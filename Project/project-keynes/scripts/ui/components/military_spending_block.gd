extends VBoxContainer
class_name MilitarySpendingBlock

## 军事预算板块（可编辑 + 实付对账）。
##
## 两段结构，从上到下：
##  1. 预算：一条「军事总预算份额」滑条（每日国库现金份额 0..100%），下辖军饷、
##     建筑维护、装备与给养采购三条占比滑条；三者之和不得超过 100%，可拖上限
##     由本类按 `100% - 另两项` 实时收窄，玩家拖到边缘就自然停住。
##  2. 结算：三条通道各自的「预算日额 / 上一轮实付」对账行。高优先级通道
##     （军饷、维护）需求超过份额时允许超支，标铁锈红与「超支」；低优先级通道
##     （采购）永不超支，被配额截断的部分标「待购」。
##
## 语义要点：`budget_share_bp <= 0` 表示「没有信封」，不是「军费归零」。
## 那种状态下原生按现金与需求直接结算（外国 AI 与未推送政策的存档都在这条路上），
## 所以读数写「未启用 · 按现金结算」，三条通道滑条降为不可拖。
##
## 招募不在预算内（需求 6.1）：它只把同格人口转成士兵，不产生现金意图。
## 因此「招募集训」始终只是一行说明，不挂滑条。
##
## 组件只发意图：`budget_committed(total_bp, wage_bp, upkeep_bp, procurement_bp)`，
## 由宿主（财政页 → 工作区）经 PlayerController 折算成
## `military.policy.set_budget`。`-1` 表示该项本次不改。

const MilitaryEnvelopeSliderScript = preload(
	"res://scripts/ui/components/military_envelope_slider.gd")
const MilitaryChannelSliderScript = preload(
	"res://scripts/ui/components/military_channel_slider.gd")

signal budget_committed(total_bp: int, wage_bp: int, upkeep_bp: int,
	procurement_bp: int)

const CASH_SCALE := 10000.0
const VALUE_MIN_WIDTH := 104.0
const SHARE_FULL_BP := 10000

const KIND_WAGE := "wage"
const KIND_UPKEEP := "upkeep"
const KIND_PROCUREMENT := "procurement"

## 三条通道：`budget` 是预算日额字段，`paid` 是上一轮实付字段，
## `share` 是原生份额字段，`overspend` 留空表示该通道不该有超支语义。
const CHANNELS := [
	{"id": KIND_WAGE, "title": "军饷",
		"budget": "wage_budget_daily", "paid": "wage_paid_last_period",
		"demand": "wage_demand", "overspend": "wage_overspend",
		"share": "budget_wage_bp"},
	{"id": KIND_UPKEEP, "title": "建筑维护",
		"budget": "upkeep_budget_daily", "paid": "maintenance_paid_last_period",
		"demand": "upkeep_demand", "overspend": "upkeep_overspend",
		"share": "budget_upkeep_bp"},
	{"id": KIND_PROCUREMENT, "title": "装备与给养采购",
		"budget": "procurement_budget_daily", "paid": "procurement_paid_last_period",
		"demand": "", "overspend": "",
		"share": "budget_procurement_bp"},
]

const NOTE_TEXT := "招募本身不拨款：只把同格人口转为士兵，费用落在军饷与装备给养上。"
const ENVELOPE_OFF_TEXT := "军事预算未启用：军饷、维护与采购按现金与需求直接结算，不设上限。"

var _envelope = null
var _envelope_row: HBoxContainer = null
var _envelope_value: Label = null
var _empty: Label = null
var _summary: Label = null
var _train_value: Label = null
var _note: Label = null
var _channels: Dictionary = {}
var _rows: Dictionary = {}
var _built := false
var _model: Dictionary = {}
## 上一次渲染时的告警签名：只有跨越阈值才脉冲一次，之后保持静态。
var _alert_signature := ""


func _init() -> void:
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build()


