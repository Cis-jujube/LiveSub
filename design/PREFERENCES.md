# LiveSub design preferences

Iteration: 2026-09-26 / reference-led native macOS visual refresh.

## Explicit instructions carried into this task

The parent task supplies these as user requirements; they are not inferred from the reference products:

- Use the `anti-template-web-design` skill to improve the app's design and remove the generic AI-template feel.
- Preserve continuous paragraph reading.
- Preserve shared bilingual / translation-only display modes across main window and overlay.
- Preserve the transparent, text-only floating subtitle surface.
- Preserve default mouse pass-through and non-focus-stealing overlay behavior.

User's exact request: “用那个去网站ai味的skill优化一下这个app设计”. The other items above summarize requirements from the preceding conversation.

## Tentative design inferences

- Sustained reading likely benefits more from restrained controls, consistent measure and clear paragraph spacing than from additional panels, cards or motion.
- Familiar native macOS settings likely suit terminology editing better than a custom dashboard.
- A slightly stronger target-text hierarchy may be useful, but neither target dominance nor any specific font, palette or ratio has been approved.
- These are hypotheses to inspect in the actual app. No reference's colors, typography or composition are user preferences merely because it was researched.

## Keep fixed

Source/translation pairing; paragraph continuity; copy/export semantics; loading/error truthfulness; existing audio/session logic; explicit terminology save/reload/reset controls; locally stored terminology; next-request application semantics; overlay transparency/pass-through/focus contract.

## Recommended candidate and unresolved choices

Research recommends **A — Parallel reading desk**, documented in `REFERENCES.md`. This is the agent's recommendation. Candidates B and C remain unselected; none is recorded as user-approved.

Unresolved: final body size/line spacing; column gutter; preferred balance of source and translated text; maximum translation-only measure; degree of visible session metadata; light/dark visual result. Reversible defaults may be prototyped within the parent's authorized build scope, but silence is not design approval.

## Next refinement

Change only (1) control hierarchy and (2) paragraph composition/typography first. Preserve working state and data semantics. Re-research only a failing dimension: if reading feels too loose, compare useful measure and density; if controls are hard to find, compare native disclosure. Do not reset the palette and entire layout in response to one isolated objection.

## Evidence boundary

This file records instructions and design hypotheses, not usability-study findings. This research agent read official product text and local source; it did not render the references or operate LiveSub. Visual and interaction acceptance belong in the implementation QA record with concrete states and evidence.
