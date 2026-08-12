extends SceneTree

# One-shot, deterministic authoring migration. It reads the currently compiled
# catalog and economy reverse bindings, then writes the sole editable network
# payload consumed by TechnologyCatalog.

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")

const OUTPUT_PATH := "res://data/technology/technology_network.json"
const GOOD_DIR := "res://data/goods"
const BUILDING_DIR := "res://data/economy/buildings"
const RESOURCE_DIR := "res://data/resources"

const BACKBONES := [
	"backbone.food_storage",
	"backbone.tools_machinery",
	"backbone.knowledge_computation",
	"backbone.institutions_exchange",
]

const BRANCHES := [
	"branch.maize_horticulture",
	"branch.wheat_rainfed",
	"branch.rice_irrigation",
	"branch.tuber_highland",
	"branch.pastoral_livestock",
	"branch.tropical_commodities",
	"branch.forest_biomass",
	"branch.maritime_logistics",
	"branch.textile_fibers",
	"branch.construction_materials",
	"branch.nonferrous_metals",
	"branch.heavy_industry",
	"branch.industrial_chemistry",
	"branch.petroleum_materials",
	"branch.water_wind",
	"branch.electric_intelligent_energy",
]

const LANE_NAMES_ZH := {
	"backbone.food_storage": "食物、保存与公共储备",
	"backbone.tools_machinery": "工具、机械与自动控制",
	"backbone.knowledge_computation": "观察、科学与计算",
	"backbone.institutions_exchange": "制度、交换与组织",
	"branch.maize_horticulture": "玉米与园圃农业",
	"branch.wheat_rainfed": "小麦、谷物与雨养农业",
	"branch.rice_irrigation": "水稻、水田与灌溉农业",
	"branch.tuber_highland": "块茎、旱地与高地农业",
	"branch.pastoral_livestock": "草原、马匹与畜牧业",
	"branch.tropical_commodities": "热带作物与商品农业",
	"branch.forest_biomass": "森林、木材、造纸与生物质",
	"branch.maritime_logistics": "渔业、航海、港口与海运物流",
	"branch.textile_fibers": "纤维、纺织、服装与合成纤维",
	"branch.construction_materials": "黏土、石材、玻璃与公共营造",
	"branch.nonferrous_metals": "铜、锡、有色金属与特种合金",
	"branch.heavy_industry": "铁、煤、深井采矿、蒸汽与重工业",
	"branch.industrial_chemistry": "盐、硫、磷肥、炸药与工业化学",
	"branch.petroleum_materials": "石油、内燃机、石化与合成材料",
	"branch.water_wind": "水力、风力、水务与流域工程",
	"branch.electric_intelligent_energy": "电气、核能、电网与智能能源",
}

const BRANCH_TERMS := {
	"branch.maize_horticulture": ["maize", "horticulture", "garden"],
	"branch.wheat_rainfed": ["wheat", "grain", "rainfed", "thresh", "bread"],
	"branch.rice_irrigation": ["rice", "paddy"],
	"branch.tuber_highland": ["tuber", "potato", "highland", "terrace", "dryland"],
	"branch.pastoral_livestock": ["pastoral", "livestock", "horse", "herd", "dairy", "meat", "wool", "hunting", "game"],
	"branch.tropical_commodities": ["tropical", "spice", "rubber", "plantation", "commodity_crop"],
	"branch.forest_biomass": ["forest", "timber", "wood", "paper", "biomass", "charcoal"],
	"branch.maritime_logistics": ["fish", "coast", "ocean", "ship", "port", "maritime", "navigation"],
	"branch.textile_fibers": ["fiber", "textile", "weav", "cloth", "garment", "flax", "cotton", "sewing", "felt"],
	"branch.construction_materials": ["clay", "stone", "glass", "masonry", "construction", "cement", "brick", "earth_building"],
	"branch.nonferrous_metals": ["copper", "tin", "bronze", "nonferrous", "aluminum", "bauxite", "alloy"],
	"branch.heavy_industry": ["iron", "coal", "steel", "mine", "mining", "steam", "machine", "rail"],
	"branch.industrial_chemistry": ["salt", "sulfur", "phosphate", "fertilizer", "chemical", "gunpowder", "explosive"],
	"branch.petroleum_materials": ["oil", "petroleum", "combust", "petrochemical", "synthetic", "refined_fuel"],
	"branch.water_wind": ["water", "hydraulic", "irrigation", "canal", "river", "wind", "hydro"],
	"branch.electric_intelligent_energy": ["electric", "grid", "nuclear", "energy", "motor", "semiconductor", "smart_grid"],
}

const BACKBONE_TERMS := {
	"backbone.food_storage": ["food", "storage", "preserv", "granary", "storehouse", "ferment"],
	"backbone.tools_machinery": ["tool", "precision", "standard", "machin", "automation", "control"],
	"backbone.knowledge_computation": ["observ", "knowledge", "research", "science", "comput", "learning", "writing"],
	"backbone.institutions_exchange": ["institution", "market", "administr", "organization", "company", "cooper", "platform", "settlement"],
}

const DEFAULT_EVIDENCE := {
	"branch.maize_horticulture": "bio.maize",
	"branch.wheat_rainfed": "bio.wheat",
	"branch.rice_irrigation": "bio.rice",
	"branch.tuber_highland": "bio.potato",
	"branch.pastoral_livestock": "bio.horse",
	"branch.tropical_commodities": "bio.spice",
	"branch.forest_biomass": "resource.timber",
	"branch.maritime_logistics": "landform.coast",
	"branch.textile_fibers": "bio.flax",
	"branch.construction_materials": "resource.clay",
	"branch.nonferrous_metals": "resource.copper_ore",
	"branch.heavy_industry": "resource.iron_ore",
	"branch.industrial_chemistry": "resource.sulfur",
	"branch.petroleum_materials": "resource.oil",
	"branch.water_wind": "landform.freshwater_access",
	"branch.electric_intelligent_energy": "breakthrough.electrification",
	"backbone.food_storage": "breakthrough.seed_saving",
	"backbone.tools_machinery": "breakthrough.kiln_temperature",
	"backbone.knowledge_computation": "breakthrough.printing",
	"backbone.institutions_exchange": "breakthrough.industrial_organization",
}

const EVIDENCE_BY_LANE := {
	"backbone.food_storage": ["breakthrough.seed_saving", "resource.fertile_soil", "weather.repeated_crop_failure"],
	"backbone.tools_machinery": ["breakthrough.kiln_temperature", "breakthrough.metalworking", "breakthrough.digital_control"],
	"backbone.knowledge_computation": ["breakthrough.printing", "breakthrough.climate_modeling", "breakthrough.digital_control"],
	"backbone.institutions_exchange": ["breakthrough.industrial_organization", "breakthrough.assembly_line", "breakthrough.print_calibration"],
	"branch.maize_horticulture": ["bio.maize", "contact.maize", "breakthrough.maize_selection"],
	"branch.wheat_rainfed": ["bio.wheat", "contact.wheat", "breakthrough.rainfed_adaptation"],
	"branch.rice_irrigation": ["bio.rice", "contact.rice", "breakthrough.paddy_control"],
	"branch.tuber_highland": ["bio.potato", "contact.potato", "breakthrough.terrace_maintenance"],
	"branch.pastoral_livestock": ["resource.pasture", "landform.grassland", "bio.horse"],
	"branch.tropical_commodities": ["bio.spice", "bio.rubber", "contact.spice"],
	"branch.forest_biomass": ["resource.timber", "landform.forest", "breakthrough.forest_management"],
	"branch.maritime_logistics": ["landform.coast", "resource.marine_fish", "breakthrough.maritime_operations"],
	"branch.textile_fibers": ["bio.flax", "bio.cotton", "contact.flax"],
	"branch.construction_materials": ["resource.clay", "resource.stone", "breakthrough.kiln_temperature"],
	"branch.nonferrous_metals": ["resource.copper_ore", "resource.tin_ore", "breakthrough.metalworking"],
	"branch.heavy_industry": ["resource.iron_ore", "resource.coal", "breakthrough.mine_support"],
	"branch.industrial_chemistry": ["resource.salt", "resource.sulfur", "breakthrough.chemical_process_control"],
	"branch.petroleum_materials": ["resource.oil", "resource.natural_gas", "breakthrough.chemical_process_control"],
	"branch.water_wind": ["landform.freshwater_access", "landform.river_valley", "breakthrough.watershed_management"],
	"branch.electric_intelligent_energy": ["breakthrough.electrification", "breakthrough.energy_control", "resource.rare_earth"],
}

# Evidence must describe knowledge that can plausibly exist in the node's era.
# These five phases prevent a route's modern payoff vocabulary from leaking
# backwards into its ancient anchors while preserving non-technology bypasses.
const PHASED_EVIDENCE_BY_LANE := {
	"backbone.tools_machinery": [
		["resource.flint", "resource.stone", "breakthrough.kiln_temperature"],
		["breakthrough.metalworking", "breakthrough.kiln_temperature", "resource.iron_ore"],
		["breakthrough.steam_sealing", "breakthrough.assembly_line", "breakthrough.industrial_organization"],
		["breakthrough.electrification", "breakthrough.motor_winding", "breakthrough.assembly_line"],
		["breakthrough.digital_control", "breakthrough.automation", "resource.rare_earth"],
	],
	"backbone.knowledge_computation": [
		["weather.monsoon", "weather.frost", "landform.river_valley"],
		["breakthrough.printing", "breakthrough.print_calibration", "breakthrough.maritime_operations"],
		["breakthrough.steam_power", "breakthrough.industrial_organization", "breakthrough.print_calibration"],
		["breakthrough.electrification", "breakthrough.assembly_line", "breakthrough.motor_winding"],
		["breakthrough.digital_control", "breakthrough.climate_modeling", "breakthrough.automation"],
	],
	"backbone.institutions_exchange": [
		["resource.fertile_soil", "landform.river_valley", "breakthrough.seed_saving"],
		["breakthrough.printing", "breakthrough.print_calibration", "breakthrough.maritime_operations"],
		["breakthrough.industrial_organization", "breakthrough.assembly_line", "breakthrough.steam_power"],
		["breakthrough.electrification", "breakthrough.industrial_organization", "breakthrough.assembly_line"],
		["breakthrough.digital_control", "breakthrough.automation", "breakthrough.energy_control"],
	],
	"branch.industrial_chemistry": [
		["resource.salt", "resource.sulfur", "resource.clay"],
		["resource.saltpeter", "resource.sulfur", "breakthrough.kiln_temperature"],
		["resource.phosphate_rock", "resource.sulfur", "breakthrough.chemical_process_control"],
		["breakthrough.chemical_process_control", "breakthrough.electrification", "resource.phosphate_rock"],
		["breakthrough.chemical_process_control", "breakthrough.digital_control", "resource.rare_earth"],
	],
	"branch.petroleum_materials": [
		["bio.rubber", "resource.oil", "resource.natural_gas"],
		["resource.oil", "resource.natural_gas", "resource.coal"],
		["resource.oil", "resource.natural_gas", "breakthrough.chemical_process_control"],
		["breakthrough.chemical_process_control", "breakthrough.electrification", "resource.oil"],
		["breakthrough.chemical_process_control", "breakthrough.digital_control", "breakthrough.energy_control"],
	],
	"branch.electric_intelligent_energy": [
		["resource.timber", "resource.clay", "breakthrough.kiln_temperature"],
		["resource.coal", "landform.stable_wind_corridor", "breakthrough.kiln_temperature"],
		["breakthrough.steam_power", "breakthrough.steam_sealing", "breakthrough.assembly_line"],
		["breakthrough.electrification", "breakthrough.motor_winding", "breakthrough.assembly_line"],
		["breakthrough.energy_control", "breakthrough.digital_control", "resource.rare_earth"],
	],
}

