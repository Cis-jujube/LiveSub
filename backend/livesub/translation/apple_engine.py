"""English subtitles through an app-owned offline Apple translation helper."""

import json
import os
from pathlib import Path
import select
import subprocess
from threading import RLock
from time import monotonic
from typing import Callable

from .base import (
    ModelUnavailable, TranslationError, TranslationInputTooLong,
    TranslationOutputTooLong, TranslationRequest, TranslationResult,
)
from .mlx_engine import MAX_CONTEXT_PAIRS, MAX_CONTEXT_TOKENS, MAX_INPUT_TOKENS, MAX_OUTPUT_TOKENS
from .terminology import ProtectedTerms, Terminology

MAX_PACKET_BYTES = 65_536


def _load_tokenizer(model_path: Path):
    # Reuse the installed tokenizer and its budgets without loading Qwen weights.
    from tokenizers import Tokenizer

    return Tokenizer.from_file(str(model_path / "tokenizer.json"))


class AppleTranslator:
    """Serialized private pipe RPC; no downloads, sockets or background service."""

    def __init__(self, helper_path: Path, model_path: Path, *,
                 terminology_path: Path | None = None,
                 tokenizer_loader: Callable = _load_tokenizer,
                 request_timeout: float = 3.0) -> None:
        self.helper_path = helper_path
        self.model_path = model_path
        self._terminology = Terminology(terminology_path)
        self._tokenizer_loader = tokenizer_loader
        self._tokenizer = None
        self._timeout = request_timeout
        self._process: subprocess.Popen | None = None
        self._lock = RLock()
        self._sequence = 0
        self._closed = False
        self._ready = False
        self._last_translation = None

    def prepare(self) -> None:
        with self._lock:
            if self._closed:
                raise TranslationError("native translation worker has closed")
            if self._ready:
                return
            if not self.helper_path.is_file() or not os.access(self.helper_path, os.X_OK):
                raise ModelUnavailable("native translation helper is unavailable")
            if self._tokenizer is None:
                try:
                    self._tokenizer = self._tokenizer_loader(self.model_path)
                except (OSError, ValueError) as error:
                    raise ModelUnavailable("local translation tokenizer is unavailable") from error
            self._process = subprocess.Popen(
                [str(self.helper_path.resolve())], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
            )
            os.set_blocking(self._process.stdin.fileno(), False)
            os.set_blocking(self._process.stdout.fileno(), False)
            try:
                reply = self._exchange({"operation": "prepare"}, timeout=20.0)
                if reply.get("ready") is not True:
                    raise ModelUnavailable("offline English/Chinese translation is unavailable")
                self._ready = True
            except Exception:
                self._stop_child()
                raise

    def translate(self, request: TranslationRequest) -> TranslationResult:
        source = request.source_text.strip()
        if not source:
            return self._result(request, source, "")
        if request.source_language != "en" or request.target_language != "zh":
            raise TranslationError("native subtitle route supports English to Chinese only")
        with self._lock:
            self.prepare()
            if self._token_count(source) > MAX_INPUT_TOKENS:
                raise TranslationInputTooLong("translation input exceeded 2048 tokens")
            context = []
            for pair in reversed(request.confirmed_context[-MAX_CONTEXT_PAIRS:]):
                candidate = [pair.source_text, *context]
                if self._token_count(json.dumps(candidate, ensure_ascii=False)) > MAX_CONTEXT_TOKENS:
                    break
                context = candidate
            spans = self._terminology.spans("en", source, context)
            protection = ProtectedTerms(source, spans, [])
            direct = protection.term_only_output()
            if direct is not None:
                output = protection.restore(direct)
            else:
                parts = []
                cursor = 0
                for start, end, entry in spans:
                    if start > cursor:
                        parts.append({"text": source[cursor:start], "protected": False})
                    parts.append({"text": entry.target, "protected": True})
                    cursor = end
                if cursor < len(source):
                    parts.append({"text": source[cursor:], "protected": False})
                if self._token_count("".join(part["text"] for part in parts)) > MAX_INPUT_TOKENS:
                    raise TranslationInputTooLong("protected translation input exceeded 2048 tokens")
                key = (request.session_id, request.generation, request.segment_id,
                       source, json.dumps(parts, ensure_ascii=False),
                       json.dumps(protection.replacements, ensure_ascii=False, sort_keys=True))
                if self._last_translation is not None and self._last_translation[0] == key:
                    output = self._last_translation[1]
                else:
                    reply = self._exchange({"operation": "translate", "source_language": "en", "parts": parts},
                                           timeout=self._timeout)
                    output = reply.get("translation")
                    if not isinstance(output, str) or not output.strip():
                        raise TranslationError("native engine returned no translation")
                    # Native attribute ranges are not relied on as evidence.
                    # Match longer targets first so "Agent" is not counted
                    # inside a separately protected "AI Agent" occurrence.
                    expected = [part["text"] for part in parts if part["protected"]]
                    remaining = output
                    for target in sorted(set(expected), key=len, reverse=True):
                        if remaining.count(target) != expected.count(target):
                            raise TranslationError("native engine did not preserve preferred term counts")
                        remaining = remaining.replace(target, "")
                    output = output.strip()
                    self._last_translation = (key, output)
            if self._token_count(output) > MAX_OUTPUT_TOKENS:
                raise TranslationOutputTooLong("translation output exceeded 256 tokens")
            return self._result(request, source, output)

    def _token_count(self, text: str) -> int:
        return len(self._tokenizer.encode(text, add_special_tokens=False).ids)

    def preview_interval_seconds(self, source_language: str) -> float | None:
        return 0.1 if self._ready and source_language == "en" else None

    def _exchange(self, payload: dict, *, timeout: float) -> dict:
        process = self._process
        if process is None or process.poll() is not None:
            raise TranslationError("native translation helper exited")
        self._sequence += 1
        packet = (json.dumps({"id": self._sequence, **payload}, ensure_ascii=False) + "\n").encode()
        if len(packet) >= MAX_PACKET_BYTES:
            raise TranslationInputTooLong("native translation packet exceeded its limit")
        deadline = monotonic() + timeout
        received = bytearray()
        sent = 0
        try:
            while True:
                remaining = deadline - monotonic()
                if remaining <= 0:
                    raise TranslationError("native translation timed out")
                readable, writable, _ = select.select(
                    [process.stdout], [process.stdin] if sent < len(packet) else [], [], remaining,
                )
                if writable:
                    try:
                        sent += os.write(process.stdin.fileno(), packet[sent:sent + 4096])
                    except BlockingIOError:
                        # Readiness is advisory; retry a transient EAGAIN under
                        # the original deadline, without sending bytes twice.
                        pass
                if readable:
                    try:
                        chunk = os.read(process.stdout.fileno(), 4096)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        raise TranslationError("native translation helper closed its pipe")
                    received.extend(chunk)
                    if len(received) >= MAX_PACKET_BYTES:
                        raise TranslationError("native translation reply exceeded its limit")
                    if b"\n" in received:
                        line, trailing = received.split(b"\n", 1)
                        if trailing or sent != len(packet):
                            raise TranslationError("native translation reply was out of order")
                        reply = json.loads(line)
                        if (not isinstance(reply, dict) or type(reply.get("id")) is not int
                                or reply["id"] != self._sequence or reply.get("error")):
                            raise TranslationError("native translation request failed")
                        return reply
        except (OSError, ValueError, TranslationError) as error:
            self._stop_child()
            if isinstance(error, TranslationError):
                raise
            raise TranslationError("native translation pipe failed") from error

    def _stop_child(self) -> None:
        process, self._process = self._process, None
        self._ready = False
        self._last_translation = None
        if process is None:
            return
        process.stdin.close()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        finally:
            process.stdout.close()

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._stop_child()

    @staticmethod
    def _result(request: TranslationRequest, source: str, target: str) -> TranslationResult:
        return TranslationResult(request.session_id, request.generation, request.segment_id,
                                 request.source_revision, request.source_language, request.target_language,
                                 source, target)
