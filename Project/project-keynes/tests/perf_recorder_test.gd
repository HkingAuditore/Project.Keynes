# perf_recorder_test.gd
# Plan: perf-recording-csv-export
#
# 单测 PerfRecorder 的纯函数：列并集 / CSV 转义 / 跳日帧空 cell / 动态 breakdown 列。
# 不依赖 main / SUS，直接构造模拟 row dict。
#
# Headless execution:
#     godot --headless --script tests/perf_recorder_test.gd --quit

extends SceneTree

# 通过 class_name PerfRecorder 引用：Godot 4.6 GDScript 在解析期不允许从
# preload 的脚本对象访问 const / static 成员（"Could not resolve external class member"），
# 必须走 class_name。

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
	print("=== perf_recorder test (plan: perf-recording-csv-export) ===")
	_test_csv_escape_basic()
	_test_csv_escape_special_chars()
	_test_csv_escape_numbers_and_bool()
	_test_collect_columns_fixed_first()
	_test_continuation_columns_fixed()
	_test_collect_columns_job_triplet_grouped()
	_test_collect_columns_job_first_seen_order()
	_test_collect_columns_breakdown_dynamic()
	_test_economy_telemetry_aliases()
	_test_format_csv_header_and_rows()
	_test_format_csv_missing_cell_blank()
	_test_recorder_default_core_sampling()
	_test_recorder_skipped_day_no_job_columns()
	_test_recorder_state_machine()
	print("=== perf_recorder test summary: %d checks, %d failures ===" % [_checks, _failures])


# ─── CSV 转义 ─────────────────────────────────────────────────────

func _test_csv_escape_basic() -> void:
	_expect(PerfRecorder._csv_escape("hello") == "hello", "plain string passthrough")
	_expect(PerfRecorder._csv_escape("") == "", "empty string")
	_expect(PerfRecorder._csv_escape(null) == "", "null → empty")


func _test_csv_escape_special_chars() -> void:
	_expect(PerfRecorder._csv_escape("a,b") == "\"a,b\"", "comma → quoted")
	_expect(PerfRecorder._csv_escape("a\"b") == "\"a\"\"b\"", "double quote → doubled + wrapped")
	_expect(PerfRecorder._csv_escape("a\nb") == "\"a\nb\"", "newline → quoted")
	_expect(PerfRecorder._csv_escape("res://tmp/path,x") == "\"res://tmp/path,x\"",
		"path with comma → quoted")


func _test_csv_escape_numbers_and_bool() -> void:
	_expect(PerfRecorder._csv_escape(42) == "42", "int")
	_expect(PerfRecorder._csv_escape(true) == "true", "bool true")
	_expect(PerfRecorder._csv_escape(false) == "false", "bool false")
	# float 截尾零
	var fs: String = PerfRecorder._csv_escape(1.5)
	_expect(fs == "1.5", "float trim trailing zeros: got=%s" % fs)
	var fs2: String = PerfRecorder._csv_escape(0.0)
	_expect(fs2 == "0", "float 0.0 → '0': got=%s" % fs2)
	# NaN / INF 安全（Excel 不友好）
	_expect(PerfRecorder._csv_escape(NAN) == "", "NaN → empty")
	_expect(PerfRecorder._csv_escape(INF) == "", "INF → empty")


# ─── 列并集 ───────────────────────────────────────────────────────

func _test_collect_columns_fixed_first() -> void:
	var rows: Array = [
		{"row_idx": 0, "tick_idx": 1, "j_climate_ms": 0.5, "j_climate_slices": 1, "j_climate_skip": ""},
	]
	var cols: PackedStringArray = PerfRecorder._collect_columns(rows)
	# 固定列在前
	_expect(cols[0] == "row_idx", "fixed col 0 = row_idx")
	_expect(cols[1] == "tick_idx", "fixed col 1 = tick_idx")
	# 每个 job 输出完整固定后缀列组。
	_expect(cols.size() == PerfRecorder.FIXED_COLUMNS.size() +
			PerfRecorder.JOB_SUFFIXES.size(),
		"size = fixed + job suffix cols, got=%d" % cols.size())