# The order of each route array is exactly BRANCHES. These are deliberate
# design decisions, not keyword matches. Every era therefore has one stable
# anchor for every specialist route and four non-milestone backbone anchors.
const ROUTE_ANCHORS_BY_ERA := {
	"stone": ["tech.wild_maize_collection", "tech.wild_wheat_collection", "tech.wild_rice_collection", "tech.tuber_storage", "tech.herd_management", "tech.wild_spice_collection", "tech.charcoal_burning", "tech.fishing_boats", "tech.fiber_twisting", "tech.hand_pottery", "tech.natural_copper_working", "tech.copper_ore_roasting", "tech.brine_collection", "tech.wild_latex_tapping", "tech.reed_identification", "tech.controlled_burning"],
	"agrarian": ["tech.maize_garden_horticulture", "tech.rainfed_wheat_cultivation", "tech.rice_paddy_cultivation", "tech.highland_tuber_farming", "tech.horse_domestication", "tech.spice_shade_gardening", "tech.timber_sawing", "tech.pottery", "tech.loom_weaving", "tech.adobe_making", "tech.bronze_casting", "tech.animal_traction", "tech.salt_preservation", "tech.rubber_working", "tech.irrigation", "tech.kiln_firing"],
	"kingdom": ["tech.customary_tenancy", "tech.crop_rotation", "tech.tenant_paddy_management", "tech.sharecropping", "tech.parchment_making", "tech.market_institutions", "tech.bark_paper_making", "tech.river_transport", "tech.plant_fiber_papermaking", "tech.masonry", "tech.currency", "tech.iron_smelting", "tech.urban_sanitation", "tech.natural_philosophy", "tech.canal_engineering", "tech.surface_coal_use"],
	"empire": ["tech.manorial_cereal_farming", "tech.intensive_crop_rotation", "tech.estate_paddy_management", "tech.estate_cereal_management", "tech.pastoral_networks", "tech.serf_obligations", "tech.forest_management", "tech.magnetic_navigation", "tech.rag_paper_making", "tech.urban_waterworks", "tech.crucible_steel", "tech.blast_furnace", "tech.gunpowder_formulation", "tech.coal_mining", "tech.water_power", "tech.wind_power"],
	"exploration": ["tech.agronomic_exchange", "tech.crop_transplantation", "tech.interregional_botany", "tech.crop_acclimatization", "tech.commercial_estates", "tech.estate_plantation_management", "tech.screw_press_printing", "tech.oceanic_navigation", "tech.commodity_crop_management", "tech.coastal_shipyards", "tech.shaft_sinking", "tech.deep_mining", "tech.gunpowder_weapons", "tech.chartered_companies", "tech.mine_drainage", "tech.celestial_navigation"],
	"enlightenment": ["tech.soil_experimentation", "tech.agricultural_improvement", "tech.agricultural_cooperatives", "tech.crop_breeding", "tech.livestock_breeding", "tech.scientific_classification", "tech.learned_societies", "tech.precision_instruments", "tech.wage_contracts", "tech.property_cadastre", "tech.geological_prospecting", "tech.atmospheric_engine", "tech.public_health", "tech.coal_geology", "tech.hydraulic_engineering", "tech.steam_sealing"],
	"steam": ["tech.mechanized_agriculture", "tech.mechanical_threshing", "tech.mechanical_reaping", "tech.fertilizer_processing", "tech.labor_organization", "tech.managerial_hierarchy", "tech.steam_sawmilling", "tech.rail_logistics", "tech.textile_machinery", "tech.interchangeable_parts", "tech.coke_smelting", "tech.industrial_coal_mining", "tech.industrial_chemistry", "tech.steam_power", "tech.steam_pumping", "tech.assembly_line"],
	"electrical": ["tech.synthetic_fertilizer", "tech.motorized_agriculture", "tech.electric_motors", "tech.cold_chain", "tech.modern_husbandry", "tech.refrigeration", "tech.electrochemistry", "tech.telecommunications", "tech.corporate_management", "tech.electrification", "tech.electromagnetic_induction", "tech.petroleum_drilling", "tech.modern_medicine", "tech.internal_combustion", "tech.electric_generation", "tech.electric_grid"],
	"atomic": ["tech.industrial_agronomy", "tech.collective_agriculture", "tech.systems_engineering", "tech.state_enterprises", "tech.corporate_agribusiness", "tech.public_health_systems", "tech.synthetic_materials", "tech.global_logistics", "tech.synthetic_fiber_engineering", "tech.plastics_engineering", "tech.specialty_alloys", "tech.mechanized_mining", "tech.petrochemical_cracking", "tech.petrochemical_industry", "tech.deep_geophysics", "tech.nuclear_energy"],
	"information": ["tech.precision_agriculture", "tech.crop_remote_sensing", "tech.precision_irrigation", "tech.biotechnology", "tech.bioinformatics", "tech.numerical_weather_prediction", "tech.satellite_observation", "tech.automated_logistics", "tech.networked_computing", "tech.geographic_information_systems", "tech.mineral_spectral_survey", "tech.sensor_networks", "tech.software_engineering", "tech.semiconductor_manufacturing", "tech.hydrological_remote_sensing", "tech.information_theory"],
	"intelligent": ["tech.intelligent_breeding", "tech.climate_modeling", "tech.adaptive_irrigation", "tech.computational_biology", "tech.human_machine_collaboration", "tech.knowledge_cooperatives", "tech.scientific_agents", "tech.autonomous_logistics", "tech.algorithmic_management", "tech.robotic_manufacturing", "tech.autonomous_mining", "tech.autonomous_labor_coordination", "tech.neural_networks", "tech.distributed_intelligence", "tech.algorithmic_governance", "tech.smart_grid"],
}

const BACKBONE_ANCHORS_BY_ERA := {
	"stone": ["tech.food_storage", "tech.composite_tools", "tech.natural_observation", "tech.communal_specialization"],
	"agrarian": ["tech.fermentation", "tech.plough_agriculture", "tech.celestial_calendars", "tech.permanent_settlements"],
	"kingdom": ["tech.urban_food_supply", "tech.weights_and_measures", "tech.writing", "tech.state_bureaucracy"],
	"empire": ["tech.regional_granaries", "tech.movable_type_printing", "tech.scholastic_method", "tech.guild_organization"],
	"exploration": ["tech.oceanic_provisioning", "tech.mechanical_timekeeping", "tech.cartography", "tech.double_entry_bookkeeping"],
	"enlightenment": ["tech.canning", "tech.standardization", "tech.experimental_science", "tech.cooperative_association"],
	"steam": ["tech.industrial_organization", "tech.machine_tools", "tech.thermodynamics", "tech.factory_system"],
	"electrical": ["tech.mass_production", "tech.industrial_quality_control", "tech.industrial_research", "tech.public_education"],
	"atomic": ["tech.industrial_ecology", "tech.electronic_control", "tech.national_laboratories", "tech.operations_research"],
	"information": ["tech.platform_coordination", "tech.digital_control", "tech.digital_computing", "tech.knowledge_economy"],
	"intelligent": ["tech.automated_agriculture", "tech.autonomous_systems", "tech.machine_learning", "tech.human_machine_cogovernance"],
}

const APPLICATION_LANE_TARGETS := {
	"branch.maize_horticulture": ["branch.industrial_chemistry", "branch.water_wind", "branch.heavy_industry", "branch.tropical_commodities"],
	"branch.wheat_rainfed": ["branch.industrial_chemistry", "branch.water_wind", "branch.heavy_industry", "branch.textile_fibers"],
	"branch.rice_irrigation": ["branch.water_wind", "branch.construction_materials", "branch.electric_intelligent_energy", "branch.maritime_logistics"],
	"branch.tuber_highland": ["branch.industrial_chemistry", "branch.construction_materials", "branch.electric_intelligent_energy", "branch.pastoral_livestock"],
	"branch.pastoral_livestock": ["branch.textile_fibers", "branch.wheat_rainfed", "branch.maritime_logistics", "branch.construction_materials"],
	"branch.tropical_commodities": ["branch.maritime_logistics", "branch.industrial_chemistry", "branch.petroleum_materials", "branch.textile_fibers"],
	"branch.forest_biomass": ["branch.construction_materials", "branch.maritime_logistics", "branch.industrial_chemistry", "branch.water_wind"],
	"branch.maritime_logistics": ["branch.forest_biomass", "branch.petroleum_materials", "branch.electric_intelligent_energy", "branch.tropical_commodities"],
	"branch.textile_fibers": ["branch.pastoral_livestock", "branch.industrial_chemistry", "branch.electric_intelligent_energy", "branch.maritime_logistics"],
	"branch.construction_materials": ["branch.forest_biomass", "branch.heavy_industry", "branch.water_wind", "branch.electric_intelligent_energy"],
	"branch.nonferrous_metals": ["branch.heavy_industry", "branch.electric_intelligent_energy", "branch.construction_materials", "branch.industrial_chemistry"],
	"branch.heavy_industry": ["branch.nonferrous_metals", "branch.industrial_chemistry", "branch.petroleum_materials", "branch.maritime_logistics"],
	"branch.industrial_chemistry": ["branch.maize_horticulture", "branch.petroleum_materials", "branch.textile_fibers", "branch.construction_materials"],
	"branch.petroleum_materials": ["branch.industrial_chemistry", "branch.maritime_logistics", "branch.textile_fibers", "branch.electric_intelligent_energy"],
	"branch.water_wind": ["branch.rice_irrigation", "branch.construction_materials", "branch.electric_intelligent_energy", "branch.maritime_logistics"],
	"branch.electric_intelligent_energy": ["branch.nonferrous_metals", "branch.heavy_industry", "branch.water_wind", "branch.petroleum_materials"],
}

const FAMILY_CANDIDATES := {
	"backbone.food_storage": ["staple_preparation", "bread_baking", "beverage_making", "fish_canning"],
	"backbone.tools_machinery": ["metal_toolmaking", "construction_methods", "railway_equipment_making", "steelmaking"],
	"backbone.knowledge_computation": ["research_institution", "paper_making", "glassmaking", "metal_toolmaking"],
	"backbone.institutions_exchange": ["research_institution", "paper_making", "jewelry_making", "construction_methods"],
	"branch.maize_horticulture": ["field_crop_farming", "staple_preparation", "bread_baking"],
	"branch.wheat_rainfed": ["field_crop_farming", "bread_baking", "staple_preparation"],
	"branch.rice_irrigation": ["field_crop_farming", "staple_preparation", "construction_methods"],
	"branch.tuber_highland": ["field_crop_farming", "staple_preparation", "construction_methods"],
	"branch.pastoral_livestock": ["livestock_husbandry", "dairy_processing", "meat_processing", "horse_breeding", "wool_processing", "leather_processing"],
	"branch.tropical_commodities": ["field_crop_farming", "beverage_making", "chemical_industry", "cloth_weaving"],
	"branch.forest_biomass": ["paper_making", "fine_furniture_making", "construction_methods", "subsistence_food"],
	"branch.maritime_logistics": ["freshwater_fishing", "fish_canning", "railway_equipment_making", "staple_preparation"],
	"branch.textile_fibers": ["cloth_weaving", "garment_making", "household_cloth", "fine_clothing_making", "footwear_making", "wool_processing"],
	"branch.construction_materials": ["clay_extraction", "construction_methods", "glassmaking", "silica_extraction"],
	"branch.nonferrous_metals": ["copper_extraction", "tin_extraction", "jewelry_making", "metal_toolmaking"],
	"branch.heavy_industry": ["iron_extraction", "steelmaking", "railway_equipment_making", "metal_toolmaking"],
	"branch.industrial_chemistry": ["chemical_industry", "fertilizer_making", "salt_extraction", "glassmaking"],
	"branch.petroleum_materials": ["oil_extraction", "chemical_industry", "garment_making", "footwear_making"],
	"branch.water_wind": ["construction_methods", "freshwater_fishing", "field_crop_farming", "metal_toolmaking"],
	"branch.electric_intelligent_energy": ["metal_toolmaking", "research_institution", "railway_equipment_making", "steelmaking"],
}

