class_name IconCatalog
extends RefCounted


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
const PAPER_TEXTURES := {
	&"good.adobe_brick": preload("res://assets/icons/paper/good_adobe_brick.tres"),
	&"good.advanced_chips": preload("res://assets/icons/paper/good_advanced_chips.tres"),
	&"good.agricultural_machinery": preload("res://assets/icons/paper/good_agricultural_machinery.tres"),
	&"good.aluminum": preload("res://assets/icons/paper/good_aluminum.tres"),
	&"good.automobiles": preload("res://assets/icons/paper/good_automobiles.tres"),
	&"good.autonomous_systems": preload("res://assets/icons/paper/good_autonomous_systems.tres"),
	&"good.bast_fiber": preload("res://assets/icons/paper/good_bast_fiber.tres"),
	&"good.batteries": preload("res://assets/icons/paper/good_batteries.tres"),
	&"good.bauxite": preload("res://assets/icons/paper/good_bauxite.tres"),
	&"good.beverages": preload("res://assets/icons/paper/good_beverages.tres"),
	&"good.bread": preload("res://assets/icons/paper/good_bread.tres"),
	&"good.bricks": preload("res://assets/icons/paper/good_bricks.tres"),
	&"good.brine": preload("res://assets/icons/paper/good_brine.tres"),
	&"good.bronze_tools": preload("res://assets/icons/paper/good_bronze_tools.tres"),
	&"good.canned_fish": preload("res://assets/icons/paper/good_canned_fish.tres"),
	&"good.cement": preload("res://assets/icons/paper/good_cement.tres"),
	&"good.charcoal": preload("res://assets/icons/paper/good_charcoal.tres"),
	&"good.chipped_stone_tools": preload("res://assets/icons/paper/good_chipped_stone_tools.tres"),
	&"good.clay": preload("res://assets/icons/paper/good_clay.tres"),
	&"good.cloth": preload("res://assets/icons/paper/good_cloth.tres"),
	&"good.clothing": preload("res://assets/icons/paper/good_clothing.tres"),
	&"good.coal": preload("res://assets/icons/paper/good_coal.tres"),
	&"good.coke": preload("res://assets/icons/paper/good_coke.tres"),
	&"good.computers": preload("res://assets/icons/paper/good_computers.tres"),
	&"good.concrete": preload("res://assets/icons/paper/good_concrete.tres"),
	&"good.construction_components": preload("res://assets/icons/paper/good_construction_components.tres"),
	&"good.copper": preload("res://assets/icons/paper/good_copper.tres"),
	&"good.copper_ore": preload("res://assets/icons/paper/good_copper_ore.tres"),
	&"good.copper_tools": preload("res://assets/icons/paper/good_copper_tools.tres"),
	&"good.corn_grain": preload("res://assets/icons/paper/good_corn_grain.tres"),
	&"good.cotton_fiber": preload("res://assets/icons/paper/good_cotton_fiber.tres"),
	&"good.crude_oil": preload("res://assets/icons/paper/good_crude_oil.tres"),
	&"good.dairy_products": preload("res://assets/icons/paper/good_dairy_products.tres"),
	&"good.detergent": preload("res://assets/icons/paper/good_detergent.tres"),
	&"good.edible_oil": preload("res://assets/icons/paper/good_edible_oil.tres"),
	&"good.electric_motor": preload("res://assets/icons/paper/good_electric_motor.tres"),
	&"good.electrical_equipment": preload("res://assets/icons/paper/good_electrical_equipment.tres"),
	&"good.electricity": preload("res://assets/icons/paper/good_electricity.tres"),
	&"good.electronic_components": preload("res://assets/icons/paper/good_electronic_components.tres"),
	&"good.engines": preload("res://assets/icons/paper/good_engines.tres"),
	&"good.explosives": preload("res://assets/icons/paper/good_explosives.tres"),
	&"good.fertilizer": preload("res://assets/icons/paper/good_fertilizer.tres"),
	&"good.fine_clothing": preload("res://assets/icons/paper/good_fine_clothing.tres"),
	&"good.fine_furniture": preload("res://assets/icons/paper/good_fine_furniture.tres"),
	&"good.fish": preload("res://assets/icons/paper/good_fish.tres"),
	&"good.flax_fiber": preload("res://assets/icons/paper/good_flax_fiber.tres"),
	&"good.flint": preload("res://assets/icons/paper/good_flint.tres"),
	&"good.footwear": preload("res://assets/icons/paper/good_footwear.tres"),
	&"good.fur": preload("res://assets/icons/paper/good_fur.tres"),
	&"good.furniture": preload("res://assets/icons/paper/good_furniture.tres"),
	&"good.game_meat": preload("res://assets/icons/paper/good_game_meat.tres"),
	&"good.gathered_plants": preload("res://assets/icons/paper/good_gathered_plants.tres"),
	&"good.glass": preload("res://assets/icons/paper/good_glass.tres"),
	&"good.glassware": preload("res://assets/icons/paper/good_glassware.tres"),
	&"good.gold": preload("res://assets/icons/paper/good_gold.tres"),
	&"good.grain": preload("res://assets/icons/paper/good_grain.tres"),
	&"good.horses": preload("res://assets/icons/paper/good_horses.tres"),
	&"good.household_appliances": preload("res://assets/icons/paper/good_household_appliances.tres"),
	&"good.industrial_chemicals": preload("res://assets/icons/paper/good_industrial_chemicals.tres"),
	&"good.industrial_machinery": preload("res://assets/icons/paper/good_industrial_machinery.tres"),
	&"good.insulated_cable": preload("res://assets/icons/paper/good_insulated_cable.tres"),
	&"good.iron_ore": preload("res://assets/icons/paper/good_iron_ore.tres"),
	&"good.jewelry": preload("res://assets/icons/paper/good_jewelry.tres"),
	&"good.latex": preload("res://assets/icons/paper/good_latex.tres"),
	&"good.lead": preload("res://assets/icons/paper/good_lead.tres"),
	&"good.lead_ore": preload("res://assets/icons/paper/good_lead_ore.tres"),
	&"good.leather": preload("res://assets/icons/paper/good_leather.tres"),
	&"good.leather_goods": preload("res://assets/icons/paper/good_leather_goods.tres"),
	&"good.lime": preload("res://assets/icons/paper/good_lime.tres"),
	&"good.limestone": preload("res://assets/icons/paper/good_limestone.tres"),
	&"good.livestock_products": preload("res://assets/icons/paper/good_livestock_products.tres"),
	&"good.logs": preload("res://assets/icons/paper/good_logs.tres"),
	&"good.lubricants": preload("res://assets/icons/paper/good_lubricants.tres"),
	&"good.lumber": preload("res://assets/icons/paper/good_lumber.tres"),
	&"good.machine_parts": preload("res://assets/icons/paper/good_machine_parts.tres"),
	&"good.manganese_ore": preload("res://assets/icons/paper/good_manganese_ore.tres"),
	&"good.manuscripts": preload("res://assets/icons/paper/good_manuscripts.tres"),
	&"good.meat": preload("res://assets/icons/paper/good_meat.tres"),
	&"good.medicinal_herbs": preload("res://assets/icons/paper/good_medicinal_herbs.tres"),
	&"good.metal_housewares": preload("res://assets/icons/paper/good_metal_housewares.tres"),
	&"good.natural_gas": preload("res://assets/icons/paper/good_natural_gas.tres"),
	&"good.natural_rubber": preload("res://assets/icons/paper/good_natural_rubber.tres"),
	&"good.nuclear_fuel": preload("res://assets/icons/paper/good_nuclear_fuel.tres"),
	&"good.oceanic_vessels": preload("res://assets/icons/paper/good_oceanic_vessels.tres"),
	&"good.packaging": preload("res://assets/icons/paper/good_packaging.tres"),
	&"good.paper": preload("res://assets/icons/paper/good_paper.tres"),
	&"good.petrochemicals": preload("res://assets/icons/paper/good_petrochemicals.tres"),
	&"good.pharmaceuticals": preload("res://assets/icons/paper/good_pharmaceuticals.tres"),
	&"good.phosphate_rock": preload("res://assets/icons/paper/good_phosphate_rock.tres"),
	&"good.plastics": preload("res://assets/icons/paper/good_plastics.tres"),
	&"good.potatoes": preload("res://assets/icons/paper/good_potatoes.tres"),
	&"good.pottery": preload("res://assets/icons/paper/good_pottery.tres"),
	&"good.precision_tools": preload("res://assets/icons/paper/good_precision_tools.tres"),
	&"good.prepared_staples": preload("res://assets/icons/paper/good_prepared_staples.tres"),
	&"good.printed_materials": preload("res://assets/icons/paper/good_printed_materials.tres"),
	&"good.processed_food": preload("res://assets/icons/paper/good_processed_food.tres"),
	&"good.radio_equipment": preload("res://assets/icons/paper/good_radio_equipment.tres"),
	&"good.railway_equipment": preload("res://assets/icons/paper/good_railway_equipment.tres"),
	&"good.rare_earth_metals": preload("res://assets/icons/paper/good_rare_earth_metals.tres"),
	&"good.rare_earth_ore": preload("res://assets/icons/paper/good_rare_earth_ore.tres"),
	&"good.raw_hide": preload("res://assets/icons/paper/good_raw_hide.tres"),
	&"good.raw_stone": preload("res://assets/icons/paper/good_raw_stone.tres"),
	&"good.reactor_components": preload("res://assets/icons/paper/good_reactor_components.tres"),
	&"good.reed_bundle": preload("res://assets/icons/paper/good_reed_bundle.tres"),
	&"good.refined_fuel": preload("res://assets/icons/paper/good_refined_fuel.tres"),
	&"good.rice_grain": preload("res://assets/icons/paper/good_rice_grain.tres"),
	&"good.salt": preload("res://assets/icons/paper/good_salt.tres"),
	&"good.saltpeter": preload("res://assets/icons/paper/good_saltpeter.tres"),
	&"good.scientific_instruments": preload("res://assets/icons/paper/good_scientific_instruments.tres"),
	&"good.seed_cotton": preload("res://assets/icons/paper/good_seed_cotton.tres"),
	&"good.semiconductors": preload("res://assets/icons/paper/good_semiconductors.tres"),
	&"good.silica_sand": preload("res://assets/icons/paper/good_silica_sand.tres"),
	&"good.silver": preload("res://assets/icons/paper/good_silver.tres"),
	&"good.soap": preload("res://assets/icons/paper/good_soap.tres"),
	&"good.spices": preload("res://assets/icons/paper/good_spices.tres"),
	&"good.stainless_steel": preload("res://assets/icons/paper/good_stainless_steel.tres"),
	&"good.steam_engines": preload("res://assets/icons/paper/good_steam_engines.tres"),
	&"good.steel": preload("res://assets/icons/paper/good_steel.tres"),
	&"good.sulfur": preload("res://assets/icons/paper/good_sulfur.tres"),
	&"good.synthetic_fiber": preload("res://assets/icons/paper/good_synthetic_fiber.tres"),
	&"good.synthetic_rubber": preload("res://assets/icons/paper/good_synthetic_rubber.tres"),
	&"good.technology_points": preload("res://assets/icons/paper/good_technology_points.tres"),
	&"good.telecom_equipment": preload("res://assets/icons/paper/good_telecom_equipment.tres"),
	&"good.tin": preload("res://assets/icons/paper/good_tin.tres"),
	&"good.tin_ore": preload("res://assets/icons/paper/good_tin_ore.tres"),
	&"good.tools": preload("res://assets/icons/paper/good_tools.tres"),
	&"good.turf_block": preload("res://assets/icons/paper/good_turf_block.tres"),
	&"good.vegetables": preload("res://assets/icons/paper/good_vegetables.tres"),
	&"good.wheat_grain": preload("res://assets/icons/paper/good_wheat_grain.tres"),
	&"good.wire": preload("res://assets/icons/paper/good_wire.tres"),
	&"good.wool": preload("res://assets/icons/paper/good_wool.tres"),
	&"good.wrought_iron": preload("res://assets/icons/paper/good_wrought_iron.tres"),
	&"good.zinc": preload("res://assets/icons/paper/good_zinc.tres"),
	&"good.zinc_ore": preload("res://assets/icons/paper/good_zinc_ore.tres"),
	&"profession.agricultural_worker": preload("res://assets/icons/paper/profession_agricultural_worker.tres"),
	&"profession.ai_researcher": preload("res://assets/icons/paper/profession_ai_researcher.tres"),
	&"profession.apprentice": preload("res://assets/icons/paper/profession_apprentice.tres"),
	&"profession.artisan": preload("res://assets/icons/paper/profession_artisan.tres"),
	&"profession.chemist": preload("res://assets/icons/paper/profession_chemist.tres"),
	&"profession.construction_worker": preload("res://assets/icons/paper/profession_construction_worker.tres"),
	&"profession.cooperative_member": preload("res://assets/icons/paper/profession_cooperative_member.tres"),
	&"profession.corvee_worker": preload("res://assets/icons/paper/profession_corvee_worker.tres"),
	&"profession.data_scientist": preload("res://assets/icons/paper/profession_data_scientist.tres"),
	&"profession.electrician": preload("res://assets/icons/paper/profession_electrician.tres"),
	&"profession.engineer": preload("res://assets/icons/paper/profession_engineer.tres"),
	&"profession.enslaved_laborer": preload("res://assets/icons/paper/profession_enslaved_laborer.tres"),
	&"profession.fisher": preload("res://assets/icons/paper/profession_fisher.tres"),
	&"profession.forager": preload("res://assets/icons/paper/profession_forager.tres"),
	&"profession.forestry_worker": preload("res://assets/icons/paper/profession_forestry_worker.tres"),
	&"profession.guild_master": preload("res://assets/icons/paper/profession_guild_master.tres"),
	&"profession.household_farmer": preload("res://assets/icons/paper/profession_household_farmer.tres"),
	&"profession.hunter": preload("res://assets/icons/paper/profession_hunter.tres"),
	&"profession.indentured_laborer": preload("res://assets/icons/paper/profession_indentured_laborer.tres"),
	&"profession.industrialist": preload("res://assets/icons/paper/profession_industrialist.tres"),
	&"profession.industrial_worker": preload("res://assets/icons/paper/profession_industrial_worker.tres"),
	&"profession.journeyman": preload("res://assets/icons/paper/profession_journeyman.tres"),
	&"profession.landlord": preload("res://assets/icons/paper/profession_landlord.tres"),
	&"profession.lorekeeper": preload("res://assets/icons/paper/profession_lorekeeper.tres"),
	&"profession.machinist": preload("res://assets/icons/paper/profession_machinist.tres"),
	&"profession.manager": preload("res://assets/icons/paper/profession_manager.tres"),
	&"profession.merchant": preload("res://assets/icons/paper/profession_merchant.tres"),
	&"profession.metallurgist": preload("res://assets/icons/paper/profession_metallurgist.tres"),
	&"profession.miner": preload("res://assets/icons/paper/profession_miner.tres"),
	&"profession.natural_philosopher": preload("res://assets/icons/paper/profession_natural_philosopher.tres"),
	&"profession.pastoralist": preload("res://assets/icons/paper/profession_pastoralist.tres"),
	&"profession.petroleum_worker": preload("res://assets/icons/paper/profession_petroleum_worker.tres"),
	&"profession.research_scientist": preload("res://assets/icons/paper/profession_research_scientist.tres"),
	&"profession.researcher": preload("res://assets/icons/paper/profession_researcher.tres"),
	&"profession.scholar": preload("res://assets/icons/paper/profession_scholar.tres"),
	&"profession.scientist": preload("res://assets/icons/paper/profession_scientist.tres"),
	&"profession.scribe": preload("res://assets/icons/paper/profession_scribe.tres"),
	&"profession.serf": preload("res://assets/icons/paper/profession_serf.tres"),
	&"profession.sharecropper": preload("res://assets/icons/paper/profession_sharecropper.tres"),
	&"profession.subsistence_farmer": preload("res://assets/icons/paper/profession_subsistence_farmer.tres"),
	&"profession.technician": preload("res://assets/icons/paper/profession_technician.tres"),
	&"profession.tenant_farmer": preload("res://assets/icons/paper/profession_tenant_farmer.tres"),
	&"profession.transport_worker": preload("res://assets/icons/paper/profession_transport_worker.tres"),
	&"profession.unemployed": preload("res://assets/icons/paper/profession_unemployed.tres"),
	&"profession.worker": preload("res://assets/icons/paper/profession_worker.tres"),
	&"resource.animal": preload("res://assets/icons/paper/resource_animal.tres"),
	&"resource.arable_land": preload("res://assets/icons/paper/resource_arable_land.tres"),
	&"resource.bauxite": preload("res://assets/icons/paper/resource_bauxite.tres"),
	&"resource.clay": preload("res://assets/icons/paper/resource_clay.tres"),
	&"resource.coal": preload("res://assets/icons/paper/resource_coal.tres"),
	&"resource.copper": preload("res://assets/icons/paper/resource_copper.tres"),
	&"resource.earth": preload("res://assets/icons/paper/resource_earth.tres"),
	&"resource.fertile_soil": preload("res://assets/icons/paper/resource_fertile_soil.tres"),
	&"resource.fire": preload("res://assets/icons/paper/resource_fire.tres"),
	&"resource.fish": preload("res://assets/icons/paper/resource_fish.tres"),
	&"resource.flint": preload("res://assets/icons/paper/resource_flint.tres"),
	&"resource.freshwater_fish": preload("res://assets/icons/paper/resource_freshwater_fish.tres"),
	&"resource.gold": preload("res://assets/icons/paper/resource_gold.tres"),
	&"resource.iron": preload("res://assets/icons/paper/resource_iron.tres"),
	&"resource.lead": preload("res://assets/icons/paper/resource_lead.tres"),
	&"resource.limestone": preload("res://assets/icons/paper/resource_limestone.tres"),
	&"resource.manganese": preload("res://assets/icons/paper/resource_manganese.tres"),
	&"resource.marine_fish": preload("res://assets/icons/paper/resource_marine_fish.tres"),
	&"resource.metal": preload("res://assets/icons/paper/resource_metal.tres"),
	&"resource.natural_gas": preload("res://assets/icons/paper/resource_natural_gas.tres"),
	&"resource.oil": preload("res://assets/icons/paper/resource_oil.tres"),
	&"resource.paddy_land": preload("res://assets/icons/paper/resource_paddy_land.tres"),
	&"resource.pasture": preload("res://assets/icons/paper/resource_pasture.tres"),
	&"resource.phosphate_rock": preload("res://assets/icons/paper/resource_phosphate_rock.tres"),
	&"resource.plantation_land": preload("res://assets/icons/paper/resource_plantation_land.tres"),
	&"resource.precious": preload("res://assets/icons/paper/resource_precious.tres"),
	&"resource.rare_earth": preload("res://assets/icons/paper/resource_rare_earth.tres"),
	&"resource.rock": preload("res://assets/icons/paper/resource_rock.tres"),
	&"resource.salt": preload("res://assets/icons/paper/resource_salt.tres"),
	&"resource.salt_deposit": preload("res://assets/icons/paper/resource_salt_deposit.tres"),
	&"resource.saltpeter": preload("res://assets/icons/paper/resource_saltpeter.tres"),
	&"resource.silica_sand": preload("res://assets/icons/paper/resource_silica_sand.tres"),
	&"resource.silver": preload("res://assets/icons/paper/resource_silver.tres"),
	&"resource.sulfur": preload("res://assets/icons/paper/resource_sulfur.tres"),
	&"resource.tin": preload("res://assets/icons/paper/resource_tin.tres"),
	&"resource.wood": preload("res://assets/icons/paper/resource_wood.tres"),
	&"resource.zinc": preload("res://assets/icons/paper/resource_zinc.tres"),
	&"economy.building": preload("res://assets/icons/paper/economy_building.tres"),
	&"economy.building.factory": preload("res://assets/icons/paper/economy_building_factory.tres"),
	&"economy.building.farm": preload("res://assets/icons/paper/economy_building_farm.tres"),
	&"economy.building.fishing": preload("res://assets/icons/paper/economy_building_fishing.tres"),
	&"economy.building.food": preload("res://assets/icons/paper/economy_building_food.tres"),
	&"economy.building.forestry": preload("res://assets/icons/paper/economy_building_forestry.tres"),
	&"economy.building.gathering": preload("res://assets/icons/paper/economy_building_gathering.tres"),
	&"economy.building.hearth": preload("res://assets/icons/paper/economy_building_hearth.tres"),
	&"economy.building.hunting": preload("res://assets/icons/paper/economy_building_hunting.tres"),
	&"economy.building.market": preload("res://assets/icons/paper/economy_building_market.tres"),
	&"economy.building.mine": preload("res://assets/icons/paper/economy_building_mine.tres"),
	&"economy.building.power": preload("res://assets/icons/paper/economy_building_power.tres"),
	&"economy.building.science": preload("res://assets/icons/paper/economy_building_science.tres"),
	&"economy.building.service": preload("res://assets/icons/paper/economy_building_service.tres"),
	&"economy.building.shipyard": preload("res://assets/icons/paper/economy_building_shipyard.tres"),
	&"economy.building.transport": preload("res://assets/icons/paper/economy_building_transport.tres"),
	&"economy.building.workshop": preload("res://assets/icons/paper/economy_building_workshop.tres"),
	&"hud.country.technology": preload("res://assets/icons/paper/hud_country_technology.tres"),
	&"hud.country.ideology": preload("res://assets/icons/paper/hud_country_ideology.tres"),
	&"hud.country.economy": preload("res://assets/icons/paper/hud_country_economy.tres"),
	&"hud.country.military": preload("res://assets/icons/paper/hud_country_military.tres"),
	&"hud.country.diplomacy": preload("res://assets/icons/paper/hud_country_diplomacy.tres"),
	&"hud.overlay.geography": preload("res://assets/icons/paper/hud_overlay_geography.tres"),
	&"hud.overlay.climate": preload("res://assets/icons/paper/hud_overlay_climate.tres"),
	&"hud.overlay.resources": preload("res://assets/icons/paper/hud_overlay_resources.tres"),
	&"hud.overlay.biology": preload("res://assets/icons/paper/hud_overlay_biology.tres"),
	&"hud.overlay.clear": preload("res://assets/icons/paper/hud_overlay_clear.tres"),
	&"geography.elevation": preload("res://assets/icons/paper/geography_elevation.tres"),
	&"geography.surface": preload("res://assets/icons/paper/geography_surface.tres"),
	&"geography.terrain": preload("res://assets/icons/paper/geography_terrain.tres"),
	&"climate.temperature": preload("res://assets/icons/paper/climate_temperature.tres"),
	&"climate.humidity": preload("res://assets/icons/paper/climate_humidity.tres"),
	&"climate.wind": preload("res://assets/icons/paper/climate_wind.tres"),
	&"ecology.growth": preload("res://assets/icons/paper/ecology_growth.tres"),
	&"ecology.vegetation": preload("res://assets/icons/paper/ecology_vegetation.tres"),
	&"hud.clock.calendar": preload("res://assets/icons/paper/hud_clock_calendar.tres"),
	&"hud.clock.pause": preload("res://assets/icons/paper/hud_clock_pause.tres"),
	&"hud.clock.play": preload("res://assets/icons/paper/hud_clock_play.tres"),
	&"hud.clock.speed": preload("res://assets/icons/paper/hud_clock_speed.tres"),
	&"hud.system.settings": preload("res://assets/icons/paper/hud_system_settings.tres"),
	&"hud.system.day_night_on": preload("res://assets/icons/paper/hud_system_day_night_on.tres"),
	&"hud.system.day_night_off": preload("res://assets/icons/paper/hud_system_day_night_off.tres"),
	&"hydrology.current": preload("res://assets/icons/paper/hydrology_current.tres"),
	&"action.add": preload("res://assets/icons/paper/action_add.tres"),
	&"action.back": preload("res://assets/icons/paper/action_back.tres"),
	&"action.chevron_down": preload("res://assets/icons/paper/action_chevron_down.tres"),
	&"action.chevron_right": preload("res://assets/icons/paper/action_chevron_right.tres"),
	&"action.close": preload("res://assets/icons/paper/action_close.tres"),
	&"action.confirm": preload("res://assets/icons/paper/action_confirm.tres"),
	&"action.fit": preload("res://assets/icons/paper/action_fit.tres"),
	&"action.history": preload("res://assets/icons/paper/action_history.tres"),
	&"action.more": preload("res://assets/icons/paper/action_more.tres"),
	&"action.pin": preload("res://assets/icons/paper/action_pin.tres"),
	&"action.refresh": preload("res://assets/icons/paper/action_refresh.tres"),
	&"action.reset": preload("res://assets/icons/paper/action_reset.tres"),
	&"action.save": preload("res://assets/icons/paper/action_save.tres"),
	&"system.clock": preload("res://assets/icons/paper/system_clock.tres"),
	&"system.seed": preload("res://assets/icons/paper/system_seed.tres"),
	&"system.target": preload("res://assets/icons/paper/system_target.tres"),
	&"system.unknown": preload("res://assets/icons/paper/system_unknown.tres"),
	&"status.hidden": preload("res://assets/icons/paper/status_hidden.tres"),
	&"status.warning": preload("res://assets/icons/paper/status_warning.tres"),
	&"summary.overview": preload("res://assets/icons/paper/summary_overview.tres"),
	&"climate.moon": preload("res://assets/icons/paper/climate_moon.tres"),
	&"climate.snow": preload("res://assets/icons/paper/climate_snow.tres"),
	&"population.heart": preload("res://assets/icons/paper/population_heart.tres"),
	&"population.living.destitute": preload("res://assets/icons/paper/population_living_destitute.tres"),
	&"population.living.struggling": preload("res://assets/icons/paper/population_living_struggling.tres"),
	&"population.living.poor": preload("res://assets/icons/paper/population_living_poor.tres"),
	&"population.living.secure": preload("res://assets/icons/paper/population_living_secure.tres"),
	&"population.living.comfortable": preload("res://assets/icons/paper/population_living_comfortable.tres"),
	&"population.living.affluent": preload("res://assets/icons/paper/population_living_affluent.tres"),
	&"population.living.luxury": preload("res://assets/icons/paper/population_living_luxury.tres"),
	&"tax.business": preload("res://assets/icons/paper/tax_business.tres"),
	&"tax.consumption": preload("res://assets/icons/paper/tax_consumption.tres"),
	&"tax.default": preload("res://assets/icons/paper/tax_default.tres"),
	&"tax.export": preload("res://assets/icons/paper/tax_export.tres"),
	&"tax.import": preload("res://assets/icons/paper/tax_import.tres"),
	&"tax.income": preload("res://assets/icons/paper/tax_income.tres"),
	&"tax.section": preload("res://assets/icons/paper/tax_section.tres"),
	&"tax.tariff": preload("res://assets/icons/paper/tax_tariff.tres"),
	&"technology.milestone": preload("res://assets/icons/paper/technology_milestone.tres"),
	&"technology.state.available": preload("res://assets/icons/paper/technology_state_available.tres"),
	&"family.workspace.crest": preload("res://assets/icons/paper/family_workspace_crest.tres"),
	&"family.workspace.prestige": preload("res://assets/icons/paper/family_workspace_prestige.tres"),
	&"family.workspace.person": preload("res://assets/icons/paper/family_workspace_person.tres"),
	&"family.workspace.traits": preload("res://assets/icons/paper/family_workspace_traits.tres"),
	&"family.workspace.preferences": preload("res://assets/icons/paper/family_workspace_preferences.tres"),
	&"family.workspace.effects": preload("res://assets/icons/paper/family_workspace_effects.tres"),
	&"family.workspace.people": preload("res://assets/icons/paper/family_workspace_people.tres"),
	&"family.workspace.branches": preload("res://assets/icons/paper/family_workspace_branches.tres"),
	&"technology.state.queued": preload("res://assets/icons/paper/technology_state_queued.tres"),
	&"trend.up": preload("res://assets/icons/paper/trend_up.tres"),
	&"trend.down": preload("res://assets/icons/paper/trend_down.tres"),
	&"trend.flat": preload("res://assets/icons/paper/trend_flat.tres"),
	&"technology.state.locked": preload("res://assets/icons/paper/technology_state_locked.tres"),
	&"country.world": preload("res://assets/icons/paper/country_world.tres"),
	&"map.expedition": preload("res://assets/icons/paper/map_expedition.tres"),
	&"metric.goods": preload("res://assets/icons/paper/metric_goods.tres"),
	&"situation.food_shortage": preload("res://assets/icons/paper/situation_food_shortage.tres"),
	&"situation.industry_shortage": preload("res://assets/icons/paper/situation_industry_shortage.tres"),
	&"situation.consumer_shortage": preload("res://assets/icons/paper/situation_consumer_shortage.tres"),
	&"situation.discontent": preload("res://assets/icons/paper/situation_discontent.tres"),
	&"situation.drought": preload("res://assets/icons/paper/situation_drought.tres"),
	&"situation.flood": preload("res://assets/icons/paper/situation_flood.tres"),
	&"situation.unemployment": preload("res://assets/icons/paper/situation_unemployment.tres"),
	&"situation.vacant_jobs": preload("res://assets/icons/paper/situation_vacant_jobs.tres"),
	&"decoration.wax_seal": preload("res://assets/icons/paper/decoration_wax_seal.tres"),
	&"control.checkbox_unchecked": preload("res://assets/icons/paper/control_checkbox_unchecked.tres"),
	&"control.checkbox_checked": preload("res://assets/icons/paper/control_checkbox_checked.tres"),
	&"control.checkbox_indeterminate": preload("res://assets/icons/paper/control_checkbox_indeterminate.tres"),
	&"control.radio_unchecked": preload("res://assets/icons/paper/control_radio_unchecked.tres"),
	&"control.radio_checked": preload("res://assets/icons/paper/control_radio_checked.tres"),
	&"control.toggle_off": preload("res://assets/icons/paper/control_toggle_off.tres"),
	&"control.toggle_on": preload("res://assets/icons/paper/control_toggle_on.tres"),
	&"control.scroll_grip": preload("res://assets/icons/paper/control_scroll_grip.tres"),
}

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
	&"ai_researcher": true,
	&"apprentice": true,
	&"artisan": true,
	&"chemist": true,
	&"construction_worker": true,
	&"cooperative_member": true,
	&"corvee_worker": true,
	&"data_scientist": true,
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
	&"soldier": true,
	&"subsistence_farmer": true,
	&"technician": true,
	&"tenant_farmer": true,
	&"transport_worker": true,
	&"unemployed": true,
	&"worker": true,
}

