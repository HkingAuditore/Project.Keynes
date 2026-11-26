extends RefCounted


static func _alt_penalty_height(owner: Variant, height_norm: float) -> float:
	var h: float = clampf(height_norm, 0.0, 1.0)
	var lin: float = h * owner._generator.ALT_PEN_LINEAR
	var hi: float = smoothstep(owner._generator.ALT_PEN_HIGH_LO, owner._generator.ALT_PEN_HIGH_HI, h) * owner._generator.ALT_PEN_HIGH_AMP
	return lin + hi


static func _alt_penalty(owner: Variant, elevation: float, sea_level: float = -1.0) -> float:
	var sea: float = sea_level
	if sea < 0.0 and owner._generator._last_cfg != null:
		sea = float(owner._generator._last_cfg.sea_level)
	if sea >= 0.0:
		return owner._generator._alt_penalty_height(owner._generator._temperature_height_for_penalty(elevation, sea))
	return owner._generator._alt_penalty_height(elevation)


static func _derived_snow_cover(owner: Variant, temp_now: float, land_h: float, terrain: int, cover: int) -> float:
	# 2026-05-19 Plan-C 二次调参（日志诊断后）：
	# 现象：season_temp_amp=0.32 + 雪线带 [0.30, 0.48] 宽度仅 0.18 → 季节振幅(0.64)
	# 是过渡带 3.6 倍 → 单 cell 只在春秋很短的窗口里看到"半雪"，其余时间全有/全无。
	# 修复：把雪线带拉宽到 [0.20, 0.60]（0.40），中纬冬季满白、春秋稳定过渡、
	#       夏季中高纬挂薄雪、赤道全年无雪。amount 上提 0.55→0.70 强化对比。
	var snow_cover: float = 0.0
	if terrain == TerrainType.TERRAIN.SNOW:
		snow_cover = (1.0 - smoothstep(0.22, 0.62, temp_now)) * 0.80
	var cold_snow: float = (1.0 - smoothstep(0.20, 0.60, temp_now)) * 0.70
	var altitude_w: float = smoothstep(0.22, 0.90, land_h)
	var alpine_temp_w: float = 1.0 - smoothstep(0.20, 0.85, temp_now)
	var alpine_snow: float = altitude_w * alpine_temp_w * 0.92
	snow_cover = max(snow_cover, max(cold_snow, alpine_snow))
	if cover == CoverType.CV.GLACIER and snow_cover < 0.80:
		snow_cover = 0.80
	return snow_cover


