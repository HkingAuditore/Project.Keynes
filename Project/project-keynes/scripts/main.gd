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

# Daily-sim perf instrumentation：每日模拟性能埋点。
#  ① perf_log_daily_breakdown=true 时，每隔 perf_log_daily_stride 个 fast tick
#     就打印一行 "[fast tick #N] sus=Xms ui=Yms total=Zms" + 各 SUS Job 的细分
#     （elapsed_ms / slices / skipped_reason）。
#  ② 即使关闭 breakdown，> 12ms 触发 WARN 时也会**强制**打印一次本 tick 的
#     SUS 拆解，方便事后定位罪魁。
#  ③ stride=0 时禁用周期日志（仅保留 WARN 触发路径）。
@export_group("Perf Instrumentation")
@export var perf_log_daily_breakdown: bool = false
@export_range(0, 3650, 1) var perf_log_daily_stride: int = 365

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
# Open Ocean Color Rebalance：在新去饱和 base palette 上，把扰动幅度从 0.70
# 抬到 0.95，让 ±5% 亮度 / ±2% 色相变化更可见，外海呈现"云影感"色斑。
# 旧值 / 新值：0.70 / 0.95。
@export_range(0.0, 1.0, 0.01) var water_calm_noise_brightness: float = 0.95
@export_range(0.0, 1.0, 0.01) var water_calm_noise_tint_strength: float = 0.95
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
@onready var _overlay_layer: DataOverlayLayer = $WorldRoot/DataOverlayLayer
@onready var _right_panel: PanelContainer = $UI/RightPanel
@onready var _close_btn: Button = $UI/RightPanel/Margin/Scroll/VBox/Header/CloseBtn
@onready var _pos_label: Label = $UI/RightPanel/Margin/Scroll/VBox/PosLabel
@onready var _elev_label: Label = $UI/RightPanel/Margin/Scroll/VBox/ElevLabel
@onready var _climate_zone_label: Label = $UI/RightPanel/Margin/Scroll/VBox/ClimateZoneLabel
@onready var _temp_label: Label = $UI/RightPanel/Margin/Scroll/VBox/TempLabel
@onready var _moist_label: Label = $UI/RightPanel/Margin/Scroll/VBox/MoistLabel
@onready var _precip_label: Label = $UI/RightPanel/Margin/Scroll/VBox/PrecipLabel
@onready var _landform_label: Label = $UI/RightPanel/Margin/Scroll/VBox/LandformLabel
@onready var _vegetation_label: Label = $UI/RightPanel/Margin/Scroll/VBox/VegetationLabel
# Milestone 4：植被生命值（演替倒计时与气候适应度的可视化）
@onready var _vitality_label: Label = $UI/RightPanel/Margin/Scroll/VBox/VitalityLabel
@onready var _cover_label: Label = $UI/RightPanel/Margin/Scroll/VBox/CoverLabel
# Milestone 3：天气子系统在 panel 上的展示行（CLEAR 时隐藏强度数字）
@onready var _weather_label: Label = $UI/RightPanel/Margin/Scroll/VBox/WeatherLabel
@onready var _feature_label: Label = $UI/RightPanel/Margin/Scroll/VBox/FeatureLabel
@onready var _mobility_label: Label = $UI/RightPanel/Margin/Scroll/VBox/MobilityLabel
@onready var _history_label: Label = $UI/RightPanel/Margin/Scroll/VBox/HistoryLabel
# Debug 控制台：可开合的调试面板（默认 visible=false），快捷键 ` 或 F1 切换。
@onready var _debug_console: PanelContainer = $UI/DebugConsole
# Overlay 图例（Legend）：在地图左下角显示当前通道的色带 / 离散列表，
# 只在 _overlay_mode != NONE 时可见。mouse_filter=IGNORE，不拦截地图输入。
@onready var _overlay_legend: PanelContainer = $UI/OverlayLegend

# Emergent Climate Coupling：三行"涌现耦合"信息标签（运行时动态创建）
var _emergent_temp_label: Label = null
var _emergent_ice_label: Label = null
var _emergent_feedback_label: Label = null
# True Insolation-Driven（Phase F）：两行额外信息。
var _emergent_sun_label: Label = null      # "太阳：直射点 ±XX.X°  日射相对年均 ±XX.X%"
var _emergent_month_label: Label = null    # "月份 X 月 X 日 · 近30日距年均 ±X.XX"

var _current_map: MapData = null
var _generator: MapGenerator = null
var _world_data: WorldData = null
var _last_seed: int = 0
var _last_time_label_hour: int = -1
# 当前选中地块（重新生成地图时清空，避免持有旧 MapData 的 cell 引用）
var _selected_cell: HexCell = null
# Emergent Climate Coupling：fast tick 性能打点计数（需求 6.2 合计耗时节流 WARN）
var _fast_tick_count: int = 0
var _fast_tick_warn_last_frame: int = 0
var _slow_tick_count: int = 0