## 消费 military_spending_model 的输出。available=false 时整块降级成一句占位，
## 不显示任何 0 值行（0 会被误读成"这个通道不花钱"）。
##
## `editable=false`（原生快照缺席 / 外国 AI / 只读会话）时滑条全部禁用但读数
## 仍可读；不伪造一份可拖的本地预算。
func set_state(model: Dictionary, editable := true) -> void:
	if not _built:
		_build()
	var previous_alert := _alert_signature
	_model = model
	var available := bool(model.get("available", false))
	_envelope_row.visible = available
	_envelope.visible = available
	_summary.visible = available
	_empty.visible = not available
	if not available:
		return
	var can_edit := editable
	var enabled := bool(model.get("envelope_enabled", false))
	var total_bp := _total_share_bp()
	var envelope_daily := maxi(0, int(model.get("envelope_daily", 0)))
	_envelope.set_envelope_state(total_bp, _country_cash(), can_edit,
		envelope_daily, total_bp if enabled else -1)
	for spec in CHANNELS:
		_refresh_channel(spec, can_edit, enabled, envelope_daily)
	_refresh_rows()
	_refresh_summary(enabled)
	# 阈值跨越：从"平衡"进入"超支/待购"（或反向）时脉冲一次，之后保持静态。
	_alert_signature = _compute_alert_signature()
	if not previous_alert.is_empty() and _alert_signature != previous_alert:
		_pulse_alert()


func is_available() -> bool:
	return bool(_model.get("available", false))


## 军事预算是否已启用（`budget_share_bp > 0`）。关闭时原生走旧的现金结算。
func is_envelope_enabled() -> bool:
	return bool(_model.get("envelope_enabled", false))


## 顶部军事总预算份额滑条（未构建时为 null）。
func envelope_slider():
	return _envelope


## 某条通道的占比滑条（未构建时为 null）。
func channel_slider(channel_id: String):
	var entry: Dictionary = _channels.get(channel_id, {})
	return entry.get("slider")


## 三条通道滑条当前份额之和（含玩家未提交的拖动值）。
func channel_share_total() -> int:
	var total := 0
	for spec in CHANNELS:
		var slider = channel_slider(String(spec.id))
		if slider != null:
			total += int(slider.share_bp())
	return total


## 某一行右侧显示的读数（"军饷" / "建筑维护" / "装备与给养采购"）。
func row_text(key: String) -> String:
	var entry: Dictionary = _rows.get(key, {})
	var label := entry.get("value") as Label
	return label.text if label != null else ""


## 通道状态脚注（"超支 X" / "待购 N 件" / 空串）。
func channel_note(channel_id: String) -> String:
	var entry: Dictionary = _channels.get(channel_id, {})
	var label := entry.get("note") as Label
	return label.text if label != null else ""


func training_text() -> String:
	return _train_value.text if _train_value != null else ""


func note_text() -> String:
	return _note.text if _note != null else ""


func empty_text() -> String:
	return _empty.text if _empty != null else ""


func summary_text() -> String:
	return _summary.text if _summary != null else ""


## 三行实付的日均合计（MONEY_SCALE），与板块头右上角的读数同源。
func spend_total() -> int:
	if not is_available():
		return 0
	var total := 0
	for spec in CHANNELS:
		total += maxi(0, int(_model.get(String(spec.paid), 0)))
	return total


## 三条通道预算日额合计（MONEY_SCALE）；未启用时为 0。
func budget_total() -> int:
	if not is_available() or not is_envelope_enabled():
		return 0
	var total := 0
	for spec in CHANNELS:
		total += maxi(0, int(_model.get(String(spec.budget), 0)))
	return total


