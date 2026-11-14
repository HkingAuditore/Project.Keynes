extends RefCounted

## Stateless collaborator for ShrubLayer.

static func set_settlement_core_buckets(host, value: PackedByteArray) -> void:

	host._settlement_core_buckets = value



static func _ready(host) -> void:

	host.z_as_relative = false
	host._ensure_resources()



static func setup(host, map: MapData, world: WorldData, bounds: Rect2, hex_size: float, visual_quality: int = 1) -> void:

	host._map = map
	host._world = world
	host._bounds = bounds
	host._hex_size = maxf(hex_size, 4.0)
	host._invalidate_chunk_spatial_cache()
	host._active_instance_count_valid = false
	host._visual_quality = clampi(visual_quality, 0, 2)
	host._native_offset_is_water_cache = PackedByteArray()
	host._native_offset_cache_dims = Vector2i.ZERO
	host._native_delta_common_knobs = {}
	# _ready/_ensure_resources 在 world/tiles 就绪前会编出 legacy 变体；setup 才是
	# 第一次拿到 visual_tiles 的入口，必须按实际 tiled 状态重建 shader，不能只 sync。
	var probe_start = Time.get_ticks_usec()
	host._ensure_shader_matches_tiles()
	print("[shrub-load] shader %.1fms" % [float(Time.get_ticks_usec()-probe_start)/1000.0])
	# 首次绘制编译成本：此刻同级的 ShrubLayer 都已建好，能拿到真实的"共享层数"。
	host._report_veg_shader_cost()
	probe_start = Time.get_ticks_usec()
	if host._defer_initial_rebuild and host._chunked_multimesh_enabled:
		clear(host, )
		host._last_rebuild_reason = "deferred_until_prefetch"
		print("[shrub-load] clear %.1fms" % [float(Time.get_ticks_usec()-probe_start)/1000.0])
	else:
		host._rebuild_instances()



static func set_defer_initial_rebuild(host, value: bool) -> void:

	host._defer_initial_rebuild = value



static func clear(host) -> void:

	host._instance_cell_indices = PackedInt32Array()
	host._instance_positions = PackedVector2Array()
	host._instance_rotations = PackedFloat32Array()
	host._instance_sizes = PackedFloat32Array()
	host._instance_seeds = PackedFloat32Array()
	host._instance_variants = PackedFloat32Array()
	host._instance_forms = PackedFloat32Array()
	host._instance_scores = PackedFloat32Array()
	host._instance_cells.clear()
	host._instance_count = 0
	host._far_instance_count = 0
	host._active_instance_count_cache = 0
	host._active_instance_count_valid = false
	host._cell_instance_lookup.clear()
	host._clear_chunk_nodes()
	if host._multimesh != null:
		host._multimesh.instance_count = 0
		host._multimesh.visible_instance_count = 0
	if host._shadow_multimesh != null:
		host._shadow_multimesh.instance_count = 0
		host._shadow_multimesh.visible_instance_count = 0
	host._shadow_built_total = 0
	# _shadow_chunk_nodes 已由 _clear_chunk_nodes() 释放
	if host._shadow_mmi != null:
		host._shadow_mmi.visible = false
	host._sync_single_wrap_nodes()
	host._sync_single_shadow_wrap_nodes()
	host.visible = false



static func set_camera_zoom(host, value: float) -> void:

	var next_zoom = clampf(value, 0.01, 16.0)
	if host._camera_zoom_initialized and absf(next_zoom - host._camera_zoom) < 0.001:
		return
	host._camera_zoom = next_zoom
	host._camera_zoom_initialized = true
	if host._family_batch_suppressed:
		host._zoom_visible_fraction = host._family_lod_fraction(host._camera_zoom)
		host._lod_zoom_t = host._zoom_visible_fraction
		host._lod_far_visible_fraction = host._family_far_fraction()
	else:
		var thresholds = host._resolved_lod_thresholds()
		var start = thresholds.x
		var finish = maxf(thresholds.y, start + 0.001)
		host._lod_zoom_t = smoothstep(start, finish, host._camera_zoom)
		var near_multiplier = host._resolved_lod_near_density_multiplier()
		host._lod_far_visible_fraction = 1.0 / maxf(near_multiplier, 1.0)
		host._zoom_visible_fraction = lerpf(host._lod_far_visible_fraction, 1.0, host._lod_zoom_t)
	host._lod_alpha = 1.0
	if host._material != null:
		host._material.set_shader_parameter("lod_alpha", host._lod_alpha)
	if host._shadow_material != null:
		host._shadow_material.set_shader_parameter("lod_alpha", host._lod_alpha)

	host._camera_lod_hidden = host._family_batch_suppressed and host._zoom_visible_fraction <= 0.0001
	host._active_instance_count_valid = false
	host.apply_visible_instance_fraction(host._shadow_fraction)
	# Shadows fade with zoom instead of switching off at one threshold.
	host._push_shadow_strength()



static func set_lod_debug_view(host, enabled: bool) -> void:

	if host._material != null:
		host._material.set_shader_parameter("lod_debug_view", enabled)



