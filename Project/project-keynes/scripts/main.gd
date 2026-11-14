# main.gd
#
# ─── Phase G.3 / dots-full-migration §G.3 计划状态（2026-05-13）──────────
#
# 本文件当前 1901+ 行，dots-full-migration plan 目标拆完后 ≤ 400 行。
# 拆分目的地骨架（D.3 已就位 + 详细迁移规格在各骨架文件顶部）：
#
#   bootstrap/dots_bootstrap.gd          ← DCWorld + ViewAdapter + Scheduler 注册 +
#                                          DataCore CLI / hot-toggle / view_adapter rebuild
#   bootstrap/sus_systems_bootstrap.gd   ← runtime system diagnostics / future
#                                          bootstrap extraction（生产入口现恒走 DCSystemScheduler）
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
#   4. sus_systems_bootstrap.gd（runtime system diagnostics / future extraction）
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
const DailySimulationBreakdown = preload("res://scripts/diagnostics/daily_simulation_breakdown.gd")
const MainDebugToolsScript = preload("res://scripts/main/debug_tools.gd")
const MainSetupControlsScript = preload("res://scripts/main/setup_controls.gd")
const MainDiagnosticsScript = preload("res://scripts/main/diagnostics.gd")
const MainOverlayScript = preload("res://scripts/main/overlay.gd")
const MainMobileOverlayScript = preload("res://scripts/main/mobile_overlay.gd")
var _debug_component = MainDebugToolsScript.new()
var _setup_component = MainSetupControlsScript.new()
var _diagnostics_component = MainDiagnosticsScript.new()
var _overlay_component = MainOverlayScript.new()
var _mobile_component = MainMobileOverlayScript.new()


# ─── DOTS ECS scheduler — preload via const to bypass class_name scan order.
# 用 preload 而不是裸 class_name DCEcsScheduler / DCEcsJob 是因为：
#   * scripts/ecs/ 目录是后加的，class_name 注册依赖 .godot/global_script_class_cache.cfg
#     刷新；首次启动尚未刷新时 main.gd 会 parse fail。
#   * preload 常量在编辑器和运行时都立刻可用，不依赖任何全局扫描。
const DCEcsScheduler := preload("res://scripts/ecs/dc_ecs_scheduler.gd")
const DCEcsJob := preload("res://scripts/ecs/dc_ecs_job.gd")
const SOAK_DUMP_SCRIPT_PATH := "res://scripts/tools/dots_soak_dump.gd"
const SOAK_DUMP_MODE_SUMMARY := 0
const SOAK_AB_RUNNER_SCRIPT_PATH := "res://scripts/tools/dots_soak_ab_runner.gd"
const SOAK_AB_MODE_SAME_SOURCE := 0
const SOAK_AB_MODE_VS_LEGACY := 1
var _soak_dump_script = null
var _soak_dump_load_attempted: bool = false
var _soak_ab_runner_script = null
var _soak_ab_runner_load_attempted: bool = false

# 0.4.2 — InfoPanelController 抽出（main.gd 拆分推荐顺序 step 1）。
# ~340 行右侧地块信息面板（_refresh_info_panel 系列 + 5 个文字档位 helper +
# 5 个 emergent_* 懒创建 Label）已搬至 ui/info_panel_controller.gd。
# main.gd 的 6 个 _refresh_* / _ensure_emergent_labels 入口降级为 1 行 forward；
# 5 个 _emergent_*_label 字段、5 个 _vitality_band 等 helper 均已删除。
const InfoPanelControllerScript = preload("res://scripts/ui/info_panel_controller.gd")

const WORLD_SETUP_META := &"world_setup_config"
const WORLD_SETUP_SCENE_PATH := "res://scenes/world_setup.tscn"
const DEFAULT_CLIMATE_PROFILE_PATH := "res://data/world/earth_like.tres"
const MOBILE_NATIVE_DAILY_STRIDE_DAYS: int = 20
const MOBILE_NATIVE_DAILY_COMMIT_BUDGET_DAYS: int = 20
const MOBILE_NATURAL_RESOURCE_STRIDE_DAYS: int = 10
const MOBILE_DYNAMIC_VISUAL_ATLAS_STRIDE: int = 8
const MOBILE_WEATHER_FIELD_ADVECT_STEPS: int = 2
const WORLD_SETUP_CLIMATE_FIELDS := {
	"continent_warp_amp": true,
	"main_radius_min": true,
	"main_radius_max": true,
	"main_placement_min": true,
	"main_placement_max": true,
	"main_separation_factor": true,
	"satellite_radius_min": true,
	"satellite_radius_max": true,
	"satellites_per_main": true,
	"satellite_placement_min": true,
	"satellite_placement_max": true,
	"satellite_separation_factor": true,
	"offshore_amp": true,
	"edge_falloff_start": true,
	"edge_falloff_end": true,
	"edge_falloff_depth": true,
	"dist_field_weight": true,
	"noise_weight": true,
	"meso_weight": true,
	"macro_relief_weight": true,
	"ridge_boost_amp": true,
	"spl_iters": true,
	"spl_erodibility": true,
	"spl_uplift_rate": true,
	"moisture_land_base": true,
	"moisture_precip_gain": true,
	"moisture_continental_dry": true,
	"moisture_itcz_wet_strength": true,
	"moisture_itcz_center": true,
	"moisture_itcz_width": true,
	"moisture_stormtrack_wet_strength": true,
	"moisture_stormtrack_center": true,
	"moisture_stormtrack_width": true,
	"moisture_polar_dry_strength": true,
	"moisture_tropical_evap_boost": true,
	"moisture_itcz_recycle_strength": true,
	"moisture_itcz_convergence": true,
	"moisture_coastal_floor": true,
	"coastal_moisture_boost": true,
	"orographic_boost": true,
	"rain_shadow_threshold": true,
	"rain_shadow_factor": true,
	"rain_shadow_lookback": true,
	"lake_seed_freq": true,
	"lake_seed_threshold": true,
	"lake_seed_depth": true,
	"lake_seed_min_interior": true,
	"hydro_lake_min_cells": true,
	"hydro_lake_min_depth": true,
	"hydro_lake_min_volume": true,
	"river_channel_init_cells": true,
	"hydro_river_min_length": true,
	"max_volcanoes": true,
	"volcano_min_dist": true,
	"volcano_min_land_h": true,
	"native_daily_sim_stride": true,
	"native_daily_commit_lag_budget_days": true,
	"native_daily_sea_ice_spread_dt_cap_days": true,
}

@export var map_width: int = 60
@export var map_height: int = 40
@export var num_continents: int = 2
@export var continent_size: float = 0.9
@export var sea_level: float = 0.42
@export var river_count: int = 8
@export var hex_size: float = 22.0
@export var initial_seed: int = 0   # 0 = 随机
@export var generate_test_economy_data: bool = false
@export_enum("资源分层混合:0", "产能基线:1", "百人级:10", "千人级:100", "万人级:1000") \
var test_economy_population_scale: int = 0