func _build() -> void:
	_built = true
	_empty = Label.new()
	_empty.name = "Empty"
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.text = "军事账目尚未就绪。"
	_empty.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_empty.add_theme_font_size_override("font_size", 14)
	_empty.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	add_child(_empty)

	# ---- 预算段 -----------------------------------------------------------
	_envelope_row = HBoxContainer.new()
	_envelope_row.name = "EnvelopeHead"
	_envelope_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_envelope_row.add_theme_constant_override("separation", 8)
	add_child(_envelope_row)
	_envelope_row.add_child(_make_caption("军事预算"))
	_envelope_row.add_child(DottedLeader.new())
	_envelope_value = _make_caption("未启用")
	_envelope_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_envelope_value.custom_minimum_size = Vector2(VALUE_MIN_WIDTH, 0.0)
	_envelope_row.add_child(_envelope_value)

	_envelope = MilitaryEnvelopeSliderScript.new()
	_envelope.name = "EnvelopeSlider"
	_envelope.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_envelope.set_condensed(true)
	_envelope.share_committed.connect(_on_envelope_committed)
	add_child(_envelope)

	# 三条通道各占一个纵向小块：滑条 + 状态脚注。滑条自带份额与日额读数，
	# 脚注只写"为什么这条通道现在这样"。
	for spec in CHANNELS:
		var channel := VBoxContainer.new()
		channel.name = "Channel_%s" % String(spec.id)
		channel.mouse_filter = Control.MOUSE_FILTER_PASS
		channel.add_theme_constant_override("separation", 1)
		add_child(channel)
		var slider = MilitaryChannelSliderScript.new()
		slider.name = "Slider"
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.set_condensed(true)
		slider.configure_channel(String(spec.title), &"military.banner",
			String(spec.id))
		slider.share_committed.connect(_on_channel_committed.bind(String(spec.id)))
		channel.add_child(slider)
		var note := Label.new()
		note.name = "Note"
		note.mouse_filter = Control.MOUSE_FILTER_IGNORE
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_override("font", UITokens.dossier_font("sans"))
		note.add_theme_font_size_override("font_size", 12)
		note.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		note.visible = false
		channel.add_child(note)
		_channels[String(spec.id)] = {"slider": slider, "note": note}

	_summary = Label.new()
	_summary.name = "Summary"
	_summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_summary.add_theme_font_size_override("font_size", 13)
	_summary.add_theme_color_override("font_color", UITokens.DOSSIER_INK_SOFT)
	add_child(_summary)

	# ---- 结算段 -----------------------------------------------------------
	var divider := DottedRule.new()
	divider.name = "Divider"
	add_child(divider)

	var head := HBoxContainer.new()
	head.name = "Head"
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override("separation", 8)
	add_child(head)
	head.add_child(_make_caption("支出通道"))
	head.add_child(DottedLeader.new())
	var head_value := _make_caption("实付 · 日均")
	head_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head_value.custom_minimum_size = Vector2(VALUE_MIN_WIDTH, 0.0)
	head.add_child(head_value)

	for spec in CHANNELS:
		var entry := _make_row(String(spec.title))
		add_child(entry.row as Control)
		# 行键沿用原生字段名（`wage_paid_last_period` 等），宿主与测试按快照
		# 字段名取读数即可，不必记两套命名。
		_rows[String(spec.paid)] = entry

	var rule := DottedRule.new()
	rule.name = "TrainRule"
	add_child(rule)

	var train := _make_row("招募集训")
	_train_value = train.value as Label
	_train_value.text = "在训 0 人 · 待装备 0 件"
	add_child(train.row as Control)

	_note = Label.new()
	_note.name = "Note"
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.text = NOTE_TEXT
	_note.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_note.add_theme_font_size_override("font_size", 12)
	_note.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	add_child(_note)

	_envelope_row.visible = false
	_envelope.visible = false
	_summary.visible = false


## 军事总预算份额提交：只推总份额，三项通道传 -1（本次不改），
## 让原生按未传入项沿用当前值校验三项之和。
func _on_envelope_committed(share_bp: int) -> void:
	budget_committed.emit(int(share_bp), -1, -1, -1)


## 通道占比提交：总份额沿用当前滑条位置，另两项传 -1。
## 只推变的那一项，避免把玩家没碰过的通道钉成伪精度值。
func _on_channel_committed(share_bp: int, channel_id: String) -> void:
	var total := int(_envelope.share_bp()) if _envelope != null else -1
	var wage := -1
	var upkeep := -1
	var procurement := -1
	match channel_id:
		KIND_WAGE:
			wage = int(share_bp)
		KIND_UPKEEP:
			upkeep = int(share_bp)
		_:
			procurement = int(share_bp)
	budget_committed.emit(total, wage, upkeep, procurement)


