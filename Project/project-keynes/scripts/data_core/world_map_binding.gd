extends RefCounted

const _Slot = preload("res://scripts/data_core/world_component_slot.gd")


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
static func bind_map_data(owner: Variant, map_data, demo_thermal_gradient_enabled: bool = false) -> void:
	if map_data == null:
		push_error("[DCWorld] bind_map_data: map_data is null")
		return
	owner._map_data = map_data
	owner._bound = false
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
	var cells_pid: int = owner.pool_id(DCComponentIds.POOL_CELLS)
	if cells_pid >= 0:
		var existing: Dictionary = owner._pools[cells_pid]
		if int(existing["start"]) != 0 or int(existing["count"]) != n:
			push_error("[DCWorld] bind_map_data: existing 'cells' pool [%d, +%d) != cell_count=%d"
				% [int(existing["start"]), int(existing["count"]), n])
			return
		# 重复 bind：保持 _entity_count = n（cells pool 已经占据 [0, n)）
		owner._entity_count = n
	else:
		# 首次 bind：清零再让 create_pool 以 start=0 注册
		owner._entity_count = 0
		owner.create_pool(DCComponentIds.POOL_CELLS, n)
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
	# 详见 docs/architecture/development-guide.md。
	#
	# Demo 条目（cell.demo.*）：仅在 demo_thermal_gradient_enabled=true 时
	# 才 attach；为 false 时跳过（slot 不注册 → C++ pass component_id() 返回
	# -1 → pass 内部安全 no-op）。开启时按 charter §12.6 约定先把 MapData
	# 对应字段 resize 到 n，避免下面的长度一致性校验报错。
	#
	# 启动期 sanity check：让 schema 错误（typo / 缺字段 / dtype 非法）
	# 在 bind 第一时间报出来，而不是 hot path 跑到一半静默失败。
	if owner._debug:
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
				owner._bind_register_and_attach(entry.name, DCComponentIds.F32,
					bool(entry.get("track_prev", false)), arr_f, arr_prev_f)
			DCComponentIds.U8:
				if not (arr_v is PackedByteArray):
					push_error("[DCWorld] bind_map_data: MapData.%s expected PackedByteArray" % map_field)
					return
				owner._bind_register_and_attach_u8(entry.name, arr_v)
			DCComponentIds.I32:
				# B3b：植被动力学 streak 字段（cell.vitality_low_streak /
				# cell.vitality_high_streak）走 I32 attach 路径。register_component
				# I32 路径 + view_i32 / write_i32 / write_i32_range / write_i32_indexed
				# 都已实装；这里补上"挂入 MapData PackedInt32Array 外部引用"步骤。
				if not (arr_v is PackedInt32Array):
					push_error("[DCWorld] bind_map_data: MapData.%s expected PackedInt32Array" % map_field)
					return
				owner._bind_register_and_attach_i32(entry.name, arr_v)
			_:
				push_error("[DCWorld] bind_map_data: unsupported dtype=%d for '%s'"
					% [int(entry.dtype), String(entry.name)])
				return
	# 4) 长度一致性校验
	for slot in owner._slots:
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
	owner._topo_neighbors = map_data.neighbor_indices_packed()
	owner._topo_built = true
	# 6) Dirty mask 同步（plan: cell-dirty-push-and-dots-atlas-bakers, A）。
	#    mask 大小 = cells pool capacity = n_cells。重 bind 时强制清零（旧脏作废）。
	owner._resize_dirty_mask(n)
	owner._bound = true


## 重新绑定（MapData.rebuild_soa_from_cells 之后必须调用）。
## 仅刷新已挂入的 component 引用，不重新注册。
static func rebind_arrays(owner: Variant) -> void:
	if owner._map_data == null:
		push_error("[DCWorld] rebind_arrays: no map_data bound")
		return
	# 直接走 bind_map_data 全量重绑（注册幂等；引用刷新）
	owner.bind_map_data(owner._map_data)


## 查询是否已 bind。
static func is_bound(owner: Variant) -> bool:
	return owner._bound


