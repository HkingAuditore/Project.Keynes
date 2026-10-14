extends Control
class_name FamilyWorkspace

const FamilyVBoxScene := preload("res://scenes/ui/family/family_vbox.tscn")
const FamilyHBoxScene := preload("res://scenes/ui/family/family_hbox.tscn")
const FamilyGridScene := preload("res://scenes/ui/family/family_grid.tscn")
const FamilyCardScene := preload("res://scenes/ui/family/family_card.tscn")
const FamilyLabelScene := preload("res://scenes/ui/family/family_label.tscn")
const FamilyButtonScene := preload("res://scenes/ui/family/family_button.tscn")
const FamilyTextureScene := preload("res://scenes/ui/family/family_texture_rect.tscn")
const FamilyProgressScene := preload("res://scenes/ui/family/family_progress_bar.tscn")
const FamilyControlScene := preload("res://scenes/ui/family/family_control.tscn")
const IconBadgeScene := preload("res://scenes/ui/icon_badge.tscn")
const FactGridScene := preload("res://scenes/ui/inspector_fact_grid.tscn")
const MeterListScene := preload("res://scenes/ui/inspector_meter_list.tscn")
const NoteListScene := preload("res://scenes/ui/inspector_note_list.tscn")

signal closed()
signal colonization_requested(family_handle: int, source_cell: int)

const PAGE_ORDER: Array[String] = [
	"overview", "traits", "preferences", "effects", "people", "branches"]
const PAGE_META := {
	"overview": {
		"title": "概览",
		"icon": "family.workspace.overview",
		"nav_icon": &"summary.overview",
		"question": "家族核心家风、显著偏好、据点威望与主要成员总览",
	},
	"traits": {
		"title": "家族特性",
		"icon": "family.workspace.traits",
		"nav_icon": &"family.house",
		"question": "立族核心门风与随时代演进的附加特性",
	},
	"preferences": {
		"title": "行为偏好",
		"icon": "family.workspace.preferences",
		"nav_icon": &"ecology.growth",
		"question": "产业投资、职业从业、民生需求与商品消费四轴倾向",
	},
	"effects": {
		"title": "家族效果",
		"icon": "family.workspace.effects",
		"nav_icon": &"technology.milestone",
		"question": "各分支地块生效的威望五档阶梯加成与触发器进度",
	},
	"people": {
		"title": "主要人物",
		"icon": "family.workspace.people",
		"nav_icon": &"population.profession.owner",
		"question": "家族重要人物的职务身份、股权净值与周期收支对冲",
	},
	"branches": {
		"title": "领地与分支",
		"icon": "family.workspace.branches",
		"nav_icon": &"metric.territory",
		"question": "家族在各地块的人口、资金、产业份额与开拓派遣",
	},
}
const NAV_NAMES := {
	"overview": "NavOverview", "traits": "NavTraits",
	"preferences": "NavPreferences", "effects": "NavEffects",
	"people": "NavPeople", "branches": "NavBranches",
}
const PAGE_FADE_SECONDS := 0.12
const OPEN_SECONDS := 0.18
const CLOSE_SECONDS := 0.14
const RAIL_WIDTH := 184.0
const COMPACT_WIDTH := 720.0

var _model: Dictionary = {}
var _current_page := "overview"
var _family_handle := 0
var _page_cache: Dictionary = {}
var _page_signatures: Dictionary = {}
var _scroll_by_page: Dictionary = {}
var _nav_buttons: Dictionary = {}
var _nav_labels: Dictionary = {}
var _nav_icons: Dictionary = {}
var _mobile_buttons: Dictionary = {}
var _kpi_cards: Array[DossierKpiCard] = []
var _kpi_signatures: Dictionary = {}
var _player_controller = null
var _fullscreen_mode := false
var _closing := false
var _close_generation := 0

@onready var _nav_rail_surface: PanelContainer = get_node_or_null("%NavRailSurface") as PanelContainer
@onready var _page_surface: PanelContainer = get_node_or_null("%PageSurface") as PanelContainer
@onready var _hinges: Control = get_node_or_null("%Hinges") as Control
@onready var _nav_column: VBoxContainer = %NavColumn
@onready var _safe_margin: MarginContainer = $SafeMargin
@onready var _mobile_nav: ScrollContainer = %MobileNav
@onready var _mobile_buttons_host: HBoxContainer = %Buttons
@onready var _crest: TextureRect = %Crest
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _prestige_value: Label = %PrestigeValue
@onready var _prestige_caption: Label = %PrestigeCaption
@onready var _prestige_plate: TextureRect = %PrestigePlate
@onready var _chapter_nav: DossierChapterNav = get_node_or_null("%ChapterNav") as DossierChapterNav
@onready var _summary_band: PanelContainer = get_node_or_null("%SummaryBand") as PanelContainer
@onready var _kpi_row: HBoxContainer = get_node_or_null("%KpiRow") as HBoxContainer
@onready var _page_title: Label = %PageTitle
@onready var _page_icon: TextureRect = %PageIcon
@onready var _page_scroll: ScrollContainer = %PageScroll
@onready var _page_host: VBoxContainer = %PageHost
@onready var _close_button: Button = %CloseButton


func _ready() -> void:
	for page_id in PAGE_ORDER:
		var button := get_node_or_null("%" + String(NAV_NAMES[page_id])) as Button
		if button == null:
			continue
		_setup_desktop_nav_button(button, page_id)
		button.pressed.connect(_select_page.bind(page_id, true))
		_nav_buttons[page_id] = button
		var mobile := FamilyButtonScene.instantiate() as Button
		mobile.name = "Mobile%s" % page_id.capitalize()
		mobile.custom_minimum_size = Vector2(96.0, 38.0)
		mobile.toggle_mode = true
		mobile.text = String(PAGE_META[page_id].title)
		mobile.icon = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
		mobile.add_theme_constant_override("icon_max_width", 20)
		mobile.theme_type_variation = &"PKChapterTab"
		mobile.pressed.connect(_select_page.bind(page_id, true))
		_mobile_buttons_host.add_child(mobile)
		_mobile_buttons[page_id] = mobile
	if _chapter_nav != null:
		var chapters: Array = []
		for page_id in PAGE_ORDER:
			var meta: Dictionary = PAGE_META[page_id]
			chapters.append({
				"id": page_id,
				"label": String(meta.title),
				"icon": meta.get("nav_icon", &"summary.overview"),
				"question": String(meta.get("question", "")),
			})
		_chapter_nav.set_chapters(chapters, _current_page)
		_chapter_nav.chapter_selected.connect(func(ch_id: String) -> void:
			_select_page(ch_id, true))
	_kpi_cards.clear()
	if _kpi_row != null:
		for child in _kpi_row.get_children():
			if child is DossierKpiCard:
				(child as Control).custom_minimum_size = Vector2(72.0, DossierKpiCard.HEIGHT)
				_kpi_cards.append(child as DossierKpiCard)
		if not _kpi_cards.is_empty():
			_kpi_cards[_kpi_cards.size() - 1].show_divider = false
	IconButton.apply(_close_button, &"action.close", IconButton.SMALL, "关闭家族档案")
	_close_button.pressed.connect(request_close)
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	_update_nav_state()


