extends RefCounted
class_name DCSystemScheduler

## DataCore — DCSystemScheduler（A3 / dots-migration-roadmap §3）。
##
## 把 SlicedUpdateScheduler（tick + budget + policy + starvation）与
## DCEcsScheduler（reads/writes 拓扑排序 + 环检测）合并为一个调度器。
##
## 设计权衡（Phase C.2 初版采用 wrapper 模式，不继承 SusScheduler）：
##   - 内部持一个 SlicedUpdateScheduler 实例做实际 tick / budget / policy 推进
##     —— 复用既有的所有 starvation / fast-tick WARN / breakdown 机制；
##   - 自己负责：(a) 收集 declare_reads/writes 派生 DAG；(b) 按拓扑序注册到
##     内部 SUS（用 priority 编码拓扑深度，priority lower 先跑）；
##     (c) tick 入口包裹 _debug_*_pass 校验；(d) 自动 swap_double_buffer。
##
## 与现有 SusScheduler / DCEcsScheduler 并存：
##   本类不替换任何现有调度器 — 是一个**额外**入口。dots-flag-prune-pr1
##   (2026-05-22)： use_dc_system_scheduler flag 已从 ClimateProfile 删除，
##   bootstrap 路径现恒走单路径。##
## 与 dots-experiment-report §3.6 一致：
##   实验已证明拓扑排序在 J=8 真实算子下 +5.08% overhead，远低于 25% 红线。
##   本类把那个沙盒结论搬进 production；reads/writes 拓扑由 DCEcsScheduler
##   原算法搬过来（Kahn O(J²) + 环检测）。

const _SusSchedulerScript = preload("res://scripts/simulation/sus/sus_scheduler.gd")
const _DCEcsSchedulerScript = preload("res://scripts/ecs/dc_ecs_scheduler.gd")
const _DCEcsJobScript = preload("res://scripts/ecs/dc_ecs_job.gd")

# ─── 内部 SUS 实例（实际 tick / budget / policy 推进） ───────────────
var _sus = _SusSchedulerScript.new()

# DCWorld 引用（用于 reads/writes comp_id 解析 + _debug_*_pass 校验）
var _world = null

# 注册的 DCSystem 列表（保留原始顺序；topo sort 时基于此构造 DAG）
var _systems: Array = []  # Array[DCSystem]

# 构造完毕、可以 tick 的标志（必须 build_topology() 后才能 tick）
var _topology_built: bool = false

# 拓扑顺序（_systems 的索引序列；与 DCEcsScheduler.topo_sort 同算法）
var _topo_order: PackedInt32Array = PackedInt32Array()


# ─── 配置（与 SusScheduler 同名透传） ────────────────────────────────

## frame_budget_ms：与 SusScheduler.frame_budget_ms 一致；调度器外部直接
## 写本字段；本类 tick 时同步给 _sus。
var frame_budget_ms: float = 12.0
var strict_budget_enabled: bool = false
var sim_budget_window_size: int = 300
var sim_budget_warn_ms: float = 1.0
var log_interval_ticks: int = 30

# dots-flag-prune-pr1 (2026-05-22)：use_gdext_sus_scheduler 已随
# SusScheduler 一起删除——SusScheduler 现恒走 ext 探测单边分支，
# 本类不再需要透传字段。


# ─── 注入 World ─────────────────────────────────────
## 由 main.gd / DataCore bootstrap 在 World 初始化完成后调用。会同步注入到
## 内部 SUS（以兼容现有 SusJob.bind_world 链路）和已注册的 DCSystem。
func bind_world(w) -> void:
	_world = w
	_sus.bind_world(w)
	for s in _systems:
		s.bind_world(w)
	# bind_world 之后调度器知道 world 了，但 declare_reads/writes 解析仍
	# 需要 build_topology() 显式触发（让 caller 控制时机，避免重复拓扑）。


# ─── 注册 DCSystem ──────────────────────────────────────────────────

