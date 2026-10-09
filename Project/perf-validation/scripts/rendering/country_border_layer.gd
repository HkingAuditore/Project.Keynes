# country_border_layer.gd
# 国界线渲染层。
#
# 为什么走几何而不是 shader 屏幕空间 edge detect：map_index_atlas 的 cell index
# 在烘焙期带 Bayer dither（map_baker 的 dither_enabled），逐像素反查在 hex 边界
# 会抖 ±1 texel，描出来的线是碎的。而国界边数极少（60×40 地图最多 7200 条，实际
# 通常几十到几百条），一次性烘一张 ArrayMesh 完全不是负担。
#
# 每个「归属与邻格不同」的 hex 边，由**拥有该格的一侧**生成一条朝本格内侧的
# ribbon。两个相邻国家各出一条 → 国界线上自然形成「深色分隔线 + 两侧国色带」；
# 国家 vs 无主地/图边只出一条。这样既避免了去重时选哪一侧的歧义，也免费得到了
# 双色国界。
#
# ribbon 按 RIBBON_WIDTH_RATIO × hex_size 烘死，实际线宽由 shader 的
# border_world_width uniform 裁出，因此相机缩放只推 uniform，不重建 mesh。
#
# ribbon 是**内缩梯形**，不是平行四边形：凸多边形向内偏移 d 时每条边会变短
# （六边形每端缩短 d·tan30°），所以内侧两点要沿边**向内收**。早期版本反过来把
# 四个点都沿边向外延伸，于是每条边都越过角点，相邻两条在角外交叉成 X。
# 外侧两点必须正好落在 hex 角上，六条 ribbon 才严丝合缝围成一圈。
#
# z_index:
#   WorldQuad             = 0
#   DataOverlayLayer      = 5
#   CountryBorderLayer    = 6   ← 本节点
#   CellHighlight         = 10
#   FogOfWarLayer         = 12
class_name CountryBorderLayer
extends Node2D

const SHADER_PATH: String = "res://shaders/country_border.gdshader"

## ribbon 的世界宽度 = 本比例 × hex_size。要能容纳最大 zoom-out 时的期望线宽
## （见 _push_border_width 的换算）。
const RIBBON_WIDTH_RATIO: float = 0.62
## 六边形 120° 折角的 miter 系数 tan(30°)：向内偏移 d 时边的每端缩短 d·tan30°，
## 向外偏移 e 时每端加长 e·tan30°。两侧都按这个规律走，相邻 ribbon 才严丝合缝。
const MITER_INSET_RATIO: float = 0.57735027
## ribbon 向国界线外侧多留一点余量（比例 × ribbon 宽度），单纯为了让线的外缘也能
## 抗锯齿。没有这条余量时外缘正好落在三角形边界上，拉近后是一条硬锯齿。
const OUTER_BLEED_RATIO: float = 0.18

## 基准屏幕线宽（像素），在 zoom=1 时取到。
##
## 线宽不做成屏幕空间恒定：恒定宽度在拉近后是一根压在巨大 hex 上的发丝，显得廉价。
## 这里让屏幕宽度随 zoom 次线性增长（指数 WIDTH_ZOOM_EXP），拉近时线变粗、有分量，
## 拉远时收细但不消失。
@export var border_screen_width: float = 3.6
## 屏幕宽度 ∝ zoom^exp。0=屏幕恒定，1=世界恒定。
@export_range(0.0, 1.0) var border_width_zoom_exp: float = 0.42
## 屏幕线宽的上下限（像素），避免极端 zoom 下过细或糊成色块。
@export var border_screen_width_min: float = 2.0
@export var border_screen_width_max: float = 9.0
@export var player_color: Color = Color(1.0, 0.86, 0.42)

var _mesh_inst: MeshInstance2D
var _shader_mat: ShaderMaterial
var _has_valid_shader: bool = false
var _has_geometry: bool = false
var _enabled: bool = true

var _hex_size: float = 22.0
var _wrap_period_x: float = 0.0
var _ribbon_width: float = 11.0
var _player_slot: int = -1
var _last_pushed_world_width: float = -1.0

static var _white_tex: ImageTexture = null


static func get_white_texture() -> ImageTexture:
	if _white_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color(1.0, 1.0, 1.0, 1.0))
		_white_tex = ImageTexture.create_from_image(img)
	return _white_tex


