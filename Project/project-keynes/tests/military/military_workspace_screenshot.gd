extends SceneTree

## Military workspace screenshot harness. Needs rendering (run without --headless):
##   godot --path Project/project-keynes -s res://tests/military/military_workspace_screenshot.gd -- [prefix]
## Captures every chapter twice from a fixed fixture: the workspace alone on a 1280x720
## page, then mounted in the real CountryPanel shell exactly as the game opens it.
## When the last user argument is "mobile" the run also repeats both passes at the
## phone landscape logical size (1942x873) in compact mode.

const OUTPUT_DIR := "D:/Godot/ProjectKeynes/Project.Keynes/tmp/military_ui"
const SCENE := "res://scenes/ui/military_workspace.tscn"
const PANEL_SCENE := "res://scenes/ui/country_panel.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"
const PARCHMENT := Color("e4d9bf")
const MONEY := 10000
const Q16 := 65536
const MOBILE := Vector2i(1942, 873)
const CHAPTER_IDS := ["overview", "forces", "armies", "war"]

var _failures := PackedStringArray()
var _session


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var prefix := "before"
	var sizes: Array = [Vector2i(1280, 720), Vector2i(1600, 900)]
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text == "mobile":
			sizes = [MOBILE]
			continue
		prefix = text
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	_session = FixtureSession.new()
	for index in range(sizes.size()):
		var size: Vector2i = sizes[index]
		var suffix := "" if size == sizes[0] else ("_compact" if index == 1 else "_mobile")
		await _run_size(prefix, size, suffix, index == 0)
	_finish()


func _run_size(prefix: String, size: Vector2i, suffix: String, references: bool) -> void:
	DisplayServer.window_set_size(size)
	root.size = size
	await _settle_viewport()
	var backdrop := ColorRect.new()
	backdrop.color = PARCHMENT
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.theme = load(THEME) as Theme
	root.add_child(backdrop)
	await process_frame
	# Pass 1: the workspace alone on a full page.
	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		frame.add_theme_constant_override("margin_" + side, 24)
	backdrop.add_child(frame)
	var workspace := (load(SCENE) as PackedScene).instantiate() as Control
	frame.add_child(workspace)
	await process_frame
	workspace.call("set_model", session_model(_session))
	workspace.call("set_compact", suffix == "_compact")
	for chapter_id in CHAPTER_IDS:
		workspace.call("select_chapter", String(chapter_id))
		await _capture("%s_%s%s" % [prefix, chapter_id, suffix])
	await _check_page(workspace, "%s page" % suffix)
	_check_names(workspace)
	_check_handoffs(workspace)
	frame.queue_free()
	# Pass 2: mounted in the real CountryPanel dossier shell, as in game.
	var panel := (load(PANEL_SCENE) as PackedScene).instantiate() as Control
	backdrop.add_child(panel)
	await process_frame
	var model := session_model(_session)
	model["country_name"] = "qingchuan"
	panel.call("show_section", "military", model)
	await process_frame
	var shell_workspace := panel.get("_military_workspace") as Control
	for chapter_id in CHAPTER_IDS:
		shell_workspace.call("select_chapter", String(chapter_id))
		await _capture("%s_%s_shell%s" % [prefix, chapter_id, suffix])
	await _check_page(shell_workspace, "%s shell" % suffix)
	_check_names(shell_workspace)
	_check_chapters(shell_workspace)
	_check_handoffs(shell_workspace)
	if references:
		for section_id in ["technology", "ideology"]:
			panel.call("show_section", section_id, model)
			await _capture("ref_%s_shell" % section_id)
	backdrop.queue_free()
	await process_frame


## M2: no chapter tab may collapse to its icon, and the KPI band must keep the
## value line and the caption line apart.
func _check_chapters(workspace: Control) -> void:
	var nav := workspace.get_node_or_null("%ChapterNav") as Control
	if nav == null:
		_failures.append("chapter nav missing")
		return
	if bool(nav.get("icon_only")):
		_failures.append("chapter tabs fell back to icon-only at %s" % nav.size)
	var labels: Array = []
	for chapter in nav.get("chapters"):
		labels.append(String(chapter.label))
	if labels.size() != CHAPTER_IDS.size():
		_failures.append("chapter nav exposes %d tabs" % labels.size())


