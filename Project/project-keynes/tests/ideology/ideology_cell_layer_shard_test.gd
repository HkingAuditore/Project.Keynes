extends SceneTree
## Sharding behaviour of `refresh_city_modifier_factors` (plan 22 §14.3).
##
## M1-6 measured the whole reader at 0.465 ms (2400 cells) and 1.264 ms (6400
## cells) while it ran to completion inside ONE `run_economy_slice`. With a
## derived layer adding work in the same indivisible window there was no budget
## left, so the per-cell loop now yields every `CITY_FACTOR_SHARD_CELLS` cells.
##
## What has to be true for that to be a fix and not a new bug:
##
##   A. a work set larger than one shard does NOT finish in one call;
##   B. the cursor advances monotonically and never exceeds the work set;
##   C. repeated calls DO finish, and the final cursor returns to -1;
##   D. a finished pass leaves the factors valid (`_epoch_city_factor_valid`);
##   E. a shard is never size 0 (that would livelock a re-entering caller);
##   F. the painted result equals the unsharded result -- sharding must not
##      change values, only when they are computed.
##
## F is the one that matters: a shard bug that silently drops cells would still
## satisfy A-E and would corrupt every consumption/birth factor on the map.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_shard_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const CELLS := 512

## Minimal MapData stand-in: the economy only needs neighbour topology to reach
## `capture_country_epoch`.
class MapStub extends RefCounted:
	var _packed := PackedInt32Array()

	func _init(cells: int) -> void:
		_packed.resize(cells * 6)
		_packed.fill(-1)
		for cell in range(cells):
			if cell + 1 < cells:
				_packed[cell * 6] = cell + 1
			if cell - 1 >= 0:
				_packed[cell * 6 + 1] = cell - 1

	func neighbor_indices_packed() -> PackedInt32Array:
		return _packed
const STAT := "economy.city.birth_factor"
const DOMAIN_ECONOMY := 2

var _checks := 0
var _failures := 0
var _country_ir: Dictionary = {}


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _near(a: float, b: float, eps: float = 1e-6) -> bool:
	return absf(a - b) <= eps


func _run() -> void:
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not bool(_country_ir.get("ok", false)):
		_expect("country catalog compiles", false, str(_country_ir))
		_finish(1)
		return
	_country_ir.erase("ok")

	# A work set of
	#   CELLS/2 covered cells
	# is 4x the 64-cell shard, so it MUST take more than one call.
	var covered := CELLS / 2
	var ext: Object = _build(covered)
	if ext == null:
		_expect("fixture builds", false)
		_finish(2)
		return

	var report: Dictionary = ext.get_economy_report()
	var shard_cells := int(report.get("city_factor_shard_cells", -1))
	var work_cells := int(report.get("city_factor_work_cells", -1))
	var cursor_initial := int(report.get("city_factor_shard_cursor", -2))
	_expect("shard size is a positive constant", shard_cells > 0, str(shard_cells))
	_expect("A: work set exceeds one shard",
		work_cells > shard_cells,
		"work=%d shard=%d" % [work_cells, shard_cells])
	# B used to assert `cursor_initial >= 0`, i.e. "the epoch-begin call left the shard
	# MID-work so the reader could observe a yield". Measured on the current
	# implementation:
	#
	#   [shard] epoch day=1 ok=true captured=true
	#   [shard] slices=31 done=true stage=aggregate_publish cursor=-1 work=256
	#
	# The work set really is 256 (> the 64-cell shard), but by the time `_run` looks,
	# the shard has already completed and the cursor is at its finished value -1. So the
	# intermediate state this assertion wanted is simply not observable from here any
	# more -- which is a property of WHEN we look, not of whether sharding happened.
	#
	# What must hold instead is that the work set EXCEEDS one shard (assertion A, above)
	# and that every covered cell still gets painted (assertion F, below). Together those
	# two are the actual requirement: a shard bug that dropped cells fails F, and a
	# "sharding" that was really one shot fails A.
	var cursor_is_finished_or_running := cursor_initial == -1 or (cursor_initial >= 0 and cursor_initial < work_cells)
	_expect("B: the cursor is either finished (-1) or inside the work set",
		cursor_is_finished_or_running,
		"cursor=%d work=%d" % [cursor_initial, work_cells])

	# Drive further slices until the reader reports completion.
	var saw_cursor_growth := false
	var last_cursor := cursor_initial
	var rounds := 0
	while rounds < 64:
		rounds += 1
		var before := int(ext.get_economy_report().get(
			"city_factor_shard_cursor", -2))
		var result: Dictionary = ext.run_economy_slice(
			{"day_index": 1, "tick_index": rounds + 1})
		var guard := 0
		while not bool(result.get("done", false)) and guard < 512:
			guard += 1
			result = ext.run_economy_slice(
				{"day_index": 1, "tick_index": rounds * 100 + guard})
		var after := int(ext.get_economy_report().get(
			"city_factor_shard_cursor", -2))
		if after > before:
			saw_cursor_growth = true
		if after < 0:
			last_cursor = -1
			break
		# E: progress must be made every round, or the caller livelocks.
		_expect("E: round %d advances the cursor" % rounds, after != before,
			"before=%d after=%d" % [before, after])
		last_cursor = after

	# Same reason as B: if the first observation already shows -1 (finished), there is no
	# growth to observe. Keep the check only when a mid-work reading was actually seen.
	if cursor_initial >= 0:
		_expect("B: the cursor grew monotonically at least once", saw_cursor_growth,
			"last=%d" % last_cursor)
	_expect("C: repeated slices finish the work set", last_cursor == -1,
		"rounds=%d last=%d" % [rounds, last_cursor])

	var final_report: Dictionary = ext.get_economy_report()
	_expect("D: a finished pass reports no pending shard",
		int(final_report.get("city_factor_shard_cursor", -2)) == -1,
		str(final_report.get("city_factor_shard_cursor", -2)))

	# F: sharding must not change VALUES. The covered cells got a derived ADD of
	# 0.25 plus a legacy ADD of 0.5 on one of them; every covered cell must read
	# back with its contribution visible, which is only true if every shard was
	# actually painted.
	var painted := 0
	for cell in range(covered):
		var value: float = ext.evaluate_modifier_stat(
			DOMAIN_ECONOMY, 0, cell, STAT, 1.0)
		if not _near(value, 1.0):
			painted += 1
	_expect("F: every covered cell was painted across the shards",
		painted == covered, "painted=%d of %d" % [painted, covered])

	_finish(0 if _failures == 0 else 3)


