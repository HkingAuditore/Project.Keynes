extends Control
class_name CellBoard

## 悬停地块时从画面左侧浮出的两张纸片：市价与民情。
##
## 只读已经算好的 view model，自己不查模拟。可见性判定（指针静止、迷雾、
## 指针是否落在 UI 上、滚屏/暂停）全部沿用悬停卡，本组件只负责停稳后的取数
## 与呈现，避免两套判定互相打脸。
##
## 动效口径：整列从左侧滑入 180ms 缓出，两张纸片错开 60ms 淡入；换格只换内容、
## 不重播入场——扫图时反复重播会把左侧闪成一片。

signal resolved(cell_index: int, ok: bool)

const BOARD_WIDTH := 520.0
const COLUMN_GAP := 10.0
const SLOT_COUNT := 5

## 停稳多久才开始查原生。更短的停留只是扫图路过，不值得占掉原生
## read-view 的订阅位（上限 128 条）。
const DWELL_MSEC := 300
## read-view 未就绪时的重试间隔与次数上限（约 1 秒）。
const RETRY_MSEC := 150
const RETRY_LIMIT := 7

const SLIDE_IN_SEC := 0.18
const SLIDE_OUT_SEC := 0.13
const SLIDE_OFFSET := 20.0
const STAGGER_SEC := 0.06

const ROW_HEIGHT := 36.0
const COHORT_ROW_HEIGHT := 64.0
const COHORT_LINE_HEIGHT := 28.0
const COHORT_SIGNAL_HEIGHT := 26.0
const HEADER_HEIGHT := 26.0
const COLUMN_SEPARATION := 8.0

const MARKET_NAME_MIN := 132.0
const MARKET_BAR_W := 48.0
const MARKET_STOCK_W := 80.0
const MARKET_PRICE_W := 80.0
const COHORT_NAME_MIN := 90.0
const COHORT_POP_W := 76.0
const COHORT_FUNDS_W := 90.0
const COHORT_INCOME_W := 88.0
const COHORT_LIVING_MIN := 104.0
const COHORT_SIGNAL_W := 124.0

const BAR_HEIGHT := 8.0
const SHARE_BAR_HEIGHT := 2.0

## 扩大的纸面同时增大文字，避免只增加留白而读数仍然偏小。
const HEADER_SIZE := 16
const NAME_SIZE := 18
const VALUE_SIZE := 18
const SMALL_SIZE := 16

## 三段压缩的可用高度阈值（可用高度 = 地图安全区高度）。
const FULL_HEIGHT := 650.0
const COMPACT_HEIGHT := 510.0
const COHORTS_HEIGHT := 320.0

var _map: MapData
var _view_model: CellBoardViewModel
var _hover_view_model: CellHoverViewModel

var _pending_cell := -1
var _shown_cell := -1
var _shown_day := -1
var _dwell_timer: Timer
var _retry_timer: Timer
var _retry_left := 0
var _cohort_capacity := SLOT_COUNT
var _show_market := true
var _show_cohorts := true
var _suppressed := false
var _slide_tween: Tween
var _hiding := false

var _slide: Control
var _column: VBoxContainer
var _market_card: PanelContainer
var _cohort_card: PanelContainer
var _market_rows: VBoxContainer
var _cohort_rows: VBoxContainer
var _market_header: HBoxContainer
var _cohort_header: HBoxContainer
var _market_slots: Array[Dictionary] = []
var _cohort_slots: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 暂停菜单打开时也必须能退场，否则会冻结在画面上。
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	modulate.a = 1.0
	custom_minimum_size = Vector2(BOARD_WIDTH, 0.0)
	_build_tree()
	_build_timers()


# ───────────────────────────── 组装 ─────────────────────────────

