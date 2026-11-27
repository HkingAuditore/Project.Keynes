extends RefCounted

## Coordinates recording, persistence, and committed event delivery.

const EconomyFacadeDisplayScript = preload(
	"res://scripts/economy/economy_facade_display.gd")


static func report(host) -> Dictionary:
	return host._world_ext.get_economy_report() if host._configured else {"configured": false}


static func start_csv_recording(host, config: Dictionary) -> Dictionary:
	return host._world_ext.start_economy_csv_recording(config) if host._world_ext != null else {}


static func request_stop_csv_recording(host) -> Dictionary:
	return host._world_ext.request_stop_economy_csv_recording() if host._world_ext != null else {}


static func csv_recording_status(host) -> Dictionary:
	return host._world_ext.get_economy_csv_recording_status() if host._world_ext != null else {}


static func begin_forensics_save(host, chunk_bytes: int) -> Dictionary:
	return host._world_ext.begin_economy_forensics_save(chunk_bytes) if host._world_ext != null else {
		"ok": false, "reason": "economy_provider_missing"}


static func read_forensics_save_chunk(host, chunk_bytes: int) -> PackedByteArray:
	return host._world_ext.read_economy_save_chunk(chunk_bytes) if host._world_ext != null else PackedByteArray()


static func end_forensics_save(host) -> Dictionary:
	return host._world_ext.end_economy_save() if host._world_ext != null else {
		"ok": false, "reason": "economy_provider_missing"}

## Lightweight country/class satisfaction aggregate used by presentation systems.
## This is a committed read and is intentionally separate from the full economy
## diagnostic report, which can contain large transient counters.


static func country_class_opinion_snapshot(host) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "country class opinion snapshot unavailable"}
	return host._world_ext.get_country_class_opinion_snapshot()


static func native_catalog(host) -> Dictionary:
	return host._catalog.duplicate(false)


static func signature_id(host, profession_id: StringName, ethnicity_id: StringName) -> int:
	var key := "%s|%s" % [String(profession_id), String(ethnicity_id)]
	var keys: PackedStringArray = host._catalog.get("signature_keys", PackedStringArray())
	return keys.find(key)


static func good_ids(host) -> PackedStringArray:
	return (host._catalog.get("good_ids", PackedStringArray()) as PackedStringArray).duplicate()


static func profession_ids(host) -> PackedStringArray:
	return (host._catalog.get("profession_ids", PackedStringArray()) as PackedStringArray).duplicate()


static func building_type_ids(host) -> PackedStringArray:
	return (host._catalog.get("building_type_ids", PackedStringArray()) as PackedStringArray).duplicate()

## Cold-path bootstrap view of the same compiled columns consumed by the native runtime.
## This deliberately exposes only finance inputs; runtime authority remains in C++.


static func bootstrap_finance_columns(host) -> Dictionary:
	var result := {}
	for key in [
		"good_ids", "good_default_price", "good_inventory_target_ratios_q16",
		"good_merchant_buy_factor_q16", "good_monetary_issue_values",
		"good_technology_tag_offsets", "good_technology_tags",
		"plan_ids", "plan_need_offsets", "need_ids", "need_living_cost_weights_q16",
		"need_stable_ids", "need_base_qty_per_person", "need_quantity_env_curve_ids",
		"need_variant_offsets", "variant_preference_q16",
		"variant_preference_env_curve_ids", "variant_component_offsets",
		"component_good_ids", "component_qty_per_need", "environment_curve_signal_ids",
		"environment_curve_values_q16", "ethnicity_need_factor_q16",
		"signature_ethnicity_ids", "signature_plan_ids",
	]:
		result[key] = host._catalog.get(key)
	var ratios: PackedInt32Array = result.get(
		"good_inventory_target_ratios_q16", PackedInt32Array())
	var target_days := PackedInt32Array()
	target_days.resize(ratios.size())
	for good_idx in range(ratios.size()):
		target_days[good_idx] = int(host._profile.merchant_market_making_days_q16) * \
			int(ratios[good_idx]) / 65536
	result["good_target_inventory_days_q16"] = target_days
	result["living_cost_base_plan_id"] = String(host._profile.living_cost_base_plan_id)
	return result


