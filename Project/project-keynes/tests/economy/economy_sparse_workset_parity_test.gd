extends "res://tests/economy/economy_preview_basis_parity_test.gd"

## 大图两处聚落、仅早期技术；与全图/晚过滤路径比较逐日完整状态。
func _boot(compiled: Dictionary, _cells: int, seed: int) -> Object:
	var cells := 6400
	var ext := _new_ext(cells)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_expect("country configures with locked late goods", bool(ext.configure_country(
		catalog, {"country_runtime_mode": "ACTIVE", "starting_technology_ids":
			PackedStringArray(["tech.gathering", "tech.hunting",
				"tech.deadwood_collection", "tech.early_trade"])}, cells, seed).get("ok", false)))
	var water := PackedByteArray()
	water.resize(cells)
	_expect("country bootstraps", bool(ext.bootstrap_country({}, water).get("ok", false)))
	_expect("economy configures", bool(ext.configure_economy(
		catalog, _profile(), cells, seed).get("ok", false)))
	var cache: Dictionary = ext.get_economy_report().get("demand_basis_cache", {})
	_expect("a large empty map configures without demand cache storage",
		int(cache.get("allocated_slots", -1)) == 0 and int(cache.get("values_bytes", -1)) == 0
		and int(cache.get("index_bytes", -1)) == 0)
	var signatures: PackedStringArray = compiled.signature_keys
	var forager := signatures.find("forager|default")
	var merchant := signatures.find("merchant|default")
	_expect("two distant settlements bootstrap", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, cells - 1, cells - 1]),
		"signature_ids": PackedInt32Array([forager, merchant, forager, merchant]),
		"population": PackedInt64Array([10, 10, 10, 10]),
		"funds": PackedInt64Array([100000000, 100000000, 100000000, 100000000]),
	}, {}).get("ok", false)))
	return ext


func _run_compact_day(ext: Object, day: int) -> Dictionary:
	var result := super._run_compact_day(ext, day)
	if day == 0:
		var cache: Dictionary = ext.get_economy_report().get("demand_basis_cache", {})
		var slots := int(cache.get("allocated_slots", -1))
		var row_bytes := 8 * (2 * int(cache.get("variant_count", 0))
			+ 3 * int(cache.get("need_count", 0)))
		_expect("only the two distant populated cells have a demand row on opening day",
			int(cache.get("sample_day", -1)) == day and int(cache.get("registered_cells", -1)) == 2
			and int(cache.get("valid_cells", -1)) == 2)
		_expect("need and variant storage follows slot capacity on the 6400-cell map",
			row_bytes > 0 and slots >= 2 and slots <= 4
			and int(cache.get("values_bytes", -1)) == slots * row_bytes)
	return result
