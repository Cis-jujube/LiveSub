# Isolated BaseRT benchmark proposal, 2026-10-03

Status at preparation: prepared for approval. The official archive was downloaded for a read-only license and provenance review. No engine binary or converter had been executed during that preparation. The standalone wrapper was reviewed against the pinned public C API and checked with `py_compile` only.

Execution update, 2026-10-03: the user's subsequent instruction to execute the possible optimization authorized this concrete isolated trial. Extraction, passthrough conversion, validation of the eight F32 norms, and bounded prefix/no-prefix native trials have now completed. This historical proposal retains the original payload below; measured results and the rejection of shipping adoption are recorded in [round 3](translation-hardware-round3-2026-10-03.md). No runtime redistribution or app integration was authorized or performed.

Proposed scope: extract the reviewed BaseRT 0.2.6 bundle into an ignored research directory, convert the existing local Qwen3-4B-Instruct-2507 4-bit checkpoint, and run a bounded comparison over the existing 96 public/synthetic translation fixtures. Use the existing Python environment and tokenizer, with no package declaration or lockfile changes, no new model download, no server, no app replacement, and no shipping integration. This introduces a new native runtime dependency for the experiment; the user's AGENTS.md requires approval before adding dependencies. Approval for this experiment would not authorize a production dependency or redistribution.

## Reviewed artifact and license

| Field | Verified value |
| --- | --- |
| Official repository | `basecompute/baseRT` |
| Release-tag commit | `3b31090e264073528658441edf81ffafe0a86ddf` |
| Reviewed public 0.2.6 sync commit | `128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6`, two commits after the release tag |
| Release | `v0.2.6`, published 2026-09-18 01:51:08 UTC |
| Release author / asset uploader | `prabod` / `prabod` |
| Asset | `basert-engine-macos-arm64-0.2.6.tar.gz` |
| Compressed bytes | 18,727,923, about 17.86 MiB |
| Published and independently computed SHA-256 | `9bcb204b7cca56470edc41323650f97f5b5fb45499825565a476be508237c84a` |
| Regular-file bytes in archive | 52,110,730, about 49.70 MiB |
| Local archive | `.build/latency-20261002-round2/external-license-review/basert-engine-macos-arm64-0.2.6.tar.gz` |
| License review copy | `.build/latency-20261002-round2/external-license-review/BaseRT-Engine-LICENSE-v0.2.6.txt` |
| License copy SHA-256 | `2d26abb223b35b02c89c52ae599e7da6a3cfc0cc50384919d6cf05b95417db05` |
| Provenance record | `.build/latency-20261002-round2/external-license-review/artifact-provenance.json` |