static func _bootstrap_sea_ice_fraction(owner: Variant, map: MapData, cfg: MapConfig) -> void:
	# generate() 里的一次性初始化：为每个海洋 cell 按年基线温度给出 sea_ice_fraction 平衡值。
	# 目的：让 refresh_climate_daily 首次运行前就有合理的初值，而不是全 0（否则高纬该冻的地方
	# 需要几十天才爬到 ice_terrain_threshold，视觉上出现"开局一片无冰"的假象）。
	# 不使用固定 summer/winter 相位；季节性由后续 daily temperature pass 连续注入。
	#
	# 平衡值取法（与 _apply_sea_ice_daily_pass 的阈值语义一致）：
	#   temp < form_threshold  →  fraction = smoothstep 向 1 走
	#   temp > melt_threshold  →  fraction = 0
	#   之间                   →  线性过渡
	# 然后再按 sea_ice_terrain_threshold 翻转 terrain。
	var cp = owner._generator._c()
	if cp == null:
		return
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var thr_terrain: float = float(cp.sea_ice_terrain_threshold)
	var solar_gate_enabled: bool = owner._generator._sea_ice_solar_gate_enabled(cp)
	var freeze_insol_low: float = float(cp.sea_ice_freeze_insol_low)
	var freeze_insol_high: float = float(cp.sea_ice_freeze_insol_high)
	for cell: HexCell in map.all_cells():
		if not owner._generator._is_water(cell.terrain):
			cell.sea_ice_fraction = 0.0
			continue
		if cell.terrain == TerrainType.TERRAIN.LAKE:
			cell.sea_ice_fraction = 0.0
			continue
		var ny: float = owner._generator._cube_row_norm(cell, cfg)
		var temp_year: float = owner._generator._compute_temperature(ny, cell.elevation)
		var temp_ref: float = clampf(temp_year, 0.0, 1.0)
		var polar_w: float = absf(ny * 2.0 - 1.0)
		var frac: float = 0.0
		if temp_ref < t_form:
			# 冷：按离阈距离给个饱和度
			frac = clampf((t_form - temp_ref) / maxf(t_form, 0.001), 0.0, 1.0)
			# 用更宽的 smoothstep，避免接近阈值的低浓度冰在开局就变成满冰带。
			frac = smoothstep(0.10, 0.85, frac)
		elif temp_ref > t_melt:
			frac = 0.0
		else:
			# 迟滞带：线性从 form→melt 对应 1→0
			var span: float = maxf(t_melt - t_form, 0.001)
			frac = clampf((t_melt - temp_ref) / span, 0.0, 1.0) * 0.35
		if solar_gate_enabled:
			var annual_insol: float = owner._generator._insolation_annual_mean(ny)
			frac *= owner._generator._sea_ice_freeze_gate(annual_insol, freeze_insol_low, freeze_insol_high)
		var stable_polar_pack: bool = polar_w >= 0.78 and temp_ref < t_form * 0.85
		if not stable_polar_pack and frac >= thr_terrain:
			frac = maxf(0.0, thr_terrain - 0.08)
		cell.sea_ice_fraction = frac
		# 生成期只把稳定极地多年冰落成 terrain；过渡冰由 daily pass 自行生长/消退。
		if stable_polar_pack and frac >= thr_terrain and cell.terrain != TerrainType.TERRAIN.SEA_ICE:
			owner._generator._set_cell_runtime_terrain(map, cell, TerrainType.TERRAIN.SEA_ICE)


