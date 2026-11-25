extends Control
class_name CellHoverCard

## 地图格子的悬停信息卡：羊皮纸小档案，跟随鼠标，只回答四件事
## 「这是什么 / 归谁 / 有多少人 / 有什么」。
##
## 为什么不用 MapCamera 发信号：PlayerController 把 MouseMotion 整个交给相机并
## 立刻 set_input_as_handled()，业务层收不到；而指针移到右侧面板后 GUI 会吃掉
## motion，相机更收不到——恰恰是这时卡片最需要消失。所以这里用 _input 置脏 +
## _process 节流的轮询：隐藏时不跑 process，唤醒只靠 _input。
##
## 内容只在 cache_key（格 : 日 : 归属槽）变化时重建；跟手只写 position。

signal payload_applied(cell_index: int)
## 当前悬停格变化（-1 = 指针不在任何可出信息的格子上）。
## 地图地名层与左侧展板都靠这条信号对齐同一格，避免三处各自解析指针。
signal hover_cell_changed(cell_index: int)

const CARD_SIZE := Vector2(320.0, 176.0)
const POINTER_OFFSET := Vector2(16.0, 18.0)
const EDGE_MARGIN := 6.0

## 最近一次指针移动后停稳多久才解析新格；扫图时不出卡。
const SETTLE_MSEC := 130
## 指针超过此速度视为"正在扫图"，卡片先退场。
const FAST_MOVE_PX_PER_SEC := 900.0
## 可见但指针静止时，仍定期复检脚下的格子（惯性滑动、缩放都会改变它）。
const REVALIDATE_MSEC := 250
const MOVE_EPSILON_PX := 2.0
const IDLE_SLEEP_MSEC := 1200
## 与 UITokens.MAP_ACTIVITY_MIN_ZOOM 同口径：再小就没有可读的单格了。
const MIN_ZOOM := 0.35

## ── 移动端触摸长按 ──
## 按住多久算长按。取 380ms：必须大于相机判 tap 的 tap_max_time（map_camera.gd:48 = 0.35s），
## 这样够格出卡的那一次按压在松手时必然已经超时，不会再被相机判成一次选格 tap；
## 又短于 Android 系统长按的 500ms，手感不发钝。
const TOUCH_LONG_PRESS_MSEC := 380
## 长按期间手指允许的抖动半径。取 12px：单指静止的真实抖动 3-8px，比鼠标的
## MOVE_EPSILON_PX(2px) 粗得多；而相机判 tap 的位移上限是 10px（移动端 ×1.8 = 18px）。
## 12px 正好夹在两者之间：轻微抖动照常出卡，真拖拽先让卡片退场。
const TOUCH_SLOP_PX := 12.0
## 卡片底边离按下点的高度：手指接触圆约 22px，留 56px 卡面才不会压住指尖。
const TOUCH_LIFT_PX := 56.0

const FADE_IN_SEC := 0.14
const FADE_OUT_SEC := 0.09
const SETTLE_SCALE := 0.965
const FADE_OUT_SCALE := 0.985

const SHADOW_COLOR := Color(0.10, 0.07, 0.04, 0.18)

var _map: MapData
var _camera: MapCamera
var _hex_size: float = 22.0
var _view_model: CellHoverViewModel
var _blocked: Callable
var _safe_area: Callable

var _suppressed := false
var _saw_touch := false
## 触摸长按态。_saw_touch 只回答"刚才那次是触摸还是真鼠标"，用来压制悬停路径；
## 下面这组变量承担长按本身的状态机，只由真实 InputEventScreenTouch 驱动。
var _touch_ids: Dictionary = {}
var _touch_press := false
var _touch_hold := false
var _touch_down_index := -1
var _touch_down_at := Vector2.ZERO
var _touch_down_ms := 0
var _dirty := true
var _dismissing := false
var _shown_key := ""
var _shown_cell := -1
var _emitted_cell := -1
var _payload: Dictionary = {}
## 需要避让的矩形（左侧悬停展板）：卡片不许压在它上面，否则两块浮层互相遮挡。
var _avoid_rect := Rect2()

