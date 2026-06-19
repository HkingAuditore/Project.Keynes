# map_camera.gd
# 地图浏览相机：统一处理 桌面（鼠标 + 键盘）与 移动端（触摸 + 捏合）交互。
#
# 桌面：
#   - 左键 / 右键 / 中键 拖拽平移（区分点按与拖拽：仅"点按"才发出 tile_tapped 选格）
#   - 滚轮平滑缩放（锚定鼠标位置）
#   - 键盘 +/- 缩放（锚定视口中心）
#   - 双击放大（锚定鼠标位置）
#   - 拖拽松手后带惯性滑动
#
# 移动端：
#   - 单指拖拽平移（经 emulate_mouse_from_touch 走鼠标路径，统一逻辑）
#   - 单指点按选格、双击放大
#   - 双指捏合缩放（锚定双指中心）+ 双指中心平移
#   - 多指手势期间屏蔽模拟鼠标，避免误平移 / 误选格
#
# 用法：作为主场景的 Camera2D，调用 set_world_bounds(rect) 限制可视范围；
#       连接 tile_tapped(world_pos) 信号做地块选择；
#       选中后用 ensure_point_visible(world_pos, safe_area) 在不重置缩放的前提下把地块移出 UI 遮挡。

class_name MapCamera
extends Camera2D

# 当用户"点按"（而非拖拽/捏合）地图时发出，参数为世界坐标。由 main.gd 连接做选格。
signal tile_tapped(world_pos: Vector2)

@export var zoom_min: float = 0.25
@export var zoom_max: float = 3.0
@export var zoom_step: float = 1.15
@export var pan_button: MouseButton = MOUSE_BUTTON_RIGHT
# 缩放平滑速度（越大越快到位）。滚轮/键盘缩放走平滑插值，捏合走即时跟手。
@export var zoom_smooth_speed: float = 14.0
# 拖拽松手后的惯性
@export var pan_inertia_enabled: bool = true
@export var pan_friction: float = 7.0          # 惯性衰减系数（越大停得越快）
@export var pan_inertia_min_speed: float = 6.0 # 低于此速度（世界单位/秒）直接停下
# 点按判定：移动小于阈值且时间短，才算 tap（否则视为拖拽，不选格）
@export var tap_max_move_px: float = 10.0
@export var tap_max_time: float = 0.35
# 双击/双指轻点放大
@export var double_tap_time: float = 0.30
@export var double_tap_zoom_factor: float = 1.8
# 键盘缩放每次的倍率
@export var key_zoom_step: float = 1.25

var _world_bounds: Rect2 = Rect2()

# ── 平滑缩放状态 ──
var _target_zoom: Vector2 = Vector2.ONE
var _zoom_anchor_screen: Vector2 = Vector2.ZERO

# ── 鼠标/单指平移与点按状态 ──
var _pan_active: bool = false          # 是否正在用鼠标按键拖拽平移
var _press_active: bool = false        # 左键/单指是否按下（用于 tap 判定）
var _press_screen: Vector2 = Vector2.ZERO
var _press_time_ms: int = 0
var _press_moved: float = 0.0          # 按下后累计移动像素

# ── 惯性 ──
var _pan_velocity: Vector2 = Vector2.ZERO   # 世界单位/秒
var _prev_position: Vector2 = Vector2.ZERO
var _measuring_pan: bool = false

# ── 平滑聚焦动画（ensure_point_visible 使用）──
var _pan_anim_active: bool = false
var _pan_anim_target: Vector2 = Vector2.ZERO

# ── 双击放大 ──
var _last_tap_time_ms: int = 0
var _last_tap_screen: Vector2 = Vector2.ZERO

# ── 触摸/捏合 ──
var _touches: Dictionary = {}          # finger index -> 屏幕坐标
var _pinching: bool = false
var _pinch_last_dist: float = 0.0
var _pinch_last_mid: Vector2 = Vector2.ZERO
# 多指手势守卫：本次按压周期内出现过多指时置位，松手 tap 时据此屏蔽误选格
var _multitouch_guard: bool = false

func _ready() -> void:
	make_current()
	_target_zoom = zoom
	_prev_position = position
	set_process(true)

func set_world_bounds(bounds: Rect2) -> void:
	_world_bounds = bounds
	_clamp_position()

