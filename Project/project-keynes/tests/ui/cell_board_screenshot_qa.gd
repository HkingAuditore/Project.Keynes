extends SceneTree

## 悬停展板与地名层的截图探针（必须带渲染运行，不能加 --headless）。
##   godot --path . --resolution 1600x900 -s res://tests/ui/cell_board_screenshot_qa.gd
## 产物写到 tmp/ 下的临时目录（已 gitignore），便于人工核对剪纸纸片、图标比例与纸签层级。
const OUTPUT_DIR := "res://tmp/cell_board_qa"
const BOARD_SCENE := "res://scenes/ui/cell_board.tscn"
const VIEWPORTS := [Vector2i(1600, 900), Vector2i(1280, 720)]


class QaEconomy extends RefCounted:
	func market_cell_snapshot(_cell: int) -> Dictionary:
		return {
			"ok": true,
			"good_ids": PackedStringArray([
				"grain", "cloth", "charcoal", "salt", "copper_ore", "tools"]),
			"stock": PackedInt64Array([420000, 180000, 90000, 60000, 12000, 30000]),
			"price": PackedInt32Array([21000, 34000, 62000, 44000, 88000, 240000]),
			"cost_anchor_price": PackedInt32Array([20000, 30000, 50000, 40000, 60000, 120000]),
			"demand_ema": PackedInt64Array([520000, 140000, 70000, 65000, 80000, 25000]),
			"business_demand_ema": PackedInt64Array([0, 60000, 40000, 0, 90000, 50000]),
			"offered_supply_ema": PackedInt64Array([380000, 240000, 40000, 90000, 0, 20000]),
			"good_technology_available": PackedByteArray([1, 1, 1, 1, 1, 1]),
		}

	func population_cell_snapshot(_cell: int, _details: bool = true) -> Dictionary:
		return {
			"ok": true,
			"population": 12000,
			"populations": PackedInt64Array([5200, 3100, 2100, 900, 500, 200]),
			"handles": PackedInt64Array([11, 12, 13, 14, 15, 16]),
			"funds_by_cohort": PackedInt64Array([
				5200000, 9100000, 2400000, 240000000, 900000, 46000000]),
			"epoch_income_by_cohort": PackedInt64Array([
				1900000, 2400000, 800000, 6200000, -180000, 3100000]),
			"owner_employed_by_cohort": PackedInt64Array([0, 0, 0, 4, 0, 12]),
			"overall_satisfaction_by_cohort_q16": PackedInt32Array([
				46000, 58000, 39000, 66000, 18000, 54000]),
			"living_standard_level_by_cohort": PackedInt32Array([3, 4, 2, 6, 0, 5]),
			"profession_ids": PackedInt32Array([0, 1, 2, 3, 4, 5]),
			"profession_stable_ids": PackedStringArray([
				"farmer", "artisan", "worker", "merchant", "unemployed", "landlord"]),
			"profession_display_names": PackedStringArray([
				"农户", "匠户", "工人", "商人", "失业者", "地主"]),
			"ethnicity_ids": PackedInt32Array([0, 0, 0, 0, 0, 0]),
		}

	func cell_mobilization_snapshot(_cell: int) -> Dictionary:
		return {"ok": true, "rows": [
			{"profession": 2, "mobilization_q16": 23593, "stage": 2},
			{"profession": 4, "mobilization_q16": 45875, "stage": 3},
		]}


class QaGenerator extends RefCounted:
	var economy := QaEconomy.new()

	func get_economy_facade():
		return economy

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": 0}


class QaLabelFacade extends RefCounted:
	var revision := 1
	var rows: Array = []

	func named_settlement_snapshot() -> Dictionary:
		var cells := PackedInt32Array()
		var tiers := PackedByteArray()
		var active := PackedByteArray()
		var names := PackedStringArray()
		for row in rows:
			cells.append(int(row[0]))
			tiers.append(int(row[1]))
			active.append(1)
			names.append(String(row[2]))
		return {
			"ok": true, "revision": revision, "full_snapshot": true,
			"cell_indices": cells, "prosperity_tiers": tiers,
			"name_active": active, "settlement_names": names,
		}

	func settlement_delta(_since: int) -> Dictionary:
		return {"ok": true, "revision": revision, "full_snapshot": false}


