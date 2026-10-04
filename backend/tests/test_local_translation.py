"""Routing preserves the request, budgets and the warm Qwen fallback."""
import pytest

from livesub.translation.base import ModelUnavailable, TranslationError, TranslationInputTooLong, TranslationRequest
from livesub.translation.local_engine import LocalTranslator


class Engine:
    def __init__(self, failure=None, prepare_failure=None):
        self.failure = failure
        self.prepare_failure = prepare_failure
        self.prepared = 0
        self.closed = 0
        self.requests = []

    def prepare(self):
        self.prepared += 1
        if self.prepare_failure:
            raise self.prepare_failure

    def translate(self, request):
        self.requests.append(request)
        if self.failure:
            raise self.failure
        return request

    def close(self):
        self.closed += 1

    def preview_interval_seconds(self, language):
        return 0.1 if language == "en" else None


def request(language="en", text="Do not send 42 files.", revision=7):
    return TranslationRequest("session", 2, "segment", revision, language,
                              "zh" if language == "en" else "en", text)


def test_native_english_and_qwen_chinese_keep_the_original_request():
    qwen, native = Engine(), Engine()
    engine = LocalTranslator(qwen, native)
    english, chinese = request(), request("zh", "不要发送42个文件。", 8)
    assert engine.translate(english) is english
    assert engine.translate(chinese) is chinese
    assert native.requests == [english] and qwen.requests == [chinese]
    assert native.prepared == qwen.prepared == 1
    assert engine.preview_interval_seconds("en") == 0.1
    assert engine.preview_interval_seconds("zh") is None
    engine.close()
    assert native.closed == qwen.closed == 1


def test_missing_languages_use_qwen_without_downloading(caplog):
    qwen, native = Engine(), Engine(prepare_failure=ModelUnavailable("missing"))
    engine = LocalTranslator(qwen, native)
    item = request()
    assert engine.translate(item) is item
    assert not native.requests and qwen.requests == [item]
    assert engine.preview_interval_seconds("en") is None
    assert "Native translation unavailable" in caplog.text
    assert item.source_text not in caplog.text
    engine.close()


def test_bad_native_result_falls_back_once_and_restores_qwen_throttle(caplog):
    qwen, native = Engine(), Engine(failure=TranslationError("invalid terms"))
    engine = LocalTranslator(qwen, native)
    first, second = request(), request(text="Wait until Friday.", revision=8)
    assert engine.translate(first) is first
    assert engine.translate(second) is second
    assert native.requests == [first] and qwen.requests == [first, second]
    assert engine.route_counts == {"apple": 0, "qwen": 2, "native_failures": 1}
    assert engine.preview_interval_seconds("en") is None
    assert "Native translation failed" in caplog.text
    assert first.source_text not in caplog.text
    engine.close()


def test_input_budget_does_not_switch_engines():
    qwen, native = Engine(), Engine(failure=TranslationInputTooLong("over budget"))
    engine = LocalTranslator(qwen, native)
    with pytest.raises(TranslationInputTooLong):
        engine.translate(request())
    assert not qwen.requests
    engine.close()


def test_unexpected_programming_error_is_not_hidden_by_fallback():
    qwen, native = Engine(), Engine(failure=TypeError("defect"))
    engine = LocalTranslator(qwen, native)
    with pytest.raises(TypeError):
        engine.translate(request())
    assert not qwen.requests
    engine.close()
