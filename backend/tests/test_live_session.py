import asyncio
import threading

import livesub.session as session_module

from livesub.asr.base import ASREvent
from livesub.protocol import AudioFrame
from livesub.session import LiveSession
from livesub.translation.base import TranslationResult


class FakeASR:
    def __init__(self):
        self.starts = 0
        self.pushes = 0

    def start(self, *, sample_rate):
        self.starts += 1

    def push(self, pcm16):
        self.pushes += 1
        return [ASREvent("hello", 0, 160, final=False)]

    def finish(self):
        return [ASREvent("hello", 0, 160, final=True)]

    def reset(self):
        pass


class QuietASR(FakeASR):
    def __init__(self):
        super().__init__()
        self.finishes = 0

    def push(self, pcm16):
        self.pushes += 1
        return []

    def finish(self):
        self.finishes += 1
        return []


class FakeTranslator:
    def translate(self, request):
        return TranslationResult(
            session_id=request.session_id,
            generation=request.generation,
            segment_id=request.segment_id,
            source_revision=request.source_revision,
            source_language=request.source_language,
            target_language=request.target_language,
            translated_source_text=request.source_text,
            target_text="你好",
        )


def test_real_session_path_keeps_source_and_translation_in_one_segment():
    async def run():
        events = []

        async def emit(event):
            events.append(event)

        asr = FakeASR()
        session = LiveSession(asr, FakeTranslator(), emit)
        assert await session.start("session-a", 1, "en", "zh")
        assert not await session.start("session-a", 1, "en", "zh")
        assert session.push_audio(
            AudioFrame("session-a", 1, 0, 0, 16_000, 1, b"\x00\x02" * 2560)
        )
        await session.stop()
        subtitles = [event["segment"] for event in events if event["kind"] == "subtitle"]
        assert any(segment["source_text"] == "hello" for segment in subtitles)
        assert any(
            segment["source_final"] and segment["target_text"] == "你好"
            and segment["translated_source_text"] == "hello"
            for segment in subtitles
        )
        assert len({segment["segment_id"] for segment in subtitles}) == 1
        assert asr.starts == 1
        assert asr.pushes == 1
        await session.close()

    asyncio.run(run())


def test_translation_model_stays_on_one_worker_thread():
    class TwoSegmentsASR(FakeASR):
        def push(self, pcm16):
            self.pushes += 1
            return [ASREvent(f"sentence {self.pushes}", (self.pushes - 1) * 160, self.pushes * 160, final=True)]

        def finish(self):
            return []

    class ThreadRecordingTranslator(FakeTranslator):
        def __init__(self):
            self.thread_ids = []

        def translate(self, request):
            self.thread_ids.append(threading.get_ident())
            return super().translate(request)

    async def run():
        async def emit(_event):
            pass

        translator = ThreadRecordingTranslator()
        session = LiveSession(TwoSegmentsASR(), translator, emit)
        await session.start("session-a", 1, "en", "zh")
        for sequence in range(2):
            assert session.push_audio(
                AudioFrame(
                    "session-a", 1, sequence, sequence * 2560, 16_000, 1,
                    b"\x00\x02" * 2560,
                )
            )
        await session.stop()
        assert len(translator.thread_ids) == 2
        assert len(set(translator.thread_ids)) == 1
        await session.close()

    asyncio.run(run())


def test_stop_drains_audio_after_automatic_queue_pause():
    async def run():
        events = []

        async def emit(event):
            events.append(event)

        asr = QuietASR()
        session = LiveSession(asr, FakeTranslator(), emit)
        assert await session.start("session-a", 1, "en", "zh")
        for sequence in range(32):
            assert session.push_audio(
                AudioFrame("session-a", 1, sequence, sequence * 2560, 16_000, 1,
                           b"\x00\x02" * 2560)
            )
        assert not session.push_audio(
            AudioFrame("session-a", 1, 32, 32 * 2560, 16_000, 1, b"\x00\x02" * 2560)
        )
        assert session.gate.state == "paused"
        assert await session.stop()
        assert asr.pushes == 32
        assert asr.finishes == 1
        assert session._audio_task is None
        assert events[-1]["state"] == "idle"
        await session.close()

    asyncio.run(run())


