class_name IconCatalog
extends RefCounted

const IconSemantics = preload("res://scripts/ui/icon_catalog_semantics.gd")

const PaperIconTextures = preload("res://scripts/ui/paper_icon_textures.gd")

const PaperBuildingIcon = preload("res://scripts/ui/paper_building_icon.gd")


const FAMILY_FONT_AWESOME := &"fontawesome"
const FAMILY_LUCIDE := &"lucide"
const FAMILY_TABLER := &"tabler"
const FAMILY_HUD := &"hud"
const FAMILY_PAPER := &"project_keynes"

static var _paper_building_textures: Dictionary = {}

const PAPER_ALIASES := {
	&"population.profession.artisan": &"profession.artisan",
	&"population.profession.fisher": &"profession.fisher",
	&"population.profession.merchant": &"profession.merchant",
	&"population.profession.owner": &"profession.landlord",
	&"population.profession.scholar": &"profession.scholar",
	&"population.profession.unemployed": &"profession.unemployed",
	&"population.profession.worker": &"profession.worker",
	&"economy.crop": &"good.grain",
	&"economy.fuel": &"good.refined_fuel",
	&"economy.livestock": &"resource.animal",
	&"economy.resource": &"resource.precious",
	&"action.pause": &"hud.clock.pause",
	&"action.play": &"hud.clock.play",
	&"climate.sun": &"hud.system.day_night_off",
	&"climate.weather": &"hud.overlay.climate",
	&"country.affairs": &"summary.overview",
	&"country.diplomacy": &"hud.country.diplomacy",
	&"country.military": &"hud.country.military",
	&"country.politics": &"hud.country.ideology",
	&"country.economy": &"hud.country.economy",
	&"country.technology": &"hud.country.technology",
	&"family.house": &"family.workspace.crest",
	&"family.workspace.overview": &"summary.overview",
	&"family.metric.population": &"family.workspace.people",
	&"family.metric.wealth": &"hud.country.economy",
	&"family.metric.buildings": &"economy.building",
	&"family.metric.time": &"system.clock",
	&"hud.system.gm": &"hud.system.settings",
	&"hydrology.water": &"hydrology.current",
	&"metric.technology": &"hud.country.technology",
	&"metric.territory": &"hud.overlay.geography",
	&"metric.treasury": &"hud.country.economy",
	&"map.population": &"family.workspace.people",
	&"map.construction": &"good.tools",
	&"system.calendar": &"hud.clock.calendar",
	&"system.settings": &"hud.system.settings",
	&"technology.domain.agriculture": &"good.grain",
	&"technology.domain.engineering": &"good.tools",
	&"technology.domain.science": &"good.scientific_instruments",
	&"technology.domain.society": &"family.workspace.people",
	&"technology.state.completed": &"action.confirm",
	&"technology.state.pending": &"system.clock",
	&"technology.state.unknown": &"system.unknown",

}


# BEGIN GENERATED PAPER ICONS
const PAPER_TEXTURES := PaperIconTextures.PAPER_TEXTURES

