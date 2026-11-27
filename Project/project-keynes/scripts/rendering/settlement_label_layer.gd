extends Node2D
class_name SettlementLabelLayer

## 地图上的地名层。三件事：
##   1. 常年可见的聚落地名，按繁荣等级（= 人口档）与首都地位分档显示。
##   2. LOD：拉远只留少数几个大城，放大才放出小城；首都任何时候都在。
##   3. 悬停某一格时，该格地名以纸签形式在地块上方浮起。
##
## 保留式更新：地块的世界坐标固定，所以标签位置只在分配槽位时写一次，
## 之后随相机变换自动跟随；每帧只处理「进出视野 / 缩放换档 / 视野变化」。
## 这样平移时不会整层重建，缩放换档时的进出用淡入淡出而不是瞬移。

const DESKTOP_CAP := 128
const MOBILE_CAP := 64

## 屏幕像素口径：标签尺寸与抬升量都不随缩放变，缩放只通过 1/zoom 缩放系数抵消。
const MINOR_FONT_SIZE := 15
const MAJOR_FONT_SIZE := 15
const CAPITAL_FONT_SIZE := 17
const MINOR_PAD_X := 4.0
const MINOR_PAD_Y := 2.0
const TAG_PAD_X := 10.0
const TAG_PAD_Y := 4.0
const LABEL_LIFT := 16.0
const LABEL_GAP := 2.0

## 屏幕占用预算：远看只放得下十几枚，放大后才有空间铺开，也才有意义铺开。
const BUDGET_FAR := 14
const BUDGET_MID := 26
const BUDGET_NEAR := 44
const BUDGET_CLOSE := 72

## 缩放换档阈值与既有实现同口径（测试锁定）。
const ZOOM_FAR := 0.45
const ZOOM_MID := 0.75
const ZOOM_NEAR := 1.2

## 首都加分足以越过任何一档 LOD：它不参与「谁能显示」的筛选。
const CAPITAL_BONUS := 100

const FADE_IN_SEC := 0.16
const FADE_OUT_SEC := 0.12
const HOVER_FADE_IN_SEC := 0.14
const HOVER_FADE_OUT_SEC := 0.09
const HOVER_RISE_PX := 7.0

const HOVER_Z_INDEX := 13
# 聚居地名要压在建筑体（z 3）、天气（4）、数据覆盖（5）、边界（6）之上，
# 但仍让选中高亮（10）与战争迷雾（12）盖住它。
const LABEL_Z_INDEX := 7
const SEAL_CAPACITY := 8

var _map: MapData
var _camera: Camera2D
var _facade
var _hex_size := 22.0
var _wrap_period_x := 0.0
var _fog_enabled := false
var _revision := -1
var _settlements: Dictionary = {}
var _row_cells: Dictionary = {}
var _pool: Array[Label] = []
var _slot_cell := PackedInt32Array()
var _slot_key: Array[String] = []
var _slot_style: Array[StringName] = []
var _slot_tweens: Array = []
var _last_camera_position := Vector2.INF
var _last_zoom := -1.0
var _last_viewport_size := Vector2.ZERO
var _last_canvas_transform := Transform2D.IDENTITY
var _dirty := true
var _player_capital_cell := -1
var _hover_cell := -1

var _hover_label: Label
var _hover_tween: Tween
var _hover_shown := false
var _hover_rise_px := 0.0
var _hover_style: StringName = &""
var _seal_pool: Array[Node2D] = []
var _tag_style: StyleBoxTexture

# 帧尾诊断：最近一次 _rebuild_visible_labels 墙钟（毫秒）。tick 日 sync_from_runtime
# 会无条件置 dirty，所以重建成本逐日计入 perf 的 tail_label_ms 列。
var _last_rebuild_ms: float = 0.0
var _last_rebuild_label_count: int = 0


func _ready() -> void:
	# Rebuild against the visibility installed by RuntimeHost in this frame.
	process_priority = 1
	# Absolute z only; the layer keeps inheriting HexRenderer's transform so
	# labels stay in world coordinates.
	z_as_relative = false
	z_index = LABEL_Z_INDEX
	_build_tag_style()


