extends SceneTree

# Probe: era advance while the technology archive is open (the exact moment a
# player watches a milestone finish). Captures what the player can see.
#
#   godot --path . --script res://tests/probes/_probe_era_panel.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	root.add_child(game)
	await runtime.world_ready
	for _i in range(4):
		await process_frame
	var ui := game.get_node("UI") as GameUIManager
	var clock := game.get_node("WorldClock") as WorldClock
	var controller = ui.get("_player_controller")
	var badge: EraIndicator = ui.get("_era_indicator")
	var hud := game.get_node("UI/UIRoot/HUDLayer") as Control
	var panel := game.get_node("UI/UIRoot/PanelLayer/CountryPanel") as Control
	var facade = controller.get_country_facade()
	var handle := int(controller.get_player_country_handle())
	var milestones: PackedInt32Array = facade.era_milestone_indices()
	var ids: PackedStringArray = facade.get("_catalog").get("technology_ids", PackedStringArray())
	ui.open_country_section("technology")
	for _i in range(10):
		await process_frame
	print("[panel] country_panel visible=%s rect=%s" % [
		str(panel.visible), str(panel.get_global_rect())])
	print("[panel] hud visible=%s badge visible=%s badge rect=%s" % [
		str(hud.visible), str(badge.visible), str(badge.get_global_rect())])
	print("[panel] badge z_index=%d hud z_index=%d panel z_index=%d" % [
		badge.z_index, hud.z_index, panel.z_index])
	await _capture("panel_before")
	clock.pause(false)
	clock.set_speed(50.0)
	var tech := int(milestones[1])
	var granted: Dictionary = facade.grant_technology(handle, StringName(String(ids[tech])),
		int(clock.day_index()), 7)
	print("[panel] grant=%s" % str(granted))
	var deadline := Time.get_ticks_msec() + 120000
	var celebrated := false
	while Time.get_ticks_msec() < deadline:
		await process_frame
		# 会话内晋升由全屏大典（EraAscensionCeremony）接管；纸徽在新徽记飞回后才放礼花。
		if bool(ui.call("is_era_ceremony_playing")) or bool(badge.get("_celebrating")):
			celebrated = true
			break
	if celebrated:
		await create_timer(2.4).timeout
		await _capture("panel_advance_burst")
		await create_timer(1.6).timeout
		await _capture("panel_advance_title")
		await create_timer(4.0).timeout
		print("[panel] settled top_bar=%s badge_rect=%s icon=%s transfer=%s" % [
			_era_label(ui), str(badge.get_global_rect()), _icon_path(badge),
			str(ui.get("_era_transfer_name"))])
		await _capture("panel_settled")
		ui.close_country_panel()
		for _i in range(20):
			await process_frame
		await _capture("panel_closed")
		print("[panel] after close top_bar=%s icon=%s" % [_era_label(ui), _icon_path(badge)])
	else:
		print("[panel] no ceremony observed")
	print("[panel] celebrated=%s badge=%s top_panel_visible=%s" % [
		str(celebrated), str(badge.get("_model")), str(panel.visible)])
	print("_probe_era_panel: %s" % ("PASS" if celebrated else "FAIL"))
	quit(0 if celebrated else 1)


func _era_label(ui) -> String:
	var top_bar = ui.get("_top_bar")
	if top_bar == null:
		return "<no top bar>"
	var target = top_bar.era_name_target()
	return String(target.text) if target != null else "<none>"


func _icon_path(badge: EraIndicator) -> String:
	var icon: TextureRect = badge.get_node("Badge/Icon")
	if icon == null or icon.texture == null:
		return "<null texture>"
	return icon.texture.resource_path



func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var out := ProjectSettings.globalize_path("res://").path_join("../../tmp/era_advancement_qa").simplify_path()
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out.path_join("probe_%s.png" % label))
	print("[capture] %s" % label)
