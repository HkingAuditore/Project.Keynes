extends RefCounted

## Samples published ecology and chooses the density and color of vegetation forms.

const VegetationColors = preload("res://scripts/rendering/shrub/vegetation_colors.gd")


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
	return VegetationColors._base_color_for_vegetation(host, veg)



static func _tree_base_color_for_vegetation(host, veg: int) -> Color:
	return VegetationColors._tree_base_color_for_vegetation(host, veg)



static func _grass_base_color_for_vegetation(host, veg: int) -> Color:
	return VegetationColors._grass_base_color_for_vegetation(host, veg)



static func _profile_weight_override(host, prop: StringName, key: int, fallback: float) -> float:

	var cfg = host._profile()
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
	match host._detail_kind():
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
	match host._detail_kind():
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

	var cfg = host._profile()
	var moisture = float(state.get("moisture", 0.5))
	var vitality = float(state.get("vitality", 0.7))
	var wet_corridor: float = smoothstep(0.46, 0.82, moisture) * cfg.moisture_corridor_boost
	var vitality_boost: float = _vitality_normalized(host, vitality) * cfg.vitality_patch_boost
	return clampf(0.68 + wet_corridor * 0.26 + vitality_boost * 0.30, 0.28, 1.35)



static func _climate_presence(host, state: Dictionary) -> float:

	var cfg = host._profile()
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

	if host.ShrubScatter._spawn_domain(host) == host.SPAWN_WATER:
		var cover = int(state.get("cover", CoverType.CV.NONE))
		if cover == CoverType.CV.SEA_ICE or cover == CoverType.CV.GLACIER:
			return 0.0
		return 1.0
	return _climate_presence(host, state)



static func _vitality_normalized(host, vitality: float) -> float:

	var cfg = host._profile()
	var dead: float = minf(cfg.vitality_dead_threshold, cfg.vitality_healthy_threshold - 0.001)
	var healthy: float = maxf(cfg.vitality_healthy_threshold, dead + 0.001)
	return clampf((clampf(vitality, 0.0, 1.0) - dead) / (healthy - dead), 0.0, 1.0)



static func _vitality_density_factor(host, state: Dictionary) -> float:

	var cfg = host._profile()
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

	var cfg = host._profile()
	var vitality = clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	var normalized = _vitality_normalized(host, vitality)
	return lerpf(cfg.vitality_size_min, cfg.vitality_size_max, pow(normalized, 0.85))
