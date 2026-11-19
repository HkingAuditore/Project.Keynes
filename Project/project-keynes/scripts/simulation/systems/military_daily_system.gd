extends DCSystem
class_name MilitaryDailySystem

## Compatibility scheduler for worlds without whole-day authority.
## Native Military advances the state and forwards its own facts.

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const MilitaryFacadeScript = preload("res://scripts/military/military_facade.gd")

var facade = null
var _last_report: Dictionary = {}
var _last_day: int = -1


func _init(p_facade, p_generator = null) -> void:
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
	generator = p_generator


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	if facade == null or not facade.is_configured():
		return false
	# The whole-day executor owns Military when it runs the full graph.
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
		"events_forwarded": int(result.get("events_forwarded", 0)),
	}


func last_report() -> Dictionary:
	return _last_report.duplicate(true)


func last_day() -> int:
	return _last_day


func events_forwarded() -> int:
	var progress: PackedInt64Array = facade.capture_pending_event_progress()
	return progress[2] if progress.size() == 3 else 0


func reset_progress() -> void:
	super.reset_progress()
	_last_report.clear()
	_last_day = -1
