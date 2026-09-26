"""Download and verify the pinned R2T2 GGUF and processor files from ModelScope."""

import argparse
from dataclasses import dataclass
import hashlib
from pathlib import Path
import shutil

import requests


GGUF_REPO = "netease-youdao/Confucius4-R2T2-GGUF"
GGUF_REVISION = "ce1e3170e8a082d3b564ca2982df3e324569cda6"
PROCESSOR_REPO = "netease-youdao/Confucius4-R2T2"
PROCESSOR_REVISION = "c2c4149f42f9f4f9a8526f4279089cbdf39db1f8"
FREE_SPACE_RESERVE = 512 * 1024**2


@dataclass(frozen=True, slots=True)
class Asset:
    repo: str
    revision: str
    relative_path: str
    size: int
    sha256: str

    @property
    def url(self) -> str:
        return f"https://modelscope.cn/models/{self.repo}/resolve/{self.revision}/{Path(self.relative_path).name}"


ASSETS = (
    Asset(GGUF_REPO, GGUF_REVISION, "Confucius4-R2T2-Q4_K_M.gguf", 1_107_404_736,
          "fa3cb46c8c3a66a58812b9098ba6e96a0266d4e8c9b3cf5ba34432fd2f9f6466"),
    Asset(GGUF_REPO, GGUF_REVISION, "mmproj-Confucius4-R2T2-Q8_0.gguf", 348_336_544,
          "8dc2c67e6a0484114928142d098db7ad94ae9f34c78948ef9d37a9678418cb65"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/added_tokens.json", 1_566,
          "de40784677cbd1843cabe5fbee078c7e042cd0b62155f0810af5a13842e5722a"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/chat_template.json", 1_161,
          "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/config.json", 6_195,
          "829b3b9cea085a46459353609774b08e4898924253ae6d623c2b4cd855386b23"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/generation_config.json", 142,
          "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/merges.txt", 1_671_853,
          "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/preprocessor_config.json", 330,
          "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/special_tokens_map.json", 1_008,
          "7b376c510ccf9d88bb9bbee41dfc5052122e16e0dec1124a8d8983c59259a9f3"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/tokenizer.json", 11_429_499,
          "0499602714160467f2d68b910651d6216020689f1e016be87a2d0019ee3baeab"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/tokenizer_config.json", 12_487,
          "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
    Asset(PROCESSOR_REPO, PROCESSOR_REVISION, "processor/vocab.json", 2_776_833,
          "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
)


def default_model_dir() -> Path:
    return Path.home() / "Library/Application Support/LiveSub/models/r2t2"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _valid(path: Path, asset: Asset) -> bool:
    return path.is_file() and path.stat().st_size == asset.size and _sha256(path) == asset.sha256


def verify_model(model_dir: Path) -> None:
    for asset in ASSETS:
        path = model_dir / asset.relative_path
        if not _valid(path, asset):
            raise RuntimeError(f"missing or checksum-mismatched R2T2 asset: {path}")


def _existing_ancestor(path: Path) -> Path:
    while not path.exists():
        path = path.parent
    return path


def _preflight(model_dir: Path) -> None:
    remaining = 0
    for asset in ASSETS:
        path = model_dir / asset.relative_path
        if _valid(path, asset):
            continue
        remaining += asset.size
    if remaining and shutil.disk_usage(_existing_ancestor(model_dir)).free < remaining + FREE_SPACE_RESERVE:
        raise RuntimeError(
            f"insufficient free disk space for R2T2 assets: need {remaining + FREE_SPACE_RESERVE:,} bytes"
        )


def _download(asset: Asset, model_dir: Path) -> None:
    path = model_dir / asset.relative_path
    if _valid(path, asset):
        print(f"Verified {asset.relative_path}", flush=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".part")
    print(f"Downloading {asset.repo}@{asset.revision}/{Path(asset.relative_path).name}", flush=True)
    # ModelScope's resolve endpoint returned HTTP 200 with a sliced body but the
    # original Content-Length when sent Range; restart partial files on rerun.
    with requests.get(asset.url, stream=True, timeout=(15, 60)) as response:
        response.raise_for_status()
        linked_etag = response.headers.get("X-Linked-Etag", "").strip('"')
        if linked_etag and linked_etag != asset.sha256:
            raise RuntimeError(f"remote checksum differs from pinned revision: {asset.relative_path}")
        if response.status_code != 200:
            raise RuntimeError(f"unexpected HTTP status {response.status_code} for {asset.relative_path}")
        with partial.open("wb") as output:
            for block in response.iter_content(chunk_size=8 * 1024 * 1024):
                if block:
                    output.write(block)
                    if output.tell() > asset.size:
                        raise RuntimeError(f"download exceeds expected size: {asset.relative_path}")
    if not _valid(partial, asset):
        raise RuntimeError(f"download size or SHA-256 mismatch: {asset.relative_path}")
    partial.replace(path)
    print(f"Verified {asset.relative_path}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, default=default_model_dir())
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        verify_model(args.model_dir)
    else:
        _preflight(args.model_dir)
        for asset in ASSETS:
            _download(asset, args.model_dir)
        verify_model(args.model_dir)
    print(f"Pinned R2T2 assets verified at {args.model_dir}", flush=True)


if __name__ == "__main__":
    main()
