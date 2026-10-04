import asyncio
import threading

import pytest

import livesub.session as session_module
from livesub.session import LiveSession
from livesub.translation.base import TranslationRequest


class QuietASR:
    def reset(self):
        pass


class QuietTranslator:
    pass


@pytest.mark.parametrize(("holder_method", "waiter_method"), [
    ("_run_asr", "_run_translation"),
    ("_run_translation", "_run_asr"),
])
def test_cancelled_waiter_keeps_model_ownership_until_worker_finishes(holder_method, waiter_method):
    async def run():
        holder_started = threading.Event()
        release_holder = threading.Event()
        waiter_started = threading.Event()
        thread_ids = []

        async def emit(_event):
            pass

        def hold():
            thread_ids.append(threading.get_ident())
            holder_started.set()
            assert release_holder.wait(timeout=5)

        def next_model_call():
            thread_ids.append(threading.get_ident())
            waiter_started.set()
            return "completed"

        session = LiveSession(QuietASR(), QuietTranslator(), emit)
        holder = asyncio.create_task(getattr(session, holder_method)(hold))
        waiter = None
        try:
            assert await asyncio.to_thread(holder_started.wait, 2)
            holder.cancel()
            with pytest.raises(asyncio.CancelledError):
                await holder
            waiter = asyncio.create_task(getattr(session, waiter_method)(next_model_call))
            # The other executor must stay blocked even though the task waiting
            # for the first executor has already acknowledged cancellation.
            assert not await asyncio.to_thread(waiter_started.wait, 0.05)
            assert not waiter.done()
            release_holder.set()
            assert await asyncio.wait_for(waiter, timeout=2) == "completed"
            assert len(set(thread_ids)) == 2
        finally:
            release_holder.set()
            if waiter is not None:
                await asyncio.wait_for(waiter, timeout=2)
            await session.close()

    asyncio.run(run())


def test_model_exception_releases_ownership_for_other_executor():
    async def run():
        async def emit(_event):
            pass

        def fail():
            raise ValueError("model failed")

        session = LiveSession(QuietASR(), QuietTranslator(), emit)
        try:
            with pytest.raises(ValueError, match="model failed"):
                await session._run_asr(fail)
            assert await asyncio.wait_for(session._run_translation(lambda: "translated"), timeout=2) == "translated"
        finally:
            await session.close()

    asyncio.run(run())


def test_reconnected_session_waits_for_timed_out_old_model_worker(monkeypatch):
    monkeypatch.setattr(session_module, "_DRAIN_TIMEOUT_SECONDS", 0.05)

    async def run():
        shared_lock = threading.Lock()
        old_started = threading.Event()
        release_old = threading.Event()
        new_started = threading.Event()

        async def emit(_event):
            pass

        def old_inference():
            old_started.set()
            assert release_old.wait(timeout=5)

        def new_inference():
            new_started.set()
            return "new session completed"

        old = LiveSession(QuietASR(), QuietTranslator(), emit, model_lock=shared_lock)
        new = LiveSession(QuietASR(), QuietTranslator(), emit, model_lock=shared_lock)
        old._audio_task = asyncio.create_task(old._run_asr(old_inference))
        next_call = None
        try:
            assert await asyncio.to_thread(old_started.wait, 2)
            # Exercise the real timeout/close path. The asyncio task and socket
            # are gone, but the underlying executor still owns the GPU.
            assert not await old._drain_audio()
            assert not old._asr_healthy
            await old.close()
            next_call = asyncio.create_task(new._run_translation(new_inference))
            assert not await asyncio.to_thread(new_started.wait, 0.05)
            assert not next_call.done()
            release_old.set()
            assert await asyncio.wait_for(next_call, timeout=2) == "new session completed"
        finally:
            release_old.set()
            if next_call is not None:
                await asyncio.wait_for(next_call, timeout=2)
            await old.close()
            await new.close()

    asyncio.run(run())


def test_model_observer_separates_lock_wait_and_call_time_with_request_identity():
    async def run():
        records = []
        holder_started = threading.Event()
        release_holder = threading.Event()
        ownership_wait_started = threading.Event()
        observer_thread_ids = []
        loop_thread_id = threading.get_ident()

        class ObservedLock:
            def __init__(self):
                self.lock = threading.Lock()

            def __enter__(self):
                if self.lock.locked():
                    ownership_wait_started.set()
                self.lock.acquire()

            def __exit__(self, *_error):
                self.lock.release()

        async def emit(_event):
            pass

        def observe(record):
            records.append(record)
            observer_thread_ids.append(threading.get_ident())

        def hold():
            holder_started.set()
            assert release_holder.wait(timeout=5)

        def translate(request):
            return request.source_text

        session = LiveSession(QuietASR(), QuietTranslator(), emit,
                              model_lock=ObservedLock(), model_observer=observe)
        request = TranslationRequest("measured", 4, "segment", 7, "en", "zh", "A sentence")
        holder = asyncio.create_task(session._run_asr(hold))
        waiter = None
        try:
            assert await asyncio.to_thread(holder_started.wait, 2)
            waiter = asyncio.create_task(session._run_translation(translate, request))
            assert await asyncio.to_thread(ownership_wait_started.wait, 2)
            await asyncio.sleep(0.05)
            assert not waiter.done()
            release_holder.set()
            await holder
            assert await waiter == "A sentence"
            await asyncio.sleep(0)
            translation = next(record for record in records if record.kind == "translation")
            assert translation.operation == "translate"
            assert (translation.session_id, translation.generation, translation.segment_id,
                    translation.source_revision) == ("measured", 4, "segment", 7)
            assert translation.submitted_at <= translation.worker_started_at
            assert translation.worker_started_at <= translation.model_started_at <= translation.finished_at
            assert translation.model_started_at - translation.worker_started_at >= 0.02
            assert translation.error_type is None
            assert observer_thread_ids == [loop_thread_id, loop_thread_id]
        finally:
            release_holder.set()
            if waiter is not None:
                await waiter
            await holder
            await session.close()

    asyncio.run(run())


def test_cancelled_model_waiter_still_reports_actual_worker_completion():
    async def run():
        records = []
        holder_started = threading.Event()
        release_holder = threading.Event()
        observed = asyncio.Event()

        async def emit(_event):
            pass

        def observe(record):
            records.append(record)
            observed.set()

        def hold():
            holder_started.set()
            assert release_holder.wait(timeout=5)

        session = LiveSession(QuietASR(), QuietTranslator(), emit, model_observer=observe)
        holder = asyncio.create_task(session._run_asr(hold))
        try:
            assert await asyncio.to_thread(holder_started.wait, 2)
            holder.cancel()
            with pytest.raises(asyncio.CancelledError):
                await holder
            assert not records
            release_holder.set()
            await asyncio.wait_for(observed.wait(), timeout=2)
            assert len(records) == 1
            assert records[0].kind == "asr" and records[0].operation == "hold"
            assert records[0].error_type is None
        finally:
            release_holder.set()
            await session.close()

    asyncio.run(run())


def test_model_observer_records_failed_call_and_does_not_change_the_exception():
    async def run():
        records = []

        async def emit(_event):
            pass

        def fail():
            raise ValueError("model failed")

        session = LiveSession(QuietASR(), QuietTranslator(), emit, model_observer=records.append)
        try:
            with pytest.raises(ValueError, match="model failed"):
                await session._run_asr(fail)
            await asyncio.sleep(0)
            assert len(records) == 1 and records[0].error_type == "ValueError"
            assert await session._run_translation(lambda: "translated") == "translated"
        finally:
            await session.close()

    asyncio.run(run())
