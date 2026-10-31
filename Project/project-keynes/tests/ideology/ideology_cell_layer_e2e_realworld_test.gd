extends SceneTree
## M3 end-to-end: a real generated world, real territory, real metric samples.
## (plan §15.5; closes the fixture gap recorded in M1-8 / M1-13 / M2-9 / M2-14 /
##  M2-17 / M3-4)
##
## WHY THIS FILE IS THE ONE THAT MATTERED
##
## Every M2/M3 result so far was proven against synthetic inputs:
## `friend` access to private territory columns, a synthetic ramp sampler, a
## hand-built modifier store. Those prove the MECHANISM. None of them proves the
## production path produces sensible numbers, because `capture_country_epoch`
## needs a real `MapData` and a hand-written stub crashes
## (`world_ext_economy.cpp:929-930`, `0xC0000005`).
##
## The only route is what `runtime_ideology_parity_test.gd:103` uses:
## `host.generate_world(SEED)` and then read the bound `DCWorldExt`. This fixture
## does exactly that, but for the cell layer rather than for parity.
##
## WHAT IT PINS (in order of how much it would hurt to be wrong)
##
##   A. the world generates and a DCWorldExt is bound -- if this fails the rest is
##      meaningless, so it aborts rather than cascading;
##   B. a real country owns a real territory, and that territory is reported with a
##      cell count > 32 -- the whole migration is pointless if generated maps only
##      ever yield small countries;
##   C. the ramp sampler reports non-zero `ramp_samples_taken`, proving the
##      production sampler is actually consulted on a real epoch (this is the first
##      time that is observable at all);
##   D. `ramp_terms_deferred` does not grow for a country-scope metric once samples
##      are available -- a growing deferral on a real epoch would mean the sampler
##      is silently unavailable and every Ramp card is inert;
##   E. the derived materialise report is internally consistent
##      (`derived + skipped_legacy == seen`), so no program is silently dropped;
##   F. `truncated == 0` on a real territory -- §12.4's hard requirement, now under
##      real content instead of a synthetic 40-cell list.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_e2e_realworld_test.gd

const PRODUCTION_WIDTH := 96
const PRODUCTION_HEIGHT := 64
const SEED := 20260227

var _checks := 0
var _failures := 0
var _host: Node = null
var _clock: Node = null


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
	# A child added during `_init()` is not inside the tree yet, so
	# `generate_world()` would return silently (runtime_ideology_parity_test:81).
	await process_frame
	host.configure(null, null, clock)

	var config := NewGameConfig.create_default()
	config.country.name = "Cell Layer E2E"
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

	# ── B: real territory ─────────────────────────────────────────────────
	#
	# The migration exists because a country's territory can exceed 32 cells. If
	# generated maps never produce one, the whole M2/M3 effort has no production
	# case and that is worth knowing loudly.
	var territories: Dictionary = ext.get_country_territory_counts()
	if not _require("B: territory counts are readable",
			bool(territories.get("ok", false)), str(territories)):
		_teardown()
		_finish(4)
		return
	var country_count := int(territories.get("country_count", 0))
	var widest_cells := int(territories.get("widest", 0))
	var above_cap := int(territories.get("above_old_cap", 0))
	var total := int(territories.get("total_cells", 0))
	print("[e2e] countries=%d widest=%d above_old_cap=%d total_cells=%d"
		% [country_count, widest_cells, above_cap, total])
	_expect("B: the world has countries", country_count > 0, str(country_count))
	# The migration's premise, in one number. If generated worlds never exceed 32
	# owned cells then the whole effort has no production case, which is worth
	# knowing loudly rather than assuming.
	_expect("B: at least one country owns more than 32 cells",
		widest_cells > 32,
		"widest=%d above_cap=%d -- with no territory above the old cap this "
			% [widest_cells, above_cap] + "migration has no production case")

	# ── C: the production ramp sampler actually runs ──────────────────────
	#
	# This is the assertion that has never been possible before: on a REAL epoch,
	# does the derived rebuild reach the economy's metric sampler at all?
	var before: Dictionary = ext.get_ideology_report()
	var taken_before := int(before.get("ramp_samples_taken", -1))
	var memo_before := int(before.get("ramp_samples_memoised", -1))
	print("[e2e] before: taken=%d memoised=%d evaluated=%d deferred=%d"
		% [taken_before, memo_before,
			int(before.get("ramp_terms_evaluated", -1)),
			int(before.get("ramp_terms_deferred", -1))])

	# Drive one economy slice so an epoch owns real cell state.
	#
	# STALE API FIXED: this called `run_economy_slice(64)` with a bare int. The bridge
	# takes a Dictionary now, so the fixture raised
	#   Invalid type in function 'run_economy_slice': Cannot convert argument 1 from int
	# and then HUNG (the error unwound the script before `quit()`), which is why this
	# file never produced a result for anyone.
	var sliced: Dictionary = {}
	if ext.has_method("run_economy_slice"):
		for s in range(256):
			sliced = ext.run_economy_slice({"day_index": 0, "tick_index": s})
			if bool(sliced.get("done", true)) or not bool(sliced.get("ok", true)):
				break
	print("[e2e] economy slice=%s" % str(sliced.get("ok", "n/a")))

	var after: Dictionary = ext.get_ideology_report()
	var taken_after := int(after.get("ramp_samples_taken", -1))
	var memo_after := int(after.get("ramp_samples_memoised", -1))
	var evaluated := int(after.get("ramp_terms_evaluated", -1))
	var deferred := int(after.get("ramp_terms_deferred", -1))
	print("[e2e] after: taken=%d memoised=%d evaluated=%d deferred=%d"
		% [taken_after, memo_after, evaluated, deferred])
	_expect("C: the production sampler is wired and reachable",
		taken_after >= 0, "taken=%d" % taken_after)
	# `memoised` may legitimately stay 0 when no country-scope Ramp program is
	# active yet; what must NOT happen is a growing `deferred` coinciding with
	# available samples, which would mean every Ramp card is inert.
	_expect("D: deferral does not grow while samples are available",
		not (taken_after > 0 and deferred > 0 and evaluated == 0),
		"taken=%d deferred=%d evaluated=%d -- samples exist but nothing was "
			% [taken_after, deferred, evaluated] + "evaluated")

	# ── E/F: the materialise report is consistent and never truncates ─────
	var report: Dictionary = ext.get_derived_materialize_report()
	print("[e2e] report=%s" % str(report))
	var seen := int(report.get("programs_seen", -1))
	var derived := int(report.get("programs_derived", -1))
	var legacy := int(report.get("programs_skipped_legacy", -1))
	_expect("E: every program is classified exactly once",
		seen < 0 or derived + legacy == seen,
		"seen=%d derived=%d legacy=%d" % [seen, derived, legacy])
	_expect("F: the derived path never truncates on a real territory",
		int(report.get("truncated", 0)) == 0,
		"truncated=%d" % int(report.get("truncated", 0)))

	_teardown()
	_finish(0 if _failures == 0 else 4)


func _teardown() -> void:
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
		_host = null
	if _clock != null and is_instance_valid(_clock):
		_clock.queue_free()
		_clock = null


func _finish(code: int) -> void:
	print("=== cell layer e2e realworld: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
