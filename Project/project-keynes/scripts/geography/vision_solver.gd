# vision_solver.gd
# 地形感知的视野解算器。
#
# 模型：以玩家国家的全部领土格为源，做**多源 Dijkstra**。每个源起始持有
# `BASE_BUDGET + view_height[src]` 的视野预算；每跨一格扣掉目标格的
# `view_block[nb]`；预算仍 ≥ 0 则该格可见。取「剩余预算最大」的路径，
# 于是站在山上看得远、穿密林看得近，且天然沿地形起伏。
#
# 为什么不逐格 LOS 光线步进：便宜两个数量级，视觉上足够。真需要精确遮挡时，
# 后续可以离线预烘每格可视集 CSR，本类的对外接口不变。
#
# 预算是有界小整数（≤ BASE_BUDGET + MAX_VIEW_HEIGHT），所以用 bucket queue
# 从高预算向低预算扫描即可，无需二叉堆——每格最多入队常数次。
#
# 触发时机：country bootstrap 后一次 + 每次 country_committed。不进每日 tick。
#
# 输出（写回 MapData）：
#   visible_arr  0/1  当前可见
#   explored_arr 0/1  单调累积，进存档
#   fog_k_arr    0..255 知识度 k = 0.5*blur(explored) + 0.5*blur(visible)
#                供 enum_lut.a / 主地形灰化 / 迷雾层消费
#
# 本类是 GDScript 权威实现。按计划后续可下沉到 gdext/src/world_ext_vision.cpp，
# 届时保留本文件作为 fallback（项目一贯的「C++ 优先 + GDScript fallback」）。
class_name VisionSolver
extends RefCounted

const LF = LandformType.LF
const VEG = VegetationType.VEG

## 三态。UI 门控与迷雾表现都以此为准。
enum { FOG_UNEXPLORED = 0, FOG_EXPLORED = 1, FOG_VISIBLE = 2 }

## 基础视野预算。平原 view_block = 10，所以平地上大约看 4 格。
const BASE_BUDGET: int = 42
## 单格 view_height 的上限，用于 bucket 数组定尺。
const MAX_VIEW_HEIGHT: int = 32
## 知识度 blur 迭代次数。必须 ≥ 2：迷雾 shader 的噪声域扭曲最多位移 1 个 hex，
## 主地形早退阈值又要求「完全未探索」，靠这里的 2 环柔化留出安全边界。
const BLUR_ITERATIONS: int = 2

## landform → 观察者视高加成。水面视野开阔但站得低，只给很小的加成。
const _VIEW_HEIGHT_BY_LANDFORM: Dictionary = {
	LF.DEEP_OCEAN: 2, LF.OCEAN: 2, LF.COAST: 1, LF.LAKE: 1,
	LF.PLAIN: 0, LF.LOWLAND: 3, LF.HILL: 12, LF.MOUNTAIN: 22, LF.PEAK: 30,
	LF.DELTA: 0, LF.BADLANDS: 6, LF.SALT_FLAT: 0, LF.VOLCANO: 24,
	LF.PLATEAU: 15, LF.RIFT_VALLEY: -2, LF.CANYON: -4,
}

## landform → 视线穿透代价。水面最低（一望无际），峡谷/山地最高。
const _VIEW_BLOCK_BY_LANDFORM: Dictionary = {
	LF.DEEP_OCEAN: 7, LF.OCEAN: 7, LF.COAST: 8, LF.LAKE: 8,
	LF.PLAIN: 10, LF.LOWLAND: 11, LF.HILL: 16, LF.MOUNTAIN: 26, LF.PEAK: 32,
	LF.DELTA: 10, LF.BADLANDS: 15, LF.SALT_FLAT: 8, LF.VOLCANO: 28,
	LF.PLATEAU: 14, LF.RIFT_VALLEY: 19, LF.CANYON: 24,
}

