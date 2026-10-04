# Translation generation and compiler experiments, 2026-10-03

The retained change is the complete-text greedy generator in `backend/livesub/translation/prompt_cache.py`. Whole-MLP compilation, packed projection fusion, previous-output speculative verification, a tensor-state compiled decoder, a larger allocator cleanup threshold, and ASR encoder FFN compilation were tested and rejected for this iteration. None of the rejected adapters, flags, or draft state remains in the application runtime. This record does **not** establish the requested source-update-to-complete-current-translation median below 300 ms.

## Environment and measurement scope

These experiments used the existing Apple M5 Pro Mac with 16 GPU cores and 48 GiB unified memory, MLX 0.32.2, MLX-LM 0.29.1, and `mlx-community/Qwen3-4B-Instruct-2507-4bit` at revision `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b`. No dependencies or weights were changed. The environment inspection and primary-source hardware research are recorded in [the hardware report](english-chinese-hardware-research-2026-10-02.md).

Every full-text comparison ran serially on one loaded model and one worker, alternating old/new request order. Each mode retained its own prompt cache. Timings include translation preparation and complete generation, excluding model load, audio capture, ASR, IPC, and native UI rendering. Inputs are repository public/synthetic fixtures with an isolated terminology file. Complete prompts, EOS behavior, and the 256-token limit were retained; faster results were not obtained by shortening the output cap. Individual JSON files retain per-request outputs and timing.

The initial fixture contains 60 inputs: 48 sentences and 12 isolated terms. Two rounds yield 96 sentence pairs and 24 term pairs. The extended [96-input fixture](translation-round2-cases.json) contains 60 distinct sentences, 12 isolated terms, and 24 growing/revising inputs in six same-segment sequences. Its distinct-sentence group contains 58 English inputs and two Chinese controls. A pair means one before/after comparison of the same input, not two independent observations. Baselines differ between experiments; their absolute timings must not be compared across runs or fixture groups.

## Retained complete-text generator

