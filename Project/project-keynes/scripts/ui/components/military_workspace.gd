extends Control
class_name MilitaryWorkspace

## Country military workspace (design §14.3). Four chapters; every number comes from
## MilitaryViewModel and every action goes through PlayerController.request_command.
## Daily refreshes only rewrite values on pre-built nodes; nothing is instantiated.

signal locate_cell_requested(cell: int)
signal target_cells_requested(cells: PackedInt32Array)

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const VIEW_MODEL_SCRIPT = preload("res://scripts/ui/military_view_model.gd")

const LIVE_REFRESH_INTERVAL_MSEC := 200
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
## Military control radius limits (PlayerController rejects > 6).
const MIN_AREA_RADIUS := 1
const MAX_AREA_RADIUS := 6

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
var _war_score := 0.0
var _forces: Dictionary = {}
var _war_data: Dictionary = {}
var _slider_dragging := false
var _flash_text := ""
## Peace terms: occupied enemy cells ticked for cession / return.
var _ceded_checked: Dictionary = {}
## Army order mode owned by the map ("", "move", "area") — see
## PlayerController.begin_military_arm_order.
var _arm_order := ""
var _arm_radius := 1
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
@onready var _overview_wars: Array = [%OverviewWar0, %OverviewWar1]
@onready var _overview_war_empty: Label = %OverviewWarEmpty

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
@onready var _unit_share_table: DossierLedgerTable = %UnitShareTable
@onready var _barracks_caption: Label = %BarracksCaption
@onready var _barracks_table: DossierLedgerTable = %BarracksTable
@onready var _training_caption: Label = %TrainingCaption
@onready var _training_table: DossierLedgerTable = %TrainingTable
@onready var _codex_toggle: Button = %CodexToggle
@onready var _codex_grid: Control = %CodexGrid

@onready var _army_caption: Label = %ArmyCaption
@onready var _army_table: DossierLedgerTable = %ArmyTable
@onready var _army_detail: Control = %ArmyDetail
@onready var _army_icon: IconBadge = %ArmyIcon
@onready var _army_title: Label = %ArmyTitle
@onready var _army_meta: Label = %ArmyMeta
@onready var _army_warning: Label = %ArmyWarning
@onready var _army_move: Button = %ArmyMove
@onready var _army_area: Button = %ArmyArea
@onready var _lot_list: DossierBarList = %LotList
@onready var _supply_list: DossierBarList = %SupplyList
@onready var _army_empty: Control = %ArmyEmpty
@onready var _convoy_caption: Label = %ConvoyCaption
@onready var _convoy_table: DossierLedgerTable = %ConvoyTable
@onready var _procurement_label: Label = %ProcurementLabel

@onready var _war_cards: Array = [%WarCard0, %WarCard1, %WarCard2]
@onready var _war_empty: Control = %WarEmpty
@onready var _declare_table: DossierLedgerTable = %DeclareTable
@onready var _declare_empty: Label = %DeclareEmpty
@onready var _declare_caption: Label = %DeclareCaption
@onready var _log_list: DossierBarList = %BattleLogList
@onready var _log_empty: Label = %BattleLogEmpty
@onready var _front_list: DossierBarList = %FrontList
@onready var _front_empty: Label = %FrontEmpty
@onready var _ceding_list: Control = %CedingList
@onready var _ceding_caption: Label = %CedingCaption
@onready var _cession_rule: Control = %CessionRule
@onready var _peace_return: Button = %PeaceReturn
@onready var _peace_editor: Control = %PeaceEditor
@onready var _peace_title: Label = %PeaceTitle
@onready var _peace_white: CheckBox = %PeaceWhite
@onready var _peace_lump: CheckBox = %PeaceLump
@onready var _lump_amount: SpinBox = %LumpAmount
@onready var _peace_install: CheckBox = %PeaceInstall
@onready var _install_amount: SpinBox = %InstallAmount
@onready var _install_count: SpinBox = %InstallCount
@onready var _install_total: Label = %InstallTotal
@onready var _peace_annex: CheckBox = %PeaceAnnex
@onready var _peace_price: Label = %PeacePrice
@onready var _peace_score: Label = %PeaceScore
@onready var _peace_band: Label = %PeaceBand
@onready var _peace_submit: Button = %PeaceSubmit