## vegetation → 附加穿透代价。乔木密林最贵，草本几乎不挡。
const _VIEW_BLOCK_BY_VEGETATION: Dictionary = {
	VEG.NONE: 0, VEG.POLAR_DESERT: 0, VEG.TUNDRA: 1, VEG.ALPINE_TUNDRA: 1,
	VEG.ALPINE_MEADOW: 1, VEG.TAIGA: 9, VEG.BOREAL_SHRUB: 4,
	VEG.TEMPERATE_DECIDUOUS: 9, VEG.TEMPERATE_CONIFER: 10,
	VEG.TEMPERATE_GRASSLAND: 1, VEG.TEMPERATE_STEPPE: 1,
	VEG.MEDITERRANEAN_SHRUB: 4, VEG.SUBTROPICAL_FOREST: 11, VEG.SAVANNA: 3,
	VEG.TROPICAL_RAINFOREST: 14, VEG.TROPICAL_DRY_FOREST: 9,
	VEG.DESERT_SCRUB: 1, VEG.XERIC_DESERT: 0, VEG.OASIS_VEG: 4,
	VEG.MANGROVE: 10, VEG.SWAMP: 6, VEG.MARSH: 3,
	VEG.KELP_FOREST: 0, VEG.CORAL_REEF: 0,
}

const _MIN_BLOCK: int = 3
const _MAX_BLOCK: int = 60


# ─── 静态预烘（生成期一次）────────────────────────────────────────────

## 把 landform/vegetation 折成两张 256 项 U8 LUT 再逐格查表，避免在 per-cell
## 循环里做 Dictionary 查找。与 map_data 的 passable_sea_lut 同套路。
##
## 数据源双路径是必需的：本函数在 bake_world 末尾被调用，而
## `map.init_soa_from_bake()` 要到 bake_world 返回之后才跑，此时 SoA 还是空的，
## 只能读 HexCell（AoS）。后续从 solve() 懒补烘时 SoA 已就位，走更快的一路。
static func bake_static_fields(map: MapData, world: WorldData) -> Dictionary:
	var report := {"ok": false, "cells": 0, "reason": "", "source": ""}
	if map == null or world == null:
		report.reason = "missing_map_or_world"
		return report
	var n: int = map.cell_count()
	if n <= 0:
		report.reason = "empty_map"
		return report

	var lf_height := PackedByteArray(); lf_height.resize(256)
	var lf_block := PackedByteArray(); lf_block.resize(256)
	var veg_block := PackedByteArray(); veg_block.resize(256)
	for i in range(256):
		lf_height[i] = 0
		lf_block[i] = _MIN_BLOCK
		veg_block[i] = 0
	for key in _VIEW_HEIGHT_BY_LANDFORM:
		lf_height[int(key) & 0xFF] = clampi(int(_VIEW_HEIGHT_BY_LANDFORM[key]), 0, MAX_VIEW_HEIGHT)
	for key in _VIEW_BLOCK_BY_LANDFORM:
		lf_block[int(key) & 0xFF] = clampi(int(_VIEW_BLOCK_BY_LANDFORM[key]), _MIN_BLOCK, _MAX_BLOCK)
	for key in _VIEW_BLOCK_BY_VEGETATION:
		veg_block[int(key) & 0xFF] = clampi(int(_VIEW_BLOCK_BY_VEGETATION[key]), 0, _MAX_BLOCK)

	var heights := PackedByteArray(); heights.resize(n)
	var blocks := PackedByteArray(); blocks.resize(n)
	if map.landform_arr.size() >= n and map.vegetation_arr.size() >= n:
		var landform := map.landform_arr
		var vegetation := map.vegetation_arr
		for i in range(n):
			var lf: int = landform[i]
			heights[i] = lf_height[lf]
			blocks[i] = clampi(
				int(lf_block[lf]) + int(veg_block[vegetation[i]]), _MIN_BLOCK, _MAX_BLOCK)
		report.source = "soa"
	else:
		var cells: Array = map.iter_cells()
		if cells.size() < n:
			report.reason = "cell_array_not_built"
			return report
		for i in range(n):
			var cell = cells[i]
			if cell == null:
				heights[i] = 0
				blocks[i] = _MIN_BLOCK
				continue
			var lf_aos: int = int(cell.landform) & 0xFF
			heights[i] = lf_height[lf_aos]
			blocks[i] = clampi(
				int(lf_block[lf_aos]) + int(veg_block[int(cell.vegetation) & 0xFF]),
				_MIN_BLOCK, _MAX_BLOCK)
		report.source = "aos"
	world.cell_view_height = heights
	world.cell_view_block = blocks
	report.ok = true
	report.cells = n
	return report


