extends RefCounted

## Stateless collaborator for ShrubLayer.

static func detail_render_family(host) -> int:

	var cfg = host._profile()
	if cfg != null and cfg.has_method("resolved_render_family"):
		return int(cfg.resolved_render_family())
	return 0



static func detail_visual_form(host) -> int:

	var cfg = host._profile()
	if cfg != null and cfg.has_method("resolved_visual_form"):
		return int(cfg.resolved_visual_form())
	return 3


# Per-profile shading the impostor shader needs. Source layers push it as
# uniforms; VegetationFamilyLayer writes it into the style LUT so a family
# material draws each of its profiles with its own response.

static func detail_style_shading(host) -> Dictionary:

	var cfg = host._profile()
	var arch = host._detail_kind()
	var is_deco = host._is_decoration_archetype(arch)
	var phenology_response = 1.0
	var phenology_color_dominance = 0.68
	var albedo_light_floor = 0.44
	match arch:
		host.DETAIL_TREE:
			phenology_color_dominance = 0.84
			albedo_light_floor = 0.60
			# Dedicated-colour trees (cloud forest, monsoon) behave as evergreens.
			if bool(cfg.base_color_override_enabled):
				phenology_response = 0.22
				phenology_color_dominance = 0.42
		host.DETAIL_CONIFER:
			phenology_response = 0.28
			phenology_color_dominance = 0.46
			albedo_light_floor = 0.60
		host.DETAIL_PALM, host.DETAIL_CACTUS:
			phenology_response = 0.16
			phenology_color_dominance = 0.40
			albedo_light_floor = 0.52
		host.DETAIL_REED:
			phenology_response = 0.72
		host.DETAIL_ROCK, host.DETAIL_SNOW_MOUND, host.DETAIL_DEAD_SNAG:
			phenology_response = 0.0
			phenology_color_dominance = 0.0
	var bloom = 0.0
	match arch:
		host.DETAIL_ALPINE_FLOWER: bloom = 0.85
		host.DETAIL_SHRUB: bloom = 0.16
		host.DETAIL_REED: bloom = 0.10
		host.DETAIL_CACTUS: bloom = 0.35
		host.DETAIL_GRASS: bloom = 0.12
	var snow_burial_strength = 0.55
	var snow_size_floor = 0.0
	if arch == host.DETAIL_TREE:
		snow_burial_strength = 0.0
		snow_size_floor = 1.0
	elif arch == host.DETAIL_CONIFER or arch == host.DETAIL_PALM:
		snow_burial_strength = 0.0
		snow_size_floor = 1.0
	return {
		"detail_form": detail_visual_form(host, ),
		"veg_response": 0.0 if is_deco else 1.0,
		"phenology_response": phenology_response,
		"phenology_color_dominance": phenology_color_dominance,
		"albedo_light_floor": albedo_light_floor,
		"aquatic_response": 1.0 if host._spawn_domain() == host.SPAWN_WATER else 0.0,
		"bloom_strength": bloom,
		"snow_burial": 0.0 if is_deco else snow_burial_strength,
		"snow_size_floor": snow_size_floor,
		"snow_body_color_retention": float(cfg.snow_body_color_retention),
		"color_saturation_gain": float(cfg.color_saturation_gain),
		"color_value_gain": float(cfg.color_value_gain),
		"shadow_foot_radius": host._profile_float(
			&"shadow_foot_radius", 0.55),
		"shadow_length_scale": host._profile_float(
			&"shadow_length_scale", 1.0),
		"shadow_strength": host._profile_float(
			&"shadow_strength", 0.32),
	}



static func detail_render_family_mask(host) -> int:

	var family = detail_render_family(host, )
	return 0 if family <= 0 else (1 << (family - 1))



static func set_family_style_id(host, value: int) -> void:

	host._family_style_id = clampi(value, 0, 31)



static func family_style_id(host) -> int:

	return host._family_style_id



