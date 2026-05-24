# main.gd
#
# ─── Phase G.3 / dots-full-migration §G.3 计划状态（2026-05-13）──────────
#
# 本文件当前 1901+ 行，dots-full-migration plan 目标拆完后 ≤ 400 行。
# 拆分目的地骨架（D.3 已就位 + 详细迁移规格在各骨架文件顶部）：
#
#   bootstrap/dots_bootstrap.gd          ← DCWorld + ViewAdapter + Scheduler 注册 +
#                                          DataCore CLI / hot-toggle / view_adapter rebuild
#   bootstrap/sus_systems_bootstrap.gd   ← 6 system 注册 + use_dc_system_scheduler
#                                          flag 切换路径（C.4 留给本 phase 完成的接入）
#   bootstrap/demo_bootstrap.gd          ← demo_thermal_gradient + DCEcsScheduler
#                                          + F-key 调试热键（demo 相关部分）
#   bootstrap/visual_bootstrap.gd        ← TOD / water shader uniform 推送 +
#                                          @export 视觉开关 (~20 个) push 逻辑
#   ui/info_panel_controller.gd         ← 右侧地块信息面板（B.1 已 adapter 化的
#                                          ~250 行 _refresh_info_panel 系列）
#
# G.3 完成后 main.gd 残留 ≤ 400 行：
#   - 生命周期（_ready / _exit_tree）+ 输入处理（_input / hot keys）
#   - @onready 节点 ref（GDScript 限制：必须在 Node 子类）+ 一次性传递给 bootstrap
#   - 顶部 UI 节点 / Camera / WorldRoot 等 scene 引用
#
# 当前各 bootstrap 是 placeholder（push_warning）；actual function migration 是
# 后续 PR 的工作。
#
# **推荐迁移顺序**（每文件独立 PR + 30-day soak ±5%）：
#   1. info_panel_controller.gd（最独立，B.1 已 adapter 化）
#   2. visual_bootstrap.gd（@export 字段 push，纯数据传递）
#   3. dots_bootstrap.gd（DataCore CLI + view_adapter rebuild）
#   4. sus_systems_bootstrap.gd（含 use_dc_system_scheduler 接入）
#   5. demo_bootstrap.gd（最后，demo + DCEcsScheduler 整合）
#
# ─── 原始入口说明（保留）────────────────────────────────────────────────
#
# 程序入口：生成地图并通过 HexRenderer 显示，提供顶部 UI 控制重新生成
# 控制：
#   右键拖拽 — 平移
#   滚轮     — 缩放
#   F        — 适配视口
#   R        — 用新随机种子重新生成
#   Space    — 暂停/继续游戏内时间

extends Node2D

# ─── DOTS ECS scheduler — preload via const to bypass class_name scan order.
# 用 preload 而不是裸 class_name DCEcsScheduler / DCEcsJob 是因为：
#   * scripts/ecs/ 目录是后加的，class_name 注册依赖 .godot/global_script_class_cache.cfg
#     刷新；首次启动尚未刷新时 main.gd 会 parse fail。
#   * preload 常量在编辑器和运行时都立刻可用，不依赖任何全局扫描。
const DCEcsScheduler := preload("res://scripts/ecs/dc_ecs_scheduler.gd")
const DCEcsJob := preload("res://scripts/ecs/dc_ecs_job.gd")

# 0.4.2 — InfoPanelController 抽出（main.gd 拆分推荐顺序 step 1）。
# ~340 行右侧地块信息面板（_refresh_info_panel 系列 + 5 个文字档位 helper +
# 5 个 emergent_* 懒创建 Label）已搬至 ui/info_panel_controller.gd。
# main.gd 的 6 个 _refresh_* / _ensure_emergent_labels 入口降级为 1 行 forward；
# 5 个 _emergent_*_label 字段、5 个 _vitality_band 等 helper 均已删除。
const InfoPanelControllerScript = preload("res://scripts/ui/info_panel_controller.gd")

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
@onready var _debug_btn: Button = $UI/TopBar/HBox/DebugBtn
@onready var _regen_btn: Button = $UI/TopBar/HBox/RegenBtn
@onready var _fit_btn: Button = $UI/TopBar/HBox/FitBtn
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
# 性能 Mini HUD：右上角常驻迷你性能浮窗（FPS / SUS total / largest job / fast_tick）。
# 默认 visible=true，快捷键 F4 切换显隐。0.25s 刷新，复用 main.gd 已有 getter，不引入新统计。
@onready var _perf_mini_hud: PanelContainer = $UI/PerfMiniHUD
# Overlay 图例（Legend）：在地图左下角显示当前通道的色带 / 离散列表，
# 只在 _overlay_mode != NONE 时可见。mouse_filter=IGNORE，不拦截地图输入。
@onready var _overlay_legend: PanelContainer = $UI/OverlayLegend

# 0.4.2 — 5 个 emergent_*_label 已搬到 InfoPanelController（懒创建仍在那里）。
# main.gd 不再持有这些 Label 引用。

var _current_map: MapData = null
var _generator: MapGenerator = null

# DOTS-Total-CPP C.4 acceptance 队列（已删除，dots-flag-prune-pr1，2026-05-22）。
# 原 _c4_acceptance_queue 与 start_soak_ab_phase_c4_acceptance_debug 一同删除。

# DOTS-Final-Push 任务 9：startup acceptance 日志一次性标记。首次 generate
# 完成后打印 DCDotsCompletionGate 的 5 段状态行 + evaluate() BLOCK 警告。
# R 键重新生成不再重复打印（避免刷屏）。
var _dots_final_push_logged: bool = false
var _world_data: WorldData = null
# B.1 (dots-migration-roadmap §3 B2)：info_panel / overlay 等只读消费者
# 通过 ViewAdapter 读 schema-mirrored 字段，不直接 cell.<field>。CellViewAdapter
# 内部直读 HexCell 强类型成员，行为等价。每次 _current_map 重新赋值时
# 同步 invalidate（_rebuild_view_adapter）。
var _view_adapter: DCViewAdapter = null
# PR-3.4.1（M4 拆分）：dots / DCFlagBus / DataCore wiring 委派给 bootstrap 类。
var _dots_bootstrap: DCDotsBootstrap = null
# 0.4.2 — info panel controller（_ready 时实例化；持有所有右侧面板 Label refs
# + 5 个 emergent_* 懒创建 Label + refresh_* 方法）。
var _info_panel_controller: InfoPanelControllerScript = null
var _last_seed: int = 0
var _last_time_label_hour: int = -1
# 当前选中地块（重新生成地图时清空，避免持有旧 MapData 的 cell 引用）
var _selected_cell: HexCell = null

# ─── DataCore CLI 缓存（dots-foundation-and-weather-migration）────
# dots-flag-prune-pr1 (2026-05-22)： use_data_core / use_data_core_weather flag
# 已删除——DataCore 现恒走单路径，--data-core / --no-data-core /
# --data-core-weather / --no-data-core-weather / --validate-weather 四个 CLI 开关
# 随之废弃（仅保留 --soak-dump=）。
# DCSoakDump CLI（dots-storage-同源紧急修复 2026-05-14）：
# --soak-dump=N[:mode[:path]]，例如 --soak-dump=30 / --soak-dump=30:full /
# --soak-dump=30:summary:user://soak/with_dc.tsv。空字符串=未启用。
var _cli_soak_dump_arg: String = ""

# ─── Validate-Weather 桶（已废弃）──────────────────────────────
# 原机制依赖 use_data_core_weather 在运行期 F9 翻转以在同一进程内对比 legacy /
# data_core 两条路径。dots-flag-prune-pr1 (2026-05-22)：该 flag 已删除——
# DataCore 现恒走单路径，validate-weather 机制随之废弃。
# Emergent Climate Coupling：fast tick 性能打点计数（需求 6.2 合计耗时节流 WARN）
var _fast_tick_count: int = 0
# DOTS-Final-Push 任务 10：200 tick 滚动采样，给 DCDotsFinalPushPerfVerdict 用。
# fast tick 主循环每帧追加 fast_ms，超过 PERF_VERDICT_WINDOW 时丢最旧。
# warn 计数同窗口对齐——每次 trigger_warn 命中都 +1，落入旧窗口外时随
# total_ms 数组同步丢弃。
const PERF_VERDICT_WINDOW: int = 200
var _perf_verdict_total_ms: Array = []
var _perf_verdict_warn_marks: Array = []  # 与 _perf_verdict_total_ms 平行：bool 数组
var _last_weather_fronts_diff: Dictionary = {}
var _fast_tick_warn_last_frame: int = 0
var _slow_tick_count: int = 0

