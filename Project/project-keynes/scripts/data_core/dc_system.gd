extends SusJob
class_name DCSystem

## DataCore — DCSystem 基类（A2 / dots-migration-roadmap §3）。
##
## 设计目标：让"加一个新 system"机械化、可重复，把 _on_world_bound 里手写
## 25+ 个 _comp_cell_* = _world.component_id(...) 缓存的样板代码消除掉，
## 同时为 DCSystemScheduler 的 reads/writes 自动校验提供契约入口。
##
## **继承自 SusJob**（GDScript 静态类型校验要求）：DCSystem 是 SusJob 的子类，
## 自动获得 `id / policy / priority / depends_on / slice_budget_ms / must_run /
## starvation_threshold / _world / _in_flight / _starvation_count / queries`
## 等字段，以及 `bind_world / _on_world_bound / should_run / run_slice /
## reset_progress` 等方法。本基类在此基础上添加 `declare_*` 系列、自动 cid
## cache、reads/writes 校验 hook。
##
## 这层继承让 DCSystem 实例可被 `SlicedUpdateScheduler.register_job(SusJob)`
## 直接接受（无需 cast，类型校验通过）；同时由 `DCSystemScheduler` 通过
## `declare_reads/writes` 做拓扑排序 + reads/writes 校验。
##
## 加新 system 的 SOP（dots-migration-roadmap §5）：
##   1. extends DCSystem
##   2. 重写 declare_reads / declare_writes / declare_pools / declare_archetypes
##      / feature_flag —— 都是声明，调度器读它们做校验
##   3. （可选）重写 setup(world) 做一次性初始化；基类已自动把
##      declare_reads + declare_writes 中的 component 全部解析到 `_cid` 字典，
##      子类可直接用 `_world.view_f32(_cid[&"cell.temp"])`
##   4. 实现 tick(ctx) 做主体逻辑；返回 {"done": bool, ...}

# ─── DCSystem 自带（SusJob 没有的字段）─────────────────────────────
#
# 注：id / policy / priority / depends_on / slice_budget_ms / must_run /
# starvation_threshold / _world / _in_flight / _starvation_count / queries
# 等字段全部从 SusJob 继承，本类不再重复声明（重复声明会导致 shadow warning
# 或在严格类型模式下 parse error）。

# 自动 cache：基类 setup() 默认把 declare_reads + declare_writes 中所有
# component 解析为 comp_id（int），存到 _cid 字典。子类 tick 可直接：
#   var temp: PackedFloat32Array = _world.view_f32(_cid[&"cell.temp"])
var _cid: Dictionary = {}

# 是否所有 declared component 都已 ready（调度器在 reads/writes 校验时用）。
var _components_ready: bool = false


# ─── 子类必须 / 可选重写的 declare_* 系列 ──────────────────────────
#
# 这 5 个方法的返回值在 setup() 时被读取一次，缓存到 _cid 与调度器内部。
# 运行时不再调用——所以子类应该返回 const 数组，避免每次构造列表的 GC 压力。

## 声明本 system 读取的 cell-level component（StringName 形式，
## 等同 DCComponentIds.CELL_*）。空数组 = 不读 cell 数据。
func declare_reads() -> Array[StringName]:
	return []

## 声明本 system 写入的 cell-level component。
## 调度器 debug 校验：tick 内部用 world.write_* 写到非本表声明的 component
## 时 push_error。
func declare_writes() -> Array[StringName]:
	return []

## 声明本 system 关联的 pool（StringName，等同 DCComponentIds.POOL_*）。
## DCSystemScheduler 启动期会校验所有声明 pool 都已 create_pool。
func declare_pools() -> Array[StringName]:
	return []

## 声明本 system 创建 / 关联的 archetype。
func declare_archetypes() -> Array[StringName]:
	return []

## 关联 feature flag（DCFeatureFlags.FLAGS 中的 name）。空 StringName = 常驻挂载。
## 调度器 register 时会调 DCFeatureFlags.is_on(feature_flag, cp) 决定是否真正
## 把 system 加入 _systems 列表。
func feature_flag() -> StringName:
	return &""


# ─── 生命周期 ──────────────────────────────────────────────────────

## 由 SlicedUpdateScheduler.register_job 或 DCSystemScheduler 在注入 World 时调。
## 默认实现：调用子类 setup() 让其完成业务侧 prefetch。
func bind_world(w) -> void:
	_world = w
	setup(w)
	_on_world_bound()  # SusJob 兼容回调


