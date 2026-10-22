class_name IdeologyCatalog
extends Resource

const DEFAULT_PATH := "res://data/ideologies/default_ideology_catalog.tres"
const IdeologyDefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const IdeologyRequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")
const IdeologyProfileScript = preload("res://scripts/ideology/ideology_profile.gd")
const IdeologyClassStanceScript = preload("res://scripts/ideology/ideology_class_stance.gd")
const IdeologySynergyDefinitionScript = preload("res://scripts/ideology/ideology_synergy_definition.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
## Only for `SELECTOR_MAX_CELLS`: the concurrency budget must use the same cell
## cap the runtime enforces, and a second literal here is exactly the mirror
## constant that drifted the last three times this project tried it.
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")

const PROTOCOL_VERSION := 1
## Card effect rows name a program by its BARE key (`v1_granary_belt`); the
## compiler and the runtime both store it prefixed (`ideology.effect.<key>`,
## see IdeologyEffectDefinition.program_key and
## NativeIdeologyRuntime::effect_program_key). Comparing a row key against the
## declared set without this prefix silently reports zero owned programs, which
## left the instance budget unenforced.
const PROGRAM_KEY_PREFIX := "ideology.effect."
## Display order and labels of the six schools (流派). Resonance rows and the
## collection tabs follow this order.
const SCHOOLS := [
	{"id": "agrarian", "name": "农本", "motto": "重农固本，仓廩实而知礼节"},
	{"id": "commerce", "name": "商贸", "motto": "通有无，兴市舶，以财养国"},
	{"id": "learning", "name": "学识", "motto": "格物致知，以学立政"},
	{"id": "mobilization", "name": "动员", "motto": "聚众成城，万人一心"},
	{"id": "industry", "name": "工造", "motto": "利器善事，百工居胆"},
	{"id": "harmony", "name": "调和", "motto": "顺天应时，山泽有度"},
]
const LEVEL_LABELS := ["初识", "通晓", "化育"]

@export var profile: Resource
@export var definitions: Array[Resource] = []
@export var synergies: Array[Resource] = []
## Declarative effect programs (`ideology.effect.<definition_key>`) that replace
## the legacy "one-shot Modifier per effect row" path. Null falls back to the
## default catalog, so a project without authored programs keeps the old shape.
@export var effect_programs: Resource

static func load_default() -> Resource:
	var loaded := ResourceLoader.load(DEFAULT_PATH, "Resource")
	return loaded

func compile_native_catalog(country_catalog: Dictionary,
		economy_catalog: Dictionary = {}) -> Dictionary:
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
				_program_live_target_cap(effect)
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
		"political_class_ids": PackedStringArray(political_class_ids),
		"ideology_ids": PackedStringArray(), "acquisition_flags": PackedByteArray(),
		"rarity_weights": PackedInt32Array(), "ideology_slot_costs": PackedInt32Array(),
		"spirit_slot_costs": PackedInt32Array(), "national_spirit_min_levels": PackedInt32Array(),
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
			var effect_error := _append_effect_rows(out, level.persistent_effects, true,
				declared_programs, tally)
			if not effect_error.is_empty(): return {"ok": false, "reason": effect_error}
			effect_error = _append_effect_rows(out, level.on_enter_effects, false,
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
	for definition in ordered:
		var definition_dense := int(ideology_index[String(definition.id)])
		for route in definition.route_tags():
			if not route_index.has(route):
				route_index[route] = PackedInt32Array()
			var bucket: PackedInt32Array = route_index[route]
			bucket.append(definition_dense)
			route_index[route] = bucket
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
			var target_key: String = IdeologyEffectDefinitionScript.definition_key_of(
				override.target_definition_key)
			if target_key.is_empty() or not declared_programs.has(target_key):
				return {"ok": false, "reason":
					"ideology_synergy_override_target_unknown:%s" % String(
						override.target_definition_key)}
			out.synergy_override_programs.append(target_key)
			out.synergy_override_scales.append(int(override.value))
		out.synergy_override_offsets.append(out.synergy_override_programs.size())
		if synergy.uses_route_tag():
			var expanded: Dictionary = _expand_route_synergy_members(
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
		synergy_error = _append_synergy_effect_rows(
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
	out.ok = true
	return out

func _append_effect_rows(out: Dictionary, effects: Array[Resource], persistent: bool,
		declared_programs: Dictionary, tally: Dictionary) -> String:
	var prefix := "persistent" if persistent else "on_enter"
	for effect in effects:
		if effect == null or not effect is EffectCommandScript:
			return "ideology_effect_resource_invalid"
		if effect.command_key == &"" or effect.definition_key == &"":
			return "ideology_effect_invalid"
		# A row that names a declared program is a routing marker: the program
		# (compiled into EffectRuntime) owns conditions, cadence, target selector
		# and magnitude, so the row's own domain/opcode/selector are not used.
		# Emitting the row keeps level_persistent_offsets aligned.
		if declared_programs.has(PROGRAM_KEY_PREFIX + String(effect.definition_key)):
			tally["owned"] = int(tally["owned"]) + 1
			var bucket := "persistent" if persistent else "enter"
			tally[bucket] = int(tally[bucket]) + 1
			out["%s_actions" % prefix].append(effect.action)
			out["%s_domains" % prefix].append(effect.domain)
			out["%s_opcodes" % prefix].append(effect.opcode)
			out["%s_values_q16" % prefix].append(effect.value_q16)
			out["%s_duration_days" % prefix].append(effect.duration_days)
			out["%s_stacks" % prefix].append(effect.stacks)
			out["%s_command_keys" % prefix].append(String(effect.command_key))
			out["%s_definition_keys" % prefix].append(String(effect.definition_key))
			out["%s_payload_i0" % prefix].append(effect.payload_i0)
			out["%s_payload_i1" % prefix].append(effect.payload_i1)
			out["%s_payload_i2" % prefix].append(effect.payload_i2)
			out["%s_payload_i3" % prefix].append(effect.payload_i3)
			continue
		if effect.action < 1 or effect.action > 6 or effect.domain < 0 or effect.domain >= 32 \
				or effect.stacks <= 0 or effect.duration_days < -1 \
				or effect.target_resolver < 0 or effect.target_resolver > 2 \
				or effect.value_mode < 0 or effect.value_mode > 1:
			return "ideology_effect_invalid"
		if effect.target_resolver == 0 and effect.static_target == 0:
			return "ideology_effect_static_target_invalid"
		if effect.target_resolver != 1:
			return "ideology_effect_target_resolver_invalid"
		if persistent and (effect.action != 1 or effect.domain < 0 or effect.domain > 3 \
				or effect.opcode != 1):
			return "ideology_persistent_effect_not_reversible_modifier"
		if not persistent:
			match int(effect.action):
				1:
					if effect.domain < 0 or effect.domain > 3 or effect.opcode != 1:
						return "ideology_modifier_effect_opcode_invalid"
				2:
					if effect.domain != 1 or effect.opcode < 1 or effect.opcode > 14:
						return "ideology_country_effect_opcode_invalid"
				3:
					if effect.domain != 2 or effect.opcode < 1 or effect.opcode > 15:
						return "ideology_economy_effect_opcode_invalid"
				4:
					if effect.domain != 3 or effect.opcode <= 0:
						return "ideology_gameplay_effect_opcode_invalid"
				5:
					if effect.domain != 4 or effect.opcode <= 0:
						return "ideology_publish_event_opcode_invalid"
				6:
					if effect.domain != 6 or effect.opcode != 1:
						return "ideology_custom_domain_adapter_unregistered"
				_:
					return "ideology_effect_action_invalid"
		out["%s_actions" % prefix].append(effect.action)
		out["%s_domains" % prefix].append(effect.domain)
		out["%s_opcodes" % prefix].append(effect.opcode)
		out["%s_values_q16" % prefix].append(effect.value_q16)
		out["%s_duration_days" % prefix].append(effect.duration_days)
		out["%s_stacks" % prefix].append(effect.stacks)
		out["%s_command_keys" % prefix].append(String(effect.command_key))
		out["%s_definition_keys" % prefix].append(String(effect.definition_key))
		out["%s_payload_i0" % prefix].append(effect.payload_i0)
		out["%s_payload_i1" % prefix].append(effect.payload_i1)
		out["%s_payload_i2" % prefix].append(effect.payload_i2)
		out["%s_payload_i3" % prefix].append(effect.payload_i3)
	out["level_%s_offsets" % prefix].append(out["%s_actions" % prefix].size())
	return ""

func _append_synergy_effect_rows(out: Dictionary,
		effects: Array[Resource]) -> String:
	for effect in effects:
		if effect == null or not effect is EffectCommandScript:
			return "ideology_synergy_effect_resource_invalid"
		if effect.action != 1 or effect.domain < 0 or effect.domain > 3 \
				or effect.opcode != 1 or effect.stacks <= 0 \
				or effect.duration_days < -1 or effect.target_resolver != 1 \
				or effect.command_key == &"" or effect.definition_key == &"":
			return "ideology_synergy_effect_not_reversible_modifier"
		out.synergy_effect_actions.append(effect.action)
		out.synergy_effect_domains.append(effect.domain)
		out.synergy_effect_opcodes.append(effect.opcode)
		out.synergy_effect_values_q16.append(effect.value_q16)
		out.synergy_effect_duration_days.append(effect.duration_days)
		out.synergy_effect_stacks.append(effect.stacks)
		out.synergy_effect_command_keys.append(String(effect.command_key))
		out.synergy_effect_definition_keys.append(String(effect.definition_key))
		out.synergy_effect_payload_i0.append(effect.payload_i0)
		out.synergy_effect_payload_i1.append(effect.payload_i1)
		out.synergy_effect_payload_i2.append(effect.payload_i2)
		out.synergy_effect_payload_i3.append(effect.payload_i3)
	out.synergy_effect_offsets.append(out.synergy_effect_actions.size())
	return ""

func catalog_view(country_catalog: Dictionary = {},
		economy_catalog: Dictionary = {}) -> Dictionary:
	var compiled := compile_native_catalog(country_catalog, economy_catalog)
	if not bool(compiled.get("ok", false)): return compiled
	var modifier_catalog = ModifierCatalogScript.load_default()
	var rows: Array[Dictionary] = []
	for i in compiled.ideology_ids.size():
		var definition = null
		for candidate in definitions:
			if candidate != null and String(candidate.id) == String(compiled.ideology_ids[i]):
				definition = candidate
				break
		if definition == null:
			continue
		var level_thresholds := PackedInt64Array()
		var level_effect_lines: Array = []
		for level in definition.levels:
			level_thresholds.append(level.understanding_threshold_q16)
			level_effect_lines.append(_present_effect_lines(
				modifier_catalog, level.persistent_effects))
		var level_labels := PackedStringArray()
		for level_index in definition.levels.size():
			level_labels.append(LEVEL_LABELS[level_index] if level_index < LEVEL_LABELS.size()
				else "%d级" % (level_index + 1))
		var required_technologies := PackedStringArray()
		var required_technology_names := PackedStringArray()
		var required_gates := PackedStringArray()
		for requirement in definition.draw_requirements:
			if requirement == null:
				continue
			if requirement.kind == IdeologyRequirementScript.Kind.TECHNOLOGY:
				required_technologies.append(String(requirement.key))
				required_technology_names.append(technology_display_name(String(requirement.key)))
			elif requirement.kind == IdeologyRequirementScript.Kind.GATE:
				required_gates.append(String(requirement.key))
		rows.append({"id": String(definition.id), "dense_id": i, "icon_key": String(definition.icon_key),
			"name_key": String(definition.name_key),
			"display_name": _display_name(definition),
			"detail_key": String(definition.detail_key),
			"school_id": String(definition.school_id),
			"school_name": school_name(String(definition.school_id)),
			"era_index": int(definition.era_index),
			"era_name": era_display_name(int(definition.era_index)),
			"route_tag": String(definition.route_tag),
			"required_gates": required_gates,
			"rarity": int(definition.rarity),
			"rarity_label": String(IdeologyDefinitionScript.RARITY_LABELS.get(
				int(definition.rarity), "")),
			"level_labels": level_labels,
			"required_technologies": required_technologies,
			"required_technology_names": required_technology_names,
			"rarity_weight": definition.rarity_weight, "ideology_slot_cost": definition.ideology_slot_cost,
			"national_spirit_slot_cost": definition.national_spirit_slot_cost,
			"acquisition_flags": definition.acquisition_flags,
			"min_spirit_level": definition.national_spirit_min_level,
			"level_thresholds_q16": level_thresholds,
			"level_effect_lines": level_effect_lines,
			"adopt_threshold_q16": definition.adopt_threshold_q16,
			"repeal_threshold_q16": definition.repeal_threshold_q16,
			"promote_threshold_q16": definition.promote_threshold_q16,
			"exclusion_group": String(definition.exclusion_group),
			"exclusion_rivals": _exclusion_rivals(definition),
			"route_tags": definition.route_tags(),
			"route_names": _route_display_names(definition.route_tags()),
			"synergy_names": PackedStringArray(),
			"synergy_tooltip": ""})
	var synergy_rows: Array[Dictionary] = []
	var synergy_by_ideology: Dictionary = {}
	for i in compiled.synergy_ids.size():
		var synergy = _synergy_resource(String(compiled.synergy_ids[i]))
		if synergy == null:
			continue
		# Requirement rows are read back from the compiled table, not re-derived
		# from the resource. A named synergy and an expanded route synergy both
		# land here as the same thing, so the UI has exactly one shape to handle
		# and cannot disagree with what the runtime will actually check.
		var member_ids := PackedStringArray()
		var member_names := PackedStringArray()
		var requirement_begin := int(compiled.synergy_requirement_offsets[i])
		var requirement_end := int(compiled.synergy_requirement_offsets[i + 1])
		for cursor in range(requirement_begin, requirement_end):
			var dense := int(compiled.synergy_requirement_ideology_ids[cursor])
			member_ids.append(String(compiled.ideology_ids[dense]))
			member_names.append(_display_name_for_id(
				String(compiled.ideology_ids[dense])))
		var effect_lines := _present_effect_lines(
			modifier_catalog, synergy.persistent_effects)
		var display := _synergy_display_name(synergy)
		var effect_text := "、".join(effect_lines) if not effect_lines.is_empty() else "额外国家修正"
		var route_key := String(synergy.route_tag).strip_edges()
		var tooltip := "同时装备%s：%s" % ["与".join(member_names), effect_text]
		if synergy.uses_route_tag():
			tooltip = "%s体系·%d张：%s" % [route_display_name(route_key),
				int(synergy.min_count), effect_text]
		var resonance_school := String(synergy.school_id)
		if not resonance_school.is_empty():
			tooltip = "%s共鸣·%d张：%s" % [school_name(resonance_school),
				int(synergy.min_count), effect_text]
		synergy_rows.append({
			"dense_id": i,
			"id": String(compiled.synergy_ids[i]),
			"display_name": display,
			"effect_lines": effect_lines,
			"required_names": member_names,
			"required_ids": member_ids,
			"route_tag": route_key,
			"minimum_levels": synergy.minimum_levels if not synergy.uses_route_tag() \
				else PackedInt32Array(),
			"min_count": int(synergy.min_count),
			"school_id": resonance_school,
			"resonance_tier": int(synergy.resonance_tier),
			"tooltip": tooltip,
		})
		if not resonance_school.is_empty():
			continue
		for required_id in member_ids:
			var key := String(required_id)
			var attached: Array = synergy_by_ideology.get(key, [])
			attached.append({"display_name": display, "tooltip": tooltip})
			synergy_by_ideology[key] = attached
	for row in rows:
		var attached: Array = synergy_by_ideology.get(String(row.get("id", "")), [])
		var names := PackedStringArray()
		var tooltips := PackedStringArray()
		for item in attached:
			names.append(String((item as Dictionary).get("display_name", "")))
			tooltips.append(String((item as Dictionary).get("tooltip", "")))
		row["synergy_names"] = names
		row["synergy_tooltip"] = "\n".join(tooltips)
	var unlock_keys := PackedStringArray(
		profile.capacity_unlock_technology_keys if profile != null else PackedStringArray())
	var unlock_names := PackedStringArray()
	for key in unlock_keys:
		unlock_names.append(technology_display_name(String(key)))
	return {"ok": true, "ideologies": rows, "synergies": synergy_rows,
		"schools": SCHOOLS.duplicate(true),
		"political_class_ids": compiled.political_class_ids,
		"gate_keys": compiled.gate_keys,
		"ideology_capacity": int(compiled.get("ideology_capacity", 0)),
		"national_spirit_capacity": int(compiled.get("national_spirit_capacity", 0)),
		"ideology_capacity_max": int(compiled.get("ideology_capacity_max", 0)),
		"national_spirit_capacity_max": int(compiled.get("national_spirit_capacity_max", 0)),
		"capacity_unlock_technology_keys": unlock_keys,
		"capacity_unlock_technology_names": unlock_names,
		"capacity_unlock_ideology_deltas": compiled.get("capacity_unlock_ideology_deltas", PackedInt32Array()),
		"capacity_unlock_spirit_deltas": compiled.get("capacity_unlock_spirit_deltas", PackedInt32Array()),
		"offer_cost_q16": int(compiled.get("offer_cost_q16", 65536)),
		"offer_cost_growth_percent": int(compiled.get("offer_cost_growth_percent", 100)),
		"starting_points_q16": int(compiled.get("starting_points_q16", 0))}


## Expands a route-tag synergy selector into the concrete dense card ids it
## covers. Pure: it takes the already-built route index and returns either the
## member list or a rejection that names the route and the numbers involved.
##
## Split out of `compile_native_catalog` because every interesting case here is
## a boundary -- an unknown route, a tier taller than its route, an empty
## bucket -- and those cost a whole compiled catalog to stage inline while
## costing one line to stage here.
static func _expand_route_synergy_members(route_tag: String,
		route_index: Dictionary, min_count: int) -> Dictionary:
	var route_key := route_tag.strip_edges()
	if route_key.is_empty():
		return {"ok": false, "reason": "ideology_synergy_route_tag_empty"}
	if not route_index.has(route_key):
		return {"ok": false, "reason":
			"ideology_synergy_route_tag_unknown:%s" % route_key}
	var members: PackedInt32Array = route_index[route_key]
	# An empty bucket is a *different* failure from an unknown tag: the tag is
	# spelled right and n cards carry it -- there are just no cards yet. Kept
	# apart because the fix differs (author cards vs fix the id), and a shared
	# message would send the next reader to the wrong file.
	if members.is_empty():
		return {"ok": false, "reason":
			"ideology_synergy_route_tag_no_members:%s" % route_key}
	# A tier that can never open is worse than a missing tier: it reads as an
	# implemented bond in the UI and never fires.
	if min_count > members.size():
		return {"ok": false, "reason":
			"ideology_synergy_route_tag_min_count_exceeds_members:%s:%d>%d" % [
				route_key, min_count, members.size()]}
	return {"ok": true, "members": members, "route_tag": route_key}


## How many live Effect instances one program row can own at once.
##
## This is the multiplicand the concurrency budget was missing. Three tiers:
##
##  * Not a per-cell domain -> exactly one instance (a country/climate/resource
##    program is one instance per card no matter what its selector says).
##  * A per-cell domain with a single-target selector -> one instance.
##  * A per-cell domain with a fan-out selector -> the program's own cell cap,
##    or `SELECTOR_MAX_CELLS` when it leaves the cap at the runtime default.
##
## Deliberately an upper bound rather than a measurement: the point is to fail
## on a catalog that CAN exceed the budget, and a real map may legitimately be
## smaller. Under-counting here would be the same silent pass this change
## exists to remove.
static func _program_live_target_cap(program: Resource) -> int:
	const SINGLE_TARGET_KINDS := [0, 2, 3, 4, 5]
	const STACK_POLICY_ADD_STACK := 2
	# L2-8: an ADD_STACK program owns one instance PER LAYER, because each layer
	# carries its own duration. The budget has to count them: a 3-stack program
	# fans out 3x, not 1x, and the whole point of the concurrency check is that a
	# catalog which cannot fit is rejected at build time.
	var layers := 1
	if int(program.stack_policy) == STACK_POLICY_ADD_STACK:
		layers = maxi(1, mini(int(program.max_stacks), 64))
	if int(program.target_domain) != 2:
		return layers
	if int(program.target_selector_kind) in SINGLE_TARGET_KINDS:
		return layers
	var params: PackedInt32Array = program.target_selector_param
	var cells := IdeologyEffectDefinitionScript.SELECTOR_MAX_CELLS
	if params.size() > 0:
		var declared_cap := int(params[0])
		if declared_cap >= 1:
			cells = mini(declared_cap, IdeologyEffectDefinitionScript.SELECTOR_MAX_CELLS)
	return layers * cells


static func school_name(school_id: String) -> String:
	for school in SCHOOLS:
		if String(school.id) == school_id:
			return String(school.name)
	return school_id


## Display names for the build routes (体系) that route-tag synergies are keyed
## by. Ids are the contract; these strings are presentation only and falling
## back to the raw id is a supported outcome, so adding a route to the content
## never requires touching this table before it can be referenced.
const ROUTE_DISPLAY_NAMES := {
	"cropland": "田垄",
	"granary": "仓廪",
	"mining": "矿冶",
	"workshop": "工坊",
	"market": "市易",
	"thoroughfare": "通衢",
	"learning": "学识",
	"labor": "劳作",
	"livelihood": "生灵",
	"clan": "宗族",
	"era": "纪元",
	"fiscal": "度支",
	"season": "天时",
	"terrain": "山河",
}


static func route_display_name(route_tag: String) -> String:
	return String(ROUTE_DISPLAY_NAMES.get(route_tag, route_tag))


static func _route_display_names(tags: PackedStringArray) -> PackedStringArray:
	var names := PackedStringArray()
	for tag in tags:
		names.append(route_display_name(String(tag)))
	return names


static var _technology_names := {}


## Cold-path display name for a technology key (slot unlock captions and draw
## requirements). Reads the cached authoring network once.
static func technology_display_name(technology_key: String) -> String:
	if _technology_names.is_empty():
		var technology_script = load("res://scripts/economy/technology_catalog.gd")
		var payload: Dictionary = technology_script._network_payload() \
			if technology_script != null else {}
		for node in payload.get("nodes", []) as Array:
			if node is Dictionary:
				_technology_names[String(node.get("id", ""))] = String(
					node.get("display_name", node.get("id", "")))
		_technology_names[""] = ""
	return String(_technology_names.get(technology_key, technology_key))


static var _era_rows_cache: Array = []


## Ordered era table read from the authoring network once. Era index -> entry
## milestone, display name and decay display all resolve through here so the
## ideology layer never depends on TechnologyCatalog being compiled first.
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


static func era_display_name(era_index: int) -> String:
	var rows := era_rows()
	if era_index < 0 or era_index >= rows.size():
		return ""
	return String((rows[era_index] as Dictionary).get("display_name", ""))


## Technology that must be completed before the player counts as "in" this era,
## i.e. the era's own entry gate. Empty for era 0 (no gate).
static func era_entry_technology_key(era_index: int) -> String:
	var rows := era_rows()
	if era_index <= 0 or era_index >= rows.size():
		return ""
	return String((rows[era_index] as Dictionary).get("entry_milestone_id", ""))


func _display_name(definition) -> String:
	var name_key := String(definition.name_key)
	if not name_key.is_empty() and not name_key.contains("."):
		return name_key
	return String(definition.id)


func _display_name_for_id(ideology_id: String) -> String:
	for definition in definitions:
		if definition != null and String(definition.id) == ideology_id:
			return _display_name(definition)
	return ideology_id


func _exclusion_rivals(definition) -> PackedStringArray:
	var rivals := PackedStringArray()
	var group := String(definition.exclusion_group).strip_edges()
	if group.is_empty():
		return rivals
	for other in definitions:
		if other == null or other == definition \
				or String(other.exclusion_group).strip_edges() != group:
			continue
		rivals.append(_display_name(other))
	return rivals


func _synergy_resource(synergy_id: String):
	for synergy in synergies:
		if synergy != null and String(synergy.id) == synergy_id:
			return synergy
	return null


func _synergy_display_name(synergy) -> String:
	var display := String(synergy.display_name).strip_edges()
	if not display.is_empty():
		return display
	return String(synergy.id)


func _present_effect_lines(modifier_catalog, effects: Array[Resource]) -> PackedStringArray:
	var lines := PackedStringArray()
	if modifier_catalog != null and modifier_catalog.has_method("present_definition"):
		for effect in effects:
			if effect == null or not effect is EffectCommandScript:
				continue
			for line in modifier_catalog.present_definition(
					effect.definition_key, int(effect.value_q16)):
				if not lines.has(line):
					lines.append(line)
	# A managed program row names a program, not a Modifier definition, so the
	# presenter above returns nothing for it. Falling back to the program's own
	# summary is the only thing standing between a cell-level card and a card
	# face that lists its cost and nothing else.
	for effect in effects:
		if effect == null or not effect is EffectCommandScript:
			continue
		var summary := _program_summary(String(effect.definition_key))
		if not summary.is_empty() and not lines.has(summary):
			lines.append(summary)
	return lines


## Player-facing summary of the managed program named by `definition_key`.
##
## `effect_programs` is optional: a catalog that declares no programs (every
## fixture before this round, and any save-less test) simply yields "".
func _program_summary(definition_key: String) -> String:
	if definition_key.is_empty():
		return ""
	var catalog: Resource = effect_programs
	if catalog == null:
		return ""
	var rows: Variant = catalog.get("effects")
	if rows == null:
		return ""
	for program in rows:
		if program == null:
			continue
		if String(program.get("definition_key")) != definition_key:
			continue
		var summary: Variant = program.get("summary")
		if summary == null:
			return ""
		return String(summary).strip_edges()
	return ""
