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
#      - timber（可再生，land）：适宜陆地格增长；水面格清零。
#      - marine_fish：在海洋水格与沿海陆格生长；freshwater_fish 只在淡水格生长。
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
	_test_wilderness_bucket_selection()
	_test_native_pass()
	print("=== natural resource pass summary: %d checks, %d failures ===" % [_checks, _failures])


# ─── 1. schema 字段 ─────────────────────────────────────────────
func _test_schema_entries() -> void:
	var timber: Dictionary = DCComponentSchema.find_by_name(&"cell.res_timber_reserve")
	var iron: Dictionary = DCComponentSchema.find_by_name(&"cell.res_iron_ore_reserve")
	var plant_water: Dictionary = DCComponentSchema.find_by_name(
		&"cell.plant_available_water")
	_expect("schema has cell.res_timber_reserve", not timber.is_empty())
	_expect("schema has cell.res_iron_ore_reserve", not iron.is_empty())
	_expect("schema has cell.plant_available_water", not plant_water.is_empty())
	if not plant_water.is_empty():
		_expect("plant water cpp_name", String(plant_water.get("cpp_name", "")) ==
			"cell_plant_available_water")
		_expect("plant water map_field", String(plant_water.get("map_field", "")) ==
			"plant_available_water_arr")
	if not timber.is_empty():
		_expect("timber cpp_name", String(timber.get("cpp_name", "")) == "cell_res_timber_reserve")
		_expect("timber map_field", String(timber.get("map_field", "")) == "res_timber_reserve_arr")
		_expect("timber dtype F32", int(timber.get("dtype", -1)) == DCComponentIds.F32)
	if not iron.is_empty():
		_expect("iron cpp_name", String(iron.get("cpp_name", "")) == "cell_res_iron_ore_reserve")
		_expect("iron map_field", String(iron.get("map_field", "")) == "res_iron_ore_reserve_arr")


