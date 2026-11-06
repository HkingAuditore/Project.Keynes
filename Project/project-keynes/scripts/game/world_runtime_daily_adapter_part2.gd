extends RefCounted

## Extracted world_runtime_daily_adapter.gd group 2; state stays with host.

func _note_climate_capacity_pending_stall(host) -> void:
	if host._climate_capacity_pending_day < 0 or host._climate_capacity_pending_since_msec <= 0:
		return
	var now_msec = Time.get_ticks_msec()
	var stalled_ms = now_msec - host._climate_capacity_pending_since_msec
	if stalled_ms < host._CLIMATE_CAPACITY_STALL_DIAG_MSEC:
		return
	if now_msec < host._climate_capacity_stall_next_diag_msec:
		return
	host._climate_capacity_stall_next_diag_msec = now_msec + host._CLIMATE_CAPACITY_STALL_DIAG_MSEC
	var report = host._generator.get_runtime_thread_report() \
		if host._generator != null and host._generator.has_method("get_runtime_thread_report") else {}
	push_warning("[host.climate-host.capacity-stall] day=%d pending_ms=%d stall=0x%x ring=%s worker=%s committed=%s economy_input=%s country_peer=%s"
		% [host._climate_capacity_pending_day, stalled_ms,
			int(report.get("day_stall_reason_mask", 0)),
			str(report.get("environment_ring_pending", -1)),
			str(report.get("simulation_host_state", report.get("state", "?"))),
			str(report.get("simulation_committed_day", report.get("committed_day", -1))),
			str(report.get("economy_input_requested_day", -1)),
			str(report.get("country_worker_waiting_for_peer", false))])
	host.RuntimeForensics.capture_and_dump("climate_input_capacity_stalled", host._generator,
		host._world_clock, "stall", {
			"stalled_day": host._climate_capacity_pending_day,
			"stalled_ms": stalled_ms,
			"day_stall_reason_mask": report.get("day_stall_reason_mask", 0),
			"environment_ring_pending": report.get("environment_ring_pending", -1),
			"economy_input_requested_day": report.get("economy_input_requested_day", -1),
			"country_worker_waiting_for_peer": report.get(
				"country_worker_waiting_for_peer", false),
			"simulation_committed_day": report.get(
				"simulation_committed_day", report.get("committed_day", -1)),
		})


## Read live authority gates without constructing the full diagnostic report.


func _runtime_control_state(host) -> Dictionary:
	if host._generator == null:
		return {}
	if host._generator.has_method("get_runtime_control_state"):
		return host._generator.get_runtime_control_state()
	return host._generator.get_runtime_thread_report() \
		if host._generator.has_method("get_runtime_thread_report") else {}


## When the native worker enters FAULTED, pause the authoritative host.clock and keep
## the last committed generation/hash diagnostics for soak evidence. Do not
## clear live MapData; the parked host.snapshot remains the recovery baseline.


