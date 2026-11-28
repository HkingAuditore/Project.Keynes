extends RefCounted

## Two weather endpoints in dense offset order. This publication owns no GPU resources.
var generation := 0
var previous_generation := 0
var terrain_generation := 0
var stamp := 0
var current := PackedFloat32Array()
var previous := PackedFloat32Array()
var has_density := false
var previous_has_density := false
var _map_id := 0
var _dimensions := Vector2i.ZERO


func publish(payload: Variant, map_id: int, dimensions: Vector2i, next_stamp: int,
		reset_previous: bool = false) -> bool:
	if not payload is Dictionary or map_id == 0 or dimensions.x <= 0 or dimensions.y <= 0 \
			or next_stamp <= 0 or next_stamp < stamp:
		return false
	var payload_map: Variant = payload.get("map_id")
	var payload_dimensions: Variant = payload.get("size")
	if (_map_id != 0 and (_map_id != map_id or _dimensions != dimensions)) \
			or not payload_map is int or payload_map != map_id \
			or not payload_dimensions is Vector2i or payload_dimensions != dimensions:
		return false
	var serial: Variant = payload.get("generation")
	var terrain: Variant = payload.get("terrain_generation")
	var values: Variant = payload.get("rg")
	var density_summary: Variant = payload.get("has_density")
	if not serial is int or serial <= 0 or serial < generation or not terrain is int or terrain <= 0 \
			or terrain < terrain_generation or not values is PackedFloat32Array \
			or values.size() != dimensions.x * dimensions.y * 2 or not density_summary is bool:
		return false
	if serial == generation:
		return stamp > 0 and terrain == terrain_generation and density_summary == has_density and values == current
	if next_stamp == stamp:
		return false
	var positive := false
	for index in range(0, values.size(), 2):
		var density: float = values[index]
		var top: float = values[index + 1]
		if not is_finite(density) or not is_finite(top) or density < 0.0 or density > 1.0 \
				or top < 0.0 or top > 1.0:
			return false
		positive = positive or density > 0.0
	if positive != density_summary:
		return false
	var continues: bool = not reset_previous and not current.is_empty() and serial == generation + 1 \
			and terrain == terrain_generation
	previous = current if continues else values
	previous_has_density = has_density if continues else positive
	previous_generation = generation if continues else serial
	current = values
	has_density = positive
	generation = serial
	terrain_generation = terrain
	stamp = next_stamp
	_map_id = map_id
	_dimensions = dimensions
	return true


func invalidate(next_stamp: int) -> void:
	# Retain the serial watermark across missing/invalid weather publications.
	if next_stamp < stamp:
		return
	stamp = next_stamp
	previous_generation = 0
	current = PackedFloat32Array()
	previous = PackedFloat32Array()
	has_density = false
	previous_has_density = false


func belongs_to(map: MapData) -> bool:
	return _map_id == map.get_instance_id() and _dimensions == Vector2i(map.width, map.height)
