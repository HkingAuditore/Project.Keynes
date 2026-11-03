class_name NarrativeEventDialog
extends Control

## Hand-drawn / papercut / torn-paper archival narrative event folio.
## Uses the project's authentic torn_note_v1 / cut_tag_v1 / chronicle_pencil_*
## textures, ink-bleed & cover-wash shaders, and Muyao/Swei typography.
## Most options are deterministic (clean single-outcome layout); only high-risk
## gamble options display multi-branch probability splits.

signal option_selected(offer_id: int, offer_generation: int, option_index: int)
signal outcome_acknowledged()
signal locate_cell_requested(cell_idx: int)
signal chronicle_requested()

const UITokensScript = preload("res://scripts/ui/ui_tokens.gd")
const UIAnimationScript = preload("res://scripts/ui/ui_animation.gd")
const IconCatalogScript = preload("res://scripts/ui/icon_catalog.gd")
const NarrativeAiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")

const PlayerSessionTheme: Theme = preload("res://assets/themes/player_session_theme.tres")
const EraNoteStyle: StyleBoxTexture = preload("res://assets/ui/era/era_note_style.tres")
const TornNoteTexture: Texture2D = preload("res://assets/ui/paper_aux_v1/torn_note_v1.tres")
const CutTagTexture: Texture2D = preload("res://assets/ui/paper_aux_v1/cut_tag_v1.tres")
const SealBadgeTexture: Texture2D = preload("res://assets/ui/annual_chronicle/chronicle_pencil_badge.png")
const ChapterEmblemsTexture: Texture2D = preload("res://assets/ui/annual_chronicle/chronicle_chapter_emblems.png")

const InkBleedShader: Shader = preload("res://shaders/ui/annual_ink_bleed.gdshader")
const CoverWashShader: Shader = preload("res://shaders/ui/annual_cover_wash.gdshader")
const DeskVignetteShader: Shader = preload("res://shaders/ui/annual_grain_vignette.gdshader")

const ERA_CUTOUT_TEXTURES := [
	preload("res://assets/ui/annual_chronicle/stone_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/agrarian_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/kingdom_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/empire_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/exploration_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/enlightenment_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/steam_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/electrical_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/atomic_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/information_cutout.tres"),
	preload("res://assets/ui/annual_chronicle/intelligent_cutout.tres"),
]

const TAG_TO_EMBLEM_INDEX := {
	"climate": 7,
	"drought": 7,
	"cold": 7,
	"flood": 4,
	"geography": 4,
	"ocean": 6,
	"maritime": 6,
	"market": 6,
	"commerce": 6,
	"trade": 6,
	"industry": 3,
	"innovation": 5,
	"discovery": 5,
	"prospecting": 7,
	"chain": 5,
	"society": 2,
	"unrest": 2,
	"agriculture": 1,
	"harvest": 1,
	"prosperity": 0,
}

const TAG_CN_LABELS := {
	"climate": "气候",
	"drought": "干旱",
	"cold": "寒潮",
	"winter": "冬季",
	"ocean": "海洋",
	"maritime": "海运",
	"prosperity": "繁荣",
	"harvest": "丰收",
	"geography": "地理",
	"flood": "洪水",
	"agriculture": "农业",
	"market": "市场",
	"commerce": "贸易",
	"unrest": "动荡",
	"crisis": "危机",
	"industry": "工业",
	"innovation": "创新",
	"society": "社会",
	"livelihood": "民生",
	"chain": "事件链",
	"prospecting": "勘探",
	"discovery": "发现",
	"extractive": "采掘",
	"ai": "AI",
}

var _offer: Dictionary = {}
var _offer_open: bool = false
var _showing_outcome: bool = false
var _offer_id: int = 0
var _offer_generation: int = 0
var _cell_idx: int = -1

