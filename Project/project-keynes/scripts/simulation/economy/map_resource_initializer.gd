extends "res://scripts/simulation/generator_context.gd"

const RESOURCE_SCALAR_STRIDE := 32

func _bootstrap_natural_resource_deposits(map_ref, cfg, cooperative: bool = false) -> void:
	if map_ref == null:
		return
	var n_cells: int = map_ref.cell_count()
	if n_cells <= 0:
		return
	var temp_arr: PackedFloat32Array = map_ref.temp_arr
	var moist_arr: PackedFloat32Array = map_ref.moisture_arr
	var terrain_arr: PackedByteArray = map_ref.terrain_arr
	var elev_arr: PackedFloat32Array = map_ref.elevation_arr
	var lf_arr: PackedByteArray = map_ref.landform_arr
	var veg_arr: PackedByteArray = map_ref.vegetation_arr
	var river_arr: PackedByteArray = map_ref.has_river_arr
	var lake_arr: PackedByteArray = map_ref.is_lake_seed_arr
	var volcano_arr: PackedByteArray = map_ref.has_volcano_arr
	var ocean_x_arr: PackedFloat32Array = map_ref.ocean_current_x_arr
	var ocean_y_arr: PackedFloat32Array = map_ref.ocean_current_y_arr
	var upwelling_arr: PackedFloat32Array = map_ref.upwelling_strength_arr
	var posx_arr: PackedFloat32Array = map_ref.cell_pos_x_arr
	var posy_arr: PackedFloat32Array = map_ref.cell_pos_y_arr
	var have_terrain: bool = terrain_arr.size() >= n_cells
	var have_elev: bool = elev_arr.size() >= n_cells
	var have_lf: bool = lf_arr.size() >= n_cells
	var have_veg: bool = veg_arr.size() >= n_cells
	var have_river: bool = river_arr.size() >= n_cells
	var have_lake: bool = lake_arr.size() >= n_cells
	var have_volcano: bool = volcano_arr.size() >= n_cells
	var have_ocean_current: bool = ocean_x_arr.size() >= n_cells and ocean_y_arr.size() >= n_cells
	var have_upwelling: bool = upwelling_arr.size() >= n_cells
	var have_pos: bool = posx_arr.size() >= n_cells and posy_arr.size() >= n_cells
	var neighbor_indices: PackedInt32Array = map_ref.neighbor_indices_packed()
	var have_neighbors: bool = neighbor_indices.size() >= n_cells * 6
	# habitat 掩码 / 河口羽流两段纯几何派生量：融合 pass 在 C++ 里与矿藏 pass
	# 一次算完；这里保留 GDScript 实现作为旧 DLL 兜底与 A/B 参考。
	var habitat_arr: PackedByteArray = await _collect_resource_habitat_mask(map_ref, cooperative)
	map_ref.resource_habitat_mask_arr = habitat_arr
	# River mouths are geography-derived productivity inputs, not resource access:
	# every cell still owns and exposes only its own reserve. Mark the river cell,
	# its ocean outlet, and a weaker one-ring marine plume.
	var estuary_strength_arr: PackedFloat32Array = await _collect_estuary_strength(
		map_ref, cooperative)
	# native-first：整段矿藏储量（O(资源 × cell) + 每资源排名分配）交给 C++ 一次算完。
	# 失败（旧 DLL / 形状不符）时继续走下面的 GDScript 路径，行为与迁移前一致。
	if _generator._try_bootstrap_natural_resources_native(map_ref, cfg, habitat_arr, estuary_strength_arr):
		return
	var base_seed: int = 0
	if cfg != null and cfg.get("seed") != null:
		base_seed = int(cfg.get("seed"))
	var province_noises: Dictionary = {}
	var belt_noises: Dictionary = {}
	for p in ResourceProfileRegistry.ordered():
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		if field == "":
			continue
		var arr: PackedFloat32Array = map_ref.get(field)
		if arr.size() < n_cells:
			arr.resize(n_cells)
		var lo: float = p.temp_lo
		var hi: float = p.temp_hi
		var inv_span: float = (1.0 / (hi - lo)) if hi > lo else 0.0
		var habitat_code: int = ResourceProfileRegistry.habitat_code(p)
		# 数据驱动「地块自身情况」因子（缺省 0/{} → 该因子不参与）。
		var w_elev: float = float(p.init_elevation)
		var w_river: float = float(p.init_river)
		var w_volc: float = float(p.init_volcano)
		var w_ocean_current: float = float(p.init_ocean_current)
		var w_upwelling: float = float(p.init_upwelling)
		var w_estuary: float = float(p.init_estuary)
		var w_noise: float = float(p.init_noise)
		var w_climate_fit: float = float(p.init_climate_fit)
		var reserve_scale: float = maxf(float(p.init_reserve_scale), 0.0) * \
			ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
		var lf_w: Dictionary = p.init_landform_weights
		var veg_w: Dictionary = p.init_vegetation_weights
		var excluded_terrain := {}
		if have_terrain:
			for terrain_id in p.init_excluded_terrain_ids:
				excluded_terrain[int(terrain_id)] = true
		var excluded_vegetation := {}
		if have_veg:
			for vegetation_id in p.init_excluded_vegetation_ids:
				excluded_vegetation[int(vegetation_id)] = true
		var floor_reserve: float = maxf(float(p.init_floor_reserve), 0.0) * \
			ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
		var use_elev: bool = have_elev and w_elev != 0.0
		var use_lf: bool = have_lf and not lf_w.is_empty()
		var use_veg: bool = have_veg and not veg_w.is_empty()
		var use_river: bool = w_river != 0.0 and (have_river or have_lake)
		var use_volc: bool = have_volcano and w_volc != 0.0
		var use_ocean_current: bool = have_ocean_current and w_ocean_current != 0.0
		var use_upwelling: bool = have_upwelling and w_upwelling != 0.0
		var use_estuary: bool = w_estuary != 0.0
		var use_noise: bool = have_pos and absf(w_noise) > 0.0
		var family_id := String(p.geology_family_id)
		var use_province := have_pos and not family_id.is_empty() and absf(p.init_province) > 0.0
		var use_belt := have_pos and not family_id.is_empty() and absf(p.init_belt) > 0.0
		var ranked_cells := []
		var target_coverage := clampf(float(p.init_target_coverage), 0.0, 1.0)
		var use_ranked_distribution := target_coverage > 0.0
		# 噪声按「资源」独立创建（map seed ⊕ 资源 id hash），保证可复现且各资源斑块互不重合。
		var noise: FastNoiseLite = null
		if use_noise:
			noise = FastNoiseLite.new()
			noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			noise.seed = base_seed ^ int(hash(p.id))
			noise.frequency = maxf(0.0001, float(p.init_noise_scale))
		var province_noise: FastNoiseLite = null
		if use_province:
			var province_key := "%s:%.6f" % [family_id, float(p.init_province_scale)]
			province_noise = province_noises.get(province_key)
			if province_noise == null:
				province_noise = FastNoiseLite.new()
				province_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
				province_noise.seed = base_seed ^ int(hash("province:" + family_id))
				province_noise.frequency = maxf(0.0001, float(p.init_province_scale))
				province_noises[province_key] = province_noise
		var belt_noise: FastNoiseLite = null
		if use_belt:
			var belt_key := "%s:%.6f" % [family_id, float(p.init_belt_scale)]
			belt_noise = belt_noises.get(belt_key)
			if belt_noise == null:
				belt_noise = FastNoiseLite.new()
				belt_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
				belt_noise.seed = base_seed ^ int(hash("belt:" + family_id))
				belt_noise.frequency = maxf(0.0001, float(p.init_belt_scale))
				belt_noises[belt_key] = belt_noise
		for i in range(n_cells):
			if cooperative and _generator._generation_slice_due():
				await _generator._yield_generation_frame()
				_generator._generation_slice_start_usec = Time.get_ticks_usec()
			if habitat_code > 0 and not ResourceProfileRegistry.habitat_available(
					p, int(habitat_arr[i])):
				arr[i] = 0.0
				continue
			if have_terrain and excluded_terrain.has(int(terrain_arr[i])):
				arr[i] = 0.0
				continue
			if have_veg and excluded_vegetation.has(int(veg_arr[i])):
				arr[i] = 0.0
				continue
			var temp_v: float = temp_arr[i] if i < temp_arr.size() else 0.0
			var m: float = moist_arr[i] if i < moist_arr.size() else 0.0
			var tn: float = clampf((temp_v - lo) * inv_span, 0.0, 1.0)
			var suit: float = p.init_base + p.init_temp * tn + p.init_moisture * m
			if w_climate_fit != 0.0:
				var temp_fit: float = 1.0 - clampf(absf(tn - p.climate_temp_opt) / maxf(p.climate_temp_tol, 0.0001), 0.0, 1.0)
				var moisture_fit: float = 1.0 - clampf(absf(m - p.climate_moisture_opt) / maxf(p.climate_moisture_tol, 0.0001), 0.0, 1.0)
				suit += w_climate_fit * temp_fit * moisture_fit
			if use_elev:
				suit += w_elev * clampf(elev_arr[i], 0.0, 1.0)
			if use_lf:
				suit += float(lf_w.get(int(lf_arr[i]), 0.0))
			if use_veg:
				suit += float(veg_w.get(int(veg_arr[i]), 0.0))
			if use_river:
				var water_feature: bool = (have_river and river_arr[i] != 0) or (have_lake and lake_arr[i] != 0)
				if water_feature:
					suit += w_river
			if use_volc and volcano_arr[i] != 0:
				suit += w_volc
			if use_ocean_current:
				var current_speed := sqrt(
					ocean_x_arr[i] * ocean_x_arr[i] + ocean_y_arr[i] * ocean_y_arr[i])
				suit += w_ocean_current * clampf(current_speed, 0.0, 1.0)
			if use_upwelling:
				suit += w_upwelling * clampf(upwelling_arr[i], 0.0, 1.0)
			if use_estuary:
				suit += w_estuary * estuary_strength_arr[i]
			if use_noise:
				suit += w_noise * ((noise.get_noise_2d(posx_arr[i], posy_arr[i]) + 1.0) * 0.5)
			if use_province:
				# 地质省是“有利/不利背景”而非全图正奖励；中心化后省外会压低储量，
				# 避免同一地块集齐大多数矿种，同时仍让同族矿物共享大尺度相关性。
				var province01 := (province_noise.get_noise_2d(posx_arr[i], posy_arr[i]) + 1.0) * 0.5
				suit += float(p.init_province) * (province01 - 0.55) * 2.0
			if use_belt:
				var belt_ridge := 1.0 - absf(belt_noise.get_noise_2d(posx_arr[i], posy_arr[i]))
				# ridge 高于阈值才形成矿带；其余区域施加负贡献，形成狭长稀疏矿脉。
				suit += float(p.init_belt) * (belt_ridge - 0.72) * 2.0
			arr[i] = maxf(0.0, suit) * reserve_scale
			if floor_reserve > 0.0:
				arr[i] = maxf(arr[i], floor_reserve)
			if use_ranked_distribution or (
					float(p.init_min_coverage) > 0.0 and float(p.init_min_reserve) > 0.0):
				ranked_cells.append({"cell": i, "suit": suit})
		var target_cells := 0
		if use_ranked_distribution:
			target_cells = mini(ranked_cells.size(), ceili(
				float(ranked_cells.size()) * target_coverage))
		else:
			target_cells = mini(ranked_cells.size(), ceili(
				float(ranked_cells.size()) * clampf(float(p.init_min_coverage), 0.0, 1.0)))
		if target_cells > 0:
			ranked_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				if not is_equal_approx(float(a.suit), float(b.suit)):
					return float(a.suit) > float(b.suit)
				return int(a.cell) < int(b.cell))
			if use_ranked_distribution:
				for ranked in ranked_cells:
					arr[int(ranked.cell)] = 0.0
				var micro_target := mini(
					ranked_cells.size() - target_cells,
					ceili(float(ranked_cells.size()) * clampf(
						float(p.init_micro_coverage), 0.0, 1.0)))
				var micro_cells := _select_micro_deposit_cells(
					ranked_cells, target_cells, micro_target,
					neighbor_indices, have_neighbors)
				var core_cells: Array = ranked_cells.slice(0, target_cells)
				var minimum_reserve := maxf(floor_reserve, float(p.init_min_reserve) * \
					ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE)
				var micro_minimum_reserve := maxf(
					float(p.init_micro_min_reserve), 0.0) * \
					ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
				var reserve_density := maxf(float(p.init_target_reserve_density), 0.0) * \
					ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
				var target_mean_reserve := maxf(float(p.init_target_mean_reserve), 0.0) * \
					ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
				if reserve_density > 0.0 or target_mean_reserve > 0.0:
					var target_total_reserve := reserve_density * ranked_cells.size() \
						if reserve_density > 0.0 else target_mean_reserve * target_cells
					var core_floor_total := minimum_reserve * core_cells.size()
					var micro_floor_total := micro_minimum_reserve * micro_cells.size()
					var total_reserve := maxf(
						target_total_reserve, core_floor_total + micro_floor_total)
					var micro_budget := total_reserve * clampf(
						float(p.init_micro_reserve_share), 0.0, 0.5) \
						if not micro_cells.is_empty() else 0.0
					micro_budget = maxf(micro_budget, micro_floor_total)
					micro_budget = minf(micro_budget, total_reserve - core_floor_total)
					_allocate_ranked_deposit_budget(
						arr, core_cells, total_reserve - micro_budget,
						minimum_reserve, maxf(float(p.init_richness_exponent), 0.1))
					_allocate_ranked_deposit_budget(
						arr, micro_cells, micro_budget,
						micro_minimum_reserve, 0.65)
				else:
					for rank in range(target_cells):
						var cell := int(ranked_cells[rank].cell)
						arr[cell] = maxf(arr[cell], minimum_reserve)
					for ranked in micro_cells:
						arr[int(ranked.cell)] = maxf(
							arr[int(ranked.cell)], micro_minimum_reserve)
			else:
				for rank in range(target_cells):
					var cell := int(ranked_cells[rank].cell)
					arr[cell] = maxf(arr[cell], float(p.init_min_reserve) * \
						ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE)
		map_ref.set(field, arr)


