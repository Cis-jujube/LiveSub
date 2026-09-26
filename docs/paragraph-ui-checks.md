# Native paragraph UI verification

Date: 2026-09-26

`paragraph-layout-fixture.png` is an offscreen render of the actual production `TranscriptView`, hosted in an `NSHostingView` at 1080 × 720 points (2160 × 1440 pixels). The input is synthetic English/Chinese text about AI Agent and token, with four completed sentences in a historical paragraph and a growing second paragraph with a pending translation. This is UI layout evidence, not ASR or model translation-quality evidence.

The one-shot harness instantiated `AppController`, applied synthetic records to its existing public `SubtitleStore`, and captured a bitmap from an offscreen window. It did not call start, launch a backend, enable a microphone, or add fixture code to the production application. The actual source and target columns share one scroll container and preserve paragraph alignment. Inspection confirmed readable paragraph spacing, no sentence-by-sentence timestamps or dividers, the pending translation indicator, and direct Settings access.

## Automated checks

- `swift run SubtitleStoreChecks`: passed 1,877 executed assertions (counted with an instrumented temporary copy at `/tmp/LiveSubCountedChecks.swift`), covering the original revision/pairing checks and 1,800 long-session records, plus checks for four-sentence grouping, stable paragraph IDs, in-place source revision and content-revision notification, stale target exclusion, failure after preview, recovery, paragraph TXT/Markdown exports, direction/generation boundaries, unpunctuated-stream bounds, session reset, and terminology validation/persistence.
- Terminology checks cover AI defaults, JSON round trip and snake-case keys, duplicate/blank/overlong/control-containing terms, raw-length parity with the backend, entry/file size limits, atomic save, and refusing to overwrite an externally changed configuration.
- `swift build --product LiveSub`: passed. The installed Command Line Tools emit existing linker search-path warnings; no compile errors remain.
- `git diff --check`: passed.

## Scope and reproduction

The temporary harness source is `/tmp/LiveSubParagraphRender.swift`; executable `/tmp/livesub-paragraph-render`; original PNG `/tmp/livesub-paragraph-fixture.png`. These are local scratch artifacts, not required app files. It links the debug SwiftPM module objects and compiles the production `AppController.swift` and `TranscriptView.swift`, excluding the production `@main`. Re-running `/tmp/livesub-paragraph-render` reproduces the captured synthetic state while these temporary files exist. Recompile the harness after changing the actual view or store.

The screenshot does not prove live audio capture, translation latency or accuracy, wheel/trackpad behavior, dragging the column split, text selection, native save-panel interaction, or Settings save/reset interaction. Those remain runtime/manual checks. Auto-follow has code-level coverage via every accepted event incrementing `contentRevision`, including translation-only changes; scrolling interaction pauses follow and the “回到实时” control restores it. The floating overlay still reads one original subtitle record and does not create another session.

## Final release and Settings interaction check

Later on 2026-09-26, `./script/build_and_run.sh --verify` passed release compilation, bundle and Info.plist checks, and strict ad hoc codesign verification. The app at `dist/LiveSub.app` launched successfully. Its `Contents/MacOS/LiveSub` SHA256 is `4b30b70dbc2e14e296949937a29dde5b83b2e2461e2783b31b781b04021d73a0`.

Actual CUA interaction, without starting recording, verified:

- Open Settings from the idle main window; the AI preset was selected.
- Add an empty entry and save; the length validation error appeared.
- Save the English-to-Chinese entry `AI agent → AI Agent`, then reload; the entry persisted. A separate backend parser successfully read the same saved file.
- Delete the test entry and save; reopening Settings showed the AI preset with zero custom entries.
- Quit with Cmd+Q; subsequent process inspection found no remaining app, `livesub.server`, or related test processes.

This supersedes the earlier “Settings save” unverified status for the specific interactions above. The Restore Defaults alert/action was not exercised. Later CUA screenshot calls returned blank images, so this check provides interaction/accessibility-state evidence and adds no pixel-quality claim beyond the previously inspected synthetic paragraph PNG. Live audio capture, populated-window scrolling and column dragging remain outside this check. No system-audio fix or complete original acceptance is claimed.
