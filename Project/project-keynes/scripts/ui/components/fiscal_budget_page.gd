extends Control
class_name FiscalBudgetPage

## 财政预算页：把所有可调的国家支出通道收在一张卷宗里。
##
## 页面本身只负责分区与滚动；每个分区是一张撕边纸（BudgetSection），
## 内部控件由后续接入的份额滑条填充。分区只在页签切换时重建一次，
## 每日 tick 走 refresh_live()，只改读数文本，不动节点树——这样快进时
## 玩家手里的滑条不会被销毁重建。

signal status_changed(text: String, warn: bool)
## 国家购买份额提交意图：由工作区统一经 PlayerController 提交，财政页不直接下命令。
## era / colonization 传 -1 表示"沿用原生自动分配"，本次不改写该通道。
signal procurement_committed(treasury_share_bp: int, research_share_bp: int,
	era_share_bp: int, colonization_share_bp: int)
## 军事预算提交意图：`-1` 表示该项本次不改（原生按未传入项沿用当前值校验
## 三项份额之和）。与 procurement_committed 一样只发意图，不下命令。
signal military_budget_committed(total_bp: int, wage_bp: int, upkeep_bp: int,
	procurement_bp: int)

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const BudgetSectionScript = preload("res://scripts/ui/components/budget_section.gd")
const NationalProcurementSliderScript = preload(
	"res://scripts/ui/components/national_procurement_slider.gd")
const ChannelShareSliderScript = preload(
	"res://scripts/ui/components/channel_share_slider.gd")
const MilitarySpendingBlockScript = preload(
	"res://scripts/ui/components/military_spending_block.gd")

const SECTION_NATIONAL := "national"
const SECTION_TECHNOLOGY := "technology"
const SECTION_ERA := "era"
const SECTION_COLONIZATION := "colonization"
const SECTION_MILITARY := "military"
const SECTION_ORDER := [SECTION_NATIONAL, SECTION_TECHNOLOGY, SECTION_ERA,
	SECTION_COLONIZATION, SECTION_MILITARY]

const SECTION_META := {
	"national": {"title": "国家购买总额", "icon": &"metric.treasury",
		"tone": UITokens.DOSSIER_BRASS,
		"note": "每日从国库现金拨出，供科技、时代晋升与派遣共同使用"},
	"technology": {"title": "科技", "icon": &"metric.technology",
		"tone": UITokens.DOSSIER_SLATE, "note": "国家购买中投向科技值采购的份额"},
	"era": {"title": "时代收购", "icon": &"system.clock",
		"tone": UITokens.DOSSIER_UMBER, "note": "升级时代所需物资的收购份额"},
	"colonization": {"title": "开拓", "icon": &"metric.territory",
		"tone": UITokens.DOSSIER_VERDIGRIS, "note": "派遣储备，供新地块开拓使用"},
	"military": {"title": "军事", "icon": &"military.banner",
		"tone": UITokens.DOSSIER_OXBLOOD,
		"note": "招募本身不拨款；花销落在军饷、维护与装备给养"},
}

const PAD_X := 2.0
const PAD_TOP := 2.0
const PAD_BOTTOM := 8.0