## 把整段矿藏储量生成交给 C++（`DCWorldExt.run_resource_deposit_pass`）。
##
## 旧 GDScript 路径是 O(资源 × cell)：2400 cell 实测 1.2s，桌面允许的 200k cell
## 会到分钟级；每格还要 append 一个 Dictionary，每资源一次 sort_custom(lambda)。
##
## 与旧路径同值的保证：噪声实例按旧路径同样的 seed（`base_seed ^ hash(id)`）
## 与 frequency 构造后传进 C++，C++ 只调用 `Noise.get_noise_2d()`；排名、小微
## 矿点、预算分配的规则逐行复刻（唯一差异是近似并列带的排序改成严格序）。
##
## 返回 true 表示已把每种资源的 reserve 列写回 MapData。

func _deposit_noise_instance(cache_key: String, seed_value: int,
		frequency: float) -> FastNoiseLite:
	var cached = _generator._deposit_noise_cache.get(cache_key)
	if cached != null:
		return cached
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed_value
	noise.frequency = maxf(0.0001, frequency)
	_generator._deposit_noise_cache[cache_key] = noise
	return noise


## 构造 run_resource_deposit_pass 的 knobs（**不含** habitat_mask / estuary 两列）。
## 这两列是纯几何派生量：融合 pass `run_boot_facade_pass` 会在 C++ 里现算后直接
## 填进同一份 knobs；旧 DLL 兜底路径仍由 `_bootstrap_natural_resource_deposits()`
## 的 GDScript 段现算后填入。两侧 knobs 除这两列外逐键相同，数值因此同源。
## 返回 {} 表示形状不支持（cell<=0 / 资源数为 0 / 标量表超限）。

