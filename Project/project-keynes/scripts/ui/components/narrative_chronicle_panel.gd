class_name NarrativeChroniclePanel
extends Control

## Hand-drawn / papercut / torn-paper archival Chronicle Folio & AI Configuration Panel.
## Uses torn_note_v1, cut_tag_v1, chronicle_chapter_emblems, and Muyao/Swei typography.

signal closed()
signal locate_cell_requested(cell_idx: int)
signal ai_settings_saved(settings_dict: Dictionary)

const UITokensScript = preload("res://scripts/ui/ui_tokens.gd")
const UIAnimationScript = preload("res://scripts/ui/ui_animation.gd")
const NarrativeAiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")

const PlayerSessionTheme: Theme = preload("res://assets/themes/player_session_theme.tres")
const EraNoteStyle: StyleBoxTexture = preload("res://assets/ui/era/era_note_style.tres")
const TornNoteTexture: Texture2D = preload("res://assets/ui/paper_aux_v1/torn_note_v1.tres")
const CutTagTexture: Texture2D = preload("res://assets/ui/paper_aux_v1/cut_tag_v1.tres")
const SealBadgeTexture: Texture2D = preload("res://assets/ui/annual_chronicle/chronicle_pencil_badge.png")
const ChapterEmblemsTexture: Texture2D = preload("res://assets/ui/annual_chronicle/chronicle_chapter_emblems.png")
const DeskVignetteShader: Shader = preload("res://shaders/ui/annual_grain_vignette.gdshader")

var _records: Array = []
var _showing_ai_config: bool = false

var _backdrop: ColorRect
var _sheet_wrap: Control
var _underlay_shadow: NinePatchRect
var _underlay_page: NinePatchRect
var _card: PanelContainer
var _title_label: Label
var _list_scroll: ScrollContainer
var _list_vbox: VBoxContainer
var _ai_config_panel: PanelContainer
var _ai_toggle_button: Button
var _ai_enabled_check: CheckButton
var _llm_url_edit: LineEdit
var _llm_model_edit: LineEdit
var _llm_key_edit: LineEdit
var _img_enabled_check: CheckButton
var _img_url_edit: LineEdit
var _img_model_edit: LineEdit
var _img_key_edit: LineEdit
var _save_status_label: Label
var _open_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = PlayerSessionTheme
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_ui()
	resized.connect(_layout_sheet)


