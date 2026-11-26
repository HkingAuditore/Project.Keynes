extends RefCounted

const TaxGroupMapScript := preload("res://scripts/country/tax_group_map.gd")


## 税收面板（对象详情 / 地方面板）的「整组调税」轴：不再自成一套，直接从
## tax_group_map.gd 的 SUBJECT_AXES 取——总面板 economy_workspace.gd 读的也是那一份。
## 旧的「按大类 / 按主粮农场」两条已并入「按产业 / 按产物」，不留两套分类并存。
## subject 决定这一屏该给哪一组轴：建筑→时代/产物/产品线/产业/生产档位，
## 物资→三层/时代/产品线/产业，职业→阶层/产业。
static func tax_group_axes(subject: String = TaxGroupMapScript.SUBJECT_BUILDING) -> Array:
	return TaxGroupMapScript.axes_for_subject(subject)


## 把 catalog 列整理成税分组需要的形状。只要求有建筑 id 列——新轴全部读
## 编译产物的现成列（see economy_facade_display.gd::construction_type_columns），
## 不再为旧 build() 的业主列补占位。
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
	return columns


## 取 item_id 这个项目在某个分组轴下所属的整组。
## 返回 {ok, mode, group, group_id, label, item_ids, count, group_count}；失败返回 {}。
## 与总面板同源：同一个 build_axis，同一套中文组名，不在这里另算一遍分组。
static func tax_group_ids_for(controller, mode: String, item_id: String,
		subject: String = TaxGroupMapScript.SUBJECT_BUILDING) -> Dictionary:
	var columns := _tax_group_columns(controller)
	if columns.is_empty():
		return {}
	var member_ids: PackedStringArray = columns.get(_id_column(subject),
		PackedStringArray())
	if member_ids.is_empty():
		return {}
	var member := member_ids.find(item_id)
	if member < 0:
		return {}
	var grouped: Dictionary = TaxGroupMapScript.build_axis(columns, mode, subject)
	if not bool(grouped.get("ok", false)):
		return {}
	var group_ids: PackedStringArray = grouped.get("group_ids", PackedStringArray())
	var group_labels: PackedStringArray = grouped.get(
		"group_labels", PackedStringArray())
	var indices: PackedInt32Array = grouped.get(
		"member_group_indices", PackedInt32Array())
	if member >= indices.size():
		return {}
	var group := int(indices[member])
	if group < 0 or group >= group_ids.size():
		return {}
	var out := PackedStringArray()
	for member_index in TaxGroupMapScript.members_in_group(indices, group):
		if member_index >= 0 and member_index < member_ids.size():
			out.append(member_ids[member_index])
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


## 主体决定读哪一份 id 列（建筑 / 物资 / 职业三套）。
static func _id_column(subject: String) -> String:
	match subject:
		TaxGroupMapScript.SUBJECT_GOOD:
			return "good_ids"
		TaxGroupMapScript.SUBJECT_PROFESSION:
			return "profession_ids"
	return "building_type_ids"
