extends Control
class_name AnnualReaderView

## 长卷。
##
## 一块滚动面，纸的第一屏是封面，往下接十章，**一直滚**。
## 封面与正文不是"两页"，而是同一张纸上先后出现的两段 —— 这正是旧版翻页式
## 版面读起来像 PPT 的原因：每一屏都在"换幻灯片"，而不是"继续读下去"。
##
## 章节按波次构建（首屏立即、其余每帧一章），图表在首次进入视口时才绑定数据。

signal chapter_entered(index: int)
signal copy_requested()
signal close_requested()
signal history_page_requested(offset: int)
signal report_selected(report_id: int)

var _scroll: ScrollContainer
var _body: VBoxContainer
var _cover: AnnualCoverView
var _head: AnnualRunningHead
var _foot_veil: AnnualRunningHead
var _paper_mask: Texture2D
var _rail: AnnualProgressRail
var _footer: HBoxContainer
var _page_label: Label
var _progress_track: ColorRect
var _progress_fill: ColorRect
var _history: OptionButton
var _newer: Button
var _older: Button
var _history_ids: Array[int] = []

var _model: Dictionary = {}
var _sections: Array[AnnualSection] = []
var _layout: Dictionary = {}
var _built := 0
var _seen := {}
var _visit_accum := 0.0
var _pending_chapter := -1
var _pending_animate := false
var _current := -1
var _scroll_tween: Tween


func _ready() -> void:
	if _scroll != null:
		return
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_chrome()


# ── 骨架 ────────────────────────────────────────────────────────────────────

func _build_chrome() -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 滚动条不出现：它会从内容宽度里偷走十几像素，纸的右侧留白就和左侧对不上。
	# 进度由页脚那根 1px 线与桌面上的刻度轨承担。
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_FILL
	_body.add_theme_constant_override("separation", 0)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_body)

	_head = AnnualRunningHead.new()
	_head.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(_head)

	_foot_veil = AnnualRunningHead.new()
	_foot_veil.set_flipped(true)
	_foot_veil.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_foot_veil.offset_top = -AnnualReportTokens.FOOTER_HEIGHT
	_foot_veil.offset_bottom = 0.0
	add_child(_foot_veil)

	_rail = AnnualProgressRail.new()
	_rail.set_on_desk(true)
	_rail.chapter_requested.connect(func(index: int) -> void: chapter_entered.emit(index))
	add_child(_rail)

	_footer = HBoxContainer.new()
	_footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_footer.custom_minimum_size.y = AnnualReportTokens.FOOTER_HEIGHT
	_footer.add_theme_constant_override("separation", 14)
	add_child(_footer)

	_page_label = _label("", 13, UITokens.CHRONICLE_MUTED)
	_page_label.custom_minimum_size.x = 68.0
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_footer.add_child(_page_label)

	_progress_track = ColorRect.new()
	_progress_track.color = Color(UITokens.CHRONICLE_INK.r, UITokens.CHRONICLE_INK.g, UITokens.CHRONICLE_INK.b, 0.12)
	_progress_track.custom_minimum_size = Vector2(120.0, 1.0)
	_progress_track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_footer.add_child(_progress_track)

	_progress_fill = ColorRect.new()
	_progress_fill.color = Color(UITokens.CHRONICLE_RED.r, UITokens.CHRONICLE_RED.g, UITokens.CHRONICLE_RED.b, 0.9)
	_progress_fill.custom_minimum_size = Vector2(0.0, 1.0)
	_progress_fill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_progress_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_track.add_child(_progress_fill)
	_progress_fill.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	_progress_fill.offset_right = 0.0

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer.add_child(spacer)

	_history = OptionButton.new()
	_history.focus_mode = Control.FOCUS_ALL
	_history.custom_minimum_size.x = 92.0
	_history.tooltip_text = "切换历年年度报告"
	_link_style(_history)
	_history.item_selected.connect(_on_history_selected)
	_footer.add_child(_history)
	_newer = _link_button("较新", func() -> void: history_page_requested.emit(maxi(0, int(_history.get_meta("offset", 0)) - 64)))
	_newer.tooltip_text = "载入较新的年度报告"
	_older = _link_button("更早", func() -> void: history_page_requested.emit(int(_history.get_meta("offset", 0)) + 64))
	_older.tooltip_text = "载入更早的年度报告"
	var copy := _link_button("复制全文", func() -> void: copy_requested.emit())
	copy.tooltip_text = "把完整报告复制到剪贴板（Ctrl+Shift+C）"
	var close := _link_button("合卷", func() -> void: close_requested.emit())
	close.tooltip_text = "关闭报告并恢复此前的时间状态"


