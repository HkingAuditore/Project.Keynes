extends RefCounted

## Pure presentation of committed ideology data; owns no session state.

static func present_ideology(snapshot: Dictionary, catalog: Dictionary) -> Dictionary:
	var catalog_capacity := int(catalog.get("ideology_capacity", 0))
	var catalog_spirits := int(catalog.get("national_spirit_capacity", 0))
	var catalog_cost := int(catalog.get("offer_cost_q16", 65536))
	var materialized := bool(snapshot.get("materialized",
		snapshot.has("ideology_slots_capacity")))
	var slots_capacity := int(snapshot.get("ideology_slots_capacity", catalog_capacity))
	var spirit_capacity := int(snapshot.get("national_spirit_slots_capacity", catalog_spirits))
	if slots_capacity <= 0:
		slots_capacity = catalog_capacity
	if spirit_capacity <= 0:
		spirit_capacity = catalog_spirits
	var slots_max := maxi(slots_capacity, int(snapshot.get("ideology_slots_capacity_max",
		catalog.get("ideology_capacity_max", slots_capacity))))
	var spirits_max := maxi(spirit_capacity, int(snapshot.get(
		"national_spirit_slots_capacity_max",
		catalog.get("national_spirit_capacity_max", spirit_capacity))))
	# The escalating draw cost is authoritative in the native snapshot; the
	# flat catalog base is only a fallback before the first query lands.
	var offer_cost := int(snapshot.get("next_offer_cost_q16",
		snapshot.get("offer_cost_q16", catalog_cost)))
	var reroll_cost := int(snapshot.get("reroll_cost_q16", offer_cost >> 1))
	var points := int(snapshot.get("ideology_points_q16", 0))
	var offer_active := bool(snapshot.get("offer_active", false))
	var known: PackedInt32Array = snapshot.get("known_ids", PackedInt32Array())
	var can_open_offer := not offer_active and points >= offer_cost
	var baseline_ready := bool(snapshot.get("point_baseline_ready", false))
	var last_gain := int(snapshot.get("point_ledger_gain_q16", 0))
	# Keep the hint line empty unless the player is blocked.
	var offer_hint := ""
	if not offer_active and points < offer_cost:
		offer_hint = "理念点不足（%s / %s）" % [_q16_display(points), _q16_display(offer_cost)]
	# Slot milestones: aligned technology names, deltas and owned flags.
	var unlock_names: PackedStringArray = catalog.get("capacity_unlock_technology_names",
		catalog.get("capacity_unlock_technology_keys", PackedStringArray()))
	var unlock_ideology: PackedInt32Array = catalog.get("capacity_unlock_ideology_deltas",
		PackedInt32Array())
	var unlock_spirit: PackedInt32Array = catalog.get("capacity_unlock_spirit_deltas",
		PackedInt32Array())
	var unlock_owned: PackedByteArray = snapshot.get("capacity_unlock_owned", PackedByteArray())
	var unlocks: Array[Dictionary] = []
	for index in unlock_names.size():
		unlocks.append({
			"technology_name": String(unlock_names[index]),
			"ideology_delta": int(unlock_ideology[index]) if index < unlock_ideology.size() else 0,
			"spirit_delta": int(unlock_spirit[index]) if index < unlock_spirit.size() else 0,
			"owned": index < unlock_owned.size() and unlock_owned[index] != 0,
		})
	return {
		"points": points,
		"points_text": _q16_display(points),
		"materialized": materialized,
		"slots_used": int(snapshot.get("ideology_slots_used", 0)),
		"slots_capacity": slots_capacity,
		"slots_max": slots_max,
		"spirits_used": int(snapshot.get("national_spirit_slots_used", 0)),
		"spirits_capacity": spirit_capacity,
		"spirits_max": spirits_max,
		"capacity_unlocks": unlocks,
		"offer_cost_q16": offer_cost,
		"offer_cost_text": _q16_display(offer_cost),
		"reroll_cost_q16": reroll_cost,
		"reroll_cost_text": _q16_display(reroll_cost),
		"can_reroll": offer_active and points >= reroll_cost,
		"draw_sequence": int(snapshot.get("draw_sequence", 0)),
		"baseline_ready": baseline_ready,
		"last_gain_q16": last_gain,
		"lifetime_points_q16": int(snapshot.get("lifetime_points_q16", 0)),
		"point_history_q16": snapshot.get("point_history_q16", PackedInt64Array()),
		"active_synergy_ids": snapshot.get("active_synergy_ids", PackedInt32Array()),
		"offer_active": offer_active,
		"can_open_offer": can_open_offer,
		"offer_hint": offer_hint,
		"known_count": known.size(),
		"empty": known.is_empty() and not offer_active,
		"empty_title": "尚未形成国家理念",
		"empty_detail": "积累理念点后抽取。",
		"empty_insights": [],
	}


