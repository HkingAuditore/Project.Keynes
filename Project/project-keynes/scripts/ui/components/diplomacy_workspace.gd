extends Control
class_name DiplomacyWorkspace

## 国家事务 · 外交章（三个章节：总览 / 国家 / 战事）。
##
## 这一页是「账簿 + 档案」，不是命令台：一行说明世界上有谁、在打谁，选中之后右侧
## 一张撕纸档案补全细节，动作只有三件——定位、宣战、议和。议和不在这里编辑条款，
## 它把战争交给停靠的 `MilitaryPeaceWindow`（同一个出口，和军事章的「议和」一致）。
##
## 所有数值来自 `DiplomacyViewModel`；命令一律经 `PlayerController.request_command`。
## 日推进只改写既有节点的值，节点树在 `_ready` 之后不再增删（同军务面板的硬约束）。
##
## 材料沿用军务一脉：`MilitaryFramePanel` 象牙纸 + 九宫撕边、`PKPaperNote` 撕纸便笺、
## `PKPaperTag` 剪纸标签、`MilitaryPaperRule` 手绘分隔。地图点击由此页发出的
## `locate_cell_requested` 转交给外壳。

## 把镜头落到某个格（本国领土 / 该国首格 / 战线所在格）。
signal locate_cell_requested(cell: int)
## 为某场战争开议和窗口。外壳直接转给 GameUIManager.open_military_peace()。
signal peace_negotiation_requested(war_id: int)

const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const VIEW_MODEL_SCRIPT = preload("res://scripts/ui/diplomacy_view_model.gd")

const LIVE_REFRESH_INTERVAL_MSEC := 200
const NARROW_WIDTH := 820.0
## 低于这个工作区高度，KPI 纸带切成单行密排。
const SHORT_HEIGHT := 520.0
## 章节页签是按标签宽度量出来的（DossierChapterNav 在放不下时退成纯图标）。
const CHAPTER_NAV_PAD := 22.0
const CHAPTER_NAV_MIN_WIDTH := 300.0

var _vm = VIEW_MODEL_SCRIPT.new()
var _model: Dictionary = {}
var _chapter := "overview"
var _compact := false
var _short := false
var _narrow := false
var _player_controller = null
var _last_refresh_ms := -LIVE_REFRESH_INTERVAL_MSEC
var _refresh_pending := false
var _refresh_timer: Timer
var _scroll_by_chapter := {}
var _signatures: Dictionary = {}
var _selected_country := 0
var _selected_war := 0
var _overview: Dictionary = {}
var _countries: Dictionary = {}
var _wars: Dictionary = {}
var _flash_text := ""
## 刚递交过宣战的国家槽位：命令次日生效，这一天里按钮保持禁用，避免连点。
var _declare_pending_slot := -1
var _declare_pending_day := -1

@onready var _chapter_nav: DossierChapterNav = %ChapterNav
@onready var _status_label: Label = %StatusLabel
@onready var _viewport: ScrollContainer = %PageViewport
@onready var _kpi_strip: PanelContainer = %KpiStrip
@onready var _kpi_row: HBoxContainer = %KpiRow
@onready var _pages := {
	"overview": %OverviewPage,
	"countries": %CountriesPage,
	"wars": %WarsPage,
}

@onready var _wars_caption: Label = %WarsCaption
@onready var _overview_war_table: DossierLedgerTable = %OverviewWarTable
@onready var _wars_empty: Label = %WarsEmpty
@onready var _powers_caption: Label = %PowersCaption
@onready var _power_list: DossierBarList = %PowerList
@onready var _insights: InsightList = %Insights

@onready var _roster_caption: Label = %RosterCaption
@onready var _roster_table: DossierLedgerTable = %RosterTable
@onready var _roster_empty: Label = %RosterEmpty
@onready var _sheet_icon: IconBadge = %SheetIcon
@onready var _sheet_title: Label = %SheetTitle
@onready var _sheet_era: Label = %SheetEra
@onready var _sheet_contact: Label = %SheetContact
@onready var _sheet_note: Label = %SheetNote
@onready var _sheet_facts: InspectorFactGrid = %SheetFacts
@onready var _territory_bar: DossierStackedBar = %TerritoryBar
@onready var _soldier_bar: DossierStackedBar = %SoldierBar
@onready var _locate_button: Button = %LocateButton
@onready var _declare_button: Button = %DeclareButton
@onready var _peace_button: Button = %PeaceButton

