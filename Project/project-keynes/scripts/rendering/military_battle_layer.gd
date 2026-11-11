extends Node2D
class_name MilitaryBattleLayer

## z=9 交战标记层：每条交战段在中点画一个双色进度环，会战时播放冲击波。
##
## 数据：get_military_render_snapshot 的 engagements（cell_a, cell_b,
## progress_q16, attacker_slot, battle）。cell_a/cell_b 是规范化后的相邻边
## (min, max)，中点 = 两个 hex 中心的中点；wrap 地图上按最近镜像取。
##
## 一个 MultiMesh（同 TradeActivityLayer 的做法），每个交战段一条实例：
##   INSTANCE_CUSTOM = (攻方进度 0..1, 会战脉冲年龄 0..1, 种子, 守方进度)
## 画法全在 military_battle_ring.gdshader 里，CPU 每帧只更新脉冲年龄，
## 不改实例矩阵。
##
## 会战：新增交战段时记为一次「会战触发」，脉冲年龄在 ~0.9 s 内走完；
## 交战段进度在一天内大幅变化也触发一次（会战结算的 Δp 跳变）。

const SHADER_PATH: String = "res://shaders/military_battle_ring.gdshader"
const BATTLE_DECAL_PATH: String = \
	"res://assets/military/map/military_battle_seal_v1.png"
const Z_INDEX := 9
const INSTANCE_CAP := 256
const BATTLE_PULSE_SECONDS := 0.9
const PROGRESS_JUMP_Q16 := 6000   # ~9% 单帧跳变视为一次会战结算

var _batch: MultiMeshInstance2D
var _material: ShaderMaterial
var _has_shader := false
var _enabled := true

var _map
var _camera: Camera2D
var _hex_size := 22.0
var _wrap := 0.0
var _aggregate_zoom := 0.35
var _wall_time := 0.0
var _camera_zoom := 1.0
var _fog_active := false
var _visible_cells := PackedByteArray()

var _count := 0
var _cell_a := PackedInt32Array()
var _cell_b := PackedInt32Array()
var _progress := PackedInt32Array()
var _attacker := PackedInt32Array()
var _pulse := PackedFloat32Array()
var _seen := PackedByteArray()
var _prev_progress := PackedInt32Array()
var _stats := {"engagements": 0, "visible": 0, "battles": 0}


func _ready() -> void:
	z_index = Z_INDEX
	top_level = true
	visible = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_ensure_batch()
	set_process(true)


func _ensure_batch() -> void:
	if _batch != null:
		return
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("MilitaryBattleLayer: missing shader %s" % SHADER_PATH)
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	var battle_decal := load(BATTLE_DECAL_PATH) as Texture2D
	if battle_decal != null:
		_material.set_shader_parameter("battle_decal", battle_decal)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = INSTANCE_CAP
	mm.visible_instance_count = 0
	_batch = MultiMeshInstance2D.new()
	_batch.name = "BattleRings"
	_batch.multimesh = mm
	_batch.texture = CountryBorderLayer.get_white_texture()
	_batch.material = _material
	add_child(_batch)
	_pulse.resize(INSTANCE_CAP)
	_pulse.fill(1.0)
	_seen.resize(INSTANCE_CAP)
	_seen.fill(0)
	_prev_progress.resize(INSTANCE_CAP)
	_prev_progress.fill(0)
	_has_shader = true


func configure(map, camera: Camera2D, hex_size: float, wrap_period_x: float) -> void:
	_ensure_batch()
	_map = map
	_camera = camera
	_hex_size = maxf(4.0, hex_size)
	_wrap = maxf(0.0, wrap_period_x)
	if _material != null:
		_material.set_shader_parameter("wrap_period_x", _wrap)


func set_player_slot(_slot: int) -> void:
	pass


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_update_visibility()


func set_aggregate_zoom(value: float) -> void:
	_aggregate_zoom = maxf(0.01, value)


func clear() -> void:
	_count = 0
	if _batch != null:
		_batch.multimesh.visible_instance_count = 0
		_batch.visible = false


## 来自 feed，同时带上本帧的迷雾可见性（交战标记只在 FOG_VISIBLE 显示）。
func set_engagements(cell_a: PackedInt32Array, cell_b: PackedInt32Array,
		progress_q16: PackedInt32Array, attacker_slot: PackedInt32Array,
		battle: PackedByteArray, visible_cells: PackedByteArray, fog_active: bool,
		attacker_cell: PackedInt32Array = PackedInt32Array()) -> void:
	_visible_cells = visible_cells
	_fog_active = fog_active
	_attacker_cell = attacker_cell
	var count := mini(cell_a.size(), INSTANCE_CAP)
	_count = count
	_cell_a = cell_a
	_cell_b = cell_b
	_progress = progress_q16
	_attacker = attacker_slot
	# 会战脉冲：新出现的交战段，或进度相对上一帧大幅跳变（会战结算的 Δp）。
	for i in count:
		var fresh := _seen[i] == 0
		var jump := 0
		if not fresh:
			jump = absi(int(progress_q16[i]) - int(_prev_progress[i]))
		if fresh or jump > PROGRESS_JUMP_Q16:
			_pulse[i] = 0.0
			_stats["battles"] = int(_stats["battles"]) + 1
		_prev_progress[i] = int(progress_q16[i])
		_seen[i] = 1
	for i in range(count, INSTANCE_CAP):
		_seen[i] = 0
	_refresh_instances()