func _build_ui() -> void:
	if _card != null:
		return

	_backdrop = ColorRect.new()
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.color = Color(0.08, 0.065, 0.05, 0.72)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	var desk_mat := ShaderMaterial.new()
	desk_mat.shader = DeskVignetteShader
	desk_mat.set_shader_parameter("grain", 0.04)
	desk_mat.set_shader_parameter("vignette", 0.32)
	desk_mat.set_shader_parameter("shade_color", Color(0.03, 0.022, 0.016, 0.82))
	_backdrop.material = desk_mat
	add_child(_backdrop)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(center)

	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(740.0, 520.0)
	var sheet_style := EraNoteStyle.duplicate() as StyleBoxTexture
	sheet_style.content_margin_left = 30.0
	sheet_style.content_margin_right = 30.0
	sheet_style.content_margin_top = 20.0
	sheet_style.content_margin_bottom = 22.0
	_card.add_theme_stylebox_override("panel", sheet_style)
	center.add_child(_card)
	_sheet_wrap = _card

	var underlay := Control.new()
	underlay.name = "Underlay"
	underlay.show_behind_parent = true
	underlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(underlay)

	_underlay_shadow = NinePatchRect.new()
	_underlay_shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_underlay_shadow.offset_left = 6.0
	_underlay_shadow.offset_top = 10.0
	_underlay_shadow.offset_right = 8.0
	_underlay_shadow.offset_bottom = 12.0
	_underlay_shadow.texture = TornNoteTexture
	_underlay_shadow.patch_margin_left = 32
	_underlay_shadow.patch_margin_top = 32
	_underlay_shadow.patch_margin_right = 32
	_underlay_shadow.patch_margin_bottom = 32
	_underlay_shadow.self_modulate = Color(0.05, 0.03, 0.015, 0.44)
	_underlay_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	underlay.add_child(_underlay_shadow)

	_underlay_page = NinePatchRect.new()
	_underlay_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_underlay_page.offset_left = -3.0
	_underlay_page.offset_top = 3.0
	_underlay_page.offset_right = 4.0
	_underlay_page.offset_bottom = 5.0
	_underlay_page.rotation = deg_to_rad(0.75)
	_underlay_page.texture = TornNoteTexture
	_underlay_page.patch_margin_left = 32
	_underlay_page.patch_margin_top = 32
	_underlay_page.patch_margin_right = 32
	_underlay_page.patch_margin_bottom = 32
	_underlay_page.self_modulate = Color(0.91, 0.85, 0.73, 0.94)
	_underlay_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	underlay.add_child(_underlay_page)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	_card.add_child(main_vbox)

	# Header Row
	var header_hbox := HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 12)
	main_vbox.add_child(header_hbox)

	var seal_icon := TextureRect.new()
	seal_icon.texture = SealBadgeTexture
	seal_icon.custom_minimum_size = Vector2(52.0, 52.0)
	seal_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	seal_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	seal_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_hbox.add_child(seal_icon)

	var title_col := VBoxContainer.new()
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_col.add_theme_constant_override("separation", 2)
	header_hbox.add_child(title_col)

	_title_label = Label.new()
	_title_label.text = "事件记录"
	_title_label.add_theme_font_override("font", UITokensScript.annual_font("display"))
	_title_label.add_theme_font_size_override("font_size", 32)
	_title_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	title_col.add_child(_title_label)

	_ai_toggle_button = _make_cut_tag_button("AI 配置")
	_ai_toggle_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_ai_toggle_button.pressed.connect(_toggle_ai_config_view)
	header_hbox.add_child(_ai_toggle_button)

	var close_btn := _make_cut_tag_button("关闭")
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close_btn.pressed.connect(func() -> void:
		close_panel()
		closed.emit()
	)
	header_hbox.add_child(close_btn)

	var rule := ColorRect.new()
	rule.custom_minimum_size = Vector2(0.0, 1.5)
	rule.color = UITokensScript.DOSSIER_RULE_STRONG
	main_vbox.add_child(rule)

	# Chronicle Scroll List
	_list_scroll = ScrollContainer.new()
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_vbox.add_child(_list_scroll)

	_list_vbox = VBoxContainer.new()
	_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_vbox.add_theme_constant_override("separation", 12)
	_list_scroll.add_child(_list_vbox)

	# AI Configuration Drawer (styled as an inserted torn-paper dossier leaf)
	_ai_config_panel = PanelContainer.new()
	_ai_config_panel.visible = false
	_ai_config_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var cfg_style := EraNoteStyle.duplicate() as StyleBoxTexture
	cfg_style.content_margin_left = 22.0
	cfg_style.content_margin_right = 22.0
	cfg_style.content_margin_top = 18.0
	cfg_style.content_margin_bottom = 18.0
	cfg_style.modulate_color = Color(0.99, 0.96, 0.89, 1.0)
	_ai_config_panel.add_theme_stylebox_override("panel", cfg_style)
	main_vbox.add_child(_ai_config_panel)

	var cfg_vbox := VBoxContainer.new()
	cfg_vbox.add_theme_constant_override("separation", 10)
	_ai_config_panel.add_child(cfg_vbox)

	var llm_sec_lbl := Label.new()
	llm_sec_lbl.text = "文本生成（LLM）"
	llm_sec_lbl.add_theme_font_override("font", UITokensScript.annual_font("display_soft"))
	llm_sec_lbl.add_theme_font_size_override("font_size", 18)
	llm_sec_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
	cfg_vbox.add_child(llm_sec_lbl)

	_ai_enabled_check = _make_toggle_button("启用 AI 生成事件")
	cfg_vbox.add_child(_ai_enabled_check)

	_llm_url_edit = _add_labeled_line_edit(cfg_vbox, "接口地址 (Base URL)", "https://api.deepseek.com/v1/chat/completions")
	_llm_model_edit = _add_labeled_line_edit(cfg_vbox, "模型名称 (Model)", "deepseek-chat")
	_llm_key_edit = _add_labeled_line_edit(cfg_vbox, "API 密钥 (仅存本地)", "sk-...", true)

	var sec_rule := ColorRect.new()
	sec_rule.custom_minimum_size = Vector2(0.0, 1.0)
	sec_rule.color = UITokensScript.DOSSIER_RULE
	cfg_vbox.add_child(sec_rule)

	var img_sec_lbl := Label.new()
	img_sec_lbl.text = "插画生成（Image API）"
	img_sec_lbl.add_theme_font_override("font", UITokensScript.annual_font("display_soft"))
	img_sec_lbl.add_theme_font_size_override("font_size", 18)
	img_sec_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
	cfg_vbox.add_child(img_sec_lbl)

	_img_enabled_check = _make_toggle_button("启用 AI 生成插画（失败时用内置题图）")
	cfg_vbox.add_child(_img_enabled_check)

	_img_url_edit = _add_labeled_line_edit(cfg_vbox, "生图接口 (Image URL)", "https://api.openai.com/v1/images/generations")
	_img_model_edit = _add_labeled_line_edit(cfg_vbox, "生图模型 (Image Model)", "dall-e-3")
	_img_key_edit = _add_labeled_line_edit(cfg_vbox, "生图密钥 (留空复用上项)", "sk-...", true)

	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 14)
	cfg_vbox.add_child(save_row)

	var save_btn := Button.new()
	save_btn.text = "保存配置"
	save_btn.custom_minimum_size = Vector2(180.0, 36.0)
	save_btn.theme_type_variation = &"PKSealPrimaryButton"
	save_btn.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	save_btn.add_theme_font_size_override("font_size", 15)
	UIAnimationScript.bind_tactile_button(save_btn)
	save_btn.pressed.connect(_save_ai_settings)
	save_row.add_child(save_btn)

	_save_status_label = Label.new()
	_save_status_label.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	_save_status_label.add_theme_font_size_override("font_size", 14)
	_save_status_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_VERDIGRIS)
	save_row.add_child(_save_status_label)