var _backdrop: ColorRect
var _sheet_wrap: Control
var _underlay_shadow: NinePatchRect
var _underlay_page: NinePatchRect
var _main_sheet: PanelContainer
var _art_clip: Control
var _art_rect: TextureRect
var _art_material: ShaderMaterial
var _wash_rect: ColorRect
var _emblem_badge: TextureRect
var _kicker_label: Label
var _title_label: Label
var _tags_row: HBoxContainer
var _locate_button: Button
var _chronicle_button: Button
var _body_label: Label
var _trigger_slip: PanelContainer
var _trigger_notes_label: Label
var _options_vbox: VBoxContainer
var _outcome_panel: PanelContainer
var _outcome_seal: TextureRect
var _outcome_kicker_label: Label
var _outcome_title_label: Label
var _outcome_effects_vbox: VBoxContainer
var _ack_button: Button
var _error_label: Label
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
	if _main_sheet != null:
		return

	# 1. Atmospheric vignette desk backdrop
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
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

	# 2. Centered floating multi-layered torn paper folio
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(center)

	_main_sheet = PanelContainer.new()
	_main_sheet.name = "MainSheet"
	_main_sheet.custom_minimum_size = Vector2(740.0, 500.0)
	var sheet_style := EraNoteStyle.duplicate() as StyleBoxTexture
	sheet_style.content_margin_left = 30.0
	sheet_style.content_margin_right = 30.0
	sheet_style.content_margin_top = 20.0
	sheet_style.content_margin_bottom = 22.0
	_main_sheet.add_theme_stylebox_override("panel", sheet_style)
	center.add_child(_main_sheet)
	_sheet_wrap = _main_sheet

	var underlay := Control.new()
	underlay.name = "Underlay"
	underlay.show_behind_parent = true
	underlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_main_sheet.add_child(underlay)

	# Soft ambient contact shadow
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

	# Slightly rotated underneath loose paper sheet for authentic stacked folio feel
	_underlay_page = NinePatchRect.new()
	_underlay_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_underlay_page.offset_left = -3.0
	_underlay_page.offset_top = 3.0
	_underlay_page.offset_right = 4.0
	_underlay_page.offset_bottom = 5.0
	_underlay_page.rotation = deg_to_rad(-0.75)
	_underlay_page.texture = TornNoteTexture
	_underlay_page.patch_margin_left = 32
	_underlay_page.patch_margin_top = 32
	_underlay_page.patch_margin_right = 32
	_underlay_page.patch_margin_bottom = 32
	_underlay_page.self_modulate = Color(0.91, 0.85, 0.73, 0.94)
	_underlay_page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	underlay.add_child(_underlay_page)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	_main_sheet.add_child(col)

	# Top Bar: Kicker + Cut-Paper Tags + Action Links
	var top_bar := HBoxContainer.new()
	top_bar.add_theme_constant_override("separation", 8)
	col.add_child(top_bar)

	_kicker_label = Label.new()
	_kicker_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_kicker_label.add_theme_font_override("font", UITokensScript.annual_font("label"))
	_kicker_label.add_theme_font_size_override("font_size", 15)
	_kicker_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
	top_bar.add_child(_kicker_label)

	_tags_row = HBoxContainer.new()
	_tags_row.add_theme_constant_override("separation", 4)
	top_bar.add_child(_tags_row)

	_locate_button = _make_cut_tag_button("定位")
	_locate_button.pressed.connect(func() -> void:
		if _cell_idx >= 0:
			locate_cell_requested.emit(_cell_idx)
	)
	top_bar.add_child(_locate_button)

	_chronicle_button = _make_cut_tag_button("记录")
	_chronicle_button.pressed.connect(func() -> void:
		chronicle_requested.emit()
	)
	top_bar.add_child(_chronicle_button)

	# Title Row with Handwritten Brush Font + Coloured-Pencil Chapter Emblem
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 12)
	col.add_child(header_row)

	_emblem_badge = TextureRect.new()
	_emblem_badge.custom_minimum_size = Vector2(54.0, 54.0)
	_emblem_badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_emblem_badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_emblem_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_row.add_child(_emblem_badge)

	var title_col := VBoxContainer.new()
	title_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_col.add_theme_constant_override("separation", 4)
	header_row.add_child(title_col)

	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.add_theme_font_override("font", UITokensScript.annual_font("display"))
	_title_label.add_theme_font_size_override("font_size", 34)
	_title_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	title_col.add_child(_title_label)

	var title_rule := ColorRect.new()
	title_rule.custom_minimum_size = Vector2(0.0, 1.5)
	title_rule.color = UITokensScript.DOSSIER_RULE_STRONG
	title_col.add_child(title_rule)

	# Colored-Pencil Papercut Illustration Stage (no rectangular dark box! Blends into paper)
	_art_clip = Control.new()
	_art_clip.custom_minimum_size = Vector2(640.0, 134.0)
	_art_clip.clip_contents = true
	_art_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_art_clip)

	_art_rect = TextureRect.new()
	_art_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_art_material = ShaderMaterial.new()
	_art_material.shader = InkBleedShader
	_art_material.set_shader_parameter("bleed", 1.2)
	_art_material.set_shader_parameter("edge", 0.07)
	_art_material.set_shader_parameter("direction", Vector2(0.15, 1.0))
	_art_material.set_shader_parameter("rim", 0.12)
	_art_material.set_shader_parameter("noise_scale", 5.0)
	_art_material.set_shader_parameter("noise_amount", 0.14)
	_art_rect.material = _art_material
	_art_clip.add_child(_art_rect)

	# Feathered wash at the bottom of the illustration so it melts into the parchment
	_wash_rect = ColorRect.new()
	_wash_rect.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_wash_rect.offset_top = -54.0
	_wash_rect.offset_bottom = 0.0
	_wash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var wash_mat := ShaderMaterial.new()
	wash_mat.shader = CoverWashShader
	wash_mat.set_shader_parameter("paper_color", UITokensScript.DOSSIER_PAPER)
	wash_mat.set_shader_parameter("axis", 1)
	wash_mat.set_shader_parameter("strength", 0.96)
	wash_mat.set_shader_parameter("feather", 0.48)
	wash_mat.set_shader_parameter("edge_taper", 0.12)
	_wash_rect.material = wash_mat
	_art_clip.add_child(_wash_rect)

	# Narrative Story Body in classical serif/brush body font
	_body_label = Label.new()
	_body_label.name = "BodyLabel"
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body_label.add_theme_font_override("font", UITokensScript.DOSSIER_SERIF)
	_body_label.add_theme_font_size_override("font_size", 17)
	_body_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	_body_label.add_theme_constant_override("line_spacing", 5)
	col.add_child(_body_label)

	# Optional on-trigger omen slip (cut-paper strip)
	_trigger_slip = PanelContainer.new()
	_trigger_slip.visible = false
	_trigger_slip.add_theme_stylebox_override("panel", _make_cut_tag_style(Color(0.96, 0.89, 0.74, 0.95)))
	col.add_child(_trigger_slip)

	_trigger_notes_label = Label.new()
	_trigger_notes_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_trigger_notes_label.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	_trigger_notes_label.add_theme_font_size_override("font_size", 13)
	_trigger_notes_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
	_trigger_slip.add_child(_trigger_notes_label)

	var mid_rule := ColorRect.new()
	mid_rule.custom_minimum_size = Vector2(0.0, 1.0)
	mid_rule.color = UITokensScript.DOSSIER_RULE
	col.add_child(mid_rule)

	# Options Stack (each option is a tactile torn-paper decree note)
	_options_vbox = VBoxContainer.new()
	_options_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_vbox.add_theme_constant_override("separation", 10)
	col.add_child(_options_vbox)

	# Outcome Resolution View (with Cinnabar Red Seal & Torn Note)
	_outcome_panel = PanelContainer.new()
	_outcome_panel.visible = false
	var out_note_style := EraNoteStyle.duplicate() as StyleBoxTexture
	out_note_style.content_margin_left = 22.0
	out_note_style.content_margin_right = 22.0
	out_note_style.content_margin_top = 18.0
	out_note_style.content_margin_bottom = 18.0
	out_note_style.modulate_color = Color(0.99, 0.96, 0.89, 1.0)
	_outcome_panel.add_theme_stylebox_override("panel", out_note_style)
	col.add_child(_outcome_panel)

	var out_hbox := HBoxContainer.new()
	out_hbox.add_theme_constant_override("separation", 16)
	_outcome_panel.add_child(out_hbox)

	_outcome_seal = TextureRect.new()
	_outcome_seal.texture = SealBadgeTexture
	_outcome_seal.custom_minimum_size = Vector2(68.0, 68.0)
	_outcome_seal.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_outcome_seal.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_outcome_seal.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	out_hbox.add_child(_outcome_seal)

	var out_vbox := VBoxContainer.new()
	out_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	out_vbox.add_theme_constant_override("separation", 8)
	out_hbox.add_child(out_vbox)

	_outcome_kicker_label = Label.new()
	_outcome_kicker_label.add_theme_font_override("font", UITokensScript.annual_font("label"))
	_outcome_kicker_label.add_theme_font_size_override("font_size", 13)
	_outcome_kicker_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
	out_vbox.add_child(_outcome_kicker_label)

	_outcome_title_label = Label.new()
	_outcome_title_label.add_theme_font_override("font", UITokensScript.annual_font("display"))
	_outcome_title_label.add_theme_font_size_override("font_size", 26)
	_outcome_title_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	out_vbox.add_child(_outcome_title_label)

	_outcome_effects_vbox = VBoxContainer.new()
	_outcome_effects_vbox.add_theme_constant_override("separation", 4)
	out_vbox.add_child(_outcome_effects_vbox)

	var ack_row := HBoxContainer.new()
	ack_row.alignment = BoxContainer.ALIGNMENT_END
	out_vbox.add_child(ack_row)

	_ack_button = Button.new()
	_ack_button.text = "确认"
	_ack_button.custom_minimum_size = Vector2(188.0, 38.0)
	_ack_button.theme_type_variation = &"PKSealPrimaryButton"
	_ack_button.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	_ack_button.add_theme_font_size_override("font_size", 15)
	UIAnimationScript.bind_tactile_button(_ack_button)
	_ack_button.pressed.connect(func() -> void:
		outcome_acknowledged.emit()
	)
	ack_row.add_child(_ack_button)

	_error_label = Label.new()
	_error_label.visible = false
	_error_label.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	_error_label.add_theme_font_size_override("font_size", 14)
	_error_label.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
	col.add_child(_error_label)


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