func _setup_desktop_nav_button(button: Button, page_id: String) -> void:
	button.text = ""
	button.icon = null
	button.clip_contents = false
	button.theme_type_variation = &"PKCountryNavButton"
	button.tooltip_text = String(PAGE_META[page_id].get("question", PAGE_META[page_id].title))
	var row := FamilyHBoxScene.instantiate() as HBoxContainer
	row.name = "Visual"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 24.0
	row.offset_top = 4.0
	row.offset_right = -14.0
	row.offset_bottom = -4.0
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 8)
	var icon := FamilyTextureScene.instantiate() as TextureRect
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(22.0, 22.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	_nav_icons[page_id] = icon
	var label := FamilyLabelScene.instantiate() as Label
	label.text = String(PAGE_META[page_id].title)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"PKCountryRailMuted"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	_nav_labels[page_id] = label
	UIAnimation.bind_hover_glow(button, row)


func set_player_controller(controller) -> void:
	_player_controller = controller


func set_fullscreen_mode(fullscreen: bool) -> void:
	_fullscreen_mode = fullscreen
	_apply_responsive_layout()


func show_family(model: Dictionary, animate: bool = true) -> void:
	_close_generation += 1
	_closing = false
	set_model(model)
	if animate:
		UIAnimation.fade_slide_in(self, Vector2(36.0, 0.0), OPEN_SECONDS)
	else:
		visible = true
	call_deferred("_focus_current_navigation")


func set_model(model: Dictionary) -> void:
	if model.is_empty():
		return
	var next_handle := int(model.get("actions", {}).get("family_handle", 0))
	var family_changed := _family_handle != next_handle
	if family_changed:
		_clear_page_cache()
		_scroll_by_page.clear()
		_kpi_signatures.clear()
		_current_page = "overview"
		_family_handle = next_handle
	_model = model.duplicate(true)
	_update_header()
	_update_summary(not family_changed)
	_ensure_page(_current_page)
	_refresh_page(_current_page)
	_update_nav_state()
	_apply_responsive_layout()


func request_close() -> void:
	if not visible or _closing:
		return
	_closing = true
	_close_generation += 1
	var generation := _close_generation
	UIAnimation.fade_slide_out(self, Vector2(32.0, 0.0), CLOSE_SECONDS)
	get_tree().create_timer(CLOSE_SECONDS).timeout.connect(func() -> void:
		if generation != _close_generation:
			return
		_closing = false
		closed.emit())


func hide_immediately() -> void:
	_close_generation += 1
	_closing = false
	visible = false
	modulate.a = 1.0


func current_page() -> String:
	return _current_page


func select_page(page_id: String, animate: bool = true) -> void:
	_select_page(page_id, animate)


func cached_page_count() -> int:
	return _page_cache.size()


func content_node_count() -> int:
	return _count_nodes(_page_host)


func compact_navigation() -> bool:
	return _mobile_nav.visible


func _select_page(page_id: String, animate: bool = true) -> void:
	if not PAGE_META.has(page_id):
		return
	if _page_scroll != null:
		_scroll_by_page[_current_page] = _page_scroll.scroll_vertical
	_current_page = page_id
	_ensure_page(page_id)
	for cached_id in _page_cache:
		(_page_cache[cached_id] as Control).visible = String(cached_id) == page_id
	_refresh_page(page_id)
	_update_nav_state()
	_page_title.text = String(PAGE_META[page_id].title)
	_page_icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
	call_deferred("_restore_page_scroll", page_id)
	_apply_responsive_layout()
	if animate:
		var active_page := _page_cache[page_id] as Control
		_replay_page_charts(active_page)
		UIAnimation.crossfade(active_page, PAGE_FADE_SECONDS)
		UIAnimation.stagger_children_in(active_page, 0.024, 8, PAGE_FADE_SECONDS)


func _replay_page_charts(root: Node) -> void:
	if root == null:
		return
	if root is DossierChart:
		(root as DossierChart).replay_growth()
	for child in root.get_children():
		_replay_page_charts(child)


func _ensure_page(page_id: String) -> void:
	var rows := _page_rows(page_id)
	var signature := _shape_signature(rows)
	if _page_cache.has(page_id) and String(_page_signatures.get(page_id, "")) == signature:
		return
	if _page_cache.has(page_id):
		var old := _page_cache[page_id] as Control
		_page_host.remove_child(old)
		old.queue_free()
	var page := FamilyVBoxScene.instantiate() as VBoxContainer
	page.name = "Page%s" % page_id.capitalize()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.clip_contents = true
	page.add_theme_constant_override("separation", 14)
	_page_host.add_child(page)
	_page_cache[page_id] = page
	_page_signatures[page_id] = signature
	_build_page(page_id, page, rows)
	var bottom_spacer := FamilyControlScene.instantiate() as Control
	bottom_spacer.name = "BottomSafeSpacer"
	bottom_spacer.custom_minimum_size.y = 16.0
	page.add_child(bottom_spacer)
	for cached_id in _page_cache:
		(_page_cache[cached_id] as Control).visible = String(cached_id) == _current_page


func _build_page(page_id: String, page: VBoxContainer, rows: Array) -> void:
	match page_id:
		"overview":
			_build_overview_page(page)
		"traits":
			_build_trait_page(page, rows)
		"preferences":
			_build_preference_page(page, rows)
		"effects":
			_build_effect_page(page, rows)
		"people":
			_build_people_page(page, rows)
		"branches":
			_build_branch_page(page, rows)


# ── 总览页（对齐 EconomyDossier 总览与 CohortDossier 账本分栏风格） ──────────

func _build_overview_page(page: VBoxContainer) -> void:
	var overview: Dictionary = _model.get("pages", {}).get("overview", {})
	var top_grid := FamilyGridScene.instantiate() as GridContainer
	top_grid.name = "OverviewTopGrid"
	top_grid.columns = 2
	top_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_grid.add_theme_constant_override("h_separation", 20)
	top_grid.add_theme_constant_override("v_separation", 14)
	page.add_child(top_grid)

	_add_overview_branches_card(top_grid, overview.get("branches", []))
	_add_overview_preferences_card(top_grid, overview.get("preferences", []))

	var mid_grid := FamilyGridScene.instantiate() as GridContainer
	mid_grid.name = "OverviewMidGrid"
	mid_grid.columns = 2
	mid_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid_grid.add_theme_constant_override("h_separation", 20)
	mid_grid.add_theme_constant_override("v_separation", 14)
	page.add_child(mid_grid)

	_add_overview_list_card(mid_grid, "traits", "家风与家族特性",
		overview.get("traits", []), false)
	_add_overview_list_card(mid_grid, "effects", "生效地域加成",
		overview.get("effects", []), true)

	_add_overview_people_card(page, overview.get("people", []))


func _add_overview_branches_card(host: Control, branches: Array) -> void:
	var card := _new_card()
	card.name = "OverviewBranches"
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.add_child(card)
	var body := _card_body(card)
	_add_overview_heading(body, "branches", "据点威望与三维份额")

	var ring_grid := FamilyGridScene.instantiate() as GridContainer
	ring_grid.name = "OverviewRingGrid"
	ring_grid.columns = 4
	ring_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ring_grid.add_theme_constant_override("h_separation", 4)
	ring_grid.add_theme_constant_override("v_separation", 2)
	body.add_child(ring_grid)
	for i in range(4):
		var ring := DossierRingGauge.new()
		ring.name = "Ring%d" % i
		ring.custom_minimum_size = Vector2(64.0, 86.0)
		ring.pressed.connect(func(_id: int) -> void: _select_page("branches", true))
		ring_grid.add_child(ring)
	_refresh_overview_rings(ring_grid, branches)

	var meter_list := MeterListScene.instantiate() as InspectorMeterList
	meter_list.name = "OverviewBranchMeters"
	meter_list.set_meters(_build_overview_branch_meters(branches))
	body.add_child(meter_list)

	var meta_label := FamilyLabelScene.instantiate() as Label
	meta_label.name = "BranchMetaLabel"
	meta_label.text = _overview_branch_meta_text(branches)
	meta_label.theme_type_variation = &"PKDossierCaption"
	meta_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	body.add_child(meta_label)


func _refresh_overview_rings(ring_grid: Control, branches: Array) -> void:
	if ring_grid == null:
		return
	var specs := _build_overview_Branch_ring_specs(branches)
	var children := ring_grid.get_children()
	for i in range(mini(children.size(), specs.size())):
		var ring := children[i] as DossierRingGauge
		if ring == null:
			continue
		var spec: Dictionary = specs[i]
		ring.set_gauge(
			i,
			String(spec.label),
			float(spec.ratio),
			String(spec.sub),
			spec.color as Color,
			String(spec.tooltip)
		)


func _build_overview_Branch_ring_specs(branches: Array) -> Array:
	var header: Dictionary = _model.get("header", {})
	var all_branches: Array = branches if not branches.is_empty() \
		else (_model.get("pages", {}).get("branches", []) as Array)
	if not all_branches.is_empty():
		var primary: Dictionary = all_branches[0]
		var score_pct := float(primary.get("prestige_percent",
			float(int(primary.get("prestige_score_q16", 0))) * 100.0 / 65536.0))
		var pop_pct := float(int(primary.get("population_share_q16", 0))) * 100.0 / 65536.0
		if pop_pct <= 0.0 and primary.has("population_share_text"):
			pop_pct = float(String(primary.get("population_share_text", "0")).trim_suffix("%"))
		var cash_pct := float(int(primary.get("cash_share_q16", 0))) * 100.0 / 65536.0
		if cash_pct <= 0.0 and primary.has("cash_share_text"):
			cash_pct = float(String(primary.get("cash_share_text", "0")).trim_suffix("%"))
		var bld_pct := float(int(primary.get("building_share_q16", 0))) * 100.0 / 65536.0
		if bld_pct <= 0.0 and primary.has("building_share_text"):
			bld_pct = float(String(primary.get("building_share_text", "0")).trim_suffix("%"))
		return [
			{"label": "主支威望", "ratio": clampf(score_pct / 100.0, 0.0, 1.0),
				"sub": "威望 %s" % String(primary.get("prestige_label", "0")),
				"color": UITokens.DOSSIER_OXBLOOD,
				"tooltip": "主分支威望综合得分 %.1f%%（等级 %s）" % [score_pct, String(primary.get("prestige_label", "0"))]},
			{"label": "人口份额", "ratio": clampf(pop_pct / 100.0, 0.0, 1.0),
				"sub": String(primary.get("population_share_text", "%.0f%%" % pop_pct)),
				"color": UITokens.DOSSIER_VERDIGRIS,
				"tooltip": "家族族人在据点总人口中的占比"},
			{"label": "资金份额", "ratio": clampf(cash_pct / 100.0, 0.0, 1.0),
				"sub": String(primary.get("cash_share_text", "%.0f%%" % cash_pct)),
				"color": UITokens.DOSSIER_BRASS,
				"tooltip": "家族现金在据点居民总资金中的占比"},
			{"label": "产业份额", "ratio": clampf(bld_pct / 100.0, 0.0, 1.0),
				"sub": String(primary.get("building_share_text", "%.0f%%" % bld_pct)),
				"color": UITokens.DOSSIER_SLATE,
				"tooltip": "家族控股建筑在据点总产业中的占比"},
		]
	var prestige_pct := float(header.get("prestige_percent", 0.0))
	if prestige_pct <= 0.0:
		prestige_pct = float(String(header.get("prestige_progress_text", "0")).trim_suffix("%"))
	var p_label := String(header.get("prestige_label", "0"))
	return [
		{"label": "家族威望", "ratio": clampf(prestige_pct / 100.0, 0.0, 1.0),
			"sub": "等级 %s" % p_label, "color": UITokens.DOSSIER_OXBLOOD,
			"tooltip": "当前家族威望得分 %.1f%%" % prestige_pct},
		{"label": "人口份额", "ratio": clampf(prestige_pct * 0.85 / 100.0, 0.0, 1.0),
			"sub": "核心支脉", "color": UITokens.DOSSIER_VERDIGRIS,
			"tooltip": "家族在所在区域的族人规模占比"},
		{"label": "资金份额", "ratio": clampf(prestige_pct * 0.92 / 100.0, 0.0, 1.0),
			"sub": "家族财力", "color": UITokens.DOSSIER_BRASS,
			"tooltip": "家族在所在区域的流动资金占比"},
		{"label": "产业份额", "ratio": clampf(prestige_pct * 0.95 / 100.0, 0.0, 1.0),
			"sub": "控股实业", "color": UITokens.DOSSIER_SLATE,
			"tooltip": "家族在所在区域的控股建筑占比"},
	]


func _build_overview_branch_meters(branches: Array) -> Array:
	var header: Dictionary = _model.get("header", {})
	var all_branches: Array = branches if not branches.is_empty() \
		else (_model.get("pages", {}).get("branches", []) as Array)
	if not all_branches.is_empty():
		var primary: Dictionary = all_branches[0]
		var score_pct := float(primary.get("prestige_percent",
			float(int(primary.get("prestige_score_q16", 0))) * 100.0 / 65536.0))
		var sat_pct := float(primary.get("satisfaction_percent", 85.0))
		if sat_pct <= 0.0:
			sat_pct = 85.0
		return [
			{"id": "ov_br_score", "label": "威望总分",
				"value": clampf(score_pct / 100.0, 0.0, 1.0),
				"value_text": String(primary.get("prestige_text", "%.1f%%" % score_pct)),
				"status_label": "目标 %s（%d/2）" % [
					String(primary.get("target_label", "0")),
					int(primary.get("review_streak", 0))],
				"accent": UITokens.WARN},
			{"id": "ov_br_sat", "label": "分支生计",
				"value": clampf(sat_pct / 100.0, 0.0, 1.0),
				"value_text": "%.1f%%" % sat_pct,
				"status_label": "族人综合满足",
				"accent": UITokens.ECO},
		]
	var prestige_pct := float(header.get("prestige_percent", 0.0))
	if prestige_pct <= 0.0:
		prestige_pct = float(String(header.get("prestige_progress_text", "0")).trim_suffix("%"))
	return [
		{"id": "ov_fam_prestige", "label": "威望总分",
			"value": clampf(prestige_pct / 100.0, 0.0, 1.0),
			"value_text": String(header.get("prestige_progress_text", "%.1f%%" % prestige_pct)),
			"status_label": "威望 %s" % String(header.get("prestige_label", "0")),
			"accent": UITokens.WARN},
		{"id": "ov_fam_tier_progress", "label": "晋级阈值",
			"value": clampf(prestige_pct / 100.0, 0.0, 1.0),
			"marker": 0.25,
			"value_text": "五档阶梯评定",
			"accent": UITokens.ECO},
	]


func _overview_branch_meta_text(branches: Array) -> String:
	var all_branches: Array = branches if not branches.is_empty() \
		else (_model.get("pages", {}).get("branches", []) as Array)
	if all_branches.is_empty():
		var header: Dictionary = _model.get("header", {})
		return "当前威望等级 %s（得分 %s）· 提升人口/资金/产业份额可晋级" % [
			String(header.get("prestige_label", "0")),
			String(header.get("prestige_progress_text", "0%"))]
	var primary: Dictionary = all_branches[0]
	var loc := String(primary.get("location_label", "地块 %d" % int(primary.get("cell", -1))))
	return "核心据点：%s · 晋级目标 %s（复核 %d/2）· 共 %d 处分支" % [
		loc, String(primary.get("target_label", "0")),
		int(primary.get("review_streak", 0)), all_branches.size()]


func _add_overview_preferences_card(host: Control, items: Array) -> void:
	var card := _new_card()
	card.name = "OverviewPreferences"
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.add_child(card)
	var body := _card_body(card)
	_add_overview_heading(body, "preferences", "显著行为偏好 · 100% 基准")
	if items.is_empty():
		_add_empty_label(body, "暂无显著行为偏好")
		return
	var bar_list := DossierBarList.new()
	bar_list.name = "OverviewPrefBars"
	bar_list.row_height = 34.0
	bar_list.label_width = 84.0
	bar_list.value_width = 92.0
	bar_list.selectable = true
	bar_list.set_rows(_build_preference_bar_rows(items))
	bar_list.row_selected.connect(func(_row_id: Variant) -> void:
		_select_page("preferences", true))
	body.add_child(bar_list)
	var foot := FamilyLabelScene.instantiate() as Label
	foot.name = "PrefScaleNote"
	foot.text = "中线为 100% 常规基线 · 铜绿为偏爱，暗红为抑制"
	foot.theme_type_variation = &"PKDossierCaption"
	body.add_child(foot)


func _build_preference_bar_rows(items: Array) -> Array:
	var out: Array = []
	for item_index in range(items.size()):
		var item: Dictionary = items[item_index]
		var factor_pct := float(item.get("factor_percent", 100.0))
		var signed_delta := factor_pct - 100.0
		var delta_str := "%s%.0f%%" % [
			"+" if signed_delta >= 0.0 else "−", absf(signed_delta)]
		var factor_str := String(item.get("factor_text",
			String(item.get("value", "%.1f%%" % factor_pct))))
		var readout := "%s (%s)" % [factor_str, delta_str] \
			if not factor_str.contains("(") else factor_str
		var color := UITokens.DOSSIER_VERDIGRIS if factor_pct >= 105.0 \
			else (UITokens.DOSSIER_OXBLOOD if factor_pct <= 95.0 else UITokens.DOSSIER_BRASS)
		var icon_key := _preference_icon_key(item)
		var axis_label := String(item.get("axis_name", "偏好"))
		out.append({
			"id": item.get("id", item_index),
			"label": String(item.get("name", "偏好")),
			"icon": icon_key,
			"value": clampf(factor_pct / 200.0, 0.0, 1.0),
			"marker": 0.5,
			"color": color,
			"text": readout,
			"text_color": color if absf(signed_delta) >= 5.0 else UITokens.DOSSIER_INK,
			"tooltip": "%s · %s偏好\n当前权重 %s（相对 100%% 基准 %s）" % [
				String(item.get("name", "偏好")), axis_label, factor_str, delta_str],
		})
	return out


func _preference_icon_key(item: Dictionary) -> StringName:
	var existing := String(item.get("icon", ""))
	if not existing.is_empty():
		return StringName(existing)
	var axis := int(item.get("axis", 0))
	var stable_id := String(item.get("stable_id", ""))
	if stable_id.is_empty() and String(item.get("id", "")).contains(":"):
		stable_id = String(item.get("id", "")).get_slice(":", 1)
	return CellInspectorViewModel._family_behavior_icon(
		axis, stable_id, String(item.get("name", "")))


func _add_overview_list_card(host: Control, page_id: String, title_text: String,
		items: Array, two_columns: bool = false) -> void:
	var card := _new_card()
	card.name = "Overview%s" % page_id.capitalize()
	host.add_child(card)
	var body := _card_body(card)
	_add_overview_heading(body, page_id, title_text)
	var item_host: Control = body
	if two_columns:
		var grid := FamilyGridScene.instantiate() as GridContainer
		grid.name = "Overview%sGrid" % page_id.capitalize()
		grid.columns = 1
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 6)
		body.add_child(grid)
		item_host = grid
	if items.is_empty():
		_add_empty_label(item_host, "暂无记录")
	for item_index in range(items.size()):
		var item_value: Variant = items[item_index]
		var item: Dictionary = item_value
		_add_overview_list_item(item_host, page_id, item, item_index)


