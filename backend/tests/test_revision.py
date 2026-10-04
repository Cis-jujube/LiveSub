from livesub.subtitles.revision import SegmentRevisionState


def test_older_source_revision_cannot_replace_newer_source():
    state = SegmentRevisionState()
    assert state.apply_source(1, "We should", final=False)
    assert state.apply_source(2, "We should review", final=False)
    assert not state.apply_source(1, "We", final=False)
    assert state.source_text == "We should review"


def test_valid_older_preview_remains_paired_while_source_grows():
    state = SegmentRevisionState()
    state.apply_source(1, "We should", final=False)
    state.apply_source(2, "We should review", final=False)
    assert state.apply_translation(
        source_revision=1,
        translated_source_text="We should",
        target_text="我们应该",
        translation_state="preview",
    )
    assert state.translated_source_text == "We should"
    assert state.source_text == "We should review"
    assert not state.apply_translation(
        source_revision=0,
        translated_source_text="We",
        target_text="我们",
        translation_state="preview",
    )
    assert not state.apply_translation(
        source_revision=1,
        translated_source_text="We should",
        target_text="我们应该",
        translation_state="preview",
    )


def test_translation_source_must_match_the_referenced_revision():
    state = SegmentRevisionState()
    state.apply_source(1, "We should", final=False)
    assert not state.apply_translation(
        source_revision=1,
        translated_source_text="A different sentence",
        target_text="另一个句子",
        translation_state="preview",
    )


def test_final_source_rejects_stale_preview_but_accepts_matching_final():
    state = SegmentRevisionState()
    state.apply_source(1, "We should", final=False)
    state.apply_source(2, "We should review.", final=True)
    assert not state.apply_translation(
        source_revision=1,
        translated_source_text="We should",
        target_text="我们应该",
        translation_state="preview",
    )
    assert state.apply_translation(
        source_revision=2,
        translated_source_text="We should review.",
        target_text="我们应该重新检查。",
        translation_state="final",
    )
    assert state.source_snapshots == {2: "We should review."}
