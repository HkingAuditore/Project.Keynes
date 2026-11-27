extends Control
class_name MilitaryWorkspace

const ArmyConflictRows = preload("res://scripts/ui/components/military_army_conflict_rows.gd")

const ForceTarget = preload("res://scripts/ui/components/military_force_target.gd")
const MilitaryTableRows = preload("res://scripts/ui/components/military_table_rows.gd")


## Country military workspace (design §14.3). Four chapters; every number comes from
## MilitaryViewModel and every action goes through PlayerController.request_command.
## Daily refreshes only rewrite values on pre-built nodes; nothing is instantiated.
##
## This panel is an INDEX, not a workbench: armies, fronts and peace talks each have
## their own detail panel, so a row here only says what exists and hands the player
## over (档案 / 定位 / 议和). Anything that belongs to one army — move, area control,
## stop, disband, composition, supply days — lives in the army dossier.

## 打开军务档案（部队 / 战线）。外壳转给 GameUIManager.open_military_dossier()。
signal dossier_requested(kind: String, id: int, cell: int)
## 打开议和面板。外壳转给 GameUIManager.open_military_peace()。
signal peace_negotiation_requested(war_id: int)
signal locate_cell_requested(cell: int)
signal target_cells_requested(cells: PackedInt32Array)

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const TouchSliderPad = preload("res://scripts/ui/components/touch_slider_pad.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const VIEW_MODEL_SCRIPT = preload("res://scripts/ui/military_view_model.gd")
## 新脚本刻意不写 class_name：未进 global_script_class_cache 的类名会让引用方解析失败
## （同 touch_ui.gd 的说明），统一 preload。
const UnitRosterScript = preload("res://scripts/ui/components/military/military_unit_roster.gd")

const LIVE_REFRESH_INTERVAL_MSEC := 200
## 目标滑条的提交延迟：键盘、点击轨道等没有 `drag_ended` 的调整靠它落库；
## 鼠标拖动在松手时立即提交，不等这个计时器。
const TARGET_COMMIT_DELAY_SEC := 0.25
const NARROW_WIDTH := 820.0
const HEADCOUNT_MAX := 50000.0
const BUDGET_MAX := 50000.0
## Chapter tabs are sized like the technology workspace's ModeNav: the nav takes
## its natural width from the labels and the rest of the toolbar row stays empty.
## DossierChapterNav falls back to icon-only tabs as soon as the labels do not
## fit, so the width is measured from the chapter labels (the static 330 px guess
## that fits the 2-3 character technology tabs only fits two of these).
const CHAPTER_NAV_PAD := 22.0
## Below this workspace height the KPI band uses DossierKpiCard's dense mode.
const SHORT_HEIGHT := 520.0
const CHAPTER_NAV_MIN_WIDTH := 330.0
const SMALL_BUTTON := Vector2(0, 28)

var _vm = VIEW_MODEL_SCRIPT.new()
var _model: Dictionary = {}
var _chapter := "overview"
var _compact := false
var _narrow := false
var _player_controller = null
var _last_refresh_ms := -LIVE_REFRESH_INTERVAL_MSEC
var _refresh_pending := false
var _refresh_timer: Timer
var _scroll_by_chapter: Dictionary = {}
var _signatures: Dictionary = {}
var _selected_army := 0
var _selected_war := 0
var _forces: Dictionary = {}
var _war_data: Dictionary = {}
var _slider_dragging := false
## 目标滑条的待提交值（`_target_pending_mode >= 0` 即视为有）。
##
## 命令在 D+1 才落库，而面板每 200ms 用原生快照重画一次。快照追上之前若把把手
## 写回原生旧值，玩家看到的就是「拖了等于没拖、永远招不到兵」（2026-11-20 用玩家
## 存档复盘：target_value 恒为 0，配额随之恒为 0）。所以要留一份本地覆盖，等到
## 快照的模式与数值都与提交值一致才释放。
var _target_pending_mode := -1
var _target_pending_value := -1.0
var _target_commit_timer: Timer
var _flash_text := ""
## Short viewport (phone landscape): the KPI band collapses to one dense line.
var _short := false
var _summoned := false

@onready var _chapter_nav: DossierChapterNav = %ChapterNav
@onready var _status_label: Label = %StatusLabel
@onready var _viewport: ScrollContainer = %PageViewport
@onready var _kpi_strip: PanelContainer = %KpiStrip
@onready var _kpi_row: HBoxContainer = %KpiRow
@onready var _pages := {
	"overview": %OverviewPage, "forces": %ForcesPage, "armies": %ArmiesPage, "war": %WarPage,
}

@onready var _composition_bar: DossierStackedBar = %CompositionBar
@onready var _deployment_bar: DossierStackedBar = %DeploymentBar
@onready var _spend_bar: DossierStackedBar = %SpendBar
@onready var _overview_insights: InsightList = %OverviewInsights
@onready var _overview_war_banner: PanelContainer = %WarBannerCard
@onready var _overview_war_kicker: Label = %WarKicker
@onready var _overview_war_link: Button = %WarLink

@onready var _mode_headcount: Button = %ModeHeadcount
@onready var _mode_budget: Button = %ModeBudget
@onready var _target_slider: HSlider = %TargetSlider
@onready var _target_value: Label = %TargetValue
@onready var _target_value_icon: TextureRect = %TargetValueIcon
@onready var _cost_caption: Label = %CostCaption
@onready var _cost_icon: TextureRect = %CostIcon
@onready var _cost_value: Label = %CostValue
@onready var _quality_best: Button = %QualityBest
@onready var _quality_cheap: Button = %QualityCheap
@onready var _toggle_auto_retrain: CheckButton = %ToggleAutoRetrain
@onready var _toggle_levy: CheckButton = %ToggleLevy
@onready var _toggle_auto_discharge: CheckButton = %ToggleAutoDischarge
@onready var _share_bar: DossierStackedBar = %ShareBar
@onready var _unit_roster = %UnitRoster
@onready var _barracks_caption: Label = %BarracksCaption
@onready var _barracks_table: DossierLedgerTable = %BarracksTable
@onready var _training_caption: Label = %TrainingCaption
@onready var _training_table: DossierLedgerTable = %TrainingTable

@onready var _army_caption: Label = %ArmyCaption
@onready var _army_table: DossierLedgerTable = %ArmyTable
@onready var _army_empty: Control = %ArmyEmpty
@onready var _convoy_caption: Label = %ConvoyCaption
@onready var _convoy_table: DossierLedgerTable = %ConvoyTable
@onready var _procurement_label: Label = %ProcurementLabel

@onready var _war_cards: Array = [%WarCard0, %WarCard1, %WarCard2]
@onready var _war_empty: Control = %WarEmpty
@onready var _declare_table: DossierLedgerTable = %DeclareTable
@onready var _declare_empty: Label = %DeclareEmpty
@onready var _declare_caption: Label = %DeclareCaption
@onready var _front_list: DossierBarList = %FrontList
@onready var _front_empty: Label = %FrontEmpty


func _ready() -> void:
	_chapter_nav.set_chapters(_chapter_definitions(), _chapter)
	_size_chapter_nav()
	_chapter_nav.chapter_selected.connect(select_chapter)
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	add_child(_refresh_timer)
	_refresh_timer.timeout.connect(_flush_pending_refresh)
	_target_commit_timer = Timer.new()
	_target_commit_timer.one_shot = true
	_target_commit_timer.wait_time = TARGET_COMMIT_DELAY_SEC
	add_child(_target_commit_timer)
	_target_commit_timer.timeout.connect(_commit_target)
	# Keep the index page compact: every action has a semantic paper icon, and
	# the caption is short enough to scan without turning the page into a manual.
	IconButton.apply_with_text(_overview_war_link, &"military.war.front", "战线",
		IconButton.MEDIUM, "打开战争与战线")
	# 「人数 / 预算」是互斥的模式签：必须真的开 toggle。`apply_with_text` 的
	# `toggle` 参数默认 false，而它会无条件 `button.toggle_mode = toggle`；漏了这
	# 一项两个按钮就退化成普通按钮——按下去不保持、`set_pressed_no_signal(false)`
	# 也无效，`button_pressed` 恒 false。结果是「预算」模式根本进不去，拖动提交
	# 一律按人数模式发出去（金额被当成兵数）。
	IconButton.apply_with_text(_mode_headcount, &"military.plan.target", "人数",
		IconButton.MEDIUM, "按目标兵力设置", true)
	IconButton.apply_with_text(_mode_budget, &"metric.treasury", "预算",
		IconButton.MEDIUM, "按每日军费设置", true)
	IconButton.apply_with_text(_quality_best, &"military.plan.quality", "优先",
		IconButton.MEDIUM, "优先采购更高品质装备", true)
	IconButton.apply_with_text(_quality_cheap, &"metric.treasury", "节省",
		IconButton.MEDIUM, "优先采购价格较低的合格装备", true)
	IconButton.apply_with_text(_toggle_auto_retrain, &"military.plan.training", "换装",
		IconButton.MEDIUM, "装备过时时自动改训", true)
	IconButton.apply_with_text(_toggle_levy, &"military.plan.target", "征召",
		IconButton.MEDIUM, "兵营缺员时强制征召", true)
	IconButton.apply_with_text(_toggle_auto_discharge, &"action.back", "退伍",
		IconButton.MEDIUM, "超过目标时自动退伍", true)
	for button in [_overview_war_link, _mode_headcount, _mode_budget, _quality_best,
			_quality_cheap, _toggle_auto_retrain, _toggle_levy, _toggle_auto_discharge]:
		button.focus_mode = Control.FOCUS_ALL
		var target_h := 36.0 if button in [_toggle_auto_retrain, _toggle_levy, _toggle_auto_discharge] else 34.0
		button.custom_minimum_size = Vector2(button.custom_minimum_size.x,
			maxf(button.custom_minimum_size.y, target_h))
		UIAnimation.bind_tactile_button(button)
	_mode_headcount.focus_neighbor_right = _mode_headcount.get_path_to(_mode_budget)
	_mode_budget.focus_neighbor_left = _mode_budget.get_path_to(_mode_headcount)
	_quality_best.focus_neighbor_right = _quality_best.get_path_to(_quality_cheap)
	_quality_cheap.focus_neighbor_left = _quality_cheap.get_path_to(_quality_best)
	_overview_war_link.pressed.connect(select_chapter.bind("war"))
	for card in _war_cards:
		# 战争卡片只负责“这是个什么战争”，条款编辑器在议和面板里。
		card.set_action("议和")
		card.action_requested.connect(func(war_id: int) -> void: peace_negotiation_requested.emit(war_id))
		card.gui_input.connect(_on_war_card_input.bind(card))
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for button in [_mode_headcount, _mode_budget, _quality_best, _quality_cheap]:
		(button as Button).custom_minimum_size = Vector2(0, 34.0)
	_bind_forces()
	_bind_armies()
	_bind_war()
	for card in _kpi_row.get_children():
		(card as DossierKpiCard).show_divider = card.get_index() < _kpi_row.get_child_count() - 1
	_apply_chapter_visibility()
	if TouchUI.is_short_viewport():
		set_compact(true)
	_apply_kpi_density()
	# Themes and container sizes settle one frame later; without this second pass
	# a workspace mounted before the player theme keeps the icon-only tab row.
	call_deferred("_refresh_layout")


func _refresh_layout() -> void:
	if not is_node_ready():
		return
	_signatures.erase("__layout_stamp__")
	_apply_layout()


func _bind_forces() -> void:
	_target_slider.drag_started.connect(func() -> void: _slider_dragging = true)
	_target_slider.drag_ended.connect(_on_target_drag_ended)
	_target_slider.value_changed.connect(_on_target_value_changed)
	TouchSliderPad.attach_to(_target_value, _target_slider, {
		"title": func() -> String: return "每日军费预算" if _mode_budget.button_pressed else "目标常备兵力",
		"commit": func(_v: float) -> void: _commit_target(),
	})
	_mode_headcount.pressed.connect(_on_target_mode.bind(0))
	_mode_budget.pressed.connect(_on_target_mode.bind(1))
	_quality_best.pressed.connect(_request.bind(
		PlayerControllerScript.COMMAND_MILITARY_QUALITY_POLICY, {"policy": 0}))
	_quality_cheap.pressed.connect(_request.bind(
		PlayerControllerScript.COMMAND_MILITARY_QUALITY_POLICY, {"policy": 1}))
	_toggle_auto_retrain.toggled.connect(_on_toggle.bind(
		PlayerControllerScript.COMMAND_MILITARY_AUTO_RETRAIN))
	_toggle_levy.toggled.connect(_on_toggle.bind(PlayerControllerScript.COMMAND_MILITARY_LEVY))
	_toggle_auto_discharge.toggled.connect(_on_toggle.bind(
		PlayerControllerScript.COMMAND_MILITARY_AUTO_DISCHARGE))
	_share_bar.set_segments("", [])
	_share_bar.show_legend = false
	_share_bar.segment_clicked = _on_share_bar_clicked
	_unit_roster.empty_text = "尚未解锁可配置的兵种：先研究军事科技"
	_unit_roster.share_step.connect(_on_roster_step)
	_barracks_table.empty_text = "尚无兵营：在领土地块面板里建造"
	_barracks_table.row_selected.connect(func(cell) -> void: locate_cell_requested.emit(int(cell)))
	_barracks_table.row_action.connect(_on_barracks_action)
	_barracks_table.set_columns([
		{"id": "name", "label": "驻地", "kind": "text", "expand": true, "min_width": 84.0},
		{"id": "posts", "label": "兵额", "kind": "number", "width": 58.0, "optional": true},
		{"id": "fill", "label": "在驻", "kind": "bar", "width": 120.0},
		{"id": "quota", "label": "配额", "kind": "number", "width": 52.0, "optional": true},
		{"id": "actions", "label": "", "kind": "actions", "width": 34.0, "sortable": false},
	], "fill")
	_training_table.empty_text = ""
	_training_table.row_selected.connect(func(id) -> void: _locate_training(int(id)))
	_training_table.set_columns([
		{"id": "unit", "label": "改训", "kind": "text", "expand": true, "min_width": 96.0},
		{"id": "count", "label": "人数", "kind": "number", "width": 52.0},
		{"id": "progress", "label": "进度", "kind": "bar", "width": 122.0},
	], "progress")


func _bind_armies() -> void:
	_army_table.empty_text = ""
	# 点行 = 打开军务档案（编成、补给、移动 / 控制 / 停止都在那边）。
	_army_table.row_selected.connect(func(handle) -> void: _open_army_dossier(int(handle)))
	_army_table.row_action.connect(_on_army_action)
	_army_table.set_columns([
		{"id": "name", "label": "部队", "kind": "text", "expand": true, "min_width": 104.0},
		{"id": "heads", "label": "兵力", "kind": "number", "width": 60.0},
		{"id": "power", "label": "攻 / 防", "kind": "text", "width": 70.0, "optional": true},
		{"id": "morale", "label": "士气", "kind": "bar", "width": 96.0},
		{"id": "supply", "label": "补给", "kind": "bar", "width": 96.0, "optional": true},
		{"id": "actions", "label": "", "kind": "actions", "width": 58.0, "sortable": false},
	], "heads")
	_convoy_table.empty_text = ""
	_convoy_table.row_selected.connect(_on_convoy_selected)
	_convoy_table.set_columns([
		{"id": "route", "label": "路线", "kind": "text", "expand": true, "min_width": 120.0},
		{"id": "goods", "label": "货物", "kind": "text", "width": 76.0, "optional": true},
		{"id": "risk", "label": "被截风险", "kind": "bar", "width": 110.0},
		{"id": "eta", "label": "到达", "kind": "text", "width": 52.0},
	], "risk")


func _bind_war() -> void:
	_declare_table.empty_text = ""
	_declare_table.row_selected.connect(_on_declare_selected)
	_declare_table.row_action.connect(_on_declare_action)
	_declare_table.set_columns([
		{"id": "name", "label": "邻国", "kind": "text", "expand": true, "min_width": 110.0},
		{"id": "capital", "label": "首府", "kind": "text", "width": 96.0, "optional": true},
		{"id": "cells", "label": "边域", "kind": "number", "width": 56.0, "optional": true},
		{"id": "state", "label": "状态", "kind": "text", "width": 104.0},
		{"id": "actions", "label": "", "kind": "actions", "width": 64.0, "sortable": false},
	], "name", false)
	_front_list.row_height = 24.0
	_front_list.label_width = 136.0
	_front_list.value_width = 108.0
	_front_list.selectable = true
	# 点战线 = 打开战线档案，镜头同时落到该扇区。
	_front_list.row_selected.connect(_on_front_selected)


func _chapter_definitions() -> Array:
	var definitions: Array = []
	for chapter in VIEW_MODEL_SCRIPT.CHAPTERS:
		definitions.append({"id": String(chapter.id), "label": String(chapter.label),
			"icon": chapter.icon, "question": ""})
	return definitions


## Width the chapter nav needs for icon + label tabs. DossierChapterNav lays each
## tab out as ICON + 6 + text width + 16 and flips to icon-only the moment the
## row does not fit, so measure with the same font and padding it draws with.
func _chapter_nav_width() -> float:
	var width := 0.0
	for chapter in _chapter_definitions():
		var text_width := UITokens.dossier_font("sans_strong").get_string_size(
			String(chapter.label), HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			DossierChapterNav.FONT_SIZE).x
		width += ceilf(text_width + DossierChapterNav.ICON + CHAPTER_NAV_PAD)
	return maxf(CHAPTER_NAV_MIN_WIDTH, width)


func _size_chapter_nav() -> void:
	if _chapter_nav == null:
		return
	# DossierChapterNav's _init fills the row; the military toolbar has nothing to
	# the right of the tabs, so both the scene and the script keep it shrunk.
	_chapter_nav.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var width := _chapter_nav_width()
	if absf(_chapter_nav.custom_minimum_size.x - width) > 0.5:
		_chapter_nav.custom_minimum_size = Vector2(width, DossierChapterNav.HEIGHT)
		_chapter_nav.call_deferred("_relayout")


# ── shell API (CountryPanel) ────────────────────────────────────────────

func set_model(model: Dictionary) -> void:
	_model = model if model != null else {}
	_vm.configure(_model)
	_last_refresh_ms = Time.get_ticks_msec()
	_signatures.clear()
	_refresh_now()


func refresh_model(model: Dictionary) -> void:
	_model = model if model != null else {}
	_vm.configure(_model)
	var now := Time.get_ticks_msec()
	if now - _last_refresh_ms < LIVE_REFRESH_INTERVAL_MSEC:
		if not _refresh_pending:
			_refresh_pending = true
			_refresh_timer.start(float(LIVE_REFRESH_INTERVAL_MSEC - (now - _last_refresh_ms)) / 1000.0)
		return
	_last_refresh_ms = now
	_refresh_now()


func set_compact(compact: bool) -> void:
	_compact = compact or TouchUI.is_short_viewport()
	_short = _compact or (size.y > 1.0 and size.y < SHORT_HEIGHT)
	_apply_layout()


func set_player_controller(controller) -> void:
	_player_controller = controller
	# The view model names zones and targets through the same session object.
	_vm.set_player_controller(controller)


func player_controller():
	return _player_controller


func current_chapter() -> String:
	return _chapter


func view_model():
	return _vm


func chapter_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	for chapter in VIEW_MODEL_SCRIPT.CHAPTERS:
		ids.append(String(chapter.id))
	return ids


func select_chapter(chapter_id: String) -> void:
	if not chapter_ids().has(chapter_id):
		return
	if chapter_id == _chapter:
		_refresh_now()
		return
	_scroll_by_chapter[_chapter] = _viewport.scroll_vertical
	_chapter = chapter_id
	_chapter_nav.select(chapter_id)
	_apply_chapter_visibility()
	_refresh_now()
	UIAnimation.crossfade(_viewport, UITokens.ANIM_FAST)
	_viewport.scroll_vertical = int(_scroll_by_chapter.get(chapter_id, 0))


func focus_army(army_handle: int) -> void:
	_selected_army = army_handle
	select_chapter("armies")
	_refresh_now()


## 外壳让面板跳到某场战争（例如从总览点「议和」）：切到战争章节即可。
func open_peace_for(war_id: int) -> void:
	_selected_war = war_id
	select_chapter("war")
	_refresh_now()


# ── refresh ─────────────────────────────────────────────────────────────

func _flush_pending_refresh() -> void:
	if not _refresh_pending:
		return
	_refresh_pending = false
	_last_refresh_ms = Time.get_ticks_msec()
	_refresh_now()


func _refresh_now() -> void:
	if not is_node_ready():
		return
	_apply_layout()
	if not _vm.available():
		_show_status(_vm.reason() if not _vm.reason().is_empty() else "先在领地建立军事机构，才能查看军情。", true)
		_kpi_strip.visible = false
		for page in _pages.values():
			(page as Control).visible = false
		return
	if _status_label.visible and _flash_text.is_empty():
		_status_label.visible = false
	_apply_chapter_visibility()
	match _chapter:
		"overview":
			_refresh_overview()
		"forces":
			_refresh_forces()
		"armies":
			_refresh_armies()
		"war":
			_refresh_war()


func _apply_chapter_visibility() -> void:
	for chapter_id in _pages:
		(_pages[chapter_id] as Control).visible = chapter_id == _chapter and _vm.available()
	_kpi_strip.visible = _chapter == "overview" and _vm.available()


func _apply_layout() -> void:
	var narrow := _compact or size.x < NARROW_WIDTH
	# The stylebox is the mount marker: CountryPanel brings the player theme, the
	# gallery/test mounts have none and draw icon-only tabs.
	var themed := _chapter_nav.has_theme_stylebox("pressed", "PKChapterTab")
	_size_chapter_nav()
	# The marker is part of the latch so a workspace mounted before its theme is
	# ready re-runs once the theme arrives instead of keeping icon-only tabs.
	# The short-viewport flag only changes through set_compact / TouchUI, so it is
	# resolved here (not from size.y, which is still 0 during the first pass).
	var stamp := "%s|%s|%s" % [narrow, themed, _short]
	if stamp == String(_signatures.get("__layout_stamp__", "")):
		return
	_signatures["__layout_stamp__"] = stamp
	_narrow = narrow
	var columns := 1 if narrow else 2
	# 部队只剩一张列表卡（详情在军务档案里）；战争卡与战线并排，宣战表独占一行。
	for grid in [%OverviewGrid, %ForcesGrid, %WarGrid]:
		(grid as GridContainer).columns = columns
	(%ArmyGrid as GridContainer).columns = 1
	(%WarLowerGrid as GridContainer).columns = 1
	_shape_kpis()
	warn_if_unbound()


## The screenshot fixture and unit tests mount the workspace without a live
## session. A real session always has a generator; when it does not, every name
## and target list here would render a placeholder, so say so once.
func warn_if_unbound() -> void:
	if _summoned:
		return
	if _vm.session_bound():
		return
	_summoned = true
	push_warning("MilitaryWorkspace: model mounted without generator/player "
		+ "controller; region, country and target names fall back to indexes.")


func session_bound() -> bool:
	return _vm.session_bound()


## The KPI band keeps DossierKpiCard's own heights (86 px, 54 px dense). It used
## to force 66 px so the band would not clip at 720p, but the card draws its value
## baseline at y=57 and its caption at y=h-8: at 66 those land on the same line and
## the two strings overlap. The page column is a ScrollContainer, so the honest
## height costs nothing but a scroll.
func _shape_kpis() -> void:
	_apply_kpi_density()
	for card in _kpi_row.get_children():
		var kpi := card as DossierKpiCard
		if kpi.dense:
			if kpi.custom_minimum_size.y < DossierKpiCard.DENSE_HEIGHT:
				kpi.custom_minimum_size.y = DossierKpiCard.DENSE_HEIGHT
			continue
		if kpi.custom_minimum_size.y < DossierKpiCard.HEIGHT:
			kpi.custom_minimum_size.y = DossierKpiCard.HEIGHT
		if not kpi.caption.is_empty() and kpi.custom_minimum_size.y < 78.0:
			push_warning("MilitaryWorkspace: KPI '%s' is %.0f px tall; value and "
				% [kpi.title, kpi.custom_minimum_size.y]
				+ "caption baselines collide below 78 px.")
		kpi.queue_redraw()
	_rescale_type()


## Below 520px of workspace the band switches to DossierKpiCard's dense
## single-line mode, exactly like the family summary band.
func _apply_kpi_density() -> void:
	for card in _kpi_row.get_children():
		var kpi := card as DossierKpiCard
		if kpi.dense != _short:
			kpi.dense = _short


## Player-facing copy must not grow past its siblings: the KPI value, the target
## value and the war score were 22–30px inside their own bands. Nothing here is
## larger than the 18px value style used by the other dossier workspaces.
func _rescale_type() -> void:
	for label in [_target_value]:
		(label as Label).add_theme_font_size_override("font_size", UITokens.FONT_VALUE)
	for card in _war_cards:
		(card as Control).set_type_scale(UITokens.FONT_VALUE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		var short := _compact or (size.y > 1.0 and size.y < SHORT_HEIGHT)
		if short != _short:
			_short = short
			_signatures.erase("__layout_stamp__")
		_apply_layout()
	# The workspace also lives in galleries and tests that never call
	# set_model; the tab row and the grid columns still have to be laid out.
	if what == NOTIFICATION_POST_ENTER_TREE:
		call_deferred("_refresh_layout")


func _changed(key: String, value) -> bool:
	var signature := var_to_str(value)
	if String(_signatures.get(key, "")) == signature:
		return false
	_signatures[key] = signature
	return true


# ── overview ────────────────────────────────────────────────────────────

func _refresh_overview() -> void:
	var data: Dictionary = _vm.build("overview")
	var kpis: Array = data.get("kpis", [])
	var cards := _kpi_row.get_children()
	for index in range(cards.size()):
		if index < kpis.size():
			(cards[index] as DossierKpiCard).set_metric(kpis[index])
	if _changed("overview_bars", [data.composition, data.deployment, data.spend]):
		_composition_bar.set_segments("兵员构成", data.composition, String(data.composition_total))
		_deployment_bar.set_segments("部署", data.deployment, String(data.deployment_total))
		_spend_bar.set_segments("日军费构成（30 日均）", data.spend, String(data.spend_total), true)

	if _changed("overview_insights", data.insights):
		_overview_insights.set_items(data.insights)
	# 战争只在「战争」章节展开；总览留一行指路，不再重复两张战争卡。
	var wars: Array = data.get("wars", [])
	if _overview_war_banner != null:
		_overview_war_banner.visible = not wars.is_empty()
	_overview_war_kicker.visible = not wars.is_empty()
	if not wars.is_empty():
		_overview_war_kicker.text = "进行中的战争 · %d 场" % wars.size()
	_overview_war_link.visible = not wars.is_empty()


# ── forces ──────────────────────────────────────────────────────────────

func _refresh_forces() -> void:
	_forces = _vm.build("forces")
	var snapshot_mode := int(_forces.get("target_mode", 0))
	var raw := float(_forces.get("target_value", 0))
	var snapshot_value := raw if snapshot_mode == 0 \
		else raw / MilitaryViewModel.MONEY_SCALE
	# 原生已经落库（模式与数值都对上）：释放本地覆盖，此后完全跟随快照。
	if _target_pending_mode >= 0 and snapshot_mode == _target_pending_mode \
			and is_equal_approx(snapshot_value, _target_pending_value):
		_target_pending_mode = -1
		_target_pending_value = -1.0
	# 待提交期间以玩家刚选定的模式为准，否则切到「预算」后按钮与量程会在快照追上
	# 之前闪回「人数」。
	var mode := _target_pending_mode if _target_pending_mode >= 0 else snapshot_mode
	_mode_headcount.set_pressed_no_signal(mode == 0)
	_mode_budget.set_pressed_no_signal(mode == 1)
	_target_slider.max_value = HEADCOUNT_MAX if mode == 0 else BUDGET_MAX
	_target_slider.step = 100.0 if mode == 0 else 50.0
	# 拖动中或还有待提交值时不动把手：写回旧值就是「拖了没用」的假象。
	if not _slider_dragging and _target_pending_mode < 0:
		_target_slider.set_value_no_signal(snapshot_value)
	_update_target_readout()
	var policy := int(_forces.get("quality_policy", 0))
	_quality_best.set_pressed_no_signal(policy == 0)
	_quality_cheap.set_pressed_no_signal(policy == 1)
	_toggle_auto_retrain.set_pressed_no_signal(bool(_forces.get("auto_retrain", true)))
	_toggle_levy.set_pressed_no_signal(bool(_forces.get("levy_enabled", true)))
	_toggle_auto_discharge.set_pressed_no_signal(bool(_forces.get("auto_discharge", false)))
	var assigned := int(_forces.get("share_total", 0))
	# 名册行是「份额 + 目录 + 解锁闸门 + 军饷」的纯函数，所以签名只取这四项，
	# 免得每 200ms 对整份行表做一次 var_to_str。
	var roster_stamp := [_forces.get("shares", []), assigned,
		_forces.get("unlocked_count", 0), _forces.get("gate_known", false),
		_forces.get("daily_wage", 0.0)]
	if _changed("shares", roster_stamp):
		_share_bar.set_segments("兵种编制", _forces.shares, "已配 %.0f%%" % (assigned / 100.0))
		_apply_unit_roster(_forces)
	_barracks_caption.text = String(_forces.get("barracks_caption", ""))
	if _changed("barracks", _forces.barracks):
		_apply_barracks(_forces.barracks)
	var training: Array = _forces.get("training", [])
	_training_table.visible = not training.is_empty()
	_training_caption.visible = not training.is_empty()
	if not training.is_empty():
		_training_caption.text = String(_forces.get("training_caption", ""))
	if _changed("training", _forces.training):
		_apply_training(_forces.training)


## 名册只列国家现在真的能编成的兵种；民兵作为“剩余份额”的持有者在行尾出现。
func _apply_unit_roster(forces: Dictionary) -> void:
	_unit_roster.set_units(forces.get("units", []))


func _apply_barracks(rows: Array) -> void:
	MilitaryTableRows._apply_barracks( _barracks_table, rows)


func _apply_training(rows: Array) -> void:
	MilitaryTableRows._apply_training( _training_table, rows)


func _update_target_readout() -> void:
	ForceTarget._update_target_readout(self)


## 用户改了滑条值。拖动中只更新读数（松手时统一提交，免得每 100 人发一条命令）；
## 其余输入（键盘、点击轨道、无障碍调整）没有 `drag_ended`，靠防抖计时器落库。
func _on_target_value_changed(_value: float) -> void:
	ForceTarget._on_target_value_changed(self, _value)


func _on_target_drag_ended(_changed_value: bool) -> void:
	ForceTarget._on_target_drag_ended(self, _changed_value)


## 提交当前滑条位置。松手与防抖到期都走这里；同一个值不重复发命令。
func _commit_target() -> void:
	ForceTarget._commit_target(self)


func _on_target_mode(mode: int) -> void:
	ForceTarget._on_target_mode(self, mode)


func _submit_target(mode: int) -> void:
	ForceTarget._submit_target(self, mode)


func _on_toggle(enabled: bool, command: StringName) -> void:
	_request(command, {"enabled": enabled})


func _on_roster_step(unit_id: String, delta_bp: int) -> void:
	ForceTarget._on_roster_step(self, unit_id, delta_bp)


## 份额条点击：色段宽度只反映现有份额，所以点击是「把这个兵种调整到该处」，
## 不是重新划分整条。落在段内的位置换算成该段已占份额的绝对千分比，
## 再夹到「其他兵种份额之和」允许的余量里，未分配部分仍旧留给民兵。
func _on_share_bar_clicked(unit_id: String, ratio: float) -> void:
	ForceTarget._on_share_bar_clicked(self, unit_id, ratio)


func _on_barracks_action(cell, action_id: String) -> void:
	_request(PlayerControllerScript.COMMAND_MILITARY_BARRACKS,
		{"cell": int(cell), "paused": action_id == "pause"})


func _locate_training(order_id: int) -> void:
	for row in _forces.get("training", []):
		if int(row.id) == order_id and int(row.cell) >= 0:
			locate_cell_requested.emit(int(row.cell))


func _refresh_armies() -> void:
	ArmyConflictRows._refresh_armies(self)


func _apply_army_rows(rows: Array) -> void:
	ArmyConflictRows._apply_army_rows(self, rows)


func _apply_convoys(convoys: Array) -> void:
	ArmyConflictRows._apply_convoys(self, convoys)


func _on_army_action(handle, action_id: String) -> void:
	ArmyConflictRows._on_army_action(self, handle, action_id)


func _open_army_dossier(handle: int) -> void:
	ArmyConflictRows._open_army_dossier(self, handle)


func _army_cell(handle: int) -> int:
	return ArmyConflictRows._army_cell(self, handle)


func selected_army() -> int:
	return ArmyConflictRows.selected_army(self)


func set_selected_army(army_handle: int) -> void:
	ArmyConflictRows.set_selected_army(self, army_handle)


func _on_convoy_selected(convoy_id) -> void:
	ArmyConflictRows._on_convoy_selected(self, convoy_id)


func _refresh_war() -> void:
	ArmyConflictRows._refresh_war(self)


func _refresh_declare(data: Dictionary) -> void:
	ArmyConflictRows._refresh_declare(self, data)


func _on_war_card_input(event: InputEvent, card: Control) -> void:
	ArmyConflictRows._on_war_card_input(self, event, card)


func _on_declare_selected(row_id) -> void:
	ArmyConflictRows._on_declare_selected(self, row_id)


func _on_declare_action(row_id, action_id: String) -> void:
	ArmyConflictRows._on_declare_action(self, row_id, action_id)


func _declare_row(row_id: int) -> Dictionary:
	return ArmyConflictRows._declare_row(self, row_id)


func _refresh_fronts(data: Dictionary) -> void:
	ArmyConflictRows._refresh_fronts(self, data)


func _on_front_selected(row_id) -> void:
	ArmyConflictRows._on_front_selected(self, row_id)


func _request(id: StringName, args: Dictionary) -> Dictionary:
	return ArmyConflictRows._request(self, id, args)


func _flash(text: String, danger: bool) -> void:
	_flash_text = text
	_show_status(text, danger)
	get_tree().create_timer(4.0).timeout.connect(func() -> void:
		if _flash_text == text:
			_flash_text = ""
			_status_label.visible = false)


func _show_status(text: String, danger: bool) -> void:
	ArmyConflictRows._show_status(self, text, danger)


static func _count(value) -> String:
	return MilitaryTableRows._count(value)


## Short form for dense table cells: 4310 -> 4310, 12500 -> 1.3万.
static func _compact_count(value) -> String:
	return MilitaryTableRows._compact_count(value)


static func _percent(value) -> String:
	return MilitaryTableRows._percent(value)


static func _tone(value: float) -> Color:
	return MilitaryTableRows._tone(value)
