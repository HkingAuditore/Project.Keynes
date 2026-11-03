class_name NarrativeWeightRule
extends Resource

const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

@export var condition: NarrativeCondition
@export var add_weight: int = 0
@export var multiplier_q16: int = 65536
@export var reason: String = ""

func matches(ctx: Dictionary) -> bool:
	if condition == null:
		return true
	return condition.evaluate(ctx)

func evaluate_rule(ctx: Dictionary) -> bool:
	return matches(ctx)

func to_dict() -> Dictionary:
	return {
		"condition": condition.to_dict() if condition != null else {},
		"add_weight": add_weight,
		"multiplier_q16": multiplier_q16,
		"reason": reason,
	}

static func from_dict(d: Dictionary) -> NarrativeWeightRule:
	var rule := NarrativeWeightRule.new()
	if d.is_empty():
		return rule
	var raw_cond: Variant = d.get("condition", null)
	if raw_cond is NarrativeCondition:
		rule.condition = raw_cond
	elif raw_cond is Dictionary and not (raw_cond as Dictionary).is_empty():
		rule.condition = NarrativeConditionScript.from_dict(raw_cond as Dictionary)
	rule.add_weight = int(d.get("add_weight", 0))
	rule.multiplier_q16 = int(d.get("multiplier_q16", 65536))
	rule.reason = String(d.get("reason", ""))
	return rule
