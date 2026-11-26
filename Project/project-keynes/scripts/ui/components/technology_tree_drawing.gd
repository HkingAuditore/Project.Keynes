extends RefCounted

## Draws the research layout's lanes, links, and node cards.


static func _draw_bands(owner: TechnologyTreeView) -> void:
	var font := owner.get_theme_default_font()
	var paper_domain_id := owner._paper_domain_id()
	for band_value in owner._focus_layout.get("bands", []) as Array:
		var band: Dictionary = band_value
		var rect: Rect2 = band.rect
		var focus := bool(band.get("is_focus", false))
		owner.draw_rect(rect, TechnologyTreeView.BAND_PAPER_FOCUS if focus else TechnologyTreeView.BAND_PAPER_ADJACENT, true)
		if focus:
			owner.draw_line(Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.end.y),
				UITokens.DOSSIER_RULE, 1.0)
		var label := String(band.get("display_name", ""))
		var colour := UITokens.DOSSIER_INK if focus else UITokens.DOSSIER_INK_MUTED
		var serif := UITokens.dossier_font("serif")
		var label_w := serif.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			TechnologyTreeView.ERA_FONT_SIZE).x
		# Era title sits on an unrolled handscroll; the rule continues to its right.
		var scroll := Rect2(rect.position + Vector2(2.0, 1.0),
			Vector2(minf(rect.size.x - 4.0, label_w + 72.0), TechnologyTreeView.ERA_SCROLL_HEIGHT))
		var scrolled := TechnologyTreeView.Art.draw_plate(owner, TechnologyTreeView.Art.ERA_SCROLL, scroll,
			Color.WHITE if focus else Color(0.92, 0.88, 0.80, 0.82), false)
		var rule_y := rect.position.y + TechnologyTreeView.ERA_SCROLL_HEIGHT * 0.5 + 1.0
		owner.draw_line(Vector2(scroll.end.x + 4.0 if scrolled else rect.position.x, rule_y),
			Vector2(rect.end.x, rule_y),
			UITokens.DOSSIER_RULE_STRONG if focus else UITokens.DOSSIER_RULE,
			2.0 if focus else 1.0)
		owner.draw_string(serif, Vector2(scroll.position.x + scroll.size.x * 0.5 - label_w * 0.5,
			rect.position.y + 21.0) if scrolled else rect.position + Vector2(12.0, 21.0),
			label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, TechnologyTreeView.ERA_FONT_SIZE, colour)
		var lanes: Array = band.get("lanes", [])
		for lane_value in lanes:
			var lane: Dictionary = lane_value
			var lane_rect: Rect2 = lane.rect
			var domain := int(lane.get("domain", 0))
			var accent := owner._accent_for(domain)
			var lane_is_paper := focus and String(lane.get("id", "")) == paper_domain_id
			if lane_is_paper:
				var wash := accent
				wash.a = 0.07
				owner.draw_rect(lane_rect, wash, true)
				# Keep torn edges at source scale and stretch only the paper centre.
				TechnologyTreeView.Art.draw_lane_strip(owner, Rect2(lane_rect.position + Vector2(-4.0, 24.0),
					Vector2(lane_rect.size.x + 8.0, maxf(0.0, rect.end.y
					- lane_rect.position.y - 30.0))), Color.WHITE)
			if domain > 0:
				var rule := Color(UITokens.ARCHIVE_RULE, 0.34 if focus else 0.18)
				var rule_x := lane_rect.position.x - 7.0
				owner.draw_line(Vector2(rule_x, lane_rect.position.y + 2.0),
					Vector2(rule_x, rect.end.y - 8.0), rule, 1.0)
			var header := String(lane.get("display_name", ""))
			var header_colour := accent.lerp(UITokens.ARCHIVE_INK, 0.35) if focus \
				else UITokens.ARCHIVE_INK_MUTED
			var header_w := font.get_string_size(header, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13).x
			var ribbon := Rect2(Vector2(lane_rect.position.x + 2.0, rect.position.y + 29.0),
				Vector2(minf(lane_rect.size.x - 4.0, header_w + 50.0), TechnologyTreeView.LANE_RIBBON_HEIGHT))
			TechnologyTreeView.Art.draw_plate(owner, TechnologyTreeView.Art.LANE_RIBBON, ribbon,
				Color.WHITE.lerp(accent, 0.10) if focus else Color(1.0, 1.0, 1.0, 0.82), false)
			var emblem := TechnologyTreeView.Art.domain_emblem(String(lane.get("id", "")))
			if not TechnologyTreeView.Art.draw_icon(owner, emblem, Vector2(ribbon.position.x + 10.0,
					ribbon.position.y + ribbon.size.y * 0.5), 18.0,
					Color.WHITE if focus else Color(1.0, 1.0, 1.0, 0.6)):
				owner._draw_glyph(IconCatalog.technology_domain_semantic(String(lane.get("id", ""))),
					Vector2(lane_rect.position.x + 8.0, rect.position.y + 42.0), 10,
					header_colour)
			owner.draw_string(font, Vector2(ribbon.position.x + 23.0, rect.position.y + 43.0),
				header, HORIZONTAL_ALIGNMENT_LEFT, maxf(24.0, ribbon.size.x - 30.0),
				13, header_colour)



