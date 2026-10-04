from dataclasses import dataclass

import numpy as np
import pytest

from livesub.asr.qwen import QwenASREngine


@dataclass
class Result:
    text: str


class FakeTranscriber:
    def __init__(self):
        self.calls = []

    def transcribe(self, *, audio: tuple[np.ndarray, int], language: str):
        samples, rate = audio
        self.calls.append((len(samples), rate, language))
        return [Result(f"heard {len(samples)}")]


def test_previews_replace_and_final_uses_complete_audio():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="English", preview_ms=1_000, max_segment_ms=3_000)
    engine.start(sample_rate=16_000)
    speech = np.full(16_000, 1000, dtype="<i2").tobytes()
    first = engine.push(speech)
    assert [(event.text, event.final, event.end_ms) for event in first] == [("heard 16000", False, 1_000)]
    second = engine.push(speech)
    assert [(event.text, event.final, event.end_ms) for event in second] == [("heard 32000", False, 2_000)]
    third = engine.push(speech)
    assert [(event.text, event.final, event.start_ms, event.end_ms) for event in third] == [
        ("heard 48000", True, 0, 3_000)
    ]
    assert engine.push(speech)[0].start_ms == 3_000
    calls_before_final = len(fake.calls)
    assert engine.finish()[0].text == "heard 16000"
    assert len(fake.calls) == calls_before_final
    assert all(rate == 16_000 and language == "English" for _, rate, language in fake.calls)


def test_reset_retains_loaded_model_and_language_changes_only_between_streams():
    fake = FakeTranscriber()
    loaded = []

    def factory():
        loaded.append(True)
        return fake

    engine = QwenASREngine(factory, language="Chinese", preview_ms=1_000)
    engine.start(sample_rate=16_000)
    with pytest.raises(RuntimeError):
        engine.set_language("English")
    engine.reset()
    engine.set_language("English")
    engine.start(sample_rate=16_000)
    assert engine.finish() == []
    assert len(loaded) == 1


def test_final_redecodes_when_audio_arrives_after_preview():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="English", preview_ms=1_000)
    engine.start(sample_rate=16_000)
    speech = np.full(16_000, 1000, dtype="<i2").tobytes()
    assert engine.push(speech)[0].text == "heard 16000"
    assert engine.push(speech[:8_000]) == []
    assert engine.finish()[0].text == "heard 20000"
    assert [count for count, _, _ in fake.calls] == [16_000, 20_000]


def test_digital_silence_skips_obsolete_preview_but_final_decodes_all_samples():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="English", preview_ms=800)
    engine.start(sample_rate=16_000)
    speech = np.full(12_800, 1000, dtype="<i2").tobytes()
    assert engine.push(speech)[0].text == "heard 12800"
    assert engine.push(bytes(25_600)) == []
    assert engine.push(bytes(25_600)) == []
    assert [count for count, _, _ in fake.calls] == [12_800]
    final = engine.finish()[0]
    assert (final.text, final.start_ms, final.end_ms, final.final) == ("heard 38400", 0, 2_400, True)
    assert [count for count, _, _ in fake.calls] == [12_800, 38_400]


def test_quiet_nonzero_audio_still_revises_preview_and_is_not_treated_as_zero():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="English", preview_ms=800)
    engine.start(sample_rate=16_000)
    assert engine.push(np.full(12_800, 1000, dtype="<i2").tobytes())
    # Even samples below the speech threshold can contain a quiet tail. The
    # optimization must only skip digital zero, without widening the VAD gate.
    quiet = np.full(12_800, 1, dtype="<i2").tobytes()
    assert engine.push(quiet)[0].text == "heard 25600"
    assert [count for count, _, _ in fake.calls] == [12_800, 25_600]
    assert engine.finish()[0].end_ms == 1_600
    assert len(fake.calls) == 2


def test_catch_up_speech_followed_by_zero_still_emits_latest_preview():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="English", preview_ms=800)
    engine.start(sample_rate=16_000)
    assert engine.push_without_preview(np.full(12_800, 1000, dtype="<i2").tobytes()) == []
    preview = engine.push(bytes(5_120))[0]
    assert (preview.text, preview.end_ms) == ("heard 15360", 960)
    assert engine.finish()[0].end_ms == 960
    assert len(fake.calls) == 1


def test_segment_limit_final_still_decodes_digital_silence_tail():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="English", preview_ms=800, max_segment_ms=1_600)
    engine.start(sample_rate=16_000)
    assert engine.push(np.full(12_800, 1000, dtype="<i2").tobytes())
    final = engine.push(bytes(25_600))[0]
    assert (final.text, final.end_ms, final.final) == ("heard 25600", 1_600, True)
    assert [count for count, _, _ in fake.calls] == [12_800, 25_600]
    assert engine.push(np.full(12_800, 1000, dtype="<i2").tobytes())[0].start_ms == 1_600


def test_rejects_invalid_audio_and_rate():
    engine = QwenASREngine(FakeTranscriber, language="English")
    with pytest.raises(ValueError):
        engine.start(sample_rate=44_100)
    engine.start(sample_rate=16_000)
    with pytest.raises(ValueError):
        engine.push(b"\x00")


def test_silence_does_not_trigger_hallucinated_model_output():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="Chinese", preview_ms=1_000, max_segment_ms=3_000)
    engine.start(sample_rate=16_000)
    assert engine.push(bytes(16_000 * 2 * 3)) == []
    assert engine.finish() == []
    assert fake.calls == []


def test_default_preview_arrives_at_800_ms_without_discarding_audio():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="English")
    engine.start(sample_rate=16_000)
    frame = np.full(2_560, 1000, dtype="<i2").tobytes()
    for _ in range(4):
        assert engine.push(frame) == []
    assert engine.push(frame)[0].end_ms == 800
    assert fake.calls[0][0] == 12_800


def test_catch_up_skips_previews_but_keeps_audio_finals_and_timestamps():
    fake = FakeTranscriber()
    engine = QwenASREngine(lambda: fake, language="English", preview_ms=800, max_segment_ms=3_000)
    engine.start(sample_rate=16_000)
    speech = np.full(16_000, 1000, dtype="<i2").tobytes()
    assert engine.push_without_preview(speech * 2) == []
    assert fake.calls == []
    final = engine.push_without_preview(speech)[0]
    assert (final.start_ms, final.end_ms, final.final) == (0, 3_000, True)
    assert engine.push_without_preview(speech) == []
    latest = engine.push(speech)[0]
    assert (latest.start_ms, latest.end_ms, latest.final) == (3_000, 5_000, False)
    assert [count for count, _, _ in fake.calls] == [48_000, 32_000]
    assert engine.finish()[0].text == latest.text
    assert len(fake.calls) == 2
