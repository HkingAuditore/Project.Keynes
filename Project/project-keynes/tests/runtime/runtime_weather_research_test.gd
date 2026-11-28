extends "res://tests/runtime/runtime_world_lifecycle_test.gd"

const FROST := 4
const WEATHER_OBSERVED := 11


func _finish() -> void:
	var catalog := EconomyCatalogScript.compile_native_catalog()
	_expect("weather research catalog compiles", catalog.get("ok", false))
	catalog.erase("ok")
	for inline_mode in [false, true]:
		await _weather_observation(catalog, inline_mode)
	print("runtime weather research: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _configuration(inline_mode: bool) -> Dictionary:
	var config := super._configuration(inline_mode)
	config.authoritative_domain_mask = 0xA0F # Input, Climate, Country, Trigger, Events, Commit.
	return config


func _capture_input(ext: Object, day: int) -> void:
	var generation := int(ext.get_runtime_thread_report().get("simulation_environment_generation", 0)) + 1
	var neighbors := PackedInt32Array()
	neighbors.resize(24)
	neighbors.fill(-1)
	_expect("weather input seals", ext.capture_runtime_inputs({
		"generation": generation, "day": day,
		"terrain": PackedByteArray([1, 1, 1, 1]), "landform": PackedByteArray([0, 0, 0, 0]),
		"climate_map_width": 4, "climate_map_height": 1, "climate_catalog_hash": 7,
		"cell_temp": PackedFloat32Array([0.02, 0.04, 0.80, 0.02]),
		"cell_moisture": PackedFloat32Array([0.5, 0.5, 0.5, 0.5]),
		"has_river": PackedByteArray([0, 0, 0, 0]), "neighbor_indices": neighbors,
	}).get("ok", false))


func _weather_observation(catalog: Dictionary, inline_mode: bool) -> void:
	var ext := DCWorldExt.new()
	ext.create_entities(4)
	_expect("weather Country configures", ext.configure_country(catalog,
		{"country_runtime_mode": "ACTIVE"}, 4, 777).get("ok", false))
	_expect("cold, warm and unowned land bootstrap", ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.cold", "country.warm"]),
		"country_names": PackedStringArray(["Cold", "Warm"]),
		"country_cash": PackedInt64Array([0, 0]), "territory_offsets": PackedInt32Array([0, 2, 3]),
		"territory_cells": PackedInt32Array([0, 1, 2]),
	}, PackedByteArray([0, 0, 0, 0])).get("ok", false))
	var cold := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var warm := int(ext.get_country_cell_summary(2).get("country_handle", 0))
	_expect("cold and warm countries have distinct handles", cold > 0 and warm > 0 and cold != warm)
	_expect("Country catalog captures", ext.capture_country_pod_catalog().get("ok", false))
	_expect("Country snapshot captures", ext.capture_country_runtime_snapshot().get("ok", false))
	var triggers: Dictionary = TriggerCatalog.load_default().compile_native_catalog()
	var configured := ext.configure_triggers(triggers)
	_expect("production weather Trigger configures in the executor",
		configured.get("ok", false) and configured.get("pod_shadow_ok", false))
	_expect("all authored weather rules produce matching observations and discovery intents",
		ext.runtime_events_authority_self_test())
	_capture_input(ext, 0)
	_expect("ACTIVE weather executor starts", ext.start_runtime_worker(_configuration(inline_mode)).get("ok", false))
	await _day(ext, inline_mode, 1)
	var saved := _capture_bundle(ext, 81)
	_expect("save at the observation boundary retains the pending weather fact",
		saved.get("ready", false) and int(saved.get("pending_command_count", -1)) == 1)
	await _day(ext, inline_mode, 2)

	var batch: Dictionary = ext.replay_gameplay_events({
		"start_tick": 1, "end_tick": 1, "type": WEATHER_OBSERVED,
	})
	_expect("only the cold country's first qualifying day emits a weather observation",
		int(batch.get("count", 0)) == 1
		and batch.get("entity_handle") == PackedInt64Array([cold])
		and batch.get("cell_idx") == PackedInt32Array([0])
		and batch.get("payload_i0") == PackedInt32Array([FROST])
		and batch.get("payload_i1") == PackedInt32Array([2]))

	await _day(ext, inline_mode, 3)
	var intent := ext.poll_trigger_worker_intent()
	var signal_ids: PackedStringArray = catalog.research_signal_ids
	var payload: PackedInt64Array = intent.get("payload", PackedInt64Array())
	_expect("the production Trigger resolves frost to the cold country's discovery command",
		intent.get("available", false) and int(intent.get("target_handle", 0)) == cold
		and int(intent.get("opcode", 0)) == 14
		and not payload.is_empty() and (payload[0] >> 32) == signal_ids.find("weather.frost")
		and (payload[0] & 0xffffffff) == 0)
	_expect("the warm country receives no weather intent",
		not ext.poll_trigger_worker_intent().get("available", true))
	await _stop(ext)
