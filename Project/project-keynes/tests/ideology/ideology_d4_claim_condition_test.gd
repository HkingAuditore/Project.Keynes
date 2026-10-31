extends SceneTree
## Which condition does COMMAND_CLAIM_UNOWNED_TERRITORY actually require?
##
## WHY THIS IS SYNTHETIC
##
## The real-world version (`ideology_d4_multi_cell_country_test.gd`) showed claims being
## ACCEPTED (`accepted=48`) while the territory never changed, and each run there costs
## 7-10 minutes of world generation. Here the territory is bootstrapped by hand, so the
## same question is answered in seconds:
##
##   * does a claim on an ADJACENT neutral cell take effect?
##   * does a claim on a FAR neutral cell take effect?
##
## If only the adjacent one lands, adjacency is the condition. If neither lands, the
## problem is the submit -> apply step (or the runtime mode), not the target choice.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_d4_claim_condition_test.gd

const WIDTH := 12
const HEIGHT := 12
const CELLS: int = WIDTH * HEIGHT
## The country starts on this single cell.
const HOME := 0
## Its neighbour in the 1-D chain the stub provides.
const ADJACENT := 1
## Far away and certainly not adjacent.
const FAR := 100
const COMMAND_CLAIM_UNOWNED_TERRITORY := 20

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

var _checks := 0
var _failures := 0
var _seq := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_fill_environment(ext)
	ext.configure_economy(country_ir, profile, CELLS, 131)
	ext.configure_modifiers(mod_ir, CELLS)
	var cfg_ret: Dictionary = ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 131)
	print("[claim] configure_country -> %s" % str(cfg_ret))
	# ONE cell of territory, so any successful claim is visible as total_cells == 2.
	var boot_ret: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.claim"]),
		"country_names": PackedStringArray(["Claim"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([HOME]),
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	print("[claim] bootstrap_country -> %s" % str(boot_ret))
	ext.begin_or_reuse_economy_input_epoch(0, _epoch(1, 0))
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

	var summary: Dictionary = ext.get_country_cell_summary(HOME)
	var handle := int(summary.get("country_handle", 0))
	_expect("the single-cell country resolves", handle != 0, str(summary))
	var base: Dictionary = ext.get_country_territory_counts()
	# Read the slot column BEFORE any claim is submitted. This is the decisive ordering:
	# if it is NEUTRAL (-1) here and 0 after the claims, the claim path is corrupting the
	# column; if it is already 0 here, this fixture's own setup is what is wrong.
	print("[claim] PRE slots: HOME=%s ADJACENT=%s FAR=%s"
		% [str(ext.get_country_cell_summary(HOME).get("country_slot", "?")),
			str(ext.get_country_cell_summary(ADJACENT).get("country_slot", "?")),
			str(ext.get_country_cell_summary(FAR).get("country_slot", "?"))])
	print("[claim] baseline: widest=%s total=%s"
		% [str(base.get("widest", "?")), str(base.get("total_cells", "?"))])
	if handle == 0:
		_finish(1)
		return

	# Submit BOTH claims up front, then advance; whichever lands shows up in the count.
	var accepted_adjacent := _submit_claim(ext, handle, ADJACENT, 1)
	var accepted_far := _submit_claim(ext, handle, FAR, 1)
	print("[claim] accepted: adjacent=%s far=%s"
		% [str(accepted_adjacent), str(accepted_far)])

	var days_done := 0
	for day in range(1, 4):
		for slice in range(256):
			var r: Dictionary = ext.run_country_slice(
				{"day_index": day, "tick_index": slice})
			if bool(r.get("done", false)):
				days_done += 1
				break
			if not bool(r.get("ok", true)):
				print("[claim] slice error: %s"
					% String(r.get("reason", r.get("code", ""))))
				break
	print("[claim] country days completed: %d" % days_done)

	# The counts come from the ECONOMY runtime's epoch snapshot, not from the country
	# store, so a stale snapshot is expected until a new epoch is opened. Opening one is
	# the decisive test of whether the territory change was real.
	var ep2: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, _epoch(2, 0))
	print("[claim] epoch2 -> %s" % str(ep2))
	var after: Dictionary = ext.get_country_territory_counts()
	var widest := int(after.get("widest", 0))
	var total := int(after.get("total_cells", 0))
	print("[claim] after: widest=%d total=%d" % [widest, total])

	# Report which of the two landed. total stays 1 -> neither; 2 -> exactly one.
	var adjacent_landed := bool(ext.get_country_cell_summary(ADJACENT).get("owned", false))
	var far_landed := bool(ext.get_country_cell_summary(FAR).get("owned", false))
	print("[claim] HOME slot=%s handle=%s | ADJACENT slot=%s | FAR slot=%s"
		% [str(ext.get_country_cell_summary(HOME).get("country_slot", "?")),
			str(ext.get_country_cell_summary(HOME).get("country_handle", "?")),
			str(ext.get_country_cell_summary(ADJACENT).get("country_slot", "?")),
			str(ext.get_country_cell_summary(FAR).get("country_slot", "?"))])
	print("[claim] adjacent_landed=%s far_landed=%s"
		% [str(adjacent_landed), str(far_landed)])

	_expect("the batch was accepted for at least one claim",
		accepted_adjacent or accepted_far,
		"adjacent=%s far=%s" % [str(accepted_adjacent), str(accepted_far)])
	# The DIAGNOSTIC, not a goal: this is what the synthetic run is for.
	print("[claim] RESULT total %d -> %d (adjacent=%s far=%s)"
		% [int(base.get("total_cells", 0)), total,
			str(adjacent_landed), str(far_landed)])

	_finish(0 if _failures == 0 else 3)


func _submit_claim(ext: Object, handle: int, cell: int, day: int) -> bool:
	_seq += 1
	var batch := {
		"opcodes": PackedInt32Array([COMMAND_CLAIM_UNOWNED_TERRITORY]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([_seq]),
		"target_handles": PackedInt64Array([handle]),
		"cell_indices": PackedInt32Array([cell]),
		"aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"tax_kinds": PackedInt32Array([-1]),
		"tax_item_indices": PackedInt32Array([-1]),
		"tax_rate_basis_points": PackedInt32Array([0]),
		"tax_assessment_modes": PackedInt32Array([1]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	}
	var out: Dictionary = ext.submit_country_commands(batch)
	if not bool(out.get("ok", false)):
		print("[claim] submit rejected for cell %d: %s" % [cell, str(out)])
	return bool(out.get("ok", false))


func _epoch(epoch: int, sample_day: int) -> Dictionary:
	return {
		"sample_day": sample_day, "epoch_id": epoch, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}


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


func _finish(code: int) -> void:
	print("=== claim condition: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