static func bootstrap_cycle_days(host, cohort_count: int, market_count: int = 0,
		active_building_cell_count: int = 0, building_group_count: int = 0) -> int:
	if host._profile == null:
		return 1
	# Native locks N from populated work plus machine timing. This helper only
	# reports the profile maximum (1–5). It never restores 50/334 auto cadence.
	var maximum := clampi(int(host._profile.market_max_cycle_days), 1, 5)
	var configured := int(host._profile.market_cycle_days)
	if configured <= 0:
		configured = maximum
	return clampi(configured, 1, maximum)


static func need_display_name(host, stable_id: String) -> String:
	return EconomyFacadeDisplayScript.need_display_name(host, stable_id)


static func building_display_name(host, building_index: int) -> String:
	return EconomyFacadeDisplayScript.building_display_name(host, building_index)

	# Modifier lines on idea cards are rendered from selector-addressable stat keys
	# such as country.output.building.iron_tool_workshop_factor. The card formatter
	# resolves the trailing stable id through this registry, so it always matches
	# the name the economy UI shows instead of leaking the raw slug.


static func good_display_name(host, good_index: int) -> String:
	return EconomyFacadeDisplayScript.good_display_name(host, good_index)


static func profession_display_name(host, profession_id: StringName) -> String:
	return EconomyFacadeDisplayScript.profession_display_name(host, profession_id)


static func settlement_display_name(host, cell: int) -> String:
	return EconomyFacadeDisplayScript.settlement_display_name(host, cell)


static func _load_family_effect_displays(host) -> void:
	EconomyFacadeDisplayScript.load_family_effect_displays(host)


static func begin_save(host) -> Dictionary:
	return host._world_ext.begin_economy_save(host._profile.save_chunk_bytes) if host._configured else {"ok": false, "reason": "not configured"}


static func read_save_chunk(host) -> PackedByteArray:
	return host._world_ext.read_economy_save_chunk(host._profile.save_chunk_bytes) if host._configured else PackedByteArray()


static func end_save(host) -> Dictionary:
	return host._world_ext.end_economy_save() if host._configured else {"ok": false, "reason": "not configured"}


static func restore_bytes(host, bytes: PackedByteArray, _chunk_bytes: int = -1) -> Dictionary:
	# Production restore is ECP2-only. Bare PKEC streaming is rejected here;
	# use restore_ecp2().
	if not host._configured:
		return {"ok": false, "reason": "not configured",
			"restore_rejected_reason": "not configured"}
	if bytes.is_empty():
		return {"ok": false, "reason": "restore_requires_ecp2",
			"restore_rejected_reason": "restore_requires_ecp2"}
	if bytes.size() >= 4 and bytes[0] == 0x45 and bytes[1] == 0x43 \
			and bytes[2] == 0x50 and bytes[3] == 0x32:
		return host.restore_ecp2(bytes)
	return {"ok": false, "reason": "restore_requires_ecp2",
		"restore_rejected_reason": "restore_requires_ecp2"}


static func restore_ecp2(host, bytes: PackedByteArray) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "not configured",
			"restore_rejected_reason": "not configured"}
	var result: Dictionary = host._world_ext.restore_economy_ecp2(bytes)
	if not bool(result.get("ok", false)) and not result.has("restore_rejected_reason"):
		result["restore_rejected_reason"] = String(result.get("reason", ""))
	return result


static func capture_ecp2(host, flags: int = 0) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "not configured"}
	return host._world_ext.capture_economy_ecp2(flags)


static func restore_rejected_reason(host) -> String:
	if not host._configured:
		return ""
	return String(host._world_ext.get_economy_restore_rejected_reason())


static func event_schema(host) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy event API unavailable"}
	return host._world_ext.get_economy_event_schema()


