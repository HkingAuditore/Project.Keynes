extends RefCounted

## Builds family dossier pages from copied display rows; deduplication preserves branch identity and never changes native family state.

static func family_workspace_model(detail: Dictionary) -> Dictionary:
	if detail.is_empty() or String(detail.get("kind", "")) != "family":
		return {}
	var row: Dictionary = detail.get("row", {})
	var traits := _family_unique_traits(row.get("trait_rows", []))
	var preferences := _family_unique_preferences(row.get("behavior_rows", []))
	var people := _family_unique_rows(row.get("notable_person_rows", []),
		["id", "handle", "name", "role", "profession", "building"])
	var branches := _family_unique_rows(row.get("branch_rows", []),
		["id", "cell", "prestige_level", "population_share_text",
		"cash_share_text", "building_share_text"])
	var effects: Array = []
	effects.append_array(row.get("effect_rows", []))
	effects.append_array(row.get("modifier_rows", []))
	effects.append_array(row.get("trigger_rows", []))
	effects = _family_unique_rows(effects,
		["cell", "kind", "id", "title", "name", "value", "detail"])
	var default_prestige_level := int(row.get("prestige_level", 0))
	for effect_idx in range(effects.size()):
		var eff: Dictionary = effects[effect_idx]
		if not eff.has("prestige_level"):
			eff["prestige_level"] = default_prestige_level
		if not eff.has("tier_statements") or (eff.get("tier_statements", []) as Array).is_empty():
			var raw_text := String(eff.get("detail", eff.get("value", "")))
			var parsed_tiers := FamilyBuffCopy.prestige_statements(raw_text)
			var tier_list: Array = []
			for st in parsed_tiers:
				tier_list.append(String(st))
			eff["tier_statements"] = tier_list
		effects[effect_idx] = eff
	effects.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var cell_a := int(a.get("cell", -1))
		var cell_b := int(b.get("cell", -1))
		if cell_a != cell_b:
			return cell_a < cell_b
		return String(a.get("kind", "")) < String(b.get("kind", "")))

	var sorted_preferences := preferences.duplicate(true)
	sorted_preferences.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var axis_a := int(a.get("axis", 99))
		var axis_b := int(b.get("axis", 99))
		if axis_a != axis_b:
			return axis_a < axis_b
		return String(a.get("name", "")) < String(b.get("name", "")))
	var overview_preferences := preferences.duplicate(true)
	overview_preferences.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("deviation", 0.0)) > float(b.get("deviation", 0.0)))

	var overview_traits: Array = []
	for trait_value in traits:
		if bool((trait_value as Dictionary).get("core", false)):
			overview_traits.append(trait_value)
			if overview_traits.size() >= 2:
				break
	if overview_traits.size() < 2:
		for trait_value in traits:
			if overview_traits.has(trait_value):
				continue
			overview_traits.append(trait_value)
			if overview_traits.size() >= 2:
				break

	var prestige_q16 := int(row.get("prestige_score_q16", 0))
	var prestige_percent := float(prestige_q16) * 100.0 / 65536.0
	var level := int(row.get("prestige_level", 0))
	var notable_count := maxi(int(row.get("notable_people", 0)), people.size())
	var branch_count := maxi(1, branches.size())
	var cash_text := String(row.get("cash_claim", ""))
	var asset_text := String(row.get("productive_asset_value", ""))
	var wealth_caption := "现金 %s · 产业 %s" % [cash_text, asset_text] \
		if not cash_text.is_empty() and not asset_text.is_empty() \
		else ("现金 %s" % cash_text if not cash_text.is_empty() else "家族名下净值")
	return {
		"kind": "family_workspace",
		"row_id": String(detail.get("row_id", "")),
		"header": {
			"name": String(detail.get("name", row.get("name", "家族"))),
			"subtitle": String(detail.get("subtitle", "")),
			"crest_icon": "family.workspace.crest",
			"prestige_level": level,
			"prestige_label": _prestige_text(level),
			"prestige_score_q16": prestige_q16,
			"prestige_percent": prestige_percent,
			"prestige_progress_text": _q16_percent_text(prestige_q16),
			"origin_settlement_name": String(row.get("origin_settlement_name", "")),
			"decline_reviews": int(row.get("decline_reviews", 0)),
		},
		"summary": [
			{"id": "population", "label": "本家族人口",
				"value": String(row.get("population", "0")),
				"caption": "分支 %d 处 · 名人 %d 人" % [branch_count, notable_count],
				"icon": "family.metric.population"},
			{"id": "net_worth", "label": "净资产",
				"value": String(row.get("net_worth", row.get("cash_claim", "0"))),
				"caption": wealth_caption,
				"icon": "family.metric.wealth"},
			{"id": "owned_buildings", "label": "产业数",
				"value": String(row.get("owned_buildings", "0")),
				"caption": "名下控股建筑规模",
				"icon": "family.metric.buildings"},
			{"id": "founded_day", "label": "创立时间",
				"value": "第%d日" % int(row.get("founded_day", 0)),
				"caption": "威望 %s · 得分 %s" % [_prestige_text(level), _q16_percent_text(prestige_q16)],
				"icon": "family.metric.time"},
		],
		"pages": {
			"overview": {
				"traits": overview_traits,
				"preferences": overview_preferences.slice(0, 4),
				"effects": effects.slice(0, 4),
				"people": people.slice(0, 5),
				"branches": branches.slice(0, 3),
			},
			"traits": traits,
			"preferences": sorted_preferences,
			"effects": effects,
			"people": people,
			"branches": branches,
		},
		"actions": {"family_handle": int(row.get("family_handle", 0))},
	}


