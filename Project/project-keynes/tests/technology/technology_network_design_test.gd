extends SceneTree

## 设计契约测试（v5 重写版）。
##
## 旧版把"候选池大小、识别信号映射、每代节点数"等具体数值写死在断言里，
## 树一改就整片失效（196 条过期断言）。新版只断言**设计不变量**，
## 具体数值一律从权威目录推导，因此内容增删不再需要改测试。

const NETWORK_PATH := "res://data/technology/technology_network.json"
const VALIDATOR_SCRIPT := preload("res://scripts/technology/technology_network_validator.gd")

const EXPECTED_ERAS := 11
const EXPECTED_DOMAINS := 4
const ROOT_ID := "tech.early_knowledge_institution"
const ROOT_NAME := "思考"
const DUPLICATE_TARGET_BUDGET := 15
const MIN_COST_TIERS := 3

var failures: int = 0


func _fail(message: String) -> void:
	failures += 1
	printerr("DESIGN FAIL: %s" % message)


## GDScript 的 `or` 返回 bool（不像 Python 那样返回操作数），
## 所以 `float(value or 0.0)` 会悄悄变成 0.0 / 1.0，必须显式判空。
func _as_float(value: Variant) -> float:
	if value == null:
		return 0.0
	return float(value)


func _load_network() -> Dictionary:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _children(condition: Variant) -> Array:
	if not condition is Dictionary:
		return []
	return (condition as Dictionary).get("children", [])


func _collect_tech_atoms(condition: Variant, out: Array) -> void:
	for child in _children(condition):
		if not child is Dictionary:
			continue
		var entry: Dictionary = child
		var identifier := String(entry.get("id", ""))
		if float(entry.get("kind", 0.0)) == 0.0 and identifier.begins_with("tech."):
			out.append(identifier)
		_collect_tech_atoms(entry.get("children", []), out)


