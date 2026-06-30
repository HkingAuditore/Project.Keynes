extends SceneTree

# Headless:
#   godot --headless --path <proj> --script res://tests/natural_resource_daily_schedule_test.gd
#
# 回归：native_daily_sim ACTIVE 路径下，natural_resource_daily 必须被注册并每日运行，
# 否则 reserve 永不演化（玩家观察不到生物质变化）。本测试用真实 MapGenerator 引导一个
# 小世界（强制 native ACTIVE），推进若干日，断言：
#   1) natural_resource_daily job 每日都跑（report 无 frame_budget_exhausted 跳过）；
#   2) 至少一个陆地格的 biomass reserve 随日增长。

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
	var generated: Dictionary = generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	_expect("map generation returned map", map != null)
	if map == null:
		_finish()
		return

	var n: int = map.cell_count()
	var biomass: PackedFloat32Array = map.res_biomass_reserve_arr
	var water: PackedByteArray = map.is_water_arr
	_expect("biomass reserve array sized to N", biomass.size() == n and n > 0)
	if biomass.size() != n or n == 0:
		_finish()
		return

	# 选一个有增长空间的陆地格（初值 < 0.8）。
	var probe_idx: int = -1
	for i in range(n):
		var is_water: bool = water.size() > i and water[i] != 0
		if not is_water and biomass[i] < 0.8:
			probe_idx = i
			break
	_expect("found a land cell with growth headroom", probe_idx >= 0)
	if probe_idx < 0:
		_finish()
		return

	var before: float = biomass[probe_idx]
	# 记录全图陆地总储量，作为整体演化信号。
	var land_sum_before: float = 0.0
	for i in range(n):
		if not (water.size() > i and water[i] != 0):
			land_sum_before += biomass[i]

	# 半隐式稳定性回归：跟踪刚性资源（草药/黏土）在 probe 格的逐日序列，断言收敛后
	# 不再 0↔capacity 横跳（旧显式 Euler 会发散）。
	var herbs_field: String = _field_for("wild_herbs")
	var clay_field: String = _field_for("clay")
	var herbs_cap: float = _cap_for("wild_herbs")
	var clay_cap: float = _cap_for("clay")
	var herbs_seq: PackedFloat32Array = PackedFloat32Array()
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
		if herbs_field != "":
			var ha: PackedFloat32Array = map.get(herbs_field)
			if ha.size() > probe_idx:
				herbs_seq.append(ha[probe_idx])
		if clay_field != "":
			var ca: PackedFloat32Array = map.get(clay_field)
			if ca.size() > probe_idx:
				clay_seq.append(ca[probe_idx])

	# 重新取数组（flush 回 MapData 后是新值）。
	var after_arr: PackedFloat32Array = map.res_biomass_reserve_arr
	var after: float = after_arr[probe_idx]
	var land_sum_after: float = 0.0
	for i in range(n):
		if not (water.size() > i and water[i] != 0):
			land_sum_after += after_arr[i]

	print("  probe cell %d: biomass %.4f → %.4f (Δ=%+.4f) over %d days" % [
		probe_idx, before, after, after - before, DAYS])
	print("  land biomass sum: %.3f → %.3f (Δ=%+.3f); job ran %d/%d days, budget-skipped %d" % [
		land_sum_before, land_sum_after, land_sum_after - land_sum_before, ran_days, DAYS, skipped_budget_days])

	_expect("natural_resource_daily ran every day (no budget skip)", ran_days >= DAYS and skipped_budget_days == 0)
	_expect("probe land cell biomass increased over time", after > before + 0.002)
	_expect("total land biomass increased over time", land_sum_after > land_sum_before + 0.01)

	# ── 极限公式鲁棒性：全部 12 种资源在多日演化后必须有限且严格 clamp 到 [0, capacity]，
	#    包含极小容量(clay=0.001)/超大容量(coal,stone=1e6)/饱和级系数(wild_herbs gen5.0)等极端配置。
	var profiles: Array = ResourceProfileRegistry.ordered()
	_expect("registry loaded 12 resources", profiles.size() == 12)
	var all_finite_clamped: bool = true
	var bad_detail: String = ""
	for p in profiles:
		var field: String = ResourceProfileRegistry.reserve_map_field(p)
		if field == "":
			all_finite_clamped = false
			bad_detail = "%s: no map_field" % String(p.id)
			break
		var arr: PackedFloat32Array = map.get(field)
		if arr.size() != n:
			all_finite_clamped = false
			bad_detail = "%s: array size %d != %d" % [String(p.id), arr.size(), n]
			break
		var cap: float = float(p.capacity)
		var hi_tol: float = cap * 1.0001 + 1e-6
		for i in range(n):
			var v: float = arr[i]
			if not is_finite(v) or v < -1e-6 or v > hi_tol:
				all_finite_clamped = false
				bad_detail = "%s[%d]=%s (cap=%s)" % [String(p.id), i, str(v), str(cap)]
				break
		if not all_finite_clamped:
			break
	if not all_finite_clamped:
		printerr("  [detail] %s" % bad_detail)
	_expect("all 12 resources finite & clamped to [0,capacity]", all_finite_clamped)

	# 横跳回归：收敛尾段（最后 5 日）的逐日变化必须远小于 capacity。旧显式 Euler 对
	# 草药(gen+decay_self=10.2)/黏土((2+1)/0.001=3000) 会每日跳 ≈±capacity；半隐式则趋稳。
	var herbs_tail: float = _tail_max_step(herbs_seq, 5)
	var clay_tail: float = _tail_max_step(clay_seq, 5)
	print("  tail max |Δ/day| (last 5d): wild_herbs=%.5f (cap=%.5f), clay=%.6f (cap=%.6f)" % [
		herbs_tail, herbs_cap, clay_tail, clay_cap])
	if herbs_seq.size() >= 6 and herbs_cap > 0.0:
		_expect("wild_herbs settled, no 0↔cap 横跳 (tail Δ < 5%% cap)", herbs_tail < 0.05 * herbs_cap)
	if clay_seq.size() >= 6 and clay_cap > 0.0:
		_expect("clay settled, no 0↔cap 横跳 (tail Δ < 5%% cap)", clay_tail < 0.05 * clay_cap)
	_finish()


# 资源 id → MapData reserve 字段名 / capacity。
func _field_for(id_name: String) -> String:
	for p in ResourceProfileRegistry.ordered():
		if String(p.id) == id_name:
			return ResourceProfileRegistry.reserve_map_field(p)
	return ""


func _cap_for(id_name: String) -> float:
	for p in ResourceProfileRegistry.ordered():
		if String(p.id) == id_name:
			return float(p.capacity)
	return 0.0


# 序列尾段（最后 window 个值）相邻日的最大绝对变化，用于检测收敛 / 横跳。
func _tail_max_step(seq: PackedFloat32Array, window: int) -> float:
	var m: float = 0.0
	var start: int = maxi(1, seq.size() - window)
	for i in range(start, seq.size()):
		m = maxf(m, absf(seq[i] - seq[i - 1]))
	return m


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