func _ready() -> void:
	_chapter_nav.set_chapters(_chapter_definitions(), _chapter)
	_size_chapter_nav()
	_chapter_nav.chapter_selected.connect(select_chapter)
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	add_child(_refresh_timer)
	_refresh_timer.timeout.connect(_flush_pending_refresh)
	%WarLink.pressed.connect(select_chapter.bind("war"))
	for card in _overview_wars:
		card.set_action("议和条款 ›")
		card.action_requested.connect(_on_overview_war)
	for card in _war_cards:
		card.set_action("")
		card.gui_input.connect(_on_war_card_input.bind(card))
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for button in [_mode_headcount, _mode_budget, _quality_best, _quality_cheap,
			%ArmyLocate, %ArmyStop, %ArmyDisband]:
		(button as Button).custom_minimum_size = SMALL_BUTTON
	_bind_forces()
	_bind_armies()
	_bind_war()
	_bind_peace()
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
	_target_slider.value_changed.connect(func(_v: float) -> void: _update_target_readout())
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
	_unit_share_table.empty_text = "尚未解锁可配置的兵种"
	_unit_share_table.row_action.connect(_on_share_action)
	_unit_share_table.set_columns([
		{"id": "name", "label": "兵种", "kind": "text", "expand": true, "min_width": 120.0},
		{"id": "class", "label": "类别", "kind": "text", "width": 58.0, "optional": true},
		{"id": "era", "label": "时代", "kind": "text", "width": 58.0, "optional": true},
		{"id": "share", "label": "份额", "kind": "bar", "width": 170.0},
		{"id": "actions", "label": "", "kind": "actions", "width": 64.0, "sortable": false},
	], "share")
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
	_training_table.empty_text = "没有训练订单"
	_training_table.row_selected.connect(func(id) -> void: _locate_training(int(id)))
	_training_table.set_columns([
		{"id": "unit", "label": "改训", "kind": "text", "expand": true, "min_width": 96.0},
		{"id": "count", "label": "人数", "kind": "number", "width": 52.0},
		{"id": "progress", "label": "进度", "kind": "bar", "width": 122.0},
	], "progress")
	_codex_toggle.toggled.connect(func(on: bool) -> void:
		_codex_grid.visible = on
		_codex_toggle.text = "收起" if on else "展开")


func _bind_armies() -> void:
	_army_table.empty_text = "尚无野战部队"
	_army_table.row_selected.connect(_on_army_selected)
	_army_table.set_columns([
		{"id": "name", "label": "部队", "kind": "text", "expand": true, "min_width": 104.0},
		{"id": "heads", "label": "兵力", "kind": "number", "width": 60.0},
		{"id": "power", "label": "攻 / 防", "kind": "text", "width": 70.0, "optional": true},
		{"id": "morale", "label": "士气", "kind": "bar", "width": 96.0},
		{"id": "supply", "label": "补给", "kind": "bar", "width": 96.0, "optional": true},
	], "heads")
	_army_icon.set_semantic(&"military.banner", UITokens.DOSSIER_OXBLOOD)
	%CommanderIcon.set_semantic(&"family.workspace.person", UITokens.DOSSIER_INK_MUTED)
	for list in [_lot_list, _supply_list]:
		list.row_height = 24.0
		list.label_width = 96.0
		list.value_width = 54.0
	%ArmyLocate.pressed.connect(func() -> void: _locate_selected_army())
	%ArmyMove.pressed.connect(_on_army_move)
	%ArmyArea.pressed.connect(_on_army_area)
	%RadiusMinus.pressed.connect(_on_radius_step.bind(-1))
	%RadiusPlus.pressed.connect(_on_radius_step.bind(1))
	%AreaRadius.value_changed.connect(_on_radius_changed)
	_arm_radius = clampi(int(%AreaRadius.value), MIN_AREA_RADIUS, MAX_AREA_RADIUS)
	_update_radius_label()
	%ArmyStop.pressed.connect(func() -> void:
		_request(PlayerControllerScript.COMMAND_MILITARY_ARMY_STOP, {"army": _selected_army}))
	%ArmyDisband.pressed.connect(func() -> void:
		_request(PlayerControllerScript.COMMAND_MILITARY_ARMY_DISBAND, {"army": _selected_army}))
	_convoy_table.empty_text = "没有在途车队"
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
	for list in [_log_list, _front_list]:
		list.row_height = 24.0
		list.label_width = 150.0
		list.value_width = 60.0
	_front_list.selectable = true
	_front_list.row_selected.connect(_on_front_selected)
	_ceding_list.row_toggled.connect(_on_ceding_toggled)


func _bind_peace() -> void:
	%PeaceIcon.set_semantic(&"military.war.peace", UITokens.DOSSIER_OXBLOOD)
	_peace_white.toggled.connect(_on_white_toggled)
	for box in [_peace_lump, _peace_install, _peace_annex]:
		box.toggled.connect(func(on: bool) -> void:
			if on:
				_peace_white.set_pressed_no_signal(false)
			_refresh_peace_preview())
	for spin in [_lump_amount, _install_amount, _install_count]:
		spin.value_changed.connect(func(_v: float) -> void: _refresh_peace_preview())
	_peace_submit.pressed.connect(_submit_peace)
	_peace_return.pressed.connect(_on_peace_return)
	_peace_return.custom_minimum_size = SMALL_BUTTON


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
		_show_status(_vm.reason() if not _vm.reason().is_empty() else "军事事务暂不可用。", true)
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
	for grid in [%OverviewGrid, %OverviewWarGrid, %ForcesGrid, %ArmyGrid, %WarGrid,
			%WarLowerGrid]:
		(grid as GridContainer).columns = columns
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