## 国色。玩家国家固定高辨识度金色，其余按黄金比 hue 展开，保证任意两个相邻
## slot 的色相差足够大且跨存档稳定（只依赖 slot，不依赖遍历顺序）。
static func country_color(slot: int, player_slot: int, player_col: Color) -> Color:
	if slot < 0:
		return Color(0.0, 0.0, 0.0, 0.0)
	if slot == player_slot:
		return player_col
	var h := fposmod(float(slot) * 0.61803398875 + 0.137, 1.0)
	return Color.from_hsv(h, 0.66, 0.94)


func _ready() -> void:
	z_index = 6
	top_level = true
	visible = false
	_ensure_nodes()
	set_process(true)


func _process(_delta: float) -> void:
	if not visible or _shader_mat == null:
		return
	_push_border_width()


func _ensure_nodes() -> void:
	if _mesh_inst != null:
		return
	_mesh_inst = MeshInstance2D.new()
	_mesh_inst.name = "BorderMesh"
	# 绑定不透明白贴图：canvas_item 的 fragment COLOR = TEXTURE 采样 × 顶点色，
	# 白贴图让顶点色（国色 + edge seed）原样到达 fragment。
	_mesh_inst.texture = get_white_texture()
	add_child(_mesh_inst)

	var sh: Shader = load(SHADER_PATH) as Shader
	if sh == null:
		push_warning("CountryBorderLayer: failed to load shader '%s'; borders disabled" % SHADER_PATH)
		_has_valid_shader = false
		return
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = sh
	_shader_mat.set_shader_parameter("ribbon_world_width", _ribbon_width)
	_shader_mat.set_shader_parameter("border_world_width", border_screen_width)
	_mesh_inst.material = _shader_mat
	_has_valid_shader = true


func set_hex_size(size: float) -> void:
	_hex_size = maxf(1.0, size)
	_ribbon_width = _hex_size * RIBBON_WIDTH_RATIO
	if _shader_mat != null:
		_shader_mat.set_shader_parameter("ribbon_world_width", _ribbon_width)


func set_horizontal_wrap(period_x: float) -> void:
	_wrap_period_x = maxf(0.0, period_x)


## 玩家国家的 slot，用于给玩家边界固定配色。-1 表示未知。
func set_player_slot(slot: int) -> void:
	_player_slot = slot


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_update_visibility()


func clear() -> void:
	_has_geometry = false
	if _mesh_inst != null:
		_mesh_inst.mesh = null
	_update_visibility()


