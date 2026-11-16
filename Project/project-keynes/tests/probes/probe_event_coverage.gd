extends SceneTree

## 临时覆盖审计：打印每个内容包在 11 个时代上的事件数，以及 tag 频次。
## 只读，不改任何东西；跑完即可删除。

const CatalogScript = preload("res://scripts/narrative/narrative_event_catalog.gd")
const RegistryScript = preload("res://scripts/narrative/narrative_event_registry.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog = CatalogScript.build_default_catalog()
	var metas: Array = RegistryScript.packs()
	var header := "pack,total"
	for e in range(11):
		header += ",e%d" % e
	print(header)
	var tag_counts: Dictionary = {}
	var grand := 0
	for meta in metas:
		var prefix := String(meta.get("prefix", ""))
		var counts := PackedInt32Array()
		counts.resize(11)
		var total := 0
		for def in catalog.all_events():
			if not String(def.event_id).begins_with(prefix):
				continue
			total += 1
			grand += 1
			for e in range(int(def.min_era_index), int(def.max_era_index) + 1):
				counts[e] += 1
			for tag in def.tags:
				var key := String(tag)
				tag_counts[key] = int(tag_counts.get(key, 0)) + 1
		var line := "%s,%d" % [String(meta.get("id", "?")), total]
		for e in range(11):
			line += ",%d" % counts[e]
		print(line)
	print("registry_total,%d" % grand)
	var legacy := 0
	for def in catalog.all_events():
		var eid := String(def.event_id)
		if eid.begins_with("evt.waterworks.") or eid.begins_with("evt.people."):
			legacy += 1
	print("legacy_packs,%d" % legacy)
	print("catalog_total,%d" % catalog.all_events().size())
	var tag_keys := tag_counts.keys()
	tag_keys.sort()
	var tag_line := "tags:"
	for k in tag_keys:
		tag_line += " %s=%d" % [String(k), int(tag_counts[k])]
	print(tag_line)
	quit(0)
