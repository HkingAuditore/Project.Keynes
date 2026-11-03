# Military unit artwork

`assets/military/units/<unit_id>.png` is optional genuine artwork for a unit type.
When a file exists, `MilitaryUnitCard` draws it instead of the procedural paper
sticker, so author art can land per unit without touching any code.

Rules:

- One PNG per `military_catalog.json` unit id, e.g. `militia.png`, `legionaries.png`,
  `tank_corps.png`. PNG with alpha, square, 512×512 or larger is the target.
- The card keeps the paper sticker, wax-crayon smudge and pencil outline around it;
  the file only supplies the figure. Do not bake a background or a border in.
- Missing files are normal: every unit falls back to the shared papercut stickers in
  `assets/military/papercut/` (built by `tools/ui/build_military_papercut.py`).
- No generated placeholder art belongs here. An empty directory is the correct
  state until an artist supplies figures.
