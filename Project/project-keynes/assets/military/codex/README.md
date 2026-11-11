# Military codex sticker atlas v1

Original AI-generated hand-drawn military vignettes created for
Project.Keynes on 2026-11-02. The supplied ToyEmpires unit images were
used only as a style reference for waxy colored-pencil grain, wobbling
graphite contours, muted earthy colors and rough white scissor-cut paper
borders. No reference character, costume, pose or composition was copied.

`military_codex_atlas_v1.png` is a lossless RGBA atlas with 8 columns
of 256px cells. Each cell keeps a transparent gutter and a normalised
232px artwork envelope so table icons and dossier headers share
the same optical weight.

The source sheets use a loose illustrated grid. The builder segments
each sheet from eroded icon cores and assigns complete connected
artwork back to its cell, so protruding weapons, smoke, roofs and
flags are not clipped by equal-grid slicing.

Source sheets live in `source/`; rebuild with:

```powershell
python tools/ui/build_military_codex_icons.py
```

| semantic | cell (x, y, w, h) |
| --- | --- |
| `military.army.attack` | 0, 1536, 256, 256 |
| `military.army.defense` | 256, 1536, 256, 256 |
| `military.army.morale` | 1024, 1280, 256, 256 |
| `military.army.organization` | 1280, 1280, 256, 256 |
| `military.army.pay` | 1536, 1280, 256, 256 |
| `military.army.supply` | 1792, 1280, 256, 256 |
| `military.building.academy` | 0, 1280, 256, 256 |
| `military.building.bunker` | 1792, 1024, 256, 256 |
| `military.building.depot` | 512, 1280, 256, 256 |
| `military.building.legion_fort` | 512, 1024, 256, 256 |
| `military.building.modern_base` | 768, 1024, 256, 256 |
| `military.building.palisade_barracks` | 256, 1024, 256, 256 |
| `military.building.rampart` | 1024, 1024, 256, 256 |
| `military.building.simulation_center` | 256, 1280, 256, 256 |
| `military.building.star_fort` | 1536, 1024, 256, 256 |
| `military.building.stone_wall` | 1280, 1024, 256, 256 |
| `military.building.training_ground` | 768, 1280, 256, 256 |
| `military.building.tribal_lodge` | 0, 1024, 256, 256 |
| `military.good.ammunition` | 0, 768, 256, 256 |
| `military.good.armored_vehicles` | 1536, 512, 256, 256 |
| `military.good.body_armor` | 1024, 512, 256, 256 |
| `military.good.drones` | 1792, 512, 256, 256 |
| `military.good.electronics` | 768, 768, 256, 256 |
| `military.good.firearms` | 512, 512, 256, 256 |
| `military.good.fuel` | 512, 768, 256, 256 |
| `military.good.melee_arms` | 0, 512, 256, 256 |
| `military.good.missile_arms` | 256, 512, 256, 256 |
| `military.good.mounts` | 1280, 512, 256, 256 |
| `military.good.ordnance` | 768, 512, 256, 256 |
| `military.good.propellant` | 256, 768, 256, 256 |
| `military.ledger.convoy` | 1792, 768, 256, 256 |
| `military.ledger.secure_convoy` | 1792, 1536, 256, 256 |
| `military.supply.equipment` | 1536, 768, 256, 256 |
| `military.supply.fodder` | 1280, 768, 256, 256 |
| `military.supply.ration` | 1024, 768, 256, 256 |
| `military.unit.archer` | 1024, 0, 256, 256 |
| `military.unit.cavalry` | 1280, 0, 256, 256 |
| `military.unit.chariot` | 1536, 0, 256, 256 |
| `military.unit.drone` | 1792, 256, 256, 256 |
| `military.unit.early_tank` | 1280, 256, 256, 256 |
| `military.unit.field_artillery` | 768, 256, 256, 256 |
| `military.unit.legionary` | 768, 0, 256, 256 |
| `military.unit.line_infantry` | 0, 256, 256, 256 |
| `military.unit.machine_gunner` | 512, 256, 256, 256 |
| `military.unit.militia` | 0, 0, 256, 256 |
| `military.unit.musketeer` | 1792, 0, 256, 256 |
| `military.unit.rifleman` | 256, 256, 256, 256 |
| `military.unit.shield_bearers` | 0, 1792, 256, 256 |
| `military.unit.siege_train` | 1024, 256, 256, 256 |
| `military.unit.spearmen` | 512, 0, 256, 256 |
| `military.unit.tank` | 1536, 256, 256, 256 |
| `military.unit.tribal` | 256, 0, 256, 256 |
| `military.war.battle` | 768, 1536, 256, 256 |
| `military.war.front` | 512, 1536, 256, 256 |
| `military.war.peace` | 1280, 1536, 256, 256 |
| `military.war.score` | 1024, 1536, 256, 256 |
| `military.war.truce` | 1536, 1536, 256, 256 |
