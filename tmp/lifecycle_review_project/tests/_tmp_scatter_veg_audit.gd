extends SceneTree

# [scatter-veg-soak 2026-08-01] 临时浸泡探针（一次性，勿长期保留）。
# 验证运行期演替后散布实例是否仍与 vegetation_arr 一致:
#   T0: 生成后基准审计(A0)
#   连跑 N 天 daily tick + 帧泵排空 queue_detail_scatter_refresh
#   T1: 实际状态审计(A1, 原生 chunked 路径) vs 强制 GDScript 全量重建(B1=当前数据的真值)
# 若 A1≈B1 → 运行期刷新正确; 若 A1≠B1 → 增量刷新丢格/错位。
# 运行(真实窗口模式, 勿加 --quit):
#   godot --path Project/project-keynes --script res://tests/_tmp_scatter_veg_audit.gd

const SOAK_DAYS := 60

const VEG_NAMES := {
	0:"NONE",1:"POLAR_DESERT",2:"TUNDRA",3:"ALPINE_TUNDRA",4:"ALPINE_MEADOW",
	5:"TAIGA",6:"BOREAL_SHRUB",7:"TEMP_DECID",8:"TEMP_CONIFER",9:"TEMP_GRASS",
	10:"TEMP_STEPPE",11:"MED_SHRUB",12:"SUBTROP_FOREST",13:"SAVANNA",14:"RAINFOREST",
	15:"TROP_DRY_FOREST",16:"DESERT_SCRUB",17:"XERIC_DESERT",18:"OASIS",19:"MANGROVE",
	20:"SWAMP",21:"MARSH",22:"KELP",23:"CORAL",24:"CLOUD_FOREST",25:"MONSOON_FOREST",
	26:"SEAGRASS",27:"PEAT_BOG",
}

# 与 shrub_layer._tree_vegetation_weight 完全一致
static func _tree_w(v: int) -> float:
	match v:
		14, 12: return 1.22
		7, 8: return 1.08
		5: return 0.98
		15: return 0.82
		20, 19: return 0.64
		13: return 0.28
		6, 11: return 0.12
		9, 10: return 0.05
		16, 17, 0, 22, 23: return 0.0
	return 0.04


func _init() -> void:
	_bootstrap()


func _bootstrap() -> void:
	while get_root() == null or not get_root().is_inside_tree():
		await process_frame
	await process_frame
	var code := await _run()
	quit(code)


func _run() -> int:
	print("[SOAK] ==== scatter x vegetation runtime-drift soak ====")
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var renderer := HexRenderer.new()
	renderer.visual_quality = 2
	get_root().add_child(renderer)
	await process_frame

	var camera := MapCamera.new()
	get_root().add_child(camera)

	var host := WorldRuntimeHost.new()
	host.generate_test_economy_data = false
	get_root().add_child(host)
	host.configure(renderer, camera, clock)

	# NewGameConfig 默认 standard 世界(60x40/seed 1), 与用户正式开局同型
	Engine.set_meta(WorldRuntimeHost.WORLD_SETUP_META, {
		"source": "world_setup",
		"base": {
			"map_width": 60, "map_height": 40, "initial_seed": 1,
			"sea_level": 0.42, "num_continents": 2, "continent_size": 0.9,
			"generate_test_economy_data": false,
		},
	})
	await host.generate_world(-1)
	Engine.remove_meta(WorldRuntimeHost.WORLD_SETUP_META)

	var world: WorldData = host.world_data()
	var map = renderer._map
	if map == null and world != null and "map_data" in world:
		map = world.map_data
	if map == null and host.generator() != null and "_map" in host.generator():
		map = host.generator()._map
	if world == null or map == null:
		push_error("[SOAK] world/map missing after generation")
		return 1

	var n_cells: int = map.cell_count()
	var hex_size: float = renderer.hex_size
	var grid_w: int = int(map.width)
	print("[SOAK] map %dx%d cells=%d" % [grid_w, int(map.height), n_cells])

	var ctx := _make_spatial_ctx(map, hex_size)

	# T0 基准
	var v0: PackedByteArray = map.vegetation_arr.duplicate()
	var a0 := _audit_all(renderer, map, ctx, "A0")

	# ─── 浸泡: N 天 daily tick + 帧泵排空散布刷新队列 ───
	var t_soak := Time.get_ticks_msec()
	for day in range(1, SOAK_DAYS + 1):
		clock.current_day = float(day)
		var phase := clock.season_phase_for_day(day)
		host.run_daily_tick(day, phase)
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier(clock) and pulses < 16:
			clock.simulation_backpressure_pulse.emit(day)
			pulses += 1
		# 帧泵: 让 renderer._process 排空 detail refresh 队列
		var frames := 0
		while not _refresh_queue_idle(renderer) and frames < 120:
			await process_frame
			frames += 1
		for extra in range(3):
			await process_frame
		if day % 15 == 0 or day == 1:
			var drift := _veg_drift_count(v0, map.vegetation_arr)
			print("[SOAK] day=%d veg_drift_vs_T0=%d frames_today=%d" % [day, drift, frames])
	print("[SOAK] soak done in %d ms" % (Time.get_ticks_msec() - t_soak))

	# T1 实际状态(原生 chunked 路径在屏幕上的真实现状)
	var v1: PackedByteArray = map.vegetation_arr.duplicate()
	var a1 := _audit_all(renderer, map, ctx, "A1")

	# B1: 强制 GDScript 全量重建 = 当前数据应然
	var b1 := _audit_all_forced_gdscript(renderer, map, world, hex_size, "B1")

	# ─── 量化错位 ───
	_report_drift(v0, v1)
	_report_tree_mismatch(map, a1, b1)
	print("[SOAK] ==== soak done ====")
	return 0