func _add_overview_list_item(host: Control, page_id: String,
		item: Dictionary, item_index: int) -> void:
	var row := FamilyHBoxScene.instantiate() as HBoxContainer
	row.name = "Item%d" % item_index
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	host.add_child(row)
	var icon := FamilyTextureScene.instantiate() as TextureRect
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(20.0, 20.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var content := FamilyVBoxScene.instantiate() as VBoxContainer
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 2)
	row.add_child(content)
	var title_row := FamilyHBoxScene.instantiate() as HBoxContainer
	title_row.add_theme_constant_override("separation", 6)
	content.add_child(title_row)
	var name_label := FamilyLabelScene.instantiate() as Label
	name_label.name = "Name"
	name_label.text = String(item.get("name", item.get("title", "记录")))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.theme_type_variation = &"FamilyStrongLabel"
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.tooltip_text = name_label.text
	title_row.add_child(name_label)
	if page_id == "traits":
		_append_trait_badges(title_row, item)
	var value_label := FamilyLabelScene.instantiate() as Label
	value_label.name = "Value"
	value_label.text = _overview_item_value_text(page_id, item)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.tooltip_text = value_label.text
	value_label.theme_type_variation = &"FamilyMutedLabel"
	value_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	title_row.add_child(value_label)
	if page_id == "traits" or page_id == "effects":
		var detail_text := _overview_item_detail_text(page_id, item)
		if not detail_text.is_empty():
			var detail := FamilyLabelScene.instantiate() as Label
			detail.name = "Detail"
			detail.text = detail_text
			detail.tooltip_text = detail_text
			detail.theme_type_variation = &"FamilyMutedLabel"
			detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			content.add_child(detail)


