extends RefCounted

const DECORATION_VEG_RESIDUAL := 0.12

## Stateless scatter and ecology helpers for ShrubLayer.

static func _cell_quota(host, suitability: float, max_per_cell: int) -> Vector2:

	var cap: int = maxi(1, max_per_cell)
	var target: float = float(cap) * clampf(suitability, 0.0, 1.0)
	var attempts: int = clampi(int(ceil(target)), 1, cap)
	return Vector2(float(attempts), target / float(attempts))



static func _cell_suitability(host, cell, idx: int, _key: int, state: Dictionary) -> float:

	var cell_is_water = _is_water_cell(host, cell, idx)
	var domain = _spawn_domain(host)
	if domain == host.SPAWN_LAND and cell_is_water:
		return 0.0
	if domain == host.SPAWN_WATER and not cell_is_water:
		return 0.0

	var lf = int(state.get("landform", LandformType.LF.PLAIN))
	var veg = int(state.get("vegetation", VegetationType.VEG.NONE))
	var cover = int(state.get("cover", CoverType.CV.NONE))
	var river = _has_river_cell(host, cell, idx)
	var arch = _detail_kind(host)

	if cell_is_water:
		return _aquatic_suitability(host, arch, lf, veg, cover, state)

	# 点缀/地貌类 archetype（岩石/雪堆/枯立木）走独立 suitability：不依赖植被权重，
	# 由地形/覆盖物/气候直接决定，能出现在植被权重为 0 的裸露/雪原/山巅。
	if _is_decoration_archetype(host, arch):
		return _decoration_suitability(host, arch, lf, cover, river, state)

	var landform_weight = _landform_weight(host, lf)
	if landform_weight <= 0.0:
		return 0.0

	var cover_weight = _cover_weight(host, cover)
	if cover_weight <= 0.0:
		return 0.0

	var temp = float(state.get("temp", 0.5))
	var moisture = float(state.get("moisture", 0.5))
	var vitality = float(state.get("vitality", 0.7))
	var stress = maxf(float(state.get("heat", 0.0)), maxf(float(state.get("drought", 0.0)), float(state.get("cold", 0.0))))
	var compat = VegetationType.climate_compat_score(veg, temp, moisture)
	var vitality_factor = _vitality_density_factor(host, state)

	var suitability = _vegetation_weight(host, veg) * landform_weight * cover_weight
	# 绝对生物量：_vegetation_weight 只表达"这一层的形态占该植被的多少比例"
	# （沙漠灌木 100% 是灌木形态，雨林林下只有一部分），量级必须由 biomass 承担，
	# 否则整条链全是相对适应度，沙漠会和雨林一样密。
	suitability *= _biomass_factor(host, veg)
	suitability *= vitality_factor
	suitability *= lerpf(0.58, 1.0, clampf(compat, 0.0, 1.0))
	suitability *= 1.0 - clampf(stress, 0.0, 1.0) * 0.38
	suitability *= lerpf(0.08, 1.0, _scatter_presence(host, state))
	suitability *= _cell_ecology_density_bias(host, state)
	# archetype 生态位亲和（针叶/棕榈/仙人掌/芦苇/高山花）：把通用植被分布收束到各自气候带。
	suitability *= _archetype_affinity(host, arch, veg, lf, cover, river, state)
	# 阶段 C：海拔林线 + 强风折损。
	suitability *= _elevation_modifier(host, arch, float(state.get("elevation", 0.4)))
	suitability *= _wind_exposure_modifier(host, arch, float(state.get("wind_speed", 0.0)))
	if river:
		suitability *= _river_density_factor(host, state)
	suitability *= _quality_density_scale(host)
	return clampf(suitability, 0.0, 1.25)


# 绝对生物量 → 密度乘子。曲线由 profile 的 biomass_floor / ceil / exponent 控制，
# 让每层自己决定对生物量的敏感度：乔木层强正相关，草层几乎不敏感（草原恰恰长在
# 树少的地方，它的选择性已经由 _grass_vegetation_weight 表达）。

static func _biomass_factor(host, veg: int) -> float:

	var cfg = _profile(host)
	var biomass = clampf(VegetationType.foliage_biomass(veg), 0.0, 1.0)
	var shaped = pow(biomass, maxf(float(cfg.biomass_exponent), 0.01))
	return lerpf(float(cfg.biomass_floor), float(cfg.biomass_ceil), shaped)


# 河流格的密度系数。河道本体的像素已在候选点阶段被 _is_river_body_position 剔除，
# 所以这里不该再对整格做一刀切惩罚：暖湿带的河谷是全图植被最密的地方，只有冷/旱带
# 的河床才是负面地形。

static func _river_density_factor(host, state: Dictionary) -> float:

	var cfg = _profile(host)
	var temp = float(state.get("temp", 0.5))
	var wet: float = maxf(float(state.get("moisture", 0.5)), float(state.get("soil_moisture", 0.4)))
	var warm_wet: float = smoothstep(0.35, 0.72, temp) * smoothstep(0.28, 0.62, wet)
	var dry_factor = float(cfg.river_edge_density)
	var lush_factor: float = maxf(dry_factor, float(cfg.river_valley_boost))
	return lerpf(dry_factor, lush_factor, warm_wet)


# 海拔林线：高海拔抑制乔木/棕榈，偏好高山花/针叶中带；低海拔归一。elevation∈[0,1]。

static func _elevation_modifier(host, arch: int, elev: float) -> float:

	match arch:
		host.DETAIL_TREE, host.DETAIL_PALM:
			return smoothstep(0.92, 0.58, elev)
		host.DETAIL_CONIFER:
			return smoothstep(0.22, 0.55, elev) * smoothstep(0.97, 0.74, elev) + 0.25
		host.DETAIL_ALPINE_FLOWER:
			return clampf(smoothstep(0.46, 0.82, elev) + 0.12, 0.0, 1.2)
		host.DETAIL_SHRUB, host.DETAIL_GRASS, host.DETAIL_CACTUS, host.DETAIL_REED:
			return smoothstep(0.97, 0.62, elev)
	return 1.0


# 强风折损：脆弱高茎（棕榈/芦苇/枯立木/高山花）在大风带略减。wind_speed 物理量（~m/s）。

static func _wind_exposure_modifier(host, arch: int, wind_speed: float) -> float:

	var w: float = clampf(wind_speed / 18.0, 0.0, 1.0)
	match arch:
		host.DETAIL_PALM, host.DETAIL_REED, host.DETAIL_ALPINE_FLOWER:
			return lerpf(1.0, 0.7, w)
		host.DETAIL_DEAD_SNAG:
			return lerpf(1.0, 0.6, w)
	return 1.0


# 3..7 植被类 archetype 的生态位亲和乘子（legacy 0/1/2 恒返回 1.0）。

