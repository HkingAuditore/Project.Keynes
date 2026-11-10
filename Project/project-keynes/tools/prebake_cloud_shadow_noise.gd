extends SceneTree

## 离线烘焙云影噪声纹理（替代 field shader 里逐像素算的 value noise）。
##
## 动机见 shaders/cloud_shadow_field.gdshader：value noise 在格点取极值、插值丢失
## 方向性，阈值化后必然露出格子/枕头状伪影（HZD 与 Godot 社区的做法都是改用
## Perlin 梯度噪声 + Worley 细胞噪声，并预生成成纹理）。
##
## 四个通道装不同频率，shader 一次采样就能拿到完整的多尺度结构：
##   R = Perlin-Worley 主体（低频，决定云团的连通形状）
##   G = Worley 反相（中频，边缘侵蚀）
##   B = Worley 反相（高频，细节毛刺）
##   A = Perlin（更低频，给域扭曲当位移场）
##
## 纹理本身**无缝**（FastNoiseLite.get_seamless_image），所以 shader 里
## 让 UV 的一个周期正好等于世界 wrap 周期即可，不需要额外接缝处理。
##
## 运行（必须在仓库根执行，输出到 res://）：
##   godot --headless --path Project/project-keynes \
##     --script res://tools/prebake_cloud_shadow_noise.gd

const OUTPUT_DIR := "res://assets/textures/cloud_shadow"
const OUTPUT_PATH := OUTPUT_DIR + "/cloud_noise_rgba.res"
const SIZE := 1024
const SEED := 20261107
## 低频特征尺度：SIZE * FREQ ≈ 16 个特征，即每个云团直径约 62 texel。
## 纹理一个周期正好铺满地图 wrap 周期（world_wrap ≈ 2322 世界单位），
## 于是 62 texel 的云团 ≈ 141 世界单位 ≈ 3.7 hex —— 落在目标 3~6 hex 内。
const BASE_FREQUENCY := 0.0160


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))

	var perlin := _perlin(SEED, BASE_FREQUENCY, 4)
	var perlin_low := _perlin(SEED + 7, BASE_FREQUENCY * 0.5, 3)
	var worley_low := _worley(SEED + 31, BASE_FREQUENCY)
	var worley_mid := _worley(SEED + 53, BASE_FREQUENCY * 2.2)
	var worley_fine := _worley(SEED + 71, BASE_FREQUENCY * 5.5)

	var perlin_img := perlin.get_seamless_image(SIZE, SIZE, false, true)
	var perlin_low_img := perlin_low.get_seamless_image(SIZE, SIZE, false, true)
	var worley_low_img := worley_low.get_seamless_image(SIZE, SIZE, false, true)
	var worley_mid_img := worley_mid.get_seamless_image(SIZE, SIZE, false, true)
	var worley_fine_img := worley_fine.get_seamless_image(SIZE, SIZE, false, true)

	var p := perlin_img.get_data()
	var pl := perlin_low_img.get_data()
	var wl := worley_low_img.get_data()
	var wm := worley_mid_img.get_data()
	var wf := worley_fine_img.get_data()
	var count := SIZE * SIZE
	if p.size() < count or wl.size() < count:
		push_error("[prebake-cloud] seamless image size mismatch")
		quit(1)
		return

	var out := PackedByteArray()
	out.resize(count * 4)
	for i in range(count):
		# Perlin-Worley：Worley 反相后作为偏移去"膨胀" Perlin。直接相加会让两层的
		# 网格互相打架（各自的低频结构都还在），按 HZD 的做法用 worley 做权重重映射：
		# worley 低（细胞内部）→ 抬升 perlin；worley 高（细胞边界）→ 压回。
		var base: float = float(p[i]) / 255.0
		var cell: float = 1.0 - float(wl[i]) / 255.0
		var low := clampf(base * 0.68 + cell * 0.32, 0.0, 1.0)
		var low_remapped := smoothstep(0.18, 0.86, low)
		out[i * 4] = clampi(int(round(low_remapped * 255.0)), 0, 255)
		out[i * 4 + 1] = 255 - wm[i]
		out[i * 4 + 2] = 255 - wf[i]
		out[i * 4 + 3] = pl[i]

	var image := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, out)
	# 遮罩纹理只有 512x256，比噪声纹理低一档：没有 mipmap 时高频通道会走样
	# （采样率不足 → 摩尔纹）。生成 mip 后由 GPU 按导数自动选层。
	image.generate_mipmaps()
	var err := ResourceSaver.save(image, OUTPUT_PATH)
	print("[prebake-cloud] %s -> %s (%dx%d, err=%d)" % [
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
