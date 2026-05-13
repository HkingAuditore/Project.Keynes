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
##   - World 实现：每 getter 1 次数组索引，~10ns（拿到 PackedArray 后走原生
##     操作，无 Variant 装箱）；setup() 调用一次缓存全部 view 引用
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
func get_weather_precip(_idx: int) -> float: return 0.0
func get_weather_vapor(_idx: int) -> float: return 0.0
func get_weather_convergence(_idx: int) -> float: return 0.0
func get_weather_instability(_idx: int) -> float: return 0.0

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

# ─── Discrete enums (U8) ─────────────────────────────────────────────────
func get_terrain(_idx: int) -> int: return 0
func get_landform(_idx: int) -> int: return 0
func get_vegetation(_idx: int) -> int: return 0
func get_cover(_idx: int) -> int: return 0
func get_weather_type(_idx: int) -> int: return 0

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
	func get_weather_precip(idx: int) -> float: return float(_cells[idx].weather_precip)
	func get_weather_vapor(idx: int) -> float: return float(_cells[idx].weather_vapor)
	func get_weather_convergence(idx: int) -> float: return float(_cells[idx].weather_convergence)
	func get_weather_instability(idx: int) -> float: return float(_cells[idx].weather_instability)

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

	# Enums
	func get_terrain(idx: int) -> int: return int(_cells[idx].terrain)
	func get_landform(idx: int) -> int: return int(_cells[idx].landform)
	func get_vegetation(idx: int) -> int: return int(_cells[idx].vegetation)
	func get_cover(idx: int) -> int: return int(_cells[idx].cover)
	func get_weather_type(idx: int) -> int: return int(_cells[idx].weather_type)

	# Booleans
	# is_water 在 HexCell 上没有独立字段；用"非 passable_land"等价（与 MapData.is_water_arr
	# 的填充逻辑 1:1 对齐：rebuild_soa_from_cells 里 is_water_arr[i] = (1 if not passable_land else 0)）
	func get_is_water(idx: int) -> bool: return not _cells[idx].passable_land
	func get_has_river(idx: int) -> bool: return bool(_cells[idx].has_river)
	func get_weather_field_init(idx: int) -> bool: return bool(_cells[idx].weather_field_initialized)
	func get_ema_initialized(idx: int) -> bool: return bool(_cells[idx]._ema_initialized)