# 军事纸贴：assets/military/codex 由 tools/ui/build_military_codex_icons.py
# 从四张专用手绘母图切出。每个兵种/装备类别/军需/建筑/战势都有独立纸贴；
# 旧语义键保留为别名，避免 UI 与测试层被迫跟随素材重构。
const MILITARY_PAPER_TEXTURES := {
	&"military.army.attack": preload("res://assets/military/codex/military_army_attack.tres"),
	&"military.army.defense": preload("res://assets/military/codex/military_army_defense.tres"),
	&"military.army.morale": preload("res://assets/military/codex/military_army_morale.tres"),
	&"military.army.organization": preload("res://assets/military/codex/military_army_organization.tres"),
	&"military.army.pay": preload("res://assets/military/codex/military_army_pay.tres"),
	&"military.army.supply": preload("res://assets/military/codex/military_army_supply.tres"),
	&"military.building.academy": preload("res://assets/military/codex/military_building_academy.tres"),
	&"military.building.bunker": preload("res://assets/military/codex/military_building_bunker.tres"),
	&"military.building.depot": preload("res://assets/military/codex/military_building_depot.tres"),
	&"military.building.legion_fort": preload("res://assets/military/codex/military_building_legion_fort.tres"),
	&"military.building.modern_base": preload("res://assets/military/codex/military_building_modern_base.tres"),
	&"military.building.palisade_barracks": preload("res://assets/military/codex/military_building_palisade_barracks.tres"),
	&"military.building.rampart": preload("res://assets/military/codex/military_building_rampart.tres"),
	&"military.building.simulation_center": preload("res://assets/military/codex/military_building_simulation_center.tres"),
	&"military.building.star_fort": preload("res://assets/military/codex/military_building_star_fort.tres"),
	&"military.building.stone_wall": preload("res://assets/military/codex/military_building_stone_wall.tres"),
	&"military.building.training_ground": preload("res://assets/military/codex/military_building_training_ground.tres"),
	&"military.building.tribal_lodge": preload("res://assets/military/codex/military_building_tribal_lodge.tres"),
	&"military.good.ammunition": preload("res://assets/military/codex/military_good_ammunition.tres"),
	&"military.good.armored_vehicles": preload("res://assets/military/codex/military_good_armored_vehicles.tres"),
	&"military.good.body_armor": preload("res://assets/military/codex/military_good_body_armor.tres"),
	&"military.good.drones": preload("res://assets/military/codex/military_good_drones.tres"),
	&"military.good.electronics": preload("res://assets/military/codex/military_good_electronics.tres"),
	&"military.good.firearms": preload("res://assets/military/codex/military_good_firearms.tres"),
	&"military.good.fuel": preload("res://assets/military/codex/military_good_fuel.tres"),
	&"military.good.melee_arms": preload("res://assets/military/codex/military_good_melee_arms.tres"),
	&"military.good.missile_arms": preload("res://assets/military/codex/military_good_missile_arms.tres"),
	&"military.good.mounts": preload("res://assets/military/codex/military_good_mounts.tres"),
	&"military.good.ordnance": preload("res://assets/military/codex/military_good_ordnance.tres"),
	&"military.good.propellant": preload("res://assets/military/codex/military_good_propellant.tres"),
	&"military.ledger.convoy": preload("res://assets/military/codex/military_ledger_convoy.tres"),
	&"military.ledger.secure_convoy": preload("res://assets/military/codex/military_ledger_secure_convoy.tres"),
	&"military.supply.equipment": preload("res://assets/military/codex/military_supply_equipment.tres"),
	&"military.supply.fodder": preload("res://assets/military/codex/military_supply_fodder.tres"),
	&"military.supply.ration": preload("res://assets/military/codex/military_supply_ration.tres"),
	&"profession.soldier": preload("res://assets/military/codex/military_unit_line_infantry.tres"),
	&"military.unit.archer": preload("res://assets/military/codex/military_unit_archer.tres"),
	&"military.unit.cavalry": preload("res://assets/military/codex/military_unit_cavalry.tres"),
	&"military.unit.chariot": preload("res://assets/military/codex/military_unit_chariot.tres"),
	&"military.unit.drone": preload("res://assets/military/codex/military_unit_drone.tres"),
	&"military.unit.early_tank": preload("res://assets/military/codex/military_unit_early_tank.tres"),
	&"military.unit.field_artillery": preload("res://assets/military/codex/military_unit_field_artillery.tres"),
	&"military.unit.legionary": preload("res://assets/military/codex/military_unit_legionary.tres"),
	&"military.unit.line_infantry": preload("res://assets/military/codex/military_unit_line_infantry.tres"),
	&"military.unit.machine_gunner": preload("res://assets/military/codex/military_unit_machine_gunner.tres"),
	&"military.unit.militia": preload("res://assets/military/codex/military_unit_militia.tres"),
	&"military.unit.musketeer": preload("res://assets/military/codex/military_unit_musketeer.tres"),
	&"military.unit.rifleman": preload("res://assets/military/codex/military_unit_rifleman.tres"),
	&"military.unit.shield_bearers": preload("res://assets/military/codex/military_unit_shield_bearers.tres"),
	&"military.unit.siege_train": preload("res://assets/military/codex/military_unit_siege_train.tres"),
	&"military.unit.spearmen": preload("res://assets/military/codex/military_unit_spearmen.tres"),
	&"military.unit.tank": preload("res://assets/military/codex/military_unit_tank.tres"),
	&"military.unit.tribal": preload("res://assets/military/codex/military_unit_tribal.tres"),
	&"military.war.battle": preload("res://assets/military/codex/military_war_battle.tres"),
	&"military.war.front": preload("res://assets/military/codex/military_war_front.tres"),
	&"military.war.peace": preload("res://assets/military/codex/military_war_peace.tres"),
	&"military.war.score": preload("res://assets/military/codex/military_war_score.tres"),
	&"military.war.truce": preload("res://assets/military/codex/military_war_truce.tres"),
	# 兼容旧 UI 调用的类别别名。
	&"military.unit.line": preload("res://assets/military/codex/military_unit_spearmen.tres"),
	&"military.unit.line.bows": preload("res://assets/military/codex/military_unit_archer.tres"),
	&"military.unit.mobile": preload("res://assets/military/codex/military_unit_cavalry.tres"),
	&"military.unit.artillery": preload("res://assets/military/codex/military_unit_field_artillery.tres"),
	&"military.unit.armored": preload("res://assets/military/codex/military_unit_tank.tres"),
	&"military.unit.air": preload("res://assets/military/codex/military_unit_drone.tres"),
	&"military.banner": preload("res://assets/military/codex/military_army_morale.tres"),
	&"military.good.armor": preload("res://assets/military/codex/military_good_body_armor.tres"),
	&"military.good.bows": preload("res://assets/military/codex/military_good_missile_arms.tres"),
	&"military.good.military_electronics": preload("res://assets/military/codex/military_good_electronics.tres"),
	&"military.building.barracks": preload("res://assets/military/codex/military_building_palisade_barracks.tres"),
	&"military.building.fortification": preload("res://assets/military/codex/military_building_stone_wall.tres"),
	&"military.building.war_college": preload("res://assets/military/codex/military_building_academy.tres"),
	&"military.building.storage": preload("res://assets/military/codex/military_building_depot.tres"),
	# 计划/账本仍使用既有纸贴；它们不是本轮兵种与军需的主体缺口。
	&"military.plan.target": preload("res://assets/military/plan_target.tres"),
	&"military.plan.share": preload("res://assets/military/plan_share.tres"),
	&"military.plan.quality": preload("res://assets/military/plan_quality.tres"),
	&"military.plan.barracks": preload("res://assets/military/plan_barracks.tres"),
	&"military.plan.training": preload("res://assets/military/plan_training.tres"),
	&"military.ledger.income": preload("res://assets/military/ledger_income.tres"),
	&"military.ledger.wage": preload("res://assets/military/ledger_wage.tres"),
}
# END GENERATED PAPER ICONS


