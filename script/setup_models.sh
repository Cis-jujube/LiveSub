#!/bin/bash
# One-time, repeatable setup for the personal local LiveSub.app installation.
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support_root="$HOME/Library/Application Support/LiveSub"
app_backend="$repo_root/dist/LiveSub.app/Contents/Resources/backend"
runtime_root="$support_root/runtime/Confucius4-R2T2-26d55a54ce5670cff9947a167d8ed95d569fd4d9"
app_python="$support_root/backend/.venv/bin/python3"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "LiveSub requires an Apple Silicon Mac." >&2
    exit 1
fi
if ! command -v uv >/dev/null; then
    echo "uv is required for one-time setup; see README.md." >&2
    exit 1
fi
if [[ ! -x "$(xcrun --find swiftc 2>/dev/null || true)" ]]; then
    echo "Xcode Command Line Tools and Swift are required for one-time setup." >&2
    exit 1
fi
if pgrep -x LiveSub >/dev/null; then
    echo "Quit LiveSub before preparing or replacing its runtime and application." >&2
    exit 1
fi

mkdir -p "$support_root/backend"
echo "[1/6] Prepare locked Python 3.12 development environment"
uv sync --project "$repo_root/backend" --locked --python 3.12

echo "[2/6] Build pinned Apple Silicon R2T2 native runtime (Metal)"
"$repo_root/script/build_r2t2_native.sh"

echo "[3/6] Prepare pinned R2T2 GGUF/projector and processor assets (~1.4 GB)"
PYTHONPATH="$repo_root/backend" \
    "$repo_root/backend/.venv/bin/python" -m livesub.asr.download_model

echo "[4/6] Prepare pinned local Qwen translation weights (~2.3 GB)"
PYTHONPATH="$repo_root/backend" \
    "$repo_root/backend/.venv/bin/python" -m livesub.translation.download_model

echo "[5/6] Build and ad hoc sign personal LiveSub.app"
"$repo_root/script/build_and_run.sh" --build-only

echo "[6/6] Install locked application Python environment in Application Support"
UV_PROJECT_ENVIRONMENT="$support_root/backend/.venv" \
    uv sync --project "$app_backend" --locked --no-dev --python 3.12
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$app_backend:$runtime_root" \
    "$app_python" -c 'from livesub.asr.r2t2 import R2T2ASREngine; from livesub.translation.mlx_engine import MLXTranslator; from livesub.server import main; print("LiveSub packaged backend imports OK")'

echo "Local setup complete. Open $repo_root/dist/LiveSub.app"
echo "macOS microphone or screen recording permission is requested only when you start that source."
