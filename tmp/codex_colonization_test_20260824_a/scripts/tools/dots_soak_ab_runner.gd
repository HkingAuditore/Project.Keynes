extends RefCounted
class_name DCSoakABRunner

## DCSoakABRunner — 引擎内一键 A/B 对比 runner（dots-storage-同源紧急修复 2026-05-14）
##
## 替代手动跑两次 godot CLI 的工作流，把"两段 30 tick dump + diff"全过程压缩到
## 游戏内一个按键（F3 / Shift+F3）。
##
## ─── Mode（2026-05-14 修订）─────────────────────────────────────────────
##   SAME_SOURCE（默认，F3）— A 与 B 都用当前 DataCore 状态跑 N tick，不切换。
##                            **不重 generate world**：A 段跑 day N..N+30，B 段
##                            跑 day N+30..N+60，是不同时间窗口的"顺序对比"。
##                            因此 weather front 随机 spawn / 季节相位推进会让
##                            离散字段必然偏离 → 用字段白名单豁免离散类。
##                            真正反映 storage 漂移的是长期均值字段
##                            （temp_30d / temp_365d / temp_anomaly），threshold
##                            = 0.05 标量、0.01 长期均值、白名单豁免离散。
##   VS_LEGACY（Shift+F3）— A 段用当前状态，B 段 toggle DataCore master 后再跑。
##                            对比 DataCore 路径 vs legacy GDScript 路径的业务等
##                            价性。threshold = 0.5，FAIL = 数值差异巨大需排查；
##                            小差异（temp ≤ 0.05, weather_type ≤ 0.3）属预期。
##
## ─── SAME_SOURCE 字段白名单（豁免随机性主导的字段）─────────────────────
## 以下字段在 SAME_SOURCE mode 下不计入 verdict（仍会列在 Top-15 里供肉眼观察），
## 因为它们本质受随机 spawn / 离散分类影响，不能反映 storage 同步问题：
## GDScript 4：const 仅接受字面量字面量；PackedStringArray(Array) 构造调用不是
## 编译时常量。改为 static var（语义不变：类级别全局只读查找表），运行时 init。
static var _SAME_SOURCE_RANDOM_FIELDS: PackedStringArray = PackedStringArray([
	"cell.weather_type",            # 离散分类 NONE/RAIN/SNOW/STORM
	"cell.weather_intensity",       # 当前 spawn front 决定
	"cell.weather_cloud",
	"cell.weather_precip",
	"cell.weather_vapor",
	"cell.weather_instability",
	"cell.temp_season_offset",      # 季节相位 = 函数(day)，时间窗口不同必偏
	"cell.moisture",                # 受 weather front 降水/蒸发链路驱动
	"cell.snow_cover",              # 降水离散累积，weather 下游
])
## 长期均值字段：阈值更严格（0.01），因为它们应当稳定
static var _SAME_SOURCE_LONGTERM_FIELDS: PackedStringArray = PackedStringArray([
	"cell.temp_30d",
	"cell.temp_365d",
	"cell.temp_anomaly",
])
const _SAME_SOURCE_SCALAR_THRESHOLD: float = 0.05
const _SAME_SOURCE_LONGTERM_THRESHOLD: float = 0.01
##
## ─── 序列 ─────────────────────────────────────────────────────────────
##   IDLE
##     ↓ start(mode)
##   RUN_A          — 当前状态跑 N tick → phase_A.tsv
##     ↓ DCSoakDump.completed
##   BETWEEN        — VS_LEGACY: toggle DataCore + 等 1 帧
##                    SAME_SOURCE: 直接进 RUN_B 不 toggle
##     ↓
##   RUN_B          — 跑 N tick → phase_B.tsv
##     ↓ DCSoakDump.completed
##   DIFF           — 配对 (tick,phase_kind,field) mean，max mean_diff per field
##                    + verdict PASS/FAIL by mode threshold
##     ↓ completed signal
##   IDLE


# ─── 单例（main 持引用）─────────────────────────────────────────────────
static var instance: DCSoakABRunner = null


## A/B runner 完成（自然完成 / 中途取消都不会触发；仅 DIFF 阶段成功完成 emit）。
##   report: 来自 compute_diff_report()
signal completed(report: Dictionary)


enum Phase { IDLE, RUN_A, BETWEEN, RUN_B, DIFF }
enum Mode { SAME_SOURCE, VS_LEGACY, FLAG_PROFILE }