## Stable military unit id -> dedicated codex sticker. Class keys remain the
## fallback for units added later; the era-specific art must not leak into
## battle/runtime data, only the presentation lookup.
const MILITARY_UNIT_ICONS := {
	&"militia": &"military.unit.militia",
	&"tribal_warriors": &"military.unit.tribal",
	&"bronze_spearmen": &"military.unit.spearmen",
	&"iron_infantry": &"military.unit.legionary",
	&"legionaries": &"military.unit.legionary",
	&"cavalry": &"military.unit.cavalry",
	&"heavy_cavalry": &"military.unit.cavalry",
	&"dragoons": &"military.unit.cavalry",
	&"chariot_troops": &"military.unit.chariot",
	&"musketeers": &"military.unit.musketeer",
	&"line_infantry": &"military.unit.line_infantry",
	&"riflemen": &"military.unit.rifleman",
	&"shield_bearers": &"military.unit.shield_bearers",
	&"machine_gunners": &"military.unit.machine_gunner",
	&"field_artillery": &"military.unit.field_artillery",
	&"heavy_artillery": &"military.unit.field_artillery",
	&"siege_train": &"military.unit.siege_train",
	&"early_armor": &"military.unit.early_tank",
	&"tank_corps": &"military.unit.tank",
	&"mechanized_infantry": &"military.unit.tank",
	&"combined_arms": &"military.unit.tank",
	&"sp_artillery": &"military.unit.field_artillery",
	&"missile_artillery": &"military.unit.field_artillery",
	&"exo_infantry": &"military.unit.line_infantry",
	&"drone_swarm": &"military.unit.drone",
}

