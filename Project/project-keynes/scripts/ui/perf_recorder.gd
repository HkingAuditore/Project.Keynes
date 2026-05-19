# perf_recorder.gd
# Plan: perf-recording-csv-export
#
# 性能录制器 —— 在 fast_tick 末尾被动接收一帧的关键耗时指标，停止时把整段
# 录制导出为宽表 CSV，方便事后用 Excel / Pandas 对照分析瓶颈。
#
# 数据来源（全部经由 main.gd 的既有 getter，不直接耦合 SUS / MapGenerator）：
#   - sample（由 main.gd._publish_fast_tick_perf_sample 构造）：tick_idx /
#     timestamp_ms / fast_ms / t_sus_ms / t_render_ms / t_ui_ms / was_skipped_day / fps
#   - main.get_sus_last_tick_report()    → 各 Job 的 elapsed_ms / slices_run / skipped_reason
#   - main.get_sus_last_tick_summary()   → largest_slice_* + sus_sim_p95_300 等
#   - main.get_sim_breakdowns()          → { climate / weather / enum_atlas / sea_ice_atlas } 子 dict
#
# CSV 列顺序：
#   1. 固定列（FIXED_COLUMNS，下方常量）
#   2. 动态 job 列：每个出现过的 job_id 展开为 j_<id>_ms / j_<id>_slices / j_<id>_skip
#   3. 动态 breakdown 列：bd_<group>_<key>，按首次出现顺序
#
# 跳日帧（was_skipped_day=true）的 SUS 段不刷新，对应 cell 留空字符串，避免
# 误把"未刷新"读作"0ms"。
#
# 不持有 SUS 引用，不修改任何 Job 内部逻辑——零新计时插桩。
class_name PerfRecorder
extends RefCounted


# 固定列（出现在 CSV 最左侧，写死保证跨录制 diff 友好）
# 注意：GDScript 的 const 不允许调构造函数，因此用 Array 字面量。
# _collect_columns / _format_*_line 内部只读迭代，不依赖具体类型。
const FIXED_COLUMNS: Array = [
	"row_idx",
	"tick_idx",
	"timestamp_ms",
	"was_skipped_day",
	"fps",
	"fast_ms",
	"t_sus_ms",
	"t_render_ms",
	"t_ui_ms",
	"largest_slice_job",
	"largest_slice_stage",
	"largest_slice_substage",
	"largest_slice_path",
	"largest_slice_ms",
	"sus_sim_p95_300",
	"sus_sim_max_300",
	"over_1ms_count_300",
]

# 软上限：避免误开后台跑爆内存。约 60000 帧 ≈ 30 分钟 30FPS。
const HARD_ROW_LIMIT: int = 60000

const JOB_COL_PREFIX: String = "j_"
const JOB_COL_MS_SUFFIX: String = "_ms"
const JOB_COL_SLICES_SUFFIX: String = "_slices"
const JOB_COL_SKIP_SUFFIX: String = "_skip"
const BD_COL_PREFIX: String = "bd_"


var _main = null  # 鸭子类型（运行时只 has_method/call 调用）；
                  # 留 untyped 是为了单测可注入 RefCounted Mock 而不必 extends Node。
var _recording: bool = false
var _rows: Array = []
var _start_tick: int = 0
var _hit_limit: bool = false


func bind_main(m) -> void:
	_main = m


func is_recording() -> bool:
	return _recording


func row_count() -> int:
	return _rows.size()


func hit_limit() -> bool:
	return _hit_limit


# 开始录制：清空缓冲。多次调用 start 等价于"丢弃旧录制重开"。
func start() -> void:
	_rows.clear()
	_recording = true
	_hit_limit = false
	if _main != null and _main.has_method("get_fast_tick_count"):
		_start_tick = int(_main.get_fast_tick_count())
	else:
		_start_tick = 0
	print("[perf-record] start (start_tick=%d)" % _start_tick)


