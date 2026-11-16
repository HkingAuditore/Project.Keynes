extends SceneTree

## Probe: the satisfaction-source definitions must compile with ADD terms whose
## stat ids resolve. Prints one line per definition so a failure names itself.

const KEYS := [
	"narrative.relief.agrarian_satisfaction",
	"narrative.levy.labor_satisfaction",
	"regime.early_clan.cohesion",
	"regime.local_council.cohesion",
	"family.country.patronage_satisfaction",
]

func _init() -> void:
	var catalog: Resource = load("res://data/modifiers/default_modifier_catalog.tres")
	if catalog == null:
		print("PROBE FAIL: catalog does not load")
		quit(1)
		return
	print("definitions=", (catalog.definitions as Array).size())
	var compiled: Dictionary = catalog.compile_native_catalog()
	print("compile ok=", compiled.get("ok", false), " reason=", str(compiled.get("reason", "")))
	if not bool(compiled.get("ok", false)):
		quit(1)
		return
	var definition_keys: PackedStringArray = compiled.get("definition_keys", PackedStringArray())
	var offsets: PackedInt32Array = compiled.get("definition_term_offsets", PackedInt32Array())
	var stat_ids: PackedInt32Array = compiled.get("term_stat_ids", PackedInt32Array())
	var operations: PackedInt32Array = compiled.get("term_operations", PackedInt32Array())
	var stat_keys: PackedStringArray = compiled.get("stat_keys", PackedStringArray())
	var bad := 0
	for key in KEYS:
		var index := definition_keys.find(key)
		if index < 0:
			print("PROBE FAIL: missing definition ", key)
			bad += 1
			continue
		var rows: Array[String] = []
		for term in range(offsets[index], offsets[index + 1]):
			var sid := int(stat_ids[term])
			var stat_key := String(stat_keys[sid]) if sid >= 0 and sid < stat_keys.size() else "<bad id %d>" % sid
			if int(operations[term]) != 0:
				print("PROBE FAIL: %s term %d is not ADD (%d)" % [key, term, operations[term]])
				bad += 1
			rows.append("%s[op=%d]" % [stat_key, int(operations[term])])
		print("%s terms=%d %s" % [key, rows.size(), ", ".join(rows)])
	print("PROBE ", "PASS" if bad == 0 else "FAIL")
	quit(0 if bad == 0 else 1)