func _observe_runtime_worker_fault(host, report: Dictionary = {}) -> void:
	if host._runtime_worker_fault_paused:
		return
	if report.is_empty():
		report = host._runtime_control_state()
	var state = String(report.get(
		"simulation_host_state", report.get("state", "")))
	if state != "FAULTED":
		return
	# Full diagnostics are needed once, when a fault is actually observed.
	if not report.has("fault_code") and host._generator != null \
			and host._generator.has_method("get_runtime_thread_report"):
		report = host._generator.get_runtime_thread_report()
	host._runtime_worker_fault_paused = true
	if host._world_clock != null:
		if host._world_clock.has_method("latch_authority_fault_hold"):
			host._world_clock.latch_authority_fault_hold()
		else:
			host._world_clock.pause(true)
	host._runtime_last_fault_diagnostics = {
		"fault_code": String(report.get("fault_code", "")),
		"committed_day": int(report.get("simulation_committed_day", report.get("committed_day", -1))),
		"generation": int(report.get("generation", 0)),
		"state_hash": int(report.get("state_hash", 0)),
		"worker_fault_count": int(report.get("worker_fault_count", 0)),
		"economy_authority_last_committed_generation": int(report.get(
			"economy_authority_last_committed_generation", 0)),
		"economy_authority_last_committed_hash": int(report.get(
			"economy_authority_last_committed_hash", 0)),
		"economy_authority_fault_paused": bool(report.get(
			"economy_authority_fault_paused", false)),
		"last_commit": host._runtime_last_commit.duplicate(false),
	}
	push_warning("[runtime-worker] FAULTED code=%s committed_day=%s generation=%s faults=%s - world_clock.pause(true)" % [
		str(host._runtime_last_fault_diagnostics.get("fault_code", "")),
		str(host._runtime_last_fault_diagnostics.get("committed_day", -1)),
		str(host._runtime_last_fault_diagnostics.get("generation", 0)),
		str(host._runtime_last_fault_diagnostics.get("worker_fault_count", 0))])
	host.RuntimeForensics.capture_and_dump(
		String(host._runtime_last_fault_diagnostics.get("fault_code", "runtime_worker_fault")),
		host._generator, host._world_clock, "runtime_worker_fault", {
			"source": "world_runtime_host",
			"worker_fault": host._runtime_last_fault_diagnostics.duplicate(true),
		})



func get_runtime_fault_diagnostics(host) -> Dictionary:
	return host._runtime_last_fault_diagnostics.duplicate(false)



func is_runtime_fault_paused(host) -> bool:
	return host._runtime_worker_fault_paused


## Host-side Country intent drain. SHADOW replays typed results without
## touching Effect/Modifier/Economy. ACTIVE invokes the already-attached
## production peer adapter and returns its typed result to the worker; the
## adapter itself does not mutate Country state.


