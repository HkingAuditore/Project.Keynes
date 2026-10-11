extends VBoxContainer
class_name EconomyDossier

## 国民经济卷宗：国家事务外壳里的一页。章节索引 + 范围选择 + KPI 条 + 章节视口。
## 每日刷新只把新数据推给当前可见章节；章节节点、滚动位置和选中项在刷新间保留。
## 财政章直接承载原有 EconomyWorkspace（国库 / 税制编辑逻辑不变）。

signal locate_cell_requested(cell: int)

const LIVE_REFRESH_INTERVAL_MSEC := 200
const COMPACT_WIDTH := 760.0
const FILTER_CHAPTERS := {"industry": "sector", "market": "group"}

var _vm := EconomyDossierViewModel.new()
var _model: Dictionary = {}
var _chapter := "overview"
var _compact := false
var _filters := {"sector": -1, "group": ""}
var _scroll_by_chapter: Dictionary = {}
var _scope_signature := ""
var _last_refresh_ms := -LIVE_REFRESH_INTERVAL_MSEC
var _refresh_pending := false
var _pages: Dictionary = {}
var _chips: Array[Button] = []
var _player_controller = null

@onready var _chapter_nav: DossierChapterNav = %ChapterNav
@onready var _scope_option: OptionButton = %ScopeOption
@onready var _scope_reset: Button = %ScopeReset
@onready var _kpi_row: HBoxContainer = %KpiRow
@onready var _filter_bar: HBoxContainer = %FilterBar
@onready var _filter_label: Label = %FilterLabel
@onready var _status_label: Label = %StatusLabel
@onready var _viewport: ScrollContainer = %PageViewport
@onready var _page_stack: MarginContainer = %PageStack
@onready var _finance_host: MarginContainer = %FinanceHost
@onready var _workspace: Control = %EconomyWorkspace
@onready var _refresh_timer: Timer = %RefreshTimer


func _ready() -> void:
	for page in _page_stack.get_children():
		var chapter_id := String(page.get("chapter_id"))
		if chapter_id.is_empty():
			continue
		_pages[chapter_id] = page
		page.visible = false
		if page.has_signal("navigate_requested"):
			page.navigate_requested.connect(_on_page_navigate)
		if page.has_signal("scope_requested"):
			page.scope_requested.connect(set_scope)
		if page.has_signal("locate_requested"):
			page.locate_requested.connect(_on_locate_requested)
	for chip in %FilterChips.get_children():
		if chip is Button:
			var button := chip as Button
			button.toggle_mode = true
			button.focus_mode = Control.FOCUS_NONE
			button.pressed.connect(_on_chip_pressed.bind(_chips.size()))
			_chips.append(button)
	_chapter_nav.set_chapters(EconomyDossierViewModel.CHAPTERS, _chapter)
	_chapter_nav.chapter_selected.connect(select_chapter)
	_scope_option.item_selected.connect(_on_scope_selected)
	_scope_option.focus_mode = Control.FOCUS_NONE
	_scope_reset.pressed.connect(set_scope.bind(-1))
	_refresh_timer.timeout.connect(_flush_pending_refresh)
	if _workspace.has_method("set_embedded"):
		_workspace.set_embedded(true)
	_apply_chapter_visibility()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		_update_layout_mode()


# ── 外壳 API（CountryPanel 调用） ─────────────────────────────────────────

func set_model(model: Dictionary) -> void:
	_model = model
	if _workspace != null and _workspace.has_method("set_model"):
		_workspace.set_model(model)
	_last_refresh_ms = Time.get_ticks_msec()
	_refresh_now()


func refresh_model(model: Dictionary) -> void:
	_model = model
	if _chapter == "finance" and _workspace != null and _workspace.has_method("refresh_model"):
		_workspace.refresh_model(model)
	var now := Time.get_ticks_msec()
	if now - _last_refresh_ms < LIVE_REFRESH_INTERVAL_MSEC:
		if not _refresh_pending:
			_refresh_pending = true
			_refresh_timer.start(float(LIVE_REFRESH_INTERVAL_MSEC - (now - _last_refresh_ms)) / 1000.0)
		return
	_last_refresh_ms = now
	_refresh_now()


