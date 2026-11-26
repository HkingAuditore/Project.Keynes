extends Node

## 移动端 UI 缩放的**唯一**策略入口。
##
## 背景（问题 1/3：安卓包「按钮特别小，点不中」）
##   Godot 4 默认 content_scale_mode=DISABLED，Control 树直接跑在物理像素上。
##   安卓横屏真机常见的 2220×1080 @440dpi 意味着 1 物理像素 = 160/440 ≈ 0.36 dp，
##   于是主菜单 52px 高的章节按钮 ≈ 19dp（约 3 mm），20px 的文字 ≈ 7dp——手指点不中。
##   桌面 1600×960 下 1 物理像素 ≈ 1 设计像素，观感正常，所以这不是「UI 设计得太小」，
##   而是「设计像素没有按 dp 换算到物理像素」。
##
## 策略（旧版：按 dpi 反推总缩放，2026-11-17 起被下面的 [pc-fit] 取代，仅存档案意义）
##   目标总缩放 S = 物理像素 / 设计像素 = DESIGN_DP_PER_UNIT × (dpi / 160)
##     → 1 设计像素恒等于 0.55dp，与分辨率、宽高比无关；
##     → 52px 按钮 = 28.6dp、18px 正文 = 9.9dp（440dpi 口径）。
##   再把 S 夹到「逻辑短边 ∈ [520, 1500] 设计像素」，避免极端 dpi/平板把 UI 挤爆或压扁。
##
## [revert-to-conservative 2026-11-01] 第一版用 0.85dp（440dpi 上总缩放 2.34、逻辑 949×462），
## 真机反馈「按钮太大、整屏被塞满、比改之前更难用」——因为 1600×960 的桌面排版被压进
## 一个 950×462 的画布，等于把整张桌面 UI 塞进手机上半屏。现在改成 0.55dp（440dpi 上
## 总缩放 ≈1.51、逻辑 ≈1468×714）：版面接近桌面设计，只把命中区整体抬大约 1.5 倍，
## 按钮从 19dp 提到 28dp，同时不破坏排版。想更大/更小由设置里的「界面缩放」再乘。
##
##   移动端：content_scale_mode = CANVAS_ITEMS + content_scale_size = 1600×960 + aspect=EXPAND，
##           content_scale_factor = S / base_stretch，其中 base_stretch = min(w/1600, h/960)
##           （EXPAND 的等比基准拉伸）。这样总缩放正好等于 S，且 content_scale_factor 的
##           语义仍是「用户 UI 缩放」，两者相乘一次，不会乘两次。
##   桌面/Web：content_scale_mode = DISABLED，content_scale_factor = 用户缩放
##           （= 改动前的既有行为），1600×960 及任意窗口尺寸下均零视觉回归。
##
## 安全区：DisplayServer.get_display_safe_area() 是**屏幕物理像素**，除以总缩放换成设计像素，
##         由各 UI 根节点（主菜单 PageMargin、游戏内 UIRoot）取用。
##
## [pc-fit 2026-11-17] 排版优先档（当前生效）
##   玩家反馈：安卓端「排版完全错乱」，明确表示「能接受字变小，希望直接按 PC 端排版缩放」。
##   根因不是缩放本身，而是**旧策略的放大倍率压缩了逻辑画布**：
##     总缩放 S = 1.375（440dpi）⇒ 逻辑画布 = 物理 / S = 2220/1.375 = 1614×785，
##     而所有版式常量都是按 1600×960 写的（右面板 460、详情面板最小 860、财政摘要卡片行、
##     工作台页脚……），高度少 18% 之后只能被压扁或溢出屏幕。
##   现在：content_scale_aspect = KEEP + factor = 用户倍率 ⇒
##     逻辑画布**恒为 1600×960**，与 PC 完全同一套版式，只是整体等比缩放到屏幕并居中。
##     2220×1080 上 scale = min(2220/1600, 1080/960) = 1.125，内容区 1800×1080，左右各留
##     210 物理像素边（约 9.5%）。20:9 比 PC 的 16.67:9 更宽，多出来的宽度进黑边，
##     而不是把版式拉开 —— EXPAND 会把科技页统计行、工作台页脚这类左右 anchor 的容器拉散。
##   代价：1 设计像素 = 1.125 物理像素 ≈ 0.41dp（旧 0.5），18px 正文从 9dp 降到 7.4dp，
##     这是玩家明确接受了的交换。
##   连带：逻辑高 = 960 = 设计基准，TouchUI.is_short_viewport 的阈值随之从 1000 降到 960，
##     否则手机仍会判「纵向吃紧」而收起摘要卡 / 科技页侧栏，跑的是 compact 版式而非 PC 版式。
##   触摸不再靠全局倍率撑：touch_ui 的命中带按固定设计像素换算（dp_per_unit 在触摸档
##   返回 DESIGN_DP_PER_UNIT，不跟随本分支的总缩放），所以排版回到 PC 后不会反过来把按钮撑大。
##
## 本类刻意不写 class_name：新脚本还没进 global_script_class_cache 时裸类名会编译失败
## （见 scripts/ui/main_menu.gd 里 WebAutotestScript 的同类注释），统一用 preload。

