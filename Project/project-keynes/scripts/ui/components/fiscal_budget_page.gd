extends Control
class_name FiscalBudgetPage

## 财政预算卷宗：所有可调的国家支出通道收在一张卷宗里，直接挂在国库页。
##
## 版面分三层，都是为了把「两个额度池」讲清楚：
##  1. 顶部固定纸带（BudgetRibbon）：国家购买每日总额、共同的 100% 分配带、
##     军事独立信封。滚动分区时它不跟着走，玩家随时能看到还剩多少额度。
##  2. 左栏「共同额度」：国库份额 + 科技 / 时代收购 / 开拓三条滑条，三者之和
##     不得超过 100%，可拖上限互相收窄。
##  3. 右栏「独立信封」：军事预算板块与口径说明便笺。
##
## 页面只发意图，不经手命令；分区只在首次构建时生成，每日 tick 走
## refresh_live() 只改读数文本，玩家手里的滑条不会被销毁重建。

signal status_changed(text: String, warn: bool)
## 国家购买份额提交意图：由工作区统一经 PlayerController 提交，财政页不直接下命令。
## era / colonization 传 -1 表示"沿用原生自动分配"，本次不改写该通道。
signal procurement_committed(treasury_share_bp: int, research_share_bp: int,
	era_share_bp: int, colonization_share_bp: int)
## 军事预算提交意图：`-1` 表示该项本次不改。
signal military_budget_committed(total_bp: int, wage_bp: int, upkeep_bp: int,
	procurement_bp: int)

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const BudgetSectionScript = preload("res://scripts/ui/components/budget_section.gd")
const BudgetRibbonScript = preload("res://scripts/ui/components/budget_ribbon.gd")
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
const POOL_SECTIONS := [SECTION_NATIONAL, SECTION_TECHNOLOGY,
	SECTION_ERA, SECTION_COLONIZATION]

const SECTION_META := {
	"national": {"title": "国家购买总额", "icon": &"metric.treasury",
		"tone": UITokens.DOSSIER_BRASS,
		"note": "每日从国库现金拨出，供科技、时代晋升与派遣共同使用"},
	"technology": {"title": "科技", "icon": &"metric.technology",
		"tone": UITokens.DOSSIER_SLATE, "note": "共同额度中投向科技值采购的份额"},
	"era": {"title": "时代收购", "icon": &"system.clock",
		"tone": UITokens.DOSSIER_UMBER, "note": "升级时代所需物资的收购份额"},
	"colonization": {"title": "开拓", "icon": &"metric.territory",
		"tone": UITokens.DOSSIER_VERDIGRIS, "note": "派遣储备，供新地块开拓使用"},
	"military": {"title": "军事", "icon": &"military.banner",
		"tone": UITokens.DOSSIER_OXBLOOD,
		"note": "招募本身不拨款；花销落在军饷、维护与装备给养"},
}
const POOL_TAG_TEXT := "共同额度 · 科技 / 时代收购 / 开拓 合计 100%"
const MILITARY_TAG_TEXT := "独立信封 · 军饷 / 维护 / 装备给养"
## 「两个池互不相加」直接画在顶部纸带的分栏与右列脚注里，不再另占一张纸：
## 右栏军事板块本身就已经很高，再挂便笺会把四条共同额度挤回首屏之外。

const PAD_X := 2.0
const PAD_TOP := 2.0
const PAD_BOTTOM := 8.0
const COLUMN_SEPARATION := 12.0

var _root: VBoxContainer = null
var _ribbon: Control = null
var _scroll: ScrollContainer = null
var _columns: HBoxContainer = null
var _pool_group: VBoxContainer = null
## 共同额度四块撕纸排成 2×2：桌面一屏能同时看到四条滑条，窄屏退回单列。
var _pool_grid: GridContainer = null
var _military_group: VBoxContainer = null
var _sections: Dictionary = {}
var _model: Dictionary = {}
var _built := false
var _compact := false
var _ribbon_signature := ""
## 国家购买滑条：共同额度池的总闸门。
var _national_slider: Control = null
## 科技 / 时代收购 / 开拓 三条通道份额滑条，共享同一个 100% 池。
var _technology_slider: Control = null
var _era_slider: Control = null
var _colonization_slider: Control = null
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
	_root = VBoxContainer.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_PASS
	_root.add_theme_constant_override("separation", 6)
	add_child(_root)
	_ribbon = BudgetRibbonScript.new() as Control
	_ribbon.name = "Ribbon"
	_root.add_child(_ribbon)
	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 横向滚动关掉：撕边纸在任何宽度下都按容器宽度重画。
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_root.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.name = "Pad"
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_left", int(PAD_X))
	pad.add_theme_constant_override("margin_top", int(PAD_TOP))
	pad.add_theme_constant_override("margin_right", int(PAD_X))
	pad.add_theme_constant_override("margin_bottom", int(PAD_BOTTOM))
	_scroll.add_child(pad)
	_columns = HBoxContainer.new()
	_columns.name = "Columns"
	_columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_columns.add_theme_constant_override("separation", int(COLUMN_SEPARATION))
	pad.add_child(_columns)


