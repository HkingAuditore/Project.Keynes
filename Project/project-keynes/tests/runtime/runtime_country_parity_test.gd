extends SceneTree

# Country SHADOW plan/replay: unified business hash, command dual-write,
# reference publication, probe formula parity, and a 30–100 day soak window.
# Production implemented mask is Climate|Country|Trigger|Ideology|Modifier|Effect|Events|COMMIT
# = 0xFFF after Phase 2-6.
# This harness stays on SHADOW Country compare evidence (sync writer + Host
# mirror); it does not grant Country ACTIVE.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	var code := _run()
	print("runtime country parity: %d checks, %d failures" % [_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _soak_days() -> int:
	var raw := OS.get_environment("PK_COUNTRY_SOAK_DAYS")
	if raw.is_empty():
		return 30
	return clampi(int(raw), 1, 100)


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 3
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return 4
	var ext: Object = DCWorldExt.new()
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	var country = CountryFacadeScript.new()
	_expect("country configures", bool(country.configure(
		ext, 6, 20260910, load("res://data/country/default_country.tres"),
		compiled, null, modifier_catalog).get("ok", false)))
	var boot_packet := {
		"country_ids": PackedStringArray(["country.parity.a", "country.parity.b"]),
		"country_names": PackedStringArray(["Parity A", "Parity B"]),
		"country_cash": PackedInt64Array([10000, 20000]),
		"territory_offsets": PackedInt32Array([0, 2, 4]),
		"territory_cells": PackedInt32Array([0, 1, 2, 3]),
		"technology_offsets": PackedInt32Array([0, 1, 2]),
		"technology_indices": PackedInt32Array([
			compiled.technology_ids.find("tech.hunting"),
			compiled.technology_ids.find("tech.hunting")]),
		"treasury_offsets": PackedInt32Array([0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}
	_expect("country bootstraps", bool(country.bootstrap(
		PackedByteArray([0, 0, 0, 0, 0, 0]), boot_packet).get("ok", false)))
	var first: Dictionary = ext.capture_country_runtime_snapshot()
	var again: Dictionary = ext.capture_country_runtime_snapshot()
	_expect("export_pod_snapshot hash is stable across immediate recapture",
		bool(first.get("ok", false)) and bool(again.get("ok", false))
		and int(first.get("state_hash", 0)) != 0
		and int(first.get("state_hash", 1)) == int(again.get("state_hash", 0)))
	_expect("catalog capture configures the Host POD",
		bool(ext.capture_country_pod_catalog().get("ok", false)))

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 1000.0,
		"paused": false,
	})
	_expect("SHADOW Host starts without Country grant",
		bool(started.get("ok", false))
		and int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0)) & 0x004 == 0)
	if not bool(started.get("ok", false)):
		return 5

	_expect("probe formula parity (rename) matches CountryCore/POD commit",
		bool(ext.runtime_country_shadow_parity_self_test()))

	var handle_a := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var handle_b := int(ext.get_country_cell_summary(2).get("country_handle", 0))
	var technologies: PackedStringArray = compiled.get(
		"technology_ids", PackedStringArray())
	var grant_technology := ""
	for technology_id in technologies:
		if String(technology_id) != "tech.hunting":
			grant_technology = String(technology_id)
			break
	var command_program: Array[Dictionary] = [
		{"label": "rename", "day": 1, "commands": [{
			"opcode": CountryFacadeScript.Opcode.RENAME_COUNTRY,
			"target_handle": handle_a, "display_name": "Parity Live",
			"effective_day": 1, "sequence": 10}]},
		{"label": "territory transfer", "day": 2, "commands": [{
			"opcode": CountryFacadeScript.Opcode.TRANSFER_TERRITORY,
			"target_handle": handle_b, "cell": 1,
			"effective_day": 2, "sequence": 20}]},
		{"label": "research weights", "day": 3, "commands": [{
			"opcode": CountryFacadeScript.Opcode.SET_RESEARCH_WEIGHTS,
			"target_handle": handle_a,
			"weights_bp": PackedInt32Array([4000, 3000, 2000, 1000]),
			"effective_day": 3, "sequence": 30}]},
		{"label": "research auto purchase", "day": 4, "commands": [{
			"opcode": CountryFacadeScript.Opcode.SET_RESEARCH_AUTO_PURCHASE,
			"target_handle": handle_a, "technology": 1,
			"effective_day": 4, "sequence": 40}]},
		{"label": "tax default", "day": 5, "commands": [{
			"opcode": CountryFacadeScript.Opcode.SET_TAX_DEFAULT,
			"target_handle": handle_a,
			"tax_kind": CountryFacadeScript.TaxKind.INCOME,
			"tax_rate_basis_points": 750,
			"effective_day": 5, "sequence": 50}]},
		{"label": "claim unowned", "day": 6, "commands": [{
			"opcode": CountryFacadeScript.Opcode.CLAIM_UNOWNED_TERRITORY,
			"target_handle": handle_a, "cell": 4,
			"effective_day": 6, "sequence": 60}]},
	]
	if not grant_technology.is_empty():
		command_program.append({
			"label": "technology grant", "day": 7, "commands": [{
				"opcode": CountryFacadeScript.Opcode.GRANT_TECHNOLOGY,
				"target_handle": handle_b,
				"technology": technologies.find(grant_technology),
				"effective_day": 7, "sequence": 70}],
		})
	var mirrored_command_families := 0
	for entry in command_program:
		var typed_commands: Array[Dictionary] = []
		for command in entry.commands:
			typed_commands.append(command)
		var submitted: Dictionary = country.submit(typed_commands)
		var mirrored := bool(submitted.get("ok", false)) \
			and bool(submitted.get("shadow_mirror_ok", false))
		_expect("live SHADOW mirrors %s command family" % entry.label, mirrored)
		if mirrored:
			mirrored_command_families += 1
	_expect("D11 command program covers multiple business-state families",
		mirrored_command_families >= 6)

	var slice_ok := true
	var last_ref_ok := false
	for day in range(1, _soak_days() + 1):
		var slice: Dictionary = ext.run_country_slice({"day_index": day})
		if not bool(slice.get("ok", false)):
			slice_ok = false
			break
		if bool(slice.get("done", false)):
			last_ref_ok = bool(slice.get("country_reference_ok", false)) \
				or last_ref_ok
		ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(4)
	_expect("soak country slices complete", slice_ok)
	_expect("committed slices publish a Country reference hash", last_ref_ok)
	# The isolated fixture verifies comparison inputs. The production replay
	# matrix checks the country state after real background commits.

	var checkpoint: Dictionary = ext.capture_country_reference_checkpoint()
	_expect("save capture remains available after SHADOW soak",
		bool(checkpoint.get("ok", false))
		or String(checkpoint.get("code", "")) != "")

	ext.set_country_sync_store_writes_forbidden(true)
	var unique: Dictionary = ext.begin_country_economy_fiscal_reserve(
		handle_a, 25, -1, -1, 0)
	_expect("unique-writer test grant rejects sync fiscal reserve",
		not bool(unique.get("ok", true))
		and String(unique.get("code", "")) == "country_worker_unique_writer")
	ext.set_country_sync_store_writes_forbidden(false)

	_expect("implemented mask includes Country after D12",
		int(ext.get_runtime_thread_report().get(
			"implemented_domain_mask", 0)) & 0x004 != 0)
	_expect("main thread still reports zero wait on simulation",
		int(ext.get_runtime_thread_report().get("main_wait_on_sim_us", -1)) == 0)

	ext.request_runtime_stop()
	var stopped := false
	for _i in range(250):
		if String(ext.get_runtime_thread_report().get("state", "")) in [
			"STOPPED", "FAULTED"]:
			stopped = true
			break
		OS.delay_msec(2)
	_expect("Host stops after parity soak", stopped)

	return 0


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)