static func _decide_terrain(owner: Variant, elevation: float, temperature: float, moisture: float, cfg: MapConfig, permanent_only: bool = false) -> TerrainType.TERRAIN:
	if elevation < cfg.sea_level - 0.06:
		return TerrainType.TERRAIN.OCEAN
	if elevation < cfg.sea_level:
		return TerrainType.TERRAIN.COAST

	var land_height: float = (elevation - cfg.sea_level) / (1.0 - cfg.sea_level)

	# ─── 海拔/极地优先（不论温度湿度）───────────────────────────────────
	# v10.6：三档 SNOW 判定
	# 2026-05-18 雪线修正 #2：alt_penalty 加深后温度被多扣 ~0.24，
	# 中纬丘陵 (land_h≈0.4~0.5) 大量误判 COLD_SNOW。阈值跟着抬：
	#   COLD_SNOW_LINE 0.40→0.55（只允许中山以上冷雪）
	#   cold-snow 温度门槛 0.13→0.08（更冷才换 SNOW）
	#   极地低温门槛 0.06→0.03（低海拔不被 alt_pen 误伤）
	#
	# 2026-05-18 雪线修正 #3 / 季节性高山雪：
	# permanent_only=true 仅在 bake 阶段（snapshot_base_state 之前）使用，
	# 用更严苛阈值决定哪些 cell 被永久锁死为 SNOW（base_terrain=SNOW，
	# refresh_seasonal/refresh_climate_daily 会跳过 _decide_terrain 永久维持）。
	# 其它 fast-tick 路径仍传 false，温度（含 season_offset）正常驱动雪/岩切换。
	#
	# 调参目标：
	#   - 赤道高山顶不再只凭高度永久雪；由雪盖曲线决定季节性退缩。
	#   - 中纬高山（land_h≈0.55~0.82, 年均温<0.08）→ bake 进 MOUNTAIN，
	#     fast tick 冬季 temp_now<0.08 时翻 SNOW，夏季回 MOUNTAIN
	#   - 极地低海拔（temp<0.03）→ bake 进 TUNDRA/PLAIN，季节性翻雪
	var snow_line: float = 0.85 if permanent_only else 0.82
	var snow_line_temp: float = 0.26 if permanent_only else 0.34
	var cold_snow_line: float = 0.70 if permanent_only else 0.55
	var cold_snow_temp: float = 0.05 if permanent_only else 0.08
	# 极地永久雪：bake 时关闭（温度<0 等价于不触发），fast-tick 仍按 0.03 兜底。
	var polar_temp: float = -1.0 if permanent_only else 0.03
	if land_height > snow_line and temperature < snow_line_temp:
		return TerrainType.TERRAIN.SNOW
	if land_height > cold_snow_line and temperature < cold_snow_temp:
		return TerrainType.TERRAIN.SNOW
	if temperature < polar_temp:
		return TerrainType.TERRAIN.SNOW
	var mountain_line: float = 0.72 if permanent_only else 0.70
	if land_height > mountain_line:
		return TerrainType.TERRAIN.MOUNTAIN
	if temperature < 0.20:
		return TerrainType.TERRAIN.TUNDRA

	# [climate-zone-fix P1] 与 C++ pk_decide_terrain_ex 同源：湿端阈值按世界湿度天花板
	# 旧单一"热带(>0.55)"拆成真热带与亚热带/暖温带；连续雨林只占湿尾。
	# (0.55–0.66)，让 FOREST 地形在亚热带可达，修复 SUBTROPICAL_FOREST 死分支。
	# [zonal-envelope 2026-08-01] 与 C++ 完全重新同步（此前 GDScript 已漂移：温带 FOREST
	# 真热带门为 0.80（≈33°回归线外缘），温带 FOREST 湿门 0.42、
	# 温带 GRASSLAND 0.28，并保留凉带 STEPPE/TUNDRA 限制。
	if temperature > 0.80:                         # 真热带（赤道带，0–33°）
		if moisture > 0.64:
			return TerrainType.TERRAIN.JUNGLE     # 连续湿润热带森林（C++ 同步）
		if moisture > 0.32:
			return TerrainType.TERRAIN.SAVANNA    # 稀树草原
		# [zonal-envelope 二轮] 热带草系干端 0.20→0.24，干端转真荒漠（C++ 同步）。
		if moisture > 0.24:
			return TerrainType.TERRAIN.STEPPE
		return TerrainType.TERRAIN.DESERT         # 热带沙漠

	if temperature > 0.55:                         # 亚热带 / 暖温带（33–51°，湿端→亚热带常绿林）
		if moisture > 0.40:
			return TerrainType.TERRAIN.FOREST     # → _derive_vegetation 派生 SUBTROPICAL_FOREST（0.36→0.40）
		if moisture > 0.24:
			return TerrainType.TERRAIN.GRASSLAND
		if moisture > 0.16:
			return TerrainType.TERRAIN.STEPPE
		return TerrainType.TERRAIN.DESERT

	if temperature > 0.38:                         # 温带（51–62°）
		if moisture > 0.42:
			return TerrainType.TERRAIN.FOREST     # 温带阔叶林（配合风暴路径湿带）
		if moisture > 0.28:
			return TerrainType.TERRAIN.GRASSLAND  # 温带草地（0.32→0.28 收窄草原漏斗）
		if moisture > 0.16:
			return TerrainType.TERRAIN.STEPPE
		return TerrainType.TERRAIN.DESERT

	# 凉温带 / 北方带（0.20–0.38，62–77°）
	if moisture > 0.45:
		return TerrainType.TERRAIN.TAIGA
	# [water-tuning 2026-06-26] STEPPE 限暖凉温带（t>0.30），更冷回落针叶林/苔原/寒漠
	if temperature > 0.30:
		if moisture > 0.22:
			return TerrainType.TERRAIN.STEPPE
		return TerrainType.TERRAIN.COLD_DESERT
	# 冷凉温带 / 亚极地（0.20–0.30）
	if moisture > 0.28:
		return TerrainType.TERRAIN.TAIGA
	if moisture > 0.16:
		return TerrainType.TERRAIN.TUNDRA
	return TerrainType.TERRAIN.COLD_DESERT


