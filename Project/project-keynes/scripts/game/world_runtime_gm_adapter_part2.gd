extends RefCounted

## Extracted world_runtime_gm_adapter.gd group 2; state stays with host.

func _gm_selected_snapshot(host, cell_idx: int) -> Dictionary:
	var cell = host._current_map.cell_at(cell_idx)
	if cell == null:
		return {}
	var country_summary = {}
	var country_snapshot = {}
	var treasury = {}
	var population = {}
	var market = {}
	var buildings = {}
	var families = {}
	if host._generator != null:
		var country = host._generator.get_country_facade() if host._generator.has_method("get_country_facade") else null
		if country != null:
			country_summary = country.cell_summary(cell_idx)
			var handle = int(country_summary.get("country_handle", 0))
			if handle != 0:
				country_snapshot = country.snapshot(handle)
				treasury = country.treasury_snapshot(handle)
		var economy = host._generator.get_economy_facade() if host._generator.has_method("get_economy_facade") else null
		if economy != null:
			population = economy.population_cell_snapshot(cell_idx)
			market = economy.market_cell_snapshot(cell_idx)
			buildings = economy.building_cell_snapshot(cell_idx)
			families = economy.family_cell_snapshot(cell_idx, 0, 64)
	return {
		"cell": {"index": cell_idx, "q": int(cell.q), "r": int(cell.r),
			"terrain": host._view_adapter.get_terrain(cell_idx) if host._view_adapter != null else int(cell.terrain),
			"landform": host._view_adapter.get_landform(cell_idx) if host._view_adapter != null else int(cell.landform),
			"temperature": host._view_adapter.get_temp(cell_idx) if host._view_adapter != null else float(cell.temperature),
			"moisture": host._view_adapter.get_moisture(cell_idx) if host._view_adapter != null else float(cell.moisture),
			"host.elevation": host._view_adapter.get_elevation(cell_idx) if host._view_adapter != null else float(cell.elevation)},
		"country_summary": country_summary,
		"country": country_snapshot,
		"treasury": treasury,
		"population": population,
		"market": market,
		"buildings": buildings,
		"families": families,
		"resources": host._gm_resource_snapshot(cell_idx),
	}



func _gm_resource_snapshot(host, cell_idx: int) -> Array:
	var out: Array = []
	if host._current_map == null:
		return out
	for profile in ResourceProfileRegistry.ordered():
		var field = ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values = host._current_map.get(field)
		if values is PackedFloat32Array and cell_idx < values.size():
			var reserve = float(values[cell_idx])
			if reserve > 0.000001:
				out.append({"id": String(profile.id), "name": profile.display_name, "reserve": reserve})
	return out



func _gm_recorder_snapshot(host) -> Dictionary:
	return {
		"performance": host._gm_one_recorder_state(host._perf_recorder),
		"tiles": host._gm_one_recorder_state(host._tile_data_recorder),
		"economy": host._gm_one_recorder_state(host._economy_data_recorder),
	}



func _gm_one_recorder_state(host, recorder: RefCounted) -> Dictionary:
	return host.HostRecorders._gm_one_recorder_state(recorder)