def test_loading_prepares_translation_and_reports_missing_model():
    class MissingTranslator(FakeTranslator):
        def prepare(self):
            raise FileNotFoundError("test missing model")

    async def run():
        events = []

        async def emit(event):
            events.append(event)

        asr = QuietASR()
        session = LiveSession(asr, MissingTranslator(), emit)
        try:
            await session.start("session-a", 1, "en", "zh")
            assert False, "missing translation model must fail start"
        except FileNotFoundError:
            pass
        assert asr.starts == 0
        assert events[0]["state"] == "loading"
        assert events[-1]["state"] == "error"
        assert events[-1]["detail"] == "translation_load_failed"
        await session.close()

    asyncio.run(run())


def test_pause_waits_for_final_translation_before_generation_changes():
    class BlockingTranslator(FakeTranslator):
        def __init__(self):
            self.started = threading.Event()
            self.release = threading.Event()

        def translate(self, request):
            self.started.set()
            assert self.release.wait(timeout=5)
            return super().translate(request)

    async def run():
        events = []

        async def emit(event):
            events.append(event)

        translator = BlockingTranslator()
        session = LiveSession(FakeASR(), translator, emit)
        await session.start("session-a", 1, "en", "zh")
        assert session.push_audio(
            AudioFrame("session-a", 1, 0, 0, 16_000, 1, b"\x00\x02" * 2560)
        )
        pause = asyncio.create_task(session.pause())
        try:
            assert await asyncio.to_thread(translator.started.wait, 2)
            await asyncio.sleep(0.05)
            assert not pause.done(), "pause must keep old generation finals intact"
        finally:
            translator.release.set()
        assert await pause
        assert any(
            event["kind"] == "subtitle"
            and event["segment"]["generation"] == 1
            and event["segment"]["source_final"]
            and event["segment"]["translation_state"] == "final"
            for event in events
        )
        assert await session.resume(2, "zh", "en")
        assert await session.stop()
        await session.close()

    asyncio.run(run())


def test_full_audio_queue_and_stalled_consumer_fail_within_drain_timeout(monkeypatch):
    monkeypatch.setattr(session_module, "_DRAIN_TIMEOUT_SECONDS", 0.05)

    async def run():
        events = []

        async def emit(event):
            events.append(event)

        session = LiveSession(QuietASR(), FakeTranslator(), emit)
        assert session.gate.start("session-a", 1)
        session._audio = asyncio.Queue(maxsize=1)
        session._audio.put_nowait(
            AudioFrame("session-a", 1, 0, 0, 16_000, 1, b"\x00\x02" * 2560)
        )
        session._audio_task = asyncio.create_task(asyncio.Event().wait())
        assert not await asyncio.wait_for(session.stop(), timeout=0.5)
        assert session.gate.state == "error"
        assert any(event.get("code") == "asr_timeout" for event in events)
        assert events[-1]["detail"] == "asr_drain_failed"
        await session.close()

    asyncio.run(run())


def test_stop_reports_translation_timeout_without_claiming_idle(monkeypatch):
    monkeypatch.setattr(session_module, "_TRANSLATION_TIMEOUT_SECONDS", 0.05)

    class BlockingTranslator(FakeTranslator):
        def __init__(self):
            self.started = threading.Event()
            self.release = threading.Event()

        def translate(self, request):
            self.started.set()
            assert self.release.wait(timeout=5)
            return super().translate(request)

    async def run():
        events = []

        async def emit(event):
            events.append(event)

        translator = BlockingTranslator()
        session = LiveSession(FakeASR(), translator, emit)
        await session.start("session-a", 1, "en", "zh")
        assert session.push_audio(
            AudioFrame("session-a", 1, 0, 0, 16_000, 1, b"\x00\x02" * 2560)
        )
        try:
            assert not await asyncio.wait_for(session.stop(), timeout=0.5)
            assert translator.started.is_set()
            assert session.gate.state == "error"
            assert events[-1]["detail"] == "translation_timeout"
            assert not any(event.get("state") == "idle" for event in events)
        finally:
            translator.release.set()
            await session.close()

    asyncio.run(run())


