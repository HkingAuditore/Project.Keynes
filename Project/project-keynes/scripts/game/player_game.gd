extends Node2D
class_name PlayerGame

const MAIN_MENU_SCENE_PATH := "res://scenes/main_menu.tscn"
# Web 自动测试跟车节点（URL autotest=1 才启用）。preload 避免依赖 class_name 缓存。
const WebAutotestScript = preload("res://scripts/game/web_autotest.gd")
const DEFAULT_DAY_NIGHT_ENABLED := true

# 桌面玩家场景默认高画质；mobile/web 由 GameSettings.render_quality 驱动
# 编译期 MOBILE_QUALITY_* + 运行期 visual_quality（auto→LOW）。
@export_range(0, 2, 1) var visual_quality: int = 2
@export_range(0, 2, 1) var mobile_quality_tier: int = 0
@export var perf_sampler_enabled: bool = false
# 正式玩家会话固定从昼夜循环开始；运行中仍可通过顶栏或 GM 面板切换。
# 不导出该字段，避免编辑器场景覆盖或热重载残值把新会话静默改成永昼。
var day_night_enabled: bool = DEFAULT_DAY_NIGHT_ENABLED

@onready var _renderer: HexRenderer = $WorldRoot/HexRenderer
@onready var _camera: MapCamera = $MapCamera
@onready var _highlight: CellHighlight = $WorldRoot/CellHighlight
@onready var _cell_highlight_set = $WorldRoot/CellHighlightSet
## Peace-window overlays: candidate outline and the picked draft, separate sets
## so a cession pick never repaints the candidates behind it.
@onready var _peace_candidate_set = $WorldRoot/PeaceCandidateSet
@onready var _peace_draft_set = $WorldRoot/PeaceDraftSet
@onready var _map_overlay: DataOverlayLayer = $WorldRoot/DataOverlayLayer
@onready var _colonization_route: ColonizationRouteLayer = $WorldRoot/ColonizationRouteLayer
@onready var _map_activity = $WorldRoot/MapActivityLayer
@onready var _trade_activity = $WorldRoot/TradeActivityLayer
@onready var _cell_situations = $UI/UIRoot/HUDLayer/CellSituationLayer
@onready var _world_clock: WorldClock = $WorldClock
@onready var _runtime_host: WorldRuntimeHost = $RuntimeHost
@onready var _ui_manager: GameUIManager = $UI
@onready var _player_controller = $PlayerController

var _viewport_refit_pending := false
## 本次场景的会话请求（new_game 或 load_game），供失败面板「重试」原样重放。
## 重试必须重建**同一个**会话：换成随机世界会把存档的 PKCN/领土恢复进另一张图。
var _session_request: Dictionary = {}


func _ready() -> void:
	if OS.has_feature("mobile"):
		PKLog.enabled = false
	# Web 自动测试：先挂跟车节点再配置运行时，这样连"会话配置失败"也能被超时抓到。
	_attach_web_autotest()
	_configure_runtime()
	var flow: Node = _game_flow()
	var request: Dictionary = flow.consume_request() if flow != null else {}
	if request.is_empty():
		var fallback := NewGameConfig.create_default()
		request = {"kind": "new_game", "config": fallback.to_dictionary()}
	_session_request = request.duplicate(true)
	var session_result := _runtime_host.configure_session(request)
	if not bool(session_result.get("ok", false)):
		# autotest 会话：会话配置失败要立刻进事件流，而不是等 world_ready 超时。
		WebAutotestScript.report_failure("session_config_failed",
			{"message": String(session_result.get("message", "")),
			"code": String(session_result.get("code", ""))})
		_ui_manager.show_loading(String(session_result.get("message", "会话初始化失败。")))
		return
	_connect_signals()
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_push_visual_toggles()
	_ui_manager.show_loading("正在生成世界...")
	var loading := _ui_manager.get_node("UIRoot/ModalLayer/WorldLoadingOverlay") as WorldLoadingOverlay
	loading.set_layout_state(_runtime_host.session_config().get("base", {}))
	loading.retry_requested.connect(_retry_session)
	loading.return_requested.connect(func() -> void: get_tree().change_scene_to_file(MAIN_MENU_SCENE_PATH))
	await get_tree().process_frame
	await get_tree().process_frame
	await _runtime_host.generate_world(-1, _ui_manager.map_safe_area())


