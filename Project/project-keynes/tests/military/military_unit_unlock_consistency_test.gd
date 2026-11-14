extends SceneTree

## 兵种解锁 / 装备链一致性的跨目录回归测试（两轮修复的合订防线）。
##
## 两套解锁语义从未绑定：`units[].tech` 决定兵种解锁（空串 = 恒解锁），
## `GoodProfile.technology_tags` 决定物资解锁（运行时 ANY，任一科技命中即可）。
##
## 第一轮（day 0）：`tech: ""` 的 militia / tribal_warriors 引用了 12 个
## `supply.upkeep` 装备物资 + 石矛 / 弓，而开局科技集合与它们的标签交集为 0。
## 现在 tribal_warriors 挂在 `tech.composite_tools`（硬前置含 stone_knapping），
## 民兵没有任何兵种专属物资需求。
##
## 第二轮（全兵种）：每个有科技门的兵种，其**每一个装备槽、按作者指定的
## min_quality 那一档 goods**，在解锁时都必须既有生产许可、又有已解锁的
## 产出建筑。不能用同类别里更早解锁的低档货蒙混：火枪兵的 melee_arms
## 类别里 stone_spears 很早就有，但它指定的 Q3 是 iron_weapons；核心装备
## firearms Q1 是 matchlocks，两者缺一不可。为此给兵种科技补了装备链硬前置，
## 并把 bronze_spearmen 挂到能覆盖三件装备的最早节点 hide_tanning。
##
## 校验走正式目录（军事 JSON + 经济目录 + 建筑 .tres + 科技树），并带负例
## （回退部落战士门槛 / 删掉火枪兵的冶铁前置）证明不是假 PASS。
##
##   godot --headless --path Project/project-keynes \
##       -s res://tests/military/military_unit_unlock_consistency_test.gd

const CompilerScript = preload("res://scripts/military/military_catalog_compiler.gd")

const MILITARY_PATH := "res://data/military/military_catalog.json"
const NETWORK_PATH := "res://data/technology/technology_network.json"
const BUILDING_DIR := "res://data/economy/buildings"
const TRIBAL_TECH := "tech.composite_tools"
const MUSKETEER_TECH := "tech.gunpowder_weapons"
const SUPPLY_CLASS_COUNT := 6
const SUPPLY_CLASS_IDS := ["ration", "fodder", "ammunition", "fuel", "upkeep", "equipment"]

var _failures := PackedStringArray()
var _economy: Dictionary = {}
var _nodes: Dictionary = {}
var _producers: Dictionary = {}
var _slots_checked := 0


func _init() -> void:
	_economy = EconomyCatalog.compile_native_catalog()
	_nodes = _technology_nodes()
	_producers = _load_producers()
	_check_day_zero_unlock_contract()
	_check_all_unit_equipment_reachable()
	_check_tribal_warriors_gate()
	_check_special_cases()
	_check_musketeers_example()
	_check_guard_detects_regression()
	_report_supply_gaps()
	if _failures.is_empty():
		print("=== military unit unlock consistency: ok ===")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	print("=== military unit unlock consistency: %d failures ===" % _failures.size())
	quit(1)