The release metadata, asset size, and digest were checked against [the official 0.2.6 release](https://github.com/basecompute/baseRT/releases/tag/v0.2.6). Every archive path was checked for absolute paths and parent traversal; the two library symlinks target files inside the bundle. Only `LICENSE` and `NOTICE` text copies have been written outside the archive.

The release tag points to the preceding public 0.2.5 sync, rather than the public 0.2.6 sync. A read-only [tag-to-reviewed-commit comparison](https://github.com/basecompute/baseRT/compare/3b31090e264073528658441edf81ffafe0a86ddf...128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6) found only nine changed files: package-version mirrors, Cargo lockfile package versions, binding version strings, and the C header's patch-version macro. No converter, quantization, architecture-mapping or struct-layout implementation changed. The later sync says it was generated from internal tree `ae68bbbf`; that message does not establish reproducible binary provenance.

Direct content hashing found identical converter `main.rs`, MLX packed reader, Qwen/Llama mappers and `types.h` at both commits. In particular, F32 norm preservation and all proposed converter flags already exist at the release-tag commit. The reviewed archive's public `baseRT.h` is byte-identical to the later public sync, differing from the tag only by `BASERT_VERSION_PATCH 5 → 6`; its `types.h` matches both commits. The wrapper's three ctypes structs also match the release-tag definitions. This supports the proposed API/format preparation but does not prove the proprietary binary was built reproducibly from a particular public commit.

| Relevant text | SHA-256 verified during tag / archive audit |
| --- | --- |
| Converter `main.rs`, identical at tag and sync | `cc7f279d8212b6cbea3b52507376bb9e68b1c0f92b6599ab4eb1eab37646c690` |
| MLX reader, identical at tag and sync | `dc8c23c42f480da9c95fbb25d965eb803d7d323fbe103a9df7aec5c06c6821bc` |
| `types.h`, identical at tag, sync and archive | `4d35d243407a0c76f84a2bbe35f72388edba24f584b5bb23b5918eb0e2e75d4c` |
| Archive `baseRT.h`, matches public 0.2.6 sync | `8a2773c96d186ff5ddc9cbe6f00f3cc1b20b48c73bca4cf5206d3532b3836314` |

The engine's actual license grants a revocable, non-transferable, non-sublicensable license to run unmodified copies on owned or controlled Apple Silicon hardware for internal use and evaluation. It prohibits redistribution, sublicensing, making the engine available to third parties, hosting it as a service, reverse engineering/decompilation/disassembly, modification or derivative works, and removal of notices. Local evaluation is within the stated grant. Bundling the engine in an app distributed to other people would require separate terms. The public CLI/converter, format, C API headers, and bindings use Apache-2.0; that license does not cover the native engine. [Official explanation of the license split](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/docs/reference/engine-releases.md).

## Toolchain and resource requirements

The archive contains the `basert` Rust CLI, runtime tools, the versioned dylib with embedded Metal kernels, standalone Metal libraries, and matching public headers. This prebuilt route needs no Rust, CMake, Metal compiler, or Python package installation. The project documents Apple Silicon M1+ / macOS 14+ for runtime use. The exact SDK used to build this release is not published in the inspected public sources. [Installation source](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/docs/getting-started/installation.md), [bundle installer source](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/install.sh).

The local machine exposes macOS SDK 27.0, but `xcrun --find metal` fails, and `cargo` / `cmake` are absent. Building the open converter from source requires Rust 1.85+ and its locked Cargo dependencies. Native engine source is not in the public repository. A custom Metal 4 kernel requires a compatible Metal compiler; the paper names `-std=metal4.0`. Installing such a toolchain would be a separate approval scope. [Converter manifest](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/base-convert/Cargo.toml), [M5 paper](https://arxiv.org/html/2607.19438v1).

The existing safetensors occupy 2,263,022,417 bytes, about 2.11 GiB. A `.base` copy with the same packed tensors should require about 2.3 GB, plus layout/header padding; this is an estimate until conversion. The proposed `--direct-write` flag avoids a second full temporary weights blob and adds a 64 MiB header reserve. Budget roughly 2.4 GB of new free disk space for the converted model and reviewed/extracted runtime, plus small reports. No existing weights or packages would be removed.

Logical FP16 KV storage for 36 layers, 8 KV heads, head dimension 128, and a 2,304-token allocation is 339,738,624 bytes (324 MiB). The packed weights add about 2.11 GiB. Actual native working-set/RSS includes scratch buffers and runtime allocations and must be measured; these arithmetic estimates are not a measured peak. Existing ASR and MLX memory remain separate. Run GPU experiments sequentially, with the exclusive GPU slot granted by the root task.

## Exact weight-conversion proposal

BaseRT loads `.base` bundles, not the MLX directory directly. The release-tag converter source has a passthrough path for affine INT4 / group-64 MLX checkpoints. Packed low-nibble-first codes are copied; scale/bias regions are rearranged and stored as F16. The `--validate` option compares packed codes and the emitted scale/bias bytes to their expected converted source representation. Avoid profiles, AWQ, lower bit widths, and the lossy `--allow-quant-from-quant` option in the first experiment. [Release-tag conversion arguments and validation](https://github.com/basecompute/baseRT/blob/3b31090e264073528658441edf81ffafe0a86ddf/base-convert/crates/base-convert/src/main.rs#L198-L217), [release-tag MLX packed reader](https://github.com/basecompute/baseRT/blob/3b31090e264073528658441edf81ffafe0a86ddf/base-convert/crates/base-readers/src/mlx.rs#L328-L460).

CPU-only inspection of all source scale/bias values found 253 packed tensors, 253 BF16 scales and 253 BF16 biases. Each of the 62,848,000 scale values and each of the 62,848,000 bias values round-trips through F16 exactly, with no overflow, zero flush, or numerical difference. Storage bytes change because BF16 and F16 differ, but this checkpoint's quantized weight grid can survive the documented transplant exactly.

There are also 145 unquantized BF16 norm tensors. Eight values would change if narrowed to F16; the largest absolute change is `2.9802322387695312e-08`, and one nonzero would flush to zero. The release-tag converter mirror policy instead carries a non-lossless unquantized norm as F32. Its `--validate` branch skips F32 tensors, so a separate check of these carried norms is required after conversion. Full runtime numerical identity cannot be established from source inspection: native operators and internal casts remain in the proprietary engine. [Release-tag norm preservation branch](https://github.com/basecompute/baseRT/blob/3b31090e264073528658441edf81ffafe0a86ddf/base-convert/crates/base-convert/src/main.rs#L3662-L3714), [release-tag validation dtype handling](https://github.com/basecompute/baseRT/blob/3b31090e264073528658441edf81ffafe0a86ddf/base-convert/crates/base-convert/src/main.rs#L2036-L2147).

## Prepared commands; do not run before approval

The first command creates a new empty extraction directory, verifies the archive again, and uses Python's `data` extraction filter. It does not run the project's installer or edit shell profiles. All subsequent binaries are addressed by absolute paths. Preserve the downloaded license and attribution files.

```sh
backend/.venv/bin/python - <<'PY'
from pathlib import Path
import hashlib, tarfile
review = Path('.build/latency-20261002-round2/external-license-review').resolve()
archive = review / 'basert-engine-macos-arm64-0.2.6.tar.gz'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == '9bcb204b7cca56470edc41323650f97f5b5fb45499825565a476be508237c84a'
destination = review / 'engine-v0.2.6'
destination.mkdir(exist_ok=False)
with tarfile.open(archive, 'r:gz') as bundle:
    bundle.extractall(destination, filter='data')
print(destination)
PY

basert_trial_root=".build/latency-20261002-round2"
basert_trial_engine="$basert_trial_root/external-license-review/engine-v0.2.6"
basert_trial_source="~/Library/Application Support/LiveSub/models/Qwen3-4B-Instruct-2507-4bit"

"$basert_trial_engine/basert" --version
"$basert_trial_engine/basert" convert --help

"$basert_trial_engine/basert" convert "$basert_trial_source" \
  --target base-q4 --mlx-passthrough --validate --direct-write \
  --output "$basert_trial_root/qwen3-4b-mlx-passthrough.base"

"$basert_trial_engine/basert" inspect \
  "$basert_trial_root/qwen3-4b-mlx-passthrough.base"
```

Before conversion, check the actual prebuilt CLI's version and help; stop if it is not 0.2.6 or lacks any proposed flag. Before native inference, review conversion counts, all tensor names/shapes, Qwen head dimension 128 and tied-embedding configuration, EOS metadata, and the carried F32 norms. The converter flags above were checked against the release-tag Rust source, which is byte-identical to the reviewed public sync implementation; executing the reviewed binary's help and conversion still requires the experiment approval. Do not use a hub model ID, `pull`, or automatic model resolution.

The prepared wrapper is `.build/latency-20261002-round2/benchmark_basert_isolated.py`. The completed current MLX comparison report is `docs/translation-round2-20261003-results.json`, covering the same 96 fixtures in three rounds. Its canonical fixture hash is checked by the wrapper; an incomplete or different fixture report is rejected.

```sh
backend/.venv/bin/python \
  "$basert_trial_root/benchmark_basert_isolated.py" --execute-approved \
  --archive "$basert_trial_root/external-license-review/basert-engine-macos-arm64-0.2.6.tar.gz" \
  --library "$basert_trial_engine/libbaseRT.0.2.6.dylib" \
  --model "$basert_trial_root/qwen3-4b-mlx-passthrough.base" \
  --tokenizer-dir "$basert_trial_source" \
  --baseline-report docs/translation-round2-20261003-results.json \
  --baseline-run after --cases docs/translation-round2-cases.json \
  --rounds 3 --cache prefix --output "$basert_trial_root/basert-96-fixtures.json"
```

The execution flag is an accidental-run guard and supplies no authorization by itself. Initial execution should use one complete round; three rounds are the planned confirmation after ABI, conversion and quality checks pass. No runtime command has been run during preparation.

## Comparison behavior and acceptance evidence

The ctypes wrapper uses the reviewed C ABI with per-load options, validates the dylib against the archive, requires native version 0.2.6, loads one model, and owns it on one thread. It calls the translator's `_translate_loaded` helper directly on the main thread; it never calls `prepare`, `translate` or `_submit`, and starts no MLX worker. Native loading, generation, cache resets and freeing therefore all remain on main. Explicit thread-ID assertions guard every native model method and callback. It keeps FP16 KV (`kv_bits=16`), one decode lane, no paged KV or RadixCache, and no automatic OOM paging. BaseRT defaults would otherwise quantize compatible KV to Q8; changing KV precision in the first comparison would add a quality confound. The existing MLX activation/cache dtype and native FP16 math may still differ. [C API load and KV options](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/include/baseRT/baseRT.h#L81-L149), [struct definitions](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/include/baseRT/types.h).

Prompts, context limits, protected terminology restoration and exact-result handling use the current LiveSub translator code. Only its model loader/generator are replaced inside the ignored benchmark process. The tokenizer is read from the existing model directory with `local_files_only=True` and `trust_remote_code=False`; native chat formatting is bypassed to preserve existing prompt token IDs. The prefix option uses `baseRT_try_rollback` / `baseRT_generate_continue` and keeps only the previous prompt prefix, discarding generated tails. It compares the achieved rollback position, resetting and prefilling if it differs. A separate `--cache none` pass can diagnose native prefix-reuse effects. [C API rollback and continuation](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/include/baseRT/baseRT.h#L1038-L1121).

The 96 fixtures contain 58 English ordinary sentences, 24 English revisions, 12 isolated terms, and 2 Chinese sentences. Report these categories separately. Retain complete output text, token IDs/count, native timing, total backend translation duration, errors, lexical checks and exact-output differences against MLX. Use the existing 256-token output budget and greedy temperature zero. The callback stops only on the existing tokenizer/generation-config EOS IDs, preserving the current MLX stopping set if a native bundle's own metadata omits an extra stop ID; it never cancels at a latency threshold or shorter token count. The callback's false-return stopping contract was checked in the public API. Budget exhaustion is flagged and excluded from successful sub-300-ms counts; native token-count bounds and finite nonnegative native durations are checked. EOS may be handled inside native generation without appearing in its callback; report this observation explicitly rather than fabricate an EOS event. [Callback stopping contract](https://github.com/basecompute/baseRT/blob/128bdd7348c6d0d271f47b5aca5b2fb16a5e1df6/include/baseRT/baseRT.h#L400-L409).

Lexical predicates are not an accuracy measure. The completed MLX baseline translates the fixture's `3.5 minutes` as `3分30秒`, which expresses the same duration, but the fixture accepts only literal `3.5` / `三个半` / `三点五` alternatives. Keep that false lexical failure visible with an explicit scoring note; do not label the translation inaccurate or report the aggregate lexical count as a general accuracy percentage. Other differing outputs still require human semantic review.

The acceptance target is complete ordinary-sentence translation below 300 ms, with p50/p90/p95 and every tail case reported. Isolated-term dictionary hits, first-token timing, lower output caps, shorter mistranslations, and output truncation do not count as reaching the target. Inspect differing translations for negation, numbers, names, clause scope, terminology markers, and unfinished speech. A standalone native backend benchmark still does not verify system-audio capture, ASR/MT contention, UI delivery or rendering latency.

The M5 paper motivates a trial without establishing an expected win here: it uses BaseRT 0.1.6, MLX 0.32.0 / MLX-LM 0.31.3, 128-token decode throughput and five repetitions on M5 Pro / 48 GB. Its 15 configurations omit Qwen3-4B-Instruct-2507. Decode gains over MLX range from losses on two large models to a 1.33× best case on Qwen3-0.6B. Its tensor-accelerator gains primarily concern prefill; dispatch/fusion explains remaining decode gains. There is no basis to promise this exact workload under 300 ms before measurement. [Primary paper and evaluation](https://arxiv.org/html/2607.19438v1).

Preparation validation: release-tag versus public-sync source comparison, official archive metadata and SHA-256 verification, archive path review, exact LICENSE/NOTICE review, in-memory public-header comparison from the already reviewed archive, CPU weight-layout/range audit, C ABI signature/struct source comparison, Python syntax check, and documentation review. Remaining unverified: reproducible binary build provenance, actual archive extraction, prebuilt CLI version/help execution, converter execution/output validation, native ABI loading, quality parity, latency and memory measurements, and native app/system-audio behavior.
