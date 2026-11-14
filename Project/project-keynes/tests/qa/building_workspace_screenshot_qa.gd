extends SceneTree

## 营造窗口的视觉验收（需要渲染，不要加 --headless）。
##
##   godot --path Project/project-keynes --resolution 1920x1080 \
##     -s res://tests/qa/building_workspace_screenshot_qa.gd
##
## 三档页宽取自真实右栏：1280×720 独占档约 1236 px、1366×768 分栏档约 578 px、
## 窄档约 424 px。每个宽度各截「可营造 / 不同因由被拒 / 空目录」三态，输出到
## res://tmp/building_workspace_qa/。

const SCENE := "res://scenes/ui/building_workspace.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"
const OUTPUT := "res://tmp/building_workspace_qa"
const PARCHMENT := Color(0.93, 0.87, 0.73, 1.0)
const PAGE_WIDTHS := [424, 604, 1236]
const PAGE_HEIGHT := 720.0
const SETTLE_SECONDS := 0.45

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	for width in PAGE_WIDTHS:
		await _run_width(int(width))
	_finish()


func _run_width(width: int) -> void:
	var backdrop := ColorRect.new()
	backdrop.color = PARCHMENT
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.theme = load(THEME) as Theme
	root.add_child(backdrop)
	await process_frame
	var frame := Control.new()
	frame.custom_minimum_size = Vector2(width, PAGE_HEIGHT)
	frame.size = Vector2(width, PAGE_HEIGHT)
	frame.position = Vector2(40.0, 40.0)
	backdrop.add_child(frame)
	await process_frame
	var page := (load(SCENE) as PackedScene).instantiate() as Control
	frame.add_child(page)
	await process_frame
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	if page.get_node("Margin/Body").get_combined_minimum_size().x > float(width) + 1.0:
		_failures.append("page minimum width exceeds the %d px column" % width)

	page.set_model(_ready_model())
	await _settle()
	_dump(width, page, "ready")
	await _capture("ready_%d" % width)

	page.set_model(_blocked_model())
	await _settle()
	_dump(width, page, "blocked")
	await _capture("blocked_%d" % width)

	page.set_model(_empty_model())
	await _settle()
	await _capture("empty_%d" % width)
	if page.get_node("%Rows").get_child_count() != 0:
		_failures.append("empty model still rendered rows at %d px" % width)
	page.queue_free()
	backdrop.queue_free()
	await process_frame


func _settle() -> void:
	await create_timer(SETTLE_SECONDS).timeout
	await process_frame


func _dump(column: int, page: Control, tag: String) -> void:
	var rows := page.get_node("%Rows") as Control
	var body := page.get_node("Margin/Body") as Control
	var nav := page.get_node("%SectorNav") as Control
	var first_row: Control = rows.get_child(0) as Control if rows.get_child_count() > 0 else null
	print("[building-workspace-qa] %s %d: page=%s body_min=%s nav_min=%s rows_min=%s row_min=%s row_count=%d" % [
		tag, column, str(page.size), str(body.get_combined_minimum_size()),
		str(nav.get_combined_minimum_size()),
		str(rows.get_combined_minimum_size()),
		str(first_row.get_combined_minimum_size()) if first_row != null else "-",
		rows.get_child_count()])


func _capture(label: String) -> void:
	var shot := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUTPUT, label]
	if shot == null or shot.is_empty() or shot.save_png(path) != OK:
		_failures.append("could not capture %s" % label)
		return
	print("[building-workspace-qa] wrote %s" % path)


func _ready_model() -> Dictionary:
	return _model("manufacturing", [
		_row("weaving", "织造工坊", true, 32000, 600, "", "木材 2.4 · 石料 1.2"),
		_row("masonry", "石作工坊", true, 0, 0, "", "石料 3.0"),
		_row("forge", "锻造工坊", false, 12000, 2000, "缺建材", "木材 1.0 · 铁矿 2.0"),
		_row("loom", "提花作坊", false, 0, 0, "地块不符", "木材 1.5"),
		_row("kiln", "砖窑", false, 9600, 900, "市场缺货", "黏土 4.5"),
	], 24, 0)