# ─── 实现 2：World（DOTS）───────────────────────────────────────────────
#
# 在 setup() 一次性把 DCWorld 的全部 view_f32/view_u8 引用缓存到本实例字段。
# getter 走原生 PackedArray[idx]，无 Variant 装箱；冷路径性能与 Cell 实现
# 等价或更快，hot path 调用方应直接用缓存的 PackedArray（不走 adapter）。
#
# 用途：阶段 II 数据所有权下移到 DCWorld(Ext) 之后默认实现，让 UI/renderer
# 不感知数据搬迁。
class World extends DCViewAdapter:
	var _world  # DCWorld（GDScript）or DCWorldExt（C++ via GDExtension）

	# Cached views（PackedFloat32Array / PackedByteArray，CoW 引用）
	var _v_temp:                PackedFloat32Array = PackedFloat32Array()
	var _v_moisture:            PackedFloat32Array = PackedFloat32Array()
	var _v_snow_cover:          PackedFloat32Array = PackedFloat32Array()
	var _v_sea_ice_frac:        PackedFloat32Array = PackedFloat32Array()
	var _v_temp_baseline:       PackedFloat32Array = PackedFloat32Array()
	var _v_temp_30d:            PackedFloat32Array = PackedFloat32Array()
	var _v_temp_365d:           PackedFloat32Array = PackedFloat32Array()
	var _v_temp_anomaly:        PackedFloat32Array = PackedFloat32Array()
	var _v_temp_baseline_year:  PackedFloat32Array = PackedFloat32Array()
	var _v_temp_season_offset:  PackedFloat32Array = PackedFloat32Array()
	var _v_air_mass_temp_anom:  PackedFloat32Array = PackedFloat32Array()
	var _v_weather_intensity:   PackedFloat32Array = PackedFloat32Array()
	var _v_weather_cloud:       PackedFloat32Array = PackedFloat32Array()
	var _v_weather_precip:      PackedFloat32Array = PackedFloat32Array()
	var _v_weather_vapor:       PackedFloat32Array = PackedFloat32Array()
	var _v_weather_convergence: PackedFloat32Array = PackedFloat32Array()
	var _v_weather_instability: PackedFloat32Array = PackedFloat32Array()
	var _v_elevation:           PackedFloat32Array = PackedFloat32Array()
	var _v_base_moisture:       PackedFloat32Array = PackedFloat32Array()
	var _v_pos_x:               PackedFloat32Array = PackedFloat32Array()
	var _v_pos_y:               PackedFloat32Array = PackedFloat32Array()
	var _v_lat_norm:            PackedFloat32Array = PackedFloat32Array()
	var _v_ocean_x:             PackedFloat32Array = PackedFloat32Array()
	var _v_ocean_y:             PackedFloat32Array = PackedFloat32Array()
	var _v_wind_x:              PackedFloat32Array = PackedFloat32Array()
	var _v_wind_y:              PackedFloat32Array = PackedFloat32Array()
	var _v_terrain:             PackedByteArray    = PackedByteArray()
	var _v_landform:            PackedByteArray    = PackedByteArray()
	var _v_vegetation:          PackedByteArray    = PackedByteArray()
	var _v_cover:               PackedByteArray    = PackedByteArray()
	var _v_weather_type:        PackedByteArray    = PackedByteArray()
	var _v_is_water:            PackedByteArray    = PackedByteArray()
	var _v_has_river:           PackedByteArray    = PackedByteArray()
	var _v_weather_field_init:  PackedByteArray    = PackedByteArray()
	var _v_ema_initialized:     PackedByteArray    = PackedByteArray()

	func _init(world) -> void:
		_world = world
		setup()

	func describe() -> String:
		return "DCViewAdapter.World(n=%d, components=%d)" % [
			int(_world.entity_count()) if _world.has_method("entity_count") else 0,
			int(_world.component_count()) if _world.has_method("component_count") else 0,
		]

	## 把全部 view 引用一次性缓存。bind_map_data / regenerate / 重 bind 后
	## 调用方应重 new 一个 World adapter，或调用 setup() 重新刷新引用。
	func setup() -> void:
		if _world == null:
			push_error("[DCViewAdapter.World] setup: world is null")
			return
		_v_temp                = _resolve_f32(DCComponentIds.CELL_TEMP)
		_v_moisture            = _resolve_f32(DCComponentIds.CELL_MOISTURE)
		_v_snow_cover          = _resolve_f32(DCComponentIds.CELL_SNOW_COVER)
		_v_sea_ice_frac        = _resolve_f32(DCComponentIds.CELL_SEA_ICE_FRAC)
		_v_temp_baseline       = _resolve_f32(DCComponentIds.CELL_TEMP_BASELINE)
		_v_temp_30d            = _resolve_f32(DCComponentIds.CELL_TEMP_30D)
		_v_temp_365d           = _resolve_f32(DCComponentIds.CELL_TEMP_365D)
		_v_temp_anomaly        = _resolve_f32(DCComponentIds.CELL_TEMP_ANOMALY)
		_v_temp_baseline_year  = _resolve_f32(DCComponentIds.CELL_TEMP_BASELINE_YEAR)
		_v_temp_season_offset  = _resolve_f32(DCComponentIds.CELL_TEMP_SEASON_OFFSET)
		_v_air_mass_temp_anom  = _resolve_f32(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
		_v_weather_intensity   = _resolve_f32(DCComponentIds.CELL_WEATHER_INTENSITY)
		_v_weather_cloud       = _resolve_f32(DCComponentIds.CELL_WEATHER_CLOUD)
		_v_weather_precip      = _resolve_f32(DCComponentIds.CELL_WEATHER_PRECIP)
		_v_weather_vapor       = _resolve_f32(DCComponentIds.CELL_WEATHER_VAPOR)
		_v_weather_convergence = _resolve_f32(DCComponentIds.CELL_WEATHER_CONVERGENCE)
		_v_weather_instability = _resolve_f32(DCComponentIds.CELL_WEATHER_INSTABILITY)
		_v_elevation           = _resolve_f32(DCComponentIds.CELL_ELEVATION)
		_v_base_moisture       = _resolve_f32(DCComponentIds.CELL_BASE_MOISTURE)
		_v_pos_x               = _resolve_f32(DCComponentIds.CELL_POS_X)
		_v_pos_y               = _resolve_f32(DCComponentIds.CELL_POS_Y)
		_v_lat_norm            = _resolve_f32(DCComponentIds.CELL_LAT_NORM)
		_v_ocean_x             = _resolve_f32(DCComponentIds.CELL_OCEAN_CURRENT_X)
		_v_ocean_y             = _resolve_f32(DCComponentIds.CELL_OCEAN_CURRENT_Y)
		_v_wind_x              = _resolve_f32(DCComponentIds.CELL_WIND_X)
		_v_wind_y              = _resolve_f32(DCComponentIds.CELL_WIND_Y)
		_v_terrain             = _resolve_u8(DCComponentIds.CELL_TERRAIN)
		_v_landform            = _resolve_u8(DCComponentIds.CELL_LANDFORM)
		_v_vegetation          = _resolve_u8(DCComponentIds.CELL_VEGETATION)
		_v_cover               = _resolve_u8(DCComponentIds.CELL_COVER)
		_v_weather_type        = _resolve_u8(DCComponentIds.CELL_WEATHER_TYPE)
		_v_is_water            = _resolve_u8(DCComponentIds.CELL_IS_WATER)
		_v_has_river           = _resolve_u8(DCComponentIds.CELL_HAS_RIVER)
		_v_weather_field_init  = _resolve_u8(DCComponentIds.CELL_WEATHER_FIELD_INIT)
		_v_ema_initialized     = _resolve_u8(DCComponentIds.CELL_EMA_INITIALIZED)

	# 内部：取 F32 view（缺失时 push_warning 一次并返回空数组）
	func _resolve_f32(comp_name: StringName) -> PackedFloat32Array:
		var cid: int = int(_world.component_id(comp_name))
		if cid < 0:
			if OS.is_debug_build():
				push_warning("[DCViewAdapter.World] component '%s' not registered; using empty view" % String(comp_name))
			return PackedFloat32Array()
		# DCWorld 与 DCWorldExt 都暴露 view_f32(comp_id) 方法（同名）
		return _world.view_f32(cid)

	func _resolve_u8(comp_name: StringName) -> PackedByteArray:
		var cid: int = int(_world.component_id(comp_name))
		if cid < 0:
			if OS.is_debug_build():
				push_warning("[DCViewAdapter.World] component '%s' not registered; using empty view" % String(comp_name))
			return PackedByteArray()
		return _world.view_u8(cid)

	# 内部：安全 F32 索引（越界返回 0；冷路径用，hot path 应直接走数组）
	func _f(view: PackedFloat32Array, idx: int) -> float:
		if idx < 0 or idx >= view.size():
			return 0.0
		return view[idx]

	func _u(view: PackedByteArray, idx: int) -> int:
		if idx < 0 or idx >= view.size():
			return 0
		return view[idx]

	# Climate scalar
	func get_temp(idx: int) -> float:               return _f(_v_temp, idx)
	func get_moisture(idx: int) -> float:           return _f(_v_moisture, idx)
	func get_snow_cover(idx: int) -> float:         return _f(_v_snow_cover, idx)
	func get_sea_ice_frac(idx: int) -> float:       return _f(_v_sea_ice_frac, idx)
	func get_temp_baseline(idx: int) -> float:      return _f(_v_temp_baseline, idx)
	func get_temp_30d(idx: int) -> float:           return _f(_v_temp_30d, idx)
	func get_temp_365d(idx: int) -> float:          return _f(_v_temp_365d, idx)
	func get_temp_anomaly(idx: int) -> float:       return _f(_v_temp_anomaly, idx)
	func get_temp_baseline_year(idx: int) -> float: return _f(_v_temp_baseline_year, idx)
	func get_temp_season_offset(idx: int) -> float: return _f(_v_temp_season_offset, idx)
	func get_air_mass_temp_anomaly(idx: int) -> float: return _f(_v_air_mass_temp_anom, idx)

	# Weather scalar
	func get_weather_intensity(idx: int) -> float:   return _f(_v_weather_intensity, idx)
	func get_weather_cloud(idx: int) -> float:       return _f(_v_weather_cloud, idx)
	func get_weather_precip(idx: int) -> float:      return _f(_v_weather_precip, idx)
	func get_weather_vapor(idx: int) -> float:       return _f(_v_weather_vapor, idx)
	func get_weather_convergence(idx: int) -> float: return _f(_v_weather_convergence, idx)
	func get_weather_instability(idx: int) -> float: return _f(_v_weather_instability, idx)

	# Static
	func get_elevation(idx: int) -> float:        return _f(_v_elevation, idx)
	func get_base_moisture(idx: int) -> float:    return _f(_v_base_moisture, idx)
	func get_pos_x(idx: int) -> float:            return _f(_v_pos_x, idx)
	func get_pos_y(idx: int) -> float:            return _f(_v_pos_y, idx)
	func get_lat_norm(idx: int) -> float:         return _f(_v_lat_norm, idx)
	func get_ocean_current_x(idx: int) -> float:  return _f(_v_ocean_x, idx)
	func get_ocean_current_y(idx: int) -> float:  return _f(_v_ocean_y, idx)
	func get_wind_x(idx: int) -> float:           return _f(_v_wind_x, idx)
	func get_wind_y(idx: int) -> float:           return _f(_v_wind_y, idx)

	# Enums
	func get_terrain(idx: int) -> int:       return _u(_v_terrain, idx)
	func get_landform(idx: int) -> int:      return _u(_v_landform, idx)
	func get_vegetation(idx: int) -> int:    return _u(_v_vegetation, idx)
	func get_cover(idx: int) -> int:         return _u(_v_cover, idx)
	func get_weather_type(idx: int) -> int:  return _u(_v_weather_type, idx)

	# Booleans
	func get_is_water(idx: int) -> bool:           return _u(_v_is_water, idx) > 0
	func get_has_river(idx: int) -> bool:          return _u(_v_has_river, idx) > 0
	func get_weather_field_init(idx: int) -> bool: return _u(_v_weather_field_init, idx) > 0
	func get_ema_initialized(idx: int) -> bool:    return _u(_v_ema_initialized, idx) > 0
