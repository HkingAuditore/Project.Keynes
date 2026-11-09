extends DossierChart

## 兵种名册：已解锁兵种的紧凑图形卡网格。
##
## 一张卡回答四个玩家问题——「这是什么兵、打得多狠、每天花多少、还差什么装备」：
##   行1  纸贴兵种图 + 中文名 + 成军天数   ·  右端 份额% 与 ±
##   行2  攻 / 防 / 速 三条迷你条（同一份可见集合内归一）+ 原值
##   行3  军饷（金币/人·日）· 供给类别图标 · 装备低品质需求
##   行4  份额轨道（余量即民兵）
##
## 全部自绘：每日刷新只重画、不重建节点树；网格列数按控件实宽重算，窄屏自动单列。

signal share_step(unit_id: String, delta_bp: int)

const CARD_HEIGHT := 104.0
const MIN_CARD_WIDTH := 292.0
const MAX_COLUMNS := 3
const GAP := 8.0
const PAD := 10.0
const ICON := 32.0
## ± 是这张卡上唯一的编制入口，22px 在 125% 缩放的 1080p 上只有手指盖大小，
## 玩家会以为整张卡不可点，所以给到 30px 并画出明确的按钮底。
const ACTION := 30.0
const ACTION_GAP := 6.0
const EMPTY_HEIGHT := 48.0
const STEP_BP := 500
const TOOLTIP_WIDTH := 392.0
const TOOLTIP_STAT_WIDTH := 116.0
## 战力卡原来 78px 里只有标签、数值和 5px 条，近半是留白。压到 46px 后
## 整张卷宗卡从约 393px 收到约 250px，一屏能同时看见名册和详情。
const TOOLTIP_STAT_HEIGHT := 46.0
## 所有 per_100 口径的数值只在展示层换算，字段名与 VM 契约保持不变。
const PER_100 := 100.0

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
## 悬停所在的禁用按钮 id（`""` = 没停在禁用按钮上）。
var _hover_disabled := ""


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
			if _hover >= 0 or not _hover_action.is_empty() or not _hover_disabled.is_empty():
				_hover = -1
				_hover_action = ""
				_hover_disabled = ""
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
	# 禁用按钮也算「悬停状态」的一部分：否则在同一张卡里横向移到禁用的 + 上时
	# hit 没变，下面的早退会把原因吞掉。
	var disabled := ""
	if hit >= 0 and action.is_empty():
		disabled = _disabled_action_at(hit, point)
	if hit == _hover and action == _hover_action and disabled == _hover_disabled:
		return
	_hover = hit
	_hover_action = action
	_hover_disabled = disabled
	if hit < 0:
		tooltip_text = ""
	elif not disabled.is_empty():
		tooltip_text = _disabled_reason(_rows[hit], disabled)
	else:
		tooltip_text = _tooltip(_rows[hit], action)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
		if hit >= 0 and not action.is_empty() else Control.CURSOR_ARROW
	queue_redraw()


## 兵种详情使用自定义卷宗卡，不走 Godot 默认的单行 TooltipPanel。
## 默认 tooltip 适合短句，无法表达「三项战力 + 成军 + 维护 + 装备」这类需要
## 分组比较的信息；这里把同一份 row 数据做成可扫描的图形化卡片。
func _make_custom_tooltip(for_text: String) -> Object:
	if _hover < 0 or _hover >= _rows.size():
		return null
	return _build_unit_tooltip(_rows[_hover], for_text, _hover_action)


