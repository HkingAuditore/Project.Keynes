# debug_console.gd
# 可开合的 Debug 控制台面板：把原本分散在 F6/F7/F8 快捷键与 @export 开关里
# 的调试选项集中到一个 UI 上，面向开发者与美术调参。
#
# 打开方式：主场景按 ` 或 F1（由 main.gd._unhandled_key_input 触发）。
# 节点结构（运行时动态构建，不依赖 .tscn 里的 children）：
#   PanelContainer (self, mouse_filter = STOP)
#     └ MarginContainer
#         └ ScrollContainer
#             └ VBoxContainer
#                 ├ Header Label（带关闭 X）
#                 ├ Overlay 分组（折叠）
#                 ├ 模拟开关 分组（折叠）
#                 ├ 视觉开关 分组（折叠）
#                 ├ 诊断动作 分组（折叠）
#                 └ Telemetry 分组（折叠）
#
# DebugConsole **不持有 MapData 引用**——所有数据都通过 `_main` 回调读取，
# 保证 MapData 被替换（R 键 regenerate）时不会出现悬挂引用。

class_name DebugConsole
extends PanelContainer

# 信号：其它子系统不直接引用 DebugConsole 的按钮/下拉，通过信号解耦。
signal overlay_mode_changed(mode: int)
signal overlay_alpha_changed(alpha: float)

# 主场景引用（提供 getter 读取运行时状态；所有回调都通过它调用 main 的方法）
var _main: Node = null

# --- 内部 UI 节点缓存 -----------------------------------------------------
var _overlay_option_btn: OptionButton
var _overlay_alpha_slider: HSlider
var _overlay_alpha_label: Label
var _overlay_error_label: Label

# 模拟开关：key=ClimateProfile 字段名，value=CheckBox
var _sim_checkboxes: Dictionary = {}
# 视觉开关：key=ClimateProfile 无关，直接 main.gd.@export 字段名，value=CheckBox
var _visual_checkboxes: Dictionary = {}

var _telemetry_vbox: VBoxContainer
var _telemetry_labels: Dictionary = {}
var _telemetry_timer: Timer

# 防抖：在一次内部 setter 刷新 CheckBox.pressed 时不要反向触发 toggled 信号。
var _suppress_sync_signals: bool = false
# 外部快捷键 / main 侧状态变更后置 dirty，由可见性切换或 telemetry 低频同步一次。
var _state_sync_dirty: bool = false
var _perf_detail_tick: int = 0


# --- 布局常量 -------------------------------------------------------------
const PANEL_WIDTH: float = 360.0

# 5 个"涌现耦合"开关映射到 ClimateProfile 字段。下拉 / CheckBox 生成顺序与展示名一致。
const SIM_SWITCHES: Array = [
	["emergent_season_enabled", "涌现季节（Emergent Season）"],
	["enable_local_climate_coupling", "本地气候耦合（Local Coupling）"],
	["emergent_weather_coupling", "天气耦合（Weather Coupling）"],
	["fast_slow_layering_enabled", "快慢分层（Fast/Slow Layering）"],
	["true_insolation_enabled", "真日射驱动（True Insolation）"],
]

# 视觉开关映射：main.gd 上的 @export 字段名 + HexRenderer 对应 setter。
# setter 为空表示不必推给 renderer（仅用于 main 自身的 perf_sampler 等）。
const VISUAL_SWITCHES: Array = [
	["day_night_enabled", "昼夜开关（day_night_enabled）", "set_day_night_enabled"],
	["water_effect_enabled", "水面效果（water_effect_enabled）", "set_water_effect_enabled"],
	["ocean_current_enabled", "洋流可视化（ocean_current_enabled）", "set_ocean_current_enabled"],
	["ocean_current_debug", "洋流高对比 Debug（F6）", "set_ocean_current_debug"],
	["extreme_weather_ground_effect_enabled", "极端天气地表特效", "set_extreme_weather_ground_effect_enabled"],
	["perf_sampler_enabled", "性能采样日志", "set_perf_sampler_enabled"],
]