## 注入玩家会话：财政页自身不提交命令，只把滑条意图转成信号交给工作区。
func set_player_controller(controller) -> void:
	_player_controller = controller


## 提交成功后的本地覆盖：让滑条在原生快照跟上之前保持玩家刚设的值。
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


## 命令提交失败时清掉乐观覆盖，让刷新把滑条退回原生真实政策。
func clear_local_policy() -> void:
	_local_policy.clear()
	_ribbon_signature = ""


func national_slider() -> Control:
	return _national_slider


## 科技份额滑条（尚未构建时为 null）。
func technology_slider() -> Control:
	return _technology_slider


func era_slider() -> Control:
	return _era_slider


func colonization_slider() -> Control:
	return _colonization_slider


func ribbon() -> Control:
	return _ribbon


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
	_refresh_ribbon()


func set_compact(compact: bool) -> void:
	if not _built:
		_ready()
	_compact = compact
	# 财政页的滑条恒为紧凑版（标题由板块头承担），不随页面档位切换。
	for slider in [_national_slider, _technology_slider, _era_slider,
			_colonization_slider]:
		if slider != null:
			slider.set_condensed(true)
	for value in _sections.values():
		((value as Dictionary).section as Control).set_condensed(compact)
	_apply_columns_layout()


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
	for child in _columns.get_children():
		_columns.remove_child(child)
		child.queue_free()
	_sections.clear()
	_national_slider = null
	_technology_slider = null
	_era_slider = null
	_colonization_slider = null
	_military_block = null
	_pool_grid = null
	_pool_group = _make_group("PoolGroup", POOL_TAG_TEXT, UITokens.DOSSIER_BRASS, true)
	_military_group = _make_group("MilitaryGroup", MILITARY_TAG_TEXT,
		UITokens.DOSSIER_OXBLOOD, false)
	for section_id in SECTION_ORDER:
		var meta: Dictionary = SECTION_META[section_id]
		var section := BudgetSectionScript.new() as Control
		section.name = "Section_%s" % String(section_id)
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.custom_minimum_size = Vector2(220.0, 0.0)
		_group_for(String(section_id)).add_child(section)
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
	_apply_columns_layout()
	_wire_focus_chain()
	_refresh_section_values(SECTION_NATIONAL)


func _make_group(name: String, tag_text: String, tone: Color,
		with_grid: bool) -> VBoxContainer:
	var group := VBoxContainer.new()
	group.name = name
	group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group.add_theme_constant_override("separation", 8)
	_columns.add_child(group)
	var tag := BudgetRibbonScript.GroupTag.new() as Control
	tag.name = "GroupTag"
	tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag.configure(tag_text, tone)
	group.add_child(tag)
	if with_grid:
		_pool_grid = GridContainer.new()
		_pool_grid.name = "PoolGrid"
		_pool_grid.columns = 2
		_pool_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_pool_grid.add_theme_constant_override("h_separation", 8)
		_pool_grid.add_theme_constant_override("v_separation", 8)
		group.add_child(_pool_grid)
	return group


func _group_for(section_id: String) -> Control:
	return _pool_grid if POOL_SECTIONS.has(section_id) else _military_group


func _apply_columns_layout() -> void:
	if _pool_group == null or _military_group == null:
		return
	# 宽屏左栏更宽：四条滑条要能一眼扫完；窄屏收敛成接近等比，避免右栏被挤爆。
	_pool_group.size_flags_stretch_ratio = 3.0 if not _compact else 1.5
	_military_group.size_flags_stretch_ratio = 2.0 if not _compact else 1.0
	if _pool_grid != null:
		_pool_grid.columns = 2 if not _compact else 1