func _build_unit_tooltip(row: Dictionary, fallback_text: String, action: String) -> Control:
	var panel := PanelContainer.new()
	panel.name = "MilitaryUnitTooltip"
	# 纸片皮肤由主题的 PKPaperPopup（StyleBoxTexture / torn_note）提供。
	# 绝不能再 add_theme_stylebox_override("panel", ...)：那会把撕纸边顶成
	# 圆角纯色板，跟营造提示卡、地图悬浮卡变成两套皮。
	panel.theme_type_variation = &"PKPaperPopup"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# TooltipPanel 会把返回控件放进可用屏幕区域；明确使用内容尺寸，
	# 否则 PanelContainer 的默认 FILL 会把纸片纵向拉满整个窗口。
	panel.custom_minimum_size = Vector2(TOOLTIP_WIDTH, 0.0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	# Theme 的 PaperPopup 自带 10/8 内容边距，不再叠一层 MarginContainer。
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 5)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(column)

	# 页头一行给全身份。原来页头一个「编制 25%」徽章、成本带又一个
	# 「当前编制 25%」，同一个数重复两次，还各占一行。
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 9)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(header)
	var emblem := IconBadge.new()
	emblem.custom_minimum_size = Vector2(34, 34)
	emblem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	emblem.set_icon(String(row.get("icon", "military.unit.line")),
		row.get("color", UITokens.DOSSIER_BRASS))
	header.add_child(emblem)
	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 1)
	header.add_child(identity)
	identity.add_child(_tooltip_label(String(row.get("name", "")), 18,
		UITokens.DOSSIER_INK, "sans_strong", TextServer.AUTOWRAP_OFF))
	var days := int(row.get("training_days", 0))
	var share := int(round(float(int(row.get("bp", 0))) / 100.0))
	var share_text := "未分配份额" if bool(row.get("is_militia_row", false)) else "编制"
	identity.add_child(_tooltip_label(
		"成军 %s · %s %d%%" % ["即时" if days <= 0 else "%d 日" % days, share_text, share],
		11, UITokens.DOSSIER_INK_MUTED, "sans", TextServer.AUTOWRAP_OFF))
	column.add_child(_tooltip_rule())

	# 条长只在三项之间相对比较，并排即自明；不给图形写「按什么归一」的脚注。
	# 用设计替代说明，而不是用一行实现术语去解释一个本来就不该暴露的分母。
	var attack := float(row.get("attack", 0.0))
	var defense := float(row.get("defense", 0.0))
	var speed := float(row.get("speed", 0.0))
	var top := maxf(attack, maxf(defense, speed))
	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 6)
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(stats)
	var stat_specs := [
		{"label": "攻击", "value": attack,
			"ratio": 0.0 if top <= 0.0 else attack / top, "color": UITokens.DOSSIER_OXBLOOD},
		{"label": "防御", "value": defense,
			"ratio": 0.0 if top <= 0.0 else defense / top, "color": UITokens.DOSSIER_VERDIGRIS},
		{"label": "速度", "value": speed,
			"ratio": 0.0 if top <= 0.0 else speed / top, "color": UITokens.DOSSIER_BRASS},
	]
	for spec in stat_specs:
		stats.add_child(_tooltip_stat(spec))

	# 成本一律按「每人每日」。wage_per_100 / supply.value / per_100 都是
	# 每 100 人的口径，只在展示层除以 100，VM 与原生数据契约不动。
	var wage := float(row.get("wage_per_100", 0.0))
	var wage_value := "待结算" if wage <= 0.0 else _per_person(wage) + " / 人·日"
	column.add_child(_tooltip_cost_row("军饷", wage_value, UITokens.DOSSIER_OXBLOOD))

	# 空态不渲染任何东西：没有维护物资就是没有这一节，不写「无需额外消耗」
	# 这种零信息量的套话，也不为它保留一行高度。
	var supply: Array = row.get("supply", [])
	if not supply.is_empty():
		column.add_child(_tooltip_label("维护物资 · 每人每日", 11,
			UITokens.DOSSIER_INK_MUTED, "sans_strong", TextServer.AUTOWRAP_OFF))
		for chip_value in supply:
			var chip: Dictionary = chip_value
			column.add_child(_tooltip_resource_row(String(chip.get("label", "")),
				"%s / 人·日" % _per_person(float(chip.get("value", 0.0))),
				String(chip.get("icon", "military.army.supply")), UITokens.DOSSIER_OXBLOOD))

	var equipment: Array = row.get("equipment", [])
	if not equipment.is_empty():
		# 装备是配备量（存量），不是每日流量，单位只写「每人」，不写「每日」。
		column.add_child(_tooltip_label("装备配备 · 每人", 11,
			UITokens.DOSSIER_INK_MUTED, "sans_strong", TextServer.AUTOWRAP_OFF))
		for slot_value in equipment:
			var slot: Dictionary = slot_value
			column.add_child(_tooltip_resource_row(
				"%s Q%d" % [String(slot.get("label", "")), int(slot.get("quality", 1))],
				"%s 件 / 人" % _per_person(float(slot.get("per_100", 0.0))),
				String(slot.get("icon", "military.army.supply")), UITokens.DOSSIER_UMBER))

	if bool(row.get("locked", false)):
		var gate := String(row.get("unlock_label", ""))
		column.add_child(_tooltip_label("需研究 " + (gate if not gate.is_empty() else "相关军事科技"),
			12, UITokens.DOSSIER_OXBLOOD, "sans_strong", TextServer.AUTOWRAP_OFF))
	elif not action.is_empty() or not _hover_disabled.is_empty():
		column.add_child(_tooltip_label(fallback_text, 11,
			UITokens.DOSSIER_INK_MUTED, "sans", TextServer.AUTOWRAP_OFF))
	return panel


