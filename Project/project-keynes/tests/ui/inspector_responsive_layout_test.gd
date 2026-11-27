extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	_check_wide(failures, 1920.0, 1040.0)
	_check_wide(failures, 1366.0, 860.0)
	_check_wide(failures, 1212.0, 860.0)
	_check_compact(failures, 1211.0)
	_check_compact(failures, 1024.0)
	_check_list_wing_layout(failures, 1920.0, 880.0, 420.0)
	_check_list_wing_layout(failures, 1600.0, 800.0, 340.0)
	_check_list_wing_layout(failures, 1366.0, 800.0, 340.0)
	_check_list_wing_layout(failures, 1212.0, 800.0, 340.0)
	_check_list_wing_compact(failures, 1211.0)
	_check_list_wing_compact(failures, 1024.0)
	_check_family_layout(failures, 1920.0, 1360.0, 900.0)
	_check_family_layout(failures, 1600.0, 1248.0, 788.0)
	_check_family_layout(failures, 1366.0, 1080.0, 620.0)
	_check_family_layout(failures, 1312.0, 1080.0, 620.0)
	_check_family_layout(failures, 1311.0, 1080.0, 620.0)
	_check_family_layout(failures, 1280.0, 1080.0, 620.0)
	_check_family_layout(failures, 1024.0, 992.0, 532.0)
	var closed := GameUIManager.inspector_layout_for_width(1024.0, false)
	if bool(closed.get("compact", false)) != true \
			or not is_equal_approx(float(closed.get("panel_width", 0.0)), 460.0):
		failures.append("closed Inspector did not keep its 460px dossier width")
	await _check_scene_geometry(failures)
	await _check_detail_close_width_restore(failures)
	await _check_list_wing_scene(failures)
	await _check_military_row_cost(failures)
	if failures.is_empty():
		print("[inspector-responsive-layout] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[inspector-responsive-layout] FAIL: %s" % failure)
		quit(1)


func _check_wide(failures: PackedStringArray, viewport_width: float,
		expected_width: float) -> void:
	var layout := GameUIManager.inspector_layout_for_width(viewport_width, true)
	if bool(layout.get("compact", true)) \
			or not is_equal_approx(float(layout.get("panel_width", 0.0)), expected_width) \
			or float(layout.get("detail_width", 0.0)) < 400.0 \
			or float(layout.get("detail_width", 9999.0)) > 580.0 \
			or float(layout.get("map_width", 0.0)) < 320.0:
		failures.append("%.0fpx did not produce the expected two-column layout" % viewport_width)


func _check_compact(failures: PackedStringArray, viewport_width: float) -> void:
	var layout := GameUIManager.inspector_layout_for_width(viewport_width, true)
	if not bool(layout.get("compact", false)) \
			or not is_equal_approx(float(layout.get("panel_width", 0.0)),
				viewport_width - UITokens.ARCHIVE_EDGE_INSET * 2.0) \
			or not is_zero_approx(float(layout.get("map_width", -1.0))):
		failures.append("%.0fpx did not produce the full content drawer" % viewport_width)


func _check_family_layout(failures: PackedStringArray, viewport_width: float,
		expected_width: float, expected_detail: float) -> void:
	var layout := GameUIManager.inspector_layout_for_width(
		viewport_width, true, true)
	if bool(layout.get("compact", true)) \
			or not is_equal_approx(float(layout.get("panel_width", 0.0)), expected_width) \
			or not is_equal_approx(float(layout.get("detail_width", 0.0)), expected_detail) \
			or not is_equal_approx(float(layout.get("map_width", -1.0)),
				viewport_width - UITokens.ARCHIVE_EDGE_INSET * 2.0 - expected_width):
		failures.append("%.0fpx family workspace did not preserve both columns: %s" % [
			viewport_width, layout])