func _gm_execute_country_command(host, command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	return host.HostGmCommands._gm_execute_country_command(command_id, args, effective_day, sequence,
		host._generator, host._gm_selected_country_handle, host._gm_resolve_cell)



func _gm_execute_economy_command(host, command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	return host.HostGmCommands._gm_execute_economy_command(command_id, args, effective_day, sequence,
		host._generator, host._resolve_player_country_handle, host._resolve_player_start_cell, _gm_resolve_cell)



func _gm_validate_args(host, spec: Dictionary, raw_args: Dictionary) -> Dictionary:
	return host.HostGmCommands._gm_validate_args(spec, raw_args)



func _gm_convert_arg(host, value, spec: Dictionary) -> Dictionary:
	return host.HostGmCommands._gm_convert_arg(value, spec)



func _gm_find_command_spec(host, command_id: String) -> Dictionary:
	for raw in host.get_gm_capabilities().get("host.commands", []):
		var spec: Dictionary = raw
		if String(spec.get("id", "")) == command_id:
			return spec
	return {}



func _gm_resolve_cell(host, args: Dictionary) -> int:
	return int(args.get("cell", int(host._selected_cell.index) if host._selected_cell != null else -1))



func _gm_selected_country_handle(host) -> int:
	if host._selected_cell == null or host._generator == null or not host._generator.has_method("get_country_facade"):
		return 0
	var facade = host._generator.get_country_facade()
	return int(facade.cell_summary(int(host._selected_cell.index)).get("country_handle", 0)) if facade != null else 0



func _gm_set_click_claim_territory_enabled(host, enabled: bool) -> Dictionary:
	if enabled:
		if host._generator == null or host._world_clock == null or host._current_map == null:
			return host._gm_error("world_not_ready", "世界尚未生成，无法启用点击接管。")
		if host._player_country_handle == 0:
			host._player_country_handle = host._resolve_player_country_handle()
		if host._player_country_handle == 0:
			return host._gm_error("player_country_unavailable", "无法解析玩家国家，点击接管未启用。")
	host._gm_click_claim_territory_enabled = enabled
	if not enabled:
		host._gm_click_claim_pending_days.clear()
	host.gm_toggle_changed.emit("simulation.click_claim_territory", enabled)
	return {"ok": true, "code": "ok", "enabled": enabled,
		"message": "点击地块接管领土已%s。" % ("启用" if enabled else "关闭")}



func _gm_claim_selected_cell(host, cell: HexCell) -> void:
	var cell_idx = int(cell.index)
	if host._current_map == null or cell_idx < 0 or cell_idx >= host._current_map.cell_count():
		host._gm_emit_claim_result(host._gm_error("invalid_cell", "所选地块无效。"), cell_idx)
		return
	if cell_idx < host._current_map.is_water_arr.size() and host._current_map.is_water_arr[cell_idx] != 0:
		host._gm_emit_claim_result(host._gm_error("water_territory", "水域不能成为国家领土。"), cell_idx)
		return
	if host._player_country_handle == 0:
		host._player_country_handle = host._resolve_player_country_handle()
	if host._player_country_handle == 0:
		host._gm_emit_claim_result(host._gm_error("player_country_unavailable", "无法解析玩家国家。"), cell_idx)
		return
	var facade = host._generator.get_country_facade() if host._generator != null \
		and host._generator.has_method("get_country_facade") else null
	if facade == null:
		host._gm_emit_claim_result(host._gm_error("country_facade_unavailable", "国家运行时尚未就绪。"), cell_idx)
		return
	var current_handle = int(facade.cell_summary(cell_idx).get("country_handle", 0))
	if current_handle == host._player_country_handle:
		host._gm_emit_claim_result({"ok": true, "code": "already_owned", "queued": false,
			"effective_day": -1, "message": "地块 #%d 已属于玩家国家。" % cell_idx,
			"data": {}}, cell_idx)
		return
	var current_day = host._world_clock.day_index() if host._world_clock != null else -1
	var pending_day = int(host._gm_click_claim_pending_days.get(cell_idx, -1))
	if pending_day >= current_day:
		host._gm_emit_claim_result({"ok": true, "code": "already_queued", "queued": true,
			"effective_day": pending_day, "message": "地块 #%d 已排队等待接管。" % cell_idx,
			"data": {}}, cell_idx)
		return
	var result = host.execute_gm_command("country.transfer_territory", {
		"cell": cell_idx, "country_handle": host._player_country_handle})
	if bool(result.get("ok", false)) and bool(result.get("queued", false)):
		host._gm_click_claim_pending_days[cell_idx] = int(result.get("effective_day", current_day + 1))
	host._gm_emit_claim_result(result, cell_idx)



func _gm_emit_claim_result(host, raw_result: Dictionary, cell_idx: int) -> void:
	var result = raw_result.duplicate(true)
	var data: Dictionary = result.get("data", {}).duplicate(true)
	data["cell"] = cell_idx
	result["data"] = data
	host.gm_action_completed.emit("country.click_claim_territory", result)



func _gm_scaled_positive(host, value, scale: int) -> int:
	return host.HostGmCommands._gm_scaled_positive(value, scale)



func _gm_renderer_toggle_state(host, property_name: String) -> Dictionary:
	if host._renderer == null:
		return host._gm_error("renderer_unavailable", "渲染器尚未就绪。")
	return {"ok": true, "enabled": bool(host._renderer.get(property_name))}


# [terrain-material-tiles] GM 开关「材质贴图门禁视图」切换时打印门禁四值（renderer 侧 /
# world 侧 / 材质 uniform），供对照 shader dv7 纯色：绿=激活 蓝=tex未绑定 品红=enabled=false 橙=q<2。


func _print_terrain_material_gate_state(host) -> void:
	if host._renderer == null:
		return
	print("[terrain-mat-gate] debug_view=%d（绿=激活 蓝=tex未绑定 品红=enabled=false 橙=q<2）" % \
		host._renderer.terrain_surface_debug_view)
	print("[terrain-mat-gate] renderer 侧: q=%d enabled=%s" % [
		host._renderer.visual_quality, str(host._renderer.terrain_materials_enabled)])
	if host._renderer._world != null:
		print("[terrain-mat-gate] world 侧: tex=%s bound=%s" % [
			str(host._renderer._world.terrain_material_tex != null),
			str(host._renderer._world.terrain_material_tex_bound)])
	if host._renderer._shader_mat != null:
		var mat: ShaderMaterial = host._renderer._shader_mat
		print("[terrain-mat-gate] 材质 uniform: enabled=%s bound=%s q=%s tex=%s" % [
			str(mat.get_shader_parameter("terrain_materials_enabled")),
			str(mat.get_shader_parameter("terrain_material_tex_bound")),
			str(mat.get_shader_parameter("visual_quality")),
			str(mat.get_shader_parameter("terrain_material_tex") != null)])


# GM 开关「Cell 索引视图」：shader 的 dv1 分支直出 decode_cell_index 的哈希色，
# 绕开整条着色管线，卡在 map_index_atlas 之后、cell_lut_uv/enum_lut 之前。
#   彩色马赛克（每格一色）= 索引图正常，塌缩发生在 LUT 采样一侧
#   纯黑                  = cid<0，采到 1×1 白纹理（0xFFFF 哨兵），索引图未真正绑定
#   整片单一非黑色        = cid 恒定，索引图采到常量
# 一并打印 CPU 侧真值，便于和屏幕结果对照。


func _print_cell_index_view_state(host) -> void:
	if host._renderer == null:
		return
	print("[cell-index-view] 彩色马赛克=索引图正常 / 纯黑=cid<0 索引图失效 / 单一色=cid 恒定")
	var world = host._renderer._world
	if world != null:
		var atlas: Texture2D = world.enum_atlas_tex
		print("[cell-index-view] world 侧: atlas=%s size=%s derived=%s lut_dims=%s" % [
			str(atlas != null), str(atlas.get_size()) if atlas != null else "-",
			str(world.derived_size), str(world.lut_dims)])
	if host._renderer._shader_mat != null:
		var mat: ShaderMaterial = host._renderer._shader_mat
		var bound: Texture2D = mat.get_shader_parameter("map_index_atlas")
		print("[cell-index-view] 材质 uniform: map_index_atlas=%s size=%s lut_dims=%s" % [
			str(bound != null), str(bound.get_size()) if bound != null else "-",
			str(mat.get_shader_parameter("lut_dims"))])


# GM 开关「enum_lut 直读视图」：shader 的 dv8 分支直出 texture(enum_lut, cell_lut_uv(cid))，
# 卡在 Cell 索引视图的下一环——索引已确认有效时，这一档判定 LUT 采样本身。
#   分区着色（色相=biome 哈希，亮度=fog_k）= LUT 正常
#   纯黑 = biome 0 且 fog_k 0，整张 LUT 读成零；这正是「发暗偏蓝像蒙在水下」的成因
#   品红 = cid<0，不该出现在这一档
# 同时对比材质上绑的 enum_lut 与 world.enum_lut_tex 是否为同一对象：LUT 走
# ImageTexture.update() 原地上传，设计上假定对象恒定，一旦对象换过而材质没重绑，
# 材质就会一直采着旧纹理。


func _print_enum_lut_view_state(host) -> void:
	if host._renderer == null:
		return
	print("[enum-lut-view] 分区着色=LUT 正常 / 纯黑=LUT 读成零 / 品红=cid<0")
	var world = host._renderer._world
	var world_tex: Texture2D = world.enum_lut_tex if world != null else null
	if world != null:
		print("[enum-lut-view] world 侧: enum_lut=%s size=%s lut_dims=%s" % [
			str(world_tex != null), str(world_tex.get_size()) if world_tex != null else "-",
			str(world.lut_dims)])
	if host._renderer._shader_mat != null:
		var mat: ShaderMaterial = host._renderer._shader_mat
		var bound: Texture2D = mat.get_shader_parameter("enum_lut")
		var same_object: bool = bound != null and bound == world_tex
		print("[enum-lut-view] 材质 uniform: enum_lut=%s size=%s 与 world 同对象=%s" % [
			str(bound != null), str(bound.get_size()) if bound != null else "-",
			str(same_object)])
		if bound != null and not same_object:
			push_warning("[enum-lut-view] 材质绑的 enum_lut 不是 world.enum_lut_tex；"
				+ "日刷内容全部落在另一张纹理上")


# GM 开关「河流 host.flow 视图」：屏幕给的是 shader 采到的 host.flow，这里补上 CPU 侧的
# height_tex.B / tiled host.flow 绑定状态。注意 CPU 侧全绿并不能排除问题——GLES3 兜底成 4×4 白纹理时这里
# 每一项都正常，要判死必须看 dv16 的 textureSize。


func _print_river_flow_state(host) -> void:
	if host._renderer == null:
		return
	print("[river-host.flow-view] 黑底+细红线=正常 / 整屏红=host.flow 恒高（sampler 落到 GLES3 兜底白纹理，用 dv16 确认）")
	var world = host._renderer._world
	var tiled = false
	var tiles = world.visual_tiles if world != null else null
	if tiles != null and bool(tiles.ready) and tiles.layout != null \
			and String(tiles.layout.mode) == "tiled":
		tiled = true
	var world_tex: Texture2D = null
	if world != null:
		world_tex = tiles.height if tiled else world.height_tex
		print("[river-host.flow-view] world 侧: packed_in_height=true tiled=%s tex=%s size=%s derived_size=%s" % [
			str(tiled), str(world_tex != null),
			str(world_tex.get_size()) if world_tex != null else "-",
			str(world.derived_size)])
	if host._renderer._shader_mat != null:
		var bound_name = "visual_height_tiles" if tiled else "height_tex"
		var bound: Texture2D = host._renderer._shader_mat.get_shader_parameter(bound_name)
		var bound_fmt: int = bound.get_format() if bound != null and bound.has_method("get_format") else -1
		var want_fmt: int = Image.FORMAT_RGBA8
		print("[river-host.flow-view] 材质 uniform: %s=%s size=%s fmt=%d want=%d 与 world 同对象=%s has_flow_tex=%s" % [
			bound_name, str(bound != null), str(bound.get_size()) if bound != null else "-",
			bound_fmt, want_fmt,
			str(bound != null and bound == world_tex),
			str(host._renderer._shader_mat.get_shader_parameter("has_flow_tex"))])
		if bound == null:
			push_warning("[river-host.flow-view] %s 未绑定；GLES3 兜底白纹理会让整片陆地被判成河" % bound_name)
		elif bound_fmt != want_fmt and not tiled:
			push_warning("[river-host.flow-view] height_tex 格式=%d，期望 RGBA8（B=host.flow）；格式错会导致 height/host.flow 解码错乱" % [
				bound_fmt])
		elif tiled and bound != null and bound.has_method("get_format") \
				and bound_fmt != want_fmt and bound_fmt != -1:
			# Texture2DArray.get_format 在部分后端可用；不对则跳过。
			push_warning("[river-host.flow-view] visual_height_tiles 格式=%d，期望 RGBA8（B=host.flow）" % bound_fmt)
	print("[river-host.flow-view] river_strength=%.2f threshold_low=%.2f threshold_high=%.2f" % [
		host._renderer.river_strength, host._renderer.river_threshold_low, host._renderer.river_threshold_high])
	# 关键读数：源 float buffer 与编码字节的分布。src.hi_frac≈1 说明上游 river SDF 就
	# 产出了全 1（渲染无关的数据 bug）；src 正常而 out.hi_frac≈1 说明编码器；两者都正常
	# 却仍整屏红，才是上传/格式问题。upload=RGBA8 表示 height+host.flow 合并路径。
	print("[river-host.flow-view] encode=", DCAtlasEncoders.last_flow_encode_info)
	var world_now = host._renderer._world
	if world_now != null:
		print("[river-host.flow-view] world.flow_buffer size=%d（期望 %d）" % [
			world_now.flow_buffer.size(), world_now.derived_size.x * world_now.derived_size.y])


# GM 动作「输出 FlowTex 完整诊断」：这是一次性诊断，不进入每日 tick。
# CPU 侧输出生成/编码/上传元数据；GPU 侧通过现有 dv14/dv16/dv17 视图抓一帧，
# 让 WebGL2 实际采样到的 textureSize 与 texelFetch 分布也进入浏览器控制台。


func dump_flow_tex_report(host) -> Dictionary:
	if host._renderer == null:
		return host._gm_error("renderer_unavailable", "渲染器尚未就绪，无法输出 FlowTex 诊断。")
	var report = host._collect_flow_tex_report()
	host._print_flow_tex_report_section("runtime", report.get("runtime", {}))
	host._print_flow_tex_report_section("host.path", report.get("host.path", {}))
	host._print_flow_tex_report_section("buffer", report.get("buffer", {}))
	host._print_flow_tex_report_section("encode", report.get("encode", {}))
	host._print_flow_tex_report_section("textures", report.get("textures", {}))
	host._print_flow_tex_report_section("shader", report.get("shader", {}))
	host._print_flow_tex_report_section("samplers", report.get("samplers", []))

	var previous_view = int(host._renderer.terrain_surface_debug_view)
	var gpu_flow_image = await host._capture_flow_debug_view(14)
	report["gpu_flow_view"] = host._summarize_flow_debug_image(gpu_flow_image)
	host._print_flow_tex_report_section("gpu_flow_view14", report["gpu_flow_view"])
	var gpu_size_image = await host._capture_flow_debug_view(16)
	report["gpu_texture_size"] = host._decode_flow_texture_size_view(gpu_size_image)
	host._print_flow_tex_report_section("gpu_texture_size_view16", report["gpu_texture_size"])
	var gpu_texel_image = await host._capture_flow_debug_view(17)
	report["gpu_texel_fetch"] = host._summarize_flow_debug_image(gpu_texel_image)
	host._print_flow_tex_report_section("gpu_texel_view17", report["gpu_texel_fetch"])
	host._renderer.terrain_surface_debug_view = previous_view

	var issues: PackedStringArray = report.get("issues", PackedStringArray())
	print("[host.flow-tex-report] issues=%s" % str(issues))
	print("[host.flow-tex-report] END")
	return {"ok": true, "code": "ok", "message": "FlowTex 完整诊断已输出（%d 个疑点；详情见 stdout/浏览器控制台）。" % issues.size(),
		"data": report}



func _collect_flow_tex_report(host) -> Dictionary:
	var current_method = String(RenderingServer.get_current_rendering_method()) \
		if RenderingServer.has_method("get_current_rendering_method") else "unknown"
	var adapter_api = String(RenderingServer.get_video_adapter_api_version()) \
		if RenderingServer.has_method("get_video_adapter_api_version") else "unknown"
	var adapter_name = String(RenderingServer.get_video_adapter_name()) \
		if RenderingServer.has_method("get_video_adapter_name") else "unknown"
	var report = {
		"runtime": {
			"os": OS.get_name(),
			"web_feature": OS.has_feature("web"),
			"feature_flags_web": DCFeatureFlags.is_web(),
			"compatibility_renderer": DCFeatureFlags.is_compatibility_renderer(),
			"rendering_method": current_method,
			"video_adapter_api": adapter_api,
			"video_adapter_name": adapter_name,
			"ticks_msec": Time.get_ticks_msec(),
		},
	}
	var world = host._renderer._world
	var material: ShaderMaterial = host._renderer._shader_mat
	var tiles = world.visual_tiles if world != null else null
	var tiled = tiles != null and bool(tiles.ready) and tiles.layout != null \
		and String(tiles.layout.mode) == "tiled"
	var world_flow = (tiles.height if tiled else world.height_tex) if world != null else null
	var effective_flow = world_flow
	var expected_buffer = int(world.derived_size.x * world.derived_size.y) if world != null else 0
	var buffer: PackedFloat32Array = world.flow_buffer if world != null else PackedFloat32Array()
	report["host.path"] = {
		"tiled": tiled,
		"layout_mode": String(tiles.layout.mode) if tiles != null and tiles.layout != null else "none",
		"shader_variant_tiled": material != null and material.shader != null
			and material.shader.code.contains("#define MAP_VISUAL_TILED"),
		"effective_flow": "visual_height_tiles.B" if tiled else "height_tex.B",
		"expected_buffer_pixels": expected_buffer,
	}
	report["buffer"] = host._flow_buffer_stats(buffer, expected_buffer)
	report["encode"] = DCAtlasEncoders.last_flow_encode_info.duplicate(true)
	report["textures"] = {
		"expected_compat_format": host._flow_format_descriptor(Image.FORMAT_RGBA8),
		"world_flow_tex_retired": host._flow_texture_descriptor(world.flow_tex if world != null else null),
		"world_height_or_tiles": host._flow_texture_descriptor(world_flow),
		"effective_flow": host._flow_texture_descriptor(effective_flow),
		"material_height_tex": host._flow_texture_descriptor(material.get_shader_parameter("height_tex") if material != null else null),
		"material_visual_height_tiles": host._flow_texture_descriptor(material.get_shader_parameter("visual_height_tiles") if material != null else null),
		"world_material_same_object": material != null and world_flow != null and (
			(material.get_shader_parameter("visual_height_tiles") == world_flow) if tiled
			else (material.get_shader_parameter("height_tex") == world_flow)),
		"has_flow_tex": material.get_shader_parameter("has_flow_tex") if material != null else false,
	}
	var shader_report = {}
	if material != null and material.shader != null:
		var shader_code: String = material.shader.code
		shader_report = {
			"source_path": String(host._renderer.get("_active_shader_source_path")),
			"debug_view": int(host._renderer.terrain_surface_debug_view),
			"pk_web_texture_budget": shader_code.contains("#define PK_WEB_TEXTURE_BUDGET"),
			"map_visual_tiled": shader_code.contains("#define MAP_VISUAL_TILED"),
			"shader_uniform_count": material.shader.get_shader_uniform_list().size(),
		}
	report["shader"] = shader_report
	var samplers: Array = host._flow_sampler_inventory(material)
	report["samplers"] = samplers
	var issues = PackedStringArray()
	if world == null:
		issues.append("world_missing")
	if material == null or material.shader == null:
		issues.append("terrain_material_or_shader_missing")
	if buffer.size() != expected_buffer:
		issues.append("flow_buffer_size_mismatch")
	var buffer_stats: Dictionary = report["buffer"]
	if float(buffer_stats.get("hi_frac", 0.0)) >= 0.98:
		issues.append("flow_buffer_almost_all_high")
	var effective_desc: Dictionary = report["textures"]["effective_flow"]
	if not bool(effective_desc.get("bound", false)):
		issues.append("effective_flow_texture_missing")
	if material != null:
		var expected_name = "visual_height_tiles" if tiled else "height_tex"
		var effective_bound = material.get_shader_parameter(expected_name)
		if effective_bound == null:
			issues.append("effective_flow_uniform_unbound")
		if not bool(material.get_shader_parameter("has_flow_tex")):
			issues.append("has_flow_tex_false")
		if material.shader != null:
			if material.shader.code.contains("uniform sampler2D flow_tex") \
					or material.shader.code.contains("uniform sampler2DArray visual_flow_tiles"):
				issues.append("retired_flow_sampler_still_declared")
		if not tiled and effective_bound != null and effective_bound.has_method("get_format") \
				and int(effective_bound.get_format()) != Image.FORMAT_RGBA8:
			issues.append("legacy_height_tex_not_rgba8")
	if DCFeatureFlags.is_compatibility_renderer():
		if samplers.size() > 8:
			issues.append("compat_sampler_count_over_8")
		if not bool(shader_report.get("pk_web_texture_budget", false)):
			issues.append("PK_WEB_TEXTURE_BUDGET_missing")
	report["issues"] = issues
	return report



func _flow_buffer_stats(host, buffer: PackedFloat32Array, expected: int) -> Dictionary:
	return host.HostValueHelpers._flow_buffer_stats(buffer, expected)



func _flow_texture_descriptor(host, texture) -> Dictionary:
	if texture == null:
		return {"bound": false}
	var out = {"bound": true, "class": texture.get_class(),
		"instance_id": texture.get_instance_id()}
	if texture.has_method("get_size"):
		out["size"] = str(texture.get_size())
	if texture.has_method("get_width"):
		out["width"] = int(texture.get_width())
	if texture.has_method("get_height"):
		out["height"] = int(texture.get_height())
	if texture.has_method("get_layers"):
		out["layers"] = int(texture.get_layers())
	if texture.has_method("get_format"):
		var format = int(texture.get_format())
		out["format"] = host._flow_format_descriptor(format)
	if texture.has_method("get_rid"):
		out["rid"] = str(texture.get_rid())
	if texture is Resource:
		out["resource_path"] = String((texture as Resource).resource_path)
	return out



func _flow_format_descriptor(host, format: int) -> Dictionary:
	return host.HostValueHelpers._flow_format_descriptor(format)



func _flow_sampler_inventory(host, material: ShaderMaterial) -> Array:
	var out: Array = []
	if material == null or material.shader == null:
		return out
	for raw in material.shader.get_shader_uniform_list():
		var uniform: Dictionary = raw
		if int(uniform.get("type", TYPE_NIL)) != TYPE_OBJECT:
			continue
		var name = String(uniform.get("name", ""))
		var entry = host._flow_texture_descriptor(material.get_shader_parameter(name))
		entry["name"] = name
		entry["hint"] = String(uniform.get("hint_string", ""))
		out.append(entry)
	return out



func _capture_flow_debug_view(host, view: int):
	if host._renderer == null:
		return null
	host._renderer.terrain_surface_debug_view = view
	await host.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var viewport = host.get_viewport()
	if viewport == null or viewport.get_texture() == null:
		return null
	return viewport.get_texture().get_image()



func _decode_flow_texture_size_view(host, image) -> Dictionary:
	if image == null:
		return {"ok": false, "reason": "viewport_readback_failed"}
	var width: int = int(image.get_width())
	var height: int = int(image.get_height())
	var values = PackedInt32Array()
	var confidence = PackedFloat32Array()
	for half in range(2):
		var y_lo = int((0.10 + 0.5 * float(half)) * float(height))
		var y_hi = int((0.40 + 0.5 * float(half)) * float(height))
		var value = 0
		var good = 0
		var total = 0
		for slot in range(12):
			var x = clampi(int((float(slot) + 0.5) / 12.0 * float(width)), 0, width - 1)
			var white = 0
			var dark = 0
			for y in range(y_lo, y_hi, 3):
				var color: Color = image.get_pixel(x, y)
				if color.r > 0.75 and color.g > 0.75 and color.b > 0.75:
					white += 1
				elif color.b > color.r and color.r < 0.35:
					dark += 1
			var bit_one = white > dark
			if white != dark:
				good += 1
			total += white + dark
			if bit_one:
				value |= 1 << (11 - slot)
		values.append(value)
		confidence.append(float(good) / 12.0)
	return {"ok": true, "size": str(Vector2i(width, height)),
		"width": values[0], "height": values[1], "confidence": confidence}



func _summarize_flow_debug_image(host, image) -> Dictionary:
	if image == null:
		return {"ok": false, "reason": "viewport_readback_failed"}
	var width: int = int(image.get_width())
	var height: int = int(image.get_height())
	var stride = maxi(1, mini(width, height) / 128)
	var recognized = 0
	var red = 0
	var gray = 0
	var gray_sum = 0.0
	for y in range(0, height, stride):
		for x in range(0, width, stride):
			var color: Color = image.get_pixel(x, y)
			if color.r > 0.80 and color.g < 0.20 and color.b < 0.20:
				red += 1
				recognized += 1
			elif absf(color.r - color.g) < 0.035 and absf(color.g - color.b) < 0.035:
				gray += 1
				gray_sum += (color.r + color.g + color.b) / 3.0
				recognized += 1
	return {"ok": true, "size": str(Vector2i(width, height)), "stride": stride,
		"recognized_frac": float(recognized) / float(maxi(1, int(ceil(float(width * height) / float(stride * stride))))),
		"red_frac": float(red) / float(maxi(recognized, 1)),
		"gray_frac": float(gray) / float(maxi(recognized, 1)),
		"gray_mean": gray_sum / float(maxi(gray, 1))}



func _print_flow_tex_report_section(host, name: String, value) -> void:
	print("[host.flow-tex-report][%s] %s" % [name, str(value)])


# [host.flow-diag] 列出主地图材质每个 sampler 当前绑的纹理与尺寸。dv16 报出的采样器尺寸
# 若和这里某一行对得上，就说明纹理单元串位了（绑到了另一张图）；若谁都对不上（例如 4×4），
# 那是引擎内部的兜底纹理。fmt 列同样关键：单通道（0=L8 / 2=R8）在 WebGL2 上就是建不起来的。


func _print_terrain_sampler_inventory(host) -> void:
	if host._renderer == null or host._renderer._shader_mat == null:
		return
	var mat: ShaderMaterial = host._renderer._shader_mat
	var shader: Shader = mat.shader
	if shader == null:
		return
	var lines: Array[String] = []
	for u in shader.get_shader_uniform_list():
		if int(u.get("type", TYPE_NIL)) != TYPE_OBJECT:
			continue
		var uname: String = str(u.get("name", ""))
		var tex = mat.get_shader_parameter(uname)
		if tex == null:
			lines.append("%s=<null>" % uname)
		elif tex is Texture2D:
			lines.append("%s=%dx%d fmt=%s" % [uname, int(tex.get_size().x),
				int(tex.get_size().y),
				str(tex.get_format()) if tex.has_method("get_format") else "?"])
		else:
			lines.append("%s=<%s>" % [uname, tex.get_class()])
	print("[host.flow-diag] 材质 sampler 清单（%d 项）：" % lines.size())
	for line in lines:
		print("[host.flow-diag]   ", line)


# GM 开关「dyn_lut / eco_lut 直读视图」：屏幕给的是 GPU 侧读到的值，这里补上
# CPU 侧真值——MapBaker 缓存着最后一次交给 ImageTexture.update() 的字节。两边一
# 对照就能把「打包出来就是零」和「字节没问题但没传上 GPU」分开。


func _print_daily_lut_upload_state(host, which: String) -> void:
	if host._renderer == null:
		return
	var tag = "%s-lut-view" % which
	print("[%s] 彩色梯度=正常 / 纯黑=整张读成零 / 品红=cid<0" % tag)
	var world = host._renderer._world
	var world_tex: Texture2D = world.get("%s_lut_tex" % which) if world != null else null
	if world != null:
		print("[%s] world 侧: tex=%s size=%s lut_dims=%s" % [
			tag, str(world_tex != null), str(world_tex.get_size()) if world_tex != null else "-",
			str(world.lut_dims)])
	if host._renderer._shader_mat != null:
		var bound: Texture2D = host._renderer._shader_mat.get_shader_parameter("%s_lut" % which)
		print("[%s] 材质 uniform: tex=%s 与 world 同对象=%s" % [
			tag, str(bound != null), str(bound != null and bound == world_tex)])
	var baker = host._gm_map_baker()
	if baker == null:
		print("[%s] MapBaker 不可用，取不到 CPU 侧字节" % tag)
		return
	var bytes = baker.get("_cell_%s_lut_bytes_cache" % which)
	if bytes is PackedByteArray:
		var nonzero = 0
		for b in bytes:
			if b != 0:
				nonzero += 1
		print("[%s] CPU 侧最后一次上传: %d 字节，非零 %d（%.1f%%）" % [
			tag, bytes.size(), nonzero,
			100.0 * float(nonzero) / float(maxi(bytes.size(), 1))])


# GM 开关「关闭地形 GI」：把 AO / bent normal / 弹射三个强度归零。按 hex_renderer
# 里 Terrain GI 那组 @export 的注释，这等价于精确回退到 2026-07-31 接入 GI 之前，
# 因此是把「GI 层」与「投影阴影层」分开的判定手段——两者共用同一张 horizon 图，
# 但 GI 另走 gi_horizon_lut 解码，投影阴影正常并不能证明 GI 也正常。


func _set_terrain_gi_disabled(host, disabled: bool) -> void:
	if disabled:
		if host._gi_saved_strengths.is_empty():
			for prop in host._GI_STRENGTH_PROPS:
				host._gi_saved_strengths[prop] = float(host._renderer.get(prop))
		for prop in host._GI_STRENGTH_PROPS:
			host._renderer.set(prop, 0.0)
	else:
		for prop in host._gi_saved_strengths:
			host._renderer.set(prop, host._gi_saved_strengths[prop])
		host._gi_saved_strengths.clear()
	host._print_terrain_gi_state("gi-off" if disabled else "gi-on")



func _print_terrain_gi_state(host, tag: String) -> void:
	if host._renderer == null:
		return
	print("[%s] ao=%.2f floor=%.2f bent=%.2f bounce=%.2f max_angle=%.3f horizon_strength=%.2f" % [
		tag, host._renderer.gi_ao_strength, host._renderer.gi_ao_floor, host._renderer.gi_bent_strength,
		host._renderer.gi_bounce_strength, host._renderer.terrain_horizon_max_angle,
		host._renderer.terrain_horizon_strength])
	var world = host._renderer._world
	if world != null:
		var horizon: Texture2D = world.terrain_horizon_tex
		print("[%s] horizon_tex=%s size=%s occluder=%s bounce_lut=%s" % [
			tag, str(horizon != null), str(horizon.get_size()) if horizon != null else "-",
			str(world.gi_occluder_tex != null), str(world.bounce_lut_tex != null)])
	if host._renderer._shader_mat != null:
		var mat: ShaderMaterial = host._renderer._shader_mat
		var lut = mat.get_shader_parameter("gi_horizon_lut")
		# gi_horizon_lut 是 PackedVector3Array(16) 的 uniform 数组而非纹理。
		# 首末两项是解析式的，对不上就说明数组没正确送达 shader。
		print("[%s] gi_horizon_lut size=%s head=%s tail=%s bound=%s" % [
			tag, str(lut.size()) if lut != null else "null",
			str(lut[0]) if lut != null and lut.size() > 0 else "-",
			str(lut[lut.size() - 1]) if lut != null and lut.size() > 0 else "-",
			str(mat.get_shader_parameter("gi_lut_bound"))])



func _gm_call_renderer_toggle(host, method: String, enabled: bool) -> bool:
	if host._renderer == null or not host._renderer.has_method(method):
		return false
	host._renderer.call(method, enabled)
	return true



func _gm_arg(host, name: String, type: String, required: bool) -> Dictionary:
	return host.HostValueHelpers._gm_arg(name, type, required)



func _gm_choice_arg(host, name: String, choices) -> Dictionary:
	return host.HostValueHelpers._gm_choice_arg(name, choices)



func _gm_positive_arg(host, name: String, type: String = "float") -> Dictionary:
	return host.HostValueHelpers._gm_positive_arg(name, type)



func _gm_day_arg(host) -> Dictionary:
	return host.HostValueHelpers._gm_day_arg()



func _gm_ok(host, message: String, queued: bool, effective_day: int) -> Dictionary:
	return host.HostValueHelpers._gm_ok(message, queued, effective_day)



func _gm_error(host, code: String, message: String, data: Dictionary = {}) -> Dictionary:
	return host.HostValueHelpers._gm_error(code, message, data)