func _ready() -> void:
	# UI 拦截：控制台内点击不应穿透到地块选中（验收 4.6）
	mouse_filter = Control.MouseFilter.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	visible = false
	# 停靠位置（TopBar 高度约 36px，空出 40 给 Label 与阴影）
	# 这里不硬编码 anchor，交由父容器或 main 侧的锚点配置；但给一个兜底 offset
	position = Vector2(8, 44)
	_build_ui()
	# Telemetry 低频定时器：Debug 面板只读缓存状态，避免打开面板后每秒制造 UI/字典开销。
	_telemetry_timer = Timer.new()
	_telemetry_timer.wait_time = 2.0

	_telemetry_timer.autostart = false
	_telemetry_timer.timeout.connect(_on_telemetry_tick)
	add_child(_telemetry_timer)
	visibility_changed.connect(_on_visibility_changed)

# 由 main.gd 注入。建议在 _ready 之后立即调用，确保 UI 构建完成后就能刷新状态。
func set_main(m: Node) -> void:
	_main = m
	_refresh_from_state()

# 由 main.gd 在 F6/F8 等外部路径修改状态后调用；不立即刷新，避免同帧 UI 抖动。
func request_state_sync() -> void:
	_state_sync_dirty = true
	if visible:
		_sync_state_if_dirty()

func _sync_state_if_dirty() -> void:
	if not _state_sync_dirty:
		return
	_state_sync_dirty = false
	_refresh_from_state()

# --- UI 构建 --------------------------------------------------------------


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.ScrollMode.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 520)
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(vbox)

	# ── 标题行
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := Label.new()
	title.text = "调试控制台"
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.pressed.connect(func() -> void: visible = false)
	header.add_child(close_btn)
	vbox.add_child(header)
	vbox.add_child(HSeparator.new())

	_build_overlay_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_sim_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_visual_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_diagnose_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_telemetry_group(vbox)

func _build_overlay_group(parent: VBoxContainer) -> void:
	var section := _make_section_header("Overlay（数据热力图）")
	parent.add_child(section)

	# Overlay 错误提示（shader 加载失败 / bake 报错时显示）
	_overlay_error_label = Label.new()
	_overlay_error_label.add_theme_color_override("font_color", Color(0.95, 0.35, 0.30))
	_overlay_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_overlay_error_label.visible = false
	parent.add_child(_overlay_error_label)

	var row_mode := HBoxContainer.new()
	var mode_label := Label.new()
	mode_label.text = "通道："
	mode_label.custom_minimum_size.x = 70.0
	row_mode.add_child(mode_label)
	_overlay_option_btn = OptionButton.new()
	_overlay_option_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Pass #2 注意事项：早期版本曾在这里读 ClimateProfile.demo_thermal_gradient_enabled
	# 决定是否注入 DEMO_THERMAL_GRADIENT 项，但 console._ready 跑得比 main 创建
	# _generator 更早 — 那一刻 _generator == null，守门必然返回 false，导致下拉
	# 框永久缺项（即使开关后来打开也不会重建）。
	# 现在恒定注入所有 ordered_modes，防御交给 main._apply_overlay_mode：开关关闭
	# 时仍选中 demo channel 会被运行时回退到 NONE 并 push_warning。
	for mode in OverlayMode.ordered_modes():
		_overlay_option_btn.add_item(OverlayMode.display_name(mode), mode)
	_overlay_option_btn.item_selected.connect(_on_overlay_option_selected)
	row_mode.add_child(_overlay_option_btn)
	parent.add_child(row_mode)

	var row_alpha := HBoxContainer.new()
	_overlay_alpha_label = Label.new()
	_overlay_alpha_label.text = "透明度 0.70"
	_overlay_alpha_label.custom_minimum_size.x = 110.0
	row_alpha.add_child(_overlay_alpha_label)
	_overlay_alpha_slider = HSlider.new()
	_overlay_alpha_slider.min_value = 0.0
	_overlay_alpha_slider.max_value = 1.0
	_overlay_alpha_slider.step = 0.01
	_overlay_alpha_slider.value = 0.7
	_overlay_alpha_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overlay_alpha_slider.value_changed.connect(_on_overlay_alpha_changed)
	row_alpha.add_child(_overlay_alpha_slider)
	parent.add_child(row_alpha)

