extends Node

## Screen-space numeric textures for the land material before rivers, climate and light.
## The original land mesh still handles fog coverage and drawing order in both paths.
var enabled := true
var builds := 0
var _source: Shader
var _reader: Shader
var _owner_material: ShaderMaterial
var _writers: Array[ShaderMaterial] = []
var _views: Array[SubViewport] = []
var _meshes: Array[MeshInstance2D] = []
var _key: Array = []
var _dirty := true
var _copy_inputs := true
var _eligible := false
var _cell_table: Texture2DArray

# Static parameters which can change independently of a full map/material publication.
const STATIC_PARAMETERS := {
	&"visual_quality": true, &"biome_tint_strength": true, &"pixel_world_size": true,
	&"terrain_ecotone_width": true, &"terrain_ecotone_noise": true, &"terrain_warp_range": true,
	&"terrain_warp_amp": true, &"terrain_materials_enabled": true, &"terrain_material_world_size": true,
	&"terrain_material_albedo_strength": true, &"terrain_material_normal_strength": true,
	&"terrain_material_roughness_strength": true, &"cell_table": true, &"cell_table_bound": true,
	&"sea_level": true, &"color_beach": true, &"color_lowland": true, &"color_hill": true,
	&"color_mountain": true, &"color_peak": true,
}
var _pushed: Dictionary = {}


func invalidate() -> void:
	_dirty = true
	_copy_inputs = true


func parameter_changed(key: StringName, value: Variant) -> void:
	if STATIC_PARAMETERS.has(key) and _pushed.get(key) != value:
		_pushed[key] = value
		invalidate()


func _enter_tree() -> void:
	if not OS.has_feature("web") and not OS.has_feature("mobile") and RenderingServer.get_rendering_device() != null:
		RenderingServer.frame_pre_draw.connect(_prepare)


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_prepare):
		RenderingServer.frame_pre_draw.disconnect(_prepare)
	_direct()
	_key.clear()


func _direct() -> void:
	if _reader != null and _owner_material != null and _owner_material.shader == _reader:
		_owner_material.shader = _source


func _configure(mat: ShaderMaterial) -> void:
	_direct()
	_owner_material = mat
	_source = mat.shader
	_reader = null
	_writers.clear()
	_key.clear()
	invalidate()
	var src := _source.code
	var prefix := src.get_slice("shader_type canvas_item;", 0)
	_eligible = prefix.contains("#define PK_CELL_FIELD\n") and prefix.contains("#define PK_LAND_ONLY\n") \
		and src.contains("#ifdef PK_READ_LAND_BASE")
	if not _eligible:
		return
	for mode in ["PK_READ_LAND_BASE", "PK_BAKE_LAND_COLOR", "PK_BAKE_LAND_NORMAL"]:
		var shader := Shader.new()
		shader.code = "#define " + mode + "\n" + src
		var failure := _variant_failure_message(mode, shader.get_shader_uniform_list())
		if not failure.is_empty():
			push_error("[land-base-cache] %s" % failure)
			_reader = null
			_writers.clear()
			_eligible = false
			return
		if mode == "PK_READ_LAND_BASE":
			_reader = shader
		else:
			var writer := ShaderMaterial.new()
			writer.shader = shader
			_writers.append(writer)


static func _variant_failure_message(mode: String, uniforms: Array) -> String:
	return "generated shader variant has no uniforms: %s" % mode if uniforms.is_empty() else ""


func _prepare() -> void:
	var host: Variant = get_parent()
	var land: MeshInstance2D = host._world_quad
	var mat: ShaderMaterial = host._shader_mat
	if not enabled or not is_instance_valid(land) or not land.is_visible_in_tree() or land.mesh == null \
			or host._world == null or not host._world.cell_table_bound or host._water_quad == null \
			or mat == null or mat.shader == null or land.material != mat or host.terrain_surface_debug_view != 0:
		_direct()
		_key.clear()
		return
	if mat != _owner_material or (mat.shader != _source and mat.shader != _reader):
		_configure(mat)
	if not _eligible:
		return
	if _cell_table != host._world.cell_table_tex:
		_cell_table = host._world.cell_table_tex
		invalidate()
	var viewport := land.get_viewport()
	host._graphics_details.scaled_surface_parent(land)
	# Window ViewportTexture sizes include the content stretch again in Godot 4.6.
	# Match the physical pixel grid read by SCREEN_UV.
	var physical_size := viewport.get_visible_rect().size * viewport.get_stretch_transform().get_scale().abs()
	var size := Vector2i(physical_size.round())
	var canvas := viewport.get_final_transform() * land.get_global_transform_with_canvas()
	var key := [viewport, size, viewport.use_hdr_2d, canvas, land.global_transform, land.mesh, host._world,
		host._world.land_base_revision]
	if key != _key:
		_direct()
		_key = key
		_dirty = true
		return
	if not _dirty:
		return
	if _copy_inputs:
		for entry in _source.get_shader_uniform_list():
			var value: Variant = mat.get_shader_parameter(entry.name)
			for writer in _writers:
				writer.set_shader_parameter(entry.name, value)
		_copy_inputs = false
	# Render before the viewport that samples the textures, even when land is downscaled.
	for i in 2:
		if _views.size() <= i:
			var view := SubViewport.new()
			view.disable_3d = true
			view.gui_disable_input = true
			view.transparent_bg = true
			view.world_2d = World2D.new()
			var mesh := MeshInstance2D.new()
			view.add_child(mesh)
			land.add_child(view)
			_views.append(view)
			_meshes.append(mesh)
		# Match the consumer so colour uniforms and textures use the same colour space.
		_views[i].use_hdr_2d = viewport.use_hdr_2d
		_views[i].size = size
		_views[i].canvas_transform = canvas * land.global_transform.affine_inverse()
		_meshes[i].transform = land.global_transform
		_meshes[i].mesh = land.mesh
		_meshes[i].material = _writers[i]
		_views[i].render_target_update_mode = SubViewport.UPDATE_ONCE
	mat.shader = _reader
	mat.set_shader_parameter("land_base_color", _views[0].get_texture())
	mat.set_shader_parameter("land_base_normal", _views[1].get_texture())
	_dirty = false
	builds += 1
