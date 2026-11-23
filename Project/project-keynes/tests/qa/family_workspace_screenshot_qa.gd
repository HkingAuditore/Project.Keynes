extends SceneTree

const OUTPUT_DIR := "res://tmp/family_workspace_qa"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var failures := PackedStringArray()
	for viewport_size in [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1920, 1080)]:
		await _capture_inspector_integration(failures, viewport_size)
	if failures.is_empty():
		print("[family-workspace-screenshot] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _capture_inspector_integration(failures: PackedStringArray,
		viewport_size: Vector2i) -> void:
	var viewport := SubViewport.new()
	viewport.size = viewport_size
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	get_root().add_child(viewport)
	var host := Control.new()
	host.size = Vector2(viewport.size)
	host.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	viewport.add_child(host)
	var map_placeholder := ColorRect.new()
	map_placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	map_placeholder.color = Color("#9eb0b2")
	host.add_child(map_placeholder)
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene) \
		.instantiate() as InspectorPanel
	host.add_child(panel)
	panel.visible = true
	var layout := GameUIManager.inspector_layout_for_width(viewport_size.x, true, true)
	var panel_width := float(layout.panel_width)
	panel.custom_minimum_size.x = panel_width
	panel.offset_left = -panel_width - UITokens.ARCHIVE_EDGE_INSET
	panel.offset_top = 68.0
	panel.offset_right = -UITokens.ARCHIVE_EDGE_INSET
	panel.offset_bottom = -12.0
	var rows: Array = []
	for i in 12:
		rows.append({"id": "family_%d" % (17 + i), "name": "白桥堡曾氏" if i == 0 else "长河郡王氏%d" % i,
			"population": "128", "owned_buildings": "12", "cash_claim": "3.56万", "prestige": "IV"})
	panel.set_model_for_selection({"cell_index": 4,
		"header": {"kicker": "地方档案", "title": "白桥堡", "subtitle": "本国城市 · 平原 · 地块 4"},
		"kpis": [{"id": "population", "title": "人口", "value": 128, "text": "128"},
			{"id": "wealth", "title": "资金", "value": 35600, "text": "3.56万"},
			{"id": "buildings", "title": "建筑", "value": 12, "text": "12"},
			{"id": "satisfaction", "title": "满足度", "value": 0.89, "text": "89%"}],
		"tabs": [{"id": "geography", "label": "地理"}, {"id": "families", "label": "家族"}],
		"categories": {"families": {"family_rows": rows}}})
	panel.select_tab("families")
	panel.show_family_workspace(_model(), false)
	panel._family_list.set_selected("family_17")
	await process_frame
	await process_frame
	await process_frame
	var left := panel._detail_shell.get_global_rect()
	var right := panel._inspector_root.get_global_rect()
	if not panel._inspector_root.visible or left.end.x > right.position.x or \
			absf(right.size.x - 424.0) > 1.0:
		failures.append("integrated family columns overlap or hide the directory at %s" % viewport_size)
	var workspace := panel._family_workspace
	for page_id in ["overview", "preferences", "people"]:
		workspace.select_page(page_id, false)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var scroll := workspace.get_node("%PageScroll") as ScrollContainer
		for card in workspace.find_children("*", "PanelContainer", true, false):
			if card.is_visible_in_tree() and card.theme_type_variation == &"FamilyCard":
				var rect: Rect2 = card.get_global_rect()
				if rect.position.x < scroll.global_position.x - 1.0 or \
						rect.end.x > scroll.get_global_rect().end.x + 1.0:
					failures.append("family card escaped its viewport at %s/%s" % [viewport_size, page_id])
		var image := viewport.get_texture().get_image()
		var path := "%s/family_inspector_%dx%d_%s.png" % [
			OUTPUT_DIR, viewport_size.x, viewport_size.y, page_id]
		if image == null or image.is_empty() or image.save_png(path) != OK:
			failures.append("failed to capture inspector-integrated family workspace")
		else:
			print("[family-workspace-screenshot] %s" % ProjectSettings.globalize_path(path))
	viewport.queue_free()
	await process_frame