func _build_sim_group(parent: VBoxContainer) -> void:
	parent.add_child(_make_section_header("模拟开关（F8 等价）"))
	for entry in SIM_SWITCHES:
		var field: String = entry[0]
		var label_text: String = entry[1]
		var cb := CheckBox.new()
		cb.text = label_text
		cb.toggled.connect(_on_sim_switch_toggled.bind(field))
		parent.add_child(cb)
		_sim_checkboxes[field] = cb

func _build_visual_group(parent: VBoxContainer) -> void:
	parent.add_child(_make_section_header("视觉开关"))
	for entry in VISUAL_SWITCHES:
		var field: String = entry[0]
		var label_text: String = entry[1]
		var setter: String = entry[2]
		var cb := CheckBox.new()
		cb.text = label_text
		cb.toggled.connect(_on_visual_switch_toggled.bind(field, setter))
		parent.add_child(cb)
		_visual_checkboxes[field] = cb

func _build_diagnose_group(parent: VBoxContainer) -> void:
	parent.add_child(_make_section_header("移动端调试动作"))
	_add_action_button(parent, "重新生成地图（R）", &"regenerate_debug_map")
	_add_action_button(parent, "适配视口（F）", &"fit_debug_map")
	_add_action_button(parent, "切换 5 项涌现/日射（F8）", &"toggle_emergent_debug_switches")
	_add_action_button(parent, "切换洋流高对比（F6）", &"toggle_ocean_current_debug")

	parent.add_child(_make_section_header("诊断打印"))
	var btn_ocean := Button.new()
	btn_ocean.text = "打印洋流热输运摘要（F7）"
	btn_ocean.custom_minimum_size.y = 34.0
	btn_ocean.pressed.connect(_on_btn_diagnose_ocean)
	parent.add_child(btn_ocean)

	var btn_temp := Button.new()
	btn_temp.text = "打印选中地块温度分解"
	btn_temp.custom_minimum_size.y = 34.0
	btn_temp.pressed.connect(_on_btn_diagnose_temperature)
	parent.add_child(btn_temp)

	_add_action_button(parent, "打印 DataCore 标志（F11）", &"print_data_core_flags_debug")
	_add_action_button(parent, "打印 validate-weather 快照（F12）", &"print_validate_weather_snapshot_debug")
	_add_action_button(parent, "打印性能 Verdict", &"print_perf_verdict_debug")

	parent.add_child(_make_section_header("DataCore / Soak"))
	_add_action_button(parent, "切换 DataCore Weather（F9）", &"toggle_data_core_weather_debug")
	_add_action_button(parent, "切换 DataCore Master（F10）", &"toggle_data_core_master_debug")
	_add_action_button(parent, "启动 Soak Dump 30 tick（F2）", &"start_soak_dump_debug")
	_add_action_button(parent, "启动 Soak A/B SAME 30（F3）", &"start_soak_ab_same_source_debug")
	_add_action_button(parent, "启动 Soak A/B Legacy（Shift+F3）", &"start_soak_ab_vs_legacy_debug")
	_add_action_button(parent, "取消 Soak / Dump（Alt+F3）", &"cancel_soak_debug")

	parent.add_child(_make_section_header("选择"))
	var btn_clear := Button.new()
	btn_clear.text = "清空当前选中"
	btn_clear.custom_minimum_size.y = 34.0
	btn_clear.pressed.connect(_on_btn_clear_selection)
	parent.add_child(btn_clear)

func _add_action_button(parent: VBoxContainer, text: String, method: StringName, args: Array = []) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size.y = 34.0
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func() -> void: _call_main_action(method, args))
	parent.add_child(btn)

func _call_main_action(method: StringName, args: Array = []) -> void:
	if _main == null or not _main.has_method(method):
		push_warning("[DebugConsole] main action missing: %s" % String(method))
		return
	_main.callv(method, args)

