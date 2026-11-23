extends "res://tests/technology/era_advancement_service_test.gd"

const CatalogScript = preload("res://scripts/era/era_advancement_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")


func _check_catalog() -> void:
	super._check_catalog()
	var technology := TechnologyCatalogScript.compile_native_catalog()
	var economy := EconomyCatalogScript.compile_native_catalog()
	_expect("technology catalog compiles", bool(technology.get("ok", false)))
	_expect("economy catalog compiles", bool(economy.get("ok", false)))
	_check_authored_catalog(technology, economy)
	for command in [&"era.advance.start", &"era.advance.pause", &"era.advance.resume",
			&"procurement.set_policy"]:
		_expect("controller allowlists %s" % command, PlayerController.SUPPORTED_COMMANDS.has(command))
	_expect("milestones are detected for research rejection",
		PlayerController.is_milestone_technology(&"tech.agrarian_society")
		and not PlayerController.is_milestone_technology(&"tech.hunting"))


func _check_model(model: Dictionary) -> void:
	super._check_model(model)
	_check_snapshot_shape(model)


func _check_authored_catalog(technology: Dictionary, economy_catalog: Dictionary) -> void:
	var good_ids: PackedStringArray = economy_catalog.get("good_ids", PackedStringArray())
	for good_id in CatalogScript.all_good_ids():
		_expect("procurement good exists: %s" % good_id, good_ids.has(good_id))
	# The first advancement happens in the opening economy. A required good that
	# no one produces yet can never be bought, so the purchase would sit at
	# partial progress forever (flint did exactly that in a real session).
	const START_MARKET_GOODS := ["clothing", "game_meat", "gathered_plants", "logs"]
	for row in CatalogScript.procurement_goods(1):
		_expect("first advancement good is sold at game start: %s" % String(row.good_id),
			START_MARKET_GOODS.has(String(row.good_id)))
	for target in range(1, 11):
		_expect("era %d has rules" % target, CatalogScript.is_valid_target(target)
			and CatalogScript.population_threshold(target) > CatalogScript.population_threshold(target - 1)
			and CatalogScript.building_threshold(target) > CatalogScript.building_threshold(target - 1)
			and CatalogScript.trade_order_threshold(target) > CatalogScript.trade_order_threshold(target - 1)
			and not CatalogScript.procurement_goods(target).is_empty())
	var ids: PackedStringArray = technology.technology_ids
	var offsets: PackedInt32Array = technology.technology_modifier_term_offsets
	for era_index in range(11):
		var milestone := String(CatalogScript.milestone_id(era_index))
		var index := ids.find(milestone)
		_expect("milestone %s carries 2-3 buff terms" % milestone, index >= 0
			and offsets[index + 1] - offsets[index] >= 2 and offsets[index + 1] - offsets[index] <= 3)
		_expect("milestone %s summary is a promotion buff" % milestone,
			String(technology.technology_effect_summaries[index]).begins_with("时代晋升效果："))
		_expect("buff lines match terms for %s" % milestone,
			CatalogScript.milestone_buff_lines(StringName(milestone)).size()
			== offsets[index + 1] - offsets[index])


func _check_snapshot_shape(model: Dictionary) -> void:
	var keys := ["ok", "current_era_index", "current_era_name", "next_era_index",
		"next_era_name", "status", "conditions", "conditions_met", "conditions_required",
		"can_start", "territory_count", "frozen_territory_count", "costs", "progress",
		"buffs_preview", "budget"]
	var sorted_model: Array = model.keys()
	sorted_model.sort()
	keys.sort()
	_expect("snapshot has exactly the §5 keys", sorted_model == keys)
	_expect("conditions are tech/population/buildings/trade",
		(model.conditions as Array).size() == 4
		and String(model.conditions[0].key) == "tech"
		and String(model.conditions[3].key) == "trade")
	for row in model.conditions:
		var row_keys: Array = (row as Dictionary).keys()
		row_keys.erase("tooltip")   # optional explanatory tooltip (all rows)
		row_keys.erase("mandatory")  # tech row is always mandatory since v5
		row_keys.sort()
		_expect("condition row shape", row_keys == ["current", "key", "label", "met", "target", "text"])
	for row in model.costs:
		var cost_keys: Array = (row as Dictionary).keys()
		cost_keys.sort()
		_expect("cost row shape", cost_keys == ["good_id", "in_treasury", "name", "ratio", "required"])
	var budget_keys: Array = (model.budget as Dictionary).keys()
	budget_keys.sort()
	_expect("budget shape", budget_keys == ["colonization_daily",
		"colonization_share_bp", "era_daily", "era_share_bp", "national_daily",
		"research_share_bp", "treasury_share_bp"])
	_expect("buffs preview is PackedStringArray", model.buffs_preview is PackedStringArray)
	_expect("conditions_required is 3 (tech mandatory + 2 of 3 economy)",
		int(model.conditions_required) == 3)
