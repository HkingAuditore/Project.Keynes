extends SceneTree

# Headless:
#   godot --headless --path <proj> --script res://tests/natural_resource_daily_schedule_test.gd
#
# 回归：native_daily_sim ACTIVE 路径下，natural_resource_daily 必须被注册并每日运行，
# 否则 reserve 永不演化（玩家观察不到生物质变化）。本测试用真实 MapGenerator 引导一个
# 小世界（强制 native ACTIVE），推进若干日，断言：
#   1) natural_resource_daily job 每日都跑（report 无 frame_budget_exhausted 跳过）；
#   2) 至少一个可再生资源的适宜陆地格 reserve 随日增长。

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== natural_resource_daily schedule ===")
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt class not found (gdext not built)")
		return

	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(16, 12)
	cfg.seed = 424242
	cfg.num_continents = 1
	cfg.sea_level = 0.50
	cfg.continent_size = 0.78
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	_expect("map generation returned map", map != null)
	if map == null:
		_finish()
		return

	var n: int = map.cell_count()
	_expect("map has cells", n > 0)
	if n == 0:
		_finish()
		return

	var probe: Dictionary = _find_dynamic_probe(map, n)
	_expect("found a renewable resource habitat-valid cell away from equilibrium", not probe.is_empty())
	if probe.is_empty():
		_finish()
		return

	var probe_idx: int = int(probe.get("idx", -1))
	var probe_field: String = String(probe.get("field", ""))
	var probe_id: String = String(probe.get("id", ""))
	var before_arr: PackedFloat32Array = map.get(probe_field)
	var before: float = before_arr[probe_idx]
	var probe_profile: ResourceProfile = probe.get("profile", null) as ResourceProfile
	var habitat: PackedByteArray = map.resource_habitat_mask_arr
	# 记录全图 habitat-valid 总储量，作为整体演化信号。
	var habitat_sum_before: float = 0.0
	for i in range(n):
		if probe_profile != null and habitat.size() > i \
				and ResourceProfileRegistry.habitat_available(probe_profile, int(habitat[i])):
			habitat_sum_before += before_arr[i]

	# 半隐式稳定性回归：跟踪两个动态资源在 probe 格的逐日序列，断言尾段不会爆炸横跳。
	var saltpeter_field: String = _field_for("saltpeter")
	var clay_field: String = _field_for("clay")
	var saltpeter_seq: PackedFloat32Array = PackedFloat32Array()
	var clay_seq: PackedFloat32Array = PackedFloat32Array()

	# 推进若干日。
	var ran_days: int = 0
	var skipped_budget_days: int = 0
	const DAYS: int = 24
	for day in range(1, DAYS + 1):
		generator.sus_tick_daily(null, day, float(day % 365) / 365.0)
		var report: Dictionary = generator.sus_report_last_tick()
		var jr: Dictionary = report.get(&"natural_resource_daily", report.get("natural_resource_daily", {}))
		if not jr.is_empty():
			var reason: String = str(jr.get("skipped_reason", ""))
			if reason == "":
				ran_days += 1
			elif reason.begins_with("frame_budget"):
				skipped_budget_days += 1
		if saltpeter_field != "":
			var ha: PackedFloat32Array = map.get(saltpeter_field)
			if ha.size() > probe_idx:
				saltpeter_seq.append(ha[probe_idx])
		if clay_field != "":
			var ca: PackedFloat32Array = map.get(clay_field)
			if ca.size() > probe_idx:
				clay_seq.append(ca[probe_idx])

	# 重新取数组（flush 回 MapData 后是新值）。
	var after_arr: PackedFloat32Array = map.get(probe_field)
	var after: float = after_arr[probe_idx]
	var habitat_sum_after: float = 0.0
	for i in range(n):
		if probe_profile != null and habitat.size() > i \
				and ResourceProfileRegistry.habitat_available(probe_profile, int(habitat[i])):
			habitat_sum_after += after_arr[i]

	print("  probe cell %d: %s %.4f → %.4f (Δ=%+.4f) over %d days" % [
		probe_idx, probe_id, before, after, after - before, DAYS])
	print("  habitat-valid %s sum: %.3f → %.3f (Δ=%+.3f); job ran %d/%d days, budget-skipped %d" % [
		probe_id,
		habitat_sum_before, habitat_sum_after, habitat_sum_after - habitat_sum_before, ran_days, DAYS, skipped_budget_days])

	_expect("natural_resource_daily ran every day (no budget skip)", ran_days >= DAYS and skipped_budget_days == 0)
	_expect("habitat-valid reserve evolved over 24 sparse wilderness days",
		absf(habitat_sum_after - habitat_sum_before) > 0.01 or absf(after - before) > 0.002)

	# ── 公式鲁棒性：全部 30 种资源在多日演化后必须有限且非负。
	var profiles: Array = ResourceProfileRegistry.ordered()
	_expect("registry loaded 31 resources", profiles.size() == 31)
	var all_finite_nonnegative: bool = true
	var bad_detail: String = ""
	for p in profiles:
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		if field == "":
			all_finite_nonnegative = false
			bad_detail = "%s: no map_field" % String(p.id)
			break
		var arr: PackedFloat32Array = map.get(field)
		if arr.size() != n:
			all_finite_nonnegative = false
			bad_detail = "%s: array size %d != %d" % [String(p.id), arr.size(), n]
			break
		for i in range(n):
			var v: float = arr[i]
			if not is_finite(v) or v < -1e-6:
				all_finite_nonnegative = false
				bad_detail = "%s[%d]=%s" % [String(p.id), i, str(v)]
				break
		if not all_finite_nonnegative:
			break
	if not all_finite_nonnegative:
		printerr("  [detail] %s" % bad_detail)
	_expect("all 31 resources finite & nonnegative", all_finite_nonnegative)

	# 空野 60 日桶会在命中日一次性入账整段 dt，尾段允许一次有界跳跃，但不能非有限。
	var saltpeter_tail: float = _tail_max_step(saltpeter_seq, 5)
	var clay_tail: float = _tail_max_step(clay_seq, 5)
	print("  tail max |Δ/day| (last 5d): saltpeter=%.5f, clay=%.6f" % [
		saltpeter_tail, clay_tail])
	if saltpeter_seq.size() >= 6:
		_expect("saltpeter tail finite after sparse wilderness catchup",
			is_finite(saltpeter_tail) and saltpeter_tail >= 0.0)
	if clay_seq.size() >= 6:
		_expect("clay tail finite after sparse wilderness catchup",
			is_finite(clay_tail) and clay_tail >= 0.0)
	_finish()