func set_compact(compact: bool) -> void:
	_compact = compact
	if _workspace != null and _workspace.has_method("set_compact"):
		_workspace.set_compact(compact)
	_update_layout_mode()


func set_player_controller(controller) -> void:
	_player_controller = controller
	if _workspace != null and _workspace.has_method("set_player_controller"):
		_workspace.set_player_controller(controller)


func economy_workspace() -> Control:
	return _workspace if _workspace != null else get_node_or_null("FinanceHost/EconomyWorkspace") as Control


func current_chapter() -> String:
	return _chapter


func scope_cell() -> int:
	return _vm.scope_cell


func page(chapter_id: String) -> Control:
	return _pages.get(chapter_id, null)


func view_model() -> EconomyDossierViewModel:
	return _vm


func kpi_texts() -> PackedStringArray:
	var texts := PackedStringArray()
	for card in _kpi_row.get_children():
		if card is DossierKpiCard:
			texts.append((card as DossierKpiCard).value_text())
	return texts


func scroll_value() -> int:
	return _viewport.scroll_vertical


func set_scroll_for_test(value: int) -> void:
	_viewport.scroll_vertical = value


func select_chapter(chapter_id: String) -> void:
	if chapter_id == _chapter or not _is_known_chapter(chapter_id):
		return
	_scroll_by_chapter[_chapter] = _viewport.scroll_vertical
	_chapter = chapter_id
	_chapter_nav.select(chapter_id)
	_apply_chapter_visibility()
	_refresh_page()
	var target: Control = _finance_host if chapter_id == "finance" else _viewport
	UIAnimation.crossfade(target, UITokens.ANIM_FAST)
	_viewport.scroll_vertical = int(_scroll_by_chapter.get(chapter_id, 0))
	if chapter_id != "finance":
		call_deferred("_restore_scroll", chapter_id)


func set_scope(cell: int) -> void:
	if cell == _vm.scope_cell:
		return
	_vm.scope_cell = cell
	_scroll_by_chapter.clear()
	if _chapter == "cities" and cell >= 0:
		select_chapter("overview")
	_refresh_now()


# ── 刷新 ───────────────────────────────────────────────────────────────

func _flush_pending_refresh() -> void:
	if not _refresh_pending:
		return
	_refresh_pending = false
	_last_refresh_ms = Time.get_ticks_msec()
	_refresh_now()


func _refresh_now() -> void:
	if not is_node_ready():
		return
	_vm.configure(_model, _model.get("economy_history", null))
	_vm.begin_refresh()
	_refresh_scope_options()
	_refresh_kpis()
	_refresh_filters()
	_refresh_page()


func _refresh_page() -> void:
	if _chapter == "finance":
		_status_label.visible = false
		return
	var current = _pages.get(_chapter, null)
	if not _vm.available():
		_show_status(_vm.unavailable_reason())
		return
	var summary := _vm.query("summary")
	if not bool(summary.get("ok", false)):
		_show_status(EconomyDossierViewModel._reason(summary))
		return
	var day_min := int(summary.get("state_day_min", -1))
	var day_max := int(summary.get("state_day_max", -1))
	if day_min >= 0 and day_max > day_min:
		_show_status("各城市结算日不同步：数据跨第 %d–%d 日" % [day_min, day_max], false)
	else:
		_status_label.visible = false
	if current != null and current.has_method("refresh"):
		var filter = _filters.get(FILTER_CHAPTERS.get(_chapter, ""), null)
		current.refresh(_vm, filter)


func _show_status(text: String, blocking: bool = true) -> void:
	_status_label.text = text
	_status_label.visible = true
	_status_label.theme_type_variation = &"PKDangerText" if blocking else &"PKDossierCaption"


func _refresh_kpis() -> void:
	var metrics := _vm.kpis() if _vm.available() else []
	var cards := _kpi_row.get_children()
	for i in range(cards.size()):
		var card := cards[i] as DossierKpiCard
		if card == null:
			continue
		card.show_divider = i < cards.size() - 1
		if i < metrics.size():
			card.set_metric(metrics[i])
			card.modulate.a = 1.0
		else:
			card.modulate.a = 0.45


