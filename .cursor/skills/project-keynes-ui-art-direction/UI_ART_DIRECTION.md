# Project.Keynes UI Art Direction Reference

This reference expands the `project-keynes-ui-art-direction` skill. Use it when a task requires detailed UI architecture, visual language, iconography, data visualization, motion, effects, or performance decisions.

It also records lessons from the July 2026 UI iteration: avoid placeholder-looking Unicode icons, flat color pills, low-contrast text, unstable per-tick inspector rebuilds, and layouts that only work by accident at one viewport size.

## 1. Product Identity

Project.Keynes is a scientific civilization and world simulation game. The UI should communicate:

- The world is physical, systemic, and alive.
- The player is reading an atlas, a cabinet report, and a living simulation instrument.
- The interface belongs to a serious strategy game, not a debug sandbox.

Reference qualities:

- Civilization 7: readable map-first composition, warm material UI, approachable information blocks.
- Europa Universalis 5: strategic clarity, restrained panels, political map readability, systemic tooltips.
- Victoria 3: data-rich dashboards, economic/institutional cards, charts, sortable logic.
- Crusader Kings 3: tactile framed panels, characterful historical UI, elegant hierarchy.

Do not copy their exact icons, layout, assets, fonts, or protected presentation. Extract principles: hierarchy, materiality, legibility, and strategic density.

## 2. Visual Design Language

### Core Style

Default style: historical scientific grand-strategy atlas.

- Base: deep ink, walnut, umber, aged parchment, muted brass.
- Material hints: parchment overlays, brass/copper accents, enamel icon badges, inked separators.
- Map priority: UI chrome should frame the map, not dominate it.
- Lines: thin, precise, warm, and material; avoid neon glow as the default active language.
- Shadows: soft but present, used to separate panels from terrain and imply depth.

### Palette Roles

Keep colors semantic and low-saturation:

- Brass/gold: focus, active speed, primary interaction.
- Earth brown: elevation, terrain, landform.
- Climate orange: temperature, sun, heat.
- Water blue: moisture, precipitation, rivers, ocean, ice.
- Ecology green: vegetation, vitality, succession.
- Resource gold: natural resources, deposits, yield potential.
- Risk red/orange: hazards, stress, low vitality, severe weather.

All new colors should either come from `UITokens` or be passed as semantic data from a view model.

Do not place readable text directly on high-chroma semantic fills. Prefer:

- Dark or parchment background.
- Semantic color as icon, border, thin side accent, small badge edge, chart line, or gauge fill.
- Strong text contrast from `UITokens.TEXT_MAIN`, `TEXT_MUTED`, and `TEXT_FAINT`.

### Typography

Use hierarchy instead of raw font size escalation:

- Panel title: short, strong, 18-22px.
- Primary values: 20-26px, numeric emphasis.
- Secondary labels: 12-14px, muted color.
- Long explanations: short lines, no dense paragraphs.

Chinese UI must avoid cramped mixed punctuation. Prefer concise labels:

- Good: `湿度 51% · 基线 42%`
- Bad: `当前湿度：0.51（湿润） 年均基线：0.42（含长期湿润反馈）`

Chinese numeric compaction:

- Use `UITokens.format_compact_number_cn()` for large player-facing values.
- Prefer Chinese units such as `1.25万` and `3.56亿`.
- Do not use English suffixes such as `k`, `M`, or `B` in Chinese UI.

### Player Copy

Player-facing Chinese must read like a cabinet brief, not a systems comment.

- Answer four questions: what is this, how is it now, what risk exists, what can I do.
- Ban implementation words: 原生, MarketStore, 测试人口, 世界生成页, 修订, 安全边界, 硬前置, 揭示证据, 冻结, 中性环境.
- Prefer `暂不可用` over `运行时尚未就绪`. Empty states describe the world, not developer import steps.
- Short labels. Prefer `湿度 51% · 基线 42%`. No parenthetical lectures.
- Insights: at most 2-4 lines, conclusion first.
- Formulas and accounting belong in object detail or tooltip.

### Iconography

Use mature, consistent icon sources before inventing new icons:

- Preferred: Font Awesome Free, Nerd Font, or curated SVG assets with compatible licenses.
- Acceptable: custom `_draw()` icons only for a project-owned visual identity pass, not as a quick placeholder.
- Avoid: raw Unicode symbols such as `△`, `☼`, `♣`, `◆` as production UI. They depend on font fallback and look inconsistent on Windows/Godot.

