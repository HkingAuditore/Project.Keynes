extends SceneTree

const ControllerScript = preload("res://scripts/game/player_controller.gd")
const DossierScene = preload("res://scenes/ui/military_dossier.tscn")
const ViewModelScript = preload("res://scripts/ui/military_view_model.gd")
const ManagerScript = preload("res://scripts/ui/game_ui_manager.gd")
const InspectorScene = preload("res://scenes/ui/inspector_panel.tscn")
var failures := 0

class FacadeStub extends RefCounted:
	var reachable := true
	var owner := 1
	var previews := 0
	func army(handle: int) -> Dictionary:
		return {"ok": true, "handle": handle, "owner_slot": owner, "cell": 0,
			"headcount": 1240, "mission": 1, "target_cell": 3, "stance": 1,
			"attack_q16": 1245184, "defense_q16": 983040, "speed_q16": 65536,
			"morale_q16": 54000, "supply_ratio_q16": 42000, "pay_ratio_q16": 65536,
			"ration_ratio_q16": 65536, "path": PackedInt32Array([0, 1, 3]),
			"composition": [{"unit": 0, "count": 1240, "quality_q8": 256}],
			"supply_days": PackedInt64Array([12, 8, 6, 0, 15, 20])}
	func preview_path(_army: int, cell: int) -> Dictionary:
		previews += 1
		return {"ok": true, "cells": PackedInt32Array([0, 1, cell]), "days": 3} \
			if reachable else {"ok": false, "reason": "military_path_unreachable"}
	func set_render_selection(_army: int) -> void:
		pass

class LayersStub extends RefCounted:
	var route := PackedInt32Array()
	func show_path_preview(cells: PackedInt32Array, _costs: PackedInt32Array, _days: int) -> void:
		route = cells
	func clear_route() -> void:
		route.clear()

class OrderController extends ControllerScript:
	var facade := FacadeStub.new()
	var layers := LayersStub.new()
	var commands: Array = []
	var accept := true
	func _military_facade():
		return facade
	func _military_layers():
		return layers
	func _military_area_cells(centre: int, radius: int) -> PackedInt32Array:
		return PackedInt32Array([centre, centre + radius])
	func request_command(id: StringName, args: Dictionary = {}) -> Dictionary:
		commands.append({"id": id, "args": args.duplicate(true)})
		return {"ok": accept, "message": "已排队，次日执行。" if accept else "部队暂不可用。"}

class UIHarness extends ManagerScript:
	var vm: MilitaryViewModel
	func _ready() -> void:
		pass
	func _military_view_model() -> MilitaryViewModel:
		return vm

func _init() -> void:
	call_deferred("_run")

func expect(label: String, passed: bool) -> void:
	if not passed:
		failures += 1
		push_error(label)