func _refresh_scope_options() -> void:
	var options := _vm.scope_options() if _vm.available() else [{"cell": -1, "label": "全国"}]
	var parts := PackedStringArray()
	for option in options:
		parts.append("%d:%s" % [int(option.cell), String(option.label)])
	var signature := "|".join(parts)
	if signature != _scope_signature:
		_scope_signature = signature
		_scope_option.clear()
		for option in options:
			_scope_option.add_item(String(option.label))
			_scope_option.set_item_metadata(_scope_option.item_count - 1, int(option.cell))
	for i in range(_scope_option.item_count):
		if int(_scope_option.get_item_metadata(i)) == _vm.scope_cell:
			if _scope_option.selected != i:
				_scope_option.select(i)
			break
	_scope_reset.visible = _vm.scope_cell >= 0


func _refresh_filters() -> void:
	var kind := String(FILTER_CHAPTERS.get(_chapter, ""))
	_filter_bar.visible = not kind.is_empty() and _vm.available()
	if not _filter_bar.visible:
		return
	var options: Array = [{"id": -1 if kind == "sector" else "", "label": "全部"}]
	if kind == "sector":
		_filter_label.text = "产业部门"
		for sector in EconomyDossierViewModel.SECTORS:
			options.append({"id": int(sector.id), "label": String(sector.name)})
	else:
		_filter_label.text = "物资类别"
		var market := _vm.market_model("")
		for group in market.get("groups", []):
			options.append({"id": String(group.id), "label": "%s %d" % [group.name, int(group.count)]})
	var current = _filters[kind]
	for i in range(_chips.size()):
		var chip := _chips[i]
		chip.visible = i < options.size()
		if not chip.visible:
			continue
		chip.text = String(options[i].label)
		chip.set_meta("filter_id", options[i].id)
		chip.set_pressed_no_signal(options[i].id == current)


func _on_chip_pressed(index: int) -> void:
	var kind := String(FILTER_CHAPTERS.get(_chapter, ""))
	if kind.is_empty() or index >= _chips.size():
		return
	_filters[kind] = _chips[index].get_meta("filter_id")
	_refresh_filters()
	_refresh_page()


func _on_scope_selected(index: int) -> void:
	set_scope(int(_scope_option.get_item_metadata(index)))


func _on_page_navigate(chapter_id: String, payload: Dictionary) -> void:
	if payload.has("sector"):
		_filters["sector"] = int(payload.sector)
	if payload.has("group"):
		_filters["group"] = String(payload.group)
	var target = _pages.get(chapter_id, null)
	if target != null and target.has_method("focus_item") and payload.has("focus"):
		target.focus_item(payload.focus)
	if chapter_id == _chapter:
		_refresh_filters()
		_refresh_page()
	else:
		select_chapter(chapter_id)
		_refresh_filters()


func _on_locate_requested(cell: int) -> void:
	locate_cell_requested.emit(cell)


# ── 布局 / 可见性 ───────────────────────────────────────────────────────

func _is_known_chapter(chapter_id: String) -> bool:
	for chapter in EconomyDossierViewModel.CHAPTERS:
		if String(chapter.id) == chapter_id:
			return true
	return false


func _apply_chapter_visibility() -> void:
	var finance := _chapter == "finance"
	_viewport.visible = not finance
	_finance_host.visible = finance
	for chapter_id in _pages:
		(_pages[chapter_id] as Control).visible = chapter_id == _chapter
	_refresh_filters()
	if finance and _workspace != null and _workspace.has_method("refresh_model") \
			and not _model.is_empty():
		_workspace.refresh_model(_model)


func _restore_scroll(chapter_id: String) -> void:
	if chapter_id == _chapter:
		_viewport.scroll_vertical = int(_scroll_by_chapter.get(chapter_id, 0))


func _update_layout_mode() -> void:
	var width := size.x
	var narrow := _compact or width < COMPACT_WIDTH
	for chapter_id in _pages:
		var target = _pages[chapter_id]
		if target.has_method("set_narrow"):
			target.set_narrow(narrow, 0.0 if _compact else width)
	for card in _kpi_row.get_children():
		if card is DossierKpiCard:
			(card as Control).custom_minimum_size.x = 104.0 if narrow else 150.0
