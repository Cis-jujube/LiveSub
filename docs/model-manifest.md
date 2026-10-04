# LiveSub model manifest

This is the personal, local installation manifest. Model weights are stored outside the Git checkout in `~/Library/Application Support/LiveSub/models/` and are not bundled into `LiveSub.app`.

## Native English translation candidate: Apple lowLatency

The 2026-10-03 source and independent native preview prefer the system Translation framework for English → Simplified Chinese when it is available. The running formal bundle has not yet been replaced. English (US) and Chinese (Mandarin, Simplified) assets were installed through System Settings after explicit user approval, and `LanguageAvailability` confirmed both translation directions as installed on macOS 27.0.1 (26A434), SDK 27.0. Apple's shared assets are managed by macOS; no new weights or Python dependency declarations were added to this repository.

The helper uses [`lowLatency`](https://developer.apple.com/documentation/translation/translationsession/strategy/lowlatency), available from macOS 26.4, and the [already-installed-language initializer](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:preferredstrategy:)). It cannot request language downloads. The app keeps the existing Qwen model warm for Chinese and fallback requests. Assets missing, older systems, or a failed native request retain the Qwen route; older macOS compatibility is guarded in source but has not been tested on an older device. This does not pin Apple's internal model revision or establish which processor executes it. Evaluation, limitations and evidence are in [round 4](native-translation-round4-2026-10-03.md).

## Translation fallback: Qwen3-4B-Instruct-2507 4-bit MLX

| Item | Pinned value |
| --- | --- |
| Artifact repository | [`mlx-community/Qwen3-4B-Instruct-2507-4bit`](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit) |
| Artifact revision | `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b` |
| Base model | [`Qwen/Qwen3-4B-Instruct-2507`](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507) |
| Conversion provenance | Community card says converted using MLX-LM `0.26.2`; it does not identify the exact base-model commit used for conversion. |
| Quantization | 4-bit, group size 64, as declared in `config.json` |
| Weight | `model.safetensors`, approximately 2.26 GB |
| Weight SHA-256 | `2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f` |
| Model license | Apache-2.0, identified by the community model card and linked to the [official base-model LICENSE](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/blob/main/LICENSE) |
| Inference package | `mlx-lm==0.29.1` with `transformers==4.57.6`; transitive versions fixed in `backend/uv.lock` |
| Local model path | `~/Library/Application Support/LiveSub/models/Qwen3-4B-Instruct-2507-4bit` |

Prepare and verify from the repository root:

```bash
cd backend
uv sync
uv run python -m livesub.translation.download_model
uv run python -m livesub.translation.download_model --verify-only
```

The preparation command downloads only the pinned repository revision, validates its quantization metadata, and checks the complete weight SHA-256. Runtime inference accepts the local path only and does not fetch weights on demand. The official Qwen model card describes this Instruct version as non-thinking mode; this is a model property, not a measured translation-quality claim.

`mlx-lm==0.31.3` ran successfully alone but requires `transformers>=5`; `qwen-asr==0.0.6` pins `transformers==4.57.6`. The selected `mlx-lm==0.29.1` supports the locked environment. The installed `qwen-asr` package uses its Transformers backend on this Mac, without the optional CUDA/vLLM runtime.

## Speech recognition

The current App uses local [`Qwen/Qwen3-ASR-1.7B`](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), revision `7278e1e70fe206f11671096ffdd38061171dd6e5`, under `~/Library/Application Support/LiveSub/models/Qwen3-ASR-1.7B/`. Its two safetensors weight shards are 4,220,320,824 bytes (SHA-256 `a4cd1f1a04d90b757dc7f7dd26254e69a013b19e80efe590a83c6a3bde8608d6`) and 478,200,688 bytes (SHA-256 `6e0b9d9e09e2e0238e7ef3cc8a484ab387e91b90f1900bedf88bc92d7929ccfc`). The model card declares Apache-2.0. `PYTHONPATH=backend backend/.venv/bin/python -m livesub.asr.download_qwen --verify-only` checks both complete hashes from the repository root. The App runs the locked `qwen-asr==0.0.6` Transformers backend on Apple MPS and produces revisable previews after each 800 ms of new audio when processing is caught up, with final recognition at silence boundaries or a 12 s limit.

The following R2T2 manifest is retained for the historical benchmark and optional direct comparison; it is no longer required by the App startup or one-time setup script.

Task 1's exact R2T2 source/model revisions and local Metal validation are recorded in [`compatibility.md`](compatibility.md). Its ASR assets are separate from Qwen translation weights:

| Item | Pinned value |
| --- | --- |
| R2T2 code | [`netease-youdao/Confucius4-R2T2`](https://github.com/netease-youdao/Confucius4-R2T2) commit `26d55a54ce5670cff9947a167d8ed95d569fd4d9` |
| llama.cpp code | [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) commit `ad6c66839af3c5646fba8c6c2e2087a1e4e38948` |
| ASR model source | Official [ModelScope GGUF repository](https://modelscope.cn/models/netease-youdao/Confucius4-R2T2-GGUF), revision `ce1e3170e8a082d3b564ca2982df3e324569cda6` |
| ASR processor source | Official [ModelScope processor repository](https://modelscope.cn/models/netease-youdao/Confucius4-R2T2), revision `c2c4149f42f9f4f9a8526f4279089cbdf39db1f8` |
| GGUF model | `Confucius4-R2T2-Q4_K_M.gguf`, 1,107,404,736 bytes, SHA-256 `fa3cb46c8c3a66a58812b9098ba6e96a0266d4e8c9b3cf5ba34432fd2f9f6466` |
| Audio projector | `mmproj-Confucius4-R2T2-Q8_0.gguf`, 348,336,544 bytes, SHA-256 `8dc2c67e6a0484114928142d098db7ad94ae9f34c78948ef9d37a9678418cb65` |
| ASR code license | [Apache-2.0](https://github.com/netease-youdao/Confucius4-R2T2/blob/26d55a54ce5670cff9947a167d8ed95d569fd4d9/LICENSE) |
| ASR weight license | Separate [NetEase Youdao Model Use License Agreement](https://github.com/netease-youdao/Confucius4-R2T2/blob/26d55a54ce5670cff9947a167d8ed95d569fd4d9/MODEL_LICENSE) |

The historical ASR GGUF and processor files were stored under `~/Library/Application Support/LiveSub/models/r2t2/`. They and the old native runtime were removed from this Mac on 2026-09-30 to reclaim space; the benchmark scripts and results remain. Preparation and independently verified hashes are detailed in [`compatibility.md`](compatibility.md).
