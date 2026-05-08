# main.gd
# 程序入口：生成地图并通过 HexRenderer 显示，提供顶部 UI 控制重新生成
# 控制：
#   右键拖拽 — 平移
#   滚轮     — 缩放
#   F        — 适配视口
#   R        — 用新随机种子重新生成
#   Space    — 暂停/继续游戏内时间

extends Node2D

@export var map_width: int = 60
@export var map_height: int = 40
@export var num_continents: int = 2
@export var sea_level: float = 0.42
@export var river_count: int = 8
@export var hex_size: float = 22.0
@export var initial_seed: int = 0   # 0 = 随机

# ─── Visual Presentation Overhaul（任务 1）：视觉总开关 ─────────────────
# 六个开关一起组成"可回退的分层视觉系统"：任何一项关闭都应退化到对应基线效果。
# 这里只存储值 + 在生成/信号触发时推给 renderer / weather_layer；具体 shader
# 分支由后续任务 3~9 接入。
@export_group("Visual Overhaul")
@export_range(0, 2, 1) var visual_quality: int = 2
@export var day_night_enabled: bool = true
@export var water_effect_enabled: bool = true
@export var ocean_current_enabled: bool = true
@export var extreme_weather_ground_effect_enabled: bool = true
# 性能采样日志开关：true 时 HexRenderer 内的 PerfSampler 会每 30 秒打印一次
# 平均帧时间 + P95，方便基线 / 优化前 / 优化后三次对齐。
@export var perf_sampler_enabled: bool = false

# ─── Visual Pass 2：TOD 全局光照中枢参数 ───────────────────────────────
# 本组 @export 只注入给 TODProfile（唯一光照数据源）；shader / renderer 不
# 直接读这些值，而是通过 TODProfile.tod_changed 信号拿到 sun_color 等字段。
@export_group("TOD (Pass 2)")
# 白天占全天的比例；0.65 时围绕 0=日出、0.25=正午、0.5=日落展开（需求 2.1）
@export_range(0.2, 0.9, 0.01) var daylight_ratio: float = 0.65
# 夜晚 night_factor 下限，数值越小夜晚越黑；<0.35 时会在日志中警告（需求 2.6）
@export_range(0.0, 1.0, 0.01) var night_factor_min: float = 0.55
# 夜晚 night_factor 上限（午夜峰值）
@export_range(0.0, 1.0, 0.01) var night_factor_max: float = 0.72
# 全局曝光（地表+云层+粒子统一生效）
@export_range(0.2, 2.5, 0.01) var tod_exposure: float = 1.0
# 水面粼光开关（任务 4 消费）
@export var water_sparkle_enabled: bool = true
# 雨雪粒子密度提升（任务 5 消费）
@export var rain_density_boost_enabled: bool = true
# 云层 TOD 染色（任务 6 消费，关闭后云层回到上一轮的 day_phase 色温逻辑）
@export var cloud_tod_tint_enabled: bool = true