# ─── 运行期状态 ─────────────────────────────────────────────────────────
var _phase: int = Phase.IDLE
var _mode: int = Mode.SAME_SOURCE
var _main: Node = null              ## main.gd（用于 toggle DataCore + 拿 _generator）
var _n_ticks: int = 30
var _path_a: String = ""
var _path_b: String = ""
var _label_a: String = "stateA"
var _label_b: String = "stateB"
var _started_at_ms: int = 0
var _flag_overrides_a: Dictionary = {}
var _flag_overrides_b: Dictionary = {}
var _saved_flag_values: Dictionary = {}
var _flag_label_a: String = "flags_off"
var _flag_label_b: String = "flags_on"
var _batch_active: bool = false
var _batch_counts: PackedInt32Array = PackedInt32Array()
var _batch_index: int = 0
var _batch_reports: Array = []


## 启动一次 A/B 对比。
##   mode = SAME_SOURCE（默认）— 不切换 DataCore，期望 PASS（threshold=1e-4）
##   mode = VS_LEGACY          — A=current, B=toggled, threshold=0.5
## main_node 必须暴露：
##   _generator                          — MapGenerator 引用
##   _toggle_data_core_master_runtime()  — flip use_data_core master（VS_LEGACY 用）
##   is_data_core_on() (可选)            — 用于 label 标注
## 返回 false 表示无法启动（已在跑 / generator 缺失）。
func start(main_node: Node, n_ticks: int = 30, mode: int = Mode.SAME_SOURCE) -> bool:
	if _phase != Phase.IDLE:
		print("[soak-ab] already running (phase=%d). ignored." % _phase)
		return false
	if main_node == null:
		push_error("[soak-ab] start: main_node is null")
		return false
	if not "_generator" in main_node or main_node._generator == null:
		print("[soak-ab] generator not ready, ignored.")
		return false
	_main = main_node
	_mode = mode
	_n_ticks = max(1, n_ticks)
	_started_at_ms = Time.get_ticks_msec()
	# 路径生成（共享时间戳让一对 A/B 文件名能配对识别）
	# 文件名前缀按 mode 区分，便于在 user://soak/ 下肉眼区分
	var ts: String = Time.get_datetime_string_from_system().replace(":", "-")
	var prefix: String = "same"
	if _mode == Mode.VS_LEGACY:
		prefix = "vsleg"
	elif _mode == Mode.FLAG_PROFILE:
		prefix = "flags"
	_path_a = "user://soak/%s_A_%s.tsv" % [prefix, ts]
	_path_b = "user://soak/%s_B_%s.tsv" % [prefix, ts]
	# Label
	var dc_on: bool = _is_dc_on()
	if _mode == Mode.SAME_SOURCE:
		# A 和 B 都是同一状态（当前），label 一致
		_label_a = ("dc_on" if dc_on else "dc_off")
		_label_b = _label_a
	elif _mode == Mode.VS_LEGACY:
		# VS_LEGACY: A=current, B=toggled
		_label_a = ("dc_on" if dc_on else "dc_off")
		_label_b = ("dc_off" if dc_on else "dc_on")
	else:
		_label_a = _flag_label_a
		_label_b = _flag_label_b
		_apply_flag_overrides(_flag_overrides_a, true)
	var mode_str: String = _mode_name(_mode)
	print("[soak-ab] ────── A/B run start ──────")
	print("[soak-ab]   mode=%s  n_ticks=%d  phaseA=%s  phaseB=%s" % [mode_str, _n_ticks, _label_a, _label_b])
	print("[soak-ab]   path A: %s" % _path_a)
	print("[soak-ab]   path B: %s" % _path_b)
	if _mode == Mode.SAME_SOURCE:
		print("[soak-ab]   threshold=1e-4 (storage 可重复性验证；FAIL = 真问题)")
	else:
		print("[soak-ab]   threshold=0.5 (DataCore vs legacy 业务对比；小差异属预期)")
	print("[soak-ab] phase A 启动（当前状态 %s 跑 %d tick）..." % [_label_a, _n_ticks])
	return _start_phase(_path_a, Phase.RUN_A)


func start_flag_profile(main_node: Node, n_ticks: int, flags_a: Dictionary,
		flags_b: Dictionary, label_a: String = "flags_off",
		label_b: String = "flags_on") -> bool:
	_flag_overrides_a = flags_a.duplicate(true)
	_flag_overrides_b = flags_b.duplicate(true)
	_saved_flag_values.clear()
	_flag_label_a = label_a
	_flag_label_b = label_b
	return start(main_node, n_ticks, Mode.FLAG_PROFILE)


