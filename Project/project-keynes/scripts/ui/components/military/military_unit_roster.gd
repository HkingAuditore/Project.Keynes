extends DossierChart

## 兵种名册：已解锁兵种的紧凑图形卡网格。
##
## 一张卡回答四个玩家问题——「这是什么兵、打得多狠、每天花多少、还差什么装备」：
##   行1  纸贴兵种图 + 中文名 + 成军天数   ·  右端 份额% 与 ±
##   行2  攻 / 防 / 速 三条迷你条（同一份可见集合内归一）+ 原值
##   行3  军饷（金币/百人日）· 供给类别图标 · 装备低品质需求
##   行4  份额轨道（余量即民兵）
##
## 全部自绘：每日刷新只重画、不重建节点树；网格列数按控件实宽重算，窄屏自动单列。

signal share_step(unit_id: String, delta_bp: int)

const CARD_HEIGHT := 96.0
const MIN_CARD_WIDTH := 292.0
const MAX_COLUMNS := 3
const GAP := 8.0
const PAD := 10.0
const ICON := 32.0
const ACTION := 22.0
const ACTION_GAP := 4.0
const EMPTY_HEIGHT := 48.0
const STEP_BP := 500

var empty_text := "尚未解锁可配置的兵种：先研究军事科技"
## 未解锁兵种默认不进军册；打开后灰显（名字、所需科技都在，± 不可用）。
var show_locked := false:
	set(value):
		if show_locked == value:
			return
		show_locked = value
		_rebuild()

var _all_rows: Array = []
var _rows: Array = []
var _rects: Array = []
var _hover := -1
var _hover_action := ""


func _init() -> void:
	super()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_PASS


## `rows` 是 MilitaryViewModel.unit_share_rows() 的行，已按时代 + 战力排好序。
func set_units(rows: Array) -> void:
	_all_rows = rows if rows != null else []
	_rebuild()
	_start_animation()


func row_count() -> int:
	return _rows.size()


func total_count() -> int:
	return _all_rows.size()


## 供截图/结构测试核对版式：每张卡的矩形（自绘，没有子控件可量）。
func card_rects() -> Array:
	return _rects.duplicate()


func _rebuild() -> void:
	_rows = []
	for row_value in _all_rows:
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		# 未解锁且没有份额的兵种不进配置表；已经占着份额的必须留着，
		# 否则玩家点不到「−」把份额收回来。
		if not show_locked and bool(row.get("locked", false)) \
				and int(row.get("bp", 0)) <= 0:
			continue
		_rows.append(row)
	_relayout()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			_relayout()
		NOTIFICATION_MOUSE_EXIT:
			if _hover >= 0 or not _hover_action.is_empty():
				_hover = -1
				_hover_action = ""
				tooltip_text = ""
				queue_redraw()


func _relayout() -> void:
	var width := maxf(MIN_CARD_WIDTH, size.x)
	var columns := clampi(int(floor((width + GAP) / (MIN_CARD_WIDTH + GAP))), 1, MAX_COLUMNS)
	var card_width := (width - GAP * float(columns - 1)) / float(columns)
	_rects.clear()
	for index in range(_rows.size()):
		var column := index % columns
		var row_index := index / columns
		_rects.append(Rect2(Vector2(float(column) * (card_width + GAP),
			float(row_index) * (CARD_HEIGHT + GAP)), Vector2(card_width, CARD_HEIGHT)))
	var row_count := ceili(float(_rows.size()) / float(columns))
	var wanted := maxf(CARD_HEIGHT, float(row_count) * (CARD_HEIGHT + GAP) - GAP) \
		if not _rows.is_empty() else EMPTY_HEIGHT
	if absf(custom_minimum_size.y - wanted) > 0.5:
		custom_minimum_size.y = wanted
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover((event as InputEventMouseMotion).position)
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
			return
		_update_hover(button.position)
		if _hover < 0 or _hover >= _rows.size():
			return
		var row: Dictionary = _rows[_hover]
		if _hover_action.is_empty():
			return
		var delta := STEP_BP if _hover_action == "raise" else -STEP_BP
		share_step.emit(String(row.get("id", "")), delta)
		accept_event()


func _update_hover(point: Vector2) -> void:
	var hit := -1
	var action := ""
	for index in range(_rects.size()):
		if (_rects[index] as Rect2).has_point(point):
			hit = index
			action = _action_at(index, point)
			break
	if hit == _hover and action == _hover_action:
		return
	_hover = hit
	_hover_action = action
	tooltip_text = _tooltip(_rows[hit], action) if hit >= 0 else ""
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
		if hit >= 0 and not action.is_empty() else Control.CURSOR_ARROW
	queue_redraw()