## M1: every KPI card is laid out at its own width (an HBox child never gets
## another control's rect), and the caption baseline sits clear of the value.
func _check_page(workspace: Control, tag: String) -> void:
	if not bool(workspace.call("view_model").call("available")):
		_failures.append("%s: view model unavailable" % tag)
		return
	_check_kpis(workspace, tag)
	_check_frames(workspace, tag)
	_check_roster(workspace, tag)
	_check_tables(workspace, tag)


## 兵营与训练队列必须真的列出数据：名册改版前这两张表在真实对局里只画表头，
## 玩家看不到任何一个兵营。
func _check_tables(workspace: Control, tag: String) -> void:
	var vm = workspace.call("view_model")
	var forces: Dictionary = vm.call("forces_model")
	var expectations := {
		"%BarracksTable": (forces.get("barracks", []) as Array).size(),
		"%TrainingTable": (forces.get("training", []) as Array).size(),
	}
	for path in expectations:
		var table := workspace.get_node_or_null(path)
		if table == null:
			_failures.append("%s: %s missing" % [tag, path])
			continue
		var drawn := int(table.call("row_count"))
		if drawn != int(expectations[path]):
			_failures.append("%s: %s draws %d of %d rows" % [tag, path, drawn,
				int(expectations[path])])


## DossierKpiCard draws its value baseline at y=57 and its caption at y=h-8, so a
## card shorter than HEIGHT puts both strings on the same baseline. This used to
## be "fixed" by forcing 66 px; the band now keeps the card's own height.
func _check_kpis(workspace: Control, tag: String) -> void:
	var row := workspace.get_node_or_null("%KpiRow") as Control
	var strip := workspace.get_node_or_null("%KpiStrip") as Control
	if row == null or strip == null:
		_failures.append("%s: KPI strip missing" % tag)
		return
	var widths := PackedFloat32Array()
	for card in row.get_children():
		var control := card as Control
		widths.append(control.size.x)
		if control.size.x < 96.0:
			_failures.append("%s: KPI '%s' squeezed to %.0f px" % [tag,
				str(card.get("title")), control.size.x])
		if bool(card.get("dense")):
			continue
		if control.size.y + 0.5 < DossierKpiCard.HEIGHT:
			_failures.append("%s: KPI '%s' is %.0f px tall (< %.0f): value and caption "
				% [tag, str(card.get("title")), control.size.y, DossierKpiCard.HEIGHT]
				+ "share one baseline")
		var caption := String(card.get("caption"))
		if caption.is_empty():
			continue
		# 数值基线固定在 y=57，说明基线在 h-8：两者挨到 20px 以内就已经是同一行。
		var baseline_gap := (control.size.y - 8.0) - 57.0
		if baseline_gap < 20.0:
			_failures.append("%s: KPI '%s' puts its caption %.1f px below the value "
				% [tag, str(card.get("title")), baseline_gap]
				+ "baseline (needs >= 20)")
	if widths.size() < 2:
		_failures.append("%s: KPI band has %d cards" % [tag, widths.size()])
		return
	for i in range(1, widths.size()):
		if absf(widths[i] - widths[0]) > 1.0:
			_failures.append("%s: KPI widths differ (%s)" % [tag, str(widths)])
			break


## The nine-sliced paper edge is drawn at 48 * frame_scale px, so content below
## that band is invisible. Every frame panel's content must clear it (this is the
## bug that cut off the army order row and the peace submit button).
func _check_frames(workspace: Control, tag: String) -> void:
	var frames: Array = []
	_collect_frames(workspace, frames)
	for node in frames:
		var panel := node as Control
		if not panel.is_visible_in_tree() or panel.size.x < 8.0 or panel.size.y < 8.0:
			continue
		var border := float(panel.get("frame_scale")) * 48.0
		var inner := panel.get_global_rect().grow(-border + 1.0)
		for child in panel.find_children("*", "Control", true, false):
			var control := child as Control
			if control == null or not control.is_visible_in_tree():
				continue
			var rect := control.get_global_rect()
			if rect.size.x < 2.0 or rect.size.y < 2.0:
				continue
			if rect.end.y > inner.end.y + 1.0 or rect.end.x > inner.end.x + 1.0:
				_failures.append("%s: '%s' is drawn under the paper frame of '%s'" % [
					tag, control.name, panel.name])
				break