const BROAD_STATS := [
	"country.output.agriculture_factor", "country.output.extractive_factor",
	"country.output.manufacturing_factor", "country.output.energy_factor",
	"country.output.knowledge_factor", "country.trade.capacity_factor",
	"country.trade.speed_factor", "country.research.agriculture_efficiency",
	"country.research.engineering_efficiency", "country.research.science_efficiency",
	"country.research.society_efficiency",
]

# Broad country effects are deliberately scarce. Reserve most of the allowed
# nodes for technologies that have no honest production-family consumer rather
# than spending the whole budget on early anchors.
const BROAD_NODE_LIMIT := 71
const BROAD_ANCHOR_BONUS_LIMIT := 24

const TERRAIN_EFFECT_IDS := [
	"ocean", "coast", "plain", "grassland", "forest", "hill", "mountain",
	"desert", "tundra", "snow", "swamp", "jungle", "savanna", "taiga",
	"steppe", "shrubland", "mangrove", "glacier", "lake", "reef", "sea_ice",
	"kelp", "delta", "oasis", "salt_flat", "badlands", "cold_desert",
	"chaparral", "moor", "floodplain", "mesa",
]

const LANDFORM_EFFECT_IDS := [
	"deep_ocean", "ocean", "coast", "lake", "plain", "lowland", "hill",
	"mountain", "peak", "delta", "badlands", "salt_flat", "volcano",
	"plateau", "rift_valley", "canyon",
]

# Geographic nodes need technology-specific evidence because a broad lane can
# span mutually exclusive environments. These signals are all published by the
# existing exploration/resource paths; they reveal the idea without replacing
# any hard prerequisite.
const EXPLICIT_EVIDENCE_BY_TECH := {
	"tech.hunting": ["resource.wild_game", "landform.grassland", "landform.forest"],
	"tech.gathering": ["resource.fertile_soil", "landform.forest", "landform.grassland"],
	"tech.stone_knapping": ["resource.flint", "resource.stone", "landform.mountain"],
	"tech.fire_control": ["resource.timber", "weather.drought", "landform.grassland"],
	"tech.freshwater_fishing": ["resource.freshwater_fish", "landform.freshwater_access", "landform.river_valley"],
	"tech.coastal_fishing": ["resource.marine_fish", "landform.coast", "landform.coastal_estuary"],
	"tech.earth_building": ["resource.clay", "landform.arid_basin", "landform.loess_plain"],
	"tech.wild_tuber_collection": ["bio.potato", "landform.high_plateau", "landform.mountain"],
	"tech.wild_flax_collection": ["bio.flax", "landform.grassland", "landform.forest"],
	"tech.gold_panning": ["resource.gold_ore", "landform.freshwater_access", "landform.river_valley"],
	"tech.surface_silver_collection": ["resource.silver_ore", "landform.mountain", "landform.high_plateau"],
	"tech.early_trade": ["resource.gold_ore", "resource.silver_ore"],
	"tech.deadwood_collection": ["resource.timber", "landform.forest", "landform.conifer_forest"],
	"tech.reed_identification": ["bio.reed", "landform.marsh", "landform.freshwater_access"],
	"tech.reed_harvesting": ["bio.reed", "landform.marsh", "landform.freshwater_access"],
	"tech.turf_cutting": ["resource.pasture", "landform.tundra", "landform.high_plateau"],
	"tech.hide_scraping": ["resource.wild_game", "landform.grassland", "landform.forest"],
	"tech.fur_sewing": ["resource.wild_game", "landform.tundra", "landform.conifer_forest"],
	"tech.felt_making": ["bio.sheep", "resource.pasture", "landform.grassland"],
	"tech.oral_memory_practice": ["weather.repeated_crop_failure", "weather.major_flood", "weather.drought"],
	"tech.phenology_observation": ["weather.frost", "weather.monsoon", "weather.drought"],
	"tech.flood_calendar_practice": ["landform.floodplain", "landform.river_valley", "weather.major_flood"],
	"tech.pastoral_route_memory": ["resource.pasture", "landform.grassland", "landform.steppe_plain"],
	"tech.tide_observation": ["landform.coast", "landform.coastal_estuary", "weather.storm_surge"],
	"tech.swidden_maize_cultivation": ["bio.maize", "landform.forest", "weather.drought"],
	"tech.rainfed_maize_cultivation": ["bio.maize", "resource.arable_land", "weather.drought"],
	"tech.flood_recession_maize": ["bio.maize", "landform.floodplain", "weather.major_flood"],
	"tech.rainfed_wheat_cultivation": ["bio.wheat", "landform.loess_plain", "weather.drought"],
	"tech.flood_recession_wheat": ["bio.wheat", "landform.floodplain", "weather.major_flood"],
	"tech.dryland_wheat_cultivation": ["bio.wheat", "landform.arid_basin", "weather.drought"],
	"tech.upland_rice_propagation": ["bio.rice", "landform.high_plateau", "weather.drought"],
	"tech.wetland_rice_gardening": ["bio.rice", "landform.marsh", "resource.paddy_land"],
	"tech.rice_water_control": ["resource.paddy_land", "landform.river_valley", "breakthrough.paddy_control"],
	"tech.dryland_farming": ["resource.arable_land", "landform.arid_basin", "weather.drought"],
	"tech.terrace_farming": ["landform.mountain", "landform.high_plateau", "breakthrough.terrace_maintenance"],
	"tech.rainfed_field_system": ["resource.arable_land", "weather.drought", "breakthrough.rainfed_adaptation"],
	"tech.paddy_bunding": ["resource.paddy_land", "landform.floodplain", "breakthrough.paddy_control"],
	"tech.dryland_water_retention": ["resource.arable_land", "weather.drought", "breakthrough.rainfed_adaptation"],
	"tech.highland_tuber_farming": ["bio.potato", "landform.high_plateau", "landform.mountain"],
	"tech.river_transport": ["landform.river_valley", "landform.freshwater_access", "weather.major_flood"],
	"tech.tenant_paddy_management": ["resource.paddy_land", "landform.floodplain", "breakthrough.paddy_control"],
	"tech.estate_paddy_management": ["resource.paddy_land", "landform.floodplain", "breakthrough.paddy_control"],
	"tech.wind_power": ["landform.stable_wind_corridor", "weather.monsoon", "weather.typhoon"],
}

# These institutional and computational technologies do not directly unlock a
# building, but they have an honest narrow consumer in the existing catalog.
# Pairing that consumer with a small broad spillover avoids generic-only buffs.
const EXPLICIT_BUILDING_EFFECT_BY_TECH := {
	"tech.wage_contracts": "guild_hall",
	"tech.long_term_leases": "landed_estate",
	"tech.cooperative_association": "guild_hall",
	"tech.agricultural_cooperatives": "intensive_farm",
	"tech.property_cadastre": "landed_estate",
	"tech.labor_organization": "guild_hall",
	"tech.worker_cooperatives": "guild_hall",
	"tech.telecommunications": "radio_equipment_works",
	"tech.corporate_agribusiness": "precision_farm",
	"tech.collective_agriculture": "mechanized_farm",
	"tech.state_enterprises": "electricity_plant",
	"tech.platform_coordination": "computing_research_center",
	"tech.digital_marketplaces": "computers_plant",
	"tech.bioinformatics": "computing_research_center",
	"tech.neural_networks": "machine_intelligence_institute",
	"tech.computational_biology": "national_laboratory",
	"tech.climate_modeling": "national_laboratory",
	"tech.intelligent_breeding": "precision_farm",
	"tech.knowledge_cooperatives": "machine_intelligence_institute",
}

const FAMILY_NAMES_ZH := {
	"chemical_industry": "化学工业",
	"clay_extraction": "黏土采掘",
	"cloth_weaving": "织布业",
	"construction_methods": "公共营造",
	"copper_extraction": "铜业",
	"field_crop_farming": "大田作物农业",
	"fine_furniture_making": "精细木作",
	"gold_extraction": "黄金采掘",
	"highland_crop_farming": "高地农业",
	"iron_extraction": "铁矿业",
	"jewelry_making": "珠宝业",
	"livestock_husbandry": "畜牧业",
	"maritime_operations": "海运业",
	"metal_toolmaking": "金属工具业",
	"paper_making": "造纸业",
	"railway_equipment_making": "运输装备业",
	"renewable_power_generation": "可再生能源业",
	"research_institution": "科研机构",
	"specialty_commodity_crops": "专用商品作物农业",
	"staple_preparation": "主粮加工",
	"steelmaking": "钢铁业",
	"tin_extraction": "锡业",
}

# Topic-level authoring rules keep discovery and numerical effects attached to
# what the technology actually concerns. They are intentionally keyed by
# stable ID tokens rather than by a lane: a lane can contain later convergence
# nodes such as computing, public health, or management.
const SEMANTIC_EVIDENCE_RULES := [
	{"tokens": ["cotton"], "signals": ["bio.cotton", "contact.cotton", "resource.plantation_land"]},
	{"tokens": ["flax", "fiber", "weaving", "loom", "spinning", "textile"], "signals": ["bio.flax", "bio.cotton", "contact.flax"]},
	{"tokens": ["spice"], "signals": ["bio.spice", "contact.spice", "resource.plantation_land"]},
	{"tokens": ["rubber", "latex"], "signals": ["bio.rubber", "contact.rubber", "landform.forest"]},
	{"tokens": ["maize"], "signals": ["bio.maize", "contact.maize", "breakthrough.maize_selection"]},
	{"tokens": ["wheat", "grain", "cereal", "rainfed", "dryland"], "signals": ["bio.wheat", "contact.wheat", "breakthrough.rainfed_adaptation"]},
	{"tokens": ["rice", "paddy"], "signals": ["bio.rice", "contact.rice", "breakthrough.paddy_control"]},
	{"tokens": ["potato", "tuber", "terrace", "highland"], "signals": ["bio.potato", "contact.potato", "breakthrough.terrace_maintenance"]},
	{"tokens": ["horse", "pastoral", "livestock", "herd", "wool", "dairy", "meat"], "signals": ["resource.pasture", "landform.grassland", "bio.horse"]},
	{"tokens": ["hide", "leather", "fur", "hunting", "animal"], "signals": ["resource.wild_game", "bio.sheep", "landform.grassland"]},
	{"tokens": ["forest", "timber", "wood", "lumber", "paper", "bark", "charcoal"], "signals": ["resource.timber", "landform.forest", "breakthrough.forest_management"]},
	{"tokens": ["fish", "fishing"], "signals": ["resource.freshwater_fish", "resource.marine_fish", "landform.coast"]},
	{"tokens": ["maritime", "ocean", "ship", "port", "navigation", "logistics", "coast"], "signals": ["landform.coast", "resource.marine_fish", "breakthrough.maritime_operations"]},
	{"tokens": ["clay", "pottery", "kiln", "brick", "adobe"], "signals": ["resource.clay", "resource.silica_sand", "breakthrough.kiln_temperature"]},
	{"tokens": ["flint", "stone", "masonry", "earth", "construction", "cement", "concrete"], "signals": ["resource.stone", "resource.flint", "resource.clay"]},
	{"tokens": ["glass", "silica"], "signals": ["resource.silica_sand", "resource.limestone", "breakthrough.kiln_temperature"]},
	{"tokens": ["copper"], "signals": ["resource.copper_ore", "resource.tin_ore", "breakthrough.metalworking"]},
	{"tokens": ["tin"], "signals": ["resource.tin_ore", "contact.tin", "breakthrough.metalworking"]},
	{"tokens": ["bronze", "alloy", "metallurgy", "metal"], "signals": ["resource.copper_ore", "resource.tin_ore", "breakthrough.metalworking"]},
	{"tokens": ["iron", "steel", "coal", "mine", "mining", "shaft"], "signals": ["resource.iron_ore", "resource.coal", "breakthrough.mine_support"]},
	{"tokens": ["gold", "silver"], "signals": ["resource.gold_ore", "resource.silver_ore", "landform.freshwater_access"]},
	{"tokens": ["salt"], "signals": ["resource.salt", "resource.saltpeter", "resource.sulfur"]},
	{"tokens": ["sulfur", "phosphate", "fertilizer", "gunpowder", "explosive", "chemistry", "chemical"], "signals": ["resource.sulfur", "resource.phosphate_rock", "resource.saltpeter"]},
	{"tokens": ["oil", "petroleum", "fuel", "combustion", "gas", "plastic", "synthetic"], "signals": ["resource.oil", "resource.natural_gas", "resource.coal"]},
	{"tokens": ["irrigation", "hydraulic", "canal", "water", "hydro", "watershed"], "signals": ["landform.freshwater_access", "landform.river_valley", "breakthrough.hydraulic_engineering"]},
	{"tokens": ["wind"], "signals": ["landform.stable_wind_corridor", "landform.freshwater_access", "breakthrough.hydraulic_engineering"]},
]

