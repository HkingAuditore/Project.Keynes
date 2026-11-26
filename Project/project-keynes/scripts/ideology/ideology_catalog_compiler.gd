extends RefCounted

## Compiles authored ideology resources into the native catalog columns.

const EffectRows = preload("res://scripts/ideology/ideology_catalog_effect_rows.gd")
const IdeologyDefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const IdeologyRequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")
const IdeologyProfileScript = preload("res://scripts/ideology/ideology_profile.gd")
const IdeologyClassStanceScript = preload("res://scripts/ideology/ideology_class_stance.gd")
const IdeologySynergyDefinitionScript = preload("res://scripts/ideology/ideology_synergy_definition.gd")
const IdeologyEffectParameterScript = preload(
	"res://scripts/ideology/ideology_effect_parameter.gd")
const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")
const IdeologyIncidenceCompilerScript = preload(
	"res://scripts/ideology/ideology_incidence_compiler.gd")
const PROTOCOL_VERSION := 1
const PROGRAM_KEY_PREFIX := "ideology.effect."
const SCHOOLS := [
	{"id": "agrarian", "name": "农本", "motto": "重农固本，仓廩实而知礼节"},
	{"id": "commerce", "name": "商贸", "motto": "通有无，兴市舶，以财养国"},
	{"id": "learning", "name": "学识", "motto": "格物致知，以学立政"},
	{"id": "mobilization", "name": "动员", "motto": "聚众成城，万人一心"},
	{"id": "industry", "name": "工造", "motto": "利器善事，百工居胆"},
	{"id": "harmony", "name": "调和", "motto": "顺天应时，山泽有度"},
]

static var _era_rows_cache: Array = []

