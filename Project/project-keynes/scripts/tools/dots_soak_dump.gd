extends RefCounted
class_name DCSoakDump

## DataCore — Soak Dump 工具（dots-storage-同源紧急修复 2026-05-14）
##
## 目标：把 N 个 tick 内所有 cell 全部 schema 字段 dump 到文件，让 A/B
## 对比（开/关 use_gdext_*）变成一行 diff 命令，让 storage 同源 bug、
## 温度逐日累积异常等"长时间序列发散"问题可被肉眼/工具排查。
##
## 设计：
##   - **stateless 单例**：DCSoakDump.instance 全局可见。main.gd 在 _ready
##     创建一次，放进 instance 槽；climate / weather pipeline 末尾通过
##     instance 调 record_tick。
##   - **schema 自动遍历**：从 DCComponentSchema.entries_production() 取全部
##     非 demo 条目，按 dtype 分支取 PackedFloat32Array / PackedByteArray，
##     写入逻辑统一，新增 schema 字段自动出现在 dump 里。
##   - **两种 mode**：
##       SUMMARY（默认，~5 KB / tick）— 每字段一行 (min,max,mean,std)，
##         适合 "30 tick 趋势线 + diff mean 列" 工作流。
##       FULL（~250 KB / tick @ 2400 cells）— 每 tick 一行 JSON，cells 数组
##         逐 idx 一份字段字典；适合 "找出第一个偏离的 cell × 字段" 工作流。
##   - **N tick 计数**：record_tick 调用方传 phase_kind="climate"|"weather"。
##     仅 climate phase 完成时递减 _remaining 并视为一个 tick 结束；
##     weather phase 是同一 tick 的子段，附加写入但不计数。
##   - **flush 频率**：每 tick 一次 file.flush()，避免 crash 丢数据。
##
## 用例（修复 A/B 验收）：
##   --no-data-core --soak-dump=30          → user://soak/auto.tsv
##   --data-core --soak-dump=30:summary:user://soak/with_dc.tsv
##   diff a.tsv b.tsv                       → mean 列应 ≤1e-4
##
## 详见 docs/dots-soak-dump-howto.md。


# ─── 单例（main.gd 持引用，全局可见；CLI 启动时初始化）─────────────────
static var instance: DCSoakDump = null


## dump 会话结束时 emit。N tick 自然完成与主动 stop() 都会触发（_close 内部）。
## 上层（DCSoakABRunner）监听此信号串两段 phase；普通用户可以忽略。
##   path:     输出文件路径
##   n_ticks:  实际 dump 的 tick 数（自然完成 = 启动时的 N；stop 提前 = 已 dump 的）
##   mode:     Mode.SUMMARY / Mode.FULL
signal completed(path: String, n_ticks: int, mode: int)


enum Mode {
	SUMMARY,  ## 单行 (min,max,mean,std) per 字段 → TSV
	FULL,     ## 整 cells 数组 JSONL（一行一 tick × phase_kind）
}


# ─── 运行期状态 ─────────────────────────────────────────────────────────
var _mode: int = Mode.SUMMARY
var _remaining: int = 0           ## 剩余 tick 数（climate phase 完成才递减）
var _path: String = ""
var _file: FileAccess = null
var _tick_idx: int = 0            ## 已完成的 tick 计数（每个 climate phase +1）
var _started_at_unix: int = 0
var _generator                    ## MapGenerator（拿 world / map 引用用）
var _summary_header_written: bool = false


