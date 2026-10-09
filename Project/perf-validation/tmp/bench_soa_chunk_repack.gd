@tool
extends EditorScript

# ════════════════════════════════════════════════════════════════════
# bench_soa_chunk_repack.gd — DOTS-B0 SANDBOX EXPERIMENT
# ════════════════════════════════════════════════════════════════════
#
# 单一职责：在**纯 GDScript**沙盒里用 PackedFloat32Array 模拟"按 archetype
# 物理重排到独立 chunk"的内存布局，量化在 stencil 类算子上：
#   1) 算法是否能 bit-equal 复刻 vanilla 的 LAND 子集
#   2) 重排本身（assign + scatter back）的开销有多大
#   3) chunked hot loop 的代码复杂度成本（看代码行数和分支结构）
#
# 与 A1（archetype-as-logical-filter）的关键区别：
#   * A1 在 cell-id 自然顺序上加 `if arch[i] != target: continue` —— 邻居访问
#     被跳过的 OCEAN cell 打散，cache 命中下降。
#   * B0 把 LAND cells 物理上聚集到独立数组 temp_land[N_land]，并预先重映射
#     邻居索引到 chunk-local —— hot loop 完全顺序访问 temp_land[]。
#
# 注意：GDScript 不会复现 C++ 真实的 cache 收益（PackedFloat32Array 的 [i]
# 访问受解释器主导，cache miss 不是瓶颈）。本实验**不**追求加速数字——它只
# 验证三件事：算法可行性、重排开销、代码复杂度。如果连这三项都不通过，
# C++ 端就完全不必启动 B 阶段。
#
# 四个模式：
#   A. interleaved        — 基线：cell-id 自然顺序 + LAND 邻居 fallback（保证语义
#                           与 C/D 一致；OCEAN cell 在 A 里透传原值，不参与演化）
#   B. filtered_in_place  — A1 同款：自然顺序 + `if water[i]` early-skip 分支 +
#                           LAND 邻居 fallback（与 A 等价但多一次 branch test）
#   C. chunked            — B0 主体：LAND 物理聚集到 temp_land[]，
#                           邻居索引预重映射为 chunk-local（跨 chunk 邻居
#                           走 fallback：用 self 替代）
#   D. chunked_scatter    — C + 末尾把 out_land[] 散回 cell-id 顺序数组
#
# Bit-equal 契约：
#   * A / B / D 的 LAND-cell 子集（按 cell-id 顺序）逐字节相等
#   * A 的 LAND-cell 子集 ≡ C 的 out_land[]（按 chunk2cell 反向映射后）
#   * tolerance = 0（纯加减乘 + clamp，无超越函数）
#
# 输入参数（可改）：
#   * 三种 grid（与 A1 一致）：32×32 / 64×64 / 128×128
#   * 三种 ocean 比例：10% / 30% / 70%（10% 接近真实地图、70% 是极端水世界）
#   * iter = 4（stencil 多次迭代以放大重排相对开销）
#
# 输出：
#   * 每行报 4 模式 µs，对照 A 的 ratio
#   * 报 "repack overhead µs"（建 chunk + 写回时间）
#   * 报 "loop body LOC"（chunked hot loop 是否显著更长）
#   * bit-equal PASS/FAIL 总判定
#
# 配套阅读：
#   docs/dots-experiment-report.md §2.4 / §4 选项丙
#   tmp/bench_archetype_filter.gd（A1，不建议直接跑两份；本 bench 是 B0 阶段）
# ════════════════════════════════════════════════════════════════════

# ── 实验配置 ──
const TOLERANCE: float = 0.0  # 纯加减乘 + clamp，bit-equal 严格

const GRID_DIMS: Array = [
	[32, 32],
	[64, 64],
	[128, 128],
]
const OCEAN_RATIOS: Array = [10, 30, 70]   # 百分比
const ITER: int = 4
const KR: int = 2     # 邻居半径，固定 1（直接邻居）即可，KR 这里只用作签名占位

