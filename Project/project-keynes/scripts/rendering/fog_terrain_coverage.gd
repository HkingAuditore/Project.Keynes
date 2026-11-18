extends RefCounted

## Integral image of cells that can let the ground show through the fog.
## Built from the exact offset-ordered RGBA8 bytes uploaded to cell_table layer 2.
const AUX_CHANNELS := 4
# fog_of_war.gdshader reaches alpha 1 when fog_amount >= 0.95.
# 12/255 < 0.05 leaves room for rounding in the three-cell blend.
const MAX_OPAQUE_K := 12

var _dims: Vector2i
var _counts := PackedInt32Array()


func _init(aux_bytes: PackedByteArray, dims: Vector2i) -> void:
	_dims = dims
	if dims.x <= 0 or dims.y <= 0 or aux_bytes.size() != dims.x * dims.y * AUX_CHANNELS:
		return
	var stride := dims.x + 1
	_counts.resize(stride * (dims.y + 1))
	for row in range(dims.y):
		var row_count := 0
		var counts_row := row * stride + 1
		var aux_row := row * dims.x * AUX_CHANNELS
		for col in range(dims.x):
			row_count += int(aux_bytes[aux_row + col * AUX_CHANNELS] > MAX_OPAQUE_K)
			_counts[counts_row + col + stride] = _counts[counts_row + col] + row_count


func covers(world_samples: Rect2, hex_size: float) -> bool:
	if _counts.is_empty() or hex_size <= 0.0 or not is_finite(hex_size) \
			or not world_samples.is_finite() or not world_samples.has_area():
		return false
	# Fog shifts a point by at most sqrt(3)/2 radii, then uses the three
	# vertices of its triangle. Each vertex is within sqrt(3) more radii.
	var candidates := world_samples.grow(hex_size * 3.0)
	var row_step := 1.5 * hex_size
	var first_row := clampi(ceili(candidates.position.y / row_step), 0, _dims.y)
	var end_row := clampi(floori(candidates.end.y / row_step) + 1, 0, _dims.y)
	if first_row >= end_row:
		return true # North/south padding has k = 0 in the fog shader.

	var col_step := sqrt(3.0) * hex_size
	# Include both even rows and odd rows, which shift half a column east.
	var first_col := ceili(candidates.position.x / col_step - 0.5)
	var end_col := floori(candidates.end.x / col_step) + 1
	var width := mini(end_col - first_col, _dims.x)
	var start := posmod(first_col, _dims.x)
	var end := mini(start + width, _dims.x)
	return _count(first_row, end_row, start, end) == 0 \
		and _count(first_row, end_row, 0, start + width - end) == 0


func _count(first_row: int, end_row: int, first_col: int, end_col: int) -> int:
	var stride := _dims.x + 1
	var top := first_row * stride
	var bottom := end_row * stride
	return _counts[bottom + end_col] - _counts[bottom + first_col] \
		- _counts[top + end_col] + _counts[top + first_col]
