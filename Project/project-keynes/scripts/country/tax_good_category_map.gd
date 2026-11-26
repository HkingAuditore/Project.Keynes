extends RefCounted

## 商品税的「按商品大类」映射表：将 125 个底层配方替代类别（good_category_ids）
## 归并为 16 个语义清晰的中文商品大类，供交易税 / 关税分组使用。
## 其中食物相关商品拆分为主粮与蔬果、肉类与水产、加工食品与乳品、饮品与调味 4 类。

const GROUP_LABELS := {
	"staple_food": "主粮与蔬果",
	"meat_seafood": "肉类与水产",
	"processed_food": "加工食品与乳品",
	"beverages_spices": "饮品与调味",
	"textile_apparel": "纺织与服饰",
	"daily_goods": "日用与医疗",
	"timber_paper": "木材与造纸文化",
	"construction": "建材与石料",
	"ores_metals": "矿产与金属",
	"energy_fuel": "能源与燃料",
	"chemicals_materials": "化工与材料",
	"tools_machinery": "工具与机械",
	"transport_equipment": "交通与载具",
	"electronics_instruments": "电子与仪器",
	"weapons_armor": "轻武器与护甲",
	"heavy_ordnance": "重装与军工",
}

const CATEGORY_TO_GROUP := {
	# 主粮与蔬果
	"starchy_staple": "staple_food",
	"vegetables": "staple_food",
	"gathered_plants": "staple_food",
	# 肉类与水产
	"meat": "meat_seafood",
	"game_meat": "meat_seafood",
	"fish": "meat_seafood",
	"canned_fish": "meat_seafood",
	"livestock_products": "meat_seafood",
	"horses": "meat_seafood",
	# 加工食品与乳品
	"bread": "processed_food",
	"prepared_staples": "processed_food",
	"processed_food": "processed_food",
	"dairy_products": "processed_food",
	"edible_oil": "processed_food",
	# 饮品与调味
	"beverages": "beverages_spices",
	"salt": "beverages_spices",
	"spices": "beverages_spices",
	# 纺织与服饰
	"raw_fiber_crop": "textile_apparel",
	"spinnable_fiber": "textile_apparel",
	"rag_paper_fiber": "textile_apparel",
	"clothing": "textile_apparel",
	"fine_clothing": "textile_apparel",
	"footwear": "textile_apparel",
	"fur": "textile_apparel",
	"raw_hide": "textile_apparel",
	"leather": "textile_apparel",
	"leather_goods": "textile_apparel",
	"dyestuff": "textile_apparel",
	# 日用与医疗
	"furniture": "daily_goods",
	"fine_furniture": "daily_goods",
	"pottery": "daily_goods",
	"glassware": "daily_goods",
	"metal_housewares": "daily_goods",
	"soap": "daily_goods",
	"detergent": "daily_goods",
	"household_appliances": "daily_goods",
	"jewelry": "daily_goods",
	"medicinal_herbs": "daily_goods",
	"pharmaceuticals": "daily_goods",
	"packaging": "daily_goods",
	# 木材与造纸文化
	"logs": "timber_paper",
	"lumber": "timber_paper",
	"paper": "timber_paper",
	"manuscripts": "timber_paper",
	"printed_materials": "timber_paper",
	"knowledge": "timber_paper",
	# 建材与石料
	"primitive_construction": "construction",
	"clay": "construction",
	"bricks": "construction",
	"raw_stone": "construction",
	"limestone": "construction",
	"lime": "construction",
	"silica_sand": "construction",
	"glass": "construction",
	"cement": "construction",
	"concrete": "construction",
	"construction_components": "construction",
	# 矿产与金属
	"flint": "ores_metals",
	"iron_ore": "ores_metals",
	"copper_ore": "ores_metals",
	"tin_ore": "ores_metals",
	"lead_ore": "ores_metals",
	"zinc_ore": "ores_metals",
	"manganese_ore": "ores_metals",
	"bauxite": "ores_metals",
	"rare_earth_ore": "ores_metals",
	"phosphate_rock": "ores_metals",
	"ferrous_stock": "ores_metals",
	"copper": "ores_metals",
	"tin": "ores_metals",
	"lead": "ores_metals",
	"zinc": "ores_metals",
	"structural_metal": "ores_metals",
	"rare_earth_metals": "ores_metals",
	"precious_metal": "ores_metals",
	# 能源与燃料
	"solid_fuel": "energy_fuel",
	"coal": "energy_fuel",
	"coke": "energy_fuel",
	"crude_oil": "energy_fuel",
	"natural_gas": "energy_fuel",
	"refined_fuel": "energy_fuel",
	"electricity": "energy_fuel",
	"nuclear_fuel": "energy_fuel",
	"batteries": "energy_fuel",
	# 化工与材料
	"brine": "chemicals_materials",
	"sulfur": "chemicals_materials",
	"saltpeter": "chemicals_materials",
	"industrial_chemicals": "chemicals_materials",
	"fertilizer": "chemicals_materials",
	"petrochemicals": "chemicals_materials",
	"plastics": "chemicals_materials",
	"lubricants": "chemicals_materials",
	"raw_latex_feedstock": "chemicals_materials",
	"elastomer": "chemicals_materials",
	# 工具与机械
	"tools": "tools_machinery",
	"machine_parts": "tools_machinery",
	"prime_mover": "tools_machinery",
	"agricultural_machinery": "tools_machinery",
	"industrial_machinery": "tools_machinery",
	"reactor_components": "tools_machinery",
	# 交通与载具
	"automobiles": "transport_equipment",
	"railway_equipment": "transport_equipment",
	"oceanic_vessels": "transport_equipment",
	# 电子与仪器
	"wire": "electronics_instruments",
	"insulated_cable": "electronics_instruments",
	"electrical_equipment": "electronics_instruments",
	"electronic_components": "electronics_instruments",
	"processor_component": "electronics_instruments",
	"computers": "electronics_instruments",
	"radio_equipment": "electronics_instruments",
	"telecom_equipment": "electronics_instruments",
	"scientific_instruments": "electronics_instruments",
	"autonomous_systems": "electronics_instruments",
	# 轻武器与护甲
	"melee_arms": "weapons_armor",
	"missile_arms": "weapons_armor",
	"firearms": "weapons_armor",
	"body_armor": "weapons_armor",
	"ammunition": "weapons_armor",
	"propellant": "weapons_armor",
	"explosives": "weapons_armor",
	# 重装与军工
	"ordnance": "heavy_ordnance",
	"mounts": "heavy_ordnance",
	"armored_vehicles": "heavy_ordnance",
	"drones": "heavy_ordnance",
	"military_electronics": "heavy_ordnance",
}


static func group_for_category(category_id: String) -> String:
	return String(CATEGORY_TO_GROUP.get(category_id, ""))


static func label_for_group(group_id: String) -> String:
	return String(GROUP_LABELS.get(group_id, group_id))
