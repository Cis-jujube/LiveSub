"""Map revisable ASR hypotheses to versioned subtitle source segments."""

from dataclasses import dataclass

from livesub.asr.base import ASREvent


@dataclass(frozen=True, slots=True)
class SourceUpdate:
    session_id: str
    generation: int
    segment_id: str
    sequence: int
    start_ms: int
    end_ms: int
    source_language: str
    target_language: str
    source_text: str
    source_revision: int
    source_final: bool


class Segmenter:
    def __init__(
        self, session_id: str, generation: int, source_language: str, target_language: str
    ) -> None:
        self.session_id = session_id
        self.generation = generation
        self.source_language = source_language
        self.target_language = target_language
        self._segment_index = 0
        self._event_sequence = 0
        self._revision = 0
        self._text = ""
        self._start_ms = 0

    @property
    def active_text(self) -> str:
        return self._text

    @property
    def active_start_ms(self) -> int:
        return self._start_ms

    def apply(self, event: ASREvent) -> SourceUpdate | None:
        text = event.text.strip() or (self._text if event.final else "")
        if not text:
            return None
        if not event.final and text == self._text:
            return None
        if self._revision == 0:
            self._start_ms = event.start_ms
        self._revision += 1
        self._text = text
        update = SourceUpdate(
            session_id=self.session_id,
            generation=self.generation,
            segment_id=f"{self.generation}:{self._segment_index}",
            sequence=self._event_sequence,
            start_ms=self._start_ms,
            end_ms=event.end_ms,
            source_language=self.source_language,
            target_language=self.target_language,
            source_text=text,
            source_revision=self._revision,
            source_final=event.final,
        )
        self._event_sequence += 1
        if event.final:
            self._segment_index += 1
            self._revision = 0
            self._text = ""
        return update
