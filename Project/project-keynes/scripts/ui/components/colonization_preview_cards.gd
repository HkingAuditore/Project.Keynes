extends RefCounted

static func _paint_waiting_guide(host) -> void:
	host._show_preview_cards(true, false, false, false, false)
	if host._directory_mode and host._target_cell >= 0:
		host._guide_title.text = "目的地"
		host._guide_facts.set_facts([{"id": "target", "title": "前往", "value": host._cell_name(host._target_cell),
			"icon": "system.target", "accent": UITokens.DOSSIER_BRASS}])
		host._guide_notes.set_notes([])
		host._guide_notes.visible = false
		return
	if host._guide_title != null:
		host._guide_title.text = "开拓"
	if host._guide_facts != null:
		var source_name = host._source_city.text if host._source_city != null and host._source_filter >= 0 else "待选"
		host._guide_facts.set_facts([
			{"id": "source", "title": "出发", "value": source_name,
				"subtitle": "", "icon": "metric.territory",
				"accent": UITokens.DOSSIER_VERDIGRIS},
			{"id": "family", "title": "世家", "value": "待选",
				"subtitle": "", "icon": "family.house",
				"accent": UITokens.DOSSIER_BRASS},
			{"id": "target", "title": "目的地", "value": host._cell_name(host._target_cell) if host._target_cell >= 0 else "待选",
				"subtitle": "", "icon": "system.target",
				"accent": UITokens.DOSSIER_BRASS},
		])
	if host._guide_notes != null:
		host._guide_notes.set_notes([])
		host._guide_notes.visible = false


static func _paint_identity_card(host, quote: Dictionary, branch: Dictionary, hovering: bool,
		traits: Dictionary, effects: Dictionary) -> void:
	host._show_preview_cards(false, true, host._route_block.visible if host._route_block != null else false, true, true)
	host._pulse_identity_card(hovering)
	var people = float(branch.get("populations", quote.get("population",
		int(quote.get("maximum_population", 0)) + 1)))
	var maximum = float(quote.get("maximum_population", 0))
	var prestige_value: Variant = branch.get("prestige_levels", quote.get("prestige_level", 0))
	var prestige_number = float(prestige_value) if typeof(prestige_value) in [TYPE_INT, TYPE_FLOAT] else 0.0
	var buildings = str(branch.get("owned_buildings", quote.get("owned_buildings", "—")))
	var cash = float(branch.get("cash_claims", quote.get("cash_claim", 0))) / 10000.0
	var city_index = host._source_city.get_item_index(int(quote.get("source_cell", host._source_filter)))
	var city_name = host._source_city.get_item_text(city_index) if city_index >= 0 else host._cell_name(int(quote.get("source_cell", -1)))
	if host._preview_crest != null:
		host._preview_crest.set_semantic(
			&"family.workspace.crest" if prestige_number >= 1.0 else &"family.house",
			UITokens.DOSSIER_OXBLOOD if prestige_number >= 3.0 else UITokens.DOSSIER_BRASS)
	if host._preview_origin != null:
		host._preview_origin.text = city_name
	if host._preview_state_pill != null:
		host._preview_state_pill.text = ""
		host._preview_state_pill.visible = false
	host._paint_quick_read(traits, effects if not effects.is_empty() else traits)
	if host._preview_facts != null:
		host._preview_facts.set_facts([
			{"id": "people", "title": "",
				"value": UITokens.format_compact_number_cn(people, 0),
				"subtitle": "", "icon": "family.metric.population",
				"accent": UITokens.DOSSIER_OXBLOOD},
			{"id": "works", "title": "",
				"value": buildings, "subtitle": "", "icon": "economy.building",
				"accent": UITokens.DOSSIER_UMBER},
			{"id": "cash", "title": "",
				"value": UITokens.format_compact_number_cn(cash, 2),
				"subtitle": "", "icon": "metric.treasury",
				"accent": UITokens.DOSSIER_BRASS},
		])
	if host._preview_meters != null:
		host._preview_meters.set_meters([])


