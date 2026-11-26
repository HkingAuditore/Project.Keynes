extends RefCounted

## Projects committed research and pending player receipts.


static func _configure_queues(owner: TechnologyWorkspace) -> void:
	for domain in range(mini(TechnologyWorkspace.DOMAIN_COUNT, owner._queue_headers.size())):
		var accent := owner._domain_accent(domain)
		var header: Dictionary = owner._queue_headers[domain]
		(header.icon as IconBadge).set_semantic(
			IconCatalog.technology_domain_semantic(owner._domain_id(domain)), accent)
		var name_label := header.name as Label
		name_label.text = owner._domain_name(domain)
		name_label.add_theme_color_override("font_color",
			accent.lerp(UITokens.DOSSIER_INK, 0.6))



static func _research_state_signature(owner: TechnologyWorkspace) -> int:
	return hash([
		int(owner._research.get("generation", 0)),
		int(owner._research.get("technology_points_stock", 0)),
		int(owner._research.get("country_cash", 0)),
		int(owner._research.get("purchased_total", 0)),
		int(owner._research.get("consumed_total", 0)),
		int(owner._research.get("progress_total", 0)),
		int(owner._research.get("deferred_unallocated_points", 0)),
		bool(owner._research.get("auto_purchase_enabled", false)),
		owner._research.get("technology_states", PackedInt32Array()),
		owner._research.get("technology_progress", PackedInt64Array()),
		owner._research.get("queue_offsets", PackedInt32Array()),
		owner._research.get("queue_technology_indices", PackedInt32Array()),
		owner._research.get("domain_weights_bp", PackedInt32Array()),
		owner._development.get("progress_by_signal", {}),
		owner._optimistic_queue.keys(),
		owner._current_day,
		owner._procurement,
		owner._procurement_policy(),
	])



static func _apply_research(owner: TechnologyWorkspace, force: bool = false) -> void:
	var signature := owner._research_state_signature()
	if not force and signature == owner._research_signature:
		return
	owner._research_signature = signature
	owner._refresh_count += 1
	var research_states: PackedInt32Array = owner._research.get(
		"technology_states", PackedInt32Array()).duplicate()
	var research_progress: PackedInt64Array = owner._research.get(
		"technology_progress", PackedInt64Array())
	var offsets: PackedInt32Array = owner._research.get(
		"queue_offsets", PackedInt32Array()).duplicate()
	var technologies: PackedInt32Array = owner._research.get(
		"queue_technology_indices", PackedInt32Array()).duplicate()
	# Optimistic overlay is presentation-only. Never bake it into `_research`
	# or a COMMIT receipt that clears the queue leaves a fake 「研究中」 forever.
	owner._overlay_optimistic_into(research_states, offsets, technologies)
	var states := owner._presentation_states(research_states)
	var progress := owner._presentation_progress(research_progress)
	var relations_changed := states != owner._last_states
	owner._last_states = states
	owner._tree.patch_states(states, progress)
	owner._available.patch_states(states, progress)
	if owner._overview.visible:
		owner._overview.patch_states(states)
	var weights: PackedInt32Array = owner._research.get("domain_weights_bp",
		PackedInt32Array([2500, 2500, 2500, 2500]))
	owner._dial.set_weights(weights)
	owner._apply_budget_notice()
	owner._patch_queues(research_states, research_progress, weights,
		offsets, technologies)
	owner._sample_history()
	owner._schedule_inputs = {"states": research_states, "progress": research_progress,
		"offsets": offsets, "technologies": technologies}
	owner._patch_schedule(research_states, research_progress, weights, offsets, technologies)
	owner._update_kpis(research_states)
	if owner._initial_focus_pending:
		owner._apply_default_focus()
	owner._refresh_detail(relations_changed)
	if not owner._optimistic_queue.is_empty():
		owner.set_process(true)



static func _optimistic_domain(owner: TechnologyWorkspace, entry) -> int:
	if entry is Dictionary:
		return int((entry as Dictionary).get("domain", -1))
	return int(entry)