const SEMANTIC_FAMILY_RULES := [
	{"tokens": ["cotton", "flax", "fiber", "weaving", "loom", "spinning", "textile"], "families": ["cloth_weaving", "household_cloth", "garment_making", "fine_clothing_making"]},
	{"tokens": ["spice"], "families": ["specialty_commodity_crops", "beverage_making", "field_crop_farming"]},
	{"tokens": ["rubber", "latex", "synthetic", "plastic"], "families": ["chemical_industry", "specialty_commodity_crops", "cloth_weaving"]},
	{"tokens": ["maize", "wheat", "rice", "grain", "cereal", "rainfed", "paddy"], "families": ["field_crop_farming", "staple_preparation", "bread_baking"]},
	{"tokens": ["potato", "tuber", "terrace", "highland"], "families": ["highland_crop_farming", "field_crop_farming", "staple_preparation"]},
	{"tokens": ["fertilizer", "phosphate"], "families": ["fertilizer_making", "field_crop_farming", "chemical_industry"]},
	{"tokens": ["horse"], "families": ["horse_breeding", "livestock_husbandry", "wool_processing"]},
	{"tokens": ["dairy"], "families": ["dairy_processing", "livestock_husbandry", "meat_processing"]},
	{"tokens": ["meat"], "families": ["meat_processing", "livestock_husbandry", "dairy_processing"]},
	{"tokens": ["wool", "felt"], "families": ["wool_processing", "livestock_husbandry", "garment_making"]},
	{"tokens": ["pastoral", "livestock", "herd", "animal"], "families": ["livestock_husbandry", "meat_processing", "horse_breeding"]},
	{"tokens": ["hide", "leather", "fur", "hunting"], "families": ["leather_processing", "garment_making", "livestock_husbandry"]},
	{"tokens": ["forest", "forestry"], "families": ["precision_forestry", "fine_furniture_making", "paper_making"]},
	{"tokens": ["timber", "wood", "lumber", "sawmill", "charcoal"], "families": ["fine_furniture_making", "precision_forestry", "construction_methods"]},
	{"tokens": ["paper", "writing", "printing", "manuscript"], "families": ["paper_making", "research_institution", "fine_furniture_making"]},
	{"tokens": ["fish", "fishing", "canning"], "families": ["freshwater_fishing", "fish_canning", "maritime_operations"]},
	{"tokens": ["maritime", "ocean", "ship", "port", "navigation", "logistics"], "families": ["maritime_operations", "railway_equipment_making", "fish_canning"]},
	{"tokens": ["clay", "adobe"], "families": ["clay_extraction", "construction_methods", "glassmaking"]},
	{"tokens": ["pottery", "kiln", "brick", "masonry", "stone", "earth", "construction", "cement", "concrete"], "families": ["construction_methods", "clay_extraction", "glassmaking"]},
	{"tokens": ["glass", "silica"], "families": ["glassmaking", "silica_extraction", "construction_methods"]},
	{"tokens": ["flint", "tool", "machine", "machinery", "precision", "standard", "parts"], "families": ["metal_toolmaking", "construction_methods", "railway_equipment_making"]},
	{"tokens": ["copper"], "families": ["copper_extraction", "metal_toolmaking", "tin_extraction"]},
	{"tokens": ["tin"], "families": ["tin_extraction", "copper_extraction", "metal_toolmaking"]},
	{"tokens": ["bronze", "alloy", "metallurgy"], "families": ["metal_toolmaking", "copper_extraction", "steelmaking"]},
	{"tokens": ["iron", "coal", "mine", "mining", "shaft"], "families": ["iron_extraction", "steelmaking", "metal_toolmaking"]},
	{"tokens": ["steel", "coke"], "families": ["steelmaking", "metal_toolmaking", "iron_extraction"]},
	{"tokens": ["gold"], "families": ["gold_extraction", "jewelry_making", "metal_toolmaking"]},
	{"tokens": ["silver", "currency"], "families": ["jewelry_making", "gold_extraction", "metal_toolmaking"]},
	{"tokens": ["salt"], "families": ["salt_extraction", "chemical_industry", "fertilizer_making"]},
	{"tokens": ["sulfur", "gunpowder", "explosive", "chemical", "chemistry", "medicine"], "families": ["chemical_industry", "fertilizer_making", "salt_extraction"]},
	{"tokens": ["oil", "petroleum", "fuel", "combustion", "gas", "refining", "drilling"], "families": ["oil_extraction", "chemical_industry", "railway_equipment_making"]},
	{"tokens": ["irrigation", "hydraulic", "canal", "water", "watershed"], "families": ["construction_methods", "field_crop_farming", "renewable_power_generation"]},
	{"tokens": ["wind", "electric", "grid", "nuclear", "power", "motor"], "families": ["renewable_power_generation", "metal_toolmaking", "railway_equipment_making"]},
	{"tokens": ["research", "science", "knowledge", "comput", "software", "algorithm", "network", "information", "learning", "neural", "agent", "education"], "families": ["research_institution", "paper_making", "metal_toolmaking"]},
	{"tokens": ["market", "trade", "exchange", "merchant", "company", "corporate", "management", "organization", "administration", "governance"], "families": ["research_institution", "maritime_operations", "construction_methods"]},
]


func _init() -> void:
	var catalog: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)) or not bool(economy.get("ok", false)):
		push_error("technology network source catalog does not compile")
		quit(1)
		return
	var definitions: Array = TechnologyCatalogScript.public_definitions()
	var eras: Array = TechnologyCatalogScript.public_era_metadata()
	var domains: Array = TechnologyCatalogScript.public_domain_metadata()
	var payload := _build_payload(definitions, eras, domains, catalog, economy)
	var error := _validate_payload(payload)
	if not error.is_empty():
		push_error(error)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://data/technology"))
	var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("cannot write %s" % OUTPUT_PATH)
		quit(1)
		return
	file.store_string(JSON.stringify(payload, "\t", false, true) + "\n")
	file.close()
	print("[PASS] technology network authoring: %d nodes / %d visual edges -> %s" % [
		(payload.nodes as Array).size(), (payload.visual_edges as Array).size(), OUTPUT_PATH])
	quit(0)


func _build_payload(definitions: Array, eras: Array, domains: Array,
		catalog: Dictionary, economy: Dictionary) -> Dictionary:
	var era_ids := PackedStringArray()
	var era_milestones := {}
	for era in eras:
		var era_id := String((era as Dictionary).get("id", ""))
		era_ids.append(era_id)
		era_milestones[era_id] = String((era as Dictionary).get("milestone_id", ""))
	var id_to_index := {}
	for i in range(definitions.size()):
		id_to_index[String((definitions[i] as Dictionary).id)] = i
	var branch_anchors := _explicit_anchors(era_ids, BRANCHES, ROUTE_ANCHORS_BY_ERA,
		id_to_index)
	var backbone_anchors := _explicit_anchors(era_ids, BACKBONES,
		BACKBONE_ANCHORS_BY_ERA, id_to_index)
	var anchor_lane_by_id := {}
	for key in branch_anchors:
		anchor_lane_by_id[String(branch_anchors[key])] = String(key).get_slice("|", 1)
	for key in backbone_anchors:
		anchor_lane_by_id[String(backbone_anchors[key])] = String(key).get_slice("|", 1)

	var lane_by_id := {}
	for definition in definitions:
		var id := String((definition as Dictionary).id)
		if anchor_lane_by_id.has(id):
			lane_by_id[id] = String(anchor_lane_by_id[id])
		else:
			lane_by_id[id] = _best_lane(definition)

	var next_anchor := {}
	for lane in BACKBONES + BRANCHES:
		for era_index in range(era_ids.size() - 1):
			var current_key := "%s|%s" % [era_ids[era_index], lane]
			var next_key := "%s|%s" % [era_ids[era_index + 1], lane]
			var current_id := String((backbone_anchors if lane in BACKBONES else branch_anchors).get(current_key, ""))
			var next_id := String((backbone_anchors if lane in BACKBONES else branch_anchors).get(next_key, ""))
			if not current_id.is_empty() and not next_id.is_empty():
				next_anchor[current_id] = next_id

	var binding_by_id := _binding_records(catalog, economy)
	var content_display_names := _content_display_names()
	var family_totals := {}
	var broad_totals := {}
	var nodes: Array[Dictionary] = []
	var broad_count := 0
	for index in range(definitions.size()):
		var source: Dictionary = definitions[index]
		var id := String(source.id)
		var era_id := String(source.era_id)
		var era_index := era_ids.find(era_id)
		var lane := String(lane_by_id[id])
		var is_milestone := bool(source.is_milestone)
		var is_route_anchor := String(branch_anchors.get("%s|%s" % [era_id, lane], "")) == id
		var is_backbone_anchor := String(backbone_anchors.get("%s|%s" % [era_id, lane], "")) == id
		var hard := PackedStringArray()
		var research_condition := {}
		var reveal_condition := _reveal_condition(source, lane, era_index, era_ids,
			era_milestones)
		var same_lane_successors := PackedStringArray()
		if next_anchor.has(id):
			same_lane_successors.append(String(next_anchor[id]))
		var application_targets := _application_targets(id, lane, era_index, era_ids,
			branch_anchors, backbone_anchors, next_anchor)
		var bindings: Array = binding_by_id.get(id, [])
		var terms := _explicit_terms(source, lane, is_route_anchor, is_backbone_anchor,
			bindings, economy, family_totals, broad_totals, broad_count)
		_decorate_modifier_terms(terms, content_display_names)
		if _terms_include_broad(terms):
			broad_count += 1
		var content_effects := _content_effects(bindings, economy,
			content_display_names)
		var secondary_tags: PackedStringArray = source.route_tags
		if secondary_tags.size() > 2:
			secondary_tags = secondary_tags.slice(0, 2)
		nodes.append({
			"id": id,
			"display_name": String(source.display_name),
			"era_id": era_id,
			"domain_id": String(source.domain_id),
			"cost_points": _cost_points(source, era_id, era_milestones, definitions,
				is_route_anchor, is_backbone_anchor),
			"layout_order": index,
			"network_role": "backbone" if lane in BACKBONES else "branch",
			"anchor_kind": "milestone" if is_milestone else ("backbone_anchor" if is_backbone_anchor else ("route_anchor" if is_route_anchor else "support")),
			"node_role": String(source.node_role),
			"effect_profile": String(source.effect_profile),
			"main_lane": lane,
			"secondary_route_tags": secondary_tags,
			"hard_prerequisite_ids": hard,
			"research_condition": research_condition,
			"reveal_condition": reveal_condition,
			"is_milestone": is_milestone,
			"is_era_key": bool(source.is_era_key),
			"is_starting": bool(source.is_starting),
			"is_starter_eligible": bool(source.is_starter_eligible),
			"starter_capability_tags": source.starter_capability_tags,
			"is_milestone_candidate": is_route_anchor,
			"modifier_terms": terms,
			"expected_bindings": bindings,
			"content_effects": content_effects,
			"effect_summary": _effect_summary(content_effects, terms),
			"opportunity_cost": _opportunity_cost(lane, era_index),
			"same_lane_successor_ids": same_lane_successors,
			"application_target_ids": application_targets,
			"terminal_reason": ("该路线的智能时代终局回报" if era_index == era_ids.size() - 1 else ""),
		})
	_assign_hard_prerequisites(nodes, era_ids, branch_anchors, backbone_anchors)
	_apply_authored_prerequisite_overrides(nodes)

	var visual_edges := _visual_edges(nodes, era_ids, branch_anchors, id_to_index)
	return {
		"schema_version": 1,
		"eras": _plain_metadata(eras),
		"domains": _plain_metadata(domains),
		"backbones": _lane_metadata(BACKBONES),
		"specialist_lanes": _lane_metadata(BRANCHES),
		"nodes": nodes,
		"visual_edges": visual_edges,
	}


