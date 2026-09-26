import pytest
import json
import os
import subprocess
import sys
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from livesub.server import create_app

from test_live_session import FakeASR, FakeTranslator


def test_backend_exits_when_owning_app_disappears():
    env = os.environ.copy()
    env["LIVESUB_AUTH_TOKEN"] = "watchdog-test"
    env["LIVESUB_PARENT_PID"] = str(os.getpid() + 10_000_000)
    process = subprocess.Popen(
        [sys.executable, "-m", "livesub.server"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        env=env,
    )
    try:
        assert process.stdout is not None
        ready = json.loads(process.stdout.readline())
        assert ready["kind"] == "ready"
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


class QuietASR(FakeASR):
    def push(self, pcm16):
        self.pushes += 1
        return []

    def finish(self):
        return []


def test_unauthorized_websocket_is_rejected():
    app = create_app(lambda _language: FakeASR(), FakeTranslator, token="secret")
    with TestClient(app) as client:
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect("/ws", headers={"Authorization": "Bearer wrong"}) as socket:
                socket.receive_json()


def test_malformed_audio_gets_controlled_error_and_session_survives():
    constructed = []

    def asr_builder(_language):
        constructed.append(1)
        return FakeASR()

    app = create_app(asr_builder, FakeTranslator, token="secret")
    with TestClient(app) as client:
        with client.websocket_connect("/ws", headers={"Authorization": "Bearer secret"}) as socket:
            socket.send_json({"kind": "start", "session_id": "s", "generation": 1,
                              "source_language": "en", "target_language": "zh"})
            assert socket.receive_json()["state"] == "loading"
            assert socket.receive_json()["state"] == "listening"
            socket.send_json({"kind": "start", "session_id": "s", "generation": 1,
                              "source_language": "en", "target_language": "zh"})
            socket.send_json({"kind": "audio", "session_id": "s", "generation": 1,
                              "sequence": 0, "start_sample": 0, "sample_rate": 16_000,
                              "channels": 1, "pcm16": "not-base64!!"})
            error = socket.receive_json()
            assert error["kind"] == "error" and error["code"] == "invalid_frame"
            assert constructed == [1]


def test_control_messages_must_match_the_active_session_and_generation():
    app = create_app(lambda _language: QuietASR(), FakeTranslator, token="secret")
    with TestClient(app) as client:
        with client.websocket_connect("/ws", headers={"Authorization": "Bearer secret"}) as socket:
            socket.send_json({"kind": "start", "session_id": "s", "generation": 1,
                              "source_language": "en", "target_language": "zh"})
            assert socket.receive_json()["state"] == "loading"
            assert socket.receive_json()["state"] == "listening"

            for command in (
                {"kind": "pause", "session_id": "other", "generation": 1},
                {"kind": "pause", "session_id": "s", "generation": 0},
                {"kind": "stop", "session_id": "other", "generation": 1},
                {"kind": "stop", "session_id": "s", "generation": 0},
            ):
                socket.send_json(command)
                assert socket.receive_json()["code"] == "control_rejected"

            socket.send_json({"kind": "pause", "session_id": "s", "generation": 1})
            assert socket.receive_json()["state"] == "paused"
            socket.send_json({"kind": "pause", "session_id": "s", "generation": 1})
            socket.send_json({"kind": "resume", "session_id": "other", "generation": 2,
                              "source_language": "zh", "target_language": "en"})
            assert socket.receive_json()["code"] == "control_rejected"
            socket.send_json({"kind": "resume", "session_id": "s", "generation": 1,
                              "source_language": "zh", "target_language": "en"})
            assert socket.receive_json()["code"] == "control_rejected"
            socket.send_json({"kind": "resume", "session_id": "s", "generation": 2,
                              "source_language": "zh", "target_language": "en"})
            assert socket.receive_json()["state"] == "loading"
            assert socket.receive_json()["state"] == "listening"
            socket.send_json({"kind": "resume", "session_id": "s", "generation": 2,
                              "source_language": "zh", "target_language": "en"})
            socket.send_json({"kind": "stop", "session_id": "s", "generation": 1})
            assert socket.receive_json()["code"] == "control_rejected"
            socket.send_json({"kind": "stop", "session_id": "s", "generation": 2})
            assert socket.receive_json()["state"] == "stopping"
            assert socket.receive_json()["state"] == "idle"
            socket.send_json({"kind": "stop", "session_id": "s", "generation": 2})
            socket.send_json({"kind": "start", "session_id": "new", "generation": 1,
                              "source_language": "en", "target_language": "zh"})
            assert socket.receive_json()["state"] == "loading"
            assert socket.receive_json()["state"] == "listening"


def test_invalid_start_does_not_construct_models_and_oversized_audio_is_rejected():
    constructed = []

    def asr_builder(_language):
        constructed.append(1)
        return QuietASR()

    app = create_app(asr_builder, FakeTranslator, token="secret")
    with TestClient(app) as client:
        with client.websocket_connect("/ws", headers={"Authorization": "Bearer secret"}) as socket:
            socket.send_json({"kind": "start", "session_id": "s", "generation": 1,
                              "source_language": "fr", "target_language": "zh"})
            assert socket.receive_json()["code"] == "invalid_message"
            assert constructed == []
            socket.send_json({"kind": "start", "session_id": "s", "generation": 1,
                              "source_language": "en", "target_language": "zh"})
            assert socket.receive_json()["state"] == "loading"
            assert socket.receive_json()["state"] == "listening"
            socket.send_json({"kind": "audio", "session_id": "s", "generation": 1,
                              "sequence": 0, "start_sample": 0, "sample_rate": 16_000,
                              "channels": 1, "pcm16": "AAAA" * 2_000})
            assert socket.receive_json()["code"] == "invalid_frame"
            socket.send_json({"kind": "stop", "session_id": "s", "generation": 1})
            assert socket.receive_json()["state"] == "stopping"
            assert socket.receive_json()["state"] == "idle"


def test_second_authorized_websocket_is_rejected_while_first_is_active():
    app = create_app(lambda _language: QuietASR(), FakeTranslator, token="secret")
    with TestClient(app) as client:
        with client.websocket_connect("/ws", headers={"Authorization": "Bearer secret"}):
            with pytest.raises(WebSocketDisconnect) as error:
                with client.websocket_connect("/ws", headers={"Authorization": "Bearer secret"}) as second:
                    second.receive_json()
            assert error.value.code == 4409
