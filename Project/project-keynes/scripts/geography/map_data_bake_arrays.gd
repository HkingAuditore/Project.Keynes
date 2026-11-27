extends RefCounted


static func _alloc_soa(owner: Variant, n: int) -> void:
	owner.temp_arr.resize(n);              owner.temp_arr_prev.resize(n)
	owner.moisture_arr.resize(n);          owner.moisture_arr_prev.resize(n)
	owner.snow_cover_arr.resize(n);        owner.snow_cover_arr_prev.resize(n)
	owner.temp_baseline_arr.resize(n)
	owner.temp_30d_arr.resize(n)
	owner.temp_365d_arr.resize(n)
	owner.temp_anomaly_arr.resize(n)
	owner.sea_ice_frac_arr.resize(n);      owner.sea_ice_frac_arr_prev.resize(n)
	owner.weather_intensity_arr.resize(n)
	owner.weather_cloud_arr.resize(n)
	owner.weather_cloud_water_arr.resize(n)
	owner.weather_precip_arr.resize(n)
	owner.weather_transition_alpha_arr.resize(n)
	owner.weather_classification_temp_arr.resize(n)
	owner.weather_classification_moisture_arr.resize(n)
	owner.elevation_arr.resize(n)
	owner.base_moisture_arr.resize(n)
	owner.ocean_current_x_arr.resize(n)
	owner.ocean_current_y_arr.resize(n)
	owner.wind_x_arr.resize(n)
	owner.wind_y_arr.resize(n)
	owner.slp_arr.resize(n)
	owner.wind_speed_arr.resize(n)
	owner.upwelling_strength_arr.resize(n)
	owner.wind_stress_curl_arr.resize(n)
	owner.ocean_psi_arr.resize(n)
	owner.cell_pos_x_arr.resize(n)
	owner.cell_pos_y_arr.resize(n)
	owner.cell_lat_norm_arr.resize(n)
	owner.temp_baseline_year_arr.resize(n)
	owner.terrain_arr.resize(n)
	owner.landform_arr.resize(n)
	owner.vegetation_arr.resize(n)
	owner.base_terrain_arr.resize(n)
	owner.base_landform_arr.resize(n)
	owner.base_vegetation_arr.resize(n)
	owner.cover_arr.resize(n)
	owner.weather_type_arr.resize(n)
	owner.weather_prev_type_arr.resize(n)
	owner.weather_target_type_arr.resize(n)
	owner.is_water_arr.resize(n)
	owner.country_slot_arr.resize(n)
	owner.visible_arr.resize(n)
	owner.explored_arr.resize(n)
	owner.fog_k_arr.resize(n)
	owner.resource_habitat_mask_arr.resize(n)
	owner.climate_dirty_mask.resize(n)
	owner.weather_dirty_mask.resize(n)
	# B-full Step-2：6 个新 SoA 字段一次性 resize
	owner.weather_vapor_arr.resize(n)
	owner.weather_convergence_arr.resize(n)
	owner.weather_instability_arr.resize(n)
	owner.weather_field_init_arr.resize(n)
	owner.air_mass_temp_anomaly_arr.resize(n)
	owner.has_river_arr.resize(n)
	owner.river_flow_arr.resize(n)
	owner.river_downstream_arr.resize(n)
	owner.has_volcano_arr.resize(n)
	owner.is_lake_seed_arr.resize(n)
	owner.hydro_parent_arr.resize(n)
	owner.river_discharge_arr.resize(n)
	owner.river_discharge_30d_arr.resize(n)
	owner.river_storage_arr.resize(n)
	owner.groundwater_storage_arr.resize(n)
	owner.surface_runoff_arr.resize(n)
	owner.canal_edge_mask_arr.resize(n)
	owner.canal_water_arr.resize(n)
	# Natural resources：per-cell 资源储量字段
	owner.res_timber_reserve_arr.resize(n)
	owner.res_stone_reserve_arr.resize(n)
	owner.res_fertile_soil_reserve_arr.resize(n)
	owner.res_coal_reserve_arr.resize(n)
	owner.res_oil_reserve_arr.resize(n)
	owner.res_natural_gas_reserve_arr.resize(n)
	owner.res_copper_ore_reserve_arr.resize(n)
	owner.res_iron_ore_reserve_arr.resize(n)
	owner.res_gold_ore_reserve_arr.resize(n)
	owner.res_silver_ore_reserve_arr.resize(n)
	owner.res_salt_reserve_arr.resize(n)
	owner.res_saltpeter_reserve_arr.resize(n)
	owner.res_rare_earth_reserve_arr.resize(n)
	owner.res_clay_reserve_arr.resize(n)
	owner.res_wild_game_reserve_arr.resize(n)
	owner.res_marine_fish_reserve_arr.resize(n)
	owner.res_freshwater_fish_reserve_arr.resize(n)
	owner.res_arable_land_reserve_arr.resize(n)
	owner.res_paddy_land_reserve_arr.resize(n)
	owner.res_plantation_land_reserve_arr.resize(n)
	owner.res_pasture_reserve_arr.resize(n)
	owner.res_bauxite_reserve_arr.resize(n)
	owner.res_limestone_reserve_arr.resize(n)
	owner.res_silica_sand_reserve_arr.resize(n)
	owner.res_phosphate_rock_reserve_arr.resize(n)
	owner.res_tin_ore_reserve_arr.resize(n)
	owner.res_lead_ore_reserve_arr.resize(n)
	owner.res_zinc_ore_reserve_arr.resize(n)
	owner.res_manganese_ore_reserve_arr.resize(n)
	owner.res_sulfur_reserve_arr.resize(n)
	owner.res_flint_reserve_arr.resize(n)
	owner.res_timber_extra_change_arr.resize(n)
	owner.res_stone_extra_change_arr.resize(n)
	owner.res_fertile_soil_extra_change_arr.resize(n)
	owner.res_coal_extra_change_arr.resize(n)
	owner.res_oil_extra_change_arr.resize(n)
	owner.res_natural_gas_extra_change_arr.resize(n)
	owner.res_copper_ore_extra_change_arr.resize(n)
	owner.res_iron_ore_extra_change_arr.resize(n)
	owner.res_gold_ore_extra_change_arr.resize(n)
	owner.res_silver_ore_extra_change_arr.resize(n)
	owner.res_salt_extra_change_arr.resize(n)
	owner.res_saltpeter_extra_change_arr.resize(n)
	owner.res_rare_earth_extra_change_arr.resize(n)
	owner.res_clay_extra_change_arr.resize(n)
	owner.res_wild_game_extra_change_arr.resize(n)
	owner.res_marine_fish_extra_change_arr.resize(n)
	owner.res_freshwater_fish_extra_change_arr.resize(n)
	owner.res_arable_land_extra_change_arr.resize(n)
	owner.res_paddy_land_extra_change_arr.resize(n)
	owner.res_plantation_land_extra_change_arr.resize(n)
	owner.res_pasture_extra_change_arr.resize(n)
	owner.res_bauxite_extra_change_arr.resize(n)
	owner.res_limestone_extra_change_arr.resize(n)
	owner.res_silica_sand_extra_change_arr.resize(n)
	owner.res_phosphate_rock_extra_change_arr.resize(n)
	owner.res_tin_ore_extra_change_arr.resize(n)
	owner.res_lead_ore_extra_change_arr.resize(n)
	owner.res_zinc_ore_extra_change_arr.resize(n)
	owner.res_manganese_ore_extra_change_arr.resize(n)
	owner.res_sulfur_extra_change_arr.resize(n)
	owner.res_flint_extra_change_arr.resize(n)
	# A 修复（climate-temp-pingpong-fix-2026-06）：anomaly 合成新增 2 个字段
	owner.ocean_thermal_anomaly_arr.resize(n)
	owner.local_thermal_anomaly_arr.resize(n)
	# Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个字段
	owner.ema_initialized_arr.resize(n)
	owner.temp_season_offset_arr.resize(n)
	owner.insolation_now_arr.resize(n)
	owner.insolation_dev_arr.resize(n)
	owner.day_length_arr.resize(n)
	owner.heat_input_arr.resize(n)
	owner.thermal_energy_arr.resize(n)
	owner.snowpack_arr.resize(n)
	owner.water_balance_30d_arr.resize(n)
	# B3b：植被动力学字段全量下沉 SoA（4 f32 + 2 i32）
	owner.vegetation_vitality_arr.resize(n)
	owner.vitality_low_streak_arr.resize(n)
	owner.vitality_high_streak_arr.resize(n)
	owner.soil_moisture_arr.resize(n)
	owner.plant_available_water_arr.resize(n)
	owner.vegetation_growth_pressure_arr.resize(n)
	owner.temperature_transport_anomaly_arr.resize(n)
	owner.vegetation_heat_stress_arr.resize(n)
	owner.vegetation_drought_stress_arr.resize(n)
	owner.vegetation_cold_stress_arr.resize(n)
	owner.vegetation_regen_score_arr.resize(n)
	owner.bio_occupancy_bits_arr.resize(n)
	owner.landmass_id_arr.resize(n)
	owner.province_id_arr.resize(n)


