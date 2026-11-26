extends "res://scripts/ui/main_menu_world_setup.gd"

const MenuLayout = preload("res://scripts/ui/main_menu_layout.gd")
const SavePreviewCodecScript = preload("res://scripts/game/save_preview_codec.gd")
const ButtonContentScene := preload("res://scenes/ui/main_menu_button_content.tscn")
const MenuButtonScene := preload("res://scenes/ui/main_menu_button.tscn")
const SaveSlotRowScene := preload("res://scenes/ui/save_slot_row.tscn")

# Web 自动测试入口。用 preload 而不是 class_name：新文件还没进 global_script_class_cache，
# 裸类名会编译失败。见 scripts/game/web_autotest.gd。
const WebAutotestScript := preload("res://scripts/game/web_autotest.gd")
const HOME_PANEL_WIDTH := 396.0
const COMMAND_WIDTH := 280.0

# Web 专属的预热进度条（只在 web 上实例化，见 _spawn_web_shader_progress）。
const WebShaderProgressScenePath := "res://scenes/ui/web_shader_progress.tscn"
const WEB_PROGRESS_MAX_WIDTH := 480.0
const WEB_PROGRESS_MIN_WIDTH := 280.0

@onready var _backdrop: Control = %Backdrop
@onready var _page_margin: MarginContainer = %PageMargin
@onready var _page_stack: Control = %PageStack
@onready var _home_tome_shell: Control = %HomeTomeShell
@onready var _home_spine: Control = %HomeSpine
@onready var _home_hinges: Control = %HomeHinges
@onready var _dual_spread: BoxContainer = %DualSpread
@onready var _right_column: Control = %RightColumn
@onready var _settings_spread: BoxContainer = %SettingsSpread
@onready var _load_slots: VBoxContainer = %LoadSlots
@onready var _volume_value_label: Label = %VolumeValueLabel
var _settings_controls: Dictionary = {}
var _current_page_key := "home"

## Web 预热进度条。**桌面上永远是 null**（不创建任何节点）。
var _shader_progress: Control = null


## 主菜单背景音乐。GameAudio 是 autoload，bank 可能还没加载完，
## 所以轮询 status 直到 ready 再播；始终不就绪就静默放弃（大厅静音不影响功能）。
## 离开菜单后由全局 GameAudio 继续播放，直到世界就绪后时代音乐接管。
func _start_hall_music() -> void:
	var audio := get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("play_music"):
		return
	for _attempt in range(30):
		if String(audio.status) == "ready":
			if audio.has_method("play_stone_age_suite"):
				audio.play_stone_age_suite(true, 0.0, 0.78, 0)
			else:
				audio.play_music(&"hall")
			return
		await get_tree().process_frame


func _ready() -> void:
	var brand_crest := find_child("Crest", true, false) as TextureRect
	if brand_crest != null:
		brand_crest.texture = IconCatalog.texture_for_key(&"family.workspace.crest")
	if OS.get_cmdline_user_args().has("--editor-tech-tree") or OS.get_cmdline_args().has("--editor-tech-tree"):
		call_deferred("_open_technology_authoring_editor")
		return
	# Web：在玩家还没点「开始游戏」之前，先把所有会在运行期首次绘制的 shader 编译掉
	# （清单见 web_shader_warmup.gd 的 SHADERS）。这里**不再 await** —— 菜单先变成
	# 可操作，预热在后台逐张跑（每帧一张，带 warmup_shader 事件上报耗时），
	# 「开始游戏」和 autotest 再各自等它就绪。否则整块 17–22 秒的编译会把菜单冻住，
	# 既没有进度也看不出谁最贵。
	WebShaderWarmup.begin(self)
	# Web 自动测试：URL 带 autotest=1 时跳过整个菜单直接开局，其余玩家完全不受影响。
	# 必须等预热结束再开局，否则编译会漏进游戏里（那正是我们要消灭的冻结帧）。
	if await _start_web_autotest():
		return
	_configure_new_game_form()
	_bind_settings_controls()
	_connect_static_actions()
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	_show_home(false)
	# Web 再加一条左下角常驻细进度：菜单能点，但玩家得知道后台在编 shader、
	# 还差几张。桌面不走这里（函数内部先判平台，非 web 一个节点都不建）。
	_spawn_web_shader_progress()
	call_deferred("_apply_responsive_layout")
	call_deferred("_start_hall_music")
	# 目标①的验收口径是「页面加载**进主菜单** ≤20 s」，不是「进世界」——两者差着整个
	# 世界生成。这里在 UI 接好、首页显示之后打一次点，配合 `warmup` 事件就能把
	# 「引擎启动 / 菜单可见 / 预热完成」三段分开报（预热是后台跑的，不再挡住菜单）。
	WebTelemetry.emit("menu_ready", {
		"warmup_done": WebShaderWarmup.is_finished(),
		"warmup_done_count": int(WebShaderWarmup.progress().get("done", 0)),
	})
	WebTelemetry.flush()