func _run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	await process_frame
	var controller := OrderController.new()
	controller._player_country_handle = 0x100000001
	root.add_child(controller)
	expect("own army enters targeting", controller.begin_military_arm_order(9, "move").ok)
	controller.military_arm_order_click(3)
	controller.military_arm_order_click(3)
	expect("repeated map taps only preview", controller.commands.is_empty())
	expect("preview is ready and carries ETA", controller.military_arm_order().ready \
		and controller.military_arm_order().days == 3)
	var before := controller.facade.previews
	controller.confirm_military_arm_order()
	expect("confirm rechecks native path", controller.facade.previews == before + 1)
	expect("one move submitted and targeting cleared", controller.commands.size() == 1 \
		and controller.commands[0].args.cell == 3 and controller.military_arm_order().mode == "")
	controller.begin_military_arm_order(9, "move")
	controller.military_arm_order_click(3)
	controller.facade.reachable = false
	controller.confirm_military_arm_order()
	expect("stale unreachable preview cannot submit", controller.commands.size() == 1 \
		and not controller.military_arm_order().ready and controller.military_arm_order().mode == "move")
	controller.facade.reachable = true
	controller.military_arm_order_click(4)
	controller.accept = false
	controller.confirm_military_arm_order()
	expect("rejected command preserves target for retry", controller.military_arm_order().target == 4)
	controller.cancel_military_arm_order()
	expect("cancel clears preview", controller.layers.route.is_empty() \
		and not controller.military_arm_order().ready)
	controller.accept = true
	controller.begin_military_arm_order(9, "area", 1)
	controller.military_arm_order_click(3)
	controller.set_military_arm_order_radius(4)
	expect("radius updates draft", controller.military_arm_order().radius == 4)
	controller.confirm_military_arm_order()
	expect("area command uses previewed radius and cells", controller.commands[-1].id == \
		ControllerScript.COMMAND_MILITARY_AREA_CONTROL and controller.commands[-1].args.radius == 4 \
		and controller.commands[-1].args.cells == PackedInt32Array([3, 7]))
	expect("explore enters targeting with configurable radius",
		controller.begin_military_arm_order(9, "explore", 2).ok)
	controller.military_arm_order_click(5)
	controller.set_military_arm_order_radius(5)
	expect("explore radius updates draft and cells", controller.military_arm_order().radius == 5 \
		and controller.military_arm_order().cell_count == 2)
	controller.confirm_military_arm_order()
	expect("explore command submits chosen radius and cells", controller.commands[-1].id == \
		&"military.army.explore" and controller.commands[-1].args.radius == 5 \
		and controller.commands[-1].args.cells == PackedInt32Array([5, 10]))
	controller.facade.owner = 2
	expect("foreign army cannot target", not controller.begin_military_arm_order(9, "move").ok)
	controller.facade.owner = 1
	var vm := ViewModelScript.new()
	vm.configure({"military": {"available": true, "country_handle": 0x100000001,
		"snapshot": {"country_slot": 1}, "facade": controller.facade,
		"catalog": {"units": [{"id": "line", "class": 0}], "display_names": {"line": "步兵"}}}})
	var host := Control.new()
	host.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	root.add_child(host)
	var dossier = DossierScene.instantiate()
	host.add_child(dossier)
	dossier.set_model(vm.army_dossier(9))
	expect("own commands and stop available", dossier.get_node("%MoveButton").visible \
		and not dossier.get_node("%StopButton").disabled)
	var count := dossier.find_children("*", "", true, false).size()
	dossier.set_order_state({"army": 9, "mode": "move", "ready": true, "days": 3, "target": 3})
	dossier.set_model(vm.army_dossier(9))
	expect("daily patch preserves targeting and nodes", dossier.get_node("%OrderDraft").visible \
		and dossier.find_children("*", "", true, false).size() == count)
	var radius_events: Array = []
	dossier.action_requested.connect(func(action: StringName, payload: Dictionary) -> void:
		if action == &"radius":
			radius_events.append(int(payload.get("radius", 0))))
	dossier.set_order_state({"army": 9, "mode": "explore", "ready": true, "radius": 2,
		"target": 5, "cell_count": 19})
	dossier.get_node("%Radius5").pressed.emit()
	expect("radius button emits chosen exploration radius", radius_events == [5] \
		and dossier.get_node("%Radius5").button_pressed \
		and int(dossier.get_node("%Radius").value) == 5)
	for width in [424, 520, 604]:
		dossier.size = Vector2(width, 560)
		await process_frame
		await process_frame
		var scroll := dossier.get_node("%Scroll") as Control
		var move := dossier.get_node("%MoveButton") as Control
		var confirm := dossier.get_node("%ConfirmOrder") as Control
		expect("fixed commands fit width %d" % width, move.get_global_rect().end.x <= \
			dossier.get_global_rect().end.x + 1 and confirm.get_global_rect().end.y <= \
			scroll.get_global_rect().position.y + 1 and scroll.size.y > 100)
	if "--visual" in OS.get_cmdline_user_args():
		await _screenshots(dossier, vm, controller)
	host.hide()
	await _check_wiring(controller, vm)
	controller.queue_free()
	host.queue_free()
	await process_frame
	print("military arm order: %d failures" % failures)
	quit(0 if failures == 0 else 1)

