extends RefCounted

## Checks the compiled military catalog against required native capabilities.

const CatalogSchema = preload("res://scripts/military/military_catalog_schema.gd")


static func validate_compiled(compiled: Dictionary) -> Dictionary:
	if not bool(compiled.get("ok", false)):
		return compiled
	var problems: Array[String] = []
	if int(compiled.get("militia_unit_index", -1)) < 0:
		problems.append("catalog must declare exactly one militia unit")
	var supply_goods: Array = compiled.get("supply_goods", [])
	if supply_goods.size() != CatalogSchema.SUPPLY_CLASS_COUNT:
		problems.append("supply_goods must hold %d rows" % CatalogSchema.SUPPLY_CLASS_COUNT)
	else:
		var ration: PackedInt32Array = supply_goods[CatalogSchema.SUPPLY_RATION]
		if ration.is_empty():
			problems.append("ration candidates are empty")
	var units: Array = compiled.get("units", [])
	if units.size() > CatalogSchema.MAX_UNITS:
		problems.append("unit count %d exceeds %d" % [units.size(), CatalogSchema.MAX_UNITS])
	# A supply class with unit demand but no candidate goods can never settle:
	# procurement (`military_core_logistics.cpp:1064`) and consumption (`:1787`)
	# both short-circuit on the empty row, while `use.need` still counts it.
	# Only `equipment` is allowed to stay empty (it uses the slot path).
	for supply_class in [CatalogSchema.SUPPLY_FODDER, CatalogSchema.SUPPLY_AMMUNITION, CatalogSchema.SUPPLY_FUEL, CatalogSchema.SUPPLY_UPKEEP]:
		if supply_class >= supply_goods.size():
			continue
		var row: PackedInt32Array = supply_goods[supply_class]
		if not row.is_empty():
			continue
		var demanded := false
		for unit_value in units:
			var unit_row: Dictionary = unit_value
			var idle: PackedFloat32Array = unit_row.get("supply_idle",
				PackedFloat32Array())
			var combat: PackedFloat32Array = unit_row.get("supply_combat",
				PackedFloat32Array())
			if supply_class < idle.size() and float(idle[supply_class]) > 0.0:
				demanded = true
			if supply_class < combat.size() and float(combat[supply_class]) > 0.0:
				demanded = true
			if demanded:
				break
		if demanded:
			problems.append("supply class %s has demand but no candidate goods"
				% CatalogSchema.SUPPLY_CLASS_IDS[supply_class])
	var barracks := 0
	for building in compiled.get("state_buildings", []):
		if int((building as Dictionary).get("role", -1)) == CatalogSchema.ROLE_BARRACKS:
			barracks += 1
	if barracks == 0:
		problems.append("no barracks state building declared")
	# Water crossing (contract 2 §2.2): all four tiers must resolve, or that kind
	# of water can never open and an army ordered across it would silently do
	# nothing.
	for gate in ["water_lake_bit", "water_shallow_bit", "water_far_bit", "water_deep_bit"]:
		if int(compiled.get(gate, -1)) < 0:
			problems.append("unlock_tech_ids must name the four water-tier technologies (%s unresolved)" % gate)
	if problems.is_empty():
		return compiled
	var failed := compiled.duplicate()
	failed["ok"] = false
	failed["reason"] = "military_catalog_invalid"
	failed["problems"] = problems
	return failed