@onready var _war_list_caption: Label = %WarListCaption
@onready var _war_table: DossierLedgerTable = %WarTable
@onready var _war_empty: Label = %WarEmpty
@onready var _war_icon: IconBadge = %WarIcon
@onready var _war_title: Label = %WarTitle
@onready var _war_role: Label = %WarRole
@onready var _war_note: Label = %WarSheetNote
@onready var _score_list: DossierBarList = %ScoreList
@onready var _front_list: DossierBarList = %FrontList
@onready var _front_empty: Label = %FrontEmpty
@onready var _log_tag: Label = %LogTag
@onready var _log_rows: Array = [%Log0, %Log1, %Log2, %Log3, %Log4]
@onready var _war_locate_button: Button = %WarLocateButton
@onready var _war_peace_button: Button = %WarPeaceButton


func _ready() -> void:
	_chapter_nav.set_chapters(_chapter_definitions(), _chapter)
	_size_chapter_nav()
	_chapter_nav.chapter_selected.connect(select_chapter)
	_refresh_timer = Timer.new()
	_refresh_timer.one_shot = true
	add_child(_refresh_timer)
	_refresh_timer.timeout.connect(_flush_pending_refresh)
	_bind_countries()
	_bind_wars()
	for card in _kpi_row.get_children():
		(card as DossierKpiCard).show_divider = card.get_index() < _kpi_row.get_child_count() - 1
	_apply_chapter_visibility()
	if TouchUI.is_short_viewport():
		set_compact(true)
	_apply_kpi_density()
	# 主题与容器尺寸晚一帧才稳定：不补这一遍，先挂载的工作区会一直停在纯图标页签。
	call_deferred("_refresh_layout")


func _bind_countries() -> void:
	_roster_table.empty_text = "尚未接触任何国家"
	_roster_table.row_selected.connect(_on_roster_selected)
	_roster_table.row_action.connect(_on_roster_action)
	_roster_table.set_columns([
		{"id": "name", "label": "国名", "kind": "text", "expand": true, "min_width": 108.0},
		{"id": "era", "label": "纪元", "kind": "text", "width": 56.0, "optional": true},
		{"id": "cells", "label": "领土", "kind": "number", "width": 56.0},
		{"id": "tech", "label": "科技", "kind": "number", "width": 52.0, "optional": true},
		{"id": "contact", "label": "关系", "kind": "text", "width": 104.0},
		{"id": "actions", "label": "", "kind": "actions", "width": 34.0, "sortable": false},
	], "cells")
	_territory_bar.show_legend = true
	_soldier_bar.show_legend = true
	_declare_button.pressed.connect(_on_declare_pressed)
	_peace_button.pressed.connect(_on_peace_pressed)
	_locate_button.pressed.connect(_on_locate_pressed)
	UIAnimation.bind_tactile_button(_declare_button)
	UIAnimation.bind_tactile_button(_peace_button)