func _make_tag_pill(tag_raw: String) -> Label:
	var lbl := Label.new()
	var cn := String(TAG_CN_LABELS.get(tag_raw.to_lower(), tag_raw))
	lbl.text = cn
	lbl.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK_SOFT)
	var st := _make_cut_tag_style(Color(0.95, 0.89, 0.76, 0.92))
	st.content_margin_left = 9.0
	st.content_margin_right = 12.0
	st.content_margin_top = 3.0
	st.content_margin_bottom = 3.0
	lbl.add_theme_stylebox_override("normal", st)
	return lbl


func _chapter_emblem_for_tags(tags: Array) -> Texture2D:
	var idx := 0
	for t in tags:
		var k := String(t).to_lower()
		if TAG_TO_EMBLEM_INDEX.has(k):
			idx = int(TAG_TO_EMBLEM_INDEX[k])
			break
	var atlas := AtlasTexture.new()
	atlas.atlas = ChapterEmblemsTexture
	var col_idx := idx % 3
	var row_idx := idx / 3
	atlas.region = Rect2(float(col_idx) * 512.0, float(row_idx) * 512.0, 512.0, 512.0)
	return atlas


func present_offer(offer: Dictionary) -> void:
	if _main_sheet == null:
		_build_ui()
	_offer = offer.duplicate(true)
	_offer_open = true
	_showing_outcome = false
	_offer_id = int(offer.get("offer_id", 0))
	_offer_generation = int(offer.get("offer_generation", 1))
	_cell_idx = int(offer.get("cell_idx", -1))

	var settlement := String(offer.get("settlement_name", "")).strip_edges()
	var landform := String(offer.get("landform_name", "")).strip_edges()
	var temp := float(offer.get("temperature", 18.0))
	var day := int(offer.get("day", 1))
	var ai_flag := "AI 生成" if bool(offer.get("is_ai_generated", false)) else ""

	_title_label.text = String(offer.get("title", "事件"))
	_locate_button.visible = _cell_idx >= 0

	# 题头只补标题里没有的定位信息：日、聚落、地貌、气温、来源。
	var kicker_parts := PackedStringArray(["第 %d 日" % day])
	if not settlement.is_empty() and not _title_label.text.contains(settlement):
		kicker_parts.append(settlement)
	if not landform.is_empty():
		kicker_parts.append(landform)
	kicker_parts.append("%.1f°C" % temp)
	if not ai_flag.is_empty():
		kicker_parts.append(ai_flag)
	_kicker_label.text = "  ·  ".join(kicker_parts)

	for child in _tags_row.get_children():
		child.queue_free()
	var tags: Array = offer.get("tags", [])
	# 只有映射到中文分类的标签才显示；内部 id（如 ai_narrative）不进界面。
	var shown_tags := 0
	for i in range(tags.size()):
		var tag_raw := String(tags[i]).to_lower()
		if not TAG_CN_LABELS.has(tag_raw):
			continue
		_tags_row.add_child(_make_tag_pill(tag_raw))
		shown_tags += 1
		if shown_tags >= 3:
			break

	_emblem_badge.texture = _chapter_emblem_for_tags(tags)
	_body_label.text = String(offer.get("body_text", "")).strip_edges()
	_body_label.visible = not _body_label.text.is_empty()

	var trig_notes: Array = offer.get("on_trigger_summaries", [])
	if not trig_notes.is_empty():
		_trigger_notes_label.text = "已生效：" + "；".join(PackedStringArray(trig_notes))
		_trigger_slip.visible = true
	else:
		_trigger_slip.visible = false

	_update_illustration(offer)

	_options_vbox.visible = true
	_outcome_panel.visible = false
	_error_label.visible = false

	for child in _options_vbox.get_children():
		child.queue_free()

	var options: Array = offer.get("options", [])
	for i in range(options.size()):
		if not (options[i] is Dictionary):
			continue
		var opt_card := _build_option_card(options[i] as Dictionary, i)
		_options_vbox.add_child(opt_card)

	visible = true
	_layout_sheet.call_deferred()
	_play_sheet_entrance()


