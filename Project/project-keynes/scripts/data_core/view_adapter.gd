extends RefCounted
class_name DCViewAdapter

## DataCore — Read-Side ViewAdapter（B2 / dots-migration-roadmap §3）。
##
## 设计目标：让 renderer / UI / baker / debug 等"只读消费者"通过本 adapter
## 访问 cell 字段，**不直接读 cell.<field> 也不直接读 map.<field>_arr[idx]**。
## 数据侧后续 DOTS 化（阶段 II 砍 flush_soa_to_cells、HexCell 改只读 facade
## 等）只需切换 adapter 实现，**消费端一行不用动**。
##
## 双实现：
##   - DCViewAdapter.Cell  — 默认（legacy 兼容）：直接读 HexCell 强类型成员
##   - DCViewAdapter.World — DOTS：通过 DCWorld.view_f32/view_u8 一次性取
##                          PackedArray 引用，hot path 索引零跨界开销
##
## 约定：
##   - 所有 getter 入参是 cell.index（HexCell.index 由 MapData._build_indices
##     注入；DCWorld 所有 cell-level component 的 idx 也是 cell.index）；
##   - getter 是冷路径 helper，单次调用 ~50ns；hot loop 应该一次性拿底层
##     PackedArray（直接调 world.view_f32(cid) 或缓存到 system 字段），
##     不要在 hot loop 里反复走 adapter；
##   - getter 返回值与 component_schema.gd 中对应字段的 dtype 严格对齐
##     （F32 → float, U8 → int / bool, Vector2 拆轴 → 两个 float getter）；
##   - 非 schema 字段（temperature_breakdown / accumulated_snow_days /
##     biome_history / vegetation_vitality / slp / wind_speed 等 HexCell-only
##     字段）**不进 adapter**——它们没有 DOTS 对位，调用方继续直接读 cell.*。
##
## 性能：
##   - Cell 实现：每 getter 1 次数组索引 + 1 次属性读，~30ns
##   - World 实现：每 getter 1 次属性读 + 1 次数组索引，~50ns（每次重新从
##     MapData 拿当前 PackedArray 引用，避免 CoW 解耦后缓存陈旧的问题）
##
## hot-loop 纪律（与 performance-charter §4 对齐）：
##   ❌ for i in range(n): adapter.get_temp(i)             # 走 facade 一次有调用开销
##   ✅ var temp_arr := world.view_f32(world.component_id(&"cell.temp"))
##     for i in range(n): temp_arr[i]                      # 直接走 PackedArray
##
## 使用示例（baker / UI 等冷路径）：
##   var adapter: DCViewAdapter = DCViewAdapter.Cell.new(map.iter_cells())
##   for cell in selected_cells:
##       label.text = "T=%.2f" % adapter.get_temp(cell.index)
##
## ─── World 实现的 SoA 真值源（2026-05-14）────────────────────────────────
##
## 历史 W.1 实现一次性 setup() 把 world.view_f32(cid) 缓存到 _v_temp 等字段，
## 但 GDExtension ABI 的 CoW 行为（charter §11）导致 C++ ptrw() 写后 slot 与
## adapter 缓存的 view 解耦，UI 永远显示生成期 baseline（"极寒 bug"）。
## 当前实现改为**不缓存 view**，每次 getter 直接从 _map_data.<map_field>
## 读 PackedArray —— map.<field> 是 GDScript MapData 上的 var，一旦 GDScript
## 写或 C++ _flush_slot_to_map 推回，引用会立刻反映最新 buffer。
## 这是 SoA 真值源的最直接读法；不依赖 round 末 flush_soa_to_cells，也不
## 依赖 DCWorld slot 与 map.<field> 是否仍 alias。


# ─── 抽象基类 ─────────────────────────────────────────────────────────────
# 所有 getter 默认返回零值。子类重写实际 getter；未重写的方法返回 0/false
# 让冷路径不会 crash 即可，warning 在 setup 时打。

