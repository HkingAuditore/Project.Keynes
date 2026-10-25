extends SceneTree

const OUTPUT := "res://assets/ui/paper_hud/control_icons"

func _init() -> void:
	if OS.get_cmdline_user_args().has("dump"):
		for type in ["CheckBox", "CheckButton", "OptionButton", "SpinBox", "PopupMenu", "Tree", "HSlider", "VSlider", "HScrollBar", "VScrollBar", "LineEdit", "TextEdit", "TabBar", "Window", "GraphEdit"]:
			print(type, " icons=", ThemeDB.get_default_theme().get_icon_list(type),
				" colors=", ThemeDB.get_default_theme().get_color_list(type))
		quit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var entries := {
		"unchecked": [&"control.checkbox_unchecked", Vector2i(18, 18)],
		"checked": [&"control.checkbox_checked", Vector2i(18, 18)],
		"indeterminate": [&"control.checkbox_indeterminate", Vector2i(18, 18)],
		"radio_unchecked": [&"control.radio_unchecked", Vector2i(18, 18)],
		"radio_checked": [&"control.radio_checked", Vector2i(18, 18)],
		"toggle_off": [&"control.toggle_off", Vector2i(32, 18)],
		"toggle_on": [&"control.toggle_on", Vector2i(32, 18)],
		"scroll_grip": [&"control.scroll_grip", Vector2i(8, 16)],
		"arrow_down": [&"action.chevron_down", Vector2i(12, 12)],
		"arrow_right": [&"action.chevron_right", Vector2i(12, 12)],
		"arrow_left": [&"action.back", Vector2i(12, 12)],
		"close": [&"action.close", Vector2i(14, 14)],
		"visibility": [&"status.hidden", Vector2i(14, 14)],
		"target": [&"system.target", Vector2i(14, 14)],
		"reset": [&"action.refresh", Vector2i(14, 14)],
		"zoom_in": [&"action.add", Vector2i(14, 14)],
		"zoom_out": [&"control.checkbox_indeterminate", Vector2i(14, 14)],
		"grabber": [&"control.radio_checked", Vector2i(14, 14)],
	}
	for key in entries:
		var image := (IconCatalog.texture_for_key(entries[key][0]) as Texture2D).get_image()
		var target: Vector2i = entries[key][1]
		var source := image.get_size()
		var fitted := Vector2(source) * minf(float(target.x) / source.x, float(target.y) / source.y)
		image.convert(Image.FORMAT_RGBA8)
		image.resize(maxi(1, int(fitted.x)), maxi(1, int(fitted.y)), Image.INTERPOLATE_LANCZOS)
		var canvas := Image.create(target.x, target.y, false, Image.FORMAT_RGBA8)
		canvas.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), (target - image.get_size()) / 2)
		canvas.save_png(OUTPUT.path_join(key + ".png"))
	var up := Image.load_from_file(OUTPUT.path_join("arrow_down.png"))
	up.flip_y()
	up.save_png(OUTPUT.path_join("arrow_up.png"))
	var updown := Image.create(12, 24, false, Image.FORMAT_RGBA8)
	updown.blend_rect(up, Rect2i(0, 0, 12, 12), Vector2i.ZERO)
	var down := Image.load_from_file(OUTPUT.path_join("arrow_down.png"))
	updown.blend_rect(down, Rect2i(0, 0, 12, 12), Vector2i(0, 12))
	updown.save_png(OUTPUT.path_join("updown.png"))
	print("[paper-control-icons] 20 engine-control textures baked")
	quit()
