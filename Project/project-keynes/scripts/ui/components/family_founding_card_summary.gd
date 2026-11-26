extends RefCounted

## Formats the visible candidate identity, origin, resources, and effects.


static func _origin_text(owner: FamilyFoundingCard, candidate: Dictionary) -> String:
	var parts := PackedStringArray()
	var building := String(candidate.get("building_display_name", "")).strip_edges()
	var profession := String(candidate.get("owner_profession_display_name", "")).strip_edges()
	if not building.is_empty():
		parts.append(building)
	if not profession.is_empty():
		parts.append(profession)
	return " · ".join(parts) if not parts.is_empty() else "待立新族"



static func _trait_names_text(owner: FamilyFoundingCard, candidate: Dictionary) -> String:
	var names: PackedStringArray = candidate.get("trait_display_names", PackedStringArray())
	var items: Array = candidate.get("trait_items", [])
	if names.is_empty():
		for item in items:
			if item is Dictionary:
				var name := String(item.get("name", "")).strip_edges()
				if not name.is_empty():
					names.append(name)
	return " · ".join(names) if not names.is_empty() else ""



static func _effect_short_text(owner: FamilyFoundingCard, candidate: Dictionary) -> String:
	var description := owner._current_effect_body(candidate)
	for prefix in ["成功开拓时，新地块会获得以下效果：", "成功开拓时，新地块获得以下效果：",
			"该家族分支所在的本地块会持续获得以下效果：", "该家族所在的本地块会持续获得以下效果："]:
		description = description.trim_prefix(prefix)
	var colon := description.find("：")
	if colon >= 0 and colon < 32:
		description = description.substr(colon + 1).strip_edges()
	if description.length() > 44:
		description = description.substr(0, 43) + "…"
	return description



static func _current_effect_body(owner: FamilyFoundingCard, candidate: Dictionary) -> String:
	var tiers: PackedStringArray = candidate.get("effect_prestige_descriptions", PackedStringArray())
	if tiers.is_empty():
		tiers = FamilyFoundingCard.FamilyBuffCopyScript.prestige_statements(
			String(candidate.get("effect_description", "")))
	var level := maxi(1, int(candidate.get("prestige_level", 1)))
	var presentation := FamilyFoundingCard.FamilyBuffCopyScript.founding_effect_rows(tiers)
	for row in presentation.get("rows", []):
		if int(row.get("level", 0)) == level:
			return String(row.get("body", "")).strip_edges()
	return ""



static func _meta_text(owner: FamilyFoundingCard, candidate: Dictionary) -> String:
	var parts := PackedStringArray()
	var cash := owner._candidate_cash(candidate)
	if cash >= 0.0:
		parts.append("现银 %s 万" % UITokens.format_compact_number_cn(cash, 2))
	var buildings := int(candidate.get("owned_buildings", 0))
	if buildings > 0:
		parts.append("产业 %d" % buildings)
	var assignable := int(candidate.get("assignable_population",
		candidate.get("available_population", -1)))
	if assignable >= 0:
		parts.append("可派 %s 人" % UITokens.format_compact_number_cn(float(assignable), 0))
	return " · ".join(parts)



static func _meta_badges(owner: FamilyFoundingCard, candidate: Dictionary) -> Array:
	var badges: Array = []
	var prestige := int(candidate.get("prestige_level", 0))
	if prestige > 0:
		badges.append({
			"text": "威望 %s" % owner._prestige_roman(prestige),
			"accent": UITokens.DOSSIER_OXBLOOD if prestige >= 3 else UITokens.DOSSIER_BRASS,
			"tooltip": "当前家族威望档位",
		})
	return badges



static func _candidate_cash(owner: FamilyFoundingCard, candidate: Dictionary) -> float:
	if candidate.has("cash_claim"):
		return maxf(0.0, float(candidate.get("cash_claim", 0)) / 10000.0)
	if candidate.has("cash"):
		return maxf(0.0, float(candidate.get("cash", 0)) / 10000.0)
	return -1.0
