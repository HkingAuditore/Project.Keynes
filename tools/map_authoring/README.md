# 作者地图语言（给 AI 整份贴进上下文）

受限 Python，不是新语法。权威河湖/植被/地貌在 **headless Godot 加载的同一份 `dots_ext.dll`** 里跑 `run_native_world_generate_post_base_pass`。本目录只写软目标：海拔、湿度、河谷下切、湖盆、高地 paint。

## 命令

```text
python tools/map_authoring/compile.py tools/map_authoring/examples/two_continents.py --width 60 --height 40 --seed 1 --sea-level 0.50 --out tmp/two_continents.pkmap
```

只要 PKAUTH（在 `Project.Keynes` 根目录）：

```text
python tools/map_authoring/compile.py tools/map_authoring/examples/two_continents.py --auth-only --auth tmp/map.pkauth
```

改过 C++ 后必须先 `gdext/rebuild.bat`，与玩游戏同一纪律。禁止 `ctypes` 直接 LoadLibrary `dots_ext.dll`。

环境变量 `GODOT_EXE` 指向 `Godot_v4.6.2-stable_win64_console.exe`。缺省回退 headless-perf 常用路径。

产品里从主菜单新游戏选择「作者地图」，浏览该 `.pkmap`，或把文件放到 Godot 用户目录的 `maps/`（`user://maps`）后用下拉选取。读档仍绑定这份文件路径，不把 PKMAP 打进 PKSV。

## 脚本契约

```python
def generate(ctx) -> dict:
    return {
        "elevation": [...],          # 必填，长度 width*height
        "sea_level": 0.50,
        "hints": {
            "carve_rivers": [{"cells": [[c, r], ...], "depth": 0.04, "width": 1}],
            "lake_basins": [{"cells": [[c, r], ...], "depth": 0.08}],
            "moisture_paint": {"values": [...], "mix": 0.5},
            "highland_paint": {"values": [...], "mix": 0.4},
        },
    }
```

`ctx` 白名单：`width` `height` `seed` `sea_level`、`index(col,row)`、`nx(col)` `ny(row)`、`cells()`、`fbm` `ridged`、`clamp` `lerp` `smoothstep`、`cyl_dist`。

沙箱：无 `import` / `open` / `eval`；5 秒超时。

## 坐标系（与 C++ `index_for_qr` 一致）

- `index = row * width + col`
- `q = col - ((row - (row & 1)) / 2)`，`r = row`
- `row=0` 北极，`row=height-1` 南极
- 东西环绕、南北硬边
- `elevation ∈ [0,1]`，`< sea_level` 为海
- 噪声必须圆柱采样：`(cos(2π·col/width), sin(2π·col/width), ny)`

## 禁止作者写

`has_river`、最终 `terrain=` 枚举、`vegetation=`、`landform=`、`bio_occupancy_bits`、资源储量。

植被/地貌/资源/生物通过湿度、海拔、陆块形状间接达到。第一期不保证格子级命中。

## 失败码

`size_mismatch` `nan_elevation` `land_ratio_out_of_range`（0.18–0.72）`wrap_seam_cliff` `river_no_outlet` `sandbox_forbidden` `sandbox_timeout`

河路径必须有出海口；无出口不要指望静默成湖。湖盆至少 8 格，深度/体积对齐 post_base 默认 `0.018 / 8 / 0.22`。

## 不合格示例

- `examples/bad_europe_on_row0.py`：把陆地画在第 0 行（北极）
- `examples/bad_no_wrap.py`：东西不接缝
- `examples/bad_direct_forest.py`：直接赋 FOREST

合格示例：`examples/two_continents.py`。

Cursor skill（给写图的 AI 自动加载）：`authored-map-authoring`。