func _make_cut_tag_style(tint: Color = Color.WHITE) -> StyleBoxTexture:
	var st := StyleBoxTexture.new()
	st.texture = CutTagTexture
	st.texture_margin_left = 18.0
	st.texture_margin_top = 24.0
	st.texture_margin_right = 26.0
	st.texture_margin_bottom = 16.0
	st.content_margin_left = 12.0
	st.content_margin_top = 5.0
	st.content_margin_right = 16.0
	st.content_margin_bottom = 5.0
	st.modulate_color = tint
	return st


func _make_toggle_button(label_text: String) -> CheckButton:
	var btn := CheckButton.new()
	btn.text = label_text
	btn.focus_mode = Control.FOCUS_ALL
	btn.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	btn.add_theme_font_size_override("font_size", 14)
	btn.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	btn.add_theme_color_override("font_hover_color", UITokensScript.DOSSIER_OXBLOOD)
	btn.add_theme_color_override("font_pressed_color", UITokensScript.DOSSIER_OXBLOOD)
	btn.add_theme_color_override("font_focus_color", UITokensScript.DOSSIER_INK)
	var normal_st := _make_cut_tag_style(Color(0.97, 0.93, 0.82, 1.0))
	var hover_st := _make_cut_tag_style(Color(1.0, 0.97, 0.89, 1.0))
	btn.add_theme_stylebox_override("normal", normal_st)
	btn.add_theme_stylebox_override("hover", hover_st)
	btn.add_theme_stylebox_override("pressed", hover_st)
	btn.add_theme_stylebox_override("hover_pressed", hover_st)
	return btn


func _make_cut_tag_button(label_text: String) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.focus_mode = Control.FOCUS_ALL
	btn.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	btn.add_theme_color_override("font_hover_color", UITokensScript.DOSSIER_OXBLOOD)
	btn.add_theme_color_override("font_pressed_color", UITokensScript.DOSSIER_OXBLOOD)
	btn.add_theme_stylebox_override("normal", _make_cut_tag_style(Color(0.98, 0.94, 0.84, 1.0)))
	btn.add_theme_stylebox_override("hover", _make_cut_tag_style(Color(1.0, 0.97, 0.88, 1.0)))
	btn.add_theme_stylebox_override("pressed", _make_cut_tag_style(Color(0.91, 0.83, 0.68, 1.0)))
	UIAnimationScript.bind_tactile_button(btn)
	return btn


