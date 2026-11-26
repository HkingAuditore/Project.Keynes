extends RefCounted

## Loads catalog resources and computes stable column identities.


static func _load_resources_impl(dir_path: String, context) -> Array:
	# [pk-export-remap] DirAccess.get_files_at() 在导出/打包工程里看到的是 pck
	# 目录项原名（会带 .remap 后缀，如 x.tres.remap），后缀过滤永远命不中，导
	# 致整个目录被判定为空——这不是 web 专属坑，任何导出包（含桌面 exe）都会
	# 中招，只是这之前只跑过编辑器内松散工程没触发。ResourceLoader.list_directory()
	# 在两种场景下都返回逻辑名（x.tres），是 Godot 4.3+ 专门为此提供的 API。
	var paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(dir_path):
		if context != null:
			await context.checkpoint("catalog_resources")
			if context.canceled:
				return []
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [dir_path, file_name])
	paths.sort()
	var out := []
	for path in paths:
		if context != null:
			await context.checkpoint("catalog_resources")
			if context.canceled:
				return []
		var resource = ResourceLoader.load(path, "Resource")
		if resource != null and String(resource.get("id")) != "":
			out.append(resource)
	out.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))
	return out

static func _index_ids(ids: PackedStringArray) -> Dictionary:
	var out := {}
	for i in range(ids.size()):
		if String(ids[i]) == "" or out.has(String(ids[i])):
			return {}
		out[String(ids[i])] = i
	return out

static func _optional_index(index: Dictionary, id_value: String) -> int:
	if id_value == "":
		return -1
	return int(index.get(id_value, -2))

static func _catalog_hash_impl(catalog: Dictionary, context) -> int:
	var keys := catalog.keys()
	keys.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	var canonical := "economy-catalog-v2\n"
	for key in keys:
		if context != null:
			await context.checkpoint("catalog_hash")
			if context.canceled:
				return 0
		canonical += "%s=%s\n" % [String(key), var_to_str(catalog[key])]
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(canonical.to_utf8_buffer())
	var digest := hashing.finish()
	var value: int = 0
	for i in range(7):
		if context != null:
			await context.checkpoint("catalog_hash")
			if context.canceled:
				return 0
		value = (value << 8) | int(digest[i])
	return maxi(1, value)