var _scroll: ScrollContainer = null
var _column: VBoxContainer = null
var _sections: Dictionary = {}
var _model: Dictionary = {}
var _built := false
var _compact := false
## 国家购买滑条：财政页顶部的第一块，宿主经 PlayerController 提交政策。
var _national_slider: Control = null
## 时代收购 / 开拓 两条通道份额滑条（满量程为国家购买总额的 100%）。
var _era_slider: Control = null
var _colonization_slider: Control = null
## 军事只读实付板块（第二层接入预算信封前不可编辑）。
var _military_block: Control = null
var _player_controller = null
## 提交成功但快照尚未反映的政策，避免刷新把滑条弹回旧值。
var _local_policy: Dictionary = {}
## 军事预算的同类覆盖：密钥是原生份额字段名，值只记录玩家刚提交的那几项。
var _military_local_budget: Dictionary = {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS


func _ready() -> void:
	if _built:
		return
	_build()


func _build() -> void:
	_built = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 横向滚动关掉：撕边纸在任何宽度下都按容器宽度重画，多出来的内容只能向下排。
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(_scroll)
	var pad := MarginContainer.new()
	pad.name = "Pad"
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_left", int(PAD_X))
	pad.add_theme_constant_override("margin_top", int(PAD_TOP))
	pad.add_theme_constant_override("margin_right", int(PAD_X))
	pad.add_theme_constant_override("margin_bottom", int(PAD_BOTTOM))
	_scroll.add_child(pad)
	_column = VBoxContainer.new()
	_column.name = "Sections"
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_column.add_theme_constant_override("separation", 10)
	pad.add_child(_column)


## 注入玩家会话：财政页自身不提交命令，只把滑条意图转成信号交给工作区。
func set_player_controller(controller) -> void:
	_player_controller = controller


## 提交成功后的本地覆盖：让滑条在原生快照跟上之前保持玩家刚设的值。
## era/colonization 传 -1 表示该通道未被本次提交改动，不覆盖。
func set_local_policy(treasury_share_bp: int, research_share_bp: int,
		era_share_bp: int = -1, colonization_share_bp: int = -1) -> void:
	_local_policy = {
		"treasury_share_bp": treasury_share_bp,
		"research_share_bp": research_share_bp,
	}
	if era_share_bp >= 0:
		_local_policy["era_share_bp"] = era_share_bp
	if colonization_share_bp >= 0:
		_local_policy["colonization_share_bp"] = colonization_share_bp


## 财政页顶部的国家购买滑条（尚未构建时为 null）。
func national_slider() -> Control:
	return _national_slider


## 时代收购份额滑条（尚未构建时为 null）。
func era_slider() -> Control:
	return _era_slider


## 开拓（派遣储备）份额滑条（尚未构建时为 null）。
func colonization_slider() -> Control:
	return _colonization_slider


## 军事预算提交成功后调用：让滑条在原生快照跟上之前保持玩家刚设的值。
## 只覆盖本次真正提交了的项（`< 0` 的项保持原样，因为玩家没碰它）。
func set_local_military_budget(total_bp: int, wage_bp: int = -1,
		upkeep_bp: int = -1, procurement_bp: int = -1) -> void:
	if total_bp >= 0:
		_military_local_budget["budget_share_bp"] = total_bp
	if wage_bp >= 0:
		_military_local_budget["budget_wage_bp"] = wage_bp
	if upkeep_bp >= 0:
		_military_local_budget["budget_upkeep_bp"] = upkeep_bp
	if procurement_bp >= 0:
		_military_local_budget["budget_procurement_bp"] = procurement_bp


## 军事只读实付板块（尚未构建时为 null）。
func military_block() -> Control:
	return _military_block


## 页签切入时调用：按当前模型建一次分区内容。
func set_model(model: Dictionary, rebuild: bool = true) -> void:
	if not _built:
		_ready()
	_model = model
	if rebuild or _sections.is_empty():
		_rebuild_sections()
	refresh_live(model)


## 每日 tick 调用：只更新读数，不重建节点。
func refresh_live(model: Dictionary) -> void:
	_model = model
	if not _built or _sections.is_empty():
		return
	for section_id in SECTION_ORDER:
		_refresh_section_values(String(section_id))


func set_compact(compact: bool) -> void:
	if not _built:
		_ready()
	_compact = compact
	if _national_slider != null:
		# 财政页的滑条恒为紧凑版（标题由板块头承担），不随页面档位切换。
		_national_slider.set_condensed(true)
	if _era_slider != null:
		_era_slider.set_condensed(true)
	if _colonization_slider != null:
		_colonization_slider.set_condensed(true)
	# 军事板块内的滑条在构建时已固定为紧凑档（标题由板块自身承担），
	# 页面档位只影响撕纸板块容器，不再逐个下推。
	for value in _sections.values():
		((value as Dictionary).section as Control).set_condensed(compact)


func section(section_id: String) -> Control:
	var entry: Dictionary = _sections.get(section_id, {})
	return entry.get("section") as Control


func section_ids() -> Array:
	return SECTION_ORDER.duplicate()


func section_value_text(section_id: String) -> String:
	var entry: Dictionary = _sections.get(section_id, {})
	var label := entry.get("value_label") as Label
	return label.text if label != null else ""


func section_title_text(section_id: String) -> String:
	var entry: Dictionary = _sections.get(section_id, {})
	var label := entry.get("title_label") as Label
	return label.text if label != null else ""


func section_body(section_id: String) -> VBoxContainer:
	var entry: Dictionary = _sections.get(section_id, {})
	return entry.get("body") as VBoxContainer


func _rebuild_sections() -> void:
	for child in _column.get_children():
		_column.remove_child(child)
		child.queue_free()
	_sections.clear()
	_national_slider = null
	_era_slider = null
	_colonization_slider = null
	_military_block = null
	for section_id in SECTION_ORDER:
		var meta: Dictionary = SECTION_META[section_id]
		var section := BudgetSectionScript.new() as Control
		section.name = "Section_%s" % String(section_id)
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_column.add_child(section)
		section.configure(String(meta.title), meta.icon, meta.tone, String(meta.note))
		section.set_condensed(_compact)
		var entry := {
			"section": section,
			"title_label": section.title_label(),
			"value_label": section.value_label(),
			"body": section.body(),
			"signature": "",
		}
		_sections[String(section_id)] = entry
		_build_section_body(String(section_id), entry)
	_refresh_section_values(SECTION_NATIONAL)


## 各分区的正文内容。国家购买分区经由通用份额滑条承载国库总额，
## 时代收购与开拓分区各挂一条通道份额滑条（满量程为国家购买总额的 100%），
## 军事分区挂只读实付板块，科技分区先铺读数占位。
func _build_section_body(section_id: String, entry: Dictionary) -> void:
	var body := entry.body as VBoxContainer
	if body == null:
		return
	if section_id == SECTION_NATIONAL:
		_build_national_slider(body)
		return
	if section_id == SECTION_ERA or section_id == SECTION_COLONIZATION:
		_build_channel_slider(section_id, body, entry)
		return
	if section_id == SECTION_MILITARY:
		_build_military_block(body, entry)
		return
	var line := Label.new()
	line.name = "Detail"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.add_theme_font_override("font", UITokens.dossier_font("sans"))
	line.add_theme_font_size_override("font_size", 14)
	line.add_theme_color_override("font_color", UITokens.DOSSIER_INK_SOFT)
	body.add_child(line)
	entry["detail_label"] = line


func _build_national_slider(body: VBoxContainer) -> void:
	var slider := NationalProcurementSliderScript.new() as Control
	slider.name = "NationalSlider"
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 板块头已经写了标题与汇总金额，滑条这里只留读数与轨道，不再重复标题行。
	# 因此财政页内的滑条恒为紧凑版，与页面本身的紧凑档无关。
	slider.set_condensed(true)
	slider.policy_committed.connect(_on_national_committed)
	body.add_child(slider)
	_national_slider = slider


func _build_channel_slider(section_id: String, body: VBoxContainer,
		entry: Dictionary) -> void:
	var slider := ChannelShareSliderScript.new() as Control
	slider.name = "EraSlider" if section_id == SECTION_ERA else "ColonizationSlider"
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.set_condensed(true)
	slider.share_committed.connect(_on_channel_committed.bind(section_id))
	body.add_child(slider)
	if section_id == SECTION_ERA:
		_era_slider = slider
	else:
		_colonization_slider = slider
	# 说明行：暂停态、自动分配、无待办需求这些语义只有一行文字说得清。
	var line := Label.new()
	line.name = "Detail"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.add_theme_font_override("font", UITokens.dossier_font("sans"))
	line.add_theme_font_size_override("font_size", 14)
	line.add_theme_color_override("font_color", UITokens.DOSSIER_INK_SOFT)
	body.add_child(line)
	entry["detail_label"] = line


func _build_military_block(body: VBoxContainer, entry: Dictionary) -> void:
	var block := MilitarySpendingBlockScript.new() as Control
	block.name = "MilitaryBlock"
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block.budget_committed.connect(_on_military_budget_committed)
	body.add_child(block)
	_military_block = block
	# 板块头右侧的读数与板块内三行同源，说明行放周期口径，避免玩家把 30 日累计
	# 当成一天的花销。
	var line := Label.new()
	line.name = "Detail"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.add_theme_font_override("font", UITokens.dossier_font("sans"))
	line.add_theme_font_size_override("font_size", 14)
	line.add_theme_color_override("font_color", UITokens.DOSSIER_INK_SOFT)
	body.add_child(line)
	entry["detail_label"] = line


## 军事预算提交：财政页只转发意图，命令由工作区经 PlayerController 下发。
func _on_military_budget_committed(total_bp: int, wage_bp: int, upkeep_bp: int,
		procurement_bp: int) -> void:
	military_budget_committed.emit(total_bp, wage_bp, upkeep_bp, procurement_bp)


func _on_national_committed(treasury_share_bp: int) -> void:
	if _national_slider == null:
		return
	procurement_committed.emit(treasury_share_bp,
		int(_national_slider.research_share_bp()),
		int(_current_channel_share(SECTION_ERA)),
		int(_current_channel_share(SECTION_COLONIZATION)))


## 通道提交：国库/科技两项沿用当前滑条位置（本次没动），只改这一条通道。
func _on_channel_committed(share_bp: int, section_id: String) -> void:
	if _national_slider == null:
		return
	var era := int(_current_channel_share(SECTION_ERA))
	var colonization := int(_current_channel_share(SECTION_COLONIZATION))
	if section_id == SECTION_ERA:
		era = share_bp
	else:
		colonization = share_bp
	procurement_committed.emit(int(_national_slider.treasury_share_bp()),
		int(_national_slider.research_share_bp()), era, colonization)


## 某条通道滑条当前显示的份额；-1 表示该通道仍沿用原生自动分配。
func _current_channel_share(section_id: String) -> int:
	var slider := _era_slider if section_id == SECTION_ERA \
		else _colonization_slider
	if slider == null:
		return -1
	return int(slider.share_bp())


func _refresh_section_values(section_id: String) -> void:
	var entry: Dictionary = _sections.get(section_id, {})
	if entry.is_empty():
		return
	var signature := _section_signature(section_id)
	# 读数没变就不碰节点：快进时每 tick 都会进来，写同一段文字也会引起重排。
	if String(entry.get("signature", "")) == signature:
		return
	entry["signature"] = signature
	var section := entry.section as Control
	var detail := entry.get("detail_label") as Label
	match section_id:
		SECTION_NATIONAL:
			section.set_value_text(_national_value_text())
			_refresh_national_slider()
		SECTION_TECHNOLOGY:
			section.set_value_text(_share_value_text(SECTION_TECHNOLOGY))
			if detail != null:
				detail.text = _technology_detail_text()
		SECTION_ERA:
			section.set_value_text(_share_value_text(SECTION_ERA))
			_refresh_channel_sliders()
			if detail != null:
				detail.text = _era_detail_text()
		SECTION_COLONIZATION:
			section.set_value_text(_share_value_text(SECTION_COLONIZATION))
			_refresh_channel_sliders()
			if detail != null:
				detail.text = _colonization_detail_text()
		SECTION_MILITARY:
			section.set_value_text(_military_value_text())
			if _military_block != null:
				_military_block.set_state(_military_model(),
					_military_editable())
			if detail != null:
				detail.text = _military_detail_text()


func _section_signature(section_id: String) -> String:
	var procurement: Dictionary = _model.get("procurement", {})
	var treasury: Dictionary = _model.get("treasury", {})
	# 军事模型含覆盖合并与现金补项，只有军事分区需要，别在别的分区白算一遍。
	var military: Dictionary = _military_model() if section_id == SECTION_MILITARY \
		else {}
	# 通道签名要感知另外两项份额：三者互相约束可拖上限，任一变化都得重刷。
	var policy: Dictionary = _channel_policy() if section_id == SECTION_ERA \
		or section_id == SECTION_COLONIZATION else {}
	match section_id:
		SECTION_NATIONAL:
			return "n:%d:%d:%d:%d:%d:%d:%d:%d" % [
				int(procurement.get("treasury_share_bp", -1)),
				int(procurement.get("research_share_bp", -1)),
				int(procurement.get("national_daily_budget", 0)),
				int(procurement.get("research_daily_budget", 0)),
				int(procurement.get("era_daily_budget", 0)),
				int(procurement.get("colonization_daily_budget", 0)),
				int(treasury.get("cash", 0)),
				1 if bool(procurement.get("available", false)) else 0]
		SECTION_TECHNOLOGY:
			return "t:%d:%d" % [int(procurement.get("research_share_bp", -1)),
				int(procurement.get("research_daily_budget", 0))]
		SECTION_ERA:
			return "e:%d:%d:%d:%d:%d:%d" % [int(procurement.get("era_share_bp", -1)),
				int(procurement.get("era_daily_budget", 0)),
				1 if bool(procurement.get("era_active", false)) else 0,
				int(policy.research), int(policy.colonization),
				1 if bool(policy.colonization_auto) else 0]
		SECTION_COLONIZATION:
			return "c:%d:%d:%d:%d:%d" % [
				int(procurement.get("colonization_share_bp", -1)),
				int(procurement.get("colonization_daily_budget", 0)),
				int(policy.research), int(policy.era),
				1 if bool(policy.era_auto) else 0]
		SECTION_MILITARY:
			return "m:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d" % [
				int(military.get("wage_paid_last_period", 0)),
				int(military.get("maintenance_paid_last_period", 0)),
				int(military.get("procurement_paid_last_period", 0)),
				int(military.get("soldiers_training", 0)),
				int(military.get("waiting_equipment", 0)),
				1 if bool(military.get("available", false)) else 0,
				1 if bool(military.get("envelope_enabled", false)) else 0,
				int(military.get("budget_share_bp", 0)),
				int(military.get("budget_wage_bp", 0)),
				int(military.get("budget_upkeep_bp", 0)),
				int(military.get("budget_procurement_bp", 0)),
				int(military.get("envelope_daily", 0)),
				int(military.get("wage_overspend", 0)),
				int(military.get("upkeep_overspend", 0)),
				int(military.get("wage_demand", 0)),
				int(military.get("upkeep_demand", 0)),
				int(military.get("procurement_deferred_units", 0))]
	return ""


## 军事分区的模型：补一项目国库现金，供预算滑条在拖动时估算日额；
## 并叠上玩家刚提交、快照尚未反映的份额覆盖。
## 视图模型的军事段本身不含现金（它是军事快照的投影），现金在 treasury 段。
func _military_model() -> Dictionary:
	var military: Dictionary = (_model.get("military", {}) as Dictionary).duplicate()
	var treasury: Dictionary = _model.get("treasury", {})
	var cash := int(treasury.get("cash", _model.get("cash", 0)))
	if cash > 0 and not military.has("country_cash"):
		military["country_cash"] = cash
	if _military_local_budget.is_empty():
		return military
	# 快照已经反映本地提交时丢弃覆盖值，避免它一直盖住真实政策。
	var settled := true
	for key in _military_local_budget.keys():
		if int(military.get(String(key), -1)) != int(_military_local_budget[key]):
			settled = false
			break
	if settled:
		_military_local_budget.clear()
		return military
	for key in _military_local_budget.keys():
		military[String(key)] = int(_military_local_budget[key])
	# 覆盖了总份额就同时改判「是否启用」：拖到 0 应立刻显示未启用，
	# 而不是等快照回来才从血红色褪成灰色。
	if _military_local_budget.has("budget_share_bp"):
		military["envelope_enabled"] = int(_military_local_budget["budget_share_bp"]) > 0
	return military


## 军事预算是否可编辑：需要玩家会话（命令要有出口）与可用快照。
## 原生 DLL 缺席时快照 itself 会 available=false，此时整块已是占位态。
func _military_editable() -> bool:
	if _player_controller == null:
		return false
	if not _player_controller.has_method("request_command"):
		return false
	return bool((_model.get("military", {}) as Dictionary).get("available", false))


func _procurement_enabled() -> bool:
	var procurement: Dictionary = _model.get("procurement", {})
	if not bool(_model.get("available", false)):
		return false
	if procurement.has("policy_enabled"):
		return bool(procurement.get("policy_enabled", false))
	return int(procurement.get("treasury_share_bp", 0)) > 0


## 把当前模型推给国家购买滑条：政策优先取玩家会话，其次本地覆盖，再其次快照。
func _refresh_national_slider() -> void:
	if _national_slider == null:
		return
	var procurement: Dictionary = _model.get("procurement", {})
	var policy: Dictionary = NationalProcurementSliderScript.resolve_policy(
		_player_controller, procurement, _local_policy)
	# 会话或快照已经反映本地提交后，丢弃本地覆盖值，避免它一直盖住真实政策。
	if not _local_policy.is_empty() and String(policy.get("source", "")) != "local":
		_local_policy.clear()
	var treasury: Dictionary = _model.get("treasury", {})
	var cash := int(treasury.get("cash", _model.get("cash", 0)))
	# 原生快照缺席时仍可拖：日额按国库现金估算，滑条照常工作，只是分项实付不显示。
	_national_slider.set_state(int(policy.get("treasury_share_bp", 0)),
		int(policy.get("research_share_bp", 5000)), cash, procurement,
		bool(_model.get("available", false)))


func _national_value_text() -> String:
	var procurement: Dictionary = _model.get("procurement", {})
	if not bool(_model.get("available", false)):
		return "暂不可用"
	if not _procurement_enabled():
		return "已关闭"
	return _money(int(procurement.get("national_daily_budget", 0))) + "/日"


## 三项份额（科技 / 时代收购 / 开拓）解析后的统一视图。
## 三者基数相同（国家购买总额 national_daily），pct 一律落在 0..10000；
## auto_* 标记该通道仍沿用原生自动分配。
func _channel_policy() -> Dictionary:
	var procurement: Dictionary = _model.get("procurement", {})
	var policy: Dictionary = NationalProcurementSliderScript.resolve_policy(
		_player_controller, procurement, _local_policy)
	var research := clampi(int(policy.get("research_share_bp", 5000)), 0, 10000)
	var era := int(policy.get("era_share_bp", -1))
	var colonization := int(policy.get("colonization_share_bp", -1))
	# 自动分配时用快照里的实际日额反推占比，让滑条落在真实位置上。
	var base := _national_daily_budget()
	var era_auto := era < 0
	var colonization_auto := colonization < 0
	if era_auto:
		era = _derive_share(int(procurement.get("era_daily_budget", 0)), base)
	if colonization_auto:
		colonization = _derive_share(
			int(procurement.get("colonization_daily_budget", 0)), base)
	# 三项之和不得超过 100%：上限按"扣掉科技 + 另一条通道已手动定下的份额"算，
	# 自动通道不占额度，避免一拖动就顺手把自动通道钉成固定值。
	var era_ceiling := maxi(0, 10000 - research
		- (0 if colonization_auto else clampi(colonization, 0, 10000)))
	var colonization_ceiling := maxi(0, 10000 - research
		- (0 if era_auto else clampi(era, 0, 10000)))
	return {
		"research": research,
		"era": clampi(era, 0, 10000),
		"colonization": clampi(colonization, 0, 10000),
		"era_auto": era_auto,
		"colonization_auto": colonization_auto,
		"era_ceiling": era_ceiling,
		"colonization_ceiling": colonization_ceiling,
		"base_daily": base,
		"all_paused": research <= 0 and era <= 0 and colonization <= 0,
	}


## 国家购买每日总额（MONEY_SCALE）；快照缺席时按国库现金 × 国库份额估算。
func _national_daily_budget() -> int:
	if not _procurement_enabled():
		return 0
	var procurement: Dictionary = _model.get("procurement", {})
	var frozen := int(procurement.get("national_daily_budget", 0))
	if frozen > 0:
		return frozen
	var treasury: Dictionary = _model.get("treasury", {})
	var cash := maxi(0, int(treasury.get("cash", _model.get("cash", 0))))
	var treasury_share := int(NationalProcurementSliderScript.resolve_policy(
		_player_controller, procurement, _local_policy).get("treasury_share_bp", 0))
	return int(round(float(cash) * float(clampi(treasury_share, 0, 1000)) / 10000.0))


static func _derive_share(daily: int, base: int) -> int:
	if base <= 0 or daily <= 0:
		return 0
	return clampi(int(round(float(daily) * 10000.0 / float(base))), 0, 10000)


## 把份额推给两条通道滑条：可拖上限随其余两项实时收窄，拖到底就停在剩余额度上。
func _refresh_channel_sliders() -> void:
	var policy := _channel_policy()
	var interactive := bool(_model.get("available", false)) and _procurement_enabled()
	var procurement: Dictionary = _model.get("procurement", {})
	var era_active := bool(procurement.get("era_active", false))
	if _era_slider != null:
		_era_slider.set_channel_state(int(policy.era), int(policy.base_daily),
			era_active, interactive, int(policy.era_ceiling), bool(policy.era_auto))
	if _colonization_slider != null:
		# 开拓通道恒有需求（派遣储备不会因为没有目标就停摆）。
		_colonization_slider.set_channel_state(int(policy.colonization),
			int(policy.base_daily), true, interactive,
			int(policy.colonization_ceiling), bool(policy.colonization_auto))


func _share_value_text(section_id: String) -> String:
	if not bool(_model.get("available", false)):
		return "暂不可用"
	if not _procurement_enabled():
		return "暂停"
	if section_id == SECTION_TECHNOLOGY:
		return _percent(int(_channel_policy().research))
	var policy := _channel_policy()
	if bool(policy.all_paused):
		return "全部暂停"
	if section_id == SECTION_ERA:
		return _percent(int(policy.era))
	return _percent(int(policy.colonization))


func _technology_detail_text() -> String:
	var procurement: Dictionary = _model.get("procurement", {})
	if not bool(_model.get("available", false)):
		return "科技采购预算随国库账目一起待命。"
	if not _procurement_enabled():
		return "国家购买已关闭，科技值暂不采购。"
	return "每日 %s 用于科技值采购" % _money(
		int(procurement.get("research_daily_budget", 0)))


func _era_detail_text() -> String:
	if not bool(_model.get("available", false)):
		return "时代收购预算随国库账目一起待命。"
	if not _procurement_enabled():
		return "国家购买已关闭，时代收购暂停。"
	var policy := _channel_policy()
	if bool(policy.all_paused):
		return "科技、时代收购与开拓份额均为 0，三条通道全部暂停采购。"
	if not bool((_model.get("procurement", {}) as Dictionary).get("era_active", false)):
		return "当前没有待收购的时代物资，份额先记在这里，有待收购项目时生效。"
	if int(policy.era) <= 0:
		return "时代收购份额为 0，即使有需求也不采购。"
	var suffix := "（自动分配）" if bool(policy.era_auto) else ""
	return "每日 %s 用于升级时代物资%s" % [_money(
		int((_model.get("procurement", {}) as Dictionary).get("era_daily_budget", 0))),
		suffix]


func _colonization_detail_text() -> String:
	if not bool(_model.get("available", false)):
		return "开拓储备随国库账目一起待命。"
	if not _procurement_enabled():
		return "国家购买已关闭，开拓派遣暂停。"
	var policy := _channel_policy()
	if bool(policy.all_paused):
		return "科技、时代收购与开拓份额均为 0，三条通道全部暂停采购。"
	if int(policy.colonization) <= 0:
		return "开拓份额为 0，派遣储备不再补充。"
	var suffix := "（自动分配）" if bool(policy.colonization_auto) else ""
	return "每日 %s 作为派遣储备%s" % [_money(
		int((_model.get("procurement", {}) as Dictionary).get(
			"colonization_daily_budget", 0))), suffix]


func _military_value_text() -> String:
	var military: Dictionary = _model.get("military", {})
	if not bool(military.get("available", false)):
		return "暂不可用"
	if bool(military.get("envelope_enabled", false)):
		return _money(int(military.get("envelope_daily", 0))) + "/日"
	var total := int(military.get("wage_paid_last_period", 0)) \
		+ int(military.get("maintenance_paid_last_period", 0)) \
		+ int(military.get("procurement_paid_last_period", 0))
	return _money(total) + "/日"


func _military_detail_text() -> String:
	var military: Dictionary = _model.get("military", {})
	if not bool(military.get("available", false)):
		return "军事账目尚未就绪。"
	if not bool(military.get("envelope_enabled", false)):
		return "军事预算未启用，花销按现金与需求直接结算；启用后可按份额封顶。"
	var days := maxi(1, int(military.get("window_days", 30)))
	return "每日信封 %s（军饷 %s · 维护 %s · 采购 %s）；近 %d 日实付折日均 %s" % [
		_money(int(military.get("envelope_daily", 0))),
		_money(maxi(0, int(military.get("wage_budget_daily", 0)))),
		_money(maxi(0, int(military.get("upkeep_budget_daily", 0)))),
		_money(maxi(0, int(military.get("procurement_budget_daily", 0)))),
		days,
		_money(int(military.get("wage_paid_last_period", 0))
			+ int(military.get("maintenance_paid_last_period", 0))
			+ int(military.get("procurement_paid_last_period", 0)))]


func _money(value: int) -> String:
	return UITokens.format_compact_number_cn(float(maxi(0, value)) / 10000.0, 2)


func _percent(basis_points: int) -> String:
	return "%.1f%%" % (float(clampi(basis_points, 0, 10000)) / 100.0)
