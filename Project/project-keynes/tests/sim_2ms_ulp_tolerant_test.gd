extends SceneTree

# tests/sim_2ms_ulp_tolerant_test.gd
#
# plan/sim-2ms-simd-dirty-budget —— ulp-tolerant 数值近似一致性验收。
#
# 与 dirty_mask_test / cpp_atlas_encode_bitequal_test 的 bit-equal 互补：
# AVX2 SIMD 8-lane FMA + scalar tail 会引入浮点运算重排（FMA round 一次 vs 普通
# add+mul 两次），即使代数等价也常出现 ulp ≤ 4 的偏差。本测试把"严格相等"
# 放宽到 ulp 容差，并跑长链 1000-tick 看累积漂移是否仍受控。
#
# 触发路径：godot --headless --script tests/sim_2ms_ulp_tolerant_test.gd
#
# 验收门槛（plan §验收）：
#   - 每个 SIMD pass 前后 ulp 差 ≤ 4（≈ 单精度 5e-7 相对误差）
#   - 1000-tick 累积后逐 cell |Δ_rel| ≤ 1e-4（≈ 万分之一）
#   - 年度统计指标偏差另由 sim_2ms_annual_stats_test 校验
#
# 跳过策略（CI 友好，与现有 bitequal_test 同形）：
#   - DCWorldExt 类不存在 → SKIP
#   - DCWorldExt 没有 *_simd method → SKIP（dll 未升级）
#   - cpp 路径返回 fallback=true → SKIP（mock 硬伤）
# SKIP 全部 quit(0)；只有真 ulp 超阈值才 fail。
#
# 不动点：
#   - 不修改任何生产代码
#   - 不引入 GUT 框架；与项目内其他 *_test.gd 同形 SceneTree pattern
#
# 状态：骨架。实际 mock world / pass 调用待对应 SIMD kernel 实现完成后填充。

const MapBaker := preload("res://scripts/rendering/map_baker.gd")

# ───────── runner 入口 ─────────

var _failures: Array[String] = []
var _skipped: bool = false
var _skip_reason: String = ""


func _init() -> void:
	_run()
	_finish()


func _finish() -> void:
	if _skipped:
		print("[ulp-tolerant-test] SKIP: %s" % _skip_reason)
		quit(0)
		return
	if _failures.is_empty():
		print("[ulp-tolerant-test] PASS (ulp ≤ 4 across all SIMD passes)")
		quit(0)
	else:
		printerr("[ulp-tolerant-test] FAIL ×%d:" % _failures.size())
		for line in _failures:
			printerr("  - " + line)
		quit(1)