## Web 自动测试：见 scripts/game/web_autotest.gd。只在 URL 带 autotest=1 时挂节点，
## 普通会话零节点、零轮询（严格增量），也不改动任何既有信号连接。
func _attach_web_autotest() -> void:
	if not WebAutotestScript.enabled():
		return
	var soak := WebAutotestScript.new()
	soak.configure(_runtime_host, _world_clock)
	add_child(soak)


func _apply_stage_c_debug_metadata() -> void:
	# Stage C is a development-only measurement hook. It is intentionally read
	# before WorldRuntimeHost.configure() because the authority choice is
	# consumed during world bind/generation. No product setting or GM toggle is
	# added for this path.
	if not OS.is_debug_build():
		return
	if not Engine.has_meta(&"stage_c_authority_mode"):
		return
	var mode := String(Engine.get_meta(&"stage_c_authority_mode", "")).to_upper()
	if mode not in ["ACTIVE", "OFF"]:
		push_warning("[stage-c] ignored invalid authority mode: %s" % mode)
		return
	_runtime_host.runtime_climate_authority_enabled = mode == "ACTIVE"
	print("[stage-c] authority=%s worker=%s" % [
		mode, "ACTIVE" if mode == "ACTIVE" else "SHADOW",
	])


func _on_viewport_size_changed() -> void:
	if _viewport_refit_pending:
		return
	_viewport_refit_pending = true
	call_deferred("_refit_after_viewport_resize")


func _refit_after_viewport_resize() -> void:
	_viewport_refit_pending = false
	_runtime_host.fit_camera(_ui_manager.map_safe_area())


func _configure_runtime() -> void:
	_map_overlay.set_alpha(0.58)
	# 正式玩家会话：整图 worker ACTIVE（0xFFF）。Effect→Country ACK 与 soft-settle
	# 已修好，不再用 0x806 把 Trigger 等留在主线程拖垮 50x 日历吞吐。
	_runtime_host.runtime_climate_authority_enabled = true
	_runtime_host.runtime_economy_auto_pod_active = true
	if OS.is_debug_build() and Engine.has_meta(&"stage_c_auto_pod_active"):
		_runtime_host.runtime_economy_auto_pod_active = bool(Engine.get_meta(&"stage_c_auto_pod_active"))
		Engine.remove_meta(&"stage_c_auto_pod_active")
	_runtime_host.runtime_authority_domain_mask = 0xFFF
	# Web 曾经在这里把权威位退回主线程（当时浏览器里 native worker 图的 day barrier
	# 收不了尾）。后来查明那次"卡死"的真正原因是首帧着色器编译 45s 把整帧堵住，
	# shader 裁剪之后 worker 图可以正常 commit day —— 而**只有 ACTIVE 才推进日历**
	# （SHADOW 只做 parity 对比，日历会停在 day 1）。所以 web 不再降级。
	# Apply the explicit A/B request after production defaults; otherwise OFF
	# is silently overwritten and both arms measure ACTIVE.
	_apply_stage_c_debug_metadata()
	_runtime_host.configure(_renderer, _camera, _world_clock, _map_overlay)
	_ui_manager.set_diagnostics_source(_runtime_host)
	_ui_manager.bind_gm_sun_camera(_camera)
	_ui_manager.bind_player_camera(_camera)
	_player_controller.configure(_camera, _highlight, _runtime_host, _world_clock, _ui_manager)
	# Injected after configure so the single-cell selection highlight and the
	# many-cell card overlay stay independent: selecting a hex must not wipe the
	# card's hits, and showing a card's hits must not move the selection.
	_player_controller.set_cell_highlight_set(_cell_highlight_set)
	_player_controller.set_peace_highlight_sets(_peace_candidate_set, _peace_draft_set)
	_ui_manager.set_colonization_route_layer(_colonization_route)
	var save: Node = _game_save()
	if save != null:
		save.bind_runtime(_runtime_host, _world_clock, _player_controller)
	# 生成前钉死 force_on，避免 AUTO 策略或 GM 残值把会话退回 SHADOW。
	_runtime_host.set_climate_authority_override(
		"force_on" if _runtime_host.runtime_climate_authority_enabled else "force_off")


