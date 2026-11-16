class_name RegimePresenter
extends RefCounted

## 体制卡的展示层换算：把体制挂的 Modifier 条目翻成「哪些阶层拥护 / 反对」，
## 把权能键翻成玩家能比较的「国家权能」清单。只读目录资源，不碰运行时。

const CAPABILITY_LABELS := {
	"treasury_construction": "国库建造",
}
const CAPABILITY_TOOLTIPS := {
	"treasury_construction": "可在本国领土上动用国库资源发起建筑营造。",
}
const SATISFACTION_PATTERN := "^economy\\.profession\\.([a-z0-9_]+)\\.satisfaction_bp$"
## 这些统计量「越低越好」：数值下降是收益，不能按正负号涂红。
const LOWER_IS_BETTER := [
	"country.construction.cost_factor",
	"country.construction.time_factor",
	"country.research.cost_factor",
	"country.population.death_factor",
]

static var _catalog: Resource
static var _pattern: RegEx


## 给每条体制定义补上 powers（全目录权能并集，逐项标注有无）、supporters /
## opponents（满意度条目）与 charter（非满意度的国策条目）。
## present_professions：本国现有职业 {stable_id: true}；传 null 不过滤。
## 没出现过的职业不进卡面——玩家无从理解「一个还不存在的阶层会满意」。
static func enrich(definitions: Array, present_professions = null) -> Array:
	var all_capabilities := PackedStringArray()
	for raw in definitions:
		for key in PackedStringArray((raw as Dictionary).get("capability_keys", PackedStringArray())):
			if not all_capabilities.has(key):
				all_capabilities.append(key)
	var out: Array = []
	for raw in definitions:
		var row: Dictionary = (raw as Dictionary).duplicate(true)
		var own := PackedStringArray(row.get("capability_keys", PackedStringArray()))
		var powers: Array = []
		for key in all_capabilities:
			powers.append({"key": key,
				"label": String(CAPABILITY_LABELS.get(key, key)),
				"granted": own.has(key),
				"tooltip": String(CAPABILITY_TOOLTIPS.get(key, ""))})
		row["powers"] = powers
		var keys := PackedStringArray(
			row.get("modifier_definition_keys", PackedStringArray()))
		var attitudes := attitudes_for(keys, present_professions)
		row["supporters"] = attitudes.supporters
		row["opponents"] = attitudes.opponents
		row["charter"] = charter_for(keys)
		out.append(row)
	return out


## 体制 Modifier 里所有「阶层满意度」条目，按幅度从大到小。
static func attitudes_for(definition_keys: PackedStringArray,
		present_professions = null) -> Dictionary:
	var supporters: Array = []
	var opponents: Array = []
	var catalog := _modifier_catalog()
	if catalog == null or definition_keys.is_empty():
		return {"supporters": supporters, "opponents": opponents}
	if _pattern == null:
		_pattern = RegEx.create_from_string(SATISFACTION_PATTERN)
	for raw_definition in catalog.get("definitions"):
		var definition: Resource = raw_definition
		if definition == null or not definition_keys.has(String(definition.get("key"))):
			continue
		for raw_term in definition.get("terms"):
			var term: Resource = raw_term
			if term == null or int(term.get("operation")) != 0:
				continue
			var match := _pattern.search(String(term.get("stat_key")))
			if match == null:
				continue
			var value_bp := int(round(float(term.get("value"))))
			if value_bp == 0:
				continue
			var profession_id := match.get_string(1)
			if present_professions is Dictionary \
					and not (present_professions as Dictionary).has(profession_id):
				continue
			var name := ModifierCatalog._profession_display_name(profession_id)
			var entry := {
				"profession_id": profession_id,
				"name": name,
				"icon": IconCatalog.profession_semantic(profession_id),
				"value_bp": value_bp,
				"value_text": signed_points(value_bp),
				"tooltip": "%s满意度 %s" % [name, signed_points(value_bp)],
			}
			if value_bp > 0:
				supporters.append(entry)
			else:
				opponents.append(entry)
	var by_size := func(a: Dictionary, b: Dictionary) -> bool:
		return absi(int(a.value_bp)) > absi(int(b.value_bp))
	supporters.sort_custom(by_size)
	opponents.sort_custom(by_size)
	return {"supporters": supporters, "opponents": opponents}


## 体制挂的「国策」条目：非满意度统计量，措辞与理念/科技卡共用同一个换算器。
## 这些都是乘数，幅度再小也会作用到全国，所以卡面必须逐条列出来。
static func charter_for(definition_keys: PackedStringArray) -> Array:
	var out: Array = []
	var catalog := _modifier_catalog()
	if catalog == null or definition_keys.is_empty():
		return out
	if _pattern == null:
		_pattern = RegEx.create_from_string(SATISFACTION_PATTERN)
	for raw_definition in catalog.get("definitions"):
		var definition: Resource = raw_definition
		if definition == null or not definition_keys.has(String(definition.get("key"))):
			continue
		for raw_term in definition.get("terms"):
			var term: Resource = raw_term
			if term == null:
				continue
			var stat_key := String(term.get("stat_key"))
			if _pattern.search(stat_key) != null:
				continue  # 满意度条目由 supporters / opponents 呈现
			var operation := int(term.get("operation"))
			var value := float(term.get("value"))
			var text := ModifierCatalog.present_stat_delta(stat_key, operation, value)
			if text.is_empty():
				continue
			var delta := _term_delta(operation, value)
			var split := text.rfind(" ")
			out.append({
				"stat_key": stat_key,
				"label": text.substr(0, split) if split > 0 else text,
				"value_text": text.substr(split + 1) if split > 0 else "",
				"delta": delta,
				"beneficial": (delta < 0.0) if LOWER_IS_BETTER.has(stat_key) \
					else (delta > 0.0),
				"tooltip": "%s（体制常驻，%s叠加）" % [text,
					"相乘" if operation >= 2 else "相加"],
			})
	return out


static func _term_delta(operation: int, value: float) -> float:
	match operation:
		0:
			return value
		1:
			return -value
		2:
			return value - 1.0
		3:
			return 1.0 / value - 1.0 if not is_zero_approx(value) else 0.0
	return 0.0


## 满意度基点 → 「+1.5%」/「−1%」。
static func signed_points(value_bp: int) -> String:
	var text := ("%.1f" % (absf(float(value_bp)) / 100.0)).trim_suffix(".0")
	return "%s%s%%" % ["+" if value_bp > 0 else "−", text]


static func _modifier_catalog() -> Resource:
	if _catalog == null:
		_catalog = ModifierCatalog.load_default()
	return _catalog