func _explicit_anchors(era_ids: PackedStringArray, lanes: Array,
		ids_by_era: Dictionary, id_to_index: Dictionary) -> Dictionary:
	var out := {}
	var used := {}
	for era_id in era_ids:
		var ids: Array = ids_by_era.get(String(era_id), [])
		if ids.size() != lanes.size():
			push_error("anchor row size mismatch: %s" % era_id)
			continue
		for lane_index in range(lanes.size()):
			var id := String(ids[lane_index])
			if not id_to_index.has(id) or used.has(id):
				push_error("anchor id missing or duplicated: %s" % id)
				continue
			out["%s|%s" % [era_id, lanes[lane_index]]] = id
			used[id] = true
	return out


func _select_anchors(definitions: Array, era_ids: PackedStringArray, lanes: Array,
		terms_by_lane: Dictionary, already_used: Dictionary) -> Dictionary:
	var out := {}
	var used_ids := {}
	for key in already_used:
		used_ids[String(already_used[key])] = true
	for era_id in era_ids:
		for lane in lanes:
			var best_id := ""
			var best_score := -1
			var best_index := 1 << 30
			for index in range(definitions.size()):
				var definition: Dictionary = definitions[index]
				var id := String(definition.id)
				if String(definition.era_id) != era_id or bool(definition.is_milestone) \
						or bool(definition.is_starting) or used_ids.has(id):
					continue
				var score := _score(definition, terms_by_lane[lane])
				if score > best_score or (score == best_score and index < best_index):
					best_score = score
					best_index = index
					best_id = id
			if best_id.is_empty():
				push_error("no anchor candidate for %s %s" % [era_id, lane])
				continue
			out["%s|%s" % [era_id, lane]] = best_id
			used_ids[best_id] = true
	return out


func _best_lane(definition: Dictionary) -> String:
	for raw_tag in definition.route_tags:
		var tag := String(raw_tag)
		if tag.begins_with("route.ecology.plants") or tag.begins_with("route.crop.general") \
				or tag.begins_with("route.crop.mechanized") or tag.begins_with("route.crop.industrial") \
				or tag.begins_with("route.crop.precision") or tag.begins_with("route.crop.automated") \
				or tag.begins_with("route.crop.biotechnology"):
			return "backbone.food_storage"
		if tag.begins_with("route.crop.maize"):
			return "branch.maize_horticulture"
		if tag.begins_with("route.crop.wheat"):
			return "branch.wheat_rainfed"
		if tag.begins_with("route.crop.rice"):
			return "branch.rice_irrigation"
		if tag.begins_with("route.crop.tuber") or tag.begins_with("route.geography.highland"):
			return "branch.tuber_highland"
		if tag.begins_with("route.ecology.pasture") or tag.begins_with("route.ecology.steppe") \
				or tag.begins_with("route.animal.horse") or tag.begins_with("route.ecology.game"):
			return "branch.pastoral_livestock"
		if tag.begins_with("route.crop.tropical") or tag.begins_with("route.crop.exchange"):
			return "branch.tropical_commodities"
		if tag.begins_with("route.ecology.forest"):
			return "branch.forest_biomass"
		if tag.begins_with("route.geography.coast") or tag.begins_with("route.trade.maritime"):
			return "branch.maritime_logistics"
		if tag.begins_with("route.craft.textiles"):
			return "branch.textile_fibers"
		if tag.begins_with("route.material.clay") or tag.begins_with("route.material.stone"):
			return "branch.construction_materials"
		if tag.begins_with("route.resource.copper") or tag.begins_with("route.resource.tin") \
				or tag.begins_with("route.resource.alloys"):
			return "branch.nonferrous_metals"
		if tag.begins_with("route.resource.iron") or tag.begins_with("route.resource.coal") \
				or tag.begins_with("route.resource.minerals") or tag.begins_with("route.energy.steam") \
				or tag.begins_with("route.energy.thermal") or tag.begins_with("route.trade.rail"):
			return "branch.heavy_industry"
		if tag.begins_with("route.resource.salt") or tag.begins_with("route.resource.sulfur") \
				or tag.begins_with("route.resource.phosphate"):
			return "branch.industrial_chemistry"
		if tag.begins_with("route.resource.oil") or tag.begins_with("route.energy.combustion"):
			return "branch.petroleum_materials"
		if tag.begins_with("route.geography.river") or tag.begins_with("route.energy.water") \
				or tag.begins_with("route.energy.wind"):
			return "branch.water_wind"
		if tag.begins_with("route.climate.drought"):
			return "branch.wheat_rainfed"
		if tag.begins_with("route.climate.cold") or tag.begins_with("route.geography.highland"):
			return "branch.tuber_highland"
		if tag.begins_with("route.climate.flood"):
			return "branch.water_wind"
		if tag.begins_with("route.energy.electric") or tag.begins_with("route.energy.nuclear"):
			return "branch.electric_intelligent_energy"
		if tag.begins_with("route.institution.storage"):
			return "backbone.food_storage"
		if tag.begins_with("route.craft.tools") or tag.begins_with("route.craft.precision") \
				or tag.begins_with("route.craft.machinery"):
			return "backbone.tools_machinery"
		if tag.begins_with("route.institution.observation") or tag.begins_with("route.institution.calendar") \
				or tag.begins_with("route.institution.oral") or tag.begins_with("route.institution.printing") \
				or tag.begins_with("route.institution.survey") or tag.begins_with("route.climate.modeling") \
				or tag.begins_with("route.institution.writing") or tag.begins_with("route.institution.academic") \
				or tag.begins_with("route.institution.experimental") or tag.begins_with("route.institution.computing") \
				or tag.begins_with("route.ai.learning"):
			return "backbone.knowledge_computation"
		if tag.begins_with("route.institution.") or tag.begins_with("route.ai.collaboration"):
			return "backbone.institutions_exchange"
		if tag.begins_with("route.material.materials"):
			return "branch.construction_materials"
		if tag.begins_with("route.geography.urban"):
			return "backbone.institutions_exchange"
		if tag.begins_with("route.ai.autonomy"):
			return "backbone.tools_machinery"
	var best_lane := ""
	var best_score := 0
	for lane in BRANCHES:
		var score := _score(definition, BRANCH_TERMS[lane])
		if score > best_score:
			best_score = score
			best_lane = lane
	if best_score >= 2:
		return best_lane
	for lane in BACKBONES:
		var score := _score(definition, BACKBONE_TERMS[lane])
		if score > best_score:
			best_score = score
			best_lane = lane
	if not best_lane.is_empty():
		return best_lane
	match String(definition.domain_id):
		"agriculture": return "backbone.food_storage"
		"engineering": return "backbone.tools_machinery"
		"science": return "backbone.knowledge_computation"
		_: return "backbone.institutions_exchange"


func _score(definition: Dictionary, terms: Array) -> int:
	var haystack := (String(definition.id) + " " + String(definition.effect_profile) + " " \
		+ String(definition.display_name) + " " + " ".join(definition.route_tags)).to_lower()
	var tokens := haystack.replace(".", "_").replace("-", "_").replace(" ", "_").split("_", false)
	var score := 0
	for term in terms:
		var needle := String(term)
		if (needle.length() <= 3 and tokens.has(needle)) \
				or (needle.length() > 3 and haystack.contains(needle)):
			score += 3
	return score


func _reveal_condition(source: Dictionary, lane: String, era_index: int,
		era_ids: PackedStringArray, era_milestones: Dictionary) -> Dictionary:
	if bool(source.is_milestone):
		return {}
	var evidence: Array = []
	for signal_id in _semantic_evidence_ids(source, lane, era_index):
		evidence.append(_signal(String(signal_id)))
	if era_index <= 0:
		return _any_of(evidence)
	var previous_milestone := String(era_milestones[era_ids[era_index - 1]])
	return _all_of([_tech(previous_milestone), _any_of(evidence)])


func _semantic_evidence_ids(source: Dictionary, lane: String, era_index: int) -> Array:
	var technology_id := String(source.id)
	if EXPLICIT_EVIDENCE_BY_TECH.has(technology_id):
		return (EXPLICIT_EVIDENCE_BY_TECH[technology_id] as Array).duplicate()
	var source_tokens := _source_tokens(source)
	for rule_value in SEMANTIC_EVIDENCE_RULES:
		var rule: Dictionary = rule_value
		if _matches_any_token(source_tokens, rule.tokens):
			return (rule.signals as Array).duplicate()
	var profile := String(source.effect_profile)
	if profile in ["research", "knowledge", "observation", "automation"]:
		return _knowledge_evidence(era_index)
	if profile in ["organization", "trade"]:
		return _institutional_evidence(era_index)
	if profile == "energy":
		return _energy_evidence(era_index)
	return _evidence_ids(lane, era_index)


func _evidence_ids(lane: String, era_index: int) -> Array:
	if not PHASED_EVIDENCE_BY_LANE.has(lane):
		return EVIDENCE_BY_LANE.get(lane, [])
	var phase := 0
	if era_index >= 9:
		phase = 4
	elif era_index >= 7:
		phase = 3
	elif era_index >= 6:
		phase = 2
	elif era_index >= 3:
		phase = 1
	return (PHASED_EVIDENCE_BY_LANE[lane] as Array)[phase]