static func compile(profile: Resource, definitions: Array[Resource],
		synergies: Array[Resource], effect_programs: Resource,
		country_catalog: Dictionary, economy_catalog: Dictionary) -> Dictionary:
	var effective_profile = profile if profile != null else IdeologyProfileScript.new()
	if not effective_profile is IdeologyProfileScript:
		return {"ok": false, "reason": "ideology_profile_invalid"}
	if effective_profile.era_decay_bp.is_empty():
		return {"ok": false, "reason": "ideology_era_decay_invalid"}
	for decay_bp in effective_profile.era_decay_bp:
		if decay_bp < 0 or decay_bp > 10000:
			return {"ok": false, "reason": "ideology_era_decay_invalid"}
	var technology_ids: PackedStringArray = country_catalog.get("technology_ids", PackedStringArray())
	var signal_ids: PackedStringArray = country_catalog.get("research_signal_ids", PackedStringArray())
	var technology_index := {}
	var signal_index := {}
	for i in technology_ids.size(): technology_index[String(technology_ids[i])] = i
	for i in signal_ids.size(): signal_index[String(signal_ids[i])] = i
	# Era milestones are exported once so the main-thread runtime and the worker
	# pod derive `current_era` from the same table. Neither side is allowed to
	# walk CountryRuntime's private era cache on its own.
	var era_milestone_technologies := PackedInt32Array()
	for era in era_rows():
		var milestone_key := String(era.get("milestone_id", ""))
		if not technology_index.has(milestone_key):
			return {"ok": false, "reason": "ideology_era_milestone_unknown"}
		era_milestone_technologies.append(int(technology_index[milestone_key]))
	if era_milestone_technologies.is_empty():
		return {"ok": false, "reason": "ideology_era_milestone_unknown"}
	var political_class_ids: Array[String] = []
	for value in economy_catalog.get("profession_class_ids", PackedStringArray()):
		var class_id := String(value).strip_edges()
		if class_id.is_empty():
			class_id = "general"
		if not political_class_ids.has(class_id):
			political_class_ids.append(class_id)
	if political_class_ids.is_empty():
		political_class_ids.append("general")
	political_class_ids.sort()
	var political_class_index := {}
	for i in political_class_ids.size():
		political_class_index[political_class_ids[i]] = i
	# Effect rows whose definition_key resolves to a declared program are owned by
	# the reconciled Effect-instance path, not by ModifierRuntime. They are allowed
	# to carry any domain/opcode/selector because the program itself is what
	# validates; the row only marks "this card has an effect at this level".
	var declared_programs := {}
	var program_resource: Resource = effect_programs
	if program_resource == null:
		program_resource = IdeologyEffectCatalogScript.load_default()
	if program_resource != null:
		if not program_resource is IdeologyEffectCatalogScript:
			return {"ok": false, "reason": "ideology_effect_catalog_invalid"}
		var program_error: String = program_resource.validate()
		if not program_error.is_empty():
			return {"ok": false, "reason": program_error}
		declared_programs = program_resource.program_key_set()
	# Two budgets, two quantities. `tally["owned"]` below counts DECLARED rows
	# across the whole catalog; this table answers the different question the
	# runtime asks -- how many instances one card can have alive right now, per
	# program, which is a function of the program's target cap and not of how
	# many rows exist. Keeping them apart is the whole of L0-3: a catalog that
	# passes one and fails the other is normal, not a contradiction.
	var program_target_caps: Dictionary = {}
	if program_resource != null:
		for effect in program_resource.effects:
			if effect == null:
				continue
			program_target_caps[String(effect.program_key())] = \
				EffectRows._program_live_target_cap(effect)
	# Widest single card in the catalog, in live instances. Accumulated while
	# walking definitions so a per-card disaster is caught even when the catalog
	# total stays small.
	var widest_card_instances := 0
	# Rows owned by a program become reconciled instances: one per (card, level,
	# target). The bound keeps a pathological catalog from overflowing the
	# EffectRuntime instance table before the runtime ever sees it.
	var tally := {"owned": 0, "persistent": 0, "enter": 0}
	# Per-level owned row counts, aligned with `level_persistent_offsets` /
	# `level_on_enter_offsets`. Those rows never reach the legacy command scratch
	# buffer (emit_templates skips them), so the transition-command budget below
	# must subtract them or a program-heavy catalog fails to compile.
	var owned_persistent_per_level := PackedInt32Array()
	var owned_enter_per_level := PackedInt32Array()
	var ordered: Array[Resource] = definitions.duplicate()
	ordered.sort_custom(func(a, b) -> bool:
		return String(a.id) < String(b.id) if a != null and b != null else a != null)
	# Material support: one dense Q16 channel row per level, in this same order.
	var incidence := IdeologyIncidenceCompilerScript.compile(
		ordered, program_resource, economy_catalog)
	var gates := {}
	for definition in ordered:
		if definition == null or not definition is IdeologyDefinitionScript:
			return {"ok": false, "reason": "ideology_definition_resource_invalid"}
		var validation: String = definition.validate()
		if not validation.is_empty(): return {"ok": false, "reason": validation}
		for requirement in definition.draw_requirements:
			if requirement.kind == IdeologyRequirementScript.Kind.GATE:
				gates[String(requirement.key)] = true
		# Affinity gates are context keys written only by IdeologyContextService.
		# They must be registered here or IdeologyFacade._gate_id() resolves them
		# to -1 and set_gate() is silently dropped by the native runtime.
		for affinity in definition.era_affinities:
			var affinity_gate := String(affinity.gate_key).strip_edges()
			if not affinity_gate.is_empty():
				gates[affinity_gate] = true
	var gate_keys: Array = gates.keys()
	gate_keys.sort()
	var gate_index := {}
	for i in gate_keys.size(): gate_index[String(gate_keys[i])] = i
	var exclusion_keys: Array[String] = []
	for definition in ordered:
		var exclusion := String(definition.exclusion_group).strip_edges()
		if not exclusion.is_empty() and not exclusion_keys.has(exclusion):
			exclusion_keys.append(exclusion)
	exclusion_keys.sort()
	var exclusion_index := {}
	for i in exclusion_keys.size():
		exclusion_index[exclusion_keys[i]] = i
	var out := {
		"protocol_version": PROTOCOL_VERSION,
		"ideology_capacity": effective_profile.ideology_capacity,
		"national_spirit_capacity": effective_profile.national_spirit_capacity,
		"offer_choice_count": effective_profile.offer_choice_count,
		"offer_cost_q16": effective_profile.offer_cost_q16,
		"starting_points_q16": effective_profile.starting_points_q16,
		"max_commands_per_slice": effective_profile.max_commands_per_slice,
		"max_transition_commands": effective_profile.max_transition_commands,
		"max_effect_instances": effective_profile.max_effect_instances,
		"max_transition_polls_per_slice": effective_profile.max_transition_polls_per_slice,
		"max_active_visits_per_slice": effective_profile.max_active_visits_per_slice,
		"opinion_owner_influence_weight": effective_profile.opinion_owner_influence_weight,
		"opinion_funds_per_influence": effective_profile.opinion_funds_per_influence,
		"support_model": effective_profile.support_model,
		"incidence_gain_q16": effective_profile.incidence_gain_q16,
		"incidence_veto_q16": effective_profile.incidence_veto_q16,
		"incidence_veto_min_influence_q16":
			effective_profile.incidence_veto_min_influence_q16,
		"incidence_threshold_scale_q16":
			effective_profile.incidence_threshold_scale_q16,
		"support_gate_enabled": effective_profile.support_gate_enabled,
		"ideology_capacity_max": maxi(effective_profile.ideology_capacity,
			effective_profile.ideology_capacity_max),
		"national_spirit_capacity_max": maxi(effective_profile.national_spirit_capacity,
			effective_profile.national_spirit_capacity_max),
		"offer_cost_growth_percent": effective_profile.offer_cost_growth_percent,
		"offer_cost_max_q16": maxi(effective_profile.offer_cost_q16,
			effective_profile.offer_cost_max_q16),
		"reroll_cost_percent": effective_profile.reroll_cost_percent,
		"point_population_weight_q16": effective_profile.point_population_weight_q16,
		"point_building_weight_q16": effective_profile.point_building_weight_q16,
		"point_trade_weight_q16": effective_profile.point_trade_weight_q16,
		"point_gain_cap_q16": effective_profile.point_gain_cap_q16,
		"point_gain_stat_key": String(effective_profile.point_gain_stat_key),
		"point_population_factor_stat_key": String(
			effective_profile.point_population_factor_stat_key),
		"point_building_factor_stat_key": String(
			effective_profile.point_building_factor_stat_key),
		"point_trade_factor_stat_key": String(
			effective_profile.point_trade_factor_stat_key),
		"opinion_factor_floor_stat_key": String(
			effective_profile.opinion_factor_floor_stat_key),
		"school_strength_factor_stat_keys": \
			effective_profile.school_strength_factor_stat_keys.duplicate(),
		"ideology_school_keys": PackedStringArray(
			SCHOOLS.map(func(school): return String(school.id))),
		# Ideology-facing multipliers. Same contract as point_gain_stat_key: an
		# empty string means "no stat", which every consumer reads as 1.0. Kept
		# as separate keys rather than one packed field so a catalog can enable
		# one without the other.
		"understanding_gain_stat_key": String(
			effective_profile.understanding_gain_stat_key),
		"reroll_cost_stat_key": String(effective_profile.reroll_cost_stat_key),
		# Draw-side knobs. `era_decay_floor_bp` / `offer_choice_bonus` are the two
		# ADDITIVE ideology stats; the two refine fields are catalog constants the
		# worker needs because it cannot read ModifierRuntime or the profile.
		"era_decay_floor_stat_key": String(effective_profile.era_decay_floor_stat_key),
		"offer_choice_bonus_stat_key": String(
			effective_profile.offer_choice_bonus_stat_key),
		"refine_weight_bp": effective_profile.refine_weight_bp,
		"refine_understanding_q16": effective_profile.refine_understanding_q16,
		"capacity_unlock_technology_ids": PackedInt32Array(),
		"capacity_unlock_ideology_deltas": PackedInt32Array(),
		"capacity_unlock_spirit_deltas": PackedInt32Array(),
		"synergy_min_counts": PackedInt32Array(),
		# L3-9 runtime magnitude overrides, flattened in synergy order. Optional as
		# a set: a catalog with no synergy overrides emits an empty offsets array
		# and the native side keeps every scale at 1.0.
		"synergy_override_offsets": PackedInt32Array([0]),
		"synergy_override_programs": PackedStringArray(),
		"synergy_override_scales": PackedInt32Array(),
		"synergy_override_match_kinds": PackedInt32Array(),
		"synergy_override_match_values": PackedStringArray(),
		"synergy_override_fields": PackedInt32Array(),
		"synergy_override_values": PackedInt32Array(),
		"synergy_override_tag_names": PackedStringArray(),
		"political_class_ids": PackedStringArray(political_class_ids),
		"ideology_ids": PackedStringArray(), "acquisition_flags": PackedByteArray(),
		"rarity_weights": PackedInt32Array(), "ideology_slot_costs": PackedInt32Array(),
		"spirit_slot_costs": PackedInt32Array(), "national_spirit_min_levels": PackedInt32Array(),
		"ideology_copy_left_programs": PackedByteArray(),
		"ideology_copyable": PackedByteArray(),
		"ideology_school_indices": PackedInt32Array(),
		"level_offsets": PackedInt32Array([0]), "level_thresholds_q16": PackedInt64Array(),
		"level_daily_understanding_q16": PackedInt64Array(),
		"technology_requirement_offsets": PackedInt32Array([0]),
		"technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0]),
		"signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0]), "gate_requirements": PackedInt32Array(),
		"level_persistent_offsets": PackedInt32Array([0]),
		"persistent_actions": PackedInt32Array(), "persistent_domains": PackedInt32Array(),
		"persistent_opcodes": PackedInt32Array(), "persistent_values_q16": PackedInt64Array(),
		"persistent_duration_days": PackedInt32Array(), "persistent_stacks": PackedInt32Array(),
		"persistent_command_keys": PackedStringArray(), "persistent_definition_keys": PackedStringArray(),
		"persistent_payload_i0": PackedInt64Array(), "persistent_payload_i1": PackedInt64Array(),
		"persistent_payload_i2": PackedInt64Array(), "persistent_payload_i3": PackedInt64Array(),
		"level_on_enter_offsets": PackedInt32Array([0]),
		"on_enter_actions": PackedInt32Array(), "on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(), "on_enter_values_q16": PackedInt64Array(),
		"on_enter_duration_days": PackedInt32Array(), "on_enter_stacks": PackedInt32Array(),
		"on_enter_command_keys": PackedStringArray(), "on_enter_definition_keys": PackedStringArray(),
		"on_enter_payload_i0": PackedInt64Array(), "on_enter_payload_i1": PackedInt64Array(),
		"on_enter_payload_i2": PackedInt64Array(), "on_enter_payload_i3": PackedInt64Array(),
		"gate_keys": PackedStringArray(gate_keys),
		"stance_offsets": PackedInt32Array([0]),
		"stance_class_indices": PackedInt32Array(),
		"stance_adopt_q16": PackedInt32Array(),
		"stance_repeal_q16": PackedInt32Array(),
		"stance_promote_q16": PackedInt32Array(),
		"stance_adopt_min_q16": PackedInt32Array(),
		"stance_repeal_min_q16": PackedInt32Array(),
		"stance_promote_min_q16": PackedInt32Array(),
		"adopt_thresholds_q16": PackedInt32Array(),
		"repeal_thresholds_q16": PackedInt32Array(),
		"promote_thresholds_q16": PackedInt32Array(),
		"exclusion_group_ids": PackedInt32Array(),
		# Route ids are a catalog contract. Each card's mask names the primary
		# and secondary routes used by ideology-local route_count scalars.
		"route_keys": PackedStringArray(),
		"ideology_route_masks": PackedInt32Array(),
		"synergy_ids": PackedStringArray(),
		"synergy_requirement_offsets": PackedInt32Array([0]),
		"synergy_requirement_ideology_ids": PackedInt32Array(),
		"synergy_requirement_min_levels": PackedInt32Array(),
		"synergy_requirement_location_masks": PackedByteArray(),
		"synergy_effect_offsets": PackedInt32Array([0]),
		"synergy_effect_actions": PackedInt32Array(),
		"synergy_effect_domains": PackedInt32Array(),
		"synergy_effect_opcodes": PackedInt32Array(),
		"synergy_effect_values_q16": PackedInt64Array(),
		"synergy_effect_duration_days": PackedInt32Array(),
		"synergy_effect_stacks": PackedInt32Array(),
		"synergy_effect_command_keys": PackedStringArray(),
		"synergy_effect_definition_keys": PackedStringArray(),
		"synergy_effect_payload_i0": PackedInt64Array(),
		"synergy_effect_payload_i1": PackedInt64Array(),
		"synergy_effect_payload_i2": PackedInt64Array(),
		"synergy_effect_payload_i3": PackedInt64Array(),
		"ideology_synergy_offsets": PackedInt32Array([0]),
		"ideology_synergy_ids": PackedInt32Array(),
		# Era decay + context affinity. `ideology_era_indices` is one entry per
		# definition; the affinity tables are a flat CSR addressed by
		# `ideology_affinity_offsets`.
		"era_decay_bp": effective_profile.era_decay_bp.duplicate(),
		"ideology_era_milestone_technologies": era_milestone_technologies,
		"ideology_era_indices": PackedInt32Array(),
		"ideology_affinity_offsets": PackedInt32Array([0]),
		"ideology_affinity_gate_ids": PackedInt32Array(),
		"ideology_affinity_multipliers_bp": PackedInt32Array(),
	}
	var unlock_keys: PackedStringArray = effective_profile.capacity_unlock_technology_keys
	if unlock_keys.size() != effective_profile.capacity_unlock_ideology_deltas.size() \
			or unlock_keys.size() != effective_profile.capacity_unlock_spirit_deltas.size():
		return {"ok": false, "reason": "ideology_capacity_unlocks_invalid"}
	for index in unlock_keys.size():
		var tech_key := String(unlock_keys[index])
		if not technology_index.has(tech_key):
			return {"ok": false, "reason": "ideology_capacity_unlock_technology_unknown"}
		var ideology_delta := int(effective_profile.capacity_unlock_ideology_deltas[index])
		var spirit_delta := int(effective_profile.capacity_unlock_spirit_deltas[index])
		if ideology_delta < 0 or spirit_delta < 0:
			return {"ok": false, "reason": "ideology_capacity_unlocks_invalid"}
		out.capacity_unlock_technology_ids.append(int(technology_index[tech_key]))
		out.capacity_unlock_ideology_deltas.append(ideology_delta)
		out.capacity_unlock_spirit_deltas.append(spirit_delta)
	var seen := {}
	var school_index := {}
	for index in SCHOOLS.size():
		school_index[String(SCHOOLS[index].id)] = index
	for definition in ordered:
		var key := String(definition.id)
		if seen.has(key): return {"ok": false, "reason": "ideology_id_duplicate"}
		seen[key] = true
		out.ideology_ids.append(key)
		out.ideology_era_indices.append(int(definition.era_index))
		for affinity in definition.era_affinities:
			out.ideology_affinity_gate_ids.append(
				int(gate_index[String(affinity.gate_key).strip_edges()]))
			out.ideology_affinity_multipliers_bp.append(int(affinity.multiplier_bp))
		out.ideology_affinity_offsets.append(out.ideology_affinity_gate_ids.size())
		out.acquisition_flags.append(definition.acquisition_flags)
		out.rarity_weights.append(definition.rarity_weight)
		out.ideology_copy_left_programs.append(
			1 if definition.copy_left_programs else 0)
		out.ideology_copyable.append(1 if definition.copyable else 0)
		var definition_school := String(definition.school_id)
		if not school_index.has(definition_school):
			return {"ok": false, "reason": "ideology_school_unknown:%s" % definition_school}
		out.ideology_school_indices.append(int(school_index[definition_school]))
		out.ideology_slot_costs.append(definition.ideology_slot_cost)
		out.spirit_slot_costs.append(definition.national_spirit_slot_cost)
		out.national_spirit_min_levels.append(definition.national_spirit_min_level)
		out.adopt_thresholds_q16.append(definition.adopt_threshold_q16)
		out.repeal_thresholds_q16.append(definition.repeal_threshold_q16)
		out.promote_thresholds_q16.append(definition.promote_threshold_q16)
		var exclusion := String(definition.exclusion_group).strip_edges()
		out.exclusion_group_ids.append(
			int(exclusion_index.get(exclusion, -1)) if not exclusion.is_empty() else -1)
		var ordered_stances: Array[Resource] = definition.class_stances.duplicate()
		ordered_stances.sort_custom(func(a, b) -> bool:
			return String(a.class_id) < String(b.class_id))
		for stance in ordered_stances:
			if stance == null or not stance is IdeologyClassStanceScript \
					or not political_class_index.has(String(stance.class_id)):
				return {"ok": false, "reason": "ideology_stance_class_unknown"}
			out.stance_class_indices.append(
				int(political_class_index[String(stance.class_id)]))
			out.stance_adopt_q16.append(stance.adopt_stance_q16)
			out.stance_repeal_q16.append(stance.repeal_stance_q16)
			out.stance_promote_q16.append(stance.promote_stance_q16)
			out.stance_adopt_min_q16.append(stance.adopt_min_support_q16)
			out.stance_repeal_min_q16.append(stance.repeal_min_support_q16)
			out.stance_promote_min_q16.append(stance.promote_min_support_q16)
		out.stance_offsets.append(out.stance_class_indices.size())
		for level in definition.levels:
			out.level_thresholds_q16.append(level.understanding_threshold_q16)
			out.level_daily_understanding_q16.append(level.daily_understanding_q16)
			tally["persistent"] = 0
			tally["enter"] = 0
			var effect_error := EffectRows._append_effect_rows(out, level.persistent_effects, true,
				declared_programs, tally)
			if not effect_error.is_empty(): return {"ok": false, "reason": effect_error}
			effect_error = EffectRows._append_effect_rows(out, level.on_enter_effects, false,
				declared_programs, tally)
			if not effect_error.is_empty(): return {"ok": false, "reason": effect_error}
			owned_persistent_per_level.append(int(tally["persistent"]))
			owned_enter_per_level.append(int(tally["enter"]))
			# Only the ACTIVE level's rows are live at once, so a card's worst
			# case is its widest level -- not the sum over all three. Summing
			# levels here would report a ceiling three times too high and make
			# the budget meaningless.
			var level_live := 0
			for effect in level.persistent_effects:
				if effect == null:
					continue
				var owned_key := PROGRAM_KEY_PREFIX + String(effect.definition_key)
				if declared_programs.has(owned_key):
					level_live += int(program_target_caps.get(owned_key, 1))
			widest_card_instances = maxi(widest_card_instances, level_live)
		out.level_offsets.append(out.level_thresholds_q16.size())
		for requirement in definition.draw_requirements:
			match requirement.kind:
				IdeologyRequirementScript.Kind.TECHNOLOGY:
					if not technology_index.has(String(requirement.key)):
						return {"ok": false, "reason": "ideology_requirement_technology_unknown"}
					out.technology_requirements.append(technology_index[String(requirement.key)])
				IdeologyRequirementScript.Kind.RESEARCH_SIGNAL:
					if not signal_index.has(String(requirement.key)):
						return {"ok": false, "reason": "ideology_requirement_signal_unknown"}
					out.signal_requirements.append(signal_index[String(requirement.key)])
				IdeologyRequirementScript.Kind.GATE:
					out.gate_requirements.append(gate_index[String(requirement.key)])
				_:
					return {"ok": false, "reason": "ideology_requirement_kind_invalid"}
		out.technology_requirement_offsets.append(out.technology_requirements.size())
		out.signal_requirement_offsets.append(out.signal_requirements.size())
		out.gate_requirement_offsets.append(out.gate_requirements.size())
	var ideology_index := {}
	for index in out.ideology_ids.size():
		ideology_index[String(out.ideology_ids[index])] = index
	# Route (体系) index: tag -> dense card ids, in dense order. Built once so a
	# route-tag synergy expands in O(1) lookups instead of rescanning the card
	# table per row. Dense order (not authored order) is what the native side
	# sees, which keeps two builds of the same content byte-identical.
	var route_index := {}
	# Sorted ids make the dense route order independent of dictionary insertion
	# order. EffectDomainCatalog validates that every one has a scalar row.
	var route_keys: Array = EffectRows.ROUTE_DISPLAY_NAMES.keys()
	route_keys.sort()
	var route_ids := {}
	for route_id in route_keys.size():
		var route_key := String(route_keys[route_id])
		route_ids[route_key] = route_id
		out.route_keys.append(route_key)
	var selector_kind_by_program := {}
	if program_resource != null:
		for effect in program_resource.effects:
			if effect == null or not effect is IdeologyEffectDefinitionScript:
				continue
			selector_kind_by_program[String(effect.program_key())] = \
				int(effect.target_selector_kind)
	for definition in ordered:
		var definition_dense := int(ideology_index[String(definition.id)])
		var definition_route_mask := 0
		for route in definition.route_tags():
			if not route_ids.has(route):
				return {"ok": false, "reason": "ideology_route_unknown:%s" % route}
			definition_route_mask |= 1 << int(route_ids[route])
			if not route_index.has(route):
				route_index[route] = PackedInt32Array()
			var bucket: PackedInt32Array = route_index[route]
			bucket.append(definition_dense)
			route_index[route] = bucket
		out.ideology_route_masks.append(definition_route_mask)
	var ordered_synergies: Array[Resource] = synergies.duplicate()
	ordered_synergies.sort_custom(func(a, b) -> bool:
		return String(a.id) < String(b.id) if a != null and b != null else a != null)
	var reverse: Array[Array] = []
	reverse.resize(out.ideology_ids.size())
	for index in reverse.size():
		reverse[index] = []
	for synergy in ordered_synergies:
		if synergy == null or not synergy is IdeologySynergyDefinitionScript:
			return {"ok": false, "reason": "ideology_synergy_resource_invalid"}
		var synergy_error: String = synergy.validate()
		if not synergy_error.is_empty():
			return {"ok": false, "reason": synergy_error}
		if out.synergy_ids.has(String(synergy.id)):
			return {"ok": false, "reason": "ideology_synergy_id_duplicate"}
		var synergy_id: int = out.synergy_ids.size()
		out.synergy_ids.append(String(synergy.id))
		out.synergy_min_counts.append(int(synergy.min_count))
		# The native side compares against the PREFIXED program key, because that
		# is what `effect_program_key()` produces when an instance is activated.
		# Emitting the bare key here would make every override silently miss.
		for override in synergy.overrides:
			if override == null:
				continue
			var override_error: String = override.validate()
			if not override_error.is_empty():
				return {"ok": false, "reason": override_error}
			var rewrite_rows: Dictionary = EffectRows._expand_override_rows(
				override, declared_programs, route_index, ordered,
				selector_kind_by_program)
			if not bool(rewrite_rows.get("ok", false)):
				return {"ok": false, "reason": String(rewrite_rows.get("reason", ""))}
			for expanded_row in rewrite_rows.get("rows", []):
				var row: Dictionary = expanded_row
				var match_kind := int(row["match_kind"])
				var match_value := String(row["match_value"])
				var field := int(override.field)
				# Legacy scale columns stay populated for the pre-X5 lookup path.
				out.synergy_override_programs.append(match_value)
				out.synergy_override_scales.append(
					int(override.value) if field == \
						IdeologyEffectParameterScript.Field.MAGNITUDE_SCALE else 0)
				out.synergy_override_match_kinds.append(match_kind)
				out.synergy_override_match_values.append(match_value)
				out.synergy_override_fields.append(field)
				out.synergy_override_values.append(int(override.value))
				out.synergy_override_tag_names.append(
					override.tag_union_name() if field == \
						IdeologyEffectParameterScript.Field.TAG else "")
		out.synergy_override_offsets.append(out.synergy_override_programs.size())
		if synergy.uses_route_tag():
			var expanded: Dictionary = EffectRows._expand_route_synergy_members(
				String(synergy.route_tag), route_index, int(synergy.min_count))
			if not bool(expanded.get("ok", false)):
				return {"ok": false, "reason": String(expanded.get("reason", ""))}
			var members: PackedInt32Array = expanded.get(
				"members", PackedInt32Array())
			for dense_id in members:
				out.synergy_requirement_ideology_ids.append(int(dense_id))
				out.synergy_requirement_min_levels.append(
					int(synergy.route_tag_min_level))
				out.synergy_requirement_location_masks.append(
					int(synergy.route_tag_location_mask))
				reverse[int(dense_id)].append(synergy_id)
		else:
			for requirement in synergy.required_ideology_ids.size():
				var required_id := String(synergy.required_ideology_ids[requirement])
				if not ideology_index.has(required_id):
					return {"ok": false, "reason": "ideology_synergy_ideology_unknown"}
				var dense_id := int(ideology_index[required_id])
				out.synergy_requirement_ideology_ids.append(dense_id)
				out.synergy_requirement_min_levels.append(
					int(synergy.minimum_levels[requirement]))
				out.synergy_requirement_location_masks.append(
					int(synergy.location_masks[requirement]))
				reverse[dense_id].append(synergy_id)
		out.synergy_requirement_offsets.append(
			out.synergy_requirement_ideology_ids.size())
		synergy_error = EffectRows._append_synergy_effect_rows(
			out, synergy.persistent_effects)
		if not synergy_error.is_empty():
			return {"ok": false, "reason": synergy_error}
	for ideology_id in reverse.size():
		(reverse[ideology_id] as Array).sort()
		for synergy_id in reverse[ideology_id]:
			out.ideology_synergy_ids.append(int(synergy_id))
		out.ideology_synergy_offsets.append(out.ideology_synergy_ids.size())
	var base_transition_commands := 0
	for level in range(out.level_persistent_offsets.size() - 1):
		var persistent_count := int(out.level_persistent_offsets[level + 1]) \
			- int(out.level_persistent_offsets[level])
		var enter_count := int(out.level_on_enter_offsets[level + 1]) \
			- int(out.level_on_enter_offsets[level])
		if level < owned_persistent_per_level.size():
			persistent_count -= int(owned_persistent_per_level[level])
			enter_count -= int(owned_enter_per_level[level])
		base_transition_commands = maxi(base_transition_commands,
			maxi(0, persistent_count) * 2 + maxi(0, enter_count))
	var max_transition_commands := base_transition_commands
	for ideology_id in out.ideology_ids.size():
		var synergy_effect_count := 0
		for cursor in range(out.ideology_synergy_offsets[ideology_id],
				out.ideology_synergy_offsets[ideology_id + 1]):
			var synergy_id := int(out.ideology_synergy_ids[cursor])
			synergy_effect_count += int(out.synergy_effect_offsets[synergy_id + 1]) \
				- int(out.synergy_effect_offsets[synergy_id])
		max_transition_commands = maxi(max_transition_commands,
			base_transition_commands + synergy_effect_count)
	if max_transition_commands > effective_profile.max_transition_commands:
		return {"ok": false, "reason": "ideology_transition_command_limit_exceeded"}
	if int(tally["owned"]) > effective_profile.max_effect_instances:
		return {"ok": false, "reason": "ideology_effect_instance_limit_exceeded"}
	# Concurrency budget. Slots are the GROWN capacities: a save that unlocked
	# both slot technologies is the state this has to survive, and the base
	# capacities would let a catalog through that dies on a late-game loadout.
	var concurrency_slots := maxi(effective_profile.ideology_capacity,
		effective_profile.ideology_capacity_max) + maxi(
		effective_profile.national_spirit_capacity,
		effective_profile.national_spirit_capacity_max)
	var worst_live_instances := concurrency_slots * widest_card_instances
	if worst_live_instances > effective_profile.max_concurrent_instances:
		# Names both numbers and the slot count: "which of the two budgets did I
		# blow" is the first question, and a bare `false` cannot answer it.
		return {"ok": false, "reason":
			"ideology_concurrent_instance_limit_exceeded:%d>%d:%dx%d" % [
				worst_live_instances,
				effective_profile.max_concurrent_instances,
				concurrency_slots, widest_card_instances]}
	out["declared_effect_instances"] = int(tally["owned"])
	out["max_concurrent_instances"] = effective_profile.max_concurrent_instances
	out["concurrency_slots"] = concurrency_slots
	out["max_instances_per_card"] = widest_card_instances
	out["worst_case_concurrent_instances"] = worst_live_instances
	# Material support model. The channel count must be identical to Economy's
	# published incidence_channel_count, so both sides derive it from the same
	# need_ids column instead of a literal.
	out["incidence_channel_count"] = incidence["channel_count"]
	out["incidence_level_channels_q16"] = incidence["rows"]
	out["incidence_level_measured"] = incidence["measured"]
	out["incidence_unmapped_stat_count"] = incidence["unmapped"]
	out.ok = true
	return out


static func era_rows() -> Array:
	if _era_rows_cache.is_empty():
		var technology_script = load("res://scripts/economy/technology_catalog.gd")
		var payload: Dictionary = technology_script._network_payload() \
			if technology_script != null else {}
		var rows: Array = (payload.get("eras", []) as Array).duplicate()
		rows.sort_custom(func(a, b) -> bool:
			return float(a.get("sort_order", 0)) < float(b.get("sort_order", 0)))
		_era_rows_cache = rows
	return _era_rows_cache