func _open_technology_authoring_editor() -> void:
	get_tree().change_scene_to_file("res://scenes/tools/technology_tree_authoring_editor.tscn")


## Web 专属：菜单左下角的 shader 预热进度条。
##
## 为什么是常驻细条而不是遮罩：预热在后台逐张跑（首次访问 16–19 s 都花在驱动建
## shader 磁盘缓存上），菜单必须保持可操作。这里只把 `WebShaderWarmup` 的
## **真实计数**（已完成张数 / 总张数）显示出来，并在结束时淡出 —— 详见
## scripts/ui/components/web_shader_progress.gd。
##
## 桌面 / 清单还没建好时**不创建任何节点**：没有真实进度可显示就不显示，
## 不做"假进度条"。
func _spawn_web_shader_progress() -> void:
	if is_instance_valid(_shader_progress) or not OS.has_feature("web"):
		return
	if not WebShaderWarmup.has_plan():
		return
	var packed := load(WebShaderProgressScenePath) as PackedScene
	if packed == null:
		return
	var strip := packed.instantiate() as Control
	if strip == null:
		return
	_shader_progress = strip
	add_child(strip)


func _start_web_autotest() -> bool:
	if not WebAutotestScript.enabled():
		return false
	# 预热没跑完就开局 = 把 shader 编译丢进游戏里，所以这里必须等。
	await WebShaderWarmup.await_ready(self)
	# 用节点路径而不是 autoload 裸标识符，避免 --check-only --script 下编译不了。
	var result := WebAutotestScript.start_new_game(get_node_or_null("/root/GameFlow"))
	return bool(result.get("ok", false))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and _current_page_key != "home":
		_show_home()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _current_page_key != "home":
		_show_home()
		get_viewport().set_input_as_handled()


func _bind_settings_controls() -> void:
	_settings_controls = {
		"window_mode": %WindowMode,
		"resolution": %Resolution,
		"vsync": %Vsync,
		"graphics": %GraphicsQualityOptions,
		"ui_scale": %UIScale,
		"ui_layout": %UILayout,
		"volume": %Volume,
		"muted": %Muted,
		"reduce_motion": %ReduceMotion,
	}
	%Vsync.toggled.connect(_settings_controls.graphics.set_vsync_enabled)
	(%Volume as HSlider).value_changed.connect(func(val: float) -> void:
		if _volume_value_label != null:
			_volume_value_label.text = "%d%%" % int(round(val * 100.0))
	)