static func _draw_edges(owner: TechnologyTreeView) -> void:
	for edge_value in owner._focus_layout.get("edges", []) as Array:
		var edge: Dictionary = edge_value
		var from := int(edge.from)
		var to := int(edge.to)
		var kind := String(edge.get("kind", "hard"))
		if kind in ["application", "branch"] and owner._selected not in [from, to]:
			continue
		var emphasis := owner._selected < 0 or from == owner._selected or to == owner._selected \
			or owner._chain_up.has(from) or owner._chain_down.has(to)
		var colour := owner._accent_for(int((owner._definitions[to] as Dictionary).get(
			"domain_index", owner._domain_index_of(owner._definitions[to])))).lerp(
				UITokens.ARCHIVE_INK, 0.24)
		colour.a = 0.76 if emphasis else 0.24
		if kind == "application":
			owner._draw_dashed_polyline(edge.points, colour, 1.0, 4.0, 5.0)
		elif kind == "branch":
			owner._draw_dashed_polyline(edge.points, colour, 1.5, 2.0, 3.0)
		else:
			# Emphasised prerequisites read as an inked thread laid on a paper
			# underlay, so crossings stay separable over the rice-paper grid.
			if emphasis and owner._selected >= 0:
				owner.draw_polyline(edge.points, TechnologyTreeView.THREAD_UNDERLAY, 5.0, true)
			owner.draw_polyline(edge.points, colour, 2.4 if emphasis and owner._selected >= 0 \
				else (2.0 if emphasis else 1.0), true)



static func _draw_dashed_polyline(owner: TechnologyTreeView, points: PackedVector2Array, colour: Color, width: float,
		dash_length: float, gap_length: float) -> void:
	for segment in range(points.size() - 1):
		var cursor := points[segment]
		var target := points[segment + 1]
		var vector := target - cursor
		var length := vector.length()
		if length <= 0.001:
			continue
		var direction := vector / length
		var consumed := 0.0
		var drawing := true
		while consumed < length:
			var step := minf(dash_length if drawing else gap_length, length - consumed)
			if drawing:
				owner.draw_line(cursor + direction * consumed,
					cursor + direction * (consumed + step), colour, width, true)
			consumed += step
			drawing = not drawing



static func _draw_portal(owner: TechnologyTreeView, cursor: int) -> void:
	var portals: Array = owner._focus_layout.get("portals", [])
	var portal: Dictionary = portals[cursor]
	var rect := owner._portal_rect(portal, cursor)
	var target := int(portal.target)
	var hover := cursor == owner._hovered_portal
	var colour := UITokens.ARCHIVE_BRASS if hover else UITokens.ARCHIVE_RULE
	owner.draw_rect(rect, UITokens.ARCHIVE_PAPER_LIGHT if hover else TechnologyTreeView.CARD_PAPER_DIM, true)
	owner.draw_rect(rect, colour, false, 1.0)
	var incoming := String(portal.direction) == "incoming"
	owner._draw_glyph(&"action.back" if incoming else &"action.chevron_right",
		rect.position + Vector2(8.0, 17.0), 11,
		UITokens.ARCHIVE_INK if hover else UITokens.ARCHIVE_INK_MUTED)



