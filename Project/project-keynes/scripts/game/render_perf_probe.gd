# render_perf_probe.gd
#
# 逐帧渲染遥测（真机/桌面通用，只在 perf 录制打开时由自动测试挂钩实例化）。
#
# 为什么单独一个文件：PerfRecorder 的 CSV 是"一天一行"的宽表，且 schema 与
# headless / GM 面板共用；渲染耗时是"一帧一行"，字段完全不同，硬塞进去会破坏
# 那个契约。这里做一份独立的 render_trace_*.csv。
#
# 采集内容（每帧）：
#   seg            当前分段名（baseline / no_vegetation / no_fog ...）
#   t_rel_ms       相对开始录制的毫秒
#   fps            Engine.get_frames_per_second()
#   frame_ms       相邻两帧的墙钟差
#   setup_cpu_ms   RenderingServer.get_frame_setup_time_cpu()（主线程装配 draw list）
#   draw_calls / primitives / objects   Performance 监视器（判断是不是 batch/填充率受限）
#
# 分段扫描（sweep）：按 needles 逐个把渲染层 visible=false + set_process(false)，
# 每段录 step_s 秒（前 settle_s 秒丢弃，避开可见性切换那一帧的抖动），段尾打一行
#   [render-sweep] seg=... ...
# 给 logcat 侧留摘要，不必等 CSV 也能读。
#
# 注意：GPU timestamp（RenderingDevice.capture_timestamp）只给"帧周期"级别的绝对时间戳，
# 单点无法拆出 GPU 忙时（两点都在 _process 里，中间没有绘制），所以这里不采它，
# 避免写出看着像 GPU 耗时、实则等于帧周期的假数据。GPU 侧成本用"逐层关掉后的帧时间差"表示。
extends RefCounted

const MAX_ROWS: int = 20000

# 默认扫描计划：段名 → 节点名子串（递归匹配，大小写不敏感）
# "独奏"计划：每次只留 fog + 一个模块可见，直接量这个模块的边际成本。
# 关键前提：**迷雾层必须一直可见**。实测把 FogOfWarLayer 隐藏/关掉会让帧时间
# 从 23 ms 涨到 54 ms（地形失去 early-out，见渲染章节），任何"不保留迷雾"的
# 分段都会被这条病态路径污染，量不出别的层的真实成本。
# 条目格式 ["only:名字", [节点名子串...]]。
const SOLO_SEGMENTS: Array = [
	["baseline", []],
	["floor_fog", ["only:", "fogofwar"]],
	["fog_terrain", ["only:", "fogofwar", "worldquad", "skybackground"]],
	["fog_vegetation", ["only:", "fogofwar", "shrub", "tree", "grass", "vegetation"]],
	["fog_resources", ["only:", "fogofwar", "resourcevisual"]],
	["fog_buildings", ["only:", "fogofwar", "buildingvisual"]],
	["fog_borders", ["only:", "fogofwar", "countryborder"]],
	["fog_weather", ["only:", "fogofwar", "weatherlayer", "cellcurtain"]],
	["fog_overlays", ["only:", "fogofwar", "activity", "trade", "overlay", "highlight", "colonization", "peace"]],
	["fog_ui", ["only:", "fogofwar", "@ui"]],
	["floor_fog", ["only:", "fogofwar"]],
	["baseline", []],
]

const DEFAULT_SEGMENTS: Array = [
	["baseline", []],
	["no_weather", ["weatherlayer", "cellcurtain"]],
	["baseline", []],
	["no_vegetation", ["shrub", "grass", "tree", "vegetation"]],
	["baseline", []],
	["no_fog", ["fogofwar"]],
	["baseline", []],
	["no_resources", ["resourcevisual"]],
	["no_buildings", ["buildingvisual"]],
	["no_borders", ["countryborder"]],
	["no_terrain", ["worldquad", "skybackground"]],
	["baseline", []],
	["no_world", ["@root"]],
	["baseline", []],
	["no_ui", ["@ui"]],
]

var _rows: Array = []
var _segments: Array = []
var _step_s: float = 6.0
var _settle_s: float = 2.5
var _out_dir: String = "user://perf"
var _csv_name: String = ""
var _running: bool = false
var _root: Node = null
var _ui_root: Node = null
var _hidden: Array = []
var _seg_index: int = -1
var _seg_name: String = ""
var _seg_started_ms: int = 0
var _started_ms: int = 0
var _last_frame_us: int = 0
var _seg_rows: Array = []
var _seg_ready_at_ms: int = 0
var _summary: Array = []


