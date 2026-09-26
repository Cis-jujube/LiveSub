# LiveSub personal macOS build: delivery evidence

This report separates model tests, authenticated backend IPC, native `.app` checks, and items still awaiting verification. It records observations on **2026-09-26**, not a general performance guarantee.

**Acceptance status: partial.** The final native package has produced microphone ambient-audio pairs in both directions and completed over 30 minutes of process/resource monitoring with observed exit cleanup. System audio, complete overlay interaction acceptance, offline operation, and continuous native subtitle correctness over 30 minutes are not yet passed. The existence of a signed build does not complete the plan's native acceptance requirements.

## Build and runtime

| Item | Observed value |
| --- | --- |
| Test Mac | Apple M5 Pro, arm64, 48 GiB RAM, macOS 27.0 (26A428) |
| Toolchain | Swift 6.4 / macOS SDK 27.0 via Command Line Tools; Python 3.12.13 via uv |
| App | `dist/LiveSub.app`, stable bundle ID `local.jujube.livesub`, ad hoc signed personal build |
| Native source revision | `c0de296` — final native fixes included in the rebuilt release package |
| ASR | Confucius4-R2T2 pinned source + llama.cpp/Metal native extension, local Q4_K_M GGUF and Q8 projector |
| Translation | Pinned Qwen3-4B-Instruct-2507 4-bit MLX local weights |
| Process model | One `.app`-owned Python child, ephemeral `127.0.0.1` port, launch-specific Bearer token; parent-death watchdog |
| Model locations | `~/Library/Application Support/LiveSub/models/`; App Python env in `~/Library/Application Support/LiveSub/backend/.venv` |

The one-time `./script/setup_models.sh` completed on this Mac: native R2T2 rebuilt, ASR assets and Qwen weight hashes verified, release `.app` built and ad hoc signed, separate application Python environment prepared, packaged backend imports succeeded. App launch is designed to own the backend without user-managed terminals. Model weights are not in Git or the `.app`.

## Automated and real-audio results

| Scope | Actual result | Evidence boundary |
| --- | --- | --- |
| Backend logic | 44 `pytest` checks passed; one upstream Starlette deprecation warning | Fake ASR/translator are used only for deterministic contract cases. |
| Native audio and Store checks | Audio 5; Store 16 assertions plus 1,800 synthetic paired rows | SwiftPM executable checks; full Xcode XCTest tooling unavailable. Synthetic rows do not measure 30 minutes of capture or UI performance. |
| Overlay state and placement checks | 4 geometry checks plus caption reset passed; a new-session reset removes old caption state without opening or unlocking the panel | State assertions do not establish rendered appearance, click-through, or absence of a visible stale-caption flash. |
| Backend wire and process lifecycle checks | 15 protocol assertions; stale stdout, termination, and failure cleanup from a previous launch rejected after relaunch; real authenticated loopback handshake and unauthorized rejection passed | Lifecycle checks use two real local subprocesses without model loading. They do not exhaustively inject all socket interleavings or App UI failure paths. |
| Final release package | Release build, Info.plist and packaged-backend checks, and `codesign --verify --deep --strict --verbose=2 dist/LiveSub.app` passed after the final native fixes | The final package subsequently underwent partial native runtime checks and process monitoring. End-of-run signature checks passed and its binary hash was unchanged; remaining interactive gaps are listed below. |
| Gatekeeper assessment | `spctl -a -vv dist/LiveSub.app` returned exit code **3** and **`rejected`** | The personal package is ad hoc signed and not notarized. Strict codesign success does not establish Gatekeeper acceptance or readiness for direct distribution. |
| R2T2 direct audio | Paced public Chinese WAV RTF 0.663, public English JFK WAV RTF 0.677; post-native-logging-patch Chinese repeat RTF 0.667; actual arm64 Metal extension loaded | Values from the retained [compatibility report](compatibility.md). Prerecorded source through model adapter, not microphone. |
| R2T2 + Qwen same process | EN ASR RTF 0.691, ZH 0.678; all final segments translated; observed max translation queue depth 1; peak RSS about 5.25 GB | Paced public WAV; ASR plus translator, before macOS capture/UI. See [benchmark](benchmark.md). |
| Authenticated WebSocket with real models | EN 11 s / 69 frames / 4 final translated segments; ZH 6.74 s / 43 frames / 2 final translated segments. No duplicate final, wrong revision pair, overflow, or reported error; wrong token rejected HTTP 403. | Real backend subprocess and IPC, not native capture/UI. [EN report](ipc-en.json), [ZH report](ipc-zh.json), [method](ipc-smoke.md). |
| IPC final translation after approximate segment end | EN 453–916 ms; ZH 864–915 ms. Stop→idle EN 286 ms, ZH 141 ms. | Backend receipt time from segment end, **not** last spoken word to visible UI latency. |
| Formal backend-only soak | **Passed:** 1,804 s of paced public English WAV audio, 164 repetitions in one authenticated WebSocket session, 30 complete minute samples; 656 final translations and 6,238 subtitle events; zero error events, duplicate finals, revision regressions, or final source/translation pair mismatches; expected final spoken tail present | Real R2T2 and Qwen backend only. Repeated prerecorded speech does not test native capture, Swift UI, overlay interaction, or varied-conversation translation quality. [Raw report](soak-backend.json), [method](soak-backend.md). |
| Backend soak resource and timing observations | Sampled backend RSS peak 4,979.45 MiB, start-to-after-idle change +64.76 MiB; approximate segment-end→final-event median 958.55 ms, P95 1,217.92 ms; stop→idle 412.98 ms | RSS is sampled process memory, not a proof of absence of leaks. Timings end at backend event receipt, not visible UI rendering. Queue depth is not exposed. |

