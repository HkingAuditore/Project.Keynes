extends RefCounted

## Admits player commands and dispatches them to the relevant simulation facade.


static func request_command(owner: PlayerController, id: StringName, args: Dictionary = {}) -> Dictionary:
	if not PlayerController.SUPPORTED_COMMANDS.has(id):
		return owner._complete_command(id, PlayerController._result(false, "unsupported_command", "该正式玩家命令尚未开放。"))
	if id == PlayerController.COMMAND_NARRATIVE_CHOOSE:
		var checked := owner._validate_command_args(id, args)
		if not bool(checked.get("ok", false)):
			return owner._complete_command(id, checked)
		var choice_sequence := owner._progression_component._allocate_command_sequence(owner)
		var answer := owner._narrative_service.choose_option(args, choice_sequence)
		answer["sequence"] = choice_sequence
		return owner._complete_command(id, answer)
	var ready := owner._resolve_player_country()
	if not bool(ready.get("ok", false)):
		return owner._complete_command(id, ready)
	var validation := owner._validate_command_args(id, args, ready.facade)
	if not bool(validation.get("ok", false)):
		return owner._complete_command(id, validation)
	var facade = ready.facade
	var effective_day := maxi(0, owner._world_clock.day_index()) \
		if id == PlayerController.COMMAND_FAMILY_COLONIZATION_START or \
		id == PlayerController.COMMAND_FAMILY_COLONIZATION_CANCEL or \
		id == PlayerController.COMMAND_ERA_REWARD_CHOOSE or \
		id == PlayerController.COMMAND_FAMILY_FOUNDING_CHOOSE else owner.CommandDispatch._next_effective_day(owner)
	var sequence := owner._command_sequence
	owner._command_sequence += 1
	var result: Dictionary
	match id:
		PlayerController.COMMAND_RESEARCH_SET_WEIGHTS:
			var weights := args.get("weights_bp", PackedInt32Array()) as PackedInt32Array
			result = facade.set_research_weights(owner._player_country_handle, weights, effective_day, sequence)
		PlayerController.COMMAND_RESEARCH_ENQUEUE:
			result = owner._progression_component._request_research_queue(owner, facade, "enqueue", args, effective_day, sequence)
		PlayerController.COMMAND_RESEARCH_REMOVE:
			result = owner._progression_component._request_research_queue(owner, facade, "remove", args, effective_day, sequence)
		PlayerController.COMMAND_RESEARCH_MOVE:
			result = owner._progression_component._request_research_queue(owner, facade, "move", args, effective_day, sequence)
		PlayerController.COMMAND_COUNTRY_TAX_SET_DEFAULT:
			result = facade.set_tax_default_basis_points(owner._player_country_handle,
				int(args.kind), owner._tax_rate_basis_points(args), effective_day, sequence,
				owner._tax_assessment_mode(args))
		PlayerController.COMMAND_COUNTRY_TAX_SET_OVERRIDE:
			result = facade.set_tax_override_basis_points(owner._player_country_handle,
				int(args.kind), StringName(args.item_id), owner._tax_rate_basis_points(args),
				effective_day, sequence, owner._tax_assessment_mode(args))
		PlayerController.COMMAND_COUNTRY_TAX_SET_OVERRIDE_GROUP:
			result = facade.set_tax_override_group_basis_points(owner._player_country_handle,
				int(args.kind), args.get("item_ids", PackedStringArray()),
				owner._tax_rate_basis_points(args), effective_day, sequence,
				owner._tax_assessment_mode(args))
		PlayerController.COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE:
			result = facade.clear_tax_override(owner._player_country_handle,
				int(args.kind), StringName(args.item_id), effective_day, sequence)
		PlayerController.COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE_GROUP:
			result = facade.clear_tax_override_group(owner._player_country_handle,
				int(args.kind), args.get("item_ids", PackedStringArray()),
				effective_day, sequence)
		PlayerController.COMMAND_CELL_TAX_SET_DEFAULT:
			result = facade.set_cell_tax_default_basis_points(owner._player_country_handle,
				int(args.cell), int(args.kind), owner._tax_rate_basis_points(args),
				effective_day, sequence, owner._tax_assessment_mode(args))
		PlayerController.COMMAND_CELL_TAX_CLEAR_DEFAULT:
			result = facade.clear_cell_tax_default(owner._player_country_handle,
				int(args.cell), int(args.kind), effective_day, sequence)
		PlayerController.COMMAND_CELL_TAX_SET_OVERRIDE:
			result = facade.set_cell_tax_override_basis_points(owner._player_country_handle,
				int(args.cell), int(args.kind), StringName(args.item_id),
				owner._tax_rate_basis_points(args), effective_day, sequence,
				owner._tax_assessment_mode(args))
		PlayerController.COMMAND_CELL_TAX_CLEAR_OVERRIDE:
			result = facade.clear_cell_tax_override(owner._player_country_handle,
				int(args.cell), int(args.kind), StringName(args.item_id),
				effective_day, sequence)
		PlayerController.COMMAND_CELL_TAX_CLEAR_ALL:
			result = facade.clear_cell_tax_policy(owner._player_country_handle,
				int(args.cell), effective_day, sequence)
		PlayerController.COMMAND_CONSTRUCTION_BUILD:
			if owner._economy_facade == null or not owner._economy_facade.has_method(
					"treasury_sponsored_build"):
				result = PlayerController._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
			else:
				result = owner._economy_facade.treasury_sponsored_build(
					owner._player_country_handle, int(args.get("cell_idx", -1)),
					StringName(args.get("building_id", &"")), effective_day, sequence,
					StringName(args.get("ownership_policy", &"")))
		PlayerController.COMMAND_POLITICAL_REGIME_SET:
			result = facade.set_political_regime(owner._player_country_handle,
				StringName(args.get("regime_id", &"")), effective_day, sequence) \
				if facade.has_method("set_political_regime") else PlayerController._result(false,
				"runtime_unavailable", "体制系统尚未就绪，请稍后再试。")
		PlayerController.COMMAND_FAMILY_COLONIZATION_START:
			result = owner._economy_facade.start_family_colonization(
				owner._player_country_handle, int(args.get("family_handle", 0)),
				int(args.get("source_cell", -1)), int(args.get("target_cell", -1)),
				int(args.get("population", 0)), int(args.get("quote_token", 0)),
				effective_day, sequence)
		PlayerController.COMMAND_FAMILY_COLONIZATION_CANCEL:
			result = owner._economy_facade.cancel_family_colonization(
				owner._player_country_handle, int(args.get("expedition_handle", 0)),
				effective_day, sequence)
		PlayerController.COMMAND_ERA_REWARD_CHOOSE:
			result = facade.choose_era_reward(
				int(args.get("offer_generation", 0)),
				int(args.get("choice_index", -1)), effective_day, sequence)
		PlayerController.COMMAND_FAMILY_FOUNDING_CHOOSE:
			result = owner._economy_facade.submit_family_founding_choice(
				int(args.get("offer_id", 0)), int(args.get("generation", 0)),
				int(args.get("choice_index", -1)), effective_day, sequence)
		PlayerController.COMMAND_IDEOLOGY_OFFER:
			result = owner._ideology_facade.request_offer(
				owner._player_country_handle, effective_day, sequence)
		PlayerController.COMMAND_IDEOLOGY_CHOOSE:
			result = owner._ideology_facade.choose_offer(owner._player_country_handle,
				int(args.get("offer_generation", 0)), int(args.get("choice_index", -1)), effective_day, sequence)
		PlayerController.COMMAND_IDEOLOGY_REROLL:
			result = owner._ideology_facade.reroll_offer(owner._player_country_handle,
				int(args.get("offer_generation", 0)), effective_day, sequence)
		PlayerController.COMMAND_IDEOLOGY_EQUIP:
			result = owner._ideology_facade.equip(owner._player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		PlayerController.COMMAND_IDEOLOGY_UNEQUIP:
			result = owner._ideology_facade.unequip(owner._player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		PlayerController.COMMAND_IDEOLOGY_PROMOTE:
			result = owner._ideology_facade.promote(owner._player_country_handle,
				int(args.get("ideology_id", -1)), effective_day, sequence)
		PlayerController.COMMAND_ERA_ADVANCE_START:
			result = owner._era_advancement.start(effective_day, sequence)
		PlayerController.COMMAND_ERA_ADVANCE_PAUSE:
			result = owner._era_advancement.pause(effective_day, sequence)
		PlayerController.COMMAND_ERA_ADVANCE_RESUME:
			result = owner._era_advancement.resume(effective_day, sequence)
		PlayerController.COMMAND_PROCUREMENT_SET_POLICY:
			result = owner._era_advancement.set_policy(int(args.get("treasury_share_bp", -1)),
				int(args.get("research_share_bp", -1)), effective_day, sequence,
				int(args.get("era_share_bp", PlayerController.EraAdvancementServiceScript.SHARE_UNSET)),
				int(args.get("colonization_share_bp",
					PlayerController.EraAdvancementServiceScript.SHARE_UNSET)))
		_:
			if PlayerController.MILITARY_COMMANDS.has(id):
				result = owner._military_component._submit_military_command(owner, id, args, effective_day, sequence)
			else:
				result = PlayerController._result(false, "unsupported_command", "该正式玩家命令尚未开放。")
	if not result.has("ok"):
		result["ok"] = false
	if not result.has("code"):
		result["code"] = "command_rejected" if not bool(result.get("ok", false)) else "ok"
	if id == PlayerController.COMMAND_CONSTRUCTION_BUILD and bool(result.get("ok", false)):
		result["code"] = "queued"
		result["message"] = "修建命令已排队，将在下一个经济结算边界执行。"
	if id == PlayerController.COMMAND_POLITICAL_REGIME_SET and bool(result.get("ok", false)):
		result["code"] = String(result.get("code", "queued"))
		result["message"] = "体制调整已排队。"
	if (id == PlayerController.COMMAND_FAMILY_COLONIZATION_START or \
			id == PlayerController.COMMAND_FAMILY_COLONIZATION_CANCEL) \
			and bool(result.get("ok", false)):
		var queued_code := String(result.get("code", ""))
		if queued_code == "colonization_queued":
			result["message"] = "派遣已排队。"
		elif queued_code == "colonization_cancel_queued":
			result["message"] = "取消已排队。"
	if (id == PlayerController.COMMAND_FAMILY_COLONIZATION_START or \
			id == PlayerController.COMMAND_FAMILY_COLONIZATION_CANCEL) \
			and not bool(result.get("ok", false)):
		var colonize_code := String(result.get("code", ""))
		if colonize_code == "economy_busy_retry":
			result["message"] = EconomyStatusCopy.BUSY
		elif String(result.get("message", "")).strip_edges().is_empty():
			result["message"] = PlayerController._colonization_command_message(colonize_code)
	if not result.has("message"):
		result["message"] = String(result.get("reason", ""))
	result["sequence"] = sequence
	return owner._complete_command(id, result)



static func _next_effective_day(owner: PlayerController) -> int:
	return owner._progression_component._next_effective_day(owner)



static func _colonization_command_message(code: String) -> String:
	return {
		"economy_busy_retry": EconomyStatusCopy.BUSY,
		"colonization_queued": "派遣已排队。",
		"colonization_cancel_queued": "取消已排队。",
		"economy_paused": "经济模拟已暂停，无法派遣。",
		"economy_not_available": "经济系统尚未就绪，请稍后再试。",
		"colonization_requote_required": "地图、视野或领土已经变化，请重新确认报价。",
		"colonization_kit_requote_required": "目标资源或科技已经变化，请重新确认开工包。",
		"colonization_kit_materials_short": "源地市场库存不足，无法抽出开工包物资。",
		"colonization_preparing": "开拓队已开始筹备，人仍留在源地生产缺货物资。",
		"colonization_cancelled": "开拓筹备已取消，目标占用已释放。",
		"colonization_quote_expired": "报价已过期，请重新选择要派遣的家族。",
		"colonization_population_insufficient": "源分支人口不足，必须至少留下一人。",
		"colonization_duplicate_target": "本国已有一支开拓队前往该目标。",
		"colonization_family_cell_capacity": "目标地块的家族数量已达上限。",
		"colonization_expedition_invalid": "开拓队已结束或已过期。",
		"colonization_command_invalid": "开拓命令参数不完整。",
		"colonization_country_snapshot_unavailable": "国家快照尚未就绪，请稍后再试。",
	}.get(code, "当前无法执行开拓。")



static func _complete_command(owner: PlayerController, id: StringName, result: Dictionary) -> Dictionary:
	var admitted := bool(result.get("admitted", result.get("ok", false)))
	if admitted:
		var admitted_days: PackedInt64Array = result.get("effective_days", PackedInt64Array())
		if not result.has("effective_day") and not admitted_days.is_empty():
			result["effective_day"] = admitted_days[0]
	else:
		result.erase("effective_day")
		result.erase("effective_days")
	result["admitted"] = admitted
	if not result.has("sequence"):
		result["sequence"] = -1
	owner.command_completed.emit(id, result)
	return result
