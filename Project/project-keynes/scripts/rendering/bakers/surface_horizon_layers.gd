extends RefCounted

## Encodes sky visibility, bent normals and directional horizons for the single-tile surface.

static func _make_neutral_gi_sky_image(size: Vector2i) -> Image:
	var n: int = size.x * size.y
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in range(n):
		var o: int = i * 4
		data[o] = 255
		data[o + 1] = 128
		data[o + 2] = 128
		data[o + 3] = 255
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)


static func _make_neutral_horizon_dir_image(size: Vector2i) -> Image:
	var data := PackedByteArray()
	data.resize(size.x * size.y * 4)
	data.fill(0)
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)


static func _gaussian_blur_3x3_rgba8(src: PackedByteArray, w: int, h: int, wrap_x: bool) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(src.size())
	if w <= 0 or h <= 0 or src.size() != w * h * 4:
		return out
	var row_stride := w * 4
	for y in range(h):
		var ym := maxi(y - 1, 0) * row_stride
		var y0 := y * row_stride
		var yp := mini(y + 1, h - 1) * row_stride
		var dst_row := y0
		for x in range(w):
			var xm := (x - 1 + w) % w if wrap_x else maxi(x - 1, 0)
			var xp := (x + 1) % w if wrap_x else mini(x + 1, w - 1)
			var xmo := xm * 4
			var x0o := x * 4
			var xpo := xp * 4
			var i00 := ym + xmo
			var i10 := ym + x0o
			var i20 := ym + xpo
			var i01 := y0 + xmo
			var i11 := y0 + x0o
			var i21 := y0 + xpo
			var i02 := yp + xmo
			var i12 := yp + x0o
			var i22 := yp + xpo
			var dst := dst_row + x0o
			for c in range(4):
				var s := src[i00 + c] + (src[i10 + c] << 1) + src[i20 + c] \
					+ (src[i01 + c] << 1) + (src[i11 + c] << 2) + (src[i21 + c] << 1) \
					+ src[i02 + c] + (src[i12 + c] << 1) + src[i22 + c]
				out[dst + c] = (s + 8) >> 4
	return out


static func _gaussian_blur_3x3_gi_sky(src: PackedByteArray, w: int, h: int, wrap_x: bool) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(src.size())
	if w <= 0 or h <= 0 or src.size() != w * h * 4:
		return out
	var row_stride := w * 4
	const INV_255 := 1.0 / 255.0
	for y in range(h):
		var ym := maxi(y - 1, 0) * row_stride
		var y0 := y * row_stride
		var yp := mini(y + 1, h - 1) * row_stride
		var dst_row := y0
		for x in range(w):
			var xm := (x - 1 + w) % w if wrap_x else maxi(x - 1, 0)
			var xp := (x + 1) % w if wrap_x else mini(x + 1, w - 1)
			var xmo := xm * 4
			var x0o := x * 4
			var xpo := xp * 4
			var idxs: Array[int] = [
				ym + xmo, ym + x0o, ym + xpo,
				y0 + xmo, y0 + x0o, y0 + xpo,
				yp + xmo, yp + x0o, yp + xpo,
			]
			var ws: Array[int] = [1, 2, 1, 2, 4, 2, 1, 2, 1]
			var r_sum := 0
			var bx := 0.0
			var by := 0.0
			var bz := 0.0
			for k in range(9):
				var idx := idxs[k]
				var wt := ws[k]
				r_sum += src[idx] * wt
				var wf := float(wt)
				bx += (float(src[idx + 1]) * INV_255 * 2.0 - 1.0) * wf
				by += (float(src[idx + 2]) * INV_255 * 2.0 - 1.0) * wf
				bz += (float(src[idx + 3]) * INV_255) * wf
			var blen := sqrt(bx * bx + by * by + bz * bz)
			if blen > 1e-4:
				bx /= blen
				by /= blen
				bz /= blen
			else:
				bx = 0.0
				by = 0.0
				bz = 1.0
			var dst := dst_row + x0o
			out[dst] = (r_sum + 8) >> 4
			out[dst + 1] = clampi(int(round((bx * 0.5 + 0.5) * 255.0)), 0, 255)
			out[dst + 2] = clampi(int(round((by * 0.5 + 0.5) * 255.0)), 0, 255)
			out[dst + 3] = clampi(int(round(clampf(bz, 0.0, 1.0) * 255.0)), 0, 255)
	return out


