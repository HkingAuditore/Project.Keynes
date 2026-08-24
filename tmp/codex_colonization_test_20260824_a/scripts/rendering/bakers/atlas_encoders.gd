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


# [flow-diag] 记录最后一次 flow 编码的输入 float buffer 与输出字节分布，供 GM
# 「河流 flow 视图」打印。Web 上 flow 整张读成 1.0 时，靠它区分三种成因：
# 源 buffer 就是全 1（上游 river SDF 的问题）／buffer 对但字节全 255（编码器）／
# 两者都对但 GPU 读成白（上传或格式）。扫描按 stride 抽样，避免拖慢 bake。
static var last_flow_encode_info: Dictionary = {}

# [flow-diag] _upload_r8 加宽路径的最终产物统计（R 通道全量）。encode 日志里的 out
# 统计的是加宽前的 R8 字节，GPU 实际看到的 RGBA8 数据由此闭环验证。
static var last_r8_upload_verify: Dictionary = {}

const _DIAG_SAMPLE_TARGET := 65536


static func _float_buffer_stats(buf: PackedFloat32Array, n: int) -> Dictionary:
	if n <= 0 or buf.size() < n:
		return {"n": 0, "buf_size": buf.size()}
	var stride: int = maxi(1, n / _DIAG_SAMPLE_TARGET)
	var mn: float = INF
	var mx: float = -INF
	var sum: float = 0.0
	var hi: int = 0
	var samples: int = 0
	var i: int = 0
	while i < n:
		var v: float = buf[i]
		mn = minf(mn, v)
		mx = maxf(mx, v)
		sum += v
		if v >= 0.70:
			hi += 1
		samples += 1
		i += stride
	return {"n": n, "buf_size": buf.size(), "samples": samples, "stride": stride,
		"min": mn, "max": mx, "mean": sum / float(samples),
		"hi_frac": float(hi) / float(samples)}


static func _byte_buffer_stats(data: PackedByteArray, n: int) -> Dictionary:
	if n <= 0 or data.size() < n:
		return {"n": 0, "data_size": data.size()}
	var stride: int = maxi(1, n / _DIAG_SAMPLE_TARGET)
	var mn: int = 255
	var mx: int = 0
	var sum: int = 0
	var hi: int = 0
	var samples: int = 0
	var i: int = 0
	while i < n:
		var v: int = data[i]
		mn = mini(mn, v)
		mx = maxi(mx, v)
		sum += v
		# 179/255 ≈ 0.70 == river_threshold_low
		if v >= 179:
			hi += 1
		samples += 1
		i += stride
	return {"data_size": data.size(), "samples": samples,
		"min": mn, "max": mx, "mean": float(sum) / float(samples),
		"hi_frac": float(hi) / float(samples)}


# 单通道 bake 纹理的实际上传格式。
#
# [归因修正 2026-08-05] 早年认为"Web(WebGL2) 上单通道纹理建不起来、被静默换成 4×4
# 默认白纹"（L8/R8 都试过、textureSize 报 4×4、CPU 侧全绿）——真根因是**纹理单元
# 撞车**：flow 是材质第 9 张 sampler（unit 9），与 GLES3 canvas 内建高光槽
# （MAX-7）冲突，每帧被内建 4×4 默认白纹覆盖，与像素格式无关。修复在
# uniforms.gdshaderinc：PK_WEB_TEXTURE_BUDGET 下把材质 sampler 裁到 ≤8。
# 单通道仍加宽到 **RG8**（与 height_tex 同款上传路径，显存只 ×2，shader 只读 .r），
# 属于保守防御；禁止 Image.convert(R8→…)（wasm 下 convert 产物未验证）。
#
# 桌面 opengl3 并不复现撞车（32 单元、预留槽在 25+），但这里仍按整个 Compatibility
# 后端开关，好处是 `--rendering-driver opengl3` 的本地探针能走相同代码路径。
static func single_channel_format() -> int:
	if DCFeatureFlags.is_compatibility_renderer():
		return Image.FORMAT_RG8
	return Image.FORMAT_R8


## 单通道数据 → ImageTexture 的统一入口。任何单通道纹理都必须走这里，**不要**自己
## `Image.create_from_data(..., FORMAT_R8/L8, ...)`，否则会踩上面那个 Compatibility 陷阱。
static func upload_single_channel(data: PackedByteArray, W: int, H: int,
		existing: ImageTexture = null) -> ImageTexture:
	return _upload_r8(data, W, H, existing)


