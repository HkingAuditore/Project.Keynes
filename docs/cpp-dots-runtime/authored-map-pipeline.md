# 作者地图外部编译管线

第一期：作者脚本 → PKAUTH → headless Godot + 同一份 `dots_ext.dll` 的 `post_base` → PKMAP → `MapGenerator.generate()` 旁路读取。产品入口是主菜单新游戏「作者地图」；`world_setup.tscn` 与命令行 `pkmap=` 仍是开发入口。PKSV 持久化 `NewGameConfig.base.pkmap_path`，不内嵌 PKMAP 字节。资源与生物占领在读包后仍走 `_bootstrap_natural_resource_deposits` / `_seed_bio_occupancy`。

禁止用 CPython `ctypes` 直接 `LoadLibrary` `dots_ext.dll`（GDExtension 依赖 ClassDB / Variant / `FastNoiseLite`）。

## 流水线

```text
author.py
  → Python 沙箱 generate(ctx)
  → HintRasterizer（河谷 / 湖盆 / 湿度 / 高地）
  → PKAUTH
  → Godot --headless tests/compile_authored_map.gd
  → run_native_world_generate_post_base_pass
  → PKMAP
  → MapGenerator._generate_cells_from_pkmap
       assemble_native_result + restuff_generation_river_cache
  → 既有 bake / 资源 / 生物 / 选点
```

科学约束：河湖由高程排水面决定（post_base Priority-Flood）；植被/地貌由温湿+海拔闭合。作者层只写软目标，不写最终 `has_river` / `VEG` / `bio_occupancy` / 储量。

## 坐标系

与 C++ `DCWorldExt::index_for_qr` 一致：

- `index = row * width + col`
- `q = col - ((row - (row & 1)) / 2)`，`r = row`
- `row=0` 北极，`row=height-1` 南极
- 东西环绕、南北硬边
- `elevation ∈ [0,1]`，`< sea_level` 为海
- 噪声必须圆柱采样：`(cos(2π·col/width), sin(2π·col/width), ny)`

## 作者语言

文档与 SDK：[`tools/map_authoring/README.md`](../../tools/map_authoring/README.md)。语言就是受限 Python。

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

`ctx` 白名单：`width/height/seed/sea_level`、`index`、`nx/ny`、`cells()`、`fbm/ridged`、`clamp/lerp/smoothstep`、`cyl_dist`。沙箱禁 `import`/`open`/`eval`，multiprocessing 超时 5s。

禁止作者写：`has_river`、最终 `terrain=` 枚举、`vegetation=`、`landform=`、`bio_occupancy_bits`、资源储量。biome/植被/资源/生物通过湿度、海拔、陆块形状间接达到；第一期不保证格子级命中。

## Hints

与 post_base 湖阈值对齐（`hydro_lake_min_depth/cells/volume` 默认 0.018 / 8 / 0.22）：

1. 河：沿 hex 路径 V 形下切，须有出海口且下切后仍 `>= sea_level`。无出口 → `river_no_outlet`，不静默成湖。
2. 湖：封闭格集下切到能过最小面积/深度；写入 `is_lake_seed` 传给 post_base。不盖 `LAKE` 枚举。
3. 湿度：缺省 = 距海地板 + 纬度带；有 paint 则 mix。温度不写，post_base 按纬度+海拔补。
4. 高地 paint：对陆地海拔做有界抬升/削平，让“大致山地/平原”进入地貌判定，而不是写 `LF.MOUNTAIN`。
5. terrain 初值（headless 编译）：`E < sea_level → OCEAN`，其余 `PLAIN`。不要把邻海陆地标成 `COAST`：引擎里 `COAST` 是浅海（`is_water`），`post_base` 不会把水格重判回陆地。

失败码：`size_mismatch`、`nan_elevation`、`land_ratio_out_of_range`（0.18–0.72）、`wrap_seam_cliff`、`river_no_outlet`。

## PKAUTH v1

`PKAU` magic + `format_version` u32 + JSON 头 + 小端 `float32` 海拔/湿度 + `uint8` `is_lake_seed`。头含 `width/height/sea_level/seed/n_cells`。

## Headless 编译

```text
godot --headless --path Project/project-keynes --script res://tests/compile_authored_map.gd -- \
  auth=.../map.pkauth out=.../map.pkmap
```

Python 包装：

```text
python tools/map_authoring/compile.py tools/map_authoring/examples/two_continents.py --out tmp/map.pkmap
```

步骤：读 PKAUTH → odd-r 填 `q_arr/r_arr` → `ClassDB.instantiate("DCWorldExt")`（不 `bind_map_data`）→ 默认 `earth_like` ClimateProfile 的 cfg/profile → `run_native_world_generate_post_base_pass`；`rc!=0` 或 `fallback` 则非零退出。不装配 HexCell、不 bake。

改 C++ 后必须先 `gdext/rebuild.bat`。`GODOT_EXE` 指向 Godot 4.6.2 console 可执行文件。

## PKMAP v1

`PKMP` magic + `format_version` + JSON 头 + ZSTD section（`var_to_bytes` 的 PackedArray Dictionary）。头含 `width/height/sea_level/seed/n_cells`、`generator_hash`（`SaveRepository.compatibility_hash()`）、`content_hash`（未压缩 payload SHA256）。payload 即 `assemble_native_result` 所需数组 + `has_river_arr/river_flow_arr/river_downstream_arr/hydro_parent_arr`。邻居表不存，加载时按 `index_for_qr` 重建。

## 游戏读取旁路

`MapConfig.map_source=pkmap` 且 `pkmap_path` 指向文件时，`_generate_cells_native_base` 跳过 `run_native_world_generate_full_pass`，读包 → 校验 hash/尺寸 → `assemble_native_result` → `DCWorldExt.restuff_generation_river_cache`（填 `_gen_river_*`，否则 bake 河 SDF 无河）。失败 `push_error` **硬中止**，不回退程序生成。报告 `path=pkmap`。

产品入口：主菜单新游戏选择「作者地图」，浏览或从 `user://maps/*.pkmap` 选取文件。`NewGameConfig.validate()` peek 头、核对 `generator_hash`，并把宽高/海平面/种子写入 `base`；`GameFlow.begin_new_game` 把完整配置交给 `WorldRuntimeHost._apply_pkmap_override`。读档再次走同一旁路，文件缺失或不兼容则失败。

开发入口：命令行 `pkmap=C:/path/map.pkmap`（`OS.get_cmdline_user_args()`），或 world_setup 的 PKMAP 路径字段。

## 明确不做（第一期）

- PKSV 内嵌静态度图字节（读档绑定原 `.pkmap` 路径，不按 seed 重生水文）
- Python 重写水文/植被/资源/生物；ctypes 调 DLL
- 作者脚本指定最终河网、植被枚举、储量、物种 bitset
- 图像导入

## AI 提示词模板

优先加载 Cursor skill `authored-map-authoring`。若在无 skill 的会话里，把 [`tools/map_authoring/README.md`](../../tools/map_authoring/README.md) 整份贴进上下文，要求只实现 `generate(ctx)`，使用圆柱噪声，陆地不要画在第 0 行，东西必须接缝，河流必须有出海口，不要写 `vegetation=` / `has_river`。