# ─── 运行时解算 ───────────────────────────────────────────────────────

## 重算可见性并累积 explored。player_slot < 0（尚未建国）时全图不可见，
## 但已探索区保持不变——不能因为暂时没有领土就抹掉玩家进度。
## 返回统计信息，供诊断与测试断言。
static func solve(map: MapData, world: WorldData, player_slot: int) -> Dictionary:
	var report := {
		"ok": false, "reason": "", "visible": 0, "explored": 0,
		"sources": 0, "cells": 0, "elapsed_ms": 0.0,
	}
	if map == null or world == null:
		report.reason = "missing_map_or_world"
		return report
	var n: int = map.cell_count()
	if n <= 0:
		report.reason = "empty_map"
		return report
	if world.cell_view_block.size() < n or world.cell_view_height.size() < n:
		var baked: Dictionary = bake_static_fields(map, world)
		if not bool(baked.get("ok", false)):
			report.reason = "static_bake_failed:%s" % String(baked.get("reason", ""))
			return report
	if map.country_slot_arr.size() < n or not map.has_indices():
		report.reason = "country_or_indices_missing"
		return report
	_ensure_arrays(map, n)
	var previous_visible := map.visible_arr.duplicate()

	var t0 := Time.get_ticks_usec()
	var source_cells := PackedInt32Array()
	if player_slot >= 0:
		for i in range(n):
			if map.country_slot_arr[i] == player_slot:
				source_cells.append(i)
	var visible_report := compute_visible_for_sources(map, world, source_cells)
	if not bool(visible_report.get("ok", false)):
		report.reason = String(visible_report.get("reason", "visible_probe_failed"))
		return report
	var visible: PackedByteArray = visible_report.visible
	var explored := map.explored_arr
	var visible_count: int = 0
	var explored_count: int = 0
	var source_count: int = source_cells.size()
	var visibility_changed_cells := PackedInt32Array()
	var newly_visible_cells := PackedInt32Array()
	var newly_hidden_cells := PackedInt32Array()
	for i in range(n):
		var v: int = visible[i]
		var before: int = previous_visible[i] if i < previous_visible.size() else 0
		if v != before:
			visibility_changed_cells.append(i)
			if v != 0:
				newly_visible_cells.append(i)
			else:
				newly_hidden_cells.append(i)
		visible_count += v
		if v != 0:
			explored[i] = 1
		explored_count += explored[i]
	map.visible_arr = visible
	map.explored_arr = explored
	map.fog_k_arr = _compute_fog_k(map, visible, explored, n)
	map.fog_solved = true
	map.vision_revision += 1

	report.ok = true
	report.visible = visible_count
	report.explored = explored_count
	report.sources = source_count
	report.cells = n
	report.elapsed_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	report.visibility_changed_cells = visibility_changed_cells
	report.newly_visible_cells = newly_visible_cells
	report.newly_hidden_cells = newly_hidden_cells
	report.vision_revision = map.vision_revision
	return report