func configure(renderer: Node, ui_root: Node, segments: Array = [],
		step_s: float = 10.0, settle_s: float = 2.5,
		out_dir: String = "user://perf", csv_name: String = "",
		sweep_mode: String = "hide") -> void:
	_root = renderer
	_ui_root = ui_root
	if not segments.is_empty():
		_segments = segments
	elif sweep_mode == "solo":
		_segments = SOLO_SEGMENTS.duplicate(true)
	else:
		_segments = DEFAULT_SEGMENTS.duplicate(true)
	_step_s = maxf(3.0, step_s)
	_settle_s = clampf(settle_s, 0.0, _step_s * 0.5)
	_out_dir = out_dir
	_csv_name = csv_name


func start() -> void:
	_rows.clear()
	_summary.clear()
	_hidden.clear()
	_seg_index = -1
	_running = true
	_started_ms = Time.get_ticks_msec()
	_last_frame_us = 0
	_advance_segment(_started_ms)
	print("[render-probe] start segments=%d step=%.1fs settle=%.1fs root=%s" % [
		_segments.size(), _step_s, _settle_s, str(_root != null)])


func stop_and_export() -> String:
	if not _running:
		return ""
	_finish_segment(Time.get_ticks_msec(), true)
	_running = false
	_restore_layers()
	if _rows.is_empty():
		print("[render-probe] stop: no rows")
		return ""
	var dir := ProjectSettings.globalize_path(_out_dir).simplify_path()
	DirAccess.make_dir_recursive_absolute(dir)
	var fname := _csv_name
	if fname.is_empty():
		fname = "render_trace_%04d%02d%02d_%02d%02d%02d.csv" % _now_parts()
	var path := dir.path_join(fname)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[render-probe] open failed path=%s err=%d" % [path, FileAccess.get_open_error()])
		return ""
	f.store_line("seg,t_rel_ms,fps,frame_ms,setup_cpu_ms,draw_calls,primitives,objects")
	for row in _rows:
		f.store_line("%s,%d,%.2f,%.3f,%.3f,%d,%d,%d" % [
			row["seg"], int(row["t_rel_ms"]), float(row["fps"]), float(row["frame_ms"]),
			float(row["setup_cpu_ms"]), int(row["draw_calls"]),
			int(row["primitives"]), int(row["objects"])])
	f.close()
	print("[render-probe] exported rows=%d → %s" % [_rows.size(), path])
	return path


func is_running() -> bool:
	return _running


## 每帧由 web_autotest._process 调用（不受 100ms 轮询节流影响）。
func on_frame() -> void:
	if not _running:
		return
	var now_us := Time.get_ticks_usec()
	var frame_ms := 0.0
	if _last_frame_us > 0:
		frame_ms = float(now_us - _last_frame_us) / 1000.0
	_last_frame_us = now_us

	var now_ms := Time.get_ticks_msec()
	var seg_elapsed := float(now_ms - _seg_started_ms) / 1000.0
	if seg_elapsed >= _step_s:
		_finish_segment(now_ms, false)
		if _seg_index + 1 >= _segments.size():
			# 扫描走完：把层恢复回去，再录一段 after_sweep 作为"漂移对照"，
			# 防止把"最后一段仍然关着某个层"误当成稳态。
			_restore_layers()
			_seg_index += 1
			_seg_name = "after_sweep"
			_seg_started_ms = now_ms
			_seg_ready_at_ms = now_ms + int(_settle_s * 1000.0)
			_seg_rows = []
			print("[render-sweep] seg=after_sweep start (all layers restored)")
			return
		_advance_segment(now_ms)
		return

	if _rows.size() >= MAX_ROWS:
		return

	# settle 窗口内不写 row：切换可见性后会有几帧重建管线/首帧抖动，
	# 让 CSV 与 logcat 的段摘要用同一批样本，避免"两处数字不一致"。
	if now_ms < _seg_ready_at_ms:
		return

	var row := {
		"seg": _seg_name,
		"t_rel_ms": now_ms - _started_ms,
		"fps": Engine.get_frames_per_second(),
		"frame_ms": frame_ms,
		"setup_cpu_ms": RenderingServer.get_frame_setup_time_cpu(),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"primitives": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"objects": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
	}
	_rows.append(row)
	_seg_rows.append(row)