func _build_tree() -> void:
	_slide = Control.new()
	_slide.name = "Slide"
	_slide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_slide.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_slide.custom_minimum_size = Vector2(BOARD_WIDTH, 0.0)
	add_child(_slide)

	_column = VBoxContainer.new()
	_column.name = "Column"
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_column.custom_minimum_size = Vector2(BOARD_WIDTH, 0.0)
	_column.add_theme_constant_override("separation", COLUMN_GAP)
	_slide.add_child(_column)

	var market_body := _build_card("MarketCard")
	_market_card = market_body["card"]
	_column.add_child(_market_card)
	_market_header = _build_market_header()
	(market_body["body"] as VBoxContainer).add_child(_market_header)
	(market_body["body"] as VBoxContainer).add_child(_make_rule())
	_market_rows = VBoxContainer.new()
	_market_rows.name = "Rows"
	_market_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_market_rows.add_theme_constant_override("separation", 0)
	(market_body["body"] as VBoxContainer).add_child(_market_rows)

	var cohort_body := _build_card("CohortCard")
	_cohort_card = cohort_body["card"]
	_column.add_child(_cohort_card)
	_cohort_header = _build_cohort_header()
	(cohort_body["body"] as VBoxContainer).add_child(_cohort_header)
	(cohort_body["body"] as VBoxContainer).add_child(_make_rule())
	_cohort_rows = VBoxContainer.new()
	_cohort_rows.name = "Rows"
	_cohort_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cohort_rows.add_theme_constant_override("separation", 3)
	(cohort_body["body"] as VBoxContainer).add_child(_cohort_rows)

	for _index in SLOT_COUNT:
		_market_slots.append(_build_market_row())
	for _index in SLOT_COUNT:
		_cohort_slots.append(_build_cohort_row())


func _build_card(node_name: String) -> Dictionary:
	var card := PanelContainer.new()
	card.name = node_name
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.theme_type_variation = &"PKPaperPopup"
	# 撕纸边与纸面阴影都在纸框内侧占位，内容必须从里面再退一圈，
	# 否则最右一列数字会被纸的毛边切掉。用内层 MarginContainer 而不是
	# 覆盖 panel stylebox —— 覆盖会把撕纸边顶成圆角纯色板。
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 2)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 6)
	card.add_child(margin)
	var body := VBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_theme_constant_override("separation", 4)
	margin.add_child(body)
	return {"card": card, "body": body}


func _build_timers() -> void:
	_dwell_timer = _make_resolve_timer()
	_retry_timer = _make_resolve_timer()


func _make_resolve_timer() -> Timer:
	var timer := Timer.new()
	timer.one_shot = true
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	timer.timeout.connect(_on_resolve_timer_elapsed)
	add_child(timer)
	return timer


# ───────────────────────────── 表头 ─────────────────────────────

func _build_market_header() -> HBoxContainer:
	var header := _make_row_box("Header", HEADER_HEIGHT)
	# 表头只给列名：五枚物资纸贴本身就是这张表的标题，不再加「本地市场」这类自证说明。
	header.add_child(_make_icon_header(&"economy.building.market", MARKET_NAME_MIN, "物资"))
	header.add_child(_make_spacer(MARKET_BAR_W))
	header.add_child(_make_text_header("储量", MARKET_STOCK_W))
	header.add_child(_make_text_header("价格", MARKET_PRICE_W))
	return header


func _build_cohort_header() -> HBoxContainer:
	var header := _make_row_box("Header", HEADER_HEIGHT)
	header.add_child(_make_icon_header(&"population.crowd", COHORT_NAME_MIN, "阶层"))
	header.add_child(_make_text_header("人口", COHORT_POP_W))
	header.add_child(_make_text_header("存款", COHORT_FUNDS_W))
	header.add_child(_make_text_header("收入", COHORT_INCOME_W))
	return header


func _make_row_box(node_name: String, min_height: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(0.0, min_height)
	row.add_theme_constant_override("separation", COLUMN_SEPARATION)
	return row


func _make_icon_header(icon_key: StringName, label_width: float, text: String) -> Control:
	var row := HBoxContainer.new()
	row.name = "Lead"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(label_width, HEADER_HEIGHT)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 4)
	var badge := IconMark.new()
	badge.semantic = icon_key
	badge.custom_minimum_size = Vector2(18.0, 18.0)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)
	var label := _make_header_text(text)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	return row