func _refresh_channel(spec: Dictionary, can_edit: bool, enabled: bool,
		envelope_daily: int) -> void:
	var channel_id := String(spec.id)
	var entry: Dictionary = _channels.get(channel_id, {})
	var slider = entry.get("slider")
	if slider == null:
		return
	var share := clampi(int(_model.get(String(spec.share), 0)), 0, SHARE_FULL_BP)
	var others := 0
	for other in CHANNELS:
		if String(other.id) == channel_id:
			continue
		others += clampi(int(_model.get(String(other.share), 0)), 0, SHARE_FULL_BP)
	# 可拖上限 = 100% 减去另两项。未启用信封时通道没有意义，整条禁用。
	var ceiling := maxi(0, SHARE_FULL_BP - others)
	var overspend := 0
	if not String(spec.overspend).is_empty():
		overspend = maxi(0, int(_model.get(String(spec.overspend), 0)))
	var demand := 0
	if not String(spec.demand).is_empty():
		demand = maxi(0, int(_model.get(String(spec.demand), 0)))
	var deferred := 0
	if channel_id == KIND_PROCUREMENT:
		deferred = maxi(0, int(_model.get("procurement_deferred_units", 0)))
	slider.set_channel_state(share, envelope_daily, can_edit and enabled,
		ceiling, demand, overspend, deferred)
	var note := entry.get("note") as Label
	if note != null:
		_refresh_channel_note(note, channel_id, share, overspend, deferred)


## 通道脚注只写需要一句话解释的语义；单纯实付差异不重复文字。
func _refresh_channel_note(note: Label, channel_id: String, share: int,
		overspend: int, deferred: int) -> void:
	var text := ""
	var colour := UITokens.DOSSIER_INK_MUTED
	if not is_envelope_enabled():
		text = "未启用预算：该通道按现金与需求直接结算。"
	elif share <= 0:
		text = "份额为 0，该通道暂停。"
	elif overspend > 0:
		text = "需求超过份额，已紧急超支 %s（高优先级不拦截）。" % amount_text(overspend)
		colour = UITokens.RISK
	elif deferred > 0 and channel_id == KIND_PROCUREMENT:
		text = "配额用尽，尚有 %d 件待购（低优先级只截断，不透支）。" % deferred
		colour = UITokens.DOSSIER_OXBLOOD
	note.text = text
	note.visible = not text.is_empty()
	note.add_theme_color_override("font_color", colour)


func _refresh_rows() -> void:
	for spec in CHANNELS:
		var entry: Dictionary = _rows.get(String(spec.paid), {})
		if entry.is_empty():
			continue
		var paid := maxi(0, int(_model.get(String(spec.paid), 0)))
		var label := entry.value as Label
		label.text = amount_text(paid) if paid > 0 else "—"
		var overspent := false
		if not String(spec.overspend).is_empty():
			overspent = maxi(0, int(_model.get(String(spec.overspend), 0))) > 0
		var colour := UITokens.DOSSIER_INK_MUTED
		if paid > 0:
			colour = UITokens.RISK if overspent else UITokens.DOSSIER_INK
		label.add_theme_color_override("font_color", colour)
	var training := maxi(0, int(_model.get("soldiers_training", 0)))
	var waiting := maxi(0, int(_model.get("waiting_equipment", 0)))
	_train_value.text = "在训 %d 人 · 待装备 %d 件" % [training, waiting]
	_train_value.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if waiting > 0 else UITokens.DOSSIER_INK_SOFT)


func _refresh_summary(enabled: bool) -> void:
	var envelope_daily := maxi(0, int(_model.get("envelope_daily", 0)))
	if _envelope_value != null:
		_envelope_value.text = "每日 " + amount_text(envelope_daily) if enabled \
			else "未启用"
		_envelope_value.add_theme_color_override("font_color",
			UITokens.DOSSIER_OXBLOOD if enabled else UITokens.DOSSIER_INK_MUTED)
	if _summary == null:
		return
	if not enabled:
		_summary.text = ENVELOPE_OFF_TEXT
		_summary.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		return
	var parts := PackedStringArray()
	var over_total := 0
	for spec in CHANNELS:
		var budget := maxi(0, int(_model.get(String(spec.budget), 0)))
		parts.append("%s %s" % [String(spec.title), amount_text(budget)])
		if not String(spec.overspend).is_empty():
			over_total += maxi(0, int(_model.get(String(spec.overspend), 0)))
	var deferred_total := maxi(0, int(_model.get("procurement_deferred_units", 0)))
	var text := "每日信封 %s：%s" % [amount_text(envelope_daily), " · ".join(parts)]
	if over_total > 0:
		text += "。上一轮超支 %s" % amount_text(over_total)
	if deferred_total > 0:
		text += "，待购 %d 件" % deferred_total
	_summary.text = text
	_summary.add_theme_color_override("font_color",
		UITokens.RISK if over_total > 0 else UITokens.DOSSIER_INK_SOFT)