func _knowledge_evidence(era_index: int) -> Array:
	if era_index >= 9:
		return ["breakthrough.digital_control", "breakthrough.automation", "resource.rare_earth"]
	if era_index >= 8:
		return ["breakthrough.electrification", "breakthrough.automation", "resource.rare_earth"]
	if era_index >= 7:
		return ["breakthrough.electrification", "breakthrough.motor_winding", "breakthrough.assembly_line"]
	if era_index >= 6:
		return ["breakthrough.steam_power", "breakthrough.industrial_organization", "breakthrough.print_calibration"]
	if era_index >= 3:
		return ["breakthrough.printing", "breakthrough.print_calibration", "breakthrough.maritime_operations"]
	return ["weather.monsoon", "weather.frost", "landform.river_valley"]


func _institutional_evidence(era_index: int) -> Array:
	if era_index >= 9:
		return ["breakthrough.digital_control", "breakthrough.automation", "breakthrough.energy_control"]
	if era_index >= 7:
		return ["breakthrough.electrification", "breakthrough.industrial_organization", "breakthrough.assembly_line"]
	if era_index >= 6:
		return ["breakthrough.industrial_organization", "breakthrough.assembly_line", "breakthrough.steam_power"]
	if era_index >= 3:
		return ["breakthrough.printing", "breakthrough.print_calibration", "breakthrough.maritime_operations"]
	return ["resource.fertile_soil", "landform.river_valley", "breakthrough.seed_saving"]


func _energy_evidence(era_index: int) -> Array:
	if era_index >= 9:
		return ["breakthrough.energy_control", "breakthrough.digital_control", "resource.rare_earth"]
	if era_index >= 7:
		return ["breakthrough.electrification", "breakthrough.motor_winding", "breakthrough.assembly_line"]
	if era_index >= 6:
		return ["breakthrough.steam_power", "breakthrough.steam_sealing", "breakthrough.assembly_line"]
	return ["landform.freshwater_access", "landform.stable_wind_corridor", "breakthrough.hydraulic_engineering"]


func _first_signal_atom(spec: Dictionary) -> Dictionary:
	if spec.is_empty():
		return {}
	if spec.has("kind") and int(spec.kind) in [ResearchPredicateScript.Kind.SIGNAL_PRESENT,
			ResearchPredicateScript.Kind.SIGNAL_COUNT]:
		return spec.duplicate(true)
	for child in spec.get("children", []):
		if child is Dictionary:
			var found := _first_signal_atom(child)
			if not found.is_empty():
				return found
	return {}


func _assign_hard_prerequisites(nodes: Array[Dictionary], era_ids: PackedStringArray,
		branch_anchors: Dictionary, backbone_anchors: Dictionary) -> void:
	var milestone_by_era := {}
	for node in nodes:
		if bool((node as Dictionary).is_milestone):
			milestone_by_era[String((node as Dictionary).era_id)] = String(
				(node as Dictionary).id)
	for era_index in range(era_ids.size()):
		var era_id := String(era_ids[era_index])
		for lane in BACKBONES + BRANCHES:
			var anchors := backbone_anchors if lane in BACKBONES else branch_anchors
			var anchor_id := String(anchors.get("%s|%s" % [era_id, lane], ""))
			var chain: Array[Dictionary] = []
			for node in nodes:
				if String(node.era_id) == era_id and String(node.main_lane) == lane \
						and not bool(node.is_milestone):
					chain.append(node)
			chain.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return int(a.layout_order) < int(b.layout_order))
			var previous_anchor := ""
			if era_index > 0:
				previous_anchor = String(anchors.get(
					"%s|%s" % [era_ids[era_index - 1], lane], ""))
			var previous := previous_anchor
			for node in chain:
				node.hard_prerequisite_ids = PackedStringArray()
				if String(node.id) == anchor_id:
					if era_index > 0:
						var prerequisites := PackedStringArray([
							String(milestone_by_era[era_ids[era_index - 1]])])
						# Specialist routes retain path dependence. Backbones remain
						# accessible after the era gate without forcing one old backbone.
						if lane in BRANCHES and not previous_anchor.is_empty():
							prerequisites.append(previous_anchor)
						node.hard_prerequisite_ids = prerequisites
					previous = String(node.id)
				else:
					if not bool(node.is_starting) and not previous.is_empty():
						node.hard_prerequisite_ids = PackedStringArray([previous])
					previous = String(node.id)


func _apply_authored_prerequisite_overrides(nodes: Array[Dictionary]) -> void:
	for node in nodes:
		if String((node as Dictionary).id) == "tech.communal_specialization":
			node.hard_prerequisite_ids = PackedStringArray(["tech.early_trade"])
			return


func _cost_points(source: Dictionary, era_id: String, era_milestones: Dictionary,
		definitions: Array, is_route_anchor: bool, is_backbone_anchor: bool) -> int:
	if bool(source.is_starting):
		return 0
	if bool(source.is_milestone):
		return int(source.cost_points)
	var milestone_id := String(era_milestones.get(era_id, ""))
	var milestone_cost := int(source.cost_points)
	for definition in definitions:
		if String((definition as Dictionary).id) == milestone_id:
			milestone_cost = int((definition as Dictionary).cost_points)
			break
	var factor := 0.78
	if is_route_anchor:
		factor = 0.68
	elif is_backbone_anchor:
		factor = 0.60
	return maxi(1, int(round(float(milestone_cost) * factor)))


