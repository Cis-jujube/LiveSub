"""The small contract shared by speech-recognition adapters."""

from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True, slots=True)
class ASREvent:
    text: str
    start_ms: int
    end_ms: int
    final: bool


class ASREngine(Protocol):
    def start(self, *, sample_rate: int) -> None: ...

    def push(self, pcm16: bytes) -> list[ASREvent]: ...

    def finish(self) -> list[ASREvent]: ...

    def reset(self) -> None: ...
