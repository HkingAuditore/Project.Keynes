extends RefCounted

## Common effect constructors for acquiring or losing a family trait.

const NarrativeEffectSpecScript = preload("res://scripts/narrative/narrative_effect_spec.gd")


static func grant(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.GRANT_FAMILY_TRAIT,
		"target_key": trait_key,
		"magnitude_q16": 65536,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」获特质「%s」，永久" % display_name,
	}


static func remove(trait_key: String, display_name: String) -> Dictionary:
	return {
		"kind": NarrativeEffectSpecScript.Kind.REMOVE_FAMILY_TRAIT,
		"target_key": trait_key,
		"duration_days": 1,
		"custom_label": "本地最大族「{family_name}」失去特质「%s」" % display_name,
	}
