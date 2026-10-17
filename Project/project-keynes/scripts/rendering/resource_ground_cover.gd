class_name ResourceGroundCover
extends Node2D

# Wild plant communities and grazing traces as a continuous ground cover.
#
# Plants are areas, not objects: one full-world quad (plus east/west wrap copies) samples
# map index -> cell -> cover_lut per pixel, exactly like FogOfWarLayer. No per-cell
# geometry, one draw call per copy, and a resource change only rewrites one texel.
# The LUT is written only from ResourceVisualObservations (fog memory), so unexplored
# cells stay empty and explored-but-hidden cells keep what was last seen.
#
# cover_lut texel (RGBA8):
#   R = primary layer * 16 + secondary layer
#   G = primary abundance (0 = no plant community), B = secondary abundance
#   A = trace kind * 64 + trace strength (kind 1..3, strength 0..63)

const SHADER = preload("res://shaders/resource_ground_cover.gdshader")
const TRACE_IDS := ["trace.pasture", "trace.mud", "trace.sand"]
const NO_LAYER := -1

var profile: Resource
var _material: ShaderMaterial
var _mesh_inst: MeshInstance2D
var _shader_key := ""
var _tiled := false
var _mobile_tier := -1
var _image: Image
var _texture: ImageTexture
var _dirty := false
var _last_upload_msec := -100000
var _cover_of_style := PackedInt32Array()  # style -> cover layer, -1 = not a plant community
var _trace_of_style := PackedInt32Array()  # style -> trace kind 1..3, 0 = none
var _style_priority := PackedFloat32Array()
var _art: ResourceArtLibrary
var _trace_base := 13
var _enabled := true
var _hex := 22.0
var _zoom := 1.0
var _stats := {"cells_written": 0, "uploads": 0}
## QA/debug: shade only from remembered climate (ignore live dyn_lut).
var memory_climate_only := false

func _ready() -> void:
	z_index = 0
	_ensure_nodes()

func _ensure_nodes() -> void:
	if _mesh_inst != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_mesh_inst = MeshInstance2D.new()
	_mesh_inst.name = "GroundCoverQuad"
	_mesh_inst.material = _material
	add_child(_mesh_inst)

func material() -> ShaderMaterial:
	_ensure_nodes()
	return _material

## styles: ResourceVisualCatalog entries (layer order). lut_dims must match dyn/enum LUTs.
func configure(styles: Array[Dictionary], hex_size: float, lut_dims: Vector2i,
		bounds: Rect2, wrap_period_x: float, map_index_atlas: Texture2D, visual_tiles) -> void:
	_ensure_nodes()
	_hex = hex_size
	_art = ResourceArtLibrary.shared()
	_cover_of_style.resize(styles.size())
	_trace_of_style.resize(styles.size())
	_style_priority.resize(styles.size())
	for i in styles.size():
		var e: Dictionary = styles[i]
		var plant := int(e.family) == 0 and int(e.form) != 26
		_cover_of_style[i] = _art.cover_layer(String(e.id)) if plant else NO_LAYER
		var trace := _art.trace_layer_for(String(e.id)) if int(e.family) == 1 else NO_LAYER
		_trace_base = _art.cover_layer(TRACE_IDS[0]) if _art.cover_layer(TRACE_IDS[0]) >= 0 else 13
		_trace_of_style[i] = trace - _trace_base + 1 if trace >= 0 else 0
		_style_priority[i] = float(e.get("priority", 1.0))
	var dims := Vector2i(maxi(1, lut_dims.x), maxi(1, lut_dims.y))
	_image = Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	_dirty = false
	var tiled := visual_tiles != null and bool(visual_tiles.ready) and String(visual_tiles.layout.mode) == "tiled"
	_tiled = tiled
	_select_shader()
	_material.set_shader_parameter("cover_lut", _texture)
	_material.set_shader_parameter("lut_dims", Vector2(dims))
	_material.set_shader_parameter("hex_size", _hex)
	_material.set_shader_parameter("world_origin", bounds.position)
	_material.set_shader_parameter("world_size", bounds.size)
	# Same wrap convention as the terrain quad and FogOfWarLayer.
	_material.set_shader_parameter("wrap_origin_x", 0.0)
	_material.set_shader_parameter("wrap_period_x", wrap_period_x)
	_material.set_shader_parameter("trace_layer_base", float(_trace_base))
	_material.set_shader_parameter("art_bound", _art.cover_albedo != null)
	if _art.cover_albedo != null:
		_material.set_shader_parameter("cover_albedo", _art.cover_albedo)
		_material.set_shader_parameter("cover_normal", _art.cover_normal)
	if tiled:
		_material.set_shader_parameter("visual_map_index_tiles", visual_tiles.map_index)
	elif map_index_atlas != null:
		_material.set_shader_parameter("map_index_atlas", map_index_atlas)
	_mesh_inst.mesh = build_quad_mesh(bounds, wrap_period_x) if bounds.size.x > 0.0 else null
	_update_visibility()