`./script/test.sh` completed the available automated checks and build; `./script/build_and_run.sh --verify` and a separate strict codesign verification passed for the final staged application containing native revision `c0de296`. See [the manual matrix](manual-test-matrix.md) for the test scope and native App observations.

`open dist/LiveSub.app` previously launched the App on this development Mac. That observed local launch and the rejected Gatekeeper assessment are separate results; launch on another Mac or after distribution has not been verified.

## Native App findings

The initial microphone observations below precede final repackaging. Subsequent final-package observations are separately recorded here and in [the manual matrix](manual-test-matrix.md).

- Main window opened with the expected paired two-column layout and idle state; opening the App did not start recording.
- First microphone run exposed an AVAudioEngine format notification false positive; the next run exposed a Swift actor isolation trap on CoreAudio's realtime callback. Both were diagnosed from the actual `.app` and fixed before continuing. The first crash left an orphan backend. A parent-PID watchdog was added and its process-exit regression test passed.
- After those fixes, the `.app` entered microphone listening in English→Chinese mode and reached 20 real paired segments in the main window. Toggling the overlay while recording kept the same App/backend PIDs and the record count continued from 13 to 19. Stopping retained the visible history. This was room audio; the transcript itself was not saved for privacy. No calibrated visible-latency measurement was made.
- Normal App Quit was observed to terminate the owned backend. The earlier crash cleanup is separately covered by the parent-watchdog regression test; forced-crash cleanup is not exhaustively tested.
- System audio initially reported missing Screen Recording permission. A later attempt returned ScreenCaptureKit `-3801` despite an apparently enabled LiveSub permission toggle. Effective permission and successful capture remain unresolved; no real system-audio recognition or translation is claimed.

## Final-package native observations

- Both microphone directions produced paired ambient-audio segments. Public English and Chinese WAVs were briefly played through the speakers, but the recognized text did not match the known samples; this is not an accuracy pass for native acoustic capture. The Chinese-direction short session retained 16 segments when paused.
- Closing the main window left App/backend processes running. File → New LiveSub Window restored the window with those 16 segments. This verifies the native File menu path, not the MenuBarExtra status item.
- Overlay toggling and two accessibility subtitle labels were observed; labels later disappeared without new subtitles. Browser typing/button activation and TextEdit typing/scrolling worked while the overlay toggle was enabled, but the test could not reliably establish that the interaction points were under the panel. Actual covered-area click-through, pixel-level appearance, line clipping, and exact fade timing remain unverified.
- System audio again returned `SCStreamErrorDomain -3801` during display discovery and produced zero segments.

### Native process/resource observation

The final package was monitored in a microphone ambient-audio ZH→EN session from 21:21:51.197 to 21:54:24.481 local time on 2026-09-26: **1,953.28 seconds (32 min 33.28 s)**. Of 196 samples, 195 showed both original App and backend PIDs alive; the final jointly alive sample was at 1,943.23 seconds. No PID replacement or reuse was observed. There was no public-WAV loop or periodic subtitle-count audit.

| Sampled RSS | App | Backend |
| --- | ---: | ---: |
| First → last alive sample | 148.42 → 175.52 MiB | 4,973.81 → 4,980.05 MiB |
| Peak | 175.66 MiB | 4,980.17 MiB |
| Change | +27.10 MiB | +6.24 MiB |

The user reported manual Cmd+Q. At 1,953.25 seconds the monitor recorded both original processes absent; an independent process check found neither the original PIDs nor remaining LiveSub App/backend processes. Monitoring ended normally, the binary hash was unchanged, and end-of-run strict signature verification passed. This supports observed process survival and exit cleanup; it does **not** establish uninterrupted audio capture, continuous subtitle updates, translation accuracy, visible latency, or final-tail handling. The RSS curve is not proof of absence of leaks. [Raw metrics](native-soak-metrics.jsonl), [summary](native-soak-summary.json), [method and observations](native-soak-plan.md).

## Remaining acceptance checks

The following are **not yet marked passed** in this report: native system-audio translation; native acoustic-capture accuracy against the public WAVs; user-visible latency from final spoken word to rendered subtitle; actual covered-area click-through; pixel-level overlay appearance and fade timing; MenuBarExtra, position adjustment/reset, Space/fullscreen/multiple-display combinations; a formal offline test; continuous native capture/subtitle correctness and tail completion over 30 minutes; and remaining retry/stop or stale-caption failure-path UI checks. Final-package process survival, resource observations, window restoration, and user-triggered exit cleanup have their own bounded evidence above. Final package signature verification and the automated process lifecycle checks have passed. Their scope and exact observations are recorded in [the manual matrix](manual-test-matrix.md). The formal 1,804-second [backend-only soak](soak-backend.md) has passed, but its IPC and resource results do not complete these native acceptance checks.

The model can revise previews, 6-second splitting can insert a word, and translations can over-complete or mistranslate negation. See [known issues](known-issues.md). No source or target text from private live audio is included in this report.