func _connect_static_actions() -> void:
	for button in [%NewGameButton, %LoadGameButton, %SettingsButton, %BrowsePkmapButton]:
		button.set_meta(&"ui_sound", &"open")
	for button in [%NewBackButton, %LoadBackButton, %SettingsBackButton, %QuitButton]:
		button.set_meta(&"ui_sound", &"close")
	for button in [%StartButton, %ApplySettingsButton]:
		button.set_meta(&"ui_sound", &"confirm")
	%AdvancedButton.set_meta(&"ui_sound", &"fold")
	%NewGameButton.pressed.connect(_show_new_game)
	%LoadGameButton.pressed.connect(_show_load_game)
	%SettingsButton.pressed.connect(_show_settings)
	%QuitButton.pressed.connect(GameFlow.quit_game)
	%NewBackButton.pressed.connect(_show_home)
	%LoadBackButton.pressed.connect(_show_home)
	%SettingsBackButton.pressed.connect(_show_home)
	%StartButton.pressed.connect(_start_new_game)
	%ApplySettingsButton.pressed.connect(_apply_settings)
	%RandomSeedButton.pressed.connect(func() -> void:
		_seed_box.value = NewGameConfig.random_seed()
		_sync_map_preview(true)
	)
	_random_country_button.pressed.connect(_pick_random_country_name)
	_country_edit.text_changed.connect(func(_txt: String) -> void: _sync_map_preview(false))
	_seed_box.value_changed.connect(func(_val: float) -> void: _sync_map_preview(false))
	_width_box.value_changed.connect(func(_val: float) -> void: _sync_map_preview(false))
	_height_box.value_changed.connect(func(_val: float) -> void: _sync_map_preview(false))
	%AdvancedButton.toggled.connect(func(open: bool) -> void:
		_advanced_grid.visible = open
		if open and not UIAnimation.reduced_motion():
			UIAnimation.crossfade(_advanced_grid, UITokens.ANIM_FAST)
	)
	%BrowsePkmapButton.pressed.connect(_browse_pkmap)
	_size_option.item_selected.connect(_on_size_preset_selected)
	_layout_option.item_selected.connect(_on_land_layout_selected)
	_map_source_option.item_selected.connect(func(_index: int) -> void: _refresh_map_source_ui())
	_pkmap_pick.item_selected.connect(_on_pkmap_pick_selected)
	_pkmap_dialog.file_selected.connect(_on_pkmap_file_selected)

	for entry in [
		[%NewGameButton, "新游戏", "plus", 20],
		[%LoadGameButton, "加载游戏", "history", 18],
		[%SettingsButton, "设置", "settings", 16],
		[%QuitButton, "退出", "close", 16],
	]:
		_decorate_chapter_button(entry[0], entry[1], entry[2], entry[3])

	for entry in [
		[%NewBackButton, "返回", "back", 15],
		[%StartButton, "开始游戏", "play", 16],
		[%LoadBackButton, "返回", "back", 15],
		[%SettingsBackButton, "返回", "back", 15],
		[%ApplySettingsButton, "应用", "confirm", 15],
		[%AdvancedButton, "高级地图设置", "settings", 14],
		[%BrowsePkmapButton, "浏览…", "world", 14],
	]:
		_decorate_text_button(entry[0], entry[1], entry[2], entry[3])
	IconButton.apply(%RandomSeedButton, &"action.refresh", 15, "随机地图种子")
	IconButton.apply(_random_country_button, &"action.refresh", 14, "随机国家名称")


func _apply_responsive_layout() -> void:
	return MenuLayout._apply_responsive_layout(self)


## 触摸端最小命中区（设计像素）。52 × 2.39 ≈ 45dp（440dpi 档位）。
const TOUCH_MIN_HEIGHT := 52.0


func _apply_touch_minimums(node: Node) -> void:
	if node is Control:
		var control := node as Control
		if control is BaseButton or control is LineEdit or control is Range:
			control.custom_minimum_size.y = maxf(control.custom_minimum_size.y, TOUCH_MIN_HEIGHT)
	for child in node.get_children():
		_apply_touch_minimums(child)


## 移动端缩放策略节点（/root/GameSettings/MobileUIScaling）。桌面端也存在，只是倍率 1.0。
func _ui_scaling_node() -> Node:
	var settings := get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return null
	return settings.call("ui_scaling")