func configure(map: MapData, camera: Camera2D, facade, hex_size: float,
		wrap_period_x: float, fog_enabled: bool) -> void:
	_map = map
	_camera = camera
	_facade = facade
	_hex_size = hex_size
	_wrap_period_x = wrap_period_x
	_fog_enabled = fog_enabled
	_ensure_pool(MOBILE_CAP if OS.has_feature("mobile") else DESKTOP_CAP)
	sync_from_runtime(true)
	set_process(true)


func set_fog_enabled(enabled: bool) -> void:
	if _fog_enabled == enabled:
		return
	_fog_enabled = enabled
	_dirty = true


func mark_visibility_dirty() -> void:
	_dirty = true


## 首都格不参与 LOD 筛选：任何缩放档位都留它的名字。
func set_player_capital_cell(cell_index: int) -> void:
	if _player_capital_cell == cell_index:
		return
	_player_capital_cell = cell_index
	_dirty = true


func player_capital_cell() -> int:
	return _player_capital_cell


## 悬停卡转发：-1 表示指针已离开可能带名字的格子。
func set_hover_cell(cell_index: int) -> void:
	if _hover_cell == cell_index:
		return
	_hover_cell = cell_index
	_dirty = true
	_update_hover_label()


func sync_from_runtime(force_full: bool = false) -> void:
	if _facade == null:
		return
	var packet: Dictionary
	if force_full or _revision < 0:
		packet = _facade.named_settlement_snapshot()
	else:
		packet = _facade.settlement_delta(_revision)
	if not bool(packet.get("ok", false)):
		return
	if bool(packet.get("full_snapshot", false)):
		_settlements.clear()
		_row_cells.clear()
	var cells: PackedInt32Array = packet.get("cell_indices", PackedInt32Array())
	var tiers: PackedByteArray = packet.get("prosperity_tiers", PackedByteArray())
	var active: PackedByteArray = packet.get("name_active", PackedByteArray())
	var names: PackedStringArray = packet.get("settlement_names", PackedStringArray())
	for index in range(cells.size()):
		var cell := int(cells[index])
		if index >= active.size() or active[index] == 0:
			_remove_from_row(cell)
			_settlements.erase(cell)
		elif index < tiers.size() and index < names.size():
			_settlements[cell] = {
				"tier": int(tiers[index]),
				"name": String(names[index]),
			}
			_add_to_row(cell)
	_revision = int(packet.get("revision", _revision))
	if bool(packet.get("full_snapshot", false)) or not cells.is_empty():
		_dirty = true


func _process(_delta: float) -> void:
	if _camera == null or _map == null:
		return
	var zoom_value := _camera.zoom.x
	var viewport_size := get_viewport_rect().size
	var canvas_transform := get_viewport().get_canvas_transform()
	if _camera.position.distance_squared_to(_last_camera_position) > 4.0 \
			or not is_equal_approx(zoom_value, _last_zoom) \
			or not viewport_size.is_equal_approx(_last_viewport_size) \
			or not canvas_transform.is_equal_approx(_last_canvas_transform):
		_last_camera_position = _camera.position
		_last_zoom = zoom_value
		_last_viewport_size = viewport_size
		_last_canvas_transform = canvas_transform
		_dirty = true
	if _dirty:
		var rebuild_started_usec := Time.get_ticks_usec()
		_rebuild_visible_labels()
		_last_rebuild_ms = float(Time.get_ticks_usec() - rebuild_started_usec) / 1000.0
	# 悬停标签走单独通道：它不在碰撞与预算里，也不该让整层重建。
	_update_hover_label()


func get_last_rebuild_ms() -> float:
	return _last_rebuild_ms


func get_last_rebuild_label_count() -> int:
	return _last_rebuild_label_count


## 当前缩放档允许的最低繁荣等级。等级即人口档（2=乡村 3=小镇 4=县城 5=城市 6=都市），
## 所以「远看只显示少数几个」与「远看只显示大城」是同一件事。
static func minimum_tier_for_zoom(zoom_value: float) -> int:
	if zoom_value < ZOOM_FAR:
		return 5
	if zoom_value < ZOOM_MID:
		return 4
	if zoom_value < ZOOM_NEAR:
		return 3
	return 2


static func budget_for_zoom(zoom_value: float) -> int:
	if zoom_value < ZOOM_FAR:
		return BUDGET_FAR
	if zoom_value < ZOOM_MID:
		return BUDGET_MID
	if zoom_value < ZOOM_NEAR:
		return BUDGET_NEAR
	return BUDGET_CLOSE