static func _archetype_affinity(host, arch: int, veg: int, lf: int, _cover: int, river: bool, state: Dictionary) -> float:

	var temp = float(state.get("temp", 0.5))
	var moisture = float(state.get("moisture", 0.5))
	var soil = float(state.get("soil_moisture", moisture))
	var discharge = float(state.get("river_discharge", 0.0))
	# 实际地表湿润 = 气候湿度与土壤湿度的较强者（土壤更贴近根系可用水）。
	var wet = maxf(moisture, soil)
	var dry = minf(moisture, soil)
	var big_river: float = clampf(discharge / 80.0, 0.0, 1.0)
	match arch:
		host.DETAIL_CONIFER:
			# 寒带针叶林应成片：把生态位亲和拉高到能让 suitability 在针叶带饱和到 1.0。
			var a = 0.10
			match veg:
				VegetationType.VEG.TAIGA:
					a = 2.6
				VegetationType.VEG.TEMPERATE_CONIFER:
					a = 2.3
				VegetationType.VEG.BOREAL_SHRUB:
					a = 1.3
				VegetationType.VEG.ALPINE_TUNDRA, VegetationType.VEG.TEMPERATE_DECIDUOUS:
					a = 0.8
			a *= smoothstep(0.82, 0.22, temp)  # 偏冷，冷带更宽
			return a
		host.DETAIL_PALM:
			var a = 0.0
			match veg:
				VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
					a = 1.7
				VegetationType.VEG.TROPICAL_DRY_FOREST, VegetationType.VEG.SAVANNA:
					a = 1.1
				VegetationType.VEG.MANGROVE, VegetationType.VEG.OASIS_VEG:
					a = 1.4
			a *= smoothstep(0.55, 0.85, temp)  # 偏暖
			if lf == LandformType.LF.DELTA or lf == LandformType.LF.LOWLAND or river:
				a *= 1.3
			a *= lerpf(1.0, 1.45, big_river)  # 大河三角洲椰林
			return a
		host.DETAIL_CACTUS:
			var a = 0.06
			match veg:
				VegetationType.VEG.DESERT_SCRUB:
					a = 1.9
				VegetationType.VEG.XERIC_DESERT:
					a = 1.0
				VegetationType.VEG.MEDITERRANEAN_SHRUB, VegetationType.VEG.SAVANNA:
					a = 0.55
				VegetationType.VEG.OASIS_VEG:
					a = 0.75
			a *= smoothstep(0.5, 0.85, temp) * smoothstep(0.55, 0.16, dry)  # 热且（气候+土壤）双干
			return a
		host.DETAIL_REED:
			var a = 0.06
			match veg:
				VegetationType.VEG.MARSH:
					a = 1.9
				VegetationType.VEG.SWAMP, VegetationType.VEG.MANGROVE:
					a = 1.6
				VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.SAVANNA:
					a = 0.45
			a *= smoothstep(0.45, 0.85, wet)  # 气候/土壤湿润取强
			if river:
				a *= 1.8
			a *= lerpf(1.0, 1.6, big_river)  # 大河岸芦苇荡
			if lf == LandformType.LF.DELTA:
				a *= 1.4
			return a
		host.DETAIL_ALPINE_FLOWER:
			var a = 0.06
			match veg:
				VegetationType.VEG.ALPINE_MEADOW:
					a = 2.0
				VegetationType.VEG.ALPINE_TUNDRA, VegetationType.VEG.TUNDRA:
					a = 1.2
				VegetationType.VEG.TEMPERATE_GRASSLAND:
					a = 0.4
			if lf == LandformType.LF.MOUNTAIN or lf == LandformType.LF.HILL:
				a *= 1.25
			a *= smoothstep(0.78, 0.32, temp)  # 偏冷凉
			return a
	return 1.0



static func _is_decoration_archetype(host, arch: int) -> bool:

	return arch == host.DETAIL_ROCK or arch == host.DETAIL_SNOW_MOUND or arch == host.DETAIL_DEAD_SNAG



static func _aquatic_suitability(host, _arch: int, lf: int, veg: int, cover: int, state: Dictionary) -> float:

	if _spawn_domain(host) != host.SPAWN_WATER:
		return 0.0
	if cover == CoverType.CV.SEA_ICE or cover == CoverType.CV.GLACIER:
		return 0.0
	var landform_weight = _landform_weight(host, lf)
	var vegetation_weight = _vegetation_weight(host, veg)
	var cover_weight = _cover_weight(host, cover)
	if landform_weight <= 0.0 or vegetation_weight <= 0.0 or cover_weight <= 0.0:
		return 0.0
	var temp = float(state.get("temp", 0.5))
	var moisture = float(state.get("moisture", 0.5))
	var suitability = vegetation_weight * landform_weight * cover_weight
	# 水域生态不使用陆地 vegetation_vitality 做密度闸门；由温度/水体类型和 profile 权重决定。
	suitability *= lerpf(0.74, 1.15, clampf(moisture, 0.0, 1.0))
	suitability *= lerpf(0.70, 1.05, VegetationType.climate_compat_score(veg, temp, moisture))
	suitability *= _quality_density_scale(host)
	return clampf(suitability, 0.0, 1.25)


# 点缀/地貌类 archetype 的独立 suitability（不经植被权重）。

static func _decoration_suitability(host, arch: int, lf: int, cover: int, river: bool, state: Dictionary) -> float:

	if LandformType.is_water(lf):
		return 0.0
	var temp = float(state.get("temp", 0.5))
	var snow = float(state.get("snow", 0.0))
	var vitality = float(state.get("vitality", 0.7))
	var drought = float(state.get("drought", 0.0))
	var cold = float(state.get("cold", 0.0))
	var elev = float(state.get("elevation", 0.4))
	var s = 0.0
	match arch:
		host.DETAIL_ROCK:
			match lf:
				LandformType.LF.MOUNTAIN, LandformType.LF.PEAK:
					s = 1.1
				LandformType.LF.VOLCANO:
					s = 0.9
				LandformType.LF.BADLANDS:
					s = 0.95
				LandformType.LF.HILL:
					s = 0.5
				LandformType.LF.SALT_FLAT:
					s = 0.35
				_:
					s = 0.12
			# 越裸露（活力低）岩石越显
			s *= lerpf(1.25, 0.55, _vitality_normalized(host, vitality))
			# 高海拔裸岩更多
			s *= lerpf(0.85, 1.4, smoothstep(0.5, 0.95, elev))
			if river:
				s *= 0.6
		host.DETAIL_SNOW_MOUND:
			var snowy: float = maxf(snow, 1.0 if cover == CoverType.CV.SNOW or cover == CoverType.CV.PERMAFROST else 0.0)
			if cover == CoverType.CV.GLACIER:
				snowy = maxf(snowy, 0.85)
			s = smoothstep(0.22, 0.7, snowy) * 1.1
			s *= smoothstep(0.62, 0.2, temp)
			# 高海拔雪线以上常年积雪堆增多
			s *= lerpf(0.9, 1.3, smoothstep(0.55, 0.92, elev))
		host.DETAIL_DEAD_SNAG:
			# 低活力 + 旱/冷胁迫的"曾经有林"区域。枯立木点缀，适度可见即可。
			var stress: float = maxf(drought, cold)
			s = (1.0 - _vitality_normalized(host, vitality)) * lerpf(0.65, 1.5, clampf(stress, 0.0, 1.0))
			match lf:
				LandformType.LF.PLAIN, LandformType.LF.LOWLAND, LandformType.LF.HILL:
					s *= 1.3
				LandformType.LF.BADLANDS:
					s *= 0.95
				_:
					s *= 0.55
	s *= lerpf(0.18, 1.0, _climate_presence(host, state))
	# 点缀层的形态由 archetype 决定，但配置了 vegetation_weight_overrides 的层
	# （红树气生根、倒木、碎石坡）要靠它把自己收束到目标生物群系；不接进来的话
	# 那几张表是死配置，红树根会按"枯立木"规则长满所有低活力旱地。
	s *= _decoration_vegetation_filter(host, int(state.get("vegetation", VegetationType.VEG.NONE)))
	s *= _quality_density_scale(host)
	return clampf(s, 0.0, 1.25)


