extends SceneTree

# 离线 shader 语言级解析验证：get_shader_uniform_list 会触发完整的着色器语言
# 解析（CPU 侧、无需 GPU 上下文），语法错误会打印到 stderr。
func _init() -> void:
	var files := [
		"res://../../tmp/_SHADER_CODE_tiled.gdshader",
		"res://../../tmp/_SHADER_CODE_legacy.gdshader",
		"res://../../tmp/_SHADOW_SHADER_CODE_tiled.gdshader",
		"res://../../tmp/_SHADOW_SHADER_CODE_legacy.gdshader",
	]
	for path in files:
		print("=== validate: %s" % path)
		var text := FileAccess.get_file_as_string(path)
		if text.is_empty():
			print("  !! file missing or empty")
			continue
		var shader := Shader.new()
		shader.code = text
		var params := shader.get_shader_uniform_list()
		print("  parsed ok, uniforms=%d" % params.size())
	quit()