# ─── Water Visual Overhaul（本轮）：水体细分开关与参数 ──────────────────
# 这些字段由 _push_visual_toggles 一次性推给 HexRenderer，再由 renderer 的
# setter 写到 shader 同名 uniform。默认全开，visual_quality==0 时由 renderer
# 侧或 shader 内部做降级：低画质优先保留水色渐变和边界柔化，跳过高成本动态细节。
@export_group("Water Overhaul")
@export var water_waves_enabled: bool = true
@export var water_fresnel_enabled: bool = true
@export var river_flow_enabled: bool = true
@export var caustics_enabled: bool = true
@export var shallow_transparency_enabled: bool = true
@export_range(4.0, 128.0, 0.5) var water_gloss: float = 34.0
@export_range(0.0, 1.0, 0.01) var water_reflection_strength: float = 0.32
@export_range(0.0, 4.0, 0.05) var river_flow_speed: float = 0.75
@export_range(0.02, 1.0, 0.01) var river_flow_freq: float = 0.16
@export_range(0.0, 1.0, 0.01) var caustics_strength: float = 0.32
@export_range(0.5, 3.0, 0.05) var deep_ocean_contrast: float = 0.96
@export var lake_water_color: Color = Color(0.20, 0.48, 0.56)
@export_range(0.0, 1.0, 0.01) var shallow_transparency_factor: float = 0.56
# ShaderToy 启发：软边过渡 + 柔和噪声层
# 注：`water_wave_line_strength` 在 Water Calm Noise 改造后语义变为
#      "柔和噪声总开关/强度"（0 = 关，1 = 默认柔和层）。默认值刻意低于 1，
#      避免水面重新出现密集条纹或高对比噪声。
@export_range(0.0, 4.0, 0.05) var water_domain_warp_strength: float = 1.45
@export_range(0.0, 1.0, 0.01) var water_wave_line_strength: float = 0.70
@export_range(0.0, 1.0, 0.01) var water_calm_noise_brightness: float = 0.70
@export_range(0.0, 1.0, 0.01) var water_calm_noise_tint_strength: float = 0.70
@export_range(0.0, 4.0, 0.05) var water_biome_blend_radius: float = 3.15
@export_range(0.0, 1.0, 0.01) var water_cartoon_color_strength: float = 0.75
@export_range(0.0, 1.0, 0.01) var water_transition_softness: float = 1.0
@export_range(0.0, 1.0, 0.01) var estuary_plume_strength: float = 0.65

@onready var _renderer: HexRenderer = $WorldRoot/HexRenderer
@onready var _camera: MapCamera = $MapCamera
@onready var _info_label: Label = $UI/TopBar/HBox/InfoLabel
@onready var _time_label: Label = $UI/TopBar/HBox/TimeLabel
@onready var _climate_label: Label = $UI/TopBar/HBox/ClimateLabel
@onready var _pause_btn: Button = $UI/TopBar/HBox/PauseBtn
@onready var _x1_btn: Button = $UI/TopBar/HBox/X1Btn
@onready var _x5_btn: Button = $UI/TopBar/HBox/X5Btn
@onready var _x20_btn: Button = $UI/TopBar/HBox/X20Btn
@onready var _world_clock: WorldClock = $WorldClock

# Pass 2：TOD 中枢（纯脚本对象，非场景节点）。启动时实例化一次，
# 之后随 WorldClock.day_phase_changed 推动 recompute。
var _tod_profile: TODProfile = null

# 地块信息面板（右侧）— 由 _select_cell / _refresh_info_panel 维护
@onready var _highlight: CellHighlight = $WorldRoot/CellHighlight
@onready var _right_panel: PanelContainer = $UI/RightPanel
@onready var _close_btn: Button = $UI/RightPanel/Margin/VBox/Header/CloseBtn
@onready var _pos_label: Label = $UI/RightPanel/Margin/VBox/PosLabel
@onready var _elev_label: Label = $UI/RightPanel/Margin/VBox/ElevLabel
@onready var _climate_zone_label: Label = $UI/RightPanel/Margin/VBox/ClimateZoneLabel
@onready var _temp_label: Label = $UI/RightPanel/Margin/VBox/TempLabel
@onready var _moist_label: Label = $UI/RightPanel/Margin/VBox/MoistLabel
@onready var _precip_label: Label = $UI/RightPanel/Margin/VBox/PrecipLabel
@onready var _landform_label: Label = $UI/RightPanel/Margin/VBox/LandformLabel
@onready var _vegetation_label: Label = $UI/RightPanel/Margin/VBox/VegetationLabel
# Milestone 4：植被生命值（演替倒计时与气候适应度的可视化）
@onready var _vitality_label: Label = $UI/RightPanel/Margin/VBox/VitalityLabel
@onready var _cover_label: Label = $UI/RightPanel/Margin/VBox/CoverLabel
# Milestone 3：天气子系统在 panel 上的展示行（CLEAR 时隐藏强度数字）
@onready var _weather_label: Label = $UI/RightPanel/Margin/VBox/WeatherLabel
@onready var _feature_label: Label = $UI/RightPanel/Margin/VBox/FeatureLabel
@onready var _mobility_label: Label = $UI/RightPanel/Margin/VBox/MobilityLabel
@onready var _history_label: Label = $UI/RightPanel/Margin/VBox/HistoryLabel