# 点缀层没有 _vegetation_weight 那样的基准表，所以这里把非空 overrides 当白名单：
# 列出的植被取表中权重，未列出的只留一点残量。倒木只该出现在林地、红树气生根只该
# 出现在红树林——列表本身就是"该出现在哪"的完整表达。


static func _decoration_vegetation_filter(host, veg: int) -> float:

	var overrides: Dictionary = _profile(host).vegetation_weight_overrides
	if overrides.is_empty():
		return 1.0
	if overrides.has(veg):
		return maxf(float(overrides[veg]), 0.0)
	var key = str(veg)
	if overrides.has(key):
		return maxf(float(overrides[key]), 0.0)
	return host.DECORATION_VEG_RESIDUAL



static func _try_append_instance(host, 
		cell,
		idx: int,
		key: int,
		attempt: int,
		cell_suitability: float,
		accept_p: float,
		state: Dictionary) -> void:

	var cfg = _profile(host)
	var climate_presence = _scatter_presence(host, state)
	if climate_presence <= 0.02:
		return
	var vitality = clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	if vitality <= cfg.vitality_dead_threshold:
		var dieback_noise = host._hash01(key, 931 + attempt)
		if dieback_noise < 1.0 - cfg.vitality_dieback_noise_strength:
			return
	var center = _cell_center(host, cell, idx)
	var pos = _candidate_position(host, center, key, attempt)
	var domain = _spawn_domain(host)
	var world_noise = _world_noise_suitability(host, pos)
	if world_noise <= 0.001:
		return
	var form = _candidate_form(host, key, attempt, world_noise, cell_suitability,
		clampf(_sample_density_for_size(host, idx, cell), 0.0, 1.0))
	var size = form.z
	# Candidate discs intentionally overlap adjacent hexes. Check the actual
	# destination cell and its six neighbours, not the source cell, so a canopy
	# spawned across a boundary cannot intrude into a known settlement.
	if domain != host.SPAWN_WATER and _overlaps_known_settlement(host, pos, size):
		return
	var candidate_is_water = _is_water_position(host, pos, cell, idx)
	if domain == host.SPAWN_LAND and candidate_is_water:
		return
	if domain == host.SPAWN_WATER and not candidate_is_water:
		return
	if domain != host.SPAWN_WATER and _is_river_body_position(host, pos):
		return
	var micro_noise = _world_micro_gap(host, pos, key, attempt)
	if micro_noise < cfg.micro_gap_threshold:
		return
	# world_noise_acceptance 现在只作用在斑块门上（决定噪声多快饱和到"满密度"），
	# 不再乘进密度量级。它原本是用来补偿 suitability² 压缩的，配额化之后如果继续
	# 乘在量级上，accept_p 只要超过 1/acceptance 就会被 clamp 到 1，顶端差异又被抹平。
	var noise_gate = pow(clampf(world_noise, 0.0, 1.0), 1.35)
	var patch_gate = clampf(noise_gate * cfg.world_noise_acceptance, 0.0, 1.0)
	var local_acceptance = clampf(accept_p * patch_gate, 0.0, 1.0)
	if host._hash01(key, 9300 + attempt) > local_acceptance:
		return
	if _sub_form_enabled(host) and _overlaps_cell_instance(host, idx, pos, size):
		return
	var variant = host._hash01(key, 300 + attempt)

	host._instance_cell_indices.append(idx)
	host._instance_cells.append(cell)
	host._instance_positions.append(pos)
	host._instance_rotations.append(_instance_rotation(host, key, attempt))
	host._instance_sizes.append(size)
	host._instance_seeds.append(host._hash01(key, 600 + attempt))
	host._instance_variants.append(variant)
	host._instance_forms.append(host.pack_form(int(form.x), int(form.y)))
	host._instance_scores.append(world_noise * 0.66 + cell_suitability * 0.27 + host._hash01(key, 7600 + attempt) * 0.07)



static func _form_knobs(host) -> Dictionary:

	var cfg = _profile(host)
	return {
		"sub_form_enabled": _sub_form_enabled(host),
		"crown_diameter_hex": float(cfg.get("crown_diameter_hex")),
		"cluster_density_threshold": float(cfg.get("cluster_density_threshold")),
		"grove_density_threshold": float(cfg.get("grove_density_threshold")),
		"grove_crown_min": int(cfg.get("grove_crown_min")),
		"grove_crown_max": int(cfg.get("grove_crown_max")),
		"edge_single_bias": float(cfg.get("edge_single_bias")),
		"element_count_min": int(cfg.get("element_count_min")),
		"element_count_max": int(cfg.get("element_count_max")),
		"impostor_quad_half": host.IMPOSTOR_QUAD_HALF,
	}



static func _sub_form_enabled(host) -> bool:

	var value = _profile(host).get("sub_form_enabled")
	return value != null and bool(value)


# Instances of one cell are appended consecutively; canopy patches of the same
# cell must not pile on each other (SAME_SOURCE: world_ext_detail.cpp).

static func _overlaps_cell_instance(host, idx: int, pos: Vector2, size: float) -> bool:

	var radius = size * host.IMPOSTOR_QUAD_HALF * host.SUB_FORM_PATCH_RADIUS
	var j = host._instance_cell_indices.size() - 1
	while j >= 0 and host._instance_cell_indices[j] == idx:
		var other = host._instance_sizes[j] * host.IMPOSTOR_QUAD_HALF * host.SUB_FORM_PATCH_RADIUS
		var limit = (radius + other) * host.SUB_FORM_OVERLAP
		if pos.distance_squared_to(host._instance_positions[j]) < limit * limit:
			return true
		j -= 1
	return false


# Returns (sub_form, count, size). Canopy profiles pick single / cluster /
# grove from local density and patch edge, and size the instance so each
# crown keeps crown_diameter_hex; other profiles draw element_count elements
# at their authored size. SAME_SOURCE: world_ext_detail.cpp candidate_form.