const REFERENCE_SIZE := Vector2i(1600, 960)
const VIEWPORT_WIDTH := 1600.0
const VIEWPORT_HEIGHT := 960.0
## 1 设计像素折算多少 dp —— **只用于触摸命中区的换算**（touch_ui / game_ui_manager），
## 不再参与 content_scale 的倍率计算。
## 0.5 ⇒ 34dp 视觉下限 = 68 设计像素、44dp 命中带 = 88 设计像素。
## 保持这个标定 = 触摸目标不随「全局缩放模式」漂移；改这里的值会立刻改变全站按钮尺寸。
const DESIGN_DP_PER_UNIT := 0.5

## 触摸档布局策略（设置里的「界面布局」三档）。桌面档恒为 fit，不读这个值。
##   fill  ：默认推荐。EXPAND 铺满无黑边 + 720p 黄金逻辑短边（20:9 上约 1600×720，元素自然放大 33%）。
##   fit   ：KEEP 1600×960 —— 与 PC 比例一致，20:9 上两侧留黑边，适合平板或偏好完整桌面比例。
##   dense ：EXPAND 1.0 —— 铺满无黑边且保持 960 逻辑高（20:9 上约 2133×960），同屏多显示内容。
const LAYOUT_MODES := ["fit", "fill", "dense"]
## fill 档目标逻辑高度（设计像素）：960 / 720 = 1.3333×，让 20:9 手机横屏恰好落在 ~1600×720。
const FILL_TARGET_HEIGHT := 720.0
const FILL_SCALE := VIEWPORT_HEIGHT / FILL_TARGET_HEIGHT
const DENSE_SCALE := 1.0
## 物理短边低于此阈值（dp）视为手机横屏（Phone Landscape），高于此阈值视为平板（Tablet）。
const PHONE_MAX_SHORT_SIDE_DP := 560.0
## dpi 不可信时的兜底：按 6.5 英寸对角线反推。
const FALLBACK_DIAGONAL_INCH := 6.5
const FALLBACK_DPI := 400.0
## [pc-fit 2026-11-17] 以下四个常量已不参与计算（旧「按 dpi 反推总缩放」策略的夹取区间）。
## 保留是为了改回旧策略时不丢标定值，新增代码不要再引用。
const LOGICAL_SHORT_SIDE_MIN := 560.0
const LOGICAL_SHORT_SIDE_MAX := 1600.0
const MAX_TOTAL_SCALE := 2.0
const MIN_TOTAL_SCALE := 0.9
## 安全区最多吃掉短边的百分比，防止厂商上报异常值把 UI 挤没。
const SAFE_AREA_MAX_RATIO := 0.25

var _is_touch := false
var _dpi := 96.0
## 触摸档布局策略（fill / fit / dense）。桌面档无效。
var _layout_mode := "fill"
## 触摸档在布局之上的再缩放（%）。50/75/100 —— 只往下，>100 会压小画布并触发 compact。
var _layout_scale := 100
## 设备倍率（[pc-fit 2026-11-17] 触摸档恒 1.0，只作诊断字段保留）。
var _device_scale := 1.0
## 实际绘制缩放 = 物理像素 / 设计像素（KEEP 下 = base_stretch × 用户倍率）。
var _total_scale := 1.0
## KEEP 的等比基准拉伸 min(w/1600, h/960)，仅供诊断。
var _base_stretch := 1.0
var _user_percent := 100
var _last_signature := ""
## QA/harness 覆盖：{"profile": "mobile"|"desktop"|"auto", "dpi": float, "safe_area": Rect2i}
var _qa_override: Dictionary = {}


