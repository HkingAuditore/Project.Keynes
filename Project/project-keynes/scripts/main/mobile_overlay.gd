extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _apply_mobile_topbar_safe_area(host) -> void:
	if not OS.has_feature("mobile"):
		return
	var top_bar: Control = host.get_node_or_null("UI/TopBar") as Control
	if top_bar == null:
		return
	# 下移并留出更宽的横向安全边，避开状态栏、刘海和圆角裁切。
	top_bar.offset_left = host.MOBILE_EDGE_SAFE
	top_bar.offset_right = -host.MOBILE_EDGE_SAFE
	top_bar.offset_top = host.MOBILE_TOPBAR_SAFE_TOP
	top_bar.offset_bottom = host.MOBILE_TOPBAR_SAFE_TOP + host.MOBILE_TOPBAR_HEIGHT
	var hbox: HBoxContainer = host.get_node_or_null("UI/TopBar/HBox") as HBoxContainer
	if hbox != null:
		hbox.add_theme_constant_override("separation", 8)
		hbox.custom_minimum_size.x = 900.0
		var scroll: ScrollContainer = host.get_node_or_null("UI/TopBar/MobileTopBarScroll") as ScrollContainer
		if scroll == null:
			scroll = ScrollContainer.new()
			scroll.name = "MobileTopBarScroll"
			scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			top_bar.add_child(scroll)
		if hbox.get_parent() != scroll:
			hbox.reparent(scroll)
	# 给所有子按钮加大 minimum_size，touch target 至少 ~72x56。
	if hbox != null:
		for child in hbox.get_children():
			if child is Button:
				var btn: Button = child as Button
				var min_w: float = max(btn.custom_minimum_size.x, 72.0)
				btn.custom_minimum_size = Vector2(min_w, host.MOBILE_BUTTON_HEIGHT)
	if host._info_label != null:
		host._info_label.visible = false
	if host._climate_label != null:
		host._climate_label.visible = false
	if host._time_label != null:
		host._time_label.custom_minimum_size.x = max(host._time_label.custom_minimum_size.x, 120.0)
	print("[mobile/safe-area] TopBar safe rect + horizontal scroll + buttons minimum 72x56")


# Mobile viewport scale（2026-06-14 路线 C）：把渲染分辨率降到 0.66x。
# 实测 fragment shader 主导 70% 帧时间；像素总数减到 0.66² ≈ 0.44 → fragment
# 时间从 ~13ms 降到 ~6ms。视觉变模糊但 60 FPS 可达。
#
# Godot 4.6 API：上轮试 Viewport.size_2d_override 失败（Window 类没该属性，运行时报错）。
# 正确路径 (https://docs.godotengine.org/en/stable/classes/class_window.html)：
#   1. get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
#      （让 canvas_item 在 base buffer 栅格化 → fragment 跑在 base 大小上）
#   2. get_window().content_scale_factor = 0.66
#      （base size = window_size * factor）
# 必须**同时**切 mode + factor，否则 factor 只影响 UI 元素缩放但 fragment 仍跑全分辨率。

func _apply_mobile_viewport_scale(host) -> void:
	if not OS.has_feature("mobile"):
		return
	var w: Window = host.get_window()
	if w == null:
		print("[mobile/viewport-scale] get_window() null, 跳过")
		return
	var win_size: Vector2i = w.size
	var target_factor: float = 0.66
	# 先记录原 mode 以便 toggle 回；切到 VIEWPORT mode 让 fragment 真的在小 buffer 跑
	var orig_mode: int = w.content_scale_mode
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	w.content_scale_factor = target_factor
	# 保持 aspect 不变（一般 KEEP / IGNORE 都行）
	print("[mobile/viewport-scale] window=%dx%d  factor=%.2f  mode: %d → %d (VIEWPORT)" % [
		win_size.x, win_size.y, target_factor, orig_mode, w.content_scale_mode
	])


# 计算移动端屏幕安全区内缩（像素，UI 坐标系）：避开刘海 / 挖孔摄像头 / 圆角 / 手势条。
# DisplayServer.get_display_safe_area() 返回物理像素，需按 viewport/物理 比例换算到 UI 坐标
# （项目可能开启 content scaling，比例未必为 1）。无可用安全区时回退到 MOBILE_EDGE_SAFE。
# 返回 Vector4(left, top, right, bottom)。