## 子类可重写：拿到 World 后做一次性 prefetch / cache。
## 基类默认实现：把 declare_reads + declare_writes 中所有 component 解析为
## comp_id 缓存到 _cid 字典；缺失时 push_warning。
func setup(w) -> void:
	_cid.clear()
	_components_ready = true
	if w == null:
		_components_ready = false
		return
	for comp_name in declare_reads():
		var c: int = int(w.component_id(comp_name))
		if c < 0:
			if OS.is_debug_build():
				push_warning("[DCSystem:%s] declare_reads component '%s' not registered on world" % [String(id), String(comp_name)])
			_components_ready = false
		_cid[comp_name] = c
	for comp_name in declare_writes():
		# 同名 component 在 reads + writes 都声明时只解析一次
		if not _cid.has(comp_name):
			var c: int = int(w.component_id(comp_name))
			if c < 0:
				if OS.is_debug_build():
					push_warning("[DCSystem:%s] declare_writes component '%s' not registered on world" % [String(id), String(comp_name)])
				_components_ready = false
			_cid[comp_name] = c


## SusJob 兼容回调：bind_world 完成后被调一次。子类可重写做额外初始化
## （比如缓存非 schema 字段、初始化游标等）。基类默认空实现。
##
## 注意：基类 setup() 已经自动 cache 了 declare_reads/writes 中的 comp_id；
## 子类无需再手写 25 个 _comp_cell_* = _world.component_id(...) 行。
func _on_world_bound() -> void:
	pass


## SusJob 兼容方法：是否所有 component 都已 ready。
func data_core_ready() -> bool:
	return _components_ready and _world != null and _world.is_bound()


# ─── 调度器入口 ─────────────────────────────────────────────────────

## 主 tick。子类必须重写。
##
## ctx 可以是 SusTickContext（SUS 路径）或 Dictionary（DCEcs 风格）。
## 返回值：{ "done": bool, "work_done": int, "elapsed_ms": float, "progress_ratio": float }
##         （SUS 兼容字段；DCSystemScheduler 也接受同样的格式）
func tick(_ctx) -> Dictionary:
	return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}


## SusJob 兼容入口。SlicedUpdateScheduler 调它而不是 tick；默认 forward 到 tick。
## 子类如果同时支持 SUS 和 DCSystemScheduler 两路径，重写 tick 即可。
## 参数类型 SusTickContext 与父类 SusJob.run_slice 严格对齐（GDScript 静态
## 类型检查要求 override 签名兼容）。
func run_slice(ctx: SusTickContext) -> Dictionary:
	return tick(ctx)


## SusJob 兼容入口。policy 决定是否本 tick 该跑。默认 forward 到 policy.should_run。
## 参数类型 SusTickContext 与父类 SusJob.should_run 严格对齐。
func should_run(ctx: SusTickContext) -> bool:
	if policy == null:
		return true
	return policy.should_run(self, ctx)


## SusJob 兼容入口。SUS 在 reset_all_progress 时调。
## 直接转发到父类（父类已做相同重置）。
func reset_progress() -> void:
	super.reset_progress()


# ─── 调度器内部用 ──────────────────────────────────────────────────

## DCSystemScheduler 在 tick 前后调 _debug_begin_pass / _debug_end_pass，
## 把 declare_writes 喂给 DCWorld 做"写到非声明 component 即报错"的校验。
## 当前 DCWorld 没有 _debug_begin_pass / _debug_end_pass API（占位）；
## C.2 引入 DCSystemScheduler 时同步在 DCWorld 加这两个方法即可。
func _scheduler_debug_pass_begin() -> void:
	if not OS.is_debug_build():
		return
	if _world == null:
		return
	if _world.has_method("_debug_begin_pass"):
		_world._debug_begin_pass(declare_writes(), declare_reads(), id)


func _scheduler_debug_pass_end() -> void:
	if not OS.is_debug_build():
		return
	if _world == null:
		return
	if _world.has_method("_debug_end_pass"):
		_world._debug_end_pass(id)


## 调试摘要。
func describe() -> String:
	return "DCSystem[%s] reads=%d writes=%d pools=%d flag=%s" % [
		String(id),
		declare_reads().size(),
		declare_writes().size(),
		declare_pools().size(),
		String(feature_flag()) if feature_flag() != &"" else "(none)",
	]
