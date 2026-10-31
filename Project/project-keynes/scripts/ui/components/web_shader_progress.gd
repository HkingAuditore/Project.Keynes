extends Control

## Web 菜单期 shader 预热的常驻进度条。
##
## 只由 `main_menu.gd` 的 `_spawn_web_shader_progress()` 在 **web** 上实例化；
## 桌面上根本不存在这个节点（`OS.has_feature("web")` 之外不建任何新节点）。
##
## 为什么需要它：全新浏览器 profile 的第一次访问，驱动要在这里建一次 shader 磁盘
## 缓存（WebGL 没有 program binary 缓存），实测 16–19 s 都落在菜单期的预热里。菜单
## 本身 5–6 s 就出来了，于是玩家看到的是"能显示、但连续卡几秒"——看起来像卡死。
## 这条常驻细条只回答两件事：在等什么（预编译着色器）、还差多少（7/18）。
##
## 三条硬规矩：
##   1) 进度只用真实数据：`WebShaderWarmup.done_count()` / `total_count()`，也就是
##      **已完成张数**。没有数据就不显示（`has_plan()` 为假时整条收起来），不按时间
##      估算、不补假动画 —— 数值不动就是没动。
##   2) 不增加卡顿：每帧只做两次 int 比较，数值真的变了才 set_text / 改条子；不构造
##      节点、不换字体、不让容器重排。预热结束立刻 `set_process(false)` 并淡出。
##   3) 不挡操作：整条 `mouse_filter = IGNORE`（场景里逐节点写明），菜单全程可点。

## 文案口径：说明"在等什么"和"为什么值得等"，不承诺任何时间。
const CAPTION := "正在预编译着色器（首次进入较慢，之后会快很多）"
## 玩家点了「开始游戏」、预热还没完时按钮上的文案（带真实计数）。
const PENDING_BUTTON_TEXT := "正在准备着色器 %d/%d…"

@onready var _caption: Label = %Caption
@onready var _count: Label = %Count
@onready var _bar: ProgressBar = %Bar

## 上一次渲染的计数。用它做"数值变化才刷新"的闸门。
var _last_done := -1
var _last_total := -1
var _finishing := false
## 被占用的「开始游戏」按钮（只在等待期间存在）。
var _pending_button: Button = null
var _pending_label: Label = null
var _pending_idle_text := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _caption == null or _count == null or _bar == null:
		# 必须通过 web_shader_progress.tscn 实例化（静态节点，运行期不建控件）。
		push_error("WebShaderProgress 必须通过 web_shader_progress.tscn 实例化。")
		visible = false
		set_process(false)
		return
	_caption.text = CAPTION
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	# step=0：条子按 done/total 的连续比例走，不被 Range 的整数步进吃掉。
	_bar.step = 0.0
	_bar.value = 0.0
	# 可见性 = 「预热正在跑」且「清单已建好」。少了任一条就没有真实进度可显示，
	# 整条收起来，绝不画 0/0、也不做假进度。
	if not WebShaderWarmup.is_running() or not WebShaderWarmup.has_plan():
		visible = false
		set_process(false)
		return
	set_counts(WebShaderWarmup.done_count(), WebShaderWarmup.total_count())
	if WebShaderWarmup.is_finished():
		# 极端情况：条子建好时预热刚好结束。不闪一下，直接不显示。
		visible = false
		set_process(false)
		return
	WebTelemetry.emit("warmup_ui", {
		"phase": "show",
		"total": WebShaderWarmup.total_count(),
		"done": WebShaderWarmup.done_count(),
	})
	WebTelemetry.flush()


func _process(_delta: float) -> void:
	if WebShaderWarmup.is_finished():
		_finish()
		return
	set_counts(WebShaderWarmup.done_count(), WebShaderWarmup.total_count())


## 唯一的渲染入口：把两个**真实计数**画出来。数值没变就什么都不做
## —— 这是"不增加卡顿"的核心：一帧两次 int 比较，没有排版、没有字符串重建。
## done/total 只来自 `WebShaderWarmup`（真机逐张编译完才会 +1）。
func set_counts(done: int, total: int) -> void:
	if done == _last_done and total == _last_total:
		return
	_last_done = done
	_last_total = total
	_count.text = "%d/%d" % [done, total]
	_bar.value = 0.0 if total <= 0 else clampf(float(done) / float(total), 0.0, 1.0)
	if _pending_button != null and is_instance_valid(_pending_button):
		_set_pending_button_text(PENDING_BUTTON_TEXT % [done, total])


## 「开始游戏」被点下而预热还没完：按钮进入明确状态（禁用 + 带计数的文案）。
## 同一条进度继续由 `set_counts()` 推进 —— 调用方 `await` 的是逐帧出帧的
## `WebShaderWarmup.await_ready()`，所以这不是忙等，UI 照常重绘。
func bind_pending_button(button: Button) -> void:
	if button == null or not is_instance_valid(button):
		return
	if _pending_button == button:
		return
	_pending_button = button
	# 主菜单按钮的可见文字在装饰层里（Content/Row/Label），
	# 直接改 `button.text` 会把这行字压在装饰文字上面。
	_pending_label = button.get_node_or_null("Content/Row/Label") as Label
	_pending_idle_text = _pending_label.text if _pending_label != null else button.text
	button.disabled = true
	_set_pending_button_text(PENDING_BUTTON_TEXT % [
		maxi(_last_done, 0), maxi(_last_total, 0)])


## 预热结束 / 开局已排队：把按钮还原成玩家点之前的样子。幂等（重复调用安全）。
func release_pending_button() -> void:
	if _pending_button != null and is_instance_valid(_pending_button):
		_pending_button.disabled = false
	if _pending_label != null and is_instance_valid(_pending_label):
		_pending_label.text = _pending_idle_text
	_pending_button = null
	_pending_label = null


func _set_pending_button_text(text_value: String) -> void:
	if _pending_label != null and is_instance_valid(_pending_label):
		_pending_label.text = text_value
	elif _pending_button != null and is_instance_valid(_pending_button):
		_pending_button.text = text_value


## 预热完成：先还按钮，再淡出。之后不再有逐帧回调。
func _finish() -> void:
	if _finishing:
		return
	_finishing = true
	set_process(false)
	# 最后一次把终值推上去（最后一张的 +1 和 _finished 是同一时刻发生的）。
	set_counts(WebShaderWarmup.done_count(), WebShaderWarmup.total_count())
	release_pending_button()
	WebTelemetry.emit("warmup_ui", {
		"phase": "hide",
		"done": _last_done,
		"total": _last_total,
		"sum_shader_ms": WebShaderWarmup.total_ms(),
	})
	WebTelemetry.flush()
	if UIAnimation.reduced_motion() or not is_inside_tree():
		visible = false
		return
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 0.0, UITokens.ANIM_SLOW)
	tween.tween_callback(func() -> void: visible = false)
