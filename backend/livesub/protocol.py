"""Validated data exchanged between the native app and local backend."""

from dataclasses import dataclass


SAMPLE_RATE = 16_000
FRAME_SAMPLES = 2_560
PROTOCOL_VERSION = 1


@dataclass(frozen=True, slots=True)
class AudioFrame:
    session_id: str
    generation: int
    sequence: int
    start_sample: int
    sample_rate: int
    channels: int
    pcm16: bytes
    speaker_id: str | None = None

    def valid(self) -> bool:
        return (
            bool(self.session_id)
            and self.generation >= 0
            and self.sequence >= 0
            and self.start_sample >= 0
            and self.sample_rate == SAMPLE_RATE
            and self.channels == 1
            and 0 < len(self.pcm16) <= FRAME_SAMPLES * 2
            and len(self.pcm16) % 2 == 0
            and (self.speaker_id is None or self.speaker_id in {"A", "B", "C", "D", "E"})
        )

    @property
    def sample_count(self) -> int:
        return len(self.pcm16) // 2
