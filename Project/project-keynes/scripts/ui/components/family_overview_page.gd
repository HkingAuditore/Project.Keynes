extends RefCounted

## Builds and refreshes the family overview.


static func _build_overview_page(owner: FamilyWorkspace, page: VBoxContainer) -> void:
	var overview: Dictionary = owner._model.get("pages", {}).get("overview", {})
	var top_grid := FamilyWorkspace.FamilyGridScene.instantiate() as GridContainer
	top_grid.name = "OverviewTopGrid"
	top_grid.columns = 2
	top_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_grid.add_theme_constant_override("h_separation", 20)
	top_grid.add_theme_constant_override("v_separation", 14)
	page.add_child(top_grid)

	owner._add_overview_branches_card(top_grid, overview.get("branches", []))
	owner._add_overview_preferences_card(top_grid, overview.get("preferences", []))

	var mid_grid := FamilyWorkspace.FamilyGridScene.instantiate() as GridContainer
	mid_grid.name = "OverviewMidGrid"
	mid_grid.columns = 2
	mid_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_grid.add_theme_constant_override("h_separation", 20)
	mid_grid.add_theme_constant_override("v_separation", 14)
	page.add_child(mid_grid)

	owner._add_overview_list_card(mid_grid, "traits", "家风与家族特性",
		overview.get("traits", []), false)
	owner._add_overview_list_card(mid_grid, "effects", "稀有独特效果",
		overview.get("effects", []), true)

	owner._add_overview_people_card(page, overview.get("people", []))



static func _add_overview_branches_card(owner: FamilyWorkspace, host: Control, branches: Array) -> void:
	var card := owner._new_card()
	card.name = "OverviewBranches"
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.add_child(card)
	var body := owner._card_body(card)
	owner._add_overview_heading(body, "branches", "据点威望")

	var ring_grid := FamilyWorkspace.FamilyGridScene.instantiate() as GridContainer
	ring_grid.name = "OverviewRingGrid"
	ring_grid.columns = 4
	ring_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ring_grid.add_theme_constant_override("h_separation", 4)
	ring_grid.add_theme_constant_override("v_separation", 2)
	body.add_child(ring_grid)
	for i in range(4):
		var ring := DossierRingGauge.new()
		ring.name = "Ring%d" % i
		ring.custom_minimum_size = Vector2(64.0, 86.0)
		ring.pressed.connect(func(_id: int) -> void: owner._select_page("branches", true))
		ring_grid.add_child(ring)
	owner._refresh_overview_rings(ring_grid, branches)

	var meter_list := FamilyWorkspace.MeterListScene.instantiate() as InspectorMeterList
	meter_list.name = "OverviewBranchMeters"
	meter_list.set_meters(owner._build_overview_branch_meters(branches))
	body.add_child(meter_list)

	var meta_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
	meta_label.name = "BranchMetaLabel"
	meta_label.text = owner._overview_branch_meta_text(branches)
	meta_label.theme_type_variation = &"PKDossierCaption"
	meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(meta_label)



static func _refresh_overview_rings(owner: FamilyWorkspace, ring_grid: Control, branches: Array) -> void:
	if ring_grid == null:
		return
	var specs := owner._build_overview_Branch_ring_specs(branches)
	var children := ring_grid.get_children()
	for i in range(children.size()):
		var ring := children[i] as DossierRingGauge
		if ring == null:
			continue
		ring.visible = i < specs.size()
		if i >= specs.size():
			continue
		var spec: Dictionary = specs[i]
		ring.set_gauge(
			i,
			String(spec.label),
			float(spec.ratio),
			String(spec.sub),
			spec.color as Color,
			String(spec.tooltip)
		)



