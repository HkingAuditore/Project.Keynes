extends SceneTree

# 诊断：生产用的 EffectDomainCatalog 是否能被 worker 的 Effect POD 接受。
#
# 背景：pod 的编译期校验（gdext/src/runtime_effect_pod.cpp:300-400）是**整目录
# 级**的 —— 任何一个定义越界都会让 configure 返回 false，进而使
# effect_stage_enabled=false、completed_domain_mask 缺少 EFFECT 位，
# 最终 (completed & wanted) != wanted 让整个 12 域授权图永远不激活。
#
# 所以「作者写了一张开不动的卡」的代价不是「这张卡不生效」，而是
# 「全部 worker 权威静默退回主线程」。这个探针把那条边界显式量出来。
#
# pod 能力子集（与 runtime_effect_pod.cpp 一一对应）：
#   target_selector_kind <= 12       :POD_MAX_SELECTOR_KIND
#   STATE_GTE arg0 <= 4              :POD_MAX_STATE_ID
#   READ_STATE arg0 <= 4             :POD_MAX_STATE_ID
# 两个上限都取自 gdext/src/runtime_effect_pod.cpp 的同名常量。它们曾低于主线程
# 上限（7 / 3），直接把整份目录拒收，所以这里刻意与主线程一致而不是写死更小的数。
# MODIFIER 命令的 domain/opcode 已被 EffectCatalog._native_command_error() 钉得更紧，
# 不会成为 pod 侧的差异来源，所以这里不重复检查。
#
# 通过标准（两条都要）：
#   1. effect_pod_ready == true  —— 目录真的被 worker 接受了
#   2. EffectCatalog 的 pod_expressible 列与校验规则**双向一致** —— 被排除的
#      确实越界，留在里面的确实合规。单向一致仍会在未来悄悄复发。
#
# 用法：
#   godot --headless --path Project/project-keynes -s tests/effect_pod_capability_probe.gd

const POD_MAX_SELECTOR_KIND := EffectCatalog.POD_MAX_SELECTOR_KIND
const POD_MAX_STATE_ID := EffectCatalog.POD_MAX_STATE_ID

const INSTRUCTION_READ_STATE := 3
const INSTRUCTION_READ_METRIC := 2
const CONDITION_METRIC_GTE := 2
const CONDITION_METRIC_EQ := 4
const CONDITION_STATE_GTE := 5

var _violations := 0
var _excluded: Array[String] = []
var _mismatched: Array[String] = []


func _report(key: String, detail: String) -> void:
	_violations += 1
	printerr("  VIOLATION %s :: %s" % [key, detail])