func _build_option_card(opt_dict: Dictionary, index: int) -> PanelContainer:
	var card := PanelContainer.new()
	var normal_paper := EraNoteStyle.duplicate() as StyleBoxTexture
	normal_paper.content_margin_left = 18.0
	normal_paper.content_margin_right = 18.0
	normal_paper.content_margin_top = 12.0
	normal_paper.content_margin_bottom = 12.0
	normal_paper.modulate_color = Color(0.985, 0.955, 0.875, 1.0)

	var hover_paper := normal_paper.duplicate() as StyleBoxTexture
	hover_paper.modulate_color = Color(1.03, 1.0, 0.92, 1.0)
	card.add_theme_stylebox_override("panel", normal_paper)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	card.add_child(row)

	# Left accent wax/ink bar
	var outcomes: Array = opt_dict.get("outcomes", [])
	var is_probabilistic := outcomes.size() > 1
	var bar := ColorRect.new()
	bar.custom_minimum_size = Vector2(3.5, 0.0)
	bar.color = UITokensScript.DOSSIER_BRASS if is_probabilistic else UITokensScript.DOSSIER_OXBLOOD
	row.add_child(bar)

	var content_col := VBoxContainer.new()
	content_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_col.add_theme_constant_override("separation", 5)
	row.add_child(content_col)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	content_col.add_child(title_row)

	var opt_title := Label.new()
	opt_title.text = String(opt_dict.get("text", "选项"))
	opt_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	opt_title.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
	opt_title.add_theme_font_size_override("font_size", 16)
	opt_title.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK)
	title_row.add_child(opt_title)

	var eligible := bool(opt_dict.get("eligible", true))
	if not eligible:
		var reason_lbl := Label.new()
		reason_lbl.text = "不可选：" + String(opt_dict.get("ineligible_reason", "条件未满足"))
		reason_lbl.add_theme_font_override("font", UITokensScript.dossier_font("sans"))
		reason_lbl.add_theme_font_size_override("font_size", 13)
		reason_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_OXBLOOD)
		content_col.add_child(reason_lbl)

	# Render outcomes:
	# - Single deterministic outcome (majority of options): show effect lines directly, no probability noise.
	# - Multi-outcome gamble option (minority): one row per branch with its percentage.
	if outcomes.size() == 1 and outcomes[0] is Dictionary:
		var od: Dictionary = outcomes[0]
		var eff_lines: PackedStringArray = PackedStringArray(od.get("effect_summaries", []))
		var eff_text := "  ·  ".join(eff_lines) if not eff_lines.is_empty() else String(od.get("outcome_title", "无效果"))
		var eff_lbl := Label.new()
		eff_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		eff_lbl.text = eff_text
		eff_lbl.add_theme_font_override("font", UITokensScript.dossier_font("sans"))
		eff_lbl.add_theme_font_size_override("font_size", 14)
		eff_lbl.add_theme_color_override("font_color", UITokensScript.DOSSIER_VERDIGRIS)
		content_col.add_child(eff_lbl)
	elif outcomes.size() > 1:
		for out_item in outcomes:
			if not (out_item is Dictionary):
				continue
			var od: Dictionary = out_item
			var prob_pct := int(od.get("probability_percent", 50))
			var out_title := String(od.get("outcome_title", "分支"))
			var eff_lines: PackedStringArray = PackedStringArray(od.get("effect_summaries", []))
			var eff_joined := "；".join(eff_lines) if not eff_lines.is_empty() else "无效果"

			var branch_row := HBoxContainer.new()
			branch_row.add_theme_constant_override("separation", 6)
			content_col.add_child(branch_row)

			var pct_badge := Label.new()
			pct_badge.text = "%d%% %s" % [prob_pct, out_title]
			pct_badge.custom_minimum_size = Vector2(124.0, 0.0)
			pct_badge.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
			pct_badge.add_theme_font_size_override("font_size", 13)
			pct_badge.add_theme_color_override("font_color",
				UITokensScript.DOSSIER_VERDIGRIS if prob_pct >= 50 else UITokensScript.DOSSIER_UMBER)
			branch_row.add_child(pct_badge)

			var branch_eff := Label.new()
			branch_eff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			branch_eff.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			branch_eff.text = eff_joined
			branch_eff.add_theme_font_override("font", UITokensScript.dossier_font("sans"))
			branch_eff.add_theme_font_size_override("font_size", 13)
			branch_eff.add_theme_color_override("font_color", UITokensScript.DOSSIER_INK_SOFT)
			branch_row.add_child(branch_eff)

	# Right-side action button
	var choose_btn := _make_cut_tag_button("选择")
	choose_btn.custom_minimum_size = Vector2(98.0, 38.0)
	choose_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	choose_btn.disabled = not eligible
	var hint := String(opt_dict.get("tooltip_hint", "")).strip_edges()
	if not hint.is_empty():
		choose_btn.tooltip_text = hint
	choose_btn.pressed.connect(func() -> void:
		option_selected.emit(_offer_id, _offer_generation, index)
	)
	choose_btn.mouse_entered.connect(func() -> void:
		card.add_theme_stylebox_override("panel", hover_paper)
	)
	choose_btn.mouse_exited.connect(func() -> void:
		card.add_theme_stylebox_override("panel", normal_paper)
	)
	row.add_child(choose_btn)

	return card