func _build_resource_deposit_knobs(map_ref, cfg) -> Dictionary:
	var n_cells: int = map_ref.cell_count()
	if n_cells <= 0:
		return {}
	# 只保留有 reserve 字段的资源（旧路径对 field == "" 的资源直接 continue）。
	var rows: Array = []
	for p in ResourceProfileRegistry.ordered():
		if ResourceProfileRegistry.reserve_map_field(p) != "":
			rows.append(p)
	var resource_count := rows.size()
	if resource_count <= 0:
		return {}
	if resource_count * RESOURCE_SCALAR_STRIDE > 8192:
		return {}

	var base_seed: int = 0
	if cfg != null and cfg.get("seed") != null:
		base_seed = int(cfg.get("seed"))

	var posx_arr: PackedFloat32Array = map_ref.cell_pos_x_arr
	var posy_arr: PackedFloat32Array = map_ref.cell_pos_y_arr
	var have_pos: bool = posx_arr.size() >= n_cells and posy_arr.size() >= n_cells

	# 排除表摊平成 resource × width 的 byte 表：C++ 侧一次数组索引即可判定。
	var excluded_terrain_width := 1
	var excluded_veg_width := 1
	for p in rows:
		for terrain_id in p.init_excluded_terrain_ids:
			excluded_terrain_width = maxi(excluded_terrain_width, int(terrain_id) + 1)
		for vegetation_id in p.init_excluded_vegetation_ids:
			excluded_veg_width = maxi(excluded_veg_width, int(vegetation_id) + 1)
	var excluded_terrain := PackedByteArray()
	excluded_terrain.resize(resource_count * excluded_terrain_width)
	var excluded_vegetation := PackedByteArray()
	excluded_vegetation.resize(resource_count * excluded_veg_width)

	var scalars := PackedFloat32Array()
	scalars.resize(resource_count * RESOURCE_SCALAR_STRIDE)
	var field_names := PackedStringArray()
	var habitat_codes := PackedInt32Array()
	habitat_codes.resize(resource_count)
	var lf_keys := PackedInt32Array()
	var lf_vals := PackedFloat32Array()
	var lf_offsets := PackedInt32Array()
	lf_offsets.resize(resource_count + 1)
	var veg_keys := PackedInt32Array()
	var veg_vals := PackedFloat32Array()
	var veg_offsets := PackedInt32Array()
	veg_offsets.resize(resource_count + 1)
	var noise_refs: Array = []
	var province_refs: Array = []
	var belt_refs: Array = []
	var province_noises: Dictionary = {}
	var belt_noises: Dictionary = {}

	for r in range(resource_count):
		var p = rows[r]
		var base: int = r * RESOURCE_SCALAR_STRIDE
		scalars[base + 0] = float(p.init_base)
		scalars[base + 1] = float(p.init_temp)
		scalars[base + 2] = float(p.init_moisture)
		scalars[base + 3] = float(p.init_reserve_scale)
		scalars[base + 4] = float(p.init_floor_reserve)
		scalars[base + 5] = float(p.init_min_coverage)
		scalars[base + 6] = float(p.init_min_reserve)
		scalars[base + 7] = float(p.init_target_coverage)
		scalars[base + 8] = float(p.init_target_reserve_density)
		scalars[base + 9] = float(p.init_target_mean_reserve)
		scalars[base + 10] = float(p.init_richness_exponent)
		scalars[base + 11] = float(p.init_micro_coverage)
		scalars[base + 12] = float(p.init_micro_reserve_share)
		scalars[base + 13] = float(p.init_micro_min_reserve)
		scalars[base + 14] = float(p.init_elevation)
		scalars[base + 15] = float(p.init_river)
		scalars[base + 16] = float(p.init_volcano)
		scalars[base + 17] = float(p.init_ocean_current)
		scalars[base + 18] = float(p.init_upwelling)
		scalars[base + 19] = float(p.init_estuary)
		scalars[base + 20] = float(p.init_noise)
		scalars[base + 21] = float(p.init_province)
		scalars[base + 22] = float(p.init_belt)
		scalars[base + 23] = float(p.climate_temp_opt)
		scalars[base + 24] = float(p.climate_temp_tol)
		scalars[base + 25] = float(p.climate_moisture_opt)
		scalars[base + 26] = float(p.climate_moisture_tol)
		scalars[base + 27] = float(p.init_climate_fit)
		scalars[base + 28] = float(p.temp_lo)
		scalars[base + 29] = float(p.temp_hi)

		field_names.append(ResourceProfileRegistry.reserve_map_field(p))
		habitat_codes[r] = ResourceProfileRegistry.habitat_code(p)

		var lf_w: Dictionary = p.init_landform_weights
		for key in lf_w.keys():
			lf_keys.append(int(key))
			lf_vals.append(float(lf_w[key]))
		lf_offsets[r + 1] = lf_keys.size()
		var veg_w: Dictionary = p.init_vegetation_weights
		for key in veg_w.keys():
			veg_keys.append(int(key))
			veg_vals.append(float(veg_w[key]))
		veg_offsets[r + 1] = veg_keys.size()

		for terrain_id in p.init_excluded_terrain_ids:
			excluded_terrain[r * excluded_terrain_width + int(terrain_id)] = 1
		for vegetation_id in p.init_excluded_vegetation_ids:
			excluded_vegetation[r * excluded_veg_width + int(vegetation_id)] = 1

		# 噪声实例：与旧路径完全同 seed / 同 frequency（C++ 只负责取值）。
		# 实例按 (seed, 资源序号/地质家族, 类型) 复用：它们是构造函数参数的纯函数，
		# 但每次 new 出来的对象不保证逐位可复现，因此同一代地图内必须复用同一批实例
		# ——A/B 探针把「融合内联调用」和「探针重建 knobs」放在一起比较才成立。
		if have_pos and absf(float(p.init_noise)) > 0.0:
			noise_refs.append(_deposit_noise_instance(
				"%d|noise:%d" % [base_seed, r], base_seed ^ int(hash(p.id)),
				float(p.init_noise_scale)))
		else:
			noise_refs.append(null)
		var family_id := String(p.geology_family_id)
		if have_pos and not family_id.is_empty() and absf(float(p.init_province)) > 0.0:
			var province_key := "%s:%.6f" % [family_id, float(p.init_province_scale)]
			var province_noise = province_noises.get(province_key)
			if province_noise == null:
				province_noise = _deposit_noise_instance(
					"%d|province:%s" % [base_seed, province_key],
					base_seed ^ int(hash("province:" + family_id)),
					float(p.init_province_scale))
				province_noises[province_key] = province_noise
			province_refs.append(province_noise)
		else:
			province_refs.append(null)
		if have_pos and not family_id.is_empty() and absf(float(p.init_belt)) > 0.0:
			var belt_key := "%s:%.6f" % [family_id, float(p.init_belt_scale)]
			var belt_noise = belt_noises.get(belt_key)
			if belt_noise == null:
				belt_noise = _deposit_noise_instance(
					"%d|belt:%s" % [base_seed, belt_key],
					base_seed ^ int(hash("belt:" + family_id)),
					float(p.init_belt_scale))
				belt_noises[belt_key] = belt_noise
			belt_refs.append(belt_noise)
		else:
			belt_refs.append(null)

	var knobs := {
		"cell_count": n_cells,
		"temperature": map_ref.temp_arr,
		"moisture": map_ref.moisture_arr,
		"elevation": map_ref.elevation_arr,
		"terrain": map_ref.terrain_arr,
		"vegetation": map_ref.vegetation_arr,
		"landform": map_ref.landform_arr,
		"has_river": map_ref.has_river_arr,
		"is_lake": map_ref.is_lake_seed_arr,
		"has_volcano": map_ref.has_volcano_arr,
		"ocean_x": map_ref.ocean_current_x_arr,
		"ocean_y": map_ref.ocean_current_y_arr,
		"upwelling": map_ref.upwelling_strength_arr,
		"pos_x": posx_arr,
		"pos_y": posy_arr,
		"neighbor_indices": map_ref.neighbor_indices_packed(),
		"field_names": field_names,
		"habitat_codes": habitat_codes,
		"scalars": scalars,
		"lf_keys": lf_keys,
		"lf_vals": lf_vals,
		"lf_offsets": lf_offsets,
		"veg_keys": veg_keys,
		"veg_vals": veg_vals,
		"veg_offsets": veg_offsets,
		"excluded_terrain_width": excluded_terrain_width,
		"excluded_terrain": excluded_terrain,
		"excluded_vegetation_width": excluded_veg_width,
		"excluded_vegetation": excluded_vegetation,
		"noise": noise_refs,
		"province_noise": province_refs,
		"belt_noise": belt_refs,
	}
	return knobs