# ─── Data Overlay 状态 ─────────────────────────────────────────────
# _overlay_mode   : OverlayMode.MODE 的整数值，NONE=0
# _overlay_alpha  : 半透明强度（0.6~0.8 推荐），送到 data_overlay.gdshader
# _overlay_stats  : 最近一次 bake 返回的统计摘要，供 Telemetry 面板读取
# _overlay_last_bake_ms : 最近一次 bake 的耗时（ms），用于性能验证
# _overlay_last_fast_tick_ms : 最近一次 fast tick 总耗时（ms），给 Telemetry
# _overlay_error_msg : shader 加载 / bake 失败时写入的错误原因，DebugConsole 读
var _overlay_mode: int = 0
var _overlay_alpha: float = 0.7
var _overlay_stats: Dictionary = {}
var _overlay_last_bake_ms: float = 0.0
var _overlay_last_fast_tick_ms: int = 0
var _overlay_error_msg: String = ""

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
	_world_clock.season_phase_changed.connect(_on_season_phase_changed)
	# Fast-tick perf opt (A+D)：速度档变更时自动调整 MapGenerator 的
	# weather_refresh_stride，同时 world_clock 内部会顺带调整 day_phase/season_phase
	# 节流步长。启动时按 initial_speed 初调一次，保证 x1 档默认 stride=1 的语义。
	_world_clock.speed_changed.connect(_on_speed_changed)
	_on_speed_changed(_world_clock.speed_multiplier)
	_refresh_time_label()
	# 任务 1：把 @export 的视觉总开关推送给 renderer / weather_layer 一次
	_push_visual_toggles()
	# Pass 2：启动时显式推一次 TOD，保证 shader 的 tod_* uniform 不为 0
	_recompute_and_push_tod(_world_clock.day_phase())
	# Data Overlay：首次把 overlay 的 world bounds 与 alpha 同步给节点；
	# 默认 mode=NONE → 节点 visible=false，零额外开销（需求 1.1 / 1.3）。
	_sync_overlay_to_world()

	# DebugConsole：把自己作为运行时状态来源注入给控制台，使其能读回诸如
	# overlay_mode / fast_tick / climate_profile 字段的真值（需求 4.7）。
	if _debug_console != null and _debug_console.has_method("set_main"):
		_debug_console.set_main(self)

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
			_camera.fit_to_viewport(1.05, _map_safe_area())
		KEY_SPACE:
			_world_clock.toggle_pause()
			_sync_pause_btn()
			_sync_clock_running_to_weather_layer()
		KEY_QUOTELEFT, KEY_F1:
			# Debug 控制台开合（需求 4.1）。反引号/波浪键 或 F1
			# 都能切换可见性。面板 mouse_filter=STOP，点击在面板内
			# 的时候不会穿透选中地块。
			if _debug_console != null:
				_debug_console.visible = not _debug_console.visible
		KEY_F8:
			# Emergent Climate Coupling + True Insolation-Driven：一键切换"纯回退模式"。
			# 把 5 个涌现耦合开关（含 true_insolation_enabled）统一在 true / false
			# 之间切换，让画面、温度物理、海冰、湿度同时切换；方便 QA 在同一会话
			# 对比"全涌现"与"全 legacy"路径的差异。
			if _generator != null:
				var cp = _generator._c()
				if cp != null:
					var fallback: bool = bool(cp.emergent_season_enabled)
					var new_state: bool = not fallback
					cp.emergent_season_enabled = new_state
					cp.enable_local_climate_coupling = new_state
					cp.emergent_weather_coupling = new_state
					cp.fast_slow_layering_enabled = new_state
					cp.true_insolation_enabled = new_state
					print("[Emergent+Insolation] 5 switches → %s (press F8 to toggle)" % str(new_state))
					# 同步推到 shader（画面跟着物理一起切）
					if _renderer != null and _renderer.has_method("set_true_insolation_enabled"):
						_renderer.set_true_insolation_enabled(new_state)
					# WeatherSystem 也要同步
					# 注：用 call() 反射调用 + Object 弱类型接收，是为了绕开 Godot 4
					# 偶发的 "Could not resolve external class member" 静态解析报错
					# （脚本类缓存脏时复现）。功能上等价于 _generator.get_weather_system()。
					var ws: Object = _generator.call("get_weather_system") if _generator.has_method("get_weather_system") else null
					if ws != null and ws.has_method("configure_emergent_coupling"):
						ws.call("configure_emergent_coupling",
							bool(cp.emergent_weather_coupling),
							float(cp.rain_shadow_threshold),
							float(cp.rain_shadow_factor),
							float(cp.orographic_boost)
						)
					if ws != null and ws.has_method("configure_ocean_spawn_bias"):
						ws.call("configure_ocean_spawn_bias", float(cp.ocean_weather_spawn_bias))
					# 立即强制一次 refresh_climate_daily，让面板 / 温度 / 海冰即时响应
					if _current_map != null and _world_clock != null:
						_generator.refresh_climate_daily(_current_map, _world_clock.season_phase())
						_refresh_emergent_lines()
		KEY_F6:
			# 任务 9：切换 ocean_current_debug uniform（高/低对比流线）
			if _renderer != null and _renderer.has_method("set_ocean_current_debug"):
				var cur: bool = _renderer.get_ocean_current_debug()
				_renderer.set_ocean_current_debug(not cur)
				print("[VisualOverhaul] ocean_current_debug = %s" % str(not cur))
		KEY_F7:
			# Systemic Ocean Currents：ocean_heat_debug 轻量控制台打印
			# 初版不做 shader 红蓝渐变（需要 per-cell debug 贴图，侵入较大）；
			# 改为：按下时打印当前地图里 temperature_transport_anomaly 分布摘要
			# （min / max / mean / |>0.02| 计数），便于快速验证热输运 pass 是否生效。
			if _current_map == null:
				print("[Ocean] F7: no map")
			else:
				var mn: float = INF
				var mx: float = -INF
				var sm: float = 0.0
				var cnt: int = 0
				var hot_water: int = 0
				var hot_land: int = 0
				for c: HexCell in _current_map.all_cells():
					var a: float = c.temperature_transport_anomaly
					mn = minf(mn, a)
					mx = maxf(mx, a)
					sm += a
					cnt += 1
					if absf(a) > 0.02:
						if _generator != null and _generator.has_method("_is_water"):
							pass
						# 简易判定：ocean_current 非零 → 判水
						if c.ocean_current.length_squared() > 1e-6:
							hot_water += 1
						else:
							hot_land += 1
				if cnt > 0:
					print("[Ocean] F7 heat_debug: anomaly min=%.3f max=%.3f mean=%.4f | |a|>0.02: water=%d land=%d" % [
						mn, mx, sm / float(cnt), hot_water, hot_land
					])

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