# Plan: perf-recording-csv-export
# DebugConsole 录制按钮注入的 PerfRecorder 实例。null = 当前未挂载或未录制；
# 主循环只做"非空时调 on_fast_tick"的快路径，避免污染主类。具体录制逻辑、
# CSV 拼装、状态机全部在 scripts/ui/perf_recorder.gd 内。
var _perf_recorder: RefCounted = null
# DebugConsole 地块数据录制按钮注入的 TileDataRecorder 实例。与 PerfRecorder
# 共用 fast_tick sample 时机，但 recorder 自己从 MapData 读取 cell-level SoA。
var _tile_data_recorder: RefCounted = null

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

	# 0.4.2 — info panel controller 实例化（在 _generate_and_render 之前，
	# 否则首次重生成结束时如果 _select_cell 触发 refresh_info_panel 会 NRE）。
	# 静态 Label refs 都已 @onready 完毕；动态上下文（map / generator / view_adapter）
	# 在 _generate_and_render / _rebuild_view_adapter 末尾 push。
	_info_panel_controller = InfoPanelControllerScript.new({
		"right_panel": _right_panel,
		"pos": _pos_label,
		"elev": _elev_label,
		"climate_zone": _climate_zone_label,
		"temp": _temp_label,
		"moist": _moist_label,
		"precip": _precip_label,
		"landform": _landform_label,
		"vegetation": _vegetation_label,
		"vitality": _vitality_label,
		"cover": _cover_label,
		"weather": _weather_label,
		"feature": _feature_label,
		"mobility": _mobility_label,
		"history": _history_label,
	})
	_info_panel_controller.set_world_clock(_world_clock)
	_info_panel_controller.set_sea_level(sea_level)
	_info_panel_controller.set_hex_size(hex_size)

	# Pass 2：TOD 中枢必须在 _generate_and_render 前实例化，
	# 因为首次 set_map 会触发 _push_visual_toggles → apply_tod 首帧推送。
	_init_tod_profile()
	# DataCore CLI 解析（dots-foundation-and-weather-migration）：
	# 在 _generate_and_render 之前应用 --data-core / --no-data-core /
	# --data-core-weather / --no-data-core-weather / --validate-weather，
	# 这些开关会写到 ClimateProfile（经 MapGenerator._c() 暴露）。
	# 注：generator 此时尚未 new，先把 CLI 结果缓存，等 _generate_and_render
	# 创建 generator 后立即应用。
	_parse_data_core_cli()
	_generate_and_render(initial_seed)
	# DataCore CLI：generator 已创建，把 CLI 缓存覆盖到 ClimateProfile。
	_apply_data_core_cli_to_profile()
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

	# PerfMiniHUD：常驻迷你性能浮窗，右上角显示 FPS / SUS / fast_tick。
	if _perf_mini_hud != null and _perf_mini_hud.has_method("set_main"):
		_perf_mini_hud.set_main(self)

	# PR-3.4.1（M4 拆分）：DCFlagBus 安装委托给 DCDotsBootstrap。
	# main 节点不再持有 _on_dcflag_changed；hot-reload 回调由 bootstrap 类承担。
	# bootstrap 实例必须保留（class member）以保持 connect 生命周期；否则 RefCounted
	# 释放后 signal 断开。
	_dots_bootstrap = DCDotsBootstrap.new(self)
	_dots_bootstrap.bootstrap_flag_bus()

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
			regenerate_debug_map()
		KEY_F:
			fit_debug_map()
		KEY_SPACE:
			_world_clock.toggle_pause()
			_sync_pause_btn()
			_sync_clock_running_to_weather_layer()
		KEY_QUOTELEFT, KEY_F1:
			# Debug 控制台开合（需求 4.1）。反引号/波浪键 或 F1
			# 都能切换可见性。面板 mouse_filter=STOP，点击在面板内
			# 的时候不会穿透选中地块。
			toggle_debug_console()
		KEY_F4:
			# 2026-05-19：Mini Perf HUD 显隐切换（右上角常驻浮窗）。
			toggle_perf_mini_hud()
		KEY_F8:
			# Emergent Climate Coupling + True Insolation-Driven：一键切换"纯回退模式"。
			toggle_emergent_debug_switches()
		KEY_F6:
			# 任务 9：切换 ocean_current_debug uniform（高/低对比流线）
			toggle_ocean_current_debug()
		KEY_F7:
			# Systemic Ocean Currents：ocean_heat_debug 轻量控制台打印
			diagnose_ocean_heat()
		KEY_F9:
			# dots-flag-prune-pr1 (2026-05-22)： use_data_core_weather flag 已删除——
			# DataCore weather mirror 现恒走单路径，F9 hot-toggle 不再生效。
			print("[DataCore] F9 deprecated: use_data_core_weather flag removed (single-path).")
		KEY_F10:
			# dots-flag-prune-pr1 (2026-05-22)： use_data_core master flag 已删除——
			# DataCore 现恒挂载，F10 master toggle 不再生效。
			print("[DataCore] F10 deprecated: use_data_core flag removed (single-path).")
		KEY_F2:
			# DCSoakDump 一键启动（dots-storage-同源紧急修复 2026-05-14）：
			# 30 tick SUMMARY mode 写到 user://soak/manual_<timestamp>.tsv。
			# F10 原本绑 use_data_core master toggle，dots-flag-prune-pr1 删除后改用 F2。
			# 已在跑则忽略（避免互相覆盖）。
			_soak_dump_hotkey_start()
		KEY_F3:
			# DCSoakABRunner 一键 A/B 对比（dots-storage-同源紧急修复 2026-05-14）：
			#   F3         — SAME_SOURCE mode 30 tick：A/B 都用当前 DataCore 状态（默认推荐）
			#                验证 storage 在稳态下的可重复性，threshold=1e-4 期望 PASS
			#   Shift+F3   — VS_LEGACY mode 30 tick：A=current, B=toggle 后状态
			#                对比 DataCore vs legacy 业务等价性，threshold=0.5
			#   Ctrl+F3    — SAME_SOURCE mode **1000 tick**（B3b 阶段 3 收工验收 / 长期均值）
			#                建议在 x20 速度下使用：1000 tick × 2 段 = 2000 sim-tick ≈ 100 s
			#   Alt+F3     — 立即 cancel 当前 A/B 流程（解卡用）。无 active 流程时 nop。
			# 总耗时 ≈ N tick × 2 段 × 当前游戏速度（x1 → 60s/30tick；x20 → 3s/30tick）。
			print("[soak-ab] F3 pressed (shift=%s ctrl=%s alt=%s)" % [
				str(event.shift_pressed), str(event.ctrl_pressed), str(event.alt_pressed)])
			if event.alt_pressed:
				_soak_ab_hotkey_cancel()
			elif event.ctrl_pressed and not event.shift_pressed:
				_soak_ab_hotkey_start(DCSoakABRunner.Mode.SAME_SOURCE, 1000)
			elif event.shift_pressed:
				_soak_ab_hotkey_start(DCSoakABRunner.Mode.VS_LEGACY)
			else:
				_soak_ab_hotkey_start(DCSoakABRunner.Mode.SAME_SOURCE)
		KEY_F11:
			# Print current DataCore world bind / entity / component snapshot.
			_print_data_core_flag_snapshot()
		KEY_F12:
			# dots-flag-prune-pr1 (2026-05-22)：--validate-weather 机制已随
			# use_data_core_weather flag 一同废弃。F12 仅打印废弃提示。
			_validate_weather_print_snapshot()

# ─── 移动端调试按钮入口 ─────────────────────────────────────────────────

func toggle_debug_console() -> void:
	if _debug_console != null:
		_debug_console.visible = not _debug_console.visible


# 2026-05-19：Mini Perf HUD 显隐切换。
# 默认 visible=true（一启动就能看到性能数据），F4 隐藏后内部 timer 也会停。
func toggle_perf_mini_hud() -> void:
	if _perf_mini_hud != null and _perf_mini_hud.has_method("toggle_visible"):
		_perf_mini_hud.toggle_visible()

func _mark_debug_console_state_dirty() -> void:
	if _debug_console != null and _debug_console.has_method("request_state_sync"):
		_debug_console.call("request_state_sync")

func regenerate_debug_map() -> void:
	_generate_and_render(0)

func fit_debug_map() -> void:
	if _camera != null:
		_camera.fit_to_viewport(1.05, _map_safe_area())

func toggle_emergent_debug_switches() -> void:
	if _generator == null:
		print("[Emergent+Insolation] generator not ready, ignored.")
		return
	var cp = _generator._c()
	if cp == null:
		print("[Emergent+Insolation] ClimateProfile missing, ignored.")
		return
	var fallback: bool = bool(cp.emergent_season_enabled)
	var new_state: bool = not fallback
	cp.emergent_season_enabled = new_state
	cp.enable_local_climate_coupling = new_state
	cp.emergent_weather_coupling = new_state
	cp.fast_slow_layering_enabled = new_state
	cp.true_insolation_enabled = new_state
	print("[Emergent+Insolation] 5 switches → %s" % str(new_state))
	if _renderer != null and _renderer.has_method("set_true_insolation_enabled"):
		_renderer.set_true_insolation_enabled(new_state)
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
	if _current_map != null and _world_clock != null:
		_generator.refresh_climate_daily(_current_map, _world_clock.season_phase())
		_refresh_emergent_lines()
	_mark_debug_console_state_dirty()

func toggle_ocean_current_debug() -> void:
	if _renderer != null and _renderer.has_method("set_ocean_current_debug"):
		var cur: bool = _renderer.get_ocean_current_debug()
		_renderer.set_ocean_current_debug(not cur)
		print("[VisualOverhaul] ocean_current_debug = %s" % str(not cur))
	_mark_debug_console_state_dirty()

func toggle_data_core_weather_debug() -> void:
	# dots-flag-prune-pr1 (2026-05-22)：stub kept for debug_console.gd compatibility.
	print("[DataCore] toggle deprecated: use_data_core_weather flag removed (single-path).")

func toggle_data_core_master_debug() -> void:
	# dots-flag-prune-pr1 (2026-05-22)：stub kept for debug_console.gd compatibility.
	print("[DataCore] toggle deprecated: use_data_core flag removed (single-path).")

func start_soak_dump_debug() -> void:
	_soak_dump_hotkey_start()

func start_soak_ab_same_source_debug(n_ticks: int = 30) -> void:
	_soak_ab_hotkey_start(DCSoakABRunner.Mode.SAME_SOURCE, n_ticks)

func start_soak_ab_vs_legacy_debug() -> void:
	_soak_ab_hotkey_start(DCSoakABRunner.Mode.VS_LEGACY)

# ─── 已删除验收入口（dots-flag-prune-pr1，2026-05-22）──────────────────────
# 以下 debug 入口随 ClimateProfile flag 一同删除：
#   - start_soak_ab_season_round_batch_debug（use_gdext_season_round 已删）
#   - start_soak_ab_sus_scheduler_batch_debug（use_gdext_sus_scheduler 已删）
#   - start_soak_ab_phase_c4_acceptance_debug（依赖 unified_fast_tick /
#     system_schedule / season_round 三个已删 flag 的 batch 入口）
#   - _on_c4_batch_completed / _try_start_next_c4_batch / _c4_acceptance_queue

## DOTS-Total-CPP C.3d/C.3e 直接验收入口：跑两段（30 + 1000 tick）SAME_SOURCE A/B
## （A=use_gdext_thread_fallback off / B=on），覆盖全部 5 个 _thread 入口：
##   climate Pass-B / ocean_water / ocean_land / sea_ice / vegetation_dynamics
## 预期：bit-equal（reduce 严格按 task_idx 升序，无 race），N≥2400 + WTP 可用时
## thread on 略快或持平。
func start_soak_ab_thread_batch_debug() -> void:
	if DCSoakABRunner.instance != null \
			and (DCSoakABRunner.instance.is_running() or DCSoakABRunner.instance.is_batch_active()):
		print("[main] thread batch ignored: A/B runner already running")
		return
	if DCSoakABRunner.instance == null:
		DCSoakABRunner.instance = DCSoakABRunner.new()
	var ok: bool = DCSoakABRunner.instance.start_thread_batch(self)
	if not ok:
		print("[main] start_thread_batch failed (generator not ready?)")


func cancel_soak_debug() -> void:
	_soak_ab_hotkey_cancel()

func print_data_core_flags_debug() -> void:
	_print_data_core_flag_snapshot()

func print_validate_weather_snapshot_debug() -> void:
	_validate_weather_print_snapshot()

func print_perf_verdict_debug() -> void:
	request_dots_final_push_perf_verdict()

# ─── 时间 UI 绑定 ───────────────────────────────────────────────────────