func _update_illustration(offer: Dictionary) -> void:
	var img_path := String(offer.get("image_path", "")).strip_edges()
	if not img_path.is_empty():
		var cached_tex := NarrativeAiClientScript.load_cached_texture(img_path)
		if cached_tex != null:
			set_illustration_texture(cached_tex)
			return
		elif ResourceLoader.exists(img_path):
			var res_tex := load(img_path) as Texture2D
			if res_tex != null:
				set_illustration_texture(res_tex)
				return

	# Use the project's authentic colored-pencil papercut era illustrations!
	var era_idx := clampi(int(offer.get("era_index", 1)), 0, ERA_CUTOUT_TEXTURES.size() - 1)
	var tags: Array = offer.get("tags", [])
	if tags.has("ocean") or tags.has("maritime"):
		era_idx = 4 # exploration maritime cutout
	elif tags.has("industry") or tags.has("prospecting") or tags.has("extractive"):
		era_idx = 2 # kingdom/workshop cutout
	elif tags.has("climate") or tags.has("drought") or tags.has("agriculture"):
		era_idx = 1 # agrarian cutout
	_art_rect.texture = ERA_CUTOUT_TEXTURES[era_idx]


func set_illustration_texture(tex: Texture2D) -> void:
	if _art_rect != null and tex != null:
		_art_rect.texture = tex


