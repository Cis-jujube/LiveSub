#!/usr/bin/env python3
"""Run synthetic subtitle translation cases through local candidate models."""

import argparse
import json
from pathlib import Path
import sys
from time import perf_counter

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "backend"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=("qwen", "hy", "gemma"), required=True)
    parser.add_argument("--cases", type=Path, default=REPO / "docs/translation-candidate-cases.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model-root", type=Path, default=Path.home() / "Library/Application Support/LiveSub/models")
    args = parser.parse_args()
    cases = json.loads(args.cases.read_text())
    rows = []
    started = perf_counter()
    if args.model == "qwen":
        from livesub.translation.base import TranslationRequest
        from livesub.translation.mlx_engine import MLXTranslator

        engine = MLXTranslator(args.model_root / "Qwen3-4B-Instruct-2507-4bit",
                               terminology_path=REPO / ".build/asr-benchmark/absent-terminology.json")
        engine.prepare()
        load_seconds = perf_counter() - started
        try:
            for case in cases:
                request = TranslationRequest(
                    session_id="synthetic-benchmark", generation=0, segment_id=case["id"],
                    source_revision=1, source_language=case["source_language"],
                    target_language="zh" if case["source_language"] == "en" else "en",
                    source_text=case["text"],
                )
                start = perf_counter()
                output = engine.translate(request).target_text
                rows.append({**case, "translation": output, "compute_ms": round((perf_counter() - start) * 1000, 2)})
        finally:
            engine.close()
    else:
        from mlx_lm import generate, load

        directory = "Hy-MT2-7B-4bit" if args.model == "hy" else "translategemma-12b-it-4bit"
        model, tokenizer = load(str(args.model_root / directory))
        if args.model == "gemma":
            # This converted model ends translations with a turn marker, not <eos>.
            tokenizer.add_eos_token("<end_of_turn>")
        load_seconds = perf_counter() - started
        for case in cases:
            source = case["source_language"]
            target = "zh" if source == "en" else "en"
            if args.model == "hy":
                target_name = "Simplified Chinese" if target == "zh" else "English"
                content = (f"Translate the following text into {target_name}. Note that you should only "
                           f"output the translated result without any additional explanation:\n\n{case['text']}")
                prompt = tokenizer.apply_chat_template([{"role": "user", "content": content}],
                                                       tokenize=False, add_generation_prompt=True)
            else:
                prompt = tokenizer.apply_chat_template([{"role": "user", "content": [{
                    "type": "text", "source_lang_code": source, "target_lang_code": target, "text": case["text"],
                }]}], tokenize=False, add_generation_prompt=True)
            start = perf_counter()
            output = generate(model, tokenizer, prompt=prompt, max_tokens=128, verbose=False).strip()
            rows.append({**case, "translation": output, "compute_ms": round((perf_counter() - start) * 1000, 2)})
    args.output.write_text(json.dumps({"model": args.model, "load_seconds": round(load_seconds, 3),
                                       "cases": rows}, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"model": args.model, "load_seconds": round(load_seconds, 3),
                      "count": len(rows)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
