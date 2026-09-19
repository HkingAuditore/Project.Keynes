extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")

var _failures := 0


func _init() -> void:
	_run()
	print("=== water transport runtime: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		print(compiled.get("error", compiled.get("reason", "")))
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_run_empty_landform_keeps_land_routes(catalog.duplicate(true))
	_run_strait_requires_shallow_sea(catalog.duplicate(true))
	_run_nested_sea_classes(catalog.duplicate(true))
	_run_lake_and_river(catalog.duplicate(true))
	_run_sea_ice_stays_land_bridge(catalog.duplicate(true))
	_run_water_target_rejected(catalog.duplicate(true))
	_run_fishing_boats_do_not_unlock_transport(catalog.duplicate(true))
	_run_trade_across_strait_conserves(catalog.duplicate(true))


func _run_empty_landform_keeps_land_routes(catalog: Dictionary) -> void:
	var world := _make_world(catalog, 240801, 3, PackedStringArray(),
		PackedByteArray([0, 0, 0]), PackedInt32Array([0]),
		PackedByteArray([2, 2, 2]), PackedByteArray(), PackedByteArray())
	if world.is_empty():
		return
	var ext: Object = world.ext
	_expect("empty landform captures without water portals",
		int(ext.get_economy_report().get("trade_water_portal_count", -1)) == 0)
	world.map.visible_arr[1] = 0
	world.map.vision_revision += 1
	var hidden: Dictionary = ext.get_family_colonization_quotes(
		world.country_handle, 2, world.family_handle, 0, 0, 64)
	_expect("fogged intermediate land still blocks a land-only route",
		bool(hidden.get("ok", false)) and int(hidden.get("total", -1)) == 0)
	world.map.visible_arr[1] = 1
	world.map.vision_revision += 1
	var visible: Dictionary = ext.get_family_colonization_quotes(
		world.country_handle, 2, world.family_handle, 0, 0, 64)
	_expect("all-land three-cell line remains reachable",
		bool(visible.get("ok", false)) and int(visible.get("total", 0)) == 1
		and int((visible.route_costs as PackedInt32Array)[0]) == 4)


func _run_strait_requires_shallow_sea(catalog: Dictionary) -> void:
	var landform := PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.COAST, LandformType.LF.PLAIN])
	var none := _make_world(catalog, 240802, 3, PackedStringArray(),
		PackedByteArray([0, 1, 0]), PackedInt32Array([0]),
		PackedByteArray([2, 2, 2]), landform, PackedByteArray())
	if none.is_empty():
		return
	_expect("coast strait builds shallow/far/deep portal graphs",
		int(none.ext.get_economy_report().get("trade_water_portal_count", 0)) > 0
		and int(none.ext.get_economy_report().get("trade_water_portal_edges", 0)) > 0)
	var blocked: Dictionary = none.ext.get_family_colonization_quotes(
		none.country_handle, 2, none.family_handle, 0, 0, 64)
	_expect("strait is unreachable without maritime technology",
		bool(blocked.get("ok", false)) and int(blocked.get("total", -1)) == 0)

	var shallow := _make_world(catalog, 240803, 3,
		PackedStringArray(["tech.celestial_navigation"]),
		PackedByteArray([0, 1, 0]), PackedInt32Array([0]),
		PackedByteArray([2, 2, 2]), landform, PackedByteArray())
	if shallow.is_empty():
		return
	shallow.map.visible_arr[1] = 0
	shallow.map.vision_revision += 1
	var quotes: Dictionary = shallow.ext.get_family_colonization_quotes(
		shallow.country_handle, 2, shallow.family_handle, 0, 0, 64)
	_expect("shallow-sea tech crosses a COAST strait even when the water cell is fogged",
		bool(quotes.get("ok", false)) and int(quotes.get("total", 0)) == 1
		and int((quotes.route_costs as PackedInt32Array)[0]) == 3)
	if int(quotes.get("total", 0)) != 1:
		print("shallow quotes=", quotes)
		return
	var detail: Dictionary = shallow.ext.get_family_colonization_quote_detail(
		int((quotes.quote_tokens as PackedInt64Array)[0]))
	_expect("quote detail expands the water corridor between land portals",
		(detail.route_cells as PackedInt32Array) == PackedInt32Array([0, 1, 2])
		and (detail.cumulative_costs as PackedInt32Array) == PackedInt32Array([0, 1, 3]))