## 启动 dump 会话。
##   n_ticks: 要 dump 的 tick 数（>=1）
##   mode: Mode.SUMMARY / Mode.FULL
##   path: 输出文件路径（user:// 或绝对）。空字符串 → 自动用
##         "user://soak/auto_<timestamp>.<ext>"
##   generator: MapGenerator 节点（必传；用于 record_tick 时取 world/map）
## 返回 true 表示打开成功；false 表示 file open 失败 / generator 缺失。
func start(n_ticks: int, mode: int, path: String, generator) -> bool:
	if generator == null:
		push_error("[DCSoakDump] start: generator is null")
		return false
	if n_ticks <= 0:
		push_error("[DCSoakDump] start: n_ticks must be positive (got %d)" % n_ticks)
		return false
	_mode = mode
	_remaining = n_ticks
	_generator = generator
	_tick_idx = 0
	_summary_header_written = false
	_started_at_unix = int(Time.get_unix_time_from_system())
	# 解析路径
	var resolved_path: String = path
	if resolved_path == "":
		var ts: String = Time.get_datetime_string_from_system().replace(":", "-")
		var ext: String = "tsv" if _mode == Mode.SUMMARY else "jsonl"
		resolved_path = "user://soak/auto_%s.%s" % [ts, ext]
	# 确保目录存在（user:// 和绝对路径都支持）
	var dir_path: String = resolved_path.get_base_dir()
	if dir_path != "":
		var mk_err: int = DirAccess.make_dir_recursive_absolute(dir_path)
		if mk_err != OK and mk_err != ERR_ALREADY_EXISTS:
			push_warning("[DCSoakDump] make_dir_recursive_absolute('%s') err=%d" % [dir_path, mk_err])
	_path = resolved_path
	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file == null:
		var err_code: int = FileAccess.get_open_error()
		push_error("[DCSoakDump] start: cannot open '%s' (err=%d)" % [_path, err_code])
		_remaining = 0
		_generator = null
		return false
	# 写 metadata 头
	var seed_str: String = "<unknown>"
	if generator != null and "_last_cfg" in generator and generator._last_cfg != null:
		var lc = generator._last_cfg
		if "seed" in lc:
			seed_str = str(int(lc.seed))
	var n_cells_str: String = "<unknown>"
	if generator != null and generator.has_method("get_map") and generator.get_map() != null:
		n_cells_str = str(int(generator.get_map().cell_count()))
	if _mode == Mode.SUMMARY:
		_file.store_line("# DCSoakDump v1 | %s | mode=SUMMARY | seed=%s | n_cells=%s" % [
			Time.get_datetime_string_from_system(), seed_str, n_cells_str
		])
	else:
		_file.store_line("# DCSoakDump v1 | %s | mode=FULL | seed=%s | n_cells=%s" % [
			Time.get_datetime_string_from_system(), seed_str, n_cells_str
		])
	_file.flush()
	print("[DCSoakDump] started: n_ticks=%d mode=%s path=%s" % [
		n_ticks, ("SUMMARY" if _mode == Mode.SUMMARY else "FULL"), _path
	])
	return true


## 解析 CLI 参数 "--soak-dump=N[:mode[:path]]" 并启动。
##   "30"                   → N=30, SUMMARY, 默认路径
##   "30:full"              → N=30, FULL, 默认路径
##   "30:summary:user://x.tsv" → 完全自定义
## arg 字符串是 = 后面的部分（不含 "--soak-dump=" 前缀）
func start_from_arg(arg: String, generator) -> bool:
	if arg == "":
		push_error("[DCSoakDump] start_from_arg: empty arg")
		return false
	var parts: PackedStringArray = arg.split(":")
	var n: int = int(parts[0]) if parts.size() >= 1 else 0
	var mode_int: int = Mode.SUMMARY
	if parts.size() >= 2:
		var mode_str: String = parts[1].to_lower()
		if mode_str == "full":
			mode_int = Mode.FULL
		elif mode_str == "summary":
			mode_int = Mode.SUMMARY
		else:
			push_warning("[DCSoakDump] unknown mode '%s'; defaulting to summary" % mode_str)
	var path: String = ""
	if parts.size() >= 3:
		# 路径中可能含 "://"，把第三段及之后全部 join 回去
		path = parts[2]
		for i in range(3, parts.size()):
			path += ":" + parts[i]
	return start(n, mode_int, path, generator)


