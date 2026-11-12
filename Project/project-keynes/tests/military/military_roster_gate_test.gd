extends SceneTree

## 兵种名册的数据管线测试：编译目录带中文名与所需科技 → CountryViewModel 合并 →
## MilitaryViewModel 用「国家已研究科技」过滤。跑的是正式路径（不是截图夹具手搓模型），
## 所以这条链一断，兵力页就会退回英文 id、并把没解锁的兵种塞回配置表。
##
##   godot --path Project/project-keynes -s res://tests/military/military_roster_gate_test.gd

const CountryViewModelScript = preload("res://scripts/ui/country_view_model.gd")
const MilitaryViewModelScript = preload("res://scripts/ui/military_view_model.gd")
const CompilerScript = preload("res://scripts/military/military_catalog_compiler.gd")

const Q16 := 65536

var _failures := PackedStringArray()


func _init() -> void:
	_check_compiler_carries_authored_copy()
	_check_country_model_wires_names_and_gate()
	_check_gate_filters_roster_and_codex()
	_check_unknown_gate_shows_everything()
	if _failures.is_empty():
		print("=== military roster gate: ok ===")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	print("=== military roster gate: %d failures ===" % _failures.size())
	quit(1)


func _expect(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_failures.append("%s%s" % [label, "" if detail.is_empty() else " :: " + detail])


## 编译目录必须把作者写的中文名、描述与所需科技透传给 UI，否则面板只能显示 id。
func _check_compiler_carries_authored_copy() -> void:
	var compiled := CompilerScript.compile(_economy_catalog(), _technology_catalog())
	_expect("compiler accepts the shipped catalog", bool(compiled.get("ok", false)),
		String(compiled.get("reason", "")))
	if not bool(compiled.get("ok", false)):
		return
	var units: Array = compiled.get("units", [])
	var by_id := {}
	for unit_value in units:
		var unit: Dictionary = unit_value
		by_id[String(unit.get("id", ""))] = unit
	var spearmen: Dictionary = by_id.get("bronze_spearmen", {})
	_expect("compiled unit carries its authored name", String(spearmen.get("name", "")) == "青铜矛兵",
		String(spearmen.get("name", "")))
	_expect("compiled unit carries its description",
		not String(spearmen.get("description", "")).is_empty())
	_expect("compiled unit carries its technology id",
		String(spearmen.get("tech", "")) == "tech.hide_tanning",
		String(spearmen.get("tech", "")))
	_expect("militia is the only tech-free unit",
		String(by_id.get("militia", {}).get("tech", "x")).is_empty())
	_expect("tribal warriors are gated behind their equipment technology",
		String(by_id.get("tribal_warriors", {}).get("tech", "")) ==
			"tech.composite_tools",
		String(by_id.get("tribal_warriors", {}).get("tech", "")))
	var categories: Array = compiled.get("categories", [])
	var named := 0
	for category_value in categories:
		var category: Dictionary = category_value
		if not String(category.get("name", "")).is_empty():
			named += 1
	_expect("every equipment category is named", named == categories.size(),
		"%d/%d" % [named, categories.size()])


## CountryViewModel 是唯一把「原生数值 + 作者文案 + 国家科技」装到一起的地方。
func _check_country_model_wires_names_and_gate() -> void:
	var model := _country_model(_researched(["tech.hide_tanning"]))
	var section: Dictionary = model.get("military", {})
	_expect("military section is available", bool(section.get("available", false)),
		String(section.get("reason", "")))
	_expect("military section reports a known technology gate",
		bool(section.get("tech_gate_known", false)))
	_expect("military section forwards the researched technology ids",
		(section.get("researched_tech_ids", PackedStringArray()) as PackedStringArray).has(
			"tech.hide_tanning"))
	var catalog: Dictionary = section.get("catalog", {})
	var display_names: Dictionary = catalog.get("display_names", {})
	_expect("catalog display names are authored Chinese",
		String(display_names.get("bronze_spearmen", "")) == "青铜矛兵",
		String(display_names.get("bronze_spearmen", "")))
	_expect("catalog category names are authored Chinese",
		String((catalog.get("category_names", {}) as Dictionary).get("melee_arms", "")) == "兵器",
		String((catalog.get("category_names", {}) as Dictionary).get("melee_arms", "")))
	_expect("catalog maps unit id to its required technology",
		String((catalog.get("unit_tech", {}) as Dictionary).get("bronze_spearmen", "")) ==
			"tech.hide_tanning")
	_expect("catalog maps tribal warriors to composite tools",
		String((catalog.get("unit_tech", {}) as Dictionary).get("tribal_warriors", "")) ==
			"tech.composite_tools")


## 只研究了皮革鞣制（青铜矛兵三件装备全部就绪的最早节点）：青铜矛兵可用，
## 铁甲步兵不可用；已经占着份额的未解锁兵种要留着。
func _check_gate_filters_roster_and_codex() -> void:
	var model := _country_model(_researched(["tech.hide_tanning"]))
	var vm = MilitaryViewModelScript.new()
	vm.configure(model)
	var spears := vm.unit_index("bronze_spearmen")
	var iron := vm.unit_index("iron_infantry")
	_expect("bronze spearmen index resolves", spears >= 0)
	_expect("iron infantry index resolves", iron >= 0)
	_expect("researched unit is unlocked", vm.unit_unlocked(spears))
	_expect("unresearched unit is locked", not vm.unit_unlocked(iron))
	_expect("locked unit names its gate",
		vm.technology_name(vm.unit_unlock_tech(iron)) == "常备军",
		vm.technology_name(vm.unit_unlock_tech(iron)))
	_expect("militia is always unlocked", vm.unit_unlocked(vm.unit_index("militia")))
	_expect("tribal warriors stay locked without composite tools",
		not vm.unit_unlocked(vm.unit_index("tribal_warriors")))
	var equipped_vm = MilitaryViewModelScript.new()
	equipped_vm.configure(_country_model(_researched(["tech.composite_tools"])))
	_expect("tribal warriors unlock with composite tools",
		equipped_vm.unit_unlocked(equipped_vm.unit_index("tribal_warriors")))
	var shares := {"bronze_spearmen": 2500, "iron_infantry": 1000}
	var rows: Array = vm.unit_share_rows(shares)
	var ids: Array = []
	for row_value in rows:
		ids.append(String((row_value as Dictionary).get("id", "")))
	_expect("roster lists the unlocked unit", ids.has("bronze_spearmen"), str(ids))
	_expect("roster keeps a locked unit that still holds a share", ids.has("iron_infantry"),
		str(ids))
	_expect("roster drops locked units without a share", not ids.has("cavalry"), str(ids))
	for row_value in rows:
		var row: Dictionary = row_value
		var unit_id := String(row.get("id", ""))
		_expect("roster row %s shows a display name" % unit_id,
			String(row.get("name", "")) != unit_id, String(row.get("name", "")))
		_expect("roster row %s reports its attack" % unit_id, float(row.get("attack", 0.0)) > 0.0)
		_expect("roster row %s reports a share ratio" % unit_id,
			float(row.get("attack_ratio", -1.0)) >= 0.0)
		if unit_id == "iron_infantry":
			_expect("locked row cannot raise its share", not bool(row.get("can_raise", true)))
			_expect("locked row is flagged", bool(row.get("locked", false)))
	_expect("gate counts the locked units", vm.locked_unit_count() > 0,
		str(vm.locked_unit_count()))
	# 民兵是兵种，也是「没分配掉的份额」的持有者：必须排最后、有一行、不能加份额。
	var militia_rows := 0
	var last_row: Dictionary = rows[rows.size() - 1] if not rows.is_empty() else {}
	for row_value in rows:
		if bool((row_value as Dictionary).get("is_militia_row", false)):
			militia_rows += 1
	_expect("roster has exactly one militia row", militia_rows == 1, str(militia_rows))
	_expect("militia closes the roster", bool(last_row.get("is_militia_row", false)),
		String(last_row.get("id", "")))
	_expect("militia owns the unassigned share", int(last_row.get("bp", -1)) == 6500,
		str(last_row.get("bp", -1)))
	_expect("militia cannot raise its share", not bool(last_row.get("can_raise", true)))


## 拿不到国家科技快照时（离线/夹具）不能过滤，否则面板会一片空白。
func _check_unknown_gate_shows_everything() -> void:
	var model := _country_model(PackedStringArray())
	model["country_facade"] = null
	var vm = MilitaryViewModelScript.new()
	vm.configure(model)
	_expect("unknown gate is reported", not vm.gate_known())
	_expect("unknown gate unlocks everything",
		vm.unit_unlocked(vm.unit_index("iron_infantry")))
	_expect("unknown gate filters nothing", vm.locked_unit_count() == 0)
	var rows: Array = vm.unit_share_rows({})
	# 全目录 + 一行民兵（unlocked_unit_count() 只数非民兵兵种）。
	_expect("unknown gate lists the whole catalog",
		rows.size() == vm.unlocked_unit_count() + 1,
		"%d vs %d" % [rows.size(), vm.unlocked_unit_count()])


# ── fixtures ─────────────────────────────────────────────────────────────

## 只用紧凑目录（原生 catalog_view 的形状）跑合并，避免测试依赖世界生成。
func _country_model(researched: PackedStringArray) -> Dictionary:
	var compiled := CompilerScript.compile(_economy_catalog(), _technology_catalog())
	var view := _catalog_view(compiled)
	var model := {
		"country_handle": 0x100000000,
		"current_day": 40,
		"good_ids": PackedStringArray(),
	}
	var vm = CountryViewModelScript.new()
	var section := {
		"available": true,
		"facade": null,
		"country_handle": 0x100000000,
		"snapshot": _country_snapshot(),
		"armies": [],
		"catalog": vm.call("_merge_military_catalog", compiled, view),
		"researched_tech_ids": researched,
		"tech_gate_known": not researched.is_empty(),
	}
	model["military"] = section
	model["country_facade"] = FakeCountryFacade.new(researched) if not researched.is_empty() else null
	return model


func _researched(ids: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for id in ids:
		out.append(String(id))
	return out


## 国家槽快照：名册只用到 daily_wage 与科技无关的计数，这里给最小可用集合。
func _country_snapshot() -> Dictionary:
	return {
		"ok": true, "country_slot": 0, "has_policy": true,
		"daily_wage": int(0.42 * 10000), "per_soldier_cost": int(0.42 * 10000),
		"target_mode": 0, "target_value": 0, "effective_target": 0,
		"config_share_bp": PackedInt32Array(),
		"barracks": [], "training": [], "wars": [],
	}


## 原生 catalog_view() 的形状：数值与 unlock_bit，没有名字。
func _catalog_view(compiled: Dictionary) -> Dictionary:
	var units: Array = []
	var source: Array = compiled.get("units", [])
	for index in range(source.size()):
		var unit: Dictionary = source[index]
		var equipment: Array = []
		for slot_value in unit.get("equipment", []):
			var slot: Dictionary = slot_value
			equipment.append({
				"category": int(slot.get("category", -1)),
				"min_quality": int(slot.get("min_quality", 1)),
				"qty_per_100": int(round(float(slot.get("per_100", 0.0)) * 1000.0)),
				"weight_q16": int(round(float(slot.get("weight", 1.0)) * Q16)),
			})
		var idle := PackedInt64Array()
		var combat := PackedInt64Array()
		for cls in range(6):
			idle.append(int(round(float((unit.get("supply_idle", PackedFloat32Array())
				as PackedFloat32Array)[cls]) * 1000.0)))
			combat.append(int(round(float((unit.get("supply_combat", PackedFloat32Array())
				as PackedFloat32Array)[cls]) * 1000.0)))
		units.append({
			"index": index,
			"id": String(unit.get("id", "")),
			"class": int(unit.get("class", 0)),
			"militia": bool(unit.get("militia", false)),
			"era": int(unit.get("era", 0)),
			"unlock_bit": int(unit.get("unlock_bit", -1)),
			"attack_q16": int(round(float(unit.get("attack", 1.0)) * Q16)),
			"defense_q16": int(round(float(unit.get("defense", 1.0)) * Q16)),
			"speed_q16": int(round(float(unit.get("speed", 1.0)) * Q16)),
			"fortification_ignore_q16": int(round(
				float(unit.get("fortification_ignore", 0.0)) * Q16)),
			"training_days": int(unit.get("training_days", 0)),
			"equipment": equipment,
			"supply_idle_per_100": idle,
			"supply_combat_per_100": combat,
		})
	var categories: Array = []
	var source_categories: Array = compiled.get("categories", [])
	for index in range(source_categories.size()):
		var category: Dictionary = source_categories[index]
		categories.append({
			"index": index,
			"id": String(category.get("id", "")),
			"goods": category.get("goods", PackedInt32Array()),
			"qualities": category.get("qualities", PackedInt32Array()),
		})
	return {
		"ok": true,
		"militia_unit": 0,
		"units": units,
		"categories": categories,
		"state_buildings": compiled.get("state_buildings", []),
		"unlock_tech_ids": compiled.get("unlock_tech_ids", PackedInt32Array()),
	}


## 经济/科技目录用真实工程数据：军事目录的 id 必须在这两份目录里解析成功。
func _economy_catalog() -> Dictionary:
	return EconomyCatalog.compile_native_catalog()


func _technology_catalog() -> Dictionary:
	return TechnologyCatalog.compile_native_catalog()


class FakeCountryFacade:
	var _researched: PackedStringArray

	func _init(researched: PackedStringArray) -> void:
		_researched = researched

	func snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "technology_ids": _researched}