func _cell_center(cell: int) -> Vector2:
	var cell_obj = _map.cell_at(cell) if _map != null else null
	if cell_obj == null:
		return Vector2(NAN, NAN)
	return HexUtils.cube_to_world(cell_obj.q, cell_obj.r, _hex_size)


func _frame_visible(i: int) -> bool:
	if not _fog_active or _visible_cells.is_empty():
		return true
	var a := _cell_a[i]
	var b := _cell_b[i]
	var a_ok := a >= 0 and a < _visible_cells.size() and _visible_cells[a] != 0
	var b_ok := b >= 0 and b < _visible_cells.size() and _visible_cells[b] != 0
	# 交战段横跨两边：参战方那一侧可见才画。only_attacker_side 为真时要求
	# 进攻方所在格可见（玩家只能看见自己在攻/被攻的那一场），否则任一端可见即可。
	if _attacker_visible_required:
		var attacker_cell := a
		if i < _attacker_cell.size() and _attacker_cell[i] >= 0:
			attacker_cell = _attacker_cell[i]
		return attacker_cell >= 0 and attacker_cell < _visible_cells.size() \
			and _visible_cells[attacker_cell] != 0
	return a_ok or b_ok


var _attacker_visible_required := true
var _attacker_cell := PackedInt32Array()


## 测试钩子：切换交战可见性判据。
func set_any_side_visible_for_tests(enabled: bool) -> void:
	_attacker_visible_required = not enabled


func _refresh_instances() -> void:
	if _batch == null or _map == null:
		return
	var mm := _batch.multimesh
	var emitted := 0
	var ref_x := NAN
	if _camera != null and is_instance_valid(_camera):
		ref_x = _camera.global_position.x
	var aggregate := _camera_zoom < _aggregate_zoom
	if _material != null:
		_material.set_shader_parameter("aggregate_mode", aggregate)
	for i in _count:
		if not _frame_visible(i):
			continue
		var ca := _cell_center(_cell_a[i])
		var cb := _cell_center(_cell_b[i])
		if is_nan(ca.x) or is_nan(cb.x):
			continue
		if not is_nan(ref_x) and _wrap > 0.0001:
			cb = HexUtils.nearest_display_world(cb, ca.x, _wrap)
			ca = HexUtils.nearest_display_world(ca, ref_x, _wrap)
			cb = HexUtils.nearest_display_world(cb, ca.x, _wrap)
		var mid := (ca + cb) * 0.5
		var radius := _hex_size * (0.40 if aggregate else 0.62)
		var tx := Transform2D(0.0, Vector2(radius * 2.0, radius * 2.0), 0.0, mid)
		mm.set_instance_transform_2d(emitted, tx)
		var p := clampf(float(_progress[i]) / 65536.0, 0.0, 1.0)
		mm.set_instance_custom_data(emitted, Color(p, _pulse[i], _seed(i), 0.0))
		emitted += 1
	mm.visible_instance_count = emitted
	_stats["engagements"] = _count
	_stats["visible"] = emitted
	_update_visibility()


func _seed(i: int) -> float:
	var h: int = (i * 2654435761) & 0xFFFFFF
	return float(h) / 16777215.0


func _update_visibility() -> void:
	visible = _enabled and _has_shader and _batch != null and _batch.visible


func _process(delta: float) -> void:
	_wall_time += delta
	if _material == null or _batch == null:
		return
	var vp := get_viewport()
	if vp != null:
		_camera_zoom = maxf(0.0001, vp.get_canvas_transform().get_scale().x)
	var aggregate := _camera_zoom < _aggregate_zoom
	var changed := false
	var pulse_dt := delta / BATTLE_PULSE_SECONDS
	for i in _count:
		if _pulse[i] < 1.0:
			_pulse[i] = minf(1.0, _pulse[i] + pulse_dt)
			changed = true
	_material.set_shader_parameter("wall_seconds", _wall_time)
	_material.set_shader_parameter("reduced_motion", UIAnimation.reduced_motion())
	_material.set_shader_parameter("battle_radius",
		_hex_size * (0.40 if aggregate else 0.62))
	_material.set_shader_parameter("aggregate_mode", aggregate)
	if changed or _count == 0:
		_refresh_instances()
	elif _batch.multimesh.visible_instance_count > 0:
		# 脉冲年龄滑动写回自定义数据（不重算位置）。
		var mm := _batch.multimesh
		var row := 0
		for i in _count:
			if not _frame_visible(i):
				continue
			var p := clampf(float(_progress[i]) / 65536.0, 0.0, 1.0)
			mm.set_instance_custom_data(row, Color(p, _pulse[i], _seed(i), 0.0))
			row += 1


func debug_snapshot() -> Dictionary:
	var out := _stats.duplicate()
	out["visible_layer"] = visible
	out["count"] = _count
	return out
