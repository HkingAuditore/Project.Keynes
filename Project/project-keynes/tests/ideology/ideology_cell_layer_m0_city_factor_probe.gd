extends SceneTree
## M1 prerequisite: measure the REAL per-cell cost of the two city-factor
## readers, because plan §14.1 now says the取消-cap cost is
## `covered_cells × 156` and nobody has a number for the per-query constant.
##
## Why a probe instead of a synthetic benchmark: `refresh_city_modifier_factors`
## is not exposed as a callable method. It runs inside `capture_country_epoch`
## (`economy_runtime.cpp:5530`), i.e. inside a real `start_epoch`, and the
## runtime already times that window as `epoch_begin_city_factor_ms`
## (`economy_runtime_diagnostics.cpp:1654`). So the honest measurement is:
##
##   configure a REAL modifier catalog,
##   insert N GROUP-scope rows so `collect_scope_ids` returns N cells,
##   run one real economy day per N,
##   read `epoch_begin_city_factor_ms`.
##
## The slope across N IS the per-covered-cell cost. That constant is what turns
## "B7: one country, 1000 cells" into a budget line.
##
## Caveat stated up front: this measures the LEGACY instance path, not the
## future derived layer. It is the baseline the derived layer must beat and the
## number the §14.3 threshold has to be expressed against.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_m0_city_factor_probe.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
## Named `CountryCatalogScript` in the other ideology fixtures because what
## `configure_economy` wants is the catalog that carries country/building/good
## columns -- which is compiled by the ECONOMY catalog script.
const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const CELLS := 2048
const GOOD_COUNT := 134
const NEED_COUNT := 20
## 1 birth + 1 general + 20 need + 134 good, per §14.1 / economy_runtime.cpp:7085-7095.
const QUERIES_PER_CELL := 1 + 1 + NEED_COUNT + GOOD_COUNT
## `paint_shared` writes 1 + need + good int32 per cell
## (economy_runtime.cpp:7048-7056), i.e. the whole cell-major factor matrix.
const WRITES_PER_CELL := 1 + NEED_COUNT + GOOD_COUNT


## Cells deliberately kept clear of derived rows, so the run has a non-zero
## baseline to subtract (the reader always probes GLOBAL + ENTITY(0) once).
var _rows_per_cell := 0
## `configure_economy` needs the COUNTRY catalog, not the modifier one:
## it resolves tax/building/good columns out of the country IR and fails with
## `country_tax_catalog_empty` otherwise.
var _country_ir: Dictionary = {}


