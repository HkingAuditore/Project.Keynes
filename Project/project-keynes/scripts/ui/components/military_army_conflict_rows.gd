extends RefCounted

## Updates the military workspace's army, logistics, and conflict displays.

const MilitaryTableRows = preload("res://scripts/ui/components/military_table_rows.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")


# ── armies & logistics ─────────────────────────────────────────────────
#
# 这里只是索引：一行说明「哪支部队、多少人、还能不能打」，编成、补给天数、
# 移动 / 军事控制 / 停止 / 解散都在军务档案面板里（点击行或「档案」按钮）。

static func _refresh_armies(workspace: MilitaryWorkspace) -> void:
	var data: Dictionary = workspace._vm.build("armies", {"army": workspace._selected_army})
	var rows: Array = data.get("rows", [])
	workspace._selected_army = int(data.get("selected", 0))
	var total := 0
	for row in rows:
		total += int(row.headcount)
	workspace._army_caption.text = "%d 支 · %s 人" % [rows.size(), MilitaryTableRows._count(total)]
	workspace._army_empty.visible = rows.is_empty()
	workspace.get_node("%ArmyGrid").visible = not rows.is_empty()
	if workspace._changed("army_rows", rows):
		workspace._apply_army_rows(rows)
	workspace._army_table.selected_id = workspace._selected_army
	workspace._army_table.queue_redraw()
	var convoys: Array = data.get("convoys", [])
	var at_risk := convoys.filter(func(c): return float(c.risk) >= 0.25).size()
	workspace._convoy_table.visible = not convoys.is_empty()
	workspace._convoy_caption.visible = not convoys.is_empty()
	if not convoys.is_empty():
		workspace._convoy_caption.text = ("%d 支 · %d 支高风险" % [convoys.size(), at_risk]) if at_risk > 0 \
			else "%d 支" % convoys.size()
	if workspace._changed("convoys", convoys):
		workspace._apply_convoys(convoys)
	var procurement_text := String(data.get("procurement_text", ""))
	workspace._procurement_label.visible = not procurement_text.is_empty()
	workspace._procurement_label.text = procurement_text

static func _apply_army_rows(workspace: MilitaryWorkspace, rows: Array) -> void:
	MilitaryTableRows._apply_army_rows( workspace._army_table, rows)

static func _apply_convoys(workspace: MilitaryWorkspace, convoys: Array) -> void:
	MilitaryTableRows._apply_convoys( workspace._convoy_table, convoys)

static func _on_army_action(workspace: MilitaryWorkspace, handle, action_id: String) -> void:
	match String(action_id):
		"locate":
			workspace.locate_cell_requested.emit(workspace._army_cell(int(handle)))
		"dossier":
			workspace._open_army_dossier(int(handle))

## 「定位」= 镜头落到部队所在格；「档案」= 打开军务档案（外壳会顺带对焦）。
static func _open_army_dossier(workspace: MilitaryWorkspace, handle: int) -> void:
	if handle <= 0:
		return
	workspace._selected_army = handle
	workspace.dossier_requested.emit("army", handle, workspace._army_cell(handle))

static func _army_cell(workspace: MilitaryWorkspace, handle: int) -> int:
	for raw in workspace._vm.armies():
		if int(raw.get("handle", 0)) == handle:
			return int(raw.get("cell", -1))
	return -1

static func selected_army(workspace: MilitaryWorkspace) -> int:
	return workspace._selected_army

static func set_selected_army(workspace: MilitaryWorkspace, army_handle: int) -> void:
	workspace._selected_army = army_handle
	if workspace.is_node_ready():
		workspace._refresh_armies()

static func _on_convoy_selected(workspace: MilitaryWorkspace, convoy_id) -> void:
	for raw in workspace._vm.snapshot().get("convoys", []):
		if int(raw.get("id", 0)) == int(convoy_id):
			workspace.locate_cell_requested.emit(int(raw.get("current_cell", -1)))

# ── war & peace ─────────────────────────────────────────────────────────
#
# 这一页只回答「在打谁、打到什么程度、要不要谈」。条款编辑器在议和面板里
# （每张战争卡的「议和」按钮打开它），战报属于战争细节，也不在这里堆。

static func _refresh_war(workspace: MilitaryWorkspace) -> void:
	var data: Dictionary = workspace._vm.build("war", {"war": workspace._selected_war})
	workspace._war_data = data
	var wars: Array = data.get("wars", [])
	workspace._selected_war = int(data.get("selected", 0))
	workspace._war_empty.visible = wars.is_empty()
	workspace.get_node("%WarGrid").visible = not wars.is_empty()
	for index in range(workspace._war_cards.size()):
		var card: Control = workspace._war_cards[index]
		card.visible = index < wars.size()
		if card.visible:
			card.set_data(wars[index])
			card.modulate = Color.WHITE if int(wars[index].id) == workspace._selected_war \
				else Color(1, 1, 1, 0.72)
	workspace._refresh_declare(data)
	workspace._refresh_fronts(data)

# ── 宣战：邻国候选（真实领土图 + Country 名称）──────────────────────────

