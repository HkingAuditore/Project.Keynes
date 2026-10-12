extends SceneTree

## Country AI contract test on the synchronous Country slice path:
## real technology catalog, three countries (slot 0 is the player), the
## default AI catalog. Covers player exclusion, determinism, PROBE inertness
## and a mid-run pkai save/restore that must match the uninterrupted run.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryAiCatalogScript = preload("res://scripts/country/country_ai_catalog.gd")
const CELLS := 9
const DAYS := 60
const RESTORE_DAY := 25

var failures := 0
var checks := 0
var _catalog: Dictionary = {}
var _hunting := -1

func _init() -> void:
	_run()
	print("runtime country AI: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	OS.set_environment(CountryAiCatalogScript.MODE_ENV, "")
	OS.set_environment(CountryAiCatalogScript.DIFFICULTY_ENV, "")
	var self_test_ext := DCWorldExt.new()
	_expect("country AI native self-test", self_test_ext.has_method("runtime_country_ai_self_test")
		and bool(self_test_ext.runtime_country_ai_self_test()))
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	_catalog = compiled.duplicate(true)
	_catalog.erase("ok")
	_hunting = (compiled.technology_ids as PackedStringArray).find("tech.hunting")
	var ai_compiled: Dictionary = CountryAiCatalogScript.load_default().compile_native_catalog(4242)
	_expect("default AI catalog compiles", bool(ai_compiled.get("ok", false)))
	if not bool(ai_compiled.get("ok", false)):
		return
	var ai_catalog: Dictionary = ai_compiled.catalog

	var unarmed := _world(ai_catalog, false)
	_run_days(unarmed.ext, 1, 10)
	var unarmed_report: Dictionary = unarmed.ext.get_country_ai_report()
	_expect("AI without player handles stays unarmed and silent",
		not bool(unarmed_report.get("armed", true))
		and int(unarmed_report.get("commands_emitted", -1)) == 0)

	var a := _world(ai_catalog, true)
	var b := _world(ai_catalog, true)
	var blob := PackedByteArray()
	for day in range(1, DAYS + 1):
		_run_days(a.ext, day, day)
		_run_days(b.ext, day, day)
		if day == RESTORE_DAY:
			blob = a.ext.encode_country_ai_state()
	var report_a: Dictionary = a.ext.get_country_ai_report()
	var report_b: Dictionary = b.ext.get_country_ai_report()
	_expect("AI controls exactly the two foreign countries",
		int(report_a.get("controlled", 0)) == 2 and int(report_a.get("excluded", 0)) == 1)
	_expect("AI emitted commands and none were rejected",
		int(report_a.get("commands_emitted", 0)) > 0
		and int(report_a.get("commands_rejected", -1)) == 0)
	_expect("same seed yields identical AI state and command stream",
		int(report_a.state_hash) == int(report_b.state_hash)
		and int(report_a.command_hash) == int(report_b.command_hash))
	var decisions: Array = a.ext.poll_country_ai_decisions(0, 4096).get("decisions", [])
	var player_touched := false
	var modules := {}
	for row in decisions:
		player_touched = player_touched or int(row.handle) == int(a.handles[0])
		modules[String(row.module)] = true
	_expect("player country never receives an AI decision", not player_touched)
	_expect("strategy, research and tax modules all ran",
		modules.has("strategy") and modules.has("research") and modules.has("tax"))
	var player_tax: Dictionary = a.ext.get_country_tax_policy_snapshot(int(a.handles[0]))
	var foreign_tax: Dictionary = a.ext.get_country_tax_policy_snapshot(int(a.handles[1]))
	_expect("player tax defaults untouched, foreign defaults set by personality",
		int((player_tax.default_rates as PackedInt32Array)[0]) == 0
		and int((foreign_tax.default_rates as PackedInt32Array)[0]) > 0)
	var player_research: Dictionary = a.ext.get_country_research_snapshot(int(a.handles[0]))
	var foreign_research: Dictionary = a.ext.get_country_research_snapshot(int(a.handles[1]))
	_expect("foreign research queue is planned, player queue is empty",
		_queued_count(foreign_research) > 0 and _queued_count(player_research) == 0)
	var snapshot: Dictionary = a.ext.get_country_ai_country_snapshot(int(a.handles[1]))
	_expect("per-country AI snapshot exposes personality and agenda",
		bool(snapshot.get("ok", false)) and not String(snapshot.get("personality", "")).is_empty()
		and not String(snapshot.get("agenda", "")).is_empty())
	var records: Array = a.ext.drain_country_ai_record_rows(4096).get("rows", [])
	_expect("country_ai_record rows are produced per think", records.size() > 0)

	# Save at RESTORE_DAY, reload into a world that reached the same Country
	# state, continue, and compare with the uninterrupted run.
	var c := _world(ai_catalog, true)
	_run_days(c.ext, 1, RESTORE_DAY)
	var reconfigured: Dictionary = c.ext.configure_country_ai(ai_catalog)
	c.ext.set_country_ai_topology(_line_neighbors(), PackedInt32Array())
	var restored: Dictionary = c.ext.restore_country_ai_state(blob)
	# committed_day is the last think day, so it may trail the save day.
	_expect("pkai restores into a reconfigured runtime",
		bool(reconfigured.get("ok", false)) and bool(restored.get("ok", false))
		and int(restored.get("committed_day", -1)) > RESTORE_DAY - 5
		and int(restored.get("committed_day", -1)) <= RESTORE_DAY)
	_run_days(c.ext, RESTORE_DAY + 1, DAYS)
	var report_c: Dictionary = c.ext.get_country_ai_report()
	_expect("save/load continuation matches the uninterrupted AI state",
		int(report_c.state_hash) == int(report_a.state_hash))
	_expect("save/load continuation matches Country research and tax outcomes",
		_queued_count(c.ext.get_country_research_snapshot(int(c.handles[2])))
			== _queued_count(a.ext.get_country_research_snapshot(int(a.handles[2])))
		and (c.ext.get_country_tax_policy_snapshot(int(c.handles[2])).default_rates as PackedInt32Array)
			== (a.ext.get_country_tax_policy_snapshot(int(a.handles[2])).default_rates as PackedInt32Array))
	var other_catalog := ai_catalog.duplicate(true)
	other_catalog["seed"] = 4243
	var mismatched := _world(other_catalog, false)
	var rejected: Dictionary = mismatched.ext.restore_country_ai_state(blob)
	_expect("pkai from another catalog is rejected", not bool(rejected.get("ok", true))
		and String(rejected.get("code", "")) == "catalog_hash_mismatch")

	var probe_catalog := ai_catalog.duplicate(true)
	probe_catalog["mode"] = "PROBE"
	var probe := _world(probe_catalog, true)
	_run_days(probe.ext, 1, 20)
	var probe_report: Dictionary = probe.ext.get_country_ai_report()
	var probe_tax: Dictionary = probe.ext.get_country_tax_policy_snapshot(int(probe.handles[1]))
	_expect("PROBE records decisions but changes no Country state",
		int(probe_report.get("countries_thought", 0)) > 0
		and int(probe_report.get("commands_emitted", -1)) == 0
		and int((probe_tax.default_rates as PackedInt32Array)[0]) == 0
		and _queued_count(probe.ext.get_country_research_snapshot(int(probe.handles[1]))) == 0)


func _world(ai_catalog: Dictionary, arm: bool) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	var configured: Dictionary = ext.configure_country(_catalog, profile, CELLS, 17)
	var packet := {
		"country_ids": PackedStringArray(["country.player", "country.foreign.001", "country.foreign.002"]),
		"country_names": PackedStringArray(["Player", "Foreign A", "Foreign B"]),
		"country_cash": PackedInt64Array([2500000000000, 2500000000000, 2500000000000]),
		"territory_offsets": PackedInt32Array([0, 1, 2, 3]),
		"territory_cells": PackedInt32Array([0, 4, 8]),
		"technology_offsets": PackedInt32Array([0, 1, 2, 3]),
		"technology_indices": PackedInt32Array([_hunting, _hunting, _hunting]),
		"treasury_offsets": PackedInt32Array([0, 0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}
	# Discover the whole tree so availability is decided by prerequisites and
	# research conditions alone, like a mid-game country.
	var technology_count := (_catalog.technology_ids as PackedStringArray).size()
	var discovered := PackedInt32Array()
	var discovered_offsets := PackedInt32Array([0])
	for _country in range(3):
		for index in range(technology_count):
			discovered.append(index)
		discovered_offsets.append(discovered.size())
	packet["discovered_technology_offsets"] = discovered_offsets
	packet["discovered_technology_indices"] = discovered
	var water := PackedByteArray()
	water.resize(CELLS)
	var bootstrapped: Dictionary = ext.bootstrap_country(packet, water)
	if not bool(configured.get("ok", false)) or not bool(bootstrapped.get("ok", false)):
		_fail("country world setup failed: %s %s" % [str(configured), str(bootstrapped)])
	var handles := PackedInt64Array()
	for cell in [0, 4, 8]:
		handles.append(int(ext.get_country_cell_summary(cell).get("country_handle", 0)))
	var ai_configured: Dictionary = ext.configure_country_ai(ai_catalog)
	if not bool(ai_configured.get("ok", false)):
		_fail("AI configure failed: %s" % str(ai_configured))
	ext.set_country_ai_topology(_line_neighbors(), PackedInt32Array())
	if arm:
		ext.set_country_ai_excluded_handles(PackedInt64Array([handles[0]]))
	return {"ext": ext, "handles": handles}


func _run_days(ext: Object, first: int, last: int) -> void:
	for day in range(first, last + 1):
		var result: Dictionary = ext.run_country_slice({"day_index": day, "tick_index": day})
		if not bool(result.get("ok", false)):
			_fail("country slice failed day=%d %s" % [day, str(result)])
			return


func _line_neighbors() -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell in range(CELLS):
		out.append_array(PackedInt32Array([
			cell + 1 if cell + 1 < CELLS else -1, -1, -1,
			cell - 1 if cell > 0 else -1, -1, -1]))
	return out


func _queued_count(research: Dictionary) -> int:
	var count := 0
	for state in research.get("technology_states", PackedInt32Array()):
		if int(state) == 3:
			count += 1
	return count


func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	failures += 1
	push_error("[FAIL] " + label)
