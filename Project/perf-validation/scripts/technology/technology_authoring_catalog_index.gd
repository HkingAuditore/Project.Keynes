class_name TechnologyAuthoringCatalogIndex
extends RefCounted

## Pick-list source for the technology authoring workbench.
##
## Authors previously typed Modifier stat keys, building IDs and good IDs into
## raw JSON text areas, so typos only surfaced when EconomyCatalog compilation
## failed at bootstrap. This index loads the real content catalogs once and
## offers only keys that actually exist.
##
## Compiling the Modifier catalog costs about two seconds because it pulls in
## the whole economy catalog, so both the profile scan and the resulting stat
## registry are cached under `user://`, keyed by a recursive content signature.

const BUILDING_DIR := "res://data/economy/buildings"
const GOOD_DIR := "res://data/goods"
const RESOURCE_DIR := "res://data/resources"
const DATA_ROOT := "res://data"
const CACHE_PATH := "user://technology_authoring_index.json"
const CACHE_VERSION := 2

## id -> {display_name, path, tag_field, tags, required_field, required_tags}
var buildings: Dictionary = {}
var goods: Dictionary = {}
var resources: Dictionary = {}
## stat key -> {domain, min, max}
var modifier_stats: Dictionary = {}
var modifier_stat_keys: PackedStringArray = PackedStringArray()
var stat_registry_reason := ""
## tech id -> [{kind, id, display_name, field, path}]
var unlocks_by_technology: Dictionary = {}
var load_msec := 0
var signature_msec := 0
var served_from_cache := false


func build(force_rescan := false) -> void:
	var started := Time.get_ticks_msec()
	var signature_started := Time.get_ticks_msec()
	var signature := _content_signature()
	signature_msec = Time.get_ticks_msec() - signature_started
	served_from_cache = not force_rescan and _load_cache(signature)
	if not served_from_cache:
		buildings = _scan_directory(BUILDING_DIR, "technology_tags", "required_technology_tags")
		goods = _scan_directory(GOOD_DIR, "technology_tags", "")
		resources = _scan_directory(RESOURCE_DIR, "discovery_technology_tags", "")
		_compile_modifier_stats()
		_store_cache(signature)
	refresh_unlock_map()
	load_msec = Time.get_ticks_msec() - started


func entries(kind: String) -> Dictionary:
	match kind:
		"building": return buildings
		"good": return goods
		"resource": return resources
	return {}


func display_name(kind: String, id: String) -> String:
	var row: Dictionary = entries(kind).get(id, {})
	return String(row.get("display_name", id))


func has_entry(kind: String, id: String) -> bool:
	return entries(kind).has(id)


