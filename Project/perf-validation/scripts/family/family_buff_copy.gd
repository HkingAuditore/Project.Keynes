class_name FamilyBuffCopy
extends RefCounted

## Player-facing family buff copy. Display-only; never enters catalog hash.


static func interpolate_preference(template: String, range_text: String,
		strength_q16: int, strength_min_q16: int, strength_max_q16: int) -> String:
	var filled := template.strip_edges()
	if filled.is_empty():
		filled = range_text.strip_edges()
	var span := strength_max_q16 - strength_min_q16
	var t := 0.0 if span <= 0 else clampf(
		float(strength_q16 - strength_min_q16) / float(span), 0.0, 1.0)
	var regex := RegEx.new()
	regex.compile("([A-Z])∈\\[(-?[0-9]+(?:\\.[0-9]+)?)(%?)[,，]\\s*(-?[0-9]+(?:\\.[0-9]+)?)(%?)\\]")
	for found in regex.search_all(range_text):
		var symbol: String = found.get_string(1)
		var lo: float = float(found.get_string(2))
		var hi: float = float(found.get_string(4))
		var unit: String = found.get_string(3)
		if unit.is_empty():
			unit = found.get_string(5)
		var rendered: String = _format_quantity(lo + (hi - lo) * t) + unit
		if unit == "%":
			filled = filled.replace(symbol + "%", rendered)
		filled = filled.replace(symbol, rendered)
	return filled


static func prestige_statements(full_text: String,
		authored: Variant = null) -> PackedStringArray:
	var copied := PackedStringArray()
	if authored is PackedStringArray:
		copied = authored
	elif authored is Array:
		for item in authored:
			copied.append(String(item).strip_edges())
	if copied.size() >= 5:
		var trimmed := PackedStringArray()
		for index in range(5):
			trimmed.append(String(copied[index]).strip_edges())
		return trimmed
	var text := full_text.replace("<br>", "\n").replace("<br/>", "\n").strip_edges()
	var labels := ["威望Ⅰ", "威望Ⅱ", "威望Ⅲ", "威望Ⅳ", "威望Ⅴ"]
	var starts: Array[int] = []
	for label in labels:
		var found := text.find(label)
		if found < 0:
			return copied
		starts.append(found)
	var statements := PackedStringArray()
	for index in range(starts.size()):
		var start := int(starts[index])
		var end := text.length() if index + 1 >= starts.size() else int(starts[index + 1])
		statements.append(text.substr(start, end - start).strip_edges())
	return statements


static func statement_for_prestige(statements: PackedStringArray,
		prestige_level: int) -> String:
	if statements.is_empty():
		return ""
	if prestige_level <= 0:
		return "当前未达威望Ⅰ。"
	var index := clampi(prestige_level, 1, statements.size()) - 1
	return String(statements[index])


static func join_prestige(statements: PackedStringArray, fallback: String = "") -> String:
	if statements.is_empty():
		return fallback.strip_edges()
	return "\n".join(statements)


static func _format_quantity(value: float) -> String:
	var scaled: float = snapped(value, 0.1)
	if is_equal_approx(scaled, round(scaled)):
		return str(int(round(scaled)))
	return String.num(scaled, 1)