func _make_spatial_ctx(map, hex_size: float) -> Dictionary:
	var n_cells: int = map.cell_count()
	var bucket_size := 1.5
	var grid := {}
	for i in range(n_cells):
		if i >= map.cell_pos_x_arr.size():
			break
		var bk := "%d_%d" % [int(floor(map.cell_pos_x_arr[i] / bucket_size)),
			int(floor(map.cell_pos_y_arr[i] / bucket_size))]
		if not grid.has(bk):
			grid[bk] = []
		(grid[bk] as Array).append(i)
	var wrap_norm := HexUtils.wrap_period_x(int(map.width), hex_size) / maxf(hex_size, 0.001)
	return {"grid": grid, "bucket": bucket_size, "wrap": wrap_norm}


func _audit_all(renderer, map, ctx: Dictionary, tag: String) -> Dictionary:
	var out := {}
	for layer in renderer._detail_layers:
		if layer == null:
			continue
		var cellmap := {}
		var total := _capture_layer_cellmap(layer, map, ctx, cellmap)
		out[layer.name] = {"kind": layer._detail_kind(), "cellmap": cellmap, "total": total}
		var vcounts := {}
		for ci in cellmap.keys():
			var v := int(map.vegetation_arr[int(ci)])
			vcounts[v] = int(vcounts.get(v, 0)) + int(cellmap[ci])
		print("[SOAK] %s %s kind=%d path=%s inst=%d | %s" % [
			tag, layer.name, layer._detail_kind(), str(layer._last_scatter_path),
			total, _fmt_top(vcounts, 6)])
	return out


func _audit_all_forced_gdscript(renderer, map, world, hex_size: float, tag: String) -> Dictionary:
	var out := {}
	for layer in renderer._detail_layers:
		if layer == null:
			continue
		var saved_ext = layer._world_ext
		layer.set_chunked_multimesh_enabled(false, 8)
		layer._world_ext = null
		layer.setup(map, world, world.world_bounds, hex_size, renderer.visual_quality)
		var cellmap := {}
		for raw_ci in layer._instance_cell_indices:
			var ci := int(raw_ci)
			if ci >= 0 and ci < map.cell_count():
				cellmap[ci] = int(cellmap.get(ci, 0)) + 1
		out[layer.name] = {"kind": layer._detail_kind(), "cellmap": cellmap,
			"total": layer._instance_cell_indices.size()}
		var vcounts := {}
		for ci in cellmap.keys():
			var v := int(map.vegetation_arr[int(ci)])
			vcounts[v] = int(vcounts.get(v, 0)) + int(cellmap[ci])
		print("[SOAK] %s %s kind=%d path=%s inst=%d | %s" % [
			tag, layer.name, layer._detail_kind(), str(layer._last_scatter_path),
			layer._instance_cell_indices.size(), _fmt_top(vcounts, 6)])
		layer._world_ext = saved_ext
	return out


func _capture_layer_cellmap(layer, map, ctx: Dictionary, cellmap: Dictionary) -> int:
	var hex_size: float = layer._hex_size
	var total := 0
	var nodes: Array = []
	if not layer._chunk_nodes.is_empty():
		for cid in layer._chunk_nodes.keys():
			var node: MultiMeshInstance2D = layer._chunk_nodes[cid]
			if node != null and is_instance_valid(node) and node.multimesh != null:
				nodes.append(node)
	elif layer._multimesh != null and layer._mmi != null:
		nodes.append(layer._mmi)
	for node in nodes:
		var mm: MultiMesh = node.multimesh
		for i in range(mm.instance_count):
			var wp: Vector2 = node.to_global(mm.get_instance_transform_2d(i).origin)
			var np := wp / maxf(hex_size, 0.001)
			if float(ctx["wrap"]) > 0.0 and (np.x < -0.5 or np.x >= float(ctx["wrap"]) + 0.5):
				continue
			var ci := _nearest_cell(np, map, ctx)
			if ci < 0:
				continue
			cellmap[ci] = int(cellmap.get(ci, 0)) + 1
			total += 1
	return total


