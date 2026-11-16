extends SceneTree

const Cache = preload("res://scripts/game/loading_catalog_cache.gd")
const Gate = preload("res://scripts/geography/loading_frame_gate.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + label)

func _run() -> void:
	Cache.invalidate()
	var directory := "user://loading_snapshot_cleanup_%d/" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var paths := PackedStringArray()
	for filename in Cache.SNAPSHOT_FILES:
		var source: String = Cache.DIRECTORY + filename
		var destination: String = directory + filename
		var file := FileAccess.open(destination, FileAccess.WRITE)
		file.store_buffer(FileAccess.get_file_as_bytes(source))
		file = null
		paths.append(destination)
	var gate := Gate.new()
	process_frame.connect(gate.cancel, CONNECT_ONE_SHOT)
	var canceled: Array[Resource] = await Cache._load_snapshots(paths, gate)
	_expect("warm snapshot cancellation returns no partial set", canceled.is_empty())
	_expect("cancellation leaves completion collectors running", Cache.ResourceRequest.pending_count > 0)
	_expect("cancellation never publishes cache", not Cache._ready)
	var weak_gate: WeakRef = weakref(gate)
	gate = null
	await process_frame
	_expect("completion collectors do not retain the gate", weak_gate.get_ref() == null)
	while Cache.ResourceRequest.pending_count > 0:
		await process_frame
	_expect("all canceled snapshot requests collected", Cache.ResourceRequest.pending_count == 0)
	# A malformed file exercises a real engine async-load failure. The other
	# requests still finish and get collected after the helper rejects the set.
	var bad_path := directory + "broken.tres"
	var broken := FileAccess.open(bad_path, FileAccess.WRITE)
	broken.store_string("not a resource")
	broken = null
	var failed_paths := paths.duplicate()
	failed_paths[0] = bad_path
	print("[loading-snapshot-cancel] broken_resource=" + bad_path)
	var failed: Array[Resource] = await Cache._load_snapshots(failed_paths)
	_expect("failed snapshot set rejected", failed.is_empty())
	_expect("failed set never publishes cache", not Cache._ready)
	while Cache.ResourceRequest.pending_count > 0:
		await process_frame
	_expect("all failed batch requests collected", Cache.ResourceRequest.pending_count == 0)
	var loaded: Array[Resource] = await Cache._load_snapshots(paths)
	_expect("complete snapshot set still loads", loaded.size() == Cache.SNAPSHOT_FILES.size())
	_expect("successful batch collectors drained", Cache.ResourceRequest.pending_count == 0)
	for path in paths:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bad_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))
	print("[loading-snapshot-cancel] checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
