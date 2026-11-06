extends "res://tests/game/starter_settlement_soak_test.gd"

# Formal ACTIVE world with an explicit same-day read boundary. Ledger and
# whole economy chains are separate; neither claims all twelve domain states.
const GOLDEN_PATH := "res://tests/runtime/golden_day_hash_baseline.json"
const GOLDEN_DAYS := 8
const V2_PATH := "res://tests/runtime/golden_day_hash_baseline.v2.json"
const V3_PATH := "res://tests/runtime/golden_day_hash_baseline.v3.json"
# Preserve the seven-domain chain; Country is a separate v4 addition.
const EXCLUDED_DOMAINS := []
const DOMAINS := ["CLIMATE", "TRIGGER_INPUT", "IDEOLOGY",
	"EFFECT", "MODIFIER", "ECONOMY", "EVENTS"]


func _run() -> void:
	var legacy_only := OS.get_environment("PK_GOLDEN_LEGACY_ONLY") == "1"
	OS.set_environment("PK_GOLDEN_DOMAINS", "0" if legacy_only else "1")
	var config := NewGameConfig.create_default()
	config.country.name = "Golden Nation"
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	var host := WorldRuntimeHost.new()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	_expect("golden configures", bool(host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()}).get("ok", false)))
	await host.generate_world()
	var generator := host.get_generator()
	var start: Dictionary = generator.gameplay_start_report()
	var cell := int(start.get("cell", -1))
	var economy = generator.get_economy_facade()
	_expect("replay cadence is fixed", preload("res://tests/runtime/replay_cadence.gd").install(economy.world_ext()))
	_expect("golden has a populated starter", bool(start.get("ok", false)) and cell >= 0)
	if OS.get_environment("PK_GOLDEN_DIAGNOSTICS") == "1":
		var map := host.get_current_map()
		# Keep initialization evidence separate from the reviewed ledger chain.
		var resources: Dictionary = {}
		var reserves: Dictionary = {}
		for profile in ResourceProfileRegistry.ordered():
			var field := ResourceProfileRegistry.reserve_map_field(profile)
			var column: PackedFloat32Array = map.get(field)
			resources[String(profile.id)] = column.to_byte_array().hex_encode().sha256_text()
			reserves[String(profile.id)] = Array(column)
		print("GOLDEN_BOOTSTRAP=" + JSON.stringify({
			"resource_columns": resources, "resource_reserves": reserves,
			"country_signals": economy.world_ext().get_country_research_signal_snapshot(
				int(economy.world_ext().get_country_cell_summary(cell).get("country_handle", 0))),
			"flint_reserves": Array(map.res_flint_reserve_arr),
			"research_signal_offsets": Array(map.cell_research_signal_offsets),
			"research_signal_ids": Array(map.cell_research_signal_ids),
			"research_signal_values": Array(map.cell_research_signal_values)}))
	var rows: Array = []
	var country_chain := "keynes-country-v4:seed=20260727:days1-8"
	var domain_chain := "keynes-domains-v3:seed=20260727:days1-8"
	var whole_chain := "keynes-whole-economy-v2:seed=20260727:days1-8"
	var chain := "keynes-economy-golden-v1:seed=20260727:commands=bootstrap,days1-8"
	if cell >= 0 and economy != null and economy.is_configured():
		clock.pause(false)
		for day in range(1, GOLDEN_DAYS + 1):
			var report := await _run_day(host, economy, clock, day)
			if bool(report.get("done", false)):
				var settled := await _wait_golden_read_boundary(host, economy, day)
				_expect("golden same-day writeback %d" % day, settled)
				if not settled:
					break
			_expect("golden day %d committed" % day, bool(report.get("done", false)))
			if not bool(report.get("done", false)):
				break
			var runtime: Dictionary = generator.get_runtime_thread_report()
			var whole_hash := str(economy.world_ext().get_economy_state_hash())
			if OS.get_environment("PK_GOLDEN_DIAGNOSTICS") == "1":
				# These live compatibility hashes diagnose E1; they are not yet a
				# committed per-domain golden contract. In particular Country's
				# public getter still reads the retained synchronous store.
				print("GOLDEN_DIAGNOSTIC=" + JSON.stringify({"day": day,
					"whole_economy_hash": whole_hash,
					"country_hash": str(economy.world_ext().get_country_state_hash()),
					"runtime": runtime, "report": report}))
			_expect("golden full ACTIVE grant", int(runtime.get("authoritative_domain_mask", 0)) == 0xFFF)
			_expect("golden keeps shadow disabled", not bool(runtime.get("economy_shadow_probe_enabled", true)))
			var population: Dictionary = economy.population_cell_snapshot(cell)
			# Canonical ordered values; exclude timings, retries, instance IDs and
			# report-only generations. Never hash an arbitrary Dictionary ordering.
			var values: Array = [day, cell, int(population.get("population", -1))]
			for field in ["population_error", "money_error", "goods_error"]:
				_expect("golden ledger field " + field, report.has(field))
				values.append(int(report.get(field, -1)))
			for field in ["funds", "epoch_income", "epoch_expense", "cohort_count", "satisfaction_q16"]:
				_expect("golden population field " + field, population.has(field))
				values.append(int(population.get(field, -1)))
			var market: Dictionary = economy.market_cell_snapshot(cell)
			for field in ["stock", "price"]:
				_expect("golden market field " + field, market.has(field))
				values.append(Array(market.get(field, PackedInt64Array())))
			_expect("golden market contains goods", not (values[-1] as Array).is_empty())
			_expect("golden nonempty population", int(values[2]) > 0)
			var digest := JSON.stringify(values).sha256_text()
			chain = (chain + ":" + digest).sha256_text()
			whole_chain = (whole_chain + ":" + whole_hash).sha256_text()
			var row := {"day": day, "values": values, "economy_hash": digest, "chain": chain,
				"whole_economy_hash": whole_hash, "whole_economy_chain": whole_chain}
			if legacy_only:
				_expect("golden diagnostics disabled leaves report unchanged",
					not economy.world_ext().get_runtime_perf_snapshot(3).has("golden_domains"))
			if not legacy_only:
				var domains := await _read_domains(economy.world_ext(), day)
				var repeated := await _read_domains(economy.world_ext(), day)
				_expect("golden diagnostic read is repeatable", domains == repeated)
				_expect("golden diagnostic does not change economy",
					whole_hash == str(economy.world_ext().get_economy_state_hash()))
				_expect("golden all available domain summaries", domains.size() == DOMAINS.size() + 1)
				var ordered: Array = []
				for domain in DOMAINS:
					var summary: Dictionary = domains.get(domain, {})
					ordered.append([domain, summary.get("state_day", -2),
						summary.get("scope", ""), summary.get("hash", "")])
				domain_chain = (domain_chain + ":" + JSON.stringify(ordered)).sha256_text()
				var country: Dictionary = domains.get("COUNTRY", {})
				country_chain = (country_chain + ":" + JSON.stringify([
					"COUNTRY", country.get("state_day", -2), country.get("scope", ""),
					country.get("hash", "")])).sha256_text()
				row["country_chain"] = country_chain
				row["domain_hashes"] = domains
				row["domain_chain"] = domain_chain
			rows.append(row)
	_expect("golden sampled every day", rows.size() == GOLDEN_DAYS)
	var result := {"version": 2, "seed": 20260727, "scope": "starter_ledger_and_whole_economy_at_same_day_writeback",
		"commands": "formal bootstrap; run_daily_tick/finish_daily_tick days 1..8; no player mutations",
		"days": rows}
	# The old result remains an independent gate, even during candidate capture.
	var v2 = JSON.parse_string(FileAccess.get_file_as_string(V2_PATH))
	var old_result: Dictionary = result.duplicate(true)
	for row in old_result["days"]:
		row.erase("domain_hashes")
		row.erase("domain_chain")
		row.erase("country_chain")
	_expect("golden preserves v2 including every old value and chain",
		v2 == JSON.parse_string(JSON.stringify(old_result)))
	if not legacy_only:
		result["version"] = 3
		result["excluded_domains"] = ["COUNTRY"]
		result["scope"] += ";worker_domain_projections"
		var old_domains: Dictionary = result.duplicate(true)
		for row in old_domains["days"]:
			row["domain_hashes"].erase("COUNTRY")
			row.erase("country_chain")
		_expect("golden preserves v3 including every old domain and chain",
			JSON.parse_string(FileAccess.get_file_as_string(V3_PATH)) ==
			JSON.parse_string(JSON.stringify(old_domains)))
		result["version"] = 4
		result["excluded_domains"] = EXCLUDED_DOMAINS
	print("GOLDEN_RESULT=" + JSON.stringify(result))
	if OS.get_environment("PK_GOLDEN_CAPTURE") != "1":
		var baseline = JSON.parse_string(FileAccess.get_file_as_string(V2_PATH if legacy_only else GOLDEN_PATH))
		# JSON decodes numbers as floats. Normalize both sides through the same
		# codec before deep Dictionary comparison; hashes remain exact strings.
		_expect("golden matches reviewed baseline", baseline != null
			and baseline == JSON.parse_string(JSON.stringify(result)))
	_expect("golden closes", bool((await host.close_world()).get("ok", false)))
	host.free()
	clock.free()
	_finish()