func _bind_wars() -> void:
	_war_table.empty_text = "当前没有战争"
	_war_table.row_selected.connect(_on_war_selected)
	_war_table.row_action.connect(_on_war_action)
	_war_table.set_columns([
		{"id": "enemy", "label": "对手", "kind": "text", "expand": true, "min_width": 104.0},
		{"id": "role", "label": "角色", "kind": "text", "width": 56.0, "optional": true},
		{"id": "days", "label": "已战", "kind": "number", "width": 52.0},
		{"id": "score", "label": "战争分", "kind": "number", "width": 62.0},
		{"id": "status", "label": "战况", "kind": "text", "width": 76.0},
		{"id": "actions", "label": "", "kind": "actions", "width": 34.0, "sortable": false},
	], "score")
	_overview_war_table.empty_text = ""
	_overview_war_table.row_selected.connect(_on_war_selected)
	_overview_war_table.row_action.connect(_on_war_action)
	_overview_war_table.set_columns([
		{"id": "enemy", "label": "对手", "kind": "text", "expand": true, "min_width": 96.0},
		{"id": "days", "label": "已战", "kind": "number", "width": 52.0},
		{"id": "score", "label": "战争分", "kind": "number", "width": 62.0},
		{"id": "actions", "label": "", "kind": "actions", "width": 34.0, "sortable": false},
	], "score")
	_power_list.row_height = 26.0
	_power_list.label_width = 108.0
	_power_list.value_width = 58.0
	_score_list.diverging = true
	_score_list.row_height = 22.0
	_score_list.label_width = 64.0
	_score_list.value_width = 40.0
	_front_list.row_height = 22.0
	_front_list.label_width = 132.0
	_front_list.value_width = 56.0
	_front_list.selectable = true
	_front_list.row_selected.connect(_on_front_selected)
	_war_peace_button.pressed.connect(_on_peace_pressed)
	_war_locate_button.pressed.connect(_on_war_locate_pressed)
	UIAnimation.bind_tactile_button(_war_peace_button)


# ── shell API（CountryPanel）────────────────────────────────────────────

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


## 选中某个国家（名录行 id）。测试与「从战事跳回该国」共用这一个入口。
func select_country(row_id: int) -> void:
	_selected_country = row_id
	if _chapter != "countries":
		select_chapter("countries")
	else:
		_refresh_countries()


func select_war(war_id: int) -> void:
	_selected_war = war_id
	if _chapter != "wars":
		select_chapter("wars")
	else:
		_refresh_wars()


func selected_country() -> int:
	return _selected_country


func selected_war() -> int:
	return _selected_war


func debug_snapshot() -> Dictionary:
	return {
		"chapter": _chapter,
		"selected_country": _selected_country,
		"selected_war": _selected_war,
		"declare_enabled": _vm.available() and _declare_button != null \
		and not _declare_button.disabled and _declare_button.visible,
		"declare_reason": _declare_button.tooltip_text if _declare_button != null else "",
		"peace_visible": _peace_button != null and _peace_button.visible,
		"war_peace_visible": _war_peace_button != null and _war_peace_button.visible,
		"status": _status_label.text if _status_label != null else "",
		"roster_rows": _roster_table.row_count() if _roster_table != null else 0,
		"war_rows": _war_table.row_count() if _war_table != null else 0,
	}


# ── 章节与布局 ──────────────────────────────────────────────────────────

func _chapter_definitions() -> Array:
	var definitions: Array = []
	for chapter in VIEW_MODEL_SCRIPT.CHAPTERS:
		definitions.append({"id": String(chapter.id), "label": String(chapter.label),
			"icon": chapter.icon, "question": ""})
	return definitions


## 页签宽度按标签量出来：DossierChapterNav 一旦放不下就退成纯图标，
## 静态猜的宽度只够两个中文章节名。
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
	_chapter_nav.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var width := _chapter_nav_width()
	if absf(_chapter_nav.custom_minimum_size.x - width) > 0.5:
		_chapter_nav.custom_minimum_size = Vector2(width, DossierChapterNav.HEIGHT)
		_chapter_nav.call_deferred("_relayout")


func _refresh_layout() -> void:
	if not is_node_ready():
		return
	_signatures.erase("__layout_stamp__")
	_apply_layout()


func _apply_layout() -> void:
	var narrow := _compact or size.x < NARROW_WIDTH
	var themed := _chapter_nav.has_theme_stylebox("pressed", "PKChapterTab")
	_size_chapter_nav()
	# 主题标记进 latch：先挂载、后拿到主题的工作区要再跑一遍，否则停在纯图标页签。
	var stamp := "%s|%s|%s" % [narrow, themed, _short]
	if stamp == String(_signatures.get("__layout_stamp__", "")):
		return
	_signatures["__layout_stamp__"] = stamp
	_narrow = narrow
	var columns := 1 if narrow else 2
	for grid in [%OverviewGrid, %CountriesGrid, %WarsGrid]:
		(grid as GridContainer).columns = columns
	_apply_kpi_density()


