extends Control
class_name MilitaryDossier

## 右栏军务档案页：部队档案 / 战线档案共用的一套页骨。
##
## 材料：一整张撕纸（PKPaperNote）承载内容，分隔线是手绘的（MilitaryPaperRule），
## 段标题是剪纸标签（PKPaperTag）。地块档案的黄铜框留给主面板，这里是"贴上去的纸"。
##
## 数据层级（不要在别处重排）：
##   部队 = 页头 → 固定指挥区 → 滚动的攻/防/速、战备、编成与后勤
##   战线 = 页头 → 对阵表（双方同指标并排）→ 交战段 → 动作
##
## 节点全部来自 military_dossier.tscn；本脚本只切卡片组、写值、播入场动画。

signal closed()
signal action_requested(action: StringName, payload: Dictionary)
signal army_selected(handle: int)

const TABLE_ROW_HEIGHT := 24.0
const ENTER_SECONDS := 0.26
const ENTER_STAGGER := 0.05
const ENTER_ROTATION := -0.012
const ENTER_SCALE := 0.94

const SAME_CELL_COLUMNS := [
	{"id": "name", "label": "番号", "expand": true, "min_width": 92.0},
	{"id": "heads", "label": "兵力", "width": 58.0, "kind": "number"},
	{"id": "owner", "label": "归属", "width": 72.0, "optional": true},
]
const ENGAGEMENT_COLUMNS := [
	{"id": "zone", "label": "区域", "expand": true, "min_width": 84.0},
	{"id": "progress", "label": "进度", "width": 92.0, "kind": "bar"},
	{"id": "attacker", "label": "攻方", "width": 58.0, "optional": true},
]
const FRONT_ARMY_COLUMNS := [
	{"id": "name", "label": "番号", "expand": true, "min_width": 92.0},
	{"id": "heads", "label": "兵力", "width": 58.0, "kind": "number"},
	{"id": "attack", "label": "攻击", "width": 54.0, "optional": true},
	{"id": "owner", "label": "归属", "width": 66.0, "optional": true},
]

@onready var _sheet: PanelContainer = %Sheet
@onready var _header_icon: IconBadge = %HeaderIcon
@onready var _kicker: Label = %Kicker
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _close_button: Button = %CloseButton
@onready var _peer_stats: MilitaryPeerStats = %PeerStats
@onready var _kpi_cards: Array = [%Kpi0, %Kpi1, %Kpi2, %Kpi3]
@onready var _versus: MilitaryVersusChart = %Versus
@onready var _scroll: ScrollContainer = %Scroll
@onready var _army_group: VBoxContainer = %ArmyGroup
@onready var _composition_bar: DossierStackedBar = %CompositionBar
@onready var _supply_bars: DossierBarList = %SupplyBars
@onready var _badges: BadgeRow = %Badges
@onready var _note: Label = %Note
@onready var _locate_button: Button = %LocateButton
@onready var _move_button: Button = %MoveButton
@onready var _area_button: Button = %AreaButton
@onready var _stop_button: Button = %StopButton
@onready var _stance: OptionButton = %Stance
@onready var _radius: SpinBox = %Radius
@onready var _same_cell_block: Control = %SameCellBlock
@onready var _same_cell_table: DossierLedgerTable = %SameCellTable
@onready var _front_footnote: Label = %FrontFootnote
@onready var _front_armies_block: Control = %FrontArmiesBlock
@onready var _front_armies_table: DossierLedgerTable = %FrontArmiesTable
@onready var _engagement_block: Control = %EngagementBlock
@onready var _engagement_table: DossierLedgerTable = %EngagementTable
@onready var _front_locate_button: Button = %FrontLocateButton

var _identity := ""
var _kind := ""
var _model: Dictionary = {}
var _kpi_signatures: Array = ["", "", "", ""]
var _badge_signature := ""
var _entered := false
var _order_state: Dictionary = {}
var _own := false