var _current_map: MapData = null
var _generator: MapGenerator = null
var _world_data: WorldData = null
var _last_seed: int = 0
var _last_time_label_hour: int = -1
# 当前选中地块（重新生成地图时清空，避免持有旧 MapData 的 cell 引用）
var _selected_cell: HexCell = null

func _ready() -> void:
	_wire_time_ui()
	_close_btn.pressed.connect(_clear_selection)
	# Pass 2：TOD 中枢必须在 _generate_and_render 前实例化，
	# 因为首次 set_map 会触发 _push_visual_toggles → apply_tod 首帧推送。
	_init_tod_profile()
	_generate_and_render(initial_seed)
	# 把时钟信号接到 renderer + UI（在第一次生成完成后）
	_world_clock.day_changed.connect(_on_day_changed)
	_world_clock.season_changed.connect(_on_season_changed)
	_world_clock.year_changed.connect(_on_year_changed)
	# 任务 2：昼夜相位节流信号，驱动 shader + 刷 UI 小时位
	_world_clock.day_phase_changed.connect(_on_day_phase_changed)
	_refresh_time_label()
	# 任务 1：把 @export 的视觉总开关推送给 renderer / weather_layer 一次
	_push_visual_toggles()
	# Pass 2：启动时显式推一次 TOD，保证 shader 的 tod_* uniform 不为 0
	_recompute_and_push_tod(_world_clock.day_phase())

# 左键点击选中地块。RightPanel.mouse_filter=STOP 已确保面板内的点击
# 不会到这里，所以无需手动判断光标是否落在 UI 上。
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if _current_map == null:
		return
	var world_pos := get_global_mouse_position()
	var cube := HexUtils.world_to_cube(world_pos, hex_size)
	var cell := _current_map.get_cell_by_cube(cube)
	if cell == null:
		return
	_select_cell(cell)

func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			_generate_and_render(0)
		KEY_F:
			_camera.fit_to_viewport()
		KEY_SPACE:
			_world_clock.toggle_pause()
			_sync_pause_btn()
			_sync_clock_running_to_weather_layer()
		KEY_F6:
			# 任务 9：切换 ocean_current_debug uniform（高/低对比流线）
			if _renderer != null and _renderer.has_method("set_ocean_current_debug"):
				var cur: bool = _renderer.get_ocean_current_debug()
				_renderer.set_ocean_current_debug(not cur)
				print("[VisualOverhaul] ocean_current_debug = %s" % str(not cur))

# ─── 时间 UI 绑定 ───────────────────────────────────────────────────────

func _wire_time_ui() -> void:
	_pause_btn.toggled.connect(_on_pause_toggled)
	_x1_btn.pressed.connect(func() -> void: _set_speed(1.0))
	_x5_btn.pressed.connect(func() -> void: _set_speed(5.0))
	_x20_btn.pressed.connect(func() -> void: _set_speed(20.0))

func _on_pause_toggled(pressed: bool) -> void:
	_world_clock.pause(pressed)
	_sync_clock_running_to_weather_layer()

func _sync_pause_btn() -> void:
	_pause_btn.set_pressed_no_signal(_world_clock.paused)

func _set_speed(s: float) -> void:
	_world_clock.set_speed(s)
	_world_clock.pause(false)
	_sync_pause_btn()
	_sync_clock_running_to_weather_layer()

# 任务 5：把 WorldClock.paused 状态转发给 WeatherLayer，让粒子/噪声同步暂停
# （只影响表现层时间累加，粒子引擎本身仍可继续渲染已生成的粒子——避免完全定格）
func _sync_clock_running_to_weather_layer() -> void:
	if _renderer == null:
		return
	var wl = _renderer.get_node_or_null("WeatherLayer")
	if wl != null and wl.has_method("set_clock_running"):
		wl.set_clock_running(not _world_clock.paused)

# ─── WorldClock 信号回调 ─────────────────────────────────────────────────

