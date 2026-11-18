extends RefCounted

# ─────────────────────────────────────────────────────────────────────────────
# world_fingerprint.gd — 「世界指纹」实现（跟进计划 §2.1 / §2.2，S1）
#
# 规格：docs/plans/terrain-followup-verification-plan.md §2.1（基线）、§2.2（挂到 golden）
# 纯 static 工具，被两处复用：
#   · tests/world/world_fingerprint_test.gd —— 6 个种子（4×60×40 + 2×200×150）的正式门禁
#   · tests/runtime/golden_day_hash_test.gd / golden_external_advancers_test.gd /
#     native_generation_equivalence_test.gd —— §2.2 的轻量前置校验（1×60×40）
#
# 指纹 = 两份东西：
#   1) hashes：5 条数组的 FNV-1a 64（逐字节）。**逐位相同**才算一致：
#      elevation_arr（F32）、terrain_arr（U8）、landform_arr（U8）、
#      has_river_arr（U8）、hydro_parent_arr（I32）
#   2) stats：land_h 分位 + terrain / landform 直方图 + 5 个计数，按**相对容差**比对
#
# cfg / profile 缺省与 tests/world/ridge_drainage_metrics_test.gd::_cfg() / _profile()
# 逐键同源（2026-11-18 P5 标定值），这样指纹测的世界与 ridge 指标测的世界是同一个世界。
# 有意改世界的 PR 必须同时改这里的缺省与 tests/world/baselines/world_fingerprint.json
# （计划 §2.1「规则」）。
#
# ── hash 口径 ────────────────────────────────────────────────────────────────
# · FNV-1a 64：offset basis = 0xcbf29ce484222325，prime = 0x100000001b3。
#   GDScript 的 int 是 64 位**有符号**：offset basis 超出 2^63 写不成字面量，也不存在
#   `& 0xFFFFFFFFFFFFFFFF` 这种「无符号截断」。但 GDScript 的整型乘加按 64 位回绕
#   （Godot 不做溢出检查），其 bit pattern 与无符号 FNV-1a 64 **完全一致**，所以这里
#   直接用有符号 int 累积（offset 用「高位 32 位 << 32 | 低位」拼出同一 bit pattern），
#   输出时再用 hex64() 把两个 32 位半区拼成 16 位十六进制串 ⇒ JSON 里全是字符串，
#   没有符号/精度歧义。
# · 只对 `to_byte_array()` 的原始字节做 hash ⇒ 结果**依赖平台字节序与 float32 表示**。
#   与计划 §10 K1 一致：精确 hash 只在同平台 / 同编译配置下比较；
#   其他配置用 `FINGERPRINT_HASH=0` 只比分布统计。
# · `hydro_parent_arr` 是 PackedInt32Array，同样直接 to_byte_array()。
#
# ── 容差口径（stats）────────────────────────────────────────────────────────
# · 高度分位（land_h_p10/p50/p90/p99）：相对容差，缺省 5%。
# · 直方图（terrain_hist / landform_hist，值 → 占比）与计数（river_count 等）：
#   先按期望的 n_cells 折回 cell 数，容差 = max(1 格, 5%) ⇒ 单格抖动不会把门禁打红，
#   成规模的漂移才会红。
# · 缺省容差可用 FINGERPRINT_STAT_TOL 覆盖；hash 比对可用 FINGERPRINT_HASH=0 关掉。
#
# ── status 语义（不假装通过）─────────────────────────────────────────────────
# · skip  ：基线文件缺失 / 解析失败 / 没有该种子的行；拿不到 DCWorldExt。
#           调用方打印 `SKIP reason=...`，**不计失败**。
# · error ：生成失败（rc != 0 或 fallback != false）。合法输入不该失败 ⇒ 调用方计 FAIL。
# · drift ：hash 或 stats 不一致 ⇒ 调用方计 FAIL 并打印 format_report()。
# · ok    ：一致。
#
# ── 本轮未覆盖（不是遗漏）───────────────────────────────────────────────────
# 计划 §2.1 表格里还有一项「bake 的 height_buffer（desktop 档）」精确 hash。它需要在
# MapBaker 里跑一次完整 bake（要绑定 MapData / 桌面档分辨率），成本与耦合都远高于
# cell 级指纹，本轮（S1）先不做；等 §3（S2）的 bake 侧诊断（A_hex dump）落地后再加，
# 否则会再造一份「只对 headless 有效」的 bake 指纹。
# ─────────────────────────────────────────────────────────────────────────────