## The KPI band is one square-set row of 66px cells, matching the technology and
## family bands; the 86px card clips at 720p once the chapter nav is above it.
## Below 520px of workspace (phone landscape) the band switches to DossierKpiCard's
## dense single-line mode, exactly like the family summary band.
func _shape_kpis() -> void:
	_apply_kpi_density()
	for card in _kpi_row.get_children():
		var kpi := card as DossierKpiCard
		if kpi.dense:
			continue
		kpi.custom_minimum_size.y = 66.0
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
	for label in [%PeacePrice]:
		(label as Label).add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	for card in _war_cards + _overview_wars:
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
	var wars: Array = data.get("wars", [])
	_overview_war_empty.visible = wars.is_empty()
	%WarLink.visible = not wars.is_empty()
	for index in range(_overview_wars.size()):
		var card: Control = _overview_wars[index]
		card.visible = index < wars.size()
		if card.visible:
			card.set_data(wars[index])


func _on_overview_war(war_id: int) -> void:
	open_peace_for(war_id)


# ── forces ──────────────────────────────────────────────────────────────

func _refresh_forces() -> void:
	_forces = _vm.build("forces")
	var mode := int(_forces.get("target_mode", 0))
	_mode_headcount.set_pressed_no_signal(mode == 0)
	_mode_budget.set_pressed_no_signal(mode == 1)
	_target_slider.max_value = HEADCOUNT_MAX if mode == 0 else BUDGET_MAX
	_target_slider.step = 100.0 if mode == 0 else 50.0
	if not _slider_dragging:
		var raw := float(_forces.get("target_value", 0))
		_target_slider.set_value_no_signal(raw if mode == 0 else raw / MilitaryViewModel.MONEY_SCALE)
	_update_target_readout()
	var policy := int(_forces.get("quality_policy", 0))
	_quality_best.set_pressed_no_signal(policy == 0)
	_quality_cheap.set_pressed_no_signal(policy == 1)
	_toggle_auto_retrain.set_pressed_no_signal(bool(_forces.get("auto_retrain", true)))
	_toggle_levy.set_pressed_no_signal(bool(_forces.get("levy_enabled", true)))
	_toggle_auto_discharge.set_pressed_no_signal(bool(_forces.get("auto_discharge", false)))
	var assigned := int(_forces.get("share_total", 0))
	if _changed("shares", _forces.shares):
		_share_bar.set_segments("兵种配置", _forces.shares,
			"已配置 %.0f%%，其余保持民兵" % (assigned / 100.0))
		_apply_share_rows(_forces.units)
	_barracks_caption.text = String(_forces.get("barracks_caption", ""))
	if _changed("barracks", _forces.barracks):
		_apply_barracks(_forces.barracks)
	var training: Array = _forces.get("training", [])
	_training_table.visible = not training.is_empty()
	_training_caption.text = String(_forces.get("training_caption", "")) if not training.is_empty() \
		else "没有训练订单"
	if _changed("training", _forces.training):
		_apply_training(_forces.training)
	if _changed("codex", _forces.codex.size()):
		_codex_grid.set_cards(_forces.codex)


func _apply_share_rows(units: Array) -> void:
	var rows: Array = []
	for unit in units:
		var bp := int(unit.bp)
		var actions: Array = []
		if bp > 0:
			actions.append({"id": "lower", "icon": "trend.down", "tooltip": "份额 −5%"})
		if bool(unit.can_raise):
			actions.append({"id": "raise", "icon": "action.add", "tooltip": "份额 +5%"})
		rows.append({
			"id": String(unit.id),
			"muted": bp == 0,
			"tooltip": "%s · %s · %s时代" % [String(unit.label), String(unit["class"]), String(unit.era)],
			"cells": {
				"name": {"text": String(unit.label), "icon": String(unit.icon)},
				"class": {"text": String(unit["class"])},
				"era": {"text": String(unit.era)},
				"share": {"text": "%.0f%%" % (bp / 100.0), "value": bp / 10000.0,
					"bar_color": unit.color, "sort": bp},
				"actions": {},
			},
			"actions": actions,
		})
	_unit_share_table.set_rows(rows)


