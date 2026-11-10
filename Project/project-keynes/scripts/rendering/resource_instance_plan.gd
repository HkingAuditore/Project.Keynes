extends RefCounted

## Pure resource representation selection and stable instance ranking; never reads live or remembered world state.

const DEPOSIT_FORMS := [16, 17, 18]

const GROUND_FORMS := [19, 20, 21, 22, 23, 25]

const PLAN_BADGE := 8

const PLAN_DECAL := 2

const PLAN_PROP := 1

const PLAN_SUBMERGED := 4

const STRIDE := 16

static func visual_plan(entry: Dictionary, source_water: bool) -> int:
	var family := int(entry.family)
	var form := int(entry.form)
	if source_water:
		return PLAN_SUBMERGED if family == 3 or form == 21 or form == 25 else 0
	if family == 3:
		return PLAN_SUBMERGED # River fish: only where the river body itself passes.
	if form == 26:
		return PLAN_BADGE # 木材：森林本身就是木材，世界里不再叠原木，只保留透镜徽章。
	if family == 0:
		return PLAN_BADGE # 植物群落由地被层绘制。
	if form in GROUND_FORMS:
		return PLAN_DECAL
	if form in DEPOSIT_FORMS:
		return PLAN_DECAL | PLAN_PROP
	return PLAN_PROP


static func _keep_important_instances(buffer: PackedFloat32Array, count: int) -> PackedFloat32Array:
	var order: Array[int] = []
	for i in buffer.size() / STRIDE:
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		var av := buffer[a * STRIDE + 10]
		var bv := buffer[b * STRIDE + 10]
		return av > bv if av != bv else a < b)
	var result := PackedFloat32Array()
	result.resize(count * STRIDE)
	for i in count:
		for k in STRIDE:
			result[i * STRIDE + k] = buffer[order[i] * STRIDE + k]
	return result


static func _hash(cell: int, salt: int) -> float:
	var value := ((cell + 1) * 1103515245 + (salt + 71) * 12345) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 1274126177) & 0x7fffffff
	return float(value) / 2147483647.0
