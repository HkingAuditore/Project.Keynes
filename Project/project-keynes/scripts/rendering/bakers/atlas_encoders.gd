extends RefCounted
class_name DCAtlasEncoders

## Bake-time texture encoder dispatcher.
##
## C++ (`DCWorldExt`) owns the byte payload loops; GDScript only keeps Image/ImageTexture
## upload and debug fallback. This keeps Godot object lifetime on the scripting side while
## removing the W*H encode loops from map generation.


# ═══════════════════════════════════════════════════════════════════════
# Native dispatch / texture upload helpers
# ═══════════════════════════════════════════════════════════════════════

static func _get_native_ext(native_ext: Object) -> Object:
	if native_ext != null:
		return native_ext
	if not ClassDB.class_exists("DCWorldExt"):
		return null
	return ClassDB.instantiate("DCWorldExt")


static func _same_size(existing: ImageTexture, W: int, H: int) -> bool:
	return existing != null and existing.get_size() == Vector2(float(W), float(H))


static func _upload_l8(data: PackedByteArray, W: int, H: int, existing: ImageTexture = null) -> ImageTexture:
	var img: Image = Image.create_from_data(W, H, false, Image.FORMAT_L8, data)
	if _same_size(existing, W, H):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)


static func _upload_rg8(data: PackedByteArray, W: int, H: int, existing: ImageTexture = null) -> ImageTexture:
	var img: Image = Image.create_from_data(W, H, false, Image.FORMAT_RG8, data)
	if _same_size(existing, W, H):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)


static func _upload_rgba8(data: PackedByteArray, W: int, H: int, existing: ImageTexture = null) -> ImageTexture:
	var img: Image = Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, data)
	if _same_size(existing, W, H):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)


static func _native_data(native_ext: Object, method_name: StringName, knobs: Dictionary) -> Dictionary:
	var ext := _get_native_ext(native_ext)
	if ext == null or not ext.has_method(method_name):
		return {"fallback": true, "reason": "native_method_missing"}
	var ret: Dictionary = ext.call(method_name, knobs)
	if bool(ret.get("fallback", true)):
		return ret
	return ret


# ═══════════════════════════════════════════════════════════════════════
# 纹理/atlas 编码 helpers
# ═══════════════════════════════════════════════════════════════════════

static func encode_height_tex(buf: PackedFloat32Array, size: Vector2i,
		native_ext: Object = null) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var ret: Dictionary = _native_data(native_ext, &"encode_bake_height_tex_data", {
		"buffer": buf,
		"width": W,
		"height": H,
	})
	if not bool(ret.get("fallback", true)):
		return _upload_rg8(ret.get("data", PackedByteArray()), W, H)

	# Debug fallback: mirrors the native contract exactly.
	var data: PackedByteArray = PackedByteArray()
	data.resize(W * H * 2)
	for i in range(W * H):
		var v: float = clampf(buf[i], 0.0, 1.0)
		var v16: int = clampi(int(round(v * 65535.0)), 0, 65535)
		data[i * 2] = (v16 >> 8) & 0xFF
		data[i * 2 + 1] = v16 & 0xFF
	return _upload_rg8(data, W, H)


# [terrain-normal-bake 2026-06-25] 生成期烘焙"总体地形法线"（宽半径梯度 → RG8: nx,ny）。
# 地形静态 → 运行期 shader 只需 1 次采样拿宏观山脉走向；细节法线另由运行期按 biome/性能档叠。
# 与 world_ext.cpp::encode_bake_terrain_normal_tex_data 逐位对齐。
static func encode_terrain_normal_tex(buf: PackedFloat32Array, size: Vector2i,
		coarse_radius: int = 4, slope_gain: float = 8.0, wrap_x: bool = true,
		native_ext: Object = null) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var ret: Dictionary = _native_data(native_ext, &"encode_bake_terrain_normal_tex_data", {
		"buffer": buf,
		"width": W,
		"height": H,
		"coarse_radius": coarse_radius,
		"slope_gain": slope_gain,
		"wrap_x": wrap_x,
	})
	if not bool(ret.get("fallback", true)):
		return _upload_rg8(ret.get("data", PackedByteArray()), W, H)

	# Debug fallback: mirrors the native contract (宽半径中心差分 → RG8 法线)。
	var r: int = maxi(coarse_radius, 1)
	var data: PackedByteArray = PackedByteArray()
	data.resize(W * H * 2)
	if buf.size() < W * H:
		return _upload_rg8(data, W, H)
	var inv2r_gain: float = slope_gain / (2.0 * float(r))
	for y in range(H):
		var yu: int = maxi(y - r, 0)
		var yd: int = mini(y + r, H - 1)
		var row: int = y * W
		var row_u: int = yu * W
		var row_d: int = yd * W
		for x in range(W):
			var xl: int = x - r
			var xr: int = x + r
			if wrap_x:
				xl = ((xl % W) + W) % W
				xr = xr % W
			else:
				xl = maxi(xl, 0)
				xr = mini(xr, W - 1)
			var h_l: float = buf[row + xl]
			var h_r: float = buf[row + xr]
			var h_u: float = buf[row_u + x]
			var h_d: float = buf[row_d + x]
			var sx: float = (h_r - h_l) * inv2r_gain
			var sy: float = (h_d - h_u) * inv2r_gain
			var inv_len: float = 1.0 / sqrt(sx * sx + sy * sy + 1.0)
			var nx: float = -sx * inv_len
			var ny: float = -sy * inv_len
			var di: int = (row + x) * 2
			data[di] = clampi(int(round((nx * 0.5 + 0.5) * 255.0)), 0, 255)
			data[di + 1] = clampi(int(round((ny * 0.5 + 0.5) * 255.0)), 0, 255)
	return _upload_rg8(data, W, H)


