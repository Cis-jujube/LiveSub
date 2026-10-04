"""One audio/ASR stream and one translation worker per local backend session."""

from _thread import LockType
import asyncio
from collections import deque
from collections.abc import Awaitable, Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, replace
from functools import partial
import math
from threading import Lock
import time

from livesub.asr.base import ASREngine, ASREvent
from livesub.protocol import AudioFrame
from livesub.subtitles.revision import SegmentRevisionState
from livesub.subtitles.segmenter import Segmenter, SourceUpdate
from livesub.translation.base import ContextPair, TranslationRequest, Translator
from livesub.translation.scheduler import PendingTranslations, QueueCapacityError
from livesub.translation.mlx_engine import MAX_CONTEXT_PAIRS


_DRAIN_TIMEOUT_SECONDS = 10
_TRANSLATION_TIMEOUT_SECONDS = 10
_PREVIEW_INTERVAL_SECONDS = 0.75


@dataclass(frozen=True, slots=True)
class ModelCallTiming:
    """Optional local trace of executor queuing, model ownership and execution."""

    kind: str
    operation: str
    session_id: str | None
    generation: int
    segment_id: str | None
    source_revision: int | None
    submitted_at: float
    worker_started_at: float
    model_started_at: float
    finished_at: float
    error_type: str | None