static func is_external_component(owner: Variant, comp_id: int) -> bool:
	var slot: _Slot = owner._get_slot(comp_id)
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
static func unbind_map_data(owner: Variant) -> void:
	if not owner._bound:
		return
	# 把所有 external_ref slot 的 PackedArray 还原为空数组（断引用 +
	# 让下次 bind_map_data 走重新挂入路径）。
	for slot in owner._slots:
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
	owner._map_data = null
	owner._bound = false
	# Dirty mask 同步（plan: cell-dirty-push-and-dots-atlas-bakers, A）：
	# unbind 后 cell pool 失效，mask 一并释放，避免旧 mask 跨 bind 污染。
	owner._resize_dirty_mask(0)


## PR-4.4：rebind 别名，兼容 hot-reload 调用。等价于先 unbind 再 bind。
##
## 用例：编辑器开发者改 ClimateProfile.demo_thermal_gradient_enabled=true 时，
## 需要重 bind 让 DCWorld 注册新的 demo slot。原 bind_map_data 是幂等的，
## 但加 demo flag 切换不会再注册 demo slot；rebind_map_data 强制走全量重 bind。
##
## map_data：通常传 null（用之前的 _map_data，由 unbind 之前 cache 的）；
##           或 caller 显式传新 MapData（regenerate / load_save 路径）。
static func rebind_map_data(owner: Variant, map_data = null, demo_thermal_gradient_enabled: bool = false) -> void:
	var target = map_data if map_data != null else owner._map_data
	if target == null:
		push_error("[DCWorld] rebind_map_data: no map_data provided and no cached _map_data")
		return
	owner.unbind_map_data()
	owner.bind_map_data(target, demo_thermal_gradient_enabled)


## 获取邻居拓扑（hex-grid）。
##  - neighbor_index(idx, dir): 返回邻居 idx（无邻居返回 -1）
##  - neighbors_packed(): 返回底层 PackedInt32Array (size = cell_count*6)
static func topology_neighbor_index(owner: Variant, idx: int, dir: int) -> int:
	if not owner._topo_built:
		push_error("[DCWorld] topology not built; call bind_map_data first")
		return -1
	if idx < 0 or dir < 0 or dir > 5:
		return -1
	var base: int = idx * 6 + dir
	if base >= owner._topo_neighbors.size():
		return -1
	return owner._topo_neighbors[base]


static func topology_neighbors_packed(owner: Variant) -> PackedInt32Array:
	if not owner._topo_built:
		push_error("[DCWorld] topology not built; call bind_map_data first")
		return PackedInt32Array()
	return owner._topo_neighbors


## 内部：注册 cell-level F32 component 并挂入引用（重复调用幂等）。
static func _bind_register_and_attach(owner: Variant, name: StringName, dtype: int, track_prev: bool,
		arr_ref: PackedFloat32Array, arr_prev_ref: PackedFloat32Array = PackedFloat32Array()) -> void:
	var cid: int
	if owner._slot_by_name.has(name):
		cid = int(owner._slot_by_name[name])
	else:
		cid = owner.register_component(name, dtype, 1, track_prev)
		owner._builtin_cell_ids[name] = cid
	if cid < 0:
		return
	var slot: _Slot = owner._slots[cid]
	slot.external_ref = true
	slot.arr_f32 = arr_ref
	if track_prev and arr_prev_ref.size() > 0:
		slot.arr_f32_prev = arr_prev_ref


## 内部：注册 cell-level U8 component 并挂入引用。
static func _bind_register_and_attach_u8(owner: Variant, name: StringName, arr_ref: PackedByteArray) -> void:
	var cid: int
	if owner._slot_by_name.has(name):
		cid = int(owner._slot_by_name[name])
	else:
		cid = owner.register_component(name, DCComponentIds.U8, 1, false)
		owner._builtin_cell_ids[name] = cid
	if cid < 0:
		return
	var slot: _Slot = owner._slots[cid]
	slot.external_ref = true
	slot.arr_u8 = arr_ref


## 内部：注册 cell-level I32 component 并挂入引用（B3b：植被动力学 streak 用）。
## I32 不支持 track_prev（与 U8 一致；首版不双缓冲，见 _Slot 字段说明）。
static func _bind_register_and_attach_i32(owner: Variant, name: StringName, arr_ref: PackedInt32Array) -> void:
	var cid: int
	if owner._slot_by_name.has(name):
		cid = int(owner._slot_by_name[name])
	else:
		cid = owner.register_component(name, DCComponentIds.I32, 1, false)
		owner._builtin_cell_ids[name] = cid
	if cid < 0:
		return
	var slot: _Slot = owner._slots[cid]
	slot.external_ref = true
	slot.arr_i32 = arr_ref
