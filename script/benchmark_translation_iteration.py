#!/usr/bin/env python3
"""Serial old/new translation A/B on one model and one GPU worker.

The baseline is a runtime-source snapshot taken before the iteration. Only
repository public/synthetic text is used, with an isolated terminology file.
Timing includes translation preparation but excludes model load, ASR and UI.
"""

import argparse
from collections import defaultdict
import hashlib
import importlib
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import statistics
import sys
import tempfile
from time import perf_counter

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "backend"))

from livesub.translation.base import ContextPair, TranslationError, TranslationRequest
from livesub.translation.download_model import REPO_ID, REVISION, verify_model
from livesub.translation.mlx_engine import MLXTranslator, default_model_path


def load_baseline(backend_root: Path):
    package = backend_root / "livesub"
    spec = importlib.util.spec_from_file_location(
        "livesub_baseline", package / "__init__.py",
        submodule_search_locations=[str(package)],
    )
    if spec is None or spec.loader is None:
        raise ValueError("baseline must contain the livesub runtime package")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return importlib.import_module("livesub_baseline.translation.mlx_engine")


class PairedTranslator(MLXTranslator):
    def __init__(self, baseline_module, **kwargs):
        super().__init__(**kwargs)
        self.baseline = baseline_module.MLXTranslator(**kwargs)
        self.mode = "after"
        self.calls = defaultdict(int)
        for name, engine in (("before", self.baseline), ("after", self)):
            generate = engine._text_generator

            def counted(*args, _name=name, _generate=generate, **kw):
                self.calls[_name] += 1
                return _generate(*args, **kw)

            engine._text_generator = counted

    def _translate_loaded(self, request):
        if self.mode == "before":
            # Both implementations execute on this translator's existing MLX
            # worker; each retains its own prefix/exact-generation cache.
            self.baseline._model, self.baseline._tokenizer = self._model, self._tokenizer
            return self.baseline._translate_loaded(request)
        return super()._translate_loaded(request)


