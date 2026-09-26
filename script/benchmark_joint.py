#!/usr/bin/env python3
"""Paced real-WAV R2T2 + Qwen benchmark in one backend Python process.

Native model diagnostics go to stderr. The JSON report includes synthetic or
public-source text only when --include-text is explicitly requested.
"""

import argparse
import hashlib
import json
from pathlib import Path
from queue import Full, Queue
import resource
import statistics
import sys
from threading import Thread
from time import perf_counter, sleep
import wave

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "backend"))
sys.path.insert(0, str(REPO / "third_party" / "Confucius4-R2T2"))

from livesub.asr.r2t2 import R2T2ASREngine  # noqa: E402
from livesub.translation.base import TranslationRequest  # noqa: E402
from livesub.translation.mlx_engine import MLXTranslator  # noqa: E402


def read_wav(path: Path) -> bytes:
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (
            1,
            2,
            16_000,
        ):
            raise ValueError("input must be mono 16 kHz PCM16 WAV")
        return source.readframes(source.getnframes())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path)
    parser.add_argument("--language", choices=("English", "Chinese"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path.home() / "Library/Application Support/LiveSub/models/r2t2",
    )
    parser.add_argument("--include-text", action="store_true")
    args = parser.parse_args()

    pcm = read_wav(args.audio)
    direction = "en" if args.language == "English" else "zh"
    translator = MLXTranslator()
    asr = R2T2ASREngine.from_local_files(
        gguf_dir=args.model_dir,
        processor_dir=args.model_dir / "processor",
        language=args.language,
    )
    started = perf_counter()
    asr.start(sample_rate=16_000)
    asr_load_ms = (perf_counter() - started) * 1_000
    started = perf_counter()
    translator.prepare()
    translator_load_ms = (perf_counter() - started) * 1_000

    pending: Queue = Queue(maxsize=32)
    translations = []
    failures = []
    sample_depths = []
    queued_count = 0
    audio_start = 0.0

    def worker() -> None:
        while True:
            item = pending.get()
            if item is None:
                pending.task_done()
                return
            request, audio_end_wall, source_end_ms = item
            try:
                start = perf_counter()
                translated = translator.translate(request)
                done = perf_counter()
                row = {
                    "segment_id": request.segment_id,
                    "source_revision": translated.source_revision,
                    "source_end_ms": source_end_ms,
                    "translation_compute_ms": round((done - start) * 1_000, 2),
                    "after_segment_end_ms": round((done - audio_end_wall) * 1_000, 2),
                }
                if args.include_text:
                    row["source_text"] = translated.translated_source_text
                    row["target_text"] = translated.target_text
                translations.append(row)
            except Exception as error:  # keep consuming so the report includes every failure
                failures.append({"segment_id": request.segment_id, "error": repr(error)})
            finally:
                pending.task_done()

    thread = Thread(target=worker, name="translation-benchmark", daemon=True)
    thread.start()
    asr_compute_s = 0.0
    push_times_ms = []
    max_feed_lateness_ms = 0.0
    frame_bytes = 2_560 * 2
    audio_start = perf_counter()

    def queue_finals(events) -> None:
        nonlocal queued_count
        for event in events:
            if not event.final:
                continue
            queued_count += 1
            request = TranslationRequest(
                session_id="joint-benchmark",
                generation=0,
                segment_id=str(queued_count),
                source_revision=1,
                source_language=direction,
                target_language="zh" if direction == "en" else "en",
                source_text=event.text,
            )
            try:
                pending.put_nowait((request, audio_start + event.end_ms / 1_000, event.end_ms))
            except Full as error:
                raise RuntimeError("translation queue overflowed its 32-item bound") from error
            sample_depths.append(pending.qsize())

    for position in range(0, len(pcm), frame_bytes):
        chunk = pcm[position : position + frame_bytes]
        due = audio_start + (position + len(chunk)) / (16_000 * 2)
        sleep(max(0, due - perf_counter()))
        max_feed_lateness_ms = max(max_feed_lateness_ms, (perf_counter() - due) * 1_000)
        start = perf_counter()
        events = asr.push(chunk)
        elapsed = perf_counter() - start
        asr_compute_s += elapsed
        push_times_ms.append(elapsed * 1_000)
        queue_finals(events)
        sample_depths.append(pending.qsize())

    start = perf_counter()
    queue_finals(asr.finish())
    asr_compute_s += perf_counter() - start
    pending.put(None)
    pending.join()
    thread.join(timeout=1)

    duration_s = len(pcm) / (16_000 * 2)
    report = {
        "audio_sha256": hashlib.sha256(pcm).hexdigest(),
        "language": args.language,
        "audio_seconds": round(duration_s, 3),
        "asr_load_ms": round(asr_load_ms, 2),
        "translation_load_ms": round(translator_load_ms, 2),
        "asr_compute_seconds": round(asr_compute_s, 3),
        "asr_rtf": round(asr_compute_s / duration_s, 3),
        "asr_mean_push_ms": round(statistics.mean(push_times_ms), 2),
        "asr_max_push_ms": round(max(push_times_ms), 2),
        "max_feed_lateness_ms": round(max_feed_lateness_ms, 2),
        "max_translation_queue_depth": max(sample_depths, default=0),
        "queued_final_segments": queued_count,
        "translated_segments": len(translations),
        "failures": failures,
        "max_rss_bytes_macos": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "translations": translations,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    summary = {key: value for key, value in report.items() if key != "translations"}
    print(json.dumps(summary, ensure_ascii=False))
    if queued_count == 0 or failures or len(translations) != queued_count:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