Implementation rules:

- View models pass semantic icon keys or legacy aliases only, such as `geo`, `sun`, `eco`, `water`, `resource`, `target`, `snow`.
- Components such as `IconBadge` own the mapping from semantic key to Font Awesome glyph/SVG/resource.
- Keep icon font files and license text in `res://assets/fonts/...` or a similarly obvious asset folder.
- Do not scatter private-use codepoints through `CellInspectorViewModel` or business UI assembly code.

### Button And Control Material

Buttons must feel like tactile strategy UI controls, not flat debug pills.

Required states:

- Normal: dark material body, readable text, subtle brass/copper border.
- Hover: clearer border and warmer body, not just a slight color shift.
- Pressed/active/toggled: materially distinct from hover; active speed/pause controls must be obvious at a glance.
- Disabled: lower opacity and muted text, still legible enough to explain state through tooltip or context.

Material rules:

- Use `UITokens.make_player_theme()` and `UITokens.button_style()` for global controls.
- Keep radius, shadow, border, and text color consistent across top HUD, tabs, close buttons, and speed buttons.
- Do not create ad hoc colored rectangular fills inside rounded controls.
- Do not use color alone for active state; combine color, border intensity, pressed state, and optional icon/text weight.

## 3. Information Architecture

### Top HUD

Top HUD answers global questions:

- What world am I in?
- What date/season/time is it?
- Is simulation paused?
- How fast is time moving?
- What common controls are available?

Recommended layout:

```text
[World Summary] [Setup] [Regenerate] [Fit]          [Year Day Season Time] [Climate Anomaly] [Pause] [Speed Pills]
```

Keep it shallow. Detailed diagnostics belong elsewhere.

### Tile Inspector

Right panel is a tile dossier, not an inspector dump.

Required structure:

```text
Header
  title: dominant landform / terrain
  subtitle: cube + offset coordinates
  badges: terrain, landform, vegetation, cover, weather

Summary
  radial score: tile suitability
  metric cards: terrain, climate, ecology, resource

Tabs
  overview, geography, climate, hydrology, ecology, resources, history

Content
  insights
  metric cards
  gauges
  charts
  badges
```

Each tab must answer one player-facing question:

- Overview: What matters most?
- Geography: Where is it and how traversable is it?
- Climate: How does temperature/moisture/sun shape it?
- Hydrology: What is water, cloud, snow, ocean, wind doing?
- Ecology: Is life stable, stressed, degrading, or recovering?
- Resources: What is valuable, available, growing, or blocked?
- History: What has changed recently?

Layout constraints:

- The right inspector must be usable at 1280x720.
- `RIGHT_PANEL_WIDTH` changes must be checked against radial gauge width, card columns, tab row, margins, and scroll container.
- If content does not fit, reduce columns, reduce verbosity, or scroll vertically. Do not allow horizontal clipping.
- Summary cards should communicate four facts quickly; if text wraps unpredictably, shorten labels in the view model rather than widening every component.

## 4. Data Acquisition Chain

### Canonical Flow

Use this read path:

```text
MapData SoA / DCWorldExt slots / HexCell facade
  -> DCViewAdapter for schema-backed fields
  -> direct HexCell reads only for documented HexCell-only fields
  -> ResourceProfileRegistry for resource definitions
  -> WorldClock for time, season, anomaly, calendar
  -> MapGenerator only for existing helper calculations
  -> CellInspectorViewModel
  -> UI components
```

### Field Sources

Use `DCViewAdapter` for schema-backed fields:

- temperature, moisture, base moisture
- elevation
- terrain, landform, vegetation, cover
- weather type/intensity/cloud/vapor/precip
- snow cover, sea ice fraction
- wind vector, wind speed
- ocean current, upwelling, SLP, wind stress curl, ocean psi
- river booleans and other mirrored fields

Direct `HexCell` reads are acceptable for non-schema or legacy facade fields:

- vegetation history / biome history
- vegetation vitality and succession streaks
- base vegetation when not mirrored
- volcano / lake seed flags if not mirrored
- current_state fallback values
- temperature transport anomaly when no adapter getter exists

Resource UI:

- Load profiles through `ResourceProfileRegistry.ensure_loaded()`.
- Iterate `ResourceProfileRegistry.ordered()`.
- Read reserve arrays via `ResourceProfileRegistry.reserve_map_field(profile)`.
- Read extra change arrays via `ResourceProfileRegistry.extra_change_map_field(profile)`.
- Respect `profile.land_only` and water/land state.
- Resource tab must show the full available natural-resource list with non-zero reserves. Hide zero-reserve rows. Do not hide non-zero resources through Top-N truncation; use compact rows, scrolling, grouping, or filters to manage density.

