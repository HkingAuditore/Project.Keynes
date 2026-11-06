extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _checks := 0
var _failures := 0

func _init() -> void:
	call_deferred("_run_all")

func _run_all() -> void:
	_run()
	await _coordinator_boundary()
	print("in-flight save boundary: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("native extension available", false)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var ext: Object = DCWorldExt.new()
	var country = CountryFacadeScript.new()
	var packet := {
		"country_ids": PackedStringArray(["country.inflight"]),
		"country_names": PackedStringArray(["In-flight"]),
		"country_cash": PackedInt64Array([1000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 1]),
		"technology_indices": PackedInt32Array([compiled.technology_ids.find("tech.hunting")]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([compiled.good_ids.find("grain")]),
		"treasury_quantities": PackedInt64Array([50]),
	}
	var configured := country.configure(ext, 1, 620260909,
		load("res://data/country/default_country.tres"), compiled)
	_expect("country configures", bool(configured.get("ok", false)))
	if not bool(configured.get("ok", false)):
		return
	_expect("country bootstraps", bool(country.bootstrap(PackedByteArray([0]), packet).get("ok", false)))
	var handle := int(country.cell_summary(0).get("country_handle", 0))
	var begin: Dictionary = ext.begin_country_economy_treasury_spend(
		handle, PackedInt32Array([compiled.good_ids.find("grain")]),
		PackedInt64Array([10]), 0, 34, 8, 980001)
	var tx_id := int(begin.get("transaction_id", 0))
	var blocked := country.begin_save()
	_expect("save request is refused while the day is in flight",
		bool(begin.get("ok", false)) and tx_id > 0 and not bool(blocked.get("ok", true))
		and String(blocked.get("reason", "")) == "country_save_economy_asset_transaction_pending"
		and int(blocked.get("in_flight", 0)) == 1)
	var session := int(begin.get("session_epoch", 0))
	var generation := int(begin.get("country_generation", 0))
	var prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		tx_id, session, generation, 77, true, "")
	var committed: Dictionary = ext.commit_country_economy_treasury_spend(tx_id)
	var applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		tx_id, session, generation, 77, true, "")
	var after := country.begin_save()
	_expect("save becomes available only after commit and applied ACK",
		String(prepared.get("status_name", "")) == "peer_prepared"
		and String(committed.get("status_name", "")) == "awaiting_peer_applied"
		and String(applied.get("status_name", "")) == "completed"
		and bool(after.get("ok", false)))


func _coordinator_boundary() -> void:
	var coordinator: Node = load("res://tests/runtime/inflight_save_coordinator_fixture.gd").new()
	var host := WorldRuntimeHost.new()
	root.add_child(host)
	root.add_child(coordinator)
	coordinator._runtime_host = host
	var result: Dictionary = await coordinator.wait_boundary()
	_expect("coordinator waits through unpublished day before allowing capture",
		bool(result.get("ok", false)) and coordinator.observations == 4)
	coordinator.terminal = true
	coordinator.observations = 0
	result = await coordinator.wait_boundary()
	_expect("coordinator rejects terminal boundary before capture",
		not bool(result.get("ok", true)) and result.get("code") == "save_runtime_fault"
		and coordinator.observations == 1)
	coordinator._runtime_host = null
	coordinator.free()
	host.free()