func _check_scene_geometry(failures: PackedStringArray) -> void:
	var root := Control.new()
	root.size = Vector2(1920.0, 720.0)
	root.theme = load("res://assets/themes/player_ui_theme.tres") as Theme
	get_root().add_child(root)
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene) \
		.instantiate() as InspectorPanel
	root.add_child(panel)
	panel.visible = true
	panel._detail_shell.visible = true
	panel._inspector_root.visible = true
	panel._sync_split_layout()
	for panel_width in [860.0, 1040.0]:
		panel.custom_minimum_size.x = panel_width
		panel.offset_left = -panel_width
		await process_frame
		var expected_detail: float = float(panel_width) - 460.0
		if not is_equal_approx(panel.size.x, panel_width) \
				or not is_equal_approx(panel._detail_shell.size.x, expected_detail) \
				or not is_equal_approx(panel._inspector_root.size.x, 424.0):
			failures.append("%.0fpx scene columns are not %.0f/424: detail=%s dossier=%s" % [
				panel_width, expected_detail, panel._detail_shell.size,
				panel._inspector_root.size])
		panel._object_detail_dialog.set_embedded(true)
		panel._object_detail_dialog.visible = true
		await process_frame
		var dialog := panel._object_detail_dialog.get_node("Center/Dialog") as Control
		if not dialog.size.is_equal_approx(panel._object_detail_dialog.size) \
				or dialog.size.x < expected_detail - 16.0:
			failures.append("%.0fpx embedded object detail did not fill its workspace: dialog=%s root=%s shell=%s" % [
				panel_width, dialog.size, panel._object_detail_dialog.size,
				panel._detail_shell.size])
		if panel_width == 860.0:
			panel.show_object_detail(_family_detail_payload())
			await process_frame
			await process_frame
			_check_family_split(failures, panel, expected_detail)
			panel.close_detail(false)
			panel.show_family_workspace(CellInspectorViewModel.family_workspace_model(
				_family_detail_payload()), false)
			await process_frame
			if not panel.family_workspace_open() or not panel._inspector_root.visible \
					or absf(panel._detail_shell.size.x - expected_detail) > 1.0:
				failures.append("specialized family workspace did not preserve the dossier column")
			var root_style := panel.get_theme_stylebox(&"panel")
			var shell_style := panel._detail_shell.get_theme_stylebox(&"panel")
			var outer_margin := panel.get_node("Margin") as MarginContainer
			if root_style is StyleBoxEmpty or not shell_style is StyleBoxEmpty \
					or outer_margin.get_theme_constant(&"margin_top") != 12 \
					or outer_margin.get_theme_constant(&"margin_bottom") != 16:
				failures.append("family chrome changed the neighboring dossier material or margins")
			panel.close_detail(false)
			if panel.get_theme_stylebox(&"panel") is StyleBoxEmpty \
					or panel._detail_shell.get_theme_stylebox(&"panel") is StyleBoxEmpty \
					or outer_margin.get_theme_constant(&"margin_top") != 12 \
					or outer_margin.get_theme_constant(&"margin_bottom") != 16:
				failures.append("generic inspector chrome was not restored after family close")
			panel._detail_shell.visible = true
			panel._inspector_root.visible = true
			panel._object_detail_dialog.visible = true
			panel._sync_split_layout()
			await process_frame
	panel._detail_shell.visible = false
	panel._sync_split_layout()
	panel.custom_minimum_size.x = 460.0
	panel.offset_left = -460.0
	await process_frame
	if panel._inspector_root.size_flags_horizontal != Control.SIZE_EXPAND_FILL \
			or panel._inspector_root.size.x < 400.0:
		failures.append("closed dossier did not fill the 460px panel: flags=%d size=%s" % [
			panel._inspector_root.size_flags_horizontal, panel._inspector_root.size])


