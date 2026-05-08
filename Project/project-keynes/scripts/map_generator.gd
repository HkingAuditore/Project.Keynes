# map_generator.gd v8
#
# v8 改动（相比 v7.5）：多尺度地理仿真，让地形/生态/大陆/岛屿分布自然丰富：
#   1) 海拔加 meso-scale noise → 大陆内部不再是同心圆梯度，有高原/谷地/起伏
#   2) 海拔加 offshore noise → 大陆远海偶现群岛
#   3) 山脉用双向脊线 ridge_a + ridge_b → 形成不同走向的山脉链而非单一大山块
#   4) 山脉加 slope_gate → 平地不抬山，只有有坡度的地方才形成山，去掉"高原全是山"
#   5) 湿度多尺度 → 出现"湿带 / 干带"大尺度结构
#   6) 新增 _apply_rain_shadow → 山脉上风向遮挡使背风面变干（雨影）
#   7) 新增 _apply_river_ecology → 河岸自然生成绿带（沙漠中河流出绿洲）
#
# 流程：generate → _generate_cells（per-cell 玩法层数据） → MapBaker.bake_world（高分辨率视觉烘焙）

class_name MapGenerator

# 显式 preload，避免新建 class_name 文件时 Godot 全局类注册表偶发未拾取的问题
const WindBeltScript = preload("res://scripts/wind_belt.gd")
# 同理：ClimateProfile 在 @export 里被引用，冷启动/首次导入时全局类注册表可能
# 尚未拾取，这里显式 preload 迫使先加载该脚本，避免
# "Parser Error: Could not parse global class MapGenerator" 的启动报错。
const ClimateProfileScript = preload("res://scripts/data/climate_profile.gd")

# ─── 世界生成配置（数据驱动） ────────────────────────────────────────────
# 所有原本散落在本文件顶部的 50+ 个调参 const 已迁移到 ClimateProfile 资源。
# - 默认（nil）时，懒加载 res://data/world/earth_like.tres 作为兜底，效果与
#   旧版硬编码完全一致。
# - 美术/策划可在 Inspector 里切换别的 .tres（如 ice_age.tres / desert_world.tres）
#   实现不同的"世界预设"，无需改代码。
# - _c() 是热路径 helper：返回非空的 climate_profile。
@export var climate_profile: ClimateProfile = null

func _c() -> ClimateProfile:
	if climate_profile == null:
		var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
		if loaded == null:
			push_warning("MapGenerator: earth_like.tres missing; using in-memory defaults")
			loaded = ClimateProfile.new()
		climate_profile = loaded
	return climate_profile

# （下面各组调参说明仍保留，方便阅读；实际数值取自 ClimateProfile。）

# ─── 河流参数 ────────────────────────────────────────────────────────────
# 流量分位阈值：超过 land cell 总流量这个 percentile 的格子标 has_river。
# v10：从 0.85 降到 0.78（top 22%），让长河上游小溪也能跨过门槛被标河

# v10 山地正雨（orographic rainfall）：高海拔 cell 降雨多
# rainfall = base × (1 + max(land_h - 0.30, 0) × OROGRAPHIC_BOOST)
# 0 = 关闭，山地降雨 = 基础值
# 1.5（默认）= land_h=0.50 时雨量 ×1.30；land_h=0.80 时 ×1.75
# 3.0 = 山地降雨翻倍，长河更容易出现
# const OROGRAPHIC_BOOST (migrated to ClimateProfile.orographic_boost)

# v10 depression 填充：迭代上限。原 12 对多 cell 盆地不够，提高到 100 保证收敛。
# const PIT_FILL_MAX_ITERS (migrated to ClimateProfile.pit_fill_max_iters)

# 沿岸湿度补偿
# const COASTAL_MOISTURE_BOOST (migrated to ClimateProfile.coastal_moisture_boost)

# 边缘衰减（让地图边界倾向于海洋）
# v7.2：START 从 0.55 拉到 0.40，让海洋深入腹地 → 消除"矩形大陆"感
# const EDGE_FALLOFF_START (migrated to ClimateProfile.edge_falloff_start)
# const EDGE_FALLOFF_END (migrated to ClimateProfile.edge_falloff_end)
# const EDGE_FALLOFF_DEPTH (migrated to ClimateProfile.edge_falloff_depth)

# 大陆距离场参数（v7.1 重新引入：让"海中 N 个大陆"结构清晰）
# 域扭曲振幅（在归一化坐标 [0,1] 空间里，把"距离 continent_center 的距离值"扰动 ±这个值）
# v7.5：现在扰动的是距离值本身（不是坐标位置），所以 deep-ocean 的远点不会被拉进 continent。
#       0.06 = 大陆边界轻度波浪；0.12 = 大陆边界明显犬牙；0.20+ = 极不规则但可能产生离岸碎岛。
# const CONTINENT_WARP_AMP (migrated to ClimateProfile.continent_warp_amp)

# 距离场和噪声的混合比例（之和应 ≤ 1，剩余给中频细节）
# const DIST_FIELD_WEIGHT (migrated to ClimateProfile.dist_field_weight)
# const NOISE_WEIGHT (migrated to ClimateProfile.noise_weight)

# v7.2：山脉脊线 ridge 强度（在距离场之上叠 ridged noise → 大陆出现山脉走向）
# 0 = 不加 ridge，0.20 = 适中山脉密度，0.35 = 多山世界
# v10.4：从 0.8 降到 0.50。0.8 时大量"高原+缓坡"cell 都被推到 elev > 0.92，
# 导致后续 hypsometric 渲染里满是 mountain→peak 段亮色 → 视觉"满山雪"
# 0.50 让 ridge 只显著推高真正的脊线 cell（slope_gate × ridge_signal 都高的）
# const RIDGE_BOOST_AMP (migrated to ClimateProfile.ridge_boost_amp)

# ─── v8：多尺度地貌参数 ────────────────────────────────────────────────────
# 中频起伏权重（在距离场之上叠加 plateau / valley 变化，打破同心圆梯度）
# 0 = 大陆内部完全是同心圆梯度（山顶在中心，向外平滑下降）
# 0.20（默认）= 大陆内部有明显高原/谷地/起伏
# 0.35+ = 起伏过强，可能让大陆中心都不是最高
# const MESO_WEIGHT (migrated to ClimateProfile.meso_weight)

# 离岸群岛振幅（控制大陆远海是否会偶现小群岛）
# 0 = 大陆周围只有大陆，无离岛
# 0.35（默认）= 偶有小群岛点缀
# 0.55+ = 群岛密布，大陆周围一圈碎岛
# const OFFSHORE_AMP (migrated to ClimateProfile.offshore_amp)

# 雨影：上风向 cell 比当前 cell 高这么多 → 视为被遮挡 → moisture 按 RAIN_SHADOW_FACTOR 衰减
# 较小的 THRESHOLD 让山脉雨影更频繁出现
# const RAIN_SHADOW_THRESHOLD (migrated to ClimateProfile.rain_shadow_threshold)
# const RAIN_SHADOW_FACTOR (migrated to ClimateProfile.rain_shadow_factor)  # 0 = 雨影区彻底干燥；1 = 不衰减
# 主导风向（默认西风带 +x，略偏南）。可改成其他方向看不同气候模式
# const PREVAILING_WIND (migrated to ClimateProfile.prevailing_wind)  # 已废弃；Phase 6 后用 WindBelt.wind_at(ny, phase) 代替
# 检查上风向多少个 hex 来判断遮挡（建议 1-3）
# const RAIN_SHADOW_LOOKBACK (migrated to ClimateProfile.rain_shadow_lookback)

# 每季湿度全局缩放（夏雨季最湿、冬干季最干）。Phase 6 之后每个 cell 风向自带，
# 但全图整体湿度仍按季节缩放，模拟 ITCZ 季节迁移对降雨总量的影响。
# const SEASONAL_MOISTURE_SCALE (migrated to ClimateProfile.seasonal_moisture_scale)

# Phase 6：每个 cell 用 WindBelt.wind_at(ny, season_phase) 算自己的风向。
# 不再全图同向。SEASONAL_WINDS 已废弃。

# ─── v9：大陆分布层次化（main + satellites） ──────────────────────────────
# cfg.num_continents 现在表示"主大陆数量"。每个 main 自动配 SATELLITES_PER_MAIN
# 个卫星岛，撒到全图 [0.08, 0.92] 范围。卫星岛半径较小，贴边时被 EDGE_FALLOFF
# 自然切成残岛，模拟现实地理（半岛、列岛）。
#
# main / satellite 半径都以 cfg.continent_size × 0.6 为单位换算。
# 例 cfg.continent_size = 0.6：
#   main radius = 0.6 × 0.6 × [0.50, 0.65] = [0.18, 0.234]
#   satellite radius = 0.6 × 0.6 × [0.15, 0.32] = [0.054, 0.115]
#   main 比 satellite 大 2~4 倍。

# 主大陆半径范围（× cfg.continent_size × 0.6）
# v10：0.50/0.65 → 0.70/0.90，主大陆面积约 ×1.8，视觉占比合理
# const MAIN_RADIUS_MIN (migrated to ClimateProfile.main_radius_min)
# const MAIN_RADIUS_MAX (migrated to ClimateProfile.main_radius_max)

# 卫星岛半径范围（× cfg.continent_size × 0.6）
# v10：同步上调，保持 main : satellite ≈ 2:1
# const SATELLITE_RADIUS_MIN (migrated to ClimateProfile.satellite_radius_min)
# const SATELLITE_RADIUS_MAX (migrated to ClimateProfile.satellite_radius_max)

# 每个主大陆自动配多少个卫星岛
# 0 = 只有主大陆；3（默认）= 大陆周围撒一圈小岛；6+ = 群岛密布
# const SATELLITES_PER_MAIN (migrated to ClimateProfile.satellites_per_main)

# 主大陆放置范围（避免太靠边被海完全切掉）
# const MAIN_PLACEMENT_MIN (migrated to ClimateProfile.main_placement_min)
# const MAIN_PLACEMENT_MAX (migrated to ClimateProfile.main_placement_max)

# 卫星岛放置范围（允许更靠边，自然产生半埋海里的离岛）
# const SATELLITE_PLACEMENT_MIN (migrated to ClimateProfile.satellite_placement_min)
# const SATELLITE_PLACEMENT_MAX (migrated to ClimateProfile.satellite_placement_max)

# Poisson 拒绝采样：两 center 间距至少要 (radius_a + radius_b) × 这个系数
# const MAIN_SEPARATION_FACTOR (migrated to ClimateProfile.main_separation_factor)       # 主大陆之间不重叠
# const SATELLITE_SEPARATION_FACTOR (migrated to ClimateProfile.satellite_separation_factor)  # 卫星岛允许一定接近 main 边缘

# ─── 噪声实例 ────────────────────────────────────────────────────────────
var _height_noise:    FastNoiseLite     # 大陆主形态（多频 fbm）
var _height_warp:     FastNoiseLite     # 域扭曲（让大陆形状非圆形）
var _detail_noise:    FastNoiseLite     # 中频细节
var _moisture_noise:  FastNoiseLite     # 湿度
var _continent_centers: Array            # Array[Dictionary]：每项 {pos: Vector2, radius: float, kind: String}
										  # kind ∈ {"main", "satellite"}，所有坐标和半径都是归一化 [0, 1]
var _rng:             RandomNumberGenerator

# ─── Phase 2：跨季 / 跨年保留状态 ────────────────────────────────────────
# 保留 baker 实例，rebake biome 时复用它的 noise，避免重新 init 一次（也保证 warp 同相）
var _baker: MapBaker = null
# 保留 cfg 给 refresh_seasonal 用（不需要每次外部传）
var _last_cfg: MapConfig = null
var _last_hex_size: float = 22.0
# 当前季节（0..3）。-1 = 还没生成
var _current_season: int = -1
# Phase 13/14：保留 seed 给 lake 种子撒布、火山蓝噪声等独立随机过程用
var _last_seed: int = 0
# Milestone 3：天气子系统（每"日"由 main.gd 推进）
var _weather_system: WeatherSystem = null

# ─── 公开接口 ────────────────────────────────────────────────────────────

