extends RefCounted

const BUILDING_BASE_OVERRIDES := {
	&"fish_farm": &"economy.building.fishing",
	&"cold_storage": &"economy.building.transport",
	&"logistics_hub": &"economy.building.transport",
	&"public_health_center": &"economy.building.service",
}

static func compose(base_texture: Texture2D, product_texture: Texture2D) -> Texture2D:
	var base := _read_layer(base_texture, 108)
	var product := _read_layer(product_texture, 66)
	if base == null or product == null:
		return null
	var canvas := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	canvas.blend_rect(base, Rect2i(0, 0, 108, 108), Vector2i.ZERO)
	canvas.blend_rect(product, Rect2i(0, 0, 66, 66), Vector2i(62, 62))
	return ImageTexture.create_from_image(canvas)


static func _read_layer(texture: Texture2D, size: int) -> Image:
	if texture == null:
		return null
	var pixels := _read_pixels(texture)
	if pixels == null or pixels.is_empty():
		return null
	# Imported paper textures may use VRAM compression, which cannot be blended directly.
	if pixels.is_compressed() and pixels.decompress() != OK:
		return null
	pixels.convert(Image.FORMAT_RGBA8)
	pixels.resize(size, size, Image.INTERPOLATE_LANCZOS)
	return pixels


static func _read_pixels(texture: Texture2D) -> Image:
	var slice := texture as AtlasTexture
	if slice == null or not (slice.atlas is CompressedTexture2D):
		return texture.get_image()
	var pixels := slice.atlas.get_image()
	if pixels == null or pixels.is_empty():
		return null
	if pixels.is_compressed() and pixels.decompress() != OK:
		return null
	# Web 缩图保留逻辑尺寸，CPU 裁切要换算到实际图集像素。
	var ratio := Vector2(pixels.get_size()) / slice.atlas.get_size()
	var region := slice.region
	if region.size.x == 0.0:
		region.size.x = slice.atlas.get_width()
	if region.size.y == 0.0:
		region.size.y = slice.atlas.get_height()
	var start := Vector2i((region.position * ratio).round())
	var end := Vector2i(((region.position + region.size.floor()) * ratio).round())
	return pixels.get_region(Rect2i(start, end - start))


static func _paper_building_base(kind: String, product_id: StringName,
		stable_id: StringName = &"") -> StringName:
	var override_key: StringName = BUILDING_BASE_OVERRIDES.get(stable_id, &"")
	if not override_key.is_empty():
		return override_key
	var product := String(product_id)
	if product.ends_with("_ore") or product in ["coal", "crude_oil", "natural_gas",
			"raw_stone", "clay", "flint", "limestone", "silica_sand", "salt", "saltpeter", "sulfur", "bauxite", "phosphate_rock"]:
		return &"economy.building.mine"
	if product in ["logs", "lumber", "latex", "natural_rubber"]:
		return &"economy.building.forestry" if kind == "collector" else &"economy.building.workshop"
	if product in ["fish", "canned_fish"]:
		return &"economy.building.fishing" if kind == "collector" else &"economy.building.food"
	if product in ["game_meat", "fur", "raw_hide"]:
		return &"economy.building.hunting"
	if product in ["gathered_plants", "medicinal_herbs"]:
		return &"economy.building.gathering"
	if product.ends_with("_grain") or product in ["grain", "potatoes", "vegetables",
			"horses", "livestock_products", "cotton_fiber", "seed_cotton", "flax_fiber", "bast_fiber", "wool"]:
		return &"economy.building.farm"
	if product in ["bread", "prepared_staples", "processed_food", "beverages", "dairy_products", "edible_oil", "meat"]:
		return &"economy.building.food"
	if product == "technology_points":
		return &"economy.building.science"
	if product == "electricity":
		return &"economy.building.power"
	if product == "oceanic_vessels":
		return &"economy.building.shipyard"
	if kind == "collector":
		return &"economy.building.gathering"
	if kind == "service":
		return &"economy.building.service"
	return &"economy.building.factory"
