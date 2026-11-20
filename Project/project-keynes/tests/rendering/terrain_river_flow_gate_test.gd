extends SceneTree

## [river-flow-gate 2026-11-19] 移动端河流消失的回归守卫。
##
## 症状：手机默认画质（auto → MOBILE_QUALITY_LOW）下整条河网、河口/岸线过渡和资源避河
## 全部消失，只剩地表色。根因是 has_flow_tex 被并进了
## DCFeatureFlags.water_flowmap_enabled()（移动端默认关），而 shader 用它做**静态河网
## 的总闸**：`scals.g = has_flow_tex ? height_px.b : 0.0`。flowmap 开关的本意只是省掉
## "慢速流速蠕动 + 海洋环流漂移"，与河网是否存在无关。
##
## 本测试守三件事：
##   1. 数据就绪时必须为真 —— 纯数据判定，与平台/画质动画开关无关；
##   2. 数据缺失（height 未就绪 / flow_buffer 不齐 / 尺寸退化）必须为假；
##   3. 两个发布点仍在调这个纯函数，且没有再把 water_flowmap_enabled 并回来。
##      平台开关在 headless 下无法伪造，所以这条用源码守卫（与 terrain_shader_variant_test
##      的源码符号守卫同一做法）。
##
## 运行：godot --headless --path . -s res://tests/rendering/terrain_river_flow_gate_test.gd

const Publish = preload("res://scripts/rendering/renderer_material_publish.gd")
const PUBLISH_PATH := "res://scripts/rendering/renderer_material_publish.gd"
const MATERIALS_PATH := "res://scripts/rendering/resource_visual_materials.gd"
const WORLD_MAP_PATH := "res://shaders/world_map.gdshader"
const FLOW_GATE_CALL := 'set_shader_parameter("has_flow_tex"'

var failures := 0


func _initialize() -> void:
	# 1) 数据就绪 ⇒ 开。含手机 hm=512 上限下的整图尺寸（被回归打掉的就是这一档）。
	check(Publish.flow_channel_ready(true, 600, Vector2i(20, 30)),
		"ready height+flow ⇒ channel on")
	check(Publish.flow_channel_ready(true, 512 * 300, Vector2i(512, 300)),
		"mobile-sized atlas ⇒ channel on")
	check(Publish.flow_channel_ready(true, 1, Vector2i(1, 1)),
		"1x1 minimal atlas ⇒ channel on")

	# 2) 数据缺失 ⇒ 关（不能靠"未绑采样得 0"兜底）。
	check(not Publish.flow_channel_ready(false, 600, Vector2i(20, 30)),
		"height texture missing ⇒ channel off")
	check(not Publish.flow_channel_ready(true, 599, Vector2i(20, 30)),
		"flow buffer shorter than hm ⇒ channel off")
	check(not Publish.flow_channel_ready(true, 0, Vector2i(20, 30)),
		"empty flow buffer ⇒ channel off")
	check(not Publish.flow_channel_ready(true, 600, Vector2i.ZERO),
		"zero hm size ⇒ channel off")
	check(not Publish.flow_channel_ready(true, 600, Vector2i(20, 0)),
		"degenerate hm rows ⇒ channel off")

	_check_push_sites()
	_check_shader_gate()
	print("terrain river flow gate: failures=%d" % failures)
	quit(0 if failures == 0 else 1)


## 每个 has_flow_tex 发布点都必须走 flow_channel_ready，不能再自己拼平台开关。
func _check_push_sites() -> void:
	for path in [PUBLISH_PATH, MATERIALS_PATH]:
		var source := _read_text(path)
		if source.is_empty():
			check(false, "%s readable" % path)
			continue
		var call_lines := 0
		for line in source.split("\n"):
			if not line.contains(FLOW_GATE_CALL):
				continue
			call_lines += 1
			check(line.contains("flow_channel_ready("),
				"%s pushes has_flow_tex through flow_channel_ready" % path)
			check(not line.contains("water_flowmap_enabled"),
				"%s does not gate has_flow_tex on the flowmap animation flag" % path)
		check(call_lines == 1, "%s has exactly one has_flow_tex push (got %d)"
			% [path, call_lines])


## shader 侧 has_flow_tex 是静态河网总闸：这条式子一旦被改写，上面的发布判定就不再是
## "有河/没河"的开关，整个回归的语义也就变了，必须一起复核。
func _check_shader_gate() -> void:
	var source := _read_text(WORLD_MAP_PATH)
	if source.is_empty():
		check(false, "%s readable" % WORLD_MAP_PATH)
		return
	check(source.contains("scals.g = has_flow_tex ? flow_raw : 0.0"),
		"world_map keeps has_flow_tex as the static river-network gate")


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func check(ok: bool, message: String) -> void:
	print("[river-flow-gate] ", "PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1