func show_outcome(resolution: Dictionary) -> void:
	if _main_sheet == null:
		_build_ui()
	_showing_outcome = true
	_options_vbox.visible = false
	_error_label.visible = false
	_outcome_panel.visible = true

	var outcome: Dictionary = resolution.get("outcome", {})
	var record: Dictionary = resolution.get("record", {})
	var prob_pct := int(outcome.get("probability_percent", record.get("outcome_probability_percent", 100)))
	var out_title := String(outcome.get("outcome_title", record.get("outcome_title", "已执行")))
	# 概率分支才需要标出命中比例；确定结果没有额外信息。
	_outcome_kicker_label.visible = prob_pct < 100
	_outcome_kicker_label.text = "概率 %d%%" % prob_pct
	_outcome_title_label.text = out_title

	for child in _outcome_effects_vbox.get_children():
		child.queue_free()

	var summaries: PackedStringArray = PackedStringArray(
		resolution.get("applied_summaries", record.get("applied_effects_summary", []))
	)
	for line in summaries:
		var chip := Label.new()
		chip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		chip.text = String(line)
		chip.add_theme_font_override("font", UITokensScript.dossier_font("sans_strong"))
		chip.add_theme_font_size_override("font_size", 14)
		chip.add_theme_color_override("font_color", UITokensScript.DOSSIER_VERDIGRIS)
		_outcome_effects_vbox.add_child(chip)

	_layout_sheet.call_deferred()


