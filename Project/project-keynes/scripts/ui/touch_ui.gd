extends Node

## 触摸端 UI「点得到 / 滚得动 / 关得掉」的**唯一**实现（与 mobile_ui_scaling.gd 配对）。
##
## 背景（真机反馈）
##   经济面板的页签是一排 34 设计像素高的纸签，440dpi 上 1 设计像素 = 0.5dp，
##   于是物理命中区只有 17dp（约 3mm），手指必然点错/点不中。同类尺寸散布在科技、
##   家族、国家、市场、暂停菜单、GM 面板里，所以这里做一次统一的树遍历，而不是在
##   几十个 .tscn 里写死数值。
##
## 口径（全部由 mobile_ui_scaling.dp_per_unit() 换算，不写死像素）
##   1 设计像素 = dp_per_unit() dp。440dpi + 总缩放 1.375 → 0.5dp/单位。
##   TOUCH_MIN_DP = 44 → 88 设计像素（Material 最小触摸目标，与 Apple 44pt 同口径）。
##   SCROLLBAR_MIN_DP = 32 → 64 设计像素（原滚动条 6~8px，几乎点不到）。
##
## 桌面档（is_touch_profile() == false）**全程 no-op**：本文件所有入口第一件事就是
## 判断触摸档，桌面 1600×960 的排版、尺寸、截图逐像素不变。
##
## 为什么不整屏放大：上一版把总缩放拉到 2.34 倍，真机反馈「按钮太大、面板被裁、
## 比改之前更难用」。这里只抬命中区（custom_minimum_size）与间距，字号/卡片比例不动。
##
## 用法（工作区根节点 _ready 一行）：
##   const TouchUI := preload("res://scripts/ui/touch_ui.gd")
##   TouchUI.watch(self)          # 覆盖现有子树 + 之后动态加入的控件
##   TouchUI.watch(self, {"min_dp": 44.0})
##
## 刻意不写 class_name：新脚本未进 global_script_class_cache 时裸类名会编译失败
## （同 mobile_ui_scaling.gd 的注释），统一 preload。

## 命中区目标（dp）。Material Design 最小触摸目标 44~48dp。
## [touch-size-rebalance 2026-11-02] 把 44dp 套到**所有**按钮上，在 2670×1200@520dpi
## 的真机上等于每个按钮 12% 屏高，整个界面被撑成平板 —— 玩家反馈「按钮异常地大」。
## 命中区不必靠视觉尺寸撑：touch_hit_button.gd 的 _has_point 已经把点击带扩到 44dp。
## 所以视觉下限回到 34dp，只有主菜单/暂停菜单这类主操作显式传 {"min_dp": 44}。
const TOUCH_MIN_DP := 34.0
## 密集数据区（热力网格方格、政策滑条行）用的次级目标（dp）。
## [touch-size-rebalance 2026-11-02] 28dp：这些行原本只有 30~34 设计像素高，
## 36dp 会把「一屏 30 行」压成 8 行。
const TOUCH_DENSE_DP := 28.0
## 相邻可点控件之间至少留多少 dp 的空隙，避免「想点 A 点到 B」。
const TOUCH_GAP_DP := 2.0
## 滚动条宽度目标（dp）。原来的纸片滚动条约 6 设计像素（3dp），手指根本捏不住。
## [touch-size-rebalance 2026-11-02] 32dp 在真机上是一条 42px 宽的棕色厚带
## （玩家反馈「很诡异的滚动条」）。改成 12dp：仍够手指按住，且不再抢视觉。
const SCROLLBAR_MIN_DP := 12.0
## 记在节点上的元数据键：已经挂过 child_entered_tree 监听。
const META_WATCH := &"pk_touch_watch"
## 记在控件上的元数据键：原始 custom_minimum_size（before/after 报告用）。
const META_BASE_MIN := &"pk_touch_base_min"


## ---------------------------------------------------------------- 设备口径

## 触摸档判定。桌面/Web 上恒为 false → 所有调用都是 no-op。
static func is_touch() -> bool:
	var scaling := _scaling()
	if scaling == null or not scaling.has_method("is_touch_profile"):
		return false
	return bool(scaling.call("is_touch_profile"))