# ─── Visual Presentation Overhaul（任务 1）：视觉总开关 ─────────────────
# 六个开关一起组成"可回退的分层视觉系统"：任何一项关闭都应退化到对应基线效果。
# 这里只存储值 + 在生成/信号触发时推给 renderer / weather_layer；具体 shader
# 分支由后续任务 3~9 接入。
@export_group("Visual Overhaul")
@export_range(0, 2, 1) var visual_quality: int = 1
# Mobile shader quality tier（2026-06-15）：三档编译时变体，控制 fragment shader
# 每像素 texture sample 预算。在 hex_renderer._load_shader 里 prepend
# `#define MOBILE_QUALITY_HIGH/MID/LOW` 到 shader code，让 GPU 实际编译三种
# 二进制变体。runtime `if` 无效（GPU warp 编译所有分支）。
#   0 = LOW   ≤4 sample/像素，纯 atlas 颜色 + 海陆判断
#   1 = MID   移动端瘦身：接近 LOW 成本，保留手动提档入口
#   2 = HIGH  移动端瘦身高档：保留手动提档入口，但不再跑桌面级水面/天气特效
# 桌面端不受此控制，走原 shader 代码（无 MOBILE_QUALITY_* define）。
@export_range(0, 2, 1) var mobile_quality_tier: int = 0
# -1=自动；0/1/2=启动页手动指定低/中/高。移动端自动档仍会优先 60 FPS。
@export_range(-1, 2, 1) var render_quality_mode: int = -1
# 移动端 terrain horizon 是可选高成本路径：默认关闭以保持 60 FPS。
# 启用后会打开 GPU horizon bake，并把移动端 shader 变体提升到 HIGH。
@export var mobile_terrain_horizon_enabled: bool = false
@export var day_night_enabled: bool = true
@export var extreme_weather_ground_effect_enabled: bool = true
# 性能采样日志开关：true 时 HexRenderer 内的 PerfSampler 会每 30 秒打印一次
# 平均帧时间 + P95，方便基线 / 优化前 / 优化后三次对齐。
@export var perf_sampler_enabled: bool = false

# ─── Cell-index 间接寻址（province-ID indirection，当前唯一动态视觉路径）────
# 地图生成会烘焙 map-index atlas（R=biome, GB=cell.index）+ per-cell LUT，让
# world_map shader 走"pixel→cell 间接寻址"渲染，把每日 atlas GPU 上传从
# n_pix(~62 万) 压到 n_cells(~2400)。当前 DCFeatureFlags.cell_indirection_active()
# 恒为 true，此导出值仅保留 Inspector 兼容。
@export var cell_indirection_enabled: bool = true

# 洋流 Flowmap 水面视觉。生成 RG8 洋流纹理供水面每像素一次采样；关闭时跳过视觉光栅与上传。
@export var ocean_current_visual_enabled: bool = true

# 旧 sea_ice_tex（R8）逐像素海冰贴图开关。默认 false=退役（已无任何 shader 采样者，
# 运行时 upload job 早已不注册，主海冰视觉由 shader 按水温派生）。关时 bake_world 不再
# encode 那张全零 R8（省 ~0.6MB），prepare/upload 全部 no-op。开为 true 仅为兼容旧调试 /
# 数据通道（dots_soak_dump 的 sea_ice_fraction_buffer 哈希）。**改勾选后需重新生成地图**。
@export var sea_ice_atlas_enabled: bool = false

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
# 雨雪粒子密度提升（任务 5 消费）
@export var rain_density_boost_enabled: bool = true
# 云层 TOD 染色（任务 6 消费，关闭后云层回到上一轮的 day_phase 色温逻辑）
@export var cloud_tod_tint_enabled: bool = true

# 水面 / 洋流 / 波浪参数不在这里：全部集中在 HexRenderer 的「海洋水面 · …」分组里，
# 那里是唯一来源（以前这里有一份副本，启动时覆盖渲染器的值，导致在渲染器上调参无效）。

@onready var _renderer: HexRenderer = $WorldRoot/HexRenderer
@onready var _camera: MapCamera = $MapCamera
@onready var _info_label: Label = $UI/TopBar/HBox/InfoLabel
@onready var _debug_btn: Button = $UI/TopBar/HBox/DebugBtn
@onready var _regen_btn: Button = $UI/TopBar/HBox/RegenBtn
@onready var _fit_btn: Button = $UI/TopBar/HBox/FitBtn
@onready var _setup_btn: Button = $UI/TopBar/HBox/SetupBtn
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
var _debug_tod_light_angle_deg: float = -60.0
var _debug_tod_light_elevation_deg: float = 37.0
var _debug_tod_sun_position: float = 0.25
var _debug_tod_sun_uv: Vector2 = Vector2(0.25, 0.5)
var _debug_tod_sun_height_scale: float = 1.0
var _debug_tod_sun_uv_override_enabled: bool = false
var _debug_tod_sun_handle_requested: bool = false
var _tod_sun_handle_btn: Button = null
var _tod_sun_handle_dragging: bool = false

# Splash overlay：bake_world 期间显示加载提示，避免移动端开场 ~13s 黑屏体感。
# 节点在 _ensure_splash_overlay() 里 lazy 创建，在 _generate_and_render 入口
# show + await 一帧让它能绘制，bake 结束后 hide。
var _splash_layer: CanvasLayer = null
var _splash_label: Label = null

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
var _visual_bootstrap: DCVisualBootstrap = null
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
const SPEED_PRESETS: Array = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0]
const MOBILE_TOPBAR_SAFE_TOP: float = 64.0
const MOBILE_TOPBAR_HEIGHT: float = 64.0
const MOBILE_EDGE_SAFE: float = 20.0
const MOBILE_BUTTON_HEIGHT: float = 56.0
var _perf_verdict_total_ms: Array = []
var _perf_verdict_warn_marks: Array = []  # 与 _perf_verdict_total_ms 平行：bool 数组
var _fast_tick_warn_last_frame: int = 0
var _slow_tick_count: int = 0
var _speed_buttons: Dictionary = {}

# Plan: perf-recording-csv-export
# DebugConsole 录制按钮注入的 PerfRecorder 实例。null = 当前未挂载或未录制；
# 主循环只做"非空时调 on_fast_tick"的快路径，避免污染主类。具体录制逻辑、
# CSV 拼装、状态机全部在 scripts/ui/perf_recorder.gd 内。
var _perf_recorder: RefCounted = null
# DebugConsole 地块数据录制按钮注入的 TileDataRecorder 实例。与 PerfRecorder
# 共用 fast_tick sample 时机，但 recorder 自己从 MapData 读取 cell-level SoA。
var _tile_data_recorder: RefCounted = null
var _economy_data_recorder: RefCounted = null
var _last_recorder_perf_summary: Dictionary = {}
var _recorder_warn_last_frame: int = 0

# ─── Data Overlay 状态 ─────────────────────────────────────────────
# _overlay_mode   : OverlayMode.MODE 的整数值，NONE=0
# _overlay_alpha  : 半透明强度（0.6~0.8 推荐），送到 data_overlay.gdshader
# _overlay_stats  : 最近一次 bake 返回的统计摘要，供 Telemetry 面板读取
# _overlay_last_bake_ms : 最近一次 bake 的耗时（ms），用于性能验证
# _overlay_last_fast_tick_ms : 最近一次 fast tick 总耗时（ms），给 Telemetry
# _overlay_error_msg : shader 加载 / bake 失败时写入的错误原因，DebugConsole 读
#
# debug-overlay-perf v1（2026-06-12）：
# _overlay_tex / _overlay_buf : 持久化 GPU 资源 + CPU PackedByteArray，
#   让 DataOverlayBaker.bake 走 .update(img) 而不是每帧 create_from_image。
#   实测：1080×574 derived size 下，单次 bake 从 ~12-20ms 降至 ~1.5-3ms。
# _overlay_dirty : 数据层标记。_on_day_changed 末尾置 true（且本帧不跳日），
#   下一次任意 _refresh_overlay_data 入口消费后清零；x20 倍速下避免在
#   同一个游戏日内重复 bake。
var _overlay_mode: int = 0
var _overlay_alpha: float = 0.7
var _overlay_stats: Dictionary = {}
var _overlay_last_bake_ms: float = 0.0
var _overlay_last_fast_tick_ms: int = 0
var _overlay_error_msg: String = ""
# 单日单推进（tmp\next\day_cost_IMPL.md §4）：web 上才打开"权威已接管当日 →
# main.gd 的 GDSUS 日 tick 让位"这道门。桌面恒 false → 既有语句逐条不变。
var _web_day_barrier_guard: bool = false
var _day_barrier_defer_logged: bool = false
var _overlay_tex: ImageTexture = null
var _overlay_buf: PackedByteArray = PackedByteArray()
var _overlay_dirty: bool = true
# debug-overlay-perf v2（2026-06-12）：最近一次 bake 的 pixel fan-out 路径
# （gdext_fanout / gdscript_fanout / gdscript_fanout_soa），供诊断 C++ 是否生效。
var _overlay_bake_path: String = "gdscript_fanout"
# best-effort-sim-stepping（2026-06-17）：高倍速 FPS 跳水根因 = overlay 每个模拟日
# 重 bake 一次（~592K 像素 fan-out，gdscript 路径 ~30ms）。50x 下几乎每帧推进一天
# → 每帧 30ms → 22FPS。修法：把 overlay 重 bake 按墙钟节流（默认 10Hz），与模拟日
# 解耦。仿真照常逐日推进，overlay 只在到点的帧刷新最新状态——高倍速下肉眼无差。
# 1x~10x（日间隔 ≥100ms）下此节流从不触发，行为不变。
@export_range(16.0, 1000.0, 1.0) var overlay_min_bake_interval_ms: float = 100.0
var _overlay_last_bake_wall_ms: int = 0
# F5 临时诊断：强制跳过 overlay 每日重 bake（overlay 画面冻结但仍可见），
# 用来 A/B 测 overlay fan-out 占多少帧时。
var _overlay_refresh_disabled: bool = false

