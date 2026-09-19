extends RefCounted
class_name DCCommandBuffer

## DataCore — CommandBuffer：结构性变更延迟队列。
##
## 设计目标：
##   hot loop（query.for_each_index 内部）禁止直接 resize PackedArray —— 一旦
##   resize，View 引用会被 COW 分裂，下游所有缓存失效；同时单个 push_back
##   会引发 GC 抖动。CommandBuffer 把"创建 / 销毁 entity、增删 component"等
##   结构性指令缓冲到 round 末，由 World 在安全点统一 flush，hot loop 全程
##   只做 `arr[i] = x` 索引赋值。
##
## 首版实现策略（够用主义）：
##   1. create_entity()：在 buffer 内记录"申请一个 slot"；flush 时 World 一次性
##      扩容（tail-append），并执行 archetype 标记；create_entity() 立刻返回
##      占位 idx（= world.entity_count + buffer 内已申请数），调用方可用此 idx
##      继续提交 add_component 等指令；
##   2. destroy_entity(idx)：flush 时把对应 entity 的 archetype 标记为 _ARCH_NONE
##      （首版不做 swap-remove，保持 idx 稳定；Front 池由 weather_system 显式
##      做 free-list，避免 PackedArray 抖动）；
##   3. add_component / remove_component：首版仅暴露 API，最小实现按 archetype
##      标记位生效（archetype Task 6）；不真正分配 / 释放 component 槽位
##      （所有 component 都按 entity_count 满分配）。
##
## 与 Unity ECB 不同点：本实现首版不严格分离 begin/end concurrent 写；调用方
## 必须保证 buffer 在单 sub-pass 内被串行追加。

# 指令类型
const _CMD_CREATE: int = 1
const _CMD_DESTROY: int = 2
const _CMD_ADD_COMP: int = 3
const _CMD_REMOVE_COMP: int = 4
# I2.A.5：pool-aware 指令。create_in_pool/destroy_in_pool 不走尾部追加路径，
# 而是调用 World._pool_alloc/_pool_free 从指定 pool 的 free-list 调配 idx。
# CMD_SET_ARCH      只改 archetype 标记，不动 entity_count；
# CMD_DESTROY_TO_POOL 把 archetype 置为 ARCH_NONE 并把 idx 还回 free-list。
const _CMD_SET_ARCH: int = 5
const _CMD_DESTROY_TO_POOL: int = 6

# 指令缓冲：每条 [cmd, arg0, arg1]
var _cmds: PackedInt32Array = PackedInt32Array()
# create 的目标 archetype 列表（顺序与 _CMD_CREATE 出现顺序一致）
var _create_arch_ids: PackedInt32Array = PackedInt32Array()

# 计数：本 buffer 已申请的 create 数量（用于 create_entity 立刻返回占位 idx）
var _pending_create_count: int = 0

# 关联的 World（构造时注入）
var _world: DCWorld = null


func _init(w: DCWorld) -> void:
	_world = w


## 申请一个 entity，立刻返回占位 idx（= 当前 entity_count + 已申请数）。
## 调用方可用此 idx 继续提交 add_component / 字段写。
##  - arch_id 默认 -1（不绑定 archetype），可由调用方在 flush 后再 assign。
func create_entity(arch_id: int = -1) -> int:
	if _world == null:
		push_error("[DCCommandBuffer] create_entity: world is null")
		return -1
	var occupied_idx: int = _world.entity_count() + _pending_create_count
	_cmds.append(_CMD_CREATE)
	_cmds.append(arch_id)
	_cmds.append(0)
	_create_arch_ids.append(arch_id)
	_pending_create_count += 1
	return occupied_idx


## 标记一个 entity 为已销毁（flush 时把 archetype 置为 _ARCH_NONE）。
## 不会立即清空字段；调用方应在 flush 之后避免再读该 idx。
func destroy_entity(idx: int) -> void:
	_cmds.append(_CMD_DESTROY)
	_cmds.append(idx)
	_cmds.append(0)


## 给 entity 增加 component（首版按 archetype 标记位生效；component 槽位
## 不变 —— 全部按 entity_count 预分配）。
func add_component(idx: int, comp_id: int) -> void:
	_cmds.append(_CMD_ADD_COMP)
	_cmds.append(idx)
	_cmds.append(comp_id)


