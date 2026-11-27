extends RefCounted

## Creates military token batches and updates their lighting and formation shader inputs.

static func _ensure_nodes(layer: MilitaryArmyTokenLayer) -> void:
	if layer._batch != null and layer._selection != null:
		return
	if layer._batch == null:
		var shader := load(MilitaryArmyTokenLayer.SHADER_PATH) as Shader
		if shader == null:
			push_warning("MilitaryArmyTokenLayer: missing shader %s" % MilitaryArmyTokenLayer.SHADER_PATH)
			return
		layer._material = ShaderMaterial.new()
		layer._material.shader = shader
		var paper_decal := load(MilitaryArmyTokenLayer.PAPER_DECAL_PATH) as Texture2D
		if paper_decal != null:
			layer._material.set_shader_parameter("paper_decal", paper_decal)
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = MilitaryArmyTokenLayer.INSTANCE_CAP
		mm.visible_instance_count = 0
		layer._batch = MultiMeshInstance2D.new()
		layer._batch.name = "ArmyTokens"
		layer._batch.multimesh = mm
		# canvas_item 的 fragment 会乘 TEXTURE 采样：绑一张不透明白贴图，让
		# shader 输出原样到达屏幕（与 CountryBorderLayer 同一处理）。
		layer._batch.texture = CountryBorderLayer.get_white_texture()
		layer._batch.material = layer._material
		layer.add_child(layer._batch)
	if layer._formation_batch == null:
		layer._try_create_formation_batch()
	# 选中部队的朱红圈：一个 Line2D，不在 MultiMesh 里（透明填充会被叠加）。
	if layer._selection == null:
		layer._selection = Line2D.new()
		layer._selection.name = "SelectedArmyRing"
		layer._selection.width = 2.2
		layer._selection.default_color = Color(0.72, 0.19, 0.13, 0.95)
		layer._selection.antialiased = true
		layer._selection.closed = true
		layer._selection.z_index = 1
		layer._selection.points = PackedVector2Array()
		layer.add_child(layer._selection)
	layer._has_shader = true


static func _try_create_formation_batch(layer: MilitaryArmyTokenLayer) -> void:
	var shader := load(MilitaryArmyTokenLayer.FORMATION_SHADER_PATH) as Shader
	var atlas := load(MilitaryArmyTokenLayer.FORMATION_ATLAS_PATH) as Texture2D
	if shader == null or atlas == null:
		layer._has_formation_backend = false
		return
	layer._formation_material = ShaderMaterial.new()
	layer._formation_material.shader = shader
	layer._formation_shadow_material = ShaderMaterial.new()
	layer._formation_shadow_material.shader = shader
	layer._formation_shadow_material.set_shader_parameter("shadow_pass", true)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_custom_data = true
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = MilitaryArmyTokenLayer.INSTANCE_CAP
	mm.visible_instance_count = 0
	# Formation members are positioned in world space with per-member wrap
	# correction. Keep a world-sized culling box so camera panning never drops
	# the whole batch at map seams or viewport edges.
	mm.custom_aabb = AABB(
		Vector3(-1_000_000.0, -1_000_000.0, -1.0),
		Vector3(2_000_000.0, 2_000_000.0, 2.0)
	)
	layer._formation_shadow_batch = MultiMeshInstance2D.new()
	layer._formation_shadow_batch.name = "ArmyFormationShadows"
	layer._formation_shadow_batch.multimesh = mm
	layer._formation_shadow_batch.texture = atlas
	layer._formation_shadow_batch.material = layer._formation_shadow_material
	layer._formation_shadow_batch.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	layer._formation_batch = MultiMeshInstance2D.new()
	layer._formation_batch.name = "ArmyFormationMembers"
	layer._formation_batch.multimesh = mm
	layer._formation_batch.texture = atlas
	layer._formation_batch.material = layer._formation_material
	# A mip pyramid would blend adjacent atlas cells. The v3 atlas already has
	# transparent frame gutters; linear filtering preserves the cutout safely.
	layer._formation_batch.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	layer.add_child(layer._formation_shadow_batch)
	layer.add_child(layer._formation_batch)
	layer._set_formation_parameter("formation_atlas", atlas)
	layer._set_formation_parameter("visual_seconds", layer._wall_time)
	layer._set_formation_parameter("layer_alpha", 1.0)
	layer._set_formation_parameter("visual_quality", layer._visual_quality)
	layer._set_formation_parameter("terrain_instance_lighting_enabled", false)
	layer._set_formation_parameter("shadow_strength", MilitaryArmyTokenLayer.FORMATION_SHADOW_STRENGTH)
	layer._set_formation_parameter("shadow_height_ratio", MilitaryArmyTokenLayer.FORMATION_SHADOW_HEIGHT_RATIO)
	layer._set_formation_parameter(
		"shadow_max_length_ratio", MilitaryArmyTokenLayer.FORMATION_SHADOW_MAX_LENGTH_RATIO)
	layer._set_formation_parameter(
		"shadow_footprints", PackedVector2Array(MilitaryArmyTokenLayer.FORMATION_SHADOW_FOOTPRINTS))
	layer._set_formation_parameter(
		"shadow_heights", PackedFloat32Array(MilitaryArmyTokenLayer.FORMATION_SHADOW_HEIGHTS))
	layer._set_formation_parameter(
		"shadow_edge_softness", MilitaryArmyTokenLayer.FORMATION_SHADOW_EDGE_SOFTNESS)
	layer._set_formation_parameter("shadow_color", MilitaryArmyTokenLayer.FORMATION_SHADOW_COLOR)
	layer._has_formation_backend = true


