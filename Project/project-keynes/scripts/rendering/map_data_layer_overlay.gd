# map_data_layer_overlay.gd
# 玩家「数据图层」分块设色叠加层（2026-07-23）。
#
# 结构完全复用 WeatherLayer：Node2D + 全屏 quad + ShaderMaterial，经
# map_index_atlas 逐格间接寻址采样 per-cell data_lut。区别：data_lut 的
# RGB 直接存「显示色」，由本脚本在 GDScript 侧按 LayerSpec 烘焙（O(n_cells)）。
#
# 仅对激活图层构建 LUT；选中时构建一次，每日 tick 调 refresh_active() 增量重建。
# 不做任何节点树重建，不改动模拟 schema。

extends Node2D
class_name MapDataLayerOverlay

const DATA_SHADER_PATH := "res://shaders/data_layer.gdshader"
const OVERLAY_ALPHA := 0.85

const DataLayerPalette = preload("res://scripts/rendering/data_layer_palette.gd")
const DCViewAdapter = preload("res://scripts/data_core/view_adapter.gd")
const TerrainType = preload("res://scripts/geography/terrain_type.gd")
const VegetationProfileRegistry = preload("res://scripts/data/vegetation_profile_registry.gd")

# ── 状态 ──
var _quad: MeshInstance2D
var _mat: ShaderMaterial
var _map: MapData = null
var _va: DCViewAdapter.Cell = null   # 非资源量访问器（显式类型，避免 match 内 := 推断失败）
var _cells: Array = []               # Array[HexCell]，顺序与 _va 一致
var _atlas_tex: ImageTexture = null
var _lut_dims: Vector2i = Vector2i.ZERO
var _lut_tex: ImageTexture = null
var _active_id: String = ""
var _active_spec: Dictionary = {}
var _legend_info: Dictionary = {}
var _no_data_color: Color = Color(0.20, 0.20, 0.22, 1.0)

func _ready() -> void:
	z_as_relative = false
	z_index = 3                        # 地形(0) 之上、WeatherLayer(4) 之下
	visible = false
	_quad = MeshInstance2D.new()
	_quad.name = "DataLayerQuad"
	_quad.z_as_relative = true
	_quad.z_index = 0
	add_child(_quad)
	_load_shader()

# ── 对外接口 ──
func set_layer(layer_id: String) -> void:
	var spec := DataLayerPalette.spec_for(layer_id)
	if spec.is_empty():
		clear_layer()
		return
	_active_id = layer_id
	_active_spec = spec
	_build_lut()
	visible = true

func clear_layer() -> void:
	_active_id = ""
	_active_spec = {}
	_legend_info = {}
	visible = false

func refresh_active() -> void:
	if _active_id == "" or _active_spec.is_empty():
		return
	# 仅「动态」图层（资源储量会逐日变化）需要每 tick 重建 LUT；
	# 海拔/地形/植被/温度/湿度/风/洋流均为静态场，选中时构建一次即可，
	# 盲目每 tick 重建会在大地图上造成无意义卡顿。
	if _active_spec.get("value", "") != "resource":
		return
	_build_lut()

func get_legend_info() -> Dictionary:
	return _legend_info

# 由 HexRenderer 在拿到 WorldData 之后调用一次（与 WeatherLayer.setup 同位置）。
func setup(bounds: Rect2, atlas_tex: ImageTexture, hex_size: float,
		lut_dims: Vector2i, wrap_period_x: float, map: MapData) -> void:
	_map = map
	if map != null:
		_cells = map.iter_cells()
		if not _cells.is_empty():
			_va = DCViewAdapter.Cell.new(_cells)
		else:
			_va = null
	else:
		_cells = []
		_va = null
	_atlas_tex = atlas_tex
	_lut_dims = lut_dims
	if _quad != null:
		_quad.mesh = _build_full_quad(bounds, wrap_period_x)
	if _mat != null:
		_mat.set_shader_parameter("map_index_atlas", atlas_tex)
		_mat.set_shader_parameter("lut_dims", Vector2(lut_dims.x, lut_dims.y))
		_mat.set_shader_parameter("world_origin", bounds.position)
		_mat.set_shader_parameter("world_size", bounds.size)
		_mat.set_shader_parameter("wrap_origin_x", 0.0)
		_mat.set_shader_parameter("wrap_period_x", wrap_period_x)
		_mat.set_shader_parameter("hex_world_diameter", 2.0 * hex_size)
		_mat.set_shader_parameter("overlay_alpha", OVERLAY_ALPHA)
	# 新地图重置激活图层
	clear_layer()

