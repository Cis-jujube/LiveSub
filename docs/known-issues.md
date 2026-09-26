# Known issues and scope

This is a personal local build for the Mac on which setup was run. It is ad hoc signed; it has not been notarized, packaged for other Macs, or submitted to the App Store. Moving it to another Mac requires rebuilding the native R2T2 extension and preparing both model sets there.

The final release package containing native revision `c0de296` passed its build and strict codesign verification. Automated checks passed for 44 Python cases, Audio 5, Store 16 assertions plus 1,800 paired rows, Overlay 4 geometry checks plus caption reset, and Backend 15 protocol assertions plus launch-lifecycle isolation and authenticated transport. These results are detailed in [the delivery report](delivery-report.md); the remaining gaps below concern native runtime acceptance and model quality.

## Recognition and translation quality

- The pinned R2T2 streaming implementation can revise an earlier `fixed_text` hypothesis. LiveSub treats these as revisable previews and only finalizes a source segment after an explicit boundary; a preview can still visibly change.
- R2T2's forced 6-second split produced an extra “The” at one boundary in the public JFK sample. Segment times are approximate, not word-aligned timestamps.
- In the real WAV joint benchmark, Qwen completed an unfinished English fragment with words that were not spoken, and a Chinese sentence had incorrect negation scope. Stronger literal/negation prompting did not fix either in the recorded recheck. These failures are documented in [the joint benchmark](benchmark.md), separately from the [40-item curated text review](translation-review.json), in which no reversed negation was observed.
- Quality and latency vary with noise, accents, overlapping speakers, device load, and source material. Automatically detecting direction and mixing microphone/system audio are outside this first version.

## macOS and build constraints

- On this Mac, `codesign --verify --deep --strict dist/LiveSub.app` passed, but `spctl -a -vv dist/LiveSub.app` returned exit code **3** with **`rejected`**. This personal ad hoc package has not been notarized and is not established as accepted by Gatekeeper or ready for direct distribution. `open dist/LiveSub.app` previously succeeded on this development Mac; that observation does not guarantee launch after copying or downloading the package elsewhere.
- This Mac has Command Line Tools but not full Xcode. The project uses SwiftPM and executable assertion checks; `swift test` based on XCTest and Swift Testing is unavailable with this toolchain. `./script/test.sh` runs the available checks.
- System audio uses ScreenCaptureKit. Protected or system restricted content may not be available; the app does not attempt to bypass these restrictions.
- The current native system-audio attempt returned ScreenCaptureKit `-3801` even though a LiveSub permission toggle appeared enabled in System Settings. The effective permission/capture state remains unresolved; no real system-audio subtitle result is claimed. This observation alone does not establish a protected-content failure.
- macOS 15 is the deployment target; the actual test machine runs macOS 27.0. Compatibility with other macOS releases is unverified.
- The floating panel uses ordinary floating window level and `canJoinAllSpaces` / `fullScreenAuxiliary`. It is not intended to cover lock screens, secure input, system prompts, or every native fullscreen app. Actual tested combinations are recorded separately in [the manual matrix](manual-test-matrix.md).
- The first model setup is a terminal script. It reports model origins, approximate sizes, verification, and disk errors, and can be rerun. The App itself reports missing preparation but does not download or compile model assets from its Settings window.

## Outstanding acceptance evidence

- A live microphone English→Chinese session reached 20 paired segments, but native Chinese→English capture and system-audio capture still require their own evidence.
- Overlay toggling preserved the App/backend processes and continued subtitle accumulation. This does not establish cross-application click-through, focus behavior, readable rendering on all backgrounds, or Space/fullscreen/multiple-display compatibility.
- The formal [backend-only soak](soak-backend.md) passed: 1,804 seconds, 164 repetitions of one public English WAV, 30 complete minute samples, 656 final translations and 6,238 subtitle events, with no reported error, duplicate final, revision regression, or final source/translation mismatch; the expected tail was present. The [raw report](soak-backend.json) records sampled RSS peak 4,979.45 MiB and start-to-after-idle growth of 64.76 MiB. These observations cover this single repeated-speech workload; queue depth is not exposed and absence of leaks is not established.
- The full-App 30-minute run, simultaneous browser/editor use, native App resource curve, final-spoken-word-to-visible-subtitle latency, and formal offline run remain pending. The successful backend soak excluded macOS capture and the Swift UI/overlay. Its approximate segment-end→final-event median 958.55 ms/P95 1,217.92 ms and stop→idle 412.98 ms are backend measurements. The separate 1,800-row Store check uses synthetic events. Neither test is a 30-minute native App session.
- Normal Quit was observed to clean up the owned backend before final repackaging. The final automated lifecycle checks also reject stale stdout, termination, and failure cleanup from a previous launch without disrupting its replacement. The earlier CoreAudio callback crash and orphan process prompted fixes and a watchdog test; not every forced-crash or socket race has been exercised.
- The final package has not been interactively retested after the last native fixes. In particular, actual retry/stop behavior after backend failure and absence of an old-caption flash on a new session remain pending; caption-state assertions and process lifecycle checks do not replace these GUI observations.