func _safe_area_insets(scaling: Node) -> Dictionary:
	if scaling == null:
		return {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	return scaling.call("safe_insets")


func _show_page(page: Control, page_key: String = "home", animate: bool = true) -> void:
	_status_label.text = ""
	_current_page_key = page_key
	if _backdrop != null and _backdrop.has_method("set_page_mode"):
		_backdrop.call("set_page_mode", page_key)
	for candidate in get_tree().get_nodes_in_group("main_menu_pages"):
		UIAnimation.cancel(candidate as Control)
		var c := candidate as Control
		c.visible = c == page
	if animate and is_inside_tree():
		var offset := Vector2(-20.0, 0.0) if page_key == "home" else Vector2(24.0, 0.0)
		UIAnimation.crossfade(page, 0.12) if UIAnimation.reduced_motion() else UIAnimation.page_flip_in(page, offset, UITokens.MENU_PAGE_TRANSITION)
	if page_key == "home" and animate and not UIAnimation.reduced_motion():
		UIAnimation.stagger_children_in(%NewGameButton.get_parent(),.035,8,.24)
	call_deferred("_apply_responsive_layout")
	call_deferred("_focus_default_for_page", page_key)


func _focus_default_for_page(page_key: String) -> void:
	match page_key:
		"home":
			if %NewGameButton != null and %NewGameButton.is_visible_in_tree():
				%NewGameButton.grab_focus()
		"new":
			if %StartButton != null and %StartButton.is_visible_in_tree():
				%StartButton.grab_focus()
		"load":
			if %LoadBackButton != null and %LoadBackButton.is_visible_in_tree():
				%LoadBackButton.grab_focus()
		"settings":
			if %ApplySettingsButton != null and %ApplySettingsButton.is_visible_in_tree():
				_settings_controls.graphics.focus_preset()


func _show_home(animate: bool = true) -> void:
	_show_page(%HomePage, "home", animate)


func _show_new_game() -> void:
	_refresh_user_pkmap_list()
	_sync_map_preview(true)
	_show_page(%NewGamePage, "new", true)


func _show_load_game() -> void:
	_show_page(%LoadGamePage, "load", true)
	for child in _load_slots.get_children():
		child.queue_free()
	var slots: Array = []
	var save_service := get_node_or_null("/root/GameSave")
	if save_service != null and save_service.has_method("list_slots"):
		slots = save_service.call("list_slots")
	else:
		for slot_id in ["manual_1", "manual_2", "manual_3", "autosave"]:
			slots.append({"slot_id": slot_id, "exists": false, "loadable": false})
	for slot in slots:
		_add_save_slot(slot, save_service)


func _add_save_slot(slot: Dictionary, save_service) -> void:
	var row := SaveSlotRowScene.instantiate() as Control
	var preview := row.get_node("%Preview") as TextureRect
	var empty_seal := row.get_node("%EmptySeal") as Label
	var slot_badge := row.get_node("%SlotBadge") as Label
	var saved_at_label := row.get_node("%SavedAtLabel") as Label
	var title_label := row.get_node("%TitleLabel") as Label
	var description := row.get_node("%Description") as Label
	var slot_id := String(slot.get("slot_id", ""))
	var label := "自动存档" if slot_id == "autosave" else "手动存档 %s" % slot_id.trim_prefix("manual_")
	slot_badge.text = label
	if bool(slot.get("exists", false)):
		var cname := String(slot.get("country_name", "未知国家"))
		var day_num := int(slot.get("day", 0))
		var w_str := str(slot.get("width", 0))
		var h_str := str(slot.get("height", 0))
		var saved_at := String(slot.get("saved_at", "")).replace("T", " ")
		title_label.text = "%s · %s" % [cname, WorldClock.date_text_for_day(day_num)]
		saved_at_label.text = saved_at
		description.text = "%s × %s" % [w_str, h_str]
		if save_service != null and save_service.has_method("load_preview"):
			var result: Dictionary = save_service.call("load_preview", slot_id)
			if bool(result.get("ok", false)):
				# New slots store a scaled JPEG; older ones a full-window PNG.
				var image: Image = SavePreviewCodecScript.decode(
					result.get("bytes", PackedByteArray()))
				if not image.is_empty():
					preview.texture = ImageTexture.create_from_image(image)
					empty_seal.visible = false
	else:
		title_label.text = "空槽位"
		saved_at_label.text = ""
		description.text = ""
		empty_seal.visible = true
	var load_button := row.get_node("%LoadButton") as Button
	_configure_button(load_button, "加载", "history", func() -> void: _load_slot(slot_id), 14)
	load_button.disabled = not bool(slot.get("loadable", false))
	if bool(slot.get("exists", false)) and load_button.disabled:
		var reason := String(slot.get("reason", "版本不兼容"))
		load_button.tooltip_text = reason
		description.text += " · 不可用"
	_load_slots.add_child(row)


## 移动端设置页只保留「真正有用」的项：窗口模式/分辨率/垂直同步在安卓上由系统决定，
## game_settings.apply() 也已经跳过这些调用，UI 上继续显示只会让人以为"改了没生效"。
func _apply_settings_platform_visibility() -> void:
	# [pc-fit] 用 _ui_layout_mode_active() 而不是裸 OS.has_feature：
	# 窗口模式/分辨率/垂直同步要隐藏的平台，与「是否走触摸档布局」必须同一个判据。
	# 否则桌面 QA（模拟 profile=mobile）看到的是「五项都在」，真机却是「隐藏三项」，
	# 截图和真机对不上，排查时会被误导。
	var touch := _ui_layout_mode_active()
	for node_name in ["WindowModeLabel", "WindowMode", "ResolutionLabel", "Resolution", "Vsync"]:
		var node := find_child(node_name, true, false) as Control
		if node != null:
			node.visible = not touch


func _show_settings() -> void:
	_show_page(%SettingsPage, "settings", true)
	_apply_settings_platform_visibility()
	var current: Dictionary = GameSettings.values()
	_configure_option(_settings_controls.window_mode,
		["窗口", "无边框", "全屏"], ["windowed", "borderless", "fullscreen"], current.window_mode)
	_configure_option(_settings_controls.resolution,
		["1280 × 720", "1366 × 768", "1600 × 900", "1920 × 1080", "2560 × 1440"],
		[Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(2560, 1440)],
		Vector2i(current.resolution_width, current.resolution_height))
	_settings_controls.graphics.configure(current)
	# 触摸档：布局策略三档（fit/fill/dense）+ 布局之上的再缩放（50/75/100）。
	# 桌面档：只有百分比缩放（80/100/125/150），布局行隐藏。
	var layout_active := _ui_layout_mode_active()
	var scale_label := get_node_or_null("%UIScaleLabel") as Label
	var layout_label := get_node_or_null("%UILayoutLabel") as Label
	if layout_active:
		if scale_label != null:
			scale_label.text = "界面缩放"
		if layout_label != null:
			layout_label.visible = true
		_configure_option(_settings_controls.ui_scale,
			["50%（更小）", "75%", "100%（原大）", "125%", "150%", "200%"],
			[50, 75, 100, 125, 150, 200],
			int(current.get("ui_layout_scale", 100)))
		_settings_controls.ui_layout.visible = true
		_configure_option(_settings_controls.ui_layout,
			["完整 · PC 版式", "铺满 · 无黑边", "紧凑 · 更小更多"],
			["fit", "fill", "dense"], String(current.get("ui_layout_mode", "fit")))
	else:
		if scale_label != null:
			scale_label.text = "界面缩放"
		if layout_label != null:
			layout_label.visible = false
		_settings_controls.ui_layout.visible = false
		_configure_option(_settings_controls.ui_scale,
			["80%", "100%", "125%", "150%"], [80, 100, 125, 150], current.ui_scale_percent)
	_settings_controls.vsync.button_pressed = bool(current.vsync)
	_settings_controls.volume.value = float(current.master_volume)
	if _volume_value_label != null:
		_volume_value_label.text = "%d%%" % int(round(float(current.master_volume) * 100.0))
	_settings_controls.muted.button_pressed = bool(current.master_muted)
	_settings_controls.reduce_motion.button_pressed = bool(current.get("reduce_motion",false))


func _configure_option(option: OptionButton, labels: Array, values: Array, selected) -> void:
	option.clear()
	for index in range(labels.size()):
		option.add_item(String(labels[index]))
		option.set_item_metadata(index, values[index])
		if values[index] == selected:
			option.select(index)


func _make_button(text_value: String, icon: String, callback: Callable) -> Button:
	var button := MenuButtonScene.instantiate() as Button
	_configure_button(button, text_value, icon, callback, 15)
	return button


func _decorate_chapter_button(button: Button, title_value: String, icon: String, font_size: int) -> void:
	button.text = ""
	button.tooltip_text = title_value
	var content := button.get_node_or_null("Content") as MarginContainer
	if content == null:
		content = ButtonContentScene.instantiate() as MarginContainer
		button.add_child(content)
	content.add_theme_constant_override("margin_left", 8)
	content.add_theme_constant_override("margin_right", 18)
	content.add_theme_constant_override("margin_top", 2)
	content.add_theme_constant_override("margin_bottom", 6)
	var row := content.get_node("Row") as HBoxContainer
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 14)
	var icon_label := content.get_node("Row/Icon") as Label
	IconButton.apply_to_label(icon_label, StringName(icon), font_size)
	icon_label.custom_minimum_size = Vector2(38, 0)
	icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_label.add_theme_color_override("font_color", Color(0.99, 0.91, 0.70, 1.0))
	icon_label.add_theme_color_override("font_shadow_color", Color(0.16, 0.04, 0.02, 0.72))
	icon_label.add_theme_constant_override("shadow_offset_x", 0)
	icon_label.add_theme_constant_override("shadow_offset_y", 1)
	var text_label := content.get_node("Row/Label") as Label
	text_label.text = title_value
	text_label.add_theme_font_override("font", UITokens.dossier_font("serif"))
	text_label.add_theme_font_size_override("font_size", font_size)
	text_label.add_theme_color_override("font_color", Color(0.14, 0.075, 0.035, 1.0))
	text_label.add_theme_color_override("font_shadow_color", Color(1.0, 0.97, 0.88, 0.84))
	text_label.add_theme_constant_override("shadow_offset_x", 0)
	text_label.add_theme_constant_override("shadow_offset_y", 1)
	_bind_paper_slip_button(button, content)


