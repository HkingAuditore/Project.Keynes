# Ideology UI v1 (papercut / scroll)

Bitmap set for the national-ideology workspace (`scenes/ui/ideology_workspace.tscn`).
All runtime access goes through `scripts/ui/components/ideology_art.gd`
(`IdeologyArt`), which caches textures and falls back to procedural drawing when
a file is missing.

## Provenance

- `source/ideology_asset_sheet_v1.png` (1536x1024) was generated with imagegen
  in the existing parchment / papercut / vermilion-seal language of the
  country dossier. It is the only authored source; keep it when regenerating.
- `tools/ideology/slice_ideology_ui_sheet.py <sheet.png>` keys out the
  border-connected near-white background, splits the sheet into connected
  components in reading order (cards, emblems, niches/seal/scroll), crops the
  two scattered decals from fixed regions, and writes RGBA PNGs. Re-run it
  after replacing the sheet, then run Godot `--import` once.

## Files

| File | Size | Use | 9-slice margin |
| --- | --- | --- | --- |
| `card_frame_common.png` | 318x423 | common card frame | 40 |
| `card_frame_rare.png` | 319x426 | rare card frame (gold-leaf sweep drawn on top) | 40 |
| `card_frame_legendary.png` | 326x427 | legendary card frame (ink splash + seal) | 44 |
| `card_back.png` | 320x428 | face-down card during the reveal | 40 |
| `school_*.png` (6) | ~254x258 | school emblems: agrarian, commerce, learning, mobilization, industry, harmony | none |
| `slot_niche.png` | 250x304 | ideology slot niche | 48 |
| `spirit_niche.png` | 246x304 | national-spirit (lacquer) niche | 48 |
| `scroll_bar.png` | 756x131 | point scroll progress bar | 60 horizontal / 0 vertical |
| `wax_seal.png` | 279x271 | choose stamp, pending stamp | none |
| `ink_splash.png` | 230x200 | legendary reveal particle | none |
| `paper_confetti.png` | 315x175 | reveal / choose particles | none |

Cards and niches currently draw with `TextureRect.STRETCH_SCALE` at a fixed
aspect. When a layout needs free resizing use
`IdeologyArt.nine_patch(texture, margin)` with the margins above (or an
equivalent `StyleBoxTexture` with the same `texture_margin_*`).

Motion (unroll shader, drop/flip, gloss, stamp punch, torn-paper reroll) is
procedural in `ideology_workspace.gd` / `ideology_card.gd`; the bitmaps carry
no animation frames. Reduced motion is a runtime toggle in the workspace.
