extends "res://tests/family/family_colonization_runtime_test.gd"

## 复现「连续派遣多支开拓队，只有第一支成功」。
##
## 玩家操作：在开拓面板连续对两个不同的目标格提交派遣。旧实现的第二支
## 派遣被拒（或静默无效）。这里用 5 格直线地图（0-1-2-3-4）搭出两个
## 可派目标，逐支提交并打印返回码。

func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		quit(1)
		return
	compiled.erase("ok")
	_multi_dispatch_case(compiled.duplicate(true))
	print("=== colonization multi dispatch: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _multi_dispatch_case(catalog: Dictionary) -> void:
	var fixture := _make_line_fixture(catalog, 261220, 5, 1000000, 1000000000000)
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	if ext == null or country == 0:
		return
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("line fixture has the founder family", int(families.get("total", 0)) == 1)
	if int(families.get("total", 0)) != 1:
		print("families=", families)
		return
	var family := int((families.family_handles as PackedInt64Array)[0])
	var day := _economy_command_day(ext)

	# 第一支：家族队 -> 目标 2。
	var first_quotes: Dictionary = ext.get_family_colonization_quotes(
		country, 2, family, 0, 0, 64)
	print("[multi/first] quotes_total=", int(first_quotes.get("total", -1)),
		" tokens=", first_quotes.get("quote_tokens", PackedInt64Array()))
	_expect("first target has a quote", int(first_quotes.get("total", 0)) >= 1)
	if int(first_quotes.get("total", 0)) < 1:
		return
	var first_token := int((first_quotes.quote_tokens as PackedInt64Array)[0])
	var first: Dictionary = ext.start_family_colonization(country, family,
		0, 2, 3, first_token, day, 2612201)
	print("[multi/first] start=", first)
	_expect("the first expedition is accepted", bool(first.get("ok", false)))
	if not bool(first.get("ok", false)):
		return

	# 第二支：同一家族 -> 另一个目标 4。
	var second_quotes: Dictionary = ext.get_family_colonization_quotes(
		country, 4, family, 0, 0, 64)
	print("[multi/second] quotes_total=", int(second_quotes.get("total", -1)),
		" tokens=", second_quotes.get("quote_tokens", PackedInt64Array()),
		" max=", second_quotes.get("maximum_populations", PackedInt64Array()))
	var second_token := 0
	var second_max := 0
	if int(second_quotes.get("total", 0)) >= 1:
		second_token = int((second_quotes.quote_tokens as PackedInt64Array)[0])
		second_max = int((second_quotes.maximum_populations as PackedInt64Array)[0])
	_expect("a second target still gets a quote after the first dispatch",
		int(second_quotes.get("total", 0)) >= 1)
	var second: Dictionary = {}
	var second_people := mini(3, maxi(1, second_max))
	if second_token != 0:
		second = ext.start_family_colonization(country, family, 0, 4,
			second_people, second_token, day, 2612202)
	print("[multi/second] start=", second)
	_expect("the second expedition is accepted", bool(second.get("ok", false)))

	# 第三支：无家族移民队 -> 目标 3，验证不同队伍类型也能并行。
	var third_quotes: Dictionary = ext.get_family_colonization_quotes(
		country, 3, 0, 0, 0, 64)
	print("[multi/third] quotes_total=", int(third_quotes.get("total", -1)),
		" families=", third_quotes.get("family_handles", PackedInt64Array()))
	var third_token := 0
	var third_max := 0
	for index in range(int(third_quotes.get("total", 0))):
		if int((third_quotes.family_handles as PackedInt64Array)[index]) == 0:
			third_token = int((third_quotes.quote_tokens as PackedInt64Array)[index])
			third_max = int((third_quotes.maximum_populations as PackedInt64Array)[index])
			break
	var third: Dictionary = {}
	if third_token != 0:
		third = ext.start_family_colonization(country, 0, 0, 3,
			mini(2, maxi(1, third_max)), third_token, day, 2612203)
	print("[multi/third] start=", third)
	_expect("a caravan joins the same day as the family parties",
		bool(third.get("ok", false)))

	var page: Dictionary = ext.get_family_expeditions(country, 0, 64)
	print("[multi/page] total=", int(page.get("total", 0)),
		" targets=", page.get("target_cells", PackedInt32Array()),
		" states=", page.get("states", PackedInt32Array()))
	_expect("three expeditions are in flight at once",
		int(page.get("total", 0)) == 3)
	var report: Dictionary = ext.get_economy_report()
	_expect("multi dispatch keeps the economy consistent",
		not bool(report.get("fatal", false))
		and int(report.get("population_error", -1)) == 0
		and int(report.get("money_error", -1)) == 0
		and int(report.get("goods_error", -1)) == 0)


## 一条 cell_count 格的直线地图，全部平原；只有格 0 归本国。
func _make_line_fixture(catalog: Dictionary, seed: int, cell_count: int,
		stock_fill: int, country_cash: int) -> Dictionary:
	var map := MapData.new(cell_count, 1)
	for q in range(cell_count):
		var cell := HexCell.new(q, 0)
		cell.terrain = TerrainType.TERRAIN.PLAIN
		cell.landform = LandformType.LF.PLAIN
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
	_expect("modifier runtime configures", bool(ext.configure_modifiers(
		modifier_catalog, cell_count).get("ok", false)))
	var effect_catalog := EffectCatalogScript.new()
	_expect("effect runtime configures", bool(ext.configure_effects(
		effect_catalog.compile_native_catalog()).get("ok", false)))
	ext.start_runtime_worker({"simulation_thread_mode": "OFF", "economy_production_writer": "compact_slice"})
	var all_technology_ids: PackedStringArray = catalog.technology_ids
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": all_technology_ids,
	}
	_expect("country runtime configures", bool(ext.configure_country(
		catalog, country_profile, cell_count, seed).get("ok", false)))
	var technology_indices := PackedInt32Array()
	for index in range(all_technology_ids.size()):
		technology_indices.append(index)
	_expect("one-cell country bootstraps", bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.colonization_multi"]),
		"country_names": PackedStringArray(["多队开拓测试国"]),
		"country_cash": PackedInt64Array([country_cash]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0, 0, 0, 0, 0])).get("ok", false)))
	var country_handle := int(ext.get_country_cell_summary(0).country_handle)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_milestone_populations = PackedInt64Array([1, 2, 3, 4, 5, 6, 7, 8])
	profile.family_min_founder_people = 20
	profile.family_founding_choice_mode = "AUTO"
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
	_expect("economy runtime configures", bool(ext.configure_economy(
		catalog, profile, cell_count, seed).get("ok", false)))
	# 六邻接按「方向 0 = +q，方向 3 = -q」排布，组成 0-1-2-3-4 直线。
	var neighbors := PackedInt32Array()
	neighbors.resize(cell_count * 6)
	neighbors.fill(-1)
	for index in range(cell_count):
		if index + 1 < cell_count:
			neighbors[index * 6] = index + 1
		if index > 0:
			neighbors[index * 6 + 3] = index - 1
	var terrain := PackedByteArray()
	for index in range(cell_count):
		terrain.append(int(TerrainType.TERRAIN.PLAIN))
	var passable := PackedByteArray()
	passable.resize(256)
	var costs := PackedInt32Array()
	costs.resize(256)
	passable[int(TerrainType.TERRAIN.PLAIN)] = 1
	costs[int(TerrainType.TERRAIN.PLAIN)] = 2
	_expect("packed six-neighbor topology configures", bool(
		ext.capture_economy_trade_topology(neighbors, terrain, passable,
			costs, 1).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var forager := signatures.find("forager|default")
	var merchant := signatures.find("merchant|default")
	var building := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var stock := PackedInt64Array()
	stock.resize(cell_count * (catalog.good_ids as PackedStringArray).size())
	stock.fill(stock_fill)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([forager, merchant]),
		"population": PackedInt64Array([10, 2]),
		"funds": PackedInt64Array([1000000, 1000000]),
		"forced_named_cells": PackedInt32Array([0]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building]),
		"building_owner_signature_ids": PackedInt32Array([forager]),
		"building_counts": PackedInt64Array([1]),
		"founder_family_cells": PackedInt32Array([0]),
		"founder_family_building_type_ids": PackedInt32Array([building]),
		"founder_family_owner_signature_ids": PackedInt32Array([forager]),
	})
	_expect("economy and founder family bootstrap", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		print("line fixture bootstrap=", boot)
	return {"ext": ext, "map": map, "country_handle": country_handle}
