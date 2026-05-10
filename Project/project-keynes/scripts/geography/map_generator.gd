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
# v11 Terrain ↔ Moisture coupling — 把地形对水汽循环的四条窄通路补强：
#   1) 雨影 _apply_rain_shadow_per_cell 通过新增 _pick_upwind_dir 优先采用
#      cell.wind_vector（地形扰动后实际风），让山脉绕流后的真实风向决定背风面位置
#   2) 新增 _apply_orographic_moisture_boost：迎风山坡按
#      boost = 1 + max(land_h-0.30, 0) × orographic_boost 增益 cell.moisture，
#      与 _compute_river_flow 同源；调用顺序为 base → coastal → orographic →
#      base_moisture snapshot → rain_shadow（保证地形决定的"不变量"进入 base）
#   3) WeatherSystem._sample_terrain_wind 让 advect / spawn 优先采样
#      cell.wind_vector，由 ClimateProfile.weather_advect_use_wind_vector 控制
#   4) _apply_vegetation_feedback 按 donor cell 海拔衰减贡献：
#      effective_donor = donor × clampf(1 - elevation × veg_feedback_elev_decay, 0.1, 1.0)
#   新增 ClimateProfile 字段：weather_advect_use_wind_vector(bool, 默认 true)、
#   veg_feedback_elev_decay(float, 默认 0.5)；orographic_boost==0 / 衰减==0
#   时各 pass 等价 no-op，保留旧 profile 兼容性。
#
# 流程：generate → _generate_cells（per-cell 玩法层数据） → MapBaker.bake_world（高分辨率视觉烘焙）
#
# ═══════════════════════════════════════════════════════════════════════
# Emergent Climate Coupling — 字段分类与调用顺序契约（Phase E）
# ═══════════════════════════════════════════════════════════════════════
#
# 项目通过"软分层 + 调用顺序契约"实现快慢双时间尺度的气候模拟。
# 字段按更新尺度划分为三类，禁止快层 pass 直接写慢层：
#
#   慢层 (slow / map layer) —— 仅由 refresh_seasonal / refresh_yearly 写入：
#     HexCell.base_temperature, base_moisture, base_vegetation, base_terrain
#     HexCell.elevation, landform, terrain, cover, has_river, has_volcano
#     HexCell.ocean_current, upwelling_strength, temperature_transport_anomaly
#     WorldData.*_buffer (烘焙纹理)
#
#   半慢层 (semi-slow) —— 每日由专属 pass 增量推进，但语义上属"地图状态"：
#     HexCell.sea_ice_fraction (由 _apply_sea_ice_daily_pass 推进)
#
#   快层 (fast / weather layer) —— 每日完整重算，禁止持久写入慢层：
#     HexCell.current_state.temperature / moisture / snow_cover
#     HexCell.current_state.weather / weather_intensity 等
#
#   反馈缓冲 (feedback buffer) —— 慢层下属，受限"反馈通道"写入：
#     HexCell.soil_moisture, vegetation_growth_pressure
#     由 _apply_weather_to_map_feedback_pass 以 ≤ 0.5%/日 的小权重累加，
#     由 refresh_seasonal 在季末消费并按 feedback_decay 衰减。
#
# 每日 (fast tick，由 main._on_day_changed 严格按以下顺序触发)：
#   1. refresh_climate_daily(map, season_phase)        — 读慢层 + 写快层
#   2. _apply_sea_ice_daily_pass                       — 读快层温度+慢层洋流→写半慢层
#   3. WeatherSystem.tick / refresh_daily              — 只读 + 写 current_state.weather_*
#   4. _apply_weather_to_map_feedback_pass             — 把当日天气以小权重累加到反馈缓冲
#
# 每季 (slow tick，仅 season_phase 跨整数边界)：
#   5. refresh_seasonal                                — 消费反馈缓冲、biome 决策、重烘 GPU tex
#
# 每年 (slow tick)：
#   6. refresh_yearly                                  — 长期植被演替、base_* 漂移
#
# 所有 4 项快慢耦合行为受 ClimateProfile 的开关控制：
#   emergent_season_enabled / enable_local_climate_coupling
#   emergent_weather_coupling / fast_slow_layering_enabled
# ═══════════════════════════════════════════════════════════════════════

class_name MapGenerator

# 显式 preload，避免新建 class_name 文件时 Godot 全局类注册表偶发未拾取的问题
const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")
# 同理：ClimateProfile 在 @export 里被引用，冷启动/首次导入时全局类注册表可能
# 尚未拾取，这里显式 preload 迫使先加载该脚本，避免
# "Parser Error: Could not parse global class MapGenerator" 的启动报错。
const ClimateProfileScript = preload("res://scripts/data/climate_profile.gd")

# Sliced Update Scheduler (SUS) — 全局切片更新调度器。MapGenerator 持有
# SUS 实例并把所有"周期性模拟工作"作为 Job 注册进来。任务 4：注册
# OceanCurrentsJob，把年首 ~1605ms 的洋流烘焙切成多日 ≤4ms 的小切片。
const SlicedUpdateSchedulerScript = preload("res://scripts/simulation/sus/sus_scheduler.gd")
const SusTickContextScript = preload("res://scripts/simulation/sus/sus_tick_context.gd")
const OceanCurrentsJobScript = preload("res://scripts/simulation/sus/jobs/ocean_currents_job.gd")
# 任务 8：把 refresh_climate_daily / refresh_daily 收编为 SUS Job。
const RefreshClimateDailyJobScript = preload("res://scripts/simulation/sus/jobs/refresh_climate_daily_job.gd")
const WeatherRefreshJobScript = preload("res://scripts/simulation/sus/jobs/weather_refresh_job.gd")
# Daily Sim SoA Refactor 阶段 1：把 bake_sea_ice_fraction_only 从 refresh_climate_daily
# 末尾拆出为独立 SUS Job，受 sea_ice_atlas_upload_stride 控制。
const SeaIceAtlasUploadJobScript = preload("res://scripts/simulation/sus/jobs/sea_ice_atlas_upload_job.gd")
const EnumAtlasUploadJobScript = preload("res://scripts/simulation/sus/jobs/enum_atlas_upload_job.gd")
const SeasonRefreshJobScript = preload("res://scripts/simulation/sus/jobs/season_refresh_job.gd")

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

# Seasonal Continuous Climate：refresh_climate_daily 调用计数器（耗时打点节流用）。
# 首次调用必打、之后每 365 次（≈ 1 年）打一次，避免日志被高频日级刷新淹没。
var _daily_climate_call_count: int = 0
# Systemic Ocean Currents：_apply_ocean_heat_transport_pass 调用计数器（同节流策略）。
var _heat_transport_call_count: int = 0
# Wind Temperature Coupling：_apply_wind_heat_transport_pass 调用计数器（同节流策略）。
var _wind_heat_call_count: int = 0

# Daily-sim perf instrumentation：上一次 refresh_climate_daily 的子段拆解。
# 字段：pass_a_ms / pass_b_ms / ocean_ms / sea_ice_ms / ice_bake_ms / transp_ms /
# total_ms / cells。main.gd fast tick WARN 路径用它定位是哪一段慢。
var _last_climate_breakdown: Dictionary = {}

# Daily-sim perf instrumentation（weather）：上一次 refresh_daily 的子段拆解。
# 字段：advance_ms / spawn_ms / distribute_ms / cyclone_ms（weather_system.tick_one_day 内部）
#       transp_ms / albedo_ms / veg_dyn_ms / cover_rebake_ms / veg_rebake_ms /
#       feedback_ms / total_ms / fronts 。
# main.gd fast tick WARN 路径用它定位 weather_refresh 的哪一段慢。
var _last_weather_breakdown: Dictionary = {}
# Weather refresh sliced：跨 stage_a / stage_b 共享当轮起点时间 + tick_ms + fronts，
# 让 stage_b 收尾时算出的 total_ms 真正反映"第一片到第二片"完整跨 tick 耗时。
var _weather_round_t0_us: int = 0
var _weather_round_tick_ms: float = 0.0
var _weather_round_fronts: Array[WeatherFront] = [] as Array[WeatherFront]
var _enum_atlas_cover_dirty: bool = false
var _enum_atlas_vegetation_dirty: bool = false
var _last_enum_atlas_upload_breakdown: Dictionary = {}
var _pending_season_refresh: bool = false
var _pending_season_idx: int = 0
var _season_refresh_in_progress: bool = false
var _last_season_refresh_breakdown: Dictionary = {}

# True Insolation-Driven Climate（Phase F）：按纬度缓存的"一年平均日射" lookup。
# key  = round(ny * _INSOL_MEAN_LUT_SIZE) ∈ [0, SIZE]
# val  = 16 点数值积分得到的年均 insolation
# 构造时机：refresh_climate_daily 每次运行时按需初始化；axial_tilt 变动时清空重算。
const _INSOL_MEAN_LUT_SIZE: int = 64                  # 65 桶，按 ny 离散，足够 80×60 图使用
const _INSOL_ANNUAL_SAMPLES: int = 16                 # 一年取 16 个 phase 采样点求平均
var _insol_mean_lut: PackedFloat32Array = PackedFloat32Array()
var _insol_mean_lut_tilt: float = -1.0                # 上次构表所用的 axial_tilt_deg，变化时失效
var _insol_driven_path_logged: bool = false           # 首次进入 insolation 主路径时打一次启动日志
var _last_hex_size: float = 22.0
# 当前季节（0..3）。-1 = 还没生成
var _current_season: int = -1
# Phase 13/14：保留 seed 给 lake 种子撒布、火山蓝噪声等独立随机过程用
var _last_seed: int = 0
# Emergent Climate Coupling：缓存最近一次 bake_world/refresh_seasonal 使用的 world，
# 供 refresh_climate_daily 末尾调 baker.bake_sea_ice_fraction_only 时无需额外参数。
var _last_world: WorldData = null
# Milestone 3：天气子系统（每"日"由 main.gd 推进）
var _weather_system: WeatherSystem = null

# v11 公开 getter：供 main.gd / debug_console.gd 等强类型 caller 安全地读取
# WeatherSystem 引用。Godot 4 对带前导下划线的成员存在 "external class member"
# 静态访问限制，外部强类型 caller 直接 `_generator._weather_system` 会触发
# "Could not resolve external class member" 解析错误；通过此 getter 走公开
# API 即可消除该警告，同时保留原内部字段命名约定不动。
# 返回类型刻意写成 Object 而非 WeatherSystem：避免 main.gd 在静态解析
# MapGenerator 时再连带解析 WeatherSystem，缓存场景下会偶发
# "Could not resolve external class member" 报错。caller 端按 duck-typing
# 调用 configure_emergent_coupling 等方法即可。
func get_weather_system() -> Object:
	return _weather_system

# Fast-tick perf opt (A)：weather_refresh_stride 跳日时复用的活跃 fronts 快照。
# 正常日 refresh_daily 结束时写入；跳日分支直接返回此快照，保持 renderer 显示
# 不抖动，同时完全跳过 transpiration / albedo / vegetation / weather→map 反馈
# 以及 baker 的增量重烘。
var _last_active_fronts: Array[WeatherFront] = [] as Array[WeatherFront]
# Fast-tick perf opt (A)：外部（main.gd）按速度档位调用 set_weather_refresh_stride
# 时打点一次，避免每次 refresh_daily 都 print 造成日志噪声。
var _weather_stride_logged: int = -1
# Fast-tick perf opt (A)：refresh_daily 被调用的单调计数，用于 stride 判定。
# MapGenerator 不直接引用 world_clock，main.gd 每日调用一次 refresh_daily，
# 所以 call_index % stride 是 day_index % stride 的合法代理。
var _refresh_daily_call_index: int = -1
var _weather_stage_b_call_index: int = -1
# Fast-tick perf opt (C)：HexCell 强类型成员主路径的一次性迁移/启动日志守门。
# 首次 refresh_climate_daily 时做兜底迁移并打 [fastpath] HexCell typed fields active。
var _typed_fields_migrated: bool = false

# ─── Sliced Update Scheduler（任务 4：接入点 ① + ③）──────────────────────
# SUS 实例由 generate() 末尾创建，把 baker 的 ocean currents bake 拆成每日切片。
var _sus: SlicedUpdateScheduler = null
var _ocean_currents_job: OceanCurrentsJob = null
# 任务 8：refresh_climate_daily / refresh_daily 也作为 SUS Job 注册，
# stride 由 ClimateProfile 字段驱动；speed_changed 时重建对应 Job 的 policy。
var _refresh_climate_daily_job: RefreshClimateDailyJob = null
var _weather_refresh_job: WeatherRefreshJob = null
# Daily Sim SoA Refactor 阶段 1：海冰 GPU 上传 Job。
var _sea_ice_atlas_upload_job: SeaIceAtlasUploadJob = null
var _enum_atlas_upload_job: EnumAtlasUploadJob = null
var _season_refresh_job: SeasonRefreshJob = null
# main.gd 在 _ready 末尾通过 set_world_clock_ref(world_clock) 注入，给
# OceanCurrentsJob 的 season_phase getter 用。
var _world_clock_ref = null
# 一次性 deprecated 字段警告守门（避免同一会话反复 print）。
var _ocean_legacy_warning_logged: bool = false

# ─── 任务 6：refresh_seasonal per-cell 起点优化（方案 C）───────────────────
# 行级查表：纬度温度 + 当季温度偏移 都只取决于 ny（= row / (height-1)），
# 与 cell.elevation 无关。在 refresh_seasonal 入口一次性建表（O(height)），
# 主循环 5 处全图遍历共 ~5×(W*H) 次 cell 访问改成 O(1) 查表，省掉每 cell 一次
# pow + cos + 一次三角函数调用。预期普通季 525ms → 350~420ms。
# 仅缓存当前 season 一份；season 切换时自动重建（O(height)，对 256 行约 1ms）。
# 对其他子 pass（rain_shadow / river_ecology / shrubland / mangrove / glacier）
# 暂不渗透，保持改动面最小，风险最低。
var _row_lat_temp: PackedFloat32Array = PackedFloat32Array()
var _row_season_off: PackedFloat32Array = PackedFloat32Array()
var _row_tables_season: int = -1
var _row_tables_height: int = 0


## 建立/重建行级查表。idempotent：同 (cfg.height, season) 命中时直接 return。
func _ensure_row_tables(cfg: MapConfig, season: int) -> void:
	if cfg == null:
		return
	var H: int = cfg.height
	if _row_tables_season == season and _row_tables_height == H \
			and _row_lat_temp.size() == H:
		return
	_row_lat_temp.resize(H)
	_row_season_off.resize(H)
	var inv: float = 1.0 / float(maxi(H - 1, 1))
	for r in range(H):
		var ny: float = float(r) * inv
		var lat_signed: float = (ny - 0.5) * 2.0
		_row_lat_temp[r] = pow(cos(lat_signed * PI * 0.5), 1.2)
		_row_season_off[r] = _season_temp_offset(ny, season)
	_row_tables_season = season
	_row_tables_height = H

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
	_weather_stage_b_call_index = -1
	_enum_atlas_cover_dirty = false
	_enum_atlas_vegetation_dirty = false
	_last_enum_atlas_upload_breakdown = {}
	_pending_season_refresh = false
	_season_refresh_in_progress = false
	_last_season_refresh_breakdown = {}

	var t_total := Time.get_ticks_msec()
	var map := _generate_cells(cfg)
	print("MapGenerator v7: per-cell %dms (%d cells)" % [Time.get_ticks_msec() - t_total, map.cell_count()])

	# Milestone 1：generate 完成后从 cell.terrain + 上下文派生 landform / vegetation / cover
	# 三轴。这一步必须在 _snapshot_base_state 之前，让基线快照能拿到三轴值。
	_sync_axes_for_map(map, cfg)

	# 在玩法层 baking 之前快照"年均"基线，给 Phase 2 季节刷新做参考
	_snapshot_base_state(map)

	# Phase 12 / Emergent Climate Coupling：base_terrain 定型后，为每个海洋 cell 初始化
	# 连续的 sea_ice_fraction（以 summer 温度为参考的平衡值），超过 terrain 阈值的同时设置 SEA_ICE。
	# 这取代了旧的 _apply_sea_ice_pass（已删除）——从 generate 开始就已经是"连续覆盖率"语义。
	_bootstrap_sea_ice_fraction(map, cfg)
	# 海冰基线可能改写了部分 cell.terrain → 重新同步轴
	_sync_axes_for_map(map, cfg)

	var t_bake := Time.get_ticks_msec()
	_baker = MapBaker.new()
	# Physical Wind & Ocean Circulation：把 ClimateProfile 注入 cfg，让 MapBaker
	# 在 bake_world 内部检测 physical_circulation_enabled 等开关。生成阶段先注入一次；
	# OceanCurrentsJob 注册时还会重复注入一次，保持 cfg.climate_profile 始终为
	# 当前激活的 profile。
	if cfg != null:
		cfg.climate_profile = _c()
	var world := _baker.bake_world(map, cfg, hex_size, effective_seed)
	if _baker.has_method("prewarm_dynamic_axis_caches"):
		_baker.prewarm_dynamic_axis_caches(map, world)
	_last_world = world
	print("MapGenerator v7: bake %dms" % (Time.get_ticks_msec() - t_bake))

	# 任务 7：在 bake 后新增一个轻量级 pass，把 MapBaker 烤好的 per-pixel 洋流场
	# 折返为 per-cell HexCell.ocean_current。这是逻辑层的洋流字段——渲染层从这里
	# 开始读取（任务 8），未来的 AI / 鱼群 / 航运也从这里读取。不改动 height /
	# temperature / moisture / vegetation 生成（需求显式非目标）。
	_compute_ocean_currents(map, world, hex_size)

	# 地形扰动风场（六边形尺度）：在洋流计算之后，借用已经定型的 cell.terrain /
	# cell.elevation + 邻居拓扑，对 WindBelt.wind_at 给出的"纬度风基线"做局地
	# 修正——海陆摩擦衰减、山脉上风阻挡（降速 + 旁侧绕流）、山脊伯努利加速、
	# 海岸热力风加速。结果写入 cell.wind_vector，仅给 Data Overlay 与未来局地
	# 玩法系统读；天气锋面 advection / 洋流 Ekman 偏转**仍读** WorldData.
	# wind_field_buffer，保留地球级纬向稳定形态。
	_compute_terrain_perturbed_wind(map)

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
	# Systemic Ocean Currents：按配置启用台风尾迹扰动（默认关闭）
	_weather_system.configure_cyclone_wake(cfg.enable_cyclone_wake, cfg.CYCLONE_WAKE_DAYS)
	# Emergent Climate Coupling：把 emergent_weather_coupling 开关与雨影/迎风坡
	# 参数一次性下推到 WeatherSystem，后续每日 tick 内部消费。
	var cp_ec := _c()
	if cp_ec != null:
		_weather_system.configure_emergent_coupling(
			bool(cp_ec.emergent_weather_coupling),
			float(cp_ec.rain_shadow_threshold),
			float(cp_ec.rain_shadow_factor),
			float(cp_ec.orographic_boost)
		)
		# v11 地形扰动风：让 weather front advect / spawn 优先用 cell.wind_vector
		_weather_system.configure_terrain_wind(bool(cp_ec.weather_advect_use_wind_vector))
		# Ocean current → weather spawn bias：寒流海岸抑制 RAIN/STORM/MONSOON 生成、
		# 暖流海岸促进。0 = legacy 行为；详见 weather_system._spawn_emergent_front。
		if _weather_system.has_method("configure_ocean_spawn_bias"):
			_weather_system.configure_ocean_spawn_bias(float(cp_ec.ocean_weather_spawn_bias))
		if _weather_system.has_method("configure_weather_field"):
			_weather_system.configure_weather_field(
				bool(cp_ec.weather_field_enabled),
				mini(int(cp_ec.weather_field_advect_steps), 1),
				float(cp_ec.weather_field_diffusion),
				float(cp_ec.weather_condensation_gain),
				float(cp_ec.weather_precip_decay),
				float(cp_ec.weather_orographic_lift_gain),
				float(cp_ec.weather_convergence_gain),
				float(cp_ec.weather_ocean_evap_gain),
				mini(int(cp_ec.weather_component_summary_limit), 12)
			)

	# ─── Daily-Sim SoA Refactor 阶段 2：构建邻居索引 SoA ──────────────────
	# 此时所有 cell 已入库、terrain 已定型（包括河流、火山、湖泊、海冰首日
	# 状态等慢层常量），fast-tick 路径需要的稳定邻居拓扑已就绪。一次性预
	# 计算 _cell_array / _cell_index / _neighbor_indices，之后 fast-tick
	# 热路径直接通过 idx*6+dir 查表，不再走 6 次字典 lookup。
	# regenerate 路径：MapData 实例随每次 generate() 调用整体替换，本次构建
	# 的索引随旧 MapData 一起被丢弃，无需手动 invalidate。
	map._build_indices()

	# ─── SUS 注册（任务 4：接入点 ① + ③）─────────────────────────────────
	# 此时 baker.bake_world 已经一次性烘完了 ocean currents + upwelling 完整版，
	# per-cell 也已经被 _compute_ocean_currents 回填。SUS 从这里开始接管"逐日
	# 增量重烘"——每个完整 round 在 ocean_currents_period_ticks 天内分
	# ocean_currents_slice_count 个切片完成，commit 时再一次性原子替换 4 件
	# 产物（ocean_current_buffer / ocean_upwelling_buffer / vector_atlas_tex /
	# upwelling_tex）并回填 per-cell。
	_setup_sus(map, world, cfg, hex_size)

	return {"map": map, "world_data": world, "seed": effective_seed}