Time UI:

- Use `WorldClock` for year/day/season/visual day phase/calendar.
- Do not infer the calendar from frame time.

### Display Scores

View-model scores such as habitability, risk, or resource potential are UI heuristics. They must:

- Be labeled as presentation summaries.
- Stay local to view models.
- Never write back to MapData, slots, resources, or simulation systems.
- Never become hidden gameplay formulas without an explicit design pass.

## 5. Component Grammar

Use a small set of reusable visual primitives.

### MetricCard

Use for one primary fact.

Data shape:

```gdscript
{
  "title": "气候",
  "value": "温暖",
  "subtitle": "温 0.52 / 湿 0.61",
  "accent": UITokens.CLIMATE,
  "trend": "↑",
  "icon": "sun"
}
```

`MetricCard` icon values should be semantic keys. Legacy Unicode aliases may be normalized inside `IconBadge`, but new view-model data should prefer keys.

### IconBadge

Use for small semantic icons inside cards and compact panels.

Responsibilities:

- Load the approved icon font/SVG resources.
- Draw or style a consistent badge frame if needed.
- Map semantic keys to glyphs/resources.
- Keep mouse filtering disabled unless the icon itself is interactive.

Do not:

- Put icon font codepoints in view models.
- Reimplement multiple competing icon systems in separate components.
- Use `Label` with arbitrary Unicode for production iconography.

### GaugeBar

Use for scalar values and baseline comparisons.

Best for:

- moisture vs baseline
- precipitation
- resource reserve
- stress levels
- risk levels
- elevation with sea-level marker

### RadialGauge

Use sparingly for one headline score:

- tile suitability
- vitality
- risk only when it is the main state

Avoid multiple radial gauges on the same small panel; they compete visually.

### BadgeRow

Use for enums:

- terrain
- landform
- vegetation
- cover
- weather
- constraints such as water-only, blocked, passable

### SparklineChart

Use for short histories:

- vegetation history
- temperature memory
- resource change
- stability trend

Use `ChartAdapter.make_sparkline()` instead of constructing chart backends directly.

### InsightList

Use for causal explanations:

- Keep to 2-4 lines.
- Start with the decision-relevant conclusion.
- Avoid dumping every contributing variable.

## 6. Motion And Effects

### Motion Values

Defaults:

- Fast: 0.10-0.14s.
- Medium: 0.16-0.22s.
- Slow: 0.24-0.32s.

Use `UIAnimation` for common motion. Do not scatter bespoke tweens unless a component has a specific visual state.

### Panel Motion

Panel open:

- Slide from the edge.
- Fade from 0 to 1 alpha.
- Ease out.
- Duration 160-220ms.

Panel close:

- Slight slide out.
- Fade out.
- Ease in.
- Duration 120-160ms.

### Data Motion

For values:

- Tween gauges to new values.
- Do not tween text every tick if it creates noise.
- Pulse only when a meaningful threshold is crossed.
- Do not crossfade or slide whole content sections during high-speed daily simulation.

Threshold examples:

- risk crosses from medium to high
- vitality enters degradation warning range
- resource trend flips sign
- weather changes from clear to storm

### Map Selection Effects

Selection should be subtle:

- Hex outline pulse once.
- Optional small contextual flyout for 1 second.
- No constant blinking.

### Fog Of War And Borders

Fog carries meaning, so keep the three states visually distinct without noise:

- Unexplored: opaque, slow-drifting cloud bank. It must read as "nothing is known
  here", not as bad weather.
- Explored but unseen: thin veil plus desaturated terrain. Colour is the signal
  for "remembered, not current"; real-time weather is masked here for the same
  reason.
- Visible: unmodified.

Transitions between states are softened by a two-ring blur on the underlying
knowledge value, not by animating per-cell alpha. Do not add per-hex fade
tweens; the fog is one full-screen pass, and the softening already exists in the
data.

The target is a sea of clouds seen from above: billowing towers catching the sun
on top, blue-grey ravines between them, ragged cauliflower edges where the deck
breaks up.

**Do not raymarch it.** That was tried and reverted. A top-down map only ever
shows the top surface of the deck, so hundreds of noise taps per pixel buy nothing
the player can see, and the step count a full-screen layer can afford is low
enough that it undersamples and looks worse than the cheap path. The fog is a
height field plus a few probes along the sun direction, which is where every part
of the scattering model still comes from.