static func _candidate_form(host, key: int, attempt: int, world_noise: float, cell_suitability: float,
		size_density: float) -> Vector3:

	var cfg = _profile(host)
	var size_hash = host._hash01(key, 400 + attempt)
	var count_hash = host._hash01(key, 8100 + attempt)
	if _sub_form_enabled(host):
		var density = clampf(sqrt(clampf(world_noise, 0.0, 1.0)) * 0.6
			+ minf(cell_suitability, 1.0) * 0.4, 0.0, 1.0)
		var single_p = float(cfg.edge_single_bias) * (1.0 - smoothstep(0.15, 0.55, world_noise))
		var edge_roll = host._hash01(key, 8200 + attempt)
		var sub_form = host.SUB_FORM_SINGLE
		var count = 1
		if density >= float(cfg.grove_density_threshold) and edge_roll >= single_p:
			sub_form = host.SUB_FORM_GROVE
			var t = (density - float(cfg.grove_density_threshold)) \
				/ maxf(1.0 - float(cfg.grove_density_threshold), 0.001)
			var lo = mini(int(cfg.grove_crown_min), int(cfg.grove_crown_max))
			var hi = maxi(int(cfg.grove_crown_min), int(cfg.grove_crown_max))
			count = int(round(lerpf(float(lo), float(hi), clampf(t * 0.8 + count_hash * 0.35, 0.0, 1.0))))
			count = clampi(count, 5, host.FORM_COUNT_MAX)
		elif density >= float(cfg.cluster_density_threshold) and edge_roll >= single_p:
			sub_form = host.SUB_FORM_CLUSTER
			count = 2 + int(floor(count_hash * 2.999))
		var crown_world = float(cfg.crown_diameter_hex) * host._hex_size
		var size = crown_world / (2.0 * host.IMPOSTOR_QUAD_HALF * host.crown_local_radius(count))
		size *= lerpf(0.88, 1.12, size_hash) * lerpf(0.92, 1.06, size_density)
		size *= _quality_size_scale(host)
		return Vector3(float(sub_form), float(count), size)
	var min_size: float = minf(cfg.min_size_factor, cfg.max_size_factor)
	var max_size: float = maxf(cfg.min_size_factor, cfg.max_size_factor)
	var size = host._hex_size * lerpf(min_size, max_size, size_hash)
	size *= lerpf(0.85, 1.12, size_density)
	size *= _quality_size_scale(host)
	var lo_n = clampi(mini(int(cfg.element_count_min), int(cfg.element_count_max)), 1, host.FORM_COUNT_MAX)
	var hi_n = clampi(maxi(int(cfg.element_count_min), int(cfg.element_count_max)), 1, host.FORM_COUNT_MAX)
	var n = lo_n + int(floor(count_hash * float(hi_n - lo_n + 1) * 0.9999))
	return Vector3(float(host.SUB_FORM_SINGLE), float(n), size)



static func _overlaps_known_settlement(host, pos: Vector2, candidate_size: float) -> bool:

	if host._map == null or host._settlement_core_buckets.is_empty():
		return false
	var destination = HexUtils.world_to_wrapped_cell(host._map, pos, host._hex_size)
	if destination == null:
		return false
	if _cell_overlaps_settlement(host, destination, pos, candidate_size):
		return true
	for neighbour in host._map.get_neighbors(destination):
		if _cell_overlaps_settlement(host, neighbour, pos, candidate_size):
			return true
	return false



static func _cell_overlaps_settlement(host, cell, pos: Vector2, candidate_size: float) -> bool:

	if cell == null:
		return false
	var idx = _cell_index(host, cell, -1)
	if idx < 0 or idx >= host._settlement_core_buckets.size():
		return false
	var bucket = mini(15, int(host._settlement_core_buckets[idx]))
	if bucket <= 0:
		return false
	var canonical_center = HexUtils.cube_to_world(
		int(cell.q), int(cell.r), host._hex_size)
	var period = HexUtils.wrap_period_x(int(host._map.width), host._hex_size)
	var display_center = HexUtils.nearest_display_world(
		canonical_center, pos.x, period)
	var radius = _settlement_core_radius(host, bucket) \
		+ maxf(0.0, candidate_size) * host.SETTLEMENT_DETAIL_FOOTPRINT_RADIUS
	return pos.distance_squared_to(display_center) < radius * radius



static func _settlement_core_radius(host, bucket: int) -> float:

	var density = clampf(float(bucket) / 15.0, 0.0, 1.0)
	var spread = lerpf(
		host.SETTLEMENT_BUILDING_SPREAD_MIN,
		host.SETTLEMENT_BUILDING_SPREAD_MAX,
		density)
	var building_scale = lerpf(
		host.SETTLEMENT_BUILDING_SCALE_MIN,
		host.SETTLEMENT_BUILDING_SCALE_MAX,
		density)
	return (host.SETTLEMENT_OUTER_RING_FACTOR * spread
		+ host.SETTLEMENT_ART_HALF_WIDTH * building_scale
			* host.SETTLEMENT_BUILDING_VISUAL_SCALE) * host._hex_size



static func _apply_instance_cap(host) -> void:

	var cap = _instance_cap(host)
	if cap <= 0:
		host.clear()
		return
	var n = host._instance_cell_indices.size()
	if n <= cap:
		return
	var order: Array[int] = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		return host._instance_scores[a] > host._instance_scores[b]
	)
	var keep_lookup = {}
	for i in range(cap):
		keep_lookup[order[i]] = true
	var next_cell_indices = PackedInt32Array()
	var next_positions = PackedVector2Array()
	var next_rotations = PackedFloat32Array()
	var next_sizes = PackedFloat32Array()
	var next_seeds = PackedFloat32Array()
	var next_variants = PackedFloat32Array()
	var next_forms = PackedFloat32Array()
	var next_scores = PackedFloat32Array()
	var next_cells: Array = []
	for i in range(n):
		if not keep_lookup.has(i):
			continue
		next_cell_indices.append(host._instance_cell_indices[i])
		next_positions.append(host._instance_positions[i])
		next_rotations.append(host._instance_rotations[i])
		next_sizes.append(host._instance_sizes[i])
		next_seeds.append(host._instance_seeds[i])
		next_variants.append(host._instance_variants[i])
		next_forms.append(host._instance_forms[i])
		next_scores.append(host._instance_scores[i])
		next_cells.append(host._instance_cells[i])
	host._instance_cell_indices = next_cell_indices
	host._instance_positions = next_positions
	host._instance_rotations = next_rotations
	host._instance_sizes = next_sizes
	host._instance_seeds = next_seeds
	host._instance_variants = next_variants
	host._instance_forms = next_forms
	host._instance_scores = next_scores
	host._instance_cells = next_cells



static func _candidate_position(host, center: Vector2, key: int, attempt: int) -> Vector2:

	var cfg = _profile(host)
	# R2 low-discrepancy sequence: successive attempts cover the hex disc evenly.
	var angle: float = fposmod(host._hash01(key, 101) + float(attempt) * 0.7548776662, 1.0) * TAU
	var radius: float = sqrt(fposmod(host._hash01(key, 200) + float(attempt) * 0.5698402910, 1.0)) \
		* host._hex_size * _effective_spawn_radius_factor(host)
	var jitter: Vector2 = Vector2(cos(angle), sin(angle)) * radius
	var base_pos: Vector2 = center + jitter
	var warp: Vector2 = Vector2(
		host._value_noise2(base_pos.x * 0.033, base_pos.y * 0.033, 911) - 0.5,
		host._value_noise2(base_pos.x * 0.033, base_pos.y * 0.033, 977) - 0.5
	) * (host._hex_size * cfg.world_noise_warp_strength)
	return base_pos + warp