## per_100 口径 → 每人口径，并按量级给足有效位，避免 0.0042 被 %.2f 抹成 0.00。
static func _per_person(per_100_value: float) -> String:
	var value := per_100_value / PER_100
	if value <= 0.0:
		return "0"
	if value >= 0.01:
		return UITokens.format_compact_number_cn(value, 2)
	return UITokens.format_compact_number_cn(value, 4)


## 成本行：左边名称、右边数值，一行说清，不再用两个 24px 徽章占一整行。
static func _tooltip_cost_row(label_text: String, value_text: String,
		accent: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(15, 15)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.set_icon("military.ledger.wage", accent)
	row.add_child(icon)
	var label := _tooltip_label(label_text, 12, UITokens.DOSSIER_INK,
		"sans_strong", TextServer.AUTOWRAP_OFF)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value := _tooltip_label(value_text, 13, UITokens.DOSSIER_INK,
		"sans_strong", TextServer.AUTOWRAP_OFF)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	return row


static func _tooltip_label(text: String, size: int, color: Color,
		font_kind: String = "sans",
		wrap: TextServer.AutowrapMode = TextServer.AUTOWRAP_WORD_SMART) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", UITokens.dossier_font(font_kind))
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	# 默认允许长说明折行；短标签与数值调用方必须显式关掉，否则
	# 16px 图标会把「攻击」挤成「攻 / 击」两行，右对齐数值也会掉字。
	label.autowrap_mode = wrap
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


static func _tooltip_surface_style(accent: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(accent, 0.10)
	style.border_color = Color(accent, 0.36)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	return style


static func _tooltip_stat(spec: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(TOOLTIP_STAT_WIDTH, TOOLTIP_STAT_HEIGHT)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _tooltip_surface_style(spec.color))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 1)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(column)
	column.add_child(_tooltip_label(String(spec.label), 11,
		UITokens.DOSSIER_INK_MUTED, "sans", TextServer.AUTOWRAP_OFF))
	var value_line := HBoxContainer.new()
	value_line.add_theme_constant_override("separation", 5)
	value_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value_line.add_child(_tooltip_label("%.1f" % float(spec.value), 17,
		UITokens.DOSSIER_INK, "sans_strong", TextServer.AUTOWRAP_OFF))
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.max_value = 1.0
	bar.value = clampf(float(spec.ratio), 0.0, 1.0)
	bar.custom_minimum_size = Vector2(34.0, 5.0)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = UITokens.DOSSIER_TRACK
	bg.set_corner_radius_all(3)
	var fill := StyleBoxFlat.new()
	fill.bg_color = spec.color
	fill.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	value_line.add_child(bar)
	column.add_child(value_line)
	return card


static func _tooltip_section_title(text: String, icon_key: StringName) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_theme_constant_override("separation", 6)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(16, 16)
	icon.set_icon(String(icon_key), UITokens.DOSSIER_UMBER)
	line.add_child(icon)
	var title := _tooltip_label(text, 12, UITokens.DOSSIER_INK_MUTED, "sans_strong")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.custom_minimum_size.x = 120.0
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	line.add_child(title)
	return line


static func _tooltip_resource_row(label_text: String, value_text: String,
		icon_key: String, accent: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 7)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(15, 15)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.set_icon(icon_key, accent)
	row.add_child(icon)
	var label := _tooltip_label(label_text, 12, UITokens.DOSSIER_INK,
		"sans", TextServer.AUTOWRAP_OFF)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value := _tooltip_label(value_text, 12, UITokens.DOSSIER_INK,
		"sans_strong", TextServer.AUTOWRAP_OFF)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.custom_minimum_size.x = 96.0
	row.add_child(value)
	return row


static func _tooltip_rule() -> HSeparator:
	var rule := HSeparator.new()
	rule.add_theme_constant_override("separation", 4)
	rule.add_theme_color_override("separator", UITokens.DOSSIER_RULE)
	return rule


## 落在按钮矩形内但当前禁用时返回按钮 id（`_action_at` 只回报可点的那些）。
func _disabled_action_at(index: int, point: Vector2) -> String:
	for entry in _action_rects(index):
		if bool(entry.get("enabled", true)):
			continue
		if (entry.rect as Rect2).has_point(point):
			return String(entry.id)
	return ""


func _disabled_reason(row: Dictionary, action: String) -> String:
	if bool(row.get("locked", false)):
		var gate := String(row.get("unlock_label", ""))
		return "需研究 %s 才能编入" % (gate if not gate.is_empty() else "相关军事科技")
	if action == "raise":
		return "编制份额已占满 100%：先从其它兵种调低，才有余量加到这里"
	return "%s 当前没有份额" % String(row.get("name", ""))


func _action_rects(index: int) -> Array:
	if index < 0 or index >= _rects.size():
		return []
	var row: Dictionary = _rows[index]
	# 民兵吃的是「没分配掉的份额」，不是可配置的编制：没有 ±。
	if bool(row.get("is_militia_row", false)):
		return []
	var rect: Rect2 = _rects[index]
	var locked := bool(row.get("locked", false))
	var bp := int(row.get("bp", 0))
	# 份额合计满 10000 时再加也没有余量：`unit_share_rows` 的 can_raise 已经算过
	# 这一条，但仍要保证「已满」不会画成一个能点的 +（点了 target==current，
	# 命令根本不会发出，玩家只会觉得按钮坏了）。
	var can_raise := not locked and bool(row.get("can_raise", true))
	var can_lower := bp > 0
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
	# 一行三段，每段「图标 + 数值」紧跟一条细度量条。数值是绝对读数，
	# 条只是在同一份可见集合内归一，供快速比较；不再印重复说明。
	var stats_top := rect.position.y + 44.0
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
	var chips_baseline := rect.position.y + 74.0
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
		var glyph := "+" if id == "raise" else "−"
		if not bool(entry.get("enabled", true)):
			draw_rect(rect, Color(UITokens.DOSSIER_PAPER_DEEP, 0.30))
			draw_rect(rect, Color(UITokens.DOSSIER_RULE, 0.45), false, 1.0)
			_text(Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5 + 6.0),
				glyph, 16, Color(UITokens.DOSSIER_INK_MUTED, 0.40),
				"sans_strong", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)
			continue
		var active := id == _hover_action and _hover >= 0
		draw_rect(rect, UITokens.DOSSIER_BRASS if active
			else Color(UITokens.DOSSIER_PAPER, 0.85))
		draw_rect(rect, UITokens.DOSSIER_BRASS if active
			else Color(UITokens.DOSSIER_RULE, 0.75), false, 1.0)
		_text(Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5 + 6.0),
			glyph, 16,
			UITokens.DOSSIER_PAPER_DEEP if active else UITokens.DOSSIER_INK,
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