# ─── SUS 接入点（任务 4） ────────────────────────────────────────────────

func _setup_sus(map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	# 创建一个全新 SUS 实例（regenerate 路径会让旧实例随 MapGenerator 一起被替换，
	# 不需要手动 reset_all_progress）。
	_sus = SlicedUpdateScheduler.new()
	_season_refresh_job = SeasonRefreshJobScript.new(self, map, world)
	_sus.register_job(_season_refresh_job)
	# Deprecated 字段守门：旧 ClimateProfile 资源里 ocean_current_refresh_seasons
	# 仍可能被序列化保存。打印一次 warning 提示作者迁移到 SUS 配置。
	var cp := _c()
	if cp != null and not _ocean_legacy_warning_logged:
		# 默认值是 4；若仍是 4 则视作"未显式覆盖"，不打 warning，避免噪声。
		if int(cp.ocean_current_refresh_seasons) != 4:
			print("[SUS] ocean_current_refresh_seasons is deprecated (was %d), ignored. Use ocean_currents_period_ticks / ocean_currents_slice_count instead." % int(cp.ocean_current_refresh_seasons))
		_ocean_legacy_warning_logged = true
	# 注册 OceanCurrentsJob。
	var period_ticks: int = 30
	var slice_count: int = 10
	if cp != null:
		period_ticks = max(1, int(cp.ocean_currents_period_ticks))
		slice_count = max(1, int(cp.ocean_currents_slice_count))
	# Physical Wind & Ocean Circulation：把激活的 ClimateProfile 引用注入 cfg，
	# 让 MapBaker 在切片烘焙时（OceanCurrentsJob.run_slice 调用 baker.bake_*_slice）
	# 通过 cfg.climate_profile 读到 physical_circulation_enabled 等开关。null 时
	# 走 ny-only 旧路径。
	if cfg != null:
		cfg.climate_profile = cp
	_ocean_currents_job = OceanCurrentsJob.new(_baker, map, world, cfg, hex_size, period_ticks, slice_count)
	_ocean_currents_job.depends_on.append(&"season_refresh")
	# commit 完成后回填 per-cell（此前 rebake_ocean_currents 路径里的 _compute_ocean_currents）。
	_ocean_currents_job.on_commit = func():
		_compute_ocean_currents(map, world, hex_size)
	# 若 main.gd 已经早一步注入 world_clock，更新 phase getter。
	if _world_clock_ref != null:
		_ocean_currents_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
	_sus.register_job(_ocean_currents_job)

	# 任务 8：注册 RefreshClimateDailyJob + WeatherRefreshJob。
	# 两者的 stride 直接读 ClimateProfile，speed_changed 时由 main.gd 通过
	# set_weather_refresh_stride / set_daily_climate_refresh_stride 改写并
	# 调 reconfigure。stride 跳日的语义完全由 SusPolicy 承担。
	var climate_stride: int = 1
	var weather_stride: int = 1
	if cp != null:
		climate_stride = max(1, int(cp.daily_climate_refresh_stride))
		weather_stride = max(1, int(cp.weather_refresh_stride))
	# RefreshClimateDailyJob：写连续气候基线（priority 100）
	var climate_phase_getter := Callable()
	if _world_clock_ref != null:
		climate_phase_getter = Callable(_world_clock_ref, "season_phase")
	_refresh_climate_daily_job = RefreshClimateDailyJobScript.new(self, map, climate_phase_getter, climate_stride)
	_refresh_climate_daily_job.depends_on.append(&"season_refresh")
	_sus.register_job(_refresh_climate_daily_job)
	_enum_atlas_upload_job = EnumAtlasUploadJobScript.new(self, _baker, map, world, hex_size, 2)
	_enum_atlas_upload_job.depends_on.append(&"season_refresh")
	_sus.register_job(_enum_atlas_upload_job)
	# WeatherRefreshJob：天气推进 + 反馈链（priority 150，依赖 refresh_climate_daily）
	var season_idx_getter := Callable()
	var season_phase_getter := Callable()
	var climate_anomaly_getter := Callable()
	if _world_clock_ref != null:
		season_idx_getter = Callable(_world_clock_ref, "season_index")
		season_phase_getter = Callable(_world_clock_ref, "season_phase")
		# climate_anomaly 是 WorldClock 的普通 property、不是方法，
		# Callable 只能绑方法，这里用 lambda 包一层读。
		var wc_ref = _world_clock_ref
		climate_anomaly_getter = func() -> float:
			return float(wc_ref.climate_anomaly)
	_weather_refresh_job = WeatherRefreshJobScript.new(
		self, map, world,
		season_idx_getter, season_phase_getter, climate_anomaly_getter,
		weather_stride
	)
	_weather_refresh_job.depends_on.append(&"season_refresh")
	_sus.register_job(_weather_refresh_job)

	# Daily Sim SoA Refactor 阶段 1：注册 SeaIceAtlasUploadJob。
	# 把 bake_sea_ice_fraction_only 从 refresh_climate_daily 末尾摘出，独立 stride 控制。
	# priority=250 保证晚于其它日级 Job；视觉上传允许被 frame_budget 守门延后一两天。
	var sea_ice_stride: int = 2
	if cp != null:
		sea_ice_stride = max(1, int(cp.sea_ice_atlas_upload_stride))
	_sea_ice_atlas_upload_job = SeaIceAtlasUploadJobScript.new(_baker, map, world, sea_ice_stride)
	_sea_ice_atlas_upload_job.depends_on.append(&"season_refresh")
	_sus.register_job(_sea_ice_atlas_upload_job)


## main.gd 在 _ready 末尾调用，让 OceanCurrentsJob 拿到 season_phase 连续浮点。
func set_world_clock_ref(world_clock_node) -> void:
	_world_clock_ref = world_clock_node
	if _world_clock_ref == null:
		return
	if _ocean_currents_job != null:
		_ocean_currents_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
	# 任务 8：把 world_clock getter 注入给气候 / 天气 Job。
	if _refresh_climate_daily_job != null:
		_refresh_climate_daily_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
	if _weather_refresh_job != null:
		_weather_refresh_job.season_index_getter = Callable(_world_clock_ref, "season_index")
		_weather_refresh_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
		var wc_ref = _world_clock_ref
		_weather_refresh_job.climate_anomaly_getter = func() -> float:
			return float(wc_ref.climate_anomaly)


## main.gd._on_day_changed 末尾调用，驱动 SUS 推进所有日级 Job。
## tick_index 单调递增；day_index / season_phase / speed 由 world_clock 提供。
## 返回字典：{ fronts: Array[WeatherFront], weather_ran: bool }，
## 让 main.gd 把 fronts 转发给 renderer、用 weather_ran 决定面板刷新策略。
func sus_tick_daily(world_clock_node) -> Dictionary:
	if _sus == null:
		return { "fronts": [] as Array[WeatherFront], "weather_ran": false }
	var di: int = 0
	var sp: float = 0.0
	var ss: float = 1.0
	if world_clock_node != null:
		if world_clock_node.has_method("day_index"):
			di = int(world_clock_node.day_index())
		if world_clock_node.has_method("season_phase"):
			sp = float(world_clock_node.season_phase())
		# WorldClock.speed_multiplier 是普通成员变量；用 get() 安全读取。
		var v = world_clock_node.get("speed_multiplier")
		if v != null:
			ss = float(v)
	# 任务 8：每个 tick 入场前清掉 weather_refresh 的 ran_this_tick 标志，
	# 这样 SUS 决定跳过该 Job 时它就保持 false（main.gd 据此跳过 UI 行刷新）。
	if _weather_refresh_job != null:
		_weather_refresh_job.reset_run_flag()
	var ctx: SusTickContext = SusTickContext.make(di, di, sp, ss, &"day_changed")
	_sus.tick(ctx)
	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	var weather_ran: bool = false
	# Drift-fix（2026-05-10）：暴露"fronts 是否真的变了"标志。
	# 与 weather_ran 区别：weather_ran=true 表示 SUS Job 跑了 slice（stage_a 或 stage_b 任一），
	# fronts_changed=true 仅当 stage_b 完成、_last_fronts 重新赋值时成立。
	# main.gd 用它 gate renderer.set_weather_fronts 调用，避免每隔一 tick 重复推送
	# 同一份 fronts 触发 weather_layer 内部的 blend reset → 云视觉冻结。
	var fronts_changed: bool = false
	if _weather_refresh_job != null:
		fronts = _weather_refresh_job.last_fronts()
		weather_ran = _weather_refresh_job.did_run_last_tick()
		fronts_changed = _weather_refresh_job.did_change_fronts_last_tick()
	return { "fronts": fronts, "weather_ran": weather_ran, "fronts_changed": fronts_changed }


## 地图重新生成 / regenerate 路径调用：清空所有 Job 的进度游标 + pending 缓冲。
func sus_reset_all() -> void:
	if _sus != null:
		_sus.reset_all_progress()


func sus_report_last_tick() -> Dictionary:
	if _sus == null:
		return {}
	return _sus.report_last_tick()


# Daily-sim perf instrumentation：返回上一次 refresh_climate_daily 的子段拆解，
# 供 main.gd fast tick WARN / 详细日志路径定位 6 段子耗时。
func sus_climate_breakdown() -> Dictionary:
	return _last_climate_breakdown.duplicate()


# Daily-sim perf instrumentation（weather）：返回上一次 refresh_daily 的子段拆解，
# 供 main.gd fast tick WARN 路径定位 weather_refresh 的生成/分发/反馈 8+ 段子耗时。
func sus_weather_breakdown() -> Dictionary:
	return _last_weather_breakdown.duplicate()


func has_pending_enum_atlas_upload() -> bool:
	return _enum_atlas_cover_dirty or _enum_atlas_vegetation_dirty


func consume_pending_enum_atlas_axis() -> String:
	if _enum_atlas_cover_dirty:
		_enum_atlas_cover_dirty = false
		return "cover"
	if _enum_atlas_vegetation_dirty:
		_enum_atlas_vegetation_dirty = false
		return "vegetation"
	return ""


func record_enum_atlas_upload(axis: String, elapsed_ms: float) -> void:
	_last_enum_atlas_upload_breakdown = {
		"axis": axis,
		"elapsed_ms": elapsed_ms,
		"cover_pending": _enum_atlas_cover_dirty,
		"vegetation_pending": _enum_atlas_vegetation_dirty,
	}


func sus_enum_atlas_breakdown() -> Dictionary:
	return _last_enum_atlas_upload_breakdown.duplicate()


func _mark_enum_atlas_dirty(cover_dirty: bool, vegetation_dirty: bool) -> void:
	_enum_atlas_cover_dirty = _enum_atlas_cover_dirty or cover_dirty
	_enum_atlas_vegetation_dirty = _enum_atlas_vegetation_dirty or vegetation_dirty


func queue_season_refresh(season_idx: int) -> void:
	_pending_season_idx = clampi(season_idx, 0, 3)
	_pending_season_refresh = true


func has_pending_season_refresh() -> bool:
	return _pending_season_refresh or _season_refresh_in_progress


func begin_pending_season_refresh() -> int:
	_pending_season_refresh = false
	_season_refresh_in_progress = true
	_last_season_refresh_breakdown = {}
	return _pending_season_idx


func run_season_refresh_stage(map: MapData, world: WorldData, season_idx: int, stage: int) -> void:
	# 11-stage 切片（原 7-stage），把 stage 4 的 4 个生态 pass 与 stage 6 的
	# rebake_biome + consume_feedback 各自独立成 stage。每个 stage 的单帧上界
	# 从原来 ~140ms 降到 ~30ms 量级。SeasonRefreshJob 的 done 判定按 11 同步。
	#   0: moisture set
	#   1: rain_shadow
	#   2: redecide_terrain
	#   3: river_ecology + vegetation_feedback
	#   4: shrubland_pass
	#   5: mangrove_pass
	#   6: glacier_pass
	#   7: swamp_pass
	#   8: sync_current_state
	#   9: rebake_biome_tex_only
	#  10: consume_feedback_buffers
	var t_us0: int = Time.get_ticks_usec()
	var season := clampi(season_idx, 0, 3)
	match stage:
		0:
			_last_world = world
			_current_season = season
			var cfg_local: MapConfig = _last_cfg
			if cfg_local == null:
				return
			_ensure_row_tables(cfg_local, season)
			var moist_scale: float = _c().seasonal_moisture_scale[season]
			for cell: HexCell in map.all_cells():
				if _is_water(cell.terrain):
					cell.moisture = cell.base_moisture
				else:
					cell.moisture = clampf(cell.base_moisture * moist_scale, 0.0, 1.0)
		1:
			if _last_cfg != null:
				_apply_rain_shadow_per_cell(map, _last_cfg, float(season) + 0.5)
		2:
			_seasonal_redecide_terrain(map, season)
		3:
			if _last_cfg != null:
				_apply_river_ecology(map, _last_cfg)
				_apply_vegetation_feedback(map, _last_cfg)
		4:
			if _last_cfg != null:
				_apply_shrubland_pass(map, _last_cfg)
		5:
			if _last_cfg != null:
				_apply_mangrove_pass(map, _last_cfg)
		6:
			if _last_cfg != null:
				_apply_glacier_pass(map, _last_cfg)
		7:
			if _last_cfg != null:
				_apply_swamp_pass(map, _last_cfg)
		8:
			_seasonal_sync_current_state(map, season)
		9:
			if world != null and _baker != null:
				_baker.rebake_biome_tex_only(map, world, _last_hex_size)
		10:
			var cp_fb := _c()
			if cp_fb != null and bool(cp_fb.fast_slow_layering_enabled):
				_consume_feedback_buffers(map, cp_fb.feedback_decay)
	var elapsed_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	_last_season_refresh_breakdown["stage_%d_ms" % stage] = elapsed_ms
	# H 诊断：单 stage > 30ms → 直接打点，定位 season_refresh max=128-141ms 的根因 stage。
	if elapsed_ms > 30.0:
		print("  [season_refresh] stage=%d slow=%.1fms (season=%d)" % [stage, elapsed_ms, season])


func finish_season_refresh(_map: MapData, _world: WorldData, _season_idx: int) -> void:
	_season_refresh_in_progress = false


func sus_season_refresh_breakdown() -> Dictionary:
	return _last_season_refresh_breakdown.duplicate()


func _seasonal_redecide_terrain(map: MapData, season: int) -> void:
	if _last_cfg == null:
		return
	var cfg_local: MapConfig = _last_cfg
	_ensure_row_tables(cfg_local, season)
	var lat_tab: PackedFloat32Array = _row_lat_temp
	var off_tab: PackedFloat32Array = _row_season_off
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var is_permanent_climate := cell.base_terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.base_terrain == TerrainType.TERRAIN.SNOW
		if is_permanent_climate:
			cell.apply_terrain(cell.base_terrain)
			continue
		if _is_permanent_landform(cell.base_terrain):
			cell.apply_terrain(cell.base_terrain)
			continue
		var r_idx: int = _cube_to_row(cell, cfg_local)
		var lat_temp: float = lat_tab[r_idx]
		var temp_year: float = clampf(lat_temp - cell.elevation * 0.5, 0.0, 1.0)
		var temp_now: float = clampf(temp_year + off_tab[r_idx], 0.0, 1.0)
		var new_terrain := _decide_terrain(cell.elevation, temp_now, cell.moisture, cfg_local)
		cell.apply_terrain(new_terrain)


func _seasonal_sync_current_state(map: MapData, season: int) -> void:
	if _last_cfg == null:
		return
	var cfg_local: MapConfig = _last_cfg
	_ensure_row_tables(cfg_local, season)
	var lat_tab: PackedFloat32Array = _row_lat_temp
	var off_tab: PackedFloat32Array = _row_season_off
	for cell: HexCell in map.all_cells():
		var r_idx2: int = _cube_to_row(cell, cfg_local)
		var lat_temp2: float = lat_tab[r_idx2]
		var temp_year2: float = clampf(lat_temp2 - cell.elevation * 0.5, 0.0, 1.0)
		var temp_now2: float = clampf(temp_year2 + off_tab[r_idx2], 0.0, 1.0)
		var land_h: float = (cell.elevation - cfg_local.sea_level) / maxf(1.0 - cfg_local.sea_level, 0.001)
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
		_sync_axes_for_cell(cell, cfg_local, snow_cover)
		cell.current_state = {
			"season": season,
			"temperature": temp_now2,
			"moisture": cell.moisture,
			"snow_cover": snow_cover,
			"biome": int(cell.terrain),
			"landform": int(cell.landform),
			"vegetation": int(cell.vegetation),
			"cover": int(cell.cover),
			"weather": cell.weather_type if cell.weather_field_initialized else int(WeatherType.WT.CLEAR),
			"weather_intensity": cell.weather_intensity if cell.weather_field_initialized else 0.0,
		}
		cell.push_biome_history(int(cell.terrain))
		cell.push_vegetation_history(int(cell.vegetation))


# Daily-sim perf instrumentation：返回 SUS 上一 tick 的整体摘要
# （total_ms / jobs_ran / jobs_skipped / slices_total / source / tick_index）。
func sus_report_last_tick_summary() -> Dictionary:
	if _sus == null:
		return {}
	return _sus.report_last_tick_summary()

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

	# 6.5 v11 新增：山地正雨（迸风上坡加湿）——与 _compute_river_flow 同源公式，
	# 使迸风山坡在 Humidity / Precipitation overlay 上明显比同纬度低地湿润。
	# 必须在 base_moisture snapshot 之前调用，因为“迸风加湿”是地形决定的不变量。
	_apply_orographic_moisture_boost(map)

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

# v11 新增：山地正雨 (orographic precipitation) 回写到 cell.moisture。
#
# 背景：_compute_river_flow 中一直有一个 "orographic_boost" 因子，但该因子
# 只被用于计算河流流量，完全不影响 cell.moisture / base_moisture，导致迸风山坡
# 在 Humidity / Precipitation / Vegetation overlay 上看不到任何加湿效果。本 pass 
# 用与河流流量完全同源的公式 boost = 1 + max(land_h - 0.30, 0) * orographic_boost
# 对 cell.moisture 乘充，使“地形决定的不变量”进入 base_moisture（调用点在
# coastal pass 之后、base_moisture snapshot 之前）。
# 只作用于陆地且 land_h>0.30 的 cell；orographic_boost==0 时整个 pass 等价 no-op。
func _apply_orographic_moisture_boost(map: MapData) -> void:
	var k: float = _c().orographic_boost
	if k == 0.0:
		return
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var land_h: float = cell.elevation
		if land_h <= 0.30:
			continue
		var boost: float = 1.0 + (land_h - 0.30) * k
		cell.moisture = clampf(cell.moisture * boost, 0.0, 1.0)

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
		var best_dir: Vector3i = _pick_upwind_dir(cell, ny, season_phase, jitter)
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

# v11 新增：雨影/上风向决策的统一入口。
#   - 优先采用 cell.wind_vector（地形扰动后、六边形尺度的实际盛行风），
#     这样山脉绕流后形成的真实风向能正确决定背风面位置；
#   - 若 cell.wind_vector 还未烘焙（race / 旧存档）则回退到 WindBelt.wind_at()
#     的纬度风基线，保证向后兼容。
# 同时被 bake 阶段 _apply_rain_shadow 与 daily sim 阶段的 per-cell 调用复用。
func _pick_upwind_dir(cell: HexCell, ny: float, season_phase: float, jitter: float) -> Vector3i:
	var wv: Vector2 = cell.wind_vector
	if wv.length() > 0.01:
		return WindBeltScript.upwind_hex_dir(wv.normalized())
	var wind: Vector2 = WindBeltScript.wind_at(ny, season_phase, jitter)
	return WindBeltScript.upwind_hex_dir(wind)

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
	# v11 海拔衰减：donor cell 海拔越高，对邻居的水汽贡献越小
	# （高山针叶林不应与低地针叶林贡献同等湿度）。
	# decay==0 时退化为旧行为；下限 0.1 避免极高海拔完全失声。
	var elev_decay: float = _c().veg_feedback_elev_decay
	var deltas: Dictionary = {}
	for cell: HexCell in map.all_cells():
		var donor: float = _vegetation_donor_amount(int(cell.terrain))
		if donor == 0.0:
			continue
		var elev_factor: float = clampf(1.0 - cell.elevation * elev_decay, 0.1, 1.0)
		var donor_eff: float = donor * elev_factor
		for nb: HexCell in map.get_neighbors(cell):
			if _is_water(nb.terrain):
				continue  # 水体湿度不参与
			var k := Vector3i(nb.q, nb.r, nb.s)
			deltas[k] = float(deltas.get(k, 0.0)) + donor_eff

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
	# 任务 6（方案 C）：温度查表化。本函数既被 generate（_current_season=-1→clamp 0）
	# 调用，也被 refresh_seasonal 调用，统一通过 _ensure_row_tables 兜底。
	# 注意：原版只用"年均温" _compute_temperature(ny, elev) 决策（不带 season offset），
	# 这里查表后保持同语义——只用 lat_tab，不叠加 off_tab。
	var season_local: int = clampi(_current_season, 0, 3)
	_ensure_row_tables(cfg, season_local)
	var lat_tab: PackedFloat32Array = _row_lat_temp
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		if cell.terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.terrain == TerrainType.TERRAIN.SNOW:
			continue
		# Phase 14：永久地标不被气候反馈翻新
		if _is_permanent_landform(cell.terrain):
			continue
		var r_idx: int = _cube_to_row(cell, cfg)
		var lat_temp: float = lat_tab[r_idx]
		var temp: float = clampf(lat_temp - cell.elevation * 0.5, 0.0, 1.0)
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
	# 任务 6（方案 C）：行级 lat_temp 查表，省掉 per-cell 一次 pow+cos。
	# swamp 用"年均温" _compute_temperature(ny, elev)（不带 season offset），
	# 与原版语义一致。
	var season_local: int = clampi(_current_season, 0, 3)
	_ensure_row_tables(cfg, season_local)
	var lat_tab: PackedFloat32Array = _row_lat_temp
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
		var r_idx: int = _cube_to_row(cell, cfg)
		var lat_temp: float = lat_tab[r_idx]
		var temp: float = clampf(lat_temp - cell.elevation * 0.5, 0.0, 1.0)
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
	# Systemic Ocean Currents：upwelling 放宽阈值 + 深海 PELAGIC_BLOOM。
	# 主开关关闭 / 无 upwelling 数据时，系数归零，回退到纯温度判定（需求 5.4）。
	var ocean_enabled: bool = cfg.enable_ocean_heat_transport
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
		var up: float = cell.upwelling_strength if ocean_enabled else 0.0
		# 上升流放宽两侧窗口 0.08（需求 5.2），仅大陆架才生效
		var widen: float = 0.08 if (has_land_neighbor and up > 0.4) else 0.0
		if has_land_neighbor:
			# REEF：暖海（temp > 0.60 - widen）+ 远离河口
			if temp > (0.60 - widen) and not has_river_outlet_neighbor:
				if t == TerrainType.TERRAIN.COAST:
					cell.apply_terrain(TerrainType.TERRAIN.REEF)
					continue
			# KELP：凉温带（temp ∈ [0.30 - widen, 0.55 + widen]）
			if temp >= (0.30 - widen) and temp <= (0.55 + widen):
				if t == TerrainType.TERRAIN.COAST:
					cell.apply_terrain(TerrainType.TERRAIN.KELP)
					continue
		# 需求 5.3：深海（OCEAN，无陆地邻居）+ 强上升流 → PELAGIC_BLOOM cover
		# cover 是独立轴，不改 terrain（仍是 OCEAN），仅视觉叠淡绿 tint。
		if ocean_enabled and not has_land_neighbor and t == TerrainType.TERRAIN.OCEAN and up > 0.6:
			cell.cover = CoverType.CV.PELAGIC_BLOOM

# SEA_ICE（海冰）：每季都重判定（用当季温度），需要 base_terrain 当 revert target
# 阈值带 hysteresis：形成 temp < 0.07，融化 temp > 0.12，避免季节边界抖动
# const SEA_ICE_FORM_THRESHOLD (migrated to ClimateProfile.sea_ice_form_threshold)
# const SEA_ICE_MELT_THRESHOLD (migrated to ClimateProfile.sea_ice_melt_threshold)

func _bootstrap_sea_ice_fraction(map: MapData, cfg: MapConfig) -> void:
	# generate() 里的一次性初始化：为每个海洋 cell 按 summer 基线温度给出 sea_ice_fraction 平衡值。
	# 目的：让 refresh_climate_daily 首次运行前就有合理的初值，而不是全 0（否则高纬该冻的地方
	# 需要几十天才爬到 ice_terrain_threshold，视觉上出现"开局一片无冰"的假象）。
	#
	# 平衡值取法（与 _apply_sea_ice_daily_pass 的阈值语义一致）：
	#   temp < form_threshold  →  fraction = smoothstep 向 1 走
	#   temp > melt_threshold  →  fraction = 0
	#   之间                   →  线性过渡
	# 然后再按 sea_ice_terrain_threshold 翻转 terrain。
	var cp := _c()
	if cp == null:
		return
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var thr_terrain: float = float(cp.sea_ice_terrain_threshold)
	for cell: HexCell in map.all_cells():
		if not _is_water(cell.terrain):
			cell.sea_ice_fraction = 0.0
			continue
		if cell.terrain == TerrainType.TERRAIN.LAKE:
			cell.sea_ice_fraction = 0.0
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp_year: float = _compute_temperature(ny, cell.elevation)
		var temp_summer: float = clampf(temp_year + _season_temp_offset(ny, 1), 0.0, 1.0)
		# Note: bootstrap 保守取全年最冷相位（season=3，冬），避免首帧过于"夏感"
		var temp_winter: float = clampf(temp_year + _season_temp_offset(ny, 3), 0.0, 1.0)
		# 取两者均值当"年平均 + 偏冬"估计，让极地区域也能初始结冰
		var temp_ref: float = (temp_summer + temp_winter) * 0.5
		var frac: float = 0.0
		if temp_ref < t_form:
			# 冷：按离阈距离给个饱和度
			frac = clampf((t_form - temp_ref) / maxf(t_form, 0.001), 0.0, 1.0)
			# 用 smoothstep 映射到 0..1，避开接近阈值时就近乎满冰
			frac = smoothstep(0.0, 0.6, frac)
		elif temp_ref > t_melt:
			frac = 0.0
		else:
			# 迟滞带：线性从 form→melt 对应 1→0
			var span: float = maxf(t_melt - t_form, 0.001)
			frac = clampf((t_melt - temp_ref) / span, 0.0, 1.0) * 0.5
		cell.sea_ice_fraction = frac
		# 超过 terrain 阈值 → 翻成 SEA_ICE（保留 base_terrain 可由原 setup 逻辑维持）
		if frac >= thr_terrain and cell.terrain != TerrainType.TERRAIN.SEA_ICE:
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
	# Physical Wind & Ocean Circulation：物理化路径下，cell.ocean_current /
	# cell.upwelling_strength 已由 MapBaker 的 hex 求解器（PhysicalCirculationSolver.psi_to_ocean_current
	# / solve_upwelling）直接写入；此时再从像素 buffer 反向采样会**降级精度**
	# （hex 求解 → RG8 量化 → 双线性回采，三次重采样累积误差），所以直接 return。
	# 旧路径继续按"像素回采到 hex"工作，行为 bit-for-bit 不变。
	var profile: ClimateProfile = _c()
	if profile != null and profile.physical_circulation_enabled:
		print("MapGenerator: skip _compute_ocean_currents (physical-hex path writes per-cell directly)")
		return
	var water_count: int = 0
	var has_upwelling: bool = not world.ocean_upwelling_buffer.is_empty()
	for cell: HexCell in map.all_cells():
		if cell == null:
			continue
		if not _is_water(cell.terrain):
			cell.ocean_current = Vector2.ZERO
			cell.upwelling_strength = 0.0
			continue
		var wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, hex_size)
		var cur: Vector2 = world.sample_ocean_current(wp)
		# clamp 长度 ≤ 1（sample 出来理论上就在 [-1,1]×[-1,1] 区间，
		# 极少数对角线位置 length 可能 >1，做个安全裁切）。
		if cur.length() > 1.0:
			cur = cur.normalized()
		cell.ocean_current = cur
		# Systemic Ocean Currents：同步回填 upwelling_strength ∈ [-1, 1]
		cell.upwelling_strength = world.sample_upwelling(wp) if has_upwelling else 0.0
		water_count += 1
	print("MapGenerator v7: ocean currents for %d water cells in %dms"
			% [water_count, Time.get_ticks_msec() - t0])