func _wait_golden_read_boundary(host: WorldRuntimeHost, economy, day: int) -> bool:
	# Do not submit another date while sampling. Consume the existing protected
	# writeback, then require the worker and its compatibility view to agree.
	for _slice in range(MAX_SLICES_PER_DAY):
		host._consume_modifier_worker_snapshot_if_authoritative()
		var runtime: Dictionary = host.get_generator().get_runtime_thread_report()
		var modifier: Dictionary = economy.world_ext().get_modifier_report()
		if int(runtime.get("simulation_committed_day", -1)) == day \
				and int(runtime.get("worker_day_inflight", -1)) == 0 \
				and int(host._modifier_worker_snapshot_generation) == int(runtime.get(
					"modifier_pod_snapshot_generation", -1)) \
				and int(modifier.get("current_day", -1)) == day:
			return true
		await process_frame
	return false


func _read_domains(world, day: int) -> Dictionary:
	for _slice in range(MAX_SLICES_PER_DAY):
		var report: Dictionary = world.get_runtime_perf_snapshot(3).get("golden_domains", {})
		if bool(report.get("ready", false)) and int(report.get("day", -1)) == day:
			var all_domains: Dictionary = report.get("domains", {})
			_expect("golden domain inventory", all_domains.size() == DOMAINS.size() + 1)
			for excluded in EXCLUDED_DOMAINS:
				_expect("golden excluded domain remains observable", all_domains.has(excluded))
				if OS.get_environment("PK_GOLDEN_DIAGNOSTICS") == "1":
					print("GOLDEN_DOMAIN_EXCLUDED=" + JSON.stringify({"day": day,
						"domain": excluded, "summary": all_domains.get(excluded, {})}))
				all_domains.erase(excluded)
			return all_domains
		await process_frame
	return {}