func session_bound() -> bool:
	return _vm.available()


func _apply_kpi_density() -> void:
	for card in _kpi_row.get_children():
		var kpi := card as DossierKpiCard
		if kpi.dense != _short:
			kpi.dense = _short


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		var short := _compact or (size.y > 1.0 and size.y < SHORT_HEIGHT)
		if short != _short:
			_short = short
			_signatures.erase("__layout_stamp__")
		_apply_layout()
	if what == NOTIFICATION_POST_ENTER_TREE:
		call_deferred("_refresh_layout")


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
		_show_status(_vm.reason(), true)
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
		"countries":
			_refresh_countries()
		"wars":
			_refresh_wars()


func _apply_chapter_visibility() -> void:
	for chapter_id in _pages:
		(_pages[chapter_id] as Control).visible = chapter_id == _chapter and _vm.available()
	_kpi_strip.visible = _chapter == "overview" and _vm.available()


func _changed(key: String, value) -> bool:
	var signature := var_to_str(value)
	if String(_signatures.get(key, "")) == signature:
		return false
	_signatures[key] = signature
	return true


# ── 总览 ────────────────────────────────────────────────────────────────

func _refresh_overview() -> void:
	_overview = _vm.build("overview")
	var kpis: Array = _overview.get("kpis", [])
	var cards := _kpi_row.get_children()
	for index in range(cards.size()):
		if index < kpis.size():
			(cards[index] as DossierKpiCard).set_metric(kpis[index])
	var wars: Array = _overview.get("wars", [])
	_wars_caption.text = "%d 场" % wars.size() if not wars.is_empty() else ""
	_wars_empty.visible = wars.is_empty()
	_wars_empty.text = _vm.wars_empty_text()
	_overview_war_table.visible = not wars.is_empty()
	if _changed("overview_wars", wars):
		_overview_war_table.set_rows(_war_table_rows(wars, false))
	var powers: Array = _overview.get("powers", [])
	_powers_caption.text = "按领土" if not powers.is_empty() else _vm.roster_empty_text()
	_power_list.visible = not powers.is_empty()
	if _changed("overview_powers", powers):
		_power_list.set_rows(powers)
	_insights.set_items(_overview.get("insights", []))


# ── 国家 ────────────────────────────────────────────────────────────────

func _refresh_countries() -> void:
	_countries = _vm.build("countries", {"country": _selected_country})
	var rows: Array = _countries.get("rows", [])
	_selected_country = int(_countries.get("selected", 0))
	_roster_empty.visible = rows.is_empty()
	_roster_empty.text = String(_countries.get("empty", ""))
	_roster_caption.text = _roster_caption_text(rows)
	_roster_table.visible = not rows.is_empty()
	if _changed("roster", rows):
		_roster_table.set_rows(_roster_rows(rows))
	_roster_table.selected_id = _selected_country
	_roster_table.queue_redraw()
	_apply_sheet(_countries.get("sheet", {}))


func _roster_caption_text(rows: Array) -> String:
	if rows.is_empty():
		return ""
	var at_war := 0
	for row in rows:
		if String(_as_dict(row.relation).get("state", "")) == "war":
			at_war += 1
	if at_war > 0:
		return "%d 国 · 交战 %d" % [rows.size(), at_war]
	return "%d 国" % rows.size()


func _roster_rows(rows: Array) -> Array:
	var out: Array = []
	for row_value in rows:
		var row := _as_dict(row_value)
		var relation := _as_dict(row.relation)
		var at_war := String(relation.get("state", "")) == "war"
		var contact_text := "远方"
		var contact_color := UITokens.DOSSIER_INK_MUTED
		if at_war:
			contact_text = "交战 %d日" % int(relation.get("days", 0))
			contact_color = UITokens.DOSSIER_OXBLOOD
		elif bool(row.adjacent):
			contact_text = "接壤"
			contact_color = UITokens.DOSSIER_BRASS
		var gate_reason := String(row.declare_reason)
		var tooltip := "%s · %d 格 · %s 纪" % [String(row.name), int(row.cells),
			String(row.era_label)]
		if not gate_reason.is_empty() and not at_war:
			tooltip += "\n%s" % gate_reason
		out.append({
			"id": int(row.id),
			"tooltip": tooltip,
			"cells": {
				"name": {"text": String(row.name), "icon": "country.world",
					"sub": "" if (at_war or bool(row.adjacent)) else "不接壤"},
				"era": {"text": String(row.era_label)},
				"cells": {"text": "%d" % int(row.cells), "sort": float(row.cells)},
				"tech": {"text": "%d" % int(row.technology_count)},
				"contact": {"text": contact_text, "color": contact_color},
				"actions": {},
			},
			"actions": [{"id": "locate", "icon": "action.pin",
				"tooltip": "在地图上定位该国领土"}],
		})
	return out


