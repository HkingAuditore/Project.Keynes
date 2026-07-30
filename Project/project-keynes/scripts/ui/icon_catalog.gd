class_name IconCatalog
extends RefCounted


const FAMILY_FONT_AWESOME := &"fontawesome"
const FAMILY_LUCIDE := &"lucide"
const FAMILY_TABLER := &"tabler"

const FONT_AWESOME: FontFile = preload("res://assets/fonts/fontawesome/fa-solid-900.woff2")

const GOOD_GLYPHS := {
	&"advanced_chips": "\uf2db", &"agricultural_machinery": "\ue58d",
	&"aluminum": "\uf45c", &"automobiles": "\uf5e4", &"autonomous_systems": "\uf544",
	&"batteries": "\uf240", &"bauxite": "\ue4e6", &"beverages": "\ue4c5",
	&"bread": "\uf7ec", &"bricks": "\ue58a", &"bronze_tools": "\uf7d9",
	&"canned_fish": "\ue4f2", &"cement": "\ue4cf", &"chipped_stone_tools": "\uf6e3",
	&"clay": "\ue52d", &"cloth": "\uf5c3", &"clothing": "\uf553",
	&"coal": "\uf46a", &"coke": "\uf7e4", &"computers": "\ue4e5",
	&"concrete": "\uf018", &"construction_components": "\uf482", &"copper": "\ue4e6",
	&"copper_ore": "\ue508", &"corn_grain": "\ue598", &"cotton_fiber": "\uf0c2",
	&"crude_oil": "\uf613", &"dairy_products": "\uf7ef", &"detergent": "\ue519",
	&"edible_oil": "\ue4c4", &"electric_motor": "\uf863", &"electrical_equipment": "\ue55b",
	&"electricity": "\ue0b7", &"electronic_components": "\uf538", &"engines": "\uf625",
	&"explosives": "\uf1e2", &"fertilizer": "\ue5aa", &"fine_clothing": "\uf508",
	&"fine_furniture": "\uf4b8", &"fish": "\ue448", &"flax_fiber": "\ue51e",
	&"flint": "\uf0d8", &"footwear": "\uf54b", &"fur": "\uf700",
	&"furniture": "\uf6c0", &"game_meat": "\uf6d7", &"gathered_plants": "\uf55f",
	&"glass": "\uf4e3", &"gold": "\uf53a", &"grain": "\ue2cd",
	&"horses": "\uf7ab", &"household_appliances": "\uf517",
	&"industrial_chemicals": "\ue4f3", &"industrial_machinery": "\uf275",
	&"insulated_cable": "\uf796", &"iron_ore": "\ue52f", &"jewelry": "\uf219",
	&"latex": "\uf5c7", &"lead": "\uf13d", &"lead_ore": "\uf496",
	&"leather": "\uf555", &"lime": "\uf094", &"limestone": "\uf5a6",
	&"livestock_products": "\uf6c8", &"logs": "\uf550", &"lubricants": "\ue532",
	&"lumber": "\uf0db", &"machine_parts": "\uf12e", &"manganese_ore": "\ue507",
	&"manuscripts": "\uf518", &"meat": "\uf7e5", &"medicinal_herbs": "\uf46b",
	&"natural_gas": "\uf52f", &"nuclear_fuel": "\uf7b9", &"oceanic_vessels": "\uf21a",
	&"packaging": "\uf49e", &"paper": "\uf70e", &"petrochemicals": "\uf493",
	&"pharmaceuticals": "\uf484", &"phosphate_rock": "\uf753", &"plastics": "\uf61f",
	&"potatoes": "\ue55a", &"pottery": "\ue516", &"precision_tools": "\uf568",
	&"prepared_staples": "\uf2e7", &"printed_materials": "\uf1ea",
	&"processed_food": "\ue4c6", &"radio_equipment": "\uf8d7",
	&"railway_equipment": "\uf238", &"rare_earth_metals": "\ue47b",
	&"rare_earth_ore": "\uf57e", &"raw_hide": "\ue569", &"raw_stone": "\uf1b3",
	&"reactor_components": "\uf7ba", &"refined_fuel": "\ue4f1", &"rice_grain": "\ue2eb",
	&"salt": "\uf2b9", &"saltpeter": "\uf492", &"scientific_instruments": "\uf610",
	&"semiconductors": "\uf2bb", &"silica_sand": "\uf252", &"silver": "\uf5a2",
	&"soap": "\ue06e", &"spices": "\uf816", &"stainless_steel": "\uf3ed",
	&"steam_engines": "\ue5b4", &"steel": "\uf56a", &"sulfur": "\uf780",
	&"synthetic_fiber": "\uf2a1", &"synthetic_rubber": "\uf5bf",
	&"technology_points": "\uf0c3", &"telecom_equipment": "\uf7c0",
	&"tin": "\uf466", &"tin_ore": "\uf6d1",
	&"tools": "\uf552", &"vegetables": "\uf787", &"wheat_grain": "\ue52a",
	&"wire": "\uf6ff", &"wool": "\uf696", &"zinc": "\uf0c1", &"zinc_ore": "\uf127",
}