# ---------- 内部分段与层开关 ----------

func _advance_segment(now_ms: int) -> void:
	_restore_layers()
	_seg_index += 1
	var entry: Array = _segments[_seg_index]
	_seg_name = String(entry[0])
	_seg_started_ms = now_ms
	_seg_ready_at_ms = now_ms + int(_settle_s * 1000.0)
	_seg_rows = []
	var needles: Array = entry[1] if entry.size() > 1 else []
	_apply_layers(needles)
	print("[render-sweep] seg=%s start needles=%s hid=%d t_ms=%d" % [
		_seg_name, ",".join(needles), _hidden.size(), now_ms - _started_ms])


func _finish_segment(now_ms: int, final: bool) -> void:
	if _seg_name.is_empty():
		return
	# settle 内的 row 在 on_frame 就丢弃了，这里直接用。
	var usable: Array = _seg_rows
	var fps := _mean_of(usable, "fps")
	var frame_ms := _mean_of(usable, "frame_ms")
	var setup := _mean_of(usable, "setup_cpu_ms")
	var draws := _mean_of(usable, "draw_calls")
	var prims := _mean_of(usable, "primitives")
	var entry := {
		"seg": _seg_name,
		"samples": usable.size(),
		"fps": fps,
		"frame_ms": frame_ms,
		"setup_cpu_ms": setup,
		"draw_calls": draws,
		"primitives": prims,
	}
	_summary.append(entry)
	print("[render-sweep] seg=%-16s samples=%4d fps=%6.2f frame_ms=%7.2f setup_cpu_ms=%6.3f draw_calls=%6.0f primitives=%9.0f%s" % [
		_seg_name, usable.size(), fps, frame_ms, setup, draws, prims,
		" (final)" if final else ""])


static func _mean_of(rows: Array, key: String) -> float:
	if rows.is_empty():
		return 0.0
	var total := 0.0
	for row in rows:
		total += float(row.get(key, 0.0))
	return total / float(rows.size())


func _apply_layers(needles: Array) -> void:
	if needles.is_empty():
		return
	var lowered: Array = []
	var solo := false
	for needle in needles:
		var text := String(needle).to_lower()
		if text == "only:":
			solo = true
			continue
		lowered.append(text)
	if solo:
		_hide_except(lowered)
		return
	for needle in lowered:
		if needle == "@ui":
			if _ui_root != null:
				_hide_node(_ui_root)
			continue
		if needle == "@root":
			_hide_node(_root)
			continue
		_hide_matching(_root, needle)


func _hide_matching(node: Node, needle: String) -> void:
	if node == null:
		return
	for child in node.get_children():
		if String(child.name).to_lower().contains(needle):
			_hide_node(child)
		else:
			_hide_matching(child, needle)


func _hide_node(node: Node) -> void:
	if node in _hidden:
		return
	_hidden.append(node)
	var item := node as CanvasItem
	if item != null:
		item.visible = false
	node.set_process(false)
	node.set_physics_process(false)


## solo：把根渲染器下的层、WorldRoot 的兄弟覆盖层、UI 全部隐藏，只留匹配的那些。
func _hide_except(needles: Array) -> void:
	var candidates: Array = []
	if _root != null:
		for child in _root.get_children():
			candidates.append(child)
		var parent := _root.get_parent()
		if parent != null:
			for sibling in parent.get_children():
				if sibling != _root and not (sibling in candidates):
					candidates.append(sibling)
	if _ui_root != null and not (_ui_root in candidates):
		candidates.append(_ui_root)
	for node in candidates:
		var node_name := String(node.name).to_lower()
		var keep := false
		for needle in needles:
			if needle == "@ui":
				if node == _ui_root:
					keep = true
					break
			elif node_name.contains(needle):
				keep = true
				break
		if not keep:
			_hide_node(node)


func _restore_layers() -> void:
	for node in _hidden:
		if not is_instance_valid(node):
			continue
		var item := node as CanvasItem
		if item != null:
			item.visible = true
		node.set_process(true)
		node.set_physics_process(true)
	_hidden.clear()


func _now_parts() -> Array:
	var dt := Time.get_datetime_dict_from_system()
	return [int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0))]
