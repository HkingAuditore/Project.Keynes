# Image generation prompt set v1

Tool path: built-in image generation (not CLI fallback).

Date: 2026-11-03

Output: four RGBA transparent-background 8×4 action sheets.

## Shared prompt

```text
Use case: stylized-concept
Asset type: production sprite sheet for a strategy game military map formation prototype

Create one transparent-background technical sprite sheet with EXACTLY 8 columns
and EXACTLY 4 rows, totaling 32 equal cells. No captions, no letters, no numbers,
no grid labels, no checkerboard.

The 4 horizontal rows are, from top to bottom:
IDLE (8-frame breathing/sway loop),
MOVE (8-frame locomotion loop),
ATTACK (8-frame attack, impact, recoil and recover cycle),
HIT (8-frame recoil, pale impact flash, smoke/damage and reforming cycle).
Every row must visibly contain eight distinct sequential frames.

Use a true vertical overhead map perspective. All units face RIGHT/EAST.
Each cell contains one coherent formation token. Keep identical silhouette,
scale, equipment, anchor and lighting across all 32 cells.

Style: hand-painted scissor-cut paper military map miniature, graphite pencil
outlines, warm parchment highlights, tactile edges, archival military dossier
and living strategy map language. Readable at 48–64 pixels.

Composition: perfect orthographic 8×4 grid, equal cells, generous transparent
padding, no overlap across cell boundaries, uniform scale, same anchor.

Background: genuinely transparent overall. No backdrop, floor, frame, separator,
text, watermark, UI or checkerboard.

Constraints: 32 distinct usable frames; consistent design and scale; crisp alpha
edges; no diagonal perspective; no side view; no front view; no additional units
outside the grid.

Avoid: SVG look, vector-flat icons, pixel art, low-poly 3D, glossy plastic,
labels, borders, grids, text, numbers, watermark, checkerboard pattern.
```

## Per-sheet subject and palette

### Foot

```text
Subject: a tiny east-facing top-down ancient/medieval infantry formation,
roughly three soldiers with small shields and spears.
Palette: warm parchment, bronze and a deep teal unit accent.
```

### Mounted

```text
Subject: a tiny east-facing top-down cavalry pair, two horses with armored
riders, small lances and shields.
Palette: parchment, leather-brown and bronze with a rust-red unit accent.
```

### Artillery

```text
Subject: a tiny east-facing top-down artillery section, two antique field guns
with large spoked wheels, bronze barrels, draught poles and a small crew.
Palette: parchment, dark iron and bronze with an ochre-gold unit accent.
```

### Armored

```text
Subject: a tiny east-facing top-down armored section, two early-to-mid 20th
century tracked tanks with riveted armor, turret, long cannon barrels and small
paper-cut tactical antennas.
Palette: parchment, gunmetal iron and soot with a slate-blue unit accent.
```
