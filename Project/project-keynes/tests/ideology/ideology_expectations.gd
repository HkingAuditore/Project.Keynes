extends RefCounted

const PATH := "res://tests/ideology/generated/card_expectations.json"

static var _by_card: Dictionary = {}
static var _loaded := false

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not parsed is Dictionary:
		return
	for entry_value in (parsed as Dictionary).get("cards", []):
		var entry: Dictionary = entry_value
		var key := String(entry.get("card", ""))
		if key.is_empty():
			continue
		if not _by_card.has(key):
			_by_card[key] = []
		(_by_card[key] as Array).append(entry)

static func level_rows(card_key: String, level: int) -> Array:
	_ensure_loaded()
	for entry_value in _by_card.get(card_key, []):
		var entry: Dictionary = entry_value
		if int(entry.get("level", 0)) == level:
			return entry.get("rows", [])
	return []

static func value(card_key: String, stat: String, level: int = 1,
		fallback: float = NAN) -> float:
	for row_value in level_rows(card_key, level):
		var row: Dictionary = row_value
		if String(row.get("stat", "")) == stat and row.has("value"):
			return float(row.value)
	return fallback

static func all_card_keys() -> PackedStringArray:
	_ensure_loaded()
	var out := PackedStringArray()
	for key in _by_card.keys():
		out.append(String(key))
	out.sort()
	return out
