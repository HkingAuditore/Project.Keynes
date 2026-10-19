extends SceneTree

## Phase 1 acceptance probe for the ideology rework.
##
## Deliberately avoids EconomyFacade / IdeologyFacade / WorkspaceScene: those
## reach into DCWorldExt, and the native library is not built in every checkout.
## Everything asserted here is pure GDScript content compilation, so the probe
## stays runnable with:
##   godot --headless --path <project> --script res://tests/ideology_phase1_probe.gd

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(economy_ir.get("ok", false)))
	if not bool(economy_ir.get("ok", false)):
		_report()
		return
	var catalog: Resource = IdeologyCatalogScript.load_default()
	_expect("default ideology catalog loads", catalog != null)
	if catalog == null:
		_report()
		return
	var ir: Dictionary = catalog.compile_native_catalog(economy_ir, economy_ir)
	_expect("default ideology catalog compiles", bool(ir.get("ok", false)))
	if not bool(ir.get("ok", false)):
		print("  compile reason: %s" % str(ir.get("reason", "")))
		_report()
		return

	_check_era_decay(ir)
	_check_era_milestones(ir)
	_check_card_era_indices(ir)
	_check_era_distribution(ir)
	_check_era_gates(ir, catalog)
	_check_affinity_tables(ir)
	_check_modifier_catalog()
	_check_display_formatter(economy_ir)
	_report()


func _check_era_decay(ir: Dictionary) -> void:
	var decay: PackedInt32Array = ir.get("era_decay_bp", PackedInt32Array())
	_expect("era decay curve is exported to the native catalog", decay.size() >= 4)
	_expect("era decay starts at full weight",
		decay.size() >= 1 and int(decay[0]) == 10000)
	var monotonic := true
	for index in range(1, decay.size()):
		monotonic = monotonic and int(decay[index]) <= int(decay[index - 1])
	_expect("era decay never increases", monotonic)
	_expect("era decay reaches zero so stale cards leave the pool",
		decay.size() >= 4 and int(decay[3]) == 0)
	_expect("era decay covers the promised one-to-two-era grace window",
		decay.size() == 4 and int(decay[1]) > 0 and int(decay[2]) > 0)


func _check_era_milestones(ir: Dictionary) -> void:
	var milestones: PackedInt32Array = ir.get(
		"ideology_era_milestone_technologies", PackedInt32Array())
	var era_rows: Array = IdeologyCatalogScript.era_rows()
	_expect("every era contributes a milestone technology",
		milestones.size() == era_rows.size() and milestones.size() == 11)
	var all_resolved := milestones.size() > 0
	for value in milestones:
		all_resolved = all_resolved and int(value) >= 0
	_expect("every era milestone resolves to a dense technology index", all_resolved)
	var distinct := {}
	for value in milestones:
		distinct[int(value)] = true
	_expect("era milestones are distinct technologies",
		distinct.size() == milestones.size())
	_expect("era 0 has no entry gate",
		IdeologyCatalogScript.era_entry_technology_key(0).is_empty())
	_expect("era 4 is gated by era 3's milestone",
		IdeologyCatalogScript.era_entry_technology_key(4)
			== "tech.imperial_integration")
	_expect("era names resolve to Chinese",
		IdeologyCatalogScript.era_display_name(0) == "石器时代"
			and IdeologyCatalogScript.era_display_name(10) == "智能时代")


func _check_card_era_indices(ir: Dictionary) -> void:
	var ids: PackedStringArray = ir.get("ideology_ids", PackedStringArray())
	var era_indices: PackedInt32Array = ir.get("ideology_era_indices", PackedInt32Array())
	_expect("every card carries an era index", era_indices.size() == ids.size())
	var in_range := era_indices.size() > 0
	for value in era_indices:
		in_range = in_range and int(value) >= 0 and int(value) <= 10
	_expect("card era indices stay inside the era table", in_range)


func _check_era_distribution(ir: Dictionary) -> void:
	var era_indices: PackedInt32Array = ir.get("ideology_era_indices", PackedInt32Array())
	var per_era := {}
	for value in era_indices:
		per_era[int(value)] = int(per_era.get(int(value), 0)) + 1
	var summary := ""
	for era in range(11):
		summary += "%d:%d " % [era, int(per_era.get(era, 0))]
	_expect("expanded pool holds at least 60 cards (%d)" % era_indices.size(),
		era_indices.size() >= 60)
	_expect("every era has a drawable starter set (%s)" % summary.strip_edges(),
		int(per_era.get(0, 0)) >= 6 and int(per_era.get(1, 0)) >= 6
			and int(per_era.get(2, 0)) >= 6)
	_expect("late eras are not left empty",
		int(per_era.get(9, 0)) >= 2 and int(per_era.get(10, 0)) >= 2)
	var distinct := {}
	for value in era_indices:
		distinct[int(value)] = true
	_expect("pool spans at least nine eras", distinct.size() >= 9)