# Fast-tick perf opt (A)：速度档变更回调——按档位把 weather_refresh_stride
# 调成 x1→1 / x5→4 / x20→8，让加速档位下 refresh_daily 的反馈链 + 重烘焙
# 按 stride 跳日执行，显著降低单帧热路径开销。
func _on_speed_changed(new_speed: float) -> void:
	if _generator == null:
		return
	var stride: int = 1
	if new_speed >= 15.0:
		stride = 8
	elif new_speed >= 3.0:
		stride = 4
	else:
		stride = 1
	_generator.set_weather_refresh_stride(stride)

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
	# ───────────────────────────────────────────────────────────────────
	# Emergent Climate Coupling — 每日调用顺序契约（fast tick）：
	#   1. refresh_climate_daily   — 读慢层 + 写快层（内部尾部还会跑 sea_ice_daily、transpiration）
	#   2. refresh_daily           — WeatherSystem tick（只读慢层 + 写 current_state.weather_*）
	#   3. weather→map feedback    — 由 refresh_daily 内部末尾的 _apply_weather_to_map_feedback_pass 完成
	# 任务 8：以上三步全部收编为 SUS Job（refresh_climate_daily / weather_refresh /
	# ocean_currents），由 sus_tick_daily 统一调度。stride 跳日由 SusPolicy 承担。
	# 每季跨整数边界时 WorldClock 会发 season_changed → _on_season_changed → refresh_seasonal。
	# 每年 year_changed → refresh_yearly。
	# ───────────────────────────────────────────────────────────────────
	# Daily-sim perf instrumentation：fast tick 总耗时拆成三段：
	#   t_sus           — SUS dispatch（refresh_climate_daily + weather_refresh +
	#                     ocean_currents 等所有 Job）
	#   t_renderer_sync — fronts → HexRenderer（UI/可视化同步成本）
	#   t_ui            — 选中地块面板 4 行的细粒度刷新（only when not skipped）
	# total = t_sus + t_renderer_sync + t_ui（外加少量调度开销）
	var t_fast0: int = Time.get_ticks_msec()
	var t_sus_us0: int = Time.get_ticks_usec()

	# Sliced Update Scheduler（任务 8）：完整收编后 fast tick 的全部模拟工作
	# 都在这里一次性驱动。返回字典：{ fronts: Array[WeatherFront], weather_ran: bool }。
	# weather_ran=false 表示本日被 weather_refresh_job.policy（StridePolicy）跳过，
	# 这条信息被用来抑制 UI 的 weather/vitality/climate/emergent 四行刷新——
	# 等价于此前的 was_skipped_day 行为。
	var sus_result: Dictionary = {}
	if _generator != null and _world_clock != null:
		sus_result = _generator.sus_tick_daily(_world_clock)
	var weather_ran: bool = bool(sus_result.get("weather_ran", false))
	var was_skipped_day: bool = not weather_ran
	var fronts: Array[WeatherFront] = sus_result.get("fronts", [] as Array[WeatherFront])
	# Drift-fix（2026-05-10）：weather_ran 在 SUS 双 tick 切片下，stage_a/stage_b 都为真——
	# 但 _last_fronts 只在 stage_b 真正翻新。fronts_changed 区分了"slice 跑了"和
	# "fronts 数据真的变了"。下方 set_weather_fronts gate 必须用 fronts_changed，
	# 否则 stage_a tick 会把上一份 fronts 重推一次 → weather_layer reset blend +
	# forward-bias 算出"起点≈终点"→ 云冻结。
	var fronts_changed: bool = bool(sus_result.get("fronts_changed", false))
	var t_sus_ms: float = (Time.get_ticks_usec() - t_sus_us0) / 1000.0

	# Renderer 与 UI 同步：fronts 在跳日时会沿用 WeatherRefreshJob.last_fronts() 的
	# 缓存（即上次成功 tick 的快照），renderer 持续看到一致的天气可视化。
	# Continuity-fix（E，2026-05-10）：跳日（weather_ran=false）不再调
	# set_weather_fronts。原因：set_weather_fronts 内部会无条件重置 blend
	# (_front_blend_elapsed=0 + 重新计算 _front_blend_duration ≈ 0.35s)，跳日下
	# 上次的视觉快照已经被 _predict_front_snapshots 沿 velocity 外推，再喂同一
	# 份 cached fronts 作 target 会让云"被拉回原位 → 重新外推 → 再拉回"，肉
	# weather_field_texture 已停用：天气场保留在 HexCell.weather_*，视觉层只吃 fronts。
	#
	# Drift-fix（2026-05-10）：从 weather_ran 改成 fronts_changed。
	# WeatherRefreshJob 双 tick 切片（stage_a 计算 + stage_b 烘 field）中，weather_ran
	# 在两 tick 都为真，但 _last_fronts 只在 stage_b 翻新。用 weather_ran 当 gate 时，
	# stage_a tick 会重推上一份 fronts → set_weather_fronts 内部 reset blend 让 lerp
	# 起点≈终点 → 一半时间云完全冻结，根本看不到 forward-bias 带来的飘动。
	# 改用 fronts_changed 确保每两个游戏日才推一次（≈ 1× 速度下 2 秒一次），
	# blend 在每次推送之间有完整 ~2.3s 平滑 lerp 时间，云能持续可见地飘。
	var t_render_us0: int = Time.get_ticks_usec()
	# Drift debug stays silent during fast ticks; SUS WARN already reports front status.
	if _renderer != null:
		if _renderer.has_method("set_weather_field_texture") and _world_data != null:
			_renderer.set_weather_field_texture(null)
		if fronts_changed:
			_renderer.set_weather_fronts(fronts)
	var t_render_ms: float = (Time.get_ticks_usec() - t_render_us0) / 1000.0

	# 选中地块的 weather + vitality + 连续气候三行跟着每日推进刷新
	# （不刷整张面板，仅刷少量行避免抖动；演替发生时整张面板会在下次 _refresh_info_panel 同步）
	# Fast-tick perf opt (A)：跳日不刷这些行——保留上次值直到下一个真正 tick 的日。
	var t_ui_us0: int = Time.get_ticks_usec()
	if _selected_cell != null and not was_skipped_day:
		_refresh_weather_line()
		_refresh_vitality_line()
		_refresh_climate_line()
		_refresh_emergent_lines()
	var t_ui_ms: float = (Time.get_ticks_usec() - t_ui_us0) / 1000.0

	# Emergent Climate Coupling：fast tick 总耗时打点
	# 首次必打；随后按 365 日节流。合计 > 12ms 触发 WARN（不阻塞主循环）。
	var fast_ms: int = Time.get_ticks_msec() - t_fast0
	_fast_tick_count += 1

	# Daily-sim perf instrumentation：周期性细分日志（默认关闭，开启后能看到
	# "SUS 段占多少 / renderer 同步段占多少 / 面板刷新占多少 / 各 Job 跑了多久"）。
	var should_log_breakdown: bool = perf_log_daily_breakdown \
		and perf_log_daily_stride > 0 \
		and (_fast_tick_count == 1 or (_fast_tick_count % perf_log_daily_stride) == 0)
	# 老牌 fast tick 日志（保留兼容 perf-report.md 已有数据格式）
	if _fast_tick_count == 1 or (_fast_tick_count % 365) == 0:
		print("fast tick #%d: %dms (sus=%.2f render=%.2f ui=%.2f skipped_day=%s)"
			% [_fast_tick_count, fast_ms, t_sus_ms, t_render_ms, t_ui_ms, str(was_skipped_day)])
	# Fast-tick perf opt (A)：跳日路径本就是低成本，跳过 > 12ms 警告误报判定。
	# Daily-sim perf instrumentation：原 365 帧节流过松（卡顿期 400ms 一年才提醒一次），
	# 改为指数退让——首次必报，之后按 30 帧节流，避免刷屏又能持续看到趋势。
	var trigger_warn: bool = (not was_skipped_day) and fast_ms > 12 \
		and (_fast_tick_warn_last_frame == 0 or (_fast_tick_count - _fast_tick_warn_last_frame) >= 30)
	if trigger_warn:
		push_warning("[fast tick] %dms > 12ms budget (frame=%d, sus=%.2fms render=%.2fms ui=%.2fms cells=%d)" % [
			fast_ms, _fast_tick_count, t_sus_ms, t_render_ms, t_ui_ms,
			_current_map.cell_count() if _current_map != null else 0
		])
		_fast_tick_warn_last_frame = _fast_tick_count

	# Daily-sim perf instrumentation：周期日志 OR WARN 触发 → 打印每个 SUS Job
	# 的精细拆解。打印格式：
	#   [fast tick #N] sus=A render=B ui=C total=D skip=<bool>
	#       <job_id> ran=<ms> slices=<n>
	#       <job_id> skipped(<reason>)
	if should_log_breakdown or trigger_warn:
		_print_daily_breakdown(_fast_tick_count, t_sus_ms, t_render_ms, t_ui_ms,
			float(fast_ms), was_skipped_day, trigger_warn)

	# Data Overlay：每日随模拟推进刷新一次数据纹理（需求 2.7）。
	# overlay_mode == NONE 时 _refresh_overlay_data 内部会早返 0 开销。
	# 跳日（was_skipped_day）时仍刷新——因为慢层（base_moisture / 气候带）
	# 在跳日内可能也变；成本仅 1 次 O(cells) 采样 + 纹理 upload，<1ms。
	_overlay_last_fast_tick_ms = fast_ms
	if _overlay_mode != 0:
		_refresh_overlay_data()


