extends RefCounted

## Builds shared terrain material and noise textures; world baking and runtime buffers remain on MapBaker.

const TERRAIN_MATERIAL_TEXTURE_PATHS := [
	"res://assets/textures/terrain_materials/organic.png",
	"res://assets/textures/terrain_materials/dry_sand.png",
	"res://assets/textures/terrain_materials/rock.png",
	"res://assets/textures/terrain_materials/snow_wet.png",
]

const TERRAIN_MICRO_TEXTURE_PATH := "res://assets/textures/terrain_micro_data.png"

static func _build_terrain_material_tex(target_size: int) -> Dictionary:
	if target_size <= 0:
		return {"texture": null, "reason": "invalid_target_size"}
	var images: Array[Image] = []
	for i in TERRAIN_MATERIAL_TEXTURE_PATHS.size():
		var image := load("res://assets/textures/loading_prebaked_v1/material_%d_%d.res" % [target_size,i]) as Image
		if image == null or image.is_empty():
			return {"texture":null,"reason":"prebaked_material_missing"}
		images.append(image)
	# [web-loading-material-shrink 2026-11-01] 层尺寸以**实际读到的图**为准，而不是
	# 请求的 target_size：Web 构建期会把 prebaked 材质图临时缩到更小（见
	# tools/web_tex_stub_loading_materials.gd + tools/web_tex_downgrade.py），文件名仍然
	# 按 target_size 命名。若这里继续按 target_size 去 resize micro 层，
	# create_from_images 会因为层尺寸不一致整张失败（quality=high 的 web 用户本来就会
	# 撞上 1024 那套被 stub 过的图）。按实际尺寸走：桌面未动 → 尺寸不变 → 行为不变。
	var material_layer_size: int = images[0].get_width()
	# [terrain-web-baked-surface-B 2026-11-01] 第 5 层 micro：512/1024² prebaked 材质层与
	# micro 源图（256²）的 mipmap 状态必须一致，否则 create_from_images 会拒绝整张 array。
	# 所以 micro 也 resize 到 target_size 并 generate_mipmaps()。
	var micro_image := _load_terrain_micro_layer_image(material_layer_size)
	if micro_image != null:
		images.append(micro_image)
	var texture := Texture2DArray.new()
	var create_error := texture.create_from_images(images)
	if create_error != OK:
		return {"texture": null, "reason": "array_create_failed:%s" % create_error}
	return {"texture": texture, "reason": "" if micro_image != null else "terrain_micro_layer_missing"}


static func _load_terrain_micro_layer_image(target_size: int) -> Image:
	if target_size <= 0:
		return null
	var tex := load(TERRAIN_MICRO_TEXTURE_PATH) as Texture2D
	if tex == null:
		push_warning("[terrain-material-tiles] micro layer source missing: %s" % TERRAIN_MICRO_TEXTURE_PATH)
		return null
	var image := tex.get_image()
	if image == null or image.is_empty():
		push_warning("[terrain-material-tiles] micro layer image unavailable: %s" % TERRAIN_MICRO_TEXTURE_PATH)
		return null
	# 复制一份再改，避免污染资源缓存里的 Image。
	image = image.duplicate() as Image
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	if image.get_width() != target_size or image.get_height() != target_size:
		image.resize(target_size, target_size, Image.INTERPOLATE_LANCZOS)
	image.generate_mipmaps()
	return image


static func _build_noise_tex(size: int, seed_val: int) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var raw := PackedByteArray()
	raw.resize(size * size)
	for i in range(size * size):
		raw[i] = rng.randi_range(0, 255)

	var data := PackedByteArray()
	data.resize(size * size * 4)
	for y in range(size):
		for x in range(size):
			var p := Vector2(float(x), float(y))
			var n1 := _sample_noise_raw(raw, size, p)
			var n2 := n1 * 0.5 + _sample_noise_raw(raw, size, p * 2.03) * 0.24
			var n3 := n2 + _sample_noise_raw(raw, size, p * 2.03 * 2.03) * 0.1152
			var n4 := n3 + _sample_noise_raw(raw, size, p * 2.03 * 2.03 * 2.03) * 0.055296
			var idx: int = (y * size + x) * 4
			data[idx] = clampi(int(round(n1 * 255.0)), 0, 255)
			data[idx + 1] = clampi(int(round(n2 * 255.0)), 0, 255)
			data[idx + 2] = clampi(int(round(n3 * 255.0)), 0, 255)
			data[idx + 3] = clampi(int(round(n4 * 255.0)), 0, 255)
	# v10.noise-pack：开启 mipmap。高频水纹/雪线/植被 dissolve 采样同一张预烘
	# RGBA fBM 噪声包；mipmap 让远距离/高频采样自动预滤波，降低 cache 抖动和 aliasing。
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _sample_noise_raw(raw: PackedByteArray, size: int, p: Vector2) -> float:
	var x0 := int(floor(p.x))
	var y0 := int(floor(p.y))
	var fx := p.x - float(x0)
	var fy := p.y - float(y0)
	var ux := fx * fx * (3.0 - 2.0 * fx)
	var uy := fy * fy * (3.0 - 2.0 * fy)
	var a := _noise_raw_at(raw, size, x0, y0)
	var b := _noise_raw_at(raw, size, x0 + 1, y0)
	var c := _noise_raw_at(raw, size, x0, y0 + 1)
	var d := _noise_raw_at(raw, size, x0 + 1, y0 + 1)
	return lerpf(lerpf(a, b, ux), lerpf(c, d, ux), uy)


static func _noise_raw_at(raw: PackedByteArray, size: int, x: int, y: int) -> float:
	var xx := posmod(x, size)
	var yy := posmod(y, size)
	return float(raw[yy * size + xx]) / 255.0
