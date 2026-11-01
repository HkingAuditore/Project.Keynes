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
## 策略（一个公式，桌面/移动共用一条代码路径，但设备倍率不同）
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
## 本类刻意不写 class_name：新脚本还没进 global_script_class_cache 时裸类名会编译失败
## （见 scripts/ui/main_menu.gd 里 WebAutotestScript 的同类注释），统一用 preload。

const REFERENCE_SIZE := Vector2i(1600, 960)
const VIEWPORT_WIDTH := 1600.0
const VIEWPORT_HEIGHT := 960.0
## 1 设计像素目标等于多少 dp。0.5 → 440dpi 上总缩放 ≈1.375、52px 按钮 ≈26dp。
## 这个值直接决定「手机上 UI 比桌面大多少」：
##   0.85（第一版）→ 总缩放 2.34、逻辑 950×462：真机反馈「按钮太大、面板被裁、完全没法用」；
##   0.50（现在）  → 总缩放 1.375、逻辑 ≈1942×873（2670×1200@440dpi）：接近桌面排版，
##                   只把命中区整体抬 37%，比改动前的 19dp 明显好按，又不会把版面挤爆。
const DESIGN_DP_PER_UNIT := 0.5
## dpi 不可信时的兜底：按 6.5 英寸对角线反推。
const FALLBACK_DIAGONAL_INCH := 6.5
const FALLBACK_DPI := 400.0
## 逻辑短边的允许区间（设计像素）。下限越大 = UI 越大；560 对应「桌面排版的 1/1.2」。
const LOGICAL_SHORT_SIDE_MIN := 560.0
const LOGICAL_SHORT_SIDE_MAX := 1600.0
const MAX_TOTAL_SCALE := 2.0
const MIN_TOTAL_SCALE := 0.9
## 安全区最多吃掉短边的百分比，防止厂商上报异常值把 UI 挤没。
const SAFE_AREA_MAX_RATIO := 0.25

var _is_touch := false
var _dpi := 96.0
## 设备倍率（dp 换算，不含用户 UI 缩放）与最终总缩放（含用户 UI 缩放）。
var _device_scale := 1.0
var _total_scale := 1.0
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


## GameSettings 调用的唯一入口。user_percent ∈ {80,100,125,150}（设置里的 UI 缩放）。
func configure(user_percent: int) -> void:
	_user_percent = clampi(user_percent, 50, 400)
	_apply()


## 兼容旧调用名。
func apply(user_percent: int) -> void:
	configure(user_percent)


func user_percent() -> int:
	return _user_percent


## 物理像素 / 设计像素（= content_scale 之后 1 设计像素的物理边长）。
func total_scale() -> float:
	return _total_scale


## 1 设计像素折算成多少 dp。用于报告/诊断与验收口径。
func dp_per_unit() -> float:
	if _total_scale <= 0.0:
		return 1.0
	return _total_scale * 160.0 / maxf(_dpi, 1.0)


func is_touch_profile() -> bool:
	return _is_touch


func dpi() -> float:
	return _dpi


## 安全区（设计像素）。left/top/right/bottom 都是「离屏幕边多少设计像素要留白」。
func safe_insets() -> Dictionary:
	var insets := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	if not _is_touch:
		# 桌面/Web：DisplayServer.get_display_safe_area() 在 Windows 上是「显示器工作区」，
		# 跟窗口无关，直接用会算出几十像素的假刘海。
		return insets
	var safe := _safe_area_pixels()
	var window := DisplayServer.window_get_size()
	if safe.size.x <= 0 or safe.size.y <= 0 or window.x <= 0 or window.y <= 0:
		return insets
	var origin := DisplayServer.window_get_position()
	var scale := maxf(_total_scale, 0.01)
	var logical_w := float(window.x) / scale
	var logical_h := float(window.y) / scale
	var limit_x := logical_w * SAFE_AREA_MAX_RATIO
	var limit_y := logical_h * SAFE_AREA_MAX_RATIO
	insets.left = clampf(float(safe.position.x - origin.x) / scale, 0.0, limit_x)
	insets.top = clampf(float(safe.position.y - origin.y) / scale, 0.0, limit_y)
	insets.right = clampf(float(origin.x + window.x - safe.position.x - safe.size.x) / scale,
		0.0, limit_x)
	insets.bottom = clampf(float(origin.y + window.y - safe.position.y - safe.size.y) / scale,
		0.0, limit_y)
	return insets