Five things carry the look, in rough order of importance:

- **Billow noise, not plain FBM.** Ordinary FBM has isotropic contours and reads as
  smoke or marble no matter how it is lit. `|2n-1|` gives round tops and creased
  valleys — cumulus. Keep the low octaves as ordinary gradient noise for the broad
  coverage swell and switch only the high ones to billow; all-billow gives a
  uniform foam. Domain warping on top of that breaks up the direction, and the
  displacement wants to be close to a full noise cell — without it the contours
  stay isotropic and the layer reads as smoke.
- **Sky occlusion by tower height, plus a multiple-scattering fill.** Tops see the
  whole sky, ravines do not — that is what makes a cloud *sea* rather than a lit
  surface. The fill term is what keeps the ravines from going black, and it
  deliberately ignores the surface normal, because light bouncing in from
  neighbouring cloud has nothing to do with local orientation.
- **Soft normals.** A raw FBM gradient is white noise — every octave contributes
  the same slope — and shading with it makes the cloud look like crumpled foil.
  Damp the high octaves so lighting is driven by the large shapes and detail only
  perturbs it.
- **Multi-scatter extinction, not single-exponential Beer.** A single exponential
  crushes shadows to black, which reads as smoke. Two exponentials with different
  rates approximate the long tail that makes clouds look translucent.
- **A near-white albedo with the darks earned by lighting.** Darkening the albedo
  to get contrast produces a flat grey slab — this was the exact failure mode of
  an earlier attempt. Balance direct + bounce + ambient so tower tops nearly clip
  to white.

Cellular noise was tried twice as a way to get the discrete lump-by-lump reading
of a real cloud sea, and rolled back to billow FBM both times on the strength of
how it actually looked. If anyone revisits it: do not build the lumps from Worley
F1. `min()` over candidate distances has a discontinuous gradient wherever the
nearest feature point changes, so every cell boundary becomes a hard crease and
the screen fills with a Voronoi polygon net — straight edges around glowing cell
centres, closer to cracked ice than to cloud. A smoother dome profile does not
help, because the crease comes from `min()` rather than from the profile. Summing
smooth radial kernels instead stays smooth everywhere. Note also that cellular
noise turns its hash output directly into feature-point *positions*, so a weakly
decorrelated hash like `fract(sin(x))` — tolerable for gradient noise, where
interpolation hides it — shows up as lumps marching in rows.

Clouds are not opaque diffuse surfaces. Their single-scattering albedo is
essentially 1 and photons bounce dozens of times before leaving, so the shadowed
side is nowhere near black. Anything that models them like stone — a hard `N·L`,
no bounce term, a sky-occlusion floor pushed to zero — immediately reads as
"missing GI".

The subtler version of the same mistake is attenuating the bounce term
*exponentially*. An exponential is Beer's law, which describes direct
transmission of singly-scattered light. High-albedo media are in the diffusion
regime instead, and diffusion has a much heavier tail — a rational `1/(1+kd)`
is the cheap stand-in. Depth 2 gives 0.11 under an exponential versus 0.31 under
the rational form, and that gap is the whole difference between stone and a cloud
whose shadowed side still glows.

Shadowed cloud is blue, not neutral grey. The lit face is warm because it sees
the sun directly; deeper in, the sun is occluded and the dominant illuminant
becomes skylight, which is Rayleigh-scattered and strongly blue. Water droplets
scatter almost achromatically, so the light bouncing around inside the cloud does
not itself turn blue — it simply fades, and the sky takes over. The multiple
scattering fill therefore has to drift in colour from key to sky with depth. That
warm-lit / cool-shadowed pairing carries a large share of the realism; a grey
shadow reads as painted stone immediately. Normalise the tint colour to unit
luminance so hue and brightness stay independently tunable.

Any layer that consumes time-of-day must also consume the moonlight triple from
`EarthDaylight`. Terrain, water and vegetation all do; a layer that forgets will
sit pitch black over a moonlit landscape. Near the terminator that is still not
enough: daylight and moonlight both fade to zero there and leave a gap, so a
skylight floor is needed on top — and it must be tinted blue like the sky, not
grey.

Three more that are easy to get wrong:

- A single-lobe phase function collapses to near-black whenever the sun is low,
  because looking straight down makes the scattering angle track sun elevation.
  Real clouds do not do this — high-order scattering has already washed out the
  directionality — so the phase must carry an isotropic floor.
