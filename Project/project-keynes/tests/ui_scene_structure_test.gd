extends SceneTree

const THEME_PATH := "res://assets/themes/player_ui_theme.tres"
const CONTROL_TYPES := ["Control", "PanelContainer", "VBoxContainer", "HBoxContainer",
	"GridContainer", "MarginContainer", "ScrollContainer", "Label", "Button",
	"TextureRect", "ColorRect", "ProgressBar", "LineEdit", "TextEdit",
	"OptionButton", "CheckBox", "HSlider", "VSlider", "SpinBox",
	"TabContainer", "CenterContainer", "AspectRatioContainer", "RichTextLabel"]
const SCRIPT_EXCLUSIONS := ["debug_console.gd", "info_panel_controller.gd",
	"perf_mini_hud.gd", "perf_recorder.gd", "tile_data_recorder.gd"]

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_theme_contract()
	await _check_main_menu()
	await _check_world_setup()
	await _check_player_game()
	_check_component_scenes()
	_check_no_runtime_control_new()
	print("ui scene structure: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _check_theme_contract() -> void:
	var theme := load(THEME_PATH) as Theme
	_expect("shared player theme loads", theme != null)
	if theme == null:
		return
	for variation in ["PKPanel", "PKInsetPanel", "PKDialog", "PKHUDPanel",
			"PKPrimaryButton", "PKIconButton", "PKTabButton", "PKMetricCard",
			"PKTitle", "PKSectionTitle", "PKMutedLabel"]:
		_expect("theme defines %s" % variation,
			not String(theme.get_type_variation_base(variation)).is_empty())
	for control_type in ["OptionButton", "CheckBox"]:
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			_expect("theme styles %s %s" % [control_type, state],
				theme.has_stylebox(state, control_type))
	for state in ["slider", "grabber_area", "grabber_area_highlight"]:
		_expect("theme styles HSlider %s" % state,
			theme.has_stylebox(state, "HSlider"))
	for state in ["scroll", "scroll_focus", "grabber", "grabber_highlight",
			"grabber_pressed"]:
		_expect("theme styles VScrollBar %s" % state,
			theme.has_stylebox(state, "VScrollBar"))


func _check_main_menu() -> void:
	var scene := (load("res://scenes/main_menu.tscn") as PackedScene).instantiate()
	_expect("main menu inherits shared theme", _uses_shared_theme(scene))
	_expect("main menu has static page stack", scene.has_node("PageMargin/PageStack"))
	for page_name in ["HomePage", "NewGamePage", "LoadGamePage", "SettingsPage"]:
		_expect("main menu has %s" % page_name,
			scene.has_node("PageMargin/PageStack/%s" % page_name))
	root.add_child(scene)
	await process_frame
	_expect("main menu keeps four static pages",
		scene.get_tree().get_nodes_in_group("main_menu_pages").size() == 4)
	scene.queue_free()
	await process_frame


func _check_world_setup() -> void:
	var scene := (load("res://scenes/world_setup.tscn") as PackedScene).instantiate()
	_expect("world setup inherits shared theme", _uses_shared_theme(scene))
	_expect("world setup has static header", scene.has_node("Margin/Root/Header"))
	_expect("world setup has static responsive body",
		scene.has_node("Margin/Root/ResponsiveBody"))
	root.add_child(scene)
	await process_frame
	_expect("world setup creates reusable field rows",
		scene.get_tree().get_nodes_in_group("world_setup_field_rows").size() > 10)
	scene.queue_free()
	await process_frame


func _check_player_game() -> void:
	var scene := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var ui_root := scene.get_node("UI/UIRoot") as Control
	_expect("player UI root inherits shared theme", _uses_shared_theme(ui_root))
	for layer in ["HUDLayer", "PanelLayer", "ModalLayer", "DebugLayer"]:
		_expect("player UI has %s" % layer, ui_root.has_node(layer))
	var fixed_paths := [
		"HUDLayer/PlayerTopBar", "HUDLayer/PerfMiniHUD",
		"HUDLayer/MapOverlayToolbar", "HUDLayer/CountryActionBar",
		"HUDLayer/MapOverlayLegend", "PanelLayer/RightPanel",
		"PanelLayer/CountryPanel", "ModalLayer/DemandDetailDialog",
		"ModalLayer/ObjectDetailDialog", "ModalLayer/WorldLoadingOverlay",
		"ModalLayer/PauseMenu"]
	for path in fixed_paths:
		_expect("player UI has static %s" % path, ui_root.has_node(path))
	_expect("modal layer renders above panel layer",
		ui_root.get_node("ModalLayer").get_index() > ui_root.get_node("PanelLayer").get_index())
	root.add_child(scene)
	await process_frame
	_expect("player UI keeps one fixed UIRoot", scene.get_node("UI").get_child_count() == 1)
	scene.queue_free()
	await process_frame


func _check_component_scenes() -> void:
	var expectations := {
		"res://scenes/ui/inspector_panel.tscn": "Margin/InspectorRoot/ContentShell/ContentMargin/Scroll/ContentBox",
		"res://scenes/ui/country_panel.tscn": "Center/Dialog/Content/SectionHost/EconomyWorkspace",
		"res://scenes/ui/economy_workspace.tscn": "Column/Scroll/Flow",
		"res://scenes/ui/technology_workspace.tscn": "Root/Main/Tree",
		"res://scenes/ui/demand_detail_dialog.tscn": "Center/Dialog/Body/Scroll/RowsGrid",
		"res://scenes/ui/object_detail_dialog.tscn": "Center/Dialog/Body/Scroll/Content",
		"res://scenes/ui/world_loading_overlay.tscn": "Center/Card/Content/Progress",
		"res://scenes/ui/map_overlay_toolbar.tscn": "SecondaryPanel/Margin/Root/ResourceScroll/SecondaryBox",
		"res://scenes/ui/map_overlay_legend.tscn": "Margin/Root/Vector/Wheel",
		"res://scenes/ui/pause_menu.tscn": "Center/Frame/Panel/Rows",
	}
	for scene_path in expectations:
		var packed := load(scene_path) as PackedScene
		var scene := packed.instantiate()
		_expect("%s has complete fixed tree" % scene_path,
			scene.has_node(String(expectations[scene_path])))
		scene.free()


func _check_no_runtime_control_new() -> void:
	var files := PackedStringArray()
	_collect_scripts("res://scripts/ui", files)
	for path in files:
		if SCRIPT_EXCLUSIONS.has(path.get_file()):
			continue
		var source := FileAccess.get_file_as_string(path)
		for type_name in CONTROL_TYPES:
			_expect("%s does not construct %s at runtime" % [path, type_name],
				source.find("%s.new(" % type_name) < 0)


func _collect_scripts(path: String, output: PackedStringArray) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var child := path.path_join(entry)
		if dir.current_is_dir():
			_collect_scripts(child, output)
		elif entry.ends_with(".gd"):
			output.append(child)
		entry = dir.get_next()
	dir.list_dir_end()


func _uses_shared_theme(control: Control) -> bool:
	return control != null and control.theme != null \
		and control.theme.resource_path == THEME_PATH


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)