static func _build_overview_Branch_ring_specs(owner: FamilyWorkspace, branches: Array) -> Array:
	var header: Dictionary = owner._model.get("header", {})
	var all_branches: Array = branches if not branches.is_empty() \
		else (owner._model.get("pages", {}).get("branches", []) as Array)
	if not all_branches.is_empty():
		var primary: Dictionary = all_branches[0]
		var score_pct := float(primary.get("prestige_percent",
			float(int(primary.get("prestige_score_q16", 0))) * 100.0 / 65536.0))
		var pop_pct := float(int(primary.get("population_share_q16", 0))) * 100.0 / 65536.0
		if pop_pct <= 0.0 and primary.has("population_share_text"):
			pop_pct = float(String(primary.get("population_share_text", "0")).trim_suffix("%"))
		var cash_pct := float(int(primary.get("cash_share_q16", 0))) * 100.0 / 65536.0
		if cash_pct <= 0.0 and primary.has("cash_share_text"):
			cash_pct = float(String(primary.get("cash_share_text", "0")).trim_suffix("%"))
		var bld_pct := float(int(primary.get("building_share_q16", 0))) * 100.0 / 65536.0
		if bld_pct <= 0.0 and primary.has("building_share_text"):
			bld_pct = float(String(primary.get("building_share_text", "0")).trim_suffix("%"))
		return [
			{"label": "主支威望", "ratio": clampf(score_pct / 100.0, 0.0, 1.0),
				"sub": "威望 %s" % String(primary.get("prestige_label", "0")),
				"color": UITokens.DOSSIER_OXBLOOD,
				"tooltip": "主支威望"},
			{"label": "人口份额", "ratio": clampf(pop_pct / 100.0, 0.0, 1.0),
				"sub": String(primary.get("population_share_text", "%.0f%%" % pop_pct)),
				"color": UITokens.DOSSIER_VERDIGRIS,
				"tooltip": "家族族人在据点总人口中的占比"},
			{"label": "资金份额", "ratio": clampf(cash_pct / 100.0, 0.0, 1.0),
				"sub": String(primary.get("cash_share_text", "%.0f%%" % cash_pct)),
				"color": UITokens.DOSSIER_BRASS,
				"tooltip": "家族现金在据点居民总资金中的占比"},
			{"label": "产业份额", "ratio": clampf(bld_pct / 100.0, 0.0, 1.0),
				"sub": String(primary.get("building_share_text", "%.0f%%" % bld_pct)),
				"color": UITokens.DOSSIER_SLATE,
				"tooltip": "家族控股建筑在据点总产业中的占比"},
		]
	var prestige_pct := float(header.get("prestige_percent", 0.0))
	if prestige_pct <= 0.0:
		prestige_pct = float(String(header.get("prestige_progress_text", "0")).trim_suffix("%"))
	var p_label := String(header.get("prestige_label", "0"))
	return [
		{"label": "家族威望", "ratio": clampf(prestige_pct / 100.0, 0.0, 1.0),
			"sub": "等级 %s" % p_label, "color": UITokens.DOSSIER_OXBLOOD,
			"tooltip": "当前家族威望得分 %.1f%%" % prestige_pct},
	]



static func _build_overview_branch_meters(owner: FamilyWorkspace, branches: Array) -> Array:
	var header: Dictionary = owner._model.get("header", {})
	var all_branches: Array = branches if not branches.is_empty() \
		else (owner._model.get("pages", {}).get("branches", []) as Array)
	if not all_branches.is_empty():
		var primary: Dictionary = all_branches[0]
		var score_pct := float(primary.get("prestige_percent",
			float(int(primary.get("prestige_score_q16", 0))) * 100.0 / 65536.0))
		var sat_known := primary.has("satisfaction_percent")
		var sat_pct := float(primary.get("satisfaction_percent", 0.0)) if sat_known else 0.0
		return [
			{"id": "ov_br_score", "label": "威望总分",
				"value": clampf(score_pct / 100.0, 0.0, 1.0),
				"value_text": String(primary.get("prestige_text", "%.1f%%" % score_pct)),
				"status_label": "目标 %s（%d/%d）" % [
					String(primary.get("target_label", "0")),
					int(primary.get("review_streak", 0)),
					int(primary.get("review_required", 2))],
				"accent": UITokens.WARN},
			# 分支满意度是成员 cohort 的「综合」口径；没有读数时留空并说明，
			# 不要用 85% 之类的常量把它填满（编出来的数会被当成真实民生）。
			{"id": "ov_br_sat", "label": "分支生计",
				"value": clampf(sat_pct / 100.0, 0.0, 1.0),
				"value_text": "%.1f%%" % sat_pct if sat_known else "—",
				"status_label": "族人综合满足" if sat_known else "暂无满意度读数",
				"accent": UITokens.ECO if sat_known else UITokens.TEXT_MUTED},
		]
	var prestige_pct := float(header.get("prestige_percent", 0.0))
	if prestige_pct <= 0.0:
		prestige_pct = float(String(header.get("prestige_progress_text", "0")).trim_suffix("%"))
	return [
		{"id": "ov_fam_prestige", "label": "威望总分",
			"value": clampf(prestige_pct / 100.0, 0.0, 1.0),
			"value_text": String(header.get("prestige_progress_text", "%.1f%%" % prestige_pct)),
			"status_label": "威望 %s" % String(header.get("prestige_label", "0")),
			"accent": UITokens.WARN},
		{"id": "ov_fam_tier_progress", "label": "晋级阈值",
			"value": clampf(prestige_pct / 100.0, 0.0, 1.0),
			"marker": 0.25,
			"value_text": "阶梯评定",
			"accent": UITokens.ECO},
	]



