extends RefCounted

## Determines each map cell's suitability for a vegetation or decorative form.

static func _cell_quota(host, suitability: float, max_per_cell: int) -> Vector2:

	var cap: int = maxi(1, max_per_cell)
	var target: float = float(cap) * clampf(suitability, 0.0, 1.0)
	var attempts: int = clampi(int(ceil(target)), 1, cap)
	return Vector2(float(attempts), target / float(attempts))



static func _cell_suitability(host, cell, idx: int, _key: int, state: Dictionary) -> float:

	var cell_is_water = host._is_water_cell(cell, idx)
	var domain = host.ShrubScatter._spawn_domain(host)
	if domain == host.SPAWN_LAND and cell_is_water:
		return 0.0
	if domain == host.SPAWN_WATER and not cell_is_water:
		return 0.0

	var lf = int(state.get("landform", LandformType.LF.PLAIN))
	var veg = int(state.get("vegetation", VegetationType.VEG.NONE))
	var cover = int(state.get("cover", CoverType.CV.NONE))
	var river = host.ShrubScatter._has_river_cell(host, cell, idx)
	var arch = host._detail_kind()

	if cell_is_water:
		return _aquatic_suitability(host, arch, lf, veg, cover, state)

	# 点缀/地貌类 archetype（岩石/雪堆/枯立木）走独立 suitability：不依赖植被权重，
	# 由地形/覆盖物/气候直接决定，能出现在植被权重为 0 的裸露/雪原/山巅。
	if _is_decoration_archetype(host, arch):
		return _decoration_suitability(host, arch, lf, cover, river, state)

	var landform_weight = host.ShrubScatter._landform_weight(host, lf)
	if landform_weight <= 0.0:
		return 0.0

	var cover_weight = host.ShrubScatter._cover_weight(host, cover)
	if cover_weight <= 0.0:
		return 0.0

	var temp = float(state.get("temp", 0.5))
	var moisture = float(state.get("moisture", 0.5))
	var vitality = float(state.get("vitality", 0.7))
	var stress = maxf(float(state.get("heat", 0.0)), maxf(float(state.get("drought", 0.0)), float(state.get("cold", 0.0))))
	var compat = VegetationType.climate_compat_score(veg, temp, moisture)
	var vitality_factor = host.ShrubScatter._vitality_density_factor(host, state)

	var suitability = host.ShrubScatter._vegetation_weight(host, veg) * landform_weight * cover_weight
	# 绝对生物量：_vegetation_weight 只表达"这一层的形态占该植被的多少比例"
	# （沙漠灌木 100% 是灌木形态，雨林林下只有一部分），量级必须由 biomass 承担，
	# 否则整条链全是相对适应度，沙漠会和雨林一样密。
	suitability *= _biomass_factor(host, veg)
	suitability *= vitality_factor
	suitability *= lerpf(0.58, 1.0, clampf(compat, 0.0, 1.0))
	suitability *= 1.0 - clampf(stress, 0.0, 1.0) * 0.38
	suitability *= lerpf(0.08, 1.0, host.ShrubScatter._scatter_presence(host, state))
	suitability *= host.ShrubScatter._cell_ecology_density_bias(host, state)
	# archetype 生态位亲和（针叶/棕榈/仙人掌/芦苇/高山花）：把通用植被分布收束到各自气候带。
	suitability *= _archetype_affinity(host, arch, veg, lf, cover, river, state)
	# 阶段 C：海拔林线 + 强风折损。
	suitability *= _elevation_modifier(host, arch, float(state.get("elevation", 0.4)))
	suitability *= _wind_exposure_modifier(host, arch, float(state.get("wind_speed", 0.0)))
	if river:
		suitability *= _river_density_factor(host, state)
	suitability *= host.ShrubScatter._quality_density_scale(host)
	return clampf(suitability, 0.0, 1.25)