var _last_motion_ms := 0
var _last_input_ms := 0
var _last_resolve_ms := 0
var _pointer_speed := 0.0
var _last_pointer := Vector2(-1, -1)

var _tween: Tween

@onready var _shadow: PanelContainer = $Shadow
@onready var _paper: PanelContainer = $Paper
@onready var _title: Label = $Paper/Body/Header/Text/Title
@onready var _country_icon: IconBadge = $Paper/Body/Header/Text/CountryRow/Icon
@onready var _country_name: Label = $Paper/Body/Header/Text/CountryRow/Name
@onready var _region: Label = $Paper/Body/Header/Region
@onready var _tags: Array[Label] = [
	$Paper/Body/TagRow/Tag1, $Paper/Body/TagRow/Tag2, $Paper/Body/TagRow/Tag3]
@onready var _pop_label: Label = $Paper/Body/PopRow/PopLabel
@onready var _pop_value: Label = $Paper/Body/PopRow/Value
@onready var _pop_unit: Label = $Paper/Body/PopRow/Unit
@onready var _tier_badge: PanelContainer = $Paper/Body/PopRow/TierBadge
@onready var _tier_text: Label = $Paper/Body/PopRow/TierBadge/Text
@onready var _chips: Array[PanelContainer] = [
	$Paper/Body/ResourceRow/Chip1, $Paper/Body/ResourceRow/Chip2,
	$Paper/Body/ResourceRow/Chip3]
@onready var _species_row: HFlowContainer = $Paper/Body/SpeciesRow

@onready var _resource_note: Label = $Paper/Body/ResourceRow/Note


func _ready() -> void:
	# DossierChart 等基类会把 mouse_filter 设成 PASS；卡片必须永久穿透，
	# 否则 320×176 会吃掉整块地图的点击与拖拽。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 暂停菜单打开时也要能自己隐藏，否则会冻结在画面上。
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	modulate.a = 1.0
	scale = Vector2.ONE
	size = CARD_SIZE
	_apply_shadow_style()
	set_process(false)


func _apply_shadow_style() -> void:
	if _paper == null or _shadow == null:
		return
	var paper_style := _paper.get_theme_stylebox("panel")
	if paper_style == null:
		return
	# StyleBox 是主题共享资源：不 duplicate 会把所有 PKPaperPopup 一起调暗。
	var shadow_style := paper_style.duplicate()
	if shadow_style is StyleBoxTexture:
		(shadow_style as StyleBoxTexture).modulate_color = SHADOW_COLOR
	_shadow.add_theme_stylebox_override("panel", shadow_style)


func configure(map: MapData, camera: MapCamera, hex_size: float,
		view_model: CellHoverViewModel, blocked: Callable, safe_area: Callable) -> void:
	_map = map
	_camera = camera
	_hex_size = hex_size
	_view_model = view_model
	_blocked = blocked
	_safe_area = safe_area
	reset_for_world()


func reset_for_world() -> void:
	dismiss(true)
	_payload.clear()
	_shown_key = ""
	_shown_cell = -1
	_dirty = true
	_saw_touch = false
	_touch_ids.clear()
	_abort_touch(false)
	_pointer_speed = 0.0
	_last_pointer = Vector2(-1, -1)


func set_suppressed(suppressed: bool) -> void:
	_suppressed = suppressed
	if suppressed:
		_abort_touch(false)
		dismiss(true)


## 由左侧展板在显隐时推送：空矩形表示当前没有需要避让的浮层。
func set_avoid_rect(rect: Rect2) -> void:
	if rect != _avoid_rect:
		_avoid_rect = rect
		_dirty = true


func current_cell_index() -> int:
	return _shown_cell


## 只在真的换格时发信号：dismiss() 会被每帧的抑制路径重复调用，
## 每次都广播会让下游展板与地名层跟着空转。
func _sync_hover_cell_signal() -> void:
	if _shown_cell == _emitted_cell:
		return
	_emitted_cell = _shown_cell
	hover_cell_changed.emit(_shown_cell)