## 注册一个 DCSystem 实例。会先校验 feature_flag（如声明）；不通过则跳过。
##  - cp 是 ClimateProfile 实例（让 DCFeatureFlags.is_on 能读 flag 值）；为 null
##    时跳过 flag 校验，无条件注册。
##  - 注册顺序作为拓扑排序的稳定打破依据（同优先级保留注册顺序）。
##  - 可重复注册同 id 的 system 视为编程错误，push_error 并忽略。
func register_system(system: DCSystem, cp = null) -> void:
	if system == null:
		push_error("[DCSystemScheduler] register_system: nil system")
		return
	if system.id == &"":
		push_error("[DCSystemScheduler] register_system: system has empty id")
		return
	for existing in _systems:
		if existing.id == system.id:
			push_error("[DCSystemScheduler] register_system: duplicate id %s" % str(system.id))
			return
	# Feature flag gating
	var ff: StringName = system.feature_flag()
	if ff != &"" and cp != null:
		if not DCFeatureFlags.is_on(ff, cp):
			if OS.is_debug_build():
				print("[DCSystemScheduler] system '%s' skipped (feature_flag '%s' is off)"
					% [String(system.id), String(ff)])
			return
	_systems.append(system)
	# 立即 bind_world（如果已有 world）
	if _world != null:
		system.bind_world(_world)
	# 把 DCSystem 也注册到内部 SUS（让 SUS 兼容路径正常工作）。
	# DCSystem 字段集合与 SusJob 同形，可直接当 SusJob 注册。
	_sus.register_job(system)
	# 拓扑标记 dirty
	_topology_built = false


## 构造 reads/writes 派生 DAG + 拓扑排序。注册结束后必须调一次。
##
## 算法与 DCEcsScheduler.topo_sort 一致（Kahn O(J²) + 环检测）；返回 true
## 表示构造成功，false 表示有环。
##
## 拓扑排序后通过把 priority 重新分配（base + topo_index * step）让内部 SUS
## 按拓扑序出 jobs：SUS 已按 priority 排序，所以一次 priority 重写就让两个
## 调度模型对齐。
func build_topology() -> bool:
	_topo_order = _topo_sort()
	if _topo_order.is_empty() and not _systems.is_empty():
		push_error("[DCSystemScheduler] build_topology: cycle detected; refusing to commit")
		return false
	# 把 system.priority 按 topo_index 重写，让内部 SUS 自动按拓扑序跑。
	# 注意：这会覆盖 system 自身的 priority 设置；C.3 改写的 6 个 system 应该
	# 不再依赖手写 priority（reads/writes 已经表达了所有顺序约束）。
	# 业务侧仍可用 depends_on（StringName）做硬序约束，与拓扑序叠加。
	for k in range(_topo_order.size()):
		var idx: int = _topo_order[k]
		_systems[idx].priority = 100 + k * 10
	# 重新触发 SUS 内部排序
	_sus._jobs.sort_custom(func(a, b): return a.priority < b.priority)
	_topology_built = true
	if OS.is_debug_build():
		var names: Array[String] = []
		for k in range(_topo_order.size()):
			names.append(String(_systems[_topo_order[k]].id))
		print("[DCSystemScheduler] topology: ", names)
	return true


# ─── tick 入口（透传 + reads/writes 校验包裹） ────────────────────────

## 主 tick。与 SusScheduler.tick 同形（接受 SusTickContext）。
##   - 调用前会校验拓扑已 build（未 build 时 push_error 并跳过）；
##   - 内部 SUS tick 期间每个 system 都会被 _debug_pass_begin/end 包裹（debug 构建）；
##   - tick 完成后自动调 world.swap_double_buffer(declare_writes 并集) —— 当前
##     版本不强制 swap（业务侧可能仍用手动 swap），留作 future hook。
func tick(ctx) -> void:
	if not _topology_built:
		push_error("[DCSystemScheduler] tick: topology not built; call build_topology() after register_system()")
		return
	# 同步配置
	_sus.frame_budget_ms = frame_budget_ms
	_sus.strict_budget_enabled = strict_budget_enabled
	_sus.sim_budget_window_size = sim_budget_window_size
	_sus.sim_budget_warn_ms = sim_budget_warn_ms
	_sus.log_interval_ticks = log_interval_ticks
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_sus_scheduler 透传已删除——
	# SusScheduler 现恒走 _ensure_ext＋ext-null fallback 单边分支。
	# debug-only reads/writes 校验：让每个 system 自己 begin/end pass
	# DCSystem 提供 _scheduler_debug_pass_begin/end；SUS 真正调 run_slice 时
	# 这两个钩子还没被触发——所以我们目前选择"在 tick 入口 begin、tick 结束 end"
	# 的粗粒度校验（whole-tick 维度，非 per-system）。per-system 维度需要
	# 在 SUS 内部加 hook，留作 future iteration。
	if OS.is_debug_build() and _world != null and _world.has_method("_debug_begin_pass"):
		var all_writes: Array = []
		var all_reads: Array = []
		for s in _systems:
			for w_name in s.declare_writes():
				if not all_writes.has(w_name):
					all_writes.append(w_name)
			for r_name in s.declare_reads():
				if not all_reads.has(r_name):
					all_reads.append(r_name)
		_world._debug_begin_pass(all_writes, all_reads, &"dc_system_scheduler.tick")
	_sus.tick(ctx)
	if OS.is_debug_build() and _world != null and _world.has_method("_debug_end_pass"):
		_world._debug_end_pass(&"dc_system_scheduler.tick")