# stencil 系数（任意选取，保证 A 自身有信号）
const STENCIL_DECAY: float = 0.85
const STENCIL_GAIN: float = 0.5


# ════════════════════════════════════════════════════════════════════
# Entry
# ════════════════════════════════════════════════════════════════════
func _run() -> void:
	print("=== bench_soa_chunk_repack — DOTS-B0 SANDBOX ===")
	print("Grids: %s × ocean_ratios=%s%% × iter=%d"
		% [str(GRID_DIMS), str(OCEAN_RATIOS), ITER])
	print("Note: GDScript-only sandbox, NOT a real cache-locality bench.")
	print("       Goal = algorithmic feasibility + repack overhead + LOC delta.")
	print("")

	# ─── Bit-equal 块（小规模 + 单 ratio）─────────────────────────
	var be_w: int = 32
	var be_h: int = 32
	var be_ratio: int = 30
	var be_n: int = be_w * be_h
	var be_temp: PackedFloat32Array = _make_temp_input(be_w, be_h)
	var be_water: PackedByteArray = _make_water_mask(be_w, be_h, be_ratio)

	var out_a: PackedFloat32Array = _stencil_interleaved(be_temp, be_water, be_w, be_h, ITER)
	var out_b: PackedFloat32Array = _stencil_filtered_in_place(be_temp, be_water, be_w, be_h, ITER)
	var pack_c = _build_chunk(be_temp, be_water, be_w, be_h)
	var out_c_chunk: PackedFloat32Array = _stencil_chunked(pack_c, be_w, be_h, ITER)
	var out_d: PackedFloat32Array = _stencil_chunked_scatter(be_temp, be_water, be_w, be_h, ITER)

	var be_a_vs_c: bool = _check_land_subset_bit_equal(out_a, out_c_chunk, pack_c, be_water, be_n)
	var be_a_vs_d: bool = _check_land_subset_bit_equal_full(out_a, out_d, be_water, be_n)
	# B 是 in-place filter：LAND cells 应该 ≡ A 的 LAND cells（OCEAN cells B 写 0，A 写 stencil）
	var be_a_vs_b_land: bool = _check_land_subset_bit_equal_full(out_a, out_b, be_water, be_n)

	print("─── Bit-equal: 32x32, ocean=30%% ───")
	print("  A (interleaved) vs B (filtered_in_place) on LAND cells: " + ("PASS" if be_a_vs_b_land else "FAIL"))
	print("  A (interleaved) vs C (chunked)           on LAND cells: " + ("PASS" if be_a_vs_c else "FAIL"))
	print("  A (interleaved) vs D (chunked_scatter)   on LAND cells: " + ("PASS" if be_a_vs_d else "FAIL"))
	print("")

	# ─── Perf 表（grid × ratio × 4 模式）─────────────────────────
	print("─── Perf table (grid × ocean%% × 4 modes) ───")
	print("| grid       | ocean%% | mode               | µs        | vs A      | repack µs |")
	print("|------------|--------|--------------------|-----------|-----------|-----------|")

	for gd in GRID_DIMS:
		var w: int = int(gd[0])
		var h: int = int(gd[1])
		for ratio in OCEAN_RATIOS:
			var temp: PackedFloat32Array = _make_temp_input(w, h)
			var water: PackedByteArray = _make_water_mask(w, h, ratio)

			# A. interleaved
			var t0_a: int = Time.get_ticks_usec()
			var _a_out = _stencil_interleaved(temp, water, w, h, ITER)
			var us_a: int = Time.get_ticks_usec() - t0_a

			# B. filtered_in_place
			var t0_b: int = Time.get_ticks_usec()
			var _b_out = _stencil_filtered_in_place(temp, water, w, h, ITER)
			var us_b: int = Time.get_ticks_usec() - t0_b

			# C. chunked（不计 scatter；report 'repack µs' = build_chunk）
			var t_pack0: int = Time.get_ticks_usec()
			var pack: Dictionary = _build_chunk(temp, water, w, h)
			var us_pack: int = Time.get_ticks_usec() - t_pack0

			var t0_c: int = Time.get_ticks_usec()
			var _c_out = _stencil_chunked(pack, w, h, ITER)
			var us_c: int = Time.get_ticks_usec() - t0_c

			# D. chunked + scatter back（含 build + scatter，最完整路径）
			var t0_d: int = Time.get_ticks_usec()
			var _d_out = _stencil_chunked_scatter(temp, water, w, h, ITER)
			var us_d: int = Time.get_ticks_usec() - t0_d

			var grid_str: String = str(w) + "x" + str(h)
			var rA: String = "1.00x"
			var rB: String = ("%5.2fx" % (float(us_b) / float(us_a))) if us_a > 0 else "  n/a"
			var rC: String = ("%5.2fx" % (float(us_c) / float(us_a))) if us_a > 0 else "  n/a"
			var rD: String = ("%5.2fx" % (float(us_d) / float(us_a))) if us_a > 0 else "  n/a"

			print("| %-10s | %5d%% | A interleaved      | %9d | %9s | %9s |"
				% [grid_str, ratio, us_a, rA, "—"])
			print("| %-10s | %5d%% | B filtered_inplace | %9d | %9s | %9s |"
				% [grid_str, ratio, us_b, rB, "—"])
			print("| %-10s | %5d%% | C chunked (pure)   | %9d | %9s | %9d |"
				% [grid_str, ratio, us_c, rC, us_pack])
			print("| %-10s | %5d%% | D chunked+scatter  | %9d | %9s | %9d |"
				% [grid_str, ratio, us_d, rD, us_pack])

	print("")
	# ─── LOC 指标（写死的代码体积，不动态计算）─────────────────
	print("─── Loop body LOC（hot path 实现复杂度，不含通用 helper）───")
	print("  A interleaved      : ~18 LOC (5-point stencil + LAND-aware fallback)")
	print("  B filtered_inplace : ~19 LOC (A + early-skip branch on water[i])")
	print("  C chunked          : ~13 LOC (4 nb-indices already chunk-local; no water test)")
	print("  D chunked+scatter  : ~13 + ~25 LOC (C + build_chunk + scatter back loop)")
	print("  → A/B 因为要 LAND-aware 不得不带分支；C 在 hot loop 里完全无分支")
	print("    （水/陆边界已被 build_chunk 折叠为 self-index）。")
	print("    代价：C 需要一张 nb_chunk_idx 表 = n_land × 4 × i32（一次性建）。")

	print("")
	var overall_pass: bool = be_a_vs_b_land and be_a_vs_c and be_a_vs_d
	print("[bench_soa_chunk_repack] DONE — bit-equal=" + ("PASS" if overall_pass else "FAIL"))


