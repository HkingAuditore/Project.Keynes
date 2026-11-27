extends RefCounted

## Routes high-density list blocks of a tile inspector tab into the optional
## left wing (`ListShell`) on wide desktop viewports, while keeping overview
## metrics, gauges, and tax controls in the right dossier column.

const GEOGRAPHY_WING_SECTIONS := ["natural_resources", "biogeography"]
const TAB_WING_ROW_KEYS := {
	"population": "cohort_rows",
	"market": "market_rows",
	"buildings": "building_rows",
}


static func split_category(tab_id: String, data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {"right": data, "left": {}, "has_left": false}
	if tab_id == "geography":
		return _split_geography(data)
	if TAB_WING_ROW_KEYS.has(tab_id):
		return _split_row_list_tab(data, String(TAB_WING_ROW_KEYS[tab_id]))
	return {"right": data, "left": {}, "has_left": false}


static func _split_geography(data: Dictionary) -> Dictionary:
	var sections: Array = data.get("sections", [])
	if sections.is_empty():
		return {"right": data, "left": {}, "has_left": false}
	var right_sections: Array = []
	var left_sections: Array = []
	for raw_section in sections:
		var section: Dictionary = raw_section
		var section_id := String(section.get("id", ""))
		if GEOGRAPHY_WING_SECTIONS.has(section_id):
			left_sections.append(section)
		else:
			right_sections.append(section)
	if left_sections.is_empty():
		return {"right": data, "left": {}, "has_left": false}
	var right_data := data.duplicate(false)
	right_data["sections"] = right_sections
	var left_data := {"sections": left_sections}
	return {"right": right_data, "left": left_data, "has_left": true}


static func _split_row_list_tab(data: Dictionary, row_key: String) -> Dictionary:
	if not data.has(row_key):
		return {"right": data, "left": {}, "has_left": false}
	var rows: Array = data.get(row_key, [])
	if rows.is_empty():
		return {"right": data, "left": {}, "has_left": false}
	var right_data := data.duplicate(false)
	var left_data := {}
	left_data[row_key] = rows
	right_data.erase(row_key)
	for extra_key in ["list_header", "list_caption"]:
		if data.has(extra_key):
			left_data[extra_key] = data.get(extra_key)
			right_data.erase(extra_key)
	return {"right": right_data, "left": left_data, "has_left": true}
