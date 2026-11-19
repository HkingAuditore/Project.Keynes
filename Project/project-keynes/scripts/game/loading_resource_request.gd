extends RefCounted

## This collector owns no world or loading gate. It joins its loader after
## completion even when the requesting screen has canceled.
static var pending_count := 0
static var _pending: Dictionary = {}
var finished := false
var result: Resource
var start_error := OK
var _tree: SceneTree
var _thread: Thread
var _load: Callable

func _init(path: String, type_hint: String = "Resource") -> void:
	_tree = Engine.get_main_loop() as SceneTree
	if _tree == null:
		start_error = ERR_UNAVAILABLE
	else:
		_load = ResourceLoader.load.bind(path, type_hint)
		if not OS.has_feature("web") or OS.has_feature("threads"):
			# Godot's threaded-request token can leak when completion is
			# claimed while the loader is dropping its final reference.
			_thread = Thread.new()
			start_error = _thread.start(_load)
	if start_error != OK:
		finished = true
		return
	_pending[get_instance_id()] = self
	pending_count += 1
	_tree.process_frame.connect(_poll)
	_tree.root.tree_exiting.connect(_finish_on_shutdown, CONNECT_ONE_SHOT)

func _poll() -> void:
	if _thread != null and _thread.is_alive():
		return
	_finish(_thread.wait_to_finish() if _thread != null else _load.call())


func _finish_on_shutdown() -> void:
	_finish(_thread.wait_to_finish() if _thread != null else null)


func _finish(loaded: Variant) -> void:
	result = loaded as Resource
	_thread = null
	_load = Callable()
	finished = true
	pending_count -= 1
	_tree.process_frame.disconnect(_poll)
	if _tree.root.tree_exiting.is_connected(_finish_on_shutdown):
		_tree.root.tree_exiting.disconnect(_finish_on_shutdown)
	_tree = null
	_pending.erase(get_instance_id())


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _thread != null and _thread.is_started():
		_thread.wait_to_finish()


static func wait_for_pending(tree: SceneTree) -> void:
	while pending_count > 0:
		await tree.process_frame
