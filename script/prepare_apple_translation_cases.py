#!/usr/bin/env python3
"""Export research fixtures with explicit native skip-translation term spans.

Uses synthetic fixture settings in a temporary directory. It does not load a
model, download language assets, change personal settings, or start a service.
Native timing excludes this export's terminology lookup; context is used only
for terminology selection, not supplied to Apple's translation engine.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from livesub.translation.terminology import ProtectedTerms, Terminology


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, default=ROOT / "docs/translation-round2-cases.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--protected-markers", action="store_true",
                        help="Protect verifiable ASCII markers and restore terms after translation")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output must be a new path")
    cases = json.loads(args.cases.read_text())
    if len(cases) != 96:
        parser.error("expected all 96 fixtures")
    settings_default = {"version": 2, "domains": ["ai", "software", "data", "finance", "quant", "blockchain"],
                        "entries": [{"source_language": "en", "source": "Jujube", "target": "枣枣"}]}
    rows = []
    with tempfile.TemporaryDirectory(prefix="livesub-native-fixtures-") as directory:
        settings = Path(directory) / "terminology.json"
        terminology = Terminology(settings)
        active = None
        for case in cases:
            desired = case.get("settings", settings_default)
            if desired != active:
                settings.write_text(json.dumps(desired))
                active = desired
            language = case.get("source_language", "en")
            context = case.get("context", [])
            sources = (["We discuss large language models."] if context is True else
                       [pair[0] for pair in context[-4:]])
            source = case["text"].strip()
            spans = terminology.spans(language, source, sources)
            protection = ProtectedTerms(source, spans, [])
            parts, cursor = [], 0
            markers = list(protection.replacements)
            for index, (start, end, entry) in enumerate(spans):
                if start < cursor or end <= start or end > len(source):
                    raise ValueError("invalid or overlapping terminology span")
                if start > cursor:
                    parts.append({"text": source[cursor:start], "protected": False})
                parts.append({"text": markers[index] if args.protected_markers else entry.target,
                              "protected": True})
                cursor = end
            if cursor < len(source):
                parts.append({"text": source[cursor:], "protected": False})
            direct = protection.term_only_output() if spans and language == "en" else None
            if direct is not None:
                direct = protection.restore(direct)
            rows.append({"id": case["id"], "source_language": language,
                         "target_language": case.get("target_language", "zh" if language == "en" else "en"),
                         "source": source, "parts": parts, "direct_output": direct})
            if args.protected_markers:
                rows[-1]["replacements"] = protection.replacements
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as stream:
        stream.write(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"cases": len(rows), "dictionary_cases": sum(row["direct_output"] is not None for row in rows),
                      "fixture_sha256": hashlib.sha256(json.dumps(cases, sort_keys=True).encode()).hexdigest(),
                      "export_sha256": hashlib.sha256(args.output.read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
