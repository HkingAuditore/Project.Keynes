extends RefCounted

## Builds ideology card descriptions, understanding, and resonance details.

const IdeologySupport = preload("res://scripts/ui/components/ideology_workspace_support.gd")


static func _card_data(host, ideology_id: int, in_collection: bool) -> Dictionary:
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var state: Dictionary = host._states.get(ideology_id, {})
	var live: Dictionary = host._live_by_id.get(ideology_id, {})
	var level = maxi(0, int(state.get("level", 0)))
	var location = int(state.get("location", 0))
	var pending = bool(state.get("pending", false))
	var view = CountryViewModel.present_ideology_card(meta, level,
		host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id))
	var stamp = ""
	if pending:
		stamp = "待生效"
	elif in_collection and location == 1:
		stamp = "推行中"
	elif in_collection and location == 2:
		stamp = "精神"
	var level_progress: Dictionary = host.LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var tooltip = PackedStringArray([host._display_name(meta, ideology_id), String(view.get("tooltip", ""))])
	if bool(level_progress.get("maxed", false)):
		tooltip.append("已至最高境界")
	else:
		tooltip.append("理解度 %s / %s" % [
			host._q16(int(level_progress.get("understanding_q16", 0))),
			host._q16(int(level_progress.get("threshold_q16", 0)))])
	tooltip.append(host._support_tooltip(live, 0 if location == 0 else 1))
	return {
		"ideology_id": ideology_id,
		"display_name": host._display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"rarity_label": String(meta.get("rarity_label", "")),
		"effects": view.get("effect_lines", PackedStringArray()),
		"level": level,
		"level_count": int(view.get("level_count", 3)),
		"level_label": String(view.get("level_label", "")),
		"level_progress": level_progress,
		"location": location,
		"pending": pending,
		"stamp_text": stamp,
		"tooltip": "\n".join(tooltip).strip_edges(),
		"detail_model": host._detail_data(ideology_id),
		"dimmed": in_collection and location != 0,
	}



static func _detail_data(host, ideology_id: int, offer := false) -> Dictionary:
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var state: Dictionary = {} if offer else host._states.get(ideology_id, {})
	var level = int(state.get("level", 0))
	var view = CountryViewModel.present_ideology_card(meta, level,
		host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id))
	var location = int(state.get("location", 0))
	var live: Dictionary = host._live_by_id.get(ideology_id, {})
	var supports: Array[Dictionary] = []
	var breakdown: Array[Dictionary] = []
	if not offer:
		supports = host._support_details(live, location)
		breakdown = IdeologySupport._support_breakdown(host, live, location)
	var notes = PackedStringArray()
	if not offer and location == 1:
		notes.append("晋升民族精神需达到第 %d 境。" % (int(meta.get("min_spirit_level", 2)) + 1))
	var requirements: PackedStringArray = meta.get("required_technology_names", PackedStringArray())
	if not requirements.is_empty():
		notes.append("需要科技：%s" % "、".join(requirements))
	var rivals: PackedStringArray = meta.get("exclusion_rivals", PackedStringArray())
	if not rivals.is_empty():
		notes.append("互斥理念：%s" % "、".join(rivals))
	var synergy = String(meta.get("synergy_tooltip", ""))
	if not synergy.is_empty():
		notes.append(synergy)
	var labels: PackedStringArray = meta.get("level_labels", PackedStringArray())
	return {"name": host._display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")), "rarity": int(meta.get("rarity", 1)),
		"status": "候选理念" if offer else "待生效" if bool(state.get("pending", false)) else "推行中" if location == 1 else "民族精神" if location == 2 else "尚未推行",
		"progress": {} if offer else host.LevelProgressScript.build(meta, state, String(view.get("level_label", ""))),
		"effects": view.get("effect_lines", PackedStringArray()),
		"next_effects": view.get("next_level_lines", PackedStringArray()),
		"next_level_label": String(labels[level + 1]) if level + 1 < labels.size() else "",
		"notes": notes, "supports": supports, "breakdown": breakdown}


# --- resonance and synergy threads ----------------------------------------


static func _id_set(host, ids: PackedInt32Array) -> Dictionary:
	var out = {}
	for value in ids:
		out[int(value)] = true
	return out



static func _progress_data(host, ideology_id: int) -> Dictionary:
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var state: Dictionary = host._states.get(ideology_id, {})
	var labels: PackedStringArray = meta.get("level_labels", PackedStringArray())
	var level = clampi(int(state.get("level", 0)), 0, 64)
	var label = String(labels[level]) if level < labels.size() else ""
	var progress = host.LevelProgressScript.build(meta, state, label)
	progress["accent"] = host.ArtScript.rarity_accent(int(meta.get("rarity", 1)))
	return progress



static func _school_counts(host, extra_id: int) -> Dictionary:
	var counts = {}
	for ideology_id in host._states:
		var state: Dictionary = host._states[ideology_id]
		if int(state.get("location", 0)) <= 0 and int(ideology_id) != extra_id:
			continue
		var school = String((host._metadata.get(int(ideology_id), {}) as Dictionary).get("school_id", ""))
		counts[school] = int(counts.get(school, 0)) + 1
	return counts



static func _update_resonance(host, _niche: Control, preview_id: int) -> void:
	var active_ids: PackedInt32Array = host._snapshot.get("active_synergy_ids", PackedInt32Array())
	var active = {}
	for value in active_ids:
		active[int(value)] = true
	var counts = host._school_counts(-1)
	var preview_counts = host._school_counts(preview_id) if preview_id >= 0 else counts
	var newly_active: Array[String] = []
	for school_id in host._resonance_views:
		var tiers: Array[Dictionary] = []
		for row_value in host._catalog.get("synergies", []) as Array:
			var row = row_value as Dictionary
			if String(row.get("school_id", "")) != school_id:
				continue
			var dense_id = int(row.get("dense_id", -1))
			var on = active.has(dense_id)
			tiers.append({"min_count": int(row.get("min_count", 0)), "active": on,
				"tooltip": String(row.get("tooltip", ""))})
			if on and not host._active_resonances.has(dense_id) and not host._active_resonances.is_empty():
				newly_active.append(String(school_id))
		tiers.sort_custom(host._tier_less)
		(host._resonance_views[school_id]).set_state(
			int(counts.get(school_id, 0)), int(preview_counts.get(school_id, 0)), tiers)
	var had_any = not host._active_resonances.is_empty()
	host._active_resonances = active.duplicate()
	host._active_resonances[-999] = true  # sentinel: first sync never celebrates
	if had_any and not host.motion_reduced():
		for school_id in newly_active:
			var view = host._resonance_views[school_id]
			view.celebrate()