func generate(cfg: MapConfig, hex_size: float) -> Dictionary:
	cfg.validate()

	var effective_seed: int = cfg.seed if cfg.seed != 0 else randi()
	_rng = RandomNumberGenerator.new()
	_rng.seed = effective_seed
	_init_noise(effective_seed)

	_last_cfg = cfg
	_last_hex_size = hex_size
	_last_seed = effective_seed
	_current_season = -1

	var t_total := Time.get_ticks_msec()
	var map := _generate_cells(cfg)
	print("MapGenerator v7: per-cell %dms (%d cells)" % [Time.get_ticks_msec() - t_total, map.cell_count()])

	# Milestone 1：generate 完成后从 cell.terrain + 上下文派生 landform / vegetation / cover
	# 三轴。这一步必须在 _snapshot_base_state 之前，让基线快照能拿到三轴值。
	_sync_axes_for_map(map, cfg)

	# 在玩法层 baking 之前快照"年均"基线，给 Phase 2 季节刷新做参考
	_snapshot_base_state(map)

	# Phase 12：base_terrain 已经定型，可以做 SEA_ICE 季节判定（初始用 summer = 1）
	_apply_sea_ice_pass(map, cfg, 1)
	# SEA_ICE pass 改写了部分 cell.terrain → 重新同步轴
	_sync_axes_for_map(map, cfg)

	var t_bake := Time.get_ticks_msec()
	_baker = MapBaker.new()
	var world := _baker.bake_world(map, cfg, hex_size, effective_seed)
	print("MapGenerator v7: bake %dms" % (Time.get_ticks_msec() - t_bake))

	# 任务 7：在 bake 后新增一个轻量级 pass，把 MapBaker 烤好的 per-pixel 洋流场
	# 折返为 per-cell HexCell.ocean_current。这是逻辑层的洋流字段——渲染层从这里
	# 开始读取（任务 8），未来的 AI / 鱼群 / 航运也从这里读取。不改动 height /
	# temperature / moisture / vegetation 生成（需求显式非目标）。
	_compute_ocean_currents(map, world, hex_size)

	# 任务 7：在 bake 后新增一个轻量级 pass，把 MapBaker 烤好的 per-pixel 洋流场
	# 折返为 per-cell HexCell.ocean_current。这是逻辑层的洋流字段——渲染层从这里
	# 开始读取（任务 8），未来的 AI / 鱼群 / 航运也从这里读取。不改动 height /
	# temperature / moisture / vegetation 生成（需求显式非目标）。
	_compute_ocean_currents(map, world, hex_size)

	# 初始 current_state（认为是夏季中段，等 main.gd 推第一次 season_changed 再更新）
	for cell: HexCell in map.all_cells():
		cell.current_state = {
			"season": 1,
			"temperature": _compute_temperature(_cube_row_norm(cell, cfg), cell.elevation),
			"moisture": cell.base_moisture,
			"snow_cover": 0.0,
			"biome": int(cell.terrain),
			"landform": int(cell.landform),
			"vegetation": int(cell.vegetation),
			"cover": int(cell.cover),
			# Milestone 3：天气初始为 CLEAR，等 main.gd 推第一次 day_changed 才有真实天气
			"weather": int(WeatherType.WT.CLEAR),
			"weather_intensity": 0.0,
		}

	# Milestone 3：天气子系统初始化（与 generator 同 seed，复盘可重现）
	_weather_system = WeatherSystem.new()
	_weather_system.init(effective_seed, world.world_bounds, hex_size)

	return {"map": map, "world_data": world, "seed": effective_seed}

# 把当前 cell.terrain 作为"年均基线"保存。
# base_moisture 已在 _generate_cells 内、雨影 / 河岸生态之前快照。
# refresh_seasonal 每次从这两个基线出发应用季节扰动，避免跨季累积漂移。
# Milestone 1：同时快照 base_landform / base_vegetation 三轴基线
func _snapshot_base_state(map: MapData) -> void:
	for cell: HexCell in map.all_cells():
		cell.base_terrain = cell.terrain
		cell.base_landform = cell.landform
		cell.base_vegetation = cell.vegetation

# ─── 内部：per-cell 生成主流程 ───────────────────────────────────────────

func _generate_cells(cfg: MapConfig) -> MapData:
	var map := MapData.new(cfg.width, cfg.height)

	# 0. 大陆中心点（提供"N 个大陆"宏结构骨架）
	_continent_centers = _make_continent_centers(cfg)

	# 1. 海拔（距离场 + 域扭曲多频 fbm + meso 中频起伏 + 边缘衰减 + 离岸群岛）
	for row in range(cfg.height):
		for col in range(cfg.width):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			var nx: float = float(col) / float(cfg.width  - 1)
			var ny: float = float(row) / float(cfg.height - 1)
			cell.elevation = _compute_elevation(nx, ny, cfg)
			map.set_cell(cell)
	_normalize_elevation(map)

	# 1.5. Phase 13：撒湖泊种子（强行下沉到 sea_level - depth），让 pit-fill 不会把它们填平
	_carve_lake_seeds(map, cfg)

	# 2. 平滑 1-cell 局部洼地（让河流能 downhill 通到海，不被噪声困住）
	_smooth_pit_depressions(map, cfg)

	# 3. 山脉脊线（v8：双向脊线 + slope_gate）：只往上抬陆地，不改海陆边界
	_apply_mountain_ridges(map, cfg)

	# 4. 湿度基线（v8：多尺度大+小）
	for cell: HexCell in map.all_cells():
		var nx2: float = float(_cube_to_col(cell, cfg)) / float(cfg.width  - 1)
		var ny2: float = float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)
		cell.moisture = _compute_moisture_base(nx2, ny2)

	# 5. 初步定地形（先有 water/land 分类，下游 pass 才能区分海陆）
	for cell: HexCell in map.all_cells():
		var ny3: float = float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)
		var temp := _compute_temperature(ny3, cell.elevation)
		var terrain := _decide_terrain(cell.elevation, temp, cell.moisture, cfg)
		cell.apply_terrain(terrain)

	# 5.5. Phase 13：水体连通分量 BFS — 不与地图边界 OCEAN 连通的水体 → LAKE
	_detect_lakes(map, cfg)

	# 6. 沿岸湿度补偿（沿海陆地更湿，内陆相对偏干）
	_apply_coastal_moisture_boost(map)

	# Phase 2 关键时机：snapshot "无季节、无雨影、无河岸生态" 的基线湿度。
	# refresh_seasonal 每次都从这里出发，保证季节切换不累积。
	for cell: HexCell in map.all_cells():
		cell.base_moisture = cell.moisture

	# 7. v8 新增：雨影（上风向高山 → 背风面更干）
	_apply_rain_shadow(map, cfg)

	# 8. 重新决策非山地非冻原的低地，反映 coastal + rain_shadow 的湿度修正
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		# 山地 / 雪 / 冻原 不被湿度二次改写（它们由海拔/温度主导）
		if cell.terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.terrain == TerrainType.TERRAIN.SNOW \
				or cell.terrain == TerrainType.TERRAIN.TUNDRA:
			continue
		var ny5: float = float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)
		var temp2 := _compute_temperature(ny5, cell.elevation)
		var new_terrain := _decide_terrain(cell.elevation, temp2, cell.moisture, cfg)
		cell.apply_terrain(new_terrain)

	# 9. 河流：Flow Accumulation 算法
	_generate_rivers_flow_accumulation(map, cfg)

	# 10. v8 新增：河岸生态（DESERT 中的河 → 绿洲；河流提升 moisture）
	_apply_river_ecology(map, cfg)

	# 11. Phase 7：植被反馈（FOREST/DESERT/SWAMP/GRASSLAND → 邻居 ±moisture + 重决策）
	_apply_vegetation_feedback(map, cfg)

	# 12. Phase 11：过渡生态 3 pass（地中海灌丛 / 红树林 / 冰川）
	_apply_shrubland_pass(map, cfg)
	_apply_mangrove_pass(map, cfg)
	_apply_glacier_pass(map, cfg)

	# 13. Phase 9：SWAMP 沼泽（低海拔 + 极湿 + 暖温 + 靠水）— 在过渡生态之后跑
	_apply_swamp_pass(map, cfg)

	# 14. Phase 14：奇观地标（永久性，写完后被 _is_permanent_landform 保护不被后续 pass 覆盖）
	_apply_volcano_pass(map, cfg)
	_apply_delta_pass(map, cfg)
	_apply_oasis_pass(map, cfg)
	_apply_salt_flat_pass(map, cfg)
	_apply_badlands_pass(map, cfg)

	# 15. Phase 12：水体变种 REEF / KELP（只在 gen 时一次性判定；SEA_ICE 在 generate 后做）
	_apply_reef_kelp_pass(map, cfg)

	return map

# ─── 噪声初始化 ──────────────────────────────────────────────────────────

func _init_noise(seed_val: int) -> void:
	# 主噪声：octaves 4（v7 是 6 → 太碎，导致到处是小坑，下坡走不通）
	_height_noise = FastNoiseLite.new()
	_height_noise.noise_type           = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_height_noise.seed                 = seed_val
	_height_noise.frequency            = 0.014
	_height_noise.fractal_type         = FastNoiseLite.FRACTAL_FBM
	_height_noise.fractal_octaves      = 4
	_height_noise.fractal_lacunarity   = 2.0
	_height_noise.fractal_gain         = 0.5

	# 域扭曲：低频，让大陆轮廓非圆形
	_height_warp = FastNoiseLite.new()
	_height_warp.noise_type            = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_height_warp.seed                  = seed_val + 13
	_height_warp.frequency             = 0.025
	_height_warp.fractal_type          = FastNoiseLite.FRACTAL_FBM
	_height_warp.fractal_octaves       = 3

	# 中频细节：用于山脉脊线 / 海岸碎边
	_detail_noise = FastNoiseLite.new()
	_detail_noise.noise_type           = FastNoiseLite.TYPE_SIMPLEX
	_detail_noise.seed                 = seed_val + 257
	_detail_noise.frequency            = 0.040
	_detail_noise.fractal_type         = FastNoiseLite.FRACTAL_FBM
	_detail_noise.fractal_octaves      = 3

	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.noise_type         = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.seed               = seed_val + 9973
	_moisture_noise.frequency          = 0.022
	_moisture_noise.fractal_type       = FastNoiseLite.FRACTAL_FBM
	_moisture_noise.fractal_octaves    = 4
	_moisture_noise.fractal_lacunarity = 2.0
	_moisture_noise.fractal_gain       = 0.5

# ─── 大陆中心点（v9：层次化 main + satellites）────────────────────────────
# 先放 N 个 main（大半径、靠中央、Poisson 不重叠），然后撒 N×SATELLITES_PER_MAIN
# 个 satellite（小半径、全图随机、允许靠近 main）。每个 center 携带自己的 radius。

func _make_continent_centers(cfg: MapConfig) -> Array:
	var centers: Array = []
	var base_radius_unit: float = cfg.continent_size * 0.6
	var n_main: int = maxi(1, cfg.num_continents)
	var n_satellite: int = n_main * _c().satellites_per_main

	# 1. 主大陆：随机半径 + Poisson 排除（不允许重叠）
	for i in range(n_main):
		var radius: float = lerpf(_c().main_radius_min, _c().main_radius_max, _rng.randf()) * base_radius_unit
		var pos = _try_place(
			centers, radius,
			_c().main_placement_min, _c().main_placement_max,
			_c().main_separation_factor, 50
		)
		if pos != null:
			centers.append({"pos": pos, "radius": radius, "kind": "main"})

	# 2. 卫星岛：更小半径 + 更宽放置范围 + 更松离散度
	for i in range(n_satellite):
		var radius: float = lerpf(_c().satellite_radius_min, _c().satellite_radius_max, _rng.randf()) * base_radius_unit
		var pos = _try_place(
			centers, radius,
			_c().satellite_placement_min, _c().satellite_placement_max,
			_c().satellite_separation_factor, 30
		)
		if pos != null:
			centers.append({"pos": pos, "radius": radius, "kind": "satellite"})
		# 找不到位置就跳过这个 satellite（不强求全部放下）

	return centers

# Poisson 拒绝采样：尝试 max_attempts 次找一个不与已有 centers 重叠的位置。
# 重叠定义：距离 < (my_radius + 已有半径) × sep_factor。
# 找到返回 Vector2，找不到返回 null。
func _try_place(
		existing: Array,
		radius: float,
		lo: float,
		hi: float,
		sep_factor: float,
		max_attempts: int) -> Variant:
	for attempt in range(max_attempts):
		var pos := Vector2(_rng.randf_range(lo, hi), _rng.randf_range(lo, hi))
		var ok: bool = true
		for c in existing:
			var c_pos: Vector2 = c["pos"]
			var c_radius: float = float(c["radius"])
			var d: float = pos.distance_to(c_pos)
			var min_d: float = (radius + c_radius) * sep_factor
			if d < min_d:
				ok = false
				break
		if ok:
			return pos
	return null

# ─── 海拔计算（域扭曲距离场 + 多频 fbm + 边缘衰减） ──────────────────────