# ─── 2. registry / knobs ────────────────────────────────────────
# count-agnostic：注册表里资源数量会随测试资源增减，这里按 slot 名定位 arable/iron，
# 不再假设恰好 2 个或固定下标。
func _test_registry_knobs() -> void:
	ResourceProfileRegistry.ensure_loaded()
	var count: int = ResourceProfileRegistry.count()
	_expect("registry loaded >=2 profiles", count >= 2)
	_expect("registry loaded 31 profiles", count == 31)
	var knobs: Dictionary = ResourceProfileRegistry.build_pass_knobs()
	var normalized_temperature_contract: bool = true
	for profile in ResourceProfileRegistry.ordered():
		normalized_temperature_contract = normalized_temperature_contract \
				and float(profile.temp_lo) >= 0.0 and float(profile.temp_hi) <= 1.0 \
				and float(profile.temp_hi) > float(profile.temp_lo)
	_expect("all resource temperature ranges use map-normalized [0,1] units",
		normalized_temperature_contract)
	var ordered_profiles := ResourceProfileRegistry.ordered()
	var temperature_signals: PackedInt32Array = knobs.get(
		"temperature_signals", PackedInt32Array())
	var moisture_signals: PackedInt32Array = knobs.get(
		"moisture_signals", PackedInt32Array())
	_expect("resource climate signal columns align",
		temperature_signals.size() == count and moisture_signals.size() == count)
	for profile_id in ["fertile_soil", "timber", "wild_game"]:
		var profile_idx := _profile_index(ordered_profiles, profile_id)
		_expect("%s uses 30d temperature and plant water" % profile_id,
			profile_idx >= 0 and temperature_signals[profile_idx] == 1 and
			moisture_signals[profile_idx] == 1)
	for profile_id in ["freshwater_fish", "marine_fish"]:
		var profile_idx := _profile_index(ordered_profiles, profile_id)
		_expect("%s uses 30d temperature and ambient moisture" % profile_id,
			profile_idx >= 0 and temperature_signals[profile_idx] == 1 and
			moisture_signals[profile_idx] == 0)
	var iron_signal_idx := _profile_index(ordered_profiles, "iron_ore")
	_expect("geological resources retain current temperature and ambient moisture",
		iron_signal_idx >= 0 and temperature_signals[iron_signal_idx] == 0 and
		moisture_signals[iron_signal_idx] == 0)
	for static_id in ["iron_ore"]:
		var static_idx := _profile_index(ordered_profiles, static_id)
		var static_profile = ordered_profiles[static_idx] if static_idx >= 0 else null
		_expect("geological stock has no natural generation or decay: %s" % static_id,
			static_profile != null and float(static_profile.gen_base) == 0.0 and
			float(static_profile.gen_temp) == 0.0 and
			float(static_profile.gen_moisture) == 0.0 and
			float(static_profile.gen_self) == 0.0 and
			float(static_profile.decay_base) == 0.0 and
			float(static_profile.decay_temp) == 0.0 and
			float(static_profile.decay_moisture) == 0.0 and
			float(static_profile.decay_self) == 0.0)
	_expect("knobs resource_count matches registry count", int(knobs.get("resource_count", 0)) == count)
	var slots: PackedStringArray = knobs.get("reserve_slots", PackedStringArray())
	var extra_slots: PackedStringArray = knobs.get("extra_change_slots", PackedStringArray())
	var gen_self: PackedFloat32Array = knobs.get("gen_self", PackedFloat32Array())
	var gen_moisture: PackedFloat32Array = knobs.get(
		"gen_moisture", PackedFloat32Array())
	var decay_self: PackedFloat32Array = knobs.get(
		"decay_self", PackedFloat32Array())
	var runtime_fit_weight: PackedFloat32Array = knobs.get(
		"runtime_climate_fit_weight", PackedFloat32Array())
	var decay_stress: PackedFloat32Array = knobs.get(
		"decay_stress", PackedFloat32Array())
	var ecology_capacity: PackedFloat32Array = knobs.get(
		"ecology_capacity", PackedFloat32Array())
	var ecology_growth_rate: PackedFloat32Array = knobs.get(
		"ecology_growth_rate", PackedFloat32Array())
	var ecology_immigration: PackedFloat32Array = knobs.get(
		"ecology_immigration", PackedFloat32Array())
	var ecology_stress_mortality_rate: PackedFloat32Array = knobs.get(
		"ecology_stress_mortality_rate", PackedFloat32Array())
	var ai: int = _slot_index(slots, "cell_res_arable_land_reserve")
	var ii: int = _slot_index(slots, "cell_res_iron_ore_reserve")
	var gi: int = _slot_index(slots, "cell_res_wild_game_reserve")
	var fi: int = _slot_index(slots, "cell_res_fertile_soil_reserve")
	var pi: int = _slot_index(slots, "cell_res_pasture_reserve")
	_expect("reserve_slots has arable_land", ai >= 0)
	_expect("reserve_slots has iron_ore", ii >= 0)
	_expect("reserve_slots has wild_game", gi >= 0)
	_expect("reserve_slots has fertile_soil", fi >= 0)
	_expect("reserve_slots has pasture", pi >= 0)
	_expect("reserve_slots includes freshwater_fish", _slot_index(slots, "cell_res_freshwater_fish_reserve") >= 0)
	for retired_slot in ["cell_res_uranium_ore_reserve", "cell_res_nickel_ore_reserve",
			"cell_res_platinum_ore_reserve", "cell_res_lithium_reserve",
			"cell_res_cobalt_ore_reserve", "cell_res_natural_graphite_reserve"]:
		_expect("reserve_slots retired strategic split: %s" % retired_slot,
			_slot_index(slots, retired_slot) < 0)
	_expect("knobs has no capacity array", not knobs.has("capacity"))
	_expect("knobs exports habitat modes and mask slot",
		(knobs.get("habitat_modes", PackedInt32Array()) as PackedInt32Array).size() == count and
		String(knobs.get("habitat_mask_slot", "")) == "cell_resource_habitat_mask")
	_expect("extra_change_slots count matches reserve_slots", extra_slots.size() == slots.size())
	if ai >= 0:
		_expect("arable land extra slot", ai < extra_slots.size() and extra_slots[ai] == "cell_res_arable_land_extra_change")
	if ii >= 0:
		_expect("iron extra slot", ii < extra_slots.size() and extra_slots[ii] == "cell_res_iron_ore_extra_change")
		_expect("iron gen_self==0 (non-renewable)", is_equal_approx(gen_self[ii], 0.0))
	if gi >= 0:
		_expect("wild_game extra slot", gi < extra_slots.size() and extra_slots[gi] == "cell_res_wild_game_extra_change")
		# Bay-cell N=5000：authored ecology_capacity≈3260 → knobs 乘 CELL_AREA 后 ≥300000。
		_expect("wild_game enables province-scale density-dependent ecology",
			gi < ecology_capacity.size() and ecology_capacity[gi] >= 300000.0 and
			gi < ecology_growth_rate.size() and ecology_growth_rate[gi] > 0.0 and
			gi < ecology_immigration.size() and ecology_immigration[gi] > 0.0 and
			gi < ecology_stress_mortality_rate.size() and
			is_zero_approx(ecology_stress_mortality_rate[gi]))
	if fi >= 0:
		var minimum_runtime_fit := 1.0 - float(runtime_fit_weight[fi])
		var minimum_daily_production := float(gen_self[fi]) * minimum_runtime_fit - \
			float(decay_stress[fi]) * (1.0 - minimum_runtime_fit)
		var minimum_equilibrium := minimum_daily_production / float(decay_self[fi])
		_expect("fertile_soil keeps a positive worst-climate equilibrium",
			fi < gen_moisture.size() and minimum_daily_production > 0.0 and
			minimum_equilibrium >= 1.0)
	if pi >= 0:
		_expect("pasture extra slot", pi < extra_slots.size() and extra_slots[pi] == "cell_res_pasture_extra_change")


func _slot_index(slots: PackedStringArray, name: String) -> int:
	for i in range(slots.size()):
		if slots[i] == name:
			return i
	return -1