var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	for viewport in VIEWPORTS:
		await _capture_board(viewport)
		await _capture_labels(viewport)
	if _failures.is_empty():
		print("[cell-board-qa] PASS")
		quit(0)
	else:
		for message in _failures:
			printerr("[cell-board-qa] FAIL: %s" % message)
		quit(1)


func _capture_board(viewport: Vector2i) -> void:
	DisplayServer.window_set_size(viewport)
	await process_frame
	var background := _make_background(viewport)
	root.add_child(background)
	var generator := QaGenerator.new()
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.current_day = 1.0
	var map := MapData.new(2, 1)
	for index in 2:
		var cell := HexCell.new(index, 0)
		cell.index = index
		map.set_cell(cell)
	map._build_indices()
	map.visible_arr = PackedByteArray([1, 1])
	var inspector := CellInspectorViewModel.new()
	inspector.set_context(map, generator, null, clock, 0.42, 22.0)

	var board := (load(BOARD_SCENE) as PackedScene).instantiate() as CellBoard
	root.add_child(board)
	board.configure(map, null,
		func() -> Object: return generator.get_economy_facade(), inspector, clock)
	board.apply_available_height(float(viewport.y) - 120.0)
	board.position = Vector2(112.0, 76.0)
	board.custom_minimum_size = Vector2(CellBoard.BOARD_WIDTH, 0.0)
	if not board.debug_show_cell(0):
		_failures.append("展板截图：debug_show_cell 失败")
	board.modulate.a = 1.0
	await process_frame
	await process_frame
	await _save("%s/board_%dx%d.png" % [OUTPUT_DIR, viewport.x, viewport.y])
	board.free()
	background.free()


func _capture_labels(viewport: Vector2i) -> void:
	DisplayServer.window_set_size(viewport)
	await process_frame
	var background := _make_background(viewport)
	root.add_child(background)
	var map := MapData.new(9, 5)
	for row in 5:
		for column in 9:
			var cell := HexCell.new(column, row)
			cell.index = row * 9 + column
			map.set_cell(cell)
	map._build_indices()
	map.visible_arr = PackedByteArray()
	map.visible_arr.resize(map.cell_count())
	map.visible_arr.fill(1)
	var camera := Camera2D.new()
	root.add_child(camera)
	camera.zoom = Vector2(1.35, 1.35)
	camera.position = Vector2(170.0, 60.0)
	camera.make_current()
	var facade := QaLabelFacade.new()
	facade.rows = [
		[0, 6, "临江市"], [2, 5, "青石关"], [4, 4, "白沙县"],
		[6, 3, "荷叶镇"], [8, 2, "柳河村"], [12, 5, "铁门"], [16, 4, "双井"],
		[20, 3, "南渡"], [24, 2, "杏村"], [28, 5, "北砦"],
	]
	var layer := SettlementLabelLayer.new()
	layer.z_index = 1
	root.add_child(layer)
	layer.configure(map, camera, facade, 22.0,
		HexUtils.wrap_period_x(map.width, 22.0), false)
	layer.set_player_capital_cell(12)
	layer._rebuild_visible_labels()
	layer.set_hover_cell(20)
	layer._update_hover_label()
	await process_frame
	await process_frame
	await _save("%s/labels_%dx%d.png" % [OUTPUT_DIR, viewport.x, viewport.y])
	layer.free()
	camera.free()
	background.free()


func _make_background(viewport: Vector2i) -> TextureRect:
	var image := Image.create(viewport.x, viewport.y, false, Image.FORMAT_RGB8)
	image.fill(Color(0.31, 0.38, 0.29))
	var texture := ImageTexture.create_from_image(image)
	var rect := TextureRect.new()
	rect.texture = texture
	rect.size = Vector2(viewport)
	rect.position = Vector2.ZERO
	rect.z_index = -10
	return rect


func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null:
		_failures.append("截图失败：%s" % path)
		return
	image.save_png(path)
	print("[cell-board-qa] saved ", path)
