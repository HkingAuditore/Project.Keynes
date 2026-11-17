extends RefCounted

const ROW_LIST_KEYS := ["family_rows", "cohort_rows", "resource_rows",
	"market_rows", "building_rows"]

static func _category_structure(data: Dictionary) -> String:
	var parts := PackedStringArray()
	for key in ["insights", "metrics", "gauges", "construction_entry", "military_cell"] \
			+ ROW_LIST_KEYS:
		if data.has(key):
			parts.append(String(key))
	if not (data.get("badges", []) as Array).is_empty():
		parts.append("badges:%d" % (data["badges"] as Array).size())
	for key in ROW_LIST_KEYS:
		if data.has("list_header") and not (data.get(key, []) as Array).is_empty():
			parts.append("header:%s:%s" % [key, str(data.get("list_header", {}))])
	if data.has("list_caption"):
		parts.append("caption")
	for chart in data.get("charts", []):
		parts.append("chart:%s" % String((chart as Dictionary).get("id", "")))
	for section in data.get("sections", []):
		parts.append("section:%s:%s" % [String((section as Dictionary).get("id", "")),
			_category_structure(section)])
	parts.append("tax:%s" % str((data.get("tax_context", {}) as Dictionary).get("available", false)))
	return "|".join(parts)


static func _tabs_signature(tabs: Array) -> String:
	var ids := PackedStringArray()
	for raw in tabs:
		var tab: Dictionary = raw
		ids.append(String(tab.get("id", "")))
	return "|".join(ids)