func _connect_signals() -> void:
	_runtime_host.world_ready.connect(_on_world_ready)
	_runtime_host.world_generation_failed.connect(_on_world_generation_failed)
	_runtime_host.generation_progress.connect(_ui_manager.set_generation_progress)
	_runtime_host.gm_toggle_changed.connect(_on_gm_runtime_toggle_changed)
	_player_controller.selection_changed.connect(_runtime_host.set_selected_cell)
	_player_controller.regeneration_requested.connect(_regenerate_world)
	_ui_manager.fit_requested.connect(_on_fit_requested)
	_ui_manager.regenerate_requested.connect(_on_regenerate_requested)
	_ui_manager.day_night_toggled.connect(_on_day_night_toggled)
	_ui_manager.map_overlay_requested.connect(_runtime_host.set_map_overlay)
	_ui_manager.map_overlay_cleared.connect(_runtime_host.clear_map_overlay)
	_ui_manager.return_main_menu_requested.connect(_request_return_main_menu)
	_ui_manager.exit_game_requested.connect(_request_exit_game)
	var settings: Node = _game_settings()
	if settings != null and not settings.settings_changed.is_connected(_on_settings_changed):
		settings.settings_changed.connect(_on_settings_changed)


func _on_world_ready(
		map: MapData,
		_world_data: WorldData,
		generator: MapGenerator,
		view_adapter: DCViewAdapter
) -> void:
	var ready_t0 := Time.get_ticks_usec()
	_player_controller.refresh_country_binding()
	_player_controller.clear_selection()
	_map_activity.configure(map, _camera, _runtime_host, _player_controller,
		generator.get_economy_facade(), _world_clock, _colonization_route,
		_renderer.country_border_layer())
	_trade_activity.configure(map, _camera, _runtime_host, _player_controller,
		generator.get_economy_facade(), _world_clock)
	_trade_activity.set_quality(visual_quality)
	# ---- Military layers
	# Manager lives on RuntimeHost (created at renderer bind); it needs the
	# world/map/camera/clock, which are all valid only here.
	if _runtime_host.military_map_layers != null:
		_runtime_host.military_map_layers.configure(map, _world_data, _camera,
			_world_clock, _runtime_host)
	# ---- Military layers
	_cell_situations.configure(map, _camera, _runtime_host,
		generator.get_economy_facade(), view_adapter)
	_renderer.configure_trade_visuals(_trade_activity)
	if _runtime_host.military_map_layers != null \
			and _runtime_host.military_map_layers.token_layer != null:
		_renderer.configure_military_visuals(
			_runtime_host.military_map_layers.token_layer)
	_ui_manager.set_world_context(
		map,
		generator,
		view_adapter,
		_world_clock,
		_runtime_host.sea_level,
		_runtime_host.hex_size
	)
	_ui_manager.set_world_summary(map.width, map.height, map.cell_count(), _runtime_host.last_seed())
	print("[player-ready-step] UI context %.1fms" % [float(Time.get_ticks_usec()-ready_t0)/1000.0])
	await get_tree().process_frame
	_player_controller.sync_ui()
	var start_report: Dictionary = generator.gameplay_start_report() \
		if generator != null and generator.has_method("gameplay_start_report") else {}
	if bool(start_report.get("ok", false)):
		if not _runtime_host.is_loading_session():
			var start_cell := map.cell_at(int(start_report.get("cell", -1)))
			if start_cell != null:
				await get_tree().process_frame
				var select_t0 := Time.get_ticks_usec()
				_player_controller.select_cell(start_cell)
				print("[player-ready-step] select %.1fms" % [float(Time.get_ticks_usec()-select_t0)/1000.0])
		var flow: Node = _game_flow()
		if flow != null:
			flow.set_session({
				"new_game_config": _runtime_host.session_config(),
				"player_country_id": "country.player",
				"start_cell": int(start_report.get("cell", -1)),
				"precious_resource": String(start_report.get("precious_resource", "")),
			})
	var save: Node = _game_save()
	if save != null:
		save.apply_pending_view(map)

	_ui_manager.hide_loading()

