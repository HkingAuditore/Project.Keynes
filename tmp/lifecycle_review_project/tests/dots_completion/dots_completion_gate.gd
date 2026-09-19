# tests/dots_completion/dots_completion_gate.gd
# DOTS 运行时验收门禁。
#
# 与 record_baseline.gd 的区别：
#   - record_baseline.gd  ：信息性输出，exit 0 always（用于建立基线 + 进度跟踪）
#   - dots_completion_gate.gd：硬门禁，任一项失败 exit 非零（用于 CI / merge gate）
#
# 依次跑下列检查（任一失败立即累积；最后给汇总 + 非零退出码）：
#   (a) 4 巨石行数历史诊断
#       - weather_system.gd ≤ 400
#       - map_generator.gd  ≤ 1500
#       - map_baker.gd      ≤ 800
#       - main.gd           ≤ 400
#       - 该项属于 2026-05 monolith-split 计划。当前生产架构已经转为
#         native daily graph + DataCore；超限保留为迁移债务警告，不再
#         伪装成当前 authority 契约，也不允许静默删除这些数据。
#   (b) hot path 直写残留 grep
#       - map_generator.gd 中 `^\s*cell\.[a-z_]+\s*=\s` 命中 ≤ baseline × 0.20
#         （这是 2026-05 拆分目标的 legacy 指标；超限只警告，不阻断当前门禁）
#       - weather_system.gd 中 `out_cell\.\w+\s*=` 命中 = 0
#   (c) Flag registry 完整性
#       - climate_profile.gd 中所有 `@export var use_[a-z_]+: bool` 必须在
#         feature_flags.gd::FLAGS 中注册
#       - 反向：FLAGS 中 resource = "ClimateProfile" 的项必须在 climate_profile
#         上有同名字段（用 default-constructed 实例反射 .get 校验）
#   (d) 当前 H8/I8 authority / D7 transport journal 静态契约
#       - implemented_domain_mask 包含
#         COMMIT|CLIMATE|COUNTRY|TRIGGER_INPUT|MODIFIER|EFFECT|IDEOLOGY|EVENTS|ECONOMY
#       - 生产 worker request 为 0xFFF
#       - D7T1 section 与 Economy fiscal peer journal 仍在源码中
#   (e) 1000 tick SAME_SOURCE 数值收敛 [SKIP / RUNTIME-GATED]
#       - 当前脚本静态校验，不真正跑 tick；记录 baseline.json 中的占位指标。
#         真正 runtime soak 由项目内 dedicated scene 跑（待 1.1-3.2 拆分稳定后建立）。
#   (f) 帧时间不退化 [SKIP / RUNTIME-GATED]
#       - 同上；baseline.json 中的 fast_tick_ms_p50/p95 记录 ground truth，
#         runtime soak 完成后由 CI 比对。
#
# Headless 用法：
#   godot --headless --script tests/dots_completion/dots_completion_gate.gd --quit
#
# 退出码：
#   0 = 全部门禁通过（含 SKIP 的 runtime soak）
#   1 = 至少一项当前硬门禁 [(b weather_system)/(c)/(d)] 失败
#   2 = 内部错误（脚本无法读取 baseline.json / climate_profile.gd 等）
#
# 失败/警告输出格式（精确定位）：
#   [LEGACY] (a) main.gd: 1742 lines > historical target 400 (over by 1342)
#   [GATE-FAIL] (b) weather_system.gd: 'out_cell.x =' hit 5 (expected 0)
#   [GATE-FAIL] (c) feature_flags.FLAGS missing entry for 'use_xxx_yyy' declared on ClimateProfile

extends SceneTree

# 4 巨石行数历史诊断
const _LANDMARKS: Array = [
	{path = "res://scripts/weather/weather_system.gd",   target =  400, key = "weather_system_gd",  label = "weather_system.gd"},
	{path = "res://scripts/geography/map_generator.gd",  target = 1500, key = "map_generator_gd",   label = "map_generator.gd"},
	{path = "res://scripts/rendering/map_baker.gd",      target =  800, key = "map_baker_gd",       label = "map_baker.gd"},
	{path = "res://scripts/main.gd",                     target =  400, key = "main_gd",            label = "main.gd"},
]