func start_season_atlas_batch(_main_node: Node,
		_tick_counts: PackedInt32Array = PackedInt32Array()) -> bool:
	# dots-flag-prune-pr1 round 2 (2026-05-22): use_gdext_season_refresh /
	# use_gdext_sea_ice_atlas_prepare flag 均已删除——batch 入口退役为 no-op stub。
	print("[soak-ab] start_season_atlas_batch: deprecated (flags removed); no-op.")
	return false


## DOTS-Final-Frontier phase 0：SIMD 三 flag 批跑入口。
## dots-flag-prune-pr1 round 2 (2026-05-22): use_gdext_pass_b_simd /
## use_gdext_ocean_water_simd / use_gdext_ocean_land_simd flag 均已删除——
## SIMD 调度现由 C++ 内部根据 CPU 特性自动选择，batch 入口退役为 no-op stub。
func start_simd_batch(_main_node: Node,
		_tick_counts: PackedInt32Array = PackedInt32Array()) -> bool:
	print("[soak-ab] start_simd_batch: deprecated (SIMD flags removed; auto-dispatched in C++); no-op.")
	return false


## DOTS-Total-CPP C.3d：thread fallback 批跑入口。
## dots-flag-prune-pr1 round 2 (2026-05-22): use_gdext_thread_fallback flag 已删除——
## thread 调度现由 C++ 内部根据 n_cells 自动选择，batch 入口退役为 no-op stub。
func start_thread_batch(_main_node: Node,
		_tick_counts: PackedInt32Array = PackedInt32Array()) -> bool:
	print("[soak-ab] start_thread_batch: deprecated (thread flags removed; auto-dispatched in C++); no-op.")
	return false


## Phase A.1：fronts zero-copy SoA 批跑入口。
## dots-flag-prune-pr1 round 2 (2026-05-22): use_gdext_fronts_soa flag 已删除——
## fronts SoA 现恒嵌入主路径，batch 入口退役为 no-op stub。
func start_fronts_soa_batch(_main_node: Node,
		_tick_counts: PackedInt32Array = PackedInt32Array()) -> bool:
	print("[soak-ab] start_fronts_soa_batch: deprecated (flag removed); no-op.")
	return false


## Phase A.3：常驻 knobs RID 批跑入口。
## dots-flag-prune-pr1 round 2 (2026-05-22): use_gdext_resident_knobs flag 已删除——
## resident knobs 现恒嵌入主路径，batch 入口退役为 no-op stub。
func start_resident_knobs_batch(_main_node: Node,
		_tick_counts: PackedInt32Array = PackedInt32Array()) -> bool:
	print("[soak-ab] start_resident_knobs_batch: deprecated (flag removed); no-op.")
	return false


# ─── 已删除 batch 入口（dots-flag-prune-pr1，2026-05-22）────────────────────
# 以下 4 个 batch 入口函数随 ClimateProfile 字段一同删除：
#   - start_season_round_batch / _start_next_season_round_run /
#     _on_batch_completed_season_round（use_gdext_season_round 已恒走单路径）
#   - start_unified_fast_tick_batch / _start_next_unified_fast_tick_run /
#     _on_batch_completed_unified_fast_tick（use_gdext_unified_fast_tick 已删）
#   - start_system_schedule_batch / _start_next_system_schedule_run /
#     _on_batch_completed_system_schedule（use_gdext_system_schedule 已删）
#   - start_sus_scheduler_batch / _start_next_sus_scheduler_run /
#     _on_batch_completed_sus_scheduler（use_gdext_sus_scheduler 已删）


## 中止当前 A/B 流程（立即 stop dump，不打 diff 报告）。
func cancel() -> void:
	if _phase == Phase.IDLE:
		return
	print("[soak-ab] cancel: phase=%d" % _phase)
	if DCSoakDump.instance != null:
		if DCSoakDump.instance.completed.is_connected(_on_dump_completed):
			DCSoakDump.instance.completed.disconnect(_on_dump_completed)
		if DCSoakDump.instance.is_active():
			DCSoakDump.instance.stop()
	_phase = Phase.IDLE
	_restore_flag_overrides()
	_batch_active = false


func is_running() -> bool:
	return _phase != Phase.IDLE


## DOTS-Total-CPP C.4：上层链式 acceptance 用，判断当前是否在 batch 模式中。
## batch 内部 multi tick_counts 之间会短暂回到 Phase.IDLE 但 _batch_active 仍为 true，
## 单看 is_running() 不够——上层 chain 只能在 batch_active=false 时切换下一 batch。
func is_batch_active() -> bool:
	return _batch_active