func _build_telemetry_group(parent: VBoxContainer) -> void:
	parent.add_child(_make_section_header("实时监视（Telemetry）"))
	_telemetry_vbox = VBoxContainer.new()
	_telemetry_vbox.add_theme_constant_override("separation", 4)
	parent.add_child(_telemetry_vbox)
	# 预注册常用 Label
	_add_telemetry_label("fast_tick", "fast_tick #0: 0ms")
	_add_telemetry_label("sus_summary", "SUS: —")
	_add_telemetry_label("sus_largest", "largest: —")
	_add_telemetry_label("sus_jobs", "jobs: —")
	_add_telemetry_label("sim_breakdowns", "breakdown: —")
	_add_telemetry_label("overlay_bake", "overlay bake: — ms")
	_add_telemetry_label("overlay_stats", "overlay stats: —")
	_add_telemetry_label("overlay_invalid", "invalid cells: 0")
	_add_telemetry_label("overlay_buckets", "")

func _add_telemetry_label(key: String, initial: String) -> void:
	var lb := Label.new()
	lb.text = initial
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_telemetry_vbox.add_child(lb)
	_telemetry_labels[key] = lb

func _make_section_header(text: String) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 14)
	lb.add_theme_color_override("font_color", Color(0.78, 0.86, 1.00))
	return lb

# --- 信号回调 -------------------------------------------------------------

func _on_visibility_changed() -> void:
	if visible:
		_state_sync_dirty = true
		_sync_state_if_dirty()
		_on_telemetry_tick()

		if _telemetry_timer != null:
			_telemetry_timer.start()
	else:
		if _telemetry_timer != null:
			_telemetry_timer.stop()

func _on_overlay_option_selected(idx: int) -> void:
	if _suppress_sync_signals:
		return
	var mode: int = _overlay_option_btn.get_item_id(idx)
	emit_signal("overlay_mode_changed", mode)
	if _main != null and _main.has_method("_apply_overlay_mode"):
		_main.call("_apply_overlay_mode", mode)
	_refresh_overlay_error_line()

func _on_overlay_alpha_changed(v: float) -> void:
	if _suppress_sync_signals:
		return
	_overlay_alpha_label.text = "透明度 %.2f" % v
	emit_signal("overlay_alpha_changed", v)
	if _main != null and _main.has_method("_set_overlay_alpha"):
		_main.call("_set_overlay_alpha", v)

# 模拟开关：复用 main.gd 里 F8 的 5-开关同步路径，确保与 shader / WeatherSystem 一致。
func _on_sim_switch_toggled(pressed: bool, field: String) -> void:
	if _suppress_sync_signals:
		return
	var gen = _get_generator()
	if gen == null:
		_show_need_map_toast()
		return
	var cp = gen._c() if gen.has_method("_c") else null
	if cp == null:
		return
	cp.set(field, pressed)
	# 跟 F8 行为一致：emergent_* / true_insolation_enabled 任一变化都要推到 shader
	# + WeatherSystem，才能让画面 / 天气/ 海冰 / 温度同步响应。
	var renderer = _get_renderer()
	if renderer != null and renderer.has_method("set_true_insolation_enabled"):
		renderer.set_true_insolation_enabled(bool(cp.get("true_insolation_enabled")))
	if gen._weather_system != null and gen._weather_system.has_method("configure_emergent_coupling"):
		gen._weather_system.configure_emergent_coupling(
			bool(cp.get("emergent_weather_coupling")),
			float(cp.get("rain_shadow_threshold")),
			float(cp.get("rain_shadow_factor")),
			float(cp.get("orographic_boost"))
		)
	if gen._weather_system != null and gen._weather_system.has_method("configure_ocean_spawn_bias"):
		gen._weather_system.configure_ocean_spawn_bias(float(cp.get("ocean_weather_spawn_bias")))
	# 立即推一次 refresh_climate_daily 让面板 / 温度 / 海冰即时响应
	var map = _get_map()
	var wc = _get_clock()
	if map != null and wc != null and gen.has_method("refresh_climate_daily"):
		gen.refresh_climate_daily(map, wc.season_phase())