func _rebuild_visible_labels() -> void:
	_dirty = false
	var zoom_value := maxf(_camera.zoom.x, 0.001)
	var minimum_tier := minimum_tier_for_zoom(zoom_value)
	var budget := mini(budget_for_zoom(zoom_value), _pool.size())
	var viewport_rect := get_viewport_rect().grow(48.0)
	var canvas_transform := get_viewport().get_canvas_transform()
	var candidates: Array[Dictionary] = []
	var half_world_height := viewport_rect.size.y * 0.5 / zoom_value
	var row_step := maxf(1.0, _hex_size * 1.5)
	var first_row := clampi(floori(
		(_camera.position.y - half_world_height) / row_step) - 2,
		0, maxi(0, _map.height - 1))
	var last_row := clampi(ceili(
		(_camera.position.y + half_world_height) / row_step) + 2,
		first_row, maxi(first_row, _map.height - 1))
	var visible_cells: Array[int] = []
	for map_row in range(first_row, last_row + 1):
		var row_bucket: Dictionary = _row_cells.get(map_row, {})
		for raw_cell in row_bucket:
			visible_cells.append(int(raw_cell))
	for cell_idx in visible_cells:
		var row: Dictionary = _settlements[cell_idx]
		var tier := int(row.tier)
		var capital := cell_idx == _player_capital_cell
		# 悬停中的格子由纸签顶着，常驻标签让位，免得同一句地名出现两次。
		if cell_idx == _hover_cell:
			continue
		if not capital and tier < minimum_tier:
			continue
		if _fog_enabled and (cell_idx >= _map.visible_arr.size()
				or _map.visible_arr[cell_idx] == 0):
			continue
		var cell := _map.cell_at(cell_idx)
		if cell == null:
			continue
		var world_position := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
		# 环向地图只取离相机最近的那一份拷贝：最近的都出屏，其余只会更远，
		# 所以每个聚落最多只有一枚地名，不会在地图接缝上出现两份同名纸签。
		world_position = HexUtils.nearest_display_world(
			world_position, _camera.position.x, _wrap_period_x)
		var screen_position: Vector2 = canvas_transform * world_position
		if not viewport_rect.has_point(screen_position):
			continue
		var name := String(row.name)
		var style := _style_for(tier, capital)
		var metrics := _label_metrics(name, style)
		candidates.append({
			"cell": cell_idx,
			"name": name,
			"style": style,
			"capital": capital,
			"world": world_position,
			"screen": screen_position,
			"size": metrics["size"],
			"importance": tier + (CAPITAL_BONUS if capital else 0),
			"distance": world_position.distance_squared_to(_camera.position),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.importance) != int(b.importance):
			return int(a.importance) > int(b.importance)
		if not is_equal_approx(float(a.distance), float(b.distance)):
			return float(a.distance) < float(b.distance)
		return int(a.cell) < int(b.cell))

	# 碰撞剔除：按重要度顺序占屏，被已占矩形压住的候选这一档就不出。
	# 槽位按「本轮第 N 名 → 第 N 槽」分配，排序几乎稳定，所以平移时槽位很少换人。
	var wanted: Array[Dictionary] = []
	var occupied: Array[Rect2] = []
	for candidate in candidates:
		if wanted.size() >= budget:
			break
		var size := candidate.size as Vector2
		var rect := Rect2(
			Vector2(candidate.screen) - Vector2(size.x * 0.5, size.y + LABEL_LIFT),
			size)
		var overlaps := false
		for other in occupied:
			if rect.intersects(other):
				overlaps = true
				break
		if overlaps:
			continue
		occupied.append(rect)
		wanted.append(candidate)

	var shown := mini(wanted.size(), _pool.size())
	for slot in range(_pool.size()):
		if slot >= shown:
			if _slot_cell[slot] >= 0:
				_slot_cell[slot] = -1
				_release_slot(slot)
			continue
		var candidate: Dictionary = wanted[slot]
		var key := str(int(candidate.cell))
		var appearing := String(_slot_key[slot]) != key
		_slot_cell[slot] = int(candidate.cell)
		_slot_key[slot] = key
		_place_label(slot, candidate, zoom_value, appearing)

	_place_seals(wanted, zoom_value)
	_last_rebuild_label_count = shown