func _action_rects(index: int) -> Array:
	if index < 0 or index >= _rects.size():
		return []
	var row: Dictionary = _rows[index]
	# 民兵吃的是「没分配掉的份额」，不是可配置的编制：没有 ±。
	if bool(row.get("is_militia_row", false)):
		return []
	var rect: Rect2 = _rects[index]
	var locked := bool(row.get("locked", false))
	var can_raise := not locked and bool(row.get("can_raise", true))
	var can_lower := int(row.get("bp", 0)) > 0
	var top := rect.position.y + PAD - 2.0
	var right := rect.end.x - PAD
	return [
		{"id": "raise", "enabled": can_raise,
			"rect": Rect2(Vector2(right - ACTION, top), Vector2(ACTION, ACTION))},
		{"id": "lower", "enabled": can_lower,
			"rect": Rect2(Vector2(right - ACTION * 2.0 - ACTION_GAP, top),
				Vector2(ACTION, ACTION))},
	]


func _action_at(index: int, point: Vector2) -> String:
	for entry in _action_rects(index):
		if not bool(entry.get("enabled", true)):
			continue
		if (entry.rect as Rect2).has_point(point):
			return String(entry.id)
	return ""


# ── drawing ──────────────────────────────────────────────────────────────

func _draw() -> void:
	if _rows.is_empty():
		_text(Vector2(0.0, 20.0), empty_text, 13, UITokens.DOSSIER_INK_MUTED,
			"sans", HORIZONTAL_ALIGNMENT_CENTER, size.x)
		return
	for index in range(mini(_rects.size(), _rows.size())):
		_draw_card(index, _rects[index], _rows[index])


func _draw_card(index: int, rect: Rect2, row: Dictionary) -> void:
	var locked := bool(row.get("locked", false))
	var accent: Color = row.get("color", UITokens.DOSSIER_BRASS)
	draw_rect(rect, Color(UITokens.DOSSIER_PAPER_DEEP, 0.20 if locked else 0.42))
	if index == _hover:
		draw_rect(rect, UITokens.DOSSIER_HOVER)
	draw_rect(rect, Color(UITokens.DOSSIER_RULE, 0.55), false, 1.0)
	draw_rect(Rect2(rect.position, Vector2(3.0, rect.size.y)),
		Color(accent, 0.35 if locked else 0.95))
	var ui_alpha := 0.45 if locked else 1.0
	# ── 行1：图标 / 名字 / 成军天数 / 份额 + ± ──────────────────────────
	var icon_rect := Rect2(rect.position + Vector2(PAD, PAD - 2.0), Vector2(ICON, ICON))
	IconCatalog.draw_icon(self, StringName(row.get("icon", "military.unit.line")),
		icon_rect, ui_alpha)
	var text_x := icon_rect.end.x + 8.0
	var actions := _action_rects(index)
	var share_right := rect.end.x - PAD - 4.0
	if actions.size() >= 2:
		share_right = float((actions[1].rect as Rect2).position.x) - 8.0
	var share_bp := int(row.get("bp", 0))
	var share_text := "%d%%" % int(round(float(share_bp) / 100.0))
	_text(Vector2(share_right - 34.0, rect.position.y + 22.0), share_text, 14,
		Color(UITokens.DOSSIER_INK, ui_alpha), "sans_strong", HORIZONTAL_ALIGNMENT_RIGHT, 34.0)
	if locked:
		IconCatalog.draw_icon(self, &"technology.state.locked",
			Rect2(Vector2(share_right - 52.0, rect.position.y + 9.0), Vector2(13.0, 13.0)),
			0.75)
	var name_room := share_right - (52.0 if locked else 34.0) - text_x - 6.0
	var name := String(row.get("name", ""))
	var days := int(row.get("training_days", 0))
	var suffix := " %d日" % days if days > 0 else ""
	var suffix_width := _text_width(suffix, 11) if not suffix.is_empty() else 0.0
	_text(Vector2(text_x, rect.position.y + 22.0),
		_fit_text(name, 14, maxf(40.0, name_room - suffix_width), "sans_strong"), 14,
		Color(UITokens.DOSSIER_INK, ui_alpha), "sans_strong")
	if not suffix.is_empty() and _text_width(name, 14, "sans_strong") + suffix_width < name_room:
		_text(Vector2(text_x + _text_width(name, 14, "sans_strong"), rect.position.y + 22.0),
			suffix, 11, Color(UITokens.DOSSIER_INK_MUTED, ui_alpha))
	_draw_actions(actions)
	# ── 行2：攻 / 防 / 速 ───────────────────────────────────────────────
	var stats_top := rect.position.y + 42.0
	var inner := rect.size.x - PAD * 2.0
	var group := (inner - 16.0) / 3.0
	_draw_stat(Vector2(rect.position.x + PAD, stats_top), group,
		&"military.army.attack", float(row.get("attack", 0.0)),
		float(row.get("attack_ratio", 0.0)), locked)
	_draw_stat(Vector2(rect.position.x + PAD + group + 8.0, stats_top), group,
		&"military.army.defense", float(row.get("defense", 0.0)),
		float(row.get("defense_ratio", 0.0)), locked)
	_draw_stat(Vector2(rect.position.x + PAD + (group + 8.0) * 2.0, stats_top), group,
		&"hud.clock.speed", float(row.get("speed", 0.0)),
		float(row.get("speed_ratio", 0.0)), locked)
	# ── 行3：军饷 / 供给 / 装备 ─────────────────────────────────────────
	var chips_baseline := rect.position.y + 68.0
	var chips_x := rect.position.x + PAD
	chips_x = _draw_wage(chips_x, chips_baseline, row, locked)
	var equip_width := _equipment_width(row)
	for chip_value in row.get("supply", []):
		if chips_x + 18.0 + equip_width > rect.end.x - PAD:
			break
		var chip: Dictionary = chip_value
		IconCatalog.draw_icon(self, StringName(chip.get("icon", "")),
			Rect2(Vector2(chips_x, chips_baseline - 11.0), Vector2(12.0, 12.0)), ui_alpha * 0.9)
		chips_x += 14.0
	_draw_equipment(chips_x, chips_baseline, rect, row, locked, equip_width)
	# ── 行4：份额轨道 ──────────────────────────────────────────────────
	var track := Rect2(Vector2(rect.position.x + PAD, rect.end.y - PAD - 3.0),
		Vector2(rect.size.x - PAD * 2.0, 4.0))
	_rounded_bar(track, UITokens.DOSSIER_TRACK, 2.0)
	var fill := clampf(float(share_bp) / 10000.0, 0.0, 1.0) * _grow
	if fill > 0.001:
		_rounded_bar(Rect2(track.position, Vector2(track.size.x * fill, 4.0)),
			Color(accent, ui_alpha), 2.0)