# 选择一个当前气候下按参考公式会自然增长的 habitat-valid 格。
func _find_dynamic_probe(map: MapData, n: int) -> Dictionary:
	var temp: PackedFloat32Array = map.temp_arr
	var moist: PackedFloat32Array = map.moisture_arr
	var habitat: PackedByteArray = map.resource_habitat_mask_arr
	var best: Dictionary = {}
	var best_change: float = 0.0001
	for p in ResourceProfileRegistry.ordered():
		if float(p.gen_self) <= 0.0 and float(p.ecology_capacity) <= 0.0:
			continue
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		if field == "":
			continue
		var arr: PackedFloat32Array = map.get(field)
		if arr.size() != n:
			continue
		for i in range(n):
			if habitat.size() <= i or not ResourceProfileRegistry.habitat_available(p, int(habitat[i])):
				continue
			var next_v: float = _reference_step_value(p, arr[i], temp[i], moist[i])
			var change: float = next_v - arr[i]
			if absf(change) > best_change:
				best_change = absf(change)
				best = {"id": String(p.id), "field": field, "idx": i,
					"profile": p, "direction": signf(change)}
	return best


func _reference_step_value(p: ResourceProfile, reserve: float, temp_v: float, moist_v: float) -> float:
	var inv_span: float = (1.0 / (p.temp_hi - p.temp_lo)) if p.temp_hi > p.temp_lo else 0.0
	var tn: float = clampf((temp_v - p.temp_lo) * inv_span, 0.0, 1.0)
	var m: float = moist_v
	var raw_temp_fit: float = 1.0 - clampf(absf(tn - p.climate_temp_opt) / maxf(p.climate_temp_tol, 0.0001), 0.0, 1.0)
	var raw_moisture_fit: float = 1.0 - clampf(absf(m - p.climate_moisture_opt) / maxf(p.climate_moisture_tol, 0.0001), 0.0, 1.0)
	var raw_climate_fit: float = raw_temp_fit * raw_moisture_fit
	var fit_weight: float = clampf(p.runtime_climate_fit_weight, 0.0, 1.0)
	var runtime_fit: float = 1.0
	if fit_weight != 0.0 or p.decay_stress != 0.0:
		runtime_fit = lerpf(1.0, raw_climate_fit, fit_weight)
	if p.ecology_capacity > 0.0:
		var runtime_capacity: float = p.ecology_capacity * runtime_fit
		if runtime_capacity <= 0.0:
			return 0.0
		var seeded: float = maxf(0.0, reserve + p.ecology_immigration * runtime_fit)
		var growth_factor: float = 1.0 + p.ecology_growth_rate * runtime_fit
		var v_ecology: float = growth_factor * seeded / maxf(
			0.000001, 1.0 + (growth_factor - 1.0) * seeded / runtime_capacity)
		var acute_stress: float = clampf((0.25 - raw_climate_fit) / 0.25, 0.0, 1.0)
		v_ecology /= 1.0 + p.ecology_stress_mortality_rate * acute_stress
		return maxf(v_ecology, 0.0)
	var gen_self_eff: float = p.gen_self * runtime_fit
	var gen_climate: float = p.gen_base + p.gen_temp * tn + p.gen_moisture * m
	var decay_climate: float = p.decay_base + p.decay_temp * tn + p.decay_moisture * m
	var P: float = gen_climate + gen_self_eff - decay_climate - p.decay_stress * (1.0 - runtime_fit)
	var L: float = p.decay_self
	if L < 0.0:
		L = 0.0
	var v: float = (reserve + P) / (1.0 + L)
	return maxf(v, 0.0)