## 旧 DLL 兜底：把 habitat / estuary 两列补进 knobs 后单独跑矿藏 pass。

func _collect_resource_habitat_mask(map_ref, cooperative: bool = false) -> PackedByteArray:
	var n_cells: int = map_ref.cell_count()
	var water_arr: PackedByteArray = map_ref.is_water_arr
	var lf_arr: PackedByteArray = map_ref.landform_arr
	var river_arr: PackedByteArray = map_ref.has_river_arr
	var neighbor_indices: PackedInt32Array = map_ref.neighbor_indices_packed()
	var habitat_arr: PackedByteArray = map_ref.resource_habitat_mask_arr
	if habitat_arr.size() < n_cells:
		habitat_arr.resize(n_cells)
	var have_water: bool = water_arr.size() >= n_cells
	var have_lf: bool = lf_arr.size() >= n_cells
	var have_river: bool = river_arr.size() >= n_cells
	var have_neighbors: bool = neighbor_indices.size() >= n_cells * 6
	for i in range(n_cells):
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		var mask := 0
		var is_water_cell := have_water and water_arr[i] != 0
		var landform := int(lf_arr[i]) if have_lf else -1
		if not is_water_cell:
			mask |= 1
			if have_river and river_arr[i] != 0:
				mask |= 4
			if have_neighbors:
				for direction in range(6):
					var neighbor := int(neighbor_indices[i * 6 + direction])
					if neighbor < 0 or neighbor >= n_cells or not have_water \
							or water_arr[neighbor] == 0:
						continue
					var neighbor_landform := int(lf_arr[neighbor]) if have_lf else -1
					if neighbor_landform == LandformType.LF.LAKE:
						mask |= 4
					elif neighbor_landform in [LandformType.LF.DEEP_OCEAN,
							LandformType.LF.OCEAN, LandformType.LF.COAST]:
						mask |= 8
		elif landform in [LandformType.LF.DEEP_OCEAN, LandformType.LF.OCEAN,
				LandformType.LF.COAST]:
			mask |= 2
		elif landform == LandformType.LF.LAKE:
			mask |= 4
		habitat_arr[i] = mask
	return habitat_arr


## 旧 DLL 兜底 + A/B 参考实现：河口/羽流生产力强度。
## 融合 pass 在 C++ 里跑同一段逻辑（world_ext_boot_facade.cpp boot_estuary_strength）。

func _collect_estuary_strength(map_ref, cooperative: bool = false) -> PackedFloat32Array:
	var n_cells: int = map_ref.cell_count()
	var lf_arr: PackedByteArray = map_ref.landform_arr
	var river_arr: PackedByteArray = map_ref.has_river_arr
	var river_flow_arr: PackedFloat32Array = map_ref.river_flow_arr
	var river_downstream_arr: PackedInt32Array = map_ref.river_downstream_arr
	var neighbor_indices: PackedInt32Array = map_ref.neighbor_indices_packed()
	var estuary_strength_arr := PackedFloat32Array()
	estuary_strength_arr.resize(n_cells)
	var have_lf: bool = lf_arr.size() >= n_cells
	var have_river: bool = river_arr.size() >= n_cells
	var have_river_flow: bool = river_flow_arr.size() >= n_cells
	var have_river_downstream: bool = river_downstream_arr.size() >= n_cells
	var have_neighbors: bool = neighbor_indices.size() >= n_cells * 6
	if not (have_river and have_river_downstream and have_lf):
		return estuary_strength_arr
	for source in range(n_cells):
		if cooperative and _generator._generation_slice_due():
			await _generator._yield_generation_frame()
			_generator._generation_slice_start_usec = Time.get_ticks_usec()
		if river_arr[source] == 0:
			continue
		var outlet := int(river_downstream_arr[source])
		if outlet < 0 or outlet >= n_cells:
			continue
		var outlet_landform := int(lf_arr[outlet])
		if outlet_landform not in [LandformType.LF.DEEP_OCEAN,
				LandformType.LF.OCEAN, LandformType.LF.COAST]:
			continue
		var flow_signal := 1.0 - exp(-maxf(
			float(river_flow_arr[source]) if have_river_flow else 1.0, 0.0) * 0.25)
		var mouth_strength := 0.75 + 0.25 * flow_signal
		estuary_strength_arr[source] = maxf(estuary_strength_arr[source], mouth_strength)
		estuary_strength_arr[outlet] = maxf(estuary_strength_arr[outlet], mouth_strength)
		if have_neighbors:
			for direction in range(6):
				var plume_cell := int(neighbor_indices[outlet * 6 + direction])
				if plume_cell < 0 or plume_cell >= n_cells:
					continue
				var plume_landform := int(lf_arr[plume_cell])
				if plume_landform in [LandformType.LF.DEEP_OCEAN,
						LandformType.LF.OCEAN, LandformType.LF.COAST]:
					estuary_strength_arr[plume_cell] = maxf(
						estuary_strength_arr[plume_cell], mouth_strength * 0.45)
	return estuary_strength_arr