## 透传 SUS reset。
func reset_all_progress() -> void:
	_sus.reset_all_progress()


# ─── 报告 / 调试 ─────────────────────────────────────────────────────

## 透传 SUS report_last_tick。
func report_last_tick() -> Dictionary:
	return _sus.report_last_tick()


func report_last_tick_summary() -> Dictionary:
	return _sus.report_last_tick_summary()


func report_sim_budget_window() -> Dictionary:
	return _sus.report_sim_budget_window()


func report_job_stats() -> Dictionary:
	return _sus.report_job_stats()


func report_skipped_summary() -> Dictionary:
	return _sus.report_skipped_summary()


## 当前注册 system 数。
func system_count() -> int:
	return _systems.size()


## 取拓扑序的 system id 列表（debug 用）。
func topology_order_names() -> Array[String]:
	var out: Array[String] = []
	for k in range(_topo_order.size()):
		out.append(String(_systems[_topo_order[k]].id))
	return out


# ─── 内部：reads/writes 拓扑排序（DCEcsScheduler 算法搬过来 + 改读 StringName）─

# 构造 DAG 边："writer system 必须早于 reader system" 与 "writer system 之间
# 按注册顺序排序（避免 WAW 不确定性）"。返回 { children, in_degree }。
# StringName 比较直接走 ==；O(J² × max(reads, writes)) 复杂度。
func _build_dag() -> Dictionary:
	var n: int = _systems.size()
	var children: Dictionary = {}
	var in_degree: PackedInt32Array = PackedInt32Array()
	in_degree.resize(n)
	for k in range(n):
		children[k] = []

	for a in range(n):
		var sa: DCSystem = _systems[a]
		var sa_writes: Array = sa.declare_writes()
		if sa_writes.is_empty():
			continue
		for b in range(n):
			if a == b:
				continue
			var sb: DCSystem = _systems[b]
			var write_to_read: bool = _intersects_string(sa_writes, sb.declare_reads())
			var write_to_write: bool = (a < b) and _intersects_string(sa_writes, sb.declare_writes())
			if write_to_read or write_to_write:
				var arr: Array = children[a]
				if not arr.has(b):
					arr.append(b)
					children[a] = arr
					in_degree[b] += 1
	return {"children": children, "in_degree": in_degree}


# Kahn 拓扑排序，stable by registration order。返回 _systems 的索引序列；
# 有环时 push_error 并返回空数组。
func _topo_sort() -> PackedInt32Array:
	var dag: Dictionary = _build_dag()
	var children: Dictionary = dag["children"]
	var in_degree: PackedInt32Array = dag["in_degree"]
	var n: int = _systems.size()

	var ready: Array = []
	for i in range(n):
		if in_degree[i] == 0:
			ready.append(i)

	var order: PackedInt32Array = PackedInt32Array()
	while not ready.is_empty():
		var pick: int = 0
		for k in range(1, ready.size()):
			var idx_k: int = int(ready[k])
			var idx_pick: int = int(ready[pick])
			var pri_k: int = int(_systems[idx_k].priority)
			var pri_pick: int = int(_systems[idx_pick].priority)
			if pri_k < pri_pick or (pri_k == pri_pick and idx_k < idx_pick):
				pick = k
		var idx: int = ready[pick]
		ready.remove_at(pick)
		order.append(idx)
		var kids: Array = children[idx]
		for c in kids:
			in_degree[c] -= 1
			if in_degree[c] == 0:
				ready.append(c)
	if order.size() != n:
		push_error("[DCSystemScheduler] cycle detected — declared %d systems, sorted %d"
			% [n, order.size()])
		return PackedInt32Array()
	return order


# StringName 数组的相交判定（O(|a| × |b|)，业务侧 reads/writes 通常 < 10 项）。
static func _intersects_string(a: Array, b: Array) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	for x in a:
		if b.has(x):
			return true
	return false