func _model() -> Dictionary:
	return {
		"kind": "family_workspace",
		"header": {"name": "白桥堡曾氏", "subtitle": "家族 · 区域 30, 30 · 新征家", "prestige_label": "IV", "prestige_progress_text": "89.0%", "prestige_percent": 89.0},
		"summary": [
			{"label": "本家族人口", "value": "5.15万", "caption": "分支 2 处 · 名人 3 人", "icon": "family.metric.population"},
			{"label": "净资产", "value": "51.5万", "caption": "现金 32.0万 · 产业 19.5万", "icon": "family.metric.wealth"},
			{"label": "产业数", "value": "24", "caption": "名下控股建筑规模", "icon": "family.metric.buildings"},
			{"label": "创立时间", "value": "第0日", "caption": "威望 IV · 得分 89.0%", "icon": "family.metric.time"},
		],
		"pages": {
			"overview": {
				"traits": [
					{"id": "steady", "name": "稳固", "value": "核心特性", "detail": "家族成员忠诚度提高 20%，产业经营韧性增强。"},
					{"id": "keeper", "name": "精明治家", "value": "核心特性", "detail": "家族成员主动改变职业的可能性增加 30%。"},
				],
				"preferences": [
					{"id": "0:farm", "name": "农庄投资", "axis": 0, "axis_name": "投资", "value": "172.0%", "factor_percent": 172.0},
					{"id": "1:merchant", "name": "商人从业", "axis": 1, "axis_name": "职业", "value": "158.0%", "factor_percent": 158.0},
					{"id": "2:food", "name": "温饱消费", "axis": 2, "axis_name": "需求", "value": "127.5%", "factor_percent": 127.5},
					{"id": "3:tea", "name": "精制茗茶", "axis": 3, "axis_name": "商品消费", "value": "68.0%", "factor_percent": 68.0},
				],
				"effects": [
					{"id": "effect:4:harvest", "name": "地块 4 · 丰收", "value": "威望 IV 生效", "detail": "本地粮食与农牧产出 +20.0%"},
					{"id": "effect:4:trade", "name": "地块 4 · 商路通达", "value": "威望 IV 生效", "detail": "本地商队贸易周转效率 +25.0%"},
					{"id": "effect:9:frontier", "name": "地块 9 · 拓荒家风", "value": "威望 II 生效", "detail": "新开拓领土建设速度 +20.0%"},
				],
				"branches": [
					{"id": "branch:4", "cell": 4, "location_label": "白桥堡（地块 4）", "prestige_label": "IV", "prestige_percent": 89.0, "prestige_text": "89.0%", "population_share_q16": 42598, "population_share_text": "65.0%", "cash_share_q16": 47185, "cash_share_text": "72.0%", "building_share_q16": 52428, "building_share_text": "80.0%", "target_label": "V", "review_streak": 1},
				],
				"people": [
					{"id": "person:1", "name": "曾雷金德", "value": "地主 · 产业所有者", "building": "白桥庄园", "net_worth_text": "28.4万", "net_cashflow_text": "+1,240", "satisfaction_text": "92.0%"},
					{"id": "person:2", "name": "曾沃米", "value": "商人 · 产业所有者", "building": "河港商栈", "net_worth_text": "15.2万", "net_cashflow_text": "+680", "satisfaction_text": "88.5%"},
					{"id": "person:3", "name": "曾贝里克", "value": "工匠 · 产业雇员", "building": "白桥铁坊", "net_worth_text": "7.9万", "net_cashflow_text": "+210", "satisfaction_text": "84.0%"},
				],
			},
			"traits": [],
			"preferences": [
				{"id": "2:food", "name": "温饱饮食", "axis": 2,
					"axis_name": "需求", "factor_percent": 127.5,
					"factor_text": "127.5%"},
				{"id": "0:farm", "name": "农庄", "axis": 0,
					"axis_name": "投资", "factor_percent": 140.0,
					"factor_text": "140.0%"},
				{"id": "1:merchant", "name": "商人", "axis": 1,
					"axis_name": "职业", "factor_percent": 158.0,
					"factor_text": "158.0%"},
				{"id": "3:tea", "name": "茗茶", "axis": 3,
					"axis_name": "商品消费", "factor_percent": 68.0,
					"factor_text": "68.0%"},
			],
			"effects": [],
			"people": [
				{"id": "person:1", "name": "曾雷金德", "role": "产业所有者", "profession": "地主", "building": "白桥庄园", "net_worth_text": "28.4万", "cash_claim_text": "16.0万", "equity_share_text": "55.0%", "attributed_asset_text": "12.4万", "net_cashflow_text": "+1,240", "satisfaction_text": "92.0%", "income_val": 1820.0, "expense_val": 580.0, "income_text": "1,820", "expense_text": "580"},
				{"id": "person:2", "name": "曾沃米", "role": "产业所有者", "profession": "商人", "building": "河港商栈", "net_worth_text": "15.2万", "cash_claim_text": "9.8万", "equity_share_text": "30.0%", "attributed_asset_text": "5.4万", "net_cashflow_text": "+680", "satisfaction_text": "88.5%", "income_val": 1120.0, "expense_val": 440.0, "income_text": "1,120", "expense_text": "440"},
				{"id": "person:3", "name": "曾贝里克", "role": "产业雇员", "profession": "工匠", "building": "白桥铁坊", "net_worth_text": "7.9万", "cash_claim_text": "6.2万", "equity_share_text": "15.0%", "attributed_asset_text": "1.7万", "net_cashflow_text": "+210", "satisfaction_text": "84.0%", "income_val": 520.0, "expense_val": 310.0, "income_text": "520", "expense_text": "310"},
			],
			"branches": [],
		},
		"actions": {"family_handle": 17},
	}
