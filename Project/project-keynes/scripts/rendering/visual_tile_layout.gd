class_name VisualTileLayout
extends RefCounted

const MODE_LEGACY := "legacy"
const MODE_PROBE := "probe"
const MODE_TILED := "tiled"

const DEFAULT_TILE_EDGE := 512
const DEFAULT_GUTTER_PX := 2
const DEFAULT_LAYER_CAP := 64
const BYTES_PER_PHYSICAL_TEXEL := 18
# Local RenderingDevice keeps a duplicate RG8 input, a float max pyramid and
# the packed output until readback. Round up so the resolver enforces peak RAM.
const COMPUTE_TEMP_BYTES_PER_TEXEL := 12

var mode: String = MODE_LEGACY
var fallback_reason: String = ""
var visual_domain: Rect2 = Rect2()
var wrap_x: bool = false
var wrap_period_x: float = 0.0
var grid_size: Vector2i = Vector2i.ONE
var layer_count: int = 1
var interior_size: Vector2i = Vector2i.ZERO
var gutter_px: int = DEFAULT_GUTTER_PX
var layer_size: Vector2i = Vector2i.ZERO
var logical_size: Vector2i = Vector2i.ZERO
var requested_budget_px: int = 0
var effective_budget_px: int = 0
var estimated_resident_bytes: int = 0
var estimated_peak_bytes: int = 0
var generation_id: int = 0


static func resolve(
		world_bounds: Rect2,
		wrap_period_x: float,
		quality: String,
		mobile: bool,
		options: Dictionary = {}
):
	var layout = load("res://scripts/rendering/visual_tile_layout.gd").new()
	layout.generation_id = int(options.get("generation_id", 0))
	layout.mode = String(options.get("mode", _configured_mode()))
	if layout.mode not in [MODE_LEGACY, MODE_PROBE, MODE_TILED]:
		layout.mode = MODE_TILED
	if String(options.get("rendering_method", _rendering_method())) == "gl_compatibility":
		layout.mode = MODE_LEGACY
		layout.fallback_reason = "compatibility_renderer"

	layout.wrap_x = wrap_period_x > 0.0001
	layout.wrap_period_x = wrap_period_x if layout.wrap_x else 0.0
	if layout.wrap_x:
		layout.visual_domain = Rect2(0.0, world_bounds.position.y,
			wrap_period_x, world_bounds.size.y)
	else:
		layout.visual_domain = world_bounds

	layout.requested_budget_px = maxi(1, int(round(
		float(options.get("budget_mp", _configured_budget_mp(quality, mobile))) * 1_000_000.0
	)))
	layout.gutter_px = maxi(1, int(options.get("gutter_px", DEFAULT_GUTTER_PX)))
	var tile_edge := clampi(int(options.get("tile_edge", DEFAULT_TILE_EDGE)), 64, 2048)
	var max_layers := mini(DEFAULT_LAYER_CAP, maxi(1, int(options.get(
		"max_array_layers", _device_limit(RenderingDevice.LIMIT_MAX_TEXTURE_ARRAY_LAYERS, DEFAULT_LAYER_CAP)
	))))
	var max_texture_size := maxi(64, int(options.get(
		"max_texture_size", _device_limit(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D, 4096)
	)))
	tile_edge = mini(tile_edge, max_texture_size - layout.gutter_px * 2)

	var resident_cap_mb := float(options.get("resident_cap_mb",
		_configured_cap_mb("resident_cap_mb", 64.0 if mobile else 192.0)))
	var peak_cap_mb := float(options.get("peak_cap_mb",
		_configured_cap_mb("peak_cap_mb", 96.0 if mobile else 256.0)))
	var resident_cap := maxi(1, int(round(resident_cap_mb * 1024.0 * 1024.0)))
	var peak_cap := maxi(1, int(round(peak_cap_mb * 1024.0 * 1024.0)))

	var budget: int = int(layout.requested_budget_px)
	var solved: bool = false
	for _attempt in range(48):
		layout._derive_grid(budget, tile_edge)
		layout._estimate_memory()
		if layout.layer_count <= max_layers \
				and layout.layer_size.x <= max_texture_size \
				and layout.layer_size.y <= max_texture_size \
				and layout.estimated_resident_bytes <= resident_cap \
				and layout.estimated_peak_bytes <= peak_cap:
			solved = true
			break
		budget = maxi(64 * 64, int(floor(float(budget) * 0.85)))

	if not solved or tile_edge < 64 or layout.visual_domain.size.x <= 0.0 \
			or layout.visual_domain.size.y <= 0.0:
		layout.mode = MODE_LEGACY
		if layout.fallback_reason.is_empty():
			layout.fallback_reason = "tile_budget_or_device_limit"
	return layout


