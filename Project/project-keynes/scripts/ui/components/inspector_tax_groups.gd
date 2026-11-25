extends RefCounted

const TaxGroupMapScript := preload("res://scripts/country/tax_group_map.gd")


## 税收面板可选的「整组调税」轴。四轴共用一套分组模块，顺序即面板下拉顺序。
## 档位放第一：它是这次新加的生产方式轴，也是玩家最想「一条滑条管一档」的那条。
const TAX_GROUP_AXES := [
	{"mode": "maturity_rank", "label": "按生产档位", "hint": "同一生产方式档位的全国建筑"},
	{"mode": "output_good", "label": "按产物", "hint": "产出同一件货的全国建筑"},
	{"mode": "sector", "label": "按大类", "hint": "农业/采掘/制造/能源/知识/军事"},
	{"mode": "staple_crop", "label": "按主粮农场", "hint": "全国主粮农场，其余按大类"},
]


static func tax_group_axes() -> Array:
	return TAX_GROUP_AXES


## 把 catalog 列整理成税分组需要的形状。业主列只给 sector_owner/staple_crop 用，
## 这里补占位保持长度匹配，避免其他轴因为缺列被拒。
static func _tax_group_columns(controller) -> Dictionary:
	if controller == null or not controller.has_method("get_economy_facade"):
		return {}
	var economy = controller.get_economy_facade()
	if economy == null or not economy.has_method("construction_type_columns"):
		return {}
	var columns: Dictionary = economy.construction_type_columns()
	var building_ids: PackedStringArray = columns.get(
		"building_type_ids", PackedStringArray())
	if building_ids.is_empty():
		return {}
	var owners: PackedInt32Array = columns.get(
		"building_owner_profession_ids", PackedInt32Array())
	if owners.size() != building_ids.size():
		owners = PackedInt32Array()
		owners.resize(building_ids.size())
		owners.fill(0)
		columns["building_owner_profession_ids"] = owners
		columns["profession_ids"] = PackedStringArray(["placeholder"])
	return columns


## 取 item_id 这座建筑在某个分组轴下所属的整组。
## 返回 {ok, mode, group_id, label, item_ids, count, group_count}；失败返回 {}。
static func tax_group_ids_for(controller, mode: String, item_id: String) -> Dictionary:
	var columns := _tax_group_columns(controller)
	if columns.is_empty():
		return {}
	var building_ids: PackedStringArray = columns["building_type_ids"]
	var building := building_ids.find(item_id)
	if building < 0:
		return {}
	var grouped: Dictionary = TaxGroupMapScript.build(columns, mode)
	if not bool(grouped.get("ok", false)):
		return {}
	var group_ids: PackedStringArray = grouped.get("group_ids", PackedStringArray())
	var group_labels: PackedStringArray = grouped.get(
		"group_labels", PackedStringArray())
	var indices: PackedInt32Array = grouped.get(
		"building_group_indices", PackedInt32Array())
	if building >= indices.size():
		return {}
	var group := int(indices[building])
	if group < 0 or group >= group_ids.size():
		return {}
	var out := PackedStringArray()
	for member in TaxGroupMapScript.buildings_in_group(indices, group):
		if member >= 0 and member < building_ids.size():
			out.append(building_ids[member])
	return {
		"ok": true,
		"mode": mode,
		"group": group,
		"group_id": String(group_ids[group]),
		"label": String(group_labels[group]) if group < group_labels.size() else "",
		"item_ids": out,
		"count": out.size(),
		"group_count": group_ids.size(),
	}


## 主粮农场税组的 item_id 列表（当前 50 座）。整组调税需要它，而分组判定
## 与建造界面的折叠同源：首个产出货的类别是 starchy_staple。
## catalog 从 economy facade 的 construction_type_columns 取，不新建数据通路。
static func staple_farm_tax_group_ids(controller) -> PackedStringArray:
	var columns := _tax_group_columns(controller)
	if columns.is_empty():
		return PackedStringArray()
	var building_ids: PackedStringArray = columns["building_type_ids"]
	var grouped: Dictionary = TaxGroupMapScript.build(
		columns, TaxGroupMapScript.MODE_STAPLE_CROP)
	if not bool(grouped.get("ok", false)):
		return PackedStringArray()
	var group_ids: PackedStringArray = grouped.get("group_ids", PackedStringArray())
	var group := group_ids.find(TaxGroupMapScript.STAPLE_GROUP_ID)
	if group < 0:
		return PackedStringArray()
	var indices: PackedInt32Array = grouped.get(
		"building_group_indices", PackedInt32Array())
	var out := PackedStringArray()
	for building in TaxGroupMapScript.buildings_in_group(indices, group):
		if building >= 0 and building < building_ids.size():
			out.append(building_ids[building])
	return out