func _on_world_generation_failed(reason: String) -> void:
	# autotest 会话：把生成失败原因码立刻推进事件流（非 autotest 时是 no-op）。
	# 结构化的 stage/reason 由 host 挂在 last_world_generation_error 上，一并上报。
	var host_error: Dictionary = _runtime_host.last_world_generation_error \
		if _runtime_host != null else {}
	WebAutotestScript.report_failure("world_generation_failed", {
		"message": reason,
		"stage": String(host_error.get("stage", "")),
		"reason": String(host_error.get("reason", "")),
	})
	# 失败面板升级：摘要（一行中文）+ 可滚动/可全选的完整详情 + "复制详情" + 落盘。
	var overlay := _ui_manager.get_node("UIRoot/ModalLayer/WorldLoadingOverlay") as WorldLoadingOverlay
	if overlay == null:
		return
	var detail := _runtime_host.last_world_generation_error_text() \
		if _runtime_host != null else ""
	overlay.show_failure_detailed(reason, detail)


func _on_fit_requested() -> void:
	_runtime_host.fit_camera(_ui_manager.map_safe_area())


func _on_regenerate_requested() -> void:
	_regenerate_world()


## 失败面板「重试」：**原样重放本场景的会话请求**，绝不另生成一张世界。
##
## 旧实现直接 `generate_world(0)`，那条路径把 0 解析成随机 seed（map_generator.gd
## generate()），却不重新 `configure_session`、也不清 `_pending_load_bundle`：
## 读档失败后点重试 = 把存档的 PKCN/领土恢复进一张随机世界，视野收尾必然报
## 「读档后无法绑定玩家国家，视野不可解算」（同版本、稳定复现）。
func _retry_session() -> void:
	_player_controller.clear_selection()
	_ui_manager.show_loading("正在重试...")
	await get_tree().process_frame
	var retry_request: Dictionary = _session_request.duplicate(true)
	if retry_request.is_empty():
		retry_request = {"kind": "new_game",
			"config": NewGameConfig.create_default().to_dictionary()}
	var prepared: Dictionary = _runtime_host.configure_session(retry_request)
	if not bool(prepared.get("ok", false)):
		_ui_manager.show_loading(String(prepared.get("message", "会话初始化失败。")))
		return
	_ui_manager.show_loading("正在生成世界...")
	await get_tree().process_frame
	await get_tree().process_frame
	await _runtime_host.generate_world(-1, _ui_manager.map_safe_area())


## 调试入口：重掷一张新世界（失败面板的重试不走这里）。
##
## 必须先把新 seed 写进会话 config 再生成，否则「存档记录的 seed」无法复现
## 「实际生成的世界」，下次读档会在 start_cell_drift 处必然失败。
func _regenerate_world() -> void:
	# 重生成期间保留全局音乐，世界就绪后由 PlayerController 同步时代。
	_player_controller.clear_selection()
	_ui_manager.show_loading("正在重生成世界...")
	await get_tree().process_frame
	var config: Dictionary = _runtime_host.session_config().duplicate(true)
	if config.is_empty():
		config = NewGameConfig.create_default().to_dictionary()
	var base = config.get("base", {})
	if base is Dictionary:
		# 显式掷一个新的非零 seed 并写进 config。不能用 0：NewGameConfig.validate()
		# 要求 1..MAX_SEED，生成期的「0=随机」（cfg.seed != 0 else randi()）只适用
		# 于绕过 validate 的开发生成路径。
		(base as Dictionary)["initial_seed"] = NewGameConfig.random_seed()
	var rerolled_request := {"kind": "new_game", "config": config}
	var prepared: Dictionary = _runtime_host.configure_session(rerolled_request)
	if not bool(prepared.get("ok", false)):
		_ui_manager.show_loading(String(prepared.get("message", "会话初始化失败。")))
		return
	_session_request = rerolled_request.duplicate(true)
	await get_tree().process_frame
	await _runtime_host.generate_world(-1, _ui_manager.map_safe_area())


func _on_day_night_toggled(enabled: bool) -> void:
	day_night_enabled = enabled
	_runtime_host.set_day_night_enabled(enabled)
	_ui_manager.set_day_night_enabled(enabled)


func _on_gm_runtime_toggle_changed(toggle_id: String, enabled: bool) -> void:
	if toggle_id == "ui.suppress_popups":
		if _player_controller != null:
			_player_controller.set_popups_suppressed(enabled)
		if _ui_manager != null and _ui_manager.has_method("set_popups_suppressed"):
			_ui_manager.set_popups_suppressed(enabled)
	elif toggle_id == "simulation.paused":
		_player_controller.sync_ui()
	elif toggle_id == "ui.hide_all_except_gm":
		if enabled and _player_controller != null:
			_player_controller.set_popups_suppressed(true)
		if _ui_manager != null and _ui_manager.has_method("set_all_ui_suppressed"):
			_ui_manager.set_all_ui_suppressed(enabled)
	elif toggle_id == "visual.day_night":
		day_night_enabled = enabled


