extends RefCounted

## Stateless collaborator for ShrubLayer.

static func _apply_coverage_mesh_enabled(host) -> void:

	host._apply_world_quad_geometry()


static func _push_overlay_edge_transition_data(host) -> void:

	var neighbor_tex: Texture2D = (
		host._world.terrain_edge_neighbor_tex if host._world != null else null
	)
	var distance_tex: Texture2D = (
		host._world.terrain_edge_distance_tex if host._world != null else null
	)
	if host._weather_layer != null:
		host._weather_layer.set_edge_transition_data(
			neighbor_tex, distance_tex, host.terrain_ecotone_width)
	if host._fog_layer != null:
		host._fog_layer.set_edge_transition_data(
			neighbor_tex, distance_tex, host.terrain_ecotone_width)



static func _push_terrain_horizon_uniforms(host) -> void:

	if host._shader_mat != null:
		host._push_world_uniform("terrain_horizon_strength", host.terrain_horizon_strength)
		host._push_world_uniform("terrain_horizon_softness", host.terrain_horizon_softness)
		host._push_world_uniform("terrain_horizon_max_angle", host.terrain_horizon_max_angle)
		host._push_world_uniform("terrain_horizon_cast_floor", host.terrain_horizon_cast_floor)
		host._push_world_uniform("terrain_horizon_debug_view", host.terrain_horizon_debug_view)
		host._push_gi_strength_uniforms(host._shader_mat)
	# [land-water-split 2026-11-02] 走 world_map 的水面 program 与陆地共用同一套
	# horizon / GI 参数（海面也有地平线遮蔽与天空可见度）。这条路径是 GM 实时调参，
	# 不走 _apply_uniforms，漏推会让海面光照停在旧值。
	if host._water_mat != null and host._water_uses_world_map:
		host._push_gi_strength_uniforms(host._water_mat)
	# tiled 模式 horizon 在 visual_tiles.horizon（Texture2DArray），不写 world.terrain_horizon_tex。
	# 若仍按 legacy tex!=null 判断，会在 _apply_uniforms 末尾把植被 bound 盖回 false →
	# 直射遮蔽/天空 GI 全关，植株看起来「没光照」。
	var tiled = host._visual_tiles_active()
	var horizon_tex: Texture2D = null
	var horizon_bound = false
	if tiled:
		horizon_bound = host._world != null and host._world.visual_tiles != null \
			and bool(host._world.visual_tiles.horizon_ready)
	elif host._world != null:
		horizon_tex = host._world.terrain_horizon_tex
		horizon_bound = horizon_tex != null
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_terrain_horizon_inputs(horizon_tex, horizon_bound,
			host.terrain_horizon_strength, host.terrain_horizon_softness, host.terrain_horizon_max_angle,
			host.terrain_horizon_cast_floor, host.terrain_horizon_debug_view,
			float(host._shader_mat.get_shader_parameter("hillshade_coarse_strength")))
		layer.set_terrain_gi_inputs(host.build_gi_horizon_lut(host.terrain_horizon_max_angle),
			host.gi_ao_strength, host.gi_ao_floor, host.gi_bent_strength, host.gi_normal_floor)
	)
	host._sync_detail_and_activity_materials()
	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_terrain_lighting(host._shader_mat)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_terrain_lighting(host._shader_mat)
	if is_instance_valid(host._trade_visual_layer):
		host._trade_visual_layer.set_terrain_lighting(host._world, host._shader_mat)
	if is_instance_valid(host._military_visual_layer):
		host._military_visual_layer.set_terrain_lighting(host._world, host._shader_mat)


# [terrain-gi 2026-07-31] 4-bit 量化角的解码查表。shader 里 h_n = n/15·max_angle 只有 16 个
# 取值，把 cos²(h) 与可见锥质心方向 m=(h+π/2)/2 的 cos/sin 预先算好推过去，fragment 侧解
# 8 个方向的天空可见度与 bent normal 时就完全没有三角函数调用。
# max_angle 是 uniform（可在场景里调），所以这张表不能做成 shader 常量，必须随之重推。

static func _push_gi_strength_uniforms(host, sm: ShaderMaterial) -> void:

	sm.set_shader_parameter("gi_horizon_lut", host.build_gi_horizon_lut(host.terrain_horizon_max_angle))
	sm.set_shader_parameter("gi_lut_bound", true)
	sm.set_shader_parameter("gi_ao_strength", host.gi_ao_strength)
	sm.set_shader_parameter("gi_ao_floor", host.gi_ao_floor)
	sm.set_shader_parameter("gi_ao_smoothing", host.gi_ao_smoothing)
	sm.set_shader_parameter("gi_bent_strength", host.gi_bent_strength)
	sm.set_shader_parameter("gi_normal_floor", host.gi_normal_floor)
	sm.set_shader_parameter("gi_bounce_strength", host.gi_bounce_strength)
	sm.set_shader_parameter("gi_debug_view", host.gi_debug_view)


