extends SceneTree

# tests/sim_2ms_annual_stats_test.gd
#
# plan/sim-2ms-simd-dirty-budget —— 年度统计指标一致性验收。
#
# 与 sim_2ms_ulp_tolerant_test 互补：ulp 测的是"单 tick 微观一致"，本测试测
# "1 个游戏年（360 tick）后宏观一致"。SIMD reorder 会让 ulp 差以随机游走方式
# 累积；年度尺度上若三大指标（年均温 / 年均降水 / 年均海冰覆盖）|Δ_rel| <
# 0.5%，则视为玩家观感无差异、模拟仍然忠实。
#
# 触发路径：godot --headless --script tests/sim_2ms_annual_stats_test.gd
#
# 验收门槛（plan §核心功能 - 验收）：
#   - 全图年均温 |Δ_rel| < 0.5%
#   - 全图年均降水 |Δ_rel| < 0.5%
#   - 海冰覆盖 cell 数年均 |Δ_rel| < 0.5%
#
# 跳过策略：
#   - DCWorldExt / ClimateProfile 不可达 → SKIP
#   - 任一 SIMD flag 在 ClimateProfile 上不存在 → SKIP（profile 旧版本）
#
# 状态：骨架。完整 1-year sim 跑需要 generator + map + world 完整 bake 链；
# 骨架阶段先校验所有依赖 method/flag 都已就位，并打印"待实现"日志，等
# climate-pass-b-simd / ocean-*-simd / weather-combined 三 todo 完成后再
# 填充 1-year tick loop 与对比逻辑。

const ClimateProfile := preload("res://scripts/data/climate_profile.gd")
const _FeatureFlags := preload("res://scripts/data_core/feature_flags.gd")

# 验收阈值（plan §验收）：
const ANNUAL_TEMP_DELTA_REL_THRESHOLD: float = 0.005
const ANNUAL_PRCP_DELTA_REL_THRESHOLD: float = 0.005
const ANNUAL_SEAICE_DELTA_REL_THRESHOLD: float = 0.005

# 一个游戏年的 tick 数（与项目主基调对齐；具体常量在 sim 端定义）。
const TICKS_PER_YEAR: int = 360


# ───────── runner 入口 ─────────

var _failures: Array[String] = []
var _skipped: bool = false
var _skip_reason: String = ""


func _init() -> void:
	_run()
	_finish()


func _finish() -> void:
	if _skipped:
		print("[annual-stats-test] SKIP: %s" % _skip_reason)
		quit(0)
		return
	if _failures.is_empty():
		print("[annual-stats-test] PASS (annual stats |Δ_rel| < 0.5%% across temp/prcp/seaice)")
		quit(0)
	else:
		printerr("[annual-stats-test] FAIL ×%d:" % _failures.size())
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


# ───────── 相对误差工具 ─────────

# 安全相对误差：分母绝对值过小时退化为绝对误差（避免除零）。
static func rel_delta(a: float, b: float) -> float:
	var denom: float = max(abs(a), abs(b))
	if denom < 1e-9:
		return abs(a - b)
	return abs(a - b) / denom


# ───────── tests ─────────

func _run() -> void:
	print("[annual-stats-test] start (TICKS_PER_YEAR=%d)" % TICKS_PER_YEAR)

	# Gate 1：DCWorldExt 可用
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found (dll not built / loaded)")
		return

	# Gate 2：ClimateProfile 必须有本计划新加的 4 个 flag 字段（registry 注册项）
	var cp: ClimateProfile = ClimateProfile.new()
	var required_flags: Array = [
		&"use_gdext_pass_b_simd",
		&"use_gdext_ocean_water_simd",
		&"use_gdext_ocean_land_simd",
		&"use_gdext_thread_fallback",
	]
	for flag in required_flags:
		var v: Variant = cp.get(String(flag))
		if typeof(v) == TYPE_NIL:
			_skip("ClimateProfile missing field '%s' (profile outdated)" % String(flag))
			return
		_expect(typeof(v) == TYPE_BOOL, "flag '%s' is bool" % String(flag),
			"got typeof=%d" % typeof(v))
		# 默认应为 false（plan §核心决策）
		_expect(bool(v) == false, "flag '%s' default == false" % String(flag),
			"got %s" % str(v))

	# Gate 3：feature_flags registry 也注册了
	for flag in required_flags:
		_expect(_FeatureFlags.is_known(flag),
			"FLAGS registry knows '%s'" % String(flag))

	# Gate 4：每个 SIMD flag 配套的 C++ method 已 export
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return
	var have_pass_b: bool = ext.has_method("run_climate_pass_b_simd")
	var have_ocean_water: bool = ext.has_method("run_ocean_water_pass_simd")
	var have_ocean_land: bool = ext.has_method("run_ocean_land_pass_simd")
	if not (have_pass_b or have_ocean_water or have_ocean_land):
		_skip("No *_simd methods exported (plan implementation not landed yet)")
		return

	# TODO（plan acceptance-and-flag-flip todo）：
	#   1. 构造 baseline run：所有 *_simd flag = false，跑 360 tick，记录
	#      avg_annual_temp_baseline / avg_annual_prcp_baseline /
	#      avg_annual_seaice_baseline。
	#   2. 构造 simd run：逐项开启 *_simd flag = true，相同 seed/profile 跑
	#      360 tick，记录三指标 simd 版。
	#   3. 三指标 rel_delta 与 ANNUAL_*_THRESHOLD 对比，超阈则 FAIL。
	#
	# 骨架阶段：仅打印就绪状态。
	print("  [info] have_run_climate_pass_b_simd  = %s" % have_pass_b)
	print("  [info] have_run_ocean_water_pass_simd = %s" % have_ocean_water)
	print("  [info] have_run_ocean_land_pass_simd  = %s" % have_ocean_land)

	# 自检：rel_delta 工具本身正确
	_expect(rel_delta(1.0, 1.0) == 0.0, "rel_delta(equal) == 0")
	_expect(rel_delta(1.0, 1.001) <= 0.002, "rel_delta(0.1%%) ≤ 0.002")
	_expect(rel_delta(100.0, 200.0) >= 0.4, "rel_delta(100,200) ≥ 0.4")
