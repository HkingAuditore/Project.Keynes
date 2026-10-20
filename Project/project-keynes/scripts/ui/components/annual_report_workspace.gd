extends Control
class_name AnnualReportWorkspace

## 年度报告编排层。
##
## 只做四件事：把视图模型灌给长卷、摆好那张纸、处理键位 / 手柄 / 历史切换、
## 以及开场的纸面沉降。版式全部在 `AnnualReaderView` / `AnnualCoverView` 内部，
## 这里一个像素都不算 —— 除了"纸"本身：
##
##   Desk / DeskGrain  桌面（深色），纸落在上面
##   Sheet/Shadow      纸在桌面上的软投影（四边都出影，跟着纸一起走）
##   Sheet/Paper       那张有限高、会随滚动上下移动的纸
##   Book              Reader（唯一滚动面，封面是它第一屏）
##   Transition        合卷遮罩
##   Toast             复制反馈

signal closed(report_id: int)
signal report_selected(report_id: int)
signal history_page_requested(offset: int)

const SETTLE_SECONDS := 0.55
const PAPER_MASK_PATH := "res://assets/ui/annual_chronicle/paper_tear_mask.png"

var _model: Dictionary = {}
var _compact: bool = false

var _book: Control
var _paper_layer: ColorRect
var _shadow: ColorRect
var _shadow_material: ShaderMaterial
var _paper_material: ShaderMaterial
var _paper_mask: Texture2D
var _transition: ColorRect
var _toast: Label
var _reader: AnnualReaderView

# 旧别名：外部与既有测试按这些名字取用，语义升级但名字保持不变。
var _art: TextureRect
var _stamp: Control
var _body: VBoxContainer
var _footer: HBoxContainer
var _scroll: ScrollContainer

var _settle_tween: Tween
var _open_tween: Tween
var _toast_tween: Tween
var _sheet_height := -1.0


func _ready() -> void:
	if _book != null:
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = preload("res://assets/themes/player_session_theme.tres")
	_book = $Book
	_paper_layer = $Sheet/Paper
	_shadow = $Sheet/Shadow
	_transition = $Transition
	_toast = $Toast
	if _paper_layer.material is ShaderMaterial:
		_paper_material = _paper_layer.material as ShaderMaterial
	if _shadow.material is ShaderMaterial:
		_shadow_material = _shadow.material as ShaderMaterial
	_load_paper_mask()
	_style_toast()

	_reader = AnnualReaderView.new()
	_reader.name = "Reader"
	_book.add_child(_reader)
	_art = _reader.cover().art() if _reader.cover() != null else null
	_reader.set_paper_mask(_paper_mask)

	_reader.copy_requested.connect(_copy_report)
	_reader.close_requested.connect(_close)
	_reader.history_page_requested.connect(func(offset: int) -> void: history_page_requested.emit(offset))
	_reader.report_selected.connect(func(id: int) -> void: report_selected.emit(id))
	_reader.chapter_entered.connect(_show_chapter)
	get_viewport().size_changed.connect(_update_layout)
	_layout_paper()


func _style_toast() -> void:
	_toast.add_theme_font_override("font", UITokens.annual_font("label"))
	_toast.add_theme_font_size_override("font_size", 13)
	_toast.add_theme_color_override("font_color", UITokens.CHRONICLE_INK)
	_toast.add_theme_color_override("font_outline_color", UITokens.CHRONICLE_SHEET_LIGHT)
	_toast.add_theme_constant_override("outline_size", 8)


# ── 纸 ──────────────────────────────────────────────────────────────────────

## 撕口蒙版：纸、投影、页眉页脚遮罩共用同一张，撕口轮廓只有一个权威来源。
## 加载失败时不抛错 —— has_mask 保持 0，两个着色器自动退回程序化撕边。
func _load_paper_mask() -> void:
	if not ResourceLoader.exists(PAPER_MASK_PATH):
		push_warning("annual report: torn-edge mask missing, falling back to the procedural tear")
		_paper_mask = null
	else:
		_paper_mask = load(PAPER_MASK_PATH) as Texture2D
	_bind_mask()