func _make_text_header(text: String, width: float) -> Label:
	var label := _make_header_text(text)
	label.custom_minimum_size = Vector2(width, HEADER_HEIGHT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _make_header_text(text: String) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.theme_type_variation = &"PKDossierKicker"
	label.add_theme_font_size_override("font_size", HEADER_SIZE)
	label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	return label


func _make_spacer(width: float) -> Control:
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.custom_minimum_size = Vector2(width, 0.0)
	return spacer


## 表头与数据行之间的一道细线：纸片上的表格靠这条线分栏，不靠空行。
func _make_rule() -> Control:
	var row := Control.new()
	row.name = "Rule"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(0.0, 5.0)
	var line := ColorRect.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.color = UITokens.DOSSIER_RULE
	line.set_anchors_preset(Control.PRESET_TOP_WIDE)
	line.offset_top = 1.0
	line.offset_bottom = 2.0
	row.add_child(line)
	var lead := ColorRect.new()
	lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lead.color = UITokens.DOSSIER_BRASS
	lead.set_anchors_preset(Control.PRESET_TOP_LEFT)
	lead.offset_right = 26.0
	lead.offset_top = 1.0
	lead.offset_bottom = 2.0
	row.add_child(lead)
	return row


# ───────────────────────────── 行情行 ─────────────────────────────

func _build_market_row() -> Dictionary:
	var root := VBoxContainer.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	root.add_theme_constant_override("separation", 0)
	var line := _make_row_box("Line", 0.0)
	root.add_child(line)

	var badge := IconMark.new()
	badge.custom_minimum_size = Vector2(24.0, 24.0)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(badge)

	var name_label := _make_value_label(NAME_SIZE, UITokens.DOSSIER_INK)
	name_label.custom_minimum_size = Vector2(MARKET_NAME_MIN, 0.0)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(name_label)

	var bar := _make_ratio_bar(MARKET_BAR_W, BAR_HEIGHT, UITokens.DOSSIER_BRASS)
	line.add_child(bar["root"])

	var stock_label := _make_value_label(VALUE_SIZE, UITokens.DOSSIER_INK_SOFT)
	stock_label.custom_minimum_size = Vector2(MARKET_STOCK_W, 0.0)
	stock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(stock_label)

	var price_label := _make_value_label(VALUE_SIZE, UITokens.DOSSIER_INK)
	price_label.custom_minimum_size = Vector2(MARKET_PRICE_W, 0.0)
	price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(price_label)

	_market_rows.add_child(root)
	return {
		"root": root,
		"badge": badge,
		"name": name_label,
		"bar": bar,
		"stock": stock_label,
		"price": price_label,
	}


# ───────────────────────────── 阶层行 ─────────────────────────────

func _build_cohort_row() -> Dictionary:
	var root := VBoxContainer.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.custom_minimum_size = Vector2(0.0, COHORT_ROW_HEIGHT)
	root.add_theme_constant_override("separation", 1)

	var line := _make_row_box("Line", COHORT_LINE_HEIGHT)
	root.add_child(line)

	var badge := IconMark.new()
	badge.custom_minimum_size = Vector2(24.0, 24.0)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(badge)

	var name_label := _make_value_label(NAME_SIZE, UITokens.DOSSIER_INK)
	name_label.custom_minimum_size = Vector2(COHORT_NAME_MIN, 0.0)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(name_label)

	var population_label := _make_value_label(VALUE_SIZE, UITokens.DOSSIER_INK)
	population_label.custom_minimum_size = Vector2(COHORT_POP_W, 0.0)
	population_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(population_label)

	var funds_label := _make_value_label(VALUE_SIZE, UITokens.DOSSIER_INK_SOFT)
	funds_label.custom_minimum_size = Vector2(COHORT_FUNDS_W, 0.0)
	funds_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(funds_label)

	var income_label := _make_value_label(VALUE_SIZE, UITokens.DOSSIER_VERDIGRIS)
	income_label.custom_minimum_size = Vector2(COHORT_INCOME_W, 0.0)
	income_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(income_label)

	# 第二行是三条读数：生活水平（贴纸 + 词）/ 满意度 / 组织度，
	# 后两条用同一套 0..1 量程的细条，读者不需要看刻度也知道谁更高。
	var signals := _make_row_box("Signals", COHORT_SIGNAL_HEIGHT)
	signals.add_theme_constant_override("separation", 4)
	signals.add_child(_make_spacer(24.0))
	root.add_child(signals)

	var living := HBoxContainer.new()
	living.mouse_filter = Control.MOUSE_FILTER_IGNORE
	living.custom_minimum_size = Vector2(COHORT_LIVING_MIN, 0.0)
	living.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	living.add_theme_constant_override("separation", 3)
	var living_badge := IconMark.new()
	living_badge.custom_minimum_size = Vector2(18.0, 18.0)
	living_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	living.add_child(living_badge)
	var living_label := _make_value_label(SMALL_SIZE, UITokens.DOSSIER_INK_SOFT)
	living.add_child(living_label)
	signals.add_child(living)

	var satisfaction := _make_signal_cell(COHORT_SIGNAL_W, MARKET_BAR_W, UITokens.DOSSIER_VERDIGRIS)
	signals.add_child(satisfaction["root"])
	var organization := _make_signal_cell(COHORT_SIGNAL_W, MARKET_BAR_W, UITokens.ACCENT)
	signals.add_child(organization["root"])

	# 当地影响力占比：贴在阶层名下面的一小截铜色横线，长度就是占比。
	# 不画轨道、不写百分比——名次由这截线的长短解释。
	var share_row := HBoxContainer.new()
	share_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	share_row.add_theme_constant_override("separation", 0)
	share_row.add_child(_make_spacer(24.0))
	root.add_child(share_row)
	var share := _make_ratio_bar(0.0, SHARE_BAR_HEIGHT, UITokens.DOSSIER_BRASS)
	(share["root"] as Control).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	(share["track"] as ColorRect).color = Color(0.0, 0.0, 0.0, 0.0)
	share_row.add_child(share["root"])

	_cohort_rows.add_child(root)
	return {
		"root": root,
		"badge": badge,
		"name": name_label,
		"population": population_label,
		"funds": funds_label,
		"income": income_label,
		"living_badge": living_badge,
		"living": living_label,
		"satisfaction": satisfaction,
		"organization": organization,
		"share": share,
	}


func _make_signal_cell(min_width: float, bar_width: float, accent: Color) -> Dictionary:
	var root := HBoxContainer.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.custom_minimum_size = Vector2(min_width, 0.0)
	root.add_theme_constant_override("separation", 3)
	var bar := _make_ratio_bar(bar_width, BAR_HEIGHT, accent)
	root.add_child(bar["root"])
	var label := _make_value_label(SMALL_SIZE, UITokens.DOSSIER_INK_SOFT)
	root.add_child(label)
	return {"root": root, "bar": bar, "label": label}


func _make_value_label(font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


## 比例条：轨道 + 填充。填充宽度走锚点比例，父容器变宽时自动跟着走。
func _make_ratio_bar(width: float, height: float, accent: Color) -> Dictionary:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.custom_minimum_size = Vector2(width, height)
	root.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var track := ColorRect.new()
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.color = UITokens.DOSSIER_TRACK
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(track)
	var fill := ColorRect.new()
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.color = accent
	fill.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	fill.anchor_right = 0.0
	root.add_child(fill)
	return {"root": root, "fill": fill, "track": track}


func _set_ratio(bar: Dictionary, ratio: float) -> void:
	var fill := bar.get("fill") as ColorRect
	if fill != null:
		fill.anchor_right = clampf(ratio, 0.0, 1.0)


# ───────────────────────────── 上下文 ─────────────────────────────

## 展板自己持有数据层：宿主只在世界绑定时调一次，此后每格取数都走内部缓存。
## 经济门面用 Callable 按需解析，避免「配置早于经济运行时绑定」时抓到 null。
func configure(map: MapData, hover_view_model: CellHoverViewModel,
		economy_provider: Callable, inspector: CellInspectorViewModel,
		world_clock: WorldClock) -> void:
	_map = map
	_hover_view_model = hover_view_model
	if _view_model == null:
		_view_model = CellBoardViewModel.new()
	_view_model.set_context(map, economy_provider, inspector, world_clock)
	reset_for_world()


func reset_for_world() -> void:
	_pending_cell = -1
	_shown_cell = -1
	_shown_day = -1
	_retry_left = 0
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
	_retry_left = RETRY_LIMIT
	_retry_timer.stop()
	_dwell_timer.start(float(DWELL_MSEC) / 1000.0)
	# 已经在展示别的格子时，新格子数据没到之前不闪走旧内容。
	if _shown_cell < 0:
		hide_board(false)


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
	_retry_left = RETRY_LIMIT
	_retry_timer.stop()
	_resolve(cell_index)


func _on_resolve_timer_elapsed() -> void:
	if _pending_cell >= 0:
		_resolve(_pending_cell)


func _resolve(cell_index: int) -> void:
	var cell := _map.cell_at(cell_index)
	if cell == null:
		hide_board(false)
		return
	if _hover_view_model != null:
		var hover: Dictionary = _hover_view_model.build(cell)
		if not bool(hover.get("ok", false)) or not bool(hover.get("settled", false)):
			# 没有聚落就没有市场、也没有阶层：不摆两格空白。
			hide_board(false)
			return
	var payload: Dictionary = _view_model.build(cell_index)
	if not bool(payload.get("ok", false)):
		if _retry_left > 0:
			_retry_left -= 1
			_retry_timer.start(float(RETRY_MSEC) / 1000.0)
		else:
			hide_board(false)
		resolved.emit(cell_index, false)
		return
	_retry_left = 0
	if not _apply_payload(cell_index, payload, true):
		hide_board(false)
		resolved.emit(cell_index, false)
		return
	resolved.emit(cell_index, true)


func _apply_payload(cell_index: int, payload: Dictionary, animate: bool) -> bool:
	var market_rows: Array = (payload.get("market", {}) as Dictionary).get("rows", [])
	var cohort_rows: Array = (payload.get("cohorts", {}) as Dictionary).get("rows", [])
	if market_rows.is_empty() and cohort_rows.is_empty():
		return false
	_apply_rows(market_rows, cohort_rows)
	_shown_cell = cell_index
	_shown_day = int(payload.get("day", -1))
	show_board(animate)
	return true


# ───────────────────────────── 呈现 ─────────────────────────────

func _apply_rows(market_rows: Array, cohort_rows: Array) -> void:
	_apply_market_rows(market_rows)
	_apply_cohort_rows(cohort_rows)


func _apply_market_rows(rows: Array) -> void:
	var visible_count := mini(rows.size(), _market_slots.size())
	for index in _market_slots.size():
		var slot: Dictionary = _market_slots[index]
		var root := slot["root"] as Control
		root.visible = index < visible_count
		if not root.visible:
			continue
		var row: Dictionary = rows[index]
		(slot["badge"] as IconMark).semantic = StringName(String(row.get("icon", "")))
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
		(slot["badge"] as IconMark).semantic = StringName(String(row.get("icon", "")))
		(slot["name"] as Label).text = String(row.get("name", ""))
		(slot["population"] as Label).text = String(row.get("population_text", ""))
		(slot["funds"] as Label).text = String(row.get("funds_text", ""))
		var income_label := slot["income"] as Label
		income_label.text = String(row.get("income_text", ""))
		income_label.add_theme_color_override("font_color",
			UITokens.DOSSIER_VERDIGRIS if bool(row.get("income_positive", true)) \
				else UITokens.DOSSIER_OXBLOOD)

		var living_badge := slot["living_badge"] as IconMark
		living_badge.semantic = StringName(String(row.get("living_icon", "history")))
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
		_set_fill_color(satisfaction["bar"], satisfaction_accent)

		var organization: Dictionary = slot["organization"]
		# 职业没有异动时原生不单列组织度：那一格留在原位、只留空轨道，
		# 既不伪造 0% 也不让同一列在行与行之间错位。
		var org_value := maxf(float(row.get("organization", -1.0)), 0.0)
		var org_known := float(row.get("organization", -1.0)) >= 0.0
		var org_accent: Color = row.get("organization_accent", UITokens.ACCENT)
		_set_ratio(organization["bar"], org_value)
		_set_fill_color(organization["bar"], org_accent)
		var org_label := organization["label"] as Label
		org_label.text = String(row.get("organization_text", "")) if org_known else ""
		org_label.add_theme_color_override("font_color", org_accent)

		_set_ratio(slot["share"], float(row.get("share", 0.0)))

	_cohort_header.visible = visible_count > 0
	_cohort_card.visible = _show_cohorts and visible_count > 0


func _set_fill_color(bar: Dictionary, color: Color) -> void:
	var fill := bar.get("fill") as ColorRect
	if fill != null and fill.color != color:
		fill.color = color


func show_board(animate: bool) -> void:
	if _hiding:
		_kill_slide_tween()
		_hiding = false
		_slide.position = Vector2.ZERO
		_market_card.modulate.a = 1.0
		_cohort_card.modulate.a = 1.0
	if not visible:
		visible = true
		modulate.a = 1.0
		_slide.position = Vector2(-SLIDE_OFFSET, 0.0)
		if animate and not UIAnimation.reduced_motion():
			_kill_slide_tween()
			_market_card.modulate.a = 0.0
			_cohort_card.modulate.a = 0.0
			_slide_tween = create_tween().set_parallel(true)
			_slide_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			_slide_tween.tween_property(_slide, "position:x", 0.0, SLIDE_IN_SEC)
			_slide_tween.tween_property(_market_card, "modulate:a", 1.0, SLIDE_IN_SEC)
			_slide_tween.tween_property(_cohort_card, "modulate:a", 1.0,
				SLIDE_IN_SEC).set_delay(STAGGER_SEC)
		else:
			_slide.position = Vector2.ZERO
			_market_card.modulate.a = 1.0
			_cohort_card.modulate.a = 1.0
		return
	if _slide.position.x < 0.0:
		# 入场尚未走完（换格打断）：立即回到位，不重播入场。
		_kill_slide_tween()
		_slide.position = Vector2.ZERO
		_market_card.modulate.a = 1.0
		_cohort_card.modulate.a = 1.0
	modulate.a = 1.0


func hide_board(immediate: bool) -> void:
	_shown_cell = -1
	_shown_day = -1
	if not visible:
		return
	if _hiding and not immediate:
		return
	_kill_slide_tween()
	if immediate or UIAnimation.reduced_motion():
		_hiding = false
		visible = false
		_slide.position = Vector2.ZERO
		modulate.a = 1.0
		return
	_hiding = true
	_slide_tween = create_tween().set_parallel(true)
	_slide_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_slide_tween.tween_property(_slide, "position:x", -SLIDE_OFFSET * 0.6, SLIDE_OUT_SEC)
	_slide_tween.tween_property(self, "modulate:a", 0.0, SLIDE_OUT_SEC)
	_slide_tween.chain().tween_callback(_finish_hide)


func _finish_hide() -> void:
	_hiding = false
	visible = false
	_slide.position = Vector2.ZERO
	modulate.a = 1.0


func _kill_slide_tween() -> void:
	if _slide_tween != null and _slide_tween.is_valid():
		_slide_tween.kill()
	_slide_tween = null


# ───────────────────────────── 布局 ─────────────────────────────

## 由 HUD 布局传入左侧可用高度。三段压缩先砍阶层行数，再整块砍掉阶层表，
## 最后连市价也不出——市价比民情更常看，优先保住。
func apply_available_height(available: float) -> void:
	_cohort_capacity = 3 if available < FULL_HEIGHT else SLOT_COUNT
	_show_cohorts = available >= COMPACT_HEIGHT
	_show_market = available >= COHORTS_HEIGHT
	if not _show_cohorts: _cohort_card.visible = false
	if not _show_market: _market_card.visible = false


func desired_height() -> float:
	# 每张纸片 = 表头 + 行高 × 行数 + 分隔线 + 纸框内外留白。
	var market := HEADER_HEIGHT + float(SLOT_COUNT) * ROW_HEIGHT + 37.0
	if not _show_cohorts:
		return market
	var cohorts := HEADER_HEIGHT + float(_cohort_capacity) * COHORT_ROW_HEIGHT + 37.0
	return market + cohorts + COLUMN_GAP


## 截图 QA / 单测专用：绕过指针状态机直接展示某格。
func debug_show_cell(cell_index: int) -> bool:
	if _view_model == null or _map == null or _map.cell_at(cell_index) == null:
		return false
	var payload: Dictionary = _view_model.build(cell_index)
	if not bool(payload.get("ok", false)) or not _apply_payload(cell_index, payload, false):
		return false
	_slide.position = Vector2.ZERO
	return true


## 只画一枚图标的小徽记：为 15px 纸贴挂完整 IconBadge 场景得不偿失。
class IconMark extends Control:
	var _semantic: StringName = &""

	var semantic: StringName:
		get:
			return _semantic
		set(value):
			if value == _semantic:
				return
			_semantic = value
			queue_redraw()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if _semantic == &"" or _semantic == &"system.unknown":
			return
		var edge := minf(size.x, size.y)
		if edge <= 0.0:
			return
		IconCatalog.draw_icon(self, _semantic,
			Rect2((size - Vector2.ONE * edge) * 0.5, Vector2.ONE * edge))