func _style_for(tier: int, capital: bool) -> String:
	# 三档视觉：纸签大字（首都）/ 纸签（城市以上）/ 描边白字（小镇以下）。
	# 远看时留下的是前两档，所以「远看只显示少数几个」读起来就是纸签变少。
	if capital:
		return "capital"
	if tier >= 5:
		return "major"
	return "minor"


func _label_metrics(text: String, style: String) -> Dictionary:
	var font_size := MINOR_FONT_SIZE
	var pad := Vector2(MINOR_PAD_X, MINOR_PAD_Y)
	match style:
		"major":
			font_size = MAJOR_FONT_SIZE
			pad = Vector2(TAG_PAD_X, TAG_PAD_Y)
		"capital":
			font_size = CAPITAL_FONT_SIZE
			pad = Vector2(TAG_PAD_X + 2.0, TAG_PAD_Y)
	var font := UITokens.UI_FONT_BOLD if style != "minor" else UITokens.UI_FONT
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	var size := Vector2(maxf(text_size.x, 8.0) + pad.x * 2.0,
		maxf(text_size.y, float(font_size)) + pad.y * 2.0)
	if style == "capital":
		# 火漆印要落在纸签里侧，所以先给纸签留一枚印章宽，再居中放字。
		size.x += size.y * 0.72
	return {"size": size, "font": font, "font_size": font_size}


func _place_label(slot: int, candidate: Dictionary, zoom_value: float,
		appearing: bool) -> void:
	var label := _pool[slot]
	var name := String(candidate.name)
	var style := String(candidate.style)
	var metrics := _label_metrics(name, style)
	var size := metrics["size"] as Vector2
	if label.text != name:
		label.text = name
	label.size = size
	label.custom_minimum_size = size
	if appearing or _slot_style[slot] != StringName(style):
		_slot_style[slot] = StringName(style)
		label.add_theme_font_override("font", metrics["font"] as Font)
		label.add_theme_font_size_override("font_size", int(metrics["font_size"]))
		_apply_style(label, style)
	var world := candidate.world as Vector2
	label.position = world + Vector2(-size.x * 0.5,
		-size.y - LABEL_LIFT) / zoom_value
	label.scale = Vector2.ONE / zoom_value
	label.visible = true
	if appearing:
		_fade_in(slot)
	else:
		_ensure_alpha(label, 1.0)


func _apply_style(label: Label, style: String) -> void:
	if style == "minor":
		label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		label.add_theme_color_override("font_color", Color(0.98, 0.95, 0.86))
		label.add_theme_color_override("font_outline_color", Color(0.06, 0.05, 0.04, 0.75))
		# 描边只负责压住地形底色。3px 以上会把 15px 汉字的笔画糊成一团墨点，
		# 所以用 1px 描边 + 1px 投影换取笔画里的留白。
		label.add_theme_constant_override("outline_size", 2)
		label.add_theme_color_override("font_shadow_color", Color(0.04, 0.03, 0.02, 0.65))
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		return
	label.add_theme_constant_override("outline_size", 0)
	label.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if style == "capital" else UITokens.DOSSIER_INK)
	label.add_theme_stylebox_override("normal", _tag_stylebox())


func _build_tag_style() -> void:
	var texture := load("res://assets/ui/paper_aux_v1/cut_tag_v1.tres") as Texture2D
	if texture == null:
		return
	_tag_style = StyleBoxTexture.new()
	_tag_style.texture = texture
	_tag_style.texture_margin_left = 18.0
	_tag_style.texture_margin_top = 24.0
	_tag_style.texture_margin_right = 26.0
	_tag_style.texture_margin_bottom = 16.0
	_tag_style.expand_margin_left = 6.0
	_tag_style.expand_margin_top = 7.0
	_tag_style.expand_margin_right = 5.0
	_tag_style.expand_margin_bottom = 6.0
	_tag_style.content_margin_left = 2.0
	_tag_style.content_margin_top = 2.0
	_tag_style.content_margin_right = 2.0
	_tag_style.content_margin_bottom = 2.0


func _tag_stylebox() -> StyleBox:
	if _tag_style != null:
		return _tag_style
	var flat := StyleBoxFlat.new()
	flat.bg_color = UITokens.DOSSIER_PAPER
	flat.border_color = UITokens.DOSSIER_BRASS
	flat.set_border_width_all(1)
	flat.set_corner_radius_all(3)
	return flat