func _expect(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_failures.append("%s%s" % [label, "" if detail.is_empty() else " :: " + detail])


func _read_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


func _technology_nodes() -> Dictionary:
	var by_id := {}
	for node_value in _read_json(NETWORK_PATH).get("nodes", []):
		if node_value is Dictionary:
			var node: Dictionary = node_value
			by_id[String(node.get("id", ""))] = node
	return by_id


## 开局科技的上界：is_starter_eligible 节点及其硬前置闭包。真实开局由
## start_location_policy.gd 按出生点挑选子集，取并集只会让校验更宽松。
func _day_zero_technologies() -> Dictionary:
	var out := {}
	for tech_id in _nodes.keys():
		var node: Dictionary = _nodes[tech_id]
		if bool(node.get("is_starter_eligible", false)):
			_collect_prerequisites(String(tech_id), out, _nodes)
	return out


func _closure_of(tech_id: String, graph: Dictionary) -> Dictionary:
	var out := {}
	_collect_prerequisites(tech_id, out, graph)
	return out


func _collect_prerequisites(tech_id: String, out: Dictionary, graph: Dictionary) -> void:
	if tech_id.is_empty() or out.has(tech_id):
		return
	out[tech_id] = true
	if not graph.has(tech_id):
		return
	var node: Dictionary = graph[tech_id]
	for parent in node.get("hard_prerequisite_ids", []):
		_collect_prerequisites(String(parent), out, graph)


## 与原生 cell_has_requirements 的 ANY 语义同源：只看 `tech.` 前缀的标签，
## 数据取自正式经济目录（而不是重读 .tres，避免与编译口径漂移）。
func _good_technology_tags() -> Dictionary:
	var ids: Array = []
	for good_id in _economy.get("good_ids", []):
		ids.append(String(good_id))
	var tags: Array = []
	for tag in _economy.get("good_technology_tags", []):
		tags.append(String(tag))
	var offsets: Array = []
	for offset in _economy.get("good_technology_tag_offsets", []):
		offsets.append(int(offset))
	_expect("economy catalog exposes good technology tags",
		not ids.is_empty() and offsets.size() >= ids.size() + 1,
		"goods=%d tags=%d offsets=%d" % [ids.size(), tags.size(), offsets.size()])
	var out := {}
	for i in range(ids.size()):
		var list := PackedStringArray()
		if i + 1 < offsets.size():
			for t in range(offsets[i], mini(offsets[i + 1], tags.size())):
				var tag := String(tags[t]).strip_edges()
				if tag.begins_with("tech."):
					list.append(tag)
		out[ids[i]] = list
	return out


func _economy_good_ids() -> Array:
	var ids: Array = []
	for good_id in _economy.get("good_ids", []):
		ids.append(String(good_id))
	return ids


## 从建筑 .tres 读产出关系：good_id -> [{building, tags, required}]。
## 运行时 building_available 用 technology_tags(ANY) + required_technology_tags(ALL)，
## 这里用同一口径；数据文件必须是能读到的，否则计数断言会拦下假 PASS。
func _packed_strings(text: String, key: String) -> PackedStringArray:
	var out := PackedStringArray()
	var regex := RegEx.new()
	if regex.compile("(?m)^\\s*" + key + "\\s*=\\s*PackedStringArray\\(([^)]*)\\)") != OK:
		return out
	var found := regex.search(text)
	if found == null:
		return out
	for part in String(found.get_string(1)).split(","):
		var value := String(part).strip_edges().replace("\"", "")
		if not value.is_empty():
			out.append(value)
	return out


func _tech_only(values: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for value in values:
		if String(value).begins_with("tech."):
			out.append(String(value))
	return out


func _load_producers() -> Dictionary:
	var out := {}
	var dir := DirAccess.open(BUILDING_DIR)
	_expect("building source directory is readable", dir != null)
	if dir == null:
		return out
	var count := 0
	for file_name in dir.get_files():
		if not String(file_name).ends_with(".tres"):
			continue
		var text := FileAccess.get_file_as_string(BUILDING_DIR + "/" + String(file_name))
		if text.is_empty():
			continue
		count += 1
		var outputs := _packed_strings(text, "output_good_ids")
		if outputs.is_empty():
			continue
		var tags := _tech_only(_packed_strings(text, "technology_tags"))
		var required := _tech_only(_packed_strings(text, "required_technology_tags"))
		for good_id in outputs:
			var key := String(good_id)
			if not out.has(key):
				out[key] = []
			(out[key] as Array).append({
				"building": String(file_name), "tags": tags, "required": required})
	_expect("building sources are loaded", count > 100, str(count))
	return out


func _producer_ready(good_id: String, closure: Dictionary) -> bool:
	for row_value in _producers.get(good_id, []):
		if not row_value is Dictionary:
			continue
		var row: Dictionary = row_value
		var direct: PackedStringArray = row.get("tags", PackedStringArray())
		var hit := false
		for tag in direct:
			if closure.has(String(tag)):
				hit = true
		if not hit:
			continue
		var all_required := true
		var required: PackedStringArray = row.get("required", PackedStringArray())
		for tag in required:
			if not closure.has(String(tag)):
				all_required = false
		if all_required:
			return true
	return false


## 槽位指定的那一档 goods（quality == min_quality）。运行时采购只按类别找货，
## 但作者指定的档位才是这个兵种成立的门槛，不能用类别里的低档货替代。
func _exact_good(raw: Dictionary, category: String, quality: int) -> String:
	for category_value in raw.get("equipment_categories", []):
		if not category_value is Dictionary:
			continue
		var entry: Dictionary = category_value
		if str(entry.get("id", "")) != category:
			continue
		for good_value in entry.get("goods", []):
			if good_value is Dictionary \
					and int((good_value as Dictionary).get("quality", 0)) == quality:
				return str((good_value as Dictionary).get("good", ""))
	return ""


## 一个恒解锁兵种引用到的物资：精确档装备 + 所有有非零需求的补给类候选。
func _referenced_goods(raw: Dictionary, compiled: Dictionary, unit: Dictionary) -> Array:
	var seen := {}
	var out: Array = []
	for slot_value in unit.get("equipment", []):
		if not slot_value is Dictionary:
			continue
		var slot: Dictionary = slot_value
		var good_id := _exact_good(raw, str(slot.get("category", "")),
			int(slot.get("min_quality", 1)))
		if not good_id.is_empty() and not seen.has(good_id):
			seen[good_id] = true
			out.append(good_id)
	var good_ids := _economy_good_ids()
	var rows: Array = compiled.get("supply_goods", [])
	var idle: Dictionary = unit.get("supply_idle", {})
	var combat: Dictionary = unit.get("supply_combat", {})
	for supply_class in range(mini(SUPPLY_CLASS_COUNT, rows.size())):
		var key := str(SUPPLY_CLASS_IDS[supply_class])
		if float(idle.get(key, 0.0)) <= 0.0 and float(combat.get(key, 0.0)) <= 0.0:
			continue
		var row: PackedInt32Array = rows[supply_class]
		for index_value in row:
			var index := int(index_value)
			if index < 0 or index >= good_ids.size():
				continue
			var good_id := String(good_ids[index])
			if not seen.has(good_id):
				seen[good_id] = true
				out.append(good_id)
	return out


## 恒解锁兵种的全部物资依赖必须在开局可用（用原始 JSON 的 units：编译后的
## equipment.category 是密集索引、supply_* 是 PackedFloat32Array）。
func _day_zero_violations(raw: Dictionary, compiled: Dictionary,
		day_zero: Dictionary, good_tags: Dictionary) -> Array:
	var violations: Array = []
	if not bool(compiled.get("ok", false)):
		violations.append("catalog does not compile: %s" % String(compiled.get("reason", "")))
		return violations
	var always := 0
	for unit_value in raw.get("units", []):
		if not unit_value is Dictionary:
			continue
		var unit: Dictionary = unit_value
		if not str(unit.get("tech", "")).strip_edges().is_empty():
			continue
		always += 1
		var unit_id := str(unit.get("id", ""))
		for good_id in _referenced_goods(raw, compiled, unit):
			var tags: PackedStringArray = good_tags.get(String(good_id), PackedStringArray())
			var unlocked := false
			for tag in tags:
				if day_zero.has(String(tag)):
					unlocked = true
			if not unlocked:
				violations.append("always-unlocked unit %s needs locked good %s (tags=%s)"
					% [unit_id, String(good_id), str(tags)])
	if always != 1:
		violations.append("expected exactly one always-unlocked unit, found %d" % always)
	return violations


## 全兵种硬契约：每个有科技门的兵种、每个装备槽、按作者指定档位，
## 解锁瞬间必须「物资许可 + 产出建筑许可」同时成立。
func _equipment_violations(raw: Dictionary, graph: Dictionary,
		good_tags: Dictionary) -> Array:
	var violations: Array = []
	_slots_checked = 0
	for unit_value in raw.get("units", []):
		if not unit_value is Dictionary:
			continue
		var unit: Dictionary = unit_value
		var tech_id := str(unit.get("tech", "")).strip_edges()
		if tech_id.is_empty():
			continue  # 恒解锁兵种由 day-zero 契约覆盖
		if not graph.has(tech_id):
			violations.append("unknown unlock technology %s" % tech_id)
			continue
		var closure := _closure_of(tech_id, graph)
		var unit_id := str(unit.get("id", ""))
		for slot_value in unit.get("equipment", []):
			if not slot_value is Dictionary:
				continue
			var slot: Dictionary = slot_value
			var category := str(slot.get("category", ""))
			var quality := int(slot.get("min_quality", 1))
			var good_id := _exact_good(raw, category, quality)
			_slots_checked += 1
			if good_id.is_empty():
				violations.append("%s/%sQ%d has no exact-quality good"
					% [unit_id, category, quality])
				continue
			var tags: PackedStringArray = good_tags.get(good_id, PackedStringArray())
			var unlocked := false
			for tag in tags:
				if closure.has(String(tag)):
					unlocked = true
			if not unlocked:
				violations.append("%s/%sQ%d good %s is locked at unlock (tags=%s)"
					% [unit_id, category, quality, good_id, str(tags)])
				continue
			if not _producer_ready(good_id, closure):
				violations.append("%s/%sQ%d good %s has no unlocked producer"
					% [unit_id, category, quality, good_id])
	return violations


func _compile(raw: Dictionary) -> Dictionary:
	return CompilerScript.compile_from_data(raw, _economy,
		TechnologyCatalog.compile_native_catalog())


func _unit_by_id(raw: Dictionary, unit_id: String) -> Dictionary:
	for unit_value in raw.get("units", []):
		if unit_value is Dictionary and str((unit_value as Dictionary).get("id", "")) == unit_id:
			return unit_value
	return {}


func _check_day_zero_unlock_contract() -> void:
	var raw := _read_json(MILITARY_PATH)
	_expect("shipped military catalog is readable", not raw.is_empty())
	_expect("technology network is readable", not _nodes.is_empty(), str(_nodes.size()))
	if raw.is_empty() or _nodes.is_empty():
		return
	var compiled := _compile(raw)
	_expect("shipped catalog compiles", bool(compiled.get("ok", false)),
		String(compiled.get("reason", "")))
	for violation in _day_zero_violations(raw, compiled,
			_day_zero_technologies(), _good_technology_tags()):
		_failures.append(String(violation))
	var militia := _unit_by_id(raw, "militia")
	_expect("militia is declared", not militia.is_empty())
	if not militia.is_empty():
		var has_demand := false
		for supply_key in ["supply_idle", "supply_combat"]:
			var row: Dictionary = militia.get(supply_key, {})
			for value in row.values():
				if float(value) > 0.0:
					has_demand = true
		_expect("militia has no unit-specific good demand",
			(militia.get("equipment", []) as Array).is_empty() and not has_demand)


func _check_all_unit_equipment_reachable() -> void:
	var raw := _read_json(MILITARY_PATH)
	if raw.is_empty():
		return
	var violations := _equipment_violations(raw, _nodes, _good_technology_tags())
	for violation in violations:
		_failures.append(String(violation))
	_expect("checked every authored gated equipment slot", _slots_checked >= 46,
		str(_slots_checked))
	_expect("every gated equipment slot is reachable at unlock", violations.is_empty(),
		str(violations.size()) + " broken slots")


func _check_tribal_warriors_gate() -> void:
	var raw := _read_json(MILITARY_PATH)
	if raw.is_empty() or _nodes.is_empty():
		return
	var tribal := _unit_by_id(raw, "tribal_warriors")
	_expect("tribal warriors are declared", not tribal.is_empty())
	if tribal.is_empty():
		return
	_expect("tribal warriors are gated behind composite tools",
		String(tribal.get("tech", "")) == TRIBAL_TECH, String(tribal.get("tech", "")))
	var closure := _closure_of(TRIBAL_TECH, _nodes)
	var good_tags := _good_technology_tags()
	for good_id in ["stone_spears", "bows"]:
		var tags: PackedStringArray = good_tags.get(String(good_id), PackedStringArray())
		var hit := PackedStringArray()
		for tag in tags:
			if closure.has(String(tag)):
				hit.append(String(tag))
		_expect("composite tools unlocks %s" % good_id, not hit.is_empty(), str(tags))


## bronze_spearmen 的 hide_tanning 门槛是特例：三件装备（青铜兵器 / 皮甲 /
## 弓）分布在三条链上，而科技表按 dense id 拓扑排序，不能给 bronze_casting
## 挂排在它后面的 hide_tanning 前置。hide_tanning 补 bronze_casting 前置后
## 是唯一能同时覆盖三件装备的最早节点。
func _check_special_cases() -> void:
	var raw := _read_json(MILITARY_PATH)
	if raw.is_empty() or _nodes.is_empty():
		return
	var spears := _unit_by_id(raw, "bronze_spearmen")
	_expect("bronze spearmen gate covers all three equipment chains",
		String(spears.get("tech", "")) == "tech.hide_tanning",
		String(spears.get("tech", "")))
	var closure := _closure_of("tech.hide_tanning", _nodes)
	var good_tags := _good_technology_tags()
	for good_id in ["bronze_weapons", "hide_armor", "bows"]:
		var tags: PackedStringArray = good_tags.get(String(good_id), PackedStringArray())
		var hit := false
		for tag in tags:
			if closure.has(String(tag)):
				hit = true
		_expect("hide_tanning closure unlocks %s" % good_id, hit, str(tags))


## 用户举的例子：火枪兵的 melee_arms 类别里 stone_spears 很早解锁，但它指定的
## Q3 是 iron_weapons；核心装备 firearms Q1 是 matchlocks。两件都必须可用。
## 负例把 gunpowder_weapons 的冶铁前置删掉，防线必须报出 iron_weapons 缺口。
func _check_musketeers_example() -> void:
	var raw := _read_json(MILITARY_PATH)
	if raw.is_empty() or _nodes.is_empty():
		return
	var musketeers := _unit_by_id(raw, "musketeers")
	_expect("musketeers are declared", not musketeers.is_empty())
	if musketeers.is_empty():
		return
	_expect("musketeers are gated behind gunpowder weapons",
		String(musketeers.get("tech", "")) == MUSKETEER_TECH,
		String(musketeers.get("tech", "")))
	var slots: Array = musketeers.get("equipment", [])
	_expect("musketeers carry two equipment slots", slots.size() == 2, str(slots.size()))
	_expect("musketeers need matchlocks (firearms Q1)",
		_exact_good(raw, "firearms", 1) == "matchlocks")
	_expect("musketeers need iron weapons (melee Q3, not stone spears)",
		_exact_good(raw, "melee_arms", 3) == "iron_weapons")
	var closure := _closure_of(MUSKETEER_TECH, _nodes)
	var good_tags := _good_technology_tags()
	for good_id in ["matchlocks", "iron_weapons"]:
		var tags: PackedStringArray = good_tags.get(String(good_id), PackedStringArray())
		var hit := false
		for tag in tags:
			if closure.has(String(tag)):
				hit = true
		_expect("gunpowder weapons unlocks %s" % good_id, hit, str(tags))
		_expect("%s has an unlocked producer" % good_id,
			_producer_ready(String(good_id), closure))
	var regressed: Dictionary = _nodes.duplicate(true)
	var gate: Dictionary = (regressed[MUSKETEER_TECH] as Dictionary).duplicate()
	var prereq: Array = (gate.get("hard_prerequisite_ids", []) as Array).duplicate()
	prereq.erase("tech.iron_smelting")
	gate["hard_prerequisite_ids"] = prereq
	regressed[MUSKETEER_TECH] = gate
	var violations := _equipment_violations(raw, regressed, _good_technology_tags())
	var found := false
	for violation in violations:
		if String(violation).contains("musketeers") and String(violation).contains("iron_weapons"):
			found = true
	_expect("guard rejects a musketeer unlocked without iron weapons", found,
		str(violations))


## 把 tribal_warriors 的门槛改回空串，防线必须报出石矛 / 弓 / upkeep 的违规。
func _check_guard_detects_regression() -> void:
	var raw := _read_json(MILITARY_PATH)
	if raw.is_empty() or _nodes.is_empty():
		return
	var regressed := raw.duplicate(true)
	var units: Array = regressed.get("units", [])
	var patched := false
	for i in range(units.size()):
		if units[i] is Dictionary \
				and String((units[i] as Dictionary).get("id", "")) == "tribal_warriors":
			var unit: Dictionary = (units[i] as Dictionary).duplicate()
			unit["tech"] = ""
			units[i] = unit
			patched = true
	_expect("regression fixture patched the tribal gate", patched)
	if not patched:
		return
	var violations := _day_zero_violations(regressed, _compile(regressed),
		_day_zero_technologies(), _good_technology_tags())
	var found := false
	for violation in violations:
		if String(violation).contains("tribal_warriors"):
			found = true
	_expect("guard rejects an always-unlocked tribal_warriors", found, str(violations))


## 补给类（fodder / ammunition / fuel / upkeep）是持续消耗、按候选 OR 结算，
## 不是训练能否完成的门槛。这里只报告缺口，不当作硬失败：某些缺口（如
## 火药时代之前的攻城营弹药）属于独立的数值设计债，见成本表 §8。
func _report_supply_gaps() -> void:
	var raw := _read_json(MILITARY_PATH)
	if raw.is_empty():
		return
	var compiled := _compile(raw)
	if not bool(compiled.get("ok", false)):
		return
	var good_ids := _economy_good_ids()
	var rows: Array = compiled.get("supply_goods", [])
	var good_tags := _good_technology_tags()
	var gaps: Array = []
	for unit_value in raw.get("units", []):
		if not unit_value is Dictionary:
			continue
		var unit: Dictionary = unit_value
		var tech_id := str(unit.get("tech", "")).strip_edges()
		var closure := _closure_of(tech_id, _nodes) if not tech_id.is_empty() \
			else _day_zero_technologies()
		var idle: Dictionary = unit.get("supply_idle", {})
		var combat: Dictionary = unit.get("supply_combat", {})
		for supply_class in range(mini(SUPPLY_CLASS_COUNT, rows.size())):
			var key := str(SUPPLY_CLASS_IDS[supply_class])
			if float(idle.get(key, 0.0)) <= 0.0 and float(combat.get(key, 0.0)) <= 0.0:
				continue
			var any := false
			var row: PackedInt32Array = rows[supply_class]
			for index_value in row:
				var index := int(index_value)
				if index < 0 or index >= good_ids.size():
					continue
				var good_id := String(good_ids[index])
				var tags: PackedStringArray = good_tags.get(good_id, PackedStringArray())
				var unlocked := false
				for tag in tags:
					if closure.has(String(tag)):
						unlocked = true
				if unlocked and _producer_ready(good_id, closure):
					any = true
			if not any:
				gaps.append("%s/%s" % [str(unit.get("id", "")), key])
	print("  [info] supply-class reachability gaps (not a hard gate): %d %s"
		% [gaps.size(), str(gaps.slice(0, 8))])
