# R2T2 on this Mac: verified compatibility (Task 1)

Checked on 2026-09-26. This is **actual local R2T2 recognition**, not a mock.
The tests below used public prerecorded WAV files; microphone capture and
ScreenCaptureKit system audio are separate tasks and are not proved here.

## Machine and source

`./script/doctor.sh` reported macOS 27.0 (26A428), arm64 Apple M5 Pro, 48 GiB
RAM, Command Line Tools SDK 27.0, Swift 6.4, uv 0.11.18, Python 3.12.13 and
about 267 GiB available after model preparation. Full Xcode is absent; its
`xcrun metal` utility is unavailable. The pinned llama.cpp source nonetheless
compiled its embedded Metal library with Command Line Tools, and runtime logs
confirmed that Metal actually ran.

| Component | Exact source/version |
| --- | --- |
| [Confucius4-R2T2 code](https://github.com/netease-youdao/Confucius4-R2T2) | `26d55a54ce5670cff9947a167d8ed95d569fd4d9` |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | `ad6c66839af3c5646fba8c6c2e2087a1e4e38948`, the upstream `r2t2_llama/README.md` pin (build b10950, llama 0.4.0, ggml 0.23.0) |
| Native build | AppleClang 21.0.0; local CMake 4.4.3; pybind11 3.1.0; CPython 3.12.13 arm64 |
| ASR Python runtime tested | `qwen-asr==0.0.6` **without** `[vllm]`, `torch==2.14.0`, `numpy==2.5.3`, `requests==2.34.2`, `soundfile==0.14.0` |
| Code license | [Apache-2.0](https://github.com/netease-youdao/Confucius4-R2T2/blob/26d55a54ce5670cff9947a167d8ed95d569fd4d9/LICENSE) |
| Weight license | Separate [NetEase Youdao Model Use License Agreement](https://github.com/netease-youdao/Confucius4-R2T2/blob/26d55a54ce5670cff9947a167d8ed95d569fd4d9/MODEL_LICENSE); the code license does not cover the weights |

Direct `git ls-remote https://github.com/...` failed with an HTTP/2 framing
error on this Mac. The exact GitHub commit was verified through GitHub API;
source was obtained from the official `codeload.github.com` commit tarball.
The pinned llama.cpp tarball was obtained the same way. No TLS or host-key
checks were disabled. `third_party/Confucius4-R2T2/` is ignored by Git and
contains extracted upstream source; the committed patches in
`third_party/patches/` reproduce the macOS changes.

## Model assets

The official [ModelScope GGUF repository](https://modelscope.cn/models/netease-youdao/Confucius4-R2T2-GGUF)
was pinned to `ce1e3170e8a082d3b564ca2982df3e324569cda6`. The separate
[processor repository](https://modelscope.cn/models/netease-youdao/Confucius4-R2T2)
was pinned to `c2c4149f42f9f4f9a8526f4279089cbdf39db1f8`. Hugging Face
timed out from this Mac, while ModelScope served the same official publisher's
repositories. Assets are in `~/Library/Application Support/LiveSub/models/r2t2/`
and are ignored by Git. No model safetensors or CUDA/vLLM installation was
needed for `stream_llama`; **the pure llama.cpp decoder still needs the Qwen
processor config and tokenizer** for the upstream streaming algorithm.

| File | Bytes | SHA-256 checked against ModelScope metadata |
| --- | ---: | --- |
| `Confucius4-R2T2-Q4_K_M.gguf` | 1,107,404,736 | `fa3cb46c8c3a66a58812b9098ba6e96a0266d4e8c9b3cf5ba34432fd2f9f6466` |
| `mmproj-Confucius4-R2T2-Q8_0.gguf` | 348,336,544 | `8dc2c67e6a0484114928142d098db7ad94ae9f34c78948ef9d37a9678418cb65` |

Ten small processor/tokenizer files were downloaded at the pinned revision;
each file's SHA-256 matched the official repository API. The source and model
licenses should be reviewed independently before distribution.

## Build and runtime evidence

`./script/build_r2t2_native.sh` reproduces the native build without a global
installation, downloads no weights, and copies the patched Python source and
Mach-O libraries to Application Support. The build, repeated build, and
runtime import succeeded using checksum-verified source tarballs. The first
script attempt to fetch the llama.cpp tarball was slow and interrupted; a
copy of the same previously downloaded, SHA-256-verified official archive
was put in its cache before the successful full build. Its essential CMake
invocation is:

```bash
uv venv --python 3.12 .build/r2t2/build-env
uv pip install --python .build/r2t2/build-env/bin/python cmake==4.4.3 pybind11==3.1.0
.build/r2t2/build-env/bin/cmake -S third_party/Confucius4-R2T2/r2t2_llama -B .build/r2t2/native \
  -DLLAMA_CPP_DIR="$PWD/.build/r2t2/llama.cpp" \
  -DPython_EXECUTABLE="$PWD/backend/.venv/bin/python" \
  -Dpybind11_DIR="$PWD/.build/r2t2/build-env/lib/python3.12/site-packages/pybind11/share/cmake/pybind11" \
  -DGGML_CUDA=OFF -DGGML_METAL=ON -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_BUILD_TYPE=Release
.build/r2t2/build-env/bin/cmake --build .build/r2t2/native --parallel 8
```

The tested extension is `qwen3asr_native.cpython-312-darwin.so`: `file`
identified a Mach-O arm64 bundle. `otool -L` showed `@rpath/libmtmd.0.dylib`,
`@rpath/libllama.0.dylib`, and ggml base/CPU/BLAS/Metal dylibs, rather than
renamed Linux `.so` files. The macOS RPATH patch adds
`@loader_path/../bin` to `LC_RPATH`. A real Chinese recognition smoke run
still passed after temporarily hiding the CMake build `bin/` directory, so
the extension loaded its adjacent packaged dylibs rather than relying on a
temporary build path.

The inference log contained `ggml_metal_init: found device: Apple M5 Pro`,
`load_tensors: offloading 27 repeating layers to GPU`, `offloading output
layer to GPU`, `MTL0_Mapped model buffer size = 1050.43 MiB`, and loaded Metal
compute pipelines. This is runtime evidence of Metal use, beyond the CMake
flag. The first cold one-shot process took about 25 seconds including Python
imports, model load, and initial Metal pipeline compilation; later runs were
faster. These timings do not measure App UI latency.

## Genuine speech tests

Public fixtures were kept outside Git:

- Chinese: R2T2 upstream [`resources/test.wav`](https://github.com/netease-youdao/Confucius4-R2T2/blob/26d55a54ce5670cff9947a167d8ed95d569fd4d9/resources/test.wav), 16 kHz mono PCM16, 6.74 s.
- English: whisper.cpp [`samples/jfk.wav`](https://github.com/ggml-org/whisper.cpp/blob/d09f61a708f3487afa956ff578e60eae5e7a233c/samples/jfk.wav), 16 kHz mono PCM16, 11.0 s.

The upstream `onetime_llama` CLI recognized the Chinese recording as
“之前有顾客自己带酒水，也没加收钱或者不让喝。” and the English recording as
“And so, my fellow Americans, ask not what your country can do for you; ask
what you can do for your country.” The real adapter was then fed 160 ms
frames at audio speed. `RTF` below is ASR computation divided by audio
duration; waiting for real-time pacing is excluded.

| Adapter test | Audio | Frames | ASR compute | RTF | Mean/max push | Final result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Chinese, paced | 6.74 s | 43 | 4.467 s | 0.663 | 102.0/122.6 ms | Full spoken sentence, one final segment |
| English, paced | 11.00 s | 69 | 7.445 s | 0.677 | 106.6/119.0 ms | Full content across two final segments; a spurious “The” appeared at the 6 s split |
| Chinese, 1 s quiet prefix, paced | 7.74 s | 49 | 5.109 s | 0.660 | 102.5/122.1 ms | Full sentence across two final segments, including tail “不让喝。” |

Example repeatable commands, after one-time source/native/model setup:

```bash
cd backend && uv run pytest tests/test_asr_contract.py tests/test_r2t2_adapter.py -v
cd ..
backend/.venv/bin/python script/smoke_r2t2.py /path/to/chinese.wav --language Chinese --pace --show-text
backend/.venv/bin/python script/smoke_r2t2.py /path/to/english.wav --language English --pace --show-text
```

The `--show-text` flag is deliberately opt-in because transcripts may be
private. The smoke script exits nonzero for a missing model, invalid audio,
empty WAV, or empty final transcript. In this investigation, nine deterministic adapter
tests passed, along with the three real paced smoke runs. The new adapter
tests first failed at import before implementation; later regression tests
first reproduced an empty-preview leak and a stale timestamp after restart.
Changing English/Chinese direction requires finishing the active stream;
`set_language` then resets stream state without reloading the model.

## Boundaries and upstream issues

- The upstream `stream_llama` example calls `streaming_transcribe` with a
  non-None `max_new_tokens`. That path imports `vllm.SamplingParams` even
  though the model uses llama.cpp; on this Mac the official demo failed with
  `ModuleNotFoundError: No module named 'vllm'` at `r2t2_asr.py:351`.
  Our adapter sets a four-token budget when creating the llama model and
  leaves the per-call argument as `None`, so it does not require vLLM.
- The upstream cumulative value named `fixed_text` occasionally **retracted**
  text in both languages (for example, Chinese `带酒水` became `带酒` before
  returning to `带酒水`); it also returned empty on a short final frame. The
  adapter therefore treats every live hypothesis as replaceable preview.
  Only `finish_streaming_transcribe` is marked final. An empty transient
  result does not erase the last spoken preview; if flush returns empty after
  a nonempty preview, the adapter finalizes that preview. No append-only
  guarantee is claimed from these GGUF tests.
- A forced 6 s boundary can cut an English phrase and introduce a word or
  punctuation change at the next segment. A future punctuation/silence-aware
  boundary and overlap check should be benchmarked before claiming polished
  long-form subtitle quality.
- Upstream `finish_streaming_transcribe` printed recognized text to stdout.
  `third_party/patches/r2t2-private-finish.patch` removes that line. The
  macOS library path patch is
  `third_party/patches/r2t2-macos-rpath.patch`.
- The pinned llama.cpp `mtmd` DEBUG logger also wrote prompt prefixes,
  including previously recognized text, to stderr. The small
  `third_party/patches/r2t2-private-native-logging.patch` keeps warnings and
  errors while suppressing that DEBUG/INFO output. After rebuilding, a paced
  Chinese smoke run with `--show-text` omitted passed at RTF 0.667, and its
  combined stdout/stderr contained no spoken-text prefix.
- Runtime microphone capture, system audio permission, bilingual translation,
  30-minute stability, and UI-visible latency were **not** validated by
  Task 1 and must have separate evidence.
