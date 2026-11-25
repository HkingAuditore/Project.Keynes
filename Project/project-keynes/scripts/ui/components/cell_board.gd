extends Control
class_name CellBoard

## 市价与民情展板。沿用悬停卡的可见性判断，只读取已发布的经济快照。
signal resolved(cell_index: int, ok: bool)

const BOARD_WIDTH := 520.0
const SLOT_COUNT := 5
const COLUMN_GAP := 10.0
const ROW_HEIGHT := 36.0
const COHORT_ROW_HEIGHT := 64.0
const HEADER_HEIGHT := 26.0
const FULL_HEIGHT := 650.0
const COMPACT_HEIGHT := 510.0
const MARKET_HEIGHT := 320.0
const DWELL_SEC := 0.3
const RETRY_SEC := 0.15
const SLIDE_IN_SEC := 0.18
const SLIDE_OUT_SEC := 0.13
const SLIDE_OFFSET := Vector2(-20.0, 0.0)

var _map: MapData
var _view_model: CellBoardViewModel
var _pending_cell := -1
var _shown_cell := -1
var _shown_day := -1
var _cohort_capacity := SLOT_COUNT
var _show_market := true
var _show_cohorts := true
var _suppressed := false
var _hiding := false
var _market_slots: Array[Dictionary] = []
var _cohort_slots: Array[Dictionary] = []
var _market_data: Dictionary = {}
var _cohort_data: Array = []

@onready var _slide: Control = $Slide
@onready var _column: VBoxContainer = $Slide/Column
@onready var _market_card: PanelContainer = $Slide/Column/MarketCard
@onready var _cohort_card: PanelContainer = $Slide/Column/CohortCard
@onready var _market_header: HBoxContainer = $Slide/Column/MarketCard/Margin/Body/Header
@onready var _stock_scale: Label = $Slide/Column/MarketCard/Margin/Body/Header/StockScale
@onready var _cohort_header: HBoxContainer = $Slide/Column/CohortCard/Margin/Body/Header
@onready var _market_rows: VBoxContainer = $Slide/Column/MarketCard/Margin/Body/Rows
@onready var _cohort_rows: VBoxContainer = $Slide/Column/CohortCard/Margin/Body/Rows
@onready var _dwell_timer: Timer = $DwellTimer
@onready var _retry_timer: Timer = $RetryTimer


func _ready() -> void:
	(_market_header.get_node("Lead/Icon") as IconBadge).set_semantic(&"economy.building.market")
	(_cohort_header.get_node("Lead/Icon") as IconBadge).set_semantic(&"population.crowd")
	for row in _market_rows.get_children():
		_market_slots.append({
			"root": row, "badge": row.get_node("Line/Icon"), "name": row.get_node("Line/Name"),
			"bar": row.get_node("Line/StockBar/Fill"), "stock": row.get_node("Line/Stock"),
			"price": row.get_node("Line/Price"),
		})
	for row in _cohort_rows.get_children():
		_cohort_slots.append({
			"root": row, "badge": row.get_node("Line/Icon"), "name": row.get_node("Line/Name"),
			"population": row.get_node("Line/Population"), "funds": row.get_node("Line/Funds"),
			"income": row.get_node("Line/Income"),
			"living_badge": row.get_node("Signals/Living/Icon"),
			"living": row.get_node("Signals/Living/Name"),
			"satisfaction": {"bar": row.get_node("Signals/Satisfaction/Bar/Fill"),
				"label": row.get_node("Signals/Satisfaction/Value")},
			"organization": {"bar": row.get_node("Signals/Organization/Bar/Fill"),
				"label": row.get_node("Signals/Organization/Value")},
			"share": row.get_node("Share/Bar/Fill"),
		})
	_dwell_timer.timeout.connect(_on_resolve_timer_elapsed)
	_retry_timer.timeout.connect(_on_resolve_timer_elapsed)
	_slide.visibility_changed.connect(_on_slide_visibility_changed)


func _set_ratio(fill: ColorRect, ratio: float) -> void:
	fill.anchor_right = clampf(ratio, 0.0, 1.0)


## 展板自己持有数据层：宿主只在世界绑定时调一次，此后每格取数都走内部缓存。
## 经济门面用 Callable 按需解析，避免「配置早于经济运行时绑定」时抓到 null。
func configure(map: MapData, economy_provider: Callable, inspector: CellInspectorViewModel,
		world_clock: WorldClock) -> void:
	_map = map
	if _view_model == null:
		_view_model = CellBoardViewModel.new()
	_view_model.set_context(map, economy_provider, inspector, world_clock)
	reset_for_world()


func reset_for_world() -> void:
	_pending_cell = -1
	_shown_cell = -1
	_shown_day = -1
	_market_data = {}
	_cohort_data = []
	if _dwell_timer != null: _dwell_timer.stop()
	if _retry_timer != null: _retry_timer.stop()
	hide_board(true)


