class_name NarrativeEventPack
extends RefCounted

## 内容包元数据的 schema 与自检。
##
## 每个 `narrative_event_catalog_<pack>.gd` 都必须提供 `meta()`，返回这里的字段。
## 注册表按 `id` 排序调用各包的 `append()`；测试按 `node_ids` 校验"声明的"与"实际注册的"一致，
## 所以漏加事件、写错前缀、改了 id 忘改 meta 都会当场失败。

const REQUIRED_KEYS := [
	"id", "title", "theme", "era_band", "prefix", "scale", "cast", "node_ids",
]


static func validate(meta: Dictionary) -> Dictionary:
	for key in REQUIRED_KEYS:
		if not meta.has(key):
			return {"ok": false, "reason": "pack_meta_missing_%s" % key}
	var prefix := String(meta["prefix"])
	if prefix.is_empty():
		return {"ok": false, "reason": "pack_meta_empty_prefix"}
	var nodes: Array = meta["node_ids"]
	if nodes.is_empty():
		return {"ok": false, "reason": "pack_meta_empty_nodes"}
	for raw in nodes:
		var node := String(raw)
		if not node.begins_with(prefix):
			return {"ok": false, "reason": "pack_node_outside_prefix:%s" % node}
	var cast: Array = meta["cast"]
	if cast.size() < 4:
		return {"ok": false, "reason": "pack_cast_too_thin:%d" % cast.size()}
	return {"ok": true, "reason": ""}


static func node_ids(meta: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for raw in meta.get("node_ids", []):
		out.append(String(raw))
	return out