func _bind_mask() -> void:
	var has_mask: float = 1.0 if _paper_mask != null else 0.0
	# 蒙版在位时 seed 只影响纸面的纤维噪声（撕口轮廓全在 PNG 里）；蒙版缺席时
	# 纸场与投影会退回程序化撕边，那时两者必须同源 —— 否则影子会和纸错开一道缝。
	var raw_seed: Variant = _paper_material.get_shader_parameter("seed") if _paper_material != null else null
	var tear_seed: float = float(raw_seed) if raw_seed != null else 0.0
	for material: ShaderMaterial in [_paper_material, _shadow_material]:
		if material == null:
			continue
		material.set_shader_parameter("paper_mask_tex", _paper_mask)
		material.set_shader_parameter("has_mask", has_mask)
		material.set_shader_parameter("seed", tear_seed)


## 纸是这份报告的第一性事实：水平居中、上下各留一段桌面、四边撕口、四边出影。
##
## 四个矩形的关系见 AnnualReportTokens：
##   paper_column  纸的竖列（只有 x / 宽有意义）
##   sheet_rect    可见纸面，高度随正文增长（正文是一章一章长出来的）
##   layer_rect    纸层，左右各扩 tear_pad、上下各扩 cap_pad（撕口余量）
##   shadow_rect   投影层，纸层再各扩 shadow_spread（投影衰减带）
##
## 关键的一点：纸层**不是**铺满视口的背景板，它是会动的那一件实物。
## 这里只算与滚动无关的量（宽度、撕口预算、着色器常量），位移交给 _move_sheet()，
## 每帧按当前滚动重设 —— 卷首看得见纸的上沿，卷末看得见纸的下沿。
func _layout_paper() -> void:
	if _paper_layer == null:
		return
	var viewport: Vector2 = get_viewport_rect().size
	_sheet_height = _reader.sheet_height() if _reader != null else 0.0
	# 正文还没排版时（present 刚进来、size 仍是 0）先按一屏算，
	# 免得第一帧闪出一张只有几十像素高的纸片；下一帧就会被真实高度替换。
	if _sheet_height <= 2.0:
		_sheet_height = viewport.y
	var layer: Rect2 = AnnualReportTokens.layer_rect(viewport, _sheet_height)
	var shadow: Rect2 = AnnualReportTokens.shadow_rect(viewport, _sheet_height)
	var tear: float = AnnualReportTokens.tear_pad(viewport)
	var cap: float = AnnualReportTokens.cap_pad(viewport)
	var cap_depth: float = AnnualReportTokens.cap_depth(viewport)
	var spread: float = AnnualReportTokens.shadow_spread(viewport)
	var mask: Rect2 = AnnualReportTokens.mask_rect(viewport)
	var mapping: Vector4 = AnnualReportTokens.mask_mapping(layer, mask)
	# 投影矩形的左右边缘与蒙版列完全重合，所以它自己的映射就是"整幅"。
	var shadow_mapping: Vector4 = AnnualReportTokens.mask_mapping(shadow, mask)
	# 蒙版的纵向几何。行数直接问纹理，两个切段常数来自构建脚本（见令牌里的
	# MASK_CAP_ROWS / MASK_EDGE_ROWS），着色器靠它们把纸层行号切成头/中/尾。
	var mask_rows: float = _paper_mask.get_size().y if _paper_mask != null else 1080.0

	_paper_layer.position.x = layer.position.x
	_paper_layer.size = layer.size
	_shadow.position.x = shadow.position.x
	_shadow.size = shadow.size

	if _paper_material != null:
		_paper_material.set_shader_parameter("rect_px", layer.size)
		_paper_material.set_shader_parameter("tear_pad", tear)
		# 咬进去的深度必须小于留白，否则撕口会撞到纸层矩形被硬切。
		_paper_material.set_shader_parameter("tear_depth", tear * 0.72)
		_paper_material.set_shader_parameter("cap_pad_px", cap)
		_paper_material.set_shader_parameter("cap_depth_px", cap_depth)
		_paper_material.set_shader_parameter("mask_tex_px", mask_rows)
		_paper_material.set_shader_parameter("mask_cap_rows", AnnualReportTokens.MASK_CAP_ROWS)
		_paper_material.set_shader_parameter("mask_edge_rows", AnnualReportTokens.MASK_EDGE_ROWS)
		_paper_material.set_shader_parameter("mask_uv_rect", mapping)

	if _shadow_material != null:
		_shadow_material.set_shader_parameter("inset", spread / maxf(1.0, shadow.size.x))
		_shadow_material.set_shader_parameter("spread_px", spread)
		_shadow_material.set_shader_parameter("layer_size", layer.size)
		_shadow_material.set_shader_parameter("cap_pad_px", cap)
		_shadow_material.set_shader_parameter("mask_far_px", AnnualReportTokens.MASK_FAR_PX)
		_shadow_material.set_shader_parameter("mask_tex_px", mask_rows)
		_shadow_material.set_shader_parameter("mask_cap_rows", AnnualReportTokens.MASK_CAP_ROWS)
		_shadow_material.set_shader_parameter("mask_edge_rows", AnnualReportTokens.MASK_EDGE_ROWS)
		_shadow_material.set_shader_parameter("mask_uv_rect", shadow_mapping)

	if _reader != null:
		_reader.set_paper_mask_mapping(AnnualReportTokens.paper_column(viewport))
	_move_sheet()