func _compute_elevation(nx: float, ny: float, _cfg: MapConfig) -> float:
	# 1. 距离值扰动（让大陆边界波浪化但不桥接）
	# 每个 center 的 dist 都加上同一个 perturbation，所以海岸线沿地图连贯波动。
	# 远 deep-ocean 的 dist 远大于任何 center 的 radius，加 ±amp 后 dist_field 仍然是 0。
	var dist_perturb: float = _height_warp.get_noise_2d(nx * 250.0 + 11.3, ny * 250.0 - 7.1) * _c().continent_warp_amp

	# 2. 大陆距离场（v9 max-over-centers）：每个 center 各自算 dist_field 后取最大
	# 这样不同大小自然处理：靠近大 main 的 cell 会被大半径覆盖，靠近 satellite 的
	# cell 由小半径决定。center 之间不重叠时，不同的 center 各自定义自己的"陆地圆"。
	var dist_field: float = 0.0
	for c in _continent_centers:
		var c_pos: Vector2 = c["pos"]
		var c_radius: float = float(c["radius"])
		var dx: float = nx - c_pos.x
		var dy: float = ny - c_pos.y
		var d: float = sqrt(dx * dx + dy * dy) + dist_perturb
		var df: float = clampf(1.0 - d / c_radius, 0.0, 1.0)
		df = pow(df, 1.5)  # 让大陆边缘衰减更柔和
		if df > dist_field:
			dist_field = df

	# 3. 多频 fbm（用扭曲坐标），给距离场加自然起伏
	var u: float = nx * 200.0
	var v: float = ny * 200.0
	var u_warp: float = _height_warp.get_noise_2d(u + 11.3, v - 7.1) * 35.0
	var v_warp: float = _height_warp.get_noise_2d(u - 23.7, v + 41.5) * 35.0
	var c1: float = _height_noise.get_noise_2d(u + u_warp, v + v_warp)              # 大陆主形
	var c2: float = _detail_noise.get_noise_2d(u * 1.7 + u_warp, v * 1.7 + v_warp)  # 中频
	var noise_01: float = ((c1 * 0.70 + c2 * 0.30) + 1.0) * 0.5  # → [0, 1]

	# 3.5. v8 新增：meso-scale 中频噪声（给大陆内部加 plateau / valley 起伏）
	# 频率比 macro 高，比 detail 低 —— 能在 continent 内部产生几个大块的"高地区/低地区"，
	# 后续 ridge 会优先在 meso 高地形成山脉走向，避免山地全堆在 continent 中心。
	var meso: float = (_detail_noise.get_noise_2d(nx * 400.0 + 137.0, ny * 400.0 - 91.0) + 1.0) * 0.5

	# 4. 海岸细碎噪声（让海岸线不规则）
	var coast: float = _height_noise.get_noise_2d(nx * 80.0 + 500.0, ny * 80.0 + 500.0) * 0.06

	# 4.5. v8 新增：离岸群岛 noise（仅当 dist_field=0 时偶发把海面顶到陆地）
	# pow(max(noise - 0.55, 0), 1.5) 是 sparse 触发：大部分时候 noise < 0.55 → 0；
	# 偶尔强 spike → 把海面 raw 抬到 sea_level 之上，形成小岛
	var offshore_raw: float = _detail_noise.get_noise_2d(nx * 900.0 - 333.0, ny * 900.0 + 217.0)
	var offshore: float = pow(maxf(offshore_raw - 0.55, 0.0), 1.5) * _c().offshore_amp

	# 5. 合成：距离场 + 距离场×(macro_noise + meso) + 海岸细节 + 离岸群岛
	# 关键：noise 必须 × dist_field，否则 noise 的均值（0.5）会给地图每个 cell
	# 永久加 0.5*NOISE_WEIGHT = 0.225，远离大陆的中间海域被错误抬到陆地
	# 把两个 continent_center 的间隙焊死成一整块大陆。
	# 现在 noise 只在 dist_field > 0 的区域起作用 = 只在大陆内部加变化。
	# offshore 是 sparse 例外：它能让 dist_field=0 区域偶有岛屿。
	# 注意：ridge 不在这里加！否则会被卷进 _normalize_elevation 的范围里
	# 导致归一化分母变大，把所有非山 cell 压低，损失陆地。
	var raw: float = dist_field * (_c().dist_field_weight + noise_01 * _c().noise_weight + meso * _c().meso_weight) + coast + offshore

	# 6. 边缘衰减：保证地图边界四周是海
	# v7.3：给"距中心距离"加噪声扰动，否则 maxf 给出的是切比雪夫 L∞ 距离，
	# 等距线是矩形 → 海洋形成方框相框。加噪声后等距线变波浪。
	var edge_dx: float = absf(nx - 0.5) * 2.0
	var edge_dy: float = absf(ny - 0.5) * 2.0
	var edge_d_base: float = maxf(edge_dx, edge_dy)
	var edge_perturb: float = _height_warp.get_noise_2d(nx * 150.0 + 199.0, ny * 150.0 - 73.0) * 0.38
	var edge_d: float = edge_d_base + edge_perturb
	var edge_t: float = smoothstep(_c().edge_falloff_start, _c().edge_falloff_end, edge_d)
	raw -= edge_t * _c().edge_falloff_depth

	return raw

# v8 升级：在 normalize 之后单独给陆地 cell 加 ridge 山脉
# - 只动 elevation > sea_level 的 cell（海洋不变 → 海陆边界不动）
# - 双向脊线（ridge_a + ridge_b 取强者）→ 山脉链有不同走向，不再单一方向
# - slope_gate：cell 与最低邻居海拔差越大 → 受 ridge 推力越强 → 平地/高原不全升山
# - 加成幅度乘以 land_factor^1.5（高地多加，海岸线附近少加）
# - 结果 clamp 到 [0, 1] 防止溢出，不影响其他 cell
func _apply_mountain_ridges(map: MapData, cfg: MapConfig) -> void:
	if _c().ridge_boost_amp <= 0.0:
		return
	for cell: HexCell in map.all_cells():
		if cell.elevation < cfg.sea_level:
			continue
		var off := HexUtils.cube_to_offset(cell.q, cell.r)
		var nx2: float = float(off.x) / float(cfg.width - 1)
		var ny2: float = float(off.y) / float(cfg.height - 1)

		# v8：双向脊线 —— 两套频率/相位不同的 ridge noise，取强者
		# ridge_signal = 1 - |fbm|，[0, 1] 的脊形噪声（脊上 ≈ 1，远离脊 ≈ 0）
		# 两套合并 → 不同走向的山脉链交织出现
		var ridge_a: float = 1.0 - absf(_detail_noise.get_noise_2d(nx2 * 180.0 + 71.3, ny2 * 180.0 - 33.7))
		var ridge_b: float = 1.0 - absf(_detail_noise.get_noise_2d(nx2 * 220.0 - 50.7, ny2 * 220.0 + 91.1))
		var ridge_signal: float = pow(maxf(ridge_a, ridge_b), 1.4)  # 锐化脊线

		# v8：坡度门控 —— cell 比最低邻居高得越多，受 ridge 推力越强
		# 这避免了"高原全部 cell 都被抬到山地" —— 高原内部坡度为 0，几乎不加 ridge；
		# 高原边缘坡度大，被推得更高 → 形成自然山脉走向（而非整片高原）
		var slope: float = _compute_slope(cell, map)
		var slope_gate: float = clampf(slope * 8.0, 0.30, 1.0)  # 0.30 = 平地最低权重；1.0 = 强坡满

		# land_factor：高地多加（≈1），海岸线附近少加（≈0）
		var land_factor: float = (cell.elevation - cfg.sea_level) / maxf(1.0 - cfg.sea_level, 0.001)
		# v7.4：从平方降到 1.5 次方
		land_factor = pow(land_factor, 1.5)

		var addition: float = ridge_signal * land_factor * slope_gate * _c().ridge_boost_amp
		var raw_post: float = cell.elevation + addition

		# v10.4：软饱和 + 硬封顶。渐近线从 1.0 降到 LAND_ELEV_CAP=0.93。
		# 关键洞察：shader 的 hypsometric snow 段是 t > 0.985（≈ elev > 0.992），
		# peak 段是 t > 0.85（≈ elev > 0.916）。如果 cell elev 能到 0.99，
		# 经过 hillshade × 1.45 + grain × 1.05 后，peak 色会被推到接近白。
		# 把 land 上限封到 0.93（max t ≈ 0.875）→ 即便最高的山顶也只在
		# mountain→peak 段的 18% 位置，色彩偏 mountain 而非 peak，自然不显白。
		# 例：raw=1.0 → 0.882, raw=1.5 → 0.927, raw=2.0 → 0.929（asymp 0.93）
		var soft_max: float = 0.78
		var land_elev_cap: float = 0.93
		if raw_post > soft_max:
			var excess: float = raw_post - soft_max
			raw_post = soft_max + (land_elev_cap - soft_max) * (1.0 - exp(-excess * 3.0))
		cell.elevation = clampf(raw_post, 0.0, land_elev_cap)

# v8：返回 cell 与其最低邻居的海拔差（仅陆地，>= 0）
# 用于 ridge boost 的 slope_gate：差值大 = 该 cell 在坡上 → 加 ridge；
# 差值小 = 平地/高原内部 → 几乎不加 ridge
func _compute_slope(cell: HexCell, map: MapData) -> float:
	var lowest: float = cell.elevation
	for nb: HexCell in map.get_neighbors(cell):
		if nb.elevation < lowest:
			lowest = nb.elevation
	return cell.elevation - lowest

# ─── 局部洼地平滑（让河流的 flow accumulation 能下坡到海） ──────────────
# 不平滑会导致大量"碗形 1-cell pit"，flow 在那里止步，最后过滤剩不了几条河。
# 算法：迭代检查每个陆地 cell，如果它比所有 6 个邻居都低 → 抬到最低邻居 + 0.001。

func _smooth_pit_depressions(map: MapData, cfg: MapConfig) -> void:
	# v10：从 12 提到 PIT_FILL_MAX_ITERS（默认 100）。多 cell 盆地需要 N 次迭代才能
	# 把"抬高"从中心传播到边缘，旧的 12 次对大于 12 cell 的盆地不够 → 河流卡死。
	for it in range(_c().pit_fill_max_iters):
		var changed: bool = false
		for cell: HexCell in map.all_cells():
			if cell.elevation < cfg.sea_level:
				continue  # 水下不需要平滑
			var nbs := map.get_neighbors(cell)
			if nbs.is_empty():
				continue
			var lowest_nb: float = INF
			for nb: HexCell in nbs:
				if nb.elevation < lowest_nb:
					lowest_nb = nb.elevation
			# 如果当前 cell 比所有邻居都低（即它是 pit）→ 抬到刚好高于最低邻居
			if lowest_nb < INF and cell.elevation <= lowest_nb:
				cell.elevation = lowest_nb + 0.001
				changed = true
		if not changed:
			break

# ─── Phase 13：湖泊种子 + 水体连通分量检测 ─────────────────────────────────

# 用低频噪声选 ~5% 内陆陆地 cell 当湖泊种子，强行下沉到 sea_level - depth。
# 必须满足：
#   1) elevation 在 sea_level + 0.04 以上（避免和现有海连通）
#   2) cell 在地图内部（远离边界至少 LAKE_SEED_MIN_INTERIOR）
#   3) 噪声值 > LAKE_SEED_THRESHOLD（让湖呈簇分布而不是孤立散点）
# pit-fill 阶段会跳过 elevation < sea_level 的 cell，所以这些下沉的种子不会被填平。
# const LAKE_SEED_FREQ (migrated to ClimateProfile.lake_seed_freq)
# const LAKE_SEED_THRESHOLD (migrated to ClimateProfile.lake_seed_threshold)
# const LAKE_SEED_DEPTH (migrated to ClimateProfile.lake_seed_depth)
# const LAKE_SEED_MIN_INTERIOR (migrated to ClimateProfile.lake_seed_min_interior)

func _carve_lake_seeds(map: MapData, cfg: MapConfig) -> void:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = _last_seed + 9173
	noise.frequency = _c().lake_seed_freq
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	var w_min: float = _c().lake_seed_min_interior
	var w_max: float = 1.0 - _c().lake_seed_min_interior
	var sea: float = cfg.sea_level
	var seed_count: int = 0
	for cell: HexCell in map.all_cells():
		if cell.elevation < sea + 0.04:
			continue
		var nx: float = float(_cube_to_col(cell, cfg)) / float(cfg.width  - 1)
		var ny: float = float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)
		if nx < w_min or nx > w_max or ny < w_min or ny > w_max:
			continue
		var n: float = noise.get_noise_2d(float(cell.q), float(cell.r))
		if n < _c().lake_seed_threshold:
			continue
		# 进一步过滤：所有 6 邻居必须是陆地，避免把湖凿在海边（会和海连通失去意义）
		var has_water_neighbor: bool = false
		for nb: HexCell in map.get_neighbors(cell):
			if nb.elevation < sea:
				has_water_neighbor = true
				break
		if has_water_neighbor:
			continue
		cell.elevation = sea - _c().lake_seed_depth
		cell.is_lake_seed = true
		seed_count += 1
	print("Phase 13: %d lake seeds" % seed_count)

# 水体连通分量 BFS。从地图边界的 OCEAN/COAST 出发标 connected_to_ocean，
# 没标到的水体 cell（OCEAN/COAST）→ LAKE。
# 注意：此时 LAKE 还没生成，所以 _is_water 只匹配 OCEAN/COAST，不会误把已分配的 LAKE 视作 ocean-connected。
func _detect_lakes(map: MapData, cfg: MapConfig) -> void:
	var connected: Dictionary = {}
	var queue: Array[HexCell] = []
	# 1) 边界水体作种子
	for cell: HexCell in map.all_cells():
		if cell.terrain != TerrainType.TERRAIN.OCEAN \
				and cell.terrain != TerrainType.TERRAIN.COAST:
			continue
		var col: int = _cube_to_col(cell, cfg)
		var row: int = _cube_to_row(cell, cfg)
		if col == 0 or col == cfg.width - 1 or row == 0 or row == cfg.height - 1:
			connected[Vector3i(cell.q, cell.r, cell.s)] = true
			queue.append(cell)
	# 2) BFS 扩散到所有 ocean-connected 水体
	while not queue.is_empty():
		var c: HexCell = queue.pop_front()
		for nb: HexCell in map.get_neighbors(c):
			if nb.terrain != TerrainType.TERRAIN.OCEAN \
					and nb.terrain != TerrainType.TERRAIN.COAST:
				continue
			var k := Vector3i(nb.q, nb.r, nb.s)
			if connected.has(k):
				continue
			connected[k] = true
			queue.append(nb)
	# 3) 没在 connected 集合的水体 cell → LAKE
	var lake_count: int = 0
	for cell: HexCell in map.all_cells():
		if cell.terrain != TerrainType.TERRAIN.OCEAN \
				and cell.terrain != TerrainType.TERRAIN.COAST:
			continue
		if not connected.has(Vector3i(cell.q, cell.r, cell.s)):
			cell.apply_terrain(TerrainType.TERRAIN.LAKE)
			lake_count += 1
	print("Phase 13: %d lake cells" % lake_count)

func _normalize_elevation(map: MapData) -> void:
	var min_e: float = INF
	var max_e: float = -INF
	for cell: HexCell in map.all_cells():
		if cell.elevation < min_e:
			min_e = cell.elevation
		if cell.elevation > max_e:
			max_e = cell.elevation
	var range_e: float = max_e - min_e
	if range_e < 0.001:
		return
	var inv := 1.0 / range_e
	for cell: HexCell in map.all_cells():
		cell.elevation = (cell.elevation - min_e) * inv

# ─── 温度（cos bell 曲线） ───────────────────────────────────────────────

func _compute_temperature(ny: float, elevation: float) -> float:
	# 用余弦做平滑钟形：赤道（ny=0.5）最高 ~1.0，两极 0
	var lat_signed: float = (ny - 0.5) * 2.0   # [-1, +1]
	var lat_temp: float = pow(cos(lat_signed * PI * 0.5), 1.2)
	var alt_penalty: float = elevation * 0.5
	return clampf(lat_temp - alt_penalty, 0.0, 1.0)