func set_suppressed(suppressed: bool) -> void:
	_suppressed = suppressed
	if suppressed:
		on_hover_cell_changed(-1)


func current_cell_index() -> int:
	return _shown_cell


## 由悬停卡转发：-1 表示指针已离开可出表的格子。
func on_hover_cell_changed(cell_index: int) -> void:
	if _dwell_timer == null:
		return
	if _suppressed or _view_model == null or _map == null or cell_index < 0:
		_pending_cell = -1
		_dwell_timer.stop()
		_retry_timer.stop()
		hide_board(false)
		return
	if cell_index == _pending_cell:
		return
	_pending_cell = cell_index
	_retry_timer.stop()
	_dwell_timer.start(DWELL_SEC)


## 悬停卡同格跨日或归属变化重建后触发：不重走 300ms 停稳等待，直接按当日快照刷新。
func on_hover_cell_refreshed(cell_index: int) -> void:
	if _dwell_timer == null or _suppressed or _view_model == null or _map == null:
		return
	if cell_index < 0 or cell_index != _pending_cell:
		return
	# 初次停稳倒计时还在跑时，等它自然到期读取当日数据，不抢跑跳过 dwell。
	if not _dwell_timer.is_stopped():
		return
	if _shown_cell == cell_index and visible and _shown_day == _view_model.current_day():
		return
	_retry_timer.stop()
	_resolve(cell_index)


func _on_resolve_timer_elapsed() -> void:
	if _pending_cell >= 0:
		_resolve(_pending_cell)


func _resolve(cell_index: int) -> void:
	if not _show_market and not _show_cohorts:
		return
	if _map.cell_at(cell_index) == null or not VisionSolver.displayed_cell_visible(_map, cell_index) \
			or not VisionSolver.displayed_fields_current(_map):
		hide_board(false)
		return
	var payload: Dictionary = _view_model.build(cell_index)
	if not bool(payload.get("ok", false)):
		if bool(payload.get("pending", false)):
			_retry_timer.start(RETRY_SEC)
			if _shown_cell != cell_index:
				hide_board(false)
		else:
			hide_board(false)
		resolved.emit(cell_index, false)
		return
	if not _apply_payload(cell_index, payload, true):
		hide_board(false)
		resolved.emit(cell_index, false)
		return
	resolved.emit(cell_index, true)


func _apply_payload(cell_index: int, payload: Dictionary, animate: bool) -> bool:
	var market := payload.get("market", {}) as Dictionary
	var cohort_rows: Array = (payload.get("cohorts", {}) as Dictionary).get("rows", [])
	if (market.get("rows", []) as Array).is_empty() and cohort_rows.is_empty():
		return false
	_market_data = market
	_cohort_data = cohort_rows
	_apply_rows(market, cohort_rows)
	if not _market_card.visible and not _cohort_card.visible:
		return false
	_shown_cell = cell_index
	_shown_day = int(payload.get("day", -1))
	show_board(animate)
	return true


# ───────────────────────────── 呈现 ─────────────────────────────

func _apply_rows(market: Dictionary, cohort_rows: Array) -> void:
	_apply_market_rows(market)
	_apply_cohort_rows(cohort_rows)


func _apply_market_rows(market: Dictionary) -> void:
	var rows: Array = market.get("rows", [])
	_stock_scale.text = String(market.get("stock_scale", ""))
	var visible_count := mini(rows.size(), _market_slots.size())
	for index in _market_slots.size():
		var slot: Dictionary = _market_slots[index]
		var root := slot["root"] as Control
		root.visible = index < visible_count
		if not root.visible:
			continue
		var row: Dictionary = rows[index]
		(slot["badge"] as IconBadge).set_semantic(StringName(row.get("icon", "")))
		(slot["name"] as Label).text = String(row.get("name", ""))
		(slot["stock"] as Label).text = String(row.get("stock_text", ""))
		var price_label := slot["price"] as Label
		price_label.text = String(row.get("price_text", ""))
		var accent: Color = row.get("price_accent", UITokens.DOSSIER_INK)
		price_label.add_theme_color_override("font_color", accent)
		_set_ratio(slot["bar"], float(row.get("stock_ratio", 0.0)))
	_market_header.visible = visible_count > 0
	_market_card.visible = _show_market and visible_count > 0