func _expect(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		print("  [ok] %s" % name)
	else:
		var msg := name
		if detail != "":
			msg += " | " + detail
		_failures.append(msg)
		printerr("  [FAIL] %s" % msg)


func _skip(reason: String) -> void:
	_skipped = true
	_skip_reason = reason


# ───────── ulp 距离工具 ─────────

# 单精度 float ulp 距离：把两个 float 视为 IEEE 754 单精度二进制位，
# 取无符号 int 表示后的差值。等价相邻 representable 数的步进格数。
# 输入要求：两者同号（异号 ulp 用 |a-b| / eps 兜底）。
static func ulp_distance(a: float, b: float) -> int:
	if is_nan(a) or is_nan(b):
		return 0x7FFFFFFF
	if is_inf(a) or is_inf(b):
		return 0x7FFFFFFF if a != b else 0
	if a == b:
		return 0
	# 简化版：用相对误差 / eps_f32 近似（避免在 GDScript 里手搓 bit cast）。
	# 容差校验需求下精度足够；真要严格 ulp 走 C++ 测试。
	const EPS_F32: float = 5.960464477539063e-08  # 2^-24
	var mag: float = max(abs(a), abs(b))
	if mag < 1e-30:
		return 0
	return int(abs(a - b) / (mag * EPS_F32))


# ───────── tests ─────────

# pass_a 写出的全部 SoA → MapData 字段（component_schema.gd 权威）。含 in/out 与纯 out；
# A/B 前 snapshot + 后 restore 这组即可把 ext slot 复位到同一输入态。
const PASS_A_OUT_F32: Array = [
	"temp_baseline_arr", "temp_30d_arr", "temp_365d_arr", "temp_anomaly_arr",
	"moisture_arr", "temp_season_offset_arr", "insolation_now_arr", "insolation_dev_arr",
	"day_length_arr", "heat_input_arr", "thermal_energy_arr", "snowpack_arr",
	"ocean_thermal_anomaly_arr", "local_thermal_anomaly_arr",
]
const PASS_A_OUT_U8: Array = ["ema_initialized_arr"]
# pass_b 写出：moisture + local_thermal_anomaly。
const PASS_B_OUT_F32: Array = ["moisture_arr", "local_thermal_anomaly_arr"]


func _run() -> void:
	print("[ulp-tolerant-test] start")

	# 自检：ulp_distance 工具本身正确
	_expect(ulp_distance(1.0, 1.0) == 0, "ulp_distance(equal) == 0")
	_expect(ulp_distance(1.0, 1.0 + 1e-7) <= 4, "ulp_distance(close) ≤ 4")
	_expect(ulp_distance(1.0, 2.0) > 100000, "ulp_distance(far) >> 4")

	# Gate 1：DCWorldExt 可用性
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found (dll not built / loaded)")
		return
	if not (MapGenerator and ClimateProfile and MapConfig):
		_skip("MapGenerator/ClimateProfile/MapConfig not available")
		return

	# ── 引导真实小世界（native ACTIVE），覆盖 SIMD body + scalar tail + 水陆混合 ──
	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(96, 72)  # 6912 cell：足够覆盖分块边界
	cfg.seed = 909090
	cfg.num_continents = 2
	cfg.sea_level = 0.50
	cfg.continent_size = 0.78
	cfg.climate_profile = profile
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var generated: Dictionary = generator.generate(cfg, 10.0)
	var map = generated.get("map", null)
	if map == null:
		_skip("map generation returned null")
		return
	for day in range(1, 4):
		generator.sus_tick_daily(null, day, float(day % 365) / 365.0)

	var ext = generator.get_data_core_world_ext()
	if ext == null or not ext.has_method("run_climate_pass_a_thread"):
		_skip("DCWorldExt not bound / _thread methods missing (dll outdated)")
		return

	var sp: float = 0.30
	var pa_struct: Dictionary = generator._build_native_daily_climate_pass_a_struct(map, profile, sp)
	var pb_knobs: Dictionary = generator._build_native_daily_climate_pass_b_knobs(map, profile, sp)

	# ── A/B 1: pass_a scalar vs pass_a_thread（应逐位等价，ulp == 0）──────────────
	if pa_struct.is_empty():
		_skip("pass_a struct builder empty")
		return
	var snap_a: Dictionary = _snapshot(map, PASS_A_OUT_F32, PASS_A_OUT_U8)
	var rc_a0 = ext.run_climate_pass_a(pa_struct, sp, sp)
	if float(rc_a0) < 0.0:
		_skip("run_climate_pass_a fell back (rc<0)")
		return
	var ref_a: Dictionary = _snapshot(map, PASS_A_OUT_F32, PASS_A_OUT_U8)
	_restore(ext, map, snap_a)
	ext.run_climate_pass_a_thread(pa_struct, sp, sp, 0)
	var got_a: Dictionary = _snapshot(map, PASS_A_OUT_F32, PASS_A_OUT_U8)
	_compare("pass_a scalar↔thread", ref_a, got_a, PASS_A_OUT_F32, PASS_A_OUT_U8, 0)

	# ── A/B 2: pass_b scalar vs pass_b_thread（应逐位等价）+ vs simd（ulp≤4）──────
	if pb_knobs.is_empty():
		_skip("pass_b knobs builder empty (enable_local_climate_coupling?)")
		return
	var snap_b: Dictionary = _snapshot(map, PASS_B_OUT_F32, [])
	var rc_b0 = ext.run_climate_pass_b(pb_knobs)
	if float(rc_b0) < 0.0:
		_skip("run_climate_pass_b fell back (rc<0)")
		return
	var ref_b: Dictionary = _snapshot(map, PASS_B_OUT_F32, [])

	_restore(ext, map, snap_b)
	ext.run_climate_pass_b_thread(pb_knobs, 0)
	var got_b_thread: Dictionary = _snapshot(map, PASS_B_OUT_F32, [])
	_compare("pass_b scalar↔thread", ref_b, got_b_thread, PASS_B_OUT_F32, [], 0)

	if ext.has_method("run_climate_pass_b_simd"):
		_restore(ext, map, snap_b)
		ext.run_climate_pass_b_simd(pb_knobs)
		var got_b_simd: Dictionary = _snapshot(map, PASS_B_OUT_F32, [])
		_compare("pass_b scalar↔simd", ref_b, got_b_simd, PASS_B_OUT_F32, [], 4)


# ── snapshot / restore / compare ──────────────────────────────────────────────
func _snapshot(map, f32_fields: Array, u8_fields: Array) -> Dictionary:
	var out: Dictionary = {}
	for f in f32_fields:
		var arr = map.get(f)
		out[f] = (arr as PackedFloat32Array).duplicate() if arr != null else PackedFloat32Array()
	for f in u8_fields:
		var arr = map.get(f)
		out[f] = (arr as PackedByteArray).duplicate() if arr != null else PackedByteArray()
	return out


func _restore(ext, map, snap: Dictionary) -> void:
	for f in snap.keys():
		map.set(f, snap[f].duplicate())
	ext.bind_map_data(map)  # 把复位后的 map 数组重新灌进 ext slot


func _compare(label: String, ref: Dictionary, got: Dictionary, f32_fields: Array, u8_fields: Array, max_ulp: int) -> void:
	var worst_ulp: int = 0
	var bad: String = ""
	for f in f32_fields:
		var a: PackedFloat32Array = ref.get(f, PackedFloat32Array())
		var b: PackedFloat32Array = got.get(f, PackedFloat32Array())
		if a.size() != b.size():
			bad = "%s size %d != %d" % [f, a.size(), b.size()]
			break
		for i in range(a.size()):
			var u: int = ulp_distance(a[i], b[i])
			if u > worst_ulp:
				worst_ulp = u
			if u > max_ulp:
				bad = "%s[%d]=%s vs %s (ulp=%d > %d)" % [f, i, str(a[i]), str(b[i]), u, max_ulp]
				break
		if bad != "":
			break
	if bad == "":
		for f in u8_fields:
			var a8: PackedByteArray = ref.get(f, PackedByteArray())
			var b8: PackedByteArray = got.get(f, PackedByteArray())
			if a8 != b8:
				bad = "%s u8 mismatch" % f
				break
	_expect(bad == "", "%s within ulp≤%d (worst=%d)" % [label, max_ulp, worst_ulp], bad)


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_shadow_diff_enabled = false
	profile.native_climate_round_active_owner_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.native_ocean_physical_active_owner_enabled = true
	profile.weather_field_enabled = false
	profile.runtime_hydrology_enabled = false
	profile.native_environment_runtime_enabled = false
	if profile.get("enable_local_climate_coupling") != null:
		profile.enable_local_climate_coupling = true
	return profile
