# template_soak_test.gd — Migration Harness Template (PR-4.3)
#
# 标准化的 SAME_SOURCE A/B soak 验收夹具。复制本文件到 `tests/<your_module>_soak_test.gd`，
# 按 "⚙️ MODULE-CUSTOM" 注释标注的位置改成你模块的 feature_flag / 字段白名单 / 容差。
#
# 验收语义（master 手册 §3.10.4）：
#   • SAME_SOURCE：两段都在同一 backend（dc_on/dc_on 或 dc_off/dc_off）跑 N tick；
#                  比较两段输出（应该 bit-equal 或落在 stochastic_field_threshold 内）。
#   • VS_LEGACY：A=use_dots=false / B=use_dots=true，比较行为漂移（mean_diff）。
#                适合迁移 PR 的回归验收。
#
# 与 DCSoakABRunner 的关系：
#   • 本夹具是 **headless / CI 友好** 包装，自动启动 generator + scheduler，
#     跑 N tick × 2 段，diff 比对，pass/fail 退出码。
#   • DCSoakABRunner 是 **engine-in editor** 工具（F3 触发），主用于人工调试。
#   • 两者底层共用 DCSoakDump dump 格式（TSV/JSONL），可互相读对方产物。
#
# 运行：
#     godot --headless --script tests/<your_module>_soak_test.gd --quit
#
# 退出码：0 = PASS（mean_diff ≤ 阈值）；1 = FAIL（漂移超阈值）
#
# 设计：
#   • 不依赖 SceneTree.process_frame 等真实 frame loop；用 generator.refresh_climate_daily()
#     等显式 step 函数推 N tick。这让本夹具能在 --headless --quit 下确定性跑完，
#     不会因 frame budget 跳片导致每次输出不同。
#   • dump 模式默认 SUMMARY（per-tick × per-field min/max/mean/std）；FULL 模式
#     体积大但能定位到具体 cell × 字段，仅在 SUMMARY 失败时手动开。

extends SceneTree

# ─── ⚙️ MODULE-CUSTOM 1：模块名 + tick 数 ─────────────────────────
const MODULE_NAME: String = "your_module"
const N_TICKS: int = 30
# Stochastic（天气类）字段阈值；非 stochastic 字段（temp_baseline / 长期均值等）
# 用更严格阈值（master 手册 §6.3）。本夹具按字段名前缀分流。
const STOCHASTIC_THRESHOLD: float = 0.30
const SCALAR_THRESHOLD: float = 0.01

# ─── ⚙️ MODULE-CUSTOM 2：要监控的字段 + 各自阈值 ──────────────────
# 每条 { field, threshold } 写入；threshold == NAN → 走默认 SCALAR_THRESHOLD。
const WATCH_FIELDS: Array = [
	# { "field": "cell.temperature", "threshold": NAN },
	# { "field": "cell.weather_intensity", "threshold": NAN },  # stochastic auto
	# { "field": "cell.weather_type", "threshold": NAN },       # stochastic auto
]

# Stochastic 字段名前缀白名单（master 手册 §6.3）。
const STOCHASTIC_PREFIXES: Array = ["cell.weather_", "cell.snow_cover", "cell.sea_ice_frac"]

# ─── ⚙️ MODULE-CUSTOM 3：feature_flag toggle ───────────────────────
# Mode A 与 Mode B 的 ClimateProfile 字段值。SAME_SOURCE：两个都填 false 或都填 true。
# VS_LEGACY：A=false（legacy）/ B=true（dots）。
const FLAG_NAME: String = "use_data_core"
const FLAG_VALUE_A: bool = false
const FLAG_VALUE_B: bool = false  # SAME_SOURCE 默认两边一致

# ─── ⚙️ MODULE-CUSTOM 4：A/B 输出路径模板 ──────────────────────────
const OUTPUT_DIR: String = "user://soak/"

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== %s_soak_test (PR-4.3) — N=%d ===" % [MODULE_NAME, N_TICKS])

	# ─── ⚙️ MODULE-CUSTOM 5：构造测试场景 ────────────────────────
	# 真实模块在这里调用 generator + scheduler。下面是 stub，复制后填实。
	# 例：
	#   var generator: Node = MapGenerator.new()
	#   root.add_child(generator)
