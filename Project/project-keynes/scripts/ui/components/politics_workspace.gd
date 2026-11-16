extends Control
class_name PoliticsWorkspace

## 政治栏：体制 / 理念两章，用与科技、军事栏同一套卷宗索引签切换。
## 页头右侧在理念章给出现行体制（体制章里已有整张章程卡，不重复）。

signal target_cells_requested(cells: PackedInt32Array)

const CHAPTERS := [
	{"id": "regime", "label": "体制", "icon": &"country.politics",
		"question": "由谁议事、国库能做什么、哪些阶层拥护"},
	{"id": "ideology", "label": "理念", "icon": &"hud.country.ideology",
		"question": "推行哪些国家理念与民族精神"},
]
## 与 DossierChapterNav 的绘制留白一致（图标 + 文字 + 两侧内边距）。
const CHAPTER_NAV_PAD := 22.0
const CHAPTER_NAV_MIN_WIDTH := 220.0

var _model: Dictionary = {}
var _player_controller = null
var _compact := false
var _active_tab := "regime"

@onready var _nav: DossierChapterNav = %ChapterNav
@onready var _summary: Label = %Summary
@onready var _regime: Control = $Root/Pages/Regime
@onready var _ideology: Control = $Root/Pages/IdeologyScroll/Ideology
@onready var _ideology_scroll: ScrollContainer = $Root/Pages/IdeologyScroll


func _ready() -> void:
	_nav.set_chapters(_chapter_definitions(), _active_tab)
	_size_nav()
	_nav.chapter_selected.connect(select_tab)
	_summary.autowrap_mode = TextServer.AUTOWRAP_OFF
	# 理念工作区是锚定式布局，最小尺寸不会上报给外层容器：矮视口下它会向上下
	# 两头溢出，盖住章节签。这里把内部 Root 的最小高度转成外层可滚动的高度。
	var ideology_root := _ideology.get_node_or_null("Root") as Control
	if ideology_root != null:
		ideology_root.grow_horizontal = Control.GROW_DIRECTION_END
		ideology_root.grow_vertical = Control.GROW_DIRECTION_END
		ideology_root.minimum_size_changed.connect(_sync_ideology_height)
		_sync_ideology_height()
	if _ideology.has_signal("target_cells_requested"):
		_ideology.connect("target_cells_requested",
			func(cells: PackedInt32Array): target_cells_requested.emit(cells))
	if _player_controller != null:
		set_player_controller(_player_controller)
	if not _model.is_empty():
		_apply_model()
	_apply_tab_state()


func set_player_controller(controller) -> void:
	_player_controller = controller
	if not is_node_ready():
		return
	if _regime.has_method("set_player_controller"):
		_regime.set_player_controller(controller)
	if _ideology.has_method("set_player_controller"):
		_ideology.set_player_controller(controller)


func set_model(model: Dictionary) -> void:
	_model = model
	if is_node_ready():
		_apply_model()


func refresh_model(model: Dictionary) -> void:
	set_model(model)


func set_compact(compact: bool) -> void:
	_compact = compact
	if not is_node_ready():
		return
	if _regime.has_method("set_compact"):
		_regime.set_compact(compact)
	if _ideology.has_method("set_compact"):
		_ideology.set_compact(compact)
	_size_nav()


func active_tab() -> String:
	return _active_tab


func select_tab(tab_id: String) -> void:
	if tab_id != "regime" and tab_id != "ideology":
		return
	var changed := tab_id != _active_tab
	_active_tab = tab_id
	if not is_node_ready():
		return
	if _nav.current != tab_id:
		_nav.select(tab_id)
	_apply_tab_state()
	if changed and tab_id == "regime" and _regime.has_method("focus_initial_action"):
		_regime.call_deferred("focus_initial_action")


func _sync_ideology_height() -> void:
	var ideology_root := _ideology.get_node_or_null("Root") as Control
	if ideology_root == null:
		return
	var needed := ideology_root.get_combined_minimum_size().y
	if absf(_ideology.custom_minimum_size.y - needed) > 0.5:
		_ideology.custom_minimum_size.y = needed


func _chapter_definitions() -> Array:
	return CHAPTERS.duplicate(true)


func _size_nav() -> void:
	var width := 0.0
	var font := UITokens.dossier_font("sans_strong")
	for chapter in CHAPTERS:
		width += ceilf(font.get_string_size(String(chapter.label),
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, DossierChapterNav.FONT_SIZE).x
			+ DossierChapterNav.ICON + CHAPTER_NAV_PAD)
	width = maxf(CHAPTER_NAV_MIN_WIDTH, width)
	# DossierChapterNav 的 _init 会把自己设成横向填满；页头右侧还有摘要，收回来。
	_nav.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if absf(_nav.custom_minimum_size.x - width) > 0.5:
		_nav.custom_minimum_size.x = width
		_nav.call_deferred("_relayout")


func _apply_model() -> void:
	var politics: Dictionary = _model.get("politics", _model)
	var regime_model := politics.duplicate(false)
	if _model.has("current_day"):
		regime_model["current_day"] = _model["current_day"]
	_regime.set_model(regime_model)
	_regime.set_compact(_compact)
	# IdeologyWorkspace expects the country model with a top-level `ideology`
	# key. The political view model deliberately keeps that shape intact.
	var ideology_model := politics.duplicate(true)
	for key in ["country_handle", "current_day", "country_name", "facade"]:
		if not ideology_model.has(key) and _model.has(key):
			ideology_model[key] = _model[key]
	_ideology.set_model(ideology_model)
	_ideology.set_compact(_compact)
	_update_summary()


func _update_summary() -> void:
	var politics: Dictionary = _model.get("politics", _model)
	var regime: Dictionary = politics.get("regime", {})
	var name := String(regime.get("current_name", ""))
	_summary.text = "现行体制 · %s" % name if not name.is_empty() else ""
	_summary.visible = _active_tab == "ideology" and not _summary.text.is_empty()


func _apply_tab_state() -> void:
	_regime.visible = _active_tab == "regime"
	_ideology_scroll.visible = _active_tab == "ideology"
	_update_summary()