# ─── Climate scalar (F32) ────────────────────────────────────────────────
func get_temp(_idx: int) -> float: return 0.0
func get_moisture(_idx: int) -> float: return 0.0
func get_snow_cover(_idx: int) -> float: return 0.0
func get_sea_ice_frac(_idx: int) -> float: return 0.0
func get_temp_baseline(_idx: int) -> float: return 0.0
func get_temp_30d(_idx: int) -> float: return 0.0
func get_temp_365d(_idx: int) -> float: return 0.0
func get_temp_anomaly(_idx: int) -> float: return 0.0
func get_temp_baseline_year(_idx: int) -> float: return 0.0
func get_temp_season_offset(_idx: int) -> float: return 0.0
func get_air_mass_temp_anomaly(_idx: int) -> float: return 0.0

# ─── Weather scalar (F32) ────────────────────────────────────────────────
func get_weather_intensity(_idx: int) -> float: return 0.0
func get_weather_cloud(_idx: int) -> float: return 0.0
func get_weather_cloud_water(_idx: int) -> float: return 0.0
func get_weather_precip(_idx: int) -> float: return 0.0
func get_weather_vapor(_idx: int) -> float: return 0.0
func get_weather_convergence(_idx: int) -> float: return 0.0
func get_weather_instability(_idx: int) -> float: return 0.0
func get_weather_transition_alpha(_idx: int) -> float: return 0.0
func get_vegetation_heat_stress(_idx: int) -> float: return 0.0
func get_vegetation_drought_stress(_idx: int) -> float: return 0.0
func get_vegetation_cold_stress(_idx: int) -> float: return 0.0
func get_vegetation_regen_score(_idx: int) -> float: return 0.0

# ─── Static / topology (F32) ─────────────────────────────────────────────
func get_elevation(_idx: int) -> float: return 0.0
func get_base_moisture(_idx: int) -> float: return 0.0
func get_pos_x(_idx: int) -> float: return 0.0
func get_pos_y(_idx: int) -> float: return 0.0
func get_lat_norm(_idx: int) -> float: return 0.0
func get_ocean_current_x(_idx: int) -> float: return 0.0
func get_ocean_current_y(_idx: int) -> float: return 0.0
func get_wind_x(_idx: int) -> float: return 0.0
func get_wind_y(_idx: int) -> float: return 0.0
func get_slp(_idx: int) -> float: return 0.0
func get_wind_speed(_idx: int) -> float: return 0.0
func get_upwelling_strength(_idx: int) -> float: return 0.0
func get_wind_stress_curl(_idx: int) -> float: return 0.0
func get_ocean_psi(_idx: int) -> float: return 0.0

# ─── Discrete enums (U8) ─────────────────────────────────────────────────
func get_terrain(_idx: int) -> int: return 0
func get_landform(_idx: int) -> int: return 0
func get_vegetation(_idx: int) -> int: return 0
func get_cover(_idx: int) -> int: return 0
func get_weather_type(_idx: int) -> int: return 0
func get_weather_prev_type(_idx: int) -> int: return 0
func get_weather_target_type(_idx: int) -> int: return 0

# ─── Boolean (U8) ────────────────────────────────────────────────────────
func get_is_water(_idx: int) -> bool: return false
func get_has_river(_idx: int) -> bool: return false
func get_weather_field_init(_idx: int) -> bool: return false
func get_ema_initialized(_idx: int) -> bool: return false

# ─── Composite helpers (常用便捷形式) ─────────────────────────────────────
## Vector2 形式：把 ocean_current_x/y 合成一个 Vector2，给原本读
## cell.ocean_current 的代码做 1:1 替换。
func get_ocean_current(idx: int) -> Vector2:
	return Vector2(get_ocean_current_x(idx), get_ocean_current_y(idx))

## Vector2 形式：把 wind_x/y 合成一个 Vector2，给原本读 cell.wind_vector
## 的代码做 1:1 替换。
func get_wind_vector(idx: int) -> Vector2:
	return Vector2(get_wind_x(idx), get_wind_y(idx))