func _on_visual_switch_toggled(pressed: bool, field: String, setter: String) -> void:
	if _suppress_sync_signals:
		return
	# main.gd 上的 @export 字段统一同步（保证 regenerate 后也能还原）
	if _main != null and _main.has_method("set"):
		_main.set(field, pressed)
	var renderer = _get_renderer()
	if renderer == null:
		return
	if setter != "" and renderer.has_method(setter):
		renderer.call(setter, pressed)

func _on_btn_diagnose_ocean() -> void:
	if _main != null and _main.has_method("diagnose_ocean_heat"):
		_main.call("diagnose_ocean_heat")

func _on_btn_diagnose_temperature() -> void:
	if _main != null and _main.has_method("diagnose_selected_temperature"):
		_main.call("diagnose_selected_temperature")

func _on_btn_clear_selection() -> void:
	if _main != null and _main.has_method("_clear_selection"):
		_main.call("_clear_selection")

# --- 状态同步 -------------------------------------------------------------

# 从 main / ClimateProfile / HexRenderer 读回真值，刷新所有 CheckBox/滑条/下拉。
# 由：① _ready 后 set_main 注入时 ② visible=true 时 ③ 外部状态 dirty 时调用。
func _refresh_from_state() -> void:
	_suppress_sync_signals = true


	# Overlay mode
	if _main != null and _main.has_method("get_overlay_mode"):
		var cur_mode: int = int(_main.call("get_overlay_mode"))
		# OptionButton item_id = mode
		for i in range(_overlay_option_btn.item_count):
			if _overlay_option_btn.get_item_id(i) == cur_mode:
				if _overlay_option_btn.selected != i:
					_overlay_option_btn.select(i)
				break

	# Overlay alpha
	if _main != null and _main.has_method("get_overlay_alpha"):
		var a: float = float(_main.call("get_overlay_alpha"))
		if not is_equal_approx(float(_overlay_alpha_slider.value), a):
			_overlay_alpha_slider.value = a
		var alpha_text := "透明度 %.2f" % a
		if _overlay_alpha_label.text != alpha_text:
			_overlay_alpha_label.text = alpha_text


	_refresh_overlay_error_line()

	# 模拟开关：读 ClimateProfile 真值
	var gen = _get_generator()
	var cp = gen._c() if gen != null and gen.has_method("_c") else null
	for entry in SIM_SWITCHES:
		var field: String = entry[0]
		var cb: CheckBox = _sim_checkboxes.get(field, null)
		if cb == null:
			continue
		if cp == null:
			if not cb.disabled:
				cb.disabled = true
		else:
			if cb.disabled:
				cb.disabled = false
			var pressed := bool(cp.get(field))
			if cb.button_pressed != pressed:
				cb.button_pressed = pressed


	# 视觉开关：从 main.gd 的 @export 字段直接读；ocean_current_debug 特殊——
	# renderer.get_ocean_current_debug() 才是权威真值（F6 可能绕过 main 修改）。
	var renderer = _get_renderer()
	for entry in VISUAL_SWITCHES:
		var field: String = entry[0]
		var cb: CheckBox = _visual_checkboxes.get(field, null)
		if cb == null:
			continue
		var val: bool = false
		if field == "ocean_current_debug" and renderer != null and renderer.has_method("get_ocean_current_debug"):
			val = bool(renderer.get_ocean_current_debug())
		elif _main != null:
			val = bool(_main.get(field))
		if cb.button_pressed != val:
			cb.button_pressed = val


	# 未生成地图：置灰诊断动作相关（通过比对 get_current_map() 是否为 null）
	var has_map: bool = _main != null \
		and _main.has_method("get_current_map") \
		and _main.call("get_current_map") != null
	# OptionButton/滑条允许切换（切到 NONE 无害），但诊断按钮需要 map
	# 这里通过 tooltip 提示而不强制禁用——避免打开控制台时一片灰色看不清

	_suppress_sync_signals = false