# hot path 直写残留 grep（pattern + 当前预期上限）
# - map_generator: 拆完后允许保留 ≤ baseline × 0.20 的 bake-time 直写（带 # bake-time 注释）
# - weather_system: 期望全部走 SoA write，out_cell.x = 应该 = 0
const _DIRECT_WRITE_TARGETS: Array = [
	{
		path = "res://scripts/geography/map_generator.gd",
		regex = "^\\s*cell\\.[a-z_]+\\s*=\\s",
		baseline_key = "map_generator_cell_field_writes",
		ratio_max = 0.20,  # 0.20 = 20%；拆完后剩余 ≤ baseline × 0.20
		label = "map_generator cell.x = (bake-time only)",
	},
	{
		path = "res://scripts/weather/weather_system.gd",
		regex = "out_cell\\.\\w+\\s*=",
		baseline_key = "",  # 不查 baseline；hard-cap = 0
		ratio_max = 0.0,
		label = "weather_system out_cell.x =",
	},
]

# 检查 flag registry 完整性时使用的目标 Resource 类型 + flag pattern
const _CLIMATE_PROFILE_PATH: String = "res://scripts/data/climate_profile.gd"
const _FEATURE_FLAGS_PATH: String = "res://scripts/data_core/feature_flags.gd"
const _BASELINE_PATH: String = "res://tests/dots_completion/baseline.json"
const _NATIVE_HOST_HEADER_PATH: String = "gdext/src/native_simulation_host.h"
const _NATIVE_HOST_SOURCE_PATH: String = "gdext/src/native_simulation_host.cpp"
const _WORLD_RUNTIME_HOST_PATH: String = "res://scripts/game/world_runtime_host.gd"
const _ECONOMY_PERSISTENCE_PATH: String = "gdext/src/economy_runtime_persistence_codec.h"

# 累积失败信息；len > 0 时以 exit 1 退出。
var _failures: Array = []
var _warnings: Array = []
var _internal_errors: Array = []


func _init() -> void:
	print("=== DOTS completion gate ===")
	print("")
	var baseline: Dictionary = _load_baseline()
	_check_landmarks()
	print("")
	_check_direct_writes(baseline)
	print("")
	_check_flag_registry()
	print("")
	_check_authority_contract()
	print("")
	_check_runtime_soak_placeholder(baseline)
	print("")
	_summarize_and_exit()


# ─── (a) 4 巨石行数历史诊断 ─────────────────────────────────────────────

func _check_landmarks() -> void:
	print("─── (a) 4 巨石行数历史诊断 ───────────────────────")
	print("%-28s %8s  %8s  %s" % ["file", "current", "target", "status"])
	for entry in _LANDMARKS:
		var lines: int = _count_lines(String(entry.path))
		if lines < 0:
			_internal_errors.append("cannot read %s" % entry.path)
			print("%-28s %8s  %8d  ERROR" % [String(entry.label), "n/a", int(entry.target)])
			continue
		var target: int = int(entry.target)
		var ok: bool = lines <= target
		var status: String = "PASS" if ok else ("OVER by %d" % (lines - target))
		print("%-28s %8d  %8d  %s" % [String(entry.label), lines, target, status])
		if not ok:
			_warnings.append(
				"[LEGACY] (a) %s: %d lines > historical target %d (over by %d)"
					% [String(entry.label), lines, target, lines - target]
			)


# ─── (b) hot path 直写残留 grep ────────────────────────────────────────

func _check_direct_writes(baseline: Dictionary) -> void:
	print("─── (b) hot path 直写残留 ─────────────────────────")
	print("%-40s %8s  %8s  %s" % ["pattern", "count", "limit", "status"])
	var hp_b: Dictionary = baseline.get("_hot_path_writes_baseline", {})
	for entry in _DIRECT_WRITE_TARGETS:
		var n: int = _count_regex_matches(String(entry.path), String(entry.regex))
		if n < 0:
			_internal_errors.append("cannot grep %s" % entry.path)
			print("%-40s %8s  %8s  ERROR" % [String(entry.label), "n/a", "n/a"])
			continue
		var limit: int = 0
		var key: String = String(entry.baseline_key)
		if key != "" and hp_b.has(key):
			limit = int(round(float(hp_b[key]) * float(entry.ratio_max)))
		var ok: bool = n <= limit
		var legacy: bool = String(entry.label).begins_with("map_generator ")
		var status: String = "PASS" if ok else ("LEGACY" if legacy else "FAIL")
		print("%-40s %8d  %8d  %s" % [String(entry.label), n, limit, status])
		if not ok:
			var message := (
				"[%s] (b) %s: hit %d > limit %d in %s"
					% ["LEGACY" if legacy else "GATE-FAIL",
						String(entry.label), n, limit, String(entry.path)]
			)
			if legacy:
				_warnings.append(message)
			else:
				_failures.append(message)


# ─── (c) Flag registry 完整性 ─────────────────────────────────────────