# Exact material identifiers replace unrelated pictograms when the icon font
# has no honest representation of the substance.
const GOOD_LABELS := {
	&"aluminum": "Al", &"copper": "Cu", &"copper_ore": "Cu", &"gold": "Au",
	&"iron_ore": "Fe", &"lead": "Pb", &"lead_ore": "Pb", &"manganese_ore": "Mn",
	&"rare_earth_metals": "RE", &"rare_earth_ore": "RE", &"salt": "NaCl",
	&"saltpeter": "KNO3", &"semiconductors": "Si", &"silica_sand": "SiO2",
	&"silver": "Ag", &"sulfur": "S", &"tin": "Sn", &"tin_ore": "Sn",
	&"zinc": "Zn", &"zinc_ore": "Zn",
}

const PROFESSION_GLYPHS := {
	&"agricultural_worker": "\ue2cd", &"ai_researcher": "\uf544",
	&"apprentice": "\uf4fd", &"artisan": "\uf4fe",
	&"chemist": "\uf0f0", &"construction_worker": "\uf85e",
	&"data_scientist": "\ue473", &"electrician": "\ue55c",
	&"engineer": "\uf4fb", &"enslaved_laborer": "\ue543", &"fisher": "\uf578",
	&"forager": "\uf554", &"forestry_worker": "\ue54f", &"guild_master": "\uf505",
	&"hunter": "\ue54e", &"indentured_laborer": "\uf56c", &"industrialist": "\uf0b1",
	&"industrial_worker": "\uf807", &"journeyman": "\ue554", &"landlord": "\ue1b0",
	&"lorekeeper": "\uf66a", &"machinist": "\uf0ad", &"manager": "\uf4fc",
	&"merchant": "\uf54f", &"metallurgist": "\uf769", &"miner": "\ue52e",
	&"natural_philosopher": "\uf5d2", &"pastoralist": "\uf6ec",
	&"petroleum_worker": "\ue532", &"research_scientist": "\uf610",
	&"researcher": "\uf501", &"scholar": "\uf5da", &"scientist": "\ue4f3",
	&"scribe": "\uf5ad", &"serf": "\ue549",
	&"subsistence_farmer": "\uf291", &"technician": "\uf54a", &"tenant_farmer": "\ue065",
	&"transport_worker": "\uf48b", &"unemployed": "\uf506", &"worker": "\uf183",
}