# 遮挡源纹理绑定 + 强度参数。gi_bounce_bound 由调用方在 bounce_lut 也就绪后单独置位，
# 因为弹射需要两者同时可用；只有 occluder 而没有 bounce_lut 时应保持档 0/1 行为。

static func _push_gi_uniforms(host, sm: ShaderMaterial, tiled: bool, visual_tiles) -> void:

	host._push_gi_strength_uniforms(sm)
	if tiled:
		sm.set_shader_parameter("visual_gi_occluder_tiles", visual_tiles.gi_occluder)
	else:
		sm.set_shader_parameter("gi_occluder_tex", host._world.gi_occluder_tex)


# ─── Terrain Horizon GPU 离屏烘焙（plan: terrain-horizon-gpu-bake 2026-07-03） ──────
# map_baker 选 GPU 路径时只在 world 上登记 terrain_horizon_gpu_params；这里用一次性
# SubViewport + canvas shader（res://shaders/bake/terrain_horizon_bake.gdshader）在场景树内
# 并行烘出 8 方向 horizon RGBA8。走引擎材质管线（非 RenderingDevice .glsl），PC/移动端同一
# 路径、规避 compute/SPIR-V 跨平台坑。SubViewport 需一帧渲染，故用 frame_post_draw 单次回读
# （set_map 是同步的、不能 await），回读为 ImageTexture 赋给 world.terrain_horizon_tex 后推 uniform。
const _HORIZON_BAKE_SHADER_PATH := "res://shaders/bake/terrain_horizon_bake.gdshader"


static func _maybe_bake_terrain_horizon_gpu(host) -> void:

	if host._world == null:
		return
	if host._visual_tiles_active() and not bool(host._world.visual_tiles.horizon_ready):
		host._start_visual_tile_horizon_bake(host._world)
		return
	if not host._world.terrain_horizon_gpu_pending:
		return
	if host._world.height_tex == null or host._world.hm_size.x <= 0 or host._world.hm_size.y <= 0:
		print("[terrain_horizon] GPU bake skipped: height_tex=%s hm_size=%s" % [
			str(host._world.height_tex != null), str(host._world.hm_size)])
		return
	var params: Dictionary = host._world.terrain_horizon_gpu_params
	if params.is_empty():
		return
	host._world.terrain_horizon_gpu_pending = false   # 防重入（regenerate 会重新置位）
	print("[terrain_horizon] GPU bake start: hm_size=%s params=%s" % [str(host._world.hm_size), str(params)])
	host._start_terrain_horizon_bake(host._world, params)