def test_new_session_clears_translation_context_and_subtitle_sequence():
    class RecordingTranslator(FakeTranslator):
        def __init__(self):
            self.requests = []

        def translate(self, request):
            self.requests.append(request)
            return super().translate(request)

    async def run():
        events = []

        async def emit(event):
            events.append(event)

        translator = RecordingTranslator()
        session = LiveSession(FakeASR(), translator, emit)
        assert await session.start("first", 1, "en", "zh")
        assert session.push_audio(AudioFrame("first", 1, 0, 0, 16_000, 1, b"\x00\x02" * 2560))
        assert await session.stop()
        first_worker = session._translation_task
        assert first_worker is not None and not first_worker.done()
        first_subtitles = [e["segment"] for e in events if e["kind"] == "subtitle"]
        assert first_subtitles and first_subtitles[0]["sequence"] == 0
        assert session._confirmed

        events.clear()
        assert await session.start("second", 1, "en", "zh")
        assert session._translation_task is first_worker
        assert session.push_audio(AudioFrame("second", 1, 0, 0, 16_000, 1, b"\x00\x02" * 2560))
        assert await session.stop()
        second_requests = [r for r in translator.requests if r.session_id == "second"]
        assert second_requests and all(not r.confirmed_context for r in second_requests)
        second_subtitles = [e["segment"] for e in events if e["kind"] == "subtitle"]
        assert second_subtitles and second_subtitles[0]["sequence"] == 0
        await session.close()

    asyncio.run(run())


def test_backlogged_finals_get_fresh_context_at_dequeue():
    class RecordingTranslator(FakeTranslator):
        def __init__(self):
            self.requests = []

        def translate(self, request):
            self.requests.append(request)
            return super().translate(request)

    async def run():
        async def emit(_):
            pass

        translator = RecordingTranslator()
        session = LiveSession(QuietASR(), translator, emit)
        await session.start("context", 1, "en", "zh")
        # Enqueue all before any translation can finish.
        await session._process_asr([
            ASREvent("We discuss AI agents.", 0, 100, final=True),
            ASREvent("They use tools.", 100, 200, final=True),
            ASREvent("They also use tokens.", 200, 300, final=True),
        ])
        await session.stop()
        assert [len(r.confirmed_context) for r in translator.requests] == [0, 1, 2]
        assert translator.requests[-1].confirmed_context[-1].source_text == "They use tools."
        assert len(session._confirmed) == 3
        await session.close()

    asyncio.run(run())


def test_context_excludes_self_future_overlap_wrong_generation_and_direction():
    from dataclasses import replace
    from livesub.session import ConfirmedSegment
    from livesub.subtitles.segmenter import SourceUpdate
    from livesub.translation.base import ContextPair, TranslationRequest

    async def emit(_):
        pass

    session = LiveSession(QuietASR(), FakeTranslator(), emit)
    current = TranslationRequest("s", 2, "current", 1, "en", "zh", "current")
    session._metadata["current"] = SourceUpdate("s", 2, "current", 10, 100, 200, "en", "zh", "current", 1, False)
    for name, generation, language, seq, start, end in [
        ("prior", 2, "en", 1, 0, 100),
        ("current", 2, "en", 2, 0, 50),
        ("future", 2, "en", 11, 200, 300),
        ("overlap", 2, "en", 3, 50, 150),
        ("oldgen", 1, "en", 4, 0, 50),
        ("wrongdir", 2, "zh", 5, 0, 50),
    ]:
        req = replace(current, segment_id=name, generation=generation, source_language=language, target_language="zh" if language == "en" else "en")
        session._confirmed.append(ConfirmedSegment(req, start, end, seq, ContextPair(name, name)))
    assert [p.source_text for p in session._context_for(current)] == ["prior"]
    for i in range(100):
        session._confirmed.append(session._confirmed[0])
    assert len(session._confirmed) == 32
    session._begin_generation("s", 3, "en", "zh")
    assert not session._confirmed
    asyncio.run(session.close())