func _ready() -> void:
	_renderer.configure_shader_clock(_world_clock.set_visual_shader_days_per_year)
	# Fix #11 third pass (2026-07-05)：mobile 上 PKLog 默认关。
	# 根因：PKLog.enabled 静态默认 true，且启动时未按 mobile 置关；同时
	# slp_field/wind_field STAGE-TOTAL 的 `>=5ms` warn 分支未走 PKLog 守门，
	# 慢帧下每 tick 触发 → logcat 每行 ~0.1-1ms、call#1 pollution ~15ms/print，
	# 直接吃掉 mobile frame budget。
	# 2026-08-03：PKLog 静态默认已改为 false（desktop 稳态 WARN 刷屏触发编辑器
	# output overflow）。本行保留作进程内兜底（前一场景按过 L 时强制回关）。
	# 需要调试时按 L / GM 面板 Log 按钮打开（C++ 镜像在切换时同步；ext 创建时
	# 也会按 PKLog.enabled 初始化）。
	if OS.has_feature("mobile"):
		PKLog.enabled = false
	# Web：权威（inline / worker）可能已经推进过当天，GDScript SUS 日 tick 必须让位。
	# 桌面恒 false，保持"main.gd 是唯一监听者"的原行为。
	_web_day_barrier_guard = OS.has_feature("web")
	_apply_world_setup_base_config()
	_wire_time_ui()
	_close_btn.pressed.connect(_clear_selection)
	# 地块选择改由 MapCamera 的 tile_tapped 信号驱动（仅"点按"触发，拖拽/捏合不误选）。
	if _camera != null:
		_camera.tile_tapped.connect(_on_map_tile_tapped)
		if not _camera.zoom_changed.is_connected(_renderer.set_camera_zoom):
			_camera.zoom_changed.connect(_renderer.set_camera_zoom)
		_renderer.set_camera_zoom(_camera.zoom.x)

	# Mobile safe area + 大按钮（plan §mobile-ui-safe-area，2026-06-14）：
	# 移动端圆角屏顶部最右上区域被裁切，TopBar 默认 offset_bottom=36 紧贴顶部，
	# 用户点不到右上角的 x5/x20 按钮。运行时给移动端：
	#   1. TopBar 整体下移 ~50px 留出 status bar / 圆角 safe area
	#   2. 按钮 custom_minimum_size 加大让 touch target 更稳
	_apply_mobile_topbar_safe_area()
	# Mobile viewport scale（plan §60fps 路线 C，2026-06-14）：渲染分辨率降到 0.66。
	# 实测 fragment shader 主导 70% 帧时间 → 像素总数 × 0.44（0.66² = 0.4356）→
	# 单帧 GPU 时间从 ~13ms 降到 ~6ms，留出余量给其他工作。视觉变模糊但 60 FPS 可达。
	# viewport scale 路线 C 已撤回（2026-06-15）：实测 content_scale_mode=VIEWPORT
	# + factor=0.66 让屏幕显示区域变得极小，无法使用。改为只走 shader 编译时变体
	# （MOBILE_QUALITY_LOW/MID/HIGH）减少 fragment 计算量，不动 viewport 物理大小。
	# _apply_mobile_viewport_scale()

	# Mobile debug overlay（plan §60fps，2026-06-14）：APK 没键盘点不到 F3/F11/F12，
	# 给移动端贴 3 个浮动按钮做 60 FPS 调查。桌面隐藏。
	_ensure_mobile_debug_overlay()

	# 安卓黑屏体感修复：bake_world 同步耗时 ~13s（移动端 GDScript 双重循环）。
	# 在 generate 调用前显示一个简单 splash overlay 让用户看到"在生成"，
	# bake 结束后 hide。期间主线程被 baker 占用 → UI 不会刷新阶段进度，
	# 所以这里只显示一行静态提示；阶段细分通过 baker.stage_progress 信号
	# print 到日志，未来 main 把 bake_world 改 deferred 后可让 UI 实时变化。
	_ensure_splash_overlay()

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
	# 移动端黑屏体感修复：show splash → await 让它真正绘制 → 同步 bake →
	# hide splash。await 必须在 _ready（async）里做，不能塞进 _generate_and_render
	# 否则会让该 func 变 async，破坏 regenerate_debug_map 等同步调用方。
	_splash_show()
	await get_tree().process_frame
	await get_tree().process_frame
	await _generate_and_render(initial_seed)
	_splash_hide()
	# DataCore CLI：generator 已创建，把 CLI 缓存覆盖到 ClimateProfile。
	_apply_data_core_cli_to_profile()
	# 把时钟信号接到 renderer + UI（在第一次生成完成后）
	_world_clock.day_changed.connect(_on_day_changed)
	_world_clock.season_changed.connect(_on_season_changed)
	_world_clock.year_changed.connect(_on_year_changed)
	# 任务 2：昼夜相位驱动 shader + 刷 UI 小时位。
	# [cylindrical-earth-daylight] 改连解耦的视觉相位 visual_day_phase_changed（晨昏线），
	# 与游戏倍速无关、按真实时间缓慢推进 → 快进不再闪瞎眼。
	_world_clock.visual_day_phase_changed.connect(_on_day_phase_changed)
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
	# [cylindrical-earth-daylight] 用解耦的视觉相位驱动 TOD。
	_recompute_and_push_tod(_world_clock.visual_day_phase)
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
	_visual_bootstrap = DCVisualBootstrap.new(self)

# 选中格的 weather / vitality / climate / emergent 四行。原来同步串在 day_changed
# 链里，也就是落在 WorldClock 的 sim_frame_budget_ms 时间盒内：高倍速下每模拟日付
# 一次约 3ms 的纯显示成本，直接挤占模拟预算。改为在 _process 里按墙钟节流读最新
# 快照，刷新次数与推进天数解耦——玩家看到的仍是当前值，只是不再每天重画。
const SELECTED_CELL_LINES_REFRESH_INTERVAL_MS: int = 100
var _selected_cell_lines_dirty: bool = false
var _selected_cell_lines_next_refresh_ms: int = 0
var _runtime_interactive_qos: bool = false
var _runtime_interactive_grace_until_ms: int = 0
var _runtime_last_viewport_size: Vector2i = Vector2i.ZERO


func _process(_delta: float) -> void:
	_update_runtime_interactive_qos()
	if _tod_sun_handle_btn != null and _tod_sun_handle_btn.visible and not _tod_sun_handle_dragging:
		_position_tod_sun_handle()
	_refresh_selected_cell_lines_if_due()


func _update_runtime_interactive_qos() -> void:
	_diagnostics_component._update_runtime_interactive_qos(self)


func _refresh_selected_cell_lines_if_due() -> void:
	_diagnostics_component._refresh_selected_cell_lines_if_due(self)