# ─── 湿度（多尺度噪声，v8） ─────────────────────────────────────────────
# 大尺度 + 小尺度混合：
# - 大尺度（freq 100）创建"潮湿带"和"干旱带"的大区域结构
# - 小尺度（freq 400）在大区域内加入局部变化（避免全部一片同色）
# 配比 0.65 大 + 0.35 小：能看到大尺度气候带，但不死板。

func _compute_moisture_base(nx: float, ny: float) -> float:
	var large: float = (_moisture_noise.get_noise_2d(nx * 100.0, ny * 100.0) + 1.0) * 0.5
	var small: float = (_moisture_noise.get_noise_2d(nx * 400.0 + 79.0, ny * 400.0 - 31.0) + 1.0) * 0.5
	return clampf(large * 0.65 + small * 0.35, 0.0, 1.0)

# v8 新增：雨影（rain shadow）
# 主导风向上风方有更高的山 → 当前 cell 在山的背风面 → 湿度衰减
# 模拟现实：例如美洲西风带 + 落基山脉 → 山脉以东的内陆是干旱大平原
#
# 算法：
#   1. 把 PREVAILING_WIND（vec2）转到 cube 空间，找最匹配的 hex 邻居方向作为"上风方向"
#   2. 对每个陆地 cell，向"上风方向"走 RAIN_SHADOW_LOOKBACK 步
#   3. 如果那个 upwind cell 海拔比当前 cell 高 RAIN_SHADOW_THRESHOLD 以上 → moisture 衰减
# Phase 6：旧的全局风向 _apply_rain_shadow 包装到 per-cell 版本，
# 默认用 season_phase=1.0（夏季）当 baseline。
func _apply_rain_shadow(map: MapData, cfg: MapConfig) -> void:
	_apply_rain_shadow_per_cell(map, cfg, 1.0)

# Phase 6：每个陆地 cell 根据自己的纬度算盛行风向，做自己的雨影 lookback。
# 不再全图同向 → 出现纬度风带分布（信风带 / 西风带 / 极地东风带），
# 配合 _height_warp 给 ny 加一点 jitter，让风带边界呈犬牙交错而不是死板水平条纹。
func _apply_rain_shadow_per_cell(map: MapData, cfg: MapConfig, season_phase: float) -> void:
	var lookback: int = _c().rain_shadow_lookback
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		# 用 _height_warp 给 ny 一点 ±0.04 扰动，让风带边界不对齐到整数 ny
		var jitter: float = _height_warp.get_noise_2d(float(cell.q) * 8.0, float(cell.r) * 8.0) * 0.04
		var wind: Vector2 = WindBeltScript.wind_at(ny, season_phase, jitter)
		var best_dir: Vector3i = WindBeltScript.upwind_hex_dir(wind)
		var target_cube := Vector3i(
			cell.q + best_dir.x * lookback,
			cell.r + best_dir.y * lookback,
			cell.s + best_dir.z * lookback
		)
		var upwind_cell: HexCell = map.get_cell_by_cube(target_cube)
		if upwind_cell == null:
			continue
		if upwind_cell.elevation > cell.elevation + _c().rain_shadow_threshold:
			cell.moisture *= _c().rain_shadow_factor

# v8 新增：河岸生态
# 现实里河流两岸总是更绿、更肥沃 —— 沙漠中也有"绿洲带"。
# 算法：has_river 的 cell 强制提升 moisture，并把 DESERT/PLAIN 升级成
# GRASSLAND（温带）或 FOREST（暖湿）。
#
# 注意：这个 pass 必须在 rivers 生成之后、最后一次 terrain 决策之前调用。
func _apply_river_ecology(map: MapData, cfg: MapConfig) -> void:
	for cell: HexCell in map.all_cells():
		if not cell.has_river:
			continue
		if _is_water(cell.terrain):
			continue
		# Phase 14：永久地标不被翻新（OASIS/DELTA 等已经吸收了河岸生态）
		if _is_permanent_landform(cell.terrain):
			cell.moisture = maxf(cell.moisture, 0.65)
			continue
		# 河流必然带来湿度（保底 0.65）
		cell.moisture = maxf(cell.moisture, 0.65)
		# DESERT 中的河 → 由 _apply_oasis_pass 单独转为 OASIS（不再粗暴翻成 GRASSLAND）
		if cell.terrain == TerrainType.TERRAIN.DESERT:
			continue
		# PLAIN 中的河，按温度分流：暖 → FOREST，温带 → GRASSLAND
		if cell.terrain == TerrainType.TERRAIN.PLAIN:
			var ny: float = float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)
			var temp: float = _compute_temperature(ny, cell.elevation)
			if temp > 0.55:
				cell.apply_terrain(TerrainType.TERRAIN.FOREST)
			elif temp > 0.30:
				cell.apply_terrain(TerrainType.TERRAIN.GRASSLAND)

# ─── Phase 7：植被反馈（biome 给邻居加/减湿度 + 边界 cell 重决策） ──────────
#
# 现实里森林通过蒸腾作用让周边降雨增多、沙漠通过强反照率降低周边降雨，
# 沼泽则是最强的水汽源。把这些反馈做成 1 pass diffusion，能产生
# "森林成片 / 沙漠成片 / 沼泽成簇" 的视觉聚类，而不是噪声散点。
#
# 算法：
#   1) 计算每个 donor biome 给邻居的 ±moisture 贡献（不立即写回，避免顺序敏感）
#   2) 累加 deltas 到目标 cell 的 moisture
#   3) 重决策非永久 biome（让边界 cell 翻转）
#   4) 重新跑 SWAMP pass（湿度变了，可能诞生新 SWAMP 或退化）
#
# Donor 强度：
#   FOREST: +0.06（蒸腾）
#   SWAMP:  +0.10（最强，水汽蒸发）
#   GRASSLAND: +0.02（温和加湿）
#   DESERT: -0.04（吸湿，干热反照率）
#   其他: 0
#
# 限幅：单 pass 不会无限循环；但若发现"森林吞掉一切"，调小 FOREST donor。

# const VEG_FOREST_DONOR (migrated to ClimateProfile.veg_forest_donor)
# const VEG_SWAMP_DONOR (migrated to ClimateProfile.veg_swamp_donor)
# const VEG_GRASSLAND_DONOR (migrated to ClimateProfile.veg_grassland_donor)
# const VEG_DESERT_DONOR (migrated to ClimateProfile.veg_desert_donor)
# Phase 10
# const VEG_JUNGLE_DONOR (migrated to ClimateProfile.veg_jungle_donor)      # 雨林比 FOREST 还湿
# const VEG_TAIGA_DONOR (migrated to ClimateProfile.veg_taiga_donor)       # 针叶林湿度中高
# const VEG_SAVANNA_DONOR (migrated to ClimateProfile.veg_savanna_donor)     # 稀树草原温和
# Phase 14
# const VEG_OASIS_DONOR (migrated to ClimateProfile.veg_oasis_donor)       # 绿洲蒸发强
# const VEG_DELTA_DONOR (migrated to ClimateProfile.veg_delta_donor)       # 三角洲湿地
# const VEG_SALT_FLAT_DONOR (migrated to ClimateProfile.veg_salt_flat_donor)  # 盐渍降低周边土壤可用水
# STEPPE 中性，不进 match

func _vegetation_donor_amount(t: int) -> float:
	var c := _c()
	match t:
		TerrainType.TERRAIN.FOREST:    return c.veg_forest_donor
		TerrainType.TERRAIN.SWAMP:     return c.veg_swamp_donor
		TerrainType.TERRAIN.GRASSLAND: return c.veg_grassland_donor
		TerrainType.TERRAIN.DESERT:    return c.veg_desert_donor
		TerrainType.TERRAIN.JUNGLE:    return c.veg_jungle_donor
		TerrainType.TERRAIN.TAIGA:     return c.veg_taiga_donor
		TerrainType.TERRAIN.SAVANNA:   return c.veg_savanna_donor
		TerrainType.TERRAIN.OASIS:     return c.veg_oasis_donor
		TerrainType.TERRAIN.DELTA:     return c.veg_delta_donor
		TerrainType.TERRAIN.SALT_FLAT: return c.veg_salt_flat_donor
		_:                              return 0.0

func _apply_vegetation_feedback(map: MapData, cfg: MapConfig) -> void:
	# 1) 累加 delta（不立即写回）
	var deltas: Dictionary = {}
	for cell: HexCell in map.all_cells():
		var donor: float = _vegetation_donor_amount(int(cell.terrain))
		if donor == 0.0:
			continue
		for nb: HexCell in map.get_neighbors(cell):
			if _is_water(nb.terrain):
				continue  # 水体湿度不参与
			var k := Vector3i(nb.q, nb.r, nb.s)
			deltas[k] = float(deltas.get(k, 0.0)) + donor

	# 2) 应用 delta 到 moisture（限幅）
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var k := Vector3i(cell.q, cell.r, cell.s)
		if not deltas.has(k):
			continue
		var d: float = float(deltas[k])
		cell.moisture = clampf(cell.moisture + d, 0.0, 1.0)

	# 3) 重决策非永久 biome（边界 cell 翻转）
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		if cell.terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.terrain == TerrainType.TERRAIN.SNOW:
			continue
		# Phase 14：永久地标不被气候反馈翻新
		if _is_permanent_landform(cell.terrain):
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp: float = _compute_temperature(ny, cell.elevation)
		var new_terrain := _decide_terrain(cell.elevation, temp, cell.moisture, cfg)
		cell.apply_terrain(new_terrain)

# Phase 9：SWAMP 沼泽决策 pass
# 触发条件（必须全部满足）：
#   1) 低海拔：land_h < 0.10（紧贴海平面，避免高地误判）
#   2) 极湿：moisture > 0.75
#   3) 暖温：temperature > 0.30（冷区是 TUNDRA / SNOW，不会形成沼泽）
#   4) 靠水：cell.has_river 或紧邻 OCEAN/COAST cell（避免内陆盆地误判）
# 永久 biome（MOUNTAIN/SNOW/TUNDRA）跳过；OCEAN/COAST 不参与判定。
func _apply_swamp_pass(map: MapData, cfg: MapConfig) -> void:
	var inv_above_sea := 1.0 / maxf(1.0 - cfg.sea_level, 0.001)
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		if cell.terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.terrain == TerrainType.TERRAIN.SNOW \
				or cell.terrain == TerrainType.TERRAIN.TUNDRA:
			continue
		if _is_permanent_landform(cell.terrain):
			continue
		var land_h: float = (cell.elevation - cfg.sea_level) * inv_above_sea
		if land_h > 0.10:
			continue
		if cell.moisture < 0.75:
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp: float = _compute_temperature(ny, cell.elevation)
		if temp < 0.30:
			continue
		var has_water: bool = cell.has_river
		if not has_water:
			for nb: HexCell in map.get_neighbors(cell):
				if _is_water(nb.terrain):
					has_water = true
					break
		if not has_water:
			continue
		cell.apply_terrain(TerrainType.TERRAIN.SWAMP)

# ─── Phase 11：过渡生态 3 pass ─────────────────────────────────────────────

# SHRUBLAND（灌丛 / 地中海植被）
# 触发：暖温 + 中干 + 低海拔 + 至少一个 OCEAN/COAST 邻居（地中海气候要靠海）
# 不动：永久 biome / 已经是 SWAMP / JUNGLE / TAIGA / FOREST 等成熟林相
func _apply_shrubland_pass(map: MapData, cfg: MapConfig) -> void:
	var inv_above_sea := 1.0 / maxf(1.0 - cfg.sea_level, 0.001)
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		# 仅替换"半干旱草原 / 平原"类，避免吃掉已成形的森林
		var t := int(cell.terrain)
		if t != TerrainType.TERRAIN.GRASSLAND \
				and t != TerrainType.TERRAIN.STEPPE \
				and t != TerrainType.TERRAIN.SAVANNA \
				and t != TerrainType.TERRAIN.PLAIN:
			continue
		if _is_permanent_landform(cell.terrain):
			continue
		var land_h: float = (cell.elevation - cfg.sea_level) * inv_above_sea
		if land_h > 0.30:
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp: float = _compute_temperature(ny, cell.elevation)
		if temp < 0.50:
			continue
		if cell.moisture < 0.25 or cell.moisture > 0.40:
			continue
		# 必须靠海（OCEAN/COAST 邻居 ≥ 1）— 地中海气候特征
		var has_sea: bool = false
		for nb: HexCell in map.get_neighbors(cell):
			if nb.terrain == TerrainType.TERRAIN.OCEAN \
					or nb.terrain == TerrainType.TERRAIN.COAST:
				has_sea = true
				break
		if not has_sea:
			continue
		cell.apply_terrain(TerrainType.TERRAIN.SHRUBLAND)

# MANGROVE（红树林）
# 触发：热带 + 极低海拔 + 紧邻 COAST + (has_river 或 SWAMP 邻接)
# 类似 SWAMP 但更偏沿海，是热带潮间带
func _apply_mangrove_pass(map: MapData, cfg: MapConfig) -> void:
	var inv_above_sea := 1.0 / maxf(1.0 - cfg.sea_level, 0.001)
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		# MANGROVE 优先级低于 SWAMP（SWAMP 已生成的不动），且不动山地 / 雪 / 冻原
		if cell.terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.terrain == TerrainType.TERRAIN.SNOW \
				or cell.terrain == TerrainType.TERRAIN.TUNDRA \
				or cell.terrain == TerrainType.TERRAIN.SWAMP:
			continue
		if _is_permanent_landform(cell.terrain):
			continue
		var land_h: float = (cell.elevation - cfg.sea_level) * inv_above_sea
		if land_h > 0.05:
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp: float = _compute_temperature(ny, cell.elevation)
		if temp < 0.65:
			continue
		# 必须紧邻 COAST（不接 OCEAN — 红树林只在浅海岸）
		var coast_neighbor: bool = false
		var swamp_neighbor: bool = false
		for nb: HexCell in map.get_neighbors(cell):
			if nb.terrain == TerrainType.TERRAIN.COAST:
				coast_neighbor = true
			elif nb.terrain == TerrainType.TERRAIN.SWAMP:
				swamp_neighbor = true
		if not coast_neighbor:
			continue
		# 进一步约束：要么有河（淡水汇入），要么 SWAMP 邻接（潮间带连续）
		if not (cell.has_river or swamp_neighbor):
			continue
		cell.apply_terrain(TerrainType.TERRAIN.MANGROVE)