## 告警签名：只看"哪些通道在超支 / 是否还有待购"这组布尔值。
## 用布尔而不是金额，避免实付天天波动就天天脉冲。
func _compute_alert_signature() -> String:
	if not is_available():
		return ""
	var bits := PackedStringArray()
	for spec in CHANNELS:
		var over := 0
		if not String(spec.overspend).is_empty():
			over = maxi(0, int(_model.get(String(spec.overspend), 0)))
		bits.append("1" if over > 0 else "0")
	bits.append("1" if maxi(0, int(_model.get("procurement_deferred_units", 0))) > 0 else "0")
	return "".join(bits)


## 轻微高亮脉冲一次；随后保持静态。减动效偏好下直接跳过。
func _pulse_alert() -> void:
	if UIAnimation.reduced_motion():
		return
	UIAnimation.pulse(_summary, UITokens.ANIM_MED)


## 国家已提交的国库现金：信封是「现金 × 份额」，拖动时按它估算日额。
func _country_cash() -> int:
	var cash := int(_model.get("country_cash", 0))
	if cash > 0:
		return cash
	# 视图模型没带现金时用「信封额 / 份额」反推，精度足够做拖动估算。
	var envelope := maxi(0, int(_model.get("envelope_daily", 0)))
	var share := _total_share_bp()
	if envelope > 0 and share > 0:
		return int(round(float(envelope) * float(SHARE_FULL_BP) / float(share)))
	return 0


func _total_share_bp() -> int:
	return clampi(int(_model.get("budget_share_bp", 0)), 0, SHARE_FULL_BP)


func _make_caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	return label


## 一行账目：通道名、引导虚线、右对齐读数。
func _make_row(title: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % title
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	var title_label := Label.new()
	title_label.name = "Title"
	title_label.text = title
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_label.add_theme_font_override("font", UITokens.dossier_font("sans"))
	title_label.add_theme_font_size_override("font_size", 14)
	title_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_SOFT)
	row.add_child(title_label)
	row.add_child(DottedLeader.new())
	var value := Label.new()
	value.name = "Value"
	value.text = "—"
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.custom_minimum_size = Vector2(VALUE_MIN_WIDTH, 0.0)
	value.add_theme_font_override("font", UITokens.dossier_font("numeral"))
	value.add_theme_font_size_override("font_size", 15)
	value.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	row.add_child(value)
	return {"row": row, "title": title_label, "value": value}


static func amount_text(value: int) -> String:
	return UITokens.format_compact_number_cn(float(maxi(0, value)) / CASH_SCALE, 2)


## 行内引导虚线：记账本上手工打出的短划，比 HSeparator 的实线更像纸面。
class DottedLeader:
	extends Control

	func _init() -> void:
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		custom_minimum_size = Vector2(16.0, 8.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var baseline := size.y * 0.5
		var colour := Color(UITokens.DOSSIER_RULE, 0.9)
		var x := 0.0
		while x < size.x - 1.0:
			var run := minf(2.0, size.x - x)
			draw_line(Vector2(x, baseline), Vector2(x + run, baseline), colour, 1.0)
			x += 6.0


## 段落之间的分隔线：一条压得很轻的墨线，不用整块背景。
class DottedRule:
	extends Control

	func _init() -> void:
		custom_minimum_size = Vector2(0.0, 9.0)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var baseline := size.y * 0.5
		draw_line(Vector2(0.0, baseline), Vector2(size.x, baseline),
			Color(UITokens.DOSSIER_RULE, 0.5), 1.0)
