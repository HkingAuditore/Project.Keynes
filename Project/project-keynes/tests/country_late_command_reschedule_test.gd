extends SceneTree

# A player stamps effective_day from the UI clock, which trails the ACTIVE
# Country worker clock at high speed. Such a command must be rescheduled onto
# the day the worker is planning, never dropped with
# country_command_day_already_committed — that silently discarded every
# research/tax intent and made the technology queue impossible to fill.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("country late command reschedule: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _register_environment(ext: Object) -> void:
	var scalar := PackedFloat32Array([0.5])
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		ext.write_f32_range(ext.register_component(slot_name, 0, 1, false), 0, scalar)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		ext.write_u8_range(ext.register_component(slot_name, 2, 1, false), 0,
			PackedByteArray([0]))


# The worker consumes one environment per day. Publish for the day it is
# actually waiting on (committed + 1): a counter that drifts ahead of the
# worker gets rejected as runtime_input_before_committed_day, and the worker
# then parks on the input barrier instead of advancing.
func _publish_day_input(ext: Object, generation: int) -> void:
	var next_day := int(ext.get_runtime_thread_report().get(
		"simulation_committed_day", 0)) + 1
	ext.capture_runtime_inputs({
		"generation": generation,
		"day": next_day,
		"terrain": PackedByteArray([1]),
		"neighbor_offsets": PackedInt32Array([0, 0]),
		"neighbor_indices": PackedInt32Array(),
		"cell_temp": PackedFloat32Array([15.0]),
		"cell_moisture": PackedFloat32Array([0.5]),
		"cell_plant_available_water": PackedFloat32Array([0.5]),
	})


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt available", false)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	_register_environment(ext)
	var country = CountryFacadeScript.new()
	country.configure(ext, 1, 9043,
		load("res://data/country/default_country.tres"), compiled)
	var tech_ids: PackedStringArray = compiled.technology_ids
	country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.late_command"]),
		"country_names": PackedStringArray(["LateCommand"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 3]),
		"technology_indices": PackedInt32Array([
			tech_ids.find("tech.gathering"),
			tech_ids.find("tech.maize_identification"),
			tech_ids.find("tech.early_knowledge_institution")]),
	})
	var handle := int(country.cell_summary(0).country_handle)
	country.discover_research_signal(handle, &"bio.maize", 0, 1, 0, 1)
	ext.run_country_slice({"day_index": 0})

	ext.capture_country_pod_catalog()
	ext.capture_country_runtime_snapshot()
	ext.capture_runtime_inputs({
		"generation": 1,
		"day": 0,
		"terrain": PackedByteArray([1]),
		"neighbor_offsets": PackedInt32Array([0, 0]),
		"neighbor_indices": PackedInt32Array(),
		"cell_temp": PackedFloat32Array([15.0]),
		"cell_moisture": PackedFloat32Array([0.5]),
		"cell_plant_available_water": PackedFloat32Array([0.5]),
	})
	ext.configure_runtime_graph({"enabled": true, "day": 0})
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0x004,
		"day": 0,
		"speed_days_per_second": 1000.0,
		"paused": false,
	})
	_expect("Country-only ACTIVE worker starts", bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		return
	var granted := false
	for _attempt in range(200):
		if (int(ext.get_runtime_thread_report().get(
				"authoritative_domain_mask", 0)) & 0x004) != 0:
			granted = true
			break
		OS.delay_msec(2)
	_expect("Country worker grant is observed", granted)
	ext.set_runtime_clock(true, 1000.0)

	# Let the worker clock run well past the day the "UI" is about to stamp.
	# Poll instead of pulsing a fixed number of times: a loaded machine can
	# leave the worker behind and silently stop exercising the late path.
	# Let the worker get a few days ahead. How many it manages per pulse is up
	# to OS scheduling, so nothing is asserted here — the command below stamps
	# day 0, which is behind the worker's committed day by construction and
	# therefore exercises the late path deterministically.
	var input_generation := 1
	for _step in range(64):
		input_generation += 1
		_publish_day_input(ext, input_generation)
		ext.advance_runtime_pulse(0, 0.0, 1.0, 4000)
		OS.delay_msec(2)
	var worker_day := int(ext.get_runtime_thread_report().get(
		"simulation_committed_day", 0))
	# Day 1 is already committed by the time the warm-up ends, so the command
	# below is late no matter how far the worker actually ran.
	const STAMPED_DAY := 1
	_expect("stamped day is behind the worker clock", STAMPED_DAY <= worker_day)

	var generation_before := int(ext.get_country_worker_read_view(0).get(
		"generation", 0))
	var submitted: Dictionary = country.enqueue_research(
		handle, &"tech.wild_maize_collection", 0, -1, STAMPED_DAY, 30)
	_expect("late research command is admitted",
		bool(submitted.get("ok", false)))

	var queued := PackedInt32Array()
	for _step in range(240):
		input_generation += 1
		_publish_day_input(ext, input_generation)
		ext.advance_runtime_pulse(0, 0.0, 1.0, 4000)
		ext.set_runtime_clock(false, 1000.0)
		OS.delay_msec(3)
		ext.set_runtime_clock(true, 1000.0)
		queued = country.research_snapshot(handle).get(
			"queue_technology_indices", PackedInt32Array())
		if queued.size() > 0:
			break
	_expect("late research command reaches the worker queue", queued.size() > 0)

	var rejected_late := false
	var receipts: Array = ext.poll_country_command_receipts(0, 64).get(
		"receipts", [])
	for row in receipts:
		if String((row as Dictionary).get("reason", "")) \
				== "country_command_day_already_committed":
			rejected_late = true
	_expect("no command is dropped as already-committed", not rejected_late)

	# The UI only refreshes when the worker read view reports a newer
	# generation: country_committed is emitted from that transition. A day that
	# commits the enqueue must therefore advance it, including when the day is
	# soft-committed because a technology peer is still PENDING.
	var view: Dictionary = ext.get_country_worker_read_view(generation_before)
	_expect("read view advances after the queued command commits",
		bool(view.get("ok", false)) and bool(view.get("available", false))
		and int(view.get("generation", 0)) > generation_before)
	ext.request_runtime_stop()
