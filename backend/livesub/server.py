"""Authenticated loopback WebSocket server managed by the macOS application."""

import asyncio
import base64
import binascii
import hmac
import json
import os
from pathlib import Path
import socket
from typing import Callable

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import uvicorn

from livesub.asr.base import ASREngine
from livesub.protocol import AudioFrame, FRAME_SAMPLES, PROTOCOL_VERSION
from livesub.session import LiveSession
from livesub.translation.base import Translator


def _parse_audio(message: dict) -> AudioFrame:
    required_numbers = ("generation", "sequence", "start_sample", "sample_rate", "channels")
    if any(type(message.get(key)) is not int for key in required_numbers):
        raise ValueError("audio metadata must be integers")
    if not isinstance(message.get("session_id"), str) or not isinstance(message.get("pcm16"), str):
        raise ValueError("audio identity and PCM data must be strings")
    if len(message["pcm16"]) > (FRAME_SAMPLES * 2 + 2) // 3 * 4:
        raise ValueError("PCM data exceeds one audio frame")
    try:
        data = base64.b64decode(message["pcm16"], validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("PCM data is not valid base64") from error
    frame = AudioFrame(
        session_id=message["session_id"],
        generation=message["generation"],
        sequence=message["sequence"],
        start_sample=message["start_sample"],
        sample_rate=message["sample_rate"],
        channels=message["channels"],
        pcm16=data,
    )
    if not frame.valid():
        raise ValueError("audio frame format must be 16 kHz mono PCM16, at most 2560 samples")
    return frame


def _control_identity(message: dict) -> tuple[str, int]:
    session_id = message.get("session_id")
    generation = message.get("generation")
    if (
        not isinstance(session_id, str)
        or not session_id
        or len(session_id) > 128
        or type(generation) is not int
        or generation < 0
    ):
        raise ValueError("invalid session identity")
    return session_id, generation


def create_app(
    asr_builder: Callable[[str], ASREngine],
    translator_builder: Callable[[], Translator],
    *,
    token: str,
) -> FastAPI:
    if not token:
        raise ValueError("backend token must not be empty")
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    active = False

    @app.websocket("/ws")
    async def websocket_endpoint(websocket: WebSocket) -> None:
        nonlocal active
        authorization = websocket.headers.get("authorization", "")
        if not hmac.compare_digest(authorization, f"Bearer {token}"):
            await websocket.close(code=4401)
            return
        if active:
            await websocket.close(code=4409)
            return
        active = True
        sender: asyncio.Task | None = None
        session: LiveSession | None = None
        try:
            await websocket.accept()
            outgoing: asyncio.Queue[dict] = asyncio.Queue(maxsize=256)

            async def emit(event: dict) -> None:
                await outgoing.put(event)

            async def send_events() -> None:
                while True:
                    await websocket.send_json(await outgoing.get())

            sender = asyncio.create_task(send_events())
            while True:
                message = None
                try:
                    message = json.loads(await websocket.receive_text())
                    if not isinstance(message, dict):
                        raise ValueError("message must be a JSON object")
                    kind = message.get("kind")
                    if kind == "start":
                        session_id, generation = _control_identity(message)
                        source_language = message["source_language"]
                        target_language = message["target_language"]
                        if (source_language, target_language) not in {("en", "zh"), ("zh", "en")}:
                            raise ValueError("unsupported translation direction")
                        if session is None:
                            language = "English" if source_language == "en" else "Chinese"
                            session = LiveSession(asr_builder(language), translator_builder(), emit)
                        if not await session.start(session_id, generation, source_language, target_language):
                            if not session.is_duplicate_start(session_id, generation, source_language, target_language):
                                await emit({"kind": "error", "code": "control_rejected", "detail": "start does not match the current session state"})
                    elif kind == "audio":
                        frame = _parse_audio(message)
                        if session is None or not session.push_audio(frame):
                            await emit({"kind": "error", "code": "frame_rejected", "detail": "audio frame was stale, out of order, or session was inactive"})
                    elif kind == "pause":
                        identity = _control_identity(message)
                        if session is None or identity != (session.gate.session_id, session.gate.generation) or not await session.pause():
                            await emit({"kind": "error", "code": "control_rejected", "detail": "pause does not match the active session"})
                    elif kind == "resume":
                        session_id, generation = _control_identity(message)
                        source_language = message["source_language"]
                        target_language = message["target_language"]
                        duplicate = session is not None and session.is_duplicate_start(
                            session_id, generation, source_language, target_language
                        ) and session.gate.state == "listening"
                        if not duplicate and (
                            session is None
                            or session_id != session.gate.session_id
                            or generation <= session.gate.generation
                            or not await session.resume(generation, source_language, target_language)
                        ):
                            await emit({"kind": "error", "code": "control_rejected", "detail": "resume does not match the paused session"})
                    elif kind == "stop":
                        identity = _control_identity(message)
                        if session is None or identity != (session.gate.session_id, session.gate.generation) or not await session.stop():
                            await emit({"kind": "error", "code": "control_rejected", "detail": "stop does not match the active session"})
                    else:
                        await emit({"kind": "error", "code": "unknown_command", "detail": "unsupported command kind"})
                except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
                    code = "invalid_frame" if isinstance(message, dict) and message.get("kind") == "audio" else "invalid_message"
                    await emit({"kind": "error", "code": code, "detail": str(error)})
                except WebSocketDisconnect:
                    break
                except Exception as error:
                    await emit({"kind": "error", "code": "backend_failure", "detail": type(error).__name__})
                    break
        finally:
            try:
                if session is not None:
                    await session.close()
            finally:
                if sender is not None:
                    sender.cancel()
                    try:
                        await sender
                    except (asyncio.CancelledError, WebSocketDisconnect):
                        pass
                active = False

    return app


async def _serve() -> None:
    token = os.environ.get("LIVESUB_AUTH_TOKEN", "")
    root = Path(os.environ.get(
        "LIVESUB_MODEL_ROOT", str(Path.home() / "Library/Application Support/LiveSub/models")
    ))

    def build_asr(language: str) -> ASREngine:
        from livesub.asr.r2t2 import R2T2ASREngine

        return R2T2ASREngine.from_local_files(
            gguf_dir=root / "r2t2", processor_dir=root / "r2t2/processor", language=language
        )

    def build_translator() -> Translator:
        from livesub.translation.mlx_engine import MLXTranslator

        return MLXTranslator(model_path=root / "Qwen3-4B-Instruct-2507-4bit")

    app = create_app(build_asr, build_translator, token=token)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    listener.setblocking(False)
    port = listener.getsockname()[1]
    config = uvicorn.Config(
        app,
        host="127.0.0.1",
        port=port,
        log_level="warning",
        access_log=False,
        ws="websockets",
        ws_max_size=64 * 1024,
    )
    server = uvicorn.Server(config)
    print(json.dumps({"kind": "ready", "version": PROTOCOL_VERSION, "port": port}), flush=True)
    await server.serve(sockets=[listener])


def main() -> None:
    asyncio.run(_serve())


if __name__ == "__main__":
    main()
