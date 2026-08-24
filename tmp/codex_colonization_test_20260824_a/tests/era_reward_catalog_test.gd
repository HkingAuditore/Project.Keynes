extends SceneTree

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EraRewardCatalogScript = preload("res://scripts/effect/era_reward_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

func _init() -> void:
	var technology := TechnologyCatalogScript.compile_native_catalog()
	assert(bool(technology.get("ok", false)))
	var reward := EraRewardCatalogScript.compile_native_catalog(technology)
	assert(bool(reward.get("ok", false)))
	assert(reward.era_reward_pool_ids.size() == 11)
	assert(reward.era_reward_option_ids.size() == 99)
	assert(reward.era_reward_option_offsets.size() == 12)
	assert(reward.era_reward_rule_codes.has(
		EraRewardCatalogScript.WeightCondition.SIGNAL_PRESENT))
	assert(reward.era_reward_rule_codes.has(
		EraRewardCatalogScript.WeightCondition.ROUTE_COMPLETED))
	assert(reward.era_reward_rule_signal_indices.size() ==
		reward.era_reward_rule_codes.size())
	assert(reward.era_reward_rule_route_technology_offsets.size() ==
		reward.era_reward_rule_codes.size() + 1)
	assert(not reward.era_reward_rule_route_technology_indices.is_empty())
	for pool in range(11):
		assert(int(reward.era_reward_option_offsets[pool + 1]) -
			int(reward.era_reward_option_offsets[pool]) == 9)
		var fallbacks := 0
		for option in range(reward.era_reward_option_offsets[pool],
				reward.era_reward_option_offsets[pool + 1]):
			fallbacks += int(reward.era_reward_option_fallback[option])
			assert(int(reward.era_reward_command_offsets[option + 1]) -
				int(reward.era_reward_command_offsets[option]) >= 1)
		assert(fallbacks == 3)
	for top_n in reward.era_reward_selector_top_n:
		assert(int(top_n) >= 1 and int(top_n) <= 32)
	var modifier = ModifierCatalogScript.load_default()
	var modifier_ir: Dictionary = modifier.compile_native_catalog()
	assert(bool(modifier_ir.get("ok", false)))
	var reward_modifiers := 0
	for key in modifier_ir.definition_keys:
		if String(key).begins_with("era_reward."):
			reward_modifiers += 1
	assert(reward_modifiers == 99)
	var effect = EffectDomainCatalogScript.build()
	assert(effect != null)
	var effect_ir: Dictionary = effect.compile_native_catalog()
	assert(bool(effect_ir.get("ok", false)))
	assert(effect_ir.era_reward_pool_ids.size() == 11)
	var ext := DCWorldExt.new()
	var configured: Dictionary = ext.configure_effects(_without_ok(effect_ir))
	assert(bool(configured.get("ok", false)), String(configured.get("reason", "")))
	print("[PASS] era reward catalog: 11 pools / 99 options / 33 fallbacks")
	quit(0)

func _without_ok(source: Dictionary) -> Dictionary:
	var out := source.duplicate(false)
	out.erase("ok")
	return out
