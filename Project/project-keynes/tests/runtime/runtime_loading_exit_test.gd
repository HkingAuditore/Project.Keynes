extends SceneTree

var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	# Exercise immediate exit and suspension in catalog/native/map/bake work.
	# These are sampling points, not deadlines or loading fallbacks.
	for frames in [0, 2, 5, 15, 40, 80]:
		await _close_loading_world(frames)
	print("runtime loading exit: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _close_loading_world(frames: int) -> void:
	var host := WorldRuntimeHost.new()
	root.add_child(host)
	host.configure(null, null, null)
	host.generate_world(20260718)
	for _frame in frames:
		await process_frame
	var generator = host.get_generator()
	_expect("generation started before exit at frame %d" % frames, generator != null)
	var released: WeakRef = weakref(generator)
	generator = null
	host.free()
	await process_frame
	_expect("exit releases loading world at frame %d" % frames, released.get_ref() == null)

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)
