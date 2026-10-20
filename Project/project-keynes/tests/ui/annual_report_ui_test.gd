extends SceneTree

const Model = preload("res://scripts/ui/annual_report_view_model.gd")
const Fixture = preload("res://tests/ui/annual_report_test.gd")
const Flow = preload("res://scripts/annual/annual_report_flow.gd")
var failures := 0

class ClockStub:
	var paused := false
	var speed_multiplier := 50.0
	func pause(value: bool) -> void: paused = value
	func set_speed(value: float) -> void: speed_multiplier = value

class ControllerStub:
	var locked := false
	func era_reward_locked() -> bool: return locked
	func family_founding_locked() -> bool: return false
	func ideology_draw_phase() -> String: return ""
	func sync_ui() -> void: pass

class HostStub:
	signal annual_report_ready(id: int)
	var ready := true
	var marked := 0
	var marked_ids: Array[int] = []
	func annual_report_status() -> Dictionary: return {"ok": ready}
	func annual_report_snapshot(_id: int) -> Dictionary: return Fixture.fixture()
	func annual_report_history(_offset: int, _limit: int) -> Dictionary: return {"reports": [{"id": 1, "year": 0, "grade": "S"}]}
	func annual_report_catalogs() -> Dictionary: return {}
	func mark_annual_report_presented(id: int) -> void:
		marked = id
		marked_ids.append(id)

class UiStub:
	signal annual_history_requested()
	signal annual_report_closed(id: int)
	signal annual_report_selected(id: int)
	signal annual_history_page_requested(offset: int)
	var opened := 0
	func annual_other_modal_open() -> bool: return false
	func show_annual_report(_model: Dictionary, _ceremonial: bool) -> void: opened += 1
	func set_annual_history(_rows: Array, _offset: int, _has_more: bool) -> void: pass

func _init() -> void:
	call_deferred("_run")

func _expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed: failures += 1