func _draw_actions(actions: Array) -> void:
	for entry in actions:
		var rect: Rect2 = entry.rect
		var id := String(entry.id)
		if not bool(entry.get("enabled", true)):
			draw_rect(rect, Color(UITokens.DOSSIER_RULE, 0.22), false, 1.0)
			_text(Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5 + 5.0),
				"+" if id == "raise" else "−", 14, Color(UITokens.DOSSIER_INK_MUTED, 0.35),
				"sans_strong", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)
			continue
		var active := id == _hover_action and _hover >= 0
		draw_rect(rect, UITokens.DOSSIER_HOVER if active else Color(
			UITokens.DOSSIER_PAPER, 0.55))
		draw_rect(rect, UITokens.DOSSIER_BRASS if active else UITokens.DOSSIER_RULE, false, 1.0)
		_text(Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5 + 5.0),
			"+" if id == "raise" else "−", 14,
			UITokens.DOSSIER_OXBLOOD if active else UITokens.DOSSIER_INK_SOFT,
			"sans_strong", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)


## 一组「攻/防/速」：图标 + 紧跟数值 + 余下宽度画迷你条，读起来是「攻 1.6 ▬▬▬▬」。
func _draw_stat(origin: Vector2, group: float, icon: StringName, value: float,
		ratio: float, locked: bool) -> void:
	var ui_alpha := 0.45 if locked else 1.0
	IconCatalog.draw_icon(self, icon, Rect2(origin, Vector2(12.0, 12.0)), ui_alpha * 0.85)
	var number_width := 26.0
	_text(Vector2(origin.x + 15.0, origin.y + 10.0), "%.1f" % value, 12,
		Color(UITokens.DOSSIER_INK, ui_alpha), "sans_strong", HORIZONTAL_ALIGNMENT_LEFT,
		number_width)
	var bar_left := origin.x + 15.0 + number_width
	var bar_width := maxf(14.0, group - 15.0 - number_width - 2.0)
	var bar := Rect2(Vector2(bar_left, origin.y + 4.0), Vector2(bar_width, 5.0))
	_rounded_bar(bar, UITokens.DOSSIER_TRACK, 2.0)
	_rounded_bar(Rect2(bar.position, Vector2(bar_width * clampf(ratio, 0.0, 1.0) * _grow, 5.0)),
		Color(UITokens.DOSSIER_BRASS, ui_alpha), 2.0)