func _run_nested_sea_classes(catalog: Dictionary) -> void:
	var far_landform := PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.OCEAN, LandformType.LF.PLAIN])
	var deep_landform := PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.DEEP_OCEAN, LandformType.LF.PLAIN])
	var coast_landform := PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.COAST, LandformType.LF.PLAIN])
	_expect("shallow tech cannot enter far ocean",
		_quote_total(catalog, 240804, PackedStringArray(["tech.celestial_navigation"]),
			far_landform) == 0)
	_expect("far-sea tech crosses OCEAN",
		_quote_total(catalog, 240805, PackedStringArray(["tech.oceanic_navigation"]),
			far_landform) == 1)
	_expect("far-sea tech still cannot enter DEEP_OCEAN",
		_quote_total(catalog, 240806, PackedStringArray(["tech.oceanic_navigation"]),
			deep_landform) == 0)
	_expect("deep-sea tech crosses DEEP_OCEAN",
		_quote_total(catalog, 240807, PackedStringArray(["tech.oceanic_ship_design"]),
			deep_landform) == 1)
	_expect("deep-sea tech nests over a COAST strait",
		_quote_total(catalog, 240808, PackedStringArray(["tech.oceanic_ship_design"]),
			coast_landform) == 1)


func _run_lake_and_river(catalog: Dictionary) -> void:
	var lake := PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.LAKE, LandformType.LF.PLAIN])
	_expect("lake is blocked without river or maritime tech",
		_quote_total(catalog, 240809, PackedStringArray(), lake) == 0)
	_expect("river transport crosses lakes",
		_quote_total(catalog, 240810, PackedStringArray(["tech.river_transport"]),
			lake) == 1)
	_expect("shallow-sea tech also crosses lakes",
		_quote_total(catalog, 240811, PackedStringArray(["tech.celestial_navigation"]),
			lake) == 1)

	var dry := _make_world(catalog, 240812, 2, PackedStringArray(),
		PackedByteArray([0, 0]), PackedInt32Array([0]),
		PackedByteArray([2, 2]), PackedByteArray(), PackedByteArray([1, 1]))
	var wet := _make_world(catalog, 240813, 2,
		PackedStringArray(["tech.river_transport"]),
		PackedByteArray([0, 0]), PackedInt32Array([0]),
		PackedByteArray([2, 2]), PackedByteArray(), PackedByteArray([1, 1]))
	if dry.is_empty() or wet.is_empty():
		return
	var dry_quotes: Dictionary = dry.ext.get_family_colonization_quotes(
		dry.country_handle, 1, dry.family_handle, 0, 0, 64)
	var wet_quotes: Dictionary = wet.ext.get_family_colonization_quotes(
		wet.country_handle, 1, wet.family_handle, 0, 0, 64)
	_expect("river transport halves adjacent river-cell enter cost",
		bool(dry_quotes.get("ok", false)) and int(dry_quotes.get("total", 0)) == 1
		and int((dry_quotes.route_costs as PackedInt32Array)[0]) == 2
		and bool(wet_quotes.get("ok", false)) and int(wet_quotes.get("total", 0)) == 1
		and int((wet_quotes.route_costs as PackedInt32Array)[0]) == 1)


func _run_sea_ice_stays_land_bridge(catalog: Dictionary) -> void:
	var world := _make_world(catalog, 240814, 3, PackedStringArray(),
		PackedByteArray([0, 0, 0]), PackedInt32Array([0]),
		PackedByteArray([2, 20, 2]),
		PackedByteArray([LandformType.LF.PLAIN, LandformType.LF.OCEAN,
			LandformType.LF.PLAIN]), PackedByteArray(), {20: 2})
	if world.is_empty():
		return
	var quotes: Dictionary = world.ext.get_family_colonization_quotes(
		world.country_handle, 2, world.family_handle, 0, 0, 64)
	_expect("SEA_ICE stays a land bridge and is not a waterway",
		bool(quotes.get("ok", false)) and int(quotes.get("total", 0)) == 1
		and int((quotes.route_costs as PackedInt32Array)[0]) == 4)


