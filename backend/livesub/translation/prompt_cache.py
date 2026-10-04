"""Reuse only a matching prompt prefix between local translation requests."""


def _greedy_api():
    import mlx.core as mx
    from mlx_lm.generate import generation_stream, wired_limit
    from mlx_lm.models.cache import make_prompt_cache
    from mlx_lm.tokenizer_utils import TokenizerWrapper

    return mx, generation_stream, wired_limit, make_prompt_cache, TokenizerWrapper


def _generate_text(model, tokenizer, *, prompt, max_tokens, verbose=False, prompt_cache=None):
    """Generate the complete greedy text without streaming-only vocabulary work.

    LiveSub consumes one complete translation. mlx-lm's streaming interface also
    builds a vocabulary detokenizer, normalizes every vocabulary logit, and
    reports timing per token. None of those values are consumed here. Keep its
    prompt prefill, one-token lookahead, EOS set, and stream synchronization;
    Greedy argmax avoids normalization; output parity is checked separately
    because finite-precision subtraction can round close logits into a tie.
    """
    mx, stream, wired_limit, make_cache, wrapper = _greedy_api()
    if not isinstance(tokenizer, wrapper):
        tokenizer = wrapper(tokenizer)
    if isinstance(prompt, str):
        special = tokenizer.bos_token is None or not prompt.startswith(tokenizer.bos_token)
        prompt = tokenizer.encode(prompt, add_special_tokens=special)
    if not isinstance(prompt, mx.array):
        prompt = mx.array(prompt)
    if len(prompt) == 0 or max_tokens < 1:
        raise ValueError("generation requires a nonempty prompt and a positive token limit")
    if prompt_cache is None:
        prompt_cache = make_cache(model)

    def step(tokens):
        logits = model(tokens[None], cache=prompt_cache)[:, -1, :]
        return mx.argmax(logits, axis=-1)

    output_tokens = []
    # Keep the upstream scoped wired limit. In particular, drain asynchronous
    # lookahead before releasing the session's shared ASR/translation lock.
    with wired_limit(model, [stream]), mx.stream(stream):
        while len(prompt) > 1:
            size = min(2048, len(prompt) - 1)
            model(prompt[:size][None], cache=prompt_cache)
            mx.eval([layer.state for layer in prompt_cache])
            prompt = prompt[size:]
        current = step(prompt)
        mx.async_eval(current)
        for index in range(max_tokens):
            following = step(current)
            mx.async_eval(following)
            token = current.item()
            if token in tokenizer.eos_token_ids:
                break
            output_tokens.append(token)
            current = following
        # Reuse small allocation buffers across subtitle requests, but bound
        # the allocator cache independently of the retained prompt KV cache.
        if mx.get_cache_memory() > 256 * 1024**2:
            mx.clear_cache()
    return tokenizer.decode(output_tokens)


def _generation_api():
    from mlx_lm import generate

    try:
        from mlx_lm.models.cache import (
            can_trim_prompt_cache,
            make_prompt_cache,
            trim_prompt_cache,
        )
    except ImportError:
        return generate, None, None, None
    return _generate_text, make_prompt_cache, can_trim_prompt_cache, trim_prompt_cache


class PromptCachedGenerator:
    """One worker-owned cache, containing prompt tokens and never prior output."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self._cache = None
        self._tokens: list[int] = []
        self._model = None
        self._tokenizer = None

    def __call__(self, model, tokenizer, prompt: str, *, max_tokens: int) -> str:
        try:
            return self._generate(model, tokenizer, prompt, max_tokens=max_tokens)
        except Exception:
            # Generation can fail after mutating some of the layer caches.
            self.reset()
            raise

    def _generate(self, model, tokenizer, prompt: str, *, max_tokens: int) -> str:
        generate, make_cache, can_trim, trim_cache = _generation_api()
        if make_cache is None:
            self.reset()
            return generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=False)

        if model is not self._model or tokenizer is not self._tokenizer:
            self.reset()

        # Match mlx-lm's string-prompt tokenization, including its BOS rule.
        add_special_tokens = tokenizer.bos_token is None or not prompt.startswith(tokenizer.bos_token)
        tokens = tokenizer.encode(prompt, add_special_tokens=add_special_tokens)
        if not tokens:
            self.reset()
            return generate(model, tokenizer, prompt=prompt, max_tokens=max_tokens, verbose=False)

        if self._cache is None:
            self._cache = make_cache(model)
            self._model = model
            self._tokenizer = tokenizer

        if not can_trim(self._cache) or not self._has_length(len(self._tokens)):
            self.reset()
            return generate(model, tokenizer, prompt=tokens, max_tokens=max_tokens, verbose=False)

        common = 0
        # Leave one token for generate_step, which requires a nonempty prompt.
        for previous, current in zip(self._tokens, tokens[:-1]):
            if previous != current:
                break
            common += 1
        if not self._trim_to(common, trim_cache):
            self.reset()
            return generate(model, tokenizer, prompt=tokens, max_tokens=max_tokens, verbose=False)

        output = generate(
            model, tokenizer, prompt=tokens[common:], prompt_cache=self._cache,
            max_tokens=max_tokens, verbose=False,
        )
        # MLX also caches generated/lookahead tokens. Inspect actual layer
        # lengths instead of inferring that tail from the returned text.
        retained = len(tokens) - 1
        if can_trim(self._cache) and self._trim_to(retained, trim_cache):
            self._tokens = tokens[:-1]
        else:
            self.reset()
        return output

    def _has_length(self, length: int) -> bool:
        try:
            return bool(self._cache) and all(len(layer) == length for layer in self._cache)
        except TypeError:
            return False

    def _trim_to(self, length: int, trim_cache) -> bool:
        try:
            current = len(self._cache[0])
        except (IndexError, TypeError):
            return False
        if current < length or not self._has_length(current):
            return False
        count = current - length
        return (count == 0 or trim_cache(self._cache, count) == count) and self._has_length(length)
