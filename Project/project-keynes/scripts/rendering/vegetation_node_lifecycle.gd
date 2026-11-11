extends RefCounted

## Owns release of both attached and temporarily detached source nodes.

static func release(layer) -> void:
	clear_chunks(layer, true)
	for node in [layer._mmi, layer._shadow_mmi]:
		if is_instance_valid(node) and node.get_parent() == null:
			node.free()


static func clear_chunks(layer, releasing: bool = false) -> void:
	for node in layer._chunk_nodes.values():
		if node != null and is_instance_valid(node):
			dispose(node, releasing)
	layer._chunk_nodes.clear()
	layer._chunk_cell_payloads.clear()
	layer._chunk_assembled_payloads.clear()
	layer._chunk_dormant_since_msec.clear()
	clear_wrap_nodes(layer._chunk_wrap_nodes, releasing)
	layer._chunk_instance_counts.clear()
	layer._chunk_far_instance_counts.clear()
	layer._active_instance_count_cache = 0
	layer._active_instance_count_valid = false
	layer.invalidate_viewport_budget_cache()
	for snode in layer._shadow_chunk_nodes.values():
		if snode != null and is_instance_valid(snode):
			dispose(snode, releasing)
	layer._shadow_chunk_nodes.clear()
	clear_wrap_nodes(layer._shadow_chunk_wrap_nodes, releasing)


static func clear_wrap_nodes(groups: Dictionary, releasing: bool = false) -> void:
	for nodes_value in groups.values():
		var nodes: Array = nodes_value
		for node_value in nodes:
			var node := node_value as MultiMeshInstance2D
			if node != null and is_instance_valid(node):
				dispose(node, releasing)
	groups.clear()


static func dispose(node: Node, releasing: bool) -> void:
	if releasing and node.get_parent() == null:
		node.free()
	else:
		node.queue_free()