func _refresh_overlay_error_line() -> void:
	if _overlay_error_label == null:
		return
	var msg: String = ""
	if _main != null and _main.has_method("get_overlay_error_msg"):
		msg = str(_main.call("get_overlay_error_msg"))
	if msg == "":
		_overlay_error_label.visible = false
		_overlay_error_label.text = ""
	else:
		_overlay_error_label.visible = true
		_overlay_error_label.text = "⚠ overlay disabled: %s" % msg

func _show_need_map_toast() -> void:
	push_warning("[DebugConsole] 请先生成地图（R 键）")

# --- Telemetry tick -------------------------------------------------------

# 低频刷新：收集并显示全局统计。模拟暂停时依然更新（暂停本身是状态 freeze，
# 数值停留在最后一次真实 tick 的快照；此处不额外判 paused，因为 stats 字典
# 本身已经是冻结态）。UI 控件状态只在 dirty 时同步，不在 telemetry 中全量轮询。
func _on_telemetry_tick() -> void:
	if _main == null:
		return
	_sync_state_if_dirty()
	# fast_tick

	var tick_n: int = 0
	var tick_ms: int = 0
	if _main.has_method("get_fast_tick_count"):
		tick_n = int(_main.call("get_fast_tick_count"))
	if _main.has_method("get_last_fast_tick_ms"):
		tick_ms = int(_main.call("get_last_fast_tick_ms"))
	_set_tele("fast_tick", "fast_tick #%d: %dms" % [tick_n, tick_ms])

	# overlay bake 时间 + stats
	var bake_ms: float = 0.0
	if _main.has_method("get_overlay_last_bake_ms"):
		bake_ms = float(_main.call("get_overlay_last_bake_ms"))
	_set_tele("overlay_bake", "overlay bake: %.2f ms" % bake_ms)

	_refresh_sim_perf_lines()

	var stats: Dictionary = {}
	if _main.has_method("get_overlay_stats"):
		stats = _main.call("get_overlay_stats")
	var mode: int = 0
	if _main.has_method("get_overlay_mode"):
		mode = int(_main.call("get_overlay_mode"))

	if stats == null or stats.is_empty() or mode == 0:
		_set_tele("overlay_stats", "overlay stats: —")
		_set_tele("overlay_invalid", "")
		_set_tele("overlay_buckets", "")
		_refresh_overlay_error_line()
		return


	if OverlayMode.is_discrete(mode):
		_set_tele("overlay_stats", "stats: %d cells（离散通道）" % int(stats.get("count", 0)))
		_set_tele("overlay_buckets", _format_buckets(mode, stats.get("buckets", {})))
	elif OverlayMode.is_vector(mode):
		# 方向型通道的 stats 描述的是"强度"（hue 不参与统计）。
		var mn_v: float = float(stats.get("min", 0.0))
		var mx_v: float = float(stats.get("max", 0.0))
		var mean_v: float = float(stats.get("mean", 0.0))
		var med_v: float = float(stats.get("median", 0.0))
		_set_tele("overlay_stats", "强度: min=%.3f max=%.3f mean=%.3f med=%.3f"
			% [mn_v, mx_v, mean_v, med_v])
		_set_tele("overlay_buckets", "")
	else:
		var mn: float = float(stats.get("min", 0.0))
		var mx: float = float(stats.get("max", 0.0))
		var mean: float = float(stats.get("mean", 0.0))
		var med: float = float(stats.get("median", 0.0))
		_set_tele("overlay_stats", "stats: min=%.3f max=%.3f mean=%.3f med=%.3f"
			% [mn, mx, mean, med])
		_set_tele("overlay_buckets", "")

	var invalid_n: int = int(stats.get("invalid_count", 0))
	var near_zero_n: int = int(stats.get("near_zero_count", 0))
	var inv_lb: Label = _telemetry_labels.get("overlay_invalid", null)
	if inv_lb != null:
		var hint := OverlayMode.domain_hint(mode)
		var line := "invalid cells: %d" % invalid_n
		if near_zero_n > 0:
			line += " / near-zero valid: %d" % near_zero_n
		if hint != "":
			line += "\n提示：%s" % hint
		inv_lb.text = line
		inv_lb.visible = line != ""
		if invalid_n > 0 or near_zero_n > 0:
			inv_lb.add_theme_color_override("font_color", Color(0.98, 0.85, 0.30))
		else:
			inv_lb.add_theme_color_override("font_color", Color(0.70, 0.75, 0.80))


	_refresh_overlay_error_line()

