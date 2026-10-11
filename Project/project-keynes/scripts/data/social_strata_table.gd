@tool
extends Resource
class_name SocialStrataTable

## 仅供 UI 展示的社会阶层分组：把职业归入少量玩家可读的阶层。
## 不进入 catalog hash，不影响意识形态、税制或任何模拟规则。

const DEFAULT_PATH := "res://data/ui/social_strata.tres"

## 每项：{id, name, icon, color, professions: PackedStringArray}
@export var strata: Array[Dictionary] = []
@export var fallback_stratum: StringName = &"workers"

static var _default: SocialStrataTable = null

var _index_by_profession: Dictionary = {}
var _fallback_index := -1


static func load_default() -> SocialStrataTable:
	if _default == null:
		_default = load(DEFAULT_PATH) as SocialStrataTable
	return _default


func stratum_count() -> int:
	return strata.size()


func stratum(index: int) -> Dictionary:
	return strata[index] if index >= 0 and index < strata.size() else {}


func stratum_id(index: int) -> String:
	return String(stratum(index).get("id", ""))


func index_of(stratum_id_value: String) -> int:
	for index in range(strata.size()):
		if String(strata[index].get("id", "")) == stratum_id_value:
			return index
	return -1


func stratum_index_for(profession_id: String) -> int:
	if _index_by_profession.is_empty():
		_rebuild_index()
	return int(_index_by_profession.get(profession_id, _fallback_index))


## 未归类的职业落到 fallback；返回缺失归类的职业，供测试守住映射完整性。
func unmapped(profession_ids: PackedStringArray) -> PackedStringArray:
	if _index_by_profession.is_empty():
		_rebuild_index()
	var missing := PackedStringArray()
	for profession_id in profession_ids:
		if not _index_by_profession.has(String(profession_id)):
			missing.append(String(profession_id))
	return missing


func _rebuild_index() -> void:
	_index_by_profession.clear()
	_fallback_index = 0
	for index in range(strata.size()):
		var entry: Dictionary = strata[index]
		if StringName(entry.get("id", "")) == fallback_stratum:
			_fallback_index = index
		for profession_id in entry.get("professions", PackedStringArray()):
			_index_by_profession[String(profession_id)] = index