func _overview_item_value_text(page_id: String, item: Dictionary) -> String:
	var val := String(item.get("value", "")).strip_edges()
	if page_id == "effects":
		if val.begins_with("当前未达威望"):
			return "未达威望Ⅰ"
		if val.length() > 14:
			var p_lvl := int(item.get("prestige_level", 0))
			return "威望 %s 生效" % CellInspectorViewModel._prestige_text(p_lvl) \
				if p_lvl > 0 else "生效中"
	return val


func _overview_item_detail_text(page_id: String, item: Dictionary) -> String:
	var detail := String(item.get("detail", item.get("effect_summary", ""))).strip_edges()
	if page_id == "effects":
		if detail.is_empty():
			detail = String(item.get("value", "")).strip_edges()
		if detail.begins_with("当前未达威望"):
			var tiers: Array = item.get("tier_statements", [])
			if not tiers.is_empty() and not String(tiers[0]).is_empty():
				return "未达威望Ⅰ · 解锁预览：%s" % String(tiers[0])
			return "当前未达威望Ⅰ · 提升本地威望至Ⅰ级后激活此项地域加成"
	elif page_id == "traits" and detail.is_empty():
		return "家族世代传承的核心门风倾向"
	return detail


func _append_trait_badges(host: HBoxContainer, item: Dictionary) -> void:
	var badges: Array = item.get("badges", [])
	if badges.is_empty():
		badges = FamilyBuffCopy.extract_trait_badges(String(item.get("detail", "")))
	for i in range(mini(2, badges.size())):
		var badge_data: Dictionary = badges[i]
		var pill := FamilyLabelScene.instantiate() as Label
		pill.text = String(badge_data.get("text", ""))
		pill.theme_type_variation = &"FamilyTraitBadgePos" \
			if bool(badge_data.get("positive", true)) else &"FamilyTraitBadgeNeg"
		host.add_child(pill)


func _add_overview_people_card(host: Control, items: Array) -> void:
	var card := _new_card()
	card.name = "OverviewPeople"
	host.add_child(card)
	var body := _card_body(card)
	_add_overview_heading(body, "people", "主要人物 · 资产、执掌产业与周期收支")
	var people_grid := FamilyGridScene.instantiate() as GridContainer
	people_grid.name = "OverviewPeopleGrid"
	people_grid.columns = _overview_people_columns(items.size(), size.x)
	people_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	people_grid.add_theme_constant_override("h_separation", 8)
	people_grid.add_theme_constant_override("v_separation", 6)
	body.add_child(people_grid)
	if items.is_empty():
		_add_empty_label(people_grid, "尚无可记录的重要人物")
	for item_index in range(items.size()):
		var item_value: Variant = items[item_index]
		var item: Dictionary = item_value
		var strip_card := FamilyCardScene.instantiate() as PanelContainer
		strip_card.name = "Person%d" % item_index
		strip_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		strip_card.theme_type_variation = &"FamilyTierLocked"
		people_grid.add_child(strip_card)
		var strip_body := _card_body(strip_card)
		var row := FamilyHBoxScene.instantiate() as HBoxContainer
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 8)
		strip_body.add_child(row)
		var portrait := FamilyTextureScene.instantiate() as TextureRect
		portrait.name = "Portrait"
		portrait.custom_minimum_size = Vector2(40.0, 46.0)
		portrait.texture = IconCatalog.texture_for_key(&"family.workspace.person")
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(portrait)
		var info_box := FamilyVBoxScene.instantiate() as VBoxContainer
		info_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_box.alignment = BoxContainer.ALIGNMENT_CENTER
		info_box.add_theme_constant_override("separation", 1)
		row.add_child(info_box)
		var name_label := FamilyLabelScene.instantiate() as Label
		name_label.name = "Name"
		name_label.text = String(item.get("name", "未命名人物"))
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.theme_type_variation = &"FamilyStrongLabel"
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info_box.add_child(name_label)
		var role_label := FamilyLabelScene.instantiate() as Label
		role_label.name = "Role"
		role_label.text = String(item.get("value", item.get("role", "家族成员")))
		role_label.theme_type_variation = &"FamilyMutedLabel"
		role_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info_box.add_child(role_label)
		var metrics_label := FamilyLabelScene.instantiate() as Label
		metrics_label.name = "PersonMetrics"
		metrics_label.text = _person_overview_metrics_text(item)
		metrics_label.theme_type_variation = &"FamilyMutedLabel"
		metrics_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
		metrics_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info_box.add_child(metrics_label)


func _people_ledger_columns() -> Array:
	return [
		{"id": "name", "label": "姓名", "min_width": 96.0, "expand": true, "kind": "text", "sortable": true},
		{"id": "role", "label": "职务 / 身份", "width": 116.0, "kind": "text", "sortable": true},
		{"id": "building", "label": "执掌产业", "width": 98.0, "kind": "text", "optional": true, "sortable": true},
		{"id": "worth", "label": "个人净资产", "width": 86.0, "kind": "number", "align": "right", "sortable": true},
		{"id": "flow", "label": "周期净收支", "width": 84.0, "kind": "number", "align": "right", "sortable": true},
		{"id": "sat", "label": "满足度", "width": 88.0, "kind": "bar", "optional": true, "sortable": true},
	]


func _people_ledger_rows(items: Array) -> Array:
	var rows: Array = []
	for index in range(items.size()):
		var person: Dictionary = items[index]
		var role_str := String(person.get("role", ""))
		var prof_str := String(person.get("profession", ""))
		if role_str.is_empty():
			role_str = String(person.get("value", "家族成员"))
		elif not prof_str.is_empty() and not role_str.contains(prof_str):
			role_str = "%s · %s" % [prof_str, role_str]
		var bld := String(person.get("building", "")).strip_edges()
		if bld.is_empty():
			bld = "家族本宅"
		var worth_str := String(person.get("net_worth_text", "—"))
		var worth_val := float(person.get("net_worth_val",
			CellInspectorViewModel._parse_leading_float(worth_str, float(items.size() - index))))
		var flow_str := String(person.get("net_cashflow_text", "稳健"))
		var flow_val := float(person.get("net_cashflow_val",
			CellInspectorViewModel._parse_leading_float(flow_str, 0.0)))
		var sat_pct := float(person.get("satisfaction_percent", 88.0))
		var sat_str := String(person.get("satisfaction_text", "%.0f%%" % sat_pct))
		rows.append({
			"id": person.get("id", "person_%d" % index),
			"tooltip": "%s（%s）\n执掌产业：%s" % [
				String(person.get("name", "成员")), role_str, bld],
			"cells": {
				"name": {"text": String(person.get("name", "未命名人物")),
					"icon": StringName(person.get("profession_icon", "population.profession.owner"))},
				"role": {"text": role_str},
				"building": {"text": bld},
				"worth": {"text": worth_str, "sort": worth_val},
				"flow": {"text": flow_str, "sort": flow_val,
					"color": UITokens.DOSSIER_OXBLOOD if flow_str.begins_with("−") else UITokens.DOSSIER_VERDIGRIS},
				"sat": {"text": sat_str, "value": clampf(sat_pct / 100.0, 0.0, 1.0),
					"sort": sat_pct, "color": UITokens.DOSSIER_VERDIGRIS},
			},
		})
	return rows


func _overview_people_columns(person_count: int, available_width: float) -> int:
	if person_count <= 1 or available_width < 480.0:
		return 1
	if person_count == 2 or available_width < 720.0:
		return 2
	return mini(3, person_count)


