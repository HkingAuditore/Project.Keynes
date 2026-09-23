extends SceneTree

# Country ACTIVE unique-writer must still buy technology_points from markets.
# Regression for the early skip that left research stalled after starter stock.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("technology procurement country worker: %d checks, %d failures" % [
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
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, PackedByteArray([0]))


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
	_expect("country configures", bool(country.configure(ext, 1, 9043,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	var gathering := (compiled.technology_ids as PackedStringArray).find(
		"tech.gathering")
	var maize_identification := (compiled.technology_ids as PackedStringArray).find(
		"tech.maize_identification")
	var early_knowledge := (compiled.technology_ids as PackedStringArray).find(
		"tech.early_knowledge_institution")
	var country_packet := {
		"country_ids": PackedStringArray(["country.worker_procurement"]),
		"country_names": PackedStringArray(["WorkerProcurement"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 3]),
		"technology_indices": PackedInt32Array([
			gathering, maize_identification, early_knowledge]),
	}
	_expect("country bootstraps", bool(country.bootstrap(
		PackedByteArray([0]), country_packet).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("research evidence queues", bool(country.discover_research_signal(
		handle, &"bio.maize", 0, 1, 0, 1).get("ok", false)))
	_expect("research evidence commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("done", false)))
	_expect("research demand and budget queue", bool(country.enqueue_research(
		handle, &"tech.wild_maize_collection", 0, -1, 1, 10).get("ok", false))
		and bool(country.set_research_budget(handle, true, 10000000, 1, 11).get(
			"ok", false)))
	_expect("policy commits before market settlement", bool(ext.run_country_slice(
		{"day_index": 1}).get("done", false)))
	var pre_worker := country.research_snapshot(handle)
	_expect("research queue is live before Country ACTIVE handoff",
		(pre_worker.queue_technology_indices as PackedInt32Array).size() > 0
		and bool(pre_worker.auto_purchase_enabled)
		and int(pre_worker.daily_procurement_budget) > 0)

	var native_catalog := compiled.duplicate(false)
	native_catalog.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	_expect("economy configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 9043).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	var merchant := signatures.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize((compiled.good_ids as PackedStringArray).size())
	stock.fill(0)
	var points_good := (compiled.good_ids as PackedStringArray).find(
		"technology_points")
	stock[points_good] = 50000
	_expect("merchant market with technology stock bootstraps", bool(
		ext.bootstrap_economy({
			"cell_indices": PackedInt32Array([0]),
			"signature_ids": PackedInt32Array([merchant]),
			"population": PackedInt64Array([10]),
			"funds": PackedInt64Array([0]),
		}, {"stock": stock}).get("ok", false)))

	_expect("Country POD inputs capture", bool(ext.capture_country_pod_catalog().get(
		"ok", false)) and bool(ext.capture_country_runtime_snapshot().get("ok", false)))
	_expect("runtime inputs publish", bool(ext.capture_runtime_inputs({
		"generation": 1,
		"day": 0,
		"terrain": PackedByteArray([1]),
		"neighbor_offsets": PackedInt32Array([0, 0]),
		"neighbor_indices": PackedInt32Array(),
		"cell_temp": PackedFloat32Array([15.0]),
		"cell_moisture": PackedFloat32Array([0.5]),
		"cell_plant_available_water": PackedFloat32Array([0.5]),
	}).get("ok", false)))
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
		print("  start diagnostic=", started)
		return
	var granted := false
	for _attempt in range(100):
		if (int(ext.get_runtime_thread_report().get(
				"authoritative_domain_mask", 0)) & 0x004) != 0:
			granted = true
			break
		OS.delay_msec(2)
	ext.set_runtime_clock(true, 1000.0)
	_expect("Country worker grant is observed", granted)

	var before_points := int(country.research_snapshot(handle).technology_points_stock)
	var before_purchased := int(country.research_snapshot(handle).purchased_total)
	var before_consumed := int(country.research_snapshot(handle).consumed_total)
	var before_cash := int(country.snapshot(handle).cash)
	var procured := 0
	var peak_procured := 0
	var no_fatal := true
	var saw_pending := false
	for step in range(128):
		ext.advance_runtime_pulse(0, 0.0, 1.0, 4000)
		var status: Dictionary = ext.get_country_economy_asset_protocol_status()
		saw_pending = saw_pending or int(status.get("pending_requests", 0)) > 0
		var economy_report: Dictionary = ext.get_runtime_graph_last_economy_report()
		no_fatal = no_fatal and not bool(economy_report.get("fatal", false))
		procured = int(economy_report.get("government_research_procured_points", 0))
		peak_procured = maxi(peak_procured, procured)
		var purchased_now := int(country.research_snapshot(handle).purchased_total)
		if peak_procured > 0 or purchased_now > before_purchased:
			break
		ext.set_runtime_clock(false, 1000.0)
		OS.delay_msec(3)
		ext.set_runtime_clock(true, 1000.0)

	var after_research := country.research_snapshot(handle)
	var after_points := int(after_research.technology_points_stock)
	var after_purchased := int(after_research.purchased_total)
	var after_consumed := int(after_research.consumed_total)
	var worker_view: Dictionary = ext.get_country_worker_read_view(-1)
	var worker_cash: PackedInt64Array = worker_view.get(
		"country_cash", PackedInt64Array())
	var worker_goods: PackedInt64Array = worker_view.get(
		"country_goods", PackedInt64Array())
	var worker_points := 0
	if worker_goods.size() > points_good:
		worker_points = int(worker_goods[points_good])
	# Durable purchase evidence: treasury debit + purchased_total. Live TP stock
	# may already be zero because Country research consumes the same day.
	_expect("procurement completes without Economy fatal under Country ACTIVE",
		no_fatal and (peak_procured > 0 or after_purchased > before_purchased))
	_expect("Host research peer publishes pending work", saw_pending)
	_expect("treasury records Host technology purchase",
		after_purchased > before_purchased
		or after_points > before_points
		or worker_points > before_points
		or after_consumed > before_consumed)
	_expect("Country worker cash declines after research purchase",
		worker_cash.size() == 1 and int(worker_cash[0]) < before_cash)
	ext.request_runtime_stop()
