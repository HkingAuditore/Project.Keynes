# Technology tree UI v1 (papercut / handscroll)

Bitmaps for the technology workspace's focus tree (`TechnologyTreeView`) and the
domain x era overview (`TechnologyOverviewView`). All access goes through
`scripts/ui/components/technology_tree_art.gd` (`TechnologyTreeArt`), which caches
textures and returns `false` when a file is missing so both views fall back to
their original StyleBoxFlat / icon-font drawing.

## Provenance

Four sheets were generated with the built-in ImageGen tool and are kept in
`source/`: plates, emblems, scrolls (all transparent) and the rice-paper backdrop.
`tools/technology_tree/slice_technology_tree_art.py <plates> <emblems> <scrolls> <backdrop>`
splits components by alpha in reading order, downsamples once and writes the
runtime PNGs. Re-run it after replacing a sheet, then run Godot `--import`.

## Files

| File | Size | Use |
| --- | --- | --- |
| `card_known.png` | 384x108 | presented technology card |
| `card_unknown.png` | 384x108 | fogged card (folded kraft) |
| `card_selected.png` | 384x105 | selected card (vermilion, gold cut line) |
| `card_milestone.png` | 448x122 | era milestone; overview hover |
| `domain_*.png` (4) | 62x64 | agriculture / engineering / science / society emblems |
| `state_*.png` (4) | 62x64 | completed seal, queued hourglass, pending sun, unknown |
| `era_scroll.png` | 768x214 | era title handscroll |
| `lane_ribbon.png` | 320x73 | domain lane ribbon tab |
| `lane_strip.png` | 101x384 | torn strip behind the focused domain lane |
| `canvas_paper.png` | 512x512 | tiled rice-paper canvas backdrop |

Total ~1 MB on disk, lossless import, no mipmaps.

## Drawing contract

- Plates are drawn as three horizontal slices whose caps scale with height
  (`TechnologyTreeArt.CAPS`), so notches, curls and rollers never stretch.
- Everything is immediate-mode `_draw()` on the existing canvases: no new nodes,
  shaders or per-frame texture work. Plates for one view share a few textures,
  so the canvas renderer batches them. Redraw triggers are unchanged (state
  patch, hover, selection, pan).
- Domain colour is still supplemental: state is carried by the seal bitmap plus
  the existing tooltip/text. Unknown and revealed-but-locked nodes use the
  unknown plate and seal only, so no semantic content leaks.

## Prompts (abridged)

- Plates: four blank 3:1 cut-paper card plates - ivory layered, kraft folded
  (unknown), oxblood with gold cut line (selected), ivory with brass rim and scroll
  curls (milestone); notched corners, decoration confined to edges, no text.
- Emblems: one row of eight circular layered-paper medallions - wheat, hammer and
  gear, alembic and star, figures under an arch, red wax-seal check, hourglass,
  sun, question mark; bold silhouettes readable at 24px.
- Scrolls: wide handscroll with wooden rollers and brass caps, swallow-tail
  ribbon tab, tall torn paper strip; blank centres.
- Backdrop: seamless low-contrast rice paper with a faint dotted grid and
  sparse embossed cloud scrolls.