## 详情打开时右栏会被撑宽，宽度写进 RightPanel.custom_minimum_size；关闭后必须按
## "内容最小宽度"落回 460。这里锁住那个测量口，防止上一轮的宽面板被当成内容最小
## 宽度再写回去（宽度只增不减，正是"关掉二级面板后一级面板变宽且回不来"的成因）。
func _check_detail_close_width_restore(failures: PackedStringArray) -> void:
	var root := Control.new()
	root.size = Vector2(1920.0, 720.0)
	root.theme = load("res://assets/themes/player_ui_theme.tres") as Theme
	get_root().add_child(root)
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene) \
		.instantiate() as InspectorPanel
	root.add_child(panel)
	panel.visible = true
	await process_frame
	# 打开详情那一帧：面板撑到 1040，宽度同时写进 custom_minimum_size。
	panel._detail_shell.visible = true
	panel._inspector_root.visible = true
	panel._sync_split_layout()
	panel.custom_minimum_size.x = 1040.0
	panel.offset_left = -1040.0
	await process_frame
	# 关闭详情：再用布局代码同一个测量口取内容最小宽度，必须回到 460 档。
	panel._detail_shell.visible = false
	panel._sync_split_layout()
	await process_frame
	var content_min := GameUIManager.panel_content_min_width(panel)
	if content_min > 460.5:
		failures.append("closed inspector content minimum is %.0fpx, expected <=460px" % content_min)
	var restored := GameUIManager.resolve_panel_content_width(1920.0, 460.0, content_min)
	if not is_equal_approx(restored, 460.0):
		failures.append("closed inspector width ratcheted to %.0fpx (content_min=%.0f)" % [
			restored, content_min])
	panel.custom_minimum_size.x = restored
	panel.offset_left = -restored
	await process_frame
	if not is_equal_approx(panel.size.x, 460.0):
		failures.append("closed inspector still renders %.0fpx wide" % panel.size.x)
	root.queue_free()
	await process_frame


func _check_family_split(failures: PackedStringArray, panel: InspectorPanel,
		expected_detail: float) -> void:
	var dialog := panel._object_detail_dialog.get_node("Center/Dialog") as Control
	var detail_rect := panel._detail_shell.get_global_rect()
	var dossier_rect := panel._inspector_root.get_global_rect()
	var overlap := detail_rect.intersection(dossier_rect)
	if overlap.size.x > 1.0 and overlap.size.y > 1.0:
		failures.append("family detail occludes the dossier column: overlap=%s detail=%s dossier=%s" % [
			overlap, detail_rect, dossier_rect])
	if absf(panel._detail_shell.size.x - expected_detail) > 1.0 \
			or absf(panel._inspector_root.size.x - 424.0) > 1.0:
		failures.append("family detail changed split widths: detail=%s dossier=%s expected_detail=%.0f" % [
			panel._detail_shell.size, panel._inspector_root.size, expected_detail])
	if dialog.size.x > panel._detail_shell.size.x + 1.0 \
			or dialog.size.y + 1.0 < panel._object_detail_dialog.size.y:
		failures.append("embedded family dialog escaped its shell: dialog=%s root=%s shell=%s" % [
			dialog.size, panel._object_detail_dialog.size, panel._detail_shell.size])
	var body := panel._object_detail_dialog.get_node("Center/Dialog/Body") as Control
	var scroll := panel._object_detail_dialog.get_node("Center/Dialog/Body/Scroll") as ScrollContainer
	if body == null or scroll == null or scroll.size.y < 80.0 \
			or body.size.y + 1.0 < panel._object_detail_dialog.size.y:
		failures.append("family detail did not fill height for scrolling: body=%s scroll=%s root=%s" % [
			body.size if body != null else Vector2.ZERO,
			scroll.size if scroll != null else Vector2.ZERO,
			panel._object_detail_dialog.size])


func _family_detail_payload() -> Dictionary:
	var long_effect := "威望Ⅰ：该家族分支所在的本地块会持续获得以下效果：降雨触发下限降低2%。威望Ⅴ：该家族分支所在的本地块会持续获得以下效果：降雨触发下限降低10%。"
	return {
		"kind": "family",
		"name": "王氏",
		"subtitle": "苍梧郡 · 聚贤 · 家族档案",
		"icon": "family.house",
		"accent": UITokens.ACCENT,
		"row": {
			"population": "128",
			"notable_people": 3,
			"owned_buildings": "12",
			"cash_claim": "3.56万",
			"productive_asset_value": "1.25万",
			"net_worth": "4.81万",
			"founded_day": 12,
			"decline_reviews": 0,
			"prestige_level": 4,
			"prestige_score": "90.0%",
			"trait_rows": [{
				"name": "求雨世家",
				"value": "核心特性",
				"detail": long_effect,
			}],
			"behavior_rows": [{
				"name": "积极的理财",
				"value": "投资偏好 · 32.0%",
			}, {
				"name": "慷慨捐赠",
				"value": "需求偏好 · 18.0%",
			}],
			"effect_rows": [{
				"name": "地块 18 · 求雨",
				"value": long_effect,
				"detail": long_effect,
			}],
			"notable_person_rows": [{
				"name": "王某",
				"value": "产业所有者 · 纺织工坊",
			}],
		},
	}