# Daily-sim perf instrumentation：把 SUS.report_last_tick() 翻译成可读日志。
# 同时打印 source（区分 day_changed / season_changed 等触发源）和每 Job 的
# elapsed_ms / slices_run / skipped_reason，便于"看一眼就知道罪魁是谁"。
func _print_daily_breakdown(tick_no: int, sus_ms: float, render_ms: float,
		ui_ms: float, total_ms: float, skipped_day: bool, is_warn: bool) -> void:
	var prefix: String = "[fast tick WARN]" if is_warn else "[fast tick]"
	print("%s #%d sus=%.2f render=%.2f ui=%.2f total=%.0fms skip_day=%s"
		% [prefix, tick_no, sus_ms, render_ms, ui_ms, total_ms, str(skipped_day)])
	if _generator == null or not _generator.has_method("sus_report_last_tick"):
		return
	var report: Dictionary = _generator.sus_report_last_tick()
	if report.is_empty():
		print("    (sus report empty)")
		return
	for job_id in report.keys():
		var r: Dictionary = report[job_id]
		var elapsed_ms: float = float(r.get("elapsed_ms", 0.0))
		var slices: int = int(r.get("slices_run", 0))
		var skipped: String = str(r.get("skipped_reason", ""))
		if skipped != "":
			print("    %s skipped(%s)" % [str(job_id), skipped])
		else:
			print("    %s ran=%.2fms slices=%d progress=%.2f"
				% [str(job_id), elapsed_ms, slices, float(r.get("progress_ratio", 0.0))])
			# Daily-sim perf instrumentation：refresh_climate_daily 内部 6 段拆解
			# （Pass A / Pass B / ocean / sea_ice / ice_bake / transp）
			if job_id == &"refresh_climate_daily" and _generator != null \
					and _generator.has_method("sus_climate_breakdown"):
				var b: Dictionary = _generator.sus_climate_breakdown()
				if not b.is_empty():
					print("        A=%.1f B=%.1f ocean=%.1f sea_ice=%.1f ice_bake=%.1f transp=%.1f cells=%d pass=%s partial=%s" % [
						float(b.get("pass_a_ms", 0.0)),
						float(b.get("pass_b_ms", 0.0)),
						float(b.get("ocean_ms", 0.0)),
						float(b.get("sea_ice_ms", 0.0)),
						float(b.get("ice_bake_ms", 0.0)),
						float(b.get("transp_ms", 0.0)),
						int(b.get("cells", 0)),
						str(b.get("current_pass", "")),
						str(b.get("partial", false)),
					])
			# Daily-sim perf instrumentation：weather_refresh 内部细分
			# （weather_tick 包括 advance/spawn/distribute/cyclone 四段；
			#  之后是 transp/albedo/veg_dyn/cover_rebake/veg_rebake/feedback）
			if job_id == &"weather_refresh" and _generator != null \
					and _generator.has_method("sus_weather_breakdown"):
				var wb: Dictionary = _generator.sus_weather_breakdown()
				if not wb.is_empty():
					print("        weather_tick=%.1f (adv=%.1f spawn=%.1f dist=%.1f cyc=%.1f) field_bake=%.1f transp=%.1f albedo=%.1f veg_dyn=%.1f rebake_cv=%.1f rebake_vg=%.1f feedback=%.1f fronts=%d" % [
						float(wb.get("weather_tick_ms", 0.0)),
						float(wb.get("advance_ms", 0.0)),
						float(wb.get("spawn_ms", 0.0)),
						float(wb.get("distribute_ms", 0.0)),
						float(wb.get("cyclone_ms", 0.0)),
						float(wb.get("weather_field_bake_ms", 0.0)),
						float(wb.get("transp_ms", 0.0)),
						float(wb.get("albedo_ms", 0.0)),
						float(wb.get("veg_dyn_ms", 0.0)),
						float(wb.get("cover_rebake_ms", 0.0)),
						float(wb.get("veg_rebake_ms", 0.0)),
						float(wb.get("feedback_ms", 0.0)),
						int(wb.get("fronts", 0)),
					])
			if job_id == &"enum_atlas_upload" and _generator != null \
					and _generator.has_method("sus_enum_atlas_breakdown"):
				var eb: Dictionary = _generator.sus_enum_atlas_breakdown()
				if not eb.is_empty():
					print("        enum_atlas_upload axis=%s elapsed=%.1f pending_cv=%s pending_vg=%s" % [
						str(eb.get("axis", "")),
						float(eb.get("elapsed_ms", 0.0)),
						str(eb.get("cover_pending", false)),
						str(eb.get("vegetation_pending", false)),
					])
			if job_id == &"season_refresh" and _generator != null \
					and _generator.has_method("sus_season_refresh_breakdown"):
				var sb: Dictionary = _generator.sus_season_refresh_breakdown()
				if not sb.is_empty():
					print("        season_refresh stages=%s" % [str(sb)])

