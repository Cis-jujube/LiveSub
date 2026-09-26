"""Lifecycle and revision regressions for the native R2T2 adapter.

These tests use a deterministic model double. Real model recognition is covered
by the separate smoke command and is never counted as a unit-test pass.
"""

from dataclasses import dataclass

import pytest

from livesub.asr.base import ASREvent
from livesub.asr.r2t2 import R2T2ASREngine


FRAME = b"\x00\x02" * 2_560  # 160 ms of non-silent 16 kHz PCM16


@dataclass
class State:
    index: int


class FakeModel:
    def __init__(self, previews: list[str], final_text: str) -> None:
        self.previews = previews
        self.final_text = final_text
        self.states = 0
        self.calls = 0
        self.seen_samples: list[int] = []
        self.languages: list[str] = []

    def init_streaming_state(self, **kwargs: object) -> State:
        self.states += 1
        self.languages.append(str(kwargs["language"]))
        return State(self.states)

    def streaming_transcribe(self, samples: object, state: State) -> tuple[str, str]:
        self.seen_samples.append(len(samples))
        text = self.previews[self.calls]
        self.calls += 1
        # Upstream's supposed fixed text can shrink or be empty on a tail call.
        fixed = text if self.calls < 3 else ""
        return text, fixed

    def finish_streaming_transcribe(self, state: State) -> str:
        return self.final_text


def test_empty_input_and_invalid_pcm() -> None:
    model = FakeModel([], "")
    engine = R2T2ASREngine(lambda: model, language="English")
    with pytest.raises(ValueError, match="16 kHz"):
        engine.start(sample_rate=48_000)
    engine.start(sample_rate=16_000)
    assert engine.push(b"") == []
    with pytest.raises(ValueError, match="complete samples"):
        engine.push(b"\x00")
    assert engine.finish() == []
    assert model.calls == 0


def test_revisable_cumulative_preview_and_final_tail() -> None:
    model = FakeModel(["hello world", "hello", "hello"], "hello there")
    engine = R2T2ASREngine(lambda: model, language="English")
    engine.start(sample_rate=16_000)
    assert engine.push(FRAME) == [
        ASREvent("hello world", 0, 160, final=False)
    ]
    assert engine.push(FRAME) == [ASREvent("hello", 0, 320, final=False)]
    assert engine.push(FRAME) == []
    assert engine.finish() == [ASREvent("hello there", 0, 480, final=True)]
    assert model.seen_samples == [2_560, 2_560, 2_560]


def test_empty_transient_hypothesis_does_not_erase_spoken_preview() -> None:
    model = FakeModel(["spoken words", ""], "")
    engine = R2T2ASREngine(lambda: model, language="English")
    engine.start(sample_rate=16_000)
    assert engine.push(FRAME) == [
        ASREvent("spoken words", 0, 160, final=False)
    ]
    assert engine.push(FRAME) == []
    assert engine.finish() == [
        ASREvent("spoken words", 0, 320, final=True)
    ]


def test_start_after_finish_starts_new_clock_and_reuses_loaded_model() -> None:
    model = FakeModel(["first", "second"], "done")
    loads = 0

    def factory() -> FakeModel:
        nonlocal loads
        loads += 1
        return model

    engine = R2T2ASREngine(factory, language="English")
    engine.start(sample_rate=16_000)
    assert engine.push(FRAME) == [ASREvent("first", 0, 160, final=False)]
    assert engine.finish() == [ASREvent("done", 0, 160, final=True)]
    engine.start(sample_rate=16_000)
    assert engine.push(FRAME) == [ASREvent("second", 0, 160, final=False)]
    assert loads == 1


def test_language_switch_requires_flush_and_does_not_reload_model() -> None:
    model = FakeModel(["old", "新"], "done")
    loads = 0

    def factory() -> FakeModel:
        nonlocal loads
        loads += 1
        return model

    engine = R2T2ASREngine(factory, language="English")
    engine.start(sample_rate=16_000)
    engine.push(FRAME)
    with pytest.raises(RuntimeError, match="finish"):
        engine.set_language("Chinese")
    engine.finish()
    engine.set_language("Chinese")
    engine.start(sample_rate=16_000)
    assert engine.push(FRAME) == [ASREvent("新", 0, 160, final=False)]
    assert model.languages == ["English", "Chinese"]
    assert loads == 1


def test_six_second_window_rolls_state_without_reloading_model() -> None:
    model = FakeModel(["first", "first part", "second"], "finished")
    factory_calls = 0

    def factory() -> FakeModel:
        nonlocal factory_calls
        factory_calls += 1
        return model

    engine = R2T2ASREngine(
        factory, language="English", max_segment_ms=320
    )
    engine.start(sample_rate=16_000)
    assert engine.push(FRAME) == [ASREvent("first", 0, 160, final=False)]
    assert engine.push(FRAME) == [
        ASREvent("first part", 0, 320, final=False),
        ASREvent("finished", 0, 320, final=True),
    ]
    assert engine.push(FRAME) == [ASREvent("second", 320, 480, final=False)]
    engine.reset()
    engine.start(sample_rate=16_000)
    assert engine.finish() == []
    assert factory_calls == 1
    assert model.states == 3