func _bind_paper_slip_button(button: Button, content: Control) -> void:
	if button == null or button.has_meta("_paper_slip_bound"):
		return
	button.set_meta("_paper_slip_bound", true)
	var slip := button.get_node_or_null("SlipSurface") as ColorRect
	var slip_mat := slip.material as ShaderMaterial if slip != null else null
	var animate_slip := func(hovered: bool, pressed: bool) -> void:
		if not is_instance_valid(button):
			return
		if button.has_meta("_slip_tween"):
			var old_t = button.get_meta("_slip_tween")
			if old_t is Tween and (old_t as Tween).is_valid():
				(old_t as Tween).kill()
		var tw := button.create_tween()
		button.set_meta("_slip_tween", tw)
		tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		var h_target := 1.0 if hovered else 0.0
		var p_target := 1.0 if pressed else 0.0
		if slip_mat != null:
			tw.parallel().tween_method(
				func(v: float) -> void: slip_mat.set_shader_parameter("hover_amount", v),
				float(slip_mat.get_shader_parameter("hover_amount")),
				h_target,
				UITokens.ANIM_FAST
			)
			tw.parallel().tween_method(
				func(v: float) -> void: slip_mat.set_shader_parameter("press_amount", v),
				float(slip_mat.get_shader_parameter("press_amount")),
				p_target,
				0.08
			)
		if content != null and is_instance_valid(content):
			var ofs := Vector2(-1.5, -2.0) if (hovered and not pressed) else (Vector2(1.0, 1.0) if pressed else Vector2.ZERO)
			tw.parallel().tween_property(content, "position", ofs, UITokens.ANIM_FAST)
	button.mouse_entered.connect(func() -> void: animate_slip.call(true, button.is_pressed()))
	button.mouse_exited.connect(func() -> void: animate_slip.call(false, false))
	button.focus_entered.connect(func() -> void: animate_slip.call(true, false))
	button.focus_exited.connect(func() -> void: animate_slip.call(false, false))
	button.button_down.connect(func() -> void: animate_slip.call(true, true))
	button.button_up.connect(func() -> void: animate_slip.call(button.is_hovered(), false))