# ─── 地形扰动风场（六边形尺度） ────────────────────────────────────────────
# 给每个 cell 计算"被地形修改过的实际盛行风向 + 风速"，写入 cell.wind_vector。
# 仅在 bake 后跑一次（per-game）。语义参见 HexCell.wind_vector 注释——
# 不影响 WorldData.wind_field_buffer，也不参与天气 / 洋流物理。
#
# 算法（season_phase=2.0 = 北半球夏至基线，与 wind_field_buffer 同源；
# 后续若想要季节切换可再扩展）：
#   ① 基础风：dir = WindBelt.wind_at(ny, 2.0)，speed = WindBelt.wind_speed_at(ny, 2.0)
#   ② 海陆摩擦：陆地 cell speed × 0.65（粗糙度 ~ 海面的 3-5 倍，简化为线性衰减）
#   ③ 山脉上风阻挡：取上风向相邻 cell（用 wind dir 的反方向选最匹配的 hex 邻居）
#      若上风邻居 elevation - 当前 elevation > 0.15：
#        speed × 0.4（背风衰减）
#        方向往两侧旋转 60°，向"左右两侧海拔较低"的那一侧绕（绕山阻力小）
#   ④ 山脊伯努利效应：当前 cell 高于全部 6 邻居 ≥ 0.10 → speed × 1.3
#   ⑤ 海岸热力风：自身陆地、邻居有海洋（白天海风加速）→ speed × 1.15
# 这些系数都是经验值，目的是让 Overlay 显示"风受地形影响"，不必物理精确。
func _compute_terrain_perturbed_wind(map: MapData) -> void:
	if _last_cfg == null:
		return
	# Physical Wind & Ocean Circulation：物理化路径下，cell.wind_vector / wind_speed 已由
	# PhysicalCirculationSolver.solve_wind_field 求出（含纬度基线 + ∇slp 压力梯度风 +
	# 海陆季风 + 科氏偏转 + 山地地形偏转），再叠这一遍经验性"地形扰动"会重复且不一致。
	# 物理化开启时直接 return，保留 hex 求解器结果。
	var profile: ClimateProfile = _c()
	if profile != null and profile.physical_circulation_enabled:
		print("MapGenerator: skip _compute_terrain_perturbed_wind (physical-hex solver writes per-cell)")
		return
	var t0 := Time.get_ticks_msec()
	var cfg_local: MapConfig = _last_cfg
	var perturbed_count: int = 0
	# 预存 6 个 cube 方向的二维"屏幕 dir"，用于"风向 → 上风 hex 邻居"匹配。
	# pointy-top + cube_to_world：方向 0 (E) 与屏幕 +x 对齐，1 (NE) 偏右上等。
	# 这里用 cube_to_world(d.x, d.y, 1.0) 得到方向单位向量，避免硬编码。
	var dir_screen: Array = []  # Array[Vector2]
	dir_screen.resize(HexUtils.CUBE_DIRECTIONS.size())
	for i in range(HexUtils.CUBE_DIRECTIONS.size()):
		var d_v3: Vector3i = HexUtils.CUBE_DIRECTIONS[i]
		var v: Vector2 = HexUtils.cube_to_world(d_v3.x, d_v3.y, 1.0)
		var ln: float = v.length()
		dir_screen[i] = v / ln if ln > 0.0001 else Vector2.RIGHT

	for cell: HexCell in map.all_cells():
		if cell == null:
			continue
		var ny: float = _cube_row_norm(cell, cfg_local)
		var base_dir: Vector2 = WindBeltScript.wind_at(ny, 2.0, 0.0)
		var base_speed: float = WindBeltScript.wind_speed_at(ny, 2.0)

		# ② 海陆摩擦：陆地 0.65；水面 1.0；海冰按陆地处理（雪面也粗糙）
		var is_water_cell: bool = _is_water(cell.terrain)
		var is_sea_ice: bool = cell.terrain == TerrainType.TERRAIN.SEA_ICE
		var friction: float = 1.0
		if is_sea_ice:
			friction = 0.7
		elif not is_water_cell:
			friction = 0.65
		var spd: float = base_speed * friction
		var dir: Vector2 = base_dir

		# ③/④/⑤ 需要 6 邻居 elevation；按方向 idx 拿（缺失邻居用当前 cell 自身海拔代替）
		var nb_elev: PackedFloat32Array = PackedFloat32Array()
		nb_elev.resize(6)
		var nb_cells: Array = []
		nb_cells.resize(6)
		for k in range(6):
			var dk: Vector3i = HexUtils.CUBE_DIRECTIONS[k]
			var nb: HexCell = map.get_cell_by_cube(
				Vector3i(cell.q + dk.x, cell.r + dk.y, cell.s + dk.z)
			)
			nb_cells[k] = nb
			nb_elev[k] = nb.elevation if nb != null else cell.elevation

		# ③ 山脉上风阻挡：选与"风向反方向"夹角最小的 hex 邻居作为上风邻居
		var upwind_idx: int = 0
		var best_dot: float = -INF
		var minus_dir: Vector2 = -dir.normalized() if dir.length() > 0.0001 else Vector2.LEFT
		for k in range(6):
			var ds: Vector2 = dir_screen[k]
			var dot_k: float = ds.dot(minus_dir)
			if dot_k > best_dot:
				best_dot = dot_k
				upwind_idx = k
		var upwind_elev: float = nb_elev[upwind_idx]
		var elev_diff: float = upwind_elev - cell.elevation
		if elev_diff > 0.15:
			spd *= 0.4
			# 选两个旁侧邻居（左右各一），看哪侧海拔更低就往哪侧绕
			var left_idx: int = (upwind_idx + 5) % 6  # 上风的"左前方"对应的下风方向
			var right_idx: int = (upwind_idx + 1) % 6
			# 实际下风方向 = -upwind_dir；其旁侧 = downwind_idx ±1
			var downwind_idx: int = (upwind_idx + 3) % 6
			var dn_left: int = (downwind_idx + 5) % 6
			var dn_right: int = (downwind_idx + 1) % 6
			# 旁侧 elev 越低，风越倾向往那侧绕
			var bend_sign: float = 0.0
			if nb_elev[dn_left] < nb_elev[dn_right] - 0.02:
				bend_sign = -1.0
			elif nb_elev[dn_right] < nb_elev[dn_left] - 0.02:
				bend_sign = 1.0
			# 旋转 ~50° 模拟绕流
			if bend_sign != 0.0:
				dir = dir.rotated(bend_sign * 0.87)  # ~50°
			# 不重新归一（保留方向语义；速度已被 0.4 衰减）
			# 仅在 left_idx/right_idx 没用到时消耗，规避 GDScript 未使用变量警告
			var _u: int = left_idx + right_idx

		# ④ 山脊加速：当前 cell elevation 高于所有邻居 ≥ 0.10
		var is_ridge: bool = true
		for k in range(6):
			if cell.elevation - nb_elev[k] < 0.10:
				is_ridge = false
				break
		if is_ridge:
			spd *= 1.3

		# ⑤ 海岸热力风：陆地 + 至少一个海洋邻居
		if not is_water_cell:
			var has_sea_neighbor: bool = false
			for k in range(6):
				var nbc: HexCell = nb_cells[k]
				if nbc != null and _is_water(nbc.terrain):
					has_sea_neighbor = true
					break
			if has_sea_neighbor:
				spd *= 1.15

		# 写入：dir 已 normalize（来自 wind_at），最终向量长度 = 速度
		var final_dir: Vector2 = dir
		var ln_d: float = final_dir.length()
		if ln_d > 0.0001:
			final_dir = final_dir / ln_d
		else:
			final_dir = Vector2(1.0, 0.0)
		cell.wind_vector = final_dir * spd
		perturbed_count += 1

	print("MapGenerator: terrain-perturbed wind for %d cells in %dms"
			% [perturbed_count, Time.get_ticks_msec() - t0])

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
	# Emergent Climate Coupling：确保 refresh_climate_daily 能取到最新 world
	_last_world = world
	_current_season = season_idx
	var season := clampi(season_idx, 0, 3)
	# 任务 6（方案 C）：缓存 cfg 到 local var，避免 per-cell 多次访问字段；
	# 一次性建立行级温度查表（lat_temp + season_off），主循环 5 处全图遍历复用。
	var cfg_local: MapConfig = _last_cfg
	_ensure_row_tables(cfg_local, season)
	var lat_tab: PackedFloat32Array = _row_lat_temp
	var off_tab: PackedFloat32Array = _row_season_off

	# 1) 复位湿度到年均基线（pre-rain-shadow） + 全局季节缩放
	var moist_scale: float = _c().seasonal_moisture_scale[season]
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			cell.moisture = cell.base_moisture
		else:
			cell.moisture = clampf(cell.base_moisture * moist_scale, 0.0, 1.0)

	# 2) 雨影（Phase 6：每 cell 用自己纬度的风向 + 当季的 season_phase 决定季风偏置）
	# season_phase 用季节中段 → spring=0.5 / summer=1.5 / autumn=2.5 / winter=3.5
	_apply_rain_shadow_per_cell(map, cfg_local, float(season) + 0.5)

	# 3) 重决策"非永久"地形
	# 任务 6（方案 C）：把 _compute_temperature(ny, elev) 拆成"行级 lat_temp 查表
	# - elev*0.5 然后 clamp"，省掉 per-cell 一次 pow+cos+三角；同时 _season_temp_offset
	# 也走查表。
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
		var r_idx: int = _cube_to_row(cell, cfg_local)
		var lat_temp: float = lat_tab[r_idx]
		var temp_year: float = clampf(lat_temp - cell.elevation * 0.5, 0.0, 1.0)
		var temp_now: float = clampf(temp_year + off_tab[r_idx], 0.0, 1.0)
		var new_terrain := _decide_terrain(cell.elevation, temp_now, cell.moisture, cfg_local)
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

	# 4.75) Systemic Ocean Currents：洋流烘焙已迁移到 SUS OceanCurrentsJob
	# （sliced-update-scheduler 任务 4：接入点 ① + ③）。每日由
	# main.gd._on_day_changed → MapGenerator.sus_tick_daily 驱动逐日切片，
	# 不再在 refresh_seasonal 内一次性大块重烘。这里**显式留空**，作为该
	# 设计变更的代码注脚。
	#
	# 历史代码（已移除）：
	#   var ocean_stride := maxi(1, _c().ocean_current_refresh_seasons)
	#   if season_idx == 0 or (season_idx % ocean_stride) == 0:
	#       _baker.rebake_ocean_currents(map, world, _last_hex_size, _last_cfg, float(season) + 0.5)
	#       _compute_ocean_currents(map, world, _last_hex_size)

	# 4.8) Emergent Climate Coupling：海冰季节性演进已由 _apply_sea_ice_daily_pass
	# 在 refresh_climate_daily 末尾逐日推进（连续浮点覆盖率 + terrain 迟滞翻转）。
	# 路线 A：已删除旧的季首统一切换 pass，保留单一真值源。

	# 5) 写 current_state（玩法层 hook）+ Phase 8：push biome_history / vegetation_history
	# Milestone 1：per-cell 同步 landform / vegetation / cover 三轴，用当季 snow_cover
	# 任务 6（方案 C）：温度查表化（lat_tab + off_tab），cfg 用 cfg_local。
	for cell: HexCell in map.all_cells():
		var r_idx2: int = _cube_to_row(cell, cfg_local)
		var lat_temp2: float = lat_tab[r_idx2]
		var temp_year2: float = clampf(lat_temp2 - cell.elevation * 0.5, 0.0, 1.0)
		var temp_now2: float = clampf(temp_year2 + off_tab[r_idx2], 0.0, 1.0)
		var land_h: float = (cell.elevation - cfg_local.sea_level) / maxf(1.0 - cfg_local.sea_level, 0.001)
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
		_sync_axes_for_cell(cell, cfg_local, snow_cover)
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

	# 6.5) Emergent Climate Coupling：消费并衰减反馈缓冲
	# 把本季累积的 soil_moisture / vegetation_growth_pressure 以很小的权重
	# 融入 base_moisture（长期慢量漂移），然后乘以 feedback_decay 衰减，
	# 让"连下三个月雨"能缓慢抬升湿润基线，而孤立一天的雨几乎不改变长期态。
	var cp_fb := _c()
	if cp_fb != null and bool(cp_fb.fast_slow_layering_enabled):
		_consume_feedback_buffers(map, cp_fb.feedback_decay)

	# 7) 季节切换"刚发生"的同一帧，立刻用连续 phase 把 current_state 从"季中段值"
	# 修正为"季首相位值"，保证逐日刷新接管后不会出现回跳。仅在开关开启时执行；
	# 关闭时维持旧整数硬切语义（兼容回退）。
	var cp_now := _c()
	if cp_now != null and cp_now.daily_climate_interpolation:
		# season_changed 通常在某日清晨触发；此时 phase 刚跨过 season_idx 整数边界
		refresh_climate_daily(map, float(season))

