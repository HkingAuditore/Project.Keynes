extends RefCounted
class_name DCTerrainGenerator

## Phase G.1 / dots-full-migration §G.1：map_generator.gd 一次性烘焙逻辑抽出。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`map_generator.gd`](../map_generator.gd) 待按下方"逐函数搬迁清单"移过来。
##
## ─── 逐函数搬迁清单（按 generate(cfg, hex_size) 调用顺序）────────────────
##
## 主入口（map_generator.gd line 539）：
##   `generate(cfg, hex_size) -> Dictionary` 返回 { "map": MapData, "world_data": WorldData, "seed": int }
##
## 一次性烘焙阶段（按 generate 内调用顺序，不再变化的静态字段）：
##
## 1. 大陆 + 海平面：
##   - `_apply_continent_warp(...)` — 大陆 noise warp
##   - `_compute_elevation(nx, ny, _cfg) -> float` — line 1337，海拔合成（噪声 + 大陆 + meso）
##   - `_apply_ridge_boost(...)` — 山脉脊线
##   - `_compute_meso_terrain(...)` — 中尺度地形细节
##   - `_compute_offshore_blend(...)` — 远海岛屿
##   - `_apply_edge_falloff(...)` — 地图边缘衰减
##
## 2. 河流 + 湖泊：
##   - `_carve_rivers(...)` — 河网雕刻
##   - `_pit_fill(...)` — 凹陷填平
##   - `_seed_lakes(...)` — 湖泊种子
##   - `_compute_river_chains(...)` — 河流链拓扑
##   - `_hydraulic_erosion(...)` — 水力侵蚀（如有，搜 hydraulic）
##
## 3. 风场（地形扰动后的稳态 wind_vector）：
##   - `_compute_terrain_perturbed_wind(map)` — line 2720（写 cell.wind_vector）
##   - `_bake_lat_lookup(...)` — 纬度 LUT
##
## 4. Biome 决策（一次性 + 季节切换共用 helper）：
##   - `_decide_biome_for_cell(cell, ...)` — biome 综合决策
##   - `_classify_landform(cell)` — landform 分类
##   - `_decide_vegetation(cell, ...)` — 植被分类
##   - `_apply_rain_shadow(...)` — 雨影
##   - `_apply_river_ecology(...)` — 河岸生态绿带
##
## ─── 注意事项 ────────────────────────────────────────────────────
##
## 1. **generation 阶段无 DCWorld**（DCWorld.bind_map_data 在 generate 之后才调）；
##    本 phase 仅做拆分，cell.<field> = ... 写法暂时保留（不需要 ViewAdapter / world.write_*）；
## 2. 生成期是冷路径（每 regenerate 调一次），不在 hot loop 性能优化范围内，
##    所以本类**不会**做 C++ 化（不在 charter §7 表里）；
## 3. 拆分后 generator 的 SUS 注册（_setup_sus, line ~700-800）保留在 map_generator.gd
##    残留中——它依赖 generator 实例字段，不能简单搬到本类。
##
## ─── 拆完后 ─────────────────────────────────────────────────────────
##
## - terrain_gen.gd ~1500 行（最大拆出文件，与 plan §4.2 估算一致）
## - map_generator.gd 减少 ~1500 行 generation 部分；剩余 ~1000 行（runtime sub-pass
##   + SUS 协调 + diagnostics 转发）；E.6 + 后续 PR 进一步压缩到 ≤ 250 行

var _generator  # MapGenerator owner（为 facade 期保留 caller 路径）

func _init(generator) -> void:
	_generator = generator

## 主入口：generate（搬迁后填实现）。
## 当前 stub；G.1 后由 main.gd 或 generator 切换为调用本方法。
func generate(_cfg: MapConfig, _hex_size: float) -> Dictionary:
	push_warning("[DCTerrainGenerator] generate stub — call MapGenerator.generate directly until G.1 actual extraction")
	return {}

func describe() -> String:
	return "DCTerrainGenerator(generator=%s)" % ("present" if _generator != null else "(null)")
