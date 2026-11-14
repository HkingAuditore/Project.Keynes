extends SceneTree

## Writes the script-visible DCWorldExt method list as sorted JSON.
##
## godot --headless --path Project/project-keynes \
##     --script res://tests/runtime/dump_world_ext_bindings.gd -- out=<absolute path>
##
## Each entry has the method name, argument names and types, the number of
## default arguments and the return type. Two dumps are equal exactly when the
## script-facing binding surface is unchanged, so this is the equivalence check
## for moving or splitting bindings (docs/plans/world-ext-binding-split.md).

const CLASS_NAME := "DCWorldExt"


func _init() -> void:
	var out_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("out="):
			out_path = arg.substr(4)
	if not ClassDB.class_exists(CLASS_NAME):
		push_error("%s is not registered; is the extension loaded?" % CLASS_NAME)
		quit(2)
		return
	var methods: Array = []
	for info in ClassDB.class_get_method_list(CLASS_NAME, true):
		var args: Array = []
		for arg in info.get("args", []):
			args.append({"name": String(arg.name), "type": int(arg.type), "class_name": String(arg.class_name)})
		var ret: Dictionary = info.get("return", {})
		methods.append({
			"name": String(info.name),
			"args": args,
			"default_count": (info.get("default_args", []) as Array).size(),
			"flags": int(info.get("flags", 0)),
			"return_type": int(ret.get("type", 0)),
			"return_class": String(ret.get("class_name", "")),
		})
	methods.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.name < b.name)
	var text := JSON.stringify({"class": CLASS_NAME, "count": methods.size(), "methods": methods}, " ", false)
	if out_path.is_empty():
		print(text)
	else:
		var file := FileAccess.open(out_path, FileAccess.WRITE)
		if file == null:
			push_error("cannot write %s" % out_path)
			quit(3)
			return
		file.store_string(text + "\n")
		file.close()
	print("[dump_world_ext_bindings] %d methods" % methods.size())
	quit(0)