func _run_water_target_rejected(catalog: Dictionary) -> void:
	var landform := PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.COAST, LandformType.LF.PLAIN])
	var world := _make_world(catalog, 240815, 3,
		PackedStringArray(["tech.celestial_navigation"]),
		PackedByteArray([0, 1, 0]), PackedInt32Array([0]),
		PackedByteArray([2, 2, 2]), landform, PackedByteArray())
	if world.is_empty():
		return
	var quotes: Dictionary = world.ext.get_family_colonization_quotes(
		world.country_handle, 1, world.family_handle, 0, 0, 64)
	_expect("water cells remain illegal colonization targets",
		not bool(quotes.get("ok", true))
		and String(quotes.get("code", "")) == "colonization_target_invalid")


func _run_fishing_boats_do_not_unlock_transport(catalog: Dictionary) -> void:
	var landform := PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.COAST, LandformType.LF.PLAIN])
	_expect("fishing boats keep only output modifiers and do not open sea corridors",
		_quote_total(catalog, 240816, PackedStringArray(["tech.fishing_boats"]),
			landform) == 0)


func _run_trade_across_strait_conserves(catalog: Dictionary) -> void:
	var landform := PackedByteArray([
		LandformType.LF.PLAIN, LandformType.LF.COAST, LandformType.LF.PLAIN])
	var blocked := _make_trade_world(catalog, 240817,
		_tech_ids_except_water(catalog), landform)
	var open := _make_trade_world(catalog, 240818,
		catalog.technology_ids, landform)
	if blocked.is_empty() or open.is_empty():
		return
	var blocked_orders := _wait_for_trade_orders(blocked.ext)
	var open_orders := _wait_for_trade_orders(open.ext)
	var open_report: Dictionary = open.ext.get_economy_report()
	_expect("no domestic order crosses an unexplored strait",
		int(blocked_orders.get("total", -1)) == 0)
	if int(open_orders.get("total", 0)) <= 0:
		print("open trade report=", {
			"rejected_route": open_report.get("trade_rejected_route", -1),
			"source_signals": open_report.get("trade_source_signals", -1),
			"dest_signals": open_report.get("trade_destination_signals", -1),
			"orders_dispatched": open_report.get("trade_orders_dispatched", -1),
			"portals": open_report.get("trade_water_portal_count", -1),
			"portal_edges": open_report.get("trade_water_portal_edges", -1),
		})
	_expect("shallow-sea tech lets the same strait dispatch a domestic order",
		int(open_orders.get("total", 0)) > 0)
	_expect("water-corridor trade keeps goods and money conservation at zero",
		not bool(open_report.get("fatal", true))
		and int(open_report.get("goods_error", 1)) == 0
		and int(open_report.get("money_error", 1)) == 0)


func _quote_total(catalog: Dictionary, seed: int, tech_ids: PackedStringArray,
		landform: PackedByteArray) -> int:
	var water := PackedByteArray()
	water.resize(landform.size())
	for i in range(landform.size()):
		water[i] = 1 if int(landform[i]) <= int(LandformType.LF.LAKE) else 0
	water[0] = 0
	if water.size() > 2:
		water[water.size() - 1] = 0
	var terrain := PackedByteArray()
	terrain.resize(landform.size())
	terrain.fill(2)
	var world := _make_world(catalog, seed, landform.size(), tech_ids, water,
		PackedInt32Array([0]), terrain, landform, PackedByteArray())
	if world.is_empty():
		return -1
	var quotes: Dictionary = world.ext.get_family_colonization_quotes(
		world.country_handle, landform.size() - 1, world.family_handle, 0, 0, 64)
	if not bool(quotes.get("ok", false)):
		return -1
	return int(quotes.get("total", -1))