static func _overview_branch_meta_text(owner: FamilyWorkspace, branches: Array) -> String:
	var all_branches: Array = branches if not branches.is_empty() \
		else (owner._model.get("pages", {}).get("branches", []) as Array)
	if all_branches.is_empty():
		var header: Dictionary = owner._model.get("header", {})
		return "当前威望等级 %s（得分 %s）· 提升人口/资金/产业份额可晋级" % [
			String(header.get("prestige_label", "0")),
			String(header.get("prestige_progress_text", "0%"))]
	var primary: Dictionary = all_branches[0]
	var loc := String(primary.get("location_label", "地块 %d" % int(primary.get("cell", -1))))
	return "核心据点：%s · 晋级目标 %s（复核 %d/%d）· 共 %d 处分支" % [
		loc, String(primary.get("target_label", "0")),
		int(primary.get("review_streak", 0)),
		int(primary.get("review_required", 2)), all_branches.size()]



static func _add_overview_preferences_card(owner: FamilyWorkspace, host: Control, items: Array) -> void:
	var card := owner._new_card()
	card.name = "OverviewPreferences"
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.add_child(card)
	var body := owner._card_body(card)
	owner._add_overview_heading(body, "preferences", "显著行为偏好")
	if items.is_empty():
		return
	var bar_list := DossierBarList.new()
	bar_list.name = "OverviewPrefBars"
	bar_list.row_height = 34.0
	bar_list.label_width = 84.0
	bar_list.value_width = 92.0
	bar_list.selectable = true
	bar_list.set_rows(owner._build_preference_bar_rows(items))
	bar_list.row_selected.connect(func(_row_id: Variant) -> void:
		owner._select_page("preferences", true))
	body.add_child(bar_list)



static func _build_preference_bar_rows(owner: FamilyWorkspace, items: Array) -> Array:
	var out: Array = []
	for item_index in range(items.size()):
		var item: Dictionary = items[item_index]
		var factor_pct := float(item.get("factor_percent", 100.0))
		var signed_delta := factor_pct - 100.0
		var delta_str := "%s%.0f%%" % [
			"+" if signed_delta >= 0.0 else "−", absf(signed_delta)]
		var factor_str := String(item.get("factor_text",
			String(item.get("value", "%.1f%%" % factor_pct))))
		var readout := "%s (%s)" % [factor_str, delta_str] \
			if not factor_str.contains("(") else factor_str
		var color := UITokens.DOSSIER_VERDIGRIS if factor_pct >= 105.0 \
			else (UITokens.DOSSIER_OXBLOOD if factor_pct <= 95.0 else UITokens.DOSSIER_BRASS)
		var icon_key := owner._preference_icon_key(item)
		var axis_label := String(item.get("axis_name", "偏好"))
		out.append({
			"id": item.get("id", item_index),
			"label": String(item.get("name", "偏好")),
			"icon": icon_key,
			"value": clampf(factor_pct / 200.0, 0.0, 1.0),
			"marker": 0.5,
			"color": color,
			"text": readout,
			"text_color": color if absf(signed_delta) >= 5.0 else UITokens.DOSSIER_INK,
			"tooltip": "%s · %s偏好\n中线为 100%% 常规基线" % [
				String(item.get("name", "偏好")), axis_label],
		})
	return out



static func _preference_icon_key(owner: FamilyWorkspace, item: Dictionary) -> StringName:
	var existing := String(item.get("icon", ""))
	if not existing.is_empty():
		return StringName(existing)
	var axis := int(item.get("axis", 0))
	var stable_id := String(item.get("stable_id", ""))
	if stable_id.is_empty() and String(item.get("id", "")).contains(":"):
		stable_id = String(item.get("id", "")).get_slice(":", 1)
	return CellInspectorViewModel._family_behavior_icon(
		axis, stable_id, String(item.get("name", "")))