func payload() -> Dictionary:
	return _payload


# ───────────────────────────── 输入 ─────────────────────────────

func _input(event: InputEvent) -> void:
	if _suppressed:
		return
	if event is InputEventScreenTouch:
		_on_screen_touch(event as InputEventScreenTouch)
		return
	if event is InputEventScreenDrag:
		_on_screen_drag(event as InputEventScreenDrag)
		return
	if event is InputEventMagnifyGesture or event is InputEventPanGesture:
		# 触控板捏合 / 双指拖移：等同"视野在动"。真鼠标不会发这两类事件，
		# 所以只在触摸态下动作，桌面轨迹一行不改。
		if _touch_press or _touch_hold:
			_abort_touch(true)
		return
	if event is not InputEventMouseMotion:
		return
	if _touch_press or _touch_hold:
		var probe := event as InputEventMouseMotion
		# 真鼠标接手：桌面上用 emulate_touch_from_mouse 自测完长按，鼠标一动就交回悬停路径。
		if probe.device != -1:
			_abort_touch(true)
	var motion := event as InputEventMouseMotion
	# device == -1 是触摸被 emulate_mouse_from_touch 合成的鼠标事件。
	if motion.device == -1:
		_saw_touch = true
		_on_touch_moved(motion.position)
		return
	_saw_touch = false
	var now := Time.get_ticks_msec()
	var delta_ms := maxf(float(now - _last_motion_ms), 8.0)
	var moved := motion.position.distance_to(_last_pointer)
	_pointer_speed = motion.relative.length() / (delta_ms / 1000.0)
	_last_motion_ms = now
	_last_input_ms = now
	if moved >= MOVE_EPSILON_PX or _last_pointer.x < 0.0:
		_dirty = true
		_last_pointer = motion.position
	if not is_processing():
		set_process(true)


# ───────────────────────────── 触摸长按 ─────────────────────────────
#
# 口径：移动端长按出卡，tap 仍归相机（player_controller._unhandled_input 的选格逻辑），
# 本文件只旁观事件、绝不 set_input_as_handled / accept_event，卡片本身 MOUSE_FILTER_IGNORE。

func _on_screen_touch(t: InputEventScreenTouch) -> void:
	_saw_touch = true
	_last_input_ms = Time.get_ticks_msec()
	if t.pressed:
		_touch_ids[t.index] = true
		if _touch_ids.size() > 1:
			# 第二根手指落下：让给相机做捏合，卡片不上场。
			_abort_touch(true)
			return
		if visible or _touch_hold:
			# 新一轮触摸按下：上一张钉住的卡先收掉。
			_touch_hold = false
			dismiss(true)
		_touch_press = true
		_touch_down_index = t.index
		_touch_down_at = t.position
		_touch_down_ms = _last_input_ms
		if not is_processing():
			set_process(true)
		return
	_touch_ids.erase(t.index)
	if t.index != _touch_down_index:
		return
	# 松手：长按已出卡就留着（手指一抬卡就没了等于没做）；没出卡就作废本次按压，
	# 事件原样留给相机做 tap 判定。
	_touch_down_index = -1
	_touch_press = false


func _on_screen_drag(d: InputEventScreenDrag) -> void:
	_saw_touch = true
	_last_input_ms = Time.get_ticks_msec()
	if d.index == _touch_down_index:
		_on_touch_moved(d.position)
	elif _touch_press or _touch_hold:
		# 不属于当前按压的那根手指（捏合的另一指）在动：视野在动，卡片退场。
		_abort_touch(true)


## 手指位移判定：超过 TOUCH_SLOP_PX 就是拖拽平移，不是长按。
func _on_touch_moved(pos: Vector2) -> void:
	if _touch_down_index < 0 or not (_touch_press or _touch_hold):
		# 没有进行中的按压：触摸在移，悬停路径没有任何可指向的东西。
		dismiss(true)
		return
	if pos.distance_to(_touch_down_at) > TOUCH_SLOP_PX:
		_abort_touch(true)


