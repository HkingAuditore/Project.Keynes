extends Control
class_name MilitaryPeaceWindow

## Dedicated peace-negotiation window (design §12.3 / §14.3).
##
## It is deliberately NOT a modal: the panel docks on the left, the map stays
## visible and every map click becomes a cession pick while the window is open.
## This mirrors ColonizationPlannerPanel's "map-first editing surface" contract:
## the panel consumes map clicks, Esc leaves, the right mouse button stays a
## camera pan, and no dimmer / no pause is introduced.
##
## Everything the window draws comes from MilitaryPeaceViewModel (read-only).
## This script owns only the UI draft (which terms are ticked, which cells are
## picked) and turns it into `peace.propose` terms — it never mutates game state.
## All controls live in military_peace_window.tscn; runtime code only writes
## values (see tests/ui/ui_scene_structure_test.gd).

const PeaceViewModelScript = preload("res://scripts/ui/military_peace_view_model.gd")
const MilitaryViewModelScript = preload("res://scripts/ui/military_view_model.gd")
const TouchUI = preload("res://scripts/ui/touch_ui.gd")

signal closed()
## The player stamped the deal. GameUIManager turns this into the command.
signal submit_requested(payload: Dictionary)
## Draft cell set changed: the map must repaint the picked cells.
signal draft_changed(cells: PackedInt32Array)
## A war-situation row asked to be framed on the map (camera only, no selection).
signal locate_cell_requested(cell: int)

const REFRESH_INTERVAL_MSEC := 200
const PANEL_MIN_WIDTH := 560.0
const PANEL_MAX_WIDTH := 760.0
## Below this the KPI band stacks 2×2 instead of 1×4.
const NARROW_WIDTH := 640.0
const CEDE_ROW_HEIGHT := 22.0
const CEDE_LIST_MIN := 48.0
## Keep the scroll viewport a little taller than the rows it shows: the last row's
## descenders otherwise land exactly on the clip line and read as cut off.
const CEDE_LIST_PAD := 8.0
## Four rows are enough to read the draft; the map is the real picker.
const CEDE_LIST_MAX := 104.0
## Native refuses a repeat proposal for 30 days after a rejection
## (military_core_war.cpp: `day - last_rejected_offer < 30`). Until the snapshot
## exports that day, the window keeps the same window locally from the submit day.
const PEACE_COOLDOWN_DAYS := 30

var _war_id := 0
var _auto_block_text := ""
var _model: Dictionary = {}
var _pvm = PeaceViewModelScript.new()
var _controller = null
var _draft: Dictionary = {}
var _data: Dictionary = {}
var _ready_done := false
var _last_refresh_ms := -REFRESH_INTERVAL_MSEC
var _refresh_pending := false
var _refresh_timer: Timer
var _submitted_day := -1
var _cooldown_until := -1
var _status_text := ""
var _status_danger := false
var _narrow := false
var _kpis: Array = []
var _logs: Array = []

@onready var _peace_icon: IconBadge = %PeaceIcon
@onready var _title: Label = %PeaceTitle
@onready var _close: Button = %CloseButton
@onready var _subtitle: Label = %Subtitle
@onready var _status: Label = %Status
@onready var _scroll: ScrollContainer = %Scroll
@onready var _kpi_grid: GridContainer = %KpiGrid
@onready var _kpi0: Control = %Kpi0
@onready var _kpi1: Control = %Kpi1
@onready var _kpi2: Control = %Kpi2
@onready var _kpi3: Control = %Kpi3
@onready var _losses: Label = %Losses
@onready var _parts: DossierBarList = %PartsList
@onready var _log0: Label = %Log0
@onready var _log1: Label = %Log1
@onready var _log2: Label = %Log2
@onready var _terms_price: Label = %TermsPrice
@onready var _white: CheckBox = %PeaceWhite
@onready var _cede_count: Label = %CedeCount
@onready var _cede_scroll: ScrollContainer = %CedeScroll
@onready var _ceding_list: MilitaryToggleList = %CedingList
@onready var _cede_caption: Label = %CedeCaption
@onready var _lump: CheckBox = %PeaceLump
@onready var _lump_amount: SpinBox = %LumpAmount
@onready var _install: CheckBox = %PeaceInstall
@onready var _install_amount: SpinBox = %InstallAmount
@onready var _install_count: SpinBox = %InstallCount
@onready var _install_total: Label = %InstallTotal
@onready var _annex: CheckBox = %PeaceAnnex
@onready var _annex_hint: Label = %AnnexHint
@onready var _footer_readout: Label = %FooterReadout
@onready var _footer_band: Label = %FooterBand
@onready var _submit: Button = %Submit


