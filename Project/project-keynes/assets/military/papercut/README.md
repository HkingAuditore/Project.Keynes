# Military papercut sticker atlas v1

The military UI uses five dedicated source atlases generated in the same
colored-pencil, graphite and scissor-cut paper language as the general UI
icons. Sources live under `source/`; `source-manifest.json` records their
semantic order, detected source-cell bounds and generation style summary.

`tools/ui/build_military_papercut.py` locates each sticker from transparent
gutters instead of assuming an equal-pixel grid. It then fits the complete
sticker into a runtime cell with a fine pencil outline and soft contact
shadow. This prevents source art from being clipped at nominal cell edges.

`military_atlas_v1.png` is lossless RGBA, 8 columns of 320px cells.
Each sticker is bound by an `AtlasTexture` at `assets/military/<key>.tres`
and referenced through `IconCatalog`.

| key | cell (x, y, w, h) |
| --- | --- |
| `military.army.attack` | 0, 0, 320, 320 |
| `military.army.defense` | 320, 0, 320, 320 |
| `military.army.morale` | 640, 0, 320, 320 |
| `military.army.organization` | 960, 0, 320, 320 |
| `military.army.pay` | 1280, 0, 320, 320 |
| `military.army.supply` | 1600, 0, 320, 320 |
| `military.building.barracks` | 1920, 0, 320, 320 |
| `military.building.fortification` | 2240, 0, 320, 320 |
| `military.building.storage` | 0, 320, 320, 320 |
| `military.building.war_college` | 320, 320, 320, 320 |
| `military.good.ammunition` | 640, 320, 320, 320 |
| `military.good.armor` | 960, 320, 320, 320 |
| `military.good.bows` | 1280, 320, 320, 320 |
| `military.good.electronics` | 1600, 320, 320, 320 |
| `military.good.firearms` | 1920, 320, 320, 320 |
| `military.good.fuel` | 2240, 320, 320, 320 |
| `military.good.ordnance` | 0, 640, 320, 320 |
| `military.good.propellant` | 320, 640, 320, 320 |
| `military.ledger.convoy` | 640, 640, 320, 320 |
| `military.ledger.income` | 960, 640, 320, 320 |
| `military.ledger.wage` | 1280, 640, 320, 320 |
| `military.plan.barracks` | 1600, 640, 320, 320 |
| `military.plan.quality` | 1920, 640, 320, 320 |
| `military.plan.share` | 2240, 640, 320, 320 |
| `military.plan.target` | 0, 960, 320, 320 |
| `military.plan.training` | 320, 960, 320, 320 |
| `military.supply.equipment` | 640, 960, 320, 320 |
| `military.supply.fodder` | 960, 960, 320, 320 |
| `military.supply.ration` | 1280, 960, 320, 320 |
| `military.unit.air` | 1600, 960, 320, 320 |
| `military.unit.armored` | 1920, 960, 320, 320 |
| `military.unit.artillery` | 2240, 960, 320, 320 |
| `military.unit.line` | 0, 1280, 320, 320 |
| `military.unit.line.bows` | 320, 1280, 320, 320 |
| `military.unit.militia` | 640, 1280, 320, 320 |
| `military.unit.mobile` | 960, 1280, 320, 320 |
| `military.war.battle` | 1280, 1280, 320, 320 |
| `military.war.front` | 1600, 1280, 320, 320 |
| `military.war.peace` | 1920, 1280, 320, 320 |
| `military.war.score` | 2240, 1280, 320, 320 |
| `military.war.truce` | 0, 1600, 320, 320 |
