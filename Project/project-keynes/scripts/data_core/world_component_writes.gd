extends RefCounted

const _Slot = preload("res://scripts/data_core/world_component_slot.gd")


# 内部：单点 mark（hot path 高频，inline-friendly）。
static func _dirty_mark_one(owner: Variant, idx: int) -> void:
	if not owner.dirty_mask_enabled:
		return
	if idx >= 0 and idx < owner._dirty_cell_mask_size:
		owner._dirty_cell_mask[idx] = 1
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] 也许凶手是单点写
		# write_f32(idx, v)，前 30 次打调用栈定位（每个不同 caller 只打一次去重）
		if owner.ENABLE_DIRTY_MARK_STACK_DIAG:
			owner._diag_dump_caller_one(idx)


# 内部：成段 mark（[start, start+n) 全标）。
static func _dirty_mark_range(owner: Variant, start: int, n: int) -> void:
	if not owner.dirty_mask_enabled or n <= 0 or owner._dirty_cell_mask_size <= 0:
		return
	var lo: int = maxi(start, 0)
	var hi: int = mini(start + n, owner._dirty_cell_mask_size)
	for i in range(lo, hi):
		owner._dirty_cell_mask[i] = 1
	if owner.ENABLE_DIRTY_MARK_STACK_DIAG:
		owner._diag_dump_caller("range", hi - lo)


# 内部：批量索引 mark（dirty_indices 列表，越界元素自动跳过）。
static func _dirty_mark_indexed(owner: Variant, indices: PackedInt32Array) -> void:
	if not owner.dirty_mask_enabled or owner._dirty_cell_mask_size <= 0:
		return
	var cap: int = owner._dirty_cell_mask_size
	var n: int = indices.size()
	for k in range(n):
		var idx: int = indices[k]
		if idx >= 0 and idx < cap:
			owner._dirty_cell_mask[idx] = 1
	if owner.ENABLE_DIRTY_MARK_STACK_DIAG:
		owner._diag_dump_caller("indexed", n)