func _ready() -> void:
	if _ready_done:
		return
	_ready_done = true
	_peace_icon.set_semantic(&"military.war.peace", UITokens.DOSSIER_OXBLOOD)
	IconButton.apply(_close, &"action.close", IconButton.SMALL, "关闭议和")
	_kpis = [_kpi0, _kpi1, _kpi2, _kpi3]
	for card in _kpis:
		var kpi := card as DossierKpiCard
		kpi.dense = true
		kpi.show_divider = false
	_logs = [_log0, _log1, _log2]
	for label in _logs:
		(label as Label).visible = false
	_parts.diverging = true
	_parts.row_height = CEDE_ROW_HEIGHT
	_parts.label_width = 64.0
	_parts.value_width = 44.0
	_parts.visible = false
	_ceding_list.row_toggled.connect(_on_row_toggled)
	_white.toggled.connect(_on_white_toggled)
	_lump.toggled.connect(_on_term_toggled.bind("lump"))
	_install.toggled.connect(_on_term_toggled.bind("install"))
	_annex.toggled.connect(_on_term_toggled.bind("annex"))
	for spin in [_lump_amount, _install_amount, _install_count]:
		(spin as SpinBox).value_changed.connect(_on_amount_changed)
	_close.pressed.connect(close_panel)
	_submit.pressed.connect(_on_submit)
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	add_child(_refresh_timer)
	_refresh_timer.timeout.connect(_flush_pending_refresh)
	_draft = PeaceViewModelScript.empty_draft()
	if is_inside_tree() and get_viewport() != null:
		get_viewport().size_changed.connect(_layout)
	visible = false


# ── shell API ────────────────────────────────────────────────────────────

func set_player_controller(controller) -> void:
	_controller = controller


func is_open() -> bool:
	return visible


func open(war_id: int, model: Dictionary) -> void:
	if not _ready_done:
		_ready()
	_war_id = int(war_id)
	_model = model if model != null else {}
	_pvm.configure(_model)
	_draft = PeaceViewModelScript.empty_draft()
	_data = {}
	_submitted_day = -1
	_cooldown_until = -1
	_status_text = ""
	_status_danger = false
	_auto_block_text = ""
	visible = true
	_layout()
	_refresh_now()
	_paint_candidates()
	UIAnimation.fade_slide_in(self, Vector2(-24.0, 0.0), UITokens.ANIM_MED)


## Daily / command-settle refresh: 200 ms coalescing, same contract as the
## military workspace. Values are rewritten, nodes are never rebuilt.
func refresh_model(model: Dictionary) -> void:
	if not visible or not _ready_done:
		return
	_model = model if model != null else {}
	_pvm.configure(_model)
	var now := Time.get_ticks_msec()
	if now - _last_refresh_ms < REFRESH_INTERVAL_MSEC:
		if not _refresh_pending:
			_refresh_pending = true
			_refresh_timer.start(
				float(REFRESH_INTERVAL_MSEC - (now - _last_refresh_ms)) / 1000.0)
		return
	_refresh_now()


func close_panel() -> void:
	if not visible:
		return
	visible = false
	if _refresh_timer != null:
		_refresh_timer.stop()
	_refresh_pending = false
	_clear_highlights()
	closed.emit()


func set_command_result(result: Dictionary) -> void:
	var ok := bool(result.get("ok", false))
	if ok:
		_submitted_day = maxi(_submitted_day, _current_day())
		_set_status("和约已递交，次日答复。", false)
	else:
		_set_status(String(result.get("message", "议和未递交：原因未返回，请稍后重试。")), true)
	_refresh_now()


## The map click entry. Returns true when the click was consumed by the draft,
## false only when the window is not the active surface.
func handle_map_cell(cell: int) -> bool:
	if not visible or cell < 0:
		return false
	var rows: Array = _data.get("cession", {}).get("rows", [])
	for row_value in rows:
		var row: Dictionary = row_value
		if int(row.get("id", -1)) == cell:
			_toggle_cell(cell)
			return true
	_set_status("此格不可交割：只有我方占领的敌国领土能写进和约。", true)
	return true


func draft_terms() -> Array:
	return PeaceViewModelScript.peace_terms(_draft)


func draft_cells() -> PackedInt32Array:
	return PeaceViewModelScript.selected_cells(_draft)


