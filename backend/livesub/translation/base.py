"""Identity-preserving contract for the one local translation engine."""

from dataclasses import dataclass
from typing import Literal, Protocol


Language = Literal["en", "zh"]


class TranslationError(RuntimeError):
    """A translation request could not be completed."""


class ModelUnavailable(TranslationError):
    """The selected local model is not installed."""


class TranslationInputTooLong(TranslationError):
    """The source segment exceeds the configured input budget."""


class TranslationOutputTooLong(TranslationError):
    """The model returned more than the configured output budget."""


class TranslationQueueFull(TranslationError):
    """The translation worker cannot accept another request."""


@dataclass(frozen=True, slots=True)
class ContextPair:
    """An already confirmed source and translation, provided as reference only."""

    source_text: str
    target_text: str


@dataclass(frozen=True, slots=True)
class TranslationRequest:
    session_id: str
    generation: int
    segment_id: str
    source_revision: int
    source_language: Language
    target_language: Language
    source_text: str
    confirmed_context: tuple[ContextPair, ...] = ()

    def __post_init__(self) -> None:
        if not self.session_id or not self.segment_id:
            raise ValueError("translation identity must not be empty")
        if self.generation < 0 or self.source_revision < 0:
            raise ValueError("translation generation and revision must not be negative")
        if (self.source_language, self.target_language) not in (("en", "zh"), ("zh", "en")):
            raise ValueError("translation direction must be en→zh or zh→en")


@dataclass(frozen=True, slots=True)
class TranslationResult:
    session_id: str
    generation: int
    segment_id: str
    source_revision: int
    source_language: Language
    target_language: Language
    translated_source_text: str
    target_text: str


class Translator(Protocol):
    def translate(self, request: TranslationRequest) -> TranslationResult: ...
