extends RefCounted
class_name DCWorld
const StateArchive = preload("res://scripts/data_core/world_state_archive.gd")
const PassLifecycle = preload("res://scripts/data_core/world_pass_lifecycle.gd")
const ComponentRegistry = preload("res://scripts/data_core/world_component_registry.gd")
const QueryPool = preload("res://scripts/data_core/world_query_pool.gd")
const ComponentReads = preload("res://scripts/data_core/world_component_reads.gd")
const EntityPools = preload("res://scripts/data_core/world_entity_pools.gd")
const Archetypes = preload("res://scripts/data_core/world_archetypes.gd")
const MapBinding = preload("res://scripts/data_core/world_map_binding.gd")
const ComponentWrites = preload("res://scripts/data_core/world_component_writes.gd")

const WorldArchiveHelpers = preload("res://scripts/data_core/world_archive_helpers.gd")

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
const _Slot = preload("res://scripts/data_core/world_component_slot.gd")


var _slots: Array = []                         # Array[_Slot]
var _slot_by_name: Dictionary = {}             # StringName → comp_id (int)
var _entity_count: int = 0

# Bind 状态（Task 4 完整接入；首版仅占位）
var _map_data_ref: WeakRef
# MapData owns HexCells, which retain this world. Do not close that cycle.
var _map_data:
	get:
		return _map_data_ref.get_ref() if _map_data_ref != null else null
	set(value):
		_map_data_ref = weakref(value) if value != null else null
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

func register_component(name: StringName, dtype: int, stride: int = 1, track_prev: bool = false) -> int:
	return ComponentRegistry.register_component(self, name, dtype, stride, track_prev)


## 通过 StringName 查询 comp_id；不存在返回 -1。
func component_id(name: StringName) -> int:
	return int(_slot_by_name.get(name, -1))


## 当前已注册 component 数量。
func component_count() -> int:
	return _slots.size()


## 当前 entity 总数。
func entity_count() -> int:
	return _entity_count


func create_entities(count: int) -> void:
	ComponentRegistry.create_entities(self, count)


func resize_all(new_count: int) -> void:
	ComponentRegistry.resize_all(self, new_count)


func get_component_array(comp_id: int):
	return ComponentRegistry.get_component_array(self, comp_id)


# ─── 内部工具 ───────────────────────────────────────────────────

func _slot_resize(slot: _Slot, n: int) -> void:
	ComponentRegistry._slot_resize(self, slot, n)


## 内部：取 _Slot（bind / view 等高级 API 用）。
func _get_slot(comp_id: int) -> _Slot:
	if comp_id < 0 or comp_id >= _slots.size():
		return null
	return _slots[comp_id]


func describe() -> Dictionary:
	return ComponentRegistry.describe(self)


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

func view_f32(comp_id: int) -> PackedFloat32Array:
	return ComponentReads.view_f32(self, comp_id)


func view_f32_prev(comp_id: int) -> PackedFloat32Array:
	return ComponentReads.view_f32_prev(self, comp_id)


func view_i32(comp_id: int) -> PackedInt32Array:
	return ComponentReads.view_i32(self, comp_id)


func view_u8(comp_id: int) -> PackedByteArray:
	return ComponentReads.view_u8(self, comp_id)


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


func _dirty_mark_one(idx: int) -> void:
	ComponentWrites._dirty_mark_one(self, idx)


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


func _dirty_mark_range(start: int, n: int) -> void:
	ComponentWrites._dirty_mark_range(self, start, n)


func _dirty_mark_indexed(indices: PackedInt32Array) -> void:
	ComponentWrites._dirty_mark_indexed(self, indices)


func write_f32(comp_id: int, idx: int, v: float) -> void:
	ComponentWrites.write_f32(self, comp_id, idx, v)


func write_i32(comp_id: int, idx: int, v: int) -> void:
	ComponentWrites.write_i32(self, comp_id, idx, v)


func write_u8(comp_id: int, idx: int, v: int) -> void:
	ComponentWrites.write_u8(self, comp_id, idx, v)


func write_f32_range(comp_id: int, start: int, src: PackedFloat32Array) -> void:
	ComponentWrites.write_f32_range(self, comp_id, start, src)


func write_i32_range(comp_id: int, start: int, src: PackedInt32Array) -> void:
	ComponentWrites.write_i32_range(self, comp_id, start, src)


func write_u8_range(comp_id: int, start: int, src: PackedByteArray) -> void:
	ComponentWrites.write_u8_range(self, comp_id, start, src)


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

func write_f32_indexed(comp_id: int, indices: PackedInt32Array, values: PackedFloat32Array) -> void:
	ComponentWrites.write_f32_indexed(self, comp_id, indices, values)