# ── LUT 烘焙（O(n_cells)）──
func _build_lut() -> void:
	if _map == null or _va == null or _active_spec.is_empty():
		return
	var lw := int(_lut_dims.x)
	var lh := int(_lut_dims.y)
	if lw < 1: lw = 1
	if lh < 1: lh = 1
	var n := _cells.size()
	if n <= 0:
		return

	var data := PackedByteArray()
	data.resize(lw * lh * 4)
	data.fill(0)   # C++ 侧 memset，比逐字节 for 循环快得多

	var value: String = _active_spec.get("value", "")
	var kind: int = int(_active_spec.get("kind", DataLayerPalette.KIND_SCALAR))
	var is_res: bool = (value == "resource")

	# 资源：预取储量数组 + 全局最大（用于色阶归一 + 图例）
	var res_arr: PackedFloat32Array = PackedFloat32Array()
	var res_max := 0.0
	if is_res:
		var field := DataLayerPalette.resource_field(_active_id)
		if field != "":
			var arr = _map.get(field)
			if arr is PackedFloat32Array:
				res_arr = arr
		for i in range(n):
			var cid := int(_cells[i].index)
			var v := 0.0
			if cid >= 0 and cid < res_arr.size():
				v = res_arr[cid]
			if v > res_max:
				res_max = v

	# 矢量：先求最大模长（自动归一亮度），再上色
	var max_len := 0.0
	if kind == DataLayerPalette.KIND_VECTOR:
		for i in range(n):
			var vec := Vector2.ZERO
			if value == "wind":
				vec = _va.get_wind_vector(i)
			else:
				vec = _va.get_ocean_current(i)
			var L := vec.length()
			if L > max_len:
				max_len = L
		if max_len < 0.0001:
			max_len = 1.0

	var present := {}   # 离散类别（地形/植被）图例用
	for i in range(n):
		var cid := int(_cells[i].index)
		if cid < 0 or cid >= 65535:
			continue
		var col := _no_data_color
		var a := 1.0
		match value:
			"elevation":
				var v := clampf(_va.get_elevation(i), 0.0, 1.0)
				col = DataLayerPalette.ramp_elevation(v)
			"terrain":
				var id := _va.get_terrain(i)
				col = DataLayerPalette.ramp_categorical(id)
				present[id] = true
			"vegetation":
				var id := _va.get_vegetation(i)
				col = DataLayerPalette.ramp_categorical(id)
				present[id] = true
			"temp":
				var v := clampf(_va.get_temp(i), 0.0, 1.0)
				col = DataLayerPalette.ramp_temp(v)
			"moisture":
				var v := clampf(_va.get_moisture(i), 0.0, 1.0)
				col = DataLayerPalette.ramp_humidity(v)
			"wind":
				var vec := _va.get_wind_vector(i)
				col = DataLayerPalette.ramp_vector(vec, vec.length() / max_len)
			"ocean_current":
				var vec := _va.get_ocean_current(i)
				col = DataLayerPalette.ramp_vector(vec, vec.length() / max_len)
			"resource":
				var v := 0.0
				if cid < res_arr.size():
					v = res_arr[cid]
				if v <= 0.0001:
					col = _no_data_color
					a = 0.5
				else:
					var t := clampf(v / maxf(res_max, 0.0001), 0.0, 1.0)
					col = DataLayerPalette.ramp_resource(t)
					a = 1.0
			_:
				col = _no_data_color

		var px := cid % lw
		var py := cid / lw
		var off := (py * lw + px) * 4
		data[off]     = int(clampf(col.r, 0.0, 1.0) * 255.0)
		data[off + 1] = int(clampf(col.g, 0.0, 1.0) * 255.0)
		data[off + 2] = int(clampf(col.b, 0.0, 1.0) * 255.0)
		data[off + 3] = int(clampf(a, 0.0, 1.0) * 255.0)

	var img := Image.create_from_data(lw, lh, false, Image.FORMAT_RGBA8, data)
	if _lut_tex == null:
		_lut_tex = ImageTexture.create_from_image(img)
		if _mat != null:
			_mat.set_shader_parameter("data_lut", _lut_tex)
	else:
		_lut_tex.set_image(img)
	_build_legend_info(kind, present, res_max)

func _build_legend_info(kind: int, present: Dictionary, res_max: float) -> void:
	_legend_info = {
		"display_name": _active_spec.get("display", ""),
		"kind": kind,
		"ramp": _active_spec.get("ramp", ""),
		"label_lo": _active_spec.get("label_lo", ""),
		"label_hi": _active_spec.get("label_hi", ""),
		"res_max": res_max,
	}
	if kind == DataLayerPalette.KIND_CATEGORICAL:
		var cats := PackedColorArray()
		var names := PackedStringArray()
		var value: String = _active_spec.get("value", "")
		# 按 enum id 排序，保证图例顺序稳定
		var sorted_ids := []
		for id in present.keys():
			sorted_ids.append(int(id))
		sorted_ids.sort()
		for id in sorted_ids:
			cats.append(DataLayerPalette.ramp_categorical(id))
			if value == "terrain":
				names.append(TerrainType.terrain_name_cn(TerrainType.TERRAIN.values()[id] if id < TerrainType.TERRAIN.size() else TerrainType.TERRAIN.OCEAN))
			elif value == "vegetation":
				var vp = VegetationProfileRegistry.get_profile(id)
				names.append(vp.display_name_cn if vp != null else ("V%d" % id))
			else:
				names.append("%d" % id)
		_legend_info["categories"] = cats
		_legend_info["category_names"] = names

# ── 内部 ──
func _load_shader() -> void:
	var shader := ResourceLoader.load(DATA_SHADER_PATH, "Shader",
		ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("MapDataLayerOverlay: shader not found at %s" % DATA_SHADER_PATH)
		return
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	_quad.material = _mat

# 全屏 quad（含横向 wrap 平铺），照搬 WeatherLayer._build_full_quad。
func _build_full_quad(bounds: Rect2, wrap_period_x: float = 0.0) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	if wrap_period_x > 0.0001:
		p.x = 0.0
		s.x = wrap_period_x
	var verts := PackedVector2Array()
	var indices := PackedInt32Array()
	var tile_offsets := PackedFloat32Array([0.0])
	if wrap_period_x > 0.0001:
		tile_offsets = PackedFloat32Array([-wrap_period_x, 0.0, wrap_period_x])
	for ox in tile_offsets:
		var base := verts.size()
		var tp := p + Vector2(float(ox), 0.0)
		verts.append(tp)
		verts.append(tp + Vector2(s.x, 0.0))
		verts.append(tp + s)
		verts.append(tp + Vector2(0.0, s.y))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