func _ready() -> void:
	_apply_env_override()
	# 屏幕旋转 / 分屏 / 窗口拖拽都会改根视口尺寸：重算基准拉伸与安全区，
	# 并把 content_scale_factor 重新对齐（安卓旋转后 window 尺寸会互换）。
	var window := get_window()
	if window != null and not window.size_changed.is_connected(_on_window_resized):
		window.size_changed.connect(_on_window_resized)


## 桌面复现手机档位用：`PK_UI_QA_PROFILE="profile=mobile,dpi=440"` 启动即可走移动端
## content_scale 分支（不改代码、不影响正式包；只在环境变量存在时生效）。
func _apply_env_override() -> void:
	var raw := OS.get_environment("PK_UI_QA_PROFILE").strip_edges()
	if raw.is_empty():
		return
	var parsed: Dictionary = {}
	for part in raw.split(","):
		var kv := part.split("=")
		if kv.size() == 2:
			var key := kv[0].strip_edges()
			var value := kv[1].strip_edges()
			if key == "dpi":
				parsed[key] = float(value)
			elif key == "safe_w" or key == "safe_h":
				parsed[key] = int(value)
			else:
				parsed[key] = value
	if not parsed.is_empty():
		_qa_override = parsed
		print("[mobile-ui-scaling] QA override from PK_UI_QA_PROFILE: %s" % str(parsed))


func _on_window_resized() -> void:
	_apply()


## GameSettings 调用的唯一入口。
## user_percent：桌面档的「界面缩放」百分比（80/100/125/150）。
## layout_mode：触摸档的布局策略（fit / fill / dense），桌面档忽略。见 LAYOUT_MODES。
## layout_scale_percent：触摸档在布局之上的**再缩放**（50/75/100/125/150/200）。传 -1 表示跟随 user_percent。
##   乘在档位系数上：total = base_stretch × (layout_scale/100) × mode_factor。
##   >100 会把逻辑画布压到 1600×960 以下（200% ⇒ 800×480），`is_short_viewport()` 随之变 true，
##   各工作台切 compact 版式 —— 这是放大档的既定代价（玩家自己选「大 UI + 紧凑版式」）。
func configure(user_percent: int, layout_mode: String = "fill", layout_scale_percent: int = -1) -> void:
	_user_percent = clampi(user_percent, 50, 400)
	_layout_mode = layout_mode if layout_mode in LAYOUT_MODES else "fill"
	_layout_scale = clampi(layout_scale_percent, 50, 200) if layout_scale_percent > 0 else _user_percent
	_apply()


## 当前布局策略（触摸档）。桌面档恒 "fit"，调用方不必分支。
func layout_mode() -> String:
	return _layout_mode


## 触摸档在布局之上的再缩放百分比。
func layout_scale_percent() -> int:
	return _layout_scale


## 兼容旧调用名。
func apply(user_percent: int) -> void:
	configure(user_percent)


func user_percent() -> int:
	return _user_percent


## 物理像素 / 设计像素（= content_scale 之后 1 设计像素的物理边长）。
func total_scale() -> float:
	return _total_scale


## 1 设计像素折算成多少 dp。用于报告/诊断与验收口径。
##
## [pc-fit 2026-11-17] 触摸档返回**固定标定值**，不再由 total_scale 反推 —— 因为
## 总缩放现在只表示「PC 等比拉伸」，跟触摸目标的物理大小解绑。若仍走反推公式，
## 2220×1080 上会算出 0.364dp/单位，touch_ui 的 34dp 目标就变成 93 设计像素，
## 排版刚回到 PC 就被撑爆。固定 0.5 让 34dp = 68 设计像素、44dp 命中带 = 88 设计像素，
## 物理上比旧档小 18%（26dp → 21dp 视觉、36dp 命中带），仍远好于改动前的 17dp。
func dp_per_unit() -> float:
	if _is_touch:
		return DESIGN_DP_PER_UNIT
	if _total_scale <= 0.0:
		return 1.0
	return _total_scale * 160.0 / maxf(_dpi, 1.0)