func _on_season_changed(_season_idx: int) -> void:
	_refresh_time_label()
	# Phase 2：每"季"重跑湿度/雨影 → 局部 biome 重决策 → 重烘焙 biome_tex
	if _generator != null and _current_map != null and _world_data != null:
		var t0 := Time.get_ticks_msec()
		if _renderer != null and _renderer.has_method("begin_season_transition"):
			_renderer.begin_season_transition(_world_clock.season_phase())
		if _generator.has_method("queue_season_refresh"):
			_generator.queue_season_refresh(_season_idx)
		else:
			_generator.refresh_seasonal(_current_map, _world_data, _season_idx)
		print("Season refresh queued %dms" % (Time.get_ticks_msec() - t0))
	# 季节事务现在由 SUS 分片提交；面板在事务完成前保留上一套完整状态。
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

func _on_season_phase_changed(season_phase: float) -> void:
	if _renderer != null:
		_renderer.set_season_phase(season_phase)

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

	# Sliced Update Scheduler（任务 5）：regenerate 入口防御性调用。当前实现里
	# _generator 会被 new 出新实例（连同新 SUS + 新 baker 一起），旧 SUS 的
	# pending buffer 随旧 baker 一起 GC，理论上不需要额外 reset。但保留这行
	# 调用作为接口防御点：未来若改成复用 _generator 实例 + 重新 generate，
	# 这一行能保证 pending buffer 被丢弃，不串味到新地图。
	if _generator != null and _generator.has_method("sus_reset_all"):
		_generator.sus_reset_all()

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
	# Sliced Update Scheduler（任务 4）：把 world_clock 入口注入给 SUS，
	# OceanCurrentsJob 需要 season_phase 连续浮点作为 phase 输入。
	if _world_clock != null:
		_generator.set_world_clock_ref(_world_clock)
	var elapsed: int = Time.get_ticks_msec() - t0

	_renderer.hex_size = hex_size
	_renderer.set_map(_current_map, _world_data)

	# 把当前时间状态先推一次给 renderer，避免新生成的地图用着旧的 season_phase
	if _world_clock != null:
		_renderer.set_season_phase(_world_clock.season_phase())
		_renderer.set_climate_anomaly(_world_clock.climate_anomaly)
		# 任务 2：新地图生成后立即把 day_phase 还原到 shader
		_renderer.set_day_phase(_world_clock.day_phase())
		# Seasonal Continuous Climate：新地图生成后 generate() 写的是"夏中段"快照，
		# 立即用当前 season_phase 同步一次连续基线，让玩家进入第一帧就看到与
		# 时钟相位一致的温度/湿度/雪盖，而不是固定的夏季常量。
		if _generator != null and _current_map != null:
			var cp = _generator._c()
			if cp != null and cp.daily_climate_interpolation:
				_generator.refresh_climate_daily(_current_map, _world_clock.season_phase())

	_camera.set_world_bounds(_renderer.get_world_bounds())
	_camera.fit_to_viewport(1.05, _map_safe_area())

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

	# Data Overlay（需求 1.5）：R 键重生成地图时**保留当前 overlay mode**，
	# 只是重绑 world bounds 并立即重烘焙一次数据纹理，让玩家可以继续在同
	# 一个数据通道上对比不同种子的分布。
	_sync_overlay_to_world()
	if _overlay_mode != 0:
		_refresh_overlay_data()

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
	_ensure_emergent_labels()
	_refresh_info_panel()
	# Legend 指针：选中后把当前 cell 的通道值映射到色带位置。
	_update_overlay_pointer_for_cell()
	# 面板弹出后地图可见区域变窄，重新 fit 一次让整张地图仍完整显示
	if _camera != null:
		_camera.fit_to_viewport(1.05, _map_safe_area())

func _clear_selection() -> void:
	_selected_cell = null
	if _highlight != null:
		_highlight.clear()
	if _right_panel != null:
		_right_panel.visible = false
	if _overlay_legend != null:
		_overlay_legend.clear_pointer()
	# 面板关闭后可见区域恢复全宽，再 fit 一次回到默认视图
	if _camera != null:
		_camera.fit_to_viewport(1.05, _map_safe_area())

