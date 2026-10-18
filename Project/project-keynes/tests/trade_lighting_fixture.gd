extends RefCounted

## Small real GPU textures, including the production Vulkan RG16 horizon ABI.
static func bind(layer: TradeActivityLayer, width: int, height: int,
		tiled: bool = false, slope: Color = Color(0.5, 0.5, 0.0, 1.0),
		horizon_byte: int = 0x44) -> Dictionary:
	var world := WorldData.new()
	world.wrap_period_x = width * sqrt(3.0) * 22.0
	world.world_bounds = Rect2(0, 0, world.wrap_period_x, height * 33.0)
	var normal := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	normal.fill(slope)
	var horizon := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	horizon.fill(Color8(horizon_byte, horizon_byte, horizon_byte, horizon_byte))
	world.terrain_normal_tex = ImageTexture.create_from_image(normal)
	world.terrain_horizon_tex = ImageTexture.create_from_image(horizon)
	if tiled:
		var tiles := VisualTileSet.new()
		var layout := VisualTileLayout.new()
		layout.mode = "tiled"
		layout.visual_domain = world.world_bounds
		layout.grid_size = Vector2i.ONE
		layout.layer_count = 1
		layout.interior_size = Vector2i(8, 8)
		layout.layer_size = Vector2i(12, 12)
		layout.logical_size = Vector2i(8, 8)
		layout.gutter_px = 2
		tiles.layout = layout
		tiles.terrain_normal = Texture2DArray.new()
		tiles.terrain_normal.create_from_images([normal])
		tiles.horizon = Texture2DArray.new()
		if not DCFeatureFlags.is_compatibility_renderer():
			horizon = Image.create_from_data(12, 12, false, Image.FORMAT_RG16, horizon.get_data())
		tiles.horizon.create_from_images([horizon])
		tiles.ready = true
		tiles.horizon_ready = true
		world.visual_tiles = tiles
	var source := ShaderMaterial.new()
	source.shader = TradeActivityLayer.VEHICLE_SHADER
	source.set_shader_parameter("gi_horizon_lut", HexRenderer.build_gi_horizon_lut(1.309))
	source.set_shader_parameter("gi_lut_bound", true)
	source.set_shader_parameter("terrain_horizon_strength", 0.9)
	layer.set_terrain_lighting(world, source)
	return {"world": world, "source": source}