static func _derive_landform(owner: Variant, cell: HexCell, cfg: MapConfig) -> int:
	# 火山地标优先（has_volcano flag 在生成中后期由 _apply_volcano_pass 写入）
	if cell.has_volcano:
		return LandformType.LF.VOLCANO
	# 水体走 cell.terrain，因为 LAKE / OCEAN / COAST 由水体连通分量算法决定，
	# 不是简单的"低于海平面"
	var t: int = int(cell.terrain)
	if t == TerrainType.TERRAIN.LAKE:
		return LandformType.LF.LAKE
	# OCEAN / COAST / REEF / KELP / SEA_ICE 都是海洋系；按海拔分深 / 中 / 浅
	var marine: bool = (t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
			or t == TerrainType.TERRAIN.SEA_ICE)
	if marine:
		var sea: float = cfg.sea_level
		if cell.elevation < sea * 0.55:
			return LandformType.LF.DEEP_OCEAN
		if cell.elevation < sea * 0.92:
			return LandformType.LF.OCEAN
		return LandformType.LF.COAST
	# 特殊永久地标
	if t == TerrainType.TERRAIN.DELTA:
		return LandformType.LF.DELTA
	if t == TerrainType.TERRAIN.BADLANDS:
		return LandformType.LF.BADLANDS
	if t == TerrainType.TERRAIN.SALT_FLAT:
		return LandformType.LF.SALT_FLAT
	if t == TerrainType.TERRAIN.FLOODPLAIN:
		return LandformType.LF.PLAIN
	if t == TerrainType.TERRAIN.MESA:
		return LandformType.LF.PLATEAU
	# 陆地：按 land_h 分段（与原 _decide_terrain 阈值一致）
	var land_h: float = (cell.elevation - cfg.sea_level) / maxf(1.0 - cfg.sea_level, 0.001)
	if land_h > 0.92:
		return LandformType.LF.PEAK
	if land_h > 0.70:
		return LandformType.LF.MOUNTAIN
	if land_h > 0.22:
		return LandformType.LF.HILL
	if land_h > 0.05:
		return LandformType.LF.LOWLAND
	return LandformType.LF.PLAIN


