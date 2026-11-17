extends SceneTree

# 时代闸只放行「下一时代」：时代 N（N ≥ 2）的任意节点都要求持有 eras[N-1] 的
# 里程碑，时代 0/1 不设闸。此前普通节点完全没有时代门，石器时代可以靠跨代
# 硬前置一路把研究爬到帝国甚至更远；里程碑又早已退出研究队列（改由时代晋升
# 授予），于是那道闸从来没生效过。见
# docs/cpp-dots-runtime/technology-tree-runtime.md「时代闸」。

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const CONDITION_PUSH_TECH_COMPLETED := 1

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("technology era gate: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var ids: PackedStringArray = compiled.get("technology_ids", PackedStringArray())
	var era_ids: PackedStringArray = compiled.get("technology_era_ids", PackedStringArray())
	var era_order: PackedStringArray = compiled.get(
		"technology_era_ids_ordered", PackedStringArray())
	var entry: PackedInt32Array = compiled.get(
		"technology_entry_milestone_indices", PackedInt32Array())
	var era_entry: PackedInt32Array = compiled.get(
		"technology_era_entry_milestone_indices", PackedInt32Array())
	var flags: PackedInt32Array = compiled.get("technology_flags", PackedInt32Array())
	_expect("catalog shape is dense",
		ids.size() == entry.size() and ids.size() == era_ids.size()
		and ids.size() == flags.size())
	_expect("eleven eras with one entry gate each",
		era_order.size() == 11 and era_entry.size() == 11)
	if ids.is_empty() or era_order.size() != 11:
		return

	var gate_mismatch := 0
	var early_gate := 0
	var late_gate := 0
	for technology in range(ids.size()):
		var position := era_order.find(String(era_ids[technology]))
		if position < 0:
			continue
		var is_milestone := (int(flags[technology]) & 2) != 0
		# 里程碑节点保持内部时代令牌判据；普通节点在时代 ≥ 2 时才加闸。
		var gated := position >= 2 or (is_milestone and position >= 1)
		var expected := int(era_entry[position]) if gated else -1
		if int(entry[technology]) != expected:
			gate_mismatch += 1
		# 里程碑节点是内部时代令牌，农耕里程碑仍要求石器里程碑，不算「过早加闸」。
		if position <= 1 and not is_milestone and int(entry[technology]) >= 0:
			early_gate += 1
		var entry_index := int(entry[technology])
		if entry_index >= 0 and entry_index < ids.size() \
				and era_order.find(String(era_ids[entry_index])) >= position:
			late_gate += 1
	_expect("every node carries exactly the previous-era gate", gate_mismatch == 0,
		"%d nodes drifted" % gate_mismatch)
	_expect("stone and agrarian nodes stay ungated", early_gate == 0,
		"%d nodes gated too early" % early_gate)
	_expect("gate milestone always sits in an earlier era", late_gate == 0,
		"%d nodes gated on their own or a later era" % late_gate)

	# IR 层：王国的普通节点现在必须引用农耕里程碑，石器和农耕节点不引用任何里程碑。
	_expect("kingdom node's IR requires the agrarian milestone",
		_ir_refs(compiled, "tech.writing", "tech.agrarian_society"))
	_expect("stone node's IR has no era gate",
		not _ir_refs(compiled, "tech.hunting", "tech.settled_knowledge"))
	_expect("agrarian node's IR has no era gate",
		not _ir_refs(compiled, "tech.household_landholding", "tech.settled_knowledge"))
	# 只放行一代：帝国节点只挂在王国里程碑上，不额外要求农耕里程碑。
	_expect("empire node's IR requires the kingdom milestone",
		_ir_refs(compiled, "tech.sharecropping", "tech.kingdom_administration"))
	_expect("empire node's IR does not stack older milestones",
		not _ir_refs(compiled, "tech.sharecropping", "tech.agrarian_society"))


func _ir_refs(compiled: Dictionary, technology_id: String, referenced_id: String) -> bool:
	var ids: PackedStringArray = compiled.get("technology_ids", PackedStringArray())
	var offsets: PackedInt32Array = compiled.get(
		"technology_research_condition_offsets", PackedInt32Array())
	var ops: PackedInt32Array = compiled.get(
		"technology_research_condition_ops", PackedInt32Array())
	var refs: PackedInt32Array = compiled.get(
		"technology_research_condition_refs", PackedInt32Array())
	var technology := ids.find(technology_id)
	var referenced := ids.find(referenced_id)
	if technology < 0 or referenced < 0 or technology + 1 >= offsets.size():
		return false
	for cursor in range(int(offsets[technology]), int(offsets[technology + 1])):
		if cursor < ops.size() and cursor < refs.size() \
				and int(ops[cursor]) == CONDITION_PUSH_TECH_COMPLETED \
				and int(refs[cursor]) == referenced:
			return true
	return false


func _expect(label: String, condition: bool, detail := "") -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	push_error("[FAIL] %s%s" % [label, (" (%s)" % detail) if not detail.is_empty() else ""])