# ════════════════════════════════════════════════════════════════════
# Stencil A — interleaved baseline (LAND-aware)
# ════════════════════════════════════════════════════════════════════
# in-place ping-pong on cell-id natural order.
#
# 重要修正（2026-05-12）：A 必须和 B/C/D 在 LAND cell 上看到的邻居规则一致。
#   * LAND cell：邻居是 LAND → 用邻居值；邻居是 OCEAN → fallback 到 self
#       （与 C 的 nb_chunk[-1]→self 折叠等价）。
#   * OCEAN cell：保持原值不变（不参与 stencil；与 B 的 dst[i]=0 不同——
#       这里 A 不写 0 是因为后续 bit-equal 校验只取 LAND 子集，OCEAN 怎样无所谓；
#       关键是 A 在 LAND cell 上不能从 OCEAN 邻居"漏入"温度）。
#
# Kernel: out[i] = decay * temp[i] + gain * (avg_neighbour - temp[i])
# 5-point stencil (N/S/E/W), clamp-to-edge + clamp-to-LAND.
func _stencil_interleaved(temp_in: PackedFloat32Array, water: PackedByteArray,
		w: int, h: int, iter: int) -> PackedFloat32Array:
	var n: int = w * h
	var src: PackedFloat32Array = temp_in.duplicate()
	var dst: PackedFloat32Array = PackedFloat32Array()
	dst.resize(n)
	for _it in range(iter):
		for y in range(h):
			for x in range(w):
				var i: int = y * w + x
				if water[i] != 0:
					dst[i] = src[i]  # OCEAN: 透传，不参与演化
					continue
				var iw: int = i - 1 if x > 0 else i
				var ie: int = i + 1 if x < w - 1 else i
				var inn: int = i - w if y > 0 else i
				var iss: int = i + w if y < h - 1 else i
				# 跨 LAND/OCEAN 边界 → fallback 到 self（与 C 的 chunk fallback 等价）
				if water[iw] != 0: iw = i
				if water[ie] != 0: ie = i
				if water[inn] != 0: inn = i
				if water[iss] != 0: iss = i
				var avg: float = 0.25 * (src[iw] + src[ie] + src[inn] + src[iss])
				dst[i] = STENCIL_DECAY * src[i] + STENCIL_GAIN * (avg - src[i])
		var tmp: PackedFloat32Array = src
		src = dst
		dst = tmp
	return src


