# Translation hardware execution experiments, round 3 — 2026-10-03

The complete English → Chinese translation target remains **unmet**. This round executed the previously prepared BaseRT trial and three local MLX execution/weight experiments. None qualifies for adoption. The shipping translation sources and the running formal app remain at the validated round-2 state. A separate native Apple `lowLatency` benchmark is compiled and prepared, but the required system language assets are not installed, so its translation speed and quality are **unverified**.

## Scope and authorization

The user asked whether better model/hardware communication, GitHub implementations, or a custom model optimization could improve speed, and instructed execution if possible. That instruction followed the concrete [BaseRT isolated trial proposal](basert-isolated-benchmark-proposal-2026-10-03.md); it authorized that internal evaluation with the existing checkpoint and about 2.4 GB of added artifacts. It does not authorize proprietary runtime redistribution or a new shipping model dependency.

Experiments used the existing Apple M5 Pro / 48 GiB machine, MLX 0.32.2, MLX-LM 0.29.1, the existing Qwen3-4B-Instruct-2507 affine-4-bit checkpoint, and the existing [96-fixture set](translation-round2-cases.json). Its canonical SHA-256 is `acef43d9b517fc6a6cb35a452f3ded80950836d3e629142463269c1762d5bff1`. Each trial ran one complete round with 58 ordinary English sentences, 24 same-segment revisions, 12 dictionary-only terms and 2 Chinese controls. GPU model experiments ran sequentially in processes that exited. Model loading and setup are excluded from warm translation timing; maximum generated output remained 256 tokens.

No package declaration/lockfile, model download, personal terminology configuration, audio capture, signing identity or formal bundle changed. The three lossy/scheduling prototypes live under the ignored `.build/latency-20261003-round3` directory. Source files and output hashes are retained in the evidence. Existing staged changes were preserved.

## Results on complete ordinary English sentences

Every MLX comparison alternated old/new order on one loaded model and one worker. BaseRT was a separate process compared for text with the stored round-2 report; it was **not** a contemporary paired timing experiment. Do not interpret its timing difference from the older 225 ms median as a causal percentage improvement.

| Experiment | Current MLX median / P95 | Candidate median / P95 | Complete outputs below 300 ms | Decision |
| --- | ---: | ---: | ---: | --- |
| Read two tokens together, still submit each step | 212.328 / 306.327 ms | 228.728 / 329.055 ms | 54/58 → 50/58 | Reject: slower; all 96 paired texts match |
| Unroll two singleton steps, submit once per chunk | 222.028 / 325.636 ms | 250.016 / 349.513 ms | 52/58 → 42/58 | Reject: slower; all 96 paired texts match |
| 3-bit MLP, retain 4-bit attention and embedding | 215.464 / 300.864 ms | 202.282 / 283.355 ms | 54/58 → 56/58 | Reject: meaning/number regressions |
| BaseRT 0.2.6, matching packed weights, prefix reuse | Not contemporaneously paired | 206.577 / 313.138 ms | 52/58 | Reject adoption: tail still exceeds target; scope divergence |
| BaseRT without prefix reuse, diagnostic | Not contemporaneously paired | 263.960 / 351.659 ms | 40/58 | Diagnostic: all 96 outputs equal the prefix-mode run |

These are screening runs, not confidence intervals or broad accuracy measurements. The two submission/read probes were rejected without additional confirmation because both the median and tail worsened. The mixed-bit prototype and BaseRT did not advance to live ASR/native acceptance because their full-output quality/latency screening failed. The [round-2 paced live result](english-chinese-round2-2026-10-03.md) remains the latest measured ASR + translation execution result; it must not be replaced by this table's standalone medians.

## What the communication profile actually showed

A benchmark-only instrumented copy of the current generator measured host wall time at graph construction, `mx.async_eval` submission and `current.item()` reads. It retained the same singleton decoding and complete outputs: all 96 paired texts matched. Instrumented English median was 211.910 ms versus 212.076 ms without the clocks in that run; the tiny difference is not an optimization claim.

