extends SceneTree

var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt unavailable")
		quit(1)
		return
	var ext := DCWorldExt.new()
	if not ext.has_method("runtime_trigger_pod_self_test"):
		push_error("Trigger POD self-test binding unavailable")
		quit(1)
		return
	if not bool(ext.runtime_trigger_pod_self_test()):
		push_error("Trigger POD self-test failed")
		_failures += 1
	print("runtime trigger pod: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)