## 地块档案列在宽屏下恒为 424 px。军事页的建筑行右侧同时有主键（建造/升级/再建）
## 和运行时才显形的拆除键，左下还有成本段；三者挤在一起时最容易出现「文字钻到键
## 底下」或「键被推出容器」。这里直接量绘制的实际占位，而不是只看按钮矩形。
func _check_military_row_cost(failures: PackedStringArray) -> void:
	var row_script: GDScript = load(
		"res://scripts/ui/components/military/military_building_row.gd") as GDScript
	var root := Control.new()
	root.size = Vector2(424.0, 200.0)
	root.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	get_root().add_child(root)
	var row = row_script.new()
	row.size = Vector2(424.0, 46.0)
	root.add_child(row)
	await process_frame
	# 一份最坏情况的模型：长建筑名 + 三项建材 + 可拆除，把宽度同时压满。
	row.set_data({
		"name": "戍边营垒",
		"count": 2,
		"icon": "military.building.barracks",
		"effect": "+50 兵额",
		"materials_text": "木材 30 · 石料 12 等 3 项",
		"cost_days_text": "18 日",
		"cost_cash_text": "1.2 万钱",
		"cost_reason": "",
		"primary_action": "rebuild",
		"action_label": "再建",
		"can_demolish": true,
		"demolish_target": 1,
		"tooltip": "戍边营垒",
	})
	await process_frame
	var room: float = row.text_room()
	if room < 120.0:
		failures.append(
			"military row left only %.0fpx for name/effect/cost at 424px width" % room)
	var primary: Button = row.action_button()
	var demolish: Button = row.demolish_button()
	if primary.position.x + primary.size.x > row.size.x + 1.0:
		failures.append("military primary chip escaped the 424px row")
	if demolish.position.x + demolish.size.x > primary.position.x + 0.5:
		failures.append("military demolish chip is not clear of the primary chip")
	# 拆除键的右边界必须落在文本区之外：文本按 `text_room()` 排版，
	# 两者重叠就说明成本段会被按住的按钮压掉。
	var text_right := 24.0 + 8.0 + room
	if text_right > demolish.position.x + 0.5:
		failures.append(
			"military cost text (%.0fpx) runs under the demolish chip (%.0fpx)" % [
				text_right, demolish.position.x])
	# 悬停前后文本区不能变：变了就说明成本段会随鼠标跳动。
	var room_before := room
	row.mouse_entered.emit()
	await process_frame
	if not is_equal_approx(row.text_room(), room_before):
		failures.append("military row text room shifted on hover: %.0f -> %.0f" % [
			room_before, row.text_room()])
	root.queue_free()
	await process_frame


func _check_list_wing_layout(failures: PackedStringArray, viewport_width: float,
		expected_width: float, expected_wing: float) -> void:
	var layout := GameUIManager.inspector_layout_for_width(
		viewport_width, false, false, true)
	if not bool(layout.get("wing_allowed", false)) \
			or not is_equal_approx(float(layout.get("panel_width", 0.0)), expected_width) \
			or not is_equal_approx(float(layout.get("list_wing_width", 0.0)), expected_wing) \
			or float(layout.get("map_width", 0.0)) < 320.0:
		failures.append("%.0fpx list wing layout mismatch: %s" % [viewport_width, layout])


func _check_list_wing_compact(failures: PackedStringArray, viewport_width: float) -> void:
	var layout := GameUIManager.inspector_layout_for_width(
		viewport_width, false, false, true)
	if bool(layout.get("wing_allowed", true)) \
			or not is_equal_approx(float(layout.get("panel_width", 0.0)), 460.0) \
			or not is_zero_approx(float(layout.get("list_wing_width", -1.0))):
		failures.append("%.0fpx narrow viewport should keep 460px single column: %s" % [
			viewport_width, layout])


