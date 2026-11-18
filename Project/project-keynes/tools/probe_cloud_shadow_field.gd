extends SceneTree

## 云影场回归探针：把 CloudShadowField 单独渲染到离屏视口（恒定天气 = 只看云形），
## 统计三件事，用来守住 2026-11-18 那次修复：
##
##   1. ==1.0 的 texel 比例 —— 云心"铁板"程度。修好前 5.8~7.8%，现在 <0.1%。
##   2. 东西 wrap 的两列梯度 vs 全图中位数 —— 接缝。修好前是 4.6 倍、列均值有
##      0.034 的阶梯（成因：噪声倍频不是整数，wrap 处采样相位跳 0.35 个纹理周期）；
##      现在两列梯度落在中位数附近，列均值平滑。
##   3. 场视口 GPU 时间（30 帧预热 + 120 帧采样）。
##
## 必须用图形渲染跑（headless 是 dummy 渲染器，读回全 0）：
##   godot --path Project/project-keynes --rendering-driver opengl3 \
##     --resolution 320x200 --script res://tools/probe_cloud_shadow_field.gd
##
## 环境变量（排查用）：PK_FOLD_SHIFT / PK_NO_WRAP / PK_TILE_REPEAT

const OUT_DIR := "res://tmp/cloud_tex_dump"
const MAP_W := 80
const MAP_H := 60
const HEX_SIZE := 22.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var world := WorldData.new()
	var period := HexUtils.wrap_period_x(MAP_W, HEX_SIZE)
	var bounds: Rect2 = DCSurfaceBaker.compute_world_bounds(MAP_W, MAP_H, HEX_SIZE)
	world.world_bounds = bounds
	world.wrap_period_x = period
	world.lut_dims = Vector2i(8, 8)
	world.enum_atlas_tex = _flat_tex(32, 32, Color(0, 0, 0, 1))
	world.weather_lut_tex = _flat_tex(8, 8, Color(0.0, 0.0, 0.92, 0.0))
	world.weather_lut_prev_tex = world.weather_lut_tex
	world.weather_lut_update_usec = 1234

	var map := MapData.new(MAP_W, MAP_H)
	var field := CloudShadowField.new()
	root.add_child(field)
	field.wind_lut_changed.connect(func(_a, _b, _c): pass)
	field.configure(bounds, world, map, null, period, 2, "", false, HEX_SIZE * 2.0)
	# 与 scenes/player_game.tscn 的 HexRenderer 取值一致，否则量到的分布不是线上那套。
	field.set_tuning(0.62, 0.58, 0.46, 2.8, 0.035, 1.0, 0.5, 0.54, 1.0, 0.035,
		0.55, 12.5, 0.25, 0.4, 1.8, 1.0, 0.45, 4.0)
	if OS.has_environment("PK_TILE_REPEAT"):
		field.set_tuning(0.62, 0.58, 0.46, 2.8, 0.035, 1.0, 0.5, 0.54,
			float(OS.get_environment("PK_TILE_REPEAT")), 0.035,
			0.55, 12.5, 0.25, 0.4, 1.8, 1.0, 0.45, 4.0)
	# 把 fold 挪到别的经度：若接缝跟着 fold 走，说明是 wrap 的伪影；若消失，
	# 说明原来那一列强梯度只是这块噪声在这一经度上本来就很陡。
	var shift := float(OS.get_environment("PK_FOLD_SHIFT")) if OS.has_environment("PK_FOLD_SHIFT") else 0.0
	if shift > 0.0:
		field._field_material.set_shader_parameter("wrap_origin_x", shift)
	if OS.has_environment("PK_NO_WRAP"):
		field._field_material.set_shader_parameter("wrap_period_x", 0.0)
		print("[probe] wrap disabled")
	print("[probe] fold_shift=%.1f" % shift)
	field.set_world_time(0.0)
	for i in range(6):
		await process_frame
		await RenderingServer.frame_post_draw

	print("[probe] has_weather=%s mode=%d viewport=%s" % [
		field.has_weather_source(), field._viewport.render_target_update_mode,
		field._viewport.size])
	var size := field.get_quality_resolution()
	print("[probe] period=%.2f bounds=%s field=%s" % [period, bounds, size])
	var image: Image = field.get_field_texture().get_image()
	if image == null:
		printerr("[probe] field image null")
		quit(2)
		return
	image.save_png(OUT_DIR + "/field_uniform_weather.png")
	_stats(image, "uniform")
	print("[probe] gpu_ms=%s" % (await _gpu_ms(field)))
	await _check_include(image)
	await _check_composite(image)
	print("[probe] png -> %s/field_uniform_weather.png" % OUT_DIR)
	quit(0)


func _fold_col(w: int) -> int:
	return int(round(44.0 / (HexUtils.wrap_period_x(MAP_W, HEX_SIZE) + 88.0) * float(w)))


func _fold_col2(w: int) -> int:
	var period := HexUtils.wrap_period_x(MAP_W, HEX_SIZE)
	return int(round((44.0 + period) / (period + 88.0) * float(w)))