# ─── Phase 12：水体变种（REEF / SEA_ICE / KELP） ────────────────────────────

# REEF（珊瑚礁）+ KELP（海藻林）：gen-time 一次性，不随季节变化
# 优先级：先判 REEF（暖海），再判 KELP（凉温带），互斥
# 仅替换 OCEAN/COAST，保留它们的 passable_sea；不动其它水体（LAKE 不能长珊瑚）
func _apply_reef_kelp_pass(map: MapData, cfg: MapConfig) -> void:
	for cell: HexCell in map.all_cells():
		var t := int(cell.terrain)
		if t != TerrainType.TERRAIN.COAST and t != TerrainType.TERRAIN.OCEAN:
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp: float = _compute_temperature(ny, cell.elevation)
		# 必须紧邻陆地（大陆架），避免深海里也长珊瑚 / 海藻
		var has_land_neighbor: bool = false
		var has_river_outlet_neighbor: bool = false
		for nb: HexCell in map.get_neighbors(cell):
			if not _is_water(nb.terrain):
				has_land_neighbor = true
				if nb.has_river:
					has_river_outlet_neighbor = true
					break
		if not has_land_neighbor:
			continue
		# REEF：暖海（temp > 0.60）+ 远离河口（淡水 + 沉积物会杀死珊瑚）
		if temp > 0.60 and not has_river_outlet_neighbor:
			# 仅 COAST 改 REEF（深海不长珊瑚）
			if t == TerrainType.TERRAIN.COAST:
				cell.apply_terrain(TerrainType.TERRAIN.REEF)
				continue
		# KELP：凉温带（temp ∈ [0.30, 0.55]）+ 紧贴大陆（has_land_neighbor 已确保）
		if temp >= 0.30 and temp <= 0.55:
			if t == TerrainType.TERRAIN.COAST:
				cell.apply_terrain(TerrainType.TERRAIN.KELP)

# SEA_ICE（海冰）：每季都重判定（用当季温度），需要 base_terrain 当 revert target
# 阈值带 hysteresis：形成 temp < 0.07，融化 temp > 0.12，避免季节边界抖动
# const SEA_ICE_FORM_THRESHOLD (migrated to ClimateProfile.sea_ice_form_threshold)
# const SEA_ICE_MELT_THRESHOLD (migrated to ClimateProfile.sea_ice_melt_threshold)

func _apply_sea_ice_pass(map: MapData, cfg: MapConfig, season: int) -> void:
	for cell: HexCell in map.all_cells():
		var current: int = int(cell.terrain)
		var base: int = int(cell.base_terrain)
		# 仅水体（OCEAN/COAST/REEF/KELP/SEA_ICE）参与；LAKE 跳过（淡水有自己的冻结，未来 phase 再做）
		var is_marine: bool = (current == TerrainType.TERRAIN.OCEAN \
				or current == TerrainType.TERRAIN.COAST \
				or current == TerrainType.TERRAIN.REEF \
				or current == TerrainType.TERRAIN.KELP \
				or current == TerrainType.TERRAIN.SEA_ICE)
		if not is_marine:
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp_year: float = _compute_temperature(ny, cell.elevation)
		var temp_now: float = clampf(temp_year + _season_temp_offset(ny, season), 0.0, 1.0)
		if current == TerrainType.TERRAIN.SEA_ICE:
			# 当前是冰：温暖到融化阈值之上 → 还原 base_terrain
			if temp_now > _c().sea_ice_melt_threshold:
				cell.apply_terrain(base if base != TerrainType.TERRAIN.SEA_ICE else TerrainType.TERRAIN.OCEAN)
		else:
			# 当前不是冰：寒冷到形成阈值之下 → 冻结
			if temp_now < _c().sea_ice_form_threshold:
				cell.apply_terrain(TerrainType.TERRAIN.SEA_ICE)

# ─── Phase 14：奇观地标 5 pass ──────────────────────────────────────────────

# VOLCANO（火山）：在高山上撒 ~3-8 个独立点
# 输出：cell.has_volcano = true（不替换 terrain，让 MOUNTAIN 渲染保留）
# const MAX_VOLCANOES (migrated to ClimateProfile.max_volcanoes)
# const VOLCANO_MIN_DIST (migrated to ClimateProfile.volcano_min_dist)  # 任意两座火山的最小 hex 距离
# const VOLCANO_MIN_LAND_H (migrated to ClimateProfile.volcano_min_land_h)