const SCHEMA := "world_fingerprint"
const SCHEMA_VERSION := 1
const BASELINE_PATH := "res://tests/world/baselines/world_fingerprint.json"

# 种子集（计划 §2.1；复用 p5_calib 的种子）
const SEED_BASE := 20260718
const W_SMALL := 60
const H_SMALL := 40
const W_LARGE := 200
const H_LARGE := 150
const SEEDS_SMALL := [20260718, 20260719, 20260720, 20260721]
const SEEDS_LARGE := [20260718, 20260719]

const SEA_FALLBACK := 0.64      # 与 ridge_drainage_metrics_test.gd::SEA_FALLBACK 同值
const STAT_TOL_DEFAULT := 0.05  # 计划 §2.1「分布统计（容差比对）」

const HASH_KEYS := ["elevation", "terrain", "landform", "has_river", "hydro_parent"]
const COUNT_STAT_KEYS := ["river_count", "lake_count", "highland_river_count",
		"peak_count", "plateau_count"]
const HEIGHT_STAT_KEYS := ["land_h_p10", "land_h_p50", "land_h_p90", "land_h_p99"]
const HIST_STAT_KEYS := ["terrain_hist", "landform_hist"]

# FNV-1a 64 常量（见文件头「hash 口径」）。
# offset basis 的无符号值是 0xCBF29CE484222325，超过 int64 上限（0x7FFF...），字面量写不出来，
# 也不能靠 `<< 32` 拼装（会依赖移位溢出的实现细节）⇒ 直接写它在有符号 64 位下的值，
# bit pattern 与无符号口径完全一致。prime 0x100000001B3 = 1099511628211 本身在范围内。
const FNV64_OFFSET := -3750763034362895579   # 0xCBF29CE484222325 as int64
const FNV64_PRIME := 0x100000001B3           # 1099511628211


# ═════════════════════════════════════════════════════════════════════════════
# cfg / profile / 种子集
# ═════════════════════════════════════════════════════════════════════════════

# 与 ridge_drainage_metrics_test.gd::_cfg() 逐键一致（宽度/高度/种子按行填）。
static func default_cfg(seed_value: int, w: int, h: int) -> Dictionary:
	return {
		"num_continents": 3,
		"continent_size": 0.9,
		"sea_level": SEA_FALLBACK,
		"river_count": 12,
		"width": w,
		"height": h,
		"seed": seed_value,
	}


# 与 ridge_drainage_metrics_test.gd::_profile() 逐键一致（2026-11-18 P5 标定值）。
# 保留 ridge_debug_dump=1：它让 base pass 额外输出 ridge_add_arr，**不改变任何正式数组**
# （纯诊断），本文件也不 hash 它 —— 留着是为了和 ridge 测试的 profile 逐键同源。
static func default_profile() -> Dictionary:
	return {
		"native_generation_mode": 2,
		"ridge_boost_amp": 0.60,
		"spl_iters": 14,
		"spl_erodibility": 1.2,
		"spl_area_exp": 0.45,
		"spl_uplift_rate": 0.08,
		"spl_ridge_uplift": 0.03,
		"spl_hillslope_diffusion": 0.08,
		"ridge_residual_frac": 0.15,
		"ridge_debug_dump": 1,
	}


# 计划 §2.1 的种子集：4 种子 × 60×40 + 2 种子 × 200×150。
static func seed_set() -> Array:
	var out: Array = []
	for s in SEEDS_SMALL:
		out.append({"seed": int(s), "w": W_SMALL, "h": H_SMALL})
	for s in SEEDS_LARGE:
		out.append({"seed": int(s), "w": W_LARGE, "h": H_LARGE})
	return out


static func row_key(seed_value: int, w: int, h: int) -> String:
	return "%d|%d|%d" % [seed_value, w, h]


static func env_stat_tol() -> float:
	var raw := OS.get_environment("FINGERPRINT_STAT_TOL").strip_edges()
	if raw.is_valid_float():
		return maxf(0.0, raw.to_float())
	return STAT_TOL_DEFAULT


