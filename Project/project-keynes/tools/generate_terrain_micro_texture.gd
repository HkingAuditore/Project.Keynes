extends SceneTree

# Offline deterministic generator for the shared terrain micro-surface data map.
# RG = encoded normal XY, B = roughness perturbation, A = albedo grain.
const SIZE := 256
const OUTPUT := "res://assets/textures/terrain_micro_data.png"


func _hash01(x: int, y: int, seed: int) -> float:
	var n: int = x * 374761393 + y * 668265263 + seed * 1442695041
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / 2147483647.0


func _periodic_value_noise(px: float, py: float, cells: int, seed: int) -> float:
	var fx: float = px * float(cells)
	var fy: float = py * float(cells)
	var x0: int = int(floor(fx))
	var y0: int = int(floor(fy))
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var x1: int = (x0 + 1) % cells
	var y1: int = (y0 + 1) % cells
	x0 = posmod(x0, cells)
	y0 = posmod(y0, cells)
	var a: float = lerpf(_hash01(x0, y0, seed), _hash01(x1, y0, seed), tx)
	var b: float = lerpf(_hash01(x0, y1, seed), _hash01(x1, y1, seed), tx)
	return lerpf(a, b, ty)


func _height_at(x: int, y: int) -> float:
	var px: float = float(posmod(x, SIZE)) / float(SIZE)
	var py: float = float(posmod(y, SIZE)) / float(SIZE)
	return (
		_periodic_value_noise(px, py, 7, 173) * 0.52
		+ _periodic_value_noise(px, py, 17, 947) * 0.30
		+ _periodic_value_noise(px, py, 37, 2617) * 0.18
	)


func _initialize() -> void:
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in range(SIZE):
		for x in range(SIZE):
			var height: float = _height_at(x, y)
			var dx: float = (_height_at(x + 1, y) - _height_at(x - 1, y)) * 2.2
			var dy: float = (_height_at(x, y + 1) - _height_at(x, y - 1)) * 2.2
			var normal_xy := Vector2(-dx, -dy).limit_length(0.72)
			var px: float = float(x) / float(SIZE)
			var py: float = float(y) / float(SIZE)
			var rough_noise: float = _periodic_value_noise(px, py, 23, 4093)
			var grain_noise: float = _periodic_value_noise(px, py, 61, 7919)
			var roughness: float = 0.5 + (rough_noise - 0.5) * 0.64 + (height - 0.5) * 0.18
			var grain: float = 0.5 + (grain_noise - 0.5) * 0.72 + (height - 0.5) * 0.12
			image.set_pixel(
				x,
				y,
				Color(
					normal_xy.x * 0.5 + 0.5,
					normal_xy.y * 0.5 + 0.5,
					clampf(roughness, 0.0, 1.0),
					clampf(grain, 0.0, 1.0)))

	var output_dir := ProjectSettings.globalize_path("res://assets/textures")
	DirAccess.make_dir_recursive_absolute(output_dir)
	var error := image.save_png(OUTPUT)
	if error != OK:
		push_error("Failed to save terrain micro texture: %s" % error_string(error))
		quit(1)
		return
	print("Generated %s (%dx%d, deterministic periodic data)" % [OUTPUT, SIZE, SIZE])
	quit()
