extends RefCounted
class_name DCQuery

## DataCore — Query DSL（声明式数据访问 + 遍历范围）。
##
## 三种遍历模式（按 dirty/archetype/index_list 优先级判定）：
##   1. with_index_list(idx_list)     — 按 idx 列表顺序遍历，最常用于"基于
##                                       fronts 的稀疏 advect"等热点子集；
##   2. with_dirty_mask(mask)         — 仅访问 mask[i]==1 的 entity，
##                                       与 MapData.climate_dirty_mask 等天然兼容；
##   3. with_archetype(arch_id)       — 仅访问 entity_archetype[i]==arch_id 的 idx，
##                                       Task 6 的 archetype 标记位投入使用；
##   4. 否则                           — 顺序全图遍历 [0, entity_count)。
##
## hot loop 设计：
##   - for_each_index(callback) 内部不分配新对象（callback 是 GDScript Callable，
##     调用方持有一份 Callable 即可）；
##   - callback 返回 false 立即中断（用于 SusJob 预算耗尽提前退出）；
##   - 写集合 / 读集合记录仅用于 debug 校验，release 路径不影响性能。
##
## 复用：DCWorld.query() 工厂返回内部预分配池里的实例；调用方通过 _build()
## 完成 chain 后直接 for_each_index，结束后调度器或工厂 release 回池。

# 与 World 关联（执行时按 archetype / entity_count 确定遍历范围）
var _world: DCWorld = null

# 读 / 写集合（调用 with / readwrite / readonly 时累计）；首版仅做 debug 校验
var _read_set: Array[int] = []
var _write_set: Array[int] = []

# 过滤器（互斥优先级：index_list > dirty > archetype > 全遍历）
var _index_list: PackedInt32Array = PackedInt32Array()
var _has_index_list: bool = false
var _dirty_mask: PackedByteArray = PackedByteArray()
var _has_dirty_mask: bool = false
var _archetype_id: int = -1
var _entity_archetype: PackedInt32Array = PackedInt32Array()  # World 注入

# 显式 entity 范围（默认 [0, world.entity_count)；可手动收窄到 front 池等）
var _range_begin: int = -1
var _range_end: int = -1

# 是否已 build（链式调用结尾必须 build()）
var _built: bool = false


# ─── 内部：由 DCWorld 调用 ────────────────────────────────────────

## 重置为初始状态（World 从池中取出 query 时调用）。
func _reset(w: DCWorld) -> void:
	_world = w
	_read_set.clear()
	_write_set.clear()
	_index_list = PackedInt32Array()
	_has_index_list = false
	_dirty_mask = PackedByteArray()
	_has_dirty_mask = false
	_archetype_id = -1
	_entity_archetype = PackedInt32Array()
	_range_begin = -1
	_range_end = -1
	_built = false


# ─── 公共：链式 DSL ───────────────────────────────────────────

## 声明本 query 需要 component（首版与 readonly/readwrite 等价；保留为 hint）。
func with(comp_id: int) -> DCQuery:
	if not _read_set.has(comp_id):
		_read_set.append(comp_id)
	return self


## 声明本 query 仅读 component（debug 校验用）。
func readonly(comp_id: int) -> DCQuery:
	if not _read_set.has(comp_id):
		_read_set.append(comp_id)
	return self


## 声明本 query 读写 component（debug 校验用：写到非 _write_set 内的 component
## 在 debug 构建会触发 push_warning）。
func readwrite(comp_id: int) -> DCQuery:
	if not _read_set.has(comp_id):
		_read_set.append(comp_id)
	if not _write_set.has(comp_id):
		_write_set.append(comp_id)
	return self


## 仅遍历 mask[i]==1 的 entity。
func with_dirty_mask(mask: PackedByteArray) -> DCQuery:
	_dirty_mask = mask
	_has_dirty_mask = true
	return self


## 仅遍历 entity_archetype[i]==arch_id 的 entity（Task 6 投入使用）。
## entity_archetype 数组由 World 内部注入，调用方只需传 arch_id。
func with_archetype(arch_id: int) -> DCQuery:
	_archetype_id = arch_id
	if _world != null:
		_entity_archetype = _world.entity_archetype_array()
	return self


## 按 idx 列表顺序遍历（front 周边稀疏域用）。
func with_index_list(idx_list: PackedInt32Array) -> DCQuery:
	_index_list = idx_list
	_has_index_list = true
	return self


