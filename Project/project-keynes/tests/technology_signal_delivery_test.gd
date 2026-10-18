extends SceneTree

# Exercise transport backpressure and the two independent ACKs. A full Trigger
# command lane must not lose the delivery id set or discard the Effect plan.
# Effect ids are ingress-allocated while delivery is canonical, so the delivery
# ACK ships the exact id set returned by handoff_trigger_effects(); the numeric
# cursor lane is only a fallback for old DLLs without ack_trigger_effect_ids().
class PeerBase extends RefCounted:
	var effects := PackedInt32Array([10, 13])
	var pending_country := false
	var receipt_ready := false
	var cursor_lane_ready := false
	var dispatches := 0
	var handoffs := 0
	var id_submissions := 0
	var cursor_submissions := 0
	var last_ids := PackedInt64Array()
	var defer_handoff := false

	func poll_trigger_effects(_after: int, _limit: int) -> Dictionary:
		return {"actions": effects, "opcodes": PackedInt32Array([14, 1])}

	func dispatch_effect_native_country() -> Dictionary:
		dispatches += 1
		pending_country = true
		return {"ok": true}

	func ack_effect_native_country() -> Dictionary:
		if receipt_ready:
			pending_country = false
		return {"ok": true}

	func ack_trigger_effects(_cursor: int) -> Dictionary:
		cursor_submissions += 1
		return {"ok": true, "pod_shadow_ok": cursor_lane_ready}

	func get_effect_native_adapter_report() -> Dictionary:
		return {"country_pending": pending_country}

class DeliveryPeer extends PeerBase:
	func handoff_trigger_effects(count: int) -> Dictionary:
		if defer_handoff:
			return {"handed_off": 0, "deferred": true}
		handoffs += 1
		effects.clear()
		return {"handed_off": count, "last_effect_id": 2,
			"effect_ids": PackedInt64Array([2])}

	func ack_trigger_effect_ids(effect_ids: PackedInt64Array) -> Dictionary:
		id_submissions += 1
		last_ids = effect_ids
		return {"ok": true, "pod_shadow_ok": cursor_lane_ready}

# Old DLL: no id-based ACK method, handoff only reports the numeric cursor.
class LegacyDeliveryPeer extends PeerBase:
	func handoff_trigger_effects(count: int) -> Dictionary:
		if defer_handoff:
			return {"handed_off": 0, "deferred": true}
		handoffs += 1
		effects.clear()
		return {"handed_off": count, "last_effect_id": 2}

var _failures := 0

func _init() -> void:
	var host := WorldRuntimeHost.new()
	var peer := DeliveryPeer.new()
	host._service_trigger_country_delivery(peer, {"trigger_acked_effect_id": 0})
	_expect(peer.handoffs == 1 and peer.dispatches == 1,
		"full graph delivers research signals even without a legacy graph pulse")
	_expect(peer.id_submissions == 1 and peer.cursor_submissions == 0,
		"delivery must ACK by explicit effect ids, not by the numeric cursor")
	_expect(peer.last_ids.size() == 1 and int(peer.last_ids[0]) == 2,
		"delivery must ACK exactly the handoff effect id set")
	var retained_ids: PackedInt64Array = host.get("_trigger_country_delivery_ids")
	_expect(retained_ids.size() == 1 and int(retained_ids[0]) == 2,
		"full id lane retains the in-flight Effect transaction")
	peer.cursor_lane_ready = true
	host._service_trigger_country_delivery(peer, {"trigger_acked_effect_id": 0})
	_expect(peer.id_submissions == 2 and peer.handoffs == 1,
		"id-lane overflow retries without repeating the Country command")
	_expect(peer.cursor_submissions == 0,
		"id-lane retry must not fall back to the cursor")
	host._service_trigger_country_delivery(peer, {"trigger_acked_effect_id": 2})
	_expect(host.get("_trigger_country_delivery_id") == 2,
		"Trigger acknowledgment alone cannot discard a pending Country receipt")
	peer.receipt_ready = true
	host._service_trigger_country_delivery(peer, {"trigger_acked_effect_id": 0})
	var cleared_ids: PackedInt64Array = host.get("_trigger_country_delivery_ids")
	_expect(host.get("_trigger_country_delivery_id") == 0 and cleared_ids.is_empty(),
		"durable Country receipt and admitted Trigger id ACK release Effect writeback")
	_expect(peer.id_submissions >= 2 and peer.dispatches == 1,
		"successful id submission and Country delivery remain idempotent")
	host.free()

	# Old DLL graceful fallback: no ack_trigger_effect_ids(), no effect_ids.
	var legacy_host := WorldRuntimeHost.new()
	var legacy_peer := LegacyDeliveryPeer.new()
	legacy_host._service_trigger_country_delivery(legacy_peer, {})
	_expect(legacy_peer.handoffs == 1 and legacy_peer.cursor_submissions == 1,
		"peer without ack_trigger_effect_ids() falls back to the numeric cursor")
	var legacy_ids: PackedInt64Array = legacy_host.get("_trigger_country_delivery_ids")
	_expect(legacy_ids.size() == 1 and int(legacy_ids[0]) == 2,
		"fallback still retains the last delivered id for reporting")
	legacy_peer.receipt_ready = true
	legacy_peer.cursor_lane_ready = true
	legacy_host._service_trigger_country_delivery(legacy_peer, {})
	_expect(legacy_host.get("_trigger_country_delivery_id") == 0,
		"legacy cursor lane still releases the delivery after the receipt")
	legacy_host.free()

	var deferred_host := WorldRuntimeHost.new()
	var deferred_peer := DeliveryPeer.new()
	deferred_peer.defer_handoff = true
	deferred_host._service_trigger_country_delivery(deferred_peer, {})
	_expect(deferred_host.get("_trigger_country_delivery_waiting")
		and deferred_peer.dispatches == 0,
		"busy Economy boundary defers delivery and protects the Effect facade")
	deferred_peer.defer_handoff = false
	deferred_peer.cursor_lane_ready = true
	deferred_host._service_trigger_country_delivery(deferred_peer, {})
	_expect(not deferred_host.get("_trigger_country_delivery_waiting")
		and deferred_peer.dispatches == 1,
		"boundary inbox completion resumes the same delivery once")
	deferred_host.free()
	print("technology_signal_delivery_test: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _expect(condition: bool, label: String) -> void:
	if not condition:
		_failures += 1
		push_error(label)