def fixtures():
    cases = [dict(case, category="sentence", required=[], forbidden=[])
             for case in json.loads((ROOT / "docs/translation-candidate-cases.json").read_text())
             if case["source_language"] == "en"]
    checks = {
        "en-finance-1": ["25", "基点"],
        "en-finance-2": ["夏普比率"],
        "en-security": ["令牌", "证券型代币"],
        "en-statistics": ["0.03", "0.3"],
        "en-time": ["3.5"],
    }
    for case in cases:
        case["required"] = checks.get(case["id"], [])
    cases += [
        {"id": "term-context", "text": "Context window.", "category": "isolated_term", "required": ["上下文窗口"]},
        {"id": "term-confidence", "text": "Confidence interval!", "category": "isolated_term", "required": ["置信区间"]},
        {"id": "term-sharpe", "text": "Sharpe ratio", "category": "isolated_term", "required": ["夏普比率"]},
        {"id": "term-api", "text": "API endpoint?", "category": "isolated_term", "required": ["API 端点"]},
        {"id": "term-custom", "text": "Jujube.", "category": "isolated_term", "required": ["枣枣"]},
        {"id": "ai-numbers", "text": "The LLM prompt contains 32 tokens.", "required": ["32", "tokens"], "forbidden": ["令牌"]},
        {"id": "ai-negation", "text": "The AI agent must not delete 42 files or expose the password.", "required": ["AI Agent", "42"]},
        {"id": "ai-unfinished", "text": "If the AI agent cannot", "required": ["AI Agent"]},
        {"id": "auth-context", "text": "The authentication token expires in 60 seconds.", "required": ["60"], "forbidden": ["__LS"]},
        {"id": "real-estate", "text": "The real estate agent sold a house.", "required": ["房"], "forbidden": ["AI Agent"]},
        {"id": "terms-repeat", "text": "An AI agent asks another AI agent to wait.", "required": ["AI Agent"]},
        {"id": "context-cues", "text": "Each token has a cost.", "required": ["token"], "forbidden": ["令牌"], "context": True},
    ]
    for case in cases:
        case.setdefault("category", "sentence")
        case.setdefault("required", [])
        case.setdefault("forbidden", [])
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-backend-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--cases", type=Path, help="Public/synthetic fixture JSON with optional per-case context/settings")
    args = parser.parse_args()
    if not 1 <= args.rounds <= 10:
        parser.error("rounds must be 1–10")
    baseline = load_baseline(args.baseline_backend_root.resolve())
    verify_model(default_model_path())
    cases = json.loads(args.cases.read_text()) if args.cases else fixtures()
    rows = []
    with tempfile.TemporaryDirectory(prefix="livesub-iteration-") as directory:
        settings = Path(directory) / "terminology.json"
        default_settings = {
            "version": 2, "domains": ["ai", "software", "data", "finance", "quant", "blockchain"],
            "entries": [{"source_language": "en", "source": "Jujube", "target": "枣枣"}],
        }
        settings.write_text(json.dumps(default_settings))
        active_settings = default_settings
        engine = PairedTranslator(baseline, terminology_path=settings)
        try:
            engine.prepare()
            for mode in ("before", "after"):
                engine.mode = mode
                engine.translate(TranslationRequest("warmup", 0, "warmup", 1, "en", "zh", "Hello."))
            engine.calls.clear()
            for round_index in range(args.rounds):
                for index, case in enumerate(cases):
                    desired_settings = case.get("settings", default_settings)
                    if desired_settings != active_settings:
                        settings.write_text(json.dumps(desired_settings))
                        active_settings = desired_settings
                    source_language = case.get("source_language", "en")
                    raw_context = case.get("context", [])
                    context = ((ContextPair("We discuss large language models.", "我们讨论大语言模型。"),)
                               if raw_context is True else tuple(ContextPair(*pair) for pair in raw_context))
                    request = TranslationRequest(
                        "iteration-benchmark", round_index, case.get("segment_id", case["id"]), case.get("source_revision", 1), source_language,
                        case.get("target_language", "zh" if source_language == "en" else "en"), case["text"], context,
                    )
                    row = {"round": round_index + 1, "id": case["id"], "category": case["category"],
                           "source_language": source_language,
                           "source": case["text"], "required": case["required"], "forbidden": case["forbidden"], "runs": {}}
                    for mode in (("before", "after") if (index + round_index) % 2 == 0 else ("after", "before")):
                        engine.mode = mode
                        start = perf_counter()
                        error = None
                        calls_before = engine.calls[mode]
                        try:
                            output = engine.translate(request).target_text
                        except (TranslationError, baseline.TranslationError) as failure:
                            error, output = type(failure).__name__, ""
                        missing = [term for term in case["required"] if term.casefold() not in output.casefold()]
                        missing += [" | ".join(group) for group in case.get("required_any", [])
                                    if not any(term.casefold() in output.casefold() for term in group)]
                        forbidden = [term for term in case["forbidden"] if term.casefold() in output.casefold()]
                        row["runs"][mode] = {
                            "elapsed_ms": round((perf_counter() - start) * 1000, 3), "translation": output,
                            "output_tokens": len(engine._tokenizer.encode(output, add_special_tokens=False)),
                            "error": error, "generation_calls": engine.calls[mode] - calls_before,
                            "lexical_pass": not error and not missing and not forbidden,
                            "missing": missing, "unexpected": forbidden,
                        }
                    row["identical_output"] = row["runs"]["before"]["translation"] == row["runs"]["after"]["translation"]
                    rows.append(row)
                print(f"Round {round_index + 1}/{args.rounds} complete", file=sys.stderr, flush=True)
        finally:
            engine.close()
    summary = {}
    for category in ("all", "sentence", "english_sentence", "revision_sentence", "isolated_term"):
        selected = [row for row in rows if category == "all" or row["category"] == category
                    or (category == "english_sentence" and row["category"] == "sentence" and row["source_language"] == "en")]
        if not selected:
            continue
        summary[category] = {"pairs": len(selected), "identical_outputs": sum(row["identical_output"] for row in selected)}
        for mode in ("before", "after"):
            runs = [row["runs"][mode] for row in selected]
            ordered = sorted(run["elapsed_ms"] for run in runs)

            def percentile(fraction):
                position = (len(ordered) - 1) * fraction
                lower = int(position)
                upper = min(lower + 1, len(ordered) - 1)
                return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower), 3)

            summary[category][mode] = {
                "median_ms": round(statistics.median(run["elapsed_ms"] for run in runs), 3),
                "p90_ms": percentile(.9), "p95_ms": percentile(.95), "max_ms": ordered[-1],
                "under_300_ms": sum(run["elapsed_ms"] < 300 for run in runs),
                "total_ms": round(sum(run["elapsed_ms"] for run in runs), 3),
                "lexical_passes": sum(run["lexical_pass"] for run in runs),
                "generation_calls": sum(run["generation_calls"] for run in runs),
            }
    report = {"scope": __doc__, "model_repo": REPO_ID, "model_revision": REVISION,
              "mlx_lm_version": importlib.metadata.version("mlx-lm"), "rounds": args.rounds,
              "mlx_version": importlib.metadata.version("mlx"),
              "fixture_sha256": hashlib.sha256(json.dumps(cases, sort_keys=True).encode()).hexdigest(),
              "baseline_mlx_sha256": hashlib.sha256(Path(baseline.__file__).read_bytes()).hexdigest(),
              "baseline_prompt_cache_sha256": hashlib.sha256((args.baseline_backend_root / "livesub/translation/prompt_cache.py").read_bytes()).hexdigest(),
              "current_prompt_cache_sha256": hashlib.sha256((ROOT / "backend/livesub/translation/prompt_cache.py").read_bytes()).hexdigest(),
              "summary": summary, "cases": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
