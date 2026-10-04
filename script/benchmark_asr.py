#!/usr/bin/env python3
"""Compare local ASR engines on the same 16 kHz PCM16 WAV fixtures.

Use only public or synthetic audio: the JSON report contains full transcripts.
"""

import argparse
import json
from pathlib import Path
import re
import sys
from time import perf_counter
import unicodedata
import wave

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "backend"))
sys.path.insert(0, str(REPO / "third_party" / "Confucius4-R2T2"))


def load_audio(path: Path) -> tuple[bytes, np.ndarray, float]:
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16_000):
            raise ValueError(f"{path}: expected 16 kHz mono PCM16 WAV")
        pcm = source.readframes(source.getnframes())
    samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768
    return pcm, samples, len(samples) / 16_000


def normalized(text: str, language: str) -> list[str]:
    text = unicodedata.normalize("NFKC", text).casefold()
    if language == "Chinese":
        return [char for char in text if char.isalnum()]
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)?", text)


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    row = list(range(len(hypothesis) + 1))
    for index, item in enumerate(reference, 1):
        next_row = [index]
        for column, other in enumerate(hypothesis, 1):
            next_row.append(min(row[column] + 1, next_row[-1] + 1, row[column - 1] + (item != other)))
        row = next_row
    return row[-1]


def transcribe_r2t2(cases: list[dict], root: Path) -> list[dict]:
    from livesub.asr.r2t2 import R2T2ASREngine

    rows = []
    for case in cases:
        pcm, _, duration = load_audio(REPO / case["audio"])
        model = R2T2ASREngine.from_local_files(
            gguf_dir=root / "r2t2", processor_dir=root / "r2t2/processor", language=case["language"]
        )
        start = perf_counter()
        model.start(sample_rate=16_000)
        load_seconds = perf_counter() - start
        start = perf_counter()
        finals = []
        for position in range(0, len(pcm), 5_120):
            finals.extend(event.text for event in model.push(pcm[position:position + 5_120]) if event.final)
        finals.extend(event.text for event in model.finish() if event.final)
        rows.append({"id": case["id"], "hypothesis": " ".join(finals), "segments": finals,
                     "compute_seconds": round(perf_counter() - start, 3), "load_seconds": round(load_seconds, 3),
                     "audio_seconds": round(duration, 3)})
    return rows


def transcribe_qwen(cases: list[dict], root: Path) -> list[dict]:
    import torch
    from qwen_asr import Qwen3ASRModel

    start = perf_counter()
    model = Qwen3ASRModel.from_pretrained(
        str(root / "Qwen3-ASR-1.7B"), dtype=torch.float16, device_map="mps",
        max_inference_batch_size=1, max_new_tokens=256,
    )
    load_seconds = perf_counter() - start
    rows = []
    for case in cases:
        _, samples, duration = load_audio(REPO / case["audio"])
        start = perf_counter()
        result = model.transcribe(audio=(samples, 16_000), language=case["language"])
        rows.append({"id": case["id"], "hypothesis": result[0].text,
                     "compute_seconds": round(perf_counter() - start, 3), "load_seconds": round(load_seconds, 3),
                     "audio_seconds": round(duration, 3)})
    return rows


def transcribe_qwen_live(cases: list[dict], root: Path) -> list[dict]:
    from livesub.asr.qwen import QwenASREngine

    model = QwenASREngine.from_local_files(root / "Qwen3-ASR-1.7B", language=cases[0]["language"])
    rows = []
    for case in cases:
        pcm, _, duration = load_audio(REPO / case["audio"])
        model.set_language(case["language"])
        start = perf_counter()
        model.start(sample_rate=16_000)
        load_seconds = perf_counter() - start
        start = perf_counter()
        finals = []
        previews = 0
        for position in range(0, len(pcm), 5_120):
            for event in model.push(pcm[position:position + 5_120]):
                if event.final:
                    finals.append(event.text)
                else:
                    previews += 1
        finals.extend(event.text for event in model.finish() if event.final)
        rows.append({"id": case["id"], "hypothesis": " ".join(finals), "segments": finals,
                     "preview_count": previews, "compute_seconds": round(perf_counter() - start, 3),
                     "load_seconds": round(load_seconds, 3), "audio_seconds": round(duration, 3)})
    return rows


def transcribe_whisper(cases: list[dict], root: Path) -> list[dict]:
    import torch
    from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline

    path = str(root / "whisper-large-v3-turbo")
    start = perf_counter()
    model = AutoModelForSpeechSeq2Seq.from_pretrained(path, torch_dtype=torch.float16).to("mps")
    processor = AutoProcessor.from_pretrained(path)
    pipe = pipeline("automatic-speech-recognition", model=model, tokenizer=processor.tokenizer,
                    feature_extractor=processor.feature_extractor, device="mps")
    load_seconds = perf_counter() - start
    rows = []
    for case in cases:
        _, samples, duration = load_audio(REPO / case["audio"])
        start = perf_counter()
        result = pipe({"array": samples, "sampling_rate": 16_000},
                      generate_kwargs={"language": "chinese" if case["language"] == "Chinese" else "english",
                                       "task": "transcribe"})
        rows.append({"id": case["id"], "hypothesis": result["text"].strip(),
                     "compute_seconds": round(perf_counter() - start, 3), "load_seconds": round(load_seconds, 3),
                     "audio_seconds": round(duration, 3)})
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", choices=("r2t2", "qwen", "qwen-live", "whisper"), required=True)
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model-root", type=Path, default=Path.home() / "Library/Application Support/LiveSub/models")
    args = parser.parse_args()
    cases = json.loads(args.cases.read_text())
    rows = {"r2t2": transcribe_r2t2, "qwen": transcribe_qwen,
            "qwen-live": transcribe_qwen_live, "whisper": transcribe_whisper}[args.engine](cases, args.model_root)
    for case, row in zip(cases, rows, strict=True):
        reference = normalized(case["reference"], case["language"])
        hypothesis = normalized(row["hypothesis"], case["language"])
        row.update({"language": case["language"], "kind": case["kind"], "reference": case["reference"],
                    "errors": edit_distance(reference, hypothesis), "reference_units": len(reference),
                    "error_rate": round(edit_distance(reference, hypothesis) / len(reference), 4),
                    "real_time_factor": round(row["compute_seconds"] / row["audio_seconds"], 3)})
    report = {"engine": args.engine, "cases": rows,
              "overall_error_rate": round(sum(r["errors"] for r in rows) / sum(r["reference_units"] for r in rows), 4)}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"engine": args.engine, "overall_error_rate": report["overall_error_rate"],
                      "cases": [{"id": r["id"], "error_rate": r["error_rate"],
                                 "real_time_factor": r["real_time_factor"]} for r in rows]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