func _refresh_sim_perf_lines() -> void:
	var summary: Dictionary = {}

	if _main.has_method("get_sus_last_tick_summary"):
		var raw_summary = _main.call("get_sus_last_tick_summary")
		if raw_summary is Dictionary:
			summary = raw_summary
	if summary.is_empty():
		_set_tele("sus_summary", "SUS: —")
		_set_tele("sus_largest", "largest: —")
	else:
		_set_tele("sus_summary", "SUS tick=%s source=%s total=%.2fms jobs=%d/%d slices=%d p95=%.2fms" % [
			str(summary.get("tick_index", "—")),
			str(summary.get("source", "—")),
			float(summary.get("total_ms", 0.0)),
			int(summary.get("jobs_ran", 0)),
			int(summary.get("jobs_skipped", 0)),
			int(summary.get("slices_total", 0)),
			float(summary.get("sus_sim_p95_300", 0.0)),
		])
		_set_tele("sus_largest", "largest: %s %.2fms stage=%s/%s path=%s" % [
			str(summary.get("largest_slice_job", "—")),
			float(summary.get("largest_slice_ms", 0.0)),
			str(summary.get("largest_slice_stage", "")),
			str(summary.get("largest_slice_substage", "")),
			str(summary.get("largest_slice_path", "")),
		])

	_perf_detail_tick += 1
	if _perf_detail_tick % 2 != 1:
		return

	var report: Dictionary = {}
	if _main.has_method("get_sus_last_tick_report"):
		var raw_report = _main.call("get_sus_last_tick_report")
		if raw_report is Dictionary:
			report = raw_report
	_set_tele("sus_jobs", _format_sus_jobs(report))

	var breakdowns: Dictionary = {}
	if _main.has_method("get_sim_breakdowns"):
		var raw_breakdowns = _main.call("get_sim_breakdowns")
		if raw_breakdowns is Dictionary:
			breakdowns = raw_breakdowns
	_set_tele("sim_breakdowns", _format_sim_breakdowns(breakdowns))


func _format_sus_jobs(report: Dictionary) -> String:
	if report.is_empty():
		return "jobs: —"
	var keys: Array = report.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	var rows: PackedStringArray = PackedStringArray()
	for job_id in keys:
		var r: Dictionary = report[job_id]
		var skipped: String = str(r.get("skipped_reason", ""))
		if skipped != "":
			rows.append("%s skip:%s" % [str(job_id), skipped])
		else:
			rows.append("%s %.2fms slices=%d progress=%.0f%%%s" % [
				str(job_id),
				float(r.get("elapsed_ms", 0.0)),
				int(r.get("slices_run", 0)),
				float(r.get("progress_ratio", 0.0)) * 100.0,
				_format_stage_suffix(r),
			])
		if rows.size() >= 8:
			break
	return "jobs:\n  " + "\n  ".join(rows)

