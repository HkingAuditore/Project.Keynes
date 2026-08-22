---
name: project-keynes-family-ui-design
description: Design, implement, or review Project.Keynes family dossier and archival-detail workspaces with the established parchment dossier visual language, responsive Godot layout, semantic view models, bitmap framing, and stable high-speed refresh behavior.
metadata:
  short-description: Build the Project.Keynes family dossier UI
---

# Project.Keynes Family Dossier UI

Use this skill for family detail panels, notable-family workspaces, archival profile pages, branch/trait/preference/effect/people views, and future screens that should feel like the same historical dossier system. It is a feature-specific companion to the broader Project.Keynes UI art-direction skill.

## Desired Outcome

Build a readable, tactile archival workspace that answers: who is this family, what defines it, where is its influence, what assets and people does it control, and what action is available? Preserve authoritative simulation data and existing UI architecture; this skill governs presentation and interaction, not gameplay rules.

## Non-Negotiable Style

- Treat the workspace as an opened dossier or ledger, not a generic dashboard.
- Use restrained parchment, ink, oxblood, brass, and muted geographic accents. Material contrast should come from paper, ink, borders, and small ornaments rather than large saturated fills.
- Establish a clear hierarchy: family identity and prestige first, four high-signal metrics second, chapter navigation third, content cards fourth.
- Use Source Han Serif or the project's approved serif for headings and a legible sans/serif pairing for dense values. Keep body copy readable at 1280x720.
- Use icons as semantic labels or chapter ornaments. Prefer the project's registered bitmap/atlas/icon catalog; never scatter Unicode glyphs as production icons.
- Keep decoration subordinate to content. A corner ornament, crest, bookmark, or rule must not consume the content safe area.

## Implementation Workflow

1. Read the existing family scene, component script, theme, UI tokens, view model, and smoke tests before editing. Trace data from the authoritative family/cell model into the family workspace view model.
2. Preserve a stable model shape: `header`, `summary`, `pages`, and `actions`. Normalize duplicate traits, preferences, people, and branches in the view model so the renderer does not invent or repeat semantics.
3. Keep rendering in `family_workspace.gd` and reusable scenes/components. Keep simulation queries and presentation text in the view model or existing adapters. Do not add a parallel gameplay data model for visual convenience.
4. Build the shell first: dossier background, safe margins, header, metrics, chapter navigation, and bounded page viewport. Then add page-specific cards.
5. Validate at 1280x720, 1366x768, and 1920x1080; use single-column or compact metric arrangements when width cannot support a two-column page.
6. Run the focused family UI test and relevant player/country smoke tests. Capture real backend screenshots when visual work is involved.

## Layout Invariants

- Keep all content inside the page's inner safe rectangle, accounting for spine, paper border, ornaments, rules, and scrollbar.
- The page viewport owns vertical scrolling. Add explicit bottom breathing room so the final card can scroll fully above the decorative bottom frame.
- Use anchors, containers, size flags, minimum sizes, and responsive breakpoints instead of lucky fixed widths.
- At compact widths, fold chapter navigation and use bounded vertical scroll; never allow horizontal card escape.
- Avoid nested cards. Use a full-width page band for grouping and framed cards for repeated records or distinct tools.
- Keep node identities stable across daily ticks and ordinary model refreshes. Rebuild only when page shape/signature changes or the user changes family/page.

## Bitmap and Nine-Patch Rules

- Use bitmap assets when dossier materiality is part of the design; keep source assets and Godot import metadata together.
- Treat generated 2x artwork as source material, not final pixel margins. Downsample or compensate for design scale before choosing `StyleBoxTexture.texture_margin_*`.
- Set nine-patch margins to preserve corners and rules while allowing the center to stretch. If ornaments intrude into text, reduce margins or create a correctly scaled asset.
- Keep content margins independent from texture margins. Texture margins protect artwork; content margins define text breathing room.
- Use alpha and modulate conservatively. Pale cards must remain opaque enough to support text.

## Content and Semantics

- Header: family name, identity subtitle, prestige tier/progress, and one clear crest or family mark.
- Summary: four compact metrics with semantic icons; prefer localized Chinese compact numbers and consistent value alignment.
- Pages may include overview, traits, preferences, effects, people, and branches, but must not repeat the same fact under multiple labels.
- Trait cards distinguish trait kind, name, detail, and effect summary. If detail already explains the effect, do not duplicate it as a second effect line.
- Empty states explain what is absent and what the player can do next; never leave a blank framed region.
- Use icon-plus-caption for chapter actions; keep labels short enough to fit their tab state.

## Interaction and Refresh

- Chapter tabs need distinct normal, hover, pressed, disabled, and active states. Active state must be unmistakable without relying on color alone.
- Preserve current page and per-page scroll offsets when refreshing data. Reopening may reset transient drafts, but authoritative daily refresh must not erase them unexpectedly.
- Fast-forward and daily ticks patch visible values or cached rows, not destroy and recreate the workspace. Verify button clickability and scroll stability under repeated ticks.
- Keep colonization/branch actions wired to the existing controller and expose unavailable reasons through the established UI path.

## Visual QA Checklist

- [ ] Screenshot at 1280x720, 1366x768, and 1920x1080.
- [ ] No card, text, ornament, or scroll content crosses the page safe rectangle.
- [ ] Final scroll item clears the bottom frame; no decorative corner blocks content.
- [ ] Typography remains readable and hierarchy is obvious.
- [ ] Bitmap corners are preserved and not oversized, stretched, or cropped.
- [ ] Tabs show all required states and remain usable in compact mode.
- [ ] Same-shape refresh reuses nodes; page and scroll position survive refresh.
- [ ] Focused family UI test, relevant smoke tests, and `git diff --check` pass, or failures are classified as pre-existing.

For detailed token, breakpoint, asset, and test guidance, read [references/family-dossier-ui.md](references/family-dossier-ui.md).