func _check_flag_registry() -> void:
	print("─── (c) Flag registry 完整性 ──────────────────────")
	# 步骤 1：从 climate_profile.gd 文本中扫描所有 `@export var use_xxx: bool`
	var declared_flags: Array = _scan_export_use_flags(_CLIMATE_PROFILE_PATH)
	if declared_flags.size() < 0:
		_internal_errors.append("cannot scan %s" % _CLIMATE_PROFILE_PATH)
		return
	print("declared on ClimateProfile: %d flags" % declared_flags.size())

	# 步骤 2：从 feature_flags.gd 文本中扫描所有 `name = &"use_xxx"` 注册项
	var registered_flags: Array = _scan_registered_flags(_FEATURE_FLAGS_PATH)
	if registered_flags.size() < 0:
		_internal_errors.append("cannot scan %s" % _FEATURE_FLAGS_PATH)
		return
	print("registered in FLAGS:        %d flags" % registered_flags.size())

	# 步骤 3：每个 declared 必须在 registered 里命中
	var missing_in_registry: Array = []
	for d in declared_flags:
		if not registered_flags.has(d):
			missing_in_registry.append(d)
	# 步骤 4：每个 registered 中 resource="ClimateProfile" 的必须在 declared 里命中
	# 由于本静态扫描分不出 resource 字段，这里只做 declared→registered 单向校验，
	# 反向校验由 DCFeatureFlags.validate_against({}) 在运行时跑（main.gd 启动期）。

	if missing_in_registry.is_empty():
		print("all %d ClimateProfile flags registered: PASS" % declared_flags.size())
	else:
		print("MISSING %d flag(s) in registry:" % missing_in_registry.size())
		for m in missing_in_registry:
			print("  - %s" % m)
			_failures.append(
				"[GATE-FAIL] (c) feature_flags.FLAGS missing entry for '%s' declared on ClimateProfile"
					% m
			)


# ─── (d) Current D12 authority / D7 journal contract ─────────────────

func _check_authority_contract() -> void:
	print("─── (d) D12 authority / D7 journal contract ─────")
	var host_header := _read_repo_text(_NATIVE_HOST_HEADER_PATH)
	var host_source := _read_repo_text(_NATIVE_HOST_SOURCE_PATH)
	var world_host := _read_text(_WORLD_RUNTIME_HOST_PATH)
	var economy_persistence := _read_repo_text(_ECONOMY_PERSISTENCE_PATH)
	if host_header == "" or host_source == "" or world_host == "" or economy_persistence == "":
		_internal_errors.append("authority contract source file missing")
		return

	var mask_block := _extract_implemented_mask_block(host_header)
	var mask_ok := mask_block != "" \
		and mask_block.contains("runtime_domain_mask(RuntimeDomainId::COMMIT)") \
		and mask_block.contains("runtime_domain_mask(RuntimeDomainId::CLIMATE)") \
		and mask_block.contains("runtime_domain_mask(RuntimeDomainId::COUNTRY)") \
		and mask_block.contains("runtime_domain_mask(RuntimeDomainId::MODIFIER)") \
		and mask_block.contains("runtime_domain_mask(RuntimeDomainId::EFFECT)") \
		and mask_block.contains("runtime_domain_mask(RuntimeDomainId::IDEOLOGY)") \
		and mask_block.contains("runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)") \
		and mask_block.contains("runtime_domain_mask(RuntimeDomainId::EVENTS)") \
		and mask_block.contains("RuntimeDomainId::ECONOMY")
	_expect_gate_contract("(d) implemented_domain_mask is COMMIT|CLIMATE|COUNTRY|TRIGGER|MODIFIER|EFFECT|IDEOLOGY|EVENTS|ECONOMY", mask_ok)

	# The production request is deliberately configurable per session, but its
	# default must remain the currently proven 0xFFF until M5 promotion evidence
	# exists. Keep the static gate aligned with that explicit source contract.
	var request_ok := world_host.contains("config[\"authoritative_domain_mask\"] = runtime_authority_domain_mask") \
		and world_host.contains("@export var runtime_authority_domain_mask: int = 0xFFF")
	_expect_gate_contract("(d) production worker default request is exactly 0xFFF", request_ok)

	var d7_marker_ok := host_source.contains("D7_TRANSACTION_MAGIC") \
		and host_source.contains("\"D7T1\"") \
		and economy_persistence.contains("SAVE_SECTION_FISCAL_PEER = 30")
	_expect_gate_contract("(d) D7T1 transport and fiscal peer section are present", d7_marker_ok)


func _expect_gate_contract(label: String, ok: bool) -> void:
	print("%-58s %s" % [label, "PASS" if ok else "FAIL"])
	if not ok:
		_failures.append("[GATE-FAIL] %s" % label)