## cloud_shadow.gdshaderinc 的 PK_CLOUD_SHADOW_DIRECT 分支只有桌面高档的
## world_map/水面程序会编；这里单独编一次，防止软膝改动只在一半程序里生效。
func _check_include(field_image: Image) -> void:
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
#define PK_CLOUD_SHADOW_DIRECT
#include "res://shaders/include/cloud_shadow.gdshaderinc"
void fragment() {
	COLOR = vec4(vec3(cloud_shadow_direct_visibility(UV, 1.0)), 1.0);
}
"""
	var viewport := SubViewport.new()
	viewport.size = Vector2i(8, 8)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var rect := ColorRect.new()
	rect.size = Vector2(8, 8)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("cloud_shadow_tex", ImageTexture.create_from_image(field_image))
	material.set_shader_parameter("cloud_shadow_field_bound", true)
	material.set_shader_parameter("cloud_shadow_strength", 0.62)
	rect.material = material
	viewport.add_child(rect)
	for i in range(3):
		await process_frame
		await RenderingServer.frame_post_draw
	print("[probe] include direct pixel=%.4f (1.0 = 无云影)" % \
		float(viewport.get_texture().get_image().get_pixel(4, 4).r))
	viewport.queue_free()


## composite 变体只在非 direct 路径（LOW / 移动 / Web）出现，其它测试都不编它。
## 这里把它真的画一遍：编译失败会打印 shader 错误，读回值也会明显偏白。
## 场视口的 GPU 时间：预热 30 帧再采 120 帧，取平均/p95（与 2026-11-09 那份
## 分档验证用同一套 RenderingServer 计时接口）。
func _gpu_ms(field) -> String:
	var viewport: SubViewport = field._viewport
	var rid := viewport.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	for i in range(30):
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		await RenderingServer.frame_post_draw
	var samples := PackedFloat32Array()
	for i in range(120):
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		await RenderingServer.frame_post_draw
		samples.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	samples.sort()
	var total := 0.0
	for v in samples:
		total += v
	return "avg=%.4f p95=%.4f max=%.4f" % [
		total / float(samples.size()), samples[int(samples.size() * 0.95)], samples[samples.size() - 1]]


func _check_composite(field_image: Image) -> void:
	var shader := ResourceLoader.load(CloudShadowField.COMPOSITE_SHADER_PATH,
		"Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		print("[probe] composite shader load FAILED")
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(16, 16)
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var rect := ColorRect.new()
	rect.color = Color.WHITE
	rect.size = Vector2(16, 16)
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("cloud_shadow_tex", ImageTexture.create_from_image(field_image))
	material.set_shader_parameter("cloud_shadow_strength", 0.46)
	rect.material = material
	viewport.add_child(rect)
	for i in range(3):
		await process_frame
		await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image()
	var v := float(result.get_pixel(8, 8).r)
	print("[probe] composite pixel=%.4f (1.0 = 无云影，明显 <1 才说明生效)" % v)
	viewport.queue_free()


func _flat_tex(w: int, h: int, color: Color) -> ImageTexture:
	var image := Image.create(w, h, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _stats(image: Image, tag: String) -> void:
	var w := image.get_width()
	var h := image.get_height()
	var data := image.get_data()
	var counts := PackedInt32Array()
	counts.resize(16)
	var sum := 0.0
	var max_col_step := 0.0
	var max_row_step := 0.0
	var col_step_sum := 0.0
	var row_step_sum := 0.0
	for y in range(h):
		for x in range(w):
			var v := float(data[(y * w + x) * 4]) / 255.0
			sum += v
			counts[mini(int(v * 16.0), 15)] += 1
			if x + 1 < w:
				var dx := absf(float(data[(y * w + x + 1) * 4]) / 255.0 - v)
				col_step_sum += dx
				max_col_step = maxf(max_col_step, dx)
			if y + 1 < h:
				var dy := absf(float(data[((y + 1) * w + x) * 4]) / 255.0 - v)
				row_step_sum += dy
				max_row_step = maxf(max_row_step, dy)
	var n := float(w * h)
	var sat_hi := 0
	var sat_lo := 0
	var mid := 0
	for i in range(16):
		if i >= 15:
			sat_hi += counts[i]
		elif i == 0:
			sat_lo += counts[i]
		else:
			mid += counts[i]
	print("[probe] %s mean=%.4f  ==1.0:%.2f%%  ==0.0:%.2f%%  middle:%.2f%%" % [
		tag, sum / n, 100.0 * float(sat_hi) / n, 100.0 * float(sat_lo) / n,
		100.0 * float(mid) / n])
	print("[probe] %s hist16=%s" % [tag, counts])
	print("[probe] %s |dx|avg=%.4f max=%.4f |dy|avg=%.4f max=%.4f" % [
		tag, col_step_sum / (float(w - 1) * float(h)), max_col_step,
		row_step_sum / (float(h - 1) * float(w)), max_row_step])
	# 东西 wrap 接缝：最后一列与第一列的内容应当是相邻采样
	var wrap_dx := 0.0
	var wrap_dy := 0.0
	for y in range(h):
		wrap_dx += absf(float(data[(y * w + 0) * 4]) - float(data[(y * w + w - 1) * 4])) / 255.0
	for x in range(w):
		wrap_dy += absf(float(data[((h - 1) * w + x) * 4]) - float(data[(0 * w + x) * 4])) / 255.0
	print("[probe] %s wrap_dx=%.4f wrap_dy=%.4f" % [
		tag, wrap_dx / float(h), wrap_dy / float(w)])
