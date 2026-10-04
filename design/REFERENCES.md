# LiveSub reference research

Date: 2026-09-26. Scope: native macOS transcript, session controls, terminology editor, and overlay. Research method: anti-template-web-design v3 `01-research`, `02-reference-atlas`, and `03-directions-feedback`. This is a design input record, not runtime acceptance.

## Evidence and scope

- This research pass used original official pages/documentation through text retrieval. **D** means official documentation was read; **E0** means publisher descriptions/search excerpts. No screenshot, recording, browser operation, or installed reference app was inspected by this research pass. Image links and screenshots mentioned by pages are not evidence that those images were seen.
- Root agent may append separate E1/E3 observations with exact viewports/states. Do not promote the text evidence below automatically.
- Discovery channel A: official native writing tools and reading-product documentation, reached by problem-specific search. Channel B: adjacent knowledge collection and bilingual publishing, reached by official Are.na material and Harvard publishing coverage. Gallery queries for Readwise/Are.na did not yield a usable specific listing; gallery coverage is not claimed.
- Six independent works were screened; R1–R3 received deeper functional/documentation comparison. Sources do not establish macOS UI performance, actual animation, accessibility compliance, or responsive behavior.
- Existing implementation inspected: `app/LiveSub/MainWindow/TranscriptView.swift`, `app/LiveSub/App/TerminologySettingsView.swift`, `app/LiveSub/Overlay/OverlayView.swift`. Current strengths: continuous paragraph pairing, shared bilingual/translation-only state, selectable body text, editable terminology, explicit persistence controls, transparent overlay. Proposed presentation must retain those contracts.

## Screened works

