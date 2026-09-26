from livesub.asr.base import ASREvent
from livesub.subtitles.segmenter import Segmenter


def test_revisable_preview_becomes_one_final_segment():
    segmenter = Segmenter("session-a", 1, "en", "zh")
    first = segmenter.apply(ASREvent("hello", 0, 160, final=False))
    assert first is not None
    assert first.segment_id == "1:0"
    assert first.source_revision == 1
    assert not first.source_final
    assert segmenter.apply(ASREvent("hello", 0, 320, final=False)) is None
    second = segmenter.apply(ASREvent("hello world", 0, 480, final=False))
    assert second is not None and second.source_revision == 2
    final = segmenter.apply(ASREvent("hello world", 0, 500, final=True))
    assert final is not None and final.source_revision == 3
    assert final.source_final
    next_segment = segmenter.apply(ASREvent("next", 500, 660, final=False))
    assert next_segment is not None and next_segment.segment_id == "1:1"


def test_empty_hypothesis_never_erases_existing_preview():
    segmenter = Segmenter("session-a", 1, "zh", "en")
    assert segmenter.apply(ASREvent("", 0, 160, final=False)) is None
    segmenter.apply(ASREvent("你好", 0, 320, final=False))
    assert segmenter.apply(ASREvent("", 0, 480, final=False)) is None
    final = segmenter.apply(ASREvent("你好", 0, 500, final=True))
    assert final is not None and final.source_text == "你好"