## 1 设计像素 = 多少 dp。缩放节点缺失时退化成 1.0（此时 44 设计像素 = 44dp，
## 仍然远比现状的 17dp 好按，属于「宁可小一点也不能不生效」的兜底）。
static func dp_per_unit() -> float:
	var scaling := _scaling()
	if scaling != null and scaling.has_method("dp_per_unit"):
		return maxf(float(scaling.call("dp_per_unit")), 0.01)
	return 1.0


## dp → 设计像素。触摸档之外一律返回 0，调用方据此天然 no-op。
static func units(dp: float) -> float:
	if not is_touch():
		return 0.0
	return dp / dp_per_unit()


## 视觉尺寸下限（设计像素）。
##
## [pc-fit 2026-11-17] **恒返回 0**：触摸档不再抬高任何控件的视觉尺寸。
## 旧值 34dp ⇒ 68 设计像素塞进 custom_minimum_size，而 PC 的按钮只有 32~40，
## 抬完比 PC 高七成；`maxf(原值, min_units())` 遍布 category_tabs / dossier_* /
## ideology / 殖民面板等十几处，合起来就是玩家说的「按钮离奇地高、布局和 PC 对不上」。
## 保留这个入口（而不是删掉调用点）是为了让所有调用方零改动地退回设计原值。
static func min_units(options: Dictionary = {}) -> float:
	return 0.0


## 滚动条目标宽度（设计像素）。触摸档之外返回 0。
## 这一条**保留**：滚动条不占主布局，加宽只影响 ScrollContainer 内部，不会破坏版式。
static func scrollbar_units(options: Dictionary = {}) -> float:
	return units(float(options.get("scrollbar_dp", SCROLLBAR_MIN_DP)))


## 密集数据区的次级下限（设计像素）。同 min_units，恒返回 0。
static func dense_units(options: Dictionary = {}) -> float:
	return 0.0


## 命中区间距（设计像素）。恒返回 0，保持容器 separation 与 PC 一致。
static func gap_units(options: Dictionary = {}) -> float:
	return 0.0


## 用长边/短边判断「手机横屏」：2670×1200@1.375 → 逻辑 1942×873。
## 触摸档下逻辑短边 < 960（= 设计基准高度）就认为纵向空间吃紧（桌面 1600×960 是 960，
## 但桌面 is_touch=false，所以这条分支永不影响桌面）。
##
## [pc-fit 2026-11-17] 阈值 1000 → 960。旧策略把手机逻辑高压到 785~873（< 1000），
## 所以恒判「纵向吃紧」走紧凑档：工作台收起摘要卡、科技页收掉左右侧栏，
## 于是和 PC 版式完全是两套排版 —— 玩家反馈的「排版完全错乱」有一半来自这里。
## 现在逻辑画布恒为 1600×960（= 设计基准），纵向不再吃紧，紧凑档只在真正的
## 小窗（< 960）才触发。
static func is_short_viewport(height: float = -1.0) -> bool:
	if not is_touch():
		return false
	# [force-compact-qa 2026-11-02] 桌面模拟手机档时，总缩放上限 2.0 让逻辑高
	# 压不到手机的 923，于是永远进不了 compact 版面。这个 QA 开关只用于截图核对：
	#   PK_UI_FORCE_COMPACT=1  ⇒ 一律按"纵向吃紧"处理（等价真机 compact）。
	# 正式包不设该变量 ⇒ 行为不变。
	if OS.get_environment("PK_UI_FORCE_COMPACT") == "1":
		return true
	var h := height
	if h < 0.0:
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null or tree.root == null:
			return false
		h = tree.root.get_visible_rect().size.y
	return h < 960.0


## 面板版面是否该走紧凑档：触摸档 + 纵向吃紧。以前只有宽度断点
## （family_workspace 的 COMPACT_WIDTH=720），而手机的**逻辑宽度有 1942**，
## 于是永远判成「宽屏」，跑的是桌面板面 —— 这是「手机上排版是 PC 的」根因之一。
static func wants_compact(width: float, height: float = -1.0) -> bool:
	if not is_touch():
		return false
	if is_short_viewport(height):
		return true
	return width > 0.0 and width < 1280.0


## ---------------------------------------------------------------- 应用入口

## 立即对现有子树套用触摸命中区，并监听之后动态加入的控件。
## 同一棵子树重复调用是安全的（全部走 maxf，只会变大不会缩回）。
static func watch(root: Node, options: Dictionary = {}) -> void:
	if root == null or not is_touch():
		return
	apply_tree(root, options)
	_watch_subtree(root, options)


