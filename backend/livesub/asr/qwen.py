"""Local Qwen3-ASR speech recognition with revisable real-time previews."""

from collections.abc import Callable
from pathlib import Path
from typing import Protocol

import numpy as np

from livesub.asr.base import ASREvent


SAMPLE_RATE = 16_000


class Transcriber(Protocol):
    def transcribe(self, *, audio: tuple[np.ndarray, int], language: str) -> object: ...


class QwenASREngine:
    def __init__(
        self,
        model_factory: Callable[[], Transcriber],
        *,
        language: str,
        preview_ms: int = 800,
        max_segment_ms: int = 12_000,
    ) -> None:
        if language not in {"English", "Chinese"}:
            raise ValueError("Qwen ASR language must be English or Chinese")
        if preview_ms <= 0 or max_segment_ms < preview_ms:
            raise ValueError("invalid ASR segment timing")
        self._model_factory = model_factory
        self._model: Transcriber | None = None
        self._language = language
        self._preview_samples = SAMPLE_RATE * preview_ms // 1_000
        self._max_segment_samples = SAMPLE_RATE * max_segment_ms // 1_000
        self.reset()

    @classmethod
    def from_local_files(cls, model_dir: str | Path, *, language: str) -> "QwenASREngine":
        path = Path(model_dir).expanduser().resolve()
        for name in ("config.json", "model.safetensors.index.json", "model-00001-of-00002.safetensors",
                     "model-00002-of-00002.safetensors", "vocab.json"):
            if not (path / name).is_file():
                raise FileNotFoundError(f"Qwen ASR model asset missing: {path / name}")

        def load() -> Transcriber:
            import torch
            from qwen_asr import Qwen3ASRModel

            mps = torch.backends.mps.is_available()
            return Qwen3ASRModel.from_pretrained(
                str(path), dtype=torch.float16 if mps else torch.float32,
                device_map="mps" if mps else "cpu", max_inference_batch_size=1,
                max_new_tokens=256,
            )

        return cls(load, language=language)

    def start(self, *, sample_rate: int) -> None:
        if sample_rate != SAMPLE_RATE:
            raise ValueError("Qwen ASR requires 16 kHz PCM16 mono")
        if self._started:
            return
        if self._model is None:
            self._model = self._model_factory()
        self.reset()
        self._started = True

    def push(self, pcm16: bytes) -> list[ASREvent]:
        return self._push(pcm16, preview=True)

    def push_without_preview(self, pcm16: bytes) -> list[ASREvent]:
        """Keep every sample and segment final, but skip an obsolete preview."""
        return self._push(pcm16, preview=False)

    def _push(self, pcm16: bytes, *, preview: bool) -> list[ASREvent]:
        if not self._started or self._model is None:
            raise RuntimeError("Qwen ASR engine is not started")
        if len(pcm16) % 2:
            raise ValueError("PCM16 input must contain complete samples")
        events: list[ASREvent] = []
        position = 0
        while position < len(pcm16):
            available = self._max_segment_samples - len(self._pcm) // 2
            count = min(available, (len(pcm16) - position) // 2)
            chunk = pcm16[position:position + count * 2]
            samples = np.frombuffer(chunk, dtype="<i2").astype(np.float32)
            # An exact-zero suffix contains no new speech for a revisable
            # preview. Keep it in PCM: final recognition still sees the full
            # suffix, since padding can change Qwen's last-word hypothesis.
            if np.any(samples):
                self._audio_since_preview = True
            if np.sqrt(np.mean(samples * samples)) >= 200:
                self._speech_detected = True
            self._pcm.extend(chunk)
            self._total_samples += count
            position += count * 2
            segment_samples = len(self._pcm) // 2
            if segment_samples == self._max_segment_samples:
                events.extend(self._finalize())
                self._segment_start_sample = self._total_samples
                self._last_preview_at = 0
                self._last_preview = ""
                self._speech_detected = False
                self._audio_since_preview = False
                self._pcm.clear()
            elif (
                preview and self._audio_since_preview
                and segment_samples - self._last_preview_at >= self._preview_samples
            ):
                self._last_preview_at = segment_samples
                text = self._recognize()
                self._audio_since_preview = False
                if text and text != self._last_preview:
                    events.append(self._event(text, final=False))
                    self._last_preview = text
        return events

    def finish(self) -> list[ASREvent]:
        if not self._started:
            return []
        events = self._finalize() if self._pcm else []
        self._started = False
        self._pcm.clear()
        return events

    def reset(self) -> None:
        self._pcm = bytearray()
        self._started = False
        self._total_samples = 0
        self._segment_start_sample = 0
        self._last_preview_at = 0
        self._last_preview = ""
        self._speech_detected = False
        self._audio_since_preview = False

    def set_language(self, language: str) -> None:
        if language not in {"English", "Chinese"}:
            raise ValueError("Qwen ASR language must be English or Chinese")
        if self._started:
            raise RuntimeError("finish the current stream before changing language")
        self._language = language
        self.reset()

    def _recognize(self) -> str:
        assert self._model is not None
        if not self._speech_detected:
            return ""
        samples = np.frombuffer(self._pcm, dtype="<i2").astype(np.float32) / 32768
        result = self._model.transcribe(audio=(samples, SAMPLE_RATE), language=self._language)
        return str(result[0].text).strip()

    def _finalize(self) -> list[ASREvent]:
        # The last preview already decoded these exact samples. A second pass
        # over identical audio adds latency without supplying new evidence.
        if self._last_preview and self._last_preview_at == len(self._pcm) // 2:
            text = self._last_preview
        else:
            text = self._recognize() or self._last_preview
        return [self._event(text, final=True)] if text else []

    def _event(self, text: str, *, final: bool) -> ASREvent:
        return ASREvent(text=text, start_ms=self._segment_start_sample * 1_000 // SAMPLE_RATE,
                        end_ms=self._total_samples * 1_000 // SAMPLE_RATE, final=final)
