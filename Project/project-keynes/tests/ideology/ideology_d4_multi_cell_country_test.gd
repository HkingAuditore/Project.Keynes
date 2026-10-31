extends SceneTree
## D4: give a REAL generated world a country with more than 32 cells.
##
## WHY THIS EXISTS
##
## `generate_world` founds every country on a SINGLE cell (`[e2e] countries=3 widest=1
## above_old_cap=0`), so the migration that removed the 32-cell cap had no production case
## to point at. Two open items were blocked on exactly this:
##
##   * the ">32 real-world production sample" (§18.4), and
##   * the kind 14/15 end-to-end fixture (a hand-written MapData stub crashes the topology
##     capture, so only a REAL map can drive the ring walk).
##
## This fixture closes both preconditions: it generates a real world and then grows one
## country's territory through the DESIGNED command path
## (`COMMAND_CLAIM_UNOWNED_TERRITORY = 20`, compare-and-set on a neutral cell), so the
## result is produced by production code, not by poking columns.
##
## WHAT IT PINS
##
##   1. the world generates and a DCWorldExt is bound (abort if not -- everything else
##      is meaningless);
##   2. claims are ACCEPTED and the territory really grows past 32 cells;
##   3. the economy territory plane agrees with the count (two readers, one answer).
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_d4_multi_cell_country_test.gd

const PRODUCTION_WIDTH := 200
const PRODUCTION_HEIGHT := 200
const SEED := 20261028
## Comfortably past the old cap so ">32" is unambiguous.
const TARGET_CELLS := 48
const COMMAND_CLAIM_UNOWNED_TERRITORY := 20

var _clock: WorldClock
var _host: WorldRuntimeHost
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


func _require(label: String, ok: bool, detail: String = "") -> bool:
	_expect(label, ok, detail)
	return ok


func _run() -> void:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	_clock = clock

	var host := WorldRuntimeHost.new()
	host.map_width = PRODUCTION_WIDTH
	host.map_height = PRODUCTION_HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = false
	host.runtime_parity_forcing = false
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	_host = host
	# A child added during `_init()` is not in the tree yet, so `generate_world()`
	# returns silently.
	await process_frame
	host.configure(null, null, clock)

	var config := NewGameConfig.create_default()
	config.country.name = "D4 MultiCell"
	config.country.foreign_count = 2
	config.base.map_width = PRODUCTION_WIDTH
	config.base.map_height = PRODUCTION_HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game",
		"config": config.to_dictionary(),
	})
	if not _require("A: session configures", bool(session.get("ok", false)),
			str(session)):
		_finish(1)
		return

	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("A: production world generation succeeded", generator != null):
		_finish(2)
		return
	var ext = generator.get_data_core_world_ext()
	if not _require("A: production DCWorldExt is bound", ext != null):
		_finish(3)
		return

	var before: Dictionary = ext.get_country_territory_counts()
	print("[d4] before: countries=%s widest=%s above_old_cap=%s total=%s"
		% [str(before.get("country_count", "?")), str(before.get("widest", "?")),
			str(before.get("above_old_cap", "?")), str(before.get("total_cells", "?"))])
	if not _require("B: territory counts readable", bool(before.get("ok", false)),
			str(before)):
		_finish(4)
		return
	var widest_before := int(before.get("widest", 0))
	_expect("B: the generated world starts at or under the old cap (that is the premise)",
		widest_before <= 32, str(widest_before))

	# Find an owned cell so we can read its country handle.
	var cell_count := int(ext.get_country_cell_summary(0).get("cell_count", 0))
	if cell_count <= 0:
		cell_count = PRODUCTION_WIDTH * PRODUCTION_HEIGHT
	var owned_cell := -1
	var handle := 0
	var scan_limit: int = min(cell_count, 40000)
	for c in range(scan_limit):
		var summary: Dictionary = ext.get_country_cell_summary(c)
		if bool(summary.get("owned", false)):
			owned_cell = c
			handle = int(summary.get("country_handle", 0))
			break
	if not _require("C: found an owned cell to grow from", owned_cell >= 0,
			"scanned %d cells" % scan_limit):
		_finish(5)
		return
	print("[d4] growing from cell %d, country handle %d" % [owned_cell, handle])

	# Claim a run of nearby cells. Water and already-owned cells are rejected by the
	# runtime itself (`country_claim_target_invalid`), so we simply try and count what
	# lands -- no assumptions about the terrain.
	var stride := 1
	var candidates := PackedInt32Array()
	var reach: int = min(cell_count, 40000)
	var offset := 1
	while candidates.size() < TARGET_CELLS * 4 and offset < reach:
		var forward := owned_cell + offset * stride
		var backward := owned_cell - offset * stride
		if forward < reach:
			candidates.append(forward)
		if backward >= 0:
			candidates.append(backward)
		offset += 1

	var accepted := 0
	var rejected := 0
	for c in candidates:
		if accepted >= TARGET_CELLS:
			break
		var batch: Dictionary = _claim_batch(handle, int(c), 1)
		var result: Dictionary = ext.submit_country_commands(batch)
		if bool(result.get("ok", false)):
			accepted += 1
		else:
			rejected += 1
	print("[d4] claim attempts: accepted=%d rejected=%d" % [accepted, rejected])
	_expect("D: at least one claim was accepted", accepted > 0, str(accepted))

	# Commands are STAGED until a country day commits them.
	var advanced := 0
	var last_error := ""
	for day in range(1, 4):
		for slice in range(256):
			var r: Dictionary = ext.run_country_slice(
				{"day_index": day, "tick_index": slice})
			if bool(r.get("done", false)):
				advanced += 1
				break
			if not bool(r.get("ok", true)):
				last_error = String(r.get("reason", r.get("code", "")))
				break
	print("[d4] country day advances completed: %d (last_error=%s)"
		% [advanced, last_error])

	var after: Dictionary = ext.get_country_territory_counts()
	print("[d4] after: countries=%s widest=%s above_old_cap=%s total=%s"
		% [str(after.get("country_count", "?")), str(after.get("widest", "?")),
			str(after.get("above_old_cap", "?")), str(after.get("total_cells", "?"))])
	var widest_after := int(after.get("widest", 0))
	var above_after := int(after.get("above_old_cap", 0))

	# THE POINT OF THE FIXTURE.
	_expect("E: a real generated world now has a country ABOVE the old 32 cap",
		widest_after > 32 and above_after >= 1,
		"widest=%d above_old_cap=%d (was %d / 0)" % [widest_after, above_after,
			widest_before])

	# Two readers must agree: the counts report and the economy territory plane.
	var plane: Dictionary = ext.get_economy_territory_plane()
	print("[d4] plane: ok=%s cell_count=%s country_count=%s"
		% [str(plane.get("ok", "?")), str(plane.get("cell_count", "?")),
			str(plane.get("country_count", "?"))])
	_expect("F: the territory plane is readable and non-empty",
		bool(plane.get("ok", false)) and int(plane.get("cell_count", 0)) > 0,
		str(plane.get("cell_count", "?")))

	_finish(0 if _failures == 0 else 3)


## Mirrors `country_facade.gd:83-137`: every array the runtime reads must be present and
## the same length as `opcodes`.
func _claim_batch(handle: int, cell: int, day: int) -> Dictionary:
	_seq += 1
	return {
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


func _finish(code: int) -> void:
	print("=== D4 multi-cell country: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