static func env_compare_hashes() -> bool:
	return OS.get_environment("FINGERPRINT_HASH").strip_edges() != "0"


# ═════════════════════════════════════════════════════════════════════════════
# hash（FNV-1a 64）
# ═════════════════════════════════════════════════════════════════════════════

# 64 位有符号 int 累积（语义见文件头）；返回值只有 bit pattern 有意义。
static func fnv1a64(bytes: PackedByteArray) -> int:
	var h := FNV64_OFFSET
	var n := bytes.size()
	for i in range(n):
		h = (h ^ int(bytes[i])) * FNV64_PRIME
	return h


# 把有符号 int64 渲染成无符号 16 位十六进制串（两个 32 位半区拼接，避免负数打印出 '-'）。
static func hex64(value: int) -> String:
	var hi := (value >> 32) & 0xFFFFFFFF
	var lo := value & 0xFFFFFFFF
	return "%08x%08x" % [hi, lo]


# ═════════════════════════════════════════════════════════════════════════════
# 单种子测量
# ═════════════════════════════════════════════════════════════════════════════

# 跑 base + post_base 两个原生 pass，返回 {meta, hashes, stats, ok, reason, missing}。
# cfg / profile 传空字典时用与 ridge 测试同源的缺省。
static func compute(ext: Object, seed_value: int, w: int, h: int,
		cfg: Dictionary = {}, profile: Dictionary = {}) -> Dictionary:
	var use_cfg: Dictionary = default_cfg(seed_value, w, h) if cfg.is_empty() else cfg
	var use_profile: Dictionary = default_profile() if profile.is_empty() else profile
	var n := w * h
	var out := {
		"seed": seed_value,
		"w": w,
		"h": h,
		"ok": false,
		"reason": "",
		"missing": [],
		"hashes": {},
		"stats": {},
		"meta": {
			"seed": seed_value, "w": w, "h": h, "n_cells": n,
			"sea_level": float(use_cfg.get("sea_level", SEA_FALLBACK)),
			"base_ms": -1.0, "post_ms": -1.0,
			"cfg": use_cfg, "profile": use_profile,
		},
	}
	if ext == null:
		out["reason"] = "ext_null"
		return out
	if not ext.has_method("run_native_world_generate_base_pass") \
			or not ext.has_method("run_native_world_generate_post_base_pass"):
		out["reason"] = "ext_missing_generation_api"
		return out
	var t0 := Time.get_ticks_usec()
	var base: Dictionary = ext.call("run_native_world_generate_base_pass",
			seed_value, use_cfg, use_profile)
	var base_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	out["meta"]["base_ms"] = base_ms
	if int(base.get("rc", -1)) != 0 or bool(base.get("fallback", true)):
		out["reason"] = "base_failed rc=%d fallback=%s reason=%s" % [
			int(base.get("rc", -1)), str(base.get("fallback", true)),
			str(base.get("reason", ""))]
		return out
	var t1 := Time.get_ticks_usec()
	var post: Dictionary = ext.call("run_native_world_generate_post_base_pass",
			seed_value, use_cfg, use_profile, base)
	out["meta"]["post_ms"] = float(Time.get_ticks_usec() - t1) / 1000.0
	if int(post.get("rc", -1)) != 0 or bool(post.get("fallback", true)):
		out["reason"] = "post_base_failed rc=%d fallback=%s reason=%s" % [
			int(post.get("rc", -1)), str(post.get("fallback", true)),
			str(post.get("reason", ""))]
		return out

	var elevation: PackedFloat32Array = base.get("elevation_arr", PackedFloat32Array())
	var terrain: PackedByteArray = base.get("terrain_arr", PackedByteArray())
	var landform: PackedByteArray = base.get("landform_arr", PackedByteArray())
	var has_river: PackedByteArray = post.get("has_river_arr", PackedByteArray())
	var hydro_parent: PackedInt32Array = post.get("hydro_parent_arr", PackedInt32Array())
	# base pass 与 post_base 都会回传 terrain/landform（post_base 会改写它们）。指纹取 base 的
	# 那一份（= 地形成形后的正式结果）；只有 base 缺失时才退回 post_base，并在 meta.notes 留痕
	# （回退不是「缺数组」，不参与 ok 判定）。
	var notes: Array = []
	if terrain.size() != n:
		terrain = post.get("terrain_arr", PackedByteArray())
		notes.append("terrain_from_post_base")
	if landform.size() != n:
		landform = post.get("landform_arr", PackedByteArray())
		notes.append("landform_from_post_base")
	out["meta"]["notes"] = notes

	var hashes: Dictionary = {}
	var missing: Array = out["missing"]
	_record_hash(hashes, missing, "elevation",
			elevation.to_byte_array(), n * 4)
	_record_hash(hashes, missing, "terrain", terrain, n)
	_record_hash(hashes, missing, "landform", landform, n)
	_record_hash(hashes, missing, "has_river", has_river, n)
	_record_hash(hashes, missing, "hydro_parent", hydro_parent.to_byte_array(), n * 4)
	out["hashes"] = hashes

	var sea := float(out["meta"]["sea_level"])
	out["stats"] = _build_stats(elevation, terrain, landform, post, sea, n)
	# ok = 「5 条 hash 全部算得出来」+ base/post 都成功。少一条就当 error（无法指纹化世界），
	# 不把它伪装成 SKIP，否则「世界变了」会被静默吞掉。
	out["ok"] = elevation.size() == n and terrain.size() == n and landform.size() == n \
			and (missing as Array).is_empty()
	if not out["ok"] and str(out["reason"]) == "":
		if not (missing as Array).is_empty():
			out["reason"] = "missing_arrays %s" % _join_names(missing)
		else:
			out["reason"] = "array_size_mismatch elev=%d terrain=%d landform=%d n=%d" % [
				elevation.size(), terrain.size(), landform.size(), n]
	return out