## 由 climate / weather pipeline 末尾调。
##   phase_kind: "climate" | "weather"
##   day: 当前 sim day（每 climate round 递增 1）
##   season_phase: 0..1 季节进度
##   map: 当前 MapData（pipeline 已持引用，直传避免再绕 generator）
##   extra: 自由 metadata，FULL mode 写入 JSON top-level；SUMMARY 忽略
##
## 仅 phase_kind=="climate" 视为一 tick 完成（递减 _remaining）。
func record_tick(phase_kind: String, day: int, season_phase: float, map, extra: Dictionary = {}) -> void:
	if not is_active():
		return
	if map == null:
		push_error("[DCSoakDump] record_tick: map is null")
		_close()
		return
	if _mode == Mode.SUMMARY:
		_record_summary(phase_kind, day, season_phase, map)
	else:
		_record_full(phase_kind, day, season_phase, extra, map)
	_file.flush()
	if phase_kind == "climate":
		_tick_idx += 1
		_remaining -= 1
		if _remaining <= 0:
			print("[DCSoakDump] completed: %d ticks dumped → %s" % [_tick_idx, _path])
			_close()


## 主动停止（不用等到 N 结束；冷路径，用户可显式调）。
func stop() -> void:
	if _file == null:
		return
	print("[DCSoakDump] stopped manually: %d/%d ticks dumped → %s" % [
		_tick_idx, _tick_idx + _remaining, _path
	])
	_close()


func is_active() -> bool:
	return _file != null and _remaining > 0


# ─── 内部：summary（TSV）─────────────────────────────────────────────────
func _record_summary(phase_kind: String, day: int, season_phase: float, map) -> void:
	if not _summary_header_written:
		_file.store_line("tick\tday\tphase\tphase_kind\tfield\tmin\tmax\tmean\tstd")
		_summary_header_written = true
	for entry in DCComponentSchema.entries_production():
		var map_field: String = String(entry.map_field)
		var dtype: int = int(entry.dtype)
		var line: String = ""
		if dtype == DCComponentIds.F32:
			line = _summary_line_f32(map, map_field, phase_kind, day, season_phase, String(entry.name))
		elif dtype == DCComponentIds.U8:
			line = _summary_line_u8(map, map_field, phase_kind, day, season_phase, String(entry.name))
		else:
			continue  # I32 暂无生产字段；保留分支
		if line != "":
			_file.store_line(line)
	var sea_ice_line: String = _summary_line_sea_ice_r8_buffer(phase_kind, day, season_phase)
	if sea_ice_line != "":
		_file.store_line(sea_ice_line)


func _summary_line_f32(map, map_field: String, phase_kind: String, day: int, season_phase: float, field_name: String) -> String:
	var v = map.get(map_field)
	if not (v is PackedFloat32Array):
		return ""
	var arr: PackedFloat32Array = v
	var n: int = arr.size()
	if n == 0:
		return "%d\t%d\t%.4f\t%s\t%s\t0\t0\t0\t0" % [_tick_idx + 1, day, season_phase, phase_kind, field_name]
	var mn: float = arr[0]
	var mx: float = arr[0]
	var sum: float = 0.0
	var sq: float = 0.0
	for i in range(n):
		var x: float = arr[i]
		if x < mn: mn = x
		if x > mx: mx = x
		sum += x
		sq += x * x
	var mean: float = sum / float(n)
	var var_v: float = (sq / float(n)) - (mean * mean)
	var std: float = sqrt(max(0.0, var_v))
	return "%d\t%d\t%.4f\t%s\t%s\t%.6f\t%.6f\t%.6f\t%.6f" % [
		_tick_idx + 1, day, season_phase, phase_kind, field_name, mn, mx, mean, std
	]