func is_touch_profile() -> bool:
	return _is_touch


func dpi() -> float:
	return _dpi


## 物理短边（dp）：用于区分手机横屏（< 560dp）与平板（>= 560dp）。
func physical_short_side_dp() -> float:
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or win.y <= 0:
		win = REFERENCE_SIZE
	return float(mini(win.x, win.y)) * 160.0 / maxf(_dpi, 1.0)


func is_phone_landscape() -> bool:
	return _is_touch and physical_short_side_dp() < PHONE_MAX_SHORT_SIDE_DP


## 安全区（设计像素）。left/top/right/bottom 都是「离内容区边缘多少设计像素要留白」。
##
## KEEP 模式内容区居中、两侧有黑边，安全区常常整块落在黑边里；
## EXPAND 模式（fill / dense）内容区铺满整个窗口，原点为 (0, 0)。
func safe_insets() -> Dictionary:
	var insets := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	if not _is_touch:
		return insets
	var safe := _safe_area_pixels()
	var window := DisplayServer.window_get_size()
	if safe.size.x <= 0 or safe.size.y <= 0 or window.x <= 0 or window.y <= 0:
		return insets
	var origin := DisplayServer.window_get_position()
	var scale := maxf(_total_scale, 0.01)
	var safe_pos := Vector2(safe.position)
	if not _safe_area_is_window_local():
		safe_pos -= Vector2(origin)
	var safe_end := safe_pos + Vector2(safe.size)
	var content := Vector2(window)
	var content_origin := Vector2.ZERO
	if _layout_mode == "fit":
		content = Vector2(REFERENCE_SIZE) * scale
		content_origin = (Vector2(window) - content) * 0.5
	var limit := Vector2(VIEWPORT_WIDTH, VIEWPORT_HEIGHT) * SAFE_AREA_MAX_RATIO * scale
	insets.left = clampf(safe_pos.x - content_origin.x, 0.0, limit.x) / scale
	insets.top = clampf(safe_pos.y - content_origin.y, 0.0, limit.y) / scale
	insets.right = clampf(content_origin.x + content.x - safe_end.x, 0.0, limit.x) / scale
	insets.bottom = clampf(content_origin.y + content.y - safe_end.y, 0.0, limit.y) / scale
	return insets


## _safe_area_pixels() 这次返回的是不是「窗口坐标」。
## override 显式给了 safe_area，或桌面模拟 mobile（用 window_get_size 造出来的），都算窗口坐标。
func _safe_area_is_window_local() -> bool:
	if _qa_override.get("safe_area", null) is Rect2i:
		return true
	return String(_qa_override.get("profile", "auto")) == "mobile"


## 诊断快照（harness / 日志用）。
func report() -> Dictionary:
	var insets := safe_insets()
	return {
		"profile": "touch" if _is_touch else "desktop",
		"layout_mode": _layout_mode,
		"dpi": _dpi,
		"device_scale": _device_scale,
		"total_scale": _total_scale,
		"base_stretch": _base_stretch,
		"content_scale_factor": _content_scale_window().content_scale_factor,
		"content_scale_mode": _content_scale_window().content_scale_mode,
		"user_percent": _user_percent,
		"dp_per_unit": dp_per_unit(),
		"window": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		# [pc-fit 2026-11-17] 直接读视口，而不是 window/total_scale —— KEEP 模式
		# 横向有黑边，除法算出来会把黑边算进「逻辑宽度」。
		"logical": [_content_scale_window().get_visible_rect().size.x,
			_content_scale_window().get_visible_rect().size.y],
		"insets": insets,
		"safe_area_pixels": [DisplayServer.get_display_safe_area().position.x,
			DisplayServer.get_display_safe_area().position.y,
			DisplayServer.get_display_safe_area().size.x,
			DisplayServer.get_display_safe_area().size.y],
		"qa_override": _qa_override.duplicate(true),
	}