static func _world_noise_suitability(host, world_pos: Vector2) -> float:

	var cfg = _profile(host)
	var p = world_pos / maxf(host._hex_size, 1.0)
	var warp = Vector2(
		host._value_noise2(p.x * cfg.patch_frequency * 0.55, p.y * cfg.patch_frequency * 0.55, 313) - 0.5,
		host._value_noise2(p.x * cfg.patch_frequency * 0.55, p.y * cfg.patch_frequency * 0.55, 719) - 0.5
	) * 7.0
	var coarse = host._value_noise2((p.x + warp.x) * cfg.patch_frequency, (p.y + warp.y) * cfg.patch_frequency, 17)
	var mid = host._value_noise2(p.x * cfg.patch_frequency * 3.1 + 19.0, p.y * cfg.patch_frequency * 3.1 - 11.0, 41)
	var fine = host._value_noise2(p.x * cfg.patch_frequency * 8.5 - 37.0, p.y * cfg.patch_frequency * 8.5 + 23.0, 83)
	var patch = smoothstep(cfg.patch_cutoff, 1.0, coarse)
	patch = pow(patch, cfg.patch_contrast)
	patch *= lerpf(1.0, lerpf(0.55, 1.35, mid), cfg.world_noise_mid_mix)
	patch *= lerpf(1.0, lerpf(0.82, 1.18, fine), cfg.world_noise_fine_mix)
	return clampf(patch, 0.0, 1.0)



static func _world_micro_gap(host, world_pos: Vector2, key: int, attempt: int) -> float:

	var p = world_pos / maxf(host._hex_size, 1.0)
	var continuous = host._value_noise2(p.x * 0.82 + 23.0, p.y * 0.82 - 17.0, 131)
	var dither = host._hash01(key, 9900 + attempt * 19)
	return clampf(continuous * 0.72 + dither * 0.28, 0.0, 1.0)



static func _instance_transform(host, i: int) -> Transform2D:

	var rot = host._instance_rotations[i]
	var size = host._instance_sizes[i]
	var x_axis = Vector2(cos(rot), sin(rot)) * size
	var y_axis = Vector2(-sin(rot), cos(rot)) * size
	return Transform2D(x_axis, y_axis, host._instance_positions[i])



static func _instance_rotation(host, key: int, attempt: int) -> float:

	var full = host._hash01(key, 500 + attempt) * TAU
	match _rotation_mode(host):
		host.ROT_UPRIGHT:
			return 0.0
		host.ROT_UPRIGHT_JITTER:
			return (host._hash01(key, 501 + attempt) * 2.0 - 1.0) * deg_to_rad(_upright_jitter_degrees(host))
	var strength = _random_rotation_strength(host)
	if strength >= 0.999:
		return full
	return (host._hash01(key, 501 + attempt) * 2.0 - 1.0) * PI * strength



static func _cached_detail_mesh(host) -> ArrayMesh:

	if host._mesh_cache.has("quad"):
		return host._mesh_cache["quad"]
	var mesh = _build_shrub_mesh(host)
	host._mesh_cache["quad"] = mesh
	return mesh


# Every form is drawn procedurally on one quad (vegetation_forms.gdshaderinc).
# Its half extent keeps the old mesh footprint so instance size, settlement
# avoidance and wrap margins keep their meaning.

