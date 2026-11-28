extends SceneTree

## Regression suite for Route A (static canopy stability & anti-flicker):
##   1. Canopy ShrubLayers (detail_kind 1, 3, 4) ignore daily succession axes
##      (0x01 veg, 0x02 landform, 0x04 cover) when static canopy mode is enabled,
##      eliminating position jumps and per-frame CPU rebuild spikes.
##   2. Canopy ShrubLayers still honour explicit 0x80 refreshes (settlement footprint
##      changes from BuildingVisualIntelCache).
##   3. Non-canopy layers (grass, shrub, rock) keep responding to succession.
##   4. Global dynamic budget throttling does not clip static canopy layers
##      (effective visible fraction stays 1.0), preventing camera-pan flicker.

const ShrubLayerScript = preload("res://scripts/rendering/shrub_layer.gd")
const DetailBudget = preload("res://scripts/rendering/renderer_detail_budget.gd")
const ChunkBudget = preload("res://scripts/rendering/shrub/chunk_budget.gd")
const ChunkNodes = preload("res://scripts/rendering/shrub/chunk_nodes.gd")
const TreeProfile = preload("res://data/visual/tree_default.tres")
const ConiferProfile = preload("res://data/visual/conifer_default.tres")
const PalmProfile = preload("res://data/visual/palm_default.tres")
const ShrubProfile = preload("res://data/visual/shrub_default.tres")
const GrassProfile = preload("res://data/visual/grass_default.tres")

var _passed := 0
var _failed := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		printerr("[FAIL] %s" % label)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_succession_gating()
	_test_budget_exemption()
	_test_no_eviction_and_stable_lod_count()
	print("static_canopy_stability_test: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _test_succession_gating() -> void:
	for prof in [TreeProfile, ConiferProfile, PalmProfile]:
		var layer := ShrubLayerScript.new()
		layer.profile = prof
		layer.set_static_canopy_enabled(true)
		_check(layer.is_static_canopy_layer(), "Profile detail_kind=%d recognized as static canopy" % int(prof.detail_kind))
		_check(not layer.detail_change_affects_profile(0x01, 7, 9, 0, 0, 0, 0),
			"Static canopy ignores daily vegetation succession (0x01)")
		_check(not layer.detail_change_affects_profile(0x02, 7, 7, 0, 1, 0, 0),
			"Static canopy ignores landform axis (0x02)")
		_check(not layer.detail_change_affects_profile(0x04, 7, 7, 0, 0, 0, 1),
			"Static canopy ignores cover axis (0x04)")
		_check(layer.detail_change_affects_profile(0x80, 0, 0, 0, 0, 0, 0),
			"Static canopy still honours explicit settlement/building refresh (0x80)")

		# Toggling off restores legacy succession responsiveness.
		layer.set_static_canopy_enabled(false)
		_check(not layer.is_static_canopy_layer(), "Disabling flag restores dynamic canopy mode")
		layer.free()

	for prof in [ShrubProfile, GrassProfile]:
		var layer := ShrubLayerScript.new()
		layer.profile = prof
		layer.set_static_canopy_enabled(true)
		_check(not layer.is_static_canopy_layer(),
			"Non-canopy detail_kind=%d is not treated as static canopy" % int(prof.detail_kind))
		layer.free()


class DummyBudgetLayer extends Node2D:
	var static_canopy: bool = false
	var last_fraction: float = -1.0

	func is_static_canopy_layer() -> bool:
		return static_canopy

	func apply_visible_instance_fraction(fraction: float) -> void:
		last_fraction = fraction


class DummyBudgetHost extends RefCounted:
	var detail_scatter_static_canopy_enabled: bool = true
	var _camera_world_rect: Rect2 = Rect2(0, 0, 1000, 1000)
	var _camera_zoom: float = 1.0
	var _pixel_world_size: float = 1.0
	var detail_scatter_rebuild_log_enabled: bool = false
	var _last_detail_budget_weighted_report: Dictionary = {}


func _test_budget_exemption() -> void:
	var host := DummyBudgetHost.new()
	var canopy := DummyBudgetLayer.new()
	canopy.static_canopy = true
	var grass := DummyBudgetLayer.new()
	grass.static_canopy = false

	DetailBudget._apply_detail_budget_to_layer(host, canopy, 0.35)
	DetailBudget._apply_detail_budget_to_layer(host, grass, 0.35)
	_check(is_equal_approx(canopy.last_fraction, 1.0),
		"Static canopy layer is exempt from global budget dilution (stays 1.0)")
	_check(is_equal_approx(grass.last_fraction, 0.35),
		"Non-canopy layer still receives global budget fraction (0.35)")

	host.detail_scatter_static_canopy_enabled = false
	DetailBudget._apply_detail_budget_to_layer(host, canopy, 0.35)
	_check(is_equal_approx(canopy.last_fraction, 0.35),
		"Disabling static canopy switch restores global budget throttling on canopy")

	canopy.free()
	grass.free()


func _test_no_eviction_and_stable_lod_count() -> void:
	var layer := ShrubLayerScript.new()
	layer.profile = TreeProfile
	layer.set_static_canopy_enabled(true)
	layer._family_batch_suppressed = false
	layer._lod_zoom_t = 0.0
	layer._shadow_fraction = 0.5
	_check(ChunkBudget._lod_visible_count(layer, 120, 40) == 120,
		"Static canopy keeps full visible count across zoom LOD (no zoom pop)")
	layer._chunk_cell_payloads[0] = {}
	_check(ChunkNodes.evict_dormant_detail_chunks(layer, 999999, 1000) == 0,
		"Static canopy chunks are never evicted after dormancy")
	layer.free()
