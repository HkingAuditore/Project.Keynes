extends RefCounted
class_name DCWorld

## DataCore — World 容器（DOTS 风格数据架构基石的根）。
##
## 职责：
##   1. Component 注册表：按类型 ID 存储 PackedArray 槽位（含 _prev 双缓冲）；
##   2. Entity 计数器（首版直接 = MapData.cell_count() / front 池容量）；
##   3. Query 工厂（DCQuery 池）—— 由 query.gd 在 Task 3 实现；
##   4. CommandBuffer 入口 —— 由 command_buffer.gd 在 Task 5 实现；
##   5. Archetype 逻辑分组 —— Task 6；
##   6. bind_map_data() 桥接：把 MapData 25 个 PackedArray 按引用挂入 component 槽 —— Task 4。
##
## hot loop 设计原则：
##   - get_component_array() / view_f32() / view_i32() / view_u8() 全部直接返回
##     底层 PackedArray 引用，零拷贝；调用方在循环外取一次本地引用，循环内只
##     做 `arr[i]` 索引，单次访问与 legacy `temp_arr[i]` 完全等价；
##   - register_component() / create_entities() 等结构性操作只在启动 / regenerate
##     时调用，不在 hot path 触发；
##   - 移动平台兼容：纯 GDScript + Packed*Array，零 GDExtension 依赖。

# ─── 内部数据结构 ─────────────────────────────────────────────
# Component 槽位：每个槽位记录 dtype / track_prev / 主数组 / prev 镜像。
#   - F32         → arr_f32 / arr_f32_prev (PackedFloat32Array)
#   - I32         → arr_i32 (PackedInt32Array)（首版不双缓冲）
#   - U8          → arr_u8  (PackedByteArray)（首版不双缓冲）
#   - VEC2_F32    → arr_f32 = x 轴, arr_f32_y = y 轴
#   - VEC3_F32    → arr_f32 = x 轴, arr_f32_y = y, arr_f32_z = z
#
# 注：把 vec2 / vec3 拆轴是因为 hot loop 用 stride>1 packed 索引会有 ~30% 损失；
# 拆轴后内层循环可以直接 `xarr[i]` `yarr[i]` 读取，与 legacy 行为一致。
class _Slot:
	extends RefCounted
	var name: StringName
	var dtype: int
	var stride: int = 1
	var track_prev: bool = false
	var external_ref: bool = false  # true = 由 bind_map_data() 挂入的外部数组（rebind 时刷新）
	var arr_f32: PackedFloat32Array = PackedFloat32Array()
	var arr_f32_prev: PackedFloat32Array = PackedFloat32Array()
	var arr_f32_y: PackedFloat32Array = PackedFloat32Array()
	var arr_f32_y_prev: PackedFloat32Array = PackedFloat32Array()
	var arr_f32_z: PackedFloat32Array = PackedFloat32Array()
	var arr_f32_z_prev: PackedFloat32Array = PackedFloat32Array()
	var arr_i32: PackedInt32Array = PackedInt32Array()
	var arr_u8: PackedByteArray = PackedByteArray()


var _slots: Array = []                         # Array[_Slot]
var _slot_by_name: Dictionary = {}             # StringName → comp_id (int)
var _entity_count: int = 0

# Bind 状态（Task 4 完整接入；首版仅占位）
var _map_data = null                           # MapData 弱引用
var _bound: bool = false

# Pending sub-pass 计数（Task 2 swap 守卫用）。每个 sub-pass 开始时 +1，完成
# -1；为 0 时才允许调用 swap_double_buffer / commit_round。
var _pending_passes: int = 0

# 调试：debug 构建下发出更严的告警。
var _debug: bool = OS.is_debug_build()

# ─── Dirty Cell Mask（plan: cell-dirty-push-and-dots-atlas-bakers, 阶段 A） ─────
#
# 目的：让 4 张运行期 atlas baker（map_baker.gd 的 dynamic_cell / ecology_visual /
# dyn_atlas_smooth / ice_state）能事件驱动地"只重烘改过的 cell"，替代现状
# "for cell in all_cells: sig 比对" 的 O(N) 全图扫。
#
# 漏斗：所有写 cell-level component 的路径都走 DCWorld 的 9 个 write_* API
# （write_f32 / write_f32_range / write_f32_indexed / write_u8* / write_i32*）。
# HexCell 21 个 facade setter 也走 _world.write_*，所以本层是唯一漏斗位。
#
# 范围：mask 只覆盖 cells pool（[0, n_cells)）。其他 pool（weather front 池等）
# 写 idx >= n_cells 时本层直接跳过 mark（mask 大小固定 = n_cells）。
#
# 同步：SUS scheduler 单线程串行 tick，visual upload jobs
# 必然跑在所有 sim 写字段 Job 之后；baker 入口
# read_and_clear_dirty_mask() 一次性快照 + 清零，原子语义靠"消费在写之后"保证。
#
# 性能：mark_dirty 单点开销 = 1 次比较 + 1 次 byte 写，N=1e5 全脏 ≈ 0.5ms（cold
# path 上限）。生产 dirty 占比 ≤ 5%，单次 baker tick mark 总 cost < 0.05ms。
#
# 向后兼容：dirty_mask_enabled = false 时 mark 全部 no-op，baker 走 legacy 路径。
var _dirty_cell_mask: PackedByteArray = PackedByteArray()
var _dirty_cell_mask_size: int = 0      # = cells pool capacity；mark/read_and_clear 内联用
var dirty_mask_enabled: bool = true     # 飞行开关；false 时 mark_* 全 no-op


# ─── Task 1 — Component 注册 / 创建 entity / 基础访问 ───────────────────

## 注册一个 component，返回 comp_id (int)。
## 重复注册同名 component 视为幂等，直接返回已有 id。
func register_component(name: StringName, dtype: int, stride: int = 1, track_prev: bool = false) -> int:
	if _slot_by_name.has(name):
		return int(_slot_by_name[name])
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
	_slot_resize(slot, _entity_count)
	_slots.append(slot)
	var cid: int = _slots.size() - 1
	_slot_by_name[name] = cid
	return cid


## 通过 StringName 查询 comp_id；不存在返回 -1。
func component_id(name: StringName) -> int:
	return int(_slot_by_name.get(name, -1))


## 当前已注册 component 数量。
func component_count() -> int:
	return _slots.size()


## 当前 entity 总数。
func entity_count() -> int:
	return _entity_count


## 一次性把 entity 数量设为 count，并 resize 全部已注册 component。
## 禁止单 entity push_back（GC 压力）。
func create_entities(count: int) -> void:
	if count < 0:
		push_error("[DCWorld] create_entities: count must be >= 0, got %d" % count)
		return
	_entity_count = count
	for slot in _slots:
		# 外部引用槽位（bind_map_data 挂入）由 MapData 自己负责长度，World 不强制 resize
		if not slot.external_ref:
			_slot_resize(slot, count)


## 全部 component 同步 resize 到 new_count（CommandBuffer 在 flush 时使用）。
func resize_all(new_count: int) -> void:
	create_entities(new_count)


## 取底层 PackedArray 引用（hot loop 用）。dtype 不匹配时返回 null。
##  - F32 / VEC2_F32 / VEC3_F32 → 返回 x 轴 PackedFloat32Array
##  - I32 → PackedInt32Array
##  - U8 → PackedByteArray
func get_component_array(comp_id: int):
	if comp_id < 0 or comp_id >= _slots.size():
		push_error("[DCWorld] get_component_array: invalid comp_id=%d" % comp_id)
		return null
	var slot: _Slot = _slots[comp_id]
	match slot.dtype:
		DCComponentIds.F32, DCComponentIds.VEC2_F32, DCComponentIds.VEC3_F32:
			return slot.arr_f32
		DCComponentIds.I32:
			return slot.arr_i32
		DCComponentIds.U8:
			return slot.arr_u8
	return null


# ─── 内部工具 ───────────────────────────────────────────────────

func _slot_resize(slot: _Slot, n: int) -> void:
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


## 内部：取 _Slot（bind / view 等高级 API 用）。
func _get_slot(comp_id: int) -> _Slot:
	if comp_id < 0 or comp_id >= _slots.size():
		return null
	return _slots[comp_id]


## 内部：调试日志（World 注册规模等）。
func describe() -> Dictionary:
	return {
		"entity_count": _entity_count,
		"component_count": _slots.size(),
		"bound": _bound,
	}