func _apply_volcano_pass(map: MapData, cfg: MapConfig) -> void:
	var inv_above_sea := 1.0 / maxf(1.0 - cfg.sea_level, 0.001)
	var candidates: Array[HexCell] = []
	for cell: HexCell in map.all_cells():
		if cell.terrain != TerrainType.TERRAIN.MOUNTAIN:
			continue
		var land_h: float = (cell.elevation - cfg.sea_level) * inv_above_sea
		if land_h < _c().volcano_min_land_h:
			continue
		candidates.append(cell)
	if candidates.is_empty():
		return
	# 用 _rng 打乱后 greedy 选 — 保证可复现
	var rng := RandomNumberGenerator.new()
	rng.seed = _last_seed + 7717
	for i in range(candidates.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: HexCell = candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = tmp
	var placed: Array[HexCell] = []
	for cand: HexCell in candidates:
		if placed.size() >= _c().max_volcanoes:
			break
		var ok: bool = true
		for p: HexCell in placed:
			# cube 距离
			var d: int = (absi(cand.q - p.q) + absi(cand.r - p.r) + absi(cand.s - p.s)) / 2
			if d < _c().volcano_min_dist:
				ok = false
				break
		if not ok:
			continue
		cand.has_volcano = true
		placed.append(cand)
	print("Phase 14: %d volcanoes" % placed.size())

# DELTA（三角洲）：河流流入海前的最末端 land 格
# 触发：has_river + land_h < 0.08 + 至少 1 个 OCEAN/COAST 邻居
func _apply_delta_pass(map: MapData, cfg: MapConfig) -> void:
	var inv_above_sea := 1.0 / maxf(1.0 - cfg.sea_level, 0.001)
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		if not cell.has_river:
			continue
		if _is_permanent_landform(cell.terrain):
			continue
		var land_h: float = (cell.elevation - cfg.sea_level) * inv_above_sea
		if land_h > 0.08:
			continue
		var has_ocean_nb: bool = false
		for nb: HexCell in map.get_neighbors(cell):
			if nb.terrain == TerrainType.TERRAIN.OCEAN \
					or nb.terrain == TerrainType.TERRAIN.COAST:
				has_ocean_nb = true
				break
		if not has_ocean_nb:
			continue
		cell.apply_terrain(TerrainType.TERRAIN.DELTA)

# OASIS（绿洲）：原始干旱（base_moisture < 0.30）+ 暖温 + (has_river 或 LAKE 邻居)
# 用 base_moisture 而不是 cell.terrain == DESERT，因为 river_ecology + vegetation_feedback
# 已经把"沙漠中的河"翻成 JUNGLE / SAVANNA / FOREST，让 cell.terrain == DESERT 检查失效
func _apply_oasis_pass(map: MapData, cfg: MapConfig) -> void:
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		if _is_permanent_landform(cell.terrain):
			continue
		# 永久 biome（山地 / 雪 / 冻原）不会变绿洲
		if cell.terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.terrain == TerrainType.TERRAIN.SNOW \
				or cell.terrain == TerrainType.TERRAIN.TUNDRA \
				or cell.terrain == TerrainType.TERRAIN.GLACIER:
			continue
		# 必须原始干旱（rain shadow 之后）
		if cell.base_moisture > 0.30:
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp: float = _compute_temperature(ny, cell.elevation)
		# 暖温带 + 热带（温度 > 0.40），避免冷沙漠误判
		if temp < 0.40:
			continue
		var has_water: bool = cell.has_river
		if not has_water:
			for nb: HexCell in map.get_neighbors(cell):
				if nb.terrain == TerrainType.TERRAIN.LAKE:
					has_water = true
					break
		if not has_water:
			continue
		cell.moisture = maxf(cell.moisture, 0.55)
		cell.apply_terrain(TerrainType.TERRAIN.OASIS)

# SALT_FLAT（盐沼 / 盐滩）：DESERT + 极低海拔 + 内陆（远离水）
# 触发：DESERT + land_h < 0.12 + r=2 范围内没有 has_river 或水体邻居
func _apply_salt_flat_pass(map: MapData, cfg: MapConfig) -> void:
	var inv_above_sea := 1.0 / maxf(1.0 - cfg.sea_level, 0.001)
	for cell: HexCell in map.all_cells():
		if cell.terrain != TerrainType.TERRAIN.DESERT:
			continue
		var land_h: float = (cell.elevation - cfg.sea_level) * inv_above_sea
		if land_h > 0.12:
			continue
		# 检查 r=2：no river anywhere, no water cell anywhere
		var endorheic: bool = true
		if cell.has_river:
			endorheic = false
		else:
			# 1-ring 检查（r=1）
			for nb: HexCell in map.get_neighbors(cell):
				if nb.has_river or _is_water(nb.terrain):
					endorheic = false
					break
		if not endorheic:
			continue
		cell.apply_terrain(TerrainType.TERRAIN.SALT_FLAT)

# BADLANDS（荒原 / 峡谷）：DESERT + 高 elevation variance + 不在低洼盐沼
# 触发：DESERT + relief（邻居高度标准差） > 阈值
func _apply_badlands_pass(map: MapData, cfg: MapConfig) -> void:
	const BADLANDS_RELIEF_THRESHOLD := 0.025
	for cell: HexCell in map.all_cells():
		if cell.terrain != TerrainType.TERRAIN.DESERT:
			continue
		# relief = max - min of cell + neighbors elevation
		var max_e: float = cell.elevation
		var min_e: float = cell.elevation
		for nb: HexCell in map.get_neighbors(cell):
			if nb.elevation > max_e:
				max_e = nb.elevation
			if nb.elevation < min_e:
				min_e = nb.elevation
		var relief: float = max_e - min_e
		if relief < BADLANDS_RELIEF_THRESHOLD:
			continue
		cell.apply_terrain(TerrainType.TERRAIN.BADLANDS)

# GLACIER（冰川）
# 触发条件之一：
#   A) 极冷沿海冰舌：temp < 0.10 + land_h < 0.20 + COAST/OCEAN 邻居
#   B) 高山冰川：land_h > 0.55 + temp < 0.10（替代 SNOW 在山腰部分）
# 既能生成两极海岸冰盖，也能延伸到高山冰川舌
func _apply_glacier_pass(map: MapData, cfg: MapConfig) -> void:
	var inv_above_sea := 1.0 / maxf(1.0 - cfg.sea_level, 0.001)
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		# 只替换 SNOW / TUNDRA（既然它们已经是冷区分类）
		# 不替换 MOUNTAIN（避免高山秃岩全变冰）
		var t := int(cell.terrain)
		if t != TerrainType.TERRAIN.SNOW and t != TerrainType.TERRAIN.TUNDRA:
			continue
		var land_h: float = (cell.elevation - cfg.sea_level) * inv_above_sea
		var ny: float = _cube_row_norm(cell, cfg)
		var temp: float = _compute_temperature(ny, cell.elevation)
		if temp >= 0.10:
			continue
		# A) 沿海冰舌（OCEAN/COAST/SEA_ICE 都算海洋邻居）
		var coastal_glacier: bool = false
		if land_h < 0.20:
			for nb: HexCell in map.get_neighbors(cell):
				if nb.terrain == TerrainType.TERRAIN.OCEAN \
						or nb.terrain == TerrainType.TERRAIN.COAST \
						or nb.terrain == TerrainType.TERRAIN.SEA_ICE:
					coastal_glacier = true
					break
		# B) 高山冰川
		var alpine_glacier: bool = land_h > 0.55
		if not (coastal_glacier or alpine_glacier):
			continue
		cell.apply_terrain(TerrainType.TERRAIN.GLACIER)

# 沿岸补偿：陆地 cell 紧贴水域 → 湿度提升；远离海岸的内陆相对降低
func _apply_coastal_moisture_boost(map: MapData) -> void:
	# 每个陆地 cell 检查 6 个邻居：有几个是水域
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var water_nbs: int = 0
		var total_nbs: int = 0
		for nb: HexCell in map.get_neighbors(cell):
			total_nbs += 1
			if _is_water(nb.terrain):
				water_nbs += 1
		if total_nbs == 0:
			continue
		var coastal_ratio: float = float(water_nbs) / float(total_nbs)
		# 1 个相邻水 ≈ 海岸，加 +0.1；3 个相邻水 ≈ 半岛，加 +0.20
		cell.moisture = clampf(cell.moisture + coastal_ratio * _c().coastal_moisture_boost, 0.0, 1.0)

# ─── 地形决策（v8 阈值定调） ────────────────────────────────────────────
#
# 决策树先按 elevation 分类（OCEAN/COAST/MOUNTAIN/HILL），剩下的低地按
# (temperature, moisture) 在 Whittaker 风格的二维空间里选择 biome。
#
# v8 的 ridge boost + slope_gate 让中海拔 cell 也能升级 MOUNTAIN，所以
# MOUNTAIN 阈值保持 0.52，配合双向脊线就能产生山脉链。HILL 阈值 0.30
# 让山脚有充足过渡区。

func _decide_terrain(elevation: float, temperature: float, moisture: float, cfg: MapConfig) -> TerrainType.TERRAIN:
	if elevation < cfg.sea_level - 0.06:
		return TerrainType.TERRAIN.OCEAN
	if elevation < cfg.sea_level:
		return TerrainType.TERRAIN.COAST

	var land_height: float = (elevation - cfg.sea_level) / (1.0 - cfg.sea_level)

	# ─── 海拔/极地优先（不论温度湿度）───────────────────────────────────
	# v10.6：三档 SNOW 判定
	const SNOW_LINE := 0.82
	const COLD_SNOW_LINE := 0.40
	if land_height > SNOW_LINE:
		return TerrainType.TERRAIN.SNOW
	if land_height > COLD_SNOW_LINE and temperature < 0.13:
		return TerrainType.TERRAIN.SNOW
	if temperature < 0.06:
		return TerrainType.TERRAIN.SNOW
	# 山地（0.62 < land_h ≤ 0.82）
	if land_height > 0.62:
		return TerrainType.TERRAIN.MOUNTAIN
	# 寒带（任何海拔）→ TUNDRA（含 land_h > 0.22 的冷区，避免冷高地误判 HILL）
	if temperature < 0.20:
		return TerrainType.TERRAIN.TUNDRA
	# 丘陵：HILL 优先于 biome 分类（除非已经是冷区）
	if land_height > 0.22:
		return TerrainType.TERRAIN.HILL

	# ─── Phase 10：Whittaker 双层决策（温度 → 湿度）─────────────────────
	# 温度区间分流；每区间内按湿度三段切。阈值刻意有 overlap 缓冲
	# 让边界 biome 不死板。

	# 热带（temperature > 0.55）
	if temperature > 0.55:
		if moisture > 0.65:
			return TerrainType.TERRAIN.JUNGLE     # 热带雨林
		if moisture > 0.30:
			return TerrainType.TERRAIN.SAVANNA    # 稀树草原
		return TerrainType.TERRAIN.DESERT         # 热带沙漠

	# 暖温带（0.40 < temperature ≤ 0.55）
	if temperature > 0.40:
		if moisture > 0.55:
			return TerrainType.TERRAIN.FOREST     # 温带阔叶林
		if moisture > 0.30:
			return TerrainType.TERRAIN.GRASSLAND  # 温带草地
		return TerrainType.TERRAIN.STEPPE         # 温带草原（更干）

	# 凉温带（0.20 < temperature ≤ 0.40）
	if temperature > 0.20:
		if moisture > 0.40:
			return TerrainType.TERRAIN.TAIGA      # 针叶林 / 泰加
		if moisture > 0.20:
			return TerrainType.TERRAIN.STEPPE     # 凉草原
		return TerrainType.TERRAIN.DESERT         # 冷沙漠 / 戈壁

	# fallback（temperature ≤ 0.20 已被前面 TUNDRA 接住，理论不到这里）
	return TerrainType.TERRAIN.PLAIN

# ─── Milestone 1：三轴派生（landform / vegetation / cover） ──────────────────
#
# 设计选择：
#   原计划"重写 _apply_*_pass 让 vegetation/cover 成为工作源"风险过高（9 个 pass
#   × 数百分支需要逐一验证）。改为更安全的"terrain 在生成期间仍是工作源，
#   三轴在每个生成阶段末尾从 terrain + 上下文派生"。
#
# 收益等价：
#   1) UI 与新代码读 cell.landform / vegetation / cover 是真正的独立轴
#   2) HILL 上不再"压制"植被—— vegetation 看到 cell.terrain == HILL 时
#      会按 (temp, moist) 重新走 Whittaker 决策（_decide_vegetation_for_landform
#      内部分支），输出真实植被
#   3) Phase 8 生态评分切到 vegetation_history（粒度更细）
#   4) M2~M4 的 baker 双通道、Weather 注入、强耦合反馈都基于这套接口扩展

# 三个 enum 是 int，用 LandformType.LF.* 等访问。
# 这些 derive 函数都是 const 函数（无 side effect，仅读 cell 现成属性 + cfg）。

func _derive_landform(cell: HexCell, cfg: MapConfig) -> int:
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
	# 陆地：按 land_h 分段（与原 _decide_terrain 阈值一致）
	var land_h: float = (cell.elevation - cfg.sea_level) / maxf(1.0 - cfg.sea_level, 0.001)
	if land_h > 0.82:
		return LandformType.LF.PEAK
	if land_h > 0.62:
		return LandformType.LF.MOUNTAIN
	if land_h > 0.22:
		return LandformType.LF.HILL
	if land_h > 0.05:
		return LandformType.LF.LOWLAND
	return LandformType.LF.PLAIN

# 给定 (terrain, landform, temperature, moisture)，输出真正的植被身份。
# 关键：当 terrain == HILL / MOUNTAIN 时，不再"植被=丘陵"，而是按 (temp, moist)
# 在 Whittaker 风格的二维空间里选择具体植被（含 ALPINE_* 高山特殊分类）。
func _derive_vegetation(cell: HexCell, landform: int, temperature: float) -> int:
	var t: int = int(cell.terrain)
	# 海水 / 湖水 / 海冰：水面无陆生植被
	if t == TerrainType.TERRAIN.OCEAN or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.LAKE or t == TerrainType.TERRAIN.SEA_ICE:
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
	if t == TerrainType.TERRAIN.SWAMP:
		return VegetationType.VEG.SWAMP
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
		return _whittaker_vegetation(temperature, cell.moisture, landform)
	# Phase 10 Whittaker 命中：FOREST/JUNGLE/SAVANNA/GRASSLAND/STEPPE/DESERT
	match t:
		TerrainType.TERRAIN.FOREST:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			if temperature > 0.55:
				return VegetationType.VEG.SUBTROPICAL_FOREST
			return VegetationType.VEG.TEMPERATE_DECIDUOUS
		TerrainType.TERRAIN.JUNGLE:
			# 极湿 → 雨林；中湿 → 季雨林
			if cell.moisture > 0.70:
				return VegetationType.VEG.TROPICAL_RAINFOREST
			return VegetationType.VEG.TROPICAL_DRY_FOREST
		TerrainType.TERRAIN.SAVANNA:
			return VegetationType.VEG.SAVANNA
		TerrainType.TERRAIN.GRASSLAND:
			if is_alpine:
				return VegetationType.VEG.ALPINE_MEADOW
			return VegetationType.VEG.TEMPERATE_GRASSLAND
		TerrainType.TERRAIN.STEPPE:
			return VegetationType.VEG.TEMPERATE_STEPPE
		TerrainType.TERRAIN.DESERT:
			# 极旱 → XERIC_DESERT；普通 → DESERT_SCRUB
			if cell.moisture < 0.10:
				return VegetationType.VEG.XERIC_DESERT
			return VegetationType.VEG.DESERT_SCRUB
		_:
			return _whittaker_vegetation(temperature, cell.moisture, landform)

# Whittaker 风格的(temperature, moisture)→vegetation 决策
# 用于 _derive_vegetation 内部"无明确植被身份的 terrain"（HILL/PLAIN/MOUNTAIN）
func _whittaker_vegetation(temperature: float, moisture: float, landform: int) -> int:
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
		return VegetationType.VEG.TEMPERATE_STEPPE
	# 暖温带
	if temperature < 0.55:
		if moisture > 0.55:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			if is_hilly:
				return VegetationType.VEG.TEMPERATE_DECIDUOUS
			return VegetationType.VEG.TEMPERATE_DECIDUOUS
		if moisture > 0.30:
			if is_alpine:
				return VegetationType.VEG.ALPINE_MEADOW
			return VegetationType.VEG.TEMPERATE_GRASSLAND
		return VegetationType.VEG.TEMPERATE_STEPPE
	# 热带
	if moisture > 0.65:
		return VegetationType.VEG.TROPICAL_RAINFOREST
	if moisture > 0.40:
		return VegetationType.VEG.TROPICAL_DRY_FOREST
	if moisture > 0.20:
		return VegetationType.VEG.SAVANNA
	if moisture < 0.10:
		return VegetationType.VEG.XERIC_DESERT
	return VegetationType.VEG.DESERT_SCRUB

# 覆盖物（cover）派生：永久冰 → GLACIER / 海冰 → SEA_ICE / 季节雪盖 → SNOW
# 苔原下层默认 PERMAFROST（永久冻土）
func _derive_cover(cell: HexCell, snow_cover: float) -> int:
	var t: int = int(cell.terrain)
	if t == TerrainType.TERRAIN.GLACIER:
		return CoverType.CV.GLACIER
	if t == TerrainType.TERRAIN.SEA_ICE:
		return CoverType.CV.SEA_ICE
	if t == TerrainType.TERRAIN.SNOW:
		return CoverType.CV.SNOW
	# 季节性雪盖（陆地，由 refresh_seasonal 算出 snow_cover ∈ [0, 1]）
	if snow_cover > 0.5 and not _is_water(t):
		return CoverType.CV.SNOW
	# 苔原默认下层永冻土（这是地理事实，不是季节性）
	if t == TerrainType.TERRAIN.TUNDRA:
		return CoverType.CV.PERMAFROST
	return CoverType.CV.NONE

# 单 cell 同步三轴。生成期间用 snow_cover=0（默认夏季）；refresh_seasonal 内传当季 snow_cover。
func _sync_axes_for_cell(cell: HexCell, cfg: MapConfig, snow_cover: float) -> void:
	var landform := _derive_landform(cell, cfg)
	var ny: float = _cube_row_norm(cell, cfg)
	var temp: float = _compute_temperature(ny, cell.elevation)
	cell.landform = landform
	cell.vegetation = _derive_vegetation(cell, landform, temp)
	cell.cover = _derive_cover(cell, snow_cover)

# 全图同步（生成结束后调用一次，snow_cover=0）
func _sync_axes_for_map(map: MapData, cfg: MapConfig) -> void:
	for cell: HexCell in map.all_cells():
		_sync_axes_for_cell(cell, cfg, 0.0)

# ─── 河流：Flow Accumulation（汇流累积） ─────────────────────────────────
#
# 算法：
#   1) 收集所有 land cell 并按海拔从高到低排序
#   2) 每个 land cell 找它的下坡邻居 (downhill_dir)，没有则 null（局部最低点）
#   3) 初始流量 = rainfall（湿度调制）
#   4) 按高→低顺序遍历，把每个 cell 的累积流量加给它的下坡邻居
#   5) 流量分位 >= percentile 的 cell 标 has_river
#   6) 过滤孤立的 river cell（无上下游 river 邻居）

func _generate_rivers_flow_accumulation(map: MapData, cfg: MapConfig) -> void:
	var land_cells: Array = []
	for cell: HexCell in map.all_cells():
		if not _is_water(cell.terrain):
			land_cells.append(cell)
	if land_cells.is_empty():
		return

	# 海拔从高到低排序，保证流量传递时 upstream 先于 downstream
	land_cells.sort_custom(func(a: HexCell, b: HexCell) -> bool: return a.elevation > b.elevation)

	# 1. 每个 land cell 找下坡邻居
	var downhill: Dictionary = {}
	for cell: HexCell in land_cells:
		var lowest_nb: HexCell = null
		var lowest_elev: float = cell.elevation
		for nb: HexCell in map.get_neighbors(cell):
			if nb.elevation < lowest_elev:
				lowest_elev = nb.elevation
				lowest_nb = nb
		if lowest_nb != null:
			downhill[Vector3i(cell.q, cell.r, cell.s)] = lowest_nb

	# 2. 初始 rainfall（湿度调制 + v10 山地正雨）
	# 基础值 = lerp(0.4, 1.6, cell.moisture)：干 0.4，湿 1.6
	# 正雨加成：高于 sea_level 0.30 的 land_h 开始按 OROGRAPHIC_BOOST 倍增
	# 例 land_h=0.50 boost=1.30；land_h=0.80 boost=1.75（OROGRAPHIC_BOOST=1.5 时）
	# 这给上游山地额外的"头部流量"，长河更容易出现
	var flow: Dictionary = {}
	var inv_above_sea := 1.0 / maxf(1.0 - cfg.sea_level, 0.001)
	for cell: HexCell in land_cells:
		var key := Vector3i(cell.q, cell.r, cell.s)
		var base_rain: float = lerpf(0.4, 1.6, cell.moisture)
		var land_h: float = (cell.elevation - cfg.sea_level) * inv_above_sea
		var orographic: float = 1.0 + maxf(land_h - 0.30, 0.0) * _c().orographic_boost
		flow[key] = base_rain * orographic

	# 3. 按高→低累积流量
	for cell: HexCell in land_cells:
		var key := Vector3i(cell.q, cell.r, cell.s)
		var dh: HexCell = downhill.get(key, null)
		if dh == null:
			continue  # 局部洼地：流量止于此
		var dh_key := Vector3i(dh.q, dh.r, dh.s)
		var src_flow: float = float(flow.get(key, 0.0))
		# 下坡邻居如果是水域，不再累积（流量入海）
		if _is_water(dh.terrain):
			continue
		flow[dh_key] = float(flow.get(dh_key, 0.0)) + src_flow

	# 4. 计算分位阈值：top (1 - percentile) 的 cell 成为河流
	var flow_values: Array = []
	for v in flow.values():
		flow_values.append(float(v))
	flow_values.sort()  # 升序
	if flow_values.is_empty():
		return
	var threshold_idx: int = int(float(flow_values.size()) * _c().river_flow_percentile)
	threshold_idx = clampi(threshold_idx, 0, flow_values.size() - 1)
	var threshold: float = float(flow_values[threshold_idx])

	# 5. 标 has_river
	for cell: HexCell in land_cells:
		var key := Vector3i(cell.q, cell.r, cell.s)
		if float(flow.get(key, 0.0)) >= threshold:
			cell.has_river = true

	# 6. 过滤：必须能下坡到达水（否则是断头沟）
	_filter_dead_end_rivers(map, downhill)

	# 7. 过滤：单点孤立 river（无相邻 river/water）
	_filter_isolated_rivers(map)

# 检查每条 river chain 能否经下坡链达到水域；不能的 unmark
func _filter_dead_end_rivers(map: MapData, downhill: Dictionary) -> void:
	var reach_water_cache: Dictionary = {}  # cube_key -> bool

	# 内联递归不太行，用迭代+缓存
	var cells_to_check: Array = []
	for cell: HexCell in map.all_cells():
		if cell.has_river and not _is_water(cell.terrain):
			cells_to_check.append(cell)

	for cell: HexCell in cells_to_check:
		var visited: Dictionary = {}
		var current: HexCell = cell
		var max_steps: int = 200
		var reached: bool = false
		for _i in range(max_steps):
			var key := Vector3i(current.q, current.r, current.s)
			if reach_water_cache.has(key):
				reached = bool(reach_water_cache[key])
				break
			if visited.has(key):
				break
			visited[key] = true
			if _is_water(current.terrain):
				reached = true
				break
			var dh: HexCell = downhill.get(key, null)
			if dh == null:
				break
			current = dh
		# 沿路径回填 cache
		for k in visited:
			reach_water_cache[k] = reached
		if not reached:
			cell.has_river = false

func _filter_isolated_rivers(map: MapData) -> void:
	# 单 cell 的 river 若四周没有任何 river/water 邻居，去掉
	var to_unmark: Array = []
	for cell: HexCell in map.all_cells():
		if not cell.has_river:
			continue
		var has_river_or_water_nb: bool = false
		for nb: HexCell in map.get_neighbors(cell):
			if nb.has_river or _is_water(nb.terrain):
				has_river_or_water_nb = true
				break
		if not has_river_or_water_nb:
			to_unmark.append(cell)
	for cell: HexCell in to_unmark:
		cell.has_river = false

# ─── 工具 ────────────────────────────────────────────────────────────────

# 任务 7：把 MapBaker 烤好的 per-pixel 洋流场折返为 per-cell HexCell.ocean_current。
#
# 为什么不直接在 MapGenerator 里重新实现 Ekman/反射算法？
#   - MapBaker._bake_ocean_currents 已经完整实现了"风应力 + Ekman 偏转 + 大陆反射
#     + 噪声扰动"的物理公式，结果就在 world.ocean_current_buffer 里。
#   - 在 hex 中心 sample 一次即可继承全部物理语义；避免两份算法漂移。
#   - MapGenerator 保持纯逻辑层身份：此函数不做任何"表现层混入"
#     （关键决策 3：表现层不掺和逻辑层）。
#
# 写入范围：仅水 cell（LF.is_water == true）；陆地 cell 保持 Vector2.ZERO。
# 向量长度即"洋流强度"∈ [0, 1]；方向为水平分量。
func _compute_ocean_currents(map: MapData, world: WorldData, hex_size: float) -> void:
	var t0 := Time.get_ticks_msec()
	var water_count: int = 0
	for cell: HexCell in map.all_cells():
		if cell == null:
			continue
		if not _is_water(cell.terrain):
			cell.ocean_current = Vector2.ZERO
			continue
		var wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, hex_size)
		var cur: Vector2 = world.sample_ocean_current(wp)
		# clamp 长度 ≤ 1（sample 出来理论上就在 [-1,1]×[-1,1] 区间，
		# 极少数对角线位置 length 可能 >1，做个安全裁切）。
		if cur.length() > 1.0:
			cur = cur.normalized()
		cell.ocean_current = cur
		water_count += 1
	print("MapGenerator v7: ocean currents for %d water cells in %dms"
			% [water_count, Time.get_ticks_msec() - t0])