func _test_continuation_columns_fixed() -> void:
	var cols: PackedStringArray = PerfRecorder._collect_columns([])
	var first: int = cols.find("continuation_frames")
	var last: int = cols.find("continuation_substage_work")
	_expect(first != -1 and last != -1, "continuation perf columns present")
	_expect(first < last, "continuation perf columns retain fixed order")
	_expect(cols.find("continuation_stage_counts") != -1,
		"continuation stage counts column present")
	_expect(cols.find("continuation_stage_wall_ms") != -1,
		"continuation stage total wall column present")
	_expect(cols.find("continuation_last_substage") != -1,
		"continuation last substage column present")
	_expect(cols.find("continuation_last_next_stage") != -1,
		"continuation next-stage column present")
	_expect(cols.find("continuation_substage_counts") != -1,
		"continuation substage counts column present")
	_expect(cols.find("continuation_substage_wall_ms") != -1,
		"continuation substage total wall column present")
	_expect(cols.find("continuation_substage_max_slice_ms") != -1,
		"continuation substage max column present")
	_expect(cols.find("continuation_substage_work") != -1,
		"continuation substage work column present")
	_expect(cols.find("speed_multiplier") != -1, "speed multiplier column present")
	_expect(cols.find("tail_vegetation_plan_ms") != -1,
		"vegetation planning probe column present")


func _test_collect_columns_job_triplet_grouped() -> void:
	# 即使输入顺序是 _slices 先出现，输出也应保持 _ms / _slices / _skip 三件套聚簇
	var rows: Array = [
		{"j_weather_slices": 1, "j_weather_ms": 0.3, "j_weather_skip": ""},
	]
	var cols: PackedStringArray = PerfRecorder._collect_columns(rows)
	var i_ms: int = cols.find("j_weather_ms")
	var i_sl: int = cols.find("j_weather_slices")
	var i_sk: int = cols.find("j_weather_skip")
	_expect(i_ms != -1 and i_sl != -1 and i_sk != -1, "all three job cols emitted")
	_expect(i_ms < i_sl and i_sl < i_sk, "job triplet order: ms < slices < skip")


func _test_collect_columns_job_first_seen_order() -> void:
	# 第一行先出现 climate，第二行才出现 weather → 输出顺序：climate 三元组 → weather 三元组
	var rows: Array = [
		{"j_climate_ms": 0.5, "j_climate_slices": 1, "j_climate_skip": ""},
		{"j_weather_ms": 0.4, "j_weather_slices": 2, "j_weather_skip": ""},
	]
	var cols: PackedStringArray = PerfRecorder._collect_columns(rows)
	var ic: int = cols.find("j_climate_ms")
	var iw: int = cols.find("j_weather_ms")
	_expect(ic != -1 and iw != -1, "both jobs present")
	_expect(ic < iw, "climate first-seen → before weather: ic=%d iw=%d" % [ic, iw])


func _test_collect_columns_breakdown_dynamic() -> void:
	# 不同 tick 出现新 bd_* key 时列扩展，且 bd 列在 job 列之后
	var rows: Array = [
		{"j_climate_ms": 0.1, "bd_climate_pass_a_ms": 0.05},
		{"j_climate_ms": 0.2, "bd_climate_pass_b_ms": 0.06, "bd_weather_total_ms": 0.07},
	]
	var cols: PackedStringArray = PerfRecorder._collect_columns(rows)
	_expect(cols.find("bd_climate_pass_a_ms") != -1, "bd_climate_pass_a_ms present")
	_expect(cols.find("bd_climate_pass_b_ms") != -1, "bd_climate_pass_b_ms present")
	_expect(cols.find("bd_weather_total_ms") != -1, "bd_weather_total_ms present")
	# bd 必须在 job 之后
	var j_idx: int = cols.find("j_climate_ms")
	var bd_idx: int = cols.find("bd_climate_pass_a_ms")
	_expect(j_idx < bd_idx, "bd cols come after job cols: j=%d bd=%d" % [j_idx, bd_idx])