# update() 要求格式一致，所以 existing 格式不符时必须重建而不是原地更新。
static func _upload_r8(data: PackedByteArray, W: int, H: int, existing: ImageTexture = null) -> ImageTexture:
	var want: int = single_channel_format()
	var img: Image
	if want == Image.FORMAT_R8:
		img = Image.create_from_data(W, H, false, Image.FORMAT_R8, data)
		last_r8_upload_verify = {"format": "R8", "widened": false}
	else:
		# Compatibility：字节级手工展开到 RG8（R=v,G=v），绝不走 Image.convert。
		var n: int = W * H
		var expanded: PackedByteArray = PackedByteArray()
		expanded.resize(n * 2)
		var has_data: bool = data.size() >= n
		var sum: int = 0
		var hi: int = 0
		var mn: int = 255
		var mx: int = 0
		for i in range(n):
			var v: int = data[i] if has_data else 0
			var o: int = i * 2
			expanded[o] = v
			expanded[o + 1] = v
			sum += v
			mn = mini(mn, v)
			mx = maxi(mx, v)
			if v >= 179:
				hi += 1
		var nf: float = float(maxi(n, 1))
		last_r8_upload_verify = {
			"format": "RG8_expanded", "widened": true, "n": n,
			"src_size": data.size(), "expanded_size": expanded.size(),
			"min": mn, "max": mx, "mean": float(sum) / nf, "hi_frac": float(hi) / nf,
		}
		img = Image.create_from_data(W, H, false, want, expanded)
	if _same_size(existing, W, H) and existing.get_format() == want:
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
	if _same_size(existing, W, H) and existing.get_format() == Image.FORMAT_RGBA8:
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


# [height-flow-pack 2026-08-06] Legacy 主地图把 height(RG16) 与 river flow(L8) 打进同一张
# RGBA8：RG=既有 16-bit height，B=flow，A=0。hm_size==derived_size 后分辨率可合；
# 腾出 1 个 WebGL2/GLES3 材质 sampler（原独立 flow_tex）。CPU 侧仍保留分离的
# height_buffer / flow_buffer。Tiled 的 visual_height_tiles 同步打成 RGBA8（B=flow）。
static func encode_height_flow_tex(height_buf: PackedFloat32Array, flow_buf: PackedFloat32Array,
		size: Vector2i, existing: ImageTexture = null,
		native_ext: Object = null) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var n: int = W * H
	if W <= 0 or H <= 0:
		last_flow_encode_info = {"size": Vector2i(W, H), "path": "skipped", "reason": "bad_size"}
		return existing

	var height_bytes: PackedByteArray = PackedByteArray()
	var flow_bytes: PackedByteArray = PackedByteArray()
	var height_path := "gdscript"
	var flow_path := "gdscript"
	var height_ret: Dictionary = _native_data(native_ext, &"encode_bake_height_tex_data", {
		"buffer": height_buf,
		"width": W,
		"height": H,
	})
	if not bool(height_ret.get("fallback", true)):
		height_bytes = height_ret.get("data", PackedByteArray())
		height_path = str(height_ret.get("path", "native"))
	var flow_ret: Dictionary = _native_data(native_ext, &"encode_bake_flow_tex_data", {
		"buffer": flow_buf,
		"width": W,
		"height": H,
	})
	if not bool(flow_ret.get("fallback", true)):
		flow_bytes = flow_ret.get("data", PackedByteArray())
		flow_path = str(flow_ret.get("path", "native"))

	last_flow_encode_info = {
		"size": Vector2i(W, H),
		"path": "height_flow_pack",
		"height_path": height_path,
		"flow_path": flow_path,
		"src": _float_buffer_stats(flow_buf, n),
		"packed_channel": "B",
		"format": "RGBA8",
	}

	var rgba: PackedByteArray = PackedByteArray()
	rgba.resize(n * 4)
	var has_native_height := height_bytes.size() == n * 2
	var has_native_flow := flow_bytes.size() == n
	var has_height_buf := height_buf.size() >= n
	var has_flow_buf := flow_buf.size() >= n
	if not has_flow_buf and not has_native_flow:
		last_flow_encode_info["out"] = {"skipped": "flow buffer too small"}
	for i in range(n):
		var o: int = i * 4
		if has_native_height:
			rgba[o] = height_bytes[i * 2]
			rgba[o + 1] = height_bytes[i * 2 + 1]
		elif has_height_buf:
			var v: float = clampf(height_buf[i], 0.0, 1.0)
			var v16: int = clampi(int(round(v * 65535.0)), 0, 65535)
			rgba[o] = (v16 >> 8) & 0xFF
			rgba[o + 1] = v16 & 0xFF
		else:
			rgba[o] = 0
			rgba[o + 1] = 0
		if has_native_flow:
			rgba[o + 2] = flow_bytes[i]
		elif has_flow_buf:
			rgba[o + 2] = int(clampf(flow_buf[i], 0.0, 1.0) * 255.0 + 0.5)
		else:
			rgba[o + 2] = 0
		rgba[o + 3] = 0

	var flow_only: PackedByteArray = PackedByteArray()
	flow_only.resize(n)
	for i in range(n):
		flow_only[i] = rgba[i * 4 + 2]
	last_flow_encode_info["out"] = _byte_buffer_stats(flow_only, n)
	last_flow_encode_info["upload"] = {"format": "RGBA8", "n": n, "bytes": rgba.size()}
	return _upload_rgba8(rgba, W, H, existing)


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


