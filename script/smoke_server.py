#!/usr/bin/env python3
"""Exercise the real authenticated backend over WebSocket with paced WAV audio.

The report contains timing, counts, and validation flags only. Public fixture
transcripts are inspected in memory but never written to the report.
"""

import argparse
import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
from time import perf_counter
import wave

import websockets
from websockets.exceptions import ConnectionClosed, InvalidStatus

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

from livesub.asr.download_model import (
    GGUF_REPO,
    GGUF_REVISION,
    PROCESSOR_REPO,
    PROCESSOR_REVISION,
    verify_model as verify_asr_model,
)
from livesub.translation.download_model import (
    REPO_ID as TRANSLATION_REPO,
    REVISION as TRANSLATION_REVISION,
    verify_model as verify_translation_model,
)


FRAME_SAMPLES = 2_560
SAMPLE_RATE = 16_000
PROTOCOL_VERSION = 1


def read_pcm16(path: Path) -> bytes:
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, SAMPLE_RATE):
            raise ValueError("audio must be mono 16 kHz PCM16 WAV")
        return source.readframes(source.getnframes())


def verify_pinned_models(model_root: Path) -> float:
    started = perf_counter()
    verify_asr_model(model_root / "r2t2")
    verify_translation_model(model_root / "Qwen3-4B-Instruct-2507-4bit")
    return (perf_counter() - started) * 1000


async def connect_ready(uri: str, headers: dict[str, str] | None = None):
    for attempt in range(40):
        try:
            return await websockets.connect(
                uri,
                additional_headers=headers,
                proxy=None,
                open_timeout=2,
                max_size=1024 * 1024,
            )
        except OSError:
            if attempt == 39:
                raise
            await asyncio.sleep(0.1)
    raise RuntimeError("WebSocket listener did not become ready")


async def reject_unauthorized(uri: str) -> tuple[bool, str]:
    try:
        connection = await connect_ready(uri, {"Authorization": "Bearer invalid"})
    except InvalidStatus as error:
        code = error.response.status_code
        return code in (401, 403), f"http_{code}"
    try:
        await asyncio.wait_for(connection.recv(), timeout=2)
        return False, "unexpected_message"
    except ConnectionClosed as error:
        return error.code in (4401, 1008), f"ws_{error.code}"
    finally:
        await connection.close()