func _format_stage_suffix(r: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	var stage: String = str(r.get("stage", ""))
	var substage: String = str(r.get("substage", ""))
	var path: String = str(r.get("path", ""))
	if stage != "":
		parts.append(stage)
	if substage != "":
		parts.append(substage)
	if path != "":
		parts.append(path)
	if parts.is_empty():
		return ""
	return " [" + "/".join(parts) + "]"

func _format_sim_breakdowns(breakdowns: Dictionary) -> String:
	if breakdowns.is_empty():
		return "breakdown: —"
	var rows: PackedStringArray = PackedStringArray()
	for name in ["climate", "weather", "enum_atlas", "sea_ice_atlas"]:
		var b = breakdowns.get(name, {})
		if b is Dictionary and not b.is_empty():
			rows.append("%s: %s" % [name, _format_ms_fields(b)])
	if rows.is_empty():
		return "breakdown: —"
	return "breakdown:\n  " + "\n  ".join(rows)

func _format_ms_fields(d: Dictionary) -> String:
	var keys: Array = d.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	var parts: PackedStringArray = PackedStringArray()
	for k in keys:
		var key_text: String = str(k)
		if key_text == "elapsed_ms" or key_text == "total_ms" or key_text.ends_with("_ms"):
			parts.append("%s=%.1f" % [key_text.replace("_ms", ""), float(d[k])])
		if parts.size() >= 7:
			break
	for meta_key in ["current_pass", "pass", "stage", "substage", "path"]:
		if d.has(meta_key) and str(d[meta_key]) != "":
			parts.append("%s=%s" % [meta_key, str(d[meta_key])])
	if parts.is_empty():
		return str(d)
	return " ".join(parts)

func _set_tele(key: String, text: String) -> void:
	var lb: Label = _telemetry_labels.get(key, null)
	if lb == null:
		return
	if lb.text != text:
		lb.text = text
	var want_visible := text != ""
	if lb.visible != want_visible:
		lb.visible = want_visible


func _format_buckets(mode: int, buckets: Dictionary) -> String:
	if buckets == null or buckets.is_empty():
		return ""
	var parts: PackedStringArray = PackedStringArray()
	var keys: Array = buckets.keys()
	keys.sort()
	for k in keys:
		var bname: String = ""
		if mode == OverlayMode.MODE.CLIMATE_ZONE:
			var idx: int = clampi(int(k), 0, OverlayMode.CLIMATE_ZONE_NAMES.size() - 1)
			bname = OverlayMode.CLIMATE_ZONE_NAMES[idx]
		elif mode == OverlayMode.MODE.WEATHER:
			var widx: int = clampi(int(k), 0, OverlayMode.WEATHER_NAMES.size() - 1)
			bname = OverlayMode.WEATHER_NAMES[widx]
		elif mode == OverlayMode.MODE.BIOME_GROUP:
			var bidx: int = clampi(int(k), 0, OverlayMode.BIOME_GROUP_NAMES.size() - 1)
			bname = OverlayMode.BIOME_GROUP_NAMES[bidx]
		elif mode == OverlayMode.MODE.LANDFORM:
			var lidx: int = clampi(int(k), 0, OverlayMode.LANDFORM_NAMES.size() - 1)
			bname = OverlayMode.LANDFORM_NAMES[lidx]
		else:
			bname = str(k)
		parts.append("%s %d" % [bname, int(buckets[k])])
	return " / ".join(parts)

# --- 访问辅助 -------------------------------------------------------------

func _get_generator():
	if _main == null:
		return null
	if _main.has_method("get_generator"):
		return _main.call("get_generator")
	return null

func _get_renderer():
	if _main == null:
		return null
	if _main.has_method("get_renderer"):
		return _main.call("get_renderer")
	return null

func _get_map():
	if _main == null:
		return null
	if _main.has_method("get_current_map"):
		return _main.call("get_current_map")
	return null

func _get_clock():
	if _main == null:
		return null
	if _main.has_method("get_world_clock_ref"):
		return _main.call("get_world_clock_ref")
	return null


# Reference-impl Pass #2 (demo-only)：通过 _main 反查 ClimateProfile 上的开关，
# 决定是否在 OptionButton 里展示 DEMO_THERMAL_GRADIENT。
# main.gd 已有 _is_demo_thermal_gradient_enabled()，这里走 has_method 间接调用，
# 避免 console 直接耦合 ClimateProfile / generator。
func _is_demo_thermal_gradient_enabled_via_main() -> bool:
	if _main == null:
		return false
	if not _main.has_method("_is_demo_thermal_gradient_enabled"):
		return false
	return bool(_main.call("_is_demo_thermal_gradient_enabled"))