# ════════════════════════════════════════════════════════════════════
# Stencil B — filtered in-place (A1-style logical archetype filter)
# ════════════════════════════════════════════════════════════════════
# Same natural ordering as A, but adds an `if water[i]: continue` branch
# (we透传 OCEAN cell 的原值，与 A 一致)，并且 LAND cell 在采邻居时若
# 邻居是 OCEAN 也 fallback 到 self —— 这样 LAND 子集才与 A/C/D bit-equal。
#
# 这正是 A1 archetype-as-filter 的产线形态：early-skip + 邻居 fallback。
func _stencil_filtered_in_place(temp_in: PackedFloat32Array, water: PackedByteArray,
		w: int, h: int, iter: int) -> PackedFloat32Array:
	var n: int = w * h
	var src: PackedFloat32Array = temp_in.duplicate()
	var dst: PackedFloat32Array = PackedFloat32Array()
	dst.resize(n)
	for _it in range(iter):
		for y in range(h):
			for x in range(w):
				var i: int = y * w + x
				if water[i] != 0:
					dst[i] = src[i]  # OCEAN 透传（与 A 一致）
					continue
				var iw: int = i - 1 if x > 0 else i
				var ie: int = i + 1 if x < w - 1 else i
				var inn: int = i - w if y > 0 else i
				var iss: int = i + w if y < h - 1 else i
				if water[iw] != 0: iw = i
				if water[ie] != 0: ie = i
				if water[inn] != 0: inn = i
				if water[iss] != 0: iss = i
				var avg: float = 0.25 * (src[iw] + src[ie] + src[inn] + src[iss])
				dst[i] = STENCIL_DECAY * src[i] + STENCIL_GAIN * (avg - src[i])
		var tmp: PackedFloat32Array = src
		src = dst
		dst = tmp
	return src