# ─── Emergent Climate Coupling：消费反馈缓冲（季末一次） ───────────────
# 调用时机：refresh_seasonal 尾部，每季一次。
# 行为：
#   1) base_moisture 漂移：按 soil_moisture 当前值 × FEEDBACK_SOIL_TO_BASE_W（0.15）
#      累加到 base_moisture（clamp 0..1），模拟"长期土壤湿度抬升湿润基线"。
#   2) 两个反馈字段都乘以 decay（默认 0.5）衰减，保留半数跨季记忆，避免无限累积。
func _consume_feedback_buffers(map: MapData, decay: float) -> void:
	var FEEDBACK_SOIL_TO_BASE_W: float = 0.15
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		if absf(cell.soil_moisture) > 1e-4:
			cell.base_moisture = clampf(cell.base_moisture + FEEDBACK_SOIL_TO_BASE_W * cell.soil_moisture, 0.0, 1.0)
		cell.soil_moisture *= decay
		cell.vegetation_growth_pressure *= decay

# ─── 逐日连续气候刷新（Seasonal Continuous Climate） ─────────────────────
# 由 main.gd 的 _on_day_changed 触发，**每日**用连续 season_phase ∈ [0, 4)
# 重写每个 cell 的 current_state.temperature / moisture / snow_cover，让玩家
# 在面板上看到逐日渐进的换季变化，而不再是季首一次性硬切。
#
# 设计要点（与需求文档 seasonal-continuous-climate/requirements.md 对齐）：
# - **不**调用 _decide_terrain（地形决策仍归 refresh_seasonal 一季一次，避免 biome 抖动）
# - **不**重跑雨影 / 植被反馈 / shrubland / mangrove / glacier / swamp / sea_ice
# - **不**调用 _baker.rebake_*（GPU tex 仅在 season_changed 重烘；视觉层连续过渡靠
#   shader 用 season_phase uniform 实时插值）
# - 仅写 current_state 中的连续标量字段，不动 cell.terrain / cell.moisture（长期态）
# - 严格守卫：开关关闭 / _last_cfg 缺失 / climate_profile 缺失 → 直接 return
func refresh_climate_daily(map: MapData, season_phase: float) -> void:
	if map == null:
		return
	var cp := _c()
	if cp == null or _last_cfg == null:
		return
	if not cp.daily_climate_interpolation:
		return  # 兼容回退路径：开关 false 时维持旧"季首硬切"行为

	# Daily Sim SoA Refactor 方向 X：refresh_climate_daily 现在只是 wrapper，
	# 串联调用 6 个独立 sub-pass。SUS RefreshClimateDailyJob 切片化路径会绕过
	# 本 wrapper，改为按 _pass_cursor 逐 tick 调用对应 sub-pass，把单 tick 的
	# ~80ms 切到 5-6 个 tick 上。其他历史/非切片调用方继续走 wrapper。
	var t0: int = Time.get_ticks_msec()
	var local_coupling: bool = bool(cp.enable_local_climate_coupling)

	# Pass A：基线 temp/moisture/snow_cover + EMA。
	var t_pass_a_us0: int = Time.get_ticks_usec()
	_climate_pass_a(map, season_phase)
	var t_pass_a_ms: float = (Time.get_ticks_usec() - t_pass_a_us0) / 1000.0

	# Pass B：局部气候耦合（受开关控）。
	var t_pass_b_ms: float = 0.0
	if local_coupling:
		var t_pass_b_us0: int = Time.get_ticks_usec()
		_climate_pass_b(map, season_phase)
		t_pass_b_ms = (Time.get_ticks_usec() - t_pass_b_us0) / 1000.0

	_daily_climate_call_count += 1

	# Ocean heat transport：水段 + 陆段（受主开关控）。
	# 切片化路径会把这两段拆到独立 sub-tick；wrapper 保持串联调用以维持
	# 非切片路径行为不变。
	var t_ocean_ms: float = 0.0
	if _last_cfg.enable_ocean_heat_transport:
		var t_ocean_us0: int = Time.get_ticks_usec()
		_ocean_water_pass(map, season_phase)
		_ocean_land_pass(map, season_phase)
		t_ocean_ms = (Time.get_ticks_usec() - t_ocean_us0) / 1000.0

	# Wind heat transport：气团段 + 地表段（对称复刻洋流热输运）。
	# 受 enable_ocean_heat_transport 开关统一控制（风温耦合与洋流热输运同属物理环流系统）。
	var t_wind_ms: float = 0.0
	if _last_cfg.enable_ocean_heat_transport:
		var t_wind_us0: int = Time.get_ticks_usec()
		_wind_air_mass_pass(map, season_phase)
		_wind_surface_pass(map, season_phase)
		t_wind_ms = (Time.get_ticks_usec() - t_wind_us0) / 1000.0

	# Sea ice：逐日演替 pass（路线 A：单一真值源）。
	var t_sea_ice_us0: int = Time.get_ticks_usec()
	_apply_sea_ice_daily_pass(map, season_phase)
	var t_sea_ice_ms: float = (Time.get_ticks_usec() - t_sea_ice_us0) / 1000.0

	# Daily Sim SoA Refactor 阶段 1：GPU 海冰上传已迁移到 SeaIceAtlasUploadJob；
	# 这里只保留指标字段为 0 占位，main.gd 读取不报错。
	var t_ice_bake_ms: float = 0.0

	# Transpiration：植被→湿度反馈（受开关控）。
	var t_transp_ms: float = 0.0
	if local_coupling:
		var t_transp_us0: int = Time.get_ticks_usec()
		_apply_transpiration_pass(map)
		t_transp_ms = (Time.get_ticks_usec() - t_transp_us0) / 1000.0

	# Daily-sim perf instrumentation：把 7 段子耗时缓存到生成器成员，
	# 由 main.gd 的 fast tick 详细日志 / WARN 路径按需读取。
	_last_climate_breakdown = {
		"pass_a_ms": t_pass_a_ms,
		"pass_b_ms": t_pass_b_ms,
		"ocean_ms": t_ocean_ms,
		"wind_ms": t_wind_ms,
		"sea_ice_ms": t_sea_ice_ms,
		"ice_bake_ms": t_ice_bake_ms,
		"transp_ms": t_transp_ms,
		"total_ms": float(Time.get_ticks_msec() - t0),
		"cells": map.cell_count(),
	}
	if _daily_climate_call_count == 1 or (_daily_climate_call_count % 365) == 0:
		print("refresh_climate_daily #%d: %dms (cells=%d, phase=%.3f) | A=%.1f B=%.1f ocean=%.1f wind=%.1f sea_ice=%.1f ice_bake=%.1f transp=%.1f" % [
			_daily_climate_call_count,
			Time.get_ticks_msec() - t0,
			map.cell_count(),
			season_phase,
			t_pass_a_ms, t_pass_b_ms, t_ocean_ms, t_wind_ms, t_sea_ice_ms, t_ice_bake_ms, t_transp_ms,
		])

# ─── Daily Sim SoA Refactor 方向 X：sub-pass API ──────────────────────────
# 把 refresh_climate_daily 内部拆成可独立调用的 6 个 sub-pass，供 SUS
# RefreshClimateDailyJob 按 _pass_cursor 切片调用。每段都是"读字段 → 写字段"
# 的纯函数：跨 sub-tick 之间靠 HexCell 已稳定的字段做数据交接，不依赖局部
# Dictionary 缓存，因此天然支持跨 tick 切片。
#
# 顺序约束（必须严格按下方顺序调用）：
#   1) _climate_pass_a       — 写 temperature/moisture/snow_cover/EMA（裸基线）
#   2) _climate_pass_b       — 局部气候耦合（可选，受 enable_local_climate_coupling）
#   3) _ocean_water_pass     — 水段（可选，受 enable_ocean_heat_transport）
#   4) _ocean_land_pass      — 陆段（可选，必须紧跟水段）
#   5) _wind_air_mass_pass   — 气团段（可选，受 enable_ocean_heat_transport）
#   6) _wind_surface_pass    — 地表段（可选，必须紧跟气团段）
#   7) _apply_sea_ice_daily_pass — 海冰演替（必跑）
#   8) _apply_transpiration_pass — 植被→湿度反馈（可选，与 Pass B 同开关）