# This is the only implementation registry. Callers retain distinct semantic
# keys even when several concepts intentionally share one visual today.
const SPECS := {
	&"action.add": true,
	&"action.back": true,
	&"action.chevron_down": true,
	&"action.chevron_right": true,
	&"action.close": true,
	&"action.confirm": true,
	&"action.fit": true,
	&"action.history": true,
	&"action.more": true,
	&"action.pause": true,
	&"action.pin": true,
	&"action.play": true,
	&"action.refresh": true,
	&"action.reset": true,
	&"action.save": true,
	&"climate.humidity": true,
	&"climate.moon": true,
	&"climate.snow": true,
	&"climate.sun": true,
	&"climate.temperature": true,
	&"climate.weather": true,
	&"climate.wind": true,
	&"country.affairs": true,
	&"country.diplomacy": true,
	&"country.military": true,
	&"country.politics": true,
	&"country.economy": true,
	&"country.technology": true,
	&"country.world": true,
	&"family.house": true,
	&"family.workspace.crest": true,
	&"family.workspace.prestige": true,
	&"family.workspace.person": true,
	&"family.workspace.overview": true,
	&"family.workspace.traits": true,
	&"family.workspace.preferences": true,
	&"family.workspace.effects": true,
	&"family.workspace.people": true,
	&"family.workspace.branches": true,
	&"family.metric.population": true,
	&"family.metric.wealth": true,
	&"family.metric.buildings": true,
	&"family.metric.time": true,
	&"economy.building": true,
	&"economy.building.factory": true,
	&"economy.building.farm": true,
	&"economy.building.fishing": true,
	&"economy.building.food": true,
	&"economy.building.forestry": true,
	&"economy.building.gathering": true,
	&"economy.building.hearth": true,
	&"economy.building.hunting": true,
	&"economy.building.market": true,
	&"economy.building.mine": true,
	&"economy.building.power": true,
	&"economy.building.science": true,
	&"economy.building.service": true,
	&"economy.building.shipyard": true,
	&"economy.building.transport": true,
	&"economy.building.workshop": true,
	&"economy.crop": true,
	&"economy.fuel": true,
	&"economy.livestock": true,
	&"economy.resource": true,
	&"ecology.growth": true,
	&"ecology.vegetation": true,
	&"geography.elevation": true,
	&"geography.surface": true,
	&"geography.terrain": true,
	&"hud.clock.calendar": true,
	&"hud.clock.pause": true,
	&"hud.clock.play": true,
	&"hud.clock.speed": true,
	&"hud.country.diplomacy": true,
	&"hud.country.economy": true,
	&"hud.country.ideology": true,
	&"hud.country.military": true,
	&"hud.country.technology": true,
	&"hud.overlay.biology": true,
	&"hud.overlay.clear": true,
	&"hud.overlay.climate": true,
	&"hud.overlay.geography": true,
	&"hud.overlay.resources": true,
	&"hud.system.day_night_off": true,
	&"hud.system.day_night_on": true,
	&"hud.system.gm": true,
	&"hud.system.settings": true,
	&"hydrology.current": true,
	&"hydrology.water": true,
	&"metric.goods": true,
	&"metric.technology": true,
	&"metric.territory": true,
	&"map.expedition": true,
	&"map.population": true,
	&"map.construction": true,
	&"metric.treasury": true,
	&"population.heart": true,
	&"population.living.affluent": true,
	&"population.living.comfortable": true,
	&"population.living.destitute": true,
	&"population.living.luxury": true,
	&"population.living.poor": true,
	&"population.living.secure": true,
	&"population.living.struggling": true,
	&"population.profession.artisan": true,
	&"population.profession.fisher": true,
	&"population.profession.merchant": true,
	&"population.profession.owner": true,
	&"population.profession.scholar": true,
	&"population.profession.unemployed": true,
	&"population.profession.worker": true,
	&"resource.animal": true,
	&"resource.arable_land": true,
	&"resource.bauxite": true,
	&"resource.clay": true,
	&"resource.coal": true,
	&"resource.copper": true,
	&"resource.earth": true,
	&"resource.fertile_soil": true,
	&"resource.fire": true,
	&"resource.fish": true,
	&"resource.flint": true,
	&"resource.freshwater_fish": true,
	&"resource.gold": true,
	&"resource.iron": true,
	&"resource.lead": true,
	&"resource.limestone": true,
	&"resource.manganese": true,
	&"resource.marine_fish": true,
	&"resource.metal": true,
	&"resource.natural_gas": true,
	&"resource.oil": true,
	&"resource.paddy_land": true,
	&"resource.pasture": true,
	&"resource.phosphate_rock": true,
	&"resource.plantation_land": true,
	&"resource.precious": true,
	&"resource.rare_earth": true,
	&"resource.rock": true,
	&"resource.salt": true,
	&"resource.salt_deposit": true,
	&"resource.saltpeter": true,
	&"resource.silica_sand": true,
	&"resource.silver": true,
	&"resource.sulfur": true,
	&"resource.tin": true,
	&"resource.wood": true,
	&"resource.zinc": true,
	&"status.hidden": true,
	&"status.warning": true,
	&"summary.overview": true,
	&"system.calendar": true,
	&"tax.business": true,
	&"tax.consumption": true,
	&"tax.default": true,
	&"tax.export": true,
	&"tax.import": true,
	&"tax.income": true,
	&"tax.section": true,
	&"tax.tariff": true,
	&"system.clock": true,
	&"system.seed": true,
	&"system.settings": true,
	&"system.target": true,
	&"system.unknown": true,
	&"technology.domain.agriculture": true,
	&"technology.domain.engineering": true,
	&"technology.domain.science": true,
	&"technology.domain.society": true,
	&"technology.milestone": true,
	&"technology.state.available": true,
	&"technology.state.completed": true,
	&"technology.state.locked": true,
	&"technology.state.pending": true,
	&"technology.state.queued": true,
	&"technology.state.unknown": true,
	&"trend.down": true,
	&"trend.flat": true,
	&"trend.up": true,
	# 军事专用纸贴（见 MILITARY_PAPER_TEXTURES）。
	&"military.army.attack": true,
	&"military.army.defense": true,
	&"military.army.morale": true,
	&"military.army.organization": true,
	&"military.army.pay": true,
	&"military.army.supply": true,
	&"military.banner": true,
	&"military.building.barracks": true,
	&"military.building.fortification": true,
	&"military.building.storage": true,
	&"military.building.war_college": true,
	&"military.good.ammunition": true,
	&"military.good.armor": true,
	&"military.good.bows": true,
	&"military.good.electronics": true,
	&"military.good.firearms": true,
	&"military.good.fuel": true,
	&"military.good.ordnance": true,
	&"military.good.propellant": true,
	&"military.ledger.convoy": true,
	&"military.ledger.income": true,
	&"military.ledger.wage": true,
	&"military.plan.barracks": true,
	&"military.plan.quality": true,
	&"military.plan.share": true,
	&"military.plan.target": true,
	&"military.plan.training": true,
	&"military.supply.equipment": true,
	&"military.supply.fodder": true,
	&"military.supply.ration": true,
	&"military.unit.air": true,
	&"military.unit.armored": true,
	&"military.unit.artillery": true,
	&"military.unit.line": true,
	&"military.unit.line.bows": true,
	&"military.unit.militia": true,
	&"military.unit.mobile": true,
	&"military.war.battle": true,
	&"military.war.front": true,
	&"military.war.peace": true,
	&"military.war.score": true,
	&"military.war.truce": true,
}