## `_log_bio_occupancy_seed()` 的诊断名字表。融合 pass 的 C++ 聚合段与 GDScript
## 兜底段共用这一份，保证两条路径打印逐字相同。

func _build_resource_signal_knobs(map_ref: MapData) -> Dictionary:
	var catalog: Dictionary = _generator.TechnologyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		push_error("[research-signals] resource catalog compile failed")
		return {}
	if map_ref == null or map_ref.cell_count() <= 0:
		return {}
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var dense := PackedInt32Array()
	for profile in ResourceProfileRegistry.ordered():
		var signal_index := ids.find("resource.%s" % String(profile.id))
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if signal_index < 0 or field.is_empty():
			push_error("[research-signals] resource signal binding missing: %s" % String(profile.id))
			return {}
		dense.append(signal_index)
	if map_ref.cell_research_signal_offsets.size() != map_ref.cell_count() + 1:
		push_error("[research-signals] static signal CSR missing")
		return {}
	return {
		"cell_signal_offsets": map_ref.cell_research_signal_offsets,
		"cell_signal_ids": map_ref.cell_research_signal_ids,
		"cell_signal_values": map_ref.cell_research_signal_values,
		"resource_signal_ids": dense,
	}



func _select_micro_deposit_cells(ranked_cells: Array, core_count: int,		micro_count: int, neighbor_indices: PackedInt32Array,
		have_neighbors: bool) -> Array:
	if micro_count <= 0 or core_count >= ranked_cells.size():
		return []
	var occupied := {}
	for rank in range(mini(core_count, ranked_cells.size())):
		occupied[int(ranked_cells[rank].cell)] = true
	var selected := {}
	var result := []
	# 第一轮保持至少一格间距，把小微矿点从富集核心和彼此之间摊开。
	for rank in range(core_count, ranked_cells.size()):
		if result.size() >= micro_count:
			break
		var cell := int(ranked_cells[rank].cell)
		var touches_deposit := false
		if have_neighbors:
			for direction in range(6):
				var neighbor := int(neighbor_indices[cell * 6 + direction])
				if neighbor >= 0 and occupied.has(neighbor):
					touches_deposit = true
					break
		if touches_deposit:
			continue
		result.append(ranked_cells[rank])
		selected[cell] = true
		occupied[cell] = true
	# 极小地图或候选区过密时，稳定回填剩余最适宜地块。
	for rank in range(core_count, ranked_cells.size()):
		if result.size() >= micro_count:
			break
		var cell := int(ranked_cells[rank].cell)
		if selected.has(cell):
			continue
		result.append(ranked_cells[rank])
		selected[cell] = true
	return result



func _allocate_ranked_deposit_budget(arr: PackedFloat32Array, cells: Array,
		budget: float, minimum_reserve: float, richness_exponent: float) -> void:
	if cells.is_empty() or budget <= 0.0:
		return
	var remaining := maxf(budget - minimum_reserve * cells.size(), 0.0)
	var best_suit := float(cells[0].suit)
	var cutoff_suit := float(cells[-1].suit)
	var suit_span := maxf(best_suit - cutoff_suit, 0.000001)
	var weights := PackedFloat32Array()
	weights.resize(cells.size())
	var weight_sum := 0.0
	for rank in range(cells.size()):
		var relative_suit := clampf(
			(float(cells[rank].suit) - cutoff_suit) / suit_span, 0.0, 1.0)
		var weight := pow(maxf(relative_suit, 0.001), richness_exponent)
		weights[rank] = weight
		weight_sum += weight
	for rank in range(cells.size()):
		var cell := int(cells[rank].cell)
		var enrichment := remaining * float(weights[rank]) / weight_sum \
			if weight_sum > 0.0 else remaining / cells.size()
		arr[cell] = minimum_reserve + enrichment



func _publish_bootstrapped_natural_resources_to_runtime(map_ref: MapData) -> void:
	if map_ref == null:
		return
	var habitat_component := &"cell.resource_habitat_mask"
	if _generator._data_core_world != null and _generator._data_core_world.has_method("component_id") \
			and _generator._data_core_world.has_method("write_u8_range"):
		var habitat_cid := int(_generator._data_core_world.component_id(habitat_component))
		if habitat_cid >= 0:
			_generator._data_core_world.write_u8_range(
				habitat_cid, 0, map_ref.resource_habitat_mask_arr)
	if _generator._data_core_world_ext != null :
		var habitat_cid_ext := int(_generator._data_core_world_ext.component_id(&"cell_resource_habitat_mask"))
		if habitat_cid_ext >= 0:
			_generator._data_core_world_ext.write_u8_range(
				habitat_cid_ext, 0, map_ref.resource_habitat_mask_arr)
	for profile in ResourceProfileRegistry.ordered():
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field.is_empty():
			continue
		var values: PackedFloat32Array = map_ref.get(field)
		if _generator._data_core_world != null and _generator._data_core_world.has_method("component_id") \
				and _generator._data_core_world.has_method("write_f32_range"):
			var cid := int(_generator._data_core_world.component_id(profile.reserve_component))
			if cid >= 0:
				_generator._data_core_world.write_f32_range(cid, 0, values)
		if _generator._data_core_world_ext != null :
			# Native slots use schema cpp_name, not the dotted GDScript name.
			var cid_ext := int(_generator._data_core_world_ext.component_id(
				ResourceProfileRegistry.reserve_cpp_name(profile)))
			if cid_ext >= 0:
				_generator._data_core_world_ext.write_f32_range(cid_ext, 0, values)


# 每日资源 pass 入口（由 NaturalResourceDailySystem.tick 调）。
# 优先 C++ run_natural_resource_pass（slot 权威 + flush 回 MapData）；
# native 不可用 / 未发布时退回 GDScript fallback 同模板。

func _on_modifier_events_available(batch: Dictionary) -> void:
	# Modifier events are emitted after the native modifier commit and before
	# downstream economy/resource consumers in the same daily graph. Only the
	# Economy domain can affect natural-resource regen factors; climate/country/
	# gameplay events leave this cache valid.
	var domains: PackedInt32Array = batch.get("domains", PackedInt32Array())
	for domain in domains:
		if int(domain) == _generator.ModifierFacadeScript.Domain.ECONOMY:
			_generator._natural_resource_regen_factors_valid = false
			return