func _make_world(catalog: Dictionary, seed: int, cells: int,
		tech_ids: PackedStringArray, water_mask: PackedByteArray,
		territory: PackedInt32Array, terrain: PackedByteArray,
		landform: PackedByteArray, rivers: PackedByteArray,
		extra_move_costs: Dictionary = {}) -> Dictionary:
	var map := MapData.new(cells, 1)
	for q in range(cells):
		var cell := HexCell.new(q, 0)
		cell.terrain = TerrainType.TERRAIN.PLAIN
		cell.base_terrain = TerrainType.TERRAIN.PLAIN
		cell.landform = LandformType.LF.PLAIN
		cell.base_landform = LandformType.LF.PLAIN
		if q < landform.size():
			cell.landform = int(landform[q])
			cell.base_landform = int(landform[q])
		if q < terrain.size() and int(terrain[q]) == 20:
			cell.terrain = TerrainType.TERRAIN.SEA_ICE
			cell.base_terrain = TerrainType.TERRAIN.SEA_ICE
		if q < rivers.size():
			cell.has_river = int(rivers[q]) != 0
		map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	map.visible_arr.fill(1)
	map.explored_arr.fill(1)
	map.vision_revision = 1
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("map binds to native world", bool(ext.bind_map_data(map)))
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	if not bool(ext.configure_modifiers(modifier_catalog, cells).get("ok", false)):
		_expect("modifier runtime configures", false)
		return {}
	var effect_catalog := EffectCatalogScript.new()
	if not bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get("ok", false)):
		_expect("effect runtime configures", false)
		return {}
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": tech_ids,
	}
	if not bool(ext.configure_country(catalog, country_profile, cells, seed).get("ok", false)):
		_expect("country runtime configures", false)
		return {}
	var technology_indices := _tech_indices(catalog, tech_ids)
	var territory_offsets := PackedInt32Array([0, territory.size()])
	var boot_water := water_mask
	if boot_water.size() != cells:
		boot_water = PackedByteArray()
		boot_water.resize(cells)
		boot_water.fill(0)
	if not bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.water_transport_test"]),
		"country_names": PackedStringArray(["水运测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": territory_offsets,
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, boot_water).get("ok", false)):
		_expect("country bootstraps", false)
		return {}
	var country_handle := int(ext.get_country_cell_summary(int(territory[0])).country_handle)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_min_settlement_tier = 0
	profile.family_min_population_per_active = 1
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	profile.trade_runtime_mode = "ACTIVE"
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
	if not bool(ext.configure_economy(catalog, profile, cells, seed).get("ok", false)):
		_expect("economy runtime configures", false)
		return {}
	var neighbors := _line_neighbors(cells)
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 2
	for terrain_id in extra_move_costs.keys():
		passable[int(terrain_id)] = 1
		costs[int(terrain_id)] = int(extra_move_costs[terrain_id])
	var captured: Dictionary = ext.capture_economy_trade_topology(
		neighbors, terrain, passable, costs, 1, landform, rivers)
	if not bool(captured.get("ok", false)):
		_expect("trade topology captures", false)
		print("capture=", captured)
		return {}
	var signatures: PackedStringArray = catalog.signature_keys
	var forager := signatures.find("forager|default")
	var merchant := signatures.find("merchant|default")
	var building := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var stock := PackedInt64Array()
	stock.resize(cells * (catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([int(territory[0]), int(territory[0])]),
		"signature_ids": PackedInt32Array([forager, merchant]),
		"population": PackedInt64Array([10, 2]),
		"funds": PackedInt64Array([1000000, 1000000]),
		"forced_named_cells": PackedInt32Array([int(territory[0])]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([int(territory[0])]),
		"building_type_ids": PackedInt32Array([building]),
		"building_owner_signature_ids": PackedInt32Array([forager]),
		"building_counts": PackedInt64Array([1]),
		"founder_family_cells": PackedInt32Array([int(territory[0])]),
		"founder_family_building_type_ids": PackedInt32Array([building]),
		"founder_family_owner_signature_ids": PackedInt32Array([forager]),
	})
	if not bool(boot.get("ok", false)):
		_expect("economy and founder family bootstrap", false)
		print("boot=", boot)
		return {}
	var families: Dictionary = ext.get_family_cell_snapshot(int(territory[0]), 0, 64)
	if int(families.get("total", 0)) < 1:
		_expect("founder family exists", false)
		return {}
	return {
		"ext": ext,
		"map": map,
		"country_handle": country_handle,
		"family_handle": int((families.family_handles as PackedInt64Array)[0]),
	}


func _make_trade_world(catalog: Dictionary, seed: int, tech_ids: PackedStringArray,
		landform: PackedByteArray) -> Dictionary:
	var cells := 3
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
	var terrain := PackedByteArray([2, 2, 2])
	var zero_bytes := PackedByteArray()
	zero_bytes.resize(cells)
	zero_bytes.fill(0)
	for slot_name in [&"cell_terrain", &"cell_base_terrain", &"cell_landform",
			&"cell_base_landform", &"cell_vegetation", &"cell_is_water",
			&"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		var payload := terrain
		if slot_name == &"cell_landform" or slot_name == &"cell_base_landform":
			payload = landform
		elif slot_name == &"cell_is_water":
			payload = PackedByteArray([0, 1, 0])
		elif slot_name != &"cell_terrain" and slot_name != &"cell_base_terrain":
			payload = zero_bytes
		ext.write_u8_range(sid, 0, payload)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var zeros := PackedFloat32Array()
	zeros.resize(cells)
	zeros.fill(0.0)
	for i in range(reserve_slots.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, zeros)
		ext.write_f32_range(extra_sid, 0, zeros)
	if not bool(ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": tech_ids,
	}, cells, seed).get("ok", false)):
		_expect("trade country configures", false)
		return {}
	var technology_indices := _tech_indices(catalog, tech_ids)
	if not bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.water_trade_test"]),
		"country_names": PackedStringArray(["水运贸易测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 2]),
		"territory_cells": PackedInt32Array([0, 2]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0, 1, 0])).get("ok", false)):
		_expect("trade country bootstraps both shores", false)
		return {}
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	profile.trade_max_route_expansions = 1024
	profile.trade_capacity_per_merchant_q16 = 67108864
	profile.trade_min_margin_q16 = 0
	profile.starvation_death_rate_q32 = 0
	if not bool(ext.configure_economy(catalog, profile, cells, seed).get("ok", false)):
		_expect("trade economy configures", false)
		return {}
	var neighbors := _line_neighbors(cells)
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 1
	if not bool(ext.capture_economy_trade_topology(
			neighbors, terrain, passable, costs, 1, landform,
			PackedByteArray()).get("ok", false)):
		_expect("trade water topology captures", false)
		return {}
	var goods: PackedStringArray = catalog.good_ids
	var gathered := goods.find("gathered_plants")
	var signatures: PackedStringArray = catalog.signature_keys
	var merchant := signatures.find("merchant|default")
	var stock := PackedInt64Array()
	var prices := PackedInt32Array()
	stock.resize(goods.size() * cells)
	stock.fill(0)
	prices.resize(goods.size() * cells)
	for cell in range(cells):
		for good in range(goods.size()):
			prices[cell * goods.size() + good] = int(
				(catalog.good_default_price as PackedInt32Array)[good])
	stock[gathered] = 100000000
	prices[gathered] = maxi(1, int((catalog.good_default_price as PackedInt32Array)[gathered]) / 10)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 2]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}, {"stock": stock, "price": prices})
	if not bool(boot.get("ok", false)):
		_expect("two shore markets bootstrap", false)
		print("trade boot=", boot)
		return {}
	return {"ext": ext}


