# Archive material v1

Four original, text-free RGBA materials generated with the built-in ImageGen tool.
Existing artwork remains untouched. Icons and all text are rendered by the existing
Godot components, not baked into these materials.

## Import and nine-slice contract

The original PNGs are preserved at 1254 × 1254. Godot's lossless texture importer
limits archive/HUD/button render sizes to 384/256/128 pixels respectively; no
runtime resizing, blur pass, shader or per-frame texture generation is required.

The generated opaque body positions were measured before choosing the AtlasTexture
regions. Atlas regions remove unused transparent space without editing the artwork.
Texture margins include shadow padding; matching expand margins keep the opaque
face aligned to the Control rectangle. Content margins retain existing layout
widths. Shadow padding does not receive input.

| Material | Atlas region in imported pixels | Slice L/T/R/B | Expansion L/T/R/B |
| --- | --- | --- | --- |
| Archive frame | 4, 9, 376, 365 | 52 / 52 / 52 / 60 | 18 / 13 / 18 / 23 |
| HUD frame | 7, 11, 242, 237 | 30 / 30 / 30 / 36 | 12 / 9 / 12 / 15 |
| Raised button | 4, 5, 120, 119 | 12 / 12 / 12 / 16 | 4 / 3 / 4 / 7 |
| Inset enamel | 9, 10, 110, 107 | 18 / 18 / 18 / 18 | 3 / 3 / 3 / 2 |
| Quiet inner paper | 48, 48, 288, 288 | 16 / 16 / 16 / 16 | 0 / 0 / 0 / 0 |

The quiet inner paper uses the archive image's central paper region. Country and
family pages retain their content margins but receive no second ornament/shadow.
The outside frame is the only large projected surface.

Theme colors/states live in player_session_theme.tres; layout and material
reference tokens live in UITokens. Hover brightens the raised material; selected
controls use the inset enamel; primary actions retain enamel under hover and
press. Disabled text retains a dark, readable ink tone.

## Generation prompts

All four calls used transparent_background=true, with no reference images.

### archive_frame_v1.png

Create a production Godot nine-slice UI texture: a single blank rectangular parchment dossier panel, front-on orthographic, no perspective. Canvas 1024 x 1024, square. The visible panel body is exactly inset 32 pixels from every canvas edge with truly transparent exterior. Warm ivory parchment with VERY subtle fine fiber texture, low contrast clean blank center, darker layered paper thickness visible only at edges. A refined thin burnished brass border with tiny restrained engraved corner guards, rounded/beveled corners, a pale upper-left edge highlight and darker lower-right edge bevel, subtle short soft cast shadow on the transparent exterior directed downward. All corner ornaments confined to 36 pixels inside the body edge, straight long edge strips of constant thickness suitable for nine-slice stretching. The whole material should feel tactile, sophisticated historical scientific atlas, delicate elegant craftsmanship, not heavy wood, no huge patterns, no text, no lettering, no symbols, no icons, no objects, no checkerboard. Large clean center must be flat neutral warm ivory, no lighting gradients across the center; only edge lighting. Fill one panel per image, do not create mockup, background, multi-item sheet or scene.

### hud_frame_v1.png

Create a production Godot nine-slice UI texture for a compact parchment HUD plaque, front-on orthographic, no perspective. Canvas square 1024 x 1024. Single blank panel body exactly inset 32 pixels from every canvas edge, transparent exterior. Ivory archival paper face with extremely subtle fine fiber grain, clean low contrast blank central field. Layered 2-sheet edge, thin restrained brass rim with tiny neatly beveled corner guards (ornament confined to 28 pixels inside body), modest upper-left cream highlight, lower-right warm brown contact shade, restrained soft downward cast shadow entirely in transparent exterior. Designed to downsample to 256x256 and nine-slice for both very shallow date/time bars and narrow vertical toolbars: keep all edge details small, uniform continuous straight edge strips, unornamented center. High-end warm historical atlas UI, tactile but lightweight. No text, no icons, no writing, no objects, no huge corner designs, no checkerboard, no background scene. One panel only.

### button_normal_v1.png

Create a production Godot nine-slice button texture. Single blank raised ivory parchment button plate, front-on orthographic, square canvas 1024 x 1024. Button body exactly inset 32 pixels from each edge, transparent outside. Very fine low-contrast paper grain and clean blank ivory face, subtle rounded corners, very thin burnished brass outline, small cream upper-left rim highlight, dark ochre lower-right bevel suggesting thickness, compact soft downward cast shadow in transparent exterior. Edge detail restricted to 20 pixels inside body; straight uniform edge strips for nine-slice. No ornament, no corner motifs, no text, no icons, no symbols, no scene, no checkerboard. This is a touchable elegant historical atlas control, neutral NORMAL raised state, rendered material only; no large spatial lighting gradient in center.

### button_pressed_v1.png

Create a production Godot nine-slice SELECTED/PRESSED button texture. Single blank inset dark oxblood-red enamel plate for an elegant historical strategy atlas, front-on orthographic, square canvas 1024 x 1024. Button body exactly inset 32 pixels from each edge; transparent outside. Muted dark burgundy/oxblood enamel face, very subtle mottling, very fine burnished brass rim, compact rounded corners, darker recessed upper-left inner bevel and restrained lower-right brass highlight, almost no outer drop shadow. Uniform clean empty central field, all edge detail restricted to 20 pixels inside body, straight uniform edge strips suitable for nine-slice. No letters, no text, no icons, no symbol, no ornaments, no background, no checkerboard, no multi-item sheet. Avoid shiny plastic or neon; sophisticated subdued matte enamel.

## Verification

Run tests/archive_material_screenshot_qa.gd with rendering to capture the actual
game at 1280×720, 1366×768, 1920×1080 and 2560×1080, three fog presentations,
material states and the country economy shell. It also checks 460px layout width,
16px logical inset and stable panel/navigation/scroll instances over ten days
at 50× speed. When the opening map has no remembered-only cell, that screenshot
uses an explicit UI-only fixture; player_ui_view_model_test.gd separately verifies
the real fog-gating contract. User UI scaling is respected by the capture checks.
