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


static func founding_effect_preview(statements: PackedStringArray,
		fallback: String = "") -> String:
	if not statements.is_empty():
		var first := String(statements[0]).strip_edges()
		if not first.is_empty():
			return first
	var clean := fallback.strip_edges()
	if clean.begins_with("当前未达威望"):
		return ""
	return clean


static func extract_trait_badges(description: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var clean := description.strip_edges()
	if clean.is_empty():
		return out
	var regex := RegEx.new()
	regex.compile("(增加|提高|提升|扩大|偏爱|减少|降低|缩减|排斥)\\s*([0-9]+(?:\\.[0-9]+)?%?)")
	for m in regex.search_all(clean):
		var verb := m.get_string(1)
		var amount := m.get_string(2)
		var positive := verb in ["增加", "提高", "提升", "扩大", "偏爱"]
		var prefix := "+" if positive else "-"
		out.append({
			"text": "%s%s" % [prefix, amount],
			"positive": positive,
			"delta": float(amount.trim_suffix("%")) * (1.0 if positive else -1.0),
		})
	return out


## 展示层去重：仅在各级的完整前缀一致时提取共同条件；不同条件完整保留。
static func founding_effect_rows(statements: PackedStringArray) -> Dictionary:
	var rows: Array[Dictionary] = []
	var shared := ""
	var same := statements.size() > 1
	for index in statements.size():
		var original := statements[index].strip_edges()
		var body := original
		var label_end := body.find("：")
		if body.begins_with("威望") and label_end >= 0:
			body = body.substr(label_end + 1).strip_edges()
		var split := body.find("：")
		var context := body.substr(0, split + 1) if split >= 0 else ""
		if index == 0:
			shared = context
		elif context != shared:
			same = false
		rows.append({"level": index + 1, "body": body, "original": original})
	if not same or shared.is_empty():
		shared = ""
	else:
		for row in rows:
			row["body"] = String(row["body"]).trim_prefix(shared).strip_edges()
	return {"context": shared.trim_suffix("："), "rows": rows}


static func trait_factor_percent(description: String,
		strength_ratio: float = 0.65) -> float:
	var badges := extract_trait_badges(description)
	if not badges.is_empty():
		var delta := float(badges[0].get("delta", 0.0))
		return clampf(100.0 + delta, 15.0, 200.0)
	return clampf(70.0 + clampf(strength_ratio, 0.0, 1.0) * 90.0, 15.0, 200.0)


static func axis_short_label(axis: int) -> String:
	match axis:
		0:
			return "产业投资"
		1:
			return "职业从业"
		2:
			return "民生消费"
		3:
			return "偏好物资"
		_:
			return "家风门风"


static func _format_quantity(value: float) -> String:
	var scaled: float = snapped(value, 0.1)
	if is_equal_approx(scaled, round(scaled)):
		return str(int(round(scaled)))
	return String.num(scaled, 1)
