from livesub.protocol import AudioFrame
from livesub.session import SessionGate


def frame(generation: int, sequence: int, start_sample: int) -> AudioFrame:
    return AudioFrame(
        session_id="session-a",
        generation=generation,
        sequence=sequence,
        start_sample=start_sample,
        sample_rate=16_000,
        channels=1,
        pcm16=b"\x00\x01" * 2560,
    )


def test_repeated_start_does_not_create_another_session():
    gate = SessionGate()
    assert gate.start("session-a", 1)
    assert not gate.start("session-a", 1)
    assert gate.state == "listening"
    assert gate.accept_frame(frame(1, 0, 0))
    assert not gate.accept_frame(frame(1, 0, 0))


def test_stopped_session_cannot_replay_the_same_generation():
    gate = SessionGate()
    assert gate.start("session-a", 1)
    assert gate.stop()
    assert not gate.start("session-a", 1)
    assert gate.start("session-a", 2)


def test_pause_and_resume_reject_old_generation_audio():
    gate = SessionGate()
    gate.start("session-a", 1)
    assert gate.accept_frame(frame(1, 0, 0))
    assert gate.pause()
    assert not gate.accept_frame(frame(1, 1, 2560))
    assert gate.resume(2)
    assert not gate.accept_frame(frame(1, 1, 2560))
    assert gate.accept_frame(frame(2, 0, 0))


def test_invalid_frame_shape_is_rejected_before_queuing():
    gate = SessionGate()
    gate.start("session-a", 1)
    invalid = AudioFrame(
        session_id="session-a",
        generation=1,
        sequence=0,
        start_sample=0,
        sample_rate=48_000,
        channels=2,
        pcm16=b"\x00\x01",
    )
    assert not gate.accept_frame(invalid)