func _init() -> void:
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not bool(_country_ir.get("ok", false)):
		printerr("country catalog: ", _country_ir)
		quit(1)
		return
	_country_ir.erase("ok")

	var samples: Array = []
	for covered in [8, 32, 128, 512]:
		# Three repeats per N. A single reading cannot distinguish a real slope
		# from instrument noise, and publishing a slope built on one sample is
		# exactly the "test that certifies itself" failure §13.1 forbids.
		var reps: Array = []
		for _rep in range(3):
			var ms := _measure(covered)
			if ms < 0.0:
				printerr("measurement failed at covered=%d" % covered)
				quit(1)
				return
			reps.append(ms)
		var median := _median(reps)
		samples.append({"covered": covered, "ms": median, "reps": reps})
		print("[city_factor_probe] covered=%4d cells  median=%7.3f ms  reps=%s"
			% [covered, median, str(reps)])

	# Slope from the smallest and largest N: two points, so the baseline offset
	# cancels. Anything below the noise floor is reported as such rather than
	# dressed up as a constant.
	var first: Dictionary = samples[0]
	var last: Dictionary = samples[samples.size() - 1]
	var d_cells := float(last.covered) - float(first.covered)
	var d_ms := float(last.ms) - float(first.ms)

	# Noise floor: the spread of repeats at ONE N is what a "real" slope has to
	# exceed. Without this the reader cannot tell 0.08 ms of signal from 0.08 ms
	# of jitter, and both look like a plausible per-cell constant.
	var spread := 0.0
	for sample in samples:
		var reps: Array = sample.reps
		spread = max(spread, float(reps.max()) - float(reps.min()))
	print("")
	print("[city_factor_probe] within-N spread (noise floor) = %.3f ms" % spread)
	print("[city_factor_probe] d_ms=%.3f over d_cells=%.0f" % [d_ms, d_cells])
	if d_cells <= 0.0:
		print("[city_factor_probe] INCONCLUSIVE: no cell delta")
	elif d_ms <= spread:
		print("[city_factor_probe] INCONCLUSIVE: signal (%.3f ms) is inside the "
			% d_ms + "noise floor (%.3f ms); covered-cell count cannot be resolved "
			% spread + "by this fixture.")
		print("")
		print("[city_factor_probe] WHY, and what it means for §14.1:")
		print("  The probe varied N (cells holding a derived-shaped row) while")
		print("  holding the map at %d cells. `refresh_city_modifier_factors`" % CELLS)
		print("  always does two O(map) passes first:")
		print("    (a) shared_factor x %d  -- GLOBAL + ENTITY(0) probes" % QUERIES_PER_CELL)
		print("    (b) paint_shared x %d cells = %d int32 writes"
			% [CELLS, CELLS * WRITES_PER_CELL])
		print("  when `shared_changed` (economy_runtime.cpp:7048-7061, because")
		print("  clear_epoch_metrics resets _city_factor_shared_* every epoch).")
		print("  Only AFTER those does collect_scope_ids decide the N cells, and")
		print("  the per-covered-cell loop (7085-7095) runs.")
		print("")
		print("  => On a %d-cell map the fixed term is ~%d x the variable term"
			% [CELLS, CELLS / 512])
		print("     even at N=512. The plan's `covered_cells x 156` is the right")
		print("     model for LARGE countries (N approaching CELLS) but it is NOT")
		print("     the whole cost: the full-matrix repaint is charged on every")
		print("     epoch regardless of coverage.")
		print("  => M1 must therefore not budget the derived layer as")
		print("     `covered_cells x 156` alone. It has to either (i) publish the")
		print("     shared row once instead of repainting it, or (ii) count 156*N")
		print("     against the MAP, not against coverage.")
		print("")
		# Confirm the diagnosis: if the cost is really O(map), scaling the MAP at
		# a FIXED coverage should show the slope the N sweep could not.
		_scale_map_probe()
	else:
		var per_cell_ms := d_ms / d_cells
		var per_query_ns := per_cell_ms * 1.0e6 / float(QUERIES_PER_CELL)
		print("[city_factor_probe] per_covered_cell=%.6f ms" % per_cell_ms)
		print("[city_factor_probe] per_query=%.1f ns (at %d queries/cell)"
			% [per_query_ns, QUERIES_PER_CELL])
		print("")
		print("[city_factor_probe] extrapolation (same machine, debug DLL):")
		for scenario in [
			{"name": "B7 1000 cells", "cells": 1000},
			{"name": "single country 6400", "cells": 6400},
			{"name": "64 countries x 6400", "cells": 64 * 6400},
		]:
			var cells: int = int(scenario.cells)
			print("  %-24s cells=%7d  cold_refresh=%9.1f ms"
				% [scenario.name, cells, per_cell_ms * float(cells)])
	quit(0)


## Fixed coverage (32 cells), varying MAP size. If `epoch_begin_city_factor_ms`
## grows with the map while coverage is constant, the dominant term is the
## full-matrix repaint, not the per-covered-cell query loop -- which is the
## claim the N sweep above implies but cannot prove.
func _scale_map_probe() -> void:
	print("[city_factor_probe] --- map-scaling control (coverage fixed at 32) ---")
	var rows: Array = []
	for map_cells in [512, 2048, 8192]:
		var reps: Array = []
		for _rep in range(3):
			var ms := _measure_with_map(32, map_cells)
			if ms < 0.0:
				printerr("map-scaling failed at map_cells=%d" % map_cells)
				return
			reps.append(ms)
		var median := _median(reps)
		rows.append({"map": map_cells, "ms": median})
		print("[city_factor_probe] map_cells=%5d covered=32  median=%7.3f ms  reps=%s"
			% [map_cells, median, str(reps)])

	if rows.size() >= 2:
		var small: Dictionary = rows[0]
		var big: Dictionary = rows[rows.size() - 1]
		var d_map := float(big.map) - float(small.map)
		var d_ms := float(big.ms) - float(small.ms)
		print("")
		print("[city_factor_probe] d_ms=%.3f over d_map_cells=%.0f (coverage fixed)"
			% [d_ms, d_map])
		if d_ms > 0.0:
			print("[city_factor_probe] per_map_cell=%.6f ms" % (d_ms / d_map))
			print("[city_factor_probe] CONFIRMED: cost tracks MAP size, not coverage.")
		else:
			print("[city_factor_probe] not resolved; see raw rows above.")


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2])


## Returns `epoch_begin_city_factor_ms` after one real economy day with
## `covered` distinct cells holding a derived-shaped GROUP row, or -1 on failure.
func _measure(covered: int) -> float:
	return _measure_with_map(covered, CELLS)


