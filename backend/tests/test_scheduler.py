import pytest

from livesub.translation.base import TranslationRequest
from livesub.translation.scheduler import PendingTranslations, QueueCapacityError


def request(segment_id: str, revision: int, generation: int = 1) -> TranslationRequest:
    return TranslationRequest(
        session_id="session-a",
        generation=generation,
        segment_id=segment_id,
        source_revision=revision,
        source_language="en",
        target_language="zh",
        source_text=f"sentence {revision}",
    )


def test_final_has_priority_and_pending_preview_is_replaced():
    queue = PendingTranslations(max_finals=2)
    queue.begin("session-a", 1)
    queue.add_preview(request("a", 1))
    queue.add_preview(request("a", 2))
    queue.add_final(request("b", 1))
    assert queue.pop_next() == (request("b", 1), True)
    assert queue.pop_next() == (request("a", 2), False)
    assert queue.pop_next() is None


def test_final_removes_pending_preview_for_same_segment():
    queue = PendingTranslations()
    queue.begin("session-a", 1)
    queue.add_preview(request("a", 1))
    queue.add_final(request("a", 2))
    assert queue.pop_next() == (request("a", 2), True)
    assert queue.pop_next() is None


def test_replace_preview_only_refreshes_existing_pending_work():
    queue = PendingTranslations()
    queue.begin("session-a", 1)
    assert not queue.replace_preview(request("a", 1))
    assert queue.add_preview(request("a", 1))
    assert queue.replace_preview(request("a", 2))
    assert not queue.replace_preview(request("a", 1))
    assert queue.pop_next() == (request("a", 2), False)
    assert not queue.replace_preview(request("a", 3))


def test_final_overflow_is_explicit_and_old_generation_is_rejected():
    queue = PendingTranslations(max_finals=1)
    queue.begin("session-a", 1)
    queue.add_final(request("a", 1))
    with pytest.raises(QueueCapacityError):
        queue.add_final(request("b", 1))
    queue.begin("session-a", 2)
    assert queue.pop_next() is None
    assert not queue.add_preview(request("old", 1))
    assert queue.add_preview(request("new", 1, generation=2))