func candidate_cells() -> PackedInt32Array:
	var cells := PackedInt32Array()
	var rows: Array = _data.get("cession", {}).get("rows", [])
	for row_value in rows:
		var row: Dictionary = row_value
		cells.append(int(row.get("id", -1)))
	return cells


func debug_snapshot() -> Dictionary:
	return {
		"war_id": _war_id,
		"day": _current_day(),
		"draft": _draft.duplicate(true),
		"terms": draft_terms(),
		"candidates": candidate_cells(),
		"selected": draft_cells(),
		"submitted_day": _submitted_day,
		"cooldown_until": _cooldown_until,
		"submit_blocked": _blocked_reason(),
		"status": _status_text,
	}


# ── layout ───────────────────────────────────────────────────────────────

func _layout() -> void:
	if not is_inside_tree() or not _ready_done:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	# While the open tween runs it owns `position`; writing the resting offset here
	# would cancel the slide halfway (same guard the inspector uses).
	if not has_meta("_ui_active_tween"):
		position = Vector2(UITokens.ARCHIVE_EDGE_INSET, PlayerTopBar.BAR_HEIGHT + 4.0)
	var touch := TouchUI.is_touch()
	var width := roundf(viewport_size.x * (0.56 if touch else 0.42))
	width = clampf(width, 560.0 if touch else PANEL_MIN_WIDTH, PANEL_MAX_WIDTH)
	if touch:
		width = minf(width, maxf(320.0, viewport_size.x - UITokens.ARCHIVE_EDGE_INSET * 2.0))
	size = Vector2(width, maxf(0.0, viewport_size.y - position.y
		- CountryActionBar.BAR_HEIGHT - UITokens.ARCHIVE_EDGE_INSET))
	# 720p docking only leaves ~380 px for the scroll; two KPIs in one row keep the
	# whole terms block above the fold, the other two numbers move into the
	# 战况 header line.
	_narrow = width < NARROW_WIDTH
	var columns := 2 if _narrow else 4
	if _kpi_grid.columns != columns:
		_kpi_grid.columns = columns


# ── refresh ──────────────────────────────────────────────────────────────

func _flush_pending_refresh() -> void:
	if not _refresh_pending:
		return
	_refresh_pending = false
	_refresh_now()


func _refresh_now() -> void:
	if not visible or not _ready_done:
		return
	_last_refresh_ms = Time.get_ticks_msec()
	_layout()
	var data: Dictionary = _pvm.peace_model(_war_id, _draft)
	_data = data
	if not bool(data.get("ok", false)):
		_show_ended(String(data.get("reason", "该战争已经结束。")))
		return
	_fill_war(data)
	_fill_terms(data)
	_fill_readout(data)
	_track_cooldown(data)


func _fill_war(data: Dictionary) -> void:
	var war: Dictionary = data.get("war", {})
	var situation: Dictionary = data.get("situation", {})
	_title.text = "与%s议和" % String(war.get("enemy_name", "敌国"))
	_subtitle.text = "已战 %d 日 · %s · 伤亡 %s : %s" % [
		int(situation.get("days", 0)), String(war.get("role", "")),
		_compact(float(war.get("our_losses", 0))),
		_compact(float(war.get("enemy_losses", 0)))]
	var kpis: Array = situation.get("kpis", [])
	var shown := 2 if _narrow else kpis.size()
	for index in range(_kpis.size()):
		var card := _kpis[index] as DossierKpiCard
		card.visible = index < shown
		if card.visible:
			card.set_metric(kpis[index])
	var enemy_owned := int(situation.get("enemy_owned", -1))
	var front_count := int(situation.get("front_count", 0))
	var tail := "全境沦陷" if bool(situation.get("fully_occupied", false)) \
		else "%d 处战线" % front_count
	_losses.text = "敌土 %d 格 · %s" % [enemy_owned, tail] if enemy_owned >= 0 else tail
	var parts: Array = situation.get("parts", [])
	_parts.visible = not parts.is_empty()
	if _parts.visible:
		_parts.set_rows(parts)
	_paint_log(situation.get("log", []))


func _paint_log(rows: Array) -> void:
	for index in range(_logs.size()):
		var label := _logs[index] as Label
		label.visible = index < rows.size()
		if label.visible:
			var row: Dictionary = rows[index]
			label.text = "第 %d 日 · %s · %s" % [int(row.get("day", 0)),
				String(row.get("kind", "战事")), String(row.get("text", ""))]


