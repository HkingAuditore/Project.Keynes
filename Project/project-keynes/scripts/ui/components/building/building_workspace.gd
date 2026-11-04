extends Control
class_name BuildingWorkspace

## 外挂在地块档案上的「营造目录」窗口。
##
## 页骨与对象详情 / 家族档案 / 军务档案同源：Kicker + 大标题 + 副标题页头、
## PKDossierBand KPI 带、DossierChapterNav 部门索引签、纸片行、纸笺提示。
##
## 页面只读 view model 的输出（CellInspectorViewModel.build_construction_model）：
## 一行 = 一座可营造建筑，按钮的可用性表达「现在能不能建」，细节走 hover 提示。
## 刷新契约：查询身份（地块 + 部门 + 搜索 + 偏移）不变时只写值，不重建行节点。

signal closed()
signal page_requested(sector: String, search: String, sort: String, offset: int)
signal build_requested(request: Dictionary)

const RowScene := preload("res://scenes/ui/building_option_row.tscn")
const HoverCardScene := preload("res://scenes/ui/building_hover_card.tscn")
## 点击后短暂禁用同一行：只防手抖重复下单，不阻止「今天连排两座」。
const PENDING_SECONDS := 1.2

@onready var _header_icon: IconBadge = %HeaderIcon
@onready var _kicker: Label = %Kicker
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _close_button: Button = %CloseButton
@onready var _sector_nav: DossierChapterNav = %SectorNav
@onready var _sort_label: Label = %SortRow/SortLabel
@onready var _sort_buttons: Dictionary = {
	"recommended": %SortRecommended,
	"cost": %SortCost,
	"newest": %SortNewest,
}
@onready var _filter_row: Control = %FilterRow
@onready var _search: LineEdit = %Search
@onready var _count_label: Label = %Count
@onready var _scroll: ScrollContainer = %Scroll
@onready var _rows: VBoxContainer = %Rows
@onready var _empty_note: Control = %EmptyNote
@onready var _empty_label: Label = %EmptyLabel
@onready var _footer: Control = %Footer
@onready var _prev_button: Button = %PrevButton
@onready var _page_label: Label = %PageLabel
@onready var _next_button: Button = %NextButton
@onready var _status_note: Control = %StatusNote
@onready var _status_label: Label = %StatusLabel

var _model: Dictionary = {}
var _identity := ""
var _rows_by_id: Dictionary = {}
var _chapters: Array = []
var _sector_signature := ""
var _pending_ids: Dictionary = {}
var _feedback := ""
var _feedback_ok := true
var _hover_card: BuildingHoverCard
var _hovered_row_id := ""


func _ready() -> void:
	if _rows == null:
		push_error("BuildingWorkspace 必须通过 building_workspace.tscn 实例化。")
		return
	_hover_card = HoverCardScene.instantiate() as BuildingHoverCard
	add_child(_hover_card)
	_hover_card.z_index = 40
	_hover_card.hide_card()
	IconButton.apply(_close_button, &"action.close", IconButton.SMALL, "关闭")
	_header_icon.set_semantic(&"economy.building", UITokens.DOSSIER_BRASS)
	_close_button.pressed.connect(func() -> void: closed.emit())
	_sector_nav.chapter_selected.connect(_on_sector_selected)
	for sort_id in _sort_buttons.keys():
		(_sort_buttons[sort_id] as Button).pressed.connect(
			_on_sort_selected.bind(String(sort_id)))
	_sort_label.text = "排序"
	_search.text_submitted.connect(_on_search_submitted)
	_prev_button.pressed.connect(_on_prev_pressed)
	_next_button.pressed.connect(_on_next_pressed)
	if not _model.is_empty():
		_apply_model()


func set_model(model: Dictionary) -> void:
	_model = model
	if _rows == null:
		return
	if _apply_model():
		call_deferred("_focus_first_buildable")


## 同一个查询身份重发一次请求（次日结算 / 打开窗口时由外层调用）。
func request_refresh() -> void:
	if not visible or not is_inside_tree() or _model.is_empty():
		return
	var query: Dictionary = _model.get("query", {})
	page_requested.emit(String(query.get("sector", "")),
		String(query.get("search", "")), String(query.get("sort", "recommended")),
		int(query.get("offset", 0)))


func set_feedback(message: String, ok: bool) -> void:
	_feedback = message.strip_edges()
	_feedback_ok = ok
	if not ok:
		_clear_pending()
	_apply_status()


func clear() -> void:
	_model = {}
	_identity = ""
	_sector_signature = ""
	_feedback = ""
	_feedback_ok = true
	_pending_ids.clear()
	_hovered_row_id = ""
	if _hover_card != null:
		_hover_card.hide_card()
	_chapters = []
	if _rows == null:
		return
	_clear_rows()
	_status_note.visible = false
	_empty_note.visible = false


