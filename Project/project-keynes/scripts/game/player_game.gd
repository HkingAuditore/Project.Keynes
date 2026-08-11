extends Node2D
class_name PlayerGame

const MAIN_MENU_SCENE_PATH := "res://scenes/main_menu.tscn"
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
@onready var _map_overlay: DataOverlayLayer = $WorldRoot/DataOverlayLayer
@onready var _colonization_route: ColonizationRouteLayer = $WorldRoot/ColonizationRouteLayer
@onready var _world_clock: WorldClock = $WorldClock
@onready var _runtime_host: WorldRuntimeHost = $RuntimeHost
@onready var _ui_manager: GameUIManager = $UI
@onready var _player_controller = $PlayerController

var _viewport_refit_pending := false


func _ready() -> void:
	if OS.has_feature("mobile"):
		PKLog.enabled = false
	_configure_runtime()
	var flow: Node = _game_flow()
	var request: Dictionary = flow.consume_request() if flow != null else {}
	if request.is_empty():
		var fallback := NewGameConfig.create_default()
		request = {"kind": "new_game", "config": fallback.to_dictionary()}
	var session_result := _runtime_host.configure_session(request)
	if not bool(session_result.get("ok", false)):
		_ui_manager.show_loading(String(session_result.get("message", "会话初始化失败。")))
		return
	_connect_signals()
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_push_visual_toggles()
	_ui_manager.show_loading("正在生成世界...")
	await get_tree().process_frame
	await get_tree().process_frame
	await _runtime_host.generate_world(-1, _ui_manager.map_safe_area())


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
	_runtime_host.configure(_renderer, _camera, _world_clock, _map_overlay)
	_ui_manager.set_diagnostics_source(_runtime_host)
	_player_controller.configure(_camera, _highlight, _runtime_host, _world_clock, _ui_manager)
	_ui_manager.set_colonization_route_layer(_colonization_route)
	var save: Node = _game_save()
	if save != null:
		save.bind_runtime(_runtime_host, _world_clock, _player_controller)


func _connect_signals() -> void:
	_runtime_host.world_ready.connect(_on_world_ready)
	_runtime_host.world_generation_failed.connect(_on_world_generation_failed)
	_runtime_host.generation_progress.connect(_ui_manager.set_generation_progress)
	_runtime_host.gm_toggle_changed.connect(_on_gm_runtime_toggle_changed)
	_player_controller.selection_changed.connect(_runtime_host.set_selected_cell)
	_player_controller.regeneration_requested.connect(_regenerate_world)
	_ui_manager.fit_requested.connect(_on_fit_requested)
	_ui_manager.regenerate_requested.connect(_on_regenerate_requested)
	_ui_manager.setup_requested.connect(_return_to_world_setup)
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
	_player_controller.refresh_country_binding()
	_player_controller.clear_selection()
	_ui_manager.set_world_context(
		map,
		generator,
		view_adapter,
		_world_clock,
		_runtime_host.sea_level,
		_runtime_host.hex_size
	)
	_ui_manager.set_world_summary(map.width, map.height, map.cell_count(), _runtime_host.last_seed())
	_ui_manager.hide_loading()
	_player_controller.sync_ui()
	var start_report: Dictionary = generator.gameplay_start_report() \
		if generator != null and generator.has_method("gameplay_start_report") else {}
	if bool(start_report.get("ok", false)):
		if not _runtime_host.is_loading_session():
			var start_cell := map.cell_at(int(start_report.get("cell", -1)))
			if start_cell != null:
				_player_controller.select_cell(start_cell)
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


func _on_world_generation_failed(reason: String) -> void:
	_ui_manager.show_loading("世界生成失败：%s" % reason)


func _on_fit_requested() -> void:
	_runtime_host.fit_camera(_ui_manager.map_safe_area())


func _on_regenerate_requested() -> void:
	_regenerate_world()


func _regenerate_world() -> void:
	_player_controller.clear_selection()
	_ui_manager.show_loading("正在重生成世界...")
	await get_tree().process_frame
	await get_tree().process_frame
	await _runtime_host.generate_world(0, _ui_manager.map_safe_area())


func _return_to_world_setup() -> void:
	var flow: Node = _game_flow()
	if flow != null:
		flow.return_to_main_menu()


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