func _test_wilderness_bucket_selection() -> void:
	var gen := MapGenerator.new()
	gen._reset_natural_resource_cadence(120, 0)
	var live := PackedInt32Array([0, 4, 8])
	var planned: Dictionary = gen.collect_natural_resource_pass_cells(1, live)
	var indices: PackedInt32Array = planned.get("cell_indices", PackedInt32Array())
	var dts: PackedInt32Array = planned.get("cell_dt_days", PackedInt32Array())
	var seen := {}
	for k in range(indices.size()):
		seen[int(indices[k])] = int(dts[k])
	_expect("live cells always enter the resource pass",
		seen.has(0) and seen.has(4) and seen.has(8))
	_expect("wilderness bucket day 1 includes cell % 60 == 1",
		seen.has(1) and seen.has(61) and not seen.has(2))
	_expect("live and wilderness catchup dt is the real elapsed interval",
		int(seen.get(0, -1)) == 1 and int(seen.get(1, -1)) == 1)
	_expect("day-1 indexed set is live union one wilderness bucket",
		indices.size() == 5)
	var later: Dictionary = gen.collect_natural_resource_pass_cells(60, live)
	var later_seen := {}
	for cell in later.get("cell_indices", PackedInt32Array()):
		later_seen[int(cell)] = true
	_expect("wilderness 60-day bucket does not rescan every empty cell",
		later_seen.has(0) and later_seen.has(60) and not later_seen.has(1)
		and int(later.get("cell_indices", PackedInt32Array()).size()) == 4)


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
	var temp_30d := PackedFloat32Array()
	var plant_water := PackedFloat32Array()
	var water := PackedByteArray()
	var habitat := PackedByteArray()
	temp.resize(n)
	moist.resize(n)
	temp_30d.resize(n)
	plant_water.resize(n)
	water.resize(n)
	habitat.resize(n)
	for i in range(n):
		temp[i] = float(i) / float(n - 1)                     # 地图气候温度 [0,1]
		moist[i] = clampf(float(i) / float(n - 1), 0.0, 1.0)
		temp_30d[i] = 1.0 - temp[i]
		plant_water[i] = 1.0 - moist[i]
		water[i] = 1 if (i % 4 == 3) else 0                    # 水面格散布在 body 与 tail 段
		habitat[i] = 0 if water[i] != 0 else 1
	habitat[3] = 2 # 海洋水格
	habitat[2] |= 8 # 邻海陆格
	habitat[7] = 4 # 湖泊水格
	habitat[4] |= 4 # 河流陆格
	map.temp_arr = temp
	map.moisture_arr = moist
	map.temp_30d_arr = temp_30d
	map.plant_available_water_arr = plant_water
	map.is_water_arr = water
	map.resource_habitat_mask_arr = habitat

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
			arr[i] = (0.2 + 0.6 * (float(i % 5) / 4.0)) if \
				ResourceProfileRegistry.habitat_available(p, int(habitat[i])) else 0.0
		map.set(field, arr)
		fields.append(field)
		inits.append(arr.duplicate())
		var extra_field: String = ResourceProfileRegistry.extra_change_map_field(p)
		var extra_arr := PackedFloat32Array()
		extra_arr.resize(n)
		for i in range(n):
			extra_arr[i] = 0.0
		if String(p.id) == "iron_ore":
			extra_arr[0] = 0.5
		map.set(extra_field, extra_arr)
		extra_fields.append(extra_field)
		extra_inits.append(extra_arr.duplicate())

	var bind_ok := bool(ext.bind_map_data(map))
	_expect("bind_map_data succeeds", bind_ok)
	if not bind_ok:
		return

	var knobs: Dictionary = ResourceProfileRegistry.build_pass_knobs()
	knobs["n_cells"] = n

	# 先算每资源期望（GDScript 参考，同模板），再跑 native（多核 + SIMD）对拍。
	var expected: Array = []
	for idx in range(profiles.size()):
		var p = profiles[idx]
		var selected_temp: PackedFloat32Array = temp_30d \
			if String(p.runtime_temperature_signal) == "mean_30d" else temp
		var selected_moisture: PackedFloat32Array = plant_water \
			if String(p.runtime_moisture_signal) == "plant_available_water" else moist
		expected.append(_reference_step(idx, inits[idx], extra_inits[idx],
			selected_temp, selected_moisture, water, habitat, n, 1))

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
			# 省级数量尺度下 GDScript double 参考值与 native float32 允许约 2 ULP。
			var cell_tol := maxf(tol, absf(exp[i]) * 4.0e-7)
			if absf(got[i] - exp[i]) > cell_tol:
				ab_ok = false
				ab_detail = "%s[%d] native=%s ref=%s (tol=%s)" % [
					String(p.id), i, str(got[i]), str(exp[i]), str(cell_tol)]
				break
		if not ab_ok:
			break
	if not ab_ok:
		printerr("  [detail] %s" % ab_detail)
	_expect("native==reference for all resources × cells (SIMD body+tail+water blend)", ab_ok)

	# 关键不变量抽查。
	var marine_i: int = _profile_index(profiles, "marine_fish")
	if marine_i >= 0:
		var marine: PackedFloat32Array = map.get(fields[marine_i])
		_expect("marine fish lives on coastal land and marine water",
			marine[2] > 0.0 and marine[3] > 0.0 and is_equal_approx(marine[0], 0.0))
	var freshwater_i: int = _profile_index(profiles, "freshwater_fish")
	if freshwater_i >= 0:
		var freshwater: PackedFloat32Array = map.get(fields[freshwater_i])
		_expect("freshwater fish only lives on freshwater habitat",
			freshwater[7] > 0.0 and is_equal_approx(freshwater[0], 0.0) and
			is_equal_approx(freshwater[3], 0.0))

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
		# stride/catchup 下外部 delta 只应用一次，而不是乘以 dt_days。
		igot[0] = 1.0
		iextra[0] = 0.5
		map.set(fields[ii], igot)
		map.set(extra_fields[ii], iextra)
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 5
		ext.run_natural_resource_pass(knobs)
		igot = map.get(fields[ii])
		_expect("dt=5 applies iron external delta exactly once", absf(igot[0] - 1.5) < 1e-4)
		igot[0] = 2.0
		iextra[0] = 0.25
		map.set(fields[ii], igot)
		map.set(extra_fields[ii], iextra)
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 60
		ext.run_natural_resource_pass(knobs)
		igot = map.get(fields[ii])
		_expect("dt=60 applies iron extra_change exactly once", absf(igot[0] - 2.25) < 1e-4)
		knobs["dt_days"] = 1

		# 数亿级省域矿床的 float32 ULP 大于单矿周期扣减；extra slot 必须累计余量，
		# 不能因为本周期 reserve 无法表示变化就把开采量清零。
		const LARGE_STATIC_RESERVE := 500000000.0
		igot[0] = LARGE_STATIC_RESERVE
		iextra[0] = 0.0
		map.set(fields[ii], igot)
		map.set(extra_fields[ii], iextra)
		for _cycle in range(128):
			iextra = map.get(extra_fields[ii])
			iextra[0] -= 0.5
			map.set(extra_fields[ii], iextra)
			ext.refresh_slots_from_map()
			ext.run_natural_resource_pass(knobs)
		igot = map.get(fields[ii])
		iextra = map.get(extra_fields[ii])
		_expect("large static deposits retain sub-ULP extraction remainder",
			absf((igot[0] + iextra[0]) - (LARGE_STATIC_RESERVE - 64.0)) < 0.01)
		_expect("accumulated sub-ULP extraction eventually lowers reserve",
			igot[0] < LARGE_STATIC_RESERVE)

	var timber_i: int = _profile_index(profiles, "timber")
	if timber_i >= 0:
		var timber_profile = profiles[timber_i]
		var timber: PackedFloat32Array = map.get(fields[timber_i])
		var timber_extra: PackedFloat32Array = map.get(extra_fields[timber_i])
		var timber_capacity := float(timber_profile.ecology_capacity) * \
			ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
		var ideal_timber_temp := float(timber_profile.temp_lo) + \
			float(timber_profile.climate_temp_opt) * \
			(float(timber_profile.temp_hi) - float(timber_profile.temp_lo))
		# 高温高湿雨林必须属于适生林地，不能因湿度超过旧窄容差而触发急性死亡。
		var rainforest_tn := 0.90
		var rainforest_moisture := 0.95
		var rainforest_temp := float(timber_profile.temp_lo) + rainforest_tn * \
			(float(timber_profile.temp_hi) - float(timber_profile.temp_lo))
		var rainforest_temp_fit := 1.0 - clampf(absf(
			rainforest_tn - float(timber_profile.climate_temp_opt)) / maxf(
			float(timber_profile.climate_temp_tol), 0.0001), 0.0, 1.0)
		var rainforest_moisture_fit := 1.0 - clampf(absf(
			rainforest_moisture - float(timber_profile.climate_moisture_opt)) / maxf(
			float(timber_profile.climate_moisture_tol), 0.0001), 0.0, 1.0)
		var rainforest_raw_fit := rainforest_temp_fit * rainforest_moisture_fit
		var rainforest_runtime_fit := lerpf(1.0, rainforest_raw_fit,
			float(timber_profile.runtime_climate_fit_weight))
		var rainforest_capacity := timber_capacity * rainforest_runtime_fit
		var observed_rainforest_temp := 0.77
		var observed_rainforest_moisture := 0.56
		var observed_tn := clampf((observed_rainforest_temp - float(timber_profile.temp_lo)) / \
			maxf(float(timber_profile.temp_hi) - float(timber_profile.temp_lo), 0.0001), 0.0, 1.0)
		var observed_temp_fit := 1.0 - clampf(absf(
			observed_tn - float(timber_profile.climate_temp_opt)) / maxf(
			float(timber_profile.climate_temp_tol), 0.0001), 0.0, 1.0)
		var observed_moisture_fit := 1.0 - clampf(absf(
			observed_rainforest_moisture - float(timber_profile.climate_moisture_opt)) / maxf(
			float(timber_profile.climate_moisture_tol), 0.0001), 0.0, 1.0)
		var observed_runtime_fit := lerpf(1.0, observed_temp_fit * observed_moisture_fit,
			float(timber_profile.runtime_climate_fit_weight))
		var observed_capacity := timber_capacity * observed_runtime_fit
		var acute_temp := float(timber_profile.temp_lo)
		var acute_moisture := float(timber_profile.climate_moisture_opt)
		var acute_temp_fit := 1.0 - clampf(absf(
			float(timber_profile.climate_temp_opt)) / maxf(
			float(timber_profile.climate_temp_tol), 0.0001), 0.0, 1.0)
		var acute_raw_fit := acute_temp_fit
		var acute_runtime_fit := lerpf(1.0, acute_raw_fit,
			float(timber_profile.runtime_climate_fit_weight))
		var acute_capacity := timber_capacity * acute_runtime_fit
		_expect("timber treats hot humid rainforest as non-acute habitat",
			rainforest_raw_fit >= 0.25)
		_expect("observed tropical rainforest keeps multi-million timber capacity",
			observed_capacity >= 4000000.0)
		_expect("timber regression covers acute low climate fit", acute_raw_fit < 0.05)
		temp[0] = ideal_timber_temp
		moist[0] = timber_profile.climate_moisture_opt
		temp[1] = rainforest_temp
		moist[1] = rainforest_moisture
		temp[2] = acute_temp
		moist[2] = acute_moisture
		timber[0] = timber_capacity * 0.5
		timber[1] = rainforest_capacity
		timber[2] = acute_capacity * 0.5
		timber_extra.fill(0.0)
		map.set(fields[timber_i], timber)
		map.set(extra_fields[timber_i], timber_extra)
		map.temp_arr = temp
		map.moisture_arr = moist
		map.temp_30d_arr = temp.duplicate()
		map.plant_available_water_arr = moist.duplicate()
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 1
		ext.run_natural_resource_pass(knobs)
		timber = map.get(fields[timber_i])
		_expect("timber naturally grows below carrying capacity",
			timber[0] > timber_capacity * 0.5)
		_expect("timber acute stress remains bounded and nonnegative",
			timber[2] >= 0.0 and timber[2] <= acute_capacity)
		timber[0] = timber_capacity
		timber[1] = rainforest_capacity
		timber_extra.fill(0.0)
		map.set(fields[timber_i], timber)
		map.set(extra_fields[timber_i], timber_extra)
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 5
		for _cycle in range(365):
			timber_extra = map.get(extra_fields[timber_i])
			timber_extra[0] = -450.0
			timber_extra[1] = -450.0
			map.set(extra_fields[timber_i], timber_extra)
			ext.refresh_slots_from_map()
			ext.run_natural_resource_pass(knobs)
		timber = map.get(fields[timber_i])
		_expect("timber sustains five years of one-camp harvest in ideal habitat",
			timber[0] > timber_capacity * 0.5)
		_expect("timber sustains five years of one-camp harvest in rainforest habitat",
			timber[1] > rainforest_capacity * 0.5)

	var wild_i: int = _profile_index(profiles, "wild_game")
	if wild_i >= 0:
		var wild_profile = profiles[wild_i]
		var wild: PackedFloat32Array = map.get(fields[wild_i])
		var wild_extra: PackedFloat32Array = map.get(extra_fields[wild_i])
		var capacity := float(wild_profile.ecology_capacity) * \
			ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
		wild[0] = 0.0
		wild[1] = capacity * 0.5
		wild[2] = capacity * 2.0
		var ordinary_raw_fit := 0.5
		var ordinary_runtime_fit := lerpf(
			1.0, ordinary_raw_fit, float(wild_profile.runtime_climate_fit_weight))
		var ordinary_capacity := capacity * ordinary_runtime_fit
		wild[5] = ordinary_capacity * 0.5
		wild[4] = capacity * 0.5
		wild_extra.fill(0.0)
		var ideal_temp := float(wild_profile.temp_lo) + float(wild_profile.climate_temp_opt) * (
			float(wild_profile.temp_hi) - float(wild_profile.temp_lo))
		temp[0] = ideal_temp; temp[1] = ideal_temp; temp[2] = ideal_temp
		moist[0] = wild_profile.climate_moisture_opt
		moist[1] = wild_profile.climate_moisture_opt
		moist[2] = wild_profile.climate_moisture_opt
		temp[5] = float(wild_profile.temp_lo) + (
			float(wild_profile.climate_temp_opt) +
			float(wild_profile.climate_temp_tol) * (1.0 - ordinary_raw_fit)) * (
			float(wild_profile.temp_hi) - float(wild_profile.temp_lo))
		moist[5] = wild_profile.climate_moisture_opt
		temp[4] = wild_profile.temp_lo
		moist[4] = 0.0
		map.set(fields[wild_i], wild)
		map.set(extra_fields[wild_i], wild_extra)
		map.temp_arr = temp
		map.moisture_arr = moist
		map.temp_30d_arr = temp.duplicate()
		map.plant_available_water_arr = moist.duplicate()
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 1
		ext.run_natural_resource_pass(knobs)
		wild = map.get(fields[wild_i])
		_expect("wild_game recovers from zero through immigration", wild[0] > 0.0)
		_expect("wild_game grows below carrying capacity", wild[1] > capacity * 0.5)
		_expect("wild_game naturally declines above carrying capacity", wild[2] < capacity * 2.0)
		_expect("wild_game grows in ordinary non-ideal climate",
			wild[5] > ordinary_capacity * 0.5)
		_expect("wild_game climate stress suppresses population",
			wild[4] < wild[1])

		var ordinary_no_harvest_start := wild[5]
		knobs["dt_days"] = 5
		for _cycle in range(146):
			ext.run_natural_resource_pass(knobs)
		wild = map.get(fields[wild_i])
		_expect("wild_game ordinary habitat has no abnormal two-year natural die-off",
			wild[5] >= ordinary_no_harvest_start * 0.98)

		# 从权威建筑内容读取真实采收率。715 GOODS_SCALE = 0.715 资源单位/栋/日；
		# 24 座营地按五日周期一次扣 85.8，避免用过时的 60 低估生态压力。
		var hunting_profile = load(
			"res://data/economy/buildings/stone_age_hunting_camp.tres")
		var harvest_per_cycle := 24.0 * float(
			hunting_profile.resource_quantities_per_day[0]) / 1000.0 * 5.0
		wild[0] = capacity
		wild[5] = ordinary_capacity
		wild_extra.fill(0.0)
		map.set(fields[wild_i], wild)
		map.set(extra_fields[wild_i], wild_extra)
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 5
		for _cycle in range(365):
			wild_extra = map.get(extra_fields[wild_i])
			wild_extra[0] = -harvest_per_cycle
			wild_extra[5] = -harvest_per_cycle
			map.set(extra_fields[wild_i], wild_extra)
			ext.refresh_slots_from_map()
			ext.run_natural_resource_pass(knobs)
		wild = map.get(fields[wild_i])
		_expect("wild_game remains viable after five years of 24-camp harvest at ideal habitat",
			wild[0] > capacity * 0.65)
		_expect("wild_game ordinary habitat visibly depletes but remains viable under 24 camps",
			wild[5] > ordinary_capacity * 0.35 and wild[5] < ordinary_capacity * 0.9)

	var fertile_i: int = _profile_index(profiles, "fertile_soil")
	if fertile_i >= 0:
		var fertile_profile = profiles[fertile_i]
		var fertile: PackedFloat32Array = map.get(fields[fertile_i])
		var fertile_extra: PackedFloat32Array = map.get(extra_fields[fertile_i])
		fertile[0] = 1.0
		fertile_extra.fill(0.0)
		temp[0] = fertile_profile.temp_lo
		moist[0] = 0.0
		map.set(fields[fertile_i], fertile)
		map.set(extra_fields[fertile_i], fertile_extra)
		map.temp_arr = temp
		map.moisture_arr = moist
		map.temp_30d_arr = temp.duplicate()
		map.plant_available_water_arr = moist.duplicate()
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 30
		for _month in range(47):
			ext.run_natural_resource_pass(knobs)
		fertile = map.get(fields[fertile_i])
		var minimum_fit := 1.0 - float(fertile_profile.runtime_climate_fit_weight)
		var minimum_p := ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE * (
			float(fertile_profile.gen_self) * minimum_fit -
			float(fertile_profile.decay_stress) * (1.0 - minimum_fit))
		var minimum_equilibrium := minimum_p / float(fertile_profile.decay_self)
		_expect("fertile_soil recovers gradually below its long-run floor",
			fertile[0] > 1.0 and fertile[0] < minimum_equilibrium)

	if wild_i >= 0:
		var modifier_profile = profiles[wild_i]
		var modifier_reserve: PackedFloat32Array = map.get(fields[wild_i])
		var modifier_extra: PackedFloat32Array = map.get(extra_fields[wild_i])
		modifier_reserve[0] = 0.0
		modifier_extra[0] = 100.0
		var modifier_temp := float(modifier_profile.temp_lo) + \
			float(modifier_profile.climate_temp_opt) * (
				float(modifier_profile.temp_hi) - float(modifier_profile.temp_lo))
		temp[0] = modifier_temp
		moist[0] = float(modifier_profile.climate_moisture_opt)
		map.set(fields[wild_i], modifier_reserve)
		map.set(extra_fields[wild_i], modifier_extra)
		map.temp_arr = temp
		map.moisture_arr = moist
		map.temp_30d_arr = temp.duplicate()
		map.plant_available_water_arr = moist.duplicate()
		var modifier_expected: PackedFloat32Array = _reference_step(
			wild_i, modifier_reserve, modifier_extra, temp, moist, water, habitat, n, 1)
		var modifier_factors := PackedFloat32Array()
		modifier_factors.resize(profiles.size() * n)
		modifier_factors.fill(1.0)
		modifier_factors[wild_i * n] = 2.0
		knobs["regen_factors"] = modifier_factors
		knobs["regen_modifier_snapshot_version"] = 42
		knobs["dt_days"] = 1
		ext.refresh_slots_from_map()
		var modifier_result: Dictionary = ext.run_natural_resource_pass(knobs)
		modifier_reserve = map.get(fields[wild_i])
		var reserve_after_external := 100.0
		var scaled_expected := reserve_after_external + maxf(
			0.0, modifier_expected[0] - reserve_after_external) * 2.0
		if absf(modifier_reserve[0] - scaled_expected) >= maxf(
				0.0001, absf(scaled_expected) * 0.000001):
			printerr("  [detail] regen modifier native=%s ref=%s raw=%s" % [
				str(modifier_reserve[0]), str(scaled_expected), str(modifier_expected[0])])
		_expect("regen factor scales only natural positive growth",
			absf(modifier_reserve[0] - scaled_expected) < maxf(
				0.0001, absf(scaled_expected) * 0.000001))
		_expect("regen factor report publishes frozen snapshot",
			int(modifier_result.get("regen_modifier_snapshot_version", 0)) == 42 and
			int(modifier_result.get("active_regen_factor_count", 0)) == 1)

	knobs.erase("regen_factors")
	if fertile_i >= 0:
		var fertile_profile = profiles[fertile_i]
		var fertile: PackedFloat32Array = map.get(fields[fertile_i])
		var fertile_extra: PackedFloat32Array = map.get(extra_fields[fertile_i])
		fertile[0] = 8.0
		fertile[1] = 8.0
		fertile_extra.fill(0.0)
		fertile_extra[0] = -1.0
		temp[0] = float(fertile_profile.temp_lo) + float(fertile_profile.climate_temp_opt) * (
			float(fertile_profile.temp_hi) - float(fertile_profile.temp_lo))
		temp[1] = temp[0]
		moist[0] = float(fertile_profile.climate_moisture_opt)
		moist[1] = moist[0]
		map.set(fields[fertile_i], fertile)
		map.set(extra_fields[fertile_i], fertile_extra)
		map.temp_arr = temp
		map.moisture_arr = moist
		map.temp_30d_arr = temp.duplicate()
		map.plant_available_water_arr = moist.duplicate()
		var selected_temp: PackedFloat32Array = map.temp_30d_arr if \
			String(fertile_profile.runtime_temperature_signal) == "mean_30d" else map.temp_arr
		var selected_moist: PackedFloat32Array = map.plant_available_water_arr if \
			String(fertile_profile.runtime_moisture_signal) == "plant_available_water" else map.moisture_arr
		var closed: PackedFloat32Array = _reference_step(
			fertile_i, fertile, fertile_extra, selected_temp, selected_moist, water, habitat, n, 60)
		var iterated := fertile.duplicate()
		var iterated_extra := fertile_extra.duplicate()
		for _day in range(60):
			iterated = _reference_step(
				fertile_i, iterated, iterated_extra, selected_temp, selected_moist, water, habitat, n, 1)
			iterated_extra.fill(0.0)
		_expect("dt=60 IMEX closed form matches 60 daily steps",
			absf(closed[0] - iterated[0]) < maxf(0.02, absf(iterated[0]) * 0.001))
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 60
		ext.run_natural_resource_pass(knobs)
		fertile = map.get(fields[fertile_i])
		_expect("native dt=60 matches IMEX closed form",
			absf(fertile[0] - closed[0]) < maxf(0.02, absf(closed[0]) * 0.001))
		fertile_extra = map.get(extra_fields[fertile_i])
		_expect("dt=60 extra_change applied once then cleared",
			is_equal_approx(fertile_extra[0], 0.0))

	if wild_i >= 0:
		var wild_profile = profiles[wild_i]
		var wild: PackedFloat32Array = map.get(fields[wild_i])
		var wild_extra: PackedFloat32Array = map.get(extra_fields[wild_i])
		var capacity := float(wild_profile.ecology_capacity) * \
			ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
		wild[0] = capacity * 0.4
		wild_extra.fill(0.0)
		wild_extra[0] = -2.0
		var ideal_temp := float(wild_profile.temp_lo) + float(wild_profile.climate_temp_opt) * (
			float(wild_profile.temp_hi) - float(wild_profile.temp_lo))
		temp[0] = ideal_temp
		moist[0] = wild_profile.climate_moisture_opt
		map.set(fields[wild_i], wild)
		map.set(extra_fields[wild_i], wild_extra)
		map.temp_arr = temp
		map.moisture_arr = moist
		map.temp_30d_arr = temp.duplicate()
		map.plant_available_water_arr = moist.duplicate()
		var bh_closed: PackedFloat32Array = _reference_step(
			wild_i, wild, wild_extra, temp, moist, water, habitat, n, 60)
		var bh_iter := wild.duplicate()
		var bh_extra := wild_extra.duplicate()
		for _day in range(60):
			bh_iter = _reference_step(wild_i, bh_iter, bh_extra, temp, moist, water, habitat, n, 1)
			bh_extra.fill(0.0)
		_expect("BH dt=60 daily iteration matches 60 daily steps",
			absf(bh_closed[0] - bh_iter[0]) < maxf(0.05, absf(bh_iter[0]) * 0.002))
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 60
		ext.run_natural_resource_pass(knobs)
		wild = map.get(fields[wild_i])
		_expect("native BH dt=60 matches daily iteration",
			absf(wild[0] - bh_closed[0]) < maxf(0.05, absf(bh_closed[0]) * 0.002))

	if timber_i >= 0:
		var timber: PackedFloat32Array = map.get(fields[timber_i])
		var timber_extra: PackedFloat32Array = map.get(extra_fields[timber_i])
		var before_other: float = timber[1]
		timber_extra.fill(0.0)
		map.set(fields[timber_i], timber)
		map.set(extra_fields[timber_i], timber_extra)
		ext.refresh_slots_from_map()
		knobs["dt_days"] = 1
		knobs["cell_indices"] = PackedInt32Array([0])
		var indexed_res: Dictionary = ext.run_natural_resource_pass(knobs)
		timber = map.get(fields[timber_i])
		_expect("cell_indices leaves non-listed cells unchanged",
			is_equal_approx(timber[1], before_other))
		_expect("indexed pass reports cell_indices layout",
			str(indexed_res.get("loop_layout", "")) == "cell_indices")
		knobs.erase("cell_indices")
		knobs.erase("cell_dt_days")
		knobs["dt_days"] = 1