func _ready() -> void:
	_guard_scene()
	for card in _kpi_cards:
		if card is Control:
			(card as Control).custom_minimum_size = Vector2(72.0, DossierKpiCard.HEIGHT)
	IconButton.apply(_close_button, &"action.close", IconButton.SMALL, "关闭")
	_close_button.pressed.connect(func() -> void: closed.emit())
	_locate_button.pressed.connect(func() -> void: _emit_action(&"locate", {}))
	_move_button.pressed.connect(func() -> void: _emit_action(&"move", {}))
	_area_button.pressed.connect(func() -> void: _emit_action(&"area", {}))
	_stop_button.pressed.connect(func() -> void: _emit_action(&"stop", {}))
	for label in ["固守", "推进", "强攻", "撤退", "海运中"]:
		_stance.add_item(label)
	_stance.set_item_disabled(4, true)
	_stance.tooltip_text = "固守重防御，推进用于常规作战，强攻承担更高风险；撤退用于脱离战斗。海运由行军自动切换。"
	_stance.item_selected.connect(func(index: int) -> void:
		_emit_action(&"stance", {"stance": index}))
	_radius.value_changed.connect(func(value: float) -> void:
		_emit_action(&"radius", {"radius": int(value)}))
	_radius.get_line_edit().focus_mode = Control.FOCUS_NONE
	%ConfirmOrder.pressed.connect(func() -> void: _emit_action(&"confirm_order", {}))
	%CancelOrder.pressed.connect(func() -> void: _emit_action(&"cancel_order", {}))
	_move_button.toggle_mode = true
	_area_button.toggle_mode = true
	_move_button.focus_neighbor_right = _move_button.get_path_to(_area_button)
	_area_button.focus_neighbor_left = _area_button.get_path_to(_move_button)
	%ConfirmOrder.focus_neighbor_right = %ConfirmOrder.get_path_to(%CancelOrder)
	%CancelOrder.focus_neighbor_left = %CancelOrder.get_path_to(%ConfirmOrder)
	_front_locate_button.pressed.connect(func() -> void: _emit_action(&"locate", {}))
	_configure_tables()


func _guard_scene() -> void:
	if _sheet == null or _peer_stats == null or _versus == null or _scroll == null \
			or _kpi_cards.is_empty() or (_kpi_cards[0] as DossierKpiCard) == null:
		push_error("MilitaryDossier 必须通过 military_dossier.tscn 实例化。")


func _configure_tables() -> void:
	_same_cell_table.set_columns(SAME_CELL_COLUMNS, "", true)
	_same_cell_table.row_height = TABLE_ROW_HEIGHT
	_same_cell_table.selected_id = null
	_same_cell_table.row_selected.connect(func(row_id: Variant) -> void:
		army_selected.emit(int(row_id)))
	_front_armies_table.set_columns(FRONT_ARMY_COLUMNS, "", true)
	_front_armies_table.row_height = TABLE_ROW_HEIGHT
	_front_armies_table.row_selected.connect(func(row_id: Variant) -> void:
		army_selected.emit(int(row_id)))
	_engagement_table.set_columns(ENGAGEMENT_COLUMNS, "", true)
	_engagement_table.row_height = TABLE_ROW_HEIGHT
	_engagement_table.row_selected.connect(func(row_id: Variant) -> void:
		# 行 id 是 min*131072+max 的边标识：定位到较小的一侧。
		var cell := int(int(row_id) / 131072)
		if cell > 0:
			action_requested.emit(&"locate_cell", {"cell": cell}))


## 档案模型（MilitaryViewModel.army_dossier / front_dossier 的输出）。
func set_model(payload: Dictionary) -> void:
	if payload.is_empty():
		clear()
		return
	var identity := String(payload.get("identity", ""))
	var identity_changed := identity != _identity
	if identity_changed:
		_order_state.clear()
		_identity = identity
		_kind = String(payload.get("kind", ""))
		_kpi_signatures = ["", "", "", ""]
		_badge_signature = ""
		_same_cell_table.selected_id = null
		if _scroll != null:
			_scroll.scroll_vertical = 0
		_switch_kind(_kind)
	_model = payload
	_apply_header(payload)
	if _kind == "army":
		_apply_army(payload)
	elif _kind == "front":
		_apply_front(payload)
	if identity_changed:
		set_order_state({})
		_play_enter()
		if _kind == "army":
			(_move_button if _own else _locate_button).grab_focus()


