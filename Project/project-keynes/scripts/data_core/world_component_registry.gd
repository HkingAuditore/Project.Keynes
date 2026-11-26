extends RefCounted

const _Slot = preload("res://scripts/data_core/world_component_slot.gd")


## 注册一个 component，返回 comp_id (int)。
## 重复注册同名 component 视为幂等，直接返回已有 id。
static func register_component(owner: Variant, name: StringName, dtype: int, stride: int = 1, track_prev: bool = false) -> int:
	if owner._slot_by_name.has(name):
		return int(owner._slot_by_name[name])
	if not DCComponentIds.is_valid_dtype(dtype):
		push_error("[DCWorld] register_component '%s': invalid dtype=%d" % [String(name), dtype])
		return -1
	if stride < 1:
		push_error("[DCWorld] register_component '%s': stride must be >= 1, got %d" % [String(name), stride])
		return -1
	# stride>1 仅在 F32 上面允许（语义已经被 VEC2/VEC3 dtype 覆盖；这里允许业务侧用 stride 自行打包）
	if (dtype == DCComponentIds.I32 or dtype == DCComponentIds.U8) and stride != 1:
		push_error("[DCWorld] register_component '%s': I32/U8 dtype only supports stride=1" % String(name))
		return -1
	var slot := _Slot.new()
	slot.name = name
	slot.dtype = dtype
	slot.stride = stride
	slot.track_prev = track_prev
	slot.external_ref = false
	# 预分配到当前 entity_count（若尚未 create_entities，则保持空数组）
	owner._slot_resize(slot, owner._entity_count)
	owner._slots.append(slot)
	var cid: int = owner._slots.size() - 1
	owner._slot_by_name[name] = cid
	return cid


## 一次性把 entity 数量设为 count，并 resize 全部已注册 component。
## 禁止单 entity push_back（GC 压力）。
static func create_entities(owner: Variant, count: int) -> void:
	if count < 0:
		push_error("[DCWorld] create_entities: count must be >= 0, got %d" % count)
		return
	owner._entity_count = count
	for slot in owner._slots:
		# 外部引用槽位（bind_map_data 挂入）由 MapData 自己负责长度，World 不强制 resize
		if not slot.external_ref:
			owner._slot_resize(slot, count)


## 全部 component 同步 resize 到 new_count（CommandBuffer 在 flush 时使用）。
static func resize_all(owner: Variant, new_count: int) -> void:
	owner.create_entities(new_count)


## 取底层 PackedArray 引用（hot loop 用）。dtype 不匹配时返回 null。
##  - F32 / VEC2_F32 / VEC3_F32 → 返回 x 轴 PackedFloat32Array
##  - I32 → PackedInt32Array
##  - U8 → PackedByteArray
static func get_component_array(owner: Variant, comp_id: int):
	if comp_id < 0 or comp_id >= owner._slots.size():
		push_error("[DCWorld] get_component_array: invalid comp_id=%d" % comp_id)
		return null
	var slot: _Slot = owner._slots[comp_id]
	match slot.dtype:
		DCComponentIds.F32, DCComponentIds.VEC2_F32, DCComponentIds.VEC3_F32:
			return slot.arr_f32
		DCComponentIds.I32:
			return slot.arr_i32
		DCComponentIds.U8:
			return slot.arr_u8
	return null


static func _slot_resize(owner: Variant, slot: _Slot, n: int) -> void:
	match slot.dtype:
		DCComponentIds.F32:
			slot.arr_f32.resize(n * slot.stride)
			if slot.track_prev:
				slot.arr_f32_prev.resize(n * slot.stride)
		DCComponentIds.VEC2_F32:
			slot.arr_f32.resize(n)
			slot.arr_f32_y.resize(n)
			if slot.track_prev:
				slot.arr_f32_prev.resize(n)
				slot.arr_f32_y_prev.resize(n)
		DCComponentIds.VEC3_F32:
			slot.arr_f32.resize(n)
			slot.arr_f32_y.resize(n)
			slot.arr_f32_z.resize(n)
			if slot.track_prev:
				slot.arr_f32_prev.resize(n)
				slot.arr_f32_y_prev.resize(n)
				slot.arr_f32_z_prev.resize(n)
		DCComponentIds.I32:
			slot.arr_i32.resize(n)
		DCComponentIds.U8:
			slot.arr_u8.resize(n)


## 内部：调试日志（World 注册规模等）。
static func describe(owner: Variant) -> Dictionary:
	return {
		"entity_count": owner._entity_count,
		"component_count": owner._slots.size(),
		"bound": owner._bound,
	}
