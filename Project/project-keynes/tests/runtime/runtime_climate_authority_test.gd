extends SceneTree

func _init() -> void:
	var world := DCWorldExt.new()
	if not world.runtime_climate_authority_self_test() or not world.runtime_climate_trace_self_test():
		push_error("runtime climate authority self-test failed")
		quit(1)
		return
	print("runtime climate authority: PASS")
	quit(0)