func _derive_grid(budget_px: int, tile_edge: int) -> void:
	var aspect := maxf(visual_domain.size.x / maxf(visual_domain.size.y, 0.0001), 0.0001)
	var target_w := maxi(8, int(ceil(sqrt(float(budget_px) * aspect))))
	var target_h := maxi(8, int(ceil(float(budget_px) / float(target_w))))
	grid_size = Vector2i(
		maxi(1, int(ceil(float(target_w) / float(tile_edge)))),
		maxi(1, int(ceil(float(target_h) / float(tile_edge))))
	)
	interior_size = Vector2i(
		_align_up(maxi(8, int(ceil(float(target_w) / float(grid_size.x)))), 8),
		_align_up(maxi(8, int(ceil(float(target_h) / float(grid_size.y)))), 8)
	)
	layer_count = grid_size.x * grid_size.y
	layer_size = interior_size + Vector2i.ONE * gutter_px * 2
	logical_size = Vector2i(interior_size.x * grid_size.x, interior_size.y * grid_size.y)
	effective_budget_px = logical_size.x * logical_size.y


func _estimate_memory() -> void:
	var physical_px := int(layer_size.x) * int(layer_size.y) * layer_count
	estimated_resident_bytes = physical_px * BYTES_PER_PHYSICAL_TEXEL
	estimated_peak_bytes = estimated_resident_bytes + physical_px * COMPUTE_TEMP_BYTES_PER_TEXEL


func world_to_tile_address(world_pos: Vector2) -> Dictionary:
	if layer_count <= 0 or visual_domain.size.x <= 0.0 or visual_domain.size.y <= 0.0:
		return {"valid": false}
	var x := world_pos.x
	if wrap_x and wrap_period_x > 0.0001:
		x = visual_domain.position.x + fposmod(x - visual_domain.position.x, wrap_period_x)
	var u := clampf((x - visual_domain.position.x) / visual_domain.size.x, 0.0, 1.0)
	var v := clampf((world_pos.y - visual_domain.position.y) / visual_domain.size.y, 0.0, 1.0)
	u = minf(u, 1.0 - 1e-7)
	v = minf(v, 1.0 - 1e-7)
	var scaled := Vector2(u * float(grid_size.x), v * float(grid_size.y))
	var tile := Vector2i(
		clampi(int(floor(scaled.x)), 0, grid_size.x - 1),
		clampi(int(floor(scaled.y)), 0, grid_size.y - 1)
	)
	var local01 := Vector2(scaled.x - float(tile.x), scaled.y - float(tile.y))
	var local_px := Vector2(gutter_px, gutter_px) + local01 * Vector2(interior_size)
	return {
		"valid": true,
		"tile": tile,
		"layer": tile.y * grid_size.x + tile.x,
		"local_uv": (local_px + Vector2(0.5, 0.5)) / Vector2(layer_size),
		"global_uv": Vector2(u, v),
	}


func diagnostic_report() -> Dictionary:
	return {
		"mode": mode,
		"fallback_reason": fallback_reason,
		"visual_domain": visual_domain,
		"wrap_x": wrap_x,
		"wrap_period_x": wrap_period_x,
		"grid_size": grid_size,
		"layers": layer_count,
		"interior_size": interior_size,
		"gutter_px": gutter_px,
		"layer_size": layer_size,
		"logical_size": logical_size,
		"requested_budget_px": requested_budget_px,
		"effective_budget_px": effective_budget_px,
		"estimated_resident_bytes": estimated_resident_bytes,
		"estimated_peak_bytes": estimated_peak_bytes,
		"generation_id": generation_id,
	}


static func _configured_mode() -> String:
	var value := String(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/mode", MODE_TILED))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map-visual-mode="):
			value = arg.trim_prefix("--map-visual-mode=")
		elif arg.begins_with("--map-tile-mode="):
			value = arg.trim_prefix("--map-tile-mode=")
	return value


static func _configured_budget_mp(quality: String, mobile: bool) -> float:
	var override := float(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/budget_mp", -1.0
	))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map-tile-budget-mp="):
			override = float(arg.trim_prefix("--map-tile-budget-mp="))
	if override > 0.0:
		return override
	match quality:
		"low":
			return 0.25 if mobile else 1.0
		"medium":
			return 1.0 if mobile else 4.0
		"high":
			return 2.0 if mobile else 8.0
		_:
			return 0.25 if mobile else 8.0


static func _configured_cap_mb(setting_name: String, fallback: float) -> float:
	var value := float(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/%s" % setting_name, fallback
	))
	var arg_prefix := "--map-tile-%s=" % setting_name.replace("_", "-")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(arg_prefix):
			value = float(arg.trim_prefix(arg_prefix))
	return maxf(value, 1.0)


static func _rendering_method() -> String:
	if RenderingServer.has_method("get_current_rendering_method"):
		return String(RenderingServer.get_current_rendering_method())
	return String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "mobile"))


static func _device_limit(limit: RenderingDevice.Limit, fallback: int) -> int:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return fallback
	var value := int(rd.limit_get(limit))
	return value if value > 0 else fallback


static func _align_up(value: int, alignment: int) -> int:
	return ((value + alignment - 1) / alignment) * alignment
