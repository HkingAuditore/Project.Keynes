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

const CARD_SIZE := Vector2(320.0, 184.0)
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
var _dirty := true
var _dismissing := false
var _shown_key := ""
var _shown_cell := -1
var _payload: Dictionary = {}

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
@onready var _resource_note: Label = $Paper/Body/ResourceRow/Note


func _ready() -> void:
	# DossierChart 等基类会把 mouse_filter 设成 PASS；卡片必须永久穿透，
	# 否则 320×184 会吃掉整块地图的点击与拖拽。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 暂停菜单打开时也要能自己隐藏，否则会冻结在画面上。
	process_mode = PROCESS_MODE_ALWAYS
	visible = false
	modulate.a = 1.0
	scale = Vector2.ONE
	size = CARD_SIZE
	_apply_shadow_style()
	set_process(false)
	if OS.has_feature("mobile"):
		set_process_input(false)


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
	_pointer_speed = 0.0
	_last_pointer = Vector2(-1, -1)


func set_suppressed(suppressed: bool) -> void:
	_suppressed = suppressed
	if suppressed:
		dismiss(true)


func current_cell_index() -> int:
	return _shown_cell


func payload() -> Dictionary:
	return _payload


# ───────────────────────────── 输入 ─────────────────────────────

func _input(event: InputEvent) -> void:
	if _suppressed:
		return
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		_saw_touch = true
		dismiss(true)
		return
	if event is not InputEventMouseMotion:
		return
	var motion := event as InputEventMouseMotion
	# device == -1 是触摸被 emulate_mouse_from_touch 合成的鼠标事件。
	if motion.device == -1:
		_saw_touch = true
		dismiss(true)
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


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
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
	if idx < 0 or idx >= _map.visible_arr.size():
		return false
	if int(_map.visible_arr[idx]) == 0:
		return false
	return VisionSolver.fog_state(_map, idx) == VisionSolver.FOG_VISIBLE


func _safe_rect() -> Rect2:
	if _safe_area.is_valid():
		var rect = _safe_area.call()
		if rect is Rect2 and (rect as Rect2).size.x > 0.0:
			return rect as Rect2
	return get_viewport_rect()


func _move_to(screen: Vector2, safe: Rect2) -> void:
	var rect := placement_rect(screen, get_viewport_rect().size, safe)
	if rect.size == Vector2.ZERO:
		dismiss(true)
		return
	position = rect.position


## 指针右下偏移；右侧/下方不够就翻到另一侧，最后夹进安全区。
## 安全区比卡片还小（极小窗口）时返回空矩形 = 不出卡。
static func placement_rect(pointer: Vector2, viewport: Vector2, safe: Rect2) -> Rect2:
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return Rect2()
	if safe.size.x < CARD_SIZE.x + EDGE_MARGIN * 2.0 \
			or safe.size.y < CARD_SIZE.y + EDGE_MARGIN * 2.0:
		return Rect2()
	var pos := pointer + POINTER_OFFSET
	if pos.x + CARD_SIZE.x > safe.end.x:
		pos.x = pointer.x - CARD_SIZE.x - POINTER_OFFSET.x
	if pos.y + CARD_SIZE.y > safe.end.y:
		pos.y = pointer.y - CARD_SIZE.y - POINTER_OFFSET.y
	pos.x = clampf(pos.x, safe.position.x + EDGE_MARGIN, safe.end.x - CARD_SIZE.x - EDGE_MARGIN)
	pos.y = clampf(pos.y, safe.position.y + EDGE_MARGIN, safe.end.y - CARD_SIZE.y - EDGE_MARGIN)
	return Rect2(pos, CARD_SIZE)


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
	pivot_offset = Vector2(CARD_SIZE.x - 8.0, CARD_SIZE.y - 8.0)
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
		return
	_shown_key = ""
	_shown_cell = -1
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
	var rect := placement_rect(screen_pos, get_viewport_rect().size, _safe_rect())
	if rect.size == Vector2.ZERO:
		dismiss(true)
		return false
	position = rect.position
	return visible
