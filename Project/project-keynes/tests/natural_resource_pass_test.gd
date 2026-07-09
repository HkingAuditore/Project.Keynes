extends SceneTree

# natural_resource_pass_test.gd
# 自然资源系统（per-cell 储量 + 每日生成/衰减）验收。
#
# 验证：
#   1. DCComponentSchema 含 timber / iron reserve 字段（cpp_name / map_field 正确）。
#   2. ResourceProfileRegistry 至少加载 timber / iron（数量随测试资源浮动）；
#      build_pass_knobs resource_count == registry.count()，按 slot 名定位系数与 .tres 对齐。
#   3. DCWorldExt 导出 run_natural_resource_pass。
#   4. 原生 pass 在小地图上行为正确，且与 GDScript 公式模板逐资源逐 cell A/B 对拍一致：
#      - wheat（可再生，land_only）：适宜陆地格增长；水面格保持 0。
#      - iron_ore（不可再生，全 0 系数）：无 extra 时保持不变，extra 单 tick 生效并清零。
#      - reserve 保持非负。
#
# Headless execution:
#   godot --headless --script tests/natural_resource_pass_test.gd --quit

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== natural resource pass test ===")
	_test_schema_entries()
	_test_registry_knobs()
	_test_native_pass()
	print("=== natural resource pass summary: %d checks, %d failures ===" % [_checks, _failures])


# ─── 1. schema 字段 ─────────────────────────────────────────────
func _test_schema_entries() -> void:
	var timber: Dictionary = DCComponentSchema.find_by_name(&"cell.res_timber_reserve")
	var iron: Dictionary = DCComponentSchema.find_by_name(&"cell.res_iron_ore_reserve")
	_expect("schema has cell.res_timber_reserve", not timber.is_empty())
	_expect("schema has cell.res_iron_ore_reserve", not iron.is_empty())
	if not timber.is_empty():
		_expect("timber cpp_name", String(timber.get("cpp_name", "")) == "cell_res_timber_reserve")
		_expect("timber map_field", String(timber.get("map_field", "")) == "res_timber_reserve_arr")
		_expect("timber dtype F32", int(timber.get("dtype", -1)) == DCComponentIds.F32)
	if not iron.is_empty():
		_expect("iron cpp_name", String(iron.get("cpp_name", "")) == "cell_res_iron_ore_reserve")
		_expect("iron map_field", String(iron.get("map_field", "")) == "res_iron_ore_reserve_arr")


# ─── 2. registry / knobs ────────────────────────────────────────
# count-agnostic：注册表里资源数量会随测试资源增减，这里按 slot 名定位 wheat/iron，
# 不再假设恰好 2 个或固定下标。
func _test_registry_knobs() -> void:
	ResourceProfileRegistry.ensure_loaded()
	var count: int = ResourceProfileRegistry.count()
	_expect("registry loaded >=2 profiles", count >= 2)
	_expect("registry loaded 28 profiles", count == 28)
	var knobs: Dictionary = ResourceProfileRegistry.build_pass_knobs()
	_expect("knobs resource_count matches registry count", int(knobs.get("resource_count", 0)) == count)
	var slots: PackedStringArray = knobs.get("reserve_slots", PackedStringArray())
	var extra_slots: PackedStringArray = knobs.get("extra_change_slots", PackedStringArray())
	var gen_self: PackedFloat32Array = knobs.get("gen_self", PackedFloat32Array())
	var wi: int = _slot_index(slots, "cell_res_wheat_reserve")
	var ii: int = _slot_index(slots, "cell_res_iron_ore_reserve")
	var gi: int = _slot_index(slots, "cell_res_wild_game_reserve")
	var hi: int = _slot_index(slots, "cell_res_medicinal_herbs_reserve")
	_expect("reserve_slots has wheat", wi >= 0)
	_expect("reserve_slots has iron_ore", ii >= 0)
	_expect("reserve_slots has wild_game", gi >= 0)
	_expect("reserve_slots has medicinal_herbs", hi >= 0)
	_expect("knobs has no capacity array", not knobs.has("capacity"))
	_expect("extra_change_slots count matches reserve_slots", extra_slots.size() == slots.size())
	if wi >= 0:
		_expect("wheat extra slot", wi < extra_slots.size() and extra_slots[wi] == "cell_res_wheat_extra_change")
		_expect("wheat gen_self>0 (renewable)", gen_self[wi] > 0.0)
	if ii >= 0:
		_expect("iron extra slot", ii < extra_slots.size() and extra_slots[ii] == "cell_res_iron_ore_extra_change")
		_expect("iron gen_self==0 (non-renewable)", is_equal_approx(gen_self[ii], 0.0))
	if gi >= 0:
		_expect("wild_game extra slot", gi < extra_slots.size() and extra_slots[gi] == "cell_res_wild_game_extra_change")
	if hi >= 0:
		_expect("medicinal_herbs extra slot", hi < extra_slots.size() and extra_slots[hi] == "cell_res_medicinal_herbs_extra_change")