func _abort_touch(dismiss_card: bool) -> void:
	_touch_press = false
	_touch_hold = false
	_touch_down_index = -1
	if dismiss_card:
		dismiss(true)


## 由 _process 在触摸态下调用。单指按住时相机的 _pan_active 恒为真（模拟鼠标按下就会
## _begin_pan，见 map_camera.gd:331），所以这里不能用 is_panning() 判"手在动"，
## 只能靠 _on_touch_moved 的位移容差。
func _process_touch(now: int) -> void:
	if get_tree().paused or (_blocked.is_valid() and bool(_blocked.call())):
		_abort_touch(true)
		return
	if _map == null or _camera == null or _view_model == null:
		_abort_touch(true)
		return
	if _touch_press:
		# 按住未到时长：只等计时，不解析、不出卡。
		if not _safe_rect().has_point(_touch_down_at) or _camera.zoom.x < MIN_ZOOM:
			_abort_touch(false)
			return
		if now - _touch_down_ms < TOUCH_LONG_PRESS_MSEC:
			return
		_show_touch_card(now)
		return
	if _touch_down_index >= 0:
		# 手指还按着（长按刚出卡）：这一段相机的 _pan_active 恒为真，不能拿它判"视野在动"，
		# 手有没有走开已经由 _on_touch_moved 的 TOUCH_SLOP_PX 容差盯着了。
		return
	# 手指已抬、卡钉在原处：只认缩放动画；其余（下一次触摸/拖拽/捏合/切世界/暂停）各有入口。
	if _camera.is_zooming() or _camera.zoom.x < MIN_ZOOM:
		_abort_touch(true)


## 长按出卡：把"按下点"喂进桌面同一条解析链
## （safe_screen_to_world → world_to_wrapped_cell → is_cell_available → build）。
func _show_touch_card(now: int) -> void:
	var anchor := _touch_down_at
	var safe := _safe_rect()
	var world := _camera.safe_screen_to_world(anchor)
	var cell: HexCell = HexUtils.world_to_wrapped_cell(_map, world, _hex_size)
	if cell == null or int(cell.index) < 0 or not is_cell_available(int(cell.index)):
		_abort_touch(true)
		return
	var built := _view_model.build(cell)
	if not bool(built.get("ok", false)):
		_abort_touch(true)
		return
	# 一次按压只解析这一帧：手指不动、格子不变，后面几帧保持原样。
	_touch_press = false
	_touch_hold = true
	_dirty = false
	_last_resolve_ms = now
	apply_payload(built)
	var rect := placement_rect_for_touch(anchor, get_viewport_rect().size, safe, size)
	if rect.size == Vector2.ZERO:
		_abort_touch(true)
		return
	rect.position = avoid_overlap(rect.position, size, _avoid_rect, safe)
	position = rect.position


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# 失焦时可能永远收不到那根手指的松手事件，触点表必须一起清，否则 _touch_ids
		# 残留会让下一次单指按下被误判成多指手势、长按从此失效。
		_touch_ids.clear()
		_abort_touch(false)
		dismiss(true)