func _on_day_changed(_day_idx: int) -> void:
	_refresh_time_label()
	# Phase 1：每"日"刷新一次 shader 季节相位
	if _renderer != null:
		_renderer.set_season_phase(_world_clock.season_phase())
		_renderer.set_climate_anomaly(_world_clock.climate_anomaly)
	# Milestone 3：每日推进天气子系统 → 上传 fronts 到 renderer → 刷面板
	if _generator != null and _current_map != null and _world_data != null and _world_clock != null:
		var fronts := _generator.refresh_daily(
			_current_map, _world_data,
			_world_clock.season_index(),
			_world_clock.climate_anomaly
		)
		if _renderer != null:
			_renderer.set_weather_fronts(fronts)
		# 选中地块的 weather + vitality 跟着每日推进刷新
		# （不刷整张面板，仅刷两行避免抖动；演替发生时整张面板会在下次 _refresh_info_panel 同步）
		if _selected_cell != null:
			_refresh_weather_line()
			_refresh_vitality_line()

func _on_season_changed(_season_idx: int) -> void:
	_refresh_time_label()
	# Phase 2：每"季"重跑湿度/雨影 → 局部 biome 重决策 → 重烘焙 biome_tex
	if _generator != null and _current_map != null and _world_data != null:
		var t0 := Time.get_ticks_msec()
		_generator.refresh_seasonal(_current_map, _world_data, _season_idx)
		# 上传新 biome_tex（generator 内部已写到 world_data.biome_tex）
		_renderer.set_map(_current_map, _world_data)
		print("Season refresh %dms" % (Time.get_ticks_msec() - t0))
	# 季节切换后 current_state 已更新，刷新当前选中地块的面板
	if _selected_cell != null:
		_refresh_info_panel()

func _on_year_changed(_year_idx: int) -> void:
	_refresh_time_label()
	_refresh_climate_label()
	# Phase 8：年度生态漂移（base_moisture 缓慢演化，长期 FOREST → +，长期 DESERT → -）
	if _generator != null and _current_map != null and _world_data != null:
		var t0 := Time.get_ticks_msec()
		_generator.refresh_yearly(_current_map, _world_data)
		print("Yearly refresh %dms" % (Time.get_ticks_msec() - t0))
	# base_moisture 漂移后 climate_anomaly 也变了，刷新面板让玩家看到长期生态变化
	if _selected_cell != null:
		_refresh_info_panel()

# 任务 2：昼夜相位回调。把值转发给 renderer，并以逐帧 TOD 保证视觉平滑；
# UI 小时位仅在显示小时变化时刷新，避免每帧重写 Label。
func _on_day_phase_changed(day_phase: float) -> void:
	if _renderer != null:
		_renderer.set_day_phase(day_phase)
	# Pass 2：同步重算 TOD 并广播给所有消费者
	_recompute_and_push_tod(day_phase)
	if _world_clock != null:
		var h := _world_clock.hour_of_day()
		if h != _last_time_label_hour:
			_refresh_time_label()

func _refresh_time_label() -> void:
	if _world_clock == null or _time_label == null:
		return
	var y := _world_clock.year_index()
	var d := _world_clock.day_in_year()
	var s := _world_clock.season_index()
	# 任务 2：扩展为 "Y%d D%d %s %02d:00" 包含当前小时位
	var h := _world_clock.hour_of_day()
	_last_time_label_hour = h
	_time_label.text = "Y%d D%d %s %02d:00" % [y, d, _world_clock.season_name(s), h]

func _refresh_climate_label() -> void:
	if _world_clock == null or _climate_label == null:
		return
	var v := _world_clock.climate_anomaly
	_climate_label.text = "Climate %s%.2f" % ["+" if v >= 0.0 else "", v]

# ─── 主生成流程 ──────────────────────────────────────────────────────────