static func set_family_batch_suppressed(host, suppressed: bool) -> void:

	if host._family_batch_suppressed == suppressed:
		return
	host._family_batch_suppressed = suppressed
	# 家族批次要真的上屏了：之前为了省一次近景编译而用远景档的家族材质，必须
	# 换回真实档位（VegetationFamilyLayer.configure() 会在这里之后才 rebuild_all，
	# 所以换档赶得上第一帧）。
	if suppressed:
		_restore_family_material_near_forms(host, )
	# 两条渲染路径使用不同的 LOD 曲线。切换路径时即使 zoom 没变，也必须
	# 重新计算实例比例；否则会把上一条路径的断崖式密度继续带到回退路径。
	host._camera_zoom_initialized = false
	host.set_camera_zoom(host._camera_zoom)
	for raw_node in host._chunk_nodes.values():
		_set_family_source_node_attached(host, raw_node as MultiMeshInstance2D, not suppressed)
	for raw_node in host._shadow_chunk_nodes.values():
		_set_family_source_node_attached(host, raw_node as MultiMeshInstance2D, not suppressed)
	_set_family_source_node_attached(host, host._mmi, not suppressed)
	_set_family_source_node_attached(host, host._shadow_mmi, not suppressed)
	host._refresh_chunk_visibility()
	if suppressed:
		if host._mmi != null:
			host._mmi.visible = false
		if host._shadow_mmi != null:
			host._shadow_mmi.visible = false
		for nodes in host._chunk_wrap_nodes.values():
			for raw_node in nodes:
				var node = raw_node as MultiMeshInstance2D
				if node != null and is_instance_valid(node):
					node.visible = false
		for nodes in host._shadow_chunk_wrap_nodes.values():
			for raw_node in nodes:
				var node = raw_node as MultiMeshInstance2D
				if node != null and is_instance_valid(node):
					node.visible = false
	else:
		host._refresh_chunk_visibility()



static func _set_family_source_node_attached(host, node: MultiMeshInstance2D, attached: bool) -> void:

	if node == null or not is_instance_valid(node):
		return
	if attached:
		if node.get_parent() == null:
			host.add_child(node)
	elif node.get_parent() == host:
		host.remove_child(node)



static func detail_family_chunk_payload(host, chunk_id: int) -> Dictionary:

	if host._chunk_cell_payloads.has(chunk_id):
		var assembled: Dictionary = host._chunk_assembled_payloads.get(chunk_id, {})
		if assembled.is_empty():
			assembled = host._assemble_chunk_cell_payloads(host._chunk_cell_payloads[chunk_id])
			host._chunk_assembled_payloads[chunk_id] = assembled
		return {
			"instance_count": int(assembled.get("instance_count", 0)),
			"buffer": assembled.get("buffer", PackedFloat32Array()),
			"style_id": host._family_style_id,
			"family": detail_render_family(host, ),
		}
	var node: MultiMeshInstance2D = host._chunk_nodes.get(chunk_id, null)
	if node == null or not is_instance_valid(node) or node.multimesh == null:
		return {"instance_count": 0, "buffer": PackedFloat32Array()}
	return {
		"instance_count": node.multimesh.instance_count,
		"buffer": node.multimesh.buffer,
		"style_id": host._family_style_id,
		"family": detail_render_family(host, ),
	}



static func detail_family_chunk_ids(host) -> Array:

	var ids = {}
	for raw_id in host._chunk_nodes.keys():
		ids[int(raw_id)] = true
	for raw_id in host._chunk_cell_payloads.keys():
		ids[int(raw_id)] = true
	return ids.keys()



static func detail_family_mesh(host) -> ArrayMesh:

	return host._cached_detail_mesh()



static func detail_family_quality(host) -> int:

	return host._active_quality_tier()



static func detail_family_mesh_for_quality(host, quality: int) -> ArrayMesh:

	var previous_quality = host._visual_quality
	host._visual_quality = clampi(quality, 0, 2)
	var mesh = host._build_shrub_mesh()
	host._visual_quality = previous_quality
	return mesh