func _slot_index(slots: PackedStringArray, name: String) -> int:
	for i in range(slots.size()):
		if slots[i] == name:
			return i
	return -1


# ─── 3. 原生 pass + A/B 对拍 ─────────────────────────────────────
func _test_native_pass() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext := DCWorldExt.new()
	if not ext.has_method("run_natural_resource_pass"):
		_skip("run_natural_resource_pass not exported")
		return

	ResourceProfileRegistry.ensure_loaded()
	var profiles: Array = ResourceProfileRegistry.ordered()
	if profiles.size() < 2:
		_skip("registry has <2 profiles")
		return

	# ≥20 cell：覆盖 AVX2 SIMD body(16) + 标量尾(4) + 陆/水混合（land_gate blendv）。
	var n: int = 20
	var map := MapData.new(n, 1)
	var temp := PackedFloat32Array()
	var moist := PackedFloat32Array()
	var water := PackedByteArray()
	temp.resize(n)
	moist.resize(n)
	water.resize(n)
	for i in range(n):
		temp[i] = -12.0 + 2.4 * float(i)                       # -12 .. 33.6 °C
		moist[i] = clampf(float(i) / float(n - 1), 0.0, 1.0)
		water[i] = 1 if (i % 4 == 3) else 0                    # 水面格散布在 body 与 tail 段
	map.temp_arr = temp
	map.moisture_arr = moist
	map.is_water_arr = water

	# 逐资源 seed 初值（直接资源量、按 cell 变化，给生成/衰减双向余量）。
	var fields: Array = []
	var extra_fields: Array = []
	var inits: Array = []
	var extra_inits: Array = []
	for idx in range(profiles.size()):
		var p = profiles[idx]
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		var arr := PackedFloat32Array()
		arr.resize(n)
		for i in range(n):
			arr[i] = 0.2 + 0.6 * (float(i % 5) / 4.0)
		map.set(field, arr)
		fields.append(field)
		inits.append(arr.duplicate())
		var extra_field: String = ResourceProfileRegistry.extra_change_map_field(p)
		var extra_arr := PackedFloat32Array()
		extra_arr.resize(n)
		for i in range(n):
			extra_arr[i] = 0.0
		if String(p.id) == "wheat":
			extra_arr[12] = 0.25
		elif String(p.id) == "iron_ore":
			extra_arr[0] = 0.5
		map.set(extra_field, extra_arr)
		extra_fields.append(extra_field)
		extra_inits.append(extra_arr.duplicate())

	_expect("bind_map_data succeeds", bool(ext.bind_map_data(map)))
	if _failures > 0:
		return

	var knobs: Dictionary = ResourceProfileRegistry.build_pass_knobs()
	knobs["n_cells"] = n

	# 先算每资源期望（GDScript 参考，同模板），再跑 native（多核 + SIMD）对拍。
	var expected: Array = []
	for idx in range(profiles.size()):
		expected.append(_reference_step(idx, inits[idx], extra_inits[idx], temp, moist, water, n))

	var res: Dictionary = ext.run_natural_resource_pass(knobs)
	_expect("pass done", bool(res.get("done", false)))
	_expect("pass path=gdext", String(res.get("path", "")) == "gdext")
	_expect("pass published_to_slot", bool(res.get("published_to_slot", false)))
	_expect("pass resource_count==registry", int(res.get("resource_count", 0)) == profiles.size())

	# 逐资源、逐 cell A/B：native（多核 + AVX2 SIMD body/tail/water-blend）== GDScript 参考。
	var ab_ok: bool = true
	var ab_detail: String = ""
	for idx in range(profiles.size()):
		var p = profiles[idx]
		var tol: float = 1e-4
		var got: PackedFloat32Array = map.get(fields[idx])
		var exp: PackedFloat32Array = expected[idx]
		if got.size() != n:
			ab_ok = false
			ab_detail = "%s size %d != %d" % [String(p.id), got.size(), n]
			break
		for i in range(n):
			if absf(got[i] - exp[i]) > tol:
				ab_ok = false
				ab_detail = "%s[%d] native=%s ref=%s (tol=%s)" % [String(p.id), i, str(got[i]), str(exp[i]), str(tol)]
				break
		if not ab_ok:
			break
	if not ab_ok:
		printerr("  [detail] %s" % ab_detail)
	_expect("native==reference for all resources × cells (SIMD body+tail+water blend)", ab_ok)

	# 关键不变量抽查。
	var wi: int = _profile_index(profiles, "wheat")
	if wi >= 0:
		var wgot: PackedFloat32Array = map.get(fields[wi])
		var winit: PackedFloat32Array = inits[wi]
		_expect("wheat suitable land cell grew", wgot.size() == n and wgot[12] > winit[12])   # i=12 温和半湿陆地
		_expect("wheat water cell unchanged (land_only)", wgot.size() == n and is_equal_approx(wgot[3], winit[3]))  # i=3 水面
		var w_nonnegative: bool = true
		for i in range(n):
			if wgot[i] < 0.0:
				w_nonnegative = false
				break
		_expect("wheat reserve nonnegative", w_nonnegative)
		var wextra: PackedFloat32Array = map.get(extra_fields[wi])
		_expect("wheat extra_change consumed and cleared", wextra.size() == n and is_equal_approx(wextra[12], 0.0))

	var ii: int = _profile_index(profiles, "iron_ore")
	if ii >= 0:
		var igot: PackedFloat32Array = map.get(fields[ii])
		var iinit: PackedFloat32Array = inits[ii]
		var static_ok: bool = igot.size() == n and igot[0] > iinit[0]
		if static_ok:
			for i in range(1, n):
				if not is_equal_approx(igot[i], iinit[i]):
					static_ok = false
					break
		_expect("iron static except one tick extra_change", static_ok)
		var iextra: PackedFloat32Array = map.get(extra_fields[ii])
		_expect("iron extra_change consumed and cleared", iextra.size() == n and is_equal_approx(iextra[0], 0.0))


