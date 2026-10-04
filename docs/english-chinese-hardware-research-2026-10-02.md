# English → Chinese hardware and compiler research, 2026-10-02

Scope: optimize complete ordinary-sentence translations on the existing local models. The target is below 300 ms for a complete translation after its source update, including scheduling delay where measured. First-token timing, shorter output caps, output truncation, and term-only dictionary matches do not establish that target. This document records research and experiment candidates; measured outcomes belong in the iteration report.

## Verified local environment

Read from the existing backend environment and model configuration without installing packages or downloading models:

| Item | Observed value |
| --- | --- |
| macOS | 27.0.1, build 26A434 |
| GPU reported by MLX | Apple M5 Pro, `applegpu_g17s` |
| Unified memory reported by MLX | 51,539,607,552 bytes, 48 GiB |
| Recommended Metal working set reported by MLX | 40,200,896,512 bytes |
| MLX | 0.32.2 |
| MLX-LM | 0.29.1 |
| PyTorch | 2.14.0 |
| Transformers | 4.57.6 |
| Qwen-ASR | 0.0.6 |
| Translation weights | Qwen3-4B-Instruct-2507, affine 4 bit, group size 64 |
| Translation architecture | 36 layers, hidden width 2,560, 32 query / 8 KV heads, head dimension 128, vocabulary 151,936 |
| Local ASR weights | Qwen3-ASR-1.7B, currently loaded through PyTorch MPS |

Versions came from `importlib.metadata`; hardware came from `mlx.core` device information; the OS came from `sw_vers`. Model architecture came from the installed translation model's `config.json`. The checked model directory contains the ASR and translation models above; it contains no separate speculative draft model or converted Core ML model.