# Daily Sim SoA Refactor 方向 X：Pass A — 全 cell 写"裸基线 temp/moisture/
# snow_cover + EMA"。读 cell.elevation/base_moisture/terrain（稳定字段），
# 写 cell.temperature / moisture / snow_cover / temp_baseline / temp_season_offset
# / temp_30d_mean / temp_365d_mean / temp_dev_from_annual。
func _climate_pass_a(map: MapData, season_phase: float) -> void:
	var cp := _c()
	if cp == null or _last_cfg == null:
		return

	# Fast-tick perf opt (C)：首次进入 fast-tick 主路径时做两件事——
	#   1) 打一次启动日志，便于运行时确认主路径已切到强类型成员；
	#   2) 对所有 cell 做一次 _migrate_typed_fields_from_dict 兜底，把残留在
	#      current_state 字典里的旧字段（旧存档/调试流程产生）一次性搬到强类型成员，
	#      避免双写双读。新代码永远不写这些键，所以只需 boot 一次即可。
	if not _typed_fields_migrated:
		_typed_fields_migrated = true
		print("[fastpath] HexCell typed fields active")
		for cell: HexCell in map.all_cells():
			cell._migrate_typed_fields_from_dict()

	# True Insolation-Driven（Phase F）：首次进入 insolation 主路径时打一次启动日志。
	if cp.true_insolation_enabled and not _insol_driven_path_logged:
		var subsolar_deg: float = rad_to_deg(_subsolar_lat_rad(season_phase))
		var equator_mean: float = _insolation_annual_mean(0.5)
		print("[climate] insolation-driven path active: subsolar_lat=%+.1f°, equator_annual_mean=%.3f, tilt=%.1f°" % [
			subsolar_deg, equator_mean, float(cp.axial_tilt_deg)
		])
		_insol_driven_path_logged = true

	# 1) 当日连续湿度倍率（相邻两季 seasonal_moisture_scale 线性插值）
	var moist_scale_now: float = DataOverlayBaker._moisture_scale_at_phase(cp, season_phase)
	# 2) 派生当日"季节中点"整数索引（写回 current_state.season，供下游消费者用）
	var season_idx: int = int(floor(fposmod(season_phase, 4.0))) & 3

	for cell: HexCell in map.all_cells():
		# —— 守卫：current_state 为空 dict（旧存档）→ 先建好骨架，避免下游读到空键 ——
		if cell.current_state == null or cell.current_state.is_empty():
			cell.current_state = {
				"season": season_idx,
				"temperature": 0.0,
				"moisture": cell.base_moisture,
				"snow_cover": 0.0,
				"biome": int(cell.terrain),
				"landform": int(cell.landform),
				"vegetation": int(cell.vegetation),
				"cover": int(cell.cover),
			}

		# —— 1) 当日湿度（陆地按当日连续倍率缩放，水体保持基线） ——
		# True Insolation-Driven（Phase F）：在 moist_scale_now 全局倍率之上叠加
		# 按纬度涌现的 (1 + 0.2 * insol_dev) 调制——赤道 dev≈0 → 几乎不变、
		# 高纬 dev 绝对值大 → 夏湿冬干差异放大。开关关闭时保持 legacy 纯查表行为。
		var ny: float = _cube_row_norm(cell, _last_cfg)
		var moisture_now: float
		if _is_water(cell.terrain):
			moisture_now = cell.base_moisture
		else:
			var scale_eff: float = moist_scale_now
			if bool(cp.true_insolation_enabled):
				var dev_moist: float = _insol_dev(ny, season_phase)
				scale_eff *= (1.0 + 0.2 * dev_moist)
			moisture_now = clampf(cell.base_moisture * scale_eff, 0.0, 1.0)

		# —— 2) 当日温度（连续 phase 余弦曲线，与 shader season_temp_offset 同公式） ——
		var temp_year: float = _compute_temperature(ny, cell.elevation)
		# True Insolation-Driven（Phase F）：优先走 insolation 派生路径；回退到 legacy 余弦。
		var season_offset: float
		if bool(cp.true_insolation_enabled):
			season_offset = _insolation_season_offset(ny, season_phase)
		else:
			season_offset = _season_temp_offset_phase(ny, season_phase)
		var temp_now: float = clampf(temp_year + season_offset, 0.0, 1.0)

		# —— 3) 当日雪盖（双段公式与 refresh_seasonal 严格一致；永久态特例处理） ——
		var snow_cover: float = 0.0
		if not _is_water(cell.terrain):
			if cell.terrain == TerrainType.TERRAIN.SNOW:
				snow_cover = 1.0  # 永久 SNOW biome 上限不变（需求 3.3）
			else:
				var land_h: float = (cell.elevation - _last_cfg.sea_level) / maxf(1.0 - _last_cfg.sea_level, 0.001)
				if temp_now < 0.18:
					snow_cover = clampf((0.18 - temp_now) / 0.14, 0.0, 1.0) * 0.85
				elif land_h > 0.45 and temp_now < 0.30:
					var t1 := clampf((0.30 - temp_now) / 0.20, 0.0, 1.0)
					var t2 := smoothstep(0.45, 0.85, land_h)
					snow_cover = t1 * t2
				# GLACIER cover：保留 0.80 下限（半永久冰川不会因日级温升彻底融光，需求 3.3）
				if cell.cover == CoverType.CV.GLACIER:
					snow_cover = maxf(snow_cover, 0.80)

		# —— 4) 写回 current_state（只更新连续字段，biome/landform/vegetation/cover 由 refresh_seasonal 维护） ——
		# Fast-tick perf opt (C)：temperature / moisture / snow_cover / temp_baseline /
		# temp_season_offset / temp_30d_mean / temp_365d_mean / temp_dev_from_annual 已
		# 升级为 HexCell 的强类型成员，这里直接赋值，不再走 current_state 字典路径，
		# 显著减少 GDScript 字典 hash 查找 + Variant 装箱开销。
		cell.current_state["season"] = season_idx
		cell.temperature = temp_now
		cell.moisture = moisture_now
		cell.snow_cover = snow_cover
		cell.temp_baseline = temp_year
		cell.temp_season_offset = season_offset

		# —— 5) True Insolation-Driven：温度 EMA（30 日 / 365 日）用于"观测月份"面板派生 ——
		# α_30 ≈ 1/30、α_365 ≈ 1/365；首次出现时用 temp_now 初始化避免长尾收敛拖影。
		# Fast-tick perf opt (C)：用 < 0 哨兵判"首次"，现在改用独立 bool 标志——
		# temp_30d_mean / temp_365d_mean 默认 0.0 是合法气候值，不能靠值域判"未初始化"。
		# 这里用 cell._ema_initialized 作为一次性标志。
		var m30: float
		var m365: float
		if not cell._ema_initialized:
			m30 = temp_now
			m365 = temp_now
			cell._ema_initialized = true
		else:
			m30 = lerpf(cell.temp_30d_mean, temp_now, 1.0 / 30.0)
			m365 = lerpf(cell.temp_365d_mean, temp_now, 1.0 / 365.0)
		cell.temp_30d_mean = m30
		cell.temp_365d_mean = m365
		cell.temp_dev_from_annual = m30 - m365

# Daily Sim SoA Refactor 方向 X：Pass B — 局部气候耦合。
# 调用方负责守卫 enable_local_climate_coupling 开关。winter_boost 从 season_phase
# 派生（与 Pass A 中算法一致），避免跨 sub-tick 传 winter_boost 状态。
func _climate_pass_b(map: MapData, season_phase: float) -> void:
	var cp := _c()
	if cp == null or _last_cfg == null:
		return
	# 冬季加成（与 _apply_ocean_heat_transport_pass 同源）：用于沿岸热泄漏在冬季 ×1.5
	var phase_mod: float = fposmod(season_phase, 4.0)
	var dist_to_winter: float = minf(absf(phase_mod - 3.0), minf(absf(phase_mod - 3.0 + 4.0), absf(phase_mod - 3.0 - 4.0)))
	var winter_boost: float = lerpf(cp.coastal_heat_leak_winter_boost, 1.0, clampf(dist_to_winter, 0.0, 1.0))
	_apply_local_climate_coupling_pass(map, season_phase, winter_boost)

# ─── Emergent Climate Coupling：本地温度/湿度耦合 pass ──────────────────
# 在 refresh_climate_daily 的"裸基线"之上叠加：
#   温度三项：① 反照率扰动（雪/植被冷却）② 沿岸热泄漏 ③ 地形扰动（山谷/盆地日变幅）
#   湿度三项：① 蒸发项（暖日水邻居）② 雨影项（当日 WindBelt 风向）③ （植被蒸腾在外部 pass）
# 该 pass 只更新 cell.current_state.temperature / moisture，不动 base_*。
# 受 ClimateProfile.enable_local_climate_coupling 控制；关闭时调用方应跳过。
func _apply_local_climate_coupling_pass(map: MapData, season_phase: float, winter_boost: float) -> void:
	var cp := _c()
	if cp == null or _last_cfg == null:
		return

	# 常量缓存
	var coast_leak: float = float(_last_cfg.COASTAL_HEAT_LEAK)
	var snow_cool: float = float(cp.snow_albedo_cooling)
	var veg_cool: float = float(cp.vegetation_cooling)
	var diurnal_amp: float = float(cp.landform_diurnal_amp)
	var evap_gain: float = float(cp.evaporation_gain)
	var rs_threshold: float = float(cp.rain_shadow_threshold)
	var rs_factor: float = float(cp.rain_shadow_factor)
	var rs_lookback: int = max(0, int(cp.rain_shadow_lookback))
	# 地形日变幅在夏中段（phase=1）最强，冬中段（phase=3）最弱
	var phase_mod: float = fposmod(season_phase, 4.0)
	var landform_phase_factor: float = (cos((phase_mod - 1.0) * 0.5 * PI) + 1.0) * 0.5  # ∈ [0, 1]

	# 把当前快层温度先快照一份，避免 1 环采样被半途覆盖
	# Fast-tick perf opt (C)：temperature 已是 HexCell 强类型成员，直接读。
	var temp_snapshot: Dictionary = {}
	for cell: HexCell in map.all_cells():
		temp_snapshot[cell] = cell.temperature

	# Daily-Sim SoA Refactor 阶段 2：抓底层邻居索引数组（fast-tick 内联用）。
	var nb_idx_arr: PackedInt32Array = map.neighbor_indices_packed()
	var has_idx: bool = map.has_indices()

	# 按 cell 应用三项温度 + 三项湿度（其一在外部 transpiration pass）
	for cell: HexCell in map.all_cells():
		var temp_now: float = temp_snapshot[cell]
		# Fast-tick perf opt (C)：moisture / snow_cover 已升级为强类型成员。
		var moisture_now: float = cell.moisture
		var snow_cover: float = cell.snow_cover

		var d_albedo: float = 0.0
		var d_coastal: float = 0.0
		var d_landform: float = 0.0
		var d_evap: float = 0.0
		var d_rain_shadow: float = 1.0  # 倍率项

		var is_water: bool = _is_water(cell.terrain)

		# ① 反照率扰动（仅陆地）：雪盖 → 反射阳光更冷；密集植被 → 蒸腾遮阴更凉
		if not is_water:
			d_albedo = -snow_cool * snow_cover
			# 植被冷却：MILESTONE 1 三轴 vegetation 不直接拿数值，用粗略分级：
			# 茂密植被（FOREST/JUNGLE/SWAMP/TAIGA） → 全冷却；草原/灌木 → 一半；其他 → 0
			var foliage: float = _vegetation_foliage_density(cell.vegetation)
			d_albedo -= veg_cool * foliage

		# ② 沿岸热泄漏：陆地 cell 邻居中暖流水体的 anomaly 注入；水体也得到邻居 cross-mix（弱）
		if not is_water:
			var sum_anomaly: float = 0.0
			var n_water: int = 0
			# Daily-Sim SoA Refactor 阶段 2：通过 _neighbor_indices 直接索引，
			# 避开 get_neighbors() 每次新建 6-元 Array 的 GC 压力。
			if has_idx:
				var ci: int = map.index_of(cell)
				if ci >= 0:
					var base: int = ci * 6
					for d in range(6):
						var ni: int = nb_idx_arr[base + d]
						if ni == -1:
							continue
						var nb: HexCell = map.cell_at(ni)
						if nb != null and _is_water(nb.terrain):
							sum_anomaly += nb.temperature_transport_anomaly
							n_water += 1
			else:
				for nb: HexCell in map.get_neighbors(cell):
					if nb != null and _is_water(nb.terrain):
						sum_anomaly += nb.temperature_transport_anomaly
						n_water += 1
			if n_water > 0:
				var avg_anomaly: float = sum_anomaly / float(n_water)
				d_coastal = coast_leak * avg_anomaly * winter_boost

		# ③ 地形扰动：山谷/盆地（LOWLAND / SALT_FLAT / DELTA）日变幅放大；高山反相变冷
		# 此处取"全日均值"作为代理：盆地夏天偏热、冬天偏冷；用 landform_phase_factor 调制
		if not is_water:
			var lf: int = cell.landform
			if lf == LandformType.LF.LOWLAND or lf == LandformType.LF.SALT_FLAT or lf == LandformType.LF.DELTA:
				# 夏季升温更猛，冬季降温更猛 → 用 (phase_factor*2-1) 表示 ±幅度
				var dir_factor: float = landform_phase_factor * 2.0 - 1.0
				d_landform = diurnal_amp * dir_factor
			elif lf == LandformType.LF.PEAK or lf == LandformType.LF.MOUNTAIN:
				# 高峰：永远更冷一些，但夏季冷却减弱（融雪季）
				d_landform = -diurnal_amp * 0.5 * (1.0 - landform_phase_factor)

		# 写回温度
		var temp_final: float = clampf(temp_now + d_albedo + d_coastal + d_landform, 0.0, 1.0)
		# Fast-tick perf opt (C)：直写强类型成员。
		cell.temperature = temp_final

		# 调试：仅当 cell.temperature_breakdown 已被 UI 选中初始化为非空字典时才更新
		# （避免每帧为整张地图分配字典）
		if not cell.temperature_breakdown.is_empty():
			cell.temperature_breakdown["baseline"] = cell.temp_baseline
			cell.temperature_breakdown["season"] = cell.temp_season_offset
			cell.temperature_breakdown["albedo"] = d_albedo
			cell.temperature_breakdown["coastal"] = d_coastal
			cell.temperature_breakdown["landform"] = d_landform

		# ④ 蒸发项（湿度）：陆地 cell 邻居中有暖水时，按温差为本格补湿
		#    Ocean-current → moisture coupling (寒流海岸沙漠通路)：
		#    - 暖流邻水 (anomaly > 0)  → 提升 d_evap（更暖的海更易蒸发）
		#    - 寒流邻水 (anomaly < 0)  → 衰减 d_evap，并叠加一项负向 d_evap_cold
		#                                 直接抑制本格 moisture（模拟冷海面下沉空气
		#                                 抑制对流，类似 Atacama / Namib）。
		if not is_water:
			var t_eff: float = temp_final + cell.temperature_transport_anomaly
			var t_freeze: float = float(cp.sea_ice_form_threshold)
			# 邻水统计：count + 平均 anomaly（无论 t_eff 是否过 freeze 都需要）
			var water_neighbor_w: float = 0.0
			var sum_water_anomaly: float = 0.0
			# Daily-Sim SoA Refactor 阶段 2：邻居计数走索引数组。
			if has_idx:
				var ci2: int = map.index_of(cell)
				if ci2 >= 0:
					var base2: int = ci2 * 6
					for d2 in range(6):
						var ni2: int = nb_idx_arr[base2 + d2]
						if ni2 == -1:
							continue
						var nb2: HexCell = map.cell_at(ni2)
						if nb2 != null and _is_water(nb2.terrain):
							water_neighbor_w += 1.0
							sum_water_anomaly += nb2.temperature_transport_anomaly
			else:
				for nb: HexCell in map.get_neighbors(cell):
					if nb != null and _is_water(nb.terrain):
						water_neighbor_w += 1.0
						sum_water_anomaly += nb.temperature_transport_anomaly
			var avg_water_anomaly: float = 0.0
			if water_neighbor_w > 0.0:
				avg_water_anomaly = sum_water_anomaly / water_neighbor_w
			water_neighbor_w = clampf(water_neighbor_w / 6.0, 0.0, 1.0)
			# 正向蒸发（仅当 t_eff 越过冰点）
			if t_eff > t_freeze and water_neighbor_w > 0.0:
				d_evap = evap_gain * (t_eff - t_freeze) * water_neighbor_w
				# 洋流耦合乘数：暖流 → > 1.0、寒流 → < 1.0；clamp 防过度
				var coupling_gain: float = float(cp.ocean_moisture_coupling_gain)
				if coupling_gain > 0.0 and absf(avg_water_anomaly) > 0.001:
					var evap_mul: float = clampf(1.0 + coupling_gain * avg_water_anomaly, 0.0, 2.0)
					d_evap *= evap_mul
			# 寒流海岸沙漠通路：当邻水洋流 anomaly 显著为负，直接对本格
			# moisture 施加额外衰减项 d_evap_cold（与 d_evap 叠加但符号永远 ≤ 0）。
			# 强度按邻水占比缩放——半岛 (water_w → 1) 受抑制最强，远岸内陆为 0。
			# 不影响海上 cell；与 t_freeze 判断解耦——即使被冰封的海面也能向陆地
			# 输送"冷干空气"。
			if avg_water_anomaly < -0.01 and water_neighbor_w > 0.0:
				var coupling_gain2: float = float(cp.ocean_moisture_coupling_gain)
				if coupling_gain2 > 0.0:
					# evap_gain × |anomaly| × water_w × coupling_gain × 0.5
					# 0.5 系数让"直接衰减项"略小于"乘性抑制"，避免双重惩罚过头
					d_evap += -evap_gain * (-avg_water_anomaly) * water_neighbor_w * coupling_gain2 * 0.5

		# ⑤ 雨影项（湿度）：背风坡用当日 WindBelt 风向衡量
		if not is_water and rs_lookback > 0:
			var ny: float = _cube_row_norm(cell, _last_cfg)
			# 风向带轻微 jitter，与 _apply_rain_shadow_per_cell 同源
			var jitter: float = sin(float(cell.q) * 0.31 + float(cell.r) * 0.47) * 0.05
			var wind: Vector2 = WindBeltScript.wind_at(ny, season_phase, jitter)
			if wind.length_squared() > 1e-6:
				var max_upwind_h: float = cell.elevation
				var w_dir: Vector2 = wind.normalized()
				var self_wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _last_hex_size)
				# 沿 -w_dir 方向逐步采样上风邻居（最对齐者）
				var probe: HexCell = cell
				for step in range(rs_lookback):
					var best_nb: HexCell = null
					var best_dot: float = 0.1
					var pwp: Vector2 = HexUtils.cube_to_world(probe.q, probe.r, _last_hex_size)
					# Daily-Sim SoA Refactor 阶段 2：通过索引数组取邻居，避免每
					# step 创建 6-元 Array。
					if has_idx:
						var pi: int = map.index_of(probe)
						if pi >= 0:
							var pbase: int = pi * 6
							for d3 in range(6):
								var ni3: int = nb_idx_arr[pbase + d3]
								if ni3 == -1:
									continue
								var nb3: HexCell = map.cell_at(ni3)
								if nb3 == null:
									continue
								var nbwp: Vector2 = HexUtils.cube_to_world(nb3.q, nb3.r, _last_hex_size)
								var d: Vector2 = (pwp - nbwp)
								if d.length_squared() < 1e-6:
									continue
								var dotv: float = d.normalized().dot(w_dir)
								if dotv > best_dot:
									best_dot = dotv
									best_nb = nb3
					else:
						for nb2: HexCell in map.get_neighbors(probe):
							if nb2 == null:
								continue
							var nbwp: Vector2 = HexUtils.cube_to_world(nb2.q, nb2.r, _last_hex_size)
							var d: Vector2 = (pwp - nbwp)
							if d.length_squared() < 1e-6:
								continue
							var dotv: float = d.normalized().dot(w_dir)
							if dotv > best_dot:
								best_dot = dotv
								best_nb = nb2
					if best_nb == null:
						break
					probe = best_nb
					if probe.elevation > max_upwind_h:
						max_upwind_h = probe.elevation
				if max_upwind_h - cell.elevation >= rs_threshold:
					d_rain_shadow = rs_factor

		# 写回湿度
		var moisture_final: float = clampf((moisture_now + d_evap) * d_rain_shadow, 0.0, 1.0)
		# Fast-tick perf opt (C)：moisture 已升级为强类型成员，直写。
		cell.moisture = moisture_final

