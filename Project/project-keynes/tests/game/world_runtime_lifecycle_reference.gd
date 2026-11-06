extends RefCounted

## Frozen lifecycle contract for the R4 extraction. The reference records the
## public host entrypoints and the required stop-before-release ordering.
const HOST_METHODS := [
	"func close_world() -> Dictionary:",
	"func _cancel_world_preparation() -> void:",
	"func _cancel_session_simulation() -> void:",
	"func _release_session_simulation() -> Dictionary:",
	"func _cancel_session_presentation() -> void:",
	"func _release_session_presentation() -> Dictionary:",
	"func _release_world_data() -> Dictionary:",
]
const LIFECYCLE_METHODS := [
	"func close_world(host) -> Dictionary:",
	"func cancel_world_preparation(host) -> void:",
	"func cancel_session_simulation(host) -> void:",
	"func release_session_simulation(host) -> Dictionary:",
	"func cancel_session_presentation(host) -> void:",
	"func release_session_presentation(host) -> Dictionary:",
	"func release_world_data(host) -> Dictionary:",
]