static func _start_visual_tile_horizon_bake(host, world: WorldData) -> void:

	if world == null or world.visual_tiles == null or world.visual_tiles.layout == null:
		return
	if host._visual_tile_horizon_baker != null:
		host._visual_tile_horizon_baker.cancel()
	var tiles = world.visual_tiles
	var generation_id = int(tiles.layout.generation_id)
	host._visual_tile_horizon_baker = host.VisualTileHorizonBakerScript.new()
	host._visual_tile_horizon_world = world
	host._visual_tile_horizon_baker.completed.connect(
		func(success: bool, report: Dictionary) -> void:
			host._on_visual_tile_horizon_completed(world, generation_id, success, report),
		CONNECT_ONE_SHOT)
	var params = world.terrain_horizon_gpu_params.duplicate(true)
	params["max_iterations"] = int(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/horizon_max_iterations", 2048))
	world.terrain_horizon_gpu_pending = false
	print("[visual-tiles/horizon] compute start generation=%d layers=%d" % [
		generation_id, int(tiles.layout.layer_count)])
	host._visual_tile_horizon_baker.start(tiles, generation_id, params)



static func _on_visual_tile_horizon_completed(host, world: WorldData, generation_id: int,
		success: bool, report: Dictionary) -> void:

	if world == null or world.visual_tiles == null \
			or int(world.visual_tiles.layout.generation_id) != generation_id:
		return
	if success:
		host._publish_visual_tile_horizon(world, report)
		return
	push_warning("[visual-tiles/horizon] compute failed (%s); using native baseline resample" %
		String(report.get("reason", "unknown")))
	host._run_visual_tile_horizon_fallback(world, generation_id, report)



static func _run_visual_tile_horizon_fallback(host, world: WorldData, generation_id: int,
		compute_report: Dictionary) -> void:

	var tiles = world.visual_tiles
	if host._world_ext == null :
		host._record_visual_tile_horizon_failure(world, "native_fallback_method_missing", compute_report)
		return
	var params = world.terrain_horizon_gpu_params
	var expected_source_bytes: int = world.hm_size.x * world.hm_size.y * 4
	var source_data = PackedByteArray()
	# [terrain-gi 2026-07-31] 全局遮挡源图。它与 horizon 独立降级：C++ 未 rebuild 或
	# map_index 不可用时 occluder_source 保持为空，AO 与 bent normal 仍然正常工作
	# （它们只需要 horizon），只有弹射项关闭。
	var occluder_source = PackedByteArray()
	var source_path = "existing_global_horizon"
	var source_ms = 0.0
	if world.terrain_horizon_tex != null:
		var source_image = world.terrain_horizon_tex.get_image()
		if source_image != null:
			if source_image.get_format() != Image.FORMAT_RGBA8:
				source_image.convert(Image.FORMAT_RGBA8)
			source_data = source_image.get_data()
	if world.gi_occluder_tex != null:
		var occ_image = world.gi_occluder_tex.get_image()
		if occ_image != null:
			if occ_image.get_format() != Image.FORMAT_RGBA8:
				occ_image.convert(Image.FORMAT_RGBA8)
			occluder_source = occ_image.get_data()
	if source_data.size() != expected_source_bytes:
		source_path = "native_global_horizon"
		var horizon_knobs = {
			"height_buffer": world.height_buffer,
			"width": world.hm_size.x,
			"height": world.hm_size.y,
			"world_size_x": world.world_bounds.size.x,
			"world_size_y": world.world_bounds.size.y,
			"wrap_x": world.wrap_period_x > 0.0001,
			"wrap_period_x": world.wrap_period_x,
			"steps": int(params.get("steps", 128)),
			"step_px": float(params.get("step_px", 8.0)),
			"step_growth": float(params.get("step_growth", 0.35)),
			"lowpass_radius": int(params.get("lowpass_radius", 1)),
			"max_horizon_angle": float(params.get("max_horizon_angle", 1.309)),
			"bias": float(params.get("bias", 0.004)),
			"height_world_scale": float(params.get("height_world_scale", 176.0)),
			"max_distance_world": float(params.get("max_distance_world", host.hex_size * 24.0)),
			"sea_level": clampf(float(params.get("sea_level", world.sea_level)), 0.0, 1.0),
		}
		var map_index_data = host._global_map_index_bytes(world)
		if map_index_data.size() == expected_source_bytes:
			horizon_knobs["emit_occluder_cells"] = true
			horizon_knobs["map_index_data"] = map_index_data
		var source_result: Dictionary = host._world_ext.encode_bake_horizon_tex_data(horizon_knobs)
		if bool(source_result.get("fallback", true)):
			host._record_visual_tile_horizon_failure(world,
				"baseline_horizon_failed:%s" % String(source_result.get("reason", "unknown")),
				compute_report)
			return
		source_data = source_result.get("data", PackedByteArray())
		source_ms = float(source_result.get("elapsed_ms", 0.0))
		occluder_source = source_result.get("occluder_data", PackedByteArray())
		if source_data.size() == expected_source_bytes:
			world.terrain_horizon_tex = ImageTexture.create_from_image(Image.create_from_data(
				world.hm_size.x, world.hm_size.y, false, Image.FORMAT_RGBA8, source_data))
		if occluder_source.size() == expected_source_bytes:
			world.gi_occluder_tex = ImageTexture.create_from_image(Image.create_from_data(
				world.hm_size.x, world.hm_size.y, false, Image.FORMAT_RGBA8, occluder_source))
	if source_data.size() != expected_source_bytes:
		host._record_visual_tile_horizon_failure(world, "baseline_horizon_size_mismatch", compute_report)
		return
	var occluder_available: bool = occluder_source.size() == expected_source_bytes

	var layout = tiles.layout
	var texel_world: Vector2 = layout.visual_domain.size / Vector2(layout.logical_size)
	var layer_reports: Array[Dictionary] = []
	var fallback_t0 = Time.get_ticks_usec()
	for layer_id in range(layout.layer_count):
		if host._world != world or world.visual_tiles != tiles \
				or int(layout.generation_id) != generation_id:
			return
		var tile_xy = Vector2i(layer_id % layout.grid_size.x,
			layer_id / layout.grid_size.x)
		var physical_origin: Vector2 = layout.visual_domain.position + Vector2(
			tile_xy.x * layout.interior_size.x - layout.gutter_px,
			tile_xy.y * layout.interior_size.y - layout.gutter_px) * texel_world
		var resample_knobs = {
			"generation_id": generation_id,
			"layer_id": layer_id,
			"source_data": source_data,
			"source_width": world.hm_size.x,
			"source_height": world.hm_size.y,
			"source_origin_x": world.world_bounds.position.x,
			"source_origin_y": world.world_bounds.position.y,
			"source_size_x": world.world_bounds.size.x,
			"source_size_y": world.world_bounds.size.y,
			"width": layout.layer_size.x,
			"height": layout.layer_size.y,
			"origin_x": physical_origin.x,
			"origin_y": physical_origin.y,
			"size_x": layout.layer_size.x * texel_world.x,
			"size_y": layout.layer_size.y * texel_world.y,
			"wrap_period_x": layout.wrap_period_x,
		}
		var result: Dictionary = host._world_ext.run_resample_visual_horizon_layer_pass(resample_knobs)
		if bool(result.get("fallback", true)) or int(result.get("generation_id", -1)) != generation_id \
				or not tiles.upload_horizon_layer(layer_id,
					result.get("data", PackedByteArray())):
			host._record_visual_tile_horizon_failure(world,
				"resample_layer_failed:%d:%s" % [layer_id, String(result.get("reason", "upload"))],
				compute_report)
			return
		# 遮挡源图与 horizon 完全同构（RGBA8、同尺寸、必须 NEAREST），因此直接复用同一个
		# resample pass，只换 source_data。任一层失败就整体放弃弹射，但不影响 horizon 发布。
		if occluder_available:
			var occ_knobs = resample_knobs.duplicate()
			occ_knobs["source_data"] = occluder_source
			var occ_result: Dictionary = host._world_ext.run_resample_visual_horizon_layer_pass(occ_knobs)
			if bool(occ_result.get("fallback", true)) \
					or int(occ_result.get("generation_id", -1)) != generation_id \
					or not tiles.upload_gi_occluder_layer(layer_id,
						occ_result.get("data", PackedByteArray())):
				occluder_available = false
				push_warning("[visual-tiles/gi] occluder resample failed at layer %d; bounce disabled"
					% layer_id)
		layer_reports.append({
			"layer": layer_id,
			"elapsed_ms": float(result.get("elapsed_ms", 0.0)),
			"hash": result.get("hash", 0),
		})
		var tree = Engine.get_main_loop() as SceneTree
		if tree != null:
			await tree.process_frame
	host._publish_visual_tile_horizon(world, {
		"ok": true,
		"path": "baseline_horizon_resample",
		"source_path": source_path,
		"source_ms": source_ms,
		"layers": layer_reports,
		"gi_occluder_ok": occluder_available,
		"compute_failure": compute_report,
		"total_ms": float(Time.get_ticks_usec() - fallback_t0) / 1000.0,
	})


# [terrain-gi 2026-07-31] legacy 全局 map_index（RGBA8，G/B=cell.index 低/高字节）的字节视图，
# 供 C++ 全局 horizon pass 顺带产出遮挡源 cell。拿不到就返回空数组，调用方据此关闭弹射。
#
# get_image() 是一次 GPU 回读，Godot 对桌面 GL（glGetTexImage）与 GLES/WebGL2
# （FBO + glReadPixels）走两条不同实现，后者不可信。而这份数据唯一的下游是
# GI 弹射的 bounce_lut，它在 PK_WEB_TEXTURE_BUDGET 下本就被编译掉了——所以
# Compatibility 后端直接跳过回读：既省一次全图回读，也避免把坏数据喂给 C++ pass。

static func _global_map_index_bytes(host, world: WorldData) -> PackedByteArray:

	if world == null or world.enum_atlas_tex == null:
		return PackedByteArray()
	if DCFeatureFlags.is_compatibility_renderer():
		return PackedByteArray()
	var image = world.enum_atlas_tex.get_image()
	if image == null:
		return PackedByteArray()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return image.get_data()



static func _publish_visual_tile_horizon(host, world: WorldData, report: Dictionary) -> void:

	if world == null or world.visual_tiles == null:
		return
	world.visual_tiles.horizon_ready = true
	# 弹射独立于 AO 降级：occluder 缺失只关闭档 2，档 0/1 仍由 horizon 驱动。
	world.visual_tiles.gi_occluder_ready = bool(report.get("gi_occluder_ok", false))
	world.visual_tiles.bake_report["horizon_path"] = report.get("path", "unknown")
	world.visual_tiles.bake_report["horizon"] = report
	if host._world == world:
		host._apply_uniforms()
	print("[visual-tiles/horizon] published %s" % JSON.stringify(report))



static func _record_visual_tile_horizon_failure(host, world: WorldData, reason: String,
		compute_report: Dictionary) -> void:

	if world != null and world.visual_tiles != null:
		world.visual_tiles.horizon_ready = false
		world.visual_tiles.gi_occluder_ready = false
		world.visual_tiles.bake_report["horizon_path"] = "neutral_failed"
		world.visual_tiles.bake_report["horizon"] = {
			"ok": false,
			"reason": reason,
			"compute_failure": compute_report,
		}
	push_warning("[visual-tiles/horizon] fallback failed: %s" % reason)


static func _start_terrain_horizon_bake(host, world: WorldData, params: Dictionary) -> void:

	var shader: Shader = load(host._HORIZON_BAKE_SHADER_PATH)
	if shader == null:
		push_warning("[terrain_horizon] GPU bake shader missing (%s); no cast shadow this world." % host._HORIZON_BAKE_SHADER_PATH)
		return
	# 清理上一次遗留的烘焙 viewport（快速连续 regenerate）。
	host._dispose_horizon_bake_vp()

	var size: Vector2i = world.hm_size
	var vp = SubViewport.new()
	vp.size = size
	vp.disable_3d = true
	# transparent_bg=true 关键：A 通道承载方向 6/7（S/SE）的打包数据，非透明度。若 false，
	# viewport 会把 alpha 强制为不透明 255 → S/SE 方向 horizon 恒为 max（15），阴影误判。
	# 配合 shader 的 blend_disabled（不做 alpha 预乘/混合），get_image 回读得到原样 RGBA 字节。
	vp.transparent_bg = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	var rect = ColorRect.new()
	rect.position = Vector2.ZERO
	rect.size = Vector2(size)
	var mat = ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("height_tex", world.height_tex)
	mat.set_shader_parameter("tex_dims", Vector2(size))
	mat.set_shader_parameter("steps", int(params.get("steps", 128)))
	mat.set_shader_parameter("step_px", float(params.get("step_px", 8.0)))
	mat.set_shader_parameter("step_growth", float(params.get("step_growth", 0.35)))
	mat.set_shader_parameter("lowpass_radius", int(params.get("lowpass_radius", 1)))
	mat.set_shader_parameter("max_horizon_angle", float(params.get("max_horizon_angle", 1.309)))
	mat.set_shader_parameter("bias", float(params.get("bias", 0.004)))
	mat.set_shader_parameter("height_world_scale", float(params.get("height_world_scale", 176.0)))
	mat.set_shader_parameter("max_distance_world", float(params.get("max_distance_world", host.hex_size * 24.0)))
	mat.set_shader_parameter("sea_level", clampf(float(params.get("sea_level", world.sea_level)), 0.0, 1.0))
	mat.set_shader_parameter("texel_x", float(params.get("texel_x", 1.0)))
	mat.set_shader_parameter("texel_y", float(params.get("texel_y", 1.0)))
	# 真正经度周期：柱状地图 x 环绕按此折叠，与运行期 wrap_map_uv 对齐，接缝无缝。
	mat.set_shader_parameter("wrap_period_x", float(params.get("wrap_period_x", 0.0)))
	rect.material = mat
	vp.add_child(rect)
	host.add_child(vp)

	host._horizon_bake_vp = vp
	host._horizon_bake_world = world
	host._horizon_bake_waited = 0
	# UPDATE_ONCE 的 viewport 需一次完整绘制才有内容；用 frame_post_draw 单次回读。
	RenderingServer.frame_post_draw.connect(host._on_terrain_horizon_frame_drawn, CONNECT_ONE_SHOT)


static func _on_terrain_horizon_frame_drawn(host) -> void:

	if host._horizon_bake_vp == null or not is_instance_valid(host._horizon_bake_vp):
		host._dispose_horizon_bake_vp()
		return
	# 时序保险：确保 SubViewport 至少经过一次完整绘制再回读（避免 UPDATE_ONCE 首帧时序空读）。
	if host._horizon_bake_waited < 1:
		host._horizon_bake_waited += 1
		RenderingServer.frame_post_draw.connect(host._on_terrain_horizon_frame_drawn, CONNECT_ONE_SHOT)
		return
	var vtex: ViewportTexture = host._horizon_bake_vp.get_texture()
	var img: Image = vtex.get_image() if vtex != null else null
	if img == null:
		push_warning("[terrain_horizon] GPU bake readback returned null image; no cast shadow this world.")
		host._dispose_horizon_bake_vp()
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	# 诊断：中心 + 一个偏移像素的字节，全 0 说明 vp 未渲染或采样坐标错。
	var wx: int = img.get_width()
	var hy: int = img.get_height()
	var mid: Color = img.get_pixel(wx / 2, hy / 2)
	var q1: Color = img.get_pixel(mini(wx / 3, wx - 1), mini(hy / 3, hy - 1))
	print("[terrain_horizon] GPU readback %dx%d fmt=%d mid(rgba*255)=[%d,%d,%d,%d] q=[%d,%d,%d,%d]" % [
		wx, hy, img.get_format(),
		int(round(mid.r * 255.0)), int(round(mid.g * 255.0)), int(round(mid.b * 255.0)), int(round(mid.a * 255.0)),
		int(round(q1.r * 255.0)), int(round(q1.g * 255.0)), int(round(q1.b * 255.0)), int(round(q1.a * 255.0))])
	var tex = ImageTexture.create_from_image(img)
	# 只回填当初发起烘焙的那个 world（避免 regenerate 竞态把旧图写到新 world）。
	if host._horizon_bake_world != null:
		host._horizon_bake_world.terrain_horizon_tex = tex
	# 关键修复：延迟回读晚于生成期 _apply_uniforms，必须把纹理显式补推给主 shader，否则主地图
	# 仍持 null → terrain_horizon_tex_bound=false → 运行期 terrain_horizon_direct_visibility 直接
	# return 1.0（无阴影）。_push_terrain_horizon_uniforms 只推标量 + 植被层，不含主 shader tex。
	var applied = false
	if host._world == host._horizon_bake_world and host._shader_mat != null:
		host._push_world_uniform("terrain_horizon_tex", tex)
		host._push_world_uniform("terrain_horizon_tex_bound", true)
		applied = true
	if host._world == host._horizon_bake_world:
		host._push_terrain_horizon_uniforms()   # 同步植被层的 horizon 输入
	print("[terrain_horizon] GPU bake applied to main shader=%s (strength=%.2f)" % [str(applied), host.terrain_horizon_strength])
	host._dispose_horizon_bake_vp()


static func _dispose_horizon_bake_vp(host) -> void:

	if host._horizon_bake_vp != null and is_instance_valid(host._horizon_bake_vp):
		host._horizon_bake_vp.queue_free()
	host._horizon_bake_vp = null
	host._horizon_bake_world = null



static func set_terrain_horizon_strength(host, v: float) -> void:

	host.terrain_horizon_strength = v



static func set_terrain_horizon_softness(host, v: float) -> void:

	host.terrain_horizon_softness = v



static func set_terrain_horizon_max_angle(host, v: float) -> void:

	host.terrain_horizon_max_angle = v



static func set_terrain_horizon_cast_floor(host, v: float) -> void:

	host.terrain_horizon_cast_floor = v



static func set_terrain_horizon_debug_view(host, v: int) -> void:

	host.terrain_horizon_debug_view = v


# 60 FPS 调查（2026-06-14）：完全禁用主地形 shader。
# 把 _world_quad.material = null → fragment shader 不跑，只剩 GPU 清屏 + canvas
# composite。用 ΔFPS 反推 hex_terrain/world_map shader 占多少 GPU 时间。
# 实验结束后再 toggle 回来恢复 _shader_mat。


static func toggle_world_shader_disabled(host) -> bool:

	if host._world_quad == null:
		print("[hex_renderer] _world_quad null, cannot toggle shader")
		return false
	host._shader_disabled_by_toggle = not host._shader_disabled_by_toggle
	if host._shader_disabled_by_toggle:
		host._world_quad.material = null
		# [web-water-pass] 两片是同一个渲染成本的两半，只关第一片会把"关掉 shader 的
		# ΔFPS"量小一半（水面 pass 仍在跑），探针结论就错了。
		if host._water_quad != null:
			host._water_quad.material = null
	else:
		host._world_quad.material = host._shader_mat
		if host._water_quad != null:
			host._water_quad.material = host._water_mat
	print("[hex_renderer] world shader disabled=%s — material=%s" % [
		str(host._shader_disabled_by_toggle),
		str(host._world_quad.material)
	])
	return host._shader_disabled_by_toggle



static func is_world_shader_disabled(host) -> bool:

	return host._shader_disabled_by_toggle


static func set_ecology_visual_quality(host, q: int) -> void:

	host.ecology_visual_quality = clampi(q, 0, 2)
	if host._shader_mat != null:
		host._push_world_uniform("ecology_visual_quality", host.ecology_visual_quality)


static func set_ecology_visual_strength(host, v: float) -> void:

	host.ecology_visual_strength = clampf(v, 0.0, 1.0)
	if host._shader_mat != null:
		host._push_world_uniform("ecology_visual_strength", host.ecology_visual_strength)


static func set_temperature_visual_strength(host, v: float) -> void:

	host.temperature_visual_strength = clampf(v, 0.0, 1.5)
	if host._shader_mat != null:
		host._push_world_uniform("temperature_visual_strength", host.temperature_visual_strength)


static func set_moisture_visual_strength(host, v: float) -> void:

	host.moisture_visual_strength = clampf(v, 0.0, 1.5)
	if host._shader_mat != null:
		host._push_world_uniform("moisture_visual_strength", host.moisture_visual_strength)


static func set_vitality_visual_strength(host, v: float) -> void:

	host.vitality_visual_strength = clampf(v, 0.0, 1.5)
	if host._shader_mat != null:
		host._push_world_uniform("vitality_visual_strength", host.vitality_visual_strength)


static func set_snowline_visual_strength(host, v: float) -> void:

	host.snowline_visual_strength = clampf(v, 0.0, 1.0)
	if host._shader_mat != null:
		host._push_world_uniform("snowline_visual_strength", host.snowline_visual_strength)

# 调试入口：toggle 雪盖"纯 dyn_snow（无 fbm 抖动）"渲染模式。
# 屏幕上的雪量将严格 = info_panel 显示的 cell.snow_cover（±量化误差），用于
# 验证 CPU→atlas→shader 链路。

static func set_debug_force_dyn_snow_only(host, v: bool) -> void:

	host.debug_force_dyn_snow_only = v
	if host._shader_mat != null:
		host._push_world_uniform("debug_force_dyn_snow_only", host.debug_force_dyn_snow_only)

# 运行时调整 dynamic_cell / dyn_atlas_smooth / ecology / ice atlas 的上传 stride。
# 1=每仿真日 2=每 2 仿真日 4=每 4 仿真日。值越大越省 CPU 但视觉变化越"卡"。
# 透传到 DynamicVisualAtlasUploadSystem.reconfigure；map_generator 持有 system 引用。

static func set_dyn_atlas_upload_stride(host, v: int) -> void:

	host.dyn_atlas_upload_stride = clampi(v, 1, 8)
	# 找到 MapGenerator 来 reconfigure 已注册的 system 实例。
	var mg = host.get_tree().root.find_child("MapGenerator", true, false)
	if mg != null and mg.has_method("set_dyn_atlas_upload_stride"):
		mg.set_dyn_atlas_upload_stride(host.dyn_atlas_upload_stride)


static func set_foliage_density_strength(host, v: float) -> void:

	host.foliage_density_strength = clampf(v, 0.0, 1.0)
	if host._shader_mat != null:
		host._push_world_uniform("foliage_density_strength", host.foliage_density_strength)


static func _wrap_period_x(host) -> float:

	if host._map == null:
		return 0.0
	return HexUtils.wrap_period_x(host._map.width, host.hex_size)


## 拆分状态的只读诊断（GM / 自动化 / 真机验收用）：一眼看出当前跑的是双 program
## 还是回退单 program、覆盖 mesh 是模块缺失还是构建成功、水面 program 种类。

static func land_water_split_diagnostics(host) -> Dictionary:

	return {
		"split_flag": host.split_land_water_passes,
		"split_active": host._split_active(),
		"water_pass_active": host._water_pass_active(),
		"split_program_failed": host._split_program_failed,
		"water_pass_failed": host._water_pass_failed,
		"coverage_enabled": host.terrain_coverage_mesh_enabled,
		"coverage_module_loaded": host._coverage_mesh_script != null,
		"coverage_ok": bool(host._coverage_mesh_result.get("ok", false)),
		"coverage_reason": String(host._coverage_mesh_result.get("reason", "")),
		"coverage_stats": host._coverage_mesh_stats.duplicate(),
		"land_program_land_only": host._shader_mat != null and host._shader_mat.shader != null \
			and host._shader_mat.shader.code.contains("PK_LAND_ONLY"),
		"water_program_kind": host._water_program_kind,
		"water_program_uses_world_map": host._water_uses_world_map,
	}


## 把"陆地用"的 mesh 同时给两块 quad：水面 quad 若有覆盖 mesh 则用覆盖 mesh，
## 否则与陆地共享同一份（今天的行为）。null 同时清空覆盖 mesh 缓存。

static func _set_world_quad_mesh(host, mesh: Mesh) -> void:

	if mesh == null:
		host._coverage_land_mesh = null
		host._coverage_water_mesh = null
		host._coverage_mesh_result = {}
		host._coverage_mesh_stats = {}
	if host._world_quad != null:
		host._world_quad.mesh = mesh
	if host._water_quad != null and is_instance_valid(host._water_quad):
		host._water_quad.mesh = host._water_quad_mesh(mesh)


## [web-water-pass][land-water-split 2026-11-02] 世界 quad 几何的唯一真源。
## 拆分激活时两张 program 可以各用一张保守覆盖 mesh（陆地 mesh / 水面 mesh，
## 纯区域只光栅化自己那条管线）；未拆分 / 覆盖 mesh 不可用时两片共享整张 quad
## （几何只算一次、GPU 只上传一次；两块 quad 的 VERTEX 逐顶点相同，水面 pass 的
## v_world 必须与陆地 pass 完全一致，否则 LUT 采到的 cell 会错位）。
## 任何改动 world quad 几何的地方都必须走这里。

static func _apply_world_quad_geometry(host) -> void:

	if host._world_quad == null:
		return
	if host._world == null or host._map == null or host._map.cell_count() == 0:
		host._coverage_land_mesh = null
		host._coverage_water_mesh = null
		host._coverage_mesh_stats = {}
		host._set_world_quad_mesh(null)
		return
	var bounds = host._world.world_bounds
	var wrap_period_x = host._wrap_period_x()
	var land_mesh: Mesh = null
	var water_mesh: Mesh = null
	host._coverage_mesh_result = {}
	host._coverage_mesh_stats = {}
	# 覆盖 mesh 只在"真的有两个 program"时才有意义：单 program（Web MID / 拆分关闭 /
	# 回退）必须由陆地 quad 铺满整张地图，否则水面像素会露背景。所以这里判定
	# _water_pass_active() 而不是 _split_active()。
	if host._water_pass_active() and host.terrain_coverage_mesh_enabled:
		var result = host._build_coverage_meshes(bounds, wrap_period_x)
		if bool(result.get("ok", false)):
			land_mesh = result.get("land_mesh", null) as Mesh
			water_mesh = result.get("water_mesh", null) as Mesh
			host._coverage_mesh_result = {"ok": true, "reason": "",
				"stats": (result.get("stats", {}) as Dictionary).duplicate()}
			host._coverage_mesh_stats = result.get("stats", {})
		else:
			host._coverage_mesh_result = {"ok": false,
				"reason": String(result.get("reason", "unknown"))}
			print("[hex_renderer/land-water-split] coverage mesh unavailable (%s); "
				% String(result.get("reason", "unknown"))
				+ "both programs share the full-map quad")
	if land_mesh == null or water_mesh == null:
		# 保底：整张 quad（拆分时两片共享；单 program 时就是今天的行为）。
		var base = host._build_world_quad_mesh(bounds, wrap_period_x)
		land_mesh = base
		water_mesh = base
		if host._coverage_mesh_result.is_empty():
			host._coverage_mesh_result = {"ok": false, "reason": "shared_full_quad"}
	host._coverage_land_mesh = land_mesh
	host._coverage_water_mesh = water_mesh
	host._set_world_quad_mesh(land_mesh)


## [land-water-split 2026-11-02] 动态调用 TerrainCoverageMesh 模块（契约见
## docs/plans/terrain-split-implementation-plan.md §2.3）：
##   static func build(world, world_bounds, wrap_period_x, block_world=...) -> Dictionary
## 模块尚不存在 / 加载失败 / 返回 ok=false / mesh 缺失 ⇒ 返回 ok=false 由调用方回退整张
## quad。构建只在 set_map / _rebuild 时发生，运行期不重建。

static func _build_coverage_meshes(host, bounds: Rect2, wrap_period_x: float) -> Dictionary:

	if not host.terrain_coverage_mesh_enabled:
		return {"ok": false, "reason": "disabled"}
	if host._coverage_mesh_script == null:
		if not ResourceLoader.exists(host.TERRAIN_COVERAGE_MESH_PATH):
			return {"ok": false, "reason": "module_missing"}
		host._coverage_mesh_script = ResourceLoader.load(
			host.TERRAIN_COVERAGE_MESH_PATH, "Script", ResourceLoader.CACHE_MODE_IGNORE) as Script
	if host._coverage_mesh_script == null:
		return {"ok": false, "reason": "module_load_failed"}
	var started_usec = Time.get_ticks_usec()
	var result: Variant = host._coverage_mesh_script.call(
		"build", host._world, bounds, wrap_period_x)
	var elapsed_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	if typeof(result) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "module_bad_result"}
	var out: Dictionary = result
	if not bool(out.get("ok", false)):
		return {"ok": false, "reason": String(out.get("reason", "module_reported_failure"))}
	if not (out.get("land_mesh") is Mesh) or not (out.get("water_mesh") is Mesh):
		return {"ok": false, "reason": "module_missing_meshes"}
	var stats: Dictionary = out.get("stats", {})
	stats["apply_ms"] = elapsed_ms
	out["stats"] = stats
	print("[hex_renderer/land-water-split] coverage meshes in %.1fms %s" % [elapsed_ms, str(stats)])
	return out



static func _push_visual_tile_layout_uniforms(host, material: ShaderMaterial, layout) -> void:

	material.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
	material.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
	material.set_shader_parameter("visual_grid_size", Vector2(layout.grid_size))
	material.set_shader_parameter("visual_interior_size", Vector2(layout.interior_size))
	material.set_shader_parameter("visual_layer_size", Vector2(layout.layer_size))
	material.set_shader_parameter("visual_logical_resolution", Vector2(layout.logical_size))
	material.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))



