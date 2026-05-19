# baker_atlas_section_verdict_test.gd
# plan: dirty-push-atlas-encode 阶段 G 验收
#
# 单测 DCDotsFinalPushPerfVerdict.evaluate_baker_atlas_section 的 4 档对照逻辑：
#   1. legacy 缺失 → overall=false + 明确 fail_reason
#   2. mask_gd 减半达标 → overall=true
#   3. mask_gd 没减半 → fail_reason 命中"does not meet target"
#   4. mask_gd 反而比 legacy 慢 10% 以上 → fail_reason 命中 "regresses"
#   5. mask_cpp 在 mask_gd 基础上再减半 → 完整 4 档全 pass
#   6. format_baker_atlas_section_lines 输出非空且包含 status 行
#
# Headless execution:
#     godot --headless --script tests/baker_atlas_section_verdict_test.gd --quit

extends SceneTree

const VerdictScript = preload("res://scripts/data_core/dots_final_push_perf_verdict.gd")

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _expect(cond: bool, name: String) -> void:
	_checks += 1
	if cond:
		print("  [PASS] %s" % name)
	else:
		print("  [FAIL] %s" % name)
		_failures += 1


func _run() -> void:
	print("=== baker_atlas_section_verdict test (plan: dirty-push-atlas-encode/G) ===")
	_test_legacy_missing()
	_test_mask_gd_target_pass()
	_test_mask_gd_target_fail()
	_test_mask_gd_regression()
	_test_full_4_tier_pass()
	_test_format_lines()
	print("=== baker_atlas_section_verdict test summary: %d checks, %d failures ===" % [_checks, _failures])


# ─── 1. legacy missing ─────────────────────────────────────────────────
func _test_legacy_missing() -> void:
	var v: Dictionary = VerdictScript.evaluate_baker_atlas_section({
		"mask_gd": [1.0, 1.5, 2.0],
	})
	_expect(not bool(v.overall), "missing legacy → overall=false")
	var reasons: Array = v.fail_reasons
	_expect(reasons.size() >= 1 and "legacy" in String(reasons[0]).to_lower(),
		"missing legacy → fail_reason mentions 'legacy'")


# ─── 2. mask_gd 减半达标 ────────────────────────────────────────────
func _test_mask_gd_target_pass() -> void:
	# legacy p95 ~5ms, mask_gd p95 ~2ms → 0.4 倍 < 0.5 target → PASS
	var legacy: Array = []
	for i in range(100):
		legacy.append(4.5 + float(i) * 0.01)  # p95 ~5.4
	var mask_gd: Array = []
	for i in range(100):
		mask_gd.append(1.5 + float(i) * 0.005)  # p95 ~2.0
	var v: Dictionary = VerdictScript.evaluate_baker_atlas_section({
		"legacy": legacy,
		"mask_gd": mask_gd,
	})
	_expect(bool(v.overall), "mask_gd reaches target → overall=true")
	var reductions: Dictionary = v.reductions
	_expect(reductions.has("mask_gd") and float(reductions["mask_gd"]) < 0.5,
		"reduction[mask_gd] < 0.5")


# ─── 3. mask_gd 没减半（停在 70%）→ fail ────────────────────────────
func _test_mask_gd_target_fail() -> void:
	var legacy: Array = []
	for i in range(100):
		legacy.append(5.0 + float(i) * 0.01)
	var mask_gd: Array = []
	for i in range(100):
		mask_gd.append(3.5 + float(i) * 0.005)  # 70% of legacy → fail target
	var v: Dictionary = VerdictScript.evaluate_baker_atlas_section({
		"legacy": legacy,
		"mask_gd": mask_gd,
	})
	_expect(not bool(v.overall), "mask_gd 70% legacy → overall=false")
	var reasons_str: String = ""
	for r in v.fail_reasons:
		reasons_str += String(r) + "|"
	_expect("does not meet target" in reasons_str, "fail_reason mentions 'does not meet target'")


# ─── 4. mask_gd 反而比 legacy 慢 → regression fail ─────────────────────
func _test_mask_gd_regression() -> void:
	var legacy: Array = []
	for i in range(100):
		legacy.append(2.0 + float(i) * 0.005)
	var mask_gd: Array = []
	for i in range(100):
		mask_gd.append(2.5 + float(i) * 0.005)  # ~125% legacy → regression
	var v: Dictionary = VerdictScript.evaluate_baker_atlas_section({
		"legacy": legacy,
		"mask_gd": mask_gd,
	})
	_expect(not bool(v.overall), "mask_gd regression → overall=false")
	var reasons_str: String = ""
	for r in v.fail_reasons:
		reasons_str += String(r) + "|"
	_expect("regresses" in reasons_str, "fail_reason mentions 'regresses'")


# ─── 5. 完整 4 档全 PASS ────────────────────────────────────────────
func _test_full_4_tier_pass() -> void:
	var legacy: Array = []
	for i in range(100):
		legacy.append(8.0 + float(i) * 0.01)  # p95 ~9.0
	var mask_gd: Array = []
	for i in range(100):
		mask_gd.append(2.5 + float(i) * 0.005)  # p95 ~3.0, ~33% legacy → PASS
	var mask_gd_full: Array = []
	for i in range(100):
		mask_gd_full.append(8.0 + float(i) * 0.005)  # p95 ~8.5, ~94% legacy → PASS（≤ 110% legacy）
	var mask_cpp: Array = []
	for i in range(100):
		mask_cpp.append(0.8 + float(i) * 0.001)  # p95 ~0.9, ~30% mask_gd → PASS
	var v: Dictionary = VerdictScript.evaluate_baker_atlas_section({
		"legacy": legacy,
		"mask_gd": mask_gd,
		"mask_gd_full": mask_gd_full,
		"mask_cpp": mask_cpp,
	})
	if not bool(v.overall):
		# 调试：打出 fail_reasons 帮助定位
		print("    DEBUG fail_reasons: %s" % str(v.fail_reasons))
	_expect(bool(v.overall), "4-tier all targets met → overall=true")
	var by_label: Dictionary = v.by_label
	_expect(by_label.has("legacy") and by_label.has("mask_gd") \
			and by_label.has("mask_gd_full") and by_label.has("mask_cpp"),
		"by_label has 4 entries")


# ─── 6. format_lines 输出非空 ──────────────────────────────────────
func _test_format_lines() -> void:
	var v: Dictionary = VerdictScript.evaluate_baker_atlas_section({
		"legacy": [5.0, 5.1, 5.2],
		"mask_gd": [2.0, 2.1, 2.2],
	})
	var lines: Array = VerdictScript.format_baker_atlas_section_lines(v)
	_expect(lines.size() > 0, "format_lines returns non-empty")
	_expect("baker atlas section verdict" in String(lines[0]),
		"first line contains 'baker atlas section verdict'")
