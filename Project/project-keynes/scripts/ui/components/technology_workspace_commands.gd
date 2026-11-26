extends RefCounted

## Handles research choices, queue commands, and budget actions.


static func _on_available_selected(owner: TechnologyWorkspace, index: int) -> void:
	owner._selected_technology = index
	if owner._compact and index >= 0 and owner._manual_focus:
		owner._set_detail_open(true)
	owner._manual_focus = true
	owner._refresh_detail()



static func _on_tree_selected(owner: TechnologyWorkspace, index: int) -> void:
	owner._selected_technology = index
	if owner._compact and index >= 0 and owner._manual_focus:
		owner._set_detail_open(true)
	owner._manual_focus = true
	owner._refresh_detail()



static func _on_tree_activated(owner: TechnologyWorkspace, index: int) -> void:
	if index < 0 or index >= owner._definitions.size() \
			or owner._is_application_definition(owner._definitions[index]):
		return
	var states: PackedInt32Array = owner._research.get("technology_states", PackedInt32Array())
	var state := int(states[index]) if index < states.size() else 0
	if state == 3 or owner._optimistic_queue.has(index):
		owner._remove_from_queue(index)
		return
	if state == 2 and not owner._is_retired(index):
		owner._enqueue(index)


# Dragging the allocation re-projects every ETA so the trade-off is visible
# before anything is committed.
static func _on_weights_previewed(owner: TechnologyWorkspace, weights_bp: PackedInt32Array) -> void:
	if owner._schedule_inputs.is_empty():
		return
	owner._patch_schedule(owner._schedule_inputs.states, owner._schedule_inputs.progress, weights_bp,
		owner._schedule_inputs.offsets, owner._schedule_inputs.technologies)
	owner._refresh_detail(false)



static func _on_weights_committed(owner: TechnologyWorkspace, weights_bp: PackedInt32Array) -> void:
	if owner._player_controller == null:
		return
	var result: Dictionary = owner._player_controller.request_command(
		TechnologyWorkspace.PlayerControllerScript.COMMAND_RESEARCH_SET_WEIGHTS, {"weights_bp": weights_bp})
	if bool(result.get("ok", false)):
		owner.policy_submitted.emit()


# ---- 国家购买政策：科技占比（只读展示） --------------------------------------

## {treasury_share_bp, research_share_bp, source}: session → snapshot → default。
## 这里不再提交政策，写入口统一在国民经济 · 国库的预算卷宗。
static func _procurement_policy(owner: TechnologyWorkspace) -> Dictionary:
	return TechnologyWorkspace.NationalProcurementSliderScript.resolve_policy(owner._player_controller, owner._procurement)


## Daily national procurement cash at the current policy (MONEY_SCALE). The
## runtime's frozen value wins when the snapshot matches the policy; otherwise
## it is estimated from treasury cash.
static func _national_daily_budget(owner: TechnologyWorkspace, policy: Dictionary) -> int:
	var treasury_share := int(policy.get("treasury_share_bp", 0))
	if treasury_share <= 0:
		return 0
	if bool(owner._procurement.get("available", false)) \
			and bool(owner._procurement.get("policy_enabled", false)) \
			and int(owner._procurement.get("treasury_share_bp", -1)) == treasury_share:
		return maxi(0, int(owner._procurement.get("national_daily_budget", 0)))
	return int(round(float(int(owner._research.get("country_cash", 0))) \
		* float(treasury_share) / 10000.0))



static func _daily_research_budget(owner: TechnologyWorkspace) -> int:
	var policy := owner._procurement_policy()
	if bool(owner._procurement.get("available", false)) \
			and bool(owner._procurement.get("policy_enabled", false)) \
			and int(owner._procurement.get("treasury_share_bp", -1)) == int(policy.treasury_share_bp) \
			and int(owner._procurement.get("research_share_bp", -1)) == int(policy.research_share_bp):
		return maxi(0, int(owner._procurement.get("research_daily_budget", 0)))
	return int(round(float(owner._national_daily_budget(policy)) \
		* float(int(policy.research_share_bp)) / 10000.0))


## 只读便笺：把当前科技份额与折算日额写清楚，不再提供第二条可拖的滑条。
static func _apply_budget_notice(owner: TechnologyWorkspace) -> void:
	if owner._budget == null:
		return
	var policy := owner._procurement_policy()
	var national := owner._national_daily_budget(policy)
	owner._budget.set_state(int(policy.research_share_bp), national,
		int(policy.treasury_share_bp) > 0)


## 便笺上的「前往预算调配」：沿节点树上溯到国家面板外壳，由它把
## 「切到国民经济 · 国库」的意图交给 GameUIManager。不在本组件里持有
## 面板引用，避免科技卷宗被单独实例化时产生悬空依赖。
static func _on_open_budget_requested(owner: TechnologyWorkspace) -> void:
	var node := owner.get_parent()
	while node != null:
		if node.has_signal("section_selected") \
				and node.has_method("focus_economy_chapter"):
			node.emit_signal("section_selected", "economy")
			node.call("focus_economy_chapter", "treasury")
			return
		node = node.get_parent()