## Military goods keep one silhouette per equipment family. Quality tiers stay
## readable through Q1-Q5 text and the distinct icon identity, avoiding 30+
## nearly identical rifle/spear variants at 24 px.
const MILITARY_GOOD_ICONS := {
	&"armor_plate": &"military.good.body_armor",
	&"stone_spears": &"military.good.melee_arms",
	&"bronze_weapons": &"military.good.melee_arms",
	&"iron_weapons": &"military.good.melee_arms",
	&"steel_blades": &"military.good.melee_arms",
	&"bows": &"military.good.missile_arms",
	&"matchlocks": &"military.good.firearms",
	&"flintlocks": &"military.good.firearms",
	&"rifles": &"military.good.firearms",
	&"automatic_rifles": &"military.good.firearms",
	&"smart_rifles": &"military.good.firearms",
	&"siege_engines": &"military.good.ordnance",
	&"bronze_cannon": &"military.good.ordnance",
	&"steel_artillery": &"military.good.ordnance",
	&"howitzers": &"military.good.ordnance",
	&"missile_launchers": &"military.good.ordnance",
	&"hide_armor": &"military.good.body_armor",
	&"iron_armor": &"military.good.body_armor",
	&"plate_armor": &"military.good.body_armor",
	&"ballistic_armor": &"military.good.body_armor",
	&"horses": &"military.good.mounts",
	&"war_chariots": &"military.good.mounts",
	&"early_tanks": &"military.good.armored_vehicles",
	&"modern_tanks": &"military.good.armored_vehicles",
	&"combat_drones": &"military.good.drones",
	&"powder_shot": &"military.good.ammunition",
	&"cartridges": &"military.good.ammunition",
	&"modern_munitions": &"military.good.ammunition",
	&"guided_munitions": &"military.good.ammunition",
	&"black_powder": &"military.good.propellant",
	&"smokeless_powder": &"military.good.propellant",
	&"modern_propellant": &"military.good.propellant",
	&"nitric_acid": &"military.good.propellant",
	&"refined_fuel": &"military.good.fuel",
	&"military_electronics": &"military.good.electronics",
}

const MILITARY_BUILDING_ICONS := {
	&"warrior_lodge": &"military.building.tribal_lodge",
	&"palisade_barracks": &"military.building.palisade_barracks",
	&"garrison_barracks": &"military.building.palisade_barracks",
	&"legion_fort": &"military.building.legion_fort",
	&"drill_depot": &"military.building.training_ground",
	&"army_depot": &"military.building.depot",
	&"military_base": &"military.building.modern_base",
	&"training_complex": &"military.building.modern_base",
	&"earthen_rampart": &"military.building.rampart",
	&"stone_walls": &"military.building.stone_wall",
	&"citadel": &"military.building.star_fort",
	&"star_fort": &"military.building.star_fort",
	&"bunker_line": &"military.building.bunker",
	&"hardened_defense_network": &"military.building.bunker",
	&"martial_academy": &"military.building.academy",
	&"military_academy": &"military.building.academy",
	&"war_simulation_center": &"military.building.simulation_center",
}

const MILITARY_BUILDING_ROLE_ICONS := {
	&"barracks": &"military.building.palisade_barracks",
	&"fortification": &"military.building.stone_wall",
	&"war_college": &"military.building.academy",
	&"storage": &"military.building.depot",
}


