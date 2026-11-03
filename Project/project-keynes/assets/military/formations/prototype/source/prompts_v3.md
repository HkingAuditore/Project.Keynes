# Image generation prompts v3

Tool path: built-in image generation.

Date: 2026-11-03.

Output: sixteen RGBA transparent-background action sheets under `v3/`. Each
sheet contains exactly eight frames in a 4-column by 2-row grid, read
left-to-right and then top-to-bottom.

Reference role: the corresponding v2 sheet was supplied only as a style and
silhouette reference. The final v3 art is newly generated. No SVG, vector
drawing or code-rendered unit artwork was used.

## Shared prompt

```text
Use case: stylized-concept
Asset type: production game sprite action sheet for a grand-strategy map token
Scene/backdrop: genuinely transparent background, no floor, no scenery
Camera: strict 90-degree vertical orthographic overhead/zenith map camera,
looking straight down perpendicular to the map plane; plan view only
Lighting/mood: flat diffuse map lighting; no directional or oblique cast shadow

Composition: EXACTLY 4 equal columns by 2 equal rows, eight sequential frames.
Read order is left-to-right across the top row, then left-to-right across the
bottom row. The eight frames depict one short animation cycle with a stable
body/chassis/frame anchor, stable scale, stable east-facing direction, and only
local limb, weapon, wheel, turret, recoil or effect motion. Every unit and every
effect must be fully contained inside its own cell. Leave a large fully
transparent gutter between cells and around the complete sheet. No artwork may
touch or cross a cell boundary.

Style: hand-painted scissor-cut paper military map miniature, graphite pencil
outlines, tactile but clean edges, readable at 48-64 screen pixels; match the
material richness and palette of the supplied trade-convoy atlas, not
vector-flat art.

Facing: EAST is RIGHT.
Constraints: true RGBA transparency; eight different frames; stable anchor;
all combat effects remain flat in the horizontal map plane; crisp isolated
alpha silhouettes.
Avoid: three-quarter view, isometric view, side view, front view, visible face
or side profile, perspective, horizon, camera tilt, diagonal shadow, SVG look,
vector-flat icon, pixel art, low-poly 3D, glossy plastic, text, letters,
numbers, borders, grid lines, watermark, checkerboard, extra objects outside
cells, weapons or smoke crossing a cell boundary.
```

## Foot action sheets

```text
Subject: one compact visual token formed by about three ancient/medieval
infantry soldiers. Show only helmet crowns, shoulder tops, round shield tops,
spear shafts and hand tips from directly above. East-facing.
Palette: muted bronze, deep teal, warm parchment.

Idle: subtle breathing, shield float and tiny shoulder settle.
Move: compact marching cadence with local vertical body motion and planted feet.
Attack: three-stage spear thrust, extension and controlled recovery.
Hit: shield-wall compression, short recoil and reform; no whole-body jump.
```

## Mounted action sheets

```text
Subject: one compact visual token formed by about two armored horses and their
riders. Show only horse backs, hindquarters, manes, ears, tails, saddle tops,
rider helmet crowns, shoulder tops, shield discs and lance top surfaces from
directly above. East-facing. Never show a horse face in profile or a rider face.
Palette: leather brown, bronze, rust red, warm parchment.

Idle: restrained breathing and tack sway.
Move: controlled gallop cycle with stable formation anchor.
Attack: braced lance charge, short extension and recovery.
Hit: compressed recoil, rider/shield reaction and reform; lances remain in-cell.
```

## Artillery action sheets

```text
Subject: one compact visual token formed by about two antique field cannon
carriages and a small crew. Show only barrel tops, timber carriage tops, wheel
rings, hat crowns and shoulder tops from directly above. East-facing. Never
show a carriage side wall or an upright body.
Palette: dark iron, bronze, ochre gold, warm parchment.

Idle: slight wheel settling and crew breathing.
Move: wheel-spoke motion, suspension bob and counter-sway.
Attack: ignition, recoil, paired muzzle flashes, contained smoke and reset.
Hit: impact sparks, short compression, crew ducking, smoke dissipation and reform.
```

## Armored action sheets

```text
Subject: one compact visual token formed by about two riveted tracked tanks.
Show only hull roof, turret roof, engine deck, top-facing tracks, hatch discs,
antenna and long gun-barrel top surfaces from directly above. East-facing.
Never show hull side walls, track side profiles, wheels seen from the side or
an isometric silhouette.
Palette: gunmetal, soot, slate blue, warm parchment.

Idle: engine tremble, small suspension settle and turret sway.
Move: track motion, rear dust and stable chassis anchor.
Attack: staggered cannon flashes, recoil and contained smoke.
Hit: impact sparks, damage smoke, short compression and recovery.
```

## Validation before acceptance

- all sixteen sheets are RGBA and strictly 4x2;
- all 128 cells are non-empty;
- every cell boundary and outer canvas edge has zero significant alpha;
- no connected alpha component crosses a cell boundary;
- no weapon, exhaust, smoke, flash or shadow is clipped by a cell;
- adjacent frames are different and consecutive;
- the body/chassis anchor remains stable through the complete action;
- all cells are strict vertical plan view and face east.
