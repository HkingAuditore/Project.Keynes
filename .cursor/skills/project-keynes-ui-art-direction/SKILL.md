---
name: project-keynes-ui-art-direction
description: Guides Project.Keynes player-facing UI, art direction, visual design language, data visualization, iconography, button material, animation, HUD, inspector panels, and grand-strategy presentation. Use when designing or implementing UI/UX, visual polish, effects, motion, data dashboards, player HUDs, icon libraries, Font Awesome-style icons, or Civilization/Europa Universalis/Victoria/Crusader Kings inspired interface work for Project.Keynes.
---

# Project.Keynes UI Art Direction

Use this skill whenever the task touches player-facing UI, HUD, inspector panels, UI architecture, visual design language, animation, effects, data visualization, or art direction for Project.Keynes.

The target reference family is grand strategy and historical simulation UI: Civilization 7, Europa Universalis 5, Victoria 3, and Crusader Kings 3. Use them as direction for information hierarchy, tactile controls, parchment/atlas/administrative elegance, and strategic clarity. Do not copy assets, exact layouts, icons, or proprietary presentation.

## Core Principle

Project.Keynes UI must feel like a scientific grand-strategy atlas, not a debug inspector.

- Prefer curated summaries over raw field dumps.
- Prefer cards, gauges, badges, timelines, and charts over long text lists.
- Keep simulation truth in existing data systems; UI only reads, transforms, and visualizes.
- Make every visual treatment support a player question: where is this, what matters, what changed, what risk exists, what can I do?

## Lessons From The Failed Iteration

Do not repeat these mistakes:

- Do not treat Unicode symbols as production icons. Use a mature icon source such as Font Awesome Free or an approved Godot-compatible icon font/SVG workflow, with license files kept in the project.
- Do not hand-draw temporary icons unless the user explicitly asks for bespoke drawing. A temporary drawn placeholder is not a design system.
- Do not ship flat `StyleBoxFlat` color pills as "historical buttons". Buttons need distinct normal/hover/pressed/disabled states, readable text, material contrast, border, radius, and shadow/highlight hierarchy.
- Do not use large semantic color fills behind text. Use dark or parchment surfaces, semantic accent borders/icons, and strong text contrast.
- Do not let right-panel content rely on lucky widths. Calculate card/gauge/tab layouts against the actual panel width and avoid clipped controls.
- Do not rebuild or animate the inspector every tick. Fast-forward must keep buttons clickable and panels visually stable.

## Hard UI Standards

- Iconography: prefer Font Awesome Free, Nerd Font, SVG assets, or another researched mature library before custom glyphs. Keep mapping in components/view models; never scatter raw private-use glyphs through business code.
- Buttons: all global button states must come from `UITokens`/theme. Active controls must be visibly different from hover and normal states.
- Readability: body text must remain readable on any colored surface; if text contrast is uncertain, remove the fill and keep the color as border/icon/accent only.
- Layout: every inspector section must fit at 1280x720 with the current `RIGHT_PANEL_WIDTH`; if it cannot fit, use scroll or fewer columns, not overflow.
- Performance: selection changes may rebuild the selected tile panel; daily ticks must update cached data or visible values only, not recreate the node tree.
- Library selection: when the user asks about existing libraries or a new UI capability, research mature reusable options first and record why the chosen option is lighter or safer than alternatives.
- Chinese numeric display: do not use English suffixes such as `k`, `M`, or `B` in player-facing Chinese UI. Use `UITokens.format_compact_number_cn()` for compact values, e.g. `1.25万`, `3.56亿`.

## Mandatory Grounding

Before UI design or implementation, read the current path being changed. Start with:

- `Project.Keynes/references/system-map.md`
- `Project.Keynes/Project/project-keynes/scenes/player_game.tscn`
- `Project.Keynes/Project/project-keynes/scripts/game/player_game.gd`
- `Project.Keynes/Project/project-keynes/scripts/ui/game_ui_manager.gd`
- `Project.Keynes/Project/project-keynes/scripts/ui/cell_inspector_view_model.gd`
- `Project.Keynes/Project/project-keynes/scripts/ui/components/inspector_panel.gd`
- `Project.Keynes/Project/project-keynes/scripts/ui/ui_tokens.gd`
- `Project.Keynes/Project/project-keynes/scripts/ui/ui_animation.gd`
- `Project.Keynes/Project/project-keynes/scripts/data_core/view_adapter.gd`

If the task involves resources, also read:

- `Project.Keynes/Project/project-keynes/scripts/data/resource_profile.gd`
- `Project.Keynes/Project/project-keynes/scripts/data/resource_profile_registry.gd`
- `Project.Keynes/Project/project-keynes/scripts/simulation/systems/natural_resource_daily_system.gd`

For complete visual language and component guidance, read [UI_ART_DIRECTION.md](UI_ART_DIRECTION.md).

## Existing Architecture To Preserve

Use this flow as the default:

```text
MapData / HexCell / WorldClock / MapGenerator
  -> DCViewAdapter + explicit non-schema HexCell reads
  -> CellInspectorViewModel
  -> InspectorPanel / HUD / focused UI components
  -> UITokens + UIAnimation + Godot Theme
```