## Sorted (id, display_name) pairs for a picker, optionally filtered.
func options(kind: String, query := "", limit := 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var needle := query.strip_edges().to_lower()
	var source := entries(kind)
	var keys := source.keys()
	keys.sort()
	for key in keys:
		var id := String(key)
		var row: Dictionary = source[key]
		var name := String(row.get("display_name", id))
		if not needle.is_empty() and not id.to_lower().contains(needle) \
				and not name.to_lower().contains(needle):
			continue
		out.append({"id": id, "display_name": name})
		if limit > 0 and out.size() >= limit:
			break
	return out


func stat_options(query := "", limit := 200) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var needle := query.strip_edges().to_lower()
	for key in modifier_stat_keys:
		var stat_key := String(key)
		if not needle.is_empty() and not stat_key.to_lower().contains(needle):
			continue
		var meta: Dictionary = modifier_stats.get(stat_key, {})
		out.append({
			"id": stat_key,
			"min": float(meta.get("min", 0.0)),
			"max": float(meta.get("max", 0.0)),
		})
		if limit > 0 and out.size() >= limit:
			break
	return out


## Content unlocked by one technology, as authored in the .tres files.
func unlocks_for(technology_id: String) -> Array:
	return (unlocks_by_technology.get(technology_id, []) as Array).duplicate()


# --------------------------------------------------------------------------
# Scanning
# --------------------------------------------------------------------------

func _scan_directory(directory: String, tag_field: String,
		required_field: String) -> Dictionary:
	var out := {}
	var dir := DirAccess.open(directory)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if not dir.current_is_dir() and entry.ends_with(".tres"):
			var path := directory.path_join(entry)
			var profile := ResourceLoader.load(path, "Resource")
			if profile != null:
				var id := String(profile.get("id"))
				if not id.is_empty():
					out[id] = {
						"display_name": String(profile.get("display_name")),
						"path": path,
						"tag_field": tag_field,
						"tags": _string_array(profile.get(tag_field)),
						"required_field": required_field,
						"required_tags": _string_array(profile.get(required_field)) \
							if not required_field.is_empty() else PackedStringArray(),
					}
		entry = dir.get_next()
	dir.list_dir_end()
	return out


static func _string_array(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value == null:
		return out
	for item in value:
		out.append(String(item))
	return out


func refresh_unlock_map() -> void:
	unlocks_by_technology.clear()
	for kind in ["building", "good", "resource"]:
		var source := entries(kind)
		for id in source:
			var row: Dictionary = source[id]
			for tag in row.get("tags", PackedStringArray()):
				_add_unlock(String(tag), kind, String(id), String(row.get("display_name", "")),
					String(row.get("tag_field", "")), String(row.get("path", "")))
			for tag in row.get("required_tags", PackedStringArray()):
				_add_unlock(String(tag), kind, String(id), String(row.get("display_name", "")),
					String(row.get("required_field", "")), String(row.get("path", "")))


func _add_unlock(tag: String, kind: String, id: String, name: String,
		field: String, path: String) -> void:
	if not tag.begins_with("tech."):
		return
	var bucket: Array = unlocks_by_technology.get(tag, [])
	bucket.append({
		"kind": kind,
		"id": id,
		"display_name": name,
		"field": field,
		"path": path,
	})
	unlocks_by_technology[tag] = bucket


func _compile_modifier_stats() -> void:
	modifier_stats.clear()
	modifier_stat_keys = PackedStringArray()
	stat_registry_reason = ""
	var catalog := ModifierCatalog.load_default()
	if catalog == null:
		stat_registry_reason = "modifier_catalog_missing"
		return
	var compiled: Dictionary = catalog.call("compile_native_catalog")
	if not bool(compiled.get("ok", false)):
		stat_registry_reason = String(compiled.get("reason", "modifier_catalog_compile_failed"))
		return
	var keys: Array = compiled.get("stat_keys", [])
	var minimums: Array = compiled.get("stat_min_values", [])
	var maximums: Array = compiled.get("stat_max_values", [])
	var domains: Array = compiled.get("stat_domains", [])
	for index in range(keys.size()):
		var key := String(keys[index])
		modifier_stats[key] = {
			"domain": int(domains[index]) if index < domains.size() else 0,
			"min": float(minimums[index]) if index < minimums.size() else 0.0,
			"max": float(maximums[index]) if index < maximums.size() else 0.0,
		}
		modifier_stat_keys.append(key)
	modifier_stat_keys.sort()


# --------------------------------------------------------------------------
# Cache
# --------------------------------------------------------------------------

## One recursive pass over res://data. The Modifier stat set is derived from
## goods, buildings, professions, resources, terrain and climate content, so a
## narrower signature would silently serve a stale stat registry.
func _content_signature() -> String:
	var totals := _signature_totals(DATA_ROOT)
	return "v%d|%d|%d" % [CACHE_VERSION, int(totals.count), int(totals.newest)]


func _signature_totals(directory: String) -> Dictionary:
	var count := 0
	var newest := 0
	var dir := DirAccess.open(directory)
	if dir == null:
		return {"count": 0, "newest": 0}
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		var path := directory.path_join(entry)
		if dir.current_is_dir():
			var nested := _signature_totals(path)
			count += int(nested.count)
			newest = maxi(newest, int(nested.newest))
		elif entry.ends_with(".tres") or entry.ends_with(".json") or entry.ends_with(".res"):
			count += 1
			newest = maxi(newest, int(FileAccess.get_modified_time(path)))
		entry = dir.get_next()
	dir.list_dir_end()
	return {"count": count, "newest": newest}


func _load_cache(signature: String) -> bool:
	if not FileAccess.file_exists(CACHE_PATH):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATH))
	if not parsed is Dictionary:
		return false
	var cache: Dictionary = parsed
	if String(cache.get("signature", "")) != signature:
		return false
	buildings = _restore_section(cache.get("buildings", {}))
	goods = _restore_section(cache.get("goods", {}))
	resources = _restore_section(cache.get("resources", {}))
	modifier_stats.clear()
	modifier_stat_keys = PackedStringArray()
	stat_registry_reason = String(cache.get("stat_registry_reason", ""))
	var stats: Variant = cache.get("modifier_stats", {})
	if stats is Dictionary:
		for key in stats as Dictionary:
			var row: Dictionary = (stats as Dictionary)[key]
			modifier_stats[String(key)] = {
				"domain": int(row.get("domain", 0)),
				"min": float(row.get("min", 0.0)),
				"max": float(row.get("max", 0.0)),
			}
			modifier_stat_keys.append(String(key))
	modifier_stat_keys.sort()
	return not buildings.is_empty()


func _restore_section(value: Variant) -> Dictionary:
	var out := {}
	if not value is Dictionary:
		return out
	for id in value as Dictionary:
		var row: Dictionary = (value as Dictionary)[id]
		out[String(id)] = {
			"display_name": String(row.get("display_name", "")),
			"path": String(row.get("path", "")),
			"tag_field": String(row.get("tag_field", "")),
			"tags": _string_array(row.get("tags", [])),
			"required_field": String(row.get("required_field", "")),
			"required_tags": _string_array(row.get("required_tags", [])),
		}
	return out


func _store_cache(signature: String) -> void:
	var file := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if file == null:
		return
	var stats := {}
	for key in modifier_stats:
		var row: Dictionary = modifier_stats[key]
		stats[String(key)] = {
			"domain": int(row.get("domain", 0)),
			"min": float(row.get("min", 0.0)),
			"max": float(row.get("max", 0.0)),
		}
	file.store_string(JSON.stringify({
		"signature": signature,
		"buildings": _serialize_section(buildings),
		"goods": _serialize_section(goods),
		"resources": _serialize_section(resources),
		"modifier_stats": stats,
		"stat_registry_reason": stat_registry_reason,
	}))
	file.close()


func _serialize_section(section: Dictionary) -> Dictionary:
	var out := {}
	for id in section:
		var row: Dictionary = section[id]
		out[String(id)] = {
			"display_name": String(row.get("display_name", "")),
			"path": String(row.get("path", "")),
			"tag_field": String(row.get("tag_field", "")),
			"tags": Array(row.get("tags", PackedStringArray())),
			"required_field": String(row.get("required_field", "")),
			"required_tags": Array(row.get("required_tags", PackedStringArray())),
		}
	return out