## Vector2 形式：cell 屏幕坐标（unit hex_size=1.0；调用方乘 hex_size 即得真实坐标）。
func get_pos(idx: int) -> Vector2:
	return Vector2(get_pos_x(idx), get_pos_y(idx))


## 适配实现的简短描述（debug log 用）。子类重写。
func describe() -> String:
	return "DCViewAdapter[abstract]"


# ─── 实现 1：Cell（默认，legacy 兼容）─────────────────────────────────────
#
# 直接读 HexCell 强类型成员；与未引入 ViewAdapter 之前的代码行为完全等价。
# 用途：阶段 0/I 中所有现有调用点机械替换 `cell.<field>` →
# `adapter.get_<field>(cell.index)` 时使用，bit-equal 验收。
class Cell extends DCViewAdapter:
	# Array[HexCell] —— 由 MapData.iter_cells() 提供（顺序与 cell.index 一致）。
	# 不持强引用 MapData 本身，仅保留 cell 数组 ref；regenerate 时由调用方
	# 重新构造 adapter。
	var _cells: Array

	func _init(cells: Array) -> void:
		_cells = cells

	func describe() -> String:
		return "DCViewAdapter.Cell(n=%d)" % _cells.size()

	# Climate scalar
	func get_temp(idx: int) -> float: return float(_cells[idx].temperature)
	func get_moisture(idx: int) -> float: return float(_cells[idx].moisture)
	func get_snow_cover(idx: int) -> float: return float(_cells[idx].snow_cover)
	func get_sea_ice_frac(idx: int) -> float: return float(_cells[idx].sea_ice_fraction)
	func get_temp_baseline(idx: int) -> float: return float(_cells[idx].temp_baseline)
	func get_temp_30d(idx: int) -> float: return float(_cells[idx].temp_30d_mean)
	func get_temp_365d(idx: int) -> float: return float(_cells[idx].temp_365d_mean)
	func get_temp_anomaly(idx: int) -> float: return float(_cells[idx].temp_dev_from_annual)
	func get_temp_baseline_year(_idx: int) -> float:
		# HexCell 没有这个强类型字段（lat-baseline 是 MapData.temp_baseline_year_arr 独有）；
		# Cell adapter 在没有 MapData 引用时直接返回 0。调用方若需要这个
		# 字段，应改用 World adapter 或同时持 map ref（见 CellWithMap 子类的 TODO）。
		return 0.0
	func get_temp_season_offset(idx: int) -> float: return float(_cells[idx].temp_season_offset)
	func get_air_mass_temp_anomaly(idx: int) -> float: return float(_cells[idx].air_mass_temp_anomaly)

	# Weather scalar
	func get_weather_intensity(idx: int) -> float: return float(_cells[idx].weather_intensity)
	func get_weather_cloud(idx: int) -> float: return float(_cells[idx].weather_cloud)
	func get_weather_cloud_water(_idx: int) -> float: return 0.0
	func get_weather_precip(idx: int) -> float: return float(_cells[idx].weather_precip)
	func get_weather_vapor(idx: int) -> float: return float(_cells[idx].weather_vapor)
	func get_weather_convergence(idx: int) -> float: return float(_cells[idx].weather_convergence)
	func get_weather_instability(idx: int) -> float: return float(_cells[idx].weather_instability)
	func get_weather_transition_alpha(idx: int) -> float: return float(_cells[idx].weather_transition_alpha)
	func get_vegetation_heat_stress(idx: int) -> float: return float(_cells[idx].vegetation_heat_stress)
	func get_vegetation_drought_stress(idx: int) -> float: return float(_cells[idx].vegetation_drought_stress)
	func get_vegetation_cold_stress(idx: int) -> float: return float(_cells[idx].vegetation_cold_stress)
	func get_vegetation_regen_score(idx: int) -> float: return float(_cells[idx].vegetation_regen_score)

	# Static
	func get_elevation(idx: int) -> float: return float(_cells[idx].elevation)
	func get_base_moisture(idx: int) -> float: return float(_cells[idx].base_moisture)
	func get_pos_x(_idx: int) -> float:
		# HexCell 也没有 cell_pos_x 强类型；要求 World adapter
		return 0.0
	func get_pos_y(_idx: int) -> float:
		return 0.0
	func get_lat_norm(_idx: int) -> float:
		return 0.0
	func get_ocean_current_x(idx: int) -> float: return float(_cells[idx].ocean_current.x)
	func get_ocean_current_y(idx: int) -> float: return float(_cells[idx].ocean_current.y)
	func get_wind_x(idx: int) -> float: return float(_cells[idx].wind_vector.x)
	func get_wind_y(idx: int) -> float: return float(_cells[idx].wind_vector.y)
	func get_slp(idx: int) -> float: return float(_cells[idx].slp)
	func get_wind_speed(idx: int) -> float: return float(_cells[idx].wind_speed)
	func get_upwelling_strength(idx: int) -> float: return float(_cells[idx].upwelling_strength)
	func get_wind_stress_curl(idx: int) -> float: return float(_cells[idx].wind_stress_curl)
	func get_ocean_psi(idx: int) -> float: return float(_cells[idx].ocean_psi)

	# Enums
	func get_terrain(idx: int) -> int: return int(_cells[idx].terrain)
	func get_landform(idx: int) -> int: return int(_cells[idx].landform)
	func get_vegetation(idx: int) -> int: return int(_cells[idx].vegetation)
	func get_cover(idx: int) -> int: return int(_cells[idx].cover)
	func get_weather_type(idx: int) -> int: return int(_cells[idx].weather_type)
	func get_weather_prev_type(idx: int) -> int: return int(_cells[idx].weather_prev_type)
	func get_weather_target_type(idx: int) -> int: return int(_cells[idx].weather_target_type)

	# Booleans
	func get_is_water(idx: int) -> bool: return MapData.terrain_is_water(int(_cells[idx].terrain))
	func get_has_river(idx: int) -> bool: return bool(_cells[idx].has_river)
	func get_weather_field_init(idx: int) -> bool: return bool(_cells[idx].weather_field_initialized)
	func get_ema_initialized(idx: int) -> bool: return bool(_cells[idx]._ema_initialized)