# ───────────────────────────── 轮询 ─────────────────────────────

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if get_tree().paused or _suppressed:
		dismiss(true)
		_sleep_if_idle(now)
		return
	if _blocked.is_valid() and bool(_blocked.call()):
		dismiss(true)
		_sleep_if_idle(now)
		return
	# 触摸长按态必须排在下一行的 is_panning / _saw_touch 之前分流：单指按住不动时
	# 相机的 _pan_active 一直为真，走下面那条会把刚出的卡立刻打掉。
	if _touch_press or _touch_hold:
		_process_touch(now)
		_sleep_if_idle(now)
		return
	if _saw_touch or _camera == null or _map == null or _view_model == null:
		dismiss(false)
		_sleep_if_idle(now)
		return
	if _camera.is_panning() or _camera.is_zooming():
		dismiss(false)
		_sleep_if_idle(now)
		return
	if _camera.zoom.x < MIN_ZOOM:
		dismiss(false)
		_sleep_if_idle(now)
		return

	var screen := get_viewport().get_mouse_position()
	var safe := _safe_rect()
	if not safe.has_point(screen):
		dismiss(false)
		_sleep_if_idle(now)
		return
	if _is_ui_hit(get_viewport().gui_get_hovered_control()):
		dismiss(false)
		_sleep_if_idle(now)
		return

	# 「快速移动」只在这一段静止时间内有约束力：指针已经停稳 130ms 后，
	# 上一次记录的瞬时速度就是过期数据了。否则「甩一下鼠标再停住」会因为
	# 速度值再也不会被刷新，把卡片永久锁死。
	if _pointer_speed > FAST_MOVE_PX_PER_SEC and now - _last_motion_ms < SETTLE_MSEC:
		dismiss(false)
		_sleep_if_idle(now)
		return
	if now - _last_motion_ms < SETTLE_MSEC:
		_sleep_if_idle(now)
		return

	var world := _camera.safe_screen_to_world(screen)
	var cell: HexCell = HexUtils.world_to_wrapped_cell(_map, world, _hex_size)
	if cell == null or int(cell.index) < 0 or not is_cell_available(int(cell.index)):
		dismiss(false)
		_sleep_if_idle(now)
		return

	if not VisionSolver.displayed_fields_current(_map):
		if _shown_cell == cell.index and visible:
			_move_to(screen, safe)
		else:
			dismiss(false)
		return
	if not _dirty and now - _last_resolve_ms < REVALIDATE_MSEC:
		_move_to(screen, safe)
		_sleep_if_idle(now)
		return

	_dirty = false
	_last_resolve_ms = now
	var payload := _view_model.build(cell)
	if not bool(payload.get("ok", false)):
		dismiss(false)
		_sleep_if_idle(now)
		return
	if visible and _shown_key == String(payload.get("cache_key", "")):
		_move_to(screen, safe)
		_sleep_if_idle(now)
		return
	apply_payload(payload)
	_move_to(screen, safe)
	_sleep_if_idle(now)


func _sleep_if_idle(now: int) -> void:
	# 可见时绝不休眠：面板/弹窗/暂停可能在指针完全静止的情况下打开，
	# 一旦停掉轮询卡片就会赖在屏幕上不走。
	if visible:
		return
	if now - _last_input_ms < IDLE_SLEEP_MSEC:
		return
	set_process(false)


func _is_ui_hit(control: Control) -> bool:
	if control == null:
		return false
	var node: Node = control
	while node != null:
		if node == self:
			return false
		if node is Control:
			var c := node as Control
			if c.is_visible_in_tree() and c.mouse_filter != Control.MOUSE_FILTER_IGNORE:
				return true
		node = node.get_parent()
	return false


## 只有当前可见的格子才配一张卡：未探索与"记得但看不见"都会泄露情报。
func is_cell_available(idx: int) -> bool:
	return VisionSolver.displayed_cell_visible(_map, idx)


func _safe_rect() -> Rect2:
	if _safe_area.is_valid():
		var rect = _safe_area.call()
		if rect is Rect2 and (rect as Rect2).size.x > 0.0:
			return rect as Rect2
	return get_viewport_rect()


func _move_to(screen: Vector2, safe: Rect2) -> void:
	var rect := placement_rect(screen, get_viewport_rect().size, safe, size)
	if rect.size == Vector2.ZERO:
		dismiss(true)
		return
	rect.position = avoid_overlap(rect.position, size, _avoid_rect, safe)
	position = rect.position


## 与避让矩形相交时，把卡片推到它右侧；右边放不下再退到左侧；两边都放不下就
## 保持原位（宁可重叠也不飞出屏幕）。
static func avoid_overlap(origin: Vector2, size: Vector2, avoid: Rect2,
		safe: Rect2) -> Vector2:
	if avoid.size.x <= 0.0 or avoid.size.y <= 0.0:
		return origin
	if not Rect2(origin, size).intersects(avoid):
		return origin
	var right := avoid.end.x + POINTER_OFFSET.x
	if right + size.x <= safe.end.x - EDGE_MARGIN:
		return Vector2(right, origin.y)
	var left := avoid.position.x - size.x - POINTER_OFFSET.x
	if left >= safe.position.x + EDGE_MARGIN:
		return Vector2(left, origin.y)
	return origin