func _link_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_ALL
	button.custom_minimum_size.y = 26.0
	_link_style(button)
	button.pressed.connect(callback)
	_footer.add_child(button)
	return button


func _label(text: String, size_px: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_override("font", UITokens.annual_font("label"))
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_color_override("font_color", color)
	return label


## 无底文本链：常态透明，hover 转朱红，focus 只加 2px 底边。
func _link_style(button: Button) -> void:
	button.add_theme_font_override("font", UITokens.annual_font("label"))
	button.add_theme_font_size_override("font_size", 13)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, UITokens.chronicle_link_style(state))
	for state in ["font_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		button.add_theme_color_override("font_color", UITokens.CHRONICLE_INK)
	button.add_theme_color_override("font_hover_color", UITokens.CHRONICLE_RED)
	button.add_theme_color_override("font_disabled_color", Color(UITokens.CHRONICLE_MUTED.r, UITokens.CHRONICLE_MUTED.g, UITokens.CHRONICLE_MUTED.b, 0.45))


# ── 构卷 ────────────────────────────────────────────────────────────────────

func present(model: Dictionary) -> void:
	if _scroll == null:
		_ready()
	_model = model
	_built = 0
	_seen.clear()
	_pending_chapter = -1
	_current = -1
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_sections.clear()
	_layout = _compute_layout()
	_apply_paper_rects()

	var chapters: Array = _model.get("chapters", [])
	_cover = AnnualCoverView.new()
	_cover.name = "Cover"
	_cover.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_cover.begin_requested.connect(func() -> void: chapter_entered.emit(0))
	_body.add_child(_cover)
	_cover.present(_model)

	var titles := PackedStringArray()
	for chapter in chapters:
		titles.append(String(chapter.get("title", "")))
	_rail.set_chapters(titles)
	_rail.set_current(-1)
	var year := int(_model.get("year", 1))
	_head.set_texts("第 %d 年 · 国家档案" % year, "")
	_head.set_ink(UITokens.CHRONICLE_MUTED)
	_scroll.scroll_vertical = 0
	_refresh_page_label()
	_progress_fill.offset_right = 0.0
	for i in mini(2, chapters.size()):
		_append_section(i)


func _compute_layout() -> Dictionary:
	var viewport: Vector2 = get_viewport_rect().size
	if viewport.y < 8.0:
		viewport = Vector2(1920.0, 1080.0)
	var paper: Rect2 = AnnualReportTokens.paper_rect(viewport)
	return {
		"viewport": viewport, "paper": paper,
		"pad": AnnualReportTokens.paper_padding(viewport),
		"measure": AnnualReportTokens.measure(viewport),
		"chart": AnnualReportTokens.chart_width(viewport),
		"narrow": AnnualReportTokens.is_narrow(viewport),
		"gap": AnnualReportTokens.chapter_gap(viewport),
		"cover_height": viewport.y,
	}


## 滚动面 = 纸本身（上下出血），正文靠 Section 的内边距落进版心。
func _apply_paper_rects() -> void:
	var viewport: Vector2 = _layout.get("viewport", Vector2(1920.0, 1080.0))
	var paper: Rect2 = _layout.get("paper", AnnualReportTokens.paper_rect(viewport))
	var pad: float = float(_layout.get("pad", 72.0))
	_scroll.offset_left = paper.position.x
	_scroll.offset_right = paper.end.x - viewport.x
	_scroll.offset_top = 0.0
	_scroll.offset_bottom = 0.0
	# 滚动内容定死在纸宽上：ScrollContainer 只按子节点最小宽度摆放，
	# 正文里最宽的那一项（图表/账本）会把整列挤窄，纸右缘就少几像素。
	_body.custom_minimum_size.x = paper.size.x

	_head.offset_left = paper.position.x
	_head.offset_right = paper.end.x - viewport.x
	_head.set_inset(pad)
	_foot_veil.offset_left = paper.position.x
	_foot_veil.offset_right = paper.end.x - viewport.x
	set_paper_mask_mapping(paper,
		AnnualReportTokens.mask_rect(viewport))

	_footer.offset_left = paper.position.x + pad
	_footer.offset_right = paper.end.x - pad - viewport.x
	_footer.offset_top = -AnnualReportTokens.FOOTER_HEIGHT
	_footer.offset_bottom = 0.0

	# 刻度轨浮在长纸右侧的桌面上 —— 它不属于纸，属于你翻纸的手。
	var desk_space: float = viewport.x - paper.end.x
	_rail.visible = desk_space >= 150.0
	_rail.offset_left = paper.end.x + 24.0
	_rail.offset_top = 0.0
	_rail.offset_right = AnnualReportTokens.RAIL_WIDTH
	_rail.offset_bottom = viewport.y


## 撕口蒙版：页眉与页脚遮罩的渐变末端要跟着纸缘收边，否则整纸宽的纸色
## 横带会把撕口缺口填平，桌面就透不出来了。
func set_paper_mask(texture: Texture2D) -> void:
	_paper_mask = texture
	if _head != null:
		_head.set_paper_mask(texture)
	if _foot_veil != null:
		_foot_veil.set_paper_mask(texture)


## 页眉 / 页脚各自在蒙版里的 UV 子矩形。两者都按整纸宽算，只有高度不同。
func set_paper_mask_mapping(paper: Rect2, mask: Rect2) -> void:
	if _head == null or _foot_veil == null:
		return
	var viewport: Vector2 = _layout.get("viewport", Vector2(1920.0, 1080.0))
	var head_height: float = AnnualReportTokens.RUNNING_HEAD_HEIGHT
	var foot_height: float = AnnualReportTokens.FOOTER_HEIGHT
	_head.set_mask(AnnualReportTokens.mask_mapping(
		Rect2(paper.position, Vector2(paper.size.x, head_height)), mask))
	_foot_veil.set_mask(AnnualReportTokens.mask_mapping(
		Rect2(Vector2(paper.position.x, viewport.y - foot_height),
			Vector2(paper.size.x, foot_height)), mask))


func _append_section(index: int) -> void:
	var chapters: Array = _model.get("chapters", [])
	if index >= chapters.size():
		return
	if _built > 0 or _body.get_child_count() > 1:
		var lead := Control.new()
		lead.custom_minimum_size.y = float(_layout.get("gap", AnnualReportTokens.GAP_CHAPTER))
		lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_body.add_child(lead)
	var section := AnnualSection.new()
	section.build(index, chapters[index], _model, _layout)
	_body.add_child(section)
	_sections.append(section)
	_built = _sections.size()


func flush_build() -> void:
	var chapters: Array = _model.get("chapters", [])
	while _built < chapters.size():
		_append_section(_built)


func total_chapters() -> int:
	return _model.get("chapters", []).size()


## 编排层要保留旧的私有别名（_body / _footer / _scroll），这里给只读取用口。
func body() -> VBoxContainer:
	if _body == null:
		_ready()
	return _body


func footer() -> HBoxContainer:
	if _footer == null:
		_ready()
	return _footer


func scroll() -> ScrollContainer:
	if _scroll == null:
		_ready()
	return _scroll


func sections() -> Array[AnnualSection]:
	return _sections


func cover() -> AnnualCoverView:
	return _cover


## 0 = 封面；1..N = 正文第 N 章。-1 表示还在封面那一屏。
func current_chapter() -> int:
	return _current


func progress_ratio() -> float:
	if _scroll == null:
		return 0.0
	var limit: float = maxf(1.0, _body.size.y - _scroll.size.y)
	return clampf(float(_scroll.scroll_vertical) / limit, 0.0, 1.0)


# ── 滚动 ────────────────────────────────────────────────────────────────────

func scroll_to_cover(animate: bool = true) -> void:
	if _scroll == null:
		_ready()
	_pending_chapter = -1
	_pending_animate = animate and not UIAnimation.reduced_motion()
	_tween_scroll(0.0, _pending_animate)


## index < 0 表示回封面；0..N-1 表示正文第 index 章。
func scroll_to_chapter(index: int, animate: bool = true) -> void:
	if _scroll == null:
		_ready()
	if index < 0:
		scroll_to_cover(animate)
		return
	flush_build()
	_pending_chapter = index
	_pending_animate = animate and not UIAnimation.reduced_motion()


func scroll_by(pixels: float) -> void:
	if _scroll != null:
		_scroll.scroll_vertical += int(pixels)


func _tween_scroll(target: float, animate: bool) -> void:
	if _scroll_tween != null and _scroll_tween.is_valid():
		_scroll_tween.kill()
	if not animate:
		_scroll.scroll_vertical = int(target)
		return
	_scroll_tween = create_tween()
	_scroll_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_scroll_tween.tween_method(func(value: float) -> void: _scroll.scroll_vertical = int(value),
		float(_scroll.scroll_vertical), target, AnnualReportTokens.CHAPTER_TURN)


func _apply_pending_chapter() -> void:
	if _pending_chapter < 0:
		return
	# 版面还没排过（size 仍是 0）时跳章会落空，等下一帧再试。
	if _scroll.size.y <= 1.0 or _body.size.y <= 1.0:
		return
	var index: int = clampi(_pending_chapter, 0, maxi(0, _sections.size() - 1))
	if index >= _sections.size():
		return
	_pending_chapter = -1
	var section := _sections[index]
	_tween_scroll(maxf(0.0, section.position.y - 8.0), _pending_animate)
	_update_chapter(section.index, true)


func _update_chapter(index: int, force: bool = false) -> void:
	if index == _current and not force:
		return
	_current = index
	_rail.set_current(index)
	var year := int(_model.get("year", 1))
	var chapters: Array = _model.get("chapters", [])
	var right := ""
	if index >= 0 and index < chapters.size():
		right = "%02d  %s" % [index + 1, String(chapters[index].get("title", ""))]
	_head.set_texts("第 %d 年 · 国家档案" % year, right)
	_refresh_page_label()


func _refresh_page_label() -> void:
	if _page_label == null:
		return
	if _current < 0:
		_page_label.text = "封面 / %02d" % maxi(1, total_chapters())
	else:
		_page_label.text = "%02d / %02d" % [_current + 1, maxi(1, total_chapters())]


# ── 每帧：补建章节、进入视口播放、进度 ──────────────────────────────────────

func _process(delta: float) -> void:
	if _scroll == null or not visible:
		return
	var chapters: Array = _model.get("chapters", [])
	if _built < chapters.size():
		_append_section(_built)
	_apply_pending_chapter()

	_visit_accum += delta
	if _visit_accum < AnnualReportTokens.VISIT_INTERVAL:
		return
	_visit_accum = 0.0

	var top: float = float(_scroll.scroll_vertical)
	var height: float = _scroll.size.y
	for i in _sections.size():
		if _seen.has(i):
			continue
		var section := _sections[i]
		if section.size.y <= 0.0:
			continue
		var y: float = section.position.y
		if y < top + height * 0.88 and y + section.size.y > top + height * 0.12:
			_seen[i] = true
			section.play_in(false)

	if _progress_track != null:
		_progress_fill.offset_right = _progress_track.size.x * progress_ratio()

	# 封面占了第一屏：滚过六成才算进入第一章。
	var cover_height: float = float(_layout.get("cover_height", 0.0))
	var active := -1
	if top > cover_height * 0.6:
		var cursor: float = top + height * 0.30
		for i in _sections.size():
			if _sections[i].position.y <= cursor:
				active = i
	_update_chapter(active)


func _gui_input(event: InputEvent) -> void:
	# 纸外（桌面上）滚轮也要能滚 —— 否则玩家会以为报告卡住了。
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll_by(48.0)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll_by(-48.0)
			accept_event()


# ── 历史 ────────────────────────────────────────────────────────────────────

func set_history(rows: Array, offset: int, has_more: bool) -> void:
	if _history == null:
		_ready()
	_history.clear()
	_history_ids.clear()
	_history.set_meta("offset", offset)
	for row in rows:
		_history_ids.append(int(row.get("id", 0)))
		_history.add_item("第 %d 年 · %s" % [int(row.get("year", 0)) + 1, String(row.get("grade", "—"))])
	if rows.is_empty():
		_history.add_item("尚无年度报告")
	_history.disabled = rows.is_empty()
	_newer.visible = offset > 0
	_newer.disabled = offset <= 0
	_older.visible = has_more
	_older.disabled = not has_more
	var index: int = _history_ids.find(int(_model.get("id", 0)))
	if index >= 0:
		_history.select(index)


func _on_history_selected(index: int) -> void:
	if index >= 0 and index < _history_ids.size():
		report_selected.emit(_history_ids[index])


func history_control() -> OptionButton:
	if _history == null:
		_ready()
	return _history