static func _build_shrub_mesh(host) -> ArrayMesh:

	var h = host.IMPOSTOR_QUAD_HALF
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([
		Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh




static func _sample_cell_state(host, idx: int, cell = null) -> Dictionary:

	return {
		"temp": host._f32(host._map.temp_arr, idx, cell.temperature if cell != null else 0.5),
		"moisture": host._f32(host._map.moisture_arr, idx, cell.moisture if cell != null else 0.5),
		"snow": host._f32(host._map.snow_cover_arr, idx, cell.snow_cover if cell != null else 0.0),
		"weather_intensity": host._f32(host._map.weather_intensity_arr, idx, cell.weather_intensity if cell != null else 0.0),
		"vitality": host._f32(host._map.vegetation_vitality_arr, idx, cell.vegetation_vitality if cell != null else 0.7),
		"heat": host._f32(host._map.vegetation_heat_stress_arr, idx, cell.vegetation_heat_stress if cell != null else 0.0),
		"drought": host._f32(host._map.vegetation_drought_stress_arr, idx, cell.vegetation_drought_stress if cell != null else 0.0),
		"cold": host._f32(host._map.vegetation_cold_stress_arr, idx, cell.vegetation_cold_stress if cell != null else 0.0),
		"landform": host._u8(host._map.landform_arr, idx, cell.landform if cell != null else LandformType.LF.PLAIN),
		"vegetation": host._u8(host._map.vegetation_arr, idx, cell.vegetation if cell != null else VegetationType.VEG.NONE),
		"cover": host._u8(host._map.cover_arr, idx, cell.cover if cell != null else CoverType.CV.NONE),
		"weather_type": host._u8(host._map.weather_type_arr, idx, cell.weather_type if cell != null else 0),
		# 阶段 C：放置侧全量参数（归一化 / 物理量），喂入 archetype 亲和 + 林线 + 地貌 suitability。
		"elevation": host._f32(host._map.elevation_arr, idx, cell.elevation if cell != null else 0.40),
		"soil_moisture": host._f32(host._map.soil_moisture_arr, idx, cell.soil_moisture if cell != null else 0.40),
		"river_discharge": host._f32(host._map.river_discharge_arr, idx, 0.0),
		"wind_speed": host._f32(host._map.wind_speed_arr, idx, cell.wind_speed if cell != null else 0.0),
		"snow_visual": 0.0,
	}



static func _base_color_for_state(host, state: Dictionary, variant: float) -> Color:

	var veg = int(state.get("vegetation", VegetationType.VEG.NONE))
	var base = _base_color_for_vegetation(host, veg)
	var shade = (variant - 0.5) * 0.16
	if shade >= 0.0:
		base = base.lightened(shade)
	else:
		base = base.darkened(-shade)
	return base



static func _base_color_for_vegetation(host, veg: int) -> Color:

	var cfg = _profile(host)
	if bool(cfg.get("base_color_override_enabled")):
		return cfg.get("base_color_override")
	match _detail_kind(host):
		host.DETAIL_TREE:
			return _tree_base_color_for_vegetation(host, veg)
		host.DETAIL_GRASS:
			return _grass_base_color_for_vegetation(host, veg)
		host.DETAIL_CONIFER:
			return Color(0.12, 0.34, 0.21, 0.98)
		host.DETAIL_PALM:
			return Color(0.16, 0.40, 0.20, 0.96)
		host.DETAIL_CACTUS:
			return Color(0.30, 0.48, 0.32, 0.96)
		host.DETAIL_REED:
			return Color(0.42, 0.52, 0.24, 0.92)
		host.DETAIL_ALPINE_FLOWER:
			return Color(0.64, 0.68, 0.52, 0.98)
		host.DETAIL_ROCK:
			return Color(0.54, 0.54, 0.57, 1.0)
		host.DETAIL_SNOW_MOUND:
			return Color(0.95, 0.97, 1.0, 1.0)
		host.DETAIL_DEAD_SNAG:
			return Color(0.42, 0.36, 0.30, 0.98)
	match veg:
		VegetationType.VEG.BOREAL_SHRUB:
			return Color(0.16, 0.33, 0.20, 0.90)
		VegetationType.VEG.MEDITERRANEAN_SHRUB:
			return Color(0.34, 0.42, 0.22, 0.90)
		VegetationType.VEG.DESERT_SCRUB:
			return Color(0.42, 0.38, 0.22, 0.88)
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			return Color(0.31, 0.38, 0.25, 0.86)
		VegetationType.VEG.SWAMP, VegetationType.VEG.MARSH:
			return Color(0.13, 0.32, 0.20, 0.88)
		VegetationType.VEG.SAVANNA, VegetationType.VEG.TEMPERATE_STEPPE:
			return Color(0.32, 0.43, 0.21, 0.88)
		_:
			return Color(0.18, 0.39, 0.19, 0.88)



static func _tree_base_color_for_vegetation(host, veg: int) -> Color:

	match veg:
		VegetationType.VEG.TAIGA, VegetationType.VEG.TEMPERATE_CONIFER:
			return Color(0.12, 0.36, 0.19, 0.96)
		VegetationType.VEG.TEMPERATE_DECIDUOUS:
			return Color(0.18, 0.48, 0.22, 0.96)
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			return Color(0.08, 0.40, 0.20, 0.98)
		VegetationType.VEG.TROPICAL_DRY_FOREST:
			return Color(0.16, 0.36, 0.18, 0.92)
		VegetationType.VEG.SWAMP, VegetationType.VEG.MANGROVE:
			return Color(0.08, 0.28, 0.18, 0.92)
		VegetationType.VEG.SAVANNA:
			return Color(0.18, 0.36, 0.18, 0.88)
		_:
			return Color(0.16, 0.42, 0.20, 0.94)



static func _grass_base_color_for_vegetation(host, veg: int) -> Color:

	match veg:
		VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.ALPINE_MEADOW:
			return Color(0.34, 0.58, 0.22, 0.72)
		VegetationType.VEG.TEMPERATE_STEPPE, VegetationType.VEG.SAVANNA:
			return Color(0.48, 0.54, 0.22, 0.70)
		VegetationType.VEG.MARSH, VegetationType.VEG.SWAMP:
			return Color(0.20, 0.48, 0.25, 0.74)
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			return Color(0.38, 0.44, 0.26, 0.66)
		VegetationType.VEG.DESERT_SCRUB:
			return Color(0.46, 0.42, 0.22, 0.60)
		_:
			return Color(0.30, 0.52, 0.22, 0.68)



static func _profile_weight_override(host, prop: StringName, key: int, fallback: float) -> float:

	var cfg = _profile(host)
	var raw = cfg.get(prop)
	if not (raw is Dictionary):
		return fallback
	var dict: Dictionary = raw
	if dict.has(key):
		return float(dict[key])
	var key_str = str(key)
	if dict.has(key_str):
		return float(dict[key_str])
	return fallback



static func _vegetation_weight(host, veg: int) -> float:

	var base = 0.0
	match _detail_kind(host):
		host.DETAIL_TREE:
			base = _tree_vegetation_weight(host, veg)
			return _profile_weight_override(host, &"vegetation_weight_overrides", veg, base)
		host.DETAIL_GRASS:
			base = _grass_vegetation_weight(host, veg)
			return _profile_weight_override(host, &"vegetation_weight_overrides", veg, base)
	match veg:
		VegetationType.VEG.BOREAL_SHRUB, VegetationType.VEG.MEDITERRANEAN_SHRUB:
			base = 1.15
		VegetationType.VEG.DESERT_SCRUB:
			base = 0.78
		VegetationType.VEG.TAIGA, VegetationType.VEG.TROPICAL_DRY_FOREST:
			base = 0.92
		VegetationType.VEG.TEMPERATE_DECIDUOUS, VegetationType.VEG.TEMPERATE_CONIFER:
			base = 0.84
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			base = 0.70
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			base = 0.42
		VegetationType.VEG.SAVANNA:
			base = 0.62
		VegetationType.VEG.TEMPERATE_STEPPE:
			base = 0.46
		VegetationType.VEG.SWAMP:
			base = 0.56
		VegetationType.VEG.MARSH:
			base = 0.34
		VegetationType.VEG.TEMPERATE_GRASSLAND:
			base = 0.36
		VegetationType.VEG.OASIS_VEG:
			base = 0.58
		VegetationType.VEG.XERIC_DESERT, VegetationType.VEG.POLAR_DESERT:
			base = 0.02
		VegetationType.VEG.NONE, VegetationType.VEG.KELP_FOREST, VegetationType.VEG.CORAL_REEF:
			base = 0.0
		_:
			base = 0.10
	return _profile_weight_override(host, &"vegetation_weight_overrides", veg, base)



static func _tree_vegetation_weight(host, veg: int) -> float:

	match veg:
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			return 1.22
		VegetationType.VEG.TEMPERATE_DECIDUOUS, VegetationType.VEG.TEMPERATE_CONIFER:
			return 1.08
		VegetationType.VEG.TAIGA:
			return 0.98
		VegetationType.VEG.TROPICAL_DRY_FOREST:
			return 0.82
		VegetationType.VEG.SWAMP, VegetationType.VEG.MANGROVE:
			return 0.64
		VegetationType.VEG.SAVANNA:
			return 0.28
		VegetationType.VEG.BOREAL_SHRUB, VegetationType.VEG.MEDITERRANEAN_SHRUB:
			return 0.12
		VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.TEMPERATE_STEPPE:
			return 0.05
		VegetationType.VEG.DESERT_SCRUB, VegetationType.VEG.XERIC_DESERT:
			return 0.0
		VegetationType.VEG.NONE, VegetationType.VEG.KELP_FOREST, VegetationType.VEG.CORAL_REEF:
			return 0.0
		_:
			return 0.04



static func _grass_vegetation_weight(host, veg: int) -> float:

	match veg:
		VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.ALPINE_MEADOW:
			return 1.22
		VegetationType.VEG.TEMPERATE_STEPPE:
			return 0.98
		VegetationType.VEG.SAVANNA:
			return 0.84
		VegetationType.VEG.MARSH:
			return 0.78
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			return 0.62
		VegetationType.VEG.DESERT_SCRUB:
			return 0.32
		VegetationType.VEG.BOREAL_SHRUB, VegetationType.VEG.MEDITERRANEAN_SHRUB:
			return 0.44
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			return 0.24
		VegetationType.VEG.TAIGA, VegetationType.VEG.TEMPERATE_DECIDUOUS, VegetationType.VEG.TEMPERATE_CONIFER:
			return 0.30
		VegetationType.VEG.XERIC_DESERT, VegetationType.VEG.POLAR_DESERT:
			return 0.02
		VegetationType.VEG.NONE, VegetationType.VEG.KELP_FOREST, VegetationType.VEG.CORAL_REEF:
			return 0.0
		_:
			return 0.18



static func _landform_weight(host, lf: int) -> float:

	var base = 0.0
	match _detail_kind(host):
		host.DETAIL_TREE:
			base = _tree_landform_weight(host, lf)
			return _profile_weight_override(host, &"landform_weight_overrides", lf, base)
		host.DETAIL_GRASS:
			base = _grass_landform_weight(host, lf)
			return _profile_weight_override(host, &"landform_weight_overrides", lf, base)
	match lf:
		LandformType.LF.PLAIN, LandformType.LF.LOWLAND:
			base = 1.0
		LandformType.LF.HILL:
			base = 0.84
		LandformType.LF.DELTA:
			base = 0.64
		LandformType.LF.BADLANDS:
			base = 0.42
		LandformType.LF.SALT_FLAT:
			base = 0.06
		LandformType.LF.MOUNTAIN:
			base = 0.14
		LandformType.LF.PEAK, LandformType.LF.VOLCANO:
			base = 0.0
		_:
			base = 0.0 if LandformType.is_water(lf) else 0.55
	return _profile_weight_override(host, &"landform_weight_overrides", lf, base)



static func _tree_landform_weight(host, lf: int) -> float:

	match lf:
		LandformType.LF.PLAIN, LandformType.LF.LOWLAND:
			return 1.0
		LandformType.LF.HILL:
			return 0.74
		LandformType.LF.DELTA:
			return 0.46
		LandformType.LF.MOUNTAIN:
			return 0.16
		LandformType.LF.BADLANDS, LandformType.LF.SALT_FLAT:
			return 0.0
		LandformType.LF.PEAK, LandformType.LF.VOLCANO:
			return 0.0
		_:
			return 0.0 if LandformType.is_water(lf) else 0.38



static func _grass_landform_weight(host, lf: int) -> float:

	match lf:
		LandformType.LF.PLAIN, LandformType.LF.LOWLAND:
			return 1.0
		LandformType.LF.HILL:
			return 0.82
		LandformType.LF.DELTA:
			return 0.72
		LandformType.LF.BADLANDS:
			return 0.26
		LandformType.LF.SALT_FLAT:
			return 0.04
		LandformType.LF.MOUNTAIN:
			return 0.32
		LandformType.LF.PEAK, LandformType.LF.VOLCANO:
			return 0.0
		_:
			return 0.0 if LandformType.is_water(lf) else 0.58



static func _cover_weight(host, cover: int) -> float:

	var base = 1.0
	match cover:
		CoverType.CV.GLACIER, CoverType.CV.SEA_ICE, CoverType.CV.PELAGIC_BLOOM:
			base = 0.0
		CoverType.CV.FLOODING:
			base = 0.18
		CoverType.CV.SNOW:
			base = 0.48
		CoverType.CV.PERMAFROST:
			base = 0.62
		_:
			base = 1.0
	return _profile_weight_override(host, &"cover_weight_overrides", cover, base)



static func _sample_density_for_size(host, idx: int, cell = null) -> float:

	var state = _sample_cell_state(host, idx, cell)
	var veg = int(state.get("vegetation", VegetationType.VEG.NONE))
	var lf = int(state.get("landform", LandformType.LF.PLAIN))
	var cover = int(state.get("cover", CoverType.CV.NONE))
	return _vegetation_weight(host, veg) * _landform_weight(host, lf) * _cover_weight(host, cover)



static func _cell_ecology_density_bias(host, state: Dictionary) -> float:

	var cfg = _profile(host)
	var moisture = float(state.get("moisture", 0.5))
	var vitality = float(state.get("vitality", 0.7))
	var wet_corridor: float = smoothstep(0.46, 0.82, moisture) * cfg.moisture_corridor_boost
	var vitality_boost: float = _vitality_normalized(host, vitality) * cfg.vitality_patch_boost
	return clampf(0.68 + wet_corridor * 0.26 + vitality_boost * 0.30, 0.28, 1.35)



static func _climate_presence(host, state: Dictionary) -> float:

	var cfg = _profile(host)
	var moisture = float(state.get("moisture", 0.5))
	var snow = float(state.get("snow", 0.0))
	var vitality = float(state.get("vitality", 0.7))
	var heat = float(state.get("heat", 0.0))
	var drought = float(state.get("drought", 0.0))
	var cold = float(state.get("cold", 0.0))
	var wt = int(state.get("weather_type", 0))
	var wi = float(state.get("weather_intensity", 0.0))
	if wt == host._WT_DROUGHT or wt == host._WT_HEATWAVE:
		drought = maxf(drought, wi * 0.65)
		heat = maxf(heat, wi * 0.52)
	elif wt == host._WT_BLIZZARD:
		snow = maxf(snow, wi * 0.85)
		cold = maxf(cold, wi * 0.62)
	elif wt == host._WT_RAIN or wt == host._WT_STORM or wt == host._WT_MONSOON:
		moisture = clampf(moisture + wi * 0.20, 0.0, 1.0)

	var dry = clampf(maxf(drought, maxf(heat * 0.78, (0.34 - moisture) * 1.9)), 0.0, 1.0)
	var snow_hide = clampf(maxf(snow, cold * 0.55), 0.0, 1.0)
	var presence = pow(_vitality_normalized(host, vitality), cfg.vitality_alpha_power)
	presence *= 1.0 - dry * cfg.stress_hide_strength
	presence *= 1.0 - snow_hide * cfg.snow_hide_strength
	return clampf(presence, 0.0, 1.0)



static func _scatter_presence(host, state: Dictionary) -> float:

	if _spawn_domain(host) == host.SPAWN_WATER:
		var cover = int(state.get("cover", CoverType.CV.NONE))
		if cover == CoverType.CV.SEA_ICE or cover == CoverType.CV.GLACIER:
			return 0.0
		return 1.0
	return _climate_presence(host, state)



static func _vitality_normalized(host, vitality: float) -> float:

	var cfg = _profile(host)
	var dead: float = minf(cfg.vitality_dead_threshold, cfg.vitality_healthy_threshold - 0.001)
	var healthy: float = maxf(cfg.vitality_healthy_threshold, dead + 0.001)
	return clampf((clampf(vitality, 0.0, 1.0) - dead) / (healthy - dead), 0.0, 1.0)



static func _vitality_density_factor(host, state: Dictionary) -> float:

	var cfg = _profile(host)
	var vitality = clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	if vitality <= cfg.vitality_dead_threshold:
		return 0.0
	var normalized = _vitality_normalized(host, vitality)
	var sparse_factor = lerpf(0.10, 0.62, smoothstep(
		cfg.vitality_dead_threshold,
		maxf(cfg.vitality_sparse_threshold, cfg.vitality_dead_threshold + 0.001),
		vitality
	))
	var healthy_factor = lerpf(0.62, 1.20, pow(normalized, cfg.vitality_density_power))
	return minf(sparse_factor, healthy_factor) if vitality < cfg.vitality_sparse_threshold else healthy_factor



static func _vitality_size_scale(host, state: Dictionary) -> float:

	var cfg = _profile(host)
	var vitality = clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	var normalized = _vitality_normalized(host, vitality)
	return lerpf(cfg.vitality_size_min, cfg.vitality_size_max, pow(normalized, 0.85))



static func _is_water_cell(host, cell, idx: int) -> bool:

	if idx >= 0 and idx < host._map.is_water_arr.size() and host._map.is_water_arr[idx] > 0:
		return true
	var lf = host._u8(host._map.landform_arr, idx, cell.landform if cell != null else LandformType.LF.OCEAN)
	if LandformType.is_water(lf):
		return true
	if cell != null and LandformType.is_water(cell.landform):
		return true
	return false



static func _has_river_cell(host, cell, idx: int) -> bool:

	if idx >= 0 and idx < host._map.has_river_arr.size():
		return host._map.has_river_arr[idx] > 0
	return bool(cell.has_river) if cell != null else false



static func _is_water_position(host, world_pos: Vector2, _fallback_cell, fallback_idx: int) -> bool:

	if host._map == null:
		return false
	var cell = HexUtils.world_to_wrapped_cell(host._map, world_pos, host._hex_size)
	if cell == null:
		return true
	var idx = _cell_index(host, cell, fallback_idx)
	return _is_water_cell(host, cell, idx)



static func _is_river_body_position(host, world_pos: Vector2) -> bool:

	if host._world == null or host._world.flow_buffer.is_empty():
		return false
	return host._world.sample_flow(world_pos) >= _profile(host).river_clear_threshold



static func _cell_center(host, cell, idx: int) -> Vector2:

	if idx >= 0 and idx < host._map.cell_pos_x_arr.size() and idx < host._map.cell_pos_y_arr.size():
		return Vector2(host._map.cell_pos_x_arr[idx], host._map.cell_pos_y_arr[idx]) * host._hex_size
	return HexUtils.cube_to_world(int(cell.q), int(cell.r), host._hex_size)



static func _cell_index(host, cell, fallback: int) -> int:

	var idx = int(cell.index)
	return idx if idx >= 0 else -1



static func _cell_hash_key(host, cell, fallback: int) -> int:

	if cell != null:
		var idx = int(cell.index)
		if idx >= 0:
			return idx
		return int(cell.q) * 4099 + int(cell.r) * 9176 + fallback
	return fallback



static func _base_max_per_cell(host) -> int:

	var cfg = _profile(host)
	if _limited_platform_density_tier(host):
		match _active_quality_tier(host):
			0:
				return maxi(0, cfg.mobile_max_per_cell_quality0)
			1:
				return maxi(0, cfg.mobile_max_per_cell_quality1)
			_:
				return maxi(0, cfg.mobile_max_per_cell_quality2)
	match _active_quality_tier(host):
		0:
			return maxi(0, cfg.desktop_max_per_cell_quality0)
		1:
			return maxi(0, cfg.desktop_max_per_cell_quality1)
		_:
			return maxi(0, cfg.desktop_max_per_cell_quality2)



static func _max_per_cell(host) -> int:

	var baseline = _base_max_per_cell(host)
	return maxi(baseline, int(ceil(float(baseline) * host._resolved_lod_near_density_multiplier())))



static func _base_instance_cap(host) -> int:

	var cfg = _profile(host)
	if _limited_platform_density_tier(host):
		match _active_quality_tier(host):
			0:
				return maxi(0, cfg.mobile_max_instances_quality0)
			1:
				return maxi(0, cfg.mobile_max_instances_quality1)
			_:
				return maxi(0, cfg.mobile_max_instances_quality2)
	match _active_quality_tier(host):
		0:
			return maxi(0, cfg.desktop_max_instances_quality0)
		1:
			return maxi(0, cfg.desktop_max_instances_quality1)
		_:
			return maxi(0, cfg.desktop_max_instances_quality2)



static func _instance_cap(host) -> int:

	var baseline = _base_instance_cap(host)
	return maxi(baseline, int(ceil(float(baseline) * host._resolved_lod_near_density_multiplier())))



static func _quality_lobe_count(host) -> int:

	var cfg = _profile(host)
	if OS.has_feature("mobile"):
		match _active_quality_tier(host):
			0:
				return clampi(cfg.mobile_lobes_quality0, 2, 8)
			1:
				return clampi(cfg.mobile_lobes_quality1, 2, 8)
			_:
				return clampi(cfg.mobile_lobes_quality2, 2, 8)
	match _active_quality_tier(host):
		0:
			return clampi(cfg.desktop_lobes_quality0, 2, 8)
		1:
			return clampi(cfg.desktop_lobes_quality1, 2, 8)
		_:
			return clampi(cfg.desktop_lobes_quality2, 2, 8)



static func _quality_density_scale(host) -> float:

	var cfg = _profile(host)
	if _limited_platform_density_tier(host):
		match _active_quality_tier(host):
			0:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality0)
			1:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality1)
			_:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality2)
	match _active_quality_tier(host):
		0:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality0)
		1:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality1)
		_:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality2)



