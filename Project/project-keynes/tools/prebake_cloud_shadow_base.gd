extends SceneTree

## 离线生成云影宏观底图。
##
## 这张纹理不是天气 LUT，也不是运行时 field。它只提供跨 cell 连续的宏观云团
## 分布；运行时由 cloud_shadow_field.gdshader 叠加动态细节并沿风向平流。
##
## 运行：
##   godot --headless --path Project/project-keynes \
##     --script res://tools/prebake_cloud_shadow_base.gd

const OUTPUT_DIR := "res://assets/textures/cloud_shadow"
const OUTPUT_PATH := OUTPUT_DIR + "/cloud_shadow_base_rgba.res"
const SIZE := 1024
const SEED := 20261108


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var macro := _perlin(SEED, 0.0045, 5)
	var macro_secondary := _perlin(SEED + 19, 0.0075, 4)
	var macro_cells := _worley(SEED + 47, 0.0055)
	var macro_detail := _worley(SEED + 83, 0.011)

	var macro_img := macro.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
	var secondary_img := macro_secondary.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
	var cells_img := macro_cells.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
	var detail_img := macro_detail.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
	var macro_data := macro_img.get_data()
	var secondary_data := secondary_img.get_data()
	var cells_data := cells_img.get_data()
	var detail_data := detail_img.get_data()
	var count := SIZE * SIZE
	var out := PackedByteArray()
	out.resize(count * 4)
	for i in range(count):
		var p := float(macro_data[i]) / 255.0
		var secondary := float(secondary_data[i]) / 255.0
		var cells := 1.0 - float(cells_data[i]) / 255.0
		var detail := 1.0 - float(detail_data[i]) / 255.0
		# R：宏观覆盖；G：边缘/天气过渡；B：低幅备用变化；A：备用 warp。
		var density := clampf(p * 0.62 + secondary * 0.18 + cells * 0.20, 0.0, 1.0)
		var edge := clampf(secondary * 0.55 + detail * 0.45, 0.0, 1.0)
		out[i * 4] = clampi(int(round(density * 255.0)), 0, 255)
		out[i * 4 + 1] = clampi(int(round(edge * 255.0)), 0, 255)
		out[i * 4 + 2] = clampi(int(round(secondary * 255.0)), 0, 255)
		out[i * 4 + 3] = clampi(int(round(detail * 255.0)), 0, 255)

	var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, out)
	image.generate_mipmaps()
	var err := ResourceSaver.save(image, OUTPUT_PATH)
	print("[prebake-cloud-base] %s -> %s (%dx%d, err=%d)" % [
		"OK" if err == OK else "FAILED", OUTPUT_PATH, SIZE, SIZE, err])
	quit(0 if err == OK else 2)


func _perlin(seed_value: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 2.0
	return noise


func _worley(seed_value: int, frequency: float) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_jitter = 1.0
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	return noise