func write_i32_indexed(comp_id: int, indices: PackedInt32Array, values: PackedInt32Array) -> void:
	ComponentWrites.write_i32_indexed(self, comp_id, indices, values)


func write_u8_indexed(comp_id: int, indices: PackedInt32Array, values: PackedByteArray) -> void:
	ComponentWrites.write_u8_indexed(self, comp_id, indices, values)


# ─── Dense 批量写（plan: kill _dirty_mark_one storm, 2026-05-20） ────────────────
# 设计动机：
#   - `cell.X = v` 这种 facade setter 走 write_f32(cid, idx, v) 单点写 + 单点标 dirty，
#     若 hot pass 每帧给所有 cell 都赋值一遍 → _dirty_cell_mask 被标成全 1，
#     atlas_upload 退化为全推（21-24 ms/tick 大头）。
#   - 解决方案是 hot pass 把结果累积到 PackedFloat32Array，结尾一次性
#     `write_f32_dense(cid, values)`：写整段 + 一次性 mark dirty range，
#     避免 N 次单点 mark。
#   - dense API 假设 values.size() ≤ slot capacity；多余元素截断，少于则只写前 n 个。

func write_f32_dense(comp_id: int, values: PackedFloat32Array) -> void:
	ComponentWrites.write_f32_dense(self, comp_id, values)


func write_i32_dense(comp_id: int, values: PackedInt32Array) -> void:
	ComponentWrites.write_i32_dense(self, comp_id, values)


func write_u8_dense(comp_id: int, values: PackedByteArray) -> void:
	ComponentWrites.write_u8_dense(self, comp_id, values)


# ─── Dirty mask public API（plan: cell-dirty-push-and-dots-atlas-bakers, A） ───

func mark_dirty(idx: int) -> void:
	ComponentWrites.mark_dirty(self, idx)


func mark_dirty_range(start: int, n: int) -> void:
	ComponentWrites.mark_dirty_range(self, start, n)


func mark_dirty_indexed(indices: PackedInt32Array) -> void:
	ComponentWrites.mark_dirty_indexed(self, indices)


func mark_dirty_all() -> void:
	ComponentWrites.mark_dirty_all(self)


func clear_dirty_mask() -> void:
	ComponentWrites.clear_dirty_mask(self)


func read_and_clear_dirty_mask() -> PackedInt32Array:
	return ComponentWrites.read_and_clear_dirty_mask(self)


func peek_dirty_count() -> int:
	return ComponentWrites.peek_dirty_count(self)


func dirty_mask_size() -> int:
	return ComponentWrites.dirty_mask_size(self)


func _resize_dirty_mask(new_size: int) -> void:
	ComponentWrites._resize_dirty_mask(self, new_size)


func read_f32(comp_id: int, idx: int) -> float:
	return ComponentReads.read_f32(self, comp_id, idx)


func read_i32(comp_id: int, idx: int) -> int:
	return ComponentReads.read_i32(self, comp_id, idx)


func read_u8(comp_id: int, idx: int) -> int:
	return ComponentReads.read_u8(self, comp_id, idx)


func read_bool(comp_id: int, idx: int) -> bool:
	return ComponentReads.read_bool(self, comp_id, idx)


## 单元素写入：bool → U8 component（true=1, false=0），对称 read_bool。
func write_bool(comp_id: int, idx: int, v: bool) -> void:
	write_u8(comp_id, idx, 1 if v else 0)


func view_vec2(comp_id: int) -> Dictionary:
	return ComponentReads.view_vec2(self, comp_id)


func view_vec2_prev(comp_id: int) -> Dictionary:
	return ComponentReads.view_vec2_prev(self, comp_id)


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

func begin_sub_pass() -> void:
	PassLifecycle.begin_sub_pass(self)


func end_sub_pass() -> void:
	PassLifecycle.end_sub_pass(self)


func has_pending_pass() -> bool:
	return PassLifecycle.has_pending_pass(self)


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


func _debug_begin_pass(writes: Array, reads: Array, pass_id: StringName = &"") -> void:
	PassLifecycle._debug_begin_pass(self, writes, reads, pass_id)


func _debug_end_pass(_pass_id: StringName = &"") -> void:
	PassLifecycle._debug_end_pass(self, _pass_id)


func _debug_check_write(comp_id: int) -> void:
	PassLifecycle._debug_check_write(self, comp_id)


func swap_double_buffer(comp_ids: Array) -> void:
	PassLifecycle.swap_double_buffer(self, comp_ids)


func commit_round(comp_ids: Array) -> void:
	PassLifecycle.commit_round(self, comp_ids)