func _unhandled_key_input(event: InputEvent) -> void:
	# Compatibility entry point for existing smoke tests and embedded tools.
	# Production input is received by PlayerController directly.
	_player_controller.handle_input(event)


func _request_return_main_menu() -> void:
	var save: Node = _game_save()
	var result: Dictionary = await save.request_autosave("return_to_main_menu") \
		if save != null else {"ok": false, "message": "存档服务尚未就绪。"}
	if bool(result.get("ok", false)):
		var flow: Node = _game_flow()
		if flow != null:
			flow.return_to_main_menu()
	else:
		_ui_manager.show_exit_save_failure("menu", result)


func _request_exit_game() -> void:
	var save: Node = _game_save()
	var result: Dictionary = await save.request_autosave("exit") \
		if save != null else {"ok": false, "message": "存档服务尚未就绪。"}
	if bool(result.get("ok", false)):
		var flow: Node = _game_flow()
		if flow != null:
			flow.quit_game()
	else:
		_ui_manager.show_exit_save_failure("exit", result)


func _push_visual_toggles() -> void:
	if _renderer == null:
		return
	# [mobile-msaa 2026-11-03] 真机反馈"六边形边缘/海陆边界在移动时闪烁"：静态截图逐字节
	# 相同（不是重建/动画），移动时闪 ⇒ 几何边缘的走样。触摸档开 2x MSAA 直接抗掉这类
	# 细线/边缘抖动；桌面保持默认（不开），避免影响既有截图与性能基线。
	var viewport := get_viewport()
	if viewport != null:
		viewport.msaa_2d = Viewport.MSAA_2X if _touch_profile() else Viewport.MSAA_DISABLED
	var settings: Node = _game_settings()
	var quality_values: Dictionary = settings.values() if settings != null else {}
	var quality_setting := String(quality_values.get("render_quality", "auto"))
	visual_quality = _resolved_visual_quality(quality_setting)
	# mobile/web：编译期 MOBILE_QUALITY_* 档必须在 set_visual_quality 之前推送。
	if DCFeatureFlags.uses_shader_quality_tier() and _renderer.has_method("set_mobile_quality_tier"):
		_renderer.set_mobile_quality_tier(_shader_quality_define_from_setting(quality_setting))
	if _renderer.has_method("set_visual_quality"):
		_renderer.set_visual_quality(visual_quality)
	if _trade_activity != null:
		_trade_activity.set_quality(visual_quality)
	if _renderer.has_method("set_perf_sampler_enabled"):
		_renderer.set_perf_sampler_enabled(perf_sampler_enabled)
	_runtime_host.set_day_night_enabled(day_night_enabled)
	_ui_manager.set_day_night_enabled(day_night_enabled)
	_apply_render_debug_overrides()


## [render-qa 2026-11-02] 画质特性二分的临时开关（QA 专用，只在 user://pk_debug.cfg
## 存在时生效，正常玩家没有这个文件 ⇒ 完全 no-op）。
##
##   [render]
##   visual_quality = 0|1|2   # 覆盖 PBR/线性光照/ACES 这些运行期档位
##   hide = "vegetation,maximpostor,fog,weather"   # 按节点名子串隐藏渲染层
##
## 用途：不重新导出就能在真机上逐项关掉渲染层量 fps，定位 LOW→MID 的台阶在哪。
func _apply_render_debug_overrides() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://pk_debug.cfg") != OK:
		return
	if cfg.has_section_key("render", "tier_override"):
		# 把编译期档位强制成 LOW/MID/HIGH，用来分离"编译期 #define 开销"和
		# "运行期 uniform 开销"：设置仍按玩家档位，只有 shader 前缀被改写。
		var tier_name := String(cfg.get_value("render", "tier_override")).strip_edges()
		if tier_name != "" and _renderer.has_method("set_mobile_quality_tier"):
			_renderer.set_mobile_quality_tier(tier_name)
	if cfg.has_section_key("render", "visual_quality"):
		var forced := int(cfg.get_value("render", "visual_quality"))
		if forced >= 0 and forced <= 2 and forced != visual_quality:
			visual_quality = forced
			if _renderer.has_method("set_visual_quality"):
				_renderer.set_visual_quality(forced)
			if _trade_activity != null:
				_trade_activity.set_quality(forced)
	var hide := String(cfg.get_value("render", "hide", "")).strip_edges()
	if hide == "":
		return
	var needles := PackedStringArray()
	for token in hide.split(","):
		var needle := token.strip_edges().to_lower()
		if needle != "":
			needles.append(needle)
	_set_layers_hidden(_renderer, needles)


