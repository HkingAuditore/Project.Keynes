extends RefCounted

## Pure composition-time validation. No simulation state, scene ownership,
## threads or callbacks are executed while resolving module dependencies.
static func resolve(entries: Array) -> Dictionary:
	var by_id := {}
	var owned := {}
	for entry in entries:
		if not entry is Dictionary:
			return _error("module_descriptor_invalid", "")
		if typeof(entry.get("id")) not in [TYPE_STRING, TYPE_STRING_NAME] \
				or not entry.get("module") is Object or not is_instance_valid(entry.module):
			return _error("module_descriptor_invalid", "id/module")
		var id := String(entry.get("id", ""))
		if id.is_empty() or entry.get("module") == null:
			return _error("module_descriptor_invalid", id)
		if by_id.has(id):
			return _error("module_id_duplicate", id)
		for field in ["after", "owns"]:
			if not (entry.get(field, []) is Array or entry.get(field, []) is PackedStringArray):
				return _error("module_descriptor_invalid", "%s.%s" % [id, field])
			for name in entry.get(field, []):
				if typeof(name) not in [TYPE_STRING, TYPE_STRING_NAME] or String(name).is_empty():
					return _error("module_descriptor_invalid", "%s.%s" % [id, field])
		by_id[id] = entry
		for key in entry.get("owns", []):
			var name := String(key)
			if name.is_empty() or owned.has(name):
				return _error("module_owner_duplicate", name)
			owned[name] = id
	for id in by_id:
		for dependency in by_id[id].get("after", []):
			if not by_id.has(String(dependency)):
				return _error("module_dependency_missing", "%s -> %s" % [id, dependency])
	var ids := PackedStringArray()
	var modules: Array = []
	var installed := {}
	# Stable topological order preserves the composition's order for unrelated
	# modules. Resolve one node at a time so newly satisfied nodes keep that tie.
	while installed.size() < entries.size():
		var next: Dictionary = {}
		for entry in entries:
			var id := String(entry.id)
			if installed.has(id):
				continue
			var ready := true
			for dependency in entry.get("after", []):
				if not installed.has(String(dependency)):
					ready = false
					break
			if ready:
				next = entry
				break
		if next.is_empty():
			var blocked := PackedStringArray()
			for id in by_id:
				if not installed.has(id):
					blocked.append(id)
			return _error("module_dependency_cycle", ", ".join(blocked))
		installed[String(next.id)] = true
		ids.append(String(next.id))
		modules.append(next.module)
	return {"ok": true, "code": "ok", "ids": ids, "modules": modules}


static func state_entry(provider, after: PackedStringArray = PackedStringArray()) -> Dictionary:
	if provider == null or not provider.has_method("provider_id") \
			or not provider.has_method("section_ids") \
			or not provider.has_method("registration_valid") \
			or not provider.registration_valid():
		return {}
	return {"id": String(provider.provider_id()), "module": provider,
		"after": after.duplicate(), "owns": provider.section_ids()}


static func _error(code: String, detail: String) -> Dictionary:
	return {"ok": false, "code": code, "detail": detail,
		"message": "游戏系统配置不完整，暂时无法继续。"}