# Legacy identifiers exist only at this boundary and should not be added to.
const COMPATIBILITY_ALIASES := {
	"sun": &"climate.sun", "climate": &"climate.sun", "\u263c": &"climate.sun",
	"moon": &"climate.moon", "day_night": &"climate.moon", "night": &"climate.moon",
	"overview": &"summary.overview", "summary": &"summary.overview",
	"eco": &"ecology.vegetation", "tree": &"ecology.vegetation", "leaf": &"ecology.vegetation",
	"forest": &"ecology.vegetation", "timber": &"resource.wood", "\u2663": &"ecology.vegetation",
	"growth": &"ecology.growth", "regen": &"ecology.growth", "\u219f": &"ecology.growth",
	"water": &"hydrology.water", "hydrology": &"hydrology.water", "river": &"hydrology.water",
	"ocean": &"hydrology.water", "\u2248": &"hydrology.water", "\u2601": &"hydrology.water",
	"resource": &"economy.resource", "ore": &"economy.resource", "mineral": &"economy.resource",
	"stone": &"resource.rock", "\u25c6": &"economy.resource", "\u25c7": &"economy.resource",
	"fuel": &"economy.fuel", "oil": &"economy.fuel", "gas": &"economy.fuel",
	"crop": &"economy.crop", "grain": &"economy.crop", "wheat": &"economy.crop",
	"rice": &"economy.crop", "corn": &"economy.crop", "potato": &"economy.crop",
	"soil": &"economy.crop", "cotton": &"economy.crop", "flax": &"economy.crop",
	"livestock": &"economy.livestock", "horse": &"economy.livestock",
	"pasture": &"economy.livestock", "game": &"economy.livestock",
	"target": &"system.target", "coord": &"system.target", "wind": &"climate.wind",
	"trend_up": &"trend.up", "up": &"trend.up", "trend_down": &"trend.down",
	"down": &"trend.down", "trend_flat": &"trend.flat", "flat": &"trend.flat",
	"snow": &"climate.snow", "ice": &"climate.snow", "heart": &"population.heart",
	"history": &"action.history", "record": &"action.history",
	"geo": &"geography.terrain", "terrain": &"geography.terrain",
	"landform": &"geography.terrain", "mountain": &"geography.terrain",
	"elevation": &"geography.elevation", "vegetation": &"ecology.vegetation",
	"temperature": &"climate.temperature", "humidity": &"climate.humidity",
	"ocean_current": &"hydrology.current", "resource_close": &"status.hidden",
	"eye_slash": &"status.hidden", "wood": &"resource.wood", "rock": &"resource.rock",
	"fire": &"resource.fire", "metal": &"resource.metal", "precious": &"resource.precious",
	"fish": &"resource.fish", "animal": &"resource.animal", "earth": &"resource.earth",
	"salt": &"resource.salt", "flint": &"resource.flint",
	"building": &"economy.building", "buildings": &"economy.building",
	"industry": &"economy.building", "factory": &"economy.building",
	"surface": &"geography.surface", "cover": &"geography.surface",
	"weather": &"climate.weather", "cloud": &"climate.weather",
	"settings": &"system.settings", "setup": &"system.settings",
	"fit": &"action.fit", "frame": &"action.fit", "regenerate": &"action.refresh",
	"refresh": &"action.refresh", "pause": &"action.pause", "play": &"action.play",
	"plus": &"action.add", "add": &"action.add", "new": &"action.add",
	"back": &"action.back", "previous": &"action.back", "confirm": &"action.confirm",
	"apply": &"action.confirm", "save": &"action.save", "close": &"action.close",
	"expand": &"action.chevron_right", "collapse": &"action.chevron_down",
	"chevron_right": &"action.chevron_right", "chevron_down": &"action.chevron_down",
	"world": &"country.world", "globe": &"country.world", "clock": &"system.clock",
	"time": &"system.clock", "calendar": &"system.calendar", "date": &"system.calendar",
	"seed": &"system.seed", "warning": &"status.warning", "risk": &"status.warning",
	"technology": &"country.technology", "science": &"country.technology",
	"research": &"country.technology", "politics": &"country.politics",
	"government": &"country.politics", "economy": &"country.economy",
	"military": &"country.military",
	"army": &"country.military", "defense": &"country.military",
	"diplomacy": &"country.diplomacy", "foreign_affairs": &"country.diplomacy",
	"affairs": &"country.affairs", "territory": &"metric.territory",
	"treasury": &"metric.treasury", "goods": &"metric.goods",
	"living_destitute": &"population.living.destitute",
	"living_struggling": &"population.living.struggling",
	"living_poor": &"population.living.poor", "living_secure": &"population.living.secure",
	"living_comfortable": &"population.living.comfortable",
	"living_affluent": &"population.living.affluent", "living_luxury": &"population.living.luxury",
	"profession_worker": &"population.profession.worker",
	"profession_artisan": &"population.profession.artisan",
	"profession_fisher": &"population.profession.fisher",
	"profession_merchant": &"population.profession.merchant",
	"profession_scholar": &"population.profession.scholar",
	"profession_owner": &"population.profession.owner",
	"profession_unemployed": &"population.profession.unemployed",
}

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
		var base_key := _paper_building_base(kind, product_id)
		return {"family": FAMILY_PAPER,
			"texture": _paper_building_texture(kind, product_id, base_key),
			"identity": "building.%s@%s" % [kind, product_id]}
	return {"family": FAMILY_PAPER, "texture": PAPER_TEXTURES[&"system.unknown"]}