# 停止录制并导出。
# 返回 globalize 后的导出路径；失败返回空字符串（push_error 打印细节）。
# 不论成功失败都会把 _recording 置 false；失败时保留 _rows 让用户决定下一步。
func stop_and_export() -> String:
	_recording = false
	if _rows.is_empty():
		print("[perf-record] stop: no rows captured, skip export")
		return ""

	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var fname: String = "res://tmp/perf_record_%04d%02d%02d_%02d%02d%02d.csv" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
	]
	# 兜底：保证 res://tmp 目录存在（与 _on_btn_snapshot 同模式）
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tmp"))

	var f := FileAccess.open(fname, FileAccess.WRITE)
	if f == null:
		var err: int = FileAccess.get_open_error()
		push_error("[perf-record] open failed path=%s err=%d" % [fname, err])
		return ""

	var columns: PackedStringArray = _collect_columns(_rows)

	# UTF-8 BOM（Excel 友好，能正确识别中文/Emoji；其他工具会忽略）
	f.store_8(0xEF)
	f.store_8(0xBB)
	f.store_8(0xBF)

	# Header
	f.store_line(_format_header_line(columns))

	# Body：逐行写盘，避免大 String 内存峰值
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		f.store_line(_format_row_line(row, columns))

	f.close()

	var globalized: String = ProjectSettings.globalize_path(fname)
	print("[perf-record] exported rows=%d cols=%d → %s%s" % [
		_rows.size(), columns.size(), globalized,
		"  (HIT LIMIT)" if _hit_limit else "",
	])
	# 导出后清空缓冲，避免下次 start 误算（start 会重新 clear，但 stop 后即清更直观）
	_rows.clear()
	_hit_limit = false
	return globalized


# main.gd._run_fast_tick() 末尾调用。recorder 自己拉 SUS 数据，sample 只承载
# 那些只有 main 局部知道的字段。
func on_fast_tick(sample: Dictionary) -> void:
	if not _recording:
		return
	if _hit_limit:
		return
	var row: Dictionary = sample.duplicate()

	# 计算 row_idx（录制内序号，从 0 开始；区别于 tick_idx 的全局序号）
	row["row_idx"] = _rows.size()

	# 拉 SUS 数据（main 的 getter 已 duplicate，可放心写入 row）
	if _main != null:
		if _main.has_method("get_sus_last_tick_summary"):
			var summary: Dictionary = _main.get_sus_last_tick_summary()
			_merge_summary(row, summary)
		if _main.has_method("get_sus_last_tick_report"):
			var report: Dictionary = _main.get_sus_last_tick_report()
			_merge_jobs(row, report, bool(sample.get("was_skipped_day", false)))
		if _main.has_method("get_sim_breakdowns"):
			var bds: Dictionary = _main.get_sim_breakdowns()
			_merge_breakdowns(row, bds)

	_rows.append(row)
	if _rows.size() >= HARD_ROW_LIMIT:
		_hit_limit = true
		_recording = false
		push_warning("[perf-record] hit hard row limit (%d), auto-stop. Press 停止并导出 to flush." % HARD_ROW_LIMIT)


# ---------- 内部：合并器 ----------

# largest_slice_* + sus_sim_p95_300 / sus_sim_max_300 / over_1ms_count_300
func _merge_summary(row: Dictionary, summary: Dictionary) -> void:
	if summary.is_empty():
		return
	for k in [
		"largest_slice_job", "largest_slice_stage", "largest_slice_substage",
		"largest_slice_path", "largest_slice_ms",
		"sus_sim_p95_300", "sus_sim_max_300", "over_1ms_count_300",
	]:
		if summary.has(k):
			row[k] = summary[k]


# 跳日帧 SUS 没运行——_last_report 仍是上一非跳日 tick 的内容。为避免污染，
# 跳日帧的 job 列全部留空。
func _merge_jobs(row: Dictionary, report: Dictionary, was_skipped_day: bool) -> void:
	if was_skipped_day or report.is_empty():
		return
	for job_id in report.keys():
		var r: Dictionary = report[job_id]
		var key_ms: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_MS_SUFFIX
		var key_slices: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SLICES_SUFFIX
		var key_skip: String = JOB_COL_PREFIX + str(job_id) + JOB_COL_SKIP_SUFFIX
		row[key_ms] = float(r.get("elapsed_ms", 0.0))
		row[key_slices] = int(r.get("slices_run", 0))
		row[key_skip] = str(r.get("skipped_reason", ""))


