class_name NarrativeOutcome
extends Resource

const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")

@export var probability_q16: int = 65536
@export var outcome_title: String = ""
@export_multiline var outcome_narrative: String = ""
@export var effects: Array[Resource] = []

func to_dict() -> Dictionary:
	var serialized_effects: Array = []
	for eff in effects:
		if eff != null and eff.has_method("to_dict"):
			serialized_effects.append(eff.to_dict())
	return {
		"probability_q16": probability_q16,
		"outcome_title": outcome_title,
		"outcome_narrative": outcome_narrative,
		"effects": serialized_effects,
	}

static func from_dict(d: Dictionary) -> NarrativeOutcome:
	var outcome := NarrativeOutcome.new()
	if d.is_empty():
		return outcome
	outcome.probability_q16 = int(d.get("probability_q16", 65536))
	outcome.outcome_title = String(d.get("outcome_title", ""))
	outcome.outcome_narrative = String(d.get("outcome_narrative", ""))
	var raw_effects: Variant = d.get("effects", [])
	var parsed_effects: Array[Resource] = []
	if raw_effects is Array:
		for item in raw_effects:
			if item is NarrativeEffectSpec:
				parsed_effects.append(item)
			elif item is Dictionary:
				parsed_effects.append(NarrativeEffectSpecScript.from_dict(item as Dictionary))
	outcome.effects = parsed_effects
	return outcome
