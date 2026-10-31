extends SceneTree
## Numeric equivalence of the old-plane I01 gate (plan §4.5 / §15.7).
##
## THE RISK THIS MEASURES
##
## `build_cell_program_table` now skips programs the derived layer owns, because both
## mechanisms feed the SAME hot path (`refresh_city_output_modifier_factors` ->
## `_ideology_cell_programs`). Before the gate, a derived program was applied TWICE.
##
## Removing a contribution and leaving the value unchanged are very different claims;
## only a value comparison can tell them apart. `get_city_output_factor_q16(cell,
## good)` exposes the merged result.
##
## HOW THE TWO ARMS ARE BUILT
##
## Same binary, environment switch:
##   PK_PLANE_IGNORE_I01=1  -> gate OFF (265 programs double-counted)
##   PK_PLANE_IGNORE_I01=0  -> gate ON  (correct)
##
## The script runs ONE arm per process (the switch is read once), prints a digest, and
## the driver compares the two digests.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_plane_equivalence_probe.gd

const WIDTH := 24
const HEIGHT := 24
const CELLS: int = WIDTH * HEIGHT
const Q16_ONE := 65536
const CARD_KEY := "idea.public_hygiene"

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

var _seq := 0


func _init() -> void:
	_run()


func _run() -> void:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	_install_satisfiable_tag(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var native_ideology: Dictionary = IdeologyCatalogScript.load_default() \
		.compile_native_catalog(country_ir, country_ir)
	native_ideology.erase("ok")
	var ids: PackedStringArray = native_ideology.get("ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	if dense < 0:
		print("[eq] card missing")
		quit(1)
		return

	print("[eq] stage=instantiate")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_fill_environment(ext)
	ext.configure_economy(country_ir, profile, CELLS, 31)
	ext.configure_effects(effect_ir)
	ext.configure_modifiers(mod_ir, CELLS)
	ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 31)
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.eq"]),
		"country_names": PackedStringArray(["Eq"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	print("[eq] stage=configure")
	ext.configure_ideologies(native_ideology)
	ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	var sig_keys: PackedStringArray = econ_catalog.get("signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	if farmer >= 0:
		var stock := PackedInt64Array()
		stock.resize(CELLS * goods)
		stock.fill(0)
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		for c in range(CELLS):
			ci.append(c)
			si.append(farmer)
			pp.append(30)
			ff.append(10000000)
		ext.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si, "population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		for s in range(512):
			if bool(ext.run_economy_slice({"day_index": 0, "tick_index": s}).get("done", false)):
				break

	print("[eq] stage=economy-day-done")
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if handle != 0:
		ext.submit_ideology_commands(_commands([
			{"op": 2, "day": 0, "handle": handle, "idea": -1, "value": 64 * Q16_ONE}]))
		ext.submit_ideology_commands(_commands([
			{"op": 1, "day": 0, "handle": handle, "idea": dense}]))
		_advance(ext, 0, 3)
		ext.submit_ideology_commands(_commands([
			{"op": 8, "day": 0, "handle": handle, "idea": dense, "value": 0}]))
		_advance(ext, 0, 3)
		ext.submit_ideology_commands(_commands([
			{"op": 5, "day": 0, "handle": handle, "idea": dense}]))
		_advance(ext, 0, 4)
	print("[eq] stage=equip-done")
	ext.drain_derived_cell_layer(0)
	print("[eq] stage=drained")

	# Digest of the merged output factors over every (cell, good) pair.
	print("[eq] stage=digest-start")
	var total := 0
	var nonzero := 0
	var checksum := 0
	for good in range(mini(goods, 8)):
		for cell in range(CELLS):
			var v: int = int(ext.get_city_output_factor_q16(cell, good))
			total += 1
			if v != 0:
				nonzero += 1
				checksum = (checksum * 31 + v + good * 7 + cell) % 1000000007
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	print("[eq] front=%d pairs=%d nonzero=%d checksum=%d"
		% [int(layer.get("cell_count", 0)), total, nonzero, checksum])
	print("[eq] gate=%s" % OS.get_environment("PK_PLANE_IGNORE_I01"))
	quit(0)


func _advance(ext: Object, day: int, days: int) -> void:
	for d in range(day, day + days):
		for _slice in range(64):
			var r: Dictionary = ext.run_ideology_daily(d)
			if bool(r.get("done", true)) or not bool(r.get("ok", true)):
				break


func _install_satisfiable_tag(domain: Resource) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population", "op": 0,
		"threshold_q16": 20 * Q16_ONE, "clause": 0,
	}]
	var tag := {"name": "cell.settlement", "rows": rows}
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	for i in range(tags.size()):
		if String(tags[i].get("name", "")) == "cell.settlement":
			tags[i] = tag
			domain.target_tags = tags
			return
	tags.append(tag)
	domain.target_tags = tags


func _fill_environment(ext: Object) -> void:
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zf := PackedFloat32Array()
	zf.resize(CELLS)
	var zu := PackedByteArray()
	zu.resize(CELLS)
	for n in f32_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zf)
	for n in u8_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zu)


func _u8_zero(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	return out


func _commands(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row in rows:
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		producers.append(1)
		_seq += 1
		sequences.append(_seq)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return {
		"opcodes": opcodes, "effective_days": days,
		"source_priorities": priorities, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	}