func _prime_natural_resource_regen_factors(n_cells: int) -> Dictionary:
	if n_cells <= 0 or _generator._data_core_world_ext == null :
		return {"ok": false, "reason": "regen_factor_api_unavailable"}
	_generator._ensure_natural_resource_knobs()
	var factor_started: int = Time.get_ticks_usec()
	var factor_result: Dictionary = _generator._data_core_world_ext.get_natural_resource_regen_factors(
		_generator._natural_resource_pass_knobs.get("resource_ids", PackedStringArray()), n_cells)
	_generator._natural_resource_regen_factor_prime_ms = (
		Time.get_ticks_usec() - factor_started) / 1000.0
	if bool(factor_result.get("ok", false)):
		_generator._natural_resource_pass_knobs["regen_factors"] = factor_result.get(
			"factors", PackedFloat32Array())
		_generator._natural_resource_pass_knobs["regen_modifier_snapshot_version"] = int(
			factor_result.get("snapshot_version", 0))
		_generator._natural_resource_pass_knobs["active_regen_factor_count"] = int(
			factor_result.get("active_factor_count", 0))
		_generator._natural_resource_regen_factors_valid = true
	return factor_result



func _try_bootstrap_natural_resources_native(map_ref, cfg,
		habitat_arr: PackedByteArray, estuary_strength_arr: PackedFloat32Array) -> bool:
	if map_ref == null or _generator._data_core_world_ext == null:
		return false
	var n_cells: int = map_ref.cell_count()
	if n_cells <= 0 or habitat_arr.size() < n_cells:
		return false
	var knobs: Dictionary = _generator._get_map_resource_initializer()._build_resource_deposit_knobs(map_ref, cfg)
	if knobs.is_empty():
		return false
	var resource_count: int = (knobs.get("field_names", PackedStringArray()) as PackedStringArray).size()
	knobs["cell_count"] = n_cells
	knobs["habitat_mask"] = habitat_arr
	knobs["estuary"] = estuary_strength_arr
	var started := Time.get_ticks_usec()
	var report: Dictionary = _generator._data_core_world_ext.run_resource_deposit_pass(knobs)
	if not bool(report.get("ok", false)):
		push_warning("[resource-deposits] native pass unavailable (%s); falling back to GDScript"
			% String(report.get("reason", "unknown")))
		return false
	var fields: PackedStringArray = report.get("fields", PackedStringArray())
	var reserves: Array = report.get("reserves", [])
	if fields.size() != resource_count or reserves.size() != resource_count:
		push_warning("[resource-deposits] native pass shape mismatch (%d/%d vs %d); falling back"
			% [fields.size(), reserves.size(), resource_count])
		return false
	for i in range(resource_count):
		map_ref.set(fields[i], reserves[i])
	var native_ms := float(Time.get_ticks_usec() - started) / 1000.0
	print("[resource-deposits] path=gdext resources=%d cells=%d total_ms=%.1f native_ms=%.1f"
		% [resource_count, n_cells, native_ms, float(report.get("elapsed_ms", 0.0))])
	return true


## 旧 DLL 兜底 + A/B 参考实现：构造 `cell.resource_habitat_mask`。
## 融合 pass 在 C++ 里跑同一段逻辑（world_ext_boot_facade.cpp boot_habitat_mask）。

func _bio_log_food_bits() -> PackedInt32Array:
	var catalog: Dictionary = _generator.ResearchSignalCatalogScript.compile_native_catalog()
	var bits := PackedInt32Array()
	for food_id in _generator.BIO_LOG_FOOD_IDS:
		bits.append(_generator.ResearchSignalCatalogScript.occupancy_bit_for_signal(
			catalog, StringName(food_id)))
	return bits


## carrier_unique_ids → reserve 字段名。查找规则与 `_bio_reserve_column()` 逐行一致：
## 取 ResourceProfileRegistry.ordered() 里第一个 id 匹配的资源的 reserve 字段；
## 匹配不到给 ""（对应老链路的空列）。
## 融合路径里 MapData 的 reserve 字段还没写入（矿藏与生态在同一次 native 调用里
## 才算），所以把字段名交给 C++，让它从矿藏输出按名对齐取列。

func _bio_carrier_reserve_fields(knobs: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for raw_id in knobs.get("carrier_unique_ids", []):
		out.append(_generator._bio_reserve_field_for(String(raw_id)))
	return out



func _bio_reserve_field_for(resource_id: String) -> String:
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) != resource_id:
			continue
		return ResourceProfileRegistry.reserve_map_field(profile)
	return ""


## 构造资源研究信号合并（mode=resources）的 knobs。储量列由融合 pass 直接取矿藏
## pass 的输出填进去；旧链路则由 `_append_natural_resource_research_signals()` 从
## MapData 的 reserve 字段取。两边数值同源。

func _bootstrap_world_facades(map_ref, cfg) -> bool:
	if map_ref == null or _generator._data_core_world_ext == null:
		return false
	if _generator._boot_facade_disabled_for_ab():
		return false
	var n_cells: int = map_ref.cell_count()
	if n_cells <= 0:
		return false
	var deposit_knobs: Dictionary = _generator._get_map_resource_initializer()._build_resource_deposit_knobs(map_ref, cfg)
	if deposit_knobs.is_empty():
		return false
	var signal_knobs: Dictionary = _generator._get_map_resource_initializer()._build_resource_signal_knobs(map_ref)
	if signal_knobs.is_empty():
		return false
	var bio_knobs: Dictionary = _generator._bio_occupancy_base_knobs(map_ref)
	if not bool(bio_knobs.get("ok", false)):
		return false
	# 融合路径里 MapData 的 reserve 字段还没写入（矿藏与生态在同一次 native 调用
	# 里才算），因此把「carrier → reserve 字段名」交给 C++ 从矿藏输出对齐取列，
	# 并把此刻必然全 0 的 carrier_reserves 拆掉（省 20×n 次 Variant 拷贝）。
	bio_knobs.erase("carrier_reserves")
	bio_knobs["carrier_reserve_fields"] = _generator._bio_carrier_reserve_fields(bio_knobs)
	var started := Time.get_ticks_usec()
	var report: Dictionary = _generator._data_core_world_ext.run_boot_facade_pass({
		"cell_count": n_cells,
		"is_water": map_ref.is_water_arr,
		"landform": map_ref.landform_arr,
		"has_river": map_ref.has_river_arr,
		"river_flow": map_ref.river_flow_arr,
		"river_downstream": map_ref.river_downstream_arr,
		"neighbor_indices": map_ref.neighbor_indices_packed(),
		"habitat_mask_in": map_ref.resource_habitat_mask_arr,
		"run_deposits": true,
		"deposit": deposit_knobs,
		"deposit_knob_sig": _generator._knob_signature(deposit_knobs),
		"run_signals": true,
		"resource_signals": signal_knobs,
		"run_bio": true,
		"bio": bio_knobs,
		"bio_food_names": PackedStringArray(_generator.BIO_LOG_FOOD_NAMES),
		"bio_food_bits": _generator._bio_log_food_bits(),
		"bio_class_names": PackedStringArray(_generator.BIO_LOG_CLASS_NAMES),
	})
	if not bool(report.get("ok", false)) \
			or not bool(report.get("deposit_ok", false)) \
			or not bool(report.get("signal_ok", false)) \
			or not bool(report.get("bio_ok", false)):
		push_warning("[boot-facades] native pass declined (%s); diagnostics=%s; falling back per stage" % [
			String(report.get("reason",
				report.get("deposit_reason",
					report.get("signal_reason",
						report.get("bio_reason", "unknown"))))),
			str({"stages": report.get("stage_ms", {}),
				"bio_carriers": [report.get("bio_carrier_declared", -1),
					report.get("bio_carrier_used", -1)],
				"deposit_fields": (report.get("deposit_fields", PackedStringArray()) as PackedStringArray).size(),
				"reserves": (report.get("deposit_reserves", []) as Array).size()})])
		return false
	var wall_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var fields: PackedStringArray = report.get("deposit_fields", PackedStringArray())
	var reserves: Array = report.get("deposit_reserves", [])
	if fields.is_empty() or fields.size() != reserves.size():
		push_warning("[boot-facades] deposit shape mismatch; falling back per stage")
		return false
	# ── 解包：整数组赋值 / set()，无 per-cell GDScript 循环 ─────────────────
	map_ref.resource_habitat_mask_arr = report.get("habitat_mask", PackedByteArray())
	for i in range(fields.size()):
		map_ref.set(fields[i], reserves[i])
	map_ref.cell_research_signal_offsets = report.get(
		"cell_signal_offsets", PackedInt32Array())
	map_ref.cell_research_signal_ids = report.get(
		"cell_signal_ids", PackedInt32Array())
	map_ref.cell_research_signal_values = report.get(
		"cell_signal_values", PackedInt32Array())
	map_ref.landmass_id_arr = report.get("landmass_ids", PackedInt32Array())
	map_ref.province_id_arr = report.get("province_ids", PackedInt32Array())
	map_ref.bio_occupancy_bits_arr = report.get("occupancy_bits", PackedInt32Array())
	_generator._publish_bio_occupancy_to_runtime(map_ref)
	print("[boot-facades] path=gdext resources=%d cells=%d wall_ms=%.1f native_ms=%.1f stages=%s" % [
		fields.size(), n_cells, wall_ms, float(report.get("elapsed_ms", 0.0)),
		str(report.get("stage_ms", {}))])
	_generator._log_bio_occupancy_seed_native(report, bio_knobs)
	return true