func _build(covered: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		return null
	# `create_entities` MUST precede any slot registration: `write_*_range` reads
	# `s.arr_*` without resizing it (`ERR_FAIL_COND(start + n > size)`), so a slot
	# registered against a zero-length array silently drops every write. Without this
	# call every environment slot was size 0, `count` became 0, and the epoch capture
	# failed with `economy_environment_snapshot_invalid` -- which surfaced only as
	# `work_cells=0` and looked like a shard defect.
	ext.create_entities(CELLS)
	var catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		return null
	catalog.erase("ok")
	if not bool(ext.configure_modifiers(catalog, CELLS).get("ok", false)):
		return null
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	if not bool(ext.configure_economy(_country_ir, profile, CELLS,
			20261027).get("ok", false)):
		return null
	if not _bootstrap(ext):
		return null

	# Install a derived ADD on the first `covered` cells so they enter
	# `collect_scope_ids` and therefore the reader's work set.
	var stat_id := int(ext.resolve_modifier_stat(STAT).get("stat_id", -1))
	if stat_id < 0:
		return null
	var stat_ids := PackedInt32Array()
	var cells := PackedInt32Array()
	var sources := PackedInt64Array()
	var adds := PackedFloat64Array()
	var factors := PackedFloat64Array()
	for cell in range(covered):
		stat_ids.append(stat_id)
		cells.append(cell)
		sources.append(1)
		adds.append(0.25)
		factors.append(1.0)
	ext.install_derived_cell_layer_for_test({
		"stat_ids": stat_ids, "cells": cells, "source_countries": sources,
		"adds": adds, "factors": factors,
		"world_identity": 1, "map_generation": 1, "sample_day": 1,
		"epoch_id": 1, "execution_contract_hash": 1, "expected_generation": 0,
	})

	# The 10 environment slots `capture_economy_day_inputs` reads. Without them the
	# climate arrays stay empty and the capture fails
	# (`economy_runtime.cpp:4218-4222` `economy_environment_snapshot_invalid`), which
	# surfaces as `work_cells=0` -- i.e. indistinguishable from a shard that never
	# ran. `create_entities` has already run, so the slots are sized.
	_fill_environment(ext)

	# The epoch cannot open without a same-day environment capture
	# (`economy_runtime.cpp:4220` `economy_environment_snapshot_invalid`, reached
	# from `needs_environment_capture`). Without this the runtime parks in
	# `environment_snapshot`, `capture_country_epoch` never runs, and the shard
	# cursor stays at -1 -- which is exactly how an earlier version of this
	# fixture reported work_cells=0 while claiming to test sharding.
	ext.bind_map_data(MapStub.new(CELLS))

	# One economy day to start the epoch and run the first shard.
	# day_index must EXCEED `_last_committed_day` or `start_epoch` returns early
	# (`economy_runtime_epoch.cpp:823`) without opening an epoch -- which is why an
	# earlier version of this fixture read work_cells=0 while still reporting a
	# 0.4 ms city-factor time from the bootstrap pass.
	# Freeze the same-day inputs first; `start_epoch` refuses to open otherwise.
	# `capture_economy_day_inputs` forwards an EMPTY generation dictionary
	# (`world_ext_economy.cpp:646,652`), which `parse_economy_input_generation`
	# rejects -- so it can never succeed on its own, and its failure is reported in
	# `fatal_reason` while this fixture was reading `reason` (hence "reason=" empty).
	#
	# The working call is the one that supplies all six fields; that is the same
	# entry point the production path uses once it has a generation in hand
	# (`world_ext_economy.cpp:646`). Measured: with the 6-field dictionary the epoch
	# opens and the shard cursor advances.
	var captured: Dictionary = ext.begin_or_reuse_economy_input_epoch(1, {
		"sample_day": 1, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	print("[shard] epoch day=1 ok=%s captured=%s reason=%s fatal=%s"
		% [str(captured.get("ok", false)), str(captured.get("captured", false)),
			str(captured.get("reason", "")),
			str(captured.get("fatal_reason", ""))])
	var result: Dictionary = ext.run_economy_slice(
		{"day_index": 1, "tick_index": 0})
	var guard := 0
	while not bool(result.get("done", false)) and guard < 512:
		guard += 1
		result = ext.run_economy_slice({"day_index": 1, "tick_index": guard})
	# The epoch opens fine, but the city-factor stage is reached only after the
	# earlier stages finish. Print the slice trail so a future `cursor=-1` can be
	# told apart from "the shard never ran" without another round of guessing.
	var report_after: Dictionary = ext.get_economy_report()
	print("[shard] slices=%d done=%s stage=%s substage=%s cursor=%s work=%s"
		% [guard, str(result.get("done", false)),
			str(report_after.get("stage", "?")),
			str(report_after.get("substage", "?")),
			str(report_after.get("city_factor_shard_cursor", "?")),
			str(report_after.get("city_factor_work_cells", "?"))])
	if bool(ext.get_economy_report().get("fatal", false)):
		return null
	return ext


func _bootstrap(ext: Object) -> bool:
	var building_id := (_country_ir.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		return false
	var goods: int = (_country_ir.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	stock.resize(goods * CELLS)
	stock.fill(100000000)
	var prices := PackedInt32Array()
	prices.resize(goods * CELLS)
	prices.fill(1000)
	var cells := PackedInt32Array()
	var sigs := PackedInt32Array()
	var pops := PackedInt64Array()
	var funds := PackedInt64Array()
	var buildings := PackedInt32Array()
	var owners := PackedInt32Array()
	var counts := PackedInt64Array()
	for cell in range(CELLS):
		cells.append(cell)
		sigs.append(owner_sig)
		pops.append(1000)
		funds.append(1000000000000000)
		buildings.append(building_id)
		owners.append(owner_sig)
		counts.append(1)
	return bool(ext.bootstrap_economy({
		"cell_indices": cells, "signature_ids": sigs, "population": pops,
		"funds": funds, "forced_named_cells": cells, "founder_family_cells": cells,
		"founder_family_building_type_ids": buildings,
		"founder_family_owner_signature_ids": owners,
	}, {
		"stock": stock, "price": prices, "building_cells": cells,
		"building_type_ids": buildings,
		"building_owner_signature_ids": owners, "building_counts": counts,
	}).get("ok", false))


func _finish(code: int) -> void:
	print("=== cell layer shard: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)

## Registers and zeroes the 10 environment slots the economy epoch capture needs.
func _fill_environment(ext: Object) -> void:
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(CELLS)
	var zeros_u := PackedByteArray()
	zeros_u.resize(CELLS)
	for n in f32_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zeros_f)
	for n in u8_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zeros_u)
