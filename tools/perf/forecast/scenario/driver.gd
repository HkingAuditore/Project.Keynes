extends SceneTree

const Cache = preload("res://cache.gd")

class World:
	extends RefCounted
	var cell_table_bound := true
	var cell_table_tex: Texture2DArray
	var land_base_revision := 0

class Details:
	extends RefCounted
	func scaled_surface_parent(land):
		return land.get_parent()

class Host:
	extends Node2D
	var _world_quad := MeshInstance2D.new()
	var _water_quad := MeshInstance2D.new()
	var _world := World.new()
	var _graphics_details := Details.new()
	var _shader_mat := ShaderMaterial.new()
	var terrain_surface_debug_view := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var request = JSON.parse_string(FileAccess.get_file_as_string("res://input.json"))
	var host := Host.new()
	root.add_child(host)
	host.add_child(host._world_quad)
	host.add_child(host._water_quad)
	host._world_quad.mesh = QuadMesh.new()
	var cache = Cache.new()
	host.add_child(cache)
	if RenderingServer.frame_pre_draw.is_connected(cache._prepare):
		RenderingServer.frame_pre_draw.disconnect(cache._prepare)
	# Start after a successful shader configuration. Rendering eligibility and
	# material compilation are outside this scenario. Use the real state machine.
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; uniform float biome_tint_strength;"
	host._shader_mat.shader = shader
	host._world_quad.material = host._shader_mat
	cache._owner_material = host._shader_mat
	cache._source = shader
	cache._reader = Shader.new()
	cache._reader.code = "shader_type canvas_item; uniform sampler2D land_base_color; uniform sampler2D land_base_normal;"
	cache._eligible = true
	for i in 2:
		var writer := ShaderMaterial.new()
		writer.shader = shader
		cache._writers.append(writer)
	var frames := []
	for frame in request.frames:
		cache.trace_events.clear()
		host._world.land_base_revision = int(frame.revision)
		if frame.has("tint"):
			host._shader_mat.set_shader_parameter("biome_tint_strength", frame.tint)
			cache.parameter_changed(&"biome_tint_strength", frame.tint)
		var before: int = cache.builds
		cache._prepare()
		frames.append({"events": cache.trace_events.duplicate(), "builds": cache.builds - before})
	print("SCENARIO_RESULT ", JSON.stringify(frames))
	root.remove_child(host)
	host.free()
	quit()
