# world_data.gd
# 由 MapBaker.synthesize_world 产出的"世界"——高分辨率地理仿真结果。
#
# - height_buffer    (hm_size, [0,1])：归一化海拔，深海到山顶
# - moisture_buffer  (derived_size, [0,1])：湿度，受 flow 扩散影响
# - flow_buffer      (derived_size, [0,1])：log-scaled 流量累积，0=干旱，1=主河道
# - biome_buffer     (derived_size, byte)：每像素 TerrainType.TERRAIN id
#
# 4 张对应的 ImageTexture 直接喂给 world_map.gdshader 做像素级合成。
# 同时提供给 MapGenerator 在 hex 中心采样，反推 cell.terrain / elevation / has_river。

class_name WorldData
extends RefCounted

# ─── 高分辨率原始 buffer（GDScript 端可直接采样） ─────────────────────────
var height_buffer: PackedFloat32Array = PackedFloat32Array()
var moisture_buffer: PackedFloat32Array = PackedFloat32Array()
var flow_buffer: PackedFloat32Array = PackedFloat32Array()
var biome_buffer: PackedByteArray = PackedByteArray()

# ─── 元数据 ───────────────────────────────────────────────────────────────
var hm_size: Vector2i = Vector2i.ZERO       # heightmap 分辨率（高，用于 hillshading）
var derived_size: Vector2i = Vector2i.ZERO  # 派生 buffer 分辨率（低，省内存）
var world_bounds: Rect2 = Rect2()
var sea_level: float = 0.42                  # 与 cfg.sea_level 一致，[0,1] 范围

# ─── shader 用 ImageTexture（编码后） ─────────────────────────────────────
var height_tex: ImageTexture
var moisture_tex: ImageTexture
var flow_tex: ImageTexture
var biome_tex: ImageTexture

# ─── 采样接口（给 MapGenerator 在 hex 中心采样用） ────────────────────────

func sample_height(world_pos: Vector2) -> float:
	return _bilinear_float(height_buffer, hm_size, world_pos)

func sample_flow(world_pos: Vector2) -> float:
	return _bilinear_float(flow_buffer, derived_size, world_pos)

func sample_moisture(world_pos: Vector2) -> float:
	return _bilinear_float(moisture_buffer, derived_size, world_pos)

func sample_biome(world_pos: Vector2) -> int:
	if biome_buffer.is_empty():
		return 0
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	return int(biome_buffer[y * W + x])

# ─── 内部 ─────────────────────────────────────────────────────────────────

func _world_to_uv(world_pos: Vector2) -> Vector2:
	if world_bounds.size.x < 0.001 or world_bounds.size.y < 0.001:
		return Vector2(0.5, 0.5)
	var u := (world_pos.x - world_bounds.position.x) / world_bounds.size.x
	var v := (world_pos.y - world_bounds.position.y) / world_bounds.size.y
	return Vector2(clampf(u, 0.0, 1.0), clampf(v, 0.0, 1.0))

func _bilinear_float(buf: PackedFloat32Array, size: Vector2i, world_pos: Vector2) -> float:
	if buf.is_empty() or size.x <= 0 or size.y <= 0:
		return 0.0
	var uv := _world_to_uv(world_pos)
	var W := size.x
	var H := size.y
	var fx := uv.x * float(W - 1)
	var fy := uv.y * float(H - 1)
	var x0 := clampi(int(floor(fx)), 0, W - 1)
	var y0 := clampi(int(floor(fy)), 0, H - 1)
	var x1 := mini(x0 + 1, W - 1)
	var y1 := mini(y0 + 1, H - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var v00 := buf[y0 * W + x0]
	var v10 := buf[y0 * W + x1]
	var v01 := buf[y1 * W + x0]
	var v11 := buf[y1 * W + x1]
	var v0 := lerpf(v00, v10, tx)
	var v1 := lerpf(v01, v11, tx)
	return lerpf(v0, v1, ty)
