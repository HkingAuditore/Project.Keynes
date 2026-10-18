extends RefCounted

const CountryHelper = preload("res://tests/country_test_helper.gd")
const Catalog = preload("res://scripts/economy/economy_catalog.gd")

static func make(cells: int = 4, sea: bool = false, water_capability: bool = true,
		fixed_cadence: bool = false) -> Dictionary:
	var compiled: Dictionary = Catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return {"ok": false, "reason": "catalog"}
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var ext := _new_ext(compiled, cells)
	var water := PackedByteArray()
	water.resize(cells)
	if sea:
		for i in range(1, cells - 1):
			water[i] = 1
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	profile.trade_max_route_expansions = 65536
	profile.trade_capacity_per_merchant_q16 = 67108864
	profile.trade_min_margin_q16 = 0
	if fixed_cadence:
		# A/B controls the machine-timing cadence input as well as the seed.
		profile.economy_cadence_force_market_days = 1
		profile.economy_cadence_force_plan_days = 5
		profile.economy_cadence_force_investment_days = 10
	var country_ok := false
	if water_capability:
		country_ok = CountryHelper.configure_all_technologies(ext, catalog, cells, 77331, water)
	else:
		var starting := PackedStringArray()
		for id in catalog.technology_ids:
			if id not in ["tech.river_transport", "tech.celestial_navigation",
				"tech.oceanic_navigation", "tech.oceanic_ship_design"]:
				starting.append(id)
		country_ok = bool(ext.configure_country(catalog, {"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": starting}, cells, 77331).get("ok", false))
		country_ok = country_ok and bool(ext.bootstrap_country({}, water).get("ok", false))
	if not country_ok:
		return {"ok": false, "reason": "country"}
	var configured: Dictionary = ext.configure_economy(catalog, profile, cells, 77331)
	if not bool(configured.get("ok", false)):
		return configured
	var topology := capture(ext, cells, sea)
	if not bool(topology.get("ok", false)):
		return topology
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	stock.resize(cells * goods.size())
	var prices := PackedInt32Array()
	prices.resize(stock.size())
	for cell in cells:
		for good in goods.size():
			prices[cell * goods.size() + good] = maxi(1, int(compiled.good_default_price[good]))
	for id in ["gathered_plants", "cloth"]:
		var index := goods.find(id)
		stock[index] = 100000000
		prices[index] = maxi(1, int(compiled.good_default_price[index]) / 10)
	var merchant: int = compiled.signature_keys.find("merchant|default")
	var bootstrap: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, cells - 1]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}, {"stock": stock, "price": prices})
	return {"ok": bool(bootstrap.get("ok", false)), "ext": ext,
		"cells": cells, "profile": profile, "catalog": catalog, "compiled": compiled}


static func capture(ext: Object, cells: int, sea: bool = false,
		blocked: bool = false, generation: int = 1) -> Dictionary:
	var neighbors := PackedInt32Array()
	neighbors.resize(cells * 6)
	neighbors.fill(-1)
	for cell in cells - 1:
		if blocked and cell == cells / 2:
			continue
		neighbors[cell * 6] = cell + 1
		neighbors[(cell + 1) * 6 + 3] = cell
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var forms := PackedByteArray()
	forms.resize(cells)
	forms.fill(4)
	if sea:
		for cell in range(1, cells - 1):
			forms[cell] = 2 # shallow water
	var passable := PackedByteArray()
	passable.resize(256)
	passable[2] = 1
	var costs := PackedInt32Array()
	costs.resize(256)
	costs[2] = 1
	return ext.capture_economy_trade_topology(neighbors, terrain, passable, costs,
		generation, forms)


static func advance(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = ext.run_economy_slice({"day_index": day})
	for continuation in 256:
		if bool(report.get("done", false)) or (not bool(report.get("commit_due", false))
				and not bool(report.get("boundary_continuation_required", false))):
			break
		report = ext.run_economy_slice({"day_index": day, "tick_index": continuation + 1})
	return report


static func find_trade(context: Dictionary) -> int:
	var ext: Object = context.ext
	for day in 40:
		advance(ext, day)
		var orders: Dictionary = ext.get_trade_orders_for_cell(0, 0, 64)
		if not bool(ext.get_economy_report().get("epoch_active", true)) \
				and int(orders.get("total", 0)) > 0:
			return day
	return -1


static func _new_ext(catalog: Dictionary, cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var scalar := PackedFloat32Array()
	scalar.resize(cells)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var zeros := PackedByteArray()
	zeros.resize(cells)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, terrain if slot_name == &"cell_terrain" else zeros)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var empty := PackedFloat32Array()
	empty.resize(cells)
	for i in reserve_slots.size():
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, empty)
		ext.write_f32_range(extra_sid, 0, empty)
	return ext