## Returns the capability reasons a definition cannot live in the POD subset.
func _subset_breaches(compiled: Dictionary, index: int, metric_count: int) -> Array[String]:
	var reasons: Array[String] = []
	var selector_kinds: PackedInt32Array = compiled.get("target_selector_kinds", PackedInt32Array())
	if index < selector_kinds.size() and int(selector_kinds[index]) > POD_MAX_SELECTOR_KIND:
		reasons.append("selector kind %d > %d" % [int(selector_kinds[index]), POD_MAX_SELECTOR_KIND])

	var condition_offsets: PackedInt32Array = compiled.get("condition_offsets", PackedInt32Array())
	var condition_ops: PackedInt32Array = compiled.get("condition_ops", PackedInt32Array())
	var condition_arg0: PackedInt32Array = compiled.get("condition_arg0", PackedInt32Array())
	if index + 1 < condition_offsets.size():
		for cursor in range(int(condition_offsets[index]), int(condition_offsets[index + 1])):
			if cursor >= condition_ops.size():
				break
			var op := int(condition_ops[cursor])
			var arg0 := int(condition_arg0[cursor])
			if op == CONDITION_STATE_GTE and arg0 > POD_MAX_STATE_ID:
				reasons.append("condition STATE_GTE arg0 %d > %d" % [arg0, POD_MAX_STATE_ID])
			elif op >= CONDITION_METRIC_GTE and op <= CONDITION_METRIC_EQ \
					and (arg0 < 0 or arg0 >= metric_count):
				reasons.append("condition metric arg0 %d outside metric table (%d)"
					% [arg0, metric_count])

	var instruction_offsets: PackedInt32Array = compiled.get("instruction_offsets", PackedInt32Array())
	var instruction_ops: PackedInt32Array = compiled.get("instruction_ops", PackedInt32Array())
	var instruction_arg0: PackedInt32Array = compiled.get("instruction_arg0", PackedInt32Array())
	if index + 1 < instruction_offsets.size():
		for cursor in range(int(instruction_offsets[index]), int(instruction_offsets[index + 1])):
			if cursor >= instruction_ops.size():
				break
			if int(instruction_ops[cursor]) == INSTRUCTION_READ_STATE \
					and int(instruction_arg0[cursor]) > POD_MAX_STATE_ID:
				reasons.append("instruction READ_STATE arg0 %d > %d"
					% [int(instruction_arg0[cursor]), POD_MAX_STATE_ID])
			elif int(instruction_ops[cursor]) == INSTRUCTION_READ_METRIC \
					and (int(instruction_arg0[cursor]) < 0
						or int(instruction_arg0[cursor]) >= metric_count):
				reasons.append("instruction READ_METRIC arg0 %d outside metric table (%d)"
					% [int(instruction_arg0[cursor]), metric_count])
	return reasons


func _scan(compiled: Dictionary) -> void:
	var keys: PackedStringArray = compiled.get("effect_keys", PackedStringArray())
	var selector_kinds: PackedInt32Array = compiled.get("target_selector_kinds", PackedInt32Array())
	var pod_expressible: PackedByteArray = compiled.get("pod_expressible", PackedByteArray())
	var metric_keys: PackedStringArray = compiled.get("metric_keys", PackedStringArray())
	var metric_count := metric_keys.size()

	print("defined programs: %d" % keys.size())
	print("metric table: %d keys" % metric_count)
	print("selector kinds present: %s" % str(_histogram(selector_kinds)))
	if pod_expressible.size() != keys.size():
		_report("<catalog>", "pod_expressible column %d != program count %d"
			% [pod_expressible.size(), keys.size()])
		return

	# The filter and the POD validator must agree in both directions: anything
	# flagged inexpressible really is out of subset, and anything left in really
	# is inside it. A silent divergence here is exactly what produced the
	# catalog-wide rejection this probe was written for.
	for index in keys.size():
		var reasons := _subset_breaches(compiled, index, metric_count)
		var flagged := int(pod_expressible[index]) == 0
		if flagged:
			_excluded.append(keys[index])
		if flagged and reasons.is_empty():
			_mismatched.append(keys[index])
			_report(keys[index], "excluded from POD but inside the subset")
		elif not flagged and not reasons.is_empty():
			_mismatched.append(keys[index])
			_report(keys[index], "left in POD but breaks it: %s" % "; ".join(reasons))

	print("excluded from POD: %d %s" % [_excluded.size(),
		("(" + ", ".join(_excluded) + ")") if not _excluded.is_empty() else ""])