static func _make_surface_horizon_layers(world: WorldData, size: Vector2i, max_angle: float) -> Array:
	var src: Image = null
	if world != null and world.terrain_horizon_tex != null:
		src = world.terrain_horizon_tex.get_image()
	if src == null or src.is_empty() or src.get_format() != Image.FORMAT_RGBA8:
		return [
			_make_neutral_gi_sky_image(size),
			_make_neutral_horizon_dir_image(size),
			_make_neutral_horizon_dir_image(size),
			false,
		]
	var sw := src.get_width()
	var sh := src.get_height()
	var src_bytes: PackedByteArray = src.get_data()
	var n := sw * sh
	if n <= 0 or src_bytes.size() != n * 4:
		return [
			_make_neutral_gi_sky_image(size),
			_make_neutral_horizon_dir_image(size),
			_make_neutral_horizon_dir_image(size),
			false,
		]
	var inv_sqrt2 := 0.7071067811865475
	var dir_x: Array[float] = [1.0, inv_sqrt2, 0.0, -inv_sqrt2, -1.0, -inv_sqrt2, 0.0, inv_sqrt2]
	var dir_y: Array[float] = [0.0, inv_sqrt2, 1.0, inv_sqrt2, 0.0, -inv_sqrt2, -1.0, -inv_sqrt2]
	var lut_c2: Array[float] = []
	var lut_cm: Array[float] = []
	var lut_sm: Array[float] = []
	var lut_u8: Array[int] = []
	lut_c2.resize(16)
	lut_cm.resize(16)
	lut_sm.resize(16)
	lut_u8.resize(16)
	var half_pi := PI * 0.5
	for idx in range(16):
		var h_ang := (float(idx) / 15.0) * max_angle
		var c := cos(h_ang)
		var m_ang := 0.5 * (h_ang + half_pi)
		lut_c2[idx] = c * c
		lut_cm[idx] = cos(m_ang)
		lut_sm[idx] = sin(m_ang)
		lut_u8[idx] = clampi(int(round((float(idx) / 15.0) * 255.0)), 0, 255)
	var gi_raw := PackedByteArray()
	var dir0_raw := PackedByteArray()
	var dir1_raw := PackedByteArray()
	gi_raw.resize(n * 4)
	dir0_raw.resize(n * 4)
	dir1_raw.resize(n * 4)
	for i in range(n):
		var o: int = i * 4
		var b0 := src_bytes[o]
		var b1 := src_bytes[o + 1]
		var b2 := src_bytes[o + 2]
		var b3 := src_bytes[o + 3]
		var q0 := b0 >> 4
		var q1 := b0 & 15
		var q2 := b1 >> 4
		var q3 := b1 & 15
		var q4 := b2 >> 4
		var q5 := b2 & 15
		var q6 := b3 >> 4
		var q7 := b3 & 15
		dir0_raw[o] = lut_u8[q0]
		dir0_raw[o + 1] = lut_u8[q1]
		dir0_raw[o + 2] = lut_u8[q2]
		dir0_raw[o + 3] = lut_u8[q3]
		dir1_raw[o] = lut_u8[q4]
		dir1_raw[o + 1] = lut_u8[q5]
		dir1_raw[o + 2] = lut_u8[q6]
		dir1_raw[o + 3] = lut_u8[q7]
		var qs := [q0, q1, q2, q3, q4, q5, q6, q7]
		var sky_sum := 0.0
		var bx := 0.0
		var by := 0.0
		var bz := 0.0
		for d in range(8):
			var qv: int = qs[d]
			var w: float = lut_c2[qv]
			sky_sum += w
			var horiz := w * lut_cm[qv]
			bx += horiz * dir_x[d]
			by += horiz * dir_y[d]
			bz += w * lut_sm[qv]
		var v_sky := clampf(sky_sum * 0.125, 0.0, 1.0)
		var blen := sqrt(bx * bx + by * by + bz * bz)
		if blen > 1e-3:
			bx /= blen
			by /= blen
			bz /= blen
		else:
			bx = 0.0
			by = 0.0
			bz = 1.0
		gi_raw[o] = clampi(int(round(v_sky * 255.0)), 0, 255)
		gi_raw[o + 1] = clampi(int(round((bx * 0.5 + 0.5) * 255.0)), 0, 255)
		gi_raw[o + 2] = clampi(int(round((by * 0.5 + 0.5) * 255.0)), 0, 255)
		gi_raw[o + 3] = clampi(int(round(clampf(bz, 0.0, 1.0) * 255.0)), 0, 255)
	var gi_blur := _gaussian_blur_3x3_gi_sky(gi_raw, sw, sh, true)
	var dir0_blur := _gaussian_blur_3x3_rgba8(dir0_raw, sw, sh, true)
	var dir1_blur := _gaussian_blur_3x3_rgba8(dir1_raw, sw, sh, true)
	var gi_img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, gi_blur)
	var dir0_img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, dir0_blur)
	var dir1_img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, dir1_blur)
	if sw != size.x or sh != size.y:
		gi_img.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
		dir0_img.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
		dir1_img.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	return [gi_img, dir0_img, dir1_img, true]
