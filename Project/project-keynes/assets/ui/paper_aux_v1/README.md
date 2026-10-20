# Auxiliary cut-paper / torn-paper material v1

Generated with the built-in ImageGen tool. The two original RGBA PNGs are preserved;
Godot imports them losslessly at 256px (note) and 128px (tag). AtlasTexture regions
trim unused outer transparency. No image post-processing, blur shader, simulation
state or new UI data model was introduced.

The existing brass archive frame is the primary window surface. These materials
are secondary: inserted labels, annotations, tooltip/pop-up surfaces and notices.

| Theme variation | Control | Role |
| --- | --- | --- |
| PKPaperTag | Label | Short cut-paper label / small ornament |
| PKPaperAnnotation | Label | Wrapped annotation on torn paper |
| PKPaperNote | PanelContainer | Inserted note / explanation |
| PKPaperPopup | PanelContainer | Small contextual window / legend |
| PKPaperToast | PanelContainer | Skin consumed by the drawn research notice |

Existing PKBadgeLabel and PKDossierNote retain their names and use the new paper.
TooltipPanel and PopupMenu use the note surface. MapOverlayLegend, the overlay
submenu, InsightShell and object annotations are explicitly scoped to auxiliary
paper. Main archive windows and all existing button states retain their materials.

The note skin uses 32px texture slices with 8/8/8/10px external projection; its
content inset is 12/8/12/8px. Small pop-ups retain the earlier 10/8/10/8px content
inset. The tag uses 18/24/26/16px slices and 6/7/5/6px projection, with a wider right
text inset protecting the diagonal cut. Badge measurement uses the actual theme
font and content margins, after the label inherits its theme. Bounds, focus and
input remain ordinary Godot Control rectangles.

Inspector annotations draw one shared paper per block with cached text layout.
Research notices duplicate their skin once per component so fading never mutates
other widgets' shared theme resources. They still create no child nodes and stop
processing when empty.

## Validation

tests/ui/paper_aux_visual_qa.gd checks the theme variations, long tag bounds, wrapped
annotation insets and stable badge nodes, and renders the mixed materials at
1280×720, 1366×768, 1920×1080 and 2560×1080. Existing inspector patch/layout and
technology workspace tests cover the update and notice contracts.
tests/qa/paper_aux_game_screenshot_qa.gd uses formal overlay button signals to
capture the actual game with the cut-paper submenu, legend and notice. It also
inherits the fog, 50× and rapid reopen checks from the archive capture suite.

## Exact generation prompts

Both calls used transparent_background=true without reference images.

### torn_note_v1.png

Create a single production game UI texture, a blank warm ivory rag-paper note with hand-torn deckled edges, front-facing orthographic scan, no perspective. Square composition filling most of the image with 6 percent truly transparent exterior padding on all sides. This belongs inside a refined historical scientific atlas interface as an auxiliary pasted paper note, contrasting with precise metal-framed main windows. NO METAL FRAME, no brass, no decorative border line. Visible irregular paper silhouette: small asymmetric shallow tears, feathered paper fibers, 1 or 2 tiny missing edge nicks, a very subtly turned lower right paper tip, pale cut-paper thickness on top-left, close warm contact shade beneath bottom-right, restrained diffuse drop shadow on transparent exterior. Corners modestly irregular; tearing must be shallow and confined to the narrow outer 2 percent of the paper, never invade the text region. The long edge strips should remain nearly straight overall and work well in nine-slice game UI scaling. Cream paper surface with extremely delicate uniform fine grain, large CLEAN low-contrast empty center, no dark stains, no folds across center, no ruled lines, no holes, no symbols, no text, no handwriting, no pins, no clips, no tape, no ribbons, no stamps, no background objects. Sophisticated tactile layered cut-paper material, not a burned treasure map, not a serrated sawtooth border, not a neat rectangular gold panel. One blank note only, actual transparent alpha.

### cut_tag_v1.png

Create a single production game UI texture of a blank small cut-paper archival label, front-on orthographic scan, square canvas (intended for nine-slice scaling into short wide strips and labels). The blank ivory paper body fills the canvas except 6 percent truly transparent padding around it. NO FRAME, no metal, no border line. A hand-cut paper silhouette with gently imperfect straight top and bottom, softly torn uneven LEFT edge, one small diagonal clipped upper-right corner, tiny visible paper fibers at a few shallow nicks, layered pale upper-left paper edge and warm brown close contact shadow just below-right; a very soft compact cast shadow on the transparent exterior. All cut/torn details confined to a very thin outer 2 percent band, keep corners simple and legible at small label sizes. Large perfectly empty cream central surface with extremely subtle fine paper grain, clean uniform face, no darkness or gradient in the center. Visual style: elegant pale paper cutout for a historical scientific grand strategy atlas; lightweight inserted annotation slip, handmade paper but restrained and high quality, distinct irregular outline. No words, no icons, no stamps, no seals, no objects, no tape, no pins, no ornamental edging, no background, no checkerboard, no multiple objects.