func _apply_barracks(rows: Array) -> void:
	var table_rows: Array = []
	for row in rows:
		var paused := bool(row.paused)
		var tone := UITokens.DOSSIER_INK_MUTED if paused or bool(row.disrepair) \
			else UITokens.DOSSIER_VERDIGRIS
		table_rows.append({
			"id": int(row.cell),
			"muted": paused or bool(row.disrepair),
			"tooltip": "%s · %s\n在驻 %d / 兵额 %d · 空额 %d · 征召中 %d\n点击在地图上定位" % [
				String(row.name), String(row.status), int(row.present), int(row.posts),
				int(row.open), int(row.pending)],
			"cells": {
				"name": {"text": String(row.name),
					"icon": String(row.get("icon", "military.building.barracks")),
					"sub": "" if String(row.status) == "招募中" else String(row.status)},
				"posts": {"text": _compact_count(row.posts)},
				"fill": {"text": _compact_count(row.present), "value": float(row.fill),
					"bar_color": tone, "sort": float(row.fill)},
				"quota": {"text": _count(row.quota)},
				"actions": {},
			},
			"actions": [] if bool(row.disrepair) else [{
				"id": "resume" if paused else "pause",
				"icon": "action.play" if paused else "action.pause",
				"tooltip": "恢复招募" if paused else "暂停招募"}],
		})
	_barracks_table.set_rows(table_rows)


func _apply_training(rows: Array) -> void:
	var table_rows: Array = []
	for row in rows:
		var ready := bool(row.ready)
		table_rows.append({
			"id": int(row.id),
			"muted": not ready,
			"tooltip": "%s：%s → %s（%s）\n%s · %s" % [String(row.cell_text), String(row.from_label),
				String(row.to_label), String(row.quality_text), String(row.progress_text),
				"装备已到位" if ready else "等待装备到货"],
			"cells": {
				"unit": {"text": String(row.to_label), "icon": String(row.icon),
					"sub": String(row.cell_text)},
				"count": {"text": _count(row.count)},
				"progress": {"text": String(row.progress_text) if ready else "等装备",
					"value": float(row.progress),
					"bar_color": UITokens.DOSSIER_VERDIGRIS if ready else UITokens.DOSSIER_BRASS},
			},
		})
	_training_table.set_rows(table_rows)


func _update_target_readout() -> void:
	var budget_mode := _mode_budget.button_pressed
	var per := float(_forces.get("per_soldier_cost", 0)) / MilitaryViewModel.MONEY_SCALE
	var value := _target_slider.value
	_target_value_icon.visible = budget_mode
	_cost_icon.visible = not budget_mode and per > 0.0
	if budget_mode:
		_target_value.text = "%s / 日" % UITokens.format_compact_number_cn(value, 1)
		_cost_caption.text = "约可维持 %s 人" % (UITokens.format_compact_number_cn(
			value / per, 0) if per > 0.0 else "—")
		_cost_value.text = ""
	else:
		_target_value.text = "%s 人" % UITokens.format_compact_number_cn(value, 1)
		_cost_caption.text = "预计日军费" if per > 0.0 else "人均军费待首次结算"
		_cost_value.text = UITokens.format_compact_number_cn(value * per, 1) if per > 0.0 else ""
	MoneyDisplay.apply_icon(_target_value_icon, 22)
	MoneyDisplay.apply_icon(_cost_icon, 14)


func _on_target_drag_ended(_changed_value: bool) -> void:
	_slider_dragging = false
	_submit_target(1 if _mode_budget.button_pressed else 0)


func _on_target_mode(mode: int) -> void:
	_mode_headcount.set_pressed_no_signal(mode == 0)
	_mode_budget.set_pressed_no_signal(mode == 1)
	var per := float(_forces.get("per_soldier_cost", 0)) / MilitaryViewModel.MONEY_SCALE
	if per > 0.0:
		# Keep the same force size when switching units of the slider.
		var converted := _target_slider.value * per if mode == 1 else _target_slider.value / per
		_target_slider.max_value = BUDGET_MAX if mode == 1 else HEADCOUNT_MAX
		_target_slider.set_value_no_signal(converted)
	_update_target_readout()
	_submit_target(mode)


func _submit_target(mode: int) -> void:
	var value := _target_slider.value
	var raw := int(round(value * MilitaryViewModel.MONEY_SCALE)) if mode == 1 else int(round(value))
	_request(PlayerControllerScript.COMMAND_MILITARY_FORCE_TARGET, {"mode": mode, "value": raw})


func _on_toggle(enabled: bool, command: StringName) -> void:
	_request(command, {"enabled": enabled})