static func _derive_vegetation(owner: Variant, cell: HexCell, landform: int, temperature: float) -> int:
	var t: int = int(cell.terrain)
	# 海水 / 湖水 / 海冰：水面无陆生植被
	if t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.LAKE or t == TerrainType.TERRAIN.SEA_ICE:
		return VegetationType.VEG.NONE
	# COAST：暖凉浅海软底育海草床(SEAGRASS)，过冷/过热裸沙底为 NONE。
	# [zonal-envelope] 上缘 0.74→0.82：真热带边界收窄到 0.80 后热带浅海也允许海草床。
	if t == TerrainType.TERRAIN.COAST:
		if temperature > 0.42 and temperature < 0.82:
			return VegetationType.VEG.SEAGRASS
		return VegetationType.VEG.NONE
	# 海洋特殊植被
	if t == TerrainType.TERRAIN.REEF:
		return VegetationType.VEG.CORAL_REEF
	if t == TerrainType.TERRAIN.KELP:
		return VegetationType.VEG.KELP_FOREST
	# 永久冰川 / 雪面：植被几乎不存在
	if t == TerrainType.TERRAIN.GLACIER:
		return VegetationType.VEG.NONE
	if t == TerrainType.TERRAIN.SNOW:
		# 雪面下面如果是高山地形，植被身份是"高山苔原"被雪覆盖（cover 单独标 SNOW）
		if landform == LandformType.LF.HILL or landform == LandformType.LF.MOUNTAIN:
			return VegetationType.VEG.ALPINE_TUNDRA
		if landform == LandformType.LF.PEAK:
			return VegetationType.VEG.NONE
		return VegetationType.VEG.POLAR_DESERT
	# 高山判定（HILL/MOUNTAIN/PEAK）：植被走"高山植被"分支
	var is_alpine: bool = (landform == LandformType.LF.MOUNTAIN \
			or landform == LandformType.LF.PEAK)
	# PEAK 几乎无植被
	if landform == LandformType.LF.PEAK:
		return VegetationType.VEG.NONE
	# 永久地标植被映射
	if t == TerrainType.TERRAIN.DELTA:
		return VegetationType.VEG.MARSH if temperature < 0.55 else VegetationType.VEG.MANGROVE
	if t == TerrainType.TERRAIN.OASIS:
		return VegetationType.VEG.OASIS_VEG
	if t == TerrainType.TERRAIN.SALT_FLAT:
		return VegetationType.VEG.NONE
	if t == TerrainType.TERRAIN.BADLANDS:
		return VegetationType.VEG.DESERT_SCRUB
	# ── terrain-overhaul 新增地形 → 植被映射（与 C++ pk_derive_vegetation 同源）──
	if t == TerrainType.TERRAIN.COLD_DESERT:
		return VegetationType.VEG.XERIC_DESERT if cell.moisture < 0.08 else VegetationType.VEG.DESERT_SCRUB
	if t == TerrainType.TERRAIN.CHAPARRAL:
		return VegetationType.VEG.MEDITERRANEAN_SHRUB
	if t == TerrainType.TERRAIN.MOOR:
		return VegetationType.VEG.PEAT_BOG
	if t == TerrainType.TERRAIN.FLOODPLAIN:
		if temperature > 0.55:
			return VegetationType.VEG.MONSOON_FOREST if cell.moisture > 0.60 else VegetationType.VEG.SAVANNA
		return VegetationType.VEG.MARSH if cell.moisture > 0.70 else VegetationType.VEG.TEMPERATE_GRASSLAND
	if t == TerrainType.TERRAIN.MESA:
		return VegetationType.VEG.DESERT_SCRUB
	if t == TerrainType.TERRAIN.SWAMP:
		# 冷区沼泽积累泥炭 → PEAT_BOG，否则常规沼泽。
		return VegetationType.VEG.PEAT_BOG if temperature < 0.34 else VegetationType.VEG.SWAMP
	if t == TerrainType.TERRAIN.MANGROVE:
		return VegetationType.VEG.MANGROVE
	if t == TerrainType.TERRAIN.SHRUBLAND:
		return VegetationType.VEG.MEDITERRANEAN_SHRUB
	# 寒带 / 苔原 / 北方
	if t == TerrainType.TERRAIN.TUNDRA:
		if is_alpine:
			return VegetationType.VEG.ALPINE_TUNDRA
		return VegetationType.VEG.TUNDRA
	if t == TerrainType.TERRAIN.TAIGA:
		if is_alpine:
			return VegetationType.VEG.TEMPERATE_CONIFER
		return VegetationType.VEG.TAIGA
	# 山地无明确植被身份 → 走 Whittaker 决策（HILL 也走这里以避免"植被=丘陵"）
	if t == TerrainType.TERRAIN.HILL or t == TerrainType.TERRAIN.MOUNTAIN \
			or t == TerrainType.TERRAIN.PLAIN:
		return owner._generator._whittaker_vegetation(temperature, cell.moisture, landform)
	# Phase 10 Whittaker 命中：FOREST/JUNGLE/SAVANNA/GRASSLAND/STEPPE/DESERT
	var is_hilly: bool = (landform == LandformType.LF.HILL)
	match t:
		TerrainType.TERRAIN.FOREST:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			# 暖湿丘陵迎风坡 → 云雾林（[climate-zone-fix P1] 湿门 0.70→0.52 适配湿度天花板）
			if is_hilly and temperature > 0.50 and cell.moisture > 0.52:
				return VegetationType.VEG.CLOUD_FOREST
			# [climate-zone-fix P1] temp>0.55→SUBTROPICAL_FOREST 现可达(亚热带 0.55–0.66 带 FOREST 地形)
			if temperature > 0.55:
				return VegetationType.VEG.SUBTROPICAL_FOREST
			return VegetationType.VEG.TEMPERATE_DECIDUOUS
		TerrainType.TERRAIN.JUNGLE:
			# 热带高地云雾林 → 极湿雨林 → 季风半落叶 → 季雨林
			# 连续雨林只占湿尾，季风林承接中间湿度带。
			if (is_alpine or is_hilly) and cell.moisture > 0.60:
				return VegetationType.VEG.CLOUD_FOREST
			if cell.moisture > 0.66:
				return VegetationType.VEG.TROPICAL_RAINFOREST
			if cell.moisture > 0.50:
				return VegetationType.VEG.MONSOON_FOREST
			return VegetationType.VEG.TROPICAL_DRY_FOREST
		TerrainType.TERRAIN.SAVANNA:
			if is_alpine:
				return VegetationType.VEG.ALPINE_MEADOW if cell.moisture > 0.45 else VegetationType.VEG.BOREAL_SHRUB
			# Keep SAVANNA's wet edge aligned with _decide_terrain's JUNGLE boundary.
			# SAVANNA 湿端季风林门与 JUNGLE 0.64 边界同步（C++ 同步）。
			return VegetationType.VEG.MONSOON_FOREST if cell.moisture > 0.64 else VegetationType.VEG.SAVANNA
		TerrainType.TERRAIN.GRASSLAND:
			if is_alpine:
				return VegetationType.VEG.ALPINE_MEADOW
			return VegetationType.VEG.TEMPERATE_GRASSLAND
		TerrainType.TERRAIN.STEPPE:
			if is_alpine:
				if temperature < 0.28:
					return VegetationType.VEG.ALPINE_TUNDRA
				return VegetationType.VEG.ALPINE_MEADOW if cell.moisture > 0.32 else VegetationType.VEG.BOREAL_SHRUB
			return VegetationType.VEG.TEMPERATE_STEPPE
		TerrainType.TERRAIN.DESERT:
			# 极旱 → XERIC_DESERT；普通 → DESERT_SCRUB
			if cell.moisture < 0.10:
				return VegetationType.VEG.XERIC_DESERT
			return VegetationType.VEG.DESERT_SCRUB
		_:
			return owner._generator._whittaker_vegetation(temperature, cell.moisture, landform)