static func _enqueue(owner: TechnologyWorkspace, index: int) -> void:
	if owner._player_controller == null or index < 0 or index >= owner._definitions.size():
		return
	var definition: Dictionary = owner._definitions[index]
	if owner._is_application_definition(definition) or owner._is_retired(index):
		return
	var domain := owner._domain_index_of(definition)
	var result: Dictionary = owner._player_controller.request_command(
		TechnologyWorkspace.PlayerControllerScript.COMMAND_RESEARCH_ENQUEUE,
		{"technology_id": StringName(definition.get("id", "")),
		"domain": domain})
	if bool(result.get("ok", false)):
		var request_ids = result.get("request_ids", PackedInt64Array())
		var request_id := 0
		if request_ids is PackedInt64Array and request_ids.size() > 0:
			request_id = int(request_ids[0])
		elif request_ids is Array and not request_ids.is_empty():
			request_id = int(request_ids[0])
		owner._optimistic_country_handle = int(owner._research.get("country_handle", 0))
		if owner._optimistic_country_handle == 0 \
				and owner._player_controller.has_method("get_player_country_handle"):
			owner._optimistic_country_handle = int(
				owner._player_controller.get_player_country_handle())
		owner._optimistic_baseline_stock = int(owner._research.get(
			"technology_points_stock", -1))
		owner._optimistic_baseline_consumed = int(owner._research.get("consumed_total", -1))
		owner._optimistic_reconcile_fail_logged = false
		owner._optimistic_queue[index] = {
			"domain": domain,
			"request_id": request_id,
			"technology_id": String(definition.get("id", "")),
		}
		owner.set_process(true)
		owner._detail.mark_submitted()
		owner._apply_research()
		owner.policy_submitted.emit()
		print("[tech-ui] enqueue accepted id=%s domain=%d request=%d handle=%d stock=%d" % [
			String(definition.get("id", "")), domain, request_id,
			owner._optimistic_country_handle, owner._optimistic_baseline_stock])
		# Immediate reconcile: at 50x the worker may finish the node before the
		# next panel refresh, and optimistic rows must not outlive that.
		owner._reconcile_optimistic_from_live_snapshot()
		return
	var reason := String(result.get("code", result.get("reason", "")))
	var message := String(result.get("message", "")).strip_edges()
	if message.is_empty():
		message = owner._research_command_message(reason)
	owner._detail.mark_rejected(message)
	print("[tech-ui] enqueue rejected id=%s reason=%s" % [
		String(definition.get("id", "")), reason])



static func _remove_from_queue(owner: TechnologyWorkspace, index: int) -> void:
	if owner._player_controller == null or index < 0 or index >= owner._definitions.size():
		return
	if owner._is_application_definition(owner._definitions[index]):
		return
	owner._optimistic_queue.erase(index)
	var result: Dictionary = owner._player_controller.request_command(
		TechnologyWorkspace.PlayerControllerScript.COMMAND_RESEARCH_REMOVE,
		{"technology_id": StringName((owner._definitions[index] as Dictionary).get("id", ""))})
	if bool(result.get("ok", false)):
		owner._detail.mark_submitted()
		if not owner._force_apply_live_research():
			owner._apply_research()
		owner.policy_submitted.emit()
		return
	var reason := String(result.get("code", result.get("reason", "")))
	# Optimistic-only rows are not on the worker yet; treat as local cancel.
	if reason == "country_research_not_queued":
		if not owner._force_apply_live_research():
			owner._apply_research()
		return
	var message := String(result.get("message", "")).strip_edges()
	if message.is_empty():
		message = owner._research_command_message(reason)
	owner._detail.mark_rejected(message)



static func _research_command_message(owner: TechnologyWorkspace, code: String) -> String:
	return {
		"country_research_already_queued": "该科技已在研究队列中。",
		"country_research_technology_unavailable": "该科技当前不可研究。",
		"country_research_requirements_incomplete": "前置条件尚未完成。",
		"country_research_domain_mismatch": "科技领域与队列不匹配。",
		"country_research_queue_full": "该领域研究队列已满。",
		"country_research_not_queued": "该科技不在研究队列中。",
		"country_research_queue_argument_invalid": "研究队列参数无效。",
		"era_reward_choice_required": "必须先完成时代奖励选择。",
		"technology_milestone_retired": "此科技已停用，请在顶栏时代徽记中晋升。",
	}.get(code, "当前无法加入研究队列。")



static func _move_in_queue(owner: TechnologyWorkspace, technology: int, domain: int, position: int) -> void:
	if owner._player_controller == null or technology < 0 or technology >= owner._definitions.size():
		return
	if owner._is_application_definition(owner._definitions[technology]) or owner._is_retired(technology):
		return
	var result: Dictionary = owner._player_controller.request_command(
		TechnologyWorkspace.PlayerControllerScript.COMMAND_RESEARCH_MOVE,
		{"technology_id": StringName((owner._definitions[technology] as Dictionary).get("id", "")),
		"domain": domain, "position": position})
	if bool(result.get("ok", false)):
		owner.policy_submitted.emit()
