extends RefCounted

static func _base_color_for_vegetation(host, veg: int) -> Color:

	var cfg = host._profile()
	if bool(cfg.get("base_color_override_enabled")):
		return cfg.get("base_color_override")
	match host._detail_kind():
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
