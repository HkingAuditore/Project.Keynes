extends RefCounted
class_name BakerDirtyHelpers

## [deprecated 2026-05-20 atlas-pipeline-cpp]
##   本模块仅在 climate_profile.cpp_atlas_pipeline_enabled = false 时使用
##   （fallback / 调试 / bit-equal 测试路径）。cpp 路径走 DCWorldExt 端
##   `run_atlas_pipeline_step` 内部 `dilate_one_hop_cpp` / `merge_with_eco_decay_cpp`
##   等价实现，输入 SoA neighbor_indices_packed + std::vector<uint8_t> seen
##   过滤位图，行为与本模块按位等价（已通过 cpp_atlas_pipeline_bitequal_test 验收）。
##
##   保留本模块的两个原因：
##     (1) flag=false 紧急回退路径需要 GD 端等价实现；
##     (2) bit-equal 测试需要 GD 镜像作为对照基准。
##   待 atlas-pipeline-cpp 在生产环境烧入 N 周后，可考虑彻底删除本模块。
##
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

# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 一次性 push_warning：当 fallback 路径首次调用 dilate_dirty_one_hop /
# merge_with_eco_decay 时提醒"已退化到 GD 路径，性能不如 cpp pipeline"。
# 不阻塞执行，仅引导关注。
static var _deprecated_warned: bool = false
static func _ensure_cpp_dilate_used_warning() -> void:
	if _deprecated_warned:
		return
	_deprecated_warned = true
	push_warning("[baker_dirty_helpers deprecated] fallback GD 路径被命中。"
			+ "如非诊断 / 测试用途，请确认 cpp_atlas_pipeline_enabled 是否开启。")



## dyn_smooth box-blur 1 跳邻居膨胀。
##
## map: MapData，调用 map.cell_at(idx) 反查 + map.get_neighbors(cell) 拿邻居
## base_cells: Array[HexCell]，sim dirty 输入；允许包含 null（自动跳过）。
## 返回: Array[HexCell]，去重后的 dirty ∪ 1 跳邻居。
##
## 实现：用一个 N 大小的 PackedByteArray(0/1) 临时去重，避免 HexCell→bool Dict
## 的 hash 装箱开销。
##
## [perf 2026-05-20 dilate-no-full-scan] 自适应两路径：
##   - 稀疏路径（base_cells.size() < n/2，正常情况）：mark 时同步 push idx 到 candidates，
##     最后 sort + dedupe，O(dirty × 7 × log(dirty × 7))。dirty=50 时 ~350 次 sort 比较。
##   - 稠密路径（base_cells.size() ≥ n/2，sim 端退化为全图打 dirty 时）：保留旧版"全图扫"，
##     O(N)，不做 sort（dirty=2400 时 sort 反而要 26000 次比较是浪费）。
##   阈值 n/2 是简单分界：稀疏路径成本 ≈ k × dirty（k≈14，含 sort log），稠密路径成本 ≈ N。
##   两者相等大约在 dirty ≈ N/14，n/2 是更保守的"明显稀疏"门槛，避免边界抖动。
##   行为上与旧版完全等价：seen 去重逻辑不变，输出顺序按 idx 升序。
static func dilate_dirty_one_hop(map, base_cells: Array) -> Array:
	_ensure_cpp_dilate_used_warning()
	if map == null or base_cells.is_empty():
		return base_cells.duplicate() if base_cells != null else []
	var n: int = map.cell_count()
	if n <= 0:
		return []
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(n)
	# 第一遍：mark base cells（两条路径共用）。
	for c in base_cells:
		if c == null:
			continue
		var idx: int = int(c.index)
		if idx >= 0 and idx < n:
			seen[idx] = 1
	# 第二遍：mark base cells 的邻居（最多 6 个）。
	var nb_indices: PackedInt32Array = PackedInt32Array()
	if map.has_method("neighbor_indices_packed"):
		nb_indices = map.neighbor_indices_packed()
	var fast_indexed: bool = nb_indices.size() >= n * 6
	for c in base_cells:
		if c == null:
			continue
		var idx2: int = int(c.index)
		if idx2 < 0 or idx2 >= n:
			continue
		if fast_indexed:
			var base: int = idx2 * 6
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
	# 第三遍：自适应稀疏 / 稠密。
	var out: Array = []
	if base_cells.size() < (n >> 1):
		# 稀疏路径：候选集 = mark 时遇到的所有 idx，sort 去重。
		var candidates: PackedInt32Array = PackedInt32Array()
		candidates.resize(base_cells.size() * 7)
		var cand_count: int = 0
		for c2 in base_cells:
			if c2 == null:
				continue
			var idx3: int = int(c2.index)
			if idx3 < 0 or idx3 >= n:
				continue
			if cand_count >= candidates.size():
				candidates.resize(cand_count + 64)
			candidates[cand_count] = idx3
			cand_count += 1
			if fast_indexed:
				var base2: int = idx3 * 6
				for d2 in range(6):
					var nb_idx2: int = nb_indices[base2 + d2]
					if nb_idx2 >= 0 and nb_idx2 < n:
						if cand_count >= candidates.size():
							candidates.resize(cand_count + 64)
						candidates[cand_count] = nb_idx2
						cand_count += 1
		candidates.resize(cand_count)
		candidates.sort()
		out.resize(cand_count)
		var w: int = 0
		for i in range(cand_count):
			var idx4: int = candidates[i]
			if seen[idx4] == 1:
				seen[idx4] = 0
				out[w] = map.cell_at(idx4)
				w += 1
		out.resize(w)
	else:
		# 稠密路径：base_cells 已占全图大半，全图扫比 sort 候选集便宜。
		for i2 in range(n):
			if seen[i2] == 1:
				out.append(map.cell_at(i2))
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
	_ensure_cpp_dilate_used_warning()
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