static func _quality_size_scale(host) -> float:

	var cfg = _profile(host)
	if OS.has_feature("mobile"):
		match _active_quality_tier(host):
			0:
				return maxf(0.0, cfg.mobile_size_scale_quality0)
			1:
				return maxf(0.0, cfg.mobile_size_scale_quality1)
			_:
				return maxf(0.0, cfg.mobile_size_scale_quality2)
	match _active_quality_tier(host):
		0:
			return maxf(0.0, cfg.desktop_size_scale_quality0)
		1:
			return maxf(0.0, cfg.desktop_size_scale_quality1)
		_:
			return maxf(0.0, cfg.desktop_size_scale_quality2)



static func _active_quality_tier(host) -> int:

	# Web's compile tier stays LOW for warmup parity. Instance budgets and
	# shading/form uniforms must follow the user's runtime quality instead.
	if OS.has_feature("web"):
		return clampi(host._visual_quality, 0, 2)
	return clampi(
		host._mobile_quality_tier if DCFeatureFlags.uses_shader_quality_tier() else host._visual_quality,
		0, 2)


# [web-mobile-density-halving 2026-10-30] 受限平台（浏览器 WebGL2 / 移动 GPU）共用
# 同一套"性能换密度"档。web 之前走的是桌面档（density 1.0–1.35、每层上限
# 14000–24000 实例），浏览器里根本跑不动；现在 web 自动拿到 Profile 上已有的
# mobile_* 档（density 0.46–0.70、每层上限 1800–2600，约为桌面的 45%），
# 移动端行为不变，桌面端仍然走 desktop_* 档、完全不受影响。
# 只切"密度 / 每格上限 / 每层上限"这三项；尺寸档与 lobe 档仍按移动端原判定，
# 避免在 web 上额外改变植株大小（那属于另一条视觉口径）。

