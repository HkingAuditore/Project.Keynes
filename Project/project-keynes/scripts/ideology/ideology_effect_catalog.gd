class_name IdeologyEffectCatalog
extends Resource

## Authored ideology effect programs, compiled into the shared EffectCatalog.
## Programs are referenced from card rows by `definition_key`, so a card whose
## effect row names a definition_key present here is driven as a reconciled
## Effect instance instead of a one-shot Modifier batch.

const DEFAULT_PATH := "res://data/ideologies/default_ideology_effects.tres"
const DefinitionScript = preload("res://scripts/ideology/ideology_effect_definition.gd")
const ParameterScript = preload("res://scripts/ideology/ideology_effect_parameter.gd")

@export var effects: Array[Resource] = []
## Program override layer (L3-9). Applied when a program is translated into its
## EffectDefinition, so an override is visible to the runtime as the program's
## own value -- not as a second source of truth the rest of the pipeline has to
## remember to consult.
@export var overrides: Array[Resource] = []


static func load_default() -> Resource:
	var loaded: Resource = ResourceLoader.load(DEFAULT_PATH, "Resource")
	if loaded != null:
		return loaded
	var script: Script = load("res://scripts/ideology/ideology_effect_catalog.gd") as Script
	return script.new() if script != null else null


## Program keys declared by this catalog, used by the ideology compiler to
## decide whether a card effect row is owned by the instance path.
func program_key_set() -> Dictionary:
	var out := {}
	for effect in effects:
		if effect == null or not effect is DefinitionScript:
			continue
		var key := String(effect.program_key()).strip_edges()
		if not key.is_empty():
			out[key] = true
	return out


func validate() -> String:
	var seen := {}
	for effect in effects:
		if effect == null or not effect is DefinitionScript:
			return "ideology_effect_catalog_resource_invalid"
		var error: String = effect.validate()
		if not error.is_empty():
			return error
		var key := String(effect.program_key())
		if seen.has(key):
			return "ideology_effect_catalog_duplicate_program"
		seen[key] = true
	# Overrides are validated against the program set, not on their own: an
	# override that targets a program nobody declared is a typo that would
	# otherwise be applied to nothing and never reported.
	var applied := {}
	for override in overrides:
		if override == null or not override is ParameterScript:
			return "ideology_effect_catalog_override_resource_invalid"
		var override_error: String = override.validate()
		if not override_error.is_empty():
			return override_error
		if not seen.has(DefinitionScript.definition_key_of(override.target_definition_key)):
			return "ideology_effect_catalog_override_target_unknown:%s" % String(
				override.target_definition_key)
		# Two overrides of the same field of the same program would make the
		# result depend on array order, which is the one thing authoring data must
		# never do.
		var slot := "%s.%s" % [String(override.target_definition_key),
			String(override.field_key())]
		if applied.has(slot):
			return "ideology_effect_catalog_override_duplicate:%s" % slot
		applied[slot] = true
	return ""


## Applies every override that targets `definition_key` to `definition`.
##
## Called right after `to_effect_definition()`, before the program enters the
## EffectCatalog. Returning the error instead of asserting keeps the caller's
## "one reject path" shape: `effect_domain_catalog.gd` turns any non-empty
## string into `effect_catalog_<reason>`.
func apply_overrides(definition: Resource, definition_key: StringName) -> String:
	if definition == null:
		return "ideology_effect_override_definition_missing"
	for override in overrides:
		if override == null or not override is ParameterScript:
			return "ideology_effect_catalog_override_resource_invalid"
		if override.target_definition_key != definition_key:
			continue
		# Re-check the row here rather than trusting `validate()` to have run.
		# `EffectDomainCatalog.build()` does not call `validate()` on this
		# resource, so without this a 999-stack override would land on the emitted
		# program and be rejected -- or worse, accepted -- by the native side with
		# a message that names no authoring rule.
		var row_error: String = override.validate()
		if not row_error.is_empty():
			return row_error
		match int(override.field):
			ParameterScript.Field.DURATION_DAYS:
				definition.duration_days = int(override.value)
			ParameterScript.Field.MAX_STACKS:
				definition.max_stacks = int(override.value)
			ParameterScript.Field.CADENCE_DAYS:
				definition.cadence_days = int(override.value)
			ParameterScript.Field.PRIORITY:
				definition.priority = int(override.value)
			ParameterScript.Field.MAGNITUDE_SCALE:
				# Runtime-only. Applying it here would bake one country's value
				# into the shared program template, which is exactly what §37
				# keeps out of this layer.
				return "ideology_effect_parameter_magnitude_scale_is_runtime_only"
			_:
				return "ideology_effect_parameter_field_invalid"
	return ""
