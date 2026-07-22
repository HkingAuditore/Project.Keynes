extends Node2D
class_name PlayerGame

const WORLD_SETUP_SCENE_PATH := "res://scenes/world_setup.tscn"

# 桌面玩家场景与调试场景共用高画质基线；移动端仍由 mobile quality tier 控制预算。
@export_range(0, 2, 1) var visual_quality: int = 2
@export_range(0, 2, 1) var mobile_quality_tier: int = 0
@export var perf_sampler_enabled: bool = false
@export var day_night_enabled: bool = true

@onready var _renderer: HexRenderer = $WorldRoot/HexRenderer
@onready var _camera: MapCamera = $MapCamera
@onready var _highlight: CellHighlight = $WorldRoot/CellHighlight
@onready var _world_clock: WorldClock = $WorldClock
@onready var _runtime_host: WorldRuntimeHost = $RuntimeHost
@onready var _ui_manager: GameUIManager = $UI
@onready var _map_interaction: MapInteractionController = $Controllers/MapInteractionController
@onready var _selection: SelectionController = $Controllers/SelectionController
@onready var _time_controls: TimeControlsController = $Controllers/TimeControlsController

var _viewport_refit_pending := false


func _ready() -> void:
	if OS.has_feature("mobile"):
		PKLog.enabled = false
	_configure_runtime()
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
	_runtime_host.configure(_renderer, _camera, _world_clock)
	_ui_manager.set_diagnostics_source(_runtime_host)
	_map_interaction.configure(_camera, _runtime_host)
	_selection.configure(_highlight, _camera, _runtime_host, _ui_manager)
	_time_controls.configure(_world_clock, _runtime_host, _ui_manager)


func _connect_signals() -> void:
	_runtime_host.world_ready.connect(_on_world_ready)
	_runtime_host.world_generation_failed.connect(_on_world_generation_failed)
	_runtime_host.generation_progress.connect(_ui_manager.set_generation_progress)
	_map_interaction.cell_selected.connect(_selection.select_cell)
	_selection.selection_changed.connect(_runtime_host.set_selected_cell)
	_ui_manager.fit_requested.connect(_on_fit_requested)
	_ui_manager.regenerate_requested.connect(_on_regenerate_requested)
	_ui_manager.setup_requested.connect(_return_to_world_setup)
	_ui_manager.clear_selection_requested.connect(_selection.clear_selection)
	_ui_manager.day_night_toggled.connect(_on_day_night_toggled)


func _on_world_ready(
		map: MapData,
		_world_data: WorldData,
		generator: MapGenerator,
		view_adapter: DCViewAdapter
) -> void:
	_selection.clear_selection()
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
	_time_controls.sync_ui()


func _on_world_generation_failed(reason: String) -> void:
	_ui_manager.show_loading("世界生成失败：%s" % reason)


func _on_fit_requested() -> void:
	_runtime_host.fit_camera(_ui_manager.map_safe_area())


func _on_regenerate_requested() -> void:
	_regenerate_world()


func _regenerate_world() -> void:
	_selection.clear_selection()
	_ui_manager.show_loading("正在重生成世界...")
	await get_tree().process_frame
	await get_tree().process_frame
	await _runtime_host.generate_world(0, _ui_manager.map_safe_area())


func _return_to_world_setup() -> void:
	get_tree().change_scene_to_file(WORLD_SETUP_SCENE_PATH)


func _on_day_night_toggled(enabled: bool) -> void:
	day_night_enabled = enabled
	_runtime_host.set_day_night_enabled(enabled)
	_ui_manager.set_day_night_enabled(enabled)


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_QUOTELEFT, KEY_F1:
			_ui_manager.toggle_gm_panel()
		KEY_F4:
			_ui_manager.toggle_perf_hud()
		KEY_R:
			_regenerate_world()
		KEY_F:
			_runtime_host.fit_camera(_ui_manager.map_safe_area())
		KEY_SPACE:
			_world_clock.toggle_pause()
			_time_controls.sync_ui()
		KEY_ESCAPE:
			_selection.clear_selection()


func _push_visual_toggles() -> void:
	if _renderer == null:
		return
	if OS.has_feature("mobile") and _renderer.has_method("set_mobile_quality_tier"):
		_renderer.set_mobile_quality_tier(_mobile_quality_tier_to_define(mobile_quality_tier))
	if _renderer.has_method("set_visual_quality"):
		_renderer.set_visual_quality(visual_quality)
	if _renderer.has_method("set_perf_sampler_enabled"):
		_renderer.set_perf_sampler_enabled(perf_sampler_enabled)
	_runtime_host.set_day_night_enabled(day_night_enabled)
	_ui_manager.set_day_night_enabled(day_night_enabled)
	var weather_layer := _renderer.get_node_or_null("WeatherLayer")
	if weather_layer != null and weather_layer.has_method("set_visual_quality"):
		weather_layer.set_visual_quality(visual_quality)


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