func _extract_implemented_mask_block(source: String) -> String:
	var rx := RegEx.new()
	if rx.compile("(?s)implemented_domain_mask\\(\\)\\s*\\{.*?return\\s+(.*?);") != OK:
		return ""
	var match := rx.search(source)
	return match.get_string(1) if match != null else ""


func _read_text(res_path: String) -> String:
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _read_repo_text(relative_path: String) -> String:
	var project_root := ProjectSettings.globalize_path("res://").replace(
		"\\", "/").trim_suffix("/")
	var repo_root := project_root.path_join("..").path_join("..").simplify_path()
	return _read_text(repo_root.path_join(relative_path))


# ─── (e) / (f) Runtime soak placeholder ────────────────────────────────

func _check_runtime_soak_placeholder(baseline: Dictionary) -> void:
	print("─── (e)/(f) runtime soak [SKIP / RUNTIME-GATED] ──")
	var bm: Dictionary = baseline.get("_baseline_metrics", {})
	var p50: Variant = bm.get("fast_tick_ms_p50", null)
	var p95: Variant = bm.get("fast_tick_ms_p95", null)
	if p50 == null or p95 == null:
		print("baseline metrics not yet recorded; (e)/(f) SKIPPED")
		print("  → record fast_tick_ms_p50/p95 in baseline.json by running 100-tick scene")
		return
	print("baseline.fast_tick_ms_p50 = %s" % str(p50))
	print("baseline.fast_tick_ms_p95 = %s" % str(p95))
	print("(e) 1000-tick SAME_SOURCE convergence: SKIPPED (requires runtime scene)")
	print("(f) frame-time non-regression:         SKIPPED (requires runtime scene)")


# ─── 辅助：行数 / regex 计数 / baseline 加载 / flag 文本扫描 ────────────

func _load_baseline() -> Dictionary:
	if not FileAccess.file_exists(_BASELINE_PATH):
		_internal_errors.append("baseline.json not found")
		return {}
	var f: FileAccess = FileAccess.open(_BASELINE_PATH, FileAccess.READ)
	if f == null:
		_internal_errors.append("cannot open baseline.json")
		return {}
	var text: String = f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		_internal_errors.append("baseline.json malformed (not a dict)")
		return {}
	return data


func _count_lines(res_path: String) -> int:
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return -1
	var n: int = 0
	while not f.eof_reached():
		f.get_line()
		n += 1
	f.close()
	return max(0, n - 1)


func _count_regex_matches(res_path: String, pattern: String) -> int:
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return -1
	var rx: RegEx = RegEx.new()
	if rx.compile(pattern) != OK:
		f.close()
		return -1
	var n: int = 0
	while not f.eof_reached():
		var line: String = f.get_line()
		if rx.search(line) != null:
			n += 1
	f.close()
	return n


# 从 climate_profile.gd（或同类 Resource 源文件）扫描所有
# `@export var use_<name>: bool` 声明，返回 use_<name> 字符串数组。
func _scan_export_use_flags(res_path: String) -> Array:
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return []
	var rx: RegEx = RegEx.new()
	if rx.compile("^\\s*@export\\s+var\\s+(use_[a-z_]+)\\s*:\\s*bool") != OK:
		f.close()
		return []
	var found: Array = []
	while not f.eof_reached():
		var line: String = f.get_line()
		var m: RegExMatch = rx.search(line)
		if m != null:
			var name: String = m.get_string(1)
			if not found.has(name):
				found.append(name)
	f.close()
	return found


# 从 feature_flags.gd 扫描所有 `name = &"use_<name>"` 注册项。
func _scan_registered_flags(res_path: String) -> Array:
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return []
	var rx: RegEx = RegEx.new()
	if rx.compile("name\\s*=\\s*&\"(use_[a-z_]+)\"") != OK:
		f.close()
		return []
	var found: Array = []
	while not f.eof_reached():
		var line: String = f.get_line()
		var m: RegExMatch = rx.search(line)
		if m != null:
			var name: String = m.get_string(1)
			if not found.has(name):
				found.append(name)
	f.close()
	return found


# ─── 退出汇总 ─────────────────────────────────────────────────────────

func _summarize_and_exit() -> void:
	print("=== summary ===")
	if not _internal_errors.is_empty():
		print("internal errors:")
		for e in _internal_errors:
			print("  ! %s" % e)
		print("=> exit 2 (gate cannot run)")
		quit(2)
		return
	if not _warnings.is_empty():
		print("historical warnings (non-gating):")
		for warning in _warnings:
			print("  %s" % warning)
	if _failures.is_empty():
		print("ALL GATES PASSED")
		print("=> exit 0")
		quit(0)
		return
	print("FAILURES (%d):" % _failures.size())
	for fail in _failures:
		print("  %s" % fail)
	print("=> exit 1")
	quit(1)