func _set_layers_hidden(root: Node, needles: PackedStringArray) -> void:
	if root == null:
		return
	for child in root.get_children():
		var node_name := String(child.name).to_lower()
		var matched := false
		for needle in needles:
			if node_name.contains(needle):
				matched = true
				break
		if matched:
			var item := child as CanvasItem
			if item != null:
				item.visible = false
			# 只设 visible=false 不会停掉 _process：层的实例更新（每帧重算
			# MultiMesh 变换/预算）照跑。二分"CPU 侧层开销"时必须一起停。
			child.set_process(false)
			child.set_physics_process(false)
			continue
		_set_layers_hidden(child, needles)
	var weather_layer := _renderer.get_node_or_null("WeatherLayer")
	if weather_layer != null and weather_layer.has_method("set_visual_quality"):
		weather_layer.set_visual_quality(visual_quality)


func _on_settings_changed(_settings: Dictionary) -> void:
	_push_visual_toggles()


func _resolved_visual_quality(quality: String) -> int:
	match quality:
		"low":
			return 0
		"medium":
			return 1
		"high":
			return 2
		_:
			# auto：mobile/web 默认 LOW；桌面默认 HIGH。
			return 0 if DCFeatureFlags.uses_shader_quality_tier() else 2


func _mobile_quality_tier_to_define(tier: int) -> String:
	match tier:
		0:
			return "MOBILE_QUALITY_LOW"
		1:
			return "MOBILE_QUALITY_MID"
		2:
			return "MOBILE_QUALITY_HIGH"
		_:
			return "MOBILE_QUALITY_MID"


func _shader_quality_define_from_setting(quality: String) -> String:
	# [web 编译期档钉死 LOW] Web 上「这一档」是**编译期宏**：换档 = 换 shader 源码 =
	# 换一个 program。而菜单期的 shader 预热（web_shader_warmup.gd）只能在菜单里按
	# 一个固定档编一遍 —— 它读不到进游戏后才生效的画质设置。玩家一旦在设置里选
	# 中/高，运行期前缀就与预热不同 ⇒ 驱动缓存必然不命中 ⇒ 所有 tier-dependent
	# shader 在游戏里重编一次（实测单张 world_map 就是 20 s 量级）。
	# Web 的编译期档仍固定 LOW，但它不再代表最终画质：visual_quality>=1
	# 在同一预热程序中启用地形 PBR/线性光照/ACES；植被同样按运行期档
	# 启用四类近景形态与法线着色。切档只改 uniform/实例预算，不换程序。
	if OS.has_feature("web"):
		return "MOBILE_QUALITY_LOW"
	# [mobile-pin-low 2026-11-02] 安卓真机实测（小米 15 / 2670x1200 / 2400 格，同图同视角）：
	#   MOBILE_QUALITY_MID  → 31~33 fps，单日成本 28~36ms
	#   MOBILE_QUALITY_HIGH → 26.5 fps
	#   MOBILE_QUALITY_LOW + visual_quality=2（运行期 PBR/线性光照/ACES 全开）
	#                        → 56~61 fps，单日成本 7~9ms
	# 也就是说「中/高编译期档」在移动 GPU 上多出来的那些每像素分支
	# （water_pipeline / world_map / country_border / hex_edge_overlay 的
	# `#if !defined(PK_QUALITY_LOW)` 段）几乎吃掉一半帧率，而运行期画质档
	# （PBR/光照/ACES）几乎免费。Web 早就是这么做的（上面的注释），移动端现在对齐：
	# 编译期固定 LOW，画质由 visual_quality 决定。
	#
	# 逃生口：pk_debug.cfg 里 `[render] mobile_shader_tier="MOBILE_QUALITY_MID|HIGH"`
	# 或环境变量 PK_MOBILE_SHADER_TIER，可回退到旧行为做对比测试。
	var tier_override := OS.get_environment("PK_MOBILE_SHADER_TIER").strip_edges()
	if tier_override == "":
		var debug_cfg := ConfigFile.new()
		if debug_cfg.load("user://pk_debug.cfg") == OK:
			tier_override = String(debug_cfg.get_value("render", "mobile_shader_tier", "")).strip_edges()
	if tier_override != "":
		return tier_override
	return "MOBILE_QUALITY_LOW"
	match quality:
		"medium":
			return "MOBILE_QUALITY_MID"
		"high":
			return "MOBILE_QUALITY_HIGH"
		"auto", "low":
			return "MOBILE_QUALITY_LOW"
		_:
			return "MOBILE_QUALITY_LOW"