func _person_overview_metrics_text(person: Dictionary) -> String:
	var parts: Array[String] = []
	var building := String(person.get("building", "")).strip_edges()
	if not building.is_empty():
		parts.append("产业：%s" % building)
	var net_worth := String(person.get("net_worth_text", "")).strip_edges()
	if not net_worth.is_empty():
		parts.append("净资产 %s" % net_worth)
	var flow := String(person.get("net_cashflow_text", "")).strip_edges()
	if not flow.is_empty():
		parts.append("日收支 %s" % flow)
	var sat := String(person.get("satisfaction_text", "")).strip_edges()
	if not sat.is_empty():
		parts.append("满足度 %s" % sat)
	if parts.is_empty():
		return "家族核心成员 · 点击查阅完整资产与收支卷宗"
	return " · ".join(parts)


func _add_overview_heading(host: VBoxContainer, page_id: String,
		title_text: String) -> void:
	var header_row := FamilyHBoxScene.instantiate() as HBoxContainer
	header_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.add_child(header_row)
	var kicker := FamilyLabelScene.instantiate() as Label
	kicker.text = title_text
	kicker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kicker.theme_type_variation = &"PKDossierKicker"
	header_row.add_child(kicker)
	var heading := FamilyButtonScene.instantiate() as Button
	heading.name = "Heading"
	heading.flat = true
	heading.focus_mode = Control.FOCUS_NONE
	heading.text = "%s ›" % String(PAGE_META[page_id].title)
	heading.theme_type_variation = &"PKDossierLink"
	heading.pressed.connect(_select_page.bind(page_id, true))
	header_row.add_child(heading)


func _overview_item_text(item: Dictionary) -> String:
	var value := String(item.get("value", ""))
	return "• %s%s" % [String(item.get("name", item.get("title", "记录"))),
		("  " + value) if not value.is_empty() else ""]


# ── 五个专项子页（对齐 Dossier 账本规范） ─────────────────────────────────

func _build_trait_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "这个家族尚未形成可记录的特性。")
		return
	var notes := NoteListScene.instantiate() as InspectorNoteList
	notes.set_notes([{
		"id": "trait_intro",
		"text": "当前共记录 %d 项家族特性。核心特性奠定立族门风，附加特性随家族经营演进。" % rows.size(),
		"accent": UITokens.WARN,
	}])
	page.add_child(notes)
	for raw in rows:
		var row: Dictionary = raw
		var card := _new_card()
		page.add_child(card)
		var body := _card_body(card)
		var header_row := _add_title_value_row(body, String(row.get("name", "特性")),
			String(row.get("kind_label", row.get("value", "附加特性"))))
		_append_trait_badges(header_row, row)
		var detail := String(row.get("detail", "暂无说明"))
		_add_wrapped_label(body, detail, true)
		var effect_summary := String(row.get("effect_summary", ""))
		if not effect_summary.strip_edges().is_empty() and \
				_family_display_key(effect_summary) != _family_display_key(detail):
			_add_wrapped_label(body, effect_summary, false)


func _build_preference_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "当前没有可见的家族行为偏好。")
		return
	var current_axis := ""
	for raw in rows:
		var row: Dictionary = raw
		var axis_name := String(row.get("axis_name", "行为"))
		if axis_name != current_axis:
			current_axis = axis_name
			_add_section_label(page, "%s偏好 · 竖线为 100%% 常规基准" % axis_name)
		var card := _new_card()
		page.add_child(card)
		var body := _card_body(card)
		var top_row := FamilyHBoxScene.instantiate() as HBoxContainer
		top_row.add_theme_constant_override("separation", 8)
		body.add_child(top_row)
		var badge := IconBadgeScene.instantiate() as IconBadge
		badge.custom_minimum_size = Vector2(22.0, 22.0)
		var factor_pct := float(row.get("factor_percent", 100.0))
		var accent := UITokens.GOOD if factor_pct >= 105.0 \
			else (UITokens.RISK if factor_pct <= 95.0 else UITokens.WARN)
		badge.set_semantic(_preference_icon_key(row), accent)
		top_row.add_child(badge)
		var title_label := FamilyLabelScene.instantiate() as Label
		title_label.text = String(row.get("name", "偏好"))
		title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title_label.theme_type_variation = &"FamilyStrongLabel"
		title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		top_row.add_child(title_label)
		var value_label := FamilyLabelScene.instantiate() as Label
		value_label.text = String(row.get("factor_text", row.get("value", "100%")))
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.size_flags_horizontal = Control.SIZE_SHRINK_END
		value_label.theme_type_variation = &"PKDossierValue"
		value_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
		top_row.add_child(value_label)
		var meter := MeterListScene.instantiate() as InspectorMeterList
		meter.name = "PrefMeter"
		meter.set_meters([_preference_meter_dict(row)])
		body.add_child(meter)


func _preference_meter_dict(row: Dictionary) -> Dictionary:
	var factor_pct := float(row.get("factor_percent", 100.0))
	var signed_delta := factor_pct - 100.0
	var delta_text := "%s%.0f%%" % [
		"+" if signed_delta >= 0.0 else "−", absf(signed_delta)]
	var accent := UITokens.GOOD if factor_pct >= 105.0 \
		else (UITokens.RISK if factor_pct <= 95.0 else UITokens.WARN)
	return {
		"id": String(row.get("id", row.get("name", "pref"))),
		"label": String(row.get("axis_name", "权重")),
		"value": clampf(factor_pct / 200.0, 0.0, 1.0),
		"marker": 0.5,
		"value_text": "基线 100%",
		"status_label": "偏离 %s" % delta_text,
		"accent": accent,
	}


func _build_effect_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "当前没有家族分支效果。")
		return
	var current_cell := -999999
	for raw in rows:
		var row: Dictionary = raw
		var cell := int(row.get("cell", -1))
		if cell != current_cell:
			current_cell = cell
			var settlement := String(row.get("settlement_name", "")).strip_edges()
			var section_title := ("%s（地块 %d）" % [settlement, cell] \
				if not settlement.is_empty() else "地块 %d" % cell) \
				if cell >= 0 else "家族整体"
			_add_section_label(page, section_title)
		var card := _new_card()
		page.add_child(card)
		var body := _card_body(card)
		var p_level := int(row.get("prestige_level", 0))
		var status_text := String(row.get("value", ""))
		if String(row.get("kind", "")) == "effect":
			status_text = "当前威望 %s" % CellInspectorViewModel._prestige_text(p_level)
		_add_title_value(body, String(row.get("title", row.get("name", "效果"))), status_text)
		_add_wrapped_label(body, String(row.get("detail", "")), true)
		var tiers: Array = row.get("tier_statements", [])
		if not tiers.is_empty():
			var ladder := FamilyVBoxScene.instantiate() as VBoxContainer
			ladder.name = "TierLadder"
			ladder.add_theme_constant_override("separation", 4)
			body.add_child(ladder)
			for tier_idx in range(tiers.size()):
				var tier_panel := FamilyCardScene.instantiate() as PanelContainer
				var is_active_tier := (tier_idx + 1) == p_level
				tier_panel.theme_type_variation = &"FamilyTierActive" \
					if is_active_tier else &"FamilyTierLocked"
				ladder.add_child(tier_panel)
				var tier_body := _card_body(tier_panel)
				var tier_label := FamilyLabelScene.instantiate() as Label
				var prefix := "【当前生效】" if is_active_tier \
					else ("【已达成】" if (tier_idx + 1) < p_level else "【待解锁】")
				tier_label.text = "%s %s" % [prefix, String(tiers[tier_idx])]
				tier_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				tier_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				tier_label.theme_type_variation = &"FamilyStrongLabel" \
					if is_active_tier else &"FamilyMutedLabel"
				tier_body.add_child(tier_label)
		if String(row.get("kind", "")) == "trigger":
			var trigger_meter := MeterListScene.instantiate() as InspectorMeterList
			trigger_meter.name = "TriggerMeter"
			trigger_meter.set_meters([{
				"id": String(row.get("id", "trigger")),
				"label": "触发进度",
				"value": clampf(float(row.get("progress_ratio", 0.0)), 0.0, 1.0),
				"value_text": "%d / %d" % [int(row.get("progress", 0)), int(row.get("threshold", 1))],
				"status_label": "已触发 %d 次" % int(row.get("completed", 0)),
				"accent": UITokens.WARN,
			}])
			body.add_child(trigger_meter)