func _blocked_model() -> Dictionary:
	return _model("extractive", [
		_row("coal_mine", "煤矿", false, 42000, 12000, "自然资源不足", "木材 2.0"),
		_row("iron_mine", "铁矿", false, 48000, 0, "资金不足", "木材 2.2"),
		_row("quarry", "采石场", false, 12000, 3000, "市场缺货", "木材 0.8"),
	], 3, 0)


func _empty_model() -> Dictionary:
	var model := _model("agriculture", [], 0, 0)
	model["available"] = false
	model["message"] = "只能在本国领土内营造。"
	model["sectors"] = []
	model["kpis"] = []
	return model


func _row(building_id: String, display_name: String, eligible: bool, cash: int,
		market_used: int, reason: String, materials: String) -> Dictionary:
	return {
		"building_id": building_id,
		"type_id": 1,
		"name": display_name,
		"icon": "economy.building.workshop",
		"eligible": eligible,
		"blocked": not eligible,
		"reason_code": "ok" if eligible else "construction_materials_insufficient",
		"reason_text": "" if eligible else reason,
		"materials_text": materials,
		"cash_required": cash,
		"cash_text": "%.2f" % (float(cash) / 10000.0),
		"market_used": market_used,
		"tooltip": "%s\n木材 · 需 2.400 / 国库 1.800 / 市购 0.600 · 单价 12\n合计需现金 %.2f\n本地市场 木材 0.200，缺口 2.200\n工期 3 日 · 岗位 业主 1 · 工匠 3\n原料 原木 0.500 /日 → 产出 木板 0.250 /日%s" % [
			display_name, float(cash) / 10000.0,
			"" if eligible else "\n不满足：%s" % reason],
	}


func _model(sector: String, rows: Array, total: int, offset: int) -> Dictionary:
	var sectors := []
	var ids := ["agriculture", "extractive", "manufacturing", "energy", "knowledge"]
	var labels := ["农业", "采掘", "制造", "能源", "知识"]
	var icons := ["economy.building.farm", "economy.building.mine",
		"economy.building.factory", "economy.building.power",
		"economy.building.science"]
	var counts := [18, 12, 64, 4, 9]
	for index in range(ids.size()):
		sectors.append({
			"id": ids[index], "label": labels[index],
			"icon": icons[index], "count": counts[index],
			"question": "%s · %d 项可营造" % [labels[index], counts[index]],
			"selected": ids[index] == sector,
		})
	return {
		"available": true, "message": "", "data_pending": false,
		"cell": 12, "sector": sector, "search": "", "sort": "recommended",
		"offset": offset, "limit": 16,
		"total": total, "sector_total": total,
		"header": {"kicker": "营造目录", "title": "新建建筑",
			"subtitle": "低地 · 平原 · 国库出资，缺料市购"},
		"sectors": sectors,
		"sorts": _sorts("recommended"),
		"items": rows,
		"page_label": "%d–%d / %d" % [offset + 1, offset + maxi(1, rows.size()), total],
		"query": {"sector": sector, "search": "", "sort": "recommended",
			"offset": offset},
	}


func _sorts(selected: String) -> Array:
	return [
		{"id": "recommended", "label": "推荐", "selected": selected == "recommended",
			"tooltip": "可建优先，再按估算毛利/日从高到低"},
		{"id": "cost", "label": "造价", "selected": selected == "cost",
			"tooltip": "可建优先，再按现金支出从低到高"},
		{"id": "newest", "label": "最新", "selected": selected == "newest",
			"tooltip": "可建优先，再按生产成熟度从新到旧"},
	]


func _finish() -> void:
	print("=== building workspace qa: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  [FAIL] %s" % failure)
	quit(0 if _failures.is_empty() else 1)
