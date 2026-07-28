class_name ModifierCatalog
extends Resource

const DEFAULT_PATH := "res://data/modifiers/default_modifier_catalog.tres"
const StatDefinitionScript = preload("res://scripts/modifier/modifier_stat_definition.gd")
const DefinitionScript = preload("res://scripts/modifier/modifier_definition.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

const TECHNOLOGY_STATS := [
	["country.research.agriculture_efficiency", 0.0, 1.6],
	["country.research.engineering_efficiency", 0.0, 1.6],
	["country.research.science_efficiency", 0.0, 1.6],
	["country.research.society_efficiency", 0.0, 1.6],
	["country.research.cost_factor", 0.65, 4.0],
	["country.research.institution_output_factor", 0.0, 3.0],
	["country.output.agriculture_factor", 0.0, 3.0],
	["country.output.extractive_factor", 0.0, 3.0],
	["country.output.manufacturing_factor", 0.0, 3.0],
	["country.output.energy_factor", 0.0, 3.0],
	["country.output.knowledge_factor", 0.0, 3.0],
	["country.construction.cost_factor", 0.65, 4.0],
	["country.construction.time_factor", 0.65, 4.0],
	["country.trade.capacity_factor", 0.0, 2.0],
	["country.trade.speed_factor", 0.0, 1.5],
]

@export var stats: Array[Resource] = []
@export var definitions: Array[Resource] = []


static func load_default() -> Resource:
	return ResourceLoader.load(DEFAULT_PATH, "Resource")


func compile_native_catalog() -> Dictionary:
	var out := {
		"stat_keys": PackedStringArray(),
		"stat_domains": PackedInt32Array(),
		"stat_min_values": PackedFloat64Array(),
		"stat_max_values": PackedFloat64Array(),
		"stat_persistable": PackedByteArray(),
		"definition_keys": PackedStringArray(),
		"definition_versions": PackedInt32Array(),
		"definition_domains": PackedInt32Array(),
		"definition_policies": PackedInt32Array(),
		"definition_max_stacks": PackedInt32Array(),
		"definition_default_duration": PackedInt32Array(),
		"definition_term_offsets": PackedInt32Array([0]),
		"term_stat_ids": PackedInt32Array(),
		"term_operations": PackedInt32Array(),
		"term_values": PackedFloat64Array(),
	}
	var stat_ids := {}
	for stat in stats:
		if stat == null or stat.key == &"" or stat_ids.has(stat.key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		if not is_finite(stat.min_value) or not is_finite(stat.max_value) \
				or stat.min_value > stat.max_value:
			return {"ok": false, "reason": "modifier_stat_range_invalid"}
		stat_ids[stat.key] = out.stat_keys.size()
		out.stat_keys.append(String(stat.key))
		out.stat_domains.append(stat.domain)
		out.stat_min_values.append(stat.min_value)
		out.stat_max_values.append(stat.max_value)
		out.stat_persistable.append(1 if stat.persistable else 0)
	for row in TECHNOLOGY_STATS:
		var key := StringName(row[0])
		if stat_ids.has(key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		stat_ids[key] = out.stat_keys.size()
		out.stat_keys.append(String(key))
		out.stat_domains.append(1)
		out.stat_min_values.append(float(row[1]))
		out.stat_max_values.append(float(row[2]))
		out.stat_persistable.append(1)
	var definition_keys := {}
	for definition in definitions:
		if definition == null or definition.key == &"" \
				or definition_keys.has(definition.key) or definition.version <= 0 \
				or definition.max_stacks <= 0 or definition.terms.is_empty():
			return {"ok": false, "reason": "modifier_definition_invalid_or_duplicate"}
		if definition.default_duration_days != -1 and definition.default_duration_days <= 0:
			return {"ok": false, "reason": "modifier_definition_duration_invalid"}
		definition_keys[definition.key] = true
		out.definition_keys.append(String(definition.key))
		out.definition_versions.append(definition.version)
		out.definition_domains.append(definition.domain)
		out.definition_policies.append(definition.stack_policy)
		out.definition_max_stacks.append(definition.max_stacks)
		out.definition_default_duration.append(definition.default_duration_days)
		for term in definition.terms:
			if term == null or not stat_ids.has(term.stat_key) or not is_finite(term.value):
				return {"ok": false, "reason": "modifier_term_invalid"}
			var stat: Resource = stats[int(stat_ids[term.stat_key])]
			if stat.domain != definition.domain or (stat.allowed_operations & (1 << term.operation)) == 0:
				return {"ok": false, "reason": "modifier_term_domain_or_operation_invalid"}
			if term.operation == 3 and term.value == 0.0:
				return {"ok": false, "reason": "modifier_term_division_by_zero"}
			out.term_stat_ids.append(int(stat_ids[term.stat_key]))
			out.term_operations.append(term.operation)
			out.term_values.append(term.value)
		out.definition_term_offsets.append(out.term_values.size())
	var technologies: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	if not bool(technologies.get("ok", false)):
		return technologies
	for i in range(technologies.technology_ids.size()):
		if (int(technologies.technology_flags[i]) & TechnologyCatalogScript.FLAG_STARTING) != 0:
			continue
		var definition_key := String(technologies.technology_modifier_definition_keys[i])
		if definition_keys.has(definition_key):
			return {"ok": false, "reason": "modifier_definition_invalid_or_duplicate"}
		definition_keys[definition_key] = true
		out.definition_keys.append(definition_key)
		out.definition_versions.append(1)
		out.definition_domains.append(1)
		out.definition_policies.append(1)
		out.definition_max_stacks.append(1)
		out.definition_default_duration.append(-1)
		var technology_terms := TechnologyCatalogScript.modifier_terms(
			String(technologies.technology_ids[i]),
			int(technologies.technology_domain_indices[i]),
			int(technologies.technology_flags[i]))
		for term in technology_terms:
			var stat_key := StringName(term.stat)
			if not stat_ids.has(stat_key):
				return {"ok": false, "reason": "modifier_term_invalid"}
			out.term_stat_ids.append(int(stat_ids[stat_key]))
			out.term_operations.append(int(term.operation))
			out.term_values.append(float(term.value))
		out.definition_term_offsets.append(out.term_values.size())
	out["ok"] = true
	return out
