# map_generator.gd v8
#
# ─── 任务 3（dots-completion）：bake-time vs tick-time 直写分类 ──────────
#
# 本文件中 `cell.<field> = v` 直写按调用时机分两类：
#
# 【bake-time only — SoA 由 init_soa_from_bake() 一次性同步】
#   generate / _apply_*_pass (mountain_ridges / rain_shadow / orographic /
#   river_ecology / vegetation_feedback / swamp / shrubland / mangrove / reef_kelp /
#   volcano / delta / oasis / salt_flat / badlands / glacier / coastal_moisture_boost) /
#   _compute_ocean_currents / _compute_terrain_perturbed_wind /
#   _init_noise / _compute_elevation / _compute_moisture_base / _compute_temperature
#
#   这些函数仅在 bake_world / regenerate / load_save 时调用，
#   末尾必由 map.init_soa_from_bake() 一次性把 AoS 同步到 SoA。
#
# 【tick-time — facade 透传 SoA】
#   refresh_seasonal / refresh_climate_daily / refresh_daily / refresh_daily_stage_a /
#   refresh_daily_stage_b / refresh_yearly
#
#   这些函数被 day_changed / season_changed / yearly tick 驱动。tick 路径中的
#   `cell.x = v` 写入由 hex_cell.gd setter 自动透传到 SoA（PR-2.3b facade 化），
#   启用 use_hexcell_facade=true 后等价于直接 world.write_f32(cid, idx, v)。
#   因此**不需要**机械替换为 world.write_f32_indexed —— facade setter 已是单点
#   write_f32 的 wrapper，效率与直写一致，且保持源代码可读性（cell.temperature = v）。
#
# 验收门禁：record_baseline.gd grep `^\s*cell\.[a-z_]+\s*=` 全文件命中 ≤ 49（基线），
# 任务 4 启用 facade 后所有命中的 tick-time 写入自动经 setter 走 SoA。
#
# ─── Phase E.6 / dots-full-migration §E.6 计划状态（2026-05-13）──────────
#
# 本文件当前 4639+ 行，dots-full-migration plan 目标拆完后 ≤ 250 行。
# 拆分目的地骨架（2026-05-13 已就位，详细迁移规格在各骨架文件顶部）：
#
#   simulation/climate/pass_a.gd                 ← _climate_pass_a (line 3129) +
#                                                  _climate_pass_a_soa (line 3941)
#   simulation/climate/pass_b.gd                 ← _climate_pass_b (line 3303) +
#                                                  _climate_pass_b_soa (line 4197) +
#                                                  _apply_local_climate_coupling_pass (line 3323)
#   simulation/ocean/water_pass.gd               ← _ocean_water_pass (line 3735) +
#                                                  _ocean_water_pass_soa (line 4429)
#   simulation/ocean/land_pass.gd                ← _ocean_land_pass (line 3838) +
#                                                  _ocean_land_pass_soa (line 4512)
#   simulation/sea_ice/daily_pass.gd             ← _apply_sea_ice_daily_pass (line 3573)
#                                                  + terrain 翻转走 ECB
#   simulation/biology/transpiration_pass.gd     ← _apply_transpiration_pass (line 4890)
#   geography/map_generation/terrain_gen.gd (G.1)← 一次性烘焙逻辑
#                                                  (大陆/高度/河流/湖泊/biome/wind ~1500 行)
#   geography/diagnostics_bus.gd                 ← _last_*_breakdown / _daily_climate_call_count
#                                                  等所有 instrumentation 字段
#
# E.6 完成后 map_generator.gd 残留：
#   - generate(cfg, hex_size) 入口（弱协调 generation 7+ pass 调用顺序）
#   - SUS 注册段（_setup_sus, line ~700-800）
#   - 配置访问 helper（_c() / get_data_core_world() / public_cube_row_norm 等）
#   - 各 sub-pass 转发占位（在 sub-module facade 抽完前保留旧函数体）
#
# 当前各 sub-module 是 facade（见各文件顶部"当前状态"），实际 hot loop 仍在
# 本文件内。后续 PR 按各 facade 顶部的"逐函数搬迁清单"逐函数搬，每个独立 PR
# + bit-equal 验收。
#
# diagnostics_bus.gd 接入路径：当前 _last_*_breakdown 字段散落在本文件 ~10 处；
# 后续 PR 把每个字段改为 `_diagnostics_bus.record_<name>(...)` / `get_<name>()`
# 调用，本文件不再持有 instrumentation state。
#
# ─── 原始 v8 改动说明（保留）────────────────────────────────────────────
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

# bake_world 阶段进度转发信号。MapBaker 内部的 stage_progress 在 _baker = new() 后
# 立刻被 connect 转发到这里，让 main.gd 不需要触达内部 _baker 引用就能订阅。
# main.gd 在 `_generator = MapGenerator.new()` 之后、`generate()` 调用之前
# 订阅本信号；详细 stage 含义见 map_baker.gd 顶部 stage_progress 信号注释。
signal bake_progress(stage: String, fraction: float)

# 显式 preload，避免新建 class_name 文件时 Godot 全局类注册表偶发未拾取的问题
const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")
const DCClimateMath = preload("res://scripts/simulation/climate/climate_math.gd")
# 同理：ClimateProfile 在 @export 里被引用，冷启动/首次导入时全局类注册表可能
# 尚未拾取，这里显式 preload 迫使先加载该脚本，避免
# "Parser Error: Could not parse global class MapGenerator" 的启动报错。
const ClimateProfileScript = preload("res://scripts/data/climate_profile.gd")

# Sliced Update Scheduler (SUS) — 全局切片更新调度器。MapGenerator 持有
# SUS 实例并把所有"周期性模拟工作"作为 Job 注册进来。任务 4：注册
# OceanCurrentsJob，把年首 ~1605ms 的洋流烘焙切成多日 ≤4ms 的小切片。
const SlicedUpdateSchedulerScript = preload("res://scripts/simulation/sus/sus_scheduler.gd")
const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const SusTickContextScript = preload("res://scripts/simulation/sus/sus_tick_context.gd")
const OceanCurrentsJobScript = preload("res://scripts/simulation/sus/jobs/ocean_currents_job.gd")
# 任务 8：把 refresh_climate_daily / refresh_daily 收编为 SUS Job。
const RefreshClimateDailyJobScript = preload("res://scripts/simulation/sus/jobs/refresh_climate_daily_job.gd")
const WeatherRefreshJobScript = preload("res://scripts/simulation/sus/jobs/weather_refresh_job.gd")
const NativeDailySimJobScript = preload("res://scripts/simulation/sus/jobs/native_daily_sim_job.gd")
# Legacy sea_ice_atlas_upload 代码保留但不再注册；海冰主视觉由 shader 按水温派生。
const SeaIceAtlasUploadJobScript = preload("res://scripts/simulation/sus/jobs/sea_ice_atlas_upload_job.gd")
const EnumAtlasUploadJobScript = preload("res://scripts/simulation/sus/jobs/enum_atlas_upload_job.gd")
const SeasonRefreshJobScript = preload("res://scripts/simulation/sus/jobs/season_refresh_job.gd")

# 0.4.1 — DCSystemScheduler 与 6 个 DCSystem wrapper 的 preload。
# 当 ClimateProfile.use_dc_system_scheduler=true 时 `_setup_sus` 会创建
# DCSystemScheduler 并 register_system 这 6 个 wrapper（其中 3 个是 delegate
# wrapper：ClimateDailySystem / OceanCurrentsSystem / WeatherDCSystem；
# 另 3 个 SeasonRefreshSystem / EnumAtlasUploadSystem / SeaIceAtlasUploadSystem
# 是原生 DCSystem 实现）。flag=false 时维持既有 SusJob 直注册路径，零行为差异。
const DCSystemSchedulerScript = preload("res://scripts/data_core/dc_system_scheduler.gd")
const ClimateDailySystemScript = preload("res://scripts/simulation/systems/climate_daily_system.gd")
const SeaIceDailySystemScript = preload("res://scripts/simulation/systems/sea_ice_daily_system.gd")
const OceanCurrentsSystemScript = preload("res://scripts/simulation/systems/ocean_currents_system.gd")
const WeatherDCSystemScript = preload("res://scripts/simulation/systems/weather_system.gd")
const SeasonRefreshSystemScript = preload("res://scripts/simulation/systems/season_refresh_system.gd")
const EnumAtlasUploadSystemScript = preload("res://scripts/simulation/systems/enum_atlas_upload_system.gd")
const SeaIceAtlasUploadSystemScript = preload("res://scripts/simulation/systems/sea_ice_atlas_upload_system.gd")
const DynamicVisualAtlasUploadSystemScript = preload("res://scripts/simulation/systems/dynamic_visual_atlas_upload_system.gd")
const WeatherLutUploadSystemScript = preload("res://scripts/simulation/systems/weather_lut_upload_system.gd")
const NativeEnvironmentRuntimeSystemScript = preload("res://scripts/simulation/systems/native_environment_runtime_system.gd")

# Phase 1.4 — DCSusSystemsBootstrap 接口骨架（main.gd 拆分前的 forward 层）。
# 在 _setup_sus 末尾被构造 + attach_post_setup；main.gd 通过 generator.get_sus_bootstrap()
# 拿引用做诊断 / 未来直接 tick scheduler。详见 scripts/bootstrap/sus_systems_bootstrap.gd。
const DCSusSystemsBootstrapScript = preload("res://scripts/bootstrap/sus_systems_bootstrap.gd")

# ─── 世界生成配置（数据驱动） ────────────────────────────────────────────
# 所有原本散落在本文件顶部的 50+ 个调参 const 已迁移到 ClimateProfile 资源。
# - 默认（nil）时，懒加载 res://data/world/earth_like.tres 作为兜底，效果与
#   旧版硬编码完全一致。
# - 美术/策划可在 Inspector 里切换别的 .tres（如 ice_age.tres / desert_world.tres）
#   实现不同的"世界预设"，无需改代码。
# - _c() 是热路径 helper：返回非空的 climate_profile。
@export var climate_profile: ClimateProfile = null

# 收尾日志限频：physical-hex 路径首次跳过 _compute_ocean_currents 时打一次，
# 之后静默（避免每天/每帧刷屏）。
var _phys_skip_logged: bool = false

func _c() -> ClimateProfile:
	if climate_profile == null:
		var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
		if loaded == null:
			push_warning("MapGenerator: earth_like.tres missing; using in-memory defaults")
			loaded = ClimateProfile.new()
		climate_profile = loaded
	return climate_profile

func _calendar_days_per_year() -> int:
	if _world_clock_ref != null and _world_clock_ref.has_method("days_per_year"):
		return clampi(int(_world_clock_ref.days_per_year()), 1, 3660)
	var cp := _c()
	if cp != null and cp.get("orbital_days_per_year") != null:
		return clampi(int(cp.get("orbital_days_per_year")), 1, 3660)
	return 365

func _season_phase_to_day_of_year(season_phase: float, days_per_year: int = 0) -> int:
	var dpy: int = clampi(days_per_year if days_per_year > 0 else _calendar_days_per_year(), 1, 3660)
	var p: float = fposmod(season_phase, 4.0)
	return clampi(int(floor((p / 4.0) * float(dpy))), 0, dpy - 1)

func _is_annual_log_tick(counter: int) -> bool:
	var dpy: int = _calendar_days_per_year()
	return counter == 1 or (counter > 0 and (counter % dpy) == 0)

# （下面各组调参说明仍保留，方便阅读；实际数值取自 ClimateProfile。）

# ─── 河流参数 ────────────────────────────────────────────────────────────
# 流量分位阈值：超过 land cell 总流量这个 percentile 的格子作为河流源头，
# native post-base 再沿 downhill 路径连续刻到水体，避免短碎河段。

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

# 旧每季湿度全局缩放已停用。湿度/降水现在由日照、温度、风场、水汽、
# 地形抬升和 weather field 共同演化。
# const SEASONAL_MOISTURE_SCALE (legacy ClimateProfile.seasonal_moisture_scale)

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
# dots-total-cpp（2026-06-18）：_height_noise / _detail_noise / _moisture_noise /
# _continent_centers 仅 GDScript 生成用，已随生成删除。_height_warp 仍供 C++ 雨影
# jitter 桥（_build_rain_shadow_jitter_for_gdext）使用，保留。
var _height_warp:     FastNoiseLite     # 域扭曲；现仅供 rain-shadow jitter C++ 桥
										  # kind ∈ {"main", "satellite"}，所有坐标和半径都是归一化 [0, 1]
var _rng:             RandomNumberGenerator

# ─── Phase 2：跨季 / 跨年保留状态 ────────────────────────────────────────
# 保留 baker 实例，rebake biome 时复用它的 noise，避免重新 init 一次（也保证 warp 同相）
var _baker: MapBaker = null
# 保留 cfg 给 refresh_seasonal 用（不需要每次外部传）
var _last_cfg: MapConfig = null

# Seasonal Continuous Climate：refresh_climate_daily 调用计数器（耗时打点节流用）。
# 首次调用必打，之后每个 WorldClock 年长打一次，避免日志被高频日级刷新淹没。
var _daily_climate_call_count: int = 0
# Systemic Ocean Currents：_apply_ocean_heat_transport_pass 调用计数器（同节流策略）。
var _heat_transport_call_count: int = 0
# Wind Temperature Coupling：_apply_wind_heat_transport_pass 调用计数器（同节流策略）。
var _wind_heat_call_count: int = 0

# Daily-sim perf instrumentation：上一次 refresh_climate_daily 的子段拆解。
# 字段：pass_a_ms / pass_b_ms / ocean_ms / sea_ice_ms / ice_bake_ms / transp_ms /
# total_ms / cells。main.gd fast tick WARN 路径用它定位是哪一段慢。
var _last_climate_breakdown: Dictionary = {}
var _last_sea_ice_daily_breakdown: Dictionary = {}

# A.2.1.A3 — Pass B 稀疏遍历专用：dirty + 1 跳邻居膨胀后的 visit mask。
# 缓存在 generator 上避免每 round 分配；第一次遇到时按 cell_count 一次性 resize。
# 仅当 use_sparse_climate=true 且 climate_dirty_ratio ∈ (50/N, 0.8) 时使用。
var _pass_b_visit_mask: PackedByteArray = PackedByteArray()
# A.2.1.A5 — 本 round Pass B 实际遍历到的 dirty_ratio 与 visited_ratio，写到 breakdown。
var _last_climate_dirty_ratio: float = 1.0
var _last_climate_visited_ratio: float = 1.0
var _last_climate_pass_b_path: String = "full"  # "full" | "sparse"

# A.2.1.A2-fix — 全图季节同向漂移补偿：Pass A 写温度时若仅是全图随季节漂移而非
# 局部异常，则不应标 dirty。我们在 round 末尾算出本日 dt 的均值（全图同向漂移量），
# 第二日 epsilon 比对改为 |dt - _dt_global_yesterday| > eps，过滤掉季节驱动的假阳性。
# 同理处理 moisture / snow_cover。这三个变量在 round 末由 _finalize_pass_a_drift_stats() 更新。
var _dt_global_yesterday: float = 0.0
var _dm_global_yesterday: float = 0.0
var _ds_global_yesterday: float = 0.0
# round 内累积本日 dt/dm/ds 之和，Pass A 完成后除以 n 得本日 global_drift
var _round_dt_sum: float = 0.0
var _round_dm_sum: float = 0.0
var _round_ds_sum: float = 0.0
var _round_drift_count: int = 0

# A.2.1.B — Pass-A push 稀疏度统计（M1：dynamic_visual_atlas 35-50ms 长帧根治）。
#   _pa_last_pushed_cells: 上一日实际 push 到 DCWorld 的 cell 数（≤ _pa_last_total_cells）
#   _pa_last_total_cells:  地图总 cell 数（SoA 路径下 = map.soa_size()）
# 比值反映 sparse 路径有效性：稳态期望 ≤ 10%；季节切换 / 30 日 / 加载首日 = 1.0。
# climate_daily_system / main.gd 可读取以输出到 perf breakdown。
var _pa_last_pushed_cells: int = 0
var _pa_last_total_cells: int = 0

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
var _enum_atlas_biome_dirty: bool = false
var _enum_atlas_cover_dirty: bool = false
var _enum_atlas_vegetation_dirty: bool = false
var _last_enum_atlas_upload_breakdown: Dictionary = {}
var _season_stage4_deltas: Dictionary = {}
# DOTS-Final-Push 任务 6.2 / 方案 A：sea_ice_atlas_upload Job 把 prepare/upload
# 的拆分耗时（path/prepare_ms/upload_ms/image_ms/dirty_cells/dirty_ratio）回填
# 到这里，供 main.gd fast tick WARN 详细日志展开。schema 与 enum_atlas 同构。
var _last_sea_ice_atlas_upload_breakdown: Dictionary = {}

# Perf instrumentation freshness（方案 ④ Step 1）：
# 5 个 _last_*_breakdown 字典都是"上次执行的快照"，没刷新时 perf_recorder
# 仍会每帧把同一份 stale 值写入 CSV。让 main.gd 在 fast tick 入口同步当前
# tick_idx 到这里，所有写入点把它打到字典内的 `_tick_idx` 字段；
# perf_recorder 比对 row.tick_idx ≠ dict._tick_idx 时跳过整组字段，避免
# 把 "305 行重复值" 累加成假象总耗时。
var _current_fast_tick_idx: int = 0
var _pending_season_refresh: bool = false
var _pending_season_idx: int = 0
var _season_refresh_in_progress: bool = false
var _last_season_refresh_breakdown: Dictionary = {}
# X2-精简版（2026-05-21）：season_refresh round 内 SoA-slots 缓存标志。
# round 启动时 refresh_slots_from_map 调一次后置 true；
# 之后每个 stage helper 进入时若仍为 true → 跳过 refresh_slots（省 ~14μs × 11 = ~0.15ms/round）；
# 任何 stage 走 GDScript fallback（_apply_xxx 直接改 cell 字段而未 flush 回 SoA）→ 置 false，
# 下一个 stage helper 会自动补一次 refresh_slots 保证 C++ SoA 看到最新 cell。
# round 结束（finish_season_refresh）→ 置 false。
var _season_round_slots_fresh: bool = false
# X2 once-log：累计当 round 内 ensure helper 的 skip / refresh 次数，用于 A/B 验证。
var _season_round_slots_skip_count: int = 0

# refresh-consolidation-2026-06：climate daily round 内 SoA-slots 同步守门员。
# 仿照 _season_round_slots_fresh 模式，但**独立**于 season_refresh round，
# 因为 climate daily 和 season refresh 不重叠（不同 SUS job）。
# 用法：每个 climate sub-pass 入口（pass_a / pass_b / ocean_water / ocean_land /
# sea_ice / transp / wind_air / wind_surface 等）原本调 refresh_slots_from_map()
# 的位置改调 _ensure_climate_daily_round_slots_fresh()。
# climate_daily_system._run_pass 在跨 pass 边界（pass_a→pass_b、ocean_water→ocean_land
# 等）调 _mark_climate_daily_round_slots_stale() 强制下一次 refresh，保证下游
# pass 读到上游 flush 进 MapData 的最新值。round 末尾 climate_daily_system 也调
# _mark_climate_daily_round_slots_stale()，下一 round 启动时重 refresh。
# 实测 ARM 上 refresh_slots_from_map 单次 ~1.5ms（67 component variant unpack），
# climate daily round 内原本 9-12 次调用 → 收编为 3-5 次，预期省 8-12ms/round。
var _climate_daily_round_slots_fresh: bool = false
var _climate_daily_round_slots_skip_count: int = 0
var _climate_daily_round_slots_refresh_count: int = 0
var _season_round_slots_refresh_count: int = 0

# ── DOTS-Final-Frontier Phase B+：season refresh full-round single-call 状态 ──
# B+ 路径将 12-stage round 的"调度层"也下沉到 C++（一次 start_season_round → N 次
# run_season_round_slice → 一次 finish_season_round），上层 SUS Job 仅做 3 次跨界。
# - _season_round_b_plus_handle: C++ 端返回的 round handle（generation 计数器）；
#   <=0 表示当前没有 active round。round 跨帧持有，每个 slice 复用。
# - _season_round_b_plus_logged: once-log 防 spam（gate 失败 / mid-slice 异常各打一次）。
# - _season_round_b_plus_native_ms: 累计 round 总 native_ms，finish 时落到 breakdown。
# 行为变更（用户 2026-05-21 已确认）：B+ 路径下 facade sync + history push 由原 8 次
# /round 收敛为 1 次 /round（finish 末尾）。原多次 push 实为环形缓冲污染，B+ 修复后
# 与"每季度一次状态快照"语义对齐。
var _season_round_b_plus_handle: int = 0
var _season_round_b_plus_logged: Dictionary = {}
var _season_round_b_plus_native_ms: float = 0.0
var _season_round_b_plus_slices_used: int = 0
var _season_round_b_plus_stages_done: int = 0
# B+ round 验收采集器：每个 finish_season_round_b_plus 完成时 append 一条记录，
# 由 dots_final_frontier_perf_verdict.evaluate(season_round_stats=…) 消费。
# pop_b_plus_round_samples() 一次性取走并清零，避免长期增长。
# round_wall_ms = finish 时刻挂钟相对 round 启动的时间（涵盖跨界 + GDScript 包装）。
var _b_plus_rounds_total: int = 0
var _b_plus_rounds_b_plus: int = 0
var _b_plus_rounds_fallback: int = 0
var _b_plus_slices_used_samples: PackedInt32Array = PackedInt32Array()
var _b_plus_stages_done_samples: PackedInt32Array = PackedInt32Array()
var _b_plus_native_ms_samples: PackedFloat32Array = PackedFloat32Array()
var _b_plus_wall_ms_samples: PackedFloat32Array = PackedFloat32Array()
# round 启动时刻（usec），finish 时算 wall_ms。0 表示当前没 active round。
var _b_plus_round_start_usec: int = 0

# True Insolation-Driven Climate（Phase F）：按纬度缓存的"一年平均日射" lookup。
# key  = round(ny * _INSOL_MEAN_LUT_SIZE) ∈ [0, SIZE]
# val  = 16 点数值积分得到的年均 insolation
# 构造时机：refresh_climate_daily 每次运行时按需初始化；axial_tilt 变动时清空重算。
const _INSOL_MEAN_LUT_SIZE: int = 64                  # 65 桶，按 ny 离散，足够 80×60 图使用
const _INSOL_ANNUAL_SAMPLES: int = 16                 # 一年取 16 个 phase 采样点求平均
var _insol_mean_lut: PackedFloat32Array = PackedFloat32Array()
var _insol_mean_lut_tilt: float = -1.0                # 上次构表所用的 axial_tilt_deg，变化时失效
var _insol_driven_path_logged: bool = false           # 首次进入 insolation 主路径时打一次启动日志

# B1-B：每日 round 入口烘焙的"当日 insolation" + "当日 dev" 按 ny 离散 LUT。
# 与 _insol_mean_lut 同粒度（65 桶）。Pass A 内层只剩数组双线性查表，
# 完全消除 _compute_insolation / _insol_dev / _insolation_season_offset 内的
# cos×4 + clamp。一日内复用，phase 变化才重建。
const _INSOL_DAILY_LUT_SIZE: int = 64
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


# DataCore（dots-foundation-and-weather-migration）：暴露给 main.gd 用于
# data_core_status_dict / SUS 日志附加 / 调试控制台。
func get_data_core_world():
	return _data_core_world

# DataCore C++ co-processor（dots-roadmap-to-gdextension 务实 A）：暴露给 climate
# Pass-A，让其在 hot path 入口判断是否可走 C++ 加速。null = 未启用 / gdext 缺失，
# 调用方一律 fallback 到现有 DataCore-GDScript 路径。
func get_data_core_world_ext():
	return _data_core_world_ext

## DataCore（climate-datacore-migration A-3）：把 4 个 climate SoA sub-pass 的
## "数据访问入口"统一收口。返回与 map.xxx_arr 字段访问等价的 PackedArray
## 引用字典；调用方约定每个 sub-pass 入口调一次，循环外取本地引用，hot loop
## 一行不动。
##
## 返回空 Dict（{}）的语义 = "走 legacy 路径"，触发条件：
##   - _data_core_world 未 bind（DCWorld 未创建 / bind_map_data 失败）
##   - _refresh_climate_daily_job.data_core_ready() = false（comp_id 没缓存好）
##
## dots-flag-prune-pr1 (2026-05-22)： use_data_core_climate flag 已删除——
## DataCore views 现恒可用，仅看 world bound + comp_id ready 两个环境条件。
##
## 设计要点：
##   - bind_map_data 保证 view_f32(CELL_TEMP) 与 map.temp_arr 是同一个底层
##     PackedFloat32Array 引用（零拷贝），所以两条路径数值上完全等价；
##   - 此函数本身只在 sub-pass 入口跑一次（每 round 4 次），25 个字段插入的
##     哈希成本约 ~5μs，相对 round 整体 ~10ms 完全可忽略；
##   - 内层 for 循环不应再 lookup 此 Dictionary；调用方必须一次性 .get(...) 出来
##     存到本地 var 再用。
## 调度边界同步：MapData.terrain_arr 是运行期 terrain 的权威源。
## C++/GDScript 写回可能让 GDScript DCWorld 的 U8 mirror 持有旧 PackedArray；
## 在 SUS/DCSystem tick 前按需补齐，避免天气/洋流/气候读取旧地形。
func _sync_data_core_runtime_terrain_mirror(map: MapData, reason: String) -> Dictionary:
	var diag: Dictionary = {
		"terrain_mismatch": 0,
		"is_water_mismatch": 0,
		"terrain_written": false,
		"is_water_written": false,
	}
	if map == null or _data_core_world == null or not _data_core_world.is_bound():
		return diag
	if not _data_core_world.has_method("view_u8") or not _data_core_world.has_method("write_u8_dense"):
		return diag
	var n: int = mini(map.cell_count(), map.terrain_arr.size())
	if n <= 0:
		return diag

	var terrain_mismatch: int = 0
	var cid_terrain: int = _data_core_world.component_id(DCComponentIds.CELL_TERRAIN)
	if cid_terrain >= 0:
		var dc_terrain: PackedByteArray = _data_core_world.view_u8(cid_terrain)
		for i in range(mini(n, dc_terrain.size())):
			if int(dc_terrain[i]) != int(map.terrain_arr[i]):
				terrain_mismatch += 1
		if terrain_mismatch > 0:
			_data_core_world.write_u8_dense(cid_terrain, map.terrain_arr)
			diag["terrain_written"] = true

	var is_water_mismatch: int = 0
	var water_n: int = mini(map.cell_count(), map.is_water_arr.size())
	var cid_is_water: int = _data_core_world.component_id(DCComponentIds.CELL_IS_WATER)
	if cid_is_water >= 0 and water_n > 0:
		var dc_is_water: PackedByteArray = _data_core_world.view_u8(cid_is_water)
		for i in range(mini(water_n, dc_is_water.size())):
			if int(dc_is_water[i]) != int(map.is_water_arr[i]):
				is_water_mismatch += 1
		if is_water_mismatch > 0:
			_data_core_world.write_u8_dense(cid_is_water, map.is_water_arr)
			diag["is_water_written"] = true

	diag["terrain_mismatch"] = terrain_mismatch
	diag["is_water_mismatch"] = is_water_mismatch
	if (terrain_mismatch > 0 or is_water_mismatch > 0) \
			and _dc_terrain_mirror_sync_log_count < _DC_TERRAIN_MIRROR_SYNC_INITIAL_LOGS:
		_dc_terrain_mirror_sync_log_count += 1
		print("[dc/terrain_mirror_sync] reason=%s terrain_mis=%d isw_mis=%d terrain_written=%s isw_written=%s" % [
			reason, terrain_mismatch, is_water_mismatch,
			str(bool(diag["terrain_written"])), str(bool(diag["is_water_written"])),
		])
	return diag


func _climate_views_from_world(cp: ClimateProfile) -> Dictionary:
	if cp == null:
		return {}
	if _data_core_world == null or not _data_core_world.is_bound():
		return {}
	if _refresh_climate_daily_job == null or not _refresh_climate_daily_job.data_core_ready():
		return {}
	# ── Path-C kill-switch（Phase 3a Step 2.0 hotfix · 2026-05-12）─────────
	# 当 DCWorldExt（C++ co-processor）已 bind 但其 run_climate_pass_a 仍处于
	# stub/fallback 阶段时，DCWorldExt::bind_map_data 内部对 map.<f32> 字段做的
	# `set()` 推回会把 PackedFloat32Array 的 refcount 顶到 ≥3，导致 GDScript
	# climate Pass 内 `arr[i] = v` 触发 CoW 写到一份临时 storage 上，函数退出
	# 即销毁，map.temp_arr 永远是初值（→ 渲染层"温度全蓝"）。详见
	# docs/performance-charter.md §11.4 第三行的 "GDScript 端整体赋值后必须
	# bind_map_data" 反向对偶。
	#
	# 折中策略（路 C）：DCWorldExt 已 bind 时，climate Pass 暂时回退到 legacy
	# 直读直写 map.<arr> 路径——绕开 view，避免 refcount 抬升 + CoW 自杀。
	# C++ Pass-A 真正接管（run_climate_pass_a 返回 ≥0）后，整套 GDScript Pass
	# 不再读写 cell-level 数组，此 kill-switch 自动失效（届时该函数返回的 view
	# dict 也不会再被使用）。
	if _data_core_world_ext != null:
		return {}
	var w = _data_core_world
	var j = _refresh_climate_daily_job
	# 25 个 cell-level view（key 命名 = SoA 字段后缀，方便读 sub-pass 时一一对照）
	return {
		"temp": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP)),
		"temp_baseline": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_BASELINE)),
		"temp_30d": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_30D)),
		"temp_365d": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_365D)),
		"temp_anomaly": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_ANOMALY)),
		"moisture": w.view_f32(w.component_id(DCComponentIds.CELL_MOISTURE)),
		"sea_ice_frac": w.view_f32(w.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)),
		"elevation": w.view_f32(w.component_id(DCComponentIds.CELL_ELEVATION)),
		"base_moisture": w.view_f32(w.component_id(DCComponentIds.CELL_BASE_MOISTURE)),
		"ocean_current_x": w.view_f32(w.component_id(DCComponentIds.CELL_OCEAN_CURRENT_X)),
		"ocean_current_y": w.view_f32(w.component_id(DCComponentIds.CELL_OCEAN_CURRENT_Y)),
		"wind_x": w.view_f32(w.component_id(DCComponentIds.CELL_WIND_X)),
		"wind_y": w.view_f32(w.component_id(DCComponentIds.CELL_WIND_Y)),
		"pos_x": w.view_f32(w.component_id(DCComponentIds.CELL_POS_X)),
		"pos_y": w.view_f32(w.component_id(DCComponentIds.CELL_POS_Y)),
		"lat_norm": w.view_f32(w.component_id(DCComponentIds.CELL_LAT_NORM)),
		"temp_baseline_year": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_BASELINE_YEAR)),
		"terrain": w.view_u8(w.component_id(DCComponentIds.CELL_TERRAIN)),
		"landform": w.view_u8(w.component_id(DCComponentIds.CELL_LANDFORM)),
		"vegetation": w.view_u8(w.component_id(DCComponentIds.CELL_VEGETATION)),
		"cover": w.view_u8(w.component_id(DCComponentIds.CELL_COVER)),
		"is_water": w.view_u8(w.component_id(DCComponentIds.CELL_IS_WATER)),
		"climate_dirty_mask": w.view_u8(w.component_id(DCComponentIds.CELL_CLIMATE_DIRTY)),
		"weather_dirty_mask": w.view_u8(w.component_id(DCComponentIds.CELL_WEATHER_DIRTY)),
		# Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个 view
		"ema_initialized": w.view_u8(w.component_id(DCComponentIds.CELL_EMA_INITIALIZED)),
		"temp_season_offset": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_SEASON_OFFSET)),
		"insolation_now": w.view_f32(w.component_id(DCComponentIds.CELL_INSOLATION_NOW)),
		"insolation_dev": w.view_f32(w.component_id(DCComponentIds.CELL_INSOLATION_DEV)),
		"day_length": w.view_f32(w.component_id(DCComponentIds.CELL_DAY_LENGTH)),
		"heat_input": w.view_f32(w.component_id(DCComponentIds.CELL_HEAT_INPUT)),
		"thermal_energy": w.view_f32(w.component_id(DCComponentIds.CELL_THERMAL_ENERGY)),
		"snowpack": w.view_f32(w.component_id(DCComponentIds.CELL_SNOWPACK)),
		"water_balance_30d": w.view_f32(w.component_id(DCComponentIds.CELL_WATER_BALANCE_30D)),
	}


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
# 0.4.1：_sus 改为 untyped 多态引用，可能是 SlicedUpdateScheduler（legacy）
# 或 DCSystemScheduler（use_dc_system_scheduler=true）。两者 API 兼容：
# bind_world / tick / reset_all_progress / report_last_tick / report_last_tick_summary
# 同形；frame_budget_ms / log_interval_ticks 同名公共字段。
var _sus = null
# Phase 1.4 — sus_systems_bootstrap 引用（接口骨架；attach_post_setup 在
# _setup_sus 末尾被调用。main.gd 通过 get_sus_bootstrap() 拿引用做诊断）。
var _sus_bootstrap: RefCounted = null

# 0.4.1：是否走 DCSystemScheduler 新路径。在 _setup_sus 入口由
# ClimateProfile.use_dc_system_scheduler 决定；用于 build_topology / register_system
# 分支判定。
var _use_dc_system_scheduler: bool = false
# DataCore World（dots-foundation-and-weather-migration）：
# 与 _sus 同生命周期，在 _setup_sus 内创建并按 ClimateProfile.use_data_core 决定
# 是否 bind_map_data。job 通过 SUS.bind_world 自动注入。
var _data_core_world: DCWorld = null
# DataCore World — C++ co-processor（dots-roadmap-to-gdextension 务实 A）：
# 仅服务于 climate Pass-A 的 C++ 加速；与 _data_core_world 共享同一份 MapData
# PackedArray（CoW alias，详见 docs/performance-charter.md §11 + Phase 3a Step 2.0
# 验证报告）。weather / sus / ECB 完全不感知此实例。
# - use_data_core=true 时创建并 bind_map_data；否则保持 null
# - climate Pass-A 入口检查 _data_core_world_ext != null && run_climate_pass_a()>=0
#   决定是否走 C++ 加速；任何失败一律 fallback 到 DataCore-GDScript 路径
# - ClassDB.instantiate("DCWorldExt") 由 gdext/src/register_types.cpp 注册
var _data_core_world_ext: RefCounted = null  # DCWorldExt（来自 gdext，无 GDScript class_name）
const _DC_TERRAIN_MIRROR_SYNC_INITIAL_LOGS: int = 12
var _dc_terrain_mirror_sync_log_count: int = 0
# DOTS-Total-CPP（任务 6）：ocean_water_pass 同 tick 复用 short-circuit。
# climate_daily 与 ocean_currents_job 都可能调 _ocean_water_pass；同一 phase
# 只跑一次。NaN = 未跑过；reset_progress 时清回 NaN。
var _ocean_water_done_phase: float = NAN
# F.5 transpiration pass C++ 加速运行时统计（charter §7 P2，3.2ms → 0.3ms 目标）。
# 一次性诊断 print + 累计 runs / fallbacks / total_ms 供 HUD / 后续 dots-f5-validation.md 验收。
var _gdext_transp_runs: int = 0
var _gdext_transp_fallbacks: int = 0
var _gdext_transp_total_ms: float = 0.0
var _gdext_transp_first_attempt_logged: bool = false
# Stale .dll 兜底：第一次 attempt 时用 get_method_list 验证 run_transpiration_pass
# 的实际签名 vs 期望（1 个 Dictionary）。不匹配（旧 stub 是 3 个参数：donor_table /
# outflow_rate / self_rate）时静默 disable F.5 fast path 整个 session，避免
# "binding 拒调 → rc=0.0 → 误判 success → SoA 静默不写 → transpiration silently
# no-op" 这类隐藏 bug。出问题时 push_warning 一次提示 rebuild 命令。
var _gdext_transp_signature_checked: bool = false
var _gdext_transp_signature_ok: bool = false
# Donor table 一次性 cache：按 VegetationType.VEG enum 顺序的 transpiration 值。
# VEG enum 大小固定（vegetation_type.gd:33-58），运行期不会变。但 reload climate_profile
# 时不影响——transpiration 是 VegetationProfileRegistry 静态查询，profile 资源换了
# 也不会影响这个 table 的生成。invalid 时调 _build_transpiration_donor_table() 重建。
var _gdext_transp_donor_table_cached: PackedFloat32Array = PackedFloat32Array()

# ─── DOTS-Final-Push（plan/dots-final-push）：stage_b 三件套运行时统计 ────
# albedo / vegetation_dynamics / climate_feedback 三段 C++ 化的诊断与 perf 计数。
# 与 F.5 transp 共享同套模式：first_attempt_logged + signature_checked +
# runs / fallbacks / total_ms 累计。stride 字段沿用 ClimateProfile 已有的
# weather_albedo_stride / weather_vegetation_dynamics_stride / weather_feedback_stride。

# albedo（任务 2）—— 使用与 climate_pass_b 同款 albedo_table（按 VEG enum 顺序）。
var _gdext_albedo_runs: int = 0
var _gdext_albedo_fallbacks: int = 0
var _gdext_albedo_total_ms: float = 0.0
var _gdext_albedo_first_attempt_logged: bool = false
var _gdext_albedo_signature_checked: bool = false
var _gdext_albedo_signature_ok: bool = false
var _gdext_albedo_table_cached: PackedFloat32Array = PackedFloat32Array()

# vegetation_dynamics（任务 3）—— 演替主循环 C++ 化。需要 6 张 LUT：
#   ideal_temp / ideal_moist / temp_tol / moist_tol / weather_penalty /
#   resistance(VEG×WT 平铺)。next_up / next_down 是 PackedByteArray。
# vitality / low_streak / high_streak 通过 in/out PackedArray 走 caller pack/unpack。
var _gdext_vegdyn_runs: int = 0
var _gdext_vegdyn_fallbacks: int = 0
var _gdext_vegdyn_total_ms: float = 0.0
var _gdext_vegdyn_first_attempt_logged: bool = false
var _gdext_vegdyn_signature_checked: bool = false
var _gdext_vegdyn_signature_ok: bool = false
var _gdext_vegdyn_ideal_temp_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_ideal_moist_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_temp_tol_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_moist_tol_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_weather_penalty_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_resistance_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_next_up_cached: PackedByteArray = PackedByteArray()
var _gdext_vegdyn_next_down_cached: PackedByteArray = PackedByteArray()

# climate_feedback（任务 4）—— 反馈三件套最后一段。base_moisture 直接走 SoA；
# soil_moisture / vegetation_growth_pressure / temperature_transport_anomaly
# 三个字段尚未 SoA 化，走 in/out PackedArray pack/unpack（前两者 in/out，
# 后者只读）。
var _gdext_feedback_runs: int = 0
var _gdext_feedback_fallbacks: int = 0
var _gdext_feedback_total_ms: float = 0.0
var _gdext_feedback_first_attempt_logged: bool = false
var _gdext_feedback_signature_checked: bool = false
var _gdext_feedback_signature_ok: bool = false

# 方案 B：stage_b 三段合并（plan/stage-b-combine）运行时统计。
# 触发于 refresh_daily_stage_b 入口的合并快路径分支；与上面三个独立 pass 的统计
# 互斥（合并成功一次 ≈ 三独立 pass 各被替代一次）。fallback 时下面三独立 wrapper
# 接管，独立统计计数器仍正常累加。
var _gdext_stage_b_runs: int = 0
var _gdext_stage_b_fallbacks: int = 0
var _gdext_stage_b_total_ms: float = 0.0
var _gdext_stage_b_first_attempt_logged: bool = false

# F.3 climate Pass-B C++ 加速运行时统计（charter §7 P1，5.2ms → 0.5ms 目标）。
var _gdext_climate_b_runs: int = 0
var _gdext_climate_b_fallbacks: int = 0
var _gdext_climate_b_total_ms: float = 0.0
var _gdext_climate_b_first_attempt_logged: bool = false
var _gdext_climate_b_signature_checked: bool = false
var _gdext_climate_b_signature_ok: bool = false
# Foliage table cache（按 VegetationType.VEG enum 顺序）：
# foliage[v] = clamp(VegetationType.transpiration(v) / 0.06, 0, 1)
# 与 _vegetation_foliage_density(veg) 等价。F.3 hot loop 内 albedo 项要查 foliage，
# 一次性 cache 避免重复查 VegetationProfileRegistry。
var _gdext_climate_b_foliage_table_cached: PackedFloat32Array = PackedFloat32Array()

# F.2 ocean water + land pass C++ 加速运行时统计（charter §7 P1，6.8ms → < 1ms 总）。
var _gdext_ocean_water_runs: int = 0
var _gdext_ocean_water_fallbacks: int = 0
var _gdext_ocean_water_total_ms: float = 0.0
var _gdext_ocean_water_first_attempt_logged: bool = false
var _gdext_ocean_water_signature_checked: bool = false
var _gdext_ocean_water_signature_ok: bool = false
var _gdext_ocean_land_runs: int = 0
var _gdext_ocean_land_fallbacks: int = 0
var _gdext_ocean_land_total_ms: float = 0.0
var _gdext_ocean_land_first_attempt_logged: bool = false
var _gdext_ocean_land_signature_checked: bool = false
var _gdext_ocean_land_signature_ok: bool = false
# F.2 共享 anomaly buffer：water pass 写完后 land pass 复用，避免再 cells→array 拷贝。
# tick 末尾隐式失效（下次 water pass 重新构建）。
var _gdext_ocean_anomaly_buf_cached: PackedFloat32Array = PackedFloat32Array()
# F.2 共享 baseline buffer：water pass 计算的 baseline（含 ema_init 分支 +
# _compute_temperature 兜底），land pass C++ 用作 t_prev 兜底（修复 cell temp
# 锁死在 0 的正反馈 bug，2026-05-13 用户验收踩过）。
var _gdext_ocean_baseline_arr_cached: PackedFloat32Array = PackedFloat32Array()
# F.2 共享 ocean_current buffer：physical C++ 路径会同步写 map.ocean_current_x/y_arr；
# water/land pass 直接读 SoA，避免每次从 HexCell facade 反向打包。
var _gdext_ocean_current_x_arr_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_current_y_arr_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_baseline_work_buf: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_temp_before_work_buf: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_anomaly_work_buf: PackedFloat32Array = PackedFloat32Array()
var _gdext_wind_baseline_work_buf: PackedFloat32Array = PackedFloat32Array()
var _gdext_wind_temp_before_work_buf: PackedFloat32Array = PackedFloat32Array()
var _climate_ocean_slice_state: Dictionary = {}

# Generic climate chunk API：统一管理 pass 生命周期、token、游标与 abort。
const _CLIMATE_PASS_OCEAN_WATER: String = "ocean_water"
const _CLIMATE_PASS_OCEAN_LAND: String = "ocean_land"
const _CLIMATE_PASS_SEA_ICE: String = "sea_ice"
const _CLIMATE_PASS_STATUS_RUNNING: String = "running"
const _CLIMATE_PASS_STATUS_DONE: String = "done"
const _CLIMATE_PASS_STATUS_FAILED: String = "failed"
const _CLIMATE_PASS_STATUS_ABORTED: String = "aborted"
var _climate_pass_generation: int = 0
var _climate_pass_states: Dictionary = {}

# F.4 sea_ice daily pass C++ 加速运行时统计（charter §7 P2，5.1ms → 0.5ms 目标）。
var _gdext_sea_ice_runs: int = 0
var _gdext_sea_ice_fallbacks: int = 0
var _gdext_sea_ice_total_ms: float = 0.0
var _gdext_sea_ice_first_attempt_logged: bool = false
var _gdext_sea_ice_signature_checked: bool = false
var _gdext_sea_ice_signature_ok: bool = false

# [S2 fix 2026-05-23] sea_ice dt 补偿：sea_ice pass 原本假定"每天调一次"，
# 但 daily_climate_refresh_stride=2 + climate_daily round 内 6 个 sub-pass 串行
# 推进，导致两次 sea_ice pass 的真实游戏日间隔从 1 天滑到 ~10-30 天，海冰
# 推进显著滞后于温度/季节相位。修复：记录上次 pass 时的 WorldClock.current_day，
# 本次 pass 用 (now - last) 作为 dt_days 乘到 d_frac 上，让物理推进按"实际
# 经过游戏天数"而不是"调用次数"驱动。clamp 上限 30 天用于：
#   1) 开局（_last_sea_ice_pass_day = -1）走 1.0 默认，避免大跳；
#   2) 长时间 pause 后恢复，避免一次推进几百天导致全图冻死/全融。
# 详见 docs/dots-master-execution-handbook.md §sea_ice-dt-compensation。
var _last_sea_ice_pass_day: float = -1.0

# [thermal dt 补偿 2026-06-16] climate pass_a 热惯性与 sea_ice 同病：原本假定
# "每天松弛一次 α"，但加速/跳日运行下两次 pass_a 的真实间隔会滑到 ~10-30 天，
# 导致温度（尤其低 α 的海洋）严重欠积分、滞后太阳直射点、极地降不下来。
# 修复与 sea_ice 对称：记录上次 pass_a 的 current_day，本次用 (now-last) 作为
# dt_days，把 α 换算为多日等效 α_eff=1-(1-α)^dt、delta_cap 乘 dt。
# _climate_dt_cached_* 用于同一仿真日内多个 knob builder 取到一致 dt 且只推进一次游标。
var _last_climate_pass_day: float = -1.0
var _climate_dt_cached_day: float = -1.0
var _climate_dt_cached_val: float = 1.0

# Sea ice 多 tick 状态机阶段。native 快路径会拆成：
# native_compute → dense_sync_chunk → terrain_flip_chunk → commit。
const _SEA_ICE_STAGE_NATIVE_COMPUTE: String = "native_compute"
const _SEA_ICE_STAGE_DENSE_SYNC_CHUNK: String = "dense_sync_chunk"
const _SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK: String = "terrain_flip_chunk"
const _SEA_ICE_STAGE_COMMIT: String = "commit"
var _sea_ice_state_machine: Dictionary = {}

# 方案 ① Step 1（确诊）：sea_ice pass total_wall_ms ≥ SLOW_DUMP_THRESHOLD_MS 时
# 强制打印 _last_sea_ice_daily_breakdown 全字段（path/pack/refresh/native/native_wall/
# sync/flip/total_wall/water/flipped），让用户一眼看出 7ms 是 GDScript fallback
# 还是 gdext 路径但 pack/sync 拖慢。节流到至少 30 fast tick 间隔一次，避免刷屏。
const _SEA_ICE_SLOW_DUMP_THRESHOLD_MS: float = 5.0
const _SEA_ICE_SLOW_DUMP_MIN_INTERVAL: int = 30
var _sea_ice_slow_dump_last_tick: int = -10000

# Plan: civ-grounded-development / 方案 ④（weather cyclone 突刺诊断）
# 5/21 perf 数据 tick 165 cyclone_ms = 6.49ms（其余 48 帧均 0.13~0.17ms，差 40 倍）。
# 强烈怀疑某种"风暴诞生/合并/死亡"路径走了一次性重操作。先加一次性诊断：
# weather 总 tick ≥ 5ms 或 cyclone_ms ≥ 3ms 任一触发时打 _last_weather_breakdown 全字段。
# 节流到至少 30 fast tick 间隔一次，避免突刺连帧刷屏。
const _WEATHER_SLOW_DUMP_TOTAL_THRESHOLD_MS: float = 5.0
const _WEATHER_SLOW_DUMP_CYCLONE_THRESHOLD_MS: float = 3.0
const _WEATHER_SLOW_DUMP_MIN_INTERVAL: int = 30
var _weather_slow_dump_last_tick: int = -10000
# F.4 共享 buffer：base_terrain / temp_transport_anomaly / upwelling_strength / cell.temperature
# 按 cells 索引提取（schema 没有 SoA 镜像，或与 GDScript 1:1 mirror 必须用 cell 字段）。
# 一个 tick 内 build 一次（不 cache 跨 tick：transport_anomaly / upwelling / temperature 每日变）。
#
# 关键 (2026-05-14)：cell_temp_buf 必须从 cell.temperature 打包，**不**能让 C++
# 直接读 SoA slot cell_temp。原因：sliced 路径下 pass_b/ocean_water/ocean_land
# 都是 C++ 跑，写 SoA 不回写 cell.temperature；GDScript fallback _apply_sea_ice
# 读 cell.temperature 拿到的是 pass_a 之后的"基线温度"（更暖），而 SoA 是
# ocean_land 之后的"修正温度"（更冷）。读错温度 → sea_ice 算冰过多 → 全图下雪。
var _gdext_sea_ice_base_terrain_buf: PackedByteArray   = PackedByteArray()
var _gdext_sea_ice_tta_buf:          PackedFloat32Array = PackedFloat32Array()
var _gdext_sea_ice_upw_buf:          PackedFloat32Array = PackedFloat32Array()
var _gdext_sea_ice_temp_buf:         PackedFloat32Array = PackedFloat32Array()
var _gdext_sea_ice_insol_buf:        PackedFloat32Array = PackedFloat32Array()

# ─── 通用 helper：验证 DCWorldExt 某个方法的实际参数数 vs 期望 ─────────
# 解决 stale gdext .dll 与新 GDScript 调用 site 签名不一致时的"静默 no-op"问题：
# 在 has_method() 检查通过但运行时 binding 拒绝（"Invalid call ... Expected N
# argument(s)"）的情况下，函数返回 null，调用方 float(null)=0.0，看似成功但
# C++ 端实际没干活。本 helper 在第一次 attempt 时主动核对，不匹配就 push_warning
# + 返回 false，让调用方永久走 GDScript fallback 直到下次 reload 项目。
#
# 用法（推荐放在 fast-path 入口 if 里）：
#   if not _gdext_transp_signature_checked:
#       _gdext_transp_signature_checked = true
#       _gdext_transp_signature_ok = _validate_gdext_method_signature(
#           "run_transpiration_pass", 1)
#   if _gdext_transp_signature_ok:
#       ... 调 C++
func _validate_gdext_method_signature(method_name: String, expected_arg_count: int) -> bool:
	if _data_core_world_ext == null:
		print("[gdext sig] %s: ext is null → false" % method_name)
		return false
	var ml: Array = _data_core_world_ext.get_method_list()
	# 在所有 method 里找匹配名字的（不止 1 个：godot-cpp 可能把 setter / getter 同名注册）。
	var matches: Array = []
	for m: Dictionary in ml:
		if String(m.get("name", "")) == method_name:
			matches.append(m)
	if matches.is_empty():
		print("[gdext sig] %s: NOT FOUND in get_method_list() (total entries=%d) → false" % [method_name, ml.size()])
		push_warning("[gdext sig] %s not found in DCWorldExt; gdext .dll is STALE or method removed." % method_name)
		return false
	# 全部 match 都 dump 一次，无脑诊断
	for i in range(matches.size()):
		var m: Dictionary = matches[i]
		var args: Array = m.get("args", [])
		var arg_names: PackedStringArray = PackedStringArray()
		for a in args:
			arg_names.append(String(a.get("name", "<noname>")))
		print("[gdext sig] %s match[%d]: args.size()=%d names=[%s] flags=%d id=%d" % [
			method_name, i, args.size(), ", ".join(arg_names),
			int(m.get("flags", 0)), int(m.get("id", -1)),
		])
	# 只要任意一个 match 的 args.size() == expected → 通过
	for m: Dictionary in matches:
		var args: Array = m.get("args", [])
		if args.size() == expected_arg_count:
			print("[gdext sig] %s: probe PASS (found match with %d args)" % [method_name, expected_arg_count])
			return true
	push_warning("[gdext sig] %s: NONE of %d matches has expected_arg_count=%d. gdext .dll likely STALE; REBUILD: 'cd gdext && scons platform=windows target=template_release dev_build=no -j8'." % [method_name, matches.size(), expected_arg_count])
	return false
var _ocean_currents_job: OceanCurrentsJob = null
# 任务 8：refresh_climate_daily / refresh_daily 也作为 SUS Job 注册，
# stride 由 ClimateProfile 字段驱动；speed_changed 时重建对应 Job 的 policy。
# W.1：RefreshClimateDailyJob 现已退化为 ClimateDailySystem 的薄壳。当
# use_dc_system_scheduler=true 时 get_inner() 返回 ClimateDailySystem 自身；
# 当 use_dc_system_scheduler=false 时直接 new RefreshClimateDailyJob（仍是
# ClimateDailySystem 子类）。改 untyped 容纳两种返回类型。
var _refresh_climate_daily_job = null
var _sea_ice_daily_job = null
var _weather_refresh_job: WeatherRefreshJob = null
# Daily Sim SoA Refactor 阶段 1：海冰 GPU 上传 Job。
# 0.4.1：以下 3 个引用类型放宽为 untyped。原因：当 use_dc_system_scheduler=true
# 时，这些字段会指向 SeaIceAtlasUploadSystem / EnumAtlasUploadSystem /
# SeasonRefreshSystem 实例（DCSystem 子类，IS-A SusJob 但 NOT-A 原始 Job 类）。
# 既有调用面（depends_on.append / 不再被读）兼容 SusJob 抽象，故放宽类型安全。
var _sea_ice_atlas_upload_job = null
var _dynamic_visual_atlas_upload_job = null
var _weather_lut_upload_job = null
# 2026-05-19：dynamic/ecology/smooth/ice 四张 atlas 的上传 stride（默认 2 仿真日）。
# HexRenderer 通过 set_dyn_atlas_upload_stride() 在运行时调整；构造期前若 hex_renderer
# 已先 setter 过来，这里会持久化为非 2 的值。
var _dyn_atlas_upload_stride: int = 2
var _enum_atlas_upload_job = null
var _native_daily_sim_job = null
var _native_environment_runtime_job = null
var _native_daily_configured: bool = false
var _native_daily_last_result: Dictionary = {}
var _native_generation_base_report: Dictionary = {}
var _native_daily_shadow_probe_logged: bool = false
# Phase A.2 unified fast tick：once-log + fallback once-warn。
var _unified_fast_tick_first_log_done: bool = false
var _unified_fast_tick_warned_fallback: bool = false
var _sus_map: MapData = null
var _sus_world: WorldData = null
var _environment_runtime: RefCounted = null
var _season_refresh_job = null
# main.gd 在 _ready 末尾通过 set_world_clock_ref(world_clock) 注入，给
# OceanCurrentsJob 的 season_phase getter 用。
var _world_clock_ref = null
# 一次性 deprecated 字段警告守门（避免同一会话反复 print）。
var _ocean_legacy_warning_logged: bool = false
# DOTS-Total-CPP 真·收尾（2026-05-21）：原来的 _season_refresh_gdext_fallback_logged
# 是"全 stage 共享一个 once-flag"，导致 8 个 stage 只要任一个先 fallback，后面 7 个
# 全部静默——用户无法看到每个 stage 实际走哪条路。
# 改成 per-stage-key 的 set：键为 "stage1" / "stage1_gdext" / "stage1_fb:ext" 等，
# 每个键在同会话内只打印一次；同时给每个 stage 在 success / 各 fallback 分支都加日志。
var _season_refresh_gdext_fallback_logged: bool = false  # DEPRECATED: 不再写入；保留声明只为兼容历史外部读引用
var _season_stage_path_logged: Dictionary = {}

# ─── 任务 6：refresh_seasonal per-cell 起点优化（方案 C）───────────────────
# 行级查表：纬度温度 + 当季温度偏移 都只取决于 ny（= row / (height-1)），
# 与 cell.elevation 无关。在 refresh_seasonal 入口一次性建表（O(height)），
# 主循环 5 处全图遍历共 ~5×(W*H) 次 cell 访问改成 O(1) 查表，省掉每 cell 一次
# pow + cos + 一次三角函数调用。预期普通季 525ms → 350~420ms。
# 仅缓存当前 season 一份；season 切换时自动重建（O(height)，对 256 行约 1ms）。
# 对其他子 pass（rain_shadow / river_ecology / shrubland / mangrove / glacier）
# 暂不渗透，保持改动面最小，风险最低。
# 纬度温度钟形曲线统一到 DCClimateMath.lat_temp_bell（全工程单一来源）；本文件不再
# 就地重写 pow(cos(...))。极地温度/海冰调参改 DCClimateMath.LAT_TEMP_CURVE_EXP。
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
		_row_lat_temp[r] = DCClimateMath.lat_temp_bell(lat_signed)
		_row_season_off[r] = _season_temp_offset(ny, season)
	_row_tables_season = season
	_row_tables_height = H

# ─── 公开接口 ────────────────────────────────────────────────────────────

func generate(cfg: MapConfig, hex_size: float) -> Dictionary:
	cfg.validate()
	_abort_all_climate_passes("generate_restart")

	var effective_seed: int = cfg.seed if cfg.seed != 0 else randi()
	_rng = RandomNumberGenerator.new()
	_rng.seed = effective_seed
	_init_noise(effective_seed)

	_last_cfg = cfg
	_last_hex_size = hex_size
	_last_seed = effective_seed
	_current_season = -1
	_weather_stage_b_call_index = -1
	_enum_atlas_biome_dirty = false
	_enum_atlas_cover_dirty = false
	_enum_atlas_vegetation_dirty = false
	_last_enum_atlas_upload_breakdown = {}
	_season_stage4_deltas.clear()
	_pending_season_refresh = false
	_season_refresh_in_progress = false
	_last_season_refresh_breakdown = {}
	# X2-精简版：reset 时清掉 SoA-slots 缓存标志，避免新世界生成跨用上个世界的 stale fresh。
	_season_round_slots_fresh = false
	_season_round_slots_skip_count = 0
	_season_round_slots_refresh_count = 0

	var t_total := Time.get_ticks_msec()
	# dots-total-cpp（2026-06-18）：地图生成已 100% C++（base + post_base，逐字段 A/B
	# parity PASS）。GDScript 生成 fallback（_generate_cells / 后处理）已删除——native
	# 失败即硬中止，绝不静默降级。失败的常见原因：DLL 未 rebuild / DCWorldExt 未注册 /
	# native_generation_mode != ACTIVE。
	var map := _generate_cells_native_base(cfg, effective_seed)
	if map == null:
		push_error("[generate] native C++ 生成失败且 GDScript fallback 已移除（dots-total-cpp）。"
			+ "请检查：GDExtension DLL 是否已 rebuild、DCWorldExt 是否注册、"
			+ "ClimateProfile.native_generation_mode 是否为 ACTIVE(2)。中止本次生成。")
		return {}
	print("MapGenerator v7: per-cell %dms (%d cells, path=gdext_base)" % [Time.get_ticks_msec() - t_total, map.cell_count()])

	# Milestone 1：landform / vegetation / cover 三轴在 native post_base 结果里已就绪
	# （_assemble_native_generation_map 装配时写入），无需再 _sync_axes_for_map。
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
	# 转发 baker.stage_progress → generator.bake_progress（main.gd 已订阅）。
	if _baker.has_signal("stage_progress") and not _baker.stage_progress.is_connected(_on_baker_stage_progress):
		_baker.stage_progress.connect(_on_baker_stage_progress)
	if _world_clock_ref != null and _baker.has_method("set_world_clock_ref"):
		_baker.set_world_clock_ref(_world_clock_ref)
	# Physical Wind & Ocean Circulation：把 ClimateProfile 注入 cfg，让 MapBaker
	# 在 bake_world 内部检测 physical_circulation_enabled 等开关。生成阶段先注入一次；
	# OceanCurrentsJob 注册时还会重复注入一次，保持 cfg.climate_profile 始终为
	# 当前激活的 profile。
	if cfg != null:
		cfg.climate_profile = _c()
	# [fix cell-indirect 2026-06-16] cell.index 必须在 bake_world 之前赋值。
	# bake_world 内部 _bake_height_biome_moisture 会按 cell.index 建 CSR，并把
	# cell.index fan-out 到 map_index_atlas.g/b。原 _build_indices() 在 bake 之后
	# (下方 ~L1205)才跑，会导致 bake 期间 cell.index 全是默认 -1 → CSR 全跳过、
	# map_index_atlas 写哨兵(0xFFFF) → shader 解码全 -1。这里提前建一次索引
	# (幂等：下方 _build_indices / init_soa_from_bake 会按同一 _cells 顺序再建，
	# cell.index 与 SoA terrain_arr 排布严格一致)。此刻 has_soa() 仍为 false，
	# 物理环流 defer 分支(MapBaker._bake_initial_physical_circulation)行为不变。
	map._build_indices()
	# [snow-dyn-valid-fix 2026-06-16] 温度 Bootstrap 必须在 bake_world 之前执行。
	# 原因：bake_world 内部 rebake_dynamic_cell_atlas_only / bake_cell_luts 会把
	# cell.temperature 烘进动态 atlas/LUT 的 R 通道。若此刻温度仍是默认 0.0，首帧
	# atlas 全图 temp=0；旧 shader 靠 dyn_valid=step(0.02,dyn_temp) 兜底回退到
	# derived_temp，但该哨兵会把真实极寒格(温度=0)误判为"未初始化"→ 整格动态状态
	# (含雪盖)被清零。前移后 atlas 从第 0 帧即带真实纬度温度，dyn_valid 不再需要
	# （shader 端已同步移除）。
	# 依赖：cfg / cell.elevation / base_moisture / terrain / landform / vegetation /
	# cover 均在 _generate_cells（bake 前）就绪；不依赖 bake 产物。下方 bake 后的
	# _compute_ocean_currents / _compute_terrain_perturbed_wind 均不读 cell.temperature，
	# 故前移对它们 bit-for-bit 无影响。
	#
	# 初始 current_state（认为是夏季中段，等 main.gd 推第一次 season_changed 再更新）
	# Bootstrap: 同时把温度写入 HexCell backing field，确保 init_soa_from_bake()
	# 的 SoA 镜像（temp_arr / temp_30d_arr / temp_365d_arr / thermal_energy_arr）
	# 开局就是正确的纬度温度，而不是默认 0.0。
	for cell: HexCell in map.all_cells():
		var _boot_ny: float = _cube_row_norm(cell, cfg)
		var _boot_temp: float = _compute_temperature(_boot_ny, cell.elevation)
		# ── current_state 字典（UI / legacy 消费者用） ──
		cell.current_state = {
			"season": 1,
			"temperature": _boot_temp,
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
		# ── 温度 Bootstrap：直写 backing field，跳过 facade（生成期 _facade_enabled=false）─
		cell._temperature_backing = _boot_temp
		cell._temp_baseline_backing = _boot_temp
		cell._temp_30d_mean_backing = _boot_temp
		cell._temp_365d_mean_backing = _boot_temp
		cell._temp_dev_from_annual_backing = 0.0
		cell._ema_initialized = true
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
				clampi(int(cp_ec.weather_field_advect_steps), 0, 8),
				float(cp_ec.weather_field_diffusion),
				float(cp_ec.weather_condensation_gain),
				float(cp_ec.weather_precip_decay),
				float(cp_ec.weather_orographic_lift_gain),
				float(cp_ec.weather_convergence_gain),
				float(cp_ec.weather_ocean_evap_gain),
				mini(int(cp_ec.weather_component_summary_limit), 12),
				int(cp_ec.weather_convergence_refresh_stride),
				float(cp_ec.weather_precip_carryover_max),
				float(cp_ec.weather_vapor_precip_sink),
				float(cp_ec.snowpack_accum_gain),
				float(cp_ec.snowpack_melt_temp_gain),
				float(cp_ec.snowpack_melt_sun_gain),
				float(cp_ec.snowpack_cover_low),
				float(cp_ec.snowpack_cover_full),
				int(cp_ec.snow_accum_days_req) if cp_ec.get("snow_accum_days_req") != null else 2,
				float(cp_ec.weather_temp_anomaly_cap),
				float(cp_ec.snowline_temp_threshold) if cp_ec.get("snowline_temp_threshold") != null else 0.24,
				float(cp_ec.snowline_band) if cp_ec.get("snowline_band") != null else 0.22,
				float(cp_ec.weather_vapor_relax_rate) if cp_ec.get("weather_vapor_relax_rate") != null else 0.08,
				float(cp_ec.weather_orographic_lift_cap) if cp_ec.get("weather_orographic_lift_cap") != null else 0.35,
				float(cp_ec.weather_wet_terrain_precip_damping) if cp_ec.get("weather_wet_terrain_precip_damping") != null else 0.28,
				float(cp_ec.weather_lake_precip_damping) if cp_ec.get("weather_lake_precip_damping") != null else 0.35,
				float(cp_ec.weather_lake_evap_scale) if cp_ec.get("weather_lake_evap_scale") != null else 0.35,
				float(cp_ec.weather_extreme_precip_soft_cap) if cp_ec.get("weather_extreme_precip_soft_cap") != null else 0.16,
				float(cp_ec.weather_extreme_precip_softness) if cp_ec.get("weather_extreme_precip_softness") != null else 0.20,
				float(cp_ec.weather_land_evapotranspiration_gain) if cp_ec.get("weather_land_evapotranspiration_gain") != null else 0.70,
				float(cp_ec.weather_precip_rh_threshold) if cp_ec.get("weather_precip_rh_threshold") != null else 0.70,
				float(cp_ec.weather_ocean_precip_suppression) if cp_ec.get("weather_ocean_precip_suppression") != null else 0.95,
				float(cp_ec.weather_frontogenesis_gain) if cp_ec.get("weather_frontogenesis_gain") != null else 0.42,
				float(cp_ec.weather_rain_shadow_drying) if cp_ec.get("weather_rain_shadow_drying") != null else 0.35,
				float(cp_ec.weather_vapor_transport_gain) if cp_ec.get("weather_vapor_transport_gain") != null else 0.75
			)

	# ─── Daily-Sim SoA Refactor 阶段 2：构建邻居索引 SoA ──────────────────
	# 此时所有 cell 已入库、terrain 已定型（包括河流、火山、湖泊、海冰首日
	# 状态等慢层常量），fast-tick 路径需要的稳定邻居拓扑已就绪。一次性预
	# 计算 _cell_array / _cell_index / _neighbor_indices，之后 fast-tick
	# 热路径直接通过 idx*6+dir 查表，不再走 6 次字典 lookup。
	# regenerate 路径：MapData 实例随每次 generate() 调用整体替换，本次构建
	# 的索引随旧 MapData 一起被丢弃，无需手动 invalidate。
	map._build_indices()

	# ─── Climate-Weather 2ms Budget 阶段 A.1：构建 SoA 镜像 ─────────────
	# 一次性把 25 个热字段从 HexCell 同步到 SoA 数组。后续 climate / weather
	# sub-pass 在阶段 A.3+ 切到 SoA 路径后将直接读写这些数组，避免每次取
	# Variant / 字典 lookup。本调用是幂等的 — bake_world / 加载存档 / regenerate
	# 都可以安全调用一次。
	# PR-2.2 DEPRECATED：本函数仅生成期/加载期调用，运行期已全部走 world.write_*_indexed。
	# PR-2.3 HexCell facade 化完成 + 加载/regenerate 路径改为 _alloc_soa + 一次性
	# write_f32_indexed 全字段后可彻底删除（master 手册 §3.10.3）。
	# 任务 3（dots-completion）：改用语义化别名 init_soa_from_bake()，明确"仅 bake 时调用"。
	map.init_soa_from_bake()
	var env_pixel_size: Vector2i = Vector2i.ZERO
	if world != null and "derived_size" in world:
		env_pixel_size = world.derived_size
	ensure_environment_runtime(map, env_pixel_size)
	# B1-A：SoA 就位后立即 bake 每 cell 的常量 LUT（归一化纬度 + 年均温度）。
	# Pass A 运行期内层仅需数组索引，不再调用 _cube_row_norm / pow / cos。
	map.bake_lat_temp_year_lut(self)
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
	_sus_map = map
	_sus_world = world
	# 创建一个全新 SUS 实例（regenerate 路径会让旧实例随 MapGenerator 一起被替换，
	# 不需要手动 reset_all_progress）。
	#
	# 0.4.1：根据 ClimateProfile.use_dc_system_scheduler 选择调度器实现。
	#   - false（默认）→ SlicedUpdateScheduler，6 个原始 SusJob 通过 register_job 注册
	#   - true → DCSystemScheduler（内部仍用 SlicedUpdateScheduler 做 tick）；
	#     6 个 DCSystem wrapper 通过 register_system 注册；最后 build_topology
	#     用 reads/writes 重写 priority 实现拓扑序运行
	# 调度器 API 同形：bind_world / tick / reset_all_progress / report_last_tick /
	# report_last_tick_summary 同名同签名。
	# dots-flag-prune-pr1 (2026-05-22)： use_dc_system_scheduler flag 已删除——
	# DCSystemScheduler 现恒走单路径（6 个 DCSystem wrapper + 拓扑排序）。
	# _use_dc_system_scheduler 变量保留作为内部常量 true，避免下游 if 分支改动。
	var cp_sched := _c()
	_use_dc_system_scheduler = true
	_sus = DCSystemSchedulerScript.new()
	_sea_ice_daily_job = null
	_apply_sim_budget_profile_to_scheduler(cp_sched)
	# DataCore World 接入（dots-foundation-and-weather-migration）：
	# 在 SUS 注册任何 job 前先把 World 实例创建出来并 bind 到 MapData，
	# 这样所有 register_job 会自动被注入 world 引用。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_data_core flag 已删除——DataCore 现
	# 恒挂载并 bind（不再区分 "创建但不 bind" 的 legacy 路径）。
	var dc_enabled: bool = true
	var cp_dc := _c()
	_data_core_world = DCWorld.new()
	if dc_enabled:
		# Reference-impl Pass #2 (performance-charter §12.6)：把 demo 开关透传，
		# 使 DCWorld 在 bind 阶段注册 CELL_DEMO_THERMAL_GRADIENT slot 并把
		# map.demo_thermal_gradient_arr resize 到 N。否则 baker 看到 size=0 全部
		# invalid，overlay 全屏空白（典型现象：stats min/max/mean=0、invalid=N）。
		var demo_tg_on: bool = false
		if cp_dc != null and "demo_thermal_gradient_enabled" in cp_dc:
			demo_tg_on = bool(cp_dc.demo_thermal_gradient_enabled)
		_data_core_world.bind_map_data(map, demo_tg_on)
	_sus.bind_world(_data_core_world)

	# DataCore World — C++ co-processor（dots-roadmap-to-gdextension 务实 A）。
	# 与 _data_core_world 同时 bind 到同一份 MapData PackedArray。CoW alias 已在
	# Phase 3a Step 2.0 验证：两侧 view_f32 看到同一块底层 buffer；C++ Pass 写完后
	# 调一次 map.set("temp_arr", arr) 推回（snapshot contract，详见 world_ext.cpp）。
	# - 仅 use_data_core=true 时创建（与主 World 一致门控）
	# - ClassDB.instantiate 失败（GDExtension 未加载）→ 保持 null，climate Pass-A
	#   走 GDScript 路径，不报 error（dev 机器上不一定每次都构建过 gdext）
	# - 不注入 SUS.bind_world：weather / sus 子系统对此实例零感知，避免 weather
	#   迁移连锁（接口集差异详见 plan/dots-roadmap-to-gdextension/architecture.md §7）
	if dc_enabled:
		if ClassDB.class_exists("DCWorldExt"):
			var ext_obj: Object = _data_core_world_ext if _data_core_world_ext != null else ClassDB.instantiate("DCWorldExt")
			if ext_obj != null and ext_obj is RefCounted:
				_data_core_world_ext = ext_obj
				var ext_bound: bool = bool(_data_core_world_ext.bind_map_data(map))
				print("[DataCore] _data_core_world_ext bound=%s (climate co-processor; class=DCWorldExt)" % str(ext_bound))
				if not ext_bound:
					push_warning("[DataCore] DCWorldExt.bind_map_data returned false; climate Pass-A C++ acceleration disabled (will fall back to DataCore/GDScript path)")
					_data_core_world_ext = null
				else:
					# sea-ice-snow-visual-fix-2026-06：bind 后注入 DCWorld 句柄。C++ pass
					# `_flush_slot_to_map` 末尾会 call("mark_dirty_all")，让 atlas pipeline
					# 在下个 stride 通过 `read_and_clear_dirty_mask` 拿到信号。修复 wind_surface
					# / pass_b / ocean_* 写 slot 后 atlas 不知道脏 → 视觉冻结。
					if _data_core_world != null and _data_core_world_ext.has_method("bind_dirty_world"):
						_data_core_world_ext.bind_dirty_world(_data_core_world)
					# Block B（master 手册 §4）：把 DCWorldExt 注入 MapBaker，
					# 让 _PHYS_STAGE_WIND 等 C++ hook 在启用 use_gdext_wind_field 时使用。
					if _baker != null and _baker.has_method("set_world_ext"):
						_baker.set_world_ext(_data_core_world_ext)
					_configure_native_world_context(map, world, cfg, hex_size)
					# cpp-dots（native-generation-publish-2026-06）：生成期地图对象/拓扑仍由
					# GDScript 编排，SoA/slot 初始仿真字段由 C++ publish 成权威，再 flush 回
					# MapData。失败时保留 map.bake_lat_temp_year_lut 的 GDScript fallback。
					var native_gen_ok: bool = _publish_native_generation_from_slots(map, cfg)
					if not native_gen_ok:
						# cpp-dots（temp-baseline-authority-2026-06）：cell_temp_baseline_year
						# （海冰 + 显示温度的运行期 baseline）权威计算归 C++。L1235 的
						# bake_lat_temp_year_lut 已用 GDScript fallback 填好 cell_lat_norm +
						# temp_baseline_year；ext 现已 bind，把 temp_baseline_year 交给 C++
						# pk_lat_temp_bell 权威重算并 flush 回 MapData（ext 未就绪则保留 GDScript 值）。
						_bake_temp_baseline_year_native(map)
			else:
				push_warning("[DataCore] ClassDB.instantiate(\"DCWorldExt\") returned null/non-RefCounted; gdext likely not loaded — climate C++ accel disabled")
		else:
			# GDExtension 没加载（开发机没编译 gdext / 平台不支持等），完全降级。
			# 不打 error 避免噪声，main.gd 的 [DataCore] flags 那行已能体现整体路径。
			print("[DataCore] DCWorldExt class not registered (gdext unavailable); climate Pass-A will use DataCore/GDScript path only")

	# PR-2.3a HexCell facade infra：bake_world / 加载存档末尾给每个 cell 注入 world
	# 引用 + facade flag。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_hexcell_facade flag 已删除——
	# facade 现恒启用（bind_world 第 2 参 _facade_on=true），热字段 getter/setter 全走
	# DCWorld view（PR-2.3c 已验收）。
	#
	# plan/3b-single-read-source：本段已从 _data_core_world 创建紧后移到此处，
	# 在 _data_core_world_ext 创建之后才 bind，使第 3 参 world_ext 能正确传入。
	# 当 ext 为 null（gdext 未编译 / bind_map_data 失败）时退化为旧 2 参行为，
	# facade getter 走 _world.read_*，与 PR-2.3c 实现 100% 等价。
	if dc_enabled:
		var _facade_on: bool = true
		var _cell_arr_for_bind: Array = map._cell_array
		var _n_cells_for_bind: int = _cell_arr_for_bind.size()
		for _ci in range(_n_cells_for_bind):
			var _c_for_bind = _cell_arr_for_bind[_ci]
			if _c_for_bind != null and _c_for_bind.has_method("bind_world"):
				_c_for_bind.bind_world(_data_core_world, _facade_on, _data_core_world_ext)
		if _facade_on:
			print("[hex_cell] facade ENABLED (%d cells bound; ext=%s)" % [_n_cells_for_bind, str(_data_core_world_ext != null)])
	# DOTS-Final-Push 修复：把 ClimateProfile 直接注入 MapBaker。
	# 历史上 sea_ice prepare / albedo / veg_dyn / feedback 通过 `world.get("config")`
	# 取 cp 永远拿到 null（WorldData 上没有 config 字段），导致 use_native 一直 false，
	# sea_ice prepare 稳定 48ms GDScript 全图回扫。这里显式注入修正这一长期 bug。
	# 不被 dc_enabled 门控——GDScript 路径同样需要 cp.flag 做配置读取。
	if _baker != null and _baker.has_method("set_climate_profile"):
		var cp_for_baker = _c()
		_baker.set_climate_profile(cp_for_baker)
		print("[DataCore] _baker climate_profile injected=%s (fixes WorldData.config==null sea_ice prepare path)" % str(cp_for_baker != null))
	if cfg != null:
		cfg.climate_profile = _c()
	if _baker != null and _baker.has_method("run_deferred_initial_physical_circulation"):
		_baker.run_deferred_initial_physical_circulation(map, world, hex_size, cfg)
	# ─── Phase F.1：DCWorldExt 接管 weather field solve（charter §7 P0）──
	# 把 ext 句柄一次性下发给 WeatherSystem。ext 为 null（gdext 未编译 / 未 bind）
	# 时 WeatherSystem 自动走 GDScript legacy path，对 caller 完全透明。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_weather_field/distribute/summary
	# /weather_front 四个 flag 已删除——enabled 参数现恒传 true，WeatherSystem 内部
	# 走 ext+has_method+sig 探测单边分支。
	# PR-2.1.6：第 4 个参数注入 GDScript DCWorld，让 weather field commit 写路径
	# 走 world.write_f32_indexed。详见 master 手册 §3.9。
	if _weather_system != null and _weather_system.has_method("configure_gdext_acceleration"):
		var cp_f1 := _c()
		_weather_system.configure_gdext_acceleration(_data_core_world_ext, true, cp_f1, _data_core_world)
	if _try_register_native_daily_sim_job(map, world):
		if OS.is_debug_build():
			print("[native_daily] ACTIVE: registered native_daily_sim + visual upload jobs only")
		_register_visual_upload_jobs(map, world, hex_size, cp_sched)
		if _use_dc_system_scheduler:
			var topo_native_ok: bool = _sus.build_topology()
			if not topo_native_ok:
				push_error("[map_generator] DCSystemScheduler.build_topology() failed for native_daily path")
		if _sus_bootstrap == null:
			_sus_bootstrap = DCSusSystemsBootstrapScript.new(self)
		_sus_bootstrap.attach_post_setup(self, _sus)
		return
	# 0.4.1：use_dc_system_scheduler 决定用 System（native DCSystem，IS-A SusJob）
	# 还是原 Job。两者业务逻辑等价（SeasonRefreshSystem.tick 与 SeasonRefreshJob.run_slice
	# 同结构 11-stage）。
	if _use_dc_system_scheduler:
		_season_refresh_job = SeasonRefreshSystemScript.new(self, map, world)
		_apply_sim_budget_profile_to_job(_season_refresh_job, cp_sched)
		_sus.register_system(_season_refresh_job)
	else:
		_season_refresh_job = SeasonRefreshJobScript.new(self, map, world)
		_apply_sim_budget_profile_to_job(_season_refresh_job, cp_sched)
		_sus.register_job(_season_refresh_job)
	# dots-flag-prune-pr1 (2026-05-22)：ocean_current_refresh_seasons E 类废字段已
	# 从 ClimateProfile 删除——原有的 deprecated warning 不再需要。SUS 路径仅
	# 读 ocean_currents_period_ticks / ocean_currents_slice_count。
	var cp := _c()
	var enum_atlas_stride: int = 2
	var dynamic_visual_atlas_stride: int = _dyn_atlas_upload_stride
	if cp != null:
		if cp.get("enum_atlas_upload_stride") != null:
			enum_atlas_stride = clampi(int(cp.enum_atlas_upload_stride), 1, 8)
		if cp.get("dynamic_visual_atlas_upload_stride") != null:
			dynamic_visual_atlas_stride = clampi(int(cp.dynamic_visual_atlas_upload_stride), 1, 8)
	_dyn_atlas_upload_stride = dynamic_visual_atlas_stride
	# 注册 OceanCurrentsJob。
	var wind_period_ticks: int = 1
	var ocean_period_ticks: int = 30
	var slice_count: int = 10
	if cp != null:
		ocean_period_ticks = max(1, int(cp.ocean_currents_period_ticks))
		slice_count = max(1, int(cp.ocean_currents_slice_count))
	# Physical Wind & Ocean Circulation：把激活的 ClimateProfile 引用注入 cfg，
	# 让 MapBaker 在切片烘焙时（OceanCurrentsJob.run_slice 调用 baker.bake_*_slice）
	# 通过 cfg.climate_profile 读到 physical_circulation_enabled 等开关。null 时
	# 走 ny-only 旧路径。
	if cfg != null:
		cfg.climate_profile = cp
	# 0.4.1：use_dc_system_scheduler 时构造 wrapper（delegate 内嵌 OceanCurrentsJob）
	# 并注册到 DCSystemScheduler；_ocean_currents_job 保持指向 wrapper._inner，让
	# on_commit / season_phase_getter / depends_on 等 SusJob-面字段的既有写入路径
	# 1:1 沿用。
	if _use_dc_system_scheduler:
		var ocean_sys = OceanCurrentsSystemScript.new(
				_baker, map, world, cfg, hex_size, wind_period_ticks, slice_count, ocean_period_ticks)
		_ocean_currents_job = ocean_sys.get_inner()
		_apply_sim_budget_profile_to_job(ocean_sys, cp)
		_apply_sim_budget_profile_to_job(_ocean_currents_job, cp)
		_ocean_currents_job.on_commit = func():
			_compute_ocean_currents(map, world, hex_size)
		if _world_clock_ref != null:
			_ocean_currents_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
		_sus.register_system(ocean_sys)
	else:
		_ocean_currents_job = OceanCurrentsJob.new(
				_baker, map, world, cfg, hex_size, wind_period_ticks, slice_count, ocean_period_ticks)
		_apply_sim_budget_profile_to_job(_ocean_currents_job, cp)
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
	# Fix #9 (2026-06-15): 不动 stride（保持仿真权威性），只用 phase 错峰。
	# climate/sea_ice/ocean phase=0 落偶 tick；weather/atlas/dynamic_visual phase=1
	# 落奇 tick。stride=1 时无视 phase（每 tick 都跑），所以仿真层不受影响。
	# 当 atlas 配 stride=2 时（earth_like.tres dynamic_visual_atlas_upload_stride=2），
	# phase=1 让它落在奇 tick，跟 climate spike tick 错开 → 不再被饿死。
	var climate_stride: int = 1
	var sea_ice_stride: int = 1
	var weather_stride: int = 1
	if cp != null:
		climate_stride = max(1, int(cp.daily_climate_refresh_stride))
		if cp.get("sea_ice_daily_stride") != null:
			sea_ice_stride = clampi(int(cp.sea_ice_daily_stride), 1, 8)
		weather_stride = max(1, int(cp.weather_refresh_stride))
	# RefreshClimateDailyJob：写连续气候基线（priority 100）
	var climate_phase_getter := Callable()
	if _world_clock_ref != null:
		climate_phase_getter = Callable(_world_clock_ref, "season_phase")
	# 0.4.1：use_dc_system_scheduler 时构造 ClimateDailySystem wrapper（delegate 到
	# RefreshClimateDailyJob）；_refresh_climate_daily_job 保持指向 wrapper._inner
	# 让现有 SusJob-面访问（reset_run_flag / did_run_last_tick / data_core_ready /
	# season_phase_getter 写入 / reconfigure 等）零改动。
	if _use_dc_system_scheduler:
		var climate_sys = ClimateDailySystemScript.new(self, map, climate_phase_getter, climate_stride)
		_refresh_climate_daily_job = climate_sys.get_inner()
		_apply_sim_budget_profile_to_job(climate_sys, cp)
		_apply_sim_budget_profile_to_job(_refresh_climate_daily_job, cp)
		_sus.register_system(climate_sys)
	else:
		_refresh_climate_daily_job = RefreshClimateDailyJobScript.new(self, map, climate_phase_getter, climate_stride)
		_apply_sim_budget_profile_to_job(_refresh_climate_daily_job, cp)
		_sus.register_job(_refresh_climate_daily_job)
	_sea_ice_daily_job = null
	if cp != null and cp.get("sea_ice_independent_system_enabled") != null \
			and bool(cp.sea_ice_independent_system_enabled):
		_sea_ice_daily_job = SeaIceDailySystemScript.new(self, map, climate_phase_getter, sea_ice_stride)
		_apply_sim_budget_profile_to_job(_sea_ice_daily_job, cp)
		if _use_dc_system_scheduler:
			_sus.register_system(_sea_ice_daily_job)
		else:
			_sus.register_job(_sea_ice_daily_job)
	if _ocean_currents_job != null:
		_ocean_currents_job.climate_ran_this_tick_getter = Callable(self, "did_refresh_climate_run_this_tick")
		_ocean_currents_job.climate_slice_ms_getter = Callable(self, "last_refresh_climate_slice_ms")
	# 0.4.1：use_dc_system_scheduler 时用 EnumAtlasUploadSystem（native DCSystem，
	# IS-A SusJob，业务逻辑与 EnumAtlasUploadJob 等价）。
	if _use_dc_system_scheduler:
		_enum_atlas_upload_job = EnumAtlasUploadSystemScript.new(self, _baker, map, world, hex_size, enum_atlas_stride, _data_core_world_ext)
		_apply_sim_budget_profile_to_job(_enum_atlas_upload_job, cp, true)
		_sus.register_system(_enum_atlas_upload_job)
	else:
		_enum_atlas_upload_job = EnumAtlasUploadJobScript.new(self, _baker, map, world, hex_size, enum_atlas_stride, _data_core_world_ext)
		_apply_sim_budget_profile_to_job(_enum_atlas_upload_job, cp, true)
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
	# 0.4.1：use_dc_system_scheduler 时构造 WeatherDCSystem wrapper（delegate 到
	# WeatherRefreshJob）；_weather_refresh_job 仍指向 wrapper.get_inner() 保持
	# 既有 last_fronts / did_change_fronts_last_tick 等访问路径不变。
	var weather_dc_system = null
	if _use_dc_system_scheduler:
		weather_dc_system = WeatherDCSystemScript.new(
			self, map, world,
			season_idx_getter, season_phase_getter, climate_anomaly_getter,
			weather_stride
		)
		_weather_refresh_job = weather_dc_system.get_inner()
		_apply_sim_budget_profile_to_job(weather_dc_system, cp)
		_apply_sim_budget_profile_to_job(_weather_refresh_job, cp)
	else:
		_weather_refresh_job = WeatherRefreshJobScript.new(
			self, map, world,
			season_idx_getter, season_phase_getter, climate_anomaly_getter,
			weather_stride
		)
		_apply_sim_budget_profile_to_job(_weather_refresh_job, cp)
	# Weather=0 fix（2026-05-13，与 weather_refresh_job.gd line 498-507 同源
	# 历史教训）：原 `_weather_refresh_job.depends_on.append(&"season_refresh")`
	# 把 weather 硬挂在 season_refresh 上，但 season 是 11-stage 切片 round
	# （每 round 前 10 个 stage 返回 done=false），weather 在 SUS 优先级序里
	# 排在 season 之后（150 > 50），只要 season 切片中 weather 立刻 dep_pending。
	# 实测 30 tick 内 weather ran=0（详见 docs/DOTS review.md 排查记录）。
	#
	# 真实依赖关系：weather hot loop 读的是 cell.temperature / moisture / wind /
	# has_river 等慢层 baseline——这些字段跟 season 切换的"植被/cover redecide"
	# 是正交的；即使 weather 读到旧 base_vegetation 一两 tick 也不影响 weather
	# field 求解（与 weather_refresh_job.gd 注释里描述的 climate dep 解除是同
	# 一类问题）。所以 weather 不应阻塞在 season 上。
	# _weather_refresh_job.depends_on.append(&"season_refresh")  # ← 移除（保留作历史记录）
	if _use_dc_system_scheduler:
		_sus.register_system(weather_dc_system)
	else:
		_sus.register_job(_weather_refresh_job)

	# WeatherLUT 发布直接内联在 WeatherRefreshJob 的 commit/merged/direct 完成点，避免独立 job
	# 的 should_run 相位早于 weather_refresh 时读到 ran_this_tick=false，也避免额外每 tick 扫描。
	_weather_lut_upload_job = null

	# 海冰主视觉数据通道：水路径 shader 从 dyn_atlas_smooth_atlas.A 通道读取
	# sea_ice_fraction（与 UI/info_panel 同源；sea-ice-render-source-unify 阶段 A）。
	# 不再需要 sea_ice_atlas_upload 周期性光栅化 / GPU 上传作为 shader 主源；
	# 保留 sea_ice_tex 作为兼容空纹理，但不注册 SUS job。
	_sea_ice_atlas_upload_job = null
	_last_sea_ice_atlas_upload_breakdown = {
		"done": true,
		"phase": "disabled",
		"stage_name": "sea_ice_atlas_upload",
		"elapsed_ms": 0.0,
		"reason": "dyn_atlas_smooth_a_unified_source",
	}
	# plan/dirty-push-atlas-encode 阶段 D：把 cp 传给 system，让其入口可调
	# DCFeatureFlags.is_on(&"dirty_push_enabled", cp) 决定是否走 mask 路径。
	_dynamic_visual_atlas_upload_job = DynamicVisualAtlasUploadSystemScript.new(
			_baker, map, world, _dyn_atlas_upload_stride, cp, _data_core_world,
			_data_core_world_ext)
	_apply_sim_budget_profile_to_job(_dynamic_visual_atlas_upload_job, cp, true)
	if _use_dc_system_scheduler:
		_sus.register_system(_dynamic_visual_atlas_upload_job)
	else:
		_sus.register_job(_dynamic_visual_atlas_upload_job)
	_try_register_native_environment_runtime_system(map, cp)

	# 0.4.1：DCSystemScheduler 路径必须在所有 register_system 之后调一次
	# build_topology()。它按 declare_reads/writes 构造 DAG + Kahn 拓扑排序，
	# 再把 system.priority 改写为 (100 + topo_index*10) 以让内部 SUS 按拓扑序
	# 跑。有环时 push_error 并拒绝构建；调试构建会 print 拓扑序 system id 列表。
	if _use_dc_system_scheduler:
		var topo_ok: bool = _sus.build_topology()
		if not topo_ok:
			push_error("[map_generator] DCSystemScheduler.build_topology() failed (cycle detected); fast tick will not run")
		elif OS.is_debug_build():
			print("[map_generator] DCSystemScheduler topology built: %s" % str(_sus.topology_order_names()))

	# Phase 1.4 — sus_systems_bootstrap attach。让 main.gd / debug overlay 能通过
	# generator.get_sus_bootstrap() 拿到 scheduler 引用做诊断 / 未来直接 tick。
	# 注意：实际注册逻辑仍在本函数内（Phase 3.4 拆分时才搬到 bootstrap.bootstrap()）。
	if _sus_bootstrap == null:
		_sus_bootstrap = DCSusSystemsBootstrapScript.new(self)
	_sus_bootstrap.attach_post_setup(self, _sus)
	if OS.is_debug_build():
		print("[map_generator] %s" % _sus_bootstrap.status_one_liner())


func _apply_sim_budget_profile_to_scheduler(cp) -> void:
	if _sus == null or cp == null:
		return
	var frame_ms: float = float(cp.sim_frame_budget_ms) if cp.get("sim_frame_budget_ms") != null else float(_sus.frame_budget_ms)
	# Runtime safety clamp：resource 里允许保留极大预算做实验输入，但实际
	# fast tick 不能放开到几十 ms，否则 SUS 会在同一帧连续吃完整轮重型 job。
	# Fix #8A (2026-06-15): mobile 上限改为 4.0ms（log_next.txt 实测 SUS p95=9-15ms，
	# budget=2ms 让 dynamic_visual_atlas_upload 80% 被饿死，雪线/海冰视觉延迟 2-3s）。
	# 4ms 仍远 < 16.6ms 60FPS frame budget，给低优先级 atlas upload 有上车机会。
	# Mobile 默认 4.0，desktop 继续 2.0（profile 里默认 sim_frame_budget_ms=2.0）。
	var max_budget: float = 4.0 if OS.has_feature("mobile") else 2.0
	# Mobile 上无视 profile 设置，强制至少 4.0（如果 profile 写得更低就用 profile，
	# 比如调试时强制 2.0 复现旧行为）。
	if OS.has_feature("mobile") and frame_ms < max_budget:
		frame_ms = max_budget
	frame_ms = clampf(frame_ms, 0.25, max_budget)
	if cp.get("sim_frame_budget_ms") != null:
		if _sus.has_method("set_frame_budget_ms"):
			_sus.set_frame_budget_ms(frame_ms)
		else:
			_sus.frame_budget_ms = frame_ms
	if cp.get("sim_strict_budget_enabled") != null:
		if _sus.has_method("set_strict_budget_enabled"):
			_sus.set_strict_budget_enabled(bool(cp.sim_strict_budget_enabled))
		else:
			_sus.strict_budget_enabled = bool(cp.sim_strict_budget_enabled)
	if _sus.get("sim_budget_window_size") != null:
		_sus.sim_budget_window_size = 300
	if _sus.get("sim_budget_warn_ms") != null:
		if cp.get("sim_budget_warn_ms") != null:
			# Fix #8A: warn_ms 上限也跟 frame_ms 走，mobile 4.0/desktop 2.0
			var warn_ms: float = clampf(float(cp.sim_budget_warn_ms), 0.25, max_budget)
			if _sus.has_method("set_sim_budget_warn_ms"):
				_sus.set_sim_budget_warn_ms(warn_ms)
			else:
				_sus.sim_budget_warn_ms = warn_ms
		elif cp.get("sim_frame_budget_ms") != null:
			if _sus.has_method("set_sim_budget_warn_ms"):
				_sus.set_sim_budget_warn_ms(frame_ms)
			else:
				_sus.sim_budget_warn_ms = frame_ms
		else:
			_sus.sim_budget_warn_ms = 1.0
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_sus_scheduler flag 已删除——SUS
	# scheduler native 路径现恒走 ext != null 单边分支，scheduler 内部自动
	# 探测 _ext，无需 caller 在这里透传 flag。
	if OS.is_debug_build():
		var log_slice_ms: float = 0.0
		if cp.get("sim_slice_budget_ms") != null:
			log_slice_ms = clampf(float(cp.sim_slice_budget_ms), 0.10, 1.0)
		var log_upload_slice_ms: float = 0.0
		if cp.get("sim_upload_slice_budget_ms") != null:
			log_upload_slice_ms = clampf(float(cp.sim_upload_slice_budget_ms), 0.10, 1.5)
		print("[SUS] sim budget strict=%s frame=%.2fms warn=%.2fms slice=%.2fms upload=%.2fms scheduler=%s native_sus=auto"
			% [str(bool(cp.sim_strict_budget_enabled)) if cp.get("sim_strict_budget_enabled") != null else "false",
				frame_ms,
				float(_sus.sim_budget_warn_ms) if _sus.get("sim_budget_warn_ms") != null else 1.0,
				log_slice_ms,
				log_upload_slice_ms,
				"DCSystemScheduler" if _use_dc_system_scheduler else "SlicedUpdateScheduler"])


func _sim_job_should_must_run(_job, _upload_job: bool) -> bool:
	if _upload_job or _job == null:
		return false
	var raw_id = _job.get("id")
	if raw_id == null:
		return false
	var job_id: StringName = StringName(str(raw_id))
	return job_id == &"ocean_currents" \
			or job_id == &"refresh_climate_daily" \
			or job_id == &"weather_refresh" \
			or job_id == &"sea_ice_daily"


func _apply_sim_budget_profile_to_job(job, cp, upload_job: bool = false) -> void:
	if job == null or cp == null:
		return
	var strict_on: bool = bool(cp.sim_strict_budget_enabled) if cp.get("sim_strict_budget_enabled") != null else false
	var slice_ms: float = 0.55
	if upload_job and cp.get("sim_upload_slice_budget_ms") != null:
		slice_ms = float(cp.sim_upload_slice_budget_ms)
	elif cp.get("sim_slice_budget_ms") != null:
		slice_ms = float(cp.sim_slice_budget_ms)
	if upload_job:
		slice_ms = clampf(slice_ms, 0.10, 1.5)
	else:
		slice_ms = clampf(slice_ms, 0.10, 1.0)
	if job.get("slice_budget_ms") != null:
		job.slice_budget_ms = slice_ms
	if job.get("max_slices_per_tick") != null:
		var job_id: StringName = &""
		var raw_id = job.get("id")
		if raw_id != null:
			job_id = StringName(str(raw_id))
		# Heavy/latency-sensitive jobs must yield after one slice. This keeps
		# climate rounds and ocean raster/commit work spread across fast ticks.
		if upload_job or job_id == &"season_refresh" \
				or job_id == &"refresh_climate_daily" \
				or job_id == &"sea_ice_daily" \
				or job_id == &"ocean_currents":
			job.max_slices_per_tick = 1
		else:
			job.max_slices_per_tick = 1 if strict_on else 0
	if job.get("must_run") != null:
		var must_job_id: StringName = &""
		var must_raw_id = job.get("id")
		if must_raw_id != null:
			must_job_id = StringName(str(must_raw_id))
		var force_must_run: bool = (must_job_id == &"sea_ice_atlas_upload")
		job.must_run = force_must_run \
				or (strict_on and _sim_job_should_must_run(job, upload_job))
	if job.get("starvation_threshold") != null:
		var starvation_job_id: StringName = &""
		var starvation_raw_id = job.get("id")
		if starvation_raw_id != null:
			starvation_job_id = StringName(str(starvation_raw_id))
		# sea-ice-snow-visual-fix-v3：原 `if upload_job: starvation_threshold = 0`
		# 把 _init 里设的 8 擦掉，导致 atlas pipeline 在 frame_budget_exhausted 时
		# 完全饿死。视觉 upload job 强制保留 starvation 防护。
		if starvation_job_id == &"dynamic_visual_atlas_upload" \
				or starvation_job_id == &"sea_ice_atlas_upload":
			job.starvation_threshold = 8
		elif upload_job:
			job.starvation_threshold = 0
		elif starvation_job_id == &"refresh_climate_daily" \
				or starvation_job_id == &"weather_refresh" \
				or starvation_job_id == &"sea_ice_daily":
			job.starvation_threshold = 3
		elif starvation_job_id == &"ocean_currents":
			job.starvation_threshold = 6
		else:
			job.starvation_threshold = 0


## Phase 1.4 — 让 main.gd / debug overlay 拿到 sus_systems_bootstrap 引用。
## 在 _setup_sus 完成之前返回 null。
func get_sus_bootstrap() -> RefCounted:
	return _sus_bootstrap


func get_environment_runtime() -> RefCounted:
	if _environment_runtime != null:
		return _environment_runtime
	if not ClassDB.class_exists("EnvironmentRuntime"):
		return null
	_environment_runtime = ClassDB.instantiate("EnvironmentRuntime") as RefCounted
	return _environment_runtime


func ensure_environment_runtime(map: MapData, pixel_size: Vector2i = Vector2i.ZERO) -> RefCounted:
	var rt: RefCounted = get_environment_runtime()
	if rt == null:
		return null
	var cell_count: int = map.cell_count() if map != null else 0
	if rt.has_method("initialize_with_sizes"):
		rt.call("initialize_with_sizes", cell_count, pixel_size)
	if map != null and map.has_method("neighbor_indices_packed") and rt.has_method("build_topology_from_arrays"):
		var pixel_to_cell: PackedInt32Array = PackedInt32Array()
		rt.call("build_topology_from_arrays", map.neighbor_indices_packed(), map.is_water_arr, map.terrain_arr, pixel_to_cell)
	if map != null and rt.has_method("bind_core_buffers"):
		rt.call("bind_core_buffers", map.elevation_arr, map.temp_arr, map.moisture_arr, map.slp_arr, map.wind_x_arr, map.wind_y_arr, map.ocean_current_x_arr, map.ocean_current_y_arr)
	if map != null and rt.has_method("bind_weather_buffers"):
		rt.call("bind_weather_buffers", map.weather_vapor_arr, map.weather_cloud_arr, map.weather_precip_arr)
	return rt


func environment_runtime_status() -> Dictionary:
	var rt: RefCounted = get_environment_runtime()
	if rt == null or not rt.has_method("status"):
		return {}
	var out: Dictionary = rt.call("status")
	if rt.has_method("buffer_summary"):
		out["buffers"] = rt.call("buffer_summary")
	if rt.has_method("topology_summary"):
		out["topology"] = rt.call("topology_summary")
	if rt.has_method("snapshot_summary"):
		out["snapshot"] = rt.call("snapshot_summary")
	if rt.has_method("progress_summary"):
		out["progress"] = rt.call("progress_summary")
	if rt.has_method("export_runtime_state"):
		out["runtime_state"] = rt.call("export_runtime_state")
	return out


func export_environment_runtime_state() -> Dictionary:
	var rt: RefCounted = get_environment_runtime()
	if rt == null or not rt.has_method("export_runtime_state"):
		return {}
	return rt.call("export_runtime_state")


func restore_environment_runtime_state(state: Dictionary) -> void:
	var rt: RefCounted = get_environment_runtime()
	if rt != null and rt.has_method("restore_runtime_state"):
		rt.call("restore_runtime_state", state)


func environment_runtime_step_budgeted(budget_ms: float, max_cells: int = 0, max_pixels: int = 0, max_indices: int = 0, pipeline: StringName = &"ocean") -> Dictionary:
	var rt: RefCounted = get_environment_runtime()
	if rt == null:
		return {"done": true, "stage": "missing_runtime", "work_done": 0, "elapsed_ms": 0.0}
	if pipeline == &"climate" and rt.has_method("step_climate_budgeted"):
		return rt.call("step_climate_budgeted", budget_ms, max_cells, max_pixels, max_indices)
	if pipeline == &"weather" and rt.has_method("step_weather_budgeted"):
		return rt.call("step_weather_budgeted", budget_ms, max_cells, max_pixels, max_indices)
	if pipeline == &"ocean" and rt.has_method("step_ocean_budgeted"):
		return rt.call("step_ocean_budgeted", budget_ms, max_cells, max_pixels, max_indices)
	if rt.has_method("step_budgeted"):
		return rt.call("step_budgeted", budget_ms, max_cells, max_pixels, max_indices)
	return {"done": true, "stage": "missing_step", "work_done": 0, "elapsed_ms": 0.0}


## 2026-05-19：dynamic/ecology/smooth/ice atlas 上传 stride 的运行时调整入口。
## HexRenderer.set_dyn_atlas_upload_stride() 反向调用过来；如果 _setup_sus 还没
## 跑过（_dynamic_visual_atlas_upload_job == null），先存到字段，等下次 setup 用。
func set_dyn_atlas_upload_stride(p_stride: int) -> void:
	_dyn_atlas_upload_stride = clampi(p_stride, 1, 8)
	var cp := _c()
	if cp != null and cp.get("dynamic_visual_atlas_upload_stride") != null:
		cp.dynamic_visual_atlas_upload_stride = _dyn_atlas_upload_stride
	if _dynamic_visual_atlas_upload_job != null and _dynamic_visual_atlas_upload_job.has_method("reconfigure"):
		_dynamic_visual_atlas_upload_job.reconfigure(_dyn_atlas_upload_stride)


func set_enum_atlas_upload_stride(p_stride: int) -> void:
	var stride: int = clampi(p_stride, 1, 8)
	var cp := _c()
	if cp != null and cp.get("enum_atlas_upload_stride") != null:
		cp.enum_atlas_upload_stride = stride
	if _enum_atlas_upload_job != null and _enum_atlas_upload_job.has_method("reconfigure"):
		_enum_atlas_upload_job.reconfigure(stride)


## Applies the cadence knobs currently stored in ClimateProfile to already
## registered SUS/DC systems. Regenerating the world also reads the same knobs
## during _setup_sus; this entry point is for debug UI / inspector tooling.
func apply_simulation_cadence_from_profile() -> void:
	var cp := _c()
	if cp == null:
		return
	if cp.get("daily_climate_refresh_stride") != null:
		set_daily_climate_refresh_stride(int(cp.daily_climate_refresh_stride))
	if _sea_ice_daily_job != null and _sea_ice_daily_job.has_method("reconfigure") \
			and cp.get("sea_ice_daily_stride") != null:
		_sea_ice_daily_job.reconfigure(clampi(int(cp.sea_ice_daily_stride), 1, 8))
	if cp.get("weather_refresh_stride") != null:
		set_weather_refresh_stride(int(cp.weather_refresh_stride))
	if _season_refresh_job != null and _season_refresh_job.get("period_ticks") != null \
			and cp.get("season_refresh_period_ticks") != null:
		_season_refresh_job.period_ticks = max(1, int(cp.season_refresh_period_ticks))
	if _ocean_currents_job != null and _ocean_currents_job.has_method("reconfigure") \
			and cp.get("ocean_currents_period_ticks") != null \
			and cp.get("ocean_currents_slice_count") != null:
		var ocean_period_ticks: int = max(1, int(cp.ocean_currents_period_ticks))
		_ocean_currents_job.reconfigure(
				1,
				max(1, int(cp.ocean_currents_slice_count)),
				ocean_period_ticks)
	if cp.get("enum_atlas_upload_stride") != null:
		set_enum_atlas_upload_stride(int(cp.enum_atlas_upload_stride))
	if cp.get("dynamic_visual_atlas_upload_stride") != null:
		set_dyn_atlas_upload_stride(int(cp.dynamic_visual_atlas_upload_stride))
	if _native_daily_sim_job != null and cp.get("native_daily_sim_stride") != null:
		_native_daily_sim_job.policy = SusPolicyScript.StridePolicy.new(
				clampi(int(cp.native_daily_sim_stride), 1, 8), 0)
	if _native_environment_runtime_job != null and cp.get("native_environment_runtime_stride") != null:
		_native_environment_runtime_job.policy = SusPolicyScript.StridePolicy.new(
				clampi(int(cp.native_environment_runtime_stride), 1, 8), 0)


## main.gd 在 _ready 末尾调用，让 OceanCurrentsJob 拿到 season_phase 连续浮点。
func set_world_clock_ref(world_clock_node) -> void:
	_world_clock_ref = world_clock_node
	if _baker != null and _baker.has_method("set_world_clock_ref"):
		_baker.set_world_clock_ref(_world_clock_ref)
	if _world_clock_ref == null:
		return
	if _ocean_currents_job != null:
		_ocean_currents_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
	# 任务 8：把 world_clock getter 注入给气候 / 天气 Job。
	if _refresh_climate_daily_job != null:
		_refresh_climate_daily_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
	if _sea_ice_daily_job != null:
		_sea_ice_daily_job.season_phase_getter = Callable(_world_clock_ref, "season_phase")
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
func _native_mode_is_active(cp, field_name: String) -> bool:
	if cp == null or cp.get(field_name) == null:
		return false
	return int(cp.get(field_name)) == 2


func _native_mode_is_shadow(cp, field_name: String) -> bool:
	if cp == null or cp.get(field_name) == null:
		return false
	return int(cp.get(field_name)) == 1


func _native_daily_base_tick_knobs(ctx: SusTickContext) -> Dictionary:
	var season_idx: int = 0
	if _world_clock_ref != null and _world_clock_ref.has_method("season_index"):
		season_idx = int(_world_clock_ref.season_index())
	var days_per_year: int = _calendar_days_per_year()
	var day_of_year: int = _season_phase_to_day_of_year(ctx.season_phase, days_per_year)
	if _world_clock_ref != null and _world_clock_ref.has_method("day_in_year"):
		day_of_year = clampi(int(_world_clock_ref.day_in_year()), 0, days_per_year - 1)
	var anomaly: float = 0.0
	if _world_clock_ref != null:
		var v = _world_clock_ref.get("climate_anomaly")
		if v != null:
			anomaly = float(v)
	return {
		"day_index": ctx.day_index,
		"day_of_year": day_of_year,
		"days_per_year": days_per_year,
		"tick_index": ctx.tick_index,
		"season_phase": ctx.season_phase,
		"season_index": season_idx,
		"climate_anomaly": anomaly,
		"speed_multiplier": ctx.speed_multiplier,
	}


func _build_native_daily_stage_b_knobs(map: MapData, cp_now, call_index: int) -> Dictionary:
	if map == null or cp_now == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}
	var albedo_stride: int = maxi(1, int(cp_now.weather_albedo_stride))
	var veg_dyn_stride: int = maxi(1, int(cp_now.weather_vegetation_dynamics_stride))
	var feedback_stride: int = maxi(1, int(cp_now.weather_feedback_stride))
	var run_albedo: bool = (call_index % albedo_stride) == 0
	var run_veg_dyn: bool = (call_index % veg_dyn_stride) == 0
	var run_feedback: bool = (call_index % feedback_stride) == 0 and bool(cp_now.fast_slow_layering_enabled)
	if not (run_albedo or run_veg_dyn or run_feedback):
		return {}
	var knobs: Dictionary = {
		"n_cells": n_cells,
		"run_albedo": run_albedo,
		"run_veg_dyn": run_veg_dyn,
		"run_feedback": run_feedback,
		"use_soa": true,
	}
	if run_albedo:
		knobs["reference_albedo"] = float(cp_now.reference_albedo)
		knobs["albedo_temp_gain"] = float(cp_now.albedo_temp_gain)
		knobs["snow_cover_albedo"] = 0.75
		knobs["cover_snow_id"] = int(CoverType.CV.SNOW)
		knobs["cover_glacier_id"] = int(CoverType.CV.GLACIER)
		knobs["albedo_table"] = _build_albedo_donor_table()
	if run_veg_dyn:
		_ensure_vegdyn_lut()
		var veg_dyn_scale_raw: float = float(veg_dyn_stride)
		var veg_dyn_scale_eff: float = maxf(veg_dyn_scale_raw, 1.0)
		knobs["day_scale"] = veg_dyn_scale_raw
		knobs["streak_days"] = maxi(1, int(round(veg_dyn_scale_eff)))
		knobs["vitality_change_rate"] = float(cp_now.vitality_change_rate)
		knobs["compat_harshness"] = float(cp_now.compat_harshness)
		knobs["weather_penalty_scale"] = float(cp_now.vegetation_weather_penalty_scale)
		knobs["plant_water_balance_weight"] = float(cp_now.plant_water_balance_weight)
		knobs["plant_soil_buffer_weight"] = float(cp_now.plant_soil_buffer_weight)
		knobs["plant_drought_penalty"] = float(cp_now.plant_drought_penalty)
		knobs["succession_min_compat_gain"] = float(cp_now.succession_min_compat_gain)
		knobs["low_threshold"] = float(cp_now.vitality_low_threshold)
		knobs["high_threshold"] = float(cp_now.vitality_high_threshold)
		knobs["succession_degrade_days"] = int(cp_now.succession_degrade_days)
		knobs["succession_upgrade_days"] = int(cp_now.succession_upgrade_days)
		knobs["vegetation_degrade_reset_target"] = float(cp_now.vegetation_degrade_reset_target) if cp_now.get("vegetation_degrade_reset_target") != null else 0.75
		knobs["vegetation_low_vitality_damping_threshold"] = float(cp_now.vegetation_low_vitality_damping_threshold) if cp_now.get("vegetation_low_vitality_damping_threshold") != null else 0.40
		knobs["vegetation_succession_cooldown_days"] = int(cp_now.vegetation_succession_cooldown_days) if cp_now.get("vegetation_succession_cooldown_days") != null else 30
		knobs["vegetation_stress_enabled"] = bool(cp_now.vegetation_stress_enabled) if cp_now.get("vegetation_stress_enabled") != null else false
		knobs["vegetation_stress_memory_days"] = float(cp_now.vegetation_stress_memory_days) if cp_now.get("vegetation_stress_memory_days") != null else 30.0
		knobs["n_wt"] = int(WeatherType.WT.size())
		knobs["wt_clear_id"] = int(WeatherType.WT.CLEAR)
		knobs["wt_blizzard_id"] = int(WeatherType.WT.BLIZZARD)
		knobs["wt_drought_id"] = int(WeatherType.WT.DROUGHT)
		knobs["wt_heatwave_id"] = int(WeatherType.WT.HEATWAVE)
		knobs["veg_none_id"] = int(VegetationType.VEG.NONE)
		knobs["ideal_temp_table"] = _gdext_vegdyn_ideal_temp_cached
		knobs["ideal_moist_table"] = _gdext_vegdyn_ideal_moist_cached
		knobs["temp_tol_table"] = _gdext_vegdyn_temp_tol_cached
		knobs["moist_tol_table"] = _gdext_vegdyn_moist_tol_cached
		knobs["weather_penalty_table"] = _gdext_vegdyn_weather_penalty_cached
		knobs["resistance_table"] = _gdext_vegdyn_resistance_cached
		knobs["next_up_table"] = _gdext_vegdyn_next_up_cached
		knobs["next_down_table"] = _gdext_vegdyn_next_down_cached
	if run_feedback:
		var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
		if neighbor_indices.size() < n_cells * 6:
			knobs["run_feedback"] = false
		else:
			var feedback_scale_eff: float = maxf(float(feedback_stride), 1.0)
			knobs["soil_gain"] = float(cp_now.weather_to_soil_gain)
			knobs["veg_gain"] = float(cp_now.weather_to_vegetation_gain)
			knobs["write_weather_veg_pressure"] = not run_veg_dyn
			knobs["scale"] = feedback_scale_eff
			knobs["per_day_clamp"] = float(cp_now.feedback_per_day_clamp) * feedback_scale_eff
			knobs["ocean_drift_gain"] = float(cp_now.ocean_moisture_drift_gain)
			knobs["wt_rain_id"] = int(WeatherType.WT.RAIN)
			knobs["wt_storm_id"] = int(WeatherType.WT.STORM)
			knobs["wt_monsoon_id"] = int(WeatherType.WT.MONSOON)
			knobs["wt_blizzard_id"] = int(WeatherType.WT.BLIZZARD)
			knobs["wt_drought_id"] = int(WeatherType.WT.DROUGHT)
			knobs["wt_heatwave_id"] = int(WeatherType.WT.HEATWAVE)
			knobs["neighbor_indices"] = neighbor_indices
	if not bool(knobs.get("run_albedo", false)) \
			and not bool(knobs.get("run_veg_dyn", false)) \
			and not bool(knobs.get("run_feedback", false)):
		return {}
	return knobs


func _build_native_daily_climate_pass_a_struct(map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or _last_cfg == null:
		return {}
	var days_per_year: int = _calendar_days_per_year()
	return {
		"use_insol": true,
		"use_sparse": bool(cp_now.use_sparse_climate),
		"insol_amp": float(cp_now.get("season_temp_amp")) if cp_now.get("season_temp_amp") != null else 0.20,
		"insol_gain": float(cp_now.get("insolation_season_gain")) if cp_now.get("insolation_season_gain") != null else 1.0,
		"moist_scale_now": 1.0,
		"season_phase": float(season_phase),
		"days_per_year": days_per_year,
		"axial_tilt_deg": float(cp_now.get("axial_tilt_deg")) if cp_now.get("axial_tilt_deg") != null else 23.5,
		"day_length_gain": float(cp_now.get("insolation_daylen_amp")) if cp_now.get("insolation_daylen_amp") != null else 0.35,
		"solar_gain": float(cp_now.get("solar_gain")) if cp_now.get("solar_gain") != null else 1.0,
		"insol_dev_min": float(cp_now.get("insolation_dev_clamp_min")) if cp_now.get("insolation_dev_clamp_min") != null else -1.0,
		"insol_dev_max": float(cp_now.get("insolation_dev_clamp_max")) if cp_now.get("insolation_dev_clamp_max") != null else 1.0,
		"thermal_inertia_land": float(cp_now.get("thermal_inertia_land")) if cp_now.get("thermal_inertia_land") != null else 0.35,
		"thermal_inertia_water": float(cp_now.get("thermal_inertia_water")) if cp_now.get("thermal_inertia_water") != null else 0.07,
		"thermal_inertia_snow": float(cp_now.get("thermal_inertia_snow")) if cp_now.get("thermal_inertia_snow") != null else 0.09,
		"thermal_inertia_high_mountain": float(cp_now.get("thermal_inertia_high_mountain")) if cp_now.get("thermal_inertia_high_mountain") != null else 0.16,
		"thermal_daily_delta_cap": float(cp_now.get("thermal_daily_delta_cap")) if cp_now.get("thermal_daily_delta_cap") != null else 0.15,
		"temp_land_continentality": float(cp_now.get("temp_land_continentality")) if cp_now.get("temp_land_continentality") != null else 1.55,
		"thermal_dt_days": _consume_climate_dt_days(),
		"snowpack_cover_low": float(cp_now.get("snowpack_cover_low")) if cp_now.get("snowpack_cover_low") != null else 0.05,
		"snowpack_cover_full": float(cp_now.get("snowpack_cover_full")) if cp_now.get("snowpack_cover_full") != null else 0.32,
		"sea_level": float(_last_cfg.sea_level),
	}


func _build_native_daily_climate_pass_b_knobs(map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or _last_cfg == null or not bool(cp_now.enable_local_climate_coupling):
		return {}
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	var n_cells: int = map.soa_size()
	if n_cells <= 0 or nb_idx.size() < n_cells * 6:
		return {}
	var tta_arr: PackedFloat32Array = map.temperature_transport_anomaly_arr
	if tta_arr.size() != n_cells:
		var cells: Array = map.iter_cells()
		tta_arr = PackedFloat32Array()
		tta_arr.resize(n_cells)
		for i in range(n_cells):
			tta_arr[i] = float((cells[i] as HexCell).temperature_transport_anomaly)
	return {
		"n_cells": n_cells,
		"winter_boost": 1.0,
		"snow_cool": float(cp_now.snow_albedo_cooling),
		"veg_cool": float(cp_now.vegetation_cooling),
		"diurnal_amp": float(cp_now.landform_diurnal_amp),
		"evap_gain": float(cp_now.evaporation_gain),
		"rs_threshold": float(cp_now.rain_shadow_threshold),
		"rs_factor": float(cp_now.rain_shadow_factor),
		"rs_lookback": max(0, int(cp_now.rain_shadow_lookback)),
		"t_freeze": float(cp_now.sea_ice_form_threshold),
		"coupling_gain": float(cp_now.ocean_moisture_coupling_gain),
		"coast_leak": float(_last_cfg.COASTAL_HEAT_LEAK),
		"season_phase": season_phase,
		"go_sparse": false,
		"neighbor_indices": nb_idx,
		"temp_transport_anomaly": tta_arr,
		"foliage_table": _build_climate_b_foliage_table(),
	}


func _build_native_daily_transpiration_knobs(map: MapData, cp_now) -> Dictionary:
	if map == null or cp_now == null:
		return {}
	var n_cells: int = map.cell_count()
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	if n_cells <= 0 or neighbor_indices.size() < n_cells * 6:
		return {}
	return {
		"n_cells": n_cells,
		"outflow_rate": float(cp_now.transpiration_outflow_rate),
		"self_rate": float(cp_now.transpiration_self_rate),
		"neighbor_indices": neighbor_indices,
		"donor_table": _build_transpiration_donor_table(),
	}


func _temperature_transport_anomaly_knobs(cp_now) -> Dictionary:
	var source_cap: float = 0.22
	var blend_rate: float = 0.70
	var decay_rate: float = 0.04
	var zero_current_decay: float = 0.06
	if cp_now != null:
		if cp_now.get("temperature_transport_anomaly_source_cap") != null:
			source_cap = float(cp_now.temperature_transport_anomaly_source_cap)
		if cp_now.get("temperature_transport_anomaly_blend_rate") != null:
			blend_rate = float(cp_now.temperature_transport_anomaly_blend_rate)
		if cp_now.get("temperature_transport_anomaly_decay_rate") != null:
			decay_rate = float(cp_now.temperature_transport_anomaly_decay_rate)
		if cp_now.get("temperature_transport_anomaly_zero_current_decay") != null:
			zero_current_decay = float(cp_now.temperature_transport_anomaly_zero_current_decay)
	return {
		"tta_source_cap": clampf(source_cap, 0.0, 0.5),
		"tta_blend_rate": clampf(blend_rate, 0.0, 1.0),
		"tta_decay_rate": clampf(decay_rate, 0.0, 1.0),
		"tta_zero_current_decay": clampf(zero_current_decay, 0.0, 1.0),
	}


func _apply_temperature_transport_anomaly_knobs(target: Dictionary, tta: Dictionary) -> void:
	for key in tta.keys():
		target[key] = tta[key]


func _prepare_temperature_transport_anomaly_state(map: MapData, n: int, cells: Array = [], prefer_cached: bool = false) -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(maxi(n, 0))
	if n <= 0:
		return out
	if prefer_cached and _gdext_ocean_anomaly_buf_cached.size() == n:
		var cached: PackedFloat32Array = _gdext_ocean_anomaly_buf_cached
		for ci in range(n):
			out[ci] = float(cached[ci])
		return out
	if map != null and map.temperature_transport_anomaly_arr.size() == n:
		var arr: PackedFloat32Array = map.temperature_transport_anomaly_arr
		for ai in range(n):
			out[ai] = float(arr[ai])
		return out
	if not prefer_cached and _gdext_ocean_anomaly_buf_cached.size() == n:
		var cached_after_map: PackedFloat32Array = _gdext_ocean_anomaly_buf_cached
		for cmi in range(n):
			out[cmi] = float(cached_after_map[cmi])
		return out
	if cells.size() == n:
		for i in range(n):
			var cell = cells[i]
			if cell != null:
				out[i] = float((cell as HexCell).temperature_transport_anomaly)
	return out


func _stabilize_temperature_transport_anomaly(prev: float, source: float, source_cap: float, blend_rate: float) -> float:
	var cap: float = absf(source_cap)
	var capped_source: float = clampf(source, -cap, cap)
	var blend: float = clampf(blend_rate, 0.0, 1.0)
	return lerpf(prev, capped_source, blend)


func _decay_temperature_transport_anomaly(prev: float, decay_rate: float) -> float:
	return prev * (1.0 - clampf(decay_rate, 0.0, 1.0))


func _valid_runtime_temp_or_baseline(temp_value: float, baseline: float) -> float:
	return baseline if is_nan(temp_value) or is_inf(temp_value) else temp_value


func _build_native_daily_ocean_knobs(map: MapData, cp_now, season_phase: float) -> Dictionary:
	if map == null or cp_now == null or _last_cfg == null or not bool(_last_cfg.enable_ocean_heat_transport):
		return {}
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6:
		return {}
	var cells: Array = map.iter_cells()
	var dc_views: Dictionary = _climate_views_from_world(cp_now)
	var use_dc: bool = not dc_views.is_empty()
	var temp_a: PackedFloat32Array = dc_views["temp"] if use_dc else map.temp_arr
	var temp_baseline_a: PackedFloat32Array = dc_views["temp_baseline"] if use_dc else map.temp_baseline_arr
	var elev_a: PackedFloat32Array = dc_views["elevation"] if use_dc else map.elevation_arr
	var lat_a: PackedFloat32Array = dc_views["lat_norm"] if use_dc else map.cell_lat_norm_arr
	var ema_init_a: PackedByteArray = dc_views["ema_initialized"] if use_dc else map.ema_initialized_arr
	var ocx_a: PackedFloat32Array = dc_views["ocean_current_x"] if use_dc else map.ocean_current_x_arr
	var ocy_a: PackedFloat32Array = dc_views["ocean_current_y"] if use_dc else map.ocean_current_y_arr
	if temp_a.size() < n or elev_a.size() < n:
		return {}
	if _gdext_ocean_baseline_work_buf.size() != n:
		_gdext_ocean_baseline_work_buf.resize(n)
	if _gdext_ocean_temp_before_work_buf.size() != n:
		_gdext_ocean_temp_before_work_buf.resize(n)
	if _gdext_ocean_anomaly_work_buf.size() != n:
		_gdext_ocean_anomaly_work_buf.resize(n)
	var baseline: PackedFloat32Array = _gdext_ocean_baseline_work_buf
	var temp_before: PackedFloat32Array = _gdext_ocean_temp_before_work_buf
	for i in range(n):
		if ema_init_a.size() > i and ema_init_a[i] != 0 and temp_baseline_a.size() > i:
			baseline[i] = temp_baseline_a[i]
		else:
			var ny: float = lat_a[i] if lat_a.size() > i else _cube_row_norm(cells[i], _last_cfg)
			baseline[i] = _compute_temperature(ny, elev_a[i])
		var t0: float = temp_a[i]
		temp_before[i] = _valid_runtime_temp_or_baseline(t0, baseline[i])
	var anomaly: PackedFloat32Array = _gdext_ocean_anomaly_work_buf
	var prev_anomaly: PackedFloat32Array = _prepare_temperature_transport_anomaly_state(map, n, cells)
	for ai in range(n):
		anomaly[ai] = prev_anomaly[ai]
	var winter_boost: float = 1.0
	var tta: Dictionary = _temperature_transport_anomaly_knobs(cp_now)
	var water_knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, _last_cfg.OCEAN_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(_last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0),
		"neighbor_indices": nb_idx,
		"baseline_arr": baseline,
		"temp_before_arr": temp_before,
		"anomaly_out": anomaly,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
	}
	var land_knobs: Dictionary = {
		"n_cells": n,
		"effective_leak": float(_last_cfg.COASTAL_HEAT_LEAK) * winter_boost,
		"neighbor_indices": nb_idx,
		"anomaly_inout": anomaly,
		"fallback_baseline_arr": baseline,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
	}
	_apply_temperature_transport_anomaly_knobs(water_knobs, tta)
	_apply_temperature_transport_anomaly_knobs(land_knobs, tta)
	return {
		"water": water_knobs,
		"land": land_knobs,
	}


func _build_native_daily_sea_ice_knobs(map: MapData, cp_now, season_phase: float, commit_side_effects: bool) -> Dictionary:
	if map == null or cp_now == null or _last_cfg == null:
		return {}
	var cells_fast: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_fast: int = cells_fast.size()
	var nb_idx_fast: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	if n_cells_fast <= 0 or nb_idx_fast.size() < n_cells_fast * 6:
		return {}
	var k_freeze: float = float(cp_now.sea_ice_freeze_rate)
	var k_melt: float = float(cp_now.sea_ice_melt_rate)
	var t_form: float = float(cp_now.sea_ice_form_threshold)
	var t_melt: float = float(cp_now.sea_ice_melt_threshold)
	var climate_anomaly_now: float = 0.0
	if _world_clock_ref != null:
		var ca_v = _world_clock_ref.get("climate_anomaly")
		if ca_v != null:
			climate_anomaly_now = float(ca_v)
	if not is_equal_approx(climate_anomaly_now, 0.0):
		var ice_thr_shift: float = 0.10 * climate_anomaly_now
		t_form = clampf(t_form - ice_thr_shift, 0.0, 1.0)
		t_melt = clampf(t_melt - ice_thr_shift, 0.0, 1.0)
	var dt_days: float = _consume_sea_ice_dt_days() if commit_side_effects else 1.0
	var base_terrain_input: PackedByteArray
	if map.base_terrain_arr.size() == n_cells_fast:
		base_terrain_input = map.base_terrain_arr
	else:
		if _gdext_sea_ice_base_terrain_buf.size() != n_cells_fast:
			_gdext_sea_ice_base_terrain_buf.resize(n_cells_fast)
		base_terrain_input = _gdext_sea_ice_base_terrain_buf
		for i_build in range(n_cells_fast):
			var c_build: HexCell = cells_fast[i_build]
			_gdext_sea_ice_base_terrain_buf[i_build] = int(c_build.base_terrain) & 0xFF
	var tta_input: PackedFloat32Array
	if _gdext_ocean_anomaly_buf_cached.size() == n_cells_fast:
		tta_input = _gdext_ocean_anomaly_buf_cached
	elif map.temperature_transport_anomaly_arr.size() == n_cells_fast:
		tta_input = map.temperature_transport_anomaly_arr
	else:
		if _gdext_sea_ice_tta_buf.size() != n_cells_fast:
			_gdext_sea_ice_tta_buf.resize(n_cells_fast)
		tta_input = _gdext_sea_ice_tta_buf
		for i_tta in range(n_cells_fast):
			tta_input[i_tta] = cells_fast[i_tta].temperature_transport_anomaly
	var upw_input: PackedFloat32Array = map.upwelling_strength_arr \
			if map.upwelling_strength_arr.size() == n_cells_fast \
			else _gdext_sea_ice_upw_buf
	if upw_input.size() != n_cells_fast:
		_gdext_sea_ice_upw_buf.resize(n_cells_fast)
		upw_input = _gdext_sea_ice_upw_buf
		for i_upw in range(n_cells_fast):
			upw_input[i_upw] = cells_fast[i_upw].upwelling_strength
	var temp_input: PackedFloat32Array = map.temp_arr \
			if map.temp_arr.size() == n_cells_fast \
			else _gdext_sea_ice_temp_buf
	if temp_input.size() != n_cells_fast:
		_gdext_sea_ice_temp_buf.resize(n_cells_fast)
		temp_input = _gdext_sea_ice_temp_buf
		for i_temp in range(n_cells_fast):
			temp_input[i_temp] = cells_fast[i_temp].temperature
	var insol_input: PackedFloat32Array = _sea_ice_insolation_input(map, cells_fast, season_phase)
	var water_ids: PackedByteArray = PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		int(TerrainType.TERRAIN.COAST) & 0xFF,
		int(TerrainType.TERRAIN.LAKE) & 0xFF,
		int(TerrainType.TERRAIN.REEF) & 0xFF,
		int(TerrainType.TERRAIN.KELP) & 0xFF,
		int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
	])
	return {
		"n_cells": n_cells_fast,
		"k_freeze": k_freeze,
		"k_melt": k_melt,
		"dt_days": dt_days,
		"t_form": t_form,
		"t_melt": t_melt,
		"contagion": float(cp_now.sea_ice_neighbor_contagion),
		"threshold": float(cp_now.sea_ice_terrain_threshold),
		"hysteresis": float(cp_now.sea_ice_terrain_hysteresis),
		"ice_delay": float(_last_cfg.OCEAN_CURRENT_ICE_DELAY),
		"enable_ocean_heat_transport": bool(_last_cfg.enable_ocean_heat_transport),
		"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
		"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
		"water_terrain_ids": water_ids,
		"neighbor_indices": nb_idx_fast,
		"base_terrain_arr": base_terrain_input,
		"temp_transport_anomaly": tta_input,
		"upwelling_strength": upw_input,
		"insolation_now_arr": insol_input,
		"solar_gate_enabled": _sea_ice_solar_gate_enabled(cp_now),
		"freeze_insol_low": float(cp_now.sea_ice_freeze_insol_low),
		"freeze_insol_high": float(cp_now.sea_ice_freeze_insol_high),
		"solar_melt_start": float(cp_now.sea_ice_solar_melt_start),
		"solar_melt_gain": float(cp_now.sea_ice_solar_melt_gain),
		"daily_delta_cap": float(cp_now.sea_ice_daily_delta_cap) if cp_now.get("sea_ice_daily_delta_cap") != null else 0.08,
		"cell_temperature_arr": temp_input,
		"apply_terrain_flips": commit_side_effects,
	}


func _native_daily_required_pass_keys(cp_now) -> PackedStringArray:
	var keys := PackedStringArray(["climate_pass_a_struct"])
	if cp_now != null and bool(cp_now.enable_local_climate_coupling):
		keys.append("climate_pass_b_knobs")
		keys.append("transpiration_knobs")
	if _last_cfg != null and bool(_last_cfg.enable_ocean_heat_transport):
		keys.append("ocean_water_knobs")
		keys.append("ocean_land_knobs")
	keys.append("sea_ice_knobs")
	# stage_b follows albedo / vegetation / feedback strides and is legitimately
	# absent on most probe ticks. Requiring it here prevents native_daily active
	# handoff even though the scheduler can simply skip that node for the tick.
	var weather_field_required: bool = _weather_system != null \
			and _weather_system.has_method("uses_weather_field") \
			and bool(_weather_system.uses_weather_field())
	if weather_field_required:
		keys.append("weather_knobs")
	return keys


func _native_daily_required_pass_keys_array(cp_now) -> Array[String]:
	var out: Array[String] = []
	for key in _native_daily_required_pass_keys(cp_now):
		out.append(String(key))
	return out


func _native_daily_missing_required_pass_keys(bundle: Dictionary, required: PackedStringArray) -> PackedStringArray:
	var missing := PackedStringArray()
	for key in required:
		if not bundle.has(key):
			missing.append(key)
	return missing


func _build_native_daily_bundle(ctx: SusTickContext, map: MapData, _world: WorldData,
		commit_side_effects: bool = false) -> Dictionary:
	var cp_now := _c()
	if map == null or cp_now == null:
		return {}
	var bundle: Dictionary = {
		"refresh_slots_from_map": true,
		"flush_slots_to_map": true,
	}
	# Phase C.1（dots-total-cpp roadmap）：System schedule graph 双轨入口。
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_system_schedule flag 已删除，
	# C++ 端 run_native_daily_tick 现恒走 system_schedule.cpp 的
	# dispatch_system_schedule loop。输出 dict（breakdown / fronts / succession_*）
	# 必须 bit-equal（dots_soak_ab_runner SAME_SOURCE 1000-tick A/B 验收）。
	# 任意节点失败 → C++ 端 finish_with_failure 短路返回 rc=-1，与原 if-chain
	# 同语义（caller 在 run_native_daily_tick_from_job 已有 fallback 处理）。
	bundle["use_system_schedule"] = true
	var pass_a_struct: Dictionary = _build_native_daily_climate_pass_a_struct(map, cp_now, ctx.season_phase)
	if not pass_a_struct.is_empty():
		bundle["climate_pass_a_struct"] = pass_a_struct
	var pass_b_knobs: Dictionary = _build_native_daily_climate_pass_b_knobs(map, cp_now, ctx.season_phase)
	if not pass_b_knobs.is_empty():
		bundle["climate_pass_b_knobs"] = pass_b_knobs
	var transp_knobs: Dictionary = _build_native_daily_transpiration_knobs(map, cp_now)
	if not transp_knobs.is_empty():
		bundle["transpiration_knobs"] = transp_knobs
	var ocean_knobs: Dictionary = _build_native_daily_ocean_knobs(map, cp_now, ctx.season_phase)
	if not ocean_knobs.is_empty():
		bundle["ocean_water_knobs"] = ocean_knobs.get("water", {})
		bundle["ocean_land_knobs"] = ocean_knobs.get("land", {})
	var sea_ice_knobs: Dictionary = _build_native_daily_sea_ice_knobs(map, cp_now, ctx.season_phase, commit_side_effects)
	if not sea_ice_knobs.is_empty():
		bundle["sea_ice_knobs"] = sea_ice_knobs
	# Phase A.2 unified fast tick: dots-flag-prune-pr1 round 2 (2026-05-22):
	# use_gdext_unified_fast_tick / use_gdext_weather_refresh_daily flag 均已删除——
	# weather refresh daily 的 4 组 super_knobs（field/distribute/summary + stage_b
	# 平铺）现恒嵌入 bundle，仅受 ext + has_method 探测控制。任意前置不满足
	# （weather_system null / fast_indexed 缺失）自动返回空 dict，此时 bundle 不含
	# weather_knobs，C++ 端短路跳过 weather 段——bit-equal 兜底。
	var stage_b_knobs: Dictionary = _build_native_daily_stage_b_knobs(
		map,
		cp_now,
		maxi(1, _weather_stage_b_call_index)
	)
	var stage_b_embedded_in_weather: bool = false
	var native_weather_daily_allowed: bool = weather_native_daily_available()
	if _weather_system != null and _world != null \
			and native_weather_daily_allowed \
			and _weather_system.has_method("build_unified_fast_tick_weather_knobs"):
		var season_idx_local: int = 0
		var anomaly_local: float = 0.0
		var season_phase_local: float = -1.0
		if _world_clock_ref != null:
			if _world_clock_ref.has_method("season_index"):
				season_idx_local = int(_world_clock_ref.season_index())
			var v_anom = _world_clock_ref.get("climate_anomaly")
			if v_anom != null:
				anomaly_local = float(v_anom)
			var v_phase = _world_clock_ref.get("season_phase") if _world_clock_ref.get("season_phase") != null else null
			if v_phase != null:
				season_phase_local = float(v_phase)
		# 同步推进 stage_b call_index：unified 路径完全绕过 weather_refresh_job /
		# refresh_weather_daily facade，stride 计数必须自己 ++（与 facade line 8448 等价）。
		# fallback（caller 端 res.rc!=0）情形会回滚（见 run_native_daily_tick_from_job）。
		if commit_side_effects:
			_weather_stage_b_call_index += 1
		var weather_super: Dictionary = _weather_system.build_unified_fast_tick_weather_knobs(
			map, _world, season_idx_local, anomaly_local, season_phase_local, stage_b_knobs
		)
		if not weather_super.is_empty():
			bundle["weather_knobs"] = weather_super
			stage_b_embedded_in_weather = true
		else:
			# fast_indexed 缺失等前置失败 → 回滚 stage_b call_index，weather 段不嵌入。
			if commit_side_effects:
				_weather_stage_b_call_index = maxi(0, _weather_stage_b_call_index - 1)
	elif _weather_system != null and _world != null and not native_weather_daily_allowed:
		bundle["weather_native_daily_blocked"] = true
	if not stage_b_embedded_in_weather and not stage_b_knobs.is_empty():
		bundle["stage_b_knobs"] = stage_b_knobs
	return bundle


func _native_daily_bundle_pass_keys(bundle: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for k in bundle.keys():
		var s: String = str(k)
		if s.ends_with("_knobs") or s == "climate_pass_a_struct":
			keys.append(s)
	keys.sort()
	return keys


func _run_native_daily_shadow_probe(ctx: SusTickContext, map: MapData, world: WorldData) -> void:
	var cp := _c()
	if not _native_mode_is_shadow(cp, "native_daily_sim_mode"):
		return
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("run_native_daily_tick"):
		_native_daily_last_result = { "rc": -1, "mode": "shadow_probe", "fail_stage": "gdext_unavailable" }
		return
	var bundle: Dictionary = _build_native_daily_bundle(ctx, map, world)
	var pass_keys: Array[String] = _native_daily_bundle_pass_keys(bundle)
	if pass_keys.is_empty():
		_native_daily_last_result = { "rc": -1, "mode": "shadow_probe", "fail_stage": "empty_bundle" }
		return
	var tick_knobs: Dictionary = _native_daily_base_tick_knobs(ctx)
	tick_knobs["probe"] = true
	tick_knobs["native_daily_bundle"] = bundle
	tick_knobs["required_pass_keys"] = _native_daily_required_pass_keys_array(cp)
	var res: Dictionary = _data_core_world_ext.run_native_daily_tick(tick_knobs)
	res["mode"] = "shadow_probe"
	res["bundle_pass_keys"] = pass_keys
	_native_daily_last_result = res.duplicate(true)
	if not _native_daily_shadow_probe_logged:
		_native_daily_shadow_probe_logged = true
		var pass_key_text: String = ", ".join(PackedStringArray(pass_keys))
		print("[native_daily] SHADOW probe rc=%s passes=%s (legacy SUS remains authoritative)"
			% [str(res.get("rc", -1)), pass_key_text])


func _configure_native_world_context(map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	_native_daily_configured = false
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("configure_native_world"):
		return
	var cp := _c()
	var knobs: Dictionary = {
		"cell_count": map.cell_count() if map != null else 0,
		"hex_size": hex_size,
		"native_generation_mode": int(cp.get("native_generation_mode")) if cp != null and cp.get("native_generation_mode") != null else 0,
		"native_daily_sim_mode": int(cp.get("native_daily_sim_mode")) if cp != null and cp.get("native_daily_sim_mode") != null else 0,
		"native_render_prepare_mode": int(cp.get("native_render_prepare_mode")) if cp != null and cp.get("native_render_prepare_mode") != null else 0,
		"native_daily_perf_target_ms": float(cp.get("native_daily_perf_target_ms")) if cp != null and cp.get("native_daily_perf_target_ms") != null else 1.0,
		"shadow_diff_enabled": bool(cp.get("native_shadow_diff_enabled")) if cp != null and cp.get("native_shadow_diff_enabled") != null else true,
		"has_world_data": world != null,
		"has_config": cfg != null,
	}
	var res: Dictionary = _data_core_world_ext.configure_native_world(knobs)
	_native_daily_configured = int(res.get("rc", -1)) == 0
	if OS.is_debug_build():
		print("[native_world] configure rc=%s reason=%s cells=%d"
			% [str(res.get("rc", -1)), str(res.get("reason", "")), int(knobs["cell_count"])])


func _try_register_native_daily_sim_job(map: MapData, world: WorldData) -> bool:
	var cp := _c()
	if not _native_mode_is_active(cp, "native_daily_sim_mode"):
		return false
	var weather_field_required: bool = _weather_system != null \
			and _weather_system.has_method("uses_weather_field") \
			and bool(_weather_system.uses_weather_field())
	if weather_field_required and not weather_native_daily_available():
		push_warning("[native_daily] ACTIVE requested but staged weather field is the only verified visible weather authority; falling back to legacy SUS jobs")
		return false
	if not _native_daily_configured or _data_core_world_ext == null:
		push_warning("[native_daily] ACTIVE requested but native world is not configured; falling back to legacy SUS jobs")
		return false
	if not _data_core_world_ext.has_method("run_native_daily_tick"):
		push_warning("[native_daily] ACTIVE requested but gdext lacks run_native_daily_tick; falling back to legacy SUS jobs")
		return false
	var probe_ctx: SusTickContext = SusTickContext.make(0, 0, 0.0, 1.0, &"native_daily_probe")
	var probe_bundle: Dictionary = _build_native_daily_bundle(probe_ctx, map, world)
	var required_pass_keys_packed: PackedStringArray = _native_daily_required_pass_keys(cp)
	var required_pass_keys: Array[String] = _native_daily_required_pass_keys_array(cp)
	var missing_required: PackedStringArray = _native_daily_missing_required_pass_keys(
			probe_bundle, required_pass_keys_packed)
	var probe: Dictionary = _data_core_world_ext.run_native_daily_tick({
		"probe": true,
		"native_daily_bundle": probe_bundle,
		"required_pass_keys": required_pass_keys,
	})
	if int(probe.get("rc", -1)) != 0:
		push_warning("[native_daily] ACTIVE requested but native tick is not ready (%s); falling back to legacy SUS jobs"
			% str(probe.get("fail_stage", probe.get("reason", ""))))
		return false
	if not missing_required.is_empty():
		push_warning("[native_daily] ACTIVE requested but native bundle is missing required passes: %s; falling back to legacy SUS jobs"
			% ", ".join(missing_required))
		return false
	var native_daily_authoritative_ready: bool = bool(probe.get("authoritative_ready", false))
	if not native_daily_authoritative_ready:
		var probe_missing := PackedStringArray()
		for key in probe.get("missing_pass_keys", []):
			probe_missing.append(String(key))
		push_warning("[native_daily] ACTIVE requested but native probe did not authorize handoff (missing=%s); falling back to legacy SUS jobs"
			% ", ".join(probe_missing))
		return false
	var native_stride: int = 1
	if cp != null and cp.get("native_daily_sim_stride") != null:
		native_stride = clampi(int(cp.native_daily_sim_stride), 1, 8)
	_native_daily_sim_job = NativeDailySimJobScript.new(self, map, world, native_stride)
	_apply_sim_budget_profile_to_job(_native_daily_sim_job, cp, false)
	if _use_dc_system_scheduler:
		_sus.register_system(_native_daily_sim_job)
	else:
		_sus.register_job(_native_daily_sim_job)
	return true


func _try_register_native_environment_runtime_system(map: MapData, cp) -> bool:
	_native_environment_runtime_job = null
	if cp == null or cp.get("native_environment_runtime_enabled") == null or not bool(cp.native_environment_runtime_enabled):
		return false
	if get_environment_runtime() == null:
		push_warning("[native_env_runtime] enabled but EnvironmentRuntime class is unavailable; skipping thin native scheduler job")
		return false
	var runtime_stride: int = 1
	if cp.get("native_environment_runtime_stride") != null:
		runtime_stride = clampi(int(cp.native_environment_runtime_stride), 1, 8)
	_native_environment_runtime_job = NativeEnvironmentRuntimeSystemScript.new(self, map, runtime_stride)
	_apply_sim_budget_profile_to_job(_native_environment_runtime_job, cp, false)
	_native_environment_runtime_job.slice_budget_ms = min(float(_native_environment_runtime_job.slice_budget_ms), 0.5)
	_native_environment_runtime_job.must_run = false
	if _use_dc_system_scheduler:
		_sus.register_system(_native_environment_runtime_job)
	else:
		_sus.register_job(_native_environment_runtime_job)
	if OS.is_debug_build():
		print("[native_env_runtime] SHADOW: registered thin EnvironmentRuntime step job")
	return true


func _register_visual_upload_jobs(map: MapData, world: WorldData, hex_size: float, cp) -> void:
	var enum_atlas_stride: int = 2
	var dynamic_visual_atlas_stride: int = _dyn_atlas_upload_stride
	if cp != null:
		if cp.get("enum_atlas_upload_stride") != null:
			enum_atlas_stride = clampi(int(cp.enum_atlas_upload_stride), 1, 8)
		if cp.get("dynamic_visual_atlas_upload_stride") != null:
			dynamic_visual_atlas_stride = clampi(int(cp.dynamic_visual_atlas_upload_stride), 1, 8)
	_dyn_atlas_upload_stride = dynamic_visual_atlas_stride
	if _use_dc_system_scheduler:
		_enum_atlas_upload_job = EnumAtlasUploadSystemScript.new(self, _baker, map, world, hex_size, enum_atlas_stride, _data_core_world_ext)
		_apply_sim_budget_profile_to_job(_enum_atlas_upload_job, cp, true)
		_sus.register_system(_enum_atlas_upload_job)
	else:
		_enum_atlas_upload_job = EnumAtlasUploadJobScript.new(self, _baker, map, world, hex_size, enum_atlas_stride, _data_core_world_ext)
		_apply_sim_budget_profile_to_job(_enum_atlas_upload_job, cp, true)
		_sus.register_job(_enum_atlas_upload_job)
	# 海冰主视觉由 shader 按 current_temp/latitude/depth 直接派生；停用旧 atlas upload。
	_sea_ice_atlas_upload_job = null
	_last_sea_ice_atlas_upload_breakdown = {
		"done": true,
		"phase": "disabled",
		"stage_name": "sea_ice_atlas_upload",
		"elapsed_ms": 0.0,
		"reason": "shader_temperature_derived",
	}
	# plan/dirty-push-atlas-encode 阶段 D：把 cp 传给 system，让其入口可调
	# DCFeatureFlags.is_on(&"dirty_push_enabled", cp) 决定是否走 mask 路径。
	_dynamic_visual_atlas_upload_job = DynamicVisualAtlasUploadSystemScript.new(
			_baker, map, world, _dyn_atlas_upload_stride, cp, _data_core_world,
			_data_core_world_ext)
	_apply_sim_budget_profile_to_job(_dynamic_visual_atlas_upload_job, cp, true)
	if _use_dc_system_scheduler:
		_sus.register_system(_dynamic_visual_atlas_upload_job)
	else:
		_sus.register_job(_dynamic_visual_atlas_upload_job)


func run_native_daily_tick_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("run_native_daily_tick"):
		return { "rc": -1, "fail_stage": "gdext_unavailable" }
	var bundle: Dictionary = _build_native_daily_bundle(ctx, _map, _world, true)
	var unified_weather_embedded: bool = bundle.has("weather_knobs")
	var tick_knobs: Dictionary = _native_daily_base_tick_knobs(ctx)
	tick_knobs["native_daily_bundle"] = bundle
	var res: Dictionary = _data_core_world_ext.run_native_daily_tick(tick_knobs)
	res["bundle_pass_keys"] = _native_daily_bundle_pass_keys(bundle)
	_native_daily_last_result = res.duplicate(true)
	var breakdown: Dictionary = res.get("breakdown", {})
	_last_weather_breakdown = breakdown.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_last_weather_breakdown["_tick_idx"] = _current_fast_tick_idx
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	_dump_weather_breakdown_if_slow()
	# Phase A.2 unified fast tick：成功路径下同步 weather state（fronts + cyclone +
	# cover_dirty + slice cleanup）。失败路径下回滚 stage_b call_index 并清 slice state
	# 让下次有机会重试 / 让独立 weather_refresh_job 接手（如果它被注册）。
	if unified_weather_embedded and _weather_system != null:
		var rc_int: int = int(res.get("rc", -1))
		if rc_int == 0:
			if not _unified_fast_tick_first_log_done:
				_unified_fast_tick_first_log_done = true
				print("[native_daily/unified] gdext path ACTIVE — weather_knobs embedded in native_daily_bundle; 16-pass single-marshal tick first run total_ms=%.2f weather_ms=%.2f"
						% [float(breakdown.get("total_ms", 0.0)), float(breakdown.get("weather_ms", 0.0))])
			if _weather_system.has_method("apply_unified_fast_tick_result"):
				# breakdown 顶层就是 weather 段产出（C++ 端 copy_dict_into 把
				# run_weather_refresh_daily_pass 返回值合进 native_daily breakdown）。
				var fronts_out: Array[WeatherFront] = _weather_system.apply_unified_fast_tick_result(breakdown)
				_last_active_fronts = fronts_out
				_weather_round_fronts = fronts_out
				res["fronts"] = fronts_out
				res["fronts_changed"] = true
				# enum_atlas dirty mark：与 refresh_weather_daily facade line 8497-8506 等价。
				if _baker != null:
					if _weather_system.has_method("has_cover_dirty") and bool(_weather_system.has_cover_dirty()):
						_mark_enum_atlas_dirty(true, false)
					var succ_indices = breakdown.get("succession_indices", null)
					var veg_dirty: bool = succ_indices != null \
							and (typeof(succ_indices) == TYPE_PACKED_INT32_ARRAY) \
							and (succ_indices as PackedInt32Array).size() > 0
					if not veg_dirty:
						veg_dirty = int(breakdown.get("stat_succession_count", 0)) > 0
					if veg_dirty:
						_mark_enum_atlas_dirty(false, true)
		else:
			# 失败回滚：stage_b call_index 还原 + 清理 slice state（weather_system 内部
			# 已自我守护，但 caller 端也防御性清一次，避免泄漏到下个 tick）。
			_weather_stage_b_call_index = maxi(0, _weather_stage_b_call_index - 1)
			if _weather_system.has_method("_clear_weather_field_slice_state"):
				_weather_system._clear_weather_field_slice_state()
			if not _unified_fast_tick_warned_fallback:
				_unified_fast_tick_warned_fallback = true
				push_warning("[native_daily/unified] embedded weather_knobs path rc=%d fail_stage=%s; weather_refresh state cleared; will fallback to independent jobs next tick"
						% [rc_int, String(res.get("fail_stage", "unknown"))])
	return res


func run_native_sim_tick_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	if _data_core_world_ext == null:
		return { "rc": -1, "fail_stage": "gdext_unavailable" }
	if not _data_core_world_ext.has_method("run_native_sim_tick"):
		return run_native_daily_tick_from_job(ctx, _map, _world)
	var bundle: Dictionary = _build_native_daily_bundle(ctx, _map, _world, true)
	var unified_weather_embedded: bool = bundle.has("weather_knobs")
	var tick_knobs: Dictionary = _native_daily_base_tick_knobs(ctx)
	tick_knobs["native_daily_bundle"] = bundle
	tick_knobs["shadow_diff_enabled"] = bool(_c().native_shadow_diff_enabled) if _c() != null and _c().get("native_shadow_diff_enabled") != null else false
	var res: Dictionary = _data_core_world_ext.run_native_sim_tick(tick_knobs)
	res["bundle_pass_keys"] = _native_daily_bundle_pass_keys(bundle)
	_native_daily_last_result = res.duplicate(true)
	var breakdown: Dictionary = res.get("breakdown", {})
	_last_weather_breakdown = breakdown.duplicate(true)
	_last_weather_breakdown["_tick_idx"] = _current_fast_tick_idx
	_dump_weather_breakdown_if_slow()
	if unified_weather_embedded and _weather_system != null:
		var rc_int: int = int(res.get("rc", -1))
		if rc_int == 0:
			if not _unified_fast_tick_first_log_done:
				_unified_fast_tick_first_log_done = true
				print("[native_daily/unified] native sim tick ACTIVE — weather_knobs embedded; total_ms=%.2f weather_ms=%.2f"
						% [float(breakdown.get("total_ms", 0.0)), float(breakdown.get("weather_ms", 0.0))])
			if _weather_system.has_method("apply_unified_fast_tick_result"):
				var fronts_out: Array[WeatherFront] = _weather_system.apply_unified_fast_tick_result(breakdown)
				_last_active_fronts = fronts_out
				_weather_round_fronts = fronts_out
				res["fronts"] = fronts_out
				res["fronts_changed"] = true
				if _baker != null:
					if _weather_system.has_method("has_cover_dirty") and bool(_weather_system.has_cover_dirty()):
						_mark_enum_atlas_dirty(true, false)
					var succ_indices = breakdown.get("succession_indices", null)
					var veg_dirty: bool = succ_indices != null \
							and (typeof(succ_indices) == TYPE_PACKED_INT32_ARRAY) \
							and (succ_indices as PackedInt32Array).size() > 0
					if not veg_dirty:
						veg_dirty = int(breakdown.get("stat_succession_count", 0)) > 0
					if veg_dirty:
						_mark_enum_atlas_dirty(false, true)
		else:
			_weather_stage_b_call_index = maxi(0, _weather_stage_b_call_index - 1)
			if _weather_system.has_method("_clear_weather_field_slice_state"):
				_weather_system._clear_weather_field_slice_state()
			if not _unified_fast_tick_warned_fallback:
				_unified_fast_tick_warned_fallback = true
				push_warning("[native_daily/unified] native sim tick rc=%d fail_stage=%s; weather state cleared"
						% [rc_int, String(res.get("fail_stage", "unknown"))])
	return res


func native_daily_last_result() -> Dictionary:
	return _native_daily_last_result.duplicate(true)


func sus_tick_daily(world_clock_node, day_index_override: int = -1,
		season_phase_override: float = NAN) -> Dictionary:
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
	if day_index_override >= 0:
		di = day_index_override
	if not is_nan(season_phase_override):
		sp = season_phase_override
	# 任务 8：每个 tick 入场前清掉 weather_refresh 的 ran_this_tick 标志，
	# 这样 SUS 决定跳过该 Job 时它就保持 false（main.gd 据此跳过 UI 行刷新）。
	if _refresh_climate_daily_job != null:
		_refresh_climate_daily_job.reset_run_flag()
	if _sea_ice_daily_job != null and _sea_ice_daily_job.has_method("reset_run_flag"):
		_sea_ice_daily_job.reset_run_flag()
	if _weather_refresh_job != null:
		_weather_refresh_job.reset_run_flag()
	if _native_daily_sim_job != null and _native_daily_sim_job.has_method("reset_run_flag"):
		_native_daily_sim_job.reset_run_flag()
	var ctx: SusTickContext = SusTickContext.make(di, di, sp, ss, &"day_changed")
	_sync_data_core_runtime_terrain_mirror(_sus_map, "sus_tick_pre")
	_sus.tick(ctx)
	if _native_daily_sim_job == null:
		_run_native_daily_shadow_probe(ctx, _sus_map, _sus_world)
	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	var weather_ran: bool = false
	# Drift-fix（2026-05-10）：暴露"fronts 是否真的变了"标志。
	# 与 weather_ran 区别：field 分片期间二者都保持 false；只有 commit + stage_b
	# 完成、_last_fronts 重新赋值时才置位，避免 UI/renderer 读取半成品。
	# main.gd 用它 gate renderer.set_weather_fronts 调用，避免每隔一 tick 重复推送
	# 同一份 fronts 触发 weather_layer 内部的 blend reset → 云视觉冻结。
	var fronts_changed: bool = false
	var fronts_diff: Dictionary = {}
	if _weather_refresh_job != null:
		fronts = _weather_refresh_job.last_fronts()
		weather_ran = _weather_refresh_job.did_run_last_tick()
		fronts_changed = _weather_refresh_job.did_change_fronts_last_tick()
		if _weather_refresh_job.has_method("last_fronts_diff_report"):
			fronts_diff = _weather_refresh_job.last_fronts_diff_report()
	elif _native_daily_sim_job != null:
		var native_res: Dictionary = _native_daily_last_result
		weather_ran = int(native_res.get("rc", -1)) == 0
		fronts_changed = bool(native_res.get("fronts_changed", false))
		fronts = native_res.get("fronts", [] as Array[WeatherFront])
		fronts_diff = native_res.get("fronts_diff", {})
	# 天气类型交叉淡入的"跳过日 GDScript 兜底"已移除（2026-06-17）：该淡入纯属
	# 视觉平滑，且没有任何 shader 采样 cell.weather_transition_alpha（地图只读离散
	# weather_type），高倍速下逐 cell fan-out 反而是 ~35ms/次的空耗。淡入开关
	# weather_transition_enabled 现仅作用于 C++ weather.commit（跑天气日推进）。
	return { "fronts": fronts, "weather_ran": weather_ran, "fronts_changed": fronts_changed, "fronts_diff": fronts_diff }


## 地图重新生成 / regenerate 路径调用：清空所有 Job 的进度游标 + pending 缓冲。
func sus_reset_all() -> void:
	_abort_all_climate_passes("sus_reset_all")
	if _sus != null:
		_sus.reset_all_progress()


func sus_report_last_tick() -> Dictionary:
	if _sus == null:
		return {}
	return _sus.report_last_tick()


# Perf instrumentation freshness（方案 ④ Step 1）：main.gd._run_fast_tick() 顶部
# 每帧调用一次，把当前 _fast_tick_count 同步给 generator。所有 _last_*_breakdown
# 写入点会从这里取值打到字典内的 `_tick_idx` 字段，让 perf_recorder 区分
# "本帧真刷新过" vs "stale 快照回放"。
func set_current_fast_tick_idx(idx: int) -> void:
	_current_fast_tick_idx = idx
	# DVA 不持有 generator 引用，单独同步过去；其内部 4 个 _last_breakdown 写入点
	# 直接读 current_fast_tick_idx。
	if _dynamic_visual_atlas_upload_job != null \
			and "current_fast_tick_idx" in _dynamic_visual_atlas_upload_job:
		_dynamic_visual_atlas_upload_job.current_fast_tick_idx = idx


func get_current_fast_tick_idx() -> int:
	return _current_fast_tick_idx


# Daily-sim perf instrumentation：返回上一次 refresh_climate_daily 的子段拆解，
# 供 main.gd fast tick WARN / 详细日志路径定位 6 段子耗时。
func sus_climate_breakdown() -> Dictionary:
	return _last_climate_breakdown.duplicate()


func sus_ocean_currents_breakdown() -> Dictionary:
	var out: Dictionary = {}
	if _ocean_currents_job != null and _ocean_currents_job.has_method("last_physical_diag"):
		out = _ocean_currents_job.last_physical_diag()
	if _baker != null and _baker.has_method("get_physical_circulation_diag"):
		var baker_diag: Dictionary = _baker.get_physical_circulation_diag()
		for k in baker_diag.keys():
			out[k] = baker_diag[k]
	out["_tick_idx"] = _current_fast_tick_idx
	return out


func did_refresh_climate_run_this_tick() -> bool:
	return _refresh_climate_daily_job != null and _refresh_climate_daily_job.did_run_last_tick()


func last_refresh_climate_slice_ms() -> float:
	if _refresh_climate_daily_job == null:
		return 0.0
	return _refresh_climate_daily_job.last_slice_elapsed_ms()


# Daily-sim perf instrumentation（weather）：返回上一次 refresh_daily 的子段拆解，
# 供 main.gd fast tick WARN 路径定位 weather_refresh 的生成/分发/反馈 8+ 段子耗时。
func sus_weather_breakdown() -> Dictionary:
	return _last_weather_breakdown.duplicate()


func merge_weather_job_breakdown(extra: Dictionary) -> void:
	for k in extra.keys():
		_last_weather_breakdown[k] = extra[k]


func has_pending_enum_atlas_upload() -> bool:
	return _enum_atlas_biome_dirty or _enum_atlas_cover_dirty or _enum_atlas_vegetation_dirty


func consume_pending_enum_atlas_axis() -> String:
	if _enum_atlas_biome_dirty:
		_enum_atlas_biome_dirty = false
		_enum_atlas_cover_dirty = false
		_enum_atlas_vegetation_dirty = false
		return "biome"
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
		"biome_pending": _enum_atlas_biome_dirty,
		"cover_pending": _enum_atlas_cover_dirty,
		"vegetation_pending": _enum_atlas_vegetation_dirty,
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		"_tick_idx": _current_fast_tick_idx,
	}


func record_enum_atlas_upload_report(report: Dictionary) -> void:
	_last_enum_atlas_upload_breakdown = report.duplicate(true)
	_last_enum_atlas_upload_breakdown["biome_pending"] = _enum_atlas_biome_dirty
	_last_enum_atlas_upload_breakdown["cover_pending"] = _enum_atlas_cover_dirty
	_last_enum_atlas_upload_breakdown["vegetation_pending"] = _enum_atlas_vegetation_dirty
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_last_enum_atlas_upload_breakdown["_tick_idx"] = _current_fast_tick_idx


func sus_enum_atlas_breakdown() -> Dictionary:
	return _last_enum_atlas_upload_breakdown.duplicate()


# DOTS-Final-Push 任务 6.2：sea_ice_atlas_upload Job 在每次 slice 末尾调用本方法，
# 把 prepare_ms / upload_ms / image_ms / dirty_cells / dirty_ratio / path 缓存到
# _last_sea_ice_atlas_upload_breakdown。main.gd fast tick WARN 详细日志通过
# sus_sea_ice_atlas_breakdown() 取来打印，定位 232ms 异常 slice 的真实瓶颈。
func record_sea_ice_atlas_upload(report: Dictionary) -> void:
	_last_sea_ice_atlas_upload_breakdown = report.duplicate()
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_last_sea_ice_atlas_upload_breakdown["_tick_idx"] = _current_fast_tick_idx


func sus_sea_ice_atlas_breakdown() -> Dictionary:
	return _last_sea_ice_atlas_upload_breakdown.duplicate()


func sus_dynamic_visual_atlas_breakdown() -> Dictionary:
	if _dynamic_visual_atlas_upload_job != null \
			and _dynamic_visual_atlas_upload_job.has_method("last_breakdown"):
		return _dynamic_visual_atlas_upload_job.last_breakdown()
	return {}


func _mark_enum_atlas_dirty(cover_dirty: bool, vegetation_dirty: bool, biome_dirty: bool = false) -> void:
	_enum_atlas_biome_dirty = _enum_atlas_biome_dirty or biome_dirty
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
	# X2-精简版：round 启动重置 SoA-slots 缓存标志位，让第一个 stage helper 自然触发
	# 唯一一次 refresh_slots_from_map（后续 11 个 stage 共享该次同步）。
	_season_round_slots_fresh = false
	_season_round_slots_skip_count = 0
	_season_round_slots_refresh_count = 0
	return _pending_season_idx


# Periodic-driver entry（慢变量周期重算）。SeasonRefreshJob 在新路径下不再依赖
# queue_season_refresh / has_pending_season_refresh 信号；按真实 tick 周期自驱
# 调用本入口启动一个 round。返回当前 WorldClock 的 season_index（仅供 stage 算
# 法 API 兼容；新设计下 stage 1/4/5/6/7/8 等慢变量本身不再绑定到具体季节）。
func begin_periodic_season_refresh() -> int:
	_season_refresh_in_progress = true
	_last_season_refresh_breakdown = {}
	# X2-精简版：同上，重置 round 内 slots 缓存标志位。
	_season_round_slots_fresh = false
	_season_round_slots_skip_count = 0
	_season_round_slots_refresh_count = 0
	var season_idx: int = 0
	if _world_clock_ref != null and _world_clock_ref.has_method("season_index"):
		season_idx = int(_world_clock_ref.season_index())
	_pending_season_idx = clampi(season_idx, 0, 3)
	return _pending_season_idx


func run_season_refresh_stage(map: MapData, world: WorldData, season_idx: int, stage: int) -> void:
	# 12-stage 切片（原 7-stage），把 stage 4 的 4 个生态 pass 与 stage 6 的
	# rebake_biome + consume_feedback 各自独立成 stage。每个 stage 的单帧上界
	# 从原来 ~140ms 降到 ~30ms 量级。SeasonRefreshJob 的 done 判定按 12 同步。
	#   0: moisture set
	#   1: rain_shadow
	#   2: redecide_terrain
	#   3: river_ecology
	#   4: vegetation_feedback
	#   5: shrubland_pass
	#   6: mangrove_pass
	#   7: glacier_pass
	#   8: swamp_pass
	#   9: sync_current_state
	#  10: rebake_biome_tex_only
	#  11: consume_feedback_buffers
	var t_us0: int = Time.get_ticks_usec()
	var season := clampi(season_idx, 0, 3)
	if stage >= 0 and stage <= 8:
		_last_world = world
		_current_season = season
		_last_season_refresh_breakdown["stage_%d_ms" % stage] = 0.0
		_last_season_refresh_breakdown["stage_%d_path" % stage] = "emergent_noop"
		return
	# DOTS-Total-CPP 真·收尾（2026-05-21）：第一次进入 run_season_refresh_stage 时打一条
	# 启动 banner，让 rebuild 后立刻能看到 ext 引用 / has_method 的真实状态——
	# 这是验证 8 stage 是否能走 gdext 路径的最快诊断。
	# dots-flag-prune-pr1 round 2: use_gdext_season_refresh flag 已删除，banner
	# 只报告 ext + has_method。
	if not _season_stage_path_logged.has("__startup_banner"):
		_season_stage_path_logged["__startup_banner"] = true
		var ext_v: String = "null" if _data_core_world_ext == null else "ok"
		var method_v: String = "n/a"
		if _data_core_world_ext != null:
			method_v = str(_data_core_world_ext.has_method("run_season_refresh_stage"))
		print("[season_refresh] startup banner: ext=%s has_run_season_refresh_stage=%s"
				% [ext_v, method_v])
	# dots-total-cpp（2026-06-18）：stage 0–8 已在上方（season<=8）early-return 走
	# emergent_noop / B+ C++ round 路径，原本的 GDScript fallback 分支为死代码，已随
	# 生成 GDScript 删除一并清理。此 match 只剩可达的 9 / 10 / 11。
	match stage:
		9:
			if not _run_season_refresh_stage8_gdext(map, world, season):
				_seasonal_sync_current_state(map, season)
				_season_round_slots_fresh = false  # X2: GDScript 改 landform/vegetation/cover
		10:
			# stage 10 is a render/upload concern. Queue it instead of blocking
			# the season simulation slice with a full biome atlas rebuild.
			_mark_enum_atlas_dirty(true, true, true)
		11:
			var cp_fb := _c()
			if cp_fb != null and bool(cp_fb.fast_slow_layering_enabled):
				# stage 11 (feedback decay)：优先走 C++ stage 10（已在 world_ext.cpp
				# line 6814 实装，含 AVX2 + restrict 指针），未启用/失败则 fallback
				# 到 _consume_feedback_buffers GDScript 实现。
				# 注：soil_moisture / vegetation_growth_pressure 现已在 SoA schema
				# （component_schema.gd L109-110），facade getter 自动从 SoA 读取，
				# 因此 in/out 走 map.soil_moisture_arr / vegetation_growth_pressure_arr
				# PackedArray 引用零拷贝传递。
				if not _run_season_refresh_stage11_gdext(map, world, season):
					_consume_feedback_buffers(map, cp_fb.feedback_decay)
					_season_round_slots_fresh = false  # X2
	var elapsed_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	_last_season_refresh_breakdown["stage_%d_ms" % stage] = elapsed_ms
	# H 诊断：单 stage > 30ms → 直接打点，定位 season_refresh max=128-141ms 的根因 stage。
	if elapsed_ms > 30.0:
		print("  [season_refresh] stage=%d slow=%.1fms (season=%d)" % [stage, elapsed_ms, season])


func run_season_refresh_stage_micro(map: MapData, _world: WorldData, season_idx: int, stage: int, cursor: int) -> Dictionary:
	var out: Dictionary = {
		"handled": false,
		"done": false,
		"cursor": cursor,
		"elapsed_ms": 0.0,
		"work_done": 0,
		"stage_name": "",
	}
	var cp := _c()
	if cp == null:
		return out
	var max_usec: int = 550
	if cp.get("sim_slice_budget_ms") != null:
		max_usec = maxi(50, int(round(float(cp.sim_slice_budget_ms) * 1000.0)))
	max_usec = clampi(max_usec, 50, 1000)

	# plan/season-stage4-chunking（2026-05-21）：stage_4_veg_feedback chunk 化。
	# 内部 deadline 必须有 hard cap，否则资源调试预算会把 stage_4 退化为一次跑完 n*3 cell-iter。
	# spike 到 15ms。stage_4 是 11 stage 中最重的（_vegetation_donor_amount × 6 邻居
	# + Vector3i 哈希 + redecide 三段），单 stage 用 ~12ms 时实测会顶到 max_tick。
	const STAGE2_MAX_USEC: int = 1000
	const STAGE3_MAX_USEC: int = 1000
	const STAGE4_MAX_USEC: int = 1000
	if stage == 2:
		var stage2_usec: int = mini(max_usec, STAGE2_MAX_USEC)
		return _run_season_stage2_micro(map, season_idx, cursor, stage2_usec)
	if stage == 3:
		var stage3_usec: int = mini(max_usec, STAGE3_MAX_USEC)
		return _run_season_stage3_micro(map, season_idx, cursor, stage3_usec)
	if stage == 4:
		var stage4_usec: int = mini(max_usec, STAGE4_MAX_USEC)
		return _run_season_stage4_micro(map, season_idx, cursor, stage4_usec)

	if stage != 1:
		return out
	# DOTS-Total-CPP（2026-05-21 真·收尾）：micro-pass 路径补 once-log。
	# 主 switch 的 _run_season_refresh_stage1_gdext 有完整 _season_log_path_once，
	# 但 micro-pass 这条独立路径之前完全静默 → 日志里看不到 stage 1 走哪条。
	# 这里沿用同 helper，stage_key 用 "stage1_micro" 区分主 switch 的 "stage1"。
	# dots-flag-prune-pr1 round 2: use_gdext_season_refresh flag 已删除——恒走 ext +
	# has_method 探测分支。
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_micro_pass"):
		_season_log_path_once("stage1_micro", "gdscript_fallback", "ext/method/map/cfg unavailable (no run_season_refresh_micro_pass)")
		return out
	if not map.has_indices():
		_season_log_path_once("stage1_micro", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return out

	if cursor <= 0:
		_ensure_season_round_slots_fresh()

	var knobs: Dictionary = {
		"stage": stage,
		"cursor": maxi(0, cursor),
		"season": clampi(season_idx, 0, 3),
		"n_cells": map.cell_count(),
		"max_usec": max_usec,
		"neighbor_indices": map.neighbor_indices_packed(),
		"rain_shadow_lookback": int(cp.rain_shadow_lookback),
		"rain_shadow_threshold": float(cp.rain_shadow_threshold),
		"rain_shadow_factor": float(cp.rain_shadow_factor),
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_micro_pass(knobs)
	if bool(res.get("fallback", true)):
		if cursor <= 0:
			_season_log_path_once("stage1_micro", "gdscript_fallback", "C++ returned fallback at cursor=0: %s" % str(res.get("reason", "unknown")))
			return out
		# mid-stage fallback：C++ 已经处理了一部分 cursor 但中途放弃；
		# 调用方需要继续走 micro 路径，但本帧没新进度 → handled=true done=false。
		_season_log_path_once("stage1_micro", "gdext_mid_fallback", "C++ mid-stage fallback cursor=%d: %s" % [cursor, str(res.get("reason", "unknown"))])
		push_warning("[season_refresh] micro-pass fallback mid-stage: %s" % str(res.get("reason", "")))
		out["handled"] = true
		out["done"] = false
		return out

	var elapsed_ms: float = float(res.get("elapsed_ms", 0.0))
	var next_cursor: int = int(res.get("cursor", cursor))
	var done: bool = bool(res.get("done", false))
	var stage_name: String = str(res.get("stage_name", "stage_%d" % stage))
	_last_season_refresh_breakdown["stage_%d_path" % stage] = "gdext_micro"
	_last_season_refresh_breakdown["stage_%d_native_ms" % stage] = elapsed_ms
	_last_season_refresh_breakdown["stage_%d_ms" % stage] = elapsed_ms
	_last_season_refresh_breakdown["stage_%d_cursor" % stage] = next_cursor
	# 成功路径 once-log：done=true 时只打一次，未完成时不刷屏（detail 含 done 状态做 dedup key）。
	if done:
		_season_log_path_once("stage1_micro", "gdext", "native_ms=%.3f done=true cursor=%d" % [elapsed_ms, next_cursor])
	else:
		_season_log_path_once("stage1_micro", "gdext", "native_ms=%.3f done=false (chunking)" % elapsed_ms)
	out["handled"] = true
	out["done"] = done
	out["cursor"] = next_cursor
	out["elapsed_ms"] = elapsed_ms
	out["work_done"] = int(res.get("touched", 0))
	out["stage_name"] = stage_name
	return out


func _run_season_stage2_micro(map: MapData, season_idx: int, cursor: int, max_usec: int) -> Dictionary:
	var out: Dictionary = {
		"handled": true,
		"done": false,
		"cursor": maxi(0, cursor),
		"elapsed_ms": 0.0,
		"work_done": 0,
		"stage_name": "stage_2_redecide",
	}
	if map == null or _last_cfg == null:
		out["done"] = true
		return out
	var cfg_local: MapConfig = _last_cfg
	var season: int = clampi(season_idx, 0, 3)
	# DOTS-Total-CPP（2026-05-21 真·收尾 / 方案 A）：cursor=0 时先 try C++ 一帧跑完。
	# 成功 → 直接 done=true 返回（绕过 GDScript chunk）；失败 → fallback 走下方 chunk 不变。
	# 见 plan.md「实施策略 / stage 2」与 _run_season_refresh_stage2_gdext (line ~2587)。
	# helper 的 world 参数标记为 _world（unused），传 null 安全。
	if cursor == 0:
		var t_try0: int = Time.get_ticks_usec()
		if _run_season_refresh_stage2_gdext(map, null, season):
			var elapsed_try: float = (Time.get_ticks_usec() - t_try0) / 1000.0
			var n_total: int = map.cell_count() if map.has_indices() else map.all_cells().size()
			out["done"] = true
			out["cursor"] = n_total
			out["elapsed_ms"] = elapsed_try
			out["work_done"] = n_total
			# breakdown 由 _run_season_refresh_stage2_gdext 内部已写 stage_2_path=gdext / stage_2_native_ms；
			# 这里补 _ms（wall-clock 含 helper 开销）与 cursor 保持口径一致。
			_last_season_refresh_breakdown["stage_2_ms"] = elapsed_try
			_last_season_refresh_breakdown["stage_2_cursor"] = n_total
			return out
		# C++ 走不通（flag off / ext 缺失 / size mismatch / C++ fallback），
		# helper 内部已 _season_log_path_once，这里静默落 chunk。
	_ensure_row_tables(cfg_local, season)
	var lat_tab: PackedFloat32Array = _row_lat_temp
	var off_tab: PackedFloat32Array = _row_season_off
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n: int = cells.size()
	if n <= 0:
		out["done"] = true
		return out
	var t0: int = Time.get_ticks_usec()
	var cur: int = clampi(cursor, 0, n)
	var touched: int = 0
	while cur < n:
		var cell: HexCell = cells[cur]
		if cell != null:
			if _is_water(cell.terrain):
				# 修复旧运行态：若当前被灌成水，但 base 是生成期确认的陆地，回退到 base。
				if not _is_water(cell.base_terrain):
					_set_cell_runtime_terrain(map, cell, cell.base_terrain, true)
			else:
				# 2026-05-18 季节性高山雪：lock-in 仅锁 base_terrain==SNOW（极地/最高峰），
				# MOUNTAIN 解放给 _decide_terrain 决策，让中纬高山冬天 temp_now<0.08 翻
				# COLD_SNOW、夏天回 MOUNTAIN。注意 apply_terrain 不写 base_terrain，
				# 所以 base 永远是 MOUNTAIN，不会被翻雪后污染（见 hex_cell.gd:812）。
				var is_permanent_climate := cell.base_terrain == TerrainType.TERRAIN.SNOW
				if is_permanent_climate or _is_permanent_landform(cell.base_terrain):
					_set_cell_runtime_terrain(map, cell, cell.base_terrain, true)
				else:
					var r_idx: int = _cube_to_row(cell, cfg_local)
					var lat_temp: float = lat_tab[r_idx]
					var temp_year: float = clampf(lat_temp - _alt_penalty(cell.elevation), 0.0, 1.0)
					var temp_now: float = clampf(temp_year + off_tab[r_idx], 0.0, 1.0)
					var new_terrain := _decide_terrain(cell.elevation, temp_now, cell.moisture, cfg_local)
					# 生成期排干/回填的内陆低洼地原始 elevation 仍可能低于 sea_level；
					# 季节重判不得把这类陆地重新灌回 COAST/OCEAN。
					if _is_water(new_terrain) and not _is_water(cell.terrain):
						new_terrain = cell.base_terrain if not _is_water(cell.base_terrain) else cell.terrain
					_set_cell_runtime_terrain(map, cell, new_terrain, true, temp_now, cell.snow_cover)
		cur += 1
		touched += 1
		if (touched & 7) == 0 and Time.get_ticks_usec() - t0 >= max_usec:
			break
	var elapsed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	out["cursor"] = cur
	out["done"] = cur >= n
	out["elapsed_ms"] = elapsed_ms
	out["work_done"] = touched
	_last_season_refresh_breakdown["stage_2_path"] = "gdscript_micro"
	_last_season_refresh_breakdown["stage_2_ms"] = elapsed_ms
	_last_season_refresh_breakdown["stage_2_cursor"] = cur
	_season_round_slots_fresh = false  # X2: chunk path apply_terrain 改 cell.terrain
	return out


func _run_season_stage3_micro(map: MapData, season_idx: int, cursor: int, max_usec: int) -> Dictionary:
	# stage_3_river_ecology 切片版（2026-05-18）。原 _apply_river_ecology 单 pass
	# 整跑 ~1ms / round，是 fast tick budget 最大固定开销之一（每 30 ticks 一次）。
	# 算法上每个 cell 独立处理（仅 has_river / terrain / moisture / apply_terrain），
	# 无跨 cell 依赖，可安全切片到 cursor。语义与 _apply_river_ecology 完全一致。
	var out: Dictionary = {
		"handled": true,
		"done": false,
		"cursor": maxi(0, cursor),
		"elapsed_ms": 0.0,
		"work_done": 0,
		"stage_name": "stage_3_river",
	}
	if map == null or _last_cfg == null:
		out["done"] = true
		return out
	var cfg_local: MapConfig = _last_cfg
	var _season := clampi(season_idx, 0, 3)
	# DOTS-Total-CPP（2026-05-21 真·收尾 / 方案 A）：cursor=0 时先 try C++ 一帧跑完。
	# 见 _run_season_refresh_stage3_gdext (line ~2670)。river_ecology 无跨 cell 依赖，
	# C++ 一帧跑完 ~0.1ms 远低于 chunk 的 ~1ms。
	if cursor == 0:
		var t_try0: int = Time.get_ticks_usec()
		if _run_season_refresh_stage3_gdext(map, null, _season):
			var elapsed_try: float = (Time.get_ticks_usec() - t_try0) / 1000.0
			var n_total: int = map.cell_count() if map.has_indices() else map.all_cells().size()
			out["done"] = true
			out["cursor"] = n_total
			out["elapsed_ms"] = elapsed_try
			out["work_done"] = n_total
			_last_season_refresh_breakdown["stage_3_ms"] = elapsed_try
			_last_season_refresh_breakdown["stage_3_cursor"] = n_total
			return out
	# season 此处仅作占位防 unused-warning；river 决策实际只看年均温
	# （_compute_temperature(ny, elev)），不带季节 offset，与 _apply_river_ecology 等价。
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n: int = cells.size()
	if n <= 0:
		out["done"] = true
		return out
	var t0: int = Time.get_ticks_usec()
	var cur: int = clampi(cursor, 0, n)
	var work_done: int = 0
	while cur < n:
		var cell: HexCell = cells[cur]
		if cell != null and cell.has_river and not _is_water(cell.terrain):
			if _is_permanent_landform(cell.terrain):
				cell.moisture = maxf(cell.moisture, 0.65)
			else:
				cell.moisture = maxf(cell.moisture, 0.65)
				if cell.terrain != TerrainType.TERRAIN.DESERT:
					if cell.terrain == TerrainType.TERRAIN.PLAIN:
						var ny: float = float(_cube_to_row(cell, cfg_local)) / float(cfg_local.height - 1)
						var temp: float = _compute_temperature(ny, cell.elevation)
						if temp > 0.55:
							_set_cell_runtime_terrain(map, cell, TerrainType.TERRAIN.FOREST, true, temp, cell.snow_cover)
						elif temp > 0.30:
							_set_cell_runtime_terrain(map, cell, TerrainType.TERRAIN.GRASSLAND, true, temp, cell.snow_cover)
		cur += 1
		work_done += 1
		if (work_done & 31) == 0 and Time.get_ticks_usec() - t0 >= max_usec:
			break
	var elapsed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	out["cursor"] = cur
	out["done"] = cur >= n
	out["elapsed_ms"] = elapsed_ms
	out["work_done"] = work_done
	_last_season_refresh_breakdown["stage_3_path"] = "gdscript_micro"
	_last_season_refresh_breakdown["stage_3_ms"] = elapsed_ms
	_last_season_refresh_breakdown["stage_3_cursor"] = cur
	_season_round_slots_fresh = false  # X2: chunk path 改 cell.terrain (river ecology)
	return out


func _run_season_stage4_micro(map: MapData, season_idx: int, cursor: int, max_usec: int) -> Dictionary:
	var out: Dictionary = {
		"handled": true,
		"done": false,
		"cursor": maxi(0, cursor),
		"elapsed_ms": 0.0,
		"work_done": 0,
		"stage_name": "stage_4_veg_feedback",
	}
	if map == null or _last_cfg == null:
		out["done"] = true
		return out
	var t_us0: int = Time.get_ticks_usec()
	# DOTS-Total-CPP（2026-05-21 真·收尾 / 方案 A）：cursor=0 时先 try C++ 一帧跑完。
	# 见 _run_season_refresh_stage4_gdext (line ~2709)。stage 4 是 fast_ms p95 最大元凶
	# （chunk 路径 ~3ms × 4 帧 = ~12ms 总）。C++ 一帧跑完预计 ~0.8-1.5ms。
	# 注意 stage 4 的 cursor 上限是 n*3（3-pass：donor / apply / redecide），
	# C++ 内部已合并 3-pass，done 时 cursor 必须设到 n*3 以匹配 chunk 路径口径。
	var season4: int = clampi(season_idx, 0, 3)
	if cursor == 0:
		var t_try0: int = Time.get_ticks_usec()
		if _run_season_refresh_stage4_gdext(map, null, season4):
			var elapsed_try: float = (Time.get_ticks_usec() - t_try0) / 1000.0
			var n_total: int = map.cell_count() if map.has_indices() else map.all_cells().size()
			var cursor_done: int = n_total * 3
			out["done"] = true
			out["cursor"] = cursor_done
			out["elapsed_ms"] = elapsed_try
			out["work_done"] = cursor_done
			_last_season_refresh_breakdown["stage_4_ms"] = elapsed_try
			_last_season_refresh_breakdown["stage_4_cursor"] = cursor_done
			return out
	# 性能修复（2026-05-18）：与 stage_3/stage_11 同因——iter_cells() 零复制，all_cells() 复制 2400 项。
	# stage_4 在 fast-tick 内每天调用，且本函数在 micro 框架内被多次重入（每次拿一段 cursor），
	# 累计 array 复制成本可观。优先用索引化路径。
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n: int = cells.size()
	if n <= 0:
		out["done"] = true
		return out
	var cur: int = clampi(cursor, 0, n * 3)
	if cur == 0:
		_season_stage4_deltas.clear()
	var work_done: int = 0
	var elev_decay: float = _c().veg_feedback_elev_decay
	var phase3_tables_ready: bool = false
	if cur >= n * 2:
		_ensure_row_tables(_last_cfg, clampi(_current_season, 0, 3))
		phase3_tables_ready = true

	while cur < n * 3:
		if cur < n:
			var cell: HexCell = cells[cur]
			if cell != null:
				var donor: float = _vegetation_donor_amount(int(cell.terrain))
				if donor != 0.0:
					var elev_factor: float = clampf(1.0 - cell.elevation * elev_decay, 0.1, 1.0)
					var donor_eff: float = donor * elev_factor
					for nb: HexCell in map.get_neighbors(cell):
						if _is_water(nb.terrain):
							continue
						var k := Vector3i(nb.q, nb.r, nb.s)
						_season_stage4_deltas[k] = float(_season_stage4_deltas.get(k, 0.0)) + donor_eff
		elif cur < n * 2:
			var apply_idx: int = cur - n
			var cell_apply: HexCell = cells[apply_idx]
			if cell_apply != null and not _is_water(cell_apply.terrain):
				var k_apply := Vector3i(cell_apply.q, cell_apply.r, cell_apply.s)
				if _season_stage4_deltas.has(k_apply):
					var d: float = float(_season_stage4_deltas[k_apply])
					cell_apply.moisture = clampf(cell_apply.moisture + d, 0.0, 1.0)
		else:
			if not phase3_tables_ready:
				_ensure_row_tables(_last_cfg, clampi(_current_season, 0, 3))
				phase3_tables_ready = true
			var redecide_idx: int = cur - n * 2
			var cell_re: HexCell = cells[redecide_idx]
			if cell_re != null and not _is_water(cell_re.terrain):
				if cell_re.terrain != TerrainType.TERRAIN.MOUNTAIN \
						and cell_re.terrain != TerrainType.TERRAIN.SNOW \
						and not _is_permanent_landform(cell_re.terrain):
					var r_idx: int = _cube_to_row(cell_re, _last_cfg)
					var lat_temp: float = _row_lat_temp[r_idx]
					var temp: float = clampf(lat_temp - _alt_penalty(cell_re.elevation), 0.0, 1.0)
					var new_terrain := _decide_terrain(cell_re.elevation, temp, cell_re.moisture, _last_cfg)
					if _is_water(new_terrain) and not _is_water(cell_re.terrain):
						new_terrain = cell_re.base_terrain if not _is_water(cell_re.base_terrain) else cell_re.terrain
					_set_cell_runtime_terrain(map, cell_re, new_terrain, true, temp, cell_re.snow_cover)

		cur += 1
		work_done += 1
		if (work_done & 7) == 0 and Time.get_ticks_usec() - t_us0 >= max_usec:
			break

	var done: bool = cur >= n * 3
	if done:
		_season_stage4_deltas.clear()
	var elapsed_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	_last_season_refresh_breakdown["stage_4_path"] = "gdscript_micro"
	_last_season_refresh_breakdown["stage_4_ms"] = elapsed_ms
	_last_season_refresh_breakdown["stage_4_cursor"] = cur
	_season_round_slots_fresh = false  # X2: chunk path 改 base_moisture / cover / vegetation
	out["done"] = done
	out["cursor"] = cur
	out["elapsed_ms"] = elapsed_ms
	out["work_done"] = work_done
	return out


func finish_season_refresh(_map: MapData, _world: WorldData, _season_idx: int) -> void:
	_season_refresh_in_progress = false
	if _map != null and _map.has_method("sync_runtime_terrain_facade_from_soa"):
		var terrain_facade_fixed: int = int(_map.sync_runtime_terrain_facade_from_soa())
		_last_season_refresh_breakdown["terrain_facade_fixed"] = terrain_facade_fixed
		if terrain_facade_fixed > 0:
			_season_log_path_once("finish", "soa_to_facade_sync", "terrain_fixed=%d" % terrain_facade_fixed)
	if _map != null:
		var enum_axes_written: int = _write_runtime_enum_axes_dense(_map)
		_last_season_refresh_breakdown["runtime_enum_axes_dense_written"] = enum_axes_written
	# X2-精简版（2026-05-21）：once-log round 的 slots refresh / skip 计数。
	# 期望全 gdext 路径下：refresh=1, skip=11（同 round 12 个 stage helper 共享一次 refresh）。
	# 若 refresh 大于 1 → 说明 round 内某 stage 走了 GDScript fallback 改 cell，触发自动补刷
	# （这是设计行为；A/B 验证时若发现 refresh>1 但语义无误则属正常）。
	# 把统计写入 breakdown，方便 perf overlay / sus_season_refresh_breakdown 查询。
	_last_season_refresh_breakdown["slots_refresh_count"] = _season_round_slots_refresh_count
	_last_season_refresh_breakdown["slots_skip_count"] = _season_round_slots_skip_count
	if not _season_stage_path_logged.has("__x2_slots_round_first"):
		_season_stage_path_logged["__x2_slots_round_first"] = true
		print("[season_refresh] x2 slots: refresh=%d skip=%d (期望 refresh=1 skip=11 全 gdext 路径)"
				% [_season_round_slots_refresh_count, _season_round_slots_skip_count])
	# 重置标志位让下一 round 重新走"首 stage 触发 refresh"流程。
	_season_round_slots_fresh = false
	_season_round_slots_skip_count = 0
	_season_round_slots_refresh_count = 0


func sus_season_refresh_breakdown() -> Dictionary:
	return _last_season_refresh_breakdown.duplicate()


# DOTS-Total-CPP 真·收尾（2026-05-21）：per-stage path once-log。
# 每个 stage_key（如 "stage1"）在同一会话内最多打印一次自己的"路径来源"，
# 让 rebuild 后 run 一次就能在控制台看到 8 个 stage 各自走的是 gdext / 哪条 fallback。
# stage_key:  stage 标识，例如 "stage1" / "stage_swamp" / "stage0"
# path:       "gdext"（成功）/ "gdscript_fallback"（GDScript 兜底）
# detail:     reason / native_ms / 哪个 gate 拦下
func _season_log_path_once(stage_key: String, path: String, detail: String) -> void:
	# 同一 stage 同一 path 同一 detail 才算 dedup；path 切换（fallback→gdext）要重打。
	var k: String = "%s|%s|%s" % [stage_key, path, detail]
	if _season_stage_path_logged.has(k):
		return
	_season_stage_path_logged[k] = true
	print("[season_refresh] %s path=%s %s" % [stage_key, path, detail])


# X2-精简版（2026-05-21）：round 内 SoA-slots 同步守门员。
# 调用模式：每个 stage helper 进入时调本函数（替换原 if has_method+refresh_slots_from_map）。
# 行为：
#   - 若 _season_round_slots_fresh == true（同 round 已 refresh 过，且中间无 fallback 改 cell）
#     → 跳过 refresh_slots_from_map，省 ~14μs Variant get-loop。
#   - 若 false（首次 / 上一 stage 走 GDScript fallback 改 cell 后置 false）
#     → 调一次 refresh_slots_from_map，置 true。
# 注意：本 helper 仅用于 season_refresh round 内的 11 处 stage helper（含 micro-pass）。
# climate_pass_a / daily ECS 路径不在 round 内，**不要**改用本 helper。
func _ensure_season_round_slots_fresh() -> void:
	if _data_core_world_ext == null:
		return
	if not _data_core_world_ext.has_method("refresh_slots_from_map"):
		return
	if _season_round_slots_fresh:
		_season_round_slots_skip_count += 1
		return
	_data_core_world_ext.refresh_slots_from_map()
	_season_round_slots_fresh = true
	_season_round_slots_refresh_count += 1


# refresh-consolidation-2026-06：climate daily round 内 SoA-slots 同步守门员。
# 见 _climate_daily_round_slots_fresh 注释。每个 climate sub-pass 入口调本函数
# 替换原 refresh_slots_from_map()。守门员逻辑与 season 版完全对称。
func _ensure_climate_daily_round_slots_fresh() -> void:
	if _data_core_world_ext == null:
		return
	if not _data_core_world_ext.has_method("refresh_slots_from_map"):
		return
	if _climate_daily_round_slots_fresh:
		_climate_daily_round_slots_skip_count += 1
		return
	_data_core_world_ext.refresh_slots_from_map()
	_climate_daily_round_slots_fresh = true
	_climate_daily_round_slots_refresh_count += 1


# 跨 pass 边界 / fallback 写 cell / round 末尾时调用，让下一次
# _ensure_climate_daily_round_slots_fresh() 重新跑 refresh_slots_from_map()。
func _mark_climate_daily_round_slots_stale() -> void:
	_climate_daily_round_slots_fresh = false


# Soak 验收用：把 round 内 refresh/skip 计数打印出来。climate_daily_system 在
# round 末尾调一次，便于核对 "原本 N 次 refresh → 现在 M 次" 的优化幅度。
func dump_climate_daily_round_slots_stats() -> Dictionary:
	var out: Dictionary = {
		"refresh_count": _climate_daily_round_slots_refresh_count,
		"skip_count": _climate_daily_round_slots_skip_count,
	}
	_climate_daily_round_slots_refresh_count = 0
	_climate_daily_round_slots_skip_count = 0
	return out

func _run_season_refresh_stage8_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp := _c()
	# dots-flag-prune-pr1 round 2: use_gdext_season_refresh flag 已删除——恒走
	# ext + has_method 探测分支。cp 仅作为后续字段读取检查。
	if cp == null:
		_season_log_path_once("stage8", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage8", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(self)
	_ensure_row_tables(_last_cfg, season)
	_ensure_season_round_slots_fresh()
	var knobs: Dictionary = {
		"stage": 8,
		"season": season,
		"n_cells": map.cell_count(),
		"height": _last_cfg.height,
		"sea_level": _last_cfg.sea_level,
		"season_offset_rows": _row_season_off,
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage8", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["stage_8_path"] = "gdext"
	_last_season_refresh_breakdown["stage_8_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage8", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# DOTS-Total-CPP / Continuous-Climate-Push（2026-05-18）：stage 11 (feedback
# decay) gdext 路径。与 stage 0 / stage 8 helper 同模式：cp.use_gdext_season_refresh
# 总开关 + ext/method 存在性检查；未满足走 GDScript fallback。
# 替换原 _consume_feedback_buffers (line ~4080) 的 ~6ms/round 开销。
func _run_season_refresh_stage11_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	# Stage 11 (feedback decay) → C++ stage 10：
	# - 输入：soil_moisture_arr / vegetation_growth_pressure_arr（PackedArray 引用）+
	#   n_cells + decay
	# - 输出：base_moisture 由 C++ 端 _flush_slot_to_map 直接写 SoA；
	#   soil_moisture / veg_growth_pressure 通过 knobs in/out 返回 decayed array，
	#   facade getter 自动从 SoA 拿新值（hex_cell.gd L668-697）。
	# - 数值漂移：clamp / decay / FEEDBACK_SOIL_TO_BASE_W=0.15 与 GDScript
	#   _consume_feedback_buffers 完全一致（world_ext.cpp L6843 确认）。
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage11", "gdscript_fallback", "cp null")
		return false
	if map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage11", "gdscript_fallback", "ext/method/map unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage11", "gdscript_fallback", "n_cells<=0")
		return false
	# 取 map.xxx_arr 引用；run_climate_feedback_pass 已经维护这两个 array
	# 与 cell facade 的同步（line 6996-7002）。
	var soil_arr: PackedFloat32Array = map.soil_moisture_arr
	var vg_arr: PackedFloat32Array = map.vegetation_growth_pressure_arr
	if soil_arr.size() != n_cells or vg_arr.size() != n_cells:
		_season_log_path_once("stage11", "gdscript_fallback", "soil/vg arr size mismatch n_cells=%d soil=%d vg=%d" % [n_cells, soil_arr.size(), vg_arr.size()])
		return false
	# 让 C++ 端 SoA 看到最新 base_moisture（stage_8 之前可能已经写过 cell.base_moisture
	# 而未 flush 回 _slots）。
	_ensure_season_round_slots_fresh()
	var knobs: Dictionary = {
		"stage": 10,
		"n_cells": n_cells,
		"decay": float(cp.feedback_decay),
		"soil_moisture_arr": soil_arr,
		"veg_growth_pressure_arr": vg_arr,
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage11", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	# 写回 in/out arrays。C++ 端通过 knobs["soil_moisture_arr"] = soil_arr;
	# 把 decayed 值写回；这里把更新后的 PackedArray 灌回 map.xxx_arr，
	# facade getter 即可读到新值（与 _climate_feedback_pass 同模式）。
	var soil_out: PackedFloat32Array = knobs.get("soil_moisture_arr", soil_arr)
	var vg_out: PackedFloat32Array = knobs.get("veg_growth_pressure_arr", vg_arr)
	if soil_out.size() == n_cells:
		map.soil_moisture_arr = soil_out
	if vg_out.size() == n_cells:
		map.vegetation_growth_pressure_arr = vg_out
	_last_season_refresh_breakdown["stage_11_path"] = "gdext"
	_last_season_refresh_breakdown["stage_11_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_last_season_refresh_breakdown["stage_11_touched"] = int(res.get("touched", 0))
	_season_log_path_once("stage11", "gdext", "native_ms=%.3f touched=%d" % [float(res.get("elapsed_ms", 0.0)), int(res.get("touched", 0))])
	return true


# DOTS-Total-CPP（任务 2）：stage 0（per-cell moisture set）gdext 路径。
# 与 stage 8 helper 同模式：检查 ClimateProfile flag + ext + method，未满足走 fallback。
# C++ 端写 cell_moisture SoA；feature_flags.use_hexcell_facade=true 让 cell.moisture
# 自动看到最新 SoA 值，不需要 facade sync。
func _run_season_refresh_stage0_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage0", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage0", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	_ensure_season_round_slots_fresh()
	var moist_scale: float = 1.0
	var knobs: Dictionary = {
		"stage": 0,
		"season": season,
		"n_cells": map.cell_count(),
		"moist_scale": moist_scale,
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage0", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_last_season_refresh_breakdown["stage_0_path"] = "gdext"
	_last_season_refresh_breakdown["stage_0_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage0", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# ════════════════════════════════════════════════════════════════════════════
# DOTS-Total-CPP（2026-05-21 真·收尾）：stage 1-9（=swamp）gdext helper。
# 严格沿用 stage 0/8/11 的双轨模板：
#   1. flag (cp.use_gdext_season_refresh) + ext + method gate；
#   2. refresh_slots_from_map() 让 C++ SoA 看到最新 cell 字段；
#   3. 构造 knobs（每 stage 必需字段见 world_ext.cpp run_season_refresh_stage）；
#   4. C++ 写 SoA + facade getter 自动透出（hexcell_facade=true）；
#      多轴变化（terrain/landform/vegetation/cover）需 _sync_stage8_facade_fields_from_soa；
#   5. fallback once-log 防 spam，回 false 让主 switch 调原 GDScript pass。
# ════════════════════════════════════════════════════════════════════════════

# 共用工具：构造 row_indices(PackedInt32Array, size=n_cells)，每 cell 一个 row id。
# 多 stage 共用，避免重复遍历。返回空表表示 cell 不可用。
func _build_row_indices_for_gdext(map: MapData, cfg: MapConfig) -> PackedInt32Array:
	var n: int = map.cell_count()
	var out: PackedInt32Array = PackedInt32Array()
	if n <= 0 or cfg == null:
		return out
	out.resize(n)
	for i in range(n):
		var cell: HexCell = map.cell_at(i)
		if cell == null:
			out[i] = 0
			continue
		out[i] = _cube_to_row(cell, cfg)
	return out


func _set_cell_runtime_terrain(map: MapData, cell: HexCell, terrain_id: int,
		sync_axes: bool = false, temperature_for_vegetation: float = -1.0,
		snow_cover: float = -1.0) -> void:
	if cell == null:
		return
	if map != null and map.has_soa():
		var idx: int = int(cell.index)
		if idx < 0 or idx >= map.cell_count():
			idx = map.index_of(cell)
		if idx >= 0 and idx < map.cell_count():
			map.set_runtime_terrain(idx, terrain_id, true)
			if sync_axes:
				_sync_runtime_axes_after_terrain(map, cell, idx, temperature_for_vegetation, snow_cover)
			return
	cell.apply_terrain(terrain_id)
	if sync_axes:
		_sync_runtime_axes_after_terrain(map, cell, -1, temperature_for_vegetation, snow_cover)


func _sync_runtime_axes_after_terrain(map: MapData, cell: HexCell, idx: int,
		temperature_for_vegetation: float = -1.0, snow_cover: float = -1.0) -> void:
	if cell == null or _last_cfg == null:
		return
	var cfg: MapConfig = _last_cfg
	var landform: int = _derive_landform(cell, cfg)
	var temp_for_veg: float = temperature_for_vegetation
	if temp_for_veg < 0.0:
		temp_for_veg = _compute_temperature(_cube_row_norm(cell, cfg), cell.elevation)
	var cover_snow: float = snow_cover if snow_cover >= 0.0 else cell.snow_cover
	var vegetation: int = _derive_vegetation(cell, landform, temp_for_veg)
	var cover: int = _derive_cover(cell, cover_snow)
	cell.landform = landform
	cell.vegetation = vegetation
	cell.cover = cover
	if cell.current_state != null and not cell.current_state.is_empty():
		cell.current_state["biome"] = int(cell.terrain)
		cell.current_state["landform"] = int(landform)
		cell.current_state["vegetation"] = int(vegetation)
		cell.current_state["cover"] = int(cover)
	if map != null and map.has_soa():
		var safe_idx: int = idx
		if safe_idx < 0 or safe_idx >= map.cell_count():
			safe_idx = int(cell.index)
		if safe_idx < 0 or safe_idx >= map.cell_count():
			safe_idx = map.index_of(cell)
		if safe_idx >= 0 and safe_idx < map.cell_count():
			if safe_idx < map.terrain_arr.size():
				map.terrain_arr[safe_idx] = int(cell.terrain) & 0xFF
			if safe_idx < map.is_water_arr.size():
				map.is_water_arr[safe_idx] = MapData.terrain_is_water_u8(int(cell.terrain))
			if safe_idx < map.landform_arr.size():
				map.landform_arr[safe_idx] = landform & 0xFF
			if safe_idx < map.vegetation_arr.size():
				map.vegetation_arr[safe_idx] = vegetation & 0xFF
			if safe_idx < map.cover_arr.size():
				map.cover_arr[safe_idx] = cover & 0xFF
			if MapData.terrain_is_water_u8(int(cell.terrain)) != 0 or vegetation == VegetationType.VEG.NONE:
				_clear_cell_vegetation_state(map, cell, safe_idx)


func _clear_cell_vegetation_state(map: MapData, cell: HexCell, idx: int = -1) -> void:
	if cell == null:
		return
	cell.vegetation_vitality = 0.0
	cell._vitality_low_streak = 0
	cell._vitality_high_streak = 0
	cell.vegetation_growth_pressure = 0.0
	cell.vegetation_heat_stress = 0.0
	cell.vegetation_drought_stress = 0.0
	cell.vegetation_cold_stress = 0.0
	cell.vegetation_regen_score = 0.0
	if map == null or not map.has_soa():
		return
	var safe_idx: int = idx
	if safe_idx < 0 or safe_idx >= map.cell_count():
		safe_idx = int(cell.index)
	if safe_idx < 0 or safe_idx >= map.cell_count():
		safe_idx = map.index_of(cell)
	if safe_idx < 0 or safe_idx >= map.cell_count():
		return
	if safe_idx < map.vegetation_vitality_arr.size():
		map.vegetation_vitality_arr[safe_idx] = 0.0
	if safe_idx < map.vitality_low_streak_arr.size():
		map.vitality_low_streak_arr[safe_idx] = 0
	if safe_idx < map.vitality_high_streak_arr.size():
		map.vitality_high_streak_arr[safe_idx] = 0
	if safe_idx < map.vegetation_growth_pressure_arr.size():
		map.vegetation_growth_pressure_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_heat_stress_arr.size():
		map.vegetation_heat_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_drought_stress_arr.size():
		map.vegetation_drought_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_cold_stress_arr.size():
		map.vegetation_cold_stress_arr[safe_idx] = 0.0
	if safe_idx < map.vegetation_regen_score_arr.size():
		map.vegetation_regen_score_arr[safe_idx] = 0.0


func _write_runtime_enum_axes_dense(map: MapData) -> int:
	if map == null or _data_core_world == null or not _data_core_world.has_method("write_u8_dense"):
		return 0
	var written: int = 0
	var cid_terrain: int = _data_core_world.component_id(DCComponentIds.CELL_TERRAIN)
	if cid_terrain >= 0:
		_data_core_world.write_u8_dense(cid_terrain, map.terrain_arr)
		written += 1
	var cid_is_water: int = _data_core_world.component_id(DCComponentIds.CELL_IS_WATER)
	if cid_is_water >= 0:
		_data_core_world.write_u8_dense(cid_is_water, map.is_water_arr)
		written += 1
	var cid_landform: int = _data_core_world.component_id(DCComponentIds.CELL_LANDFORM)
	if cid_landform >= 0:
		_data_core_world.write_u8_dense(cid_landform, map.landform_arr)
		written += 1
	var cid_vegetation: int = _data_core_world.component_id(DCComponentIds.CELL_VEGETATION)
	if cid_vegetation >= 0:
		_data_core_world.write_u8_dense(cid_vegetation, map.vegetation_arr)
		written += 1
	var cid_cover: int = _data_core_world.component_id(DCComponentIds.CELL_COVER)
	if cid_cover >= 0:
		_data_core_world.write_u8_dense(cid_cover, map.cover_arr)
		written += 1
	return written


func _world_ext_u8_component_id(gd_name: StringName) -> int:
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("component_id"):
		return -1
	var cid_ext: int = int(_data_core_world_ext.component_id(gd_name))
	if cid_ext < 0:
		cid_ext = int(_data_core_world_ext.component_id(StringName(String(gd_name).replace(".", "_"))))
	return cid_ext


func _apply_sea_ice_terrain_flips_indexed(map: MapData, indices: PackedInt32Array,
		terrain_values: PackedByteArray, sync_cells: bool = true) -> Dictionary:
	var diag: Dictionary = {
		"applied": false,
		"count": 0,
		"fallback_reason": "",
		"dc_written": false,
		"dc_ext_written": false,
	}
	if map == null or not map.has_soa():
		diag["fallback_reason"] = "missing_soa"
		return diag
	var n_values: int = mini(indices.size(), terrain_values.size())
	if n_values <= 0:
		diag["applied"] = true
		return diag
	if map.terrain_arr.size() < map.cell_count() or map.is_water_arr.size() < map.cell_count():
		diag["fallback_reason"] = "bad_map_array_size"
		return diag
	var apply_idx: PackedInt32Array = PackedInt32Array()
	var apply_terrain: PackedByteArray = PackedByteArray()
	var apply_water: PackedByteArray = PackedByteArray()
	apply_idx.resize(n_values)
	apply_terrain.resize(n_values)
	apply_water.resize(n_values)
	var w: int = 0
	for k in range(n_values):
		var idx: int = indices[k]
		if idx < 0 or idx >= map.cell_count():
			continue
		var terrain_byte: int = int(terrain_values[k]) & 0xFF
		var water_byte: int = MapData.terrain_is_water_u8(terrain_byte)
		if int(map.terrain_arr[idx]) == terrain_byte and int(map.is_water_arr[idx]) == water_byte:
			continue
		map.terrain_arr[idx] = terrain_byte
		map.is_water_arr[idx] = water_byte
		if sync_cells:
			var cell: HexCell = map.cell_at(idx)
			if cell != null:
				cell.apply_terrain(terrain_byte)
		if map.has_method("mark_climate_dirty"):
			map.mark_climate_dirty(idx)
		apply_idx[w] = idx
		apply_terrain[w] = terrain_byte
		apply_water[w] = water_byte
		w += 1
	if w <= 0:
		diag["applied"] = true
		return diag
	apply_idx.resize(w)
	apply_terrain.resize(w)
	apply_water.resize(w)
	if _data_core_world != null and _data_core_world.has_method("write_u8_indexed"):
		var cid_terrain: int = _data_core_world.component_id(DCComponentIds.CELL_TERRAIN)
		if cid_terrain >= 0:
			_data_core_world.write_u8_indexed(cid_terrain, apply_idx, apply_terrain)
			diag["dc_written"] = true
		var cid_is_water: int = _data_core_world.component_id(DCComponentIds.CELL_IS_WATER)
		if cid_is_water >= 0:
			_data_core_world.write_u8_indexed(cid_is_water, apply_idx, apply_water)
			diag["dc_written"] = true
	if _data_core_world != null and _data_core_world.has_method("mark_dirty_indexed"):
		_data_core_world.mark_dirty_indexed(apply_idx)
	if _data_core_world_ext != null and _data_core_world_ext.has_method("write_u8_indexed"):
		var cid_terr_ext: int = _world_ext_u8_component_id(DCComponentIds.CELL_TERRAIN)
		if cid_terr_ext >= 0:
			_data_core_world_ext.write_u8_indexed(cid_terr_ext, apply_idx, apply_terrain)
			diag["dc_ext_written"] = true
		var cid_isw_ext: int = _world_ext_u8_component_id(DCComponentIds.CELL_IS_WATER)
		if cid_isw_ext >= 0:
			_data_core_world_ext.write_u8_indexed(cid_isw_ext, apply_idx, apply_water)
			diag["dc_ext_written"] = true
	diag["applied"] = true
	diag["count"] = w
	return diag


func _build_sea_ice_flip_batch(flip_to_ice_list: PackedInt32Array,
		flip_to_base_list: PackedInt32Array, flip_to_base_terrain: PackedByteArray,
		start: int = 0, end: int = -1) -> Dictionary:
	var total: int = flip_to_ice_list.size() + flip_to_base_list.size()
	var first: int = clampi(start, 0, total)
	var last: int = total if end < 0 else clampi(end, first, total)
	var out_idx: PackedInt32Array = PackedInt32Array()
	var out_terrain: PackedByteArray = PackedByteArray()
	out_idx.resize(last - first)
	out_terrain.resize(last - first)
	var sea_ice_id: int = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
	var w: int = 0
	for f in range(first, last):
		if f < flip_to_ice_list.size():
			out_idx[w] = int(flip_to_ice_list[f])
			out_terrain[w] = sea_ice_id
			w += 1
		else:
			var base_i: int = f - flip_to_ice_list.size()
			if base_i < flip_to_base_list.size() and base_i < flip_to_base_terrain.size():
				out_idx[w] = int(flip_to_base_list[base_i])
				out_terrain[w] = int(flip_to_base_terrain[base_i]) & 0xFF
				w += 1
	out_idx.resize(w)
	out_terrain.resize(w)
	return {
		"indices": out_idx,
		"terrain": out_terrain,
	}


# stage 4 用的 donor_table（PackedFloat32Array, size=26, 按 terrain enum 索引）。
# 复刻 _vegetation_donor_amount 的 10 类型 hot 表 + 其余为 0。
func _build_vegetation_donor_table_for_gdext() -> PackedFloat32Array:
	var c := _c()
	var t: PackedFloat32Array = PackedFloat32Array()
	t.resize(26)
	if c == null:
		return t
	t[int(TerrainType.TERRAIN.FOREST)]    = float(c.veg_forest_donor)
	t[int(TerrainType.TERRAIN.SWAMP)]     = float(c.veg_swamp_donor)
	t[int(TerrainType.TERRAIN.GRASSLAND)] = float(c.veg_grassland_donor)
	t[int(TerrainType.TERRAIN.DESERT)]    = float(c.veg_desert_donor)
	t[int(TerrainType.TERRAIN.JUNGLE)]    = float(c.veg_jungle_donor)
	t[int(TerrainType.TERRAIN.TAIGA)]     = float(c.veg_taiga_donor)
	t[int(TerrainType.TERRAIN.SAVANNA)]   = float(c.veg_savanna_donor)
	t[int(TerrainType.TERRAIN.OASIS)]     = float(c.veg_oasis_donor)
	t[int(TerrainType.TERRAIN.DELTA)]     = float(c.veg_delta_donor)
	t[int(TerrainType.TERRAIN.SALT_FLAT)] = float(c.veg_salt_flat_donor)
	return t


# stage 1 用的 jitter_arr（PackedFloat32Array, size=n_cells）。
# 与 _apply_rain_shadow_per_cell line 3158 完全等价：
#   jitter[i] = _height_warp.get_noise_2d(cell.q*8.0, cell.r*8.0) * 0.04
# 让 C++ 端 stage 1 不需要 noise 引擎即可 bit-equal 复刻 WindBelt fallback 路径。
func _build_rain_shadow_jitter_for_gdext(map: MapData) -> PackedFloat32Array:
	var n: int = map.cell_count()
	var out: PackedFloat32Array = PackedFloat32Array()
	if n <= 0 or _height_warp == null:
		return out
	out.resize(n)
	for i in range(n):
		var cell: HexCell = map.cell_at(i)
		if cell == null:
			out[i] = 0.0
			continue
		out[i] = _height_warp.get_noise_2d(float(cell.q) * 8.0, float(cell.r) * 8.0) * 0.04
	return out


# stage 1: rain_shadow_per_cell。
# C++ 等价：cell.wind_vector 优先 + WindBelt fallback（用预烘焙 jitter）+ 6 邻接 lookback。
func _run_season_refresh_stage1_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage1", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage1", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		_season_log_path_once("stage1", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage1", "gdscript_fallback", "n_cells<=0")
		return false
	_ensure_season_round_slots_fresh()
	var jitter_arr: PackedFloat32Array = _build_rain_shadow_jitter_for_gdext(map)
	if jitter_arr.size() != n_cells:
		_season_log_path_once("stage1", "gdscript_fallback", "jitter_arr size mismatch n_cells=%d jitter=%d" % [n_cells, jitter_arr.size()])
		return false
	var knobs: Dictionary = {
		"stage": 1,
		"n_cells": n_cells,
		"rain_shadow_lookback": int(cp.rain_shadow_lookback),
		"rain_shadow_threshold": float(cp.rain_shadow_threshold),
		"rain_shadow_factor": float(cp.rain_shadow_factor),
		"neighbor_indices": map.neighbor_indices_packed(),
		"season_phase": float(season) + 0.5,
		"jitter_arr": jitter_arr,
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage1", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	# moisture 是单轴写入，hexcell_facade=true 自动透出，不需 facade sync。
	_last_season_refresh_breakdown["stage_1_path"] = "gdext"
	_last_season_refresh_breakdown["stage_1_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage1", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 2: seasonal_redecide_terrain。多轴写入（terrain + landform + vegetation + cover），
# 必须在结束后 _sync_stage8_facade_fields_from_soa 同步 facade。
func _run_season_refresh_stage2_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage2", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage2", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage2", "gdscript_fallback", "n_cells<=0")
		return false
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(self)
	_ensure_row_tables(_last_cfg, season)
	if _row_lat_temp.size() < _last_cfg.height or _row_season_off.size() < _last_cfg.height:
		_season_log_path_once("stage2", "gdscript_fallback", "row tables not ready: lat_temp=%d season_off=%d height=%d" % [_row_lat_temp.size(), _row_season_off.size(), int(_last_cfg.height)])
		return false
	_ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _build_row_indices_for_gdext(map, _last_cfg)
	if row_idx.size() != n_cells:
		_season_log_path_once("stage2", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 2,
		"season": season,
		"n_cells": n_cells,
		"height": int(_last_cfg.height),
		"sea_level": float(_last_cfg.sea_level),
		"lat_temp_rows": _row_lat_temp,
		"season_offset_rows": _row_season_off,
		"row_indices": row_idx,
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage2", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["stage_2_path"] = "gdext"
	_last_season_refresh_breakdown["stage_2_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage2", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 3: river_ecology。DESERT 不翻；PLAIN→FOREST/GRASSLAND；has_river+land 强湿。
# 多轴写入需 facade sync。
func _run_season_refresh_stage3_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage3", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage3", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage3", "gdscript_fallback", "n_cells<=0")
		return false
	_ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _build_row_indices_for_gdext(map, _last_cfg)
	if row_idx.size() != n_cells:
		_season_log_path_once("stage3", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 3,
		"n_cells": n_cells,
		"height": int(_last_cfg.height),
		"sea_level": float(_last_cfg.sea_level),
		"row_indices": row_idx,
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage3", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["stage_3_path"] = "gdext"
	_last_season_refresh_breakdown["stage_3_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage3", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 4: vegetation_feedback。3-pass（donor delta 累加 / 应用 / 二次 redecide）。
# 多轴写入 + moisture 写入；需 facade sync。
func _run_season_refresh_stage4_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage4", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage4", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		_season_log_path_once("stage4", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage4", "gdscript_fallback", "n_cells<=0")
		return false
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(self)
	_ensure_row_tables(_last_cfg, season)
	if _row_lat_temp.size() < _last_cfg.height:
		_season_log_path_once("stage4", "gdscript_fallback", "row_lat_temp not ready: size=%d height=%d" % [_row_lat_temp.size(), int(_last_cfg.height)])
		return false
	_ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _build_row_indices_for_gdext(map, _last_cfg)
	if row_idx.size() != n_cells:
		_season_log_path_once("stage4", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var donor_table: PackedFloat32Array = _build_vegetation_donor_table_for_gdext()
	var knobs: Dictionary = {
		"stage": 4,
		"n_cells": n_cells,
		"height": int(_last_cfg.height),
		"sea_level": float(_last_cfg.sea_level),
		"lat_temp_rows": _row_lat_temp,
		"row_indices": row_idx,
		"neighbor_indices": map.neighbor_indices_packed(),
		"donor_table": donor_table,
		"elev_decay": float(cp.veg_feedback_elev_decay),
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage4", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["stage_4_path"] = "gdext"
	_last_season_refresh_breakdown["stage_4_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage4", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 5: shrubland_pass。陆地 + GRASSLAND/STEPPE/SAVANNA/PLAIN + 低海拔 + 暖温 + 中干 + 海邻 → SHRUBLAND.
func _run_season_refresh_stage5_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage5", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage5", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		_season_log_path_once("stage5", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage5", "gdscript_fallback", "n_cells<=0")
		return false
	_ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _build_row_indices_for_gdext(map, _last_cfg)
	if row_idx.size() != n_cells:
		_season_log_path_once("stage5", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 5,
		"n_cells": n_cells,
		"height": int(_last_cfg.height),
		"sea_level": float(_last_cfg.sea_level),
		"row_indices": row_idx,
		"neighbor_indices": map.neighbor_indices_packed(),
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage5", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["stage_5_path"] = "gdext"
	_last_season_refresh_breakdown["stage_5_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage5", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 6: mangrove_pass。陆地 + 非永久 + 极低海拔 + 热带 + COAST 邻接 + (river || SWAMP邻) → MANGROVE.
func _run_season_refresh_stage6_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage6", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage6", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		_season_log_path_once("stage6", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage6", "gdscript_fallback", "n_cells<=0")
		return false
	_ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _build_row_indices_for_gdext(map, _last_cfg)
	if row_idx.size() != n_cells:
		_season_log_path_once("stage6", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 6,
		"n_cells": n_cells,
		"height": int(_last_cfg.height),
		"sea_level": float(_last_cfg.sea_level),
		"row_indices": row_idx,
		"neighbor_indices": map.neighbor_indices_packed(),
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage6", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["stage_6_path"] = "gdext"
	_last_season_refresh_breakdown["stage_6_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage6", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 7: glacier_pass。SNOW/TUNDRA + temp<0.05 + (沿海冰舌 || alpine) → GLACIER.
func _run_season_refresh_stage7_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage7", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage7", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		_season_log_path_once("stage7", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage7", "gdscript_fallback", "n_cells<=0")
		return false
	_ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _build_row_indices_for_gdext(map, _last_cfg)
	if row_idx.size() != n_cells:
		_season_log_path_once("stage7", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 7,
		"n_cells": n_cells,
		"height": int(_last_cfg.height),
		"sea_level": float(_last_cfg.sea_level),
		"row_indices": row_idx,
		"neighbor_indices": map.neighbor_indices_packed(),
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage7", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["stage_7_path"] = "gdext"
	_last_season_refresh_breakdown["stage_7_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage7", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# stage 8 in scheduler == swamp_pass. C++ 端 stage_id=9（避开 stage 8=sync_current_state 的占用）。
# 陆地 + !MOUNTAIN/SNOW/TUNDRA + !permanent + 极低海拔 + 极湿 + 暖温 + (river||water邻) → SWAMP.
func _run_season_refresh_swamp_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	var cp := _c()
	if cp == null:
		_season_log_path_once("stage_swamp", "gdscript_fallback", "cp null")
		return false
	if _last_cfg == null or map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_season_refresh_stage"):
		_season_log_path_once("stage_swamp", "gdscript_fallback", "ext/method/map/cfg unavailable")
		return false
	if not map.has_indices():
		_season_log_path_once("stage_swamp", "gdscript_fallback", "map.has_indices()=false (CSR not baked)")
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		_season_log_path_once("stage_swamp", "gdscript_fallback", "n_cells<=0")
		return false
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(self)
	_ensure_row_tables(_last_cfg, season)
	if _row_lat_temp.size() < _last_cfg.height:
		_season_log_path_once("stage_swamp", "gdscript_fallback", "row_lat_temp not ready: size=%d height=%d" % [_row_lat_temp.size(), int(_last_cfg.height)])
		return false
	_ensure_season_round_slots_fresh()
	var row_idx: PackedInt32Array = _build_row_indices_for_gdext(map, _last_cfg)
	if row_idx.size() != n_cells:
		_season_log_path_once("stage_swamp", "gdscript_fallback", "row_idx size mismatch n_cells=%d row_idx=%d" % [n_cells, row_idx.size()])
		return false
	var knobs: Dictionary = {
		"stage": 9,  # C++ 端 stage_id=9 = swamp（注：与 GDScript scheduler 的 stage 8 对应）
		"n_cells": n_cells,
		"height": int(_last_cfg.height),
		"sea_level": float(_last_cfg.sea_level),
		"lat_temp_rows": _row_lat_temp,
		"row_indices": row_idx,
		"neighbor_indices": map.neighbor_indices_packed(),
	}
	var res: Dictionary = _data_core_world_ext.run_season_refresh_stage(knobs)
	if bool(res.get("fallback", true)) or float(res.get("elapsed_ms", -1.0)) < 0.0:
		_season_log_path_once("stage_swamp", "gdscript_fallback", "C++ returned fallback: %s" % String(res.get("reason", "unknown")))
		return false
	_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["stage_swamp_path"] = "gdext"
	_last_season_refresh_breakdown["stage_swamp_native_ms"] = float(res.get("elapsed_ms", 0.0))
	_season_log_path_once("stage_swamp", "gdext", "native_ms=%.3f" % float(res.get("elapsed_ms", 0.0)))
	return true


# ════════════════════════════════════════════════════════════════════════════
# DOTS-Final-Frontier Phase B+：season refresh full-round single-call wrappers
# ────────────────────────────────────────────────────────────────────────────
# B+ 路径思想：原 12-stage round 每 slice 跨界 1 次（共 12 次）→ B+ 退化为
# 整 round 共 3 次跨界（start / run_slice × N / finish）。每 slice 内由 C++
# 调度器 run_season_round_slice 在 stage 边界（b1）连续推进，到 deadline 退出。
# 算法实现 100% 复用 stage 0..11 已 bit-equal 的 C++ 路径（不引入新算法）。
#
# 与单 stage helper（_run_season_refresh_stageN_gdext）的关系：
#   - 单 stage helper 仍保留为双轨 fallback 与 A/B 等价性基线；
#   - B+ wrapper 在 SUS Job / DCSystem 入口处优先尝试，gate 失败则退到 12-stage
#     scheduler，整体不阻断主线（required = false 直到 1000-tick A/B 通过）。
#
# round_knobs 是 12 stage 各自 knobs 的并集；C++ 端 start_season_round 把它存到
# round_state，每 slice 内部 ::run_season_round_slice 复制一份 + 覆盖 stage 字段
# 后调既有 run_season_refresh_stage 路径，达到 zero-copy / 零算法风险。
#
# facade sync / history push（行为变更，用户已确认）：
#   原路径：stage 2/3/4/5/6/7/swamp 各自调一次 _sync_stage8_facade_fields_from_soa，
#           触发 push_biome_history + push_vegetation_history 累计 ~7 次/round。
#   B+ 路径：仅在 finish_season_round_b_plus 末尾调一次 → 1 次/round。
#           对应"每季度一次状态快照"的产品语义，也消除了 history 环形缓冲被
#           同 round 多次 push 污染的隐性 bug。
# ════════════════════════════════════════════════════════════════════════════

# B+ 路径门禁：dots-flag-prune-pr1 round 2 (2026-05-22)：use_gdext_season_round /
# use_gdext_season_refresh flag 均已删除——现只检查 ext + 4 个新方法（start/run_slice/
# finish/abort）是否齐全。任一不满足返回 false。
# 上层 caller（SUS Job / DCSystem）拿到 false 后回退到 12-stage scheduler。
func season_round_b_plus_available() -> bool:
	if _data_core_world_ext == null:
		return false
	if not _data_core_world_ext.has_method("start_season_round"):
		return false
	if not _data_core_world_ext.has_method("run_season_round_slice"):
		return false
	if not _data_core_world_ext.has_method("finish_season_round"):
		return false
	return true


# 构造 round_knobs：12 stage knobs 的并集。
# 失败（cfg / map / row_table 缺失）返回空 Dictionary，caller 视为 fallback。
func _build_season_round_knobs(map: MapData, season: int) -> Dictionary:
	var cp := _c()
	if cp == null or _last_cfg == null or map == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}
	if not map.has_indices():
		return {}
	if not map.has_lat_lut():
		map.bake_lat_temp_year_lut(self)
	_ensure_row_tables(_last_cfg, season)
	if _row_lat_temp.size() < _last_cfg.height or _row_season_off.size() < _last_cfg.height:
		return {}
	var row_idx: PackedInt32Array = _build_row_indices_for_gdext(map, _last_cfg)
	if row_idx.size() != n_cells:
		return {}
	var jitter_arr: PackedFloat32Array = _build_rain_shadow_jitter_for_gdext(map)
	if jitter_arr.size() != n_cells:
		return {}
	var donor_table: PackedFloat32Array = _build_vegetation_donor_table_for_gdext()
	var moist_scale: float = 1.0
	var soil_arr: PackedFloat32Array = map.soil_moisture_arr
	var vg_arr: PackedFloat32Array = map.vegetation_growth_pressure_arr
	# B+ 路径暂不暴露 stage 11（feedback_decay）的 in/out array 写回路径——
	# 由 finish wrapper 末尾通过 knobs 取回 decayed array 后回灌 map.xxx_arr。
	# round_knobs 字段顺序与 stage helper 中现有 knobs 保持一致，便于 diff 验收。
	var knobs: Dictionary = {
		"season": season,
		"season_phase": float(season) + 0.5,
		"n_cells": n_cells,
		"height": int(_last_cfg.height),
		"sea_level": float(_last_cfg.sea_level),
		# stage 0
		"moist_scale": moist_scale,
		# stage 1
		"rain_shadow_lookback": int(cp.rain_shadow_lookback),
		"rain_shadow_threshold": float(cp.rain_shadow_threshold),
		"rain_shadow_factor": float(cp.rain_shadow_factor),
		"jitter_arr": jitter_arr,
		# stage 2 / 4 / swamp
		"lat_temp_rows": _row_lat_temp,
		"season_offset_rows": _row_season_off,
		"row_indices": row_idx,
		"neighbor_indices": map.neighbor_indices_packed(),
		# stage 4
		"donor_table": donor_table,
		"elev_decay": float(cp.veg_feedback_elev_decay),
		# stage 11 (feedback_decay)
		"decay": float(cp.feedback_decay),
		"soil_moisture_arr": soil_arr,
		"veg_growth_pressure_arr": vg_arr,
	}
	return knobs


# B+ 入口 1/3：开启 round。
# 返回 handle > 0 表示 active；<=0 表示门禁失败，caller 应退回 12-stage 路径。
# 副作用：refresh_slots_from_map（让 C++ SoA 看到本 round 起点的最新 cell 状态），
#         重置 _season_round_b_plus_* 累计计数。
func start_season_round_b_plus(map: MapData, _world: WorldData, season: int) -> int:
	if not season_round_b_plus_available():
		_season_log_path_once("b_plus", "gdscript_fallback", "gate fail (cp/ext/method)")
		return 0
	if soil_arr_size_mismatch(map):
		_season_log_path_once("b_plus", "gdscript_fallback", "soil/vg arr size mismatch with n_cells")
		return 0
	# 旧 round 残留（前一个 round 没正常 finish / abort）→ 强制清理。
	if _season_round_b_plus_handle > 0:
		_season_log_path_once("b_plus", "stale_handle_abort", "previous handle=%d still active, forcing abort" % _season_round_b_plus_handle)
		_abort_season_round_b_plus_safe()
	_ensure_season_round_slots_fresh()
	var knobs: Dictionary = _build_season_round_knobs(map, season)
	if knobs.is_empty():
		_season_log_path_once("b_plus", "gdscript_fallback", "round_knobs build failed (cfg/map/row_table)")
		return 0
	var res: Dictionary = _data_core_world_ext.start_season_round(knobs)
	if res.is_empty() or bool(res.get("fallback", true)):
		_season_log_path_once("b_plus", "gdscript_fallback", "start_season_round returned fallback: %s" % String(res.get("reason", "unknown")))
		return 0
	var handle: int = int(res.get("handle", 0))
	if handle <= 0:
		_season_log_path_once("b_plus", "gdscript_fallback", "start_season_round returned invalid handle=%d" % handle)
		return 0
	_season_round_b_plus_handle = handle
	_season_round_b_plus_native_ms = 0.0
	_season_round_b_plus_slices_used = 0
	_season_round_b_plus_stages_done = 0
	_b_plus_round_start_usec = Time.get_ticks_usec()
	_last_season_refresh_breakdown["b_plus_path"] = "gdext"
	_last_season_refresh_breakdown["b_plus_handle"] = handle
	_season_log_path_once("b_plus_start", "gdext", "handle=%d season=%d n_cells=%d" % [handle, season, int(knobs.get("n_cells", 0))])
	return handle


# B+ 入口 2/3：推进一个 slice，stage-boundary 切片（b1）。
# max_usec：单 slice 预算（默认从 cp.sim_slice_budget_ms 取）。
# 返回字典 { "done": bool, "stages_done": int, "elapsed_ms": float, "fallback": bool }。
# 任一异常（handle 无效 / fallback / mid-slice 错误）→ 标记 done=true + fallback=true，
# 上层 caller 应放弃 round 并退回 12-stage 路径补完。
func run_season_round_slice_b_plus(_map: MapData, _world: WorldData, max_usec: int = 0) -> Dictionary:
	var out: Dictionary = {"done": false, "stages_done": 0, "elapsed_ms": 0.0, "fallback": false}
	if _season_round_b_plus_handle <= 0:
		out["fallback"] = true
		out["done"] = true
		_season_log_path_once("b_plus_slice", "gdscript_fallback", "no active handle")
		return out
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("run_season_round_slice"):
		out["fallback"] = true
		out["done"] = true
		_season_log_path_once("b_plus_slice", "gdscript_fallback", "ext/method missing mid-round")
		return out
	var budget_us: int = max_usec
	if budget_us <= 0:
		var cp := _c()
		var ms: float = 0.55
		if cp != null and cp.get("sim_slice_budget_ms") != null:
			ms = float(cp.sim_slice_budget_ms)
		budget_us = maxi(50, int(round(ms * 1000.0)))
	budget_us = clampi(budget_us, 50, 1000)
	var res: Dictionary = _data_core_world_ext.run_season_round_slice(_season_round_b_plus_handle, budget_us)
	if res.is_empty() or bool(res.get("fallback", false)):
		out["fallback"] = true
		out["done"] = true
		_season_log_path_once("b_plus_slice", "gdscript_fallback", "run_season_round_slice fallback: %s" % String(res.get("reason", "unknown")))
		# 让 C++ 端清掉残留状态（next round 才能干净开新）。
		_abort_season_round_b_plus_safe()
		return out
	var elapsed_ms: float = float(res.get("elapsed_ms", 0.0))
	_season_round_b_plus_native_ms += elapsed_ms
	_season_round_b_plus_slices_used += 1
	_season_round_b_plus_stages_done = int(res.get("stages_done", _season_round_b_plus_stages_done))
	out["elapsed_ms"] = elapsed_ms
	out["stages_done"] = _season_round_b_plus_stages_done
	out["done"] = bool(res.get("done", false))
	return out


# B+ 入口 3/3：round 收尾。
# 副作用：
#   1. 调 finish_season_round 取回 decayed soil_moisture_arr / veg_growth_pressure_arr，
#      回灌 map.xxx_arr，让 hexcell_facade getter 看到新值。
#   2. 调一次 _sync_stage8_facade_fields_from_soa(map) 把多轴 SoA（terrain/landform/
#      vegetation/cover）回灌到 cell facade，并触发 push_biome_history /
#      push_vegetation_history 各 1 次/round。
#   3. 落 breakdown：b_plus_native_ms / slices / stages_done。
#   4. 清 handle 与累计计数。
# 若 finish_season_round 本身 fallback：仍尝试 facade sync 让本 round 已写入 SoA 的
# 部分字段透出（避免上层看到陈旧 cell），然后清 handle。
func finish_season_round_b_plus(map: MapData, _world: WorldData, _season: int) -> void:
	if _season_round_b_plus_handle <= 0:
		_season_log_path_once("b_plus_finish", "gdscript_fallback", "no active handle to finish")
		return
	var ext_ok: bool = _data_core_world_ext != null and _data_core_world_ext.has_method("finish_season_round")
	if not ext_ok:
		_season_log_path_once("b_plus_finish", "gdscript_fallback", "finish_season_round method missing")
		# 算作一次 fallback round（已 start 但 ext 半途丢失，验收侧应可见）
		_b_plus_rounds_total += 1
		_b_plus_rounds_fallback += 1
		_season_round_b_plus_handle = 0
		_b_plus_round_start_usec = 0
		return
	var res: Dictionary = _data_core_world_ext.finish_season_round(_season_round_b_plus_handle)
	var fallback: bool = bool(res.get("fallback", false))
	# 即便 fallback，res 内的 in/out array 也优先取（C++ 端如果半途退出至少把已 decayed 的写回了）。
	if map != null:
		var n: int = map.cell_count()
		var soil_out: Variant = res.get("soil_moisture_arr", null)
		var vg_out: Variant = res.get("veg_growth_pressure_arr", null)
		if typeof(soil_out) == TYPE_PACKED_FLOAT32_ARRAY and (soil_out as PackedFloat32Array).size() == n:
			map.soil_moisture_arr = soil_out
		if typeof(vg_out) == TYPE_PACKED_FLOAT32_ARRAY and (vg_out as PackedFloat32Array).size() == n:
			map.vegetation_growth_pressure_arr = vg_out
		# 行为变更（用户 2026-05-21 已确认）：B+ 路径下 facade sync + history push 1 次/round。
		_sync_stage8_facade_fields_from_soa(map)
	_last_season_refresh_breakdown["b_plus_native_ms"] = float(res.get("total_native_ms", _season_round_b_plus_native_ms))
	_last_season_refresh_breakdown["b_plus_slices_used"] = int(res.get("slices_used", _season_round_b_plus_slices_used))
	_last_season_refresh_breakdown["b_plus_stages_done"] = int(res.get("stages_done", _season_round_b_plus_stages_done))
	if fallback:
		_season_log_path_once("b_plus_finish", "gdscript_fallback", "finish_season_round fallback: %s" % String(res.get("reason", "unknown")))
	else:
		_season_log_path_once("b_plus_finish", "gdext", "native_ms=%.3f slices=%d stages_done=%d" % [
				float(res.get("total_native_ms", _season_round_b_plus_native_ms)),
				int(res.get("slices_used", _season_round_b_plus_slices_used)),
				int(res.get("stages_done", _season_round_b_plus_stages_done)),
		])
	# B+ round 验收样本采集（pop_b_plus_round_samples 消费）
	var wall_ms_now: float = 0.0
	if _b_plus_round_start_usec > 0:
		wall_ms_now = float(Time.get_ticks_usec() - _b_plus_round_start_usec) / 1000.0
	_b_plus_rounds_total += 1
	if fallback:
		_b_plus_rounds_fallback += 1
	else:
		_b_plus_rounds_b_plus += 1
	_b_plus_slices_used_samples.append(int(res.get("slices_used", _season_round_b_plus_slices_used)))
	_b_plus_stages_done_samples.append(int(res.get("stages_done", _season_round_b_plus_stages_done)))
	_b_plus_native_ms_samples.append(float(res.get("total_native_ms", _season_round_b_plus_native_ms)))
	_b_plus_wall_ms_samples.append(wall_ms_now)
	_season_round_b_plus_handle = 0
	_season_round_b_plus_native_ms = 0.0
	_season_round_b_plus_slices_used = 0
	_season_round_b_plus_stages_done = 0
	_b_plus_round_start_usec = 0


# 一次性取走 B+ round 验收样本，清零内部计数。
# 由 dots_final_frontier_perf_verdict.evaluate 调用，避免长期持有。
func pop_b_plus_round_samples() -> Dictionary:
	var slices_arr: Array = []
	for v in _b_plus_slices_used_samples:
		slices_arr.append(int(v))
	var stages_arr: Array = []
	for v in _b_plus_stages_done_samples:
		stages_arr.append(int(v))
	var native_arr: Array = []
	for v in _b_plus_native_ms_samples:
		native_arr.append(float(v))
	var wall_arr: Array = []
	for v in _b_plus_wall_ms_samples:
		wall_arr.append(float(v))
	var out: Dictionary = {
		"rounds_total": _b_plus_rounds_total,
		"rounds_b_plus": _b_plus_rounds_b_plus,
		"rounds_fallback": _b_plus_rounds_fallback,
		"slices_used_samples": slices_arr,
		"stages_done_samples": stages_arr,
		"native_ms_samples": native_arr,
		"wall_ms_samples": wall_arr,
	}
	_b_plus_rounds_total = 0
	_b_plus_rounds_b_plus = 0
	_b_plus_rounds_fallback = 0
	_b_plus_slices_used_samples.clear()
	_b_plus_stages_done_samples.clear()
	_b_plus_native_ms_samples.clear()
	_b_plus_wall_ms_samples.clear()
	return out


# 强制中止当前 B+ round（C++ 端清 round_state，GDScript 端清 handle）。
# 用于：start 前发现旧 round 残留 / slice 中途 fallback 后清场 / 外部主动放弃。
# 不抛异常；ext 缺失时仅清本地 handle。
func _abort_season_round_b_plus_safe() -> void:
	if _data_core_world_ext != null and _data_core_world_ext.has_method("abort_season_round"):
		_data_core_world_ext.abort_season_round()
	_season_round_b_plus_handle = 0
	_season_round_b_plus_native_ms = 0.0
	_season_round_b_plus_slices_used = 0
	_season_round_b_plus_stages_done = 0
	# abort 不算完整 round（不进 _b_plus_rounds_total 计数），仅清 start usec。
	_b_plus_round_start_usec = 0


# 检查 soil_moisture / veg_growth_pressure SoA size 是否与 n_cells 对齐。
# B+ 路径 round_knobs 内含这两条 in/out array，size 不齐会导致 C++ 端 stage 11 路径
# 误算或 OOB；start 阶段就拒绝，回 GDScript fallback。
func soil_arr_size_mismatch(map: MapData) -> bool:
	if map == null:
		return true
	var n: int = map.cell_count()
	var s: int = (map.soil_moisture_arr as PackedFloat32Array).size()
	var v: int = (map.vegetation_growth_pressure_arr as PackedFloat32Array).size()
	return s != n or v != n


func _sync_stage8_facade_fields_from_soa(map: MapData) -> void:
	var n: int = map.cell_count()
	var terrain_a: PackedByteArray = map.terrain_arr
	var landform_a: PackedByteArray = map.landform_arr
	var vegetation_a: PackedByteArray = map.vegetation_arr
	var cover_a: PackedByteArray = map.cover_arr
	if map.has_method("sync_runtime_terrain_facade_from_soa"):
		map.sync_runtime_terrain_facade_from_soa()
	for i in range(n):
		var cell: HexCell = map.cell_at(i)
		if cell == null:
			continue
		if i < landform_a.size():
			cell.landform = int(landform_a[i])
		if i < vegetation_a.size():
			cell.vegetation = int(vegetation_a[i])
		if i < cover_a.size():
			cell.cover = int(cover_a[i])
		cell.push_biome_history(int(cell.terrain))
		cell.push_vegetation_history(int(cell.vegetation))


func build_current_state_view(cell: HexCell, season: int = -1) -> Dictionary:
	if cell == null:
		return {}
	var season_v: int = season
	if season_v < 0:
		season_v = clampi(_current_season, 0, 3)
	return {
		"season": season_v,
		"temperature": float(cell.temperature),
		"moisture": float(cell.moisture),
		"snow_cover": float(cell.snow_cover),
		"biome": int(cell.terrain),
		"landform": int(cell.landform),
		"vegetation": int(cell.vegetation),
		"cover": int(cell.cover),
		"weather": cell.weather_type if cell.weather_field_initialized else int(WeatherType.WT.CLEAR),
		"weather_intensity": cell.weather_intensity if cell.weather_field_initialized else 0.0,
	}


func _seasonal_redecide_terrain(map: MapData, season: int) -> void:
	if _last_cfg == null:
		return
	var cfg_local: MapConfig = _last_cfg
	_ensure_row_tables(cfg_local, season)
	var lat_tab: PackedFloat32Array = _row_lat_temp
	var off_tab: PackedFloat32Array = _row_season_off
	# 性能修复：iter_cells() 零复制。
	var _cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	for cell: HexCell in _cells:
		if _is_water(cell.terrain):
			if not _is_water(cell.base_terrain):
				_set_cell_runtime_terrain(map, cell, cell.base_terrain, true)
			continue
		# 2026-05-18：解除 MOUNTAIN lock-in，仅 SNOW 永久。详见 _run_season_stage2_micro 注释。
		var is_permanent_climate := cell.base_terrain == TerrainType.TERRAIN.SNOW
		if is_permanent_climate:
			_set_cell_runtime_terrain(map, cell, cell.base_terrain, true)
			continue
		if _is_permanent_landform(cell.base_terrain):
			_set_cell_runtime_terrain(map, cell, cell.base_terrain, true)
			continue
		var r_idx: int = _cube_to_row(cell, cfg_local)
		var lat_temp: float = lat_tab[r_idx]
		var temp_year: float = clampf(lat_temp - _alt_penalty(cell.elevation), 0.0, 1.0)
		var temp_now: float = clampf(temp_year + off_tab[r_idx], 0.0, 1.0)
		var new_terrain := _decide_terrain(cell.elevation, temp_now, cell.moisture, cfg_local)
		if _is_water(new_terrain) and not _is_water(cell.terrain):
			new_terrain = cell.base_terrain if not _is_water(cell.base_terrain) else cell.terrain
		_set_cell_runtime_terrain(map, cell, new_terrain, true, temp_now, cell.snow_cover)


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
		var temp_year2: float = clampf(lat_temp2 - _alt_penalty(cell.elevation), 0.0, 1.0)
		var temp_now2: float = clampf(temp_year2 + off_tab[r_idx2], 0.0, 1.0)
		var land_h: float = (cell.elevation - cfg_local.sea_level) / maxf(1.0 - cfg_local.sea_level, 0.001)
		var snow_cover: float = 0.0
		if not _is_water(cell.terrain):
			snow_cover = _derived_snow_cover(temp_now2, land_h, int(cell.terrain), int(cell.cover))
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


func sus_report_sim_budget_window() -> Dictionary:
	if _sus == null or not _sus.has_method("report_sim_budget_window"):
		return {}
	return _sus.report_sim_budget_window()


# DOTS-Final-Push 任务 10：透传 SUS scheduler `_stats` 全表给
# DCDotsFinalPushPerfVerdict.evaluate() 使用。schema 见
# sus_scheduler.gd::report_job_stats() 注释。
func sus_report_job_stats() -> Dictionary:
	if _sus == null:
		return {}
	if not _sus.has_method("report_job_stats"):
		return {}
	return _sus.report_job_stats()


# 2026-05-19：透传 SUS 滚动窗口的 skipped reason 累计 + max_ms。
# 用途：DebugConsole 快照导出 + 性能分析时识别"长期被节流"的 Job。
func sus_report_skipped_summary() -> Dictionary:
	if _sus == null or not _sus.has_method("report_skipped_summary"):
		return {}
	return _sus.report_skipped_summary()

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

func _ensure_generation_world_ext() -> RefCounted:
	if _data_core_world_ext != null:
		return _data_core_world_ext
	if not ClassDB.class_exists("DCWorldExt"):
		return null
	var ext_obj: Object = ClassDB.instantiate("DCWorldExt")
	if ext_obj == null or not (ext_obj is RefCounted):
		return null
	_data_core_world_ext = ext_obj
	return _data_core_world_ext


func _native_generation_cfg_dict(cfg: MapConfig) -> Dictionary:
	if cfg == null:
		return {}
	return {
		"width": int(cfg.width),
		"height": int(cfg.height),
		"num_continents": int(cfg.num_continents),
		"sea_level": float(cfg.sea_level),
		"continent_size": float(cfg.continent_size),
		"river_count": int(cfg.river_count),
		"seed": int(cfg.seed),
		"enable_ocean_heat_transport": bool(cfg.enable_ocean_heat_transport),
	}


func _native_generation_profile_dict() -> Dictionary:
	var cp := _c()
	if cp == null:
		return {"native_generation_mode": 0}
	var keys := [
		"native_generation_mode",
		"continent_warp_amp",
		"dist_field_weight",
		"noise_weight",
		"ridge_boost_amp",
		"meso_weight",
		"macro_relief_weight",
		"offshore_amp",
		"edge_falloff_start",
		"edge_falloff_end",
		"edge_falloff_depth",
		# 复刻 GDScript 生成：湖泊种子 + 坑洼平滑 knob（native base pass 用）
		"lake_seed_freq",
		"lake_seed_threshold",
		"lake_seed_depth",
		"lake_seed_min_interior",
		"pit_fill_max_iters",
		"main_radius_min",
		"main_radius_max",
		"satellite_radius_min",
		"satellite_radius_max",
		"satellites_per_main",
		"main_placement_min",
		"main_placement_max",
		"satellite_placement_min",
		"satellite_placement_max",
		"main_separation_factor",
		"satellite_separation_factor",
		"coastal_moisture_boost",
		"orographic_boost",
		"rain_shadow_threshold",
		"rain_shadow_factor",
		"rain_shadow_lookback",
		"river_flow_percentile",
		"river_channel_init_cells",
		"hydro_river_min_length",
		"hydro_lake_min_cells",
		"hydro_lake_min_depth",
		"hydro_lake_min_volume",
		"veg_forest_donor",
		"veg_swamp_donor",
		"veg_grassland_donor",
		"veg_desert_donor",
		"veg_jungle_donor",
		"veg_taiga_donor",
		"veg_savanna_donor",
		"veg_oasis_donor",
		"veg_delta_donor",
		"veg_salt_flat_donor",
		"veg_feedback_elev_decay",
		"max_volcanoes",
		"volcano_min_dist",
		"volcano_min_land_h",
		# terrain-overhaul Phase 0 板块构造
		"tectonic_blend",
		"tectonic_plate_count",
		"tectonic_continental_fraction",
		"tectonic_continental_base",
		"tectonic_oceanic_base",
		"tectonic_uplift_amp",
		"tectonic_ridge_width",
		"tectonic_drift_speed",
		"tectonic_lloyd_iters",
		# Stream-Power 河流侵蚀 (Cordonnier 2016)
		"spl_iters",
		"spl_erodibility",
		"spl_area_exp",
		"spl_uplift_rate",
		# terrain-overhaul Phase 1 侵蚀
		"erosion_droplet_factor",
		"erosion_max_lifetime",
		"erosion_capacity",
		"erosion_deposit_rate",
		"erosion_erode_rate",
		"erosion_evaporation",
		"erosion_gravity",
		"erosion_min_slope",
		"erosion_thermal_iters",
		"erosion_thermal_talus",
		"erosion_thermal_rate",
		# terrain-overhaul Phase 3 统一气候场
		"moisture_wind_evap",
		"moisture_rainout_base",
		"moisture_orographic_gain",
		"moisture_continental_dry",
		"moisture_land_base",
		"moisture_precip_gain",
		"moisture_humidity_cap",
		"moisture_smooth",
		"moisture_noise_amp",
		"moisture_coastal_floor",
		"moisture_coastal_scale",
		"coastal_temp_moderation",
		"coastal_temp_scale",
		# terrain-overhaul Phase 5 特征点缀
		"salt_flat_min_dist_ocean",
		"chaparral_max_dist_ocean",
	]
	var out: Dictionary = {}
	for k in keys:
		if cp.get(k) != null:
			out[k] = cp.get(k)
	return out


func _native_generation_array_ok(res: Dictionary, key: String, n: int, type_id: int) -> bool:
	var v = res.get(key, null)
	if typeof(v) != type_id:
		return false
	return v.size() == n


func get_native_generation_base_report() -> Dictionary:
	return _native_generation_base_report.duplicate(true)


func _native_generation_post_base_ok() -> bool:
	var post = _native_generation_base_report.get("post_base", null)
	return typeof(post) == TYPE_DICTIONARY \
		and int(post.get("rc", -1)) == 0 \
		and not bool(post.get("fallback", true))


# native generation ACTIVE 路径：C++ 负责 base SoA + post-base 湖泊/河流/
# 生态/地标后处理；GDScript 只发送请求、校验 PackedArray 并装配 HexCell。
func _generate_cells_native_base(cfg: MapConfig, seed: int) -> MapData:
	var cp := _c()
	if not _native_mode_is_active(cp, "native_generation_mode"):
		_native_generation_base_report = {
			"rc": -1,
			"path": "gdscript",
			"fallback_reason": "native_generation_mode_not_active",
		}
		return null
	var ext := _ensure_generation_world_ext()
	if ext == null or not ext.has_method("run_native_world_generate_base_pass"):
		_native_generation_base_report = {
			"rc": -1,
			"path": "gdscript",
			"fallback_reason": "missing_run_native_world_generate_base_pass",
		}
		return null

	var cfg_dict := _native_generation_cfg_dict(cfg)
	var profile_dict := _native_generation_profile_dict()
	var res: Dictionary = ext.run_native_world_generate_base_pass(seed, cfg_dict, profile_dict)
	_native_generation_base_report = res.duplicate(true)
	if int(res.get("rc", -1)) != 0 or bool(res.get("fallback", true)):
		var reason := String(res.get("fallback_reason", res.get("reason", "unknown")))
		push_warning("[native_generation/base] 失败 (%s)；GDScript _generate_cells 已移除，中止生成" % reason)
		return null
	var n: int = int(res.get("n_cells", 0))
	var expected_n: int = int(cfg.width) * int(cfg.height)
	if n <= 0 or n != expected_n:
		push_warning("[native_generation/base] bad n_cells=%d expected=%d; fallback" % [n, expected_n])
		return null
	var required := {
		"q_arr": TYPE_PACKED_INT32_ARRAY,
		"r_arr": TYPE_PACKED_INT32_ARRAY,
		"elevation_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"base_moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"temp_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"terrain_arr": TYPE_PACKED_BYTE_ARRAY,
		"landform_arr": TYPE_PACKED_BYTE_ARRAY,
		"vegetation_arr": TYPE_PACKED_BYTE_ARRAY,
		"cover_arr": TYPE_PACKED_BYTE_ARRAY,
	}
	for key in required.keys():
		if not _native_generation_array_ok(res, key, n, int(required[key])):
			push_warning("[native_generation/base] bad array %s; fallback" % key)
			return null

	# dots-total-cpp（2026-06-18）：post_base 也已 C++ 化并 parity PASS。GDScript
	# 后处理 fallback（_run_post_base_generation_passes）已删除——post_base 缺失/失败
	# 即返回 null，由上层 generate() 硬中止。
	if not ext.has_method("run_native_world_generate_post_base_pass"):
		push_warning("[native_generation/post_base] 缺 run_native_world_generate_post_base_pass（DLL 未 rebuild?）；中止")
		return null
	var post_res: Dictionary = ext.run_native_world_generate_post_base_pass(seed, cfg_dict, profile_dict, res)
	var report := res.duplicate(true)
	report["post_base"] = post_res.duplicate(true)
	_native_generation_base_report = report
	if int(post_res.get("rc", -1)) != 0 or bool(post_res.get("fallback", true)):
		var reason := String(post_res.get("fallback_reason", post_res.get("reason", "unknown")))
		push_warning("[native_generation/post_base] 失败 (%s)；GDScript 后处理已移除，中止生成" % reason)
		return null
	var final_res: Dictionary = post_res

	var map := _assemble_native_generation_map(final_res, cfg)
	if map == null:
		push_warning("[native_generation] final result invalid（装配失败）；中止生成")
		return null
	print("[native_generation/base] path=gdext algorithm=%s n=%d native_ms=%.3f water=%d land=%d"
		% [
			String(res.get("native_algorithm", "unknown")),
			n,
			float(res.get("native_ms", res.get("elapsed_ms", 0.0))),
			int(res.get("water_count", 0)),
			int(res.get("land_count", 0)),
		])
	print("[native_generation/post_base] path=gdext algorithm=%s n=%d native_ms=%.3f lakes=%d rivers=%d volcanoes=%d"
		% [
			String(final_res.get("native_algorithm", "unknown")),
			int(final_res.get("n_cells", 0)),
			float(final_res.get("native_ms", final_res.get("elapsed_ms", 0.0))),
			int(final_res.get("lake_count", 0)),
			int(final_res.get("river_count", 0)),
			int(final_res.get("volcano_count", 0)),
		])
	# 生成 QA 度量（地形改造回归基线）：单格水体应 →0，biome 熵/河流占比应随改造上升。
	var qa: Dictionary = final_res.get("qa_metrics", {})
	if not qa.is_empty():
		print("[native_generation/qa] single_water=%d tiny<=3=%d small<=5=%d bodies=%d largest=%d | land_below_sea=%.1f%% | terr_distinct=%d entropy=%.3fbit | river_ratio=%.3f%%"
			% [
				int(qa.get("single_tile_water", 0)),
				int(qa.get("tiny_water_le3", 0)),
				int(qa.get("small_water_le5", 0)),
				int(qa.get("water_bodies", 0)),
				int(qa.get("largest_water_body", 0)),
				100.0 * float(qa.get("land_below_sealevel_ratio", 0.0)),
				int(qa.get("terrain_distinct", 0)),
				float(qa.get("terrain_entropy_bits", 0.0)),
				100.0 * float(qa.get("river_ratio", 0.0)),
			])
	return map


func _assemble_native_generation_map(res: Dictionary, cfg: MapConfig) -> MapData:
	var n: int = int(res.get("n_cells", 0))
	if cfg == null or n <= 0 or n != int(cfg.width) * int(cfg.height):
		return null
	var required := {
		"q_arr": TYPE_PACKED_INT32_ARRAY,
		"r_arr": TYPE_PACKED_INT32_ARRAY,
		"elevation_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"base_moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"temp_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"terrain_arr": TYPE_PACKED_BYTE_ARRAY,
		"landform_arr": TYPE_PACKED_BYTE_ARRAY,
		"vegetation_arr": TYPE_PACKED_BYTE_ARRAY,
		"cover_arr": TYPE_PACKED_BYTE_ARRAY,
	}
	for key in required.keys():
		if not _native_generation_array_ok(res, key, n, int(required[key])):
			push_warning("[native_generation/assemble] bad array %s" % key)
			return null

	var q_arr: PackedInt32Array = res["q_arr"]
	var r_arr: PackedInt32Array = res["r_arr"]
	var elevation_arr: PackedFloat32Array = res["elevation_arr"]
	var moisture_arr: PackedFloat32Array = res["moisture_arr"]
	var base_moisture_arr: PackedFloat32Array = res["base_moisture_arr"]
	var temp_arr: PackedFloat32Array = res["temp_arr"]
	var temp_baseline_arr: PackedFloat32Array = res["temp_baseline_arr"] if res.has("temp_baseline_arr") else temp_arr
	var temp_30d_arr: PackedFloat32Array = res["temp_30d_arr"] if res.has("temp_30d_arr") else temp_arr
	var temp_365d_arr: PackedFloat32Array = res["temp_365d_arr"] if res.has("temp_365d_arr") else temp_arr
	var terrain_arr: PackedByteArray = res["terrain_arr"]
	var base_terrain_arr: PackedByteArray = res["base_terrain_arr"] if res.has("base_terrain_arr") else terrain_arr
	var landform_arr: PackedByteArray = res["landform_arr"]
	var base_landform_arr: PackedByteArray = res["base_landform_arr"] if res.has("base_landform_arr") else landform_arr
	var vegetation_arr: PackedByteArray = res["vegetation_arr"]
	var base_vegetation_arr: PackedByteArray = res["base_vegetation_arr"] if res.has("base_vegetation_arr") else vegetation_arr
	var cover_arr: PackedByteArray = res["cover_arr"]
	var has_river_arr: PackedByteArray = res["has_river_arr"] if res.has("has_river_arr") else PackedByteArray()
	var river_flow_arr: PackedFloat32Array = res["river_flow_arr"] if res.has("river_flow_arr") else PackedFloat32Array()
	var river_downstream_arr: PackedInt32Array = res["river_downstream_arr"] if res.has("river_downstream_arr") else PackedInt32Array()
	var hydro_parent_arr: PackedInt32Array = res["hydro_parent_arr"] if res.has("hydro_parent_arr") else PackedInt32Array()
	var has_volcano_arr: PackedByteArray = res["has_volcano_arr"] if res.has("has_volcano_arr") else PackedByteArray()
	var is_lake_seed_arr: PackedByteArray = res["is_lake_seed_arr"] if res.has("is_lake_seed_arr") else PackedByteArray()
	var map := MapData.new(cfg.width, cfg.height)
	for i in range(n):
		var cell := HexCell.new(int(q_arr[i]), int(r_arr[i]))
		cell.elevation = float(elevation_arr[i])
		cell.moisture = float(moisture_arr[i])
		cell.base_moisture = float(base_moisture_arr[i])
		cell.apply_terrain(int(terrain_arr[i]))
		cell.base_terrain = int(base_terrain_arr[i]) if base_terrain_arr.size() == n else int(terrain_arr[i])
		cell.landform = int(landform_arr[i])
		cell.base_landform = int(base_landform_arr[i]) if base_landform_arr.size() == n else int(landform_arr[i])
		cell.vegetation = int(vegetation_arr[i])
		cell.base_vegetation = int(base_vegetation_arr[i]) if base_vegetation_arr.size() == n else int(vegetation_arr[i])
		cell.cover = int(cover_arr[i])
		cell.has_river = has_river_arr.size() == n and int(has_river_arr[i]) != 0
		cell.river_flow = float(river_flow_arr[i]) if river_flow_arr.size() == n else (1.0 if cell.has_river else 0.0)
		if river_downstream_arr.size() == n:
			var downstream_idx: int = int(river_downstream_arr[i])
			if downstream_idx >= 0 and downstream_idx < n:
				cell.river_downstream = Vector3i(int(q_arr[downstream_idx]), int(r_arr[downstream_idx]), -int(q_arr[downstream_idx]) - int(r_arr[downstream_idx]))
				cell.has_river_downstream = true
		cell.has_volcano = has_volcano_arr.size() == n and int(has_volcano_arr[i]) != 0
		cell.is_lake_seed = is_lake_seed_arr.size() == n and int(is_lake_seed_arr[i]) != 0
		cell._temperature_backing = float(temp_arr[i])
		cell._temp_baseline_backing = float(temp_baseline_arr[i])
		cell._temp_30d_mean_backing = float(temp_30d_arr[i])
		cell._temp_365d_mean_backing = float(temp_365d_arr[i])
		cell._temp_dev_from_annual_backing = 0.0
		cell._ema_initialized = true
		cell.current_state = {
			"season": 1,
			"temperature": float(temp_arr[i]),
			"moisture": cell.base_moisture,
			"snow_cover": 0.0,
			"biome": int(cell.terrain),
			"landform": int(cell.landform),
			"vegetation": int(cell.vegetation),
			"cover": int(cell.cover),
			"weather": int(WeatherType.WT.CLEAR),
			"weather_intensity": 0.0,
		}
		map.set_cell(cell)
	if hydro_parent_arr.size() == n:
		map.hydro_parent_arr = hydro_parent_arr.duplicate()
	return map


# ─── 噪声初始化 ──────────────────────────────────────────────────────────

# dots-total-cpp（2026-06-18）：GDScript 生成已删除。_height_noise / _detail_noise /
# _moisture_noise 仅生成用，已随之移除。_height_warp 仍被 C++ 桥
# _build_rain_shadow_jitter_for_gdext（季节 stage1 / B+ round 雨影 jitter）读取，
# 故保留并继续按生成期同款参数初始化（seed+13），保证 jitter 与原生成 bit 对齐。
func _init_noise(seed_val: int) -> void:
	# 域扭曲：低频。原生成大陆轮廓用；现仅供 rain-shadow jitter C++ 桥消费。
	_height_warp = FastNoiseLite.new()
	_height_warp.noise_type            = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_height_warp.seed                  = seed_val + 13
	_height_warp.frequency             = 0.025
	_height_warp.fractal_type          = FastNoiseLite.FRACTAL_FBM
	_height_warp.fractal_octaves       = 3


# ─── 温度（cos bell 曲线） ───────────────────────────────────────────────

# 海拔→温度递减率（双段式，2026-05-18 雪线修正）。
# 旧：alt_penalty = elev * 0.5 —— 海拔 0.85 山头只比平原冷 0.425（≈30 个纬度），
#    赤道高山 temp 仍 ≈ 0.575，无法触发雪线分支。
# 新：低海拔段保持 ×0.55（保护平原/丘陵的纬度气候带不被压扁），
# 0.55→0.40 降低海拔线性降温，使中海拔 4-6 月积雪自然融化，季节温差超越海拔效应。
# AMP 0.30→0.22 等比缩放高山额外扣减。
# CPU/GPU/C++ SAME_SOURCE：三路径一致。
const ALT_PEN_LINEAR: float = 0.40
const ALT_PEN_HIGH_AMP: float = 0.22
const ALT_PEN_HIGH_LO: float = 0.45
const ALT_PEN_HIGH_HI: float = 1.00

# A.2.1.B — Pass-A push 稀疏化 ε 阈值（dynamic_visual_atlas 35-50ms 长帧根治 M1）。
# SoA 路径（_climate_pass_a_soa）用同款数值就地声明为 _DIRTY_EPS_TEMP/MOIST/SNOW，
# 二者必须严格相等以保证两路径的 dirty 决策语义一致（mean_diff 红线 0.005，ε 远低于此）。
const _PUSH_EPS_TEMP: float = 1.0 / 512.0
const _PUSH_EPS_MOIST: float = 1.0 / 512.0
const _PUSH_EPS_SNOW: float = 1.0 / 256.0

func _alt_penalty(elevation: float) -> float:
	var lin: float = elevation * ALT_PEN_LINEAR
	var hi: float = smoothstep(ALT_PEN_HIGH_LO, ALT_PEN_HIGH_HI, elevation) * ALT_PEN_HIGH_AMP
	return lin + hi

# 雪盖派生：与 shader compute_snow_factor 同公式（去掉 fbm jitter，CPU 端用确定性版本）。
# 2026-05-19：把雪线从"高山地形开关"改回连续海拔/温度权重。
#   - 低温段放宽到 temp<0.52，但以薄雪为主，解决丘陵/温带冬季永远无雪。
#   - 高山段用 temp 0.72→0.28 和 land_h 0.22→0.90 的双 smoothstep，
#     让暖季高山雪盖退成斑驳，而不是只要进 MOUNTAIN 就终年全白。
# 输入 land_h 由 caller 用 sea_level 归一化后传入，避免在此重复算。
# 2026-05-19 Plan-C 调参：cold_snow 雪线带从 [0.26, 0.52]×0.50 收窄到 [0.30, 0.48]×0.55。
# 配合 season_temp_amp 0.20→0.32 的振幅放大，让中高纬地块在春秋出现真正的雪线过渡态，
# 而不是终年同色。SAME_SOURCE 锚点：
#   - shader: shaders/include/snow_cover.gdshaderinc::apply_snow_cover (cold_lo/cold_hi)
#   - 本文件 fast-path 复刻：行 ~5781（_apply_climate_daily_pass_fast 内）
func _derived_snow_cover(temp_now: float, land_h: float, terrain: int, cover: int) -> float:
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

func _compute_temperature(ny: float, elevation: float) -> float:
	# 纬度温度钟形统一走 DCClimateMath.lat_temp_bell（全工程单一来源），再叠海拔惩罚。
	var lat_temp: float = DCClimateMath.lat_temp_bell_from_ny(ny)
	var alt_penalty: float = _alt_penalty(elevation)
	return clampf(lat_temp - alt_penalty, 0.0, 1.0)


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


# SEA_ICE（海冰）：连续 sea_ice_fraction，由逐日温度 pass 推进；
# base_terrain 只作为消融后的 revert target。
# 阈值带 hysteresis：具体 form/melt/terrain 阈值来自 ClimateProfile。
# const SEA_ICE_FORM_THRESHOLD (migrated to ClimateProfile.sea_ice_form_threshold)
# const SEA_ICE_MELT_THRESHOLD (migrated to ClimateProfile.sea_ice_melt_threshold)

func _bootstrap_sea_ice_fraction(map: MapData, cfg: MapConfig) -> void:
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
	var cp := _c()
	if cp == null:
		return
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var thr_terrain: float = float(cp.sea_ice_terrain_threshold)
	var solar_gate_enabled: bool = _sea_ice_solar_gate_enabled(cp)
	var freeze_insol_low: float = float(cp.sea_ice_freeze_insol_low)
	var freeze_insol_high: float = float(cp.sea_ice_freeze_insol_high)
	for cell: HexCell in map.all_cells():
		if not _is_water(cell.terrain):
			cell.sea_ice_fraction = 0.0
			continue
		if cell.terrain == TerrainType.TERRAIN.LAKE:
			cell.sea_ice_fraction = 0.0
			continue
		var ny: float = _cube_row_norm(cell, cfg)
		var temp_year: float = _compute_temperature(ny, cell.elevation)
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
			var annual_insol: float = _insolation_annual_mean(ny)
			frac *= _sea_ice_freeze_gate(annual_insol, freeze_insol_low, freeze_insol_high)
		var stable_polar_pack: bool = polar_w >= 0.78 and temp_ref < t_form * 0.85
		if not stable_polar_pack and frac >= thr_terrain:
			frac = maxf(0.0, thr_terrain - 0.08)
		cell.sea_ice_fraction = frac
		# 生成期只把稳定极地多年冰落成 terrain；过渡冰由 daily pass 自行生长/消退。
		if stable_polar_pack and frac >= thr_terrain and cell.terrain != TerrainType.TERRAIN.SEA_ICE:
			_set_cell_runtime_terrain(map, cell, TerrainType.TERRAIN.SEA_ICE)


# ─── 地形决策（v8 阈值定调） ────────────────────────────────────────────
#
# 决策树先按 elevation 分类（OCEAN/COAST/MOUNTAIN/HILL），剩下的低地按
# (temperature, moisture) 在 Whittaker 风格的二维空间里选择 biome。
#
# v8 的 ridge boost + slope_gate 让中海拔 cell 也能升级 MOUNTAIN，所以
# MOUNTAIN 阈值保持 0.52，配合双向脊线就能产生山脉链。HILL 阈值 0.30
# 让山脚有充足过渡区。

func _decide_terrain(elevation: float, temperature: float, moisture: float, cfg: MapConfig, permanent_only: bool = false) -> TerrainType.TERRAIN:
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
	# permanent_only=true 仅在 bake 阶段（_snapshot_base_state 之前）使用，
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
		# terrain-overhaul：冷而极旱 → COLD_DESERT（寒漠/戈壁），区别于热沙漠。
		return TerrainType.TERRAIN.COLD_DESERT

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
	if t == TerrainType.TERRAIN.MESA:
		return LandformType.LF.PLATEAU
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
	if t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.LAKE or t == TerrainType.TERRAIN.SEA_ICE:
		return VegetationType.VEG.NONE
	# COAST：暖凉浅海软底育海草床(SEAGRASS)，过冷/过热裸沙底为 NONE。
	if t == TerrainType.TERRAIN.COAST:
		if temperature > 0.42 and temperature < 0.74:
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
		return _whittaker_vegetation(temperature, cell.moisture, landform)
	# Phase 10 Whittaker 命中：FOREST/JUNGLE/SAVANNA/GRASSLAND/STEPPE/DESERT
	var is_hilly: bool = (landform == LandformType.LF.HILL)
	match t:
		TerrainType.TERRAIN.FOREST:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			# 暖湿丘陵迎风坡 → 云雾林
			if is_hilly and temperature > 0.50 and cell.moisture > 0.70:
				return VegetationType.VEG.CLOUD_FOREST
			if temperature > 0.55:
				return VegetationType.VEG.SUBTROPICAL_FOREST
			return VegetationType.VEG.TEMPERATE_DECIDUOUS
		TerrainType.TERRAIN.JUNGLE:
			# 热带高地云雾林 → 极湿雨林 → 季风半落叶 → 季雨林
			if (is_alpine or is_hilly) and cell.moisture > 0.62:
				return VegetationType.VEG.CLOUD_FOREST
			if cell.moisture > 0.72:
				return VegetationType.VEG.TROPICAL_RAINFOREST
			if cell.moisture > 0.55:
				return VegetationType.VEG.MONSOON_FOREST
			return VegetationType.VEG.TROPICAL_DRY_FOREST
		TerrainType.TERRAIN.SAVANNA:
			return VegetationType.VEG.MONSOON_FOREST if cell.moisture > 0.45 else VegetationType.VEG.SAVANNA
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
		# 收尾日志：旧版每天一次；现在 physical-hex 已是常态路径，只在第一次
		# 命中时打一行作为可观测证据，后续静默。
		if not _phys_skip_logged:
			_phys_skip_logged = true
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
	# 沿海热力环流 + 科氏偏转 + 山地地形偏转），再叠这一遍经验性"地形扰动"会重复且不一致。
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
# terrain-overhaul：CHAPARRAL/MOOR/FLOODPLAIN/MESA 为特征 pass 专属地形（分类器无法
# 复现），须永久固定，否则季节重判会退回基础气候地形。与 C++ pk_is_permanent_landform 同源。
static func _is_permanent_landform(t: int) -> bool:
	return t == TerrainType.TERRAIN.OASIS \
			or t == TerrainType.TERRAIN.DELTA \
			or t == TerrainType.TERRAIN.SALT_FLAT \
			or t == TerrainType.TERRAIN.BADLANDS \
			or t == TerrainType.TERRAIN.CHAPARRAL \
			or t == TerrainType.TERRAIN.MOOR \
			or t == TerrainType.TERRAIN.FLOODPLAIN \
			or t == TerrainType.TERRAIN.MESA

func _cube_to_col(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.x, 0, cfg.width - 1)

func _cube_to_row(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.y, 0, cfg.height - 1)

func _cube_row_norm(cell: HexCell, cfg: MapConfig) -> float:
	return float(_cube_to_row(cell, cfg)) / float(maxi(cfg.height - 1, 1))

# B1-A：MapData.bake_lat_temp_year_lut() 调用的公开 wrapper，避免跨脚本访问
# 下划线私有函数。返回与 _cube_row_norm 完全等价。
func public_cube_row_norm(cell: HexCell) -> float:
	if _last_cfg == null or cell == null:
		return 0.5
	return _cube_row_norm(cell, _last_cfg)

# cpp-dots（native-generation-publish-2026-06）：地图生成 C++ DOTS 收口点。
# ACTIVE 路径中 base/post-base 地图生成已由 C++ 结果包接管；这里是 bind 后
# publish 层：DCWorldExt 读取已绑定 SoA slot，重算并发布初始 runtime climate slots
#（temp/baseline/EMA/water mask 等），再 flush 回 MapData。
# 返回 true 表示 C++ 已 published_to_slot，后续 temp_baseline_year 专用 bake 可跳过。
func _publish_native_generation_from_slots(map: MapData, cfg: MapConfig) -> bool:
	if map == null or cfg == null or _data_core_world_ext == null:
		return false
	if not _data_core_world_ext.has_method("run_native_world_generate_pass"):
		return false
	var cp := _c()
	var cfg_dict: Dictionary = {
		"cell_count": map.cell_count(),
		"width": int(cfg.width),
		"height": int(cfg.height),
		"sea_level": float(cfg.sea_level),
	}
	var profile_dict: Dictionary = {
		"native_generation_mode": int(cp.get("native_generation_mode")) if cp != null and cp.get("native_generation_mode") != null else 0,
	}
	var res: Dictionary = _data_core_world_ext.run_native_world_generate_pass(_last_seed, cfg_dict, profile_dict)
	if int(res.get("rc", -1)) == 0 and bool(res.get("published_to_slot", false)):
		# C++ flush 使用 MapData.set() reseat PackedArray；重绑 GDScript DCWorld，避免
		# scheduler/facade 持有生成前的旧数组引用。
		if _data_core_world != null and _data_core_world.has_method("rebind_map_data"):
			var demo_tg_on: bool = false
			if cp != null and "demo_thermal_gradient_enabled" in cp:
				demo_tg_on = bool(cp.demo_thermal_gradient_enabled)
			_data_core_world.rebind_map_data(map, demo_tg_on)
			if _sus != null and _sus.has_method("bind_world"):
				_sus.bind_world(_data_core_world)
		if _data_core_world_ext.has_method("flush_pending_mark_dirty_all"):
			_data_core_world_ext.flush_pending_mark_dirty_all()
		var published: Array = res.get("published_slots", [])
		print("[native_generation] path=gdext n=%d published=%d native_ms=%.3f compute_ms=%.3f flush_ms=%.3f"
			% [
				int(res.get("n_cells", 0)),
				published.size(),
				float(res.get("native_ms", res.get("elapsed_ms", 0.0))),
				float(res.get("compute_ms", 0.0)),
				float(res.get("flush_ms", 0.0)),
			])
		return true
	var reason: String = String(res.get("fallback_reason", res.get("reason", "unknown")))
	push_warning("[native_generation] C++ publish fallback (%s); 保留 GDScript 生成期 SoA" % reason)
	return false

# cpp-dots（temp-baseline-authority-2026-06）：cell_temp_baseline_year 的权威 C++ 烘焙。
# 海冰 + 显示温度的运行期 baseline 是 lat_temp_bell(lat_norm) 的纯仿真量——计算权威归
# C++（DCWorldExt.run_temp_baseline_year_bake / pk_lat_temp_bell），写 cell_temp_baseline_year
# slot 并 flush 回 MapData.temp_baseline_year_arr。本函数在 DCWorldExt bind 完成后调用一次。
# ext 未编译 / 未 bind / 缺方法 → 静默保留 bake_lat_temp_year_lut 已填的 GDScript fallback 值。
func _bake_temp_baseline_year_native(map: MapData) -> void:
	if map == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_temp_baseline_year_bake"):
		return
	if int(_data_core_world_ext.component_id("cell_temp_baseline_year")) < 0:
		return
	var lat: PackedFloat32Array = map.cell_lat_norm_arr
	if lat.is_empty():
		return
	var res: Dictionary = _data_core_world_ext.run_temp_baseline_year_bake({"lat_norm": lat})
	if bool(res.get("fallback", true)):
		push_warning("[DataCore] run_temp_baseline_year_bake fallback (%s); 保留 GDScript baseline" % String(res.get("reason", "unknown")))
	else:
		print("[DataCore] cell_temp_baseline_year baked by C++ (pk_lat_temp_bell): n=%d native_ms=%.3f" % [int(res.get("n_cells", 0)), float(res.get("elapsed_ms", 0.0))])

# ─── 轨道相位边界刷新（慢层维护）────────────────────────────────────
# 每次 WorldClock.season_changed 触发。这里不再直接重置湿度、温度、雨影或风；
# 气候变化由每日 C++/DOTS 链条推进：太阳直射点 -> 日照/昼长 -> 热惯性 ->
# SLP/风场 -> 水汽/天气。season_changed 只作为慢层/atlas 的维护边界。
func refresh_seasonal(map: MapData, world: WorldData, season_idx: int) -> void:
	if _last_cfg == null or _baker == null:
		return
	_last_world = world
	_current_season = season_idx
	_mark_enum_atlas_dirty(true, true, true)

# ─── Emergent Climate Coupling：消费反馈缓冲（季末一次） ───────────────
# 调用时机：refresh_seasonal 尾部，每季一次。
# 行为：
#   1) base_moisture 漂移：按 soil_moisture 当前值 × FEEDBACK_SOIL_TO_BASE_W（0.15）
#      累加到 base_moisture（clamp 0..1），模拟"长期土壤湿度抬升湿润基线"。
#   2) 两个反馈字段都乘以 decay（默认 0.5）衰减，保留半数跨季记忆，避免无限累积。
func _consume_feedback_buffers(map: MapData, decay: float) -> void:
	var FEEDBACK_SOIL_TO_BASE_W: float = 0.15
	# 性能修复（2026-05-18）：stage_11_feedback 历史 max=6.14ms（120-tick budget 的最大单项）。
	# 单 cell 工作量极小（一两次 clamp+mul），所以瓶颈是 all_cells() 每次新建
	# Array 复制 2400 项的开销。走 iter_cells() 直接复用底层 _cell_array。
	var _cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	for cell: HexCell in _cells:
		if _is_water(cell.terrain):
			continue
		if absf(cell.soil_moisture) > 1e-4:
			cell.base_moisture = clampf(cell.base_moisture + FEEDBACK_SOIL_TO_BASE_W * cell.soil_moisture, 0.0, 1.0)
		cell.soil_moisture *= decay
		cell.vegetation_growth_pressure *= decay

# ─── 逐日连续气候刷新（Orbital Daily Climate）─────────────────────
# 由 main.gd 的 _on_day_changed 触发，**每日**用连续 season_phase ∈ [0, 4)
# 推进太阳直射点、日照、昼长、热惯性、风与水汽链条，让玩家在面板上
# 看到逐日渐进的气候变化，而不再是季首一次性硬切。
#
# 设计要点（与需求文档 seasonal-continuous-climate/requirements.md 对齐）：
# - **不**调用 _decide_terrain（地形/生态慢层另行维护，避免 biome 抖动）
# - **不**在日历边界重跑独立雨影/季节风；天气水汽来自每日 field
# - **不**调用 _baker.rebake_*（GPU tex 只按 dirty/atlas 维护；视觉温度同样走日照公式）
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
		"_tick_idx": _current_fast_tick_idx,
	}
	if _is_annual_log_tick(_daily_climate_call_count):
		# I1.A-1: wrapper 路径也补上 path=... 标识，与 sliced 路径输出格式对齐。
		# 实际该路径在 SUS 接管后基本不触发（已走 RefreshClimateDailyJob.sliced），
		# 但保留对齐避免日志解析脚本分歧。
		var _wrap_path: String = "legacy"
		if _data_core_world != null and _data_core_world.is_bound():
			if _refresh_climate_daily_job != null and _refresh_climate_daily_job.has_method("data_core_ready") and _refresh_climate_daily_job.data_core_ready():
				_wrap_path = "data_core"
			else:
				_wrap_path = "data_core_cells_only"
		print("refresh_climate_daily #%d: %dms (cells=%d, phase=%.3f) | A=%.1f B=%.1f ocean=%.1f wind=%.1f sea_ice=%.1f ice_bake=%.1f transp=%.1f path=%s" % [
			_daily_climate_call_count,
			Time.get_ticks_msec() - t0,
			map.cell_count(),
			season_phase,
			t_pass_a_ms, t_pass_b_ms, t_ocean_ms, t_wind_ms, t_sea_ice_ms, t_ice_bake_ms, t_transp_ms,
			_wrap_path,
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

# PR-2.1.1 helper：把 [name → cid → write_*_indexed] 三步压成一行调用，封装
# `_data_core_world == null` / `cid < 0` 双守卫。供 _climate_pass_a /
# _climate_pass_a_soa 以及后续 PR-2.1.2/3/4 的 hot pass push 块复用。
# 详见 docs/dots-master-execution-handbook.md §3.4.2.C / §9.2 模板 2。
func _push_f32_to_world(name: StringName, indices: PackedInt32Array, values: PackedFloat32Array) -> void:
	if _data_core_world == null:
		return
	var cid: int = _data_core_world.component_id(name)
	if cid < 0:
		return
	_data_core_world.write_f32_indexed(cid, indices, values)


func _push_u8_to_world(name: StringName, indices: PackedInt32Array, values: PackedByteArray) -> void:
	if _data_core_world == null:
		return
	var cid: int = _data_core_world.component_id(name)
	if cid < 0:
		return
	_data_core_world.write_u8_indexed(cid, indices, values)


# Daily Sim SoA Refactor 方向 X：Pass A — 全 cell 写"裸基线 temp/moisture/
# snow_cover + EMA"。读 cell.elevation/base_moisture/terrain（稳定字段），
# 写 cell.temperature / moisture / snow_cover / temp_baseline / temp_season_offset
# / temp_30d_mean / temp_365d_mean / temp_dev_from_annual。
func _climate_pass_a(map: MapData, season_phase: float) -> void:
	var cp := _c()
	if cp == null or _last_cfg == null:
		return
	var days_per_year: int = _calendar_days_per_year()
	var annual_ema_alpha: float = 1.0 / float(days_per_year)

	# [DIAG mask_dirty=2400 排查 · 2026-05-20] 入口 flag dump（仅前 3 个 round，
	# 之后按 WorldClock 年长节流）。诊断完成后整段删除。
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_climate_pass_a / use_data_core_climate
	# flag 已删除——这里保留原原生 DIAG 输出格式不变，但打印常量 true。
	if _daily_climate_call_count <= 3 or _is_annual_log_tick(_daily_climate_call_count):
		print("[DIAG pass_a_entry] day=%d phase=%.3f gdext_pass_a=%s use_data_core_climate=%s use_soa_pipeline=%s use_sparse_climate=%s ext_bound=%s" % [
			_daily_climate_call_count, season_phase,
			"true",
			"true",
			str(bool(cp.use_soa_pipeline)),
			str(bool(cp.use_sparse_climate)),
			str(_data_core_world_ext != null),
		])

	# dots-roadmap-to-gdextension 务实 A — climate Pass-A C++ 加速路由。
	# 三态路径优先级：
	#   1. C++（DCWorldExt.run_climate_pass_a） — _data_core_world_ext 已 bind 时尝试；
	#      返回 < 0 视作 "未实装/拒绝"，静默 fallback 到下一档（snapshot contract
	#      见 world_ext.cpp）。
	#   2. DataCore SoA（_climate_pass_a_soa） — 当 use_soa_pipeline=true 走此路。
	#   3. Legacy 强类型成员循环 — 默认路径。
	# 注意：本路由只在 _climate_pass_a 入口做一次判断；hot path 完全不动。
	# 任何 C++ 端异常 / -1 返回都让 GDScript 路径接管，不抛 error 不打 push_warning
	# 以避免 frame 内日志炸开（首日由 _setup_sus 的 [DataCore] _data_core_world_ext
	# bound 行体现整体路径状态）。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_climate_pass_a / use_data_core_climate
	# 两个闸门 flag 已删除——现恒走 ext+has_method 探测单边分支。
	if _data_core_world_ext != null and map != null:
		# §11.2: Pass-A is the first C++ pass in the pipeline. Refresh all
		# slots from MapData so C++ reads GDScript-side changes since last flush.
		# refresh-consolidation-2026-06：改走 round 守门员，整个 climate daily round
		# 内多次调用收编为最多 ~3 次实际 refresh。详见 _ensure_climate_daily_round_slots_fresh。
		_ensure_climate_daily_round_slots_fresh()
		# Step 3b-1: 真实 cp_struct packing。
		# 这些字段必须与 world_ext.cpp::run_climate_pass_a 第 3 节读取顺序一一对应。
		# 任何字段缺失 / 类型不符都会让 C++ 端 return -1.0；strict-native 下保留上一帧结果。
		# truth source for 各 cp.xxx 字段：scripts/geography/climate_profile.gd。
		# 日照/昼长/热输入由 C++ pass 逐格写入 SoA，不再从 GDScript 打包日照 LUT。
		var cp_struct: Dictionary = {
			"use_insol":        true,
			"use_sparse":       bool(cp.use_sparse_climate),
			"insol_amp":        float(cp.season_temp_amp) if "season_temp_amp" in cp else 0.20,
			"insol_gain":       float(cp.insolation_season_gain) if "insolation_season_gain" in cp else 1.0,
			"moist_scale_now":  1.0,
			"season_phase":     float(season_phase),
			"days_per_year":    _calendar_days_per_year(),
			"axial_tilt_deg":   float(cp.axial_tilt_deg) if "axial_tilt_deg" in cp else 23.5,
			"day_length_gain":  float(cp.insolation_daylen_amp) if "insolation_daylen_amp" in cp else 0.35,
			"solar_gain":       float(cp.solar_gain) if "solar_gain" in cp else 1.0,
			"insol_dev_min":    float(cp.insolation_dev_clamp_min) if "insolation_dev_clamp_min" in cp else -1.0,
			"insol_dev_max":    float(cp.insolation_dev_clamp_max) if "insolation_dev_clamp_max" in cp else 1.0,
			"thermal_inertia_land": float(cp.thermal_inertia_land) if "thermal_inertia_land" in cp else 0.35,
			"thermal_inertia_water": float(cp.thermal_inertia_water) if "thermal_inertia_water" in cp else 0.07,
			"thermal_inertia_snow": float(cp.thermal_inertia_snow) if "thermal_inertia_snow" in cp else 0.09,
			"thermal_inertia_high_mountain": float(cp.thermal_inertia_high_mountain) if "thermal_inertia_high_mountain" in cp else 0.16,
			"thermal_daily_delta_cap": float(cp.thermal_daily_delta_cap) if "thermal_daily_delta_cap" in cp else 0.15,
			"temp_land_continentality": float(cp.temp_land_continentality) if "temp_land_continentality" in cp else 1.55,
			"thermal_dt_days": _consume_climate_dt_days(),
			"snowpack_cover_low": float(cp.snowpack_cover_low) if "snowpack_cover_low" in cp else 0.05,
			"snowpack_cover_full": float(cp.snowpack_cover_full) if "snowpack_cover_full" in cp else 0.32,
			"sea_level":        float(_last_cfg.sea_level),
		}
		var rc: float = -1.0
		# dots-flag-prune-pr1 round 2: use_gdext_thread_fallback flag 已删除——恒走
		# C++ scalar 入口 run_climate_pass_a，C++ 内部根据 CPU 特性 / n_cells 自动选择
		# scalar / SIMD / threaded 三档执行路径。
		rc = float(_data_core_world_ext.run_climate_pass_a(cp_struct, float(season_phase), float(season_phase)))
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] C++ Pass-A 路径 rc + DCWorld dirty
		# 即时观测：rc>=0 表示 C++ 接管并已 return；此处 peek 一次 dirty count 看 C++
		# 端是否在 set() 推回 MapData 时也副作用 mark 到 DCWorld（理论上不会）。
		if _daily_climate_call_count <= 3 or _is_annual_log_tick(_daily_climate_call_count):
			var _dirty_after_cpp: int = -1
			if _data_core_world != null and _data_core_world.has_method("peek_dirty_count"):
				_dirty_after_cpp = int(_data_core_world.peek_dirty_count())
			print("[DIAG pass_a_cpp] day=%d rc=%.4f cpp_taken_over=%s dirty_count_after_cpp=%d" % [
				_daily_climate_call_count, rc, str(rc >= 0.0), _dirty_after_cpp
			])
		if rc >= 0.0:
			# C++ 路径已接管整段 Pass-A 并已通过 set() 把结果推回 MapData。
			# 与 SoA 路径一样，这里直接返回；其余 sub-pass（B/ocean/sea_ice/transp）
			# 继续读 map.*_arr 强类型字段，与 GDScript 路径无差异。
			# 但 C++ 直接写 MapData 会绕过 GDScript SoA value-diff 路径；
			# dynamic visual atlas 依赖 DCWorld dirty mask，因此这里显式发布一次
			# 全气候 dirty，避免温度/雪/海冰 GPU Atlas 滞后到下一次全量 sweep。
			var native_dirty_cells: int = 0
			if map != null and map.has_method("cell_count"):
				native_dirty_cells = int(map.cell_count())
			elif map != null and map.has_method("all_cells"):
				native_dirty_cells = int(map.all_cells().size())
			_pa_last_total_cells = native_dirty_cells
			_pa_last_pushed_cells = native_dirty_cells
			if map != null and map.has_method("mark_all_climate_dirty"):
				map.mark_all_climate_dirty()
			if _data_core_world != null and _data_core_world.has_method("mark_dirty_all"):
				_data_core_world.mark_dirty_all()
			return
		push_warning("[climate/pass_a] native path failed; keeping previous climate fields for strict-native simulation")
		return

	# Climate-Weather 2ms Budget — Phase A.3：SoA pipeline 分发。
	# use_soa_pipeline = true 时，走 SoA 路径重写的热循环；legacy 路径仅作为默认 / 回退。
	if cp.use_soa_pipeline and map != null and map.has_soa():
		_climate_pass_a_soa(map, season_phase, cp)
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

	# 日照链条是运行时唯一气候相位来源：season_phase 只作为轨道相位进入太阳几何。
	if not _insol_driven_path_logged:
		var subsolar_deg: float = rad_to_deg(_subsolar_lat_rad(season_phase))
		var equator_mean: float = _insolation_annual_mean(0.5)
		print("[climate] insolation-driven path active: subsolar_lat=%+.1f°, equator_annual_mean=%.3f, tilt=%.1f°" % [
			subsolar_deg, equator_mean, float(cp.axial_tilt_deg)
		])
		_insol_driven_path_logged = true

	# 湿度由 native weather/climate 字段演化；旧四季湿度表不再作为输入。
	var moist_scale_now: float = 1.0
	var axial_tilt_deg: float = float(cp.get("axial_tilt_deg")) if cp.get("axial_tilt_deg") != null else 23.5
	var daylen_amp: float = float(cp.get("insolation_daylen_amp")) if cp.get("insolation_daylen_amp") != null else _INSOLATION_DAYLEN_AMP
	var solar_gain: float = float(cp.get("solar_gain")) if cp.get("solar_gain") != null else 1.0
	var insol_amp: float = float(cp.get("season_temp_amp")) if cp.get("season_temp_amp") != null else 0.20
	var insol_gain: float = float(cp.get("insolation_season_gain")) if cp.get("insolation_season_gain") != null else 1.0
	var insol_amp_gain: float = insol_amp * insol_gain
	var insol_dev_min: float = float(cp.get("insolation_dev_clamp_min")) if cp.get("insolation_dev_clamp_min") != null else -1.0
	var insol_dev_max: float = float(cp.get("insolation_dev_clamp_max")) if cp.get("insolation_dev_clamp_max") != null else 1.0
	# Legacy telemetry only. 不用于数值判定。
	var season_idx: int = int(floor(fposmod(season_phase, 4.0))) & 3

	# PR-2.1.1（climate Pass-A 写路径下移）：legacy fallback 9 写位预分配 batch buffer。
	# 详见 docs/dots-master-execution-handbook.md §3.4 + §9.2 模板 2。
	#   - 8 个 f32 字段：temp / moisture / snow_cover / temp_baseline / temp_season_offset
	#                   / temp_30d / temp_365d / temp_anomaly
	#   - 1 个 u8 字段：_ema_initialized
	#   - 一次循环结束后批量 write_*_indexed，避免每 idx CoW
	var _pa_cells: Array = map.all_cells()
	var _pa_n: int = map.cell_count() if map.has_method("cell_count") else _pa_cells.size()
	var _pa_indices: PackedInt32Array = PackedInt32Array()
	var _pa_temp: PackedFloat32Array = PackedFloat32Array()
	var _pa_moist: PackedFloat32Array = PackedFloat32Array()
	var _pa_temp_baseline: PackedFloat32Array = PackedFloat32Array()
	var _pa_temp_season_off: PackedFloat32Array = PackedFloat32Array()
	var _pa_temp_30d: PackedFloat32Array = PackedFloat32Array()
	var _pa_temp_365d: PackedFloat32Array = PackedFloat32Array()
	var _pa_temp_anom: PackedFloat32Array = PackedFloat32Array()
	var _pa_insol_now: PackedFloat32Array = PackedFloat32Array()
	var _pa_insol_dev: PackedFloat32Array = PackedFloat32Array()
	var _pa_day_length: PackedFloat32Array = PackedFloat32Array()
	var _pa_heat_input: PackedFloat32Array = PackedFloat32Array()
	var _pa_ema_init: PackedByteArray = PackedByteArray()
	_pa_indices.resize(_pa_n)
	_pa_temp.resize(_pa_n)
	_pa_moist.resize(_pa_n)
	_pa_temp_baseline.resize(_pa_n)
	_pa_temp_season_off.resize(_pa_n)
	_pa_temp_30d.resize(_pa_n)
	_pa_temp_365d.resize(_pa_n)
	_pa_temp_anom.resize(_pa_n)
	_pa_insol_now.resize(_pa_n)
	_pa_insol_dev.resize(_pa_n)
	_pa_day_length.resize(_pa_n)
	_pa_heat_input.resize(_pa_n)
	_pa_ema_init.resize(_pa_n)
	var _pa_write_i: int = 0

	for _pa_cell_i in range(_pa_cells.size()):
		var cell: HexCell = _pa_cells[_pa_cell_i]
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

		# A.2.1.B — Pass-A push 稀疏化（legacy fallback 路径 M1）：
		# 在写回 cell.* 之前先读旧值，循环末按 ε 决定是否进入 push 列表。
		# 与 SoA 路径同款阈值（_DIRTY_EPS_TEMP/MOIST/SNOW = 1/512 / 1/512 / 1/256）。
		# 首次（ema_was_init=false）强制收集 → push 一次完整 baseline，避免长尾。
		var _prev_t_legacy: float = cell.temperature
		var _prev_m_legacy: float = cell.moisture

		# —— 1) 太阳几何：直射点/日照/昼长 → 日照异常 ——
		var ny: float = _cube_row_norm(cell, _last_cfg)
		var insol_now: float = DCClimateMath.compute_daily_insolation(ny, season_phase, axial_tilt_deg, daylen_amp)
		var insol_mean: float = _insolation_annual_mean(ny)
		var dev_today: float = clampf(DCClimateMath.compute_insolation_dev_from_values(ny, insol_now, insol_mean), insol_dev_min, insol_dev_max)
		var day_length: float = DCClimateMath.compute_day_length_norm(ny, season_phase, axial_tilt_deg)
		var heat_input: float = clampf(insol_now * solar_gain, 0.0, 1.0)
		var cell_idx: int = int(cell.index) if cell.index >= 0 else _pa_cell_i
		if cell_idx >= 0 and cell_idx < map.insolation_now_arr.size():
			map.insolation_now_arr[cell_idx] = insol_now
		if cell_idx >= 0 and cell_idx < map.insolation_dev_arr.size():
			map.insolation_dev_arr[cell_idx] = dev_today
		if cell_idx >= 0 and cell_idx < map.day_length_arr.size():
			map.day_length_arr[cell_idx] = day_length
		if cell_idx >= 0 and cell_idx < map.heat_input_arr.size():
			map.heat_input_arr[cell_idx] = heat_input

		# —— 2) 当日湿度：水汽基线由当前日照异常调制 ——
		var moisture_now: float
		if _is_water(cell.terrain):
			moisture_now = cell.base_moisture
		else:
			var scale_eff: float = moist_scale_now * (1.0 + 0.2 * dev_today)
			moisture_now = clampf(cell.base_moisture * scale_eff, 0.0, 1.0)

		# —— 3) 当日温度：日照异常生成辐射目标，后续路径再施加热惯性 ——
		# 物理化（2026-06-16）：季节项按吸收短波因子缩放（持久冰封→低吸收），与 SoA/C++ 同源。
		# 用【年均温度 cell.temp_365d_mean】作冰封代理，避免夏季融化正反馈失控。
		var temp_year: float = _compute_temperature(ny, cell.elevation)
		var absorb_factor: float = DCClimateMath.surface_absorbed_factor(_is_water(cell.terrain), cell.temp_365d_mean)
		# 冷侧软压缩（v2）：极向热输送/海洋热库托底，防中纬冬季无限过冷。与 SoA/C++ 同源。
		var season_offset: float = DCClimateMath.compress_season_cooling(insol_amp_gain * absorb_factor * dev_today)
		var temp_now: float = clampf(temp_year + season_offset, 0.0, 1.0)

		# —— 4) 写回 current_state（只更新连续字段，biome/landform/vegetation/cover 由 refresh_seasonal 维护） ——
		# Fast-tick perf opt (C)：temperature / moisture / snow_cover / temp_baseline /
		# temp_season_offset / temp_30d_mean / temp_365d_mean / temp_dev_from_annual 已
		# 升级为 HexCell 的强类型成员，这里直接赋值，不再走 current_state 字典路径，
		# 显著减少 GDScript 字典 hash 查找 + Variant 装箱开销。
		cell.current_state["season"] = season_idx
		# PR-2.1.1：双写保留（cell.* 仍写，PR-2.3 facade 化时由 setter 路由到 world）。
		cell.temperature = temp_now
		cell.moisture = moisture_now
		cell.temp_baseline = temp_year
		cell.temp_season_offset = season_offset

		# —— 5) True Insolation-Driven：温度 EMA（30 日 / 日历年长）用于"观测月份"面板派生 ——
		# α_30 ≈ 1/30、α_year ≈ 1/days_per_year；首次出现时用 temp_now 初始化避免长尾收敛拖影。
		# Fast-tick perf opt (C)：用 < 0 哨兵判"首次"，现在改用独立 bool 标志——
		# temp_30d_mean / temp_365d_mean 默认 0.0 是合法气候值，不能靠值域判"未初始化"。
		# 这里用 cell._ema_initialized 作为一次性标志。
		var m30: float
		var m365: float
		var ema_was_init: bool = cell._ema_initialized
		if not ema_was_init:
			m30 = temp_now
			m365 = temp_now
			cell._ema_initialized = true
		else:
			m30 = lerpf(cell.temp_30d_mean, temp_now, 1.0 / 30.0)
			m365 = lerpf(cell.temp_365d_mean, temp_now, annual_ema_alpha)
		cell.temp_30d_mean = m30
		cell.temp_365d_mean = m365
		cell.temp_dev_from_annual = m30 - m365

		# A.2.1.B — ε 比对决定是否进入 push 列表。
		# 首次 EMA 初始化 / current_state 刚建骨架 → 视为"baseline 必推"。
		# 否则三主字段 (T/M/S) 任一变化幅度 > ε 才 push。
		var _force_push_legacy: bool = not ema_was_init
		var _need_push_legacy: bool = _force_push_legacy
		if not _need_push_legacy:
			var _dt_abs: float = temp_now - _prev_t_legacy
			if _dt_abs < 0.0: _dt_abs = -_dt_abs
			if _dt_abs > _PUSH_EPS_TEMP:
				_need_push_legacy = true
		if not _need_push_legacy:
			var _dm_abs: float = moisture_now - _prev_m_legacy
			if _dm_abs < 0.0: _dm_abs = -_dm_abs
			if _dm_abs > _PUSH_EPS_MOIST:
				_need_push_legacy = true

		# PR-2.1.1：收集 dirty entry（每 cell 一行，9 字段一次性下移到 SoA）。
		var _pa_idx: int = cell_idx
		if _need_push_legacy and _pa_idx >= 0 and _pa_write_i < _pa_n:
			_pa_indices[_pa_write_i] = _pa_idx
			_pa_temp[_pa_write_i] = temp_now
			_pa_moist[_pa_write_i] = moisture_now
			_pa_temp_baseline[_pa_write_i] = temp_year
			_pa_temp_season_off[_pa_write_i] = season_offset
			_pa_temp_30d[_pa_write_i] = m30
			_pa_temp_365d[_pa_write_i] = m365
			_pa_temp_anom[_pa_write_i] = m30 - m365
			_pa_insol_now[_pa_write_i] = insol_now
			_pa_insol_dev[_pa_write_i] = dev_today
			_pa_day_length[_pa_write_i] = day_length
			_pa_heat_input[_pa_write_i] = heat_input
			_pa_ema_init[_pa_write_i] = 1  # 当前 cell 已经走过 init 分支或正常 EMA 更新，标记"已初始化"
			_pa_write_i += 1

	# PR-2.1.1：循环结束后批量提交 9 字段到 DCWorld SoA（helper 内部守卫
	# _data_core_world / cid，故此处只判 write_i > 0）。
	if _pa_write_i > 0:
		_pa_indices.resize(_pa_write_i)
		_pa_temp.resize(_pa_write_i)
		_pa_moist.resize(_pa_write_i)
		_pa_temp_baseline.resize(_pa_write_i)
		_pa_temp_season_off.resize(_pa_write_i)
		_pa_temp_30d.resize(_pa_write_i)
		_pa_temp_365d.resize(_pa_write_i)
		_pa_temp_anom.resize(_pa_write_i)
		_pa_insol_now.resize(_pa_write_i)
		_pa_insol_dev.resize(_pa_write_i)
		_pa_day_length.resize(_pa_write_i)
		_pa_heat_input.resize(_pa_write_i)
		_pa_ema_init.resize(_pa_write_i)
		_push_f32_to_world(DCComponentIds.CELL_TEMP, _pa_indices, _pa_temp)
		_push_f32_to_world(DCComponentIds.CELL_MOISTURE, _pa_indices, _pa_moist)
		# 长期均值字段：mean_diff ≤ 0.005 红线（master 手册 §3.4.3）
		_push_f32_to_world(DCComponentIds.CELL_TEMP_BASELINE, _pa_indices, _pa_temp_baseline)
		_push_f32_to_world(DCComponentIds.CELL_TEMP_SEASON_OFFSET, _pa_indices, _pa_temp_season_off)
		_push_f32_to_world(DCComponentIds.CELL_TEMP_30D, _pa_indices, _pa_temp_30d)
		_push_f32_to_world(DCComponentIds.CELL_TEMP_365D, _pa_indices, _pa_temp_365d)
		_push_f32_to_world(DCComponentIds.CELL_TEMP_ANOMALY, _pa_indices, _pa_temp_anom)
		_push_f32_to_world(DCComponentIds.CELL_INSOLATION_NOW, _pa_indices, _pa_insol_now)
		_push_f32_to_world(DCComponentIds.CELL_INSOLATION_DEV, _pa_indices, _pa_insol_dev)
		_push_f32_to_world(DCComponentIds.CELL_DAY_LENGTH, _pa_indices, _pa_day_length)
		_push_f32_to_world(DCComponentIds.CELL_HEAT_INPUT, _pa_indices, _pa_heat_input)
		_push_u8_to_world(DCComponentIds.CELL_EMA_INITIALIZED, _pa_indices, _pa_ema_init)
	if _pa_n > 0:
		var _pa_astronomy_indices: PackedInt32Array = PackedInt32Array()
		_pa_astronomy_indices.resize(_pa_n)
		for _pa_ai in range(_pa_n):
			_pa_astronomy_indices[_pa_ai] = _pa_ai
		_push_f32_to_world(DCComponentIds.CELL_INSOLATION_NOW, _pa_astronomy_indices, map.insolation_now_arr)
		_push_f32_to_world(DCComponentIds.CELL_INSOLATION_DEV, _pa_astronomy_indices, map.insolation_dev_arr)
		_push_f32_to_world(DCComponentIds.CELL_DAY_LENGTH, _pa_astronomy_indices, map.day_length_arr)
		_push_f32_to_world(DCComponentIds.CELL_HEAT_INPUT, _pa_astronomy_indices, map.heat_input_arr)
	# A.2.1.B — 同步 push 统计（legacy fallback 路径，配合 SoA 路径统一 perf 输出）
	_pa_last_pushed_cells = _pa_write_i
	_pa_last_total_cells = _pa_n

# Daily Sim SoA Refactor 方向 X：Pass B — 局部气候耦合。
# 调用方负责守卫 enable_local_climate_coupling 开关。season_phase 只作为轨道
# 相位传入，地貌热响应读取 Pass-A 写出的 cell_insolation_dev。
func _climate_pass_b(map: MapData, season_phase: float) -> void:
	var cp := _c()
	if cp == null or _last_cfg == null:
		return
	# Climate-Weather 2ms Budget — Phase A.3：SoA pipeline 分发。
	if cp.use_soa_pipeline and map != null and map.has_soa():
		_climate_pass_b_soa(map, season_phase, cp)
		return
	# 沿岸热泄漏不再用独立冬季倍率；冷热来自洋流/海陆热惯性/日照链条。
	var winter_boost: float = 1.0
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

	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var nb_idx_arr: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var has_idx: bool = nb_idx_arr.size() >= n_cells * 6
	var snowpack_cover_low: float = float(cp.get("snowpack_cover_low")) if cp.get("snowpack_cover_low") != null else 0.05
	var snowpack_cover_full: float = float(cp.get("snowpack_cover_full")) if cp.get("snowpack_cover_full") != null else 0.32
	var has_snowpack_arr: bool = map.snowpack_arr.size() == n_cells
	var temp_snapshot := PackedFloat32Array()
	temp_snapshot.resize(n_cells)
	var cell_pos := PackedVector2Array()
	var need_cell_pos: bool = has_idx and rs_lookback > 0
	if need_cell_pos:
		cell_pos.resize(n_cells)
	for i in range(n_cells):
		var snap_cell: HexCell = cells[i]
		temp_snapshot[i] = snap_cell.temperature
		if need_cell_pos:
			cell_pos[i] = HexUtils.cube_to_world(snap_cell.q, snap_cell.r, _last_hex_size)

	# PR-2.1.2（climate Pass-B legacy 写路径下移）：预分配 batch buffer。
	# 详见 docs/dots-master-execution-handbook.md §3.5。
	var _pb_indices: PackedInt32Array = PackedInt32Array()
	var _pb_temp: PackedFloat32Array = PackedFloat32Array()
	var _pb_moist: PackedFloat32Array = PackedFloat32Array()
	_pb_indices.resize(n_cells)
	_pb_temp.resize(n_cells)
	_pb_moist.resize(n_cells)

	# 按 cell 应用三项温度 + 三项湿度（其一在外部 transpiration pass）
	for i in range(n_cells):
		var cell: HexCell = cells[i]
		var temp_now: float = temp_snapshot[i]
		# Fast-tick perf opt (C)：moisture 已升级为强类型成员。
		var moisture_now: float = cell.moisture
		var snow_cover: float = 0.0
		if has_snowpack_arr and not _is_water(cell.terrain):
			snow_cover = smoothstep(snowpack_cover_low, snowpack_cover_full, map.snowpack_arr[i])
			if cell.cover == CoverType.CV.GLACIER and snow_cover < 0.80:
				snow_cover = 0.80

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
				var base: int = i * 6
				for d in range(6):
					var ni: int = nb_idx_arr[base + d]
					if ni < 0:
						continue
					var nb: HexCell = cells[ni]
					if _is_water(nb.terrain):
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

		# ③ 地形扰动：山谷/盆地放大当日本地日照偏差；高山只在日照不足时额外变冷。
		if not is_water:
			var idx_for_solar: int = int(cell.index) if cell.index >= 0 else i
			var solar_factor: float = 0.0
			if idx_for_solar >= 0 and idx_for_solar < map.insolation_dev_arr.size():
				solar_factor = clampf(map.insolation_dev_arr[idx_for_solar], -1.0, 1.0)
			else:
				solar_factor = clampf(_insol_dev(_cube_row_norm(cell, _last_cfg), season_phase), -1.0, 1.0)
			var lf: int = cell.landform
			if lf == LandformType.LF.LOWLAND or lf == LandformType.LF.SALT_FLAT or lf == LandformType.LF.DELTA:
				d_landform = diurnal_amp * solar_factor
			elif lf == LandformType.LF.PEAK or lf == LandformType.LF.MOUNTAIN:
				d_landform = -diurnal_amp * 0.5 * maxf(0.0, -solar_factor)

		# 写回温度
		var temp_final: float = clampf(temp_now + d_albedo + d_coastal + d_landform, 0.0, 1.0)
		# Fast-tick perf opt (C)：直写强类型成员（双写，PR-2.3 facade 化前保留）。
		cell.temperature = temp_final
		_pb_indices[i] = int(cell.index) if cell.index >= 0 else i
		_pb_temp[i] = temp_final

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
				var base2: int = i * 6
				for d2 in range(6):
					var ni2: int = nb_idx_arr[base2 + d2]
					if ni2 < 0:
						continue
					var nb2: HexCell = cells[ni2]
					if _is_water(nb2.terrain):
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
				# 沿 -w_dir 方向逐步采样上风邻居（最对齐者）
				var probe: HexCell = cell
				var probe_idx: int = i
				for step in range(rs_lookback):
					var best_nb: HexCell = null
					var best_idx: int = -1
					var best_dot: float = 0.1
					# Daily-Sim SoA Refactor 阶段 2：通过索引数组取邻居，避免每
					# step 创建 6-元 Array。
					if has_idx:
						var pwp: Vector2 = cell_pos[probe_idx]
						var pbase: int = probe_idx * 6
						for d3 in range(6):
							var ni3: int = nb_idx_arr[pbase + d3]
							if ni3 < 0:
								continue
							var nbwp: Vector2 = cell_pos[ni3]
							var d: Vector2 = (pwp - nbwp)
							if d.length_squared() < 1e-6:
								continue
							var dotv: float = d.normalized().dot(w_dir)
							if dotv > best_dot:
								best_dot = dotv
								best_idx = ni3
					else:
						var pwp_fb: Vector2 = HexUtils.cube_to_world(probe.q, probe.r, _last_hex_size)
						for nb2: HexCell in map.get_neighbors(probe):
							if nb2 == null:
								continue
							var nbwp: Vector2 = HexUtils.cube_to_world(nb2.q, nb2.r, _last_hex_size)
							var d_fb: Vector2 = (pwp_fb - nbwp)
							if d_fb.length_squared() < 1e-6:
								continue
							var dotv: float = d_fb.normalized().dot(w_dir)
							if dotv > best_dot:
								best_dot = dotv
								best_nb = nb2
					if has_idx:
						if best_idx < 0:
							break
						probe_idx = best_idx
						probe = cells[probe_idx]
					else:
						if best_nb == null:
							break
						probe = best_nb
					if probe.elevation > max_upwind_h:
						max_upwind_h = probe.elevation
				if max_upwind_h - cell.elevation >= rs_threshold:
					d_rain_shadow = rs_factor

		# 写回湿度
		var moisture_final: float = clampf((moisture_now + d_evap) * d_rain_shadow, 0.0, 1.0)
		# Fast-tick perf opt (C)：moisture 已升级为强类型成员，直写（双写）。
		cell.moisture = moisture_final
		_pb_moist[i] = moisture_final

	# PR-2.1.2：循环结束后批量提交 cell.temperature / cell.moisture 到 DCWorld SoA。
	if _data_core_world != null and n_cells > 0:
		var _cid_temp_b: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
		if _cid_temp_b >= 0:
			_data_core_world.write_f32_indexed(_cid_temp_b, _pb_indices, _pb_temp)
		var _cid_moist_b: int = _data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
		if _cid_moist_b >= 0:
			_data_core_world.write_f32_indexed(_cid_moist_b, _pb_indices, _pb_moist)

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
# Plan: civ-grounded-development / 方案 ① Step 1（确诊辅助）
# sea_ice daily pass total_wall ≥ 5ms 时强制打印 breakdown 全字段，便于定位是
# 哪条路径（gdext / gdscript）+ 哪个阶段（pack / refresh / native / sync / flip）拖慢的。
# 不阻塞快路径；节流避免连续帧刷屏。
func _dump_sea_ice_breakdown_if_slow() -> void:
	if _last_sea_ice_daily_breakdown.is_empty():
		return
	var total_wall: float = float(_last_sea_ice_daily_breakdown.get("total_wall_ms", 0.0))
	if total_wall < _SEA_ICE_SLOW_DUMP_THRESHOLD_MS:
		return
	# 节流：30 fast tick 内最多打一次，避免连续帧刷屏。
	# _current_fast_tick_idx 由 main.gd._run_fast_tick 顶部同步，初始 0；
	# 首次触发时 last_tick=-10000，无论如何会打。
	if _current_fast_tick_idx - _sea_ice_slow_dump_last_tick < _SEA_ICE_SLOW_DUMP_MIN_INTERVAL:
		return
	_sea_ice_slow_dump_last_tick = _current_fast_tick_idx
	var b: Dictionary = _last_sea_ice_daily_breakdown
	print("[sea_ice/slow-dump] tick=%d path=%s total_wall=%.2fms (pack=%.2f refresh=%.2f native=%.2f native_wall=%.2f sync=%.2f flip=%.2f) water=%d flipped=%d" % [
		_current_fast_tick_idx,
		str(b.get("path", "?")),
		total_wall,
		float(b.get("pack_ms", 0.0)),
		float(b.get("refresh_ms", 0.0)),
		float(b.get("native_ms", -1.0)),
		float(b.get("native_wall_ms", 0.0)),
		float(b.get("sync_ms", 0.0)),
		float(b.get("flip_ms", 0.0)),
		int(b.get("water", 0)),
		int(b.get("flipped", 0)),
	])


# Plan: civ-grounded-development / weather cyclone 突刺一次性诊断（2026-05-21）
# 触发条件（任一）：
#   - weather_tick_ms ≥ 5.0   → 总 tick 突刺
#   - cyclone_ms      ≥ 3.0   → cyclone_wake_step 单段突刺（典型常态 0.15ms）
# 输出 _last_weather_breakdown 全字段：advance / spawn / distribute / cyclone /
#   stage_a/b 各段 / albedo / veg_dyn / cover_rebake / veg_rebake / feedback / fronts / path。
# 节流到至少 30 fast tick 间隔一次。
func _dump_weather_breakdown_if_slow() -> void:
	if _last_weather_breakdown.is_empty():
		return
	var total_wall: float = float(_last_weather_breakdown.get("weather_tick_ms", 0.0))
	var cyclone_ms_v: float = float(_last_weather_breakdown.get("cyclone_ms", 0.0))
	if total_wall < _WEATHER_SLOW_DUMP_TOTAL_THRESHOLD_MS \
			and cyclone_ms_v < _WEATHER_SLOW_DUMP_CYCLONE_THRESHOLD_MS:
		return
	if _current_fast_tick_idx - _weather_slow_dump_last_tick < _WEATHER_SLOW_DUMP_MIN_INTERVAL:
		return
	_weather_slow_dump_last_tick = _current_fast_tick_idx
	var b: Dictionary = _last_weather_breakdown
	print("[weather/slow-dump] tick=%d path=%s tick_ms=%.2f (adv=%.2f spawn=%.2f dist=%.2f cyc=%.2f stage_b=%.2f albedo=%.2f veg_dyn=%.2f feedback=%.2f cover_rb=%.2f veg_rb=%.2f) fronts=%d" % [
		_current_fast_tick_idx,
		str(b.get("path", "?")),
		total_wall,
		float(b.get("advance_ms", 0.0)),
		float(b.get("spawn_ms", 0.0)),
		float(b.get("distribute_ms", 0.0)),
		cyclone_ms_v,
		float(b.get("stage_b_ms", 0.0)),
		float(b.get("albedo_ms", 0.0)),
		float(b.get("veg_dyn_ms", 0.0)),
		float(b.get("feedback_ms", 0.0)),
		float(b.get("cover_rebake_ms", 0.0)),
		float(b.get("veg_rebake_ms", 0.0)),
		int(b.get("fronts", 0)),
	])
	# Phase B.2 cyclone 细粒度遥测：仅在 cyclone 段实际有耗时（≥0.5ms）且 C++
	# combined path 提供了 phase1/phase2 拆分时打印第二行。常态 cyclone≈0.15ms
	# 时此分支不触发，避免噪音；一旦未来真出现 cyclone 突刺立即可定位是衰减循环
	# (phase1) vs 注入循环 (phase2)、是大量 evict vs 大量 replace。
	var phase1_ms: float = float(b.get("cyclone_phase1_decay_ms", 0.0))
	var phase2_ms: float = float(b.get("cyclone_phase2_inject_ms", 0.0))
	if cyclone_ms_v >= 0.5 and (phase1_ms > 0.0 or phase2_ms > 0.0):
		print("[weather/slow-dump-cyclone] tick=%d phase1_decay=%.2fms phase2_inject=%.2fms (n_decayed=%d n_evicted=%d n_replaced=%d n_injected=%d pool_size=%d)" % [
			_current_fast_tick_idx,
			phase1_ms,
			phase2_ms,
			int(b.get("cyclone_n_decayed", 0)),
			int(b.get("cyclone_n_evicted", 0)),
			int(b.get("cyclone_n_replaced", 0)),
			int(b.get("cyclone_n_injected", 0)),
			int(b.get("cyclone_pool_size", 0)),
		])


func _sea_ice_slice_budget_cells() -> int:
	var cp := _c()
	var slice_ms: float = 0.75
	if cp != null and cp.get("sim_slice_budget_ms") != null:
		slice_ms = float(cp.sim_slice_budget_ms)
	return clampi(int(round(512.0 * clampf(slice_ms / 0.75, 0.5, 2.0))), 128, 1024)


func _sea_ice_solar_gate_enabled(cp) -> bool:
	return cp != null and cp.get("sea_ice_solar_gate_enabled") != null \
		and bool(cp.sea_ice_solar_gate_enabled)


func _sea_ice_freeze_gate(insolation_now: float, freeze_low: float, freeze_high: float) -> float:
	var hi: float = maxf(freeze_high, freeze_low + 0.001)
	return clampf(1.0 - smoothstep(freeze_low, hi, insolation_now), 0.0, 1.0)


func _sea_ice_solar_melt(insolation_now: float, melt_start: float, melt_gain: float) -> float:
	return maxf(0.0, melt_gain) * maxf(0.0, insolation_now - melt_start)


func _sea_ice_insolation_input(map: MapData, cells: Array, season_phase: float) -> PackedFloat32Array:
	var n_cells: int = cells.size()
	if map != null and map.insolation_now_arr.size() == n_cells:
		return map.insolation_now_arr
	if _gdext_sea_ice_insol_buf.size() != n_cells:
		_gdext_sea_ice_insol_buf.resize(n_cells)
	for i in range(n_cells):
		var c: HexCell = cells[i]
		_gdext_sea_ice_insol_buf[i] = _compute_insolation(_cube_row_norm(c, _last_cfg), season_phase) \
			if c != null and _last_cfg != null else 0.0
	return _gdext_sea_ice_insol_buf


func _abort_sea_ice_state_machine(reason: String = "abort") -> void:
	if _sea_ice_state_machine.is_empty():
		return
	_sea_ice_state_machine["status"] = _CLIMATE_PASS_STATUS_ABORTED
	_sea_ice_state_machine["abort_reason"] = reason
	_sea_ice_state_machine["ended_msec"] = Time.get_ticks_msec()
	_sea_ice_state_machine = {}


func _begin_sea_ice_state_machine(map: MapData, season_phase: float, token: int) -> bool:
	if map == null or _last_cfg == null:
		return false
	var cp := _c()
	if cp == null:
		return false
	var cells_fast: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_fast: int = cells_fast.size()
	var nb_idx_fast: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = nb_idx_fast.size() >= n_cells_fast * 6
	if _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_sea_ice_daily_pass") \
			or not fast_indexed:
		return false
	if not _gdext_sea_ice_signature_checked:
		_gdext_sea_ice_signature_checked = true
		_gdext_sea_ice_signature_ok = _validate_gdext_method_signature("run_sea_ice_daily_pass", 2)
		print("[sea_ice/F.4] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_gdext_sea_ice_signature_ok))

	var k_freeze: float = float(cp.sea_ice_freeze_rate)
	var k_melt: float = float(cp.sea_ice_melt_rate)
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var contagion: float = float(cp.sea_ice_neighbor_contagion)
	var threshold: float = float(cp.sea_ice_terrain_threshold)
	var hysteresis: float = float(cp.sea_ice_terrain_hysteresis)
	var ice_delay: float = float(_last_cfg.OCEAN_CURRENT_ICE_DELAY)
	var climate_anomaly_now: float = 0.0
	if _world_clock_ref != null:
		var ca_v = _world_clock_ref.get("climate_anomaly")
		if ca_v != null:
			climate_anomaly_now = float(ca_v)
	if not is_equal_approx(climate_anomaly_now, 0.0):
		var ice_thr_shift: float = 0.10 * climate_anomaly_now
		t_form = clampf(t_form - ice_thr_shift, 0.0, 1.0)
		t_melt = clampf(t_melt - ice_thr_shift, 0.0, 1.0)

	# ─── sea_ice dt_days 补偿（状态机入口路径）────────────────────────────
	# C++ 路径传 per-day k + dt_days；GDScript fallback 才在本地公式中乘 dt。
	# 这样既补偿 SUS sliced 调度间隔，又避免 native 路径出现 dt^2 过冲。
	var dt_days: float = _consume_sea_ice_dt_days()
	var k_freeze_scaled: float = k_freeze * dt_days
	var k_melt_scaled: float = k_melt * dt_days

	var t_total_us: int = Time.get_ticks_usec()
	var t_pack_us: int = Time.get_ticks_usec()
	var base_terrain_input: PackedByteArray
	if map.base_terrain_arr.size() == n_cells_fast:
		base_terrain_input = map.base_terrain_arr
	else:
		if _gdext_sea_ice_base_terrain_buf.size() != n_cells_fast:
			_gdext_sea_ice_base_terrain_buf.resize(n_cells_fast)
		base_terrain_input = _gdext_sea_ice_base_terrain_buf
		for i_build in range(n_cells_fast):
			var c_build: HexCell = cells_fast[i_build]
			_gdext_sea_ice_base_terrain_buf[i_build] = int(c_build.base_terrain) & 0xFF
	var tta_input: PackedFloat32Array
	if _gdext_ocean_anomaly_buf_cached.size() == n_cells_fast:
		tta_input = _gdext_ocean_anomaly_buf_cached
	elif map.temperature_transport_anomaly_arr.size() == n_cells_fast:
		tta_input = map.temperature_transport_anomaly_arr
	else:
		if _gdext_sea_ice_tta_buf.size() != n_cells_fast:
			_gdext_sea_ice_tta_buf.resize(n_cells_fast)
		tta_input = _gdext_sea_ice_tta_buf
		for i_tta in range(n_cells_fast):
			tta_input[i_tta] = cells_fast[i_tta].temperature_transport_anomaly
	var upw_input: PackedFloat32Array = map.upwelling_strength_arr \
			if map.upwelling_strength_arr.size() == n_cells_fast \
			else _gdext_sea_ice_upw_buf
	if upw_input.size() != n_cells_fast:
		_gdext_sea_ice_upw_buf.resize(n_cells_fast)
		upw_input = _gdext_sea_ice_upw_buf
		for i_upw in range(n_cells_fast):
			upw_input[i_upw] = cells_fast[i_upw].upwelling_strength
	var temp_input: PackedFloat32Array = map.temp_arr \
			if map.temp_arr.size() == n_cells_fast \
			else _gdext_sea_ice_temp_buf
	if temp_input.size() != n_cells_fast:
		_gdext_sea_ice_temp_buf.resize(n_cells_fast)
		temp_input = _gdext_sea_ice_temp_buf
		for i_temp in range(n_cells_fast):
			temp_input[i_temp] = cells_fast[i_temp].temperature
	var insol_input: PackedFloat32Array = _sea_ice_insolation_input(map, cells_fast, season_phase)
	var pack_ms: float = (Time.get_ticks_usec() - t_pack_us) / 1000.0
	var water_ids: PackedByteArray = PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		int(TerrainType.TERRAIN.COAST) & 0xFF,
		int(TerrainType.TERRAIN.LAKE) & 0xFF,
		int(TerrainType.TERRAIN.REEF) & 0xFF,
		int(TerrainType.TERRAIN.KELP) & 0xFF,
		int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
	])
	var knobs: Dictionary = {
		"n_cells": n_cells_fast,
		# C++ 端会用 dt_days 乘一次；这里传原始 per-day 速率，避免 dt^2 过冲。
		"k_freeze": k_freeze,
		"k_melt": k_melt,
		"dt_days": dt_days,
		"t_form": t_form,
		"t_melt": t_melt,
		"contagion": contagion,
		"threshold": threshold,
		"hysteresis": hysteresis,
		"ice_delay": ice_delay,
		"enable_ocean_heat_transport": bool(_last_cfg.enable_ocean_heat_transport),
		"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
		"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
		"water_terrain_ids": water_ids,
		"neighbor_indices": nb_idx_fast,
		"base_terrain_arr": base_terrain_input,
		"temp_transport_anomaly": tta_input,
		"upwelling_strength": upw_input,
		"insolation_now_arr": insol_input,
		"solar_gate_enabled": _sea_ice_solar_gate_enabled(cp),
		"freeze_insol_low": float(cp.sea_ice_freeze_insol_low),
		"freeze_insol_high": float(cp.sea_ice_freeze_insol_high),
		"solar_melt_start": float(cp.sea_ice_solar_melt_start),
		"solar_melt_gain": float(cp.sea_ice_solar_melt_gain),
		"daily_delta_cap": float(cp.sea_ice_daily_delta_cap) if cp.get("sea_ice_daily_delta_cap") != null else 0.08,
		"cell_temperature_arr": temp_input,
	}
	var refresh_ms: float = 0.0
	if _data_core_world_ext.has_method("refresh_slots_from_map"):
		var t_refresh_us: int = Time.get_ticks_usec()
		_data_core_world_ext.refresh_slots_from_map()
		refresh_ms = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
	# [BUG-FIX 2026-05-23 海冰看似不动] 在 C++ pass 修改 SIF 之前，先 snapshot
	# pre-pass 状态。dense_sync_chunk 阶段会用它和 post-pass 比对，对真正变化
	# 的 cell 调 mark_dirty_indexed —— 否则 atlas pipeline 永远拿不到 SIF dirty。
	# 见 _run_sea_ice_state_machine_slice DENSE_SYNC_CHUNK 分支注释。
	var pre_sif_snapshot: PackedFloat32Array = PackedFloat32Array()
	if map.sea_ice_frac_arr.size() == n_cells_fast:
		pre_sif_snapshot = map.sea_ice_frac_arr.duplicate()
	var t_native_us: int = Time.get_ticks_usec()
	var rc: float = float(_data_core_world_ext.run_sea_ice_daily_pass(knobs, season_phase))
	var dispatch_path: String = "scalar"
	if rc < 0.0 and _data_core_world_ext.has_method("run_sea_ice_daily_pass_thread"):
		dispatch_path = "thread_fallback"
		rc = float(_data_core_world_ext.run_sea_ice_daily_pass_thread(knobs, season_phase, 4))
	var native_wall_ms: float = (Time.get_ticks_usec() - t_native_us) / 1000.0
	if rc < 0.0:
		_gdext_sea_ice_fallbacks += 1
		return false
	var facade_on: bool = false
	if n_cells_fast > 0 and cells_fast[0] != null:
		var c0_sync: HexCell = cells_fast[0] as HexCell
		facade_on = c0_sync != null and c0_sync.is_facade_enabled()
	_sea_ice_state_machine = {
		"token": token,
		"map_id": map.get_instance_id(),
		"season_phase": season_phase,
		"stage": _SEA_ICE_STAGE_DENSE_SYNC_CHUNK,
		"cells": cells_fast,
		"n": n_cells_fast,
		"facade_on": facade_on,
		"sync_cursor": 0,
		"flip_cursor": 0,
		"flip_to_ice_list": knobs.get("flip_to_ice_list", PackedInt32Array()),
		"flip_to_base_list": knobs.get("flip_to_base_list", PackedInt32Array()),
		"flip_to_base_terrain": knobs.get("flip_to_base_terrain", PackedByteArray()),
		"pack_ms": pack_ms,
		"refresh_ms": refresh_ms,
		"native_ms": rc,
		"native_wall_ms": native_wall_ms,
		"sync_ms": 0.0,
		"flip_ms": 0.0,
		"total_start_us": t_total_us,
		"water": int(knobs.get("stat_water_count", 0)),
		"flipped": int(knobs.get("stat_flipped_count", 0)),
		"dispatch_path": dispatch_path,
		# [BUG-FIX 2026-05-23 海冰看似不动] pre-pass SIF 快照：dense_sync_chunk 用
		# 来比对找真正变化 cell + 显式 mark_dirty_indexed。见同函数注释。
		"pre_sif_snapshot": pre_sif_snapshot,
		"dirty_marked_count": 0,
	}
	# [DIAG 2026-05-23] 海冰不动排障：状态机入口（实际运行主路径）。
	# 每个日历年长 + 前 5 次打印一次温度 / SIF 分布。
	# 关键问诊：t_eff 实际有没有 < t_form？SIF 是否在累积但卡在 threshold 下？
	if _gdext_sea_ice_runs < 5 or _is_annual_log_tick(_gdext_sea_ice_runs):
		var _diag_water: int = 0
		var _diag_below_form: int = 0
		var _diag_sif_pos: int = 0
		var _diag_sif_near_thr: int = 0
		var _diag_t_min: float = 9.99
		var _diag_t_max: float = -9.99
		var _diag_t_sum: float = 0.0
		var _diag_t_min_water: float = 9.99
		var _diag_sif_max: float = 0.0
		var _diag_sif_sum: float = 0.0
		var _diag_d_frac_max: float = 0.0    # 单 cell 单 pass 最大 d_frac 估算
		var _terrain_arr_diag: PackedByteArray = map.terrain_arr
		var _sif_arr_diag: PackedFloat32Array = map.sea_ice_frac_arr
		var _temp_n: int = temp_input.size()
		var _sif_n: int = _sif_arr_diag.size()
		var _terr_n: int = _terrain_arr_diag.size()
		for _i_diag in range(n_cells_fast):
			var _t_d: float = temp_input[_i_diag] if _i_diag < _temp_n else 0.0
			if _t_d < _diag_t_min: _diag_t_min = _t_d
			if _t_d > _diag_t_max: _diag_t_max = _t_d
			_diag_t_sum += _t_d
			var _terr_d: int = int(_terrain_arr_diag[_i_diag]) if _i_diag < _terr_n else -1
			var _is_w: bool = (_terr_d == int(TerrainType.TERRAIN.OCEAN) \
				or _terr_d == int(TerrainType.TERRAIN.COAST) \
				or _terr_d == int(TerrainType.TERRAIN.REEF) \
				or _terr_d == int(TerrainType.TERRAIN.KELP) \
				or _terr_d == int(TerrainType.TERRAIN.SEA_ICE))
			if _is_w:
				_diag_water += 1
				if _t_d < _diag_t_min_water: _diag_t_min_water = _t_d
				if _t_d < t_form:
					_diag_below_form += 1
					var _df: float = k_freeze_scaled * (t_form - _t_d)
					if _df > _diag_d_frac_max: _diag_d_frac_max = _df
				var _sf_d: float = _sif_arr_diag[_i_diag] if _i_diag < _sif_n else 0.0
				_diag_sif_sum += _sf_d
				if _sf_d > _diag_sif_max: _diag_sif_max = _sf_d
				if _sf_d > 0.01: _diag_sif_pos += 1
				if _sf_d >= threshold * 0.5 and _sf_d < threshold: _diag_sif_near_thr += 1
		var _avg_t: float = _diag_t_sum / max(1, n_cells_fast)
		var _avg_sif_w: float = _diag_sif_sum / max(1, _diag_water)
		# [DIAG 2026-05-23 四轮] 海冰看似不动排障：把 C++ 端写回的 flip 列表 + 计数也打出来。
		# 关键问诊：terrain 真的没翻吗？flip_to_ice_list 有没有元素？
		var _flip_to_ice_diag: PackedInt32Array = knobs.get("flip_to_ice_list", PackedInt32Array())
		var _flip_to_base_diag: PackedInt32Array = knobs.get("flip_to_base_list", PackedInt32Array())
		var _stat_water_diag: int = int(knobs.get("stat_water_count", 0))
		var _stat_flipped_diag: int = int(knobs.get("stat_flipped_count", 0))
		# 当前 terrain 已是 SEA_ICE 的 cell 数（用于交叉核对：若已翻 cell 多但 SIF avg_w 仍低 = 渲染层问题）
		var _existing_ice_terrain: int = 0
		for _i_terr in range(n_cells_fast):
			if _i_terr < _terr_n and int(_terrain_arr_diag[_i_terr]) == int(TerrainType.TERRAIN.SEA_ICE):
				_existing_ice_terrain += 1
		print("[sea_ice/DIAG-SM] run#%d phase=%.3f | thr_eff t_form=%.3f t_melt=%.3f flip_thr=%.3f | k_f=%.3f k_m=%.3f dt=%.2f | temp all min=%.3f max=%.3f avg=%.3f | water n=%d t_min_w=%.3f below_form=%d (%.1f%%) max_dfrac=%.4f | SIF pos=%d max=%.3f avg_w=%.4f near_thr=%d | FLIP to_ice=%d to_base=%d stat_water=%d stat_flipped=%d existing_ice_terr=%d | climate_anom=%.3f" % [
			_gdext_sea_ice_runs + 1, season_phase,
			t_form, t_melt, threshold,
			k_freeze_scaled, k_melt_scaled, dt_days,
			_diag_t_min, _diag_t_max, _avg_t,
			_diag_water, _diag_t_min_water,
			_diag_below_form, 100.0 * float(_diag_below_form) / max(1, _diag_water), _diag_d_frac_max,
			_diag_sif_pos, _diag_sif_max, _avg_sif_w, _diag_sif_near_thr,
			_flip_to_ice_diag.size(), _flip_to_base_diag.size(),
			_stat_water_diag, _stat_flipped_diag, _existing_ice_terrain,
			climate_anomaly_now,
		])
	_gdext_sea_ice_runs += 1
	_gdext_sea_ice_total_ms += rc
	return true


func _run_sea_ice_state_machine_slice(map: MapData, season_phase: float, token: int) -> Dictionary:
	if _sea_ice_state_machine.is_empty() \
			or int(_sea_ice_state_machine.get("map_id", -1)) != map.get_instance_id() \
			or int(_sea_ice_state_machine.get("token", 0)) != token:
		if not _begin_sea_ice_state_machine(map, season_phase, token):
			var fb: Dictionary = _run_climate_pass_legacy_fallback(_CLIMATE_PASS_SEA_ICE, map, season_phase, token, "native_unavailable")
			_climate_pass_states.erase(_CLIMATE_PASS_SEA_ICE)
			return fb
		var native_result: Dictionary = _make_climate_pass_result(_CLIMATE_PASS_SEA_ICE, false, 0.0, 0, 0, 0, _CLIMATE_PASS_STATUS_RUNNING, token, _SEA_ICE_STAGE_NATIVE_COMPUTE)
		native_result["cursor_remaining"] = int(_sea_ice_state_machine.get("n", 0))
		native_result["budget_cells"] = _sea_ice_slice_budget_cells()
		return native_result
	var stage: String = str(_sea_ice_state_machine.get("stage", _SEA_ICE_STAGE_DENSE_SYNC_CHUNK))
	var n: int = int(_sea_ice_state_machine.get("n", 0))
	var budget: int = _sea_ice_slice_budget_cells()
	if stage == _SEA_ICE_STAGE_DENSE_SYNC_CHUNK:
		var sync_start: int = int(_sea_ice_state_machine.get("sync_cursor", 0))
		var sync_end: int = mini(n, sync_start + budget)
		var t_sync_us: int = Time.get_ticks_usec()
		if bool(_sea_ice_state_machine.get("facade_on", false)) and _data_core_world != null and map.sea_ice_frac_arr.size() >= n:
			var cid_si: int = _data_core_world.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)
			if cid_si >= 0 and _data_core_world.has_method("write_f32_indexed"):
				var idx: PackedInt32Array = PackedInt32Array()
				var vals: PackedFloat32Array = PackedFloat32Array()
				idx.resize(sync_end - sync_start)
				vals.resize(sync_end - sync_start)
				for k in range(sync_end - sync_start):
					var ci: int = sync_start + k
					idx[k] = ci
					vals[k] = map.sea_ice_frac_arr[ci]
				_data_core_world.write_f32_indexed(cid_si, idx, vals)
				# [B-Surgical 2026-05-23 海冰看似不动] 同步写 DCWorldExt 的 SIF slot。
				# 真因：C++ ice atlas raster（world_ext.cpp::encode_ice_state_atlas_*）
				# 从 DCWorldExt 自己的 cell_sea_ice_frac slot.arr_f32 读，不读
				# MapData.sea_ice_frac_arr，也不读 GDScript DCWorld。状态机只写
				# MapData + GDScript DCWorld，DCWorldExt slot 永远停留在初始 0 →
				# atlas pixel 全 0 → 视觉上海冰一直不动。
				# 修复：在已经备好 idx/vals 的同一处，向 DCWorldExt 镜像一次。
				# 双 world 架构由 GDScript DCWorld（ECS 容器）+ DCWorldExt（C++ 镜像
				# slot）组成，本来就是 superset/subset 关系；这里属于补足缺失的一条
				# 镜像链路（B-Surgical），不动其它系统的写入路径。
				# 见 docs/dots-master-execution-handbook.md §sea-ice-dual-world-sync。
				if _data_core_world_ext != null \
						and _data_core_world_ext.has_method("write_f32_indexed") \
						and _data_core_world_ext.has_method("component_id"):
					# [B-Surgical 命名空间不一致] DCComponentIds 用点号风格
					# (`cell.sea_ice_frac`)，但 DCWorldExt 的 BIND_TABLE 用下划线
					# 风格 (`cell_sea_ice_frac`，见 component_bind_table.gen.h)。
					# C++ component_id 是按字面量 hash 查表，找不到点号版本。
					# 这里两种都试一遍，下划线版作为 ext 端的真名 fallback。
					var cid_si_ext: int = int(_data_core_world_ext.component_id(DCComponentIds.CELL_SEA_ICE_FRAC))
					if cid_si_ext < 0:
						cid_si_ext = int(_data_core_world_ext.component_id(&"cell_sea_ice_frac"))
					if cid_si_ext >= 0:
						_data_core_world_ext.write_f32_indexed(cid_si_ext, idx, vals)
				# [BUG-FIX 2026-05-23 海冰看似不动] C++ sea_ice pass 直接改 DCWorld
				# slot.arr_f32 + _flush_slot_to_map(set MapData)，slot 已是新值。
				# 上面 write_f32_indexed 的 value-diff 因此命中"未变" → 不 mark dirty
				# → atlas_pipeline read_and_clear_dirty_mask 拿不到 SIF 变化 cell
				# → ice_state_atlas 永远空 → 海冰看似不动。
				# 修复：用 _begin 时缓存的 pre-pass SIF 快照比对 + 显式 mark_dirty_indexed。
				# 海冰 pass 一天一次，开销可接受。
				if _data_core_world.has_method("mark_dirty_indexed"):
					var pre_arr: PackedFloat32Array = _sea_ice_state_machine.get("pre_sif_snapshot", PackedFloat32Array())
					if pre_arr.size() >= sync_end:
						var dirty_idx: PackedInt32Array = PackedInt32Array()
						dirty_idx.resize(sync_end - sync_start)
						var dw: int = 0
						# [DIAG 2026-05-23 海冰排障第二轮] 收集 SIF>0 的 dirty cell 计数
						# + 最大 SIF 值，用来核对 atlas COMMIT 收到的 nonzero=0 是否
						# 因为 dirty_idx 里的 cell SIF 实际上都是 0（量化后 byte=0）。
						var dw_pos: int = 0
						var dw_sif_max: float = 0.0
						for k2 in range(sync_end - sync_start):
							var ci2: int = sync_start + k2
							var v_now: float = map.sea_ice_frac_arr[ci2]
							if v_now != pre_arr[ci2]:
								dirty_idx[dw] = ci2
								dw += 1
								if v_now > 0.0:
									dw_pos += 1
									if v_now > dw_sif_max:
										dw_sif_max = v_now
						if dw > 0:
							dirty_idx.resize(dw)
							_data_core_world.mark_dirty_indexed(dirty_idx)
							_sea_ice_state_machine["dirty_marked_count"] = int(_sea_ice_state_machine.get("dirty_marked_count", 0)) + dw
							_sea_ice_state_machine["dirty_marked_sif_pos"] = int(_sea_ice_state_machine.get("dirty_marked_sif_pos", 0)) + dw_pos
							var prev_max: float = float(_sea_ice_state_machine.get("dirty_marked_sif_max", 0.0))
							if dw_sif_max > prev_max:
								_sea_ice_state_machine["dirty_marked_sif_max"] = dw_sif_max
			else:
				var cells_sync: Array = _sea_ice_state_machine.get("cells", [])
				for i_sync in range(sync_start, sync_end):
					(cells_sync[i_sync] as HexCell).sea_ice_fraction = map.sea_ice_frac_arr[i_sync]
		else:
			var cells_sync_fb: Array = _sea_ice_state_machine.get("cells", [])
			for i_sync_fb in range(sync_start, sync_end):
				(cells_sync_fb[i_sync_fb] as HexCell).sea_ice_fraction = map.sea_ice_frac_arr[i_sync_fb]
		_sea_ice_state_machine["sync_ms"] = float(_sea_ice_state_machine.get("sync_ms", 0.0)) + (Time.get_ticks_usec() - t_sync_us) / 1000.0
		_sea_ice_state_machine["sync_cursor"] = sync_end
		if sync_end >= n:
			_sea_ice_state_machine["stage"] = _SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK
		var sync_result: Dictionary = _make_climate_pass_result(_CLIMATE_PASS_SEA_ICE, false, (Time.get_ticks_usec() - t_sync_us) / 1000.0,
				sync_end - sync_start, sync_start, sync_end, _CLIMATE_PASS_STATUS_RUNNING, token, _SEA_ICE_STAGE_DENSE_SYNC_CHUNK)
		sync_result["cursor_remaining"] = maxi(0, n - sync_end)
		sync_result["budget_cells"] = budget
		sync_result["next_stage"] = str(_sea_ice_state_machine.get("stage", _SEA_ICE_STAGE_DENSE_SYNC_CHUNK))
		return sync_result
	if stage == _SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK:
		var flip_to_ice_list: PackedInt32Array = _sea_ice_state_machine.get("flip_to_ice_list", PackedInt32Array())
		var flip_to_base_list: PackedInt32Array = _sea_ice_state_machine.get("flip_to_base_list", PackedInt32Array())
		var flip_to_base_terrain: PackedByteArray = _sea_ice_state_machine.get("flip_to_base_terrain", PackedByteArray())
		var total_flips: int = flip_to_ice_list.size() + flip_to_base_list.size()
		var flip_start: int = int(_sea_ice_state_machine.get("flip_cursor", 0))
		var flip_end: int = mini(total_flips, flip_start + budget)
		var t_flip_us: int = Time.get_ticks_usec()
		var flip_batch: Dictionary = _build_sea_ice_flip_batch(flip_to_ice_list, flip_to_base_list, flip_to_base_terrain, flip_start, flip_end)
		var flip_diag: Dictionary = _apply_sea_ice_terrain_flips_indexed(
				map,
				flip_batch.get("indices", PackedInt32Array()),
				flip_batch.get("terrain", PackedByteArray()),
				true)
		if bool(flip_diag.get("applied", false)):
			_sea_ice_state_machine["terrain_flip_indexed_count"] = int(_sea_ice_state_machine.get("terrain_flip_indexed_count", 0)) + int(flip_diag.get("count", 0))
		else:
			_sea_ice_state_machine["terrain_flip_legacy_fallback"] = true
			_sea_ice_state_machine["terrain_flip_fallback_reason"] = str(flip_diag.get("fallback_reason", "unknown"))
			var sea_ice_id: int = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
			for f in range(flip_start, flip_end):
				if f < flip_to_ice_list.size():
					var idx_i: int = flip_to_ice_list[f]
					if idx_i >= 0 and idx_i < n:
						var sm_cell_i: HexCell = map.cell_at(idx_i)
						if sm_cell_i != null:
							_set_cell_runtime_terrain(map, sm_cell_i, sea_ice_id, true, -1.0, sm_cell_i.snow_cover)
				else:
					var base_i: int = f - flip_to_ice_list.size()
					var idx_b: int = flip_to_base_list[base_i]
					if idx_b >= 0 and idx_b < n and base_i < flip_to_base_terrain.size():
						var target_terr: int = int(flip_to_base_terrain[base_i])
						var sm_cell_b: HexCell = map.cell_at(idx_b)
						if sm_cell_b != null:
							_set_cell_runtime_terrain(map, sm_cell_b, target_terr, true, -1.0, sm_cell_b.snow_cover)
		_sea_ice_state_machine["flip_ms"] = float(_sea_ice_state_machine.get("flip_ms", 0.0)) + (Time.get_ticks_usec() - t_flip_us) / 1000.0
		_sea_ice_state_machine["flip_cursor"] = flip_end
		if flip_end >= total_flips:
			_sea_ice_state_machine["stage"] = _SEA_ICE_STAGE_COMMIT
		var flip_result: Dictionary = _make_climate_pass_result(_CLIMATE_PASS_SEA_ICE, false, (Time.get_ticks_usec() - t_flip_us) / 1000.0,
				flip_end - flip_start, flip_start, flip_end, _CLIMATE_PASS_STATUS_RUNNING, token, _SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK)
		flip_result["cursor_remaining"] = maxi(0, total_flips - flip_end)
		flip_result["budget_cells"] = budget
		flip_result["next_stage"] = str(_sea_ice_state_machine.get("stage", _SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK))
		flip_result["terrain_flip_path"] = "legacy_set_cell_runtime_terrain" if bool(_sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)) else "indexed"
		flip_result["terrain_flip_count"] = int(_sea_ice_state_machine.get("terrain_flip_indexed_count", 0))
		flip_result["fallback_reason"] = str(_sea_ice_state_machine.get("terrain_flip_fallback_reason", ""))
		return flip_result
	var t_commit_us: int = Time.get_ticks_usec()
	if bool(_sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)):
		_write_runtime_enum_axes_dense(map)
	var water_count: int = int(_sea_ice_state_machine.get("water", 0))
	var flipped_count: int = int(_sea_ice_state_machine.get("flipped", 0))
	# [BUG-FIX 2026-05-23 海冰看似不动] 诊断：本 pass 我们显式 mark_dirty 的 cell 数。
	# 期望：当 SIF 有变化时 dirty_marked > 0；若仍 ==0 而 SIF 在变，说明 fix 没生效。
	# 节流：前 5 次 + 每个日历年长（与 DIAG-SM 同步）。
	var _dirty_marked_count: int = int(_sea_ice_state_machine.get("dirty_marked_count", 0))
	if _gdext_sea_ice_runs <= 5 or _is_annual_log_tick(_gdext_sea_ice_runs):
		print("[sea_ice/DIRTY-MARK] run#%d marked_dirty_cells=%d (sif_pos=%d sif_max=%.4f) water=%d flipped=%d" % [
			_gdext_sea_ice_runs, _dirty_marked_count,
			int(_sea_ice_state_machine.get("dirty_marked_sif_pos", 0)),
			float(_sea_ice_state_machine.get("dirty_marked_sif_max", 0.0)),
			water_count, flipped_count
		])
	if water_count > 0:
		var ratio: float = float(flipped_count) / float(water_count)
		if ratio > 0.03:
			push_warning("[sea_ice_daily/F.4] %d/%d (%.1f%%) cells flipped on phase=%.3f — possible bulk-switch regression" % [
				flipped_count, water_count, ratio * 100.0, season_phase
			])
	_last_sea_ice_daily_breakdown = {
		"path": "gdext_state_machine",
		"stage": _SEA_ICE_STAGE_COMMIT,
		"pack_ms": float(_sea_ice_state_machine.get("pack_ms", 0.0)),
		"refresh_ms": float(_sea_ice_state_machine.get("refresh_ms", 0.0)),
		"native_ms": float(_sea_ice_state_machine.get("native_ms", 0.0)),
		"native_wall_ms": float(_sea_ice_state_machine.get("native_wall_ms", 0.0)),
		"sync_ms": float(_sea_ice_state_machine.get("sync_ms", 0.0)),
		"flip_ms": float(_sea_ice_state_machine.get("flip_ms", 0.0)),
		"terrain_flip_path": "legacy_set_cell_runtime_terrain" if bool(_sea_ice_state_machine.get("terrain_flip_legacy_fallback", false)) else "indexed",
		"terrain_flip_count": int(_sea_ice_state_machine.get("terrain_flip_indexed_count", 0)),
		"terrain_flip_fallback_reason": str(_sea_ice_state_machine.get("terrain_flip_fallback_reason", "")),
		"commit_ms": (Time.get_ticks_usec() - t_commit_us) / 1000.0,
		"total_wall_ms": (Time.get_ticks_usec() - int(_sea_ice_state_machine.get("total_start_us", Time.get_ticks_usec()))) / 1000.0,
		"water": water_count,
		"flipped": flipped_count,
	}
	_dump_sea_ice_breakdown_if_slow()
	_gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
	_climate_pass_states.erase(_CLIMATE_PASS_SEA_ICE)
	_sea_ice_state_machine = {}
	return _make_climate_pass_result(_CLIMATE_PASS_SEA_ICE, true, (Time.get_ticks_usec() - t_commit_us) / 1000.0,
			0, -1, -1, _CLIMATE_PASS_STATUS_DONE, token, _SEA_ICE_STAGE_COMMIT)


# ─── [S2 fix 2026-05-23 三轮] sea_ice dt_days 补偿辅助函数 ────────────────────
# 抽自原 _apply_sea_ice_daily_pass 内联段。两条调用链共用：
#   - SUS sliced 路径：_begin_sea_ice_state_machine（实际运行时主路径）
#   - 非 sliced 整轮 / fallback 路径：_apply_sea_ice_daily_pass
# 同 tick 只命中其中一条，所以游标 _last_sea_ice_pass_day 不会双更新。
#
# 返回 dt_days ∈ (0, 30]。C++ 路径传原始 k + dt_days；GDScript fallback
# 在本地公式里乘 dt_days。不要在传给 C++ 前预乘 k，避免 d_frac 变成 dt^2。
# clamp 上限 30：防 pause 复位 / 开局过冲；下限 ≥ 0 后再 floor 到 1.0：阻断
# 同 tick 重入。第一次调用（_last_sea_ice_pass_day < 0）保持默认 1.0。
func _consume_sea_ice_dt_days() -> float:
	var dt_days: float = 1.0
	if _world_clock_ref != null:
		var now_day_v = _world_clock_ref.get("current_day")
		if now_day_v != null:
			var now_day: float = float(now_day_v)
			if _last_sea_ice_pass_day >= 0.0:
				dt_days = clampf(now_day - _last_sea_ice_pass_day, 0.0, 30.0)
				if dt_days <= 0.0:
					dt_days = 1.0  # 同 tick 重入兜底
			# else: 第一次调用，保持 dt_days = 1.0 默认
			_last_sea_ice_pass_day = now_day
	# 诊断：每个日历年长或前 5 次打印一次 dt_days，验证补偿是否在工作。
	# Fix #11 second pass (2026-06-16) mobile：x20 速度下 1 仿真年 ~6 秒，mobile
	# 每秒触发 ~0.16 次 print。logcat overhead ~10ms/行 → 1.6ms/秒。改为 mobile 上
	# 前 5 次后只在 sea_ice 行为异常时打（dt_days > 10 或 < 0.5 = 速度档异常）。
	var _sea_ice_call_total: int = _gdext_sea_ice_runs + _gdext_sea_ice_fallbacks
	var _should_log_dt: bool = _sea_ice_call_total < 5
	if not _should_log_dt and not OS.has_feature("mobile"):
		_should_log_dt = _is_annual_log_tick(_sea_ice_call_total)
	if not _should_log_dt and OS.has_feature("mobile"):
		# mobile：超出 5 次后只在 dt_days 偏离常规时打（异常 dt 才有诊断价值）。
		_should_log_dt = dt_days > 10.0 or dt_days < 0.5
	if _should_log_dt and PKLog.enabled:
		print("[sea_ice/dt] call#%d dt_days=%.3f (last_pass_day=%.3f, k x%.2f)" % [
			_gdext_sea_ice_runs + _gdext_sea_ice_fallbacks + 1,
			dt_days,
			_last_sea_ice_pass_day,
			dt_days,
		])
	return dt_days


# [thermal dt 补偿 2026-06-16] 与 _consume_sea_ice_dt_days 对称：返回本次 climate
# pass_a 距上次实际经过的仿真天数 ∈ (0, 30]。C++/GDScript pass_a 用它把单日 α
# 换算为多日等效 α_eff、并把 delta_cap 乘以 dt。
# 同一仿真日内多个 knob builder（cp_struct / async kick / fallback 循环）可能各调
# 一次：用 _climate_dt_cached_day 缓存，保证返回同一 dt 且只推进一次游标。
func _consume_climate_dt_days() -> float:
	var dt_days: float = 1.0
	if _world_clock_ref != null:
		var now_day_v = _world_clock_ref.get("current_day")
		if now_day_v != null:
			var now_day: float = float(now_day_v)
			# 同一仿真日重复取值 → 命中缓存，不再推进游标。
			if _climate_dt_cached_day >= 0.0 and is_equal_approx(now_day, _climate_dt_cached_day):
				return _climate_dt_cached_val
			if _last_climate_pass_day >= 0.0:
				dt_days = clampf(now_day - _last_climate_pass_day, 0.0, 30.0)
				if dt_days <= 0.0:
					dt_days = 1.0  # 同 tick 重入兜底
			# else: 第一次调用，保持 dt_days = 1.0 默认
			_last_climate_pass_day = now_day
			_climate_dt_cached_day = now_day
			_climate_dt_cached_val = dt_days
	return dt_days


# QA 异常守卫：当日 SEA_ICE 翻转 cell 数 > 总水体数 3% 时打印一次 WARN
# （帮助定位"全图统一切换"的回归）。
func _apply_sea_ice_daily_pass(map: MapData, season_phase: float) -> void:
	if map == null or _last_cfg == null:
		return
	var cp := _c()
	if cp == null:
		return

	var t_total_us: int = Time.get_ticks_usec()
	var t0: int = Time.get_ticks_msec()
	var k_freeze: float = float(cp.sea_ice_freeze_rate)
	var k_melt: float = float(cp.sea_ice_melt_rate)
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var contagion: float = float(cp.sea_ice_neighbor_contagion)
	var threshold: float = float(cp.sea_ice_terrain_threshold)
	var hysteresis: float = float(cp.sea_ice_terrain_hysteresis)
	var ice_delay: float = float(_last_cfg.OCEAN_CURRENT_ICE_DELAY)

	# ─── map-visual-overhaul-v1：climate_anomaly 联动（极区可见缩水） ──────────
	# climate_anomaly > 0 → 长期升温 → 海冰冻结/融化阈值同步下调 → 极地白圈缩水。
	# 等价于"温度抬升 anomaly_strength * climate_anomaly"，但走阈值下调更安全
	# （不污染 SoA temp_arr / cell.temperature），且对 GDExt C++ 路径透明
	# （C++ 端接收的 t_form/t_melt 已带偏移）。系数 0.10 实测：
	#   climate_anomaly = +0.20 → 阈值下调 0.02 → 极地白圈缩约 1-2 hex 圈
	#   climate_anomaly = -0.20 → 阈值上调 0.02 → 中纬冬季冰扩约 1 hex 圈
	# 区间内对玩家明显可见但不至于剧烈跳变。
	var sea_ice_climate_anomaly_strength: float = 0.10
	var climate_anomaly_now: float = 0.0
	if _world_clock_ref != null:
		var ca_v = _world_clock_ref.get("climate_anomaly")
		if ca_v != null:
			climate_anomaly_now = float(ca_v)
	if not is_equal_approx(climate_anomaly_now, 0.0):
		var ice_thr_shift: float = sea_ice_climate_anomaly_strength * climate_anomaly_now
		t_form = clampf(t_form - ice_thr_shift, 0.0, 1.0)
		t_melt = clampf(t_melt - ice_thr_shift, 0.0, 1.0)

	# ─── [S2 fix 2026-05-23] dt_days 补偿 ──────────────────────────────
	# 详见 _consume_sea_ice_dt_days()。本函数是 daily_climate_refresh 非 sliced
	# 整轮路径 / fallback 路径；状态机 sliced 路径在 _begin_sea_ice_state_machine
	# 同样调用 _consume_sea_ice_dt_days，两路径互斥（同 tick 只命中一条）。
	var dt_days: float = _consume_sea_ice_dt_days()
	var k_freeze_scaled: float = k_freeze * dt_days
	var k_melt_scaled: float = k_melt * dt_days

	# ─── Phase F.4：DCWorldExt C++ 快路径（charter §7 P2，5.1ms → 0.5ms）─
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_sea_ice flag 已删，现走 ext +
	# has_method 探测。触发条件：
	#   1. _data_core_world_ext 已 bind
	#   2. fast_indexed（neighbor_indices_packed 完整 + has_indices）
	#   3. C++ 端 has run_sea_ice_daily_pass 且返回 ≥ 0
	# 任意一条不满足 → 透明 fallback 到下面的 GDScript 双 phase 循环。
	#
	# 设计：terrain 翻转**不**在 C++ 端写——C++ 只算 fraction 增量 + 收集 flip
	# 候选列表，由 GDScript 端遍历列表调 cell.apply_terrain 维护 multi-axis 同步
	# （passable_land / passable_sea / landform 等派生字段）。这是 charter §2.5
	# STRUCT-001 反模式规避：C++ 不直接改 multi-axis enum。
	var cells_fast: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_fast: int = cells_fast.size()
	var nb_idx_fast: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = nb_idx_fast.size() >= n_cells_fast * 6

	if not _gdext_sea_ice_first_attempt_logged:
		_gdext_sea_ice_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		var flag_val: bool = true  # use_gdext_sea_ice flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp != null and cp.resource_path != "":
			cp_path = cp.resource_path
		var ext_ok: bool = _data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _data_core_world_ext.has_method("run_sea_ice_daily_pass")
		var verdict: String = "OK → will try C++"
		if not (flag_val and ext_ok and has_method_ok and fast_indexed):
			verdict = "FAIL → fall through to GDScript path"
		print("[sea_ice/F.4] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_sea_ice = %s (flag removed; constant true)" % str(flag_val))
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_sea_ice_daily_pass') = %s" % str(has_method_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got neighbor_indices.size()=%d)" % [str(fast_indexed), n_cells_fast * 6, nb_idx_fast.size()])
		print("  verdict = %s" % verdict)

	if _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_sea_ice_daily_pass") and fast_indexed:
		# Stale .dll probe（一次/session）
		if not _gdext_sea_ice_signature_checked:
			_gdext_sea_ice_signature_checked = true
			_gdext_sea_ice_signature_ok = _validate_gdext_method_signature("run_sea_ice_daily_pass", 2)
			print("[sea_ice/F.4] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_gdext_sea_ice_signature_ok))

		# Build per-tick PackedArray 输入：尽量走 SoA/cache，避免从 HexCell facade
		# 逐格打包。sea_ice C++ native 只有几十微秒，热成本主要在这里。
		#
		# 性能修复（2026-05-18）：实测 pack=0.9ms vs native=0.025ms（36×）。
		# 原因是 base_terrain_arr / TTA 都在 SoA（map_data.gd:102, 142），但旧代码
		# 仍逐 cell 打包。现按 temp_input 同款策略：先看 SoA 是否已就绪，再用
		# fallback 私有 buffer。base_terrain 运行时不会变（sea_ice 翻转只动 terrain
		# 不动 base_terrain），可以直接引用；TTA 优先用 ocean pass 同 round 留下的
		# cached buffer（更新鲜），其次回 SoA，最后才逐 cell 打包。
		var t_pack_us: int = Time.get_ticks_usec()
		# base_terrain：SoA 是权威源（见 map_data.gd:397，pull_packed_arrays_from_cells
		# 在生成期 / 加载存档时写一次；运行时 sea_ice 翻 terrain 不动 base_terrain）。
		var base_terrain_input: PackedByteArray
		if map.base_terrain_arr.size() == n_cells_fast:
			base_terrain_input = map.base_terrain_arr
		else:
			if _gdext_sea_ice_base_terrain_buf.size() != n_cells_fast:
				_gdext_sea_ice_base_terrain_buf.resize(n_cells_fast)
			base_terrain_input = _gdext_sea_ice_base_terrain_buf
			for i_build in range(n_cells_fast):
				var c_build: HexCell = cells_fast[i_build]
				_gdext_sea_ice_base_terrain_buf[i_build] = int(c_build.base_terrain) & 0xFF
		# TTA：优先 ocean pass cached（同 round 最新），其次 SoA，最后 fallback。
		var tta_input: PackedFloat32Array
		if _gdext_ocean_anomaly_buf_cached.size() == n_cells_fast:
			tta_input = _gdext_ocean_anomaly_buf_cached
		elif map.temperature_transport_anomaly_arr.size() == n_cells_fast:
			tta_input = map.temperature_transport_anomaly_arr
		else:
			if _gdext_sea_ice_tta_buf.size() != n_cells_fast:
				_gdext_sea_ice_tta_buf.resize(n_cells_fast)
			tta_input = _gdext_sea_ice_tta_buf
			for i_tta in range(n_cells_fast):
				tta_input[i_tta] = cells_fast[i_tta].temperature_transport_anomaly
		var upw_input: PackedFloat32Array = map.upwelling_strength_arr \
				if map.upwelling_strength_arr.size() == n_cells_fast \
				else _gdext_sea_ice_upw_buf
		if upw_input.size() != n_cells_fast:
			_gdext_sea_ice_upw_buf.resize(n_cells_fast)
			upw_input = _gdext_sea_ice_upw_buf
			for i_upw in range(n_cells_fast):
				upw_input[i_upw] = cells_fast[i_upw].upwelling_strength
		var temp_input: PackedFloat32Array = map.temp_arr \
				if map.temp_arr.size() == n_cells_fast \
				else _gdext_sea_ice_temp_buf
		if temp_input.size() != n_cells_fast:
			_gdext_sea_ice_temp_buf.resize(n_cells_fast)
			temp_input = _gdext_sea_ice_temp_buf
			for i_temp in range(n_cells_fast):
				temp_input[i_temp] = cells_fast[i_temp].temperature
		var insol_input: PackedFloat32Array = _sea_ice_insolation_input(map, cells_fast, season_phase)
		var pack_ms: float = (Time.get_ticks_usec() - t_pack_us) / 1000.0

		# water_terrain_ids 与 _is_water 1:1 对齐（line 3090+）：
		# OCEAN / COAST / LAKE / REEF / KELP / SEA_ICE 共 6 种。
		var water_ids: PackedByteArray = PackedByteArray([
			int(TerrainType.TERRAIN.OCEAN) & 0xFF,
			int(TerrainType.TERRAIN.COAST) & 0xFF,
			int(TerrainType.TERRAIN.LAKE) & 0xFF,
			int(TerrainType.TERRAIN.REEF) & 0xFF,
			int(TerrainType.TERRAIN.KELP) & 0xFF,
			int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
		])

		var knobs: Dictionary = {
			"n_cells": n_cells_fast,
			# C++ 端会用 dt_days 乘一次；这里传原始 per-day 速率，避免 dt^2 过冲。
			"k_freeze": k_freeze,
			"k_melt": k_melt,
			"dt_days": dt_days,
			"t_form": t_form,
			"t_melt": t_melt,
			"contagion": contagion,
			"threshold": threshold,
			"hysteresis": hysteresis,
			"ice_delay": ice_delay,
			"enable_ocean_heat_transport": bool(_last_cfg.enable_ocean_heat_transport),
			"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
			"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
			"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
			"water_terrain_ids": water_ids,
			"neighbor_indices": nb_idx_fast,
			"base_terrain_arr": base_terrain_input,
			"temp_transport_anomaly": tta_input,
			"upwelling_strength": upw_input,
			"insolation_now_arr": insol_input,
			"solar_gate_enabled": _sea_ice_solar_gate_enabled(cp),
			"freeze_insol_low": float(cp.sea_ice_freeze_insol_low),
			"freeze_insol_high": float(cp.sea_ice_freeze_insol_high),
			"solar_melt_start": float(cp.sea_ice_solar_melt_start),
			"solar_melt_gain": float(cp.sea_ice_solar_melt_gain),
			"daily_delta_cap": float(cp.sea_ice_daily_delta_cap) if cp.get("sea_ice_daily_delta_cap") != null else 0.08,
			"cell_temperature_arr": temp_input,
		}
		# storage A/B 同源契约（修复 B 2026-05-14；详见 docs/dots-f4-validation.md §2.2.b）：
		# GDScript pass_a 写 map.temp_arr / 上一段 sub-pass 写 map.*_arr 后，C++ slot
		# 仍指向 CoW 解耦前的旧 buffer。先 refresh 让 C++ 读到 GDScript 端最新状态。
		# 开销 ~14μs / 35 component（map_data->get + Variant 类型分发），可接受；
		# 后续 Phase 2.1 GDScript 改走 world.write_f32_indexed 后可移除。
		# refresh-consolidation-2026-06：走 climate daily round 守门员。
		# 同 round 内若 pass_a/B/ocean 已 refresh 过则跳过；refresh_ms 仅记录真实
		# refresh 那次的耗时，否则保持 0。
		var refresh_ms: float = 0.0
		if _data_core_world_ext.has_method("refresh_slots_from_map") and not _climate_daily_round_slots_fresh:
			var t_refresh_us: int = Time.get_ticks_usec()
			_ensure_climate_daily_round_slots_fresh()
			refresh_ms = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
		else:
			_ensure_climate_daily_round_slots_fresh()  # may skip
		# dots-flag-prune-pr1 round 2: use_gdext_thread_fallback flag 已删除——恒走
		# C++ scalar 入口 run_sea_ice_daily_pass，C++ 内部根据 CPU 特性 / n_cells 自动选择
		# scalar / SIMD / threaded 三档执行路径。
		var _sea_ice_dispatch_path: String = "scalar"
		var t_native_us: int = Time.get_ticks_usec()
		var rc: float = float(_data_core_world_ext.run_sea_ice_daily_pass(knobs, season_phase))
		if rc < 0.0 and _data_core_world_ext.has_method("run_sea_ice_daily_pass_thread"):
			_sea_ice_dispatch_path = "thread_fallback"
			rc = float(_data_core_world_ext.run_sea_ice_daily_pass_thread(knobs, season_phase, 4))
		var native_wall_ms: float = (Time.get_ticks_usec() - t_native_us) / 1000.0
		# Plan-C full-map diagnostics were removed from this hot path. Slow-path
		# breakdown logging below is retained and uses already-collected timings.
		if _gdext_sea_ice_runs + _gdext_sea_ice_fallbacks < 3:
			print("[sea_ice/F.4] DEBUG call#%d: path=%s rc=%.4f n_cells=%d enable_oht=%s" % [
				_gdext_sea_ice_runs + _gdext_sea_ice_fallbacks + 1,
				_sea_ice_dispatch_path, rc, n_cells_fast, str(_last_cfg.enable_ocean_heat_transport),
			])
		if rc >= 0.0:
			# C++ 已写 DCWorldExt cell_sea_ice_frac slot 并 flush 回 MapData。
			# 这里还需要同步 GDScript DCWorld 的 dirty mask，供 dynamic atlas 消费。
			# 旧实现逐 cell 走 HexCell setter，会触发 2400 次 write_f32/dirty mark；
			# 改为 dense 批量写，复用 value-diff，仅真实变化的 cell 标 dirty。
			var t_sync_us: int = Time.get_ticks_usec()
			var facade_on: bool = false
			if n_cells_fast > 0 and cells_fast[0] != null:
				var c0_sync: HexCell = cells_fast[0] as HexCell
				facade_on = c0_sync != null and c0_sync.is_facade_enabled()
			var sync_done_dense: bool = false
			if facade_on and _data_core_world != null \
					and _data_core_world.has_method("write_f32_dense") \
					and map.sea_ice_frac_arr.size() >= n_cells_fast:
				var _cid_si_dense: int = _data_core_world.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)
				if _cid_si_dense >= 0:
					_data_core_world.write_f32_dense(_cid_si_dense, map.sea_ice_frac_arr)
					sync_done_dense = true
			if not sync_done_dense:
				for i_sync in range(n_cells_fast):
					var c_sync: HexCell = cells_fast[i_sync]
					c_sync.sea_ice_fraction = map.sea_ice_frac_arr[i_sync]
			var sync_ms: float = (Time.get_ticks_usec() - t_sync_us) / 1000.0

			# 应用 flip 列表
			# 2026-05-19 plan-c 修复：apply_terrain 只写 GDScript HexCell.terrain（裸 var），
			# 不会同步到 map.terrain_arr。下次 sea_ice pass 调用 refresh_slots_from_map 时，
			# C++ s_terrain.arr_u8 会从 map.terrain_arr 拿到 bake 时的旧 OCEAN，导致：
			#   1) was_ice 永远 false → flip_to_base_list 永远空 → 冰永远翻不回 OCEAN
			#   2) 已 flip 的 cell 被 C++ 重判为 "non-ice 且 sif>=thr" → 重复加入 flip_to_ice
			# 修复：apply 同步写 map.terrain_arr，让 C++ 下一帧看到最新 terrain。
			# 开销：flip_list 通常 <300，O(n) 写入 ~几 μs，可忽略。
			var t_flip_us: int = Time.get_ticks_usec()
			var flip_to_ice_list: PackedInt32Array = knobs.get("flip_to_ice_list", PackedInt32Array())
			var flip_to_base_list: PackedInt32Array = knobs.get("flip_to_base_list", PackedInt32Array())
			var flip_to_base_terrain: PackedByteArray = knobs.get("flip_to_base_terrain", PackedByteArray())
			var flip_batch: Dictionary = _build_sea_ice_flip_batch(flip_to_ice_list, flip_to_base_list, flip_to_base_terrain)
			var flip_diag: Dictionary = _apply_sea_ice_terrain_flips_indexed(
					map,
					flip_batch.get("indices", PackedInt32Array()),
					flip_batch.get("terrain", PackedByteArray()),
					true)
			if not bool(flip_diag.get("applied", false)):
				var _sea_ice_id: int = int(TerrainType.TERRAIN.SEA_ICE) & 0xFF
				for i_flip in range(flip_to_ice_list.size()):
					var idx_i: int = flip_to_ice_list[i_flip]
					if idx_i >= 0 and idx_i < n_cells_fast:
						var fast_cell_i: HexCell = map.cell_at(idx_i)
						if fast_cell_i != null:
							_set_cell_runtime_terrain(map, fast_cell_i, _sea_ice_id, true, -1.0, fast_cell_i.snow_cover)
				for i_back in range(flip_to_base_list.size()):
					var idx_b: int = flip_to_base_list[i_back]
					if idx_b >= 0 and idx_b < n_cells_fast and i_back < flip_to_base_terrain.size():
						var target_terr: int = int(flip_to_base_terrain[i_back])
						var fast_cell_b: HexCell = map.cell_at(idx_b)
						if fast_cell_b != null:
							_set_cell_runtime_terrain(map, fast_cell_b, target_terr, true, -1.0, fast_cell_b.snow_cover)
				_write_runtime_enum_axes_dense(map)
			var flip_ms: float = (Time.get_ticks_usec() - t_flip_us) / 1000.0

			var water_count_cpp: int = int(knobs.get("stat_water_count", 0))
			var flipped_count_cpp: int = int(knobs.get("stat_flipped_count", 0))

			# QA 异常守卫（与 GDScript 路径一致）
			if water_count_cpp > 0:
				var ratio: float = float(flipped_count_cpp) / float(water_count_cpp)
				if ratio > 0.03:
					push_warning("[sea_ice_daily/F.4] %d/%d (%.1f%%) cells flipped on phase=%.3f — possible bulk-switch regression" % [
						flipped_count_cpp, water_count_cpp, ratio * 100.0, season_phase
					])

			_gdext_sea_ice_runs += 1
			_gdext_sea_ice_total_ms += rc
			if _gdext_sea_ice_runs == 1:
				print("[sea_ice/F.4] gdext path ACTIVE (dispatch=%s) — first run elapsed=%.2fms (legacy GDScript baseline ≈ 5.1ms; charter §7 target < 0.5ms)" % [_sea_ice_dispatch_path, rc])

			# 节流打点（每个日历年长）
			if _is_annual_log_tick(_daily_climate_call_count):
				print("_apply_sea_ice_daily_pass[F.4]: %.2fms (water=%d, flipped=%d, phase=%.3f)" % [
					rc, water_count_cpp, flipped_count_cpp, season_phase
				])
				# [DIAG 2026-05-23] 海冰不动排障：统计水体 cell 的温度分布与 SIF 分布。
				# 关键问题：t_eff 是否真的有 < t_form？SIF 是否在涨但没到 threshold？
				# 用 temp_input（与 C++ 端读的同一份）+ map.sea_ice_frac_arr（C++ 已 flush）。
				var _diag_t_form: float = t_form          # 已带 climate_anomaly 偏移
				var _diag_t_melt: float = t_melt
				var _diag_thr: float = threshold
				var _diag_n: int = n_cells_fast
				var _diag_water: int = 0
				var _diag_below_form: int = 0     # t_eff < t_form
				var _diag_sif_pos: int = 0        # SIF > 0.01
				var _diag_sif_near_thr: int = 0   # SIF ∈ [thr*0.5, thr)
				var _diag_t_min: float = 9.99
				var _diag_t_max: float = -9.99
				var _diag_t_sum: float = 0.0
				var _diag_t_min_water: float = 9.99    # 仅水体
				var _diag_sif_max: float = 0.0
				var _diag_sif_sum: float = 0.0
				var _terrain_arr_diag: PackedByteArray = map.terrain_arr
				var _sif_arr_diag: PackedFloat32Array = map.sea_ice_frac_arr
				var _temp_n: int = temp_input.size()
				var _sif_n: int = _sif_arr_diag.size()
				for _i_diag in range(_diag_n):
					var _t_d: float = temp_input[_i_diag] if _i_diag < _temp_n else 0.0
					if _t_d < _diag_t_min: _diag_t_min = _t_d
					if _t_d > _diag_t_max: _diag_t_max = _t_d
					_diag_t_sum += _t_d
					var _terr_d: int = int(_terrain_arr_diag[_i_diag]) if _i_diag < _terrain_arr_diag.size() else -1
					var _is_w: bool = (_terr_d == int(TerrainType.TERRAIN.OCEAN) \
						or _terr_d == int(TerrainType.TERRAIN.COAST) \
						or _terr_d == int(TerrainType.TERRAIN.REEF) \
						or _terr_d == int(TerrainType.TERRAIN.KELP) \
						or _terr_d == int(TerrainType.TERRAIN.SEA_ICE))
					if _is_w:
						_diag_water += 1
						if _t_d < _diag_t_min_water: _diag_t_min_water = _t_d
						if _t_d < _diag_t_form: _diag_below_form += 1
						var _sf_d: float = _sif_arr_diag[_i_diag] if _i_diag < _sif_n else 0.0
						_diag_sif_sum += _sf_d
						if _sf_d > _diag_sif_max: _diag_sif_max = _sf_d
						if _sf_d > 0.01: _diag_sif_pos += 1
						if _sf_d >= _diag_thr * 0.5 and _sf_d < _diag_thr: _diag_sif_near_thr += 1
				var _avg_t: float = _diag_t_sum / max(1, _diag_n)
				var _avg_sif_w: float = _diag_sif_sum / max(1, _diag_water)
				print("[sea_ice/DIAG] thr_eff t_form=%.3f t_melt=%.3f flip_thr=%.3f | temp all min=%.3f max=%.3f avg=%.3f | water n=%d t_min_w=%.3f below_form=%d (%.1f%%) | SIF pos=%d max=%.3f avg_w=%.4f near_thr=%d | climate_anom=%.3f" % [
					_diag_t_form, _diag_t_melt, _diag_thr,
					_diag_t_min, _diag_t_max, _avg_t,
					_diag_water, _diag_t_min_water,
					_diag_below_form, 100.0 * float(_diag_below_form) / max(1, _diag_water),
					_diag_sif_pos, _diag_sif_max, _avg_sif_w, _diag_sif_near_thr,
					climate_anomaly_now,
				])
			_last_sea_ice_daily_breakdown = {
				"path": "gdext",
				"pack_ms": pack_ms,
				"refresh_ms": refresh_ms,
				"native_ms": rc,
				"native_wall_ms": native_wall_ms,
				"sync_ms": sync_ms,
				"flip_ms": flip_ms,
				"terrain_flip_path": "indexed" if bool(flip_diag.get("applied", false)) else "legacy_set_cell_runtime_terrain",
				"terrain_flip_count": int(flip_diag.get("count", 0)),
				"terrain_flip_fallback_reason": str(flip_diag.get("fallback_reason", "")),
				"total_wall_ms": (Time.get_ticks_usec() - t_total_us) / 1000.0,
				"water": water_count_cpp,
				"flipped": flipped_count_cpp,
			}
			# 方案 ① Step 1：≥ 5ms 强制打印（节流），确诊 7ms 走的是哪条路径
			_dump_sea_ice_breakdown_if_slow()
			_gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
			return
		_gdext_sea_ice_fallbacks += 1
		push_warning("[sea_ice_daily] native path failed; keeping previous sea-ice fields for strict-native simulation")
		return

	# Pass A：先把每个水体 cell 的"是否有冷邻居"快照（用前一日的 sea_ice_fraction）
	# Daily-Sim SoA Refactor 阶段 2：通过 _neighbor_indices 直接索引，避免每帧
	# 创建 N_water 个 6-元 Array。
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var nb_idx_arr: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var has_idx: bool = nb_idx_arr.size() >= n_cells * 6
	var has_cold_neighbor := PackedByteArray()
	has_cold_neighbor.resize(n_cells)
	var solar_gate_enabled: bool = _sea_ice_solar_gate_enabled(cp)
	var freeze_insol_low: float = float(cp.sea_ice_freeze_insol_low)
	var freeze_insol_high: float = float(cp.sea_ice_freeze_insol_high)
	var solar_melt_start: float = float(cp.sea_ice_solar_melt_start)
	var solar_melt_gain: float = float(cp.sea_ice_solar_melt_gain)
	var daily_delta_cap: float = float(cp.sea_ice_daily_delta_cap) if cp.get("sea_ice_daily_delta_cap") != null else 0.08
	var insolation_input: PackedFloat32Array = _sea_ice_insolation_input(map, cells, season_phase)

	# PR-2.1.4（sea_ice daily fallback 写路径下移）：预分配 batch buffer。
	# C++ 路径在 line 4140+ 已 return；本 batch 仅在 GDScript fallback 时使用。
	# 详见 docs/dots-master-execution-handbook.md §3.8。
	var _si_indices: PackedInt32Array = PackedInt32Array()
	var _si_frac: PackedFloat32Array = PackedFloat32Array()
	_si_indices.resize(n_cells)
	_si_frac.resize(n_cells)
	for i in range(n_cells):
		var cell: HexCell = cells[i]
		if not _is_water(cell.terrain):
			continue
		var any_cold: bool = false
		if has_idx:
			var base: int = i * 6
			for d in range(6):
				var ni: int = nb_idx_arr[base + d]
				if ni < 0:
					continue
				var nb: HexCell = cells[ni]
				if _is_water(nb.terrain) and nb.sea_ice_fraction >= 0.6:
					any_cold = true
					break
		else:
			for nb: HexCell in map.get_neighbors(cell):
				if nb != null and _is_water(nb.terrain) and nb.sea_ice_fraction >= 0.6:
					any_cold = true
					break
		has_cold_neighbor[i] = 1 if any_cold else 0

	var water_count: int = 0
	var flipped_count: int = 0

	# [perf 2026-05-20] 移除循环内 cell.sea_ice_fraction = X 单点 setter，
	# 仅写 _si_frac[i]，末尾走 write_f32_indexed 批量提交。
	# 原因：facade setter → world.write_f32 → _dirty_mark_one 风暴，导致
	# _dirty_cell_mask 每帧被标成全 1，atlas_upload 退化为全推（21-24 ms/tick）。
	for i in range(n_cells):
		var cell: HexCell = cells[i]
		if not _is_water(cell.terrain):
			# 非水体 cell 强制保持 0
			_si_indices[i] = i
			_si_frac[i] = 0.0
			continue
		# LAKE：跳过（淡水冻结留给后续 phase）
		if cell.terrain == TerrainType.TERRAIN.LAKE:
			_si_indices[i] = i
			_si_frac[i] = 0.0
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
		if has_cold_neighbor[i] != 0:
			k_freeze_eff = k_freeze * (1.0 + contagion)

		# 路线 A（单一真值源）：海冰仍以温度为主驱动，不再乘 dev_ice。
		# 南北半球的"冬冻夏融"差异完全来自温度 Pass（insolation 驱动）：
		#   - 温度 Pass 已让北半球 1 月冷、南半球 7 月冷；
		#   - 这里只需按"当日温度越过阈值 → 结冰/融化"，同温度 → 同命运；
		#   - 避免"日历月份直接决定冻融速率"的相位作弊（#bugfix 同温不同冻）。
		# 强日照作为冻结门控/额外融化，避免热带高日照低温预热期误结冰。
		var k_melt_eff: float = k_melt

		# 增量更新：温度低于结冰阈值 → 增长；高于融化阈值 → 衰减
		# [S2 fix 2026-05-23] 乘 dt_days：见函数入口 dt_days 计算注释。
		var freeze_gate: float = 1.0
		var solar_melt: float = 0.0
		if solar_gate_enabled:
			var insolation_now: float = insolation_input[i] if i < insolation_input.size() else 0.0
			freeze_gate = _sea_ice_freeze_gate(insolation_now, freeze_insol_low, freeze_insol_high)
			solar_melt = _sea_ice_solar_melt(insolation_now, solar_melt_start, solar_melt_gain)
		var delta_freeze: float = k_freeze_eff * maxf(0.0, t_form - t_eff) * freeze_gate
		var delta_melt: float = k_melt_eff * maxf(0.0, t_eff - t_melt) + solar_melt
		# [seaice dt 修复 2026-06-16] daily_delta_cap 是"每日"上限：先裁剪日速率再乘
		# dt_days（与 C++ 三核 1:1）。否则加速档每轮最多长 cap，亚极地涨不到翻转阈值。
		var rate: float = delta_freeze - delta_melt
		if daily_delta_cap > 0.0:
			rate = clampf(rate, -daily_delta_cap, daily_delta_cap)
		var d_frac: float = rate * dt_days
		var prev_frac: float = cell.sea_ice_fraction
		var new_frac: float = clampf(prev_frac + d_frac, 0.0, 1.0)
		# [perf 2026-05-20] 不再单点 setter，末尾批量 write_f32_indexed
		_si_indices[i] = i
		_si_frac[i] = new_frac

		# terrain 翻转（带迟滞）
		var was_ice: bool = (cell.terrain == TerrainType.TERRAIN.SEA_ICE)
		if not was_ice and new_frac >= threshold:
			# 形成海冰：保留 base_terrain 以便回退（不动 base_terrain 自身）
			_set_cell_runtime_terrain(map, cell, TerrainType.TERRAIN.SEA_ICE, true, t_eff, cell.snow_cover)
			flipped_count += 1
		elif was_ice and new_frac < threshold - hysteresis:
			# 融化退出：还原到 base_terrain
			var base: int = int(cell.base_terrain)
			if base == TerrainType.TERRAIN.SEA_ICE:
				_set_cell_runtime_terrain(map, cell, TerrainType.TERRAIN.OCEAN, true, t_eff, cell.snow_cover)
			else:
				_set_cell_runtime_terrain(map, cell, base, true, t_eff, cell.snow_cover)
			flipped_count += 1

	# QA 异常守卫：当日翻转 > 3% 总水体 → WARN（统一切换的旧回归特征）
	if water_count > 0:
		var ratio: float = float(flipped_count) / float(water_count)
		if ratio > 0.03:
			push_warning("[sea_ice_daily] %d/%d (%.1f%%) cells flipped on phase=%.3f — possible bulk-switch regression" % [
				flipped_count, water_count, ratio * 100.0, season_phase
			])

	# PR-2.1.4（sea_ice fallback 写路径下移）：循环结束后批量 push sea_ice_fraction 到 DCWorld。
	if _data_core_world != null and n_cells > 0:
		var _cid_si: int = _data_core_world.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)
		if _cid_si >= 0:
			_data_core_world.write_f32_indexed(_cid_si, _si_indices, _si_frac)
		_write_runtime_enum_axes_dense(map)
	_last_sea_ice_daily_breakdown = {
		"path": "gdscript",
		"pack_ms": 0.0,
		"refresh_ms": 0.0,
		"native_ms": -1.0,
		"native_wall_ms": 0.0,
		"sync_ms": 0.0,
		"flip_ms": 0.0,
		"total_wall_ms": (Time.get_ticks_usec() - t_total_us) / 1000.0,
		"water": water_count,
		"flipped": flipped_count,
	}
	# 方案 ① Step 1：≥ 5ms 强制打印（节流），确诊 7ms 走的是哪条路径
	_dump_sea_ice_breakdown_if_slow()
	_gdext_ocean_anomaly_buf_cached = PackedFloat32Array()

	# 节流打点（每个日历年长）
	if _is_annual_log_tick(_daily_climate_call_count):
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
#                   沿岸泄漏权重固定；冷热强弱来自水体温度、洋流路径与热惯性。
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
	if _is_annual_log_tick(_heat_transport_call_count):
		var winter_boost: float = 1.0
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
	# DOTS-Total-CPP（任务 6）：同 tick 复用 short-circuit。
	# climate_daily Pass _PASS_OCEAN_WATER 与 ocean_currents_job 的 phys solve 都
	# 可能调本函数；同一个 SUS tick 内只跑一次（用 phase 作为标识，与 ocean_currents
	# 的 _phase_locked 同语义）。
	if not is_nan(_ocean_water_done_phase) and absf(_ocean_water_done_phase - season_phase) < 0.001:
		return
	# Climate-Weather 2ms Budget — Phase A.3：SoA pipeline 分发。
	var cp := _c()
	if cp != null and cp.use_soa_pipeline and map != null and map.has_soa():
		_ocean_water_pass_soa(map, season_phase, cp)
		_ocean_water_done_phase = season_phase
		return
	var advect_steps: int = max(0, _last_cfg.OCEAN_HEAT_ADVECT_STEPS)
	var heat_mix: float = clampf(_last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0)
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var nb_idx_arr: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var has_idx: bool = nb_idx_arr.size() >= n_cells * 6
	var baseline := PackedFloat32Array()
	var temp_before := PackedFloat32Array()
	var anomaly_state: PackedFloat32Array = _prepare_temperature_transport_anomaly_state(map, n_cells, cells)
	var tta: Dictionary = _temperature_transport_anomaly_knobs(cp)
	var tta_source_cap: float = float(tta["tta_source_cap"])
	var tta_blend_rate: float = float(tta["tta_blend_rate"])
	var tta_zero_current_decay: float = float(tta["tta_zero_current_decay"])
	var cell_pos := PackedVector2Array()
	baseline.resize(n_cells)
	temp_before.resize(n_cells)
	if has_idx:
		cell_pos.resize(n_cells)
	for i in range(n_cells):
		var src_cell: HexCell = cells[i]
		if src_cell._ema_initialized:
			baseline[i] = src_cell.temp_baseline
		else:
			var ny: float = _cube_row_norm(src_cell, _last_cfg)
			baseline[i] = _compute_temperature(ny, src_cell.elevation)
		temp_before[i] = _valid_runtime_temp_or_baseline(src_cell.temperature, baseline[i])
		if has_idx:
			cell_pos[i] = HexUtils.cube_to_world(src_cell.q, src_cell.r, _last_hex_size)

	for i in range(n_cells):
		var cell: HexCell = cells[i]
		if not _is_water(cell.terrain):
			continue
		var cur: Vector2 = cell.ocean_current
		if cur.length_squared() < 1e-6 or advect_steps == 0:
			var decayed_zero: float = _decay_temperature_transport_anomaly(anomaly_state[i], tta_zero_current_decay)
			anomaly_state[i] = decayed_zero
			cell.temperature_transport_anomaly = decayed_zero
			continue
		# 沿 -cur 方向回溯 advect_steps 步，每步选最对齐的水邻居
		var upstream_idx: int = i
		var upstream: HexCell = cell
		var upstream_dir: Vector2 = -cur.normalized()
		for step in range(advect_steps):
			var best_nb: HexCell = null
			var best_idx: int = -1
			var best_dot: float = 0.1  # 需要最低对齐阈值，避免反向邻居被选
			# Daily-Sim SoA Refactor 阶段 2：通过索引取邻居。
			if has_idx:
				var self_wp: Vector2 = cell_pos[upstream_idx]
				var ubase: int = upstream_idx * 6
				for d in range(6):
					var ni: int = nb_idx_arr[ubase + d]
					if ni < 0:
						continue
					var nb: HexCell = cells[ni]
					if not _is_water(nb.terrain):
						continue
					var d_vec: Vector2 = cell_pos[ni] - self_wp
					if d_vec.length_squared() < 1e-6:
						continue
					var dot_v: float = d_vec.normalized().dot(upstream_dir)
					if dot_v > best_dot:
						best_dot = dot_v
						best_idx = ni
			else:
				var self_wp_fb: Vector2 = HexUtils.cube_to_world(upstream.q, upstream.r, _last_hex_size)
				for nb: HexCell in map.get_neighbors(upstream):
					if nb == null or not _is_water(nb.terrain):
						continue
					var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _last_hex_size)
					var d: Vector2 = (nb_wp - self_wp_fb)
					if d.length_squared() < 1e-6:
						continue
					var dot_v: float = d.normalized().dot(upstream_dir)
					if dot_v > best_dot:
						best_dot = dot_v
						best_nb = nb
			if has_idx:
				if best_idx < 0:
					break
				upstream_idx = best_idx
				upstream = cells[upstream_idx]
			else:
				if best_nb == null:
					break
				upstream = best_nb
		var temp_self: float = temp_before[i]
		var temp_up: float = temp_before[upstream_idx] if has_idx else temp_self
		if not has_idx and upstream != cell:
			var upstream_lookup: int = cells.find(upstream)
			if upstream_lookup >= 0 and upstream_lookup < n_cells:
				temp_up = temp_before[upstream_lookup]
		var temp_mixed: float = lerpf(temp_self, temp_up, heat_mix)
		# Fast-tick perf opt (C)：直接写强类型成员（双写，PR-2.3 facade 化前保留）。
		var temp_clamped: float = clampf(temp_mixed, 0.0, 1.0)
		cell.temperature = temp_clamped
		# PR-2.1.3a（ocean water legacy 写路径下移）：cell.temperature 单点 write_f32。
		# temperature_transport_anomaly 字段不在 schema 内，保留 cell.* 直写
		# （由 PR-2.3 HexCell facade 化时统一决定是否加 cid，详见 master 手册 §3.6.2）。
		var anomaly_new: float = _stabilize_temperature_transport_anomaly(
				anomaly_state[i], temp_mixed - baseline[i], tta_source_cap, tta_blend_rate)
		anomaly_state[i] = anomaly_new
		cell.temperature_transport_anomaly = anomaly_new
		if _data_core_world != null:
			var _cid_temp_ow: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
			if _cid_temp_ow >= 0 and cell.index >= 0:
				_data_core_world.write_f32(_cid_temp_ow, int(cell.index), temp_clamped)
	map.temperature_transport_anomaly_arr = anomaly_state
	if _data_core_world != null:
		var _cid_tta_ow: int = _data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if _cid_tta_ow >= 0 and _data_core_world.has_method("write_f32_dense"):
			_data_core_world.write_f32_dense(_cid_tta_ow, anomaly_state)
	# DOTS-Total-CPP（任务 6）：标记本 phase 已跑完，让同 tick caller 短路。
	_ocean_water_done_phase = season_phase

# Daily Sim SoA Refactor 方向 X（A2）：洋流热输运的"陆段"——
# 陆地 cell 从相邻水 cell 收集 temperature_transport_anomaly，按"邻水 cell 的
# ocean_current 是否流向本陆地 cell"加权注入；不再使用独立冬季倍率。
# 必须在 _ocean_water_pass 之后调用——读取的是水段写完的 anomaly。
func _ocean_land_pass(map: MapData, season_phase: float) -> void:
	if _last_cfg == null:
		return
	# Climate-Weather 2ms Budget — Phase A.3：SoA pipeline 分发。
	var cp := _c()
	if cp != null and cp.use_soa_pipeline and map != null and map.has_soa():
		_ocean_land_pass_soa(map, season_phase, cp)
		return
	var coast_leak: float = _last_cfg.COASTAL_HEAT_LEAK
	# 沿岸热泄漏不再使用独立冬季倍率；热异常由水体温度/洋流路径决定。
	var winter_boost: float = 1.0
	var effective_leak: float = coast_leak * winter_boost
	var tta: Dictionary = _temperature_transport_anomaly_knobs(cp)
	var tta_source_cap: float = float(tta["tta_source_cap"])
	var tta_blend_rate: float = float(tta["tta_blend_rate"])
	var tta_decay_rate: float = float(tta["tta_decay_rate"])

	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var nb_idx_arr: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var has_idx: bool = nb_idx_arr.size() >= n_cells * 6
	var cell_pos := PackedVector2Array()
	if has_idx:
		cell_pos.resize(n_cells)
		for i_pos in range(n_cells):
			var pos_cell: HexCell = cells[i_pos]
			cell_pos[i_pos] = HexUtils.cube_to_world(pos_cell.q, pos_cell.r, _last_hex_size)
	for i in range(n_cells):
		var cell: HexCell = cells[i]
		if _is_water(cell.terrain):
			continue
		var weighted_sum: float = 0.0
		var weight_total: float = 0.0
		# Daily-Sim SoA Refactor 阶段 2：同上。
		if has_idx:
			var self_wp2: Vector2 = cell_pos[i]
			var cbase: int = i * 6
			for d in range(6):
				var ni: int = nb_idx_arr[cbase + d]
				if ni < 0:
					continue
				var nb: HexCell = cells[ni]
				if not _is_water(nb.terrain):
					continue
				var cur_nb: Vector2 = nb.ocean_current
				if cur_nb.length_squared() < 1e-6:
					continue
				var dir_nb_to_self: Vector2 = self_wp2 - cell_pos[ni]
				if dir_nb_to_self.length_squared() < 1e-6:
					continue
				var w_nb: float = maxf(0.0, dir_nb_to_self.normalized().dot(cur_nb))
				if w_nb <= 0.0:
					continue
				weighted_sum += nb.temperature_transport_anomaly * w_nb
				weight_total += w_nb
		else:
			var self_wp2_fb: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _last_hex_size)
			for nb: HexCell in map.get_neighbors(cell):
				if nb == null or not _is_water(nb.terrain):
					continue
				var cur_nb: Vector2 = nb.ocean_current
				if cur_nb.length_squared() < 1e-6:
					continue
				var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _last_hex_size)
				# 邻居 → 本 cell 方向（迎流判断：若水 cell 的洋流正是流向陆地方向，权重最大）
				var dir_nb_to_self: Vector2 = (self_wp2_fb - nb_wp)
				if dir_nb_to_self.length_squared() < 1e-6:
					continue
				var w_nb: float = maxf(0.0, dir_nb_to_self.normalized().dot(cur_nb))
				if w_nb <= 0.0:
					continue
				weighted_sum += nb.temperature_transport_anomaly * w_nb
				weight_total += w_nb
		var prev_anomaly: float = cell.temperature_transport_anomaly
		var anomaly_in: float = _decay_temperature_transport_anomaly(prev_anomaly, tta_decay_rate)
		if weight_total > 0.0:
			anomaly_in = _stabilize_temperature_transport_anomaly(
					prev_anomaly, (weighted_sum / weight_total) * effective_leak,
					tta_source_cap, tta_blend_rate)
		cell.temperature_transport_anomaly = anomaly_in
		if absf(anomaly_in) > 1e-5:
			# Fast-tick perf opt (C)：直接读写强类型成员（双写）。
			var fallback_baseline: float = cell.temp_baseline
			if not cell._ema_initialized:
				var ny: float = _cube_row_norm(cell, _last_cfg)
				fallback_baseline = _compute_temperature(ny, cell.elevation)
			var t_prev: float = _valid_runtime_temp_or_baseline(cell.temperature, fallback_baseline)
			var t_new: float = clampf(t_prev + anomaly_in, 0.0, 1.0)
			cell.temperature = t_new
			# PR-2.1.3b（ocean land legacy 写路径下移）：单点 write_f32。
			if _data_core_world != null:
				var _cid_temp_ol: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
				if _cid_temp_ol >= 0 and cell.index >= 0:
					_data_core_world.write_f32(_cid_temp_ol, int(cell.index), t_new)
	var anomaly_land_state: PackedFloat32Array = PackedFloat32Array()
	anomaly_land_state.resize(n_cells)
	for tta_i in range(n_cells):
		var tta_cell = cells[tta_i]
		anomaly_land_state[tta_i] = float((tta_cell as HexCell).temperature_transport_anomaly) if tta_cell != null else 0.0
	map.temperature_transport_anomaly_arr = anomaly_land_state
	if _data_core_world != null:
		var _cid_tta_ol: int = _data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if _cid_tta_ol >= 0 and _data_core_world.has_method("write_f32_dense"):
			_data_core_world.write_f32_dense(_cid_tta_ol, anomaly_land_state)

# ══════════════════════════════════════════════════════════════════════
# Climate-Weather 2ms Budget — Phase A.3：4 段 sub-pass 的 SoA 重写版本
# ══════════════════════════════════════════════════════════════════════
# 设计原则：
#   • 内层循环只读写 MapData SoA 数组与 neighbor_indices_packed，禁止
#     `for cell: HexCell in map.all_cells()` 风格循环（需求 1.2）。
#   • 数值与 legacy 路径 1:1 对齐——直接复用 _compute_temperature /
#     _insolation_season_offset / _vegetation_foliage_density / 等已稳定
#     的函数；仅把 cell.* 字段访问替换为 SoA 数组索引。
#   • round 末由 RefreshClimateDailyJob.flush_soa_to_cells() 把 SoA 一次性
#     写回 HexCell 强类型成员，UI / Baker / Overlay 等只读消费者继续工作。
#   • 涉及"非 SoA 字段"（cell.terrain / landform / vegetation / cover /
#     temperature_breakdown / current_state / temperature_transport_anomaly /
#     upwelling_strength 等）时，仍从 _cell_array[i] 直接读这些字段——
#     SoA 化的边界在"高频读写的连续浮点字段"，慢层结构化字段按需直读。
# ══════════════════════════════════════════════════════════════════════

func _climate_pass_a_soa(map: MapData, season_phase: float, cp: ClimateProfile) -> void:
	# A 修复（climate-temp-pingpong-fix-2026-06）：本 fallback 仍维持旧 schema 语义
	# (写 cell.temperature 直接对应 temp_arr)。在 C++ 接管时（绝大多数生产路径）这
	# 个函数不会被执行——climate_pass_distribution 中所有 stage 都是 path=gdext/data_core，
	# 无 path=gdscript 命中。一旦真的回退到 GDScript 主跑，会偏离 C++ 的 anomaly 合成
	# 语义（baseline + ocean_anom + local_anom + air_anom）；对玩家可见的是温度在
	# 那个 round 内可能跟 wind_surface 的 SoA 值不一致。如果 fallback 命中率上升，
	# 优先级 P1：把 d_albedo/d_coastal/d_landform 写到 map.local_thermal_anomaly_arr，
	# ocean_water/land 的 temp_mixed-baseline 写到 map.ocean_thermal_anomaly_arr，
	# wind_surface_pass 末端做 baseline+anomaly 合成。
	if not _typed_fields_migrated:
		_typed_fields_migrated = true
		print("[fastpath] HexCell typed fields active (SoA)")
		var cells_mig: Array[HexCell] = map.iter_cells()
		for k in range(cells_mig.size()):
			cells_mig[k]._migrate_typed_fields_from_dict()
	if not _insol_driven_path_logged:
		var subsolar_deg: float = rad_to_deg(_subsolar_lat_rad(season_phase))
		var equator_mean: float = _insolation_annual_mean(0.5)
		print("[climate] insolation-driven path active (SoA): subsolar_lat=%+.1f°, equator_annual_mean=%.3f, tilt=%.1f°" % [
			subsolar_deg, equator_mean, float(cp.axial_tilt_deg)
		])
		_insol_driven_path_logged = true

	var moist_scale_now: float = 1.0
	var season_idx: int = int(floor(fposmod(season_phase, 4.0))) & 3
	var sea_level: float = float(_last_cfg.sea_level)
	var inv_above_sea: float = 1.0 / maxf(1.0 - sea_level, 0.001)
	var days_per_year: int = _calendar_days_per_year()
	var annual_ema_alpha: float = 1.0 / float(days_per_year)
	# Native path writes per-cell astronomy SoA; this GDScript fallback mirrors it.
	# B1-C：season_offset 的 amp/gain 提到循环外（一日内常量）。
	var insol_amp: float = 0.20
	var insol_gain: float = 1.0
	if "season_temp_amp" in cp:
		insol_amp = cp.season_temp_amp
	if "insolation_season_gain" in cp:
		insol_gain = cp.insolation_season_gain
	var insol_amp_gain: float = insol_amp * insol_gain
	var insol_dev_min: float = float(cp.get("insolation_dev_clamp_min")) if cp.get("insolation_dev_clamp_min") != null else -1.0
	var insol_dev_max: float = float(cp.get("insolation_dev_clamp_max")) if cp.get("insolation_dev_clamp_max") != null else 1.0
	var axial_tilt_deg: float = float(cp.get("axial_tilt_deg")) if cp.get("axial_tilt_deg") != null else 23.5
	var daylen_amp: float = float(cp.get("insolation_daylen_amp")) if cp.get("insolation_daylen_amp") != null else _INSOLATION_DAYLEN_AMP
	var solar_gain: float = float(cp.get("solar_gain")) if cp.get("solar_gain") != null else 1.0
	var thermal_land: float = float(cp.get("thermal_inertia_land")) if cp.get("thermal_inertia_land") != null else 0.35
	var thermal_water: float = float(cp.get("thermal_inertia_water")) if cp.get("thermal_inertia_water") != null else 0.07
	var thermal_snow: float = float(cp.get("thermal_inertia_snow")) if cp.get("thermal_inertia_snow") != null else 0.09
	var thermal_high: float = float(cp.get("thermal_inertia_high_mountain")) if cp.get("thermal_inertia_high_mountain") != null else 0.16
	var thermal_delta_cap: float = float(cp.get("thermal_daily_delta_cap")) if cp.get("thermal_daily_delta_cap") != null else 0.15
	# 大陆性季节增幅(2026-06-21)：陆地季节强迫×land_continentality 放大其振幅，建立"夏陆>海、
	# 冬陆<海"的真实海陆温差(修温差恒负/大陆性看不出)。海洋=1.0。SAME_SOURCE: C++ pk_season_offset_continental。
	var land_continentality: float = float(cp.get("temp_land_continentality")) if cp.get("temp_land_continentality") != null else 1.55
	# 加速/跳日补偿：把单日 α 换算为多日等效 α_eff=1-(1-α)^dt、delta_cap 乘 dt。
	# dt<=1 时退化为原值，与 C++ pk_thermal_alpha_eff / sea_ice dt 同源。
	var thermal_dt: float = clampf(_consume_climate_dt_days(), 1.0, 30.0)
	var thermal_land_eff: float = thermal_land if thermal_dt <= 1.0 else 1.0 - pow(1.0 - clampf(thermal_land, 0.0, 1.0), thermal_dt)
	var thermal_water_eff: float = thermal_water if thermal_dt <= 1.0 else 1.0 - pow(1.0 - clampf(thermal_water, 0.0, 1.0), thermal_dt)
	var thermal_snow_eff: float = thermal_snow if thermal_dt <= 1.0 else 1.0 - pow(1.0 - clampf(thermal_snow, 0.0, 1.0), thermal_dt)
	var thermal_high_eff: float = thermal_high if thermal_dt <= 1.0 else 1.0 - pow(1.0 - clampf(thermal_high, 0.0, 1.0), thermal_dt)
	var thermal_delta_cap_eff: float = thermal_delta_cap * thermal_dt
	var snowpack_cover_low: float = float(cp.get("snowpack_cover_low")) if cp.get("snowpack_cover_low") != null else 0.05
	var snowpack_cover_full: float = float(cp.get("snowpack_cover_full")) if cp.get("snowpack_cover_full") != null else 0.32
	# DataCore（climate-datacore-migration A-4）：取数入口分支化。
	# _dc_views 非空 → 走 World view（统一数据通道，为 C++ 化扫前置）；
	# 空 → 走 legacy map.xxx_arr 字段访问（行为 100% 等价，bind_map_data 保证
	# view 与 PackedArray 同引用，但开关关闭/未 bind 时退回字段直读）。
	var _dc_views: Dictionary = _climate_views_from_world(cp)
	var _use_dc: bool = not _dc_views.is_empty()
	# Step 3b-1 完成后，原 Stage-1 dry-run probe（在此重复调一次 run_climate_pass_a
	# 仅为验证 ABI）已删除：真实调用点在 _climate_pass_a 入口，C++ 接管时直接 return，
	# 不会再进入本函数。本函数现在只负责 GDScript 端 SoA fallback 路径。
	var n: int = map.soa_size()
	var cells: Array[HexCell] = map.iter_cells()
	# 直接拿底层数组引用避免每次 indexer 调用
	var temp_a: PackedFloat32Array = _dc_views["temp"] if _use_dc else map.temp_arr
	var moist_a: PackedFloat32Array = _dc_views["moisture"] if _use_dc else map.moisture_arr
	# A.2.1.A2 — Dirty Mask：Pass A 写温度时按 epsilon 标记。
	# 进入 round 时调用方（RefreshClimateDailyJob）已根据"季节切换 / 每 30 日 / 加载首日"
	# 决定本 round 的 dirty 起点（mark_all 或 clear），这里只在内层做 epsilon 比对附加标记。
	# 当 use_sparse_climate=false 时跳过 dirty 写，避免无谓 PackedByteArray 写。
	var use_sparse: bool = bool(cp.use_sparse_climate)
	var dirty_mask: PackedByteArray = _dc_views["climate_dirty_mask"] if _use_dc else map.climate_dirty_mask
	const _DIRTY_EPS_TEMP: float = 1.0 / 512.0
	const _DIRTY_EPS_MOIST: float = 1.0 / 512.0
	# A.2.1.A2-fix — 取昨日 global drift（季节驱动的全图同向漂移量），
	# 让本日 dt 减去 drift 再与 epsilon 比，过滤"伪 dirty"。第 1 日 drift=0
	# 时所有 cell 仍会因 dt 自身 > eps 而 mark dirty，由 reset_progress 强制
	# 全图扫已涵盖（_full_sweep_counter=30），无副作用。
	var dt_drift: float = _dt_global_yesterday
	var dm_drift: float = _dm_global_yesterday
	# 本日 drift 累加器：Pass A 末尾一次性除以 n 写回 generator 成员
	var dt_sum_local: float = 0.0
	var dm_sum_local: float = 0.0
	var drift_count_local: int = 0
	var base_moist_a: PackedFloat32Array = _dc_views["base_moisture"] if _use_dc else map.base_moisture_arr
	var elev_a: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
	var is_water_a: PackedByteArray = _dc_views["is_water"] if _use_dc else map.is_water_arr
	var temp_baseline_a: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
	var temp_30d_a: PackedFloat32Array = _dc_views["temp_30d"] if _use_dc else map.temp_30d_arr
	var temp_365d_a: PackedFloat32Array = _dc_views["temp_365d"] if _use_dc else map.temp_365d_arr
	var temp_anom_a: PackedFloat32Array = _dc_views["temp_anomaly"] if _use_dc else map.temp_anomaly_arr
	# B1-A：cell_lat_norm_arr / temp_baseline_year_arr 一次性 bake 后，
	# 内层不再调用 _cube_row_norm / _compute_temperature。
	var lat_arr: PackedFloat32Array = _dc_views["lat_norm"] if _use_dc else map.cell_lat_norm_arr
	var temp_year_arr: PackedFloat32Array = _dc_views["temp_baseline_year"] if _use_dc else map.temp_baseline_year_arr
	# Phase 3a Step 2.1.a：Pass-A SoA 化新增 2 个 view 别名
	var ema_init_a: PackedByteArray = _dc_views["ema_initialized"] if _use_dc else map.ema_initialized_arr
	var season_off_a: PackedFloat32Array = _dc_views["temp_season_offset"] if _use_dc else map.temp_season_offset_arr
	var insol_now_a: PackedFloat32Array = _dc_views["insolation_now"] if _use_dc and _dc_views["insolation_now"].size() == n else map.insolation_now_arr
	var insol_dev_a: PackedFloat32Array = _dc_views["insolation_dev"] if _use_dc and _dc_views["insolation_dev"].size() == n else map.insolation_dev_arr
	var day_length_a: PackedFloat32Array = _dc_views["day_length"] if _use_dc and _dc_views["day_length"].size() == n else map.day_length_arr
	var heat_input_a: PackedFloat32Array = _dc_views["heat_input"] if _use_dc and _dc_views["heat_input"].size() == n else map.heat_input_arr
	var thermal_a: PackedFloat32Array = _dc_views["thermal_energy"] if _use_dc and _dc_views["thermal_energy"].size() == n else map.thermal_energy_arr
	var snowpack_a: PackedFloat32Array = _dc_views["snowpack"] if _use_dc and _dc_views["snowpack"].size() == n else map.snowpack_arr
	var has_lat_lut: bool = map.has_lat_lut() and lat_arr.size() == n and temp_year_arr.size() == n
	# B1-B：内层查表条件（lut 大小已确认且 size = LUT_SIZE+1）。
	for i in range(n):
		var c: HexCell = cells[i]
		# current_state 守卫：旧存档 → 建骨架（这部分仍然走 cell；非热点）
		if c.current_state == null or c.current_state.is_empty():
			c.current_state = {
				"season": season_idx,
				"temperature": 0.0,
				"moisture": base_moist_a[i],
				"snow_cover": 0.0,
				"biome": int(c.terrain),
				"landform": int(c.landform),
				"vegetation": int(c.vegetation),
				"cover": int(c.cover),
			}

		# B1-A/B：纬度与年均温度查表，dev 也走 LUT；fallback 走原函数保证不崩。
		var ny: float
		var temp_year_lat: float
		if has_lat_lut:
			ny = lat_arr[i]
			temp_year_lat = temp_year_arr[i]
		else:
			ny = _cube_row_norm(c, _last_cfg)
			temp_year_lat = DCClimateMath.lat_temp_bell_from_ny(ny)
			if temp_year_lat < 0.0: temp_year_lat = 0.0
			elif temp_year_lat > 1.0: temp_year_lat = 1.0
		var dev_today: float = 0.0
		var insol_now: float = DCClimateMath.compute_daily_insolation(ny, season_phase, axial_tilt_deg, daylen_amp)
		var insol_mean: float = _insolation_annual_mean(ny)
		dev_today = clampf(DCClimateMath.compute_insolation_dev_from_values(ny, insol_now, insol_mean), insol_dev_min, insol_dev_max)
		var day_length: float = DCClimateMath.compute_day_length_norm(ny, season_phase, axial_tilt_deg)
		var heat_input: float = clampf(insol_now * solar_gain, 0.0, 1.0)
		if insol_now_a.size() == n:
			insol_now_a[i] = insol_now
		if insol_dev_a.size() == n:
			insol_dev_a[i] = dev_today
		if day_length_a.size() == n:
			day_length_a[i] = day_length
		if heat_input_a.size() == n:
			heat_input_a[i] = heat_input

		var elevation: float = elev_a[i]
		# 1) 当日湿度
		var moisture_now: float
		if is_water_a[i] != 0:
			moisture_now = base_moist_a[i]
		else:
			var scale_eff: float = moist_scale_now * (1.0 + 0.2 * dev_today)
			var bm: float = base_moist_a[i] * scale_eff
			moisture_now = bm if bm < 1.0 else 1.0
			if moisture_now < 0.0:
				moisture_now = 0.0

		# 2) 当日温度（B1-A：temp_year = temp_baseline_year - alt_penalty(elev)，clamp）
		# alt_penalty 内联双段式，常量走 ALT_PEN_*（同 _alt_penalty / pk_alt_penalty）：
		# lin = elev*ALT_PEN_LINEAR(0.40)；hi = smoothstep(0.45, 1.00, elev) * ALT_PEN_HIGH_AMP(0.22)
		var alt_pen_lin: float = elevation * ALT_PEN_LINEAR
		var alt_pen_hi_t: float = (elevation - ALT_PEN_HIGH_LO) / (ALT_PEN_HIGH_HI - ALT_PEN_HIGH_LO)
		if alt_pen_hi_t < 0.0: alt_pen_hi_t = 0.0
		elif alt_pen_hi_t > 1.0: alt_pen_hi_t = 1.0
		var alt_pen_hi: float = alt_pen_hi_t * alt_pen_hi_t * (3.0 - 2.0 * alt_pen_hi_t) * ALT_PEN_HIGH_AMP
		var temp_year: float = temp_year_lat - (alt_pen_lin + alt_pen_hi)
		if temp_year < 0.0: temp_year = 0.0
		elif temp_year > 1.0: temp_year = 1.0
		# 物理化（2026-06-16）：季节项按吸收短波因子缩放（持久冰封→低吸收）。
		# 用【年均温度 temp_365d_a[i]】作冰封代理（与 C++ p365[i] 同源），避免夏季融化正反馈失控。
		var absorb_factor: float = DCClimateMath.surface_absorbed_factor(is_water_a[i] != 0, temp_365d_a[i])
		# 大陆性增幅：陆地季节强迫放大(海洋=1.0)。SAME_SOURCE: C++ pk_season_offset_continental。
		var continentality: float = 1.0 if is_water_a[i] != 0 else land_continentality
		# 冷侧软压缩（v2）：极向热输送/海洋热库托底，防中纬冬季无限过冷。与 legacy/C++ 同源。
		var season_offset: float = DCClimateMath.compress_season_cooling(insol_amp_gain * absorb_factor * continentality * dev_today)
		var radiative_target: float = clampf(temp_year + season_offset, 0.0, 1.0)

		# 3) 热惯性：日照只生成 radiative target，最终 temp 由长期热储量缓慢逼近。
		var prev_temp_for_thermal: float = thermal_a[i] if thermal_a.size() == n else temp_a[i]
		var prev_energy: float = prev_temp_for_thermal
		if ema_init_a[i] == 0:
			prev_temp_for_thermal = temp_a[i]
			prev_energy = prev_temp_for_thermal
		var alpha_thermal: float = thermal_land_eff
		if is_water_a[i] != 0:
			alpha_thermal = thermal_water_eff
		elif c.cover == CoverType.CV.GLACIER:
			alpha_thermal = thermal_snow_eff
		elif snowpack_a.size() == n and snowpack_a[i] > snowpack_cover_low:
			alpha_thermal = thermal_snow_eff
		elif elevation > 0.70:
			alpha_thermal = thermal_high_eff
		var heat_next: float = lerpf(prev_energy, radiative_target, clampf(alpha_thermal, 0.0, 1.0))
		var temp_now: float = clampf(prev_temp_for_thermal + clampf(heat_next - prev_temp_for_thermal, -thermal_delta_cap_eff, thermal_delta_cap_eff), 0.0, 1.0)
		if thermal_a.size() == n:
			thermal_a[i] = heat_next

		# 4) Pass A 只维护物理 snowpack；视觉 snow_cover 由 weather distribute 统一发布。
		if is_water_a[i] == 0:
			if c.cover == CoverType.CV.GLACIER and snowpack_a.size() == n and snowpack_a[i] < 0.80:
				snowpack_a[i] = 0.80
		elif snowpack_a.size() == n:
			snowpack_a[i] = 0.0

		# 写入 SoA
		c.current_state["season"] = season_idx
		# A.2.1.A2 + fix — 与上一日对比，dt 先减全图 drift 再比 epsilon，过滤季节伪dirty。
		# round 入口的 mark_all（季节切换 / 30 日 / 加载首日）会在 dirty_mask[i] 已为 1 时
		# 跳过本块的 mark（再写 1 不变），所以这块只为"增量稳态"服务。
		if use_sparse:
			var prev_t: float = temp_a[i]
			var prev_m: float = moist_a[i]
			var dt_signed: float = temp_now - prev_t
			var dm_signed: float = moisture_now - prev_m
			# 累积带符号差值，Pass A 末尾算 dt_global = sum / n（全图同向漂移）
			dt_sum_local += dt_signed
			dm_sum_local += dm_signed
			drift_count_local += 1
			# 残差：扣除昨日全图漂移后的"局部异常"
			var dt_res: float = dt_signed - dt_drift
			var dm_res: float = dm_signed - dm_drift
			if dt_res < 0.0: dt_res = -dt_res
			if dm_res < 0.0: dm_res = -dm_res
			if dt_res > _DIRTY_EPS_TEMP or dm_res > _DIRTY_EPS_MOIST:
				dirty_mask[i] = 1
		temp_a[i] = temp_now
		moist_a[i] = moisture_now
		temp_baseline_a[i] = temp_year
		season_off_a[i] = season_offset

		# 5) 温度 EMA
		var m30: float
		var m365: float
		if ema_init_a[i] == 0:
			m30 = temp_now
			m365 = temp_now
			ema_init_a[i] = 1
		else:
			m30 = lerpf(temp_30d_a[i], temp_now, 1.0 / 30.0)
			m365 = lerpf(temp_365d_a[i], temp_now, annual_ema_alpha)
		temp_30d_a[i] = m30
		temp_365d_a[i] = m365
		temp_anom_a[i] = m30 - m365

	# PR-2.1.1（climate Pass-A 写路径下移，SoA 路径）：循环结束后，批量把 9 字段
	# push 到 DCWorld。当 _use_dc=true 时 temp_a 等已是 world view 的 alias，
	# 但 ptrw() / CoW 漏写隐患下我们额外做一次显式 write_f32_indexed 确保同源
	# （多花一次 O(N) 拷贝，N=2400 时 < 0.5ms 可接受）。
	# 当 _use_dc=false 但 _data_core_world != null 时这次写就是必须的（map.*_arr
	# 与 DCWorld 不同源时唯一的 push 时机）。
	# 详见 docs/dots-master-execution-handbook.md §3.4 + §9.2 模板 2。
	# helper 内部守卫 _data_core_world / cid，故此处只判 n > 0。
	#
	# A.2.1.B — Dirty-aware push（dynamic_visual_atlas 35-50ms 长帧根治 M1）：
	#   早先版本用 `_pa_soa_indices = [0..n)` 无差别 push 全图，导致
	#   `world.write_f32_indexed` 内部 `_dirty_mark_indexed` 把整图标脏，
	#   下游 `dynamic_visual_atlas_upload_system` 看到 `mask_dirty_count = 2400`
	#   ⇒ dynamic / ecology / smooth 三个 phase 每天重打包全图 CSR（GDScript
	#   端 18-25ms × 3 phase）。
	#
	#   这里改造：当 `use_sparse=true` 且 climate_dirty_mask 可用时，只 push
	#   mask[i]=1 的 cell（ε 真变 + 季节边界 mark_all + 30 日 full-sweep 已在
	#   round 入口预置 mark 进 mask，所以行为完全等价）。
	#   - mask 全 1（季节切换日 / 30 日 / 加载首日）→ push 退化为全图，与旧版相同。
	#   - mask 稀疏（增量稳态日）→ push k=mask_count，下游 dirty_world 自然
	#     稀疏化，dynamic_visual_atlas 看到的 mask_dirty_count 同步下降。
	#   - use_sparse=false 或 mask 不可用 → 走 else 分支的全图旧路径，0 风险回退。
	if n > 0:
		var _use_sparse_push: bool = use_sparse and dirty_mask.size() == n
		if _use_sparse_push:
			# 1) 先数 mask 中 1 的个数，避免 push_back 多次扩容
			var _k: int = 0
			for _ki in range(n):
				if dirty_mask[_ki] != 0:
					_k += 1
			if _k <= 0:
				pass  # 本日完全没真变（罕见）—— 直接跳过 push
			elif _k >= n:
				# 全图脏：与旧路径完全一致，避免无谓子集分配。
				var _pa_all: PackedInt32Array = PackedInt32Array()
				_pa_all.resize(n)
				for _ki in range(n):
					_pa_all[_ki] = _ki
				_push_f32_to_world(DCComponentIds.CELL_TEMP, _pa_all, temp_a)
				_push_f32_to_world(DCComponentIds.CELL_MOISTURE, _pa_all, moist_a)
				_push_f32_to_world(DCComponentIds.CELL_THERMAL_ENERGY, _pa_all, thermal_a)
				_push_f32_to_world(DCComponentIds.CELL_SNOWPACK, _pa_all, snowpack_a)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_BASELINE, _pa_all, temp_baseline_a)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_SEASON_OFFSET, _pa_all, season_off_a)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_30D, _pa_all, temp_30d_a)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_365D, _pa_all, temp_365d_a)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_ANOMALY, _pa_all, temp_anom_a)
				_push_f32_to_world(DCComponentIds.CELL_INSOLATION_NOW, _pa_all, insol_now_a)
				_push_f32_to_world(DCComponentIds.CELL_INSOLATION_DEV, _pa_all, insol_dev_a)
				_push_f32_to_world(DCComponentIds.CELL_DAY_LENGTH, _pa_all, day_length_a)
				_push_f32_to_world(DCComponentIds.CELL_HEAT_INPUT, _pa_all, heat_input_a)
				_push_u8_to_world(DCComponentIds.CELL_EMA_INITIALIZED, _pa_all, ema_init_a)
			else:
				# 2) 提取 ε 真变子集（mask[i]=1 → idx 收入 _pa_idx；同时同步压缩 9 路 values）
				var _pa_idx: PackedInt32Array = PackedInt32Array()
				_pa_idx.resize(_k)
				var _v_temp: PackedFloat32Array = PackedFloat32Array(); _v_temp.resize(_k)
				var _v_moist: PackedFloat32Array = PackedFloat32Array(); _v_moist.resize(_k)
				var _v_thermal: PackedFloat32Array = PackedFloat32Array(); _v_thermal.resize(_k)
				var _v_snowpack: PackedFloat32Array = PackedFloat32Array(); _v_snowpack.resize(_k)
				var _v_temp_baseline: PackedFloat32Array = PackedFloat32Array(); _v_temp_baseline.resize(_k)
				var _v_season_off: PackedFloat32Array = PackedFloat32Array(); _v_season_off.resize(_k)
				var _v_temp_30d: PackedFloat32Array = PackedFloat32Array(); _v_temp_30d.resize(_k)
				var _v_temp_365d: PackedFloat32Array = PackedFloat32Array(); _v_temp_365d.resize(_k)
				var _v_temp_anom: PackedFloat32Array = PackedFloat32Array(); _v_temp_anom.resize(_k)
				var _v_ema_init: PackedByteArray = PackedByteArray(); _v_ema_init.resize(_k)
				var _w: int = 0
				for _ki in range(n):
					if dirty_mask[_ki] == 0:
						continue
					_pa_idx[_w] = _ki
					_v_temp[_w] = temp_a[_ki]
					_v_moist[_w] = moist_a[_ki]
					_v_thermal[_w] = thermal_a[_ki]
					_v_snowpack[_w] = snowpack_a[_ki]
					_v_temp_baseline[_w] = temp_baseline_a[_ki]
					_v_season_off[_w] = season_off_a[_ki]
					_v_temp_30d[_w] = temp_30d_a[_ki]
					_v_temp_365d[_w] = temp_365d_a[_ki]
					_v_temp_anom[_w] = temp_anom_a[_ki]
					_v_ema_init[_w] = ema_init_a[_ki]
					_w += 1
				_push_f32_to_world(DCComponentIds.CELL_TEMP, _pa_idx, _v_temp)
				_push_f32_to_world(DCComponentIds.CELL_MOISTURE, _pa_idx, _v_moist)
				_push_f32_to_world(DCComponentIds.CELL_THERMAL_ENERGY, _pa_idx, _v_thermal)
				_push_f32_to_world(DCComponentIds.CELL_SNOWPACK, _pa_idx, _v_snowpack)
				# 长期均值字段：mean_diff ≤ 0.005 红线（master 手册 §3.4.3）
				# 注：30d/365d/anomaly 在 ε ≤ 1/512 时人均误差远低于红线，安全。
				_push_f32_to_world(DCComponentIds.CELL_TEMP_BASELINE, _pa_idx, _v_temp_baseline)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_SEASON_OFFSET, _pa_idx, _v_season_off)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_30D, _pa_idx, _v_temp_30d)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_365D, _pa_idx, _v_temp_365d)
				_push_f32_to_world(DCComponentIds.CELL_TEMP_ANOMALY, _pa_idx, _v_temp_anom)
				_push_u8_to_world(DCComponentIds.CELL_EMA_INITIALIZED, _pa_idx, _v_ema_init)
			# 把 push 统计塞进诊断成员，供 climate_daily_system breakdown 抓取（M1 AB 验证）
			_pa_last_pushed_cells = _k
			_pa_last_total_cells = n
			var _pa_ast_all: PackedInt32Array = PackedInt32Array()
			_pa_ast_all.resize(n)
			for _ast_i in range(n):
				_pa_ast_all[_ast_i] = _ast_i
			_push_f32_to_world(DCComponentIds.CELL_INSOLATION_NOW, _pa_ast_all, insol_now_a)
			_push_f32_to_world(DCComponentIds.CELL_INSOLATION_DEV, _pa_ast_all, insol_dev_a)
			_push_f32_to_world(DCComponentIds.CELL_DAY_LENGTH, _pa_ast_all, day_length_a)
			_push_f32_to_world(DCComponentIds.CELL_HEAT_INPUT, _pa_ast_all, heat_input_a)
		else:
			# Sparse 关闭 / mask 不可用：保留旧的全图 push 行为（0 风险回退路径）。
			var _pa_soa_indices: PackedInt32Array = PackedInt32Array()
			_pa_soa_indices.resize(n)
			for _ki in range(n):
				_pa_soa_indices[_ki] = _ki
			_push_f32_to_world(DCComponentIds.CELL_TEMP, _pa_soa_indices, temp_a)
			_push_f32_to_world(DCComponentIds.CELL_MOISTURE, _pa_soa_indices, moist_a)
			_push_f32_to_world(DCComponentIds.CELL_THERMAL_ENERGY, _pa_soa_indices, thermal_a)
			_push_f32_to_world(DCComponentIds.CELL_SNOWPACK, _pa_soa_indices, snowpack_a)
			# 长期均值字段（master 手册 §3.4.3 要求 mean_diff ≤ 0.005 的严格红线）
			_push_f32_to_world(DCComponentIds.CELL_TEMP_BASELINE, _pa_soa_indices, temp_baseline_a)
			_push_f32_to_world(DCComponentIds.CELL_TEMP_SEASON_OFFSET, _pa_soa_indices, season_off_a)
			_push_f32_to_world(DCComponentIds.CELL_TEMP_30D, _pa_soa_indices, temp_30d_a)
			_push_f32_to_world(DCComponentIds.CELL_TEMP_365D, _pa_soa_indices, temp_365d_a)
			_push_f32_to_world(DCComponentIds.CELL_TEMP_ANOMALY, _pa_soa_indices, temp_anom_a)
			_push_f32_to_world(DCComponentIds.CELL_INSOLATION_NOW, _pa_soa_indices, insol_now_a)
			_push_f32_to_world(DCComponentIds.CELL_INSOLATION_DEV, _pa_soa_indices, insol_dev_a)
			_push_f32_to_world(DCComponentIds.CELL_DAY_LENGTH, _pa_soa_indices, day_length_a)
			_push_f32_to_world(DCComponentIds.CELL_HEAT_INPUT, _pa_soa_indices, heat_input_a)
			_push_u8_to_world(DCComponentIds.CELL_EMA_INITIALIZED, _pa_soa_indices, ema_init_a)
			_pa_last_pushed_cells = n
			_pa_last_total_cells = n

	# [DIAG mask_dirty=2400 排查 · 2026-05-20] SoA Pass-A push 末尾路径 dump
	if _daily_climate_call_count <= 3 or _is_annual_log_tick(_daily_climate_call_count):
		var _dirty_after_pa: int = -1
		if _data_core_world != null and _data_core_world.has_method("peek_dirty_count"):
			_dirty_after_pa = int(_data_core_world.peek_dirty_count())
		print("[DIAG pass_a_soa_end] day=%d use_sparse=%s dirty_mask_size=%d _pa_last_pushed=%d _pa_last_total=%d dc_dirty_count=%d" % [
			_daily_climate_call_count, str(use_sparse), dirty_mask.size(),
			_pa_last_pushed_cells, _pa_last_total_cells, _dirty_after_pa,
		])
	# A.2.1.A2-fix — Pass A 完成：把本日全图 drift 写回 generator 成员，供下一日 epsilon 比对扣除。
	# 用 EMA 平滑（α=0.3）避免单日噪声导致 drift 估计抖动；首次（drift_count_local==0）保持原值。
	if drift_count_local > 0:
		var inv_n: float = 1.0 / float(drift_count_local)
		var dt_today: float = dt_sum_local * inv_n
		var dm_today: float = dm_sum_local * inv_n
		const _DRIFT_EMA_ALPHA: float = 0.3
		_dt_global_yesterday = lerpf(_dt_global_yesterday, dt_today, _DRIFT_EMA_ALPHA)
		_dm_global_yesterday = lerpf(_dm_global_yesterday, dm_today, _DRIFT_EMA_ALPHA)

# F.3 helper：按 VegetationType.VEG enum 顺序构建 foliage density table。
# 与 _vegetation_foliage_density() 等价（clamp(transp/0.06, 0, 1)）。第一次调用
# 时填好 cache，后续 zero-cost。
func _build_climate_b_foliage_table() -> PackedFloat32Array:
	if _gdext_climate_b_foliage_table_cached.size() > 0:
		return _gdext_climate_b_foliage_table_cached
	var n_veg: int = VegetationType.VEG.size()
	var table: PackedFloat32Array = PackedFloat32Array()
	table.resize(n_veg)
	for v in range(n_veg):
		var f: float = VegetationType.transpiration(v) / 0.06
		if f < 0.0:
			f = 0.0
		elif f > 1.0:
			f = 1.0
		table[v] = f
	_gdext_climate_b_foliage_table_cached = table
	return _gdext_climate_b_foliage_table_cached

func _climate_pass_b_soa(map: MapData, season_phase: float, cp: ClimateProfile) -> void:
	# A 修复（climate-temp-pingpong-fix-2026-06）：同 _climate_pass_a_soa 的 TODO。
	# 当前 fallback 仍写 cell.temperature 直接；C++ 路径写 cell.local_thermal_anomaly。
	# 局部气候耦合 SoA 版本：在 SoA 上做 albedo / coastal / landform 温度修正 +
	# evap / rain_shadow 湿度修正。复用 legacy 同段算法常量。
	var winter_boost: float = 1.0
	var coast_leak: float = float(_last_cfg.COASTAL_HEAT_LEAK)
	var snow_cool: float = float(cp.snow_albedo_cooling)
	var veg_cool: float = float(cp.vegetation_cooling)
	var diurnal_amp: float = float(cp.landform_diurnal_amp)
	var evap_gain: float = float(cp.evaporation_gain)
	var rs_threshold: float = float(cp.rain_shadow_threshold)
	var rs_factor: float = float(cp.rain_shadow_factor)
	var rs_lookback: int = max(0, int(cp.rain_shadow_lookback))
	var t_freeze: float = float(cp.sea_ice_form_threshold)
	var coupling_gain: float = float(cp.ocean_moisture_coupling_gain)
	# climate-loop-closure Phase 4.1：海冰反照率→温度反馈系数（profile 缺字段默认 0.06）。
	var sea_ice_cool: float = float(cp.sea_ice_albedo_cooling) if cp.get("sea_ice_albedo_cooling") != null else 0.06

	# ─── Phase F.3：DCWorldExt C++ 快路径（charter §7 P1，5.2ms → < 0.5ms）──
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_climate_pass_b flag 已删，现走
	# ext + has_method 探测。触发条件：
	#   1. cp != null
	#   2. _data_core_world_ext 已 bind && has_method("run_climate_pass_b")
	#   3. fast_indexed（neighbor_indices_packed 完整 = n_cells*6）
	#   4. **删除了 `not use_sparse_climate` 检查**——C++ 永远跑 full pass；
	#      如果 sparse runtime 真触发 (path=sparse)，C++ 仍会跑全图，结果与
	#      “GDScript 跑 full” bit-equal（稳态下等价），仅损失 sparse 跳格优化。
	#   5. C++ 端 run_climate_pass_b 返回 ≥ 0
	var nb_idx_for_f3: PackedInt32Array = map.neighbor_indices_packed()
	var n_for_f3: int = map.soa_size()
	var fast_indexed_b: bool = nb_idx_for_f3.size() >= n_for_f3 * 6

	# F.3 无脑诊断：在做任何条件检查之前，把 6 个 precondition 真实值 + 当前
	# ClimateProfile 资源路径 print 一次。F.5 验收时踩过的"flag 表面 true 但
	# fast-path 静默不进"问题在这里被一眼看穿。
	if not _gdext_climate_b_first_attempt_logged:
		_gdext_climate_b_first_attempt_logged = true
		var cp_b_path: String = "<in-memory ClimateProfile>"
		var flag_b_val: bool = true  # use_gdext_climate_pass_b flag removed (dots-flag-prune-pr1, 2026-05-22)
		var sparse_b_val: bool = false
		if cp != null:
			if cp.resource_path != "":
				cp_b_path = cp.resource_path
			sparse_b_val = bool(cp.use_sparse_climate)
		var ext_b_ok: bool = _data_core_world_ext != null
		var has_method_b_ok: bool = ext_b_ok and _data_core_world_ext.has_method("run_climate_pass_b")
		var verdict_b: String = "OK → will try C++"
		if not (flag_b_val and ext_b_ok and has_method_b_ok and fast_indexed_b):
			verdict_b = "FAIL → fall through to GDScript path"
		print("[climate_b/F.3] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_b_path)
		print("  cp.use_gdext_climate_pass_b = %s (flag removed; constant true)" % str(flag_b_val))
		print("  cp.use_sparse_climate = %s（C++ 会跑 full path 等价结果，不阻止）" % str(sparse_b_val))
		print("  _data_core_world_ext != null = %s" % str(ext_b_ok))
		print("  ext.has_method('run_climate_pass_b') = %s" % str(has_method_b_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got nb_size=%d)" % [str(fast_indexed_b), n_for_f3 * 6, nb_idx_for_f3.size()])
		print("  rs_lookback = %d, t_freeze = %.4f, coupling_gain = %.4f" % [rs_lookback, t_freeze, coupling_gain])
		print("  verdict = %s" % verdict_b)

	if cp != null and _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_climate_pass_b") and fast_indexed_b:
		# Stale .dll sig probe（仅作诊断，不阻止下方 C++ 调用——和 F.5 同模板）
		if not _gdext_climate_b_signature_checked:
			_gdext_climate_b_signature_checked = true
			_gdext_climate_b_signature_ok = _validate_gdext_method_signature("run_climate_pass_b", 1)
			print("[climate_b/F.3] sig probe result = %s（仅作诊断）" % str(_gdext_climate_b_signature_ok))
		var tta_arr: PackedFloat32Array = map.temperature_transport_anomaly_arr
		if tta_arr.size() != n_for_f3:
			var cells_for_f3: Array = map.iter_cells()
			tta_arr = PackedFloat32Array()
			tta_arr.resize(n_for_f3)
			for ti in range(n_for_f3):
				var cti: HexCell = cells_for_f3[ti]
				tta_arr[ti] = float(cti.temperature_transport_anomaly)
		var foliage_table: PackedFloat32Array = _build_climate_b_foliage_table()
		var knobs_b: Dictionary = {
			"n_cells": n_for_f3,
			"winter_boost": winter_boost,
			"snow_cool": snow_cool,
			"veg_cool": veg_cool,
			"diurnal_amp": diurnal_amp,
			"evap_gain": evap_gain,
			"rs_threshold": rs_threshold,
			"rs_factor": rs_factor,
			"rs_lookback": rs_lookback,
			"t_freeze": t_freeze,
			"coupling_gain": coupling_gain,
			"coast_leak": coast_leak,
			"season_phase": season_phase,
			"go_sparse": false,
			"neighbor_indices": nb_idx_for_f3,
			"temp_transport_anomaly": tta_arr,
			"foliage_table": foliage_table,
			# climate-loop-closure Phase 4.1：海冰反照率→温度反馈（C++ tail loop 消费）。
			"sea_ice_albedo_cooling": sea_ice_cool,
			"sea_ice_frac": map.sea_ice_frac_arr,
		}
		# storage A/B 同源契约（修复 B 2026-05-14）：pass_a 刚写过 map.temp_arr，C++
		# slot 仍指向旧 buffer；先 refresh 同步。详见 docs/dots-f4-validation.md §2.2.b。
		# refresh-consolidation-2026-06：climate_daily round 守门员，跨 pass 边界由
		# climate_daily_system 在 _run_pass 切换 pass_id 时 mark stale。
		_ensure_climate_daily_round_slots_fresh()
		# ─── sim-2ms-perf-push（plan/climate-pass-b-simd）派发 ───────────────
		# dots-flag-prune-pr1 round 2: use_gdext_pass_b_simd / use_gdext_thread_fallback
		# flag 均已删除——恒走 C++ scalar 入口 run_climate_pass_b，C++ 内部根据 CPU 特性 /
		# n_cells 自动选择 scalar / SIMD / threaded 三档执行路径。
		var _b_dispatch_path: String = "scalar"
		var rc_b: float = -1.0
		if _data_core_world_ext.has_method("run_climate_pass_b_simd"):
			_b_dispatch_path = "simd"
			rc_b = float(_data_core_world_ext.run_climate_pass_b_simd(knobs_b))
		else:
			rc_b = float(_data_core_world_ext.run_climate_pass_b(knobs_b))
		if rc_b < 0.0 and _b_dispatch_path == "simd":
			_b_dispatch_path = "scalar_fallback"
			rc_b = float(_data_core_world_ext.run_climate_pass_b(knobs_b))
		# 强制无脑诊断：前 3 次调用打 rc 值 + 派发路径
		if _gdext_climate_b_runs + _gdext_climate_b_fallbacks < 3:
			print("[climate_b/F.3] DEBUG call#%d: path=%s rc=%.4f n_cells=%d rs_lookback=%d" % [
				_gdext_climate_b_runs + _gdext_climate_b_fallbacks + 1,
				_b_dispatch_path, rc_b, n_for_f3, rs_lookback,
			])
		if rc_b >= 0.0:
			# C++ 写完 cell_temp / cell_moisture SoA。fastpath HexCell 模式下 cell.temperature
			# / cell.moisture 是 SoA alias，下游 pass 直接看到 C++ 写入；不需要回写。
			# 注意：C++ 没写 cell.temperature_breakdown UI dict；该字段只在 inspector
			# 选中时有用，允许 GDScript fallback 路径按需补回。
			_gdext_climate_b_runs += 1
			_gdext_climate_b_total_ms += rc_b
			if _gdext_climate_b_runs == 1:
				print("[climate_b/F.3] gdext path ACTIVE (dispatch=%s) — first run elapsed=%.2fms (legacy GDScript baseline ≈ 5.2ms; charter §7 target < 0.5ms)" % [_b_dispatch_path, rc_b])
			return
		_gdext_climate_b_fallbacks += 1
		# rc<0：C++ 已 push_warning；继续 fall through 到下面的 GDScript 完整路径


	# DataCore（climate-datacore-migration A-4）：取数入口分支化（Pass B）
	var _dc_views: Dictionary = _climate_views_from_world(cp)
	var _use_dc: bool = not _dc_views.is_empty()
	var n: int = map.soa_size()
	var cells: Array[HexCell] = map.iter_cells()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	var temp_a: PackedFloat32Array = _dc_views["temp"] if _use_dc else map.temp_arr
	var moist_a: PackedFloat32Array = _dc_views["moisture"] if _use_dc else map.moisture_arr
	var snowpack_a: PackedFloat32Array = _dc_views["snowpack"] if _use_dc and _dc_views["snowpack"].size() == n else map.snowpack_arr
	var snowpack_cover_low: float = float(cp.get("snowpack_cover_low")) if cp.get("snowpack_cover_low") != null else 0.05
	var snowpack_cover_full: float = float(cp.get("snowpack_cover_full")) if cp.get("snowpack_cover_full") != null else 0.32
	var is_water_a: PackedByteArray = _dc_views["is_water"] if _use_dc else map.is_water_arr
	var pos_x_a: PackedFloat32Array = _dc_views["pos_x"] if _use_dc else map.cell_pos_x_arr
	var pos_y_a: PackedFloat32Array = _dc_views["pos_y"] if _use_dc else map.cell_pos_y_arr
	var elev_a: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
	var lat_a: PackedFloat32Array = _dc_views["lat_norm"] if _use_dc else map.cell_lat_norm_arr
	var temp_baseline_a: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
	# Phase 3a Step 2.1.a：Pass-B 调试 breakdown 读 season offset 走 SoA（Pass-A 同帧写入）
	var season_off_a: PackedFloat32Array = _dc_views["temp_season_offset"] if _use_dc else map.temp_season_offset_arr
	var insol_dev_a: PackedFloat32Array = _dc_views["insolation_dev"] if _use_dc and _dc_views["insolation_dev"].size() == n else map.insolation_dev_arr
	# climate-loop-closure Phase 4.1：海冰浓度（水域反照率反馈输入）。
	var sif_a: PackedFloat32Array = map.sea_ice_frac_arr

	# 温度快照（避免相邻 cell 写干扰）
	var temp_snapshot: PackedFloat32Array = temp_a.duplicate()

	# A.2.1.A3 — 稀疏路径决策：use_sparse_climate=true 且 dirty_ratio ∈ (50/N, 0.8) 时
	# 构建 dirty + 1 跳邻居膨胀的 visit mask，跳过未变化区域。否则全图遍历。
	# Pass B 的 6-邻居读取（沿岸热泄漏 / 蒸发 / 雨影第 1 跳）需要邻居自身被 visit，
	# 这里"dirty + 邻居膨胀"已经覆盖：dirty cell 自己跑，dirty 的邻居也跑（因为 dirty 邻居读
	# 的 6 邻居中可能包含 dirty cell）。第 2 跳以外的雨影 lookback 不会读到 dirty 区域之外
	# 的"被改写的字段"（temp_a / moist_a 在 Pass B 内的修改不影响雨影路径），所以闭合。
	var use_sparse: bool = bool(cp.use_sparse_climate)
	var dirty_mask_b: PackedByteArray = _dc_views["climate_dirty_mask"] if _use_dc else map.climate_dirty_mask
	var dirty_ratio: float = 0.0
	var dirty_count: int = 0
	if use_sparse:
		var dn: int = dirty_mask_b.size()
		for di in range(dn):
			if dirty_mask_b[di] != 0:
				dirty_count += 1
		dirty_ratio = float(dirty_count) / float(dn) if dn > 0 else 0.0
	_last_climate_dirty_ratio = dirty_ratio
	# 自适应回退阈值：dirty 太少（< 50 / N）说明节省效益不抵 mask 构建开销；
	# dirty 太多（> 0.8）说明几乎全图，膨胀后 visited≈100%，直接全图更划算。
	var n_inv: float = (50.0 / float(n)) if n > 0 else 1.0
	var go_sparse: bool = use_sparse and dirty_ratio > n_inv and dirty_ratio < 0.8
	var visit_mask: PackedByteArray = PackedByteArray()
	var visited_count: int = 0
	if go_sparse:
		# 复用 generator 缓存的 visit mask，避免每 round 重新分配。
		if _pass_b_visit_mask.size() != n:
			_pass_b_visit_mask.resize(n)
		visit_mask = _pass_b_visit_mask
		# Step 1：清零 visit mask；Step 2 边膨胀 dirty + 1 跳邻居（合并为一次 pass）
		for vi in range(n):
			visit_mask[vi] = 0
		for vi in range(n):
			if dirty_mask_b[vi] == 0:
				continue
			visit_mask[vi] = 1
			var bb: int = vi * 6
			for d in range(6):
				var ni: int = nb_idx[bb + d]
				if ni >= 0:
					visit_mask[ni] = 1
		# Step 3：统计 visited 比例（用于 breakdown 观察实际节省效益）
		for vi in range(n):
			if visit_mask[vi] != 0:
				visited_count += 1
	_last_climate_visited_ratio = (float(visited_count) / float(n)) if (go_sparse and n > 0) else 1.0
	_last_climate_pass_b_path = "sparse" if go_sparse else "full"

	for i in range(n):
		# A.2.1.A3 — 稀疏跳过未 visit 的 cell（visit_mask 仅在 go_sparse=true 时启用）
		if go_sparse and visit_mask[i] == 0:
			continue
		var c: HexCell = cells[i]
		var temp_now: float = temp_snapshot[i]
		var moisture_now: float = moist_a[i]
		var is_water: bool = is_water_a[i] != 0
		var snow_cover: float = 0.0
		if not is_water and snowpack_a.size() == n:
			snow_cover = smoothstep(snowpack_cover_low, snowpack_cover_full, snowpack_a[i])
			if c.cover == CoverType.CV.GLACIER and snow_cover < 0.80:
				snow_cover = 0.80

		var d_albedo: float = 0.0
		var d_coastal: float = 0.0
		var d_landform: float = 0.0
		var d_evap: float = 0.0
		var d_rain_shadow: float = 1.0

		# ① 反照率（陆地 snow/植被；水域海冰）
		if not is_water:
			d_albedo = -snow_cool * snow_cover
			var foliage: float = _vegetation_foliage_density(c.vegetation)
			d_albedo -= veg_cool * foliage
		elif sea_ice_cool > 0.0 and i < sif_a.size():
			# climate-loop-closure Phase 4.1：海冰反照率→温度反馈（水域）
			d_albedo = -sea_ice_cool * sif_a[i]

		# ② 沿岸热泄漏
		if not is_water:
			var sum_anomaly: float = 0.0
			var n_water: int = 0
			var base_off: int = i * 6
			for d in range(6):
				var ni: int = nb_idx[base_off + d]
				if ni < 0:
					continue
				if is_water_a[ni] != 0:
					sum_anomaly += cells[ni].temperature_transport_anomaly
					n_water += 1
			if n_water > 0:
				d_coastal = coast_leak * (sum_anomaly / float(n_water)) * winter_boost

		# ③ 地形扰动：读取 Pass-A 发布的本地日照偏差，避免独立季节余弦。
		if not is_water:
			var solar_factor: float = 0.0
			if insol_dev_a.size() == n:
				solar_factor = clampf(insol_dev_a[i], -1.0, 1.0)
			else:
				var ny_solar: float = lat_a[i] if lat_a.size() > i else _cube_row_norm(c, _last_cfg)
				solar_factor = clampf(_insol_dev(ny_solar, season_phase), -1.0, 1.0)
			var lf: int = c.landform
			if lf == LandformType.LF.LOWLAND or lf == LandformType.LF.SALT_FLAT or lf == LandformType.LF.DELTA:
				d_landform = diurnal_amp * solar_factor
			elif lf == LandformType.LF.PEAK or lf == LandformType.LF.MOUNTAIN:
				d_landform = -diurnal_amp * 0.5 * maxf(0.0, -solar_factor)

		var temp_final: float = temp_now + d_albedo + d_coastal + d_landform
		if temp_final < 0.0: temp_final = 0.0
		elif temp_final > 1.0: temp_final = 1.0
		temp_a[i] = temp_final

		# 调试 breakdown 仍写到 cell（仅在 UI 选中态非空 dict 时）
		if not c.temperature_breakdown.is_empty():
			c.temperature_breakdown["baseline"] = temp_baseline_a[i]
			c.temperature_breakdown["season"] = season_off_a[i]
			c.temperature_breakdown["albedo"] = d_albedo
			c.temperature_breakdown["coastal"] = d_coastal
			c.temperature_breakdown["landform"] = d_landform

		# ④ 蒸发项（陆地）
		if not is_water:
			var t_eff: float = temp_final + c.temperature_transport_anomaly
			var water_neighbor_w: float = 0.0
			var sum_water_anomaly: float = 0.0
			var bo: int = i * 6
			for dd in range(6):
				var ni2: int = nb_idx[bo + dd]
				if ni2 < 0:
					continue
				if is_water_a[ni2] != 0:
					water_neighbor_w += 1.0
					sum_water_anomaly += cells[ni2].temperature_transport_anomaly
			var avg_water_anomaly: float = 0.0
			if water_neighbor_w > 0.0:
				avg_water_anomaly = sum_water_anomaly / water_neighbor_w
			var nb_w_norm: float = water_neighbor_w / 6.0
			if nb_w_norm > 1.0: nb_w_norm = 1.0
			if t_eff > t_freeze and nb_w_norm > 0.0:
				d_evap = evap_gain * (t_eff - t_freeze) * nb_w_norm
				if coupling_gain > 0.0 and absf(avg_water_anomaly) > 0.001:
					var evap_mul: float = 1.0 + coupling_gain * avg_water_anomaly
					if evap_mul < 0.0: evap_mul = 0.0
					elif evap_mul > 2.0: evap_mul = 2.0
					d_evap *= evap_mul
			if avg_water_anomaly < -0.01 and nb_w_norm > 0.0 and coupling_gain > 0.0:
				d_evap += -evap_gain * (-avg_water_anomaly) * nb_w_norm * coupling_gain * 0.5

		# ⑤ 雨影项（陆地，简化版：只对 1 跳上风邻居判断；rs_lookback>1 仍走 legacy 多步追踪不在 SoA 重写中）
		if not is_water and rs_lookback > 0:
			var ny: float = _cube_row_norm(c, _last_cfg)
			var jitter: float = sin(float(c.q) * 0.31 + float(c.r) * 0.47) * 0.05
			var wind: Vector2 = WindBeltScript.wind_at(ny, season_phase, jitter)
			if wind.length_squared() > 1e-6:
				var max_upwind_h: float = elev_a[i]
				var w_dir: Vector2 = wind.normalized()
				var probe_idx: int = i
				for step in range(rs_lookback):
					var best_idx: int = -1
					var best_dot: float = 0.1
					var pwx: float = pos_x_a[probe_idx]
					var pwy: float = pos_y_a[probe_idx]
					var pbase: int = probe_idx * 6
					for d3 in range(6):
						var ni3: int = nb_idx[pbase + d3]
						if ni3 < 0:
							continue
						var dx: float = pwx - pos_x_a[ni3]
						var dy: float = pwy - pos_y_a[ni3]
						var len2: float = dx * dx + dy * dy
						if len2 < 1e-6:
							continue
						var inv_len: float = 1.0 / sqrt(len2)
						var dotv: float = (dx * w_dir.x + dy * w_dir.y) * inv_len
						if dotv > best_dot:
							best_dot = dotv
							best_idx = ni3
					if best_idx < 0:
						break
					probe_idx = best_idx
					if elev_a[probe_idx] > max_upwind_h:
						max_upwind_h = elev_a[probe_idx]
				if max_upwind_h - elev_a[i] >= rs_threshold:
					d_rain_shadow = rs_factor

		var moisture_final: float = (moisture_now + d_evap) * d_rain_shadow
		if moisture_final < 0.0: moisture_final = 0.0
		elif moisture_final > 1.0: moisture_final = 1.0
		moist_a[i] = moisture_final

	# PR-2.1.2（climate Pass-B SoA 路径）：循环结束后批量 push temp_a / moist_a 到 DCWorld。
	# 与 PR-2.1.1 SoA 收尾对称（详见 docs/dots-master-execution-handbook.md §3.5）。
	#
	# A.2.1.B — Dirty-aware push（M1 续）：复用 Pass-A 的 climate_dirty_mask 子集，
	# 避免在 Pass-A 已稀疏化之后再被本 pass 全图覆盖。dirty_mask 不可用 / 大小不符
	# → 退回旧的全图 push（0 风险路径）。
	if _data_core_world != null and n > 0:
		var _pb_dirty_mask: PackedByteArray = map.climate_dirty_mask if map != null else PackedByteArray()
		var _pb_use_sparse: bool = bool(cp.use_sparse_climate) and _pb_dirty_mask.size() == n
		var _cid_temp_bs: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
		var _cid_moist_bs: int = _data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] Pass-B push 路径决策点
		var _pb_dirty_count_local: int = 0
		var _pb_path_tag: String = ""
		if _pb_use_sparse:
			var _kb: int = 0
			for _ki in range(n):
				if _pb_dirty_mask[_ki] != 0:
					_kb += 1
			if _kb > 0 and _kb < n:
				var _pb_idx_sub: PackedInt32Array = PackedInt32Array(); _pb_idx_sub.resize(_kb)
				var _pb_temp_sub: PackedFloat32Array = PackedFloat32Array(); _pb_temp_sub.resize(_kb)
				var _pb_moist_sub: PackedFloat32Array = PackedFloat32Array(); _pb_moist_sub.resize(_kb)
				var _wb: int = 0
				for _ki in range(n):
					if _pb_dirty_mask[_ki] == 0:
						continue
					_pb_idx_sub[_wb] = _ki
					_pb_temp_sub[_wb] = temp_a[_ki]
					_pb_moist_sub[_wb] = moist_a[_ki]
					_wb += 1
				if _cid_temp_bs >= 0:
					_data_core_world.write_f32_indexed(_cid_temp_bs, _pb_idx_sub, _pb_temp_sub)
				if _cid_moist_bs >= 0:
					_data_core_world.write_f32_indexed(_cid_moist_bs, _pb_idx_sub, _pb_moist_sub)
				_pb_path_tag = "sparse_subset"
				_pb_dirty_count_local = _kb
			elif _kb >= n:
				# 全图脏：退化为全图 push（与旧路径完全一致）
				var _pb_all: PackedInt32Array = PackedInt32Array(); _pb_all.resize(n)
				for _ki in range(n):
					_pb_all[_ki] = _ki
				if _cid_temp_bs >= 0:
					_data_core_world.write_f32_indexed(_cid_temp_bs, _pb_all, temp_a)
				if _cid_moist_bs >= 0:
					_data_core_world.write_f32_indexed(_cid_moist_bs, _pb_all, moist_a)
				_pb_path_tag = "sparse_fullmask"
				_pb_dirty_count_local = n
			else:
				_pb_path_tag = "sparse_zero_skip"
				_pb_dirty_count_local = 0
			# _kb == 0 → 无 dirty，跳过 push
		else:
			var _pb_soa_indices: PackedInt32Array = PackedInt32Array()
			_pb_soa_indices.resize(n)
			for _ki in range(n):
				_pb_soa_indices[_ki] = _ki
			if _cid_temp_bs >= 0:
				_data_core_world.write_f32_indexed(_cid_temp_bs, _pb_soa_indices, temp_a)
			if _cid_moist_bs >= 0:
				_data_core_world.write_f32_indexed(_cid_moist_bs, _pb_soa_indices, moist_a)
			_pb_path_tag = "fallback_full"
			_pb_dirty_count_local = n
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] Pass-B push 完成后路径 dump
		if _daily_climate_call_count <= 3 or _is_annual_log_tick(_daily_climate_call_count):
			var _dirty_after_pb: int = -1
			if _data_core_world.has_method("peek_dirty_count"):
				_dirty_after_pb = int(_data_core_world.peek_dirty_count())
			print("[DIAG pass_b_push] day=%d path=%s use_sparse=%s mask_size=%d wrote=%d dc_dirty_count=%d" % [
				_daily_climate_call_count, _pb_path_tag, str(_pb_use_sparse),
				_pb_dirty_mask.size(), _pb_dirty_count_local, _dirty_after_pb,
			])

func _ocean_water_pass_soa(map: MapData, season_phase: float, cp: ClimateProfile) -> void:
	# A 修复（climate-temp-pingpong-fix-2026-06）：同 _climate_pass_a_soa 的 TODO。
	# 当前 fallback 仍写 cell.temperature 直接；C++ 路径写 cell.ocean_thermal_anomaly。
	var advect_steps: int = max(0, _last_cfg.OCEAN_HEAT_ADVECT_STEPS)
	var heat_mix: float = clampf(_last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0)
	var tta: Dictionary = _temperature_transport_anomaly_knobs(cp)
	var tta_source_cap: float = float(tta["tta_source_cap"])
	var tta_blend_rate: float = float(tta["tta_blend_rate"])
	var tta_zero_current_decay: float = float(tta["tta_zero_current_decay"])
	# DataCore（climate-datacore-migration A-4）：取数入口分支化（Ocean Water）
	var _dc_views: Dictionary = _climate_views_from_world(cp)
	var _use_dc: bool = not _dc_views.is_empty()
	var n: int = map.soa_size()
	var cells: Array[HexCell] = map.iter_cells()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	var temp_a: PackedFloat32Array = _dc_views["temp"] if _use_dc else map.temp_arr
	var temp_baseline_a: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
	var elev_a: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
	var is_water_a: PackedByteArray = _dc_views["is_water"] if _use_dc else map.is_water_arr
	var pos_x_a: PackedFloat32Array = _dc_views["pos_x"] if _use_dc else map.cell_pos_x_arr
	var pos_y_a: PackedFloat32Array = _dc_views["pos_y"] if _use_dc else map.cell_pos_y_arr
	var ocx_a: PackedFloat32Array = _dc_views["ocean_current_x"] if _use_dc else map.ocean_current_x_arr
	var ocy_a: PackedFloat32Array = _dc_views["ocean_current_y"] if _use_dc else map.ocean_current_y_arr
	var lat_a: PackedFloat32Array = _dc_views["lat_norm"] if _use_dc else map.cell_lat_norm_arr
	# Phase 3a Step 2.1.a：ema_initialized SoA 别名
	var ema_init_a: PackedByteArray = _dc_views["ema_initialized"] if _use_dc else map.ema_initialized_arr

	# baseline + temp_before 快照。复用 PackedArray，避免每个 climate round 分配。
	# DOTS boundary：优先读 lat_norm SoA，避免逐 HexCell 调 _cube_row_norm。
	if _gdext_ocean_baseline_work_buf.size() != n:
		_gdext_ocean_baseline_work_buf.resize(n)
	if _gdext_ocean_temp_before_work_buf.size() != n:
		_gdext_ocean_temp_before_work_buf.resize(n)
	var baseline: PackedFloat32Array = _gdext_ocean_baseline_work_buf
	var temp_before: PackedFloat32Array = _gdext_ocean_temp_before_work_buf
	for i in range(n):
		if ema_init_a[i] != 0:
			baseline[i] = temp_baseline_a[i]
		else:
			var ny: float = lat_a[i] if lat_a.size() > i else _cube_row_norm(cells[i], _last_cfg)
			baseline[i] = _compute_temperature(ny, elev_a[i])
		var t0: float = temp_a[i]
		temp_before[i] = _valid_runtime_temp_or_baseline(t0, baseline[i])

	# ─── Phase F.2a：DCWorldExt C++ 快路径（charter §7 P1，3.4ms → < 0.5ms）──
	# baseline + temp_before 已经预算，不需要再翻译 _compute_temperature 到 C++。
	# 触发条件全 true 才进 C++。anomaly_out 是 [n] 浮点 scratch buffer，C++ 写
	# water cell 的 anomaly，land pass 后续覆盖 land cell。
	#
	# 与 F.5 同模板：精确诊断 print + sig probe + DEBUG print + fast-path
	if not _gdext_ocean_water_first_attempt_logged:
		_gdext_ocean_water_first_attempt_logged = true
		var cp_path_w: String = "<in-memory>"
		var flag_w: bool = true  # use_gdext_ocean_water flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp != null and cp.resource_path != "":
			cp_path_w = cp.resource_path
		var ext_w_ok: bool = _data_core_world_ext != null
		var has_w_ok: bool = ext_w_ok and _data_core_world_ext.has_method("run_ocean_water_pass")
		var fast_w_ok: bool = nb_idx.size() >= n * 6
		var verdict_w: String = "OK → will try C++"
		if not (flag_w and ext_w_ok and has_w_ok and fast_w_ok):
			verdict_w = "FAIL → fall through to GDScript"
		print("[ocean_water/F.2a] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path_w)
		print("  cp.use_gdext_ocean_water = %s (flag removed; constant true)" % str(flag_w))
		print("  _data_core_world_ext != null = %s" % str(ext_w_ok))
		print("  ext.has_method('run_ocean_water_pass') = %s" % str(has_w_ok))
		print("  fast_indexed = %s (n=%d nb=%d)" % [str(fast_w_ok), n, nb_idx.size()])
		print("  advect_steps=%d heat_mix=%.4f" % [advect_steps, heat_mix])
		print("  verdict = %s" % verdict_w)

	if cp != null and _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_ocean_water_pass") and nb_idx.size() >= n * 6:
		if not _gdext_ocean_water_signature_checked:
			_gdext_ocean_water_signature_checked = true
			_gdext_ocean_water_signature_ok = _validate_gdext_method_signature("run_ocean_water_pass", 1)
			print("[ocean_water/F.2a] sig probe result = %s（仅作诊断）" % str(_gdext_ocean_water_signature_ok))
		# C++ 会创建 fresh anomaly_out 并写回 knobs。这里传复用 buffer 只为满足
		# 旧签名，避免额外 cells → array 打包。
		if _gdext_ocean_anomaly_work_buf.size() != n:
			_gdext_ocean_anomaly_work_buf.resize(n)
		var anomaly_buf: PackedFloat32Array = _gdext_ocean_anomaly_work_buf
		var prev_anomaly: PackedFloat32Array = _prepare_temperature_transport_anomaly_state(map, n, cells)
		for ai in range(n):
			anomaly_buf[ai] = prev_anomaly[ai]
		var knobs_w: Dictionary = {
			"n_cells": n,
			"advect_steps": advect_steps,
			"heat_mix": heat_mix,
			"neighbor_indices": nb_idx,
			"baseline_arr": baseline,
			"temp_before_arr": temp_before,
			"anomaly_out": anomaly_buf,
			"ocean_current_x_arr": ocx_a,
			"ocean_current_y_arr": ocy_a,
		}
		_apply_temperature_transport_anomaly_knobs(knobs_w, tta)
		# storage A/B 同源契约（修复 B 2026-05-14）：climate_b 已 flush 到 map，
		# 但本 pass 还要读 map.is_water_arr / cell_lat_norm_arr 等静态/上一段写过的字段；
		# refresh 后保证 C++ slot 与 map 一致。详见 docs/dots-f4-validation.md §2.2.b。
		# refresh-consolidation-2026-06：climate_daily round 守门员。
		_ensure_climate_daily_round_slots_fresh()
		# ─── sim-2ms-perf-push（plan/ocean-water-land-simd）派发 ─────────────
		# dots-flag-prune-pr1 round 2: use_gdext_ocean_water_simd / use_gdext_thread_fallback
		# flag 均已删除——恒走 C++ scalar 入口 run_ocean_water_pass，C++ 内部根据 CPU
		# 特性 / n_cells 自动选择 scalar / SIMD / threaded 三档执行路径。
		var _w_dispatch_path: String = "scalar"
		var rc_w: float = float(_data_core_world_ext.run_ocean_water_pass(knobs_w))
		if rc_w < 0.0 and _data_core_world_ext.has_method("run_ocean_water_pass_thread"):
			_w_dispatch_path = "thread_fallback"
			rc_w = float(_data_core_world_ext.run_ocean_water_pass_thread(knobs_w, 4))
		if _gdext_ocean_water_runs + _gdext_ocean_water_fallbacks < 3:
			print("[ocean_water/F.2a] DEBUG call#%d: path=%s rc=%.4f n=%d advect=%d" % [
				_gdext_ocean_water_runs + _gdext_ocean_water_fallbacks + 1,
				_w_dispatch_path, rc_w, n, advect_steps,
			])
		if rc_w >= 0.0:
			# §11 CoW fix: C++ 创建了新的 anomaly 数组并写回了 knobs Dictionary。
			# 必须从 dict 重新读取，原始 anomaly_buf 因 CoW detach 仍是旧数据。
			anomaly_buf = knobs_w["anomaly_out"]
			# 不在 water pass 回写 HexCell.temperature_transport_anomaly：land pass
			# 会直接复用该 buffer，并在下一片统一回写。这样 ocean_water 不再承担
			# 2400 次 facade 属性写。
			# 顺便把 anomaly_buf 缓存给后续 land pass C++ 路径使用，避免再
			# 次 cells → PackedArray 拷贝（_apply_ocean_anomaly_to_cells 之后再清）
			_gdext_ocean_anomaly_buf_cached = anomaly_buf
			# 把 baseline 也 stash 一份给 land pass 当 t_prev 兜底（修复正反馈 bug）
			_gdext_ocean_baseline_arr_cached = baseline
			# ocean_current 同样 cache 给 land pass 复用。
			_gdext_ocean_current_x_arr_cached = ocx_a
			_gdext_ocean_current_y_arr_cached = ocy_a
			_gdext_ocean_water_runs += 1
			_gdext_ocean_water_total_ms += rc_w
			if _gdext_ocean_water_runs == 1:
				print("[ocean_water/F.2a] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 3.4ms; charter §7 target < 0.5ms)" % rc_w)
			return
		_gdext_ocean_water_fallbacks += 1
		# rc<0：C++ 已 push_warning；fall through 到下面 GDScript 完整路径


	for i in range(n):
		if is_water_a[i] == 0:
			continue
		var cur_x: float = ocx_a[i]
		var cur_y: float = ocy_a[i]
		var cur_len2: float = cur_x * cur_x + cur_y * cur_y
		if cur_len2 < 1e-6 or advect_steps == 0:
			var decayed_zero: float = _decay_temperature_transport_anomaly(
					cells[i].temperature_transport_anomaly, tta_zero_current_decay)
			cells[i].temperature_transport_anomaly = decayed_zero
			continue
		var inv_cur: float = 1.0 / sqrt(cur_len2)
		var up_dx: float = -cur_x * inv_cur
		var up_dy: float = -cur_y * inv_cur

		var upstream_idx: int = i
		for step in range(advect_steps):
			var best_idx: int = -1
			var best_dot: float = 0.1
			var swx: float = pos_x_a[upstream_idx]
			var swy: float = pos_y_a[upstream_idx]
			var ub: int = upstream_idx * 6
			for d in range(6):
				var ni: int = nb_idx[ub + d]
				if ni < 0:
					continue
				if is_water_a[ni] == 0:
					continue
				var dx: float = pos_x_a[ni] - swx
				var dy: float = pos_y_a[ni] - swy
				var len2: float = dx * dx + dy * dy
				if len2 < 1e-6:
					continue
				var inv_len: float = 1.0 / sqrt(len2)
				var dot_v: float = (dx * up_dx + dy * up_dy) * inv_len
				if dot_v > best_dot:
					best_dot = dot_v
					best_idx = ni
			if best_idx < 0:
				break
			upstream_idx = best_idx

		var temp_self: float = temp_before[i]
		var temp_up: float = temp_before[upstream_idx]
		var temp_mixed: float = lerpf(temp_self, temp_up, heat_mix)
		if temp_mixed < 0.0: temp_mixed = 0.0
		elif temp_mixed > 1.0: temp_mixed = 1.0
		temp_a[i] = temp_mixed
		cells[i].temperature_transport_anomaly = _stabilize_temperature_transport_anomaly(
				cells[i].temperature_transport_anomaly, temp_mixed - baseline[i],
				tta_source_cap, tta_blend_rate)

	# PR-2.1.3a（ocean water SoA 路径）：循环结束后批量 push temp_a 到 DCWorld。
	#
	# A.2.1.B — Dirty 范围收窄 + ε 真变（M1 续）：本 pass 只修改水域 cell 的温度。
	# 利用 pass 入口快照 `temp_before`（已在 line ~6611 填好）做差分：
	#   - 仅 push 水域 (is_water_a[i]!=0) 且 |temp_a[i] - temp_before[i]| > ε 的 cell。
	# 这样 dirty mask 只包含"洋流热传输实际改了温度"的水 cell，下游
	# dynamic_visual_atlas / sea_ice / weather 能精准消费。
	# ε 与 climate Pass-A 同源（_PUSH_EPS_TEMP = 1/512）。
	if _data_core_world != null and n > 0:
		var _ow_n_changed: int = 0
		for _ki in range(n):
			if is_water_a[_ki] == 0:
				continue
			var _d: float = temp_a[_ki] - temp_before[_ki]
			if _d < 0.0: _d = -_d
			if _d > _PUSH_EPS_TEMP:
				_ow_n_changed += 1
		if _ow_n_changed > 0:
			var _ow_indices: PackedInt32Array = PackedInt32Array(); _ow_indices.resize(_ow_n_changed)
			var _ow_temp: PackedFloat32Array = PackedFloat32Array(); _ow_temp.resize(_ow_n_changed)
			var _ow_w: int = 0
			for _ki in range(n):
				if is_water_a[_ki] == 0:
					continue
				var _d2: float = temp_a[_ki] - temp_before[_ki]
				if _d2 < 0.0: _d2 = -_d2
				if _d2 <= _PUSH_EPS_TEMP:
					continue
				_ow_indices[_ow_w] = _ki
				_ow_temp[_ow_w] = temp_a[_ki]
				_ow_w += 1
			var _cid_temp_ows: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
			if _cid_temp_ows >= 0:
				_data_core_world.write_f32_indexed(_cid_temp_ows, _ow_indices, _ow_temp)
	var anomaly_soa_state: PackedFloat32Array = PackedFloat32Array()
	anomaly_soa_state.resize(n)
	for tta_i in range(n):
		anomaly_soa_state[tta_i] = float(cells[tta_i].temperature_transport_anomaly) if cells[tta_i] != null else 0.0
	map.temperature_transport_anomaly_arr = anomaly_soa_state
	if _data_core_world != null:
		var _cid_tta_ows: int = _data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if _cid_tta_ows >= 0 and _data_core_world.has_method("write_f32_dense"):
			_data_core_world.write_f32_dense(_cid_tta_ows, anomaly_soa_state)

func _ocean_land_pass_soa(map: MapData, season_phase: float, cp: ClimateProfile) -> void:
	# A 修复（climate-temp-pingpong-fix-2026-06）：同 _climate_pass_a_soa 的 TODO。
	# 当前 fallback 仍写 cell.temperature 直接；C++ 路径累加到 cell.ocean_thermal_anomaly。
	var coast_leak: float = _last_cfg.COASTAL_HEAT_LEAK
	var winter_boost: float = 1.0
	var effective_leak: float = coast_leak * winter_boost
	var tta: Dictionary = _temperature_transport_anomaly_knobs(cp)
	var tta_source_cap: float = float(tta["tta_source_cap"])
	var tta_blend_rate: float = float(tta["tta_blend_rate"])
	var tta_decay_rate: float = float(tta["tta_decay_rate"])

	# DataCore（climate-datacore-migration A-4）：取数入口分支化（Ocean Land）
	var _dc_views: Dictionary = _climate_views_from_world(cp)
	var _use_dc: bool = not _dc_views.is_empty()
	var n: int = map.soa_size()
	var cells: Array[HexCell] = map.iter_cells()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()

	# ─── Phase F.2b：DCWorldExt C++ 快路径（charter §7 P1，3.4ms → < 0.5ms）──
	# 与 water pass 同模板。anomaly_inout 是 [n] 浮点 in/out buffer：water pass
	# 已写好 water cell 的 anomaly（如果 water pass 也走 C++，直接复用 cached
	# buffer 省一次 cells→array 拷贝）；land pass 写每个 land cell 的 anomaly。
	if not _gdext_ocean_land_first_attempt_logged:
		_gdext_ocean_land_first_attempt_logged = true
		var cp_path_l: String = "<in-memory>"
		var flag_l: bool = true  # use_gdext_ocean_land flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp != null and cp.resource_path != "":
			cp_path_l = cp.resource_path
		var ext_l_ok: bool = _data_core_world_ext != null
		var has_l_ok: bool = ext_l_ok and _data_core_world_ext.has_method("run_ocean_land_pass")
		var fast_l_ok: bool = nb_idx.size() >= n * 6
		var verdict_l: String = "OK → will try C++"
		if not (flag_l and ext_l_ok and has_l_ok and fast_l_ok):
			verdict_l = "FAIL → fall through to GDScript"
		print("[ocean_land/F.2b] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path_l)
		print("  cp.use_gdext_ocean_land = %s (flag removed; constant true)" % str(flag_l))
		print("  _data_core_world_ext != null = %s" % str(ext_l_ok))
		print("  ext.has_method('run_ocean_land_pass') = %s" % str(has_l_ok))
		print("  fast_indexed = %s (n=%d nb=%d)" % [str(fast_l_ok), n, nb_idx.size()])
		print("  effective_leak=%.4f (coast_leak=%.4f winter_boost=%.4f)" % [effective_leak, coast_leak, winter_boost])
		print("  verdict = %s" % verdict_l)

	if cp != null and _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_ocean_land_pass") and nb_idx.size() >= n * 6:
		if not _gdext_ocean_land_signature_checked:
			_gdext_ocean_land_signature_checked = true
			_gdext_ocean_land_signature_ok = _validate_gdext_method_signature("run_ocean_land_pass", 1)
			print("[ocean_land/F.2b] sig probe result = %s（仅作诊断）" % str(_gdext_ocean_land_signature_ok))
		# 准备 anomaly_inout：优先复用 water pass 已 cache 的 buffer；否则从
		# cells 拷出（water pass 走 GDScript 时也兼容）。
		var anomaly_io: PackedFloat32Array
		if _gdext_ocean_anomaly_buf_cached.size() == n:
			anomaly_io = _gdext_ocean_anomaly_buf_cached
		else:
			anomaly_io = PackedFloat32Array()
			anomaly_io.resize(n)
			for ai in range(n):
				anomaly_io[ai] = float(cells[ai].temperature_transport_anomaly)
		# 准备 fallback_baseline_arr：优先复用 water pass cache；否则现场重算
		# （ema_init 分支 + _compute_temperature 兜底，与 GDScript 原版对齐）
		var fallback_baseline_arr: PackedFloat32Array
		if _gdext_ocean_baseline_arr_cached.size() == n:
			fallback_baseline_arr = _gdext_ocean_baseline_arr_cached
		else:
			fallback_baseline_arr = PackedFloat32Array()
			fallback_baseline_arr.resize(n)
			var temp_baseline_a_l: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
			var elev_a_l: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
			var lat_a_l: PackedFloat32Array = _dc_views["lat_norm"] if _use_dc else map.cell_lat_norm_arr
			var ema_init_a_l: PackedByteArray = _dc_views["ema_initialized"] if _use_dc else map.ema_initialized_arr
			for bi in range(n):
				if ema_init_a_l[bi] != 0:
					fallback_baseline_arr[bi] = temp_baseline_a_l[bi]
				else:
					var ny_b: float = lat_a_l[bi] if lat_a_l.size() > bi else _cube_row_norm(cells[bi], _last_cfg)
					fallback_baseline_arr[bi] = _compute_temperature(ny_b, elev_a_l[bi])
		# 准备 ocean_current x/y：优先复用 water pass cache；否则从 cells 提取
		var ocx_arr_l: PackedFloat32Array
		var ocy_arr_l: PackedFloat32Array
		if _gdext_ocean_current_x_arr_cached.size() == n and _gdext_ocean_current_y_arr_cached.size() == n:
			ocx_arr_l = _gdext_ocean_current_x_arr_cached
			ocy_arr_l = _gdext_ocean_current_y_arr_cached
		else:
			ocx_arr_l = PackedFloat32Array()
			ocy_arr_l = PackedFloat32Array()
			ocx_arr_l.resize(n)
			ocy_arr_l.resize(n)
			for ci2 in range(n):
				var cci: HexCell = cells[ci2]
				ocx_arr_l[ci2] = cci.ocean_current.x
				ocy_arr_l[ci2] = cci.ocean_current.y
		var knobs_l: Dictionary = {
			"n_cells": n,
			"effective_leak": effective_leak,
			"neighbor_indices": nb_idx,
			"anomaly_inout": anomaly_io,
			"fallback_baseline_arr": fallback_baseline_arr,
			"ocean_current_x_arr": ocx_arr_l,
			"ocean_current_y_arr": ocy_arr_l,
		}
		_apply_temperature_transport_anomaly_knobs(knobs_l, _temperature_transport_anomaly_knobs(cp))
		# storage A/B 同源契约（修复 B 2026-05-14）：ocean_water 已 flush 到 map，
		# refresh 让本 pass C++ slot 看到最新海洋温度修正。详见 docs/dots-f4-validation.md §2.2.b。
		# refresh-consolidation-2026-06：climate_daily round 守门员；ocean_water→ocean_land
		# 的跨 pass mark stale 由 climate_daily_system._run_pass 负责。
		_ensure_climate_daily_round_slots_fresh()
		# ─── sim-2ms-perf-push（plan/ocean-water-land-simd）派发 ─────────────
		# dots-flag-prune-pr1 round 2: use_gdext_ocean_land_simd / use_gdext_thread_fallback
		# flag 均已删除——恒走 C++ scalar 入口 run_ocean_land_pass，C++ 内部根据 CPU
		# 特性 / n_cells 自动选择 scalar / SIMD / threaded 三档执行路径。
		var _l_dispatch_path: String = "scalar"
		var rc_l: float = float(_data_core_world_ext.run_ocean_land_pass(knobs_l))
		if rc_l < 0.0 and _data_core_world_ext.has_method("run_ocean_land_pass_thread"):
			_l_dispatch_path = "thread_fallback"
			rc_l = float(_data_core_world_ext.run_ocean_land_pass_thread(knobs_l, 4))
		if _gdext_ocean_land_runs + _gdext_ocean_land_fallbacks < 3:
			print("[ocean_land/F.2b] DEBUG call#%d: path=%s rc=%.4f n=%d effective_leak=%.4f" % [
				_gdext_ocean_land_runs + _gdext_ocean_land_fallbacks + 1,
				_l_dispatch_path, rc_l, n, effective_leak,
			])
		if rc_l >= 0.0:
			# §11 CoW fix: C++ 创建了新的 anomaly 数组并写回了 knobs Dictionary。
			# 必须从 dict 重新读取。
			anomaly_io = knobs_l["anomaly_inout"]
			# Bugfix 2026-05-17（overlay 洋流热输运全白）：
			# water pass 走 C++ 路径时刻意省略了 HexCell.temperature_transport_anomaly
			# 的回写（注释说 "land pass 会直接复用该 buffer，并在下一片统一回写"），
			# 但原回写循环只覆盖 land cell（is_water_l[ci]==0），导致水域 cell
			# 的 anomaly 永远停留在 HexCell 默认值 0.0。DataOverlayBaker 读
			# cell.temperature_transport_anomaly 后归一化为 value=0.5，shader 用
			# ramp_diverging 渲染为中性灰（≈白），表现为"洋流热输运 overlay 全白"。
			# anomaly_io 在进入 land pass 时复用 water pass cache（含水域 anomaly）
			# 且 land pass C++ 只写 land cell；这里把水陆两部分一起 flush 回 HexCell，
			# 与 GDScript 完整路径保持一致（line 5089 / 5177）。
			map.temperature_transport_anomaly_arr = anomaly_io
			if _data_core_world != null:
				var _cid_tta_dense: int = _data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
				if _cid_tta_dense >= 0 and _data_core_world.has_method("write_f32_dense"):
					_data_core_world.write_f32_dense(_cid_tta_dense, anomaly_io)
			var _tta_facade_on: bool = n > 0 and cells[0] != null and (cells[0] as HexCell).is_facade_enabled()
			if not _tta_facade_on:
				for ci in range(n):
					cells[ci].temperature_transport_anomaly = anomaly_io[ci]
			# anomaly 继续保留给同轮 sea_ice，避免 sea_ice 再从 HexCell 打包 TTA。
			_gdext_ocean_anomaly_buf_cached = anomaly_io
			_gdext_ocean_baseline_arr_cached = PackedFloat32Array()
			_gdext_ocean_current_x_arr_cached = PackedFloat32Array()
			_gdext_ocean_current_y_arr_cached = PackedFloat32Array()
			_gdext_ocean_land_runs += 1
			_gdext_ocean_land_total_ms += rc_l
			if _gdext_ocean_land_runs == 1:
				print("[ocean_land/F.2b] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 3.4ms; charter §7 target < 0.5ms)" % rc_l)
			return
		_gdext_ocean_land_fallbacks += 1
		# rc<0：fall through 到 GDScript 完整路径
	var temp_a: PackedFloat32Array = _dc_views["temp"] if _use_dc else map.temp_arr
	var temp_baseline_a: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
	var elev_a: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
	var is_water_a: PackedByteArray = _dc_views["is_water"] if _use_dc else map.is_water_arr
	var pos_x_a: PackedFloat32Array = _dc_views["pos_x"] if _use_dc else map.cell_pos_x_arr
	var pos_y_a: PackedFloat32Array = _dc_views["pos_y"] if _use_dc else map.cell_pos_y_arr
	var ocx_a: PackedFloat32Array = _dc_views["ocean_current_x"] if _use_dc else map.ocean_current_x_arr
	var ocy_a: PackedFloat32Array = _dc_views["ocean_current_y"] if _use_dc else map.ocean_current_y_arr
	# Phase 3a Step 2.1.a：ema_initialized SoA 别名
	var ema_init_a: PackedByteArray = _dc_views["ema_initialized"] if _use_dc else map.ema_initialized_arr

	# A.2.1.B — Dirty 范围收窄 + 真变收集（M1 续，ocean_land 路径）：
	# 循环里本来就只对 |anomaly_in| > 1e-5 的 cell 写 temp_a[i]。
	# 这里同步记录这些 cell 的 idx + 新温度，循环结束后只 push 这些。
	var _ol_changed_idx: PackedInt32Array = PackedInt32Array()
	var _ol_changed_temp: PackedFloat32Array = PackedFloat32Array()

	for i in range(n):
		if is_water_a[i] != 0:
			continue
		var swx: float = pos_x_a[i]
		var swy: float = pos_y_a[i]
		var weighted_sum: float = 0.0
		var weight_total: float = 0.0
		var b: int = i * 6
		for d in range(6):
			var ni: int = nb_idx[b + d]
			if ni < 0:
				continue
			if is_water_a[ni] == 0:
				continue
			var cx: float = ocx_a[ni]
			var cy: float = ocy_a[ni]
			if cx * cx + cy * cy < 1e-6:
				continue
			var dx: float = swx - pos_x_a[ni]
			var dy: float = swy - pos_y_a[ni]
			var dlen2: float = dx * dx + dy * dy
			if dlen2 < 1e-6:
				continue
			var inv_len: float = 1.0 / sqrt(dlen2)
			var dot_v: float = (dx * cx + dy * cy) * inv_len
			if dot_v <= 0.0:
				continue
			weighted_sum += cells[ni].temperature_transport_anomaly * dot_v
			weight_total += dot_v
		var prev_anomaly: float = cells[i].temperature_transport_anomaly
		var anomaly_in: float = _decay_temperature_transport_anomaly(prev_anomaly, tta_decay_rate)
		if weight_total > 0.0:
			anomaly_in = _stabilize_temperature_transport_anomaly(
					prev_anomaly, (weighted_sum / weight_total) * effective_leak,
					tta_source_cap, tta_blend_rate)
		cells[i].temperature_transport_anomaly = anomaly_in
		if absf(anomaly_in) > 1e-5:
			var c: HexCell = cells[i]
			var fallback_baseline: float = temp_baseline_a[i]
			if ema_init_a[i] == 0:
				var ny: float = _cube_row_norm(c, _last_cfg)
				fallback_baseline = _compute_temperature(ny, elev_a[i])
			var t_prev: float = _valid_runtime_temp_or_baseline(temp_a[i], fallback_baseline)
			var tnew: float = t_prev + anomaly_in
			if tnew < 0.0: tnew = 0.0
			elif tnew > 1.0: tnew = 1.0
			temp_a[i] = tnew
			# A.2.1.B — 真变 cell 收集（push 子集）。仅当 ε 真变才入列；
			# 同时把"陆地端 anomaly 修正本身大于 ε"也吸收（避免极小修正污染 dirty）。
			var _ol_d: float = tnew - t_prev
			if _ol_d < 0.0: _ol_d = -_ol_d
			if _ol_d > _PUSH_EPS_TEMP:
				_ol_changed_idx.append(i)
				_ol_changed_temp.append(tnew)

	# PR-2.1.3b（ocean land SoA 路径）：循环结束后批量 push temp_a 到 DCWorld。
	#
	# A.2.1.B — Dirty 范围收窄 + ε 真变（M1 续）：循环里已经收集了所有
	# |t_new - t_prev| > ε 的陆地 cell 到 _ol_changed_idx / _ol_changed_temp。
	# 这里直接 push 子集，避免把没动的陆地 cell 标进 dirty mask。
	if _data_core_world != null and _ol_changed_idx.size() > 0:
		var _cid_temp_ols: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
		if _cid_temp_ols >= 0:
			_data_core_world.write_f32_indexed(_cid_temp_ols, _ol_changed_idx, _ol_changed_temp)
	var anomaly_land_state: PackedFloat32Array = PackedFloat32Array()
	anomaly_land_state.resize(n)
	for tta_i in range(n):
		anomaly_land_state[tta_i] = float(cells[tta_i].temperature_transport_anomaly) if cells[tta_i] != null else 0.0
	map.temperature_transport_anomaly_arr = anomaly_land_state
	if _data_core_world != null:
		var _cid_tta_ols: int = _data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if _cid_tta_ols >= 0 and _data_core_world.has_method("write_f32_dense"):
			_data_core_world.write_f32_dense(_cid_tta_ols, anomaly_land_state)


func _begin_ocean_heat_transport_sliced(map: MapData, season_phase: float, cp: ClimateProfile) -> bool:
	if map == null or cp == null or _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_ocean_water_pass") \
			or not _data_core_world_ext.has_method("run_ocean_land_pass"):
		return false
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6:
		return false
	var cells: Array[HexCell] = map.iter_cells()
	var _dc_views: Dictionary = _climate_views_from_world(cp)
	var _use_dc: bool = not _dc_views.is_empty()
	var temp_a: PackedFloat32Array = _dc_views["temp"] if _use_dc else map.temp_arr
	var temp_baseline_a: PackedFloat32Array = _dc_views["temp_baseline"] if _use_dc else map.temp_baseline_arr
	var elev_a: PackedFloat32Array = _dc_views["elevation"] if _use_dc else map.elevation_arr
	var lat_a: PackedFloat32Array = _dc_views["lat_norm"] if _use_dc else map.cell_lat_norm_arr
	var ema_init_a: PackedByteArray = _dc_views["ema_initialized"] if _use_dc else map.ema_initialized_arr
	var ocx_a: PackedFloat32Array = _dc_views["ocean_current_x"] if _use_dc else map.ocean_current_x_arr
	var ocy_a: PackedFloat32Array = _dc_views["ocean_current_y"] if _use_dc else map.ocean_current_y_arr
	if _gdext_ocean_baseline_work_buf.size() != n:
		_gdext_ocean_baseline_work_buf.resize(n)
	if _gdext_ocean_temp_before_work_buf.size() != n:
		_gdext_ocean_temp_before_work_buf.resize(n)
	if _gdext_ocean_anomaly_work_buf.size() != n:
		_gdext_ocean_anomaly_work_buf.resize(n)
	var baseline: PackedFloat32Array = _gdext_ocean_baseline_work_buf
	var temp_before: PackedFloat32Array = _gdext_ocean_temp_before_work_buf
	for i in range(n):
		if ema_init_a[i] != 0:
			baseline[i] = temp_baseline_a[i]
		else:
			var ny: float = lat_a[i] if lat_a.size() > i else _cube_row_norm(cells[i], _last_cfg)
			baseline[i] = _compute_temperature(ny, elev_a[i])
		var t0: float = temp_a[i]
		temp_before[i] = _valid_runtime_temp_or_baseline(t0, baseline[i])
	var anomaly: PackedFloat32Array = _gdext_ocean_anomaly_work_buf
	var prev_anomaly: PackedFloat32Array = _prepare_temperature_transport_anomaly_state(map, n, cells)
	for ai in range(n):
		anomaly[ai] = prev_anomaly[ai]
	var winter_boost: float = 1.0
	var effective_leak: float = float(_last_cfg.COASTAL_HEAT_LEAK) * winter_boost
	var tta: Dictionary = _temperature_transport_anomaly_knobs(cp)
	var water_knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, _last_cfg.OCEAN_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(_last_cfg.OCEAN_HEAT_MIX, 0.0, 1.0),
		"neighbor_indices": nb_idx,
		"baseline_arr": baseline,
		"temp_before_arr": temp_before,
		"anomaly_out": anomaly,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
	}
	var land_knobs: Dictionary = {
		"n_cells": n,
		"effective_leak": effective_leak,
		"neighbor_indices": nb_idx,
		"anomaly_inout": anomaly,
		"fallback_baseline_arr": baseline,
		"ocean_current_x_arr": ocx_a,
		"ocean_current_y_arr": ocy_a,
	}
	_apply_temperature_transport_anomaly_knobs(water_knobs, tta)
	_apply_temperature_transport_anomaly_knobs(land_knobs, tta)
	_climate_ocean_slice_state = {
		"map_id": map.get_instance_id(),
		"n": n,
		"cells": cells,
		"water_cursor": 0,
		"land_cursor": 0,
		"anomaly": anomaly,
		"baseline": baseline,
		"water_knobs": water_knobs,
		"land_knobs": land_knobs,
	}
	if _data_core_world_ext.has_method("refresh_slots_from_map"):
		_data_core_world_ext.refresh_slots_from_map()
	return true


func _ocean_slice_budget_cells() -> int:
	var cp := _c()
	var slice_ms: float = 0.75
	if cp != null and cp.get("sim_slice_budget_ms") != null:
		slice_ms = float(cp.sim_slice_budget_ms)
	return clampi(int(round(700.0 * clampf(slice_ms / 0.75, 0.5, 1.5))), 256, 900)


func _make_climate_pass_result(pass_type: String, done: bool, elapsed_ms: float, processed_cells: int,
		cursor_start: int, cursor_end: int, status: String = "", token: int = 0,
		stage: String = "", abort_reason: String = "") -> Dictionary:
	var out_status: String = status
	if out_status == "":
		out_status = _CLIMATE_PASS_STATUS_DONE if done else _CLIMATE_PASS_STATUS_RUNNING
	return {
		"pass_type": pass_type,
		"done": done,
		"status": out_status,
		"elapsed_ms": elapsed_ms,
		"processed_cells": processed_cells,
		"cursor_start": cursor_start,
		"cursor_end": cursor_end,
		"budget_interrupted": not done,
		"token": token,
		"stage": stage if stage != "" else pass_type,
		"abort_reason": abort_reason,
	}


func _climate_pass_state_matches(pass_type: String, map: MapData, token: int = 0) -> bool:
	if not _climate_pass_states.has(pass_type):
		return false
	var state: Dictionary = _climate_pass_states[pass_type]
	if map != null and int(state.get("map_id", -1)) != map.get_instance_id():
		return false
	if token > 0 and int(state.get("token", 0)) != token:
		return false
	return str(state.get("status", "")) == _CLIMATE_PASS_STATUS_RUNNING


func begin_climate_pass(pass_type: String, map: MapData, season_phase: float, opts: Dictionary = {}) -> Dictionary:
	var cp := _c()
	if map == null or cp == null:
		return _make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_FAILED, 0, pass_type, "missing_context")
	if _climate_pass_state_matches(pass_type, map):
		return _climate_pass_states[pass_type].duplicate(true)
	_climate_pass_generation += 1
	var token: int = _climate_pass_generation
	var stage: String = str(opts.get("stage", pass_type))
	var state: Dictionary = {
		"pass_type": pass_type,
		"token": token,
		"status": _CLIMATE_PASS_STATUS_RUNNING,
		"map_id": map.get_instance_id(),
		"season_phase": season_phase,
		"stage": stage,
		"cursor": 0,
		"cursor_start": 0,
		"cursor_end": 0,
		"processed_cells": 0,
		"budget_cells": int(opts.get("budget_cells", _ocean_slice_budget_cells())),
		"started_msec": Time.get_ticks_msec(),
	}
	match pass_type:
		_CLIMATE_PASS_OCEAN_WATER, _CLIMATE_PASS_OCEAN_LAND:
			if _climate_ocean_slice_state.is_empty() \
					or int(_climate_ocean_slice_state.get("map_id", -1)) != map.get_instance_id():
				if not _begin_ocean_heat_transport_sliced(map, season_phase, cp):
					return _make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_FAILED, token, stage, "begin_failed")
			state["n"] = int(_climate_ocean_slice_state.get("n", 0))
			state["water_cursor"] = int(_climate_ocean_slice_state.get("water_cursor", 0))
			state["land_cursor"] = int(_climate_ocean_slice_state.get("land_cursor", 0))
		_CLIMATE_PASS_SEA_ICE:
			state["n"] = map.cell_count()
		_:
			return _make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_FAILED, token, stage, "unknown_pass")
	_climate_pass_states[pass_type] = state
	return state.duplicate(true)


func abort_climate_pass(pass_type: String, reason: String = "abort") -> Dictionary:
	if not _climate_pass_states.has(pass_type):
		return _make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_ABORTED, 0, pass_type, reason)
	var state: Dictionary = _climate_pass_states[pass_type]
	state["status"] = _CLIMATE_PASS_STATUS_ABORTED
	state["abort_reason"] = reason
	state["ended_msec"] = Time.get_ticks_msec()
	_climate_pass_states.erase(pass_type)
	if pass_type == _CLIMATE_PASS_OCEAN_WATER or pass_type == _CLIMATE_PASS_OCEAN_LAND:
		_climate_ocean_slice_state.clear()
		_gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
		_gdext_ocean_baseline_arr_cached = PackedFloat32Array()
		_gdext_ocean_current_x_arr_cached = PackedFloat32Array()
		_gdext_ocean_current_y_arr_cached = PackedFloat32Array()
		_ocean_water_done_phase = NAN
	elif pass_type == _CLIMATE_PASS_SEA_ICE:
		_abort_sea_ice_state_machine(reason)
	return _make_climate_pass_result(pass_type, true, 0.0, int(state.get("processed_cells", 0)),
			int(state.get("cursor_start", -1)), int(state.get("cursor_end", -1)),
			_CLIMATE_PASS_STATUS_ABORTED, int(state.get("token", 0)), str(state.get("stage", pass_type)), reason)


func _abort_all_climate_passes(reason: String = "abort_all") -> void:
	var pass_types: Array = _climate_pass_states.keys()
	for pass_type in pass_types:
		abort_climate_pass(str(pass_type), reason)
	_climate_pass_states.clear()
	_climate_ocean_slice_state.clear()
	_gdext_ocean_anomaly_buf_cached = PackedFloat32Array()
	_gdext_ocean_baseline_arr_cached = PackedFloat32Array()
	_gdext_ocean_current_x_arr_cached = PackedFloat32Array()
	_gdext_ocean_current_y_arr_cached = PackedFloat32Array()
	_ocean_water_done_phase = NAN
	_abort_sea_ice_state_machine(reason)


func _run_climate_pass_legacy_fallback(pass_type: String, map: MapData, season_phase: float, token: int, reason: String) -> Dictionary:
	var t_fb: int = Time.get_ticks_usec()
	match pass_type:
		_CLIMATE_PASS_OCEAN_WATER:
			_ocean_water_pass(map, season_phase)
			return _make_climate_pass_result(pass_type, true, (Time.get_ticks_usec() - t_fb) / 1000.0, map.cell_count(), 0, map.cell_count(), _CLIMATE_PASS_STATUS_DONE, token, "ocean_water_fallback", reason)
		_CLIMATE_PASS_OCEAN_LAND:
			_ocean_land_pass(map, season_phase)
			return _make_climate_pass_result(pass_type, true, (Time.get_ticks_usec() - t_fb) / 1000.0, map.cell_count(), 0, map.cell_count(), _CLIMATE_PASS_STATUS_DONE, token, "ocean_land_fallback", reason)
		_CLIMATE_PASS_SEA_ICE:
			_apply_sea_ice_daily_pass(map, season_phase)
			return _make_climate_pass_result(pass_type, true, (Time.get_ticks_usec() - t_fb) / 1000.0, map.cell_count(), 0, map.cell_count(), _CLIMATE_PASS_STATUS_DONE, token, "sea_ice_fallback", reason)
	return _make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_FAILED, token, pass_type, reason)


func run_climate_pass_slice(pass_type: String, map: MapData, season_phase: float, opts: Dictionary = {}) -> Dictionary:
	var state: Dictionary = begin_climate_pass(pass_type, map, season_phase, opts)
	var token: int = int(state.get("token", 0))
	if str(state.get("status", "")) == _CLIMATE_PASS_STATUS_FAILED:
		return _run_climate_pass_legacy_fallback(pass_type, map, season_phase, token, str(state.get("abort_reason", "begin_failed")))
	if not _climate_pass_state_matches(pass_type, map, token):
		return _make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_ABORTED, token, pass_type, "stale_token")
	match pass_type:
		_CLIMATE_PASS_OCEAN_WATER:
			return _run_ocean_water_pass_slice_impl(map, season_phase, token)
		_CLIMATE_PASS_OCEAN_LAND:
			return _run_ocean_land_pass_slice_impl(map, season_phase, token)
		_CLIMATE_PASS_SEA_ICE:
			return _run_sea_ice_state_machine_slice(map, season_phase, token)
	return _make_climate_pass_result(pass_type, true, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_FAILED, token, pass_type, "unknown_pass")


func run_ocean_water_pass_slice(map: MapData, season_phase: float) -> Dictionary:
	return run_climate_pass_slice(_CLIMATE_PASS_OCEAN_WATER, map, season_phase)


func _run_ocean_water_pass_slice_impl(map: MapData, season_phase: float, token: int = 0) -> Dictionary:
	var cp := _c()
	if _climate_ocean_slice_state.is_empty() \
			or int(_climate_ocean_slice_state.get("map_id", -1)) != map.get_instance_id():
		if not _begin_ocean_heat_transport_sliced(map, season_phase, cp):
			var t_fb: int = Time.get_ticks_usec()
			_ocean_water_pass(map, season_phase)
			return _make_climate_pass_result(_CLIMATE_PASS_OCEAN_WATER, true, (Time.get_ticks_usec() - t_fb) / 1000.0, map.cell_count(), 0, map.cell_count(), _CLIMATE_PASS_STATUS_DONE, token, "ocean_water_fallback")
	var n: int = int(_climate_ocean_slice_state.get("n", 0))
	var start: int = int(_climate_ocean_slice_state.get("water_cursor", 0))
	var end: int = mini(n, start + _ocean_slice_budget_cells())
	var knobs: Dictionary = _climate_ocean_slice_state["water_knobs"]
	knobs["start_idx"] = start
	knobs["end_idx"] = end
	var rc: float = float(_data_core_world_ext.run_ocean_water_pass(knobs))
	if rc < 0.0:
		_climate_ocean_slice_state.clear()
		_climate_pass_states.erase(_CLIMATE_PASS_OCEAN_WATER)
		var t_fb2: int = Time.get_ticks_usec()
		_ocean_water_pass(map, season_phase)
		return _make_climate_pass_result(_CLIMATE_PASS_OCEAN_WATER, true, (Time.get_ticks_usec() - t_fb2) / 1000.0, map.cell_count(), 0, map.cell_count(), _CLIMATE_PASS_STATUS_DONE, token, "ocean_water_fallback")
	var anomaly: PackedFloat32Array = knobs["anomaly_out"]
	_climate_ocean_slice_state["anomaly"] = anomaly
	_climate_ocean_slice_state["water_cursor"] = end
	var land_knobs: Dictionary = _climate_ocean_slice_state["land_knobs"]
	land_knobs["anomaly_inout"] = anomaly
	_gdext_ocean_anomaly_buf_cached = anomaly
	_gdext_ocean_baseline_arr_cached = _climate_ocean_slice_state["baseline"]
	# Incremental publish (climate-pipeline-spike-reduction)：每片都把当前 anomaly
	# 推到 map / DCWorld dense buffer，避免 budget=2ms 节奏下 round 跨多帧时读方
	# (weather field_solver / map_generator feedback 路径) 长时间读到陈旧的洋流热
	# 输运。区间外格子保留上一片旧值（C++ run_ocean_water_pass §11 CoW duplicate
	# 保证），即「水格新值 + 陆格旧值」的混合态——比「完全冻结到几日前」好得多。
	map.temperature_transport_anomaly_arr = anomaly
	if _data_core_world != null:
		var _cid_tta_inc_w: int = _data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if _cid_tta_inc_w >= 0 and _data_core_world.has_method("write_f32_dense"):
			_data_core_world.write_f32_dense(_cid_tta_inc_w, anomaly)
	# A2 增量回写 HexCell.temperature_transport_anomaly：该字段尚未 facade 化
	# (HexCell 内是裸 var)，baker / info_panel / weather fallback 都通过
	# cell.temperature_transport_anomaly 这条 AoS 路径读，必须显式赋值。仅写当
	# 前 slice 区间，开销 ~slice_budget 个 cell 一次循环（≤0.05ms 量级），区间外
	# 保留上一片旧值，配合 land 阶段最终 done 全图回写，渲染层可逐片看到合并视图。
	var _cells_inc_w: Array = _climate_ocean_slice_state.get("cells", [])
	if _cells_inc_w.size() == n:
		for _ci_w in range(start, end):
			var _c_w = _cells_inc_w[_ci_w]
			if _c_w != null:
				_c_w.temperature_transport_anomaly = anomaly[_ci_w]
	var done: bool = end >= n
	if _climate_pass_states.has(_CLIMATE_PASS_OCEAN_WATER):
		var state: Dictionary = _climate_pass_states[_CLIMATE_PASS_OCEAN_WATER]
		state["water_cursor"] = end
		state["cursor_start"] = start
		state["cursor_end"] = end
		state["processed_cells"] = end - start
		state["status"] = _CLIMATE_PASS_STATUS_DONE if done else _CLIMATE_PASS_STATUS_RUNNING
		_climate_pass_states[_CLIMATE_PASS_OCEAN_WATER] = state
	if done:
		_climate_pass_states.erase(_CLIMATE_PASS_OCEAN_WATER)
	return _make_climate_pass_result(_CLIMATE_PASS_OCEAN_WATER, done, rc, end - start, start, end, _CLIMATE_PASS_STATUS_DONE if done else _CLIMATE_PASS_STATUS_RUNNING, token, "ocean_water")


func run_ocean_land_pass_slice(map: MapData, season_phase: float) -> Dictionary:
	return run_climate_pass_slice(_CLIMATE_PASS_OCEAN_LAND, map, season_phase)


func _run_ocean_land_pass_slice_impl(map: MapData, season_phase: float, token: int = 0) -> Dictionary:
	var cp := _c()
	if _climate_ocean_slice_state.is_empty() \
			or int(_climate_ocean_slice_state.get("map_id", -1)) != map.get_instance_id():
		if not _begin_ocean_heat_transport_sliced(map, season_phase, cp):
			var t_fb: int = Time.get_ticks_usec()
			_ocean_land_pass(map, season_phase)
			return _make_climate_pass_result(_CLIMATE_PASS_OCEAN_LAND, true, (Time.get_ticks_usec() - t_fb) / 1000.0, map.cell_count(), 0, map.cell_count(), _CLIMATE_PASS_STATUS_DONE, token, "ocean_land_fallback")
	var n: int = int(_climate_ocean_slice_state.get("n", 0))
	var start: int = int(_climate_ocean_slice_state.get("land_cursor", 0))
	var end: int = mini(n, start + _ocean_slice_budget_cells())
	var knobs: Dictionary = _climate_ocean_slice_state["land_knobs"]
	knobs["start_idx"] = start
	knobs["end_idx"] = end
	var rc: float = float(_data_core_world_ext.run_ocean_land_pass(knobs))
	if rc < 0.0:
		_climate_ocean_slice_state.clear()
		_climate_pass_states.erase(_CLIMATE_PASS_OCEAN_LAND)
		var t_fb2: int = Time.get_ticks_usec()
		_ocean_land_pass(map, season_phase)
		return _make_climate_pass_result(_CLIMATE_PASS_OCEAN_LAND, true, (Time.get_ticks_usec() - t_fb2) / 1000.0, map.cell_count(), 0, map.cell_count(), _CLIMATE_PASS_STATUS_DONE, token, "ocean_land_fallback")
	var anomaly: PackedFloat32Array = knobs["anomaly_inout"]
	_climate_ocean_slice_state["anomaly"] = anomaly
	_climate_ocean_slice_state["land_cursor"] = end
	var done: bool = end >= n
	if _climate_pass_states.has(_CLIMATE_PASS_OCEAN_LAND):
		var state: Dictionary = _climate_pass_states[_CLIMATE_PASS_OCEAN_LAND]
		state["land_cursor"] = end
		state["cursor_start"] = start
		state["cursor_end"] = end
		state["processed_cells"] = end - start
		state["status"] = _CLIMATE_PASS_STATUS_DONE if done else _CLIMATE_PASS_STATUS_RUNNING
		_climate_pass_states[_CLIMATE_PASS_OCEAN_LAND] = state
	# Incremental publish (climate-pipeline-spike-reduction)：每片都把当前 anomaly
	# 推到 map / DCWorld dense buffer。read 方 (weather/field_solver/feedback) 始
	# 终能拿到「已计算部分新值 + 未计算部分上一片旧值」的合并视图，避免在 ocean_land
	# 整轮跨多帧时洋流热输运彻底冻结。逐 cell HexCell 回写代价较大，仅在 done 时
	# 执行（且只对 facade-off 路径，新代码默认 facade-on）。
	map.temperature_transport_anomaly_arr = anomaly
	if _data_core_world != null:
		var _cid_tta_dense: int = _data_core_world.component_id(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY)
		if _cid_tta_dense >= 0 and _data_core_world.has_method("write_f32_dense"):
			_data_core_world.write_f32_dense(_cid_tta_dense, anomaly)
	_gdext_ocean_anomaly_buf_cached = anomaly
	# A2 增量回写 HexCell.temperature_transport_anomaly：land 阶段对 [start, end)
	# 内的陆格 anomaly 做了更新（水格保留 water 阶段值），区间外保留上一片旧值。
	# 与 water 阶段对称，让 baker / info_panel 在 budget=2ms 节奏下也能逐片看到
	# 渐进合并视图，避免「洋流热输运一直白」的现象。done 分支额外做的全图回写
	# 保留作为兜底（应对极端 reset 后某片尚未触达的格子）。
	var _cells_inc_l: Array = _climate_ocean_slice_state.get("cells", [])
	if _cells_inc_l.size() == n:
		for _ci_l in range(start, end):
			var _c_l = _cells_inc_l[_ci_l]
			if _c_l != null:
				_c_l.temperature_transport_anomaly = anomaly[_ci_l]
	if done:
		var cells: Array = _climate_ocean_slice_state.get("cells", [])
		# 兜底全图回写：确保任何因为 reset / cells 数组变更等原因未被增量段覆盖到的
		# 格子在 round 末尾拿到最新 anomaly。即使 facade 化后 (cell.temperature_
		# transport_anomaly 走 SoA) 这次冗余写也无害——facade getter/setter 不存在
		# 时这段就是唯一的最终回写。
		if n > 0 and cells.size() == n:
			for ci in range(n):
				var _cf = cells[ci]
				if _cf != null:
					_cf.temperature_transport_anomaly = anomaly[ci]
		_gdext_ocean_baseline_arr_cached = PackedFloat32Array()
		_gdext_ocean_current_x_arr_cached = PackedFloat32Array()
		_gdext_ocean_current_y_arr_cached = PackedFloat32Array()
		_climate_ocean_slice_state.clear()
		_climate_pass_states.erase(_CLIMATE_PASS_OCEAN_LAND)
	return _make_climate_pass_result(_CLIMATE_PASS_OCEAN_LAND, done, rc, end - start, start, end, _CLIMATE_PASS_STATUS_DONE if done else _CLIMATE_PASS_STATUS_RUNNING, token, "ocean_land")

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


func publish_weather_lut_after_weather_commit(map: MapData, world: WorldData, native_lut: PackedByteArray = PackedByteArray(), force_changed: bool = false) -> Dictionary:
	if _baker == null or map == null or world == null:
		return {"path": "weather_lut_inline", "fallback": true, "reason": "missing_inputs"}
	var report: Dictionary
	if not native_lut.is_empty() and _baker.has_method("publish_weather_lut_bytes_from_native"):
		report = _baker.publish_weather_lut_bytes_from_native(native_lut, world, force_changed)
	else:
		report = _baker.refresh_weather_lut_from_weather(map, world)
	report["path"] = "weather_lut_inline"
	return report


# plan/weather-refresh-cpp-all PR-2：weather refresh daily 合并 facade。
#
# 单次 cpp call 把 field_solve + distribute + summary_fronts + cyclone_wake + stage_b
# 5 段 pass 跑完，跳过 GDScript ↔ C++ 3 次 marshal + 多次 Dictionary 装包。当 cp.use_gdext_weather_refresh_daily=true
# 且 ext 已 bound + has_method 时由 SUS WeatherRefreshJob 优先选用本入口；任何前置不
# 满足或 cpp rc!=0 时**透明回退**到 refresh_daily_stage_a + refresh_daily_stage_b 老链，
# 对 caller 完全无感。
#
# 与 stage_a/stage_b 的语义对应：
#   - stage_a (tick_one_day) ⇒ cpp 段 1-4：field_solve / distribute / summary / cyclone_wake
#   - stage_b ⇒ cpp 段 5：albedo / veg_dyn / feedback
#
# 通报字段 1:1 沿用 stage_b 末尾的 _last_weather_breakdown 协议（path 字段标 "gdext_combined"
# 让 perf overlay 能区分慢速 GDScript 链与 fast cpp 链）；同时 stage_b 的 enum_atlas
# dirty mark 必须由本 facade 主动调用，因为合并 path 完全跳过了 stage_b GDScript 入口。
func refresh_weather_daily(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	# Step 1：前置 gate。任何一项失败立即 fallback 到老链，让 caller 透明感知。
	if _weather_system == null or map == null or world == null:
		return refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
	var cp_now := _c()
	# dots-flag-prune-pr1 round 2: use_gdext_weather_refresh_daily flag 已删除——
	# 恒走 ext + has_method(run_weather_refresh_daily_pass) + weather_system has_method
	# 探测分支（任一缺失透明 fallback 到老链 stage_a + stage_b）。
	if _data_core_world_ext == null \
			or not _data_core_world_ext.has_method("run_weather_refresh_daily_pass"):
		var fb: Array[WeatherFront] = refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
		refresh_daily_stage_b(map, world)
		return fb
	if not _weather_system.has_method("try_run_refresh_daily_combined_gdext"):
		var fc: Array[WeatherFront] = refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
		refresh_daily_stage_b(map, world)
		return fc

	# Step 2：sliced stage 不应混用合并模式（_round_active 状态由 sliced 路径维护，
	# 由 weather_refresh_job 的 _should_use_merged_native_weather 互斥保证）。这里再
	# 做 defensive：合并 path 必须自己刷新 _round_t0 计时基准，与 stage_b 的 total_ms 算法对齐。
	_last_world = world
	_weather_round_t0_us = Time.get_ticks_usec()

	# Step 3：把 stage_b call_index 推进，保持 stride 计数与 stage_b 老链 1:1 对齐。
	# （即便后续 ok=false 走 fallback 老链，老 stage_b 也会再 ++ 一次 — 这是 stride 二次
	# 推进的旧问题，但它本就只在合并失败的"半冷启动"几 tick 出现，不影响周期 stride 节奏。
	# 为最大兼容，这里仍按 stage_b 同步 ++，若 fallback 触发则在 fallback 分支里手动回滚。）
	var prev_call_index: int = _weather_stage_b_call_index
	_weather_stage_b_call_index += 1
	var stage_b_knobs: Dictionary = _build_native_daily_stage_b_knobs(
		map,
		cp_now,
		maxi(1, _weather_stage_b_call_index)
	)

	# Step 4：单次 cpp call。weather_system.try_run_refresh_daily_combined_gdext
	# 内部 begin_field_solve → super_knobs merge → run_weather_refresh_daily_pass →
	# unpack fronts + cyclone mirror，stage_b knobs 由本 facade 注入。
	var res: Dictionary = _weather_system.try_run_refresh_daily_combined_gdext(
		map, world, season_idx, climate_anomaly, season_phase, stage_b_knobs
	)
	var ok: bool = bool(res.get("ok", false))
	if not ok:
		# Fallback 路径：先回滚 stage_b call_index（让老 stage_b 自己重新 ++），
		# 然后透明走 stage_a + stage_b 老链。fail_stage 会在 weather_system
		# 内部首次失败时打 push_warning（节流单次），无需在此重复。
		_weather_stage_b_call_index = prev_call_index
		var fronts_fb: Array[WeatherFront] = refresh_daily_stage_a(
			map, world, season_idx, climate_anomaly, season_phase
		)
		refresh_daily_stage_b(map, world)
		return fronts_fb

	# Step 5：成功路径。同步生成器侧通报状态。
	var fronts_out: Array[WeatherFront] = res.get("fronts", [] as Array[WeatherFront])
	_last_active_fronts = fronts_out
	_weather_round_fronts = fronts_out
	# breakdown：weather_system 已经按 path="gdext_combined" + 各段 ms 装好；外部 perf
	# overlay / SUS publish 直接读 _last_weather_breakdown 即可。
	var br: Dictionary = res.get("breakdown", {})
	_last_weather_breakdown = br.duplicate(true)
	# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
	_last_weather_breakdown["_tick_idx"] = _current_fast_tick_idx
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	_dump_weather_breakdown_if_slow()
	# weather_round_tick_ms 用于 sliced 路径与本路径共享 perf 字段：取 advance+distribute+summary 段
	# 之和（与 stage_a 老链的 weather_tick_ms 对应概念，cyclone/stage_b 之外的"主 tick"耗时）。
	_weather_round_tick_ms = float(br.get("advance_ms", 0.0)) \
			+ float(br.get("distribute_ms", 0.0)) \
			+ float(br.get("summary_ms", 0.0))

	# Step 6：合并 path 完全绕过了 stage_b GDScript 入口，所以 enum_atlas dirty mark 必须由
	# 本 facade 主动触发——否则 baker 收不到 cover/vegetation 改动信号导致视觉残影。
	#   - cover_dirty: weather distribute 段（BLIZZARD→SNOW 等）由 cpp 在 run_distribute 内
	#     直接写 cell.cover；mark cover dirty 让 baker 重烘。
	#   - vegetation_dirty: cpp veg_dyn 段返回 succession_indices / succession_to_veg；非空
	#     即视为 vegetation 有改动。
	if _baker != null:
		if _weather_system.has_method("has_cover_dirty") and bool(_weather_system.has_cover_dirty()):
			_mark_enum_atlas_dirty(true, false)
		var succ_indices = br.get("succession_indices", null)
		var veg_dirty: bool = succ_indices != null and (typeof(succ_indices) == TYPE_PACKED_INT32_ARRAY) \
				and (succ_indices as PackedInt32Array).size() > 0
		if not veg_dirty:
			veg_dirty = int(br.get("stat_succession_count", 0)) > 0
		if veg_dirty:
			_mark_enum_atlas_dirty(false, true)

	return fronts_out


func weather_native_daily_available() -> bool:
	# The combined native daily pass is not the visible weather authority yet:
	# recent CSV diagnostics showed it can advance cadence while leaving
	# MapData.weather_field_init_arr and all weather field arrays at zero. Keep
	# SUS on the staged begin/solve/commit path until this facade verifies a
	# real field publication contract.
	return false


# Stage A：tick_one_day（advection / spawn / distribute / cyclone）。
# WeatherRefreshJob 可把 field solver 拆成多 tick；最后一片才返回当日 fronts。
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


func weather_uses_field_solver() -> bool:
	return _weather_system != null \
		and _weather_system.has_method("uses_weather_field") \
		and bool(_weather_system.uses_weather_field())


func weather_field_slice_cells() -> int:
	var cp_now := _c()
	if cp_now == null:
		return 2400
	var n_cells: int = _sus_map.cell_count() if _sus_map != null else 0
	if n_cells > 0 and n_cells <= 6400 \
			and _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_weather_field_solve_pass") \
			and _weather_system != null \
			and _weather_system.has_method("uses_weather_field") \
			and bool(_weather_system.uses_weather_field()):
		return n_cells
	return clampi(int(cp_now.weather_field_slice_cells), 100, 6400)


func begin_weather_refresh_stage_a(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> void:
	if _weather_system == null or map == null or world == null:
		return
	_last_world = world
	_weather_round_t0_us = Time.get_ticks_usec()
	if _weather_system.has_method("begin_weather_field_solve"):
		_weather_system.begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase)


func run_weather_refresh_stage_a_slice(cell_budget: int) -> Dictionary:
	if _weather_system == null or not _weather_system.has_method("run_weather_field_solve_slice"):
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }
	var result: Dictionary = _weather_system.run_weather_field_solve_slice(maxi(1, cell_budget))
	var elapsed_ms: float = float(result.get("elapsed_ms", 0.0))
	var processed_cells: int = int(result.get("processed_cells", result.get("work_done", 0)))
	var cursor_start: int = int(result.get("cursor_start", -1))
	var cursor_end: int = int(result.get("cursor_end", -1))
	var sub: Dictionary = _weather_system.last_breakdown() if _weather_system.has_method("last_breakdown") else {}
	_last_weather_breakdown = {
		"weather_tick_ms": elapsed_ms,
		"advance_ms": elapsed_ms,
		"spawn_ms": 0.0,
		"distribute_ms": 0.0,
		"cyclone_ms": 0.0,
		"weather_field_bake_ms": 0.0,
		"transp_ms": 0.0,
		"albedo_ms": 0.0,
		"veg_dyn_ms": 0.0,
		"cover_rebake_ms": 0.0,
		"veg_rebake_ms": 0.0,
		"feedback_ms": 0.0,
		"total_ms": (Time.get_ticks_usec() - _weather_round_t0_us) / 1000.0,
		"fronts": _weather_round_fronts.size(),
		"processed_cells": processed_cells,
		"cursor_start": cursor_start,
		"cursor_end": cursor_end,
		"weather_dirty_count": int(result.get("weather_dirty_count", 0)),
		"water_budget_error": float(result.get("water_budget_error", 0.0)),
		"active_weather_ratio": float(result.get("active_weather_ratio", 0.0)),
		"field_solve_tick": int(sub.get("field_solve_tick", -1)),
		"weather_commit_tick_delta": int(sub.get("weather_commit_tick_delta", 0)),
		"weather_last_commit_tick": int(sub.get("weather_last_commit_tick", -1)),
		"weather_cold_front_count": int(sub.get("weather_cold_front_count", 0)),
		"weather_warm_front_count": int(sub.get("weather_warm_front_count", 0)),
		"field_convergence_refresh_stride": int(sub.get("field_convergence_refresh_stride", 0)),
		"refresh_convergence": bool(sub.get("refresh_convergence", false)),
		"native_convergence_boost": bool(sub.get("native_convergence_boost", false)),
		"weather_convergence_dirty_count": int(sub.get("weather_convergence_dirty_count", 0)),
		"weather_convergence_delta_p95": float(sub.get("weather_convergence_delta_p95", 0.0)),
		"convergence_published": bool(sub.get("convergence_published", false)),
		"partial": not bool(result.get("done", true)),
		"progress_ratio": float(result.get("progress_ratio", 0.0)),
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		"_tick_idx": _current_fast_tick_idx,
	}
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	_dump_weather_breakdown_if_slow()
	return result


func commit_weather_refresh_stage_a(map: MapData, world: WorldData) -> Array[WeatherFront]:
	if _weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	if _weather_system.has_method("commit_weather_field_solve"):
		fronts = _weather_system.commit_weather_field_solve()
	var sub: Dictionary = _weather_system.last_breakdown() if _weather_system.has_method("last_breakdown") else {}
	_weather_round_tick_ms = float(sub.get("weather_tick_ms", sub.get("field_solve_ms", 0.0)))
	if not sub.is_empty():
		var merged: Dictionary = _last_weather_breakdown.duplicate(true)
		merged.merge(sub, true)
		merged["weather_tick_ms"] = _weather_round_tick_ms
		merged["weather_field_bake_ms"] = float(merged.get("weather_field_bake_ms", 0.0))
		merged["transp_ms"] = float(merged.get("transp_ms", 0.0))
		merged["albedo_ms"] = float(merged.get("albedo_ms", 0.0))
		merged["veg_dyn_ms"] = float(merged.get("veg_dyn_ms", 0.0))
		merged["cover_rebake_ms"] = float(merged.get("cover_rebake_ms", 0.0))
		merged["veg_rebake_ms"] = float(merged.get("veg_rebake_ms", 0.0))
		merged["feedback_ms"] = float(merged.get("feedback_ms", 0.0))
		merged["total_ms"] = (Time.get_ticks_usec() - _weather_round_t0_us) / 1000.0
		merged["fronts"] = fronts.size()
		merged["_tick_idx"] = _current_fast_tick_idx
		_last_weather_breakdown = merged
	_last_active_fronts = fronts
	_weather_round_fronts = fronts
	return fronts


func runtime_hydrology_enabled() -> bool:
	var cp_now := _c()
	return cp_now != null and bool(cp_now.runtime_hydrology_enabled)


# Stage13「让天气移动」：每个 weather 轮(commit 后)推进一次独立全场 ψ pass。转发到 weather_system。
# 返回 elapsed_ms (≥0) 或 -1.0(未就绪/关闭/失败,ψ 保持上轮值)。
func run_synoptic_advance_pass_native(map: MapData, world: WorldData) -> float:
	if _weather_system == null or not _weather_system.has_method("run_synoptic_advance_pass"):
		return -1.0
	return _weather_system.run_synoptic_advance_pass(map, world)


func run_hydrology_discharge_pass_native(map: MapData, world: WorldData) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var cp_now := _c()
	if cp_now == null or not bool(cp_now.runtime_hydrology_enabled):
		return {
			"done": true,
			"elapsed_ms": 0.0,
			"work_done": 0,
			"progress_ratio": 1.0,
			"stage_name": "hydrology_discharge",
			"substage": "disabled",
			"path": "disabled",
			"published_to_slot": false,
			"fallback_reason": "runtime_hydrology_disabled",
		}
	if map == null or world == null:
		return {
			"done": true,
			"elapsed_ms": 0.0,
			"work_done": 0,
			"progress_ratio": 1.0,
			"stage_name": "hydrology_discharge",
			"substage": "missing_context",
			"path": "fallback",
			"published_to_slot": false,
			"fallback_reason": "missing_map_or_world",
		}
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("run_runtime_hydrology_pass"):
		return {
			"done": true,
			"elapsed_ms": 0.0,
			"work_done": 0,
			"progress_ratio": 1.0,
			"stage_name": "hydrology_discharge",
			"substage": "missing_native",
			"path": "fallback",
			"published_to_slot": false,
			"fallback_reason": "missing_run_runtime_hydrology_pass",
		}
	var t_refresh_us: int = Time.get_ticks_usec()
	if _data_core_world_ext.has_method("refresh_slots_from_map"):
		_data_core_world_ext.refresh_slots_from_map()
	var refresh_ms: float = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
	var knobs: Dictionary = {
		"n_cells": map.cell_count(),
		"hydro_precip_scale": float(cp_now.hydro_precip_scale),
		"hydro_snowmelt_scale": float(cp_now.hydro_snowmelt_scale),
		"hydro_soil_capacity": float(cp_now.hydro_soil_capacity),
		"hydro_infiltration_rate": float(cp_now.hydro_infiltration_rate),
		"hydro_quickflow_fraction": float(cp_now.hydro_quickflow_fraction),
		"hydro_baseflow_recession": float(cp_now.hydro_baseflow_recession),
		"hydro_channel_release_rate": float(cp_now.hydro_channel_release_rate),
		"hydro_lake_release_rate": float(cp_now.hydro_lake_release_rate),
		"hydro_discharge_ema": float(cp_now.hydro_discharge_ema),
		"hydro_bank_moisture_gain": float(cp_now.hydro_bank_moisture_gain),
		"hydro_river_evap_gain": float(cp_now.hydro_river_evap_gain),
		"hydro_flood_threshold": float(cp_now.hydro_flood_threshold),
		"hydro_flood_decay": float(cp_now.hydro_flood_decay),
		"snowpack_melt_temp_gain": float(cp_now.snowpack_melt_temp_gain),
		"snowpack_melt_sun_gain": float(cp_now.snowpack_melt_sun_gain),
	}
	var res: Dictionary = _data_core_world_ext.run_runtime_hydrology_pass(knobs)
	var elapsed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	res["done"] = true
	res["elapsed_ms"] = elapsed_ms
	res["work_done"] = int(res.get("processed_cells", res.get("n_cells", 0)))
	res["progress_ratio"] = 1.0
	res["stage_name"] = "hydrology_discharge"
	res["substage"] = "route_full"
	res["refresh_ms"] = refresh_ms
	res["path"] = str(res.get("path", "gdext"))
	_last_weather_breakdown["hydrology_discharge_ms"] = elapsed_ms
	_last_weather_breakdown["hydrology_native_ms"] = float(res.get("native_ms", 0.0))
	_last_weather_breakdown["hydrology_compute_ms"] = float(res.get("compute_ms", 0.0))
	_last_weather_breakdown["hydrology_flush_ms"] = float(res.get("flush_ms", 0.0))
	_last_weather_breakdown["hydrology_refresh_ms"] = refresh_ms
	_last_weather_breakdown["hydrology_water_budget_error"] = float(res.get("water_budget_error", 0.0))
	_last_weather_breakdown["hydrology_river_discharge_p95"] = float(res.get("river_discharge_p95", 0.0))
	_last_weather_breakdown["hydrology_river_discharge_max"] = float(res.get("river_discharge_max", 0.0))
	_last_weather_breakdown["hydrology_flood_count"] = int(res.get("flood_count", res.get("flood_candidate_count", 0)))
	return res


# Stage B：tick_one_day 之后的全部"派生 / 反馈"工作。
# field_bake（F 之后 ~5ms 增量） + transpiration（多数情况下被 enable_local_climate_coupling 跳过）
# + albedo + vegetation_dynamics + cover/veg dirty marks + weather→map feedback。
# 由 SUS WeatherRefreshJob 在 round 终点的 tick 跑（典型下一 tick）。
func refresh_daily_stage_b(map: MapData, world: WorldData) -> void:
	if _weather_system == null or map == null or world == null:
		return
	var cp_now := _c()
	_weather_stage_b_call_index += 1
	var albedo_stride: int = maxi(1, int(cp_now.weather_albedo_stride)) if cp_now != null else 10
	var veg_dyn_stride: int = maxi(1, int(cp_now.weather_vegetation_dynamics_stride)) if cp_now != null else 10
	var feedback_stride: int = maxi(1, int(cp_now.weather_feedback_stride)) if cp_now != null else 10
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

	# ─── 方案 B：stage_b 三段合并快路径（plan/stage-b-combine）────────────────
	# 满足 cp.use_gdext_stage_b_combined && ext bound && ext.has_method &&
	# 至少一个 run_* 为 true 时，走单 cpp call run_stage_b_pass，把 albedo +
	# veg_dyn + feedback 三段一次性 pack/unpack；成功则置 stage_b_combined_done
	# 让下面独立三段 wrapper 全部跳过（任何一项失败 / rc<0 都会让 done=false，
	# 自动透明回落到旧三段独立路径）。
	# 关键收益：消除 GDScript 端 3 次 pack（vit/lo/hi、soil/vg/tta、albedo+8 LUT）
	# + 3 次 refresh_slots_from_map + 3 次 unpack 循环。各段算法 1:1 同 cpp 旧路径。
	var stage_b_combined_done: bool = false
	var albedo_ms: float = 0.0
	var veg_dyn_ms: float = 0.0
	var feedback_ms: float = 0.0
	var vegetation_dirty := false
	var fast_slow_layering_on: bool = cp_now != null and bool(cp_now.fast_slow_layering_enabled)
	var combined_run_albedo: bool = run_albedo
	var combined_run_veg_dyn: bool = run_veg_dyn
	var combined_run_feedback: bool = run_feedback and fast_slow_layering_on
	# dots-flag-prune-pr1 round 2: use_gdext_stage_b_combined flag 已删除——恒走 ext +
	# has_method(run_stage_b_pass) 探测分支。DIAG 块保留原状，stage_b_flag_on 恒 true
	# 仅作为诊断记录。
	var stage_b_flag_on: bool = true  # 已折叠：flag 字段已删
	var stage_b_ext_ok: bool = _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_stage_b_pass")
	if not _gdext_stage_b_first_attempt_logged:
		_gdext_stage_b_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		if cp_now != null and cp_now.resource_path != "":
			cp_path = cp_now.resource_path
		var verdict: String = "OK → will try C++ combined pass"
		if not (stage_b_flag_on and stage_b_ext_ok):
			verdict = "FAIL → fall through to legacy three-pass path"
		print("[stage_b/combined] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_stage_b_combined = %s" % str(stage_b_flag_on))
		print("  _data_core_world_ext != null = %s" % str(_data_core_world_ext != null))
		print("  ext.has_method('run_stage_b_pass') = %s" % str(stage_b_ext_ok))
		print("  verdict = %s" % verdict)

	if stage_b_flag_on and stage_b_ext_ok \
			and (combined_run_albedo or combined_run_veg_dyn or combined_run_feedback):
		var t_combined_us0: int = Time.get_ticks_usec()
		# 细粒度子段计时（仅前 3 次 DEBUG 用）
		var _dbg_combined_first3: bool = (_gdext_stage_b_runs + _gdext_stage_b_fallbacks) < 3
		var t_iter_us: int = 0
		var t_pack_albedo_us: int = 0
		var t_pack_vegdyn_us: int = 0
		var t_pack_feedback_us: int = 0
		var t_refresh_us: int = 0
		var t_call_us: int = 0
		var t_unpack_us: int = 0
		var _dbg_t0: int = t_combined_us0
		var cells_c: Array = map.iter_cells() if map.has_indices() else map.all_cells()
		var n_cells_c: int = cells_c.size()
		if _dbg_combined_first3:
			t_iter_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		var knobs_c: Dictionary = {
			"n_cells": n_cells_c,
			"run_albedo": combined_run_albedo,
			"run_veg_dyn": combined_run_veg_dyn,
			"run_feedback": combined_run_feedback,
			# B3b 数据所有权下沉：6 字段已下沉到 SoA schema，cpp 端直读
			# _slots[].arr_*，消除 GDScript 端 pack/unpack hot loop。
			# 末尾 cpp 自动 flush 6 个新 slot 回 MapData，GDScript 端再做一次
			# 轻量"slot → HexCell 回灌"以兼容下游冷路径（overlay/info_panel/main）。
			"use_soa": true,
		}

		# ① ALBEDO 段入参（与 _apply_albedo_pass 完全一致）
		if combined_run_albedo:
			knobs_c["reference_albedo"]   = float(cp_now.reference_albedo)
			knobs_c["albedo_temp_gain"]   = float(cp_now.albedo_temp_gain)
			knobs_c["snow_cover_albedo"]  = 0.75
			knobs_c["cover_snow_id"]      = int(CoverType.CV.SNOW)
			knobs_c["cover_glacier_id"]   = int(CoverType.CV.GLACIER)
			knobs_c["albedo_table"]       = _build_albedo_donor_table()
		if _dbg_combined_first3:
			t_pack_albedo_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		# ② VEG_DYN 段入参（B3b 后 vit/streak 已下沉到 SoA，无需 pack PackedArray）
		if combined_run_veg_dyn:
			_ensure_vegdyn_lut()
			var veg_dyn_scale_raw: float = float(veg_dyn_stride)
			var veg_dyn_scale_eff: float = maxf(veg_dyn_scale_raw, 1.0)
			var streak_days_c: int = maxi(1, int(round(veg_dyn_scale_eff)))
			knobs_c["day_scale"]               = veg_dyn_scale_raw
			knobs_c["streak_days"]             = streak_days_c
			knobs_c["vitality_change_rate"]    = float(cp_now.vitality_change_rate)
			knobs_c["compat_harshness"]        = float(cp_now.compat_harshness)
			knobs_c["weather_penalty_scale"]   = float(cp_now.vegetation_weather_penalty_scale)
			knobs_c["plant_water_balance_weight"] = float(cp_now.plant_water_balance_weight)
			knobs_c["plant_soil_buffer_weight"] = float(cp_now.plant_soil_buffer_weight)
			knobs_c["plant_drought_penalty"] = float(cp_now.plant_drought_penalty)
			knobs_c["succession_min_compat_gain"] = float(cp_now.succession_min_compat_gain)
			knobs_c["low_threshold"]           = float(cp_now.vitality_low_threshold)
			knobs_c["high_threshold"]          = float(cp_now.vitality_high_threshold)
			knobs_c["succession_degrade_days"] = int(cp_now.succession_degrade_days)
			knobs_c["succession_upgrade_days"] = int(cp_now.succession_upgrade_days)
			knobs_c["vegetation_degrade_reset_target"] = float(cp_now.vegetation_degrade_reset_target) if cp_now.get("vegetation_degrade_reset_target") != null else 0.75
			knobs_c["vegetation_low_vitality_damping_threshold"] = float(cp_now.vegetation_low_vitality_damping_threshold) if cp_now.get("vegetation_low_vitality_damping_threshold") != null else 0.40
			knobs_c["vegetation_succession_cooldown_days"] = int(cp_now.vegetation_succession_cooldown_days) if cp_now.get("vegetation_succession_cooldown_days") != null else 30
			knobs_c["vegetation_stress_enabled"] = bool(cp_now.vegetation_stress_enabled) if cp_now.get("vegetation_stress_enabled") != null else false
			knobs_c["vegetation_stress_memory_days"] = float(cp_now.vegetation_stress_memory_days) if cp_now.get("vegetation_stress_memory_days") != null else 30.0
			knobs_c["n_wt"]                    = int(WeatherType.WT.size())
			knobs_c["wt_clear_id"]             = int(WeatherType.WT.CLEAR)
			knobs_c["wt_blizzard_id"]          = int(WeatherType.WT.BLIZZARD)
			knobs_c["wt_drought_id"]           = int(WeatherType.WT.DROUGHT)
			knobs_c["wt_heatwave_id"]          = int(WeatherType.WT.HEATWAVE)
			knobs_c["veg_none_id"]             = int(VegetationType.VEG.NONE)
			knobs_c["ideal_temp_table"]        = _gdext_vegdyn_ideal_temp_cached
			knobs_c["ideal_moist_table"]       = _gdext_vegdyn_ideal_moist_cached
			knobs_c["temp_tol_table"]          = _gdext_vegdyn_temp_tol_cached
			knobs_c["moist_tol_table"]         = _gdext_vegdyn_moist_tol_cached
			knobs_c["weather_penalty_table"]   = _gdext_vegdyn_weather_penalty_cached
			knobs_c["resistance_table"]        = _gdext_vegdyn_resistance_cached
			knobs_c["next_up_table"]           = _gdext_vegdyn_next_up_cached
			knobs_c["next_down_table"]         = _gdext_vegdyn_next_down_cached
			# 注：use_soa=true 时 cpp 直读 _slots[sid_vit/sid_low_streak/sid_high_streak]
			# vitality_arr / low_streak_arr / high_streak_arr 已不再传入
		if _dbg_combined_first3:
			t_pack_vegdyn_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		# ③ FEEDBACK 段入参（B3b 后 soil/vg/tta 已下沉到 SoA，无需 pack PackedArray）
		if combined_run_feedback:
			var feedback_scale_eff: float = maxf(float(feedback_stride), 1.0)
			var per_day_clamp_c: float = float(cp_now.feedback_per_day_clamp) * feedback_scale_eff
			var neighbor_indices_c: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
			# fast_indexed precondition：合并入口的 feedback 段必须 fully indexed；
			# 不满足时只降级 feedback 段（关掉合并里的 feedback 子开关 + 同步 knobs），
			# 让 albedo + veg_dyn 仍走合并 cpp call，feedback 由下面的 legacy wrapper 接管。
			if neighbor_indices_c.size() < n_cells_c * 6:
				push_warning("[stage_b/combined] neighbor_indices_packed not fully indexed (size=%d < %d), feedback段降级走 legacy wrapper" % [neighbor_indices_c.size(), n_cells_c * 6])
				combined_run_feedback = false
				knobs_c["run_feedback"] = false
			else:
				knobs_c["soil_gain"]               = float(cp_now.weather_to_soil_gain)
				knobs_c["veg_gain"]                = float(cp_now.weather_to_vegetation_gain)
				knobs_c["write_weather_veg_pressure"] = not combined_run_veg_dyn
				knobs_c["scale"]                   = feedback_scale_eff
				knobs_c["per_day_clamp"]           = per_day_clamp_c
				knobs_c["ocean_drift_gain"]        = float(cp_now.ocean_moisture_drift_gain)
				knobs_c["wt_rain_id"]              = int(WeatherType.WT.RAIN)
				knobs_c["wt_storm_id"]             = int(WeatherType.WT.STORM)
				knobs_c["wt_monsoon_id"]           = int(WeatherType.WT.MONSOON)
				knobs_c["wt_blizzard_id"]          = int(WeatherType.WT.BLIZZARD)
				knobs_c["wt_drought_id"]           = int(WeatherType.WT.DROUGHT)
				knobs_c["wt_heatwave_id"]          = int(WeatherType.WT.HEATWAVE)
				knobs_c["neighbor_indices"]        = neighbor_indices_c
				# 注：use_soa=true 时 cpp 直读 _slots[sid_tta/sid_soil/sid_vgp]
				# temp_transport_anomaly / soil_moisture_arr / veg_growth_pressure_arr 已不再传入
		if _dbg_combined_first3:
			t_pack_feedback_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		# 单次 refresh_slots_from_map（替代旧三段各自一次共三次）
		if _data_core_world_ext.has_method("refresh_slots_from_map"):
			_data_core_world_ext.refresh_slots_from_map()
		if _dbg_combined_first3:
			t_refresh_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		var rc_c: float = float(_data_core_world_ext.run_stage_b_pass(knobs_c))
		if _dbg_combined_first3:
			t_call_us = Time.get_ticks_usec() - _dbg_t0
			_dbg_t0 = Time.get_ticks_usec()

		if rc_c >= 0.0:
			# 段计时（C++ 写回）
			albedo_ms = float(knobs_c.get("albedo_ms", 0.0))
			veg_dyn_ms = float(knobs_c.get("veg_dyn_ms", 0.0))
			feedback_ms = float(knobs_c.get("feedback_ms", 0.0))

			# VEG_DYN 写回：cpp 已直写 SoA _slots[sid_vit/sid_low_streak/sid_high_streak]，
			# slot 与 map.vegetation_vitality_arr / vitality_low_streak_arr / vitality_high_streak_arr
			# 共享同一份 PackedArray 引用（zero-copy）。HexCell 端 5 字段已 facade 化
			# （hex_cell.gd L455-505），cell.vegetation_vitality / _vitality_low_streak / _vitality_high_streak
			# 的 getter 直接走 world.read_f32/i32 → 拿到的就是 cpp 刚写完的最新值。
			# 因此 unpack 回灌循环（n_cells × 3 PackedArray.get + cell setter）可整段删除，
			# 这是 wall ≤ 1ms 收益的核心来源。
			if combined_run_veg_dyn:
				# 演替候选（与 _apply_vegetation_dynamics L7099-7115 完全一致）
				# 注：succession 后处理会显式覆写 vegetation_vitality（0.65/0.7），
				# cell.vegetation_vitality = new_vit_c 通过 facade setter 自动 write_f32
				# 到 SoA，与 map.vegetation_vitality_arr 引用一致。
				var succ_indices_c: PackedInt32Array = knobs_c.get("succession_indices", PackedInt32Array())
				var succ_to_veg_c: PackedByteArray = knobs_c.get("succession_to_veg", PackedByteArray())
				var n_succ_c: int = succ_indices_c.size()
				for k in range(n_succ_c):
					var ci_c: int = succ_indices_c[k]
					if ci_c < 0 or ci_c >= n_cells_c:
						continue
					var c_succ: HexCell = cells_c[ci_c]
					var prev_veg_c: int = int(c_succ.vegetation)
					var new_veg_c: int = int(succ_to_veg_c[k])
					var is_degrade_c: bool = (prev_veg_c < _gdext_vegdyn_next_down_cached.size() \
							and int(_gdext_vegdyn_next_down_cached[prev_veg_c]) == new_veg_c \
							and new_veg_c != prev_veg_c)
					c_succ.vegetation = new_veg_c
					c_succ.base_vegetation = new_veg_c
					# vegetation-survival-rebalance v2：软重置代替硬重置。
					# 原本 new_vit_c = 0.65/0.7 会把 vitality 拉回足以触发
					# 下一轮演替中间的仰角 → 全图永远抽在 0.7 附近。
					# 改为 (old + target) * 0.5 后，vitality 保留历史梯度，
					# 热力图重新发热，还能防连锁死亡。
					var prev_vit_c: float = c_succ.vegetation_vitality
					var target_vit_c: float = (float(cp_now.vegetation_degrade_reset_target) if cp_now.get("vegetation_degrade_reset_target") != null else 0.75) if is_degrade_c else 0.7
					c_succ.vegetation_vitality = (prev_vit_c + target_vit_c) * 0.5  # facade setter → world.write_f32
					var cooldown_days_c: int = int(cp_now.vegetation_succession_cooldown_days) if cp_now.get("vegetation_succession_cooldown_days") != null else 30
					if cooldown_days_c > 0:
						c_succ._vitality_low_streak = -cooldown_days_c
						c_succ._vitality_high_streak = -cooldown_days_c
					c_succ.current_state["vegetation"] = new_veg_c
					vegetation_dirty = true

			# FEEDBACK 写回：cpp 已直写 SoA _slots[sid_soil/sid_vgp]，与 map.soil_moisture_arr /
			# vegetation_growth_pressure_arr 共享 PackedArray 引用。HexCell 端 soil_moisture /
			# vegetation_growth_pressure 已 facade 化（hex_cell.gd L668-697），getter 自动从
			# SoA 拿最新值，无需 unpack 回灌循环。

			stage_b_combined_done = true
			_gdext_stage_b_runs += 1
			_gdext_stage_b_total_ms += rc_c
			if _gdext_stage_b_runs == 1:
				print("[stage_b/combined] gdext path ACTIVE — first run elapsed=%.2fms (legacy three-pass total ≈ 6–15ms; target ≤ 1.5ms)" % rc_c)
				print("  per-stage: albedo=%.2fms veg_dyn=%.2fms feedback=%.2fms" % [albedo_ms, veg_dyn_ms, feedback_ms])
			# ─── DIAGNOSTIC: vegetation_vitality 数据通路一次性体检 ─────────────
			# 跑 N 次后采样一次（让 vitality 有机会漂移），打印 4 个数据源的全图分布。
			# 目的：定位"全图 70%"是 cpp 没漂、facade 没启用、还是渲染读错源。
			# 顺便每 5 次报一次心跳，确认 pass 在持续运行。
			if (_gdext_stage_b_runs % 5) == 0 and _gdext_stage_b_runs <= 20:
				print("[veg_vit/HEARTBEAT] stage_b combined runs=%d" % _gdext_stage_b_runs)
			if _gdext_stage_b_runs == 5:
				var _diag_n: int = cells_c.size()
				var _diag_cid: int = -1
				# 关键：参数 world 是 WorldData（无 component_id），必须用 _data_core_world（DCWorld）
				var _dcw = _data_core_world
				if _dcw != null and _dcw.has_method("component_id"):
					_diag_cid = int(_dcw.component_id(&"cell.vegetation_vitality"))
				var _v_min_get: float =  1e9
				var _v_max_get: float = -1e9
				var _v_sum_get: float = 0.0
				var _v_min_soa: float =  1e9
				var _v_max_soa: float = -1e9
				var _v_sum_soa: float = 0.0
				var _v_min_arr: float =  1e9
				var _v_max_arr: float = -1e9
				var _v_sum_arr: float = 0.0
				var _land_cnt: int = 0
				var _facade_on_cnt: int = 0
				var _arr_size: int = map.vegetation_vitality_arr.size() if map != null else 0
				for _di in range(_diag_n):
					var _dc: HexCell = cells_c[_di]
					if _dc == null or bool(_dc.passable_sea):
						continue
					_land_cnt += 1
					if _dc.is_facade_enabled():
						_facade_on_cnt += 1
					var _vg: float = float(_dc.vegetation_vitality)  # getter
					if _vg < _v_min_get: _v_min_get = _vg
					if _vg > _v_max_get: _v_max_get = _vg
					_v_sum_get += _vg
					if _diag_cid >= 0:
						var _vs: float = float(_dcw.read_f32(_diag_cid, _di))
						if _vs < _v_min_soa: _v_min_soa = _vs
						if _vs > _v_max_soa: _v_max_soa = _vs
						_v_sum_soa += _vs
					if _di < _arr_size:
						var _va: float = float(map.vegetation_vitality_arr[_di])
						if _va < _v_min_arr: _v_min_arr = _va
						if _va > _v_max_arr: _v_max_arr = _va
						_v_sum_arr += _va
				print("[veg_vit/DIAG] tick #5  land_cells=%d  facade_on=%d/%d  cid=%d  arr_size=%d" % [_land_cnt, _facade_on_cnt, _land_cnt, _diag_cid, _arr_size])
				if _land_cnt > 0:
					print("  getter (cell.vegetation_vitality):  min=%.4f  max=%.4f  avg=%.4f" % [_v_min_get, _v_max_get, _v_sum_get / float(_land_cnt)])
					if _diag_cid >= 0:
						print("  SoA    (world.read_f32):             min=%.4f  max=%.4f  avg=%.4f" % [_v_min_soa, _v_max_soa, _v_sum_soa / float(_land_cnt)])
					if _arr_size > 0:
						print("  array  (map.vegetation_vitality_arr): min=%.4f  max=%.4f  avg=%.4f" % [_v_min_arr, _v_max_arr, _v_sum_arr / float(_land_cnt)])
		else:
			_gdext_stage_b_fallbacks += 1
			if _gdext_stage_b_fallbacks == 1:
				print("[stage_b/combined] gdext path UNAVAILABLE: run_stage_b_pass — falling back to legacy three-pass path")
		# combined elapsed wall-clock（含 pack/unpack/marshal）—— 仅 DEBUG 前 3 次
		if _gdext_stage_b_runs + _gdext_stage_b_fallbacks <= 3:
			# unpack 段：从 t_call_us 测完到现在
			t_unpack_us = Time.get_ticks_usec() - _dbg_t0
			var combined_wall_ms: float = (Time.get_ticks_usec() - t_combined_us0) / 1000.0
			print("[stage_b/combined] DEBUG call#%d: rc=%.4f wall=%.2fms run_a=%s run_v=%s run_f=%s" % [
				_gdext_stage_b_runs + _gdext_stage_b_fallbacks,
				rc_c, combined_wall_ms,
				str(combined_run_albedo), str(combined_run_veg_dyn), str(combined_run_feedback),
			])
			print("  breakdown(ms): iter=%.2f pack_albedo=%.2f pack_vegdyn=%.2f pack_feedback=%.2f refresh=%.2f call=%.2f unpack=%.2f" % [
				t_iter_us / 1000.0,
				t_pack_albedo_us / 1000.0,
				t_pack_vegdyn_us / 1000.0,
				t_pack_feedback_us / 1000.0,
				t_refresh_us / 1000.0,
				t_call_us / 1000.0,
				t_unpack_us / 1000.0,
			])

	# ─── Legacy 三段 wrapper（合并失败时 / flag 关闭时的 fallback；保留原行为） ─
	if not stage_b_combined_done:
		if run_albedo:
			t_us0 = Time.get_ticks_usec()
			_apply_albedo_pass(map)
			albedo_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
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
	if not stage_b_combined_done:
		if cp_now != null and bool(cp_now.fast_slow_layering_enabled) and run_feedback:
			t_us0 = Time.get_ticks_usec()
			_apply_weather_to_map_feedback_pass(map, float(feedback_stride), not run_veg_dyn)
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
		"field_solve_ms": float(sub.get("field_solve_ms", 0.0)),
		"field_solve_total_ms": float(sub.get("field_solve_total_ms", 0.0)),
		"field_summary_ms": float(sub.get("field_summary_ms", sub.get("spawn_ms", 0.0))),
		"field_commit_total_ms": float(sub.get("field_commit_total_ms", 0.0)),
		"field_commit_setup_ms": float(sub.get("field_commit_setup_ms", 0.0)),
		"field_commit_loop_ms": float(sub.get("field_commit_loop_ms", 0.0)),
		"field_commit_path": str(sub.get("field_commit_path", "")),
		"field_commit_publish_verified": bool(sub.get("field_commit_publish_verified", false)),
		"field_commit_publish_repaired": bool(sub.get("field_commit_publish_repaired", false)),
		"field_commit_init_count": int(sub.get("field_commit_init_count", 0)),
		"field_commit_publish_reason": str(sub.get("field_commit_publish_reason", "")),
		"field_commit_dc_ms": float(sub.get("field_commit_dc_ms", 0.0)),
		"field_commit_convergence_ms": float(sub.get("field_commit_convergence_ms", 0.0)),
		"field_solve_tick": int(sub.get("field_solve_tick", -1)),
		"weather_commit_tick_delta": int(sub.get("weather_commit_tick_delta", 0)),
		"weather_last_commit_tick": int(sub.get("weather_last_commit_tick", -1)),
		"weather_cold_front_count": int(sub.get("weather_cold_front_count", 0)),
		"weather_warm_front_count": int(sub.get("weather_warm_front_count", 0)),
		"field_convergence_refresh_stride": int(sub.get("field_convergence_refresh_stride", 0)),
		"refresh_convergence": bool(sub.get("refresh_convergence", false)),
		"native_convergence_boost": bool(sub.get("native_convergence_boost", false)),
		"weather_convergence_dirty_count": int(sub.get("weather_convergence_dirty_count", 0)),
		"weather_convergence_delta_p95": float(sub.get("weather_convergence_delta_p95", 0.0)),
		"convergence_published": bool(sub.get("convergence_published", false)),
		"weather_dirty_count": int(sub.get("weather_dirty_count", 0)),
		"water_budget_error": float(sub.get("water_budget_error", 0.0)),
		"active_weather_ratio": float(sub.get("active_weather_ratio", 0.0)),
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
		# 方案 ④ Step 1：标记本帧 fast tick，perf_recorder 据此过滤 stale 回放
		"_tick_idx": _current_fast_tick_idx,
	}
	# 5/21 突刺诊断：weather_tick≥5ms 或 cyclone≥3ms 时打全字段
	_dump_weather_breakdown_if_slow()

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
func _apply_weather_to_map_feedback_pass(map: MapData, day_scale: float = 1.0, write_weather_veg_pressure: bool = true) -> void:
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
	# 让天气流动(2026-06-21)：weather → base_moisture 反馈增益(cp.get 兼容旧 profile 无此字段)。
	var base_m_gain: float = float(cp.weather_to_base_moisture_gain) if cp.get("weather_to_base_moisture_gain") != null else 0.0
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = neighbor_indices.size() >= n_cells * 6

	# ─── DOTS-Final-Push 任务 4：DCWorldExt C++ 快路径 ──────────────────
	# 触发条件：
	#   1. ClimateProfile.use_gdext_climate_feedback == true
	#   2. _data_core_world_ext 已 bind 且 has_method("run_climate_feedback_pass")
	#   3. fast_indexed（neighbor_indices_packed 完整 — ocean drift 段需要）
	#   4. C++ 端返回 ≥ 0
	# 任意一条不满足 → 透明 fallback 到下面 GDScript 单循环。
	#
	# soil_moisture / veg_growth_pressure / temperature_transport_anomaly 三个字段
	# 未 SoA 化，走 in/out PackedArray pack/unpack。base_moisture 已 SoA，C++ 直读直写。
	if not _gdext_feedback_first_attempt_logged:
		_gdext_feedback_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		var flag_val: bool = true  # use_gdext_climate_feedback flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp != null and cp.resource_path != "":
			cp_path = cp.resource_path
		var ext_ok: bool = _data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _data_core_world_ext.has_method("run_climate_feedback_pass")
		var verdict: String = "OK → will try C++"
		if not (flag_val and ext_ok and has_method_ok and fast_indexed):
			verdict = "FAIL → fall through to GDScript path"
		print("[feedback/stage_b] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_climate_feedback = %s (flag removed; constant true)" % str(flag_val))
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_climate_feedback_pass') = %s" % str(has_method_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got neighbor_indices.size()=%d)" % [str(fast_indexed), n_cells * 6, neighbor_indices.size()])
		print("  verdict = %s" % verdict)
	if cp != null and _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_climate_feedback_pass") and fast_indexed:
		if not _gdext_feedback_signature_checked:
			_gdext_feedback_signature_checked = true
			_gdext_feedback_signature_ok = _validate_gdext_method_signature("run_climate_feedback_pass", 1)
			print("[feedback/stage_b] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_gdext_feedback_signature_ok))
		# Pack in/out 数组：3 个 PackedFloat32Array（n_cells 长度）
		var soil_arr: PackedFloat32Array = PackedFloat32Array()
		var vg_arr: PackedFloat32Array = PackedFloat32Array()
		var tta_arr: PackedFloat32Array = PackedFloat32Array()
		soil_arr.resize(n_cells)
		vg_arr.resize(n_cells)
		tta_arr.resize(n_cells)
		for i in range(n_cells):
			var cell_pack: HexCell = cells[i]
			soil_arr[i] = cell_pack.soil_moisture
			vg_arr[i] = cell_pack.vegetation_growth_pressure
			tta_arr[i] = cell_pack.temperature_transport_anomaly
		var knobs: Dictionary = {
			"n_cells": n_cells,
			"soil_gain": soil_gain,
			"veg_gain": veg_gain,
			"write_weather_veg_pressure": write_weather_veg_pressure,
			"scale": scale,
			"per_day_clamp": per_day_clamp,
			"ocean_drift_gain": ocean_drift_gain,
			"weather_to_base_moisture_gain": base_m_gain,
			"wt_clear_id": int(WeatherType.WT.CLEAR),
			"wt_rain_id": int(WeatherType.WT.RAIN),
			"wt_storm_id": int(WeatherType.WT.STORM),
			"wt_monsoon_id": int(WeatherType.WT.MONSOON),
			"wt_blizzard_id": int(WeatherType.WT.BLIZZARD),
			"wt_drought_id": int(WeatherType.WT.DROUGHT),
			"wt_heatwave_id": int(WeatherType.WT.HEATWAVE),
			"neighbor_indices": neighbor_indices,
			"temp_transport_anomaly": tta_arr,
			"soil_moisture_arr": soil_arr,
			"veg_growth_pressure_arr": vg_arr,
		}
		# storage A/B 同源契约：refresh 让 SoA 取得最新值（接 weather_refresh 上一段）
		if _data_core_world_ext.has_method("refresh_slots_from_map"):
			_data_core_world_ext.refresh_slots_from_map()
		# dots-flag-prune-pr1 round 2: use_gdext_thread_fallback flag 已删除——恒走
		# C++ scalar 入口 run_climate_feedback_pass，C++ 内部根据 CPU 特性 / n_cells 自动
		# 选择 scalar / SIMD / threaded 三档执行路径。
		var rc: float = float(_data_core_world_ext.run_climate_feedback_pass(knobs))
		if _gdext_feedback_runs + _gdext_feedback_fallbacks < 3:
			print("[feedback/stage_b] DEBUG call#%d: rc=%.4f n_cells=%d scale=%.2f" % [
				_gdext_feedback_runs + _gdext_feedback_fallbacks + 1,
				rc, n_cells, scale,
			])
		if rc >= 0.0:
			# 写回 in/out arrays（base_moisture 已通过 SoA flush 写回 cell.base_moisture）
			var soil_out: PackedFloat32Array = knobs.get("soil_moisture_arr", soil_arr)
			var vg_out: PackedFloat32Array = knobs.get("veg_growth_pressure_arr", vg_arr)
			for i in range(n_cells):
				var cell_unpack: HexCell = cells[i]
				cell_unpack.soil_moisture = soil_out[i]
				cell_unpack.vegetation_growth_pressure = vg_out[i]
			_gdext_feedback_runs += 1
			_gdext_feedback_total_ms += rc
			if _gdext_feedback_runs == 1:
				print("[feedback/stage_b] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 6.1ms; target < 0.5ms)" % rc)
			return
		_gdext_feedback_fallbacks += 1
		if _gdext_feedback_fallbacks == 1:
			print("[stage_b] gdext path UNAVAILABLE: run_climate_feedback_pass — falling back to GDScript")

	for i in range(cells.size()):
		var cell: HexCell = cells[i]
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
			if fast_indexed:
				var base: int = i * 6
				for d in range(6):
					var nb_idx: int = neighbor_indices[base + d]
					if nb_idx < 0:
						continue
					var nb: HexCell = cells[nb_idx]
					if _is_water(nb.terrain):
						sum_an += nb.temperature_transport_anomaly
						n_water += 1
			else:
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
		# 让天气流动(2026-06-21)：weather → base_moisture 直接反馈(镜像 C++ run_climate_feedback_pass)。
		if base_m_gain > 0.0:
			var d_bm: float = clampf(base_m_gain * precip_contrib * scale, -per_day_clamp, per_day_clamp)
			cell.base_moisture = clampf(cell.base_moisture + d_bm, 0.0, 1.0)
		if write_weather_veg_pressure:
			# 未跑 veg_dyn 的 tick 保留天气压力；跑过 veg_dyn 的 tick 让 VGP 保持 target - vitality。
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
# F.5 helper：按 VegetationType.VEG enum 顺序构建 transpiration donor table。
# 第一次调用时填好 cache，后续直接返回 cache（仍需 cache 副本 → C++ 端 zero-copy
# 入参；godot::PackedFloat32Array 经 Variant 边界后 refcount ≥ 2 但 ptr() 不会
# CoW，仅 ptrw() 才会）。VEG enum 长度通过 VegetationType.VEG.size() 取（GDScript
# enum 在 GDScript 4 中支持 .size() / .keys() 反射）。
func _build_transpiration_donor_table() -> PackedFloat32Array:
	if _gdext_transp_donor_table_cached.size() > 0:
		return _gdext_transp_donor_table_cached
	var n_veg: int = VegetationType.VEG.size()
	var table: PackedFloat32Array = PackedFloat32Array()
	table.resize(n_veg)
	for v in range(n_veg):
		table[v] = VegetationType.transpiration(v)
	_gdext_transp_donor_table_cached = table
	return _gdext_transp_donor_table_cached


func _make_transpiration_native_unavailable(reason: String, t_wall_us: int, n_cells: int = 0) -> Dictionary:
	var elapsed_ms: float = (Time.get_ticks_usec() - t_wall_us) / 1000.0
	var result: Dictionary = _make_climate_pass_result("transp", false, elapsed_ms, 0, -1, -1,
			_CLIMATE_PASS_STATUS_FAILED, 0, "native_unavailable", reason)
	result["path"] = "gdscript_sliced"
	result["cursor_remaining"] = n_cells
	result["next_stage"] = "compute"
	return result


func _sync_transpiration_native_outputs(map: MapData, dirty_indices: PackedInt32Array, dirty_values: PackedFloat32Array) -> Dictionary:
	var t_sync_us: int = Time.get_ticks_usec()
	var out: Dictionary = {
		"sync_total_ms": 0.0,
		"sync_write_ms": 0.0,
		"sync_mark_ms": 0.0,
		"sync_path": "none",
		"dirty_count": dirty_indices.size(),
	}
	if _data_core_world == null or map == null:
		out["sync_path"] = "missing_context"
		out["sync_total_ms"] = (Time.get_ticks_usec() - t_sync_us) / 1000.0
		return out
	var n: int = map.cell_count()
	if n <= 0 or map.moisture_arr.size() < n:
		out["sync_path"] = "missing_soa"
		out["sync_total_ms"] = (Time.get_ticks_usec() - t_sync_us) / 1000.0
		return out
	var cid_moist: int = _data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
	if cid_moist >= 0 and dirty_indices.size() > 0 and dirty_values.size() >= dirty_indices.size() \
			and _data_core_world.has_method("write_f32_indexed"):
		var t_write_us: int = Time.get_ticks_usec()
		_data_core_world.write_f32_indexed(cid_moist, dirty_indices, dirty_values)
		out["sync_write_ms"] = (Time.get_ticks_usec() - t_write_us) / 1000.0
		if _data_core_world.has_method("mark_dirty_indexed"):
			var t_mark_us: int = Time.get_ticks_usec()
			_data_core_world.mark_dirty_indexed(dirty_indices)
			out["sync_mark_ms"] = (Time.get_ticks_usec() - t_mark_us) / 1000.0
		out["sync_path"] = "indexed"
	elif cid_moist >= 0 and _data_core_world.has_method("write_f32_dense"):
		var t_dense_us: int = Time.get_ticks_usec()
		_data_core_world.write_f32_dense(cid_moist, map.moisture_arr)
		out["sync_write_ms"] = (Time.get_ticks_usec() - t_dense_us) / 1000.0
		out["sync_path"] = "dense"
	else:
		out["sync_path"] = "missing_writer"
	out["sync_total_ms"] = (Time.get_ticks_usec() - t_sync_us) / 1000.0
	return out


func run_transpiration_pass_native(map: MapData) -> Dictionary:
	var t_wall_us: int = Time.get_ticks_usec()
	var n_cells: int = map.cell_count() if map != null else 0
	if map == null:
		return _make_transpiration_native_unavailable("missing_map", t_wall_us, n_cells)
	var cp_f5 := _c()
	if cp_f5 == null:
		return _make_transpiration_native_unavailable("missing_climate_profile", t_wall_us, n_cells)
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = n_cells > 0 and neighbor_indices.size() >= n_cells * 6
	if not _gdext_transp_first_attempt_logged:
		_gdext_transp_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		if cp_f5.resource_path != "":
			cp_path = cp_f5.resource_path
		var ext_ok: bool = _data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _data_core_world_ext.has_method("run_transpiration_pass")
		var verdict: String = "OK -> will try C++"
		if not (ext_ok and has_method_ok and fast_indexed):
			verdict = "FAIL -> fall through to GDScript sliced path"
		print("[transp/F.5] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_transpiration = true (flag removed; constant true)")
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_transpiration_pass') = %s" % str(has_method_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got neighbor_indices.size()=%d)" % [str(fast_indexed), n_cells * 6, neighbor_indices.size()])
		print("  verdict = %s" % verdict)
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("run_transpiration_pass"):
		return _make_transpiration_native_unavailable("native_unavailable", t_wall_us, n_cells)
	if not fast_indexed:
		return _make_transpiration_native_unavailable("missing_neighbor_indices", t_wall_us, n_cells)
	if not _gdext_transp_signature_checked:
		_gdext_transp_signature_checked = true
		_gdext_transp_signature_ok = _validate_gdext_method_signature("run_transpiration_pass", 1)
		print("[transp/F.5] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_gdext_transp_signature_ok))
	var donor_table: PackedFloat32Array = _build_transpiration_donor_table()
	var knobs: Dictionary = {
		"n_cells": n_cells,
		"outflow_rate": float(cp_f5.transpiration_outflow_rate),
		"self_rate": float(cp_f5.transpiration_self_rate),
		"neighbor_indices": neighbor_indices,
		"donor_table": donor_table,
	}
	var refresh_ms: float = 0.0
	# refresh-consolidation-2026-06：climate_daily round 守门员。仅当未在本 round
	# 内 refresh 过时才计时，避免 skip 路径误报 refresh_ms。
	if _data_core_world_ext.has_method("refresh_slots_from_map") and not _climate_daily_round_slots_fresh:
		var t_refresh_us: int = Time.get_ticks_usec()
		_ensure_climate_daily_round_slots_fresh()
		refresh_ms = (Time.get_ticks_usec() - t_refresh_us) / 1000.0
	else:
		_ensure_climate_daily_round_slots_fresh()  # may skip
	var t_native_us: int = Time.get_ticks_usec()
	var rc: float = float(_data_core_world_ext.run_transpiration_pass(knobs))
	var native_call_ms: float = (Time.get_ticks_usec() - t_native_us) / 1000.0
	if _gdext_transp_runs + _gdext_transp_fallbacks < 3:
		print("[transp/F.5] DEBUG call#%d: rc=%.4f donor_table.size()=%d n_cells=%d outflow=%.4f self=%.4f" % [
			_gdext_transp_runs + _gdext_transp_fallbacks + 1,
			rc, donor_table.size(), n_cells,
			float(cp_f5.transpiration_outflow_rate),
			float(cp_f5.transpiration_self_rate),
		])
	if rc < 0.0:
		_gdext_transp_fallbacks += 1
		return _make_transpiration_native_unavailable("native_failed", t_wall_us, n_cells)
	var dirty_indices: PackedInt32Array = knobs.get("dirty_indices", PackedInt32Array())
	var dirty_values: PackedFloat32Array = knobs.get("dirty_values", PackedFloat32Array())
	var sync_diag: Dictionary = _sync_transpiration_native_outputs(map, dirty_indices, dirty_values)
	_gdext_transp_runs += 1
	_gdext_transp_total_ms += rc
	if _gdext_transp_runs == 1:
		print("[transp/F.5] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript sliced hotspot now bypassed)" % rc)
	var elapsed_ms: float = (Time.get_ticks_usec() - t_wall_us) / 1000.0
	var result: Dictionary = _make_climate_pass_result("transp", true, elapsed_ms, n_cells, 0, n_cells,
			_CLIMATE_PASS_STATUS_DONE, 0, "native")
	var sync_total_ms: float = float(sync_diag.get("sync_total_ms", 0.0))
	var dominant_substage: String = "native"
	var dominant_ms: float = rc
	if refresh_ms > dominant_ms:
		dominant_ms = refresh_ms
		dominant_substage = "refresh"
	if sync_total_ms > dominant_ms:
		dominant_ms = sync_total_ms
		dominant_substage = "sync"
	result["path"] = "gdext"
	result["native_ms"] = rc
	result["native_call_ms"] = native_call_ms
	result["native_compute_ms"] = float(knobs.get("compute_ms", 0.0))
	result["native_apply_ms"] = float(knobs.get("apply_ms", 0.0))
	result["native_flush_ms"] = float(knobs.get("flush_ms", 0.0))
	result["refresh_ms"] = refresh_ms
	result["sync_ms"] = sync_total_ms
	result["sync_total_ms"] = sync_total_ms
	result["sync_write_ms"] = float(sync_diag.get("sync_write_ms", 0.0))
	result["sync_mark_ms"] = float(sync_diag.get("sync_mark_ms", 0.0))
	result["sync_path"] = str(sync_diag.get("sync_path", ""))
	result["substage"] = dominant_substage
	result["diagnostic_wall_ms"] = elapsed_ms
	result["dirty_count"] = int(knobs.get("dirty_count", dirty_indices.size()))
	result["cursor_remaining"] = 0
	result["next_stage"] = "done"
	return result


func _apply_transpiration_pass(map: MapData) -> void:
	# 阶段 1：算每 cell 的"输出额"（不立刻写）
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = neighbor_indices.size() >= n_cells * 6

	# ─── Phase F.5：DCWorldExt C++ 快路径（charter §7 P2，3.2ms → 0.3ms）─
	# 触发条件：
	#   1. ClimateProfile.use_gdext_transpiration == true
	#   2. _data_core_world_ext 已 bind（class_exists("DCWorldExt") && bind_map_data 成功）
	#   3. fast_indexed（neighbor_indices_packed 完整）
	#   4. C++ 端 run_transpiration_pass 返回 ≥ 0
	# 任意一条不满足 → 透明 fallback 到下面的 GDScript 双 phase 循环。
	#
	# 与 F.1 同模板：单 shot 全图，写直接落 cell_moisture SoA。GDScript 一侧 cell.moisture
	# = soa[i] 已经在 fastpath HexCell typed fields 路径下生效（main.gd 启动日志
	# `[fastpath] HexCell typed fields active (SoA)`），所以 C++ 写 SoA 等价于 GDScript
	# 写 cell.moisture，不需要再做一次 cell.moisture = ... 兜底。
	var cp_f5 := _c()
	# F.5 无脑首次诊断：在做任何条件检查之前，把 5 个 precondition 的真实值 +
	# 当前 ClimateProfile 资源路径全部打印一次。这样"flag 表面 true 实际 false"
	# 类隐藏 bug（编辑了错的 .tres / 改了 inspector 但没保存 / @export 资源被
	# 别的实例覆盖）能一眼看穿，不需要在 if 嵌套深处反复加 print 排查。
	if not _gdext_transp_first_attempt_logged:
		_gdext_transp_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		var flag_val: bool = true  # use_gdext_transpiration flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp_f5 != null and cp_f5.resource_path != "":
			cp_path = cp_f5.resource_path
		var ext_ok: bool = _data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _data_core_world_ext.has_method("run_transpiration_pass")
		var verdict: String = "OK → will try C++"
		if not (flag_val and ext_ok and has_method_ok and fast_indexed):
			verdict = "FAIL → fall through to GDScript path"
		print("[transp/F.5] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_transpiration = %s (flag removed; constant true)" % str(flag_val))
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_transpiration_pass') = %s" % str(has_method_ok))
		print("  fast_indexed = %s (need n_cells*6=%d, got neighbor_indices.size()=%d)" % [str(fast_indexed), n_cells * 6, neighbor_indices.size()])
		print("  verdict = %s" % verdict)
	if cp_f5 != null and _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_transpiration_pass") and fast_indexed:
		# Stale .dll probe（一次/session）：先无脑跑一次（带详细诊断 print），
		# 但即使 probe 判 false 也不阻止下面的 C++ 调用——避免 strict equality
		# 在某些 godot-cpp 版本误判把好的 .dll 也拒了。stale .dll 的真正信号是
		# rc=0.0 + console "Invalid call ... Expected N argument(s)"。
		if not _gdext_transp_signature_checked:
			_gdext_transp_signature_checked = true
			_gdext_transp_signature_ok = _validate_gdext_method_signature("run_transpiration_pass", 1)
			print("[transp/F.5] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_gdext_transp_signature_ok))
		var donor_table: PackedFloat32Array = _build_transpiration_donor_table()
		var knobs: Dictionary = {
			"n_cells": n_cells,
			"outflow_rate": float(cp_f5.transpiration_outflow_rate),
			"self_rate": float(cp_f5.transpiration_self_rate),
			"neighbor_indices": neighbor_indices,
			"donor_table": donor_table,
		}
		# storage A/B 同源契约（修复 B 2026-05-14）：sea_ice 已 flush 到 map，
		# refresh 让本 pass 读 cell.moisture / cell.weather_precip 等取得最新值。
		# 详见 docs/dots-f4-validation.md §2.2.b。
		if _data_core_world_ext.has_method("refresh_slots_from_map"):
			_data_core_world_ext.refresh_slots_from_map()
		var rc: float = float(_data_core_world_ext.run_transpiration_pass(knobs))
		# 强制无脑诊断：前 3 次调用无论 rc 多少都打一行（含 donor_table 长度），
		# 让 stale-dll / silent-fallback / 隐藏 -1.0 一类 bug 没法藏。
		if _gdext_transp_runs + _gdext_transp_fallbacks < 3:
			print("[transp/F.5] DEBUG call#%d: rc=%.4f donor_table.size()=%d n_cells=%d outflow=%.4f self=%.4f" % [
				_gdext_transp_runs + _gdext_transp_fallbacks + 1,
				rc, donor_table.size(), n_cells,
				float(cp_f5.transpiration_outflow_rate),
				float(cp_f5.transpiration_self_rate),
			])
		if rc >= 0.0:
			# C++ 完成全量写到 SoA cell_moisture。fastpath 模式下 cell.moisture
			# 是 SoA alias，无需再回写。
			_gdext_transp_runs += 1
			_gdext_transp_total_ms += rc
			if _gdext_transp_runs == 1:
				print("[transp/F.5] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 3.2ms; charter §7 target < 0.3ms)" % rc)
			return
		_gdext_transp_fallbacks += 1
		# rc<0：C++ 已 push_warning；继续 fall through 到 GDScript 双 phase 循环

	var deltas := PackedFloat32Array()
	deltas.resize(n_cells)
	for i in range(n_cells):
		var cell: HexCell = cells[i]
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
		deltas[i] = deltas[i] + self_share
		if fast_indexed:
			var base: int = i * 6
			for d_idx in range(6):
				var nb_idx: int = neighbor_indices[base + d_idx]
				if nb_idx < 0:
					continue
				var nb: HexCell = cells[nb_idx]
				# 海面邻居不接受陆地蒸腾外溢（避免给海加湿）
				if LandformType.is_water(nb.landform):
					continue
				deltas[nb_idx] = deltas[nb_idx] + nb_share
		else:
			for nb: HexCell in map.get_neighbors(cell):
				if LandformType.is_water(nb.landform):
					continue
				var nb_idx_fallback: int = map.index_of(nb)
				if nb_idx_fallback >= 0 and nb_idx_fallback < n_cells:
					deltas[nb_idx_fallback] = deltas[nb_idx_fallback] + nb_share
	# 阶段 2：把所有 delta 应用到 current_state.moisture（一次性，避免顺序敏感）
	#
	# PR-2.1.5（transpiration 模板 PR）：写路径下移到 world.write_f32_indexed。
	# 详见 docs/dots-master-execution-handbook.md §3.3 + §9.1 模板 1。
	#   - 收集 dirty_indices + new_values（dirty 仅 deltas[i] != 0 的格子）
	#   - 双写保留：cell.moisture 仍写（PR-2.3 facade 化时由 setter 统一处理）
	#   - 一次性 write_f32_indexed（避免每 idx 单调用的开销 / CoW 风险）
	var _t_dirty_idx: PackedInt32Array = PackedInt32Array()
	var _t_dirty_val: PackedFloat32Array = PackedFloat32Array()
	_t_dirty_idx.resize(n_cells)
	_t_dirty_val.resize(n_cells)
	var _t_write_i: int = 0
	for i in range(n_cells):
		var d: float = deltas[i]
		if d == 0.0:
			continue
		var cell: HexCell = cells[i]
		var new_moist: float = clampf(cell.moisture + d, 0.0, 1.0)
		# Fast-tick perf opt (C)：直接读写强类型成员（双写，PR-2.3 facade 化前保留）。
		cell.moisture = new_moist
		_t_dirty_idx[_t_write_i] = i
		_t_dirty_val[_t_write_i] = new_moist
		_t_write_i += 1
	_t_dirty_idx.resize(_t_write_i)
	_t_dirty_val.resize(_t_write_i)
	if _data_core_world != null and _t_write_i > 0:
		var _cid_moist: int = _data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
		if _cid_moist >= 0:
			_data_core_world.write_f32_indexed(_cid_moist, _t_dirty_idx, _t_dirty_val)

# Pass 2：反照率反馈。植被反照率高（雪、沙漠）→ 反射阳光 → 局地温度下降；
# 反照率低（深色森林、湿地）→ 吸收阳光 → 局地温度上升。
# 公式：Δtemp = (REFERENCE_ALBEDO - albedo) × ALBEDO_TEMP_GAIN
# REFERENCE_ALBEDO=0.30 是中性参考（无植被裸地）。雨林 albedo=0.10 → +0.005 / day。
# const REFERENCE_ALBEDO (migrated to ClimateProfile.reference_albedo)
# const ALBEDO_TEMP_GAIN (migrated to ClimateProfile.albedo_temp_gain)  # 每"日"最大 ±0.005 温度调制
# DOTS-Final-Push 任务 2 helper：按 VegetationType.VEG enum 顺序构建 albedo donor table。
# 与 F.5 _build_transpiration_donor_table 同模式：一次性 cache，VEG enum 长度固定。
# C++ run_albedo_pass 入参 albedo_table 通过 Variant 边界 zero-copy 共享 ptr。
func _build_albedo_donor_table() -> PackedFloat32Array:
	if _gdext_albedo_table_cached.size() > 0:
		return _gdext_albedo_table_cached
	var n_veg: int = VegetationType.VEG.size()
	var table: PackedFloat32Array = PackedFloat32Array()
	table.resize(n_veg)
	for v in range(n_veg):
		table[v] = VegetationType.albedo(v)
	_gdext_albedo_table_cached = table
	return _gdext_albedo_table_cached

func _apply_albedo_pass(map: MapData) -> void:
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()

	# ─── DOTS-Final-Push 任务 2：DCWorldExt C++ 快路径 ───────────────────
	# 触发条件：
	#   1. ClimateProfile.use_gdext_albedo == true
	#   2. _data_core_world_ext 已 bind
	#   3. C++ 端 run_albedo_pass 返回 ≥ 0
	# 任意一条不满足 → 透明 fallback 到下面 GDScript 单循环。
	# 与 climate_pass_b 共享 cell_is_water / cell_vegetation / cell_cover / cell_temp 槽位，
	# 写直接落 SoA cell_temp（fastpath HexCell typed fields 模式下等价于 cell.temperature）。
	var cp_alb := _c()
	if not _gdext_albedo_first_attempt_logged:
		_gdext_albedo_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		var flag_val: bool = true  # use_gdext_albedo flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp_alb != null and cp_alb.resource_path != "":
			cp_path = cp_alb.resource_path
		var ext_ok: bool = _data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _data_core_world_ext.has_method("run_albedo_pass")
		var verdict: String = "OK → will try C++"
		if not (flag_val and ext_ok and has_method_ok):
			verdict = "FAIL → fall through to GDScript path"
		print("[albedo/stage_b] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_albedo = %s (flag removed; constant true)" % str(flag_val))
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_albedo_pass') = %s" % str(has_method_ok))
		print("  verdict = %s" % verdict)
	if cp_alb != null and _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_albedo_pass"):
		if not _gdext_albedo_signature_checked:
			_gdext_albedo_signature_checked = true
			_gdext_albedo_signature_ok = _validate_gdext_method_signature("run_albedo_pass", 1)
			print("[albedo/stage_b] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_gdext_albedo_signature_ok))
		var albedo_table: PackedFloat32Array = _build_albedo_donor_table()
		var knobs: Dictionary = {
			"n_cells": n_cells,
			"reference_albedo": float(cp_alb.reference_albedo),
			"albedo_temp_gain": float(cp_alb.albedo_temp_gain),
			"snow_cover_albedo": 0.75,
			"cover_snow_id": int(CoverType.CV.SNOW),
			"cover_glacier_id": int(CoverType.CV.GLACIER),
			"albedo_table": albedo_table,
		}
		# storage A/B 同源契约：在 stage_b 链路上前序 pass（fronts / sea_ice / 等）
		# 已 flush 到 map，refresh 让 cell.temperature / cell.cover / cell.vegetation
		# 取得最新值再计算（与 transp/F.5 同模式）。
		if _data_core_world_ext.has_method("refresh_slots_from_map"):
			_data_core_world_ext.refresh_slots_from_map()
		# dots-flag-prune-pr1 round 2: use_gdext_thread_fallback flag 已删除——恒走
		# C++ scalar 入口 run_albedo_pass，C++ 内部根据 CPU 特性 / n_cells 自动选择
		# scalar / SIMD / threaded 三档执行路径。
		var rc: float = float(_data_core_world_ext.run_albedo_pass(knobs))
		if _gdext_albedo_runs + _gdext_albedo_fallbacks < 3:
			print("[albedo/stage_b] DEBUG call#%d: rc=%.4f albedo_table.size()=%d n_cells=%d ref_alb=%.3f gain=%.4f" % [
				_gdext_albedo_runs + _gdext_albedo_fallbacks + 1,
				rc, albedo_table.size(), n_cells,
				float(cp_alb.reference_albedo), float(cp_alb.albedo_temp_gain),
			])
		if rc >= 0.0:
			_gdext_albedo_runs += 1
			_gdext_albedo_total_ms += rc
			if _gdext_albedo_runs == 1:
				print("[albedo/stage_b] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 3.6ms; target < 0.5ms)" % rc)
			return
		_gdext_albedo_fallbacks += 1
		# rc<0：C++ 已 push_warning；继续 fall through 到 GDScript 路径
		# 一次性 UNAVAILABLE 提示（与需求 1.7 对齐）：仅当 fallback 计数从 0 → 1 时打
		if _gdext_albedo_fallbacks == 1:
			print("[stage_b] gdext path UNAVAILABLE: run_albedo_pass — falling back to GDScript")

	for cell: HexCell in cells:
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

# DOTS-Final-Push 任务 3 helper：构建（一次性 cache）vegetation_dynamics 所需 8 张 LUT。
#  - ideal_temp / ideal_moist / temp_tol / moist_tol  按 VEG enum 顺序的 PackedFloat32Array
#  - weather_penalty_table                           按 WT enum 顺序的 PackedFloat32Array
#  - resistance_table                                平铺 VEG×WT 的 PackedFloat32Array
#  - next_up_table / next_down_table                 按 VEG enum 顺序的 PackedByteArray
# 全部为静态查询，运行期不变（VegetationProfileRegistry 是 res:// 资源，profile
# 资源换了 / inspector 改了 ideal_* 时需要 reload 整个项目，cache 会被自然丢弃）。
func _ensure_vegdyn_lut() -> void:
	if _gdext_vegdyn_ideal_temp_cached.size() > 0:
		return
	var n_veg: int = VegetationType.VEG.size()
	var n_wt: int = WeatherType.WT.size()
	var ideal_t: PackedFloat32Array = PackedFloat32Array()
	var ideal_m: PackedFloat32Array = PackedFloat32Array()
	var tol_t: PackedFloat32Array = PackedFloat32Array()
	var tol_m: PackedFloat32Array = PackedFloat32Array()
	var nx_up: PackedByteArray = PackedByteArray()
	var nx_dn: PackedByteArray = PackedByteArray()
	ideal_t.resize(n_veg)
	ideal_m.resize(n_veg)
	tol_t.resize(n_veg)
	tol_m.resize(n_veg)
	nx_up.resize(n_veg)
	nx_dn.resize(n_veg)
	for v in range(n_veg):
		var p := VegetationProfileRegistry.get_profile(v)
		ideal_t[v] = float(p.ideal_temp)
		ideal_m[v] = float(p.ideal_moist)
		tol_t[v] = float(p.temp_tolerance)
		tol_m[v] = float(p.moist_tolerance)
		nx_up[v] = int(VegetationType.next_in_succession(v, 1))
		nx_dn[v] = int(VegetationType.next_in_succession(v, -1))
	_gdext_vegdyn_ideal_temp_cached = ideal_t
	_gdext_vegdyn_ideal_moist_cached = ideal_m
	_gdext_vegdyn_temp_tol_cached = tol_t
	_gdext_vegdyn_moist_tol_cached = tol_m
	_gdext_vegdyn_next_up_cached = nx_up
	_gdext_vegdyn_next_down_cached = nx_dn
	# weather_penalty 表（按 WT enum 顺序）：参考本文件 const WEATHER_VITALITY_PENALTY 字典，
	# 未声明的 WT 默认 0.0。
	var wpn: PackedFloat32Array = PackedFloat32Array()
	wpn.resize(n_wt)
	for wt_id in range(n_wt):
		wpn[wt_id] = float(WEATHER_VITALITY_PENALTY.get(wt_id, 0.0))
	_gdext_vegdyn_weather_penalty_cached = wpn
	# resistance_table：VEG × WT 平铺，VegetationType.weather_resistance 提供单点查询
	var res: PackedFloat32Array = PackedFloat32Array()
	res.resize(n_veg * n_wt)
	for v in range(n_veg):
		var base: int = v * n_wt
		for wt_id in range(n_wt):
			res[base + wt_id] = float(VegetationType.weather_resistance(v, wt_id))
	_gdext_vegdyn_resistance_cached = res


func _plant_available_water(base_moisture: float, water_balance_30d: float, soil_moisture: float) -> float:
	var cp := _c()
	return clampf(
		base_moisture
		+ maxf(water_balance_30d, 0.0) * float(cp.plant_water_balance_weight)
		+ maxf(soil_moisture, 0.0) * float(cp.plant_soil_buffer_weight)
		+ minf(water_balance_30d, 0.0) * float(cp.plant_drought_penalty),
		0.0,
		1.0
	)


func _vegetation_weather_stress(veg: int, wt: int, wi: float) -> float:
	var base_penalty: float = float(WEATHER_VITALITY_PENALTY.get(wt, 0.0))
	var resistance: float = VegetationType.weather_resistance(veg, wt)
	return base_penalty * maxf(wi, 0.0) * (1.0 - resistance) * float(_c().vegetation_weather_penalty_scale)


func _update_vegetation_stress(cell: HexCell, map: MapData, idx: int, temp: float,
		plant_water: float, compat: float, weather_stress: float,
		day_scale: float) -> Dictionary:
	var cp := _c()
	var memory_days: float = maxf(float(cp.vegetation_stress_memory_days), 1.0)
	var blend: float = clampf(day_scale / memory_days, 0.0, 1.0)
	var prof := VegetationProfileRegistry.get_profile(int(cell.vegetation))
	var temp_tol: float = maxf(float(prof.temp_tolerance), 0.05)
	var moist_tol: float = maxf(float(prof.moist_tolerance), 0.05)
	var heat_input: float = clampf((temp - (float(prof.ideal_temp) + temp_tol)) / temp_tol, 0.0, 1.0)
	var cold_input: float = clampf(((float(prof.ideal_temp) - temp_tol) - temp) / temp_tol, 0.0, 1.0)
	var water_deficit: float = clampf(((float(prof.ideal_moist) - moist_tol) - plant_water) / moist_tol, 0.0, 1.0)
	var drought_input: float = water_deficit
	if cell.weather_field_initialized:
		if int(cell.weather_type) == int(WeatherType.WT.HEATWAVE):
			heat_input = maxf(heat_input, clampf(cell.weather_intensity, 0.0, 1.0))
		elif int(cell.weather_type) == int(WeatherType.WT.DROUGHT):
			drought_input = maxf(drought_input, water_deficit * clampf(cell.weather_intensity, 0.0, 1.0))
		elif int(cell.weather_type) == int(WeatherType.WT.BLIZZARD):
			cold_input = maxf(cold_input, clampf(cell.weather_intensity, 0.0, 1.0))
	var old_heat: float = cell.vegetation_heat_stress
	var old_drought: float = cell.vegetation_drought_stress
	var old_cold: float = cell.vegetation_cold_stress
	var old_regen: float = cell.vegetation_regen_score
	if idx >= 0:
		if idx < map.vegetation_heat_stress_arr.size():
			old_heat = map.vegetation_heat_stress_arr[idx]
		if idx < map.vegetation_drought_stress_arr.size():
			old_drought = map.vegetation_drought_stress_arr[idx]
		if idx < map.vegetation_cold_stress_arr.size():
			old_cold = map.vegetation_cold_stress_arr[idx]
		if idx < map.vegetation_regen_score_arr.size():
			old_regen = map.vegetation_regen_score_arr[idx]
	var regen_input: float = clampf(compat * (1.0 - weather_stress) * (0.5 + 0.5 * plant_water), 0.0, 1.0)
	var heat: float = lerpf(old_heat, heat_input, blend)
	var drought: float = lerpf(old_drought, drought_input, blend)
	var cold: float = lerpf(old_cold, cold_input, blend)
	var regen: float = lerpf(old_regen, regen_input, blend)
	cell.vegetation_heat_stress = heat
	cell.vegetation_drought_stress = drought
	cell.vegetation_cold_stress = cold
	cell.vegetation_regen_score = regen
	if idx >= 0:
		if idx < map.vegetation_heat_stress_arr.size():
			map.vegetation_heat_stress_arr[idx] = heat
		if idx < map.vegetation_drought_stress_arr.size():
			map.vegetation_drought_stress_arr[idx] = drought
		if idx < map.vegetation_cold_stress_arr.size():
			map.vegetation_cold_stress_arr[idx] = cold
		if idx < map.vegetation_regen_score_arr.size():
			map.vegetation_regen_score_arr[idx] = regen
	return {
		"stress": maxf(heat, maxf(drought, cold)),
		"regen": regen,
	}


func _apply_vegetation_dynamics(map: MapData, day_scale: float = 1.0) -> bool:
	var any_changed: bool = false
	var scale: float = maxf(day_scale, 1.0)
	var streak_days: int = maxi(1, int(round(scale)))
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()

	# ─── DOTS-Final-Push 任务 3：DCWorldExt C++ 快路径 ────────────────────
	# 触发条件：
	#   1. ClimateProfile.use_gdext_vegetation_dynamics == true
	#   2. _data_core_world_ext 已 bind 且 has_method("run_vegetation_dynamics_pass")
	#   3. C++ 端返回 ≥ 0
	# 任意一条不满足 → 透明 fallback 到下面 GDScript 单循环。
	# 与 sea_ice 同模式：演替触发的写入（cell.vegetation/base_vegetation/current_state）
	# 由 GDScript 后处理；C++ 仅返回候选列表 succession_indices + succession_to_veg。
	var cp_vd := _c()
	if not _gdext_vegdyn_first_attempt_logged:
		_gdext_vegdyn_first_attempt_logged = true
		var cp_path: String = "<in-memory ClimateProfile>"
		var flag_val: bool = true  # use_gdext_vegetation_dynamics flag removed (dots-flag-prune-pr1, 2026-05-22)
		if cp_vd != null and cp_vd.resource_path != "":
			cp_path = cp_vd.resource_path
		var ext_ok: bool = _data_core_world_ext != null
		var has_method_ok: bool = ext_ok and _data_core_world_ext.has_method("run_vegetation_dynamics_pass")
		var verdict: String = "OK → will try C++"
		if not (flag_val and ext_ok and has_method_ok):
			verdict = "FAIL → fall through to GDScript path"
		print("[veg_dyn/stage_b] precondition probe (one-time):")
		print("  active ClimateProfile = %s" % cp_path)
		print("  cp.use_gdext_vegetation_dynamics = %s (flag removed; constant true)" % str(flag_val))
		print("  _data_core_world_ext != null = %s" % str(ext_ok))
		print("  ext.has_method('run_vegetation_dynamics_pass') = %s" % str(has_method_ok))
		print("  verdict = %s" % verdict)
	if cp_vd != null and not bool(cp_vd.vegetation_stress_enabled) \
			and _data_core_world_ext != null \
			and _data_core_world_ext.has_method("run_vegetation_dynamics_pass"):
		if not _gdext_vegdyn_signature_checked:
			_gdext_vegdyn_signature_checked = true
			_gdext_vegdyn_signature_ok = _validate_gdext_method_signature("run_vegetation_dynamics_pass", 1)
			print("[veg_dyn/stage_b] sig probe result = %s（仅作诊断，不阻止下方 C++ 调用）" % str(_gdext_vegdyn_signature_ok))
		# 构建/复用 LUT + pack vitality / streak in/out arrays。
		_ensure_vegdyn_lut()
		var vitality_arr: PackedFloat32Array = PackedFloat32Array()
		var low_streak_arr: PackedInt32Array = PackedInt32Array()
		var high_streak_arr: PackedInt32Array = PackedInt32Array()
		vitality_arr.resize(n_cells)
		low_streak_arr.resize(n_cells)
		high_streak_arr.resize(n_cells)
		for i in range(n_cells):
			var cell_pack: HexCell = cells[i]
			vitality_arr[i] = cell_pack.vegetation_vitality
			low_streak_arr[i] = cell_pack._vitality_low_streak
			high_streak_arr[i] = cell_pack._vitality_high_streak
		var n_wt: int = WeatherType.WT.size()
		var knobs: Dictionary = {
			"n_cells": n_cells,
			"day_scale": float(day_scale),
			"streak_days": streak_days,
			"vitality_change_rate": float(cp_vd.vitality_change_rate),
			"compat_harshness": float(cp_vd.compat_harshness),
			"weather_penalty_scale": float(cp_vd.vegetation_weather_penalty_scale),
			"plant_water_balance_weight": float(cp_vd.plant_water_balance_weight),
			"plant_soil_buffer_weight": float(cp_vd.plant_soil_buffer_weight),
			"plant_drought_penalty": float(cp_vd.plant_drought_penalty),
			"succession_min_compat_gain": float(cp_vd.succession_min_compat_gain),
			"low_threshold": float(cp_vd.vitality_low_threshold),
			"high_threshold": float(cp_vd.vitality_high_threshold),
			"succession_degrade_days": int(cp_vd.succession_degrade_days),
			"succession_upgrade_days": int(cp_vd.succession_upgrade_days),
			"vegetation_degrade_reset_target": float(cp_vd.vegetation_degrade_reset_target) if cp_vd.get("vegetation_degrade_reset_target") != null else 0.75,
			"vegetation_low_vitality_damping_threshold": float(cp_vd.vegetation_low_vitality_damping_threshold) if cp_vd.get("vegetation_low_vitality_damping_threshold") != null else 0.40,
			"vegetation_succession_cooldown_days": int(cp_vd.vegetation_succession_cooldown_days) if cp_vd.get("vegetation_succession_cooldown_days") != null else 30,
			"n_wt": n_wt,
			"wt_clear_id": int(WeatherType.WT.CLEAR),
			"veg_none_id": int(VegetationType.VEG.NONE),
			"ideal_temp_table": _gdext_vegdyn_ideal_temp_cached,
			"ideal_moist_table": _gdext_vegdyn_ideal_moist_cached,
			"temp_tol_table": _gdext_vegdyn_temp_tol_cached,
			"moist_tol_table": _gdext_vegdyn_moist_tol_cached,
			"weather_penalty_table": _gdext_vegdyn_weather_penalty_cached,
			"resistance_table": _gdext_vegdyn_resistance_cached,
			"next_up_table": _gdext_vegdyn_next_up_cached,
			"next_down_table": _gdext_vegdyn_next_down_cached,
			"vitality_arr": vitality_arr,
			"low_streak_arr": low_streak_arr,
			"high_streak_arr": high_streak_arr,
		}
		# storage A/B 同源契约：与 albedo / transp 同模式，refresh 让 SoA 取得最新值
		if _data_core_world_ext.has_method("refresh_slots_from_map"):
			_data_core_world_ext.refresh_slots_from_map()
		# dots-flag-prune-pr1 round 2: use_gdext_thread_fallback flag 已删除——恒走
		# C++ scalar 入口 run_vegetation_dynamics_pass，C++ 内部根据 CPU 特性 / n_cells
		# 自动选择 scalar / SIMD / threaded 三档执行路径。
		var _vegdyn_dispatch_path: String = "scalar"
		var rc: float = float(_data_core_world_ext.run_vegetation_dynamics_pass(knobs))
		if _gdext_vegdyn_runs + _gdext_vegdyn_fallbacks < 3:
			print("[veg_dyn/stage_b] DEBUG call#%d: path=%s rc=%.4f n_cells=%d scale=%.2f" % [
				_gdext_vegdyn_runs + _gdext_vegdyn_fallbacks + 1,
				_vegdyn_dispatch_path, rc, n_cells, scale,
			])
		if rc >= 0.0:
			# 写回 vitality / streak —— knobs in/out 模式
			var vit_out: PackedFloat32Array = knobs.get("vitality_arr", vitality_arr)
			var ls_out: PackedInt32Array = knobs.get("low_streak_arr", low_streak_arr)
			var hs_out: PackedInt32Array = knobs.get("high_streak_arr", high_streak_arr)
			# [perf 2026-05-20] 替换原来的 for-loop 单点 setter（每帧 N 次 _dirty_mark_one
			# 风暴）为 dense 批量写。只标 dirty range 一次，atlas_upload 不再被打成全脏。
			# 注意：facade 走 SoA 真值源，backing field 在 facade_enabled=true 时无人读，
			# 所以这里安全地绕过 setter，直接写底层 component。
			if _data_core_world != null:
				var _cid_vit: int = _data_core_world.component_id(DCComponentIds.CELL_VEGETATION_VITALITY)
				var _cid_ls: int = _data_core_world.component_id(DCComponentIds.CELL_VITALITY_LOW_STREAK)
				var _cid_hs: int = _data_core_world.component_id(DCComponentIds.CELL_VITALITY_HIGH_STREAK)
				if _cid_vit >= 0:
					_data_core_world.write_f32_dense(_cid_vit, vit_out)
				if _cid_ls >= 0:
					_data_core_world.write_i32_dense(_cid_ls, ls_out)
				if _cid_hs >= 0:
					_data_core_world.write_i32_dense(_cid_hs, hs_out)
			else:
				# fallback：facade 未启用时仍走 setter（backing 必须更新）
				for i in range(n_cells):
					var cell_unpack: HexCell = cells[i]
					cell_unpack.vegetation_vitality = vit_out[i]
					cell_unpack._vitality_low_streak = ls_out[i]
					cell_unpack._vitality_high_streak = hs_out[i]
			# 应用演替候选（GDScript 后处理：写 cell.vegetation / base_vegetation / current_state）
			# 退化起点 vitality=0.65（远离 LOW_THRESHOLD 给适应缓冲），升级起点 vitality=0.70
			# —— 与 _trigger_succession 的 0.65 / 0.7 分歧严格对齐。
			var succ_indices: PackedInt32Array = knobs.get("succession_indices", PackedInt32Array())
			var succ_to_veg: PackedByteArray = knobs.get("succession_to_veg", PackedByteArray())
			var n_succ: int = succ_indices.size()
			for k in range(n_succ):
				var ci: int = succ_indices[k]
				if ci < 0 or ci >= n_cells:
					continue
				var c: HexCell = cells[ci]
				var prev_veg: int = int(c.vegetation)
				var new_veg: int = int(succ_to_veg[k])
				# 判断方向：C++ 端先尝试退化（next_down），失败才尝试升级（next_up）
				# 这里用 cached LUT 反查方向，与 _trigger_succession 的 priority 顺序一致
				var is_degrade: bool = (prev_veg < _gdext_vegdyn_next_down_cached.size() \
						and int(_gdext_vegdyn_next_down_cached[prev_veg]) == new_veg \
						and new_veg != prev_veg)
				c.vegetation = new_veg
				c.base_vegetation = new_veg
				# vegetation-survival-rebalance v2：软重置（详见合并 pass 同段注释）
				var prev_vit: float = c.vegetation_vitality
				var target_vit: float = (float(cp_vd.vegetation_degrade_reset_target) if cp_vd.get("vegetation_degrade_reset_target") != null else 0.75) if is_degrade else 0.7
				c.vegetation_vitality = (prev_vit + target_vit) * 0.5
				if ci < vit_out.size():
					vit_out[ci] = c.vegetation_vitality
				var cooldown_days: int = int(cp_vd.vegetation_succession_cooldown_days) if cp_vd.get("vegetation_succession_cooldown_days") != null else 30
				if cooldown_days > 0:
					if ci < ls_out.size():
						ls_out[ci] = -cooldown_days
					if ci < hs_out.size():
						hs_out[ci] = -cooldown_days
				c.current_state["vegetation"] = new_veg
				any_changed = true
			if any_changed and _data_core_world != null:
				var _cid_vit_after: int = _data_core_world.component_id(DCComponentIds.CELL_VEGETATION_VITALITY)
				var _cid_ls_after: int = _data_core_world.component_id(DCComponentIds.CELL_VITALITY_LOW_STREAK)
				var _cid_hs_after: int = _data_core_world.component_id(DCComponentIds.CELL_VITALITY_HIGH_STREAK)
				if _cid_vit_after >= 0:
					_data_core_world.write_f32_dense(_cid_vit_after, vit_out)
				if _cid_ls_after >= 0:
					_data_core_world.write_i32_dense(_cid_ls_after, ls_out)
				if _cid_hs_after >= 0:
					_data_core_world.write_i32_dense(_cid_hs_after, hs_out)
			_gdext_vegdyn_runs += 1
			_gdext_vegdyn_total_ms += rc
			if _gdext_vegdyn_runs == 1:
				print("[veg_dyn/stage_b] gdext path ACTIVE (dispatch=%s) — first run elapsed=%.2fms (legacy GDScript baseline ≈ 9.2ms; target < 1.0ms)" % [_vegdyn_dispatch_path, rc])
			return any_changed
		_gdext_vegdyn_fallbacks += 1
		if _gdext_vegdyn_fallbacks == 1:
			print("[stage_b] gdext path UNAVAILABLE: run_vegetation_dynamics_pass — falling back to GDScript")

	for cell: HexCell in cells:
		if LandformType.is_water(cell.landform):
			_clear_cell_vegetation_state(map, cell)
			continue
		if int(cell.vegetation) == int(VegetationType.VEG.NONE):
			_clear_cell_vegetation_state(map, cell)
			continue
		# 生态慢层读 30 日温度与 30 日水分平衡，单日天气只作为小惩罚项。
		var idx_vd: int = int(cell.index)
		var temp: float = cell.temp_30d_mean
		var water_balance_30d: float = 0.0
		var soil_moisture: float = 0.0
		if idx_vd >= 0 and idx_vd < map.temp_30d_arr.size():
			temp = map.temp_30d_arr[idx_vd]
		if idx_vd >= 0 and idx_vd < map.water_balance_30d_arr.size():
			water_balance_30d = map.water_balance_30d_arr[idx_vd]
		if idx_vd >= 0 and idx_vd < map.soil_moisture_arr.size():
			soil_moisture = map.soil_moisture_arr[idx_vd]
		var plant_water: float = _plant_available_water(cell.moisture, water_balance_30d, soil_moisture)
		var compat: float = VegetationType.climate_compat_score(cell.vegetation, temp, plant_water)
		var wt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var wi: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		var weather_stress: float = _vegetation_weather_stress(int(cell.vegetation), wt, wi)
		var stress_max: float = 0.0
		var regen_score: float = 0.0
		if bool(cp_vd.vegetation_stress_enabled):
			var stress_info: Dictionary = _update_vegetation_stress(
					cell, map, idx_vd, temp, plant_water, compat, weather_stress, scale)
			stress_max = float(stress_info.get("stress", 0.0))
			regen_score = float(stress_info.get("regen", 0.0))
		var water_pressure: float = clampf(water_balance_30d * 0.18 + soil_moisture * 0.10, -0.12, 0.12)
		var target: float = clampf(compat + water_pressure - weather_stress - stress_max * 0.25 + regen_score * 0.10, 0.0, 1.0)
		var prev_vitality: float = cell.vegetation_vitality
		var dv: float = (target - prev_vitality) * float(_c().vitality_change_rate)
		if dv < 0.0:
			dv *= float(_c().compat_harshness)
			var damping_threshold: float = float(_c().vegetation_low_vitality_damping_threshold) if _c().get("vegetation_low_vitality_damping_threshold") != null else 0.40
			if prev_vitality < damping_threshold:
				dv *= clampf(prev_vitality / maxf(damping_threshold, 0.001), 0.25, 1.0)
		cell.vegetation_vitality = clampf(prev_vitality + dv * scale, 0.0, 1.0)
		if idx_vd >= 0 and idx_vd < map.vegetation_growth_pressure_arr.size():
			map.vegetation_growth_pressure_arr[idx_vd] = target - prev_vitality
		else:
			cell.vegetation_growth_pressure = target - prev_vitality

		var in_cooldown: bool = cell._vitality_low_streak < 0 or cell._vitality_high_streak < 0
		if in_cooldown:
			cell._vitality_low_streak = mini(cell._vitality_low_streak + streak_days, 0)
			cell._vitality_high_streak = mini(cell._vitality_high_streak + streak_days, 0)
			continue

		# Streak 计数同时要求历史活力和当前目标都在触发区，过滤短期天气残留。
		if stress_max > 0.65 and target < _c().vitality_high_threshold:
			cell._vitality_low_streak += maxi(streak_days, int(round(float(streak_days) * stress_max)))
			cell._vitality_high_streak = 0
		elif cell.vegetation_vitality < _c().vitality_low_threshold and target < _c().vitality_low_threshold:
			cell._vitality_low_streak += streak_days
			cell._vitality_high_streak = 0
		elif cell.vegetation_vitality > _c().vitality_high_threshold \
				and target > _c().vitality_high_threshold and regen_score > 0.55:
			cell._vitality_high_streak += streak_days
			cell._vitality_low_streak = 0
		else:
			# 中性区间：streak 缓慢清零（避免极端事件遗留计数）
			cell._vitality_low_streak = maxi(cell._vitality_low_streak - streak_days, 0)
			cell._vitality_high_streak = maxi(cell._vitality_high_streak - streak_days, 0)

		# 触发演替（climate-loop-closure Phase 3.2：传入 temp/plant_water 供气候导向退化）
		if _trigger_succession(cell, temp, plant_water, compat):
			any_changed = true
	if bool(cp_vd.vegetation_stress_enabled) and _data_core_world != null:
		var _cid_vhs: int = _data_core_world.component_id(DCComponentIds.CELL_VEGETATION_HEAT_STRESS)
		var _cid_vds: int = _data_core_world.component_id(DCComponentIds.CELL_VEGETATION_DROUGHT_STRESS)
		var _cid_vcs: int = _data_core_world.component_id(DCComponentIds.CELL_VEGETATION_COLD_STRESS)
		var _cid_vrs: int = _data_core_world.component_id(DCComponentIds.CELL_VEGETATION_REGEN_SCORE)
		if _cid_vhs >= 0:
			_data_core_world.write_f32_dense(_cid_vhs, map.vegetation_heat_stress_arr)
		if _cid_vds >= 0:
			_data_core_world.write_f32_dense(_cid_vds, map.vegetation_drought_stress_arr)
		if _cid_vcs >= 0:
			_data_core_world.write_f32_dense(_cid_vcs, map.vegetation_cold_stress_arr)
		if _cid_vrs >= 0:
			_data_core_world.write_f32_dense(_cid_vrs, map.vegetation_regen_score_arr)
	return any_changed

# 演替触发判定：streak 达到阈值且有可演替的下一阶 → 写 cell.vegetation 并 reset。
# 返回值 = 是否实际发生了演替。
func _trigger_succession(cell: HexCell, temp: float = 0.5, moist: float = 0.5, current_compat: float = -1.0) -> bool:
	if cell._vitality_low_streak < 0 or cell._vitality_high_streak < 0:
		return false
	var min_gain: float = float(_c().succession_min_compat_gain)
	var current_score: float = current_compat
	if current_score < 0.0:
		current_score = VegetationType.climate_compat_score(cell.vegetation, temp, moist)
	# 退化优先（连续不适应更紧迫）
	if cell._vitality_low_streak >= _c().succession_degrade_days:
		# climate-loop-closure Phase 3.2：气候导向退化目标（过湿→湿生，过旱→荒漠）。
		var next_h: int = VegetationType.best_degrade_target(cell.vegetation, temp, moist)
		var next_h_score: float = VegetationType.climate_compat_score(next_h, temp, moist) if next_h != cell.vegetation else -1.0
		if next_h != cell.vegetation and next_h_score >= current_score + min_gain:
			cell.vegetation = next_h
			cell.base_vegetation = next_h          # 演替后基线也跟着前进
			# vegetation-survival-rebalance v2：软重置代替硬重置。
			# 原本硬设 vitality=0.65 会把低 vitality 拉高、高 vitality 拉低，
			# 两者都抹去了热力梯度。软混合保留历史。
			var reset_target: float = float(_c().vegetation_degrade_reset_target) if _c().get("vegetation_degrade_reset_target") != null else 0.75
			cell.vegetation_vitality = (cell.vegetation_vitality + reset_target) * 0.5
			var cooldown_days: int = int(_c().vegetation_succession_cooldown_days) if _c().get("vegetation_succession_cooldown_days") != null else 30
			cell._vitality_low_streak = -cooldown_days if cooldown_days > 0 else 0
			cell._vitality_high_streak = -cooldown_days if cooldown_days > 0 else 0
			cell.current_state["vegetation"] = int(cell.vegetation)
			return true
		# 没有下家：把 streak 清零防止反复触发
		cell._vitality_low_streak = 0
		return false
	if cell._vitality_high_streak >= _c().succession_upgrade_days:
		var next_r: int = VegetationType.next_in_succession(cell.vegetation, 1)
		var next_r_score: float = VegetationType.climate_compat_score(next_r, temp, moist) if next_r != cell.vegetation else -1.0
		if next_r != cell.vegetation and next_r_score >= current_score + min_gain:
			cell.vegetation = next_r
			cell.base_vegetation = next_r
			# vegetation-survival-rebalance v2：软重置（详见退化分支同段注释）
			cell.vegetation_vitality = (cell.vegetation_vitality + 0.7) * 0.5
			var cooldown_days_up: int = int(_c().vegetation_succession_cooldown_days) if _c().get("vegetation_succession_cooldown_days") != null else 30
			cell._vitality_low_streak = -cooldown_days_up if cooldown_days_up > 0 else 0
			cell._vitality_high_streak = -cooldown_days_up if cooldown_days_up > 0 else 0
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

# 名义季节温度偏移：只用于旧 refresh_seasonal 行缓存兼容；运行时气候链条
# 始终由太阳几何 -> 日照偏差 -> 热惯性推进。
# ny ∈ [0, 1]：0 = 北极，0.5 = 赤道，1 = 南极。
# season_phase 用整数中点（0.5 / 1.5 / 2.5 / 3.5）做"季节中段"评估。
func _season_temp_offset(ny: float, season: int) -> float:
	var phase_mid: float = float(season) + 0.5
	return _insolation_season_offset(ny, phase_mid)

# ─── Emergent Climate Coupling：太阳辐照（insolation） ───────────────────
# True Insolation-Driven Climate（Phase F）：把 insolation 提升为"单一真值源"。
#
# 物理解读：
#   year_progress   = fposmod(season_phase, 4) / 4                  # ∈ [0, 1)
#   subsolar_lat    = axial_tilt × cos(2π · year_progress)          # 直射点纬度（rad）
#                     phase=0(1月) → +tilt（南向 subsolar，北半球冬至）
#                     phase=2(7月) → -tilt（北向 subsolar，北半球夏至）
#   daily_insol     = 日出到日落太阳高度积分（含极昼/极夜和昼长）
#
# 半球反相由 sign(lat) 自然涌现，不再需要旧代码里的 `if lat < 0: phase += 2`
# 手动翻转。
const _INSOLATION_DAYLEN_AMP: float = 0.35  # legacy 默认；运行时被 profile.insolation_daylen_amp 覆盖

# PR-3.3.1（M4 拆分）：纯数学 helper 已迁至 DCClimateMath。
# 本类保留 thin wrapper 兼容现有调用方（_c() 上下文读取仍由 map_generator 持有）。
func _subsolar_lat_rad(season_phase: float) -> float:
	var cp := _c()
	var tilt_deg: float = 23.5
	if cp != null and "axial_tilt_deg" in cp:
		tilt_deg = cp.axial_tilt_deg
	return DCClimateMath.subsolar_lat_rad(season_phase, tilt_deg)

func _compute_insolation(ny: float, season_phase: float) -> float:
	var cp := _c()
	var amp: float = _INSOLATION_DAYLEN_AMP
	var tilt_deg: float = 23.5
	if cp != null:
		if "insolation_daylen_amp" in cp:
			amp = cp.insolation_daylen_amp
		if "axial_tilt_deg" in cp:
			tilt_deg = cp.axial_tilt_deg
	return DCClimateMath.compute_daily_insolation(ny, season_phase, tilt_deg, amp)

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

# 日射季节偏差（legacy 气压求解 / UI 读法）：直接路由到 DCClimateMath 单一来源。
# 2026-06-16 物理化：删除"极地放大/衰减"band-aid，dev 还原为纯物理偏差。极地夏季
# 过热改由吸收短波因子（DCClimateMath.surface_absorbed_factor）在 pass_a season_offset 处理。
func _insol_dev(ny: float, season_phase: float) -> float:
	var mean_val: float = _insolation_annual_mean(ny)
	var now_val: float = _compute_insolation(ny, season_phase)
	return clampf(DCClimateMath.compute_insolation_dev_from_values(ny, now_val, mean_val), -1.0, 1.0)

# True Insolation-Driven：温度季节偏移的兼容读法。
# offset = gain × dev × season_temp_amp
# 与 legacy 独立余弦的差别：
#   - 幅度不再是纬度无关常量，而是随 ny 涌现（赤道小、高纬大）
#   - 半球反相通过 dev 的符号自然产生（subsolar 移向北时南半球 dev<0）
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
	# 冷侧软压缩（v2）：与 pass_a 同源，使 UI/legacy 读出的季节偏移在降温侧与实际一致。
	return DCClimateMath.compress_season_cooling(gain * dev * amp)

# ─── Emergent Climate Coupling：UI 用名义季节标签 ────────────────────────
# 仅供选中面板 / HUD 显示，不参与任何物理 pass。返回 {label, transition}：
#   label      ∈ {"Winter", "Spring", "Summer", "Autumn"}（北半球日历语义）
#   transition ∈ [0, 1]，当前 season 已走完的百分比（0 = 季首，1 = 季末）
func nominal_season_label(season_phase: float) -> Dictionary:
	var p: float = fposmod(season_phase, 4.0)
	var idx: int = int(floor(p)) & 3
	var frac: float = p - float(idx)
	var labels: Array[String] = ["Winter", "Spring", "Summer", "Autumn"]
	return {"label": labels[idx], "transition": frac}

# ─── True Insolation-Driven：日历月份 ────────────────────────────────────
# 约定 season_phase = 0 对应年初（北半球冬季），phase=1/2/3 对应年内
# 25%/50%/75% 进度；真实年长来自 WorldClock.days_per_year()。
func month_of_year(season_phase: float) -> Dictionary:
	const MONTH_LENGTHS: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	var days_per_year: int = _calendar_days_per_year()
	var day_of_year: int = _season_phase_to_day_of_year(season_phase, days_per_year)
	var display_days: int = 0
	for ml_display in MONTH_LENGTHS:
		display_days += int(ml_display)
	var calendar_day0: int = clampi(
			int(floor((float(day_of_year) / float(days_per_year)) * float(display_days))),
			0,
			display_days - 1)
	var month: int = 1
	var day_rem: int = calendar_day0
	for i in range(MONTH_LENGTHS.size()):
		var ml: int = int(MONTH_LENGTHS[i])
		if day_rem < ml:
			month = i + 1
			break
		day_rem -= ml
	return {
		"month": month,
		"day_of_month": day_rem + 1,
		"day_of_year": day_of_year + 1,
		"calendar_day_display": calendar_day0 + 1,
		"days_per_year": days_per_year,
	}

# True Insolation-Driven：UI 便利接口。给外部（main.gd 面板）用当前 _last_cfg
# 快速拿到某 cell 的归一化纬度 ny ∈ [0, 1]，0 = 北极 / 0.5 = 赤道 / 1 = 南极。
# 内部仍走 _cube_row_norm；_last_cfg 缺失时返回 0.5（赤道兜底）。
func cell_ny(cell: HexCell) -> float:
	if cell == null or _last_cfg == null:
		return 0.5
	return _cube_row_norm(cell, _last_cfg)

# ─── True Insolation-Driven：本地温度 EMA → 观测月份 ─────────────────────
# 由选中面板使用。用本地温度 30 日 EMA 相对年均 EMA 的偏差，结合当前日历
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
	if _is_annual_log_tick(_wind_heat_call_count):
		print("wind_heat_transport #%d: %dms (cells=%d, phase=%.3f)" % [
			_wind_heat_call_count,
			Time.get_ticks_msec() - t0,
			map.cell_count(),
			season_phase,
		])


func _fallback_wind_air_mass_pass_result(map: MapData, season_phase: float, reason: String) -> Dictionary:
	var t_fb: int = Time.get_ticks_usec()
	_wind_air_mass_pass(map, season_phase)
	var elapsed: float = (Time.get_ticks_usec() - t_fb) / 1000.0
	var result: Dictionary = _make_climate_pass_result("wind_air", true, elapsed, map.cell_count(), 0, map.cell_count(),
			_CLIMATE_PASS_STATUS_DONE, 0, "oneshot_fallback", reason)
	result["path"] = "gdscript"
	return result


func _fallback_wind_surface_pass_result(map: MapData, season_phase: float, reason: String) -> Dictionary:
	var t_fb: int = Time.get_ticks_usec()
	_wind_surface_pass(map, season_phase)
	var elapsed: float = (Time.get_ticks_usec() - t_fb) / 1000.0
	var result: Dictionary = _make_climate_pass_result("wind_surface", true, elapsed, map.cell_count(), 0, map.cell_count(),
			_CLIMATE_PASS_STATUS_DONE, 0, "oneshot_fallback", reason)
	result["path"] = "gdscript"
	return result


func _build_native_wind_baseline(map: MapData) -> PackedFloat32Array:
	var n: int = map.soa_size()
	var cells: Array[HexCell] = map.iter_cells()
	var elev_a: PackedFloat32Array = map.elevation_arr
	var lat_a: PackedFloat32Array = map.cell_lat_norm_arr
	if _gdext_wind_baseline_work_buf.size() != n:
		_gdext_wind_baseline_work_buf.resize(n)
	var baseline: PackedFloat32Array = _gdext_wind_baseline_work_buf
	for i in range(n):
		var ny: float = lat_a[i] if lat_a.size() > i else _cube_row_norm(cells[i], _last_cfg)
		var elev: float = elev_a[i] if elev_a.size() > i else cells[i].elevation
		baseline[i] = _compute_temperature(ny, elev)
	return baseline


func _publish_wind_heat_native_outputs(map: MapData) -> void:
	if _data_core_world == null:
		return
	var n: int = map.soa_size()
	if n <= 0:
		return
	var _cid_temp: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
	var _cid_anom: int = _data_core_world.component_id(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
	if _cid_temp >= 0 and map.temp_arr.size() == n:
		_data_core_world.write_f32_dense(_cid_temp, map.temp_arr)
	if _cid_anom >= 0 and map.air_mass_temp_anomaly_arr.size() == n:
		_data_core_world.write_f32_dense(_cid_anom, map.air_mass_temp_anomaly_arr)
	# A 修复（climate-temp-pingpong-fix-2026-06）：3 条新写权字段定义后，wind_surface 末端
	# 也需要把 baseline / ocean_anom / local_anom 的 GDScript 镜像推回 C++ slot，保持
	# C++ 视角的 SoA 与 GDScript 视角一致。pass_a / ocean_* / pass_b 的 _flush_slot_to_map
	# 已经把 C++ slot 推到 map.* arr；这里走"补救式 push back"，与温度/air_anom 的旧逻辑
	# 等价（idempotent — 若 GDScript 没动 arr 这就是 no-op 拷贝）。
	var _cid_baseline: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP_BASELINE)
	var _cid_oanom: int = _data_core_world.component_id(DCComponentIds.CELL_OCEAN_THERMAL_ANOMALY)
	var _cid_lanom: int = _data_core_world.component_id(DCComponentIds.CELL_LOCAL_THERMAL_ANOMALY)
	if _cid_baseline >= 0 and map.temp_baseline_arr.size() == n:
		_data_core_world.write_f32_dense(_cid_baseline, map.temp_baseline_arr)
	if _cid_oanom >= 0 and map.ocean_thermal_anomaly_arr.size() == n:
		_data_core_world.write_f32_dense(_cid_oanom, map.ocean_thermal_anomaly_arr)
	if _cid_lanom >= 0 and map.local_thermal_anomaly_arr.size() == n:
		_data_core_world.write_f32_dense(_cid_lanom, map.local_thermal_anomaly_arr)


func run_wind_air_mass_pass_native(map: MapData, season_phase: float) -> Dictionary:
	if _last_cfg == null or map == null:
		var result_missing: Dictionary = _make_climate_pass_result("wind_air", true, 0.0, 0, -1, -1,
				_CLIMATE_PASS_STATUS_DONE, 0, "oneshot_noop", "missing_context")
		result_missing["path"] = "noop"
		return result_missing
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("run_wind_air_mass_pass"):
		return _fallback_wind_air_mass_pass_result(map, season_phase, "native_unavailable")
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6 or map.temp_arr.size() < n:
		return _fallback_wind_air_mass_pass_result(map, season_phase, "missing_soa")
	var baseline: PackedFloat32Array = _build_native_wind_baseline(map)
	if _gdext_wind_temp_before_work_buf.size() != n:
		_gdext_wind_temp_before_work_buf.resize(n)
	var temp_before: PackedFloat32Array = _gdext_wind_temp_before_work_buf
	var temp_a: PackedFloat32Array = map.temp_arr
	for i in range(n):
		var t0: float = temp_a[i]
		temp_before[i] = _valid_runtime_temp_or_baseline(t0, baseline[i])
	var knobs: Dictionary = {
		"n_cells": n,
		"advect_steps": max(0, _last_cfg.WIND_HEAT_ADVECT_STEPS),
		"heat_mix": clampf(_last_cfg.WIND_HEAT_MIX, 0.0, 1.0),
		"neighbor_indices": nb_idx,
		"baseline_arr": baseline,
		"temp_before_arr": temp_before,
	}
	# refresh-consolidation-2026-06：climate_daily round 守门员。wind_air 通常无须
	# 真实 refresh —— 它读温度 temp_arr，前序 ocean_land flush 了 ocean_anom 但
	# climate_daily_system 会在跨 pass 边界 mark stale，这里 ensure 时会按需 refresh。
	_ensure_climate_daily_round_slots_fresh()
	var rc: float = float(_data_core_world_ext.run_wind_air_mass_pass(knobs))
	if rc < 0.0:
		return _fallback_wind_air_mass_pass_result(map, season_phase, "native_failed")
	_publish_wind_heat_native_outputs(map)
	var result: Dictionary = _make_climate_pass_result("wind_air", true, rc, n, 0, n,
			_CLIMATE_PASS_STATUS_DONE, 0, "oneshot_native")
	result["path"] = "gdext"
	return result


func run_wind_surface_pass_native(map: MapData, season_phase: float) -> Dictionary:
	if _last_cfg == null or map == null:
		var result_missing: Dictionary = _make_climate_pass_result("wind_surface", true, 0.0, 0, -1, -1,
				_CLIMATE_PASS_STATUS_DONE, 0, "oneshot_noop", "missing_context")
		result_missing["path"] = "noop"
		return result_missing
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("run_wind_surface_pass"):
		return _fallback_wind_surface_pass_result(map, season_phase, "native_unavailable")
	var n: int = map.soa_size()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed()
	if n <= 0 or nb_idx.size() < n * 6 or map.temp_arr.size() < n:
		return _fallback_wind_surface_pass_result(map, season_phase, "missing_soa")
	var baseline: PackedFloat32Array = _build_native_wind_baseline(map)
	var knobs: Dictionary = {
		"n_cells": n,
		"air_leak": float(_last_cfg.AIR_MASS_HEAT_LEAK),
		"neighbor_indices": nb_idx,
		"fallback_baseline_arr": baseline,
	}
	# refresh-consolidation-2026-06：climate_daily round 守门员。wind_surface 通常
	# 跟在 wind_air 之后，仅读 wind_air 写入的 C++ slot（不绕 MapData），故可 skip。
	_ensure_climate_daily_round_slots_fresh()
	var rc: float = float(_data_core_world_ext.run_wind_surface_pass(knobs))
	if rc < 0.0:
		return _fallback_wind_surface_pass_result(map, season_phase, "native_failed")
	_publish_wind_heat_native_outputs(map)
	var result: Dictionary = _make_climate_pass_result("wind_surface", true, rc, n, 0, n,
			_CLIMATE_PASS_STATUS_DONE, 0, "oneshot_native")
	result["path"] = "gdext"
	return result

# 风温耦合的"气团段"——
# 所有 cell 沿 -wind_vector 回溯 advect_steps 步、与上游 cell 温度做 lerp 混合，
# 只写回 cell.air_mass_temp_anomaly；temperature 由紧随其后的 surface pass 注入。
# [perf 2026-05-20] 不再循环 cell.X = setter（每帧 N 次 _dirty_mark_one 风暴），
# 改成累积到 PackedFloat32Array → 末尾 write_f32_dense 一次性 commit + 一次性 mark dirty range。
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
		temp_before[cell] = _valid_runtime_temp_or_baseline(cell.temperature, float(baseline[cell]))
	
	# [perf] 累积输出，循环结束后批量 commit
	var n_cells_air: int = map.iter_cells().size() if map.has_indices() else map.all_cells().size()
	var anom_out_arr: PackedFloat32Array = PackedFloat32Array()
	anom_out_arr.resize(n_cells_air)
	# 默认值：anom=0，temperature 保持原值。
	var iter_cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	for ic in range(n_cells_air):
		anom_out_arr[ic] = 0.0
	
	# climate-loop-closure 修复：直接读 SoA 风场（wind_x_arr/wind_y_arr，与 weather
	# field solver 同源）。此前读 cell.wind_vector facade（经 _world_ext.read_f32），
	# 在 native_environment_runtime 路径下返回 0 → 风温平流整段 no-op（air_mass≡0）。
	var wind_x_arr_air: PackedFloat32Array = map.wind_x_arr
	var wind_y_arr_air: PackedFloat32Array = map.wind_y_arr
	var has_wind_soa_air: bool = wind_x_arr_air.size() == n_cells_air and wind_y_arr_air.size() == n_cells_air
	for cell: HexCell in map.all_cells():
		var ci_air: int = int(cell.index)
		var wind: Vector2
		if has_wind_soa_air and ci_air >= 0 and ci_air < n_cells_air:
			wind = Vector2(wind_x_arr_air[ci_air], wind_y_arr_air[ci_air])
		else:
			wind = cell.wind_vector
		if wind.length_squared() < 1e-6 or advect_steps == 0:
			# anom = 0（默认）；temp 保持原值（默认）
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
		
		var idx_cell: int = int(cell.index)
		if idx_cell >= 0 and idx_cell < n_cells_air:
			anom_out_arr[idx_cell] = temp_mixed - float(baseline[cell])
	
	# climate-loop-closure 修复 v2：直接写 map SoA（property 原地索引，与 weather
	# distribute 的 snowpack 写法同源，recorder/下游已验证可见）。此前 write_f32_dense
	# 在本路径未反映到 map.air_mass_temp_anomaly_arr → air_mass 恒 0。
	var _anom_ok: bool = map.air_mass_temp_anomaly_arr.size() == n_cells_air
	for ic in range(n_cells_air):
		if _anom_ok:
			map.air_mass_temp_anomaly_arr[ic] = anom_out_arr[ic]
		else:
			var cf: HexCell = iter_cells[ic]
			cf.air_mass_temp_anomaly = anom_out_arr[ic]
	# DCWorld view 兜底 push（facade 启用时 map.*_arr 即 view alias，幂等）。
	if _data_core_world != null:
		var _cid_anom_a: int = _data_core_world.component_id(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
		if _cid_anom_a >= 0:
			_data_core_world.write_f32_dense(_cid_anom_a, anom_out_arr)

# 风温耦合的"地表段"——
# 每个 cell 从相邻 cell 收集 air_mass_temp_anomaly，按"邻 cell 的 wind_vector 是否流向本 cell"加权注入。
# 必须在 _wind_air_mass_pass 之后调用——读取的是气团段写完的 anomaly。
# [perf 2026-05-20] 同 _wind_air_mass_pass：循环只累积到 array，末尾 dense 一次性 commit。
func _wind_surface_pass(map: MapData, season_phase: float) -> void:
	# A 修复（climate-temp-pingpong-fix-2026-06）：C++ 路径在此 pass 末端做合成
	# cell_temp = clamp(baseline + ocean_anom + local_anom + air_anom)。GDScript fallback
	# 当前仍按旧"在自身温度上 += 风热 anomaly"的方式实现；fallback 命中率应趋近 0
	# (climate_pass_distribution 显示 path=gdext)。若 fallback 接管率上升，应在此处
	# 调用统一的 `_compose_temp_from_anomalies(map, n)` 写 cell.temperature 与 SoA。
	if _last_cfg == null:
		return
	var air_leak: float = _last_cfg.AIR_MASS_HEAT_LEAK
	
	# baseline 在表面段也需要——用 cell.elevation + _cube_row_norm 重算
	var baseline: Dictionary = {}
	for cell: HexCell in map.all_cells():
		var ny: float = _cube_row_norm(cell, _last_cfg)
		baseline[cell] = _compute_temperature(ny, cell.elevation)
	
	# [perf] 累积 anom + temp 输出
	var iter_cells_s: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells_s: int = iter_cells_s.size()
	var anom_out_s: PackedFloat32Array = PackedFloat32Array()
	var temp_out_s: PackedFloat32Array = PackedFloat32Array()
	anom_out_s.resize(n_cells_s)
	temp_out_s.resize(n_cells_s)
	# 默认值：anom=0；temp 优先保留 air_mass pass 写入 SoA 的最新值。
	for ic in range(n_cells_s):
		var c0: HexCell = iter_cells_s[ic]
		anom_out_s[ic] = 0.0
		temp_out_s[ic] = c0.temperature
	
	# climate-loop-closure 修复：邻居风向同样直接读 SoA（理由见 _wind_air_mass_pass）。
	var wind_x_arr_s: PackedFloat32Array = map.wind_x_arr
	var wind_y_arr_s: PackedFloat32Array = map.wind_y_arr
	var has_wind_soa_s: bool = wind_x_arr_s.size() == n_cells_s and wind_y_arr_s.size() == n_cells_s
	var air_anom_arr_s: PackedFloat32Array = map.air_mass_temp_anomaly_arr
	var temp_arr_s: PackedFloat32Array = map.temp_arr
	var has_air_anom_soa_s: bool = air_anom_arr_s.size() == n_cells_s
	var has_temp_soa_s: bool = temp_arr_s.size() == n_cells_s
	for ic in range(n_cells_s):
		if has_temp_soa_s:
			temp_out_s[ic] = temp_arr_s[ic]
	for cell: HexCell in map.all_cells():
		var self_wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _last_hex_size)
		var weighted_sum: float = 0.0
		var weight_total: float = 0.0
		
		for nb: HexCell in map.get_neighbors(cell):
			if nb == null:
				continue
			var nb_ci: int = int(nb.index)
			var wind_nb: Vector2
			if has_wind_soa_s and nb_ci >= 0 and nb_ci < n_cells_s:
				wind_nb = Vector2(wind_x_arr_s[nb_ci], wind_y_arr_s[nb_ci])
			else:
				wind_nb = nb.wind_vector
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
			
			var nb_anomaly: float = air_anom_arr_s[nb_ci] if has_air_anom_soa_s and nb_ci >= 0 and nb_ci < n_cells_s else nb.air_mass_temp_anomaly
			weighted_sum += nb_anomaly * w_nb
			weight_total += w_nb
		
		var anomaly_in: float = 0.0
		if weight_total > 0.0:
			anomaly_in = (weighted_sum / weight_total) * air_leak
		
		var idx_cell_s: int = int(cell.index)
		if idx_cell_s < 0 or idx_cell_s >= n_cells_s:
			continue
		anom_out_s[idx_cell_s] = anomaly_in
		if absf(anomaly_in) > 1e-5:
			var t_prev: float = _valid_runtime_temp_or_baseline(temp_out_s[idx_cell_s], float(baseline[cell]))
			temp_out_s[idx_cell_s] = clampf(t_prev + anomaly_in, 0.0, 1.0)
	
	# climate-loop-closure 修复 v2：直接写 map SoA（property 原地索引，见 air pass 同注释）。
	var _temp_ok_s: bool = map.temp_arr.size() == n_cells_s
	var _anom_ok_s: bool = map.air_mass_temp_anomaly_arr.size() == n_cells_s
	for ic in range(n_cells_s):
		if _temp_ok_s:
			map.temp_arr[ic] = temp_out_s[ic]
		if _anom_ok_s:
			map.air_mass_temp_anomaly_arr[ic] = anom_out_s[ic]
		if not (_temp_ok_s and _anom_ok_s):
			var cf: HexCell = iter_cells_s[ic]
			cf.temperature = temp_out_s[ic]
			cf.air_mass_temp_anomaly = anom_out_s[ic]
	if _data_core_world != null:
		var _cid_temp_s: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
		var _cid_anom_s: int = _data_core_world.component_id(DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY)
		if _cid_temp_s >= 0:
			_data_core_world.write_f32_dense(_cid_temp_s, temp_out_s)
		if _cid_anom_s >= 0:
			_data_core_world.write_f32_dense(_cid_anom_s, anom_out_s)
	# 旧 B-full Step-2 镜像循环已并入上面的直写（map.air_mass_temp_anomaly_arr 即 SoA）；
	# 保留下方分支仅为兼容 has_soa 校验，但不再做 COW 易脱离的 local-var 镜像。
	if false and map.has_indices() and map.has_soa():
		var soa_air: PackedFloat32Array = map.air_mass_temp_anomaly_arr
		var n_air: int = map.iter_cells().size()
		for i_air in range(n_air):
			soa_air[i_air] = map.cell_at(i_air).air_mass_temp_anomaly


# bake_world 阶段进度信号 forwarder：MapBaker.stage_progress → MapGenerator.bake_progress。
# 详细 stage 含义见 map_baker.gd 顶部 stage_progress 信号注释。
func _on_baker_stage_progress(stage: String, fraction: float) -> void:
	bake_progress.emit(stage, fraction)


# ───────────────────────────────────────────────────────────────────────────
# Async Climate Round — A-B 验证 helper（plan §async-stage-1/2）
# ───────────────────────────────────────────────────────────────────────────
# 调用方式：
#   - 真机/桌面跑游戏后，KEY_B 触发默认 "transp" bench；
#   - 编程接口：_generator.run_async_climate_round_bench("pass_a")
#     pass_name 可选：
#       "transp"  - 验证 transp pure kernel（Stage 1，bit 7）
#       "pass_a"  - 验证 pass_a pure kernel（Stage 2，bit 0）
#
# 验证策略：
#   1) snapshot 当前 sim 状态（被验证 pass 会写的所有字段）
#   2) 跑 sync 路径拿参考输出
#   3) 把状态恢复到 snapshot
#   4) async path: register + set_static_knobs + kick（passes_mask 单 bit）
#   5) busy-wait worker 完成（最多 200ms）
#   6) poll → 比较 async 写回的字段 vs sync 参考
#   7) 把所有字段再次恢复（对调用方透明）
#
# 输出：print A-B report，包括 bit-equal 计数 / max abs diff / worker timing。
func run_async_climate_round_bench(pass_name: String = "transp") -> Dictionary:
	var report: Dictionary = {
		"ok": false,
		"reason": "",
		"pass": pass_name,
	}
	if _data_core_world_ext == null:
		report["reason"] = "DCWorldExt unavailable"
		print("[async/bench] FAIL: ", report["reason"])
		return report
	if not _data_core_world_ext.has_method("async_climate_round_register"):
		report["reason"] = "ext lacks async_climate_round_* methods (rebuild dots_ext)"
		print("[async/bench] FAIL: ", report["reason"])
		return report
	var map: MapData = _sus_map
	if map == null:
		report["reason"] = "_sus_map is null; world not generated yet"
		print("[async/bench] FAIL: ", report["reason"])
		return report
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		report["reason"] = "map.cell_count() <= 0"
		print("[async/bench] FAIL: ", report["reason"])
		return report
	var cp_f5: ClimateProfile = _c()
	if cp_f5 == null:
		report["reason"] = "ClimateProfile null"
		print("[async/bench] FAIL: ", report["reason"])
		return report

	# Bench vs daily round 互斥：临时关 use_climate_round_async，避免 daily round 路径
	# 占用全局 worker，bench 拿到混入 daily-round 结果（pass_a worker_compute_us≈1700 而非 ≈1400 即
	# 是症状）。bench 完恢复原值。
	var _bench_was_async: bool = false
	if "use_climate_round_async" in cp_f5:
		_bench_was_async = bool(cp_f5.use_climate_round_async)
		cp_f5.use_climate_round_async = false
	# 等待当前在跑的 daily round worker 自然结束（最多 200ms）
	var _wait_deadline: int = Time.get_ticks_usec() + 200_000
	while Time.get_ticks_usec() < _wait_deadline:
		var stats: Dictionary = _data_core_world_ext.async_climate_round_stats()
		var pending: bool = bool(stats.get("request_pending", false))
		var ready: bool = bool(stats.get("result_ready", false))
		if not pending and not ready:
			break
		if ready:
			# 把上一次 daily round 残留结果 poll 掉，否则下一次 kick 永远拿到旧值
			_data_core_world_ext.async_climate_round_poll()
			break
		OS.delay_msec(1)

	# 静态 knobs 提前注入（neighbor_indices + donor_table 不变）
	_data_core_world_ext.async_climate_round_register()
	var donor_table: PackedFloat32Array = _build_transpiration_donor_table()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var static_knobs: Dictionary = {
		"n_cells": n_cells,
		"neighbor_indices": nb_idx,
		"donor_table": donor_table,
	}
	_data_core_world_ext.async_climate_round_set_static_knobs(static_knobs)

	# 按 pass 分支
	var bench_result: Dictionary = report
	match pass_name:
		"transp":
			bench_result = _bench_async_transp(map, n_cells, cp_f5, report)
		"pass_a":
			bench_result = _bench_async_pass_a(map, n_cells, cp_f5, report)
		_:
			report["reason"] = "unknown pass_name '%s' (expect 'transp' or 'pass_a')" % pass_name
			print("[async/bench] FAIL: ", report["reason"])
			bench_result = report
	# 恢复 use_climate_round_async flag（bench 入口已临时关掉）
	if "use_climate_round_async" in cp_f5:
		cp_f5.use_climate_round_async = _bench_was_async
	return bench_result


# 兼容旧名（KEY_B 热键调用）
func run_async_climate_round_stage1_bench() -> Dictionary:
	return run_async_climate_round_bench("transp")


# transp pass A-B：验证 moisture 输出 bit-equal sync
func _bench_async_transp(map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	# 1) snapshot moisture
	var moisture_snap: PackedFloat32Array = map.moisture_arr.duplicate()

	# 2) sync 拿参考
	var sync_t0: int = Time.get_ticks_usec()
	var sync_res: Dictionary = run_transpiration_pass_native(map)
	var sync_elapsed_us: int = Time.get_ticks_usec() - sync_t0
	var sync_path: String = str(sync_res.get("path", "?"))
	if sync_path != "gdext":
		report["reason"] = "sync path failed (path=%s)" % sync_path
		print("[async/bench transp] FAIL: ", report["reason"])
		map.moisture_arr = moisture_snap
		if _data_core_world_ext.has_method("refresh_slots_from_map"):
			_data_core_world_ext.refresh_slots_from_map()
		return report
	var ref_moisture: PackedFloat32Array = map.moisture_arr.duplicate()

	# 把 moisture 还原，让 async 跑同一 input
	map.moisture_arr = moisture_snap
	if _data_core_world_ext.has_method("refresh_slots_from_map"):
		_data_core_world_ext.refresh_slots_from_map()

	# 3) async kick（passes_mask=0x80 仅 transp）
	var input: Dictionary = {
		"n_cells": n_cells,
		"passes_mask": 0x80,
		"landform": map.landform_arr,
		"vegetation": map.vegetation_arr,
		"moisture": map.moisture_arr,
		"transp_outflow_rate": float(cp_f5.transpiration_outflow_rate),
		"transp_self_rate": float(cp_f5.transpiration_self_rate),
		"season_phase": 0.0,
	}
	var async_t0: int = Time.get_ticks_usec()
	if not bool(_data_core_world_ext.async_climate_round_kick(input)):
		report["reason"] = "kick returned false"
		print("[async/bench transp] FAIL: ", report["reason"])
		return report

	# 4) busy-wait
	var poll_result: Dictionary = _busy_wait_poll(200_000)
	var async_elapsed_us: int = Time.get_ticks_usec() - async_t0
	if poll_result.is_empty():
		report["reason"] = "worker did not complete within 200ms"
		print("[async/bench transp] FAIL: ", report["reason"])
		return report
	var async_moisture: PackedFloat32Array = map.moisture_arr.duplicate()

	# 5) compare
	var diff: Dictionary = _diff_f32_arrays(ref_moisture, async_moisture, n_cells)

	# 6) 恢复
	map.moisture_arr = moisture_snap
	if _data_core_world_ext.has_method("refresh_slots_from_map"):
		_data_core_world_ext.refresh_slots_from_map()

	# 7) 报告
	report["ok"] = (diff["diff_count"] == 0)
	report["n_cells"] = n_cells
	report["sync_us"] = sync_elapsed_us
	report["async_total_us"] = async_elapsed_us
	report["worker_compute_us"] = int(poll_result.get("worker_compute_us", 0))
	report["transp_us"] = int(poll_result.get("transp_us", 0))
	report["diff_count"] = diff["diff_count"]
	report["max_abs_diff"] = diff["max_abs_diff"]
	report["first_diff_idx"] = diff["first_diff_idx"]
	print("[async/bench transp] === A-B verification ===")
	print("  n_cells=%d  sync_us=%d  async_total_us=%d" % [n_cells, sync_elapsed_us, async_elapsed_us])
	print("  worker_compute_us=%d  transp_us=%d" % [
		int(poll_result.get("worker_compute_us", 0)), int(poll_result.get("transp_us", 0))])
	print("  diff_count=%d  max_abs_diff=%.9f  first_diff_idx=%d" % [
		diff["diff_count"], diff["max_abs_diff"], diff["first_diff_idx"]])
	if report["ok"]:
		print("[async/bench transp] OK ✅ — moisture bit-equal sync")
	else:
		print("[async/bench transp] FAIL ❌")
	return report


# pass_a A-B：验证 16 字段输出 bit-equal sync
func _bench_async_pass_a(map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	# 验证字段列表（与 worker poll 写回的 16 字段一致）。
	# (map_field, dtype) — 用于通用 snapshot/compare/restore
	# Stage 2 范围内只 diff F32 字段；ema_initialized 是 U8，逻辑相同（snapshot+restore）。
	var f32_fields: Array = [
		"moisture_arr", "snow_cover_arr", "temp_baseline_arr", "temp_season_offset_arr",
		"temp_30d_arr", "temp_365d_arr", "temp_anomaly_arr",
		"insolation_now_arr", "insolation_dev_arr", "day_length_arr", "heat_input_arr",
		"thermal_energy_arr", "snowpack_arr",
		"ocean_thermal_anomaly_arr", "local_thermal_anomaly_arr",
	]
	var u8_fields: Array = ["ema_initialized_arr"]

	# 1) snapshot 全部 16 字段
	var snap_f32: Dictionary = {}
	for f in f32_fields:
		snap_f32[f] = (map.get(f) as PackedFloat32Array).duplicate()
	var snap_u8: Dictionary = {}
	for f in u8_fields:
		snap_u8[f] = (map.get(f) as PackedByteArray).duplicate()

	# 2) sync 拿参考输出：直接调 _climate_pass_a（带 refresh + flush）
	var sync_t0: int = Time.get_ticks_usec()
	# season_phase 使用当前 round 锁定值；若 climate_daily round 没在跑，用 world_clock 当前值
	var sp: float = 0.0
	if _world_clock_ref != null and _world_clock_ref.has_method("season_phase"):
		sp = float(_world_clock_ref.season_phase())
	_climate_pass_a(map, sp)
	var sync_elapsed_us: int = Time.get_ticks_usec() - sync_t0
	# 拿 sync 后的 ref values
	var ref_f32: Dictionary = {}
	for f in f32_fields:
		ref_f32[f] = (map.get(f) as PackedFloat32Array).duplicate()
	var ref_u8: Dictionary = {}
	for f in u8_fields:
		ref_u8[f] = (map.get(f) as PackedByteArray).duplicate()

	# 3) 把所有字段恢复 snapshot
	for f in f32_fields:
		map.set(f, (snap_f32[f] as PackedFloat32Array).duplicate())
	for f in u8_fields:
		map.set(f, (snap_u8[f] as PackedByteArray).duplicate())
	if _data_core_world_ext.has_method("refresh_slots_from_map"):
		_data_core_world_ext.refresh_slots_from_map()

	# 4) async kick（passes_mask=0x01 仅 pass_a）+ 完整 pass_a 输入
	var input: Dictionary = {
		"n_cells": n_cells,
		"passes_mask": 0x01,
		# U8 输入
		"is_water": map.is_water_arr,
		"terrain": map.terrain_arr,
		"cover": map.cover_arr,
		"ema_initialized": map.ema_initialized_arr,
		# F32 输入
		"elevation": map.elevation_arr,
		"base_moisture": map.base_moisture_arr,
		"lat_norm": map.cell_lat_norm_arr,
		"temp_baseline_year": map.temp_baseline_year_arr,
		"temp": map.temp_arr,
		"temp_30d": map.temp_30d_arr,
		"temp_365d": map.temp_365d_arr,
		"thermal_energy": map.thermal_energy_arr,
		"snowpack": map.snowpack_arr,
		# scalars - 与 _climate_pass_a 同源
		"season_phase": sp,
		"axial_tilt_deg": float(cp_f5.axial_tilt_deg) if "axial_tilt_deg" in cp_f5 else 23.5,
		"day_length_gain": float(cp_f5.insolation_daylen_amp) if "insolation_daylen_amp" in cp_f5 else 0.35,
		"solar_gain": float(cp_f5.solar_gain) if "solar_gain" in cp_f5 else 1.0,
		"insol_amp": float(cp_f5.season_temp_amp) if "season_temp_amp" in cp_f5 else 0.20,
		"insol_gain": float(cp_f5.insolation_season_gain) if "insolation_season_gain" in cp_f5 else 1.0,
		"moist_scale_now": 1.0,
		"days_per_year": _calendar_days_per_year(),
		"sea_level": float(_last_cfg.sea_level) if _last_cfg != null else 0.5,
		# pass_a 扩展 scalars — mirror sync `_climate_pass_a` 的 cp_struct。
		"thermal_inertia_land": float(cp_f5.thermal_inertia_land) if "thermal_inertia_land" in cp_f5 else 0.35,
		"thermal_inertia_water": float(cp_f5.thermal_inertia_water) if "thermal_inertia_water" in cp_f5 else 0.07,
		"thermal_inertia_snow": float(cp_f5.thermal_inertia_snow) if "thermal_inertia_snow" in cp_f5 else 0.09,
		"thermal_inertia_high_mountain": float(cp_f5.thermal_inertia_high_mountain) if "thermal_inertia_high_mountain" in cp_f5 else 0.16,
		"thermal_daily_delta_cap": float(cp_f5.thermal_daily_delta_cap) if "thermal_daily_delta_cap" in cp_f5 else 0.15,
		"temp_land_continentality": float(cp_f5.temp_land_continentality) if "temp_land_continentality" in cp_f5 else 1.55,
		"thermal_dt_days": _consume_climate_dt_days(),
		"snowpack_cover_low": float(cp_f5.snowpack_cover_low) if "snowpack_cover_low" in cp_f5 else 0.05,
		"snowpack_cover_full": float(cp_f5.snowpack_cover_full) if "snowpack_cover_full" in cp_f5 else 0.32,
		"insol_dev_min": float(cp_f5.insolation_dev_clamp_min) if "insolation_dev_clamp_min" in cp_f5 else -1.0,
		"insol_dev_max": float(cp_f5.insolation_dev_clamp_max) if "insolation_dev_clamp_max" in cp_f5 else 1.0,
	}
	var async_t0: int = Time.get_ticks_usec()
	if not bool(_data_core_world_ext.async_climate_round_kick(input)):
		report["reason"] = "kick returned false"
		print("[async/bench pass_a] FAIL: ", report["reason"])
		return report

	# 5) busy-wait
	var poll_result: Dictionary = _busy_wait_poll(200_000)
	var async_elapsed_us: int = Time.get_ticks_usec() - async_t0
	if poll_result.is_empty():
		report["reason"] = "worker did not complete within 200ms"
		print("[async/bench pass_a] FAIL: ", report["reason"])
		return report

	# 6) compare each F32 field
	var total_diff_count: int = 0
	var worst_field: String = ""
	var worst_max_diff: float = 0.0
	var field_diffs: Dictionary = {}
	for f in f32_fields:
		var ref_a: PackedFloat32Array = ref_f32[f]
		var async_a: PackedFloat32Array = map.get(f) as PackedFloat32Array
		var d: Dictionary = _diff_f32_arrays(ref_a, async_a, n_cells)
		field_diffs[f] = d
		total_diff_count += int(d["diff_count"])
		if float(d["max_abs_diff"]) > worst_max_diff:
			worst_max_diff = float(d["max_abs_diff"])
			worst_field = f

	# u8 field diff (ema_initialized)
	var u8_diff_count: int = 0
	for f in u8_fields:
		var ref_a: PackedByteArray = ref_u8[f]
		var async_a: PackedByteArray = map.get(f) as PackedByteArray
		for i in range(n_cells):
			var r: int = ref_a[i] if i < ref_a.size() else 0
			var a: int = async_a[i] if i < async_a.size() else 0
			if r != a:
				u8_diff_count += 1

	# 7) 恢复 sim 状态
	for f in f32_fields:
		map.set(f, (snap_f32[f] as PackedFloat32Array).duplicate())
	for f in u8_fields:
		map.set(f, (snap_u8[f] as PackedByteArray).duplicate())
	if _data_core_world_ext.has_method("refresh_slots_from_map"):
		_data_core_world_ext.refresh_slots_from_map()

	# 8) 报告
	report["ok"] = (total_diff_count == 0 and u8_diff_count == 0)
	report["n_cells"] = n_cells
	report["sync_us"] = sync_elapsed_us
	report["async_total_us"] = async_elapsed_us
	report["worker_compute_us"] = int(poll_result.get("worker_compute_us", 0))
	report["pass_a_us"] = int(poll_result.get("pass_a_us", 0))
	report["total_diff_count_f32"] = total_diff_count
	report["total_diff_count_u8"] = u8_diff_count
	report["worst_field"] = worst_field
	report["worst_max_abs_diff"] = worst_max_diff
	report["field_diffs"] = field_diffs

	print("[async/bench pass_a] === A-B verification ===")
	print("  n_cells=%d  sync_us=%d  async_total_us=%d" % [n_cells, sync_elapsed_us, async_elapsed_us])
	print("  worker_compute_us=%d  pass_a_us=%d" % [
		int(poll_result.get("worker_compute_us", 0)), int(poll_result.get("pass_a_us", 0))])
	print("  total_diff_count_f32=%d  total_diff_count_u8=%d" % [total_diff_count, u8_diff_count])
	print("  worst_field=%s  worst_max_abs_diff=%.9f" % [worst_field, worst_max_diff])
	if total_diff_count > 0:
		# 打印每个有差异的字段细节
		for f in f32_fields:
			var d: Dictionary = field_diffs[f]
			if int(d["diff_count"]) > 0:
				print("    [%s] diff=%d max=%.9f first_idx=%d" % [
					f, int(d["diff_count"]), float(d["max_abs_diff"]), int(d["first_diff_idx"])])
	if report["ok"]:
		print("[async/bench pass_a] OK ✅ — 16 fields all bit-equal sync")
	else:
		print("[async/bench pass_a] FAIL ❌")
	return report


# busy-wait poll worker 结果，最多 timeout_us 微秒
func _busy_wait_poll(timeout_us: int) -> Dictionary:
	var poll_result: Dictionary = {}
	var deadline_us: int = Time.get_ticks_usec() + timeout_us
	while Time.get_ticks_usec() < deadline_us:
		poll_result = _data_core_world_ext.async_climate_round_poll()
		if not poll_result.is_empty():
			break
		OS.delay_msec(1)
	return poll_result


# 比较两个 PackedFloat32Array，返回 {diff_count, max_abs_diff, first_diff_idx}
func _diff_f32_arrays(a: PackedFloat32Array, b: PackedFloat32Array, n: int) -> Dictionary:
	var diff_count: int = 0
	var max_abs_diff: float = 0.0
	var first_diff_idx: int = -1
	for i in range(n):
		var av: float = a[i] if i < a.size() else 0.0
		var bv: float = b[i] if i < b.size() else 0.0
		var d: float = absf(av - bv)
		if d > max_abs_diff:
			max_abs_diff = d
		if d > 0.0:
			if first_diff_idx < 0:
				first_diff_idx = i
			diff_count += 1
	return {
		"diff_count": diff_count,
		"max_abs_diff": max_abs_diff,
		"first_diff_idx": first_diff_idx,
	}