static func _paper_building_base(kind: String, product_id: StringName) -> StringName:
	var product := String(product_id)
	if product.ends_with("_ore") or product in ["coal", "crude_oil", "natural_gas",
			"raw_stone", "clay", "flint", "limestone", "silica_sand", "salt", "saltpeter", "sulfur", "bauxite", "phosphate_rock"]:
		return &"economy.building.mine"
	if product in ["logs", "lumber", "latex", "natural_rubber"]:
		return &"economy.building.forestry" if kind == "collector" else &"economy.building.workshop"
	if product in ["fish", "canned_fish"]:
		return &"economy.building.fishing" if kind == "collector" else &"economy.building.food"
	if product in ["game_meat", "fur", "raw_hide"]:
		return &"economy.building.hunting"
	if product in ["gathered_plants", "medicinal_herbs"]:
		return &"economy.building.gathering"
	if product.ends_with("_grain") or product in ["grain", "potatoes", "vegetables",
			"horses", "livestock_products", "cotton_fiber", "seed_cotton", "flax_fiber", "bast_fiber", "wool"]:
		return &"economy.building.farm"
	if product in ["bread", "prepared_staples", "processed_food", "beverages", "dairy_products", "edible_oil", "meat"]:
		return &"economy.building.food"
	if product == "technology_points":
		return &"economy.building.science"
	if product == "electricity":
		return &"economy.building.power"
	if product == "oceanic_vessels":
		return &"economy.building.shipyard"
	if kind == "collector":
		return &"economy.building.gathering"
	if kind == "service":
		return &"economy.building.service"
	return &"economy.building.factory"


static func _paper_building_texture(kind: String, product_id: StringName,
		base_key: StringName) -> Texture2D:
	var cache_key := "%s@%s" % [kind, product_id]
	if _paper_building_textures.has(cache_key):
		return _paper_building_textures[cache_key] as Texture2D
	# 只在首次显示时合成纸贴；按建筑类型和产物缓存，不进入每日刷新热路径。
	var canvas := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	var base := (PAPER_TEXTURES[base_key] as Texture2D).get_image()
	base.convert(Image.FORMAT_RGBA8)
	base.resize(108, 108, Image.INTERPOLATE_LANCZOS)
	canvas.blend_rect(base, Rect2i(0, 0, 108, 108), Vector2i.ZERO)
	var product := texture_for_key(good_semantic(String(product_id))).get_image()
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
