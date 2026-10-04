"""Verify reused KV prefixes describe exactly the next complete prompt."""

from dataclasses import replace
from contextlib import nullcontext
from threading import get_ident

import numpy as np
import pytest

from livesub.translation import mlx_engine, prompt_cache
from livesub.translation.base import TranslationError, TranslationRequest
from livesub.translation.prompt_cache import PromptCachedGenerator


class Tokenizer:
    bos_token = None

    def encode(self, text, *, add_special_tokens):
        # Two-character tokens make appending a character revise the last token.
        tokens = [int.from_bytes(text[index:index + 2].encode(), "big")
                  for index in range(0, len(text), 2)]
        return ([999_999] if add_special_tokens else []) + tokens

    def apply_chat_template(self, messages, **kwargs):
        return "\n".join(message["content"] for message in messages)


class CacheLayer:
    def __init__(self):
        self.tokens = []

    def __len__(self):
        return len(self.tokens)


class GenerationAPI:
    def __init__(self, monkeypatch):
        self.calls = []
        self.trimmable = True
        self.partial_trim = False
        self.fail = False
        self.available = True
        monkeypatch.setattr(prompt_cache, "_generation_api", self.api)

    def api(self):
        if not self.available:
            return self.generate, None, None, None
        return self.generate, self.make_cache, self.can_trim, self.trim_cache

    @staticmethod
    def make_cache(model):
        return [CacheLayer(), CacheLayer()]

    def can_trim(self, cache):
        return self.trimmable

    def trim_cache(self, cache, count):
        removed = max(0, count - 1) if self.partial_trim else count
        if removed:
            for layer in cache:
                del layer.tokens[-removed:]
        return removed

    def generate(self, model, tokenizer, *, prompt, max_tokens, verbose, prompt_cache=None):
        assert max_tokens == 256 and verbose is False
        if isinstance(prompt, str):
            special = tokenizer.bos_token is None or not prompt.startswith(tokenizer.bos_token)
            prompt = tokenizer.encode(prompt, add_special_tokens=special)
        assert prompt  # MLX rejects an empty suffix.
        retained = list(prompt_cache[0].tokens) if prompt_cache else []
        if prompt_cache:
            assert all(layer.tokens == retained for layer in prompt_cache)
        self.calls.append((retained, list(prompt)))
        if prompt_cache:
            for layer in prompt_cache:
                # Include lookahead that is not represented in returned text.
                layer.tokens.extend([*prompt, 9_100, 9_101, 9_102])
        if self.fail:
            raise RuntimeError("generation failed after cache mutation")
        return "translated"


def full_tokens(tokenizer, prompt):
    special = tokenizer.bos_token is None or not prompt.startswith(tokenizer.bos_token)
    return tokenizer.encode(prompt, add_special_tokens=special)


def test_append_revision_shrink_and_identical_prompts_keep_exact_context(monkeypatch):
    api = GenerationAPI(monkeypatch)
    generator = PromptCachedGenerator()
    model, tokenizer = object(), Tokenizer()
    prompts = ["prefix a", "prefix ab", "prefix acd", "prefix a", "prefix a", "other prompt"]
    for prompt in prompts:
        assert generator(model, tokenizer, prompt, max_tokens=256) == "translated"
        retained, suffix = api.calls[-1]
        assert retained + suffix == full_tokens(tokenizer, prompt)
        assert generator._tokens == full_tokens(tokenizer, prompt)[:-1]
        assert all(layer.tokens == generator._tokens for layer in generator._cache)
    assert api.calls[0][0] == []
    assert api.calls[1][0]  # Shared work is actually reused.
    assert len(api.calls[4][1]) == 1  # Identical prompt still supplies one token.


@pytest.mark.parametrize(("bos", "prompt"), [(None, "hello"), ("<s>", "hello"), ("<s>", "<s>hello")])
def test_tokenization_matches_mlx_bos_behavior(monkeypatch, bos, prompt):
    api = GenerationAPI(monkeypatch)
    generator = PromptCachedGenerator()
    tokenizer = Tokenizer()
    tokenizer.bos_token = bos
    generator(object(), tokenizer, prompt, max_tokens=256)
    assert api.calls[0][1] == full_tokens(tokenizer, prompt)


