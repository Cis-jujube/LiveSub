# Native design verification

## 2026-10-04 · paper / ink / vermilion redesign

Scope: main window, overlay presentation, settings, menu-bar label, design tokens (`Theme.swift`), render scripts. AppController gained presentation-only state: an input-level meter fed from the existing capture frames, a structured input notice, an opt-in overlay backdrop preference, a Bool result from export, and a hook for the overlay's 完成 button. Backend, ASR, translation, store semantics and placeholder strings are unchanged.

### Executed checks

- `swift run AudioPipelineChecks` (7 passed), `SubtitleStoreChecks`, `OverlayPlacementChecks`, `BackendProtocolChecks --transport` (15 assertions + loopback): **passed**.
- `swift build --product LiveSub`: **passed**. `git diff --check`: passed.
- Python backend tests were not re-run; no backend file changed in this iteration.
- `./script/render_design.sh` and `--settings-only`: **passed**. The renderer now draws a real titled window off screen with the SwiftUI toolbar bridged (`sceneBridgingOptions = [.toolbars]`) and captures the window frame, so previews include the toolbar. `script/render_overlay.swift` draws the caption over a synthetic bright/dark frame.
- Not done: operating the packaged app. The design-check build launched, but screenshots of real windows were refused because Screen Recording is not granted to the agent host. Native Settings tabs and the live toolbar states (listening, paused, error) still need a look in the running app.

### Rendered production views (synthetic text)

| Fixture | Size (pt) | What to look for |
|---|---:|---|
| [Bilingual](previews/bilingual-1080.png) | 1080 × 720 | Toolbar status/source, reading bar with ⇄ on the spine, split separators, inline 翻译中… |
| [Narrow bilingual](previews/bilingual-820.png) | 820 × 560 | Minimum width; toolbar fits without overflow |
| [Translation-only](previews/translation-wide.png) | 1440 × 800 | 720 pt measure, 19 pt text, 译自 English ⇄ |
| [Dark bilingual](previews/bilingual-dark.png) | 1080 × 720 | Warm charcoal paper, lighter vermilion |
| [Empty](previews/empty-1080.png) / [dark](previews/empty-dark.png) | 1080 × 720 | Caption mark, phase copy, vermilion 开始, privacy note |
| [Overlay](previews/overlay-bilingual.png) / [backdrop](previews/overlay-backdrop.png) / [adjusting](previews/overlay-adjusting.png) | 1100 × 420 | Default transparency; opt-in backdrop over a bright area; 完成 and width grip |
| [Settings](previews/settings-rows.png) / [empty](previews/settings-empty.png) / [dark](previews/settings-dark.png) / [runtime](previews/settings-runtime.png) | 680 × 600 / 430 | Pane content as shown under each native tab (the tab bar itself is not rendered) |

Capture notes: toolbar prominent buttons render neutral because the off-screen app is never active; in-content buttons use the key-window environment. Dark captures read about 10 levels lighter than the specified colours (a plain `#1E1D20` swatch also captures as `#28262A`), so judge dark tones in the running app.

### Repairs from comparison

1. Toolbar items packed to the leading edge on macOS 26+ without a title; added `ToolbarSpacer` behind an availability check.
2. Disabled ■ in the idle toolbar read as a grey block; Stop now appears only once a session exists.
3. Translation-only header said 译文 and 译自 together; dropped the role word there.
4. Vermilion tint leaked onto every settings control; scoped it to Save and chips.
5. Continuous-curvature capsules drew edge ticks in captures; chips and pills use circular capsules.
6. White captions vanished over a bright region in the overlay render; added the opt-in backdrop.

---

## 2026-09-26 · previous iteration (its preview images have since been regenerated)

Date: 2026-09-26. Baseline: `2544c63`. Scope: presentation in three SwiftUI files, reusable native fixture renderer, and design documentation. Backend, ASR, model configuration, subtitle store, audio capture, overlay presentation/window behavior and external dependency declarations were not changed.

## Executed checks

- Final `./script/test.sh`: **passed**. 80 Python tests; Audio 5 checks; Store pairing, paragraph, terminology, display and 1,800-record checks; Overlay geometry/display checks; Backend 15 protocol assertions, authenticated/unauthenticated real loopback and lifecycle checks; final debug App build.
- `./script/build_and_run.sh --verify`: **passed**, including a final rebuild after the narrow-window alignment repair. Release, bundle, Info.plist and strict ad hoc signature checks succeeded.
- `./script/render_design.sh` and `./script/render_design.sh --settings-only`: **passed**. The former also asserts unchanged session/generation/records/revision/exports/status/source/direction across display-mode switches.
- `git diff --check`: passed during implementation and final review.
- Existing Starlette/httpx deprecation and CLT linker search-path warnings remain. No dependencies were changed to suppress them.

The first App compile failed because this local SDK exposed `@State` through an unavailable `SwiftUIMacros.StateMacro` plugin. Settings selection now follows the repository's existing `@StateObject`/`ObservableObject` pattern. Explicit main-actor isolation also resolved the standalone renderer's actor check. Both final full checks and release build passed after these changes.

