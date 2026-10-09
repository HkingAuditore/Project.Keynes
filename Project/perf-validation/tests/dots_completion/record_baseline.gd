# tests/dots_completion/record_baseline.gd
# 任务 1 — 静态门禁统计：行数 + 直写残留计数。
#
# 不依赖 runtime，纯 SceneTree 脚本，扫描 scripts/ 源文件并输出 baseline 报告。
# 后续 PR（任务 2~10）合入前都应跑一次本脚本对照 baseline.json。
#
# Headless 用法：
#   godot --headless --script tests/dots_completion/record_baseline.gd --quit
#
# 输出（stdout）：
#   - 4 巨石当前行数 vs 拆分目标
#   - hot path `cell.x = ` / `out_cell.x = ` 直写残留计数
#   - 已知 baseline 对比（如有 baseline.json）
#
# 退出码：始终 0（仅信息性，不强制 fail；任务 10 的 completion_gate.gd 才是 fail-or-pass）。

extends SceneTree

# 4 巨石（路径 + 拆分目标）
const _LANDMARKS: Array = [
	{path = "res://scripts/geography/map_generator.gd",  target = 1500, name = "map_generator.gd"},
	{path = "res://scripts/weather/weather_system.gd",   target =  400, name = "weather_system.gd"},
	{path = "res://scripts/rendering/map_baker.gd",      target =  800, name = "map_baker.gd"},
	{path = "res://scripts/main.gd",                     target =  400, name = "main.gd"},
]

# 直写残留扫描目标（路径 + 模式 + 该次允许上限的"占当前基线百分比"）
# pattern 1: ^\s*cell\.[a-z_]+\s*=\s   — map_generator hot path 直写
# pattern 2: out_cell\.\w+\s*=         — weather_system hot loop 直写
const _DIRECT_WRITE_TARGETS: Array = [
	{
		path = "res://scripts/geography/map_generator.gd",
		regex = "^\\s*cell\\.[a-z_]+\\s*=\\s",
		name = "map_generator cell.x =",
	},
	{
		path = "res://scripts/weather/weather_system.gd",
		regex = "out_cell\\.\\w+\\s*=",
		name = "weather_system out_cell.x =",
	},
]


func _init() -> void:
	print("=== DOTS completion baseline recorder ===")
	print("")
	_report_landmarks()
	print("")
	_report_direct_writes()
	print("")
	_report_baseline_json()
	print("")
	print("=== done ===")
	quit(0)


func _report_landmarks() -> void:
	print("─── 4 巨石行数 ──────────────────────────────────────")
	print("%-28s %8s  %8s  %s" % ["file", "current", "target", "status"])
	for entry in _LANDMARKS:
		var lines: int = _count_lines(entry.path)
		var target: int = int(entry.target)
		var status: String = "PASS" if lines <= target else ("OVER by %d" % (lines - target))
		print("%-28s %8d  %8d  %s" % [entry.name, lines, target, status])


func _report_direct_writes() -> void:
	print("─── hot path 直写残留 ──────────────────────────────")
	print("%-32s %8s  %s" % ["pattern", "count", "file"])
	for entry in _DIRECT_WRITE_TARGETS:
		var n: int = _count_regex_matches(entry.path, entry.regex)
		print("%-32s %8d  %s" % [entry.name, n, entry.path])


func _report_baseline_json() -> void:
	print("─── baseline.json snapshot ─────────────────────────")
	var path: String = "res://tests/dots_completion/baseline.json"
	if not FileAccess.file_exists(path):
		print("(no baseline.json found; create one once flags are stable)")
		return
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("(failed to open baseline.json)")
		return
	var text: String = f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		print("(baseline.json malformed; cannot parse)")
		return
	var size_b: Dictionary = data.get("_size_baseline", {})
	var hp_b: Dictionary = data.get("_hot_path_writes_baseline", {})
	print("baseline._size_baseline:")
	for key in size_b.keys():
		if String(key).begins_with("_"):
			continue
		print("  %s = %s" % [String(key), str(size_b[key])])
	print("baseline._hot_path_writes_baseline:")
	for key in hp_b.keys():
		if String(key).begins_with("_"):
			continue
		print("  %s = %s" % [String(key), str(hp_b[key])])


func _count_lines(res_path: String) -> int:
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		push_warning("[record_baseline] cannot open %s" % res_path)
		return -1
	var n: int = 0
	while not f.eof_reached():
		f.get_line()
		n += 1
	f.close()
	# eof_reached 触发后多算一行的修正：godot 文件结尾常给一个空行
	return max(0, n - 1)


func _count_regex_matches(res_path: String, pattern: String) -> int:
	var f: FileAccess = FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		push_warning("[record_baseline] cannot open %s" % res_path)
		return -1
	var rx: RegEx = RegEx.new()
	var err: int = rx.compile(pattern)
	if err != OK:
		push_error("[record_baseline] regex compile failed: %s" % pattern)
		f.close()
		return -1
	var n: int = 0
	while not f.eof_reached():
		var line: String = f.get_line()
		if rx.search(line) != null:
			n += 1
	f.close()
	return n