## 军饷：金币 + 「/百人日」。经济尚未发布时写「待结算」，绝不印 0 金币。
func _draw_wage(left: float, baseline: float, row: Dictionary, locked: bool) -> float:
	var wage := float(row.get("wage_per_100", 0.0))
	var ui_alpha := 0.45 if locked else 1.0
	if wage <= 0.0:
		_text(Vector2(left, baseline), "军饷待结算", 11,
			Color(UITokens.DOSSIER_INK_MUTED, ui_alpha))
		return left + _text_width("军饷待结算", 11) + 10.0
	var text := UITokens.format_compact_number_cn(wage,
		2 if wage < 10.0 and absf(wage - roundf(wage)) > 0.05 else 0)
	var width := _money_text(Vector2(left, baseline), text, 12,
		Color(UITokens.DOSSIER_INK, ui_alpha), "sans_strong")
	_text(Vector2(left + width + 1.0, baseline), "/百人日", 10,
		Color(UITokens.DOSSIER_INK_MUTED, ui_alpha))
	return left + width + _text_width("/百人日", 10) + 10.0


func _equipment_width(row: Dictionary) -> float:
	var slots: Array = row.get("equipment", [])
	return float(slots.size()) * 30.0


## 装备需求：类别纸贴 + 最低品质，右对齐；宽度不够时整组省略（tooltip 仍有全量）。
func _draw_equipment(left: float, baseline: float, rect: Rect2, row: Dictionary,
		locked: bool, needed: float) -> void:
	var slots: Array = row.get("equipment", [])
	if slots.is_empty():
		return
	var right := rect.end.x - PAD
	if left + needed > right:
		return
	var ui_alpha := 0.45 if locked else 1.0
	var cursor := right - needed
	for slot_value in slots:
		var slot: Dictionary = slot_value
		IconCatalog.draw_icon(self, StringName(slot.get("icon", "")),
			Rect2(Vector2(cursor, baseline - 11.0), Vector2(12.0, 12.0)), ui_alpha * 0.9)
		_text(Vector2(cursor + 13.0, baseline), String(slot.get("quality_text", "")), 10,
			Color(UITokens.DOSSIER_INK_MUTED, ui_alpha))
		cursor += 30.0


# ── tooltip ──────────────────────────────────────────────────────────────

static func _tooltip(row: Dictionary, action: String) -> String:
	if action == "raise":
		return "把 %s 的编制份额提高 5%%" % String(row.get("name", ""))
	if action == "lower":
		return "把 %s 的编制份额降低 5%%" % String(row.get("name", ""))
	var lines := PackedStringArray()
	var title := String(row.get("name", ""))
	if bool(row.get("locked", false)):
		title += "（未解锁）"
	lines.append(title)
	var description := String(row.get("description", ""))
	if not description.is_empty():
		lines.append(description)
	if bool(row.get("is_militia_row", false)):
		lines.append("未分配的份额自动编入民兵：不配装备，也不能单独加份额。")
	lines.append("攻 %.1f · 防 %.1f · 速 %.1f · 成军 %d 日" % [
		float(row.get("attack", 0.0)), float(row.get("defense", 0.0)),
		float(row.get("speed", 0.0)), int(row.get("training_days", 0))])
	var wage := float(row.get("wage_per_100", 0.0))
	lines.append("军饷 %s / 百人日" % ("待结算" if wage <= 0.0 else
		UITokens.format_compact_number_cn(wage, 2)))
	var supply: Array = row.get("supply", [])
	if not supply.is_empty():
		var parts := PackedStringArray()
		for chip_value in supply:
			var chip: Dictionary = chip_value
			parts.append("%s %s" % [String(chip.get("label", "")), String(chip.get("text", ""))])
		lines.append("每日供给（每百人，目录值）：" + " · ".join(parts))
	var equipment: Array = row.get("equipment", [])
	if not equipment.is_empty():
		var parts := PackedStringArray()
		for slot_value in equipment:
			var slot: Dictionary = slot_value
			parts.append("%s ≥%s" % [String(slot.get("label", "")),
				String(slot.get("quality_text", ""))])
		lines.append("装备需求：" + " · ".join(parts) + "（按市场价另购）")
	if bool(row.get("locked", false)):
		var gate := String(row.get("unlock_label", ""))
		lines.append("需先研究：%s" % (gate if not gate.is_empty() else "相关军事科技"))
	return "\n".join(lines)