func _check_modifier_catalog() -> void:
	var catalog: Resource = ModifierCatalogScript.load_default()
	_expect("default modifier catalog loads", catalog != null)
	if catalog == null:
		return
	var compiled: Dictionary = catalog.compile_native_catalog()
	_expect("modifier catalog compiles (all authored stat keys resolve): %s"
			% str(compiled.get("reason", "")), bool(compiled.get("ok", false)))
	var keys: PackedStringArray = compiled.get("stat_keys", PackedStringArray())
	_expect("stat catalog still exposes thousands of keys (%d)" % keys.size(),
		keys.size() > 2000)
	# Cards that target a specific building/good/profession/terrain would be the
	# first casualty of an id typo, so assert those families actually appear.
	var families := {
		"building": 0, "good": 0, "terrain": 0, "landform": 0, "tax_income": 0,
	}
	for key in keys:
		var text := String(key)
		if text.begins_with("country.output.building."):
			families["building"] = int(families["building"]) + 1
		elif text.begins_with("country.output.good."):
			families["good"] = int(families["good"]) + 1
		elif text.begins_with("country.output.terrain."):
			families["terrain"] = int(families["terrain"]) + 1
		elif text.begins_with("country.output.landform."):
			families["landform"] = int(families["landform"]) + 1
		elif text.begins_with("country.tax.income."):
			families["tax_income"] = int(families["tax_income"]) + 1
	_expect("selector stat families are compiled: %s" % str(families),
		int(families["building"]) > 0 and int(families["good"]) > 0
			and int(families["terrain"]) > 0 and int(families["landform"]) > 0
			and int(families["tax_income"]) > 0)


func _check_era_gates(ir: Dictionary, catalog: Resource) -> void:
	# The hard era floor is expressed through the existing TECHNOLOGY draw
	# requirement, so it must show up as a compiled technology requirement on
	# every card above era 0.
	var offsets: PackedInt32Array = ir.get(
		"technology_requirement_offsets", PackedInt32Array())
	var requirements: PackedInt32Array = ir.get(
		"technology_requirements", PackedInt32Array())
	var era_indices: PackedInt32Array = ir.get("ideology_era_indices", PackedInt32Array())
	var milestones: PackedInt32Array = ir.get(
		"ideology_era_milestone_technologies", PackedInt32Array())
	_expect("technology requirement CSR covers every card",
		offsets.size() == era_indices.size() + 1)
	# Era milestone i is the technology that puts the player into era i, so a card
	# of era i must require milestone[i] for every i >= 1.
	var technology_ids: PackedStringArray = ir.get("technology_ids", PackedStringArray())
	var ungated := 0
	var mis_gated := 0
	var ids: PackedStringArray = ir.get("ideology_ids", PackedStringArray())
	for index in era_indices.size():
		var era := int(era_indices[index])
		var block := PackedInt32Array()
		for cursor in range(int(offsets[index]), int(offsets[index + 1])):
			block.append(int(requirements[cursor]))
		if era == 0:
			continue
		var expected := int(milestones[era])
		if block.is_empty():
			ungated += 1
			print("  ungated: %s (era %d)" % [String(ids[index]), era])
		elif not block.has(expected):
			mis_gated += 1
			print("  mis-gated: %s (era %d, wants %s)" % [
				String(ids[index]), era, String(technology_ids[expected])])
	_expect("every card above era 0 carries its era milestone gate", ungated == 0)
	_expect("no card carries a weaker era gate", mis_gated == 0)
	_expect("era 0 cards stay ungated so the game can start",
		_card_requirement_count(offsets, era_indices, 0) == 0)
	var all_requirements_resolve := true
	for value in requirements:
		all_requirements_resolve = all_requirements_resolve and int(value) >= 0
	_expect("every draw requirement resolves to a dense technology index",
		all_requirements_resolve)
	_expect("ideology catalog resource is the expanded one",
		catalog != null and (catalog.get("definitions") as Array).size() == era_indices.size())