static func _optimistic_request_id(owner: TechnologyWorkspace, entry) -> int:
	if entry is Dictionary:
		return int((entry as Dictionary).get("request_id", 0))
	return 0



static func _overlay_optimistic_into(owner: TechnologyWorkspace, states: PackedInt32Array, offsets: PackedInt32Array,
		technologies: PackedInt32Array, erase_confirmed: bool = true) -> void:
	if owner._optimistic_queue.is_empty():
		return
	if offsets.size() < TechnologyWorkspace.DOMAIN_COUNT + 1:
		offsets.resize(TechnologyWorkspace.DOMAIN_COUNT + 1)
		offsets[0] = 0
		for domain_cursor in range(1, TechnologyWorkspace.DOMAIN_COUNT + 1):
			offsets[domain_cursor] = technologies.size()
	var confirmed: Array[int] = []
	for tech_index_value in owner._optimistic_queue.keys():
		var tech_index := int(tech_index_value)
		if tech_index < 0 or tech_index >= states.size():
			confirmed.append(tech_index)
			continue
		# Authoritative queued / pending / owned means the optimistic row is done.
		if int(states[tech_index]) >= 3:
			confirmed.append(tech_index)
			continue
		var domain := owner._optimistic_domain(owner._optimistic_queue[tech_index_value])
		if domain < 0 or domain >= TechnologyWorkspace.DOMAIN_COUNT:
			confirmed.append(tech_index)
			continue
		var already := false
		for queued_index in technologies:
			if int(queued_index) == tech_index:
				already = true
				break
		if already:
			confirmed.append(tech_index)
			continue
		states[tech_index] = 3
		var insert_at := int(offsets[domain + 1])
		technologies.insert(insert_at, tech_index)
		for domain_cursor in range(domain + 1, TechnologyWorkspace.DOMAIN_COUNT + 1):
			offsets[domain_cursor] = int(offsets[domain_cursor]) + 1
	if erase_confirmed:
		for tech_index in confirmed:
			owner._optimistic_queue.erase(tech_index)



static func _resolve_research_handle(owner: TechnologyWorkspace) -> int:
	var handle := owner._optimistic_country_handle
	if handle == 0:
		handle = int(owner._research.get("country_handle", 0))
	if handle == 0 and owner._player_controller != null \
			and owner._player_controller.has_method("get_player_country_handle"):
		handle = int(owner._player_controller.get_player_country_handle())
	return handle



static func _force_apply_live_research(owner: TechnologyWorkspace) -> bool:
	if owner._player_controller == null:
		return false
	var facade = null
	if owner._player_controller.has_method("get_country_facade"):
		facade = owner._player_controller.get_country_facade()
	if facade == null or not facade.has_method("research_snapshot"):
		return false
	var handle := owner._resolve_research_handle()
	if handle == 0:
		if not owner._optimistic_reconcile_fail_logged:
			owner._optimistic_reconcile_fail_logged = true
			print("[tech-ui] live research apply skipped: country_handle=0")
		return false
	var live: Dictionary = facade.research_snapshot(handle)
	if live.is_empty() or (live.has("ok") and not bool(live.get("ok", false))):
		return false
	var live_states = live.get("technology_states", null)
	if not live_states is PackedInt32Array:
		return false
	live["country_cash"] = owner._research.get("country_cash", live.get("country_cash", 0))
	owner._research = live
	owner._has_valid_research = true
	owner._apply_research()
	return true