## 键盘 / 手柄：四条滑条串成一条纵向链，Tab 与方向键都沿版面顺序走。
func _wire_focus_chain() -> void:
	var chain: Array = []
	for slider in [_national_slider, _technology_slider, _era_slider,
			_colonization_slider]:
		if slider != null:
			chain.append(slider)
	# focus_neighbor_* 存的是 NodePath，节点必须已在树里；测试里 set_model
	# 会赶在首帧布局之前调用，此时退回 Godot 的自动空间邻居即可。
	for item in chain:
		if not (item as Control).is_inside_tree():
			return
	for index in range(chain.size()):
		var control := chain[index] as Control
		if index > 0:
			control.focus_neighbor_top = (chain[index - 1] as Control).get_path()
		if index < chain.size() - 1:
			control.focus_neighbor_bottom = (chain[index + 1] as Control).get_path()


## 各分区正文：共同额度池里每条通道挂一条份额滑条；军事挂预算板块；
## 每个分区底下留一行小字说明特殊状态（暂停 / 自动分配 / 无待办需求）。
func _build_section_body(section_id: String, entry: Dictionary) -> void:
	var body := entry.body as VBoxContainer
	if body == null:
		return
	if section_id == SECTION_NATIONAL:
		_build_national_slider(body)
		return
	if section_id in [SECTION_TECHNOLOGY, SECTION_ERA, SECTION_COLONIZATION]:
		_build_channel_slider(section_id, body, entry)
		return
	if section_id == SECTION_MILITARY:
		_build_military_block(body, entry)
		return


func _build_national_slider(body: VBoxContainer) -> void:
	var slider := NationalProcurementSliderScript.new() as Control
	slider.name = "NationalSlider"
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.set_condensed(true)
	slider.policy_committed.connect(_on_national_committed)
	body.add_child(slider)
	_national_slider = slider


func _build_channel_slider(section_id: String, body: VBoxContainer,
		entry: Dictionary) -> void:
	var slider := ChannelShareSliderScript.new() as Control
	slider.name = "%sSlider" % String(section_id).capitalize()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.set_condensed(true)
	match section_id:
		SECTION_TECHNOLOGY:
			slider.configure_channel("科技份额", &"metric.technology")
			_technology_slider = slider
			slider.share_committed.connect(_on_technology_committed)
		SECTION_ERA:
			slider.configure_channel("时代收购份额", &"system.clock")
			_era_slider = slider
			slider.share_committed.connect(_on_channel_committed.bind(section_id))
		_:
			slider.configure_channel("开拓份额", &"metric.territory")
			_colonization_slider = slider
			slider.share_committed.connect(_on_channel_committed.bind(section_id))
	body.add_child(slider)
	_add_detail_label(body, entry)


func _build_military_block(body: VBoxContainer, entry: Dictionary) -> void:
	var block := MilitarySpendingBlockScript.new() as Control
	block.name = "MilitaryBlock"
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	block.budget_committed.connect(_on_military_budget_committed)
	body.add_child(block)
	_military_block = block
	_add_detail_label(body, entry)


func _add_detail_label(body: VBoxContainer, entry: Dictionary) -> void:
	var line := Label.new()
	line.name = "Detail"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line.add_theme_font_override("font", UITokens.dossier_font("sans"))
	line.add_theme_font_size_override("font_size", 12)
	line.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	body.add_child(line)
	entry["detail_label"] = line


## 军事预算提交：财政页只转发意图，命令由工作区经 PlayerController 下发。
func _on_military_budget_committed(total_bp: int, wage_bp: int, upkeep_bp: int,
		procurement_bp: int) -> void:
	military_budget_committed.emit(total_bp, wage_bp, upkeep_bp, procurement_bp)


func _on_national_committed(treasury_share_bp: int) -> void:
	if _national_slider == null:
		return
	procurement_committed.emit(treasury_share_bp, _research_share(),
		int(_current_channel_share(SECTION_ERA)),
		int(_current_channel_share(SECTION_COLONIZATION)))


## 科技份额提交：另两条通道沿用当前值（自动分配的通道传 -1，不把它钉死）。
func _on_technology_committed(share_bp: int) -> void:
	if _national_slider == null:
		return
	procurement_committed.emit(int(_national_slider.treasury_share_bp()), share_bp,
		int(_current_channel_share(SECTION_ERA)),
		int(_current_channel_share(SECTION_COLONIZATION)))