func _mobile_safe_insets(host) -> Vector4:
	var fallback = Vector4(host.MOBILE_EDGE_SAFE, host.MOBILE_EDGE_SAFE, host.MOBILE_EDGE_SAFE, host.MOBILE_EDGE_SAFE)
	if not OS.has_feature("mobile"):
		return fallback
	var safe: Rect2i = DisplayServer.get_display_safe_area()
	var win: Vector2i = DisplayServer.window_get_size()
	if safe.size.x <= 0 or safe.size.y <= 0 or win.x <= 0 or win.y <= 0:
		return fallback
	var ui: Vector2 = host.get_viewport().get_visible_rect().size
	var sx: float = ui.x / float(win.x)
	var sy: float = ui.y / float(win.y)
	var left: float = max(float(safe.position.x) * sx, host.MOBILE_EDGE_SAFE)
	var top: float = max(float(safe.position.y) * sy, host.MOBILE_EDGE_SAFE)
	var right: float = max(float(win.x - safe.end.x) * sx, host.MOBILE_EDGE_SAFE)
	var bottom: float = max(float(win.y - safe.end.y) * sy, host.MOBILE_EDGE_SAFE)
	return Vector4(left, top, right, bottom)


# Mobile-only 60 FPS 调查浮动面板（2026-06-14）：APK 没键盘，给手指可点的调试按钮。
# 默认收起成一个按钮，避免左侧窗口/地图被常驻面板遮挡；需要时点开抽屉。

