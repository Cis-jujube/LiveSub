"""Native llama.cpp adapter for the pinned Confucius4-R2T2 source.

The upstream streaming result is a cumulative hypothesis. Even its ``fixed``
return value can retract text with the tested GGUF pair, so only a segment's
finish result is final. The caller must replace previews, never append them.
"""

from array import array
from collections.abc import Callable
from pathlib import Path
from typing import Protocol
import sys

from livesub.asr.base import ASREvent


SAMPLE_RATE = 16_000


class StreamingR2T2Model(Protocol):
    def init_streaming_state(self, **kwargs: object) -> object: ...

    def streaming_transcribe(
        self, samples: array, state: object
    ) -> tuple[str, str]: ...

    def finish_streaming_transcribe(self, state: object) -> str: ...


class R2T2ASREngine:
    def __init__(
        self,
        model_factory: Callable[[], StreamingR2T2Model],
        *,
        language: str,
        chunk_ms: int = 160,
        max_segment_ms: int = 6_000,
    ) -> None:
        if chunk_ms <= 0 or max_segment_ms < chunk_ms:
            raise ValueError("segment length must be at least one positive chunk")
        if language not in {"English", "Chinese"}:
            raise ValueError("R2T2 language must be English or Chinese")
        self._model_factory = model_factory
        self._language = language
        self._chunk_ms = chunk_ms
        self._chunk_samples = SAMPLE_RATE * chunk_ms // 1_000
        self._max_segment_samples = SAMPLE_RATE * max_segment_ms // 1_000
        if self._chunk_samples == 0 or self._max_segment_samples == 0:
            raise ValueError("chunk and segment must contain at least one sample")
        self._model: StreamingR2T2Model | None = None
        self.reset()

    @classmethod
    def from_local_files(
        cls,
        *,
        gguf_dir: str | Path,
        processor_dir: str | Path,
        language: str,
        model_name: str = "Confucius4-R2T2-Q4_K_M.gguf",
        projector_name: str = "mmproj-Confucius4-R2T2-Q8_0.gguf",
        use_gpu: bool = True,
    ) -> "R2T2ASREngine":
        """Load the verified local model on first start, never per frame.

        The launch environment must provide the pinned upstream source on
        ``PYTHONPATH`` and the rebuilt CPython 3.12 Mach-O extension/libraries.
        No model is downloaded by this constructor.
        """
        gguf_dir = Path(gguf_dir).expanduser().resolve()
        processor_dir = Path(processor_dir).expanduser().resolve()
        for path in (
            gguf_dir / model_name,
            gguf_dir / projector_name,
            processor_dir / "config.json",
            processor_dir / "tokenizer.json",
        ):
            if not path.is_file():
                raise FileNotFoundError(f"R2T2 model asset missing: {path}")

        def load_native() -> StreamingR2T2Model:
            from r2t2_llama import R2T2LlamaASRModel

            return R2T2LlamaASRModel.LlamaNative(
                processor_path=str(processor_dir),
                gguf_dir=str(gguf_dir),
                model_gguf_name=model_name,
                mmproj_gguf_name=projector_name,
                n_ctx=4_096,
                n_batch=2_048,
                n_threads=8,
                use_gpu=use_gpu,
                max_new_tokens=4,
            )

        return cls(load_native, language=language)

    def start(self, *, sample_rate: int) -> None:
        if sample_rate != SAMPLE_RATE:
            raise ValueError("R2T2 requires 16 kHz PCM16 mono")
        if self._started:
            return
        if self._model is None:
            self._model = self._model_factory()
        # start after finish begins a new session timeline; reset retains the
        # loaded model but discards every sample and hypothesis from prior use.
        self.reset()
        self._state = self._new_state()
        self._started = True

    def push(self, pcm16: bytes) -> list[ASREvent]:
        if not self._started or self._state is None or self._model is None:
            raise RuntimeError("R2T2 engine is not started")
        if len(pcm16) % 2:
            raise ValueError("PCM16 input must contain complete samples")
        events: list[ASREvent] = []
        position = 0
        while position < len(pcm16):
            available = self._max_segment_samples - self._segment_samples
            count = min(self._chunk_samples, available, (len(pcm16) - position) // 2)
            end = position + count * 2
            samples = array("h")
            samples.frombytes(pcm16[position:end])
            if sys.byteorder != "little":
                samples.byteswap()
            position = end
            self._segment_samples += count
            self._total_samples += count

            # Keep max_new_tokens=None. Upstream otherwise imports vLLM's
            # SamplingParams even on the pure llama.cpp path. The constructor
            # supplies a bounded four-token decode budget instead.
            hypothesis, _upstream_fixed = self._model.streaming_transcribe(
                samples, self._state
            )
            preview = hypothesis.strip()
            # A blank intermediate decode can occur after real words. Keep
            # the visible hypothesis until a replacement or final result.
            if preview and preview != self._last_preview:
                events.append(self._event(preview, final=False))
                self._last_preview = preview

            if self._segment_samples == self._max_segment_samples:
                events.extend(self._finalize_segment())
                self._segment_start_sample = self._total_samples
                self._segment_samples = 0
                self._last_preview = ""
                self._state = self._new_state()
        return events

    def finish(self) -> list[ASREvent]:
        if not self._started:
            return []
        events = self._finalize_segment() if self._segment_samples else []
        self._started = False
        self._state = None
        return events

    def reset(self) -> None:
        """Discard stream state without unloading the expensive model."""
        self._state: object | None = None
        self._started = False
        self._total_samples = 0
        self._segment_start_sample = 0
        self._segment_samples = 0
        self._last_preview = ""

    def set_language(self, language: str) -> None:
        """Select the next stream's language while retaining the loaded model.

        The caller must finish the current stream first so that its tail is
        committed before the direction changes.
        """
        if language not in {"English", "Chinese"}:
            raise ValueError("R2T2 language must be English or Chinese")
        if language == self._language:
            return
        if self._started:
            raise RuntimeError("finish the current stream before changing language")
        self._language = language
        self.reset()

    def _new_state(self) -> object:
        assert self._model is not None
        return self._model.init_streaming_state(
            language=self._language,
            unfixed_chunk_num=0,
            unfixed_token_num=1,
            chunk_size_sec=self._chunk_ms / 1_000,
        )

    def _finalize_segment(self) -> list[ASREvent]:
        assert self._model is not None and self._state is not None
        final_text = self._model.finish_streaming_transcribe(self._state).strip()
        if not final_text:
            final_text = self._last_preview
        if not final_text:
            return []
        return [self._event(final_text, final=True)]

    def _event(self, text: str, *, final: bool) -> ASREvent:
        return ASREvent(
            text=text,
            start_ms=self._segment_start_sample * 1_000 // SAMPLE_RATE,
            end_ms=self._total_samples * 1_000 // SAMPLE_RATE,
            final=final,
        )