func _fill_terms(data: Dictionary) -> void:
	var cession: Dictionary = data.get("cession", {})
	var annex: Dictionary = data.get("annex", {})
	var day := int(data.get("day", -1))
	var total := int(cession.get("total", 0))
	var checked := int(cession.get("checked", 0))
	_white.set_pressed_no_signal(bool(_draft.get("white", false)))
	_lump.set_pressed_no_signal(bool(_draft.get("lump", false)))
	_install.set_pressed_no_signal(bool(_draft.get("install", false)))
	_annex.set_pressed_no_signal(bool(_draft.get("annex", false)))
	_lump_amount.editable = bool(_draft.get("lump", false))
	_install_amount.editable = bool(_draft.get("install", false))
	_install_count.editable = bool(_draft.get("install", false))
	_install_total.text = "总额 %s" % _compact(
		_install_amount.value * _install_count.value) if bool(_draft.get("install", false)) else ""
	_annex.disabled = not bool(annex.get("can", false))
	_annex_hint.text = "" if bool(annex.get("can", false)) else (
		"需对方全境沦陷且由我方独占" if not bool(annex.get("fully_occupied", false))
		else "需我方独占其全部领土")
	_annex.tooltip_text = _annex_hint.text
	_cede_count.text = "%d / %d 格" % [checked, total] if total > 0 else "无可交割地块"
	_cede_caption.text = _cede_caption_text(cession)
	_cede_caption.remove_theme_color_override("font_color")
	if total > 0 and checked == 0:
		_cede_caption.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	var checked_map := {}
	for cell in cession.get("cells", PackedInt32Array()):
		checked_map[int(cell)] = true
	_ceding_list.set_rows(cession.get("rows", []), checked_map)
	_cede_scroll.custom_minimum_size.y = clampf(
		CEDE_ROW_HEIGHT * float(cession.get("rows", []).size()) + CEDE_LIST_PAD,
		CEDE_LIST_MIN, CEDE_LIST_MAX)
	_install_count.tooltip_text = "每 30 日一期，共 2–12 期" if day >= 0 else ""


func _cede_caption_text(cession: Dictionary) -> String:
	var total := int(cession.get("total", 0))
	if total <= 0:
		return "我方尚未占领敌国领土；白和平与赔款仍可递交。"
	var text := "点地图上的斜纹占领格增删；未勾选的格会随和约自动交还。"
	if bool(cession.get("capped", false)):
		text += " 清单只列前 %d 格，其余请在地图上点选。" % int(cession.get("rows", []).size())
	return text


func _fill_readout(data: Dictionary) -> void:
	var terms: Dictionary = data.get("terms", {})
	var price := float(terms.get("price", 0.0))
	var band := int(terms.get("band", -1))
	var estimated := bool(terms.get("estimated", false))
	_terms_price.text = "条款总价 %s 分%s" % [_compact(price), "（估算）" if estimated else ""]
	if estimated:
		_footer_readout.text = "对方意愿暂不可读，仍可递交，由对方裁断"
	elif float(terms.get("willing", -1.0)) >= 0.0:
		_footer_readout.text = "意愿 %s · 分差 %s" % [
			_compact(float(terms.get("willing", 0.0))),
			_compact(float(terms.get("gap", 0.0)))]
	else:
		_footer_readout.text = ""
	_footer_band.visible = band >= 0
	if band >= 0:
		_footer_band.text = MilitaryViewModelScript.BAND_LABELS[band]
		_footer_band.add_theme_color_override("font_color",
			[UITokens.DOSSIER_OXBLOOD, UITokens.DOSSIER_BRASS, UITokens.DOSSIER_VERDIGRIS][band])
	var blocked := _blocked_reason()
	_submit.disabled = blocked != ""
	_submit.tooltip_text = blocked if not blocked.is_empty() else "提交给对方，次日答复"
	# 禁用原因常显；只接管自己写过的状态文字，避免盖住「递交中 / 冷却」等回执，
	# 也避免 _set_status() 回写 _status_text 后旧的禁用原因清不掉。
	if not blocked.is_empty():
		if _status_text.is_empty() or _status_text == _auto_block_text:
			_auto_block_text = blocked
			_set_status(blocked, true)
		else:
			_set_status(_status_text, _status_danger)
	elif _status_text == _auto_block_text and not _auto_block_text.is_empty():
		_auto_block_text = ""
		_set_status("", false)
	else:
		_set_status(_status_text, _status_danger)