# This is the only implementation registry. Callers retain distinct semantic
# keys even when several concepts intentionally share one visual today.
const SPECS := {
	&"action.add": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf067"},
	&"action.back": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf060"},
	&"action.chevron_down": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf078"},
	&"action.chevron_right": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf054"},
	&"action.close": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf00d"},
	&"action.confirm": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf00c"},
	&"action.fit": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf065"},
	&"action.history": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1da"},
	&"action.pause": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf04c"},
	&"action.play": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf04b"},
	&"action.refresh": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf2f1"},
	&"action.reset": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0e2"},
	&"action.save": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf00c"},
	&"climate.humidity": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf043"},
	&"climate.moon": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf186"},
	&"climate.snow": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf2dc"},
	&"climate.sun": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf185"},
	&"climate.temperature": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf2c9"},
	&"climate.weather": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0c2"},
	&"climate.wind": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf72e"},
	&"country.affairs": {"family": FAMILY_TABLER,
		"texture": preload("res://assets/icons/tabler/affairs.svg")},
	&"country.diplomacy": {"family": FAMILY_LUCIDE,
		"texture": preload("res://assets/icons/lucide/diplomacy.svg")},
	&"country.military": {"family": FAMILY_LUCIDE,
		"texture": preload("res://assets/icons/lucide/military.svg")},
	&"country.politics": {"family": FAMILY_LUCIDE,
		"texture": preload("res://assets/icons/lucide/politics.svg")},
	&"country.economy": {"family": FAMILY_TABLER,
		"texture": preload("res://assets/icons/tabler/treasury.svg")},
	&"country.technology": {"family": FAMILY_LUCIDE,
		"texture": preload("res://assets/icons/lucide/technology.svg")},
	&"country.world": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0ac"},
	&"economy.building": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1ad"},
	&"economy.building.factory": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf275"},
	&"economy.building.farm": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf722"},
	&"economy.building.fishing": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf578"},
	&"economy.building.food": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf2e7"},
	&"economy.building.forestry": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1bb"},
	&"economy.building.gathering": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf291"},
	&"economy.building.hearth": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf06d"},
	&"economy.building.hunting": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1b0"},
	&"economy.building.market": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf54e"},
	&"economy.building.mine": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc"},
	&"economy.building.power": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0e7"},
	&"economy.building.science": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0c3"},
	&"economy.building.service": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1ad"},
	&"economy.building.shipyard": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf21a"},
	&"economy.building.transport": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf238"},
	&"economy.building.workshop": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6e3"},
	&"economy.crop": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf722"},
	&"economy.fuel": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf043"},
	&"economy.livestock": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6f0"},
	&"economy.resource": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf3a5"},
	&"ecology.growth": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf4d8"},
	&"ecology.vegetation": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf06c"},
	&"geography.elevation": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc"},
	&"geography.surface": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf5fd"},
	&"geography.terrain": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc"},
	&"hydrology.current": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf773"},
	&"hydrology.water": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf773"},
	&"metric.goods": {"family": FAMILY_TABLER,
		"texture": preload("res://assets/icons/tabler/goods.svg")},
	&"metric.technology": {"family": FAMILY_TABLER,
		"texture": preload("res://assets/icons/tabler/technology.svg")},
	&"metric.territory": {"family": FAMILY_TABLER,
		"texture": preload("res://assets/icons/tabler/territory.svg")},
	&"metric.treasury": {"family": FAMILY_TABLER,
		"texture": preload("res://assets/icons/tabler/treasury.svg")},
	&"population.heart": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf004"},
	&"population.living.affluent": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf521"},
	&"population.living.comfortable": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf005"},
	&"population.living.destitute": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf071"},
	&"population.living.luxury": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf3a5"},
	&"population.living.poor": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf015"},
	&"population.living.secure": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf4d8"},
	&"population.living.struggling": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf554"},
	&"population.profession.artisan": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6e3"},
	&"population.profession.fisher": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf578"},
	&"population.profession.merchant": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf51e"},
	&"population.profession.owner": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf521"},
	&"population.profession.scholar": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf02d"},
	&"population.profession.unemployed": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf183"},
	&"population.profession.worker": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf807"},
	&"resource.animal": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1b0"},
	&"resource.arable_land": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf722"},
	&"resource.bauxite": {"family": FAMILY_FONT_AWESOME, "glyph": "\ue52d", "label": "Al"},
	&"resource.clay": {"family": FAMILY_FONT_AWESOME, "glyph": "\ue52d"},
	&"resource.coal": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf06d"},
	&"resource.copper": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc", "label": "Cu"},
	&"resource.earth": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1b2"},
	&"resource.fertile_soil": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf4d8"},
	&"resource.fire": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf06d"},
	&"resource.fish": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf578"},
	&"resource.flint": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0e7"},
	&"resource.freshwater_fish": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf773"},
	&"resource.gold": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf3a5", "label": "Au"},
	&"resource.iron": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc", "label": "Fe"},
	&"resource.lead": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc", "label": "Pb"},
	&"resource.limestone": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf5fd", "label": "CaCO3"},
	&"resource.manganese": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc", "label": "Mn"},
	&"resource.marine_fish": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf578"},
	&"resource.metal": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6e3"},
	&"resource.natural_gas": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf52f"},
	&"resource.oil": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf043"},
	&"resource.paddy_land": {"family": FAMILY_FONT_AWESOME, "glyph": "\ue2eb"},
	&"resource.pasture": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6f0"},
	&"resource.phosphate_rock": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc", "label": "P"},
	&"resource.plantation_land": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf06c"},
	&"resource.precious": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf3a5"},
	&"resource.rare_earth": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf5d2", "label": "RE"},
	&"resource.rock": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc"},
	&"resource.salt": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf5d2"},
	&"resource.salt_deposit": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1b3", "label": "NaCl"},
	&"resource.saltpeter": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0c3", "label": "KNO3"},
	&"resource.silica_sand": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf254", "label": "SiO2"},
	&"resource.silver": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf51e", "label": "Ag"},
	&"resource.sulfur": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0c3", "label": "S"},
	&"resource.tin": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc", "label": "Sn"},
	&"resource.wood": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1bb"},
	&"resource.zinc": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf6fc", "label": "Zn"},
	&"status.hidden": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf070"},
	&"status.warning": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf071"},
	&"summary.overview": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0ca"},
	&"system.calendar": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf133"},
	&"tax.business": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf19c"},
	&"tax.consumption": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf07a"},
	&"tax.default": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf541"},
	&"tax.export": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf5b0"},
	&"tax.import": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf5af"},
	&"tax.income": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf4c0"},
	&"tax.section": {"family": FAMILY_LUCIDE,
		"texture": preload("res://assets/icons/lucide/taxation.svg")},
	&"tax.tariff": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf24e"},
	&"system.clock": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf017"},
	&"system.seed": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf1ec"},
	&"system.settings": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf013"},
	&"system.target": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf05b"},
	&"system.unknown": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf128"},
	&"technology.domain.agriculture": {"family": FAMILY_FONT_AWESOME, "glyph": "\ue2cd"},
	&"technology.domain.engineering": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0ad"},
	&"technology.domain.science": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf610"},
	&"technology.domain.society": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf505"},
	&"technology.milestone": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf521"},
	&"technology.state.available": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0eb"},
	&"technology.state.completed": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf00c"},
	&"technology.state.locked": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf023"},
	&"technology.state.pending": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf017"},
	&"technology.state.queued": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf0ca"},
	&"technology.state.unknown": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf128"},
	&"trend.down": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf063"},
	&"trend.flat": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf061"},
	&"trend.up": {"family": FAMILY_FONT_AWESOME, "glyph": "\uf062"},
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

# Repeated implementation signatures must be explicitly acknowledged here.
const ALLOWED_SHARED_IMPLEMENTATIONS := {
	"fontawesome:glyph:f00c": [&"action.confirm", &"action.save",
		&"technology.state.completed"],
	"fontawesome:glyph:f013": [&"resource.tin", &"system.settings"],
	"fontawesome:glyph:f017": [&"system.clock", &"technology.state.pending"],
	"fontawesome:glyph:f043": [&"climate.humidity", &"economy.fuel", &"resource.oil"],
	"fontawesome:glyph:f04b": [&"action.play"],
	"fontawesome:glyph:f061": [&"trend.flat"],
	"fontawesome:glyph:f06c": [&"ecology.vegetation", &"resource.plantation_land"],
	"fontawesome:glyph:f06d": [&"economy.building.hearth", &"resource.coal", &"resource.fire"],
	"fontawesome:glyph:f071": [&"population.living.destitute", &"status.warning"],
	"fontawesome:glyph:f0c3": [&"economy.building.science", &"resource.saltpeter"],
	"fontawesome:glyph:f0ca": [&"summary.overview", &"technology.state.queued"],
	"fontawesome:glyph:f0e7": [&"economy.building.power", &"resource.flint"],
	"fontawesome:glyph:f1ad": [&"economy.building", &"economy.building.service"],
	"fontawesome:glyph:f1b0": [&"economy.building.hunting", &"resource.animal"],
	"fontawesome:glyph:f128": [&"system.unknown", &"technology.state.unknown"],
	"fontawesome:glyph:f1b2": [&"resource.clay", &"resource.earth"],
	"fontawesome:glyph:f1bb": [&"economy.building.forestry", &"resource.wood"],
	"fontawesome:glyph:f2e7": [&"economy.building.food", &"resource.paddy_land"],
	"fontawesome:glyph:f3a5": [&"economy.resource", &"population.living.luxury", &"resource.precious"],
	"fontawesome:glyph:f4d8": [&"ecology.growth", &"population.living.secure", &"resource.fertile_soil"],
	"fontawesome:glyph:f51e": [&"population.profession.merchant", &"resource.silver"],
	"fontawesome:glyph:f521": [&"population.living.affluent",
		&"population.profession.owner", &"technology.milestone"],
	"fontawesome:glyph:f578": [&"economy.building.fishing", &"population.profession.fisher", &"resource.fish", &"resource.marine_fish"],
	"fontawesome:glyph:f5d2": [&"resource.rare_earth", &"resource.salt"],
	"fontawesome:glyph:f5fd": [&"geography.surface", &"resource.limestone"],
	"fontawesome:glyph:f6e3": [&"economy.building.workshop", &"population.profession.artisan", &"resource.iron", &"resource.metal"],
	"fontawesome:glyph:f6f0": [&"economy.livestock", &"resource.pasture"],
	"fontawesome:glyph:f6fc": [&"economy.building.mine", &"geography.elevation", &"geography.terrain", &"resource.rock"],
	"fontawesome:glyph:f722": [&"economy.building.farm", &"economy.crop", &"resource.arable_land"],
	"fontawesome:glyph:f72e": [&"climate.wind", &"resource.natural_gas"],
	"fontawesome:glyph:f773": [&"hydrology.current", &"hydrology.water", &"resource.freshwater_fish"],
	"lucide:texture:technology.svg": [&"country.technology"],
	"tabler:texture:technology.svg": [&"metric.technology"],
	"tabler:texture:treasury.svg": [&"country.economy", &"metric.treasury"],
}


static func resolve_semantic(key: StringName) -> StringName:
	if key == &"" or String(key) == "\u2014":
		return &""
	if SPECS.has(key):
		return key
	var raw := String(key)
	if raw.begins_with("building.") and _building_product_id(raw) != &"":
		return key
	if raw.begins_with("good.") and GOOD_GLYPHS.has(StringName(raw.trim_prefix("good."))):
		return key
	if raw.begins_with("profession.") \
			and PROFESSION_GLYPHS.has(StringName(raw.trim_prefix("profession."))):
		return key
	return COMPATIBILITY_ALIASES.get(String(key), &"system.unknown") as StringName


static func resolve_key(key: String) -> String:
	return String(resolve_semantic(StringName(key)))


static func spec_for(key: StringName) -> Dictionary:
	var semantic := resolve_semantic(key)
	var raw := String(semantic)
	if raw.begins_with("building."):
		var product_id := _building_product_id(raw)
		var product_spec := spec_for(good_semantic(String(product_id)))
		var kind := raw.trim_prefix("building.").get_slice(".", 0)
		var spec := {
			"family": FAMILY_FONT_AWESOME,
			"glyph": _building_kind_glyph(kind),
			"overlay_glyph": String(product_spec.get("glyph", "")),
		}
		if product_spec.has("label"):
			spec["label"] = product_spec["label"]
		return spec
	if raw.begins_with("good."):
		var stable_id := StringName(raw.trim_prefix("good."))
		var spec := {"family": FAMILY_FONT_AWESOME,
			"glyph": GOOD_GLYPHS.get(stable_id, "")}
		if GOOD_LABELS.has(stable_id):
			spec["label"] = GOOD_LABELS[stable_id]
		return spec
	if raw.begins_with("profession."):
		return {"family": FAMILY_FONT_AWESOME,
			"glyph": PROFESSION_GLYPHS.get(StringName(raw.trim_prefix("profession.")), "")}
	return SPECS.get(semantic, SPECS[&"system.unknown"]) as Dictionary


static func glyph_for_key(key: StringName) -> String:
	return String(spec_for(key).get("glyph", SPECS[&"system.unknown"]["glyph"]))


static func texture_for_key(key: StringName) -> Texture2D:
	return spec_for(key).get("texture") as Texture2D


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
	for stable_id in GOOD_GLYPHS:
		keys.append(good_semantic(String(stable_id)))
	for stable_id in PROFESSION_GLYPHS:
		keys.append(profession_semantic(String(stable_id)))
	keys.sort()
	return keys


static func good_semantic(stable_id: String) -> StringName:
	return StringName("good.%s" % stable_id) if GOOD_GLYPHS.has(StringName(stable_id)) \
		else &"system.unknown"


static func profession_semantic(stable_id: String) -> StringName:
	return StringName("profession.%s" % stable_id) \
		if PROFESSION_GLYPHS.has(StringName(stable_id)) else &"system.unknown"


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
	return product_id if GOOD_GLYPHS.has(product_id) else &""


static func _building_kind_glyph(kind: String) -> String:
	match kind:
		"collector":
			return "\uf291" # basket-shopping
		"service":
			return "\uf1ad" # building
		_:
			return "\uf275" # industry


static func implementation_signature(key: StringName) -> String:
	var spec := spec_for(key)
	var family := String(spec.get("family", FAMILY_FONT_AWESOME))
	var label := String(spec.get("label", ""))
	var overlay_glyph := String(spec.get("overlay_glyph", ""))
	if not label.is_empty():
		var glyph := String(spec.get("glyph", ""))
		return "%s:label:%s:glyph:%x" % [family, label,
			glyph.unicode_at(0) if not glyph.is_empty() else 0]
	if not overlay_glyph.is_empty():
		var base_glyph := String(spec.get("glyph", ""))
		return "%s:glyph:%x:overlay:%x" % [family,
			base_glyph.unicode_at(0) if not base_glyph.is_empty() else 0,
			overlay_glyph.unicode_at(0)]
	if spec.has("texture"):
		return "%s:texture:%s" % [family, (spec.texture as Texture2D).resource_path.get_file()]
	var glyph := String(spec.get("glyph", ""))
	return "%s:glyph:%x" % [family, glyph.unicode_at(0) if not glyph.is_empty() else 0]


static func usage_audit() -> Dictionary:
	var usage := {}
	for semantic in registered_keys():
		var signature := implementation_signature(semantic)
		if not usage.has(signature):
			usage[signature] = []
		(usage[signature] as Array).append(semantic)
	return usage