static func _family_unique_traits(rows: Array) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for row_value in rows:
		if not row_value is Dictionary:
			continue
		var item := (row_value as Dictionary).duplicate(true)
		var detail_text := String(item.get("detail", ""))
		var detail_key := _family_text_key(detail_text)
		var effect_key := _family_text_key(item.get("effect_summary", ""))
		if not effect_key.is_empty() and effect_key == detail_key:
			item["effect_summary"] = ""
			effect_key = ""
		if not item.has("badges"):
			item["badges"] = FamilyBuffCopy.extract_trait_badges(detail_text)
		var stable_id := _family_text_key(item.get("id", ""))
		var key := "id:%s" % stable_id if not stable_id.is_empty() else \
			"%s|%s|%s" % [_family_text_key(item.get("name", "")),
			detail_key, effect_key]
		if seen.has(key):
			continue
		seen[key] = true
		result.append(item)
	return result


static func _family_unique_preferences(rows: Array) -> Array:
	var result: Array = []
	var result_index: Dictionary = {}
	for row_value in rows:
		if not row_value is Dictionary:
			continue
		var item := (row_value as Dictionary).duplicate(true)
		var factor_pct := float(item.get("factor_percent",
			_parse_leading_float(item.get("value", "100"), 100.0)))
		item["factor_percent"] = factor_pct
		if not item.has("factor_text"):
			item["factor_text"] = "%.1f%%" % factor_pct
		var axis := int(item.get("axis", 0))
		var stable_id := String(item.get("stable_id", ""))
		if stable_id.is_empty() and String(item.get("id", "")).contains(":"):
			stable_id = String(item.get("id", "")).get_slice(":", 1)
			item["stable_id"] = stable_id
		if not item.has("icon") or String(item.get("icon", "")).is_empty():
			item["icon"] = String(_family_behavior_icon(
				axis, stable_id, String(item.get("name", ""))))
		var signed_delta := factor_pct - 100.0
		item["signed_delta_percent"] = signed_delta
		item["delta_text"] = "%s%.0f%%" % [
			"+" if signed_delta >= 0.0 else "−", absf(signed_delta)]
		item["bar_ratio"] = clampf(factor_pct / 200.0, 0.0, 1.0)
		var axis_key := _family_text_key(item.get("axis", item.get("axis_name", "")))
		var key := "%s|%s" % [axis_key, _family_text_key(item.get("name", ""))]
		var deviation := absf(factor_pct - 100.0)
		item["deviation"] = deviation
		if not result_index.has(key):
			result_index[key] = result.size()
			result.append(item)
			continue
		var index := int(result_index[key])
		var current: Dictionary = result[index]
		var current_deviation := absf(
			float(current.get("factor_percent", 100.0)) - 100.0)
		if deviation > current_deviation:
			result[index] = item
	return result


static func _family_unique_rows(rows: Array, key_fields: Array) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for row_value in rows:
		if not row_value is Dictionary:
			continue
		var item := (row_value as Dictionary).duplicate(true)
		var parts: Array[String] = []
		for field_value in key_fields:
			parts.append(_family_text_key(item.get(str(field_value), "")))
		var key := "|".join(parts)
		if seen.has(key):
			continue
		seen[key] = true
		result.append(item)
	return result


static func _family_text_key(value: Variant) -> String:
	return str(value).strip_edges().replace(" ", "").replace("\n", "").replace("\r", "")


