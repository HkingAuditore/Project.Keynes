extends RefCounted

## ResourceLoader keeps a threaded request until load_threaded_get consumes it.
## This small collector owns no world/generator/gate. It survives cancellation
## only until the engine finishes loading, then collects without blocking.
static var pending_count := 0
static var _pending: Dictionary = {}
var finished := false
var result: Resource
var start_error := OK
var _path: String
var _tree: SceneTree

func _init(path: String, type_hint: String = "Resource") -> void:
	_path = path
	_tree = Engine.get_main_loop() as SceneTree
	start_error = ERR_UNAVAILABLE if _tree == null \
		else ResourceLoader.load_threaded_request(path, type_hint)
	if start_error != OK:
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


static func wait_for_pending(tree: SceneTree) -> void:
	while pending_count > 0:
		await tree.process_frame