func _add_labeled_line_edit(parent: VBoxContainer, label_text: String, placeholder: String, secret: bool = false) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(180.0, 32.0)
	lbl.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK_SOFT)
	row.add_child(lbl)

	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.secret = secret
	edit.custom_minimum_size = Vector2(0.0, 34.0)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.add_theme_font_override("font", UITokensScript.dossier_font("sans"))
	edit.add_theme_font_size_override("font_size", 14)
	edit.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	edit.add_theme_color_override("font_placeholder_color", UITokensScript.DOSSIER_INK_MUTED)
	edit.add_theme_color_override("caret_color", UITokensScript.DOSSIER_OXBLOOD)
	var edit_style := _make_cut_tag_style(Color(0.97, 0.93, 0.82, 1.0))
	edit.add_theme_stylebox_override("normal", edit_style)
	edit.add_theme_stylebox_override("focus", _make_cut_tag_style(Color(1.0, 0.97, 0.89, 1.0)))
	row.add_child(edit)
	return edit


func _toggle_ai_config_view() -> void:
	_showing_ai_config = not _showing_ai_config
	_list_scroll.visible = not _showing_ai_config
	_ai_config_panel.visible = _showing_ai_config
	_title_label.text = "AI 配置" if _showing_ai_config else "事件记录"
	_ai_toggle_button.text = "返回记录" if _showing_ai_config else "AI 配置"
	if _showing_ai_config:
		_load_current_ai_settings()


func _load_current_ai_settings() -> void:
	var settings_node := get_node_or_null("/root/GameSettings")
	var vals: Dictionary = settings_node.values() if settings_node != null and settings_node.has_method("values") else {}
	_ai_enabled_check.button_pressed = bool(vals.get("ai_narrative_enabled", false))
	_llm_url_edit.text = String(vals.get("ai_llm_base_url", "https://api.deepseek.com/v1/chat/completions"))
	_llm_model_edit.text = String(vals.get("ai_llm_model", "deepseek-chat"))
	_img_enabled_check.button_pressed = bool(vals.get("ai_image_enabled", false))
	_img_url_edit.text = String(vals.get("ai_image_base_url", "https://api.openai.com/v1/images/generations"))
	_img_model_edit.text = String(vals.get("ai_image_model", "dall-e-3"))
	var keys := NarrativeAiClientScript.load_api_keys()
	_llm_key_edit.text = String(keys.get("llm_api_key", ""))
	_img_key_edit.text = String(keys.get("image_api_key", ""))
	_save_status_label.text = ""


func _save_ai_settings() -> void:
	var payload := {
		"ai_narrative_enabled": _ai_enabled_check.button_pressed,
		"ai_llm_base_url": _llm_url_edit.text.strip_edges(),
		"ai_llm_model": _llm_model_edit.text.strip_edges(),
		"ai_image_enabled": _img_enabled_check.button_pressed,
		"ai_image_base_url": _img_url_edit.text.strip_edges(),
		"ai_image_model": _img_model_edit.text.strip_edges(),
	}
	var settings_node := get_node_or_null("/root/GameSettings")
	if settings_node != null and settings_node.has_method("update"):
		settings_node.update(payload, true)
	NarrativeAiClientScript.save_api_keys(_llm_key_edit.text.strip_edges(), _img_key_edit.text.strip_edges())
	_save_status_label.text = "已保存"
	ai_settings_saved.emit(payload)


func open_panel(records: Array) -> void:
	if _card == null:
		_build_ui()
	_showing_ai_config = false
	_list_scroll.visible = true
	_ai_config_panel.visible = false
	_title_label.text = "事件记录"
	_ai_toggle_button.text = "AI 配置"
	set_records(records)
	visible = true
	_layout_sheet.call_deferred()
	_play_entrance()


func close_panel() -> void:
	visible = false


func is_panel_open() -> bool:
	return visible


func set_records(records: Array) -> void:
	if _card == null:
		_build_ui()
	_records = records.duplicate(true)
	for child in _list_vbox.get_children():
		child.queue_free()
	_card.custom_minimum_size.y = 0.0 if _records.is_empty() else 520.0
	for i in range(_records.size()):
		if not (_records[i] is Dictionary):
			continue
		var entry_card := _build_record_card(_records[i] as Dictionary, i)
		_list_vbox.add_child(entry_card)