Across the 84 measured model-generated requests, generation wall time totaled **18,755.005 ms**:

| Host boundary | Cumulative time | Fraction of generation wall time |
| --- | ---: | ---: |
| Model graph construction and argmax call | 1,416.950 ms | 7.555% |
| `mx.async_eval` host calls | 12,512.989 ms | 66.718% |
| Reading token values through `.item()` | 11.925 ms | 0.064% |
| Other work, including prefill, synchronization and decode | 4,813.141 ms | 25.663% |

`async_eval` host duration includes the runtime's work and waiting. It is not isolated data-transfer time, CPU compute time, or a GPU-kernel profile. `.item()` reads occur after the existing lookahead submissions, so pending GPU work can be charged to another boundary. The observed result nevertheless rules out claiming that per-token host-value reads alone consume hundreds of milliseconds here. Reducing submission calls was then tested directly and made this workload slower.

The GitHub research included [MLX's CPU/GPU fence issue](https://github.com/ml-explore/mlx/issues/4438), [a decoding optimization proposal](https://github.com/ml-explore/mlx/issues/3789), and [AX Engine's native MLX execution design](https://github.com/defai-digital/ax-engine/blob/main/docs/MLX-BACKEND.md). Their authors' gains are not this machine's measurements. The fence issue concerns distributed/cross-stream work; the current translation path already computes GPU argmax and transfers token IDs, so neither report establishes an applicable speed switch. No distributed fence setting, GPU architecture override or new package was adopted.

## BaseRT: conversion and numerical boundaries

The reviewed 0.2.6 archive was extracted, the actual executable reported version 0.2.6, and its converter supported the prepared flags. Conversion used the existing local model directory and `--target base-q4 --mlx-passthrough --validate --direct-write`; no hub model resolution or requantization was requested. The converter emitted 398 tensors: 253 packed BaseQ4 tensors, 137 F16 norms and 8 F32 norms. Its validation passed for the 253 packed transplants and 137 F16 tensors. A separate CPU check verified **every value of all eight skipped F32 norms** equals the original BF16 value expanded to F32. Per-tensor checksums passed through `basert inspect --verify-checksums`.

The converted file is 2,332,070,912 bytes; the original checkpoint is 2,263,022,417 bytes. Source SHA-256 is `2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f`; converted SHA-256 is `5e616f82072829b2fcc85600546cd1caea3a6ee2a3e3fbbf1e7cfa9b8d519a32`. Head dimension 128, 36 layers, 32 query/8 KV heads, tied embedding and other checked architecture fields match. These checks preserve the supplied weight grid; they do **not** make the proprietary runtime's internal operators numerically identical to MLX.

Both native runs finished all 96 requests with zero engine exceptions and zero exhausted output budgets. Each had 86/96 texts identical to the stored MLX results, including 50/58 ordinary English sentences. Most differences were paraphrase or spacing, but `revision-plain-3` changed “avoid claiming that a higher score proves anything” into “避免声称分数更高就说明一切”. That changes the scope of the statement being rejected. The 96 outputs were identical between native prefix/no-prefix modes, so prefix rollback is not a sufficient explanation for this observed divergence; the precise numerical cause is unproven.

BaseRT is retained only as an internal evaluation artifact under its reviewed license. It has not been integrated into the app or redistributed. The license/provenance limitations in the original proposal still apply.

## Custom model compression: why it was rejected

The isolated prototype dequantized the existing 4-bit MLP grid in memory and recompressed the 108 gate/up/down projections to affine 3 bit, group size 64. Attention, embedding, norms, KV handling, prompts, terminology restoration and output/EOS limits retained their existing implementations. This is lossy recompression of already quantized weights, **not** an optimization from unavailable original high-precision weights. Both candidates' arrays were switched only on the existing worker and each translator owned its own prompt cache.

Measured parameter storage fell from 2,262,920,192 to 1,926,720,512 bytes, a 14.86% reduction. Setup took 1,138.721 ms separately. The ordinary-sentence median improved by about 6.1% in this one paired run, but only 32/96 full texts were identical and manual checks found unacceptable changes:

- `We have 3.5 hours left.` → `我们还剩下三小时零十分。` changes a number.
- `A language model predicts tokens one at a time.` → `一个语言模型一次预测tokens。` loses the sequential meaning.
- Other output included awkward phrases and a stray quote in a Chinese-to-English control.

Both modes happened to pass 94/96 aggregate lexical checks. That matching count does not establish matching quality: one newly wrong duration was offset by other literal predicates changing their outcome. Full case outputs, per-layer weight errors and semantic notes are retained. No compressed model was saved over the original weights or adopted in shipping.

## Next prepared route: native Apple low-latency translation

The installed macOS SDK 27.0 exposes `TranslationSession(installedSource:target:preferredStrategy:)`, `.lowLatency` and `AttributedString.translation.skipsTranslation`. Apple's [lowLatency documentation](https://developer.apple.com/documentation/translation/translationsession/strategy/lowlatency) describes traditional translation models intended for latency-sensitive uses such as live audio, with faster, less fluent translations than `highFidelity`. This is a different model/engine from Qwen, not a way to run Qwen weights on the Neural Engine. Its speed, quality and actual hardware scheduling remain unmeasured locally.

Prepared source:

- [prepare_apple_translation_cases.py](../script/prepare_apple_translation_cases.py) exports the same 96 fixtures using temporary synthetic terminology settings. It constructs protected target spans for native skip-translation attributes; real-estate “agent” is not forcibly changed into an AI term. Source context is used for terminology selection, not supplied as a prompt to the native model.
- [benchmark_apple_translation.swift](../script/benchmark_apple_translation.swift) builds with `xcrun swiftc -O -parse-as-library`, uses only already-installed languages, validates that the session cannot request downloads, runs complete outputs and records direct dictionary cases separately. Its timed scope excludes the exported terminology lookup, ASR, IPC and UI. Native attributed-text translation itself is not verified until language assets are available.

The Swift tool compiled successfully, the export contains all 96 cases/12 dictionary cases, and the actual one-shot readiness run returned `supported_not_installed` for **both** English → Simplified Chinese and the reverse direction. It attempted zero translations and zero downloads. Native permission to add these system language assets is pending; no model-speed result is reported for this route.

Once the language assets are installed, reproduce the prepared standalone evaluation with:

```sh
xcrun swiftc -O -parse-as-library script/benchmark_apple_translation.swift \
  -o .build/latency-20261003-round3/benchmark_apple_translation
backend/.venv/bin/python -B script/prepare_apple_translation_cases.py \
  --output .build/latency-20261003-round3/apple-prepared-cases-new.json
.build/latency-20261003-round3/benchmark_apple_translation \
  .build/latency-20261003-round3/apple-prepared-cases-new.json \
  .build/latency-20261003-round3/apple-native-results-new.json 3
```

Output paths must be new, to preserve earlier evidence. A compiled tool and available API are preparation evidence, not translation-performance acceptance. Integration would still need full terminology/negation/tail review, a paced live session and the separate native app test.

## Evidence and validation

[translation-hardware-round3-20261003-results.json](translation-hardware-round3-20261003-results.json) embeds every raw report, source/output SHA-256, conversion verification, host timing boundaries and manual quality notes. The original logs/research helpers remain under `.build/latency-20261003-round3`; the release/conversion artifacts remain under `.build/latency-20261002-round2/external-license-review` and its adjacent `.base` file.

The standalone probes completed without a persistent server. The scheduling candidate passed 48 CPU-only EOS/budget scenarios at limits 1, 2, 3, 255, 256 and 257, preserving singleton decode calls; actual Metal output parity was checked separately. Existing terminology/prompt-cache/translation-contract checks passed. Swift compilation and native missing-language behavior passed. The shipping source hashes still equal the start-of-round snapshot. No formal app replacement, native audio-to-screen test, production release or package cleanup is claimed.
