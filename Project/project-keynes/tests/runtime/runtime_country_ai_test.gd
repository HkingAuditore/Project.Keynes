extends SceneTree

## Country AI contract test on the synchronous Country slice path:
## real technology catalog, three countries (slot 0 is the player), the
## default AI catalog. Covers player exclusion, determinism, PROBE inertness
## and a mid-run pkai save/restore that must match the uninterrupted run.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryAiCatalogScript = preload("res://scripts/country/country_ai_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
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
	_run_ai_colonization_regression()


func _run_ai_colonization_regression() -> void:
	var colonizer := CountryAiCatalogScript.load_default()
	colonizer.think_days = 1
	colonizer.colonize_days = 1
	colonizer.colonize_min_reserve_days = 0
	colonizer.colonize_min_country_population = 1
	colonizer.colonize_min_population_per_cell = 0
	colonizer.colonize_essentials_floor = 0.0
	colonizer.colonize_hungry_share_max = 1.0
	var ai_compiled: Dictionary = colonizer.compile_native_catalog(73023)
	_expect("colonization AI catalog compiles", bool(ai_compiled.get("ok", false)))
	if not bool(ai_compiled.get("ok", false)):
		return
	var world := _world(ai_compiled.catalog, true)
	var ext: Object = world.ext
	var country_handle := int(world.handles[1])
	var map := MapData.new(CELLS, 1)
	for cell_index in range(CELLS):
		var cell := HexCell.new(cell_index, 0)
		cell.terrain = TerrainType.TERRAIN.PLAIN
		cell.landform = LandformType.LF.PLAIN
		map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	map.visible_arr.fill(1)
	map.explored_arr.fill(1)
	map.vision_revision = 1
	_expect("AI colonization map binds", bool(ext.bind_map_data(map)))
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	_expect("AI colonization modifier runtime configures",
		bool(ext.configure_modifiers(modifier_catalog, CELLS).get("ok", false)))
	var effect_catalog := EffectCatalogScript.new()
	_expect("AI colonization effect runtime configures",
		bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get("ok", false)))
	var economy_catalog := _catalog.duplicate(true)
	var birth_rates: PackedInt64Array = economy_catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	economy_catalog.signature_birth_rate_q32 = birth_rates
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_founding_choice_mode = "AUTO"
	profile.family_min_founder_people = 20
	profile.starvation_death_rate_q32 = 0
	_expect("AI colonization economy configures", bool(ext.configure_economy(
		economy_catalog, profile, CELLS, 73023).get("ok", false)))
	var neighbors := _line_neighbors()
	var terrain := PackedByteArray()
	terrain.resize(CELLS)
	terrain.fill(2)
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 2
	ext.capture_economy_trade_topology(neighbors, terrain, passable, costs, 1)
	var signatures: PackedStringArray = economy_catalog.signature_keys
	var forager := signatures.find("forager|default")
	var merchant := signatures.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize(CELLS * (economy_catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	var buildings := PackedInt64Array([1])
	var building_type := (economy_catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([4, 4]),
		"signature_ids": PackedInt32Array([forager, merchant]),
		"population": PackedInt64Array([500, 20]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
		"forced_named_cells": PackedInt32Array([4]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([4]),
		"building_type_ids": PackedInt32Array([building_type]),
		"building_owner_signature_ids": PackedInt32Array([forager]),
		"building_counts": buildings,
		"founder_family_cells": PackedInt32Array([4]),
		"founder_family_building_type_ids": PackedInt32Array([building_type]),
		"founder_family_owner_signature_ids": PackedInt32Array([forager]),
	})
	_expect("AI source family bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		print("AI colonization economy bootstrap=", boot)
		return
	var values := PackedInt32Array()
	values.resize(CELLS)
	values.fill(65536)
	ext.set_country_ai_topology(neighbors, values)
	var player_handles := PackedInt64Array([int(world.handles[0])])
	ext.set_country_ai_excluded_handles(player_handles)
	_expect("opening Country day commits", bool(ext.run_country_slice(
		{"day_index": 0, "tick_index": 0}).get("ok", false)))
	_expect("opening economy day publishes the colonization digest",
		_run_economy_day(ext, 0))
	var ai_day: Dictionary = ext.run_country_slice({"day_index": 1, "tick_index": 1})
	_expect("AI colonization decision commits", bool(ai_day.get("ok", false)))
	var decision_report: Dictionary = ext.get_country_ai_report()
	_expect("fixed seed produces an AI colonization intent",
		int(decision_report.get("colonization_intents", 0)) > 0)
	_expect("effective day creates an actual AI expedition",
		_run_economy_day(ext, 1)
		and int(ext.get_family_expeditions(country_handle, 0, 64).get("total", 0)) == 1)
	var receipts: Dictionary = ext.get_family_colonization_receipts(
		country_handle, 0, 64)
	var receipt_rows: Array = receipts.get("receipts", [])
	_expect("accepted AI command receipt names its owning country",
		int(receipts.get("count", 0)) > 0 and not receipt_rows.is_empty()
		and String(receipt_rows.back().get("code", "")) in ["STARTED", "PREPARING"])


func _run_economy_day(ext: Object, day: int) -> bool:
	var report: Dictionary = {}
	for tick in range(2048):
		report = ext.run_economy_slice({"day_index": day,
			"tick_index": day * 1000 + tick})
		if bool(report.get("fatal", false)):
			print("AI colonization economy day failed day=", day,
				" reason=", report.get("fatal_reason", ""))
			return false
		if bool(report.get("done", false)):
			return true
	print("AI colonization economy day did not finish day=", day)
	return false


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
	# Research conditions read observed signals; without any, nothing past the
	# starting technology is ever available and the AI has nothing to queue.
	var signal_count := (_catalog.get("research_signal_ids", PackedStringArray()) as PackedStringArray).size()
	var signal_offsets := PackedInt32Array([0])
	var signal_indices := PackedInt32Array()
	var signal_cells := PackedInt32Array()
	var signal_days := PackedInt64Array()
	for country_cell in [0, 4, 8]:
		for signal_index in range(signal_count):
			signal_indices.append(signal_index)
			signal_cells.append(country_cell)
			signal_days.append(0)
		signal_offsets.append(signal_indices.size())
	packet["research_signal_offsets"] = signal_offsets
	packet["research_signal_indices"] = signal_indices
	packet["research_signal_cells"] = signal_cells
	packet["research_signal_days"] = signal_days
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