func _apply_cohort_rows(rows: Array) -> void:
	var capacity := mini(_cohort_capacity, _cohort_slots.size())
	var visible_count := mini(rows.size(), capacity)
	for index in _cohort_slots.size():
		var slot: Dictionary = _cohort_slots[index]
		var root := slot["root"] as Control
		root.visible = index < visible_count
		if not root.visible:
			continue
		var row: Dictionary = rows[index]
		(slot["badge"] as IconBadge).set_semantic(StringName(row.get("icon", "")))
		(slot["name"] as Label).text = String(row.get("name", ""))
		(slot["population"] as Label).text = String(row.get("population_text", ""))
		(slot["funds"] as Label).text = String(row.get("funds_text", ""))
		var income_label := slot["income"] as Label
		income_label.text = String(row.get("income_text", ""))
		income_label.add_theme_color_override("font_color",
			UITokens.DOSSIER_VERDIGRIS if bool(row.get("income_positive", true)) \
				else UITokens.DOSSIER_OXBLOOD)

		var living_badge := slot["living_badge"] as IconBadge
		living_badge.set_semantic(StringName(row.get("living_icon", "history")))
		var living_label := slot["living"] as Label
		living_label.text = String(row.get("living_name", ""))
		var living_accent: Color = row.get("living_accent", UITokens.DOSSIER_INK_SOFT)
		living_label.add_theme_color_override("font_color", living_accent)

		var satisfaction: Dictionary = slot["satisfaction"]
		_set_ratio(satisfaction["bar"], float(row.get("satisfaction", 0.0)))
		var satisfaction_label := satisfaction["label"] as Label
		satisfaction_label.text = String(row.get("satisfaction_text", ""))
		var satisfaction_accent: Color = row.get("satisfaction_accent",
			UITokens.DOSSIER_INK_SOFT)
		satisfaction_label.add_theme_color_override("font_color", satisfaction_accent)
		(satisfaction["bar"] as ColorRect).color = satisfaction_accent

		var organization: Dictionary = slot["organization"]
		# 职业没有异动时原生不单列组织度：那一格留在原位、只留空轨道，
		# 既不伪造 0% 也不让同一列在行与行之间错位。
		var org_value := maxf(float(row.get("organization", -1.0)), 0.0)
		var org_known := float(row.get("organization", -1.0)) >= 0.0
		var org_accent: Color = row.get("organization_accent", UITokens.ACCENT)
		_set_ratio(organization["bar"], org_value)
		(organization["bar"] as ColorRect).color = org_accent
		var org_label := organization["label"] as Label
		org_label.text = String(row.get("organization_text", "")) if org_known else ""
		org_label.add_theme_color_override("font_color", org_accent)

		_set_ratio(slot["share"], float(row.get("share", 0.0)))

	_cohort_header.visible = visible_count > 0
	_cohort_card.visible = _show_cohorts and visible_count > 0


func show_board(animate: bool) -> void:
	if _hiding:
		UIAnimation.cancel(_slide)
		_hiding = false
		_slide.position = Vector2.ZERO
	if visible:
		return
	visible = true
	if animate and not UIAnimation.reduced_motion():
		UIAnimation.fade_slide_in(_slide, SLIDE_OFFSET, SLIDE_IN_SEC)
		UIAnimation.stagger_children_in(_column, 0.06, 2, SLIDE_IN_SEC)
	else:
		_slide.position = Vector2.ZERO


func hide_board(immediate: bool) -> void:
	_shown_cell = -1
	_shown_day = -1
	if not visible or (_hiding and not immediate):
		return
	if immediate or UIAnimation.reduced_motion():
		UIAnimation.cancel(_slide)
		_finish_hide()
	else:
		_hiding = true
		UIAnimation.fade_slide_out(_slide, SLIDE_OFFSET * 0.6, SLIDE_OUT_SEC)


func _on_slide_visibility_changed() -> void:
	if _hiding and not _slide.visible:
		_finish_hide()


func _finish_hide() -> void:
	_hiding = false
	visible = false
	_slide.show()
	_slide.position = Vector2.ZERO


func apply_available_height(available: float) -> void:
	var capacity := 3 if available < FULL_HEIGHT else SLOT_COUNT
	var show_cohorts := available >= COMPACT_HEIGHT
	var show_market := available >= MARKET_HEIGHT
	if capacity == _cohort_capacity and show_cohorts == _show_cohorts and show_market == _show_market:
		return
	var restored := show_market and not _show_market
	_cohort_capacity = capacity
	_show_cohorts = show_cohorts
	_show_market = show_market
	_apply_rows(_market_data, _cohort_data)
	if not _market_card.visible and not _cohort_card.visible:
		hide_board(true)
	if restored and _pending_cell >= 0 and _dwell_timer.is_stopped():
		_retry_timer.stop()
		_resolve(_pending_cell)


func desired_height() -> float:
	var market := HEADER_HEIGHT + float(SLOT_COUNT) * ROW_HEIGHT + 37.0
	if not _show_cohorts:
		return market if _show_market else 0.0
	var cohorts := HEADER_HEIGHT + float(_cohort_capacity) * COHORT_ROW_HEIGHT + 37.0
	return market + cohorts + COLUMN_GAP


## 截图 QA 和测试可直接展示有数据的格子。
func debug_show_cell(cell_index: int) -> bool:
	if _view_model == null or _map == null or _map.cell_at(cell_index) == null:
		return false
	var payload: Dictionary = _view_model.build(cell_index)
	return bool(payload.get("ok", false)) and _apply_payload(cell_index, payload, false)