func _decorate_text_button(button: Button, text_value: String, icon: String, font_size: int) -> void:
	button.text = ""
	button.tooltip_text = text_value
	var content := button.get_node_or_null("Content") as MarginContainer
	if content == null:
		content = ButtonContentScene.instantiate() as MarginContainer
		button.add_child(content)
	var icon_label := content.get_node("Row/Icon") as Label
	IconButton.apply_to_label(icon_label, StringName(icon), font_size)
	var text_label := content.get_node("Row/Label") as Label
	text_label.text = text_value
	text_label.add_theme_font_size_override("font_size", font_size)
	if button.theme_type_variation == &"PKSealPrimaryButton":
		icon_label.add_theme_color_override("font_color", UITokens.PAPERCUT_SEAL_GOLD)
		text_label.add_theme_color_override("font_color", UITokens.PAPERCUT_SEAL_GOLD)
	UIAnimation.bind_tactile_button(button, content, 3.0)


func _configure_button(button: Button, text_value: String, icon: String,
		callback: Callable, font_size: int) -> void:
	_decorate_text_button(button, text_value, icon, font_size)
	button.pressed.connect(callback)


func _start_new_game() -> void:
	# Web：预热在后台跑，玩家可能先点了开始。这里等它就绪：按钮换成
	# 「正在准备着色器 n/N…」并禁用，左下角那条同样的进度继续走。
	# await 的是 WebShaderWarmup.await_ready()，内部逐帧 await process_frame，
	# 所以等待期间 UI 照常重绘（不是忙等），进度条也照常按已完成张数推进。
	# 桌面：is_finished() 恒为 true，整段跳过，行为与改动前完全一致。
	if not WebShaderWarmup.is_finished():
		var start_button: Button = %StartButton
		if is_instance_valid(_shader_progress) and _shader_progress.has_method("bind_pending_button"):
			_shader_progress.call("bind_pending_button", start_button)
		elif start_button != null:
			start_button.disabled = true
		await WebShaderWarmup.await_ready(self)
		if is_instance_valid(_shader_progress) and _shader_progress.has_method("release_pending_button"):
			_shader_progress.call("release_pending_button")
		elif start_button != null and is_instance_valid(start_button):
			start_button.disabled = false
	var config := NewGameConfig.new()
	config.country.name = _country_edit.text
	config.country.foreign_count = int(_foreign_count_box.value)
	config.base.map_width = int(_width_box.value)
	config.base.map_height = int(_height_box.value)
	config.base.initial_seed = int(_seed_box.value)
	config.base.land_layout = String(_layout_option.get_item_metadata(_layout_option.selected))
	config.base.num_continents = int((_advanced_controls.num_continents as SpinBox).value)
	config.base.continent_size = float((_advanced_controls.continent_size as SpinBox).value)
	config.base.sea_level = float((_advanced_controls.sea_level as SpinBox).value)
	if _is_pkmap_source():
		config.base.map_source = NewGameConfig.MAP_SOURCE_PKMAP
		config.base.pkmap_path = _pkmap_path
	else:
		config.base.map_source = NewGameConfig.MAP_SOURCE_PROCEDURAL
		config.base.pkmap_path = ""
	config.world_controls = {
		"continent_spacing": int((_advanced_controls.continent_spacing as SpinBox).value),
		"island_amount": int((_advanced_controls.island_amount as SpinBox).value),
		"wetness": int((_advanced_controls.wetness as SpinBox).value),
		"lake_density": int((_advanced_controls.lake_density as SpinBox).value),
		"river_density": int((_advanced_controls.river_density as SpinBox).value),
		"volcano_amount": int((_advanced_controls.volcano_amount as SpinBox).value),
	}
	var result := GameFlow.begin_new_game(config)
	if not bool(result.get("ok", false)):
		_status_label.text = String(result.get("message", "无法开始新游戏。"))


