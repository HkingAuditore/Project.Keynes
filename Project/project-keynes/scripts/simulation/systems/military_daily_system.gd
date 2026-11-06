extends DCSystem
class_name MilitaryDailySystem

## `military_daily` — Military 是主线程同步 runtime（contract §0.1）。
##
## 非整图权威路径（legacy / 分域 ACTIVE）：
##   每个 SimulationDay 调一次 `MilitaryFacade.run_daily(day)`。native 侧采集
##   Country/Economy 的**已提交** D 日视图，跑 Military 的 D 日阶段，产出生效于
##   D+1 的意图（Country / Economy 命令批次）。
##
## 整图 ACTIVE 路径：本 system 的 `should_run` 返回 false（与 country/economy
## 一致）。worker 从不推进 Military：`WorldRuntimeHost` 在每个观察到的已提交日
## 把 day 入队（`_queue_runtime_military_commit`），`_drain_runtime_military_commits`
## 每帧最多补跑 4 日，在**主线程**直接调 `MilitaryFacade.run_daily(day)`
## （即 native `run_military_daily`），随后调本 system 的 `forward_military_events()`。
##
## 事件：Military 日阶段尾部把 40..47 事件压进自己的 ring，本 system 在每个
## military 日之后把它们 `forward` 进 GameplayEventBus，Trigger/叙事/音乐/年报
## 与其它事件一致地消费，不需要各自去轮询 native。
##
## reads / writes：不写任何 DataCore cell component。Military 只写自己的 store；
## 对 Country / Economy 的所有修改都通过它们的命令入口。因此这里 declare_* 为空，
## build_topology 不会给它排到别的 system 后面（除 Country/Economy 是逻辑依赖，
## 不是 cell 数据依赖）。

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const MilitaryFacadeScript = preload("res://scripts/military/military_facade.gd")

## GameplayEventBus source id for military facts; must match
## TriggerCatalog.SOURCE_MILITARY so military trigger rules select these rows.
const EVENT_SOURCE_MILITARY := 5
const EVENT_TYPE_MIN := 40
const EVENT_TYPE_MAX := 47
const PAYLOAD_SCHEMA_BASE := 20
const EVENT_POLL_LIMIT := 256
## Bus publishes at most one small batch per military day; a long war can emit a
## few hundred facts (control flips dominate), so chunk them.
const EVENT_FORWARD_BATCH := 64

var facade = null
var world_clock: WorldClock = null
var event_bus = null
var _last_report: Dictionary = {}
var _event_cursor: int = 0
var _events_forwarded: int = 0
var _last_day: int = -1


func _init(p_facade, p_world_clock: WorldClock = null, p_generator = null,
		p_event_bus = null) -> void:
	id = MilitaryFacadeScript.SYSTEM_ID
	# Country (255) and Economy (260) emit the committed facts Military reads;
	# priority only decides tie-broken launch order inside SUS.
	priority = 270
	must_run = false
	max_slices_per_tick = 1
	use_job_should_run = true
	use_job_deadline_critical = true
	starvation_threshold = 2
	slice_budget_ms = 0.8
	policy = SusPolicyScript.AlwaysPolicy.new()
	facade = p_facade
	world_clock = p_world_clock
	generator = p_generator
	event_bus = p_event_bus
	if facade != null and facade.has_method("take_restored_event_progress"):
		var restored: PackedInt64Array = facade.take_restored_event_progress()
		if not restored.is_empty(): restore_event_progress(restored)


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	if facade == null or not facade.is_configured():
		return false
	# Whole-graph ACTIVE owns every domain day; the host drains military there.
	if generator != null and generator.has_method("runtime_graph_active") \
			and bool(generator.runtime_graph_active()):
		return false
	if not facade.terrain_ready():
		return false
	if ctx == null:
		return false
	var day := int(ctx.day_index)
	# Re-running the same day would double-submit D+1 intents.
	if day == _last_day:
		return false
	return bool(facade.should_run(day))


func is_deadline_critical(ctx: SusTickContext) -> bool:
	# Military intents for D+1 must be queued before the day commits, otherwise
	# the Country/Economy effective-day ordering slips by a day.
	return ctx != null and should_run(ctx)