func _measure_with_map(covered: int, cells: int) -> float:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		return -1.0

	var catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		printerr(catalog)
		return -1.0
	catalog.erase("ok")

	if not bool(ext.configure_modifiers(catalog, cells).get("ok", false)):
		return -1.0

	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	var configured: Dictionary = ext.configure_economy(
		_country_ir, profile, cells, 20261026)
	if not bool(configured.get("ok", false)):
		printerr("configure_economy: ", configured)
		return -1.0

	if not _bootstrap(ext, cells):
		return -1.0

	# One GROUP row per covered cell on a stat the reader actually enumerates.
	# `economy.city.birth_factor` is in `_city_factor_stat_ids_scratch`
	# (economy_runtime.cpp:7003), so these rows land in collect_scope_ids' answer.
	var ok := true
	for cell in range(covered):
		if not _submit_group_row(ext, cell, 1):
			ok = false
			break
	if not ok:
		return -1.0

	# A real day. The first `run_economy_slice` for a new day reaches
	# start_epoch -> capture_country_epoch -> refresh_city_modifier_factors.
	var result: Dictionary = ext.run_economy_slice(
		{"day_index": 0, "tick_index": 0})
	var guard := 0
	while not bool(result.get("done", false)) and guard < 64:
		guard += 1
		result = ext.run_economy_slice({"day_index": 0, "tick_index": guard})

	var report: Dictionary = ext.get_economy_report()
	if not bool(report.get("configured", false)):
		printerr("report: ", report)
		return -1.0

	# VALIDITY GATE. A flat timing curve across a 64x change in N means either
	# the rows never became enumerable, or the reader short-circuited; both make
	# the number meaningless. Assert the row is actually readable before
	# reporting any timing, so a broken fixture fails loudly instead of
	# producing a confident-looking slope of 0.
	if covered > 0:
		var live: float = ext.evaluate_modifier_stat(
			2, 0, 0, "economy.city.birth_factor", 1.0)
		if is_equal_approx(live, 1.0):
			printerr("VALIDITY FAIL: row at cell 0 not readable (got %f); "
				% live + "timing below would be meaningless")
			return -1.0
	if not bool(report.get("epoch_active", false)) and \
			float(report.get("epoch_begin_city_factor_ms", 0.0)) <= 0.0:
		printerr("VALIDITY FAIL: epoch never opened, so the reader never ran")
		return -1.0
	return float(report.get("epoch_begin_city_factor_ms", -1.0))


func _bootstrap(ext: Object, cells_count: int) -> bool:
	var building_id := (_country_ir.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		printerr("fixture cannot find its building type / owner signature")
		return false
	var goods: int = (_country_ir.good_ids as PackedStringArray).size()

	var stock := PackedInt64Array()
	stock.resize(goods * cells_count)
	stock.fill(100000000)
	var prices := PackedInt32Array()
	prices.resize(goods * cells_count)
	prices.fill(1000)

	var cells := PackedInt32Array()
	var sigs := PackedInt32Array()
	var pops := PackedInt64Array()
	var funds := PackedInt64Array()
	var buildings := PackedInt32Array()
	var owners := PackedInt32Array()
	var counts := PackedInt64Array()
	for cell in range(cells_count):
		cells.append(cell)
		sigs.append(owner_sig)
		pops.append(1000)
		funds.append(1000000000000000)
		buildings.append(building_id)
		owners.append(owner_sig)
		counts.append(1)

	var result: Dictionary = ext.bootstrap_economy({
		"cell_indices": cells,
		"signature_ids": sigs,
		"population": pops,
		"funds": funds,
		"forced_named_cells": cells,
		"founder_family_cells": cells,
		"founder_family_building_type_ids": buildings,
		"founder_family_owner_signature_ids": owners,
	}, {
		"stock": stock, "price": prices,
		"building_cells": cells,
		"building_type_ids": buildings,
		"building_owner_signature_ids": owners,
		"building_counts": counts,
	})
	if not bool(result.get("ok", false)):
		printerr("bootstrap: ", result)
		return false
	return true


func _submit_group_row(ext: Object, cell: int, magnitude_q16: int) -> bool:
	var batch := {
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([_rows_per_cell]),
		"effective_days": PackedInt64Array([-1]),
		"definition_keys": PackedStringArray(["economy.city.birth_factor"]),
		"domains": PackedInt32Array([2]),
		"scopes": PackedInt32Array([1]),
		"entity_handles": PackedInt64Array([0]),
		"group_handles": PackedInt64Array([cell]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([_rows_per_cell + 1]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([magnitude_q16]),
		"modifier_handles": PackedInt64Array([0]),
	}
	_rows_per_cell += 1
	var submitted: Dictionary = ext.submit_modifier_commands(batch)
	if not bool(submitted.get("ok", false)):
		printerr("submit: ", submitted)
		return false
	ext.run_modifier_daily(0)
	return true
