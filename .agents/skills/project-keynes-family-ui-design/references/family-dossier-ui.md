# Family Dossier UI Reference

Concrete lessons from the family workspace implementation. Read this when choosing tokens, asset treatment, responsive breakpoints, or regression tests.

## Visual Grammar

- Primary surface: warm restrained parchment/paper; dark ink for text, oxblood for identity/emphasis, brass or sepia for rules, and low-saturation regional colors for data accents.
- The background is a full-width dossier/page surface, not a card inside another card.
- Repeated records use a quiet framed card with opaque paper fill, modest radius, and thin rule. Avoid glossy gradients, neon, heavy shadows, and translucent white panels.
- A chapter tab is an icon above a compact caption. Active treatment may use a paper inset, oxblood mark, or brass rule; normal/hover/pressed/disabled remain distinct.

## Type and Spacing Starting Points

Keep these in the project's theme/tokens and tune against the actual viewport:

- Body: about 16px at 1280x720, with readable line height and regular/medium weight.
- Section title: 18-24px serif, semibold or bold.
- Family identity: larger serif display with a short subtitle.
- Metric values: compact, high contrast, and consistently aligned.
- Use an 8/12/16px rhythm; never solve alignment with literal spaces.
- Keep 12-16px content padding inside cards after texture margins are applied.

## Responsive Composition

- Wide (around 1920): identity/header plus four metrics in one row; overview may use two columns.
- Medium (around 1366): allow a 2x2 metric grid and a single-column page when needed.
- Compact (around 1280 or narrower): collapse navigation or place it in a compact row, keep the page vertically scrollable, and never let cards exceed viewport width.
- Test the actual project viewport; decorative frame width and scrollbar width reduce usable content width.

## Data Normalization Lessons

The renderer should receive already-merged semantic rows. A trait's `detail` and `effect_summary` must not describe the same sentence twice. Stable row IDs should include source kind and authoritative identity so refreshes patch the same node. Compute a page signature from row IDs and shape; rebuild only when that signature changes.

## Asset Lessons

- Keep final bitmap names/versioning explicit (`*_v2`, `*_v3`) and remove unreferenced failed intermediates only after checking references.
- A 2x generated frame can make 40px-looking corners when raw margins are used. Downsample to design scale or halve margins before shipping.
- Nine-patch corners should remain complete. If an ornament is too close to text, fix the asset/margin relationship rather than adding arbitrary text offsets.
- Use atlas textures or small semantic texture resources behind an icon catalog so feature code passes keys, not paths.

## Verification Commands

Use the project's configured Godot executable and focused tests:

```powershell
godot --headless --path Project/project-keynes --script res://tests/family_workspace_ui_test.gd
godot --headless --path Project/project-keynes --script res://tests/player_ui_view_model_test.gd
godot --headless --path Project/project-keynes --script res://tests/player_country_ui_smoke_test.gd
git diff --check
```

Classify unrelated existing failures separately. A passing family test does not excuse a newly introduced parse error or visual overflow visible in screenshots.