func _apply_sheet(sheet_value) -> void:
	var sheet := _as_dict(sheet_value)
	_sheet_icon.set_semantic(&"country.world", UITokens.DOSSIER_SLATE)
	if not bool(sheet.get("ok", false)):
		_sheet_title.text = "未选择国家"
		_sheet_era.text = "—"
		_sheet_contact.text = "—"
		_sheet_note.text = String(sheet.get("reason", ""))
		_sheet_facts.set_facts([])
		_territory_bar.visible = false
		_soldier_bar.visible = false
		_declare_button.visible = false
		_peace_button.visible = false
		_locate_button.disabled = true
		return
	_sheet_title.text = String(sheet.name)
	_sheet_era.text = String(sheet.era_label)
	_sheet_contact.text = String(sheet.contact_text)
	_sheet_note.text = String(sheet.note)
	_sheet_facts.set_facts(sheet.get("facts", []))
	_apply_compare_bars(sheet.get("compare", []))
	_apply_sheet_actions(sheet)


func _apply_compare_bars(bars_value) -> void:
	var bars := {}
	for bar_value in _as_array(bars_value):
		var bar := _as_dict(bar_value)
		bars[String(bar.get("id", ""))] = bar
	var territory := _as_dict(bars.get("territory", null))
	_territory_bar.visible = not territory.is_empty()
	if _territory_bar.visible:
		_territory_bar.set_segments(String(territory.title),
			territory.get("segments", []), String(territory.get("total", "")))
	var soldiers := _as_dict(bars.get("soldiers", null))
	_soldier_bar.visible = not soldiers.is_empty()
	if _soldier_bar.visible:
		_soldier_bar.set_segments(String(soldiers.title),
			soldiers.get("segments", []), String(soldiers.get("total", "")))


func _apply_sheet_actions(sheet: Dictionary) -> void:
	var gate := _as_dict(sheet.get("declare", null))
	var handle := int(sheet.get("handle", 0))
	var at_war := String(_as_dict(sheet.get("relation", null)).get("state", "")) == "war"
	_locate_button.disabled = int(sheet.get("locate_cell", -1)) < 0
	# 交战中的国家只有「议和」；其余国家只有「宣战」。两者互斥，避免误点。
	_peace_button.visible = at_war
	_declare_button.visible = not at_war
	if at_war:
		_peace_button.disabled = int(sheet.get("peace_war_id", 0)) <= 0
		return
	var pending := _declare_pending_for(sheet)
	var enabled := bool(gate.get("enabled", false)) and not pending
	_declare_button.disabled = not enabled
	_declare_button.tooltip_text = "向%s递交宣战" % String(sheet.name) if enabled \
		else ("已递交 · 次日生效" if pending else String(gate.get("reason", "")))
	_declare_button.set_meta(&"handle", handle)


## 已递交但还没生效的宣战：日推进或该国真的进入战争后自动解除。
func _declare_pending_for(sheet: Dictionary) -> bool:
	if _declare_pending_slot < 0:
		return false
	if int(sheet.get("slot", -1)) != _declare_pending_slot:
		return false
	if _vm.day() > _declare_pending_day:
		_declare_pending_slot = -1
		_declare_pending_day = -1
		return false
	return true


# ── 战事 ────────────────────────────────────────────────────────────────

