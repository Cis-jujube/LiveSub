# Native English translation and private IPC, round 4 — 2026-10-03

The **warm English translation target is met in the measured fixtures**, including the paced ASR + translation path and the actual preview bundle's backend/helper. Complete current translation waits in the packaged run were median **36.06 ms**, P95 **61.28 ms**, maximum **64.77 ms**, with **47/47 below 300 ms**. This is recognition-text-ready → matching full translation, not audio playback → screen latency. The running formal `dist/LiveSub.app` has not been replaced and the new GUI has not been launched or accepted.

## Authorization and implementation

The user explicitly confirmed installation and evaluation of the English and Simplified Chinese system translation packs. System Settings showed **Remove** for English (US), ID `en_US`, and Chinese (Mandarin, Simplified), ID `zh_CN`, after the downloads completed. The framework then reported both `en → zh-Hans` and the reverse as `installed`. Other language downloads and the global On-Device Mode switch were not changed.

The new source/preview uses Apple's [`lowLatency`](https://developer.apple.com/documentation/translation/translationsession/strategy/lowlatency) strategy with the [installed-language initializer](https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:preferredstrategy:)). Apple describes traditional translation models for latency-sensitive audio uses, with lower fluency than `highFidelity`. The helper checks `canRequestDownloads == false`. This uses Apple's system models; Qwen weights stay available for Chinese and fallback requests. Actual CPU/GPU/Neural Engine scheduling has not been established.

- [native_translation_helper.swift](../script/native_translation_helper.swift) implements a private JSON-lines child process. It uses no listening socket, language download or transcript log, checks macOS 26.4 and exits on owner-pipe EOF.
- [apple_engine.py](../backend/livesub/translation/apple_engine.py) owns the helper, applies the existing terminology/sense rules, directly returns a complete isolated term, applies native skip-translation attributes to preferred targets, checks target multiplicities and returns the full matching request identity. It reuses the installed Qwen tokenizer for 2048-token input / 256-token output limits. Recent source context helps choose terms; no reference-context prompt is supplied to Apple's model.
- [local_engine.py](../backend/livesub/translation/local_engine.py) keeps Qwen warm for Chinese, unavailable assets and failed native requests. Failed requests preserve their original source/revision. Native failures are reported by exception type without transcript text. Budgets remain explicit errors.
- [session.py](../backend/livesub/session.py) retains the shared model lock and final-priority/coalescing rules. Qualified native English previews use a 100 ms interval; Qwen remains at 750 ms. Backend process selection uses only the bundled helper on supported systems. The macOS settings text describes the conditional route.

No dependency declaration, lockfile, original model weight, TCC permission, signing identity or formal bundle was changed. The repository's pre-existing staged work was preserved. Older macOS execution and disconnected-network operation have not been tested during this round.

## Complete request timing

The final [full-pipeline benchmark](../script/benchmark_native_pipeline.py) ran all 96 public/synthetic fixtures for three rounds on the existing M5 Pro / 48 GiB machine. It includes terminology lookup, tokenizer budget checks, Python ↔ Swift pipe RPC, the complete native translation and output validation. Startup, fixture setting writes, ASR and GUI rendering are excluded. The fixture canonical SHA-256 remains `acef43d9b517fc6a6cb35a452f3ded80950836d3e629142463269c1762d5bff1`.

| Category | Requests | Median | P95 | Maximum | Below 300 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Ordinary English sentences | 174 | 21.160 ms | 34.597 ms | 48.493 ms | 174/174 |
| Same-segment English revisions | 72 | 29.611 ms | 56.322 ms | 60.939 ms | 72/72 |
| Isolated dictionary terms | 36 | 0.095 ms | 0.256 ms | 1.085 ms | 36/36 |
| Chinese controls, original Qwen route | 6 | 313.125 ms | 403.526 ms | 404.327 ms | 3/6 |

All 288 existing lexical predicates and identity checks passed, with 282 native English requests, 6 Qwen Chinese controls and no native failures. Maximum complete output was 40 Qwen-tokenizer tokens. Dictionary requests are separate and do not inflate sentence latency results. These are a different translation model's outputs, not a numerically identical acceleration of Qwen or a general accuracy score. The round-2 ordinary English median/P95 were 225.034/318.729 ms in an earlier run; this is historical context, not a contemporary causal A/B percentage.

## Paced audio and the packaged result

Each run sent the same 42.86962 s mono 16 kHz PCM16 fixture in real time, with PCM SHA-256 `72f2ecafb97a50980833c3460cf396731ea6fdba1a2ef2504f9908ded7b40753`. All four final-router runs accepted 268 frames, rejected none, drained the tail, returned four current final segments and reported no errors. The packaged run imported the actual copied backend and executed the actual signed bundled helper. Nine relevant bundled source/manifest/lockfile byte comparisons matched the workspace. The app-specific Python runtime's relevant package versions also match the benchmark environment.

| Run | Current translations | Median wait | P95 wait | Maximum wait | Native failures / Qwen English requests |
| --- | ---: | ---: | ---: | ---: | ---: |
| Router confirmation 1 | 49 | 37.70 ms | 62.08 ms | 63.41 ms | 0 / 0 |
| Router confirmation 2 | 49 | 36.48 ms | 61.35 ms | 63.22 ms | 0 / 0 |
| Final source, after pipe fix | 49 | 35.35 ms | 60.73 ms | 62.23 ms | 0 / 0 |
| Actual preview backend/helper | 47 | 36.06 ms | 61.28 ms | 64.77 ms | 0 / 0 |