func _build_people_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "尚无可记录的重要人物。")
		return
	var table := DossierLedgerTable.new()
	table.name = "PeoplePageLedger"
	table.row_height = 28.0
	table.set_columns(_people_ledger_columns(), "worth", true)
	table.set_rows(_people_ledger_rows(rows))
	page.add_child(table)
	var grid := FamilyGridScene.instantiate() as GridContainer
	grid.name = "PeoplePageGrid"
	grid.columns = 2 if size.x >= 680.0 else 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 12)
	page.add_child(grid)
	for raw in rows:
		var row: Dictionary = raw
		var card := _new_card()
		grid.add_child(card)
		var card_body := _card_body(card)
		var horizontal := FamilyHBoxScene.instantiate() as HBoxContainer
		horizontal.add_theme_constant_override("separation", 10)
		card_body.add_child(horizontal)
		var portrait := FamilyTextureScene.instantiate() as TextureRect
		portrait.name = "Portrait"
		portrait.custom_minimum_size = Vector2(48.0, 56.0)
		portrait.texture = IconCatalog.texture_for_key(&"family.workspace.person")
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		horizontal.add_child(portrait)
		var text_box := FamilyVBoxScene.instantiate() as VBoxContainer
		text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_box.add_theme_constant_override("separation", 2)
		horizontal.add_child(text_box)
		_add_title_value(text_box, String(row.get("name", "未命名人物")),
			String(row.get("role", "家族成员")))
		_add_wrapped_label(text_box, String(row.get("profession", "身份未详")), true)
		var building := String(row.get("building", ""))
		_add_wrapped_label(text_box,
			"所属产业：%s" % building if not building.is_empty() else "所属产业：无", true)
		var facts := FactGridScene.instantiate() as InspectorFactGrid
		facts.name = "PersonFacts"
		facts.set_facts(_person_fact_cells(row))
		card_body.add_child(facts)
		var cashflow_bar := DossierDivergingBar.new()
		cashflow_bar.name = "PersonCashflowBar"
		_update_person_cashflow_bar(cashflow_bar, row)
		card_body.add_child(cashflow_bar)


func _person_fact_cells(row: Dictionary) -> Array:
	var person_id := String(row.get("id", row.get("name", "person")))
	var net_worth := String(row.get("net_worth_text", ""))
	if net_worth.is_empty():
		var role_str := String(row.get("role", "家族成员"))
		var prof_str := String(row.get("profession", "家族实业"))
		var bld_str := String(row.get("building", "家族本宅"))
		return [
			{"id": "%s_role" % person_id, "title": "家族职务", "value": role_str,
				"icon": "family.house", "accent": UITokens.RESOURCE},
			{"id": "%s_prof" % person_id, "title": "从业身份", "value": prof_str,
				"icon": "population.profession.owner", "accent": UITokens.WARN},
			{"id": "%s_bld" % person_id, "title": "执掌产业",
				"value": bld_str if not bld_str.is_empty() else "家族本宅",
				"icon": "economy.building", "accent": UITokens.GOOD},
			{"id": "%s_state" % person_id, "title": "履职状态", "value": "在职主理",
				"icon": "population.heart", "accent": UITokens.ECO},
		]
	var cash := String(row.get("cash_claim_text", ""))
	var equity := String(row.get("equity_share_text", "—"))
	var attr_asset := String(row.get("attributed_asset_text", ""))
	var net_flow := String(row.get("net_cashflow_text", "—"))
	var sat := String(row.get("satisfaction_text", "—"))
	return [
		{"id": "%s_worth" % person_id, "title": "个人净资产", "value": net_worth,
			"subtitle": "现金 %s" % cash if not cash.is_empty() else "",
			"icon": "metric.treasury", "accent": UITokens.RESOURCE},
		{"id": "%s_equity" % person_id, "title": "家族股权占比", "value": equity,
			"subtitle": "权益 %s" % attr_asset if not attr_asset.is_empty() else "",
			"icon": "economy.building", "accent": UITokens.WARN},
		{"id": "%s_flow" % person_id, "title": "周期净收支", "value": net_flow,
			"icon": "country.economy",
			"accent": UITokens.RISK if net_flow.begins_with("−") else UITokens.GOOD},
		{"id": "%s_sat" % person_id, "title": "需求满足度", "value": sat,
			"icon": "population.heart", "accent": UITokens.ECO},
	]


func _update_person_cashflow_bar(bar: DossierDivergingBar, row: Dictionary) -> void:
	var has_flow := row.has("income_val") or row.has("expense_val")
	var exp_val := float(row.get("expense_val", 0.35 if not has_flow else 0.0))
	var inc_val := float(row.get("income_val", 0.65 if not has_flow else 0.0))
	var exp_text := String(row.get("expense_text", "稳健支出" if not has_flow else "0"))
	var inc_text := String(row.get("income_text", "经营盈余" if not has_flow else "0"))
	bar.set_values("周期消费与税负", exp_val, exp_text, "周期薪资与分红", inc_val, inc_text)


func _build_branch_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "这个家族尚未建立分支。")
		return
	for raw in rows:
		var row: Dictionary = raw
		var card := _new_card()
		page.add_child(card)
		var body := _card_body(card)
		_add_title_value(body, "地块 %d" % int(row.get("cell", -1)),
			"威望 %s · %s" % [String(row.get("prestige_label", "0")),
			String(row.get("prestige_text", "0%"))])
		_add_wrapped_label(body, "人口 %s · 现金 %s · 建筑 %s" % [
			String(row.get("population_share_text", "0%")),
			String(row.get("cash_share_text", "0%")),
			String(row.get("building_share_text", "0%"))], true)
		_add_wrapped_label(body, "晋级目标 %s · 复核 %d/2" % [
			String(row.get("target_label", "0")), int(row.get("review_streak", 0))], true)
		var meters := MeterListScene.instantiate() as InspectorMeterList
		meters.name = "BranchMeters"
		meters.set_meters(_branch_meter_dicts(row))
		body.add_child(meters)
		var action := FamilyButtonScene.instantiate() as Button
		action.text = "进入地图选点"
		action.theme_type_variation = &"FamilyActionButton"
		action.disabled = not _colonization_available(int(row.get("cell", -1)))
		action.tooltip_text = "以此分支为来源进入地图选点"
		action.pressed.connect(func() -> void:
			colonization_requested.emit(_family_handle, int(row.get("cell", -1))))
		body.add_child(action)


func _branch_meter_dicts(row: Dictionary) -> Array:
	var cell := int(row.get("cell", -1))
	var score_pct := float(row.get("prestige_percent",
		float(int(row.get("prestige_score_q16", 0))) * 100.0 / 65536.0))
	var pop_pct := float(int(row.get("population_share_q16", 0))) * 100.0 / 65536.0
	var cash_pct := float(int(row.get("cash_share_q16", 0))) * 100.0 / 65536.0
	var bld_pct := float(int(row.get("building_share_q16", 0))) * 100.0 / 65536.0
	return [
		{"id": "br_%d_score" % cell, "label": "威望总分",
			"value": clampf(score_pct / 100.0, 0.0, 1.0),
			"value_text": String(row.get("prestige_text", "%.1f%%" % score_pct)),
			"status_label": "威望 %s" % String(row.get("prestige_label", "0")),
			"accent": UITokens.WARN},
		{"id": "br_%d_pop" % cell, "label": "人口份额",
			"value": clampf(pop_pct / 100.0, 0.0, 1.0),
			"value_text": String(row.get("population_share_text", "%.1f%%" % pop_pct)),
			"status_label": String(row.get("population_count_text", "")),
			"accent": UITokens.ECO},
		{"id": "br_%d_cash" % cell, "label": "资金份额",
			"value": clampf(cash_pct / 100.0, 0.0, 1.0),
			"value_text": String(row.get("cash_share_text", "%.1f%%" % cash_pct)),
			"status_label": String(row.get("cash_amount_text", "")),
			"accent": UITokens.RESOURCE},
		{"id": "br_%d_bld" % cell, "label": "产业份额",
			"value": clampf(bld_pct / 100.0, 0.0, 1.0),
			"value_text": String(row.get("building_share_text", "%.1f%%" % bld_pct)),
			"status_label": String(row.get("building_asset_text", "")),
			"accent": UITokens.WATER},
	]


# ── 实时刷新（保持节点树恒定与滚动位置不变） ────────────────────────────

func _refresh_page(page_id: String) -> void:
	var rows := _page_rows(page_id)
	var signature := _shape_signature(rows)
	if String(_page_signatures.get(page_id, "")) != signature:
		_ensure_page(page_id)
		return
	var page := _page_cache.get(page_id) as Control
	if page == null:
		return
	if page_id == "overview":
		_refresh_overview_page(page)
		return
	if page_id == "people":
		var people_ledger := page.find_child("PeoplePageLedger", true, false) as DossierLedgerTable
		if people_ledger != null:
			people_ledger.set_rows(_people_ledger_rows(rows))
	var row_index := 0
	for card in _find_cards(page):
		if row_index >= rows.size():
			break
		_apply_card_live(page_id, card, rows[row_index])
		row_index += 1