# [terrain-horizon 2026-07-03] 生成期烘焙 8 方向 horizon angle。
# C++ 输出 RGBA8，每个 byte 拆 high/low nibble 承载两个方向：E/NE, N/NW, W/SW, S/SE。
# 这里不提供 GDScript 热循环 fallback：DLL 未 rebuild 时返回 existing/null，shader 自动关闭阴影。
static func encode_horizon_tex(buf: PackedFloat32Array, size: Vector2i,
		world_size: Vector2, hex_size: float, existing: ImageTexture = null,
		native_ext: Object = null, steps: int = 48, step_px: float = 2.0,
		max_horizon_angle: float = 1.309, bias: float = 0.003,
		height_world_scale: float = 0.0, wrap_period_x: float = 0.0,
		sea_level: float = 0.0, step_growth: float = 0.35,
		lowpass_radius: int = 1) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var hscale: float = height_world_scale if height_world_scale > 0.0 else maxf(hex_size * 8.0, 1.0)
	var ret: Dictionary = _native_data(native_ext, &"encode_bake_horizon_tex_data", {
		"height_buffer": buf,
		"width": W,
		"height": H,
		"world_size_x": world_size.x,
		"world_size_y": world_size.y,
		"wrap_x": true,
		# 真正经度周期（world units）：柱状地图 marching 须按此折叠而非整图宽（含 padding）。
		"wrap_period_x": wrap_period_x,
		"steps": steps,
		"step_px": step_px,
		"step_growth": step_growth,
		"lowpass_radius": lowpass_radius,
		"max_horizon_angle": max_horizon_angle,
		"bias": bias,
		"height_world_scale": hscale,
		"sea_level": sea_level,
	})
	if not bool(ret.get("fallback", true)):
		return _upload_rgba8(ret.get("data", PackedByteArray()), W, H, existing)
	push_warning(("[terrain_horizon] encode_bake_horizon_tex_data unavailable/fallback (reason=%s). "
		+ "Rebuild the GDExtension DLL to enable terrain cast shadows.") % String(ret.get("reason", "?")))
	return null


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
		return _upload_r8(ret.get("data", PackedByteArray()), W, H, existing)

	var n: int = W * H
	if upwelling_buf.size() == n:
		return _upload_r8(upwelling_buf, W, H, existing)
	var data: PackedByteArray = PackedByteArray()
	data.resize(n)
	var has_up: bool = upwelling_buf.size() >= n
	for i in range(n):
		data[i] = upwelling_buf[i] if has_up else 128
	return _upload_r8(data, W, H, existing)


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
		return _upload_r8(ret.get("data", PackedByteArray()), W, H, existing)

	var n: int = W * H
	var data: PackedByteArray = PackedByteArray()
	data.resize(n)
	var has_buf: bool = buf.size() >= n
	for i in range(n):
		data[i] = buf[i] if has_buf else 0
	return _upload_r8(data, W, H, existing)


static func encode_rg8_tex(buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var expected: int = W * H * 2
	if W <= 0 or H <= 0 or buf.size() != expected:
		return existing
	return _upload_rg8(buf, W, H, existing)


static func encode_flow_tex(buf: PackedFloat32Array, size: Vector2i, existing: ImageTexture,
		native_ext: Object = null) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var ret: Dictionary = _native_data(native_ext, &"encode_bake_flow_tex_data", {
		"buffer": buf,
		"width": W,
		"height": H,
	})
	last_flow_encode_info = {
		"size": Vector2i(W, H),
		"path": str(ret.get("path", "gdscript")),
		"reason": str(ret.get("reason", "")),
		"src": _float_buffer_stats(buf, W * H),
	}
	if not bool(ret.get("fallback", true)):
		var native_bytes: PackedByteArray = ret.get("data", PackedByteArray())
		last_flow_encode_info["out"] = _byte_buffer_stats(native_bytes, W * H)
		var tex_native := _upload_r8(native_bytes, W, H, existing)
		last_flow_encode_info["upload"] = last_r8_upload_verify
		return tex_native

	var n: int = W * H
	if buf.size() < n:
		last_flow_encode_info["out"] = {"skipped": "buffer too small"}
		return existing
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(n)
	for i in range(n):
		bytes[i] = int(clampf(buf[i], 0.0, 1.0) * 255.0 + 0.5)
	last_flow_encode_info["out"] = _byte_buffer_stats(bytes, n)
	var tex_fallback := encode_r8_tex(bytes, size, existing, native_ext)
	last_flow_encode_info["upload"] = last_r8_upload_verify
	return tex_fallback