func _refresh_wars() -> void:
	_wars = _vm.build("wars", {"war": _selected_war})
	var rows: Array = _wars.get("rows", [])
	_selected_war = int(_wars.get("selected", 0))
	_war_empty.visible = rows.is_empty()
	_war_empty.text = String(_wars.get("empty", ""))
	_war_table.visible = not rows.is_empty()
	_war_list_caption.text = "%d 场" % rows.size() if not rows.is_empty() else ""
	if _changed("wars", rows):
		_war_table.set_rows(_war_table_rows(rows, true))
	_war_table.selected_id = _selected_war
	_war_table.queue_redraw()
	_apply_war_sheet(_wars.get("sheet", {}))


func _war_table_rows(rows: Array, with_status: bool) -> Array:
	var out: Array = []
	for row_value in rows:
		var row := _as_dict(row_value)
		var score := float(row.get("score", 0.0))
		var cells := {
			"enemy": {"text": String(row.enemy_name), "icon": "military.war.front",
				"sub": String(row.role)},
			"days": {"text": "%d" % int(row.days), "sort": float(row.days)},
			"score": {"text": String(row.score_text), "sort": score,
				"color": UITokens.DOSSIER_VERDIGRIS if score >= 0.0
					else UITokens.DOSSIER_OXBLOOD},
		}
		if with_status:
			cells["role"] = {"text": String(row.role)}
			cells["status"] = {"text": String(row.status),
				"color": UITokens.DOSSIER_OXBLOOD if bool(row.fully_occupied)
					else UITokens.DOSSIER_INK}
		out.append({
			"id": int(row.id),
			"tooltip": "对%s · %s · 已战 %d 日\n%s" % [String(row.enemy_name),
				String(row.role), int(row.days), String(row.losses_text)],
			"cells": cells,
			# 名单里也能直接议和：窄屏下战争档案在折叠线以下，动作必须另有一条路，
			# 而且「开议和窗口」是不可撤销提案，放在行上没有误伤风险（真递交要再确认）。
			"actions": [{"id": "peace", "icon": "military.war.peace",
				"tooltip": "为对%s的战争开议和窗口" % String(row.enemy_name)}],
		})
	return out


func _apply_war_sheet(sheet_value) -> void:
	var sheet := _as_dict(sheet_value)
	_war_icon.set_semantic(&"military.war.front", UITokens.DOSSIER_OXBLOOD)
	_log_tag.visible = false
	for entry in _log_rows:
		var log_label := entry as Label
		log_label.visible = false
		log_label.text = ""
	if not bool(sheet.get("ok", false)):
		_war_title.text = "未选择战争"
		_war_role.text = "—"
		_war_note.text = String(sheet.get("reason", ""))
		_score_list.visible = false
		_front_list.visible = false
		_front_empty.visible = true
		_front_empty.text = ""
		_war_peace_button.visible = false
		_war_peace_button.disabled = true
		_war_locate_button.disabled = true
		return
	_war_title.text = "对%s" % String(sheet.enemy_name)
	_war_role.text = String(sheet.role)
	var note := "已战 %d 日 · %s" % [int(sheet.days), String(sheet.losses_text)]
	if bool(sheet.fully_occupied):
		note += " · 全境沦陷"
	_war_note.text = note
	var score_rows: Array = _as_array(sheet.get("score_rows", []))
	_score_list.visible = not score_rows.is_empty()
	if _score_list.visible:
		_score_list.set_rows(score_rows)
	var fronts: Array = _as_array(sheet.get("fronts", []))
	_front_list.visible = not fronts.is_empty()
	if _front_list.visible:
		if _changed("fronts", fronts):
			_front_list.set_rows(fronts)
	_front_empty.visible = fronts.is_empty()
	_front_empty.text = "当前没有接触中的战线。"
	var log: Array = _as_array(sheet.get("log", []))
	_log_tag.visible = not log.is_empty()
	for index in range(_log_rows.size()):
		var label := _log_rows[index] as Label
		var visible_row := index < log.size()
		label.visible = visible_row
		if visible_row:
			var row := _as_dict(log[index])
			label.text = "第 %d 日 · %s · %s" % [int(row.get("day", 0)),
				String(row.get("kind", "战事")), String(row.get("text", ""))]
	_war_peace_button.visible = true
	_war_peace_button.disabled = int(sheet.get("id", 0)) <= 0
	_war_peace_button.set_meta(&"war_id", int(sheet.get("id", 0)))
	_war_locate_button.disabled = int(sheet.get("focus_cell", -1)) < 0
	_war_locate_button.set_meta(&"cell", int(sheet.get("focus_cell", -1)))