## 测试/验收用：在桌面上模拟移动端档位（profile/dpi/安全区）。
## 传空字典清除覆盖。
func set_qa_override(values: Dictionary) -> void:
	_qa_override = values.duplicate(true)
	_apply()


func clear_qa_override() -> void:
	_qa_override.clear()
	_apply()


## [resize-loop 2026-11-24] 重入锁：`_apply()` 会写 `content_scale_*`，而 web 单线程
## 消息循环里这次写入会让引擎重设 canvas 并**同步**回调 `size_changed` →
## `_on_window_resized` → `_apply()`，形成自激环（实测 logical 宽度
## 1140→1136→994→968→867→825→823 持续收缩，同时 terrain_render_scale 每帧
## 按新尺寸重分配渲染目标）。只把判重提前解决不了：签名里的 win 尺寸正是被自己
## 上一轮写入改掉的量。重入锁直接切断"自己的写入触发自己"。
var _applying := false


func _apply() -> void:
	if _applying:
		return
	_applying = true
	_apply_inner()
	_applying = false


func _apply_inner() -> void:
	var window := _content_scale_window()
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or win.y <= 0:
		win = Vector2i(int(VIEWPORT_WIDTH), int(VIEWPORT_HEIGHT))
	_is_touch = _resolve_touch()
	if _qa_override.has("layout"):
		var forced_mode := String(_qa_override.get("layout"))
		if forced_mode in LAYOUT_MODES:
			_layout_mode = forced_mode
	_dpi = _resolve_dpi(win)
	# [resize-loop 2026-11-24] 判重必须在**写 content_scale_* 之前**做。
	# 旧实现把它放在 :341 写入之后，于是每次调用都先改窗口的 content_scale_mode/size/
	# factor，改完又触发 window.size_changed -> _on_window_resized -> _apply()，
	# 自激成环：实测用户控制台 logical 宽度 1140→1136→994→968→867→825→823 持续收缩，
	# 同时 terrain_render_scale 每帧按新尺寸重分配渲染目标（见 terrain_render_scale.gd:107）。
	# 这里用「输入」做签名：输入定了输出就定了，不必等输出算完再比。
	var web_dpr := _resolve_web_dpr()
	var input_sig := "%s|%s|%.1f|%.3f|%d|%d|%d|%d" % ["touch" if _is_touch else "desktop",
		_layout_mode, _dpi, web_dpr, _user_percent, _layout_scale, win.x, win.y]
	if input_sig == _last_signature:
		return
	_last_signature = input_sig
	var user := float(_user_percent) / 100.0
	if _is_touch:
		# [layout-scale 2026-11-17] 触摸档的缩放来自独立的「界面缩放」档（50/75/100），
		# 与桌面百分比解耦：同一台机器切到触屏/鼠标不该互相改写对方的设置。
		user = float(_layout_scale) / 100.0
	if _is_touch:
		# 触摸档：分离 UI 矢量清晰渲染与地图独立降采样（terrain_render_scale.gd）。
		# 窗口统一采用 CANVAS_ITEMS 在物理分辨率上直接光栅化字体与矢量边框，告别上采样模糊。
		_device_scale = 1.0
		var mode_factor := 1.0
		var aspect := Window.CONTENT_SCALE_ASPECT_KEEP
		match _layout_mode:
			"fill":
				aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
				mode_factor = FILL_SCALE
			"dense":
				aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
				mode_factor = DENSE_SCALE
		var factor := user * mode_factor
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		window.content_scale_size = REFERENCE_SIZE
		window.content_scale_aspect = aspect
		_base_stretch = maxf(minf(float(win.x) / VIEWPORT_WIDTH, float(win.y) / VIEWPORT_HEIGHT),
			0.01)
		_total_scale = _base_stretch * factor
		window.content_scale_factor = factor
	else:
		# 桌面 / PC-Web：拉伸关闭。PC-Web 解锁原生 HiDPI（DPR≤2.0）后，canvas 按物理像素
		# 分配；同步按 DPR 抬高 _device_scale，并夹住逻辑画布不低于 1600×960（避免
		# 1080p@150% 窗口被压进 compact 窄视口），兼顾物理像素锐度与桌面完整排版。
		var fit_cap := maxf(1.0, minf(float(win.x) / VIEWPORT_WIDTH, float(win.y) / VIEWPORT_HEIGHT))
		_device_scale = clampf(minf(web_dpr, fit_cap), 1.0, 4.0) if web_dpr > 1.0 else 1.0
		_total_scale = _device_scale * user
		_base_stretch = 1.0
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		window.content_scale_factor = _total_scale
	# 判重已在函数开头完成（输入签名），这里不再重复比较。
	# fit（KEEP）的逻辑画布就是 REFERENCE_SIZE；fill/dense（EXPAND）与桌面档按窗口/总缩放换算。
	var keep_logical := _is_touch and _layout_mode == "fit"
	var logical_w := REFERENCE_SIZE.x if keep_logical \
		else int(float(win.x) / maxf(_total_scale, 0.01))
	var logical_h := REFERENCE_SIZE.y if keep_logical \
		else int(float(win.y) / maxf(_total_scale, 0.01))
	print("[mobile-ui-scaling] %s layout=%s dpi=%.0f device=%.3f total=%.3f dp_per_unit=%.2f logical=%dx%d"
		% ["touch" if _is_touch else "desktop", _layout_mode, _dpi, _device_scale,
			_total_scale, dp_per_unit(), logical_w, logical_h])