## Compile-time variants: tiled map addressing and the mobile quality tier.
func _select_shader() -> void:
	var key := "%s|%d" % [_tiled, _mobile_tier]
	if key == _shader_key:
		return
	_shader_key = key
	var prefix := "#define MAP_VISUAL_TILED\n" if _tiled else ""
	if _mobile_tier >= 0:
		prefix += ["#define MOBILE_QUALITY_LOW\n", "#define MOBILE_QUALITY_MID\n", "#define MOBILE_QUALITY_HIGH\n"][clampi(_mobile_tier, 0, 2)]
	if prefix.is_empty():
		_material.shader = SHADER
	else:
		var shader := Shader.new()
		shader.code = prefix + SHADER.code
		_material.shader = shader

func set_quality(quality: int, mobile_tier: int) -> void:
	_ensure_nodes()
	_mobile_tier = mobile_tier
	_select_shader()
	_material.set_shader_parameter("visual_quality", quality)
	if profile != null:
		var taps: PackedInt32Array = profile.ground_cover_taps
		_material.set_shader_parameter("cover_taps", taps[clampi(quality, 0, taps.size() - 1)] if not taps.is_empty() else 1)

func apply_profile(p: Resource) -> void:
	profile = p
	_ensure_nodes()
	for pair in [["cover_opacity", "ground_cover_opacity"], ["tile_hex", "ground_cover_tile_hex"],
			["edge_warp_hex", "ground_cover_edge_warp_hex"], ["clump_scale_hex", "ground_cover_clump_scale_hex"],
			["clump_strength", "ground_cover_clump_strength"], ["normal_strength", "ground_cover_normal_strength"],
			["shadow_strength", "ground_cover_shadow"], ["lens_dim", "ground_cover_lens_dim"],
			["far_opacity", "ground_cover_far_opacity"], ["trace_opacity", "animal_trace_opacity"],
			["climate_response", "climate_response"], ["snow_response", "snow_response"],
			["vitality_dead_threshold", "vitality_dead_threshold"], ["vitality_power", "vitality_power"],
			["wind_strength", "wind_strength"], ["river_clear_threshold", "river_clear_threshold"]]:
		_material.set_shader_parameter(pair[0], p.get(pair[1]))
	_enabled = bool(p.enabled) and bool(p.ground_cover_enabled)
	_update_visibility()

func set_zoom(zoom_value: float) -> void:
	_zoom = zoom_value
	if _material != null:
		_material.set_shader_parameter("camera_zoom", _zoom)

func set_lens_amount(amount: float) -> void:
	if _material != null:
		_material.set_shader_parameter("lens_amount", amount)