static func _set_formation_parameter(layer: MilitaryArmyTokenLayer, name: String, value: Variant) -> void:
	layer._formation_parameters[name] = value
	if layer._formation_material != null:
		layer._formation_material.set_shader_parameter(name, value)
	if layer._formation_shadow_material != null:
		layer._formation_shadow_material.set_shader_parameter(name, value)


static func _apply_formation_shader_variant(layer: MilitaryArmyTokenLayer, tiled: bool) -> void:
	if tiled == layer._formation_shader_tiled or layer._formation_material == null:
		return
	var base := load(MilitaryArmyTokenLayer.FORMATION_SHADER_PATH) as Shader
	if base == null:
		return
	layer._formation_shader_tiled = tiled
	var variant := Shader.new()
	variant.code = ("#define MAP_VISUAL_TILED\n" if tiled else "") + base.code
	layer._formation_material.shader = variant
	layer._formation_shadow_material.shader = variant
	for name in layer._formation_parameters:
		layer._formation_material.set_shader_parameter(name, layer._formation_parameters[name])
		layer._formation_shadow_material.set_shader_parameter(
			name, layer._formation_parameters[name])
	layer._formation_material.set_shader_parameter("shadow_pass", false)
	layer._formation_shadow_material.set_shader_parameter("shadow_pass", true)


static func configure_formation_catalog(layer: MilitaryArmyTokenLayer, units: Array) -> Dictionary:
	layer._ensure_nodes()
	var loaded: bool = layer._formation_catalog.load_catalog()
	if not loaded:
		layer._has_formation_backend = false
		layer._dirty = true
		return {"ok": false, "reason": "formation_visual_catalog_invalid",
			"mapped": 0, "dense_unit_count": 0}
	layer._has_formation_backend = layer._formation_batch != null
	var report: Dictionary = layer._formation_catalog.bind_dense_units(units)
	if not bool(report.get("ok", false)) or not layer._has_formation_backend:
		layer._has_formation_backend = false
		layer._dirty = true
		return report
	layer._last_signature = -1
	layer._last_formation_signature = -1
	layer._dirty = true
	return report


