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
	loading.retry_requested.connect(_regenerate_world)
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
	_cell_situations.configure(map, _camera, _runtime_host,
		generator.get_economy_facade(), view_adapter)
	_renderer.configure_trade_visuals(_trade_activity)
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


func _regenerate_world() -> void:
	# 重生成期间保留全局音乐，世界就绪后由 PlayerController 同步时代。
	_player_controller.clear_selection()
	_ui_manager.show_loading("正在重生成世界...")
	await get_tree().process_frame
	await get_tree().process_frame
	await _runtime_host.generate_world(0, _ui_manager.map_safe_area())


func _on_day_night_toggled(enabled: bool) -> void:
	day_night_enabled = enabled
	_runtime_host.set_day_night_enabled(enabled)
	_ui_manager.set_day_night_enabled(enabled)


func _on_gm_runtime_toggle_changed(toggle_id: String, enabled: bool) -> void:
	if toggle_id == "simulation.paused":
		_player_controller.sync_ui()
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


func _capture_debug_screenshot(shot_ms: int = 0) -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		print("[screenshot] capture failed")
		return
	var path := "user://debug_shot_%d_at%dms.png" % [Time.get_ticks_msec(), shot_ms]
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