## 只套用一次，不装监听（给「一次性构建、之后不再增删」的子树用）。
## options.skip_names: 名字命中的子树整棵跳过（例如 HUD 顶栏/主操作栏的高度是
## 由 anchor + offset 写死的 80/86 设计像素，内部按钮若抬到 88 会溢出栏外，交给
## 各自的 apply_touch_metrics() 处理）。
static func apply_tree(root: Node, options: Dictionary = {}) -> int:
	if root == null or not is_touch():
		return 0
	# 注意：这里不再用 min_units 提前 return —— 即使不再抬任何尺寸，
	# 滚动条加宽（widen_scrollbars）仍要遍历整棵树。
	var skip := _skip_names(options)
	var applied := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if not skip.is_empty() and skip.has(String(node.name)):
			continue
		if node is ScrollContainer:
			widen_scrollbars(node as ScrollContainer, options)
		if apply_control(node, options):
			applied += 1
		for child in node.get_children():
			stack.append(child)
	return applied


## 单个控件套用命中区。返回是否真的动过尺寸（给 QA 计数用）。
##
## [pc-fit 2026-11-17] 触摸档**不再抬高任何控件的视觉尺寸**。
## 旧行为把 34dp ÷ 0.5 = 68 设计像素塞进 custom_minimum_size，而 PC 的按钮只有 32~40；
## 玩家的原话是「按钮变得特别离奇地高、布局和 PC 对不上」。视觉尺寸一动，版式就不再是
## PC 版式的等比缩放，而是另一套 —— 这才是「丑」的来源。
## 可点性改由**不占布局**的命中带承担：页签/整行按钮在 .tscn 里挂 touch_hit_button
## （_has_point 外扩，视觉不变）。需要更大命中区的地方应当显式挂，不做全局抬高。
static func apply_control(node: Node, options: Dictionary = {}) -> bool:
	if node == null or not is_touch():
		return false
	return false


## 抬高控件的最小尺寸（设计像素），并记录原始值供 before/after 报告。
static func raise_min_size(control: Control, height: float, width: float = 0.0) -> void:
	if control == null:
		return
	if not control.has_meta(META_BASE_MIN):
		control.set_meta(META_BASE_MIN, control.custom_minimum_size)
	var current := control.custom_minimum_size
	var wanted := current
	if height > 0.0:
		wanted.y = maxf(wanted.y, height)
	if width > 0.0:
		wanted.x = maxf(wanted.x, width)
	if wanted != current:
		control.custom_minimum_size = wanted


## 下拉框的弹出列表（OptionButton / MenuButton 的 PopupMenu）。
## PopupMenu 是独立 Window，不在面板的 Control 子树里，因此必须从按钮身上取；
## 行高 = 字高 + v_separation，这里把 v_separation 抬到约 0.75 倍目标，行高≈42dp。
static func raise_popup_items(popup, target: float) -> void:
	if popup == null or target <= 0.0 or not (popup is PopupMenu):
		return
	var menu := popup as PopupMenu
	var separation := int(round(target * 0.75))
	if menu.get_theme_constant("v_separation") < separation:
		menu.add_theme_constant_override("v_separation", separation)


## 滚动条加宽 + 触摸拖动。手机上「细纸边」既看不见也捏不住。
static func widen_scrollbars(scroll: ScrollContainer, options: Dictionary = {}) -> void:
	if scroll == null:
		return
	var width := scrollbar_units(options)
	if width <= 0.0:
		return
	var v_bar := scroll.get_v_scroll_bar()
	if v_bar != null:
		if v_bar.custom_minimum_size.x < width:
			v_bar.custom_minimum_size.x = width
		# [scrollbar-track-off 2026-11-02] 主题给 ScrollBar 铺的纸纹"轨道"会被拉伸成
		# 一条贯穿面板的浅棕色宽带（真机反馈"很诡异的滚动条"）。触摸档只保留滑块，
		# 轨道置空；滚动仍然可用（拖动滑块 + 内容区拖动）。
		v_bar.add_theme_stylebox_override("scroll", StyleBoxEmpty.new())
	var h_bar := scroll.get_h_scroll_bar()
	if h_bar != null:
		if h_bar.custom_minimum_size.y < width:
			h_bar.custom_minimum_size.y = width
		h_bar.add_theme_stylebox_override("scroll", StyleBoxEmpty.new())
	# 触摸拖动：ScrollContainer 只有在 deadzone 为 0 时才把第一下拖动判成滚动，
	# 否则会先等「是不是点击」。手指没有 hover，等不起。
	if scroll.scroll_deadzone > 4.0:
		scroll.scroll_deadzone = 4.0