def summarize(
    report: dict,
    events: list[tuple[float, dict]],
    *,
    audio_start: float | None,
    start_sent: float | None,
    stop_sent: float | None,
    expected_tail: str | None,
) -> None:
    state_records = [(at, event) for at, event in events if event.get("kind") == "state"]
    subtitle_records = [(at, event["segment"]) for at, event in events if event.get("kind") == "subtitle"]
    errors = [event.get("code", "unknown") for _, event in events if event.get("kind") == "error"]
    report["state_sequence"] = [event.get("state") for _, event in state_records]
    report["error_codes"] = errors
    report["subtitle_events"] = len(subtitle_records)
    report["unique_segment_ids"] = len({segment.get("segment_id") for _, segment in subtitle_records})
    report["audio_overflow_errors"] = errors.count("audio_overflow")
    report["translation_overflow_errors"] = errors.count("translation_overflow")
    report["frame_rejected_errors"] = errors.count("frame_rejected")
    report["server_queue_depth_exposed"] = False

    # These timestamps are client receipt times, not native capture/UI timings.
    report["target_latency_scope"] = (
        "Paced WAV audio-start to backend WebSocket IPC reception in this smoke client; "
        "excludes native capture and UI rendering and does not measure end-of-speech. "
        "Source-final waits start at first observed matching final source revision, "
        "not at the backend's internal ASR completion. Usable targets are nonblank "
        "preview/final translations with a nonblank translated source; useful previews "
        "also match the current source text and revision."
    )

    def offset_ms(at: float | None) -> float | None:
        return round((at - audio_start) * 1000, 2) if at is not None and audio_start is not None else None

    first_target_at = None
    first_current_preview_at = None
    useful_preview_events = 0
    useful_previews = set()
    segment_timings = {}
    first_source_observed = {}
    source_final_observed = {}
    final_target_waits = []
    for at, segment in subtitle_records:
        segment_id = segment.get("segment_id")
        first_source_observed.setdefault(segment_id, at)
        timing = segment_timings.setdefault(segment_id, {
            "segment_index": len(segment_timings) + 1,
            "first_source_observed_after_audio_start_ms": offset_ms(at),
            "first_usable_target_after_audio_start_ms": None,
            "first_usable_target_after_source_observed_ms": None,
        })
        revision_key = (segment_id, segment.get("source_revision"), segment.get("source_text"))
        if segment.get("source_final"):
            source_final_observed.setdefault(revision_key, at)
        usable_target = (
            segment.get("translation_state") in ("preview", "final")
            and bool(segment.get("target_text", "").strip())
            and bool(segment.get("translated_source_text", "").strip())
        )
        current_pair = (
            segment.get("translated_source_revision") is not None
            and segment.get("translated_source_revision") == segment.get("source_revision")
            and segment.get("translated_source_text") == segment.get("source_text")
        )
        if usable_target:
            if first_target_at is None:
                first_target_at = at
            if timing["first_usable_target_after_source_observed_ms"] is None:
                timing["first_usable_target_after_audio_start_ms"] = offset_ms(at)
                timing["first_usable_target_after_source_observed_ms"] = round(
                    (at - first_source_observed[segment_id]) * 1000, 2
                )
        if usable_target and current_pair and segment.get("translation_state") == "preview":
            if first_current_preview_at is None:
                first_current_preview_at = at
            useful_preview_events += 1
            useful_previews.add((*revision_key, segment.get("target_text")))
        if usable_target and current_pair and segment.get("source_final") and segment.get("translation_state") == "final":
            final_target_waits.append({
                "segment_index": timing["segment_index"],
                "source_revision": segment.get("source_revision"),
                "source_final_observed_to_final_target_ms": round((at - source_final_observed[revision_key]) * 1000, 2),
            })
    report["audio_start_to_first_usable_target_ms"] = offset_ms(first_target_at)
    report["audio_start_to_first_current_pair_preview_ms"] = offset_ms(first_current_preview_at)
    report["useful_preview_events"] = useful_preview_events
    report["useful_previews"] = len(useful_previews)
    report["segment_target_timings"] = list(segment_timings.values())
    report["source_final_to_final_target_waits"] = final_target_waits

    if start_sent is not None:
        listening = next((at for at, event in state_records if event.get("state") == "listening"), None)
        report["start_to_listening_ms"] = round((listening - start_sent) * 1000, 2) if listening else None
    if stop_sent is not None:
        idle = next((at for at, event in state_records if event.get("state") == "idle"), None)
        report["stop_to_idle_ms"] = round((idle - stop_sent) * 1000, 2) if idle else None
    if audio_start is not None and subtitle_records:
        report["audio_start_to_first_subtitle_ms"] = round(
            (subtitle_records[0][0] - audio_start) * 1000, 2
        )

    final_records = [
        (at, segment)
        for at, segment in subtitle_records
        if segment.get("source_final") and segment.get("translation_state") == "final"
    ]
    report["final_translated_segments"] = len(final_records)
    final_ids = [segment.get("segment_id") for _, segment in final_records]
    report["duplicate_final_segment_ids"] = len(final_ids) - len(set(final_ids))
    idle_at = next((at for at, event in state_records if event.get("state") == "idle"), None)
    report["final_translations_retained_at_idle"] = bool(final_records) and idle_at is not None and all(
        at <= idle_at for at, _ in final_records
    )
    if stop_sent is not None:
        report["final_translations_received_after_stop"] = sum(
            at >= stop_sent for at, _ in final_records
        )
    report["all_final_pairs_match_source_revision"] = bool(final_records) and all(
        segment.get("translated_source_revision") == segment.get("source_revision")
        and segment.get("translated_source_text") == segment.get("source_text")
        and bool(segment.get("target_text"))
        for _, segment in final_records
    )
    if audio_start is not None:
        report["final_translation_after_segment_end_ms"] = [
            round((at - audio_start - segment["end_ms"] / 1000) * 1000, 2)
            for at, segment in final_records
        ]
    report["last_final_segment_near_audio_end"] = bool(final_records) and max(
        segment["end_ms"] for _, segment in final_records
    ) >= report["audio_duration_ms"] - 1000

    final_sources = " ".join(segment.get("source_text", "") for _, segment in final_records)
    report["expected_tail_substring_found"] = (
        expected_tail in final_sources if expected_tail is not None else None
    )
    if final_records:
        target_language = final_records[-1][1].get("target_language")
        target_text = " ".join(segment.get("target_text", "") for _, segment in final_records)
        report["target_script_present"] = bool(
            re.search(r"[\u4e00-\u9fff]" if target_language == "zh" else r"[A-Za-z]", target_text)
        )
    else:
        report["target_script_present"] = False

    regressions = 0
    finished_ids = set()
    for _, segment in subtitle_records:
        segment_id = segment.get("segment_id")
        if segment_id in finished_ids and segment.get("translation_state") != "final":
            regressions += 1
        if segment.get("translation_state") == "final":
            finished_ids.add(segment_id)
    report["post_final_state_regressions"] = regressions