static func fits_right_of(edge: float, safe: Rect2, card_width: float = CARD_SIZE.x) -> bool:
	return edge + POINTER_OFFSET.x + card_width <= safe.end.x - EDGE_MARGIN


## 指针右下偏移；右侧/下方不够就翻到另一侧，最后夹进安全区。
## 安全区比卡片还小（极小窗口）时返回空矩形 = 不出卡。
static func placement_rect(pointer: Vector2, viewport: Vector2, safe: Rect2, card_size: Vector2 = CARD_SIZE) -> Rect2:
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return Rect2()
	if safe.size.x < card_size.x + EDGE_MARGIN * 2.0 \
			or safe.size.y < card_size.y + EDGE_MARGIN * 2.0:
		return Rect2()
	var pos := pointer + POINTER_OFFSET
	if pos.x + card_size.x > safe.end.x:
		pos.x = pointer.x - card_size.x - POINTER_OFFSET.x
	if pos.y + card_size.y > safe.end.y:
		pos.y = pointer.y - card_size.y - POINTER_OFFSET.y
	pos.x = clampf(pos.x, safe.position.x + EDGE_MARGIN, safe.end.x - card_size.x - EDGE_MARGIN)
	pos.y = clampf(pos.y, safe.position.y + EDGE_MARGIN, safe.end.y - card_size.y - EDGE_MARGIN)
	return Rect2(pos, card_size)


## 触摸长按专用摆位：水平居中于按下点，并整体抬到按下点上方 TOUCH_LIFT_PX，
## 让卡面不压住手指（口径 5）。上方放不下就翻到按下点下方；安全区塞不进卡片 = 不出卡。
## 桌面悬停仍走 placement_rect，本函数只被 _show_touch_card 调用。
static func placement_rect_for_touch(pointer: Vector2, viewport: Vector2, safe: Rect2,
		card_size: Vector2 = CARD_SIZE) -> Rect2:
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return Rect2()
	if safe.size.x < card_size.x + EDGE_MARGIN * 2.0 \
			or safe.size.y < card_size.y + EDGE_MARGIN * 2.0:
		return Rect2()
	var above := pointer.y - TOUCH_LIFT_PX - card_size.y
	var below := pointer.y + TOUCH_LIFT_PX
	var fits_above := above >= safe.position.y + EDGE_MARGIN
	var fits_below := below + card_size.y <= safe.end.y - EDGE_MARGIN
	var y := above
	if not fits_above and fits_below:
		y = below
	var pos := Vector2(pointer.x - card_size.x * 0.5, y)
	pos.x = clampf(pos.x, safe.position.x + EDGE_MARGIN, safe.end.x - card_size.x - EDGE_MARGIN)
	pos.y = clampf(pos.y, safe.position.y + EDGE_MARGIN, safe.end.y - card_size.y - EDGE_MARGIN)
	return Rect2(pos, card_size)


# ───────────────────────────── 渲染 ─────────────────────────────

func apply_payload(new_payload: Dictionary, animate: bool = true) -> void:
	if not bool(new_payload.get("ok", false)):
		dismiss(true)
		return
	var key := String(new_payload.get("cache_key", ""))
	var same_key := key == _shown_key
	_payload = new_payload
	_shown_key = key
	_shown_cell = int(new_payload.get("cell_index", -1))

	_title.text = String(new_payload.get("title", ""))
	_region.text = String(new_payload.get("region", ""))
	_country_name.text = String(new_payload.get("country_name", ""))
	_country_icon.set_semantic(&"metric.territory",
		UITokens.DOSSIER_UMBER if bool(new_payload.get("country_owned", false)) \
			else UITokens.DOSSIER_INK_MUTED)

	_apply_tags(new_payload.get("tags", []))
	_apply_population(new_payload)
	_apply_resources(new_payload)
	_apply_species(new_payload.get("species", []))

	_sync_hover_cell_signal()
	payload_applied.emit(_shown_cell)
	if not visible:
		_show(animate)
	elif same_key:
		_pulse_header()