const GOOD_IDS := {
	&"adobe_brick": true,
	&"advanced_chips": true,
	&"agricultural_machinery": true,
	&"aluminum": true,
	&"ammonia": true,
	&"antibiotics": true,
	&"armor_plate": true,
	&"automobiles": true,
	&"automatic_rifles": true,
	&"autonomous_systems": true,
	&"ballistic_armor": true,
	&"bast_fiber": true,
	&"batteries": true,
	&"bauxite": true,
	&"beverages": true,
	&"black_powder": true,
	&"bows": true,
	&"bread": true,
	&"bricks": true,
	&"brine": true,
	&"bronze_cannon": true,
	&"bronze_tools": true,
	&"bronze_weapons": true,
	&"canned_fish": true,
	&"cartridges": true,
	&"cement": true,
	&"charcoal": true,
	&"chipped_stone_tools": true,
	&"clay": true,
	&"cloth": true,
	&"clothing": true,
	&"coal": true,
	&"coke": true,
	&"combat_drones": true,
	&"computers": true,
	&"concrete": true,
	&"construction_components": true,
	&"copper": true,
	&"copper_ore": true,
	&"copper_tools": true,
	&"corn_grain": true,
	&"cotton_fiber": true,
	&"crude_oil": true,
	&"dairy_products": true,
	&"detergent": true,
	&"dyestuff": true,
	&"early_tanks": true,
	&"edible_oil": true,
	&"electric_motor": true,
	&"electrical_equipment": true,
	&"electricity": true,
	&"electronic_components": true,
	&"engines": true,
	&"explosives": true,
	&"fertilizer": true,
	&"fine_clothing": true,
	&"fine_furniture": true,
	&"fish": true,
	&"flax_fiber": true,
	&"flint": true,
	&"flintlocks": true,
	&"footwear": true,
	&"frozen_food": true,
	&"fur": true,
	&"furniture": true,
	&"game_meat": true,
	&"gathered_plants": true,
	&"glass": true,
	&"glassware": true,
	&"gold": true,
	&"grain": true,
	&"guided_munitions": true,
	&"hide_armor": true,
	&"horses": true,
	&"household_appliances": true,
	&"howitzers": true,
	&"industrial_chemicals": true,
	&"industrial_machinery": true,
	&"insulated_cable": true,
	&"iron_armor": true,
	&"iron_ore": true,
	&"iron_weapons": true,
	&"jewelry": true,
	&"latex": true,
	&"lead": true,
	&"lead_ore": true,
	&"leather": true,
	&"leather_goods": true,
	&"lime": true,
	&"limestone": true,
	&"livestock_products": true,
	&"logs": true,
	&"lubricants": true,
	&"lumber": true,
	&"machine_parts": true,
	&"manganese_ore": true,
	&"manuscripts": true,
	&"matchlocks": true,
	&"meat": true,
	&"medicinal_herbs": true,
	&"metal_housewares": true,
	&"military_electronics": true,
	&"missile_launchers": true,
	&"modern_munitions": true,
	&"modern_propellant": true,
	&"modern_tanks": true,
	&"natural_gas": true,
	&"natural_rubber": true,
	&"nitric_acid": true,
	&"nuclear_fuel": true,
	&"oceanic_vessels": true,
	&"packaging": true,
	&"paper": true,
	&"petrochemicals": true,
	&"pharmaceuticals": true,
	&"phosphate_rock": true,
	&"plastics": true,
	&"plate_armor": true,
	&"potatoes": true,
	&"pottery": true,
	&"powder_shot": true,
	&"precision_tools": true,
	&"prepared_staples": true,
	&"printed_materials": true,
	&"processed_food": true,
	&"radio_equipment": true,
	&"railway_equipment": true,
	&"rare_earth_metals": true,
	&"rare_earth_ore": true,
	&"raw_hide": true,
	&"raw_stone": true,
	&"reactor_components": true,
	&"reed_bundle": true,
	&"refined_fuel": true,
	&"rice_grain": true,
	&"rifles": true,
	&"salt": true,
	&"saltpeter": true,
	&"scientific_instruments": true,
	&"seed_cotton": true,
	&"semiconductors": true,
	&"siege_engines": true,
	&"silica_sand": true,
	&"silver": true,
	&"smart_rifles": true,
	&"smokeless_powder": true,
	&"soap": true,
	&"spices": true,
	&"stainless_steel": true,
	&"steam_engines": true,
	&"steel": true,
	&"steel_artillery": true,
	&"steel_blades": true,
	&"stone_spears": true,
	&"structural_steel": true,
	&"sulfur": true,
	&"synthetic_fiber": true,
	&"synthetic_rubber": true,
	&"technology_points": true,
	&"telecom_equipment": true,
	&"tin": true,
	&"tin_ore": true,
	&"tools": true,
	&"turf_block": true,
	&"vegetables": true,
	&"war_chariots": true,
	&"wheat_grain": true,
	&"wire": true,
	&"wool": true,
	&"wrought_iron": true,
	&"zinc": true,
	&"zinc_ore": true,
}

const PROFESSION_IDS := {
	&"agricultural_worker": true,
	&"agronomist": true,
	&"ai_researcher": true,
	&"apprentice": true,
	&"aquaculturist": true,
	&"artisan": true,
	&"chemist": true,
	&"construction_worker": true,
	&"cooperative_member": true,
	&"corvee_worker": true,
	&"data_scientist": true,
	&"dyer": true,
	&"electrician": true,
	&"engineer": true,
	&"enslaved_laborer": true,
	&"fisher": true,
	&"forager": true,
	&"forestry_worker": true,
	&"guild_master": true,
	&"household_farmer": true,
	&"hunter": true,
	&"indentured_laborer": true,
	&"industrialist": true,
	&"industrial_worker": true,
	&"journeyman": true,
	&"landlord": true,
	&"lorekeeper": true,
	&"machinist": true,
	&"manager": true,
	&"merchant": true,
	&"metallurgist": true,
	&"miner": true,
	&"natural_philosopher": true,
	&"pastoralist": true,
	&"petroleum_worker": true,
	&"research_scientist": true,
	&"researcher": true,
	&"scholar": true,
	&"scientist": true,
	&"scribe": true,
	&"serf": true,
	&"sharecropper": true,
	&"ship_officer": true,
	&"soldier": true,
	&"subsistence_farmer": true,
	&"technician": true,
	&"tenant_farmer": true,
	&"transport_worker": true,
	&"unemployed": true,
	&"worker": true,
}

