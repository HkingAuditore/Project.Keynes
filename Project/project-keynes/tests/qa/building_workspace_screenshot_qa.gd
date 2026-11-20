extends SceneTree

## 营造窗口的视觉验收（需要渲染，不要加 --headless）。
##
##   godot --path Project/project-keynes --resolution 1920x1080 \
##     -s res://tests/qa/building_workspace_screenshot_qa.gd
##
## 覆盖窄栏、超宽屏分栏与 720p 独占档。截图输出到 res://tmp/building_workspace_qa/。

const SCENE := "res://scenes/ui/building_workspace.tscn"
const DOSSIER_SCENE := "res://scenes/ui/object_detail_dialog.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"
const OUTPUT := "res://tmp/building_workspace_qa"
const PARCHMENT := Color(0.93, 0.87, 0.73, 1.0)
const PAGE_WIDTHS := [424, 604, 1236]
const VIEWPORTS := [Vector2i(930, 558), Vector2i(1680, 720), Vector2i(1280, 720)]
const SETTLE_SECONDS := 0.45

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for i in PAGE_WIDTHS.size():
		var viewport: Vector2i = VIEWPORTS[i]
		DisplayServer.window_set_size(viewport)
		root.size = viewport
		await _run_width(PAGE_WIDTHS[i], viewport.y - 32)
	_finish()


func _run_width(width: int, height: int) -> void:
	var backdrop := ColorRect.new()
	backdrop.color = PARCHMENT
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.theme = load(THEME) as Theme
	root.add_child(backdrop)
	await process_frame
	var frame := Control.new()
	frame.size = Vector2(width, height)
	frame.position = Vector2(24.0, 16.0)
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

	var first_row := page.get_node("%Rows").get_child(0) as BuildingOptionRow
	first_row.hover_started.emit(first_row._row_data, first_row)
	await _settle()
	if not page.get_global_rect().encloses(page._hover_card.get_global_rect()):
		_failures.append("hover card exceeds the %d px column" % width)
	if first_row._build.get_global_rect().intersects(page._hover_card.get_global_rect()):
		_failures.append("hover card covers its build button in the %d px column" % width)
	if not page._hover_card._outputs.is_visible_in_tree() \
			or not page._hover_card._optional.is_visible_in_tree():
		_failures.append("hunting preview lost output or tool choices in the %d px column" % width)
	await _capture("hover_%d" % width)
	first_row.hover_ended.emit()

	page.set_model(_blocked_model())
	await _settle()
	_dump(width, page, "blocked")
	await _capture("blocked_%d" % width)

	page.set_model(_empty_model())
	await _settle()
	await _capture("empty_%d" % width)
	if page.get_node("%Rows").get_child_count() != 0:
		_failures.append("empty model still rendered rows at %d px" % width)
	page.hide()
	var dossier := (load(DOSSIER_SCENE) as PackedScene).instantiate() as ObjectDetailDialog
	frame.add_child(dossier)
	dossier.set_embedded()
	dossier.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dossier.show_details(_dossier_payload())
	await _settle()
	await _capture("dossier_%d" % width)
	var view: Control = dossier._building_refs.production_rows
	if view.size.x < view.get_combined_minimum_size().x or view.get_child_count() != 2:
		_failures.append("production rows did not fit the %d px column" % width)
	var changed := _dossier_payload()
	changed.row.actual_utilization_float = 0.69
	if not dossier.refresh_details(changed):
		_failures.append("live dossier patch failed in the %d px column" % width)
	await _settle()
	await _capture("dossier_live_%d" % width)
	var gathering := _gathering_payload()
	dossier.show_details(gathering)
	await _settle()
	await _capture("dossier_materials_%d" % width)
	if not dossier._building_refs.construction_card.visible:
		_failures.append("catalog material card missing in the %d px column" % width)
	if width == 424:
		var scroll := dossier.get_node("Center/Dialog/Body/Scroll") as ScrollContainer
		scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
		await _settle()
		await _capture("dossier_materials_scrolled_%d" % width)
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
		_row("hunting", "狩猎营地", true, 252200, 26783, "", "原木 26.783"),
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
	var material_rows: Array = []
	for item in materials.split(" · "):
		var label := item.split(" ")
		material_rows.append({
			"name": label[0], "text": label[1] + " 单位",
			"icon": "good.lumber" if label[0].begins_with("木") else "economy.resource",
			"detail": "国库 " + label[1],
		})
	if market_used > 0:
		material_rows[0]["detail"] = "国库 1.8，需市购 0.6"
	var preview := {}
	if building_id == "hunting":
		material_rows[0]["detail"] = "全部市购"
		material_rows[0]["icon"] = "good.logs"
		preview = {
			"outputs": [
				{"name": "野味", "icon": &"good.game_meat", "text": "1.624 单位/日"},
				{"name": "生皮", "icon": &"good.raw_hide", "text": "0.075 单位/日"},
				{"name": "毛皮", "icon": &"good.fur", "text": "0.045 单位/日"},
			],
			"inputs": [{"name": "野生动物", "icon": &"resource.animal", "text": "0.209 单位/日"}],
			"jobs": [{"name": "猎人（业主）", "icon": &"profession.hunter", "text": "1 人"}],
			"optional": [{"name": "工具", "icon": &"good.tools", "text": "0.1 单位/日", "options": [
				{"name": "打制石器", "icon": &"good.chipped_stone_tools"},
				{"name": "铜工具", "icon": &"good.copper_tools"},
				{"name": "青铜工具", "icon": &"good.bronze_tools"},
			]}],
		}
	if not eligible and reason == "市场缺货":
		material_rows[0].merge({"missing": true, "missing_text": "0.6", "reason": "市场无货"})
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
		"material_status": material_rows,
		"preview": preview,
		"cash_required": cash,
		"cash_text": "%.2f" % (float(cash) / 10000.0),
		"market_used": market_used,
		"days": 3,
		"tooltip": "%s\n合计需现金 %.2f\n岗位：业主 工匠 ×1 · 雇员 工人 ×3\n投入：亚麻 / 棉花 0.5/日、燃料 0.25/日\n产出：布料 0.25/日%s" % [
			display_name, float(cash) / 10000.0,
			"" if eligible else "\n不满足：%s" % reason],
	}