static func _prepare_bake_soa(owner: Variant) -> PackedInt32Array:
	var n: int = owner._cell_array.size()
	var seed: PackedInt32Array = owner.hydro_parent_arr.duplicate()
	owner._alloc_soa(n)
	owner.fog_solved = false
	owner.physical_visible_arr = PackedByteArray()
	return seed


static func _copy_bake_cells(owner: Variant, begin: int, end: int, hydro_parent_seed: PackedInt32Array) -> void:
	var n: int = owner._cell_array.size()
	for i in range(begin,end):
		var c: HexCell = owner._cell_array[i]
		owner.temp_arr[i] = c.temperature
		owner.moisture_arr[i] = c.moisture
		owner.snow_cover_arr[i] = c.snow_cover
		owner.temp_baseline_arr[i] = c.temp_baseline
		owner.temp_30d_arr[i] = c.temp_30d_mean
		owner.temp_365d_arr[i] = c.temp_365d_mean
		owner.temp_anomaly_arr[i] = c.temp_dev_from_annual
		owner.sea_ice_frac_arr[i] = c.sea_ice_fraction
		owner.weather_intensity_arr[i] = c.weather_intensity
		owner.weather_cloud_arr[i] = c.weather_cloud
		owner.weather_cloud_water_arr[i] = c.weather_cloud * 0.5 if c.weather_field_initialized else 0.0
		owner.weather_precip_arr[i] = c.weather_precip
		owner.weather_transition_alpha_arr[i] = c.weather_transition_alpha
		owner.weather_classification_temp_arr[i] = c.temperature
		owner.weather_classification_moisture_arr[i] = c.moisture
		owner.elevation_arr[i] = c.elevation
		owner.base_moisture_arr[i] = c.base_moisture
		owner.ocean_current_x_arr[i] = c.ocean_current.x
		owner.ocean_current_y_arr[i] = c.ocean_current.y
		owner.wind_x_arr[i] = c.wind_vector.x
		owner.wind_y_arr[i] = c.wind_vector.y
		owner.slp_arr[i] = c.slp
		owner.wind_speed_arr[i] = c.wind_speed
		owner.upwelling_strength_arr[i] = c.upwelling_strength
		owner.wind_stress_curl_arr[i] = c.wind_stress_curl
		owner.ocean_psi_arr[i] = c.ocean_psi
		var wp: Vector2 = HexUtils.cube_to_world(c.q, c.r, 1.0)
		owner.cell_pos_x_arr[i] = wp.x
		owner.cell_pos_y_arr[i] = wp.y
		owner.terrain_arr[i] = int(c.terrain) & 0xFF
		owner.landform_arr[i] = c.landform & 0xFF
		owner.vegetation_arr[i] = c.vegetation & 0xFF
		owner.base_terrain_arr[i] = int(c.base_terrain) & 0xFF
		owner.base_landform_arr[i] = c.base_landform & 0xFF
		owner.base_vegetation_arr[i] = c.base_vegetation & 0xFF
		owner.cover_arr[i] = c.cover & 0xFF
		owner.weather_type_arr[i] = c.weather_type & 0xFF
		owner.weather_prev_type_arr[i] = c.weather_prev_type & 0xFF
		owner.weather_target_type_arr[i] = c.weather_target_type & 0xFF
		owner.is_water_arr[i] = MapData.terrain_is_water_u8(int(owner.terrain_arr[i]))
		owner.country_slot_arr[i] = -1
		# 视野：纯运行期 SoA（无 HexCell 镜像）。全图未探索起步，由 VisionSolver
		# 在 country bootstrap 后首解；存档恢复时 explored 由 PKFG 覆盖。
		owner.visible_arr[i] = 0
		owner.explored_arr[i] = 0
		owner.fog_k_arr[i] = 0
		owner.climate_dirty_mask[i] = 0
		owner.weather_dirty_mask[i] = 0
		# B-full Step-2：6 个新字段 AoS → SoA 一次性镜像
		owner.weather_vapor_arr[i] = c.weather_vapor
		owner.weather_convergence_arr[i] = c.weather_convergence
		owner.weather_instability_arr[i] = c.weather_instability
		owner.weather_field_init_arr[i] = (1 if c.weather_field_initialized else 0)
		owner.air_mass_temp_anomaly_arr[i] = c.air_mass_temp_anomaly
		owner.has_river_arr[i] = (1 if c.has_river else 0)
		owner.river_flow_arr[i] = c.river_flow
		owner.has_volcano_arr[i] = (1 if c.has_volcano else 0)
		owner.is_lake_seed_arr[i] = (1 if c.is_lake_seed else 0)
		var downstream_idx: int = -1
		if c.has_river_downstream:
			var downstream_cell: HexCell = owner.get_cell_by_cube(c.river_downstream)
			downstream_idx = int(owner._cell_index.get(downstream_cell, -1)) if downstream_cell != null else -1
		owner.river_downstream_arr[i] = downstream_idx
		var hydro_parent_idx: int = int(hydro_parent_seed[i]) if hydro_parent_seed.size() == n else -1
		owner.hydro_parent_arr[i] = hydro_parent_idx if hydro_parent_idx >= -1 and hydro_parent_idx < n else -1
		owner.river_discharge_arr[i] = maxf(0.0, owner.river_flow_arr[i] if owner.has_river_arr[i] != 0 else 0.0)
		owner.river_discharge_30d_arr[i] = owner.river_discharge_arr[i]
		owner.river_storage_arr[i] = 0.0
		owner.groundwater_storage_arr[i] = 0.0
		owner.surface_runoff_arr[i] = 0.0
		owner.canal_edge_mask_arr[i] = 0
		owner.canal_water_arr[i] = 0.0
		# Phase 3a Step 2.1.a：Pass-A SoA 化新增 2 个字段镜像
		owner.ema_initialized_arr[i] = (1 if c._ema_initialized else 0)
		owner.temp_season_offset_arr[i] = c.temp_season_offset
		owner.insolation_now_arr[i] = 0.0
		owner.insolation_dev_arr[i] = 0.0
		owner.day_length_arr[i] = 0.5
		owner.heat_input_arr[i] = 0.0
		owner.thermal_energy_arr[i] = c.temperature
		owner.snowpack_arr[i] = 0.8 if c.cover == CoverType.CV.GLACIER else clampf(c.snow_cover * 0.35, 0.0, 1.0)
		owner.water_balance_30d_arr[i] = 0.0
		# B3b：植被动力学字段全量下沉 SoA — bake 期一次性从 HexCell 镜像初值
		var has_live_vegetation: bool = owner.is_water_arr[i] == 0 and int(c.vegetation) != int(VegetationType.VEG.NONE)
		owner.vegetation_vitality_arr[i] = c.vegetation_vitality if has_live_vegetation else 0.0
		owner.vitality_low_streak_arr[i] = c._vitality_low_streak if has_live_vegetation else 0
		owner.vitality_high_streak_arr[i] = c._vitality_high_streak if has_live_vegetation else 0
		owner.soil_moisture_arr[i] = c.soil_moisture
		owner.vegetation_growth_pressure_arr[i] = c.vegetation_growth_pressure if has_live_vegetation else 0.0
		owner.temperature_transport_anomaly_arr[i] = c.temperature_transport_anomaly
		owner.vegetation_heat_stress_arr[i] = c.vegetation_heat_stress if has_live_vegetation else 0.0
		owner.vegetation_drought_stress_arr[i] = c.vegetation_drought_stress if has_live_vegetation else 0.0
		owner.vegetation_cold_stress_arr[i] = c.vegetation_cold_stress if has_live_vegetation else 0.0
		owner.vegetation_regen_score_arr[i] = c.vegetation_regen_score if has_live_vegetation else 0.0


