"""Prepare the pinned local translation model in Application Support."""

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from .mlx_engine import default_model_path

REPO_ID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
REVISION = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
WEIGHT_SHA256 = "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f"
MIN_FREE_BYTES = 4 * 1024**3


def verify_model(path: Path) -> None:
    weight = path / "model.safetensors"
    config_path = path / "config.json"
    if any(
        not (path / name).is_file()
        for name in ("model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json")
    ):
        raise RuntimeError(f"translation model is incomplete: {path}")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    quantization = config.get("quantization") or config.get("quantization_config")
    if quantization is None or quantization.get("bits") != 4 or quantization.get("group_size") != 64:
        raise RuntimeError("translation model has unexpected quantization config")
    digest = hashlib.sha256()
    with weight.open("rb") as model_file:
        for block in iter(lambda: model_file.read(8 * 1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != WEIGHT_SHA256:
        raise RuntimeError("translation model weight SHA-256 does not match pinned revision")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--model-dir", type=Path, default=default_model_path())
    args = parser.parse_args()
    path = args.model_dir
    if args.verify_only:
        verify_model(path)
        print(f"Verified {REPO_ID}@{REVISION} at {path}")
        return

    if not (path / "model.safetensors").is_file():
        free_bytes = shutil.disk_usage(path.parent if path.parent.exists() else Path.home()).free
        if free_bytes < MIN_FREE_BYTES:
            raise RuntimeError("at least 4 GiB free space is required to prepare translation weights")

    print(f"Preparing {REPO_ID}@{REVISION} in {path}", flush=True)
    from huggingface_hub import snapshot_download

    snapshot_download(
        repo_id=REPO_ID,
        revision=REVISION,
        local_dir=path,
        allow_patterns=[
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "model.safetensors.index.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "added_tokens.json",
            "chat_template.jinja",
            "merges.txt",
            "vocab.json",
        ],
    )
    verify_model(path)
    print("Pinned translation model verified", flush=True)


if __name__ == "__main__":
    main()