func clear() -> void:
	_order_state.clear()
	_identity = ""
	_kind = ""
	_model.clear()
	_kpi_signatures = ["", "", "", ""]
	_badge_signature = ""
	_same_cell_table.selected_id = null
	_entered = false


func identity() -> String:
	return _identity


func kind() -> String:
	return _kind


func model() -> Dictionary:
	return _model


func _switch_kind(kind: String) -> void:
	var army := kind == "army"
	_army_group.visible = army
	_peer_stats.visible = army
	%KpiRow.visible = army
	%StateRule.visible = army
	%Versus.visible = not army
	%FrontGroup.visible = not army
	%CommandDeck.visible = army
	%DetailRule.visible = not army


func _emit_action(action: StringName, extra: Dictionary) -> void:
	var payload := extra.duplicate()
	payload["identity"] = _identity
	payload["focus_cell"] = int(_model.get("focus_cell", -1))
	payload["handle"] = int(_model.get("selected", 0)) if _kind == "army" else 0
	action_requested.emit(action, payload)


func _apply_header(payload: Dictionary) -> void:
	_kicker.text = String(payload.get("kicker", ""))
	_title.text = String(payload.get("title", ""))
	_title.tooltip_text = _title.text
	_subtitle.text = String(payload.get("subtitle", ""))
	_subtitle.tooltip_text = _subtitle.text
	_header_icon.set_semantic(StringName(payload.get("icon", &"military.banner")),
		payload.get("accent", UITokens.DOSSIER_OXBLOOD))


func _apply_kpis(kpis: Array) -> void:
	var visible_count := mini(kpis.size(), _kpi_cards.size())
	for i in range(_kpi_cards.size()):
		var card := _kpi_cards[i] as DossierKpiCard
		if card == null:
			continue
		card.visible = i < visible_count
		card.show_divider = i < visible_count - 1
		if i >= visible_count:
			continue
		var data: Dictionary = kpis[i]
		var signature := "%s|%s|%s|%s|%s|%s" % [
			String(data.get("title", "")), String(data.get("kind", "")),
			str(data.get("value", "")), String(data.get("text", "")),
			String(data.get("caption", "")), String(data.get("tone", ""))]
		if _kpi_signatures[i] == signature:
			continue
		_kpi_signatures[i] = signature
		card.set_metric(data)


func _apply_army(payload: Dictionary) -> void:
	var army: Dictionary = payload.get("army", {})
	_own = bool(army.get("own", false))
	%Mission.text = String(army.get("mission_text", "待命"))
	%Mission.tooltip_text = %Mission.text
	_stance.select(clampi(int(army.get("stance", 0)), 0, 4))
	_stance.disabled = not _own or int(army.get("stance", 0)) == 4
	%StanceRow.visible = _own
	var peers: Array = army.get("peer_stats", [])
	_peer_stats.visible = not peers.is_empty()
	if not peers.is_empty():
		_peer_stats.set_stats(peers)
	_apply_kpis(payload.get("kpis", []))
	var composition: Dictionary = army.get("composition", {})
	_composition_bar.set_segments(String(composition.get("title", "")),
		composition.get("segments", []), String(composition.get("total", "")), false)
	var supply_rows: Array = army.get("supply_rows", [])
	_supply_bars.visible = not supply_rows.is_empty()
	if not supply_rows.is_empty():
		_supply_bars.set_rows(supply_rows)
	_apply_badges(army.get("badges", []))
	var note := String(army.get("note", ""))
	_note.text = note
	_note.visible = not note.is_empty()
	%StatusBlock.visible = _badges.visible or _note.visible
	_apply_actions(army.get("actions", []), int(payload.get("selected", 0)))
	var same_rows: Array = army.get("same_cell_rows", [])
	_same_cell_block.visible = not same_rows.is_empty()
	if not same_rows.is_empty():
		_same_cell_table.set_rows(same_rows)


