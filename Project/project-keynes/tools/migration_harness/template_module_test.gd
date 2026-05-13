# template_module_test.gd — Migration Harness Template (B3)
#
# 复制这个文件到 `tests/<your_module>_test.gd`，按"⚙️ MODULE-CUSTOM" 注释
# 标注的位置改成你自己的 system 类名 / 字段名 / 30-tick 期望容差。
#
# 本模板覆盖 dots-migration-roadmap §5 SOP Step 5 的"30-tick SUS log 对比"
# 验收门——但脱敏成"30-tick 跑两条路径，对照输出 ±5%"：
#   - 路径 A：feature_flag 关（legacy）
#   - 路径 B：feature_flag 开（dots_gdscript / dots_cpp）
#   - 比对：30 tick 内 system tick avg/p95、关键输出字段的均值方差
#
# 运行：
#     godot --headless --script tests/<your_module>_test.gd --quit
#
# 退出码：0 = 全部 PASS；1 = 至少一项 FAIL（详情打 stderr）。

extends SceneTree

# ─── ⚙️ MODULE-CUSTOM 1：模块名 + tick 数 ─────────────────────────
const MODULE_NAME: String = "your_module"
const N_TICKS: int = 30
const RELATIVE_TOLERANCE: float = 0.05  # ±5% per dots-migration-roadmap §5

# ─── ⚙️ MODULE-CUSTOM 2：要监控的输出字段名（DCComponentSchema.CELL_*）
const WATCH_FIELDS: Array = [
	# &"cell.your_output_field_a",
	# &"cell.your_output_field_b",
]


var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== %s_test — module migration regression ===" % MODULE_NAME)

	# ─── ⚙️ MODULE-CUSTOM 3：构造测试场景 ────────────────────────
	# 真实模块在这里 new MapData / MapGenerator / DCWorld / scheduler。
	# 出于模板简洁性，下面只是一个 stub。
	# 例：
	#   var generator := MapGenerator.new()
	#   var map := generator.generate(...)
	#   var world := DCWorld.new()
	#   world.bind_map_data(map)
	#   var cp := load("res://data/world/earth_like.tres")

	# 路径 A（legacy）：feature_flag = false
	# ⚙️ MODULE-CUSTOM 4：cp.<flag> = false; 跑 N_TICKS
	var stats_a: Dictionary = _run_30_ticks(false)

	# 路径 B（dots）：feature_flag = true
	# ⚙️ MODULE-CUSTOM 5：cp.<flag> = true; 跑 N_TICKS
	var stats_b: Dictionary = _run_30_ticks(true)

	# 比对
	_compare_stats(stats_a, stats_b, RELATIVE_TOLERANCE)

	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


# Stub: 跑 N_TICKS，收集每 tick 的 system 耗时 + WATCH_FIELDS 均值方差。
# 真实模块替换为：
#   for tick in range(N_TICKS):
#       scheduler.tick(ctx)
#       collect from world.view_f32(...) etc.
func _run_30_ticks(use_dots: bool) -> Dictionary:
	# Stub return
	return {
		"path": ("dots" if use_dots else "legacy"),
		"tick_avg_us": 0,
		"tick_p95_us": 0,
		"field_means": {},
		"field_stddevs": {},
	}


func _compare_stats(a: Dictionary, b: Dictionary, tol: float) -> void:
	# tick_avg ±tol
	_expect_within_relative(
		"tick_avg_us", int(a.tick_avg_us), int(b.tick_avg_us), tol)
	# tick_p95 ±tol
	_expect_within_relative(
		"tick_p95_us", int(a.tick_p95_us), int(b.tick_p95_us), tol)
	# 字段均值 ±tol
	for field in WATCH_FIELDS:
		var key: String = String(field)
		var a_mean: float = float((a.field_means as Dictionary).get(key, 0.0))
		var b_mean: float = float((b.field_means as Dictionary).get(key, 0.0))
		_expect_within_relative(
			"field_mean[%s]" % key, a_mean, b_mean, tol)


func _expect_within_relative(label: String, a: float, b: float, tol: float) -> void:
	_checks += 1
	if a == 0.0 and b == 0.0:
		return
	var denom: float = max(abs(a), abs(b))
	if denom == 0.0:
		return
	var rel: float = abs(a - b) / denom
	if rel <= tol:
		return
	push_error("[%s_test] FAIL %s: a=%.6g b=%.6g rel=%.4f tol=%.4f" %
		[MODULE_NAME, label, a, b, rel, tol])
	_failures += 1