func _profile_index(profiles: Array, id_name: String) -> int:
	for i in range(profiles.size()):
		if String(profiles[i].id) == id_name:
			return i
	return -1


# GDScript 参考实现：与 C++ run_natural_resource_pass / map_generator fallback 同公式。
func _reference_step(res_idx: int, reserve_in: PackedFloat32Array, extra_in: PackedFloat32Array, temp: PackedFloat32Array,
		moist: PackedFloat32Array, water: PackedByteArray, n: int) -> PackedFloat32Array:
	var profiles: Array = ResourceProfileRegistry.ordered()
	var p = profiles[res_idx]
	var out := reserve_in.duplicate()
	var lo: float = p.temp_lo
	var hi: float = p.temp_hi
	var inv_span: float = (1.0 / (hi - lo)) if hi > lo else 0.0
	var land_gate: bool = bool(p.land_only)
	for i in range(n):
		if land_gate and water[i] != 0:
			continue
		var tn: float = clampf((temp[i] - lo) * inv_span, 0.0, 1.0)
		var m: float = moist[i]
		var reserve: float = out[i]
		var extra_change: float = extra_in[i] if i < extra_in.size() else 0.0
		# 半隐式（IMEX）：与 C++ run_natural_resource_pass / fallback 同模板。
		var fit_weight: float = clampf(p.runtime_climate_fit_weight, 0.0, 1.0)
		var runtime_fit: float = 1.0
		if fit_weight != 0.0 or p.decay_stress != 0.0:
			var temp_fit: float = 1.0 - clampf(absf(tn - p.climate_temp_opt) / maxf(p.climate_temp_tol, 0.0001), 0.0, 1.0)
			var moisture_fit: float = 1.0 - clampf(absf(m - p.climate_moisture_opt) / maxf(p.climate_moisture_tol, 0.0001), 0.0, 1.0)
			runtime_fit = lerpf(1.0, temp_fit * moisture_fit, fit_weight)
		var gen_climate: float = p.gen_base + p.gen_temp * tn + p.gen_moisture * m
		var decay_climate: float = p.decay_base + p.decay_temp * tn + p.decay_moisture * m
		var gen_self_eff: float = p.gen_self * runtime_fit
		var P: float = gen_climate + gen_self_eff + extra_change - decay_climate - p.decay_stress * (1.0 - runtime_fit)
		var L: float = p.decay_self
		if L < 0.0:
			L = 0.0
		var v: float = (reserve + P) / (1.0 + L)
		if v < 0.0:
			v = 0.0
		out[i] = v
	return out


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