## Encodes one observed cell. presence(style, band) -> bool decides whether an animal is
## shown in the world (traces follow visible herds only). Returns the packed texel.
func encode_cell(bands: PackedByteArray, water: bool, core: int, presence: Callable) -> Color:
	if water or bands.is_empty():
		return Color(0, 0, 0, 0)
	var best := [-1, -1]
	var best_score := [-1.0, -1.0]
	var trace_kind := 0
	var trace_band := 0
	for i in mini(bands.size(), _cover_of_style.size()):
		var band := int(bands[i])
		if band <= 0:
			continue
		if _cover_of_style[i] >= 0:
			var score := float(band) + _style_priority[i] * 0.01 + float(i) * 0.0001
			if score > best_score[0]:
				best[1] = best[0]
				best_score[1] = best_score[0]
				best[0] = i
				best_score[0] = score
			elif score > best_score[1]:
				best[1] = i
				best_score[1] = score
		elif _trace_of_style[i] > 0 and band > trace_band and presence.call(i, band):
			trace_kind = _trace_of_style[i]
			trace_band = band
	# Settlement cores clear the wild cover around the town.
	var clearing := 1.0 - clampf(float(core) / 15.0, 0.0, 1.0) * float(profile.ground_cover_settlement_clear if profile != null else 0.7)
	var r := 0
	var g := 0
	var b := 0
	if best[0] >= 0:
		var secondary: int = best[1] if best[1] >= 0 else best[0]
		r = _cover_of_style[best[0]] * 16 + _cover_of_style[secondary]
		g = clampi(roundi(abundance(int(bands[best[0]])) * clearing * 255.0), 1, 255)
		b = clampi(roundi(abundance(int(bands[secondary])) * clearing * 255.0), 0, 255) if best[1] >= 0 else 0
	var a := 0
	if trace_kind > 0:
		a = trace_kind * 64 + clampi(roundi((0.55 + 0.15 * float(trace_band)) * clearing * 63.0), 1, 63)
	return Color8(r, g, b, a)

## Species occupancy reports band 2; reserves report 1..4.
static func abundance(band: int) -> float:
	return clampf(0.62 + 0.14 * float(band), 0.0, 1.0)

func write_cell(cell: int, value: Color) -> bool:
	if _image == null or cell < 0:
		return false
	var w := _image.get_width()
	if cell >= w * _image.get_height():
		return false
	var x := cell % w
	var y := cell / w
	if _image.get_pixel(x, y) == value:
		return false
	_image.set_pixel(x, y, value)
	_dirty = true
	_stats.cells_written = int(_stats.cells_written) + 1
	return true

func read_cell(cell: int) -> Color:
	var w := _image.get_width()
	return _image.get_pixel(cell % w, cell / w)

func clear_cells() -> void:
	if _image != null:
		_image.fill(Color(0, 0, 0, 0))
		_dirty = true

func dirty() -> bool:
	return _dirty

## Throttled GPU upload (ground_cover_upload_hz). Returns true when the texture changed.
func flush(force: bool = false) -> bool:
	if not _dirty or _texture == null:
		return false
	var hz := maxf(0.1, float(profile.ground_cover_upload_hz) if profile != null else 4.0)
	var now := Time.get_ticks_msec()
	if not force and now - _last_upload_msec < int(1000.0 / hz):
		return false
	_texture.update(_image)
	_dirty = false
	_last_upload_msec = now
	_stats.uploads = int(_stats.uploads) + 1
	return true

## Shared per-frame state (daylight, wind, LUTs) from the resource layer.
func set_frame_state(time: float, state: Dictionary, memory_lut: Texture2D) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("world_time", time)
	for name in state:
		_material.set_shader_parameter(name, state[name])
	if memory_climate_only:
		_material.set_shader_parameter("has_dynamic_lut", false)
	_material.set_shader_parameter("memory_lut", memory_lut)

func set_enabled(value: bool) -> void:
	_enabled = value
	_update_visibility()

func _update_visibility() -> void:
	visible = _enabled and _mesh_inst != null and _mesh_inst.mesh != null and _art != null and _art.cover_albedo != null

func diagnostics() -> Dictionary:
	var result := _stats.duplicate()
	result.merge({"visible": visible, "dirty": _dirty})
	return result

static func build_quad_mesh(bounds: Rect2, wrap_period_x: float) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	var offsets := [0.0]
	if wrap_period_x > 0.0001:
		p.x = 0.0
		s.x = wrap_period_x
		offsets = [-wrap_period_x, 0.0, wrap_period_x]
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for ox in offsets:
		var base := verts.size()
		var tp := p + Vector2(float(ox), 0.0)
		verts.append_array(PackedVector2Array([tp, tp + Vector2(s.x, 0.0), tp + s, tp + Vector2(0.0, s.y)]))
		uvs.append_array(PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
