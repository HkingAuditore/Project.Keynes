extends "res://scripts/simulation/generator_context.gd"

const ModifierDailySystemScript = preload("res://scripts/simulation/systems/modifier_daily_system.gd")
const TriggerDailySystemScript = preload("res://scripts/simulation/systems/trigger_daily_system.gd")
const IdeologyRuntimeSystemScript = preload("res://scripts/simulation/systems/ideology_runtime_system.gd")
const CountryDailySystemScript = preload("res://scripts/simulation/systems/country_daily_system.gd")
const EconomyDailySystemScript = preload("res://scripts/simulation/systems/economy_daily_system.gd")

## 第 5 批：规则目录配置、绑定与运行时规则入口。可变状态仍由 MapGenerator 持有。

func _register_country_economy_systems(scheduler_profile) -> Dictionary:
	if _generator._sus == null:
		return {"ok": false, "reason": "runtime_scheduler_unavailable"}
	if _generator._modifier_facade == null or _generator._country_facade == null or _generator._economy_facade == null:
		return {"ok": false, "reason": "country_economy_runtime_unavailable"}
	if _generator._modifier_daily_job != null or _generator._country_daily_job != null or _generator._economy_daily_job != null:
		return {"ok": false, "reason": "country_economy_systems_already_registered"}
	if _generator._effect_facade != null and _generator._effect_facade.is_configured():
		_generator._effect_facade.register_domain_adapters(_generator._modifier_facade, _generator._country_facade,
			_generator._economy_facade)
	_generator._modifier_daily_job = ModifierDailySystemScript.new(_generator._modifier_facade)
	_generator._sus.configure_job_from_profile(
		_generator._modifier_daily_job, scheduler_profile, false, &"modifier_daily", 1)
	_generator._runtime_register_system(_generator._modifier_daily_job)
	if _generator._trigger_facade != null:
		_generator._trigger_facade.register_domain_effect_adapter(11, 2,
			&"family.free_building",
			Callable(_generator._economy_facade, "queue_family_trigger_reward"))
		_generator._trigger_facade.register_domain_effect_adapter(11, 2,
			&"family.population_reward",
			Callable(_generator._economy_facade, "queue_family_trigger_reward"))
		_generator._trigger_daily_job = TriggerDailySystemScript.new(_generator._trigger_facade)
		_generator._sus.configure_job_from_profile(
			_generator._trigger_daily_job, scheduler_profile, false, &"trigger_runtime", 1)
		_generator._runtime_register_system(_generator._trigger_daily_job)
	if _generator._ideology_facade != null and _generator._ideology_facade.is_configured():
		_generator._ideology_daily_job = IdeologyRuntimeSystemScript.new(
			_generator._ideology_facade, _generator._world_clock_ref)
		_generator._sus.configure_job_from_profile(
			_generator._ideology_daily_job, scheduler_profile, false, &"ideology_runtime", 1)
		_generator._runtime_register_system(_generator._ideology_daily_job)
	_generator._country_daily_job = CountryDailySystemScript.new(
		_generator._country_facade, _generator._world_clock_ref, _generator)
	_generator._sus.configure_job_from_profile(
		_generator._country_daily_job, scheduler_profile, false, &"country_daily", 1)
	_generator._runtime_register_system(_generator._country_daily_job)
	_generator._economy_daily_job = EconomyDailySystemScript.new(_generator._economy_facade, _generator._world_clock_ref, _generator)
	_generator._sus.configure_job_from_profile(
		_generator._economy_daily_job, scheduler_profile, false, &"economy_daily", 1)
	_generator._runtime_register_system(_generator._economy_daily_job)
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_signal("simulation_backpressure_pulse"):
		var continuation_cb := Callable(_generator, "_continue_economy_inflight")
		if not _generator._world_clock_ref.simulation_backpressure_pulse.is_connected(continuation_cb):
			_generator._world_clock_ref.simulation_backpressure_pulse.connect(continuation_cb)
	return {"ok": true}


## Military catalog compile + configure + terrain + AI arming.
##
## Order matters: it runs after Country and Economy catalogs are configured
## (dense good/profession/technology ids and the territory mirror). New games
## bootstrap first; load preparation configures before PKMI/ECP2 restore,
## and before the daily system registration so the first simulation day already
## has a usable terrain layer.
##
## Every native call is `has_method` guarded: an older DLL has no military API,
## in which case this returns `ok=false, reason=military_api_unavailable` and the
## rest of the world keeps running unchanged.

func get_modifier_facade():
	return _generator._modifier_facade


func get_trigger_facade():
	return _generator._trigger_facade

func get_effect_facade():
	return _generator._effect_facade


func get_ideology_facade():
	return _generator._ideology_facade


func get_trigger_report() -> Dictionary:
	return _generator._trigger_facade.report() if _generator._trigger_facade != null else {"configured": false}

func get_effect_report() -> Dictionary:
	return _generator._effect_facade.report() if _generator._effect_facade != null else {"configured": false}


func get_ideology_report() -> Dictionary:
	return _generator._ideology_facade.report() if _generator._ideology_facade != null else {"configured": false}


func get_modifier_report() -> Dictionary:
	return _generator._modifier_facade.report() if _generator._modifier_facade != null else {"configured": false}


func apply_runtime_trigger_snapshot(after_generation: int) -> Dictionary:
	return _forward_runtime_snapshot_apply("apply_runtime_trigger_snapshot", after_generation)


func apply_runtime_ideology_snapshot(after_generation: int) -> Dictionary:
	return _forward_runtime_snapshot_apply("apply_runtime_ideology_snapshot", after_generation)


## P1-A: under IDEOLOGY worker authority the main-thread daily job is suppressed,
## so the host pumps the sliced instance refresh itself. One call = at most one
## country budget; `done == false` means "call again".

func step_ideology_instance_refresh(day_index: int) -> Dictionary:
	if _generator._ideology_facade == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._ideology_facade.step_instance_refresh(day_index)


## Plan §9.3 in worker mode: the DERIVED half of the same pump.
##
## `run_ideology_daily` is suppressed when the worker owns IDEOLOGY and it is the only
## production caller of `step_derived_rebuild`, so without this the derived cell layer was
## never stepped and produced nothing at all (measured: `rebuild_visits` delta 0 over 12
## suppressed days with a live card). This wrapper is what makes the host's pump reachable:
## the host guards on `has_method("step_ideology_derived_rebuild")`, and until this existed
## that guard was FALSE on `MapGenerator`, so the pump on the tick path was dead code.
##
## One call steps one slice. `done == false` means "call again"; `code` of
## `economy_day_inflight` means the boundary was busy and the call should be retried on a
## later tick -- normal contention, not a failure.

func step_ideology_derived_rebuild(day_index: int) -> Dictionary:
	if _generator._ideology_facade == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._ideology_facade.step_derived_rebuild(day_index)


func apply_runtime_modifier_snapshot(after_generation: int) -> Dictionary:
	return _forward_runtime_snapshot_apply("apply_runtime_modifier_snapshot", after_generation)


func apply_runtime_effect_snapshot(after_generation: int) -> Dictionary:
	return _forward_runtime_snapshot_apply("apply_runtime_effect_snapshot", after_generation)


func _forward_runtime_snapshot_apply(method: StringName, after_generation: int) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.call(method, after_generation)