- Never accumulate premultiplied radiance and then divide by coverage. Coverage is
  identically 1 across unexplored territory, so dividing it back out removes every
  bit of light and shade along with it.
- Height-field probes (self-shadowing and similar) must use the same octave count
  as the field they are compared against. Mismatched bands make the difference
  dominated by frequencies only one side has, which produces speckle instead of
  directional shadow.

Lighting comes from the same per-pixel `earth_daylight` terminator as terrain,
water, vegetation and weather clouds, so the fog is swept by dawn and dusk along
with everything else — cold white tops at noon, warm rim light and long inter-cloud
shadows at dusk, cold blue ambient at night. Never let the night side fall to
black; unexplored territory turning into a dead black slab reads as a rendering
bug.

Two rules that are easy to get wrong:

- **Procedural noise must fade octaves by screen footprint.** Zoomed out, high
  octaves drop below a pixel and point-sampling turns the whole layer into
  flickering grit. This is a general constraint for any procedural layer on a
  zoomable map, not a fog quirk.
- **The map wraps east-west, so the noise has to tile.** Sample points get folded
  back into one wrap period; ordinary noise does not match across that boundary
  and leaves a vertical seam straight down the screen. Every noise call in the fog
  layer, including the one that breaks up the hex outline, uses the tileable
  variants.
- **Quality is tiered, and the cheapest tier is genuinely cheap.** q0 is flat
  colour with a single octave and no lighting at all; q1 adds normals and sky
  occlusion; q2/q3 add domain warping, self-shadow probes, powder, silver lining
  and subsurface transmission. Low-end hardware gets q0, desktop gets q3. The
  terrain early-out is only valid at q0, because it assumes the fog paints a
  constant colour.

Country borders are a double band: each side of a contested edge contributes its
own inward ribbon, so a shared border reads as two national colours with a dark
seam. That dark casing is what lets a saturated national colour hold up over any
terrain — without it a gold line dissolves into yellow-green grassland.

Line width is **not** constant in screen space. A fixed hairline over huge
hexes looks cheap when zoomed in, so screen width grows sublinearly with zoom
(`base × zoom^0.42`, clamped) while geometry stays fixed — camera zoom only
adjusts a shader uniform and never rebuilds the mesh.

## 7. Performance Strategy

### UI Refresh Frequency

Use refresh granularity:

- World generation: progress only.
- Clock update: top HUD only.
- Daily selected tile update: selected-tile data cache and visible values only.
- Tab change: visible tab content only.
- Regeneration: rebuild context and clear selection.

Avoid full node tree rebuilds on every daily tick. Rebuild selected-cell UI on selection changes or tab switches; update value caches or visible components on daily ticks. During fast-forward, the inspector must not flicker, shift, or make buttons unclickable.

Hard implementation invariant:

每日 tick 不再重建右侧面板节点树，只低频更新内部数据缓存；内容只在选中地块或切换标签时重建。这样快进时按钮不会被不断销毁重建，滚动位置和表格也不会跟着跳。

Recommended pattern:

- `show_cell_panel(cell)`: build view model, rebuild panel once, play panel enter animation.
- `refresh_selected_daily_lines()`: throttle and update cached data; do not recreate buttons, tabs, scroll containers, or card grids.
- `set_model(model, rebuild_visible=false)`: preserve current tab, scroll position, and interactable controls.
- `tab_selected`: rebuild visible tab only.

### Allocation Control

Avoid:

- Creating many new Control nodes every frame.
- Reading all cells for one selected tile panel.
- Building large arrays for hidden charts.
- Per-frame `ResourceProfileRegistry.ensure_loaded()` in hot paths.
- Re-running icon font loads or license/resource discovery in hot paths.
- Rebuilding tab buttons, speed buttons, or scroll containers during simulation ticks.

Acceptable:

- Rebuilding a selected tile panel on selection change.
- Recomputing visible selected-tile metrics once per day.
- Drawing small gauges/sparklines with `_draw()`.

### Chart Plugins

Default backend:

- Built-in `SparklineChart` with `_draw()`.

Plugin evaluation:

- Easy Charts: better adoption for standard charts.
- TauPlot: better scientific/interactive plot fit but newer.

Rules:

- Add plugin only after Godot version compatibility is checked.
- Isolate plugin API in `ChartAdapter`.
- Keep built-in fallback.
- Never make a plugin mandatory for core UI boot.

