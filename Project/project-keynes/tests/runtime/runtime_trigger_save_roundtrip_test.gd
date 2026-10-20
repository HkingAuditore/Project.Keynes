extends SceneTree

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt unavailable")
		quit(1)
		return
	var ext := DCWorldExt.new()
	var ok := ext.has_method("runtime_trigger_pod_self_test") and bool(ext.runtime_trigger_pod_self_test())
	if not ok:
		push_error("Trigger TPD1 save roundtrip failed")
	quit(0 if ok else 1)