@dataclass(frozen=True, slots=True)
class ConfirmedSegment:
    request: TranslationRequest
    start_ms: int
    end_ms: int
    sequence: int
    pair: ContextPair


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
        *,
        model_lock: LockType | None = None,
        model_observer: Callable[[ModelCallTiming], None] | None = None,
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
        self._confirmed: deque[ConfirmedSegment] = deque(maxlen=32)
        self._last_preview_at: dict[str, float] = {}
        self._deferred_previews: dict[str, tuple[TranslationRequest, asyncio.TimerHandle]] = {}
        self._subtitle_sequence = 0
        self._asr_offset_samples = 0
        self._silence_samples = 0
        self._current_speaker_id: str | None = None
        self._asr_has_audio = False
        self._selected_speakers: frozenset[str] | None = None
        self._closed = False
        self._asr_healthy = True
        # Qwen MPS and MLX share one GPU. Hold ownership inside the worker
        # callable so cancelling its asyncio waiter cannot release the GPU
        # while the underlying inference is still running.
        self._model_lock = model_lock if model_lock is not None else Lock()
        self._model_observer = model_observer
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

    async def select_speakers(self, speaker_ids: list[str] | None) -> None:
        if speaker_ids is not None and (
            len(speaker_ids) > 5
            or len(set(speaker_ids)) != len(speaker_ids)
            or any(speaker_id not in {"A", "B", "C", "D", "E"} for speaker_id in speaker_ids)
        ):
            raise ValueError("choose at most five distinct detected speakers")
        self._selected_speakers = None if speaker_ids is None else frozenset(speaker_ids)
        for segment_id, meta in list(self._metadata.items()):
            revision = self._revisions.get(segment_id)
            if revision is None:
                continue
            if self._speaker_is_selected(meta.speaker_id):
                revision.request_translation()
            else:
                revision.skip_translation()
            await self._emit_subtitle(segment_id)
            if meta.source_final and not self._speaker_is_selected(meta.speaker_id):
                self._revisions.pop(segment_id, None)
                self._metadata.pop(segment_id, None)

    def _speaker_is_selected(self, speaker_id: str | None) -> bool:
        return self._selected_speakers is None or speaker_id in self._selected_speakers

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
        self._cancel_deferred_previews()
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
        self._confirmed.clear()
        self._cancel_deferred_previews()
        self._segmenter = Segmenter(session_id, generation, source_language, target_language)
        self._pending.begin(session_id, generation)
        self._translation_ready.clear()
        self._translation_idle.set()
        self._revisions = {}
        self._metadata = {}
        self._last_preview_at = {}
        self._asr_offset_samples = 0
        self._silence_samples = 0
        self._current_speaker_id = None
        self._asr_has_audio = False
        self._selected_speakers = None

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
            # Diarization leaves silent frames unattributed. Keep them with the
            # preceding voice so a pause does not reset ASR every 160 ms.
            rms = self._rms(frame.pcm16)
            speaker_id = frame.speaker_id
            if speaker_id is None and self._current_speaker_id is not None and rms < 400:
                speaker_id = self._current_speaker_id
            if speaker_id != self._current_speaker_id:
                if self._asr_has_audio:
                    await self._flush_asr()
                    await self._run_asr(self._asr.reset)
                    await self._run_asr(self._asr.start, sample_rate=16_000)
                self._asr_offset_samples = frame.start_sample
                self._current_speaker_id = speaker_id
                self._silence_samples = 0
            # A slow inference or a diarization batch can leave several frames
            # queued. Feed all of them in order, but decode the newest available
            # preview instead of spending GPU time replaying obsolete previews.
            # Adapters without this capability retain their streaming behavior.
            push = self._asr.push
            if not self._audio.empty():
                push = getattr(self._asr, "push_without_preview", push)
            events = await self._run_asr(push, frame.pcm16)
            self._asr_has_audio = True
            await self._process_asr(events)
            segmenter = self._segmenter
            if segmenter is None:
                continue
            if rms < 400:
                self._silence_samples += frame.sample_count
            else:
                self._silence_samples = 0
            text = segmenter.active_text
            too_long = len(text) >= 80 if segmenter.source_language == "zh" else len(text.split()) >= 35
            # A Qwen preview can add punctuation before the next spoken word.
            # Only silence or a length bound may seal a revisable ASR segment.
            if text and (self._silence_samples >= 8_000 or too_long):
                await self._flush_asr()
                self._asr_offset_samples = frame.start_sample + frame.sample_count
                await self._run_asr(self._asr.reset)
                await self._run_asr(self._asr.start, sample_rate=16_000)
                self._silence_samples = 0
        await self._flush_asr()

    async def _flush_asr(self) -> None:
        events = await self._run_asr(self._asr.finish)
        self._asr_has_audio = False
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
            update = segmenter.apply(adjusted, speaker_id=self._current_speaker_id)
            if update is None:
                continue
            state = self._revisions.setdefault(update.segment_id, SegmentRevisionState())
            if not state.apply_source(
                update.source_revision, update.source_text, final=update.source_final
            ):
                continue
            self._metadata[update.segment_id] = update
            if self._speaker_is_selected(update.speaker_id):
                state.request_translation()
            else:
                state.skip_translation()
            await self._emit_subtitle(update.segment_id)
            if not self._speaker_is_selected(update.speaker_id):
                if update.source_final:
                    self._revisions.pop(update.segment_id, None)
                    self._metadata.pop(update.segment_id, None)
                continue
            request = TranslationRequest(
                session_id=update.session_id,
                generation=update.generation,
                segment_id=update.segment_id,
                source_revision=update.source_revision,
                source_language=update.source_language,
                target_language=update.target_language,
                source_text=update.source_text,
            )
            if update.source_final:
                self._last_preview_at.pop(update.segment_id, None)
                deferred = self._deferred_previews.pop(update.segment_id, None)
                if deferred is not None:
                    deferred[1].cancel()
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
                self._schedule_preview(request)

    def _schedule_preview(self, request: TranslationRequest) -> None:
        if self._closed:
            return
        if self._pending.replace_preview(request):
            return
        deferred = self._deferred_previews.get(request.segment_id)
        if deferred is not None:
            # Keep the original deadline so a stream of revisions cannot
            # continually postpone the latest preview.
            self._deferred_previews[request.segment_id] = (request, deferred[1])
            return
        recommend_interval = getattr(self._translator, "preview_interval_seconds", None)
        interval = recommend_interval(request.source_language) if recommend_interval else None
        delay = (
            self._last_preview_at.get(request.segment_id, 0)
            + (interval if interval is not None else _PREVIEW_INTERVAL_SECONDS) - time.monotonic()
        )
        if delay <= 0:
            self._publish_preview(request)
        else:
            handle = asyncio.get_running_loop().call_later(
                delay, self._release_preview, request.segment_id
            )
            self._deferred_previews[request.segment_id] = (request, handle)

    def _publish_preview(self, request: TranslationRequest) -> None:
        if self._pending.add_preview(request):
            self._last_preview_at[request.segment_id] = time.monotonic()
            self._translation_ready.set()

    def _release_preview(self, segment_id: str) -> None:
        deferred = self._deferred_previews.pop(segment_id, None)
        if deferred is not None:
            self._publish_preview(deferred[0])

    def _cancel_deferred_previews(self) -> None:
        for _, handle in self._deferred_previews.values():
            handle.cancel()
        self._deferred_previews.clear()

    async def _translate(self) -> None:
        while True:
            item = self._pending.pop_next()
            if item is None:
                self._translation_ready.clear()
                await self._translation_ready.wait()
                continue
            request, is_final = item
            meta = self._metadata.get(request.segment_id)
            if meta is None or not self._speaker_is_selected(meta.speaker_id):
                if self._pending.final_count == 0:
                    self._translation_idle.set()
                continue
            request = replace(request, confirmed_context=self._context_for(request))
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
                meta = self._metadata.get(request.segment_id)
                if revision is not None and meta is not None and self._speaker_is_selected(meta.speaker_id) and revision.apply_translation(
                    source_revision=request.source_revision,
                    translated_source_text=request.source_text.strip(),
                    target_text=target,
                    translation_state=state_name,
                ):
                    if state_name == "final":
                        meta = self._metadata[request.segment_id]
                        self._confirmed.append(ConfirmedSegment(
                            request=replace(request, confirmed_context=()),
                            start_ms=meta.start_ms, end_ms=meta.end_ms, sequence=meta.sequence,
                            pair=ContextPair(request.source_text, target),
                        ))
                    await self._emit_subtitle(request.segment_id)
                    if is_final:
                        # The emitted record is complete; only recent confirmed pairs
                        # are needed for later translation context.
                        self._revisions.pop(request.segment_id, None)
                        self._metadata.pop(request.segment_id, None)
            if self._pending.final_count == 0:
                self._translation_idle.set()

    def _context_for(self, request: TranslationRequest) -> tuple[ContextPair, ...]:
        current = self._metadata.get(request.segment_id)
        if current is None:
            return ()
        earlier = [item for item in self._confirmed if (
            item.request.session_id == request.session_id
            and item.request.generation == request.generation
            and item.request.source_language == request.source_language
            and item.request.target_language == request.target_language
            and item.request.segment_id != request.segment_id
            and item.sequence < current.sequence
            and item.start_ms <= current.start_ms
            and item.end_ms <= current.start_ms
        )]
        earlier.sort(key=lambda item: (item.start_ms, item.sequence))
        return tuple(item.pair for item in earlier[-MAX_CONTEXT_PAIRS:])

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
        return await self._run_model(self._asr_executor, "asr", fn, *args, **kwargs)

    async def _run_translation(self, fn: Callable, *args, **kwargs):
        return await self._run_model(self._translation_executor, "translation", fn, *args, **kwargs)

    async def _run_model(self, executor: ThreadPoolExecutor, kind: str, fn: Callable, *args, **kwargs):
        loop = asyncio.get_running_loop()
        if self._model_observer is None:
            call = partial(self._call_model, fn, *args, **kwargs)
        else:
            request = args[0] if args and isinstance(args[0], TranslationRequest) else None
            call = partial(
                self._call_model_measured, loop, kind, fn, time.perf_counter(),
                request.session_id if request is not None else self.gate.session_id,
                request.generation if request is not None else self.gate.generation,
                request.segment_id if request is not None else None,
                request.source_revision if request is not None else None,
                *args, **kwargs,
            )
        return await loop.run_in_executor(executor, call)

    def _call_model(self, fn: Callable, *args, **kwargs):
        with self._model_lock:
            return fn(*args, **kwargs)

    def _call_model_measured(
        self, loop: asyncio.AbstractEventLoop, kind: str, fn: Callable,
        submitted_at: float, session_id: str | None, generation: int,
        segment_id: str | None, source_revision: int | None, *args, **kwargs,
    ):
        worker_started_at = time.perf_counter()
        error_type = None
        with self._model_lock:
            model_started_at = time.perf_counter()
            try:
                return fn(*args, **kwargs)
            except BaseException as error:
                error_type = type(error).__name__
                raise
            finally:
                timing = ModelCallTiming(
                    kind, getattr(fn, "__name__", type(fn).__name__),
                    session_id, generation, segment_id, source_revision,
                    submitted_at, worker_started_at, model_started_at,
                    time.perf_counter(), error_type,
                )
                # A cancelled coroutine can leave its actual worker running.
                # Deliver its record on the event loop without letting an
                # observer exception change the model result or lock lifetime.
                try:
                    loop.call_soon_threadsafe(self._model_observer, timing)
                except RuntimeError:
                    if not loop.is_closed():
                        raise

    @staticmethod
    def _rms(pcm16: bytes) -> float:
        if not pcm16:
            return 0.0
        samples = memoryview(pcm16).cast("h")
        return math.sqrt(sum(sample * sample for sample in samples) / len(samples))