#   await generator.generate(seed=12345)  # 等待生成完成
	#   var cp: ClimateProfile = generator._c()
	#   var scheduler = generator._sus

	var ts: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path_a: String = "%s%s_A_%s.tsv" % [OUTPUT_DIR, MODULE_NAME, ts]
	var path_b: String = "%s%s_B_%s.tsv" % [OUTPUT_DIR, MODULE_NAME, ts]

	# Phase A：FLAG_VALUE_A
	# ⚙️ MODULE-CUSTOM 6：cp.set(FLAG_NAME, FLAG_VALUE_A); rebake/reset；
	#                      DCSoakDump.instance.start(N_TICKS, SUMMARY, path_a, generator);
	#                      for _ in range(N_TICKS): scheduler.tick()
	print("  Phase A: %s = %s → %s" % [FLAG_NAME, str(FLAG_VALUE_A), path_a])
	# (stub) 略过实际跑

	# Phase B：FLAG_VALUE_B
	print("  Phase B: %s = %s → %s" % [FLAG_NAME, str(FLAG_VALUE_B), path_b])
	# (stub) 略过实际跑

	# diff
	# ⚙️ MODULE-CUSTOM 7：如果两段 path 文件存在，加载 + 比对
	if FileAccess.file_exists(path_a) and FileAccess.file_exists(path_b):
		_compare_summaries(path_a, path_b)
	else:
		print("  [SKIP] dump files not produced — fill MODULE-CUSTOM 5/6 in this template")

	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


# ─── 通用：解析 SUMMARY TSV 并对每个字段做 mean_diff 检查 ───────────
#
# DCSoakDump SUMMARY TSV 格式（dots_soak_dump.gd::_record_summary）：
#   tick_idx \t day \t phase \t phase_kind \t field_name \t min \t max \t mean \t std
#
# 本夹具按 (tick_idx × field_name) 配对，比较两文件的 mean 列差。
func _compare_summaries(path_a: String, path_b: String) -> void:
	var rows_a: Dictionary = _load_summary(path_a)
	var rows_b: Dictionary = _load_summary(path_b)
	for key in rows_a:
		if not rows_b.has(key):
			continue
		var mean_a: float = float(rows_a[key])
		var mean_b: float = float(rows_b[key])
		var diff: float = absf(mean_a - mean_b)
		var field_name: String = String(key).split("|")[1]  # key = tick_idx|field
		var threshold: float = _threshold_for(field_name)
		_expect_within_abs("[%s] mean_diff" % field_name, diff, threshold)


func _load_summary(path: String) -> Dictionary:
	var out: Dictionary = {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line: String = f.get_line()
		if line.is_empty() or line.begins_with("#"):
			continue
		var cols: PackedStringArray = line.split("\t")
		if cols.size() < 8:
			continue
		var tick_idx: String = cols[0]
		var field_name: String = cols[4]
		var mean: String = cols[7]
		out["%s|%s" % [tick_idx, field_name]] = float(mean)
	f.close()
	return out


func _threshold_for(field_name: String) -> float:
	# 1. WATCH_FIELDS 显式设置优先
	for entry in WATCH_FIELDS:
		var ed: Dictionary = entry as Dictionary
		if String(ed.get("field", "")) == field_name:
			var t: float = float(ed.get("threshold", NAN))
			if not is_nan(t):
				return t
	# 2. stochastic 前缀白名单
	for prefix in STOCHASTIC_PREFIXES:
		if field_name.begins_with(String(prefix)):
			return STOCHASTIC_THRESHOLD
	# 3. 默认 scalar
	return SCALAR_THRESHOLD


func _expect_within_abs(label: String, diff: float, threshold: float) -> void:
	_checks += 1
	if diff <= threshold:
		return
	push_error("[%s_soak] FAIL %s: diff=%.6f > threshold=%.6f" %
		[MODULE_NAME, label, diff, threshold])
	_failures += 1


# ─── 工具函数：直接调用 DCSoakDump 跑一段 ────────────────────────────
#
# 真实模块（MODULE-CUSTOM 6）的标准用法：
#
#   DCSoakDump.instance = DCSoakDump.new()  # 如尚未创建
#   DCSoakDump.instance.start(N_TICKS, DCSoakDump.Mode.SUMMARY, path, generator)
#   for tick in range(N_TICKS):
#       scheduler.tick(some_ctx)
#       # DCSoakDump.instance.record_tick(...) 由 climate_daily_system / weather_system
#       # 在 phase 末尾自动调用
#   # DCSoakDump 自动 _close 并 emit completed signal
#
# 然后本夹具的 _compare_summaries(path_a, path_b) 比对两个 TSV。