func _service_country_worker_transport(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null \
			or not host._generator.has_method("service_country_worker_peer_adapter"):
		return
	var report = host._runtime_control_state()
	var mode = String(report.get("simulation_thread_mode",
		report.get("requested_simulation_thread_mode", "OFF")))
	if mode != "SHADOW" and mode != "ACTIVE":
		return
	var shadow_replay = mode != "ACTIVE"
	host._country_worker_transport_last_service = \
		host._generator.service_country_worker_peer_adapter(64, shadow_replay)
	if int(host._country_worker_transport_last_service.get("inspected", 0)) > 0 \
			or int(host._country_worker_transport_last_service.get("notified", 0)) > 0:
		host.country_peer_serviced.emit(host._country_worker_transport_last_service.duplicate(false))


## ACTIVE Country's only MapData read-back boundary.  The worker host.snapshot is
## immutable and stays on the native side; this method copies either the
## generation-contiguous sparse owner patch or an explicit full bootstrap /
## recovery host.snapshot.  It never waits for the worker and never calls the
## synchronous Country write API.

## E8 ACTIVE Modifier write-back. Non-blocking: drops intermediate generations.
## Targets legacy ModifierRuntime (not MapData arrays). main_wait_on_sim_us stays 0.


func _consume_modifier_worker_snapshot_if_authoritative(host) -> void:
	host._modifier_worker_snapshot_generation = preload("res://scripts/game/world_runtime_modifier_writeback.gd").consume(
		host._runtime_ready_for_ticks, host._generator, host._runtime_control_state,
		host._modifier_worker_snapshot_generation)


## F8 ACTIVE Effect write-back. Non-blocking: drops intermediate generations.
## Targets legacy EffectRuntime. main_wait_on_sim_us stays 0.


func _consume_effect_worker_snapshot_if_authoritative(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null:
		return
	if host._trigger_country_delivery_id > 0 or not host._trigger_country_delivery_ids.is_empty() \
			or host._trigger_country_delivery_waiting:
		return
	if not host._generator.has_method("apply_runtime_effect_snapshot"):
		return
	var report = host._runtime_control_state()
	var granted_mask = int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x020) == 0:
		return
	var applied: Dictionary = host._generator.apply_runtime_effect_snapshot(
		host._effect_worker_snapshot_generation)
	if not bool(applied.get("ok", false)) or not bool(applied.get("applied", false)):
		return
	var generation = int(applied.get("generation", 0))
	if generation <= host._effect_worker_snapshot_generation:
		return
	host._effect_worker_snapshot_generation = generation


## F8: non-Modifier Effect intents are consumed on the main thread and ACK'd
## back to the worker. MODIFIER intents stay in-worker (E8).


func _service_effect_worker_intents_if_authoritative(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null:
		return
	var report = host._runtime_control_state()
	var granted_mask = int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x020) == 0:
		return
	var ext = host._generator.get_data_core_world_ext() \
		if host._generator.has_method("get_data_core_world_ext") else null
	if ext == null or not ext.has_method("poll_effect_worker_intent"):
		return
	# Bounded pump: never block the sim on an unbounded intent backlog.
	for _i in range(64):
		var intent: Dictionary = ext.poll_effect_worker_intent()
		if not bool(intent.get("ok", false)) or not bool(intent.get("available", false)):
			break
		var domain = int(intent.get("target_domain", intent.get("domain", 0)))
		# MODIFIER (7) is ACK'd inside the worker Modifier stage.
		if domain == 7:
			continue
		var ack: Dictionary = {
			"request_id": int(intent.get("request_id", 0)),
			"transaction_id": int(intent.get("transaction_id",
				intent.get("request_id", 0))),
			"target_handle": int(intent.get("target_handle", 0)),
			"target_generation": int(intent.get("target_generation", 0)),
			"domain": domain,
			# RuntimeDomainAckCode::OK == 0; 1 is RETRY (clears intent_emitted).
			"code": 0,
			"host.effective_day": int(intent.get("host.effective_day", 0)),
			"producer_id": int(intent.get("producer_id", 0)),
			"sequence": int(intent.get("sequence", 0)),
		}
		if ext.has_method("submit_effect_worker_ack"):
			ext.submit_effect_worker_ack(ack)
	# Economy-owned family expeditions enqueue their CLAIM/SETTLE transaction
	# onto the legacy EffectRuntime while the Effect domain itself is worker
	# authoritative. The worker intent queue above does not contain these
	# program_id=-1 adapter transactions, so they must be pumped from the main
	# thread. Keep the order explicit: Country CLAIM -> Country ACK -> Economy
	# SETTLE -> Economy ACK. The native adapters are idempotent and retain
	# incomplete bindings until the worker publishes their terminal receipts.
	if ext.has_method("get_effect_native_adapter_report"):
		var adapter_report: Dictionary = ext.get_effect_native_adapter_report()
		if bool(adapter_report.get("idle", true)):
			return
	if ext.has_method("dispatch_effect_native_country"):
		ext.dispatch_effect_native_country()
	if ext.has_method("ack_effect_native_country"):
		ext.ack_effect_native_country()
	# Drain only non-mixed orphaned Country bindings. The native helper keeps
	# CLAIM+SETTLE transactions pending until the claim is truly acknowledged.
	if ext.has_method("settle_orphaned_effect_native_country_acks"):
		ext.settle_orphaned_effect_native_country_acks()
	if ext.has_method("dispatch_effect_native_economy"):
		ext.dispatch_effect_native_economy()
	if ext.has_method("ack_effect_native_economy"):
		ext.ack_effect_native_economy()


## P1-A: under IDEOLOGY worker authority the main-thread daily job is
## suppressed, so the sliced instance refresh -- whose instances still belong to
## this facade -- has to be pumped here. A pending boundary or slice is continued
## by frame liveness, even when the calendar cannot admit another day.
## Last day the derived-host.layer pump reached completion.
##
## The throttle belongs to the PUMP, because the pump is the only caller invoked every
## tick. Putting it inside `step_derived_rebuild` also throttled a new epoch that began
## within the same calendar day -- see the comment at the pump.
## How many times this pump has actually reached the host.generator, and the last shapes it
## got back. The pump is the only place the IDEOLOGY mask bit turns into work, so
## without a counter "the gate opened" was not observable from outside the process --
## which is exactly how a mask that read 0x000 while the writer followed the request
## survived: the pump silently did nothing and nothing could say so. Read by
## `ideology_worker_restart_mask_promotion_test.gd`.



func _step_ideology_instance_refresh_if_authoritative(host, day_idx: int) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null:
		return
	if not host._generator.has_method("step_ideology_instance_refresh"):
		return
	var report = host._runtime_control_state()
	if (int(report.get("authoritative_domain_mask", 0)) & 0x010) == 0:
		return
	host._ideology_refresh_pending_day = day_idx
	host._ideology_pump_calls += 1
	if host._ideology_instance_refreshed_day != day_idx:
		host._ideology_instance_refresh_last = \
			host._generator.step_ideology_instance_refresh(day_idx).duplicate(false)
		if not bool(host._ideology_instance_refresh_last.get("done", false)) \
				or bool(host._ideology_instance_refresh_last.get("pending", true)):
			return
		host._ideology_instance_refreshed_day = day_idx
	# Plan §9.3 in worker mode: the DERIVED half needs the same pump.
	#
	# `run_ideology_daily` is suppressed under IDEOLOGY worker authority and it is the only
	# production caller of `step_derived_rebuild`, so without this the derived host.layer was
	# never stepped and produced nothing (measured: visits delta 0 over 12 days with a live
	# card, vs 4 with host.ideology on the main thread).
	#
	# THE THROTTLE LIVES HERE, NOT IN THE STEP, and that placement is the whole lesson.
	# Only the pump is called every tick, so only the pump needs throttling; the normal day
	# loop and `drain_derived_cell_layer` legitimately step the rebuild many times per day,
	# and a NEW EPOCH can host.begin on the SAME calendar day. A once-per-day guard inside
	# `step_derived_rebuild`, keyed on the day alone, skipped that epoch's rebuild entirely
	# -- measured, and it cost two attempts and a broken save fixture host.before it was
	# understood.
	#
	# A call landing inside the worker's day transaction returns `economy_day_inflight`.
	# Retry from frame liveness: the worker may be parked on the main-boundary request,
	# so waiting for the next calendar tick can deadlock. Instance and derived calls
	# share that request bit; finish one host.before starting the other.
	if host._generator.has_method("step_ideology_derived_rebuild"):
		if host._ideology_derived_pumped_day != day_idx:
			var pumped: Dictionary = host._generator.step_ideology_derived_rebuild(day_idx)
			host._ideology_pump_last = pumped.duplicate(false)
			if bool(pumped.get("done", false)) and not bool(pumped.get("pending", true)):
				host._ideology_derived_pumped_day = day_idx
			else:
				return
	host._ideology_refresh_pending_day = -1


## G8 ACTIVE Ideology write-back. Non-blocking: drops intermediate generations.
## Targets legacy NativeIdeologyRuntime. main_wait_on_sim_us stays 0.


func _consume_ideology_worker_snapshot_if_authoritative(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null:
		return
	if not host._generator.has_method("apply_runtime_ideology_snapshot"):
		return
	var report = host._runtime_control_state()
	var granted_mask = int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x010) == 0:
		return
	var applied: Dictionary = host._generator.apply_runtime_ideology_snapshot(
		host._ideology_worker_snapshot_generation)
	if not bool(applied.get("ok", false)) or not bool(applied.get("applied", false)):
		return
	var generation = int(applied.get("generation", 0))
	if generation <= host._ideology_worker_snapshot_generation:
		return
	host._ideology_worker_snapshot_generation = generation


## G8: Ideology transition intents address EFFECT and require an ACK host.before the
## worker applies the transition. When EFFECT is granted in the same host.session the
## worker already ACKs them in-worker; this pump is the protocol host.path and covers an
## IDEOLOGY-only grant where EFFECT is still main-thread owned.
##
## R-3d: "Effect accepted" is a real statement, not a formality. `submit_ideology_worker_ack`
## tells the POD that the Effect side has actually taken the transition, and the POD
## then flips the card's location and frees the slot. Answering it on behalf of a worker
## that owns EFFECT would mean claiming a commit that never happened -- the slot frees
## while the modifier row is still live, which is the exact divergence the earlier
## rounds chased.
##
## So the pump is ONLY the host.fallback for the split-authority case:
##   * IDEOLOGY must be worker-authoritative (otherwise the main thread owns the day
##     and this queue is empty anyway), and
##   * EFFECT must NOT be worker-authoritative. When the worker owns EFFECT it drains
##     the intents itself (`ack_ideology_intents_in_worker`) and a GDScript ACK would
##     be a duplicate.
##
## `host._ideology_intent_duplicate_acks` and `host._ideology_intent_unknown_acks` count the two
## ways a reply can be wrong; both must stay 0 under the 0xFFF fixture, where the worker
## owns everything and this function should never fire at all.


func _service_ideology_worker_intents_if_authoritative(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null:
		return
	var report = host._runtime_control_state()
	var granted_mask = int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x010) == 0:
		return
	if (granted_mask & 0x020) != 0:
		# EFFECT belongs to the worker: it ACKs in-worker, and a second reply from
		# here would report a commit nobody verified.
		return
	var ext = host._generator.get_data_core_world_ext() \
		if host._generator.has_method("get_data_core_world_ext") else null
	if ext == null or not ext.has_method("poll_ideology_worker_intent"):
		return
	if not ext.has_method("submit_ideology_worker_ack"):
		return
	# Bounded pump: never block the sim on an unbounded intent backlog.
	for _i in range(64):
		var intent: Dictionary = ext.poll_ideology_worker_intent()
		if not bool(intent.get("ok", false)) or not bool(intent.get("available", false)):
			break
		var request_id = int(intent.get("request_id", 0))
		var transaction_id = int(intent.get("transaction_id", request_id))
		if request_id == 0:
			++host._ideology_intent_unknown_acks
			continue
		# Same transaction answered twice means the POD emitted two intents for one
		# transition (or a retry raced the first reply). Either way the second reply
		# must not be sent: it would settle a transition the first reply already
		# settled, and the POD cannot tell the difference.
		if host._ideology_acked_transactions.has(transaction_id):
			++host._ideology_intent_duplicate_acks
			continue
		host._ideology_acked_transactions[transaction_id] = true
		# submit_ideology_worker_ack stamps EFFECT itself; the Ideology
		# authority ignores an ACK from any other domain.
		ext.submit_ideology_worker_ack({
			"request_id": request_id,
			"transaction_id": transaction_id,
			"target_handle": int(intent.get("target_handle", 0)),
			"target_generation": int(intent.get("target_generation", 0)),
			# RuntimeDomainAckCode::OK == 0. 1 is RETRY, which clears
			# intent_emitted and makes the worker re-emit the same transition
			# forever instead of settling it.
			"code": 0,
			"host.effective_day": int(intent.get("host.effective_day", 0)),
		})

## H8 ACTIVE Trigger write-back. The worker owns aggregation and host.effect emission;
## this is the only boundary that copies its committed state back into the legacy
## TriggerRuntime facade, which the UI, save, and Trigger->Effect handoff still
## read. Non-blocking and generation-gated: intermediate generations are dropped.


func _consume_trigger_worker_snapshot_if_authoritative(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null:
		return
	if not host._generator.has_method("apply_runtime_trigger_snapshot"):
		return
	var report = host._runtime_control_state()
	var granted_mask = int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x008) == 0:
		return
	var applied: Dictionary = host._generator.apply_runtime_trigger_snapshot(
		host._trigger_worker_snapshot_generation)
	if not bool(applied.get("ok", false)) or not bool(applied.get("applied", false)):
		return
	var generation = int(applied.get("generation", 0))
	if generation <= host._trigger_worker_snapshot_generation:
		return
	host._trigger_worker_snapshot_generation = generation


## H8: Trigger host.effect intents address EFFECT and require an ACK host.before the worker
## considers the firing day committed. With EFFECT granted in the same host.session the
## worker ACKs them itself at the Effect stage; this pump is the protocol host.path and
## covers a TRIGGER-only grant plus anything the in-worker drain missed.


func _service_trigger_worker_intents_if_authoritative(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null:
		return
	var report = host._runtime_control_state()
	var granted_mask = int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x008) == 0:
		return
	var ext = host._generator.get_data_core_world_ext() \
		if host._generator.has_method("get_data_core_world_ext") else null
	if ext == null or not ext.has_method("poll_trigger_worker_intent"):
		return
	host._service_trigger_country_delivery(ext, report)
	if not ext.has_method("submit_trigger_worker_ack"):
		return
	# Bounded pump: never block the sim on an unbounded intent backlog.
	for _i in range(64):
		var intent: Dictionary = ext.poll_trigger_worker_intent()
		if not bool(intent.get("ok", false)) or not bool(intent.get("available", false)):
			break
		ext.submit_trigger_worker_ack({
			"request_id": int(intent.get("request_id", 0)),
			"transaction_id": int(intent.get("transaction_id",
				intent.get("request_id", 0))),
			"target_handle": int(intent.get("target_handle", 0)),
			"target_generation": int(intent.get("target_generation", 0)),
			"target_domain": int(intent.get("target_domain", 0)),
			# RuntimeDomainAckCode::OK == 0. RETRY(1) would make the worker
			# replay the same firing day forever instead of settling it.
			"code": 0,
			"host.effective_day": int(intent.get("host.effective_day", 0)),
		})



func _service_trigger_country_delivery(host, ext: Object, _report: Dictionary) -> void:
	if host._trigger_country_delivery_id > 0 or not host._trigger_country_delivery_ids.is_empty():
		ext.ack_effect_native_country()
		if not host._trigger_country_delivery_ack_sent:
			var retried: Dictionary = host._ack_trigger_delivery_ids(ext)
			host._trigger_country_delivery_ack_sent = bool(retried.get("pod_shadow_ok", false))
		var adapter: Dictionary = ext.get_effect_native_adapter_report()
		if host._trigger_country_delivery_ack_sent and not bool(adapter.get("country_pending", false)):
			host._trigger_country_delivery_id = 0
			host._trigger_country_delivery_ids = PackedInt64Array()
		return
	if not host._trigger_country_delivery_waiting and host._world_clock != null and host._world_clock.paused:
		return
	if not host._completed_research_signals_reconciled \
			and ext.has_method("reconcile_completed_research_signals"):
		var recovery: Dictionary = ext.reconcile_completed_research_signals(64)
		host._completed_research_signals_reconciled = bool(recovery.get("ok", false)) \
			and bool(recovery.get("complete", false))
		if int(recovery.get("submitted", 0)) > 0:
			print("[research-evidence-recovery] ", recovery)
	# Full-host.graph ACTIVE skips advance_runtime_pulse(), which used to own this
	# handoff. Drain a bounded prefix through the existing Effect -> Country
	# adapter, including restored effects whose effective day is in the past.
	var batch: Dictionary = ext.poll_trigger_effects(0, 64)
	var actions: PackedInt32Array = batch.get("actions", PackedInt32Array())
	var opcodes: PackedInt32Array = batch.get("opcodes", PackedInt32Array())
	var count = 0
	for i in actions.size():
		if actions[i] != host.TRIGGER_PUBLISH_EVENT and not (
				actions[i] == host.TRIGGER_COUNTRY_COMMAND and opcodes[i] == host.COUNTRY_DISCOVER_SIGNAL):
			break
		count += 1
	if count == 0 and not host._trigger_country_delivery_waiting:
		return
	var handoff: Dictionary = ext.handoff_trigger_effects(maxi(1, count))
	host._trigger_country_delivery_waiting = bool(handoff.get("deferred", false))
	if int(handoff.get("handed_off", 0)) <= 0:
		return
	# Delivery order is host.canonical while host.effect host.ids are ingress-allocated: ACK
	# exactly the host.ids that were handed off, never a numeric high-water cursor.
	var delivered_ids: PackedInt64Array = handoff.get("effect_ids", PackedInt64Array())
	host._trigger_country_delivery_id = int(handoff.get("last_effect_id", 0))
	if delivered_ids.is_empty() and host._trigger_country_delivery_id > 0:
		delivered_ids = PackedInt64Array([host._trigger_country_delivery_id])
	host._trigger_country_delivery_ids = delivered_ids
	# Explicitly forward the delivery ACK as well as acknowledging the facade.
	# This is idempotent when handoff_trigger_effects already forwarded it.
	var delivery_ack: Dictionary = host._ack_trigger_delivery_ids(ext)
	host._trigger_country_delivery_ack_sent = bool(delivery_ack.get("pod_shadow_ok", false))
	if OS.get_environment("PK_TECH_DELIVERY_DIAG") == "1":
		print("[tech-delivery] handoff=", handoff, " ids_ack=", delivery_ack)
	ext.dispatch_effect_native_country()
	ext.ack_effect_native_country()


## ACK a delivery batch by the exact host.effect host.ids the handoff returned. Old DLLs
## without ack_trigger_effect_ids() fall back to the numeric cursor lane.


func _ack_trigger_delivery_ids(host, ext: Object) -> Dictionary:
	if not host._trigger_country_delivery_ids.is_empty() \
			and ext.has_method("ack_trigger_effect_ids"):
		return ext.ack_trigger_effect_ids(host._trigger_country_delivery_ids)
	return ext.ack_trigger_effects(host._trigger_country_delivery_id)



func _consume_country_worker_read_view_if_authoritative(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null \
			or not host._generator.has_method("get_country_worker_read_view"):
		return
	var report = host._runtime_control_state()
	var granted_mask = int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x004) == 0:
		return
	var view: Dictionary = host._generator.get_country_worker_read_view(
		host._country_worker_read_generation)
	if not bool(view.get("ok", false)) or not bool(view.get("available", false)):
		return
	var generation = int(view.get("generation", 0))
	if generation <= host._country_worker_read_generation:
		return
	var cell_count = host._current_map.cell_count() if host._current_map != null else 0
	if cell_count <= 0:
		host._country_worker_read_rejected_count += 1
		return
	var changed_cells: PackedInt32Array = view.get(
		"changed_cells", PackedInt32Array())
	var changed_owners: PackedInt32Array = view.get(
		"changed_owners", PackedInt32Array())
	var full_required = bool(view.get("full_snapshot_required", false))
	var territory_changed_count = 0
	if full_required:
		var full_owners: PackedInt32Array = view.get(
			"full_cell_owners", PackedInt32Array())
		if full_owners.size() != cell_count:
			host._country_worker_read_rejected_count += 1
			push_warning("[host.country-authority] full read view rejected: cell shape mismatch")
			return
		# Repair MapData with the full owner plane, but never advertise
		# cell_count as "host.changed": that forced O(host.n) host.vision/host.border on every
		# missed-generation catch-up even when only a few host.cells differed.
		var previous_owners: PackedInt32Array = host._current_map.country_slot_arr
		if previous_owners.size() == cell_count:
			for cell in range(cell_count):
				if int(previous_owners[cell]) != int(full_owners[cell]):
					territory_changed_count += 1
		else:
			territory_changed_count = cell_count
		host._current_map.country_slot_arr = full_owners
		host._country_worker_read_full_snapshot_count += 1
	else:
		if changed_cells.size() != changed_owners.size():
			host._country_worker_read_rejected_count += 1
			push_warning("[host.country-authority] sparse read view rejected: patch shape mismatch")
			return
		if host._current_map.country_slot_arr.size() != cell_count:
			host._country_worker_read_rejected_count += 1
			push_warning("[host.country-authority] sparse read view rejected: MapData shape mismatch")
			return
		for i in changed_cells.size():
			var cell = int(changed_cells[i])
			if cell < 0 or cell >= cell_count:
				host._country_worker_read_rejected_count += 1
				push_warning("[host.country-authority] sparse read view rejected: cell host.out of range")
				return
			host._current_map.country_slot_arr[cell] = int(changed_owners[i])
		territory_changed_count = changed_cells.size()
		host._country_worker_read_patch_count += 1

	host._country_worker_read_generation = generation
	host._country_worker_read_last_day = int(view.get("committed_day", -1))
	host._country_read_last_full_snapshot = full_required
	host._country_read_last_applied_cells = territory_changed_count
	host._country_read_last_territory_changed_cells = territory_changed_count
	view.erase("full_cell_owners")
	view.erase("changed_cells")
	view.erase("changed_owners")
	# Shallow copy is enough: remaining fields are scalars / packed arrays.
	host._country_worker_read_last_result = view.duplicate(false)
	host._country_worker_read_last_result["applied_cells"] = territory_changed_count
	host._country_worker_read_last_result["territory_changed_cells"] = territory_changed_count
	host._country_worker_read_last_result["full_snapshot_applied"] = full_required
	var worker_report = host._country_worker_read_last_result.duplicate(false)
	# Vision/host.border consumers key off changed_cells. Use the real territory
	# delta, never the repaired plane width.
	worker_report["changed_cells"] = territory_changed_count
	worker_report["changed_cell_count"] = territory_changed_count
	worker_report["full_snapshot_applied"] = full_required
	worker_report["country_generation"] = generation
	# CountryFacade is the existing notification host.path.  It emits the same
	# country_committed signal consumed by host.vision, host.border, controller and UI.
	var facade = host._generator.get_country_facade() \
		if host._generator.has_method("get_country_facade") else null
	if facade != null and facade.has_method("dispatch_worker_committed_view"):
		facade.dispatch_worker_committed_view(worker_report)


## Budgeted host.country host.vision/host.border refresh. Pending work survives frames that
## already spent their sim budget so day capture and peer pumps stay responsive.


func _service_country_visual_refresh_budgeted(host, frame_started_usec: int) -> void:
	if not host._country_visual_refresh_pending:
		return
	var frame_elapsed_ms = host._sched_elapsed_ms(frame_started_usec)
	var budget_ms = host.COUNTRY_VISUAL_REFRESH_BUDGET_MS
	if host._world_clock != null:
		budget_ms = minf(budget_ms, float(host._world_clock.sim_frame_budget_ms))
	var force = host._country_visual_refresh_deferred_frames >= \
		host.COUNTRY_VISUAL_REFRESH_MAX_DEFER_FRAMES
	if not force and frame_elapsed_ms >= budget_ms:
		host._country_visual_refresh_deferred_frames += 1
		host._country_visual_refresh_defer_count += 1
		return
	host._country_visual_refresh_pending = false
	host._country_visual_refresh_deferred_frames = 0
	var started_usec = Time.get_ticks_usec()
	host.refresh_country_visuals(host._country_visual_refresh_reason)
	host._country_visual_last_refresh_ms = host._sched_elapsed_ms(started_usec)
	host._country_visual_refresh_run_count += 1


## ACTIVE worker 的唯一主线程消费点。poll_runtime_commit() 只返回不可变提交
## 元数据；视觉 intent 采用有界预算分片消费。这里绝不调用 run_daily_tick、
## 不读取 runtime store，也不等待 worker。
##
## `report_override`：同一调用栈里刚刚取过的 runtime report。内联日没有 worker
## 线程，两次读取必然同值，因此传进来可以省掉一天里第二次
## get_runtime_thread_report() 的打包/拷贝，并且把**已经由调用方做过的**
## host.climate 回灌跳过一次（同一个 report、同一个 committed_day，回灌的单调日门
## 保证第二次调用本来就是空转）。非 override 调用（每帧 _process）行为不变。