## 时代 / 开拓通道提交：只改这一条，其余三项沿用当前滑条位置。
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
		_research_share(), era, colonization)


## 科技份额的当前可见值；滑条未构建时退回解析出的政策值。
func _research_share() -> int:
	if _technology_slider != null:
		return int(_technology_slider.share_bp())
	return int(_channel_policy().research)


## 某条通道滑条当前显示的份额；-1 表示该通道仍沿用原生自动分配
## （自动通道显示的是从日额反推的位置，提交时必须保持 -1，否则会被钉成手动值）。
func _current_channel_share(section_id: String) -> int:
	var slider := _era_slider if section_id == SECTION_ERA \
		else _colonization_slider
	if slider == null:
		return -1
	if bool(slider.is_auto_allocated()):
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
	match section_id:
		SECTION_NATIONAL:
			section.set_value_text(_national_value_text())
			_refresh_national_slider()
		SECTION_TECHNOLOGY:
			section.set_value_text(_share_value_text(SECTION_TECHNOLOGY))
			_refresh_channel_sliders()
			_set_detail(entry, _technology_detail_text())
		SECTION_ERA:
			section.set_value_text(_share_value_text(SECTION_ERA))
			_refresh_channel_sliders()
			_set_detail(entry, _era_detail_text())
		SECTION_COLONIZATION:
			section.set_value_text(_share_value_text(SECTION_COLONIZATION))
			_refresh_channel_sliders()
			_set_detail(entry, _colonization_detail_text())
		SECTION_MILITARY:
			section.set_value_text(_military_value_text())
			if _military_block != null:
				_military_block.set_state(_military_model(),
					_military_editable())
			_set_detail(entry, _military_detail_text())


## 说明行只在异常状态出现：正常运行时的日额已经画在滑条右侧读数里，
## 再写一行只会把 2×2 网格的纸撑高、把第四块挤出首屏。
func _set_detail(entry: Dictionary, text: String) -> void:
	var detail := entry.get("detail_label") as Label
	if detail == null:
		return
	if detail.text != text:
		detail.text = text
	detail.visible = not text.is_empty()


func _section_signature(section_id: String) -> String:
	var procurement: Dictionary = _model.get("procurement", {})
	var treasury: Dictionary = _model.get("treasury", {})
	if POOL_SECTIONS.has(section_id):
		# 三条通道互相约束可拖上限：任一变化都要让四块一起重刷，
		# 否则玩家拖完科技，时代/开拓的上限还停在旧额度上。
		var policy: Dictionary = _channel_policy()
		return "p:%s:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d" % [
			section_id,
			int(policy.research), int(policy.era), int(policy.colonization),
			int(policy.base_daily),
			1 if bool(policy.era_auto) else 0,
			1 if bool(policy.colonization_auto) else 0,
			1 if bool(procurement.get("era_active", false)) else 0,
			int(procurement.get("research_daily_budget", 0)),
			int(procurement.get("era_daily_budget", 0)),
			int(procurement.get("colonization_daily_budget", 0)),
			1 if bool(_model.get("available", false)) else 0,
			1 if _procurement_enabled() else 0]
	if section_id == SECTION_MILITARY:
		var military: Dictionary = _military_model()
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


## 顶部纸带：滚动分区时它不动，所以每次刷新都要按最新政策重画。
func _refresh_ribbon() -> void:
	if _ribbon == null:
		return
	var policy: Dictionary = _channel_policy()
	var military: Dictionary = _military_model()
	var resolved: Dictionary = NationalProcurementSliderScript.resolve_policy(
		_player_controller, _model.get("procurement", {}), _local_policy)
	var signature := "r:%d:%d:%d:%d:%d:%d:%d:%d:%d" % [
		int(policy.base_daily), int(policy.research), int(policy.era),
		int(policy.colonization),
		int(resolved.get("treasury_share_bp", 0)),
		int(military.get("envelope_daily", 0)),
		1 if bool(military.get("envelope_enabled", false)) else 0,
		1 if bool(_model.get("available", false)) else 0,
		1 if _procurement_enabled() else 0]
	if signature == _ribbon_signature:
		return
	_ribbon_signature = signature
	_ribbon.set_state(int(policy.base_daily),
		int(resolved.get("treasury_share_bp", 0)),
		int(policy.research), int(policy.era), int(policy.colonization),
		int(military.get("envelope_daily", 0)),
		bool(military.get("envelope_enabled", false)),
		bool(_model.get("available", false)))


