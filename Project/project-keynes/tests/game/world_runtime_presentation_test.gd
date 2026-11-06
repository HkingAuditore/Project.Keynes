extends SceneTree

const Adapter = preload("res://scripts/game/world_runtime_presentation.gd")
const Reference = preload("res://tests/game/world_runtime_presentation_reference.gd")
const Overlay = preload("res://scripts/game/world_runtime_overlay.gd")
const OverlayReference = preload("res://tests/game/world_runtime_overlay_reference.gd")
var failures := 0
var checks := 0

class Feed extends RefCounted:
	var requested := PackedInt32Array()
	func get_building_visual_snapshot(_cells: PackedInt32Array) -> Dictionary:
		return {"ok": true}
	func consume_building_visual_dirty_cells() -> Dictionary:
		return {"dirty_cells": PackedInt32Array([1, 2, 2])}
	func consume_country_visual_era_dirty_slots() -> Dictionary:
		return {"country_slots": PackedInt32Array([3])}

class Catalog extends RefCounted:
	func building_visual_catalog() -> Dictionary:
		return {"building_type_ids": PackedStringArray(["probe"])}

class Generator extends RefCounted:
	var feed := Feed.new()
	var catalog := Catalog.new()
	func get_data_core_world_ext() -> Object: return feed
	func get_economy_facade() -> Object: return catalog

class Intel extends BuildingVisualIntelCache:
	var requests: Array = []
	var succeed := true
	var known := PackedInt32Array([0, 1])
	func known_cells() -> PackedInt32Array: return known
	func refresh_visible_cells(_ext: Object, cells: PackedInt32Array, visible: PackedByteArray) -> Dictionary:
		requests.append([cells, visible])
		return {"ok": succeed, "changed_cells": PackedInt32Array([1])}

class Renderer extends Node:
	var updates: Array = []
	func update_building_visual_intel(_intel: Object, cells: PackedInt32Array) -> void:
		updates.append(cells)
	func building_visual_diagnostics() -> Dictionary: return {}

class OverlayRenderer extends RefCounted:
	var filters: Array = []
	func set_resource_visual_filter(value: String) -> void: filters.append(value)

class OverlayLayer extends RefCounted:
	var hidden := 0
	func hide_animated() -> void: hidden += 1

class ProcessRequests extends RefCounted:
	var calls: Array = []
	func record(enabled: bool) -> void: calls.append(enabled)

func _compare_overlay() -> void:
	var previous := OverlayReference.new()
	var current := Overlay.new()
	var renderers: Array = []
	var layers: Array = []
	var processes: Array = []
	for object in [previous, current]:
		var renderer := OverlayRenderer.new()
		var layer := OverlayLayer.new()
		var process := ProcessRequests.new()
		renderers.append(renderer)
		layers.append(layer)
		processes.append(process)
		object._renderer = renderer
		object._map_overlay_layer = layer
		object._process_request = process.record
	for request in [{}, {"mode": OverlayMode.MODE.RESOURCE_RESERVE, "resource_id": "iron"},
			{"mode": OverlayMode.MODE.BIO_OCCUPANCY, "signal_id": "missing"},
			{"mode": OverlayMode.MODE.RESOURCE_RESERVE, "resource_id": "grain"}]:
		previous.set_map_overlay(request)
		current.set_map_overlay(request)
		previous.mark_map_overlay_dirty()
		current.mark_map_overlay_dirty()
		_check("overlay ordered diagnostics", previous.map_overlay_diagnostics() == current.map_overlay_diagnostics())
		_check("overlay renderer filter order", renderers[0].filters == renderers[1].filters)
		_check("overlay process request order", processes[0].calls == processes[1].calls)
		_check("overlay hide count", layers[0].hidden == layers[1].hidden)
	for duration in [0.0, 1.0, 10.0, 100.0]:
		previous._map_overlay_last_bake_ms = duration
		current._map_overlay_last_bake_ms = duration
		_check("overlay adaptive interval", previous._map_overlay_refresh_interval_msec() == current._map_overlay_refresh_interval_msec())
	previous.clear_map_overlay()
	current.clear_map_overlay()
	_check("overlay clear", previous.map_overlay_diagnostics() == current.map_overlay_diagnostics())
	current.release_resources()
	_check("overlay releases references", current._renderer == null and current._map_overlay_layer == null and not current._process_request.is_valid() and current._map_overlay_tex == null)

func _init() -> void:
	_compare_overlay()
	for fog in [false, true]:
		for force in [false, true]:
			for success in [false, true]:
				_compare(fog, force, success)
	var adapter := Adapter.new()
	_check("unbound reports unavailable", adapter._refresh_building_visual_intel({}) == {"ok": false, "reason": "building_visual_world_unavailable"})
	adapter._bind_settlement_labels()
	_check("unbound labels are absent", adapter._settlement_label_layer == null)
	var host := WorldRuntimeHost.new()
	_check("host preserves unavailable result", host._refresh_building_visual_intel({}) == adapter._refresh_building_visual_intel({}))
	_check("host exposes same cache", host.building_visual_intel_cache() == host._presentation._building_visual_intel)
	host._building_visual_force_full_refresh = true
	_check("host flag forwards", host._presentation._building_visual_force_full_refresh)
	host._presentation._building_visual_type_count = 7
	_check("host type count forwards", host.building_visual_type_count() == 7)
	host.free()
	print("host presentation: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _compare(fog: bool, force: bool, success: bool) -> void:
	var old := Reference.new()
	var current := Adapter.new()
	var map := MapData.new(3, 1)
	map.visible_arr = PackedByteArray([1, 0, 1])
	map.country_slot_arr = PackedInt32Array([3, 3, 4])
	var renderers: Array = []
	for object in [old, current]:
		var generator := Generator.new()
		var renderer := Renderer.new()
		renderers.append(renderer)
		if object == current:
			object.bind_resources(map, generator, renderer, null, fog, 22.0, 50.0)
		else:
			object._current_map = map
			object._generator = generator
			object._renderer = renderer
			object._fog_of_war_enabled = fog
		object._building_visual_intel = Intel.new()
		object._building_visual_intel.succeed = success
		object._building_visual_force_full_refresh = force
	var input := {"newly_visible_cells": PackedInt32Array([2, 0])}
	_check("old/new result", old._refresh_building_visual_intel(input) == current._refresh_building_visual_intel(input))
	_check("old/new ordered requests and visibility", old._building_visual_intel.requests == current._building_visual_intel.requests)
	_check("old/new renderer updates", renderers[0].updates == renderers[1].updates)
	_check("old/new force flag", old._building_visual_force_full_refresh == current._building_visual_force_full_refresh)
	_check("old/new diagnostic flag", old._building_visual_diag_logged == current._building_visual_diag_logged)
	_check("old/new catalog count", old._building_visual_type_count == current._building_visual_type_count)
	var generator_ref: WeakRef = weakref(current._generator)
	current.release_resources()
	_check("explicitly releases borrowed resources", current._current_map == null and current._renderer == null and current._camera == null and generator_ref.get_ref() == null)
	for renderer in renderers: renderer.free()

func _check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)
