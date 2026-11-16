extends SceneTree

## Lists the stat keys the material-support compiler cannot map to a channel.
##
## `IdeologyIncidenceCompiler.debug_unmapped_keys` is a probe-only sink; production
## leaves it null. The output is grouped by stat family so the next mapping work can
## target the families that actually carry material incidence.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const IdeologyIncidenceCompilerScript = preload(
	"res://scripts/ideology/ideology_incidence_compiler.gd")


func _init() -> void:
	IdeologyIncidenceCompilerScript.debug_unmapped_keys = []
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var catalog: Resource = IdeologyCatalogScript.load_default()
	if catalog == null:
		printerr("catalog missing")
		quit(1)
		return
	var compiled: Dictionary = catalog.compile_native_catalog(economy, economy)
	print("[unmapped] ok=%s channels=%s rows=%s unmapped=%s" % [
		str(compiled.get("ok", false)), str(compiled.get("incidence_channel_count", "?")),
		str(compiled.get("incidence_levels", "?")),
		str(compiled.get("incidence_unmapped_stat_count", "?"))])
	var keys: Array = IdeologyIncidenceCompilerScript.debug_unmapped_keys
	IdeologyIncidenceCompilerScript.debug_unmapped_keys = null
	print("[unmapped] captured keys=%d (unique=%d)" % [keys.size(),
		_unique(keys).size()])
	var families := {}
	for key in keys:
		var family := _family(String(key))
		families[family] = int(families.get(family, 0)) + 1
	var ranked := families.keys()
	ranked.sort_custom(func(a, b): return int(families[a]) > int(families[b]))
	for family in ranked:
		print("  %-46s %d" % [family, int(families[family])])
	print("[unmapped] sample keys:")
	for key in _unique(keys).slice(0, 40):
		print("  ", key)
	quit(0)


func _unique(values: Array) -> Array:
	var seen := {}
	var out := []
	for value in values:
		if seen.has(value):
			continue
		seen[value] = true
		out.append(value)
	return out


## Collapse a stat key to its family: keep the first three dotted segments, which is
## where `country.output.*`, `economy.profession.*`, `modifier.*` differ.
func _family(key: String) -> String:
	var parts := key.split(".")
	if parts.size() <= 3:
		return key
	return ".".join(parts.slice(0, 3)) + ".*"
