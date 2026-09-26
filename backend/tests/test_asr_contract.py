"""ASR lifecycle contract with a deterministic native-model double.

These checks verify adapter behavior, not model accuracy. A separate smoke
command runs downloaded weights against genuine spoken audio.
"""

from livesub.asr.base import ASREvent
from livesub.asr.r2t2 import R2T2ASREngine


class ContractModel:
    def init_streaming_state(self, **kwargs: object) -> dict[str, int]:
        return {"samples": 0}

    def streaming_transcribe(
        self, samples: object, state: dict[str, int]
    ) -> tuple[str, str]:
        state["samples"] += len(samples)
        return "", ""

    def finish_streaming_transcribe(self, state: dict[str, int]) -> str:
        return "last sentence" if state["samples"] else ""


def test_empty_input_emits_no_words() -> None:
    engine = R2T2ASREngine(ContractModel, language="English")
    engine.start(sample_rate=16_000)
    assert engine.finish() == []


def test_finish_emits_unflushed_tail() -> None:
    engine = R2T2ASREngine(ContractModel, language="English")
    engine.start(sample_rate=16_000)
    assert engine.push(b"\x00\x02" * 1_600) == []
    assert engine.finish() == [
        ASREvent("last sentence", start_ms=0, end_ms=100, final=True)
    ]


def test_reset_discards_old_audio_and_reuses_model() -> None:
    model = ContractModel()
    loads = 0

    def load_model() -> ContractModel:
        nonlocal loads
        loads += 1
        return model

    engine = R2T2ASREngine(load_model, language="English")
    engine.start(sample_rate=16_000)
    engine.push(b"\x00\x02" * 1_600)
    engine.reset()
    engine.start(sample_rate=16_000)
    engine.push(b"\x00\x02" * 800)
    assert engine.finish() == [
        ASREvent("last sentence", start_ms=0, end_ms=50, final=True)
    ]
    assert loads == 1
