#!/usr/bin/env python3
"""Compare cached/uncached real-model translation on identical public prompts.

Both paths run serially on one MLX worker with the same loaded model. Pair order
alternates to reduce warm-up/order bias. This isolates translation generation;
it is not an audio-to-screen latency benchmark.
"""

import argparse
from dataclasses import replace
import hashlib
import importlib.metadata
import json
from pathlib import Path
import statistics
import sys
import tempfile
from time import perf_counter

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

from livesub.translation.base import ContextPair, TranslationRequest
from livesub.translation.download_model import REPO_ID, REVISION, verify_model
from livesub.translation.mlx_engine import MLXTranslator, _generate, default_model_path
from livesub.translation.prompt_cache import PromptCachedGenerator


class ComparisonGenerator:
    def __init__(self):
        self.cached = PromptCachedGenerator()
        self.rows = []
        self.case = None
        self.identity = None

    def __call__(self, model, tokenizer, prompt, *, max_tokens):
        if self.case is None:
            # Warm GPU kernels through both paths; do not retain warm-up context.
            _generate(model, tokenizer, prompt, max_tokens=max_tokens)
            result = self.cached(model, tokenizer, prompt, max_tokens=max_tokens)
            self.cached.reset()
            return result
        row = dict(self.case)
        identity = row["round"], row["direction"]
        if self.identity != identity:
            self.cached.reset()
            self.identity = identity
        paths = [("uncached", _generate), ("cached", self.cached)]
        if len(self.rows) % 2:
            paths.reverse()
        outputs = {}
        for name, generate in paths:
            start = perf_counter()
            outputs[name] = generate(model, tokenizer, prompt, max_tokens=max_tokens).strip()
            row[f"{name}_ms"] = round((perf_counter() - start) * 1000, 2)
        row["identical_output"] = outputs["uncached"] == outputs["cached"]
        if not row["identical_output"]:
            # Inputs are repository public fixtures; save only differences for review.
            row["outputs"] = outputs
        self.rows.append(row)
        return outputs["cached"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 10:
        parser.error("--rounds must be between 1 and 10")
    cases_path = ROOT / "docs/translation-candidate-cases.json"
    cases = json.loads(cases_path.read_text())
    model_path = default_model_path()
    verify_model(model_path)
    comparison = ComparisonGenerator()
    # Pin an empty user glossary so personal terminology settings cannot affect
    # repeatability. Built-in terminology remains active in both A/B paths.
    with tempfile.TemporaryDirectory(prefix="livesub-cache-benchmark-") as directory:
        terminology_path = Path(directory) / "terminology.json"
        terminology_path.write_text(json.dumps({"version": 1, "profile": "general", "entries": []}))
        engine = MLXTranslator(model_path, text_generator=comparison, terminology_path=terminology_path)
        try:
            engine.prepare()
            engine.translate(TranslationRequest("warmup", 0, "warmup", 1, "en", "zh", "Hello."))
            for round_index in range(args.rounds):
                for case in cases:
                    source = case["text"]
                    direction = case["source_language"]
                    words = source.split() if direction == "en" else list(source)
                    partial = " ".join(words[:max(1, len(words) // 2)]) if direction == "en" else "".join(words[:max(1, len(words) // 2)])
                    request = TranslationRequest(
                        "cache-benchmark", round_index, case["id"], 1, direction,
                        "zh" if direction == "en" else "en", partial,
                    )
                    context = (ContextPair("The meeting starts at nine.", "会议九点开始。"),) if direction == "en" else (
                        ContextPair("会议九点开始。", "The meeting starts at nine."),
                    )
                    for phase, item in (
                        ("partial", request),
                        ("full", replace(request, source_text=source, source_revision=2)),
                        ("context", replace(request, source_text=source, source_revision=3, confirmed_context=context)),
                    ):
                        comparison.case = {"round": round_index + 1, "case": case["id"], "direction": direction, "phase": phase}
                        engine.translate(item)
                print(f"Round {round_index + 1}/{args.rounds} completed", file=sys.stderr, flush=True)
        finally:
            engine.close()
    rows = comparison.rows
    summary = {
        "scope": "Serial same-prompt generation A/B on one MLX worker; excludes ASR, audio capture, scheduling, IPC, and UI. Alternating pair order, warm-up excluded.",
        "model_repo": REPO_ID, "model_revision": REVISION,
        "mlx_lm_version": importlib.metadata.version("mlx-lm"),
        "fixture_sha256": hashlib.sha256(cases_path.read_bytes()).hexdigest(),
        "rounds": args.rounds, "pairs": len(rows),
        "identical_outputs": sum(row["identical_output"] for row in rows),
        "uncached_median_ms": round(statistics.median(row["uncached_ms"] for row in rows), 2),
        "cached_median_ms": round(statistics.median(row["cached_ms"] for row in rows), 2),
        "uncached_total_ms": round(sum(row["uncached_ms"] for row in rows), 2),
        "cached_total_ms": round(sum(row["cached_ms"] for row in rows), 2),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({**summary, "cases": rows}, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