func _ensure_mobile_debug_overlay(host) -> void:
	if not OS.has_feature("mobile"):
		return
	# 复用 UI CanvasLayer，避免新建 layer 跟 splash 等冲突
	var ui_layer: CanvasLayer = host.get_node_or_null("UI") as CanvasLayer
	if ui_layer == null:
		return
	if ui_layer.get_node_or_null("MobileDebugOverlay") != null:
		return  # 已建过
	# Container：锚定左上、向下展开（修复 2026-06-17）。
	# 旧版锚 CENTER_LEFT 有两个问题：
	#   1. 横屏时挖孔摄像头常落在左侧边缘垂直中部，Toggle 按钮正好被摄像头压住按不到；
	#   2. 展开靠手动改 position.y / size.y 对抗中心锚点，按钮组会窜到左上角飞出屏幕。
	# 现在统一锚 TOP_LEFT、向下生长，横向用真实安全区左内缩避开挖孔/圆角，纵向落在 TopBar 之下。
	var insets: Vector4 = host._mobile_safe_insets()
	var box: VBoxContainer = VBoxContainer.new()
	box.name = "MobileDebugOverlay"
	box.add_theme_constant_override("separation", 8)
	box.set_anchors_preset(Control.PRESET_TOP_LEFT)
	box.grow_horizontal = Control.GROW_DIRECTION_END
	box.grow_vertical = Control.GROW_DIRECTION_END
	box.position = Vector2(
		max(insets.x, host.MOBILE_EDGE_SAFE),
		max(insets.y, host.MOBILE_TOPBAR_SAFE_TOP) + host.MOBILE_TOPBAR_HEIGHT + 16.0
	)
	var btn_toggle: Button = Button.new()
	btn_toggle.name = "BtnToggle"
	btn_toggle.text = "Tools"
	btn_toggle.toggle_mode = true
	btn_toggle.custom_minimum_size = Vector2(148.0, host.MOBILE_BUTTON_HEIGHT)
	btn_toggle.pressed.connect(host._on_mobile_debug_overlay_toggle)
	box.add_child(btn_toggle)
	var stack: VBoxContainer = VBoxContainer.new()
	stack.name = "ButtonStack"
	stack.visible = false
	stack.add_theme_constant_override("separation", 8)
	box.add_child(stack)
	# Profile 按钮 — 不切状态，只 dump
	var btn_profile: Button = Button.new()
	btn_profile.text = "Profile"
	btn_profile.custom_minimum_size = Vector2(148.0, host.MOBILE_BUTTON_HEIGHT)
	btn_profile.pressed.connect(host.dump_render_profile)
	stack.add_child(btn_profile)
	# DVA toggle — 文本随状态变
	var btn_dva: Button = Button.new()
	btn_dva.name = "BtnDVA"
	btn_dva.text = "DVA: ON"
	btn_dva.toggle_mode = true
	btn_dva.custom_minimum_size = Vector2(148.0, host.MOBILE_BUTTON_HEIGHT)
	btn_dva.pressed.connect(host._on_mobile_dva_btn_pressed)
	stack.add_child(btn_dva)
	# Atlas size toggle
	var btn_atlas: Button = Button.new()
	btn_atlas.name = "BtnAtlas"
	btn_atlas.text = "Atlas: 512"
	btn_atlas.toggle_mode = true
	btn_atlas.custom_minimum_size = Vector2(148.0, host.MOBILE_BUTTON_HEIGHT)
	btn_atlas.pressed.connect(host._on_mobile_atlas_btn_pressed)
	stack.add_child(btn_atlas)
	# Weather Layer toggle (60 FPS 瓶颈调查：完全隐藏 weather overlay 看 ΔFPS)
	var btn_weather: Button = Button.new()
	btn_weather.name = "BtnWeather"
	btn_weather.text = "Weather: ON"
	btn_weather.toggle_mode = true
	btn_weather.custom_minimum_size = Vector2(148.0, host.MOBILE_BUTTON_HEIGHT)
	btn_weather.pressed.connect(host._on_mobile_weather_btn_pressed)
	stack.add_child(btn_weather)
	# Shader toggle (60 FPS 瓶颈调查：禁用主地形 shader 看 ΔFPS)
	var btn_shader: Button = Button.new()
	btn_shader.name = "BtnShader"
	btn_shader.text = "Shader: ON"
	btn_shader.toggle_mode = true
	btn_shader.custom_minimum_size = Vector2(148.0, host.MOBILE_BUTTON_HEIGHT)
	btn_shader.pressed.connect(host._on_mobile_shader_btn_pressed)
	stack.add_child(btn_shader)
	# Quality tier cycle 按钮（2026-06-15）：LOW (≤4 sample) → MID (≤6) → HIGH (≤9) 循环
	var btn_quality: Button = Button.new()
	btn_quality.name = "BtnQuality"
	btn_quality.text = "Quality: MID"
	btn_quality.custom_minimum_size = Vector2(148.0, host.MOBILE_BUTTON_HEIGHT)
	btn_quality.pressed.connect(host._on_mobile_quality_btn_pressed)
	stack.add_child(btn_quality)
	# Log toggle (Fix #11 second pass, 2026-06-16)：全局诊断日志开关
	# 关掉所有 GDScript print + 字符串构造 + C++ SUS-cpp periodic log，
	# 让 mobile 看到真实硬件天花板（去掉 print 自身 ~150-300ms/秒 overhead）。
	# 镜像到 DCWorldExt + SusSchedulerExt 的 set_diag_logs_enabled。
	var btn_log: Button = Button.new()
	btn_log.name = "BtnLog"
	# mobile 默认关（见 _ready() Fix #11 third pass），按钮初始文本随之。
	btn_log.text = "Log: ON" if PKLog.enabled else "Log: OFF"
	btn_log.toggle_mode = true
	btn_log.custom_minimum_size = Vector2(148.0, host.MOBILE_BUTTON_HEIGHT)
	btn_log.pressed.connect(host._on_mobile_log_btn_pressed)
	stack.add_child(btn_log)
	ui_layer.add_child(box)
	# 让容器收缩到当前（收起）所需的最小高度，避免残留过大 rect 盖住地图。
	box.reset_size.call_deferred()
	print("[mobile/debug-overlay] 60 FPS 调查面板挂载完成（默认收起，Tools 展开）")



func _on_mobile_debug_overlay_toggle(host) -> void:
	var ui_layer: CanvasLayer = host.get_node_or_null("UI") as CanvasLayer
	if ui_layer == null:
		return
	var box: VBoxContainer = ui_layer.get_node_or_null("MobileDebugOverlay") as VBoxContainer
	if box == null:
		return
	var stack: VBoxContainer = box.get_node_or_null("ButtonStack") as VBoxContainer
	var btn: Button = box.get_node_or_null("BtnToggle") as Button
	var expanded: bool = btn != null and btn.button_pressed
	if stack != null:
		stack.visible = expanded
	# 容器锚 TOP_LEFT，position 固定不动；只随内容收缩/展开自身高度，永远向下生长。
	box.reset_size.call_deferred()
	if btn != null:
		btn.text = "Hide" if expanded else "Tools"