Apple describes the M5 Pro family as supporting **up to** 307 GB/s unified memory bandwidth. This is a family maximum, not a measurement of this particular 16-GPU-core configuration. This report does not transfer the bandwidth of an M5 Max or a different Pro configuration to this machine. [Apple's M5 Pro / Max announcement](https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/).

## What the hardware can and cannot accelerate automatically

M5 GPU Neural Accelerators and the standalone Neural Engine are distinct hardware. Apple explains that LLM prefill uses matrix products with high arithmetic intensity, while single-token decode spends much of its time reading weights. Its M5 discussion reports a much larger prefill improvement than decode improvement and identifies MLX, llama.cpp, and PyTorch as frameworks already using GPU Neural Accelerators. TensorOps enables lower-level kernels and fused post-processing, but adopting it is not a general switch that guarantees a 4× improvement for complete translations. [Apple's M5 machine-learning technical talk](https://developer.apple.com/videos/play/tech-talks/111432/).

The installed MLX 0.32.2 already includes M5-aware kernels. Its release notes include NAX quantized matmul tuning and fused attention work. The newer 0.32.3 release has fixes and shape-specific improvements; the release notes do not establish that upgrading alone will cut this Qwen3 translation workload below 300 ms. [MLX releases](https://github.com/ml-explore/mlx/releases).

For affine quantized linear layers, the installed-version upstream Metal dispatch selects matrix/vector kernels according to row count and shape. The single-token case follows a vector route; larger prefill batches use a different matrix route. This matches the reason that tensor-core improvements to large matrix operations may improve prefill more than autoregressive decode. This is an inference from the exact dispatch source, not a local kernel-profile result. [MLX 0.32.2 quantized Metal dispatch](https://github.com/ml-explore/mlx/blob/v0.32.2/mlx/backend/metal/quantized.cpp#L1782-L1845).

## Priority 1: existing dependency and weight set

### Remove generation work unused by this application

Installed `mlx_lm/generate.py`, `generate_step`, computes a full-vocabulary `logsumexp` and log-probability vector even when the sampler is greedy argmax. It also evaluates a lookahead model step. The application consumes complete text, not token log probabilities. A specialized greedy path can sample directly from logits because subtracting the same normalization constant does not change argmax.

Preserve EOS handling, tokenizer decoding, complete-output limits, prompt-prefix trimming, model-worker ownership, and exceptions. Compare complete text to the old greedy path on ordinary sentences, numbers, names, negation, unfinished clauses, multiple terminology markers, and changed session settings. Measure output token count alongside duration so faster completion is not attributable to shortened output.

Local sources inspected: `backend/.venv/lib/python3.12/site-packages/mlx_lm/generate.py` (`generate_step`, lines 298–463), `sample_utils.py` (`make_sampler`), and `backend/livesub/translation/prompt_cache.py`. This candidate needs no package declaration change.

### Compile stateless Qwen blocks before compiling mutable caches

The installed Qwen3 model already uses `mx.fast` attention and fused normalization; `nn.silu` is independently compiled. A surrounding MLP graph still provides an opportunity to fuse SiLU with the gate/up multiplication and reduce Python graph construction. Compiling the stateless MLP is a more contained initial probe than compiling the entire mutable model step.

`mx.compile` supports explicit input/output captures. It caches compiled graphs and may recompile on changed shapes or types. `shapeless=True` does not make Python control flow dependent on tensor shape safe automatically. [MLX compilation documentation](https://github.com/ml-explore/mlx/blob/main/docs/src/usage/compile.rst).

Installed Qwen `KVCache.offset` is a Python integer; caches allocate in 256-token steps. A naive compiled closure can capture an old RoPE offset or old cache slice. Whole-step compilation therefore requires tensor state/position inputs or an otherwise verified cache design. Successful compilation is insufficient: check generated token sequences, varying prefix lengths, cache trims, session resets, and chunk boundaries. Do not change package internals globally to hide the probe.

Local sources inspected: `mlx_lm/models/qwen3.py`, `mlx_lm/models/base.py`, `mlx_lm/models/cache.py`, and `mlx/nn/layers/activations.py` in the existing `.venv`.

### Combine packed projection output rows without requantizing weights

Installed `nn.QuantizedLinear` passes packed `weight`, `scales`, and affine quantization `biases` to `mx.quantized_matmul`. For projections with the same input width and quantization settings, concatenate these arrays along output-row axis zero, then split the resulting output channels. This retains every original packed 4-bit group and scale/bias; no dequantization, requantization, new model, or new dependency is required. Gate and up projections are an especially small MLP experiment: preserve the existing down projection and combine only gate/up. QKV projections can use the same packed-row operation, but this report avoids a copied attention implementation or a hidden shared-call memoizer.

An ignored helper at `dist/research/benchmark_fused_projections.py` contains an opt-in `FusedGateUpMLP`, a projection-only `FusedQKVProjection`, and an isolated single-layer benchmark. It validates affine/group-64/4-bit layout and normal `nn.Module.parameters()` traversal/storage, checks numerical differences, and alternates timing order. Syntax was checked; the research worker did not load weights or run the benchmark. Projection/block timing is a screening result, not complete-translation performance. Concatenation can change kernel dispatch shapes, so compare complete greedy outputs before any production adoption.

The installed-version Metal source already reuses each weight group across up to five input vectors in its affine `qmv_wide` route. For this gen-17 GPU, a five-row verification pass remains below the matrix-route threshold for the inspected projections and occupies one vector tile. Six to ten rows require two tiles. This does not prove the whole transformer is compute-efficient, but it rules out assuming that five rows necessarily reread every linear weight five times. Increasing projection output width can also change the matrix-route threshold, so benchmark row counts separately. [MLX 0.32.2 vector batch thresholds and reuse implementation](https://github.com/ml-explore/mlx/blob/v0.32.2/mlx/backend/metal/quantized.cpp#L85-L120), [vector tile implementation](https://github.com/ml-explore/mlx/blob/v0.32.2/mlx/backend/metal/quantized.cpp#L537-L578).

### Benchmark MPS execution controls separately from MLX translation

Qwen-ASR's installed `transcribe` method is decorated with `torch.no_grad()`. A caller-scoped `torch.inference_mode()` removes additional autograd bookkeeping and is a precise candidate for an ASR comparison. It may also make no material difference; benchmark identical audio and complete transcripts before adoption.

The inspected real path creates fresh processor tensors, calls `generate`, immediately decodes the token sequences, and returns strings. The model's default generation configuration selects greedy decoding and has no static-cache override; Transformers uses a per-call dynamic cache. Qwen retains `thinker.rope_deltas` but recomputes it when a new generation starts at cache position zero. No autograd/training consumer was found in this live path. Scope an inference-mode guard to the complete real transcription call on its ASR worker; keep model loading outside it. The guard is thread-local and does not replace `model.eval()`. If static caches or tensor-returning APIs are introduced later, review tensors escaping the guard and in-place writes outside it. These are installed-code conclusions, not a passed inference-mode benchmark.

PyTorch 2.14 documents `PYTORCH_MPS_PREFER_METAL=1` as a choice of Metal matmul kernels instead of MPSGraph. Test it in a separate short-lived benchmark process, set before importing Torch, and compare warm ASR duration and transcript output. It does not change MLX translation kernels. `PYTORCH_MPS_FAST_MATH=1` is a separate numerical change and should not be combined into the first test. CPU fallback is a compatibility path, not a speed optimization. [PyTorch 2.14 MPS environment-variable source](https://github.com/pytorch/pytorch/blob/v2.14.0/docs/source/mps_environment_variables.md).

The installed Torch supports a limited MPS Inductor path: `torch/_inductor/codegen/common.py:619` registers `MetalScheduling` with a Python wrapper, and `scheduler.py:9311` explicitly exempts MPS from the missing-Triton error. The backend source still calls itself an early prototype and is not feature complete. This is static support evidence, not a successful Qwen-ASR compilation or measured speedup. [Official v2.14 backend registration](https://github.com/pytorch/pytorch/blob/v2.14.0/torch/_inductor/codegen/common.py#L618-L625), [MPS exemption from the Triton requirement](https://github.com/pytorch/pytorch/blob/v2.14.0/torch/_inductor/scheduler.py#L9305-L9314).

The Python wrapper's JIT path compiles generated Metal source through `runtime/runtime_utils.py:209` → `torch.mps.compile_shader` → `_mps_compileShader`. Torch embeds its included `c10/metal` headers, then the C++ implementation calls Metal's `newLibraryWithSource`. This path does not invoke the missing `xcrun metal` compiler or require a Triton installation. Keep the default Python wrapper and default compile mode; this conclusion does not establish prerequisites for an offline Metal build, C++ wrapper, AOT artifact, or CUDA-graph modes. [Official v2.14 MPS API documentation](https://github.com/pytorch/pytorch/blob/v2.14.0/docs/source/mps.md#L28-L29), [JIT shader helper](https://github.com/pytorch/pytorch/blob/v2.14.0/torch/_inductor/runtime/runtime_utils.py#L195-L221), [Metal runtime compilation](https://github.com/pytorch/pytorch/blob/v2.14.0/aten/src/ATen/native/mps/OperationUtils.mm#L873-L882).

Version attribution matters here: the local `torch/version.py` reports `2.14.0` and build Git commit `08187d9e0fba026dc8217405802ab5381dc88d90`, whereas the current official `v2.14.0` tag resolves to `2b3ec34829036a65cd9d1398ea72a0167dc37470`. The installed Python source is the local behavior authority; the official tag provides corroborating source/docs and is not claimed to be byte-identical to this wheel. The reported build commit's Metal source independently contains the same runtime-compilation call. [Build-commit source](https://github.com/pytorch/pytorch/blob/08187d9e0fba026dc8217405802ab5381dc88d90/aten/src/ATen/native/mps/OperationUtils.mm#L873-L882).

The installed Qwen-ASR encoder does not offer a statically verified whole-encoder full-graph path. In `qwen_asr/core/transformers_backend/modeling_qwen3_asr.py:691-744`, chunk counts and lengths become Python list sizes, `chunk_lengths.tolist()` controls splitting, tensor lengths control loops and conditions, and a Boolean mask changes the output length. These require graph breaks or a deliberate shape/control-flow redesign. `torch.compile(..., fullgraph=False)` may compile some islands, but tracing and repeated audio lengths can add overhead; setting a compile flag on the entire `transcribe` pipeline is not evidence of improvement. [Official v2.14 data-dependent graph-break documentation](https://github.com/pytorch/pytorch/blob/v2.14.0/docs/source/user_guide/torch_compiler/compile/programming_model.common_graph_breaks.md#L61-L78).

A finite probe that needs no new declared dependency is only the tensor-only encoder feed-forward region at installed lines `561-573`: `final_layer_norm` → `fc1` → activation → `fc2` → residual add → the existing FP16 clamp. Use the existing evaluation mode, dtype and weights, `backend="inductor"`, `mode="default"`, `fullgraph=True`, `dynamic=False`, and established audio shapes. Full-graph errors should remain visible; do not silently claim compilation when it falls back. Compare tensor numerical error, complete transcripts, cold compile cost, warm full ASR latency, and recompilation count. The matrix products can remain external ATen/MPS calls, so the opportunity is fewer tensor-operation dispatches and fusion around normalization/activation/residual operations, not a demonstrated faster matmul backend. This ASR possibility does not shorten the separately measured MLX English→Chinese translation stage by itself.

On 2026-10-03 the parent authorized exactly one bounded FFN probe using the existing local Qwen-ASR model and three existing synthetic WAVs. It ran successfully without new dependencies or external compiler tools and **was rejected for production adoption**. The ignored helper at `.build/latency-20261002-round2/asr-ffn-compile/probe.py` verifies the six installed FFN AST statements, replaces only that region in each instance's forward, and restores the original forward after every transcription. Attention, tensor-to-Python chunk handling, the rest of the encoder, and the mutable decoder retain their installed behavior. The helper checks parameter names, identities, storage pointers, shapes, dtypes, and devices before and after each call. Its counted backend delegates to the existing Inductor implementation with `suppress_errors=False`; the actual run produced 72 FX traces and 96 compiled FFN executions, with no eager fallback.

| Full transcription fixture | Eager | Compiled | Interpretation |
| --- | ---: | ---: | --- |
| en-tech | 810.78 ms | 818.92 ms | Both warm; compiled was 1.01% slower in this pair |
| en-finance | 835.15 ms | 1,417.88 ms | Compiled call includes 24 new-shape traces |
| zh-tech | 707.52 ms | 1,310.16 ms | Compiled call includes 24 new-shape traces |

Each fixture had exactly one measured pair, with A/B order reversed for the middle fixture. A separate en-tech warmup was 946.49 ms eager and 3,446.10 ms compiled; the latter includes first compilation and one numerical comparison per layer. Backend compile callbacks totaled 1,933.18 ms; this number excludes other Dynamo tracing and full-transcription costs. All three complete transcripts matched between variants, and the 24 first-shape layer checks were finite and within the reported tolerance, with maximum absolute FP16 output difference 0.00390625. These limited checks do not prove general ASR accuracy. At the sampled call boundaries MPS tensor allocation was 4,097,564,672 bytes and driver allocation was 5,693,603,840 bytes for both variants; these are sampled residency values, not measured memory peaks. Model loading took 5,251.10 ms separately. The stable report `.build/latency-20261002-round2/asr-ffn-compile/asr-ffn-compile-results.json` retains fixture hashes, reference and actual texts, durations, source hashes, build/tag distinction, traces, numerical checks, memory samples, order, and errors. No additional warmup/retry or production change was performed after this inconclusive/slower result.

### Synchronization and command-buffer tuning are experiments

MLX documents `MLX_METAL_FAST_SYNCH` and command-buffer tuning variables; architecture overrides can select incompatible kernels. Defaults are hardware selected. A process-local experiment can isolate synchronization changes, but application defaults should change only after repeated full-output tests. Do not force a different GPU architecture or change system memory limits as a latency shortcut. [MLX environment-variable documentation](https://ml-explore.github.io/mlx/build/html/usage/environment_variables.html).

The exact 0.32.2 source chooses command-buffer limits from the last character of the GPU architecture string. This machine reports `applegpu_g17s`; its `s` branch selects **50 operations and a size-accounting limit of 50**, then applies `MLX_MAX_OPS_PER_BUFFER` / `MLX_MAX_MB_PER_BUFFER` overrides. The source commits when **either** limit is exceeded. A useful bounded comparison is the default 50/50 versus `MLX_MAX_OPS_PER_BUFFER=100 MLX_MAX_MB_PER_BUFFER=100` in a fresh short-lived benchmark process, with identical full outputs and sequential GPU use. Increasing only the operation limit may leave the size threshold dominant. These values describe command-buffer accounting, not the GPU's physical bandwidth or an allocation allowance. [MLX 0.32.2 device / encoder implementation](https://github.com/ml-explore/mlx/blob/v0.32.2/mlx/backend/metal/device.cpp#L511-L626).

The source reads these variables once into static values. `MLX_METAL_FAST_SYNCH` defaults to 0 and selects the CPU/GPU cross-stream `Fence` implementation; it is not a universal replacement for every GPU completion wait. This application has no explicit CPU MLX graph in the inspected translation path, so it is a lower-priority probe than command-buffer batching. All five inspected MLX/MPS tuning variables were unset in the research process environment. [MLX 0.32.2 environment readers](https://github.com/ml-explore/mlx/blob/v0.32.2/mlx/utils.h#L182-L211), [Metal Fence implementation](https://github.com/ml-explore/mlx/blob/v0.32.2/mlx/backend/metal/fence.cpp#L9-L78).

## Priority 2: existing APIs with uncertain benefit or quality cost

A previous translation of the same revising subtitle can also provide candidate token IDs without a second model. This adapts the idea behind [Prompt Lookup Decoding](https://github.com/apoorvumang/prompt-lookup-decoding) and [Transformers assisted decoding](https://huggingface.co/docs/transformers/v4.57.1/llm_optims): process a short proposed continuation in one target-model call, accept only the contiguous target-greedy matches, and roll back every rejected cache position. New segments, changed context/settings, EOS and output budgets need explicit handling. The earlier output supplies a proposal, never an accepted translation by itself.

This is not a universal numerical identity guarantee. Batched verification and single-token decoding can use different Metal kernels and rounding; [an upstream MLX-LM report](https://github.com/ml-explore/mlx-lm/issues/1423) describes greedy-output divergence with a different model and MLX version. Actual same-segment output comparisons are required for this candidate as well as complete current-revision latency. The measured result must distinguish ordinary new sentences from revising sentences with usable prior output.

MLX-LM 0.29.1 already exposes `kv_bits`, `kv_group_size`, and `quantized_kv_start` in generation. This compresses the KV cache, not the 4-bit model weights. With a short subtitle prompt, KV data is much smaller than the weights, and quantization adds work and changes attention numerics. It is an optional measured probe, not an expected cure for short ordinary-sentence decode latency. The existing prompt cache also expects layer lengths and safe trimming; check compatibility before integrating a quantized cache.

The installed generator exposes speculative generation with a `draft_model`. It verifies draft tokens with the target model and can improve effective decode throughput when acceptance and verification batch size are favorable. There is no locally available separate draft model in the inspected model directory. Do not count speculative decoding as an already available optimization or download a new model during a dependency-preserving iteration.

## Priority 3: alternatives requiring explicit follow-up scope

| Alternative | Why research it | Required preparation / review |
| --- | --- | --- |
| New smaller translation or speculative draft model | Fewer bytes per autoregressive step, or more target-verified tokens per target step | Select source and license, size/download target, model manifest, complete-sentence quality baseline, then obtain the required scope approval |
| MLX / MLX-LM version change | A relevant upstream fix may improve a measured hot shape | Identify exact feature/commit and compatible version; package declarations or lockfile changes need approval |
| New inference runtime or custom quantized TensorOps kernel | Fuse dequantization, matmul, and activation if profiling proves this is the bottleneck | Additional dependency/build surface or wider architecture change requires concrete scope and approval; accuracy and maintenance cost must be reviewed |
| Stateful Core ML ASR or translation backend | Keep mutable state inside a compiled native model; potentially use a different compute-unit allocation | Conversion tools, converted weights, compatible operators and shapes, model-state reset, native inference integration, quality and latency comparison |

Core ML supports stateful models and KV state from macOS 15 onward. Apple's published transformer example uses CPU/GPU compute units; it does not prove that this Qwen model can run entirely on the Neural Engine or that ANE placement is faster. Conversion is a separate implementation and validation project. [Core ML stateful-model guide](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html).

### BaseRT standalone comparison prepared, 2026-10-03

BaseRT is a concrete alternative runtime candidate after the existing-framework probes. The public repository contains its Apache-2.0 converter, format, headers and bindings; the native engine is a separate proprietary prebuilt binary. An authorized read-only review verified the official 0.2.6 archive's published SHA-256 and its actual license. That license permits internal evaluation on owned/controlled Apple Silicon but prohibits third-party redistribution and hosting the engine as a service. A local trial and shipping a bundled runtime have different scope. [BaseRT's official license split](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/docs/reference/engine-releases.md).

The current converter has an MLX group-64 INT4 transplant and validation path, so a trial can use the existing local checkpoint. A CPU range audit found exact F16 representability for all source scales/biases; unquantized norms need separate carried-F32 validation. No speed or full numerical-parity claim follows from those storage checks. The exact reviewed artifact, license, estimates, commands, ctypes wrapper and 96-fixture criteria are recorded in [the isolated BaseRT benchmark proposal](basert-isolated-benchmark-proposal-2026-10-03.md). Execution remains pending the user's required approval for a new runtime dependency; there is no production integration or package declaration change in this preparation.

The v0.2.6 release tag points to `3b31090e264073528658441edf81ffafe0a86ddf`; the reviewed public 0.2.6 sync is two commits later at `128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6`. Their differences are package-version mirrors and the C patch-version macro. Converter logic, F32 norm preservation, flags, and C structs are unchanged. The existing archive's public headers match the later sync; this source/archive correspondence does not prove a reproducible proprietary binary build. The proposal now distinguishes both commits and requires actual CLI version/help verification after approval. [Official tag-to-sync comparison](https://github.com/basecompute/baseRT/compare/3b31090e264073528658441edf81ffafe0a86ddf...128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6).

## Measurement requirements

1. Compare complete translation duration and live source-update-to-matching-translation duration separately.
2. Retain output, output token count, EOS status, source revision, and context for every measured request.
3. Report warm p50/p90/p95 and the number of ordinary sentences above 300 ms. Report cold model/compile cost separately.
4. Run GPU benchmarks sequentially. Simultaneous agent benchmarks or a second model process would contaminate the measurements.
5. Verify compiler/cache candidates with varying sentence lengths and sessions. Numerical or output changes need explicit quality inspection.
6. Treat the actual system-audio capture, native UI dispatch, and subtitle rendering path as unverified until tested in the app. A backend benchmark cannot establish native end-to-end latency.

Research-only checks for this file: installed version/hardware inspection, current primary-source review, API/source inspection, CPU weight-layout/range inspection, authorized official runtime archive download for license/provenance review, Python syntax checks, and Markdown diff review. No engine/converter execution, native library loading, package changes, model downloads, GPU benchmark run, system setting changes, or app replacement were performed by the research worker.