func _collect_frames(node: Node, out: Array) -> void:
	if node is MilitaryFramePanel:
		out.append(node)
	for child in node.get_children():
		_collect_frames(child, out)


## M2: the roster offers exactly the units the country can field (plus any locked
## unit that still holds a share), never shows a unit id as a name, and lays its
## cards out at their minimum width without overlapping.
func _check_roster(workspace: Control, tag: String) -> void:
	var roster := workspace.get_node_or_null("%UnitRoster") as Control
	if roster == null:
		_failures.append("%s: unit roster missing" % tag)
		return
	var vm = workspace.call("view_model")
	var rows: Array = vm.call("unit_share_rows", vm.call("shares_by_unit"))
	if int(roster.call("row_count")) != rows.size():
		_failures.append("%s: roster shows %d rows for %d visible units" % [
			tag, int(roster.call("row_count")), rows.size()])
	for row in rows:
		if not bool(row.get("unlocked", true)) and int(row.get("bp", 0)) <= 0:
			_failures.append("%s: locked unit '%s' reached the roster" % [
				tag, String(row.get("id", ""))])
		if String(row.get("name", "")) == String(row.get("id", "")):
			_failures.append("%s: roster row still prints the unit id '%s'" % [
				tag, String(row.get("id", ""))])
	var rects: Array = roster.call("card_rects")
	for index in range(rects.size()):
		var rect: Rect2 = rects[index]
		if rect.size.x + 0.5 < 292.0:
			_failures.append("%s: roster card %d is %.0f px wide" % [tag, index, rect.size.x])
			break
		for other in range(index + 1, rects.size()):
			if rect.intersects(rects[other]):
				_failures.append("%s: roster cards %d and %d overlap" % [tag, index, other])
				break
	if int(vm.call("locked_unit_count")) <= 0:
		_failures.append("%s: fixture should leave units locked to prove the gate" % tag)
	# 民兵是兵种，必须在名册里有一行；图鉴不再存在。
	var ids: Array = []
	for row in rows:
		ids.append(String((row as Dictionary).get("id", "")))
	if not ids.has("militia"):
		_failures.append("%s: roster is missing the militia row (%s)" % [tag, str(ids)])
	if workspace.has_node("%CodexGrid") or ResourceLoader.exists(
			"res://scripts/ui/components/military/military_codex_grid.gd"):
		_failures.append("%s: the unit codex must not exist any more" % tag)
	if workspace.get_node_or_null("%ArmyDetail") != null:
		_failures.append("%s: army details belong to the dossier, not this panel" % tag)
	if workspace.get_node_or_null("%PeaceEditor") != null:
		_failures.append("%s: peace terms belong to the peace window" % tag)


## 面板只做索引：点部队行要请求打开军务档案，点战线要请求战线档案，
## 战争卡的「议和」要请求打开议和面板。三条都在这里钉住。
func _check_handoffs(workspace: Control) -> void:
	var requests: Array = []
	workspace.connect("dossier_requested", func(kind: String, id: int, cell: int) -> void:
		requests.append({"kind": kind, "id": id, "cell": cell}))
	workspace.connect("peace_negotiation_requested", func(war_id: int) -> void:
		requests.append({"kind": "peace", "id": war_id, "cell": -1}))
	var vm = workspace.call("view_model")
	var armies: Array = vm.call("armies")
	if armies.is_empty():
		_failures.append("handoff check: fixture has no armies")
		return
	var army_handle := int((armies[0] as Dictionary).get("handle", 0))
	workspace.call("_open_army_dossier", army_handle)
	if not _has_request(requests, "army", army_handle):
		_failures.append("handoff check: army row did not request its dossier (%s)" % [requests])
	var fronts: Array = vm.call("front_rows")
	if fronts.is_empty():
		_failures.append("handoff check: fixture has no fronts")
	else:
		var front := fronts[0] as Dictionary
		workspace.call("_on_front_selected", front.get("id"))
		if not _has_request(requests, "front", int(front.get("cell", -2))):
			_failures.append("handoff check: front row did not request its dossier (%s)"
				% [requests])
	var war_card := workspace.get_node_or_null("%WarCard0")
	if war_card == null:
		_failures.append("handoff check: war card missing")
	else:
		war_card.emit_signal("action_requested", 7)
		if not _has_request(requests, "peace", 7):
			_failures.append("handoff check: 议和 button did not request the peace panel (%s)"
				% [requests])