func _apply_actions(actions: Array, selected: int) -> void:
	var by_id := {}
	for raw in actions:
		var action := raw as Dictionary
		by_id[String(action.get("id", ""))] = bool(action.get("enabled", true))
	_locate_button.visible = by_id.has("locate")
	_locate_button.disabled = not bool(by_id.get("locate", true))
	_move_button.visible = _own and by_id.has("move")
	_move_button.disabled = selected <= 0 or not bool(by_id.get("move", false))
	_area_button.visible = _own and by_id.has("area")
	_area_button.disabled = selected <= 0 or not bool(by_id.get("area", false))
	_stop_button.visible = _own and by_id.has("stop")
	_stop_button.disabled = not bool(by_id.get("stop", false))
	%ArmyActions.visible = _locate_button.visible or _move_button.visible \
		or _area_button.visible


## 选点草稿是会话输入状态，和每日军事快照分开写；刷新不会清掉路线或焦点。
func set_order_state(state: Dictionary) -> void:
	var was_ready := bool(_order_state.get("ready", false))
	var was_active := not String(_order_state.get("mode", "")).is_empty()
	_order_state = state.duplicate()
	var mode := String(state.get("mode", ""))
	var active := not mode.is_empty() and int(state.get("army", 0)) == int(_model.get("selected", 0))
	%OrderDraft.visible = active and _kind == "army"
	_move_button.set_pressed_no_signal(active and mode == "move")
	_area_button.set_pressed_no_signal(active and mode == "area")
	%RadiusRow.visible = active and mode == "area"
	_radius.set_value_no_signal(int(state.get("radius", 1)))
	%ConfirmOrder.disabled = not active or not bool(state.get("ready", false))
	%ConfirmOrder.text = "确认控制区域" if mode == "area" else "确认行军"
	%OrderSummary.text = "先选择地图目标"
	if active and bool(state.get("ready", false)):
		%OrderSummary.text = "控制 %d 格 · 抵达中心约 %d 日" % [int(state.get("cell_count", 0)),
			int(state.get("days", 0))] if mode == "area" else "预计行军 %d 日" % int(state.get("days", 0))
	%CommandHint.theme_type_variation = &"PKDossierCaption"
	%CommandHint.text = String(state.get("message", "")) if active else (
		"M 行军 · C 区域控制 · X 停止任务" if _own else "其他国家的部队，可查看战备与编成。")
	%CommandHint.visible = true
	if not active and was_active and _kind == "army" and is_visible_in_tree():
		(_move_button if _own else _locate_button).grab_focus()
	if active:
		%CommandHint.text += "\n右键或 Esc 取消选点。"
		if bool(state.get("ready", false)) and not was_ready:
			%ConfirmOrder.grab_focus()
		elif not bool(state.get("ready", false)):
			# 激活行军的按钮不能继续吃掉 Enter 并重新开始选点。
			var focus := get_viewport().gui_get_focus_owner()
			if focus != null and is_ancestor_of(focus):
				focus.release_focus()


func show_feedback(message: String, ok: bool) -> void:
	%CommandHint.text = message
	%CommandHint.theme_type_variation = &"PKDossierCaption" if ok else &"PKDangerText"
	%CommandHint.visible = not message.is_empty()


func handle_order_key(event: InputEvent) -> bool:
	if not is_visible_in_tree() or _kind != "army" or not event is InputEventKey \
			or not event.is_pressed() or event.is_echo():
		return false
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	var key := event as InputEventKey
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return false
	if not String(_order_state.get("mode", "")).is_empty():
		if key.keycode == KEY_ESCAPE:
			_emit_action(&"cancel_order", {})
			return true
		if key.keycode in [KEY_ENTER, KEY_KP_ENTER] and not %ConfirmOrder.disabled:
			_emit_action(&"confirm_order", {})
			return true
	if not _own:
		return false
	var shortcuts := {KEY_M: _move_button, KEY_C: _area_button, KEY_X: _stop_button}
	if shortcuts.has(key.keycode) and not (shortcuts[key.keycode] as Button).disabled:
		(shortcuts[key.keycode] as Button).pressed.emit()
		return true
	return false