func _game_flow() -> Node:
	return get_node_or_null("/root/GameFlow")


func _game_save() -> Node:
	return get_node_or_null("/root/GameSave")


func _game_settings() -> Node:
	return get_node_or_null("/root/GameSettings")


## ─── 运行时哨兵（安卓"卡死"取证）──────────────────────────────────────
## 玩家只看到"卡死"，日志里却什么都没有。这两行用最小成本把三种情况分开：
##   [heartbeat] 正常刷新 → 主线程活着，看 day 是否前进判断仿真是否在跑；
##   [stall]     单帧 ≥2s → 主线程被阻塞（渲染/原生调用），frame_ms 就是阻塞时长；
##   两者都没有        → 主线程被彻底卡死（死循环/死锁），最后一条日志就是现场。
const SENTINEL_HEARTBEAT_MS := 5000
const SENTINEL_STALL_MS := 2000
var _sentinel_started_ms := 0
var _sentinel_last_ms := 0
var _sentinel_frames := 0
var _sentinel_stall_count := 0
## 调试截图：`PK_SCREENSHOT_AFTER_MS=15000` 时在进入世界 15 秒后存一张 PNG 到 user://，
## 用于在没有真机/远控的环境里核对"游戏内 HUD 在手机尺寸下长什么样"。正式包不受影响。
var _sentinel_shot_times: Array[int] = []
var _sentinel_shot_done := false
## PK_UI_SHOT_PANEL 的一次性状态（见 _process 里的 ui-shot-panel 段）。
var _ui_shot_panel_done := false
var _ui_shot_panel_opened := false
var _ui_shot_panel_ms := 0


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _sentinel_started_ms == 0:
		_sentinel_started_ms = now
		_sentinel_last_ms = now
		# 支持逗号列表：PK_SCREENSHOT_AFTER_MS="12000,45000" 会在两个时间点各存一张。
		var shot_env := OS.get_environment("PK_SCREENSHOT_AFTER_MS").strip_edges()
		if not shot_env.is_empty():
			for part in shot_env.split(","):
				var ms := int(part.strip_edges().to_int())
				if ms > 0:
					_sentinel_shot_times.append(ms)
			_sentinel_shot_times.sort()
	while not _sentinel_shot_times.is_empty() \
			and now - _sentinel_started_ms >= _sentinel_shot_times[0]:
		var shot_ms: int = _sentinel_shot_times.pop_front()
		_capture_debug_screenshot(shot_ms)
	# [ui-shot-panel 2026-11-02] 无真机也能核对"某个面板在手机尺寸下长什么样"：
	#   PK_UI_SHOT_PANEL=gm | country | country:economy
	#   PK_UI_SHOT_DELAY_MS=18000   （进入世界后多久打开面板并截图，默认 18 秒）
	# 打开面板后等一帧再截，避免截到布局还没结算的中间态。正式包不设这些变量 ⇒ 不生效。
	if not _ui_shot_panel_done:
		var panel_spec := OS.get_environment("PK_UI_SHOT_PANEL").strip_edges()
		if not panel_spec.is_empty():
			var delay_ms := int(OS.get_environment("PK_UI_SHOT_DELAY_MS").strip_edges().to_int())
			if delay_ms <= 0:
				delay_ms = 18000
			if _ui_shot_panel_opened:
				if now - _ui_shot_panel_ms >= 250:
					_capture_debug_screenshot(-1, "panel_%s" % panel_spec.replace(":", "_"))
					_ui_shot_panel_done = true
			elif now - _sentinel_started_ms >= delay_ms and _ui_manager != null:
				_ui_shot_panel_opened = true
				_ui_shot_panel_ms = now
				if panel_spec == "gm":
					_ui_manager.toggle_gm_panel()
				elif panel_spec.begins_with("country"):
					var chapter := panel_spec.get_slice(":", 1) if panel_spec.contains(":") else ""
					_ui_manager.open_country_section("economy", chapter)
				else:
					# 其它国家事务页签：PK_UI_SHOT_PANEL=technology | military | economy …
					_ui_manager.open_country_section(panel_spec, "")
				print("[ui-shot] opened panel=%s" % panel_spec)
	_sentinel_frames += 1
	var frame_ms := int(round(delta * 1000.0))
	if frame_ms >= SENTINEL_STALL_MS:
		_sentinel_stall_count += 1
		print("[stall] frame_ms=%d day=%s speed=%.2f stalls=%d" % [
			frame_ms, str(_current_day()), _current_speed(), _sentinel_stall_count])
	var elapsed := now - _sentinel_last_ms
	if elapsed < SENTINEL_HEARTBEAT_MS:
		return
	var fps := float(_sentinel_frames) * 1000.0 / maxf(float(elapsed), 1.0)
	var eco := _economy_probe()
	print("[heartbeat] day=%s speed=%.2f fps=%.1f stalls=%d scale=%.3f eco_day=%s graph=%s window=%dx%d" % [
		str(_current_day()), _current_speed(), fps, _sentinel_stall_count,
		_ui_scale(), str(eco["eco_day"]), str(eco["graph"]),
		DisplayServer.window_get_size().x, DisplayServer.window_get_size().y])
	# 主线程在跑、日期在涨、经济日结却停住 → 这是"经济不动"的唯一可判定信号。
	# 连续 3 天不推进就打一行，日志里一眼能看到卡在哪一侧。
	var day := int(_current_day())
	if day > 3 and int(eco["eco_day"]) >= 0 and day - int(eco["eco_day"]) > 3:
		print("[economy-stall] day=%d eco_day=%d graph=%s paused=%s speed=%.2f" % [
			day, int(eco["eco_day"]), str(eco["graph"]),
			str(_world_clock.paused if _world_clock != null else true), _current_speed()])
	_sentinel_last_ms = now
	_sentinel_frames = 0


