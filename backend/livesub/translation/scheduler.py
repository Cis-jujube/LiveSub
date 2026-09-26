"""Bounded, final-first translation scheduling for one local model worker."""

from collections import OrderedDict, deque

from livesub.translation.base import TranslationRequest


class QueueCapacityError(RuntimeError):
    """The final translation backlog reached its configured safety limit."""


class PendingTranslations:
    def __init__(self, *, max_finals: int = 32) -> None:
        if max_finals < 1:
            raise ValueError("max_finals must be positive")
        self.max_finals = max_finals
        self._identity: tuple[str, int] | None = None
        self._finals: deque[TranslationRequest] = deque()
        self._previews: OrderedDict[str, TranslationRequest] = OrderedDict()
        self._final_segments: set[str] = set()

    @property
    def final_count(self) -> int:
        return len(self._finals)

    def begin(self, session_id: str, generation: int) -> None:
        self._identity = (session_id, generation)
        self._finals.clear()
        self._previews.clear()
        self._final_segments.clear()

    def add_preview(self, request: TranslationRequest) -> bool:
        if not self._matches(request) or request.segment_id in self._final_segments:
            return False
        current = self._previews.get(request.segment_id)
        if current is not None and request.source_revision <= current.source_revision:
            return False
        self._previews[request.segment_id] = request
        return True

    def add_final(self, request: TranslationRequest) -> bool:
        if not self._matches(request) or request.segment_id in self._final_segments:
            return False
        if len(self._finals) >= self.max_finals:
            raise QueueCapacityError(f"final translation queue exceeded {self.max_finals}")
        self._previews.pop(request.segment_id, None)
        self._final_segments.add(request.segment_id)
        self._finals.append(request)
        return True

    def pop_next(self) -> tuple[TranslationRequest, bool] | None:
        if self._finals:
            return self._finals.popleft(), True
        if self._previews:
            _, request = self._previews.popitem(last=False)
            return request, False
        return None

    def _matches(self, request: TranslationRequest) -> bool:
        return (request.session_id, request.generation) == self._identity
