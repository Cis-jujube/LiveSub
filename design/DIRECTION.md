# LiveSub reading design

Iteration: 2026-10-04 (supersedes 2026-09-26). Reversible presentation update; no model, ASR, translation engine, storage format or permission change.

## Direction: paper, ink and one vermilion line

The app icon is an open book: an ink line on the left page (source) and a vermilion line on the right (translation). The interface uses the same three ingredients.

- **Paper** `#FBFAF7` / `#1E1D20` is the only surface in the main window. The previous four stacked tinted bands (title, controls, reading, footer) are gone.
- **Ink**: translation in primary ink; source in a softer warm ink (`#5E5A57` / `#A9A5A2`) so it reads as reference text without looking disabled.
- **Vermilion** `#C4472F` / `#E2664A` is reserved for live state and the primary action: the start button, the input-level bars, the live-paragraph marker and the translation column mark. Settings keep neutral controls except Save and selected domain chips.

Tokens live in `app/LiveSub/App/Theme.swift`, together with `EclipseMark` (the app icon redrawn in SwiftUI for the empty state) and `InputLevelBars`.

## Main window

- **Native unified toolbar** replaces the in-content header. Leading: session status (phase word plus real input-level bars while listening; spinner while preparing) and the audio-source menu. Trailing: 悬浮字幕 toggle, 字幕外观 popover, 说话人 popover, 导出 menu (copy / TXT / Markdown), 设置; then 停止 (only while a session exists) and the primary 开始 / 暂停 / 继续. On macOS 26+ the groups render as Liquid Glass capsules; on macOS 15 as a standard toolbar.
- **Column header is the reading bar.** `▬ English 原文 (⇄) ▬ 简体中文 译文 … [双语 | 仅译文]`. The ink/vermilion marks echo the icon. The ⇄ button sits on the spine and swaps translation direction (it replaces the direction picker). The display-mode switch lives next to the columns it controls.
- **Spine.** A hairline at the gutter centre runs the full reading height. Every row's gutter is the drag area for column balance (28–72%); the header exposes the same adjustment to accessibility.
- **Rows.** Source 15.5 pt / +6.5 leading; translation 18 pt regular / +8 leading (19 pt in translation-only). Separators stop at the spine. The newest paragraph shows a 3 pt vermilion marker in the margin while listening.
- **Placeholders.** `[翻译中…]`, `[译文更新中…]`, `[上一版译文·更新中…]`, `[翻译失败]`, `[未选中 · 未翻译]` keep their exact text in the model and in exports; the view restyles them as quiet inline notes and collapses adjacent ones (`TranscriptParagraph.Marker`).
- **Measure.** Bilingual stops widening at 1,240 pt; translation-only stays at 720 pt. Margins 32 pt below 960 pt width, 48 pt above.
- **Empty state.** Centered caption mark, phase-specific title/detail (unchanged copy), one primary action and the privacy note.
- **Notices.** Errors and input warnings (no frames / only silence) appear as one banner above the columns; copy/export confirmations are a brief toast. Status is not repeated in a footer.
- **Shortcuts.** ⌘R start / pause / resume (⌘Space was taken by Spotlight on most Macs); ⌘. stop.

## Overlay

Still transparent, non-activating and mouse-through by default. Source line is 0.84× and slightly dimmer than the target line. New opt-in **字幕底板** (dark rounded backdrop, persisted under `livesub.overlayBackdrop`) keeps captions legible over bright video; it is off unless the user turns it on. Adjust mode gains an in-overlay **完成** button and a labelled width grip, so finishing no longer requires returning to the main window.

## Settings

Native Settings tabs (`TabView` + `tabItem`) with grouped forms: 翻译与术语 (domain chips, quick presets, custom terms with direction / source → target / remove) and 权限与本地运行 (`LabeledContent` rows). The terminology draft is still owned outside the tabs and survives switching.

## Protected behavior

Preserve controller/session ownership, source/translation revision pairing, growing paragraphs, source selection, direction changes, start/pause/resume/stop, shared and persisted display mode, text selection, copy/export, explicit terminology save/reload/reset and conflict checks. The overlay stays transparent by default, nonactivating and mouse-through; do not transfer main-window backgrounds into it.

See [QA.md](QA.md) for executed checks and evidence boundaries.