func _profile_index(profiles: Array, id_name: String) -> int:
	for i in range(profiles.size()):
		if String(profiles[i].id) == id_name:
			return i
	return -1


# GDScript 参考实现：与 C++ run_natural_resource_pass / map_generator fallback 同公式。
func _reference_step(res_idx: int, reserve_in: PackedFloat32Array, extra_in: PackedFloat32Array, temp: PackedFloat32Array,
		moist: PackedFloat32Array, water: PackedByteArray, habitat: PackedByteArray,
		n: int, dt_days: int) -> PackedFloat32Array:
	var profiles: Array = ResourceProfileRegistry.ordered()
	var p = profiles[res_idx]
	var out := reserve_in.duplicate()
	var quantity_scale := ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
	var lo: float = p.temp_lo
	var hi: float = p.temp_hi
	var inv_span: float = (1.0 / (hi - lo)) if hi > lo else 0.0
	for i in range(n):
		if not ResourceProfileRegistry.habitat_available(p, int(habitat[i])):
			out[i] = 0.0
			continue
		var tn: float = clampf((temp[i] - lo) * inv_span, 0.0, 1.0)
		var m: float = moist[i]
		var reserve: float = out[i]
		var extra_change: float = extra_in[i] if i < extra_in.size() else 0.0
		# 半隐式（IMEX）：与 C++ run_natural_resource_pass / fallback 同模板。
		var fit_weight: float = clampf(p.runtime_climate_fit_weight, 0.0, 1.0)
		var climate_fit: float = 1.0
		var runtime_fit: float = 1.0
		if fit_weight != 0.0 or p.decay_stress != 0.0 or \
				p.ecology_stress_mortality_rate != 0.0:
			var temp_fit: float = 1.0 - clampf(absf(tn - p.climate_temp_opt) / maxf(p.climate_temp_tol, 0.0001), 0.0, 1.0)
			var moisture_fit: float = 1.0 - clampf(absf(m - p.climate_moisture_opt) / maxf(p.climate_moisture_tol, 0.0001), 0.0, 1.0)
			climate_fit = temp_fit * moisture_fit
			runtime_fit = lerpf(1.0, climate_fit, fit_weight)
		var reserve_after_external := maxf(0.0, reserve + extra_change)
		var v: float
		if float(p.ecology_capacity) > 0.0:
			var capacity := maxf(0.0, float(p.ecology_capacity) * quantity_scale * runtime_fit)
			var growth_factor := 1.0 + maxf(0.0, float(p.ecology_growth_rate)) * runtime_fit
			var immigration := maxf(0.0, float(p.ecology_immigration)) * quantity_scale * runtime_fit
			var acute_stress := clampf((0.25 - climate_fit) / 0.25, 0.0, 1.0)
			var stress_denom := 1.0 + maxf(0.0, float(
				p.ecology_stress_mortality_rate)) * acute_stress
			v = reserve_after_external
			for _day in range(maxi(1, dt_days)):
				var seeded := v + immigration
				if capacity <= 0.000001:
					v = 0.0
					continue
				var density_denom := 1.0 + (growth_factor - 1.0) * seeded / capacity
				v = maxf(0.0, growth_factor * seeded / density_denom / stress_denom)
		else:
			var gen_climate: float = quantity_scale * (
				p.gen_base + p.gen_temp * tn + p.gen_moisture * m)
			var decay_climate: float = quantity_scale * (
				p.decay_base + p.decay_temp * tn + p.decay_moisture * m)
			var gen_self_eff: float = quantity_scale * p.gen_self * runtime_fit
			var P: float = gen_climate + gen_self_eff - decay_climate - \
				quantity_scale * p.decay_stress * (1.0 - runtime_fit)
			var L: float = maxf(0.0, p.decay_self)
			if dt_days <= 1:
				v = (reserve_after_external + P) / (1.0 + L)
			elif L <= 0.0:
				v = reserve_after_external + P * float(dt_days)
			else:
				var inv_denom := 1.0 / (1.0 + L)
				var a_pow := pow(inv_denom, float(dt_days))
				v = a_pow * reserve_after_external + P * inv_denom * (1.0 - a_pow) / (1.0 - inv_denom)
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
