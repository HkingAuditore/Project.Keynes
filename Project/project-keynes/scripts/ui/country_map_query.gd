extends RefCounted
class_name CountryMapQuery

## 「格归属 → 槽位 → 国家句柄 → 国名」这一条解析的唯一去处。全静态、无状态、不缓存，
## 缓存留给调用方（它们的失效点各不相同）。
##
## 为什么要有这一层：同一条规则以前在三个地方各写一遍，而且三处都只认
## `ext.get_country_cell_snapshot()`——那个方法从来没有在 C++ 里绑定过（只有截图
## fixture 的 FakeExt 实现了它）。于是生产环境里邻国表、割地候选恒为空，模型里的
## `country_handles` 又从不被填充，所有国家都被判成「缺少国家句柄」。
##
## 权威顺序：
##   1. `MapData.country_slot_arr`——原生领土权威经
##      `sync_country_territory_to_map()` 写进 MapData 的只读镜像，
##      视野、国界、军事图层都读它，和玩家屏幕上看到的边界是同一份数据。
##   2. `get_country_cell_snapshot()`——旧桥 / 截图 fixture 的替身。
##   3. 模型里的 `military.cell_owners.owners`——纯 fixture（没有任何世界对象时）。
##
## 句柄解析：句柄是 `generation << 32 | slot`（`NativeCountryRuntime::make_handle`），
## 代际只有 Country 自己知道，所以拿该槽位的一个格去问 `cell_summary()`，
## 由 Country 回填 `country_handle`。模型里显式给的 `country_handles` 优先，
## 那是 fixture 与 AI 注入用的口子。

## 中性格：没有任何国家拥有。
const NEUTRAL := -1


## 每格归属槽位（长度 = 格数）。不可得时返回空数组，调用方据此走空态。
## `map_obj` 优先：生产里它来自 `CountryViewModel.set_context(generator, map)`，
## 因为 `MapGenerator` 没有公开的 map getter（`map_of()` 只是 fixture 那条路）。
static func owner_map(generator, model: Dictionary = {},
		map_obj = null) -> PackedInt32Array:
	var map = map_obj if map_obj != null else map_of(generator)
	if map != null:
		# 用 `get()` 而不是 `in`：MapData 是脚本属性，测试替身也可以是纯脚本类。
		var from_map = map.get("country_slot_arr")
		if from_map is PackedInt32Array and not (from_map as PackedInt32Array).is_empty():
			return from_map
	if generator != null and generator.has_method("get_data_core_world_ext"):
		var ext = generator.call("get_data_core_world_ext")
		if ext != null and ext.has_method("get_country_cell_snapshot"):
			var rows = ext.call("get_country_cell_snapshot")
			if rows is PackedInt32Array and not (rows as PackedInt32Array).is_empty():
				return rows
	return _model_owners(model)


## 会话地图（`MapData`）。没有 generator（截图 fixture、单元测试自行挂载）时为 null。
static func map_of(generator) -> Object:
	if generator == null or not generator.has_method("current_map"):
		return null
	var map = generator.call("current_map")
	return map if map is Object else null


## 六邻接打包表（cell * 6 + 方向）。地形/地图没接上时返回空。
static func neighbors_of(generator, map_obj = null) -> PackedInt32Array:
	var map = map_obj if map_obj != null else map_of(generator)
	if map == null or not map.has_method("neighbor_indices_packed"):
		return PackedInt32Array()
	var neighbors = map.call("neighbor_indices_packed")
	return neighbors if neighbors is PackedInt32Array else PackedInt32Array()


## 槽位 → 该国领土里的第一个格（= 建国时的首格，与 `country_snapshot.cell` 同义）。
## 一次 O(格数) 扫描，调用方按需缓存；不要在每个槽位上重扫一遍。
static func first_cell_by_slot(owners: PackedInt32Array) -> Dictionary:
	var out := {}
	for cell in range(owners.size()):
		var slot := int(owners[cell])
		if slot == NEUTRAL or out.has(slot):
			continue
		out[slot] = cell
	return out


## `first_cell_by_slot()` 的结果按槽位升序（名单展示用）。
static func occupied_slots(owners: PackedInt32Array) -> PackedInt32Array:
	var first_cells := first_cell_by_slot(owners)
	var slots := PackedInt32Array()
	for slot in first_cells.keys():
		slots.append(int(slot))
	slots.sort()
	return slots


## 该槽位是否存在有效的 Country 句柄。`override_handles` 是 fixture/AI 注入的显式表。
static func handle_for_slot(owners: PackedInt32Array, slot: int, country_facade,
		override_handles: Dictionary = {}, first_cells: Dictionary = {}) -> int:
	if slot == NEUTRAL:
		return 0
	var explicit := int(override_handles.get(slot, 0))
	if explicit != 0:
		return explicit
	if country_facade == null or not country_facade.has_method("cell_summary"):
		return 0
	var cells := first_cells if not first_cells.is_empty() \
		else first_cell_by_slot(owners)
	var cell := int(cells.get(slot, -1))
	if cell < 0:
		return 0
	var summary = country_facade.call("cell_summary", cell)
	if not (summary is Dictionary) or not bool((summary as Dictionary).get("ok", false)):
		return 0
	if not bool((summary as Dictionary).get("owned", false)):
		return 0
	return int((summary as Dictionary).get("country_handle", 0))


## 句柄里低 32 位就是槽位（`make_handle` 的编码），代际不进 UI。
static func slot_of_handle(handle: int) -> int:
	if handle == 0:
		return NEUTRAL
	return int(handle & 0xFFFFFFFF)


## Country 手里的国名。句柄失效/运行时未接通时返回空串，由调用方兜底编号。
static func country_name(country_facade, handle: int) -> String:
	if country_facade == null or handle == 0 \
			or not country_facade.has_method("snapshot"):
		return ""
	var snapshot = country_facade.call("snapshot", handle)
	if not (snapshot is Dictionary) or not bool((snapshot as Dictionary).get("ok", false)):
		return ""
	return String((snapshot as Dictionary).get("country_name", "")).strip_edges()


## 该国的格数，直接数归属镜像（不额外问 Country）。
static func cell_count_for_slot(owners: PackedInt32Array, slot: int) -> int:
	if slot == NEUTRAL:
		return 0
	var count := 0
	for index in range(owners.size()):
		if int(owners[index]) == slot:
			count += 1
	return count


## 与 `target_slot` 的领土共享一条六边形边的槽位集合（ring-1 = 接壤）。
## 返回 `{slot: edges}`：edges 是接触边数，用来区分"擦一角"和"长边界"。
static func border_edge_counts(owners: PackedInt32Array, neighbors: PackedInt32Array,
		target_slot: int) -> Dictionary:
	var out := {}
	if target_slot == NEUTRAL or neighbors.size() < owners.size() * 6:
		return out
	for cell in range(owners.size()):
		if int(owners[cell]) != target_slot:
			continue
		var base := cell * 6
		for direction in range(6):
			var neighbor := int(neighbors[base + direction])
			if neighbor < 0 or neighbor >= owners.size() or neighbor == cell:
				continue
			var other := int(owners[neighbor])
			if other == NEUTRAL or other == target_slot:
				continue
			out[other] = int(out.get(other, 0)) + 1
	return out


static func _model_owners(model: Dictionary) -> PackedInt32Array:
	var stand_in = _as_dict(_as_dict(model.get("military", null)).get(
		"cell_owners", null))
	var rows = stand_in.get("owners", PackedInt32Array())
	return rows if rows is PackedInt32Array else PackedInt32Array()


static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}