# ════════════════════════════════════════════════════════════════════
# Build chunk —— "SoA 物理重排" 的核心：把 LAND cells 物理聚集到独立数组，
# 同时预先把每个 LAND cell 的 4 邻居（N/S/E/W）重映射到 chunk-local 索引。
# 跨 archetype 的邻居（即邻居是 OCEAN）写 -1，hot loop 用 self fallback。
#
# 返回：
#   {
#     "n_land": int,
#     "temp_land": PackedFloat32Array,             # [n_land]
#     "nb_chunk":  PackedInt32Array,               # [n_land * 4]   N/S/E/W
#     "chunk2cell": PackedInt32Array,              # [n_land] → cell_id
#     "cell2chunk": PackedInt32Array,              # [n] → chunk_idx or -1
#   }
# ════════════════════════════════════════════════════════════════════
func _build_chunk(temp_in: PackedFloat32Array, water: PackedByteArray,
		w: int, h: int) -> Dictionary:
	var n: int = w * h

	var cell2chunk: PackedInt32Array = PackedInt32Array()
	cell2chunk.resize(n)
	# Pass 1: 数 LAND 数量、生成 cell_id → chunk_idx 映射
	var n_land: int = 0
	for i in range(n):
		if water[i] == 0:
			cell2chunk[i] = n_land
			n_land += 1
		else:
			cell2chunk[i] = -1

	var temp_land: PackedFloat32Array = PackedFloat32Array()
	temp_land.resize(n_land)
	var chunk2cell: PackedInt32Array = PackedInt32Array()
	chunk2cell.resize(n_land)
	var nb_chunk: PackedInt32Array = PackedInt32Array()
	nb_chunk.resize(n_land * 4)

	# Pass 2: 写入 temp_land、chunk2cell、邻居重映射
	for y in range(h):
		for x in range(w):
			var cid: int = y * w + x
			if water[cid] != 0:
				continue
			var ck: int = cell2chunk[cid]
			temp_land[ck] = temp_in[cid]
			chunk2cell[ck] = cid
			# 4 邻居（W/E/N/S），跨 chunk 邻居映射到 -1
			var iw: int = cid - 1 if x > 0 else cid
			var ie: int = cid + 1 if x < w - 1 else cid
			var inn: int = cid - w if y > 0 else cid
			var iss: int = cid + w if y < h - 1 else cid
			# 注：边界 fallback 时 iw/ie/inn/iss 仍是 LAND（与 A 行为一致）
			# 跨 chunk 的 fallback：邻居是 OCEAN → 用 self
			nb_chunk[ck * 4 + 0] = cell2chunk[iw] if cell2chunk[iw] >= 0 else ck
			nb_chunk[ck * 4 + 1] = cell2chunk[ie] if cell2chunk[ie] >= 0 else ck
			nb_chunk[ck * 4 + 2] = cell2chunk[inn] if cell2chunk[inn] >= 0 else ck
			nb_chunk[ck * 4 + 3] = cell2chunk[iss] if cell2chunk[iss] >= 0 else ck

	return {
		"n_land": n_land,
		"temp_land": temp_land,
		"nb_chunk": nb_chunk,
		"chunk2cell": chunk2cell,
		"cell2chunk": cell2chunk,
	}


# ════════════════════════════════════════════════════════════════════
# Stencil C — chunked (pure，不含 scatter back)
# ════════════════════════════════════════════════════════════════════
# Pure chunk-local hot loop. 邻居全部走 chunk-local 索引（跨 chunk 已被
# build 阶段折叠为 self）。这是"理论上"最 cache-friendly 的形态，但 GDScript
# 看不到收益（解释器主导）。
func _stencil_chunked(pack: Dictionary, _w: int, _h: int, iter: int) -> PackedFloat32Array:
	var n_land: int = int(pack.n_land)
	var nb: PackedInt32Array = pack.nb_chunk
	var src: PackedFloat32Array = (pack.temp_land as PackedFloat32Array).duplicate()
	var dst: PackedFloat32Array = PackedFloat32Array()
	dst.resize(n_land)
	for _it in range(iter):
		for ck in range(n_land):
			var b: int = ck * 4
			var iw: int = nb[b]
			var ie: int = nb[b + 1]
			var inn: int = nb[b + 2]
			var iss: int = nb[b + 3]
			var avg: float = 0.25 * (src[iw] + src[ie] + src[inn] + src[iss])
			dst[ck] = STENCIL_DECAY * src[ck] + STENCIL_GAIN * (avg - src[ck])
		var tmp: PackedFloat32Array = src
		src = dst
		dst = tmp
	return src