func _wire_time_ui() -> void:
	_debug_btn.pressed.connect(toggle_debug_console)
	_regen_btn.pressed.connect(regenerate_debug_map)
	_fit_btn.pressed.connect(fit_debug_map)
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
	var cp = _generator._c() if _generator.has_method("_c") else null
	var auto_weather_stride: bool = true
	if cp != null and cp.get("weather_refresh_auto_stride_by_speed") != null:
		auto_weather_stride = bool(cp.weather_refresh_auto_stride_by_speed)
	if auto_weather_stride:
		var stride: int = 1
		if new_speed >= 15.0:
			stride = 8
		elif new_speed >= 3.0:
			stride = 4
		else:
			stride = 1
		_generator.set_weather_refresh_stride(stride)
	# 抽动修复（2026-05-18）：切档瞬间 weather_layer 内的 snapshot_interval 估计
	# 会因为"上次 push 到现在"的墙钟差变得不真实（x20→x1 时尤其严重），导致下
	# 一次 set_weather_fronts 算出超长 blend_duration → 云第一段几乎不动。重置
	# pacing 让下一次 push 从 INITIAL_BLEND_SEC 重启 IIR。
	if _renderer != null:
		var wl = _renderer.get_node_or_null("WeatherLayer")
		if wl != null and wl.has_method("reset_snapshot_pacing"):
			wl.reset_snapshot_pacing()

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

	# Perf instrumentation freshness（方案 ④ Step 1）：在跑 SUS 之前把"本帧将要
	# 变成的 fast_tick_idx"（即 _fast_tick_count + 1）同步给 generator/DVA，让
	# 所有 _last_*_breakdown 写入点能打上 _tick_idx 戳。perf_recorder.on_fast_tick
	# 拿到的 sample.tick_idx 也是 _fast_tick_count + 1（见 _fast_tick_count += 1
	# 在 fast tick 末尾，sample 在那之后构造），两侧对齐。
	if _generator != null and _generator.has_method("set_current_fast_tick_idx"):
		_generator.set_current_fast_tick_idx(_fast_tick_count + 1)

	# Sliced Update Scheduler（任务 8）：完整收编后 fast tick 的全部模拟工作
	# 都在这里一次性驱动。返回字典：{ fronts: Array[WeatherFront], weather_ran: bool }。
	# weather_ran=false 表示本日被 weather_refresh_job.policy（StridePolicy）跳过，
	# 这条信息被用来抑制 UI 的 weather/vitality/climate/emergent 四行刷新——
	# 等价于此前的 was_skipped_day 行为。
	var sus_result: Dictionary = {}
	if _generator != null and _world_clock != null:
		sus_result = _generator.sus_tick_daily(_world_clock)
	# ───────────────────────────────────────────────────────────────────
	# Reference-impl Pass #2 (demo-only, performance-charter §12.6)。
	# 仅在 ClimateProfile.demo_thermal_gradient_enabled = true 时启用：
	#   1) C++ 距 run_thermal_gradient_pass——读 cell_temp / cell_elevation，
	#      写 cell_demo_thermal_gradient（都是 bind_map_data 阶段共享 CoW 的同一
	#      块 buffer，无需额外 push）。
	#   2) 为防 CoW 后续被 GDScript 侧 mutator 意外 detach，调用后用 snapshot_f32
	#      拉一份赋回 map.demo_thermal_gradient_arr 以驱动 baker 重 bake。
	# 开关为 false 时这里全部跳过，overlay 下拉菜单也不应呈现该项。
	# ───────────────────────────────────────────────────────────────────
	_run_demo_thermal_gradient_pass_if_enabled()
	var weather_ran: bool = bool(sus_result.get("weather_ran", false))
	var was_skipped_day: bool = not weather_ran
	var fronts: Array[WeatherFront] = sus_result.get("fronts", [] as Array[WeatherFront])
	# Drift-fix（2026-05-10）：weather_ran 在 SUS 双 tick 切片下，stage_a/stage_b 都为真——
	# 但 _last_fronts 只在 stage_b 真正翻新。fronts_changed 区分了"slice 跑了"和
	# "fronts 数据真的变了"。下方 set_weather_fronts gate 必须用 fronts_changed，
	# 否则 stage_a tick 会把上一份 fronts 重推一次 → weather_layer reset blend +
	# forward-bias 算出"起点≈终点"→ 云冻结。
	var fronts_changed: bool = bool(sus_result.get("fronts_changed", false))
	var fronts_diff: Dictionary = sus_result.get("fronts_diff", {})
	_last_weather_fronts_diff = fronts_diff.duplicate(true)
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
		# 2026-05-18 P1-B：主地形材质需要看到 world.weather_field_tex 的最新内容，
		# 让海面分支按 hex 真值做风暴变色 + 风浪条纹（weather_layer 仍走 null 路径）。
		if _renderer.has_method("refresh_terrain_weather_field_tex"):
			_renderer.refresh_terrain_weather_field_tex()
		if _renderer.has_method("sync_weather_fronts_signature") and not fronts_diff.is_empty():
			_last_weather_fronts_diff["renderer"] = _renderer.sync_weather_fronts_signature(fronts, fronts_diff)
		elif fronts_changed:
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
	var sus_budget_warn: bool = t_sus_ms > 1.0
	var trigger_warn: bool = (not was_skipped_day) and (fast_ms > 12 or sus_budget_warn) \
		and (_fast_tick_warn_last_frame == 0 or (_fast_tick_count - _fast_tick_warn_last_frame) >= 30)
	if trigger_warn:
		push_warning("[fast tick] frame=%d total=%dms sus=%.2fms render=%.2fms ui=%.2fms cells=%d budgets(total>12ms or sus>1ms)" % [
			_fast_tick_count, fast_ms, t_sus_ms, t_render_ms, t_ui_ms,
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

	# DOTS-Final-Push 任务 10：把当前 tick 的 fast_ms 与 trigger_warn 标记
	# 推入滚动窗口（PERF_VERDICT_WINDOW=200），供 request_dots_final_push_perf_verdict()
	# 一键产出 verdict。跳日（was_skipped_day）的 tick 不计入窗口——它本就
	# 是低成本路径，与稳态门槛验收无关（需求 6.1~6.3 都是非跳日）。
	if not was_skipped_day:
		_perf_verdict_total_ms.append(float(fast_ms))
		_perf_verdict_warn_marks.append(trigger_warn)
		while _perf_verdict_total_ms.size() > PERF_VERDICT_WINDOW:
			_perf_verdict_total_ms.pop_front()
			_perf_verdict_warn_marks.pop_front()

	# Plan: perf-recording-csv-export + tile-data debug recording
	# 把本帧 main 局部才知道的指标（三段 ms / 跳日标志 / fps / 时间戳）发布给
	# 已挂接的录制器。PerfRecorder 自己拉 SUS breakdown；TileDataRecorder
	# 自己拉 MapData SoA。未挂载或未录制时内部早返，跳日帧也录入。
	_publish_fast_tick_perf_sample(t_sus_ms, t_render_ms, t_ui_ms,
		float(fast_ms), was_skipped_day)


# Plan: perf-recording-csv-export
# 把"只有 fast_tick 局部知道"的指标打包成 sample 字典，转发给已挂接的录制器。
# 不持有 recorder 引用或未录制时直接 return，零开销快路径。
func _publish_fast_tick_perf_sample(t_sus_ms: float, t_render_ms: float,
		t_ui_ms: float, fast_ms: float, was_skipped_day: bool) -> void:
	var perf_ready: bool = _recorder_ready(_perf_recorder)
	var tile_ready: bool = _recorder_ready(_tile_data_recorder)
	if not perf_ready and not tile_ready:
		return
	var sample: Dictionary = {
		"tick_idx": _fast_tick_count,
		"timestamp_ms": Time.get_ticks_msec(),
		"was_skipped_day": was_skipped_day,
		"fps": Engine.get_frames_per_second(),
		"fast_ms": fast_ms,
		"t_sus_ms": t_sus_ms,
		"t_render_ms": t_render_ms,
		"t_ui_ms": t_ui_ms,
	}
	if perf_ready:
		_perf_recorder.call("on_fast_tick", sample)
	if tile_ready:
		_tile_data_recorder.call("on_fast_tick", sample)


func _recorder_ready(rec: RefCounted) -> bool:
	if rec == null:
		return false
	if not rec.has_method("on_fast_tick"):
		return false
	if rec.has_method("is_recording") and not bool(rec.call("is_recording")):
		return false
	return true


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
	if _generator.has_method("sus_report_last_tick_summary"):
		var summary: Dictionary = _generator.sus_report_last_tick_summary()
		if not summary.is_empty():
			print("    sus_window p95=%.2fms max=%.2fms over1ms=%d largest=%s/%s/%s path=%s %.2fms" % [
				float(summary.get("sus_sim_p95_300", 0.0)),
				float(summary.get("sus_sim_max_300", 0.0)),
				int(summary.get("over_1ms_count_300", 0)),
				str(summary.get("largest_slice_job", "")),
				str(summary.get("largest_slice_stage", "")),
				str(summary.get("largest_slice_substage", "")),
				str(summary.get("largest_slice_path", "")),
				float(summary.get("largest_slice_ms", 0.0)),
			])
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
					print("        A=%.1f B=%.1f ocean=%.1f sea_ice=%.1f ice_bake=%.1f transp=%.1f cells=%d pass=%s partial=%s dirty=%.2f visited=%.2f path=%s" % [
						float(b.get("pass_a_ms", 0.0)),
						float(b.get("pass_b_ms", 0.0)),
						float(b.get("ocean_ms", 0.0)),
						float(b.get("sea_ice_ms", 0.0)),
						float(b.get("ice_bake_ms", 0.0)),
						float(b.get("transp_ms", 0.0)),
						int(b.get("cells", 0)),
						str(b.get("current_pass", "")),
						str(b.get("partial", false)),
						float(b.get("dirty_ratio", 1.0)),
						float(b.get("visited_ratio", 1.0)),
						str(b.get("pass_b_path", "full")),
					])
					# DataCore: climate sub-pass 取数路径标识（B-1）
					# dots-flag-prune-pr1 (2026-05-22)： use_data_core_climate flag 已删除。
					# Climate 现恒走 DataCore 单路径：
					#   data_core             — World 已 bind + 25 个 comp_id 全部缓存
					#   data_core_cells_only  — World 已 bind，但 comp_id 还未缓存好
					#   legacy                — World 还没绑定（启动早期 fallback）
					var _dcc_path: String = "legacy"
					var _dcc_w = _generator.get_data_core_world() if _generator.has_method("get_data_core_world") else null
					if _dcc_w != null and _dcc_w.is_bound():
						var _cjob = _generator._refresh_climate_daily_job if "_refresh_climate_daily_job" in _generator else null
						if _cjob != null and _cjob.has_method("data_core_ready") and _cjob.data_core_ready():
							_dcc_path = "data_core"
						else:
							_dcc_path = "data_core_cells_only"
					# I1.A-1: 与 weather "path=..." 对齐，便于 grep / A-B 桶聚合（保留旧 dc=
					# 字段一并打印以兼容历史 ab_test*.log 解析脚本）
					print("        climate path=%s dc=%s" % [_dcc_path, _dcc_path])
					# Ocean pass C++ vs fallback diag：当本片是 ocean_water / ocean_land
					# 时附带 gdext runs / fallbacks / last rc，定位"为何 fallback"
					var _cur_pass: String = str(b.get("current_pass", ""))
					if _cur_pass == "ocean_land" or _cur_pass == "ocean_water":
						var _ocp_runs: int = -1
						var _ocp_fb: int = -1
						var _ocp_total_ms: float = -1.0
						var _ocp_flag: bool = false
						var _ocp_field_runs: String = ""
						var _ocp_field_fb: String = ""
						var _ocp_field_total: String = ""
						if _cur_pass == "ocean_land":
							_ocp_field_runs = "_gdext_ocean_land_runs"
							_ocp_field_fb = "_gdext_ocean_land_fallbacks"
							_ocp_field_total = "_gdext_ocean_land_total_ms"
						else:
							_ocp_field_runs = "_gdext_ocean_water_runs"
							_ocp_field_fb = "_gdext_ocean_water_fallbacks"
							_ocp_field_total = "_gdext_ocean_water_total_ms"
						if _ocp_field_runs in _generator:
							_ocp_runs = int(_generator.get(_ocp_field_runs))
						if _ocp_field_fb in _generator:
							_ocp_fb = int(_generator.get(_ocp_field_fb))
						if _ocp_field_total in _generator:
							_ocp_total_ms = float(_generator.get(_ocp_field_total))
						# dots-flag-prune-pr1: use_gdext_ocean_water/land flags were removed;
						# these passes are now constant-on when ext+method probes succeed.
						_ocp_flag = true
						var _ocp_avg: float = (_ocp_total_ms / float(_ocp_runs)) if _ocp_runs > 0 else 0.0
						print("        %s gdext flag=%s runs=%d fallbacks=%d avg_native=%.2fms" % [
							_cur_pass, str(_ocp_flag), _ocp_runs, _ocp_fb, _ocp_avg,
						])
					if str(b.get("current_pass", "")) == "sea_ice" and "_last_sea_ice_daily_breakdown" in _generator:
						var sid: Dictionary = _generator._last_sea_ice_daily_breakdown
						if not sid.is_empty():
							print("        sea_ice_daily path=%s pack=%.1f refresh=%.1f native=%.3f native_wall=%.1f sync=%.1f flip=%.1f total=%.1f water=%d flipped=%d" % [
								str(sid.get("path", "")),
								float(sid.get("pack_ms", 0.0)),
								float(sid.get("refresh_ms", 0.0)),
								float(sid.get("native_ms", -1.0)),
								float(sid.get("native_wall_ms", 0.0)),
								float(sid.get("sync_ms", 0.0)),
								float(sid.get("flip_ms", 0.0)),
								float(sid.get("total_wall_ms", 0.0)),
								int(sid.get("water", 0)),
								int(sid.get("flipped", 0)),
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
					if wb.has("job_total_ms"):
						print("        weather_job total=%.1f prelude=%.1f begin=%.1f run_slice=%.1f direct_a=%.1f commit=%.1f stage_b=%.1f sync=%.1f soak=%.1f unattributed=%.1f" % [
							float(wb.get("job_total_ms", 0.0)),
							float(wb.get("prelude_ms", 0.0)),
							float(wb.get("begin_stage_a_ms", 0.0)),
							float(wb.get("run_stage_a_slice_ms", 0.0)),
							float(wb.get("stage_a_direct_ms", 0.0)),
							float(wb.get("commit_stage_a_ms", 0.0)),
							float(wb.get("stage_b_outer_ms", 0.0)),
							float(wb.get("sync_fronts_ms", 0.0)),
							float(wb.get("soak_dump_ms", 0.0)),
							float(wb.get("job_unattributed_ms", 0.0)),
						])
					if wb.has("field_commit_total_ms"):
						print("        weather_commit inner=%.1f setup=%.1f loop=%.1f dc=%.1f conv=%.1f dist=%.1f summary=%.1f" % [
							float(wb.get("field_commit_total_ms", 0.0)),
							float(wb.get("field_commit_setup_ms", 0.0)),
							float(wb.get("field_commit_loop_ms", 0.0)),
							float(wb.get("field_commit_dc_ms", 0.0)),
							float(wb.get("field_commit_convergence_ms", 0.0)),
							float(wb.get("distribute_ms", 0.0)),
							float(wb.get("field_summary_ms", 0.0)),
						])
					# DataCore: 末尾 path 标记，方便 A/B 对照（plan 任务 10）
					# dots-flag-prune-pr1 (2026-05-22)： use_data_core_weather flag 已删除。
					# Weather 现恒走 DataCore 单路径 ; path 仔细仅反映 World bind + comp_id
					# 缓存状态。
					var _dc_path: String = "legacy"
					var _dc_w = _generator.get_data_core_world() if _generator.has_method("get_data_core_world") else null
					if _dc_w != null and _dc_w.is_bound():
						var _wjob = _generator._weather_refresh_job if "_weather_refresh_job" in _generator else null
						if _wjob != null and _wjob.has_method("data_core_ready") and _wjob.data_core_ready():
							_dc_path = "data_core"
						else:
							_dc_path = "data_core_cells_only"
					print("        weather path=%s" % _dc_path)
					# dots-flag-prune-pr1 (2026-05-22)：--validate-weather 机制已废弃。
			if job_id == &"enum_atlas_upload" and _generator != null \
					and _generator.has_method("sus_enum_atlas_breakdown"):
				var eb: Dictionary = _generator.sus_enum_atlas_breakdown()
				if not eb.is_empty():
					print("        enum_atlas_upload axis=%s path=%s elapsed=%.2f patch=%.2f img=%.2f upload=%.2f dirty=%dpx/%dcells cache=%s pending_cv=%s pending_vg=%s" % [
						str(eb.get("axis", "")),
						str(eb.get("path", "unknown")),
						float(eb.get("elapsed_ms", 0.0)),
						float(eb.get("buffer_patch_ms", 0.0)),
						float(eb.get("image_ms", 0.0)),
						float(eb.get("upload_ms", 0.0)),
						int(eb.get("dirty_pixels", 0)),
						int(eb.get("dirty_cells", 0)),
						str(eb.get("cache_valid", false)),
						str(eb.get("cover_pending", false)),
						str(eb.get("vegetation_pending", false)),
					])
			# DOTS-Final-Push 任务 6.2：sea_ice_atlas_upload 拆 prepare/upload 子段。
			# 之前日志只看到 ran=232ms slices=1 progress=0.5 但完全不知道这 232ms
			# 是卡在 prepare（C++ run_sea_ice_atlas_prepare / GD 全图 28800 像素回扫）
			# 还是 upload（28KB R8 纹理 update）。本钩子把两段拆出来 + path（gdext/
			# gdscript/zero_fallback）+ dirty_cells/dirty_ratio 一并打印，让下次跑日志
			# 直接看到瓶颈源。
			if job_id == &"sea_ice_atlas_upload" and _generator != null \
					and _generator.has_method("sus_sea_ice_atlas_breakdown"):
				var sib: Dictionary = _generator.sus_sea_ice_atlas_breakdown()
				if not sib.is_empty():
					print("        sea_ice_atlas phase=%s path=%s prep=%.2f img=%.2f upload=%.2f dirty=%d/%.2f" % [
						str(sib.get("phase", "")),
						str(sib.get("path", "unknown")),
						float(sib.get("prepare_ms", 0.0)),
						float(sib.get("image_ms", 0.0)),
						float(sib.get("upload_ms", 0.0)),
						int(sib.get("dirty_cells", 0)),
						float(sib.get("dirty_ratio", 0.0)),
					])
			if job_id == &"season_refresh" and _generator != null \
					and _generator.has_method("sus_season_refresh_breakdown"):
				var sb: Dictionary = _generator.sus_season_refresh_breakdown()
				if not sb.is_empty():
					print("        season_refresh stages=%s" % [str(sb)])

func _on_season_changed(_season_idx: int) -> void:
	_refresh_time_label()
	# 2026-05-18：season_refresh 改为 SeasonRefreshJob 自驱周期重算（默认每 30
	# tick 一次），不再绑定到 WorldClock.season_changed 信号脉冲。游戏世界里
	# 温度 / 降水 / 风 / 海冰已由 refresh_climate_daily 每天连续推进，"季节切换"
	# 退化为 UI 概念。仅在 ClimateProfile.season_refresh_legacy_signal=true（回归
	# 对照路径）时，main.gd 才会主动 queue_season_refresh。
	if _generator != null and _current_map != null and _world_data != null:
		var cp = _generator._c() if _generator.has_method("_c") else null
		var use_legacy: bool = false
		if cp != null and "season_refresh_legacy_signal" in cp:
			use_legacy = bool(cp.season_refresh_legacy_signal)
		if _renderer != null and _renderer.has_method("begin_season_transition"):
			_renderer.begin_season_transition(_world_clock.season_phase())
		if use_legacy:
			var t0 := Time.get_ticks_msec()
			if _generator.has_method("queue_season_refresh"):
				_generator.queue_season_refresh(_season_idx)
			else:
				_generator.refresh_seasonal(_current_map, _world_data, _season_idx)
			print("Season refresh queued %dms (legacy signal path)" % (Time.get_ticks_msec() - t0))
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
	# 0.4.2 — 新地图就位后立即把 map / generator / sea_level 推给 info panel
	# controller。view_adapter 在 _rebuild_view_adapter 内部已 push。
	if _info_panel_controller != null:
		_info_panel_controller.set_current_map(_current_map)
		_info_panel_controller.set_generator(_generator)
		_info_panel_controller.set_sea_level(sea_level)
	# B.1 / B.3：地图新生成 → 重建 ViewAdapter
	# B.3：根据 DCFeatureFlags.use_world_view_adapter 决定走 .Cell（默认，legacy）
	# 还是 .World（DOTS 路径）。World 实现要求 DCWorld 已 bind_map_data；
	# 否则 silently 退到 Cell 实现（带一次 warning）。
	_rebuild_view_adapter()
	_last_seed = result.get("seed", seed_val)
	# DOTS thermal-gradient: a new map means archetypes (LAND/OCEAN) must be
	# re-synced from the freshly populated `is_water_arr`. The next entry into
	# the ECS_ARCHETYPE path will re-do create_archetype + assign_archetype.
	_dc_ecs_archetype_dirty = true
	_dc_ecs_land_archetype_id = -1
	# Sliced Update Scheduler（任务 4）：把 world_clock 入口注入给 SUS，
	# OceanCurrentsJob 需要 season_phase 连续浮点作为 phase 输入。
	if _world_clock != null:
		_generator.set_world_clock_ref(_world_clock)
	var elapsed: int = Time.get_ticks_msec() - t0

	_renderer.hex_size = hex_size
	_renderer.set_map(_current_map, _world_data)
	# 方案 0：把 MapBaker 喂给 renderer，让 F6 切到 ocean_current_debug 时
	# 能 lazy bake upwelling_tex（commit 路径已不再无条件烘焙）。
	if _renderer.has_method("set_map_baker") and _generator != null and "_baker" in _generator:
		_renderer.set_map_baker(_generator._baker)

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
		_info_label.text = "%dx%d  cells=%d  bake=%dms  touch: Debug / Regen / Fit" % [
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

	# DOTS-Final-Push 任务 9：首次 generate 完成后，把本计划新增 5 段的
	# flag 启用状态 + 验收门槛打一次到控制台；任一 required 段未达成时
	# 走 evaluate() 并打印 [DOTS-Final-Push] BLOCK 警告。R 键重新生成
	# 地图不再重复打印（避免刷屏）。
	if not _dots_final_push_logged and _generator != null:
		_dots_final_push_logged = true
		var _cp_for_gate = _generator._c() if _generator.has_method("_c") else null
		if _cp_for_gate != null:
			for _line in DCDotsCompletionGate.format_acceptance_lines(_cp_for_gate):
				print(_line)
			var _failures: Array = DCDotsCompletionGate.evaluate(_cp_for_gate)
			for _f in _failures:
				push_warning(String(_f))

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
	# 0.4.2 — controller 持有自己的 _selected_cell 副本；这里同步推一次。
	if _info_panel_controller != null:
		_info_panel_controller.set_selected_cell(cell)
	_ensure_emergent_labels()
	_refresh_info_panel()
	# Legend 指针：选中后把当前 cell 的通道值映射到色带位置。
	_update_overlay_pointer_for_cell()
	# 面板弹出后地图可见区域变窄，重新 fit 一次让整张地图仍完整显示
	if _camera != null:
		_camera.fit_to_viewport(1.05, _map_safe_area())

func _clear_selection() -> void:
	_selected_cell = null
	# 0.4.2 — 同步清掉 controller 的 selection（否则 refresh_* 会读到旧 cell 引用）
	if _info_panel_controller != null:
		_info_panel_controller.set_selected_cell(null)
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

# 0.4.2 — main.gd 拆分推荐顺序 step 1：refresh_info_panel 系列已搬到
# [`ui/info_panel_controller.gd`](ui/info_panel_controller.gd)。
# 6 个 forwarder 保留 main 命名空间内的旧 api（_refresh_info_panel /
# _refresh_weather_line / _refresh_climate_line / _refresh_vitality_line /
# _ensure_emergent_labels / _refresh_emergent_lines），其余 callsite 零改动。
# 5 个文字档位 helper（_vitality_band / _elevation_band / _climate_zone_name /
# _temperature_band / _moisture_band）+ 5 个 _emergent_* Label 字段已完全删除。
func _refresh_info_panel() -> void:
	if _info_panel_controller == null:
		return
	_info_panel_controller.refresh_info_panel()


func _refresh_weather_line() -> void:
	if _info_panel_controller == null:
		return
	_info_panel_controller.refresh_weather_line()


func _refresh_climate_line() -> void:
	if _info_panel_controller == null:
		return
	_info_panel_controller.refresh_climate_line()


func _refresh_vitality_line() -> void:
	if _info_panel_controller == null:
		return
	_info_panel_controller.refresh_vitality_line()


func _ensure_emergent_labels() -> void:
	if _info_panel_controller == null:
		return
	_info_panel_controller.ensure_emergent_labels()


func _refresh_emergent_lines() -> void:
	if _info_panel_controller == null:
		return
	_info_panel_controller.refresh_emergent_lines()


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

# ─── Reference-impl Pass #2 helpers (demo-only, performance-charter §12.6) ───
# _is_demo_thermal_gradient_enabled / _run_demo_thermal_gradient_pass_if_enabled
# 是参考实现的"接入主流程模板"。如果未来要把这套通信契约升级为真实游戏机制，
# 应该在这里复制一套（替换为真实 component / pass / map field 名）。

# 首次诊断打印去重表：每条 reason 仅打印一次，避免每帧刷屏。
var _demo_tg_diag_seen: Dictionary = {}
var _demo_tg_first_run_logged: bool = false
# Pass #3：每 tick 耗时打印的单调计数器 + 过预算守门标志。
var _demo_complex_tick_counter: int = 0
var _demo_complex_over_budget_warned: bool = false

# ─── DOTS thermal-gradient dispatch state ─────────────────────────────
# Lazily constructed when ClimateProfile.demo_thermal_gradient_path != LEGACY.
# `_dc_ecs_scheduler` is reused across ticks; jobs are rebuilt each tick (cheap)
# because comp_ids and archetype filters can change after a map regenerate.
# `_dc_ecs_archetype_dirty` flips to true after a map regenerate so the
# ECS_ARCHETYPE path knows to re-create + reassign archetypes from
# `_current_map.is_water_arr`. The scheduler itself is stateless across maps.
var _dc_ecs_scheduler = null  # DCEcsScheduler
var _dc_ecs_archetype_dirty: bool = true
var _dc_ecs_land_archetype_id: int = -1
var _dc_ecs_path_label_seen: Dictionary = {}

func _demo_tg_diag_once(reason: String) -> void:
	if _demo_tg_diag_seen.has(reason):
		return
	_demo_tg_diag_seen[reason] = true
	push_warning("[demo_thermal_gradient] pass skipped — " + reason)

func _is_demo_thermal_gradient_enabled() -> bool:
	if _generator == null or not _generator.has_method("_c"):
		return false
	var cp = _generator._c()
	if cp == null:
		return false
	if not ("demo_thermal_gradient_enabled" in cp):
		return false
	return bool(cp.demo_thermal_gradient_enabled)


func _run_demo_thermal_gradient_pass_if_enabled() -> void:
	if not _is_demo_thermal_gradient_enabled():
		_demo_tg_diag_once("disabled (ClimateProfile.demo_thermal_gradient_enabled=false or no _c())")
		return
	if _current_map == null or _generator == null:
		_demo_tg_diag_once("no current_map / generator")
		return
	if not _generator.has_method("get_data_core_world_ext"):
		_demo_tg_diag_once("generator lacks get_data_core_world_ext (legacy build?)")
		return
	var ext = _generator.get_data_core_world_ext()
	if ext == null:
		_demo_tg_diag_once("DCWorldExt is null (gdext not loaded)")
		return  # gdext 未加载（fallback 到纯 GDScript）；此 demo 无 GDScript fallback
	# Pass #3：优先调用 run_demo_complex_pass；旧 .dll 不带新方法时回退到 Pass #2 老入口。
	var has_complex: bool = ext.has_method("run_demo_complex_pass")
	if not has_complex and not ext.has_method("run_thermal_gradient_pass"):
		# C++ 端两条 pass 都不存在（极旧构建产物），静默跳过避免噪音
		_demo_tg_diag_once("DCWorldExt missing both run_demo_complex_pass and run_thermal_gradient_pass (stale .dll)")
		return
	var cp = _generator._c()
	var gain: float = float(cp.demo_thermal_gradient_elevation_gain) if cp != null else 1.5
	var k: float = float(cp.demo_thermal_gradient_normalize_k) if cp != null else 0.5
	# Pass #3 4 个新旋钮——cp 为空或字段不存在时 fallback 到 C++ 默认值。
	var iter: int = 16
	var kr: int = 2
	var coriolis: float = 0.5
	var drag: float = 0.6
	if cp != null:
		if "demo_complex_iterations" in cp:
			iter = int(cp.demo_complex_iterations)
		if "demo_complex_kernel_radius" in cp:
			kr = int(cp.demo_complex_kernel_radius)
		if "demo_complex_coriolis_strength" in cp:
			coriolis = float(cp.demo_complex_coriolis_strength)
		if "demo_complex_terrain_drag" in cp:
			drag = float(cp.demo_complex_terrain_drag)
	var w: int = int(_current_map.width)
	var h: int = int(_current_map.height)
	# ─── 关键：bind_map_data 之后 CoW 已分裂，C++ 端 s.arr_f32 与 GDScript 端
	# map.temp_arr / elevation_arr 不再共享；按 docs/performance-charter §11
	# 的官方契约，GDScript→C++ 必须用 write_f32_range 显式 push。
	# 否则 C++ 永远读到 bind 那一瞬的初值（很可能全 0），输出也就全 0。
	if ext.has_method("component_id") and ext.has_method("write_f32_range"):
		var cid_t: int = int(ext.component_id(&"cell_temp"))
		var cid_e: int = int(ext.component_id(&"cell_elevation"))
		if cid_t >= 0:
			ext.write_f32_range(cid_t, 0, _current_map.temp_arr)
		if cid_e >= 0:
			ext.write_f32_range(cid_e, 0, _current_map.elevation_arr)
	# C++ 端读 cell_temp / cell_elevation slot（已由上面的 write_f32_range 同步），
	# 写 cell_demo_thermal_gradient slot，pass 末尾通过 snapshot_f32 取回。
	# Pass #3 测时用 Time.get_ticks_usec()，含 pass 主体 + 不含 snapshot 的两段。
	#
	# ─── DOTS path dispatch ───────────────────────────────────────────
	# `demo_thermal_gradient_path` 三选一（详见 ClimateProfile.DemoTGPath）：
	#   * LEGACY        → 旧手写直调，零调度开销，是 pre-DOTS 基线。
	#   * ECS           → 用 DCEcsScheduler 单 job 跑同一个 kernel；输出与
	#                     LEGACY 路径 bit-equal（kernel 完全相同，只是多一层
	#                     拓扑排序 + Callable 调用）。
	#   * ECS_ARCHETYPE → DCEcsScheduler + run_demo_complex_pass_archetyped
	#                     (target=LAND)。OCEAN cells 输出被置 0；视觉上能
	#                     看到水陆边界，性能差距和 vanilla 相比由 A1 实验
	#                     描述（stencil 类算子收益 ≈ 0）。
	var path_id: int = 0  # default LEGACY
	if cp != null and "demo_thermal_gradient_path" in cp:
		path_id = int(cp.demo_thermal_gradient_path)
	var path_label: String = "legacy"
	var t0_cpp: int = Time.get_ticks_usec()
	if path_id == 0 or not has_complex:
		# LEGACY (also used as fallback when run_demo_complex_pass is missing).
		path_label = "legacy"
		if has_complex:
			ext.run_demo_complex_pass(w, h, iter, kr, coriolis, drag, gain, k)
		else:
			ext.run_thermal_gradient_pass(w, h, gain, k)
	else:
		# ECS / ECS_ARCHETYPE — both go through DCEcsScheduler.
		path_label = "ecs" if path_id == 1 else "ecs_archetype"
		_run_demo_tg_via_ecs(ext, w, h, iter, kr, coriolis, drag, gain, k, path_id)
	var cpp_us: int = Time.get_ticks_usec() - t0_cpp
	# 路径首次进入时打一行诊断，方便确认 ClimateProfile 配置生效。
	if not _dc_ecs_path_label_seen.has(path_label):
		_dc_ecs_path_label_seen[path_label] = true
		print("[demo_thermal_gradient] dispatch path=%s (path_id=%d)" % [path_label, path_id])
	# CoW 共享下 ptrw 已就地写入；再 snapshot 一次确保 GDScript 侧 detach 安全
	# （避免 CoW 在被 GDScript mutate 后引用别处的副本）。开销 ~ 一次 memcpy。
	if not ext.has_method("snapshot_f32") or not ext.has_method("component_id"):
		_demo_tg_diag_once("DCWorldExt missing snapshot_f32 / component_id")
		return
	var cid: int = int(ext.component_id(&"cell_demo_thermal_gradient"))
	if cid < 0:
		_demo_tg_diag_once("component_id(cell_demo_thermal_gradient) < 0 — slot not registered")
		return
	var snap: PackedFloat32Array = ext.snapshot_f32(cid)
	_current_map.demo_thermal_gradient_arr = snap
	# ─── Pass #3 每 tick 耗时打印（紧凑诊断）─────────────────────────
	# 第一次还多打一行 inputs 行（沿用 Pass #2 既有 _demo_tg_first_run_logged 守门）。
	_demo_complex_tick_counter += 1
	var s_n: int = snap.size()
	var s_min: float = INF
	var s_max: float = -INF
	var s_sum: float = 0.0
	for i in range(s_n):
		var v: float = snap[i]
		if v < s_min: s_min = v
		if v > s_max: s_max = v
		s_sum += v
	var s_mean: float = (s_sum / float(s_n)) if s_n > 0 else 0.0
	var kernel_label: String = "demo_complex" if has_complex else "demo_thermal_gradient"
	var pass_label: String = kernel_label + "/" + path_label
	print("[" + pass_label + "] tick=#" + str(_demo_complex_tick_counter)
		+ " w=" + str(w) + " h=" + str(h)
		+ " iter=" + str(iter) + " kr=" + str(kr)
		+ " coriolis=" + String.num(coriolis, 3)
		+ " drag=" + String.num(drag, 3)
		+ " cpp=" + str(cpp_us) + " µs"
		+ " out[min=" + String.num(s_min, 4)
		+ " max=" + String.num(s_max, 4)
		+ " mean=" + String.num(s_mean, 4) + "]")
	# 过预算守门：单 tick > 16 ms 仅在第 1 次发生时 push_warning，避免每帧刷屏
	if cpp_us > 16000 and not _demo_complex_over_budget_warned:
		_demo_complex_over_budget_warned = true
		push_warning("[" + pass_label + "] cpp=" + str(cpp_us)
			+ " µs > 16 ms budget — consider lowering demo_complex_iterations or kernel_radius")
	# 第一次跑完 pass 后看看输出范围 + 输入范围。
	# 如果输出 max==0 但输入 cell_temp/cell_elevation 也是全 0，说明 climate Pass-A 没填温度场。
	if not _demo_tg_first_run_logged:
		_demo_tg_first_run_logged = true
		# 输入端：从 _current_map 读 temp_arr / elevation_arr（这是 GDScript 端
		# 的当前真值；上面已经用 write_f32_range 把它们推给 C++ slot，所以
		# C++ pass 读到的就是这同一份数据）。
		var t_arr: PackedFloat32Array = _current_map.temp_arr
		var e_arr: PackedFloat32Array = _current_map.elevation_arr
		var t_min: float = INF; var t_max: float = -INF; var t_sum: float = 0.0
		for i in range(t_arr.size()):
			var tv: float = t_arr[i]
			if tv < t_min: t_min = tv
			if tv > t_max: t_max = tv
			t_sum += tv
		var t_mean: float = (t_sum / float(t_arr.size())) if t_arr.size() > 0 else 0.0
		var e_min: float = INF; var e_max: float = -INF; var e_sum: float = 0.0
		for i in range(e_arr.size()):
			var ev: float = e_arr[i]
			if ev < e_min: e_min = ev
			if ev > e_max: e_max = ev
			e_sum += ev
		var e_mean: float = (e_sum / float(e_arr.size())) if e_arr.size() > 0 else 0.0
		print("[" + pass_label + "] first run OK — input temp[n=" + str(t_arr.size())
			+ " min=" + String.num(t_min, 4) + " max=" + String.num(t_max, 4)
			+ " mean=" + String.num(t_mean, 4) + "] elevation[n=" + str(e_arr.size())
			+ " min=" + String.num(e_min, 4) + " max=" + String.num(e_max, 4)
			+ " mean=" + String.num(e_mean, 4) + "]")


# ─── DOTS thermal-gradient ECS dispatch helpers ───────────────────────
# Build a one-shot scheduler with a single demo_thermal_gradient job and
# tick it. The bit-equal contract is:
#   * ECS path        ≡ LEGACY path (same kernel, scheduler is a pure shim).
#   * ECS_ARCHETYPE   ≠ LEGACY (zeros OCEAN cells; only LAND-cells comparable
#                       and even those are re-normalized — see A1 §2.3).
#
# `path_id` mapping mirrors ClimateProfile.DemoTGPath:
#   1 → ECS, 2 → ECS_ARCHETYPE.
func _run_demo_tg_via_ecs(ext: Object, w: int, h: int, iter_count: int, kr: int,
		coriolis: float, drag: float, gain: float, k: float, path_id: int) -> void:
	# Lazy scheduler instantiation — one shared instance across ticks.
	if _dc_ecs_scheduler == null:
		_dc_ecs_scheduler = DCEcsScheduler.new()

	# ECS_ARCHETYPE: ensure archetypes exist + are assigned from the current
	# water mask. We treat the assignment as one-shot per map (re-done when
	# `_dc_ecs_archetype_dirty` is set externally on regenerate).
	var land_arch_id: int = -1
	if path_id == 2:
		if not (ext.has_method("create_archetype") and ext.has_method("assign_archetype")):
			_demo_tg_diag_once("ECS_ARCHETYPE: DCWorldExt missing create_archetype / assign_archetype — falling back to ECS")
			path_id = 1
		elif not ext.has_method("run_demo_complex_pass_archetyped"):
			_demo_tg_diag_once("ECS_ARCHETYPE: DCWorldExt missing run_demo_complex_pass_archetyped — falling back to ECS")
			path_id = 1
		else:
			if _dc_ecs_archetype_dirty or _dc_ecs_land_archetype_id < 0:
				_dc_ecs_land_archetype_id = _dc_ecs_sync_archetypes(ext)
				_dc_ecs_archetype_dirty = false
			land_arch_id = _dc_ecs_land_archetype_id

	# Build the single-job graph each tick: comp_ids are stable across ticks
	# but cheap to look up; this keeps the path resilient to mid-game
	# component re-registration if it ever happens.
	var cid_temp: int = int(ext.component_id(&"cell_temp"))
	var cid_elev: int = int(ext.component_id(&"cell_elevation"))
	var cid_out: int = int(ext.component_id(&"cell_demo_thermal_gradient"))
	if cid_temp < 0 or cid_elev < 0 or cid_out < 0:
		_demo_tg_diag_once("ECS dispatch: component_id < 0 (temp=%d elev=%d out=%d)"
			% [cid_temp, cid_elev, cid_out])
		# Fall back to legacy direct call — never silently no-op.
		ext.run_demo_complex_pass(w, h, iter_count, kr, coriolis, drag, gain, k)
		return

	_dc_ecs_scheduler.clear()
	var runner: Callable
	var arch_filter: int
	if path_id == 2:
		runner = Callable(self, "_dc_ecs_run_demo_complex_archetyped")
		arch_filter = land_arch_id
	else:
		runner = Callable(self, "_dc_ecs_run_demo_complex")
		arch_filter = -1

	var job := DCEcsJob.new(
		&"demo_thermal_gradient",
		[cid_temp, cid_elev],
		[cid_out],
		runner,
		arch_filter,
		{}
	)
	_dc_ecs_scheduler.add_job(job)

	var ctx: Dictionary = {
		"ext": ext,
		"w": w, "h": h,
		"iter": iter_count, "kr": kr,
		"coriolis": coriolis, "drag": drag,
		"gain": gain, "k": k,
	}
	_dc_ecs_scheduler.tick(ctx)


# Re-create archetypes (LAND, OCEAN) and assign every cell from
# `_current_map.is_water_arr`. Returns the LAND archetype id.
# Called only when `_dc_ecs_archetype_dirty` flips true (initial entry +
# after map regenerate).
func _dc_ecs_sync_archetypes(ext: Object) -> int:
	var land_id: int = int(ext.create_archetype(&"LAND", []))
	var ocean_id: int = int(ext.create_archetype(&"OCEAN", []))
	if _current_map == null:
		return land_id
	var mask: PackedByteArray = _current_map.is_water_arr
	var n: int = mask.size()
	# ─── BUGFIX: C++-side `_entity_count` must be ≥ n before assign_archetype ───
	# Production path never calls `ext.create_pool("cells", n)` (only the bench
	# does). DCWorldExt::assign_archetype silently drops `idx >= _entity_count`,
	# leaving `_entity_archetype` empty; the archetyped pass then early-returns
	# with a `_entity_archetype size < n` warning and writes nothing → overlay
	# all-zero. Top up entity_count to n here. `create_entities` is additive,
	# so guard against the rare case where front-pool or future systems already
	# pushed it past n.
	var ec: int = int(ext.entity_count()) if ext.has_method("entity_count") else 0
	if ec < n:
		ext.create_entities(n - ec)
	for i in range(n):
		if mask[i] != 0:
			ext.assign_archetype(i, ocean_id)
		else:
			ext.assign_archetype(i, land_id)
	print("[demo_thermal_gradient/ecs_archetype] archetypes synced — "
		+ "n=" + str(n)
		+ " entity_count_before=" + str(ec)
		+ " entity_count_after=" + str(ext.entity_count() if ext.has_method("entity_count") else -1)
		+ " land_id=" + str(land_id) + " ocean_id=" + str(ocean_id))
	return land_id


# Job runners (Callable targets). Signature: (ctx, job) -> void.
func _dc_ecs_run_demo_complex(ctx: Dictionary, _job) -> void:
	var ext: Object = ctx["ext"]
	ext.run_demo_complex_pass(
		int(ctx["w"]), int(ctx["h"]),
		int(ctx["iter"]), int(ctx["kr"]),
		float(ctx["coriolis"]), float(ctx["drag"]),
		float(ctx["gain"]), float(ctx["k"]))


func _dc_ecs_run_demo_complex_archetyped(ctx: Dictionary, job) -> void:
	var ext: Object = ctx["ext"]
	ext.run_demo_complex_pass_archetyped(
		int(ctx["w"]), int(ctx["h"]),
		int(ctx["iter"]), int(ctx["kr"]),
		float(ctx["coriolis"]), float(ctx["drag"]),
		float(ctx["gain"]), float(ctx["k"]),
		int(job.archetype_filter))


func _apply_overlay_mode(mode: int) -> void:
	# 需求 6.4：防止快速连切残留旧 uniform——每次切换都强制 bake + 重绑 tex。
	# Reference-impl Pass #2 守门：DEMO_THERMAL_GRADIENT 开关关闭时，即便外部
	# 强行调到该 mode（例如旧存档 / 调试脚本），也要降级回退到 NONE 避免画错。
	if mode == OverlayMode.MODE.DEMO_THERMAL_GRADIENT \
			and not _is_demo_thermal_gradient_enabled():
		push_warning("[Overlay] DEMO_THERMAL_GRADIENT 开关已关，回退到 NONE")
		mode = 0
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
	var overlay_adapter: DCViewAdapter = _view_adapter
	if _generator != null and _generator.has_method("get_data_core_world"):
		var dc_world = _generator.get_data_core_world()
		if dc_world != null and dc_world.has_method("is_bound") and dc_world.is_bound():
			overlay_adapter = DCViewAdapter.World.new(dc_world, _current_map)
	result = DataOverlayBaker.bake(
		_current_map, _world_data, _overlay_mode, cp, phase, overlay_adapter
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
	# B.1：通过 ViewAdapter 读 schema-mirrored 字段
	var diag_idx: int = int(cell.index)
	var diag_ad: DCViewAdapter = _view_adapter
	var diag_t: float = diag_ad.get_temp(diag_idx) if diag_ad != null else float(cell.temperature)
	var diag_b: float = diag_ad.get_temp_baseline(diag_idx) if diag_ad != null else float(cell.temp_baseline)
	var diag_s: float = diag_ad.get_temp_season_offset(diag_idx) if diag_ad != null else float(cell.temp_season_offset)
	print("[Temp] cell(q=%d,r=%d) temperature=%.3f baseline=%.3f season_off=%.3f" % [
		cell.q, cell.r, diag_t, diag_b, diag_s
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

func get_sus_last_tick_report() -> Dictionary:
	if _generator == null or not _generator.has_method("sus_report_last_tick"):
		return {}
	var report: Dictionary = _generator.sus_report_last_tick()
	return report.duplicate(false)

func get_sus_last_tick_summary() -> Dictionary:
	if _generator == null or not _generator.has_method("sus_report_last_tick_summary"):
		return {}
	var summary: Dictionary = _generator.sus_report_last_tick_summary()
	return summary.duplicate(false)

func get_sim_breakdowns() -> Dictionary:
	var out: Dictionary = {}
	if _generator == null:
		return out
	if _generator.has_method("sus_climate_breakdown"):
		out["climate"] = _generator.sus_climate_breakdown()
	if _generator.has_method("sus_weather_breakdown"):
		out["weather"] = _generator.sus_weather_breakdown()
	if _generator.has_method("sus_enum_atlas_breakdown"):
		out["enum_atlas"] = _generator.sus_enum_atlas_breakdown()
	if _generator.has_method("sus_sea_ice_atlas_breakdown"):
		out["sea_ice_atlas"] = _generator.sus_sea_ice_atlas_breakdown()
	if _generator.has_method("sus_dynamic_visual_atlas_breakdown"):
		out["dynamic_visual_atlas"] = _generator.sus_dynamic_visual_atlas_breakdown()
	return out.duplicate(false)


func get_environment_perf_summary() -> Dictionary:
	var summary: Dictionary = get_sus_last_tick_summary()
	var out: Dictionary = {
		"target_avg_ms": 2.0,
		"target_p95_ms": 3.5,
		"target_max_ms": 5.0,
		"tick_idx": _fast_tick_count,
		"fast_ms": _overlay_last_fast_tick_ms,
		"map_cells": 0,
		"map_pixels": 0,
		"budget": {},
		"last_tick": summary,
		"window": {},
	}
	if _current_map != null and _current_map.has_method("cell_count"):
		out["map_cells"] = int(_current_map.cell_count())
	if _world_data != null and "derived_size" in _world_data:
		var ds: Vector2i = _world_data.derived_size
		out["map_pixels"] = int(ds.x * ds.y)
	if _generator != null and _generator.has_method("sus_report_sim_budget_window"):
		out["window"] = _generator.sus_report_sim_budget_window()
	if _generator != null and _generator.has_method("environment_runtime_status"):
		out["environment_runtime"] = _generator.environment_runtime_status()
	out["budget"] = {
		"sim_frame_budget_ms": float(summary.get("sim_frame_budget_ms", 0.0)),
		"sim_slice_budget_ms": float(summary.get("sim_slice_budget_ms", 0.0)),
		"sim_upload_slice_budget_ms": float(summary.get("sim_upload_slice_budget_ms", 0.0)),
		"sim_strict_budget_enabled": bool(summary.get("sim_strict_budget_enabled", false)),
		"sim_budget_warn_ms": float(summary.get("sim_budget_warn_ms", 0.0)),
		"economy_reserved_budget_ms": float(summary.get("economy_reserved_budget_ms", 0.0)),
	}
	return out


# Plan: perf-recording-csv-export
# DebugConsole 在 set_main 时实例化 PerfRecorder 并注入；fast_tick 末尾会把本帧
# 指标 forward 给 recorder.on_fast_tick。传 null 等价于卸载（PerfRecorder 自身会
# 留在 DebugConsole 持有，避免 GC）。
func set_perf_recorder(rec: RefCounted) -> void:
	_perf_recorder = rec


func get_perf_recorder() -> RefCounted:
	return _perf_recorder


func set_tile_data_recorder(rec: RefCounted) -> void:
	_tile_data_recorder = rec


func get_tile_data_recorder() -> RefCounted:
	return _tile_data_recorder


# DOTS-Final-Push 任务 10：终端稳态指标 verdict 入口。
#
# 用法：
#   - 启动游戏在 2400 cells 基线运行 ≥ 200 fast tick 后，从 debug_console 或
#     脚本调用 get_tree().root.get_node("...Main").request_dots_final_push_perf_verdict()
#   - 函数内部读 PERF_VERDICT_WINDOW 滚动窗口（最多 200 tick 的 fast_ms / warn 标记）
#     + 透传 SUS scheduler `_stats` 全表 → DCDotsFinalPushPerfVerdict.evaluate()
#   - 把结构化 verdict Dictionary 返回给调用方，并把 format_verdict_lines 的可读
#     报告打印到控制台
#
# 验收门槛（与 plan/dots-final-push/requirements.md §6 一致）：
#   - 2400 cells 200 tick 中 fast tick WARN 占比 ≤ 0.5%
#   - total_ms p95 ≤ 12ms / p99 ≤ 20ms
#   - 任一 SUS job p95 ≤ 8ms（豁免 sea_ice_atlas_upload / enum_atlas_upload）
#   - 6400 cells 大地图 200 tick 中 WARN 占比 ≤ 5%
#
# 不达标时 verdict.fail_reasons 给出具体哪条门槛未达成 + next_bottleneck
# 字段标注次高瓶颈，作为下一轮 plan 的输入（不阻塞本计划按段验收）。
func request_dots_final_push_perf_verdict() -> Dictionary:
	var samples: Array = _perf_verdict_total_ms.duplicate()
	var warn_count: int = 0
	for marked in _perf_verdict_warn_marks:
		if bool(marked):
			warn_count += 1
	var sus_job_stats: Dictionary = {}
	if _generator != null and _generator.has_method("sus_report_job_stats"):
		sus_job_stats = _generator.sus_report_job_stats()
	var cells: int = 0
	if _current_map != null:
		cells = _current_map.cell_count()
	var verdict: Dictionary = DCDotsFinalPushPerfVerdict.evaluate(
		samples, warn_count, sus_job_stats, cells
	)
	for line in DCDotsFinalPushPerfVerdict.format_verdict_lines(verdict):
		print(line)
	return verdict

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
		# B.1：通过 ViewAdapter 读 wind_vector / ocean_current
		var ov_idx: int = int(_selected_cell.index)
		var ov_ad: DCViewAdapter = _view_adapter
		var vec: Vector2 = Vector2.ZERO
		var norm_max: float = 1.0
		match _overlay_mode:
			OverlayMode.MODE.WIND_DIR:
				vec = ov_ad.get_wind_vector(ov_idx) if ov_ad != null else _selected_cell.wind_vector
				# 与 baker 同源（DataOverlayBaker.WIND_SPEED_NORM_MAX = 1.7）
				norm_max = 1.7
			OverlayMode.MODE.OCEAN_CURRENT_DIR:
				vec = ov_ad.get_ocean_current(ov_idx) if ov_ad != null else _selected_cell.ocean_current
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
	# B.1：通过 ViewAdapter 读 temperature / moisture / base_moisture
	var ovs_idx: int = int(_selected_cell.index)
	var ovs_ad: DCViewAdapter = _view_adapter
	var v: float = NAN
	match _overlay_mode:
		OverlayMode.MODE.TEMPERATURE:
			var t_v: float = ovs_ad.get_temp(ovs_idx) if ovs_ad != null else float(_selected_cell.temperature)
			v = clampf(t_v, 0.0, 1.0)
		OverlayMode.MODE.PRECIPITATION:
			# 与 baker 同源的 1.5 上限（PRECIPITATION_NORM_MAX）
			var phase: float = _world_clock.season_phase() if _world_clock != null else 0.0
			var scale: float = 1.0
			if _generator != null:
				var cp = _generator._c()
				scale = DataOverlayBaker._moisture_scale_at_phase(cp, phase)
			var bm_v: float = ovs_ad.get_base_moisture(ovs_idx) if ovs_ad != null else float(_selected_cell.base_moisture)
			var precip: float = scale * bm_v
			v = clampf(precip / 1.5, 0.0, 1.0)
		OverlayMode.MODE.HUMIDITY:
			var m_v: float = ovs_ad.get_moisture(ovs_idx) if ovs_ad != null else float(_selected_cell.moisture)
			v = clampf(m_v, 0.0, 1.0)
		OverlayMode.MODE.VEGETATION_VITALITY:
			# vegetation_vitality 无 SoA 对位（HexCell-only），仍直读
			v = clampf(float(_selected_cell.vegetation_vitality), 0.0, 1.0)
	if is_nan(v):
		_overlay_legend.clear_pointer()
	else:
		_overlay_legend.update_pointer(v)


# ─── DataCore CLI Helpers（dots-foundation-and-weather-migration） ────────
# dots-flag-prune-pr1 (2026-05-22)：use_data_core / use_data_core_weather flag
# 已删除——DataCore 现恒走单路径。原 --data-core / --no-data-core /
# --data-core-weather / --no-data-core-weather / --validate-weather 五个 CLI
# 开关随之废弃（解析时打 deprecated 提示，不再写 ClimateProfile）。
# 仅保留 --soak-dump= CLI（DCSoakDump 路径独立于 flag）。
func _parse_data_core_cli() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	# 同时接受工程 cmdline_args（编辑器测试 / Godot 启动参数）
	for a in OS.get_cmdline_args():
		args.append(a)
	for arg in args:
		var s: String = String(arg)
		match s:
			"--data-core", "--no-data-core", \
			"--data-core-weather", "--no-data-core-weather", \
			"--validate-weather":
				print("[DataCore] %s deprecated: flag removed (single-path); ignored." % s)
			_:
				# 形如 --soak-dump=30 / --soak-dump=30:full:user://x.jsonl
				if s.begins_with("--soak-dump="):
					_cli_soak_dump_arg = s.substr("--soak-dump=".length())


# 应用阶段：generator 已创建。dots-flag-prune-pr1 后 ClimateProfile 已无相关
# flag；本函数仅保留 --soak-dump 启动逻辑（独立于 flag 表）。
func _apply_data_core_cli_to_profile() -> void:
	if _generator == null:
		return
	# DCSoakDump（dots-storage-同源紧急修复 2026-05-14）：CLI 启动 N tick dump。
	# generator 已经 _generate_and_render 完成，map / world 都就绪；hot path
	# 第一次跑（climate_daily_system._finalize_round）就会写第一条记录。
	if _cli_soak_dump_arg != "":
		if DCSoakDump.instance == null:
			DCSoakDump.instance = DCSoakDump.new()
		var ok: bool = DCSoakDump.instance.start_from_arg(_cli_soak_dump_arg, _generator)
		if not ok:
			push_warning("[main] --soak-dump=%s failed to start (see prior errors)" % _cli_soak_dump_arg)


## 调试 / Overlay：生成 DataCore 状态摘要供 SUS 周期日志附加。
func data_core_status_dict() -> Dictionary:
	var out: Dictionary = {
		"world_entities": 0,
		"world_components": 0,
		"bound": false,
	}
	if _generator == null:
		return out
	if not _generator.has_method("get_data_core_world"):
		return out
	var w = _generator.get_data_core_world()
	if w == null:
		return out
	out["world_entities"] = int(w.entity_count())
	out["world_components"] = int(w.component_count())
	out["bound"] = bool(w.is_bound())
	return out


# ─── DCSoakDump Hotkey (F2) ──────────────────────────────────────────────
# 一键启动 30 tick SUMMARY dump，写到 user://soak/manual_<timestamp>.tsv。
# CLI 已启 → 忽略；已在跑 → 忽略（不打断当前会话）。
func _soak_dump_hotkey_start() -> void:
	if _generator == null:
		print("[soak-dump] F2: generator not ready, ignored.")
		return
	if DCSoakDump.instance != null and DCSoakDump.instance.is_active():
		print("[soak-dump] F2: already running, ignored. (active=%s)" % str(DCSoakDump.instance.is_active()))
		return
	if DCSoakDump.instance == null:
		DCSoakDump.instance = DCSoakDump.new()
	var ts: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = "user://soak/manual_%s.tsv" % ts
	var ok: bool = DCSoakDump.instance.start(30, DCSoakDump.Mode.SUMMARY, path, _generator)
	if ok:
		print("[soak-dump] F2 started: 30 ticks → %s" % path)
	else:
		push_warning("[soak-dump] F2 start failed (see prior errors)")


# ─── DCSoakABRunner Hotkey (F3) ──────────────────────────────────────────
# 一键完整 A/B 对比工作流：
#   1) 用当前 DataCore 状态跑 N tick → phase A.tsv
#   2) (VS_LEGACY) toggle DataCore master / (SAME_SOURCE) 不切换
#   3) 跑 N tick → phase B.tsv
#   4) 内置 diff 报告（max mean_diff per field, top-15）
# 总耗时 ≈ 2N sim-ticks（按游戏速度档：x1 ≈ 60s/30tick, x5 ≈ 12s, x20 ≈ 3s）。
# 已在跑则忽略；建议在游戏速度 ≥ x5 时按以缩短总耗时。
#
# B3b 阶段 3 收工长期验收用 Ctrl+F3 → n_ticks=1000；在 x20 速度下 ≈ 100s。
func _soak_ab_hotkey_start(mode: int = DCSoakABRunner.Mode.SAME_SOURCE,
		n_ticks: int = 30) -> void:
	if _generator == null:
		print("[soak-ab] F3: generator not ready, ignored.")
		return
	if DCSoakABRunner.instance != null and DCSoakABRunner.instance.is_running():
		print("[soak-ab] F3: already running, ignored. (Alt+F3 取消当前流程)")
		return
	if DCSoakABRunner.instance == null:
		DCSoakABRunner.instance = DCSoakABRunner.new()
	var ok: bool = DCSoakABRunner.instance.start(self, n_ticks, mode)
	if not ok:
		push_warning("[soak-ab] F3 start failed (see prior errors)")


## Alt+F3 — 立即 cancel 当前 A/B 流程并 stop dump。
## 反卡死（2026-05-17）：当 dumper 自身把 weather wall 拉到 ~40ms+ 顶满 frame budget
## 导致 climate phase 长期 dep_pending starve、_remaining 不递减、dump 永不结束时，
## 用户可按 Alt+F3 强制解卡。同时 dump 内置 stall 守门会在 200 次同 day record 后
## 自动 abort（约 8s @ 40ms/tick），Alt+F3 是更快的手动出口。
func _soak_ab_hotkey_cancel() -> void:
	if DCSoakABRunner.instance != null and DCSoakABRunner.instance.is_running():
		DCSoakABRunner.instance.cancel()
		print("[soak-ab] Alt+F3: A/B runner cancelled by user")
		return
	if DCSoakDump.instance != null and DCSoakDump.instance.is_active():
		DCSoakDump.instance.stop()
		print("[soak-ab] Alt+F3: standalone DCSoakDump stopped by user")
		return
	print("[soak-ab] Alt+F3: nothing active to cancel")


## DCSoakABRunner 用 helper：返回当前 use_data_core 状态。
## main.gd 暴露给 runner 用，避免 runner 自己解析 ClimateProfile。
##
## dots-flag-prune-pr1 (2026-05-22)： use_data_core flag 已删除——DataCore 现
## 恒挂载，本 helper 返回常量 true（generator/world 未就绪时返 false作为 probe）。
func is_data_core_on() -> bool:
	if _generator == null:
		return false
	return true


# ─── DataCore Runtime Hot Toggles \u00b7 deprecated stubs ───────────────────
# dots-flag-prune-pr1 (2026-05-22)\uff1a use_data_core / use_data_core_weather flag
# 已删除——DataCore 现恒走单路径，原有 F9/F10 hot-toggle / F11 snapshot 改为
# 简化 stub。F11 仍打 world bind / entity / component 状态，便于 runtime 自检。

func _toggle_data_core_weather_runtime() -> void:
	print("[DataCore] toggle deprecated: use_data_core_weather flag removed (single-path).")

func _toggle_data_core_master_runtime() -> void:
	print("[DataCore] toggle deprecated: use_data_core flag removed (single-path).")

func _print_data_core_flag_snapshot() -> void:
	if _generator == null:
		print("[DataCore] F11: generator not ready.")
		return
	var status: Dictionary = data_core_status_dict()
	print("[DataCore] F11 snapshot: world bound=%s entities=%d components=%d (single-path; flags removed)" % [
		str(status.get("bound", false)),
		int(status.get("world_entities", 0)),
		int(status.get("world_components", 0)),
	])


# ─── Validate-Weather \u00b7 deprecated stubs ─────────────────────────────────
# dots-flag-prune-pr1 (2026-05-22)：原 --validate-weather 机制依赖 F9 翻
# use_data_core_weather 在同一进程内对比 legacy / data_core 两条路径。该 flag
# 已删除——validate-weather 整个 A/B 桶机制随之废弃。F12 / debug_console
# 入口保留为 stub 提示。

func _validate_weather_collect(_path: String, _wb: Dictionary) -> void:
	pass

func _validate_weather_print_snapshot() -> void:
	print(">>>VAL>>> deprecated: validate-weather buckets removed (single-path; use_data_core_weather flag deleted).")


# ─── Phase B.3 / dots-migration-roadmap §3 B2：ViewAdapter A/B 切换 ─────
# DCFeatureFlags.use_world_view_adapter 控制走 .Cell（默认）或 .World（DOTS 路径）。
# dots-flag-prune-pr1 (2026-05-22)： use_world_view_adapter 是唯一保留的 sentinel-true
# flag——ClimateProfile 字段已删，DCFeatureFlags.is_on() 返回 FLAGS 表中的 default=true。
# 依赖：
#   - .World 实现要求 _generator.get_data_core_world() 返回非空且 is_bound()=true（DCWorld.bind_map_data 已成功）；
#     否则 silently 退到 .Cell 实现并 push_warning 一次。
func _rebuild_view_adapter() -> void:
	if _current_map == null:
		_view_adapter = null
		return
	# 默认走 Cell（legacy 兼容路径）
	var adapter_kind: String = "Cell"
	# 如果 use_world_view_adapter=true 且 DCWorld 已就绪 → 走 World
	var cp = _generator._c() if _generator != null else null
	if cp != null and DCFeatureFlags.is_on(&"use_world_view_adapter", cp):
		var dc_world = _generator.get_data_core_world() if _generator != null and _generator.has_method("get_data_core_world") else null
		if dc_world != null and dc_world.has_method("is_bound") and dc_world.is_bound():
			# 修复 A（2026-05-14）：传入 _current_map 让 adapter 直读 map.<field>，
			# 避开 GDExtension CoW 后 view 缓存陈旧 → UI "极寒" bug。
			# 详见 docs/dots-f4-validation.md §2.2.b storage A/B 同源契约。
			_view_adapter = DCViewAdapter.World.new(dc_world, _current_map)
			adapter_kind = "World"
		else:
			push_warning("[main] use_world_view_adapter=true but DCWorld not bound; falling back to Cell adapter")
			_view_adapter = DCViewAdapter.Cell.new(_current_map.iter_cells())
	else:
		_view_adapter = DCViewAdapter.Cell.new(_current_map.iter_cells())
	# 0.4.2 — view adapter 重建后同步推给 info panel controller。
	if _info_panel_controller != null:
		_info_panel_controller.set_view_adapter(_view_adapter)
	if OS.is_debug_build():
		print("[main] view adapter rebuilt: kind=%s | %s" % [adapter_kind, _view_adapter.describe()])


# PR-3.4.1（M4 拆分）：_on_dcflag_changed 已迁至 DCDotsBootstrap；
# main 通过 _dots_bootstrap 委派持有 signal connection 生命周期。