# ───────────────────────────── 淡入淡出 ─────────────────────────────

func _fade_in(slot: int) -> void:
	var label := _pool[slot]
	label.modulate.a = 0.0
	if UIAnimation.reduced_motion():
		label.modulate.a = 1.0
		return
	_kill_slot_tween(slot)
	var tween := label.create_tween()
	tween.tween_property(label, "modulate:a", 1.0, FADE_IN_SEC)
	_slot_tweens[slot] = tween


func _ensure_alpha(label: Label, alpha: float) -> void:
	label.modulate.a = alpha


func _release_slot(slot: int) -> void:
	if slot < 0 or slot >= _pool.size():
		return
	var label := _pool[slot]
	_slot_style[slot] = &""
	_slot_key[slot] = ""
	_kill_slot_tween(slot)
	if not label.visible:
		return
	if UIAnimation.reduced_motion():
		label.visible = false
		label.modulate.a = 1.0
		return
	var tween := label.create_tween()
	tween.tween_property(label, "modulate:a", 0.0, FADE_OUT_SEC)
	tween.tween_callback(func() -> void:
		label.visible = false
		label.modulate.a = 1.0)
	_slot_tweens[slot] = tween


func _kill_slot_tween(slot: int) -> void:
	if slot < 0 or slot >= _slot_tweens.size():
		return
	var tween = _slot_tweens[slot]
	if tween != null and is_instance_valid(tween) and (tween as Tween).is_valid():
		(tween as Tween).kill()
	_slot_tweens[slot] = null


# ───────────────────────────── 首都火漆印 ─────────────────────────────

## 首都的纸签盖一枚火漆印：地名读成「这是首都」不需要额外文字。
func _place_seals(wanted: Array[Dictionary], zoom_value: float) -> void:
	var used := 0
	for candidate in wanted:
		if not bool(candidate.capital):
			continue
		if used >= _seal_pool.size():
			break
		var seal := _seal_pool[used]
		var tag_size := candidate.size as Vector2
		var mark := float(CAPITAL_FONT_SIZE) * 0.86
		# 印章落在纸签右端留出的那一条里，垂直居中于纸签。
		seal.position = (candidate.world as Vector2) + Vector2(
			tag_size.x * 0.5 - mark - 5.0,
			-(tag_size.y + LABEL_LIFT) + (tag_size.y - mark) * 0.5) / zoom_value
		seal.scale = Vector2.ONE / zoom_value
		(seal as SealMark).set_mark_size(mark)
		seal.visible = true
		used += 1
	for index in range(used, _seal_pool.size()):
		_seal_pool[index].visible = false


# ───────────────────────────── 悬停纸签 ─────────────────────────────

func hover_label_visible() -> bool:
	return _hover_shown


func hover_label_text() -> String:
	return _hover_label.text if _hover_label != null else ""


func _update_hover_label() -> void:
	if _map == null or _camera == null:
		return
	if _hover_cell < 0 or not _settlements.has(_hover_cell):
		_hide_hover_label()
		return
	var row: Dictionary = _settlements[_hover_cell]
	var cell := _map.cell_at(_hover_cell)
	if cell == null:
		_hide_hover_label()
		return
	if _fog_enabled and (_hover_cell >= _map.visible_arr.size()
			or _map.visible_arr[_hover_cell] == 0):
		_hide_hover_label()
		return
	var name := String(row.name)
	if name.is_empty():
		_hide_hover_label()
		return
	_ensure_hover_nodes()
	var zoom_value := maxf(_camera.zoom.x, 0.001)
	var capital := _hover_cell == _player_capital_cell
	var style := "capital" if capital else "major"
	var metrics := _label_metrics(name, style)
	var size := metrics["size"] as Vector2
	var world := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	world = HexUtils.nearest_display_world(world, _camera.position.x, _wrap_period_x)
	var rest := world + Vector2(-size.x * 0.5, -size.y - LABEL_LIFT * 1.7) / zoom_value
	if _hover_label.text != name or _hover_style != StringName(style):
		_hover_style = StringName(style)
		_hover_label.text = name
		_hover_label.add_theme_font_override("font", metrics["font"] as Font)
		_hover_label.add_theme_font_size_override("font_size", int(metrics["font_size"]))
		_hover_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD \
			if capital else UITokens.DOSSIER_INK)
		_hover_label.add_theme_stylebox_override("normal", _tag_stylebox())
		_hover_label.size = size
		_hover_label.custom_minimum_size = size
		_hover_label.scale = Vector2.ONE / zoom_value
	_hover_label.scale = Vector2.ONE / zoom_value
	# 抬升量单独存一份再叠加，动画期间新目标位置也不会被每帧覆盖。
	_hover_label.position = rest + Vector2(0.0, _hover_rise_px / zoom_value)
	if not _hover_shown:
		_show_hover_label()


