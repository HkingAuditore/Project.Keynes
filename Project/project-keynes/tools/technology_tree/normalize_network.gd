extends SceneTree

## 归一化入口：重建 effect_summary 与 visual_edges，再用运行时自己的序列化器写盘。
## 用法：
##   godot --headless --path <project> --script res://tools/technology_tree/normalize_network.gd
##   （追加 -- --check 只检查是否需要归一化，不写盘）

const NETWORK_PATH := "res://data/technology/technology_network.json"
const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")


func _init() -> void:
	var check_only := false
	for argument in OS.get_cmdline_user_args():
		if argument == "--check":
			check_only = true
	var text := FileAccess.get_file_as_string(NETWORK_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		printerr("network is not a JSON object")
		quit(2)
		return
	var payload: Dictionary = parsed
	var summaries_changed: bool = ValidatorScript.normalize_effect_summaries(payload)
	var edges: Array = ValidatorScript.build_visual_edges(payload)
	var edges_changed := int(edges.size()) != int((payload.get("visual_edges", []) as Array).size())
	payload["visual_edges"] = edges
	print("normalize summaries_changed=%s edges=%d edges_size_changed=%s" % [
		str(summaries_changed), edges.size(), str(edges_changed)])
	if check_only:
		quit(0 if not summaries_changed and not edges_changed else 1)
		return
	var serialized: String = ValidatorScript.serialize_network(payload)
	var handle := FileAccess.open(NETWORK_PATH, FileAccess.WRITE)
	if handle == null:
		printerr("cannot open network for write")
		quit(2)
		return
	handle.store_string(serialized)
	handle.close()
	print("written %d bytes" % serialized.length())
	quit(0)
