# Image generation prompts v2

Tool path: built-in image generation (not CLI fallback).

Date: 2026-11-03

Output: four RGBA transparent-background 8-column x 4-row action sheets.

Reference image: `res://assets/vfx/trade/vehicles_topdown_v2.png`. It is used
only as a camera, material and palette reference; the military subjects are new
model-generated artwork.

## Shared prompt

```text
Use case: stylized-concept
Asset type: production game sprite atlas for a strategy-game military map formation, intended to be sliced into 8 columns x 4 rows
Scene/backdrop: genuinely transparent background, no floor, no scenery, no cast shadow.
Camera: 90-degree vertical orthographic overhead/zenith map camera, looking straight down perpendicular to the map plane. Strict plan view only.
Lighting/mood: flat diffuse map lighting; no directional cast shadows, no oblique shadows, no perspective.
Composition: PERFECT ORTHOGRAPHIC GRID, exactly 8 equal columns across and 4 equal rows down. One coherent east-facing token centered in each cell, same scale, same anchor, generous transparent padding, 32 distinct sequential frames.
Rows: IDLE / MOVE / ATTACK / HIT.
Style: hand-painted scissor-cut paper military map miniature, graphite pencil outlines, tactile but clean edges, readable at 48-64 screen pixels; match the supplied trade-convoy atlas's painted material richness, not vector-flat art.
Constraints: transparent RGBA; no overlap across cell boundaries; east is RIGHT; attack impact and hit effects stay flat in the horizontal map plane; crisp alpha edges.
Avoid: three-quarter view, isometric view, side view, front view, visible faces, visible legs in profile, perspective, horizon, diagonal shadow, camera tilt, SVG look, vector-flat icons, pixel art, low-poly 3D, glossy plastic, text, letters, numbers, borders, grid lines, watermark, checkerboard, extra objects outside cells.
```

## Foot

```text
Subject: a compact ancient/medieval infantry formation of about 3 soldiers grouped as ONE visual token. All soldiers face RIGHT/EAST. Shown from directly overhead: only helmet crowns/tops, shoulder tops, circular shield tops, spear shafts and hand tips. No faces, no torsos, no legs, no side silhouettes.
Palette: muted bronze, deep teal, warm parchment.
Animation: row 1 idle breathing/sway; row 2 marching; row 3 thrust and recover; row 4 recoil and reform.
```

## Mounted

```text
Subject: a compact cavalry section of about 2 horses with armored riders grouped as ONE visual token. Every horse and rider faces RIGHT/EAST. Strict plan view: horses appear as backs, hindquarters, manes, ears, tails and saddle tops; riders as helmet crowns, shoulder tops, shield discs and lance shafts. Horse legs are hidden or reduced to tiny top-facing hoof tips. Absolutely no side-view horse body, visible horse face in profile, visible rider face, or upright side silhouette.
Palette: leather-brown, bronze, rust-red, warm parchment.
Animation: row 1 idle; row 2 gallop; row 3 lance charge and recover; row 4 recoil and reform.
```

## Artillery

```text
Subject: a compact field-artillery section of about 2 antique cannon carriages with small crew grouped as ONE visual token. All barrels point RIGHT/EAST. Strict plan view: wheels read as circles from above, carriages as top-facing wooden planks and metal fittings, barrels as long top-facing cylinders, crew as helmet/hat crowns and shoulder tops. No carriage side wall, cannon side profile, crew faces, upright bodies or visible legs.
Palette: dark iron, bronze, ochre-gold, warm parchment.
Animation: row 1 idle; row 2 limbering/rolling; row 3 muzzle flash and recoil; row 4 smoke, crew recoil and reform.
```

## Armored

```text
Subject: a compact armored section of about 2 riveted tracked tanks grouped as ONE visual token. All tank hulls and long cannon barrels point RIGHT/EAST. Strict plan view: only tank roof, turret roof, engine deck, top-facing tracks, hatch discs, antenna and gun barrel top are visible. Absolutely no hull side walls, track side profiles, sloped isometric silhouette, wheels seen from the side, or horizon.
Palette: gunmetal, soot, slate-blue, warm parchment.
Animation: row 1 idle engine tremble/turret sway; row 2 track motion and dust; row 3 cannon flash and recoil; row 4 sparks/smoke and recovery.
```

## Rejected variant

`*_sheet_v1.png` is intentionally retained for provenance. Its foot, mounted
and armored rows drift toward a three-quarter or side view, so it is not the
runtime source for the current prototype. V2 does not overwrite it.