static func set_trace_cells(host, cells: PackedInt32Array) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy event API unavailable"}
	return host._world_ext.set_economy_trace_filter({"cells": cells})


static func set_inspector_trace_cell(host, cell_idx: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy inspector trace API unavailable"}
	return host._world_ext.set_economy_inspector_trace_cell(cell_idx)


static func poll_events(host, consumer_id: StringName, max_events: int = -1,
		kind: int = 0, cell: int = -1, after_event_id: int = -1) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy event API unavailable", "count": 0}
	var opts := {
		"consumer_id": consumer_id,
		"max_events": host._profile.economy_trace_poll_max_events if max_events < 0 else max_events,
		"kind": kind,
		"cell": cell,
	}
	if after_event_id >= 0:
		opts["after_event_id"] = after_event_id
	return host._world_ext.poll_economy_events(opts)


static func ack_events(host, consumer_id: StringName, up_to_event_id: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy event API unavailable"}
	return host._world_ext.ack_economy_events(consumer_id, up_to_event_id)


static func trace_report(host) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy event API unavailable"}
	return host._world_ext.get_economy_trace_report()


static func dispatch_committed_events(host, meta: Dictionary) -> Dictionary:
	if not bool(meta.get("economy_event_batch_published", false)):
		return {"published": false, "materialized": false, "count": 0}
	host.economy_event_batch_available.emit(meta)
	# The availability signal is the normal UI invalidation path. Do not build
	# twenty PackedArrays for every committed day when nobody consumes the
	# detailed batch signal. Advance this facade-owned cursor directly so a
	# listener connected later starts at the next committed batch, matching the
	# old eager poll+ack behavior without materializing discarded rows.
	if host.economy_event_batch.get_connections().is_empty():
		var newest_id := int(meta.get("economy_event_newest_id", 0))
		var acknowledged: Dictionary = host.ack_events(&"economy_facade_handlers", newest_id)
		return {
			"published": true,
			"materialized": false,
			"count": 0,
			"acked_event_id": int(acknowledged.get("acked_event_id", newest_id)),
		}
	var batch: Dictionary = host.poll_events(&"economy_facade_handlers")
	if int(batch.get("count", 0)) <= 0:
		return {"published": true, "materialized": true, "count": 0}
	host.economy_event_batch.emit(batch)
	host.ack_events(&"economy_facade_handlers", int(batch.get("last_event_id", 0)))
	return {
		"published": true,
		"materialized": true,
		"count": int(batch.get("count", 0)),
	}


static func begin_event_archive(host, chunk_bytes: int = -1) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy event archive API unavailable"}
	return host._world_ext.begin_economy_event_archive(
		host._profile.save_chunk_bytes if chunk_bytes < 0 else chunk_bytes)


static func read_event_archive_chunk(host, max_bytes: int = -1) -> PackedByteArray:
	if not host._configured:
		return PackedByteArray()
	return host._world_ext.read_economy_event_archive_chunk(
		host._profile.save_chunk_bytes if max_bytes < 0 else max_bytes)


static func end_event_archive(host) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy event archive API unavailable"}
	return host._world_ext.end_economy_event_archive()


static func write_event_archive(host, path: String, chunk_bytes: int = -1) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "not configured"}
	var file := FileAccess.open_compressed(
		path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return {"ok": false, "reason": "event archive file open failed",
			"error": FileAccess.get_open_error()}
	var begin: Dictionary = host.begin_event_archive(chunk_bytes)
	if not bool(begin.get("ok", false)):
		file.close()
		return begin
	var chunks := 0
	var bytes_written := 0
	while true:
		var chunk: PackedByteArray = host.read_event_archive_chunk(chunk_bytes)
		if chunk.is_empty():
			break
		file.store_buffer(chunk)
		chunks += 1
		bytes_written += chunk.size()
	file.close()
	var ended: Dictionary = host.end_event_archive()
	ended["path"] = path
	ended["chunks"] = chunks
	ended["uncompressed_bytes"] = bytes_written
	return ended