# ════════════════════════════════════════════════════════════════════
# Stencil D — chunked + scatter back（最完整路径）
# ════════════════════════════════════════════════════════════════════
# 包含 build_chunk + chunked stencil + scatter back 到 cell-id 顺序数组。
# 这是真实业务里"接 baker / 接其他系统"必须支付的总成本。
func _stencil_chunked_scatter(temp_in: PackedFloat32Array, water: PackedByteArray,
		w: int, h: int, iter: int) -> PackedFloat32Array:
	var pack: Dictionary = _build_chunk(temp_in, water, w, h)
	var land_out: PackedFloat32Array = _stencil_chunked(pack, w, h, iter)
	var n: int = w * h
	var out_full: PackedFloat32Array = PackedFloat32Array()
	out_full.resize(n)
	# OCEAN 默认 0；LAND 从 chunk 散回
	var n_land: int = int(pack.n_land)
	var c2c: PackedInt32Array = pack.chunk2cell
	for ck in range(n_land):
		out_full[c2c[ck]] = land_out[ck]
	return out_full


# ════════════════════════════════════════════════════════════════════
# Bit-equal helpers
# ════════════════════════════════════════════════════════════════════

# A 的 LAND-cell 子集 vs C 的 chunk 数组（按 chunk2cell 反向映射）
func _check_land_subset_bit_equal(out_a: PackedFloat32Array,
		out_c_chunk: PackedFloat32Array, pack: Dictionary,
		water: PackedByteArray, n: int) -> bool:
	var n_land: int = int(pack.n_land)
	var c2c: PackedInt32Array = pack.chunk2cell
	var fails: int = 0
	for ck in range(n_land):
		var cid: int = c2c[ck]
		if water[cid] != 0:
			continue
		if absf(out_a[cid] - out_c_chunk[ck]) > TOLERANCE:
			if fails < 3:
				print("    [A vs C] cell=%d chunk=%d a=%s c=%s diff=%s"
					% [cid, ck, String.num(out_a[cid], 9),
						String.num(out_c_chunk[ck], 9),
						String.num(absf(out_a[cid] - out_c_chunk[ck]), 9)])
			fails += 1
	if fails > 0:
		print("    A vs C diverged: %d / %d" % [fails, n_land])
		return false
	return true


# A vs (B|D) 的 LAND-cell 子集（两边都是 cell-id 顺序）
func _check_land_subset_bit_equal_full(out_a: PackedFloat32Array,
		out_b: PackedFloat32Array, water: PackedByteArray, n: int) -> bool:
	var fails: int = 0
	var land_count: int = 0
	for i in range(n):
		if water[i] != 0:
			continue
		land_count += 1
		if absf(out_a[i] - out_b[i]) > TOLERANCE:
			if fails < 3:
				print("    [A vs other] i=%d a=%s b=%s diff=%s"
					% [i, String.num(out_a[i], 9), String.num(out_b[i], 9),
						String.num(absf(out_a[i] - out_b[i]), 9)])
			fails += 1
	if fails > 0:
		print("    A vs other diverged: %d / %d LAND" % [fails, land_count])
		return false
	return true


# ════════════════════════════════════════════════════════════════════
# Input fixtures —— 与 bench_archetype_filter / realjobs 一致风格
# ════════════════════════════════════════════════════════════════════
func _make_temp_input(w: int, h: int) -> PackedFloat32Array:
	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(w * h)
	for y in range(h):
		var ny: float = (float(y) + 0.5) / float(h)
		for x in range(w):
			var nx: float = (float(x) + 0.5) / float(w)
			var base: float = nx
			var wave: float = 0.15 * cos(nx * TAU * 2.0) * sin(ny * PI)
			arr[y * w + x] = base + wave
	return arr


# Deterministic PCG mask (~ratio% ocean), independent seed from temp_input.
func _make_water_mask(w: int, h: int, ratio_pct: int) -> PackedByteArray:
	var arr: PackedByteArray = PackedByteArray()
	arr.resize(w * h)
	var seed_v: int = 0x6789ABCD
	for i in range(w * h):
		seed_v = (seed_v * 1103515245 + 12345) & 0x7FFFFFFF
		arr[i] = 1 if ((seed_v % 100) < ratio_pct) else 0
	return arr
