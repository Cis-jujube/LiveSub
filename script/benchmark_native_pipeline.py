#!/usr/bin/env python3
"""One-shot full native/Qwen router test with terminology, IPC and budgets.

Uses all 96 synthetic/public fixtures, including 2 Chinese Qwen controls.
Warm request time excludes startup, fixture configuration writes, ASR and UI.
"""

import argparse
import hashlib
import json
from pathlib import Path
import statistics
import sys
import tempfile
from time import perf_counter

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from livesub.translation.apple_engine import AppleTranslator
from livesub.translation.base import ContextPair, TranslationRequest
from livesub.translation.local_engine import LocalTranslator
from livesub.translation.mlx_engine import MLXTranslator, default_model_path


class ObservedAppleTranslator(AppleTranslator):
    """Retain only this benchmark's synthetic rejected response for diagnosis."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.last_reply = None
        self.rejections = []

    def _exchange(self, payload, *, timeout):
        result = super()._exchange(payload, timeout=timeout)
        if payload["operation"] == "translate":
            self.last_reply = {"request": payload, "reply": result}
        return result

    def translate(self, request):
        self.last_reply = None
        try:
            return super().translate(request)
        except Exception as error:
            self.rejections.append({"source": request.source_text, "generation": request.generation,
                                    "segment_id": request.segment_id, "error": str(error),
                                    "cause": repr(error.__cause__),
                                    "native_reply": self.last_reply})
            raise


def summary(rows):
    values = sorted(row["elapsed_ms"] for row in rows)
    if not values:
        return None

    def percentile(fraction):
        position = (len(values) - 1) * fraction
        low = int(position)
        high = min(low + 1, len(values) - 1)
        return round(values[low] + (values[high] - values[low]) * (position - low), 3)

    return {"count": len(rows), "median_ms": round(statistics.median(values), 3),
            "p90_ms": percentile(.9), "p95_ms": percentile(.95), "max_ms": round(max(values), 3),
            "under_300_ms": sum(value < 300 for value in values),
            "lexical_passes": sum(row["lexical_pass"] for row in rows),
            "errors": sum(row["error"] is not None for row in rows)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, choices=(1, 2, 3), default=3)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output must be a new path")
    cases = json.loads((ROOT / "docs/translation-round2-cases.json").read_text())
    if len(cases) != 96 or len({case["id"] for case in cases}) != 96:
        parser.error("expected all 96 unique fixtures")
    defaults = {"version": 2, "domains": ["ai", "software", "data", "finance", "quant", "blockchain"],
                "entries": [{"source_language": "en", "source": "Jujube", "target": "枣枣"}]}
    rows = []
    with tempfile.TemporaryDirectory(prefix="livesub-native-pipeline-") as directory:
        config = Path(directory) / "terminology.json"
        native = ObservedAppleTranslator(args.helper, default_model_path(), terminology_path=config)
        qwen = MLXTranslator(terminology_path=config)
        engine = LocalTranslator(qwen, native)
        active = None
        try:
            start = perf_counter()
            engine.prepare()
            prepare_ms = (perf_counter() - start) * 1000
            for round_index in range(1, args.rounds + 1):
                for case in cases:
                    desired = case.get("settings", defaults)
                    if desired != active:
                        config.write_text(json.dumps(desired))
                        active = desired
                    language = case.get("source_language", "en")
                    context = case.get("context", [])
                    if context is True:
                        context = [["We discuss large language models.", "我们讨论大语言模型。"]]
                    request = TranslationRequest(
                        "native-pipeline", round_index, case.get("segment_id", case["id"]),
                        case.get("source_revision", 1), language,
                        case.get("target_language", "zh" if language == "en" else "en"),
                        case["text"], tuple(ContextPair(*pair) for pair in context[-4:]),
                    )
                    counts = dict(engine.route_counts)
                    start = perf_counter()
                    error = None
                    try:
                        result = engine.translate(request)
                        elapsed = (perf_counter() - start) * 1000
                        output = result.target_text
                        identity_pass = (result.session_id, result.generation, result.segment_id,
                                         result.source_revision, result.source_language, result.target_language,
                                         result.translated_source_text) == (
                                             request.session_id, request.generation, request.segment_id,
                                             request.source_revision, request.source_language, request.target_language,
                                             request.source_text.strip())
                    except Exception as failure:
                        elapsed = (perf_counter() - start) * 1000
                        error, output, identity_pass = type(failure).__name__, "", False
                    missing = [term for term in case.get("required", []) if term.casefold() not in output.casefold()]
                    missing += [" | ".join(group) for group in case.get("required_any", [])
                                if not any(term.casefold() in output.casefold() for term in group)]
                    unexpected = [term for term in case.get("forbidden", []) if term.casefold() in output.casefold()]
                    rows.append({"round": round_index, "id": case["id"], "category": case["category"],
                                 "source_language": language, "source": case["text"], "translation": output,
                                 "elapsed_ms": elapsed, "error": error, "identity_pass": identity_pass,
                                 "output_tokens": native._token_count(output),
                                 "route": "apple" if engine.route_counts["apple"] > counts["apple"] else "qwen",
                                 "missing": missing, "unexpected": unexpected,
                                 "lexical_pass": not error and not missing and not unexpected})
                print(f"Round {round_index}/{args.rounds} complete", file=sys.stderr, flush=True)
        finally:
            engine.close()
    summaries = {category: summary([row for row in rows if row["category"] == category
                                    and row["source_language"] == "en"])
                 for category in ("sentence", "revision_sentence", "isolated_term")}
    summaries["chinese_controls"] = summary([row for row in rows if row["source_language"] == "zh"])
    report = {"scope": __doc__, "fixture_sha256": hashlib.sha256(json.dumps(cases, sort_keys=True).encode()).hexdigest(),
              "helper_sha256": hashlib.sha256(args.helper.read_bytes()).hexdigest(),
              "rounds": args.rounds, "prepare_ms": prepare_ms, "route_counts": engine.route_counts,
              "native_rejections": native.rejections,
              "helper_closed": native._process is None, "summary": summaries, "cases": rows,
              "passed": all(row["lexical_pass"] and row["identity_pass"] for row in rows)
                        and engine.route_counts["native_failures"] == 0}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"summary": summaries, "route_counts": engine.route_counts, "passed": report["passed"]}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