static func _draw_node(owner: TechnologyTreeView, node: Dictionary) -> void:
	var index := int(node.index)
	var rect: Rect2 = node.rect
	var definition: Dictionary = owner._definitions[index]
	# Retired era milestones never reach the focus layout; guard anyway so a
	# stale layout cannot draw an internal era token as a research card.
	if TechnologyTreeView.is_retired_definition(definition):
		return
	var state := owner._state_of(index)
	var known := owner._is_known(index)
	var domain := int(node.domain)
	var is_application := owner._is_application_definition(definition)
	var accent := owner._accent_for(domain)
	var emphasis := owner._emphasis_for(index)
	var text_colour := owner._node_text_colour(emphasis)
	var muted_text_colour := owner._node_text_colour(emphasis, true)
	owner._draw_card_plate(rect, domain, state, known, emphasis, false)
	if not known:
		if not TechnologyTreeView.Art.draw_icon(owner, TechnologyTreeView.Art.state_seal(state, false),
				rect.position + Vector2(22.0, rect.size.y * 0.5), TechnologyTreeView.SEAL_DIAMETER,
				Color(1.0, 1.0, 1.0, 0.9 if emphasis == 2 else 0.72)):
			owner._draw_glyph(&"technology.state.unknown", rect.position + Vector2(14.0, 36.0), 13,
				Color(accent.r, accent.g, accent.b, 0.72))
		owner.draw_string(owner._name_font, rect.position + Vector2(38.0, 36.0), "未知科技",
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 46.0, TechnologyTreeView.NAME_FONT_SIZE,
			muted_text_colour)
		return
	# Narrow lanes already carry the domain glyph in their header; dropping it on
	# the card keeps four-character names readable instead of ellipsized.
	var narrow := rect.size.x < TechnologyTreeView.NARROW_CARD_WIDTH and not is_application
	var text_x := 14.0 if narrow else 40.0
	if not narrow:
		var emblem: Texture2D = null if is_application \
			else TechnologyTreeView.Art.domain_emblem(String(definition.get("domain_id", "")))
		if not TechnologyTreeView.Art.draw_icon(owner, emblem, rect.position + Vector2(22.0, 30.0),
				TechnologyTreeView.EMBLEM_DIAMETER, Color(1.0, 1.0, 1.0, 0.62 if emphasis == 0 else 1.0)):
			owner._draw_glyph(&"economy.building" if is_application \
				else IconCatalog.technology_domain_semantic(String(definition.get("domain_id", ""))),
				rect.position + Vector2(14.0, 36.0), 13,
				text_colour if emphasis == 2 else accent)
	var label := String(definition.get("display_name", ""))
	# Leave the right edge to the state glyph drawn at size.x - 24.
	var label_width := rect.size.x - text_x - (22.0 if is_application else 30.0)
	var label_font_size := owner._fitted_name_size(label, label_width)
	owner.draw_string(owner._name_font, rect.position + Vector2(text_x, 35.0),
		owner._ellipsize(label, label_width, label_font_size), HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		label_font_size, text_colour)
	if is_application:
		owner.draw_string(owner.get_theme_default_font(), rect.position + Vector2(38.0, 54.0),
			TechnologyTreeView.STATE_NAMES[5] if state >= 5 else "应用条件未齐",
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 50.0, 11, muted_text_colour)
	else:
		if not TechnologyTreeView.Art.draw_icon(owner, TechnologyTreeView.Art.state_seal(state),
				rect.position + Vector2(rect.size.x - 18.0, 30.0), TechnologyTreeView.SEAL_DIAMETER,
				Color(1.0, 1.0, 1.0, 0.6 if emphasis == 0 else 1.0)):
			owner._draw_glyph(IconCatalog.technology_state_semantic(state),
				rect.position + Vector2(rect.size.x - 24.0, 35.0), 12,
				text_colour if emphasis == 2 else owner._state_colour(state))
		owner._draw_progress(index, rect, accent, emphasis == 0)


# Bitmap card plate with a thin domain-colour tab; StyleBoxFlat remains the
# fallback when the textures are unavailable (tests, stripped exports).
static func _draw_card_plate(owner: TechnologyTreeView, rect: Rect2, domain: int, state: int, known: bool, emphasis: int,
		is_milestone: bool) -> void:
	var path := TechnologyTreeView.Art.CARD_KNOWN
	if emphasis == 2:
		path = TechnologyTreeView.Art.CARD_SELECTED
	elif is_milestone:
		path = TechnologyTreeView.Art.CARD_MILESTONE
	elif not known:
		path = TechnologyTreeView.Art.CARD_UNKNOWN
	var tint := Color.WHITE
	if emphasis == 0:
		tint = Color(0.90, 0.87, 0.80, 0.86)
	elif state >= 5 and known and not is_milestone:
		# Mastered cards read as older, settled paper; live research stays bright.
		tint = Color(0.96, 0.94, 0.88)
	if not TechnologyTreeView.Art.draw_plate(owner, path, rect, tint):
		owner.draw_style_box(owner._card_style(domain, state, known, emphasis, is_milestone), rect)
		return
	if known and not is_milestone:
		var accent := owner._accent_for(domain)
		accent.a = 0.95 if emphasis != 0 else 0.45
		owner.draw_rect(Rect2(rect.position + Vector2(5.0, 9.0), Vector2(3.0, rect.size.y - 18.0)),
			accent, true)



static func _draw_progress(owner: TechnologyTreeView, index: int, rect: Rect2, accent: Color, dim: bool) -> void:
	if owner._is_application_definition(owner._definitions[index]):
		return
	var state := owner._state_of(index)
	if state < 2 or state >= 5:
		return
	var cost := maxf(1.0, float((owner._definitions[index] as Dictionary).get(
		"cost_points_scaled",
		int((owner._definitions[index] as Dictionary).get("cost_points", 1)) * 1000)))
	var earned := float(owner._progress[index]) if index < owner._progress.size() else 0.0
	var fraction := clampf(earned / cost, 0.0, 1.0)
	var track := Rect2(rect.position + Vector2(12.0, rect.size.y - 9.0),
		Vector2(rect.size.x - 24.0, 3.0))
	owner.draw_rect(track, Color(UITokens.ARCHIVE_INK, 0.18), true)
	if fraction > 0.0:
		var colour := accent.lerp(UITokens.BRASS_HIGHLIGHT, 0.42)
		colour.a = 0.45 if dim else 1.0
		owner.draw_rect(Rect2(track.position, Vector2(track.size.x * fraction, track.size.y)),
			colour, true)



static func _draw_glyph(owner: TechnologyTreeView, semantic: StringName, baseline: Vector2, glyph_size: int,
		colour: Color) -> void:
	IconCatalog.draw_icon(owner, semantic,
		Rect2(baseline - Vector2(0, glyph_size * 0.84), Vector2.ONE * glyph_size), colour.a)
