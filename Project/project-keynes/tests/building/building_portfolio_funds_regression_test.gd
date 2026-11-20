extends SceneTree


func _init() -> void:
	var ext := DCWorldExt.new()
	# Native fixtures cover merchant construction cash reused for lending,
	# funded prefixes, and unequal family/anonymous claims across a shared sponsor.
	var ok := bool(ext.runtime_economy_authority_fault_gate_self_test())
	print("building portfolio funds regression: %s" % ("PASS" if ok else "FAIL"))
	ext = null
	quit(0 if ok else 1)
