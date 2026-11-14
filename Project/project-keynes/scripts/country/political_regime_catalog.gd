class_name PoliticalRegimeCatalog
extends Resource

const DEFAULT_PATH := "res://data/country/default_political_regime_catalog.tres"
const PoliticalRegimeDefinitionScript = preload(
	"res://scripts/country/political_regime_definition.gd")

const CAP_TREASURY_CONSTRUCTION := 1 << 0
const CAPABILITY_BITS := {
	"treasury_construction": CAP_TREASURY_CONSTRUCTION,
}

@export var catalog_version: int = 1
@export var definitions: Array[Resource] = []

static func load_default() -> PoliticalRegimeCatalog:
	return ResourceLoader.load(DEFAULT_PATH, "Resource") as PoliticalRegimeCatalog

func validate() -> String:
	if catalog_version <= 0 or definitions.is_empty():
		return "political_regime_catalog_empty"
	var seen := {}
	for raw_definition in definitions:
		if raw_definition == null or not raw_definition is PoliticalRegimeDefinitionScript:
			return "political_regime_definition_invalid"
		var definition: PoliticalRegimeDefinition = raw_definition
		var error := definition.validate()
		if not error.is_empty():
			return error
		var id := String(definition.id)
		if seen.has(id):
			return "political_regime_id_duplicate"
		seen[id] = true
		for raw_key in definition.capability_keys:
			if not CAPABILITY_BITS.has(String(raw_key)):
				return "political_regime_capability_unknown"
	return ""

func compile_native_catalog(_country_catalog: Dictionary = {},
		_modifier_catalog: Dictionary = {}) -> Dictionary:
	var error := validate()
	if not error.is_empty():
		return {"ok": false, "reason": error}
	var ordered: Array[Resource] = definitions.duplicate()
	ordered.sort_custom(func(a: Resource, b: Resource) -> bool:
		return String((a as PoliticalRegimeDefinition).id) < \
			String((b as PoliticalRegimeDefinition).id))
	var ids := PackedStringArray()
	var bits := PackedInt32Array()
	var catalog_hash: int = 1469598103934665603
	for raw_definition in ordered:
		var definition: PoliticalRegimeDefinition = raw_definition
		var id := String(definition.id)
		ids.append(id)
		var capability_bits := 0
		var keys := PackedStringArray(definition.capability_keys)
		keys.sort()
		for raw_key in keys:
			var key := String(raw_key)
			capability_bits |= int(CAPABILITY_BITS[key])
			catalog_hash = _fnv_append(catalog_hash, key)
		catalog_hash = _fnv_append(catalog_hash, "|")
		bits.append(capability_bits)
		catalog_hash = _fnv_append(catalog_hash, id)
		catalog_hash = _fnv_append(catalog_hash, ":%d;" % capability_bits)
	return {
		"ok": true,
		"political_regime_ids": ids,
		"political_regime_capability_bits": bits,
		"political_regime_catalog_hash": catalog_hash,
		"political_regime_default_id": "early_clan" if ids.has("early_clan") \
			else String(ids[0]),
	}

func catalog_view() -> Dictionary:
	var error := validate()
	if not error.is_empty():
		return {"ok": false, "reason": error}
	var rows: Array[Dictionary] = []
	for raw_definition in definitions:
		rows.append((raw_definition as PoliticalRegimeDefinition).presentation())
	return {
		"ok": true,
		"catalog_version": catalog_version,
		"definitions": rows,
		"capability_bits": CAPABILITY_BITS.duplicate(),
	}

func definition_for(regime_id: StringName) -> PoliticalRegimeDefinition:
	for raw_definition in definitions:
		var definition: PoliticalRegimeDefinition = raw_definition
		if definition != null and definition.id == regime_id:
			return definition
	return null

static func _fnv_append(value: int, text: String) -> int:
	var result := value
	for byte_value in text.to_utf8_buffer():
		result = int((result ^ int(byte_value)) * 1099511628211) & 0x7fffffffffffffff
	return result
