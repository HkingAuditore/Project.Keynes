extends RefCounted

const _Slot = preload("res://scripts/data_core/world_component_slot.gd")


## sub-pass 开始（计数 +1，用于 swap 守卫）。
static func begin_sub_pass(owner: Variant) -> void:
	owner._pending_passes += 1


## sub-pass 结束（计数 -1）。负数视为编程错误。
static func end_sub_pass(owner: Variant) -> void:
	owner._pending_passes -= 1
	if owner._pending_passes < 0:
		push_error("[DCWorld] end_sub_pass: pending passes underflow (-> %d)" % owner._pending_passes)
		owner._pending_passes = 0


## 当前是否有 sub-pass 在飞。
static func has_pending_pass(owner: Variant) -> bool:
	return owner._pending_passes > 0


## 由调度器在 system tick 前调用。仅 debug 构建生效。
##  - writes: 本 pass 声明会写入的 component StringName 数组
##  - reads:  本 pass 声明会读取的 component StringName 数组
##  - pass_id: 调试日志用的 pass 名（system.id）
static func _debug_begin_pass(owner: Variant, writes: Array, reads: Array, pass_id: StringName = &"") -> void:
	if not owner._debug:
		return
	if owner._debug_pass_active:
		push_warning("[DCWorld] _debug_begin_pass: previous pass '%s' not closed; auto-closing" % String(owner._debug_pass_id))
	owner._debug_pass_active = true
	owner._debug_pass_writes = writes
	owner._debug_pass_reads = reads
	owner._debug_pass_id = pass_id


## 由调度器在 system tick 后调用。仅 debug 构建生效。
static func _debug_end_pass(owner: Variant, _pass_id: StringName = &"") -> void:
	if not owner._debug:
		return
	owner._debug_pass_active = false
	owner._debug_pass_writes = []
	owner._debug_pass_reads = []
	owner._debug_pass_id = &""


## 内部：write_* 入口可调本函数检查目标 component 是否已声明。当前未在
## write_* 内插入调用以避免 hot path 开销；future iteration 会按需接入。
static func _debug_check_write(owner: Variant, comp_id: int) -> void:
	if not owner._debug or not owner._debug_pass_active:
		return
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		return
	if not owner._debug_pass_writes.has(slot.name):
		push_error("[DCWorld] write violation in pass '%s': component '%s' not in declare_writes %s"
			% [String(owner._debug_pass_id), String(slot.name), str(owner._debug_pass_writes)])


## O(1) 交换一组 component 的 _arr / _arr_prev 引用。
## 调用方必须保证所有 sub-pass 都已 end_sub_pass()，否则在 debug 构建 push_error 中止。
static func swap_double_buffer(owner: Variant, comp_ids: Array) -> void:
	if owner._pending_passes > 0:
		push_error("[DCWorld] swap_double_buffer: %d sub-pass still in flight, refusing to swap" % owner._pending_passes)
		return
	for cid in comp_ids:
		var slot: _Slot = owner._get_slot(int(cid))
		if slot == null:
			continue
		if not slot.track_prev:
			if owner._debug:
				push_warning("[DCWorld] swap_double_buffer: comp '%s' has no prev buffer, skipped" % String(slot.name))
			continue
		match slot.dtype:
			DCComponentIds.F32:
				var tmp_f: PackedFloat32Array = slot.arr_f32
				slot.arr_f32 = slot.arr_f32_prev
				slot.arr_f32_prev = tmp_f
			DCComponentIds.VEC2_F32:
				var tmp_x: PackedFloat32Array = slot.arr_f32
				slot.arr_f32 = slot.arr_f32_prev
				slot.arr_f32_prev = tmp_x
				var tmp_y: PackedFloat32Array = slot.arr_f32_y
				slot.arr_f32_y = slot.arr_f32_y_prev
				slot.arr_f32_y_prev = tmp_y
			DCComponentIds.VEC3_F32:
				var tmp_xx: PackedFloat32Array = slot.arr_f32
				slot.arr_f32 = slot.arr_f32_prev
				slot.arr_f32_prev = tmp_xx
				var tmp_yy: PackedFloat32Array = slot.arr_f32_y
				slot.arr_f32_y = slot.arr_f32_y_prev
				slot.arr_f32_y_prev = tmp_yy
				var tmp_zz: PackedFloat32Array = slot.arr_f32_z
				slot.arr_f32_z = slot.arr_f32_z_prev
				slot.arr_f32_z_prev = tmp_zz
			_:
				# I32 / U8 首版不双缓冲；track_prev=true 也忽略
				pass


## round 末"完成快照"：等价 swap_double_buffer，但语义上是"提交一轮"。
## 阶段实现一致；后续若需要语义分化（例如 commit 不交换 ref 而是 memcpy 快照）再调整。
static func commit_round(owner: Variant, comp_ids: Array) -> void:
	owner.swap_double_buffer(comp_ids)
