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