# 植被茂密度估计（仅供 albedo / 蒸腾系数使用），单位 [0, 1]。
# 直接使用 VegetationType.transpiration() 作为代理：森林/雨林蒸腾高 → 茂密；
# 草原/灌木中等；裸地/沙漠/苔原接近 0。这样不依赖任何特定枚举名，
# 即使日后扩充 VEG 枚举也无需改这里。
func _vegetation_foliage_density(veg: int) -> float:
	var trans: float = VegetationType.transpiration(veg)
	# transpiration 的常见取值范围 [0, ~0.06]，归一到 [0, 1]
	return clampf(trans / 0.06, 0.0, 1.0)

# ─── Emergent Climate Coupling：海冰逐日推进 pass ────────────────────────
# 替代旧 _apply_sea_ice_pass 的"统一切换"语义。每日运行一次，对每个水体 cell
# 做 sea_ice_fraction 的增量更新：
#   Δfrac = k_freeze * max(0, T_form - T_eff) - k_melt * max(0, T_eff - T_melt)
#   T_eff = current_state.temperature + OCEAN_CURRENT_ICE_DELAY * max(0, anomaly)
#           - 0.5 * upwelling_strength（若 upwelling > 0.3）
# 并加入"邻居传染"：当 1 环邻居中存在 sea_ice_fraction ≥ 0.6 的水体时，
# 本 cell 的 k_freeze 获得加成（模拟冰盖物理扩张）。
#
# terrain 翻转：
#   sea_ice_fraction ≥ ice_terrain_threshold              → terrain = SEA_ICE
#   sea_ice_fraction <  ice_terrain_threshold - hyst      → terrain = base_terrain
#
# QA 异常守卫：当日 SEA_ICE 翻转 cell 数 > 总水体数 3% 时打印一次 WARN
# （帮助定位"全图统一切换"的回归）。
func _apply_sea_ice_daily_pass(map: MapData, season_phase: float) -> void:
	if map == null or _last_cfg == null:
		return
	var cp := _c()
	if cp == null:
		return

	var t0: int = Time.get_ticks_msec()
	var k_freeze: float = float(cp.sea_ice_freeze_rate)
	var k_melt: float = float(cp.sea_ice_melt_rate)
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var contagion: float = float(cp.sea_ice_neighbor_contagion)
	var threshold: float = float(cp.sea_ice_terrain_threshold)
	var hysteresis: float = float(cp.sea_ice_terrain_hysteresis)
	var ice_delay: float = float(_last_cfg.OCEAN_CURRENT_ICE_DELAY)

	# Pass A：先把每个水体 cell 的"是否有冷邻居"快照（用前一日的 sea_ice_fraction）
	# Daily-Sim SoA Refactor 阶段 2：通过 _neighbor_indices 直接索引，避免每帧
	# 创建 N_water 个 6-元 Array。
	var nb_idx_arr: PackedInt32Array = map.neighbor_indices_packed()
	var has_idx: bool = map.has_indices()
	var has_cold_neighbor: Dictionary = {}
	for cell: HexCell in map.all_cells():
		if not _is_water(cell.terrain):
			continue
		var any_cold: bool = false
		if has_idx:
			var ci: int = map.index_of(cell)
			if ci >= 0:
				var base: int = ci * 6
				for d in range(6):
					var ni: int = nb_idx_arr[base + d]
					if ni == -1:
						continue
					var nb: HexCell = map.cell_at(ni)
					if nb != null and _is_water(nb.terrain) and nb.sea_ice_fraction >= 0.6:
						any_cold = true
						break
		else:
			for nb: HexCell in map.get_neighbors(cell):
				if nb != null and _is_water(nb.terrain) and nb.sea_ice_fraction >= 0.6:
					any_cold = true
					break
		has_cold_neighbor[cell] = any_cold

	var water_count: int = 0
	var flipped_count: int = 0

	for cell: HexCell in map.all_cells():
		if not _is_water(cell.terrain):
			# 非水体 cell 强制保持 0
			cell.sea_ice_fraction = 0.0
			continue
		# LAKE：跳过（淡水冻结留给后续 phase）
		if cell.terrain == TerrainType.TERRAIN.LAKE:
			cell.sea_ice_fraction = 0.0
			continue
		water_count += 1

		# T_eff：当日温度 + 暖流推迟 - 上升流冷却
		# Fast-tick perf opt (C)：temperature 已升级为强类型成员，直接读。
		var temp_now: float = cell.temperature
		var t_eff: float = temp_now
		if _last_cfg.enable_ocean_heat_transport:
			t_eff += ice_delay * maxf(0.0, cell.temperature_transport_anomaly)
			if cell.upwelling_strength > 0.3:
				t_eff -= 0.5 * cell.upwelling_strength
		t_eff = clampf(t_eff, 0.0, 1.0)

		# 邻居传染：若 1 环存在已结冰邻居 → k_freeze ×（1 + contagion）
		var k_freeze_eff: float = k_freeze
		if has_cold_neighbor.get(cell, false):
			k_freeze_eff = k_freeze * (1.0 + contagion)

		# 路线 A（单一真值源）：海冰只看温度，不再乘 dev_ice。
		# 南北半球的"冬冻夏融"差异完全来自温度 Pass（insolation 驱动）：
		#   - 温度 Pass 已让北半球 1 月冷、南半球 7 月冷；
		#   - 这里只需按"当日温度越过阈值 → 结冰/融化"，同温度 → 同命运；
		#   - 避免"日历月份直接决定冻融速率"的相位作弊（#bugfix 同温不同冻）。
		var k_melt_eff: float = k_melt

		# 增量更新：温度低于结冰阈值 → 增长；高于融化阈值 → 衰减
		var delta_freeze: float = k_freeze_eff * maxf(0.0, t_form - t_eff)
		var delta_melt: float = k_melt_eff * maxf(0.0, t_eff - t_melt)
		var d_frac: float = delta_freeze - delta_melt
		var prev_frac: float = cell.sea_ice_fraction
		var new_frac: float = clampf(prev_frac + d_frac, 0.0, 1.0)
		cell.sea_ice_fraction = new_frac

		# terrain 翻转（带迟滞）
		var was_ice: bool = (cell.terrain == TerrainType.TERRAIN.SEA_ICE)
		if not was_ice and new_frac >= threshold:
			# 形成海冰：保留 base_terrain 以便回退（不动 base_terrain 自身）
			cell.apply_terrain(TerrainType.TERRAIN.SEA_ICE)
			flipped_count += 1
		elif was_ice and new_frac < threshold - hysteresis:
			# 融化退出：还原到 base_terrain
			var base: int = int(cell.base_terrain)
			if base == TerrainType.TERRAIN.SEA_ICE:
				cell.apply_terrain(TerrainType.TERRAIN.OCEAN)
			else:
				cell.apply_terrain(base)
			flipped_count += 1

	# QA 异常守卫：当日翻转 > 3% 总水体 → WARN（统一切换的旧回归特征）
	if water_count > 0:
		var ratio: float = float(flipped_count) / float(water_count)
		if ratio > 0.03:
			push_warning("[sea_ice_daily] %d/%d (%.1f%%) cells flipped on phase=%.3f — possible bulk-switch regression" % [
				flipped_count, water_count, ratio * 100.0, season_phase
			])

	# 节流打点（每 365 天打一次）
	if _daily_climate_call_count == 1 or (_daily_climate_call_count % 365) == 0:
		print("_apply_sea_ice_daily_pass: %dms (water=%d, flipped=%d, phase=%.3f)" % [
			Time.get_ticks_msec() - t0, water_count, flipped_count, season_phase
		])

# ─── Systemic Ocean Currents：洋流热输运 pass ─────────────────────────────
# 在几何温度之上叠加一层：
#   Pass 1（水→水）：沿 -ocean_current 回溯最多 OCEAN_HEAT_ADVECT_STEPS 个邻居，
#                  混合上游 current_state.temperature 到本 cell，按 OCEAN_HEAT_MIX 权重。
#                  temperature_transport_anomaly = temp_after_mix - temp_year_at_cell。
#   Pass 2（水→陆）：对每个陆地 cell，按 max(0, dot(邻居方向, 水 cell ocean_current)) 加权
#                   收集相邻水 cell 的 transport_anomaly；按 COASTAL_HEAT_LEAK 注入 current_state.temperature。
#                   冬季相位（|hemi_phase - 3| < 0.5）权重 × 1.5。
#
# 复杂度：O(cells × (ADVECT_STEPS + 6))；默认常量 3 + 6 ≈ 9，轻量。
# 所有几何温度基线使用 _compute_temperature(ny, elevation) 保证与 refresh_climate_daily 一致。
func _apply_ocean_heat_transport_pass(map: MapData, season_phase: float) -> void:
	# Daily Sim SoA Refactor 方向 X：本函数现在只是 wrapper，串联调用拆分后的
	# 水段 + 陆段两个独立 pass。SUS RefreshClimateDailyJob 切片化路径会绕过本
	# wrapper、直接分别调用 _ocean_water_pass / _ocean_land_pass，从而把单 tick
	# 的 ocean ~31ms 切成两半。其他历史/非切片调用方（如手动重算）继续走 wrapper。
	if _last_cfg == null:
		return
	var t0 := Time.get_ticks_msec()
	_ocean_water_pass(map, season_phase)
	_ocean_land_pass(map, season_phase)
	_heat_transport_call_count += 1
	if _heat_transport_call_count == 1 or (_heat_transport_call_count % 365) == 0:
		var phase_mod := fposmod(season_phase, 4.0)
		var dist_to_winter: float = minf(phase_mod, 4.0 - phase_mod)
		var winter_boost: float = lerpf(1.5, 1.0, clampf(dist_to_winter, 0.0, 1.0))
		print("ocean_heat_transport #%d: %dms (cells=%d, phase=%.3f, winter_boost=%.2f)" % [
			_heat_transport_call_count,
			Time.get_ticks_msec() - t0,
			map.cell_count(),
			season_phase,
			winter_boost,
		])

# Daily Sim SoA Refactor 方向 X（A2）：洋流热输运的"水段"——
# 水 cell 沿 -ocean_current 回溯 advect_steps 步、与上游水 cell 温度做 lerp 混合，
# 写回 cell.temperature 与 cell.temperature_transport_anomaly。
# 此函数与 _ocean_land_pass 之间存在严格因果依赖：陆段必须读到水段已写完
# 的 temperature_transport_anomaly。两段之间允许跨 tick 切片，因为水段写完
# 后 cell 字段就稳定了。
func _ocean_water_pass(map: MapData, season_phase: float) -> void:
	if _last_cfg == null:
		return
	var advect_steps: int = max(0, _last_cfg.OCEAN_HEAT_ADVECT_STEPS)
	var heat_mix: float = clampf(_last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0)
	# 基线温度缓存（per-cell 的 temp_year_at_cell，用于算 anomaly）。
	# Fast-tick perf opt (C) 之后 cell.temp_baseline 在 Pass A 已经写过等值
	# 数据，但 _ocean_water_pass 也可能从非切片 wrapper 直接进入（refresh
	# 顺序变化时），所以这里独立重算一次，保证健壮。
	var baseline: Dictionary = {}
	for cell: HexCell in map.all_cells():
		var ny: float = _cube_row_norm(cell, _last_cfg)
		baseline[cell] = _compute_temperature(ny, cell.elevation)

	# Daily-Sim SoA Refactor 阶段 2：抓底层邻居索引数组（两个 Pass 共用）。
	var nb_idx_arr: PackedInt32Array = map.neighbor_indices_packed()
	var has_idx: bool = map.has_indices()
	# 先把所有水 cell 的当前 current_state.temperature 拷贝出来（避免半途被覆盖）
	# Fast-tick perf opt (C)：temperature 已升级为强类型成员，直接读。
	var water_temp_before: Dictionary = {}
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			water_temp_before[cell] = cell.temperature if cell.temperature > 0.0 else float(baseline[cell])

	for cell: HexCell in map.all_cells():
		if not _is_water(cell.terrain):
			continue
		var cur: Vector2 = cell.ocean_current
		if cur.length_squared() < 1e-6 or advect_steps == 0:
			cell.temperature_transport_anomaly = 0.0
			continue
		# 沿 -cur 方向回溯 advect_steps 步，每步选最对齐的水邻居
		var upstream: HexCell = cell
		var upstream_dir: Vector2 = -cur.normalized()
		for step in range(advect_steps):
			var best_nb: HexCell = null
			var best_dot: float = 0.1  # 需要最低对齐阈值，避免反向邻居被选
			var self_wp: Vector2 = HexUtils.cube_to_world(upstream.q, upstream.r, _last_hex_size)
			# Daily-Sim SoA Refactor 阶段 2：通过索引取邻居。
			if has_idx:
				var ui: int = map.index_of(upstream)
				if ui >= 0:
					var ubase: int = ui * 6
					for d in range(6):
						var ni: int = nb_idx_arr[ubase + d]
						if ni == -1:
							continue
						var nb: HexCell = map.cell_at(ni)
						if nb == null or not _is_water(nb.terrain):
							continue
						var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _last_hex_size)
						var d_vec: Vector2 = (nb_wp - self_wp)
						if d_vec.length_squared() < 1e-6:
							continue
						var dot_v: float = d_vec.normalized().dot(upstream_dir)
						if dot_v > best_dot:
							best_dot = dot_v
							best_nb = nb
			else:
				for nb: HexCell in map.get_neighbors(upstream):
					if nb == null or not _is_water(nb.terrain):
						continue
					var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _last_hex_size)
					var d: Vector2 = (nb_wp - self_wp)
					if d.length_squared() < 1e-6:
						continue
					var dot_v: float = d.normalized().dot(upstream_dir)
					if dot_v > best_dot:
						best_dot = dot_v
						best_nb = nb
			if best_nb == null:
				break
			upstream = best_nb
		var temp_self: float = water_temp_before.get(cell, baseline[cell])
		var temp_up: float = water_temp_before.get(upstream, baseline.get(upstream, temp_self))
		var temp_mixed: float = lerpf(temp_self, temp_up, heat_mix)
		# Fast-tick perf opt (C)：直接写强类型成员。
		cell.temperature = clampf(temp_mixed, 0.0, 1.0)
		cell.temperature_transport_anomaly = temp_mixed - baseline[cell]

# Daily Sim SoA Refactor 方向 X（A2）：洋流热输运的"陆段"——
# 陆地 cell 从相邻水 cell 收集 temperature_transport_anomaly，按"邻水 cell 的
# ocean_current 是否流向本陆地 cell"加权注入。冬季权重 ×winter_boost。
# 必须在 _ocean_water_pass 之后调用——读取的是水段写完的 anomaly。
func _ocean_land_pass(map: MapData, season_phase: float) -> void:
	if _last_cfg == null:
		return
	var coast_leak: float = _last_cfg.COASTAL_HEAT_LEAK
	# 冬季加强系数（与 _ocean_water_pass 中相同语义；这里再算一次，避免
	# 跨函数传 winter_boost 增加耦合）。winter_boost ∈ [1.0, 1.5]，在
	# phase=0（或 4）±0.5 窗口内线性抬升。
	var phase_mod := fposmod(season_phase, 4.0)
	var dist_to_winter: float = minf(phase_mod, 4.0 - phase_mod)
	var winter_boost: float = lerpf(1.5, 1.0, clampf(dist_to_winter, 0.0, 1.0))
	var effective_leak: float = coast_leak * winter_boost

	# baseline 在陆段也需要——用 cell.elevation + _cube_row_norm 重算，避免依赖
	# 上一段的 Dictionary 字段（跨 sub-slice 时可能已被释放）。
	var baseline: Dictionary = {}
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var ny: float = _cube_row_norm(cell, _last_cfg)
		baseline[cell] = _compute_temperature(ny, cell.elevation)

	var nb_idx_arr: PackedInt32Array = map.neighbor_indices_packed()
	var has_idx: bool = map.has_indices()
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var self_wp2: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _last_hex_size)
		var weighted_sum: float = 0.0
		var weight_total: float = 0.0
		# Daily-Sim SoA Refactor 阶段 2：同上。
		if has_idx:
			var ci: int = map.index_of(cell)
			if ci >= 0:
				var cbase: int = ci * 6
				for d in range(6):
					var ni: int = nb_idx_arr[cbase + d]
					if ni == -1:
						continue
					var nb: HexCell = map.cell_at(ni)
					if nb == null or not _is_water(nb.terrain):
						continue
					var cur_nb: Vector2 = nb.ocean_current
					if cur_nb.length_squared() < 1e-6:
						continue
					var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _last_hex_size)
					var dir_nb_to_self: Vector2 = (self_wp2 - nb_wp)
					if dir_nb_to_self.length_squared() < 1e-6:
						continue
					var w_nb: float = maxf(0.0, dir_nb_to_self.normalized().dot(cur_nb))
					if w_nb <= 0.0:
						continue
					weighted_sum += nb.temperature_transport_anomaly * w_nb
					weight_total += w_nb
		else:
			for nb: HexCell in map.get_neighbors(cell):
				if nb == null or not _is_water(nb.terrain):
					continue
				var cur_nb: Vector2 = nb.ocean_current
				if cur_nb.length_squared() < 1e-6:
					continue
				var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _last_hex_size)
				# 邻居 → 本 cell 方向（迎流判断：若水 cell 的洋流正是流向陆地方向，权重最大）
				var dir_nb_to_self: Vector2 = (self_wp2 - nb_wp)
				if dir_nb_to_self.length_squared() < 1e-6:
					continue
				var w_nb: float = maxf(0.0, dir_nb_to_self.normalized().dot(cur_nb))
				if w_nb <= 0.0:
					continue
				weighted_sum += nb.temperature_transport_anomaly * w_nb
				weight_total += w_nb
		var anomaly_in: float = 0.0
		if weight_total > 0.0:
			anomaly_in = (weighted_sum / weight_total) * effective_leak
		cell.temperature_transport_anomaly = anomaly_in
		if absf(anomaly_in) > 1e-5:
			# Fast-tick perf opt (C)：直接读写强类型成员。
			var t_prev: float = cell.temperature if cell.temperature > 0.0 else float(baseline[cell])
			cell.temperature = clampf(t_prev + anomaly_in, 0.0, 1.0)