static func _join_names(values: Array) -> String:
	var text := ""
	for value in values:
		text += "%s " % str(value)
	return text.strip_edges()


static func _record_hash(hashes: Dictionary, missing: Array, name: String,
		bytes: PackedByteArray, expected_size: int) -> void:
	if expected_size <= 0 or bytes.size() != expected_size:
		missing.append(name)
		hashes[name] = ""
		return
	hashes[name] = hex64(fnv1a64(bytes))


static func _build_stats(elevation: PackedFloat32Array, terrain: PackedByteArray,
		landform: PackedByteArray, post: Dictionary, sea: float, n: int) -> Dictionary:
	var stats := {
		"land_h_p10": null, "land_h_p50": null, "land_h_p90": null, "land_h_p99": null,
		"terrain_hist": {}, "landform_hist": {},
		"river_count": int(post.get("river_count", -1)),
		"lake_count": int(post.get("lake_count", -1)),
		"highland_river_count": int(post.get("highland_river_count", -1)),
		"peak_count": int(post.get("peak_count", -1)),
		"plateau_count": int(post.get("plateau_count", -1)),
	}
	if elevation.size() == n:
		# land_h = elevation − sea_level，只取陆地格（elevation >= sea，与 ridge 测试同口径）
		var land_h := PackedFloat32Array()
		for i in range(n):
			var e := float(elevation[i])
			if e >= sea:
				land_h.append(e - sea)
		land_h.sort()
		if land_h.size() > 0:
			stats["land_h_p10"] = _num(_percentile(land_h, 0.10))
			stats["land_h_p50"] = _num(_percentile(land_h, 0.50))
			stats["land_h_p90"] = _num(_percentile(land_h, 0.90))
			stats["land_h_p99"] = _num(_percentile(land_h, 0.99))
	stats["terrain_hist"] = _histogram_ratio(terrain)
	stats["landform_hist"] = _histogram_ratio(landform)
	return stats


# u8 数组 → {值字符串: 占比}，只输出非零桶；按键值升序插入（JSON 里也是升序）。
static func _histogram_ratio(values: PackedByteArray) -> Dictionary:
	var out := {}
	var total := values.size()
	if total <= 0:
		return out
	var counts := PackedInt32Array()
	counts.resize(256)
	for i in range(total):
		counts[int(values[i])] += 1
	for k in range(256):
		if counts[k] > 0:
			out[str(k)] = float(counts[k]) / float(total)
	return out


# numpy 口径的线性插值分位（values 必须已升序）。
static func _percentile(values: PackedFloat32Array, q: float) -> float:
	var m := values.size()
	if m == 0:
		return NAN
	if m == 1:
		return float(values[0])
	var pos := float(m - 1) * q
	var lo := int(floor(pos))
	if lo < 0:
		lo = 0
	if lo > m - 2:
		lo = m - 2
	var frac := pos - float(lo)
	return float(values[lo]) + (float(values[lo + 1]) - float(values[lo])) * frac