## 纯只读视野探针。出生点求解与正式首帧共用同一传播算法，且不受“关闭迷雾”
## 的全图直通开关影响。
static func compute_visible_for_sources(map: MapData, world: WorldData,
		source_cells: PackedInt32Array) -> Dictionary:
	if map == null or world == null:
		return {"ok": false, "reason": "missing_map_or_world"}
	var n := map.cell_count()
	if n <= 0 or not map.has_indices():
		return {"ok": false, "reason": "empty_or_unindexed_map"}
	if world.cell_view_block.size() < n or world.cell_view_height.size() < n:
		var baked := bake_static_fields(map, world)
		if not bool(baked.get("ok", false)):
			return {"ok": false, "reason": "static_bake_failed:%s" % String(
				baked.get("reason", ""))}
	for cell in source_cells:
		if cell < 0 or cell >= n:
			return {"ok": false, "reason": "source_cell_invalid", "cell": cell}
	return {
		"ok": true,
		"visible": _solve_visible_from_sources(map, world, source_cells, n),
		"sources": source_cells.size(),
	}


## 迷雾关闭时的直通路径：全图可见。让 UI 门控与 enum_lut.a 的消费点不需要
## 各自再判一次总开关——它们只认这三个数组。
static func mark_all_visible(map: MapData) -> Dictionary:
	if map == null:
		return {"ok": false, "reason": "missing_map", "visible": 0, "explored": 0}
	var n: int = map.cell_count()
	if n <= 0:
		return {"ok": false, "reason": "empty_map", "visible": 0, "explored": 0}
	_ensure_arrays(map, n)
	var changed := PackedInt32Array()
	var newly_visible := PackedInt32Array()
	for i in range(n):
		if map.visible_arr[i] == 0:
			changed.append(i)
			newly_visible.append(i)
		map.visible_arr[i] = 1
		map.explored_arr[i] = 1
		map.fog_k_arr[i] = 255
	map.fog_solved = true
	map.vision_revision += 1
	return {
		"ok": true, "reason": "fog_disabled", "visible": n, "explored": n,
		"sources": 0, "cells": n, "elapsed_ms": 0.0,
		"visibility_changed_cells": changed,
		"newly_visible_cells": newly_visible,
		"newly_hidden_cells": PackedInt32Array(),
		"vision_revision": map.vision_revision,
	}


## 三态查询，供 UI 门控。
## 数组未初始化（迷雾系统未接线 / 测试场景）时按 FOG_VISIBLE 处理，避免任何
## 消费点因为没跑过 solve 就把界面锁死。
static func fog_state(map: MapData, cell_idx: int) -> int:
	if map == null or cell_idx < 0:
		return FOG_VISIBLE
	if cell_idx >= map.visible_arr.size() or cell_idx >= map.explored_arr.size():
		return FOG_VISIBLE
	if map.visible_arr[cell_idx] != 0:
		return FOG_VISIBLE
	return FOG_EXPLORED if map.explored_arr[cell_idx] != 0 else FOG_UNEXPLORED


# --- 内部 -----------------------------------------------------

static func _ensure_arrays(map: MapData, n: int) -> void:
	if map.visible_arr.size() != n:
		map.visible_arr.resize(n)
	if map.explored_arr.size() != n:
		var old_size: int = map.explored_arr.size()
		map.explored_arr.resize(n)
		for i in range(old_size, n):
			map.explored_arr[i] = 0
	if map.fog_k_arr.size() != n:
		map.fog_k_arr.resize(n)