static func _is_water(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.LAKE \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
			or t == TerrainType.TERRAIN.SEA_ICE

# Phase 14：永久性地标 — 一旦设定不被季节 / biome 重决策覆盖。
static func _is_permanent_landform(t: int) -> bool:
	return t == TerrainType.TERRAIN.OASIS \
			or t == TerrainType.TERRAIN.DELTA \
			or t == TerrainType.TERRAIN.SALT_FLAT \
			or t == TerrainType.TERRAIN.BADLANDS

func _cube_to_col(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.x, 0, cfg.width - 1)

func _cube_to_row(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.y, 0, cfg.height - 1)

func _cube_row_norm(cell: HexCell, cfg: MapConfig) -> float:
	return float(_cube_to_row(cell, cfg)) / float(maxi(cfg.height - 1, 1))

# ─── Phase 2：季节刷新（湿度 + 雨影 + 局部 biome 重决策） ───────────────────
# 每次 WorldClock.season_changed 触发。
# 流程：
#   1) cell.moisture := cell.base_moisture × SEASONAL_MOISTURE_SCALE[season]
#   2) 用 SEASONAL_WINDS[season] 当主导风向重跑雨影
#   3) 重新决策非"永久" biome（OCEAN/COAST/MOUNTAIN/SNOW 不动；
#      其他 land cell 按当季 temp + moisture 重选）
#   4) 写入 cell.current_state 给玩法层读取
#   5) baker.rebake_biome_tex_only → 上层 renderer 自动看到新 biome_tex

func refresh_seasonal(map: MapData, world: WorldData, season_idx: int) -> void:
	if _last_cfg == null or _baker == null:
		return
	_current_season = season_idx
	var season := clampi(season_idx, 0, 3)

	# 1) 复位湿度到年均基线（pre-rain-shadow） + 全局季节缩放
	var moist_scale: float = _c().seasonal_moisture_scale[season]
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			cell.moisture = cell.base_moisture
		else:
			cell.moisture = clampf(cell.base_moisture * moist_scale, 0.0, 1.0)

	# 2) 雨影（Phase 6：每 cell 用自己纬度的风向 + 当季的 season_phase 决定季风偏置）
	# season_phase 用季节中段 → spring=0.5 / summer=1.5 / autumn=2.5 / winter=3.5
	_apply_rain_shadow_per_cell(map, _last_cfg, float(season) + 0.5)

	# 3) 重决策"非永久"地形
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var is_permanent_climate := cell.base_terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.base_terrain == TerrainType.TERRAIN.SNOW
		if is_permanent_climate:
			cell.apply_terrain(cell.base_terrain)
			continue
		# Phase 14：永久地标（OASIS/DELTA/SALT_FLAT/BADLANDS）由 base_terrain 还原后保持
		if _is_permanent_landform(cell.base_terrain):
			cell.apply_terrain(cell.base_terrain)
			continue
		var ny: float = _cube_row_norm(cell, _last_cfg)
		var temp_year: float = _compute_temperature(ny, cell.elevation)
		var temp_now: float = clampf(temp_year + _season_temp_offset(ny, season), 0.0, 1.0)
		var new_terrain := _decide_terrain(cell.elevation, temp_now, cell.moisture, _last_cfg)
		cell.apply_terrain(new_terrain)

	# 4) 河岸生态（已有的 _apply_river_ecology 是幂等的：moisture 提升到 0.65 + DESERT/PLAIN 翻转）
	_apply_river_ecology(map, _last_cfg)

	# 4.5) Phase 7：植被反馈（biome 给邻居 ±moisture + 重决策）— 让聚类持续
	_apply_vegetation_feedback(map, _last_cfg)

	# 4.6) Phase 11：过渡生态（每季都重判定，moisture/temperature 随季节变化）
	_apply_shrubland_pass(map, _last_cfg)
	_apply_mangrove_pass(map, _last_cfg)
	_apply_glacier_pass(map, _last_cfg)

	# 4.7) Phase 9：SWAMP 沼泽（在反馈之后判定，每季都重判定，moisture/temperature 随季节变）
	_apply_swamp_pass(map, _last_cfg)

	# 4.8) Phase 12：海冰季节性扩张/退缩（REEF/KELP 是 gen-time 永久，不在每季刷新）
	_apply_sea_ice_pass(map, _last_cfg, season)

	# 5) 写 current_state（玩法层 hook）+ Phase 8：push biome_history / vegetation_history
	# Milestone 1：per-cell 同步 landform / vegetation / cover 三轴，用当季 snow_cover
	for cell: HexCell in map.all_cells():
		var ny2: float = _cube_row_norm(cell, _last_cfg)
		var temp_year2: float = _compute_temperature(ny2, cell.elevation)
		var temp_now2: float = clampf(temp_year2 + _season_temp_offset(ny2, season), 0.0, 1.0)
		var land_h: float = (cell.elevation - _last_cfg.sea_level) / maxf(1.0 - _last_cfg.sea_level, 0.001)
		var snow_cover: float = 0.0
		if not _is_water(cell.terrain):
			if cell.terrain == TerrainType.TERRAIN.SNOW:
				snow_cover = 1.0
			elif temp_now2 < 0.18:
				snow_cover = clampf((0.18 - temp_now2) / 0.14, 0.0, 1.0) * 0.85
			elif land_h > 0.45 and temp_now2 < 0.30:
				var t1 := clampf((0.30 - temp_now2) / 0.20, 0.0, 1.0)
				var t2 := smoothstep(0.45, 0.85, land_h)
				snow_cover = t1 * t2
		# 派生三轴（landform 跨季不变，但 vegetation/cover 会随当季 terrain/snow 变化）
		_sync_axes_for_cell(cell, _last_cfg, snow_cover)
		cell.current_state = {
			"season": season,
			"temperature": temp_now2,
			"moisture": cell.moisture,
			"snow_cover": snow_cover,
			"biome": int(cell.terrain),
			"landform": int(cell.landform),
			"vegetation": int(cell.vegetation),
			"cover": int(cell.cover),
		}
		# Phase 8：环形缓冲记录最近 HexCell.HISTORY_LEN 季
		cell.push_biome_history(int(cell.terrain))
		cell.push_vegetation_history(int(cell.vegetation))

	# 6) 增量重烘焙 biome_tex（其他 buffer 不动）
	if world != null:
		_baker.rebake_biome_tex_only(map, world, _last_hex_size)

# ─── Milestone 3：天气子系统每日推进 ────────────────────────────────────
# 由 main.gd 的 _on_day_changed 触发。流程：
#   1) WeatherSystem.tick_one_day：advect 现有 front + spawn 新 front + 写 cell.current_state.weather/intensity
#   2) 同时把 weather 的 moisture/temp 扰动叠加到 current_state.moisture/temperature（不改 base_*）
#   3) 必要时改写 cell.cover（BLIZZARD → SNOW、STORM/MONSOON 低地 → FLOODING）
#   4) 不重烘焙任何 tex（视觉层 weather overlay 走 shader uniform 数组路径，零 tex 上传）
# 返回当前活跃 front 列表，main 拿去喂 renderer。
func refresh_daily(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> Array[WeatherFront]:
	if _weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	# 1) 推进天气子系统（写 weather/intensity，必要时改写 cover）
	var fronts := _weather_system.tick_one_day(map, world, season_idx, climate_anomaly)
	# 2) Milestone 4：完整耦合反馈链（按因果顺序，前一 pass 的输出是后一 pass 的输入）
	#    transpiration → albedo → vegetation_dynamics → succession_trigger
	_apply_transpiration_pass(map)
	_apply_albedo_pass(map)
	var vegetation_dirty := _apply_vegetation_dynamics(map)
	# 3) 增量重烘 GPU tex：分别看 cover 与 vegetation 是否被 dirty
	if _baker != null:
		if _weather_system.has_cover_dirty():
			_baker.rebake_cover_tex_only(map, world, _last_hex_size)
		if vegetation_dirty:
			_baker.rebake_vegetation_tex_only(map, world, _last_hex_size)
	return fronts

# 给 UI / renderer 直接拿到当前天气快照（不触发 tick）
func active_weather_fronts() -> Array[WeatherFront]:
	if _weather_system == null:
		return [] as Array[WeatherFront]
	return _weather_system.active_fronts()

# ─── Milestone 4：完整耦合反馈 ───────────────────────────────────────────
# 三个 pass + 一个演替触发，按"植被影响气候 → 气候反过来评估植被适应性 → 长期不适应触发演替"的因果序排列。
#
# 设计原则：
#   - 三个 pass 全部只动 cell.current_state 与 cell.vegetation_vitality / streak 计数器，
#     不写 base_moisture / base_temperature / base_vegetation。base_* 仅由 refresh_seasonal /
#     refresh_yearly 缓慢漂移；M4 反馈是"日尺度"的快变扰动。
#   - 蒸腾外溢只在陆地 cell 之间扩散（海面 / 冰川不参与）。
#   - 反照率只在陆地 cell 上调整温度（海洋温度由洋流体系决定，M4 不动）。
#   - 演替触发后立即写 cell.vegetation 并刷 base_vegetation，让玩家在 panel 看到"演替已发生"。

# Pass 1：蒸腾外溢。每个陆地 cell 把自己 transpiration × current_moisture 的一部分，
# 平均分给 6 个邻居 + 自己。所有写入做完后再统一应用，避免顺序耦合。
# const TRANSPIRATION_OUTFLOW_RATE (migrated to ClimateProfile.transpiration_outflow_rate)   # 每天最多 2.5% moisture 外溢给邻居
# const TRANSPIRATION_SELF_RATE (migrated to ClimateProfile.transpiration_self_rate)      # 每天最多 1.5% moisture 留给自己（蒸腾闭环）
func _apply_transpiration_pass(map: MapData) -> void:
	# 阶段 1：算每 cell 的"输出额"（不立刻写）
	var deltas: Dictionary = {}  # cell.cube → float
	for cell: HexCell in map.all_cells():
		if LandformType.is_water(cell.landform):
			continue
		var trans: float = VegetationType.transpiration(cell.vegetation)
		if trans < 0.01:
			continue
		var moist: float = float(cell.current_state.get("moisture", cell.moisture))
		# 强烈 transpiration（雨林）+ 高湿度 → 大额输出；干旱 cell 输出微弱
		var output: float = trans * moist
		var self_share: float = output * _c().transpiration_self_rate
		var nb_share: float = output * _c().transpiration_outflow_rate / 6.0
		var key_self := Vector3i(cell.q, cell.r, cell.s)
		deltas[key_self] = float(deltas.get(key_self, 0.0)) + self_share
		for nb: HexCell in map.get_neighbors(cell):
			# 海面邻居不接受陆地蒸腾外溢（避免给海加湿）
			if LandformType.is_water(nb.landform):
				continue
			var key_nb := Vector3i(nb.q, nb.r, nb.s)
			deltas[key_nb] = float(deltas.get(key_nb, 0.0)) + nb_share
	# 阶段 2：把所有 delta 应用到 current_state.moisture（一次性，避免顺序敏感）
	for cell: HexCell in map.all_cells():
		var key := Vector3i(cell.q, cell.r, cell.s)
		var d: float = float(deltas.get(key, 0.0))
		if d == 0.0:
			continue
		var moist_now: float = float(cell.current_state.get("moisture", cell.moisture))
		cell.current_state["moisture"] = clampf(moist_now + d, 0.0, 1.0)

# Pass 2：反照率反馈。植被反照率高（雪、沙漠）→ 反射阳光 → 局地温度下降；
# 反照率低（深色森林、湿地）→ 吸收阳光 → 局地温度上升。
# 公式：Δtemp = (REFERENCE_ALBEDO - albedo) × ALBEDO_TEMP_GAIN
# REFERENCE_ALBEDO=0.30 是中性参考（无植被裸地）。雨林 albedo=0.10 → +0.005 / day。
# const REFERENCE_ALBEDO (migrated to ClimateProfile.reference_albedo)
# const ALBEDO_TEMP_GAIN (migrated to ClimateProfile.albedo_temp_gain)  # 每"日"最大 ±0.005 温度调制
func _apply_albedo_pass(map: MapData) -> void:
	for cell: HexCell in map.all_cells():
		if LandformType.is_water(cell.landform):
			continue
		var alb: float = VegetationType.albedo(cell.vegetation)
		# 覆盖物 SNOW / GLACIER 主导反照率（白色高反照率覆盖会盖过下面的植被）
		if cell.cover == CoverType.CV.SNOW or cell.cover == CoverType.CV.GLACIER:
			alb = maxf(alb, 0.75)
		var dt: float = (_c().reference_albedo - alb) * _c().albedo_temp_gain
		var temp_now: float = float(cell.current_state.get("temperature", 0.5))
		cell.current_state["temperature"] = clampf(temp_now + dt, 0.0, 1.0)

# Pass 3：植被生命值动力学 + 演替触发。
# vitality 每日按 climate_compat_score 的差异调整；streak 计数器累计连续超阈天数；
# 满足条件即触发演替（写新 vegetation + reset streak + 快照 base_vegetation）。
# 返回值 = 是否有任何 cell 的 vegetation 被改写（vegetation_tex 是否需要 rebake）。
# const VITALITY_CHANGE_RATE (migrated to ClimateProfile.vitality_change_rate)         # 每"日"最多 ±0.02 变化（≈ 50 天即可从 0 到 1）
# const VITALITY_LOW_THRESHOLD (migrated to ClimateProfile.vitality_low_threshold)       # 低于该值开始累计退化 streak
# const VITALITY_HIGH_THRESHOLD (migrated to ClimateProfile.vitality_high_threshold)      # 高于该值开始累计升级 streak
# const SUCCESSION_DEGRADE_DAYS (migrated to ClimateProfile.succession_degrade_days)        # 退化所需连续不适应天数（~1 季）
# const SUCCESSION_UPGRADE_DAYS (migrated to ClimateProfile.succession_upgrade_days)        # 升级所需连续优适应天数（~半年）
const WEATHER_VITALITY_PENALTY: Dictionary = {
	# 不在 dict 中 = 0 惩罚；在 dict 中 = 当 weather_intensity=1 时每天额外 vitality 损失
	# vegetation-survival-rebalance（方案 A）：整体缩放到原值的 40%，并由植被抗性（方案 C）进一步差异化。
	WeatherType.WT.DROUGHT:  0.012,   # 旱灾对所有植被都是重打击（抗旱植被由 _WEATHER_RESISTANCE 抵消）
	WeatherType.WT.BLIZZARD: 0.005,   # 暴风雪伤害温带 / 热带植被
	WeatherType.WT.HEATWAVE: 0.007,   # 热浪伤害寒带植被
	WeatherType.WT.STORM:    0.002,   # 雷暴轻微伤害（树木倒伏）
	WeatherType.WT.MONSOON:  0.002,
}
func _apply_vegetation_dynamics(map: MapData) -> bool:
	var any_changed: bool = false
	for cell: HexCell in map.all_cells():
		if LandformType.is_water(cell.landform):
			continue
		if cell.vegetation == VegetationType.VEG.NONE:
			# NONE 也参与演替（先驱阶段：从 NONE 慢慢演替到 DESERT_SCRUB → STEPPE → ...）
			pass
		var temp: float = float(cell.current_state.get("temperature", 0.5))
		var moist: float = float(cell.current_state.get("moisture", cell.moisture))
		var compat: float = VegetationType.climate_compat_score(cell.vegetation, temp, moist)
		# vegetation-survival-rebalance 方案 B：非对称漂移 + 中性死区。
		#   compat ≥ 0.6 → 正向恢复（原公式）
		#   compat ≤ 0.4 → 负向退化，乘 COMPAT_HARSHNESS
		#   compat ∈ (0.4, 0.6) → 死区 dv = 0（由天气惩罚单独处理）
		# 另外：NONE 跳过基础漂移（NONE 不自然衰减，只靠 streak 升级）
		var dv: float = 0.0
		if cell.vegetation != VegetationType.VEG.NONE:
			var rate: float = _c().vitality_change_rate
			if compat >= 0.6:
				dv = (compat - 0.5) * 2.0 * rate
			elif compat <= 0.4:
				dv = -(0.5 - compat) * 2.0 * rate * _c().compat_harshness
			# else: 死区保持 dv = 0
		# weather 额外惩罚（方案 C：按植被抗性缩放 penalty *= (1 - resistance)）
		var wt: int = int(cell.current_state.get("weather", WeatherType.WT.CLEAR))
		var wi: float = float(cell.current_state.get("weather_intensity", 0.0))
		var base_penalty: float = float(WEATHER_VITALITY_PENALTY.get(wt, 0.0))
		var resistance: float = VegetationType.weather_resistance(int(cell.vegetation), wt)
		var penalty: float = base_penalty * wi * (1.0 - resistance)
		dv -= penalty
		cell.vegetation_vitality = clampf(cell.vegetation_vitality + dv, 0.0, 1.0)

		# Streak 计数：连续多少天处于演替触发区间
		if cell.vegetation_vitality < _c().vitality_low_threshold:
			cell._vitality_low_streak += 1
			cell._vitality_high_streak = 0
		elif cell.vegetation_vitality > _c().vitality_high_threshold:
			cell._vitality_high_streak += 1
			cell._vitality_low_streak = 0
		else:
			# 中性区间：streak 缓慢清零（避免极端事件遗留计数）
			cell._vitality_low_streak = maxi(cell._vitality_low_streak - 1, 0)
			cell._vitality_high_streak = maxi(cell._vitality_high_streak - 1, 0)

		# 触发演替
		if _trigger_succession(cell):
			any_changed = true
	return any_changed

# 演替触发判定：streak 达到阈值且有可演替的下一阶 → 写 cell.vegetation 并 reset。
# 返回值 = 是否实际发生了演替。
func _trigger_succession(cell: HexCell) -> bool:
	# 退化优先（连续不适应更紧迫）
	if cell._vitality_low_streak >= _c().succession_degrade_days:
		var next_h: int = VegetationType.next_in_succession(cell.vegetation, -1)
		if next_h != cell.vegetation:
			cell.vegetation = next_h
			cell.base_vegetation = next_h          # 演替后基线也跟着前进
			# vegetation-survival-rebalance 需求 4：退化起点从 0.5 提升到 0.65，
			# 远离 VITALITY_LOW_THRESHOLD（0.20）给新植被足够适应缓冲期，防连锁死亡。
			cell.vegetation_vitality = 0.65
			cell._vitality_low_streak = 0
			cell._vitality_high_streak = 0
			cell.current_state["vegetation"] = int(cell.vegetation)
			return true
		# 没有下家：把 streak 清零防止反复触发
		cell._vitality_low_streak = 0
		return false
	if cell._vitality_high_streak >= _c().succession_upgrade_days:
		var next_r: int = VegetationType.next_in_succession(cell.vegetation, 1)
		if next_r != cell.vegetation:
			cell.vegetation = next_r
			cell.base_vegetation = next_r
			cell.vegetation_vitality = 0.7
			cell._vitality_low_streak = 0
			cell._vitality_high_streak = 0
			cell.current_state["vegetation"] = int(cell.vegetation)
			return true
		cell._vitality_high_streak = 0
		return false
	return false

# ─── Phase 8：年度生态记忆漂移 ────────────────────────────────────────────
# 现实里持续多年的森林会让土壤有机质变厚 → 保水更好 → base_moisture 提升；
# 持续多年沙漠化会让土壤板结 → base_moisture 下降。
# 每年 WorldClock.year_changed 触发一次。这是慢漂移，不立即重烘焙；
# 影响下一次 refresh_seasonal 的起点。
#
# Score 机制：
#   FOREST/SWAMP 在 history 中占比 → 正贡献
#   DESERT 在 history 中占比 → 负贡献
#   其他 biome 中性
# Score ∈ [-1, +1]；漂移幅度按 ECO_DRIFT_AMP 缩放。
# const ECO_DRIFT_AMP (migrated to ClimateProfile.eco_drift_amp)  # 一年最大漂 ±0.012 base_moisture
# const ECO_SCORE_CLAMP (migrated to ClimateProfile.eco_score_clamp)  # 平稳期不会全速漂

func refresh_yearly(map: MapData, _world: WorldData) -> void:
	if _last_cfg == null:
		return
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		# 永久 biome 不参与生态漂移（雪山土壤本来就稳定）
		if cell.base_terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.base_terrain == TerrainType.TERRAIN.SNOW:
			continue
		# Milestone 1：评分换源到 vegetation_history（粒度更细，与真实植被绑定）
		# 若 vegetation_history 还没攒够（新地图前几季），fallback 到 biome_history 老评分
		var score: float = 0.0
		if cell.vegetation_history.is_empty():
			score = _ecosystem_score(cell.biome_history)
		else:
			score = _ecosystem_score_vegetation(cell.vegetation_history)
		# clamp 让平稳期漂得更慢
		var eco_clamp: float = _c().eco_score_clamp
		score = clampf(score, -eco_clamp, eco_clamp) / eco_clamp
		cell.base_moisture = clampf(cell.base_moisture + score * _c().eco_drift_amp, 0.0, 1.0)

# Milestone 1：基于 VegetationType.eco_score 表的细粒度评分。
# RAINFOREST/SUBTROPICAL_FOREST > FOREST/MANGROVE/SWAMP > GRASSLAND/SAVANNA >
# STEPPE/SHRUB > DESERT_SCRUB/XERIC_DESERT 负分。详见 vegetation_type.gd。
func _ecosystem_score_vegetation(history: PackedByteArray) -> float:
	if history.is_empty():
		return 0.0
	var n: int = history.size()
	var total: float = 0.0
	for i in range(n):
		total += VegetationType.eco_score(int(history[i]))
	return total / float(n)

# 老 biome_history 评分（M1 fallback / 兼容）：FOREST/SWAMP/JUNGLE/TAIGA 正分；DESERT 负分。
func _ecosystem_score(history: PackedByteArray) -> float:
	if history.is_empty():
		return 0.0
	var n: int = history.size()
	var positive: float = 0.0
	var negative: float = 0.0
	for i in range(n):
		var b: int = int(history[i])
		match b:
			TerrainType.TERRAIN.FOREST:    positive += 1.0
			TerrainType.TERRAIN.JUNGLE:    positive += 1.2
			TerrainType.TERRAIN.SWAMP:     positive += 1.0
			TerrainType.TERRAIN.TAIGA:     positive += 0.8
			TerrainType.TERRAIN.GRASSLAND: positive += 0.5
			TerrainType.TERRAIN.SAVANNA:   positive += 0.4
			TerrainType.TERRAIN.STEPPE:    negative += 0.3
			TerrainType.TERRAIN.DESERT:    negative += 1.0
	return (positive - negative) / float(n)

# 季节温度偏移：与 shader 端 hemi_phase + season_temp_offset 同公式（保证 GDScript / GLSL 视觉一致）。
# ny ∈ [0, 1]：0 = 北极，0.5 = 赤道，1 = 南极。
# season_phase 用整数中点（0.5 / 1.5 / 2.5 / 3.5）做"季节中段"评估。
func _season_temp_offset(ny: float, season: int) -> float:
	# 北/南半球反相
	var lat_signed: float = (ny - 0.5) * 2.0
	var phase: float = float(season) + 0.5  # 取季节中段（spring 中段 = 0.5）
	if lat_signed < 0.0:
		phase = fposmod(phase + 2.0, 4.0)
	# season_temp_amp 与 shader 端默认 0.20 同步
	return cos((phase - 1.0) * 0.5 * PI) * 0.20
