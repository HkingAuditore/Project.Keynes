extends RefCounted
class_name SusJob

## SUS Job — abstract base for any periodic simulation work managed by the
## Sliced Update Scheduler.
##
## Each Job exposes a single slice via run_slice(); SUS will keep calling it
## within slice_budget_ms until either { done = true } is returned or the
## scheduler-wide frame_budget_ms is exhausted.
##
## Subclasses MUST override run_slice(). Override should_run() only if the
## default policy-forwarding behavior is insufficient.

## Unique job id, e.g. &"ocean_currents", &"refresh_climate_daily".
var id: StringName = &""

## Scheduling policy. nil → AlwaysPolicy by default.
var policy: SusPolicy = null

## Per-slice soft budget (ms). SUS uses this only as advisory; actual cutoff
## is enforced by the scheduler-wide frame_budget_ms.
var slice_budget_ms: float = 0.75

## Hard cap on how many run_slice() calls this job may receive in one SUS tick.
## 0 preserves the legacy behavior where SUS can keep calling a job while
## budget remains. Strict simulation profiles set this to 1.
var max_slices_per_tick: int = 0

## Lower priority runs first. Default 100, ocean_currents = 200, etc.
var priority: int = 100

## Job ids this job depends on. SUS will skip this tick if any dependency
## still has slices in flight.
var depends_on: Array[StringName] = []

## Bypass the scheduler-wide frame_budget_ms gate when true. Use this for
## Jobs whose absence would corrupt simulation state (e.g. weather推进 /
## 洋流刷新——若被 budget 挡掉，世界状态就停摆了)。
##
## 注意：此旗标仅绕过 frame_budget 守卫，policy / depends_on 仍正常生效。
## 设计上只有"维持游戏世界正常推进必须执行"的 Job 才能开启。
var must_run: bool = false

## Starvation 防护（2026-05-11）：当 Job 被 frame_budget_exhausted 跳过的次数
## 累积达到该阈值时，下一次 should_run/policy 通过的 tick 会绕过 budget 守卫
## 强制跑至少 1 slice，避免 sea_ice_atlas_upload / ocean_currents 这类低优先级
## Job 长期饿死。must_run=true 的 Job 不需要它（本就绕过 budget）。
##  - <=0：禁用饥饿防护（保持旧行为）
##  - 推荐 5–10：约相当于 5–10 个 fast tick 后强制让步一次
var starvation_threshold: int = 0

## Set by SUS the first time the job runs in a tick where should_run = true,
## cleared when run_slice reports done = true. Used purely for diagnostics.
var _in_flight: bool = false

## Starvation counter（2026-05-11）：每次被 frame_budget_exhausted 跳过 +1，
## 任意一次 run_slice 实际执行后清零。由 SUS 维护。
var _starvation_count: int = 0


## DataCore 接入（2026-05-11，dots-foundation-and-weather-migration）：
## SUS 在 register_job 时把 World 注入到 job._world。job 通过 _world.query()...
## 拿数据，跨 tick 切片用 SusJob cursor + World 双缓冲共同保证语义。
##
## queries 字段：仅作 hint —— job 可在初始化时把常用 query 链预 build 好放入此
## 数组，运行时直接复用而不必每个 slice 重新 chain。首版无强校验。
var _world = null    # DCWorld；类型省略以避免循环依赖
var queries: Array = []


## 由 SusScheduler.register_job 调用，注入当前 World 引用。
## job 内部如需在 reset_progress 之前做一次性 prefetch（comp_id / archetype id），
## 可在子类重写 _on_world_bound() 实现。
func bind_world(w) -> void:
	_world = w
	_on_world_bound()


## 子类重写：World 绑定后调用一次（注册 component / 解析 comp_id / 创建
## archetype 等一次性初始化逻辑）。默认空实现。
func _on_world_bound() -> void:
	pass


## Forward to policy.should_run by default. Subclasses can override for custom
## gating logic (e.g. "only run if map is loaded").
func should_run(ctx: SusTickContext) -> bool:
	if policy == null:
		return true
	return policy.should_run(self, ctx)


## Run a single slice. Implementations should:
##   1. Time their own work (Time.get_ticks_usec()).
##   2. Return { done: bool, work_done: int, elapsed_ms: float }.
##   3. Persist progress to job-local fields when done = false.
func run_slice(_ctx: SusTickContext) -> Dictionary:
	return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }


## Reset internal progress cursor. Called by SUS.reset_all_progress() when the
## map is regenerated. Subclasses override to clear pending double buffers etc.
func reset_progress() -> void:
	_in_flight = false
	_starvation_count = 0
