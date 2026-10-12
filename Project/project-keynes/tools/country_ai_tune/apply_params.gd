extends SceneTree

## Writes a CountryAiCatalog candidate for offline tuning.
##
##   godot --headless --path Project/project-keynes \
##       --script res://tools/country_ai_tune/apply_params.gd -- \
##       base=res://data/country/default_country_ai.tres \
##       params=D:/.../candidate.json out=D:/.../candidate.tres
##
## `params` is a JSON object of {path: value}. Path tokens are separated by
## "." ; the first token is a catalog property, an id token selects the
## dictionary with that "id" inside agendas/personalities, and an integer token
## indexes an array. Examples:
##   tax_step_bp
##   agendas.expand.research_share_bp
##   agendas.develop.considerations.0.x1
##   personalities.builder.agenda_bias.0
## Existing int values stay int (rounded); everything else is written as float.
## The candidate is validated with compile_native_catalog() before saving.
##
## Read mode (`read=spec.json out=values.json`) takes a JSON array of paths, or
## an object with a "params" array of {path}, and writes their current values.

const CountryAiCatalogScript = preload("res://scripts/country/country_ai_catalog.gd")


func _init() -> void:
	var args := {}
	for raw in OS.get_cmdline_user_args():
		var text := String(raw)
		var eq := text.find("=")
		if eq > 0:
			args[text.substr(0, eq)] = text.substr(eq + 1)
	var result := _read(args) if args.has("read") else _run(args)
	print("[country-ai-tune/apply] %s" % JSON.stringify(result))
	quit(0 if bool(result.get("ok", false)) else 2)


func _run(args: Dictionary) -> Dictionary:
	var base_path := String(args.get("base", CountryAiCatalogScript.DEFAULT_PATH))
	var params_path := String(args.get("params", ""))
	var out_path := String(args.get("out", ""))
	if params_path.is_empty() or out_path.is_empty():
		return {"ok": false, "reason": "usage_base_params_out"}
	var catalog := ResourceLoader.load(
		base_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Resource
	if catalog == null or catalog.get_script() != CountryAiCatalogScript:
		return {"ok": false, "reason": "base_load_failed", "base": base_path}
	var text := FileAccess.get_file_as_string(params_path)
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "reason": "params_not_object", "params": params_path}
	var applied := 0
	for key in parsed:
		var error := _apply(catalog, String(key), parsed[key])
		if not error.is_empty():
			return {"ok": false, "reason": error, "path": String(key)}
		applied += 1
	var compiled: Dictionary = catalog.compile_native_catalog(0)
	if not bool(compiled.get("ok", false)):
		return {"ok": false, "reason": "compile_failed", "detail": compiled}
	var save_error := ResourceSaver.save(catalog, out_path)
	if save_error != OK:
		return {"ok": false, "reason": "save_failed", "code": save_error, "out": out_path}
	return {"ok": true, "applied": applied, "out": out_path}


func _read(args: Dictionary) -> Dictionary:
	var base_path := String(args.get("base", CountryAiCatalogScript.DEFAULT_PATH))
	var out_path := String(args.get("out", ""))
	if out_path.is_empty():
		return {"ok": false, "reason": "usage_read_out"}
	var catalog := ResourceLoader.load(
		base_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Resource
	if catalog == null or catalog.get_script() != CountryAiCatalogScript:
		return {"ok": false, "reason": "base_load_failed", "base": base_path}
	var spec = JSON.parse_string(FileAccess.get_file_as_string(String(args["read"])))
	var paths: Array = []
	if spec is Array:
		paths = spec
	elif spec is Dictionary:
		for entry in spec.get("params", []):
			paths.append(entry.get("path", "") if entry is Dictionary else entry)
	var values := {}
	for raw_path in paths:
		var path := String(raw_path)
		var tokens := path.split(".", false)
		if tokens.is_empty() or not (tokens[0] in catalog):
			return {"ok": false, "reason": "unknown_property", "path": path}
		var node = catalog.get(tokens[0])
		for i in range(1, tokens.size()):
			node = _child(node, tokens[i])
			if node == null:
				return {"ok": false, "reason": "missing_path", "path": path}
		values[path] = node
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "reason": "out_open_failed", "out": out_path}
	file.store_string(JSON.stringify(values, "  "))
	file.close()
	return {"ok": true, "read": values.size(), "out": out_path}


func _child(container, token: String):
	if container is Array:
		if token.is_valid_int():
			var index := token.to_int()
			return container[index] if index >= 0 and index < container.size() else null
		for item in container:
			if item is Dictionary and String(item.get("id", "")) == token:
				return item
		return null
	if container is Dictionary:
		return container.get(token, null)
	return null


func _apply(catalog: Resource, path: String, value) -> String:
	var tokens := path.split(".", false)
	if tokens.is_empty():
		return "empty_path"
	var property := tokens[0]
	if not (property in catalog):
		return "unknown_property"
	if tokens.size() == 1:
		var current = catalog.get(property)
		if current is Array or current is Dictionary:
			return "container_needs_subpath"
		catalog.set(property, _coerce(current, value))
		return ""
	var root = catalog.get(property)
	if not (root is Array):
		return "subpath_on_scalar"
	var copy: Array = root.duplicate(true)
	var error := _set_nested(copy, tokens, 1, value)
	if not error.is_empty():
		return error
	catalog.set(property, copy)
	return ""


func _set_nested(container, tokens: PackedStringArray, at: int, value) -> String:
	var token := tokens[at]
	var last := at == tokens.size() - 1
	if container is Array:
		var index := -1
		if token.is_valid_int():
			index = token.to_int()
		else:
			for i in range(container.size()):
				if container[i] is Dictionary and String(container[i].get("id", "")) == token:
					index = i
					break
		if index < 0 or index >= container.size():
			return "missing_element:%s" % token
		if last:
			container[index] = _coerce(container[index], value)
			return ""
		return _set_nested(container[index], tokens, at + 1, value)
	if container is Dictionary:
		if not container.has(token):
			return "missing_key:%s" % token
		if last:
			container[token] = _coerce(container[token], value)
			return ""
		return _set_nested(container[token], tokens, at + 1, value)
	return "not_container:%s" % token


func _coerce(current, value):
	if current is int:
		return roundi(float(value))
	if current is bool:
		return bool(value)
	return float(value)