func _load_slot(slot_id: String) -> void:
	var result := GameFlow.begin_load_game(slot_id)
	if not bool(result.get("ok", false)):
		_status_label.text = String(result.get("message", "无法加载存档。"))


func _apply_settings() -> void:
	var resolution: Vector2i = _settings_controls.resolution.get_selected_metadata()
	var picked_scale = _settings_controls.ui_scale.get_selected_metadata()
	var payload := {
		"window_mode": _settings_controls.window_mode.get_selected_metadata(),
		"resolution_width": resolution.x,
		"resolution_height": resolution.y,
		"vsync": _settings_controls.vsync.button_pressed,
		"master_volume": _settings_controls.volume.value,
		"master_muted": _settings_controls.muted.button_pressed,
		"reduce_motion": _settings_controls.reduce_motion.button_pressed,
	}
	# 触摸档：UIScale 装缩放百分比（int）、UILayout 装布局档位（String）。
	# 桌面档：UIScale 装桌面百分比（int），UILayout 隐藏。
	if _ui_layout_mode_active():
		payload["ui_layout_scale"] = picked_scale
		payload["ui_layout_mode"] = _settings_controls.ui_layout.get_selected_metadata()
	else:
		payload["ui_scale_percent"] = picked_scale
	var result := GameSettings.update(payload.merged(_settings_controls.graphics.settings_payload()))
	_status_label.text = "设置已应用。" if bool(result.get("ok", false)) else String(result.message)


## 当前设备是否走「布局策略」而不是「百分比缩放」——与 mobile_ui_scaling 同一判定。
func _ui_layout_mode_active() -> bool:
	var scaling = GameSettings.ui_scaling() if GameSettings.has_method("ui_scaling") else null
	if scaling == null or not scaling.has_method("is_touch_profile"):
		return false
	return bool(scaling.call("is_touch_profile"))