# ─── 实现 2：World（DOTS）───────────────────────────────────────────────
#
# 不缓存 PackedArray view（避免 GDExtension CoW 解耦后视图陈旧 bug，2026-05-14
# "极寒 bug" 修复，详见 docs/dots-f4-validation.md §2.2.b 同源契约）。
#
# 每次 getter 直接从 MapData.<map_field> 读 PackedArray —— map.<field> 是
# GDScript var，一旦 GDScript 写或 C++ _flush_slot_to_map 推回，引用即时反映
# 最新 buffer。getter 仅服务于冷路径（UI panel / inspector / debug print），
# hot loop 应继续在系统内部 cache `world.view_f32(cid)` 到局部变量直接索引。
#
# 用途：阶段 II 数据所有权下移到 DCWorld(Ext) 之后默认实现，让 UI/renderer
# 不感知数据搬迁。
class World extends DCViewAdapter:
	var _world  # DCWorld（GDScript）or DCWorldExt（C++ via GDExtension）— 仅 describe 用
	var _map_data  # MapData — SoA 权威数据源，每 getter 通过 _map_data.<field> 重取

	func _init(world, map_data = null) -> void:
		_world = world
		_map_data = map_data
		# 兼容旧调用签名：DCViewAdapter.World.new(dc_world)（不传 map_data）
		# 此时尝试从 dc_world._map_data 抓引用（DCWorld GDScript 实现暴露此字段）
		if _map_data == null and _world != null:
			if "_map_data" in _world:
				_map_data = _world._map_data
		setup()

	func describe() -> String:
		var n_cells: int = 0
		var n_components: int = 0
		if _world != null:
			if _world.has_method("entity_count"):
				n_cells = int(_world.entity_count())
			if _world.has_method("component_count"):
				n_components = int(_world.component_count())
		var src: String = "map_data" if _map_data != null else "world-only(no_map)"
		return "DCViewAdapter.World(n=%d, components=%d, src=%s)" % [n_cells, n_components, src]

	## 当前实现是 stateless（不缓存 view）：setup() 仅做参数 sanity check。
	## bind_map_data / regenerate / 重 bind 后**不需要**重 new adapter—getter
	## 每次都从 _map_data.<field> 取最新引用。保留 setup() 方法签名以兼容
	## 阶段 II 之前的调用方式与抽象基类约定。
	func setup() -> void:
		if _world == null:
			push_error("[DCViewAdapter.World] setup: world is null")
			return
		if _map_data == null:
			push_warning("[DCViewAdapter.World] setup: map_data is null; getter will return zeros until rebind")

	# 内部：从 _map_data.<map_field> 取 F32 PackedArray 当前引用
	# 每次调用都重新走 GDScript var 访问，确保 CoW 解耦后取得最新 buffer
	func _arr_f32(map_field: StringName) -> PackedFloat32Array:
		if _map_data == null:
			return PackedFloat32Array()
		var v = _map_data.get(map_field)
		if v is PackedFloat32Array:
			return v
		return PackedFloat32Array()

	func _arr_u8(map_field: StringName) -> PackedByteArray:
		if _map_data == null:
			return PackedByteArray()
		var v = _map_data.get(map_field)
		if v is PackedByteArray:
			return v
		return PackedByteArray()

	func _f(arr: PackedFloat32Array, idx: int) -> float:
		if idx < 0 or idx >= arr.size():
			return 0.0
		return arr[idx]

	func _u(arr: PackedByteArray, idx: int) -> int:
		if idx < 0 or idx >= arr.size():
			return 0
		return arr[idx]

	# Climate scalar
	func get_temp(idx: int) -> float:               return _f(_arr_f32(&"temp_arr"), idx)
	func get_moisture(idx: int) -> float:           return _f(_arr_f32(&"moisture_arr"), idx)
	func get_snow_cover(idx: int) -> float:         return _f(_arr_f32(&"snow_cover_arr"), idx)
	func get_sea_ice_frac(idx: int) -> float:       return _f(_arr_f32(&"sea_ice_frac_arr"), idx)
	func get_temp_baseline(idx: int) -> float:      return _f(_arr_f32(&"temp_baseline_arr"), idx)
	func get_temp_30d(idx: int) -> float:           return _f(_arr_f32(&"temp_30d_arr"), idx)
	func get_temp_365d(idx: int) -> float:          return _f(_arr_f32(&"temp_365d_arr"), idx)
	func get_temp_anomaly(idx: int) -> float:       return _f(_arr_f32(&"temp_anomaly_arr"), idx)
	func get_temp_baseline_year(idx: int) -> float: return _f(_arr_f32(&"temp_baseline_year_arr"), idx)
	func get_temp_season_offset(idx: int) -> float: return _f(_arr_f32(&"temp_season_offset_arr"), idx)
	func get_air_mass_temp_anomaly(idx: int) -> float: return _f(_arr_f32(&"air_mass_temp_anomaly_arr"), idx)

	# Weather scalar
	func get_weather_intensity(idx: int) -> float:   return _f(_arr_f32(&"weather_intensity_arr"), idx)
	func get_weather_cloud(idx: int) -> float:       return _f(_arr_f32(&"weather_cloud_arr"), idx)
	func get_weather_cloud_water(idx: int) -> float: return _f(_arr_f32(&"weather_cloud_water_arr"), idx)
	func get_weather_precip(idx: int) -> float:      return _f(_arr_f32(&"weather_precip_arr"), idx)
	func get_weather_vapor(idx: int) -> float:       return _f(_arr_f32(&"weather_vapor_arr"), idx)
	func get_weather_convergence(idx: int) -> float: return _f(_arr_f32(&"weather_convergence_arr"), idx)
	func get_weather_instability(idx: int) -> float: return _f(_arr_f32(&"weather_instability_arr"), idx)
	func get_weather_transition_alpha(idx: int) -> float: return _f(_arr_f32(&"weather_transition_alpha_arr"), idx)
	func get_vegetation_heat_stress(idx: int) -> float: return _f(_arr_f32(&"vegetation_heat_stress_arr"), idx)
	func get_vegetation_drought_stress(idx: int) -> float: return _f(_arr_f32(&"vegetation_drought_stress_arr"), idx)
	func get_vegetation_cold_stress(idx: int) -> float: return _f(_arr_f32(&"vegetation_cold_stress_arr"), idx)
	func get_vegetation_regen_score(idx: int) -> float: return _f(_arr_f32(&"vegetation_regen_score_arr"), idx)

	# Static
	func get_elevation(idx: int) -> float:        return _f(_arr_f32(&"elevation_arr"), idx)
	func get_base_moisture(idx: int) -> float:    return _f(_arr_f32(&"base_moisture_arr"), idx)
	func get_pos_x(idx: int) -> float:            return _f(_arr_f32(&"cell_pos_x_arr"), idx)
	func get_pos_y(idx: int) -> float:            return _f(_arr_f32(&"cell_pos_y_arr"), idx)
	func get_lat_norm(idx: int) -> float:         return _f(_arr_f32(&"cell_lat_norm_arr"), idx)
	func get_ocean_current_x(idx: int) -> float:  return _f(_arr_f32(&"ocean_current_x_arr"), idx)
	func get_ocean_current_y(idx: int) -> float:  return _f(_arr_f32(&"ocean_current_y_arr"), idx)
	func get_wind_x(idx: int) -> float:           return _f(_arr_f32(&"wind_x_arr"), idx)
	func get_wind_y(idx: int) -> float:           return _f(_arr_f32(&"wind_y_arr"), idx)
	func get_slp(idx: int) -> float:              return _f(_arr_f32(&"slp_arr"), idx)
	func get_wind_speed(idx: int) -> float:       return _f(_arr_f32(&"wind_speed_arr"), idx)
	func get_upwelling_strength(idx: int) -> float: return _f(_arr_f32(&"upwelling_strength_arr"), idx)
	func get_wind_stress_curl(idx: int) -> float: return _f(_arr_f32(&"wind_stress_curl_arr"), idx)
	func get_ocean_psi(idx: int) -> float:        return _f(_arr_f32(&"ocean_psi_arr"), idx)

	# Enums
	func get_terrain(idx: int) -> int:       return _u(_arr_u8(&"terrain_arr"), idx)
	func get_landform(idx: int) -> int:      return _u(_arr_u8(&"landform_arr"), idx)
	func get_vegetation(idx: int) -> int:    return _u(_arr_u8(&"vegetation_arr"), idx)
	func get_cover(idx: int) -> int:         return _u(_arr_u8(&"cover_arr"), idx)
	func get_weather_type(idx: int) -> int:  return _u(_arr_u8(&"weather_type_arr"), idx)
	func get_weather_prev_type(idx: int) -> int: return _u(_arr_u8(&"weather_prev_type_arr"), idx)
	func get_weather_target_type(idx: int) -> int: return _u(_arr_u8(&"weather_target_type_arr"), idx)

	# Booleans
	func get_is_water(idx: int) -> bool:           return _u(_arr_u8(&"is_water_arr"), idx) > 0
	func get_has_river(idx: int) -> bool:          return _u(_arr_u8(&"has_river_arr"), idx) > 0
	func get_weather_field_init(idx: int) -> bool: return _u(_arr_u8(&"weather_field_init_arr"), idx) > 0
	func get_ema_initialized(idx: int) -> bool:    return _u(_arr_u8(&"ema_initialized_arr"), idx) > 0
