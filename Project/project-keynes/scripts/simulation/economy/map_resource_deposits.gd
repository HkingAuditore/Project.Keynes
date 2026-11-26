extends "res://scripts/simulation/generator_context.gd"

## Initial natural-resource reserves, deposit inputs, and distribution.

const RESOURCE_SCALAR_STRIDE := 32
const MIN_DEPOSIT_QUOTA_LANDMASS_CELLS := 8

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
	# 旧库或原生计算失败时，由脚本完成储量和陆块配额。
	if _generator._try_bootstrap_natural_resources_native(map_ref, cfg, habitat_arr, estuary_strength_arr):
		return
	var landmass_labels := PackedInt32Array()
	var landmass_sizes := PackedInt32Array([0])
	var water: PackedByteArray = map_ref.is_water_arr
	if have_neighbors and water.size() >= n_cells:
		_label_landmasses(water, neighbor_indices, n_cells, landmass_labels, landmass_sizes)
	var quota_totals := Vector2i.ZERO
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
		var use_landmass_quota: bool = not landmass_labels.is_empty() \
			and p.init_continent_floor_cells > 0 and p.init_min_reserve > 0.0
		var collect_ranked: bool = use_ranked_distribution or use_landmass_quota \
			or (p.init_min_coverage > 0.0 and p.init_min_reserve > 0.0)
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
			if collect_ranked:
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
		if use_landmass_quota:
			# PackedFloat32Array rounds on write. Count a reserve we already
			# raised to this same stored floor as a complete deposit.
			var minimum := PackedFloat32Array([float(p.init_min_reserve) \
				* ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE])[0]
			quota_totals += _apply_landmass_quota(arr, ranked_cells, minimum,
				int(p.init_continent_floor_cells), landmass_labels, landmass_sizes)
		map_ref.set(field, arr)
	print("[resource-deposits] path=gdscript quota_cells=%d quota_unmet=%d" \
		% [quota_totals.x, quota_totals.y])


static func _label_landmasses(water: PackedByteArray, neighbors: PackedInt32Array,
		cell_count: int, labels: PackedInt32Array, sizes: PackedInt32Array) -> void:
	labels.resize(cell_count)
	labels.fill(0)
	var pending: Array[int] = []
	for cell in range(cell_count):
		if water[cell] != 0 or labels[cell] != 0:
			continue
		var landmass := sizes.size()
		var size := 0
		labels[cell] = landmass
		pending.append(cell)
		while not pending.is_empty():
			var current: int = pending.pop_back()
			size += 1
			for direction in range(6):
				var neighbor := neighbors[current * 6 + direction]
				if neighbor < 0 or neighbor >= cell_count or water[neighbor] != 0 \
						or labels[neighbor] != 0:
					continue
				labels[neighbor] = landmass
				pending.append(neighbor)
		sizes.append(size)


static func _apply_landmass_quota(reserves: PackedFloat32Array, ranked_cells: Array,
		minimum: float, quota: int, labels: PackedInt32Array,
		sizes: PackedInt32Array) -> Vector2i:
	var remaining := PackedInt32Array()
	remaining.resize(sizes.size())
	remaining.fill(0)
	for landmass in range(1, sizes.size()):
		if sizes[landmass] >= MIN_DEPOSIT_QUOTA_LANDMASS_CELLS:
			remaining[landmass] = mini(quota, ceili(0.01 * sizes[landmass]))
	for cell in range(labels.size()):
		var landmass := labels[cell]
		if remaining[landmass] > 0 and reserves[cell] >= minimum:
			remaining[landmass] -= 1
	var unmet := 0
	for count in remaining:
		unmet += count
	if unmet == 0:
		return Vector2i.ZERO
	# Native quota ranking uses exact suitability and breaks ties by cell ID.
	ranked_cells.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.suit) > float(b.suit) if a.suit != b.suit else int(a.cell) < int(b.cell))
	var added := 0
	for ranked in ranked_cells:
		var cell := int(ranked.cell)
		var landmass := labels[cell]
		if remaining[landmass] <= 0 or reserves[cell] >= minimum:
			continue
		reserves[cell] = minimum
		remaining[landmass] -= 1
		added += 1
		if added == unmet:
			break
	return Vector2i(added, unmet - added)


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
		scalars[base + 30] = float(p.init_continent_floor_cells)

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
		"is_water": map_ref.is_water_arr,
		"has_volcano": map_ref.has_volcano_arr,
		"ocean_x": map_ref.ocean_current_x_arr,
		"ocean_y": map_ref.ocean_current_y_arr,
		"upwelling": map_ref.upwelling_strength_arr,
		"pos_x": posx_arr,
		"pos_y": posy_arr,
		"neighbor_indices": map_ref.neighbor_indices_packed(),
		"field_names": field_names,
		"habitat_codes": habitat_codes,
		"scalars": scalars, "cell_area_resource_scale": ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE,
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
	if not report.has_all(["quota_cells", "quota_unmet"]):
		push_warning("[resource-deposits] native pass lacks landmass quotas; falling back to GDScript")
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
	print(("[resource-deposits] path=gdext resources=%d cells=%d total_ms=%.1f native_ms=%.1f"
		+ " quota_cells=%d quota_unmet=%d") % [resource_count, n_cells, native_ms,
			float(report.get("elapsed_ms", 0.0)), int(report.get("quota_cells", 0)),
			int(report.get("quota_unmet", 0))])
	return true


## 旧 DLL 兜底 + A/B 参考实现：构造 `cell.resource_habitat_mask`。
## 融合 pass 在 C++ 里跑同一段逻辑（world_ext_boot_facade.cpp boot_habitat_mask）。