static func _solve_visible_from_sources(
	map: MapData, world: WorldData, source_cells: PackedInt32Array, n: int
) -> PackedByteArray:
	var visible := PackedByteArray()
	visible.resize(n)
	for i in range(n):
		visible[i] = 0
	if source_cells.is_empty():
		return visible

	var neighbors: PackedInt32Array = map.neighbor_indices_packed()
	var view_height: PackedByteArray = world.cell_view_height
	var view_block: PackedByteArray = world.cell_view_block

	# best[i] = 到达 i 时的最大剩余预算；-1 = 未到达。
	var best := PackedInt32Array()
	best.resize(n)
	for i in range(n):
		best[i] = -1

	var max_budget: int = BASE_BUDGET + MAX_VIEW_HEIGHT
	# 桶必须用引用语义的 Array 而不是 PackedInt32Array：嵌在 Array 里的 Packed
	# 数组读出来是 COW 副本，`buckets[b].append(x)` 会写进一个临时对象然后被丢弃。
	var buckets: Array = []
	buckets.resize(max_budget + 1)
	for b in range(max_budget + 1):
		buckets[b] = []

	for source in source_cells:
		var budget: int = clampi(BASE_BUDGET + int(view_height[source]), 0, max_budget)
		if budget > best[source]:
			best[source] = budget
			buckets[budget].append(source)

	# 从高预算向低预算扫描。跨一格必然扣掉 ≥ _MIN_BLOCK 的预算，所以只会往
	# 更低的桶里追加，当前桶在遍历期间不会被修改。
	for b in range(max_budget, -1, -1):
		var bucket: Array = buckets[b]
		var count: int = bucket.size()
		if count == 0:
			continue
		for bi in range(count):
			var idx: int = bucket[bi]
			if best[idx] != b:
				continue  # 已被更优路径取代的陈旧条目
			visible[idx] = 1
			var base_n: int = idx * 6
			for d in range(6):
				var nb: int = neighbors[base_n + d]
				if nb < 0:
					continue
				var nb_budget: int = b - int(view_block[nb])
				if nb_budget < 0 or nb_budget <= best[nb]:
					continue
				best[nb] = nb_budget
				buckets[nb_budget].append(nb)
	return visible


## k = 0.5 * blur(explored) + 0.5 * blur(visible)，量化到 0..255。
## 单调性由 visible ⊆ explored 保证：
##   未探索 → 0.0、已探索未可见 → 0.5、完全可见 → 1.0，中间值全是 blur 过渡带。
## blur 放在 CPU 是项目既有约定（world_data 的 dyn_atlas_smooth_buffer 注释：
## 「任何看起来需要邻域的视觉都由 baker 端预烘到 atlas，shader 单点采样」）。
static func _compute_fog_k(
	map: MapData, visible: PackedByteArray, explored: PackedByteArray, n: int
) -> PackedByteArray:
	var neighbors: PackedInt32Array = map.neighbor_indices_packed()
	var vis_f := PackedFloat32Array(); vis_f.resize(n)
	var exp_f := PackedFloat32Array(); exp_f.resize(n)
	for i in range(n):
		vis_f[i] = 1.0 if visible[i] != 0 else 0.0
		exp_f[i] = 1.0 if explored[i] != 0 else 0.0
	for _iter in range(BLUR_ITERATIONS):
		vis_f = _hex_box_blur(vis_f, neighbors, n)
		exp_f = _hex_box_blur(exp_f, neighbors, n)

	var out := PackedByteArray()
	out.resize(n)
	for i in range(n):
		var k: float = 0.5 * exp_f[i] + 0.5 * vis_f[i]
		out[i] = clampi(int(round(k * 255.0)), 0, 255)
	return out


## hex 邻域 box blur。自身权重 2，六个邻居各 1；图边缺失的邻居不计入分母，
## 避免南北极行被虚假地拉向 0。
static func _hex_box_blur(
	src: PackedFloat32Array, neighbors: PackedInt32Array, n: int
) -> PackedFloat32Array:
	var dst := PackedFloat32Array()
	dst.resize(n)
	for i in range(n):
		var sum: float = src[i] * 2.0
		var weight: float = 2.0
		var base_n: int = i * 6
		for d in range(6):
			var nb: int = neighbors[base_n + d]
			if nb < 0:
				continue
			sum += src[nb]
			weight += 1.0
		dst[i] = sum / weight
	return dst