static func _finish_bake_soa(owner: Variant) -> void:
	owner.ocean_thermal_anomaly_arr.fill(0.0)
	owner.local_thermal_anomaly_arr.fill(0.0)
	owner.res_timber_reserve_arr.fill(0.0)
	owner.res_stone_reserve_arr.fill(0.0)
	owner.res_fertile_soil_reserve_arr.fill(0.0)
	owner.res_coal_reserve_arr.fill(0.0)
	owner.res_oil_reserve_arr.fill(0.0)
	owner.res_natural_gas_reserve_arr.fill(0.0)
	owner.res_copper_ore_reserve_arr.fill(0.0)
	owner.res_iron_ore_reserve_arr.fill(0.0)
	owner.res_gold_ore_reserve_arr.fill(0.0)
	owner.res_silver_ore_reserve_arr.fill(0.0)
	owner.res_salt_reserve_arr.fill(0.0)
	owner.res_saltpeter_reserve_arr.fill(0.0)
	owner.res_rare_earth_reserve_arr.fill(0.0)
	owner.res_clay_reserve_arr.fill(0.0)
	owner.res_wild_game_reserve_arr.fill(0.0)
	owner.res_marine_fish_reserve_arr.fill(0.0)
	owner.res_freshwater_fish_reserve_arr.fill(0.0)
	owner.res_arable_land_reserve_arr.fill(0.0)
	owner.res_paddy_land_reserve_arr.fill(0.0)
	owner.res_plantation_land_reserve_arr.fill(0.0)
	owner.res_pasture_reserve_arr.fill(0.0)
	owner.res_bauxite_reserve_arr.fill(0.0)
	owner.res_limestone_reserve_arr.fill(0.0)
	owner.res_silica_sand_reserve_arr.fill(0.0)
	owner.res_phosphate_rock_reserve_arr.fill(0.0)
	owner.res_tin_ore_reserve_arr.fill(0.0)
	owner.res_lead_ore_reserve_arr.fill(0.0)
	owner.res_zinc_ore_reserve_arr.fill(0.0)
	owner.res_manganese_ore_reserve_arr.fill(0.0)
	owner.res_sulfur_reserve_arr.fill(0.0)
	owner.res_flint_reserve_arr.fill(0.0)
	owner.res_timber_extra_change_arr.fill(0.0)
	owner.res_stone_extra_change_arr.fill(0.0)
	owner.res_fertile_soil_extra_change_arr.fill(0.0)
	owner.res_coal_extra_change_arr.fill(0.0)
	owner.res_oil_extra_change_arr.fill(0.0)
	owner.res_natural_gas_extra_change_arr.fill(0.0)
	owner.res_copper_ore_extra_change_arr.fill(0.0)
	owner.res_iron_ore_extra_change_arr.fill(0.0)
	owner.res_gold_ore_extra_change_arr.fill(0.0)
	owner.res_silver_ore_extra_change_arr.fill(0.0)
	owner.res_salt_extra_change_arr.fill(0.0)
	owner.res_saltpeter_extra_change_arr.fill(0.0)
	owner.res_rare_earth_extra_change_arr.fill(0.0)
	owner.res_clay_extra_change_arr.fill(0.0)
	owner.res_wild_game_extra_change_arr.fill(0.0)
	owner.res_marine_fish_extra_change_arr.fill(0.0)
	owner.res_freshwater_fish_extra_change_arr.fill(0.0)
	owner.res_arable_land_extra_change_arr.fill(0.0)
	owner.res_paddy_land_extra_change_arr.fill(0.0)
	owner.res_plantation_land_extra_change_arr.fill(0.0)
	owner.res_pasture_extra_change_arr.fill(0.0)
	owner.resource_habitat_mask_arr.fill(0)
	owner.res_bauxite_extra_change_arr.fill(0.0)
	owner.res_limestone_extra_change_arr.fill(0.0)
	owner.res_silica_sand_extra_change_arr.fill(0.0)
	owner.res_phosphate_rock_extra_change_arr.fill(0.0)
	owner.res_tin_ore_extra_change_arr.fill(0.0)
	owner.res_lead_ore_extra_change_arr.fill(0.0)
	owner.res_zinc_ore_extra_change_arr.fill(0.0)
	owner.res_manganese_ore_extra_change_arr.fill(0.0)
	owner.res_sulfur_extra_change_arr.fill(0.0)
	owner.res_flint_extra_change_arr.fill(0.0)
	# 同步初始化 _prev 双缓冲为 _next 当前快照，避免首日 sub-pass 切片读到 0。
	owner.temp_arr_prev = owner.temp_arr.duplicate()
	owner.moisture_arr_prev = owner.moisture_arr.duplicate()
	owner.snow_cover_arr_prev = owner.snow_cover_arr.duplicate()
	owner.sea_ice_frac_arr_prev = owner.sea_ice_frac_arr.duplicate()
	owner._soa_built = true
	# B1-A：lat / temp_year LUT 必须由 generator 在 _last_cfg 就位后 bake；
	# 这里仅置为未 bake 状态，bake_world 路径会立即调用 bake_lat_temp_year_lut()。
	owner._lat_lut_baked = false


static func apply_pending_generation_ecology(owner: Variant) -> void:
	if owner._pending_generation_ecology.is_empty():
		return
	var n: int = owner.cell_count()
	var fields := [
		"vegetation_vitality_arr", "soil_moisture_arr", "water_balance_30d_arr",
		"plant_available_water_arr", "vegetation_growth_pressure_arr",
		"vegetation_heat_stress_arr", "vegetation_drought_stress_arr",
		"vegetation_cold_stress_arr", "vegetation_regen_score_arr",
	]
	for field in fields:
		var value = owner._pending_generation_ecology.get(field, null)
		if value is PackedFloat32Array and value.size() == n:
			owner.set(field, value.duplicate())
	owner._pending_generation_ecology.clear()