func _on_map_tile_tapped(world_pos: Vector2) -> void:
	if _current_map == null:
		return
	var cell = HexUtils.world_to_wrapped_cell(_current_map, world_pos, hex_size)
	if cell == null:
		return
	_select_cell(cell)

func _unhandled_key_input(event: InputEvent) -> void:
	# Debug hotkeys are available only in debug builds. Release builds use GM.
	if not OS.is_debug_build():
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			regenerate_debug_map()
		KEY_F:
			fit_debug_map()
		KEY_B:
			# Async climate round Stage 1 — A-B 验证（GM 面板等价）。transp pure kernel
			# bit-equal sync；bench 自己 snapshot/restore moisture，不污染持久 sim 状态。
			run_async_climate_bench_debug("transp")
		KEY_V:
			# Async climate round Stage 2 — pass_a A-B 验证（GM 面板等价）。
			run_async_climate_bench_debug("pass_a")
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
		KEY_F3:
			# 2026-06-14：GPU/Render frame profile dump（mobile 60 FPS 调查）。
			# 一键 dump Performance monitor 数据：FPS / 主循环 / 物理 / 渲染 / GPU /
			# 内存 / draw calls / vertex count，定位非 SUS 时间花在哪儿。
			dump_render_profile()
		KEY_F11:
			# 2026-06-14：toggle dynamic_visual_atlas_upload job（atlas 旁路实验）。
			# 关掉此 job 看 FPS 是否改善 → 判断 atlas commit 是否是 GPU 瓶颈来源。
			toggle_dynamic_visual_atlas_upload()
		KEY_F12:
			# 2026-06-14：toggle atlas resolution（256 vs 512）→ 看 GPU 负载减半否。
			# 注意：会触发 regenerate（重 bake atlas），等待 ~5 秒。
			toggle_atlas_resolution()
		KEY_F8:
			# Emergent Climate Coupling：一键切换耦合调试项。
			# 真日射链条保持运行时强制启用，不再随 F8 切回 legacy 余弦季节项。
			toggle_emergent_debug_switches()
		KEY_F6:
			# 任务 9：切换 ocean_current_debug uniform（高/低对比流线）
			toggle_ocean_current_debug()
		KEY_F7:
			# Systemic Ocean Currents：ocean_heat_debug 轻量控制台打印
			diagnose_ocean_heat()
		KEY_F9:
			# 2026-06-14：toggle 主地形 shader（_world_quad.material = null）。
			# 60 FPS 瓶颈调查：fragment shader 不跑 → 直接测出 hex_terrain/world_map
			# shader 占多少 GPU 时间。FPS 飙升 → shader 是真凶；不变 → Vulkan/驱动瓶颈。
			toggle_world_shader_disabled()
		KEY_F10:
			# 2026-06-14：toggle WeatherLayer visible（60 FPS 瓶颈调查）。
			# 完全隐藏 weather overlay → shader 不跑 → 直接测出 weather_overlay 占
			# 多少 ms/帧。如果 FPS 从 40 升到 55+，weather_overlay 是真凶；如果只升
			# 到 45，瓶颈在别处（SUS / 其他 shader / Canvas）。
			toggle_weather_layer_visible()
		KEY_F5:
			# best-effort-sim-stepping（2026-06-17，临时）：冻结 data overlay 的每日重 bake。
			# overlay 保持当前画面可见，但 _refresh_overlay_data 被跳过 → 直接测出
			# overlay fan-out（~30ms gdscript 路径）占多少帧时。高倍速下按一下若 FPS
			# 从 ~22 飙到 55+，overlay 重 bake 即真凶（已加墙钟节流 overlay_min_bake_interval_ms）。
			toggle_overlay_refresh_disabled()
		KEY_L:
			# 全局诊断日志（PKLog）开关（GM 面板等价）。关掉后所有守门 print 站点
			# short-circuit，立即看到真实硬件天花板；镜像到 C++ 端。
			toggle_diagnostic_logging_debug()
		KEY_F2:
			# DCSoakDump 一键启动（dots-storage-同源紧急修复 2026-05-14）：
			# 30 tick SUMMARY mode 写到 user://soak/manual_<timestamp>.tsv。
			# F10 原本绑 use_data_core master toggle，dots-flag-prune-pr1 删除后改用 F2。
			# 已在跑则忽略（避免互相覆盖）。
			_soak_dump_hotkey_start()
		# 注：原 KEY_F3（Soak A/B）/ KEY_F11（DataCore 标志）/ KEY_F12（validate-weather）
		# 重复分支已删除——它们在 match 里被上方首次出现的 F3/F11/F12 分支永久遮蔽（死代码），
		# 对应功能现已统一收进 GM 面板（调试控制台）的「DataCore / Soak」「诊断打印」分组。
		# Soak A/B 的修饰键变体（Shift/Ctrl/Alt+F3）同理失效，改用面板按钮触发。

# ─── 移动端调试按钮入口 ─────────────────────────────────────────────────

var _render_profile_atlas_disabled: bool = false

var _render_profile_atlas_quarter_size: bool = false

var _render_profile_weather_hidden: bool = false

var _render_profile_world_shader_disabled: bool = false

func _on_pause_toggled(pressed: bool) -> void:
	_world_clock.pause(pressed)
	_sync_clock_running_to_weather_layer()

func _on_speed_changed(new_speed: float) -> void:
	_sync_speed_buttons()
	if _renderer != null:
		if _renderer.has_method("set_simulation_speed_multiplier"):
			_renderer.set_simulation_speed_multiplier(new_speed)
		var wl = _renderer.get_node_or_null("WeatherLayer")
		if wl != null and wl.has_method("set_clock_speed_multiplier"):
			wl.set_clock_speed_multiplier(new_speed)
		var fl = _renderer.get_node_or_null("FogOfWarLayer")
		if fl != null and fl.has_method("set_clock_speed_multiplier"):
			fl.set_clock_speed_multiplier(new_speed)
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

# 把 WorldClock.paused 状态转发给天气云与迷雾云。两个大气层使用同一表现时钟语义：
# 运行时按游戏倍速，暂停时仍以 1x 真实时间缓慢活动，避免完全冻结。
func _on_day_changed(_day_idx: int) -> void:
	_diagnostics_component.run_day_changed(self, _day_idx)


func _on_season_changed(_season_idx: int) -> void:
	_refresh_time_label()
	# 2026-05-18：season_refresh 改为 SeasonRefreshSystem 自驱周期重算（默认每 30
	# tick 一次），不再绑定到 WorldClock.season_changed 信号脉冲。游戏世界里
	# 温度 / 降水 / 风 / 海冰已由 refresh_climate_daily 每天连续推进，"季节切换"
	# 退化为 UI 概念。仅在 ClimateProfile.season_refresh_legacy_signal=true（回归
	# 对照路径）时，main.gd 才会主动 queue_season_refresh。
	if _generator != null and _current_map != null and _world_data != null:
		var cp = _generator._c() if _generator.has_method("_c") else null
		var use_legacy: bool = false
		if cp != null and "season_refresh_legacy_signal" in cp:
			use_legacy = bool(cp.season_refresh_legacy_signal)
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
	_debug_tod_sun_position = fposmod(day_phase, 1.0)
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
	_diagnostics_component._refresh_time_label(self)