func _summary_line_u8(map, map_field: String, phase_kind: String, day: int, season_phase: float, field_name: String) -> String:
	var v = map.get(map_field)
	if not (v is PackedByteArray):
		return ""
	var arr: PackedByteArray = v
	var n: int = arr.size()
	if n == 0:
		return "%d\t%d\t%.4f\t%s\t%s\t0\t0\t0\t0" % [_tick_idx + 1, day, season_phase, phase_kind, field_name]
	var mn: int = int(arr[0])
	var mx: int = int(arr[0])
	var sum: int = 0
	var sq: int = 0
	for i in range(n):
		var x: int = int(arr[i])
		if x < mn: mn = x
		if x > mx: mx = x
		sum += x
		sq += x * x
	var mean: float = float(sum) / float(n)
	var var_v: float = (float(sq) / float(n)) - (mean * mean)
	var std: float = sqrt(max(0.0, var_v))
	return "%d\t%d\t%.4f\t%s\t%s\t%d\t%d\t%.6f\t%.6f" % [
		_tick_idx + 1, day, season_phase, phase_kind, field_name, mn, mx, mean, std
	]


func _summary_line_sea_ice_r8_buffer(phase_kind: String, day: int, season_phase: float) -> String:
	if _generator == null or not "_last_world" in _generator or _generator._last_world == null:
		return ""
	var buf: PackedByteArray = _generator._last_world.sea_ice_fraction_buffer
	var n: int = buf.size()
	var field_name: String = "world.sea_ice_fraction_buffer_hash"
	if n == 0:
		return "%d\t%d\t%.4f\t%s\t%s\t0\t0\t0\t0" % [
			_tick_idx + 1, day, season_phase, phase_kind, field_name
		]
	var hash32: int = 2166136261
	for i in range(n):
		hash32 = int((hash32 ^ int(buf[i])) * 16777619) & 0xFFFFFFFF
	return "%d\t%d\t%.4f\t%s\t%s\t%d\t%d\t%.6f\t0" % [
		_tick_idx + 1, day, season_phase, phase_kind,
		field_name, hash32, hash32, float(hash32)
	]


# ─── 内部：FULL（JSONL）─────────────────────────────────────────────────
func _record_full(phase_kind: String, day: int, season_phase: float, extra: Dictionary, map) -> void:
	var n_cells: int = int(map.cell_count())
	var entries: Array = DCComponentSchema.entries_production()
	# 预先收集 PackedArray 引用，避免 cells 内层每次 obj.get 走 Variant 分发
	var f32_arrs: Dictionary = {}
	var u8_arrs: Dictionary = {}
	for entry in entries:
		var map_field: String = String(entry.map_field)
		var dtype: int = int(entry.dtype)
		var v = map.get(map_field)
		if dtype == DCComponentIds.F32 and v is PackedFloat32Array:
			f32_arrs[String(entry.name)] = v
		elif dtype == DCComponentIds.U8 and v is PackedByteArray:
			u8_arrs[String(entry.name)] = v
	var cells_out: Array = []
	cells_out.resize(n_cells)
	for i in range(n_cells):
		var d: Dictionary = {"idx": i}
		for k in f32_arrs.keys():
			var arr_f: PackedFloat32Array = f32_arrs[k]
			d[k] = float(arr_f[i]) if i < arr_f.size() else 0.0
		for k2 in u8_arrs.keys():
			var arr_u: PackedByteArray = u8_arrs[k2]
			d[k2] = int(arr_u[i]) if i < arr_u.size() else 0
		cells_out[i] = d
	var record: Dictionary = {
		"tick": _tick_idx + 1,
		"day": day,
		"phase": season_phase,
		"phase_kind": phase_kind,
		"cells": cells_out,
	}
	for k in extra.keys():
		if not record.has(k):
			record[k] = extra[k]
	_file.store_line(JSON.stringify(record))


func _close() -> void:
	var was_open: bool = _file != null
	var path_snapshot: String = _path
	var ticks_done: int = _tick_idx
	var mode_snapshot: int = _mode
	if _file != null:
		_file.flush()
		_file.close()
		_file = null
	_remaining = 0
	_generator = null
	if was_open:
		# 自然完成 / 主动 stop 都走这里 emit；监听方（如 DCSoakABRunner）串接 phase
		completed.emit(path_snapshot, ticks_done, mode_snapshot)