# ─── 内部：phase 启动 ───────────────────────────────────────────────────
func _start_phase(path: String, target_phase: int) -> bool:
	if DCSoakDump.instance == null:
		DCSoakDump.instance = DCSoakDump.new()
	if DCSoakDump.instance.is_active():
		print("[soak-ab] DCSoakDump already active; cancelling existing dump first.")
		DCSoakDump.instance.stop()
	if not DCSoakDump.instance.completed.is_connected(_on_dump_completed):
		DCSoakDump.instance.completed.connect(_on_dump_completed)
	var ok: bool = DCSoakDump.instance.start(_n_ticks, DCSoakDump.Mode.SUMMARY, path, _main._generator)
	if not ok:
		push_error("[soak-ab] _start_phase: DCSoakDump.start failed (path=%s)" % path)
		_phase = Phase.IDLE
		return false
	_phase = target_phase
	return true


func _on_dump_completed(path: String, ticks_done: int, _dump_mode: int) -> void:
	# 反卡死（2026-05-17）：DCSoakDump 探测到 N 次同 day record 没推进会主动 abort；
	# 此时 ticks_done 远小于 _n_ticks，且 dump.aborted_due_to_stall 为 true。
	# 直接放弃整个 A/B 流程回 IDLE，不跑 phase B（它一定会再次撞同样的死锁）。
	var aborted: bool = (DCSoakDump.instance != null
			and DCSoakDump.instance.aborted_due_to_stall)
	if aborted:
		print("[soak-ab] ABORT: dump 在 phase=%d 被 stall 守门触发关闭（实际 %d / 期望 %d ticks）"
				% [_phase, ticks_done, _n_ticks])
		print("[soak-ab]   原因：refresh_climate_daily 长期 dep_pending / strict_budget_one_job")
		print("[soak-ab]         （多半是 dump 自己把 weather wall 拉到 ~40ms 顶满 frame budget）。")
		print("[soak-ab]   建议：(a) 关掉 DataCore master (F10) 让 dump 路径走 legacy；")
		print("[soak-ab]         (b) 关闭其他高负载 overlay；")
		print("[soak-ab]         (c) 用 x1 速度跑 (x20 下 SUS budget 更易顶满)；")
		print("[soak-ab]         (d) 等 B3b dumper 优化 PR 把字段统计降到 ~5ms。")
		if DCSoakDump.instance != null and DCSoakDump.instance.completed.is_connected(_on_dump_completed):
			DCSoakDump.instance.completed.disconnect(_on_dump_completed)
		_phase = Phase.IDLE
		_restore_flag_overrides()
		_batch_active = false
		return
	if _phase == Phase.RUN_A:
		_phase = Phase.BETWEEN
		# Disconnect 当前回调，避免下次 phase B start 时重复连接
		if DCSoakDump.instance != null and DCSoakDump.instance.completed.is_connected(_on_dump_completed):
			DCSoakDump.instance.completed.disconnect(_on_dump_completed)
		print("[soak-ab] phase A 完成（实际 %d ticks）→ %s" % [ticks_done, path])
		# Toggle DataCore master 切换到 phase B 状态（仅 VS_LEGACY mode）
		if _mode == Mode.VS_LEGACY:
			if _main.has_method("_toggle_data_core_master_runtime"):
				print("[soak-ab] toggle DataCore master → 进入 phase B 状态 %s" % _label_b)
				_main._toggle_data_core_master_runtime()
			else:
				push_warning("[soak-ab] main 缺少 _toggle_data_core_master_runtime 方法，跳过 toggle")
		elif _mode == Mode.FLAG_PROFILE:
			print("[soak-ab] FLAG_PROFILE mode: apply phase B flags %s" % str(_flag_overrides_b))
			_apply_flag_overrides(_flag_overrides_b, false)
		else:
			print("[soak-ab] SAME_SOURCE mode：不 toggle DataCore，phase B 沿用 %s 状态" % _label_a)
		# 等下一帧让 SUS 看到任何 ClimateProfile 字段变化（hot path 每 tick 重读 cp）
		var loop = Engine.get_main_loop()
		if loop != null and loop.has_signal("process_frame"):
			await loop.process_frame
		print("[soak-ab] phase B 启动（状态 %s 跑 %d tick）..." % [_label_b, _n_ticks])
		_start_phase(_path_b, Phase.RUN_B)
	elif _phase == Phase.RUN_B:
		# 拆 connection 防止下一次复用 instance 时残留
		if DCSoakDump.instance != null and DCSoakDump.instance.completed.is_connected(_on_dump_completed):
			DCSoakDump.instance.completed.disconnect(_on_dump_completed)
		print("[soak-ab] phase B 完成（实际 %d ticks）→ %s" % [ticks_done, path])
		_phase = Phase.DIFF
		print("[soak-ab] computing diff...")
		# threshold 的语义按 mode 区分（SAME_SOURCE 走多阈值，见 _evaluate_same_source）
		var threshold: float = (_SAME_SOURCE_SCALAR_THRESHOLD if _mode == Mode.SAME_SOURCE else 0.5)
		var report: Dictionary = compute_diff_report(_path_a, _path_b, _label_a, _label_b, threshold)
		report["mode"] = _mode_name(_mode)
		# SAME_SOURCE：用字段分类阈值重新评 verdict，覆盖 compute_diff_report 默认
		if _mode == Mode.SAME_SOURCE:
			_evaluate_same_source(report)
		print_report(report, _path_a, _path_b)
		var elapsed_s: float = float(Time.get_ticks_msec() - _started_at_ms) / 1000.0
		print("[soak-ab] ────── A/B run done in %.2fs ──────" % elapsed_s)
		_phase = Phase.IDLE
		_restore_flag_overrides()
		completed.emit(report)


