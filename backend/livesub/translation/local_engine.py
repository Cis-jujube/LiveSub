"""Prefer qualified native English translation, retain the local Qwen route."""

import logging
from threading import RLock

from .base import TranslationError, TranslationInputTooLong, TranslationOutputTooLong

LOG = logging.getLogger(__name__)


class LocalTranslator:
    def __init__(self, fallback, native) -> None:
        self._fallback = fallback
        self._native = native
        self._lock = RLock()
        self._prepared = False
        self._closed = False
        self._native_available = False
        self.route_counts = {"apple": 0, "qwen": 0, "native_failures": 0}

    def prepare(self) -> None:
        with self._lock:
            if self._closed:
                raise TranslationError("local translation worker has closed")
            if self._prepared:
                return
            # Keep Chinese and failed-native requests warm; model loading is
            # part of session startup rather than the first subtitle request.
            self._fallback.prepare()
            try:
                self._native.prepare()
                self._native_available = True
            except (TranslationError, OSError) as error:
                LOG.warning("Native translation unavailable (%s); using local Qwen", type(error).__name__)
                self._native.close()
            self._prepared = True

    def translate(self, request):
        with self._lock:
            self.prepare()
            if self._native_available and request.source_language == "en":
                try:
                    result = self._native.translate(request)
                    self.route_counts["apple"] += 1
                    return result
                except (TranslationInputTooLong, TranslationOutputTooLong):
                    # Preserve explicit input/output budgets across engines.
                    raise
                except TranslationError as error:
                    self.route_counts["native_failures"] += 1
                    self._native_available = False
                    self._native.close()
                    LOG.warning("Native translation failed (%s); using local Qwen", type(error).__name__)
            result = self._fallback.translate(request)
            self.route_counts["qwen"] += 1
            return result

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._native.close()
            self._fallback.close()

    def preview_interval_seconds(self, source_language: str) -> float | None:
        if self._native_available and source_language == "en":
            return self._native.preview_interval_seconds(source_language)
        return None