# 绝对生物量 → 密度乘子。曲线由 profile 的 biomass_floor / ceil / exponent 控制，
# 让每层自己决定对生物量的敏感度：乔木层强正相关，草层几乎不敏感（草原恰恰长在
# 树少的地方，它的选择性已经由 _grass_vegetation_weight 表达）。

static func _biomass_factor(host, veg: int) -> float:

	var cfg = host._profile()
	var biomass = clampf(VegetationType.foliage_biomass(veg), 0.0, 1.0)
	var shaped = pow(biomass, maxf(float(cfg.biomass_exponent), 0.01))
	return lerpf(float(cfg.biomass_floor), float(cfg.biomass_ceil), shaped)


# 河流格的密度系数。河道本体的像素已在候选点阶段被 _is_river_body_position 剔除，
# 所以这里不该再对整格做一刀切惩罚：暖湿带的河谷是全图植被最密的地方，只有冷/旱带
# 的河床才是负面地形。

static func _river_density_factor(host, state: Dictionary) -> float:

	var cfg = host._profile()
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

	if host.ShrubScatter._spawn_domain(host) != host.SPAWN_WATER:
		return 0.0
	if cover == CoverType.CV.SEA_ICE or cover == CoverType.CV.GLACIER:
		return 0.0
	var landform_weight = host.ShrubScatter._landform_weight(host, lf)
	var vegetation_weight = host.ShrubScatter._vegetation_weight(host, veg)
	var cover_weight = host.ShrubScatter._cover_weight(host, cover)
	if landform_weight <= 0.0 or vegetation_weight <= 0.0 or cover_weight <= 0.0:
		return 0.0
	var temp = float(state.get("temp", 0.5))
	var moisture = float(state.get("moisture", 0.5))
	var suitability = vegetation_weight * landform_weight * cover_weight
	# 水域生态不使用陆地 vegetation_vitality 做密度闸门；由温度/水体类型和 profile 权重决定。
	suitability *= lerpf(0.74, 1.15, clampf(moisture, 0.0, 1.0))
	suitability *= lerpf(0.70, 1.05, VegetationType.climate_compat_score(veg, temp, moisture))
	suitability *= host.ShrubScatter._quality_density_scale(host)
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
			s *= lerpf(1.25, 0.55, host.ShrubScatter._vitality_normalized(host, vitality))
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
			s = (1.0 - host.ShrubScatter._vitality_normalized(host, vitality)) * lerpf(0.65, 1.5, clampf(stress, 0.0, 1.0))
			match lf:
				LandformType.LF.PLAIN, LandformType.LF.LOWLAND, LandformType.LF.HILL:
					s *= 1.3
				LandformType.LF.BADLANDS:
					s *= 0.95
				_:
					s *= 0.55
	s *= lerpf(0.18, 1.0, host.ShrubScatter._climate_presence(host, state))
	# 点缀层的形态由 archetype 决定，但配置了 vegetation_weight_overrides 的层
	# （红树气生根、倒木、碎石坡）要靠它把自己收束到目标生物群系；不接进来的话
	# 那几张表是死配置，红树根会按"枯立木"规则长满所有低活力旱地。
	s *= _decoration_vegetation_filter(host, int(state.get("vegetation", VegetationType.VEG.NONE)))
	s *= host.ShrubScatter._quality_density_scale(host)
	return clampf(s, 0.0, 1.25)


# 点缀层没有 _vegetation_weight 那样的基准表，所以这里把非空 overrides 当白名单：
# 列出的植被取表中权重，未列出的只留一点残量。倒木只该出现在林地、红树气生根只该
# 出现在红树林——列表本身就是"该出现在哪"的完整表达。


static func _decoration_vegetation_filter(host, veg: int) -> float:

	var overrides: Dictionary = host._profile().vegetation_weight_overrides
	if overrides.is_empty():
		return 1.0
	if overrides.has(veg):
		return maxf(float(overrides[veg]), 0.0)
	var key = str(veg)
	if overrides.has(key):
		return maxf(float(overrides[key]), 0.0)
	return host.DECORATION_VEG_RESIDUAL