## 位移：纸的上沿 = 卷首留白 - 滚动位移。这就是"纸在动"的全部实现。
## 投影跟着纸走，纸头和纸尾才看得出是同一件东西在桌面上移动。
func _move_sheet() -> void:
	if _paper_layer == null or _reader == null:
		return
	var viewport: Vector2 = get_viewport_rect().size
	var top: float = _reader.sheet_top() - AnnualReportTokens.cap_pad(viewport)
	_paper_layer.position.y = top
	_shadow.position.y = top - AnnualReportTokens.shadow_spread(viewport)


## 每帧校准。高度只在正文变长时变（着色器常量跟着它），位移每帧都要跟 ——
## 滚轮、触摸板、手柄、跳章 tween 全都直接改 scroll_vertical，没有统一信号。
func _sync_sheet() -> void:
	if _reader == null or _paper_layer == null:
		return
	var height: float = _reader.sheet_height()
	if absf(height - _sheet_height) > 0.5:
		_layout_paper()
		return
	var viewport: Vector2 = get_viewport_rect().size
	var top: float = _reader.sheet_top() - AnnualReportTokens.cap_pad(viewport)
	if absf(top - _paper_layer.position.y) < 0.01:
		return
	_move_sheet()


# ── 对外 API（名字与语义都对旧调用方保持兼容） ──────────────────────────────

func present(model: Dictionary, ceremonial: bool = true) -> void:
	if _book == null:
		_ready()
	finish_opening()
	var data: Dictionary = model
	if data.get("chapters", []).is_empty():
		data = data.duplicate(true)
		data["chapters"] = [_empty_chapter()]
	_model = data
	_layout_paper()
	_reader.present(_model)
	_art = _reader.cover().art() if _reader.cover() != null else null
	_stamp = _reader.cover().stamp() if _reader.cover() != null else null
	_body = _reader.body()
	_footer = _reader.footer()
	_scroll = _reader.scroll()
	_toast.visible = false
	_transition.visible = false
	visible = true
	move_to_front()
	_update_layout()
	_settle_paper()

	if not bool(_model.get("available", false)):
		if _reader.cover() != null:
			_reader.cover().finish_opening()
		_reader.scroll_to_chapter(0, false)
		return
	if ceremonial and not UIAnimation.reduced_motion():
		_reader.cover().play_opening()
	else:
		_reader.cover().finish_opening()
		_reader.cover().modulate.a = 0.0
		if _open_tween != null and _open_tween.is_valid():
			_open_tween.kill()
		_open_tween = create_tween()
		_open_tween.tween_property(_reader.cover(), "modulate:a", 1.0, 0.18)
	var history: OptionButton = _reader.history_control()
	if history != null and not history.disabled:
		history.grab_focus()


func set_history(rows: Array, offset: int, has_more: bool) -> void:
	if _reader == null:
		_ready()
	_reader.set_history(rows, offset, has_more)


## 让"跳章之后立刻可查"成立：一次性补齐全部章节。
func flush_build() -> void:
	if _reader != null:
		_reader.flush_build()


func finish_opening() -> void:
	if _settle_tween != null and _settle_tween.is_valid():
		_settle_tween.kill()
	_settle_tween = null
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	_open_tween = null
	if _paper_material != null:
		_paper_material.set_shader_parameter("settle", 1.0)
	if _reader != null and _reader.cover() != null:
		_reader.cover().finish_opening()