## 给 entity 移除 component（首版按 archetype 标记位生效）。
func remove_component(idx: int, comp_id: int) -> void:
	_cmds.append(_CMD_REMOVE_COMP)
	_cmds.append(idx)
	_cmds.append(comp_id)


## I2.A.5：pool-aware 创建。立即从 World._pool_alloc 拿到一个具体 idx（不是占位值），
## 并把"打 archetype 标记"这件事延迟到 flush。这让 spawn 时刷可用的 idx、flush
## 时才走 entity_archetype 写入，顺序与 Unity ECB / I3 C++ ECB 一致。
##  - 池满返回 -1，调用方需自行跳过（weather_system 已有 "front_count >= MAX 则不 spawn" 守卫）。
func create_in_pool(pool_id: int, arch_id: int) -> int:
	if _world == null:
		push_error("[DCCommandBuffer] create_in_pool: world is null")
		return -1
	var idx: int = _world._pool_alloc(pool_id)
	if idx < 0:
		return -1
	_cmds.append(_CMD_SET_ARCH)
	_cmds.append(idx)
	_cmds.append(arch_id)
	return idx


## I2.A.5：pool-aware 销毁。flush 时先把 archetype 置为 ARCH_NONE，再把 idx 归还
## free-list。调用方不可在 flush 之前重复 destroy 同一 idx（会导致 free-list 重复变量）。
func destroy_in_pool(pool_id: int, idx: int) -> void:
	_cmds.append(_CMD_DESTROY_TO_POOL)
	_cmds.append(idx)
	_cmds.append(pool_id)


## I2.A.5：同步设置 archetype（需要跳过 free-list 分配、仅重点 archetype 转换的场景）。
func set_archetype(idx: int, arch_id: int) -> void:
	_cmds.append(_CMD_SET_ARCH)
	_cmds.append(idx)
	_cmds.append(arch_id)


## 当前 buffer 是否有指令。
func is_empty() -> bool:
	return _cmds.size() == 0


## 指令条数（每条 3 个 int）。
func count() -> int:
	return _cmds.size() / 3


## flush：按记录顺序应用所有指令到 World，执行完清空 buffer。
##
## 性能：每帧 weather 迁移期 buffer 条数预计 < 32（spawn / destroy front），
## 远低于"单帧累积 1000 条触发分批"阈值；首版直接顺序处理。
func flush() -> void:
	if _world == null:
		push_error("[DCCommandBuffer] flush: world is null")
		_cmds.clear()
		_create_arch_ids.clear()
		_pending_create_count = 0
		return
	var n: int = _cmds.size()
	if n == 0:
		return
	# 第一遍：扫描所有 _CMD_CREATE，一次性扩容 World（避免多次 resize）
	var create_count: int = 0
	var i: int = 0
	while i < n:
		if _cmds[i] == _CMD_CREATE:
			create_count += 1
		i += 3
	if create_count > 0:
		var new_count: int = _world.entity_count() + create_count
		_world.resize_all(new_count)
	# 第二遍：按顺序应用指令（archetype 等）
	var create_cursor: int = 0
	var base_idx: int = _world.entity_count() - create_count
	i = 0
	while i < n:
		var cmd: int = _cmds[i]
		var a0: int = _cmds[i + 1]
		var a1: int = _cmds[i + 2]
		match cmd:
			_CMD_CREATE:
				var new_idx: int = base_idx + create_cursor
				if a0 >= 0:
					_world.assign_archetype(new_idx, a0)
				create_cursor += 1
			_CMD_DESTROY:
				_world.assign_archetype(a0, _world.archetype_none())
			_CMD_SET_ARCH:
				# I2.A.5：pool-aware create 路径。idx 已在 create_in_pool 里 _pool_alloc 拿到，
				# 这里仅负责把 archetype 写入 _entity_archetype。
				_world.assign_archetype(a0, a1)
			_CMD_DESTROY_TO_POOL:
				# I2.A.5：archetype 置为 NONE 后把 idx 还给 free-list。
				_world.assign_archetype(a0, _world.archetype_none())
				_world._pool_free(a1, a0)
			_CMD_ADD_COMP:
				# 首版仅打 archetype 标记位；component 槽位全部已预分配
				pass
			_CMD_REMOVE_COMP:
				pass
		i += 3
	# 清空 buffer
	_cmds.clear()
	_create_arch_ids.clear()
	_pending_create_count = 0