# ─── Milestone 3：天气子系统每日推进 ────────────────────────────────────
# 由 main.gd 的 _on_day_changed 触发。流程：
#   1) WeatherSystem.tick_one_day：advect 现有 front + spawn 新 front + 写 cell.current_state.weather/intensity
#   2) 同时把 weather 的 moisture/temp 扰动叠加到 current_state.moisture/temperature（不改 base_*）
#   3) 必要时改写 cell.cover（BLIZZARD → SNOW、STORM/MONSOON 低地 → FLOODING）
#   4) 不重烘焙任何 tex（视觉层 weather overlay 走 shader uniform 数组路径，零 tex 上传）
# 返回当前活跃 front 列表，main 拿去喂 renderer。
func refresh_daily(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	# 一次性入口：保留兼容性。内部分别调 _stage_a / _stage_b，等价于"Job 把整轮
	# 在单 tick 跑完"。Job 的多 tick 切片路径走 `refresh_daily_stage_a / _stage_b`。
	var fronts: Array[WeatherFront] = refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
	refresh_daily_stage_b(map, world)
	return fronts


# Stage A：tick_one_day（advection / spawn / distribute / cyclone），57ms 大头不可拆。
# 由 SUS WeatherRefreshJob 在 round 起点的 tick 跑；返回当日 fronts。
# 副作用：写入 cell.current_state（weather/intensity/cloud/precip）+ 更新 _last_world / _last_active_fronts。
func refresh_daily_stage_a(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	if _weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	_last_world = world
	# 重置当轮分段计时；stage_b 完成后再写 total_ms / 各 ms。
	_weather_round_t0_us = Time.get_ticks_usec()
	var t_us0: int = Time.get_ticks_usec()
	var fronts := _weather_system.tick_one_day(map, world, season_idx, climate_anomaly, season_phase)
	_weather_round_tick_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
	_last_active_fronts = fronts
	_weather_round_fronts = fronts
	return fronts


# Stage B：tick_one_day 之后的全部"派生 / 反馈"工作。
# field_bake（F 之后 ~5ms 增量） + transpiration（多数情况下被 enable_local_climate_coupling 跳过）
# + albedo + vegetation_dynamics + cover/veg dirty marks + weather→map feedback。
# 由 SUS WeatherRefreshJob 在 round 终点的 tick 跑（典型下一 tick）。
func refresh_daily_stage_b(map: MapData, world: WorldData) -> void:
	if _weather_system == null or map == null or world == null:
		return
	var cp_now := _c()
	_weather_stage_b_call_index += 1
	var albedo_stride: int = maxi(1, int(cp_now.weather_albedo_stride)) if cp_now != null else 7
	var veg_dyn_stride: int = maxi(1, int(cp_now.weather_vegetation_dynamics_stride)) if cp_now != null else 5
	var feedback_stride: int = maxi(1, int(cp_now.weather_feedback_stride)) if cp_now != null else 3
	var run_albedo: bool = (_weather_stage_b_call_index % albedo_stride) == 0
	var run_veg_dyn: bool = (_weather_stage_b_call_index % veg_dyn_stride) == 0
	var run_feedback: bool = (_weather_stage_b_call_index % feedback_stride) == 0
	var weather_field_bake_ms: float = 0.0
	var t_us0: int = Time.get_ticks_usec()
	# Weather field data now lives on HexCell.weather_* and is consumed by CPU-side
	# systems directly. Do not flatten it into a per-pixel texture each weather tick.
	if world.weather_field_tex != null or not world.weather_field_buffer.is_empty():
		world.weather_field_tex = null
		world.weather_field_buffer = PackedByteArray()

	# Emergent Climate Coupling：当 enable_local_climate_coupling 开启时，
	# transpiration 已在 refresh_climate_daily 末尾、weather tick 之前执行过，此处跳过。
	var skip_transpiration: bool = cp_now != null and bool(cp_now.enable_local_climate_coupling)
	var transp_ms: float = 0.0
	if not skip_transpiration:
		t_us0 = Time.get_ticks_usec()
		_apply_transpiration_pass(map)
		transp_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
	var albedo_ms: float = 0.0
	if run_albedo:
		t_us0 = Time.get_ticks_usec()
		_apply_albedo_pass(map)
		albedo_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
	var vegetation_dirty := false
	var veg_dyn_ms: float = 0.0
	if run_veg_dyn:
		t_us0 = Time.get_ticks_usec()
		vegetation_dirty = _apply_vegetation_dynamics(map, float(veg_dyn_stride))
		veg_dyn_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
	var cover_rebake_ms: float = 0.0
	var veg_rebake_ms: float = 0.0
	if _baker != null:
		if _weather_system.has_cover_dirty():
			_mark_enum_atlas_dirty(true, false)
		if vegetation_dirty:
			_mark_enum_atlas_dirty(false, true)
	var feedback_ms: float = 0.0
	if cp_now != null and bool(cp_now.fast_slow_layering_enabled) and run_feedback:
		t_us0 = Time.get_ticks_usec()
		_apply_weather_to_map_feedback_pass(map, float(feedback_stride))
		feedback_ms = (Time.get_ticks_usec() - t_us0) / 1000.0

	var total_ms: float = (Time.get_ticks_usec() - _weather_round_t0_us) / 1000.0
	var sub: Dictionary = {}
	if _weather_system.has_method("last_breakdown"):
		sub = _weather_system.last_breakdown()
	_last_weather_breakdown = {
		"weather_tick_ms": _weather_round_tick_ms,
		"advance_ms": float(sub.get("advance_ms", 0.0)),
		"spawn_ms": float(sub.get("spawn_ms", 0.0)),
		"distribute_ms": float(sub.get("distribute_ms", 0.0)),
		"cyclone_ms": float(sub.get("cyclone_ms", 0.0)),
		"weather_field_bake_ms": weather_field_bake_ms,
		"transp_ms": transp_ms,
		"albedo_ms": albedo_ms,
		"veg_dyn_ms": veg_dyn_ms,
		"cover_rebake_ms": cover_rebake_ms,
		"veg_rebake_ms": veg_rebake_ms,
		"feedback_ms": feedback_ms,
		"total_ms": total_ms,
		"fronts": _weather_round_fronts.size(),
		"albedo_ran": run_albedo,
		"veg_dyn_ran": run_veg_dyn,
		"feedback_ran": run_feedback,
	}

# 给 UI / renderer 直接拿到当前天气快照（不触发 tick）
func active_weather_fronts() -> Array[WeatherFront]:
	if _weather_system == null:
		return [] as Array[WeatherFront]
	return _weather_system.active_fronts()

# Fast-tick perf opt (A)：由 main.gd 在速度档位变更时调用，按档位写入
# ClimateProfile.weather_refresh_stride。clamp 到 [1, 8] 与 profile 的
# @export_range 保持一致。首次设置或变化时打一次 [fastpath] 日志便于验证。
# 任务 8：stride 的单一真值源已迁到 SUS 的 WeatherRefreshJob.policy；这里同时
# 重建 Job 的 StridePolicy，保证 main.gd / Inspector / SUS 三者一致。
func set_weather_refresh_stride(s: int) -> void:
	var stride: int = clampi(s, 1, 8)
	var cp := _c()
	if cp == null:
		# 尚无 climate profile（通常是 _ready 完成前的极早调用）——缓存到待应用标志上不太值得，
		# 外部 main.gd 会在后续 speed_changed 回调里再调一次，直接忽略即可。
		return
	cp.weather_refresh_stride = stride
	if _weather_refresh_job != null:
		_weather_refresh_job.reconfigure(stride)
	if stride != _weather_stride_logged:
		_weather_stride_logged = stride
		print("[fastpath] weather_refresh_stride = %d" % stride)


# 任务 8：daily_climate_refresh_stride 亦迁到 SUS；提供 setter 改写
# ClimateProfile + Job policy 两者，保持语义一致。默认 main.gd 不随 speed_changed
# 修改该 stride（历史上也未随速度变化），保持原有 default = 1 行为。
func set_daily_climate_refresh_stride(s: int) -> void:
	var stride: int = max(1, s)
	var cp := _c()
	if cp == null:
		return
	cp.daily_climate_refresh_stride = stride
	if _refresh_climate_daily_job != null:
		_refresh_climate_daily_job.reconfigure(stride)

# ─── Emergent Climate Coupling：天气 → 慢层反馈 pass ─────────────────────
# 每日末尾一次性把当日天气累积效应以**极小权重**（≤ 慢层基线 0.5%/日）
# 累加到慢层的两个反馈缓冲字段：
#   cell.soil_moisture             ← 降水累积（RAIN / STORM / MONSOON × intensity）
#   cell.vegetation_growth_pressure ← 综合正向（RAIN）/ 负向（DROUGHT / HEATWAVE）
# 这些反馈缓冲由 refresh_seasonal 在季末消费并按 feedback_decay 衰减，从而让
# "长期天气"（如"连下三个月雨"）能缓慢影响 base_moisture / 演替评估，但
# 当天的雨绝不直接重写 base_*——物理上"天气快、地图慢"。
#
# 受 ClimateProfile.fast_slow_layering_enabled 控制（调用方已检查）。
# 全局 |Δ|/日 clamp：feedback_per_day_clamp（默认 0.005，即 0.5%）。
func _apply_weather_to_map_feedback_pass(map: MapData, day_scale: float = 1.0) -> void:
	if map == null:
		return
	var cp := _c()
	if cp == null:
		return
	var soil_gain: float = float(cp.weather_to_soil_gain)
	var veg_gain: float = float(cp.weather_to_vegetation_gain)
	var scale: float = maxf(day_scale, 1.0)
	var per_day_clamp: float = float(cp.feedback_per_day_clamp) * scale
	var ocean_drift_gain: float = float(cp.ocean_moisture_drift_gain)

	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			# 水体不参与土壤 / 植被反馈（海冰已有自己的半慢层）
			continue
		# ── 长期洋流 → base_moisture 漂移（寒流海岸沙漠通路，年尺度）──
		# 计算邻水平均 anomaly；以"日 |Δ| ≤ feedback_per_day_clamp"上限漂移
		# base_moisture，让稳态寒流海岸在 ~1 in-game year 内实测 base 下降 ~0.05–0.10，
		# 暖流海岸对称上升。彻底关闭时 ocean_moisture_drift_gain == 0。
		if ocean_drift_gain > 0.0:
			var sum_an: float = 0.0
			var n_water: int = 0
			for nb: HexCell in map.get_neighbors(cell):
				if nb != null and _is_water(nb.terrain):
					sum_an += nb.temperature_transport_anomaly
					n_water += 1
			if n_water > 0:
				var avg_an: float = sum_an / float(n_water)
				if absf(avg_an) > 0.005:
					# coastal_ratio 0..1：内陆为 0，半岛 ≈ 1
					var coastal_ratio: float = clampf(float(n_water) / 6.0, 0.0, 1.0)
					var d_base: float = clampf(ocean_drift_gain * avg_an * coastal_ratio * scale,
						-per_day_clamp, per_day_clamp)
					cell.base_moisture = clampf(cell.base_moisture + d_base, 0.0, 1.0)
		var wt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var w_int: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		if w_int < 0.01:
			continue
		# 降水贡献（RAIN / STORM / MONSOON 正；DROUGHT / HEATWAVE 负）
		var precip_contrib: float = 0.0
		match wt:
			WeatherType.WT.RAIN:     precip_contrib = w_int
			WeatherType.WT.STORM:    precip_contrib = w_int * 0.8
			WeatherType.WT.MONSOON:  precip_contrib = w_int * 1.2
			WeatherType.WT.BLIZZARD: precip_contrib = w_int * 0.3  # 雪融化慢，贡献弱
			WeatherType.WT.DROUGHT:  precip_contrib = -w_int * 0.6
			WeatherType.WT.HEATWAVE: precip_contrib = -w_int * 0.4
			_: precip_contrib = 0.0
		# 累加到 soil_moisture（小权重）
		var d_soil: float = clampf(soil_gain * precip_contrib * scale, -per_day_clamp, per_day_clamp)
		cell.soil_moisture = clampf(cell.soil_moisture + d_soil, -0.5, 0.5)
		# 累加到 vegetation_growth_pressure（含温度协同：暖湿利于生长、热干压迫）
		var d_veg: float = clampf(veg_gain * precip_contrib * scale, -per_day_clamp, per_day_clamp)
		cell.vegetation_growth_pressure = clampf(cell.vegetation_growth_pressure + d_veg, -0.5, 0.5)

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
		# Fast-tick perf opt (C)：moisture 已升级为强类型成员。
		var moist: float = cell.moisture
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
		# Fast-tick perf opt (C)：直接读写强类型成员。
		cell.moisture = clampf(cell.moisture + d, 0.0, 1.0)

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
		# Fast-tick perf opt (C)：直接读写强类型成员，避免字典开销。
		cell.temperature = clampf(cell.temperature + dt, 0.0, 1.0)

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
	# Weather now acts as chronic stress, not a short-term mass die-off trigger.
	WeatherType.WT.DROUGHT:  0.004,   # Drought remains the main pressure, mitigated by _WEATHER_RESISTANCE.
	WeatherType.WT.BLIZZARD: 0.002,   # Blizzard pressure on temperate / tropical vegetation.
	WeatherType.WT.HEATWAVE: 0.003,   # Heatwave pressure on cold-adapted vegetation.
	WeatherType.WT.STORM:    0.001,   # Minor storm damage from windthrow.
	WeatherType.WT.MONSOON:  0.001,
}
func _apply_vegetation_dynamics(map: MapData, day_scale: float = 1.0) -> bool:
	var any_changed: bool = false
	var scale: float = maxf(day_scale, 1.0)
	var streak_days: int = maxi(1, int(round(scale)))
	for cell: HexCell in map.all_cells():
		if LandformType.is_water(cell.landform):
			continue
		if cell.vegetation == VegetationType.VEG.NONE:
			# NONE 也参与演替（先驱阶段：从 NONE 慢慢演替到 DESERT_SCRUB → STEPPE → ...）
			pass
		# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
		var temp: float = cell.temperature
		var moist: float = cell.moisture
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
		var wt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var wi: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		var base_penalty: float = float(WEATHER_VITALITY_PENALTY.get(wt, 0.0))
		var resistance: float = VegetationType.weather_resistance(int(cell.vegetation), wt)
		var penalty: float = base_penalty * wi * (1.0 - resistance)
		dv -= penalty
		cell.vegetation_vitality = clampf(cell.vegetation_vitality + dv * scale, 0.0, 1.0)

		# Streak 计数：连续多少天处于演替触发区间
		if cell.vegetation_vitality < _c().vitality_low_threshold:
			cell._vitality_low_streak += streak_days
			cell._vitality_high_streak = 0
		elif cell.vegetation_vitality > _c().vitality_high_threshold:
			cell._vitality_high_streak += streak_days
			cell._vitality_low_streak = 0
		else:
			# 中性区间：streak 缓慢清零（避免极端事件遗留计数）
			cell._vitality_low_streak = maxi(cell._vitality_low_streak - streak_days, 0)
			cell._vitality_high_streak = maxi(cell._vitality_high_streak - streak_days, 0)

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
	# 旧调用点（refresh_seasonal / sea_ice_pass）继续按"季节中段"语义；
	# True Insolation-Driven：主开关打开时统一转发到 insolation 派生，保证"季节信号"单一源头；
	# 关闭时维持 legacy 余弦路径（兼容回退）。
	var cp := _c()
	var phase_mid: float = float(season) + 0.5
	if cp != null and bool(cp.true_insolation_enabled):
		return _insolation_season_offset(ny, phase_mid)
	return _season_temp_offset_phase(ny, phase_mid)

# ─── Emergent Climate Coupling：太阳辐照（insolation） ───────────────────
# True Insolation-Driven Climate（Phase F）：把 insolation 提升为"单一真值源"。
#
# 物理解读（Phase F 版本 + Plan B 日历对齐）：
#   year_progress   = fposmod(season_phase, 4) / 4                  # ∈ [0, 1)
#   subsolar_lat    = axial_tilt × cos(2π · year_progress)          # 直射点纬度（rad）
#                     phase=0(1月) → +tilt（南向 subsolar，北半球冬至）
#                     phase=2(7月) → -tilt（北向 subsolar，北半球夏至）
#   lat_rad         = (ny - 0.5) × π                                # ny=0 北极 lat_rad=-π/2
#   cos_zenith      = max(0, cos(lat_rad - subsolar_lat_rad))       # 太阳高度角的余弦
#   daylen_factor   = 1 - amp · cos(2π · year_progress) · sign(lat) # 连续日长项
#                     phase=2 时 ny=0（北极, sign=-1）→ 1+amp（昼最长） ✓
#   insolation      = clamp(cos_zenith × daylen_factor, 0, 1)
#
# 半球反相由 sign(lat) 自然涌现，不再需要旧代码里的 `if lat < 0: phase += 2`
# 手动翻转。shader 端同步使用同一公式，保证 CPU / GPU 同源。
#
# 当 true_insolation_enabled == false 时，调用方仍可读到 insolation 数值，
# 但温度季节偏移、海冰冬季判定、湿度季节倍率会改回 legacy 路径。
const _INSOLATION_DAYLEN_AMP: float = 0.35  # legacy 默认；运行时被 profile.insolation_daylen_amp 覆盖

func _subsolar_lat_rad(season_phase: float) -> float:
	var cp := _c()
	var tilt_deg: float = 23.5
	if cp != null and "axial_tilt_deg" in cp:
		tilt_deg = cp.axial_tilt_deg
	var year_progress: float = fposmod(season_phase, 4.0) / 4.0
	# Plan B 日历对齐：phase=0(1月) → +tilt（北半球冬至），phase=2(7月) → -tilt（北半球夏至）
	return deg_to_rad(tilt_deg) * cos(TAU * year_progress)

func _compute_insolation(ny: float, season_phase: float) -> float:
	var cp := _c()
	var amp: float = _INSOLATION_DAYLEN_AMP
	if cp != null and "insolation_daylen_amp" in cp:
		amp = cp.insolation_daylen_amp
	var lat_rad: float = (ny - 0.5) * PI
	var subsolar: float = _subsolar_lat_rad(season_phase)
	var cos_zenith: float = maxf(cos(lat_rad - subsolar), 0.0)
	var year_progress: float = fposmod(season_phase, 4.0) / 4.0
	var lat_sign: float = signf(lat_rad)
	# Plan B：与 subsolar 同相位。phase=2 时 cos=-1，北极 sign=-1 → 1 + amp（昼最长）。
	var daylen_factor: float = 1.0 - amp * cos(TAU * year_progress) * lat_sign
	return clampf(cos_zenith * daylen_factor, 0.0, 1.0)

# 按 ny 缓存的"一年平均 insolation"：16 点数值积分 + LUT 插值。
# 首次调用或 axial_tilt_deg 变化时重建 LUT；之后 O(1) 查表。
func _insolation_annual_mean(ny: float) -> float:
	var cp := _c()
	var tilt_deg: float = 23.5
	if cp != null and "axial_tilt_deg" in cp:
		tilt_deg = cp.axial_tilt_deg
	# LUT 未建或 tilt 变化 → 重建
	if _insol_mean_lut.size() != _INSOL_MEAN_LUT_SIZE + 1 or not is_equal_approx(_insol_mean_lut_tilt, tilt_deg):
		_rebuild_insol_mean_lut()
	# 将 ny ∈ [0, 1] 映射到 LUT 桶索引（双线性插值）
	var x: float = clampf(ny, 0.0, 1.0) * float(_INSOL_MEAN_LUT_SIZE)
	var i0: int = int(floor(x))
	var i1: int = mini(i0 + 1, _INSOL_MEAN_LUT_SIZE)
	var t: float = x - float(i0)
	return lerp(_insol_mean_lut[i0], _insol_mean_lut[i1], t)

func _rebuild_insol_mean_lut() -> void:
	var cp := _c()
	var tilt_deg: float = 23.5
	if cp != null and "axial_tilt_deg" in cp:
		tilt_deg = cp.axial_tilt_deg
	_insol_mean_lut.resize(_INSOL_MEAN_LUT_SIZE + 1)
	for i: int in range(_INSOL_MEAN_LUT_SIZE + 1):
		var ny: float = float(i) / float(_INSOL_MEAN_LUT_SIZE)
		var acc: float = 0.0
		for s: int in range(_INSOL_ANNUAL_SAMPLES):
			var phase: float = 4.0 * float(s) / float(_INSOL_ANNUAL_SAMPLES)
			acc += _compute_insolation(ny, phase)
		_insol_mean_lut[i] = acc / float(_INSOL_ANNUAL_SAMPLES)
	_insol_mean_lut_tilt = tilt_deg

# 标准化日射偏差：(insol_now - insol_mean) / insol_mean ∈ 大致 [-1, +1]。
# - 赤道附近 mean 较大、|dev| 接近 0（季节弱）
# - 高纬 mean 较小、|dev| 较大（季节强）
# - 极夜期 insol_now ≈ 0 → dev ≈ -1
# 给需求 2.1 / 需求 1.4 / 需求 1.5 三条路径共享。
func _insol_dev(ny: float, season_phase: float) -> float:
	var mean_val: float = _insolation_annual_mean(ny)
	if mean_val <= 1e-4:
		return 0.0  # 极区 mean≈0 时定义为无偏差，避免除零放大噪声
	var now_val: float = _compute_insolation(ny, season_phase)
	return clampf((now_val - mean_val) / mean_val, -1.0, 1.5)

# True Insolation-Driven：温度季节偏移的"主路径"。
# offset = gain × dev × season_temp_amp
# 与 legacy _season_temp_offset_phase 的差别：
#   - 幅度不再是纬度无关常量，而是随 ny 涌现（赤道小、高纬大）
#   - 半球反相通过 dev 的符号自然产生（subsolar 移向北时南半球 dev<0）
#   - CPU / shader 公式同源（shader 侧在 Task 8 跟进）
func _insolation_season_offset(ny: float, season_phase: float) -> float:
	var cp := _c()
	var amp: float = 0.20
	var gain: float = 1.0
	if cp != null:
		if "season_temp_amp" in cp:
			amp = cp.season_temp_amp
		if "insolation_season_gain" in cp:
			gain = cp.insolation_season_gain
	var dev: float = _insol_dev(ny, season_phase)
	return gain * dev * amp

# ─── Emergent Climate Coupling：UI 用名义季节标签 ────────────────────────
# 仅供选中面板 / HUD 显示，不参与任何物理 pass。返回 {label, transition}：
#   label      ∈ {"Spring", "Summer", "Autumn", "Winter"}
#   transition ∈ [0, 1]，当前 season 已走完的百分比（0 = 季首，1 = 季末）
func nominal_season_label(season_phase: float) -> Dictionary:
	var p: float = fposmod(season_phase, 4.0)
	var idx: int = int(floor(p)) & 3
	var frac: float = p - float(idx)
	var labels: Array[String] = ["Spring", "Summer", "Autumn", "Winter"]
	return {"label": labels[idx], "transition": frac}

# ─── True Insolation-Driven：日历月份 ────────────────────────────────────
# 全年 = 4 季 × 30 日 = 120 天 → 12 个月、每月 10 天。
# 约定 season_phase = 0 对应 1 月 1 日（春分前后）。
# 返回 {month: 1..12, day_of_month: 1..10, day_of_year: 1..120}
func month_of_year(season_phase: float) -> Dictionary:
	var p: float = fposmod(season_phase, 4.0)
	var day_of_year: int = int(floor(p * 30.0))  # 0..119
	var month: int = (day_of_year / 10) + 1      # 1..12
	var day_of_month: int = (day_of_year % 10) + 1  # 1..10
	return {"month": month, "day_of_month": day_of_month, "day_of_year": day_of_year + 1}

# True Insolation-Driven：UI 便利接口。给外部（main.gd 面板）用当前 _last_cfg
# 快速拿到某 cell 的归一化纬度 ny ∈ [0, 1]，0 = 北极 / 0.5 = 赤道 / 1 = 南极。
# 内部仍走 _cube_row_norm；_last_cfg 缺失时返回 0.5（赤道兜底）。
func cell_ny(cell: HexCell) -> float:
	if cell == null or _last_cfg == null:
		return 0.5
	return _cube_row_norm(cell, _last_cfg)

# ─── True Insolation-Driven：本地温度 EMA → 观测月份 ─────────────────────
# 由选中面板使用。用本地温度 30 日 EMA 相对 365 日 EMA 的偏差，结合当前日历
# 月份的 "该半球理论温度方向"，给出一个观测描述。
# 不返回春夏秋冬标签（南北半球相反、赤道无季节），只给出：
#   {calendar_month: 1..12, dev: m30 - m365, warmer_than_annual: bool/null,
#    magnitude: 0..1（|dev|/season_temp_amp，截断到 1）}
# 赤道附近 |dev| < 0.02 时 warmer_than_annual = null（显示"常年温暖"）。
func observe_local_month(cell: HexCell, season_phase: float) -> Dictionary:
	var calendar: Dictionary = month_of_year(season_phase)
	# Fast-tick perf opt (C)：temp_dev_from_annual 已升级为强类型成员，直接读。
	var dev: float = cell.temp_dev_from_annual
	var cp := _c()
	var amp: float = 0.20
	if cp != null and "season_temp_amp" in cp:
		amp = maxf(cp.season_temp_amp, 1e-4)
	var magnitude: float = clampf(absf(dev) / amp, 0.0, 1.0)
	var warmer: Variant = null
	if absf(dev) >= 0.02:
		warmer = dev > 0.0
	return {
		"calendar_month": int(calendar.month),
		"day_of_month": int(calendar.day_of_month),
		"dev": dev,
		"magnitude": magnitude,
		"warmer_than_annual": warmer,  # null = 无显著差异（赤道等）
	}

# 连续相位版本：season_phase ∈ [0, 4) 任意实数。【Legacy / 回退路径】
# 当 ClimateProfile.true_insolation_enabled == false 时，refresh_climate_daily 以及
# ocean_heat_transport winter_boost 会沿用本函数；true_insolation_enabled == true 时
# 改用 _insolation_season_offset(ny, phase) 作为单一真值源。
# 公式（Plan B 日历对齐）：cos((phase - 2) × π/2) × amp × hemi_sign
#   hemi_sign = +1  for 北半球（lat_signed < 0，ny < 0.5）
#             = -1  for 南半球（lat_signed > 0）
#             =  0  for 赤道（lat_signed == 0，无季节偏移）
#   phase=0(1月) 北半球: cos(-π)·amp·1 = -amp（冬） ✓
#   phase=2(7月) 北半球: cos(0)·amp·1  = +amp（夏） ✓
#   phase=2(7月) 南半球: cos(0)·amp·-1 = -amp（冬） ✓
# - season_temp_amp 取自 climate_profile（与 shader uniform 同源），缺失则回退 0.20。
func _season_temp_offset_phase(ny: float, season_phase: float) -> float:
	var lat_signed: float = (ny - 0.5) * 2.0
	# hemi_sign: 北半球 +1、南半球 -1、赤道 0
	var hemi_sign: float = 0.0
	if lat_signed < 0.0:
		hemi_sign = 1.0
	elif lat_signed > 0.0:
		hemi_sign = -1.0
	var amp: float = 0.20
	var cp := _c()
	if cp != null and "season_temp_amp" in cp:
		amp = cp.season_temp_amp
	return cos((season_phase - 2.0) * 0.5 * PI) * amp * hemi_sign

# --- Wind Temperature Coupling：风温耦合 pass（对称复刻洋流热输运） ─────────────────
# 在几何温度之上叠加一层：
#   Pass 1（气团→气团）：沿 -wind_vector 回溯最多 WIND_HEAT_ADVECT_STEPS 个邻居，
#                     混合上游 current_state.temperature 到本 cell，按 WIND_HEAT_MIX 权重。
#                     air_mass_temp_anomaly = temp_after_mix - temp_year_at_cell。
#   Pass 2（气团→地表）：对每个 cell，按 max(0, dot(邻居方向, 上游 cell wind_vector)) 加权
#                     收集相邻 cell 的 air_mass_temp_anomaly；按 AIR_MASS_HEAT_LEAK 注入 current_state.temperature。
#
# 复杂度：O(cells × (ADVECT_STEPS + 6))；默认常量 3 + 6 ≈ 9，轻量。
# 所有几何温度基线使用 _compute_temperature(ny, elevation) 保证与 refresh_climate_daily 一致。
func _apply_wind_heat_transport_pass(map: MapData, season_phase: float) -> void:
	# 对称复刻 _apply_ocean_heat_transport_pass 的 wrapper 设计
	if _last_cfg == null:
		return
	var t0 := Time.get_ticks_msec()
	_wind_air_mass_pass(map, season_phase)
	_wind_surface_pass(map, season_phase)
	_wind_heat_call_count += 1
	if _wind_heat_call_count == 1 or (_wind_heat_call_count % 365) == 0:
		print("wind_heat_transport #%d: %dms (cells=%d, phase=%.3f)" % [
			_wind_heat_call_count,
			Time.get_ticks_msec() - t0,
			map.cell_count(),
			season_phase,
		])

# 风温耦合的"气团段"——
# 所有 cell 沿 -wind_vector 回溯 advect_steps 步、与上游 cell 温度做 lerp 混合，
# 写回 cell.temperature 与 cell.air_mass_temp_anomaly。
func _wind_air_mass_pass(map: MapData, season_phase: float) -> void:
	if _last_cfg == null:
		return
	var advect_steps: int = max(0, _last_cfg.WIND_HEAT_ADVECT_STEPS)
	var heat_mix: float = clampf(_last_cfg.WIND_HEAT_MIX, 0.0, 1.0)
	
	# 基线温度缓存（per-cell 的 temp_year_at_cell，用于算 anomaly）
	var baseline: Dictionary = {}
	for cell: HexCell in map.all_cells():
		var ny: float = _cube_row_norm(cell, _last_cfg)
		baseline[cell] = _compute_temperature(ny, cell.elevation)

	# 先把所有 cell 的当前 temperature 拷贝出来（避免半途被覆盖）
	var temp_before: Dictionary = {}
	for cell: HexCell in map.all_cells():
		temp_before[cell] = cell.temperature if cell.temperature > 0.0 else float(baseline[cell])

	for cell: HexCell in map.all_cells():
		var wind: Vector2 = cell.wind_vector
		if wind.length_squared() < 1e-6 or advect_steps == 0:
			cell.air_mass_temp_anomaly = 0.0
			continue
		
		# 沿 -wind 方向回溯 advect_steps 步，每步选最对齐的邻居
		var upstream: HexCell = cell
		var upstream_dir: Vector2 = -wind.normalized()
		
		for step in range(advect_steps):
			var best_nb: HexCell = null
			var best_dot: float = 0.1  # 需要最低对齐阈值，避免反向邻居被选
			var self_wp: Vector2 = HexUtils.cube_to_world(upstream.q, upstream.r, _last_hex_size)
			
			for nb: HexCell in map.get_neighbors(upstream):
				if nb == null:
					continue
				var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _last_hex_size)
				var d: Vector2 = (nb_wp - self_wp)
				if d.length_squared() < 1e-6:
					continue
				var dot_v: float = d.normalized().dot(upstream_dir)
				if dot_v > best_dot:
					best_dot = dot_v
					best_nb = nb
			
			if best_nb == null:
				break
			upstream = best_nb
		
		var temp_self: float = temp_before.get(cell, baseline[cell])
		var temp_up: float = temp_before.get(upstream, baseline.get(upstream, temp_self))
		var temp_mixed: float = lerpf(temp_self, temp_up, heat_mix)
		
		# Fast-tick perf opt (C)：直接写强类型成员
		cell.temperature = clampf(temp_mixed, 0.0, 1.0)
		cell.air_mass_temp_anomaly = temp_mixed - baseline[cell]