func _copy_report() -> void:
	DisplayServer.clipboard_set(String(_model.get("full_text", "")))
	_toast.text = "完整报告已复制"
	_toast.visible = true
	_toast.modulate.a = 1.0
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.5)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.4).set_trans(Tween.TRANS_SINE)
	_toast_tween.tween_callback(func() -> void: _toast.visible = false)


func _close() -> void:
	finish_opening()
	visible = false
	closed.emit(int(_model.get("id", 0)))


# ── 导航 ────────────────────────────────────────────────────────────────────

## 旧语义：0 回封面，i > 0 打开第 i 章。现在两者都是"滚到那张纸的某个位置"。
func _show_page(index: int, animate: bool = true) -> void:
	finish_opening()
	if index <= 0:
		_show_cover(animate)
		return
	_show_chapter(index, animate)


func _show_chapter(index: int, animate: bool = true) -> void:
	if _reader == null:
		_ready()
	_reader.scroll_to_chapter(index, animate)


func _show_cover(animate: bool = true) -> void:
	if _reader != null:
		_reader.scroll_to_cover(animate)


func _on_begin() -> void:
	_show_chapter(0, true)


func _step_chapter(delta: int) -> void:
	if _reader == null:
		return
	var current: int = _reader.current_chapter()
	if current < 0:
		if delta > 0:
			_show_chapter(0, true)
		return
	var total: int = _reader.total_chapters()
	if total <= 0:
		return
	if delta < 0 and current <= 0:
		_show_cover(true)
		return
	_show_chapter(clampi(current + delta, 0, total - 1), true)


func _update_layout() -> void:
	if _book == null:
		return
	_compact = get_viewport_rect().size.x < 1100.0
	_layout_paper()
	if _reader != null and not _model.is_empty():
		var chapter: int = _reader.current_chapter()
		_reader.present(_model)
		_art = _reader.cover().art() if _reader.cover() != null else null
		_stamp = _reader.cover().stamp() if _reader.cover() != null else null
		_body = _reader.body()
		_footer = _reader.footer()
		_scroll = _reader.scroll()
		if chapter >= 0:
			_reader.scroll_to_chapter(chapter, false)
		else:
			_reader.scroll_to_cover(false)


# ── 纸场 ────────────────────────────────────────────────────────────────────

func _settle_paper() -> void:
	if _paper_material == null:
		return
	if _settle_tween != null and _settle_tween.is_valid():
		_settle_tween.kill()
	if UIAnimation.reduced_motion():
		_paper_material.set_shader_parameter("settle", 1.0)
		return
	_paper_material.set_shader_parameter("settle", 0.0)
	_settle_tween = create_tween()
	_settle_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_settle_tween.tween_method(func(value: float) -> void: _paper_material.set_shader_parameter("settle", value),
		0.0, 1.0, SETTLE_SECONDS)


func _empty_chapter() -> Dictionary:
	return {
		"title": "国家年度发展报告", "number": 1,
		"lead": "尚无数据",
		"rows": [], "details": [], "figures": [], "visuals": [], "margin_notes": [],
		"has_previous": false,
	}


# ── 输入 ────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel") or event.is_action_pressed(&"player_cancel"):
		_close()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
			_step_chapter(-1 if event.button_index == JOY_BUTTON_LEFT_SHOULDER else 1)
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_PAGEUP, KEY_PAGEDOWN]:
			_step_chapter(-1 if event.keycode == KEY_PAGEUP else 1)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_C and event.ctrl_pressed and event.shift_pressed:
			_copy_report()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible or _reader == null:
		return
	_sync_sheet()
	for device in Input.get_connected_joypads():
		var axis := Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y)
		if absf(axis) > 0.2:
			_reader.scroll_by(axis * 700.0 * delta)


# ── 只读取用（QA / 测试） ──────────────────────────────────────────────────

func reader() -> AnnualReaderView:
	return _reader


func cover() -> AnnualCoverView:
	return _reader.cover() if _reader != null else null


func current_page() -> int:
	return _reader.current_chapter() if _reader != null else -1


func paper_material() -> ShaderMaterial:
	return _paper_material
