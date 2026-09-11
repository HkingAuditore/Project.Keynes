extends SceneTree

# K2-C Host protocol coverage. The test keeps the worker in SHADOW: it proves
# the Host owns a configured Country transport without granting Country
# authority or executing a real peer write. A real seal requires the normal
# Climate reference/input boundary; that cross-domain fixture is covered by
# the production host smoke, while Country intent/ACK semantics are covered by
# runtime_country_peer_bridge_test.gd.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("runtime country host protocol: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var ext: Object = DCWorldExt.new()
	var country = CountryFacadeScript.new()
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_expect("country configures", bool(country.configure(
		ext, 1, 20260909, load("res://data/country/default_country.tres"),
		compiled).get("ok", false)))
	var boot_packet := {
		"country_ids": PackedStringArray(["country.host_protocol"]),
		"country_names": PackedStringArray(["Host Protocol"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 1]),
		"technology_indices": PackedInt32Array([compiled.technology_ids.find("tech.hunting")]),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}
	_expect("country bootstraps", bool(country.bootstrap(
		PackedByteArray([0]), boot_packet).get("ok", false)))
	_expect("worker capture APIs are exported",
		ext.has_method("capture_country_pod_catalog")
		and ext.has_method("capture_country_runtime_snapshot")
		and ext.has_method("get_runtime_thread_report"))
	_expect("catalog capture publishes worker input",
		bool(ext.capture_country_pod_catalog().get("ok", false)))
	_expect("snapshot capture publishes worker input",
		bool(ext.capture_country_runtime_snapshot().get("ok", false)))

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 1000.0,
		"paused": false,
	})
	_expect("shadow Host starts", bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		return

	var intent: Dictionary = {}
	for _i in range(250):
		intent = ext.poll_country_worker_intent()
		if bool(intent.get("available", false)):
			break
		OS.delay_msec(2)
	_expect("Host reports a configured Country worker",
		bool(ext.get_runtime_thread_report().get(
			"country_worker_configured", false)))
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("report exposes Country worker session metadata",
		int(report.get("country_worker_session_epoch", 0)) > 0
		and int(report.get("country_worker_country_generation", 0)) >= 0)
	_expect("report exposes the worker admission watermark",
		int(report.get("country_worker_last_admitted_submit_order", -1)) >= 0)
	_expect("unsealed Host does not fabricate a Country boundary",
		int(report.get("country_worker_boundary_id", 0)) == 0
		and int(report.get("country_worker_pending_intents", 0)) == 0)

	var real_attempt: Dictionary = ext.service_country_worker_peer_adapter(64, false)
	_expect("real adapter is refused outside ACTIVE authority",
		not bool(real_attempt.get("ok", true))
		and String(real_attempt.get("code", "")) ==
			"country_worker_real_peer_adapter_not_authoritative")

	var replay: Dictionary = ext.service_country_worker_peer_adapter(64, true)
	_expect("SHADOW replay services an empty Host outbox",
		bool(replay.get("ok", false))
		and bool(replay.get("shadow_replay", false))
		and not bool(replay.get("real_adapter", true))
		and int(replay.get("replayed", 0)) == 0)
	var after_replay: Dictionary = ext.get_country_worker_protocol_status()
	_expect("replay returns a typed result and clears the queue",
		int(after_replay.get("pending_intents", -1)) == 0
		and int(after_replay.get("queued_intents", -1)) == 0)
	_expect("Country is not granted by a SHADOW probe",
		int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0)) & 0x004 == 0)
	_expect("Country terminal receipt API is exported",
		ext.has_method("poll_country_command_receipts"))
	_expect("Country Host terminal self-test is exported and passes",
		ext.has_method("runtime_country_host_receipt_self_test")
		and bool(ext.runtime_country_host_receipt_self_test()))
	_expect("Country Host rejection retry self-test is exported and passes",
		ext.has_method("runtime_country_host_rejection_self_test")
		and bool(ext.runtime_country_host_rejection_self_test()))
	_expect("Country SHADOW formula parity self-test is exported and passes",
		ext.has_method("runtime_country_shadow_parity_self_test")
		and bool(ext.runtime_country_shadow_parity_self_test()))
	_expect("Country Economy transport API is exported",
		ext.has_method("get_country_economy_asset_protocol_status")
		and ext.has_method("poll_country_economy_asset_request")
		and ext.has_method("submit_country_economy_asset_result")
		and ext.has_method("runtime_country_host_economy_protocol_self_test"))
	_expect("Country Economy transport self-test passes",
		bool(ext.runtime_country_host_economy_protocol_self_test()))
	_expect("Country Host handoff self-test is exported and passes",
		ext.has_method("runtime_country_host_handoff_self_test")
		and bool(ext.runtime_country_host_handoff_self_test()))
	var host_country: Dictionary = ext.get_country_cell_summary(0)
	ext.set_country_sync_store_writes_forbidden(true)
	var unique_writer: Dictionary = ext.begin_country_economy_fiscal_reserve(
		int(host_country.get("country_handle", 0)), 1000, 0, 0)
	_expect("unique writer forbids sync Country treasury writes",
		not bool(unique_writer.get("ok", true))
		and String(unique_writer.get("code", "")) == "country_worker_unique_writer")
	ext.set_country_sync_store_writes_forbidden(false)
	_expect("handoff prepare API is exported",
		ext.has_method("prepare_country_authority_handoff")
		and ext.has_method("install_country_authority_handoff")
		and ext.has_method("abort_country_authority_handoff")
		and ext.has_method("get_country_authority_handoff_status"))
	var handoff_status: Dictionary = ext.get_country_authority_handoff_status()
	_expect("handoff status reports sync owner by default",
		bool(handoff_status.get("ok", false))
		and int(handoff_status.get("owner", -1)) == 0)
	_expect("implemented mask includes Country after D12",
		int(ext.get_runtime_thread_report().get(
			"implemented_domain_mask", 0)) & 0x004 != 0)
	_expect("SHADOW session still does not grant Country authority",
		int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0)) & 0x004 == 0)
	var prepare_worker: Dictionary = ext.prepare_country_authority_handoff(1)
	_expect("prepare handoff to WORKER succeeds while drained",
		bool(prepare_worker.get("ok", false)))
	var aborted: Dictionary = ext.abort_country_authority_handoff()
	_expect("abort clears prepare without flipping owner",
		bool(aborted.get("ok", false))
		and not bool(aborted.get("prepare_pending", true))
		and int(aborted.get("owner", -1)) == 0)
	var epoch_before := int(ext.get_country_authority_handoff_status().get(
		"session_epoch", 0))
	_expect("prepare again after abort",
		bool(ext.prepare_country_authority_handoff(1).get("ok", false)))
	var installed: Dictionary = ext.install_country_authority_handoff()
	_expect("install SYNC→WORKER publishes checkpoint and flips owner",
		bool(installed.get("ok", false))
		and int(installed.get("owner", -1)) == 1
		and int(installed.get("session_epoch", 0)) > epoch_before
		and int(installed.get("implemented_domain_mask", 0)) & 0x004 != 0)
	var handoff_fiscal: Dictionary = ext.begin_country_economy_fiscal_reserve(
		int(ext.get_country_cell_summary(0).get("country_handle", 0)), 10, -1, -1, 0)
	_expect("handoff WORKER owner forbids sync treasury writes",
		not bool(handoff_fiscal.get("ok", true))
		and String(handoff_fiscal.get("code", "")) == "country_worker_unique_writer")
	var epoch_worker := int(ext.get_country_authority_handoff_status().get(
		"session_epoch", 0))
	_expect("prepare handoff back to SYNC",
		bool(ext.prepare_country_authority_handoff(0).get("ok", false)))
	var restored: Dictionary = ext.install_country_authority_handoff()
	_expect("install WORKER→SYNC restores sync owner without Country grant",
		bool(restored.get("ok", false))
		and int(restored.get("owner", -1)) == 0
		and int(restored.get("session_epoch", 0)) > epoch_worker
		and int(restored.get("implemented_domain_mask", 0)) & 0x004 != 0
		and int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0)) & 0x004 == 0)
	var economy_status: Dictionary = ext.get_country_economy_asset_protocol_status()
	_expect("empty Economy transport reports no pending work",
		bool(economy_status.get("ok", false))
		and economy_status.has("faulted_transactions")
		and economy_status.has("recovered_transactions")
		and economy_status.has("duplicate_messages")
		and int(economy_status.get("queued_requests", -1)) == 0
		and int(economy_status.get("pending_requests", -1)) == 0
		and int(economy_status.get("terminal_requests", -1)) == 0)
	var economy_empty: Dictionary = ext.poll_country_economy_asset_request()
	_expect("empty Economy request poll is explicit",
		bool(economy_empty.get("ok", false))
		and not bool(economy_empty.get("available", true))
		and String(economy_empty.get("code", "")) ==
			"country_economy_asset_request_empty")
	var empty_receipts: Dictionary = ext.poll_country_command_receipts(0, 8)
	_expect("empty Country terminal receipt poll is explicit",
		bool(empty_receipts.get("ok", false))
		and not bool(empty_receipts.get("available", true))
		and int(empty_receipts.get("count", -1)) == 0)

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var renamed: Dictionary = country.rename_country(
		handle, "Shadow Dual Write", 1, 1)
	_expect("SHADOW dual-write admits the sync command",
		bool(renamed.get("ok", false)))
	_expect("SHADOW command mirror reaches the Host queue",
		bool(renamed.get("shadow_mirror_ok", false))
		or int(ext.get_runtime_thread_report().get("command_queue_depth", 0)) > 0
		or int(renamed.get("shadow_request_ids", PackedInt64Array()).size()) > 0)
	_expect("SHADOW dual-write does not grant Country authority",
		int(ext.get_runtime_thread_report().get(
			"authoritative_domain_mask", 0)) & 0x004 == 0)

	ext.set_country_sync_store_writes_forbidden(true)
	var blocked_fiscal: Dictionary = ext.begin_country_economy_fiscal_reserve(
		handle, 10, -1, -1, 0)
	_expect("test unique-writer blocks sync fiscal writes",
		not bool(blocked_fiscal.get("ok", true))
		and String(blocked_fiscal.get("code", "")) == "country_worker_unique_writer")
	ext.set_country_sync_store_writes_forbidden(false)

	ext.request_runtime_stop()
	var stopped := false
	for _i in range(250):
		var stop_report: Dictionary = ext.get_runtime_thread_report()
		if String(stop_report.get("state", "")) in ["STOPPED", "FAULTED"]:
			stopped = true
			break
		OS.delay_msec(2)
	_expect("Host stops without a wait on simulation", stopped
		and int(ext.get_runtime_thread_report().get("main_wait_on_sim_us", -1)) == 0)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