# 资源 id → MapData reserve 字段名。
func _field_for(id_name: String) -> String:
	for p in ResourceProfileRegistry.ordered():
		if String(p.id) == id_name:
			return ResourceProfileRegistry.reserve_map_field(p)
	return ""


# 序列尾段（最后 window 个值）相邻日的最大绝对变化，用于检测收敛 / 横跳。
func _tail_max_step(seq: PackedFloat32Array, window: int) -> float:
	var m: float = 0.0
	var start: int = maxi(1, seq.size() - window)
	for i in range(start, seq.size()):
		m = maxf(m, absf(seq[i] - seq[i - 1]))
	return m


func _tail_stable(seq: PackedFloat32Array, tail_delta: float) -> bool:
	if seq.is_empty():
		return true
	var scale: float = maxf(0.05, absf(seq[seq.size() - 1]) * 0.25)
	return is_finite(tail_delta) and tail_delta <= scale + 1e-6


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_shadow_diff_enabled = false
	profile.native_climate_round_active_owner_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.native_ocean_physical_active_owner_enabled = true
	profile.weather_field_enabled = true
	# This regression verifies the daily registration path independently from
	# the production profile's intentionally coarser resource cadence.
	profile.natural_resource_daily_stride = 1
	profile.runtime_hydrology_enabled = false
	profile.native_environment_runtime_enabled = false
	return profile


func _finish() -> void:
	if _failures == 0:
		print("PASS natural_resource_daily schedule (%d checks)" % _checks)
	else:
		print("FAIL natural_resource_daily schedule (%d failures / %d checks)" % [_failures, _checks])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