# 风温耦合的"地表段"——
# 每个 cell 从相邻 cell 收集 air_mass_temp_anomaly，按"邻 cell 的 wind_vector 是否流向本 cell"加权注入。
# 必须在 _wind_air_mass_pass 之后调用——读取的是气团段写完的 anomaly。
func _wind_surface_pass(map: MapData, season_phase: float) -> void:
	if _last_cfg == null:
		return
	var air_leak: float = _last_cfg.AIR_MASS_HEAT_LEAK
	
	# baseline 在表面段也需要——用 cell.elevation + _cube_row_norm 重算
	var baseline: Dictionary = {}
	for cell: HexCell in map.all_cells():
		var ny: float = _cube_row_norm(cell, _last_cfg)
		baseline[cell] = _compute_temperature(ny, cell.elevation)

	for cell: HexCell in map.all_cells():
		var self_wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _last_hex_size)
		var weighted_sum: float = 0.0
		var weight_total: float = 0.0
		
		for nb: HexCell in map.get_neighbors(cell):
			if nb == null:
				continue
			var wind_nb: Vector2 = nb.wind_vector
			if wind_nb.length_squared() < 1e-6:
				continue
			
			var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _last_hex_size)
			# 邻居 → 本 cell 方向（迎流判断：若邻 cell 的风正是流向本 cell，权重最大）
			var dir_nb_to_self: Vector2 = (self_wp - nb_wp)
			if dir_nb_to_self.length_squared() < 1e-6:
				continue
			
			var w_nb: float = maxf(0.0, dir_nb_to_self.normalized().dot(wind_nb))
			if w_nb <= 0.0:
				continue
			
			weighted_sum += nb.air_mass_temp_anomaly * w_nb
			weight_total += w_nb
		
		var anomaly_in: float = 0.0
		if weight_total > 0.0:
			anomaly_in = (weighted_sum / weight_total) * air_leak
		
		cell.air_mass_temp_anomaly = anomaly_in
		if absf(anomaly_in) > 1e-5:
			# Fast-tick perf opt (C)：直接读写强类型成员
			var t_prev: float = cell.temperature if cell.temperature > 0.0 else float(baseline[cell])
			cell.temperature = clampf(t_prev + anomaly_in, 0.0, 1.0)