## 查询身份：地块 + 部门 + 搜索词 + 排序档 + 偏移。身份不变 = 同一张目录页。
static func model_identity(model: Dictionary) -> String:
	return "%d|%s|%s|%s|%d" % [int(model.get("cell", -1)),
		String(model.get("sector", "")), String(model.get("search", "")),
		String(model.get("sort", "")), int(model.get("offset", 0))]


## 返回「是否换了查询身份」（决定要不要重建行节点并恢复焦点）。
func _apply_model() -> bool:
	if _model.is_empty():
		clear()
		return false
	var identity := model_identity(_model)
	var rebuild := identity != _identity
	if rebuild:
		_identity = identity
		_pending_ids.clear()
		_feedback = ""
		_feedback_ok = true
	_apply_header(_model.get("header", {}))
	_apply_sectors(_model.get("sectors", []), String(_model.get("sector", "")))
	_apply_sorts(_model.get("sorts", []), String(_model.get("sort", "recommended")))
	var items: Array = _model.get("items", [])
	_apply_filters()
	_apply_rows(items, rebuild)
	_apply_paging()
	if rebuild and _scroll != null:
		_scroll.scroll_vertical = 0
	_apply_status()
	return rebuild


func _apply_header(header: Dictionary) -> void:
	_kicker.text = String(header.get("kicker", "营造目录"))
	_title.text = String(header.get("title", "新建建筑"))
	_subtitle.text = String(header.get("subtitle", ""))
	_subtitle.tooltip_text = _subtitle.text
	_subtitle.visible = not _subtitle.text.is_empty()


func _apply_sectors(sectors: Array, current: String) -> void:
	var signature := PackedStringArray()
	for raw in sectors:
		var sector: Dictionary = raw
		signature.append("%s:%d" % [String(sector.get("id", "")),
			int(sector.get("count", 0))])
	var joined := "|".join(signature)
	if joined != _sector_signature:
		_sector_signature = joined
		_chapters = []
		for raw in sectors:
			var sector: Dictionary = raw
			_chapters.append({
				"id": String(sector.get("id", "")),
				"label": String(sector.get("label", "")),
				"icon": IconBadge.normalize_icon(sector.get("icon", "")),
				"question": String(sector.get("question", "")),
			})
		_sector_nav.set_chapters(_chapters, current)
	else:
		_sector_nav.select(current, false)
	_sector_nav.visible = _chapters.size() > 1


## 排序签：模型给出 id/label/tooltip/selected，这里只写文字与按下态。
func _apply_sorts(sorts: Array, selected: String) -> void:
	for raw in sorts:
		var sort: Dictionary = raw
		var sort_id := String(sort.get("id", ""))
		var button := _sort_buttons.get(sort_id) as Button
		if button == null:
			continue
		button.text = String(sort.get("label", sort_id))
		button.tooltip_text = String(sort.get("tooltip", ""))
		button.set_pressed_no_signal(sort_id == selected)


## 搜索框与翻页只在目录规模超出一页（或已在筛选）时出现：目录短时保持单屏干净。
func _apply_filters() -> void:
	var total := int(_model.get("total", 0))
	var limit := maxi(1, int(_model.get("limit", 1)))
	var search := String(_model.get("search", ""))
	var needed := total > limit or not search.strip_edges().is_empty()
	_filter_row.visible = needed
	if not needed:
		_count_label.text = ""
		return
	if _search.text != search:
		_search.text = search
	_count_label.text = "%d 项" % total


func _apply_rows(items: Array, rebuild: bool) -> void:
	if rebuild or _rows_by_id.size() != items.size() or not _rows_match(items):
		_build_rows(items)
	for raw in items:
		var item: Dictionary = raw
		var row := _rows_by_id.get(String(item.get("building_id", ""))) \
			as BuildingOptionRow
		if row == null:
			continue
		row.set_row(item, _pending_ids.has(String(item.get("building_id", ""))))
		if String(item.get("building_id", "")) == _hovered_row_id \
				and _hover_card != null and _hover_card.visible:
			_hover_card.refresh(item)
	var empty := items.is_empty()
	_empty_note.visible = empty
	_scroll.visible = not empty
	_empty_label.text = _empty_text() if empty else ""


func _rows_match(items: Array) -> bool:
	for raw in items:
		if not _rows_by_id.has(String((raw as Dictionary).get("building_id", ""))):
			return false
	return true


func _build_rows(items: Array) -> void:
	_clear_rows()
	if _hover_card != null:
		_hover_card.hide_card()
	_hovered_row_id = ""
	for raw in items:
		var item: Dictionary = raw
		var row := RowScene.instantiate() as BuildingOptionRow
		_rows.add_child(row)
		row.build_requested.connect(_on_row_build_requested)
		row.hover_started.connect(_on_row_hover_started)
		row.hover_ended.connect(_on_row_hover_ended)
		_rows_by_id[String(item.get("building_id", ""))] = row


