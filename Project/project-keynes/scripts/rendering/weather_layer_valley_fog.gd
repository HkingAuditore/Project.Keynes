extends RefCounted

const NOISE_PATH := "res://assets/textures/weather/valley_fog_noise.png"

var compiled := false
var _texture: Texture2DArray
var _noise: Texture2D
var _height: TextureLayered
var _height_legacy: Texture2D
var _world_id := 0
var _stamp := -1
var _current_layer := 0
var _previous_layer := 0
var _generation := 0
var _active := false
var upload_usec := 0


func release(material: ShaderMaterial) -> void:
	if compiled and material != null:
		material.set_shader_parameter("valley_fog_active", false)
		material.set_shader_parameter("valley_fog_table", null)
		material.set_shader_parameter("valley_fog_noise", null)
		material.set_shader_parameter("visual_height_tiles", null)
		material.set_shader_parameter("height_tex", null)
	_texture = null
	_noise = null
	_height = null
	_height_legacy = null
	_world_id = 0
	_stamp = -1
	_generation = 0
	_active = false
	upload_usec = 0


func push(layer: WeatherLayer) -> void:
	if not compiled or not layer._render_gate_open or layer._overlay_mat == null:
		return
	var world: WorldData = layer._world_ref
	var material := layer._overlay_mat
	if world == null:
		if _world_id != 0:
			release(material)
		return
	if _world_id != world.get_instance_id():
		release(material)
		_world_id = world.get_instance_id()
	var tiled := layer._visual_tiles_active()
	var tiled_height: TextureLayered = layer._visual_tiles.height if tiled else null
	var legacy_height: Texture2D = world.height_tex if not tiled else null
	if _height != tiled_height or _height_legacy != legacy_height:
		_height = tiled_height
		_height_legacy = legacy_height
		if tiled:
			material.set_shader_parameter("visual_height_tiles", _height)
		else:
			material.set_shader_parameter("height_tex", _height_legacy)
		material.set_shader_parameter("valley_fog_sea_level", world.sea_level)
	var frame := world.valley_fog
	var height_ready := (_height != null or _height_legacy != null) \
		and (layer._weather_map == null or frame.belongs_to(layer._weather_map))
	var stamp := world.weather_lut_update_usec
	if height_ready and stamp == frame.stamp and stamp != _stamp and not frame.current.is_empty():
		if frame.has_density or frame.previous_has_density:
			if _noise == null:
				_noise = ResourceLoader.load(NOISE_PATH, "Texture2D") as Texture2D
				material.set_shader_parameter("valley_fog_noise", _noise)
			if _noise != null:
				var started := Time.get_ticks_usec()
				_upload(layer, frame)
				upload_usec = Time.get_ticks_usec() - started
		_stamp = stamp
	var active := height_ready and _texture != null and stamp == frame.stamp and stamp == _stamp \
			and _generation == frame.generation and (frame.has_density \
			or (frame.previous_has_density and layer._wx_pushed_lerp < 1.0))
	if active != _active:
		_active = active
		material.set_shader_parameter("valley_fog_active", active)


func _upload(layer: WeatherLayer, frame) -> void:
	var map_dims := Vector2i(layer._resolve_map_dims())
	if map_dims.x <= 0 or map_dims.y <= 0 or frame.current.size() != map_dims.x * map_dims.y * 2:
		return
	var image := _image(map_dims, frame.current)
	if _texture != null and frame.previous_generation == _generation and frame.generation != _generation:
		_previous_layer = _current_layer
		_current_layer = 1 - _current_layer
		_texture.update_layer(image, _current_layer)
	elif _texture != null and frame.previous_generation == frame.generation:
		_current_layer = 1 - _current_layer
		_previous_layer = _current_layer
		_texture.update_layer(image, _current_layer)
	else:
		var previous := image if frame.previous_generation == frame.generation else _image(map_dims, frame.previous)
		var images: Array[Image] = [image, previous]
		var texture := Texture2DArray.new()
		if texture.create_from_images(images) != OK:
			return
		_texture = texture
		_current_layer = 0
		_previous_layer = 0 if frame.previous_generation == frame.generation else 1
		layer._overlay_mat.set_shader_parameter("valley_fog_table", _texture)
	_generation = frame.generation
	layer._overlay_mat.set_shader_parameter("valley_fog_cur_layer", _current_layer)
	layer._overlay_mat.set_shader_parameter("valley_fog_prev_layer", _previous_layer)


func _image(dims: Vector2i, values: PackedFloat32Array) -> Image:
	var image := Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RGF, values.to_byte_array())
	image.convert(Image.FORMAT_RGH)
	return image