Do not let UI components directly own simulation state. Do not add a new gameplay data model for visual convenience. Do not bypass `DCViewAdapter` for schema-backed fields unless the field is explicitly HexCell-only.

## UI Implementation Rules

1. Keep `GameUIManager` as the player UI assembly layer.
   - It wires signals, creates top-level HUD/panels/loading overlays, and owns scene-level UI state.
   - It should not become a giant per-field renderer again.

2. Put data transformation in view models.
   - `CellInspectorViewModel` converts raw cell/world data into player-facing categories.
   - Output dictionaries should be structured by `header`, `summary_cards`, `tabs`, and `categories`.
   - Display scores are UI heuristics; never feed them back into simulation.

3. Put visuals in components.
   - Use components under `scripts/ui/components/`.
   - Prefer `MetricCard`, `IconBadge`, `GaugeBar`, `RadialGauge`, `BadgeRow`, `CategoryTabs`, `SparklineChart`, and `InsightList`.
   - Add a new component only when existing ones cannot express the pattern cleanly.

4. Use tokens and theme.
   - Colors, spacing, radius, and animation timings belong in `UITokens`.
   - Motion helpers belong in `UIAnimation`.
   - Avoid hard-coded one-off colors inside feature code unless they are local data colors passed from the view model.

5. Keep third-party charting behind `ChartAdapter`.
   - Default to built-in drawing until the plugin is proven.
   - If Easy Charts or TauPlot is introduced, isolate its API in `ChartAdapter`.
   - UI business code must not import plugin classes directly.

6. Keep icon library access behind UI components.
   - Font Awesome/Nerd Font/SVG mappings belong in components such as `IconBadge` or a dedicated adapter.
   - View models may pass semantic icon keys, not hard-coded font implementation details.
   - Keep license files next to bundled icon/font assets.

## Data Visualization Rules

For numeric values, choose a visual grammar:

- 0..1 scalar: `GaugeBar` or `RadialGauge`.
- Current plus baseline: `GaugeBar` with marker.
- Enum/category: `BadgeRow`.
- Small set of key facts: `MetricCard`.
- Recent history: `SparklineChart` or timeline.
- Complex causal explanation: `InsightList` with at most 2-4 high-signal lines.
- Resource collection: show the full available natural-resource list with non-zero reserves. Hide zero-reserve rows. Do not use Top-N truncation for the resource tab; solve density with compact rows, scroll, grouping, or filters.

Never show more than the current decision requires. Move raw diagnostics to debug UI, not player UI.

## Performance Rules

- High-speed daily ticks must not rebuild every UI node.
- Refresh only the selected cell and only visible panels/categories when possible.
- Avoid per-frame allocation-heavy UI rebuilding for non-changing content.
- Use `_draw()` components for lightweight gauges/sparklines before introducing heavy chart widgets.
- Keep animations short and one-shot; avoid infinite flashing or layout-thrashing effects.
- Do not read large arrays in UI hot paths except for the selected cell or a bounded summary.
- Never animate or rebuild tab/card containers on every tick; text/gauge value updates should be throttled or event-driven.
- Hard invariant: 每日 tick 不再重建右侧面板节点树，只低频更新内部数据缓存；内容只在选中地块或切换标签时重建。这样快进时按钮不会被不断销毁重建，滚动位置和表格也不会跟着跳。

## Motion And Effects

Motion must clarify state changes:

- Panel open: right slide + fade, about 160-220ms.
- Panel close: shorter fade/slide, about 120-160ms.
- Tab switch: content crossfade, about 100-140ms.
- Gauge/metric changes: tween numeric value, about 160-220ms.
- Selection: subtle pulse on `CellHighlight`.
- Loading: progress card with current generation stage; avoid static blocking text.

Effects must be restrained: atmospheric, legible, and tied to state. Do not add decorative noise that competes with the map.

## Aesthetic Direction

Use a mature grand-strategy style:

- Strategic atlas: map-first, subdued UI chrome, thin borders, geographic color accents.
- Administrative ledger: clear cards, dense but hierarchical typography, readable numbers.
- Historical materiality: parchment, brass, enamel, dark glass, soft shadows, framed panels.
- Scientific instrument: gauges, sparklines, thresholds, baselines, confidence/risk language.

Avoid generic sci-fi neon, mobile gacha clutter, debug-console density, and raw spreadsheet presentation.

## Validation Checklist

Before finishing a UI change:

- [ ] Player can understand the selected tile's location, value, risk, and resource profile quickly.
- [ ] UI reads from `DCViewAdapter`, `MapData`, `HexCell`, `WorldClock`, or existing registries only.
- [ ] No simulation formula or persistent data schema changed for presentation alone.
- [ ] Top-level wiring remains in `GameUIManager`; rendering remains in components.
- [ ] New colors/spacing/motion use `UITokens` or `UIAnimation`.
- [ ] Icons come from an approved library/asset workflow, with license files present, unless the user requested bespoke art.
- [ ] Buttons have distinct states and readable text in normal, hover, pressed, disabled, and active/toggled states.
- [ ] Right panel content fits without clipping at 1280x720 and remains usable at fast-forward speed.
- [ ] High-speed tick behavior does not rebuild hidden categories unnecessarily.
- [ ] Lints and available Godot parse/smoke checks have been run or their absence reported.