## 诊断快照（harness / 日志用）。
func report() -> Dictionary:
	var insets := safe_insets()
	return {
		"profile": "touch" if _is_touch else "desktop",
		"dpi": _dpi,
		"device_scale": _device_scale,
		"total_scale": _total_scale,
		"base_stretch": _base_stretch,
		"content_scale_factor": _content_scale_window().content_scale_factor,
		"content_scale_mode": _content_scale_window().content_scale_mode,
		"user_percent": _user_percent,
		"dp_per_unit": dp_per_unit(),
		"window": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"logical": [float(DisplayServer.window_get_size().x) / maxf(_total_scale, 0.01),
			float(DisplayServer.window_get_size().y) / maxf(_total_scale, 0.01)],
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


func _apply() -> void:
	var window := _content_scale_window()
	var win := DisplayServer.window_get_size()
	if win.x <= 0 or win.y <= 0:
		win = Vector2i(int(VIEWPORT_WIDTH), int(VIEWPORT_HEIGHT))
	_is_touch = _resolve_touch()
	_dpi = _resolve_dpi(win)
	var user := float(_user_percent) / 100.0
	if _is_touch:
		var desired := DESIGN_DP_PER_UNIT * (maxf(_dpi, 1.0) / 160.0)
		var short_side := float(mini(win.x, win.y))
		desired = clampf(desired, short_side / LOGICAL_SHORT_SIDE_MAX,
			short_side / LOGICAL_SHORT_SIDE_MIN)
		_device_scale = clampf(desired, MIN_TOTAL_SCALE, MAX_TOTAL_SCALE)
		# 用户倍率只乘一次：设备倍率（dp 换算）与用户 UI 缩放相乘后写进 content_scale_factor。
		_total_scale = _device_scale * user
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		window.content_scale_size = REFERENCE_SIZE
		window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		_base_stretch = maxf(minf(float(win.x) / VIEWPORT_WIDTH, float(win.y) / VIEWPORT_HEIGHT),
			0.01)
		window.content_scale_factor = _device_scale / _base_stretch * user
	else:
		# 桌面/Web：与改动前完全一致——拉伸关闭，factor 只表示用户 UI 缩放。
		_device_scale = 1.0
		_total_scale = user
		_base_stretch = 1.0
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		window.content_scale_factor = user
	var signature := "%s|%.1f|%.3f|%.3f|%d|%s" % ["touch" if _is_touch else "desktop", _dpi,
		_device_scale, _total_scale, win.x, win.y]
	if signature == _last_signature:
		return
	_last_signature = signature
	print("[mobile-ui-scaling] %s dpi=%.0f device=%.3f total=%.3f dp_per_unit=%.2f logical=%dx%d"
		% ["touch" if _is_touch else "desktop", _dpi, _device_scale, _total_scale, dp_per_unit(),
			int(float(win.x) / maxf(_total_scale, 0.01)),
			int(float(win.y) / maxf(_total_scale, 0.01))])


func _content_scale_window() -> Window:
	var window := get_window()
	return window if window != null else get_tree().root


func _resolve_touch() -> bool:
	var override := String(_qa_override.get("profile", "auto"))
	if override == "mobile":
		return true
	if override == "desktop":
		return false
	# 只认原生移动平台。Web（含移动浏览器）走 export_presets.cfg 的 DPR=1 方案，
	# 由另一路负责，这里不介入。
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")


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
