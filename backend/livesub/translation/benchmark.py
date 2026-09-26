"""Reproducible real-model translation review and latency measurement."""

import argparse
import importlib.metadata
import json
import platform
import resource
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path
from time import perf_counter

from .base import TranslationRequest
from .download_model import REPO_ID, REVISION, verify_model
from .mlx_engine import MLXTranslator, default_model_path

CASES_PATH = Path(__file__).resolve().parents[2] / "tests/fixtures/translation_review.json"


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--smoke", action="store_true", help="run one English and one Chinese case")
    args = parser.parse_args()

    model_path = default_model_path()
    verify_model(model_path)
    all_cases = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    cases = ([all_cases[0], all_cases[20]] if args.smoke else all_cases)
    engine = MLXTranslator(model_path)

    load_start = perf_counter()
    engine.prepare()
    load_ms = (perf_counter() - load_start) * 1000
    rows = []
    for case in cases:
        direction = case["source_language"]
        request = TranslationRequest(
            session_id="benchmark",
            generation=0,
            segment_id=case["id"],
            source_revision=1,
            source_language=direction,
            target_language="zh" if direction == "en" else "en",
            source_text=case["text"],
        )
        start = perf_counter()
        result = engine.translate(request)
        elapsed_ms = (perf_counter() - start) * 1000
        row = {
            **case,
            "target_language": result.target_language,
            "translation": result.target_text,
            "elapsed_ms": round(elapsed_ms, 2),
        }
        rows.append(row)
        print(f"{case['id']}: {elapsed_ms:.0f} ms -> {result.target_text}", file=sys.stderr, flush=True)

    latencies = [row["elapsed_ms"] for row in rows]
    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "model_repo": REPO_ID,
        "model_revision": REVISION,
        "model_path": str(model_path),
        "mlx_lm_version": importlib.metadata.version("mlx-lm"),
        "mlx_version": importlib.metadata.version("mlx"),
        "python_version": platform.python_version(),
        "platform": platform.platform(),
        "model_load_ms": round(load_ms, 2),
        "inference_median_ms": round(statistics.median(latencies), 2),
        "inference_p95_ms": round(percentile(latencies, 0.95), 2),
        "max_rss_bytes_macos": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "cases": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(rows)} real-model results to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