func _on_share_action(unit_id, action_id: String) -> void:
	var current := 0
	for unit in _forces.get("units", []):
		if String(unit.id) == String(unit_id):
			current = int(unit.bp)
	var free := 10000 - int(_forces.get("share_total", 0))
	var step := mini(MilitaryViewModel.SHARE_STEP_BP, free) if action_id == "raise" \
		else -mini(MilitaryViewModel.SHARE_STEP_BP, current)
	if step == 0:
		return
	_request(PlayerControllerScript.COMMAND_MILITARY_CONFIG_SHARES,
		{"unit": String(unit_id), "bp": current + step})


func _on_barracks_action(cell, action_id: String) -> void:
	_request(PlayerControllerScript.COMMAND_MILITARY_BARRACKS,
		{"cell": int(cell), "paused": action_id == "pause"})


func _locate_training(order_id: int) -> void:
	for row in _forces.get("training", []):
		if int(row.id) == order_id and int(row.cell) >= 0:
			locate_cell_requested.emit(int(row.cell))


# ── armies & logistics ─────────────────────────────────────────────────

func _refresh_armies() -> void:
	var data: Dictionary = _vm.build("armies", {"army": _selected_army})
	var rows: Array = data.get("rows", [])
	_selected_army = int(data.get("selected", 0))
	var total := 0
	for row in rows:
		total += int(row.headcount)
	_army_caption.text = "%d 支 · %s 人" % [rows.size(), _count(total)]
	_army_empty.visible = rows.is_empty()
	%ArmyGrid.visible = not rows.is_empty()
	if _changed("army_rows", rows):
		_apply_army_rows(rows)
	_army_table.selected_id = _selected_army
	_army_table.queue_redraw()
	var detail: Dictionary = data.get("detail", {})
	if not detail.is_empty() and _changed("army_detail", detail):
		_apply_army_detail(detail)
	var convoys: Array = data.get("convoys", [])
	var at_risk := convoys.filter(func(c): return float(c.risk) >= 0.25).size()
	_convoy_table.visible = not convoys.is_empty()
	_convoy_caption.text = ("%d 支 · %d 支高风险" % [convoys.size(), at_risk]) if at_risk > 0 \
		else ("%d 支" % convoys.size() if not convoys.is_empty() else "没有在途车队")
	if _changed("convoys", convoys):
		_apply_convoys(convoys)
	_procurement_label.text = String(data.get("procurement_text", ""))


func _apply_army_rows(rows: Array) -> void:
	var table_rows: Array = []
	for row in rows:
		table_rows.append({
			"id": int(row.handle),
			"tooltip": "%s · %s\n%s%s" % [String(row.name), String(row.cell_text),
				String(row.mission), ("\n" + String(row.warning)) if not String(row.warning).is_empty() else ""],
			"cells": {
				"name": {"text": String(row.name), "icon": "military.banner",
					"sub": String(row.warning) if not String(row.warning).is_empty() else String(row.cell_text),
					"color": UITokens.DOSSIER_OXBLOOD if bool(row.critical) else UITokens.DOSSIER_INK},
				"heads": {"text": _count(row.headcount), "sort": float(row.headcount)},
				"power": {"text": "%.1f / %.1f" % [float(row.attack), float(row.defense)]},
				"morale": {"text": _percent(row.morale), "value": float(row.morale),
					"bar_color": _tone(float(row.morale))},
				"supply": {"text": _percent(row.supply), "value": float(row.supply),
					"bar_color": _tone(float(row.supply))},
			},
		})
	_army_table.set_rows(table_rows)


func _apply_army_detail(detail: Dictionary) -> void:
	_army_title.text = String(detail.name)
	_army_meta.text = String(detail.meta)
	var warnings: Array = detail.get("warnings", [])
	_army_warning.visible = not warnings.is_empty()
	if not warnings.is_empty():
		_army_warning.text = String(warnings[0].label)
		_army_warning.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD
			if String(warnings[0].tone) == "risk" else UITokens.DOSSIER_BRASS)
	_lot_list.set_rows(detail.get("lots", []))
	_supply_list.set_rows(detail.get("supply", []))
	%SupplyList.get_parent().get_node("SupplyKicker").visible = not (detail.get("supply", []) as Array).is_empty()


func _apply_convoys(convoys: Array) -> void:
	var rows: Array = []
	for row in convoys:
		var risk := float(row.risk)
		rows.append({
			"id": int(row.id),
			"tooltip": "%s\n%s · 被截风险 %s · %d 日后到达" % [String(row.route), String(row.goods),
				_percent(risk), int(row.eta)],
			"cells": {
				"route": {"text": String(row.route), "icon": "military.ledger.convoy"},
				"goods": {"text": String(row.goods)},
				"risk": {"text": _percent(risk), "value": risk,
					"bar_color": UITokens.DOSSIER_OXBLOOD if risk >= 0.25
						else (UITokens.DOSSIER_BRASS if risk >= 0.08 else UITokens.DOSSIER_VERDIGRIS)},
				"eta": {"text": "%d 日" % int(row.eta), "sort": float(row.eta)},
			},
		})
	_convoy_table.set_rows(rows)