All **194/194** measured current translations were below 300 ms. Keep each run's distribution; do not select only the lowest median. The final bundle run is the reporting baseline. The separate round-2 final run had median 370.46 ms, P95 587.92 ms, maximum 669.39 ms, with 13/40 current translations below 300 ms.

The packaged run's real ASR compute median was **527.00 ms**, P95 **803.63 ms**. First current translation appeared **1226.97 ms** after fixture input began; stop-to-idle is retained in the raw report. System capture, WebSocket delivery to the GUI and actual rendering are excluded. Speech/audiovisual latency remains a separate acceptance requirement.

## Rejected routes and repaired defects

All earlier evidence is preserved under `.build/latency-20261003-round4` and indexed in the [results](native-translation-round4-20261003-results.json).

1. The initial export incorrectly returned dictionary markers before restoring their targets. It was fixed before adoption; the 12 direct terms now return their actual preferred translations. The initial pilot is explicitly excluded from acceptance.
2. Protecting generic ASCII markers caused semantic errors despite passing lexical predicates: “raised interest rates” became “筹集了利率”, and a basis-point sentence acquired a stray underscore. That route was rejected. Preferred target text plus skip-translation attributes retained the intended financial meaning.
3. A diagnostic attributed-target response exposed ranges that did not identify the preferred Chinese substring correctly. Returned attribute ranges are not used as evidence. The engine checks actual target text multiplicities, matching longer overlapping targets first.
4. The first native-only audio pilot retained the Qwen 750 ms interval and had a **410.16 ms** worst current wait although actual native execution remained below 79 ms. The interval was shortened only for qualified native English.
5. Two repeated full-pipeline runs fell back at the same second-round revision because a nonblocking pipe operation raised **`BlockingIOError(35, 'Resource temporarily unavailable')`**. The initial adapter misclassified this advisory-readiness race as a fatal transport error and disabled native translation. Read/write now retry transient EAGAIN under the original deadline without advancing an unsent byte offset or duplicating a request. The final 288-case rerun had no fallback or rejection. A regression test injects both transient read and write failures and checks that the child received exactly one request ID per operation.

## Quality boundaries

Manual review of the ordinary English/revision outputs retained the key tested negations, 42 files, 90/500/700 token values, 3.5 hours/minutes, 0.03 versus 0.3 seconds, one-at-a-time prediction, unfinished clauses, financial rates and scope of “proves anything”. Four paced final paragraphs retain the tested technical/financial meanings.

Some native phrasing remains less natural or too specific: technical “outage” was rendered as “停电”, “corkage fee” as “瓶塞费”, and one distributed-system sentence included “故障运行了”. Native skip spans also introduce spaces around Chinese terms. These are recorded limitations for user review. Lexical checks do not prove general semantic quality, pronoun/reference-context fidelity or broad domain accuracy. No universal accuracy or every-future-request latency guarantee is made; exceptional Qwen fallback can exceed 300 ms.

## Package and validation

`./script/test.sh` completed successfully: **164 backend tests**, Swift audio/store/overlay checks, real authenticated loopback transport checks and the app build. This includes timeout/EOF/wrong-ID/malformed/oversized pipe replies, child reaping, source/revision/settings cache isolation, term omission/duplication, budgets, transient EAGAIN, Qwen fallback and direction-specific preview scheduling. Existing dependency/linker warnings remain in the log; no check was disabled.

`./script/build_and_run.sh --verify-native-preview` produced `dist/previews/LiveSub-native-preview.app`, ID `local.jujube.livesub.preview.native`. Release compilation, plist, bundled sources, executable checks and strict deep **ad hoc** signature verification passed; the helper signature was also verified separately. This is a personal preview, not a notarized/distributed release. The GUI was not launched. The formal bundle and older Qwen previews remain intact, awaiting formal replacement authorization and user acceptance before package cleanup.

The packaging script now retains an existing replaced package in one `.build/previous-app-bundle/<bundle-id>.app` slot and refuses another replacement while that slot remains. It restores the previous package if installation fails. This avoids deleting an unaccepted version through staging cleanup. Syntax/diff inspection and three disposable-package filesystem scenarios passed: retain the previous package, refuse a second replacement, and restore after an injected install failure. Compile/sign/image/process tools were stubbed in those filesystem scenarios; actual production compilation/signatures were checked separately above. The initial native preview had no prior package to archive, so actual formal replacement/rollback is still unverified.

Reproduce with fresh output paths:

```sh
./script/test.sh
./script/build_and_run.sh --verify-native-preview
backend/.venv/bin/python -B script/benchmark_native_pipeline.py \
  --helper dist/previews/LiveSub-native-preview.app/Contents/Resources/LiveSubNativeTranslation \
  --output .build/native-pipeline-new.json --rounds 3
backend/.venv/bin/python -B script/benchmark_live_iteration.py \
  --audio .build/latency-round2-20260930/en-sustained.wav --language English \
  --backend-root dist/previews/LiveSub-native-preview.app/Contents/Resources/backend \
  --translation-helper dist/previews/LiveSub-native-preview.app/Contents/Resources/LiveSubNativeTranslation \
  --qwen-fallback --output .build/native-live-new.json
```

Do not replace a running preview or formal bundle through these commands. Native system-audio-to-screen acceptance, GUI settings/selection confirmation and longer native sessions remain unverified.
