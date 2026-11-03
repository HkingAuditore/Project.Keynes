extends Node2D
class_name MilitaryOccupationLayer

## z=5 占领层：被占领格画占领者国色的斜纹。
##
## 复用 DataOverlay 的间接寻址：静态 cell-index atlas（map_index_atlas 的
## G/B 是 cell index）→ 每格一个 texel 的 RG8/RGBA8 LUT。LUT 只在
## control_revision 变化时重传（设计稿 §14.1「只在控制有变化时上传」），
## 其余帧只有一次 atlas + 一次 LUT 采样。
##
## 与 DataOverlayLayer 的差别：本层不参与玩家 overlay 模式切换，
## 永远画（有占领时），因此可见性只看「有没有占领格」。
##
## LUT 通道：
##   R = 占领者 slot（0 表示无；slot 0 的占领写 255 以免与「空」冲突）
##   G = 斜纹强度（满 = 255）
##   B = 占领者与所有者差异（用于线宽抖动）
##   A = 255 = 该格被占领

const SHADER_PATH: String = "res://shaders/military_occupation_hatch.gdshader"
const Z_INDEX := 5

var _mesh_inst: MeshInstance2D
var _material: ShaderMaterial
var _has_shader := false
var _lut_tex: ImageTexture
var _lut_image: Image
var _lut_buf := PackedByteArray()
var _lut_dims := Vector2i.ONE
var _bounds := Rect2()
var _wrap := 0.0
var _uploaded_revision := -1
var _cell_count := 0
var _occupier := PackedInt32Array()
var _cell_stamp := PackedInt32Array()
var _stamp := 0
var _occupied_count := 0
var _stats := {"lut_uploads": 0, "occupied_cells": 0, "upload_bytes": 0, "last_upload_usec": 0}


func _ready() -> void:
	z_index = Z_INDEX
	top_level = true
	visible = false
	_ensure_nodes()


func _ensure_nodes() -> void:
	if _mesh_inst != null:
		return
	_mesh_inst = MeshInstance2D.new()
	_mesh_inst.name = "OccupationQuad"
	_mesh_inst.texture = CountryBorderLayer.get_white_texture()
	add_child(_mesh_inst)
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_warning("MilitaryOccupationLayer: missing shader %s" % SHADER_PATH)
		return
	_material = ShaderMaterial.new()
	_material.shader = shader
	_material.set_shader_parameter("map_index_atlas", DataOverlayBaker.get_empty_texture())
	_material.set_shader_parameter("occupation_lut", DataOverlayBaker.get_empty_texture())
	_material.set_shader_parameter("has_lut", false)
	_material.set_shader_parameter("lut_dims", Vector2.ONE)
	_mesh_inst.material = _material
	_has_shader = true


## 世界生命周期内调用一次（world_ready / 读档后重绑）。
func configure(map, map_index_atlas: Texture2D, lut_dims: Vector2i,
		bounds: Rect2, hex_size: float, wrap_period_x: float) -> void:
	_ensure_nodes()
	if _material == null:
		return
	_cell_count = map.cell_count() if map != null else 0
	_lut_dims = Vector2i(maxi(1, lut_dims.x), maxi(1, lut_dims.y))
	_bounds = bounds
	_wrap = maxf(0.0, wrap_period_x)
	_mesh_inst.mesh = _build_quad_mesh(bounds, _wrap)
	_material.set_shader_parameter("world_origin", bounds.position)
	_material.set_shader_parameter("world_size", bounds.size)
	_material.set_shader_parameter("wrap_origin_x", 0.0)
	_material.set_shader_parameter("wrap_period_x", _wrap)
	_material.set_shader_parameter("hatch_spacing", maxf(4.0, hex_size * 0.42))
	_material.set_shader_parameter("hatch_line_ratio", 0.36)
	_material.set_shader_parameter(
		"map_index_atlas",
		map_index_atlas if map_index_atlas != null else DataOverlayBaker.get_empty_texture()
	)
	_material.set_shader_parameter("lut_dims", Vector2(_lut_dims))
	_material.set_shader_parameter("has_lut", map_index_atlas != null)
	var pixels := _lut_dims.x * _lut_dims.y
	if _lut_buf.size() != pixels * 4:
		_lut_buf = PackedByteArray()
		_lut_buf.resize(pixels * 4)
		_lut_buf.fill(0)
	_lut_image = Image.create_from_data(_lut_dims.x, _lut_dims.y, false,
		Image.FORMAT_RGBA8, _lut_buf)
	if _lut_tex != null and _lut_tex.get_size() == Vector2(_lut_dims):
		_lut_tex.update(_lut_image)
	else:
		_lut_tex = ImageTexture.create_from_image(_lut_image)
	_material.set_shader_parameter("occupation_lut", _lut_tex)
	if _occupier.size() != _cell_count:
		_occupier.resize(_cell_count)
		_occupier.fill(-1)
		_cell_stamp.resize(_cell_count)
		_cell_stamp.fill(0)
	_uploaded_revision = -1