# 计算地图的"可见安全区"：扣掉顶部 TopBar 和右侧 RightPanel（仅在可见时扣除）。
# 被 fit_to_viewport 使用，保证整张地图都落在未被 UI 覆盖的矩形内。
func _map_safe_area() -> Rect2:
	var vp := get_viewport().get_visible_rect().size
	var top_h: float = 40.0  # TopBar = PanelContainer offset_bottom=36 + 少量安全边距
	var right_w: float = 0.0
	if _right_panel != null and _right_panel.visible:
		# RightPanel.custom_minimum_size.x 若为 0 则用 size.x 回退
		var w: float = _right_panel.custom_minimum_size.x
		if w <= 0.0:
			w = _right_panel.size.x
		right_w = w
	var safe := Rect2(Vector2(0.0, top_h), Vector2(maxf(vp.x - right_w, 1.0), maxf(vp.y - top_h, 1.0)))
	return safe

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
	# Fast-tick perf opt (C)：temperature / moisture / snow_cover 已升级为
	# HexCell 强类型成员，直接读，不再走 cs.get 字典查找。
	var cs: Dictionary = cell.current_state
	var temp: float = cell.temperature
	_temp_label.text = "当前温度：%.2f（%s）" % [temp, _temperature_band(temp)]

	# ── 当前湿度（cell.moisture） + 年均基线对照
	var moist: float = cell.moisture
	_moist_label.text = "当前湿度：%.2f（%s）   年均基线：%.2f" % [
		moist, _moisture_band(moist), cell.base_moisture
	]

	# ── 当季降水（派生估算：连续 moisture_scale × base_moisture）
	# Seasonal Continuous Climate：用 _moisture_scale_at_phase 取连续倍率，
	# 与逐日刷新写入 current_state.moisture 的倍率严格一致，避免显示与实际脱节。
	var fallback_season: int = _world_clock.season_index() if _world_clock != null else 1
	var season: int = int(cs.get("season", fallback_season))
	var season_phase_now: float = _world_clock.season_phase() if _world_clock != null else (float(season) + 0.5)
	var scale: float = 1.0
	if _generator != null:
		var cp = _generator._c()
		scale = DataOverlayBaker._moisture_scale_at_phase(cp, season_phase_now)
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
	# Fast-tick perf opt (C)：snow_cover 已升级为强类型成员，直接读。
	var snow_pct: float = cell.snow_cover * 100.0
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

	# Emergent Climate Coupling：三行涌现耦合信息（温度分解 / 海冰覆盖度 / 反馈缓冲）
	_refresh_emergent_lines()

# Milestone 3：单独刷新天气行，避免每天 tick 时重画整面板
func _refresh_weather_line() -> void:
	if _selected_cell == null or _weather_label == null:
		return
	var wt: int = _selected_cell.weather_type if _selected_cell.weather_field_initialized else WeatherType.WT.CLEAR
	var wi: float = _selected_cell.weather_intensity if _selected_cell.weather_field_initialized else 0.0
	if wt == WeatherType.WT.CLEAR or wi <= 0.05:
		_weather_label.text = "天气：晴朗"
	else:
		_weather_label.text = "天气：%s（强度 %.0f%%）" % [WeatherType.name_cn(wt), wi * 100.0]

# Seasonal Continuous Climate：单独刷新"当前温度 / 当前湿度 / 当季降水"三行，
# 让玩家在选中地块时能逐日看到换季的渐进变化，而不必等到换季触发整面板重绘。
# 与 _refresh_info_panel 中的同名计算保持一致（连续 moisture_scale + 余弦温度曲线）。
func _refresh_climate_line() -> void:
	if _selected_cell == null:
		return
	var cell := _selected_cell
	var cs: Dictionary = cell.current_state

	# ── 当前温度
	if _temp_label != null:
		# Fast-tick perf opt (C)：temperature 已升级为强类型成员，直接读。
		var temp: float = cell.temperature
		_temp_label.text = "当前温度：%.2f（%s）" % [temp, _temperature_band(temp)]

	# ── 当前湿度
	if _moist_label != null:
		# Fast-tick perf opt (C)：moisture 已升级为强类型成员，直接读。
		var moist: float = cell.moisture
		_moist_label.text = "当前湿度：%.2f（%s）   年均基线：%.2f" % [
			moist, _moisture_band(moist), cell.base_moisture
		]

	# ── 当季降水（连续 moisture_scale × base_moisture，与逐日刷新同源）
	if _precip_label != null:
		var fallback_season: int = _world_clock.season_index() if _world_clock != null else 1
		var season: int = int(cs.get("season", fallback_season))
		var season_phase_now: float = _world_clock.season_phase() if _world_clock != null else (float(season) + 0.5)
		var scale: float = 1.0
		if _generator != null:
			var cp = _generator._c()
			scale = DataOverlayBaker._moisture_scale_at_phase(cp, season_phase_now)
		var precip: float = scale * cell.base_moisture
		_precip_label.text = "当季降水：%.2f（估算 = %s ×%.2f × 年均湿度 %.2f）" % [
			precip, _world_clock.season_name_cn(season), scale, cell.base_moisture
		]

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
		var rem: int = (_generator._c().succession_degrade_days if _generator != null else 180) - cell._vitality_low_streak
		if rem <= 0:
			hint = "  ⚠ 即将退化"
		elif rem <= 30:
			hint = "  ⚠ 退化倒计时 %d 天" % rem
	elif cell._vitality_high_streak > 0:
		var rem2: int = (_generator._c().succession_upgrade_days if _generator != null else 360) - cell._vitality_high_streak
		if rem2 <= 0:
			hint = "  ✓ 即将升级"
		elif rem2 <= 45:
			hint = "  ✓ 升级倒计时 %d 天" % rem2
	_vitality_label.text = "生命值：%.0f%%（%s）%s" % [v * 100.0, band, hint]

# Emergent Climate Coupling：懒创建三行 UI 标签（首次选中 cell 时调用一次）
# 动态挂到右侧面板 VBox 末尾，避免修改 .tscn。
func _ensure_emergent_labels() -> void:
	if _emergent_temp_label != null:
		return
	var vbox: Node = _history_label.get_parent() if _history_label != null else null
	if vbox == null:
		return
	_emergent_temp_label = Label.new()
	_emergent_temp_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_temp_label)
	_emergent_ice_label = Label.new()
	_emergent_ice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_ice_label)
	_emergent_feedback_label = Label.new()
	_emergent_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_feedback_label)
	# True Insolation-Driven：额外两行
	_emergent_sun_label = Label.new()
	_emergent_sun_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_sun_label)
	_emergent_month_label = Label.new()
	_emergent_month_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_emergent_month_label)