## M1 前置扫描：谁在用 state？
#
# pod 当前的 state_value（runtime_effect_pod.cpp:747-755 / :930-938）语义是
#   0=level(原值) 1=fire_sequence(原值) 2=stack_count 3=input_revision
# 而主线程（effect_runtime.cpp:3840-3859）是
#   0=level×Q16 1=fire×Q16 2=input_revision 3=remaining_days×Q16 4=stack×Q16
# 也就是 0/1/2/3 四个 id **全部错位**。把 pod 对齐之前必须先确认没有任何
# 已在 worker 上运行的程序依赖旧语义，否则对齐就是一次静默的语义漂移。
func _scan_state_usage(compiled: Dictionary) -> void:
	var keys: PackedStringArray = compiled.get("effect_keys", PackedStringArray())
	var pod_expressible: PackedByteArray = compiled.get("pod_expressible", PackedByteArray())
	var condition_offsets: PackedInt32Array = compiled.get("condition_offsets", PackedInt32Array())
	var condition_ops: PackedInt32Array = compiled.get("condition_ops", PackedInt32Array())
	var condition_arg0: PackedInt32Array = compiled.get("condition_arg0", PackedInt32Array())
	var instruction_offsets: PackedInt32Array = compiled.get("instruction_offsets", PackedInt32Array())
	var instruction_ops: PackedInt32Array = compiled.get("instruction_ops", PackedInt32Array())
	var instruction_arg0: PackedInt32Array = compiled.get("instruction_arg0", PackedInt32Array())

	var cond_ids := {}
	var inst_ids := {}
	var users: Array[String] = []
	for index in keys.size():
		var touches := false
		if index + 1 < condition_offsets.size():
			for cursor in range(int(condition_offsets[index]), int(condition_offsets[index + 1])):
				if cursor >= condition_ops.size():
					break
				if int(condition_ops[cursor]) == CONDITION_STATE_GTE:
					var id := int(condition_arg0[cursor])
					cond_ids[id] = int(cond_ids.get(id, 0)) + 1
					touches = true
		if index + 1 < instruction_offsets.size():
			for cursor in range(int(instruction_offsets[index]), int(instruction_offsets[index + 1])):
				if cursor >= instruction_ops.size():
					break
				if int(instruction_ops[cursor]) == INSTRUCTION_READ_STATE:
					var id := int(instruction_arg0[cursor])
					inst_ids[id] = int(inst_ids.get(id, 0)) + 1
					touches = true
		if touches:
			var in_pod := index < pod_expressible.size() and int(pod_expressible[index]) != 0
			users.append("%s%s" % [keys[index], "" if in_pod else " [not-in-pod]"])

	print("--- M1 pre-scan: state usage ---")
	print("STATE_GTE arg0 histogram : %s" % str(cond_ids))
	print("READ_STATE arg0 histogram: %s" % str(inst_ids))
	print("programs touching state  : %d" % users.size())
	for key in users:
		print("    %s" % key)


func _histogram(values: PackedInt32Array) -> Dictionary:
	var out := {}
	for value in values:
		out[value] = int(out.get(value, 0)) + 1
	return out


func _init() -> void:
	print("=== effect pod capability probe ===")
	var domain_catalog: Resource = EffectDomainCatalog.build()
	if domain_catalog == null:
		printerr("FAIL: EffectDomainCatalog.build() returned null")
		quit(1)
		return
	var compiled: Dictionary = domain_catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		printerr("FAIL: catalog compile failed: %s" % str(compiled.get("reason", "")))
		quit(1)
		return

	_scan(compiled)
	_scan_state_usage(compiled)

	var ext = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		printerr("FAIL: DCWorldExt unavailable")
		quit(1)
		return
	var configured: Dictionary = ext.configure_effects(compiled)
	var ok := bool(configured.get("ok", false))
	var pod_ready := bool(configured.get("effect_pod_ready", false))
	var reason := str(configured.get("effect_pod_fallback_reason", ""))
	print("configure.ok            = %s" % str(ok))
	print("effect_pod_ready        = %s" % str(pod_ready))
	print("effect_pod_fallback     = %s" % (reason if not reason.is_empty() else "<none>"))
	print("effect_pod_catalog_hash = %d" % int(configured.get("effect_pod_catalog_hash", 0)))
	print("violations              = %d" % _violations)
	# DCWorldExt is RefCounted: drop the reference, never free() it.
	ext = null

	if not pod_ready:
		printerr("RESULT: FAIL — worker Effect POD refuses the production catalog")
		quit(1)
		return
	if _violations > 0:
		printerr("RESULT: UNEXPECTED — pod ready but capability scan found violations")
		quit(1)
		return
	print("RESULT: PASS — production catalog is inside the pod capability subset")
	quit(0)