The existing application consumes a complete translation string. The installed streaming generator also constructs a vocabulary detokenizer, normalizes the full vocabulary into log probabilities, and creates token-level response/statistics objects. The specialized path collects raw token IDs and decodes once, samples directly from logits, and reuses small allocator buffers. It keeps the upstream prompt prefill split, asynchronous one-token lookahead, tokenizer BOS rule and EOS set, scoped wired-memory limit, and stream synchronization before the shared model worker releases ownership. Matching prompt prefixes are retained; generated output and lookahead tails are trimmed before the next request. Failure resets the prompt cache. The allocator cache is cleared when it exceeds 256 MiB, independently of retained prompt KV state. See the [installed-version generation source](https://github.com/ml-explore/mlx-lm/blob/v0.29.1/mlx_lm/generate.py) and [tokenizer source](https://github.com/ml-explore/mlx-lm/blob/v0.29.1/mlx_lm/tokenizer_utils.py).

In the initial paired experiment, all **120/120** complete outputs matched the R1 prompt-cached upstream generator. Sentence median decreased **299.054 → 232.439 ms**, a 22.3% reduction; sentence total decreased **29,513.882 → 23,006.150 ms**. These 96 sentence pairs include 92 English pairs and four Chinese control pairs. Isolated terms required no generation and measured **0.605 → 0.582 ms**; they do not demonstrate ordinary-sentence inference speed. Evidence: [generator-ab.json](../.build/latency-20261002-round2/generator-ab.json).

Direct argmax and subtracting a scalar normalization constant have the same mathematical maximizer. Finite-precision subtraction can round close logits into a tie, so this is a measured output-parity result, not a universal numerical identity guarantee. Complete-output checks remain necessary when changing models, versions, or prompt settings.

The production backend suite after removing the rejected prototypes passed **143 tests**, with one existing Starlette/httpx deprecation warning. CPU generator tests cover prompt/BOS handling, EOS sets, output limits and lookahead, allocation-cache bounds, and cache reuse/failure behavior. A separate review checked tokenizer Unicode/whitespace parity. These checks do not replace native system-audio acceptance.

## Full-request candidate results

All times below are milliseconds. “Sentence” is the distinct-sentence group, excluding isolated terms and growing/revising inputs. Candidate baselines already use the retained greedy path unless the row explicitly says R1 upstream. Exact output counts cover every pair, including terms and revisions.

| Candidate and evidence | Rounds / pairs | Exact complete outputs | Sentence median, before → after | English sentence median, before → after | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| Complete-text generator vs R1 upstream, [JSON](../.build/latency-20261002-round2/generator-ab.json) | 2 / 120 | 120 / 120 | 299.054 → 232.439 | Not separately summarized in this early JSON | Retain |
| Stateless whole MLP compile, [JSON](../.build/latency-20261002-round2/mlp-compile-ab.json) | 2 / 120 | 120 / 120 | 218.696 → 215.407 | 213.805 → 213.226 | Reject negligible English gain |
| Prior-output verified draft, [JSON](../.build/latency-20261002-round2/verified-draft-ab.json) | 2 / 192 | 186 / 192 | 221.028 → 225.882 | 219.551 → 220.286 | Reject semantic regression |
| Singleton MLP + QKV fusion, lazy projection groups, [JSON](../.build/latency-20261002-round2/fused-combined-ab.json) | 1 / 96 | 96 / 96 | 226.348 → 231.302 | 220.461 → 223.966 | Reject no request gain |
| Singleton MLP + QKV fusion, direct forwards, [JSON](../.build/latency-20261002-round2/fused-direct-ab.json) | 1 / 96 | 96 / 96 | 249.493 → 252.413 | 242.140 → 244.938 | Reject no request gain |
| Tensor-state compiled L1 decode, [JSON](../.build/latency-20261002-round2/tensor-decoder-ab.json) | 1 / 96 | 96 / 96 | 248.376 → 257.245 | 242.674 → 252.145 | Reject slower generation |

### Stateless MLP compilation

The ignored [MLP benchmark](../.build/latency-20261002-round2/benchmark_mlp.py) compiles the original MLP with `mx.compile(..., shapeless=True)`, retaining its registered parameters. The same loaded model switches to original MLP modules for baseline requests and compiled wrappers for candidate requests. This avoids accidentally giving the baseline the candidate's global model modification.

English sentence median improves only **0.27%**; English p95 is **299.814 → 297.360 ms**, and total is **20,047.619 → 19,971.642 ms** across 92 pairs. The installed SiLU is already compiled; quantized matmul and attention already use optimized operators. These facts explain why surrounding graph compilation is not automatically a large improvement; this experiment does not independently prove the hardware bottleneck. The helper and its prototype tests were removed from production. Compilation behavior and explicit-state requirements are described in [MLX's compiler documentation](https://ml-explore.github.io/mlx/build/html/usage/compile.html).

### Previous-output target-verified draft

This candidate proposed up to four raw output IDs from the preceding translation of the same segment. Immutable session/generation/direction/segment, prompt settings, context, terminology protection, and tokenizer/model scope controlled reuse. The current target model verified every proposed token. Rejection, EOS, and output-budget tails were trimmed; previous text was never returned without inference. Independent CPU review passed 240 causal-cache scenarios and 14 engine scope/worker/reset checks. The pattern was informed by [MLX-LM's installed speculative generator](https://github.com/ml-explore/mlx-lm/blob/v0.29.1/mlx_lm/generate.py) and [Transformers' assisted-generation documentation](https://huggingface.co/docs/transformers/v4.57.1/llm_optims).

The 48 revision pairs improved median **216.594 → 190.559 ms**, but only **42/48** outputs matched. Revision p95 worsened **527.277 → 528.764 ms**. Distinct English sentences gained no speed. Three unique changed outputs recurred in both rounds:

| Fixture | Original ending / wording | Draft candidate ending / wording | Assessment |
| --- | --- | --- | --- |
| `revision-plain-3`, “avoid claiming that a higher score proves anything” | `避免声称分数更高就说明什么。` | `避免声称分数更高就说明一切。` | Changes the scope of the claim; reject |
| `revision-plain-4`, causal-improvement revision | `导致了提升。` | `导致了改进。` | Paraphrase, but differs from baseline |
| `revision-number-2`, unavailable for 0.03 seconds | `系统不可用持续了0.03秒。` | `系统不可用，持续时间为0.03秒。` | Number retained, wording differs |

Both modes passed every lexical check for the revision group, showing that glossary/number checks alone do not detect this quality failure. Diagnostic [top-two-logit records](../.build/latency-20261002-round2/draft-margins.json) showed a later **single-token** prediction at cache position 178 changing from scores `一切=34.75, 什么=34.5` to a `34.25/34.25` tie after earlier batched KV generation. Extra synchronization for diagnosis can itself change near-tie wording, so its timing and output direction are not substitutes for the original A/B. The meaningful finding is that numerical drift persists into later scalar decode: accepting target tokens and trimming offsets does not restore scalar-generated KV values. A margin guard on the current block alone cannot establish baseline equivalence. Guaranteeing original state would require restoring the earlier cache arrays and replaying affected inputs sequentially; that unproven heuristic/replay complexity was not added to the runtime.

The complete rejected runtime and tests are retained in [the ignored candidate snapshot](../.build/latency-20261002-round2/rejected-verified-draft/backend/). Diagnosis scripts, fixtures, and outputs remain alongside it. Production has no verified-draft constructor option, helper, state, or prototype tests.

### Packed projection fusion

The probe concatenated packed quantized weight, scale, and bias rows without requantization. Original modules remained registered for model/wired-memory traversal. Multi-token prefill kept the original projections. The [single-layer microbenchmark](../.build/latency-20261002-round2/fused-blocks.json) used 15 samples per path:

| Projection | Input rows | Baseline median → fused median | Arrays exactly equal | Maximum absolute difference |
| --- | ---: | ---: | --- | ---: |
| Gate/up MLP | 1 | 0.701291 → 0.677416 | Yes | 0 |
| QKV | 1 | 0.299542 → 0.249291 | Yes | 0 |
| Gate/up MLP | 5 | 0.687500 → 0.693292 | Yes | 0 |
| QKV | 5 | 0.245500 → 0.255125 | Yes | 0 |
| Gate/up MLP | 16 | 0.793625 → 0.830667 | Yes | 0 |
| QKV | 16 | 0.312625 → 0.345292 | No | 0.03125 |

The 16-row QKV result ruled out extending this fusion to prefill. Two singleton-only implementations then completed all 96 full-text pairs exactly: a lazy projection group that releases temporary tensors after the final projection, and direct forwards preserving original RMS normalization, RoPE, cache update, SDPA, and output projection. The direct adapter attributes the original [Qwen3 forward implementation](https://github.com/ml-explore/mlx-lm/blob/v0.29.1/mlx_lm/models/qwen3.py).

Neither implementation produced a meaningful full-request gain. Lazy fusion's complete-fixture total increased **19,937.015 → 20,015.946 ms**; direct fusion was effectively unchanged at **21,445.069 → 21,442.853 ms** while sentence medians became slower. Microkernel improvements did not transfer to this workload. Both remain only in the ignored [fusion benchmark](../.build/latency-20261002-round2/benchmark_fusion.py).

### Tensor-state compiled single-token decoder

The ignored [decoder benchmark](../.build/latency-20261002-round2/benchmark_tensor_decoder.py) used the stock model forward with temporary tensor KV proxies. Valid-prefix K/V tensors and a tensor RoPE offset were explicit inputs to a shapeless compiled function; logits and updated K/V were explicit outputs. It did not capture mutable stock cache objects or Python offsets. Stock multi-token prefill was unchanged. Returned states were committed to the stock cache only after the compiled call succeeded. This specifically addresses the mutable-offset hazard in [MLX-LM's stock cache](https://github.com/ml-explore/mlx-lm/blob/v0.29.1/mlx_lm/models/cache.py).

Independent CPU review passed nine checks covering the 255/256/257 boundary, trim 259 → 253, stock prefill after compiled decode, inconsistent offsets, reset, and exception cleanup. An [eight-revision pilot](../.build/latency-20261002-round2/tensor-decoder-tiny-ab.json) matched all outputs but increased median **223.290 → 231.894 ms**. The 96-input comparison also matched all outputs, while English median increased **242.674 → 252.145 ms** and p95 **340.353 → 345.019 ms**. Complete-fixture total increased **21,852.659 → 22,263.994 ms**, approximately 1.9%.

The full-run [diagnostic record](../.build/latency-20261002-round2/tensor-decoder-diagnostics.json) reports a first compiled call of **216.138 ms** outside the warm paired timing, 1,500 compiled decode calls, and two traces initially observed at past lengths 131 and 132. MLX reported allocator cache **215,222,936 bytes**, active memory **2,388,283,476 bytes**, and peak memory **2,903,146,732 bytes**. Two traces support graph reuse in this fixture; they do not prove every possible context length safe. Prefix concatenation, tensor state transfer, and compilation added complexity without reducing measured complete generation, so the decoder was rejected.

### Allocator cleanup threshold

A final ignored probe changed only the retained generator's cleanup threshold from 256 MiB to 1,024 MiB. Shipping code stayed unchanged. One alternating 96-fixture round matched **96/96** outputs with zero errors and 84 generation calls per mode. The 256 MiB mode actually cleared 31 times (one additional warmup clear); the larger-threshold mode cleared zero times. Measured cache immediately before the baseline clears ranged from 273,216,956 to 1,032,854,036 bytes, dropping to 0–5,120 bytes afterward. This exercised the cleanup hypothesis rather than measuring two thresholds that never triggered.

English median was **255.406 → 250.495 ms**, but English p95 worsened **350.786 → 354.267 ms**, and English total increased **14,322.074 → 14,357.163 ms**. Revision median stayed **235.685 → 235.756 ms**; all-fixture total improved only about 0.12%. The larger limit was rejected. The allocator is process-global and requests alternate, so both modes share a pool; these results are not an independent steady-state memory/latency comparison. Observed maximum active memory was 2,415,688,712 bytes, boundary cache 1,036,046,516 bytes, and MLX peak 2,903,146,732 bytes. Shared values do not prove that running the larger limit alone has no memory cost. All request/clear records and the two hash-checked snapshots are preserved in [allocator-ab.json](../.build/latency-20261002-round2/allocator-threshold/allocator-ab.json).

### PyTorch MPS ASR encoder FFN compilation

The existing PyTorch 2.14 installation supports MPS Inductor and runtime Metal shader compilation; this experiment required no new package or external `metal` compiler. The whole Qwen-ASR encoder contains tensor-to-Python lengths and dynamic chunking, so the ignored probe compiled only each layer's final normalization, linear/activation/linear, residual addition and FP16 clamp. AST replacement retained the stock attention and remaining forward statements. Parameter registration and storage identity were verified. `fullgraph=True`, the existing Inductor backend and `suppress_errors=False` prevented silent eager fallback. This was a separate ASR-only full-transcription experiment, not an MT generation test.

One loaded Qwen3-ASR-1.7B model ran an eager and compiled English technical warmup, then exactly three public/synthetic audio pairs with alternating order. All **3/3** complete transcripts matched. The backend recorded 72 FX traces and 96 actual compiled FFN executions, with no fallback. The compiled warmup took **3,446.10 ms** versus eager **946.49 ms**, including first compilation and one numerical check per layer. Cumulative backend compile-callback time was **1,933.18 ms**, excluding some Dynamo tracing and complete-transcription work. A warmed technical clip was **810.78 → 818.92 ms**, approximately 1% slower. Finance and Chinese clips had new encoder shapes and each triggered 24 additional traces: **835.15 → 1,417.88 ms** and **707.52 → 1,310.16 ms** respectively. Those times intentionally retain shape-compilation costs; they are not warm inference comparisons.

Initial 24-layer tensor checks were finite and allclose, with maximum absolute difference **0.00390625**, rather than exact array identity. Observed allocation snapshots were 4,097,564,672 current MPS bytes and 5,693,603,840 driver bytes, not a measured process/RSS peak. The bounded probe exited successfully, restored original forwards, and was not adopted: warmed full transcription did not improve, while changing input shapes introduced material extra latency. The complete outputs, graph/input-shape counters, fixture hashes, source/version metadata and validation remain in [asr-ffn-compile-results.json](../.build/latency-20261002-round2/asr-ffn-compile/asr-ffn-compile-results.json). The installed Torch binary's source revision differs from the public v2.14 tag; the hardware report distinguishes installed-code evidence from official API documentation.

## Acceptance boundary

These are local experiment results. Earlier sustained backend audio replay with the retained greedy path measured source-update-to-current-translation median **324.62 ms**, p90 **538.76 ms**, and actual generation median **333.24 ms**, with negligible translation ownership wait. That replay is retained as [diagnostic evidence](../.build/latency-20261002-round2/live-greedy-en-sustained.json); it does not pass the 300 ms requirement and is not native system-audio capture. Final repeated R1 comparisons and live validation are recorded separately in the iteration report. No compiler candidate here justifies claiming the target met, and neither successful tests nor exact fixture outputs establish live native UI/audio acceptance.

Experimental scripts, source snapshots, and JSON are preserved under `.build/latency-20261002-round2/` for local reproduction and are ignored by Git. Their presence is evidence of rejected experiments, not enabled application features. The production change remains the specialized complete-text generator plus the existing R1 prompt-cache and terminology logic.