static func _paint_quick_read(host, traits: Dictionary, effects: Dictionary) -> void:
	if host._preview_trait_summary == null or host._preview_effect_summary == null:
		return
	var trait_names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var trait_descriptions: PackedStringArray = traits.get("descriptions", PackedStringArray())
	var trait_parts = PackedStringArray()
	for index in mini(trait_names.size(), 2):
		var trait_name = String(trait_names[index]).strip_edges()
		if not trait_name.is_empty():
			trait_parts.append("[b]%s[/b]" % host._bbcode_escape(trait_name))
	if trait_names.size() > 2:
		trait_parts.append("[color=#%s]另 %d 项[/color]" % [
			UITokens.DOSSIER_INK_MUTED.to_html(false), trait_names.size() - 2])
	host._preview_trait_summary.text = "  ·  ".join(trait_parts) if not trait_parts.is_empty() \
		else "[color=#%s]家风：无[/color]" % UITokens.DOSSIER_INK_MUTED.to_html(false)
	var trait_tooltip = PackedStringArray()
	for index in trait_names.size():
		var description = String(trait_descriptions[index]).strip_edges() \
			if index < trait_descriptions.size() else ""
		trait_tooltip.append("%s：%s" % [String(trait_names[index]), description])
	host._preview_trait_summary.tooltip_text = "\n".join(trait_tooltip)

	var effect_names: PackedStringArray = effects.get("effect_display_names", PackedStringArray())
	var effect_copy: PackedStringArray = effects.get("effect_current_descriptions",
		effects.get("effect_descriptions", PackedStringArray()))
	var effect_parts = PackedStringArray()
	if not effect_names.is_empty():
		effect_parts.append("[b]%s[/b]" % host._bbcode_escape(String(effect_names[0])))
		if not effect_copy.is_empty():
			var current = host._compact_effect_text(String(effect_copy[0]))
			if not current.is_empty():
				effect_parts.append(host._highlight_effect_metrics(current))
		if effect_names.size() > 1:
			effect_parts.append("[color=#%s]另 %d 项[/color]" % [
				UITokens.DOSSIER_INK_MUTED.to_html(false), effect_names.size() - 1])
	host._preview_effect_summary.text = "  ·  ".join(effect_parts) if not effect_parts.is_empty() \
		else "[color=#%s]效果：无[/color]" % UITokens.DOSSIER_INK_MUTED.to_html(false)
	var effect_tooltip = PackedStringArray()
	for index in effect_names.size():
		var description = String(effect_copy[index]).strip_edges() \
			if index < effect_copy.size() else ""
		effect_tooltip.append("%s：%s" % [String(effect_names[index]), description])
	host._preview_effect_summary.tooltip_text = "\n".join(effect_tooltip)


static func _pulse_identity_card(host, hovering: bool) -> void:
	if host._identity_card == null or not hovering or UIAnimation.reduced_motion():
		return
	if host._identity_pulse_tween != null and host._identity_pulse_tween.is_valid():
		host._identity_pulse_tween.kill()
	host._identity_card.modulate = Color(1.035, 1.02, 0.975, 1.0)
	host._identity_pulse_tween = host.create_tween()
	host._identity_pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	host._identity_pulse_tween.tween_property(host._identity_card, "modulate", Color.WHITE, 0.16)


static func _paint_trait_card(host, traits: Dictionary) -> void:
	var names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var descriptions: PackedStringArray = traits.get("descriptions", PackedStringArray())
	var core: PackedByteArray = traits.get("core", PackedByteArray())
	var show = not names.is_empty()
	if host._traits_block != null:
		host._traits_block.visible = show
	if not show:
		return
	var meters: Array = []
	for index in range(names.size()):
		var description = descriptions[index] if index < descriptions.size() else ""
		var is_core = index < core.size() and core[index] != 0
		var factor = FamilyBuffCopy.trait_factor_percent(description)
		var badges: Array[Dictionary] = FamilyBuffCopy.extract_trait_badges(description)
		var readout = str(badges[0].get("text", "")) if not badges.is_empty() else ""
		meters.append({
			"id": "trait-%d" % index,
			"label": String(names[index]),
			"value": clampf(factor / 200.0, 0.0, 1.0),
			"value_text": readout,
			"status_label": "",
			"tooltip": description,
			"accent": UITokens.RISK if is_core else UITokens.WARN,
		})
	if host._trait_meters != null:
		host._trait_meters.set_meters(meters)
	var preferences: PackedStringArray = traits.get("behavior_selector_display_names", PackedStringArray())
	var pref_kicker = host.get_node_or_null("%PrefKicker") as Label
	if pref_kicker != null:
		pref_kicker.visible = not preferences.is_empty()
	if host._pref_badges != null:
		host._pref_badges.visible = not preferences.is_empty()
		var badges: Array = []
		for preference in preferences:
			badges.append({"text": String(preference), "accent": UITokens.DOSSIER_BRASS})
		host._pref_badges.set_badges(badges)


static func _paint_effect_card(host, effects: Dictionary) -> void:
	var names: PackedStringArray = effects.get("effect_display_names", PackedStringArray())
	var copy: PackedStringArray = effects.get("effect_current_descriptions",
		effects.get("effect_descriptions", PackedStringArray()))
	var show = true
	if host._effects_block != null:
		host._effects_block.visible = show
	if host._effect_notes == null:
		return
	var notes: Array = []
	if names.is_empty():
		notes.append({
			"id": "effect-none",
			"text": "独特效果：无",
			"accent": UITokens.DOSSIER_INK_MUTED,
		})
	for index in range(mini(names.size(), 4)):
		var description = String(copy[index]) if index < copy.size() else ""
		var text = String(names[index])
		if not description.is_empty():
			text += " · " + description
		notes.append({
			"id": "effect-%d" % index,
			"text": text,
			"accent": UITokens.DOSSIER_VERDIGRIS if index == 0 else UITokens.DOSSIER_UMBER,
		})
	host._effect_notes.set_notes(notes)


