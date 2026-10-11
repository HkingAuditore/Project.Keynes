# Building Visual Art Direction

## What the current system is

The strategic map is painted terrain lit by a real sun. Buildings must sit in that world, so
they are rendered as a true top-down view of real roofs: each building volume is one
instance whose roof height field (gable, hipped, cone, dome, flat, sawtooth, cross,
courtyard, tower, mound, windmill, chimney, greenhouse, cooling tower, tank) is drawn with
one parallax step in the shader (no ray marching), lit with the shared earth daylight model,
and leaned slightly screen-up (0.30 per unit height) so a thin facade sliver with windows
shows below the eave. Shadows are vertex-built hulls toward the local sun. There are no
sprites, atlases, or authored images.

The first visual test is always recognition from the strategic camera: a cell must read as a
settlement of its era, with a plaza, streets, roofs and fields, before any texture detail.
The second test is that two neighbouring cells read differently when their economies
differ: dominant industry, size, and wealth must be visible without the inspector.

## Settlement readability rules

- Plan the settlement, not the building: plaza at the centre, 1–4 streets (by tier), lots
  fronting the streets in rings — civic, villas, houses with light industry, heavy industry,
  shanties, extraction and power, farmland. Stone age uses a ring camp.
- Keep visible ground between lots. Houses mix with shops along streets; they do not pave
  the hex. Dense cells may read as a town, never as one opaque blob.
- Orientation follows the street, not a fixed screen direction. The lean and shadows provide
  depth; a building never rotates independently of its lot frame.
- Every footprint stays inside its own hex and clear of river water.
- Roof material carries most of the colour. Keep saturation moderate (terracotta, slate,
  thatch, metal, membrane) so roofs sit in the oil-painting terrain rather than on top of it.
- Streets meander slightly and fade at the hex edge; long ruled lines read as UI, not roads.
- At night the terrain is lit by sky and moon only; roofs use the same ambient gain at night
  and windows supply warm light (averaged when individual windows fall below a pixel).

## Industry language: visual families

Resolution is data-driven through `BuildingVisualFamilyTable`: `visual.family.<id>` tag,
sector/kind, production climate profile, production resource, then keywords. The 22 families
group into the six archetypes used for style and macro glyphs:

| Archetype | Families and lot content |
|---|---|
| agriculture | field (farmstead, fields), paddy (granaries, flooded bunded paddies), plantation (sheds, orchard rows), pasture (barns, fenced pasture), forage (camps, hay meadow), fishery (huts/sheds on a timber or concrete quay) |
| extractive | mine (headframe, pit), quarry (terraced pit), forestry (sawmill, log yard), saltworks (boiling house, salt pans), wells (derricks, tanks) |
| manufacturing | workshop, food, textile (long halls → sawtooth mills), kiln (bottle kilns, brickfields), metallurgy (bloomery → blast furnace, tanks), chemical (tanks, stacks), machinery (sheds → assembly halls), electronics (clean flat plants) |
| energy | energy (windmills → boiler houses → cooling towers → solar and turbines) |
| knowledge | temple/church, academy courtyards, domes, campuses |
| service | market halls, shops, offices, towers |

Land use is log-compressed: the scale-weighted total maps onto a lot ladder split by
`weight^0.75`, so the dominant industry visibly takes more and larger lots while a single
minor workshop may not appear. A family is drawn no newer than its construction grade allows.
Family should still be identifiable if all colour is removed: footprint and roof form first,
material second.

## Population and wealth language

- Settlement tier (0–7) sets the skeleton: street count, plaza size, number and typology of
  houses (farmsteads → row houses → courtyard blocks/terraces → slabs and towers). A cell with
  people but no recorded buildings still draws its houses.
- Living level (0–6) sets quality: roof material (thatch/earth → tile/slate), gardens and
  hedges, paving. Poor towns keep dirt streets one era band longer and their plazas wear back
  to earth; rich plazas get a fountain (a monument before era 3).
- Rich share draws villas with gardens and pools in the inner ring; poor share draws shanties
  with muddy yards on the edge. Before the classical band inequality is damped to 0.35.

## Era language

Era bands follow the existing `TechnologyCatalog` era order (never inferred from content):

| Band | Eras | Language |
|---|---|---|
| stone | 0 | ring camp, cone/mound huts, stone ring, hearth |
| agrarian | 1 | thatch longhouses, dirt lanes, open fields |
| classical | 2–3 | terracotta tile, courtyard houses, cobbled plaza, windmills |
| early modern | 4–5 | slate and tile, crossing streets, churches, workshops |
| industrial | 6–7 | slate terraces, metal sheds, sawtooth halls, chimneys, macadam |
| atomic | 8 | concrete flats, towers, cooling towers, asphalt |
| information | 9–10 | glass-facade towers with plant roofs, green roofs, solar, turbines |

A hue swap is insufficient: each band changes plan, roof form, material and ground.

## Weather and depth cues

Snow settles on upward roof faces according to each material's snow hold and on the ground
decals; walls stay mostly clear. Rain darkens albedo and raises specular. Fogged memory
geometry is desaturated and stops sampling live snow/rain. Shadows tint toward cool blue, are
bounded in length, and disappear on the night side.

## Tuning

Use `tests/_tmp_building_art_harness.tscn` (11 era columns × 6 local economies — rice
hamlet, wheat town, textile town, mining town, rich capital, snowed coast — each with tier
and wealth bands; overview, close-ups, city, night and dusk shots; `detail` for single-cell
close-ups; `wealth` sweeps living level and inequality across columns at era 5). Read the
screenshots before and after every change.
