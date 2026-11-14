extends RefCounted

## Grants the era technology and research signals an ideology card requires.
##
## The worker pod checks draw requirements against its frozen Country snapshot, so
## fixtures must install them through the same CountryFacade the research UI uses.
## Accepts either a bare card key or its catalog id (`idea.<key>`).
static func grant_draw_gates(host: WorldRuntimeHost, card_id: String, handle: int,
		day: int, first_sequence: int = 900000) -> Dictionary:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return {"ok": false, "reason": "ideology_catalog_unavailable"}
	var wanted := card_id if card_id.begins_with("idea.") else "idea.%s" % card_id
	var definition: Resource = null
	for row in catalog.definitions:
		if row != null and String(row.id) == wanted:
			definition = row
			break
	if definition == null:
		return {"ok": false, "reason": "ideology_definition_missing"}
	var generator: MapGenerator = host.get_generator() \
		if host != null and host.has_method("get_generator") else null
	if generator == null or not generator.has_method("get_country_facade"):
		return {"ok": false, "reason": "country_facade_unavailable"}
	var facade = generator.get_country_facade()
	if facade == null:
		return {"ok": false, "reason": "country_facade_unavailable"}

	var sequence := first_sequence
	for requirement in definition.draw_requirements:
		if requirement == null:
			continue
		var key := StringName(String(requirement.key))
		var granted: Dictionary
		if int(requirement.kind) == 1:
			granted = facade.grant_technology(handle, key, day, sequence)
		elif int(requirement.kind) == 2:
			granted = facade.discover_research_signal(
				handle, key, 0, 0, day, sequence)
		else:
			return {"ok": false, "reason": "draw_requirement_kind_invalid"}
		sequence += 1
		if not bool(granted.get("ok", false)):
			return {"ok": false, "reason": String(granted.get(
				"reason", "draw_gate_rejected"))}
	return {"ok": true, "next_sequence": sequence}


## True once every technology `grant_draw_gates` queued is visible on the Country
## mirror. The grant is a queued Country command: under worker authority it lands a
## day or more after submission, and a DISCOVER the pod applies before that is
## refused with `ideology_discovery_not_allowed` (receipt), so the card never enters
## the collection. Signal requirements are not checked here.
static func draw_gates_landed(host: WorldRuntimeHost, card_id: String,
		handle: int) -> bool:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	var wanted := card_id if card_id.begins_with("idea.") else "idea.%s" % card_id
	var facade = host.get_generator().get_country_facade()
	for row in catalog.definitions:
		if row == null or String(row.id) != wanted:
			continue
		for requirement in row.draw_requirements:
			if requirement != null and int(requirement.kind) == 1 \
					and not facade.has_completed_technology(handle,
						facade._technology_index(StringName(String(requirement.key)))):
				return false
		return true
	return false
