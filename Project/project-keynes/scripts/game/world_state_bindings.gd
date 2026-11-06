extends RefCounted

## The only save composition boundary that knows the scene/legacy facades.
## Resolve at each invocation: restoring Country can replace Economy facades.
## Adapters receive neither a host nor a generator and retain no world references.
static func for_module(source: Dictionary, id: String) -> Dictionary:
	var host = source.get("host")
	var generator = source.get("generator")
	match id:
		"dynamic_world":
			var ext = generator.get_data_core_world_ext() if generator != null else null
			return {"world": source.get("world"), "session": source.session,
				"restore_base_moisture": func():
					ext.refresh_slots_from_map_keys(PackedStringArray(["cell_base_moisture"])),
				"base_moisture": func():
					return ext.snapshot_f32(ext.component_id("cell_base_moisture")) if ext != null else PackedFloat32Array()}
		"environment":
			return {"capture_environment": _method(generator, "export_environment_runtime_state"),
				"restore_environment": _method(generator, "restore_environment_runtime_state"),
				"weather_result": func(): return int(generator._native_daily_last_result.get("rc", -1)),
				"restore_weather_result": func(rc: int): generator._native_daily_last_result["rc"] = rc}
		"world_clock":
			return {"clock": source.get("clock"), "clock_restored": source.clock_restored,
				"saved_paused": source.saved_paused, "saved_speed": source.saved_speed}
		"simulation_runtime":
			return {"clock": source.get("clock"),
				"runtime_report": _method(generator, "get_runtime_thread_report"),
				"restore_bundle": _method(generator, "restore_runtime_bundle"),
				"native_runtime_bundle": source.get("native_runtime_bundle", PackedByteArray()),
				"saved_paused": source.saved_paused, "saved_speed": source.saved_speed}
		"pkcn":
			return {"country": _facade(generator, "country"),
				"native_country_pkcn": source.get("native_country_pkcn", PackedByteArray()),
				"prepare_economy": _method(generator, "prepare_economy_save_restore_runtime")}
		"pkmi":
			return {"military": _facade(generator, "military"), "country": _facade(generator, "country"),
				"military_progress": generator.get_military_daily_job() if generator != null else null}
		"pkai":
			return {"country_ai": _facade(generator, "country_ai"), "country": _facade(generator, "country")}
		"ecp2":
			return {"economy": _facade(generator, "economy"),
				"native_economy_ecp2": source.get("native_economy_ecp2", PackedByteArray()),
				"refresh_buildings": _method(host, "refresh_building_visual_catalog")}
		"pkcm", "pkgp":
			return {"modifier": _facade(generator, "modifier")}
		"pktr":
			return {"trigger": _facade(generator, "trigger")}
		"pkef":
			return {"effect": _facade(generator, "effect")}
		"pkid":
			return {"ideology": _facade(generator, "ideology"),
				"ideology_report": _method(generator, "get_ideology_report")}
		"pkfg":
			return {"map": host.current_map() if host != null else null,
				"fog_enabled": host.is_fog_of_war_enabled() if host != null else false,
				"player_slot": host.player_country_slot() if host != null else -1,
				"intel": host.building_visual_intel_cache() if host != null else null,
				"type_count": host.building_visual_type_count() if host != null else -1,
				"refresh_vision": _method(host, "refresh_country_visuals")}
		"journal":
			return {"event_bus": source.get("event_bus")}
		"pkar":
			return {"annual": generator.get_data_core_world_ext() if generator != null else null}
		"pknr":
			return {"player": source.get("player")}
		"player_session":
			return {"session": source.session, "set_session": source.set_session,
				"player": source.get("player"), "viewport": source.get("viewport"),
				"set_pending_view": source.set_pending_view}
	return {}


static func _method(target, name: StringName) -> Callable:
	return Callable(target, name) if target != null and target.has_method(name) else Callable()


static func _facade(generator, domain: String):
	var getter := _method(generator, StringName("get_%s_facade" % domain))
	return getter.call() if getter.is_valid() else null