func _on_army_selected(handle) -> void:
	_selected_army = int(handle)
	_refresh_armies()


func _locate_selected_army() -> void:
	for raw in _vm.armies():
		if int(raw.get("handle", 0)) == _selected_army:
			locate_cell_requested.emit(int(raw.get("cell", -1)))


# ── 部队指令（设计 §14.2）：移动 / 军事控制 ───────────────────────────

## Try to hand the next map click to the army order. The map side owns the
## target-pick state (PlayerController.begin_military_arm_order); clicking the
## army's cell only needs a camera focus there.
func _arm_order_target_count() -> int:
	return 2 if _arm_order == "move" else 1


func _on_army_move() -> void:
	if _arm_order == "move":
		cancel_arm_order()
		return
	if _selected_army <= 0:
		_flash("先选一支自己的部队。", true)
		return
	if _player_controller == null \
			or not _player_controller.has_method("begin_military_arm_order"):
		_flash("地图指令尚未接通。", true)
		return
	var result: Dictionary = _player_controller.begin_military_arm_order(
		_selected_army, "move", 0)
	if not bool(result.get("ok", false)):
		_flash(String(result.get("message", "无法进入移动指令。")), true)
		return
	_arm_order = "move"
	_set_arm_buttons("取消移动")
	var cell := _selected_army_cell()
	if cell >= 0:
		locate_cell_requested.emit(cell)
	_flash("在地图上点目标格预览路线，再点一次确认行军。", false)


func _on_army_area() -> void:
	if _arm_order == "area":
		cancel_arm_order()
		return
	if _selected_army <= 0:
		_flash("先选一支自己的部队。", true)
		return
	if _player_controller == null \
			or not _player_controller.has_method("begin_military_arm_order"):
		_flash("地图指令尚未接通。", true)
		return
	var radius := _arm_radius
	var result: Dictionary = _player_controller.begin_military_arm_order(
		_selected_army, "area", radius)
	if not bool(result.get("ok", false)):
		_flash(String(result.get("message", "无法进入军事控制指令。")), true)
		return
	_arm_order = "area"
	_set_arm_buttons("取消控制")
	_flash("在地图上点中心格，半径 %d 格设为军事控制区。" % radius, false)


## Leaving the order clears it on the map side too: PlayerController owns the
## target-pick state, and a stale order would swallow the next map click.
func cancel_arm_order() -> void:
	if not _arm_order.is_empty() and _player_controller != null \
			and _player_controller.has_method("cancel_military_arm_order"):
		_player_controller.call("cancel_military_arm_order")
	_arm_order = ""
	_set_arm_buttons()


func arm_order() -> String:
	return _arm_order


func _set_arm_buttons(mode_text: String = "") -> void:
	_army_move.text = mode_text if mode_text == "取消移动" else "移动"
	_army_area.text = mode_text if mode_text == "取消控制" else "军事控制"
	_army_move.button_pressed = mode_text == "取消移动"
	_army_area.button_pressed = mode_text == "取消控制"


func _on_radius_step(delta: int) -> void:
	_arm_radius = clampi(_arm_radius + delta, MIN_AREA_RADIUS, MAX_AREA_RADIUS)
	%AreaRadius.set_value_no_signal(float(_arm_radius))
	_update_radius_label()


func _on_radius_changed(value: float) -> void:
	_arm_radius = clampi(int(round(value)), MIN_AREA_RADIUS, MAX_AREA_RADIUS)
	_update_radius_label()


func area_radius() -> int:
	return _arm_radius


func _update_radius_label() -> void:
	%RadiusMinus.disabled = _arm_radius <= MIN_AREA_RADIUS
	%RadiusPlus.disabled = _arm_radius >= MAX_AREA_RADIUS
	%AreaRadius.tooltip_text = "军事控制半径 %d 格（上限 6 格）" % _arm_radius


func _selected_army_cell() -> int:
	for raw in _vm.armies():
		if int(raw.get("handle", 0)) == _selected_army:
			return int(raw.get("cell", -1))
	return -1


func selected_army() -> int:
	return _selected_army


func set_selected_army(army_handle: int) -> void:
	_selected_army = army_handle
	if is_node_ready():
		_refresh_armies()


func _on_convoy_selected(convoy_id) -> void:
	for raw in _vm.snapshot().get("convoys", []):
		if int(raw.get("id", 0)) == int(convoy_id):
			locate_cell_requested.emit(int(raw.get("current_cell", -1)))


# ── war & peace ─────────────────────────────────────────────────────────