func set_player_slot(slot: int) -> void:
	if _material != null:
		_material.set_shader_parameter("player_slot", float(slot))


func set_enabled(enabled: bool) -> void:
	visible = enabled and _has_shader and _occupied_count > 0
	_stats["occupied_cells"] = _occupied_count


func clear() -> void:
	_stamp += 1
	_uploaded_revision = -1
	_occupied_count = 0
	if _material != null:
		_material.set_shader_parameter("has_lut", false)
	visible = false


func _process(_delta: float) -> void:
	if _material != null and visible:
		_material.set_shader_parameter("wall_seconds", _wall_seconds())


var _wall_time := 0.0


func _wall_seconds() -> float:
	return _wall_time


## 来源：feed 的 control_revision + 稀疏 (cell, occupier slot) 行。
## 只有 revision 变化才重写 LUT 并重传；相同 revision 直接返回。
func sync(control_revision: int, cells: PackedInt32Array, slots: PackedInt32Array) -> void:
	if _material == null:
		return
	if control_revision == _uploaded_revision:
		return
	var started := Time.get_ticks_usec()
	_uploaded_revision = control_revision
	_stamp += 1
	var count := mini(cells.size(), slots.size())
	var occupied := 0
	# 1) 清掉上一轮仍标记的格子（stamp 复用，不分配）。
	for i in _cell_count:
		if _cell_stamp[i] == _stamp - 1:
			_occupier[i] = -1
	# 2) 写入这一轮的稀疏行。
	for i in count:
		var cell := cells[i]
		if cell < 0 or cell >= _cell_count:
			continue
		var slot := slots[i]
		if slot < 0:
			continue
		_occupier[cell] = slot
		_cell_stamp[cell] = _stamp
		occupied += 1
	_occupied_count = occupied
	if occupied == 0:
		_material.set_shader_parameter("has_lut", false)
		visible = false
		_stats["occupied_cells"] = 0
		return
	# 3) 写 LUT：每格一个 texel。
	var pixels := _lut_dims.x * _lut_dims.y
	var b := _lut_buf
	for i in pixels:
		var o := i * 4
		var slot := _occupier[i] if i < _cell_count else -1
		if slot < 0:
			b[o] = 0
			b[o + 1] = 0
			b[o + 2] = 0
			b[o + 3] = 0
			continue
		b[o] = 255 if slot == 0 else (slot & 0xFF)
		b[o + 1] = 205
		b[o + 2] = 180
		b[o + 3] = 255
	_lut_image.set_data(_lut_dims.x, _lut_dims.y, false, Image.FORMAT_RGBA8, b)
	_lut_tex.update(_lut_image)
	_material.set_shader_parameter("has_lut", true)
	visible = true
	_stats["lut_uploads"] = int(_stats["lut_uploads"]) + 1
	_stats["upload_bytes"] = b.size()
	_stats["occupied_cells"] = occupied
	_stats["last_upload_usec"] = Time.get_ticks_usec() - started


func set_wall_time(seconds: float) -> void:
	_wall_time = seconds


func debug_snapshot() -> Dictionary:
	return {
		"visible": visible,
		"occupied_cells": _occupied_count,
		"uploaded_revision": _uploaded_revision,
		"lut_dims": str(_lut_dims),
		"lut_uploads": int(_stats["lut_uploads"]),
		"upload_bytes": int(_stats["upload_bytes"]),
		"last_upload_usec": int(_stats["last_upload_usec"]),
	}


func _build_quad_mesh(bounds: Rect2, wrap_period_x: float) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	if wrap_period_x > 0.0001:
		p.x = 0.0
		s.x = wrap_period_x
	var offsets := PackedFloat32Array([0.0])
	if wrap_period_x > 0.0001:
		offsets = PackedFloat32Array([-wrap_period_x, 0.0, wrap_period_x])
	var verts := PackedVector2Array()
	var indices := PackedInt32Array()
	for ox in offsets:
		var base := verts.size()
		var tp := p + Vector2(float(ox), 0.0)
		verts.append(tp)
		verts.append(tp + Vector2(s.x, 0.0))
		verts.append(tp + s)
		verts.append(tp + Vector2(0.0, s.y))
		indices.append_array(PackedInt32Array([
			base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