def test_generation_failure_discards_partial_cache_before_retry(monkeypatch):
    api = GenerationAPI(monkeypatch)
    generator = PromptCachedGenerator()
    model, tokenizer = object(), Tokenizer()
    generator(model, tokenizer, "prefix first", max_tokens=256)
    api.fail = True
    with pytest.raises(RuntimeError, match="after cache mutation"):
        generator(model, tokenizer, "prefix second", max_tokens=256)
    assert generator._cache is None
    api.fail = False
    generator(model, tokenizer, "prefix second", max_tokens=256)
    assert api.calls[-1] == ([], full_tokens(tokenizer, "prefix second"))


@pytest.mark.parametrize("unsupported", ["unavailable", "not_trimmable", "partial_trim", "unequal_layers"])
def test_unsupported_cache_falls_back_to_complete_prompt(monkeypatch, unsupported):
    api = GenerationAPI(monkeypatch)
    generator = PromptCachedGenerator()
    model, tokenizer = object(), Tokenizer()
    generator(model, tokenizer, "prefix first", max_tokens=256)
    if unsupported == "unavailable":
        api.available = False
    elif unsupported == "not_trimmable":
        api.trimmable = False
    elif unsupported == "partial_trim":
        api.partial_trim = True
    else:
        generator._cache[1].tokens.append(123)
    prompt = "changed prefix"
    assert generator(model, tokenizer, prompt, max_tokens=256) == "translated"
    assert api.calls[-1] == ([], full_tokens(tokenizer, prompt))
    assert generator._cache is None


@pytest.mark.parametrize("change", ["reset", "model", "tokenizer"])
def test_explicit_reset_or_model_change_discards_previous_context(monkeypatch, change):
    api = GenerationAPI(monkeypatch)
    generator = PromptCachedGenerator()
    model, tokenizer = object(), Tokenizer()
    generator(model, tokenizer, "prefix first", max_tokens=256)
    if change == "reset":
        generator.reset()
    elif change == "model":
        model = object()
    else:
        tokenizer = Tokenizer()
    generator(model, tokenizer, "prefix second", max_tokens=256)
    assert api.calls[-1] == ([], full_tokens(tokenizer, "prefix second"))


def test_default_translator_resets_cache_identity_failure_and_close_on_worker(tmp_path, monkeypatch):
    class TracedGenerator:
        def __init__(self):
            self.resets = []
            self.calls = []
            self.output = "translated"

        def reset(self):
            self.resets.append(get_ident())

        def __call__(self, model, tokenizer, prompt, *, max_tokens):
            self.calls.append(get_ident())
            return self.output

    generator = TracedGenerator()
    monkeypatch.setattr(mlx_engine, "PromptCachedGenerator", lambda: generator)
    engine = mlx_engine.MLXTranslator(tmp_path, model_loader=lambda _: (object(), Tokenizer()),
                                      terminology_path=tmp_path / "absent-terminology.json")
    first = TranslationRequest("session", 1, "segment", 1, "en", "zh", "Hello")
    try:
        engine.translate(first)
        assert len(generator.resets) == 1
        final = engine.translate(replace(first, source_revision=2))
        assert final.source_revision == 2 and len(generator.calls) == 1
        engine.translate(replace(first, segment_id="next", source_text="Hello again"))
        assert len(generator.resets) == 1
        current = first
        for change in ({"session_id": "other"}, {"generation": 2},
                       {"source_language": "zh", "target_language": "en"}):
            current = replace(current, **change)
            before = len(generator.resets)
            engine.translate(current)
            assert len(generator.resets) == before + 1
        generator.output = ""
        before = len(generator.resets)
        with pytest.raises(TranslationError):
            engine.translate(replace(current, source_text="invalid output"))
        assert len(generator.resets) == before + 1
    finally:
        before = len(generator.resets)
        engine.close()
    assert len(generator.resets) == before + 1
    assert len(set(generator.resets + generator.calls)) == 1
    assert generator.resets[0] != get_ident()
    assert engine._last_generation is None


class FakeArray(np.ndarray):
    def __new__(cls, values, dtype=None):
        return np.asarray(values, dtype=dtype).view(cls)


class GreedyRuntime:
    """CPU-only array shim: tests token limits/EOS/cache work without Metal."""

    array = FakeArray
    uint32 = np.uint32

    def __init__(self):
        self.async_calls = 0
        self.cache_bytes = 0
        self.clears = 0
        self.scoped_streams = []

    @staticmethod
    def argmax(logits, *, axis):
        return FakeArray(np.argmax(logits, axis=axis))

    @staticmethod
    def concatenate(arrays):
        return FakeArray(np.concatenate(arrays))

    @staticmethod
    def eval(value):
        pass

    def async_eval(self, value):
        self.async_calls += 1

    def stream(self, stream):
        self.scoped_streams.append(stream)
        return nullcontext()

    def get_cache_memory(self):
        return self.cache_bytes

    def clear_cache(self):
        self.clears += 1


