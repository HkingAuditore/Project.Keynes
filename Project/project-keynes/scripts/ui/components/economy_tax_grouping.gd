extends RefCounted

## 国家财政总面板的多维度税收分组计算（所得税 / 交易税与关税 / 营业税）。
## 优先复用 TaxGroupMap 的统一轴表 SUBJECT_AXES 与 build_axis()（按时代/产业/产物/
## 产品线/物资三层/职业阶层），确保总面板、地方面板、对象详情三处组名一致；
## 在缺少编译期 catalog 列（例如轻量级 UI 测试）时，退回静态目录推导。

const TaxGroupMapScript := preload("res://scripts/country/tax_group_map.gd")
const TaxGoodCategoryMapScript := preload("res://scripts/country/tax_good_category_map.gd")
const CountryCatalogPresentation := preload("res://scripts/ui/country_catalog_presentation.gd")

const TAX_MODE_PERCENT_BP := 0
const TAX_MODE_ABSOLUTE := 1
const AXIS_FLAT := "flat"

const PROFESSION_CLASS_LABELS_ZH := {
	"farmer": "农民", "worker": "工人", "technology": "技术与学者",
	"military": "军事", "commerce": "商业", "merchant": "商业",
	"small_owner": "小业主", "major_owner": "大业主",
	"capitalist": "大业主", "landowner": "大业主", "general": "其他阶层",
}


static func subject_for_page(page: String) -> String:
	if page == "business":
		return TaxGroupMapScript.SUBJECT_BUILDING
	if page == "consumption":
		return TaxGroupMapScript.SUBJECT_GOOD
	return TaxGroupMapScript.SUBJECT_PROFESSION


static func id_column_for_page(page: String) -> String:
	if page == "business":
		return "building_type_ids"
	if page == "consumption":
		return "good_ids"
	return "profession_ids"


static func axes_for_page(page: String, has_columns: bool = true) -> Array:
	var axes: Array = []
	if has_columns:
		for axis_value in TaxGroupMapScript.axes_for_subject(subject_for_page(page)):
			axes.append(axis_value)
	axes.append({"id": AXIS_FLAT, "label": "不分组",
		"hint": "直接平铺显示全部卡片"})
	return axes


## 返回 [{id, label, item_ids}]；axis_id 为 flat 或无项时返回空数组。
static func build_groups(page: String, axis_id: String, card_ids: Array,
		_rows: Dictionary, columns: Dictionary) -> Array:
	if axis_id.is_empty() or axis_id == AXIS_FLAT or card_ids.is_empty():
		return []
	var subject := subject_for_page(page)
	var id_col := id_column_for_page(page)
	var member_ids: PackedStringArray = columns.get(id_col, PackedStringArray())
	if not columns.is_empty() and not member_ids.is_empty():
		var grouped: Dictionary = TaxGroupMapScript.build_axis(columns, axis_id, subject)
		if bool(grouped.get("ok", false)):
			return _intersect_with_cards(axis_id, grouped, member_ids, card_ids)
	return _fallback_static_groups(page, card_ids)


static func _intersect_with_cards(axis_id: String, grouped: Dictionary,
		member_ids: PackedStringArray, card_ids: Array) -> Array:
	var group_ids: PackedStringArray = grouped.get("group_ids", PackedStringArray())
	var group_labels: PackedStringArray = grouped.get("group_labels", PackedStringArray())
	var member_groups: PackedInt32Array = grouped.get("member_group_indices", PackedInt32Array())
	var known := {}
	for raw_id in card_ids:
		known[String(raw_id)] = true
	var out: Array = []
	for group in range(group_ids.size()):
		var ids := PackedStringArray()
		for member in TaxGroupMapScript.members_in_group(member_groups, group):
			if member < 0 or member >= member_ids.size():
				continue
			var stable := String(member_ids[member])
			if known.has(stable):
				ids.append(stable)
		if ids.is_empty():
			continue
		var raw_gid := String(group_ids[group])
		var label := String(group_labels[group]) if group < group_labels.size() else raw_gid
		out.append({
			"id": "%s:%s" % [axis_id, raw_gid],
			"label": label,
			"item_ids": ids,
		})
	return out


## 缺少编译期列时的静态兜底（按职业阶层或商品类别分组）。
static func _fallback_static_groups(page: String, card_ids: Array) -> Array:
	var kind_key := "profession" if page == "income" else ("good" if page == "consumption" else "building")
	var content: Dictionary = CountryCatalogPresentation._tax_content(kind_key)
	var grouped := {}
	var order: Array[String] = []
	for raw_id in card_ids:
		var item_id := String(raw_id)
		var meta: Dictionary = content.get(item_id, {})
		var gid := "all"
		var label := "全部项目"
		if page == "income":
			var cls := String(meta.get("profession_class_id", "general")).strip_edges()
			if cls.is_empty():
				cls = "general"
			gid = "prof:%s" % cls
			label = String(PROFESSION_CLASS_LABELS_ZH.get(cls, cls))
		elif page == "consumption":
			var cat := String(meta.get("category_id", "")).strip_edges()
			if not cat.is_empty():
				var mapped := TaxGoodCategoryMapScript.group_for_category(cat)
				gid = "cat:%s" % (mapped if not mapped.is_empty() else cat)
				label = TaxGoodCategoryMapScript.label_for_group(mapped) if not mapped.is_empty() else cat
		if not grouped.has(gid):
			grouped[gid] = {"id": gid, "label": label, "item_ids": PackedStringArray()}
			order.append(gid)
		(grouped[gid]["item_ids"] as PackedStringArray).append(item_id)
	var out: Array = []
	for key in order:
		out.append(grouped[key])
	return out
