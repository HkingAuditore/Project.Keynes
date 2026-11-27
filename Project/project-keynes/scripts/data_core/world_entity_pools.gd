extends RefCounted


## 注册一个 pool，返回 pool_id (int)。
##  - 同名 pool 已存在视为幂等，直接返回既有 id；容量不一致时 push_warning。
##  - 新 pool 的 start = 当前 _entity_count；自动把 _entity_count 拉伸到
##    start + capacity，并对所有已注册 component 同步 resize（external_ref
##    槽位不动，由 bind_map_data 自行管理）。
##  - I2.A.5：同时初始化该 pool 的 free-list（全部空闲）并把段内所有
##    entity 的 archetype 预置为 _ARCH_NONE，让"未分配"与"已 destroy"语义统一。
static func create_pool(owner: Variant, name: StringName, capacity: int) -> int:
	if capacity < 0:
		push_error("[DCWorld] create_pool '%s': capacity must be >= 0, got %d"
			% [String(name), capacity])
		return -1
	if owner._pool_by_name.has(name):
		var existing_id: int = int(owner._pool_by_name[name])
		var existing: Dictionary = owner._pools[existing_id]
		if int(existing["count"]) != capacity:
			push_warning("[DCWorld] create_pool '%s': existing capacity=%d != requested=%d, returning existing id"
				% [String(name), int(existing["count"]), capacity])
		return existing_id
	var start: int = owner._entity_count
	var pool_id_new: int = owner._pools.size()
	owner._pools.append({ "name": name, "start": start, "count": capacity })
	owner._pool_by_name[name] = pool_id_new
	# 拉伸 entity_count 并同步 component 槽位（create_entities 内部跳过 external_ref）
	owner.create_entities(start + capacity)
	# 初始化 free-list（栈式 LIFO，pop_back 取最高 idx；高位先消耗、低位后消耗，
	# 与扁平池约定无关，只要顺序自洽即可）。
	var fl: PackedInt32Array = PackedInt32Array()
	fl.resize(capacity)
	for i in range(capacity):
		fl[i] = start + i
	owner._pool_free_lists.append(fl)
	# 把段内所有 entity 的 archetype 预置为 ARCH_NONE。
	# 注意：cells pool 调用此函数时 _entity_archetype 可能尚为空（archetype
	# 数组按需扩容）；这里走 assign_archetype 触发首次扩容是安全且廉价的。
	var arch_none: int = owner._ARCH_NONE
	for j in range(start, start + capacity):
		owner.assign_archetype(j, arch_none)
	return pool_id_new


## I2.A.5：从指定 pool 的 free-list 借用一个 entity idx；池满返回 -1。
## 仅供 ECB / 框架内部调用，业务代码不要直接调。
static func _pool_alloc(owner: Variant, pid: int) -> int:
	if pid < 0 or pid >= owner._pool_free_lists.size():
		push_error("[DCWorld] _pool_alloc: invalid pool_id=%d" % pid)
		return -1
	var fl: PackedInt32Array = owner._pool_free_lists[pid]
	var sz: int = fl.size()
	if sz == 0:
		return -1
	var idx: int = fl[sz - 1]
	fl.resize(sz - 1)
	owner._pool_free_lists[pid] = fl  # COW 写回
	return idx


## I2.A.5：把 idx 归还指定 pool 的 free-list。
## 调用方应保证 idx 确实属于该 pool 的范围；首版不做去重校验（debug 下校验）。
static func _pool_free(owner: Variant, pid: int, idx: int) -> void:
	if pid < 0 or pid >= owner._pool_free_lists.size():
		push_error("[DCWorld] _pool_free: invalid pool_id=%d" % pid)
		return
	if owner._debug:
		var p: Dictionary = owner._pools[pid]
		var s: int = int(p["start"])
		var c: int = int(p["count"])
		if idx < s or idx >= s + c:
			push_error("[DCWorld] _pool_free: idx=%d out of pool '%s' range [%d, %d)"
				% [idx, String(p["name"]), s, s + c])
			return
	var fl: PackedInt32Array = owner._pool_free_lists[pid]
	fl.append(idx)
	owner._pool_free_lists[pid] = fl  # COW 写回


## I2.A.5：当前 pool 内剩余可分配槽位数（debug 用）。
static func pool_free_count(owner: Variant, pid: int) -> int:
	if pid < 0 or pid >= owner._pool_free_lists.size():
		return 0
	return owner._pool_free_lists[pid].size()


## 取 pool 的 [start, end) 范围。非法 pool_id 返回 Vector2i(-1, -1)。
static func pool_range(owner: Variant, pid: int) -> Vector2i:
	if pid < 0 or pid >= owner._pools.size():
		push_error("[DCWorld] pool_range: invalid pool_id=%d" % pid)
		return Vector2i(-1, -1)
	var p: Dictionary = owner._pools[pid]
	var s: int = int(p["start"])
	var c: int = int(p["count"])
	return Vector2i(s, s + c)


## 取 pool 名 → pool_id；不存在返回 -1。
static func pool_id(owner: Variant, name: StringName) -> int:
	return int(owner._pool_by_name.get(name, -1))


## 当前 pool 总数。
static func pool_count(owner: Variant) -> int:
	return owner._pools.size()
