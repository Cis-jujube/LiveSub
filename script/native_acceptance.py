#!/usr/bin/env python3
"""Public-audio playback and read-only native App process observation.

Neither command starts LiveSub, edits its bundle, changes volume settings, or
reads subtitle text. Playback is explicit; --dry-run only inspects the WAV.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import subprocess
import time
import wave


def snapshot(pid: int) -> dict | None:
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "pid=,ppid=,lstart=,rss=,pcpu=,comm="],
        text=True, capture_output=True, check=False,
    )
    if result.returncode != 0:
        return None
    parts = result.stdout.strip().split(None, 9)
    if len(parts) != 10:
        raise RuntimeError("Unexpected ps output shape")
    return {
        "pid": int(parts[0]), "ppid": int(parts[1]),
        "started": " ".join(parts[2:7]), "rss_mib": round(int(parts[7]) / 1024, 2),
        "cpu_percent": float(parts[8]), "executable": parts[9],
    }


def public_metrics(pid: int, expected: dict) -> dict:
    current = snapshot(pid)
    if current is None:
        return {"pid": pid, "alive": False, "pid_reused": False}
    reused = current["started"] != expected["started"] or current["executable"] != expected["executable"]
    return {
        "pid": pid, "alive": not reused, "pid_reused": reused,
        "rss_mib": current["rss_mib"] if not reused else None,
        "cpu_percent": current["cpu_percent"] if not reused else None,
    }


def fingerprint(app: Path) -> str:
    return hashlib.sha256((app / "Contents/MacOS/LiveSub").read_bytes()).hexdigest()


def verify_signature(app: Path) -> bool:
    return subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    ).returncode == 0


def monitor(args: argparse.Namespace) -> None:
    app = snapshot(args.app_pid)
    backend = snapshot(args.backend_pid)
    expected_binary = args.app.resolve() / "Contents/MacOS/LiveSub"
    if app is None or Path(app["executable"]).resolve() != expected_binary:
        raise ValueError("App PID does not name the supplied LiveSub bundle")
    if backend is None or backend["ppid"] != args.app_pid:
        raise ValueError("Backend PID must be a direct child of this App")
    original_hash = fingerprint(args.app)
    if not verify_signature(args.app):
        raise ValueError("App signature check failed before monitoring")
    started = time.monotonic()
    stopped_early = False
    # Refuse to overwrite previous evidence.
    with args.output.open("x", encoding="utf-8") as stream:
        def write(event: dict) -> None:
            stream.write(json.dumps({
                "utc": datetime.now(timezone.utc).isoformat(),
                "elapsed_seconds": round(time.monotonic() - started, 2), **event,
            }) + "\n")
            stream.flush()

        write({"kind": "start", "binary_sha256": original_hash, "signature_valid": True,
               "scope": "native_app_process_metrics_only", "planned_seconds": args.seconds})
        try:
            while True:
                app_metrics = public_metrics(args.app_pid, app)
                backend_metrics = public_metrics(args.backend_pid, backend)
                write({"kind": "sample", "app": app_metrics, "backend": backend_metrics})
                if not app_metrics["alive"] and not backend_metrics["alive"]:
                    write({"kind": "both_original_processes_exited"})
                    break
                remaining = args.seconds - (time.monotonic() - started)
                if remaining <= 0:
                    break
                time.sleep(min(args.interval, remaining))
        except KeyboardInterrupt:
            stopped_early = True
        finally:
            write({"kind": "end", "interrupted": stopped_early,
                   "binary_unchanged": fingerprint(args.app) == original_hash,
                   "signature_valid": verify_signature(args.app)})


def play(args: argparse.Namespace) -> None:
    with wave.open(str(args.audio), "rb") as audio:
        if audio.getcomptype() != "NONE" or audio.getnframes() == 0:
            raise ValueError("Expected a nonempty uncompressed public PCM WAV")
        duration = audio.getnframes() / audio.getframerate()
    repeats = math.ceil(args.seconds / duration)
    plan = {
        "clip_seconds": round(duration, 3), "repeats": repeats,
        "planned_audio_seconds": round(duration * repeats, 3),
        "playback_gain": args.gain,
        "wav_sha256": hashlib.sha256(args.audio.read_bytes()).hexdigest(),
        "dry_run": args.dry_run,
    }
    print(json.dumps(plan), flush=True)
    if args.dry_run:
        return
    completed = 0
    started = time.monotonic()
    try:
        for _ in range(repeats):
            subprocess.run(["/usr/bin/afplay", "-v", str(args.gain), str(args.audio)], check=True)
            completed += 1
    finally:
        print(json.dumps({"completed_repeats": completed,
                          "completed_audio_seconds": round(duration * completed, 3),
                          "wall_seconds": round(time.monotonic() - started, 3)}), flush=True)


def positive(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or number <= 0 or number > 7200:
        raise argparse.ArgumentTypeError("Expected a finite number in (0, 7200]")
    return number


def gain(value: str) -> float:
    number = float(value)
    if not math.isfinite(number) or not 0 < number <= 1:
        raise argparse.ArgumentTypeError("Gain must be in (0, 1]")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    observer = commands.add_parser("monitor", help="Observe an already running App and owned backend")
    observer.add_argument("--app", type=Path, default=Path("dist/LiveSub.app"))
    observer.add_argument("--app-pid", type=int, required=True)
    observer.add_argument("--backend-pid", type=int, required=True)
    observer.add_argument("--seconds", type=positive, default=1980)
    observer.add_argument("--interval", type=positive, default=10)
    observer.add_argument("--output", type=Path, required=True)
    player = commands.add_parser("play", help="Explicitly play a public WAV repeatedly; never starts LiveSub")
    player.add_argument("audio", type=Path)
    player.add_argument("--seconds", type=positive, default=1800)
    player.add_argument("--gain", type=gain, default=0.03)
    player.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    (monitor if args.command == "monitor" else play)(args)


if __name__ == "__main__":
    main()
