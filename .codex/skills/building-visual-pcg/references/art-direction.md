# Building Visual Art Direction

## What the current system is

The current implementation is one shared procedural house superset rendered through a
CanvasItem shader. It has six category archetypes and eleven era style slots, giving
`11 x 6 = 66` combinations in the style LUT. These are not 66 independently authored
building models or 66 unique silhouettes. The system deliberately spends geometry on a
recognizable house outline and uses shader parameters, material bands, and small category
facilities for variation. Landmark atlas coverage can add exact authored silhouettes later.

The first visual test is always recognition from the strategic overhead camera. A glyph that
looks like a flat resource marker is a failure even if its color encodes correct data.

## House readability rules

- Use a compact orthographic glyph with a visible two-plane pitched roof, ridge/eave contrast,
  front and side wall values, a lower foundation, and a small ground contact edge.
- Keep the foundation and any yard/decal at the bottom of the image. Do not randomly rotate a
  house; rotation makes the foundation move and destroys the map's reading direction.
- Anchor a single compound at the exact cell center. For multiple compounds, use a small
  hex-compatible layout radius and shrink annexes before pushing a body outside the cell.
- Make the door and two windows large enough to survive strategic zoom. Chimney, tower, tank,
  yard, or market canopy are secondary cues, not substitutes for the house mass.
- Avoid large transparent gaps in the sprite/quad. Keep the occupied mask tightly framed and
  use the lower foundation to close the visual gap between roof, wall, and ground.
- Keep at least 35% visible ground on dense cells at the highest quality. Density should read
  as a hierarchy of compounds, not a solid opaque blob.
- Use low-saturation material contrast: roof brighter than wall, back/side plane darker, and a
  non-black contact edge. Country colors belong on a flag, lintel, or tiny roof trim only.

## Category language

Category resolution is data-driven and ordered as follows: explicit `visual.archetype.*`
semantic tag, then `building_kind == service`, then `economic_sector_id`. The six stable
archetypes are:

| Archetype | Silhouette and ground cue |
|---|---|
| agriculture | low pitched house or barn, grain shed, yard/field edge |
| extractive | hut or shed with pit/ore pile, hoist or scaffold |
| manufacturing | long workshop, chimney, hard yard or loading shed |
| energy | wider body, tower/tank/pipe feature, safety gap |
| knowledge | orderly hall, courtyard, dome/observatory/antenna |
| service | central public house, market canopy, square or warehouse |

Category should still be identifiable if all color is removed. Use module silhouette and
footprint first, material tint second.

## Era language

Era style is a visual interpretation of the existing `TechnologyCatalog` era order. It is not
new technology content and must never be inferred from economy content. The eleven current
style bands are:

`stone`, `agrarian`, `kingdom`, `empire`, `exploration`, `enlightenment`, `steam`,
`electrical`, `atomic`, `information`, `intelligent`.

The style LUT should alter proportions, roof/edge language, material family, windows, and
facilities. A mere hue swap is insufficient. Useful progression cues are:

- early eras: low, irregular, earthen/wood/rough-stone masses;
- agrarian through enlightenment: courtyards, masonry bases, pitched tile/brick roofs,
  ordered public buildings and workshops;
- steam/electrical: long factories, sawtooth or large roofs, chimneys, steel frames and
  utility structures;
- atomic: broad concrete masses, tanks and ventilation structures;
- information/intelligent: compact campuses, glass/metal panels, antenna/sensor modules,
  restrained automation cues without neon science-fiction styling.

The renderer uses `style = era_index * 6 + archetype` and a shared style texture. Keep the
era index sourced from the country runtime's deepest completed era milestone.

## Weather and depth cues

Snow belongs first on upward roof masks, then as a restrained eave edge. Walls receive only a
small fraction of roof snow. Rain changes wetness and highlight response in the shader. Fogged
memory geometry is gray and low contrast and must stop sampling live snow/rain. Shadows are
analytical blue-gray false shadows with bounded length; they reinforce height and sunlight,
not physical accumulation.

For a flat overhead camera, this 2D false-depth treatment is preferred over 3D meshes because
it preserves map readability, keeps batching simple, and matches the vegetation layer's
strategic-map visual language.