# breakdowns = { "climate": {...}, "weather": {...}, "enum_atlas": {...}, "sea_ice_atlas": {...} }
# 每个子 dict 的 key 集合不固定，全部展开为 bd_<group>_<key>。
func _merge_breakdowns(row: Dictionary, bds: Dictionary) -> void:
	if bds.is_empty():
		return
	for group in bds.keys():
		var sub = bds[group]
		if not (sub is Dictionary):
			continue
		for k in (sub as Dictionary).keys():
			var col: String = BD_COL_PREFIX + str(group) + "_" + str(k)
			row[col] = (sub as Dictionary)[k]


# ---------- 静态：列并集 / CSV 拼装 ----------

# 收集所有出现过的列名：固定列 → job 列（按首次出现顺序，且按 ms/slices/skip 三元组聚簇） → bd 列。
static func _collect_columns(rows: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}

	# Phase 1：固定列
	for c in FIXED_COLUMNS:
		out.append(c)
		seen[c] = true

	# Phase 2：扫描 rows，按首次出现顺序收集 job 与 bd 的"基名"（不含 _ms/_slices/_skip）
	var job_bases: Array = []
	var job_base_seen: Dictionary = {}
	var bd_keys: Array = []
	var bd_key_seen: Dictionary = {}

	for row in rows:
		var d: Dictionary = row
		for k in d.keys():
			var ks: String = str(k)
			if seen.has(ks):
				continue
			if ks.begins_with(JOB_COL_PREFIX):
				# 找最长后缀匹配（"_skip" / "_slices" / "_ms"）
				var base: String = ""
				if ks.ends_with(JOB_COL_SKIP_SUFFIX):
					base = ks.substr(0, ks.length() - JOB_COL_SKIP_SUFFIX.length())
				elif ks.ends_with(JOB_COL_SLICES_SUFFIX):
					base = ks.substr(0, ks.length() - JOB_COL_SLICES_SUFFIX.length())
				elif ks.ends_with(JOB_COL_MS_SUFFIX):
					base = ks.substr(0, ks.length() - JOB_COL_MS_SUFFIX.length())
				if base != "" and not job_base_seen.has(base):
					job_base_seen[base] = true
					job_bases.append(base)
			elif ks.begins_with(BD_COL_PREFIX):
				if not bd_key_seen.has(ks):
					bd_key_seen[ks] = true
					bd_keys.append(ks)

	# Phase 3：每个 job_base 输出三元组（_ms / _slices / _skip）
	for base in job_bases:
		out.append(base + JOB_COL_MS_SUFFIX)
		out.append(base + JOB_COL_SLICES_SUFFIX)
		out.append(base + JOB_COL_SKIP_SUFFIX)

	# Phase 4：bd 列
	for k in bd_keys:
		out.append(k)

	return out


static func _format_header_line(columns: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c in columns:
		parts.append(_csv_escape(c))
	return ",".join(parts)


static func _format_row_line(row: Dictionary, columns: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c in columns:
		if row.has(c):
			parts.append(_csv_escape(row[c]))
		else:
			parts.append("")  # 缺失值留空字符串
	return ",".join(parts)


# RFC 4180 转义：
#   - 数字 → 直接 str()（GDScript float 默认精度足够分析；不强行限位）
#   - bool → "true" / "false"
#   - 字符串：含 ',' '"' '\n' '\r' 时加双引号包裹，内部 '"' 翻倍
static func _csv_escape(value) -> String:
	var s: String = ""
	var t: int = typeof(value)
	if t == TYPE_NIL:
		return ""
	elif t == TYPE_BOOL:
		s = "true" if bool(value) else "false"
	elif t == TYPE_INT:
		s = str(int(value))
	elif t == TYPE_FLOAT:
		# 保留 6 位小数，去尾零；NaN / INF 转空，避免 Excel 报错
		var fv: float = float(value)
		if is_nan(fv) or is_inf(fv):
			return ""
		s = ("%.6f" % fv).rstrip("0").rstrip(".")
		if s == "" or s == "-":
			s = "0"
	else:
		s = str(value)

	# 是否需要转义
	if s.find(",") != -1 or s.find("\"") != -1 or s.find("\n") != -1 or s.find("\r") != -1:
		s = s.replace("\"", "\"\"")
		return "\"" + s + "\""
	return s