static func _num(v: float) -> Variant:
	if is_nan(v) or not is_finite(v):
		return null
	return v


# ═════════════════════════════════════════════════════════════════════════════
# 比对
# ═════════════════════════════════════════════════════════════════════════════

# 返回 {ok, hash_diffs:[数组名], stat_diffs:[{key, expected, actual, rel}], missing,
#       config_match, stat_tol, actual, expected}
# · hash 逐位比（compare_hashes=false 时只比 stats，对应计划 §10 K1 的「其他配置」）
# · stats 按容差比（口径见文件头）
static func compare(actual: Dictionary, expected: Dictionary,
		stat_tol: float = STAT_TOL_DEFAULT, compare_hashes: bool = true) -> Dictionary:
	var out := {
		"ok": true,
		"hash_diffs": [],
		"stat_diffs": [],
		"missing": [],
		"config_match": true,
		"stat_tol": stat_tol,
		"actual": actual,
		"expected": expected,
	}
	var a_hashes: Dictionary = actual.get("hashes", {})
	var e_hashes: Dictionary = expected.get("hashes", {})
	for key in HASH_KEYS:
		var k := str(key)
		var av := str(a_hashes.get(k, ""))
		var ev := str(e_hashes.get(k, ""))
		if av == "" or ev == "":
			out["missing"].append(k)
			continue
		if compare_hashes and av != ev:
			out["hash_diffs"].append(k)

	var e_meta: Dictionary = expected.get("meta", {})
	var a_meta: Dictionary = actual.get("meta", {})
	out["config_match"] = JSON.stringify(a_meta.get("cfg", {})) == JSON.stringify(e_meta.get("cfg", {})) \
			and JSON.stringify(a_meta.get("profile", {})) == JSON.stringify(e_meta.get("profile", {}))
	var n_cells := float(e_meta.get("n_cells", actual.get("w", 1) * actual.get("h", 1)))
	if n_cells <= 0.0:
		n_cells = 1.0

	var e_flat := _flatten_stats(expected.get("stats", {}))
	var a_flat := _flatten_stats(actual.get("stats", {}))
	var keys: Array = e_flat.keys()
	for key in a_flat.keys():
		if not e_flat.has(key):
			keys.append(key)
	keys.sort()
	for key in keys:
		var k := str(key)
		var has_e := e_flat.has(k)
		var has_a := a_flat.has(k)
		if not has_e and not has_a:
			continue
		var e_val := float(e_flat.get(k, 0.0))
		var a_val := float(a_flat.get(k, 0.0))
		var is_cell_count := k.find(".") >= 0 or COUNT_STAT_KEYS.has(k)
		var expected_cells := e_val * (n_cells if k.find(".") >= 0 else 1.0)
		var actual_cells := a_val * (n_cells if k.find(".") >= 0 else 1.0)
		var delta := absf(actual_cells - expected_cells)
		if is_cell_count:
			# 计数 / 直方图：容差 = max(1 格, stat_tol × 期望)
			if delta > maxf(1.0, stat_tol * absf(expected_cells)) + 1.0e-9:
				out["stat_diffs"].append({
					"key": k, "expected": e_val, "actual": a_val,
					"rel": delta / maxf(absf(expected_cells), 1.0), "kind": "count"})
		else:
			# 高度分位：相对容差
			var rel := absf(a_val - e_val) / maxf(absf(e_val), 1.0e-4)
			if rel > stat_tol + 1.0e-9:
				out["stat_diffs"].append({
					"key": k, "expected": e_val, "actual": a_val,
					"rel": rel, "kind": "height"})
	out["ok"] = (out["hash_diffs"] as Array).is_empty() \
			and (out["stat_diffs"] as Array).is_empty()
	return out


