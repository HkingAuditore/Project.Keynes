extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns player persistence; receives only declared capabilities.

func _can_player_provider(context: Dictionary) -> Dictionary:
	var session: Dictionary = context.session
	return _result(not session.is_empty() and session.has("new_game_config"),
		"ok" if not session.is_empty() else "save_provider_missing",
		"" if not session.is_empty() else "玩家会话 provider 不可用。")

func _write_player_provider(context: Dictionary) -> Dictionary:
	var preview := _capture_preview(context)
	var view: Dictionary = context.get("player").capture_view_state() \
		if context.get("player") != null else {
			"selected_cell": -1,
			"camera_position": Vector2.ZERO,
			"camera_zoom": Vector2.ONE,
		}
	return {"ok": true, "sections": {
		"player_context": context.session,
		"player_view": view,
		"preview": preview,
	}}

func _restore_player_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	context.set_session.call(sections.player_context)
	context.set_pending_view.call(sections.player_view.duplicate(true))
	return _result(true, "ok", "")

func _capture_preview(context: Dictionary) -> PackedByteArray:
	var preview := PackedByteArray()
	var viewport: Viewport = context.viewport
	if DisplayServer.get_name() != "headless" and viewport != null \
			and viewport.get_texture() != null:
		var image := viewport.get_texture().get_image()
		if image != null and not image.is_empty():
			preview = image.save_png_to_buffer()
	if preview.is_empty():
		var fallback := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		fallback.fill(Color.TRANSPARENT)
		preview = fallback.save_png_to_buffer()
	return preview


func section_codecs(_id: StringName, sections: PackedStringArray) -> Dictionary:
	var codecs := {}
	for section in sections:
		codecs[section] = "bytes" if section == "preview" else "variant"
	return codecs
