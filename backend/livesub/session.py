"""One audio/ASR stream and one translation worker per local backend session."""

import asyncio
from collections.abc import Awaitable, Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
from functools import partial
import math
import time

from livesub.asr.base import ASREngine, ASREvent
from livesub.protocol import AudioFrame
from livesub.subtitles.revision import SegmentRevisionState
from livesub.subtitles.segmenter import Segmenter, SourceUpdate
from livesub.translation.base import ContextPair, TranslationRequest, Translator
from livesub.translation.scheduler import PendingTranslations, QueueCapacityError


_DRAIN_TIMEOUT_SECONDS = 10
_TRANSLATION_TIMEOUT_SECONDS = 10


class SessionGate:
    def __init__(self) -> None:
        self.session_id: str | None = None
        self.generation = 0
        self.state = "idle"
        self._next_sequence = 0
        self._next_sample = 0

    def start(self, session_id: str, generation: int) -> bool:
        if (
            self.state != "idle"
            or not session_id
            or generation < 0
            or (session_id == self.session_id and generation <= self.generation)
        ):
            return False
        self.session_id = session_id
        self.generation = generation
        self.state = "listening"
        self._next_sequence = 0
        self._next_sample = 0
        return True

    def accept_frame(self, frame: AudioFrame) -> bool:
        if (
            self.state != "listening"
            or not frame.valid()
            or frame.session_id != self.session_id
            or frame.generation != self.generation
            or frame.sequence != self._next_sequence
            or frame.start_sample != self._next_sample
        ):
            return False
        self._next_sequence += 1
        self._next_sample += frame.sample_count
        return True

    def pause(self) -> bool:
        if self.state != "listening":
            return False
        self.state = "paused"
        return True

    def resume(self, generation: int) -> bool:
        if self.state != "paused" or generation <= self.generation:
            return False
        self.generation = generation
        self.state = "listening"
        self._next_sequence = 0
        self._next_sample = 0
        return True

    def stop(self) -> bool:
        if self.state == "idle":
            return False
        self.state = "idle"
        return True


