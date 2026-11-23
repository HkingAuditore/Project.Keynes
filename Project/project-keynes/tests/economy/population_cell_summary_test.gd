extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")


func _init() -> void:
	var compiled := EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		_fail("catalog compile failed: %s" % str(compiled))
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var ext := DCWorldExt.new()
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	var configured: Dictionary = ext.configure_economy(catalog, profile, 1, 77)
	if not bool(configured.get("ok", false)):
		_fail("configure failed: %s" % str(configured))
		return
	var signature_keys: PackedStringArray = compiled.signature_keys
	if signature_keys.is_empty():
		_fail("catalog has no population signatures")
		return
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([0]),
		"population": PackedInt64Array([105]),
		"funds": PackedInt64Array([1000000]),
	}, {"stock": stock})
	if not bool(boot.get("ok", false)):
		_fail("bootstrap failed: %s" % str(boot))
		return
	var summary: Dictionary = ext.get_population_cell_summary(0)
	if not bool(summary.get("ok", false)) \
			or int(summary.get("population", 0)) != 105 \
			or not summary.has("employed_population") \
			or not summary.has("unemployed_population") \
			or int(summary.get("employed_population", -1)) + int(summary.get("unemployed_population", -1)) != 105 \
			or summary.has("demand_good_indices") \
			or summary.has("populations"):
		_fail("summary shape mismatch: %s" % str(summary))
		return
	for include_details in [false, true]:
		var snapshot: Dictionary = ext.get_population_cell_snapshot(0, include_details)
		if not bool(snapshot.get("ok", false)) \
				or not snapshot.has("employed_population") \
				or not snapshot.has("unemployed_population") \
				or int(snapshot.get("employed_population", -1)) != int(summary.get("employed_population", -2)) \
				or int(snapshot.get("unemployed_population", -1)) != int(summary.get("unemployed_population", -2)):
			_fail("snapshot employment summary mismatch (include_details=%s): %s" % [
				str(include_details), str(snapshot)])
			return
	print("[population-cell-summary] PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error("[population-cell-summary] %s" % message)
	quit(1)