static func _add_overview_list_card(owner: FamilyWorkspace, host: Control, page_id: String, title_text: String,
		items: Array, two_columns: bool = false) -> void:
	var card := owner._new_card()
	card.name = "Overview%s" % page_id.capitalize()
	host.add_child(card)
	var body := owner._card_body(card)
	owner._add_overview_heading(body, page_id, title_text)
	var item_host: Control = body
	if two_columns:
		var grid := FamilyWorkspace.FamilyGridScene.instantiate() as GridContainer
		grid.name = "Overview%sGrid" % page_id.capitalize()
		grid.columns = 1
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 6)
		body.add_child(grid)
		item_host = grid
	for item_index in range(items.size()):
		var item_value: Variant = items[item_index]
		var item: Dictionary = item_value
		owner._add_overview_list_item(item_host, page_id, item, item_index)



static func _add_overview_list_item(owner: FamilyWorkspace, host: Control, page_id: String,
		item: Dictionary, item_index: int) -> void:
	var row := FamilyWorkspace.FamilyHBoxScene.instantiate() as HBoxContainer
	row.name = "Item%d" % item_index
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	host.add_child(row)
	var icon := FamilyWorkspace.FamilyTextureScene.instantiate() as TextureRect
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(20.0, 20.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	icon.texture = IconCatalog.texture_for_key(StringName(FamilyWorkspace.PAGE_META[page_id].icon))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var content := FamilyWorkspace.FamilyVBoxScene.instantiate() as VBoxContainer
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 2)
	row.add_child(content)
	var title_row := FamilyWorkspace.FamilyHBoxScene.instantiate() as HBoxContainer
	title_row.add_theme_constant_override("separation", 6)
	content.add_child(title_row)
	var name_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
	name_label.name = "Name"
	name_label.text = String(item.get("name", item.get("title", "记录")))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.theme_type_variation = &"FamilyStrongLabel"
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.tooltip_text = name_label.text
	title_row.add_child(name_label)
	if page_id == "traits":
		owner._append_trait_badges(title_row, item)
	var value_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
	value_label.name = "Value"
	value_label.text = owner._overview_item_value_text(page_id, item)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.tooltip_text = value_label.text
	value_label.theme_type_variation = &"FamilyMutedLabel"
	value_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	title_row.add_child(value_label)
	if page_id == "traits" or page_id == "effects":
		var detail_text := owner._overview_item_detail_text(page_id, item)
		if not detail_text.is_empty():
			var detail := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
			detail.name = "Detail"
			detail.text = detail_text
			detail.tooltip_text = detail_text
			detail.theme_type_variation = &"FamilyMutedLabel"
			detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			content.add_child(detail)



static func _overview_item_value_text(owner: FamilyWorkspace, page_id: String, item: Dictionary) -> String:
	var val := String(item.get("value", "")).strip_edges()
	if page_id == "effects":
		if val.begins_with("当前未达威望"):
			return "未达威望Ⅰ"
		if val.length() > 14:
			var p_lvl := int(item.get("prestige_level", 0))
			return "威望 %s 生效" % CellInspectorViewModel._prestige_text(p_lvl) \
				if p_lvl > 0 else "生效中"
	return val



static func _overview_item_detail_text(owner: FamilyWorkspace, page_id: String, item: Dictionary) -> String:
	var detail := String(item.get("detail", item.get("effect_summary", ""))).strip_edges()
	if page_id == "effects":
		if detail.is_empty():
			detail = String(item.get("value", "")).strip_edges()
		if detail.begins_with("当前未达威望"):
			var tiers: Array = item.get("tier_statements", [])
			if not tiers.is_empty() and not String(tiers[0]).is_empty():
				return "未达威望Ⅰ · 解锁预览：%s" % String(tiers[0])
			return "当前未达威望Ⅰ · 提升本地威望至Ⅰ级后激活此项地域加成"
	elif page_id == "traits" and detail.is_empty():
		return ""
	return detail



