extends SceneTree
## P0-8 平台探针：验证 cell-field 依赖的两个 GLES3/WebGL2 能力在**真实渲染后端**上成立。
##
## 背景（方案 §3.4 / §7）：
##   1) `texelFetch(sampler2DArray, ivec3(col,row,layer), 0)` —— canvas_item 里按整数坐标
##      取 per-cell 表。dummy 渲染器不校验，必须真后端跑一次。
##   2) `Texture2DArray.update_layer()` —— cell_table 的 layer1(state) 每天更新；若该调用
##      在 GLES3/WebGL2 上不成立或触发整张重传，就要退回三张独立 Texture2D。
##
## 用法（**必须带渲染后端，不能用 --headless**）：
##   godot --path Project/project-keynes --rendering-driver opengl3 \
##         -s res://tests/world/cell_table_platform_probe.gd
##   godot --path Project/project-keynes --rendering-driver vulkan \
##         -s res://tests/world/cell_table_platform_probe.gd
##
## 判据：打印 `[cell-table-probe] OK ...` 且 exit 0。任何 FAIL 都说明需要走契约 §5.3 的
## 退回路径（三张独立 Texture2D）。

const PROBE_W := 8
const PROBE_H := 4
# [cell-field-web 2026-11-18] layer3 = class_by_index 加入后实际发布 4 层（契约 §3 / Web 方案 §3.1），
# 探针跟着对齐：真正的发布层数若与 4 不同，这里就会与 cell_lut_baker 的断言对不上。
const PROBE_LAYERS := 4

var _failures := 0

func _init() -> void:
	var rendering_driver := str(ProjectSettings.get_setting("rendering/rendering_device/driver", ""))
	print("[cell-table-probe] headless=%s video_adapter=%s" % [
			str(DisplayServer.get_name() == "headless"),
			RenderingServer.get_video_adapter_name()])
	print("[cell-table-probe] driver_setting=%s backend=%s" % [
			rendering_driver, str(RenderingServer.get_video_adapter_api_version())])
	_probe_texel_fetch_contract()
	_probe_update_layer()
	print("[cell-table-probe] %s (%d failures)" % [
			"OK" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


func _probe_texel_fetch_contract() -> void:
	# 1) Texture2DArray 能按 (w, h, layers) 创建，且 layer 数、尺寸可读回。
	var images: Array[Image] = []
	for layer in PROBE_LAYERS:
		var img := Image.create_empty(PROBE_W, PROBE_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.1 * float(layer + 1), 0.2, 0.3, 1.0))
		images.append(img)
	var array_tex := Texture2DArray.new()
	var err := array_tex.create_from_images(images)
	_check(err == OK, "Texture2DArray.create_from_images returned OK (got %d)" % err)
	_check(array_tex.get_width() == PROBE_W and array_tex.get_height() == PROBE_H,
			"Texture2DArray dims readable (%dx%d)" % [array_tex.get_width(), array_tex.get_height()])
	_check(array_tex.get_layers() == PROBE_LAYERS,
			"Texture2DArray layer count = %d (got %d)" % [PROBE_LAYERS, array_tex.get_layers()])

	# 2) 每层读回的数据必须与写入一致 ⇒ 后端真的区分 layer（否则 texelFetch 的
	#    ivec3.z 毫无意义，整张表会退化成同一层）。
	for layer in PROBE_LAYERS:
		var back := array_tex.get_layer_data(layer)
		if back == null:
			_check(false, "get_layer_data(%d) returned null" % layer)
			continue
		var px := back.get_pixel(0, 0)
		var expected := 0.1 * float(layer + 1)
		_check(absf(px.r - expected) < 0.02,
				"layer %d round-trip r=%.3f (expected %.3f)" % [layer, px.r, expected])


func _probe_update_layer() -> void:
	# 3) update_layer 单层更新：只改 layer1，layer0/layer2 必须保持不变。
	var images: Array[Image] = []
	for layer in PROBE_LAYERS:
		var img := Image.create_empty(PROBE_W, PROBE_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.25, 0.25, 0.25, 1.0))
		images.append(img)
	var array_tex := Texture2DArray.new()
	var err := array_tex.create_from_images(images)
	if err != OK:
		_check(false, "create_from_images failed before update_layer probe (%d)" % err)
		return
	var patch := Image.create_empty(PROBE_W, PROBE_H, false, Image.FORMAT_RGBA8)
	patch.fill(Color(0.75, 0.5, 0.125, 1.0))
	array_tex.update_layer(patch, 1)
	var l0 := array_tex.get_layer_data(0)
	var l1 := array_tex.get_layer_data(1)
	var l2 := array_tex.get_layer_data(2)
	if l0 == null or l1 == null or l2 == null:
		_check(false, "get_layer_data returned null after update_layer")
		return
	_check(absf(l1.get_pixel(0, 0).r - 0.75) < 0.02,
			"update_layer(1) wrote the new texel (r=%.3f)" % l1.get_pixel(0, 0).r)
	_check(absf(l0.get_pixel(0, 0).r - 0.25) < 0.02,
			"update_layer(1) left layer0 untouched (r=%.3f)" % l0.get_pixel(0, 0).r)
	_check(absf(l2.get_pixel(0, 0).r - 0.25) < 0.02,
			"update_layer(1) left layer2 untouched (r=%.3f)" % l2.get_pixel(0, 0).r)
	# 4) 同一层可以重复更新（每日 dyn/state 刷新的实际用法）。
	patch.fill(Color(0.5, 0.5, 0.5, 1.0))
	array_tex.update_layer(patch, 1)
	var l1b := array_tex.get_layer_data(1)
	_check(l1b != null and absf(l1b.get_pixel(0, 0).r - 0.5) < 0.02,
			"update_layer is repeatable on the same layer")


func _check(cond: bool, label: String) -> void:
	if cond:
		print("[cell-table-probe] PASS %s" % label)
	else:
		_failures += 1
		push_error("[cell-table-probe] FAIL %s" % label)