func center_on_bounds() -> void:
	if _world_bounds.size == Vector2.ZERO:
		return
	_stop_motion()
	position = _world_bounds.position + _world_bounds.size * 0.5

func fit_to_viewport(margin: float = 1.05, safe_area: Rect2 = Rect2()) -> void:
	# 用户主动"适配/重置视图"时调用（Fit 按钮 / 首次生成）。会重置缩放与位置。
	if _world_bounds.size == Vector2.ZERO:
		return
	_stop_motion()
	var vp_size := get_viewport_rect().size
	var area: Rect2 = safe_area
	if area.size.x <= 0.0 or area.size.y <= 0.0:
		area = Rect2(Vector2.ZERO, vp_size)
	var sx := area.size.x / (_world_bounds.size.x * margin)
	var sy := area.size.y / (_world_bounds.size.y * margin)
	var s := clampf(minf(sx, sy), zoom_min, zoom_max)
	zoom = Vector2(s, s)
	_target_zoom = zoom
	# 让 safe_area 的中心对齐世界 bounds 的中心
	var world_center := _world_bounds.position + _world_bounds.size * 0.5
	var vp_center := vp_size * 0.5
	var area_center := area.position + area.size * 0.5
	var screen_offset := area_center - vp_center
	position = world_center - screen_offset / s
	_clamp_position()

# 在不改变缩放的前提下，若目标点被 UI（safe_area 之外）遮挡，则平滑平移把它移到可见区中心。
# 已经可见时不动相机，避免每次选格都跳动。
func ensure_point_visible(world_pos: Vector2, safe_area: Rect2) -> void:
	if safe_area.size.x <= 0.0 or safe_area.size.y <= 0.0:
		return
	var screen := _world_to_screen(world_pos)
	# 留一点内边距，避免地块贴着面板边缘
	var inset := safe_area.grow(-32.0)
	if inset.size.x <= 0.0 or inset.size.y <= 0.0:
		inset = safe_area
	if inset.has_point(screen):
		return
	var vp_center := get_viewport_rect().size * 0.5
	var target_screen := safe_area.position + safe_area.size * 0.5
	# 求让 world_pos 落在 target_screen 处的相机位置
	var new_pos := world_pos - (target_screen - vp_center) / zoom
	_pan_anim_target = _clamped_position(new_pos)
	_pan_anim_active = true
	_pan_velocity = Vector2.ZERO

# ───────────────────────────── 每帧平滑 ─────────────────────────────

func _process(delta: float) -> void:
	_update_zoom(delta)
	_update_pan_anim(delta)
	_update_inertia(delta)

func _update_zoom(delta: float) -> void:
	if zoom.is_equal_approx(_target_zoom):
		return
	var t := clampf(zoom_smooth_speed * delta, 0.0, 1.0)
	var nz := lerpf(zoom.x, _target_zoom.x, t)
	if absf(nz - _target_zoom.x) < 0.0008:
		nz = _target_zoom.x
	_apply_zoom_anchored(nz, _zoom_anchor_screen)

func _update_pan_anim(delta: float) -> void:
	if not _pan_anim_active:
		return
	var t := clampf(zoom_smooth_speed * delta, 0.0, 1.0)
	position = position.lerp(_pan_anim_target, t)
	if position.distance_to(_pan_anim_target) < 0.5:
		position = _pan_anim_target
		_pan_anim_active = false
	_clamp_position()

func _update_inertia(delta: float) -> void:
	# 拖拽中：测量速度供松手后惯性使用
	if _measuring_pan:
		if delta > 0.0:
			var v := (position - _prev_position) / delta
			# 平滑速度，避免单帧抖动
			_pan_velocity = _pan_velocity.lerp(v, 0.5)
		_prev_position = position
		return
	if not pan_inertia_enabled:
		return
	if _pan_velocity.length() <= pan_inertia_min_speed:
		_pan_velocity = Vector2.ZERO
		return
	var before := position
	position += _pan_velocity * delta
	_clamp_position()
	# 撞到边界时清除对应方向速度，避免在边界处"粘滞"
	if not is_equal_approx(position.x, before.x + _pan_velocity.x * delta):
		_pan_velocity.x = 0.0
	if not is_equal_approx(position.y, before.y + _pan_velocity.y * delta):
		_pan_velocity.y = 0.0
	# 指数衰减
	_pan_velocity *= exp(-pan_friction * delta)