const SPECS := IconSemantics.SPECS
const COMPATIBILITY_ALIASES := IconSemantics.COMPATIBILITY_ALIASES

const ALLOWED_SHARED_IMPLEMENTATIONS := {}


static func resolve_semantic(key: StringName) -> StringName:
	if key == &"" or String(key) == "\u2014":
		return &""
	if SPECS.has(key) or PAPER_TEXTURES.has(key) or MILITARY_PAPER_TEXTURES.has(key):
		return key
	var raw := String(key)
	if raw.begins_with("building.") and _building_product_id(raw) != &"":
		return key
	if raw.begins_with("good.") and (GOOD_IDS.has(StringName(raw.trim_prefix("good."))) \
			or MILITARY_PAPER_TEXTURES.has(StringName("military.%s" % raw))):
		return key
	if raw.begins_with("profession.") \
			and PROFESSION_IDS.has(StringName(raw.trim_prefix("profession."))):
		return key
	return COMPATIBILITY_ALIASES.get(String(key), &"system.unknown") as StringName


static func resolve_key(key: String) -> String:
	return String(resolve_semantic(StringName(key)))


static func spec_for(key: StringName) -> Dictionary:
	var semantic := resolve_semantic(key)
	var raw := String(semantic)
	if semantic == &"":
		return {}
	if raw.begins_with("good."):
		var good_id := StringName(raw.trim_prefix("good."))
		var military_good_key: StringName = MILITARY_GOOD_ICONS.get(good_id, &"")
		if MILITARY_PAPER_TEXTURES.has(military_good_key):
			# 同一装备家族的 Q1-Q5 仍保留独立语义身份；品质由文字承载，
			# 避免 24px 表格里堆出几十张几乎相同的枪炮小图。
			return {"family": FAMILY_PAPER,
				"texture": MILITARY_PAPER_TEXTURES[military_good_key],
				"identity": "military_good:%s" % good_id}
	if raw.begins_with("good.") and MILITARY_PAPER_TEXTURES.has(
			StringName("military.%s" % raw)):
		# 军需物资走军事图集：与居民物资同名的物件要看得出「这是军用品」。
		var military_key := StringName("military.%s" % raw)
		return {"family": FAMILY_PAPER, "texture": MILITARY_PAPER_TEXTURES[military_key],
			"identity": String(military_key)}
	var paper_key: StringName = PAPER_ALIASES.get(semantic, semantic)
	if PAPER_TEXTURES.has(paper_key):
		return {"family": FAMILY_PAPER, "texture": PAPER_TEXTURES[paper_key]}
	if MILITARY_PAPER_TEXTURES.has(paper_key):
		return {"family": FAMILY_PAPER, "texture": MILITARY_PAPER_TEXTURES[paper_key],
			"identity": String(paper_key)}
	if raw.begins_with("building."):
		var product_id := _building_product_id(raw)
		var kind := raw.trim_prefix("building.").get_slice(".", 0)
		var stable_id := _building_stable_id(raw)
		var base_key := _paper_building_base(kind, product_id, stable_id)
		return {"family": FAMILY_PAPER,
			"texture": _paper_building_texture(kind, product_id, base_key),
			"identity": "building.%s@%s@%s" % [kind, product_id, base_key]}
	return {"family": FAMILY_PAPER, "texture": PAPER_TEXTURES[&"system.unknown"]}


const BUILDING_BASE_OVERRIDES = PaperBuildingIcon.BUILDING_BASE_OVERRIDES


static func _paper_building_base(kind: String, product_id: StringName,
		stable_id: StringName = &"") -> StringName:
	return PaperBuildingIcon._paper_building_base(kind, product_id, stable_id)