func tick(ctx) -> Dictionary:
	if ctx == null:
		return {"done": true, "elapsed_ms": 0.0, "stage_name": "military_no_context"}
	if facade == null or not facade.is_configured():
		return {"done": true, "elapsed_ms": 0.0, "stage_name": "military_unavailable"}
	if generator != null and generator.has_method("runtime_graph_active") \
			and bool(generator.runtime_graph_active()):
		return {"done": true, "elapsed_ms": 0.0,
			"stage_name": "military_owned_by_runtime_graph",
			"path": "native_runtime_graph"}
	if not facade.should_run(int(ctx.day_index)):
		# Peace with no movement: zero slices (contract §5).
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0,
			"progress_ratio": 1.0, "stage_name": "military_idle",
			"path": "native_military_skip"}
	var started_us := Time.get_ticks_usec()
	var day := int(ctx.day_index)
	var result: Dictionary = facade.run_daily(day)
	_last_day = day
	_last_report = result.duplicate(false) if not result.is_empty() else {}
	var dispatch_started_us := Time.get_ticks_usec()
	var forwarded := forward_military_events()
	var dispatch_ms := float(Time.get_ticks_usec() - dispatch_started_us) / 1000.0
	return {
		"done": true,
		"work_done": int(result.get("armies_active", 0)) \
			+ int(result.get("engagements_active", 0)) * 4,
		"elapsed_ms": float(Time.get_ticks_usec() - started_us) / 1000.0,
		"progress_ratio": 1.0,
		"stage_name": "military_daily",
		"path": String(result.get("path", "native_military")),
		"military_day_ms": float(result.get("day_ms", 0.0)),
		"armies_active": int(result.get("armies_active", 0)),
		"armies_moving": int(result.get("armies_moving", 0)),
		"engagements_active": int(result.get("engagements_active", 0)),
		"wars_active": int(result.get("wars_active", 0)),
		"soldiers_total": int(result.get("soldiers_total", 0)),
		"intents_submitted": int(result.get("intents_submitted", 0)),
		"country_ops": int(result.get("country_ops", 0)),
		"economy_ops": int(result.get("economy_ops", 0)),
		"astar_expansions": int(result.get("astar_expansions", 0)),
		"convoys_due": int(result.get("convoys_due", 0)),
		"front_edges_touched": int(result.get("front_edges_touched", 0)),
		"events_forwarded": forwarded,
		"event_dispatch_ms": dispatch_ms,
	}


## Drain the native military event ring into GameplayEventBus so Trigger,
## narrative, music and the annual report see military facts on the same day.
## Returns the number of facts published.
func forward_military_events() -> int:
	if event_bus == null or facade == null or not facade.is_configured():
		return 0
	var published := 0
	while true:
		var events: Array = facade.poll_events(_event_cursor, EVENT_POLL_LIMIT)
		if events.is_empty():
			break
		var batch := _build_event_batch(events)
		if int(batch.get("count", 0)) > 0:
			event_bus.publish_events_batch(batch)
			published += int(batch.get("count", 0))
		# The native ring is monotone in id; an event without an id cannot
		# advance the cursor, so stop instead of spinning forever.
		var last_id := int((events[events.size() - 1] as Dictionary).get("id", 0))
		if last_id <= _event_cursor:
			break
		_event_cursor = last_id
	if published > 0:
		_events_forwarded += published
	return published


## Military events are already coalesced natively (per-type daily caps), so the
## forwarder only has to pack them into the bus's SoA batch layout. The bus
## stores one tick/phase/source per batch, hence the fixed type is not used:
## `type_scalar` applies only to `count == 1` publishes, and a batch carries a
## per-event `type` array.
func _build_event_batch(events: Array) -> Dictionary:
	var count := mini(events.size(), EVENT_FORWARD_BATCH * 8)
	var batch := {
		"count": count,
		"tick_scalar": _last_day,
		"phase_scalar": 0,
		"type_scalar": 0,
		"source_scalar": EVENT_SOURCE_MILITARY,
		"flags_scalar": 0,
		"payload_schema_scalar": 0,
		"cell_idx": PackedInt32Array(),
		"entity_id": PackedInt32Array(),
		"entity_handle": PackedInt64Array(),
		"value_i64": PackedInt64Array(),
		"payload_i0": PackedInt32Array(),
		"payload_i1": PackedInt32Array(),
		"payload_i2": PackedInt32Array(),
		"payload_i3": PackedInt32Array(),
		"type": PackedInt32Array(),
		"payload_schema": PackedInt32Array(),
		"event_day": PackedInt64Array(),
	}
	for index in range(count):
		var event: Dictionary = events[index]
		var event_type := clampi(int(event.get("type", 0)), EVENT_TYPE_MIN, EVENT_TYPE_MAX)
		var cell := int(event.get("cell", -1))
		batch.type.append(event_type)
		batch.payload_schema.append(int(event.get("payload_schema",
			PAYLOAD_SCHEMA_BASE + (event_type - EVENT_TYPE_MIN))))
		batch.cell_idx.append(cell)
		# entity_id doubles as the Trigger entity scope key; military facts are
		# scoped by their country (i0) when the fact has one, else by cell.
		batch.entity_id.append(int(event.get("i0", cell)))
		batch.entity_handle.append(int(event.get("i0", 0)))
		batch.value_i64.append(int(event.get("value", 0)))
		batch.payload_i0.append(int(event.get("i0", 0)))
		batch.payload_i1.append(int(event.get("i1", 0)))
		batch.payload_i2.append(int(event.get("i2", 0)))
		batch.payload_i3.append(int(event.get("i3", 0)))
		batch.event_day.append(int(event.get("day", _last_day)))
	return batch


func last_report() -> Dictionary:
	return _last_report.duplicate(true)


func last_day() -> int:
	return _last_day


func events_forwarded() -> int:
	return _events_forwarded


func reset_progress() -> void:
	super.reset_progress()
	_last_report.clear()
	_last_day = -1
	_event_cursor = 0
	_events_forwarded = 0


# This is the forwarding cursor, not simulation state or derived manpower.
func capture_event_progress() -> PackedInt64Array:
	return PackedInt64Array([_event_cursor, _last_day, _events_forwarded])

func restore_event_progress(values: PackedInt64Array) -> bool:
	if values.size() != 3 or values[0] < 0 or values[1] < -1 or values[2] < 0:
		return false
	_event_cursor = values[0]
	_last_day = values[1]
	_events_forwarded = values[2]
	return true