func _generate_and_render(seed_val: int) -> void:
	# 重新生成会替换 MapData，旧的 _selected_cell 引用立即失效，必须先清掉
	_clear_selection()

	var cfg := MapConfig.make(map_width, map_height)
	cfg.num_continents = num_continents
	cfg.sea_level = sea_level
	cfg.river_count = river_count
	cfg.seed = seed_val

	var t0: int = Time.get_ticks_msec()
	_generator = MapGenerator.new()
	var result := _generator.generate(cfg, hex_size)
	_current_map = result["map"]
	_world_data = result["world_data"]
	_last_seed = result.get("seed", seed_val)
	var elapsed: int = Time.get_ticks_msec() - t0

	_renderer.hex_size = hex_size
	_renderer.set_map(_current_map, _world_data)

	# 把当前时间状态先推一次给 renderer，避免新生成的地图用着旧的 season_phase
	if _world_clock != null:
		_renderer.set_season_phase(_world_clock.season_phase())
		_renderer.set_climate_anomaly(_world_clock.climate_anomaly)
		# 任务 2：新地图生成后立即把 day_phase 还原到 shader
		_renderer.set_day_phase(_world_clock.day_phase())

	_camera.set_world_bounds(_renderer.get_world_bounds())
	_camera.fit_to_viewport(1.05)

	if _info_label != null:
		var stats := _current_map.terrain_stats()
		_info_label.text = "%dx%d  cells=%d  bake=%dms  [R] regenerate  [F] fit  [Space] pause" % [
			cfg.width, cfg.height, _current_map.cell_count(), elapsed
		]
		print("=== World baked in %dms ===" % elapsed)
		for t in stats:
			print("  %s: %d" % [TerrainType.terrain_name(t), stats[t]])

	# 任务 1：重新生成地图后，再把视觉总开关刷一次（renderer 的材质可能被重建）
	_push_visual_toggles()

# ─── 任务 1：视觉总开关推送 ─────────────────────────────────────────────
# 把六个 @export 开关一次性推到 HexRenderer / WeatherLayer。
# 开关 → 具体 shader 分支的绑定由后续任务消费这些 setter 完成。
func _push_visual_toggles() -> void:
	if _renderer != null:
		_renderer.set_visual_quality(visual_quality)
		_renderer.set_day_night_enabled(day_night_enabled)
		_renderer.set_water_effect_enabled(water_effect_enabled)
		_renderer.set_ocean_current_enabled(ocean_current_enabled)
		_renderer.set_extreme_weather_ground_effect_enabled(
			extreme_weather_ground_effect_enabled
		)
		_renderer.set_perf_sampler_enabled(perf_sampler_enabled)
		# Pass 2：把 Pass 2 的三个模块开关也一次性推下去
		if _renderer.has_method("set_water_sparkle_enabled"):
			_renderer.set_water_sparkle_enabled(water_sparkle_enabled)
		if _renderer.has_method("set_rain_density_boost_enabled"):
			_renderer.set_rain_density_boost_enabled(rain_density_boost_enabled)
		if _renderer.has_method("set_cloud_tod_tint_enabled"):
			_renderer.set_cloud_tod_tint_enabled(cloud_tod_tint_enabled)

		# Water Visual Overhaul：把本轮的 13 个参数 + 5 个子开关一起推下去。
		# visual_quality==0 时，各子特性由 renderer/shader 内部做降级，不在这里改值。
		if _renderer.has_method("set_water_waves_enabled"):
			_renderer.set_water_waves_enabled(water_waves_enabled)
		if _renderer.has_method("set_water_fresnel_enabled"):
			_renderer.set_water_fresnel_enabled(water_fresnel_enabled)
		if _renderer.has_method("set_river_flow_enabled"):
			_renderer.set_river_flow_enabled(river_flow_enabled)
		if _renderer.has_method("set_caustics_enabled"):
			_renderer.set_caustics_enabled(caustics_enabled)
		if _renderer.has_method("set_shallow_transparency_enabled"):
			_renderer.set_shallow_transparency_enabled(shallow_transparency_enabled)
		if _renderer.has_method("set_water_gloss"):
			_renderer.set_water_gloss(water_gloss)
		if _renderer.has_method("set_water_reflection_strength"):
			_renderer.set_water_reflection_strength(water_reflection_strength)
		if _renderer.has_method("set_river_flow_speed"):
			_renderer.set_river_flow_speed(river_flow_speed)
		if _renderer.has_method("set_river_flow_freq"):
			_renderer.set_river_flow_freq(river_flow_freq)
		if _renderer.has_method("set_caustics_strength"):
			_renderer.set_caustics_strength(caustics_strength)
		if _renderer.has_method("set_deep_ocean_contrast"):
			_renderer.set_deep_ocean_contrast(deep_ocean_contrast)
		if _renderer.has_method("set_lake_water_color"):
			_renderer.set_lake_water_color(lake_water_color)
		if _renderer.has_method("set_shallow_transparency_factor"):
			_renderer.set_shallow_transparency_factor(shallow_transparency_factor)
		if _renderer.has_method("set_water_domain_warp_strength"):
			_renderer.set_water_domain_warp_strength(water_domain_warp_strength)
		if _renderer.has_method("set_water_wave_line_strength"):
			_renderer.set_water_wave_line_strength(water_wave_line_strength)
		if _renderer.has_method("set_water_calm_noise_brightness"):
			_renderer.set_water_calm_noise_brightness(water_calm_noise_brightness)
		if _renderer.has_method("set_water_calm_noise_tint_strength"):
			_renderer.set_water_calm_noise_tint_strength(water_calm_noise_tint_strength)
		if _renderer.has_method("set_water_biome_blend_radius"):
			_renderer.set_water_biome_blend_radius(water_biome_blend_radius)
		if _renderer.has_method("set_water_cartoon_color_strength"):
			_renderer.set_water_cartoon_color_strength(water_cartoon_color_strength)
		if _renderer.has_method("set_water_transition_softness"):
			_renderer.set_water_transition_softness(water_transition_softness)
		if _renderer.has_method("set_estuary_plume_strength"):
			_renderer.set_estuary_plume_strength(estuary_plume_strength)