## 单元素写入：F32 component。
static func write_f32(owner: Variant, comp_id: int, idx: int, v: float) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_f32: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.F32 and slot.dtype != DCComponentIds.VEC2_F32 and slot.dtype != DCComponentIds.VEC3_F32:
		push_error("[DCWorld] write_f32: comp '%s' dtype=%s is not F32-compatible"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	if idx < 0 or idx >= slot.arr_f32.size():
		push_error("[DCWorld] write_f32: idx=%d out of range [0,%d)" % [idx, slot.arr_f32.size()])
		return
	slot.arr_f32[idx] = v
	owner._dirty_mark_one(idx)


## 单元素写入：I32 component。
static func write_i32(owner: Variant, comp_id: int, idx: int, v: int) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_i32: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.I32:
		push_error("[DCWorld] write_i32: comp '%s' dtype=%s is not I32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	if idx < 0 or idx >= slot.arr_i32.size():
		push_error("[DCWorld] write_i32: idx=%d out of range [0,%d)" % [idx, slot.arr_i32.size()])
		return
	slot.arr_i32[idx] = v
	owner._dirty_mark_one(idx)


## 单元素写入：U8 component（int 入参，自动 & 0xFF 截断）。
static func write_u8(owner: Variant, comp_id: int, idx: int, v: int) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_u8: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.U8:
		push_error("[DCWorld] write_u8: comp '%s' dtype=%s is not U8"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	if idx < 0 or idx >= slot.arr_u8.size():
		push_error("[DCWorld] write_u8: idx=%d out of range [0,%d)" % [idx, slot.arr_u8.size()])
		return
	slot.arr_u8[idx] = v & 0xFF
	owner._dirty_mark_one(idx)


## 成段写入：F32 component。把 src[0..src.size()) 写到 arr[start..start+src.size())。
static func write_f32_range(owner: Variant, comp_id: int, start: int, src: PackedFloat32Array) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_f32_range: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.F32 and slot.dtype != DCComponentIds.VEC2_F32 and slot.dtype != DCComponentIds.VEC3_F32:
		push_error("[DCWorld] write_f32_range: comp '%s' dtype not F32-compatible" % String(slot.name))
		return
	var n: int = src.size()
	if n <= 0:
		return
	if start < 0 or start + n > slot.arr_f32.size():
		push_error("[DCWorld] write_f32_range: range [%d,%d) out of [0,%d)" % [start, start + n, slot.arr_f32.size()])
		return
	for i in range(n):
		slot.arr_f32[start + i] = src[i]
	owner._dirty_mark_range(start, n)


## 成段写入：I32 component。
static func write_i32_range(owner: Variant, comp_id: int, start: int, src: PackedInt32Array) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_i32_range: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.I32:
		push_error("[DCWorld] write_i32_range: comp '%s' dtype not I32" % String(slot.name))
		return
	var n: int = src.size()
	if n <= 0:
		return
	if start < 0 or start + n > slot.arr_i32.size():
		push_error("[DCWorld] write_i32_range: range [%d,%d) out of [0,%d)" % [start, start + n, slot.arr_i32.size()])
		return
	for i in range(n):
		slot.arr_i32[start + i] = src[i]
	owner._dirty_mark_range(start, n)


## 成段写入：U8 component。
static func write_u8_range(owner: Variant, comp_id: int, start: int, src: PackedByteArray) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_u8_range: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.U8:
		push_error("[DCWorld] write_u8_range: comp '%s' dtype not U8" % String(slot.name))
		return
	var n: int = src.size()
	if n <= 0:
		return
	if start < 0 or start + n > slot.arr_u8.size():
		push_error("[DCWorld] write_u8_range: range [%d,%d) out of [0,%d)" % [start, start + n, slot.arr_u8.size()])
		return
	for i in range(n):
		slot.arr_u8[start + i] = src[i]
	owner._dirty_mark_range(start, n)


## 批量索引写：F32 component。
## 把 values[k] 写到 arr[indices[k]]，k ∈ [0, min(indices.size(), values.size()))。
##
## [perf 2026-05-20 indexed-value-diff] 旧版无条件 _dirty_mark_indexed(indices)
##   导致 weather_system 每 tick commit 2400 idx → mask 全 1 → atlas_upload 全推。
##   现改为 value-diff：仅当 arr[idx] != values[k] 才写 + 标 dirty。
##   语义等价于 write_f32_dense 的 value-diff 行为。
static func write_f32_indexed(owner: Variant, comp_id: int, indices: PackedInt32Array, values: PackedFloat32Array) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_f32_indexed: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.F32 and slot.dtype != DCComponentIds.VEC2_F32 and slot.dtype != DCComponentIds.VEC3_F32:
		push_error("[DCWorld] write_f32_indexed: comp '%s' dtype=%s is not F32-compatible"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	var arr: PackedFloat32Array = slot.arr_f32
	var cap: int = arr.size()
	var n: int = mini(indices.size(), values.size())
	if owner.dirty_mask_enabled and owner._dirty_cell_mask_size > 0:
		var mask_cap: int = owner._dirty_cell_mask_size
		for k in range(n):
			var idx: int = indices[k]
			if idx >= 0 and idx < cap:
				var v_new: float = values[k]
				if arr[idx] != v_new:
					arr[idx] = v_new
					if idx < mask_cap:
						owner._dirty_cell_mask[idx] = 1
	else:
		for k in range(n):
			var idx2: int = indices[k]
			if idx2 >= 0 and idx2 < cap:
				arr[idx2] = values[k]


## 批量索引写：I32 component。
## [perf 2026-05-20 indexed-value-diff] 同 write_f32_indexed。
static func write_i32_indexed(owner: Variant, comp_id: int, indices: PackedInt32Array, values: PackedInt32Array) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_i32_indexed: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.I32:
		push_error("[DCWorld] write_i32_indexed: comp '%s' dtype=%s is not I32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	var arr: PackedInt32Array = slot.arr_i32
	var cap: int = arr.size()
	var n: int = mini(indices.size(), values.size())
	if owner.dirty_mask_enabled and owner._dirty_cell_mask_size > 0:
		var mask_cap: int = owner._dirty_cell_mask_size
		for k in range(n):
			var idx: int = indices[k]
			if idx >= 0 and idx < cap:
				var v_new: int = values[k]
				if arr[idx] != v_new:
					arr[idx] = v_new
					if idx < mask_cap:
						owner._dirty_cell_mask[idx] = 1
	else:
		for k in range(n):
			var idx2: int = indices[k]
			if idx2 >= 0 and idx2 < cap:
				arr[idx2] = values[k]


## 批量索引写：U8 component（int 入参，自动 & 0xFF 截断）。
## [perf 2026-05-20 indexed-value-diff] 同 write_f32_indexed。
static func write_u8_indexed(owner: Variant, comp_id: int, indices: PackedInt32Array, values: PackedByteArray) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_u8_indexed: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.U8:
		push_error("[DCWorld] write_u8_indexed: comp '%s' dtype=%s is not U8"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	var arr: PackedByteArray = slot.arr_u8
	var cap: int = arr.size()
	var n: int = mini(indices.size(), values.size())
	if owner.dirty_mask_enabled and owner._dirty_cell_mask_size > 0:
		var mask_cap: int = owner._dirty_cell_mask_size
		for k in range(n):
			var idx: int = indices[k]
			if idx >= 0 and idx < cap:
				var v_new: int = values[k] & 0xFF
				if arr[idx] != v_new:
					arr[idx] = v_new
					if idx < mask_cap:
						owner._dirty_cell_mask[idx] = 1
	else:
		for k in range(n):
			var idx2: int = indices[k]
			if idx2 >= 0 and idx2 < cap:
				arr[idx2] = values[k] & 0xFF


## 批量整段写：F32 component。把 values[0..n) 写到 arr[0..n)，并标 dirty range。
static func write_f32_dense(owner: Variant, comp_id: int, values: PackedFloat32Array) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_f32_dense: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.F32 and slot.dtype != DCComponentIds.VEC2_F32 and slot.dtype != DCComponentIds.VEC3_F32:
		push_error("[DCWorld] write_f32_dense: comp '%s' dtype=%s is not F32-compatible"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	var arr: PackedFloat32Array = slot.arr_f32
	var n: int = mini(values.size(), arr.size())
	# [perf 2026-05-20] value-diff 标脏：仅对实际变化的 cell 标脏。
	# 修复 atlas 全图重传问题：write_f32_dense 之前无条件 mark_range(0, n)，
	# 即使绝大多数 cell 值未变也会全脏 → atlas_upload dirty_count=n 每帧 → 18-22ms 卡顿。
	if owner.dirty_mask_enabled and owner._dirty_cell_mask_size > 0:
		var cap: int = owner._dirty_cell_mask_size
		for k in range(n):
			var v_new: float = values[k]
			if arr[k] != v_new:
				arr[k] = v_new
				if k < cap:
					owner._dirty_cell_mask[k] = 1
	else:
		for k in range(n):
			arr[k] = values[k]


## 批量整段写：I32 component。
static func write_i32_dense(owner: Variant, comp_id: int, values: PackedInt32Array) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_i32_dense: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.I32:
		push_error("[DCWorld] write_i32_dense: comp '%s' dtype=%s is not I32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	var arr: PackedInt32Array = slot.arr_i32
	var n: int = mini(values.size(), arr.size())
	# [perf 2026-05-20] value-diff 标脏：仅对实际变化的 cell 标脏（同 write_f32_dense）。
	if owner.dirty_mask_enabled and owner._dirty_cell_mask_size > 0:
		var cap: int = owner._dirty_cell_mask_size
		for k in range(n):
			var v_new: int = values[k]
			if arr[k] != v_new:
				arr[k] = v_new
				if k < cap:
					owner._dirty_cell_mask[k] = 1
	else:
		for k in range(n):
			arr[k] = values[k]


## 批量整段写：U8 component。values 是 PackedByteArray，会按需 & 0xFF。
static func write_u8_dense(owner: Variant, comp_id: int, values: PackedByteArray) -> void:
	var slot: _Slot = owner._get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] write_u8_dense: invalid comp_id=%d" % comp_id)
		return
	if slot.dtype != DCComponentIds.U8:
		push_error("[DCWorld] write_u8_dense: comp '%s' dtype=%s is not U8"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return
	var arr: PackedByteArray = slot.arr_u8
	var n: int = mini(values.size(), arr.size())
	# [perf 2026-05-20] value-diff 标脏：仅对实际变化的 cell 标脏（同 write_f32_dense）。
	if owner.dirty_mask_enabled and owner._dirty_cell_mask_size > 0:
		var cap: int = owner._dirty_cell_mask_size
		for k in range(n):
			var v_new: int = values[k] & 0xFF
			if arr[k] != v_new:
				arr[k] = v_new
				if k < cap:
					owner._dirty_cell_mask[k] = 1
	else:
		for k in range(n):
			arr[k] = values[k] & 0xFF


## 公开 API：手工标脏单 cell（外部直写场景兜底，例如 baker initialize 全脏）。
## idx 必须在 [0, cell_count) 内；越界静默跳过。dirty_mask_enabled = false 时 no-op。
static func mark_dirty(owner: Variant, idx: int) -> void:
	owner._dirty_mark_one(idx)


## 公开 API：成段标脏 [start, start+n)。多用于"刚 bind / regenerate 后强制全脏"。
static func mark_dirty_range(owner: Variant, start: int, n: int) -> void:
	owner._dirty_mark_range(start, n)


## 公开 API：批量索引标脏。多用于"sim Job 已经攒了 dirty_indices 但走自定义路径写"。
static func mark_dirty_indexed(owner: Variant, indices: PackedInt32Array) -> void:
	owner._dirty_mark_indexed(indices)


## 公开 API：把全脏标志强制设为全 1（首帧 baker bake_world / regenerate 用）。
static func mark_dirty_all(owner: Variant) -> void:
	if not owner.dirty_mask_enabled or owner._dirty_cell_mask_size <= 0:
		return
	owner._dirty_cell_mask.fill(1)


## 清空 dirty mask 但不构造 index 数组。稠密 dirty 消费端会直接走 full encode，
## 这里用 PackedByteArray 的 native fill，避免 GDScript 双遍扫描 6400 个 cell。
static func clear_dirty_mask(owner: Variant) -> void:
	if owner._dirty_cell_mask_size <= 0:
		return
	owner._dirty_cell_mask.fill(0)


## 公开 API：原子地"读出当前所有 dirty cell 的 index 列表 + 把 mask 清零"。
##
## 返回 PackedInt32Array（升序，因遍历顺序保证）。
## SUS scheduler 是单线程串行，priority 序天然把 sim 写 Job 排在
## visual upload job 之前 → baker 入口调本方法即获得 tick 内
## "全部待消费 dirty"快照；之后 sim 再写下个 tick 的脏会重新累积。
##
## dirty_mask_enabled = false 或 mask_size = 0 时返回空数组（baker 应当退化到
## "all_cells 全扫"行为）。
static func read_and_clear_dirty_mask(owner: Variant) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if not owner.dirty_mask_enabled or owner._dirty_cell_mask_size <= 0:
		return out
	# 首遍计数（避免 push_back 多次扩容）
	var cap: int = owner._dirty_cell_mask_size
	var cnt: int = 0
	for i in range(cap):
		if owner._dirty_cell_mask[i] != 0:
			cnt += 1
	if cnt == 0:
		return out
	out.resize(cnt)
	var w: int = 0
	for i in range(cap):
		if owner._dirty_cell_mask[i] != 0:
			out[w] = i
			w += 1
			owner._dirty_cell_mask[i] = 0
	return out


## 公开 API：诊断 / log 用，不清零。
static func peek_dirty_count(owner: Variant) -> int:
	if not owner.dirty_mask_enabled or owner._dirty_cell_mask_size <= 0:
		return 0
	var cnt: int = 0
	for i in range(owner._dirty_cell_mask_size):
		if owner._dirty_cell_mask[i] != 0:
			cnt += 1
	return cnt


## 公开 API：dirty mask 当前覆盖的 cell 数（= cells pool capacity）。诊断用。
static func dirty_mask_size(owner: Variant) -> int:
	return owner._dirty_cell_mask_size


# 内部：bind_map_data / unbind 调用，使 mask 大小与 cells pool 同步。
static func _resize_dirty_mask(owner: Variant, new_size: int) -> void:
	if new_size < 0:
		new_size = 0
	owner._dirty_cell_mask_size = new_size
	owner._dirty_cell_mask.resize(new_size)
	# resize 后内容未定义，统一清 0
	for i in range(new_size):
		owner._dirty_cell_mask[i] = 0