func _refresh_climate_label() -> void:
	_diagnostics_component._refresh_climate_label(self)


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

	# Cell-index 间接寻址开关：把 @export 勾选值推给进程级 meta（DCFeatureFlags），
	# 必须在 _generator.generate(...)（内部调 bake_world）之前设置，bake /
	# dynamic_visual_atlas_upload / hex_renderer 三处统一读。一键勾选 → 重新生成即生效。
	DCFeatureFlags.set_cell_indirection(cell_indirection_enabled)
	# 洋流/风场逐像素视觉开关（同样必须在 bake_world 前推送）。关时 bake / job 跳过
	# vector_atlas 像素光栅 + 上传，纯视觉退化，仿真不受影响。
	DCFeatureFlags.set_ocean_current_visual(ocean_current_visual_enabled)
	# 旧 sea_ice_tex 逐像素海冰贴图开关（同样必须在 bake_world 前推送）。默认关 → bake
	# 不再产出那张死贴图，prepare/upload no-op；主海冰视觉走 shader 派生不受影响。
	DCFeatureFlags.set_sea_ice_atlas(sea_ice_atlas_enabled)
	# Terrain horizon：桌面默认开；移动端由启动页开关控制；Web 强制关（与
	# WorldRuntimeHost._apply_feature_flags / DCFeatureFlags 默认一致，避免 meta
	# 被写成 true 后盖掉 web 关阴影设计）。移动端启用后 _push_visual_toggles_legacy
	# 会提升 mobile shader quality，确保运行期不被 LOW/MID 剪掉。
	var terrain_horizon_gpu := true
	if OS.has_feature("mobile"):
		terrain_horizon_gpu = mobile_terrain_horizon_enabled
	elif OS.has_feature("web"):
		terrain_horizon_gpu = false
	DCFeatureFlags.set_terrain_horizon_gpu_bake(terrain_horizon_gpu)

	var cfg := MapConfig.make(map_width, map_height)
	cfg.num_continents = num_continents
	cfg.continent_size = continent_size
	cfg.sea_level = sea_level
	cfg.river_count = river_count
	cfg.seed = seed_val

	var t0: int = Time.get_ticks_msec()
	_generator = MapGenerator.new()
	# EconomyDailySystem is created during generate(). Inject the clock first so
	# the debug scene uses the same barrier/continuation path as PlayerGame.
	_generator.set_world_clock_ref(_world_clock)
	_generator.set_test_economy_bootstrap_enabled(generate_test_economy_data)
	_generator.set_test_economy_population_scale(test_economy_population_scale)
	_apply_runtime_climate_profile(_generator)
	# 订阅 cooperative generation 的阶段进度；MapGenerator / MapBaker 会在重阶段
	# 边界主动让出一帧，因此 splash、窗口事件和进度文案能真实刷新。
	if _generator.has_signal("bake_progress") and not _generator.bake_progress.is_connected(_on_baker_stage_progress):
		_generator.bake_progress.connect(_on_baker_stage_progress)
	var result: Dictionary = await _generator.generate(cfg, hex_size)
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
	# 散布层 native 生成：把 C++ DCWorldExt 在 set_map（触发首次 _rebuild）之前注入，
	# 让首张地图的植被/点缀就能走 encode_detail_scatter（缺方法时层内自动回退 GDScript）。
	if _renderer.has_method("set_world_ext") and _generator != null and "_data_core_world_ext" in _generator:
		_renderer.set_world_ext(_generator._data_core_world_ext)
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
		# [cylindrical-earth-daylight] 用解耦的视觉相位。
		_renderer.set_day_phase(_world_clock.visual_day_phase)
		# Seasonal Continuous Climate：新地图生成后 generate() 写的是"夏中段"快照，
		# 立即用当前 season_phase 同步一次连续基线，让玩家进入第一帧就看到与
		# 时钟相位一致的温度/湿度/雪盖，而不是固定的夏季常量。
		if _generator != null and _current_map != null:
			var cp = _generator._c()
			if cp != null and cp.daily_climate_interpolation:
				_generator.refresh_climate_daily(_current_map, _world_clock.season_phase())

	_camera.set_world_bounds(_renderer.get_world_bounds())
	if _camera.has_method("set_horizontal_wrap"):
		_camera.set_horizontal_wrap(_map_wrap_period_x(), true)
	_camera.fit_to_viewport(1.05, _map_safe_area())
	_renderer.set_camera_zoom(_camera.zoom.x)

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
	# debug-overlay-perf v1（2026-06-12）：regenerate 后 derived_size 可能变，
	# 把持久化的 _overlay_tex/_buf 置空让 baker 安全新建；同时立刻 bake 一次
	# 让玩家看到新地图的 overlay 数据。dirty 标记保持 false——下个 day_changed
	# 会自然置 true。
	_overlay_tex = null
	_overlay_buf = PackedByteArray()
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

# ─── Mobile shader quality tier helper（2026-06-15）──────────────────
# tier 整数 → shader #define 字符串。tier 越低 sample 预算越紧。
func _mobile_quality_tier_to_define(tier: int) -> String:
	return _overlay_component._mobile_quality_tier_to_define(self, tier)


func cycle_mobile_quality_tier() -> void:
	_overlay_component.cycle_mobile_quality_tier(self)


func _push_visual_toggles() -> void:
	_overlay_component._push_visual_toggles(self)


func _push_visual_toggles_legacy() -> void:
	_overlay_component._push_visual_toggles_legacy(self)


func _init_tod_profile() -> void:
	_overlay_component._init_tod_profile(self)


func _recompute_and_push_tod(day_phase: float) -> void:
	_overlay_component._recompute_and_push_tod(self, day_phase)


func set_day_night_enabled(v: bool) -> void:
	_overlay_component.set_day_night_enabled(self, v)


func set_debug_tod_light_angle_deg(v: float) -> void:
	_overlay_component.set_debug_tod_light_angle_deg(self, v)


func get_debug_tod_light_angle_deg() -> float:
	return _overlay_component.get_debug_tod_light_angle_deg(self)


func set_debug_tod_light_elevation_deg(v: float) -> void:
	_overlay_component.set_debug_tod_light_elevation_deg(self, v)


func get_debug_tod_light_elevation_deg() -> float:
	return _overlay_component.get_debug_tod_light_elevation_deg(self)


func set_debug_tod_sun_position(v: float) -> void:
	_overlay_component.set_debug_tod_sun_position(self, v)


func get_debug_tod_sun_position() -> float:
	return _overlay_component.get_debug_tod_sun_position(self)


func set_debug_tod_sun_uv(uv: Vector2) -> void:
	_overlay_component.set_debug_tod_sun_uv(self, uv)


func get_debug_tod_sun_uv() -> Vector2:
	return _overlay_component.get_debug_tod_sun_uv(self)


func set_debug_tod_sun_height_scale(v: float) -> void:
	_overlay_component.set_debug_tod_sun_height_scale(self, v)


func get_debug_tod_sun_height_scale() -> float:
	return _overlay_component.get_debug_tod_sun_height_scale(self)


func set_debug_tod_sun_handle_visible(v: bool) -> void:
	_overlay_component.set_debug_tod_sun_handle_visible(self, v)


func _current_visual_day_phase() -> float:
	return _overlay_component._current_visual_day_phase(self)


func _debug_tod_light_dir() -> Vector3:
	return _overlay_component._debug_tod_light_dir(self)


func _push_tod_debug_sun_uv() -> void:
	_overlay_component._push_tod_debug_sun_uv(self)


func _current_tod_sun_uv() -> Vector2:
	return _overlay_component._current_tod_sun_uv(self)


func _ensure_tod_sun_handle() -> void:
	if _tod_sun_handle_btn != null and is_instance_valid(_tod_sun_handle_btn):
		return
	var ui_layer: CanvasLayer = get_node_or_null("UI") as CanvasLayer
	if ui_layer == null:
		return
	_tod_sun_handle_btn = Button.new()
	_tod_sun_handle_btn.name = "TODSunHandle"
	_tod_sun_handle_btn.text = "☀"
	_tod_sun_handle_btn.tooltip_text = "拖动太阳位置"
	_tod_sun_handle_btn.custom_minimum_size = Vector2(38, 38)
	_tod_sun_handle_btn.size = Vector2(38, 38)
	_tod_sun_handle_btn.mouse_filter = Control.MouseFilter.MOUSE_FILTER_STOP
	_tod_sun_handle_btn.focus_mode = Control.FOCUS_NONE
	_tod_sun_handle_btn.visible = false
	_tod_sun_handle_btn.gui_input.connect(_on_tod_sun_handle_gui_input)
	ui_layer.add_child(_tod_sun_handle_btn)


