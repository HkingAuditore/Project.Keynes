---
name: authored-map-authoring
description: >
  Project.Keynes 作者地图写作 skill。当用户要 AI 当地图作者、写 generate(ctx)、做自定义大陆/岛屿/
  河湖/干湿/山地、产出 PKAUTH 或 PKMAP、说「画一张图」「两个大陆」「内陆海」「作者脚本」
  「不要走 seed 程序生成」时，必须用本 skill。只写受限 Python 软目标（海拔/湿度/hints），
  禁止写最终 has_river、terrain 枚举、vegetation、landform、生物占领或资源储量。
  改 C++ 生成器 / bake / post_base 内核时不要用本 skill，改用 map-generation-pipeline。
---

# 作者地图（给写图的 AI）

你是地图作者，不是引擎作者。交付物是一份能通过沙箱的 `generate(ctx)` 脚本，再编译成 PKMAP。
河网、湖泊枚举、植被、地貌由 headless Godot 里同一份 `dots_ext.dll` 的 `post_base` 闭合。
第一期不保证格子级命中「这里必须是森林」。

权威短文：`Project.Keynes/tools/map_authoring/README.md`。
管线说明：`Project.Keynes/docs/cpp-dots-runtime/authored-map-pipeline.md`。
合格样例：`Project.Keynes/tools/map_authoring/examples/two_continents.py`。

开始前先读 README 和 `two_continents.py`，不要凭地球记忆直接赋 FOREST。

## 工作流

1. 向用户确认或取默认：`width=60` `height=40` `seed=1` `sea_level=0.50`。
2. 把自然语言译成软目标：陆块位置用圆柱距离；干湿用 `moisture_paint`；山地用 `highland_paint`；河用有出海口的路径下切；湖用 ≥8 格封闭盆。
3. 在 `Project.Keynes/tools/map_authoring/` 下写脚本（新图用 `examples/` 或用户指定路径）。文件顶层只有 `def generate(ctx):`，不要 `import`。
4. 先 `--auth-only` 编译 PKAUTH。失败则按失败码改脚本，不要改编译器。
5. 通过后再编 PKMAP。告诉用户用 `pkmap=绝对路径` 或 world_setup「PKMAP 路径」加载。不要改主菜单，不要写进 PKSV。

仓库根目录命令：

```text
python tools/map_authoring/compile.py <script.py> --width 60 --height 40 --seed 1 --sea-level 0.50 --auth-only --auth tmp/map.pkauth

python tools/map_authoring/compile.py <script.py> --width 60 --height 40 --seed 1 --sea-level 0.50 --out tmp/map.pkmap
```

禁止 `ctypes` / `LoadLibrary` `dots_ext.dll`。`GODOT_EXE` 指向 Godot 4.6.2 console。

## 坐标系

与 C++ `index_for_qr` 一致：

- `index = row * width + col`
- `q = col - ((row - (row & 1)) / 2)`，`r = row`
- `row=0` 北极，`row=height-1` 南极
- 东西环绕、南北硬边
- `elevation ∈ [0,1]`，`< sea_level` 为海
- `nx = col/width`，`ny = row/(height-1)`
- 噪声必须圆柱：内部已是 `(cos(2π·col/width), sin(2π·col/width), ny)`。用 `ctx.fbm` / `ctx.ridged` / `ctx.cyl_dist`，不要按笛卡尔 `col` 做普通 2D 噪声

把「欧洲」画在第 0 行等于画在北极。温带陆块放在 `ny ≈ 0.35–0.65`。

## `generate(ctx)` 契约

```python
def generate(ctx):
    n = ctx.width * ctx.height
    elevation = [0.0] * n
    # ... 填海拔 ...
    return {
        "elevation": elevation,          # 必填，长度 n
        "sea_level": ctx.sea_level,
        "hints": {
            "carve_rivers": [{"cells": [[col, row], ...], "depth": 0.04, "width": 1}],
            "lake_basins": [{"cells": [[col, row], ...], "depth": 0.08}],
            "moisture_paint": {"values": [...], "mix": 0.5},
            "highland_paint": {"values": [...], "mix": 0.4},
        },
    }
```

`ctx` 仅有：`width` `height` `seed` `sea_level`，`index(col,row)`，`nx` `ny`，`cells()` 产出 `(row, col, index)`，`fbm` `ridged`，`clamp` `lerp` `smoothstep`，`cyl_dist(nx0,ny0,nx1,ny1)`。

沙箱：无 `import` / `open` / `eval` / `exec`；约 5 秒超时。可用 `abs min max range len float int list dict enumerate zip round sum`。

## 软目标怎么表达

| 玩家意图 | 作者层做法 |
|---|---|
| 两块大陆隔海 | 两个 `cyl_dist` 团块，缝在 `nx≈0` 处留海，避免包住经度 0 |
| 群岛 | 多个小半径团块 + 较弱 `fbm`，控制陆地比例仍 ≥0.18 |
| 内陆湖 | `lake_basins` 至少 8 格，落在陆地上；不要写 `terrain=LAKE` |
| 大河入海 | `carve_rivers` 路径从内陆走到海边或海里；最后一格须邻海 |
| 湿润/干旱 | `moisture_paint` 与默认距海湿度 mix；温度交给 post_base |
| 山脉/平原 | `highland_paint` 抬升陆地海拔；不要写 `LF.MOUNTAIN` |
| 森林/沙漠 | 只调湿度和纬度带；不要写 `vegetation=` |

河路径下切后仍须 `>= sea_level`。无出海口会报 `river_no_outlet`，不会静默成湖。
湖阈值对齐 post_base 默认：深度 0.018、至少 8 格、体积 0.22。

陆地比例建议 **0.18–0.72**。东西接缝：`col=0` 与 `col=width-1` 海拔差不能像悬崖；圆柱噪声 + `cyl_dist` 通常自然接上。

## 禁止写

`has_river`、最终 `terrain=`、`vegetation=`、`landform=`、`bio_occupancy_bits`、资源储量数组。
多写的键会被忽略，但不要假装它们生效。

反例（不要抄逻辑）：

- `examples/bad_europe_on_row0.py` — 陆地画在北极
- `examples/bad_no_wrap.py` — 东西悬崖
- `examples/bad_direct_forest.py` — 直接赋 FOREST

## 失败码

| 码 | 改什么 |
|---|---|
| `sandbox_forbidden` | 去掉 import/open/eval |
| `sandbox_timeout` | 少算；`fbm` octaves≤4；不要三重循环搜全图 |
| `size_mismatch` | `elevation` 长度必须是 `width*height` |
| `nan_elevation` | 不要除零；`clamp` 所有场 |
| `land_ratio_out_of_range` | 加大/缩小团块或调整相对 `sea_level` 的底座海拔 |
| `wrap_seam_cliff` | 用 `cyl_dist`/`fbm`，不要按 `col < width/2` 切两半 |
| `river_no_outlet` | 把路径延伸到海洋邻格；最后几格应在陆海边界 |
| `lake_too_small` | 湖盆格子 ≥8 |
| `headless_compile_failed` | 先看 Godot 日志；C++ 改过则先 `gdext/rebuild.bat` |

## 交付时告诉用户

- 脚本路径、width/height/seed/sea_level
- PKAUTH / PKMAP 路径
- 加载：命令行 `pkmap=...` 或 world_setup 的 PKMAP 路径；失败会硬中止，不会回退程序生成
- 资源与生物仍在游戏读包后由现有 bootstrap 生成
