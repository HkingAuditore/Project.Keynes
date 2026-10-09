extends SceneTree

func _init() -> void:
	var failures := 0
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt class unavailable")
		quit(1)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if not ext.has_method("runtime_snapshot_ring_self_test"):
		push_error("runtime snapshot ring self-test API unavailable")
		quit(1)
		return
	if not bool(ext.runtime_snapshot_ring_self_test()):
		failures += 1
		push_error("runtime snapshot ring self-test failed")
	else:
		print("runtime snapshot ring: PASS")
	quit(0 if failures == 0 else 1)
