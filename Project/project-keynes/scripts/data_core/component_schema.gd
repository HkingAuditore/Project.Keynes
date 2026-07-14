extends RefCounted
class_name DCComponentSchema

## DataCore — Cell-level Component Schema 单一源（A1 / P0-1）。
##
## 设计目标（dots-migration-roadmap §3 A1）：
##   1. 把现有的"加新 cell-level 字段要改 6 处"压缩到"改 1 处"；
##   2. 同时驱动 GDScript 侧 `world.gd::bind_map_data` 与 C++ 侧
##      `gdext/src/component_bind_table.gen.h`（由
##      `tools/codegen/gen_cpp_bind_table.py` 离线生成），消除
##      "GDScript / C++ 两份 BIND_TABLE 双重维护"反模式
##      （performance-charter §11.2 / §12.4 历史警告）。
##
## 关键不变量（违反任一会让 bind_map_data 静默偏离 / C++ pass 拿到 -1 slot）：
##   - `name` 必须等于 `DCComponentIds.CELL_*` 常量的 StringName 值
##     （形如 `&"cell.temp"`，dot 命名），且与 `world.gd::_builtin_cell_ids`
##     当前查询路径 1:1 对齐；
##   - `cpp_name` 必须等于 C++ 侧 `_slots[].name` 注册时使用的 StringName
##     （形如 `"cell_temp"`，underscore 命名），与 `world_ext.cpp` 现行
##     `run_climate_pass_a` 等 C++ pass 内的 `component_id("cell_temp")` 调用
##     1:1 对齐；
##   - `dtype` 与 `track_prev` 决定底层 PackedArray 类型与 _prev 镜像
##     是否分配，与 GDScript `_bind_register_and_attach[_u8]` 行为一致；
##   - `map_field` 必须是 `MapData` 上真实存在的属性名（直接 obj.get
##     按字符串读取；GDScript 与 C++ 都依赖此字段）；
##   - `prev_field` 仅当 `track_prev=true` 时被使用，必须是 `MapData` 上
##     `<map_field>_prev` 形式的真实属性；track_prev=false 时填空字符串。
##
## 加新字段的 5 步骤（详见 docs/dots-component-schema.md 的 SOP）：
##   1. 在 `DCComponentIds` 加一个 `CELL_<NAME>: StringName = &"cell.<name>"` 常量；
##   2. 在 `MapData` 加同名 `PackedArray` 字段并在 `_alloc_soa / rebuild_soa_from_cells`
##      里 resize / 镜像；
##   3. 在本文件 `CELL_SCHEMA` 末尾追加一行（30 秒）；
##   4. 跑 `python3 tools/codegen/gen_cpp_bind_table.py` 重新生成 C++ 头；
##   5. 重 build GDExtension。完成。

# dtype 别名：把 DCComponentIds 枚举值"拉到本文件名字空间"，让下方的
# CELL_SCHEMA 表项更紧凑（dtype = F32 比 dtype = DCComponentIds.F32 短）。
# 这里的赋值在编译期发生，DCComponentIds 已通过 class_name 全局可见，无需 preload。
const F32: int = DCComponentIds.F32
const I32: int = DCComponentIds.I32
const U8: int  = DCComponentIds.U8