Final local artifact: `dist/LiveSub.app`. Executable SHA256:

```text
2cad0a94f05445d0934bc6ac180ffb3535c736228c89a5b5fe7ca4a179922f13
```

## Rendered production views

These are actual SwiftUI views rendered through an offscreen AppKit host with **synthetic text**, not a live audio demonstration. No capture/model backend is started. The renderer restores its changed preferences and injects an already-loaded in-memory terminology editor; it does not read or save the user's terminology file. Native inactive-window buttons can appear neutral in these images.

| Fixture | Window size in points | Observed result |
|---|---:|---|
| [Bilingual](previews/bilingual-1080.png) | 1080 × 720 | Compact two-row controls, common paragraph axes, clear source/target hierarchy |
| Narrow bilingual (`bilingual-790.png`, removed) | 790 × 540 | No control collision; header and body aligned; long content continues in scroll area above fixed footer |
| [Translation-only](previews/translation-wide.png) | 1440 × 800 | Centered 700 pt reading measure, no source column, explicit previous-preview/pending markers |
| [Dark bilingual](previews/bilingual-dark.png) | 1080 × 720 | Adaptive neutral surfaces and legible body hierarchy |
| [Empty main window](previews/empty-1080.png) | 1080 × 720 | Functional prompt and short first-use/privacy note; no illustration or fake activity |
| [Empty settings](previews/settings-empty.png) | 680 × 620 | Category labels, empty editor and save controls visible |
| [Populated settings](previews/settings-rows.png) | 680 × 620 | Two synthetic rows align to direction/source/target headings; actions remain visible |

All seven were visually inspected by the implementing agent and the root reviewer. Review covered content, composition, typography, contrast/hierarchy, spacing, control containers and narrow-window overflow. The screen-bottom clipping of a long paragraph at 790 × 540 is the intentional scroll viewport, not a hidden fixed-height text box.

### Repairs from comparison

1. Source body looked disabled with semantic secondary text. Changed to primary at 0.78 opacity; inspected again in light/dark.
2. The native scrollbar changed the parent's measured width, offsetting narrow-window heading/body axes. Bound the reading region and leading alignment; inspected the final 790 × 540 result.
3. Initial native TabView capture had an unreadable black tab artifact. Replaced its shell with a native segmented category picker and inspected the complete settings view again.
4. Replaced the proposed promotional empty heading with functional copy. Empty copy now reflects real controller phases instead of always asking the user to start.
5. Restored the original 28–72% divider range after review noticed that an intermediate prototype narrowed it unnecessarily.

## Actual packaged-app operation

Using CUA on this Mac, with capture idle and zero subtitle records:

- Opened the new release and verified saved translation-only preference, Chinese → English direction, source selector and single footer status.
- Switched to bilingual: original heading appeared. Invoked the divider's exposed accessibility Increment and Decrement actions: 45% → 50% → 45%.
- Returned to translation-only and opened settings. Both category controls and terminology controls were reachable in the accessibility tree.
- Added one unsaved test term. Typed the source, used Tab to reach the translated field, and entered its target.
- Switched to “权限与本地运行”, verified real model/status/permission content, switched back, and confirmed both draft strings survived.
- Reloaded saved terminology to discard only the synthetic draft. A before/after file hash and existence check confirmed the saved terminology file was unchanged.
- Quit normally before the final alignment rebuild. The build's no-running-App check passed. The final rebuilt App was opened again; it remains idle, with translation-only selected and no recording started.

The multi-step settings interaction used the same final settings code. The last source change after that interaction was the main reading region's narrow-window alignment; its final production render and release compile were checked, followed by final App launch.

## Evidence limits

- This iteration did not run new live microphone/system-audio translation or latency benchmarks. Existing capture/accuracy limitations remain in the prior reports.
- Follow-live gestures during actual speech, all keyboard paths, VoiceOver speech, 100-term scrolling, 200% text enlargement, and all model/error phases were not manually exercised. Return-to-live reduced-motion behavior and non-idle empty copy were checked in source, not by toggling system settings or inducing live errors.
- Native CUA screenshots of the old window were tilted thumbnails. Runtime control/state evidence comes from accessibility observations; visual judgments come from the production-view fixtures. Active-window accent appearance is not established by inactive renders.
- The overlay was unchanged. This iteration does not re-certify pass-through, focus, multi-screen or full-screen behavior.
- Reference sites were read as official documentation/publisher text; browser access timed out. No reference-site animation or visual fidelity claim is made. See [REFERENCES.md](REFERENCES.md).
- No accessibility score, originality percentage, usability-study result or new performance improvement is claimed.

## Reproduce fixtures

From the repository root after preparing the existing environment:

```sh
swift build --product LiveSub
./script/render_design.sh
./script/render_design.sh --settings-only
```

The wrapper compiles a temporary copy of the App source with only the `@main` annotation removed, alongside the actual views and existing debug library objects. It cleans its temporary compiler output on exit. Fixture code is not bundled into the production App.