## 矿藏 pass 输入数组的指纹：用于诊断融合 pass 的输入是否稳定。

func _knob_signature(knobs: Dictionary) -> int:
	var keys := [
		"temperature", "moisture", "elevation", "terrain", "vegetation", "landform",
		"has_river", "is_lake", "has_volcano", "ocean_x", "ocean_y", "upwelling",
		"pos_x", "pos_y", "scalars", "field_names", "habitat_codes",
		"lf_keys", "lf_vals", "lf_offsets", "veg_keys", "veg_vals", "veg_offsets",
		"excluded_terrain", "excluded_vegetation",
	]
	var sig := 0
	for key in keys:
		sig = int((sig * 1000003 + hash(knobs.get(key))) & 0x3FFFFFFFFFFFFFFF)
	return sig



func run_natural_resource_pass_native(
		map_ref,
		dt_days: int = 1,
		cell_indices: PackedInt32Array = PackedInt32Array(),
		cell_dt_days: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var t_wall: int = Time.get_ticks_usec()
	dt_days = clampi(dt_days, 1, _generator.NATURAL_RESOURCE_WILDERNESS_STRIDE)
	if map_ref == null:
		return _generator._remember_natural_resource_report({"done": true, "path": "skip", "published_to_slot": false})
	var n_cells: int = map_ref.cell_count()
	if n_cells <= 0:
		return _generator._remember_natural_resource_report({"done": true, "path": "skip", "published_to_slot": false})
	var knob_update_started: int = Time.get_ticks_usec()
	_generator._ensure_natural_resource_knobs()
	var knob_update_ms: float = (Time.get_ticks_usec() - knob_update_started) / 1000.0
	if int(_generator._natural_resource_pass_knobs.get("resource_count", 0)) <= 0:
		return _generator._remember_natural_resource_report({"done": true, "path": "no_resources", "published_to_slot": false})
	var factor_lookup_ms: float = 0.0
	if not _generator._natural_resource_regen_factors_valid:
		var factor_started: int = Time.get_ticks_usec()
		_generator._prime_natural_resource_regen_factors(n_cells)
		factor_lookup_ms = (Time.get_ticks_usec() - factor_started) / 1000.0
		if not _generator._natural_resource_regen_factors_valid:
			# Preserve the legacy no-modifier behavior when the optional getter is
			# unavailable. An empty factor table means an exact multiplier of 1.0.
			_generator._natural_resource_pass_knobs.erase("regen_factors")
			_generator._natural_resource_pass_knobs["regen_modifier_snapshot_version"] = 0
			_generator._natural_resource_pass_knobs["active_regen_factor_count"] = 0
			_generator._natural_resource_regen_factors_valid = true

	var native_reason: String = "native_unavailable"
	if _generator._data_core_world_ext != null:
		native_reason = "native_failed"
		var refresh_ms: float = 0.0
		var refresh_started: int = 0
		refresh_started = Time.get_ticks_usec()
		_generator._data_core_world_ext.refresh_slots_from_map_keys(_generator._natural_resource_refresh_keys)
		refresh_ms = (Time.get_ticks_usec() - refresh_started) / 1000.0
		_generator._natural_resource_pass_knobs["n_cells"] = n_cells
		_generator._natural_resource_pass_knobs["dt_days"] = dt_days
		if cell_indices.is_empty():
			_generator._natural_resource_pass_knobs.erase("cell_indices")
			_generator._natural_resource_pass_knobs.erase("cell_dt_days")
		else:
			_generator._natural_resource_pass_knobs["cell_indices"] = cell_indices
			if cell_dt_days.size() == cell_indices.size():
				_generator._natural_resource_pass_knobs["cell_dt_days"] = cell_dt_days
			else:
				_generator._natural_resource_pass_knobs.erase("cell_dt_days")
		knob_update_ms = (Time.get_ticks_usec() - knob_update_started) / 1000.0
		var native_call_started: int = Time.get_ticks_usec()
		var res: Dictionary = _generator._data_core_world_ext.run_natural_resource_pass(_generator._natural_resource_pass_knobs)
		native_reason = String(res.get("reason", "native_failed"))
		var native_call_ms: float = (Time.get_ticks_usec() - native_call_started) / 1000.0
		res["factor_lookup_ms"] = factor_lookup_ms
		res["slot_refresh_ms"] = refresh_ms
		res["knob_update_ms"] = knob_update_ms
		res["native_call_ms"] = native_call_ms
		if bool(res.get("published_to_slot", false)):
			res["dt_days"] = dt_days
			res["wrapper_wall_ms"] = (Time.get_ticks_usec() - t_wall) / 1000.0
			res["wrapper_overhead_ms"] = max(0.0, float(res.get("wrapper_wall_ms", 0.0)) - float(res.get("native_ms", 0.0)))
			return _generator._remember_natural_resource_report(res)
	push_error("[natural_resource] native failed: %s; previous resource fields retained" % native_reason)
	return _generator._remember_natural_resource_report({
		"done": false,
		"path": "native_failed",
		"status": "failed",
		"reason": native_reason,
		"published_to_slot": false,
		"factor_lookup_ms": factor_lookup_ms,
		"knob_update_ms": knob_update_ms,
		"dt_days": dt_days,
		"indexed_cell_count": cell_indices.size() if not cell_indices.is_empty() else n_cells,
		"wrapper_wall_ms": (Time.get_ticks_usec() - t_wall) / 1000.0,
	})



func run_natural_resource_pass_for_runtime_commit(day: int) -> Dictionary:
	if _generator._sus_map == null:
		return {"done": true, "path": "skip", "published_to_slot": false}
	var live_cells = _generator.economy_live_cells()
	return _generator.run_natural_resource_pass_scheduled(_generator._sus_map, maxi(0, day), live_cells)



func _reset_natural_resource_cadence(n_cells: int, last_day: int) -> void:
	_generator._natural_resource_last_day.resize(maxi(0, n_cells))
	_generator._natural_resource_was_live.resize(maxi(0, n_cells))
	_generator._natural_resource_last_day.fill(last_day)
	_generator._natural_resource_was_live.fill(0)



func _natural_resource_dt_for_cell(cell: int, day: int, is_live: bool) -> int:
	var last: int = int(_generator._natural_resource_last_day[cell])
	var elapsed: int = clampi(day - last, 1, _generator.NATURAL_RESOURCE_WILDERNESS_STRIDE)
	if is_live and int(_generator._natural_resource_was_live[cell]) != 0:
		elapsed = clampi(elapsed, 1, _generator.NATURAL_RESOURCE_LIVE_CATCHUP_MAX_DAYS)
	return elapsed



func collect_natural_resource_pass_cells(day: int, live_cells: PackedInt32Array) -> Dictionary:
	var n_cells: int = _generator._natural_resource_last_day.size()
	var live_set := {}
	var cell_indices := PackedInt32Array()
	var cell_dt_days := PackedInt32Array()
	for cell in live_cells:
		var idx := int(cell)
		if idx < 0 or idx >= n_cells:
			continue
		live_set[idx] = true
		if int(_generator._natural_resource_last_day[idx]) >= day:
			continue
		cell_indices.append(idx)
		cell_dt_days.append(_generator._natural_resource_dt_for_cell(idx, day, true))
	var bucket: int = posmod(day, _generator.NATURAL_RESOURCE_WILDERNESS_STRIDE)
	for idx in range(n_cells):
		if live_set.has(idx):
			continue
		if posmod(idx, _generator.NATURAL_RESOURCE_WILDERNESS_STRIDE) != bucket:
			continue
		if int(_generator._natural_resource_last_day[idx]) >= day:
			continue
		cell_indices.append(idx)
		cell_dt_days.append(_generator._natural_resource_dt_for_cell(idx, day, false))
	return {"cell_indices": cell_indices, "cell_dt_days": cell_dt_days, "live_set": live_set}



func _commit_natural_resource_pass_days(day: int, cell_indices: PackedInt32Array, live_set: Dictionary) -> void:
	for cell in cell_indices:
		var idx := int(cell)
		if idx < 0 or idx >= _generator._natural_resource_last_day.size():
			continue
		_generator._natural_resource_last_day[idx] = day
		_generator._natural_resource_was_live[idx] = 1 if live_set.has(idx) else 0



func run_natural_resource_pass_scheduled(map_ref, day: int, live_cells: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	if map_ref == null:
		return _generator._remember_natural_resource_report({"done": true, "path": "skip", "published_to_slot": false})
	var n_cells: int = map_ref.cell_count()
	_generator._ensure_natural_resource_cadence(n_cells, day)
	var planned: Dictionary = _generator.collect_natural_resource_pass_cells(day, live_cells)
	var cell_indices: PackedInt32Array = planned.get("cell_indices", PackedInt32Array())
	var cell_dt_days: PackedInt32Array = planned.get("cell_dt_days", PackedInt32Array())
	if cell_indices.is_empty():
		return _generator._remember_natural_resource_report({
			"done": true,
			"path": "indexed_empty",
			"published_to_slot": true,
			"dt_days": 1,
			"indexed_cell_count": 0,
			"n_cells": n_cells,
			"total_delta": 0.0,
		})
	var res: Dictionary = _generator.run_natural_resource_pass_native(map_ref, 1, cell_indices, cell_dt_days)
	if bool(res.get("published_to_slot", false)):
		_generator._commit_natural_resource_pass_days(day, cell_indices, planned.get("live_set", {}))
	res["indexed_cell_count"] = cell_indices.size()
	return res



func catchup_natural_resources_for_live_cells(day: int) -> Dictionary:
	if _generator._sus_map == null:
		return {"done": true, "path": "skip", "indexed_cell_count": 0}
	_generator._ensure_natural_resource_cadence(_generator._sus_map.cell_count(), day)
	var live: PackedInt32Array = _generator.economy_live_cells()
	var due := PackedInt32Array()
	var dts := PackedInt32Array()
	var live_set := {}
	for cell in live:
		var idx := int(cell)
		if idx < 0 or idx >= _generator._natural_resource_last_day.size():
			continue
		live_set[idx] = true
		if int(_generator._natural_resource_last_day[idx]) >= day:
			continue
		due.append(idx)
		dts.append(_generator._natural_resource_dt_for_cell(idx, day, true))
	if due.is_empty():
		return {"done": true, "path": "catchup_empty", "indexed_cell_count": 0}
	var res: Dictionary = _generator.run_natural_resource_pass_native(_generator._sus_map, 1, due, dts)
	if bool(res.get("published_to_slot", false)):
		_generator._commit_natural_resource_pass_days(day, due, live_set)
	res["indexed_cell_count"] = due.size()
	return res



func dump_climate_daily_round_slots_stats() -> Dictionary:
	var out: Dictionary = {
		"refresh_count": _generator._climate_daily_round_slots_refresh_count,
		"skip_count": _generator._climate_daily_round_slots_skip_count,
	}
	_generator._climate_daily_round_slots_refresh_count = 0
	_generator._climate_daily_round_slots_skip_count = 0
	return out


func _run_season_refresh_stage8_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp = _generator._c()
	# Native stage 8 is authoritative; cp only supplies the seasonal gate.
	if cp == null:
		_generator._season_log_path_once("stage8", "gdscript_fallback", "cp null")
		return false
	if _generator._last_cfg == null or map == null or _generator._data_core_world_ext == null :
		_generator._season_log_path_once("stage8", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	_generator._ensure_season_round_slots_fresh()
	var knobs: Dictionary = {
		"stage": 8,
		"n_cells": map.cell_count(),
		"sea_level": _generator._last_cfg.sea_level,
	}
	var res: Dictionary = _generator._data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_generator._season_log_path_once("stage8", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_generator._sync_stage8_facade_fields_from_soa(map)
	_generator._last_season_refresh_breakdown["stage_8_path"] = "gdext"
	_generator._last_season_refresh_breakdown["stage_8_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_generator._season_log_path_once("stage8", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# Native stage 11 feedback decay. Native failure is reported to the season
# coordinator and leaves the previous feedback fields untouched.
