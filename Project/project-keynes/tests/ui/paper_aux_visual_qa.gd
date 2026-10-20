extends SceneTree

const THEME := preload("res://assets/themes/player_session_theme.tres")
const NOTES := preload("res://scenes/ui/inspector_note_list.tscn")
const BADGES := preload("res://scenes/ui/badge_row.tscn")
const LEGEND := preload("res://scenes/ui/map_overlay_legend.tscn")
const TOAST := preload("res://scenes/ui/research_toast.tscn")
const OUTPUT := "res://tmp/paper_aux_qa"
const SIZES := [Vector2i(1280, 720), Vector2i(1366, 768),
	Vector2i(1920, 1080), Vector2i(2560, 1080)]
var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.content_scale_factor = 1.0
	_check_theme()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for viewport_size in SIZES:
		root.size = viewport_size
		var viewport := SubViewport.new()
		viewport.size = viewport_size
		viewport.disable_3d = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var preview := _build_preview(viewport)
		await process_frame
		await process_frame
		var badge_row := preview["badges"] as BadgeRow
		for child in badge_row.get_children():
			var badge := child as Label
			_expect(badge.get_rect().end.x <= badge_row.size.x + 1.0,
				"tag fits at %s" % viewport_size)
			_expect(badge.size.y >= 24.0, "tag reserves cut-edge and text height")
		var notes := preview["notes"] as InspectorNoteList
		var paragraphs: Array = notes.get("_paragraphs")
		var text_bottom := UITokens.PAPER_NOTE_PAD_Y
		for paragraph in paragraphs:
			text_bottom += (paragraph as TextParagraph).get_size().y + UITokens.PAPER_NOTE_LINE_GAP
		_expect(text_bottom - UITokens.PAPER_NOTE_LINE_GAP
			<= notes.custom_minimum_size.y - UITokens.PAPER_NOTE_PAD_Y + 1.0,
			"wrapped annotation fits within the paper text inset")
		var row_ids := PackedInt64Array()
		for child in badge_row.get_children():
			row_ids.append(child.get_instance_id())
		badge_row.update_badges(_tags())
		for i in range(row_ids.size()):
			_expect(badge_row.get_child(i).get_instance_id() == row_ids[i],
				"tag refresh preserves label nodes")
		_expect(notes.get_child_count() == 0, "annotation material adds no child nodes")
		if DisplayServer.get_name() != "headless":
			await create_timer(0.4).timeout
			await RenderingServer.frame_post_draw
			var shot := viewport.get_texture().get_image()
			var path := "%s/mixed_%dx%d.png" % [OUTPUT, viewport_size.x, viewport_size.y]
			_expect(shot != null and shot.save_png(path) == OK, "capture mixed paper styles")
		viewport.queue_free()
		await process_frame
	for failure in _failures:
		push_error(failure)
	print("[paper-aux-qa] %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _check_theme() -> void:
	for variation in ["PKPaperTag", "PKPaperNote", "PKPaperPopup",
			"PKPaperAnnotation", "PKPaperToast"]:
		_expect(not THEME.get_type_variation_base(variation).is_empty(), variation)
	for type in ["TooltipPanel", "PopupMenu", "PKPaperPopup"]:
		var paper := THEME.get_stylebox("panel", type) as StyleBoxTexture
		_expect(paper != null and paper.expand_margin_bottom > 0.0,
			"%s uses a projected paper cutout" % type)
	var tag := THEME.get_stylebox("normal", "PKPaperTag") as StyleBoxTexture
	_expect(tag != null and tag.texture.get_width() <= 128.0,
		"labels use a compact source texture")
	_expect(THEME.get_stylebox("panel", "PKArchivePanel") !=
		THEME.get_stylebox("panel", "PKPaperNote"), "primary and auxiliary surfaces coexist")


func _build_preview(viewport: SubViewport) -> Dictionary:
	var background := ColorRect.new()
	background.color = Color(0.095, 0.125, 0.165)
	background.size = Vector2(viewport.size)
	viewport.add_child(background)
	var frame := PanelContainer.new()
	frame.theme = THEME
	frame.theme_type_variation = &"PKArchivePanel"
	frame.position = Vector2(32.0, 32.0)
	frame.size = Vector2(viewport.size) - Vector2(64.0, 64.0)
	viewport.add_child(frame)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	frame.add_child(body)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	body.add_child(header)
	var title := _label("档案与纸片", &"PKArchiveTitle")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 30)
	header.add_child(title)
	var stamp := _label("地图阅读 · 辅助信息", &"PKPaperTag")
	stamp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(stamp)
	body.add_child(_label("黄铜框承载主档案，纸片承载标签、批注与临时提示。", &"PKMutedLabel"))
	var badges := BADGES.instantiate() as BadgeRow
	body.add_child(badges)
	badges.set_badges(_tags())
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 28)
	body.add_child(columns)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.35
	left.add_theme_constant_override("separation", 16)
	columns.add_child(left)
	left.add_child(_label("卷宗批注", &"PKSectionTitle"))
	var notes := NOTES.instantiate() as InspectorNoteList
	left.add_child(notes)
	notes.set_notes([
		{"text": "雨季河流上涨：低地耕作宜关注季节性洪水。", "accent": UITokens.WARN},
		{"text": "沿河土壤有利于粮食生产，可结合本地人口与运输条件评估定居。", "accent": UITokens.GOOD},
	])
	var annotation := _label("注释：这里是贴在档案内页上的短便笺，撕边与柔影提供轻微的纸层厚度。", &"PKPaperAnnotation")
	annotation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(annotation)
	left.add_child(_label("小窗与图例", &"PKSectionTitle"))
	var legend := LEGEND.instantiate() as OverlayLegend
	left.add_child(legend)
	legend.update_for_mode(OverlayMode.MODE.ELEVATION, "海拔图例", "纸片小窗 · 海岸至高地")
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 16)
	columns.add_child(right)
	right.add_child(_label("悬浮提示与弹出", &"PKSectionTitle"))
	var popup := PanelContainer.new()
	popup.theme_type_variation = &"PKPaperPopup"
	right.add_child(popup)
	var popup_body := VBoxContainer.new()
	popup_body.add_theme_constant_override("separation", 12)
	popup.add_child(popup_body)
	popup_body.add_child(_label("查看这片土地", &"PKTitle"))
	var text := _label("纸张中心保持清晰，纤维边、浅切角和接触阴影只出现在外缘。", &"PKMutedLabel")
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	popup_body.add_child(text)
	for caption in ["地理与地表", "资源与储量"]:
		var button := Button.new()
		button.text = caption
		button.theme_type_variation = &"PKHUDButton"
		button.custom_minimum_size.y = 36.0
		popup_body.add_child(button)
	var quiet := _label("边角点缀 · 临时记录", &"PKPaperTag")
	quiet.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	right.add_child(quiet)
	body.add_child(_label("研究完成提示", &"PKSectionTitle"))
	var toast := TOAST.instantiate() as ResearchToast
	toast.custom_minimum_size.y = 64
	body.add_child(toast)
	toast.show_research_completed("陶器制作")
	return {"badges": badges, "notes": notes}


func _tags() -> Array:
	return [
		{"text": "已探索", "accent": UITokens.DOSSIER_INK},
		{"text": "适宜定居", "accent": UITokens.GOOD},
		{"text": "季节性洪水", "accent": UITokens.WARN},
		{"text": "很长的地理分类标签会截断并保持在纸签范围内", "accent": UITokens.DOSSIER_INK},
	]


func _label(text: String, variation: StringName) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	return label


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
