extends RefCounted

## Validates allowed player command arguments through explicit read callbacks. Command sequencing and submission remain in PlayerController.

const COMMAND_RESEARCH_SET_WEIGHTS := &"research.set_weights"

const COMMAND_RESEARCH_SET_BUDGET := &"research.set_budget"

const COMMAND_RESEARCH_ENQUEUE := &"research.enqueue"

const COMMAND_RESEARCH_REMOVE := &"research.remove"

const COMMAND_RESEARCH_MOVE := &"research.move"

const COMMAND_COUNTRY_TAX_SET_DEFAULT := &"country.tax.set_default"

const COMMAND_COUNTRY_TAX_SET_OVERRIDE := &"country.tax.set_override"

const COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE := &"country.tax.clear_override"

const COMMAND_CELL_TAX_SET_DEFAULT := &"country.tax.cell.set_default"

const COMMAND_CELL_TAX_CLEAR_DEFAULT := &"country.tax.cell.clear_default"

const COMMAND_CELL_TAX_SET_OVERRIDE := &"country.tax.cell.set_override"

const COMMAND_CELL_TAX_CLEAR_OVERRIDE := &"country.tax.cell.clear_override"

const COMMAND_CELL_TAX_CLEAR_ALL := &"country.tax.cell.clear_all"

const COMMAND_CONSTRUCTION_BUILD := &"construction.build"
const COMMAND_POLITICAL_REGIME_SET := &"politics.regime.set"

const COMMAND_FAMILY_COLONIZATION_START := &"family.colonization.start"

const COMMAND_FAMILY_COLONIZATION_CANCEL := &"family.colonization.cancel"

const COMMAND_ERA_REWARD_CHOOSE := &"era_reward.choose"

const COMMAND_FAMILY_FOUNDING_CHOOSE := &"family.founding.choose"

const COMMAND_IDEOLOGY_OFFER := &"ideology.offer"

const COMMAND_IDEOLOGY_CHOOSE := &"ideology.choose"

const COMMAND_IDEOLOGY_EQUIP := &"ideology.equip"

const COMMAND_IDEOLOGY_UNEQUIP := &"ideology.unequip"

const COMMAND_IDEOLOGY_PROMOTE := &"ideology.promote"

const COMMAND_IDEOLOGY_REROLL := &"ideology.reroll"

const COMMAND_ERA_ADVANCE_START := &"era.advance.start"

const COMMAND_ERA_ADVANCE_PAUSE := &"era.advance.pause"

const COMMAND_ERA_ADVANCE_RESUME := &"era.advance.resume"

const COMMAND_PROCUREMENT_SET_POLICY := &"procurement.set_policy"

const COMMAND_NARRATIVE_CHOOSE := &"narrative.choose"

const COMMAND_MILITARY_FORCE_TARGET := &"military.force.set_target"

const COMMAND_MILITARY_CONFIG_SHARES := &"military.config.set"

const COMMAND_MILITARY_QUALITY_POLICY := &"military.config.set_quality_policy"

const COMMAND_MILITARY_AUTO_RETRAIN := &"military.config.auto_retrain"

const COMMAND_MILITARY_LEVY := &"military.force.set_levy"

const COMMAND_MILITARY_AUTO_DISCHARGE := &"military.force.set_auto_discharge"

const COMMAND_MILITARY_BARRACKS := &"military.barracks.pause"

const COMMAND_MILITARY_TRAIN := &"military.train"

const COMMAND_MILITARY_STATE_BUILD := &"military.state.build"

const COMMAND_MILITARY_STATE_DEMOLISH := &"military.state.demolish"

const COMMAND_MILITARY_WAGE := &"military.policy.set_wage"

const COMMAND_MILITARY_PROCUREMENT := &"military.policy.set_procurement"

const COMMAND_MILITARY_BUDGET := &"military.policy.set_budget"

const COMMAND_MILITARY_ARMY_CREATE := &"military.army.create"

const COMMAND_MILITARY_ARMY_STATION := &"military.army.station"

const COMMAND_MILITARY_ARMY_MOVE := &"military.army.move"

const COMMAND_MILITARY_AREA_CONTROL := &"military.army.area_control"

const COMMAND_MILITARY_ARMY_EXPLORE := &"military.army.explore"

const COMMAND_MILITARY_ARMY_STOP := &"military.army.stop"