## 经济日结水位 + 原生图是否在跑。失败时返回 -1 / false，绝不抛错（哨兵不能拖垮主循环）。
func _economy_probe() -> Dictionary:
	var out := {"eco_day": -1, "graph": false}
	if _runtime_host == null or not _runtime_host.has_method("get_generator"):
		return out
	var generator = _runtime_host.get_generator()
	if generator == null:
		return out
	if generator.has_method("runtime_graph_active"):
		out["graph"] = bool(generator.runtime_graph_active())
	if generator.has_method("get_economy_facade"):
		var facade = generator.get_economy_facade()
		if facade != null and facade.has_method("report"):
			var report: Dictionary = facade.report()
			out["eco_day"] = int(report.get("newest_state_day", -1))
	return out


func _capture_debug_screenshot(shot_ms: int = 0, tag: String = "") -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		print("[screenshot] capture failed")
		return
	var suffix := "" if tag.is_empty() else "_" + tag
	var path := "user://debug_shot_%d_at%dms%s.png" % [Time.get_ticks_msec(), shot_ms, suffix]
	var err := image.save_png(path)
	print("[screenshot] %s err=%d size=%dx%d" % [path, err, image.get_width(), image.get_height()])


func _current_day() -> int:
	return _world_clock.day_index() if _world_clock != null else -1


func _current_speed() -> float:
	return _world_clock.speed_multiplier if _world_clock != null else 0.0


func _ui_scale() -> float:
	var settings := _game_settings()
	if settings != null and settings.has_method("ui_scaling"):
		var scaling = settings.call("ui_scaling")
		if scaling != null and scaling.has_method("total_scale"):
			return float(scaling.call("total_scale"))
	return 1.0


## 当前是否是触摸档（手机/平板）。桌面恒 false，用于把移动端专用的渲染开关隔离开。
func _touch_profile() -> bool:
	var settings := _game_settings()
	if settings != null and settings.has_method("ui_scaling"):
		var scaling = settings.call("ui_scaling")
		if scaling != null and scaling.has_method("is_touch_profile"):
			return bool(scaling.call("is_touch_profile"))
	return false
