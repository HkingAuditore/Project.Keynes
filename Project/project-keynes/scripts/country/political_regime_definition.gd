class_name PoliticalRegimeDefinition
extends Resource

## Stable, country-owned political regime content.  The native runtime only
## receives the compiled dense id/capability columns; presentation remains in
## this resource so UI text never enters the simulation hot path.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var detail: String = ""
@export var icon_key: StringName = &"country.politics"
@export var capability_keys: PackedStringArray = PackedStringArray()
@export var effect_rows: Array[Resource] = []

func validate() -> String:
	if id.is_empty():
		return "political_regime_id_empty"
	if display_name.strip_edges().is_empty():
		return "political_regime_display_name_empty"
	var seen := {}
	for raw_key in capability_keys:
		var key := String(raw_key).strip_edges()
		if key.is_empty():
			return "political_regime_capability_empty"
		if seen.has(key):
			return "political_regime_capability_duplicate"
		seen[key] = true
	return ""

func presentation() -> Dictionary:
	return {
		"id": String(id),
		"display_name": display_name,
		"detail": detail,
		"icon_key": icon_key,
		"capability_keys": capability_keys.duplicate(),
		"effects": effect_rows.duplicate(),
	}
