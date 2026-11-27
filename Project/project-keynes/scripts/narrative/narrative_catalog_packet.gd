extends RefCounted

const Rebellion = preload("res://scripts/politics/stratum_rebellion_content.gd")
const Probes = preload("res://scripts/narrative/narrative_state_probe_catalog.gd")
const EffectSpec = preload("res://scripts/narrative/narrative_effect_spec.gd")
const PauseCategories = preload("res://scripts/narrative/narrative_pause_categories.gd")
const ERA_NAMES := [
	"石器时代", "农耕时代", "青铜与城邦时代", "古典王国时代", "帝国与封建时代",
	"文艺复兴与航海时代", "工场手工业时代", "蒸汽工业时代", "电气与钢铁时代", "原子与信息时代", "智能与生态时代",
]

const AI_FACT_HINTS := {
	3: "天气锋面过境", 6: "营造完工", 7: "商队抵达", 8: "民生压力上升",
	9: "科研线索被发现", 10: "地图地貌新发现", 13: "技术被采纳",
	40: "战事爆发", 41: "战事结束", 42: "会战分出胜负", 43: "城池易手",
	44: "部队被歼", 45: "国家被吞并",
}
const UNREST_PROFESSIONS := {
	"soldier": "军士", "farmer": "农户", "subsistence_farmer": "小农",
	"tenant_farmer": "佃户", "sharecropper": "分成佃农", "agricultural_worker": "农工",
	"artisan": "匠户", "apprentice": "学徒", "journeyman": "帮工", "guild_master": "行会师傅",
	"miner": "矿工", "industrial_worker": "工厂工人", "worker": "工人",
	"merchant": "商人", "scholar": "读书人", "scribe": "书吏", "serf": "农奴",
	"unemployed": "失业者", "landlord": "地主", "industrialist": "厂主",
}


static func build(catalog: NarrativeEventCatalog, generator, clock: WorldClock,
		player: int, seed: int, enable_ai: bool, pause_mask: int) -> Dictionary:
	var economy = generator.get_economy_facade()
	var country = generator.get_country_facade().native_catalog()
	var professions := {}
	for id: String in economy.profession_ids():
		professions[id] = economy.profession_display_name(StringName(id))
	var good_names := {}
	var good_ids_raw: PackedStringArray = country.get("good_ids", PackedStringArray())
	for gid: String in good_ids_raw:
		good_names[gid] = EffectSpec._friendly_good_name(StringName(gid))
	var technology_names := {}
	var tech_ids_raw: PackedStringArray = country.get("technology_ids", PackedStringArray())
	var tech_display_raw: PackedStringArray = country.get("technology_display_names", PackedStringArray())
	for i in range(tech_ids_raw.size()):
		var tid := String(tech_ids_raw[i])
		var tname := String(tech_display_raw[i]).strip_edges() if i < tech_display_raw.size() else ""
		technology_names[tid] = tname if not tname.is_empty() else tid
	var definitions: Array[Dictionary] = []
	for event in catalog.events:
		definitions.append(encode_event(event))
	var probes: Array[Dictionary] = []
	for probe in Probes.build_default_probes():
		probes.append(probe.to_dict())
	var terrain_names := PackedStringArray()
	for index in TerrainType.TERRAIN.values():
		terrain_names.append(TerrainType.terrain_name_cn(index))
	var landform_names := PackedStringArray()
	for index in LandformType.LF.values():
		landform_names.append(LandformType.name_cn(index))
	var vegetation_names := PackedStringArray()
	for index in VegetationType.VEG.values():
		vegetation_names.append(VegetationType.name_cn(index))
	var unrest: Array[Dictionary] = []
	var actions_by_stage: Array = []
	for stage in range(1, 5):
		actions_by_stage.append(Rebellion.actions_for_stage(stage))
	for key in ["", "soldier", "merchant"]:
		for stage in range(1, 5):
			var event := Rebellion.build(stage, "{unrest_profession}", "{settlement_name}",
				actions_by_stage[stage - 1], {}, [], key)
			# 32768 is the authored template's provisional chance. The executor
			# publishes the actual odds alongside the chosen cell and profession.
			for option in event.options:
				option.tooltip_hint = option.tooltip_hint.replace("50%", "{unrest_chance}%")
			unrest.append(encode_event(event))
	return {
		"country": player, "seed": seed, "ai_enabled": enable_ai, "event_pause_mask": pause_mask,
		"days_per_year": clock.days_per_year(), "month_lengths": WorldClock._MONTH_LENGTHS,
		"events": definitions, "probes": probes, "unrest": unrest, "unrest_actions": actions_by_stage,
		"terrain_names": terrain_names, "landform_names": landform_names,
		"vegetation_names": vegetation_names, "era_names": PackedStringArray(ERA_NAMES),
		"era_milestones": CountryFacade.era_milestone_indices(),
		"technology_ids": country.get("technology_ids", PackedStringArray()),
		"good_ids": country.get("good_ids", PackedStringArray()),
		"signal_ids": country.get("research_signal_ids", PackedStringArray()),
		"profession_names": professions, "unrest_profession_names": UNREST_PROFESSIONS,
		"good_names": good_names, "technology_names": technology_names,
		"ai_fact_hints": AI_FACT_HINTS,
	}


static func encode_event(event: NarrativeEventDefinition) -> Dictionary:
	var raw := event.to_dict()
	raw["event_category"] = PauseCategories.category(String(event.event_id))
	raw["event_notification"] = event.event_id == &"evt.chain.ancient_foundry_legacy"
	for index in range(event.options.size()):
		var option: NarrativeOption = event.options[index]
		var row: Dictionary = raw.options[index]
		row["probabilities"] = option.normalized_probabilities_q16()
		row["require_good_name"] = EffectSpec._friendly_good_name(option.require_good_id)
		for outcome_idx in range(option.outcomes.size()):
			var descriptions: Array[String] = []
			var outcome: Dictionary = row.outcomes[outcome_idx]
			var effects: Array = option.outcomes[outcome_idx].effects
			for effect_idx in effects.size():
				var effect: NarrativeEffectSpec = effects[effect_idx]
				if event.is_ai_generated and effect.kind in [
						EffectSpec.Kind.COUNTRY_GOOD_TO_MARKET, EffectSpec.Kind.MARKET_GOOD_TO_COUNTRY,
						EffectSpec.Kind.MARKET_ADD_STOCK, EffectSpec.Kind.MARKET_REMOVE_STOCK]:
					outcome.effects[effect_idx]["target_display_name"] = EffectSpec._friendly_good_name(effect.target_key)
				descriptions.append(effect.describe())
			outcome["effect_descriptions"] = descriptions
	for index in range(event.on_trigger_effects.size()):
		raw.on_trigger_effects[index]["description"] = event.on_trigger_effects[index].describe()
	return raw