# ─── Pass 2：TOD 中枢初始化与广播 ─────────────────────────────────────
# 唯一一处构造 TODProfile 的地方。@export 参数校验：night_factor_min <0.35
# 时（过黑）在日志里 push_warning，避免用户无意退回上一轮过暗模式（需求 2.6）。
func _init_tod_profile() -> void:
	_tod_profile = TODProfile.new()
	_tod_profile.configure(
		daylight_ratio, night_factor_min, night_factor_max, tod_exposure
	)
	if night_factor_min < 0.35:
		push_warning(
			"[TOD] night_factor_min=%.2f < 0.35：夜晚可能过暗无法操作" % night_factor_min
		)

# 按当前 day_phase 重算 TOD 并广播给 renderer / weather_layer。
# 被 _on_day_phase_changed 和 _ready 初始化阶段各调用一次。
func _recompute_and_push_tod(day_phase: float) -> void:
	if _tod_profile == null:
		return
	_tod_profile.recompute(day_phase, day_night_enabled)
	if _renderer != null and _renderer.has_method("apply_tod"):
		_renderer.apply_tod(_tod_profile)

# ─── 地块选择 / 信息面板 ─────────────────────────────────────────────────

func _select_cell(cell: HexCell) -> void:
	_selected_cell = cell
	_highlight.set_cell(cell, hex_size)
	_right_panel.visible = true
	_refresh_info_panel()

func _clear_selection() -> void:
	_selected_cell = null
	if _highlight != null:
		_highlight.clear()
	if _right_panel != null:
		_right_panel.visible = false