func _check_list_wing_scene(failures: PackedStringArray) -> void:
	var root := Control.new()
	root.size = Vector2(1920.0, 720.0)
	root.theme = load("res://assets/themes/player_ui_theme.tres") as Theme
	get_root().add_child(root)
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene) \
		.instantiate() as InspectorPanel
	root.add_child(panel)
	panel.visible = true
	panel.set_compact_detail_mode(false)
	panel.set_list_wing_enabled(true)
	panel.custom_minimum_size.x = 880.0
	panel.offset_left = -880.0
	var model := {
		"cell_index": 7,
		"header": {"kicker": "区域 1, 1", "title": "沃野城", "subtitle": "测试国"},
		"kpis": [],
		"tabs": [
			{"id": "geography", "label": "地理", "icon": "geo"},
			{"id": "population", "label": "人口", "icon": "population.crowd"},
			{"id": "buildings", "label": "建筑", "icon": "building"},
			{"id": "military", "label": "军事", "icon": "country.military"},
		],
		"categories": {
			"geography": {
				"sections": [
					{"id": "physical_geography", "title": "地貌与地表", "metrics": [
						{"id": "m1", "title": "地貌", "value": "平原"}]},
					{"id": "natural_resources", "title": "自然资源", "resource_rows": [
						{"id": "iron", "name": "铁矿", "value": "120", "density": "丰富",
							"delta": "", "extractable": true, "accent": UITokens.RESOURCE,
							"icon": "resource", "visible": true}]},
				],
			},
			"population": {
				"metrics": [{"id": "population_funds", "title": "居民存款", "value": "100"}],
				"cohort_rows": [
					{"id": "cohort_1", "name": "农民", "population": "100 人",
						"wealth": "10", "net": "+1", "living_standard": "温饱",
						"satisfaction": "80.0%", "visible": true},
				],
			},
			"buildings": {
				"metrics": [{"id": "building_total", "title": "建筑总数", "value": "2 栋"}],
				"construction_entry": {"title": "营造新建筑", "available": true},
				"building_rows": [
					{"id": "b_1", "name": "农田", "count": "2", "owner": "业主 · 农民",
						"status": "正常", "profit": "+5", "visible": true},
				],
			},
			"military": {
				"military_cell": {},
			},
		},
	}
	panel.set_model_for_selection(model)
	await process_frame
	if not panel.has_list_wing() or not panel.list_wing_open() \
			or panel._list_content.get_child_count() == 0 \
			or panel._content_box.get_child_count() == 0:
		failures.append("geography tab with resources did not split into ListShell + ContentBox")
	# 点开对象详情应冲掉列表，关闭后恢复列表。
	panel.show_object_detail(_family_detail_payload())
	await process_frame
	if not panel.detail_open() or panel.list_wing_open():
		failures.append("opening object detail did not replace ListShell")
	panel.close_detail(false)
	await process_frame
	if panel.detail_open() or not panel.list_wing_open():
		failures.append("closing object detail did not restore ListShell")
	# 建筑页：building_rows 进左翼，construction_entry 仍留在右栏。
	panel.select_tab("buildings")
	await process_frame
	if not panel.list_wing_open() or panel._list_content.get_child_count() == 0 \
			or panel._content_box.get_child_count() < 2:
		failures.append("buildings tab did not keep construction_entry in right column while moving rows left")
	# 窄屏退化为单栏，切回宽屏恢复双栏。
	panel.set_list_wing_enabled(false)
	await process_frame
	if panel.list_wing_open() or panel._list_content.get_child_count() != 0:
		failures.append("disabling list wing did not collapse ListShell back into ContentBox")
	panel.set_list_wing_enabled(true)
	await process_frame
	if not panel.list_wing_open() or panel._list_content.get_child_count() == 0:
		failures.append("enabling list wing did not restore ListShell")
	# 军事页无左翼内容，保持 460 单栏。
	panel.select_tab("military")
	await process_frame
	if panel.has_list_wing() or panel.list_wing_open():
		failures.append("military tab should not open ListShell")
	root.queue_free()
	await process_frame