func _track_cooldown(data: Dictionary) -> void:
	var day := int(data.get("day", -1))
	if _submitted_day < 0 or day <= _submitted_day:
		return
	if _cooldown_until <= day:
		_cooldown_until = _submitted_day + PEACE_COOLDOWN_DAYS
		_set_status("对方未接受这次和议：第 %d 日后可再次提出。" % _cooldown_until, true)


func _blocked_reason() -> String:
	if _war_id <= 0:
		return "没有选中的战争。"
	if not _data.is_empty() and not bool(_data.get("ok", true)):
		return String(_data.get("reason", "该战争已经结束。"))
	var day := _current_day()
	if _submitted_day >= 0 and day <= _submitted_day:
		return "今日已递交，次日答复。"
	if _submitted_day >= 0 and _cooldown_until > day:
		return "对方已拒绝：第 %d 日后可再次提出。" % _cooldown_until
	if draft_terms().is_empty():
		return "先勾选条款（白和平也是一份和约）。"
	if _controller == null:
		return "议和命令暂未接通，请稍后重试。"
	return ""


func _show_ended(reason: String) -> void:
	_title.text = "议和"
	_subtitle.text = reason
	for card in _kpis:
		(card as Control).visible = false
	_losses.text = ""
	_parts.visible = false
	for label in _logs:
		(label as Label).visible = false
	_ceding_list.set_rows([], {})
	_cede_count.text = ""
	_cede_caption.text = ""
	_terms_price.text = ""
	_footer_readout.text = ""
	_footer_band.visible = false
	_submit.disabled = true
	_submit.tooltip_text = reason
	if _submitted_day >= 0:
		_set_status("和约已生效，战争结束。", false)
	else:
		_set_status(reason, true)
	_clear_highlights()


# ── draft ────────────────────────────────────────────────────────────────

func _on_white_toggled(on: bool) -> void:
	_draft["white"] = on
	if on:
		_draft["annex"] = false
		_draft["lump"] = false
		_draft["install"] = false
		_draft["ceding"] = {}
		_paint_draft_highlights()
	_draft_touched()


func _on_term_toggled(on: bool, key: String) -> void:
	_draft[key] = on
	if on:
		_draft["white"] = false
	_draft_touched()


func _on_amount_changed(_value: float) -> void:
	_draft["amount"] = _lump_amount.value
	_draft["install_amount"] = _install_amount.value
	_draft["install_count"] = int(_install_count.value)
	_draft_touched()


func _on_row_toggled(row_id: Variant, checked: bool) -> void:
	var ceding := _draft.get("ceding", {}) as Dictionary
	if checked:
		ceding[int(row_id)] = true
		_draft["white"] = false
	else:
		ceding.erase(int(row_id))
	_draft["ceding"] = ceding
	_draft_touched()


func _toggle_cell(cell: int) -> void:
	var ceding := _draft.get("ceding", {}) as Dictionary
	if ceding.has(cell):
		ceding.erase(cell)
	else:
		ceding[cell] = true
		_draft["white"] = false
	_draft["ceding"] = ceding
	_draft_touched()


func _draft_touched() -> void:
	_refresh_now()
	_paint_draft_highlights()
	draft_changed.emit(draft_cells())


# ── map highlights ───────────────────────────────────────────────────────

func _paint_candidates() -> void:
	if _controller != null and _controller.has_method("highlight_peace_candidates"):
		_controller.call("highlight_peace_candidates", candidate_cells())


func _paint_draft_highlights() -> void:
	if _controller != null and _controller.has_method("highlight_peace_draft"):
		_controller.call("highlight_peace_draft", draft_cells())


func _clear_highlights() -> void:
	if _controller != null and _controller.has_method("clear_peace_highlights"):
		_controller.call("clear_peace_highlights")


# ── submit ───────────────────────────────────────────────────────────────

func _on_submit() -> void:
	var blocked := _blocked_reason()
	if not blocked.is_empty():
		_set_status(blocked, true)
		return
	var terms := draft_terms()
	if terms.is_empty():
		return
	_set_status("递交中…", false)
	submit_requested.emit({"war_id": _war_id, "terms": terms})


func _set_status(text: String, danger: bool) -> void:
	_status_text = text
	_status_danger = danger
	if _status == null:
		return
	_status.text = text
	_status.visible = not text.is_empty()
	_status.theme_type_variation = &"PKDangerText" if danger else &"PKDossierCaption"


func _current_day() -> int:
	return int(_model.get("current_day", -1))


static func _compact(value: float) -> String:
	return UITokens.format_compact_number_cn(value, 0 if absf(value) >= 100.0 else 1)
