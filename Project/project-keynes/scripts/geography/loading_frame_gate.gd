extends RefCounted

## A loading operation waits for the next frame or explicit cancellation.
## Cancellation unwinds suspended calls while their scene owner still exists.
signal resumed
var canceled := false
var _tree: SceneTree

func next_frame():
	if canceled:
		return null
	_tree = Engine.get_main_loop() as SceneTree
	if _tree == null:
		return null
	if not _tree.process_frame.is_connected(_resume):
		_tree.process_frame.connect(_resume, CONNECT_ONE_SHOT)
	return resumed

func cancel() -> void:
	canceled = true
	_resume()

func _resume() -> void:
	if is_instance_valid(_tree) and _tree.process_frame.is_connected(_resume):
		_tree.process_frame.disconnect(_resume)
	_tree = null
	resumed.emit()