# ─── Task 2 — ComponentView 访问器（hot loop 零拷贝） ───────────────────
#
# 所有 view_* API 都直接返回 _Slot 内部 PackedArray 引用，零拷贝；hot loop
# 在循环外取一次本地引用，循环内只走 `arr[i]` 索引。
#
# 注意：Godot 4 的 PackedArray 是 COW（copy-on-write）值类型。当 GDScript 把
# class member PackedArray 赋值到 local var 后，对 local var 的写仍能反向影响
# class member（因为 share 同一份内部 buffer），直到任一方 size 发生结构性
# 变化。这一约定对 hot loop 是透明的：调用方拿到 view 后只做 `arr[i] = x`，
# 不会触发结构性 COW，性能与 legacy 一致。

## 取 F32 component 主数组（hot loop 用）。
func view_f32(comp_id: int) -> PackedFloat32Array:
	var slot: _Slot = _get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_f32: invalid comp_id=%d" % comp_id)
		return PackedFloat32Array()
	if slot.dtype != DCComponentIds.F32 and slot.dtype != DCComponentIds.VEC2_F32 and slot.dtype != DCComponentIds.VEC3_F32:
		push_error("[DCWorld] view_f32: comp '%s' dtype=%s is not F32-compatible"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return PackedFloat32Array()
	return slot.arr_f32


## 取 F32 component 上一轮快照（要求 register 时 track_prev=true）。
func view_f32_prev(comp_id: int) -> PackedFloat32Array:
	var slot: _Slot = _get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_f32_prev: invalid comp_id=%d" % comp_id)
		return PackedFloat32Array()
	if not slot.track_prev:
		push_error("[DCWorld] view_f32_prev: comp '%s' was not registered with track_prev=true" % String(slot.name))
		return PackedFloat32Array()
	return slot.arr_f32_prev


## 取 I32 component 主数组。
func view_i32(comp_id: int) -> PackedInt32Array:
	var slot: _Slot = _get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_i32: invalid comp_id=%d" % comp_id)
		return PackedInt32Array()
	if slot.dtype != DCComponentIds.I32:
		push_error("[DCWorld] view_i32: comp '%s' dtype=%s is not I32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return PackedInt32Array()
	return slot.arr_i32


## 取 U8 component 主数组。
func view_u8(comp_id: int) -> PackedByteArray:
	var slot: _Slot = _get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_u8: invalid comp_id=%d" % comp_id)
		return PackedByteArray()
	if slot.dtype != DCComponentIds.U8:
		push_error("[DCWorld] view_u8: comp '%s' dtype=%s is not U8"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return PackedByteArray()
	return slot.arr_u8


# ─── Task 2.5 — Write API（DCWorldExt 等价路径） ──────────────────────
#
# 显式写回 API。DCWorld（GDScript）下 PackedArray 是 CoW 引用，原本用
# `view_f32(c)[i] = v` 也能写回；但 DCWorldExt（C++/GDExtension）下
# `view_*` 返回的是 Variant 拷贝，写不回内部 storage。为统一行为，所有
# hot-loop 的 *写* 路径必须经 write_* 走，view_* 视为只读快照。
#
# 性能：在 GDScript fallback 下额外多一次方法调用 + slot 查表（_get_slot），
# 单次开销 < 1us；调用方应在循环外缓存 comp_id，循环内直接调本方法。
# 真正热的成段写应使用 write_*_range（一次调用搬一段）。
#
# Dirty mask 联动（plan: cell-dirty-push-and-dots-atlas-bakers, 阶段 A）：
# 9 个 write_* API 在数据写入后调用 _dirty_mark_one/range/indexed；只对
# cells pool 段（[0, _dirty_cell_mask_size)）生效，其他 pool（front 池等）
# 因 idx 越界自动跳过。dirty_mask_enabled = false 或 mask_size = 0 时全 no-op。

const ENABLE_DIRTY_MARK_STACK_DIAG := false

# [DIAG mask_dirty=2400 排查 · 2026-05-20] 凶手抓现行：每次 mark 前 30 次
# 调用打印调用栈（含调用文件、函数、行号），定位"谁在每帧标 2400 dirty"。
# 默认关闭，避免 hot path 中的 get_stack() 成为性能瓶颈。
var _diag_mark_count: int = 0

func _diag_dump_caller(tag: String, n_marked: int) -> void:
	if _diag_mark_count >= 30:
		return
	_diag_mark_count += 1
	var stack = get_stack()
	# stack[0] 是 _diag_dump_caller 自己；stack[1] 是 _dirty_mark_*；
	# stack[2] 是 write_* API；stack[3] 才是真正的业务调用方。
	var caller_info: String = "<unknown>"
	if stack != null and stack.size() >= 4:
		var s = stack[3]
		caller_info = "%s:%d %s()" % [str(s.get("source", "?")), int(s.get("line", -1)), str(s.get("function", "?"))]
	elif stack != null and stack.size() >= 3:
		var s2 = stack[2]
		caller_info = "%s:%d %s()" % [str(s2.get("source", "?")), int(s2.get("line", -1)), str(s2.get("function", "?"))]
	print("[DIAG dirty_mark #%d] %s n=%d caller=%s" % [_diag_mark_count, tag, n_marked, caller_info])


# 内部：单点 mark（hot path 高频，inline-friendly）。
func _dirty_mark_one(idx: int) -> void:
	if not dirty_mask_enabled:
		return
	if idx >= 0 and idx < _dirty_cell_mask_size:
		_dirty_cell_mask[idx] = 1
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] 也许凶手是单点写
		# write_f32(idx, v)，前 30 次打调用栈定位（每个不同 caller 只打一次去重）
		if ENABLE_DIRTY_MARK_STACK_DIAG:
			_diag_dump_caller_one(idx)


# [DIAG] 单点 mark 调用栈去重打印：每个 (source, function) 组合只打一次，
# 避免单点循环 2400 次刷屏；总共最多打 30 个不同 caller。
var _diag_one_callers_seen: Dictionary = {}
var _diag_one_count: int = 0

func _diag_dump_caller_one(idx: int) -> void:
	if _diag_one_count >= 30:
		return
	var stack = get_stack()
	if stack == null or stack.size() < 3:
		return
	# stack[0]=_diag_dump_caller_one, stack[1]=_dirty_mark_one,
	# stack[2]=write_f32/u8/i32, stack[3]=业务 caller
	var key_info = stack[2] if stack.size() >= 3 else null
	var biz_info = stack[3] if stack.size() >= 4 else key_info
	if biz_info == null:
		return
	var src: String = str(biz_info.get("source", "?"))
	var fn: String = str(biz_info.get("function", "?"))
	var ln: int = int(biz_info.get("line", -1))
	var key: String = "%s::%s" % [src, fn]
	if _diag_one_callers_seen.has(key):
		return
	_diag_one_callers_seen[key] = true
	_diag_one_count += 1
	print("[DIAG dirty_mark_one #%d] idx=%d caller=%s:%d %s()" % [_diag_one_count, idx, src, ln, fn])


# 内部：成段 mark（[start, start+n) 全标）。
func _dirty_mark_range(start: int, n: int) -> void:
	if not dirty_mask_enabled or n <= 0 or _dirty_cell_mask_size <= 0:
		return
	var lo: int = maxi(start, 0)
	var hi: int = mini(start + n, _dirty_cell_mask_size)
	for i in range(lo, hi):
		_dirty_cell_mask[i] = 1
	if ENABLE_DIRTY_MARK_STACK_DIAG:
		_diag_dump_caller("range", hi - lo)


# 内部：批量索引 mark（dirty_indices 列表，越界元素自动跳过）。
func _dirty_mark_indexed(indices: PackedInt32Array) -> void:
	if not dirty_mask_enabled or _dirty_cell_mask_size <= 0:
		return
	var cap: int = _dirty_cell_mask_size
	var n: int = indices.size()
	for k in range(n):
		var idx: int = indices[k]
		if idx >= 0 and idx < cap:
			_dirty_cell_mask[idx] = 1
	if ENABLE_DIRTY_MARK_STACK_DIAG:
		_diag_dump_caller("indexed", n)


## 单元素写入：F32 component。
func write_f32(comp_id: int, idx: int, v: float) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	_dirty_mark_one(idx)


## 单元素写入：I32 component。
func write_i32(comp_id: int, idx: int, v: int) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	_dirty_mark_one(idx)


## 单元素写入：U8 component（int 入参，自动 & 0xFF 截断）。
func write_u8(comp_id: int, idx: int, v: int) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	_dirty_mark_one(idx)


## 成段写入：F32 component。把 src[0..src.size()) 写到 arr[start..start+src.size())。
func write_f32_range(comp_id: int, start: int, src: PackedFloat32Array) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	_dirty_mark_range(start, n)


## 成段写入：I32 component。
func write_i32_range(comp_id: int, start: int, src: PackedInt32Array) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	_dirty_mark_range(start, n)


## 成段写入：U8 component。
func write_u8_range(comp_id: int, start: int, src: PackedByteArray) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	_dirty_mark_range(start, n)


# ─── 批量索引写 API（PR-2.0，2026-Q3）─────────────────────────────────
# 用于 hot pass 写路径下移：收集 (dirty_indices, new_values) 后一次性提交，
# 避免 cell.field= / map.field_arr[i]= 的 CoW 漏写陷阱。
#
# 三大 API 的契约：
#   - indices.size() 与 values.size() 不一致时 → 取 min(size) 截断写入
#   - 单个 idx 越界 → 静默跳过（与 write_f32 单点不同；批量场景下 push_error 噪音过大）
#   - dtype 不匹配 → 整个调用 push_error 后 return（与 write_f32_range 一致）
#   - hot path 应在循环外 cache cid，循环内 collect dirty_indices + values，
#     循环出来后一次调用 write_*_indexed
#
# 性能：实测 N=2400 / dirty=full 单调用 < 0.5ms（纯 GDScript），可接受热路径使用。
# 真正 hot 的 pass（每 tick 全量写）若需更快可走 C++ 端的同名 pass。

## 批量索引写：F32 component。
## 把 values[k] 写到 arr[indices[k]]，k ∈ [0, min(indices.size(), values.size()))。
##
## [perf 2026-05-20 indexed-value-diff] 旧版无条件 _dirty_mark_indexed(indices)
##   导致 weather_system 每 tick commit 2400 idx → mask 全 1 → atlas_upload 全推。
##   现改为 value-diff：仅当 arr[idx] != values[k] 才写 + 标 dirty。
##   语义等价于 write_f32_dense 的 value-diff 行为。
func write_f32_indexed(comp_id: int, indices: PackedInt32Array, values: PackedFloat32Array) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	if dirty_mask_enabled and _dirty_cell_mask_size > 0:
		var mask_cap: int = _dirty_cell_mask_size
		for k in range(n):
			var idx: int = indices[k]
			if idx >= 0 and idx < cap:
				var v_new: float = values[k]
				if arr[idx] != v_new:
					arr[idx] = v_new
					if idx < mask_cap:
						_dirty_cell_mask[idx] = 1
	else:
		for k in range(n):
			var idx2: int = indices[k]
			if idx2 >= 0 and idx2 < cap:
				arr[idx2] = values[k]


## 批量索引写：I32 component。
## [perf 2026-05-20 indexed-value-diff] 同 write_f32_indexed。
func write_i32_indexed(comp_id: int, indices: PackedInt32Array, values: PackedInt32Array) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	if dirty_mask_enabled and _dirty_cell_mask_size > 0:
		var mask_cap: int = _dirty_cell_mask_size
		for k in range(n):
			var idx: int = indices[k]
			if idx >= 0 and idx < cap:
				var v_new: int = values[k]
				if arr[idx] != v_new:
					arr[idx] = v_new
					if idx < mask_cap:
						_dirty_cell_mask[idx] = 1
	else:
		for k in range(n):
			var idx2: int = indices[k]
			if idx2 >= 0 and idx2 < cap:
				arr[idx2] = values[k]


## 批量索引写：U8 component（int 入参，自动 & 0xFF 截断）。
## [perf 2026-05-20 indexed-value-diff] 同 write_f32_indexed。
func write_u8_indexed(comp_id: int, indices: PackedInt32Array, values: PackedByteArray) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	if dirty_mask_enabled and _dirty_cell_mask_size > 0:
		var mask_cap: int = _dirty_cell_mask_size
		for k in range(n):
			var idx: int = indices[k]
			if idx >= 0 and idx < cap:
				var v_new: int = values[k] & 0xFF
				if arr[idx] != v_new:
					arr[idx] = v_new
					if idx < mask_cap:
						_dirty_cell_mask[idx] = 1
	else:
		for k in range(n):
			var idx2: int = indices[k]
			if idx2 >= 0 and idx2 < cap:
				arr[idx2] = values[k] & 0xFF


# ─── Dense 批量写（plan: kill _dirty_mark_one storm, 2026-05-20） ────────────────
# 设计动机：
#   - `cell.X = v` 这种 facade setter 走 write_f32(cid, idx, v) 单点写 + 单点标 dirty，
#     若 hot pass 每帧给所有 cell 都赋值一遍 → _dirty_cell_mask 被标成全 1，
#     atlas_upload 退化为全推（21-24 ms/tick 大头）。
#   - 解决方案是 hot pass 把结果累积到 PackedFloat32Array，结尾一次性
#     `write_f32_dense(cid, values)`：写整段 + 一次性 mark dirty range，
#     避免 N 次单点 mark。
#   - dense API 假设 values.size() ≤ slot capacity；多余元素截断，少于则只写前 n 个。

## 批量整段写：F32 component。把 values[0..n) 写到 arr[0..n)，并标 dirty range。
func write_f32_dense(comp_id: int, values: PackedFloat32Array) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	if dirty_mask_enabled and _dirty_cell_mask_size > 0:
		var cap: int = _dirty_cell_mask_size
		for k in range(n):
			var v_new: float = values[k]
			if arr[k] != v_new:
				arr[k] = v_new
				if k < cap:
					_dirty_cell_mask[k] = 1
	else:
		for k in range(n):
			arr[k] = values[k]


## 批量整段写：I32 component。
func write_i32_dense(comp_id: int, values: PackedInt32Array) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	if dirty_mask_enabled and _dirty_cell_mask_size > 0:
		var cap: int = _dirty_cell_mask_size
		for k in range(n):
			var v_new: int = values[k]
			if arr[k] != v_new:
				arr[k] = v_new
				if k < cap:
					_dirty_cell_mask[k] = 1
	else:
		for k in range(n):
			arr[k] = values[k]


## 批量整段写：U8 component。values 是 PackedByteArray，会按需 & 0xFF。
func write_u8_dense(comp_id: int, values: PackedByteArray) -> void:
	var slot: _Slot = _get_slot(comp_id)
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
	if dirty_mask_enabled and _dirty_cell_mask_size > 0:
		var cap: int = _dirty_cell_mask_size
		for k in range(n):
			var v_new: int = values[k] & 0xFF
			if arr[k] != v_new:
				arr[k] = v_new
				if k < cap:
					_dirty_cell_mask[k] = 1
	else:
		for k in range(n):
			arr[k] = values[k] & 0xFF


# ─── Dirty mask public API（plan: cell-dirty-push-and-dots-atlas-bakers, A） ───

## 公开 API：手工标脏单 cell（外部直写场景兜底，例如 baker initialize 全脏）。
## idx 必须在 [0, cell_count) 内；越界静默跳过。dirty_mask_enabled = false 时 no-op。
func mark_dirty(idx: int) -> void:
	_dirty_mark_one(idx)


## 公开 API：成段标脏 [start, start+n)。多用于"刚 bind / regenerate 后强制全脏"。
func mark_dirty_range(start: int, n: int) -> void:
	_dirty_mark_range(start, n)


## 公开 API：批量索引标脏。多用于"sim Job 已经攒了 dirty_indices 但走自定义路径写"。
func mark_dirty_indexed(indices: PackedInt32Array) -> void:
	_dirty_mark_indexed(indices)


## 公开 API：把全脏标志强制设为全 1（首帧 baker bake_world / regenerate 用）。
func mark_dirty_all() -> void:
	if not dirty_mask_enabled or _dirty_cell_mask_size <= 0:
		return
	_dirty_cell_mask.fill(1)


## 清空 dirty mask 但不构造 index 数组。稠密 dirty 消费端会直接走 full encode，
## 这里用 PackedByteArray 的 native fill，避免 GDScript 双遍扫描 6400 个 cell。
func clear_dirty_mask() -> void:
	if _dirty_cell_mask_size <= 0:
		return
	_dirty_cell_mask.fill(0)


## 公开 API：原子地"读出当前所有 dirty cell 的 index 列表 + 把 mask 清零"。
##
## 返回 PackedInt32Array（升序，因遍历顺序保证）。
## SUS scheduler 是单线程串行，priority 序天然把 sim 写 Job 排在
## visual upload job 之前 → baker 入口调本方法即获得 tick 内
## "全部待消费 dirty"快照；之后 sim 再写下个 tick 的脏会重新累积。
##
## dirty_mask_enabled = false 或 mask_size = 0 时返回空数组（baker 应当退化到
## "all_cells 全扫"行为）。
func read_and_clear_dirty_mask() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if not dirty_mask_enabled or _dirty_cell_mask_size <= 0:
		return out
	# 首遍计数（避免 push_back 多次扩容）
	var cap: int = _dirty_cell_mask_size
	var cnt: int = 0
	for i in range(cap):
		if _dirty_cell_mask[i] != 0:
			cnt += 1
	if cnt == 0:
		return out
	out.resize(cnt)
	var w: int = 0
	for i in range(cap):
		if _dirty_cell_mask[i] != 0:
			out[w] = i
			w += 1
			_dirty_cell_mask[i] = 0
	return out


## 公开 API：诊断 / log 用，不清零。
func peek_dirty_count() -> int:
	if not dirty_mask_enabled or _dirty_cell_mask_size <= 0:
		return 0
	var cnt: int = 0
	for i in range(_dirty_cell_mask_size):
		if _dirty_cell_mask[i] != 0:
			cnt += 1
	return cnt


## 公开 API：dirty mask 当前覆盖的 cell 数（= cells pool capacity）。诊断用。
func dirty_mask_size() -> int:
	return _dirty_cell_mask_size


# 内部：bind_map_data / unbind 调用，使 mask 大小与 cells pool 同步。
func _resize_dirty_mask(new_size: int) -> void:
	if new_size < 0:
		new_size = 0
	_dirty_cell_mask_size = new_size
	_dirty_cell_mask.resize(new_size)
	# resize 后内容未定义，统一清 0
	for i in range(new_size):
		_dirty_cell_mask[i] = 0


## 单元素读取：F32 component。冷路径（UI / baker / test / debug print）使用；
## hot loop 应在循环外 `var arr := view_f32(cid)`，循环内直接 `arr[i]`。
## 越界 / dtype 不匹配返回 0.0 并 push_error。
func read_f32(comp_id: int, idx: int) -> float:
	var slot: _Slot = _get_slot(comp_id)
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
func read_i32(comp_id: int, idx: int) -> int:
	var slot: _Slot = _get_slot(comp_id)
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
func read_u8(comp_id: int, idx: int) -> int:
	var slot: _Slot = _get_slot(comp_id)
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
func read_bool(comp_id: int, idx: int) -> bool:
	return read_u8(comp_id, idx) > 0


## 单元素写入：bool → U8 component（true=1, false=0），对称 read_bool。
func write_bool(comp_id: int, idx: int, v: bool) -> void:
	write_u8(comp_id, idx, 1 if v else 0)


## 取 VEC2 component 拆轴视图：{ x: PackedFloat32Array, y: PackedFloat32Array }
func view_vec2(comp_id: int) -> Dictionary:
	var slot: _Slot = _get_slot(comp_id)
	if slot == null:
		push_error("[DCWorld] view_vec2: invalid comp_id=%d" % comp_id)
		return {}
	if slot.dtype != DCComponentIds.VEC2_F32:
		push_error("[DCWorld] view_vec2: comp '%s' dtype=%s is not VEC2_F32"
			% [String(slot.name), DCComponentIds.dtype_name(slot.dtype)])
		return {}
	return { "x": slot.arr_f32, "y": slot.arr_f32_y }


## 取 VEC2 component 上一轮快照拆轴视图。
func view_vec2_prev(comp_id: int) -> Dictionary:
	var slot: _Slot = _get_slot(comp_id)
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


# ─── Task 2 — 双缓冲 swap ───────────────────────────────────────────
#
# 设计：swap 只交换 _Slot 内部"当前 / prev"PackedArray 引用，O(1)，无内存拷贝。
# 由于 PackedArray 在 GDScript 里是值类型 (COW)，"swap 引用"在 GDScript 中通过
# 临时变量赋值实现：
#   var tmp = slot.arr_f32
#   slot.arr_f32 = slot.arr_f32_prev
#   slot.arr_f32_prev = tmp
# 这是 ref-count 级别的赋值，不触发底层 buffer 拷贝。
#
# 守卫：`_pending_passes > 0` 时禁止 swap，避免 sub-pass 中途切片下游读到半成品。
# 由 sub-pass 通过 begin_sub_pass() / end_sub_pass() 维护计数。

## sub-pass 开始（计数 +1，用于 swap 守卫）。
func begin_sub_pass() -> void:
	_pending_passes += 1


## sub-pass 结束（计数 -1）。负数视为编程错误。
func end_sub_pass() -> void:
	_pending_passes -= 1
	if _pending_passes < 0:
		push_error("[DCWorld] end_sub_pass: pending passes underflow (-> %d)" % _pending_passes)
		_pending_passes = 0


## 当前是否有 sub-pass 在飞。
func has_pending_pass() -> bool:
	return _pending_passes > 0


# ─── Phase C.2 / dots-migration-roadmap §3 A3：reads/writes 自动校验 hook ──
#
# DCSystemScheduler 在 system tick 前后调用 _debug_begin_pass / _debug_end_pass。
# 当前实现是"声明记录器"——把当前 pass 声明的 writes / reads 列表记下来，
# write_f32 / write_i32 / write_u8 / write_*_range / write_*_indexed 等写入
# API 在 debug 构建下校验目标 component 是否在声明的 writes 内。违约时
# push_error（不中止运行，避免 hot path 性能影响）。
#
# 当前 phase 仅记录 + 暴露 API；完整违约校验逻辑在 write_f32 等方法内
# 接入是 future iteration——本 hook 让 DCSystemScheduler 调用面已经稳定，
# 后续只需在写入函数中加一行 _debug_check_write(comp_id) 即可生效。
var _debug_pass_active: bool = false
var _debug_pass_writes: Array = []  # Array[StringName]
var _debug_pass_reads: Array = []   # Array[StringName]
var _debug_pass_id: StringName = &""


## 由调度器在 system tick 前调用。仅 debug 构建生效。
##  - writes: 本 pass 声明会写入的 component StringName 数组
##  - reads:  本 pass 声明会读取的 component StringName 数组
##  - pass_id: 调试日志用的 pass 名（system.id）
func _debug_begin_pass(writes: Array, reads: Array, pass_id: StringName = &"") -> void:
	if not _debug:
		return
	if _debug_pass_active:
		push_warning("[DCWorld] _debug_begin_pass: previous pass '%s' not closed; auto-closing" % String(_debug_pass_id))
	_debug_pass_active = true
	_debug_pass_writes = writes
	_debug_pass_reads = reads
	_debug_pass_id = pass_id


## 由调度器在 system tick 后调用。仅 debug 构建生效。
func _debug_end_pass(_pass_id: StringName = &"") -> void:
	if not _debug:
		return
	_debug_pass_active = false
	_debug_pass_writes = []
	_debug_pass_reads = []
	_debug_pass_id = &""


## 内部：write_* 入口可调本函数检查目标 component 是否已声明。当前未在
## write_* 内插入调用以避免 hot path 开销；future iteration 会按需接入。
func _debug_check_write(comp_id: int) -> void:
	if not _debug or not _debug_pass_active:
		return
	var slot: _Slot = _get_slot(comp_id)
	if slot == null:
		return
	if not _debug_pass_writes.has(slot.name):
		push_error("[DCWorld] write violation in pass '%s': component '%s' not in declare_writes %s"
			% [String(_debug_pass_id), String(slot.name), str(_debug_pass_writes)])


## O(1) 交换一组 component 的 _arr / _arr_prev 引用。
## 调用方必须保证所有 sub-pass 都已 end_sub_pass()，否则在 debug 构建 push_error 中止。
func swap_double_buffer(comp_ids: Array) -> void:
	if _pending_passes > 0:
		push_error("[DCWorld] swap_double_buffer: %d sub-pass still in flight, refusing to swap" % _pending_passes)
		return
	for cid in comp_ids:
		var slot: _Slot = _get_slot(int(cid))
		if slot == null:
			continue
		if not slot.track_prev:
			if _debug:
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
func commit_round(comp_ids: Array) -> void:
	swap_double_buffer(comp_ids)


# ─── Task 3 — Query 工厂（预分配池，避免 hot path 分配） ────────────────

# Query 池：World 内部维护若干 DCQuery 实例，query() 取一个、_release_query
# 归还。首版池大小 4 已够 weather sub-pass + climate + ocean 同时用；不够时
# 自动扩容，但日志 push_warning。
var _query_pool: Array = []           # Array[DCQuery]
var _query_in_use: Array = []         # Array[bool] —— 与 _query_pool 同 idx
const _QUERY_POOL_INITIAL: int = 4
const _QUERY_POOL_MAX: int = 32

func _ensure_query_pool() -> void:
	if _query_pool.size() == 0:
		for i in range(_QUERY_POOL_INITIAL):
			_query_pool.append(DCQuery.new())
			_query_in_use.append(false)


## 从池中取一个 query 实例并 reset 到初始状态。
## 调用方按链式 DSL 配置后调用 for_each_index；执行完 release_query() 归还。
func query() -> DCQuery:
	_ensure_query_pool()
	for i in range(_query_pool.size()):
		if not _query_in_use[i]:
			_query_in_use[i] = true
			var q: DCQuery = _query_pool[i]
			q._reset(self)
			return q
	# 池子用满了，扩容（罕见路径）
	if _query_pool.size() >= _QUERY_POOL_MAX:
		if _debug:
			push_warning("[DCWorld] query pool reached max=%d; allocating extra query (no pool)" % _QUERY_POOL_MAX)
		var qe: DCQuery = DCQuery.new()
		qe._reset(self)
		return qe
	var qq: DCQuery = DCQuery.new()
	_query_pool.append(qq)
	_query_in_use.append(true)
	qq._reset(self)
	return qq


## 把 query 归还池子。若 q 不在池中则忽略（兼容 max 之外临时分配的 query）。
func release_query(q: DCQuery) -> void:
	for i in range(_query_pool.size()):
		if _query_pool[i] == q:
			_query_in_use[i] = false
			return


# ─── Task 6 — Archetype 数据桩（query.with_archetype 依赖） ─────────────
# 完整的 create_archetype / assign_archetype API 在 Task 6 加入；这里仅声明
# entity_archetype 数组与访问器，让 query.with_archetype 能联调。
var _archetypes: Array = []                      # Array[Dictionary]：archetype 描述
var _archetype_by_name: Dictionary = {}          # StringName → arch_id
var _entity_archetype: PackedInt32Array = PackedInt32Array()
const _ARCH_NONE: int = -1


## 取 entity → archetype 映射数组（DCQuery 使用）。
## Task 6 之前可能尚未分配；此时返回空数组，DCQuery 自然跳过 archetype 过滤。
func entity_archetype_array() -> PackedInt32Array:
	return _entity_archetype


# ─── Task 4 — Topology + bind_map_data ───────────────────────────
#
# 目标：把 MapData 现有的 25 个 PackedArray "认领"为 component（按引用，零拷贝），
# 同时把 _neighbor_indices 注册成内置 HexNeighborTopology component。
#
# Godot 4 PackedArray COW 行为说明：把 MapData 的字段赋值给 _Slot.arr_f32 后，
# 双方共享同一份内部 buffer；只有 size 发生变化（resize / push_back）才会分裂。
# bind 完成后任意一方写 `arr[i]=x`（不改 size）对另一方都立即可见，满足"挂入"
# 语义。MapData.rebuild_soa_from_cells() 内部会重新 resize 所有 PackedArray，这
# 时必须调用 World.rebind_arrays() 重新刷新引用，否则 World 会持有旧 buffer。

# Topology 槽位（独立于 _slots，固定一个）。
var _topo_neighbors: PackedInt32Array = PackedInt32Array()  # 引用 MapData._neighbor_indices
var _topo_built: bool = false

# 内置 cell-level component id 映射表（bind 时填充）；供 weather_system / job 直接索引。
var _builtin_cell_ids: Dictionary = {}    # StringName → comp_id (int)


## 把 MapData 现有 SoA 字段注册成内置 component 并按引用挂入；同时挂入 topology。
##
## 调用时机：bake_world / regenerate / 加载存档完成后调用一次。MapData 必须
## 已构建完 _build_indices() + rebuild_soa_from_cells()。
##
## 参数 demo_thermal_gradient_enabled（performance-charter §12.6 参考实现）：
##   true  → 额外注册 CELL_DEMO_THERMAL_GRADIENT slot，并在挂入前将
##           map_data.demo_thermal_gradient_arr resize 到 N（補上必要的
##           存储）。
##   false → 跳过该 slot——demo 字段保持 size=0，不占内存，下游 C++ pass
##           调用时会看到 slot id < 0 并安全 no-op + push_warning（在未启用
##           的路径上不应被调用，main.gd 会他同一开关跳过调用）。
func bind_map_data(map_data, demo_thermal_gradient_enabled: bool = false) -> void:
	if map_data == null:
		push_error("[DCWorld] bind_map_data: map_data is null")
		return
	_map_data = map_data
	_bound = false
	# 1) 校验前置条件
	if not map_data.has_indices():
		push_error("[DCWorld] bind_map_data: MapData._build_indices() must be called first")
		return
	if not map_data.has_soa():
		push_error("[DCWorld] bind_map_data: MapData.rebuild_soa_from_cells() must be called first")
		return
	var n: int = map_data.cell_count()
	# 2) 自动注册 cells pool（I2.A.4）。如已存在则校验容量。
	#     首次 bind：_entity_count 暂设为 0，让 create_pool 内部以 start=0 注册，
	#                 然后 create_pool → create_entities(n) 会把 _entity_count 拉到 n。
	#     重复 bind：cells pool 已存在，跳过（容量校验通过即可）。
	var cells_pid: int = pool_id(DCComponentIds.POOL_CELLS)
	if cells_pid >= 0:
		var existing: Dictionary = _pools[cells_pid]
		if int(existing["start"]) != 0 or int(existing["count"]) != n:
			push_error("[DCWorld] bind_map_data: existing 'cells' pool [%d, +%d) != cell_count=%d"
				% [int(existing["start"]), int(existing["count"]), n])
			return
		# 重复 bind：保持 _entity_count = n（cells pool 已经占据 [0, n)）
		_entity_count = n
	else:
		# 首次 bind：清零再让 create_pool 以 start=0 注册
		_entity_count = 0
		create_pool(DCComponentIds.POOL_CELLS, n)
		# create_pool 已把 _entity_count 拉到 n（= 0 + capacity）
	# 3) 内置 cell component 注册 / 挂入（A1 / dots-migration-roadmap §3）
	#
	# 历史：本段曾是 38 行手写 `_bind_register_and_attach[_u8](...)`，每加
	# 一个新 cell 字段要改 6 处（component_ids.gd / map_data.gd 的 SoA 字段
	# / world.gd 这里 / job 的 _comp_cache / world_ext.cpp BIND_TABLE）。
	# 现在统一从 `DCComponentSchema.CELL_SCHEMA` 单一源派生：
	#   - GDScript 这一段从 schema 自动循环；
	#   - C++ 端 `gdext/src/component_bind_table.gen.h` 由 codegen 脚本
	#     `tools/codegen/gen_cpp_bind_table.py` 从同一份 schema 生成。
	# 加新字段：在 component_schema.gd 加一行 → 跑 codegen → rebuild gdext。
	# 详见 docs/dots-component-schema.md。
	#
	# Demo 条目（cell.demo.*）：仅在 demo_thermal_gradient_enabled=true 时
	# 才 attach；为 false 时跳过（slot 不注册 → C++ pass component_id() 返回
	# -1 → pass 内部安全 no-op）。开启时按 charter §12.6 约定先把 MapData
	# 对应字段 resize 到 n，避免下面的长度一致性校验报错。
	#
	# 启动期 sanity check：让 schema 错误（typo / 缺字段 / dtype 非法）
	# 在 bind 第一时间报出来，而不是 hot path 跑到一半静默失败。
	if _debug:
		var schema_err: String = DCComponentSchema.validate_all()
		if schema_err != "":
			push_error("[DCWorld] bind_map_data: schema invalid — %s" % schema_err)
			return
	for entry in DCComponentSchema.entries():
		var is_demo: bool = bool(entry.get("demo", false))
		if is_demo and not demo_thermal_gradient_enabled:
			continue
		var map_field: String = String(entry.map_field)
		# Demo 条目按需 resize（与原 717-721 行行为等价）
		if is_demo:
			var arr_now: Variant = map_data.get(map_field)
			if arr_now is PackedFloat32Array:
				var pf: PackedFloat32Array = arr_now
				if pf.size() != n:
					pf.resize(n)
					pf.fill(0.0)
					map_data.set(map_field, pf)
		var arr_v: Variant = map_data.get(map_field)
		if arr_v == null or typeof(arr_v) == TYPE_NIL:
			push_error("[DCWorld] bind_map_data: MapData.%s missing for component '%s'"
				% [map_field, String(entry.name)])
			return
		match int(entry.dtype):
			DCComponentIds.F32:
				if not (arr_v is PackedFloat32Array):
					push_error("[DCWorld] bind_map_data: MapData.%s expected PackedFloat32Array" % map_field)
					return
				var arr_f: PackedFloat32Array = arr_v
				var arr_prev_f: PackedFloat32Array = PackedFloat32Array()
				if bool(entry.get("track_prev", false)) and String(entry.prev_field) != "":
					var prev_v: Variant = map_data.get(String(entry.prev_field))
					if prev_v is PackedFloat32Array:
						arr_prev_f = prev_v
				_bind_register_and_attach(entry.name, DCComponentIds.F32,
					bool(entry.get("track_prev", false)), arr_f, arr_prev_f)
			DCComponentIds.U8:
				if not (arr_v is PackedByteArray):
					push_error("[DCWorld] bind_map_data: MapData.%s expected PackedByteArray" % map_field)
					return
				_bind_register_and_attach_u8(entry.name, arr_v)
			DCComponentIds.I32:
				# B3b：植被动力学 streak 字段（cell.vitality_low_streak /
				# cell.vitality_high_streak）走 I32 attach 路径。register_component
				# I32 路径 + view_i32 / write_i32 / write_i32_range / write_i32_indexed
				# 都已实装；这里补上"挂入 MapData PackedInt32Array 外部引用"步骤。
				if not (arr_v is PackedInt32Array):
					push_error("[DCWorld] bind_map_data: MapData.%s expected PackedInt32Array" % map_field)
					return
				_bind_register_and_attach_i32(entry.name, arr_v)
			_:
				push_error("[DCWorld] bind_map_data: unsupported dtype=%d for '%s'"
					% [int(entry.dtype), String(entry.name)])
				return
	# 4) 长度一致性校验
	for slot in _slots:
		if slot.external_ref:
			var sz: int = 0
			match slot.dtype:
				DCComponentIds.F32:
					sz = slot.arr_f32.size()
				DCComponentIds.I32:
					sz = slot.arr_i32.size()
				DCComponentIds.U8:
					sz = slot.arr_u8.size()
			if sz != n:
				push_error("[DCWorld] bind_map_data: comp '%s' size=%d != cell_count=%d"
					% [String(slot.name), sz, n])
				return
	# 5) Topology 挂入
	_topo_neighbors = map_data.neighbor_indices_packed()
	_topo_built = true
	# 6) Dirty mask 同步（plan: cell-dirty-push-and-dots-atlas-bakers, A）。
	#    mask 大小 = cells pool capacity = n_cells。重 bind 时强制清零（旧脏作废）。
	_resize_dirty_mask(n)
	_bound = true


## 重新绑定（MapData.rebuild_soa_from_cells 之后必须调用）。
## 仅刷新已挂入的 component 引用，不重新注册。
func rebind_arrays() -> void:
	if _map_data == null:
		push_error("[DCWorld] rebind_arrays: no map_data bound")
		return
	# 直接走 bind_map_data 全量重绑（注册幂等；引用刷新）
	bind_map_data(_map_data)


## 查询是否已 bind。
func is_bound() -> bool:
	return _bound


func is_external_component(comp_id: int) -> bool:
	var slot: _Slot = _get_slot(comp_id)
	return slot != null and slot.external_ref


## PR-4.4：解绑 MapData，让 hot-reload 路径可以"卸下当前世界 → 改 flag → 重 bind"。
##
## 解绑后所有 SoA 槽位的 external_ref 引用立刻清空（slot.arr_f32 = PackedFloat32Array()）；
## bind_map_data 重新调用时会重新挂入 MapData 的 PackedArray 引用。
##
## 注意：解绑会让所有 view_f32() 缓存的引用失效；caller 应在 unbind 后重新拿
## view_*。hot-loop 不应该跨 unbind/rebind 边界缓存数组引用。
##
## 用例：
##   1. 编辑器调试：开发者改 ClimateProfile.use_data_core_climate=true 后
##      DCFeatureFlags.flag_changed signal 触发 unbind → 改 flag → rebind。
##   2. 测试夹具：tests/<module>_soak_test 在 A/B phase 之间 unbind/rebind 重置状态。
##   3. 加载存档：load 之前先 unbind 旧 MapData，避免悬空引用。
func unbind_map_data() -> void:
	if not _bound:
		return
	# 把所有 external_ref slot 的 PackedArray 还原为空数组（断引用 +
	# 让下次 bind_map_data 走重新挂入路径）。
	for slot in _slots:
		if slot != null and slot.external_ref:
			slot.arr_f32 = PackedFloat32Array()
			slot.arr_f32_prev = PackedFloat32Array()
			slot.arr_f32_y = PackedFloat32Array()
			slot.arr_f32_y_prev = PackedFloat32Array()
			slot.arr_f32_z = PackedFloat32Array()
			slot.arr_f32_z_prev = PackedFloat32Array()
			slot.arr_i32 = PackedInt32Array()
			slot.arr_u8 = PackedByteArray()
			slot.external_ref = false
	_map_data = null
	_bound = false
	# Dirty mask 同步（plan: cell-dirty-push-and-dots-atlas-bakers, A）：
	# unbind 后 cell pool 失效，mask 一并释放，避免旧 mask 跨 bind 污染。
	_resize_dirty_mask(0)


## PR-4.4：rebind 别名，兼容 hot-reload 调用。等价于先 unbind 再 bind。
##
## 用例：编辑器开发者改 ClimateProfile.demo_thermal_gradient_enabled=true 时，
## 需要重 bind 让 DCWorld 注册新的 demo slot。原 bind_map_data 是幂等的，
## 但加 demo flag 切换不会再注册 demo slot；rebind_map_data 强制走全量重 bind。
##
## map_data：通常传 null（用之前的 _map_data，由 unbind 之前 cache 的）；
##           或 caller 显式传新 MapData（regenerate / load_save 路径）。
func rebind_map_data(map_data = null, demo_thermal_gradient_enabled: bool = false) -> void:
	var target = map_data if map_data != null else _map_data
	if target == null:
		push_error("[DCWorld] rebind_map_data: no map_data provided and no cached _map_data")
		return
	unbind_map_data()
	bind_map_data(target, demo_thermal_gradient_enabled)


## 获取邻居拓扑（hex-grid）。
##  - neighbor_index(idx, dir): 返回邻居 idx（无邻居返回 -1）
##  - neighbors_packed(): 返回底层 PackedInt32Array (size = cell_count*6)
func topology_neighbor_index(idx: int, dir: int) -> int:
	if not _topo_built:
		push_error("[DCWorld] topology not built; call bind_map_data first")
		return -1
	if idx < 0 or dir < 0 or dir > 5:
		return -1
	var base: int = idx * 6 + dir
	if base >= _topo_neighbors.size():
		return -1
	return _topo_neighbors[base]


func topology_neighbors_packed() -> PackedInt32Array:
	if not _topo_built:
		push_error("[DCWorld] topology not built; call bind_map_data first")
		return PackedInt32Array()
	return _topo_neighbors


## 内部：注册 cell-level F32 component 并挂入引用（重复调用幂等）。
func _bind_register_and_attach(name: StringName, dtype: int, track_prev: bool,
		arr_ref: PackedFloat32Array, arr_prev_ref: PackedFloat32Array = PackedFloat32Array()) -> void:
	var cid: int
	if _slot_by_name.has(name):
		cid = int(_slot_by_name[name])
	else:
		cid = register_component(name, dtype, 1, track_prev)
		_builtin_cell_ids[name] = cid
	if cid < 0:
		return
	var slot: _Slot = _slots[cid]
	slot.external_ref = true
	slot.arr_f32 = arr_ref
	if track_prev and arr_prev_ref.size() > 0:
		slot.arr_f32_prev = arr_prev_ref


## 内部：注册 cell-level U8 component 并挂入引用。
func _bind_register_and_attach_u8(name: StringName, arr_ref: PackedByteArray) -> void:
	var cid: int
	if _slot_by_name.has(name):
		cid = int(_slot_by_name[name])
	else:
		cid = register_component(name, DCComponentIds.U8, 1, false)
		_builtin_cell_ids[name] = cid
	if cid < 0:
		return
	var slot: _Slot = _slots[cid]
	slot.external_ref = true
	slot.arr_u8 = arr_ref


## 内部：注册 cell-level I32 component 并挂入引用（B3b：植被动力学 streak 用）。
## I32 不支持 track_prev（与 U8 一致；首版不双缓冲，见 _Slot 字段说明）。
func _bind_register_and_attach_i32(name: StringName, arr_ref: PackedInt32Array) -> void:
	var cid: int
	if _slot_by_name.has(name):
		cid = int(_slot_by_name[name])
	else:
		cid = register_component(name, DCComponentIds.I32, 1, false)
		_builtin_cell_ids[name] = cid
	if cid < 0:
		return
	var slot: _Slot = _slots[cid]
	slot.external_ref = true
	slot.arr_i32 = arr_ref


## 便捷：通过 StringName 直接拿内置 cell component 的 comp_id。
func builtin_cell(name: StringName) -> int:
	return int(_builtin_cell_ids.get(name, -1))


# ─── Task 5 — CommandBuffer 单例工厂 ──────────────────────────────
#
# 首版策略：World 持有一个全局 CommandBuffer 实例（按需分配），调用方通过
# command_buffer() 取出累积指令；调度器在 round 末调用 flush_command_buffer()。
# 单线程串行使用即可，无需多 buffer。

var _cmd_buffer: DCCommandBuffer = null

func command_buffer() -> DCCommandBuffer:
	if _cmd_buffer == null:
		_cmd_buffer = DCCommandBuffer.new(self)
	return _cmd_buffer


func flush_command_buffer() -> void:
	if _cmd_buffer == null:
		return
	_cmd_buffer.flush()


# ─── Task 6 — Archetype 完整 API ─────────────────────────────────
#
# 首版（weather 迁移阶段）只做"逻辑分组" —— 维护 entity_archetype: PackedInt32Array
# 标记位，query.with_archetype(arch_id) 在遍历时按位过滤。不做物理重排
# （enable_archetype_sorting 仅暴露 API，未来阶段再实现）。
#
# Front 池设计：weather front 不是 cell；它们是 entity_count 之外的"扩展 entity"。
# 首版做法是把 front 池也分配到同一个全局 entity 池里 —— 当 weather 启动时
# 调用 world.create_entities(cell_count + max_front_count)，front 占用 [cell_count,
# cell_count + max_front_count) 段。此举把"双 entity 池"的复杂度藏到调用方
# （weather_system 决定 front_capacity）；World 仍是统一的扁平 ID 空间。

var enable_archetype_sorting: bool = false  # 物理重排开关（首版不实现）


## 创建 archetype，返回 arch_id (int)。
## comp_ids 仅作记录；首版不做"必须 entity 拥有这些 component"强校验。
func create_archetype(name: StringName, comp_ids: Array = []) -> int:
	if _archetype_by_name.has(name):
		return int(_archetype_by_name[name])
	var arch_id: int = _archetypes.size()
	_archetypes.append({ "name": name, "comp_ids": comp_ids })
	_archetype_by_name[name] = arch_id
	# 确保 _entity_archetype 长度 = entity_count，初值 _ARCH_NONE
	if _entity_archetype.size() < _entity_count:
		var old_size: int = _entity_archetype.size()
		_entity_archetype.resize(_entity_count)
		for i in range(old_size, _entity_count):
			_entity_archetype[i] = _ARCH_NONE
	return arch_id


## 把 entity 分配到 archetype。idx 越界时自动扩容 _entity_archetype。
func assign_archetype(idx: int, arch_id: int) -> void:
	if idx < 0:
		return
	if idx >= _entity_archetype.size():
		var old: int = _entity_archetype.size()
		_entity_archetype.resize(idx + 1)
		for i in range(old, idx + 1):
			_entity_archetype[i] = _ARCH_NONE
	_entity_archetype[idx] = arch_id


## 取 entity 当前 archetype id；未赋值返回 _ARCH_NONE。
func get_archetype(idx: int) -> int:
	if idx < 0 or idx >= _entity_archetype.size():
		return _ARCH_NONE
	return _entity_archetype[idx]


## archetype "无 / 无效"标记。
func archetype_none() -> int:
	return _ARCH_NONE


## archetype 数量。
func archetype_count() -> int:
	return _archetypes.size()


## archetype 名 → id；不存在返回 -1。
func archetype_id(name: StringName) -> int:
	return int(_archetype_by_name.get(name, -1))


# ─── Task 7 — 多 Pool API（I2.A） ────────────────────────────────
#
# 目的：把"约定式 idx 段"升级为"显式 pool 注册"。所有子系统通过 pool_id
# 声明自己的 entity 范围，Query 用 in_pool(pool_id) 过滤遍历。
#
# 实施背景：在 I2.A 之前，weather front 池是"约定式"占用 [cell_n, cell_n+16)
# —— weather_refresh_job 写死偏移，未来加第三个 pool（unit/army/economy）
# 必须修 weather_refresh_job，违反开闭原则。本段把 pool 抽象成一等公民。
#
# 数据结构约束：
#   - _pools 严格按 create 顺序记录，pool 之间无空洞
#   - 第 N 个 pool 的 start = 前 N-1 个 pool 的 (start + count) 之和
#   - 删除 pool 不在本 plan 范围（destroy_pool 暂不实现）
#
# 与 GDExtension 同形：本段 API 形状与上游 dots-roadmap-to-gdextension 计划
# 中 DCWorldExt::create_pool / pool_range 一致，I3.A 阶段 C++ 镜像零返工。

var _pools: Array = []                          # Array[Dictionary]：{ name, start, count }
var _pool_by_name: Dictionary = {}              # StringName → pool_id (int)
# 每个 pool 的 free-list（栈式 LIFO），元素是绝对 entity idx。pool_id 与 _pools 同 idx。
# I2.A.5：ECB pool-aware create/destroy 通过 _pool_alloc/_pool_free 借还 idx；
# free-list 是 pool 内"空闲槽"的真值持有者。
var _pool_free_lists: Array = []                # Array[PackedInt32Array]


## 注册一个 pool，返回 pool_id (int)。
##  - 同名 pool 已存在视为幂等，直接返回既有 id；容量不一致时 push_warning。
##  - 新 pool 的 start = 当前 _entity_count；自动把 _entity_count 拉伸到
##    start + capacity，并对所有已注册 component 同步 resize（external_ref
##    槽位不动，由 bind_map_data 自行管理）。
##  - I2.A.5：同时初始化该 pool 的 free-list（全部空闲）并把段内所有
##    entity 的 archetype 预置为 _ARCH_NONE，让"未分配"与"已 destroy"语义统一。
func create_pool(name: StringName, capacity: int) -> int:
	if capacity < 0:
		push_error("[DCWorld] create_pool '%s': capacity must be >= 0, got %d"
			% [String(name), capacity])
		return -1
	if _pool_by_name.has(name):
		var existing_id: int = int(_pool_by_name[name])
		var existing: Dictionary = _pools[existing_id]
		if int(existing["count"]) != capacity:
			push_warning("[DCWorld] create_pool '%s': existing capacity=%d != requested=%d, returning existing id"
				% [String(name), int(existing["count"]), capacity])
		return existing_id
	var start: int = _entity_count
	var pool_id_new: int = _pools.size()
	_pools.append({ "name": name, "start": start, "count": capacity })
	_pool_by_name[name] = pool_id_new
	# 拉伸 entity_count 并同步 component 槽位（create_entities 内部跳过 external_ref）
	create_entities(start + capacity)
	# 初始化 free-list（栈式 LIFO，pop_back 取最高 idx；高位先消耗、低位后消耗，
	# 与扁平池约定无关，只要顺序自洽即可）。
	var fl: PackedInt32Array = PackedInt32Array()
	fl.resize(capacity)
	for i in range(capacity):
		fl[i] = start + i
	_pool_free_lists.append(fl)
	# 把段内所有 entity 的 archetype 预置为 ARCH_NONE。
	# 注意：cells pool 调用此函数时 _entity_archetype 可能尚为空（archetype
	# 数组按需扩容）；这里走 assign_archetype 触发首次扩容是安全且廉价的。
	var arch_none: int = _ARCH_NONE
	for j in range(start, start + capacity):
		assign_archetype(j, arch_none)
	return pool_id_new


## I2.A.5：从指定 pool 的 free-list 借用一个 entity idx；池满返回 -1。
## 仅供 ECB / 框架内部调用，业务代码不要直接调。
func _pool_alloc(pid: int) -> int:
	if pid < 0 or pid >= _pool_free_lists.size():
		push_error("[DCWorld] _pool_alloc: invalid pool_id=%d" % pid)
		return -1
	var fl: PackedInt32Array = _pool_free_lists[pid]
	var sz: int = fl.size()
	if sz == 0:
		return -1
	var idx: int = fl[sz - 1]
	fl.resize(sz - 1)
	_pool_free_lists[pid] = fl  # COW 写回
	return idx


## I2.A.5：把 idx 归还指定 pool 的 free-list。
## 调用方应保证 idx 确实属于该 pool 的范围；首版不做去重校验（debug 下校验）。
func _pool_free(pid: int, idx: int) -> void:
	if pid < 0 or pid >= _pool_free_lists.size():
		push_error("[DCWorld] _pool_free: invalid pool_id=%d" % pid)
		return
	if _debug:
		var p: Dictionary = _pools[pid]
		var s: int = int(p["start"])
		var c: int = int(p["count"])
		if idx < s or idx >= s + c:
			push_error("[DCWorld] _pool_free: idx=%d out of pool '%s' range [%d, %d)"
				% [idx, String(p["name"]), s, s + c])
			return
	var fl: PackedInt32Array = _pool_free_lists[pid]
	fl.append(idx)
	_pool_free_lists[pid] = fl  # COW 写回


## I2.A.5：当前 pool 内剩余可分配槽位数（debug 用）。
func pool_free_count(pid: int) -> int:
	if pid < 0 or pid >= _pool_free_lists.size():
		return 0
	return _pool_free_lists[pid].size()


## 取 pool 的 [start, end) 范围。非法 pool_id 返回 Vector2i(-1, -1)。
func pool_range(pid: int) -> Vector2i:
	if pid < 0 or pid >= _pools.size():
		push_error("[DCWorld] pool_range: invalid pool_id=%d" % pid)
		return Vector2i(-1, -1)
	var p: Dictionary = _pools[pid]
	var s: int = int(p["start"])
	var c: int = int(p["count"])
	return Vector2i(s, s + c)


## 取 pool 名 → pool_id；不存在返回 -1。
func pool_id(name: StringName) -> int:
	return int(_pool_by_name.get(name, -1))


## 当前 pool 总数。
func pool_count() -> int:
	return _pools.size()


# ─── Phase 4.1：序列化 / 反序列化 API（dots-phase4-followup.md §4.1）─────
#
# 当前实现：**骨架阶段**——按 component_schema.gd CELL_SCHEMA 自动遍历
# 生产 cell 字段，把每个 SoA 拷贝到 Dictionary（serialize），或反向写回（deserialize）。
# fronts 序列化在 Phase 1.2 SoA 化升权威之后扩展（当前 _serialize_fronts 返回空 dict）。
#
# 调用语义：
#   - serialize() 在游戏暂停期 / 季节末调用，开销随生产字段数 × n_cells 线性增长
#   - deserialize(d) 在 load 时调用，要求当前已 bind_map_data 到 *相同 size* 的 MapData
#     （否则 size 不匹配直接 push_error）
#   - version 字段触发 schema migration 钩子（Phase 4.2）。

const SAVE_VERSION: int = 1


## 把 DCWorld 当前的全部 SoA 状态打包成 Dictionary，供存档系统持久化到磁盘。
##
## 输出结构：
##   {
##     "version": int (= SAVE_VERSION),
##     "n_cells": int,
##     "n_fronts": int,
##     "cells": Dictionary { cpp_name: PackedArray },  # 生产字段（demo 跳过）
##     "fronts": Dictionary,                            # Phase 4.1 PR-4.1.2 后扩展
##   }
##
## 注意：返回的 PackedArray 是 view_*() 的拷贝（CoW，下次 mutation 各自独立）。
##       caller 可以直接 var_to_bytes 写入文件。
func serialize() -> Dictionary:
	var out: Dictionary = {
		"version": SAVE_VERSION,
		"n_cells": _entity_count if _entity_count > 0 else (_slots[0].arr_f32.size() if _slots.size() > 0 else 0),
		"n_fronts": 0,
		"cells": _serialize_cells_dict(),
		"fronts": _serialize_fronts_dict(),
	}
	return out


## 把序列化的 Dictionary 反向写回 DCWorld 的 SoA。
##
## 流程：
##   1. 读 version；若低于 SAVE_VERSION，调用 schema migration（Phase 4.2 实装）
##   2. 验证 n_cells 与当前 _entity_count 一致（否则 push_error）
##   3. 遍历 CELL_SCHEMA，按 cpp_name 从 d["cells"] 读 PackedArray，写入对应 _slots
##   4. fronts 反序列化（Phase 4.1 PR-4.1.2 后实装）
##
## 失败时不抛异常，仅 push_error；caller 应自行检查游戏状态。
func deserialize(d: Dictionary) -> void:
	var v: int = int(d.get("version", 0))
	if v < SAVE_VERSION:
		# Phase 4.2 schema migration 钩子（暂未实装）：
		# d = DCSchemaMigrations.migrate(d, v, SAVE_VERSION)
		push_warning("[DCWorld] deserialize: save version=%d < current=%d; schema migration not yet implemented (Phase 4.2)" % [v, SAVE_VERSION])
	var n_save: int = int(d.get("n_cells", -1))
	if n_save < 0:
		push_error("[DCWorld] deserialize: n_cells missing")
		return
	if n_save != _entity_count:
		push_error("[DCWorld] deserialize: n_cells mismatch (save=%d, current=%d) — re-bind to matching MapData first" % [n_save, _entity_count])
		return
	_deserialize_cells_dict(d.get("cells", {}))
	_deserialize_fronts_dict(d.get("fronts", {}))


# ─── private serialize helpers ───────────────────────────────────────

func _serialize_cells_dict() -> Dictionary:
	var out: Dictionary = {}
	# 按 component_schema.gd 自动遍历 production entries（跳过 demo 字段）。
	for e in DCComponentSchema.entries_production():
		var cpp_name: String = String(e.cpp_name)
		var cid: int = component_id(e.name)
		if cid < 0:
			continue
		var dt: int = int(e.dtype)
		match dt:
			DCComponentIds.F32:
				out[cpp_name] = view_f32(cid)
			DCComponentIds.I32:
				out[cpp_name] = view_i32(cid)
			DCComponentIds.U8:
				out[cpp_name] = view_u8(cid)
			_:
				push_warning("[DCWorld] serialize: unknown dtype=%d for %s — skipped" % [dt, cpp_name])
	return out


func _deserialize_cells_dict(cells: Dictionary) -> void:
	for e in DCComponentSchema.entries_production():
		var cpp_name: String = String(e.cpp_name)
		if not cells.has(cpp_name):
			continue
		var cid: int = component_id(e.name)
		if cid < 0:
			continue
		var dt: int = int(e.dtype)
		match dt:
			DCComponentIds.F32:
				var f32: PackedFloat32Array = cells[cpp_name]
				if f32.size() == _entity_count:
					write_f32_range(cid, 0, f32)
			DCComponentIds.I32:
				var i32: PackedInt32Array = cells[cpp_name]
				if i32.size() == _entity_count:
					write_i32_range(cid, 0, i32)
			DCComponentIds.U8:
				var u8: PackedByteArray = cells[cpp_name]
				if u8.size() == _entity_count:
					write_u8_range(cid, 0, u8)


func _serialize_fronts_dict() -> Dictionary:
	# Phase 4.1 PR-4.1.2 后扩展：caller 通过 WeatherFront.pack_into_dict 提供
	# 当前 _active_fronts 的 batch dict；DCWorld 把它合并进存档。
	# 当前 phase（仅骨架）：返回空 dict。
	return {}


func _deserialize_fronts_dict(_d: Dictionary) -> void:
	# Phase 4.1 PR-4.1.2 后扩展。
	pass