static func _paper_building_texture(kind: String, product_id: StringName,
		base_key: StringName) -> Texture2D:
	var cache_key := "%s@%s@%s" % [kind, product_id, base_key]
	if _paper_building_textures.has(cache_key):
		return _paper_building_textures[cache_key] as Texture2D
	# 只在首次显示时合成纸贴；按建筑类型和产物缓存，不进入每日刷新热路径。
	var canvas := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	var base := (PAPER_TEXTURES[base_key] as Texture2D).get_image()
	# 纸贴图集按 VRAM 压缩导入（compress/mode=1）。压缩 Image 上 convert /
	# resize / blend_rect 全部被引擎拒绝，图层会被静默丢弃并把坏贴图写进缓存，
	# 必须先解压再合成。
	if base != null and base.is_compressed():
		base.decompress()
	base.convert(Image.FORMAT_RGBA8)
	base.resize(108, 108, Image.INTERPOLATE_LANCZOS)
	canvas.blend_rect(base, Rect2i(0, 0, 108, 108), Vector2i.ZERO)
	var product := texture_for_key(good_semantic(String(product_id))).get_image()
	if product != null and product.is_compressed():
		product.decompress()
	product.convert(Image.FORMAT_RGBA8)
	product.resize(66, 66, Image.INTERPOLATE_LANCZOS)
	canvas.blend_rect(product, Rect2i(0, 0, 66, 66), Vector2i(62, 62))
	var texture := ImageTexture.create_from_image(canvas)
	_paper_building_textures[cache_key] = texture
	return texture


static func glyph_for_key(key: StringName) -> String:
	return "" # Compatibility only: player icons are textures.


static func texture_for_key(key: StringName) -> Texture2D:
	return spec_for(key).get("texture") as Texture2D


## UI 与地图标记共用纸贴绘制；状态只影响透明度，不把彩铅图案染成单色。
static func draw_icon(canvas: CanvasItem, key: StringName, rect: Rect2,
		alpha: float = 1.0) -> void:
	var texture := texture_for_key(key)
	if texture == null or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var source := texture.get_size()
	var fitted := source * minf(rect.size.x / source.x, rect.size.y / source.y)
	canvas.draw_texture_rect(texture, Rect2(rect.get_center() - fitted * 0.5, fitted),
		false, Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0)))


static func family_for_key(key: StringName) -> StringName:
	return spec_for(key).get("family", FAMILY_FONT_AWESOME) as StringName


static func label_for_key(key: StringName) -> String:
	return String(spec_for(key).get("label", ""))


static func has_icon(key: StringName) -> bool:
	var semantic := resolve_semantic(key)
	return semantic != &"" and semantic != &"system.unknown"


static func registered_keys() -> Array[StringName]:
	var keys: Array[StringName] = []
	keys.assign(SPECS.keys())
	for stable_id in GOOD_IDS:
		keys.append(good_semantic(String(stable_id)))
	for stable_id in PROFESSION_IDS:
		keys.append(profession_semantic(String(stable_id)))
	for key in PAPER_TEXTURES:
		if not keys.has(key):
			keys.append(key)
	for key in MILITARY_PAPER_TEXTURES:
		if not keys.has(key):
			keys.append(key)
	keys.sort()
	return keys


## 旧类别键仍为新增兵种兜底；目录内已有稳定 id 的兵种优先走
## military_unit_semantic_for_id()，避免整个时代都显示同一张剪影。
static func military_unit_semantic(unit_class: String, has_bow_slot: bool = false) -> StringName:
	match unit_class:
		"mobile":
			return &"military.unit.mobile"
		"artillery":
			return &"military.unit.artillery"
		"armored":
			return &"military.unit.armored"
		"air":
			return &"military.unit.air"
		_:
			return &"military.unit.line.bows" if has_bow_slot else &"military.unit.line"


static func military_unit_semantic_for_id(unit_id: String, unit_class: String,
		has_bow_slot: bool = false) -> StringName:
	var key: StringName = MILITARY_UNIT_ICONS.get(StringName(unit_id), &"")
	if MILITARY_PAPER_TEXTURES.has(key):
		return key
	return military_unit_semantic(unit_class, has_bow_slot)


static func military_good_icon(stable_id: String) -> StringName:
	var key: StringName = MILITARY_GOOD_ICONS.get(StringName(stable_id), &"")
	if MILITARY_PAPER_TEXTURES.has(key):
		return key
	return good_semantic(stable_id)


