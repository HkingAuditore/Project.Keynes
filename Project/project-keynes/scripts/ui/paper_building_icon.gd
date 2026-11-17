extends RefCounted

const BUILDING_BASE_OVERRIDES := {
	&"fish_farm": &"economy.building.fishing",
	&"cold_storage": &"economy.building.transport",
	&"logistics_hub": &"economy.building.transport",
	&"public_health_center": &"economy.building.service",
}

static func _paper_building_base(kind: String, product_id: StringName,
		stable_id: StringName = &"") -> StringName:
	var override_key: StringName = BUILDING_BASE_OVERRIDES.get(stable_id, &"")
	if not override_key.is_empty():
		return override_key
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