func _content_scale_window() -> Window:
	var window := get_window()
	return window if window != null else get_tree().root


func _resolve_touch() -> bool:
	var override := String(_qa_override.get("profile", "auto"))
	if override == "mobile":
		return true
	if override == "desktop":
		return false
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios") \
		or DCFeatureFlags.is_mobile_web()


func _resolve_web_dpr() -> float:
	var forced := float(_qa_override.get("web_dpr", 0.0))
	if forced > 0.0:
		return clampf(forced, 0.5, 4.0)
	if not OS.has_feature("web") or DCFeatureFlags.is_mobile_web():
		return 1.0
	if Engine.has_singleton("JavaScriptBridge"):
		var bridge: Object = Engine.get_singleton("JavaScriptBridge")
		if bridge != null:
			var raw: Variant = bridge.call("eval", "Number(window.devicePixelRatio) || 1")
			if raw is float or raw is int:
				var dpr := float(raw)
				if is_finite(dpr) and dpr > 0.0:
					return clampf(dpr, 1.0, 4.0)
	var screen_scale := DisplayServer.screen_get_scale()
	if is_finite(screen_scale) and screen_scale > 1.0:
		return clampf(screen_scale, 1.0, 2.0)
	return 1.0


func _resolve_dpi(win: Vector2i) -> float:
	var forced := float(_qa_override.get("dpi", 0.0))
	if forced > 0.0:
		return forced
	# 安卓上 screen_get_dpi() 返回 densityDpi（Pixel 3a = 440），screen_get_scale() 是
	# densityDpi/160（=2.75）。两个都问一遍，凡是落在合理区间的都收下；都不合理时按
	# 「对角线 6.5 英寸」反推——只为不让一台 dpi 上报异常的机器把 UI 缩成 1/3。
	var reported := float(DisplayServer.screen_get_dpi())
	if reported >= 120.0 and reported <= 800.0:
		return reported
	var scale := DisplayServer.screen_get_scale() * 160.0
	if scale >= 120.0 and scale <= 800.0:
		return scale
	var diagonal := sqrt(float(win.x) * win.x + float(win.y) * win.y)
	if diagonal > 0.0 and _is_touch:
		return clampf(diagonal / FALLBACK_DIAGONAL_INCH, 120.0, 800.0)
	return FALLBACK_DPI if _is_touch else 96.0


func _safe_area_pixels() -> Rect2i:
	var override = _qa_override.get("safe_area", null)
	if override is Rect2i:
		return override
	if String(_qa_override.get("profile", "auto")) == "mobile":
		# 桌面模拟移动端时，DisplayServer.get_display_safe_area() 返回的是显示器工作区
		# （跟窗口无关），拿来算会得到假刘海；默认按「无刘海全屏」处理。
		return Rect2i(Vector2i.ZERO, DisplayServer.window_get_size())
	return DisplayServer.get_display_safe_area()