func _init() -> void:
	var data: Dictionary = _load_network()
	if data.is_empty():
		_fail("network json unreadable")
		_done()
		return

	var nodes: Array = data.get("nodes", [])
	var eras: Array = data.get("eras", [])
	var domains: Array = data.get("domains", [])

	# ---- 1. 骨架规模 ----
	if eras.size() != EXPECTED_ERAS:
		_fail("era count %d != %d" % [eras.size(), EXPECTED_ERAS])
	if domains.size() != EXPECTED_DOMAINS:
		_fail("domain count %d != %d" % [domains.size(), EXPECTED_DOMAINS])

	var era_index := {}
	var era_rows := {}
	for index in range(eras.size()):
		var era: Dictionary = eras[index]
		var era_id := String(era.get("id", ""))
		era_index[era_id] = index
		era_rows[era_id] = era

	# ---- 2. 节点表 ----
	var by_id := {}
	var row_of := {}
	var order_of := {}
	for index in range(nodes.size()):
		var node: Dictionary = nodes[index]
		var node_id := String(node.get("id", ""))
		if not node_id.begins_with("tech.") or node_id.begins_with("tech.application."):
			_fail("invalid technology id %s" % node_id)
		if by_id.has(node_id):
			_fail("duplicate technology id %s" % node_id)
		by_id[node_id] = node
		row_of[node_id] = index
		order_of[node_id] = _as_float(node.get("layout_order"))
		if not era_index.has(String(node.get("era_id", ""))):
			_fail("%s has unknown era %s" % [node_id, node.get("era_id")])
		if String(node.get("display_name", "")).strip_edges().is_empty():
			_fail("%s has empty display_name" % node_id)

	# ---- 3. 前置关系：必须存在、必须排在本节点之前、理由条数对齐 ----
	for index in range(nodes.size()):
		var node: Dictionary = nodes[index]
		var node_id := String(node.get("id", ""))
		var prerequisites: Array = node.get("hard_prerequisite_ids", [])
		var rationales: Array = node.get("prerequisite_rationales", [])
		if prerequisites.size() != rationales.size():
			_fail("%s prerequisite reasons %d != prerequisites %d"
				% [node_id, rationales.size(), prerequisites.size()])
		for prerequisite in prerequisites:
			var prerequisite_id := String(prerequisite)
			if not by_id.has(prerequisite_id):
				_fail("%s requires unknown %s" % [node_id, prerequisite_id])
				continue
			if int(row_of[prerequisite_id]) >= index:
				_fail("%s requires later-defined %s" % [node_id, prerequisite_id])

	# ---- 4. 唯一源头 + 全树可达 ----
	var roots: Array = []
	for node in nodes:
		if ((node as Dictionary).get("hard_prerequisite_ids", []) as Array).is_empty():
			roots.append(String((node as Dictionary).get("id", "")))
	if roots.size() != 1:
		_fail("expected exactly 1 root, found %d: %s" % [roots.size(), str(roots.slice(0, 6))])
	if roots.has(ROOT_ID):
		var root: Dictionary = by_id[ROOT_ID]
		if String(root.get("display_name", "")) != ROOT_NAME:
			_fail("root display_name %s != %s" % [root.get("display_name"), ROOT_NAME])
		if int(row_of[ROOT_ID]) != 0:
			_fail("root is not the first row (index %d)" % int(row_of[ROOT_ID]))
	else:
		_fail("root %s missing or not a root" % ROOT_ID)

	var children := {}
	for node in nodes:
		var node_id := String((node as Dictionary).get("id", ""))
		for prerequisite in ((node as Dictionary).get("hard_prerequisite_ids", []) as Array):
			var bucket: Array = children.get(String(prerequisite), [])
			bucket.append(node_id)
			children[String(prerequisite)] = bucket
	var visited := {}
	var queue: Array = [ROOT_ID]
	while not queue.is_empty():
		var current: String = queue.pop_back()
		if visited.has(current):
			continue
		visited[current] = true
		for child in children.get(current, []):
			queue.append(String(child))
	if visited.size() != nodes.size():
		_fail("root can reach %d of %d nodes" % [visited.size(), nodes.size()])

	# ---- 5. 每代：里程碑存在、候选池足够、候选同代 ----
	for index in range(eras.size()):
		var era: Dictionary = eras[index]
		var era_id := String(era.get("id", ""))
		var milestone := String(era.get("milestone_id", ""))
		if not by_id.has(milestone):
			_fail("era %s milestone %s missing" % [era_id, milestone])
		var candidates: Array = era.get("milestone_candidate_ids", [])
		var required := int(era.get("candidate_required", 0))
		if candidates.size() < required:
			_fail("era %s candidate pool %d < required %d" % [era_id, candidates.size(), required])
		for candidate in candidates:
			var candidate_id := String(candidate)
			if not by_id.has(candidate_id):
				_fail("era %s candidate %s missing" % [era_id, candidate_id])
				continue
			if String((by_id[candidate_id] as Dictionary).get("era_id", "")) != era_id:
				_fail("era %s candidate %s belongs to another era" % [era_id, candidate_id])
		if index > 0:
			var entry := String(era.get("entry_milestone_id", ""))
			var previous := String((eras[index - 1] as Dictionary).get("milestone_id", ""))
			if entry != previous:
				_fail("era %s entry milestone %s != previous milestone %s"
					% [era_id, entry, previous])

	# ---- 6. 成本价位：每代至少三档 ----
	for index in range(eras.size()):
		var era: Dictionary = eras[index]
		var era_id := String(era.get("id", ""))
		var costs := {}
		for node in nodes:
			if String((node as Dictionary).get("era_id", "")) != era_id:
				continue
			costs[_as_float((node as Dictionary).get("cost_points"))] = true
		if costs.size() < MIN_COST_TIERS:
			_fail("era %s has only %d distinct cost tiers" % [era_id, costs.size()])

	# ---- 7. 路线证据必须早于本节点，且 v5 之后每代都有路线或豁免 ----
	for index in range(nodes.size()):
		var node: Dictionary = nodes[index]
		var node_id := String(node.get("id", ""))
		var routes: Array = node.get("research_routes", [])
		var basis: Dictionary = node.get("knowledge_basis", {})
		var era_of_node := int(era_index.get(String(node.get("era_id", "")), 0))
		# 引擎规则：只有声明了替代证据组（alternative_groups）的节点才必须给路线；
		# 纯硬前置节点不需要，豁免又只允许根节点用 —— 所以这里只查有替代组的情况。
		var groups: Array = basis.get("alternative_groups", [])
		if era_of_node >= 2 and not groups.is_empty() and routes.is_empty():
			_fail("%s (era %d) declares alternative groups but has no research routes"
				% [node_id, era_of_node])
		for route in routes:
			var atoms: Array = []
			_collect_tech_atoms((route as Dictionary).get("condition", {}), atoms)
			for atom in atoms:
				if not by_id.has(String(atom)):
					_fail("%s route references unknown %s" % [node_id, atom])
				elif int(row_of[String(atom)]) >= index:
					_fail("%s route references later-defined %s" % [node_id, atom])

	# ---- 8. 内容效果与 expected_bindings 双向匹配 ----
	var target_owner := {}
	var duplicated := 0
	for node in nodes:
		var node_id := String((node as Dictionary).get("id", ""))
		var expected := {}
		for binding in ((node as Dictionary).get("expected_bindings", []) as Array):
			expected["%d|%s" % [int((binding as Dictionary).get("kind", 0)),
				String((binding as Dictionary).get("id", ""))]] = false
		for effect in ((node as Dictionary).get("content_effects", []) as Array):
			var entry: Dictionary = effect
			var binding_kind := int(entry.get("binding_kind", 0))
			# binding_kind == 0 是运行时能力效果（例如水运解锁），本来就不需要
			# expected_binding —— 编译器同样只对 binding_kind > 0 做双向匹配。
			if binding_kind > 0:
				var key := "%d|%s" % [binding_kind, String(entry.get("id", ""))]
				if not expected.has(key):
					_fail("%s effect %s has no matching expected_binding" % [node_id, key])
				else:
					expected[key] = true
			var target := "%s:%s" % [String(entry.get("kind", "")), String(entry.get("id", ""))]
			if target_owner.has(target) and String(target_owner[target]) != node_id:
				duplicated += 1
			target_owner[target] = node_id
		for key in expected:
			if not bool(expected[key]):
				_fail("%s expected_binding %s is unused" % [node_id, key])
	if duplicated > DUPLICATE_TARGET_BUDGET:
		_fail("duplicate unlock targets %d > budget %d" % [duplicated, DUPLICATE_TARGET_BUDGET])

	# ---- 9. 结构校验器必须全绿 ----
	var report: Dictionary = VALIDATOR_SCRIPT.validate(data)
	if not bool(report.get("ok", false)):
		var issues: Array = report.get("findings", [])
		_fail("technology network validator reported %d finding(s); first=%s"
			% [issues.size(), str(issues[0]) if not issues.is_empty() else ""])

	_done()


func _done() -> void:
	if failures == 0:
		print("DESIGN TEST PASS")
		quit(0)
		return
	printerr("DESIGN TEST FAIL: %d failure(s)" % failures)
	quit(1)