func _on_row_hover_started(row_data: Dictionary, source: Control) -> void:
	if _hover_card == null or not visible:
		return
	_hovered_row_id = String(row_data.get("building_id", ""))
	_hover_card.show_for(row_data, source, self)


func _on_row_hover_ended() -> void:
	_hovered_row_id = ""
	if _hover_card != null:
		_hover_card.hide_card()


func _empty_text() -> String:
	var message := String(_model.get("message", "")).strip_edges()
	if not message.is_empty():
		return message
	if not String(_model.get("search", "")).strip_edges().is_empty():
		return "没有匹配的建筑。"
	return "本部门当前没有可营造的项目。"


func _apply_paging() -> void:
	var total := int(_model.get("total", 0))
	var offset := int(_model.get("offset", 0))
	var limit := maxi(1, int(_model.get("limit", 1)))
	var items: Array = _model.get("items", [])
	_footer.visible = total > limit and not items.is_empty()
	if not _footer.visible:
		return
	_prev_button.disabled = offset <= 0
	_next_button.disabled = offset + items.size() >= total
	var label := String(_model.get("page_label", ""))
	_page_label.text = label if not label.is_empty() \
		else "%d–%d / %d" % [offset + 1, offset + items.size(), total]


func _apply_status() -> void:
	if _status_label == null:
		return
	var text := _feedback
	var ok := _feedback_ok
	if text.is_empty() and bool(_model.get("data_pending", false)) \
			and not _rows_by_id.is_empty():
		text = "正在刷新营造报价…"
		ok = true
	_status_note.visible = not text.is_empty()
	_status_label.text = text
	_status_label.add_theme_color_override("font_color",
		UITokens.DOSSIER_VERDIGRIS if ok else UITokens.DOSSIER_OXBLOOD)


func _clear_rows() -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_rows_by_id.clear()


func _focus_first_buildable() -> void:
	if not visible or _rows == null:
		return
	for raw in _model.get("items", []):
		var item: Dictionary = raw
		if not bool(item.get("eligible", false)):
			continue
		var row := _rows_by_id.get(String(item.get("building_id", ""))) \
			as BuildingOptionRow
		if row == null:
			continue
		var button := row.get_node_or_null("Row/BuildButton") as Button
		if button != null and button.focus_mode != Control.FOCUS_NONE:
			button.grab_focus()
			return


func _current_sort() -> String:
	return String(_model.get("sort", "recommended"))


func _on_sector_selected(sector_id: String) -> void:
	if sector_id == String(_model.get("sector", "")):
		return
	page_requested.emit(sector_id, String(_model.get("search", "")),
		_current_sort(), 0)


func _on_sort_selected(sort_id: String) -> void:
	_apply_sorts(_model.get("sorts", []), sort_id)
	if sort_id == _current_sort():
		return
	page_requested.emit(String(_model.get("sector", "")),
		String(_model.get("search", "")), sort_id, 0)


func _on_search_submitted(text: String) -> void:
	page_requested.emit(String(_model.get("sector", "")), text,
		_current_sort(), 0)


func _on_prev_pressed() -> void:
	var offset := maxi(0, int(_model.get("offset", 0)) - int(_model.get("limit", 1)))
	page_requested.emit(String(_model.get("sector", "")),
		String(_model.get("search", "")), _current_sort(), offset)


func _on_next_pressed() -> void:
	var offset := int(_model.get("offset", 0)) + maxi(1, int(_model.get("limit", 1)))
	page_requested.emit(String(_model.get("sector", "")),
		String(_model.get("search", "")), _current_sort(), offset)


func _on_row_build_requested(building_id: StringName) -> void:
	var key := String(building_id)
	if key.is_empty():
		return
	_pending_ids[key] = true
	if is_inside_tree():
		get_tree().create_timer(PENDING_SECONDS).timeout.connect(
			_release_pending.bind(key), CONNECT_ONE_SHOT)
	var request := {"building_id": building_id}
	# 军事部门的条目带原生 dense 序（`state.build` 的 `building` 参数），必须一起
	# 送到守卫层，否则它会被当成经济建筑的稳定 id。
	for raw in _model.get("items", []):
		var item: Dictionary = raw
		if String(item.get("building_id", "")) != key:
			continue
		if item.has("military_index"):
			request["military_index"] = int(item.get("military_index", -1))
			request["op"] = "state.build"
		break
	build_requested.emit(request)


func _release_pending(building_id: String) -> void:
	_pending_ids.erase(building_id)
	var row := _rows_by_id.get(building_id) as BuildingOptionRow
	if row != null:
		row.set_pending(false)


func _clear_pending() -> void:
	_pending_ids.clear()
	for key in _rows_by_id.keys():
		var row := _rows_by_id[key] as BuildingOptionRow
		if row != null:
			row.set_pending(false)