# 统计拍平成一维：{key: float}。直方图键写成 "<group>.<值>"，缺席 = 0。
static func _flatten_stats(stats: Dictionary) -> Dictionary:
	var flat := {}
	for key in HEIGHT_STAT_KEYS:
		var k := str(key)
		if stats.has(k) and stats[k] != null:
			flat[k] = float(stats[k])
	for key in COUNT_STAT_KEYS:
		var k := str(key)
		if stats.has(k) and stats[k] != null:
			flat[k] = float(stats[k])
	for group in HIST_STAT_KEYS:
		var g := str(group)
		var hist: Dictionary = stats.get(g, {})
		for bucket in hist.keys():
			flat["%s.%s" % [g, str(bucket)]] = float(hist[bucket])
	return flat


# 人能读的摘要：**必须**点名哪个数组 hash 变了、哪个统计差多少。
# 接受 verify()/precheck() 的返回值（含 compare 子字典）或 compare() 的返回值本身。
static func format_report(result: Dictionary) -> String:
	var cmp: Dictionary = result.get("compare", result)
	var lines: Array = []
	var head := "fingerprint"
	if result.has("seed"):
		head = "seed=%d %dx%d" % [int(result.get("seed", -1)),
				int(result.get("w", -1)), int(result.get("h", -1))]
	var tol := float(cmp.get("stat_tol", STAT_TOL_DEFAULT))
	lines.append("%s ok=%s stat_tol=%.1f%%" % [head, str(bool(cmp.get("ok", false))),
			tol * 100.0])
	if not bool(cmp.get("config_match", true)):
		lines.append("  cfg/profile 与基线不同（本身就是漂移来源之一）")
	var hash_diffs: Array = cmp.get("hash_diffs", [])
	if hash_diffs.is_empty():
		lines.append("  hashes: 全部一致（或 FINGERPRINT_HASH=0 未比）")
	else:
		var e_hashes: Dictionary = (cmp.get("expected", {}) as Dictionary).get("hashes", {})
		var a_hashes: Dictionary = (cmp.get("actual", {}) as Dictionary).get("hashes", {})
		for name in hash_diffs:
			var k := str(name)
			lines.append("  hash DRIFT %s: baseline=%s actual=%s" % [
					k, str(e_hashes.get(k, "")), str(a_hashes.get(k, ""))])
	var stat_diffs: Array = cmp.get("stat_diffs", [])
	if stat_diffs.is_empty():
		lines.append("  stats: 全部在容差内")
	else:
		for entry in stat_diffs:
			var d: Dictionary = entry
			lines.append("  stat DRIFT %s: baseline=%.6f actual=%.6f rel=%.2f%% (%s)" % [
					str(d.get("key", "?")), float(d.get("expected", 0.0)),
					float(d.get("actual", 0.0)), float(d.get("rel", 0.0)) * 100.0,
					str(d.get("kind", "?"))])
	var missing: Array = cmp.get("missing", [])
	if not missing.is_empty():
		var names := ""
		for m in missing:
			names += ("%s " % str(m))
		lines.append("  missing arrays: %s" % names.strip_edges())
	return "\n".join(PackedStringArray(lines))


# ═════════════════════════════════════════════════════════════════════════════
# 基线文件读写
# ═════════════════════════════════════════════════════════════════════════════

# 读基线：返回 {ok, reason, doc, rows}；rows = {"seed|w|h": 行}。
static func load_baseline(path: String = BASELINE_PATH) -> Dictionary:
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "doc": {}, "rows": {},
			"reason": "baseline missing (run with FINGERPRINT_WRITE=1): %s" % path}
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return {"ok": false, "doc": {}, "rows": {},
			"reason": "baseline unreadable (err=%d): %s" % [FileAccess.get_open_error(), path]}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "doc": {}, "rows": {},
			"reason": "baseline is not a JSON object: %s" % path}
	var doc: Dictionary = parsed
	var rows := {}
	var row_list = doc.get("rows", [])
	if row_list is Array:
		for entry in row_list:
			if not (entry is Dictionary):
				continue
			var row: Dictionary = entry
			var key := row_key(int(row.get("seed", -1)), int(row.get("w", -1)),
					int(row.get("h", -1)))
			rows[key] = row
	if rows.is_empty():
		return {"ok": false, "doc": doc, "rows": {},
			"reason": "baseline has no usable rows: %s" % path}
	return {"ok": true, "doc": doc, "rows": rows, "reason": ""}