static func configure(layer: MilitaryArmyTokenLayer, map, camera: Camera2D, hex_size: float, wrap_period_x: float) -> void:
	layer._ensure_nodes()
	layer._map = map
	layer._camera = camera
	layer._hex_size = maxf(4.0, hex_size)
	layer._wrap = maxf(0.0, wrap_period_x)
	layer._dirty = true


## HexRenderer owns this state so formations and trade convoys share the exact
## same astronomical phase. Per-vertex work remains on the GPU.


static func set_daylight_parameters(layer: MilitaryArmyTokenLayer, values: Dictionary) -> void:
	layer._ensure_nodes()
	for name in values:
		if layer._lighting_values.has(name) and layer._lighting_values[name] == values[name]:
			continue
		layer._lighting_values[name] = values[name]
		layer._set_formation_parameter(name, values[name])


## Static map fields and the terrain-derived light parameters. Called on initial
## registration and whenever the tiled horizon bake finishes.


static func set_terrain_lighting(layer: MilitaryArmyTokenLayer, world: WorldData, source: ShaderMaterial) -> void:
	layer._ensure_nodes()
	if world == null:
		layer._set_formation_parameter("terrain_instance_lighting_enabled", false)
		for name in [
			"terrain_normal_tex_bound",
			"terrain_horizon_tex_bound",
			"gi_lut_bound",
		]:
			layer._set_formation_parameter(name, false)
		return
	layer._set_formation_parameter("world_origin", world.world_bounds.position)
	layer._set_formation_parameter(
		"world_size", world.world_bounds.size.max(Vector2(0.0001, 0.0001)))
	layer._set_formation_parameter("wrap_origin_x", 0.0)
	layer._set_formation_parameter("wrap_period_x", world.wrap_period_x)
	var tiles: Variant = world.visual_tiles
	var tiled := tiles != null and bool(tiles.ready) \
		and String(tiles.layout.mode) == "tiled"
	layer._apply_formation_shader_variant(tiled)
	if tiled:
		layer._set_formation_parameter("visual_horizon_tiles", tiles.horizon)
		layer._set_formation_parameter(
			"visual_terrain_normal_tiles", tiles.terrain_normal)
		var layout: Variant = tiles.layout
		layer._set_formation_parameter(
			"visual_domain_origin", layout.visual_domain.position)
		layer._set_formation_parameter(
			"visual_domain_size", layout.visual_domain.size)
		for pair in [
			["visual_grid_size", layout.grid_size],
			["visual_interior_size", layout.interior_size],
			["visual_layer_size", layout.layer_size],
			["visual_logical_resolution", layout.logical_size],
		]:
			layer._set_formation_parameter(pair[0], Vector2(pair[1]))
		layer._set_formation_parameter("visual_gutter_px", float(layout.gutter_px))
	else:
		layer._set_formation_parameter(
			"terrain_horizon_tex", world.terrain_horizon_tex)
		layer._set_formation_parameter(
			"terrain_normal_tex", world.terrain_normal_tex)
	layer._set_formation_parameter(
		"terrain_horizon_tex_bound",
		bool(tiles.horizon_ready) if tiled else world.terrain_horizon_tex != null)
	layer._set_formation_parameter(
		"terrain_normal_tex_bound",
		tiles.terrain_normal != null if tiled else world.terrain_normal_tex != null)
	if source != null:
		for name in [
			"terrain_horizon_strength",
			"terrain_horizon_softness",
			"terrain_horizon_max_angle",
			"terrain_normal_influence",
			"gi_horizon_lut",
			"gi_lut_bound",
			"gi_ao_strength",
			"gi_ao_floor",
			"gi_ao_smoothing",
			"gi_bent_strength",
			"gi_normal_floor",
			"sky_ibl_bound",
			"sky_ambient_strength",
			"sky_day_sh_l1",
			"sky_night_sh_l1",
		]:
			var value: Variant = source.get_shader_parameter(name)
			if value != null:
				layer._set_formation_parameter(name, value)
	layer._set_formation_parameter("terrain_instance_lighting_enabled", true)