func _build_record_card(rec: Dictionary, idx: int) -> PanelContainer:
	var note := PanelContainer.new()
	var style := EraNoteStyle.duplicate() as StyleBoxTexture
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 14.0
	style.content_margin_bottom = 14.0
	style.modulate_color = Color(0.99, 0.96, 0.88, 1.0)
	note.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	note.add_child(hbox)

	# Colored-pencil chapter emblem on the left
	var emblem := TextureRect.new()
	emblem.custom_minimum_size = Vector2(44.0, 44.0)
	emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	emblem.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var atlas := AtlasTexture.new()
	atlas.atlas = ChapterEmblemsTexture
	var em_idx := (idx * 2 + 1) % 9
	atlas.region = Rect2(float(em_idx % 3) * 512.0, float(em_idx / 3) * 512.0, 512.0, 512.0)
	emblem.texture = atlas
	hbox.add_child(emblem)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	hbox.add_child(vbox)

	var top_hbox := HBoxContainer.new()
	top_hbox.add_theme_constant_override("separation", 8)
	vbox.add_child(top_hbox)

	var day := int(rec.get("day", 1))
	var settlement := String(rec.get("settlement_name", "")).strip_edges()
	var title_text := String(rec.get("title", ""))
	# 日期行只补标题里缺的定位信息，避免同一行重复地名。
	var date_parts := PackedStringArray(["第 %d 日" % day])
	if not settlement.is_empty() and not title_text.contains(settlement):
		date_parts.append(settlement)
	var date_tag := Label.new()
	date_tag.text = "  ·  ".join(date_parts)
	date_tag.add_theme_font_override("font", UITokensScript.annual_font("label"))
	date_tag.add_theme_font_size_override("font_size", 13)
	date_tag.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
	top_hbox.add_child(date_tag)

	var title_lbl := Label.new()
	title_lbl.text = title_text
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_override("font", UITokensScript.annual_font("display_soft"))
	title_lbl.add_theme_font_size_override("font_size", 20)
	title_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	vbox.add_child(title_lbl)

	var choice_lbl := Label.new()
	choice_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var prob_pct := int(rec.get("outcome_probability_percent", 100))
	var outcome_str := String(rec.get("outcome_title", ""))
	if prob_pct < 100:
		outcome_str += "（%d%%）" % prob_pct
	choice_lbl.text = "选择：%s  ·  结果：%s" % [
		String(rec.get("chosen_option_text", "")),
		outcome_str,
	]
	choice_lbl.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	choice_lbl.add_theme_font_size_override("font_size", 14)
	choice_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK_SOFT)
	vbox.add_child(choice_lbl)

	var effects: PackedStringArray = PackedStringArray(rec.get("applied_effects_summary", []))
	if not effects.is_empty():
		var eff_lbl := Label.new()
		eff_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		eff_lbl.text = "  ·  ".join(effects)
		eff_lbl.add_theme_font_override("font", UITokensScript.dossier_font("sans"))
		eff_lbl.add_theme_font_size_override("font_size", 13)
		eff_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_VERDIGRIS)
		vbox.add_child(eff_lbl)

	var cell_idx := int(rec.get("cell_idx", -1))
	if cell_idx >= 0:
		var loc_btn := _make_cut_tag_button("定位")
		loc_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		loc_btn.pressed.connect(func() -> void:
			locate_cell_requested.emit(cell_idx)
		)
		hbox.add_child(loc_btn)

	return note


func _layout_sheet() -> void:
	if _card == null:
		return
	_card.pivot_offset = _card.size * 0.5


func _play_entrance() -> void:
	if _sheet_wrap == null or UIAnimationScript.reduced_motion():
		return
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	_sheet_wrap.modulate.a = 0.0
	_sheet_wrap.scale = Vector2(0.97, 0.94)
	_sheet_wrap.rotation = deg_to_rad(0.6)
	_open_tween = create_tween().set_parallel(true)
	_open_tween.tween_property(_sheet_wrap, "modulate:a", 1.0, 0.16)
	_open_tween.tween_property(_sheet_wrap, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_open_tween.tween_property(_sheet_wrap, "rotation", 0.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