static func _whittaker_vegetation(owner: Variant, temperature: float, moisture: float, landform: int) -> int:
	var is_alpine: bool = (landform == LandformType.LF.MOUNTAIN \
			or landform == LandformType.LF.PEAK)
	var is_hilly: bool = (landform == LandformType.LF.HILL)
	# 寒带
	if temperature < 0.06:
		return VegetationType.VEG.POLAR_DESERT
	if temperature < 0.20:
		if is_alpine:
			return VegetationType.VEG.ALPINE_TUNDRA
		return VegetationType.VEG.TUNDRA
	# 凉温带
	if temperature < 0.40:
		if moisture > 0.40:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			return VegetationType.VEG.TAIGA
		if moisture > 0.20:
			return VegetationType.VEG.BOREAL_SHRUB
		return VegetationType.VEG.ALPINE_TUNDRA if is_alpine else VegetationType.VEG.TEMPERATE_STEPPE
	# 暖温带
	if temperature < 0.55:
		# 温带森林湿门 0.42 / 草门 0.26，与 C++ pk_whittaker_vegetation 同步。
		if moisture > 0.42:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			if is_hilly:
				return VegetationType.VEG.TEMPERATE_DECIDUOUS
			return VegetationType.VEG.TEMPERATE_DECIDUOUS
		if moisture > 0.26:
			if is_alpine:
				return VegetationType.VEG.ALPINE_MEADOW
			return VegetationType.VEG.TEMPERATE_GRASSLAND
		return VegetationType.VEG.BOREAL_SHRUB if is_alpine else VegetationType.VEG.TEMPERATE_STEPPE
	# [climate-zone-fix P1] 亚热带拆出 SUBTROPICAL_FOREST；真热带湿端阈值下移适配天花板。
	# [zonal-envelope] 亚热带上缘 0.66→0.80（≈33°），SUBTROP 湿门 0.36→0.40，与 C++ 同步。
	if temperature < 0.80:           # 亚热带（33–51°）
		if moisture > 0.40:
			return VegetationType.VEG.SUBTROPICAL_FOREST
		if moisture > 0.22:
			return VegetationType.VEG.TEMPERATE_GRASSLAND
		if moisture < 0.12:
			return VegetationType.VEG.DESERT_SCRUB   # 副热带旱坡
		return VegetationType.VEG.TEMPERATE_STEPPE
	# 真热带（0–33°）
	# 连续雨林湿门 0.64，与 JUNGLE 地形边界对齐（C++ 同步）。
	if moisture > 0.64:
		return VegetationType.VEG.TROPICAL_RAINFOREST
	if moisture > 0.42:
		return VegetationType.VEG.MONSOON_FOREST
	if moisture > 0.34:
		return VegetationType.VEG.TROPICAL_DRY_FOREST
	# [zonal-envelope 二轮] SAVANNA 下限 0.20→0.24（C++ 同步）。
	if moisture > 0.24:
		return VegetationType.VEG.SAVANNA
	if moisture < 0.10:
		return VegetationType.VEG.XERIC_DESERT
	return VegetationType.VEG.DESERT_SCRUB


