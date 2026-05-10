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
var slice_budget_ms: float = 4.0

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