func _apply_tags(tags: Array) -> void:
	for i in _tags.size():
		var label := _tags[i]
		if i >= tags.size():
			label.visible = false
			continue
		var tag: Dictionary = tags[i]
		label.text = String(tag.get("name", ""))
		label.visible = not label.text.is_empty()
		var tick := label.get_node_or_null("Tick") as ColorRect
		if tick != null:
			tick.color = tag.get("color", UITokens.DOSSIER_UMBER)
			tick.visible = label.visible


func _apply_population(new_payload: Dictionary) -> void:
	var settled := bool(new_payload.get("settled", false))
	_pop_value.text = String(new_payload.get("population_text", ""))
	# 「无人定居」这类文案用 20px 竖排数字会喧宾夺主，退到与标签同级的小字。
	_pop_value.add_theme_font_size_override("font_size", 20 if settled else 13)
	_pop_value.add_theme_color_override("font_color",
		UITokens.DOSSIER_INK if settled else UITokens.DOSSIER_INK_MUTED)
	_pop_unit.visible = settled
	_pop_unit.text = "人" if settled else ""
	var tier := String(new_payload.get("settlement_tier", ""))
	_tier_badge.visible = not tier.is_empty()
	_tier_text.text = tier
	# 原生进度未提交时拿到的是上一份好值：徽记降饱和，避免读者把它当成当日确数。
	var muted := bool(new_payload.get("tier_pending", false))
	_tier_text.modulate.a = 0.62 if muted else 1.0


func _apply_resources(new_payload: Dictionary) -> void:
	var rows: Array = new_payload.get("resources", [])
	for i in _chips.size():
		var chip := _chips[i]
		if i >= rows.size():
			chip.visible = false
			continue
		_apply_chip(chip, rows[i])
		chip.visible = true
	_resource_note.visible = rows.is_empty()
	_resource_note.text = String(new_payload.get("resource_note", ""))


## 保留图标槽；跨日刷新只改内容，避免快进时销毁节点。
func _apply_species(rows: Array) -> void:
	while _species_row.get_child_count() < rows.size():
		var entry := UIControlParts.h_box_container()
		entry.custom_minimum_size = Vector2(0, 20)
		entry.add_theme_constant_override("separation", 2)
		entry.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icon := IconBadge.new()
		icon.custom_minimum_size = Vector2(20, 20)
		entry.add_child(icon)
		var label := UIControlParts.label()
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.add_theme_font_size_override("font_size", 10)
		label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_SOFT)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		entry.add_child(label)
		_species_row.add_child(entry)
	for i in _species_row.get_child_count():
		var entry := _species_row.get_child(i) as HBoxContainer
		entry.visible = i < rows.size()
		if not entry.visible:
			continue
		var row: Dictionary = rows[i]
		(entry.get_child(0) as IconBadge).set_semantic(StringName(row.get("id", "")), UITokens.ECO)
		(entry.get_child(1) as Label).text = String(row.get("text", ""))
	_species_row.visible = not rows.is_empty()
	# 按内容宽度紧接排列，行数计算与 FlowContainer 的换行一致。
	var available_width := _paper.size.x - _paper.get_theme_stylebox("panel").get_minimum_size().x
	var line_width := 0.0
	var line_count := 0
	for entry in _species_row.get_children():
		if not entry.visible:
			continue
		var width: float = entry.get_combined_minimum_size().x
		var gap := float(_species_row.get_theme_constant("h_separation")) if line_width > 0.0 else 0.0
		if line_count == 0 or line_width + gap + width > available_width:
			line_count += 1
			line_width = width
		else:
			line_width += gap + width
	var extra_height := float(line_count * 20 + maxi(0, line_count - 1) * _species_row.get_theme_constant("v_separation"))
	custom_minimum_size = CARD_SIZE + Vector2(0, extra_height)
	size = custom_minimum_size
	_paper.offset_bottom = CARD_SIZE.y - 10.0 + extra_height
	_shadow.offset_bottom = CARD_SIZE.y - 7.0 + extra_height