# ─── 内部：是否 DataCore on（兼容 main 不暴露 helper 的情况）──────────
# ─── 内部：SAME_SOURCE verdict 重评估 ───────────────────────────────────
## 把字段分三类用不同阈值评判：
##   - 白名单（随机 spawn / 离散分类）→ skip，不计入 verdict
##   - 长期均值（temp_30d/365d/anomaly）→ 0.01 严格
##   - 其他标量 → 0.05 宽松
## 把评估结果回写到 report：passed / verdict_detail / max_*。
func _evaluate_same_source(report: Dictionary) -> void:
	var per_field: Dictionary = report.get("per_field_max_diff", {})
	var worst_scalar: float = 0.0
	var worst_scalar_field: String = ""
	var worst_long: float = 0.0
	var worst_long_field: String = ""
	var skipped: PackedStringArray = PackedStringArray()
	for fname in per_field.keys():
		var name: String = String(fname)
		var diff: float = float(per_field[fname])
		if name in _SAME_SOURCE_RANDOM_FIELDS:
			skipped.append(name)
			continue
		if name in _SAME_SOURCE_LONGTERM_FIELDS:
			if diff > worst_long:
				worst_long = diff
				worst_long_field = name
		else:
			if diff > worst_scalar:
				worst_scalar = diff
				worst_scalar_field = name
	var passed_scalar: bool = worst_scalar <= _SAME_SOURCE_SCALAR_THRESHOLD
	var passed_long: bool = worst_long <= _SAME_SOURCE_LONGTERM_THRESHOLD
	report["passed"] = passed_scalar and passed_long
	report["worst_scalar"] = worst_scalar
	report["worst_scalar_field"] = worst_scalar_field
	report["worst_long"] = worst_long
	report["worst_long_field"] = worst_long_field
	report["skipped_random_fields"] = skipped
	report["scalar_threshold"] = _SAME_SOURCE_SCALAR_THRESHOLD
	report["long_threshold"] = _SAME_SOURCE_LONGTERM_THRESHOLD


func _is_dc_on() -> bool:
	# dots-flag-prune-pr1（2026-05-22）：use_data_core 字段已从 ClimateProfile
	# 删除——DataCore 已恒走单路径（World 始终 bind，weather/climate 始终走
	# DCWorld view 镜像）。保留 is_data_core_on() 探测以兼容旧 main.gd（toggle
	# master 仍可在 runtime 切换路径），fallback 路径在字段缺失时直接返回 true。
	if _main == null:
		return false
	if _main.has_method("is_data_core_on"):
		return bool(_main.is_data_core_on())
	# Fallback：DataCore 默认恒挂载，无 helper 暴露时按 on 处理。
	return true


func _mode_name(mode: int) -> String:
	if mode == Mode.SAME_SOURCE:
		return "SAME_SOURCE"
	if mode == Mode.VS_LEGACY:
		return "VS_LEGACY"
	if mode == Mode.FLAG_PROFILE:
		return "FLAG_PROFILE"
	return "UNKNOWN"


func _apply_flag_overrides(overrides: Dictionary, capture_originals: bool) -> void:
	var gen = _main._generator if _main != null and "_generator" in _main else null
	if gen == null or not gen.has_method("_c"):
		push_warning("[soak-ab] cannot apply flag overrides: generator/climate_profile missing")
		return
	var cp = gen._c()
	if cp == null:
		push_warning("[soak-ab] cannot apply flag overrides: climate_profile null")
		return
	for k in overrides.keys():
		var name: String = String(k)
		var old_v: Variant = cp.get(name)
		if typeof(old_v) == TYPE_NIL:
			push_warning("[soak-ab] flag '%s' not found on ClimateProfile; skipped" % name)
			continue
		if capture_originals and not _saved_flag_values.has(name):
			_saved_flag_values[name] = old_v
		cp.set(name, overrides[k])
		print("[soak-ab] flag %s=%s" % [name, str(overrides[k])])