static func _reconcile_optimistic_from_live_snapshot(owner: TechnologyWorkspace) -> void:
	if owner._optimistic_queue.is_empty() or owner._player_controller == null:
		return
	var facade = null
	if owner._player_controller.has_method("get_country_facade"):
		facade = owner._player_controller.get_country_facade()
	if facade == null or not facade.has_method("research_snapshot"):
		return
	var handle := owner._resolve_research_handle()
	if handle == 0:
		if not owner._optimistic_reconcile_fail_logged:
			owner._optimistic_reconcile_fail_logged = true
			print("[tech-ui] optimistic reconcile skipped: country_handle=0")
		return
	var live: Dictionary = facade.research_snapshot(handle)
	if live.is_empty() or (live.has("ok") and not bool(live.get("ok", false))):
		return
	var live_states = live.get("technology_states", null)
	if not live_states is PackedInt32Array:
		return
	var states: PackedInt32Array = live_states
	var live_stock := int(live.get("technology_points_stock", -1))
	var live_consumed := int(live.get("consumed_total", -1))
	# Starter knowledge costs the entire treasury grant. When stock/consumed move
	# after an optimistic enqueue, the worker already finished the node even if
	# our local definition index and the states array briefly disagree.
	var authority_moved := (
		(owner._optimistic_baseline_stock >= 0 and live_stock >= 0
			and live_stock != owner._optimistic_baseline_stock)
		or (owner._optimistic_baseline_consumed >= 0 and live_consumed >= 0
			and live_consumed != owner._optimistic_baseline_consumed)
		or int(live.get("generation", -1)) != int(owner._research.get("generation", -1))
	)
	var cleared := false
	var remaining: Array = owner._optimistic_queue.keys()
	for tech_index_value in remaining:
		var tech_index := int(tech_index_value)
		var entry = owner._optimistic_queue[tech_index_value]
		if owner._optimistic_request_id(entry) != 0:
			continue
		var technology_id := ""
		if entry is Dictionary:
			technology_id = String((entry as Dictionary).get("technology_id", ""))
		var resolved := tech_index
		if not technology_id.is_empty() and owner._technology_indices.has(technology_id):
			resolved = int(owner._technology_indices[technology_id])
		var authoritative_state := -1
		if resolved >= 0 and resolved < states.size():
			authoritative_state = int(states[resolved])
		elif tech_index >= 0 and tech_index < states.size():
			authoritative_state = int(states[tech_index])
		if authoritative_state >= 3 or authority_moved:
			owner._optimistic_queue.erase(tech_index)
			cleared = true
	if cleared or authority_moved:
		live["country_cash"] = owner._research.get("country_cash", live.get("country_cash", 0))
		owner._research = live
		owner._has_valid_research = true
		if owner._optimistic_queue.is_empty():
			owner._optimistic_baseline_stock = -1
			owner._optimistic_baseline_consumed = -1
			owner._optimistic_reconcile_fail_logged = false
		owner._apply_research()
		print("[tech-ui] optimistic reconciled gen=%d stock=%d consumed=%d queued_left=%d" % [
			int(live.get("generation", -1)), live_stock, live_consumed,
			owner._optimistic_queue.size()])



static func _poll_optimistic_receipts(owner: TechnologyWorkspace) -> void:
	if owner._optimistic_queue.is_empty() or owner._player_controller == null:
		return
	var facade = null
	if owner._player_controller.has_method("get_country_facade"):
		facade = owner._player_controller.get_country_facade()
	if facade == null or not facade.has_method("poll_worker_command_receipts"):
		return
	var batch: Dictionary = facade.poll_worker_command_receipts(
		owner._receipt_cursor, 64)
	owner._receipt_cursor = int(batch.get("last_publication_sequence", owner._receipt_cursor))
	var pending_changed := false
	for row: Dictionary in batch.get("receipts", []):
		var request_id := int(row.get("request_id", 0))
		if request_id == 0:
			continue
		var status := String(row.get("status", ""))
		if status not in ["Committed", "RejectedAtExecution"]:
			continue
		for tech_index in owner._optimistic_queue.keys():
			if owner._optimistic_request_id(owner._optimistic_queue[tech_index]) != request_id:
				continue
			owner._optimistic_queue.erase(tech_index)
			pending_changed = true
			if status == "RejectedAtExecution":
				var reason := String(row.get("reason", "")).strip_edges()
				var message := owner._research_command_message(reason)
				if message == "当前无法加入研究队列。" and not reason.is_empty():
					message = reason
				owner._detail.mark_rejected(message)
	if pending_changed and not owner._force_apply_live_research():
		owner._apply_research()