func _mobile_debug_button(host, name: String) -> Button:
	var ui_layer: CanvasLayer = host.get_node_or_null("UI") as CanvasLayer
	if ui_layer == null:
		return null
	var btn: Button = ui_layer.get_node_or_null("MobileDebugOverlay/ButtonStack/%s" % name) as Button
	if btn != null:
		return btn
	return ui_layer.get_node_or_null("MobileDebugOverlay/%s" % name) as Button



func _on_mobile_dva_btn_pressed(host) -> void:
	host.toggle_dynamic_visual_atlas_upload()
	var btn: Button = host._mobile_debug_button("BtnDVA")
	if btn != null:
		btn.text = "DVA: OFF" if host._render_profile_atlas_disabled else "DVA: ON"



func _on_mobile_atlas_btn_pressed(host) -> void:
	host.toggle_atlas_resolution()
	var btn: Button = host._mobile_debug_button("BtnAtlas")
	if btn != null:
		btn.text = "Atlas: 256" if host._render_profile_atlas_quarter_size else "Atlas: 512"



func _on_mobile_weather_btn_pressed(host) -> void:
	host.toggle_weather_layer_visible()
	var btn: Button = host._mobile_debug_button("BtnWeather")
	if btn != null:
		btn.text = "Weather: OFF" if host._render_profile_weather_hidden else "Weather: ON"



func _on_mobile_shader_btn_pressed(host) -> void:
	host.toggle_world_shader_disabled()
	var btn: Button = host._mobile_debug_button("BtnShader")
	if btn != null:
		btn.text = "Shader: OFF" if host._render_profile_world_shader_disabled else "Shader: ON"



func _on_mobile_quality_btn_pressed(host) -> void:
	host.cycle_mobile_quality_tier()
	var btn: Button = host._mobile_debug_button("BtnQuality")
	if btn != null:
		var label: String = "MID"
		if host.mobile_quality_tier == 0:
			label = "LOW"
		elif host.mobile_quality_tier == 2:
			label = "HIGH"
		btn.text = "Quality: %s" % label


# Fix #11 second pass (2026-06-16) — Log toggle (KEY_L 等价)。
# 关掉 PKLog.enabled 后所有加守门的 GDScript print 站点跳过（含 % 字符串构造），
# 镜像到 C++ 端的 DCWorldExt / SusSchedulerExt::set_diag_logs_enabled 让 native
# print 站点也响应。mobile 上 print 自身 ~150-300ms/秒 是 frame budget 杀手。

func _on_mobile_log_btn_pressed(host) -> void:
	var new_enabled: bool = not PKLog.enabled
	var world_ext_ref = null
	var sus_ext_ref = null
	if host._generator != null:
		if "_data_core_world_ext" in host._generator:
			world_ext_ref = host._generator._data_core_world_ext
		sus_ext_ref = host._sus_ext_ref()
	PKLog.set_enabled(new_enabled, world_ext_ref, sus_ext_ref)
	var btn: Button = host._mobile_debug_button("BtnLog")
	if btn != null:
		btn.text = "Log: ON" if PKLog.enabled else "Log: OFF"



func _ensure_splash_overlay(host) -> void:
	if host._splash_layer != null:
		return
	host._splash_layer = CanvasLayer.new()
	host._splash_layer.layer = 100  # 盖在 UI 之上
	host._splash_layer.name = "SplashOverlay"
	# 全屏黑底
	var bg = ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 1.0)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host._splash_layer.add_child(bg)
	# 居中文字
	host._splash_label = Label.new()
	host._splash_label.text = "正在生成世界…"
	host._splash_label.add_theme_font_size_override("font_size", 28)
	host._splash_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95, 1.0))
	host._splash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	host._splash_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	host._splash_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host._splash_layer.add_child(host._splash_label)
	host.add_child(host._splash_layer)
	host._splash_layer.visible = false



func _splash_show(host, text: String = "正在生成世界…") -> void:
	if host._splash_label != null:
		host._splash_label.text = text
	if host._splash_layer != null:
		host._splash_layer.visible = true



func _splash_hide(host) -> void:
	if host._splash_layer != null:
		host._splash_layer.visible = false


# 由 baker.stage_progress signal 触发。bake_world 同步执行期间 UI 不会重绘，
# 这里只 print 进度便于 logcat 诊断。

static func _on_baker_stage_progress(host, stage: String, fraction: float) -> void:
	if OS.is_debug_build():
		print("[splash] bake stage=%s fraction=%.2f" % [stage, fraction])