func _refresh_war() -> void:
	var data: Dictionary = _vm.build("war", {"war": _selected_war, "ceding": _ceded_checked})
	_war_data = data
	var wars: Array = data.get("wars", [])
	_selected_war = int(data.get("selected", 0))
	_war_empty.visible = wars.is_empty()
	%WarGrid.visible = not wars.is_empty()
	for index in range(_war_cards.size()):
		var card: Control = _war_cards[index]
		card.visible = index < wars.size()
		if card.visible:
			card.set_data(wars[index])
			card.modulate = Color.WHITE if int(wars[index].id) == _selected_war \
				else Color(1, 1, 1, 0.72)
	_refresh_declare(data)
	_refresh_fronts(data)
	_refresh_log(data)
	_refresh_ceding(data)
	var detail: Dictionary = data.get("detail", {})
	_peace_editor.visible = not detail.is_empty()
	if detail.is_empty():
		return
	_war_score = float(detail.get("score", 0.0))
	_peace_title.text = "与%s议和" % String(detail.get("enemy_name", "敌国"))
	_peace_score.text = "当前战争分 %s" % String(detail.get("score_text", "0"))
	_refresh_peace_preview()


# ── 宣战：邻国候选（真实领土图 + Country 名称）──────────────────────────

func _refresh_declare(data: Dictionary) -> void:
	var rows: Array = data.get("declare", [])
	_declare_caption.text = "%d 个邻国" % rows.size() if not rows.is_empty() else ""
	_declare_empty.visible = rows.is_empty()
	_declare_empty.text = "邻接领土图上没有其他国家。" if _vm.session_bound() \
		else "未能读取领土邻接：本面板没有接到世界数据。"
	if _changed("declare", rows):
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
		_declare_table.set_rows(table_rows)


func _on_war_card_input(event: InputEvent, card: Control) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_selected_war = int(card.war_id)
		_refresh_war()


func _on_declare_selected(row_id) -> void:
	var row := _declare_row(int(row_id))
	if row.is_empty():
		return
	if not bool(row.can_declare):
		_flash("%s 目前无法宣战：%s" % [String(row.name), String(row.reason)], true)
		return
	_request(PlayerControllerScript.COMMAND_MILITARY_WAR_DECLARE,
		{"target": int(row.handle)})


func _on_declare_action(row_id, action_id: String) -> void:
	if action_id == "declare":
		_on_declare_selected(row_id)


func _declare_row(row_id: int) -> Dictionary:
	for row in _war_data.get("declare", []):
		if int(row.id) == row_id:
			return row
	return {}


# ── 战线与战报 ──────────────────────────────────────────────────────────

func _refresh_fronts(data: Dictionary) -> void:
	var rows: Array = data.get("fronts", [])
	_front_empty.visible = rows.is_empty()
	# Three states, not two: the probe answering with an empty set means the
	# country is at peace; no probe at all means the panel has no data source.
	if not bool(data.get("front_source", true)):
		_front_empty.text = "战线需要军事运行时的推送。"
	else:
		_front_empty.text = "当前没有接触中的战线。"
	if _changed("fronts", rows):
		_front_list.set_rows(rows)


func _refresh_log(data: Dictionary) -> void:
	var rows: Array = data.get("log", [])
	_log_empty.visible = rows.is_empty()
	_log_empty.text = "最近没有会战记录。" if _event_log_available() \
		else "战报需要军事运行时的事件流。"
	var list_rows: Array = []
	for row in rows:
		var label := String(row.text)
		var detail := String(row.detail)
		if not detail.is_empty():
			label = "%s · %s" % [label, detail]
		list_rows.append({
			"id": int(row.id),
			"label": "%d日 %s" % [int(row.day), String(row.kind)],
			"text": label,
			"value": clampf(float(row.day) / maxf(1.0, float(_model.get("current_day", 1))),
				0.0, 1.0),
			"color": UITokens.DOSSIER_OXBLOOD if String(row.team) == "敌方"
				else UITokens.DOSSIER_SLATE,
			"text_color": UITokens.DOSSIER_INK,
			"tooltip": label,
		})
	if _changed("battle_log", list_rows):
		_log_list.set_rows(list_rows)


func _event_log_available() -> bool:
	return _vm.event_log_available()


func _on_front_selected(row_id) -> void:
	for row in _war_data.get("fronts", []):
		if String(row.id) == String(row_id):
			locate_cell_requested.emit(int(row.cell))
			return


