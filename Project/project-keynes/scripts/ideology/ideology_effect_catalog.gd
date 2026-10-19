class_name IdeologyEffectCatalog
extends Resource

## Authored ideology effect programs, compiled into the shared EffectCatalog.
## Programs are referenced from card rows by `definition_key`, so a card whose
## effect row names a definition_key present here is driven as a reconciled
## Effect instance instead of a one-shot Modifier batch.

const DEFAULT_PATH := "res://data/ideologies/default_ideology_effects.tres"
const DefinitionScript = preload("res://scripts/ideology/ideology_effect_definition.gd")

@export var effects: Array[Resource] = []


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
	return ""