class LiveSession:
    """Keep model calls off the WebSocket receive path and bound queued audio."""

    def __init__(
        self,
        asr: ASREngine,
        translator: Translator,
        emit: Callable[[dict], Awaitable[None]],
    ) -> None:
        self.gate = SessionGate()
        self._asr = asr
        self._translator = translator
        self._emit = emit
        self._audio: asyncio.Queue[AudioFrame | None] = asyncio.Queue(maxsize=32)
        self._audio_task: asyncio.Task | None = None
        self._translation_task: asyncio.Task | None = None
        self._translation_ready = asyncio.Event()
        self._translation_idle = asyncio.Event()
        self._translation_idle.set()
        self._pending = PendingTranslations(max_finals=32)
        self._segmenter: Segmenter | None = None
        self._revisions: dict[str, SegmentRevisionState] = {}
        self._metadata: dict[str, SourceUpdate] = {}
        self._confirmed: list[ContextPair] = []
        self._last_preview_at: dict[str, float] = {}
        self._subtitle_sequence = 0
        self._asr_offset_samples = 0
        self._silence_samples = 0
        self._closed = False
        self._asr_healthy = True
        self._asr_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="livesub-asr")
        self._translation_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="livesub-translation")

    def is_duplicate_start(
        self, session_id: str, generation: int, source_language: str, target_language: str
    ) -> bool:
        segmenter = self._segmenter
        return (
            self.gate.state in {"listening", "paused"}
            and (session_id, generation) == (self.gate.session_id, self.gate.generation)
            and segmenter is not None
            and (source_language, target_language) == (
                segmenter.source_language, segmenter.target_language
            )
        )

    async def start(
        self, session_id: str, generation: int, source_language: str, target_language: str
    ) -> bool:
        if (source_language, target_language) not in {("en", "zh"), ("zh", "en")}:
            raise ValueError("unsupported translation direction")
        if self._closed:
            return False
        if not self.gate.start(session_id, generation):
            return False
        await self._state("loading")
        prepare_translation = getattr(self._translator, "prepare", None)
        if prepare_translation is not None:
            try:
                await self._run_translation(prepare_translation)
            except Exception:
                self.gate.state = "error"
                await self._state("error", "translation_load_failed")
                raise
        try:
            set_language = getattr(self._asr, "set_language", None)
            if set_language is not None:
                await self._run_asr(set_language, "English" if source_language == "en" else "Chinese")
            await self._run_asr(self._asr.start, sample_rate=16_000)
        except Exception:
            self.gate.state = "error"
            await self._state("error", "asr_load_failed")
            raise
        self._begin_generation(session_id, generation, source_language, target_language)
        self._audio_task = asyncio.create_task(self._consume_audio())
        if self._translation_task is None or self._translation_task.done():
            self._translation_task = asyncio.create_task(self._translate())
        await self._state("listening")
        return True

    def push_audio(self, frame: AudioFrame) -> bool:
        if self._audio.full():
            if self.gate.pause():
                asyncio.create_task(self._overflow())
            return False
        if not self.gate.accept_frame(frame):
            return False
        self._audio.put_nowait(frame)
        return True

    async def pause(self) -> bool:
        if self.gate.state == "listening":
            self.gate.pause()
        elif self.gate.state == "paused" and self._audio_task is None:
            return True
        elif self.gate.state != "paused":
            return False
        if not await self._drain_audio():
            self.gate.state = "error"
            await self._state("error", "asr_drain_failed")
            return False
        if not await self._wait_translation():
            self.gate.state = "error"
            await self._state("error", "translation_timeout")
            return False
        await self._state("paused")
        return True

    async def resume(
        self, generation: int, source_language: str, target_language: str
    ) -> bool:
        if (source_language, target_language) not in {("en", "zh"), ("zh", "en")}:
            raise ValueError("unsupported translation direction")
        if self._audio_task is not None and not await self.pause():
            return False
        if not self._translation_idle.is_set():
            return False
        if not self.gate.resume(generation):
            return False
        await self._state("loading")
        try:
            await self._run_asr(self._asr.reset)
            set_language = getattr(self._asr, "set_language", None)
            if set_language is not None:
                await self._run_asr(set_language, "English" if source_language == "en" else "Chinese")
            await self._run_asr(self._asr.start, sample_rate=16_000)
        except Exception:
            self.gate.state = "error"
            await self._state("error", "asr_load_failed")
            raise
        self._begin_generation(self.gate.session_id or "", generation, source_language, target_language)
        self._audio = asyncio.Queue(maxsize=32)
        self._audio_task = asyncio.create_task(self._consume_audio())
        await self._state("listening")
        return True

    async def stop(self) -> bool:
        if self.gate.state == "idle":
            return self.gate.session_id is not None
        if self.gate.state == "error":
            return False
        await self._state("stopping")
        if self.gate.state == "listening":
            self.gate.pause()
        if not await self._drain_audio():
            self.gate.state = "error"
            await self._state("error", "asr_drain_failed")
            return False
        if not await self._wait_translation():
            self.gate.state = "error"
            await self._state("error", "translation_timeout")
            return False
        try:
            await asyncio.wait_for(self._run_asr(self._asr.reset), timeout=_DRAIN_TIMEOUT_SECONDS)
        except Exception:
            self._asr_healthy = False
            self.gate.state = "error"
            await self._state("error", "asr_reset_failed")
            return False
        self.gate.stop()
        await self._state("idle")
        return True

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self.gate.state not in {"idle", "error"}:
            await self.stop()
        if self._translation_task is not None:
            self._translation_task.cancel()
            try:
                await self._translation_task
            except asyncio.CancelledError:
                pass
        close_translator = getattr(self._translator, "close", None)
        if close_translator is not None:
            try:
                await asyncio.wait_for(self._run_translation(close_translator), timeout=5)
            except Exception:
                pass
        if self._asr_healthy:
            try:
                await asyncio.wait_for(self._run_asr(self._asr.reset), timeout=5)
            except Exception:
                pass
        self._asr_executor.shutdown(wait=False, cancel_futures=True)
        self._translation_executor.shutdown(wait=False, cancel_futures=True)

    def _begin_generation(
        self, session_id: str, generation: int, source_language: str, target_language: str
    ) -> None:
        if self._segmenter is None or self._segmenter.session_id != session_id:
            self._subtitle_sequence = 0
        if (
            self._segmenter is None
            or self._segmenter.session_id != session_id
            or self._segmenter.source_language != source_language
        ):
            self._confirmed = []
        self._segmenter = Segmenter(session_id, generation, source_language, target_language)
        self._pending.begin(session_id, generation)
        self._translation_ready.clear()
        self._translation_idle.set()
        self._revisions = {}
        self._metadata = {}
        self._last_preview_at = {}
        self._asr_offset_samples = 0
        self._silence_samples = 0

    async def _drain_audio(self) -> bool:
        task = self._audio_task
        if task is None:
            return True
        try:
            async with asyncio.timeout(_DRAIN_TIMEOUT_SECONDS):
                await self._audio.put(None)
                await task
        except TimeoutError:
            task.cancel()
            self._asr_healthy = False
            await self._emit({"kind": "error", "code": "asr_timeout", "detail": "audio tail did not finish within 10 seconds"})
            self._audio_task = None
            return False
        except Exception:
            self._asr_healthy = False
            await self._emit({"kind": "error", "code": "asr_failed", "detail": "audio processing failed"})
            self._audio_task = None
            return False
        self._audio_task = None
        return True

    async def _wait_translation(self) -> bool:
        try:
            await asyncio.wait_for(self._translation_idle.wait(), timeout=_TRANSLATION_TIMEOUT_SECONDS)
        except TimeoutError:
            await self._emit({"kind": "error", "code": "translation_timeout", "detail": "final translation did not finish within 10 seconds"})
            return False
        return True

    async def _consume_audio(self) -> None:
        while True:
            frame = await self._audio.get()
            if frame is None:
                break
            events = await self._run_asr(self._asr.push, frame.pcm16)
            await self._process_asr(events)
            segmenter = self._segmenter
            if segmenter is None:
                continue
            if self._rms(frame.pcm16) < 400:
                self._silence_samples += frame.sample_count
            else:
                self._silence_samples = 0
            text = segmenter.active_text
            spoken_ms = (frame.start_sample + frame.sample_count) * 1_000 // 16_000
            punctuated = (
                text.endswith((".", "!", "?", "。", "！", "？", ",", "，", ";", "；"))
                and spoken_ms - segmenter.active_start_ms >= 2_000
            )
            too_long = len(text) >= 80 if segmenter.source_language == "zh" else len(text.split()) >= 35
            if text and (self._silence_samples >= 8_000 or punctuated or too_long):
                await self._flush_asr()
                self._asr_offset_samples = frame.start_sample + frame.sample_count
                await self._run_asr(self._asr.reset)
                await self._run_asr(self._asr.start, sample_rate=16_000)
                self._silence_samples = 0
        await self._flush_asr()

    async def _flush_asr(self) -> None:
        events = await self._run_asr(self._asr.finish)
        await self._process_asr(events)

    async def _process_asr(self, events: list[ASREvent]) -> None:
        segmenter = self._segmenter
        if segmenter is None:
            return
        offset_ms = self._asr_offset_samples * 1_000 // 16_000
        for event in events:
            adjusted = ASREvent(
                event.text, event.start_ms + offset_ms, event.end_ms + offset_ms, event.final
            )
            update = segmenter.apply(adjusted)
            if update is None:
                continue
            state = self._revisions.setdefault(update.segment_id, SegmentRevisionState())
            if not state.apply_source(
                update.source_revision, update.source_text, final=update.source_final
            ):
                continue
            self._metadata[update.segment_id] = update
            await self._emit_subtitle(update.segment_id)
            request = TranslationRequest(
                session_id=update.session_id,
                generation=update.generation,
                segment_id=update.segment_id,
                source_revision=update.source_revision,
                source_language=update.source_language,
                target_language=update.target_language,
                source_text=update.source_text,
                confirmed_context=tuple(self._confirmed[-2:]),
            )
            if update.source_final:
                try:
                    added = self._pending.add_final(request)
                except QueueCapacityError:
                    self.gate.pause()
                    await self._emit({"kind": "error", "code": "translation_overflow", "detail": "final translation backlog exceeded 32 segments"})
                    await self._state("paused", "translation backlog exceeded 32 segments")
                    continue
                if added:
                    self._translation_idle.clear()
                    self._translation_ready.set()
            else:
                now = time.monotonic()
                if now - self._last_preview_at.get(update.segment_id, 0) >= 0.75:
                    if self._pending.add_preview(request):
                        self._last_preview_at[update.segment_id] = now
                        self._translation_ready.set()

    async def _translate(self) -> None:
        while True:
            item = self._pending.pop_next()
            if item is None:
                self._translation_ready.clear()
                await self._translation_ready.wait()
                continue
            request, is_final = item
            try:
                result = await self._run_translation(self._translator.translate, request)
                if (
                    result.session_id != request.session_id
                    or result.generation != request.generation
                    or result.segment_id != request.segment_id
                    or result.source_revision != request.source_revision
                    or result.source_language != request.source_language
                    or result.target_language != request.target_language
                    or result.translated_source_text != request.source_text.strip()
                ):
                    raise ValueError("translation result identity or source snapshot mismatch")
                state_name = "final" if is_final else "preview"
                target = result.target_text
            except Exception:
                state_name = "failed"
                target = ""
            if (request.session_id, request.generation) == (
                self.gate.session_id,
                self.gate.generation,
            ):
                revision = self._revisions.get(request.segment_id)
                if revision is not None and revision.apply_translation(
                    source_revision=request.source_revision,
                    translated_source_text=request.source_text.strip(),
                    target_text=target,
                    translation_state=state_name,
                ):
                    if state_name == "final":
                        self._confirmed.append(ContextPair(request.source_text, target))
                    await self._emit_subtitle(request.segment_id)
            if self._pending.final_count == 0:
                self._translation_idle.set()

    async def _emit_subtitle(self, segment_id: str) -> None:
        meta = self._metadata[segment_id]
        revision = self._revisions[segment_id]
        segment = asdict(meta)
        segment["sequence"] = self._subtitle_sequence
        self._subtitle_sequence += 1
        segment.update(
            target_text=revision.target_text,
            translated_source_text=revision.translated_source_text,
            translated_source_revision=revision.translated_source_revision,
            translation_state=revision.translation_state,
        )
        await self._emit({"kind": "subtitle", "segment": segment})

    async def _state(self, state: str, detail: str | None = None) -> None:
        await self._emit(
            {"kind": "state", "session_id": self.gate.session_id, "generation": self.gate.generation, "state": state, "detail": detail}
        )

    async def _overflow(self) -> None:
        await self._emit({"kind": "error", "code": "audio_overflow", "detail": "five-second audio queue filled"})
        await self._state("paused", "audio queue filled")

    async def _run_asr(self, fn: Callable, *args, **kwargs):
        return await asyncio.get_running_loop().run_in_executor(
            self._asr_executor, partial(fn, *args, **kwargs)
        )

    async def _run_translation(self, fn: Callable, *args, **kwargs):
        return await asyncio.get_running_loop().run_in_executor(
            self._translation_executor, partial(fn, *args, **kwargs)
        )

    @staticmethod
    def _rms(pcm16: bytes) -> float:
        if not pcm16:
            return 0.0
        samples = memoryview(pcm16).cast("h")
        return math.sqrt(sum(sample * sample for sample in samples) / len(samples))