func _apply_badges(badges: Array) -> void:
	var labels := PackedStringArray()
	for raw in badges:
		labels.append(String((raw as Dictionary).get("text", "")))
	var signature := "%d:%s" % [badges.size(), "|".join(labels)]
	if signature == _badge_signature:
		return
	_badge_signature = signature
	_badges.visible = not badges.is_empty()
	if badges.is_empty():
		return
	_badges.set_badges(badges)


func _apply_front(payload: Dictionary) -> void:
	var front: Dictionary = payload.get("front", {})
	var versus: Dictionary = front.get("versus", {})
	_versus.set_rows(versus.get("rows", []),
		versus.get("own_color", UITokens.DOSSIER_VERDIGRIS),
		versus.get("enemy_color", UITokens.DOSSIER_OXBLOOD),
		String(versus.get("own_label", "我方")),
		String(versus.get("enemy_label", "敌方")))
	var footnote := String(front.get("footnote", ""))
	_front_footnote.text = footnote
	_front_footnote.visible = not footnote.is_empty()
	var army_rows: Array = front.get("army_rows", [])
	var armies_visible := bool(front.get("army_visible", false)) and not army_rows.is_empty()
	_front_armies_block.visible = armies_visible
	if armies_visible:
		_front_armies_table.set_rows(army_rows)
	var rows: Array = front.get("engagement_rows", [])
	var visible := bool(front.get("engagement_visible", false)) and not rows.is_empty()
	_engagement_block.visible = visible
	if visible:
		_engagement_table.set_rows(rows)


## 入场：纸片逐块落下。只动 alpha / 轻微旋转 / 极小缩放，
## 不碰 position（容器布局会覆盖它），也不在 reduced_motion 下播放。
## 缩放用 TRANS_BACK：落纸时有一点点过冲，读起来是"放上去"而不是"淡出来"。
func _play_enter() -> void:
	if UIAnimation.reduced_motion():
		return
	if not _entered:
		_entered = true
		_sheet.modulate.a = 0.0
		_sheet.scale = Vector2(0.985, 0.985)
		_sheet.pivot_offset = Vector2(_sheet.size.x * 0.5, _sheet.size.y * 0.5)
		var sheet_tween := create_tween().set_parallel(true)
		sheet_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		sheet_tween.tween_property(_sheet, "modulate:a", 1.0, 0.18)
		sheet_tween.tween_property(_sheet, "scale", Vector2.ONE, 0.22)
	var blocks := _visible_blocks()
	for i in blocks.size():
		var block := blocks[i] as Control
		if block == null:
			continue
		block.modulate.a = 0.0
		block.rotation = ENTER_ROTATION
		block.scale = Vector2(1.0, ENTER_SCALE)
		block.pivot_offset = Vector2(minf(block.size.x, 240.0) * 0.5, 0.0)
		var delay := ENTER_STAGGER * float(i)
		var tween := create_tween().set_parallel(true)
		tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(block, "scale", Vector2.ONE, ENTER_SECONDS).set_delay(delay)
		tween.tween_property(block, "rotation", 0.0, ENTER_SECONDS).set_delay(delay)
		var fade := create_tween()
		fade.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		fade.tween_property(block, "modulate:a", 1.0, ENTER_SECONDS * 0.7).set_delay(delay)


func _visible_blocks() -> Array:
	var blocks: Array = []
	if _kind == "army":
		blocks = [_peer_stats, %KpiRow, %CompositionBlock, %SupplyBlock,
			%StatusBlock, %SameCellBlock]
	else:
		blocks = [_versus, %FrontFootnote, %FrontArmiesBlock, %EngagementBlock,
			%FrontGroup.get_node("FrontActions")]
	var visible: Array = []
	for block in blocks:
		if block is Control and (block as Control).visible:
			visible.append(block)
	return visible