def greedy_fixture(monkeypatch, generated):
    mx = GreedyRuntime()
    stream = object()
    wired_calls = []
    layers = [CacheLayer(), CacheLayer()]

    class GreedyTokenizer:
        bos_token = None
        eos_token_ids = {0, 4}

        def __init__(self):
            self.encodes = []
            self.decodes = []

        def encode(self, text, *, add_special_tokens):
            self.encodes.append((text, add_special_tokens))
            return [10, 11, 12]

        def decode(self, tokens):
            self.decodes.append(tokens)
            return "".join({1: "你", 2: "好", 3: "。"}[token] for token in tokens)

    class Model:
        def __init__(self):
            self.calls = []

        def __call__(self, tokens, *, cache):
            self.calls.append(tokens.tolist()[0])
            for layer in cache:
                layer.tokens.extend(tokens.tolist()[0])
                layer.state = list(layer.tokens)
            # The multi-token prefill result is deliberately unused.
            logits = np.zeros((1, tokens.shape[1], 5))
            before = len(cache[0].tokens) - tokens.shape[1]
            for position in range(tokens.shape[1]):
                index = before + position + 1 - 3
                chosen = generated[min(max(0, index), len(generated) - 1)]
                logits[0, position, chosen] = 10
            return logits

    def wired_limit(model, streams):
        wired_calls.append(streams)
        return nullcontext()

    monkeypatch.setattr(prompt_cache, "_greedy_api", lambda: (
        mx, stream, wired_limit, lambda model: layers, GreedyTokenizer,
    ))
    return mx, Model(), GreedyTokenizer(), layers, wired_calls, stream


@pytest.mark.parametrize("eos", [0, 4])
def test_text_generator_stops_at_all_eos_and_decodes_once(monkeypatch, eos):
    mx, model, tokenizer, layers, wired_calls, stream = greedy_fixture(monkeypatch, [1, 2, eos])
    output = prompt_cache._generate_text(model, tokenizer, prompt="prompt", max_tokens=256)
    assert output == "你好"
    assert tokenizer.encodes == [("prompt", True)]
    assert tokenizer.decodes == [[1, 2]]
    assert model.calls[:2] == [[10, 11], [12]]
    assert len(model.calls) == 5  # Includes lookahead while checking EOS.
    assert wired_calls == [[stream]] and mx.scoped_streams == [stream]
    assert len(layers[0].tokens) == 6


def test_text_generator_keeps_token_cap_and_bounds_allocator_cache(monkeypatch):
    mx, model, tokenizer, layers, _, _ = greedy_fixture(monkeypatch, [1, 2, 3])
    mx.cache_bytes = 256 * 1024**2 + 1
    output = prompt_cache._generate_text(
        model, tokenizer, prompt=np.array([10, 11, 12]), max_tokens=2, prompt_cache=layers,
    )
    assert output == "你好" and tokenizer.decodes == [[1, 2]]
    assert tokenizer.encodes == []
    assert len(model.calls) == 4
    assert mx.clears == 1


@pytest.mark.parametrize(("bos", "prompt", "special"), [
    (None, "hello", True), ("<s>", "hello", True), ("<s>", "<s>hello", False),
])
def test_text_generator_preserves_bos_rule(monkeypatch, bos, prompt, special):
    _, model, tokenizer, _, _, _ = greedy_fixture(monkeypatch, [0])
    tokenizer.bos_token = bos
    assert prompt_cache._generate_text(model, tokenizer, prompt=prompt, max_tokens=1) == ""
    assert tokenizer.encodes == [(prompt, special)]


@pytest.mark.parametrize(("prompt", "limit"), [(np.array([]), 1), (np.array([1]), 0)])
def test_text_generator_rejects_empty_prompt_or_zero_limit(monkeypatch, prompt, limit):
    _, model, tokenizer, _, _, _ = greedy_fixture(monkeypatch, [0])
    with pytest.raises(ValueError, match="nonempty prompt"):
        prompt_cache._generate_text(model, tokenizer, prompt=prompt, max_tokens=limit)
