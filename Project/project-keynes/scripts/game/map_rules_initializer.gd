extends "res://scripts/simulation/generator_context.gd"

const LoadingCatalogContextScript = preload("res://scripts/game/loading_catalog_context.gd")

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


func apply_runtime_modifier_snapshot(after_generation: int) -> Dictionary:
	return _forward_runtime_snapshot_apply("apply_runtime_modifier_snapshot", after_generation)


func _forward_runtime_snapshot_apply(method: StringName, after_generation: int) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {"ok": false, "code": "runtime_worker_api_missing"}
	return _generator._data_core_world_ext.call(method, after_generation)


func _setup_effect_runtime(cp_sched) -> void:
	# EffectRuntime is independent from Country/Economy. Configure and register
	# it before economy bootstrap, whose valid early returns must not starve it.
	_generator._effect_facade = null
	_generator._effect_daily_job = null
	_generator._gameplay_effect_job = null
	if _generator._data_core_world_ext != null:
		var effect_facade = _generator.EffectFacadeScript.new()
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("effect_catalog")
		var catalog_context = LoadingCatalogContextScript.for_generator(_generator)
		var effect_catalog := LoadingCatalogCache.effect_catalog()
		var effect_columns := LoadingCatalogCache.effect_native_columns()
		if effect_catalog == null:
			effect_catalog = await _generator.EffectDomainCatalogScript.build_cooperative(catalog_context)
		if catalog_context.canceled:
			return
		await _generator._yield_generation_frame()
		_generator._loading_profile_step("effect_configure")
		if effect_catalog == null:
			push_error("[effect] domain catalog build failed")
		else:
			if effect_columns.is_empty():
				effect_columns = await effect_catalog.compile_native_catalog_cooperative(catalog_context)
			if catalog_context.canceled:
				return
			await _generator._yield_generation_frame()
			if catalog_context.canceled:
				return
			_generator._loading_profile_step("effect_native_configure")
			var effect_configured: Dictionary = effect_facade.configure(
				_generator._data_core_world_ext, _generator._world_clock_ref, effect_catalog, effect_columns)
			if bool(effect_configured.get("ok", false)):
				# `ok` 只代表主线程 EffectRuntime 吃下了目录。worker 侧还有第二份
				# POD 目录：编译失败时 `_effect_pod_catalog` 保持空，Effect 阶段就
				# 在 `effect_stage_enabled == false` 那一行无条件放弃、不设 stall 位、
				# 不写日志，于是整局只表现为「日历推不动」。这里必须响。
				if not bool(effect_configured.get("effect_pod_ready", true)):
					push_error(
						"[effect] native POD catalog not ready (%s) — worker Effect stage will park every day" % [
							String(effect_configured.get(
								"effect_pod_fallback_reason", "unknown"))])
				_generator._effect_facade = effect_facade
				_generator._effect_daily_job = _generator.EffectRuntimeSystemScript.new(_generator._effect_facade)
				_generator._sus.configure_job_from_profile(
					_generator._effect_daily_job, cp_sched, false, &"effect_runtime", 1)
				_generator._runtime_register_system(_generator._effect_daily_job)
				_generator._gameplay_effect_job = _generator.GameplayEffectSystemScript.new(_generator._effect_facade)
				_generator._sus.configure_job_from_profile(
					_generator._gameplay_effect_job, cp_sched, false, &"gameplay_effect", 1)
				_generator._runtime_register_system(_generator._gameplay_effect_job)
			else:
				push_error("[effect] configure failed: %s" % String(
					effect_configured.get("reason", "unknown")))

func _release_loading_catalog_context() -> void:
	LoadingCatalogContextScript.release_generator(_generator)
