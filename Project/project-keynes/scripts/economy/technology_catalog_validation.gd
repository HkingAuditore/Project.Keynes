class_name TechnologyCatalogValidation
extends RefCounted

## A support_only node opens no new building: its expected bindings may only
## carry production-method rows (`method_*`) of buildings opened elsewhere.
static func _building_review_matches_bindings(row: Dictionary) -> bool:
	var review: Dictionary = row.get("building_unlock_review", {})
	if String(review.get("policy", "")) != "support_only":
		return true
	for binding_value in row.get("expected_bindings", []):
		if not binding_value is Dictionary:
			continue
		var binding: Dictionary = binding_value
		if int(binding.get("kind", 0)) == 2 \
				and not String(binding.get("id", "")).begins_with("method_"):
			return false
	return true


static func _validate_content_effects(effects: Array, expected_bindings: Array) -> bool:
	var expected := {}
	for binding_value in expected_bindings:
		var binding: Dictionary = binding_value
		expected["%d|%s" % [int(binding.get("kind", 0)), String(binding.get("id", ""))]] = false
	for effect_value in effects:
		if not effect_value is Dictionary:
			return false
		var effect: Dictionary = effect_value
		var effect_id := String(effect.get("id", "")).strip_edges()
		if String(effect.get("kind", "")).strip_edges().is_empty() or effect_id.is_empty() \
				or String(effect.get("subject", "")).is_empty() \
				or String(effect.get("attribute", "")).is_empty() \
				or String(effect.get("operation", "")).is_empty() \
				or String(effect.get("implementation", "")).is_empty() \
				or String(effect.get("status", "")).is_empty():
			return false
		var binding_kind := int(effect.get("binding_kind", 0))
		if binding_kind > 0:
			var key := "%d|%s" % [binding_kind, effect_id]
			if not expected.has(key):
				return false
			expected[key] = true
	for key in expected:
		if not bool(expected[key]):
			return false
	return true