## 显式收窄 entity 范围（用于 front 池 [0, front_count) 而非全图）。
func with_range(begin_idx: int, end_idx: int) -> DCQuery:
	_range_begin = begin_idx
	_range_end = end_idx
	return self


## 限定遍历到某个 pool（I2.A.2）。内部转换为 with_range，与 with_archetype
## 叠加时取交集。非法 pool_id 时设为空段（callback 一次都不会被调用）。
func in_pool(pid: int) -> DCQuery:
	if _world == null:
		push_error("[DCQuery] in_pool: world is null")
		return self
	var rng: Vector2i = _world.pool_range(pid)
	if rng.x < 0:
		# 非法 pool_id：空段，遍历不触发 callback（pool_range 已 push_error）
		_range_begin = 0
		_range_end = 0
		return self
	_range_begin = rng.x
	_range_end = rng.y
	return self


## 链式结尾。返回 self 以便 inline 使用。
func build() -> DCQuery:
	_built = true
	return self


# ─── 公共：遍历 ──────────────────────────────────────────────

## 顺序遍历选定 entity，对每个 idx 调用 callback(idx) -> bool。
##  - callback 返回 false：立即中断（SusJob 预算耗尽路径）。
##  - callback 返回 true / null：继续。
##  - 返回值：true=遍历完成，false=被 callback 中断。
func for_each_index(callback: Callable) -> bool:
	if _world == null:
		push_error("[DCQuery] for_each_index: world is null")
		return false
	if not _built:
		# 容错：未显式 build() 也允许执行（保留 hot path 简洁）
		_built = true
	# 1) index_list 优先
	if _has_index_list:
		var n_l: int = _index_list.size()
		for i in range(n_l):
			var idx: int = _index_list[i]
			if idx < 0:
				continue
			var ret = callback.call(idx)
			if typeof(ret) == TYPE_BOOL and not ret:
				return false
		return true
	# 2) 范围确定
	var begin_i: int = _range_begin if _range_begin >= 0 else 0
	var end_i: int = _range_end if _range_end >= 0 else _world.entity_count()
	if end_i <= begin_i:
		return true
	# 3) dirty mask 与 archetype 可同时叠加：两者都成立才进入 callback
	var use_dirty: bool = _has_dirty_mask and _dirty_mask.size() >= end_i
	var use_arch: bool = _archetype_id >= 0 and _entity_archetype.size() >= end_i
	if not use_dirty and not use_arch:
		# 全段顺序遍历（hot path）
		for j in range(begin_i, end_i):
			var ret_b = callback.call(j)
			if typeof(ret_b) == TYPE_BOOL and not ret_b:
				return false
		return true
	# 慢路径：带过滤
	for k in range(begin_i, end_i):
		if use_dirty and _dirty_mask[k] == 0:
			continue
		if use_arch and _entity_archetype[k] != _archetype_id:
			continue
		var ret_c = callback.call(k)
		if typeof(ret_c) == TYPE_BOOL and not ret_c:
			return false
	return true


## 分块遍历（首版同步实现；保留 chunk 形态供未来 WorkerThreadPool 并行）。
##   callback(start, end) -> bool。end 为开区间。
func for_each_chunk(chunk_size: int, callback: Callable) -> bool:
	if _world == null:
		push_error("[DCQuery] for_each_chunk: world is null")
		return false
	if chunk_size <= 0:
		chunk_size = 256
	# 计算遍历范围
	var begin_i: int = _range_begin if _range_begin >= 0 else 0
	var end_i: int = _range_end if _range_end >= 0 else _world.entity_count()
	if _has_index_list:
		# index_list 模式按 list size 分块（chunk 内 idx 仍由 callback 自行遍历）
		var nl: int = _index_list.size()
		var s: int = 0
		while s < nl:
			var e: int = min(s + chunk_size, nl)
			var ret = callback.call(s, e)
			if typeof(ret) == TYPE_BOOL and not ret:
				return false
			s = e
		return true
	# 范围模式
	var c: int = begin_i
	while c < end_i:
		var ne: int = min(c + chunk_size, end_i)
		var ret_b = callback.call(c, ne)
		if typeof(ret_b) == TYPE_BOOL and not ret_b:
			return false
		c = ne
	return true


# ─── 调试辅助 ────────────────────────────────────────────────

## 返回读 / 写集合（debug 校验用）。
func read_set() -> Array[int]:
	return _read_set


func write_set() -> Array[int]:
	return _write_set