static func build_baseline_document(rows: Array) -> Dictionary:
	return {
		"schema": SCHEMA,
		"version": SCHEMA_VERSION,
		"written_utc": Time.get_datetime_string_from_system(true),
		"godot": str(Engine.get_version_info().get("string", "?")),
		"platform": OS.get_name(),
		"hash_algo": "fnv1a-64 over to_byte_array()（只在同平台/同编译配置下比）",
		"stat_tol_default": STAT_TOL_DEFAULT,
		"stat_rule": "高度分位按相对容差；直方图/计数按 cell 数，容差 = max(1 格, tol × 期望)",
		"seed_set": seed_set(),
		"row_count": rows.size(),
		"rows": rows,
	}


static func write_baseline(path: String, doc: Dictionary) -> Dictionary:
	var abs_path := ProjectSettings.globalize_path(path)
	var dir := abs_path.get_base_dir()
	if dir != "":
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK and err != ERR_ALREADY_EXISTS:
			return {"ok": false, "path": abs_path,
				"reason": "mkdir failed err=%d dir=%s" % [err, dir]}
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "path": abs_path, "reason": "open failed err=%d" % FileAccess.get_open_error()}
	f.store_string(JSON.stringify(doc, "  ", false, false) + "\n")
	f.close()
	return {"ok": true, "path": abs_path, "reason": ""}


# ═════════════════════════════════════════════════════════════════════════════
# 校验入口
# ═════════════════════════════════════════════════════════════════════════════

# 拿 ext：优先 host.world_ext()（host 有该方法时），否则 ClassDB.instantiate("DCWorldExt")。
# 也接受「直接传一个已经实例化好的 ext」（测试里 ext 已经在手上时，别再建第二个实例）。
static func resolve_ext(host: Variant = null) -> Object:
	if host != null and host is Object:
		var host_object: Object = host
		if host_object.has_method("run_native_world_generate_base_pass"):
			return host_object
		if host_object.has_method("world_ext"):
			var from_host = host_object.call("world_ext")
			if from_host != null and from_host is Object:
				return from_host as Object
	if ClassDB.class_exists("DCWorldExt"):
		return ClassDB.instantiate("DCWorldExt") as Object
	return null


# 单种子校验：返回 {status, reason, seed, w, h, compare, actual, expected}。
static func verify(ext: Object, seed_value: int, w: int, h: int,
		path: String = BASELINE_PATH, stat_tol: float = STAT_TOL_DEFAULT,
		compare_hashes: bool = true) -> Dictionary:
	var head := {"status": "skip", "reason": "", "seed": seed_value, "w": w, "h": h}
	var loaded := load_baseline(path)
	if not bool(loaded.get("ok", false)):
		head["reason"] = str(loaded.get("reason", "baseline missing"))
		return head
	var rows: Dictionary = loaded.get("rows", {})
	var key := row_key(seed_value, w, h)
	if not rows.has(key):
		head["reason"] = "baseline has no row for %s (rows=%d)" % [key, rows.size()]
		return head
	if ext == null:
		head["reason"] = "DCWorldExt unavailable"
		return head
	var actual := compute(ext, seed_value, w, h)
	if not bool(actual.get("ok", false)):
		head["status"] = "error"
		head["reason"] = "generation failed: %s" % str(actual.get("reason", "?"))
		head["actual"] = actual
		return head
	var expected: Dictionary = rows[key]
	var cmp := compare(actual, expected, stat_tol, compare_hashes)
	head["status"] = "ok" if bool(cmp.get("ok", false)) else "drift"
	head["compare"] = cmp
	head["actual"] = actual
	head["expected"] = expected
	return head


# §2.2 用的轻量前置校验：拿 ext + 比 1 个 60×40 种子（缺省 20260718）。
# host 参数可以是 WorldRuntimeHost（走 host.world_ext()），也可以直接是已实例化的 ext。
# 容差与 hash 开关走环境变量，与正式指纹测试同一套口径。
static func precheck(host: Variant = null, seed_value: int = SEED_BASE,
		w: int = W_SMALL, h: int = H_SMALL) -> Dictionary:
	var ext := resolve_ext(host)
	if ext == null:
		return {"status": "skip", "seed": seed_value, "w": w, "h": h,
			"reason": "DCWorldExt unavailable (class missing or instantiate returned null)"}
	return verify(ext, seed_value, w, h, BASELINE_PATH, env_stat_tol(), env_compare_hashes())
