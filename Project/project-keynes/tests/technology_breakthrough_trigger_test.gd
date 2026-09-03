extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")

var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("technology_breakthrough_trigger_test: SKIP")
		quit(0)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_require(bool(compiled.get("ok", false)), "economy catalog compiles")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_require(effect_catalog != null, "effect domain catalog builds")
	var gis_index := (compiled.technology_ids as PackedStringArray).find(
		"tech.geographic_information_systems")
	var gis_recipe_id := String((compiled.technology_effect_recipe_ids as PackedStringArray)[gis_index])
	var gis_effect_definition: Resource = null
	for definition_value in effect_catalog.definitions:
		var definition: Resource = definition_value
		if String(definition.key) == gis_recipe_id:
			gis_effect_definition = definition
			break
	var has_adopted := false
	var has_modifier := false
	if gis_effect_definition != null:
		for command_value in gis_effect_definition.commands:
			var command: Resource = command_value
			has_adopted = has_adopted or String(command.command_key) == "technology.adopted"
			has_modifier = has_modifier or String(command.command_key) == "technology.modifier"
	_require(gis_effect_definition != null and has_adopted,
		"technology emits adopted command")
	_require(bool(ext.configure_effects(
		effect_catalog.compile_native_catalog()).get("ok", false)),
		"effect runtime configures")
	var trigger_catalog: Resource = TriggerCatalogScript.load_default()
	var trigger_ir: Dictionary = trigger_catalog.compile_native_catalog()
	_require(bool(trigger_ir.get("ok", false)), "trigger catalog compiles")
	_require(int(trigger_ir.trigger_keys.size()) >= 14,
		"default catalog includes breakthrough definitions")
	var compiled_country_commands := {}
	var development_programs := 0
	for definition_value in effect_catalog.definitions:
		var compiled_definition: Resource = definition_value
		if String(compiled_definition.key).begins_with("trigger.country.development."):
			development_programs += 1
		for command_value in compiled_definition.commands:
			var compiled_command: Resource = command_value
			compiled_country_commands["%s|%s" % [
				String(compiled_command.command_key),
				String(compiled_command.definition_key)]] = true
	var missing_country_commands: PackedStringArray = PackedStringArray()
	var country_command_count := 0
	var development_discover_count := 0
	for effect_index in range((trigger_ir.effect_command_keys as PackedStringArray).size()):
		if int(trigger_ir.effect_actions[effect_index]) != TriggerCatalogScript.ACTION_COUNTRY_COMMAND:
			continue
		country_command_count += 1
		var command_key := String(trigger_ir.effect_command_keys[effect_index])
		var definition_key := String(trigger_ir.effect_definition_keys[effect_index])
		if command_key == "development.discover":
			development_discover_count += 1
		var pair := "%s|%s" % [command_key, definition_key]
		if not compiled_country_commands.has(pair):
			missing_country_commands.append(pair)
	_require(development_discover_count > 0 and development_programs == development_discover_count,
		"development.discover commands are compiled into Effect catalog")
	_require(missing_country_commands.is_empty(),
		"every COUNTRY_COMMAND trigger effect has a compiled command: %s" %
			str(missing_country_commands))
	_require(country_command_count > development_discover_count,
		"country trigger commands include breakthrough/contact/weather plus development")
	for trigger_key in ["technology.practice.maritime_operations",
			"technology.practice.watershed_management",
			"technology.practice.forest_management",
			"technology.practice.chemical_process_control",
			"technology.practice.energy_control",
			"technology.practice.hide_working",
			"technology.contact.bast_fiber"]:
		_require((trigger_ir.trigger_keys as PackedStringArray).has(trigger_key),
			"new practice trigger compiles: %s" % trigger_key)
	_require(bool(ext.configure_triggers(trigger_ir).get("ok", false)),
		"trigger runtime configures")

	var facade := CountryFacadeScript.new()
	var profile: Resource = load("res://data/country/default_country.tres")
	_require(bool(facade.configure(ext, 1, 17, profile, compiled).get("ok", false)),
		"country runtime configures")
	_require(bool(facade.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.practice"]),
		"country_names": PackedStringArray(["实践国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}).get("ok", false)), "country runtime bootstraps")
	var handle := int(facade.cell_summary(0).country_handle)
	_require(handle != 0, "country handle exists")

	var practice_event := {
		"event_ids": PackedInt64Array([1]),
		"source_ids": PackedInt32Array([1]),
		"days": PackedInt64Array([0]),
		"event_types": PackedInt32Array([14]),
		"payload_schemas": PackedInt32Array([7]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([365]),
		"payload_i0": PackedInt64Array([0]),
		"payload_i1": PackedInt64Array([1]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	}
	_require(int(ext.submit_trigger_events(practice_event).get("accepted", 0)) == 1,
		"practice event accepted")
	_require(int(ext.submit_trigger_events(practice_event).get("deduplicated", 0)) == 1,
		"duplicate event is ignored")
	_require(bool(ext.run_trigger_daily(0).get("ok", false)),
		"trigger threshold evaluates")
	var handoff: Dictionary = ext.handoff_trigger_effects(32)
	_require(int(handoff.get("handed_off", 0)) == 1,
		"breakthrough hands off to EffectRuntime: %s" % str(handoff))
	var dispatch: Dictionary = ext.dispatch_effect_native_country()
	_require(int(dispatch.get("submitted_transactions", 0)) == 1,
		"EffectRuntime submits one Country transaction: %s" % str(dispatch))
	var country_commit: Dictionary = ext.run_country_slice({"day_index": 1})
	_require(bool(country_commit.get("ok", false)) and
		bool(country_commit.get("done", false)), "Country safe boundary commits")
	var ack: Dictionary = ext.ack_effect_native_country()
	_require(int(ack.get("acknowledged", 0)) == 1,
		"Country domain ACK completes: %s" % str(ack))

	var evidence: Dictionary = facade.research_signal_snapshot(handle)
	var catalog_signal_ids: PackedStringArray = compiled.get(
		"research_signal_ids", PackedStringArray())
	var expected_signal := catalog_signal_ids.find("breakthrough.maize_selection")
	var signal_ids: PackedInt32Array = evidence.get("signal_ids", PackedInt32Array())
	var signal_index := signal_ids.find(expected_signal)
	_require(signal_index >= 0, "maize-selection breakthrough discovered")
	if signal_index >= 0:
		var first_cells: PackedInt32Array = evidence.get(
			"first_cells", PackedInt32Array())
		var counts: PackedInt32Array = evidence.get("counts", PackedInt32Array())
		_require(int(first_cells[signal_index]) == 0 and int(counts[signal_index]) == 1,
			"first practice cell and provenance count persist")

	var contact_event := {
		"event_ids": PackedInt64Array([2]),
		"source_ids": PackedInt32Array([1]),
		"days": PackedInt64Array([2]),
		"event_types": PackedInt32Array([16]),
		"payload_schemas": PackedInt32Array([7]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([1]),
		"payload_i0": PackedInt64Array([0]),
		"payload_i1": PackedInt64Array([1]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	}
	_require(int(ext.submit_trigger_events(contact_event).get("accepted", 0)) == 1,
		"actual-import contact event accepted")
	var contact_run: Dictionary = ext.run_trigger_daily(2)
	_require(bool(contact_run.get("ok", false)),
		"contact threshold evaluates: %s" % str(contact_run))
	var contact_handoff: Dictionary = ext.handoff_trigger_effects(32)
	_require(int(contact_handoff.get("handed_off", 0)) == 1,
		"contact discovery hands off to EffectRuntime: run=%s handoff=%s" % [
			str(contact_run), str(contact_handoff)])
	_require(int(ext.dispatch_effect_native_country().get(
		"submitted_transactions", 0)) == 1,
		"contact effect submits one Country transaction")
	_require(bool(ext.run_country_slice({"day_index": 3}).get("ok", false)),
		"contact signal commits at the Country boundary")
	_require(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 1,
		"contact Country ACK completes")
	var contact_evidence: Dictionary = facade.research_signal_snapshot(handle)
	var contact_signal := catalog_signal_ids.find("contact.maize")
	var contact_signal_ids: PackedInt32Array = contact_evidence.get(
		"signal_ids", PackedInt32Array())
	_require(contact_signal_ids.has(contact_signal),
		"maize contact is discovered only through the contact event path")

	var maritime_event := {
		"event_ids": PackedInt64Array([3]),
		"source_ids": PackedInt32Array([1]),
		"days": PackedInt64Array([4]),
		"event_types": PackedInt32Array([14]),
		"payload_schemas": PackedInt32Array([7]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([360]),
		"payload_i0": PackedInt64Array([23]),
		"payload_i1": PackedInt64Array([1]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	}
	_require(int(ext.submit_trigger_events(maritime_event).get("accepted", 0)) == 1,
		"maritime practice event accepted")
	_require(bool(ext.run_trigger_daily(4).get("ok", false)),
		"maritime practice threshold evaluates")
	_require(int(ext.handoff_trigger_effects(32).get("handed_off", 0)) == 1,
		"maritime breakthrough hands off to EffectRuntime")
	_require(int(ext.dispatch_effect_native_country().get(
		"submitted_transactions", 0)) == 1,
		"maritime breakthrough submits a Country transaction")
	_require(bool(ext.run_country_slice({"day_index": 5}).get("ok", false)),
		"maritime breakthrough commits at the Country boundary")
	_require(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 1,
		"maritime breakthrough Country ACK completes")
	var final_evidence: Dictionary = facade.research_signal_snapshot(handle)
	var maritime_signal := catalog_signal_ids.find("breakthrough.maritime_operations")
	_require((final_evidence.get("signal_ids", PackedInt32Array()) as PackedInt32Array).has(
		maritime_signal), "maritime operations breakthrough is discoverable")

	var hide_event := {
		"event_ids": PackedInt64Array([4]),
		"source_ids": PackedInt32Array([1]),
		"days": PackedInt64Array([6]),
		"event_types": PackedInt32Array([14]),
		"payload_schemas": PackedInt32Array([7]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([1]),
		"payload_i0": PackedInt64Array([28]),
		"payload_i1": PackedInt64Array([1]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	}
	_require(int(ext.submit_trigger_events(hide_event).get("accepted", 0)) == 1,
		"hide-working practice event accepted")
	_require(bool(ext.run_trigger_daily(6).get("ok", false)),
		"hide-working threshold evaluates")
	_require(int(ext.handoff_trigger_effects(32).get("handed_off", 0)) == 1,
		"hide-working breakthrough hands off")
	_require(int(ext.dispatch_effect_native_country().get(
		"submitted_transactions", 0)) == 1,
		"hide-working breakthrough submits a Country transaction")
	_require(bool(ext.run_country_slice({"day_index": 7}).get("ok", false)),
		"hide-working breakthrough commits")
	_require(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 1,
		"hide-working breakthrough ACK completes")

	var bast_contact_event := {
		"event_ids": PackedInt64Array([5]),
		"source_ids": PackedInt32Array([1]),
		"days": PackedInt64Array([8]),
		"event_types": PackedInt32Array([16]),
		"payload_schemas": PackedInt32Array([7]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([1]),
		"payload_i0": PackedInt64Array([10]),
		"payload_i1": PackedInt64Array([1]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	}
	_require(int(ext.submit_trigger_events(bast_contact_event).get("accepted", 0)) == 1,
		"bast-fiber contact event accepted")
	_require(bool(ext.run_trigger_daily(8).get("ok", false)),
		"bast-fiber contact threshold evaluates")
	_require(int(ext.handoff_trigger_effects(32).get("handed_off", 0)) == 1,
		"bast-fiber contact hands off")
	_require(int(ext.dispatch_effect_native_country().get(
		"submitted_transactions", 0)) == 1,
		"bast-fiber contact submits a Country transaction")
	_require(bool(ext.run_country_slice({"day_index": 9}).get("ok", false)),
		"bast-fiber contact commits")
	_require(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 1,
		"bast-fiber contact ACK completes")
	var material_evidence: Dictionary = facade.research_signal_snapshot(handle)
	var material_signal_ids: PackedInt32Array = material_evidence.get(
		"signal_ids", PackedInt32Array())
	for material_signal_id in ["breakthrough.hide_working", "contact.bast_fiber"]:
		_require(material_signal_ids.has(catalog_signal_ids.find(material_signal_id)),
			"material practice evidence discovered: %s" % material_signal_id)

	var next_event_id := 10
	for weather_rule in range(7):
		var observations := 3 if weather_rule == 6 else 1
		for observation in range(observations):
			var weather_day := 10 + weather_rule * 3 + observation
			var weather_event := {
				"event_ids": PackedInt64Array([next_event_id]),
				"source_ids": PackedInt32Array([1 if weather_rule == 6 else 2]),
				"days": PackedInt64Array([weather_day]),
				"event_types": PackedInt32Array([11]),
				"payload_schemas": PackedInt32Array([9]),
				"entity_handles": PackedInt64Array([handle]),
				"group_handles": PackedInt64Array([0]),
				"values": PackedInt64Array([1 if weather_rule == 6 else 65536]),
				"payload_i0": PackedInt64Array([weather_rule]),
				"payload_i1": PackedInt64Array([1]),
				"payload_i2": PackedInt64Array([0]),
				"payload_i3": PackedInt64Array([1]),
			}
			next_event_id += 1
			_require(int(ext.submit_trigger_events(weather_event).get("accepted", 0)) == 1,
				"weather rule %d observation %d accepted" % [weather_rule, observation])
			_require(bool(ext.run_trigger_daily(weather_day).get("ok", false)),
				"weather rule %d observation %d evaluates" % [weather_rule, observation])
			if observation + 1 < observations:
				_require(int(ext.handoff_trigger_effects(32).get("handed_off", 0)) == 0,
					"weather rule %d remains below threshold after observation %d" % [
						weather_rule, observation])
		_require(int(ext.handoff_trigger_effects(32).get("handed_off", 0)) == 1,
			"weather rule %d hands off" % weather_rule)
		_require(int(ext.dispatch_effect_native_country().get(
			"submitted_transactions", 0)) == 1,
			"weather rule %d submits Country command" % weather_rule)
		_require(bool(ext.run_country_slice({"day_index": 40 + weather_rule}).get(
			"ok", false)), "weather rule %d commits" % weather_rule)
		_require(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 1,
			"weather rule %d ACK completes" % weather_rule)
	var weather_evidence: Dictionary = facade.research_signal_snapshot(handle)
	var weather_signal_ids: PackedInt32Array = weather_evidence.get(
		"signal_ids", PackedInt32Array())
	for weather_signal_id in ["weather.typhoon", "weather.major_flood", "weather.drought",
			"weather.monsoon", "weather.frost", "weather.storm_surge",
			"weather.repeated_crop_failure"]:
		_require(weather_signal_ids.has(catalog_signal_ids.find(weather_signal_id)),
			"permanent weather evidence discovered: %s" % weather_signal_id)

	print("technology_breakthrough_trigger_test: %s" %
		("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _require(condition: bool, label: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[FAIL] %s" % label)