## 全量重建国界 mesh。领土变更极少（country_committed 才触发），不做增量。
## 返回统计信息，便于测试与诊断断言。
func rebuild(map) -> Dictionary:
	_ensure_nodes()
	var stats := {"edges": 0, "vertices": 0, "countries": 0, "tiles": 1}
	if map == null or _mesh_inst == null:
		clear()
		return stats
	var slots: PackedInt32Array = map.country_slot_arr
	var cells: Array = map.iter_cells()
	var n: int = cells.size()
	if n <= 0 or slots.size() < n:
		clear()
		return stats
	var neighbors: PackedInt32Array = map.neighbor_indices_packed()
	if neighbors.size() < n * 6:
		clear()
		return stats

	# pointy-top hex 的 6 个角，角度 60°*i - 30°（与 cell_highlight 同约定）。
	var corners := PackedVector2Array()
	corners.resize(6)
	for i in range(6):
		var ang: float = deg_to_rad(60.0 * float(i) - 30.0)
		corners[i] = Vector2(cos(ang), sin(ang)) * _hex_size

	var tile_offsets := PackedFloat32Array([0.0])
	if _wrap_period_x > 0.0001:
		tile_offsets = PackedFloat32Array([-_wrap_period_x, 0.0, _wrap_period_x])
	stats["tiles"] = tile_offsets.size()

	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var miter: float = _ribbon_width * MITER_INSET_RATIO
	var bleed: float = _ribbon_width * OUTER_BLEED_RATIO
	var bleed_miter: float = bleed * MITER_INSET_RATIO
	var color_cache: Dictionary = {}
	var edge_count: int = 0

	for tile_ox in tile_offsets:
		var tile_shift := Vector2(float(tile_ox), 0.0)
		for idx in range(n):
			var owner: int = slots[idx]
			if owner < 0:
				continue
			var cell = cells[idx]
			if cell == null:
				continue
			var center: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _hex_size) + tile_shift
			var base_n: int = idx * 6
			for d in range(6):
				var nb: int = neighbors[base_n + d]
				var nb_owner: int = slots[nb] if nb >= 0 else -1
				if nb_owner == owner:
					continue
				# dir d 对应的两个 hex 角：va = (6 - d) % 6，vb = va + 1。
				var va: int = (6 - d) % 6
				var p0: Vector2 = center + corners[va]
				var p1: Vector2 = center + corners[(va + 1) % 6]
				var edge_vec := p1 - p0
				var edge_len := edge_vec.length()
				if edge_len < 0.0001:
					continue
				var along := edge_vec / edge_len
				var inward := (center - (p0 + p1) * 0.5).normalized()
				var inset := inward * _ribbon_width
				var out_off := inward * bleed
				# 内侧沿边各收 miter，外侧各放 bleed_miter —— 两侧都是凸多边形的
				# 正确偏移，因此相邻两条 ribbon 在角点处顶点重合，围成的环没有缝也没有交叉。
				var a0 := p0 - out_off - along * bleed_miter
				var a1 := p1 - out_off + along * bleed_miter
				var b0 := p0 + inset + along * miter
				var b1 := p1 + inset - along * miter

				if not color_cache.has(owner):
					color_cache[owner] = country_color(owner, _player_slot, player_color)
				var base_col: Color = color_cache[owner]
				var seed := _edge_seed(idx, d)
				var vcol := Color(base_col.r, base_col.g, base_col.b, seed)

				# UV 存**世界单位**而非 0..1：两者都是位置的线性函数，因此在梯形
				# 拆成的两个三角形里插值都精确，不会在对角线上出现折痕。
				# u = 沿边距 p0 的距离，v = 距国界线的垂距（外侧为负）。
				var base_v: int = verts.size()
				verts.append(a0)
				verts.append(a1)
				verts.append(b1)
				verts.append(b0)
				uvs.append(Vector2(-bleed_miter, -bleed))
				uvs.append(Vector2(edge_len + bleed_miter, -bleed))
				uvs.append(Vector2(edge_len - miter, _ribbon_width))
				uvs.append(Vector2(miter, _ribbon_width))
				for _k in range(4):
					colors.append(vcol)
				indices.append_array(PackedInt32Array([
					base_v, base_v + 1, base_v + 2,
					base_v, base_v + 2, base_v + 3,
				]))
				edge_count += 1

	stats["edges"] = edge_count / maxi(1, tile_offsets.size())
	stats["vertices"] = verts.size()
	stats["countries"] = color_cache.size()

	if verts.is_empty():
		clear()
		return stats

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_inst.mesh = mesh
	_has_geometry = true
	_last_pushed_world_width = -1.0
	_update_visibility()
	_push_border_width()
	return stats


# --- 内部 -----------------------------------------------------

## per-edge 噪声种子。只依赖 (cell idx, dir)，因此圆柱地图的三份副本拿到同一
## 个种子，接缝处的边界起伏完全一致。
func _edge_seed(idx: int, dir: int) -> float:
	var h: int = (idx * 6 + dir) * 2654435761
	h = (h ^ (h >> 15)) & 0xFFFFFF
	return float(h) / 16777215.0


## 屏幕线宽随 zoom 次线性增长：screen = base × zoom^exp（再夹到上下限），
## 世界线宽 = screen / zoom。exp=0 退化为屏幕恒定，exp=1 为世界恒定。
## canvas transform 的 scale 就是当前 zoom，不需要把 MapCamera 引用注入本层。
func _push_border_width() -> void:
	if _shader_mat == null:
		return
	var zoom: float = 1.0
	var vp := get_viewport()
	if vp != null:
		var s := vp.get_canvas_transform().get_scale()
		zoom = maxf(0.0001, s.x)
	var screen_width := border_screen_width * pow(zoom, border_width_zoom_exp)
	screen_width = clampf(screen_width, border_screen_width_min, border_screen_width_max)
	var world_width := clampf(screen_width / zoom, 0.35, _ribbon_width)
	if absf(world_width - _last_pushed_world_width) < 0.001:
		return
	_last_pushed_world_width = world_width
	_shader_mat.set_shader_parameter("border_world_width", world_width)


func _update_visibility() -> void:
	visible = _enabled and _has_valid_shader and _has_geometry