func _restore_flag_overrides() -> void:
	if _saved_flag_values.is_empty():
		return
	var gen = _main._generator if _main != null and "_generator" in _main else null
	var cp = gen._c() if gen != null and gen.has_method("_c") else null
	if cp != null:
		for k in _saved_flag_values.keys():
			cp.set(String(k), _saved_flag_values[k])
			print("[soak-ab] restore flag %s=%s" % [String(k), str(_saved_flag_values[k])])
	_saved_flag_values.clear()


func _start_next_batch_run(_main_node: Node) -> bool:
	# dots-flag-prune-pr1 round 2 (2026-05-22): use_gdext_season_refresh /
	# use_gdext_sea_ice_atlas_prepare flag 均已删除——season/atlas A/B 逻辑已退役。
	# 保留函数骨架以防止 _on_batch_completed 调用点报错，直接返回作为终止。
	_batch_active = false
	if completed.is_connected(_on_batch_completed):
		completed.disconnect(_on_batch_completed)
	print("[soak-ab] season/atlas batch path retired (flags removed).")
	return false


func _on_batch_completed(report: Dictionary) -> void:
	if not _batch_active:
		return
	_batch_reports.append(report)
	_batch_index += 1
	call_deferred("_start_next_batch_run", _main)


# ─── 内部：SUMMARY TSV 解析 + diff ─────────────────────────────────────
## 解析 DCSoakDump SUMMARY TSV，返回 Dict[String -> Dict]。
##   key: "tick=%d|phase_kind=%s|field=%s"
##   val: {"min": float, "max": float, "mean": float, "std": float, "tick": int,
##         "phase_kind": String, "field": String}
##   忽略 # 注释行 与 header 行
static func _parse_summary_tsv(path: String) -> Dictionary:
	var out: Dictionary = {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[soak-ab] cannot open '%s' (err=%d)" % [path, FileAccess.get_open_error()])
		return out
	# header 期望：tick\tday\tphase\tphase_kind\tfield\tmin\tmax\tmean\tstd
	while not f.eof_reached():
		var line: String = f.get_line()
		if line == "" or line.begins_with("#") or line.begins_with("tick"):
			continue
		var parts: PackedStringArray = line.split("\t")
		if parts.size() < 9:
			continue
		var tick: int = int(parts[0])
		var phase_kind: String = String(parts[3])
		var field: String = String(parts[4])
		var entry: Dictionary = {
			"tick": tick,
			"phase_kind": phase_kind,
			"field": field,
			"min": float(parts[5]),
			"max": float(parts[6]),
			"mean": float(parts[7]),
			"std": float(parts[8]),
		}
		var key: String = "tick=%d|phase_kind=%s|field=%s" % [tick, phase_kind, field]
		out[key] = entry
	f.close()
	return out


## 跑 diff，返回报告 Dictionary：
##   {
##     "n_paired": int,                    — 两份 dump 都覆盖的 (tick,phase_kind,field) 数
##     "n_unpaired_a": int,                — 仅 A 有的
##     "n_unpaired_b": int,                — 仅 B 有的
##     "max_mean_diff_overall": float,
##     "max_field": String,                — 最大差异字段名
##     "per_field_max_diff": Dictionary,   — { field -> max abs(mean_a - mean_b) across ticks }
##     "passed": bool,                     — max_mean_diff_overall ≤ threshold
##     "threshold": float,                 — 当前阈值
##   }
static func compute_diff_report(a_path: String, b_path: String, label_a: String = "A", label_b: String = "B", threshold: float = 1e-4) -> Dictionary:
	var a: Dictionary = _parse_summary_tsv(a_path)
	var b: Dictionary = _parse_summary_tsv(b_path)
	var per_field: Dictionary = {}
	var n_paired: int = 0
	var unpaired_a: int = 0
	var unpaired_b: int = 0
	for k in a.keys():
		if not b.has(k):
			unpaired_a += 1
			continue
		n_paired += 1
		var ea: Dictionary = a[k]
		var eb: Dictionary = b[k]
		var diff: float = abs(float(ea.mean) - float(eb.mean))
		var field: String = String(ea.field)
		var prev: float = float(per_field.get(field, 0.0))
		if diff > prev:
			per_field[field] = diff
	for k in b.keys():
		if not a.has(k):
			unpaired_b += 1
	# overall max
	var overall_max: float = 0.0
	var max_field: String = ""
	for fname in per_field.keys():
		var v: float = float(per_field[fname])
		if v > overall_max:
			overall_max = v
			max_field = fname
	return {
		"path_a": a_path,
		"path_b": b_path,
		"label_a": label_a,
		"label_b": label_b,
		"n_paired": n_paired,
		"n_unpaired_a": unpaired_a,
		"n_unpaired_b": unpaired_b,
		"max_mean_diff_overall": overall_max,
		"max_field": max_field,
		"per_field_max_diff": per_field,
		"passed": overall_max <= threshold,
		"threshold": threshold,
	}


## 把 compute_diff_report 的结果格式化打到 console + 写入持久文件。
##
## 实现踩坑（2026-05-14 三次修复）：
##   1) `%-40s` 左对齐字符串宽度在 Godot 4 GDScript format 上不稳定
##      → 改成手动 ljust 拼接修复
##   2) `══` (U+2550 双线 box-drawing) 在 PowerShell 中文 codepage (GBK)
##      会让 print 这一行静默失败 → 改 100% ASCII (=====) 修复
##   3) `%` operator 在某些参数组合下 push_error 让后续 stdout 行错位
##      → 全部 stats/top-15 行改用 str() + concat 拼接，绕开 format 路径
##
## 多通道兜底：报告同时
##   a) print 到 stdout（console 友好显示）
##   b) push_warning 镜像到 stderr（即使 stdout 错位也有备份）
##   c) 写入 user://soak/last_report.txt（永远可靠的持久化通道，用户可
##      用编辑器 / cat 查看；多次 A/B 跑会覆盖最新一份）
##   d) 追加写入 user://soak/report_history.txt（C.4 串行 batch 用于保留全链路报告）
##
## 哨兵打印：每段 print 前打 step 3a/3b/4a 等细粒度标记，方便定位崩点。
static func print_report(report: Dictionary, a_path: String, b_path: String) -> void:
	print("[soak-ab] print_report step 1: read fields")
	var passed: bool = bool(report.get("passed", false))
	var threshold: float = float(report.get("threshold", 1e-4))
	var overall: float = float(report.get("max_mean_diff_overall", 0.0))
	var max_field: String = String(report.get("max_field", ""))
	var n_paired: int = int(report.get("n_paired", 0))
	var unpaired_a: int = int(report.get("n_unpaired_a", 0))
	var unpaired_b: int = int(report.get("n_unpaired_b", 0))
	var label_a: String = String(report.get("label_a", "A"))
	var label_b: String = String(report.get("label_b", "B"))
	var mode: String = String(report.get("mode", "SAME_SOURCE"))
	# 构建报告行（不用 % format，避开 GDScript runtime push_error 风险）
	var lines: Array = []
	lines.append("")
	lines.append("=================== DCSoakABRunner Report ===================")
	lines.append("  mode: " + mode)
	lines.append("  A: [" + label_a + "] " + a_path)
	lines.append("  B: [" + label_b + "] " + b_path)
	lines.append("  paired entries: " + str(n_paired) +
		"   unpaired A:" + str(unpaired_a) + "  B:" + str(unpaired_b))
	lines.append("  max mean_diff (paired ticks x fields, all fields): " + _fmt6(overall))
	lines.append("  worst field: " + max_field)
	# verdict 含义随 mode 变化
	if mode == "SAME_SOURCE":
		var ws: float = float(report.get("worst_scalar", 0.0))
		var wsf: String = String(report.get("worst_scalar_field", ""))
		var wl: float = float(report.get("worst_long", 0.0))
		var wlf: String = String(report.get("worst_long_field", ""))
		var st: float = float(report.get("scalar_threshold", 0.05))
		var lt: float = float(report.get("long_threshold", 0.01))
		var skipped = report.get("skipped_random_fields", PackedStringArray())
		lines.append("  --- SAME_SOURCE 多阈值评估 ---")
		lines.append("  scalar:    " + _fmt6(ws) + "  (" + wsf + ")  threshold=" + _fmt6(st))
		lines.append("  long-term: " + _fmt6(wl) + "  (" + wlf + ")  threshold=" + _fmt6(lt))
		lines.append("  skipped (random spawn / 离散字段): " + str(skipped.size()) + " fields")
		if passed:
			lines.append("  verdict: PASS (scalar & long-term both within tolerance)")
		else:
			lines.append("  verdict: FAIL (scalar or long-term exceeds tolerance)")
			lines.append("           ^ 长期均值(temp_30d/365d/anomaly)异常才是 storage bug 信号")
	else:
		lines.append("  threshold: " + _fmt6(threshold))
		if passed:
			lines.append("  verdict: PASS (DataCore vs legacy within tolerance " + _fmt6(threshold) + ")")
		else:
			lines.append("  verdict: FAIL (DataCore vs legacy diverged beyond " + _fmt6(threshold) + ")")
			lines.append("           ^ EXPECTED for some fields (weather_type/spawn 顺序差异)")
			lines.append("           ^ Investigate only if scalar fields (temp/moisture) > 0.05")
	# Top-15 fields
	var per_field: Dictionary = report.get("per_field_max_diff", {})
	var pairs: Array = []
	for k in per_field.keys():
		pairs.append({"field": String(k), "diff": float(per_field[k])})
	pairs.sort_custom(func(x, y): return float(x.diff) > float(y.diff))
	lines.append("  --- Top-15 fields by max mean_diff ---")
	var n_show: int = mini(15, pairs.size())
	var col_w: int = 36
	for i in range(n_show):
		var p: Dictionary = pairs[i]
		var marker: String = "      "
		if float(p.diff) > threshold:
			marker = "  *** "
		var fname: String = String(p.field)
		if fname.length() < col_w:
			fname += " ".repeat(col_w - fname.length())
		lines.append("    " + marker + fname + "  " + _fmt6(float(p.diff)))
	if pairs.size() > n_show:
		lines.append("    ... (+" + str(pairs.size() - n_show) +
			" more fields, all <= " + _fmt6(float(pairs[n_show - 1].diff)) + ")")
	lines.append("=============================================================")
	lines.append("")
	# Channel 1: stdout print（每行独立 print，方便 console 查看）
	print("[soak-ab] print_report step 2: write " + str(lines.size()) + " lines to stdout")
	for ln in lines:
		print(String(ln))
	# Channel 2: stderr 镜像（push_warning 走 Godot debugger console，stdout 错位时仍可见）
	print("[soak-ab] print_report step 3: mirror to stderr (push_warning)")
	for ln in lines:
		push_warning("[soak-ab-report] " + String(ln))
	# Channel 3: 写到 user://soak/last_report.txt（持久化兜底；下一次 A/B 会覆盖）
	print("[soak-ab] print_report step 4: persist to user://soak/last_report.txt")
	var report_path: String = "user://soak/last_report.txt"
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var f: FileAccess = FileAccess.open(report_path, FileAccess.WRITE)
	if f != null:
		for ln in lines:
			f.store_line(String(ln))
		f.flush()
		f.close()
		print("[soak-ab] report persisted: " + report_path)
	else:
		push_error("[soak-ab] cannot write last_report.txt err=" + str(FileAccess.get_open_error()))
	# Channel 4: 追加到 history，C.4 串行 batch 能保留 4 个 batch 的完整报告。
	var history_path: String = "user://soak/report_history.txt"
	var hf: FileAccess = FileAccess.open(history_path, FileAccess.READ_WRITE)
	if hf == null:
		hf = FileAccess.open(history_path, FileAccess.WRITE)
	else:
		hf.seek_end()
	if hf != null:
		hf.store_line("")
		hf.store_line("# report_at=" + Time.get_datetime_string_from_system())
		for ln in lines:
			hf.store_line(String(ln))
		hf.flush()
		hf.close()
		print("[soak-ab] report history appended: " + history_path)
	else:
		push_error("[soak-ab] cannot append report_history.txt err=" + str(FileAccess.get_open_error()))
	print("[soak-ab] print_report done")


# 内部：6 位小数 float → string，绕开 `%.6f` format 路径
static func _fmt6(v: float) -> String:
	return String.num(v, 6)


## 文件选择 helper：扫 user://soak/ 找最近两份 .tsv，返回 [newest_a, newest_b]。
## 用于 "F3 也支持 diff 已有文件" 场景（暂不连入 hotkey，留作 API）。
static func find_two_latest_tsv(dir: String = "user://soak/") -> Array:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return []
	var files: Array = []
	d.list_dir_begin()
	var name: String = d.get_next()
	while name != "":
		if not d.current_is_dir() and name.ends_with(".tsv"):
			var full: String = dir.path_join(name)
			var t: int = int(FileAccess.get_modified_time(full))
			files.append({"path": full, "mtime": t})
		name = d.get_next()
	d.list_dir_end()
	files.sort_custom(func(x, y): return int(x.mtime) > int(y.mtime))
	if files.size() < 2:
		return []
	return [String(files[0].path), String(files[1].path)]