func _apply_card_live(page_id: String, card: PanelContainer, row_value: Variant) -> void:
	var row: Dictionary = row_value
	var labels := _find_labels(card)
	if labels.is_empty():
		return
	match page_id:
		"traits":
			labels[0].text = String(row.get("name", "特性"))
			if labels.size() > 1: labels[1].text = String(row.get("kind_label", row.get("value", "附加特性")))
			if labels.size() > 2: labels[2].text = String(row.get("detail", "暂无说明"))
			if labels.size() > 3: labels[3].text = String(row.get("effect_summary", ""))
		"preferences":
			labels[0].text = String(row.get("name", "偏好"))
			if labels.size() > 1: labels[1].text = String(row.get("factor_text", row.get("value", "100%")))
			var pref_meter := card.find_child("PrefMeter", true, false) as InspectorMeterList
			if pref_meter != null:
				pref_meter.set_meters([_preference_meter_dict(row)])
			var bars := _find_progress_bars(card)
			if not bars.is_empty(): bars[0].value = clampf(float(row.get("factor_percent", 100.0)), 0.0, 200.0)
		"effects":
			labels[0].text = String(row.get("title", row.get("name", "效果")))
			if labels.size() > 1: labels[1].text = String(row.get("value", ""))
			if labels.size() > 2: labels[2].text = String(row.get("detail", ""))
			var trig_meter := card.find_child("TriggerMeter", true, false) as InspectorMeterList
			if trig_meter != null:
				trig_meter.set_meters([{
					"id": String(row.get("id", "trigger")),
					"label": "触发进度",
					"value": clampf(float(row.get("progress_ratio", 0.0)), 0.0, 1.0),
					"value_text": "%d / %d" % [int(row.get("progress", 0)), int(row.get("threshold", 1))],
					"status_label": "已触发 %d 次" % int(row.get("completed", 0)),
					"accent": UITokens.WARN,
				}])
		"people":
			labels[0].text = String(row.get("name", "未命名人物"))
			if labels.size() > 1: labels[1].text = String(row.get("role", "家族成员"))
			if labels.size() > 2: labels[2].text = String(row.get("profession", "身份未详"))
			if labels.size() > 3:
				var building := String(row.get("building", ""))
				labels[3].text = "所属产业：%s" % building if not building.is_empty() else "所属产业：无"
			var person_facts := card.find_child("PersonFacts", true, false) as InspectorFactGrid
			if person_facts != null:
				person_facts.set_facts(_person_fact_cells(row))
			var cashflow_bar := card.find_child("PersonCashflowBar", true, false) as DossierDivergingBar
			if cashflow_bar != null:
				_update_person_cashflow_bar(cashflow_bar, row)
		"branches":
			labels[0].text = "地块 %d" % int(row.get("cell", -1))
			if labels.size() > 1: labels[1].text = "威望 %s · %s" % [String(row.get("prestige_label", "0")), String(row.get("prestige_text", "0%"))]
			if labels.size() > 2: labels[2].text = "人口 %s · 现金 %s · 建筑 %s" % [String(row.get("population_share_text", "0%")), String(row.get("cash_share_text", "0%")), String(row.get("building_share_text", "0%"))]
			if labels.size() > 3: labels[3].text = "晋级目标 %s · 复核 %d/2" % [String(row.get("target_label", "0")), int(row.get("review_streak", 0))]
			var branch_meters := card.find_child("BranchMeters", true, false) as InspectorMeterList
			if branch_meters != null:
				branch_meters.set_meters(_branch_meter_dicts(row))
			var buttons := _find_buttons(card)
			if not buttons.is_empty(): buttons[0].disabled = not _colonization_available(int(row.get("cell", -1)))


func _refresh_overview_page(page: Control) -> void:
	var overview: Dictionary = _model.get("pages", {}).get("overview", {})
	var pref_bars := page.find_child("OverviewPrefBars", true, false) as DossierBarList
	if pref_bars != null:
		pref_bars.set_rows(_build_preference_bar_rows(overview.get("preferences", [])))
	var ring_grid := page.find_child("OverviewRingGrid", true, false) as Control
	if ring_grid != null:
		_refresh_overview_rings(ring_grid, overview.get("branches", []))
	var branch_meters := page.find_child("OverviewBranchMeters", true, false) as InspectorMeterList
	if branch_meters != null:
		branch_meters.set_meters(_build_overview_branch_meters(overview.get("branches", [])))
	var branch_meta := page.find_child("BranchMetaLabel", true, false) as Label
	if branch_meta != null:
		branch_meta.text = _overview_branch_meta_text(overview.get("branches", []))
	for section_key in ["traits", "effects"]:
		var card := page.find_child("Overview%s" % section_key.capitalize(),
			true, false) as PanelContainer
		if card == null:
			continue
		var items: Array = overview.get(section_key, [])
		for item_index in range(items.size()):
			var item_root := card.find_child("Item%d" % item_index, true, false) as Control
			if item_root == null:
				continue
			var item: Dictionary = items[item_index]
			var name_label := item_root.find_child("Name", true, false) as Label
			var value_label := item_root.find_child("Value", true, false) as Label
			var detail_label := item_root.find_child("Detail", true, false) as Label
			if name_label != null:
				name_label.text = String(item.get("name", item.get("title", "记录")))
			if value_label != null:
				value_label.text = _overview_item_value_text(section_key, item)
			if detail_label != null:
				detail_label.text = _overview_item_detail_text(section_key, item)
	var people_card := page.find_child("OverviewPeople", true, false) as PanelContainer
	if people_card == null:
		return
	var people: Array = overview.get("people", [])
	var people_table := people_card.find_child("OverviewPeopleTable", true, false) as DossierLedgerTable
	if people_table != null:
		people_table.set_rows(_people_ledger_rows(people))
	for person_index in range(people.size()):
		var person_root := people_card.find_child("Person%d" % person_index,
			true, false) as Control
		if person_root == null:
			continue
		var person: Dictionary = people[person_index]
		var name_label := person_root.find_child("Name", true, false) as Label
		var role_label := person_root.find_child("Role", true, false) as Label
		var metrics_label := person_root.find_child("PersonMetrics", true, false) as Label
		if name_label != null:
			name_label.text = String(person.get("name", "未命名人物"))
		if role_label != null:
			role_label.text = String(person.get("value", person.get("role", "家族成员")))
		if metrics_label != null:
			metrics_label.text = _person_overview_metrics_text(person)


# ── 页头、DossierKpiCard 摘要条与导航状态同步 ───────────────────────────

func _update_header() -> void:
	var header: Dictionary = _model.get("header", {})
	_title.text = String(header.get("name", "家族档案"))
	_subtitle.text = String(header.get("subtitle", ""))
	_prestige_value.text = String(header.get("prestige_progress_text", "0%"))
	_prestige_caption.text = "威望 %s" % String(header.get("prestige_label", "0"))
	if _prestige_plate != null:
		_prestige_plate.tooltip_text = "家族威望 %s（当前综合得分 %s）\n由家族在分支地块的人口份额、资金份额与产业份额共同决定。" % [
			String(header.get("prestige_label", "0")),
			String(header.get("prestige_progress_text", "0%"))]


func _update_summary(live_patch: bool = false) -> void:
	var items: Array = _model.get("summary", [])
	var header: Dictionary = _model.get("header", {})
	var icon_map := {
		0: &"family.house",
		1: &"metric.treasury",
		2: &"economy.building",
		3: &"technology.milestone",
	}
	for index in range(_kpi_cards.size()):
		var card := _kpi_cards[index]
		var item: Dictionary = items[index] if index < items.size() else {}
		var title_str := String(item.get("label", ""))
		var value_str := String(item.get("value", "—"))
		var caption_str := String(item.get("caption", ""))
		var tone_str := ""
		if index == 3:
			var p_label := String(header.get("prestige_label", "0"))
			var p_prog := String(header.get("prestige_progress_text", "0%"))
			if caption_str.is_empty():
				caption_str = "威望 %s · 得分 %s" % [p_label, p_prog]
			if p_label != "0":
				tone_str = "warn"
		var sig := "%s|%s|%s|%s" % [title_str, value_str, caption_str, tone_str]
		var slot := "kpi_%d" % index
		if live_patch and String(_kpi_signatures.get(slot, "")) == sig:
			continue
		_kpi_signatures[slot] = sig
		card.set_metric({
			"id": String(item.get("id", slot)),
			"title": title_str,
			"kind": "text",
			"text": value_str,
			"value": CellInspectorViewModel._parse_leading_float(value_str, 0.0),
			"caption": caption_str,
			"tone": tone_str,
			"icon": icon_map.get(index, &"summary.overview"),
		})


func _update_nav_state() -> void:
	for page_id in PAGE_ORDER:
		var active := page_id == _current_page
		if _nav_buttons.has(page_id):
			(_nav_buttons[page_id] as Button).set_pressed_no_signal(active)
		if _nav_labels.has(page_id):
			var nav_label := _nav_labels[page_id] as Label
			nav_label.add_theme_color_override("font_color",
				Color("#fff0c8") if active else Color("#3a2414"))
			nav_label.add_theme_color_override("font_outline_color",
				Color(0.18, 0.06, 0.03, 0.55) if active \
				else Color(1.0, 0.93, 0.76, 0.0))
			nav_label.add_theme_constant_override("outline_size", 2 if active else 1)
		if _nav_icons.has(page_id):
			var nav_icon := _nav_icons[page_id] as TextureRect
			nav_icon.modulate = Color(1.08, 1.05, 0.98, 1.0) if active else Color.WHITE
		if _mobile_buttons.has(page_id):
			(_mobile_buttons[page_id] as Button).set_pressed_no_signal(active)
	if _chapter_nav != null and _chapter_nav.current != _current_page:
		_chapter_nav.select(_current_page, true)
	if PAGE_META.has(_current_page):
		_page_title.text = String(PAGE_META[_current_page].title)
		_page_icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[_current_page].icon))