func _card_requirement_count(offsets: PackedInt32Array, era_indices: PackedInt32Array,
		era: int) -> int:
	var total := 0
	for index in era_indices.size():
		if int(era_indices[index]) != era:
			continue
		total += int(offsets[index + 1]) - int(offsets[index])
	return total


func _check_affinity_tables(ir: Dictionary) -> void:
	var ids: PackedStringArray = ir.get("ideology_ids", PackedStringArray())
	var offsets: PackedInt32Array = ir.get("ideology_affinity_offsets", PackedInt32Array())
	var gate_ids: PackedInt32Array = ir.get(
		"ideology_affinity_gate_ids", PackedInt32Array())
	var multipliers: PackedInt32Array = ir.get(
		"ideology_affinity_multipliers_bp", PackedInt32Array())
	_expect("affinity CSR offsets cover every card",
		offsets.size() == ids.size() + 1)
	_expect("affinity gate and multiplier rows agree",
		gate_ids.size() == multipliers.size())
	_expect("affinity CSR is well formed",
		offsets.size() > 0 and int(offsets[offsets.size() - 1]) == gate_ids.size())
	# Phase 1 ships the plumbing with no authored affinities, so the default
	# catalog must still draw exactly the same pool as before.
	_expect("phase 1 authors no affinities yet", gate_ids.is_empty())


func _check_display_formatter(economy_ir: Dictionary) -> void:
	var building_id := "iron_tool_workshop"
	if not (economy_ir.get("building_type_ids", PackedStringArray()) as PackedStringArray).has(building_id):
		building_id = String((economy_ir.get("building_type_ids", PackedStringArray()) as PackedStringArray)[0])
	ModifierCatalogScript.reset_display_names()
	ModifierCatalogScript.register_display_names(&"building", {building_id: "铁制工具作坊"})
	ModifierCatalogScript.register_display_names(&"good", {"iron_ore": "铁矿石"})
	ModifierCatalogScript.register_display_names(&"profession", {"miner": "矿工"})
	var cases := [
		["country.output.building.%s_factor" % building_id, 2, 1.25,
			"铁制工具作坊 产出 +25%"],
		["country.output.good.iron_ore_factor", 0, 0.30, "铁矿石 全国产出 +30%"],
		["country.input.good.iron_ore_factor", 1, 0.15, "铁矿石 全国投入 -15%"],
		["country.consumption.good.iron_ore_factor", 2, 0.80, "铁矿石 全国消费 -20%"],
		["economy.city.building.%s.output_factor" % building_id, 2, 1.15,
			"铁制工具作坊 城市产出 +15%"],
		["country.tax.income.miner.rate_bp", 0, 150, "矿工 所得税率 +1.50%"],
		["country.output.agriculture_factor", 2, 1.10, "农业部门产出 +10%"],
	]
	for entry in cases:
		var line := ModifierCatalogScript.present_stat_delta(
			String(entry[0]), int(entry[1]), float(entry[2]))
		_expect("renders '%s' -> '%s'" % [String(entry[3]), line],
			line == String(entry[3]))
	# Geography dimensions resolve through TerrainType/LandformType, so assert on
	# the shape instead of pinning names that live in the profile registry.
	var terrain_line := ModifierCatalogScript.present_stat_delta(
		"country.output.terrain.hill.agriculture_factor", 2, 1.10)
	_expect("terrain dimension resolves to Chinese (%s)" % terrain_line,
		terrain_line.ends_with("·农业 产出 +10%") and not terrain_line.contains("hill"))
	var landform_line := ModifierCatalogScript.present_stat_delta(
		"country.output.landform.plateau.manufacturing_factor", 2, 1.20)
	_expect("landform dimension resolves to Chinese (%s)" % landform_line,
		landform_line.ends_with("·制造 产出 +20%")
			and not landform_line.contains("plateau"))
	# Unregistered dimensions degrade to the raw stable id instead of vanishing.
	var raw := ModifierCatalogScript.present_stat_delta(
		"country.output.building.mystery_works_factor", 2, 1.05)
	_expect("unregistered dimension still renders", raw == "mystery_works 产出 +5%")
	_expect("unknown stat keys stay hidden",
		ModifierCatalogScript.present_stat_delta(
			"country.nonsense.effect", 2, 1.5).is_empty())


func _report() -> void:
	print("")
	print("ideology_phase1_probe: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
