"""Deterministic translation contract tests; real model tests run separately."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import get_ident

import pytest

from livesub.translation.base import (
    ContextPair,
    TranslationError,
    TranslationInputTooLong,
    TranslationOutputTooLong,
    TranslationRequest,
)
from livesub.translation.mlx_engine import MLXTranslator


class FakeTokenizer:
    def apply_chat_template(self, messages, *, tokenize, add_generation_prompt):
        assert tokenize is False
        assert add_generation_prompt is True
        return "\n".join(f"{message['role']}: {message['content']}" for message in messages)

    def encode(self, text, *, add_special_tokens=False):
        assert add_special_tokens is False
        return text.split()


def request(source_text="Hello, world.", **changes):
    values = dict(
        session_id="session-1",
        generation=2,
        segment_id="segment-3",
        source_revision=4,
        source_language="en",
        target_language="zh",
        source_text=source_text,
        confirmed_context=(),
    )
    values.update(changes)
    return TranslationRequest(**values)


def translator(tmp_path: Path, output="你好，世界。"):
    model_path = tmp_path / "model"
    model_path.mkdir()
    loads = []
    calls = []

    def load(path):
        loads.append(path)
        return object(), FakeTokenizer()

    def generate(model, tokenizer, prompt, *, max_tokens):
        calls.append((prompt, max_tokens))
        return output

    return MLXTranslator(model_path, model_loader=load, text_generator=generate), loads, calls


def test_empty_input_preserves_identity_without_loading_model(tmp_path):
    engine, loads, calls = translator(tmp_path)
    result = engine.translate(request("  \n "))
    assert result.session_id == "session-1"
    assert result.generation == 2
    assert result.segment_id == "segment-3"
    assert result.source_revision == 4
    assert result.translated_source_text == ""
    assert result.target_text == ""
    assert loads == []
    assert calls == []


@pytest.mark.parametrize(
    ("source_language", "target_language", "source_text", "output", "direction"),
    [
        ("en", "zh", "Don't erase 42 rows.", "不要删除 42 行。", "English to Simplified Chinese"),
        ("zh", "en", "不要删除 42 行。", "Do not delete 42 rows.", "Simplified Chinese to English"),
    ],
)
def test_direction_and_revision_are_preserved(
    tmp_path, source_language, target_language, source_text, output, direction
):
    engine, loads, calls = translator(tmp_path, output)
    item = request(
        source_text,
        source_language=source_language,
        target_language=target_language,
        source_revision=17,
    )
    result = engine.translate(item)
    assert result.source_language == source_language
    assert result.target_language == target_language
    assert result.source_revision == 17
    assert result.translated_source_text == source_text
    assert result.target_text == output
    assert direction in calls[0][0]
    assert calls[0][1] == 256
    assert loads == [tmp_path / "model"]
    engine.translate(item)
    assert loads == [tmp_path / "model"]


def test_generation_output_is_capped_even_if_backend_ignores_limit(tmp_path):
    engine, _, _ = translator(tmp_path, "word " * 257)
    with pytest.raises(TranslationOutputTooLong):
        engine.translate(request())


def test_nonempty_source_cannot_succeed_with_empty_translation(tmp_path):
    engine, _, _ = translator(tmp_path, "   ")
    with pytest.raises(TranslationError, match="no translation"):
        engine.translate(request())


def test_source_over_input_budget_fails_before_generation(tmp_path):
    engine, _, calls = translator(tmp_path)
    with pytest.raises(TranslationInputTooLong):
        engine.translate(request("word " * 2100))
    assert calls == []


def test_only_recent_confirmed_context_within_budget_is_used(tmp_path):
    engine, _, calls = translator(tmp_path)
    context = (
        ContextPair("old " * 300, "旧 " * 300),
        ContextPair("middle " * 300, "中 " * 300),
        ContextPair("recent " * 100, "近 " * 100),
    )
    engine.translate(request(confirmed_context=context))
    prompt, _ = calls[0]
    assert "recent" in prompt
    assert "middle" not in prompt
    assert "old" not in prompt


def test_model_load_and_inference_stay_on_one_worker_thread(tmp_path):
    model_path = tmp_path / "model"
    model_path.mkdir()
    worker_threads = []

    def load(path):
        worker_threads.append(get_ident())
        return object(), FakeTokenizer()

    def generate(model, tokenizer, prompt, *, max_tokens):
        worker_threads.append(get_ident())
        return "你好。"

    engine = MLXTranslator(model_path, model_loader=load, text_generator=generate)
    engine.prepare()
    with ThreadPoolExecutor(max_workers=1) as pool:
        result = pool.submit(engine.translate, request()).result()
    assert result.target_text == "你好。"
    assert worker_threads[0] == worker_threads[1]
    assert worker_threads[0] != get_ident()
    engine.close()
    engine.close()