func _update_tod_sun_handle_visibility() -> void:
	_ensure_tod_sun_handle()
	if _tod_sun_handle_btn == null:
		return
	_tod_sun_handle_btn.visible = _debug_tod_sun_handle_requested and day_night_enabled
	if _tod_sun_handle_btn.visible:
		_position_tod_sun_handle()


func _position_tod_sun_handle() -> void:
	_overlay_component._position_tod_sun_handle(self)


func _on_tod_sun_handle_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_tod_sun_handle_dragging = mb.pressed
			if mb.pressed:
				set_debug_tod_sun_uv(_screen_to_sun_uv(get_viewport().get_mouse_position()))
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _tod_sun_handle_dragging:
		set_debug_tod_sun_uv(_screen_to_sun_uv(get_viewport().get_mouse_position()))
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		_tod_sun_handle_dragging = touch.pressed
		if touch.pressed:
			set_debug_tod_sun_uv(_screen_to_sun_uv(touch.position))
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and _tod_sun_handle_dragging:
		var drag := event as InputEventScreenDrag
		set_debug_tod_sun_uv(_screen_to_sun_uv(drag.position))
		get_viewport().set_input_as_handled()


func _screen_to_sun_uv(screen_pos: Vector2) -> Vector2:
	return _overlay_component._screen_to_sun_uv(self, screen_pos)


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return _overlay_component._screen_to_world(self, screen_pos)


func _world_to_screen(world_pos: Vector2) -> Vector2:
	return _overlay_component._world_to_screen(self, world_pos)


func _map_wrap_period_x() -> float:
	return _overlay_component._map_wrap_period_x(self)


func _cell_display_world(cell: HexCell) -> Vector2:
	return _overlay_component._cell_display_world(self, cell)


func _select_cell(cell: HexCell) -> void:
	_overlay_component._select_cell(self, cell)


func _clear_selection() -> void:
	_overlay_component._clear_selection(self)


func _map_safe_area() -> Rect2:
	return _overlay_component._map_safe_area(self)


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
	_diagnostics_component._refresh_emergent_lines(self)


func _sync_overlay_to_world() -> void:
	_overlay_component._sync_overlay_to_world(self)


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
	_debug_component._demo_tg_diag_once(self, reason)


func _is_demo_thermal_gradient_enabled() -> bool:
	return _debug_component._is_demo_thermal_gradient_enabled(self)


func _run_demo_thermal_gradient_pass_if_enabled() -> void:
	_debug_component._run_demo_thermal_gradient_pass_if_enabled(self)


func _run_demo_tg_via_ecs(ext: Object, w: int, h: int, iter_count: int, kr: int,
		coriolis: float, drag: float, gain: float, k: float, path_id: int) -> void:
	_debug_component._run_demo_tg_via_ecs(self, ext, w, h, iter_count, kr, coriolis, drag, gain, k, path_id)


func _dc_ecs_sync_archetypes(ext: Object) -> int:
	return _debug_component._dc_ecs_sync_archetypes(self, ext)


func _dc_ecs_run_demo_complex(ctx: Dictionary, _job) -> void:
	_debug_component._dc_ecs_run_demo_complex(self, ctx, _job)


func _dc_ecs_run_demo_complex_archetyped(ctx: Dictionary, job) -> void:
	_debug_component._dc_ecs_run_demo_complex_archetyped(self, ctx, job)


func diagnose_ocean_heat() -> void:
	_debug_component.diagnose_ocean_heat(self)


func diagnose_selected_temperature() -> void:
	_debug_component.diagnose_selected_temperature(self)


func get_selected_cell() -> HexCell:
	return _debug_component.get_selected_cell(self)


func get_current_map() -> MapData:
	return _debug_component.get_current_map(self)


func get_world_clock_ref() -> WorldClock:
	return _debug_component.get_world_clock_ref(self)


func get_generator() -> MapGenerator:
	return _debug_component.get_generator(self)


func get_renderer() -> HexRenderer:
	return _debug_component.get_renderer(self)


func get_fast_tick_count() -> int:
	return _debug_component.get_fast_tick_count(self)


func get_last_fast_tick_ms() -> int:
	return _debug_component.get_last_fast_tick_ms(self)


func get_sus_last_tick_report() -> Dictionary:
	return _debug_component.get_sus_last_tick_report(self)


func get_sus_last_tick_summary() -> Dictionary:
	return _debug_component.get_sus_last_tick_summary(self)


func _parse_data_core_cli() -> void:
	_debug_component._parse_data_core_cli(self)


func _apply_data_core_cli_to_profile() -> void:
	_debug_component._apply_data_core_cli_to_profile(self)


func _soak_dump_hotkey_start() -> void:
	_debug_component._soak_dump_hotkey_start(self)


func _get_soak_dump_script() -> GDScript:
	return _debug_component._get_soak_dump_script(self)


func _get_soak_ab_runner_script():
	return _debug_component._get_soak_ab_runner_script(self)


func _soak_ab_hotkey_start(mode: int = SOAK_AB_MODE_SAME_SOURCE,
		n_ticks: int = 30) -> void:
	_debug_component._soak_ab_hotkey_start(self, mode, n_ticks)


func _soak_ab_hotkey_cancel() -> void:
	_debug_component._soak_ab_hotkey_cancel(self)


func is_data_core_on() -> bool:
	return _debug_component.is_data_core_on(self)


func _toggle_data_core_weather_runtime() -> void:
	_debug_component._toggle_data_core_weather_runtime(self)


func _toggle_data_core_master_runtime() -> void:
	_debug_component._toggle_data_core_master_runtime(self)


func _rebuild_view_adapter() -> void:
	_debug_component._rebuild_view_adapter(self)


func toggle_debug_console() -> void:
	_debug_component.toggle_debug_console(self)

func run_async_climate_bench_debug(kind: String = "transp") -> void:
	_debug_component.run_async_climate_bench_debug(self, kind)

func _sus_ext_ref():
	return _debug_component._sus_ext_ref(self)

func toggle_diagnostic_logging_debug() -> void:
	_debug_component.toggle_diagnostic_logging_debug(self)

func cycle_weather_debug_view() -> void:
	_debug_component.cycle_weather_debug_view(self)

func get_debug_toggle_state(key: String) -> bool:
	return _debug_component.get_debug_toggle_state(self, key)

func toggle_perf_mini_hud() -> void:
	_debug_component.toggle_perf_mini_hud(self)

