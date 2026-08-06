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

var _generator  # MapGenerator owner; retained for the facade context.

func _init(generator) -> void:
	_generator = generator

## Native result assembly boundary used by MapGenerator.generate().
func assemble_native_result(res: Dictionary, cfg: MapConfig) -> MapData:
	var n: int = int(res.get("n_cells", 0))
	if cfg == null or n <= 0 or n != int(cfg.width) * int(cfg.height):
		return null
	var required := {
		"q_arr": TYPE_PACKED_INT32_ARRAY,
		"r_arr": TYPE_PACKED_INT32_ARRAY,
		"elevation_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"base_moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"temp_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"terrain_arr": TYPE_PACKED_BYTE_ARRAY,
		"landform_arr": TYPE_PACKED_BYTE_ARRAY,
		"vegetation_arr": TYPE_PACKED_BYTE_ARRAY,
		"cover_arr": TYPE_PACKED_BYTE_ARRAY,
		"vegetation_vitality_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"soil_moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"water_balance_30d_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"plant_available_water_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_growth_pressure_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_heat_stress_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_drought_stress_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_cold_stress_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_regen_score_arr": TYPE_PACKED_FLOAT32_ARRAY,
	}
	for key in required.keys():
		if not native_generation_array_ok(res, key, n, int(required[key])):
			push_warning("[native_generation/assemble] bad array %s" % key)
			return null

	var q_arr: PackedInt32Array = res["q_arr"]
	var r_arr: PackedInt32Array = res["r_arr"]
	var elevation_arr: PackedFloat32Array = res["elevation_arr"]
	var moisture_arr: PackedFloat32Array = res["moisture_arr"]
	var base_moisture_arr: PackedFloat32Array = res["base_moisture_arr"]
	var temp_arr: PackedFloat32Array = res["temp_arr"]
	var temp_baseline_arr: PackedFloat32Array = res["temp_baseline_arr"] if res.has("temp_baseline_arr") else temp_arr
	var temp_30d_arr: PackedFloat32Array = res["temp_30d_arr"] if res.has("temp_30d_arr") else temp_arr
	var temp_365d_arr: PackedFloat32Array = res["temp_365d_arr"] if res.has("temp_365d_arr") else temp_arr
	var terrain_arr: PackedByteArray = res["terrain_arr"]
	var base_terrain_arr: PackedByteArray = res["base_terrain_arr"] if res.has("base_terrain_arr") else terrain_arr
	var landform_arr: PackedByteArray = res["landform_arr"]
	var base_landform_arr: PackedByteArray = res["base_landform_arr"] if res.has("base_landform_arr") else landform_arr
	var vegetation_arr: PackedByteArray = res["vegetation_arr"]
	var base_vegetation_arr: PackedByteArray = res["base_vegetation_arr"] if res.has("base_vegetation_arr") else vegetation_arr
	var cover_arr: PackedByteArray = res["cover_arr"]
	var has_river_arr: PackedByteArray = res["has_river_arr"] if res.has("has_river_arr") else PackedByteArray()
	var river_flow_arr: PackedFloat32Array = res["river_flow_arr"] if res.has("river_flow_arr") else PackedFloat32Array()
	var river_downstream_arr: PackedInt32Array = res["river_downstream_arr"] if res.has("river_downstream_arr") else PackedInt32Array()
	var hydro_parent_arr: PackedInt32Array = res["hydro_parent_arr"] if res.has("hydro_parent_arr") else PackedInt32Array()
	var has_volcano_arr: PackedByteArray = res["has_volcano_arr"] if res.has("has_volcano_arr") else PackedByteArray()
	var is_lake_seed_arr: PackedByteArray = res["is_lake_seed_arr"] if res.has("is_lake_seed_arr") else PackedByteArray()
	var water_depth_arr: PackedFloat32Array = res["water_depth_arr"] if res.has("water_depth_arr") else PackedFloat32Array()
	var map := MapData.new(cfg.width, cfg.height)
	for i in range(n):
		var cell := HexCell.new(int(q_arr[i]), int(r_arr[i]))
		cell.elevation = float(elevation_arr[i])
		cell.moisture = float(moisture_arr[i])
		cell.base_moisture = float(base_moisture_arr[i])
		cell.apply_terrain(int(terrain_arr[i]))
		cell.base_terrain = int(base_terrain_arr[i]) if base_terrain_arr.size() == n else int(terrain_arr[i])
		cell.landform = int(landform_arr[i])
		cell.base_landform = int(base_landform_arr[i]) if base_landform_arr.size() == n else int(landform_arr[i])
		cell.vegetation = int(vegetation_arr[i])
		cell.base_vegetation = int(base_vegetation_arr[i]) if base_vegetation_arr.size() == n else int(vegetation_arr[i])
		cell.cover = int(cover_arr[i])
		cell.has_river = has_river_arr.size() == n and int(has_river_arr[i]) != 0
		cell.river_flow = float(river_flow_arr[i]) if river_flow_arr.size() == n else (1.0 if cell.has_river else 0.0)
		if river_downstream_arr.size() == n:
			var downstream_idx: int = int(river_downstream_arr[i])
			if downstream_idx >= 0 and downstream_idx < n:
				cell.river_downstream = Vector3i(int(q_arr[downstream_idx]), int(r_arr[downstream_idx]), -int(q_arr[downstream_idx]) - int(r_arr[downstream_idx]))
				cell.has_river_downstream = true
		cell.has_volcano = has_volcano_arr.size() == n and int(has_volcano_arr[i]) != 0
		cell.is_lake_seed = is_lake_seed_arr.size() == n and int(is_lake_seed_arr[i]) != 0
		cell.water_depth = float(water_depth_arr[i]) if water_depth_arr.size() == n else 0.0
		cell._temperature_backing = float(temp_arr[i])
		cell._temp_baseline_backing = float(temp_baseline_arr[i])
		cell._temp_30d_mean_backing = float(temp_30d_arr[i])
		cell._temp_365d_mean_backing = float(temp_365d_arr[i])
		cell._temp_dev_from_annual_backing = 0.0
		cell._ema_initialized = true
		cell.current_state = {
			"season": 1,
			"temperature": float(temp_arr[i]),
			"moisture": cell.base_moisture,
			"snow_cover": 0.0,
			"biome": int(cell.terrain),
			"landform": int(cell.landform),
			"vegetation": int(cell.vegetation),
			"cover": int(cell.cover),
			"weather": int(WeatherType.WT.CLEAR),
			"weather_intensity": 0.0,
		}
		map.set_cell(cell)
	map.set_pending_generation_ecology({
		"vegetation_vitality_arr": res["vegetation_vitality_arr"],
		"soil_moisture_arr": res["soil_moisture_arr"],
		"water_balance_30d_arr": res["water_balance_30d_arr"],
		"plant_available_water_arr": res["plant_available_water_arr"],
		"vegetation_growth_pressure_arr": res["vegetation_growth_pressure_arr"],
		"vegetation_heat_stress_arr": res["vegetation_heat_stress_arr"],
		"vegetation_drought_stress_arr": res["vegetation_drought_stress_arr"],
		"vegetation_cold_stress_arr": res["vegetation_cold_stress_arr"],
		"vegetation_regen_score_arr": res["vegetation_regen_score_arr"],
	})
	if hydro_parent_arr.size() == n:
		map.hydro_parent_arr = hydro_parent_arr.duplicate()
	return map


static func native_generation_array_ok(res: Dictionary, key: String, n: int, type_id: int) -> bool:
	var value = res.get(key, null)
	return typeof(value) == type_id and value.size() == n

func describe() -> String:
	return "DCTerrainGenerator(generator=%s)" % ("present" if _generator != null else "(null)")
