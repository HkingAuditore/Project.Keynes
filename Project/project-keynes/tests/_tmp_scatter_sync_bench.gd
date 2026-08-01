# 临时微基准：tick 末四轴 diff 的 GDScript 开销（对应 map_generator.sync_detail_scatter_after_tick）
# 用法: godot --path Project/project-keynes --script res://tests/_tmp_scatter_sync_bench.gd
extends SceneTree

func _init() -> void:
	var sizes: Array[int] = [2400, 6400, 25600]
	for n in sizes:
		_bench(n)
	quit()


func _make_arrays(n: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var out := {}
	for key in ["terrain", "landform", "vegetation", "cover"]:
		var a := PackedByteArray()
		a.resize(n)
		for i in range(n):
			a[i] = rng.randi() % 20
		out[key] = a
	return out


func _bench(n: int) -> void:
	var src := _make_arrays(n)
	# 快照 = 原样复制（无变化场景 = 每 tick 最常见路径）
	var snap: Dictionary = {}
	for k in src.keys():
		snap[k] = (src[k] as PackedByteArray).duplicate()

	# A) 当前实现形态（每轮 .size() + int() 转换）
	var reps := 200
	var t0 := Time.get_ticks_usec()
	var acc := 0
	for r in range(reps):
		var terrain_a: PackedByteArray = src["terrain"]
		var landform_a: PackedByteArray = src["landform"]
		var vegetation_a: PackedByteArray = src["vegetation"]
		var cover_a: PackedByteArray = src["cover"]
		var snap_t: PackedByteArray = snap["terrain"]
		var snap_l: PackedByteArray = snap["landform"]
		var snap_v: PackedByteArray = snap["vegetation"]
		var snap_c: PackedByteArray = snap["cover"]
		var changed := PackedInt32Array()
		for i in range(n):
			var dirty := false
			if i < vegetation_a.size() and int(snap_v[i]) != int(vegetation_a[i]):
				dirty = true
			elif i < landform_a.size() and int(snap_l[i]) != int(landform_a[i]):
				dirty = true
			elif i < cover_a.size() and int(snap_c[i]) != int(cover_a[i]):
				dirty = true
			elif i < terrain_a.size() and int(snap_t[i]) != int(terrain_a[i]):
				dirty = true
			if dirty:
				changed.append(i)
		acc += changed.size()
	var cur_us := float(Time.get_ticks_usec() - t0) / float(reps)

	# B) 微优化形态（hoist size、直接索引、单表达式）
	t0 = Time.get_ticks_usec()
	for r in range(reps):
		var terrain_a: PackedByteArray = src["terrain"]
		var landform_a: PackedByteArray = src["landform"]
		var vegetation_a: PackedByteArray = src["vegetation"]
		var cover_a: PackedByteArray = src["cover"]
		var snap_t: PackedByteArray = snap["terrain"]
		var snap_l: PackedByteArray = snap["landform"]
		var snap_v: PackedByteArray = snap["vegetation"]
		var snap_c: PackedByteArray = snap["cover"]
		var changed := PackedInt32Array()
		for i in range(n):
			if snap_v[i] != vegetation_a[i] or snap_l[i] != landform_a[i] \
					or snap_c[i] != cover_a[i] or snap_t[i] != terrain_a[i]:
				changed.append(i)
		acc += changed.size()
	var opt_us := float(Time.get_ticks_usec() - t0) / float(reps)

	# C) duplicate 开销（仅变化 tick 才付）
	t0 = Time.get_ticks_usec()
	for r in range(reps):
		var d0: PackedByteArray = (src["terrain"] as PackedByteArray).duplicate()
		var d1: PackedByteArray = (src["landform"] as PackedByteArray).duplicate()
		var d2: PackedByteArray = (src["vegetation"] as PackedByteArray).duplicate()
		var d3: PackedByteArray = (src["cover"] as PackedByteArray).duplicate()
		acc += d0.size() + d1.size() + d2.size() + d3.size()
	var dup_us := float(Time.get_ticks_usec() - t0) / float(reps)

	# D) memcmp 快路径：4× PackedByteArray ==（无变化 tick 的成本）
	t0 = Time.get_ticks_usec()
	for r in range(reps):
		var same: bool = (snap["terrain"] == src["terrain"]) \
				and (snap["landform"] == src["landform"]) \
				and (snap["vegetation"] == src["vegetation"]) \
				and (snap["cover"] == src["cover"])
		if not same:
			acc += 1
	var eq_us := float(Time.get_ticks_usec() - t0) / float(reps)

	print("[BENCH] n=%d current=%.1fus opt=%.1fus dup4=%.1fus eq4=%.1fus (acc=%d)" % [n, cur_us, opt_us, dup_us, eq_us, acc])