func _application_targets(id: String, lane: String, era_index: int,
		era_ids: PackedStringArray, branch_anchors: Dictionary, backbone_anchors: Dictionary,
		next_anchor: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if next_anchor.has(id):
		out.append(String(next_anchor[id]))
	if lane in BRANCHES:
		var targets: Array = APPLICATION_LANE_TARGETS[lane]
		var cross_lane := String(targets[era_index % targets.size()])
		var cross_id := String(branch_anchors.get("%s|%s" % [era_ids[era_index], cross_lane], ""))
		if not cross_id.is_empty() and cross_id != id and not out.has(cross_id):
			out.append(cross_id)
		if era_index in [3, 7]:
			var lane_index := BRANCHES.find(lane)
			var backbone := String(BACKBONES[lane_index % BACKBONES.size()])
			var feedback_id := String(backbone_anchors.get("%s|%s" % [era_ids[era_index], backbone], ""))
			if not feedback_id.is_empty() and feedback_id != id and not out.has(feedback_id):
				out.append(feedback_id)
	return out


func _explicit_terms(source: Dictionary, lane: String, is_route_anchor: bool,
		is_backbone_anchor: bool, bindings: Array, economy: Dictionary,
		family_totals: Dictionary, broad_totals: Dictionary, broad_count: int) -> Array[Dictionary]:
	if bool(source.is_starting):
		return []
	var bound_building_stat := _bound_building_stat(bindings)
	if not bound_building_stat.is_empty():
		return [{
			"stat": bound_building_stat,
			"operation": 0,
			"value": 0.25 if is_route_anchor or is_backbone_anchor else 0.20,
		}]
	var technology_id := String(source.id)
	if EXPLICIT_BUILDING_EFFECT_BY_TECH.has(technology_id):
		var building_id := String(EXPLICIT_BUILDING_EFFECT_BY_TECH[technology_id])
		var building_ids: PackedStringArray = economy.get(
			"building_type_ids", PackedStringArray())
		if not building_ids.has(building_id):
			push_error("explicit building effect target missing: %s -> %s" % [
				technology_id, building_id])
			return []
		var explicit_terms: Array[Dictionary] = [{
			"stat": "country.output.building.%s_factor" % building_id,
			"operation": 0,
			"value": 0.25 if is_route_anchor or is_backbone_anchor else 0.20,
		}]
		if broad_count < BROAD_NODE_LIMIT:
			var explicit_broad := _broad_with_capacity(
				_semantic_broad_candidates(source, lane), broad_totals, 0.03)
			if not explicit_broad.is_empty():
				explicit_terms.append({
					"stat": explicit_broad, "operation": 0, "value": 0.03})
		return explicit_terms
	var value := 0.12 if is_route_anchor else (0.11 if is_backbone_anchor else 0.10)
	var candidates := _semantic_family_candidates(source, lane, bindings, economy)
	var family := _family_with_capacity(candidates, family_totals, value)
	if family.is_empty():
		# Generic institutional/research nodes may not have a meaningful
		# production family. Use a registered country consumer rather than
		# borrowing an unrelated family just to satisfy a count.
		if broad_count < BROAD_NODE_LIMIT:
			var fallback_stat := _broad_with_capacity(_semantic_broad_candidates(source, lane),
				broad_totals, 0.03)
			if not fallback_stat.is_empty():
				return [{"stat": fallback_stat, "operation": 0, "value": 0.03}]
		push_error("no semantic effect consumer with capacity: %s" % String(source.id))
		return []
	var terms: Array[Dictionary] = [{
		"stat": "country.output.family.%s_factor" % family,
		"operation": 0,
		"value": value,
	}]
	if (is_backbone_anchor or is_route_anchor) and broad_count < BROAD_ANCHOR_BONUS_LIMIT:
		var broad_stat := _broad_with_capacity(_semantic_broad_candidates(source, lane),
			broad_totals, 0.03)
		if not broad_stat.is_empty():
			terms.append({"stat": broad_stat, "operation": 0, "value": 0.03})
	return terms


func _bound_building_stat(bindings: Array) -> String:
	for binding_value in bindings:
		var binding: Dictionary = binding_value
		if int(binding.get("kind", 0)) == 2:
			return "country.output.building.%s_factor" % String(binding.get("id", ""))
	return ""


func _content_effects(bindings: Array, economy: Dictionary,
		display_names: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	var building_ids: PackedStringArray = economy.get("building_type_ids", PackedStringArray())
	var good_ids: PackedStringArray = economy.get("good_ids", PackedStringArray())
	var resource_ids: PackedStringArray = economy.get("building_resource_ids", PackedStringArray())
	var profession_ids: PackedStringArray = economy.get("profession_ids", PackedStringArray())
	var profession_classes: PackedStringArray = economy.get("profession_class_ids", PackedStringArray())
	var owner_professions: PackedInt32Array = economy.get("building_owner_profession_ids", PackedInt32Array())
	var employee_offsets: PackedInt32Array = economy.get("building_employee_offsets", PackedInt32Array())
	var employee_professions: PackedInt32Array = economy.get("building_employee_profession_ids", PackedInt32Array())
	var output_offsets: PackedInt32Array = economy.get("building_output_offsets", PackedInt32Array())
	var output_goods: PackedInt32Array = economy.get("building_output_good_ids", PackedInt32Array())
	var input_offsets: PackedInt32Array = economy.get("building_input_offsets", PackedInt32Array())
	var input_goods: PackedInt32Array = economy.get("building_input_good_ids", PackedInt32Array())
	var condition_offsets: PackedInt32Array = economy.get("building_condition_offsets", PackedInt32Array())
	var condition_opcodes: PackedInt32Array = economy.get("building_condition_opcodes", PackedInt32Array())
	var condition_signals: PackedInt32Array = economy.get("building_condition_signals", PackedInt32Array())
	var condition_references: PackedInt32Array = economy.get("building_condition_references", PackedInt32Array())
	var condition_values: PackedInt64Array = economy.get("building_condition_values", PackedInt64Array())
	for binding_value in bindings:
		var binding: Dictionary = binding_value
		var kind := int(binding.get("kind", 0))
		var id := String(binding.get("id", ""))
		match kind:
			1:
				_append_content_effect(out, seen, {
					"kind": "good", "id": id, "binding_kind": kind,
					"subject": "good.%s" % id, "attribute": "production_access",
					"operation": "unlock", "value": 1,
					"implementation": "GoodProfile.technology_tags",
					"status": "existing_binding",
				})
			2:
				var building_index := building_ids.find(id)
				_append_content_effect(out, seen, {
					"kind": "building", "id": id, "binding_kind": kind,
					"subject": "building.%s" % id,
					"attribute": "construction_and_production_access",
					"operation": "unlock", "value": 1,
					"implementation": "BuildingProfile.technology_tags",
					"status": "existing_binding",
				})
				if building_index >= 0:
					_append_building_context_effects(out, seen, building_index, good_ids,
						profession_ids, profession_classes, owner_professions, employee_offsets,
						employee_professions, output_offsets, output_goods, input_offsets,
						input_goods, condition_offsets, condition_opcodes, condition_signals, condition_references,
						condition_values, resource_ids)
			3:
				_append_content_effect(out, seen, {
					"kind": "resource", "id": id, "binding_kind": kind,
					"subject": "resource.%s" % id, "attribute": "local_resource_access",
					"operation": "unlock", "value": 1,
					"implementation": "ResourceProfile.discovery_technology_tags",
					"status": "existing_binding",
				})
	for effect in out:
		var kind := String((effect as Dictionary).get("kind", ""))
		var id := String((effect as Dictionary).get("id", ""))
		(effect as Dictionary)["display_name"] = String(display_names.get(
			"%s|%s" % [kind, id], id))
	return out


func _append_building_context_effects(out: Array[Dictionary], seen: Dictionary,
		building_index: int, good_ids: PackedStringArray, profession_ids: PackedStringArray,
		profession_classes: PackedStringArray, owner_professions: PackedInt32Array,
		employee_offsets: PackedInt32Array, employee_professions: PackedInt32Array,
		output_offsets: PackedInt32Array, output_goods: PackedInt32Array,
		input_offsets: PackedInt32Array, input_goods: PackedInt32Array,
		condition_offsets: PackedInt32Array, condition_opcodes: PackedInt32Array,
		condition_signals: PackedInt32Array,
		condition_references: PackedInt32Array, condition_values: PackedInt64Array,
		resource_ids: PackedStringArray) -> void:
	if building_index < owner_professions.size():
		_append_profession_class_effect(out, seen, int(owner_professions[building_index]),
			profession_ids, profession_classes, "ownership_access")
	if building_index + 1 < employee_offsets.size():
		for row in range(employee_offsets[building_index], employee_offsets[building_index + 1]):
			if row >= 0 and row < employee_professions.size():
				_append_profession_class_effect(out, seen, int(employee_professions[row]),
					profession_ids, profession_classes, "employment_access")
	if building_index + 1 < output_offsets.size():
		for row in range(output_offsets[building_index], output_offsets[building_index + 1]):
			if row >= 0 and row < output_goods.size():
				_append_good_recipe_effect(out, seen, int(output_goods[row]), good_ids,
					"output_recipe_access")
	if building_index + 1 < input_offsets.size():
		for row in range(input_offsets[building_index], input_offsets[building_index + 1]):
			if row >= 0 and row < input_goods.size():
				_append_good_recipe_effect(out, seen, int(input_goods[row]), good_ids,
					"input_method_access")
	if building_index + 1 < condition_offsets.size():
		for row in range(condition_offsets[building_index], condition_offsets[building_index + 1]):
			if row < 0 or row >= condition_signals.size() or row >= condition_opcodes.size() \
					or int(condition_opcodes[row]) != 1:
				continue
			var condition_signal := int(condition_signals[row])
			var reference := int(condition_references[row]) if row < condition_references.size() else -1
			var value := int(condition_values[row]) if row < condition_values.size() else -1
			if condition_signal == 0:
				_append_placement_effect(out, seen, "climate", "temperature")
			elif condition_signal == 1:
				_append_placement_effect(out, seen, "climate", "moisture")
			elif condition_signal == 2:
				_append_placement_effect(out, seen, "climate", "snow")
			elif condition_signal == 3:
				_append_placement_effect(out, seen, "climate", "weather")
			elif condition_signal == 4:
				_append_placement_effect(out, seen, "tile", "elevation")
			elif condition_signal == 5 and value >= 0 and value < TERRAIN_EFFECT_IDS.size():
				_append_placement_effect(out, seen, "terrain", TERRAIN_EFFECT_IDS[value])
			elif condition_signal == 6 and value >= 0 and value < LANDFORM_EFFECT_IDS.size():
				_append_placement_effect(out, seen, "landform", LANDFORM_EFFECT_IDS[value])
			elif condition_signal == 7:
				_append_placement_effect(out, seen, "terrain", "vegetation")
			elif condition_signal == 8:
				_append_placement_effect(out, seen, "tile", "water")
			elif condition_signal == 9:
				_append_placement_effect(out, seen, "tile", "river")
			elif condition_signal == 10 and reference >= 0 and reference < resource_ids.size():
				_append_placement_effect(out, seen, "resource", String(resource_ids[reference]))


func _append_profession_class_effect(out: Array[Dictionary], seen: Dictionary,
		profession_index: int, profession_ids: PackedStringArray,
		profession_classes: PackedStringArray, attribute: String) -> void:
	if profession_index < 0 or profession_index >= profession_ids.size():
		return
	var class_id := String(profession_classes[profession_index]) \
		if profession_index < profession_classes.size() else "general"
	_append_content_effect(out, seen, {
		"kind": "class", "id": class_id, "binding_kind": 0,
		"subject": "class.%s" % class_id, "attribute": attribute,
		"operation": "enable", "value": 1,
		"implementation": "BuildingProfile.owner_and_employee_slots",
		"status": "existing_binding",
	})


func _append_good_recipe_effect(out: Array[Dictionary], seen: Dictionary,
		good_index: int, good_ids: PackedStringArray, attribute: String) -> void:
	if good_index < 0 or good_index >= good_ids.size():
		return
	var good_id := String(good_ids[good_index])
	_append_content_effect(out, seen, {
		"kind": "good", "id": good_id, "binding_kind": 0,
		"subject": "good.%s" % good_id, "attribute": attribute,
		"operation": "enable", "value": 1,
		"implementation": "BuildingProfile.recipe",
		"status": "existing_binding",
	})


func _append_placement_effect(out: Array[Dictionary], seen: Dictionary,
		kind: String, id: String) -> void:
	_append_content_effect(out, seen, {
		"kind": kind, "id": id, "binding_kind": 0,
		"subject": "%s.%s" % [kind, id], "attribute": "specialized_building_placement",
		"operation": "enable", "value": 1,
		"implementation": "BuildingProfile.condition_postfix",
		"status": "existing_binding",
	})


func _append_content_effect(out: Array[Dictionary], seen: Dictionary,
		effect: Dictionary) -> void:
	var key := "%s|%s|%s" % [String(effect.get("kind", "")),
		String(effect.get("id", "")), String(effect.get("attribute", ""))]
	if seen.has(key):
		return
	seen[key] = true
	out.append(effect)


func _effect_summary(content_effects: Array[Dictionary], terms: Array[Dictionary]) -> String:
	var parts := PackedStringArray()
	for effect in content_effects:
		var item: Dictionary = effect
		var display_name := String(item.get("display_name", item.get("id", "")))
		match String(item.get("kind", "")):
			"building": parts.append("解锁建筑：%s" % display_name)
			"good":
				if String(item.get("attribute", "")) == "production_access":
					parts.append("解锁物资：%s" % display_name)
			"class": parts.append("开放%s岗位" % display_name)
			"terrain": parts.append("适用于%s地形" % display_name)
			"landform": parts.append("适用于%s地貌" % display_name)
			"tile": parts.append("需要%s地块条件" % display_name)
			"climate": parts.append("适应%s条件" % display_name)
			"resource": parts.append("可利用资源：%s" % display_name)
		if parts.size() >= 4:
			break
	for term in terms:
		var stat := String((term as Dictionary).get("stat", ""))
		var percent := int(round(float((term as Dictionary).get("value", 0.0)) * 100.0))
		if stat.begins_with("country.output.building."):
			parts.append("%s产出 +%d%%" % [String((term as Dictionary).get(
				"subject_display_name", "指定建筑")), percent])
		elif stat.begins_with("country.output.family."):
			parts.append("%s产出 +%d%%" % [String((term as Dictionary).get(
				"subject_display_name", "相关建筑工艺")), percent])
		elif not stat.is_empty():
			parts.append("国家协同能力 +%d%%" % percent)
	return "；".join(parts)


func _content_display_names() -> Dictionary:
	var out := {
		"class|general": "通用职业阶层",
		"class|farmer": "农民阶层",
		"class|worker": "劳动者阶层",
		"class|technology": "科技职业阶层",
		"tile|river": "河流",
		"tile|water": "水域",
		"tile|elevation": "高海拔",
		"climate|temperature": "温度",
		"climate|moisture": "水分",
		"climate|snow": "积雪",
		"climate|weather": "天气强度",
		"terrain|tundra": "苔原",
		"terrain|swamp": "沼泽",
		"terrain|moor": "泥炭湿原",
		"terrain|floodplain": "洪泛平原",
		"landform|mountain": "山地",
		"landform|plateau": "高原",
	}
	for source in [[GOOD_DIR, "good"], [BUILDING_DIR, "building"],
			[RESOURCE_DIR, "resource"]]:
		var directory := String(source[0])
		var kind := String(source[1])
		var paths := PackedStringArray()
		for file_name in ResourceLoader.list_directory(directory):
			if String(file_name).get_extension().to_lower() == "tres":
				paths.append("%s/%s" % [directory, file_name])
		paths.sort()
		for path in paths:
			var resource := ResourceLoader.load(path, "Resource")
			if resource == null:
				continue
			var id := String(resource.get("id"))
			var display_name := String(resource.get("display_name"))
			if not id.is_empty():
				out["%s|%s" % [kind, id]] = display_name if not display_name.is_empty() else id
	return out


func _decorate_modifier_terms(terms: Array[Dictionary],
		display_names: Dictionary) -> void:
	for term in terms:
		var stat := String((term as Dictionary).get("stat", ""))
		if stat.begins_with("country.output.family.") and stat.ends_with("_factor"):
			var family_id := stat.trim_prefix("country.output.family.").trim_suffix(
				"_factor")
			(term as Dictionary)["subject_kind"] = "building_family"
			(term as Dictionary)["subject_id"] = family_id
			(term as Dictionary)["subject_display_name"] = String(
				FAMILY_NAMES_ZH.get(family_id, family_id))
			continue
		if not stat.begins_with("country.output.building.") \
				or not stat.ends_with("_factor"):
			continue
		var building_id := stat.trim_prefix("country.output.building.").trim_suffix(
			"_factor")
		(term as Dictionary)["subject_kind"] = "building"
		(term as Dictionary)["subject_id"] = building_id
		(term as Dictionary)["subject_display_name"] = String(display_names.get(
			"building|%s" % building_id, building_id))


func _semantic_family_candidates(source: Dictionary, lane: String, bindings: Array,
		economy: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for family in _bound_family_candidates(bindings, economy):
		_append_family_candidate(out, String(family))
	var source_tokens := _source_tokens(source)
	for rule_value in SEMANTIC_FAMILY_RULES:
		var rule: Dictionary = rule_value
		if _matches_any_token(source_tokens, rule.tokens):
			for family in rule.families:
				_append_family_candidate(out, String(family))
	for family in _profile_family_candidates(source, lane):
		_append_family_candidate(out, String(family))
	return out


func _profile_family_candidates(source: Dictionary, lane: String) -> Array:
	var profile := String(source.effect_profile)
	match profile:
		"research", "knowledge", "observation", "automation":
			return ["research_institution", "paper_making", "metal_toolmaking"]
		"organization", "trade":
			return ["research_institution", "maritime_operations", "construction_methods"]
		"energy":
			return ["renewable_power_generation", "metal_toolmaking", "railway_equipment_making"]
		"hydraulic":
			return ["construction_methods", "field_crop_farming", "renewable_power_generation"]
		"chemistry", "health":
			return ["chemical_industry", "fertilizer_making", "salt_extraction"]
		"metallurgy", "tools", "manufacturing":
			return ["metal_toolmaking", "steelmaking", "railway_equipment_making"]
		"crop":
			return ["field_crop_farming", "staple_preparation", "bread_baking"]
		"livestock":
			return ["livestock_husbandry", "meat_processing", "dairy_processing"]
		"fishing":
			return ["freshwater_fishing", "fish_canning", "maritime_operations"]
		"construction":
			return ["construction_methods", "clay_extraction", "glassmaking"]
		"resource":
			return ["iron_extraction", "copper_extraction", "salt_extraction"]
		"craft", "foraging":
			return FAMILY_CANDIDATES[lane]
	return FAMILY_CANDIDATES[lane]


func _semantic_broad_candidates(source: Dictionary, lane: String) -> Array[String]:
	var out: Array[String] = []
	var profile := String(source.effect_profile)
	var domain := String(source.domain_id)
	if profile in ["research", "knowledge", "observation", "automation"]:
		_append_broad_candidate(out, "country.research.%s_efficiency" % domain)
		_append_broad_candidate(out, "country.output.knowledge_factor")
	elif profile == "trade":
		_append_broad_candidate(out, "country.trade.capacity_factor")
		_append_broad_candidate(out, "country.trade.speed_factor")
	elif profile in ["organization", "health"]:
		_append_broad_candidate(out, "country.research.society_efficiency")
		_append_broad_candidate(out, "country.trade.capacity_factor")
	elif profile in ["crop", "livestock", "fishing", "foraging"]:
		_append_broad_candidate(out, "country.output.agriculture_factor")
		_append_broad_candidate(out, "country.research.agriculture_efficiency")
	elif profile in ["energy", "hydraulic"]:
		_append_broad_candidate(out, "country.output.energy_factor")
		_append_broad_candidate(out, "country.research.engineering_efficiency")
	elif profile in ["metallurgy", "tools", "manufacturing", "construction", "craft", "resource", "chemistry"]:
		_append_broad_candidate(out, "country.output.manufacturing_factor")
		_append_broad_candidate(out, "country.output.extractive_factor")
		_append_broad_candidate(out, "country.research.engineering_efficiency")
	if out.is_empty():
		match domain:
			"agriculture":
				_append_broad_candidate(out, "country.research.agriculture_efficiency")
				_append_broad_candidate(out, "country.output.agriculture_factor")
			"engineering":
				_append_broad_candidate(out, "country.research.engineering_efficiency")
				_append_broad_candidate(out, "country.output.manufacturing_factor")
			"science":
				_append_broad_candidate(out, "country.research.science_efficiency")
				_append_broad_candidate(out, "country.output.knowledge_factor")
			"society":
				_append_broad_candidate(out, "country.research.society_efficiency")
				_append_broad_candidate(out, "country.trade.capacity_factor")
	return out


func _bound_family_candidates(bindings: Array, economy: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var building_ids: PackedStringArray = economy.get("building_type_ids", PackedStringArray())
	var family_ids: PackedStringArray = economy.get("building_upgrade_family_ids", PackedStringArray())
	var family_indices: PackedInt32Array = economy.get("building_upgrade_family_indices", PackedInt32Array())
	for binding in bindings:
		if int((binding as Dictionary).get("kind", 0)) != 2:
			continue
		var building_index := building_ids.find(String((binding as Dictionary).get("id", "")))
		if building_index < 0 or building_index >= family_indices.size():
			continue
		var family_index := int(family_indices[building_index])
		if family_index < 0 or family_index >= family_ids.size():
			continue
		var family := String(family_ids[family_index])
		if not family.is_empty() and not out.has(family):
			out.append(family)
	return out


func _family_with_capacity(candidates: Array, totals: Dictionary, value: float) -> String:
	for family in candidates:
		var total := float(totals.get(family, 0.0))
		if total + value <= 1.250001:
			var selected := String(family)
			totals[selected] = total + value
			return selected
	return ""


func _broad_with_capacity(candidates: Array, totals: Dictionary, value: float) -> String:
	for stat_value in candidates:
		var stat := String(stat_value)
		var total := float(totals.get(stat, 0.0))
		if total + value <= 0.500001:
			totals[stat] = total + value
			return stat
	return ""


func _source_tokens(source: Dictionary) -> PackedStringArray:
	var id := String(source.id).trim_prefix("tech.")
	var out := PackedStringArray()
	for token_value in id.split("_", false):
		var token := String(token_value).to_lower()
		if not token.is_empty() and not out.has(token):
			out.append(token)
	return out


func _matches_any_token(source_tokens: PackedStringArray, rule_tokens: Array) -> bool:
	for token_value in rule_tokens:
		var rule_token := String(token_value)
		for source_token_value in source_tokens:
			var source_token := String(source_token_value)
			if source_token == rule_token or source_token.begins_with(rule_token):
				return true
	return false


func _append_family_candidate(out: Array[String], family: String) -> void:
	if not family.is_empty() and not out.has(family):
		out.append(family)


func _append_broad_candidate(out: Array[String], stat: String) -> void:
	if not stat.is_empty() and not out.has(stat):
		out.append(stat)


func _terms_include_broad(terms: Array[Dictionary]) -> bool:
	for term_value in terms:
		var stat := String((term_value as Dictionary).get("stat", ""))
		if stat in BROAD_STATS or stat.begins_with("country.research.") \
				or stat.begins_with("country.trade."):
			return true
	return false


func _binding_records(catalog: Dictionary, economy: Dictionary) -> Dictionary:
	var out := {}
	var ids: PackedStringArray = catalog.technology_ids
	var offsets: PackedInt32Array = economy.technology_content_binding_offsets
	var kinds: PackedByteArray = economy.technology_content_binding_kinds
	var binding_ids: PackedStringArray = economy.technology_content_binding_ids
	for i in range(ids.size()):
		var records: Array[Dictionary] = []
		for edge in range(offsets[i], offsets[i + 1]):
			records.append({"kind": int(kinds[edge]), "id": String(binding_ids[edge])})
		out[String(ids[i])] = records
	return out


func _visual_edges(nodes: Array[Dictionary], era_ids: PackedStringArray,
		branch_anchors: Dictionary, id_to_index: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	for node in nodes:
		var to_id := String(node.id)
		for from_id in node.hard_prerequisite_ids:
			_add_edge(out, seen, String(from_id), to_id, "hard")
		var alternatives := PackedStringArray()
		_collect_technology_atoms(node.research_condition, alternatives)
		for from_id in alternatives:
			if not node.hard_prerequisite_ids.has(from_id):
				_add_edge(out, seen, String(from_id), to_id, "alternative")
		for target_id in node.application_target_ids:
			_add_edge(out, seen, to_id, String(target_id), "application")
	for era_id in era_ids:
		var milestone_id := ""
		for node in nodes:
			if String(node.era_id) == era_id and bool(node.is_milestone):
				milestone_id = String(node.id)
				break
		for lane in BRANCHES:
			var candidate_id := String(branch_anchors.get("%s|%s" % [era_id, lane], ""))
			_add_edge(out, seen, candidate_id, milestone_id, "milestone_candidate")
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ai := int(id_to_index.get(String(a.from), 1 << 30))
		var bi := int(id_to_index.get(String(b.from), 1 << 30))
		if ai != bi: return ai < bi
		var at := int(id_to_index.get(String(a.to), 1 << 30))
		var bt := int(id_to_index.get(String(b.to), 1 << 30))
		if at != bt: return at < bt
		return String(a.kind) < String(b.kind))
	return out


func _collect_technology_atoms(spec: Dictionary, out: PackedStringArray) -> void:
	if spec.is_empty():
		return
	if spec.has("kind"):
		if int(spec.kind) == ResearchPredicateScript.Kind.TECH_COMPLETED:
			var id := String(spec.get("id", ""))
			if not id.is_empty() and not out.has(id):
				out.append(id)
		return
	for child in spec.get("children", []):
		if child is Dictionary:
			_collect_technology_atoms(child, out)


func _add_edge(out: Array[Dictionary], seen: Dictionary, from_id: String,
		to_id: String, kind: String) -> void:
	if from_id.is_empty() or to_id.is_empty() or from_id == to_id:
		return
	var key := "%s|%s|%s" % [kind, from_id, to_id]
	if seen.has(key):
		return
	seen[key] = true
	out.append({"from": from_id, "to": to_id, "kind": kind})


func _plain_metadata(values: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for value in values:
		var source: Dictionary = value
		var row := {}
		for key in source:
			if source[key] is Color:
				row[key] = "#" + (source[key] as Color).to_html(false)
			else:
				row[key] = source[key]
		out.append(row)
	return out


func _lane_metadata(lanes: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in range(lanes.size()):
		out.append({"id": String(lanes[index]), "display_name": String(LANE_NAMES_ZH[lanes[index]]), "sort_order": index})
	return out


func _opportunity_cost(lane: String, era_index: int) -> String:
	if lane in BACKBONES:
		return "占用通用研究预算，延后同代专业路线锚点"
	return "转入该路线需补齐历史锚点；时代 %d 后的生产方式依赖专用资本、岗位或地理条件" % (era_index + 1)


func _tech(id: String) -> Dictionary:
	return {"kind": ResearchPredicateScript.Kind.TECH_COMPLETED, "id": id, "value": 1}


func _signal(id: String) -> Dictionary:
	return {"kind": ResearchPredicateScript.Kind.SIGNAL_PRESENT, "id": id, "value": 1}


func _all_of(children: Array) -> Dictionary:
	var filtered: Array = []
	for child in children:
		if child is Dictionary and not (child as Dictionary).is_empty():
			filtered.append(child)
	return {"operator": ResearchConditionScript.Operator.ALL_OF, "children": filtered}


func _any_of(children: Array) -> Dictionary:
	var filtered: Array = []
	for child in children:
		if child is Dictionary and not (child as Dictionary).is_empty():
			filtered.append(child)
	return {"operator": ResearchConditionScript.Operator.ANY_OF, "children": filtered}


func _validate_payload(payload: Dictionary) -> String:
	var nodes: Array = payload.nodes
	var edges: Array = payload.visual_edges
	if nodes.size() != 361:
		return "technology_network_node_count_invalid"
	if edges.size() > 1500:
		return "technology_network_visual_edge_limit_exceeded"
	var hard_edges := 0
	var modifier_terms := 0
	var era_lane_anchors := {}
	var family_totals := {}
	for node in nodes:
		var hard: Array = node.hard_prerequisite_ids
		if hard.size() > 2:
			return "technology_network_hard_indegree_exceeded: %s" % String(node.id)
		hard_edges += hard.size()
		modifier_terms += (node.modifier_terms as Array).size()
		if String(node.anchor_kind) == "route_anchor":
			era_lane_anchors["%s|%s" % [node.era_id, node.main_lane]] = true
		for term in node.modifier_terms:
			var stat := String(term.stat)
			if stat.begins_with("country.output.family."):
				family_totals[stat] = float(family_totals.get(stat, 0.0)) + float(term.value)
	if hard_edges > 500:
		return "technology_network_hard_edge_limit_exceeded"
	if modifier_terms < 360 or modifier_terms > 480:
		return "technology_network_modifier_term_count_invalid: %d" % modifier_terms
	if era_lane_anchors.size() != 176:
		return "technology_network_route_anchor_count_invalid: %d" % era_lane_anchors.size()
	for stat in family_totals:
		if float(family_totals[stat]) > 1.250001:
			return "technology_network_family_stack_exceeded: %s" % stat
	return ""
