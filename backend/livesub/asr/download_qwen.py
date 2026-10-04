"""Prepare the pinned local Qwen3-ASR-1.7B weights used by LiveSub."""

import argparse
import hashlib
from pathlib import Path

from huggingface_hub import snapshot_download


MODEL_ID = "Qwen/Qwen3-ASR-1.7B"
REVISION = "7278e1e70fe206f11671096ffdd38061171dd6e5"
REQUIRED = (
    "config.json", "model.safetensors.index.json",
    "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
    "vocab.json", "merges.txt", "tokenizer_config.json",
)
WEIGHTS = {
    "model-00001-of-00002.safetensors": (4220320824, "a4cd1f1a04d90b757dc7f7dd26254e69a013b19e80efe590a83c6a3bde8608d6"),
    "model-00002-of-00002.safetensors": (478200688, "6e0b9d9e09e2e0238e7ef3cc8a484ab387e91b90f1900bedf88bc92d7929ccfc"),
}


def verify(path: Path) -> None:
    missing = [name for name in REQUIRED if not (path / name).is_file() or (path / name).stat().st_size == 0]
    if missing:
        raise FileNotFoundError(f"Qwen3-ASR model is incomplete: {', '.join(missing)}")
    for name, (expected_size, expected_sha) in WEIGHTS.items():
        file = path / name
        if file.stat().st_size != expected_size:
            raise ValueError(f"Qwen3-ASR weight has unexpected size: {name}")
        digest = hashlib.sha256()
        with file.open("rb") as stream:
            for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected_sha:
            raise ValueError(f"Qwen3-ASR weight has unexpected SHA-256: {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=Path.home() / "Library/Application Support/LiveSub/models/Qwen3-ASR-1.7B")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if not args.verify_only:
        snapshot_download(MODEL_ID, revision=REVISION, local_dir=args.model_dir,
                          ignore_patterns=["*.md", ".gitattributes"])
    verify(args.model_dir)
    print(f"Pinned Qwen3-ASR model ready at {args.model_dir}", flush=True)


if __name__ == "__main__":
    main()
