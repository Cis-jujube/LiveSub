"""Native-route identity, terminology, pipe limits and child lifecycle checks."""

from concurrent.futures import ThreadPoolExecutor
import errno
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

from livesub.translation.apple_engine import AppleTranslator
from livesub.translation.base import (
    TranslationError, TranslationInputTooLong, TranslationOutputTooLong, TranslationRequest,
)


class Tokenizer:
    def encode(self, text, *, add_special_tokens):
        assert not add_special_tokens
        return SimpleNamespace(ids=text.split())


def request(text, revision=1, generation=0):
    return TranslationRequest("session", generation, "segment", revision, "en", "zh", text)


@pytest.fixture
def native(tmp_path):
    helper = tmp_path / "helper"
    log = tmp_path / "requests.jsonl"
    helper.write_text(f"#!{sys.executable}\n" + """
import json, sys, time
for line in sys.stdin:
    item = json.loads(line)
    with open(LOG, 'a') as stream:
        stream.write(json.dumps(item) + '\\n')
    reply = {'id': item['id']}
    if item['operation'] == 'prepare':
        reply['ready'] = True
    else:
        source = ''.join(part['text'] for part in item['parts'])
        if source.startswith('TIMEOUT'):
            time.sleep(2)
        if source.startswith('EXIT'):
            sys.exit(0)
        if source.startswith('WRONG_ID'):
            reply['id'] += 1
        if source.startswith('MALFORMED'):
            print('{invalid', flush=True)
            continue
        if source.startswith('OVERSIZE'):
            print('x' * 65536, flush=True)
            continue
        if source.startswith('EMPTY'):
            source = ''
        if source.startswith('DROP'):
            source = source.replace('AI Agent', '')
        if source.startswith('DUPLICATE'):
            source += ' AI Agent'
        if source.startswith('LONG_OUTPUT'):
            source = 'word ' * 257
        reply['translation'] = source
    print(json.dumps(reply, ensure_ascii=False), flush=True)
""".replace("LOG", repr(str(log))))
    helper.chmod(0o700)
    config = tmp_path / "terms.json"
    engine = AppleTranslator(helper, tmp_path / "model", terminology_path=config,
                             tokenizer_loader=lambda path: Tokenizer(), request_timeout=0.08)
    yield engine, config, log
    engine.close()


def test_dictionary_returns_preferred_term_and_punctuation(native):
    engine, config, log = native
    config.write_text(json.dumps({"version": 2, "domains": ["software"], "entries": []}))
    result = engine.translate(request("Observability!", revision=9))
    assert result.target_text == "可观测性！"
    assert result.translated_source_text == "Observability!"
    assert result.source_revision == 9
    assert [json.loads(line)['operation'] for line in log.read_text().splitlines()] == ["prepare"]


def test_repeated_source_rebuilds_identity_and_settings(native):
    engine, config, log = native
    config.write_text(json.dumps({"version": 2, "domains": [], "entries": [
        {"source_language": "en", "source": "Jujube", "target": "枣枣"}]}))
    first = engine.translate(request("Jujube says hello.", revision=1))
    second = engine.translate(request("Jujube says hello.", revision=2))
    assert first.target_text == second.target_text == "枣枣 says hello."
    assert second.source_revision == 2
    assert len(log.read_text().splitlines()) == 2
    config.write_text(json.dumps({"version": 2, "domains": [], "entries": [
        {"source_language": "en", "source": "Jujube", "target": "朱朱"}]}))
    third = engine.translate(request("Jujube says hello.", revision=3))
    assert third.target_text == "朱朱 says hello."
    assert len(log.read_text().splitlines()) == 3


def test_overlapping_target_names_are_counted_separately(native):
    engine, _, _ = native
    result = engine.translate(request("An AI agent asks another software agent to wait."))
    assert result.target_text == "An AI Agent asks another software Agent to wait."


@pytest.mark.parametrize("source", ["DROP AI agent", "DUPLICATE AI agent", "EMPTY"])
def test_invalid_native_output_cannot_succeed(native, source):
    engine, _, _ = native
    with pytest.raises(TranslationError):
        engine.translate(request(source))


@pytest.mark.parametrize("source", ["TIMEOUT", "EXIT", "WRONG_ID", "MALFORMED", "OVERSIZE"])
def test_failed_rpc_stops_and_reaps_child(native, source):
    engine, _, _ = native
    engine.prepare()
    process = engine._process
    with pytest.raises(TranslationError):
        engine.translate(request(source))
    assert process.poll() is not None
    assert engine._process is None


def test_budgets_are_enforced(native):
    engine, _, log = native
    with pytest.raises(TranslationInputTooLong):
        engine.translate(request("word " * 2049))
    assert len(log.read_text().splitlines()) == 1
    with pytest.raises(TranslationOutputTooLong):
        engine.translate(request("LONG_OUTPUT"))


def test_empty_source_needs_no_child_and_close_is_final(native):
    engine, _, _ = native
    assert engine.translate(request("  ")).target_text == ""
    assert engine._process is None
    engine.prepare()
    process = engine._process
    engine.close()
    assert process.poll() is not None
    with pytest.raises(TranslationError, match="closed"):
        engine.translate(request("Hello."))


def test_concurrent_requests_keep_their_own_revisions(native):
    engine, _, _ = native
    items = [request(f"Sentence {i}.", revision=i) for i in range(1, 7)]
    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(engine.translate, items))
    assert [(r.target_text, r.source_revision) for r in results] == [(r.source_text, r.source_revision) for r in items]


def test_advisory_pipe_readiness_retries_eagain_without_duplicate_requests(native, monkeypatch):
    from livesub.translation import apple_engine

    engine, _, log = native
    engine.prepare()
    write_fd, read_fd = engine._process.stdin.fileno(), engine._process.stdout.fileno()
    write, read = apple_engine.os.write, apple_engine.os.read
    failures = {"write": 1, "read": 1}

    def transient_write(fd, data):
        if fd == write_fd and failures["write"]:
            failures["write"] -= 1
            raise BlockingIOError(errno.EAGAIN, "fixture would block")
        return write(fd, data)

    def transient_read(fd, size):
        if fd == read_fd and failures["read"]:
            failures["read"] -= 1
            raise BlockingIOError(errno.EAGAIN, "fixture would block")
        return read(fd, size)

    monkeypatch.setattr(apple_engine.os, "write", transient_write)
    monkeypatch.setattr(apple_engine.os, "read", transient_read)
    result = engine.translate(request("Keep 42 files.", revision=8))
    assert result.target_text == "Keep 42 files." and result.source_revision == 8
    assert failures == {"write": 0, "read": 0}
    assert [json.loads(line)['id'] for line in log.read_text().splitlines()] == [1, 2]
