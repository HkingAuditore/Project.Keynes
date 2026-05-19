extends RefCounted
class_name BakerDirtyHelpers

## plan/dirty-push-atlas-encode 阶段 E：4 张 atlas baker 共享的 dirty 集合处理工具。
##
## 本模块全部走 static func + 纯计算 + PackedByteArray/Dictionary 临时去重，
## 不持有状态。`DynamicVisualAtlasUploadSystem._step_phase_baker` 在
## ecology / dyn_smooth phase 入口调用以下工具，把 sim dirty cells 加工成
## 真正的 baker 工作集。
##
## 调用约定：
##   - dilate_dirty_one_hop：dyn_smooth phase 用；输入 dirty cells，输出 dirty
##     ∪ 6 邻居（去重后的 Array[HexCell]）。box blur 中心 + 邻居均值，dirty cell
##     变化会让其作为"邻居"出现的中心们也需要重算，所以必须膨胀。
##   - merge_with_eco_decay：ecology phase 用；输入 dirty cells + baker 的
##     _eco_active_decay_set，输出去重合并的 Array[HexCell]。让 transition_age
##     还在衰减的 cells 即使本 stride 无 sim dirty 也能被重新喂进 chunk_step。
##
## 性能：
##   - dilate：O(dirty_count × 6) + O(N) PackedByteArray 内存分配（一次）；
##     dirty 占比 5% 时 6×5%×N = 30%×N 量级，仍远小于 all_cells。
##   - merge：O(dirty_count + decay_set.size())，两者都远小于 N。

const HexCellScript = preload("res://scripts/geography/hex_cell.gd")
const MapDataScript = preload("res://scripts/geography/map_data.gd")


## dyn_smooth box-blur 1 跳邻居膨胀。
##
## map: MapData，调用 map.cell_at(idx) 反查 + map.get_neighbors(cell) 拿邻居
## base_cells: Array[HexCell]，sim dirty 输入；允许包含 null（自动跳过）。
## 返回: Array[HexCell]，去重后的 dirty ∪ 1 跳邻居。
##
## 实现：用一个 N 大小的 PackedByteArray(0/1) 临时去重，避免 HexCell→bool Dict
## 的 hash 装箱开销。返回时用 _cell_array 顺序遍历填 Array（保持 cells 序与
## chunk_step 内 sig 比对的稳定性。）
static func dilate_dirty_one_hop(map, base_cells: Array) -> Array:
	if map == null or base_cells.is_empty():
		return base_cells.duplicate() if base_cells != null else []
	var n: int = map.cell_count()
	if n <= 0:
		return []
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(n)
	# fill(0) 是 default，PackedByteArray.resize 已置零。
	# 第一遍：mark base cells。
	for c in base_cells:
		if c == null:
			continue
		var idx: int = int(c.index)
		if idx >= 0 and idx < n:
			seen[idx] = 1
	# 第二遍：mark base cells 的邻居（最多 6 个）。
	# 优先走 PackedInt32Array 快路径；旧 MapData 退回 get_neighbors(cell)。
	var nb_indices: PackedInt32Array = PackedInt32Array()
	if map.has_method("neighbor_indices_packed"):
		nb_indices = map.neighbor_indices_packed()
	var fast_indexed: bool = nb_indices.size() >= n * 6
	for c in base_cells:
		if c == null:
			continue
		var idx: int = int(c.index)
		if idx < 0 or idx >= n:
			continue
		if fast_indexed:
			var base: int = idx * 6
			for d in range(6):
				var nb_idx: int = nb_indices[base + d]
				if nb_idx >= 0 and nb_idx < n:
					seen[nb_idx] = 1
		elif map.has_method("get_neighbors"):
			for nb_cell in map.get_neighbors(c):
				if nb_cell == null:
					continue
				var nb_i: int = int(nb_cell.index)
				if nb_i >= 0 and nb_i < n:
					seen[nb_i] = 1
	# 第三遍：按 idx 顺序收集 cells。
	var out: Array = []
	for i in range(n):
		if seen[i] == 1:
			out.append(map.cell_at(i))
	return out


## ecology phase 工作集合并：dirty cells ∪ active decay set。
##
## base_cells: Array[HexCell]，sim dirty cells（允许 null）。
## decay_set: Dictionary[HexCell→true]，baker 维护的"transition_age 还 > 0"集合。
##
## 返回: Array[HexCell]，去重合并；若两者都空则返回 []。
##
## 实现：用 Dictionary 临时去重（HexCell 是 RefCounted，按 reference equality
## hash）。decay_set 通常 ≤ 几百，base_cells 取决于 sim dirty 占比，合并后仍
## ≪ N，无需 PackedByteArray fast path。
static func merge_with_eco_decay(base_cells: Array, decay_set: Dictionary) -> Array:
	if (base_cells == null or base_cells.is_empty()) \
			and (decay_set == null or decay_set.is_empty()):
		return []
	var seen: Dictionary = {}
	var out: Array = []
	if base_cells != null:
		for c in base_cells:
			if c == null or seen.has(c):
				continue
			seen[c] = true
			out.append(c)
	if decay_set != null:
		for c in decay_set.keys():
			if c == null or seen.has(c):
				continue
			seen[c] = true
			out.append(c)
	return out
