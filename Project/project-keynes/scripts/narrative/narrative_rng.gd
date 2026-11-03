class_name NarrativeRng
extends RefCounted

const Q16_ONE: int = 65536
const MASK_63: int = 0x7fffffffffffffff

static func _mix64(x: int) -> int:
	var z: int = (x + 0x6a09e667f3bcc908) & MASK_63
	z = ((z ^ (z >> 30)) * 0x517cc1b727220a95) & MASK_63
	z = ((z ^ (z >> 27)) * 0x2545f4914f6cdd1d) & MASK_63
	z = (z ^ (z >> 31)) & MASK_63
	return z

static func hash64(seed_val: int, day: int, country_handle: int, cell_idx: int, salt: int = 0) -> int:
	var h: int = 0x1f83d9abfb41bd6b
	h = _mix64(h ^ (seed_val & MASK_63))
	h = _mix64(h ^ ((day * 0x3c6ef372fe94f82b) & MASK_63))
	h = _mix64(h ^ ((country_handle * 0x5be0cd19137e2179) & MASK_63))
	h = _mix64(h ^ ((cell_idx * 0x517cc1b727220a95) & MASK_63))
	h = _mix64(h ^ ((salt * 0x2545f4914f6cdd1d) & MASK_63))
	return h & MASK_63

static func roll_q16(seed_val: int, day: int, country_handle: int, cell_idx: int, salt: int = 0) -> int:
	var h: int = hash64(seed_val, day, country_handle, cell_idx, salt)
	return (h >> 16) & (Q16_ONE - 1)

static func roll_range(seed_val: int, day: int, country_handle: int, cell_idx: int, min_val: int, max_val: int, salt: int = 0) -> int:
	if max_val <= min_val:
		return min_val
	var span: int = max_val - min_val + 1
	var h: int = hash64(seed_val, day, country_handle, cell_idx, salt)
	return min_val + (h % span)

static func pick_weighted_index(weights: PackedInt64Array, seed_val: int, day: int, country_handle: int, cell_idx: int, salt: int = 0) -> int:
	var total: int = 0
	var count: int = weights.size()
	var last_positive_idx: int = -1
	for i in range(count):
		var w: int = weights[i]
		if w > 0:
			total += w
			last_positive_idx = i
	if total <= 0:
		return -1
	var target: int = hash64(seed_val, day, country_handle, cell_idx, salt) % total
	for i in range(count):
		var w: int = weights[i]
		if w <= 0:
			continue
		if target < w:
			return i
		target -= w
	return last_positive_idx

static func pick_weighted_index_i32(weights: PackedInt32Array, seed_val: int, day: int, country_handle: int, cell_idx: int, salt: int = 0) -> int:
	var weights64 := PackedInt64Array()
	weights64.resize(weights.size())
	for i in range(weights.size()):
		weights64[i] = weights[i]
	return pick_weighted_index(weights64, seed_val, day, country_handle, cell_idx, salt)
