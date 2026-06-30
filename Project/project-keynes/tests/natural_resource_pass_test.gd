extends SceneTree

# natural_resource_pass_test.gd
# 自然资源系统（per-cell 储量 + 每日生成/衰减）验收。
#
# 验证：
#   1. DCComponentSchema 含 biomass / iron reserve 字段（cpp_name / map_field 正确）。
#   2. ResourceProfileRegistry 至少加载 biomass / iron（数量随测试资源浮动）；
#      build_pass_knobs resource_count == registry.count()，按 slot 名定位系数与 .tres 对齐。
#   3. DCWorldExt 导出 run_natural_resource_pass。
#   4. 原生 pass 在小地图上行为正确，且与 GDScript 公式模板逐资源逐 cell A/B 对拍一致：
#      - biomass（可再生，land_only）：陆地格趋向 capacity 增长（delta>0）；水面格保持 0。
#      - iron_ore（不可再生，全 0 系数）：保持不变。
#      - clamp 到 [0, capacity]。
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
	var biomass: Dictionary = DCComponentSchema.find_by_name(&"cell.res_biomass_reserve")
	var iron: Dictionary = DCComponentSchema.find_by_name(&"cell.res_iron_ore_reserve")
	_expect("schema has cell.res_biomass_reserve", not biomass.is_empty())
	_expect("schema has cell.res_iron_ore_reserve", not iron.is_empty())
	if not biomass.is_empty():
		_expect("biomass cpp_name", String(biomass.get("cpp_name", "")) == "cell_res_biomass_reserve")
		_expect("biomass map_field", String(biomass.get("map_field", "")) == "res_biomass_reserve_arr")
		_expect("biomass dtype F32", int(biomass.get("dtype", -1)) == DCComponentIds.F32)
	if not iron.is_empty():
		_expect("iron cpp_name", String(iron.get("cpp_name", "")) == "cell_res_iron_ore_reserve")
		_expect("iron map_field", String(iron.get("map_field", "")) == "res_iron_ore_reserve_arr")


# ─── 2. registry / knobs ────────────────────────────────────────
# count-agnostic：注册表里资源数量会随测试资源增减，这里按 slot 名定位 biomass/iron，
# 不再假设恰好 2 个或固定下标。
func _test_registry_knobs() -> void:
	ResourceProfileRegistry.ensure_loaded()
	var count: int = ResourceProfileRegistry.count()
	_expect("registry loaded >=2 profiles", count >= 2)
	var knobs: Dictionary = ResourceProfileRegistry.build_pass_knobs()
	_expect("knobs resource_count matches registry count", int(knobs.get("resource_count", 0)) == count)
	var slots: PackedStringArray = knobs.get("reserve_slots", PackedStringArray())
	var caps: PackedFloat32Array = knobs.get("capacity", PackedFloat32Array())
	var gen_self: PackedFloat32Array = knobs.get("gen_self", PackedFloat32Array())
	var bi: int = _slot_index(slots, "cell_res_biomass_reserve")
	var ii: int = _slot_index(slots, "cell_res_iron_ore_reserve")
	_expect("reserve_slots has biomass", bi >= 0)
	_expect("reserve_slots has iron_ore", ii >= 0)
	if bi >= 0:
		_expect("biomass capacity 1.0", is_equal_approx(caps[bi], 1.0))
		_expect("biomass gen_self>0 (renewable)", gen_self[bi] > 0.0)
	if ii >= 0:
		_expect("iron capacity 1.0", is_equal_approx(caps[ii], 1.0))
		_expect("iron gen_self==0 (non-renewable)", is_equal_approx(gen_self[ii], 0.0))


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

	var n: int = 2
	var map := MapData.new(2, 1)
	# 仅 seed 本 pass 需要的字段（其余 schema 字段以 size 0 绑定，pass 不触碰）。
	# cell 0：陆地（is_water=0），温暖湿润 → biomass 应增长。
	# cell 1：水面（is_water=1，land_only）→ biomass 保持 0。
	map.temp_arr = PackedFloat32Array([20.0, 10.0])
	map.moisture_arr = PackedFloat32Array([0.6, 0.8])
	map.is_water_arr = PackedByteArray([0, 1])
	var biomass_init := PackedFloat32Array([0.2, 0.0])
	var iron_init := PackedFloat32Array([0.5, 0.0])
	map.res_biomass_reserve_arr = biomass_init.duplicate()
	map.res_iron_ore_reserve_arr = iron_init.duplicate()

	_expect("bind_map_data succeeds", bool(ext.bind_map_data(map)))
	if _failures > 0:
		return

	var knobs: Dictionary = ResourceProfileRegistry.build_pass_knobs()
	knobs["n_cells"] = n

	# GDScript 参考（同模板）：先算期望值，再跑 native 对拍。
	var expected_biomass := _reference_step(0, biomass_init, map.temp_arr, map.moisture_arr, map.is_water_arr, n)
	var expected_iron := _reference_step(1, iron_init, map.temp_arr, map.moisture_arr, map.is_water_arr, n)

	var res: Dictionary = ext.run_natural_resource_pass(knobs)
	_expect("pass done", bool(res.get("done", false)))
	_expect("pass path=gdext", String(res.get("path", "")) == "gdext")
	_expect("pass published_to_slot", bool(res.get("published_to_slot", false)))
	_expect("pass resource_count==2", int(res.get("resource_count", 0)) == 2)

	var b: PackedFloat32Array = map.res_biomass_reserve_arr
	var ir: PackedFloat32Array = map.res_iron_ore_reserve_arr
	_expect("biomass land cell grew", b.size() == n and b[0] > biomass_init[0])
	_expect("biomass water cell stays 0 (land_only)", b.size() == n and is_equal_approx(b[1], 0.0))
	_expect("biomass within [0,capacity]", b.size() == n and b[0] >= 0.0 and b[0] <= 1.0)
	_expect("iron static (no regen/decay)", ir.size() == n and is_equal_approx(ir[0], iron_init[0]) and is_equal_approx(ir[1], iron_init[1]))

	# A/B：native 与 GDScript 参考逐 cell 一致（f32 容差）。
	_expect("biomass native==reference[0]", b.size() == n and absf(b[0] - expected_biomass[0]) < 1e-4)
	_expect("biomass native==reference[1]", b.size() == n and absf(b[1] - expected_biomass[1]) < 1e-4)
	_expect("iron native==reference[0]", ir.size() == n and absf(ir[0] - expected_iron[0]) < 1e-4)


# GDScript 参考实现：与 C++ run_natural_resource_pass / map_generator fallback 同公式。
func _reference_step(res_idx: int, reserve_in: PackedFloat32Array, temp: PackedFloat32Array,
		moist: PackedFloat32Array, water: PackedByteArray, n: int) -> PackedFloat32Array:
	var profiles: Array = ResourceProfileRegistry.ordered()
	var p = profiles[res_idx]
	var out := reserve_in.duplicate()
	var cap: float = p.capacity
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
		# 半隐式（IMEX）：与 C++ run_natural_resource_pass / fallback 同模板。
		var gen_climate: float = p.gen_base + p.gen_temp * tn + p.gen_moisture * m
		var decay_climate: float = p.decay_base + p.decay_temp * tn + p.decay_moisture * m
		var P: float = gen_climate + p.gen_self - decay_climate
		var L: float = ((p.gen_self + p.decay_self) / cap) if cap > 0.0 else 0.0
		if L < 0.0:
			L = 0.0
		var v: float = (reserve + P) / (1.0 + L)
		if cap > 0.0 and v > cap:
			v = cap
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