func _test_economy_telemetry_aliases() -> void:
	var rows: Array = [{
		"tick_idx": 7,
		"bd_economy_prepare_reuse_count": 3,
		"bd_economy_workset_cells_planned": 6144,
		"bd_economy_workset_cells_executed": 3072,
		"bd_economy_duplicate_range_count": 0,
		"bd_economy_household_market_prepare_ms": 0.4,
		"bd_economy_household_market_worker_ms": 1.2,
		"bd_economy_household_market_merge_ms": 0.2,
	}]
	var cols: PackedStringArray = PerfRecorder._collect_columns(rows)
	for key in [
		"prepare_reuse_count", "workset_cells_planned", "workset_cells_executed",
		"duplicate_range_count", "household_market_prepare_ms",
		"household_market_worker_ms", "household_market_merge_ms"]:
		_expect(cols.find(key) != -1, "economy telemetry fixed column: %s" % key)
	# The real merge path populates aliases from bd_economy_*; exercise it through
	# the public recorder input so this test catches accidental prefix drift.
	var recorder := PerfRecorder.new()
	recorder._main = null
	var row := {"tick_idx": 7}
	recorder._merge_breakdowns(row, {
		"economy": {
			"_tick_idx": 7,
			"prepare_reuse_count": 3,
			"household_market_worker_ms": 1.2,
			"last_completed_perf_valid": true,
			"last_completed_prepare_reuse_count": 9,
			"last_completed_household_market_worker_ms": 2.4,
		},
	})
	_expect(int(row.get("prepare_reuse_count", -1)) == 9,
		"economy telemetry prefers completed epoch value")
	_expect(is_equal_approx(float(row.get("household_market_worker_ms", -1.0)), 2.4),
		"economy worker timing prefers completed epoch value")


# ─── CSV 拼装 ─────────────────────────────────────────────────────

func _test_format_csv_header_and_rows() -> void:
	var rows: Array = [
		{"row_idx": 0, "tick_idx": 100, "fast_ms": 5.5, "j_climate_ms": 0.5,
			"j_climate_slices": 1, "j_climate_skip": ""},
	]
	var cols: PackedStringArray = PerfRecorder._collect_columns(rows)
	var header: String = PerfRecorder._format_header_line(cols)
	_expect(header.begins_with("row_idx,tick_idx,"), "header starts with fixed cols: %s" % header.substr(0, 30))
	var body: String = PerfRecorder._format_row_line(rows[0], cols)
	# row_idx=0 应出现在第一格
	_expect(body.begins_with("0,100,"), "row body starts with row_idx,tick_idx values: %s" % body.substr(0, 30))


func _test_format_csv_missing_cell_blank() -> void:
	# 第一行没有 j_weather_ms，应该输出空字符串占位
	var rows: Array = [
		{"row_idx": 0, "j_climate_ms": 0.5, "j_climate_slices": 1, "j_climate_skip": ""},
		{"row_idx": 1, "j_weather_ms": 0.4, "j_weather_slices": 2, "j_weather_skip": ""},
	]
	var cols: PackedStringArray = PerfRecorder._collect_columns(rows)
	var line0: String = PerfRecorder._format_row_line(rows[0], cols)
	var i_w: int = cols.find("j_weather_ms")
	_expect(i_w != -1, "weather cols emitted globally")
	# 取 line0 的对应字段
	var parts0: PackedStringArray = line0.split(",")
	_expect(parts0[i_w] == "", "missing j_weather_ms in row 0 → blank, got='%s'" % parts0[i_w])


# ─── PerfRecorder 状态 ─────────────────────────────────────────────

class _MockMain:
	extends RefCounted
	var fast_tick: int = 0
	var sus_summary: Dictionary = {}
	var sus_report: Dictionary = {}
	var breakdowns: Dictionary = {}

	func get_fast_tick_count() -> int:
		return fast_tick
	func get_sus_last_tick_summary() -> Dictionary:
		return sus_summary
	func get_sus_last_tick_report() -> Dictionary:
		return sus_report
	func get_sim_breakdowns() -> Dictionary:
		return breakdowns


