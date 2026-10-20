extends SceneTree


func _init() -> void:
	var ext := DCWorldExt.new()
	# The native fixture withdraws the cached merchant, attempts the exact
	# 11166-subunit debt payment from the day-10315 fault, then retries with a
	# recipient. A rejected payment must preserve both cash and principal.
	var ok := bool(ext.runtime_economy_authority_fault_gate_self_test())
	print("merchant debt conservation regression: %s" % ("PASS" if ok else "FAIL"))
	ext = null
	quit(0 if ok else 1)