# ── 响应式布局（对齐 CountryPanel 书脊 + 合页 + 9-slice 书页结构） ─────────

func _apply_responsive_layout() -> void:
	if _nav_column == null or _safe_margin == null:
		return
	var full_width_book := _uses_full_width_book_layout()
	var compact := (full_width_book and size.x < COMPACT_WIDTH) or size.x < 620.0
	var rail_width := RAIL_WIDTH
	var left_pad := 18.0
	var right_pad := 28.0 if not compact else 20.0
	var top_pad := 20.0 if not compact else 14.0
	var bottom_pad := 22.0 if not compact else 16.0
	var main_sep := 28.0 if not compact else 8.0
	var nav_col_width := rail_width - left_pad

	if _nav_rail_surface != null:
		_nav_rail_surface.visible = not compact
		_nav_rail_surface.position = Vector2.ZERO
		_nav_rail_surface.size = Vector2(rail_width, size.y)
	if _page_surface != null:
		var page_x := 0.0 if compact else rail_width
		_page_surface.position = Vector2(page_x, 0.0)
		_page_surface.size = Vector2(maxf(200.0, size.x - page_x), size.y)
	_place_hinges(rail_width, compact)

	_safe_margin.add_theme_constant_override("margin_left", roundi(left_pad))
	_safe_margin.add_theme_constant_override("margin_top", roundi(top_pad))
	_safe_margin.add_theme_constant_override("margin_right", roundi(right_pad))
	_safe_margin.add_theme_constant_override("margin_bottom", roundi(bottom_pad))
	_nav_column.custom_minimum_size.x = nav_col_width
	_nav_column.visible = not compact
	_mobile_nav.visible = compact
	if _chapter_nav != null:
		_chapter_nav.visible = false
	var main := $SafeMargin/Main as HBoxContainer
	main.add_theme_constant_override("separation", roundi(main_sep))

	var content_width := maxf(280.0, size.x - left_pad - right_pad \
		- (0.0 if compact else nav_col_width + main_sep))
	var dense_kpi := size.y > 1.0 and size.y < 520.0
	for card in _kpi_cards:
		card.dense = dense_kpi

	var overview := _page_cache.get("overview") as Control
	if overview != null:
		var top_grid := overview.find_child("OverviewTopGrid", true, false) as GridContainer
		if top_grid != null:
			top_grid.columns = 1 if content_width < 560.0 else 2
		var mid_grid := overview.find_child("OverviewMidGrid", true, false) as GridContainer
		if mid_grid != null:
			mid_grid.columns = 1 if content_width < 560.0 else 2
		var ring_grid := overview.find_child("OverviewRingGrid", true, false) as GridContainer
		if ring_grid != null:
			ring_grid.columns = 2 if content_width < 620.0 else 4
		var people_grid := overview.find_child("OverviewPeopleGrid", true, false) as GridContainer
		if people_grid != null:
			people_grid.columns = _overview_people_columns(
				people_grid.get_child_count(), content_width)
		var effects_grid := overview.find_child("OverviewEffectsGrid", true, false) as GridContainer
		if effects_grid != null:
			effects_grid.columns = 1 if (mid_grid != null and mid_grid.columns >= 2) \
				or content_width < 620.0 else 2
	var people_page := _page_cache.get("people") as Control
	if people_page != null:
		var people_page_grid := people_page.find_child("PeoplePageGrid", true, false) as GridContainer
		if people_page_grid != null:
			people_page_grid.columns = 1 if content_width < 620.0 else 2


func _place_hinges(seam_x: float, compact: bool) -> void:
	if _hinges == null:
		return
	_hinges.visible = not compact
	if compact:
		return
	var ratios := [0.18, 0.50, 0.82]
	var children := _hinges.get_children()
	for i in range(mini(children.size(), ratios.size())):
		var hinge := children[i] as Control
		hinge.position = Vector2(seam_x - hinge.size.x * 0.5,
			round(size.y * float(ratios[i]) - hinge.size.y * 0.5))


func _focus_current_navigation() -> void:
	if not visible:
		return
	var target: Button = (_mobile_buttons.get(_current_page) as Button) \
		if _mobile_nav.visible else (_nav_buttons.get(_current_page) as Button)
	if target != null:
		target.grab_focus()


func _uses_full_width_book_layout() -> bool:
	if _fullscreen_mode:
		return true
	var viewport_width := get_viewport_rect().size.x
	if viewport_width <= 0.0:
		return false
	return size.x >= viewport_width * 0.75


func _page_rows(page_id: String) -> Array:
	var pages: Dictionary = _model.get("pages", {})
	if page_id == "overview":
		var overview: Dictionary = pages.get("overview", {})
		var flat: Array = []
		for key in ["traits", "preferences", "effects", "people", "branches"]:
			flat.append_array(overview.get(key, []))
		return flat
	return pages.get(page_id, [])


func _shape_signature(rows: Array) -> String:
	var parts: Array[String] = [str(rows.size())]
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		parts.append("%s:%s:%s:%s" % [str(row.get("id", index)),
			str(row.get("kind", "")), str(row.get("cell", "")),
			str(not String(row.get("effect_summary", "")).strip_edges().is_empty())])
	return "|".join(parts)


func _clear_page_cache() -> void:
	if _page_host != null:
		for child in _page_host.get_children():
			_page_host.remove_child(child)
			child.queue_free()
	_page_cache.clear()
	_page_signatures.clear()


func _restore_page_scroll(page_id: String) -> void:
	if page_id == _current_page and _page_scroll != null:
		_page_scroll.scroll_vertical = int(_scroll_by_page.get(page_id, 0))


func _colonization_available(source_cell: int) -> bool:
	if source_cell < 0:
		return false
	if _player_controller == null:
		return true
	if _player_controller.has_method("can_family_colonize_from"):
		return bool(_player_controller.can_family_colonize_from(_family_handle, source_cell))
	return true


func _new_card() -> PanelContainer:
	var card := FamilyCardScene.instantiate() as PanelContainer
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.clip_contents = true
	return card


func _card_body(card: PanelContainer) -> VBoxContainer:
	return card.get_node("Body") as VBoxContainer


func _add_title_value(host: VBoxContainer, title_text: String, value_text: String) -> void:
	_add_title_value_row(host, title_text, value_text)


func _add_title_value_row(host: VBoxContainer, title_text: String, value_text: String) -> HBoxContainer:
	var row := FamilyHBoxScene.instantiate() as HBoxContainer
	row.add_theme_constant_override("separation", 8)
	host.add_child(row)
	var title_label := FamilyLabelScene.instantiate() as Label
	title_label.text = title_text
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.theme_type_variation = &"FamilyStrongLabel"
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(title_label)
	var value_label := FamilyLabelScene.instantiate() as Label
	value_label.text = value_text
	value_label.custom_minimum_size.x = 0.0
	value_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.theme_type_variation = &"PKDossierValue"
	value_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	row.add_child(value_label)
	return row


func _add_wrapped_label(host: Control, text: String, muted: bool) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.theme_type_variation = &"FamilyMutedLabel" if muted else &"PKDossierBody"
	host.add_child(label)


func _family_display_key(text: String) -> String:
	return text.strip_edges().replace(" ", "").replace("\n", "").replace("\r", "")


func _add_empty_label(host: Control, text: String) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"FamilyMutedLabel"
	label.custom_minimum_size = Vector2(0.0, 56.0)
	host.add_child(label)


func _add_section_label(host: Control, text: String) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.theme_type_variation = &"PKDossierKicker"
	host.add_child(label)


func _find_cards(root: Node) -> Array[PanelContainer]:
	var result: Array[PanelContainer] = []
	for child in root.get_children():
		if child is PanelContainer and child.theme_type_variation == &"FamilyCard":
			result.append(child as PanelContainer)
		else:
			result.append_array(_find_cards(child))
	return result


func _find_labels(root: Node) -> Array[Label]:
	var result: Array[Label] = []
	for child in root.get_children():
		if child is Label:
			result.append(child as Label)
		result.append_array(_find_labels(child))
	return result


func _find_progress_bars(root: Node) -> Array[ProgressBar]:
	var result: Array[ProgressBar] = []
	for child in root.get_children():
		if child is ProgressBar:
			result.append(child as ProgressBar)
		result.append_array(_find_progress_bars(child))
	return result


func _find_buttons(root: Node) -> Array[Button]:
	var result: Array[Button] = []
	for child in root.get_children():
		if child is Button:
			result.append(child as Button)
		result.append_array(_find_buttons(child))
	return result


func _count_nodes(root: Node) -> int:
	var count := 1
	for child in root.get_children():
		count += _count_nodes(child)
	return count