## 8. Implementation Workflow

When implementing a UI/art change:

1. Identify the player question.
   - Example: "Why is this tile valuable?"

2. Trace data source.
   - Adapter getter?
   - HexCell-only field?
   - Resource profile array?
   - WorldClock state?

3. Add or update view-model output.
   - Keep raw values and display labels separate.
   - Use semantic accents.
   - Keep category shape stable.

4. Render through components.
   - Reuse existing components first.
   - Add a component only for a recurring visual pattern.
   - Author the shell and fixed slots in `.tscn` (`@onready` / `%UniqueName`, editor signal connections). Scripts fill data; they do not `Control.new()` a layout.
   - Instantiate a PackedScene only for variable-length lists (collection rows, badges). Prefer updating existing children over `queue_free` + rebuild.
   - Put ConfirmationDialog and other popups in the scene, not `ConfirmationDialog.new()`.

5. Apply tokens and motion.
   - Use `UITokens`.
   - Use `UIAnimation`.

6. Validate.
   - Lints.
   - Godot parse/smoke if available.
   - Manual selection/tick/regenerate test.
   - Check high-speed tick behavior.
   - Check right panel at 1280x720 and at the current development viewport.
   - Check button normal/hover/pressed/active/readability states.
   - Check that icon assets load from the approved library and license files are present.

### Library Selection Workflow

When the user asks for an existing UI, chart, or icon library:

1. Search mature reusable options first.
2. Prefer official packages/assets with clear licenses and current maintenance.
3. Avoid introducing a full Godot editor plugin when a small runtime asset is enough.
4. Keep plugin APIs behind adapters such as `ChartAdapter` or icon components.
5. Record the decision briefly in the final response: chosen option, why not alternatives, license/resource implication.

## 9. Anti-Patterns

Do not:

- Recreate the old `InfoPanelController` label dump in a prettier container.
- Add simulation writes from UI components.
- Add new persistent fields for pure presentation.
- Use raw normalized numbers without labels, bars, or context.
- Show all possible metrics at once.
- Make a chart plugin a hard dependency without fallback.
- Let animations loop indefinitely.
- Use bright neon sci-fi styling as the default game identity.
- Hide important text behind hover-only interactions.
- Use Unicode fallback glyphs as production icons.
- Present hand-drawn placeholder icons as final art direction.
- Use large colored backgrounds for cards when text contrast is not proven.
- Create rounded controls with visible rectangular fills inside them.
- Let right-side UI overflow horizontally or hide content outside the viewport.
- Rebuild inspector nodes every simulation tick.
- Fix readability by only changing colors while leaving broken component structure intact.

## 10. Iteration Reflection

The July 2026 UI iteration exposed these process failures:

- I over-indexed on quick local fixes: changing color constants and adding Unicode glyphs made the UI look different but did not establish a real visual system.
- I treated symptoms as isolated issues: poor readability, ugly icons, and bad button feel were all consequences of weak component grammar and missing asset standards.
- I used placeholder iconography where a mature library was the appropriate solution. The correct path was to research Font Awesome/Nerd Font/SVG options, then isolate the chosen implementation behind `IconBadge`.
- I initially underestimated layout math. The right panel must be designed from fixed constraints: viewport, panel width, margins, gauge size, card columns, and tab widths.
- I did not make performance a visual acceptance criterion early enough. A UI that flickers or rebuilds during fast-forward is functionally broken even if the static screenshot improves.

Corrective principles:

- Before polishing colors, verify component structure, asset source, layout constraints, and update frequency.
- Use libraries for commodity visual assets; spend custom work on game-specific hierarchy and data presentation.
- Treat readability, clickability, and stability as non-negotiable before decorative styling.
- Every UI change should include a quick "screenshot thought test": would this still look like a serious historical strategy game at 1280x720 during fast-forward?

## 11. Acceptance Standard

A finished Project.Keynes player UI change should pass this standard:

- A new player can tell what the selected tile is, what it is good for, and what threatens it within 3 seconds.
- A strategy player can drill down into the numeric cause within one click/tab.
- The map remains visually dominant.
- The UI feels like a historical grand-strategy atlas and administrative dashboard.
- The data remains traceable to existing simulation sources.
- High-speed simulation remains responsive.
- Icons are consistent, licensed, and sourced from an approved library or asset workflow.
- Buttons have clear material states and readable labels.
- Right-panel content fits without horizontal clipping at 1280x720.