## 军事分区的模型：补一项目国库现金，供预算滑条在拖动时估算日额；
## 并叠上玩家刚提交、快照尚未反映的份额覆盖。
func _military_model() -> Dictionary:
	var military: Dictionary = (_model.get("military", {}) as Dictionary).duplicate()
	var treasury: Dictionary = _model.get("treasury", {})
	var cash := int(treasury.get("cash", _model.get("cash", 0)))
	if cash > 0 and not military.has("country_cash"):
		military["country_cash"] = cash
	if _military_local_budget.is_empty():
		return military
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
	if _military_local_budget.has("budget_share_bp"):
		military["envelope_enabled"] = int(_military_local_budget["budget_share_bp"]) > 0
	return military


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


func _refresh_national_slider() -> void:
	if _national_slider == null:
		return
	var procurement: Dictionary = _model.get("procurement", {})
	var policy: Dictionary = NationalProcurementSliderScript.resolve_policy(
		_player_controller, procurement, _local_policy)
	if not _local_policy.is_empty() and String(policy.get("source", "")) != "local":
		_local_policy.clear()
	var treasury: Dictionary = _model.get("treasury", {})
	var cash := int(treasury.get("cash", _model.get("cash", 0)))
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
## 三者基数相同（国家购买总额 national_daily），一律落在 0..10000；
## auto_* 标记该通道仍沿用原生自动分配，不占手动额度。
func _channel_policy() -> Dictionary:
	var procurement: Dictionary = _model.get("procurement", {})
	var policy: Dictionary = NationalProcurementSliderScript.resolve_policy(
		_player_controller, procurement, _local_policy)
	var research := clampi(int(policy.get("research_share_bp", 5000)), 0, 10000)
	var era := int(policy.get("era_share_bp", -1))
	var colonization := int(policy.get("colonization_share_bp", -1))
	var base := _national_daily_budget()
	var era_auto := era < 0
	var colonization_auto := colonization < 0
	if era_auto:
		era = _derive_share(int(procurement.get("era_daily_budget", 0)), base)
	if colonization_auto:
		colonization = _derive_share(
			int(procurement.get("colonization_daily_budget", 0)), base)
	var era_manual := 0 if era_auto else clampi(era, 0, 10000)
	var colonization_manual := 0 if colonization_auto \
		else clampi(colonization, 0, 10000)
	return {
		"research": research,
		"era": clampi(era, 0, 10000),
		"colonization": clampi(colonization, 0, 10000),
		"era_auto": era_auto,
		"colonization_auto": colonization_auto,
		# 三条通道都受同一条 100% 约束：科技也要被另外两条手动份额收窄。
		"research_ceiling": maxi(0, 10000 - era_manual - colonization_manual),
		"era_ceiling": maxi(0, 10000 - research - colonization_manual),
		"colonization_ceiling": maxi(0, 10000 - research - era_manual),
		"base_daily": base,
		"all_paused": research <= 0 and era <= 0 and colonization <= 0,
	}


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


## 把份额推给三条通道滑条：可拖上限随其余两项实时收窄。
func _refresh_channel_sliders() -> void:
	var policy := _channel_policy()
	var interactive := bool(_model.get("available", false)) and _procurement_enabled()
	var procurement: Dictionary = _model.get("procurement", {})
	var era_active := bool(procurement.get("era_active", false))
	if _technology_slider != null:
		# 科技恒有需求（科技值采购不会因为没有项目就停摆）。
		_technology_slider.set_channel_state(int(policy.research),
			int(policy.base_daily), true, interactive,
			int(policy.research_ceiling), false)
	if _era_slider != null:
		_era_slider.set_channel_state(int(policy.era), int(policy.base_daily),
			era_active, interactive, int(policy.era_ceiling), bool(policy.era_auto))
	if _colonization_slider != null:
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
	if not bool(_model.get("available", false)):
		return "科技采购预算随国库账目一起待命。"
	if not _procurement_enabled():
		return "国家购买已关闭，科技值暂不采购。"
	return ""


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
	return ""


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
	return ""


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