static func _limited_platform_density_tier(host) -> bool:

	return DCFeatureFlags.uses_shader_quality_tier()



static func _detail_kind(host) -> int:

	var cfg = _profile(host)
	return clampi(int(cfg.detail_kind), host.DETAIL_SHRUB, host.DETAIL_DEAD_SNAG)



static func _profile(host) -> Resource:

	return host.profile if host.profile != null else host.DEFAULT_PROFILE



static func _effective_spawn_radius_factor(host) -> float:

	var cfg = _profile(host)
	var configured_floor = cfg.get("seamless_spawn_radius_floor")
	var overlap_floor = 1.06 if configured_floor == null else float(configured_floor)
	return maxf(float(cfg.spawn_radius_factor), clampf(overlap_floor, 0.85, 1.35))



static func _profile_int(host, prop: StringName, fallback: int) -> int:

	var v = _profile(host).get(prop)
	return fallback if v == null else int(v)



static func _profile_float(host, prop: StringName, fallback: float) -> float:

	var v = _profile(host).get(prop)
	return fallback if v == null else float(v)



static func _spawn_domain(host) -> int:

	return clampi(_profile_int(host, &"spawn_domain", host.SPAWN_LAND), host.SPAWN_LAND, host.SPAWN_ANY)



static func _rotation_mode(host) -> int:

	return clampi(_profile_int(host, &"rotation_mode", host.ROT_RANDOM_FULL), host.ROT_RANDOM_FULL, host.ROT_UPRIGHT_JITTER)



static func _random_rotation_strength(host) -> float:

	return clampf(_profile_float(host, &"random_rotation_strength", 1.0), 0.0, 1.0)



static func _upright_jitter_degrees(host) -> float:

	return clampf(_profile_float(host, &"upright_jitter_degrees", 6.0), 0.0, 35.0)