## 军饷：金币 + 「/人·日」。经济尚未发布时写「待结算」，绝不印 0 金币。
func _draw_wage(left: float, baseline: float, row: Dictionary, locked: bool) -> float:
	var wage := float(row.get("wage_per_100", 0.0))
	var ui_alpha := 0.45 if locked else 1.0
	if wage <= 0.0:
		_text(Vector2(left, baseline), "军饷待结算", 11,
			Color(UITokens.DOSSIER_INK_MUTED, ui_alpha))
		return left + _text_width("军饷待结算", 11) + 10.0
	var per_person := wage / PER_100
	var text := UITokens.format_compact_number_cn(per_person,
		2 if per_person < 10.0 and absf(per_person - roundf(per_person)) > 0.005 else 0)
	var width := _money_text(Vector2(left, baseline), text, 12,
		Color(UITokens.DOSSIER_INK, ui_alpha), "sans_strong")
	var unit := "/人·日"
	_text(Vector2(left + width + 1.0, baseline), unit, 10,
		Color(UITokens.DOSSIER_INK_MUTED, ui_alpha))
	return left + width + _text_width(unit, 10) + 10.0


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
		return "%s 编制 +5%%" % String(row.get("name", ""))
	if action == "lower":
		return "%s 编制 −5%%" % String(row.get("name", ""))
	var lines := PackedStringArray()
	var title := String(row.get("name", ""))
	if bool(row.get("locked", false)):
		title += "（未解锁）"
	lines.append(title)
	# 只给数值：玩家已经在卡片上读过这一行，tooltip 不再复述兵种是什么。
	lines.append("攻 %.1f　防 %.1f　速 %.1f" % [
		float(row.get("attack", 0.0)), float(row.get("defense", 0.0)),
		float(row.get("speed", 0.0))])
	var days := int(row.get("training_days", 0))
	lines.append("成军 %s" % ("%d 日" % days if days > 0 else "即时"))
	# 民兵吃的是剩余份额；其它兵种给出当前份额与本次可调整的手感提示。
	if bool(row.get("is_militia_row", false)):
		lines.append("份额 %.0f%%（未分配部分）" % (float(int(row.get("bp", 0))) / 100.0))
	else:
		lines.append("份额 %.0f%%" % (float(int(row.get("bp", 0))) / 100.0))
	var wage := float(row.get("wage_per_100", 0.0))
	lines.append("军饷 " + ("待结算" if wage <= 0.0
		else _per_person(wage) + " / 人·日"))
	# 没有维护物资就不写这一节：纯文本 fallback 同样不印「不计 / 无需」套话。
	var supply: Array = row.get("supply", [])
	if not supply.is_empty():
		var parts := PackedStringArray()
		for chip_value in supply:
			var chip: Dictionary = chip_value
			parts.append("%s %s" % [String(chip.get("label", "")),
				_per_person(float(chip.get("value", 0.0)))])
		lines.append("维护物资（每人每日 / 人·日）")
		lines.append("　" + "　".join(parts))
	var equipment: Array = row.get("equipment", [])
	if not equipment.is_empty():
		lines.append("装备配备（每人）")
		for slot_value in equipment:
			var slot: Dictionary = slot_value
			var per_100 := float(slot.get("per_100", 0.0))
			lines.append("　%s Q%d　每人 %s 件" % [
				String(slot.get("label", "")), int(slot.get("quality", 1)),
				_per_person(per_100)])
	if bool(row.get("locked", false)):
		var gate := String(row.get("unlock_label", ""))
		lines.append("需研究 " + (gate if not gate.is_empty() else "相关军事科技"))
	return "\n".join(lines)
