extends SceneTree
func _init() -> void:
	var library = load("res://money.gdextension")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var ok := bool(ext.runtime_economy_authority_fault_gate_self_test())
	print("merchant debt conservation regression: ", "PASS" if ok else "FAIL")
	ext = null
	quit(0 if ok else 1)