# ───────────────────────────── 输入分发 ─────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)
	elif event is InputEventMagnifyGesture:
		# 触控板/部分平台的捏合手势
		var mg := event as InputEventMagnifyGesture
		_set_target_zoom(_target_zoom.x * mg.factor, mg.position)
	elif event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		_stop_inertia()
		position += pg.delta * 12.0 / zoom
		_clamp_position()
	elif event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		_handle_key(event as InputEventKey)

# 键盘 +/- 缩放（锚定视口中心）。与 main.gd 的功能热键不冲突。
func _handle_key(k: InputEventKey) -> void:
	if not k.pressed or k.echo:
		return
	var center := get_viewport_rect().size * 0.5
	match k.keycode:
		KEY_EQUAL, KEY_KP_ADD:
			_set_target_zoom(_target_zoom.x * key_zoom_step, center)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_set_target_zoom(_target_zoom.x / key_zoom_step, center)

# ── 鼠标（含移动端单指模拟）──

func _handle_mouse_button(mb: InputEventMouseButton) -> void:
	# 多指捏合期间，屏蔽模拟鼠标，避免误平移/误选格
	if _pinching:
		return
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed:
				_set_target_zoom(_target_zoom.x * zoom_step, mb.position)
		MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_set_target_zoom(_target_zoom.x / zoom_step, mb.position)
		MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_press(mb.position)
				_begin_pan()
			else:
				_end_pan()
				_end_press(mb.position)
		_:
			# 右键/中键（pan_button 及中键）：纯平移，不参与 tap 选格
			if mb.button_index == pan_button or mb.button_index == MOUSE_BUTTON_MIDDLE:
				if mb.pressed:
					_begin_pan()
				else:
					_end_pan()

func _handle_mouse_motion(mm: InputEventMouseMotion) -> void:
	if _pinching:
		return
	if not _pan_active:
		return
	position -= mm.relative / zoom
	_clamp_position()
	if _press_active:
		_press_moved += mm.relative.length()

# ── 触摸：仅用于多指捏合 + 守卫，单指交给模拟鼠标 ──

func _handle_screen_touch(t: InputEventScreenTouch) -> void:
	if t.pressed:
		_touches[t.index] = t.position
	else:
		_touches.erase(t.index)
	var count := _touches.size()
	if count >= 2:
		_pinching = true
		_multitouch_guard = true
		_stop_inertia()
		_pan_anim_active = false
		_pinch_last_dist = _touch_distance()
		_pinch_last_mid = _touch_midpoint()
	else:
		_pinching = false
	# 注意：_multitouch_guard 不在这里随 count==0 复位。
	# 因为松手时模拟鼠标的 release 与 ScreenTouch release 在同一输入批次，
	# 顺序不定；若此处提前清零，捏合结束后可能误触发一次 tap。
	# 守卫改为在下一次"全新单指/单键按下"时复位（见 _begin_press）。

func _handle_screen_drag(d: InputEventScreenDrag) -> void:
	if _touches.has(d.index):
		_touches[d.index] = d.position
	if _touches.size() < 2:
		return  # 单指拖拽交给模拟鼠标路径处理
	var dist := _touch_distance()
	var mid := _touch_midpoint()
	if _pinch_last_dist > 1.0:
		var factor := dist / _pinch_last_dist
		var target := clampf(zoom.x * factor, zoom_min, zoom_max)
		# 捏合即时跟手（不走平滑），并锚定双指中心
		_apply_zoom_anchored(target, mid)
		_target_zoom = zoom
		# 双指中心移动 → 平移
		position -= (mid - _pinch_last_mid) / zoom
		_clamp_position()
	_pinch_last_dist = dist
	_pinch_last_mid = mid

# ───────────────────────────── 平移 / 点按辅助 ─────────────────────────────

func _begin_pan() -> void:
	_pan_active = true
	_pan_anim_active = false
	_stop_inertia()
	_measuring_pan = true
	_prev_position = position
	_pan_velocity = Vector2.ZERO

func _end_pan() -> void:
	_pan_active = false
	_measuring_pan = false
	# _pan_velocity 已在 _update_inertia 测得，松手后自然进入惯性

