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
	await _check_embedded_object_detail_row_values()
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
	_expect("main menu has map source option", scene.has_node("%MapSourceOption"))
	_expect("main menu has pkmap browse button", scene.has_node("%BrowsePkmapButton"))
	_expect("main menu has pkmap dialog", scene.has_node("%PkmapDialog"))
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
		"PanelLayer/CountryPanel",
		"PanelLayer/RightPanel/Margin/Split/DetailShell/ObjectDetail",
		"PanelLayer/RightPanel/Margin/Split/DetailShell/FamilyWorkspace",
		"PanelLayer/RightPanel/Margin/Split/DetailShell/ConstructionPane",
		"ModalLayer/WorldLoadingOverlay",
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
		"res://scenes/ui/inspector_panel.tscn": "Margin/Split/InspectorRoot/ContentShell/ContentMargin/Scroll/ContentBox",
		"res://scenes/ui/country_panel.tscn": "Center/Dialog/Content/SectionHost/EconomyWorkspace",
		"res://scenes/ui/economy_workspace.tscn": "Column/Scroll/Flow",
		"res://scenes/ui/technology_workspace.tscn": "Root/Main/DetailHost/Body/Detail",
		"res://scenes/ui/technology_overview_view.tscn": "",
		"res://scenes/ui/object_detail_dialog.tscn": "Center/Dialog/Body/Scroll/Content",
		"res://scenes/ui/family_workspace.tscn": "SafeMargin/Main/PageArea/PageViewport/PageScroll/PageHost",
		"res://scenes/ui/world_loading_overlay.tscn": "Center/Card/Content/Progress",
		"res://scenes/ui/map_overlay_toolbar.tscn": "SecondaryPanel/Margin/Root/ResourceScroll/SecondaryBox",
		"res://scenes/ui/map_overlay_legend.tscn": "Margin/Root/Vector/Wheel",
		"res://scenes/ui/pause_menu.tscn": "Center/Frame/Panel/Rows",
	}
	for scene_path in expectations:
		var packed := load(scene_path) as PackedScene
		var scene := packed.instantiate()
		var required_path := String(expectations[scene_path])
		_expect("%s has complete fixed tree" % scene_path,
			required_path.is_empty() or scene.has_node(required_path))
		if scene_path.ends_with("economy_workspace.tscn"):
			_expect("economy workspace has tax sub-tabs", scene.has_node("Column/TaxTabs"))
			_expect("economy workspace has treasury insights", scene.has_node("Column/Insights"))
		scene.free()


func _check_embedded_object_detail_row_values() -> void:
	var cases := [
		{
			"kind": "cohort",
			"name": "商人",
			"needles": PackedStringArray(["32 人", "61.8%", "+0.12/人"]),
			"row": {
				"population": "32 人",
				"cohort_identity": "本地人口",
				"wealth": "1.2",
				"satisfaction": "61.8%",
				"living_standard": "温饱",
				"worst_dimension": "税负",
				"income": "+0.12",
				"expense": "−0.08",
				"net": "+0.04",
				"satisfaction_rows": [
					{"name": "温饱", "value": "61.8%", "visible": true},
				],
				"income_rows": [
					{"name": "居民销售", "value": "+0.12/人", "visible": true},
				],
				"expense_rows": [
					{"name": "生活消费", "value": "−0.08/人", "visible": true},
				],
				"demand_rows": [
					{"name": "野味", "value": "0.123 单位/人/日", "visible": true},
				],
			},
		},
		{
			"kind": "building",
			"name": "采集营地",
			"needles": PackedStringArray(["2 栋", "+0.40"]),
			"row": {
				"count": "2 栋",
				"status": "运转",
				"profit": "+0.40",
				"job_rows": [
					{"name": "业主岗位", "value": "2 / 2", "visible": true},
				],
			},
		},
		{
			"kind": "family",
			"name": "长安李氏",
			"needles": PackedStringArray(["12 人", "3.50"]),
			"row": {
				"population": "12 人",
				"notable_people": 1,
				"owned_buildings": "1",
				"cash_claim": "3.50",
				"productive_asset_value": "1.00",
				"net_worth": "4.50",
				"founded_day": 1,
				"decline_reviews": 0,
				"prestige_level": 1,
				"prestige_score": "4.2%",
			},
		},
		{
			"kind": "good",
			"name": "原木",
			"needles": PackedStringArray(["120 单位", "0.80"]),
			"row": {
				"stock_plain": "120 单位",
				"price": "0.80",
				"delta": "+2",
			},
		},
		{
			"kind": "resource",
			"name": "木材",
			"needles": PackedStringArray(["0.42", "可开采"]),
			"row": {
				"value": "0.42",
				"density": "中",
				"delta": "+0.01",
				"extractable": true,
			},
		},
	]
	for case_value in cases:
		var case: Dictionary = case_value
		var host := Control.new()
		host.clip_contents = true
		host.custom_minimum_size = Vector2(320, 720)
		host.size = Vector2(320, 720)
		root.add_child(host)
		var dialog := (load("res://scenes/ui/object_detail_dialog.tscn") as PackedScene).instantiate() as ObjectDetailDialog
		host.add_child(dialog)
		dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		dialog.set_embedded(true)
		dialog.show_details({
			"kind": String(case.kind),
			"name": String(case.name),
			"icon": "resource",
			"row": case.row,
		})
		await process_frame
		await process_frame
		await process_frame
		var host_rect := host.get_global_rect()
		var needles: PackedStringArray = case.needles
		for needle in needles:
			var label := _find_value_label(dialog, needle)
			_expect("%s detail shows %s" % [String(case.kind), needle], label != null)
			if label == null:
				continue
			_expect("%s value %s has layout size" % [String(case.kind), needle],
				label.size.x >= 8.0 and label.size.y >= 8.0)
			_expect("%s value %s stays inside the embedded column" % [
				String(case.kind), needle],
				host_rect.grow(1.0).encloses(label.get_global_rect()))
		host.queue_free()
		await process_frame


func _find_value_label(node: Node, needle: String) -> Label:
	if node is Label and String(node.name) == "Value" \
			and (node as Label).visible \
			and String((node as Label).text).find(needle) >= 0:
		return node as Label
	for child in node.get_children():
		var found := _find_value_label(child, needle)
		if found != null:
			return found
	return null


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