const COMMAND_MILITARY_ARMY_STANCE := &"military.army.stance"

const COMMAND_MILITARY_ARMY_DISBAND := &"military.army.disband"

const COMMAND_MILITARY_WAR_DECLARE := &"military.war.declare"

const COMMAND_MILITARY_PEACE_PROPOSE := &"military.peace.propose"

const COMMAND_MILITARY_PEACE_RESPOND := &"military.peace.respond"

const EraAdvancementServiceScript = preload("res://scripts/era/era_advancement_service.gd")

static func _validate_command_args(
		_economy_facade,
		_ideology_facade,
		_era_reward_generation: int,
		_family_founding_offer_id: int,
		_family_founding_generation: int,
		is_milestone_technology: Callable,
		_validate_owned_cell: Callable,
		ideology_offer_eligibility: Callable,
		_era_advancement_preview: Callable,
		_military_facade: Callable,
		_completed_technology_ids: Callable,
		_state_building_gate: Callable,
		_player_owns_military_cell: Callable,
		_player_country_handle: int,
		id: StringName,
		args: Dictionary,
		facade = null) -> Dictionary:
	match id:
		COMMAND_RESEARCH_SET_WEIGHTS:
			var weights_value = args.get("weights_bp", null)
			if not weights_value is PackedInt32Array:
				return _result(false, "invalid_args", "研究权重参数类型无效。")
			var weights: PackedInt32Array = weights_value
			if weights.size() != 4:
				return _result(false, "invalid_args", "研究权重必须包含四个领域。")
			var total := 0
			for weight in weights:
				if weight < 0:
					return _result(false, "invalid_args", "研究权重不能为负。")
				total += weight
			if total != 10000:
				return _result(false, "invalid_args", "研究权重总和必须为 10000。")
		COMMAND_RESEARCH_SET_BUDGET:
			if not args.has("enabled") or not args.has("daily_cash_limit"):
				return _result(false, "invalid_args", "研究预算参数不完整。")
			if int(args.get("daily_cash_limit", -1)) < 0:
				return _result(false, "invalid_args", "研究预算不能为负。")
		COMMAND_RESEARCH_ENQUEUE, COMMAND_RESEARCH_REMOVE, COMMAND_RESEARCH_MOVE:
			var technology_id := StringName(args.get("technology_id", &""))
			if technology_id.is_empty():
				return _result(false, "invalid_args", "缺少科技标识。")
			# Era milestones are internal era tokens granted by Era Advancement;
			# removing a stale queue entry stays allowed.
			if id != COMMAND_RESEARCH_REMOVE and is_milestone_technology.call(technology_id):
				return _result(false, "technology_milestone_retired",
					"时代里程碑不再通过研究获得，请在时代晋升面板中晋升时代。")
			if id == COMMAND_RESEARCH_ENQUEUE:
				var domain := int(args.get("domain", -1))
				if domain < 0 or domain >= 4:
					return _result(false, "invalid_args", "科技领域无效。")
			elif id == COMMAND_RESEARCH_MOVE:
				var move_domain := int(args.get("domain", -1))
				var position := int(args.get("position", -1))
				if move_domain < 0 or move_domain >= 4 or position < 0:
					return _result(false, "invalid_args", "研究队列位置无效。")
		COMMAND_COUNTRY_TAX_SET_DEFAULT, COMMAND_COUNTRY_TAX_SET_OVERRIDE, \
				COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE, COMMAND_CELL_TAX_SET_DEFAULT, \
				COMMAND_CELL_TAX_CLEAR_DEFAULT, COMMAND_CELL_TAX_SET_OVERRIDE, \
				COMMAND_CELL_TAX_CLEAR_OVERRIDE:
			var kind := int(args.get("kind", -1))
			if kind < 0 or kind >= 5:
				return _result(false, "invalid_tax_kind", "税种无效。")
			if id == COMMAND_COUNTRY_TAX_SET_DEFAULT or \
					id == COMMAND_CELL_TAX_SET_DEFAULT or \
					id == COMMAND_CELL_TAX_SET_OVERRIDE or \
					id == COMMAND_COUNTRY_TAX_SET_OVERRIDE:
				var mode := _tax_assessment_mode(args)
				if mode != 0 and mode != 1:
					return _result(false, "invalid_tax_mode", "计税模式无效。")
				var rate := _tax_rate_basis_points(args)
				if mode == 1:
					if rate < -1000000000 or rate > 1000000000:
						return _result(false, "invalid_tax_rate",
							"绝对税额必须在 -1000000000 到 1000000000 之间。")
				elif rate < -100000 or rate > 10000:
					return _result(false, "invalid_tax_rate",
						"税率必须在 -1000% 到 100% 之间。")
			if id == COMMAND_COUNTRY_TAX_SET_OVERRIDE or \
					id == COMMAND_COUNTRY_TAX_CLEAR_OVERRIDE or \
					id == COMMAND_CELL_TAX_SET_OVERRIDE or \
					id == COMMAND_CELL_TAX_CLEAR_OVERRIDE:
				var item_id := StringName(args.get("item_id", &""))
				if item_id.is_empty() or not _tax_item_exists(facade, kind, item_id):
					return _result(false, "invalid_tax_item", "税务细项目标无效。")
			if id == COMMAND_CELL_TAX_SET_DEFAULT or \
					id == COMMAND_CELL_TAX_CLEAR_DEFAULT or \
					id == COMMAND_CELL_TAX_SET_OVERRIDE or \
					id == COMMAND_CELL_TAX_CLEAR_OVERRIDE:
				var owned: Dictionary = _validate_owned_cell.call(facade, int(args.get("cell", -1)))
				if not bool(owned.ok):
					return owned
		COMMAND_CELL_TAX_CLEAR_ALL:
			var owned: Dictionary = _validate_owned_cell.call(facade, int(args.get("cell", -1)))
			if not bool(owned.ok):
				return owned
		COMMAND_CONSTRUCTION_BUILD:
			if StringName(args.get("building_id", &"")).is_empty():
				return _result(false, "invalid_args", "缺少建筑标识。")
			if StringName(args.get("ownership_policy", &"")) \
					!= &"treasury_sponsored_private":
				return _result(false, "unsupported_ownership_policy",
					"当前版本仅支持国库资助私人经营。")
			var owned: Dictionary = _validate_owned_cell.call(facade, int(args.get("cell_idx", -1)))
			if not bool(owned.ok):
				return _result(false, "construction_cell_not_owned",
					"只能在玩家领土内修建建筑。")
			if facade != null and facade.has_method("has_political_capability") \
				and not facade.has_political_capability(_player_country_handle,
					&"treasury_construction"):
				return _result(false, "political_regime_lacks_treasury_construction",
					"当前体制不开放国库建造。")
		COMMAND_POLITICAL_REGIME_SET:
			var regime_id := StringName(args.get("regime_id", &""))
			if regime_id.is_empty() or facade == null \
				or not facade.has_method("political_regime_catalog_view"):
				return _result(false, "invalid_regime", "体制标识无效。")
			var regime_catalog: Dictionary = facade.political_regime_catalog_view()
			if not bool(regime_catalog.get("ok", false)):
				return _result(false, "political_regime_unavailable",
					"体制目录尚未就绪，请稍后再试。")
			var found := false
			for raw_definition in regime_catalog.get("definitions", []):
				if String((raw_definition as Dictionary).get("id", "")) == String(regime_id):
					found = true
					break
			if not found:
				return _result(false, "invalid_regime", "体制标识无效。")
		COMMAND_FAMILY_COLONIZATION_START:
			if int(args.get("family_handle", 0)) == 0 or \
					int(args.get("source_cell", -1)) < 0 or \
					int(args.get("target_cell", -1)) < 0 or \
					int(args.get("population", 0)) < 1 or \
					int(args.get("quote_token", 0)) == 0:
				return _result(false, "invalid_args", "开拓命令参数不完整。")
		COMMAND_FAMILY_COLONIZATION_CANCEL:
			if int(args.get("expedition_handle", 0)) == 0:
				return _result(false, "invalid_args", "开拓队句柄无效。")
		COMMAND_ERA_REWARD_CHOOSE:
			var choice := int(args.get("choice_index", -1))
			var generation := int(args.get("offer_generation", 0))
			if choice < 0 or choice > 2 or generation <= 0 \
					or generation != _era_reward_generation:
				return _result(false, "era_reward_choice_invalid",
					"时代奖励代际或选项无效。")
		COMMAND_FAMILY_FOUNDING_CHOOSE:
			if _economy_facade == null or not _economy_facade.has_method(
					"submit_family_founding_choice"):
				return _result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
			var founding_choice := int(args.get("choice_index", -1))
			if founding_choice < 0 or founding_choice > 2 \
					or int(args.get("offer_id", 0)) != _family_founding_offer_id \
					or _family_founding_offer_id <= 0 \
					or int(args.get("generation", 0)) != _family_founding_generation:
				return _result(false, "family_founding_choice_invalid",
					"家族候选已过期或选项无效。")
		COMMAND_IDEOLOGY_OFFER:
			if _ideology_facade == null:
				return _result(false, "runtime_unavailable", "理念系统尚未就绪，请稍后再试。")
			# Never advance time for a draw the authority would reject.
			var preview: Dictionary = ideology_offer_eligibility.call()
			if not bool(preview.get("can_draw", false)):
				var reason := String(preview.get("reason", "ideology_offer_unavailable"))
				return _result(false, reason, CountryViewModel.ideology_player_reason(reason))
		COMMAND_IDEOLOGY_REROLL:
			if _ideology_facade == null:
				return _result(false, "runtime_unavailable", "理念系统尚未就绪，请稍后再试。")
			var reroll_preview: Dictionary = ideology_offer_eligibility.call()
			if not bool(reroll_preview.get("can_reroll", false)):
				var reroll_reason := "ideology_offer_not_active" \
					if not bool(reroll_preview.get("offer_active", false)) else (
					"ideology_offer_pool_insufficient" \
					if int(reroll_preview.get("pool_size", 0)) <= 0 \
					else "ideology_points_insufficient")
				return _result(false, reroll_reason,
					CountryViewModel.ideology_player_reason(reroll_reason))
		COMMAND_IDEOLOGY_CHOOSE:
			if _ideology_facade == null:
				return _result(false, "runtime_unavailable", "理念系统尚未就绪，请稍后再试。")
			if int(args.get("offer_generation", 0)) <= 0 or \
					int(args.get("choice_index", -1)) < 0 or \
					int(args.get("choice_index", -1)) > 2:
				return _result(false, "invalid_args", "理念候选代际或选项无效。")
		COMMAND_IDEOLOGY_EQUIP, COMMAND_IDEOLOGY_UNEQUIP, \
				COMMAND_IDEOLOGY_PROMOTE:
			if _ideology_facade == null:
				return _result(false, "runtime_unavailable", "理念系统尚未就绪，请稍后再试。")
			if int(args.get("ideology_id", -1)) < 0:
				return _result(false, "invalid_args", "理念标识无效。")
		COMMAND_ERA_ADVANCE_START:
			var preview: Dictionary = _era_advancement_preview.call()
			match String(preview.get("status", "")):
				"ready":
					pass
				"max":
					return _result(false, "era_advance_max", "已到达最高时代。")
				"purchasing", "paused", "completing":
					return _result(false, "era_advance_in_progress", "时代晋升已在进行中。")
				_:
					return _result(false, "era_advance_conditions_unmet",
						"至少需要满足 2 项晋升条件。")
		COMMAND_ERA_ADVANCE_PAUSE:
			if String(_era_advancement_preview.call().get("status", "")) != "purchasing":
				return _result(false, "era_advance_not_purchasing", "当前没有进行中的收购。")
		COMMAND_ERA_ADVANCE_RESUME:
			if String(_era_advancement_preview.call().get("status", "")) != "paused":
				return _result(false, "era_advance_not_paused", "时代收购没有处于暂停状态。")
		COMMAND_PROCUREMENT_SET_POLICY:
			if not args.has("treasury_share_bp") or not args.has("research_share_bp"):
				return _result(false, "invalid_args", "国家购买预算参数不完整。")
			var policy_check: Dictionary = EraAdvancementServiceScript.validate_policy(
				int(args.get("treasury_share_bp", -1)), int(args.get("research_share_bp", -1)),
				int(args.get("era_share_bp", EraAdvancementServiceScript.SHARE_UNSET)),
				int(args.get("colonization_share_bp",
					EraAdvancementServiceScript.SHARE_UNSET)))
			if not bool(policy_check.get("ok", false)):
				return policy_check
		COMMAND_NARRATIVE_CHOOSE:
			if int(args.get("offer_id", 0)) <= 0 \
					or int(args.get("offer_generation", 0)) <= 0 \
					or int(args.get("option_index", -1)) < 0:
				return _result(false, "invalid_args", "事件选项参数无效。")
		COMMAND_MILITARY_FORCE_TARGET:
			var target_mode := int(args.get("mode", -1))
			if target_mode < 0 or target_mode > 1:
				return _result(false, "invalid_args", "目标兵力模式无效。")
			if int(args.get("value", -1)) < 0:
				return _result(false, "invalid_args", "目标兵力不能为负。")
		COMMAND_MILITARY_CONFIG_SHARES:
			if String(args.get("unit", "")).is_empty():
				return _result(false, "invalid_args", "缺少兵种标识。")
			var share_bp := int(args.get("bp", -1))
			if share_bp < 0 or share_bp > 10000:
				return _result(false, "invalid_args", "兵种份额必须在 0–100% 之间。")
		COMMAND_MILITARY_QUALITY_POLICY:
			var quality_policy := int(args.get("policy", -1))
			if quality_policy < 0 or quality_policy > 1:
				return _result(false, "invalid_args", "品质策略无效。")
		COMMAND_MILITARY_AUTO_RETRAIN, COMMAND_MILITARY_LEVY, \
				COMMAND_MILITARY_AUTO_DISCHARGE:
			if not args.has("enabled"):
				return _result(false, "invalid_args", "军事开关缺少开关值。")
		COMMAND_MILITARY_BARRACKS:
			if int(args.get("cell", -1)) < 0 or not args.has("paused"):
				return _result(false, "invalid_args", "兵营命令缺少地块或状态。")
		COMMAND_MILITARY_TRAIN:
			if int(args.get("cell", -1)) < 0 or String(args.get("to", "")).is_empty() \
					or int(args.get("count", 0)) <= 0:
				return _result(false, "invalid_args", "训练命令缺少地块、兵种或人数。")
			# 与官营建筑一致：兵种未解锁时不允许手动下达训练命令。原生
			# MCMD_TRAIN 拿不到当日 digest，闸门放在唯一的命令入口。
			var train_facade = _military_facade.call()
			if train_facade != null and train_facade.has_method("catalog"):
				var train_catalog: Dictionary = train_facade.catalog()
				var train_units: Array = train_catalog.get("units", []) if \
					train_catalog.get("units", null) is Array else []
				var train_tech := ""
				for unit_row in train_units:
					if unit_row is Dictionary and String((unit_row as Dictionary).get(
							"id", "")) == String(args.get("to", "")):
						train_tech = String((unit_row as Dictionary).get("tech", ""))
						break
				if not train_tech.is_empty():
					var train_researched = _completed_technology_ids.call()
					if train_researched == null:
						return _result(false, "technology_unknown",
							"科技状态暂不可读，稍后再试。")
					if not (train_researched as PackedStringArray).has(train_tech):
						return _result(false, "technology_locked", "尚未解锁这项科技。")
		COMMAND_MILITARY_STATE_BUILD, COMMAND_MILITARY_STATE_DEMOLISH:
			if int(args.get("cell", -1)) < 0 or int(args.get("building", -1)) < 0:
				return _result(false, "invalid_args", "官营建筑命令缺少地块或建筑。")
			# 拆除不查科技：打下别人城市的旧城墙也要能拆，只是仍需在本国领土上。
			var gate: Dictionary = _state_building_gate.call(int(args.get("cell", -1)),
				int(args.get("building", -1)), id == COMMAND_MILITARY_STATE_DEMOLISH)
			if not bool(gate.get("ok", false)):
				return _result(false, String(gate.get("code", "technology_locked")),
					String(gate.get("message", "该官营建筑尚未解锁。")))
		COMMAND_MILITARY_WAGE:
			var wage_mode := int(args.get("mode", -1))
			if wage_mode < 0 or wage_mode > 1:
				return _result(false, "invalid_args", "军饷模式无效。")
			if int(args.get("value", 0)) < 0:
				return _result(false, "invalid_args", "军饷不能为负。")
		COMMAND_MILITARY_PROCUREMENT:
			var procurement_bp := int(args.get("bp", -1))
			if procurement_bp < 0 or procurement_bp > 10000:
				return _result(false, "invalid_args", "军需采购份额必须在 0–100% 之间。")
		COMMAND_MILITARY_ARMY_CREATE:
			var cell := int(args.get("cell", -1))
			var units = args.get("units", {})
			if cell < 0 or not units is Dictionary or units.is_empty():
				return _result(false, "invalid_args", "编成部队需要所在格和驻军兵种。")
			var army_gate: Dictionary = _player_owns_military_cell.call(cell)
			if not bool(army_gate.get("ok", false)):
				return _result(false, String(army_gate.get("code", "not_own_territory")),
					String(army_gate.get("message", "只能编成本国可控领土上的驻军。")))
		COMMAND_MILITARY_ARMY_STATION, COMMAND_MILITARY_ARMY_STOP, \
				COMMAND_MILITARY_ARMY_DISBAND:
			if int(args.get("army", 0)) <= 0:
				return _result(false, "invalid_args", "部队句柄无效。")
		COMMAND_MILITARY_ARMY_MOVE:
			if int(args.get("army", 0)) <= 0 or int(args.get("cell", -1)) < 0:
				return _result(false, "invalid_args", "移动命令缺少部队或目标格。")
		COMMAND_MILITARY_AREA_CONTROL:
			if int(args.get("army", 0)) <= 0:
				return _result(false, "invalid_args", "军事控制缺少部队句柄。")
			var area_cells = args.get("cells", PackedInt32Array())
			var radius := int(args.get("radius", 0))
			if (not area_cells is PackedInt32Array or (area_cells as PackedInt32Array).is_empty()) \
					and radius <= 0:
				return _result(false, "invalid_args", "军事控制需要框选或中心格半径。")
			if radius > 6:
				return _result(false, "invalid_args", "军事控制半径上限为 6 格。")
			if area_cells is PackedInt32Array and (area_cells as PackedInt32Array).size() > 256:
				return _result(false, "invalid_args", "军事控制区域上限为 256 格。")
		COMMAND_MILITARY_ARMY_EXPLORE:
			if int(args.get("army", 0)) <= 0 or int(args.get("cell", -1)) < 0:
				return _result(false, "invalid_args", "探路命令缺少部队或中心格。")
			var explore_radius := int(args.get("radius", 0))
			if explore_radius < 1 or explore_radius > 6:
				return _result(false, "invalid_args", "探查半径必须在 1–6 格之间。")
			var explore_cells = args.get("cells", PackedInt32Array())
			if not explore_cells is PackedInt32Array \
					or (explore_cells as PackedInt32Array).is_empty() \
					or (explore_cells as PackedInt32Array).size() > 256:
				return _result(false, "invalid_args", "探查范围必须为 1–256 格。")
		COMMAND_MILITARY_ARMY_STANCE:
			var stance := int(args.get("stance", -1))
			if stance < 0 or stance > 4:
				return _result(false, "invalid_args", "部队姿态无效。")
		COMMAND_MILITARY_WAR_DECLARE:
			if int(args.get("target", 0)) == 0:
				return _result(false, "invalid_args", "宣战需要目标国家句柄。")
		COMMAND_MILITARY_PEACE_PROPOSE:
			if int(args.get("war_id", 0)) <= 0:
				return _result(false, "invalid_args", "和议需要战争标识。")
			if not args.get("terms", null) is Array:
				return _result(false, "invalid_args", "和议条款格式无效。")
		COMMAND_MILITARY_PEACE_RESPOND:
			if int(args.get("war_id", 0)) <= 0 or not args.has("accept"):
				return _result(false, "invalid_args", "和议答复缺少战争标识或结果。")
	return _result(true, "ok", "")


static func _tax_item_exists(facade, kind: int, item_id: StringName) -> bool:
	if facade == null or not facade.has_method("native_catalog"):
		return false
	var key := ""
	match kind:
		0: key = "profession_ids"
		1, 3, 4: key = "good_ids"
		2: key = "building_type_ids"
		_: return false
	var ids: PackedStringArray = facade.native_catalog().get(key, PackedStringArray())
	return ids.find(String(item_id)) >= 0


static func _tax_rate_basis_points(args: Dictionary) -> int:
	if args.has("rate_basis_points"):
		return int(args.get("rate_basis_points", 0))
	if args.has("absolute_amount"):
		return int(args.get("absolute_amount", 0))
	return int(round(float(args.get("rate_percent", 0.0)) * 100.0))


static func _tax_assessment_mode(args: Dictionary) -> int:
	return int(args.get("tax_assessment_mode", args.get("assessment_mode", 0)))


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return {"ok": ok, "code": code, "message": message}
