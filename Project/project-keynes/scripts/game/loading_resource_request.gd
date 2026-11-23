extends RefCounted

## This collector owns no world or loading gate. It joins its loader after
## completion even when the requesting screen has canceled.
static var pending_count := 0
static var _pending: Dictionary = {}
static var _web_queue: Array[RefCounted] = []
static var _web_frame := -1
const LOAD_SLICE_USEC := 4000
var finished := false
var result: Resource
var start_error := OK
var progress := 0.0
var _tree: SceneTree
var _thread: Thread
var _type_hint: String
var _paths: Array[String] = []
var _expanded: Dictionary = {}
var _loaded: Dictionary = {}

func _init(path: String, type_hint: String = "Resource") -> void:
	_tree = Engine.get_main_loop() as SceneTree
	if _tree == null:
		start_error = ERR_UNAVAILABLE
	else:
		if not OS.has_feature("web") or OS.has_feature("threads"):
			# Godot's threaded-request token can leak when completion is
			# claimed while the loader is dropping its final reference.
			_thread = Thread.new()
			start_error = _thread.start(ResourceLoader.load.bind(path, type_hint))
		else:
			_type_hint = type_hint
			_paths.push_back(path)
			_web_queue.push_back(self)
			_web_frame = Engine.get_process_frames()
	if start_error != OK:
		finished = true
		return
	_pending[get_instance_id()] = self
	pending_count += 1
	_tree.process_frame.connect(_poll)
	_tree.root.tree_exiting.connect(_finish_on_shutdown, CONNECT_ONE_SHOT)

func _poll() -> void:
	if _thread != null:
		if not _thread.is_alive():
			_finish(_thread.wait_to_finish())
		return
	var frame := Engine.get_process_frames()
	if _web_queue.front() == self and _web_frame != frame:
		_web_frame = frame
		_load_dependency_slice()


func _load_dependency_slice() -> void:
	var started := Time.get_ticks_usec()
	while not _paths.is_empty():
		var path: String = _paths.back()
		if not _expanded.has(path) and not ResourceLoader.has_cached(path):
			_expanded[path] = true
			# Godot qualifies UID references as uid::fallback with an empty type slot.
			var dependencies := ResourceLoader.get_dependencies(path)
			for index in range(dependencies.size() - 1, -1, -1):
				var parts := dependencies[index].split("::")
				var dependency: String = parts[0]
				if parts.size() == 3:
					var uid := ResourceUID.text_to_id(parts[0])
					dependency = ResourceUID.get_id_path(uid) if ResourceUID.has_id(uid) else parts[2]
				if not _expanded.has(dependency) and not _loaded.has(dependency) \
						and ResourceLoader.exists(dependency):
					_paths.push_back(dependency)
		else:
			_paths.pop_back()
			if _paths.is_empty():
				_finish(ResourceLoader.load(path, _type_hint))
				return
			# Retain the dependencies so the scene parse can reuse the engine cache.
			if not _loaded.has(path):
				_loaded[path] = ResourceLoader.load(path)
		if Time.get_ticks_usec() - started >= LOAD_SLICE_USEC:
			break
	progress = maxf(progress, float(_loaded.size()) / maxi(1, _loaded.size() + _paths.size()))


func _finish_on_shutdown() -> void:
	_finish(_thread.wait_to_finish() if _thread != null else null)


func _finish(loaded: Variant) -> void:
	result = loaded as Resource
	if _thread == null:
		_web_queue.erase(self)
		_paths.clear()
		_expanded.clear()
		_loaded.clear()
	_thread = null
	progress = 1.0
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
