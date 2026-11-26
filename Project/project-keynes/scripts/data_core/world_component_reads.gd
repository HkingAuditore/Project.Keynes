extends RefCounted

const _Slot = preload("res://scripts/data_core/world_component_slot.gd")


## 取 F32 component 主数组（hot loop 用）。
static func view_f32(owner: Variant, comp_id: int) -> PackedFloat32Array:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_f32: invalid comp_id=%d" % comp_id)
		return PackedFloat32Array()
	if slot.dtype != DCComponentIds.F32 and slot.dtype != DCComponentIds.VEC2_F32 and slot.dtype != DCComponentIds.VEC3_F32:
		push_error("[DCWorld] view_f32: comp '%s' dtype=%s is not F32-compatible"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return PackedFloat32Array()
	return slot.arr_f32


## 取 F32 component 上一轮快照（要求 register 时 track_prev=true）。
static func view_f32_prev(owner: Variant, comp_id: int) -> PackedFloat32Array:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_f32_prev: invalid comp_id=%d" % comp_id)
		return PackedFloat32Array()
	if not slot.track_prev:
		push_error("[DCWorld] view_f32_prev: comp '%s' was not registered with track_prev=true" % String(slot.name))
		return PackedFloat32Array()
	return slot.arr_f32_prev


## 取 I32 component 主数组。
static func view_i32(owner: Variant, comp_id: int) -> PackedInt32Array:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_i32: invalid comp_id=%d" % comp_id)
		return PackedInt32Array()
	if slot.dtype != DCComponentIds.I32:
		push_error("[DCWorld] view_i32: comp '%s' dtype=%s is not I32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return PackedInt32Array()
	return slot.arr_i32


## 取 U8 component 主数组。
static func view_u8(owner: Variant, comp_id: int) -> PackedByteArray:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_u8: invalid comp_id=%d" % comp_id)
		return PackedByteArray()
	if slot.dtype != DCComponentIds.U8:
		push_error("[DCWorld] view_u8: comp '%s' dtype=%s is not U8"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return PackedByteArray()
	return slot.arr_u8


## 单元素读取：F32 component。冷路径（UI / baker / test / debug print）使用；
## hot loop 应在循环外 `var arr := view_f32(cid)`，循环内直接 `arr[i]`。
## 越界 / dtype 不匹配返回 0.0 并 push_error。
static func read_f32(owner: Variant, comp_id: int, idx: int) -> float:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] read_f32: invalid comp_id=%d" % comp_id)
		return 0.0
	if slot.dtype != DCComponentIds.F32 and slot.dtype != DCComponentIds.VEC2_F32 and slot.dtype != DCComponentIds.VEC3_F32:
		push_error("[DCWorld] read_f32: comp '%s' dtype=%s is not F32-compatible"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return 0.0
	if idx < 0 or idx >= slot.arr_f32.size():
		push_error("[DCWorld] read_f32: idx=%d out of range [0,%d)" % [idx, slot.arr_f32.size()])
		return 0.0
	return slot.arr_f32[idx]


## 单元素读取：I32 component。
static func read_i32(owner: Variant, comp_id: int, idx: int) -> int:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] read_i32: invalid comp_id=%d" % comp_id)
		return 0
	if slot.dtype != DCComponentIds.I32:
		push_error("[DCWorld] read_i32: comp '%s' dtype=%s is not I32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return 0
	if idx < 0 or idx >= slot.arr_i32.size():
		push_error("[DCWorld] read_i32: idx=%d out of range [0,%d)" % [idx, slot.arr_i32.size()])
		return 0
	return slot.arr_i32[idx]


## 单元素读取：U8 component（返回 0..255 的 int）。
static func read_u8(owner: Variant, comp_id: int, idx: int) -> int:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] read_u8: invalid comp_id=%d" % comp_id)
		return 0
	if slot.dtype != DCComponentIds.U8:
		push_error("[DCWorld] read_u8: comp '%s' dtype=%s is not U8"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return 0
	if idx < 0 or idx >= slot.arr_u8.size():
		push_error("[DCWorld] read_u8: idx=%d out of range [0,%d)" % [idx, slot.arr_u8.size()])
		return 0
	return slot.arr_u8[idx]


## 单元素读取：U8 component 当作 bool（> 0 即 true）。
## D3-b：让"weather_field_initialized / _ema_initialized / has_river"等 0/1
## 标志的调用方语义无感，对称 write_bool。
static func read_bool(owner: Variant, comp_id: int, idx: int) -> bool:
	return owner.read_u8(comp_id, idx) > 0


## 取 VEC2 component 拆轴视图：{ x: PackedFloat32Array, y: PackedFloat32Array }
static func view_vec2(owner: Variant, comp_id: int) -> Dictionary:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_vec2: invalid comp_id=%d" % comp_id)
		return {}
	if slot.dtype != DCComponentIds.VEC2_F32:
		push_error("[DCWorld] view_vec2: comp '%s' dtype=%s is not VEC2_F32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return {}
	return { "x": slot.arr_f32, "y": slot.arr_f32_y }


## 取 VEC2 component 上一轮快照拆轴视图。
static func view_vec2_prev(owner: Variant, comp_id: int) -> Dictionary:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_vec2_prev: invalid comp_id=%d" % comp_id)
		return {}
	if slot.dtype != DCComponentIds.VEC2_F32:
		push_error("[DCWorld] view_vec2_prev: comp '%s' dtype=%s is not VEC2_F32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return {}
	if not slot.track_prev:
		push_error("[DCWorld] view_vec2_prev: comp '%s' has no track_prev" % String(slot.name))
		return {}
	return { "x": slot.arr_f32_prev, "y": slot.arr_f32_y_prev }