static func _refresh_declare(workspace: MilitaryWorkspace, data: Dictionary) -> void:
	var rows: Array = data.get("declare", [])
	workspace._declare_caption.text = "%d 个邻国" % rows.size() if not rows.is_empty() else ""
	workspace._declare_empty.visible = rows.is_empty()
	workspace._declare_empty.text = "邻接领土图上没有其他国家。" if workspace._vm.session_bound() \
		else "暂时读不到邻国领土，请稍后重试。"
	if workspace._changed("declare", rows):
		var table_rows: Array = []
		for row in rows:
			var reason := String(row.reason)
			var state := reason if not reason.is_empty() else "可宣战"
			var tone := UITokens.DOSSIER_OXBLOOD if bool(row.can_declare) \
				else UITokens.DOSSIER_INK_MUTED
			var actions: Array = []
			if bool(row.can_declare) and int(row.handle) != 0:
				actions.append({"id": "declare", "icon": "military.war.front",
					"tooltip": "向%s宣战" % String(row.name)})
			table_rows.append({
				"id": int(row.id),
				"muted": not bool(row.can_declare),
				"tooltip": "%s\n边域 %d 格 · %s" % [String(row.name), int(row.cells), state],
				"cells": {
					"name": {"text": String(row.name), "icon": "country.military",
						"color": UITokens.DOSSIER_INK},
					"capital": {"text": String(row.capital)},
					"cells": {"text": "%d" % int(row.cells), "sort": float(row.cells)},
					"state": {"text": state, "color": tone},
					"actions": {},
				},
				"actions": actions,
			})
		workspace._declare_table.set_rows(table_rows)

static func _on_war_card_input(workspace: MilitaryWorkspace, event: InputEvent, card: Control) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		workspace._selected_war = int(card.war_id)
		workspace._refresh_war()

static func _on_declare_selected(workspace: MilitaryWorkspace, row_id) -> void:
	var row: Dictionary = workspace._declare_row(int(row_id))
	if row.is_empty():
		return
	if not bool(row.can_declare):
		workspace._flash("%s 目前无法宣战：%s" % [String(row.name), String(row.reason)], true)
		return
	workspace._request(PlayerControllerScript.COMMAND_MILITARY_WAR_DECLARE,
		{"target": int(row.handle)})

static func _on_declare_action(workspace: MilitaryWorkspace, row_id, action_id: String) -> void:
	if action_id == "declare":
		workspace._on_declare_selected(row_id)

static func _declare_row(workspace: MilitaryWorkspace, row_id: int) -> Dictionary:
	for row in workspace._war_data.get("declare", []):
		if int(row.id) == row_id:
			return row
	return {}

# ── 战线 ────────────────────────────────────────────────────────────────

static func _refresh_fronts(workspace: MilitaryWorkspace, data: Dictionary) -> void:
	var rows: Array = data.get("fronts", [])
	# 和平（无战线）时空态整节不渲染；仅数据源缺失时给出原因提示（后果提示保留）。
	var front_source_missing := not bool(data.get("front_source", true))
	workspace._front_empty.visible = rows.is_empty() and front_source_missing
	if front_source_missing:
		workspace._front_empty.text = "暂时读不到战线情报。"
	if workspace._changed("fronts", rows):
		var list_rows: Array = []
		for row in rows:
			var progress := float(row.progress)
			list_rows.append({
				"id": String(row.id),
				"label": String(row.zone),
				"text": "%s · %d 处接触" % [String(row.text), int(row.edges)],
				"value": progress,
				"color": UITokens.DOSSIER_OXBLOOD if progress > 0.001
					else UITokens.DOSSIER_SLATE,
				"tooltip": "%s · %d 处接触\n点击打开战线档案" % [String(row.zone),
					int(row.edges)],
			})
		workspace._front_list.set_rows(list_rows)

## 点战线 = 打开战线档案；外壳会同时把镜头落到该扇区（等同于「定位」）。
static func _on_front_selected(workspace: MilitaryWorkspace, row_id) -> void:
	for row in workspace._war_data.get("fronts", []):
		if String(row.id) == String(row_id):
			workspace.dossier_requested.emit("front", int(row.cell), int(row.cell))
			return

# ── commands ────────────────────────────────────────────────────────────

static func _request(workspace: MilitaryWorkspace, id: StringName, args: Dictionary) -> Dictionary:
	if workspace._player_controller == null or not workspace._player_controller.has_method("request_command"):
		workspace._flash("命令暂未接通，请稍后重试。", true)
		return {}
	var result: Dictionary = workspace._player_controller.request_command(id, args)
	if bool(result.get("ok", false)):
		workspace._flash(String(result.get("message", "已下达。")), false)
	else:
		workspace._flash(String(result.get("message", "命令未生效，请重试或查看军情。")), true)
	return result

static func _show_status(workspace: MilitaryWorkspace, text: String, danger: bool) -> void:
	workspace._status_label.text = text
	workspace._status_label.visible = not text.is_empty()
	workspace._status_label.theme_type_variation = &"PKDangerText" if danger else &"PKDossierCaption"