## `effect_row` is `IdeologyEffectReport.card_row()` for this card: how many
## reconciled effect instances it currently owns, and over how many targets.
## Empty when the caller has no report — an unowned card, or a facade without
## the native report. An empty row renders no badge at all, which is deliberate:
## "0 处" and "we did not look" must not look the same to the player.
static func present_ideology_card(metadata: Dictionary, level: int = 0,
		effect_row: Dictionary = {}) -> Dictionary:
	var effect_sets: Array = metadata.get("level_effect_lines", [])
	var current_lines := PackedStringArray()
	if level >= 0 and level < effect_sets.size():
		current_lines = PackedStringArray(effect_sets[level])
	elif not effect_sets.is_empty():
		current_lines = PackedStringArray(effect_sets[0])
	var insight_items: Array = []
	var icon := String(metadata.get("icon_key", "country.politics"))
	for line in current_lines:
		var text := String(line).strip_edges()
		if text.is_empty():
			continue
		insight_items.append({
			"text": text,
			"icon": icon,
			"accent": UITokens.RESOURCE,
		})
	var level_labels: PackedStringArray = metadata.get("level_labels", PackedStringArray())
	var badges: Array = []
	var rivals: PackedStringArray = metadata.get("exclusion_rivals", PackedStringArray())
	if not rivals.is_empty():
		badges.append({
			"text": "与%s互斥" % "、".join(rivals),
			"accent": UITokens.WARN,
			"tooltip": "同一秩序不能同时推行这些道路。",
		})
	var next_lines := PackedStringArray()
	if level + 1 < effect_sets.size():
		next_lines = PackedStringArray(effect_sets[level + 1])
		if not next_lines.is_empty():
			var next_label := String(level_labels[level + 1]) \
				if level + 1 < level_labels.size() else "%d级" % (level + 2)
			badges.append({
				"text": "下一境·%s" % next_label,
				"accent": UITokens.BRASS_HIGHLIGHT,
				"tooltip": "、".join(next_lines),
			})
	var synergy_names: PackedStringArray = metadata.get("synergy_names", PackedStringArray())
	if not synergy_names.is_empty():
		badges.append({
			"text": "联动 %s" % "、".join(synergy_names),
			"accent": UITokens.CLIMATE,
			"tooltip": String(metadata.get("synergy_tooltip", "")),
		})
	# "效果 N 处" rather than "命中 N 块地": one instance is one resolved target,
	# which is a cell for a cell-domain program and a country handle for a
	# country-domain one. The count is the same number either way; only the noun
	# would be a lie.
	var effect_tooltip := ""
	var instances := int(effect_row.get("instances", 0))
	if instances > 0:
		var targets := int(effect_row.get("target_count", 0))
		effect_tooltip = "效果实例 %d 处" % instances
		if targets > 0:
			effect_tooltip += "，覆盖 %d 个目标" % targets
		badges.append({
			"text": "效果 %d 处" % instances,
			"accent": UITokens.GOOD,
			"tooltip": effect_tooltip,
		})
	var requirement_names: PackedStringArray = metadata.get(
		"required_technology_names", PackedStringArray())
	var level_label := String(level_labels[level]) \
		if level >= 0 and level < level_labels.size() else ""
	var tooltip_lines := PackedStringArray()
	var detail := String(metadata.get("detail_key", ""))
	if not detail.is_empty() and not detail.contains("."):
		tooltip_lines.append(detail)
	if not level_label.is_empty():
		tooltip_lines.append("当前境界·%s：%s" % [level_label, "、".join(current_lines)])
	if not next_lines.is_empty():
		tooltip_lines.append("下一境：%s" % "、".join(next_lines))
	if not requirement_names.is_empty():
		tooltip_lines.append("需掌握：%s" % "、".join(requirement_names))
	if not rivals.is_empty():
		tooltip_lines.append("与%s互斥" % "、".join(rivals))
	if not synergy_names.is_empty():
		tooltip_lines.append(String(metadata.get("synergy_tooltip", "")))
	if not effect_tooltip.is_empty():
		tooltip_lines.append(effect_tooltip)
	return {
		"display_name": String(metadata.get("display_name",
			metadata.get("name_key", ""))),
		"detail": detail,
		"icon_key": icon,
		"school_id": String(metadata.get("school_id", "")),
		"rarity": int(metadata.get("rarity", 1)),
		"rarity_label": String(metadata.get("rarity_label", "")),
		"level_label": level_label,
		"level_count": maxi(1, effect_sets.size()),
		"effects": insight_items,
		"effect_lines": current_lines,
		"next_level_lines": next_lines,
		"badges": badges,
		"summary": "、".join(current_lines),
		"tooltip": "\n".join(tooltip_lines),
	}


static func _q16_display(value: int) -> String:
	return "%.2f" % (float(value) / 65536.0)


static func ideology_player_reason(reason: String) -> String:
	match reason:
		"ideology_points_insufficient":
			return "理念点不足。"
		"ideology_offer_pending":
			return "已有一次三选一待选择。"
		"ideology_offer_not_active":
			return ""
		"ideology_offer_pool_insufficient":
			return "当前没有可抽取的理念。"
		"ideology_offer_weight_invalid":
			return "暂时无法抽取理念。"
		"ideology_draw_in_progress":
			return "正在抽取。"
		"ideology_draw_timeout":
			return "抽取超时，请重试。"
		"ideology_runtime_unconfigured", "ideology_runtime_unavailable", \
				"DCWorldExt ideology API unavailable":
			return "理念事务暂不可用。"
		"ideology_country_handle_stale", "ideology_country_state_unavailable":
			return "国家数据已更新，请稍后重试。"
		"正在载入已提交数据":
			return "载入中…"
		_:
			return reason if not reason.is_empty() else "理念事务暂不可用。"