func dump_render_profile() -> void:
	# Godot 4 Performance.get_monitor 提供以下精确 ms 计数：
	# - TIME_FPS / TIME_PROCESS / TIME_PHYSICS_PROCESS / TIME_NAVIGATION_PROCESS
	# - RENDER_TOTAL_OBJECTS_IN_FRAME / TOTAL_PRIMITIVES / TOTAL_DRAW_CALLS
	# - RENDER_VIDEO_MEM_USED / RENDER_TEXTURE_MEM_USED / RENDER_BUFFER_MEM_USED
	# - OBJECT_NODE_COUNT / OBJECT_RESOURCE_COUNT
	var fps: float = Engine.get_frames_per_second()
	var proc_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var nav_ms: float = Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
	# 取 120 帧采样 + 直方图 + SUS 关联（plan §60fps，2026-06-14）
	# 之前用 30 帧 sample 只给 min/avg/p95/max，无法区分"60 FPS 帧 + 30 FPS 帧混合"
	# 跟"全部稳定 25ms"。现在加直方图：哪 N 帧在哪个 ms 区间，能看出真分布。
	const _SAMPLE_FRAMES: int = 120
	var frame_samples: PackedFloat32Array = PackedFloat32Array()
	frame_samples.resize(_SAMPLE_FRAMES)
	# 记录每帧前 _on_day_changed 是否被触发（fast tick 帧 vs 非 fast tick 帧）
	var sus_tick_marks: PackedByteArray = PackedByteArray()
	sus_tick_marks.resize(_SAMPLE_FRAMES)
	var sus_tick_count_t0: int = _fast_tick_count
	var sample_t0: int = Time.get_ticks_usec()
	for i in range(_SAMPLE_FRAMES):
		var t0: int = Time.get_ticks_usec()
		var sus_before: int = _fast_tick_count
		await get_tree().process_frame
		frame_samples[i] = float(Time.get_ticks_usec() - t0) / 1000.0
		sus_tick_marks[i] = 1 if _fast_tick_count > sus_before else 0
	var sample_total_ms: float = float(Time.get_ticks_usec() - sample_t0) / 1000.0
	var sus_ticks_in_window: int = _fast_tick_count - sus_tick_count_t0
	# 算 min / avg / max / p95
	var arr: Array = []
	for i in range(_SAMPLE_FRAMES):
		arr.append(frame_samples[i])
	arr.sort()
	var f_min: float = arr[0]
	var f_max: float = arr[_SAMPLE_FRAMES - 1]
	var f_p50: float = arr[_SAMPLE_FRAMES / 2]
	var f_p95: float = arr[int(_SAMPLE_FRAMES * 0.95)]
	var f_avg: float = sample_total_ms / float(_SAMPLE_FRAMES)
	# 直方图：每 4ms 一个 bin，0-40ms 共 10 个 bin，> 40ms 算 overflow
	var bins: PackedInt32Array = PackedInt32Array()
	bins.resize(11)  # [0-4) [4-8) [8-12) [12-16) [16-20) [20-24) [24-28) [28-32) [32-36) [36-40) [40+)
	for v in arr:
		var idx: int = int(v / 4.0)
		if idx >= 10:
			idx = 10
		bins[idx] += 1
	# SUS 帧 vs 非 SUS 帧的 avg
	var sus_frame_total_ms: float = 0.0
	var non_sus_frame_total_ms: float = 0.0
	var sus_count: int = 0
	var non_sus_count: int = 0
	for i in range(_SAMPLE_FRAMES):
		if sus_tick_marks[i] == 1:
			sus_frame_total_ms += frame_samples[i]
			sus_count += 1
		else:
			non_sus_frame_total_ms += frame_samples[i]
			non_sus_count += 1
	var sus_frame_avg: float = sus_frame_total_ms / float(maxi(1, sus_count))
	var non_sus_frame_avg: float = non_sus_frame_total_ms / float(maxi(1, non_sus_count))
	var draw_calls: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var primitives: float = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var objects: float = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var vram_total: float = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var vram_tex: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	var vram_buf: float = Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0
	var nodes: float = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var resources: float = Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var orphan_nodes: float = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	# 注意：Godot 4 没有"GPU 时间"单独 monitor；TIME_PROCESS 包含 GDScript + render submit。
	# 真正 GPU 用时要靠 RenderingServer.get_rendering_info(VIEWPORT_DRAW_CALLS_IN_FRAME) 等。
	var rs_view_calls: int = -1
	var rs_view_prims: int = -1
	if Engine.has_singleton("RenderingServer"):
		rs_view_calls = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		rs_view_prims = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	var msaa_setting: int = ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d", 0)
	var fxaa_setting: bool = bool(ProjectSettings.get_setting("rendering/anti_aliasing/quality/use_fxaa", false))
	var vsync_setting: int = int(DisplayServer.window_get_vsync_mode())  # 0=Disabled, 1=Enabled, 2=Adaptive, 3=Mailbox
	var max_fps_setting: int = int(Engine.max_fps)
	var hm_size: Vector2i = Vector2i.ZERO
	if _world_data != null and _world_data.get("hm_size") != null:
		hm_size = _world_data.hm_size
	print("[render-profile] === GPU / Frame metrics @ frame %d ===" % Engine.get_frames_drawn())
	print("  FPS=%.1f  process(sample)=%.2fms  physics=%.2fms  nav=%.2fms" % [fps, proc_ms, phys_ms, nav_ms])
	print("  frame wall ms over %d samples: min=%.2f avg=%.2f p50=%.2f p95=%.2f max=%.2f" % [_SAMPLE_FRAMES, f_min, f_avg, f_p50, f_p95, f_max])
	# SUS frame vs non-SUS frame avg
	print("  sus_ticks=%d/%d sus_frame_avg=%.2fms non_sus_frame_avg=%.2fms" % [sus_count, _SAMPLE_FRAMES, sus_frame_avg, non_sus_frame_avg])
	# 直方图（4ms bins）
	print("  histogram (4ms bins): [0-4)=%d [4-8)=%d [8-12)=%d [12-16)=%d [16-20)=%d [20-24)=%d [24-28)=%d [28-32)=%d [32-36)=%d [36-40)=%d [40+)=%d" % [
		bins[0], bins[1], bins[2], bins[3], bins[4], bins[5], bins[6], bins[7], bins[8], bins[9], bins[10]
	])
	print("  vsync_mode=%d  max_fps=%d  (0=Off 1=On 2=Adaptive 3=Mailbox)" % [vsync_setting, max_fps_setting])
	print("  draw_calls=%d  primitives=%d  objects=%d (Performance monitor)" % [int(draw_calls), int(primitives), int(objects)])
	print("  RenderingServer view_calls=%d view_prims=%d" % [rs_view_calls, rs_view_prims])
	print("  vram total=%.1f MB  tex=%.1f MB  buf=%.1f MB" % [vram_total, vram_tex, vram_buf])
	print("  nodes=%d resources=%d orphan_nodes=%d" % [int(nodes), int(resources), int(orphan_nodes)])
	print("  atlas hm_size=%dx%d  msaa=%d  fxaa=%s  mobile=%s" % [
		hm_size.x, hm_size.y, msaa_setting, str(fxaa_setting), str(OS.has_feature("mobile"))
	])
	print("  dynamic_visual_atlas_upload_disabled=%s  atlas_force_quarter_size=%s" % [
		str(_render_profile_atlas_disabled), str(_render_profile_atlas_quarter_size)
	])

func toggle_overlay_refresh_disabled() -> void:
	_debug_component.toggle_overlay_refresh_disabled(self)

func toggle_dynamic_visual_atlas_upload() -> void:
	_debug_component.toggle_dynamic_visual_atlas_upload(self)

func toggle_atlas_resolution() -> void:
	_debug_component.toggle_atlas_resolution(self)

func toggle_weather_layer_visible() -> void:
	_debug_component.toggle_weather_layer_visible(self)

func toggle_terrain_material_gate_debug() -> void:
	_debug_component.toggle_terrain_material_gate_debug(self)

func toggle_world_shader_disabled() -> void:
	_debug_component.toggle_world_shader_disabled(self)

func cycle_visual_quality() -> void:
	_debug_component.cycle_visual_quality(self)

func _mark_debug_console_state_dirty() -> void:
	_debug_component._mark_debug_console_state_dirty(self)

func regenerate_debug_map() -> void:
	# 重新生成同样会触发 ~13s bake_world，给一次 splash 体感。
	_splash_show()
	await get_tree().process_frame
	await get_tree().process_frame
	await _generate_and_render(0)
	_splash_hide()

func fit_debug_map() -> void:
	_debug_component.fit_debug_map(self)

func toggle_emergent_debug_switches() -> void:
	_debug_component.toggle_emergent_debug_switches(self)

func toggle_ocean_current_debug() -> void:
	_debug_component.toggle_ocean_current_debug(self)

func toggle_data_core_weather_debug() -> void:
	_debug_component.toggle_data_core_weather_debug(self)

func toggle_data_core_master_debug() -> void:
	_debug_component.toggle_data_core_master_debug(self)

func start_soak_dump_debug() -> void:
	_debug_component.start_soak_dump_debug(self)

func start_soak_ab_same_source_debug(n_ticks: int = 30) -> void:
	_debug_component.start_soak_ab_same_source_debug(self, n_ticks)