static func detail_family_material(host, style_lut: Texture2D) -> ShaderMaterial:

	if host._material == null:
		host._ensure_resources()
	var out = host._material.duplicate(true) as ShaderMaterial
	out.shader = detail_family_shader(host, false)
	out.set_shader_parameter("detail_style_lut", style_lut)
	out.set_shader_parameter("detail_style_lut_size", Vector2(16.0, 32.0))
	_track_family_material(host, out)
	host._push_cloud_shadow_uniforms_to(out)
	return out



static func detail_family_shader(host, shadow_pass: bool) -> Shader:

	if shadow_pass:
		return host._compiled_shader(
			host._shader_quality_define_prefix() + "#define DETAIL_FAMILY_BATCH\n" + host._SHADOW_SHADER_CODE,
			"shadow")
	return host._compiled_shader(
		_family_batch_define_prefix(host, ) + "#define DETAIL_FAMILY_BATCH\n" + host._SHADER_CODE,
		"family")


# 家族批次材质的 define 前缀。家族批次没在画时（_family_batch_suppressed=false，
# 也就是 detail_scatter_family_renderer_enabled=false 的默认配置）这份材质永远
# 不上屏，web 上先用远景档 —— 否则 VegetationFamilyLayer.configure() 会白编一份
# 同样大小的近景 shader，把首次编译耗时翻倍。真要画家族批次时由
# set_family_batch_suppressed(true) 换回真实档位（见 _restore_family_material_near_forms）。

static func _family_batch_define_prefix(host) -> String:

	var force_far = OS.has_feature("web") and host.PK_WEB_ENABLE_VEG_NEAR_FORMS \
		and not host._family_batch_suppressed
	return host.VegetationShaderVariants.family_prefix(host._shader_quality_define_prefix(force_far))


# 家族批次材质引用（只记 web；上限 16 个，超了先丢掉旧的引用，避免多次 configure
# 累积）。这些对象归 VegetationFamilyLayer 缓存，这里只用于"换档时改 shader"。



static func _track_family_material(host, mat: ShaderMaterial) -> void:

	if not OS.has_feature("web"):
		return
	if host._family_materials.size() >= 16:
		host._family_materials.clear()
	host._family_materials.append(mat)



static func _restore_family_material_near_forms(host) -> void:

	if host._family_materials.is_empty():
		return
	var shader = host._compiled_shader(
		_family_batch_define_prefix(host, )
		+ "#define DETAIL_FAMILY_BATCH\n"
		+ host._SHADER_CODE,
		"family")
	for raw_mat in host._family_materials:
		var mat = raw_mat as ShaderMaterial
		if mat == null or mat.shader == shader:
			continue
		mat.shader = shader
	host._family_materials.clear()



static func detail_family_shadow_material(host, style_lut: Texture2D = null) -> ShaderMaterial:

	if host._shadow_material == null:
		host._ensure_resources()
	var out = host._shadow_material.duplicate(true) as ShaderMaterial
	if style_lut != null:
		out.shader = detail_family_shader(host, true)
		out.set_shader_parameter("detail_style_lut", style_lut)
		out.set_shader_parameter("detail_style_lut_size", Vector2(16.0, 32.0))
	host._push_cloud_shadow_uniforms_to(out)
	return out



static func detail_family_shadow_mesh(host) -> ArrayMesh:

	if host._shadow_blob_mesh == null:
		host._ensure_resources()
	return host._shadow_blob_mesh



static func detail_family_casts_shadow(host) -> bool:

	return host._shadow_resources_enabled()



static func detail_change_affects_profile(host, 
		axis_mask: int,
		old_veg: int, new_veg: int,
		old_lf: int, new_lf: int,
		old_cover: int, new_cover: int
) -> bool:

	if (axis_mask & 0x80) != 0:
		return true
	if (axis_mask & 0x01) != 0 \
			and (host._vegetation_weight(old_veg) > 0.0 or host._vegetation_weight(new_veg) > 0.0):
		return true
	if (axis_mask & 0x02) != 0 \
			and (host._landform_weight(old_lf) > 0.0 or host._landform_weight(new_lf) > 0.0):
		return true
	if (axis_mask & 0x04) != 0 \
			and (host._cover_weight(old_cover) > 0.0 or host._cover_weight(new_cover) > 0.0):
		return true
	return false