static func _parse_leading_float(text: Variant, fallback: float = 0.0) -> float:
	if text is float or text is int:
		return float(text)
	var raw := String(text).strip_edges().replace("−", "-").replace("+", "")
	if raw.is_empty() or raw == "—":
		return fallback
	var mult := 1.0
	if raw.find("亿") >= 0:
		mult = 100000000.0
	elif raw.find("万") >= 0:
		mult = 10000.0
	var num_str := ""
	var dot_seen := false
	for idx in range(raw.length()):
		var ch := raw[idx]
		if (ch >= "0" and ch <= "9") or (ch == "-" and num_str.is_empty()):
			num_str += ch
		elif ch == "." and not dot_seen:
			dot_seen = true
			num_str += ch
		elif not num_str.is_empty():
			break
	if num_str.is_empty() or num_str == "-" or num_str == ".":
		return fallback
	return float(num_str) * mult


static func _family_behavior_icon(axis: int, stable_id: String, name_text: String = "") -> StringName:
	match axis:
		0:
			if not stable_id.is_empty():
				if stable_id.contains("hearth"): return &"economy.building.hearth"
				if stable_id.contains("gathering"): return &"economy.building.gathering"
				if stable_id.contains("merchant") or stable_id.contains("market") or stable_id.contains("trade"): return &"economy.building.market"
				if stable_id.contains("fish"): return &"economy.building.fishing"
				if stable_id.contains("hunting"): return &"economy.building.hunting"
				if stable_id.contains("kitchen") or stable_id.contains("food") or stable_id.contains("slaughter"): return &"economy.building.food"
				if stable_id.contains("farm") or stable_id.contains("estate") or stable_id.contains("pasture") or stable_id.contains("rice") or stable_id.contains("wheat") or stable_id.contains("cotton") or stable_id.contains("flax"): return &"economy.building.farm"
				if stable_id.contains("timber") or stable_id.contains("lumber"): return &"economy.building.forestry"
				if stable_id.contains("mine") or stable_id.contains("ore") or stable_id.contains("quarry") or stable_id.contains("stone") or stable_id.contains("coal") or stable_id.contains("salt"): return &"economy.building.mine"
				if stable_id.contains("workshop") or stable_id.contains("kiln") or stable_id.contains("smith") or stable_id.contains("tailor") or stable_id.contains("tannery"): return &"economy.building.workshop"
				if stable_id.contains("plant") or stable_id.contains("works") or stable_id.contains("mill") or stable_id.contains("factory"): return &"economy.building.factory"
			if name_text.contains("农") or name_text.contains("田") or name_text.contains("牧"): return &"economy.building.farm"
			if name_text.contains("矿") or name_text.contains("石") or name_text.contains("盐"): return &"economy.building.mine"
			if name_text.contains("商") or name_text.contains("市") or name_text.contains("贸"): return &"economy.building.market"
			if name_text.contains("林") or name_text.contains("木"): return &"economy.building.forestry"
			if name_text.contains("猎"): return &"economy.building.hunting"
			if name_text.contains("渔"): return &"economy.building.fishing"
			return &"economy.building"
		1:
			var prof_icon := IconCatalog.profession_semantic(stable_id)
			if prof_icon != &"system.unknown":
				return prof_icon
			if name_text.contains("采集"): return &"profession.forager"
			if name_text.contains("猎"): return &"profession.hunter"
			if name_text.contains("商"): return &"profession.merchant"
			if name_text.contains("矿"): return &"profession.miner"
			if name_text.contains("农"): return &"profession.agricultural_worker"
			if name_text.contains("渔"): return &"profession.fisher"
			if name_text.contains("匠") or name_text.contains("工"): return &"profession.artisan"
			if name_text.contains("学") or name_text.contains("研"): return &"profession.scholar"
			return &"population.profession.worker"
		2:
			if stable_id.contains("food") or stable_id.contains("staple") or stable_id.contains("protein") or name_text.contains("食") or name_text.contains("饮") or name_text.contains("温饱"):
				return &"economy.building.food"
			if stable_id.contains("cloth") or name_text.contains("衣") or name_text.contains("服"):
				return &"good.clothing"
			if stable_id.contains("heat") or stable_id.contains("fuel") or name_text.contains("暖") or name_text.contains("火"):
				return &"economy.building.hearth"
			if stable_id.contains("hous") or stable_id.contains("shelter") or name_text.contains("居") or name_text.contains("宅"):
				return &"population.living.poor"
			if stable_id.contains("lux") or name_text.contains("奢") or name_text.contains("礼"):
				return &"population.living.luxury"
			return &"population.heart"
		3:
			var good_icon := IconCatalog.good_semantic(stable_id)
			if good_icon != &"system.unknown":
				return good_icon
			return &"metric.goods"
		_:
			return &"summary.overview"


static func _prestige_text(level: int) -> String:
	return ["0", "I", "II", "III", "IV", "V"][clampi(level, 0, 5)]


static func _q16_percent_text(value: int) -> String:
	return "%.1f%%" % (float(value) * 100.0 / 65536.0)
