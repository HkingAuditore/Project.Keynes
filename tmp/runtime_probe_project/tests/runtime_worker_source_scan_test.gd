extends SceneTree

const WORKER_SOURCES := [
	"gdext/src/native_simulation_host.cpp",
	"gdext/src/native_simulation_host.h",
	"gdext/src/runtime_climate_authority.cpp",
	"gdext/src/runtime_climate_authority.h",
	"gdext/src/runtime_authoritative_domains.cpp",
	"gdext/src/runtime_authoritative_domains.h",
	"gdext/src/runtime_climate_kernel.cpp",
	"gdext/src/runtime_climate_kernel.h",
	"gdext/src/runtime_climate_trace.h",
	"gdext/src/runtime_country_pod.cpp",
	"gdext/src/runtime_country_pod.h",
	"gdext/src/runtime_domain_pod.cpp",
	"gdext/src/runtime_domain_pod.h",
	"gdext/src/runtime_pod_protocol.h",
	"gdext/src/runtime_snapshot_ring.cpp",
	"gdext/src/runtime_snapshot_ring.h",
	"gdext/src/native_parallel_executor.cpp",
	"gdext/src/native_parallel_executor.h",
	"gdext/src/runtime_protocol_guard.cpp",
	"gdext/src/runtime_protocol_guard.h",
]

const FORBIDDEN_TOKENS := [
	"#include <godot",
	"godot::",
	"Dictionary",
	"Variant",
	"Object",
	"PackedArray",
	"MapData",
]

var _failures := 0

func _init() -> void:
	var project_root := ProjectSettings.globalize_path("res://").path_join("../..").simplify_path()
	for relative_path in WORKER_SOURCES:
		var absolute_path := project_root.path_join(relative_path)
		var source := FileAccess.get_file_as_string(absolute_path)
		if source.is_empty():
			_fail("worker source missing: %s" % absolute_path)
			continue
		var code := _strip_comments(source)
		for token in FORBIDDEN_TOKENS:
			if code.contains(token):
				_fail("worker source contains forbidden token '%s': %s" % [token, relative_path])
	if _failures == 0:
		print("runtime worker source scan: PASS")
	quit(0 if _failures == 0 else 1)

func _fail(message: String) -> void:
	_failures += 1
	push_error(message)


func _strip_comments(source: String) -> String:
	var comments := RegEx.new()
	if comments.compile("(?s)/\\*.*?\\*/|//[^\\r\\n]*") != OK:
		return source
	return comments.sub(source, "", true)
