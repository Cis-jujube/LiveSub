#!/usr/bin/env bash
# One-time pinned R2T2/llama.cpp arm64 build. Does not download model weights.
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R2T2_COMMIT=26d55a54ce5670cff9947a167d8ed95d569fd4d9
LLAMA_COMMIT=ad6c66839af3c5646fba8c6c2e2087a1e4e38948
R2T2_ARCHIVE_SHA=8e257a3be4ccd03eec7750dfe70d51d5201f44cca4f3508a609796d20b220b24
LLAMA_ARCHIVE_SHA=fb02c93eef3b4b13e8bfd1a241f3f18a91ad926ec51cc32fb4c9a2bfe6f37208
BUILD_ROOT="$ROOT/.build/r2t2"
DOWNLOAD_ROOT="$BUILD_ROOT/downloads"
SOURCE="$ROOT/third_party/Confucius4-R2T2"
LLAMA_SOURCE="$BUILD_ROOT/llama.cpp"
BUILD_ENV="$BUILD_ROOT/build-env"
BUILD_DIR="$BUILD_ROOT/native"
RUNTIME_PYTHON="$ROOT/backend/.venv/bin/python"
APP_SUPPORT="${LIVESUB_APP_SUPPORT:-$HOME/Library/Application Support/LiveSub}"
APP_RUNTIME="$APP_SUPPORT/runtime/Confucius4-R2T2-$R2T2_COMMIT"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "R2T2 native build requires arm64 macOS." >&2
  exit 1
fi
for command_name in uv curl tar shasum patch file otool rg ditto; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required build command missing: $command_name" >&2
    exit 1
  fi
done
if [[ ! -x "$RUNTIME_PYTHON" ]]; then
  echo "Prepare backend/.venv first: cd backend && uv sync" >&2
  exit 1
fi
if [[ "$("$RUNTIME_PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" != 3.12 ]]; then
  echo "The backend Python environment must use CPython 3.12." >&2
  exit 1
fi

mkdir -p "$DOWNLOAD_ROOT"

download_verified() {
  local url="$1" archive="$2" expected="$3" actual
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 240 \
      --output "$archive.part" "$url"
    mv "$archive.part" "$archive"
  fi
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Source archive checksum mismatch: $archive" >&2
    echo "Expected $expected, got $actual" >&2
    exit 1
  fi
}

download_verified \
  "https://codeload.github.com/netease-youdao/Confucius4-R2T2/tar.gz/$R2T2_COMMIT" \
  "$DOWNLOAD_ROOT/r2t2-$R2T2_COMMIT.tar.gz" "$R2T2_ARCHIVE_SHA"
download_verified \
  "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$LLAMA_COMMIT" \
  "$DOWNLOAD_ROOT/llama-$LLAMA_COMMIT.tar.gz" "$LLAMA_ARCHIVE_SHA"

if [[ ! -d "$SOURCE" ]]; then
  mkdir -p "$SOURCE"
  tar -xzf "$DOWNLOAD_ROOT/r2t2-$R2T2_COMMIT.tar.gz" -C "$SOURCE" \
    --strip-components=1 \
    --exclude='*/r2t2_llama/bin/*' \
    --exclude='*/r2t2_llama/native/*.so' \
    --exclude='*/resources/*.mp4' \
    --exclude='*/resources/*.wav'
  printf '%s\n' "$R2T2_COMMIT" > "$SOURCE/UPSTREAM_COMMIT"
fi
if [[ "$(cat "$SOURCE/UPSTREAM_COMMIT" 2>/dev/null || true)" != "$R2T2_COMMIT" ]]; then
  echo "Existing third_party/Confucius4-R2T2 has an unknown revision; refusing to overwrite." >&2
  exit 1
fi
if [[ ! -d "$LLAMA_SOURCE" ]]; then
  mkdir -p "$LLAMA_SOURCE"
  tar -xzf "$DOWNLOAD_ROOT/llama-$LLAMA_COMMIT.tar.gz" -C "$LLAMA_SOURCE" \
    --strip-components=1
  printf '%s\n' "$LLAMA_COMMIT" > "$LLAMA_SOURCE/UPSTREAM_COMMIT"
fi
if [[ "$(cat "$LLAMA_SOURCE/UPSTREAM_COMMIT" 2>/dev/null || true)" != "$LLAMA_COMMIT" ]]; then
  echo "Existing llama.cpp source has an unknown revision; refusing to overwrite." >&2
  exit 1
fi

apply_once() {
  local patch_file="$1"
  if patch -RC -d "$SOURCE" -p1 -i "$patch_file" >/dev/null 2>&1; then
    return
  fi
  if ! patch -C -d "$SOURCE" -p1 -i "$patch_file" >/dev/null 2>&1; then
    echo "Source patch does not apply cleanly: $patch_file" >&2
    exit 1
  fi
  patch -d "$SOURCE" -p1 -i "$patch_file"
}

apply_once "$ROOT/third_party/patches/r2t2-macos-rpath.patch"
apply_once "$ROOT/third_party/patches/r2t2-private-finish.patch"
apply_once "$ROOT/third_party/patches/r2t2-private-native-logging.patch"

if [[ ! -x "$BUILD_ENV/bin/python" ]]; then
  uv venv --python 3.12 "$BUILD_ENV"
fi
uv pip install --python "$BUILD_ENV/bin/python" cmake==4.4.3 pybind11==3.1.0
PYBIND11_DIR="$("$BUILD_ENV/bin/python" -m pybind11 --cmakedir)"
"$BUILD_ENV/bin/cmake" -S "$SOURCE/r2t2_llama" -B "$BUILD_DIR" \
  -DLLAMA_CPP_DIR="$LLAMA_SOURCE" \
  -DPython_EXECUTABLE="$RUNTIME_PYTHON" \
  -Dpybind11_DIR="$PYBIND11_DIR" \
  -DGGML_CUDA=OFF -DGGML_METAL=ON \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Release
"$BUILD_ENV/bin/cmake" --build "$BUILD_DIR" --parallel 8

mkdir -p "$SOURCE/r2t2_llama/bin"
cp -a "$BUILD_DIR"/bin/lib*.dylib "$SOURCE/r2t2_llama/bin/"
EXTENSION="$SOURCE/r2t2_llama/native/qwen3asr_native.cpython-312-darwin.so"
if [[ ! -f "$EXTENSION" ]] || ! file "$EXTENSION" | rg -q 'Mach-O 64-bit bundle arm64'; then
  echo "arm64 CPython 3.12 native extension was not produced." >&2
  exit 1
fi
if ! otool -l "$EXTENSION" | rg -q '@loader_path/../bin'; then
  echo "Native extension is missing its portable @loader_path RPATH." >&2
  exit 1
fi

mkdir -p "$APP_RUNTIME"
ditto "$SOURCE" "$APP_RUNTIME"
PYTHONPATH="$APP_RUNTIME${PYTHONPATH:+:$PYTHONPATH}" "$RUNTIME_PYTHON" -c \
  'from r2t2_llama.native.qwen3asr_native import Qwen3ASRNative; print("R2T2 native import OK")'
echo "R2T2 source: $R2T2_COMMIT"
echo "llama.cpp source: $LLAMA_COMMIT"
echo "Local runtime: $APP_RUNTIME"
echo "Model weights are prepared separately under Application Support/models/r2t2."
