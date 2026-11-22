extends RefCounted

static func _poll_shader_hot_reload(host, delta: float) -> void:

	if not host.shader_hot_reload_enabled:
		return
	host._shader_hot_reload_accum += delta
	if host._shader_hot_reload_accum < maxf(host.shader_hot_reload_interval, 0.1):
		return
	host._shader_hot_reload_accum = 0.0

	var shader_mtime: int = _file_modified_time(host, host._active_shader_source_path)
	var material_mtime: int = _file_modified_time(host, host._active_material_source_path)
	var shader_changed: bool = shader_mtime > 0 and host._shader_source_mtime > 0 \
			and shader_mtime != host._shader_source_mtime
	var material_changed: bool = material_mtime > 0 and host._material_source_mtime > 0 \
			and material_mtime != host._material_source_mtime
	if not shader_changed and not material_changed:
		if host._shader_source_mtime == 0:
			host._shader_source_mtime = shader_mtime
		if host._material_source_mtime == 0:
			host._material_source_mtime = material_mtime
		return

	# [land-water-split 2026-11-02] shader 源文件热重载：两片 program 都要从磁盘重新
	# 取（水面 program 可能是同一份 world_map.gdshader 的另一个变体）。上一次编译失败
	# 可能只是编辑中的临时状态，这里清掉失败标记重新尝试。
	host._water_pass_failed = false
	host._split_program_failed = false
	host._drop_water_quad()
	host._load_shader()
	if host._map != null and host._world != null and host._shader_mat != null:
		host._apply_uniforms()
	host._push_cloud_shadow_material_inputs()
	print("[HexRenderer] hot-reloaded world shader/material")


static func _file_modified_time(_host, path: String) -> int:

	if path == "":
		return 0
	var fs_path := path
	if path.begins_with("res://") or path.begins_with("user://"):
		fs_path = ProjectSettings.globalize_path(path)
	return int(FileAccess.get_modified_time(fs_path))


static func _refresh_shader_hot_reload_baseline(host) -> void:

	host._shader_source_mtime = _file_modified_time(host, host._active_shader_source_path)
	host._material_source_mtime = _file_modified_time(host, host._active_material_source_path)