func _layout_sheet() -> void:
	if _main_sheet == null:
		return
	_main_sheet.pivot_offset = _main_sheet.size * 0.5


func _play_sheet_entrance() -> void:
	if _sheet_wrap == null or UIAnimationScript.reduced_motion():
		return
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()
	_sheet_wrap.modulate.a = 0.0
	_sheet_wrap.scale = Vector2(0.97, 0.94)
	_sheet_wrap.rotation = deg_to_rad(-0.8)
	_art_material.set_shader_parameter("bleed", 0.15)
	_open_tween = create_tween().set_parallel(true)
	_open_tween.tween_property(_sheet_wrap, "modulate:a", 1.0, 0.16)
	_open_tween.tween_property(_sheet_wrap, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_open_tween.tween_property(_sheet_wrap, "rotation", 0.0, 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_open_tween.tween_method(func(v: float) -> void:
		_art_material.set_shader_parameter("bleed", v), 0.15, 1.2, 0.42
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func show_error(message: String) -> void:
	if _main_sheet == null:
		_build_ui()
	_error_label.text = message
	_error_label.visible = not message.is_empty()


func close_offer() -> void:
	_offer_open = false
	_showing_outcome = false
	_offer.clear()
	visible = false


func is_offer_open() -> bool:
	return _offer_open and visible
