#!/usr/bin/env python3
"""Run the real local R2T2 model against a 16 kHz mono PCM16 WAV.

This is an integration probe. Its process must use the prepared Python 3.12
environment with qwen-asr (without the vLLM extra) and the compiled extension.
"""

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import sys
import time
import wave

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "backend"))
sys.path.insert(0, str(REPO / "third_party" / "Confucius4-R2T2"))

from livesub.asr.r2t2 import R2T2ASREngine  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--language", choices=("English", "Chinese"), required=True)
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path.home() / "Library/Application Support/LiveSub/models/r2t2",
    )
    parser.add_argument("--pace", action="store_true", help="Feed frames at audio speed")
    parser.add_argument("--quiet-prefix-ms", type=int, default=0)
    parser.add_argument("--show-text", action="store_true")
    parser.add_argument("--expected-substring")
    args = parser.parse_args()

    with wave.open(str(args.audio), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (
            1,
            2,
            16_000,
        ):
            parser.error("audio must be mono 16 kHz PCM16 WAV")
        pcm = source.readframes(source.getnframes())
    if not pcm:
        parser.error("audio contains no samples")
    if args.quiet_prefix_ms < 0:
        parser.error("quiet prefix cannot be negative")
    pcm = b"\x00\x00" * (16 * args.quiet_prefix_ms) + pcm

    engine = R2T2ASREngine.from_local_files(
        gguf_dir=args.model_dir,
        processor_dir=args.model_dir / "processor",
        language=args.language,
    )
    t = time.perf_counter()
    engine.start(sample_rate=16_000)
    load_seconds = time.perf_counter() - t

    final_texts: list[str] = []
    preview_count = 0
    timings: list[float] = []
    max_lateness = 0.0
    start_wall = time.perf_counter()
    frame_bytes = 2_560 * 2
    for end in range(frame_bytes, len(pcm) + frame_bytes, frame_bytes):
        chunk = pcm[end - frame_bytes : end]
        if not chunk:
            break
        if args.pace:
            due = start_wall + min(end, len(pcm)) / (16_000 * 2)
            time.sleep(max(0, due - time.perf_counter()))
            max_lateness = max(max_lateness, time.perf_counter() - due)
        t = time.perf_counter()
        events = engine.push(chunk)
        timings.append(time.perf_counter() - t)
        for event in events:
            if event.final:
                final_texts.append(event.text)
            else:
                preview_count += 1
    t = time.perf_counter()
    tail_events = engine.finish()
    finish_seconds = time.perf_counter() - t
    final_texts.extend(event.text for event in tail_events if event.final)

    audio_seconds = len(pcm) / (16_000 * 2)
    joined = ("" if args.language == "Chinese" else " ").join(final_texts)
    result = {
        "audio_sha256": hashlib.sha256(pcm).hexdigest(),
        "audio_seconds": round(audio_seconds, 3),
        "load_seconds": round(load_seconds, 3),
        "compute_seconds": round(sum(timings) + finish_seconds, 3),
        "rtf": round((sum(timings) + finish_seconds) / audio_seconds, 3),
        "paced_wall_seconds": round(time.perf_counter() - start_wall, 3),
        "max_feed_lateness_ms": round(max_lateness * 1_000, 1),
        "mean_push_ms": round(statistics.mean(timings) * 1_000, 1),
        "max_push_ms": round(max(timings) * 1_000, 1),
        "finish_ms": round(finish_seconds * 1_000, 1),
        "frames": len(timings),
        "previews": preview_count,
        "final_segments": len(final_texts),
        "final_character_count": len(joined),
    }
    if args.show_text:
        result["final_text"] = joined
        result["segments"] = final_texts
    print(json.dumps(result, ensure_ascii=False))
    if args.expected_substring and args.expected_substring not in joined:
        print("expected substring was absent from final transcript", file=sys.stderr)
        return 1
    if not joined.strip():
        print("model produced no final transcript", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