func _begin_press(screen_pos: Vector2) -> void:
	_press_active = true
	_press_screen = screen_pos
	_press_time_ms = Time.get_ticks_msec()
	_press_moved = 0.0
	# 全新的单指/单键按下：复位多指守卫（此刻最多 1 个触点）
	if _touches.size() <= 1:
		_multitouch_guard = false

func _end_press(screen_pos: Vector2) -> void:
	if not _press_active:
		return
	_press_active = false
	var dt_ms := Time.get_ticks_msec() - _press_time_ms
	var moved := maxf(_press_moved, screen_pos.distance_to(_press_screen))
	# 多指手势期间松手不算点按
	if _multitouch_guard:
		return
	# 拖拽（移动过大或耗时过长）不算点按
	if moved > tap_max_move_px or dt_ms > int(tap_max_time * 1000.0):
		return
	# 双击 / 双指轻点 → 放大；否则发出点按选格
	var now := Time.get_ticks_msec()
	if now - _last_tap_time_ms <= int(double_tap_time * 1000.0) \
			and screen_pos.distance_to(_last_tap_screen) <= tap_max_move_px * 2.0:
		_set_target_zoom(_target_zoom.x * double_tap_zoom_factor, screen_pos)
		_last_tap_time_ms = 0  # 消费掉，避免三击连放
		return
	_last_tap_time_ms = now
	_last_tap_screen = screen_pos
	tile_tapped.emit(_screen_to_world(screen_pos, zoom.x))

# ───────────────────────────── 缩放数学 ─────────────────────────────

func _set_target_zoom(target_scalar: float, screen_anchor: Vector2) -> void:
	var t := clampf(target_scalar, zoom_min, zoom_max)
	if is_equal_approx(t, _target_zoom.x):
		return
	_target_zoom = Vector2(t, t)
	_zoom_anchor_screen = screen_anchor
	_pan_anim_active = false  # 缩放时取消聚焦动画，避免互相打架

func _apply_zoom_anchored(new_scalar: float, screen_anchor: Vector2) -> void:
	var old := zoom.x
	if is_equal_approx(new_scalar, old):
		return
	var vp_center := get_viewport_rect().size * 0.5
	var world_before := position + (screen_anchor - vp_center) / old
	zoom = Vector2(new_scalar, new_scalar)
	var world_after := position + (screen_anchor - vp_center) / new_scalar
	position += world_before - world_after
	_clamp_position()

# ───────────────────────────── 坐标 / 工具 ─────────────────────────────

func _screen_to_world(screen: Vector2, z: float) -> Vector2:
	var vp_center := get_viewport_rect().size * 0.5
	return position + (screen - vp_center) / z

func _world_to_screen(world: Vector2) -> Vector2:
	var vp_center := get_viewport_rect().size * 0.5
	return vp_center + (world - position) * zoom.x

func _touch_distance() -> float:
	var pts := _touches.values()
	if pts.size() < 2:
		return 0.0
	return (pts[0] as Vector2).distance_to(pts[1] as Vector2)

func _touch_midpoint() -> Vector2:
	var pts := _touches.values()
	if pts.size() < 2:
		return Vector2.ZERO
	return ((pts[0] as Vector2) + (pts[1] as Vector2)) * 0.5

func _stop_inertia() -> void:
	_pan_velocity = Vector2.ZERO

func _stop_motion() -> void:
	_pan_velocity = Vector2.ZERO
	_pan_anim_active = false
	_measuring_pan = false

func _clamped_position(p: Vector2) -> Vector2:
	if _world_bounds.size == Vector2.ZERO:
		return p
	var half_view := get_viewport_rect().size * 0.5 / zoom
	var min_p := _world_bounds.position + half_view
	var max_p := _world_bounds.position + _world_bounds.size - half_view
	var out := p
	if min_p.x > max_p.x:
		out.x = _world_bounds.position.x + _world_bounds.size.x * 0.5
	else:
		out.x = clampf(p.x, min_p.x, max_p.x)
	if min_p.y > max_p.y:
		out.y = _world_bounds.position.y + _world_bounds.size.y * 0.5
	else:
		out.y = clampf(p.y, min_p.y, max_p.y)
	return out

func _clamp_position() -> void:
	if _world_bounds.size == Vector2.ZERO:
		return
	position = _clamped_position(position)