# ── 议和：占领格交还 / 割让（设计 §12.3）──────────────────────────────
func _refresh_ceding(data: Dictionary) -> void:
	var ceded: Dictionary = data.get("ceded", {})
	var rows: Array = ceded.get("rows", [])
	_ceding_list.set_rows(rows, _ceded_checked)
	_ceding_list.visible = not rows.is_empty()
	_cession_rule.visible = not rows.is_empty()
	_peace_return.visible = not rows.is_empty()
	_ceding_caption.visible = not rows.is_empty()
	_ceding_caption.text = "我方占领其 %d 格，已选 %d 格" % [int(ceded.get("total", 0)),
		int(ceded.get("checked", 0))]


func _on_ceding_toggled(_row_id, _checked: bool) -> void:
	_refresh_peace_preview()


func _refresh_peace_preview() -> void:
	_install_total.text = UITokens.format_compact_number_cn(
		_install_amount.value * _install_count.value, 1)
	var terms := _peace_terms()
	var result: Dictionary = _vm.evaluate_peace(_selected_war, _war_score, terms)
	_peace_price.text = "条款总价 %.0f 分" % float(result.get("price", 0.0))
	var band := int(result.get("band", -1))
	_peace_band.text = "接受倾向 %s" % (MilitaryViewModel.BAND_LABELS[band] if band >= 0 else "—")
	_peace_band.add_theme_color_override("font_color", [UITokens.DOSSIER_OXBLOOD,
		UITokens.DOSSIER_BRASS, UITokens.DOSSIER_VERDIGRIS][band] if band >= 0
		else UITokens.DOSSIER_INK_MUTED)
	_peace_submit.disabled = terms.is_empty() or _selected_war <= 0
	_peace_submit.tooltip_text = "先勾选条款" if terms.is_empty() else "提交给对方，次日答复"


func _submit_peace() -> void:
	var terms := _peace_terms()
	if terms.is_empty() or _selected_war <= 0:
		return
	_request(PlayerControllerScript.COMMAND_MILITARY_PEACE_PROPOSE,
		{"war_id": _selected_war, "terms": terms})


func _peace_terms() -> Array:
	var terms: Array = []
	if _peace_white.button_pressed:
		terms.append({"kind": "white"})
	if _peace_lump.button_pressed:
		terms.append({"kind": "lump_sum", "amount": _lump_amount.value})
	if _peace_install.button_pressed:
		terms.append({"kind": "installments", "amount": _install_amount.value,
			"n": int(_install_count.value)})
	if _peace_annex.button_pressed:
		terms.append({"kind": "annex"})
	return terms


func _on_white_toggled(on: bool) -> void:
	if on:
		for box in [_peace_lump, _peace_install, _peace_annex]:
			box.set_pressed_no_signal(false)
	_refresh_peace_preview()


## 交还：tick the occupied enemy cells the player picked in the 战争 chapter.
func _on_peace_return() -> void:
	var ceded: Dictionary = _war_data.get("ceded", {})
	var cells: Array = ceded.get("cells", [])
	if cells.is_empty():
		_flash("先在上面的占领格清单里勾选要交还的格子。", true)
		return
	var packed := PackedInt32Array()
	for cell in cells:
		packed.append(int(cell))
	target_cells_requested.emit(packed)
	_flash("已在地图标出 %d 格交还给对方的领土。" % packed.size(), false)


# ── commands ────────────────────────────────────────────────────────────

func _request(id: StringName, args: Dictionary) -> void:
	if _player_controller == null or not _player_controller.has_method("request_command"):
		_flash("军事命令需要在正式对局中下达。", true)
		return
	var result: Dictionary = _player_controller.request_command(id, args)
	if bool(result.get("ok", false)):
		_flash(String(result.get("message", "已下达，次日生效。")), false)
	else:
		_flash(String(result.get("message", "命令被拒绝。")), true)


func _flash(text: String, danger: bool) -> void:
	_flash_text = text
	_show_status(text, danger)
	get_tree().create_timer(4.0).timeout.connect(func() -> void:
		if _flash_text == text:
			_flash_text = ""
			_status_label.visible = false)


func _show_status(text: String, danger: bool) -> void:
	_status_label.text = text
	_status_label.visible = not text.is_empty()
	_status_label.theme_type_variation = &"PKDangerText" if danger else &"PKDossierCaption"


static func _count(value) -> String:
	return UITokens.format_compact_number_cn(float(value), 1)


## Short form for dense table cells: 4310 -> 4310, 12500 -> 1.3万.
static func _compact_count(value) -> String:
	return UITokens.format_compact_number_cn(float(value), 0 if float(value) < 10000.0 else 1)


static func _percent(value) -> String:
	return "%d%%" % int(round(clampf(float(value), 0.0, 1.0) * 100.0))


static func _tone(value: float) -> Color:
	if value < 0.35:
		return UITokens.DOSSIER_OXBLOOD
	return UITokens.DOSSIER_BRASS if value < 0.6 else UITokens.DOSSIER_VERDIGRIS