static func _has_request(requests: Array, kind: String, id: int) -> bool:
	for request_value in requests:
		var request: Dictionary = request_value
		if String(request.get("kind", "")) == kind and int(request.get("id", 0)) == id:
			return true
	return false


## 窗口尺寸是异步生效的（stretch 下逻辑视口还要按缩放换算）。不等到稳定就开始
## 排版，第一遍会沿用上一遍的逻辑尺寸 —— 曾经因此让「1280×720 桌面壳」截出上一档的
## 书脊布局，也把 CountryPanel 的 compact 断点判歪。
func _settle_viewport() -> void:
	var last := Vector2.ZERO
	for _i in range(40):
		await process_frame
		var now := root.get_visible_rect().size
		if now == last and now.x > 1.0:
			return
		last = now


func _capture(label: String) -> void:
	for _i in range(4):
		await process_frame
	await create_timer(UITokens.ANIM_MED + 0.25).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUTPUT_DIR, label]
	if image == null or image.is_empty() or image.save_png(path) != OK:
		_failures.append("failed to capture %s" % path)
		return
	print("[military-screenshot] %s" % path)


func _finish() -> void:
	for failure in _failures:
		push_error(failure)
	print("=== military workspace screenshot: %d failures ===" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


## The panel must take region and country names from the live session, and must
## not paper over a missing source with a placeholder that looks like a name.
func _check_names(workspace: Control) -> void:
	var vm = workspace.call("view_model")
	var zone := String(vm.call("zone_name", 1460))
	if not zone.contains("QINGYANG"):
		_failures.append("zone name 1460 = '%s' (expected the session's region name)" % zone)
	var enemy := String(vm.call("country_name", 3))
	if enemy != "CHIYUAN":
		_failures.append("country name slot 3 = '%s'" % enemy)
	workspace.call("set_selected_army", 0)
	var targets: Array = vm.call("declare_candidates")
	if targets.size() != 1 or int(targets[0].handle) != 0x300000001:
		_failures.append("declare candidates = %s" % [targets])
	if not targets.is_empty() and String(targets[0].name) != "CHIYUAN":
		_failures.append("declare candidate name = '%s'" % String(targets[0].name))
	var rows: Array = vm.call("war_log")
	if rows.size() < 2:
		_failures.append("battle log rows = %d" % rows.size())
	var fronts: Array = vm.call("front_rows")
	if fronts.is_empty():
		_failures.append("front rows empty")
	var ceded: Dictionary = vm.call("ceded_cells", vm.call("war_cards")[0])
	if int(ceded.get("total", 0)) != 3:
		_failures.append("occupied enemy cells = %d (expected 3)" % int(ceded.get("total", 0)))


static func fixture_model() -> Dictionary:
	var day := 412
	var units := [
		_unit(0, "militia", 0, true, 0, 0.6, 0.7, 1.0, 0, [], ""),
		_unit(1, "bronze_spearmen", 0, false, 0, 1.0, 1.3, 1.0, 20, [[0, 1, 100], [3, 1, 60]],
			"tech.bronze_casting"),
		_unit(2, "legionaries", 0, false, 1, 1.2, 0.8, 1.0, 25, [[1, 1, 100]],
			"tech.military.standing_army"),
		_unit(3, "riflemen", 0, false, 3, 1.5, 1.2, 1.0, 30, [[0, 2, 100], [3, 2, 100]],
			"tech.military.rifled_weapons"),
		_unit(4, "cavalry", 1, false, 1, 1.4, 0.9, 1.8, 40, [[0, 1, 100], [4, 1, 100]],
			"tech.military.mounted_warfare"),
		_unit(5, "heavy_cavalry", 1, false, 2, 2.2, 1.6, 1.5, 60,
			[[0, 3, 100], [3, 3, 100], [4, 2, 100]], "tech.military.heavy_cavalry"),
		_unit(6, "field_artillery", 2, false, 2, 2.0, 0.5, 0.6, 45, [[2, 1, 40]],
			"tech.military.field_artillery"),
		_unit(7, "musketeers", 0, false, 4, 2.4, 1.5, 1.0, 35, [[5, 2, 100], [6, 1, 80]],
			"tech.gunpowder_weapons"),
	]
	# Chinese display copy is what the roster must show; a resolver that falls back
	# to the unit id would print `bronze_spearmen` and fail _check_roster().
	var names := {
		"militia": "民兵", "bronze_spearmen": "青铜矛兵", "legionaries": "军团步兵",
		"riflemen": "步枪兵", "cavalry": "骑兵", "heavy_cavalry": "重装骑兵",
		"field_artillery": "野战炮兵", "musketeers": "火枪兵",
	}
	var unit_tech := {
		"militia": "", "bronze_spearmen": "tech.bronze_casting",
		"legionaries": "tech.military.standing_army",
		"riflemen": "tech.military.rifled_weapons",
		"cavalry": "tech.military.mounted_warfare",
		"heavy_cavalry": "tech.military.heavy_cavalry",
		"field_artillery": "tech.military.field_artillery",
		"musketeers": "tech.gunpowder_weapons",
	}
	var categories := [
		_category(0, "melee", [0, 1, 2, 3], [1, 2, 3, 4]),
		_category(1, "bows", [4, 5], [1, 3]),
		_category(2, "siege", [6], [2]),
		_category(3, "armor", [7, 8, 9], [1, 2, 4]),
		_category(4, "mounts", [10, 11], [1, 3]),
		_category(5, "firearms", [12, 13], [2, 4]),
		_category(6, "ammunition", [14], [1]),
	]
	var category_names := {"melee": "兵器", "bows": "弓箭",
		"siege": "火炮", "armor": "护具", "mounts": "坐骑", "firearms": "火器",
		"ammunition": "弹药"}
	var good_ids := PackedStringArray(["stone_spears", "bronze_weapons", "iron_weapons",
		"steel_blades", "bows", "bows", "siege_engines", "hide_armor", "iron_armor",
		"plate_armor", "horses", "war_chariots", "matchlocks", "flintlocks", "powder_shot"])
	var shares := PackedInt32Array([0, 2500, 1500, 1200, 800, 0, 500, 0])
	var snapshot := {
		"ok": true, "country_slot": 0,
		"soldiers_total": 18640, "soldiers_militia": 6120, "soldiers_trained": 12520,
		"soldiers_garrisoned": 9340, "soldiers_in_armies": 9300, "soldiers_training": 1450,
		"has_policy": true, "target_mode": 0, "target_value": 22000, "effective_target": 22000,
		"levy_enabled": true, "auto_retrain": true, "auto_discharge": false,
		"quality_policy": 0, "wage_mode": 0, "wage_absolute": 0,
		"daily_wage": int(0.42 * MONEY), "soldier_living_cost": int(0.35 * MONEY),
		"procurement_share_bp": 2000, "pay_ratio_30_q16": int(0.82 * Q16),
		"spend_payroll_30": 30 * 4200 * MONEY, "spend_procurement_30": 30 * 2650 * MONEY,
		"spend_upkeep_30": 30 * 880 * MONEY, "per_soldier_cost": int(0.42 * MONEY),
		"config_share_bp": shares, "post_count": 12000,
		"barracks": [
			_barracks(1204, 5000, 4310, 0, 380, 120, false, false),
			_barracks(1388, 4000, 3120, 600, 260, 80, false, false),
			_barracks(977, 2000, 1910, 0, 0, 0, true, false),
			_barracks(1502, 1000, 0, 0, 0, 0, false, true),
		],
		"training": [
			_training(91, 1204, 0, 3, 600, 30, 22, true, 512),
			_training(92, 1388, 0, 4, 400, 40, 9, true, 256),
			_training(93, 1204, 1, 6, 250, 45, 0, false, 256),
			_training(94, 977, 0, 2, 200, 25, 3, false, 256),
		],
		"wars": [{"war_id": 7, "attacker_slot": 0, "defender_slot": 3, "start_day": 351,
			"score_q16": int(0.27 * Q16), "attacker_losses": 2140, "defender_losses": 3980,
			"fully_occupied": false,
			"score_parts": {"battle": 14.0, "occupation": 9.0, "annihilation": 6.0,
				"attrition": -2.0}}],
		"wars_active": 1,
		"convoys": [
			{"id": 501, "good": 14, "qty": 4000, "current_cell": 1210, "dest_cell": 1460,
				"eta_day": day + 3, "risk_q16": int(0.31 * Q16)},
			{"id": 502, "good": 7, "qty": 1200, "current_cell": 1388, "dest_cell": 1452,
				"eta_day": day + 5, "risk_q16": int(0.12 * Q16)},
			{"id": 503, "good": 0, "qty": 900, "current_cell": 1204, "dest_cell": 1388,
				"eta_day": day + 2, "risk_q16": int(0.02 * Q16)},
		],
		"negotiation": {"war_id": 7, "available_points": 27.0},
		"control": {"cells": PackedInt32Array([1466, 1467, 1453]),
			"controller_slots": PackedInt32Array([0, 0, 0])},
		"engagements": [
			{"cell_a": 1460, "cell_b": 1466, "attacker_slot": 0, "defender_slot": 3,
				"progress_q16": int(0.62 * Q16), "start_day": 388, "battle": true,
				"zone_a": "QINGYANG", "zone_b": "QINGYANG"},
			{"cell_a": 1452, "cell_b": 1453, "attacker_slot": 3, "defender_slot": 0,
				"progress_q16": int(0.34 * Q16), "start_day": 403, "battle": false},
		],
		"front_edge_keys": PackedInt32Array([1460 * 6, 1460 * 6 + 1, 1452 * 6 + 3]),
		"front_edge_progress": PackedByteArray([255, 200, 255]),
	}
	var armies := [
		_army(0x100000001, 1460, 4200, 1.9, 1.6, 1.0, 0.71, 0.84, 1, 2, 1466, 16,
			[[3, 1800, 512], [4, 1200, 256], [1, 1200, 256]], [6, 4, 9, 0, 12, 20]),
		_army(0x100000002, 1452, 3100, 1.4, 1.5, 0.9, 0.38, 0.55, 2, 1, -1, 1 | 8,
			[[1, 2100, 256], [2, 1000, 256]], [2, 1, 3, 0, 5, 14]),
		_army(0x100000003, 1204, 2000, 1.1, 1.3, 1.0, 0.92, 0.95, 0, 0, -1, 0,
			[[0, 1500, 256], [6, 500, 256]], [28, 30, 25, 0, 30, 40]),
	]
	return {
		"country_handle": 0x100000000,
		"current_day": day,
		"population": 214000,
		"good_ids": good_ids,
		"cell_names": {1204: "N1204", 1388: "N1388", 977: "N977",
			1502: "N1502", 1460: "N1460", 1452: "N1452", 1466: "N1466",
			1210: "N1210"},
		"country_names": {3: "CHIYUAN"},
		"army_names": {0x100000001: "A1", 0x100000002: "A2",
			0x100000003: "A3"},
		"military": {
			"available": true,
			"facade": null,
			"country_handle": 0x100000000,
			"country_handles": {3: 0x300000001},
			"region_names": {1460: "QINGYANG", 1452: "LUOYAN",
				1466: "QINGYANG"},
			"cell_owners": {"owners": PackedInt32Array([
				0, 0, 0, 3, 3, 3,
				0, 0, 0, 3, 3, 3,
				0, 0, 0, 3, 3, 3,
				0, 0, 0, 3, 3, 3])},
			"snapshot": snapshot,
			"armies": armies,
			"catalog": {"ok": true, "units": units, "categories": categories,
				"display_names": names, "category_names": category_names,
				"unit_tech": unit_tech,
				"descriptions": {
					"bronze_spearmen": "青铜兵器与皮甲让步兵第一次拥有稳定的攻防配比。",
					"legionaries": "军需体系支撑的重装步兵，攻防俱佳。",
					"cavalry": "马匹与铁兵器结合的机动部队。",
					"heavy_cavalry": "人马俱甲的冲击骑兵，机动力略降而攻防大幅提高。",
					"field_artillery": "马拉火炮随军机动，无视 50% 工事。",
					"musketeers": "火绳枪让密集射击成为可能。",
					"riflemen": "线膛步枪让散兵成为主力。",
				}},
			# 已研究四项军事科技：名册应只剩 4 张卡，未解锁的 3 种进图鉴。
			"researched_tech_ids": PackedStringArray([
				"tech.bronze_casting", "tech.military.standing_army",
				"tech.military.mounted_warfare", "tech.military.field_artillery"]),
			"tech_gate_known": true,
		},
	}


static func _unit(index: int, id: String, unit_class: int, militia: bool, era: int,
		attack: float, defense: float, speed: float, days: int, slots: Array,
		tech: String = "") -> Dictionary:
	var equipment: Array = []
	for slot in slots:
		equipment.append({"category": slot[0], "min_quality": slot[1],
			"qty_per_100": int(slot[2]) * 1000, "weight_q16": Q16 / 2})
	return {"index": index, "id": id, "class": unit_class, "militia": militia, "era": era,
		"attack_q16": int(attack * Q16), "defense_q16": int(defense * Q16),
		"speed_q16": int(speed * Q16), "fortification_ignore_q16": 0,
		"training_days": days, "equipment": equipment,
		"unlock_bit": -1 if tech.is_empty() else index}


static func _category(index: int, id: String, goods: Array, qualities: Array) -> Dictionary:
	return {"index": index, "id": id, "goods": PackedInt32Array(goods),
		"qualities": PackedInt32Array(qualities)}


static func _barracks(cell: int, posts: int, present: int, foreign: int, quota: int,
		pending: int, paused: bool, disrepair: bool) -> Dictionary:
	return {"cell": cell, "post_count": posts, "present": present, "foreign": foreign,
		"open": maxi(0, posts - present - pending), "quota": quota, "pending_enlist": pending,
		"paused": paused, "disrepair": disrepair, "fort_tier": 1, "college_tier": -1}


static func _training(id: int, cell: int, from_unit: int, to_unit: int, count: int,
		total: int, done: int, ready: bool, quality_q8: int) -> Dictionary:
	return {"id": id, "cell": cell, "from_unit": from_unit, "to_unit": to_unit,
		"count": count, "days_total": total, "days_done": done, "equipment_ready": ready,
		"quality_q8": quality_q8}


static func _army(handle: int, cell: int, heads: int, attack: float, defense: float,
		speed: float, morale: float, organization: float, stance: int, mission: int,
		target: int, flags: int, lots: Array, supply: Array) -> Dictionary:
	var composition: Array = []
	for lot in lots:
		composition.append({"unit": lot[0], "count": lot[1], "quality_q8": lot[2],
			"condition_q16": Q16})
	return {"handle": handle, "owner_slot": 0, "cell": cell, "headcount": heads,
		"attack_q16": int(attack * Q16), "defense_q16": int(defense * Q16),
		"speed_q16": int(speed * Q16), "morale_q16": int(morale * Q16),
		"organization_q16": int(organization * Q16),
		"supply_ratio_q16": int(clampf(float(supply[0]) / 10.0, 0.0, 1.0) * Q16),
		"ration_ratio_q16": int(clampf(float(supply[0]) / 6.0, 0.0, 1.0) * Q16),
		"pay_ratio_q16": int(0.82 * Q16), "engagement": 3 if flags & 16 else -1, "stance": stance, "mission": mission,
		"target_cell": target, "flags": flags, "reinforce_enabled": true,
		"composition": composition, "supply_days": PackedInt64Array(supply), "convoys": []}


## Hard dependency of the fixture mount: the UI reports every missing name, so the
## harness fails loudly instead of depending on the fixture's own name tables.
static func session_model(session) -> Dictionary:
	var model := fixture_model()
	model["generator"] = session.generator()
	model["player_controller"] = session.controller()
	model["military"]["player_controller"] = session.controller()
	return model


## Stand-in for MapGenerator + PlayerController on the paths the military panel
## reads: region names, the Country territory map, neighbour indices and the
## military event ring. Every other method is genuinely absent, so a wrong call
## fails instead of silently succeeding.
class FixtureSession:
	const OWNERS := [
		0, 0, 0, 0, 3, 3, 3, 3,
		0, 0, 0, 0, 3, 3, 3, 3,
		0, 0, 0, 0, 3, 3, 3, 3,
		0, 0, 0, 0, 3, 3, 3, 3,
	]

	func generator() -> Object:
		return FakeGenerator.new()

	func controller() -> Object:
		return FakeController.new()


class FakeMap:
	## 4 rows x N columns, odd-r offsets, east-west wrap (the production layout).
	func neighbor_indices_packed() -> PackedInt32Array:
		var total := FixtureSession.OWNERS.size()
		var rows := 4
		var width := total / rows
		var out := PackedInt32Array()
		out.resize(total * 6)
		for cell in range(total):
			var row := cell / width
			var column := cell % width
			var odd := 1 if (row & 1) == 1 else 0
			var offsets := [Vector2i(1, 0), Vector2i(odd, -1), Vector2i(odd - 1, -1),
				Vector2i(odd - 1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
			for direction in range(6):
				var delta: Vector2i = offsets[direction]
				var next_row := row + delta.y
				var next_col := column + delta.x
				if next_row < 0 or next_row >= rows:
					out[cell * 6 + direction] = -1
					continue
				if next_col < 0:
					next_col += width
				elif next_col >= width:
					next_col -= width
				out[cell * 6 + direction] = next_row * width + next_col
		return out


class FakeExt:
	func get_country_cell_snapshot() -> PackedInt32Array:
		return PackedInt32Array(FixtureSession.OWNERS)


class FakeGenerator:
	func get_data_core_world_ext() -> Object:
		return FakeExt.new()

	func current_map() -> Object:
		return FakeMap.new()

	func region_name_for_cell(_cell: int) -> String:
		return "QINGYANG"

	func get_military_facade() -> Object:
		return null


class FakeController:
	func get_player_country_handle() -> int:
		return 0x100000000

	func military_events_probe(_limit: int = 512) -> Array:
		return [
			{"id": 11, "day": 404, "type": 42, "cell": 1460, "i0": 0, "i1": 3,
				"i2": 40632, "value": 320},
			{"id": 12, "day": 405, "type": 43, "cell": 1466, "i0": 0, "i1": 3,
				"i2": 3, "value": 0},
			{"id": 13, "day": 406, "type": 42, "cell": 1452, "i0": 3, "i1": 0,
				"i2": 30000, "value": 180},
			{"id": 14, "day": 407, "type": 46, "cell": 1388, "i0": 3, "i1": 0,
				"i2": 502, "value": 12000},
			{"id": 15, "day": 408, "type": 40, "cell": -1, "i0": 3, "i1": 0,
				"i2": 9, "value": 0},
		]

	func military_front_probe() -> Dictionary:
		return {"keys": PackedInt32Array([1460 * 6, 1460 * 6 + 1, 1452 * 6 + 3]),
			"progress": PackedByteArray([255, 200, 255])}

	func military_truce_until(_slot: int) -> int:
		return -1

	func battle_log_probe() -> Dictionary:
		return {"available": true, "count": 2, "newest": "1460|7"}

	func get_country_facade() -> Object:
		return null

	func begin_military_arm_order(army: int, mode: String, radius: int) -> Dictionary:
		if army <= 0:
			return {"ok": false, "message": "no army"}
		_armed_mode = mode
		_armed_radius = radius
		return {"ok": true, "mode": mode, "radius": radius}

	var _armed_mode := ""
	var _armed_radius := 0

	func military_arm_order() -> Dictionary:
		return {"army": 0, "mode": _armed_mode, "radius": _armed_radius, "target": -1}

	func cancel_military_arm_order() -> void:
		_armed_mode = ""
		_armed_radius = 0

	# The workspace talks to the controller through request_command; nothing is
	# queued here because these checks only exercise the targeting handshake.
	func request_command(_id: StringName, _args: Dictionary = {}) -> Dictionary:
		return {"ok": true, "code": "queued", "message": ""}