func _wait_for_trade_orders(ext: Object) -> Dictionary:
	var orders: Dictionary = ext.get_trade_orders_for_cell(0, 0, 64)
	for day in range(0, 16):
		if int(orders.get("total", 0)) > 0:
			return orders
		_advance_day(ext, day)
		orders = ext.get_trade_orders_for_cell(0, 0, 64)
	return orders


func _advance_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = ext.run_economy_slice({"day_index": day})
	for continuation in range(64):
		if bool(report.get("done", false)) or (
				not bool(report.get("commit_due", false)) and
				not bool(report.get("boundary_continuation_required", false))):
			break
		report = ext.run_economy_slice({"day_index": day, "tick_index": continuation + 1})
	return report


func _line_neighbors(cells: int) -> PackedInt32Array:
	var neighbors := PackedInt32Array()
	neighbors.resize(cells * 6)
	neighbors.fill(-1)
	for cell in range(cells - 1):
		neighbors[cell * 6] = cell + 1
		neighbors[(cell + 1) * 6 + 3] = cell
	return neighbors


func _tech_ids_except_water(catalog: Dictionary) -> PackedStringArray:
	var exclude := {
		"tech.river_transport": true,
		"tech.celestial_navigation": true,
		"tech.oceanic_navigation": true,
		"tech.oceanic_ship_design": true,
	}
	var out := PackedStringArray()
	for id in catalog.technology_ids:
		if not exclude.has(String(id)):
			out.append(id)
	return out


func _tech_indices(catalog: Dictionary, tech_ids: PackedStringArray) -> PackedInt32Array:
	var all: PackedStringArray = catalog.technology_ids
	var out := PackedInt32Array()
	for id in tech_ids:
		var index := all.find(id)
		if index >= 0:
			out.append(index)
	return out