# 把当前 _selected_cell 的所有信息写到右侧面板。
# 字段全部从 cell 现成属性 + WorldClock + MapGenerator 派生，不引入新数据存储。
func _refresh_info_panel() -> void:
	if _selected_cell == null or _right_panel == null or _current_map == null:
		return
	var cell := _selected_cell
	var cfg_h: int = max(_current_map.height, 1)

	# ── 位置（cube + offset）
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	_pos_label.text = "位置：cube(%d,%d,%d)  offset(col=%d,row=%d)" % [
		cell.q, cell.r, cell.s, off.x, off.y
	]

	# ── 海拔（归一化 + 陆上海拔比例 + 文字档位）
	var sea: float = sea_level
	var land_h: float = (cell.elevation - sea) / maxf(1.0 - sea, 0.001)
	_elev_label.text = "海拔：%.3f（%s）   陆上高度：%+.2f" % [
		cell.elevation, _elevation_band(cell.elevation, sea), land_h
	]

	# ── 气候带（按纬度 |ny - 0.5| 推导）
	var ny: float = float(off.y) / float(cfg_h - 1) if cfg_h > 1 else 0.5
	var anomaly: float = _world_clock.climate_anomaly if _world_clock != null else 0.0
	_climate_zone_label.text = "气候带：%s（纬度 %.2f）   气候异常：%+.2f" % [
		_climate_zone_name(ny), ny, anomaly
	]

	# ── 当前温度（来自 current_state）
	var cs: Dictionary = cell.current_state
	var temp: float = float(cs.get("temperature", 0.0))
	_temp_label.text = "当前温度：%.2f（%s）" % [temp, _temperature_band(temp)]

	# ── 当前湿度（cell.current_state） + 年均基线对照
	var moist: float = float(cs.get("moisture", cell.moisture))
	_moist_label.text = "当前湿度：%.2f（%s）   年均基线：%.2f" % [
		moist, _moisture_band(moist), cell.base_moisture
	]

	# ── 当季降水（派生估算：SEASONAL_MOISTURE_SCALE[season] × base_moisture）
	var fallback_season: int = _world_clock.season_index() if _world_clock != null else 1
	var season: int = int(cs.get("season", fallback_season))
	var scale_arr: Array[float] = _generator._c().seasonal_moisture_scale if _generator != null else ([1.0, 1.0, 1.0, 1.0] as Array[float])
	var scale: float = scale_arr[season] if season >= 0 and season < scale_arr.size() else 1.0
	var precip: float = scale * cell.base_moisture
	_precip_label.text = "当季降水：%.2f（估算 = %s ×%.2f × 年均湿度 %.2f）" % [
		precip, _world_clock.season_name_cn(season), scale, cell.base_moisture
	]

	# ── Milestone 1：三轴分栏（地形 / 植被 / 覆盖）
	# 地形：仅描述海拔/海陆几何，不含植被语义（HILL 上面会有真实植被）
	_landform_label.text = "地形：%s" % LandformType.name_cn(cell.landform)
	# 植被：独立轴；与年均基线不同则提示"当季已演替"
	var veg_now := VegetationType.name_cn(cell.vegetation)
	if cell.vegetation != cell.base_vegetation:
		var veg_base := VegetationType.name_cn(cell.base_vegetation)
		_vegetation_label.text = "植被：%s   ⚠ 当季已演替（基线：%s）" % [veg_now, veg_base]
	else:
		_vegetation_label.text = "植被：%s" % veg_now
	# Milestone 4：植被生命值 + 演替倒计时
	_refresh_vitality_line()
	# 覆盖：临时/永久覆盖物 + 当前 snow_cover 百分比
	var snow_pct: float = float(cs.get("snow_cover", 0.0)) * 100.0
	if snow_pct > 1.0:
		_cover_label.text = "覆盖：%s（雪盖 %.0f%%）" % [CoverType.name_cn(cell.cover), snow_pct]
	else:
		_cover_label.text = "覆盖：%s" % CoverType.name_cn(cell.cover)

	# Milestone 3：天气（每"日"由 weather 子系统更新；CLEAR 时不显示强度）
	_refresh_weather_line()

	# ── 地理特征（河流 / 火山 / 湖泊种子）—— 雪盖已迁到 CoverLabel 不再重复
	var feats := PackedStringArray()
	if cell.has_river: feats.append("河流")
	if cell.has_volcano: feats.append("火山")
	if cell.is_lake_seed: feats.append("湖泊种子")
	_feature_label.text = "地理特征：%s" % ("无" if feats.is_empty() else ", ".join(feats))

	# ── 通行（基础通行 + 当季通行）
	_mobility_label.text = "通行：陆 %s / 海 %s   move_cost=%d   当季可通行：%s" % [
		"是" if cell.passable_land else "否",
		"是" if cell.passable_sea else "否",
		TerrainType.get_move_cost(cell.terrain),
		"是" if cell.is_passable_in_season(season) else "否",
	]

	# ── 近期植被演替（vegetation_history 环形缓冲，最近 8 季）
	# Milestone 1：换源到独立植被轴，粒度更细；空缓冲时回退到 biome_history
	var veg_history := cell.vegetation_history
	if not veg_history.is_empty():
		var names := PackedStringArray()
		for i in range(veg_history.size()):
			names.append(VegetationType.name_cn(int(veg_history[i])))
		_history_label.text = "近期植被：%s" % " → ".join(names)
	else:
		var bio_history := cell.biome_history
		if bio_history.is_empty():
			_history_label.text = "近期植被：尚无记录"
		else:
			var names2 := PackedStringArray()
			for i in range(bio_history.size()):
				names2.append(TerrainType.terrain_name_cn(int(bio_history[i])))
			_history_label.text = "近期植被：%s（兼容轴）" % " → ".join(names2)