func start_soak_ab_vs_legacy_debug() -> void:
	_debug_component.start_soak_ab_vs_legacy_debug(self)

func start_soak_ab_thread_batch_debug() -> void:
	_debug_component.start_soak_ab_thread_batch_debug(self)

func cancel_soak_debug() -> void:
	_debug_component.cancel_soak_debug(self)

func print_data_core_flags_debug() -> void:
	_debug_component.print_data_core_flags_debug(self)

func print_validate_weather_snapshot_debug() -> void:
	_debug_component.print_validate_weather_snapshot_debug(self)

func print_perf_verdict_debug() -> void:
	_debug_component.print_perf_verdict_debug(self)

func _world_setup_config() -> Dictionary:
	return _setup_component._world_setup_config(self)

func _apply_world_setup_base_config() -> void:
	_setup_component._apply_world_setup_base_config(self)

func _default_climate_profile_path() -> String:
	return _setup_component._default_climate_profile_path(self)

func _load_runtime_climate_profile() -> ClimateProfile:
	return _setup_component._load_runtime_climate_profile(self)

func _apply_runtime_climate_profile(generator: MapGenerator) -> void:
	_setup_component._apply_runtime_climate_profile(self, generator)

func _return_to_world_setup() -> void:
	_setup_component._return_to_world_setup(self)

func _wire_time_ui() -> void:
	_setup_component._wire_time_ui(self)

func _ensure_speed_preset_buttons() -> void:
	_setup_component._ensure_speed_preset_buttons(self)

func _existing_speed_button(speed: float) -> Button:
	return _setup_component._existing_speed_button(self, speed)

func _topbar_hbox() -> HBoxContainer:
	return _setup_component._topbar_hbox(self)

func _speed_button_node_name(speed: float) -> String:
	return _setup_component._speed_button_node_name(self, speed)

func _speed_button_label(speed: float) -> String:
	return _setup_component._speed_button_label(self, speed)

func _on_speed_preset_pressed(speed: float) -> void:
	_setup_component._on_speed_preset_pressed(self, speed)

func _sync_speed_buttons() -> void:
	_setup_component._sync_speed_buttons(self)

func _sync_pause_btn() -> void:
	_setup_component._sync_pause_btn(self)

func _set_speed(s: float) -> void:
	_setup_component._set_speed(self, s)

func _sync_clock_running_to_weather_layer() -> void:
	_setup_component._sync_clock_running_to_weather_layer(self)

func _publish_fast_tick_perf_sample(t_sus_ms: float, t_render_ms: float,
		t_ui_ms: float, fast_ms: float, was_skipped_day: bool) -> Dictionary:
	return _diagnostics_component._publish_fast_tick_perf_sample(self, t_sus_ms, t_render_ms, t_ui_ms, fast_ms, was_skipped_day)

func _recorder_ready(rec: RefCounted) -> bool:
	return _diagnostics_component._recorder_ready(self, rec)

func _print_daily_breakdown(tick_no: int, sus_ms: float, render_ms: float,
		ui_ms: float, total_ms: float, skipped_day: bool, is_warn: bool) -> void:
	_diagnostics_component._print_daily_breakdown(self, tick_no, sus_ms, render_ms, ui_ms, total_ms, skipped_day, is_warn)

func get_sim_breakdowns() -> Dictionary:
	return _diagnostics_component.get_sim_breakdowns(self)

func get_environment_perf_summary() -> Dictionary:
	return _diagnostics_component.get_environment_perf_summary(self)

func get_recorder_perf_summary() -> Dictionary:
	return _diagnostics_component.get_recorder_perf_summary(self)

func set_perf_recorder(rec: RefCounted) -> void:
	_diagnostics_component.set_perf_recorder(self, rec)

func get_perf_recorder() -> RefCounted:
	return _diagnostics_component.get_perf_recorder(self)

func set_tile_data_recorder(rec: RefCounted) -> void:
	_diagnostics_component.set_tile_data_recorder(self, rec)

func get_tile_data_recorder() -> RefCounted:
	return _diagnostics_component.get_tile_data_recorder(self)

func set_economy_data_recorder(rec: RefCounted) -> void:
	_diagnostics_component.set_economy_data_recorder(self, rec)

func get_economy_data_recorder() -> RefCounted:
	return _diagnostics_component.get_economy_data_recorder(self)

func request_dots_final_push_perf_verdict() -> Dictionary:
	return _diagnostics_component.request_dots_final_push_perf_verdict(self)

func data_core_status_dict() -> Dictionary:
	return _diagnostics_component.data_core_status_dict(self)

func _print_data_core_flag_snapshot() -> void:
	_diagnostics_component._print_data_core_flag_snapshot(self)

func _validate_weather_collect(_path: String, _wb: Dictionary) -> void:
	_diagnostics_component._validate_weather_collect(self, _path, _wb)

func _validate_weather_print_snapshot() -> void:
	_diagnostics_component._validate_weather_print_snapshot(self)

func _apply_overlay_mode(mode: int) -> void:
	_overlay_component._apply_overlay_mode(self, mode)

func _set_overlay_alpha(v: float) -> void:
	_overlay_component._set_overlay_alpha(self, v)

func _refresh_overlay_data() -> void:
	_overlay_component._refresh_overlay_data(self)

func _disable_overlay_due_to_error(msg: String) -> void:
	_overlay_component._disable_overlay_due_to_error(self, msg)

func get_overlay_mode() -> int:
	return _overlay_component.get_overlay_mode(self)

func get_overlay_alpha() -> float:
	return _overlay_component.get_overlay_alpha(self)

func get_overlay_stats() -> Dictionary:
	return _overlay_component.get_overlay_stats(self)

func get_overlay_last_bake_ms() -> float:
	return _overlay_component.get_overlay_last_bake_ms(self)

func get_overlay_bake_path() -> String:
	return _overlay_component.get_overlay_bake_path(self)

func get_overlay_error_msg() -> String:
	return _overlay_component.get_overlay_error_msg(self)

func _update_overlay_pointer_for_cell() -> void:
	_overlay_component._update_overlay_pointer_for_cell(self)

func _apply_mobile_topbar_safe_area() -> void:
	_mobile_component._apply_mobile_topbar_safe_area(self)

func _apply_mobile_viewport_scale() -> void:
	_mobile_component._apply_mobile_viewport_scale(self)

func _mobile_safe_insets() -> Vector4:
	return _mobile_component._mobile_safe_insets(self)

func _ensure_mobile_debug_overlay() -> void:
	_mobile_component._ensure_mobile_debug_overlay(self)

func _on_mobile_debug_overlay_toggle() -> void:
	_mobile_component._on_mobile_debug_overlay_toggle(self)

func _mobile_debug_button(name: String) -> Button:
	return _mobile_component._mobile_debug_button(self, name)

func _on_mobile_dva_btn_pressed() -> void:
	_mobile_component._on_mobile_dva_btn_pressed(self)

func _on_mobile_atlas_btn_pressed() -> void:
	_mobile_component._on_mobile_atlas_btn_pressed(self)

func _on_mobile_weather_btn_pressed() -> void:
	_mobile_component._on_mobile_weather_btn_pressed(self)

func _on_mobile_shader_btn_pressed() -> void:
	_mobile_component._on_mobile_shader_btn_pressed(self)

func _on_mobile_quality_btn_pressed() -> void:
	_mobile_component._on_mobile_quality_btn_pressed(self)

func _on_mobile_log_btn_pressed() -> void:
	_mobile_component._on_mobile_log_btn_pressed(self)

func _ensure_splash_overlay() -> void:
	_mobile_component._ensure_splash_overlay(self)

func _splash_show(text: String = "正在生成世界…") -> void:
	_mobile_component._splash_show(self, text)

func _splash_hide() -> void:
	_mobile_component._splash_hide(self)

func _on_baker_stage_progress(stage: String, fraction: float) -> void:
	_mobile_component._on_baker_stage_progress(self, stage, fraction)