static func encode_enum_atlas_payload(biome_buf: PackedByteArray, _veg_buf: PackedByteArray,
		_cover_buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null, world: Object = null, native_ext: Object = null,
		landform_by_cell: PackedByteArray = PackedByteArray()) -> Dictionary:
	var W: int = size.x
	var H: int = size.y
	var n: int = W * H
	var ret: Dictionary = {"fallback": true}
	if world != null:
		ret = _native_data(native_ext, &"encode_bake_enum_atlas_payload", {
			"biome_buffer": biome_buf,
			"width": W,
			"height": H,
			"n_cells": world.cell_first_px_arr.size(),
			"cell_first_px": world.cell_first_px_arr,
			"cell_px_count": world.cell_px_count_arr,
			"flat_px_indices": world.flat_px_indices_arr,
			"landform_by_cell": landform_by_cell,
		})
	if not bool(ret.get("fallback", true)):
		var native_data: PackedByteArray = ret.get("data", PackedByteArray())
		return {
			"texture": _upload_rgba8(native_data, W, H, existing),
			"data": native_data,
			"size": Vector2i(W, H),
			"path": "gdext",
		}

	# Debug fallback: retained only for gdext-missing/editor diagnostics.
	var data: PackedByteArray = PackedByteArray()
	data.resize(n * 4)
	var lookup: Array = world.pixel_to_cell_lookup if world != null else []
	var has_lookup: bool = lookup.size() >= n
	for i in range(n):
		var di: int = i * 4
		data[di] = biome_buf[i] if i < biome_buf.size() else 0
		var cid: int = 65535
		var lf: int = 0
		if has_lookup:
			var cell = lookup[i]
			if cell != null:
				cid = int(cell.index)
				lf = int(cell.landform) & 0xFF
		data[di + 1] = cid & 0xFF
		data[di + 2] = (cid >> 8) & 0xFF
		data[di + 3] = lf
	return {
		"texture": _upload_rgba8(data, W, H, existing),
		"data": data,
		"size": Vector2i(W, H),
		"path": "gdscript",
	}


static func encode_upwelling_tex(upwelling_buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null, native_ext: Object = null) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var ret: Dictionary = _native_data(native_ext, &"encode_bake_r8_tex_data", {
		"buffer": upwelling_buf,
		"width": W,
		"height": H,
		"default_byte": 128,
	})
	if not bool(ret.get("fallback", true)):
		return _upload_l8(ret.get("data", PackedByteArray()), W, H, existing)

	var n: int = W * H
	if upwelling_buf.size() == n:
		return _upload_l8(upwelling_buf, W, H, existing)
	var data: PackedByteArray = PackedByteArray()
	data.resize(n)
	var has_up: bool = upwelling_buf.size() >= n
	for i in range(n):
		data[i] = upwelling_buf[i] if has_up else 128
	return _upload_l8(data, W, H, existing)


# 传入 existing（非 null + 同尺寸）会尝试原地 update 以复用 GPU 句柄，
# 避免 refresh_climate_daily 每日创建新纹理带来的驱动层分配开销。
static func encode_r8_tex(buf: PackedByteArray, size: Vector2i, existing: ImageTexture,
		native_ext: Object = null) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var ret: Dictionary = _native_data(native_ext, &"encode_bake_r8_tex_data", {
		"buffer": buf,
		"width": W,
		"height": H,
		"default_byte": 0,
	})
	if not bool(ret.get("fallback", true)):
		return _upload_l8(ret.get("data", PackedByteArray()), W, H, existing)

	var n: int = W * H
	var data: PackedByteArray = PackedByteArray()
	data.resize(n)
	var has_buf: bool = buf.size() >= n
	for i in range(n):
		data[i] = buf[i] if has_buf else 0
	return _upload_l8(data, W, H, existing)


static func encode_flow_tex(buf: PackedFloat32Array, size: Vector2i, existing: ImageTexture,
		native_ext: Object = null) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var ret: Dictionary = _native_data(native_ext, &"encode_bake_flow_tex_data", {
		"buffer": buf,
		"width": W,
		"height": H,
	})
	if not bool(ret.get("fallback", true)):
		return _upload_l8(ret.get("data", PackedByteArray()), W, H, existing)

	var n: int = W * H
	if buf.size() < n:
		return existing
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(n)
	for i in range(n):
		bytes[i] = int(clampf(buf[i], 0.0, 1.0) * 255.0 + 0.5)
	return encode_r8_tex(bytes, size, existing, native_ext)