static func _append_trait_badges(owner: FamilyWorkspace, host: HBoxContainer, item: Dictionary) -> void:
	var badges: Array = item.get("badges", [])
	if badges.is_empty():
		badges = FamilyBuffCopy.extract_trait_badges(String(item.get("detail", "")))
	for i in range(mini(2, badges.size())):
		var badge_data: Dictionary = badges[i]
		var pill := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
		pill.text = String(badge_data.get("text", ""))
		pill.theme_type_variation = &"FamilyTraitBadgePos" \
			if bool(badge_data.get("positive", true)) else &"FamilyTraitBadgeNeg"
		host.add_child(pill)
	if badges.size() > 2:
		var more := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
		more.text = "+%d 项" % (badges.size() - 2)
		var all_names := PackedStringArray()
		for badge_value in badges:
			var badge_entry: Dictionary = badge_value
			all_names.append(String(badge_entry.get("text", "")))
		more.tooltip_text = " · ".join(all_names)
		more.theme_type_variation = &"FamilyMutedLabel"
		host.add_child(more)



static func _add_overview_people_card(owner: FamilyWorkspace, host: Control, items: Array) -> void:
	var card := owner._new_card()
	card.name = "OverviewPeople"
	host.add_child(card)
	var body := owner._card_body(card)
	owner._add_overview_heading(body, "people", "主要人物")
	var people_grid := FamilyWorkspace.FamilyGridScene.instantiate() as GridContainer
	people_grid.name = "OverviewPeopleGrid"
	people_grid.columns = owner._overview_people_columns(items.size(), owner.size.x)
	people_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	people_grid.add_theme_constant_override("h_separation", 8)
	people_grid.add_theme_constant_override("v_separation", 6)
	body.add_child(people_grid)
	for item_index in range(items.size()):
		var item_value: Variant = items[item_index]
		var item: Dictionary = item_value
		var strip_card := FamilyWorkspace.FamilyCardScene.instantiate() as PanelContainer
		strip_card.name = "Person%d" % item_index
		strip_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		strip_card.theme_type_variation = &"FamilyTierLocked"
		people_grid.add_child(strip_card)
		var strip_body := owner._card_body(strip_card)
		var row := FamilyWorkspace.FamilyHBoxScene.instantiate() as HBoxContainer
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)
		strip_body.add_child(row)
		var portrait := FamilyWorkspace.FamilyTextureScene.instantiate() as TextureRect
		portrait.name = "Portrait"
		portrait.custom_minimum_size = Vector2(40.0, 46.0)
		portrait.texture = IconCatalog.texture_for_key(&"family.workspace.person")
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(portrait)
		var info_box := FamilyWorkspace.FamilyVBoxScene.instantiate() as VBoxContainer
		info_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_box.alignment = BoxContainer.ALIGNMENT_CENTER
		info_box.add_theme_constant_override("separation", 1)
		row.add_child(info_box)
		var name_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
		name_label.name = "Name"
		name_label.text = String(item.get("name", "未命名人物"))
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.theme_type_variation = &"FamilyStrongLabel"
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info_box.add_child(name_label)
		var role_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
		role_label.name = "Role"
		role_label.text = String(item.get("value", item.get("role", "家族成员")))
		role_label.theme_type_variation = &"FamilyMutedLabel"
		role_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info_box.add_child(role_label)
		var metrics_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
		metrics_label.name = "PersonMetrics"
		metrics_label.text = owner._person_overview_metrics_text(item)
		metrics_label.theme_type_variation = &"FamilyMutedLabel"
		metrics_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
		metrics_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info_box.add_child(metrics_label)



static func _people_ledger_columns(owner: FamilyWorkspace) -> Array:
	return [
		{"id": "name", "label": "姓名", "min_width": 96.0, "expand": true, "kind": "text", "sortable": true},
		{"id": "role", "label": "职务 / 身份", "width": 116.0, "kind": "text", "sortable": true},
		{"id": "building", "label": "执掌产业", "width": 98.0, "kind": "text", "optional": true, "sortable": true},
		{"id": "worth", "label": "个人净资产", "width": 92.0, "kind": "money", "align": "right", "sortable": true},
		{"id": "flow", "label": "周期净收支", "width": 90.0, "kind": "money", "align": "right", "sortable": true},
		{"id": "sat", "label": "生存", "width": 88.0, "kind": "bar", "optional": true, "sortable": true},
	]