func _test_recorder_default_core_sampling() -> void:
	var rec = PerfRecorder.new()
	var mock = _MockMain.new()
	mock.sus_report = {"climate": {"elapsed_ms": 2.5, "slices_run": 1}}
	rec.bind_main(mock)
	rec.start()
	rec.on_fast_tick({
		"tick_idx": 1, "timestamp_ms": 100, "was_skipped_day": false,
		"fps": 60, "fast_ms": 2.5, "t_sus_ms": 2.0, "t_render_ms": 0.0, "t_ui_ms": 0.0,
	})
	var path: String = rec.stop_and_export()
	_expect(path != "", "default CORE export returns non-empty path")
	if path == "":
		return
	var f := FileAccess.open(path, FileAccess.READ)
	_expect(f != null, "default CORE export readable")
	if f == null:
		return
	f.get_8(); f.get_8(); f.get_8()
	var header: String = f.get_line()
	f.close()
	_expect(not header.contains("j_climate_ms"),
		"default CORE omits per-tick job detail")


# 跳日帧 sus_report 不应展开为 j_*_ms 列（避免误把上一非跳日 tick 的值当本帧）
func _test_recorder_skipped_day_no_job_columns() -> void:
	var rec = PerfRecorder.new()
	var mock = _MockMain.new()
	mock.sus_report = {"climate": {"elapsed_ms": 2.5, "slices_run": 1, "skipped_reason": ""}}
	rec.bind_main(mock)
	rec.start("DETAIL", 1)

	# 跳日帧
	rec.on_fast_tick({
		"tick_idx": 1, "timestamp_ms": 100, "was_skipped_day": true,
		"fps": 60, "fast_ms": 0.2, "t_sus_ms": 0.0, "t_render_ms": 0.0, "t_ui_ms": 0.1,
	})
	# 非跳日帧
	rec.on_fast_tick({
		"tick_idx": 2, "timestamp_ms": 200, "was_skipped_day": false,
		"fps": 60, "fast_ms": 5.0, "t_sus_ms": 2.5, "t_render_ms": 1.0, "t_ui_ms": 0.5,
	})
	_expect(rec.row_count() == 2, "2 rows captured")
	# 行字典是私有成员；通过 stop_and_export 写文件再读回的方式做端到端验证。
	var path: String = rec.stop_and_export()
	_expect(path != "", "export returns non-empty path")
	if path == "":
		return
	var f := FileAccess.open(path, FileAccess.READ)
	_expect(f != null, "exported file readable")
	if f == null:
		return
	# 跳过 UTF-8 BOM 三字节
	f.get_8(); f.get_8(); f.get_8()
	var header: String = f.get_line()
	var line_skip: String = f.get_line()
	var line_normal: String = f.get_line()
	f.close()

	var cols: PackedStringArray = header.split(",")
	var i_climate: int = cols.find("j_climate_ms")
	_expect(i_climate != -1, "j_climate_ms column emitted (because non-skip row populated it)")

	var parts_skip: PackedStringArray = line_skip.split(",")
	var parts_normal: PackedStringArray = line_normal.split(",")
	# 跳日行 j_climate_ms 应为空
	_expect(parts_skip[i_climate] == "",
		"skipped_day row has blank j_climate_ms, got='%s'" % parts_skip[i_climate])
	# 非跳日行 j_climate_ms 应有数值
	_expect(parts_normal[i_climate] != "" and parts_normal[i_climate] != "0",
		"normal row has non-empty j_climate_ms, got='%s'" % parts_normal[i_climate])


func _test_recorder_state_machine() -> void:
	var rec = PerfRecorder.new()
	_expect(not rec.is_recording(), "initial: not recording")
	_expect(rec.row_count() == 0, "initial: 0 rows")
	rec.start()
	_expect(rec.is_recording(), "after start: recording=true")
	# stop 空缓冲时返回 ""
	var path: String = rec.stop_and_export()
	_expect(path == "", "stop with empty rows → empty path")
	_expect(not rec.is_recording(), "after stop: recording=false")