func _check_wiring(controller, vm) -> void:
	controller.facade.owner = 1
	var ui := UIHarness.new()
	ui.vm = vm
	root.add_child(ui)
	var inspector = InspectorScene.instantiate()
	inspector.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	ui.add_child(inspector)
	ui._right_panel = inspector
	ui._player_controller = controller
	controller._ui_manager = ui
	inspector.detail_visibility_changed.connect(ui._on_inspector_detail_visibility_changed)
	inspector.military_dossier_action_requested.connect(ui._on_military_dossier_action_requested)
	ui.open_military_dossier("army", 9, 0)
	ui._layout_right_panel()
	await process_frame
	await process_frame
	await create_timer(0.3).timeout
	expect("army page leaves map space", inspector.size.x >= 500 and inspector.size.x <= 521)
	expect("enter animation keeps right edge inside viewport", inspector.get_global_rect().end.x <= \
		root.get_visible_rect().end.x - UITokens.ARCHIVE_EDGE_INSET + 1)
	var view = inspector._military_dossier
	view.get_node("%MoveButton").pressed.emit()
	expect("begin targeting retains dossier", inspector.military_dossier_open() \
		and view.get_node("%OrderDraft").visible)
	ui.open_military_dossier("army", 9, 0)
	expect("reselecting same army preserves draft", inspector.military_dossier_open() \
		and controller.military_arm_order().mode == "move")
	controller.military_arm_order_click(3)
	expect("ready draft focuses confirm", view.get_node("%ConfirmOrder").has_focus())
	expect("focused confirm keeps dark ink", (view.get_node("%ConfirmOrder") as Button).get_theme_color(
		"font_focus_color").get_luminance() < 0.4)
	await process_frame
	await process_frame
	expect("embedded paper stays inside compact army panel", view.get_global_rect().end.x <= \
		inspector.get_global_rect().end.x + 1 and view.size.x >= 400)
	if "--visual" in OS.get_cmdline_user_args():
		await create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tmp/military_order_qa/embedded_move.png")
	var command_count: int = controller.commands.size()
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	Input.parse_input_event(enter)
	await process_frame
	enter.pressed = false
	Input.parse_input_event(enter)
	await process_frame
	expect("keyboard confirm submits exactly once", controller.commands.size() == command_count + 1 \
		and controller.military_arm_order().mode == "")
	view.get_node("%MoveButton").pressed.emit()
	view.get_node("%CancelOrder").pressed.emit()
	expect("cancel retains dossier", inspector.military_dossier_open() \
		and controller.military_arm_order().mode == "")
	view.get_node("%AreaButton").pressed.emit()
	controller.military_arm_order_click(3)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	inspector._unhandled_key_input(escape)
	expect("first escape only cancels draft", inspector.military_dossier_open() \
		and controller.military_arm_order().mode == "")
	view.get_node("%MoveButton").pressed.emit()
	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	controller._dispatch_player_input(right_click)
	expect("right click cancels without closing dossier", inspector.military_dossier_open() \
		and controller.military_arm_order().mode == "")
	inspector._unhandled_key_input(escape)
	expect("second escape closes dossier and restores tile directory", not inspector.detail_open() \
		and inspector._directory_available)
	controller._ui_manager = null
	ui.queue_free()
	await process_frame

func _screenshots(dossier, vm, controller) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tmp/military_order_qa"))
	for viewport_size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(viewport_size)
		root.content_scale_size = Vector2i.ZERO
		root.size = viewport_size
		dossier.size = Vector2(520, viewport_size.y - 110)
		dossier.position = Vector2(viewport_size.x - 536, 90)
		for mode in ["", "move", "area", "foreign"]:
			controller.facade.owner = 2 if mode == "foreign" else 1
			dossier.set_model(vm.army_dossier(9))
			dossier.set_order_state({"army": 9, "mode": mode if mode != "foreign" else "",
				"ready": true, "target": 3, "days": 3, "radius": 2, "cell_count": 19,
				"message": "路线已标出；可改选目标，或确认行军。"})
			await create_timer(0.5).timeout
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://tmp/military_order_qa/%dx%d_%s.png" % [
				viewport_size.x, viewport_size.y, "idle" if mode.is_empty() else mode])