static func _people_ledger_rows(owner: FamilyWorkspace, items: Array) -> Array:
	var rows: Array = []
	for index in range(items.size()):
		var person: Dictionary = items[index]
		var role_str := String(person.get("role", ""))
		var prof_str := String(person.get("profession", ""))
		if role_str.is_empty():
			role_str = String(person.get("value", "家族成员"))
		elif not prof_str.is_empty() and not role_str.contains(prof_str):
			role_str = "%s · %s" % [prof_str, role_str]
		var bld := String(person.get("building", "")).strip_edges()
		if bld.is_empty():
			bld = "家族本宅"
		var worth_str := String(person.get("net_worth_text", "—"))
		var worth_val := float(person.get("net_worth_val",
			CellInspectorViewModel._parse_leading_float(worth_str, float(items.size() - index))))
		var flow_str := String(person.get("net_cashflow_text", "稳健"))
		var flow_val := float(person.get("net_cashflow_val",
			CellInspectorViewModel._parse_leading_float(flow_str, 0.0)))
		# 名人只有「生存」读数（成员 cohort 的 survival），没有综合满意度列；
		# 读不到就写「—」，绝不拿常量顶上。
		var sat_known := person.has("satisfaction_percent") \
			and String(person.get("satisfaction_text", "—")) != "—"
		var sat_pct := float(person.get("satisfaction_percent", -1.0))
		var sat_str := String(person.get("satisfaction_text", "—")) if sat_known else "—"
		rows.append({
			"id": person.get("id", "person_%d" % index),
			"tooltip": "%s（%s）\n执掌产业：%s" % [
				String(person.get("name", "成员")), role_str, bld],
			"cells": {
				"name": {"text": String(person.get("name", "未命名人物")),
					"icon": StringName(person.get("profession_icon", "population.profession.owner"))},
				"role": {"text": role_str},
				"building": {"text": bld},
				"worth": {"text": worth_str, "sort": worth_val},
				"flow": {"text": flow_str, "sort": flow_val,
					"color": UITokens.DOSSIER_OXBLOOD if flow_str.begins_with("−") else UITokens.DOSSIER_VERDIGRIS},
				"sat": {"text": sat_str,
					"value": clampf(maxf(sat_pct, 0.0) / 100.0, 0.0, 1.0),
					"sort": sat_pct,
					"color": UITokens.DOSSIER_VERDIGRIS if sat_known else UITokens.TEXT_MUTED},
			},
		})
	return rows



static func _overview_people_columns(owner: FamilyWorkspace, person_count: int, available_width: float) -> int:
	if person_count <= 1 or available_width < 480.0:
		return 1
	if person_count == 2 or available_width < 720.0:
		return 2
	return mini(3, person_count)



static func _person_overview_metrics_text(owner: FamilyWorkspace, person: Dictionary) -> String:
	var parts: Array[String] = []
	var building := String(person.get("building", "")).strip_edges()
	if not building.is_empty():
		parts.append("产业：%s" % building)
	var net_worth := String(person.get("net_worth_text", "")).strip_edges()
	if not net_worth.is_empty():
		parts.append("净资产 %s" % net_worth)
	var flow := String(person.get("net_cashflow_text", "")).strip_edges()
	if not flow.is_empty():
		parts.append("日收支 %s" % flow)
	var sat := String(person.get("satisfaction_text", "")).strip_edges()
	if not sat.is_empty():
		parts.append("生存 %s" % sat)
	if parts.is_empty():
		return "详情：无"
	return " · ".join(parts)



static func _add_overview_heading(owner: FamilyWorkspace, host: VBoxContainer, page_id: String,
		title_text: String) -> void:
	var header_row := FamilyWorkspace.FamilyHBoxScene.instantiate() as HBoxContainer
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.add_child(header_row)
	var kicker := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
	kicker.text = title_text
	kicker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kicker.theme_type_variation = &"PKDossierKicker"
	header_row.add_child(kicker)
	var heading := FamilyWorkspace.FamilyButtonScene.instantiate() as Button
	heading.name = "Heading"
	heading.flat = true
	heading.focus_mode = Control.FOCUS_NONE
	heading.text = "%s ›" % String(FamilyWorkspace.PAGE_META[page_id].title)
	heading.theme_type_variation = &"PKDossierLink"
	heading.pressed.connect(owner._select_page.bind(page_id, true))
	header_row.add_child(heading)