| ID / work | Original source and discovery | Evidence / transferable mechanism | Exclude / fit decision |
|---|---|---|---|
| R1 iA Writer | [Quick Tour](https://ia.net/writer/how-to/quick-tour), official writing-tool search | D: Editor, Library and Preview are distinct; peripheral panes can close; Editor and Preview can sit side by side. Reading surface has priority. | Adopt control disclosure and parallel reading; do not copy typeface, branded blue, Markdown syntax, or file library. Deep reference. |
| R2 CotEditor | [Official product page](https://coteditor.com/), native text-editor search | E0: publisher describes split editing, contextual character inspection, CJK support, and a standard settings window. | Adopt native settings and inspectable structured text; exclude code coloring, line numbers, file browser, and code-editor density. Deep reference. |
| R3 Readwise Reader | [Appearance documentation](https://docs.readwise.io/reader/docs/faqs/appearance), reading-layout search | D: line width/size/spacing controls; side panels can collapse; long-form reading hides an action-heavy bottom bar. | Adopt readable measure and hierarchy; exclude feed triage, AI prompt field, document library, and the assumption that tablet columns are translation pairs. Deep reference. |
| R4 Ulysses | [First Steps — Library & Editor](https://help.ulysses.app/en_US/getting-started/first-steps-library-editor), official writing-tool search | D: three/two/editor-only pane modes, keyboard access, content-first plain text. | Reinforces optional peripheral tools. Do not introduce a library/project structure into a transient subtitle session. Supporting reference. |
| R5 Are.na | [About](https://www.are.na/about), adjacent knowledge-collection search | E0: capture, arrange, search, connect; content can be reused across contexts. | Useful for conceptual separation of source content from its presentation. Reject block grids and collection navigation for continuous speech. Counterexample. |
| R6 Loeb Classical Library | [Harvard Gazette: A leap for the Loeb](https://news.harvard.edu/gazette/story/2014/09/a-leap-for-the-loeb/), adjacent bilingual-publication search; [publisher series](https://www.hup.harvard.edu/series/loeb-classical-library?sort=date) | E0: official Harvard search excerpt describes retaining the facing-page original/translation relationship. | Borrow stable language position and correspondence. Exclude simulated paper pages, red/green branding, fixed pagination, and antiquarian typography. Digital reader original `/page/about` could not be retrieved; no reader interaction is claimed. |

## Deep comparison: supported details and design hypotheses

### R1 — iA Writer: keep the subject continuous while controls recede

**Inspected:** official quick-tour text, beginning through Editor/Library/Preview sections and final next-step link. [Focus Mode documentation](https://ia.net/writer/support/editor/focus-mode) also read as documentation. Device/viewport: none; D only. Product creator: iA, as shown by official site.

**Publisher-described mechanism:** the central editor is the main work surface; library and preview can be hidden; split preview supports parallel content. Focus documentation distinguishes active sentence/paragraph emphasis from vertically centered typewriter behavior and warns of jumping during editing.

**Translation to LiveSub (hypothesis):** retain a persistent transcript surface; put audio source, direction and session action in a compact upper band; route uncommon operations to settings. Keep source and translation aligned by paragraph. Follow-live should have an explicit state and stable user escape path.

**Exclude:** automatic dimming of historical paragraphs and typewriter centering. These could impede rereading speech and are not needed to reduce visual clutter. Do not copy iA's complete layout.

**Unknown:** visual type metrics, animation, pointer behavior, small-window adaptation, actual editor scrolling. None operated. LiveSub scroll changes require its own tests.

### R2 — CotEditor: native controls can coexist with a sparse text surface

**Inspected:** complete official product-page text, opening, feature list, standard-settings description, split editor, character inspector and CJK entries. Device/viewport: none; publisher description E0. The text links screenshots but they were not viewed here.

**Publisher-described mechanism:** document work remains in the editor; settings have a standard macOS home; character information is contextual rather than permanently occupying the document.

**Translation to LiveSub (hypothesis):** terminology uses a compact table-like editing surface with persistent column labels for direction, source, fixed translation and removal. Keep save, reload, reset and errors explicit, and preserve the distinction between draft edits and saved terminology. Use native control shapes and focus behavior.

**Exclude:** syntax colors, toolbar icon proliferation, configurable text encodings and developer inspectors. Their information model does not fit listening.

**Unknown:** exact settings layout, row sizing, keyboard traversal, VoiceOver and responsiveness. These remain local verification requirements.

### R3 — Readwise Reader: typography and disclosure serve sustained reading

**Inspected:** official appearance FAQ text including text settings, panel collapse, pagination rationale, long-form reading and tablet columns. Device/viewport: none; D only. Product creator: Readwise.

**Documented mechanism:** text measure is independent of window width; peripheral panels can be hidden; long-form mode reduces action prominence. The publisher explains maintaining text selection when choosing its scrolling model.

**Translation to LiveSub (hypothesis):** cap transcript measure inside wide windows, give paired columns a consistent gutter, keep body text dominant, and retain text selection. Translation-only mode should occupy a deliberate readable measure rather than spreading lines across the entire display. Status belongs at the edge of the reading area.

**Exclude:** pagination, justified text, AI prompt fields and independently navigated sidebars. Live speech needs a chronological continuous surface; the two language columns are one shared stream.

**Unknown:** actual full application layout, real transition timing, small-window line breaks and screen-reader behavior. Documentation is not observation of those states.

## Three structurally distinct directions

These are unrendered design storyboards, not approved or implemented designs. Each uses the same existing transcript, actions and terminology data. Since this is a native macOS app, the small-screen alternative means narrow desktop windows; no mobile app is proposed.

### A — Parallel reading desk (recommended)

- Thesis: the spoken session is one continuous bilingual document, with its controls at the edges.
- Order: compact session controls → language headings → continuous paired paragraphs → quiet status/export strip. Terminology remains a settings surface.
- Space/type: two equal starting columns with adjustable ratio; generous shared gutter; 17–18 pt system body, 11–12 pt metadata, 13 pt controls. These sizes are proposed local parameters, not measured reference styles. In translation-only mode, center a bounded reading measure.
- Material: system semantic text/background; separators only where they explain a region. A single accent reserved for the actionable session state. No transcript cards or repeated badges.
- Lead interaction: existing follow-live toggle and paired transcript updates; no animated rearrangement.
- Narrow window: wrap controls into stable rows while preserving both language columns and their minimum widths; translation-only remains an explicit user choice.
- Reference translation: R1's peripheral disclosure + R3's reading measure + R6's stable bilingual adjacency.
- Cost/risk: low to moderate presentation work; verify control overflow and preserve common row alignment. Fits existing implementation best.

### B — Listening stage

- Thesis: the latest translated thought dominates while earlier transcript becomes secondary.
- Order: large current translation → smaller paired source → compact recent history → session controls at the bottom; terminology opens separately.
- Space/type: one central reading axis, strong scale difference, substantial empty space. Narrow window stacks naturally.
- Lead interaction: manual expansion from current utterance to history.
- Reference translation: R1's focused text + R3's long-form controls.
- Cost/risk: changes information disclosure and makes comparison/review slower; overlaps the existing overlay's purpose. Would require behavior scope beyond visual polish. Not recommended for this iteration.

### C — Transcript with terminology inspector

- Thesis: the transcript is a workbench for reviewing translations against an always-available lexicon.
- Order: session toolbar → transcript occupying most width + persistent terminology inspector; export beneath transcript.
- Space/type: asymmetric 3:1 reading/inspection split; compact labelled term rows; sidebar may collapse in narrow windows.
- Lead interaction: open/close terminology inspector while reading; save remains explicit.
- Reference translation: R2's contextual inspection + R4's pane disclosure.
- Cost/risk: additional panel state, draft lifecycle and narrow-window complexity; reduces room for bilingual reading. Useful for active translation correction, which is not the primary live listening task. Not recommended now.

## Recommended boundaries and implementation research

Choose A as the implementation recommendation, not as an asserted user approval. Retain the overlay as transparent text with optional adjustment affordances; do not transplant the main window's surfaces into it. Keep loading, failed translation and empty states honest and visible without adding decorative feature content.

The repository already uses SwiftUI/AppKit and has no need for React Bits, Anime.js, web fonts or a browser animation stack. Existing `VStack`, `HStack`, native `Picker`, `Button`, `Menu`, `TextField`, semantic colors and `NSWindow` are sufficient to express the proposed mechanism. No dependency installation or declaration change is proposed. This statement comes from inspected local Swift source, not a claim of API/runtime validation.

Acceptance still requires rendered main-window empty/populated/loading/error states; terminology editing and validation; narrow-window overflow; light/dark appearance; keyboard reachability; and overlay transparency, mouse pass-through and focus behavior. Research alone closes none of those gates.

## Root inspection and access limits

Root inspected the existing production-view render `docs/translation-bilingual-layout-fixture.png`: three control rows, a large rounded wordmark, repeated status text, and paired paragraphs. It is a synthetic native fixture, not a reference-site screenshot or live transcription.

An attempted original-site browser visit to the iA quick tour timed out after 30 seconds. A subsequent browser inventory also timed out. Official-domain image searches for iA Writer and CotEditor returned no results. Therefore external research remains D/E0; no reference-site visual, motion, or responsive behavior is claimed. The old native app's accessibility tree was read, but its screenshot was a tilted thumbnail unsuitable for pixel review. New local production-view renders will supply the layout evidence, with runtime interaction recorded separately.