func _nearest_cell(np: Vector2, map, ctx: Dictionary) -> int:
	var bucket: float = ctx["bucket"]
	var grid: Dictionary = ctx["grid"]
	var bx := int(floor(np.x / bucket))
	var by := int(floor(np.y / bucket))
	var best := -1
	var best_d := INF
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var bk := "%d_%d" % [bx + dx, by + dy]
			if not grid.has(bk):
				continue
			for ci in grid[bk]:
				var d: float = np.distance_squared_to(Vector2(
					map.cell_pos_x_arr[ci], map.cell_pos_y_arr[ci]))
				if d < best_d:
					best_d = d
					best = int(ci)
	return best


func _veg_drift_count(v0: PackedByteArray, v1: PackedByteArray) -> int:
	var n := 0
	for i in range(mini(v0.size(), v1.size())):
		if v0[i] != v1[i]:
			n += 1
	return n


func _report_drift(v0: PackedByteArray, v1: PackedByteArray) -> void:
	var flows := {}
	for i in range(mini(v0.size(), v1.size())):
		if v0[i] == v1[i]:
			continue
		var key := "%s>%s" % [str(VEG_NAMES.get(v0[i], v0[i])), str(VEG_NAMES.get(v1[i], v1[i]))]
		flows[key] = int(flows.get(key, 0)) + 1
	var pairs: Array = []
	for k in flows.keys():
		pairs.append([int(flows[k]), k])
	pairs.sort()
	pairs.reverse()
	print("[SOAK] drift cells=%d top flows:" % pairs.size() if false else "")
	var drift_total := 0
	for p in pairs:
		drift_total += p[0]
	var tops: Array = []
	for p in pairs.slice(0, 10):
		tops.append("%s:%d" % [p[1], p[0]])
	print("[SOAK] drift cells=%d top: %s" % [drift_total, ", ".join(tops)])


func _report_tree_mismatch(map, a1: Dictionary, b1: Dictionary) -> void:
	for layer_name in a1.keys():
		if int(a1[layer_name]["kind"]) != 1:
			continue
		var a_map: Dictionary = a1[layer_name]["cellmap"]
		var b_map: Dictionary = b1.get(layer_name, {}).get("cellmap", {})
		var bad_a := 0
		var bad_a_cells := []
		for ci in a_map.keys():
			var v := int(map.vegetation_arr[int(ci)])
			if _tree_w(v) <= 0.0:
				bad_a += int(a_map[ci])
				if bad_a_cells.size() < 8:
					bad_a_cells.append("%d:%s" % [int(ci), str(VEG_NAMES.get(v, v))])
		var bad_b := 0
		for ci in b_map.keys():
			var v := int(map.vegetation_arr[int(ci)])
			if _tree_w(v) <= 0.0:
				bad_b += int(b_map[ci])
		# 森林秃格: 陆地 + 树权重>=0.8 + 活力度>=0.12, A/B 两侧各自零实例的格数
		var bald_a := 0
		var bald_b := 0
		var worthy := 0
		for ci in range(map.cell_count()):
			if ci >= map.vegetation_arr.size():
				break
			if int(map.is_water_arr[ci]) != 0:
				continue
			var v := int(map.vegetation_arr[ci])
			if _tree_w(v) < 0.8:
				continue
			if ci < map.vegetation_vitality_arr.size() and float(map.vegetation_vitality_arr[ci]) < 0.12:
				continue
			worthy += 1
			if not a_map.has(ci):
				bald_a += 1
			if not b_map.has(ci):
				bald_b += 1
		print("[SOAK] TREE mismatch %s: A1_trees_on_zero_weight=%d (cells: %s) | B1_same_metric=%d" % [
			layer_name, bad_a, ", ".join(bad_a_cells), bad_b])
		print("[SOAK] TREE bald %s: worthy_cells=%d A1_bald=%d B1_bald=%d" % [
			layer_name, worthy, bald_a, bald_b])


func _fmt_top(vcounts: Dictionary, k: int) -> String:
	var pairs: Array = []
	for v in vcounts.keys():
		pairs.append([int(vcounts[v]), int(v)])
	pairs.sort()
	pairs.reverse()
	var parts: Array = []
	for p in pairs.slice(0, k):
		parts.append("%s:%d" % [str(VEG_NAMES.get(p[1], p[1])), p[0]])
	return ", ".join(parts)


func _refresh_queue_idle(renderer) -> bool:
	return renderer._detail_refresh_queue.is_empty() \
		and renderer._detail_refresh_batches.is_empty() \
		and renderer._detail_refresh_indices.is_empty()


func _has_hard_barrier(clock: WorldClock) -> bool:
	return clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or clock._simulation_backpressure_sources.has(&"economy_day_barrier")