static func military_building_semantic(building_id: String, role_id: String = "",
		tier: int = -1) -> StringName:
	var key: StringName = MILITARY_BUILDING_ICONS.get(StringName(building_id), &"")
	if MILITARY_PAPER_TEXTURES.has(key):
		return key
	if role_id == "barracks":
		if tier < 0:
			return &"military.building.palisade_barracks"
		if tier <= 0:
			return &"military.building.tribal_lodge"
		if tier <= 2:
			return &"military.building.palisade_barracks"
		if tier <= 4:
			return &"military.building.legion_fort"
		return &"military.building.modern_base"
	if role_id == "fortification":
		if tier < 0:
			return &"military.building.stone_wall"
		if tier <= 0:
			return &"military.building.rampart"
		if tier <= 2:
			return &"military.building.stone_wall"
		if tier <= 4:
			return &"military.building.star_fort"
		return &"military.building.bunker"
	if role_id == "war_college":
		return &"military.building.simulation_center" if tier >= 2 \
			else &"military.building.academy"
	var role_key: StringName = MILITARY_BUILDING_ROLE_ICONS.get(
		StringName(role_id), &"military.building.palisade_barracks")
	return role_key if MILITARY_PAPER_TEXTURES.has(role_key) \
		else &"military.building.palisade_barracks"


static func military_semantic(stable_id: String) -> StringName:
	var key := StringName("military.%s" % stable_id)
	return key if MILITARY_PAPER_TEXTURES.has(key) else &"country.military"


static func good_semantic(stable_id: String) -> StringName:
	return StringName("good.%s" % stable_id) if GOOD_IDS.has(StringName(stable_id)) \
		else &"system.unknown"


static func resource_semantic(stable_id: String) -> StringName:
	match stable_id:
		"timber": return &"resource.wood"
		"wild_game": return &"resource.animal"
		"stone": return &"resource.rock"
	var key := StringName("resource.%s" % stable_id)
	return key if PAPER_TEXTURES.has(key) else &"economy.resource"


static func profession_semantic(stable_id: String) -> StringName:
	return StringName("profession.%s" % stable_id) \
		if PROFESSION_IDS.has(StringName(stable_id)) else &"system.unknown"


static func technology_domain_semantic(domain_id: String) -> StringName:
	var key := StringName("technology.domain.%s" % domain_id)
	return key if SPECS.has(key) else &"country.technology"


# Research state ordering matches NativeCountryRuntime's snapshot encoding.
static func technology_state_semantic(state: int) -> StringName:
	match state:
		1:
			return &"technology.state.locked"
		2:
			return &"technology.state.available"
		3:
			return &"technology.state.queued"
		4:
			return &"technology.state.pending"
		5:
			return &"technology.state.completed"
		_:
			return &"technology.state.unknown"


static func building_semantic(stable_id: String, primary_good_id: String,
		kind: int) -> StringName:
	if stable_id.is_empty() or good_semantic(primary_good_id) == &"system.unknown":
		return &"economy.building"
	var kind_name := "collector" if kind == 0 else ("service" if kind == 2 else "industrial")
	return StringName("building.%s.%s@%s" % [kind_name, stable_id, primary_good_id])


static func _building_product_id(raw: String) -> StringName:
	var separator := raw.rfind("@")
	if separator < 0:
		return &""
	var product_id := StringName(raw.substr(separator + 1))
	return product_id if GOOD_IDS.has(product_id) else &""


static func _building_stable_id(raw: String) -> StringName:
	var prefix := raw.trim_prefix("building.")
	var separator := prefix.rfind("@")
	if separator < 0:
		return &""
	var segments := prefix.substr(0, separator).split(".", false)
	return StringName(segments[1]) if segments.size() > 1 else &""


static func implementation_signature(key: StringName) -> String:
	var spec := spec_for(key)
	var family := String(spec.get("family", FAMILY_FONT_AWESOME))
	if spec.has("identity"):
		return "%s:%s" % [family, spec.identity]
	var texture := spec.get("texture") as Texture2D
	return "%s:texture:%s" % [family, texture.resource_path.get_file() if texture != null else "empty"]


static func usage_audit() -> Dictionary:
	var usage := {}
	for semantic in registered_keys():
		var signature := implementation_signature(semantic)
		if not usage.has(signature):
			usage[signature] = []
		(usage[signature] as Array).append(semantic)
	return usage
