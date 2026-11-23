extends RefCounted

static func _apply_land_layout(host, layout_id: String) -> void:
	var preset := NewGameConfig.land_layout_by_id(layout_id)
	if preset.is_empty():
		return
	host._layout_syncing = true
	if String(preset.get("id", "")) != NewGameConfig.CUSTOM_LAND_LAYOUT:
		(host._advanced_controls.num_continents as SpinBox).value = int(preset.get("num_continents", 2))
		(host._advanced_controls.continent_size as SpinBox).value = float(preset.get("continent_size", 0.50))
		(host._advanced_controls.sea_level as SpinBox).value = float(preset.get("sea_level", 0.50))
		(host._advanced_controls.continent_spacing as SpinBox).value = int(preset.get("continent_spacing", 55))
		(host._advanced_controls.island_amount as SpinBox).value = int(preset.get("island_amount", 50))
	var resolved_id := String(preset.get("id", NewGameConfig.CUSTOM_LAND_LAYOUT))
	var select_index := NewGameConfig.land_layout_index(resolved_id)
	if host._layout_option.selected != select_index:
		host._layout_option.select(select_index)
	host._sync_layout_cards(resolved_id)
	host._layout_syncing = false
	host._refresh_layout_hint()
	host._sync_map_preview(true)


static func _sync_layout_cards(host, active_id: String) -> void:
	for id_key in host._layout_cards:
		var card := host._layout_cards[id_key] as Button
		if card != null:
			card.set_pressed_no_signal(String(id_key) == active_id)
			if card.has_method("_refresh_visual"):
				card.call("_refresh_visual")


static func _matched_land_layout_id(host) -> String:
	for preset in NewGameConfig.LAND_LAYOUT_PRESETS:
		var layout: Dictionary = preset
		if String(layout.get("id", "")) == NewGameConfig.CUSTOM_LAND_LAYOUT:
			continue
		if int((host._advanced_controls.num_continents as SpinBox).value) != int(layout.get("num_continents", 0)):
			continue
		if not is_equal_approx(float((host._advanced_controls.continent_size as SpinBox).value),
				float(layout.get("continent_size", 0.0))):
			continue
		if not is_equal_approx(float((host._advanced_controls.sea_level as SpinBox).value),
				float(layout.get("sea_level", 0.0))):
			continue
		if int((host._advanced_controls.continent_spacing as SpinBox).value) != int(layout.get("continent_spacing", 0)):
			continue
		if int((host._advanced_controls.island_amount as SpinBox).value) != int(layout.get("island_amount", 0)):
			continue
		return String(layout.get("id", NewGameConfig.CUSTOM_LAND_LAYOUT))
	return NewGameConfig.CUSTOM_LAND_LAYOUT


static func _refresh_layout_hint(host) -> void:
	if host._is_pkmap_source():
		host._layout_hint.text = "作者地图已冻结河湖与陆地形状。"
		return
	var layout_id := String(host._layout_option.get_item_metadata(host._layout_option.selected))
	var preset := NewGameConfig.land_layout_by_id(layout_id)
	host._layout_hint.text = String(preset.get("hint", ""))