static func _derive_cover(owner: Variant, cell: HexCell, snow_cover: float) -> int:
	var t: int = int(cell.terrain)
	if t == TerrainType.TERRAIN.GLACIER:
		return CoverType.CV.GLACIER
	if t == TerrainType.TERRAIN.SEA_ICE:
		return CoverType.CV.SEA_ICE
	if t == TerrainType.TERRAIN.SNOW:
		return CoverType.CV.SNOW
	# 季节性雪盖（陆地，由 refresh_seasonal 算出 snow_cover ∈ [0, 1]）
	if snow_cover > 0.5 and not owner._generator._is_water(t):
		return CoverType.CV.SNOW
	# 苔原默认下层永冻土（这是地理事实，不是季节性）
	if t == TerrainType.TERRAIN.TUNDRA:
		return CoverType.CV.PERMAFROST
	return CoverType.CV.NONE


static func _sync_axes_for_cell(owner: Variant, cell: HexCell, cfg: MapConfig, snow_cover: float, temperature_override: float = -1.0) -> void:
	var landform = owner._generator._derive_landform(cell, cfg)
	var prev_landform: int = int(cell.landform)
	if not owner._generator._is_water(cell.terrain) and (
			prev_landform == LandformType.LF.PEAK
			or prev_landform == LandformType.LF.VOLCANO
			or prev_landform == LandformType.LF.PLATEAU
			or prev_landform == LandformType.LF.RIFT_VALLEY
			or prev_landform == LandformType.LF.CANYON):
		landform = prev_landform
	var ny: float = owner._generator._cube_row_norm(cell, cfg)
	var temp: float = temperature_override if temperature_override >= 0.0 else owner._generator._compute_temperature(ny, cell.elevation)
	cell.landform = landform
	# 保留合理的演替滞后；明显跨生态带的残留则在 terrain 重分类后立即纠正。
	var needs_reconcile := VegetationType.needs_biome_reconciliation(
		int(cell.terrain), int(cell.vegetation))
	if owner._generator._is_water(cell.terrain) \
			or int(cell.vegetation) == int(VegetationType.VEG.NONE) \
			or needs_reconcile:
		cell.vegetation = owner._generator._derive_vegetation(cell, landform, temp)
	cell.cover = owner._generator._derive_cover(cell, snow_cover)
