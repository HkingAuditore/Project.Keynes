extends RefCounted

## ResourceLoader keeps a threaded request until load_threaded_get consumes it.
## This small collector owns no world/generator/gate. It survives cancellation
## only until the engine finishes loading, then collects without blocking.
static var pending_count := 0
static var _pending: Dictionary = {}
var finished := false
var result: Resource
var _path: String
var _tree: SceneTree

func _init(path: String) -> void:
	_path = path
	_tree = Engine.get_main_loop() as SceneTree
	if _tree == null or ResourceLoader.load_threaded_request(path, "Resource") != OK:
		finished = true
		return
	_pending[get_instance_id()] = self
	pending_count += 1
	_tree.process_frame.connect(_poll)

func _poll() -> void:
	var status := ResourceLoader.load_threaded_get_status(_path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return
	# Both success and failure are complete: get removes the request either way.
	if status != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		result = ResourceLoader.load_threaded_get(_path) as Resource
	finished = true
	pending_count -= 1
	_tree.process_frame.disconnect(_poll)
	_tree = null
	_pending.erase(get_instance_id())