# Emergent Climate Coupling：刷新三行"涌现耦合"信息：
#   行 1 陆地 cell 显示温度分解，水体 cell 显示海冰覆盖度；
#   行 2 显示 soil_moisture / vegetation_growth_pressure 两个反馈缓冲；
#   行 3 顶部"当前季节"名义 + 过渡百分比。
# 缺字段时一次 WARN 后静默（通过 get(key, fallback) 兜底）。
func _refresh_emergent_lines() -> void:
	if _selected_cell == null:
		return
	_ensure_emergent_labels()
	var cell := _selected_cell
	var cs: Dictionary = cell.current_state

	# 行 1：陆地 → 温度分解；水体 → 海冰覆盖度
	if _emergent_temp_label != null:
		if LandformType.is_water(cell.landform):
			var ice_f: float = float(cell.get("sea_ice_fraction"))
			_emergent_temp_label.text = "海冰覆盖：%.1f%%" % [ice_f * 100.0]
		else:
			# 温度分解（温度基线 / 季节余弦 / 反照率 / 岸泄 / 地形）：当前仅累加 T_eff，
			# 未单独保留分解项。此处给出简化展示：基线 + 叠加量。
			# Fast-tick perf opt (C)：temperature / temp_baseline 已升级为 HexCell
			# 强类型成员，直接读，不再走 current_state 字典查找。
			var t_eff: float = cell.temperature
			var t_base: float = cell.temp_baseline
			_emergent_temp_label.text = "温度分解：基线 %.2f  叠加 %+.2f（含反照率/岸泄/地形）" % [t_base, t_eff - t_base]

	# 行 2：土壤湿度反馈 / 植被生长压力（可能为 0）
	if _emergent_feedback_label != null:
		var sm: float = float(cell.get("soil_moisture"))
		var vp: float = float(cell.get("vegetation_growth_pressure"))
		_emergent_feedback_label.text = "反馈缓冲：土壤湿度 %+.3f  植被压力 %+.3f（本季累计）" % [sm, vp]

	# 行 3：日历月份（显示给玩家看的是月份、而非春夏秋冬——因南北半球相反）
	if _emergent_ice_label != null:
		if _world_clock != null and _generator != null:
			var phase: float = _world_clock.season_phase()
			var cal: Dictionary = _generator.month_of_year(phase)
			_emergent_ice_label.text = "日历：%d 月 %d 日（全年第 %d/120 天）" % [int(cal.month), int(cal.day_of_month), int(cal.day_of_year)]
		else:
			_emergent_ice_label.text = "日历：—"

	# 行 4：太阳直射点 + 日射相对年均（True Insolation-Driven 因果链可视化）
	if _emergent_sun_label != null and _generator != null and _world_clock != null:
		var phase_sun: float = _world_clock.season_phase()
		var subsolar_rad: float = _generator._subsolar_lat_rad(phase_sun)
		var subsolar_deg: float = rad_to_deg(subsolar_rad)
		var ny_sun: float = _generator.cell_ny(cell)
		var dev_sun: float = _generator._insol_dev(ny_sun, phase_sun)
		_emergent_sun_label.text = "太阳：直射点 %+.1f°  日射距年均 %+.1f%%" % [subsolar_deg, dev_sun * 100.0]

	# 行 5：观测月份（本地温度 EMA 距年均）——赤道显示"常年温暖"
	if _emergent_month_label != null and _generator != null and _world_clock != null:
		var phase_m: float = _world_clock.season_phase()
		var obs: Dictionary = _generator.observe_local_month(cell, phase_m)
		var dev_v: float = float(obs.dev)
		var warmer = obs.warmer_than_annual
		var obs_txt: String
		if warmer == null:
			obs_txt = "常年温暖"
		elif bool(warmer):
			obs_txt = "当前偏暖 %+.2f" % [dev_v]
		else:
			obs_txt = "当前偏冷 %+.2f" % [dev_v]
		_emergent_month_label.text = "观测：%d 月 · %s（振幅 %.0f%%）" % [int(obs.calendar_month), obs_txt, float(obs.magnitude) * 100.0]

func _vitality_band(v: float) -> String:
	if v < 0.15: return "濒死"
	if v < 0.40: return "枯萎"
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

# ─── Data Overlay 接口 ─────────────────────────────────────────────────
# 统一放在 main.gd 尾部：DebugConsole 通过这些公共方法控制 overlay，
# 避免 UI 层直接访问 DataOverlayLayer / DataOverlayBaker，便于将来替换实现。
#
# _sync_overlay_to_world()         把当前 world_bounds + alpha + mode 推一次给节点
# _apply_overlay_mode(mode)        切换通道并立即烘焙一次数据纹理
# _set_overlay_alpha(v)            调整 shader 的 base_alpha uniform
# _refresh_overlay_data()          重新 bake 一次（每日 tick 或重生成后调用）
# get_overlay_mode() / get_overlay_alpha() / get_overlay_stats()
#                                  DebugConsole 查询当前状态

func _sync_overlay_to_world() -> void:
	if _overlay_layer == null:
		return
	if _renderer != null:
		_overlay_layer.set_bounds(_renderer.get_world_bounds())
	_overlay_layer.set_alpha(_overlay_alpha)
	_overlay_layer.set_mode(_overlay_mode)

func _apply_overlay_mode(mode: int) -> void:
	# 需求 6.4：防止快速连切残留旧 uniform——每次切换都强制 bake + 重绑 tex。
	_overlay_mode = mode
	_overlay_error_msg = ""
	if _overlay_layer == null:
		return
	_overlay_layer.set_mode(mode)
	if mode == 0:
		# NONE：清空数据纹理避免残影，节点 visible 由 set_mode 内部处理。
		_overlay_layer.set_data_texture(null)
		_overlay_stats = {}
		if _overlay_legend != null:
			_overlay_legend.update_for_mode(0)
		return
	_refresh_overlay_data()
	if _overlay_legend != null:
		_overlay_legend.update_for_mode(_overlay_mode)
		_update_overlay_pointer_for_cell()

func _set_overlay_alpha(v: float) -> void:
	_overlay_alpha = clampf(v, 0.0, 1.0)
	if _overlay_layer != null:
		_overlay_layer.set_alpha(_overlay_alpha)

# 每日（或 regenerate 后）重烘焙一次数据纹理；NONE 模式直接早返。
# 任一环节抛错都把 overlay 强制回退到 NONE（需求 6.5）。
func _refresh_overlay_data() -> void:
	if _overlay_layer == null or _overlay_mode == 0:
		return
	if _current_map == null or _world_data == null:
		# 地图尚未生成（理论上 _ready 里不会走到这里，保险兜底）
		return
	var cp = null
	if _generator != null:
		cp = _generator._c()
	var phase: float = 0.0
	if _world_clock != null:
		phase = _world_clock.season_phase()
	var t0 := Time.get_ticks_usec()
	var result: Dictionary = {}
	# GDScript 没有 try/except；这里做显式的接口存在性检查 + 结果字段校验。
	if DataOverlayBaker == null:
		_disable_overlay_due_to_error("DataOverlayBaker not loaded")
		return
	result = DataOverlayBaker.bake(
		_current_map, _world_data, _overlay_mode, cp, phase
	)
	_overlay_last_bake_ms = (Time.get_ticks_usec() - t0) / 1000.0
	var tex = result.get("texture", null)
	if tex == null:
		_disable_overlay_due_to_error("bake returned null texture")
		return
	_overlay_layer.set_data_texture(tex)
	_overlay_stats = result.get("stats", {})