# Milestone 3：单独刷新天气行，避免每天 tick 时重画整面板
func _refresh_weather_line() -> void:
	if _selected_cell == null or _weather_label == null:
		return
	var cs: Dictionary = _selected_cell.current_state
	var wt: int = int(cs.get("weather", WeatherType.WT.CLEAR))
	var wi: float = float(cs.get("weather_intensity", 0.0))
	if wt == WeatherType.WT.CLEAR or wi <= 0.05:
		_weather_label.text = "天气：晴朗"
	else:
		_weather_label.text = "天气：%s（强度 %.0f%%）" % [WeatherType.name_cn(wt), wi * 100.0]

# Milestone 4：单独刷新植被生命值行（与 weather 一样按"日"高频刷新）
func _refresh_vitality_line() -> void:
	if _selected_cell == null or _vitality_label == null:
		return
	var cell := _selected_cell
	if LandformType.is_water(cell.landform):
		_vitality_label.text = "生命值：—（水域无植被生命值）"
		return
	var v: float = cell.vegetation_vitality
	var band: String = _vitality_band(v)
	# 演替倒计时：哪边 streak 接近触发就提示倒计时
	var hint := ""
	if cell._vitality_low_streak > 0:
		var rem: int = (_generator._c().succession_degrade_days if _generator != null else 30) - cell._vitality_low_streak
		if rem <= 0:
			hint = "  ⚠ 即将退化"
		elif rem <= 10:
			hint = "  ⚠ 退化倒计时 %d 天" % rem
	elif cell._vitality_high_streak > 0:
		var rem2: int = (_generator._c().succession_upgrade_days if _generator != null else 60) - cell._vitality_high_streak
		if rem2 <= 0:
			hint = "  ✓ 即将升级"
		elif rem2 <= 15:
			hint = "  ✓ 升级倒计时 %d 天" % rem2
	_vitality_label.text = "生命值：%.0f%%（%s）%s" % [v * 100.0, band, hint]

func _vitality_band(v: float) -> String:
	if v < 0.20: return "濒死"
	if v < 0.45: return "枯萎"
	if v < 0.70: return "亚健康"
	if v < 0.90: return "健康"
	return "繁茂"

# ─── 文字档位 helper（仅 UI 用，不参与游戏逻辑） ─────────────────────────

func _elevation_band(elev: float, sea: float) -> String:
	if elev < sea * 0.30: return "深海"
	if elev < sea * 0.85: return "近海"
	if elev < sea: return "浅海"
	var land := (elev - sea) / maxf(1.0 - sea, 0.001)
	if land < 0.05: return "海岸 / 海滩"
	if land < 0.30: return "低地平原"
	if land < 0.55: return "丘陵"
	if land < 0.80: return "山地"
	if land < 0.95: return "高峰"
	return "雪线以上"

func _climate_zone_name(ny: float) -> String:
	var d: float = absf(ny - 0.5)
	if d < 0.10: return "热带"
	if d < 0.20: return "副热带"
	if d < 0.32: return "温带"
	if d < 0.42: return "副极地"
	return "极地"

func _temperature_band(t: float) -> String:
	if t < 0.06: return "极寒"
	if t < 0.20: return "严寒"
	if t < 0.30: return "寒冷"
	if t < 0.40: return "凉爽"
	if t < 0.55: return "温暖"
	if t < 0.75: return "炎热"
	return "酷热"

func _moisture_band(m: float) -> String:
	if m < 0.20: return "极干"
	if m < 0.40: return "干燥"
	if m < 0.60: return "适中"
	if m < 0.80: return "湿润"
	return "极湿"
