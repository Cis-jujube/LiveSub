#!/usr/bin/env python3
"""Soak the real local backend with one paced, repeated public WAV session.

The JSON report contains process metrics and event counts, never speech text.
Run 30 minutes for an acceptance result; --smoke permits a shorter script check.
"""

import argparse
import asyncio
import base64
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import statistics
import sys
import tempfile
from time import perf_counter

import websockets

import smoke_server as support


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * fraction
    low = math.floor(rank)
    high = math.ceil(rank)
    return round(ordered[low] + (ordered[high] - ordered[low]) * (rank - low), 2)


async def process_metrics(pid: int) -> tuple[float | None, float | None]:
    probe = await asyncio.create_subprocess_exec(
        "/bin/ps", "-p", str(pid), "-o", "rss=,pcpu=",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await probe.communicate()
    if probe.returncode != 0:
        return None, None
    fields = stdout.decode("ascii", errors="replace").split()
    if len(fields) != 2:
        return None, None
    return round(int(fields[0]) / 1024, 2), float(fields[1])


class Observations:
    def __init__(self, expected_tail: str, target_language: str) -> None:
        self.expected_tail = expected_tail
        self.target_language = target_language
        self.states: list[str] = []
        self.errors: Counter[str] = Counter()
        self.subtitle_events = 0
        self.final_events = 0
        self.final_ids: set[str] = set()
        self.duplicate_final_ids = 0
        self.final_pair_mismatches = 0
        self.revision_regressions = 0
        self.post_final_regressions = 0
        self.target_script_missing = 0
        self.latest_revision: dict[str, int] = {}
        self.final_after_stop = 0
        self.final_after_idle = 0
        self.final_delay_ms: list[float] = []
        self.last_final_source = ""
        self.last_final_end_ms: int | None = None
        self.first_subtitle_at: float | None = None
        self.listening_at: float | None = None
        self.idle_at: float | None = None
        self.audio_start: float | None = None
        self.stop_sent: float | None = None
        self.listening = asyncio.Event()
        self.idle = asyncio.Event()
        self.fatal = asyncio.Event()

    def accept(self, at: float, event: dict) -> None:
        kind = event.get("kind")
        if kind == "state":
            state = event.get("state", "unknown")
            self.states.append(state)
            if state == "listening":
                self.listening_at = at
                self.listening.set()
            elif state == "idle":
                self.idle_at = at
                self.idle.set()
            elif state == "error":
                self.fatal.set()
        elif kind == "error":
            self.errors[event.get("code", "unknown")] += 1
            self.fatal.set()
        elif kind == "subtitle":
            self._subtitle(at, event.get("segment", {}))

    def _subtitle(self, at: float, segment: dict) -> None:
        self.subtitle_events += 1
        if self.first_subtitle_at is None:
            self.first_subtitle_at = at
        segment_id = segment.get("segment_id")
        revision = segment.get("source_revision")
        if not isinstance(segment_id, str) or not isinstance(revision, int):
            self.revision_regressions += 1
            return
        old_revision = self.latest_revision.get(segment_id, -1)
        if revision < old_revision:
            self.revision_regressions += 1
        self.latest_revision[segment_id] = max(revision, old_revision)
        if segment_id in self.final_ids and segment.get("translation_state") != "final":
            self.post_final_regressions += 1
        if not (segment.get("source_final") and segment.get("translation_state") == "final"):
            return
        self.final_events += 1
        if segment_id in self.final_ids:
            self.duplicate_final_ids += 1
        self.final_ids.add(segment_id)
        if (
            segment.get("translated_source_revision") != revision
            or segment.get("translated_source_text") != segment.get("source_text")
            or not segment.get("target_text")
        ):
            self.final_pair_mismatches += 1
        target_text = segment.get("target_text", "")
        pattern = r"[\u4e00-\u9fff]" if self.target_language == "zh" else r"[A-Za-z]"
        if not re.search(pattern, target_text):
            self.target_script_missing += 1
        self.last_final_source = segment.get("source_text", "")
        self.last_final_end_ms = segment.get("end_ms")
        if self.stop_sent is not None and at >= self.stop_sent:
            self.final_after_stop += 1
        if self.idle_at is not None and at >= self.idle_at:
            self.final_after_idle += 1
        if self.audio_start is not None and isinstance(self.last_final_end_ms, (int, float)):
            self.final_delay_ms.append(
                (at - self.audio_start - self.last_final_end_ms / 1000) * 1000
            )

    def counters(self) -> dict:
        return {
            "subtitle_events": self.subtitle_events,
            "unique_segment_ids": len(self.latest_revision),
            "final_translated_segments": self.final_events,
            "error_events": sum(self.errors.values()),
            "duplicate_final_ids": self.duplicate_final_ids,
            "revision_regressions": self.revision_regressions,
            "post_final_regressions": self.post_final_regressions,
        }


async def run(args: argparse.Namespace) -> int:
    if not math.isfinite(args.min_duration_seconds) or args.min_duration_seconds <= 0:
        raise ValueError("minimum duration must be finite and positive")
    if args.min_duration_seconds < 1800 and not args.smoke:
        raise ValueError("a production soak must last at least 1800 seconds")
    if args.smoke and args.output.resolve() == (support.ROOT / "docs/soak-backend.json").resolve():
        raise ValueError("short smoke runs require a separate --output path")
    pcm = support.read_pcm16(args.audio)
    if not pcm:
        raise ValueError("audio fixture is empty")
    clip_seconds = len(pcm) / (support.SAMPLE_RATE * 2)
    repeats = math.ceil(args.min_duration_seconds / clip_seconds)
    target_audio_seconds = repeats * clip_seconds
    target_language = "zh" if args.language == "English" else "en"
    source_language = "en" if args.language == "English" else "zh"
    observations = Observations(args.expected_tail_substring, target_language)
    report = {
        "test_type": "backend_websocket_repeated_public_wav",
        "smoke_only": args.smoke,
        "fixture_pcm_sha256": hashlib.sha256(pcm).hexdigest(),
        "fixture_duration_seconds": round(clip_seconds, 2),
        "fixture_repetitions_planned": repeats,
        "planned_audio_seconds": round(target_audio_seconds, 2),
        "source_language": source_language,
        "target_language": target_language,
        "single_session_start_commands": 1,
        "protocol_version": support.PROTOCOL_VERSION,
        "asr_model_repo": support.ASR_REPO,
        "asr_model_revision": support.ASR_REVISION,
        "translation_model_repo": support.TRANSLATION_REPO,
        "translation_model_revision": support.TRANSLATION_REVISION,
        "model_assets_verified": False,
        "frames_sent": 0,
        "audio_seconds_sent": 0.0,
        "minute_samples": [],
        "failure_codes": [],
        "server_queue_depth_exposed": False,
    }
    token = secrets.token_urlsafe(32)
    session_id = secrets.token_hex(16)
    model_root = Path.home() / "Library/Application Support/LiveSub/models"
    env = os.environ.copy()
    env["LIVESUB_AUTH_TOKEN"] = token
    env["LIVESUB_MODEL_ROOT"] = str(model_root)
    env["PYTHONPATH"] = os.pathsep.join([
        str(support.ROOT / "backend"),
        env.get("PYTHONPATH", ""),
    ])
    process = None
    connection = None
    receiver = None
    sampler = None
    stdout_drain = None
    extra_stdout_lines = 0
    start_sent = None
    stop_sent = None
    send_lateness_ms: list[float] = []
    sent_samples = 0
    sent_repeats = 0

    with tempfile.TemporaryFile() as stderr_file:
        try:
            report["model_verification_ms"] = round(support.verify_pinned_models(model_root), 2)
            report["model_assets_verified"] = True
            process = await asyncio.create_subprocess_exec(
                sys.executable, "-m", "livesub.server", cwd=support.ROOT, env=env,
                stdout=asyncio.subprocess.PIPE, stderr=stderr_file,
            )
            assert process.stdout is not None
            ready = json.loads(await asyncio.wait_for(process.stdout.readline(), timeout=30))
            if ready.get("kind") != "ready" or ready.get("version") != support.PROTOCOL_VERSION:
                raise RuntimeError("unexpected backend ready line")
            uri = f"ws://127.0.0.1:{ready['port']}/ws"

            async def drain_stdout() -> None:
                nonlocal extra_stdout_lines
                while await process.stdout.readline():
                    extra_stdout_lines += 1

            stdout_drain = asyncio.create_task(drain_stdout())
            connection = await support.connect_ready(
                uri, {"Authorization": f"Bearer {token}"}
            )

            async def receive_events() -> None:
                async for raw in connection:
                    observations.accept(perf_counter(), json.loads(raw))

            receiver = asyncio.create_task(receive_events())
            start_sent = perf_counter()
            await connection.send(json.dumps({
                "kind": "start", "session_id": session_id, "generation": 1,
                "source_language": source_language, "target_language": target_language,
            }))
            await asyncio.wait_for(observations.listening.wait(), timeout=args.startup_timeout)
            if observations.fatal.is_set():
                raise RuntimeError("backend reported a startup error")

            async def sample(kind: str) -> None:
                rss_mib, cpu_percent = await process_metrics(process.pid)
                report["minute_samples"].append({
                    "kind": kind,
                    "wall_elapsed_seconds": round(perf_counter() - observations.audio_start, 2),
                    "audio_seconds_sent": round(sent_samples / support.SAMPLE_RATE, 2),
                    "rss_mib": rss_mib,
                    "cpu_percent_ps": cpu_percent,
                    **observations.counters(),
                })

            observations.audio_start = perf_counter()
            await sample("start")

            async def sample_minutes() -> None:
                minute = 1
                while True:
                    due = observations.audio_start + minute * 60
                    await asyncio.sleep(max(0, due - perf_counter()))
                    await sample(f"minute_{minute}")
                    minute += 1

            sampler = asyncio.create_task(sample_minutes())
            frame_bytes = support.FRAME_SAMPLES * 2
            sequence = 0
            for repeat in range(repeats):
                for position in range(0, len(pcm), frame_bytes):
                    if observations.fatal.is_set():
                        raise RuntimeError("backend reported an error during audio feed")
                    chunk = pcm[position:position + frame_bytes]
                    due = observations.audio_start + (sent_samples + len(chunk) / 2) / support.SAMPLE_RATE
                    await asyncio.sleep(max(0, due - perf_counter()))
                    send_lateness_ms.append(max(0, (perf_counter() - due) * 1000))
                    await connection.send(json.dumps({
                        "kind": "audio", "session_id": session_id, "generation": 1,
                        "sequence": sequence, "start_sample": sent_samples,
                        "sample_rate": support.SAMPLE_RATE, "channels": 1,
                        "pcm16": base64.b64encode(chunk).decode("ascii"),
                    }))
                    sequence += 1
                    sent_samples += len(chunk) // 2
                    report["frames_sent"] = sequence
                sent_repeats += 1
            report["fixture_repetitions_sent"] = sent_repeats
            report["audio_seconds_sent"] = round(sent_samples / support.SAMPLE_RATE, 2)
            stop_sent = perf_counter()
            observations.stop_sent = stop_sent
            await connection.send(json.dumps({
                "kind": "stop", "session_id": session_id, "generation": 1,
            }))
            await asyncio.wait_for(observations.idle.wait(), timeout=args.stop_timeout)
            await asyncio.sleep(0.1)
            await sample("after_idle")
        except Exception as error:
            report["failure_codes"].append(type(error).__name__)
        finally:
            if sampler is not None:
                sampler.cancel()
                try:
                    await sampler
                except asyncio.CancelledError:
                    pass
            if connection is not None:
                await connection.close()
            if receiver is not None:
                receiver.cancel()
                try:
                    await receiver
                except asyncio.CancelledError:
                    pass
                except Exception as error:
                    report["failure_codes"].append(type(error).__name__)
            if process is not None:
                if process.returncode is None:
                    try:
                        process.terminate()
                    except ProcessLookupError:
                        pass
                try:
                    await asyncio.wait_for(process.wait(), timeout=5)
                except TimeoutError:
                    process.kill()
                    await process.wait()
                report["backend_exit_code"] = process.returncode
            if stdout_drain is not None:
                await stdout_drain

    report["extra_backend_stdout_lines"] = extra_stdout_lines
    report["fixture_repetitions_sent"] = sent_repeats
    report["audio_seconds_sent"] = round(sent_samples / support.SAMPLE_RATE, 2)
    report["states"] = observations.states
    report["error_codes"] = dict(observations.errors)
    report.update(observations.counters())
    report["final_pair_mismatches"] = observations.final_pair_mismatches
    report["target_script_missing_segments"] = observations.target_script_missing
    report["final_translations_received_after_stop"] = observations.final_after_stop
    report["final_translations_received_after_idle"] = observations.final_after_idle
    report["last_final_source_has_expected_tail"] = (
        observations.expected_tail in observations.last_final_source
    )
    report["last_final_segment_near_audio_end"] = (
        observations.last_final_end_ms is not None
        and observations.last_final_end_ms >= sent_samples / support.SAMPLE_RATE * 1000 - 1000
    )
    report["final_translation_after_segment_end_ms"] = {
        "median": percentile(observations.final_delay_ms, 0.5),
        "p95": percentile(observations.final_delay_ms, 0.95),
        "max": round(max(observations.final_delay_ms), 2) if observations.final_delay_ms else None,
    }
    report["send_lateness_ms"] = {
        "median": round(statistics.median(send_lateness_ms), 2) if send_lateness_ms else None,
        "p95": percentile(send_lateness_ms, 0.95),
        "max": round(max(send_lateness_ms), 2) if send_lateness_ms else None,
    }
    report["pacing_p95_under_160_ms"] = (
        report["send_lateness_ms"]["p95"] is not None
        and report["send_lateness_ms"]["p95"] < 160
    )
    report["audio_start_to_idle_wall_seconds"] = (
        round(observations.idle_at - observations.audio_start, 2)
        if observations.idle_at is not None and observations.audio_start is not None else None
    )
    report["start_to_listening_ms"] = (
        round((observations.listening_at - start_sent) * 1000, 2)
        if observations.listening_at is not None and start_sent is not None else None
    )
    report["audio_start_to_first_subtitle_ms"] = (
        round((observations.first_subtitle_at - observations.audio_start) * 1000, 2)
        if observations.first_subtitle_at is not None and observations.audio_start is not None else None
    )
    report["stop_to_idle_ms"] = (
        round((observations.idle_at - stop_sent) * 1000, 2)
        if observations.idle_at is not None and stop_sent is not None else None
    )
    rss = [sample["rss_mib"] for sample in report["minute_samples"] if sample["rss_mib"] is not None]
    report["rss_peak_mib"] = max(rss) if rss else None
    report["rss_delta_mib"] = round(rss[-1] - rss[0], 2) if len(rss) >= 2 else None
    minute_samples = [
        sample for sample in report["minute_samples"] if sample["kind"].startswith("minute_")
    ]
    report["complete_minute_metric_samples"] = bool(
        len(minute_samples) >= math.floor(args.min_duration_seconds / 60)
        and all(
            sample["rss_mib"] is not None and sample["cpu_percent_ps"] is not None
            for sample in minute_samples
        )
    )
    report["passed"] = bool(
        report["model_assets_verified"]
        and (args.smoke or report["audio_seconds_sent"] >= 1800)
        and (args.smoke or report["complete_minute_metric_samples"])
        and report["pacing_p95_under_160_ms"]
        and report["fixture_repetitions_sent"] == repeats
        and report["states"][:2] == ["loading", "listening"]
        and report["states"][-2:] == ["stopping", "idle"]
        and report["final_translated_segments"] > 0
        and report["duplicate_final_ids"] == 0
        and report["revision_regressions"] == 0
        and report["post_final_regressions"] == 0
        and report["final_pair_mismatches"] == 0
        and report["target_script_missing_segments"] == 0
        and report["final_translations_received_after_idle"] == 0
        and report["last_final_source_has_expected_tail"]
        and report["last_final_segment_near_audio_end"]
        and report["error_events"] == 0
        and report["extra_backend_stdout_lines"] == 0
        and not report["failure_codes"]
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "passed": report["passed"],
        "audio_seconds_sent": report["audio_seconds_sent"],
        "final_translated_segments": report["final_translated_segments"],
        "error_events": report["error_events"],
        "rss_peak_mib": report["rss_peak_mib"],
        "output": str(args.output),
    }, ensure_ascii=False), flush=True)
    return 0 if report["passed"] else 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--language", choices=("English", "Chinese"), default="English")
    parser.add_argument("--expected-tail-substring", default="your country")
    parser.add_argument("--min-duration-seconds", type=float, default=1800)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--output", type=Path, default=support.ROOT / "docs/soak-backend.json")
    parser.add_argument("--startup-timeout", type=float, default=180)
    parser.add_argument("--stop-timeout", type=float, default=30)
    raise SystemExit(asyncio.run(run(parser.parse_args())))


if __name__ == "__main__":
    main()