func _disable_overlay_due_to_error(msg: String) -> void:
	push_warning("[Overlay] disabled: %s" % msg)
	_overlay_error_msg = msg
	_overlay_mode = 0
	if _overlay_layer != null:
		_overlay_layer.force_disable()
		_overlay_layer.set_data_texture(null)

# 公共 getter：DebugConsole / Legend 读取当前状态
func get_overlay_mode() -> int:
	return _overlay_mode

func get_overlay_alpha() -> float:
	return _overlay_alpha

func get_overlay_stats() -> Dictionary:
	return _overlay_stats

func get_overlay_last_bake_ms() -> float:
	return _overlay_last_bake_ms

func get_overlay_error_msg() -> String:
	return _overlay_error_msg

# 诊断动作（Debug 控制台复用）：打印洋流热输运摘要，等价于 F7 的处理逻辑。
func diagnose_ocean_heat() -> void:
	if _current_map == null:
		print("[Ocean] diagnose: no map")
		return
	var mn: float = INF
	var mx: float = -INF
	var sm: float = 0.0
	var cnt: int = 0
	var hot_water: int = 0
	var hot_land: int = 0
	for c: HexCell in _current_map.all_cells():
		var a: float = c.temperature_transport_anomaly
		mn = minf(mn, a)
		mx = maxf(mx, a)
		sm += a
		cnt += 1
		if absf(a) > 0.02:
			if c.ocean_current.length_squared() > 1e-6:
				hot_water += 1
			else:
				hot_land += 1
	if cnt > 0:
		print("[Ocean] heat_debug: anomaly min=%.3f max=%.3f mean=%.4f | |a|>0.02: water=%d land=%d" % [
			mn, mx, sm / float(cnt), hot_water, hot_land
		])

# 诊断动作：打印当前选中地块的 temperature_breakdown（展开成详细项）。
func diagnose_selected_temperature() -> void:
	if _selected_cell == null:
		print("[Temp] diagnose: no selection")
		return
	var cell := _selected_cell
	print("[Temp] cell(q=%d,r=%d) temperature=%.3f baseline=%.3f season_off=%.3f" % [
		cell.q, cell.r, cell.temperature, cell.temp_baseline, cell.temp_season_offset
	])
	var bd: Dictionary = cell.temperature_breakdown
	if bd.is_empty():
		print("    (breakdown empty — selected cell not yet sampled this tick)")
	else:
		for k in bd.keys():
			print("    %s = %.3f" % [str(k), float(bd[k])])

func get_selected_cell() -> HexCell:
	return _selected_cell

func get_current_map() -> MapData:
	return _current_map

func get_world_clock_ref() -> WorldClock:
	return _world_clock

func get_generator() -> MapGenerator:
	return _generator

func get_renderer() -> HexRenderer:
	return _renderer

func get_fast_tick_count() -> int:
	return _fast_tick_count

func get_last_fast_tick_ms() -> int:
	return _overlay_last_fast_tick_ms

# Legend 指针：把当前选中 cell 在当前 overlay 通道下的归一化值传给 OverlayLegend，
# 使色带上的指针位置与 RightPanel 显示的实际数值一一对应。
# 离散通道（CLIMATE_ZONE / WEATHER）由 Legend 自身决定隐藏指针。
# 方向型通道（WIND_DIR / OCEAN_CURRENT_DIR）走 update_pointer_vector，把 (hue, intensity)
# 投影成色环上的小亮点。
func _update_overlay_pointer_for_cell() -> void:
	if _overlay_legend == null or _selected_cell == null:
		return
	if _overlay_mode == 0:
		_overlay_legend.clear_pointer()
		return
	if OverlayMode.is_vector(_overlay_mode):
		var vec: Vector2 = Vector2.ZERO
		var norm_max: float = 1.0
		match _overlay_mode:
			OverlayMode.MODE.WIND_DIR:
				vec = _selected_cell.wind_vector
				# 与 baker 同源（DataOverlayBaker.WIND_SPEED_NORM_MAX = 1.7）
				norm_max = 1.7
			OverlayMode.MODE.OCEAN_CURRENT_DIR:
				vec = _selected_cell.ocean_current
				# 与 baker 同源（DataOverlayBaker.OCEAN_CURRENT_NORM_MAX = 0.8）
				norm_max = 0.8
		var mag: float = vec.length()
		if mag < 0.0001:
			_overlay_legend.clear_pointer()
			return
		var hue: float = fposmod(atan2(vec.y, vec.x) / TAU + 0.5, 1.0)
		var intensity: float = clampf(mag / norm_max, 0.0, 1.0)
		_overlay_legend.update_pointer_vector(hue, intensity)
		return
	if OverlayMode.is_discrete(_overlay_mode):
		_overlay_legend.clear_pointer()
		return
	var v: float = NAN
	match _overlay_mode:
		OverlayMode.MODE.TEMPERATURE:
			v = clampf(float(_selected_cell.temperature), 0.0, 1.0)
		OverlayMode.MODE.PRECIPITATION:
			# 与 baker 同源的 1.5 上限（PRECIPITATION_NORM_MAX）
			var phase: float = _world_clock.season_phase() if _world_clock != null else 0.0
			var scale: float = 1.0
			if _generator != null:
				var cp = _generator._c()
				scale = DataOverlayBaker._moisture_scale_at_phase(cp, phase)
			var precip: float = scale * float(_selected_cell.base_moisture)
			v = clampf(precip / 1.5, 0.0, 1.0)
		OverlayMode.MODE.HUMIDITY:
			v = clampf(float(_selected_cell.moisture), 0.0, 1.0)
		OverlayMode.MODE.VEGETATION_VITALITY:
			v = clampf(float(_selected_cell.vegetation_vitality), 0.0, 1.0)
	if is_nan(v):
		_overlay_legend.clear_pointer()
	else:
		_overlay_legend.update_pointer(v)
