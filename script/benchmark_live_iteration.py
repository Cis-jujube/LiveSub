#!/usr/bin/env python3
"""One-shot paced-WAV model/session benchmark, with no listening service.

Use public/synthetic mono 16kHz PCM16 WAVs. The report contains fixture text;
it excludes ScreenCaptureKit, WebSocket transport and native screen rendering.
"""

import argparse
import asyncio
from dataclasses import asdict
import hashlib
import inspect
import json
from pathlib import Path
import statistics
import sys
import tempfile
from time import perf_counter
import wave

ROOT = Path(__file__).resolve().parent.parent


def timing_summary(values):
    if not values:
        return None
    ordered = sorted(values)

    def percentile(fraction):
        position = (len(ordered) - 1) * fraction
        lower = int(position)
        upper = min(lower + 1, len(ordered) - 1)
        return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower), 2)

    return {"count": len(values), "median_ms": percentile(.5), "p90_ms": percentile(.9),
            "p95_ms": percentile(.95), "max_ms": round(ordered[-1], 2)}


async def run(args):
    sys.path.insert(0, str(args.backend_root.resolve()))
    from livesub.asr.qwen import QwenASREngine
    from livesub.protocol import AudioFrame, FRAME_SAMPLES, SAMPLE_RATE
    from livesub.session import LiveSession
    from livesub.translation.mlx_engine import MLXTranslator

    with wave.open(str(args.audio), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, SAMPLE_RATE):
            raise ValueError("expected mono 16kHz PCM16 WAV")
        pcm = source.readframes(source.getnframes())
    events = []
    audio_start = None
    asr_calls = []
    translation_calls = []
    model_calls = []

    async def emit(event):
        events.append((perf_counter(), event))

    model_root = Path.home() / "Library/Application Support/LiveSub/models"
    asr = QwenASREngine.from_local_files(model_root / "Qwen3-ASR-1.7B", language=args.language)
    with tempfile.TemporaryDirectory(prefix="livesub-live-iteration-") as directory:
        config = Path(directory) / "terminology.json"
        config.write_text(json.dumps({"version": 2, "domains": ["ai", "software", "data", "finance", "quant", "blockchain"], "entries": []}))
        if args.translation_helper:
            if args.language != "English":
                raise ValueError("native candidate is evaluated for English subtitles only")
            from livesub.translation.apple_engine import AppleTranslator
            translator = AppleTranslator(args.translation_helper,
                                         model_root / "Qwen3-4B-Instruct-2507-4bit", terminology_path=config)
            if args.qwen_fallback:
                from livesub.translation.local_engine import LocalTranslator
                translator = LocalTranslator(MLXTranslator(terminology_path=config), translator)
        else:
            translator = MLXTranslator(terminology_path=config)
        observer_options = ({"model_observer": lambda call: model_calls.append(asdict(call))}
                            if "model_observer" in inspect.signature(LiveSession).parameters else {})
        session = LiveSession(asr, translator, emit, **observer_options)
        source_language = "en" if args.language == "English" else "zh"
        started = perf_counter()
        accepted = 0
        rejected = 0
        stop_ok = False
        try:
            await session.start("live-iteration", 1, source_language, "zh" if source_language == "en" else "en")
            model_load_ms = (perf_counter() - started) * 1000
            transcribe = asr._model.transcribe

            class MeasuredTranscriber:
                def transcribe(self, **kwargs):
                    start = perf_counter()
                    if args.asr_inference_mode:
                        import torch
                        with torch.inference_mode():
                            output = transcribe(**kwargs)
                    else:
                        output = transcribe(**kwargs)
                    asr_calls.append({"audio_ms": round(len(kwargs["audio"][0]) * 1000 / SAMPLE_RATE, 2),
                                      "compute_ms": round((perf_counter() - start) * 1000, 2)})
                    return output

            asr._model = MeasuredTranscriber()
            if not args.translation_helper:
                generate = translator._text_generator

                def measured_generate(*values, **kwargs):
                    start = perf_counter()
                    result = generate(*values, **kwargs)
                    translation_calls.append(round((perf_counter() - start) * 1000, 2))
                    return result

                translator._text_generator = measured_generate
            audio_start = perf_counter()
            max_send_lateness_ms = 0.0
            for sequence, position in enumerate(range(0, len(pcm), FRAME_SAMPLES * 2)):
                chunk = pcm[position:position + FRAME_SAMPLES * 2]
                due = audio_start + (position + len(chunk)) / (SAMPLE_RATE * 2)
                await asyncio.sleep(max(0, due - perf_counter()))
                max_send_lateness_ms = max(max_send_lateness_ms, (perf_counter() - due) * 1000)
                frame = AudioFrame("live-iteration", 1, sequence, position // 2, SAMPLE_RATE, 1, chunk)
                if session.push_audio(frame):
                    accepted += 1
                else:
                    rejected += 1
            stop_started = perf_counter()
            stop_ok = await session.stop()
            stop_to_idle_ms = round((perf_counter() - stop_started) * 1000, 2)
        finally:
            await session.close()
    subtitles = [(at, event["segment"]) for at, event in events if event.get("kind") == "subtitle"]
    finals = [segment for _, segment in subtitles if segment.get("translation_state") == "final"]
    useful = [(at, segment) for at, segment in subtitles if segment.get("translation_state") in {"preview", "final"}
              and segment.get("target_text") and segment.get("translated_source_text") == segment["source_text"]
              and segment.get("translated_source_revision") == segment["source_revision"]]
    waits = []
    translation_waits = []
    for at, segment in useful:
        source_times = [source_at for source_at, source_segment in subtitles
                        if source_segment["segment_id"] == segment["segment_id"]
                        and source_segment["source_revision"] == segment["source_revision"]]
        wait = (at - min(source_times)) * 1000
        waits.append(wait)
        translation_waits.append({"segment_id": segment["segment_id"], "source_revision": segment["source_revision"],
                                  "state": segment["translation_state"], "wait_ms": round(wait, 2)})
    source_revisions = {(segment["segment_id"], segment["source_revision"]) for _, segment in subtitles}
    translated_revisions = {(segment["segment_id"], segment["source_revision"]) for _, segment in useful}
    model_timing = {}
    for kind in ("asr", "translation"):
        calls = [call for call in model_calls if call["kind"] == kind
                 and (kind != "translation" or call["operation"] == "translate")]
        model_timing[kind] = {
            "scope": "translate calls only" if kind == "translation" else "all ASR operations, including non-inference pushes; see asr_transcribe_timing for real inference",
            "executor_wait": timing_summary([(call["worker_started_at"] - call["submitted_at"]) * 1000 for call in calls]),
            "ownership_wait": timing_summary([(call["model_started_at"] - call["worker_started_at"]) * 1000 for call in calls]),
            "execution": timing_summary([(call["finished_at"] - call["model_started_at"]) * 1000 for call in calls]),
        }
    for call in model_calls:
        for field in ("submitted_at", "worker_started_at", "model_started_at", "finished_at"):
            call[field] = round((call[field] - audio_start) * 1000, 2)
    errors = [event.get("code") for _, event in events if event.get("kind") == "error"]
    report = {
        "scope": __doc__, "language": args.language,
        "translation_engine": ("apple_low_latency_with_qwen_fallback" if args.qwen_fallback else
                               "apple_low_latency" if args.translation_helper else "mlx_qwen"),
        "route_counts": getattr(translator, "route_counts", None),
        "fixture_sha256": hashlib.sha256(pcm).hexdigest(),
        "audio_ms": round(len(pcm) * 1000 / (SAMPLE_RATE * 2), 2), "model_load_ms": round(model_load_ms, 2),
        "frames_accepted": accepted, "frames_rejected": rejected, "stop_ok": stop_ok,
        "max_send_lateness_ms": round(max_send_lateness_ms, 2), "stop_to_idle_ms": stop_to_idle_ms,
        "first_current_translation_ms": round((useful[0][0] - audio_start) * 1000, 2) if useful else None,
        "current_translation_wait_median_ms": round(statistics.median(waits), 2) if waits else None,
        "current_translation_wait": timing_summary(waits), "translation_waits": translation_waits,
        "source_revisions": len(source_revisions), "translated_revisions": len(translated_revisions),
        "subtitle_events": len(subtitles), "current_translations": len(useful), "finals": finals,
        "asr_calls": asr_calls, "asr_total_ms": round(sum(call["compute_ms"] for call in asr_calls), 2),
        "asr_transcribe_timing": timing_summary([call["compute_ms"] for call in asr_calls]),
        "generation_calls": len(translation_calls), "generation_total_ms": round(sum(translation_calls), 2),
        "generation_timing": timing_summary(translation_calls), "model_call_timing": model_timing,
        "model_calls": model_calls, "asr_inference_mode": args.asr_inference_mode,
        "latency_acceptance": {"threshold_ms": 300,
                               "median_below_threshold": bool(waits) and statistics.median(waits) < 300,
                               "every_translation_below_threshold": bool(waits) and max(waits) < 300,
                               "under_threshold_count": sum(wait < 300 for wait in waits)},
        "error_codes": errors,
        "passed": stop_ok and not rejected and not errors and bool(finals)
            and len({segment["segment_id"] for segment in finals}) == len(finals)
            and all(segment["source_final"] and segment["source_text"] == segment["translated_source_text"]
                    and segment["source_revision"] == segment["translated_source_revision"] for segment in finals),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items()
                      if key not in {"finals", "asr_calls", "scope", "model_calls", "translation_waits"}}, ensure_ascii=False))
    return 0 if report["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--language", choices=("English", "Chinese"), required=True)
    parser.add_argument("--backend-root", type=Path, default=ROOT / "backend")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--asr-inference-mode", action="store_true", help="Controlled PyTorch inference-mode probe; not enabled in production")
    parser.add_argument("--translation-helper", type=Path, help="Evaluate the app-owned Apple English translation candidate")
    parser.add_argument("--qwen-fallback", action="store_true", help="Evaluate the final native/Qwen router with both models warm")
    args = parser.parse_args()
    if args.qwen_fallback and not args.translation_helper:
        parser.error("Qwen fallback evaluation requires --translation-helper")
    if args.output.exists():
        parser.error("output must be a new path")
    raise SystemExit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
