extends SceneTree

# Headless:
#   godot --headless --script tests/rift_emergence_test.gd --quit

const OLD_GLOBAL_CAP := 48

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("[rift-emergence] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[rift-emergence] SKIP DCWorldExt missing")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("DCWorldExt instantiated", ext != null)
	if ext == null:
		return

	# Zero local thresholds and a one-cell minimum deliberately create more than
	# the retired quota, while retaining the same local valley cross-section test.
	var post := _generate(ext, 20260731, {
		"rift_min_wall": 0.0,
		"rift_min_axis": 0.0,
		"rift_min_length_cells": 1,
	})
	_validate_uncapped(post)

	var natural := _generate(ext, 10086, {
		"rift_min_wall": 0.024,
		"rift_min_axis": 0.052,
		"rift_min_length_cells": 3,
	})
	_validate_accounting(natural)


func _generate(ext: Object, seed: int, rift_profile: Dictionary) -> Dictionary:
	var cfg := {
		"width": 120,
		"height": 100,
		"num_continents": 3,
		"sea_level": 0.42,
		"continent_size": 0.9,
	}
	var profile := {"native_generation_mode": 2}
	profile.merge(rift_profile, true)
	var base: Dictionary = ext.call("run_native_world_generate_base_pass", seed, cfg, profile)
	_expect("base succeeds seed=%d" % seed, int(base.get("rc", -1)) == 0)
	if int(base.get("rc", -1)) != 0:
		return {}
	return ext.call("run_native_world_generate_post_base_pass", seed, cfg, profile, base)


func _validate_uncapped(post: Dictionary) -> void:
	_validate_accounting(post)
	var selected := int(post.get("rift_valley_count", -1))
	_expect("selection exceeds retired global cap", selected > OLD_GLOBAL_CAP)


func _validate_accounting(post: Dictionary) -> void:
	_expect("post succeeds", int(post.get("rc", -1)) == 0)
	if int(post.get("rc", -1)) != 0:
		return
	var candidates := int(post.get("rift_candidate_count", -1))
	var rejected := int(post.get("rift_rejected_fragment_count", -1))
	var selected := int(post.get("rift_valley_count", -1))
	var components := int(post.get("rift_component_count", -1))
	var largest := int(post.get("rift_largest_component", -1))
	var stages: Dictionary = post.get("stage_counts", {})
	print("[rift-emergence] candidates=%d selected=%d rejected=%d components=%d largest=%d" % [
		candidates, selected, rejected, components, largest])
	_expect("candidate accounting closes", candidates == selected + rejected)
	_expect("stage count matches final selection", int(stages.get("rift_valley", -1)) == selected)
	_expect("component diagnostics are non-negative", components >= 0 and largest >= 0)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	push_error("[rift-emergence] FAIL: %s" % label)