# ── 交互 ────────────────────────────────────────────────────────────────

func _on_roster_selected(row_id) -> void:
	if int(row_id) == _selected_country:
		return
	_selected_country = int(row_id)
	_refresh_countries()


func _on_roster_action(row_id, action_id: String) -> void:
	if String(action_id) != "locate":
		return
	var sheet: Dictionary = _vm.country_sheet(int(row_id))
	if int(sheet.get("locate_cell", -1)) >= 0:
		locate_cell_requested.emit(int(sheet.locate_cell))


func _on_locate_pressed() -> void:
	var sheet: Dictionary = _as_dict(_countries.get("sheet", null))
	if int(sheet.get("locate_cell", -1)) >= 0:
		locate_cell_requested.emit(int(sheet.locate_cell))


func _on_declare_pressed() -> void:
	var sheet: Dictionary = _as_dict(_countries.get("sheet", null))
	var handle := int(sheet.get("handle", _declare_button.get_meta(&"handle", 0)))
	if handle == 0:
		_flash("未建立往来，无法递交宣战。", true)
		return
	if _player_controller == null or not _player_controller.has_method("request_command"):
		_flash("外交命令需要在正式对局中下达。", true)
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_MILITARY_WAR_DECLARE, {"target": handle})
	if bool(result.get("ok", false)):
		_declare_pending_slot = int(sheet.get("slot", -1))
		_declare_pending_day = _vm.day()
		_flash("已递交宣战 · 次日生效", false)
	else:
		_flash(String(result.get("message", "命令被拒绝。")), true)
	_refresh_countries()


func _on_peace_pressed() -> void:
	var war_id := 0
	if _chapter == "countries":
		war_id = int(_as_dict(_countries.get("sheet", null)).get("peace_war_id", 0))
	else:
		war_id = int(_as_dict(_wars.get("sheet", null)).get("id", 0))
	if war_id <= 0:
		return
	peace_negotiation_requested.emit(war_id)


func _on_war_selected(row_id) -> void:
	if int(row_id) == _selected_war:
		return
	_selected_war = int(row_id)
	if _chapter == "wars":
		_refresh_wars()
	else:
		select_war(_selected_war)


## 行上的议和：直接开窗口，不经过档案页（窄屏下档案在折叠线以下）。
func _on_war_action(row_id, action_id: String) -> void:
	if String(action_id) != "peace":
		return
	if int(row_id) <= 0:
		return
	_selected_war = int(row_id)
	peace_negotiation_requested.emit(int(row_id))


func _on_front_selected(front_id) -> void:
	for row_value in _as_array(_as_dict(_wars.get("sheet", null)).get("fronts", [])):
		var row := _as_dict(row_value)
		if String(row.get("id", "")) == String(front_id):
			if int(row.get("cell", -1)) >= 0:
				locate_cell_requested.emit(int(row.cell))
			return


func _on_war_locate_pressed() -> void:
	var cell := int(_war_locate_button.get_meta(&"cell", -1))
	if cell >= 0:
		locate_cell_requested.emit(cell)


# ── 回执 ────────────────────────────────────────────────────────────────

func _flash(text: String, danger: bool) -> void:
	_flash_text = text
	_show_status(text, danger)
	if not is_inside_tree():
		return
	get_tree().create_timer(4.0).timeout.connect(func() -> void:
		if _flash_text == text:
			_flash_text = ""
			_status_label.visible = false)


func _show_status(text: String, danger: bool) -> void:
	_status_label.text = text
	_status_label.visible = not text.is_empty()
	_status_label.theme_type_variation = &"PKDangerText" if danger else &"PKDossierCaption"


static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}


static func _as_array(value) -> Array:
	return value if value is Array else []