static func _preview_party_count(host, quote: Dictionary) -> float:
	if not host._preview_hovering and host._population != null and not host._selected_quote.is_empty():
		return float(host._population.value)
	return float(quote.get("maximum_population", 0))


static func _paint_route_card(host, quote: Dictionary) -> void:
	if host._route_block == null:
		return
	if host._preview_family <= 0 and host._selected_quote.is_empty():
		return
	host._route_block.visible = true
	var waiting = host._target_cell < 0
	if host._route_ready_pill != null:
		if waiting:
			host._route_ready_pill.text = "待选点"
		elif bool(quote.get("kit_partial", false)) and bool(quote.get("kit_place_buildings", false)):
			host._route_ready_pill.text = "先筹备"
		elif bool(quote.get("kit_partial", false)):
			host._route_ready_pill.text = "基础物资"
		else:
			host._route_ready_pill.text = "可安家"
	if host._route_facts != null:
		host._route_facts.set_facts([
			{"id": "target", "title": "目的地", "value": host._cell_name(host._target_cell),
				"subtitle": "", "icon": "system.target",
				"accent": UITokens.DOSSIER_BRASS},
			{"id": "days", "title": "行程",
				"value": "待计算" if waiting else "%d 日" % int(quote.get("travel_days", 1)),
				"subtitle": "", "icon": "family.metric.time",
				"accent": UITokens.DOSSIER_UMBER},
			{"id": "party", "title": "随行",
				"value": UITokens.format_compact_number_cn(host._preview_party_count(quote), 0),
				"subtitle": "", "icon": "family.metric.population",
				"accent": UITokens.DOSSIER_OXBLOOD},
		])
	var badges = host._kit_badge_items(quote)
	if host._kit_badges != null:
		host._kit_badges.visible = not badges.is_empty()
		host._kit_badges.set_badges(badges)
	var kicker = host.get_node_or_null("%KitKicker") as Label
	if kicker != null:
		kicker.visible = not badges.is_empty()
	if host._route_notes != null:
		# 路线状态由 pill / facts / kit badges 表达，不再附修饰性引导批注。
		host._route_notes.set_notes([])
		host._route_notes.visible = false


static func _kit_badge_items(host, quote: Dictionary) -> Array:
	var badges: Array = []
	var names: PackedStringArray = quote.get("kit_building_display_names", PackedStringArray())
	var counts: PackedInt64Array = quote.get("kit_building_counts", PackedInt64Array())
	for index in range(names.size()):
		var label = String(names[index]).strip_edges()
		if label.is_empty() or label.contains("_") or label.contains("."):
			continue
		var count = int(counts[index]) if index < counts.size() else 1
		badges.append({"text": "%s ×%d" % [label, count], "accent": UITokens.DOSSIER_VERDIGRIS})
	var professions: PackedStringArray = quote.get("profession_display_names", PackedStringArray())
	var populations: PackedInt64Array = quote.get("profession_populations", PackedInt64Array())
	for index in range(professions.size()):
		var label = String(professions[index]).strip_edges()
		if label.is_empty() or label.contains("_") or label.contains("."):
			continue
		var count = int(populations[index]) if index < populations.size() else 0
		var text = label if count <= 0 else "%s %s人" % [label, UITokens.format_compact_number_cn(float(count), 0)]
		badges.append({"text": text, "accent": UITokens.DOSSIER_BRASS})
	return badges


static func _paint_expedition_card(host, title: String, metrics: String, effects: String, route: String) -> void:
	host._show_preview_cards(false, true, true, false, false)
	host._preview_title.text = title
	host._preview_route.text = route
	(host.get_node("%PreviewQuickRead") as Control).visible = false
	if host._preview_origin != null:
		host._preview_origin.text = metrics
	if host._preview_state_pill != null:
		host._preview_state_pill.text = "在途"
		host._preview_state_pill.visible = true
	if host._preview_crest != null:
		host._preview_crest.set_semantic(&"action.history", UITokens.DOSSIER_BRASS)
	if host._preview_facts != null:
		host._preview_facts.visible = false
	if host._route_ready_pill != null:
		host._route_ready_pill.text = "在途"
	if host._route_notes != null:
		if effects.is_empty():
			host._route_notes.set_notes([])
			host._route_notes.visible = false
		else:
			host._route_notes.visible = true
			host._route_notes.set_notes([{
				"id": "block", "text": effects, "accent": UITokens.DOSSIER_BRASS,
			}])
	if host._kit_badges != null:
		host._kit_badges.visible = false
	var kicker = host.get_node_or_null("%KitKicker") as Label
	if kicker != null:
		kicker.visible = false