# ─── CELL_SCHEMA — 140 条（截至 2026-07-09，含物资库存/价格字段；
#     与 component_ids.gd / world.gd / world_ext.cpp BIND_TABLE 1:1 镜像）────
#
# 字段 demo（可选，默认 false）：标记为 true 的条目仅在
# `ClimateProfile.demo_thermal_gradient_enabled` 为 true 时才被
# bind_map_data attach；为 false 时跳过（slot 不注册，C++ pass
# `component_id("cell_demo_*")` 返回 -1，pass 内部安全 no-op）。
#
# 字段 owner：业务模块归属，仅作 lint / dot-graph 用，**无运行期影响**。
# 后续 dots_lint 工具会校验"声明 owner=X 但实际有 Y 在写"的违约。
const CELL_SCHEMA: Array = [
	# ─── Climate / Weather F32（含日照、热惯性、雪包、水分平衡）────────
	{ name = &"cell.temp",               cpp_name = "cell_temp",                  dtype = F32, track_prev = true,  map_field = "temp_arr",                  prev_field = "temp_arr_prev",            owner = "climate.wind_surface" },
	{ name = &"cell.temp_baseline",      cpp_name = "cell_temp_baseline",         dtype = F32, track_prev = false, map_field = "temp_baseline_arr",         prev_field = "",                         owner = "climate.pass_a" },
	{ name = &"cell.temp_30d",           cpp_name = "cell_temp_30d",              dtype = F32, track_prev = false, map_field = "temp_30d_arr",              prev_field = "",                         owner = "climate.pass_a" },
	{ name = &"cell.temp_365d",          cpp_name = "cell_temp_365d",             dtype = F32, track_prev = false, map_field = "temp_365d_arr",             prev_field = "",                         owner = "climate.pass_a" },
	{ name = &"cell.temp_anomaly",       cpp_name = "cell_temp_anomaly",          dtype = F32, track_prev = false, map_field = "temp_anomaly_arr",          prev_field = "",                         owner = "climate.pass_a" },
	{ name = &"cell.moisture",           cpp_name = "cell_moisture",              dtype = F32, track_prev = true,  map_field = "moisture_arr",              prev_field = "moisture_arr_prev",        owner = "climate.pass_b" },
	{ name = &"cell.snow_cover",         cpp_name = "cell_snow_cover",            dtype = F32, track_prev = true,  map_field = "snow_cover_arr",            prev_field = "snow_cover_arr_prev",      owner = "weather.snow_visual" },
	{ name = &"cell.sea_ice_frac",       cpp_name = "cell_sea_ice_frac",          dtype = F32, track_prev = true,  map_field = "sea_ice_frac_arr",          prev_field = "sea_ice_frac_arr_prev",    owner = "climate.sea_ice" },
	{ name = &"cell.weather_intensity",  cpp_name = "cell_weather_intensity",     dtype = F32, track_prev = false, map_field = "weather_intensity_arr",     prev_field = "",                         owner = "weather.commit" },
	{ name = &"cell.weather_cloud",      cpp_name = "cell_weather_cloud",         dtype = F32, track_prev = false, map_field = "weather_cloud_arr",         prev_field = "",                         owner = "weather.commit" },
	{ name = &"cell.weather_cloud_water", cpp_name = "cell_weather_cloud_water",  dtype = F32, track_prev = false, map_field = "weather_cloud_water_arr",   prev_field = "",                         owner = "weather.field_solver" },
	{ name = &"cell.weather_precip",     cpp_name = "cell_weather_precip",        dtype = F32, track_prev = false, map_field = "weather_precip_arr",        prev_field = "",                         owner = "weather.commit" },
	{ name = &"cell.weather_transition_alpha", cpp_name = "cell_weather_transition_alpha", dtype = F32, track_prev = false, map_field = "weather_transition_alpha_arr", prev_field = "",                  owner = "weather.commit" },
	{ name = &"cell.elevation",          cpp_name = "cell_elevation",             dtype = F32, track_prev = false, map_field = "elevation_arr",             prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.base_moisture",      cpp_name = "cell_base_moisture",         dtype = F32, track_prev = false, map_field = "base_moisture_arr",         prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.ocean_current_x",    cpp_name = "cell_ocean_current_x",       dtype = F32, track_prev = false, map_field = "ocean_current_x_arr",       prev_field = "",                         owner = "ocean.currents" },
	{ name = &"cell.ocean_current_y",    cpp_name = "cell_ocean_current_y",       dtype = F32, track_prev = false, map_field = "ocean_current_y_arr",       prev_field = "",                         owner = "ocean.currents" },
	{ name = &"cell.wind_x",             cpp_name = "cell_wind_x",                dtype = F32, track_prev = false, map_field = "wind_x_arr",                prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.wind_y",             cpp_name = "cell_wind_y",                dtype = F32, track_prev = false, map_field = "wind_y_arr",                prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.slp",                cpp_name = "cell_slp",                   dtype = F32, track_prev = false, map_field = "slp_arr",                   prev_field = "",                         owner = "ocean.physical" },
	{ name = &"cell.wind_speed",         cpp_name = "cell_wind_speed",            dtype = F32, track_prev = false, map_field = "wind_speed_arr",            prev_field = "",                         owner = "ocean.physical" },
	{ name = &"cell.upwelling_strength", cpp_name = "cell_upwelling_strength",    dtype = F32, track_prev = false, map_field = "upwelling_strength_arr",    prev_field = "",                         owner = "ocean.currents" },
	# Fix #11 (2026-06-15): wind_stress_curl + ocean_psi 加进 schema，让 C++ run_psi_solver_pass
	# 直接 published_to_slot 后 GDScript caller 跳过 2400-loop 写回 (map_baker.gd PSI_INIT
	# stage)。这两个数组之前只在 MapData PackedArray 存在，仅 tile_data_recorder 读取。
	# Schema 化后 view_adapter / DataCore consumer 也能直读 slot。
	{ name = &"cell.wind_stress_curl",   cpp_name = "cell_wind_stress_curl",      dtype = F32, track_prev = false, map_field = "wind_stress_curl_arr",      prev_field = "",                         owner = "ocean.currents" },
	{ name = &"cell.ocean_psi",          cpp_name = "cell_ocean_psi",             dtype = F32, track_prev = false, map_field = "ocean_psi_arr",             prev_field = "",                         owner = "ocean.currents" },
	{ name = &"cell.pos_x",              cpp_name = "cell_pos_x",                 dtype = F32, track_prev = false, map_field = "cell_pos_x_arr",            prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.pos_y",              cpp_name = "cell_pos_y",                 dtype = F32, track_prev = false, map_field = "cell_pos_y_arr",            prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.lat_norm",           cpp_name = "cell_lat_norm",              dtype = F32, track_prev = false, map_field = "cell_lat_norm_arr",         prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.temp_baseline_year", cpp_name = "cell_temp_baseline_year",    dtype = F32, track_prev = false, map_field = "temp_baseline_year_arr",    prev_field = "",                         owner = "map_generation" },
	# ─── Climate U8（8 条，对应 world.gd 689-696）──────────────────────────
	{ name = &"cell.terrain",            cpp_name = "cell_terrain",               dtype = U8,  track_prev = false, map_field = "terrain_arr",               prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.landform",           cpp_name = "cell_landform",              dtype = U8,  track_prev = false, map_field = "landform_arr",              prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.vegetation",         cpp_name = "cell_vegetation",            dtype = U8,  track_prev = false, map_field = "vegetation_arr",            prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.base_terrain",       cpp_name = "cell_base_terrain",          dtype = U8,  track_prev = false, map_field = "base_terrain_arr",          prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.base_landform",      cpp_name = "cell_base_landform",         dtype = U8,  track_prev = false, map_field = "base_landform_arr",         prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.base_vegetation",    cpp_name = "cell_base_vegetation",       dtype = U8,  track_prev = false, map_field = "base_vegetation_arr",       prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.cover",              cpp_name = "cell_cover",                 dtype = U8,  track_prev = false, map_field = "cover_arr",                 prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.weather_type",       cpp_name = "cell_weather_type",          dtype = U8,  track_prev = false, map_field = "weather_type_arr",          prev_field = "",                         owner = "weather.commit" },
	{ name = &"cell.weather_prev_type",  cpp_name = "cell_weather_prev_type",     dtype = U8,  track_prev = false, map_field = "weather_prev_type_arr",     prev_field = "",                         owner = "weather.commit" },
	{ name = &"cell.weather_target_type", cpp_name = "cell_weather_target_type",  dtype = U8,  track_prev = false, map_field = "weather_target_type_arr",   prev_field = "",                         owner = "weather.commit" },
	{ name = &"cell.is_water",           cpp_name = "cell_is_water",              dtype = U8,  track_prev = false, map_field = "is_water_arr",              prev_field = "",                         owner = "map_generation" },
	{ name = &"cell.country_slot",       cpp_name = "cell_country_slot",          dtype = I32, track_prev = false, map_field = "country_slot_arr",          prev_field = "",                         owner = "country_runtime" },
	{ name = &"cell.resource_habitat_mask", cpp_name = "cell_resource_habitat_mask", dtype = U8, track_prev = false, map_field = "resource_habitat_mask_arr", prev_field = "", owner = "map_generation" },
	{ name = &"cell.climate_dirty_mask", cpp_name = "cell_climate_dirty",         dtype = U8,  track_prev = false, map_field = "climate_dirty_mask",        prev_field = "",                         owner = "climate.pass_a" },
	{ name = &"cell.weather_dirty_mask", cpp_name = "cell_weather_dirty",         dtype = U8,  track_prev = false, map_field = "weather_dirty_mask",        prev_field = "",                         owner = "weather.commit" },
	# ─── Weather extras（6 条，对应 world.gd 702-707，B-full Step-2）────────
	{ name = &"cell.weather_vapor",         cpp_name = "cell_weather_vapor",         dtype = F32, track_prev = false, map_field = "weather_vapor_arr",         prev_field = "", owner = "weather.field_solver" },
	{ name = &"cell.weather_convergence",   cpp_name = "cell_weather_convergence",   dtype = F32, track_prev = false, map_field = "weather_convergence_arr",   prev_field = "", owner = "weather.field_solver" },
	{ name = &"cell.weather_instability",   cpp_name = "cell_weather_instability",   dtype = F32, track_prev = false, map_field = "weather_instability_arr",   prev_field = "", owner = "weather.field_solver" },
	{ name = &"cell.weather_field_init",    cpp_name = "cell_weather_field_init",    dtype = U8,  track_prev = false, map_field = "weather_field_init_arr",    prev_field = "", owner = "weather.field_solver" },
	{ name = &"cell.air_mass_temp_anomaly", cpp_name = "cell_air_mass_temp_anomaly", dtype = F32, track_prev = false, map_field = "air_mass_temp_anomaly_arr", prev_field = "", owner = "climate.pass_b" },
	# ─── A 修复（climate-temp-pingpong-fix-2026-06）— 显式 anomaly 合成新增 2 条 ─
	# 与 cell.air_mass_temp_anomaly 并列：
	#   ocean_thermal_anomaly  由 ocean_water/ocean_land pass 写（ocean.composition）
	#   local_thermal_anomaly  由 climate pass_b 写（albedo + coastal + landform + sea_ice 反馈）
	# wind_surface 末端把这三条 anomaly 与 cell.temp_baseline 合成回 cell.temp。
	{ name = &"cell.ocean_thermal_anomaly", cpp_name = "cell_ocean_thermal_anomaly", dtype = F32, track_prev = false, map_field = "ocean_thermal_anomaly_arr", prev_field = "", owner = "ocean.composition" },
	{ name = &"cell.local_thermal_anomaly", cpp_name = "cell_local_thermal_anomaly", dtype = F32, track_prev = false, map_field = "local_thermal_anomaly_arr", prev_field = "", owner = "climate.pass_b" },
	{ name = &"cell.has_river",             cpp_name = "cell_has_river",             dtype = U8,  track_prev = false, map_field = "has_river_arr",             prev_field = "", owner = "map_generation" },
	{ name = &"cell.river_flow",            cpp_name = "cell_river_flow",            dtype = F32, track_prev = false, map_field = "river_flow_arr",            prev_field = "", owner = "map_generation" },
	# ─── Phase 3a Step 2.1.a（2 条，对应 world.gd 711-712）─────────────────
	{ name = &"cell.ema_initialized",       cpp_name = "cell_ema_initialized",       dtype = U8,  track_prev = false, map_field = "ema_initialized_arr",       prev_field = "", owner = "climate.pass_a" },
	{ name = &"cell.temp_season_offset",    cpp_name = "cell_temp_season_offset",    dtype = F32, track_prev = false, map_field = "temp_season_offset_arr",    prev_field = "", owner = "climate.pass_a" },
	{ name = &"cell.insolation_now",        cpp_name = "cell_insolation_now",        dtype = F32, track_prev = false, map_field = "insolation_now_arr",        prev_field = "", owner = "climate.astronomy" },
	{ name = &"cell.insolation_dev",        cpp_name = "cell_insolation_dev",        dtype = F32, track_prev = false, map_field = "insolation_dev_arr",        prev_field = "", owner = "climate.astronomy" },
	{ name = &"cell.day_length",            cpp_name = "cell_day_length",            dtype = F32, track_prev = false, map_field = "day_length_arr",            prev_field = "", owner = "climate.astronomy" },
	{ name = &"cell.heat_input",            cpp_name = "cell_heat_input",            dtype = F32, track_prev = false, map_field = "heat_input_arr",            prev_field = "", owner = "climate.astronomy" },
	{ name = &"cell.thermal_energy",        cpp_name = "cell_thermal_energy",        dtype = F32, track_prev = false, map_field = "thermal_energy_arr",        prev_field = "", owner = "climate.pass_a" },
	{ name = &"cell.snowpack",              cpp_name = "cell_snowpack",              dtype = F32, track_prev = false, map_field = "snowpack_arr",              prev_field = "", owner = "climate.snowpack" },
	{ name = &"cell.water_balance_30d",     cpp_name = "cell_water_balance_30d",     dtype = F32, track_prev = false, map_field = "water_balance_30d_arr",     prev_field = "", owner = "climate.feedback" },
	# ─── B3b：植被动力学字段全量下沉 SoA（6 条，4 f32 + 2 i32）─────────────
	# 消除 stage_b combined pass 的 pack/unpack hot loop（原 ~7ms wall 的 95%）。
	# 命名严格 1:1 对齐 HexCell 字段名，方便阶段 3 把 _trigger_succession /
	# legacy fallback 改成 `world.write_f32_range(slot_id, ...)` 时搜索/重构。
	{ name = &"cell.vegetation_vitality",        cpp_name = "cell_vegetation_vitality",        dtype = F32, track_prev = false, map_field = "vegetation_vitality_arr",        prev_field = "", owner = "climate.vegetation_dynamics" },
	{ name = &"cell.vitality_low_streak",        cpp_name = "cell_vitality_low_streak",        dtype = I32, track_prev = false, map_field = "vitality_low_streak_arr",        prev_field = "", owner = "climate.vegetation_dynamics" },
	{ name = &"cell.vitality_high_streak",       cpp_name = "cell_vitality_high_streak",       dtype = I32, track_prev = false, map_field = "vitality_high_streak_arr",       prev_field = "", owner = "climate.vegetation_dynamics" },
	{ name = &"cell.soil_moisture",              cpp_name = "cell_soil_moisture",              dtype = F32, track_prev = false, map_field = "soil_moisture_arr",              prev_field = "", owner = "climate.feedback" },
	{ name = &"cell.vegetation_growth_pressure", cpp_name = "cell_vegetation_growth_pressure", dtype = F32, track_prev = false, map_field = "vegetation_growth_pressure_arr", prev_field = "", owner = "climate.feedback" },
	{ name = &"cell.temperature_transport_anomaly", cpp_name = "cell_temperature_transport_anomaly", dtype = F32, track_prev = false, map_field = "temperature_transport_anomaly_arr", prev_field = "", owner = "climate.feedback" },
	{ name = &"cell.vegetation_heat_stress", cpp_name = "cell_vegetation_heat_stress", dtype = F32, track_prev = false, map_field = "vegetation_heat_stress_arr", prev_field = "", owner = "climate.vegetation_dynamics" },
	{ name = &"cell.vegetation_drought_stress", cpp_name = "cell_vegetation_drought_stress", dtype = F32, track_prev = false, map_field = "vegetation_drought_stress_arr", prev_field = "", owner = "climate.vegetation_dynamics" },
	{ name = &"cell.vegetation_cold_stress", cpp_name = "cell_vegetation_cold_stress", dtype = F32, track_prev = false, map_field = "vegetation_cold_stress_arr", prev_field = "", owner = "climate.vegetation_dynamics" },
	{ name = &"cell.vegetation_regen_score", cpp_name = "cell_vegetation_regen_score", dtype = F32, track_prev = false, map_field = "vegetation_regen_score_arr", prev_field = "", owner = "climate.vegetation_dynamics" },
	# ─── Runtime hydrology（生成期拓扑 + 日级动态径流）──────────────────────
	{ name = &"cell.hydro_parent", cpp_name = "cell_hydro_parent", dtype = I32, track_prev = false, map_field = "hydro_parent_arr", prev_field = "", owner = "map_generation" },
	{ name = &"cell.river_discharge", cpp_name = "cell_river_discharge", dtype = F32, track_prev = false, map_field = "river_discharge_arr", prev_field = "", owner = "runtime.hydrology" },
	{ name = &"cell.river_discharge_30d", cpp_name = "cell_river_discharge_30d", dtype = F32, track_prev = false, map_field = "river_discharge_30d_arr", prev_field = "", owner = "runtime.hydrology" },
	{ name = &"cell.river_storage", cpp_name = "cell_river_storage", dtype = F32, track_prev = false, map_field = "river_storage_arr", prev_field = "", owner = "runtime.hydrology" },
	{ name = &"cell.groundwater_storage", cpp_name = "cell_groundwater_storage", dtype = F32, track_prev = false, map_field = "groundwater_storage_arr", prev_field = "", owner = "runtime.hydrology" },
	{ name = &"cell.surface_runoff", cpp_name = "cell_surface_runoff", dtype = F32, track_prev = false, map_field = "surface_runoff_arr", prev_field = "", owner = "runtime.hydrology" },
	# ─── Natural resources：per-cell 资源储量（economy.resources）──────────
	{ name = &"cell.res_timber_reserve", cpp_name = "cell_res_timber_reserve", dtype = F32, track_prev = false, map_field = "res_timber_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_stone_reserve", cpp_name = "cell_res_stone_reserve", dtype = F32, track_prev = false, map_field = "res_stone_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_fertile_soil_reserve", cpp_name = "cell_res_fertile_soil_reserve", dtype = F32, track_prev = false, map_field = "res_fertile_soil_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_coal_reserve", cpp_name = "cell_res_coal_reserve", dtype = F32, track_prev = false, map_field = "res_coal_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_oil_reserve", cpp_name = "cell_res_oil_reserve", dtype = F32, track_prev = false, map_field = "res_oil_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_natural_gas_reserve", cpp_name = "cell_res_natural_gas_reserve", dtype = F32, track_prev = false, map_field = "res_natural_gas_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_copper_ore_reserve", cpp_name = "cell_res_copper_ore_reserve", dtype = F32, track_prev = false, map_field = "res_copper_ore_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_iron_ore_reserve", cpp_name = "cell_res_iron_ore_reserve", dtype = F32, track_prev = false, map_field = "res_iron_ore_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_gold_ore_reserve", cpp_name = "cell_res_gold_ore_reserve", dtype = F32, track_prev = false, map_field = "res_gold_ore_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_silver_ore_reserve", cpp_name = "cell_res_silver_ore_reserve", dtype = F32, track_prev = false, map_field = "res_silver_ore_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_salt_reserve", cpp_name = "cell_res_salt_reserve", dtype = F32, track_prev = false, map_field = "res_salt_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_saltpeter_reserve", cpp_name = "cell_res_saltpeter_reserve", dtype = F32, track_prev = false, map_field = "res_saltpeter_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_rare_earth_reserve", cpp_name = "cell_res_rare_earth_reserve", dtype = F32, track_prev = false, map_field = "res_rare_earth_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_clay_reserve", cpp_name = "cell_res_clay_reserve", dtype = F32, track_prev = false, map_field = "res_clay_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_wild_game_reserve", cpp_name = "cell_res_wild_game_reserve", dtype = F32, track_prev = false, map_field = "res_wild_game_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_marine_fish_reserve", cpp_name = "cell_res_marine_fish_reserve", dtype = F32, track_prev = false, map_field = "res_marine_fish_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_arable_land_reserve", cpp_name = "cell_res_arable_land_reserve", dtype = F32, track_prev = false, map_field = "res_arable_land_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_paddy_land_reserve", cpp_name = "cell_res_paddy_land_reserve", dtype = F32, track_prev = false, map_field = "res_paddy_land_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_plantation_land_reserve", cpp_name = "cell_res_plantation_land_reserve", dtype = F32, track_prev = false, map_field = "res_plantation_land_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_pasture_reserve", cpp_name = "cell_res_pasture_reserve", dtype = F32, track_prev = false, map_field = "res_pasture_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_bauxite_reserve", cpp_name = "cell_res_bauxite_reserve", dtype = F32, track_prev = false, map_field = "res_bauxite_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_limestone_reserve", cpp_name = "cell_res_limestone_reserve", dtype = F32, track_prev = false, map_field = "res_limestone_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_silica_sand_reserve", cpp_name = "cell_res_silica_sand_reserve", dtype = F32, track_prev = false, map_field = "res_silica_sand_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_phosphate_rock_reserve", cpp_name = "cell_res_phosphate_rock_reserve", dtype = F32, track_prev = false, map_field = "res_phosphate_rock_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_tin_ore_reserve", cpp_name = "cell_res_tin_ore_reserve", dtype = F32, track_prev = false, map_field = "res_tin_ore_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_lead_ore_reserve", cpp_name = "cell_res_lead_ore_reserve", dtype = F32, track_prev = false, map_field = "res_lead_ore_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_zinc_ore_reserve", cpp_name = "cell_res_zinc_ore_reserve", dtype = F32, track_prev = false, map_field = "res_zinc_ore_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_manganese_ore_reserve", cpp_name = "cell_res_manganese_ore_reserve", dtype = F32, track_prev = false, map_field = "res_manganese_ore_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_sulfur_reserve", cpp_name = "cell_res_sulfur_reserve", dtype = F32, track_prev = false, map_field = "res_sulfur_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_flint_reserve", cpp_name = "cell_res_flint_reserve", dtype = F32, track_prev = false, map_field = "res_flint_reserve_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_timber_extra_change", cpp_name = "cell_res_timber_extra_change", dtype = F32, track_prev = false, map_field = "res_timber_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_stone_extra_change", cpp_name = "cell_res_stone_extra_change", dtype = F32, track_prev = false, map_field = "res_stone_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_fertile_soil_extra_change", cpp_name = "cell_res_fertile_soil_extra_change", dtype = F32, track_prev = false, map_field = "res_fertile_soil_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_coal_extra_change", cpp_name = "cell_res_coal_extra_change", dtype = F32, track_prev = false, map_field = "res_coal_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_oil_extra_change", cpp_name = "cell_res_oil_extra_change", dtype = F32, track_prev = false, map_field = "res_oil_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_natural_gas_extra_change", cpp_name = "cell_res_natural_gas_extra_change", dtype = F32, track_prev = false, map_field = "res_natural_gas_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_copper_ore_extra_change", cpp_name = "cell_res_copper_ore_extra_change", dtype = F32, track_prev = false, map_field = "res_copper_ore_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_iron_ore_extra_change", cpp_name = "cell_res_iron_ore_extra_change", dtype = F32, track_prev = false, map_field = "res_iron_ore_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_gold_ore_extra_change", cpp_name = "cell_res_gold_ore_extra_change", dtype = F32, track_prev = false, map_field = "res_gold_ore_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_silver_ore_extra_change", cpp_name = "cell_res_silver_ore_extra_change", dtype = F32, track_prev = false, map_field = "res_silver_ore_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_salt_extra_change", cpp_name = "cell_res_salt_extra_change", dtype = F32, track_prev = false, map_field = "res_salt_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_saltpeter_extra_change", cpp_name = "cell_res_saltpeter_extra_change", dtype = F32, track_prev = false, map_field = "res_saltpeter_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_rare_earth_extra_change", cpp_name = "cell_res_rare_earth_extra_change", dtype = F32, track_prev = false, map_field = "res_rare_earth_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_clay_extra_change", cpp_name = "cell_res_clay_extra_change", dtype = F32, track_prev = false, map_field = "res_clay_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_wild_game_extra_change", cpp_name = "cell_res_wild_game_extra_change", dtype = F32, track_prev = false, map_field = "res_wild_game_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_marine_fish_extra_change", cpp_name = "cell_res_marine_fish_extra_change", dtype = F32, track_prev = false, map_field = "res_marine_fish_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_arable_land_extra_change", cpp_name = "cell_res_arable_land_extra_change", dtype = F32, track_prev = false, map_field = "res_arable_land_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_paddy_land_extra_change", cpp_name = "cell_res_paddy_land_extra_change", dtype = F32, track_prev = false, map_field = "res_paddy_land_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_plantation_land_extra_change", cpp_name = "cell_res_plantation_land_extra_change", dtype = F32, track_prev = false, map_field = "res_plantation_land_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_pasture_extra_change", cpp_name = "cell_res_pasture_extra_change", dtype = F32, track_prev = false, map_field = "res_pasture_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_bauxite_extra_change", cpp_name = "cell_res_bauxite_extra_change", dtype = F32, track_prev = false, map_field = "res_bauxite_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_limestone_extra_change", cpp_name = "cell_res_limestone_extra_change", dtype = F32, track_prev = false, map_field = "res_limestone_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_silica_sand_extra_change", cpp_name = "cell_res_silica_sand_extra_change", dtype = F32, track_prev = false, map_field = "res_silica_sand_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_phosphate_rock_extra_change", cpp_name = "cell_res_phosphate_rock_extra_change", dtype = F32, track_prev = false, map_field = "res_phosphate_rock_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_tin_ore_extra_change", cpp_name = "cell_res_tin_ore_extra_change", dtype = F32, track_prev = false, map_field = "res_tin_ore_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_lead_ore_extra_change", cpp_name = "cell_res_lead_ore_extra_change", dtype = F32, track_prev = false, map_field = "res_lead_ore_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_zinc_ore_extra_change", cpp_name = "cell_res_zinc_ore_extra_change", dtype = F32, track_prev = false, map_field = "res_zinc_ore_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_manganese_ore_extra_change", cpp_name = "cell_res_manganese_ore_extra_change", dtype = F32, track_prev = false, map_field = "res_manganese_ore_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_sulfur_extra_change", cpp_name = "cell_res_sulfur_extra_change", dtype = F32, track_prev = false, map_field = "res_sulfur_extra_change_arr", prev_field = "", owner = "economy.resources" },
	{ name = &"cell.res_flint_extra_change", cpp_name = "cell_res_flint_extra_change", dtype = F32, track_prev = false, map_field = "res_flint_extra_change_arr", prev_field = "", owner = "economy.resources" },
	# ─── Demo-only（1 条，performance-charter §12.6 reference impl）────────
	# 仅在 ClimateProfile.demo_thermal_gradient_enabled=true 时被 bind_map_data
	# attach；为 false 时跳过，不占内存。
	{ name = &"cell.demo.thermal_gradient", cpp_name = "cell_demo_thermal_gradient", dtype = F32, track_prev = false, map_field = "demo_thermal_gradient_arr", prev_field = "", owner = "demo.thermal_gradient", demo = true },
]


## 遍历全部条目（含 demo）。调用方根据需要过滤 demo 字段。
## 返回 Array[Dictionary]。
static func entries() -> Array:
	return CELL_SCHEMA


## 仅遍历非 demo 条目（生产 bind 路径用）。
## 性能：每次调用都会过滤一遍；调用方应在 bind_map_data 启动期一次性遍历，
## 不要进 hot loop。
static func entries_production() -> Array:
	var out: Array = []
	for e in CELL_SCHEMA:
		if not bool(e.get("demo", false)):
			out.append(e)
	return out


## 仅遍历 demo 条目。
static func entries_demo() -> Array:
	var out: Array = []
	for e in CELL_SCHEMA:
		if bool(e.get("demo", false)):
			out.append(e)
	return out


## 按 GDScript-side StringName 查表（如 &"cell.temp"）。
## 不存在返回空 Dictionary（注意：GDScript 里 {} 才是空 dict，null 表示函数返回值缺失）。
static func find_by_name(comp_name: StringName) -> Dictionary:
	for e in CELL_SCHEMA:
		if e.name == comp_name:
			return e
	return {}


## 按 C++-side underscore 名查表（如 "cell_temp"）。
## codegen / debug 工具用。
static func find_by_cpp_name(cpp_name: String) -> Dictionary:
	for e in CELL_SCHEMA:
		if String(e.cpp_name) == cpp_name:
			return e
	return {}


## 全部条目数量（含 demo）。
static func count() -> int:
	return CELL_SCHEMA.size()


## 单个 entry 是否合法（启动期 sanity check 用，不进 hot loop）。
##  - name / cpp_name / map_field 必须非空
##  - dtype 必须是 F32 / I32 / U8
##  - track_prev=true 时 prev_field 必须非空
static func validate_entry(e: Dictionary) -> String:
	if not e.has("name") or e.name == &"":
		return "missing 'name'"
	if not e.has("cpp_name") or String(e.cpp_name) == "":
		return "missing 'cpp_name'"
	if not e.has("map_field") or String(e.map_field) == "":
		return "missing 'map_field'"
	if not e.has("dtype") or (int(e.dtype) != F32 and int(e.dtype) != I32 and int(e.dtype) != U8):
		return "invalid 'dtype' (must be F32 / I32 / U8)"
	if bool(e.get("track_prev", false)):
		if not e.has("prev_field") or String(e.prev_field) == "":
			return "track_prev=true requires non-empty 'prev_field'"
	return ""  # OK


## 启动期一次性自检：遍历所有条目调用 validate_entry，第一个失败返回错误描述，
## 全部通过返回空字符串。bind_map_data 入口可调此函数，违反纪律 push_error。
static func validate_all() -> String:
	for i in range(CELL_SCHEMA.size()):
		var e: Dictionary = CELL_SCHEMA[i]
		var err: String = validate_entry(e)
		if err != "":
			return "[CELL_SCHEMA[%d]] %s — entry=%s" % [i, err, str(e)]
	return ""