## 让一个面板「滚得动」：把内容塞进 ScrollContainer 是不动场景结构的做法，
## 这里只做保底——面板自身高度超过可视高度时，横向/纵向滚动模式打开。
static func ensure_scrollable(scroll: ScrollContainer, vertical := true,
		horizontal := false) -> void:
	if scroll == null or not is_touch():
		return
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO \
		if vertical else ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO \
		if horizontal else ScrollContainer.SCROLL_MODE_DISABLED
	widen_scrollbars(scroll)


## ---------------------------------------------------------------- 诊断/验收

## 关键控件实测表（QA harness 用）：返回每个控件的设计像素/物理像素/dp。
static func measure(root: Node, paths: Array, dpi: float, pixel_scale: float) -> Array:
	var rows: Array = []
	if root == null:
		return rows
	for entry in paths:
		var path := String(entry)
		var human := path
		if entry is Array and (entry as Array).size() >= 2:
			path = String((entry as Array)[0])
			human = String((entry as Array)[1])
		var node := root.get_node_or_null(path) as Control
		if node == null:
			rows.append({"node": human, "exists": false})
			continue
		var rect := node.get_global_rect()
		var hit := hit_rect(node)
		rows.append({
			"node": human,
			"exists": true,
			"visible": node.is_visible_in_tree(),
			"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
			"w": rect.size.x, "h": rect.size.y,
			"hit_w": hit.size.x, "hit_h": hit.size.y,
			"px_h": rect.size.y * pixel_scale,
			"dp_w": _dp(rect.size.x * pixel_scale, dpi),
			"dp_h": _dp(rect.size.y * pixel_scale, dpi),
			"hit_dp_w": _dp(hit.size.x * pixel_scale, dpi),
			"hit_dp_h": _dp(hit.size.y * pixel_scale, dpi),
			"min_size": [node.custom_minimum_size.x, node.custom_minimum_size.y],
			"base_min": _base_min(node),
		})
	return rows


## 控件真正的可点矩形：本体 + `_has_point` 扩展出来的命中边。
static func hit_rect(control: Control) -> Rect2:
	if control == null:
		return Rect2()
	var rect := Rect2(Vector2.ZERO, control.size)
	var pad := Vector2.ZERO
	if control.has_method("touch_hit_padding"):
		var value = control.call("touch_hit_padding")
		if value is Vector2:
			pad = value
	if pad == Vector2.ZERO:
		return rect
	return Rect2(rect.position - pad, rect.size + pad * 2.0)


## ---------------------------------------------------------------- 内部

static func _scaling() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var settings := tree.root.get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return null
	return settings.call("ui_scaling")


static func _watch_subtree(node: Node, options: Dictionary) -> void:
	if node == null or node.has_meta(META_WATCH):
		return
	node.set_meta(META_WATCH, true)
	# 动态内容（税卡、列表行、暂停菜单按钮、页签按钮）都是在运行期 add_child 的，
	# 只在 _ready 遍历一次会漏掉它们；这里对「新加入的子树」再套一遍。
	node.child_entered_tree.connect(func(child: Node) -> void:
		apply_tree(child, options)
		_watch_subtree(child, options))
	for child in node.get_children():
		_watch_subtree(child, options)


static func _looks_icon_only(button: Button) -> bool:
	if button == null:
		return false
	return button.text.strip_edges().is_empty() and button.icon != null


static func _skip_names(options: Dictionary) -> Array:
	var value = options.get("skip_names", [])
	if value is Array:
		return value
	return []


static func _base_min(control: Control) -> Array:
	if control == null or not control.has_meta(META_BASE_MIN):
		return []
	var base = control.get_meta(META_BASE_MIN)
	if base is Vector2:
		return [(base as Vector2).x, (base as Vector2).y]
	return []


static func _dp(physical: float, dpi: float) -> float:
	return physical * 160.0 / maxf(dpi, 1.0)