async def run(args: argparse.Namespace) -> int:
    pcm = read_pcm16(args.audio)
    token = secrets.token_urlsafe(32)
    session_id = secrets.token_hex(16)
    duration_ms = len(pcm) / (SAMPLE_RATE * 2) * 1000
    report: dict = {
        "audio_sha256": hashlib.sha256(pcm).hexdigest(),
        "audio_duration_ms": round(duration_ms, 2),
        "source_language": "en" if args.language == "English" else "zh",
        "target_language": "zh" if args.language == "English" else "en",
        "frame_samples": FRAME_SAMPLES,
        "frames_sent": 0,
        "unauthorized_rejected": False,
        "failure_codes": [],
        "asr_model_repo": GGUF_REPO,
        "asr_model_revision": GGUF_REVISION,
        "asr_processor_repo": PROCESSOR_REPO,
        "asr_processor_revision": PROCESSOR_REVISION,
        "translation_model_repo": TRANSLATION_REPO,
        "translation_model_revision": TRANSLATION_REVISION,
        "model_assets_verified": False,
    }
    events: list[tuple[float, dict]] = []
    listening_event = asyncio.Event()
    idle_event = asyncio.Event()
    audio_start = None
    start_sent = None
    stop_sent = None
    process = None
    connection = None
    receiver = None
    stdout_drain = None
    extra_stdout_lines = 0

    env = os.environ.copy()
    env["LIVESUB_AUTH_TOKEN"] = token
    model_root = Path.home() / "Library/Application Support/LiveSub/models"
    env["LIVESUB_MODEL_ROOT"] = str(model_root)
    env["PYTHONPATH"] = os.pathsep.join(
        [str(ROOT / "backend"), str(ROOT / "third_party/Confucius4-R2T2"), env.get("PYTHONPATH", "")]
    )

    with tempfile.TemporaryFile() as stderr_file:
        try:
            report["model_verification_ms"] = round(verify_pinned_models(model_root), 2)
            report["model_assets_verified"] = True
            process = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m",
                "livesub.server",
                cwd=ROOT,
                env=env,
                stdout=asyncio.subprocess.PIPE,
                stderr=stderr_file,
            )
            assert process.stdout is not None
            ready_line = await asyncio.wait_for(process.stdout.readline(), timeout=30)
            ready = json.loads(ready_line)
            if ready.get("kind") != "ready" or ready.get("version") != PROTOCOL_VERSION:
                raise RuntimeError("backend did not announce the expected protocol version")
            report["protocol_version"] = ready["version"]
            uri = f"ws://127.0.0.1:{ready['port']}/ws"

            async def drain_stdout() -> None:
                nonlocal extra_stdout_lines
                while await process.stdout.readline():
                    extra_stdout_lines += 1

            stdout_drain = asyncio.create_task(drain_stdout())
            rejected, rejection = await reject_unauthorized(uri)
            report["unauthorized_rejected"] = rejected
            report["unauthorized_rejection_kind"] = rejection
            connection = await connect_ready(uri, {"Authorization": f"Bearer {token}"})

            async def receive_events() -> None:
                async for raw in connection:
                    event = json.loads(raw)
                    events.append((perf_counter(), event))
                    if event.get("kind") == "state" and event.get("state") == "listening":
                        listening_event.set()
                    if event.get("kind") == "state" and event.get("state") == "idle":
                        idle_event.set()

            receiver = asyncio.create_task(receive_events())
            source_language = report["source_language"]
            start_sent = perf_counter()
            await connection.send(json.dumps({
                "kind": "start",
                "session_id": session_id,
                "generation": 1,
                "source_language": source_language,
                "target_language": report["target_language"],
            }))
            await asyncio.wait_for(listening_event.wait(), timeout=args.startup_timeout)

            frame_bytes = FRAME_SAMPLES * 2
            max_send_lateness_ms = 0.0
            audio_start = perf_counter()
            for sequence, position in enumerate(range(0, len(pcm), frame_bytes)):
                chunk = pcm[position : position + frame_bytes]
                due = audio_start + (position + len(chunk)) / (SAMPLE_RATE * 2)
                await asyncio.sleep(max(0, due - perf_counter()))
                max_send_lateness_ms = max(max_send_lateness_ms, (perf_counter() - due) * 1000)
                await connection.send(json.dumps({
                    "kind": "audio",
                    "session_id": session_id,
                    "generation": 1,
                    "sequence": sequence,
                    "start_sample": position // 2,
                    "sample_rate": SAMPLE_RATE,
                    "channels": 1,
                    "pcm16": base64.b64encode(chunk).decode("ascii"),
                }))
                report["frames_sent"] += 1
            report["max_send_lateness_ms"] = round(max_send_lateness_ms, 2)
            stop_sent = perf_counter()
            await connection.send(json.dumps({
                "kind": "stop", "session_id": session_id, "generation": 1
            }))
            await asyncio.wait_for(idle_event.wait(), timeout=args.stop_timeout)
            await asyncio.sleep(0.1)
        except Exception as error:
            report["failure_codes"].append(type(error).__name__)
        finally:
            if connection is not None:
                await connection.close()
            if receiver is not None:
                receiver.cancel()
                try:
                    await receiver
                except asyncio.CancelledError:
                    pass
            if process is not None:
                if process.returncode is None:
                    process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=5)
                except TimeoutError:
                    process.kill()
                    await process.wait()
                report["backend_exit_code"] = process.returncode
            if stdout_drain is not None:
                await stdout_drain

    report["extra_backend_stdout_lines"] = extra_stdout_lines
    summarize(
        report,
        events,
        audio_start=audio_start,
        start_sent=start_sent,
        stop_sent=stop_sent,
        expected_tail=args.expected_tail_substring,
    )
    checks = (
        report["unauthorized_rejected"]
        and report["model_assets_verified"]
        and report.get("protocol_version") == PROTOCOL_VERSION
        and report["state_sequence"][:2] == ["loading", "listening"]
        and report["state_sequence"][-2:] == ["stopping", "idle"]
        and report["frames_sent"] > 0
        and report["final_translated_segments"] > 0
        and report["duplicate_final_segment_ids"] == 0
        and report["all_final_pairs_match_source_revision"]
        and report["final_translations_retained_at_idle"]
        and report["post_final_state_regressions"] == 0
        and report["expected_tail_substring_found"] is not False
        and report["target_script_present"]
        and not report["error_codes"]
        and report["extra_backend_stdout_lines"] == 0
        and not report["failure_codes"]
    )
    report["passed"] = bool(checks)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if checks else 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--language", choices=("English", "Chinese"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-tail-substring")
    parser.add_argument("--startup-timeout", type=float, default=180)
    parser.add_argument("--stop-timeout", type=float, default=30)
    args = parser.parse_args()
    raise SystemExit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