func _apply_chip(chip: PanelContainer, row: Dictionary) -> void:
	var icon := chip.get_node("Line/Icon") as IconBadge
	if icon != null:
		icon.set_semantic(StringName(row.get("icon", &"economy.resource")),
			UITokens.DOSSIER_INK_SOFT)
	var name_label := chip.get_node("Line/Info/Name") as Label
	if name_label != null:
		name_label.text = String(row.get("name", ""))
	var density_label := chip.get_node("Line/Info/DensityRow/Density") as Label
	if density_label != null:
		density_label.text = String(row.get("density_name", ""))
	var pips := chip.get_node("Line/Info/DensityRow/Pips") as HBoxContainer
	if pips != null:
		var level := int(row.get("density_level", 0))
		for i in pips.get_child_count():
			var pip := pips.get_child(i) as ColorRect
			if pip != null:
				pip.color = UITokens.DOSSIER_BRASS if i < level else UITokens.DOSSIER_TRACK


# ───────────────────────────── 动画 ─────────────────────────────

func _show(animate: bool) -> void:
	_kill_tween()
	_dismissing = false
	visible = true
	if not animate or UIAnimation.reduced_motion():
		modulate.a = 1.0
		scale = Vector2.ONE
		return
	modulate.a = 0.0
	scale = Vector2.ONE * SETTLE_SCALE
	# 缩放锚点放在背离指针的那一角，视觉上"从指针旁展开"。
	pivot_offset = size - Vector2(8.0, 8.0)
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "modulate:a", 1.0, FADE_IN_SEC)
	_tween.tween_property(self, "scale", Vector2.ONE, FADE_IN_SEC)


func _pulse_header() -> void:
	if UIAnimation.reduced_motion():
		return
	var lead := $Paper/Body/Rule1/Lead as ColorRect
	if lead == null:
		return
	lead.modulate.a = 0.35
	var tween := create_tween()
	tween.tween_property(lead, "modulate:a", 1.0, 0.08)
	tween.tween_property(lead, "modulate:a", 0.75, 0.08)


func dismiss(immediate: bool = true) -> void:
	if not visible or _dismissing:
		_sync_hover_cell_signal()
		return
	_shown_key = ""
	_shown_cell = -1
	_sync_hover_cell_signal()
	if immediate or UIAnimation.reduced_motion():
		_kill_tween()
		visible = false
		_dismissing = false
		modulate.a = 1.0
		scale = Vector2.ONE
		return
	_dismissing = true
	_kill_tween()
	_tween = create_tween().set_parallel(true)
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_property(self, "modulate:a", 0.0, FADE_OUT_SEC)
	_tween.tween_property(self, "scale", Vector2.ONE * FADE_OUT_SCALE, FADE_OUT_SEC)
	_tween.chain().tween_callback(_finish_dismiss)


func _finish_dismiss() -> void:
	_dismissing = false
	visible = false
	modulate.a = 1.0
	scale = Vector2.ONE


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


# ───────────────────────────── 测试入口 ─────────────────────────────

## 截图 QA / 单测专用：绕过指针状态机，直接在指定屏幕位置显示某格。
## 正式流程不会调用它。
func debug_show_cell(cell_index: int, screen_pos: Vector2) -> bool:
	if _map == null or _view_model == null:
		return false
	var cell := _map.cell_at(cell_index)
	if cell == null:
		return false
	var built := _view_model.build(cell)
	if not bool(built.get("ok", false)):
		return false
	apply_payload(built, false)
	modulate.a = 1.0
	scale = Vector2.ONE
	var rect := placement_rect(screen_pos, get_viewport_rect().size, _safe_rect(), size)
	if rect.size == Vector2.ZERO:
		dismiss(true)
		return false
	position = rect.position
	return visible