def test_latest_throttled_preview_is_translated_without_another_asr_event(monkeypatch):
    monkeypatch.setattr(session_module, "_PREVIEW_INTERVAL_SECONDS", 0.05)

    class RecordingTranslator(FakeTranslator):
        def __init__(self):
            self.requests = []

        def translate(self, request):
            self.requests.append(request)
            return super().translate(request)

    async def run():
        first_ready = asyncio.Event()
        latest_ready = asyncio.Event()

        async def emit(event):
            if event["kind"] == "subtitle":
                subtitle = event["segment"]
                if subtitle["translation_state"] == "preview":
                    if subtitle["translated_source_text"] == "hello":
                        first_ready.set()
                    if subtitle["translated_source_text"] == "hello there friend":
                        latest_ready.set()

        translator = RecordingTranslator()
        session = LiveSession(QuietASR(), translator, emit)
        try:
            await session.start("preview", 1, "en", "zh")
            await session._process_asr([ASREvent("hello", 0, 160, False)])
            await asyncio.wait_for(first_ready.wait(), timeout=1)
            await session._process_asr([ASREvent("hello there", 0, 320, False)])
            handle = session._deferred_previews["1:0"][1]
            await session._process_asr([ASREvent("hello there friend", 0, 480, False)])
            assert session._deferred_previews["1:0"][1] is handle
            await asyncio.wait_for(latest_ready.wait(), timeout=1)
            assert [r.source_text for r in translator.requests] == ["hello", "hello there friend"]
            assert not session._deferred_previews
            await session._process_asr([ASREvent("hello there friend", 0, 480, True)])
            assert await session.stop()
        finally:
            await session.close()

    asyncio.run(run())


def test_final_cancels_deferred_preview_and_keeps_final_priority():
    async def run():
        events = []

        async def emit(event):
            events.append(event)

        session = LiveSession(QuietASR(), FakeTranslator(), emit)
        try:
            await session.start("preview", 1, "en", "zh")
            session._last_preview_at["1:0"] = session_module.time.monotonic()
            await session._process_asr([ASREvent("hello", 0, 160, False)])
            handle = session._deferred_previews["1:0"][1]
            await session._process_asr([ASREvent("hello friend", 0, 320, True)])
            assert handle.cancelled()
            assert not session._deferred_previews
            assert await session.stop()
            subtitles = [e["segment"] for e in events if e["kind"] == "subtitle"]
            assert subtitles[-1]["translation_state"] == "final"
            assert subtitles[-1]["translated_source_text"] == "hello friend"
            assert not any(s["translation_state"] == "preview" for s in subtitles)
        finally:
            await session.close()

    asyncio.run(run())


def test_generation_change_and_close_cancel_deferred_preview():
    from livesub.translation.base import TranslationRequest

    async def run():
        async def emit(_):
            pass

        session = LiveSession(QuietASR(), FakeTranslator(), emit)
        session._begin_generation("preview", 1, "en", "zh")
        session._last_preview_at["1:0"] = session_module.time.monotonic()
        session._schedule_preview(TranslationRequest("preview", 1, "1:0", 1, "en", "zh", "hello"))
        first = session._deferred_previews["1:0"][1]
        session._begin_generation("preview", 2, "zh", "en")
        assert first.cancelled()
        assert not session._deferred_previews
        assert session._pending.pop_next() is None
        session._last_preview_at["2:0"] = session_module.time.monotonic()
        session._schedule_preview(TranslationRequest("preview", 2, "2:0", 1, "zh", "en", "你好"))
        second = session._deferred_previews["2:0"][1]
        await session.close()
        assert second.cancelled()
        assert not session._deferred_previews

    asyncio.run(run())
