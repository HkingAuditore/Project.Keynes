extends Node
class_name TimeControlsController

var _world_clock: WorldClock = null
var _runtime_host: WorldRuntimeHost = null
var _ui_manager: GameUIManager = null


func configure(
		world_clock: WorldClock,
		runtime_host: WorldRuntimeHost,
		ui_manager: GameUIManager
) -> void:
	_world_clock = world_clock
	_runtime_host = runtime_host
	_ui_manager = ui_manager
	_connect_clock()
	_connect_ui()
	sync_ui()


func sync_ui() -> void:
	_sync_ui()


func _connect_clock() -> void:
	if _world_clock == null:
		return
	if not _world_clock.day_changed.is_connected(_on_day_changed):
		_world_clock.day_changed.connect(_on_day_changed)
	if not _world_clock.season_changed.is_connected(_on_season_changed):
		_world_clock.season_changed.connect(_on_season_changed)
	if not _world_clock.year_changed.is_connected(_on_year_changed):
		_world_clock.year_changed.connect(_on_year_changed)
	if not _world_clock.visual_day_phase_changed.is_connected(_on_visual_day_phase_changed):
		_world_clock.visual_day_phase_changed.connect(_on_visual_day_phase_changed)
	if not _world_clock.speed_changed.is_connected(_on_speed_changed):
		_world_clock.speed_changed.connect(_on_speed_changed)


func _connect_ui() -> void:
	if _ui_manager == null:
		return
	if not _ui_manager.pause_toggled.is_connected(_on_pause_toggled):
		_ui_manager.pause_toggled.connect(_on_pause_toggled)
	if not _ui_manager.speed_selected.is_connected(_on_speed_selected):
		_ui_manager.speed_selected.connect(_on_speed_selected)


func _on_day_changed(day_idx: int) -> void:
	if _runtime_host == null or _world_clock == null:
		return
	var season_phase := _world_clock.season_phase_for_day(day_idx)
	_runtime_host.run_daily_tick(day_idx, season_phase)
	var ui_started_usec := Time.get_ticks_usec()
	var ui_breakdown: Dictionary = {}
	if _ui_manager != null:
		ui_breakdown = _ui_manager.refresh_selected_daily_lines(false, day_idx)
	_sync_ui()
	_runtime_host.finish_daily_tick(
		(Time.get_ticks_usec() - ui_started_usec) / 1000.0,
		ui_breakdown
	)


func _on_season_changed(season_idx: int) -> void:
	if _runtime_host != null:
		_runtime_host.on_season_changed(season_idx)
	if _ui_manager != null:
		_ui_manager.refresh_selected_daily_lines(true)
	_sync_ui()


func _on_year_changed(year_idx: int) -> void:
	if _runtime_host != null:
		_runtime_host.on_year_changed(year_idx)
	if _ui_manager != null:
		_ui_manager.refresh_selected_daily_lines(true)
	_sync_ui()


func _on_visual_day_phase_changed(visual_day_phase: float) -> void:
	if _runtime_host != null:
		_runtime_host.on_visual_day_phase_changed(visual_day_phase)
	_sync_ui()


func _on_speed_changed(new_speed: float) -> void:
	if _runtime_host != null:
		_runtime_host.on_speed_changed(new_speed)
	_sync_ui()


func _on_pause_toggled(paused: bool) -> void:
	if _world_clock == null:
		return
	_world_clock.pause(paused)
	_sync_ui()


func _on_speed_selected(speed: float) -> void:
	if _world_clock == null:
		return
	_world_clock.set_speed(speed)
	_world_clock.pause(false)
	_sync_ui()


func _sync_ui() -> void:
	if _ui_manager == null or _world_clock == null:
		return
	var calendar_date := _world_clock.calendar_date()
	_ui_manager.update_time_state(
		_world_clock.year_index(),
		int(calendar_date.month),
		int(calendar_date.day_of_month),
		_world_clock.paused,
		_world_clock.speed_multiplier
	)
