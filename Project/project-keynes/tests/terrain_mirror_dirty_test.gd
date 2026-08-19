extends SceneTree

# Headless:
#   godot --headless --path <proj> --script res://tests/terrain_mirror_dirty_test.gd

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	print("=== terrain mirror dirty: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var gen := MapGenerator.new()
	_expect("bind/open starts with a dirty terrain mirror",
		bool(gen._dc_terrain_mirror_dirty))
	gen._dc_terrain_mirror_dirty = false
	var skipped: Dictionary = gen._sync_data_core_runtime_terrain_mirror(null, "test_clean")
	_expect("clean mirror returns immediately",
		bool(skipped.get("skipped", false)) and not bool(skipped.get("terrain_written", true)))
	_expect("clean skip leaves the dirty flag clear",
		not bool(gen._dc_terrain_mirror_dirty))
	gen.mark_runtime_terrain_mirror_dirty()
	_expect("MapData-only terrain writes can mark the mirror dirty",
		bool(gen._dc_terrain_mirror_dirty))
	var dirty: Dictionary = gen._sync_data_core_runtime_terrain_mirror(null, "test_dirty")
	_expect("dirty mirror does not take the skip path",
		not bool(dirty.get("skipped", true)))


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures += 1
