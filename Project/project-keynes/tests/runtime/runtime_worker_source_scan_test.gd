extends SceneTree

const WORKER_SOURCES := [
	"gdext/src/native_simulation_host.cpp",
	"gdext/src/native_simulation_host.h",
	"gdext/src/runtime_climate_authority.cpp",
	"gdext/src/runtime_climate_authority.h",
	"gdext/src/runtime_climate_authority_persistence.cpp",
	"gdext/src/runtime_climate_authority_publication.cpp",
	"gdext/src/runtime_climate_authority_selftest.cpp",
	"gdext/src/runtime_authoritative_domains.cpp",
	"gdext/src/runtime_authoritative_domains.h",
	"gdext/src/runtime_authoritative_domains_environment.cpp",
	"gdext/src/runtime_climate_kernel.cpp",
	"gdext/src/runtime_climate_kernel.h",
	"gdext/src/runtime_climate_passes.cpp",
	"gdext/src/runtime_climate_passes.h",
	"gdext/src/runtime_climate_physics.cpp",
	"gdext/src/runtime_climate_physics.h",
	"gdext/src/runtime_climate_physics_ocean_solver.cpp",
	"gdext/src/runtime_climate_physics_selftest.cpp",
	"gdext/src/runtime_climate_physics_solver.h",
	"gdext/src/runtime_climate_physics_wind_transport.cpp",
	"gdext/src/runtime_climate_formulas.cpp",
	"gdext/src/runtime_climate_formulas.h",
	"gdext/src/runtime_climate_trace.h",
	"gdext/src/runtime_country_pod.cpp",
	"gdext/src/runtime_country_pod.h",
	"gdext/src/runtime_trigger_kernel.cpp",
	"gdext/src/runtime_trigger_kernel.h",
	"gdext/src/runtime_trigger_pod.cpp",
	"gdext/src/runtime_trigger_pod.h",
	"gdext/src/runtime_trigger_pod_snapshot_ring.cpp",
	"gdext/src/runtime_ideology_pod.cpp",
	"gdext/src/runtime_ideology_pod.h",
	"gdext/src/runtime_ideology_pod_catalog.h",
	# The Effect POD runs on the worker thread and shares its metric/instance
	# structs with the ideology and modifier stages. It was self-declared
	# Godot-free but unenforced, so a stray include would only surface as a
	# link error or a silent cross-thread type.
	"gdext/src/runtime_effect_pod.cpp",
	"gdext/src/runtime_effect_pod.h",
	"gdext/src/runtime_effect_pod_snapshot_ring.cpp",
	"gdext/src/runtime_domain_pod.cpp",
	"gdext/src/runtime_domain_pod.h",
	"gdext/src/runtime_domain_pod_persistence.cpp",
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
	var fragments := RegEx.create_from_string('(?m)^\\s*#include\\s+"([^"\\r\\n]+\\.inc)"')
	var paths := PackedStringArray(WORKER_SOURCES)
	var native_source_dir := "gdext/src"
	# Separate translation units are not reachable through the fragment includes.
	for file_name in DirAccess.get_files_at(project_root.path_join(native_source_dir)):
		if file_name.begins_with("runtime_climate_passes_") and file_name.get_extension() in ["cpp", "h"]:
			paths.append(native_source_dir.path_join(file_name))
	var index := 0
	while index < paths.size():
		var relative_path := paths[index]
		index += 1
		var absolute_path := project_root.path_join(relative_path)
		var source := FileAccess.get_file_as_string(absolute_path)
		if source.is_empty():
			_fail("worker source missing: %s" % absolute_path)
			continue
		var code := _strip_comments(source)
		for match_result in fragments.search_all(code):
			var fragment := relative_path.get_base_dir().path_join(match_result.get_string(1)).simplify_path()
			if not paths.has(fragment):
				paths.append(fragment)
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