func _run() -> void:
	root.size = Vector2i(1280,720)
	root.content_scale_factor = 1.0
	var top = load("res://scenes/ui/player_top_bar.tscn").instantiate()
	root.add_child(top)
	var clicked := [0]
	top.annual_history_requested.connect(func() -> void: clicked[0] += 1)
	var date = top.get_node("Margin/Row/DateBlock")
	_expect("date is an accessible button", date is Button and date.focus_mode == Control.FOCUS_ALL)
	top.update_time_state(999,12,31,false,50)
	date.pressed.emit()
	_expect("date opens chronicle intent once", clicked[0] == 1)
	_expect("date tooltip explains annual history", date.tooltip_text.contains("年度纪事"))
	var bar = load("res://scenes/ui/country_action_bar.tscn").instantiate()
	root.add_child(bar)
	_expect("bottom affairs has five original entries", bar.get("_buttons").size() == 5 and not bar.get("_buttons").has("annual"))
	var workspace = load("res://scenes/ui/annual_report_workspace.tscn").instantiate()
	root.add_child(workspace)
	workspace.present(Model.build(Fixture.fixture()), true)
	workspace.finish_opening()
	await process_frame
	await process_frame
	# 封面是"那张纸"的第一屏：宽度等于纸宽（≈视口 46%），高度等于纸的可见高度
	# （整屏减去卷首那段桌面），版心与正文同一列。
	var cover = workspace.cover()
	var art: TextureRect = workspace.get("_art")
	var viewport: Vector2 = root.get_visible_rect().size
	var column: Rect2 = AnnualReportTokens.paper_column(viewport)
	var head_gap: float = AnnualReportTokens.sheet_head_gap(viewport)
	var cap: float = AnnualReportTokens.cap_pad(viewport)
	_expect("cover art carries a real alpha cutout", art.texture.get_image().detect_alpha() != Image.ALPHA_NONE)
	_expect("cover sits inside the sheet",
		absf(cover.size.x - column.size.x) <= 1.0
		and absf(cover.position.y - head_gap) <= 1.0
		and absf(cover.size.y - (viewport.y - head_gap)) <= 1.0)
	# 纸层四边各留一圈撕口余量：余量里 alpha 归零，桌面从缺口透出来。
	var paper_layer: ColorRect = workspace.get("_paper_layer")
	var tear: float = column.position.x - paper_layer.position.x
	_expect("paper keeps a torn margin on every edge",
		tear >= 12.0 and tear <= 34.0
		and absf(paper_layer.size.x - (column.size.x + tear * 2.0)) <= 1.0
		and absf(paper_layer.position.x + paper_layer.size.x - column.end.x - tear) <= 1.0
		and absf(paper_layer.position.y - (head_gap - cap)) <= 1.0)
	# 卷首：纸的上沿在画面里，上面露出一段桌面。旧版把纸上下出血出屏，
	# 玩家永远看不到"这张纸从哪里开始" —— 这一条就是那道伤疤的哨兵。
	_expect("sheet top edge is on screen at the head",
		head_gap > AnnualReportTokens.RUNNING_HEAD_HEIGHT
		and paper_layer.position.y >= -1.0
		and AnnualReportTokens.sheet_head_gap(viewport) < viewport.y * 0.16)
	# 撕口轮廓来自蒙版位图：纸、投影、页眉、页脚共用同一张，轮廓只有一个权威来源。
	# mask_uv_rect 是纸层在蒙版里的子矩形 —— 这两个比例与分辨率无关（只要钳位没咬住），
	# 所以可以直接断言，不必跟着视口换算。
	var paper_material: ShaderMaterial = workspace.paper_material()
	var mask_tex: Texture2D = paper_material.get_shader_parameter("paper_mask_tex")
	var mask_uv: Vector4 = paper_material.get_shader_parameter("mask_uv_rect")
	var shadow_material: ShaderMaterial = workspace.get("_shadow_material")
	_expect("paper and shadow share the torn-edge mask",
		mask_tex != null
		and float(paper_material.get_shader_parameter("has_mask")) > 0.5
		and float(shadow_material.get_shader_parameter("has_mask")) > 0.5
		and shadow_material.get_shader_parameter("paper_mask_tex") != null
		and mask_uv.z > 0.85 and mask_uv.z < 0.96
		and mask_uv.x > 0.02 and mask_uv.x < 0.10)
	# 像素级哨兵。A 是轮廓、G 是纸外侧的距离场：纹理最左列在纸外，必须 G 饱和、A 归零。
	# 这条专门抓 process/fix_alpha_border = true —— 它会把不透明邻居的颜色涂满透明像素，
	# 距离场被填平后投影在外面直接塌成硬边，而所有几何断言依然全绿。
	var mask_image: Image = mask_tex.get_image()
	var mask_mid: int = mask_image.get_height() / 2
	var outside: Color = mask_image.get_pixel(0, mask_mid)
	var inside: Color = mask_image.get_pixel(mask_image.get_width() / 2, mask_mid)
	_expect("tear mask keeps its distance field",
		outside.a < 0.02 and outside.g > 0.9 and inside.a > 0.98)
	# 沿 y 采样 96 行求左缘：既不能贴到纹理边（蒙版没地方衰减投影），
	# 也不能是一条直边（那就退回"机器裁的"了），更不能超过咬入预算。
	# 只采中段：蒙版上下两端是纸头纸尾的真实撕口，那几张行在左缘之外还有
	# 纸外的空白行，混进来量的就不是"侧边撕口有多毛"了。
	var cap_rows: int = int(AnnualReportTokens.MASK_CAP_ROWS)
	var band_from: int = cap_rows
	var band_to: int = mask_image.get_height() - cap_rows - 1
	var left_edges: Array[float] = []
	for sample in 96:
		var y: int = int(round(float(band_from)
				+ float(sample) * float(band_to - band_from) / 95.0))
		for x in mask_image.get_width():
			if mask_image.get_pixel(x, y).a > 0.5:
				left_edges.append(float(x))
				break
	left_edges.sort()
	var reach: float = left_edges[left_edges.size() - 1] - left_edges[0]
	_expect("tear mask edge wanders instead of cutting straight",
		left_edges.size() == 96 and left_edges[0] > 8.0 and reach >= 3.0 and reach <= 34.0)
	# 纸头纸尾的撕口。这四条就是"四条边全走位图"的哨兵 —— 曾经构建脚本把源图上下
	# 当圆角裁掉（VERTICAL_BAND = 0.62），纸变成实物之后那两条边直接以机切直边的
	# 样子出现在读者眼前。中段 40% 的列反推：纸面名义上沿（中位数）必须落在
	# MASK_EDGE_ROWS 行，最深咬口必须整个留在 1:1 段（MASK_CAP_ROWS）以内，
	# 而且必须真的在咬（游走 >= 3px），不能是一条直线。
	var mid_from: int = int(mask_image.get_width() * 0.3)
	var mid_to: int = int(mask_image.get_width() * 0.7)
	var top_rows: Array[float] = []
	var bottom_rows: Array[float] = []
	for x in range(mid_from, mid_to):
		for y in mask_image.get_height():
			if mask_image.get_pixel(x, y).a > 0.5:
				top_rows.append(float(y))
				break
		for y in range(mask_image.get_height() - 1, -1, -1):
			if mask_image.get_pixel(x, y).a > 0.5:
				bottom_rows.append(float(y))
				break
	top_rows.sort()
	bottom_rows.sort()
	var columns: int = mid_to - mid_from
	var top_edge: float = top_rows[top_rows.size() / 2]
	var bottom_edge: float = bottom_rows[bottom_rows.size() / 2]
	_expect("mask geometry contract matches the build script",
		top_rows.size() == columns and bottom_rows.size() == columns
		and absf(top_edge - AnnualReportTokens.MASK_EDGE_ROWS) <= 4.0
		and absf(bottom_edge - float(mask_image.get_height() - 1)
				+ AnnualReportTokens.MASK_EDGE_ROWS) <= 4.0)
	_expect("sheet head and tail are torn, not guillotined",
		top_rows[top_rows.size() - 1] - top_rows[0] >= 3.0
		and top_rows[top_rows.size() - 1] < AnnualReportTokens.MASK_CAP_ROWS
		and bottom_rows[0] > float(mask_image.get_height()) - AnnualReportTokens.MASK_CAP_ROWS
		and bottom_rows[bottom_rows.size() - 1] - bottom_rows[0] >= 3.0)
	# 硬规则：同一屏必须同时存在 ≥80px 与 ≤13px，比值至少 6 倍。
	# 只统计真正可见的标签 —— 封面为放不下的元素预留了节点，隐藏的那些不算数。
	var label_sizes: Array[int] = []
	for node in cover.find_children("*", "Label", true, false):
		if node.is_visible_in_tree():
			label_sizes.append(node.get_theme_font_size("font_size"))
	label_sizes.sort()
	_expect("cover keeps display-scale contrast",
		label_sizes.size() > 3 and label_sizes[label_sizes.size() - 1] >= 80
		and float(label_sizes[label_sizes.size() - 1]) / maxf(1.0, float(label_sizes[0])) >= 6.0)
	_expect("footer stays compact", workspace.get("_footer").size.y <= 48)
	workspace.call("_show_page", 6, false)
	await process_frame
	await process_frame
	await process_frame
	await create_timer(0.25).timeout
	var reader = workspace.reader()
	var sections: Array = reader.sections()
	var jump_delta: float = absf(sections[6].position.y - AnnualReportTokens.RUNNING_HEAD_HEIGHT - float(workspace.get("_scroll").scroll_vertical))
	_expect("chapter six is scrolled into place",
		reader.current_chapter() == 6 and jump_delta <= 12.0
		and workspace.get("_body").get_child_count() == 20
		and workspace.get("_paper_layer").visible)
	# 纸是实物：它跟着滚动位移一起走，不是钉在视口上的背景板。
	# 位移量必须与 scroll_vertical 一分不差，否则纸会"滑"在正文下面。
	var rode: float = head_gap - cap - paper_layer.position.y
	_expect("paper rides the scroll offset",
		rode > 200.0 and absf(rode - float(workspace.get("_scroll").scroll_vertical)) <= 1.0)
	var paragraphs = workspace.get("_body").find_children("*", "RichTextLabel", true, false)
	_expect("body supports native text selection", paragraphs.size() > 0 and paragraphs[0].selection_enabled)
	workspace.call("_show_page", 0, false)
	await process_frame
	await process_frame
	await create_timer(0.25).timeout
	_expect("page zero scrolls back to the cover",
		workspace.get("_scroll").scroll_vertical == 0 and reader.current_chapter() == -1)
	# 卷末：滚到底时纸的下沿必须落在画面里，下面露出一段桌面 ——
	# 读者才知道这份报告读完了，而不是"文字到此为止了"。
	var scroll: ScrollContainer = workspace.get("_scroll")
	var foot_gap: float = AnnualReportTokens.sheet_foot_gap(viewport)
	scroll.scroll_vertical = int(maxf(0.0, reader.body().size.y - scroll.size.y))
	await process_frame
	await process_frame
	_expect("sheet bottom edge is on screen at the tail",
		foot_gap > AnnualReportTokens.FOOTER_HEIGHT
		and absf(reader.sheet_bottom() - (viewport.y - foot_gap)) <= 1.5
		and paper_layer.position.y + paper_layer.size.y <= viewport.y + 1.0)
	var clock := ClockStub.new()
	var host := HostStub.new()
	var controller := ControllerStub.new()
	var ui := UiStub.new()
	var flow = Flow.new()
	flow.configure(controller,host,clock,ui)
	controller.locked = true
	flow.queue_report(1)
	_expect("annual waits for blocking choices", ui.opened == 0 and not clock.paused)
	controller.locked = false
	flow.try_present()
	_expect("annual pauses after the other modal ends", ui.opened == 1 and clock.paused)
	var state: Dictionary = flow.capture()
	ui.annual_report_closed.emit(1)
	_expect("close restores previous 50x state", not clock.paused and clock.speed_multiplier == 50.0 and host.marked == 1)
	host.ready = false
	flow.restore(state)
	flow.try_present()
	_expect("load waits for native report facade", ui.opened == 1)
	host.ready = true
	flow.try_present()
	_expect("load reopens report with original resume intent", ui.opened == 2 and clock.paused)
	ui.annual_report_closed.emit(1)
	_expect("loaded report restores original running state", not clock.paused and clock.speed_multiplier == 50.0)
	var second_host := HostStub.new()
	var second_ui := UiStub.new()
	var second_flow = Flow.new()
	second_flow.configure(ControllerStub.new(), second_host, ClockStub.new(), second_ui)
	second_flow.queue_report(1)
	second_ui.annual_report_selected.emit(2)
	second_flow.queue_report(1)
	second_ui.annual_report_closed.emit(2)
	second_flow.try_present()
	_expect("history navigation acknowledges all viewed years without duplicate popup", second_host.marked_ids == [1, 2] and second_ui.opened == 2 and not second_flow.is_open())
	workspace.queue_free()
	top.queue_free()
	bar.queue_free()
	await process_frame
	print("annual_report_ui_test: %d failures" % failures)
	quit(0 if failures == 0 else 1)
