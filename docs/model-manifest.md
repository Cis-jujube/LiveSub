# LiveSub model manifest

This is the personal, local installation manifest. Model weights are stored outside the Git checkout in `~/Library/Application Support/LiveSub/models/` and are not bundled into `LiveSub.app`.

## Translation: Qwen3-4B-Instruct-2507 4-bit MLX

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

`mlx-lm==0.31.3` ran successfully alone but requires `transformers>=5`. The native R2T2 adapter's required `qwen-asr==0.0.6` pins `transformers==4.57.6`, so the resolver rejects that combination. `mlx-lm==0.29.1` was selected only after real Qwen English and Chinese inference succeeded alongside the R2T2 runtime in one Python 3.12 environment. The combined lock includes `qwen-asr==0.0.6` without its optional `vllm` extra and `torch==2.14.0` for the R2T2 Python imports.

## Speech recognition

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

The ASR GGUF and processor files live under `~/Library/Application Support/LiveSub/models/r2t2/`. Their preparation and independently verified hashes are detailed in `docs/compatibility.md`.