func _dossier_payload() -> Dictionary:
	return {
		"kind": "building", "name": "枯枝采集营地", "icon": "economy.building.gathering",
		"row": {
			"id": "deadwood", "count": "3", "status": "开工 70%", "actual_utilization_float": 0.70,
			"planned_utilization_float": 1.0, "owner": "业主 · 采集者",
			"staffing_actual_raw": 6, "staffing_required_raw": 6, "profit": "+0.0005",
			"job_rows": [{"name": "业主 · 采集者", "value": "6 / 6"}],
			"production_rows": [{
				"id": "natural_input_0", "name": "开采 林木", "icon": "resource.wood",
				"value": "0.799 单位/栋/日", "detail": "当前可采 27.6 单位",
			}, {
				"id": "output_0", "name": "产出 原木", "icon": "good.logs",
				"value": "3.548 单位/栋/日", "detail": "基础产量 3.4 单位/栋/日",
			}],
		},
	}


func _gathering_payload() -> Dictionary:
	var payload := _dossier_payload()
	payload.name = "采集营地"
	var row: Dictionary = payload.row
	row.id = "gathering"
	row.actual_utilization_float = 0.53
	row.planned_utilization_float = 0.59
	row.has_climate_profile = true
	row.climate_capacity_float = 0.53
	row.temperature_fit_float = 0.37
	row.water_fit_float = 0.58
	row.production_rows = [{
		"id": "natural_input_0", "name": "承载 肥沃土壤", "icon": "resource.fertile_soil",
		"value": "需 1.215 单位/栋",
	}, {
		"id": "output_0", "name": "产出 采集植物食物", "icon": "good.gathered_plants",
		"value": "2.95 单位/栋/日", "detail": "基础产量 3.741 单位/栋/日",
	}]
	row.construction_requirements = [{"name": "原木", "icon": "good.logs", "text": "8.686 单位"}]
	return payload


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
