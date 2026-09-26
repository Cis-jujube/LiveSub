# Translation-only native UI checks

Date: 2026-09-26. These are **synthetic state and layout checks**, not live microphone, system-audio, ASR, translation, or interactive window verification.

## Actual controller state check

A one-shot native executable compiles the production `AppController.swift` and `TranscriptView.swift` against the debug Swift libraries. Eight synthetic subtitle records populate the public `SubtitleStore`; no start/resume/capture/backend operation is invoked. It exercises the actual `selectSubtitleDisplayMode` setter in translation-only → bilingual → translation-only order.

Assertions passed for unchanged session ID, generation, content revision, records, paragraph projection, bilingual TXT/Markdown exports, phase, status, audio source, translation direction, hidden overlay, adjustment state, and transition state. Each selection also round-trips through the persisted preference. The executable saves its original UserDefaults value and restores it with `defer`, removing the key when it was initially absent.

## Production view fixtures

- `translation-only-layout-fixture.png`: actual production `TranscriptView`, 790 × 720 point host, translation-only, populated synthetic paragraphs, a validated paired preview retained with an inline `上一版译文·更新中…` marker after its source advances, and a separate pending translation.
- `translation-bilingual-layout-fixture.png`: the same production view and records at the same size in bilingual mode.
- `translation-only-overlay-fixture.png`: actual production `OverlayView` instances, 820 point width and 108 point height each, with long Chinese/English translations, pending translation, and failed translation. The gray backdrop and fixture heading are test-host decoration. This does not prove production panel transparency or click-through.

All images use an offscreen `NSHostingView`/`NSWindow` rendered with AppKit bitmap caching. The overlay check compiles the production `OverlayView.swift` into the scratch executable so its internal view and presentation model remain accessible without adding fixture APIs to production. No fixture code was added to the app.

Scratch programs: `/tmp/LiveSubDisplayModeRender.swift` and `/tmp/LiveSubOverlayModeRender.swift`. Both use `xcrun swiftc -parse-as-library -target arm64-apple-macosx15.0 -I .build/debug -L .build/debug`; the latest main-view render links the four existing native module `.o` files directly (avoiding duplicate transitive symbols from static archives), and the overlay links `LiveSubSubtitles`. Both exit after assertions/rendering.

## Retained preview regression check

`swift run SubtitleStoreChecks` passed after adding translation-only paragraph preview retention. A preview is first accepted against a known source snapshot; when the source advances, only `targetForDisplay(in: .translationOnly)` retains that preview with `上一版译文·更新中…`. The bilingual projection still emits `[译文更新中…]`, and bilingual exports exclude the old preview and presentation marker. A failed update replaces the old preview with `[翻译失败]`; a current recovered translation replaces the marker with the current text. Records with no validated preview retain `[翻译中…]`. No backend or store acceptance rules changed.

## Remaining interactive checks

Use the packaged app to confirm menu/main selector synchronization, actual live-session continuity while toggling, persisted mode across app relaunch, long translated-line readability, panel placement adjustments, transparency, no focus stealing, and click-through. Static/synthetic assertions do not establish these interactive properties.

## Final packaged-app verification

Later on 2026-09-26, the complete `./script/test.sh` passed 80 Python tests, Audio 5 checks, Store records/paragraph/terminology/display checks and 1,800 paired records, Overlay 4 position checks plus display/geometry checks, Backend 15 protocol checks plus real authentication/process lifecycle, and the Swift debug build. An independent run of 34 related backend tests also passed.

`./script/build_and_run.sh --verify` passed release compilation, bundle/Info.plist checks and strict ad hoc codesign verification. The binary at `dist/LiveSub.app/Contents/MacOS/LiveSub` has SHA256 `7926d5d8202fc3383cb1793d403ecd5544ed0d2aeb70bc2cb27a05edd56f7378`. Four checked packaged Python runtime files matched their sources byte-for-byte.

Actual CUA interaction in the idle app with zero subtitle segments verified:

- Selecting translation-only removed the original-language column from the accessibility tree and updated the target-language/empty state.
- Cmd+Q left no app or backend process; relaunch retained translation-only selection.
- Selecting bilingual restored the original column.
- Opening the overlay, changing to translation-only while it remained open, and hiding it kept the app idle throughout.
- Final quit left no app/backend process; the saved preference is `translationOnly`.

No recording was started. These observations supersede the earlier unverified relaunch-persistence/main-selector items only. The extra menu-bar entry was not clicked. Continuity while speaking remains covered by synthetic controller assertions, not actual live capture. CUA screenshots returned tilted thumbnails, so they provide no runtime pixel confirmation. The three production-view fixtures and the final stale-preview example were visually reviewed with no layout clipping/overlap; long English overlay text still truncates after two lines. Transparency, click-through, focus behavior and full audio-to-screen latency remain outside this check.
