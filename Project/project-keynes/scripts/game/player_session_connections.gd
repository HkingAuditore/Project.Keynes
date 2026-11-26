extends RefCounted

## Binds the formal player node to the clock, runtime, camera, and UI signals.


static func configure(owner: PlayerController,
		camera,
		highlight,
		runtime_host,
		world_clock,
		ui_manager
) -> void:
	if is_instance_valid(owner._world_clock):
		for signal_name in PlayerController.CLOCK_CALLBACKS:
			var callback := Callable(owner, PlayerController.CLOCK_CALLBACKS[signal_name])
			if owner._world_clock.is_connected(signal_name, callback):
				owner._world_clock.disconnect(signal_name, callback)
	owner._camera = camera
	owner._highlight = highlight
	owner._runtime_host = runtime_host
	owner._world_clock = world_clock
	owner._ui_manager = ui_manager
	owner.AudioPresentation._apply_camera_view_scale_compensation(owner)
	owner._connect_runtime()
	owner.SessionConnections._connect_ui(owner)
	owner._annual_report_flow.configure(owner, owner._runtime_host, owner._ui_manager)
	owner._configure_narrative_runtime()
	if owner._music_playback == null:
		owner._music_playback = PlayerController.MusicSituationPlaybackScript.new()
		owner._music_playback.situation = owner._music_situation
		owner.add_child(owner._music_playback)
	owner.sync_ui()



static func _connect_runtime(owner: PlayerController) -> void:
	if owner._camera != null and not owner._camera.tile_tapped.is_connected(owner._on_tile_tapped):
		owner._camera.tile_tapped.connect(owner._on_tile_tapped)
	if owner._camera != null and owner._camera.has_signal("zoom_changed") \
			and not owner._camera.zoom_changed.is_connected(owner._on_camera_zoom_changed):
		owner._camera.zoom_changed.connect(owner._on_camera_zoom_changed)
	if owner._camera != null and owner._camera.has_signal("view_changed") \
			and not owner._camera.view_changed.is_connected(owner._on_camera_view_changed):
		owner._camera.view_changed.connect(owner._on_camera_view_changed)
	if owner._runtime_host != null:
		var runtime_callbacks := {"simulation_committed": owner._on_simulation_committed,
			"simulation_day_records": owner._on_simulation_day_records,
			"simulation_command_results": owner._on_simulation_command_results,
			"player_confirmation_updated": owner._on_player_confirmation_updated,
			"colonization_quotes_ready": owner.colonization_quotes_ready.emit,
			"simulation_ui_updated": owner._on_simulation_ui_updated,
			"simulation_view_updated": owner._on_simulation_view_updated}
		for event in runtime_callbacks:
			if owner._runtime_host.has_signal(event) and not owner._runtime_host.is_connected(event, runtime_callbacks[event]):
				owner._runtime_host.connect(event, runtime_callbacks[event])
	if owner._world_clock == null:
		return
	for signal_name in PlayerController.CLOCK_CALLBACKS:
		var callback := Callable(owner, PlayerController.CLOCK_CALLBACKS[signal_name])
		if not owner._world_clock.is_connected(signal_name, callback):
			owner._world_clock.connect(signal_name, callback,
				CONNECT_DEFERRED if signal_name == &"control_changed" else 0)



static func _connect_ui(owner: PlayerController) -> void:
	if owner._ui_manager == null:
		return
	if not owner._ui_manager.pause_toggled.is_connected(owner._on_pause_toggled):
		owner._ui_manager.pause_toggled.connect(owner._on_pause_toggled)
	if not owner._ui_manager.speed_selected.is_connected(owner._on_speed_selected):
		owner._ui_manager.speed_selected.connect(owner._on_speed_selected)
	if not owner._ui_manager.clear_selection_requested.is_connected(owner.clear_selection):
		owner._ui_manager.clear_selection_requested.connect(owner.clear_selection)
	if not owner._ui_manager.pause_menu_visibility_changed.is_connected(owner._on_pause_menu_visibility_changed):
		owner._ui_manager.pause_menu_visibility_changed.connect(owner._on_pause_menu_visibility_changed)
	if owner._ui_manager.has_signal("era_reward_choice_requested") and not \
			owner._ui_manager.era_reward_choice_requested.is_connected(
				owner._on_era_reward_choice_requested):
		owner._ui_manager.era_reward_choice_requested.connect(
			owner._on_era_reward_choice_requested)
	if not owner._ui_manager.era_reward_open_requested.is_connected(owner.open_era_reward_offer):
		owner._ui_manager.era_reward_open_requested.connect(owner.open_era_reward_offer)
	if not owner._ui_manager.era_reward_dismiss_requested.is_connected(owner.dismiss_era_reward_offer):
		owner._ui_manager.era_reward_dismiss_requested.connect(owner.dismiss_era_reward_offer)
	if owner._ui_manager.has_signal("family_founding_choice_requested") and not \
			owner._ui_manager.family_founding_choice_requested.is_connected(
				owner._on_family_founding_choice_requested):
		owner._ui_manager.family_founding_choice_requested.connect(
			owner._on_family_founding_choice_requested)
	owner._ui_manager.set_player_controller(owner)
	owner.refresh_country_binding()