func _ensure_hover_nodes() -> void:
	if _hover_label == null:
		_hover_label = Label.new()
		_hover_label.name = "HoverName"
		_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hover_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_hover_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		_hover_label.z_as_relative = false
		_hover_label.z_index = HOVER_Z_INDEX
		_hover_label.visible = false
		add_child(_hover_label)


func _show_hover_label() -> void:
	_hover_shown = true
	_hover_label.visible = true
	_hover_label.modulate.a = 1.0
	if UIAnimation.reduced_motion():
		_hover_rise_px = 0.0
		return
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_rise_px = HOVER_RISE_PX
	_hover_label.modulate.a = 0.0
	_hover_tween = create_tween().set_parallel(true)
	_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(self, "_hover_rise_px", 0.0, HOVER_FADE_IN_SEC)
	_hover_tween.tween_property(_hover_label, "modulate:a", 1.0, HOVER_FADE_IN_SEC)


func _hide_hover_label() -> void:
	if _hover_label == null or not _hover_shown:
		return
	_hover_shown = false
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	if UIAnimation.reduced_motion():
		_hover_label.visible = false
		return
	_hover_tween = _hover_label.create_tween()
	_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_hover_tween.tween_property(_hover_label, "modulate:a", 0.0, HOVER_FADE_OUT_SEC)
	_hover_tween.tween_callback(func() -> void:
		_hover_label.visible = false
		_hover_label.modulate.a = 1.0)


# ───────────────────────────── 槽位池 ─────────────────────────────

func _ensure_pool(capacity: int) -> void:
	while _pool.size() < capacity:
		var label := Label.new()
		label.size = Vector2(176.0, 24.0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.add_theme_font_size_override("font_size", MINOR_FONT_SIZE)
		label.add_theme_color_override("font_color", Color(0.96, 0.93, 0.82))
		label.add_theme_color_override("font_outline_color", Color(0.04, 0.05, 0.07, 0.92))
		label.add_theme_constant_override("outline_size", 4)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.visible = false
		add_child(label)
		_pool.append(label)
		_slot_cell.append(-1)
		_slot_key.append("")
		_slot_style.append(&"")
		_slot_tweens.append(null)
	_seed_seals()


func _seed_seals() -> void:
	if not _seal_pool.is_empty():
		return
	for _index in SEAL_CAPACITY:
		var seal := SealMark.new()
		seal.visible = false
		add_child(seal)
		_seal_pool.append(seal)


func _add_to_row(cell_idx: int) -> void:
	if _map == null:
		return
	var cell := _map.cell_at(cell_idx)
	if cell == null:
		return
	var row_bucket: Dictionary = _row_cells.get(cell.r, {})
	row_bucket[cell_idx] = true
	_row_cells[cell.r] = row_bucket


func _remove_from_row(cell_idx: int) -> void:
	if _map == null:
		return
	var cell := _map.cell_at(cell_idx)
	if cell == null or not _row_cells.has(cell.r):
		return
	var row_bucket: Dictionary = _row_cells[cell.r]
	row_bucket.erase(cell_idx)
	if row_bucket.is_empty():
		_row_cells.erase(cell.r)
	else:
		_row_cells[cell.r] = row_bucket


## 火漆印：一枚纸上的朱红蜡封，只画在首都纸签旁边。
class SealMark extends Node2D:
	var _mark_size := 12.0

	func set_mark_size(value: float) -> void:
		if is_equal_approx(_mark_size, value):
			return
		_mark_size = value
		queue_redraw()

	func _draw() -> void:
		if _mark_size <= 0.0:
			return
		IconCatalog.draw_icon(self, &"decoration.wax_seal",
			Rect2(Vector2.ZERO, Vector2.ONE * _mark_size))