# ─── Task 3 — Query 工厂（预分配池，避免 hot path 分配） ────────────────

# Query 池：World 内部维护若干 DCQuery 实例，query() 取一个、_release_query
# 归还。首版池大小 4 已够 weather sub-pass + climate + ocean 同时用；不够时
# 自动扩容，但日志 push_warning。
var _query_pool: Array = []           # Array[DCQuery]
var _query_in_use: Array = []         # Array[bool] —— 与 _query_pool 同 idx
const _QUERY_POOL_INITIAL: int = 4
const _QUERY_POOL_MAX: int = 32

func _ensure_query_pool() -> void:
	QueryPool._ensure_query_pool(self)


func query() -> DCQuery:
	return QueryPool.query(self)


func release_query(q: DCQuery) -> void:
	QueryPool.release_query(self, q)


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


func bind_map_data(map_data, demo_thermal_gradient_enabled: bool = false) -> void:
	MapBinding.bind_map_data(self, map_data, demo_thermal_gradient_enabled)


func rebind_arrays() -> void:
	MapBinding.rebind_arrays(self)


func is_bound() -> bool:
	return MapBinding.is_bound(self)


func is_external_component(comp_id: int) -> bool:
	return MapBinding.is_external_component(self, comp_id)


func unbind_map_data() -> void:
	MapBinding.unbind_map_data(self)


func rebind_map_data(map_data = null, demo_thermal_gradient_enabled: bool = false) -> void:
	MapBinding.rebind_map_data(self, map_data, demo_thermal_gradient_enabled)


func topology_neighbor_index(idx: int, dir: int) -> int:
	return MapBinding.topology_neighbor_index(self, idx, dir)


func topology_neighbors_packed() -> PackedInt32Array:
	return MapBinding.topology_neighbors_packed(self)


func _bind_register_and_attach(name: StringName, dtype: int, track_prev: bool,
		arr_ref: PackedFloat32Array, arr_prev_ref: PackedFloat32Array = PackedFloat32Array()) -> void:
	MapBinding._bind_register_and_attach(self, name, dtype, track_prev, arr_ref, arr_prev_ref)


func _bind_register_and_attach_u8(name: StringName, arr_ref: PackedByteArray) -> void:
	MapBinding._bind_register_and_attach_u8(self, name, arr_ref)


func _bind_register_and_attach_i32(name: StringName, arr_ref: PackedInt32Array) -> void:
	MapBinding._bind_register_and_attach_i32(self, name, arr_ref)


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


func create_archetype(name: StringName, comp_ids: Array = []) -> int:
	return Archetypes.create_archetype(self, name, comp_ids)


func assign_archetype(idx: int, arch_id: int) -> void:
	Archetypes.assign_archetype(self, idx, arch_id)


func get_archetype(idx: int) -> int:
	return Archetypes.get_archetype(self, idx)


func archetype_none() -> int:
	return Archetypes.archetype_none(self)


func archetype_count() -> int:
	return Archetypes.archetype_count(self)


func archetype_id(name: StringName) -> int:
	return Archetypes.archetype_id(self, name)


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


func create_pool(name: StringName, capacity: int) -> int:
	return EntityPools.create_pool(self, name, capacity)


func _pool_alloc(pid: int) -> int:
	return EntityPools._pool_alloc(self, pid)


func _pool_free(pid: int, idx: int) -> void:
	EntityPools._pool_free(self, pid, idx)


func pool_free_count(pid: int) -> int:
	return EntityPools.pool_free_count(self, pid)


func pool_range(pid: int) -> Vector2i:
	return EntityPools.pool_range(self, pid)


func pool_id(name: StringName) -> int:
	return EntityPools.pool_id(self, name)


func pool_count() -> int:
	return EntityPools.pool_count(self)


# ─── Phase 4.1：序列化 / 反序列化 API（docs/architecture/migration.md）─────
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


func serialize() -> Dictionary:
	return StateArchive.serialize(self)


func deserialize(d: Dictionary) -> void:
	StateArchive.deserialize(self, d)


# ─── private serialize helpers ───────────────────────────────────────

func _serialize_cells_dict() -> Dictionary:
	return WorldArchiveHelpers.serialize_cells_dict(self)

func _deserialize_cells_dict(cells: Dictionary) -> void:
	WorldArchiveHelpers.deserialize_cells_dict(self, cells)

func _serialize_fronts_dict() -> Dictionary:
	return WorldArchiveHelpers.serialize_fronts_dict(self)

func _deserialize_fronts_dict(_d: Dictionary) -> void:
	WorldArchiveHelpers.deserialize_fronts_dict(self, _d)
