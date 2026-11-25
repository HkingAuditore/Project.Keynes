extends SceneTree

const Presentation = preload("res://scripts/game/world_runtime_presentation.gd")
var failures: Array[String] = []


class ReadHost extends WorldRuntimeHost:
	var reads := 0

	func _consume_runtime_commit_if_ready(_report: Dictionary = {}) -> void:
		reads += 1


class MilitaryReads extends Node:
	var reads := 0

	func poll_snapshot() -> void:
		reads += 1


class AnnualReads extends AnnualReportSession:
	var reads := 0

	func poll() -> void:
		reads += 1


class CountingUI extends GameUIManager:
	var refreshes := 0

	func refresh_country_summary() -> Dictionary:
		refreshes += 1
		return {"ran": true}


func _init() -> void:
	var host := WorldRuntimeHost.new()
	var scene := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var target := scene.get_node_or_null("MapViewport")
	check(target is SubViewport and target.has_method("bind_map"), "map has its own draw target")
	check(scene.get_node("UI").get_parent() == scene, "UI stays in the window")
	check(host.has_signal("simulation_ui_updated"), "UI has an independent delivery")
	if "publication_reader" in host:
		check_reader(host.get("publication_reader"))
	else:
		check(false, "publication reader can run on a real-time schedule")
	var presentation = Presentation.new()
	if presentation.has_method("publish_ui_view"):
		check_delivery(presentation)
		check_country_panel(presentation)
	check_paused_reader()
	check_drawn_vision()
	scene.free()
	host.free()
	for failure in failures:
		printerr(failure)
	print("independent presentation: ", failures.size(), " failures")
	quit(0 if failures.is_empty() else 1)


func check_reader(reader) -> void:
	check(reader.due(0) and reader.due(1), "default polls each process")
	reader.interval_usec = 100000
	check(reader.due(25), "first timed read is immediate")
	check(not reader.due(100024) and reader.due(100025), "timed read follows real time")
	check(reader.due(461000) and not reader.due(461001), "late frame reads one batch")
	check(reader.due(500025), "late frame preserves the original phase")
	reader.reset()
	check(reader.due(50), "new session starts with a fresh read")


func check_delivery(presentation) -> void:
	var ui: Array = []
	var map: Array = []
	var send_ui := func(a, b, c): ui.append([a, b, c])
	var send_map := func(a, b, c): map.append([a, b, c])
	presentation.queue_worker_commit(0, 1, 6, {"display_dirty_cells": PackedInt32Array([1])})
	presentation.publish_worker_view(send_map)
	presentation.publish_ui_view(send_ui)
	check(map.is_empty() and ui == [[0, 1, 6]], "pending map does not block UI")
	presentation.ui_refresh_enabled = false
	presentation.queue_worker_commit(1, 3, 8, {"display_dirty_cells": PackedInt32Array([2])})
	presentation.apply_pending_worker_map(PackedInt32Array(), func(_update, _day, _now): return true)
	presentation.publish_worker_view(send_map)
	presentation.publish_ui_view(send_ui)
	check(map == [[0, 3, 8]] and ui.size() == 1, "holding UI does not block map")
	presentation.queue_worker_commit(3, 4, 9)
	presentation.ui_refresh_enabled = true
	presentation.publish_ui_view(send_ui)
	presentation.publish_ui_view(send_ui)
	check(ui == [[0, 1, 6], [1, 4, 9]], "UI receives the pending range exactly once")
	presentation.queue_worker_commit(4, 5, 10)
	presentation.reset_worker_views()
	presentation.publish_ui_view(send_ui)
	check(ui.size() == 2, "reset discards old-world updates")


func check_paused_reader() -> void:
	var host := ReadHost.new()
	var military := MilitaryReads.new()
	var annual := AnnualReads.new()
	var clock := WorldClock.new()
	clock.pause(true)
	host._world_clock = clock
	host.military_map_layers = military
	host._annual_reports = annual
	host.publication_reader.interval_usec = 100000
	for usec in [50, 50000, 100049, 100050, 350051]:
		host._service_runtime_progress(usec)
	check(host.reads == 3 and military.reads == 3 and clock.paused,
		"paused host and military share the publication schedule")
	check(annual.reads == 3, "annual report notifications follow the paused publication schedule")
	host._presentation.ui_refresh_enabled = false
	host._runtime_commit_day = 3
	host._presentation.queue_worker_commit(0, 3, 1)
	host._presentation.publish_ui_view(host.simulation_ui_updated.emit)
	check(host.ui_worker_day() == 0, "a first held UI batch keeps the initial date")
	host._presentation.ui_refresh_enabled = true
	host._presentation.publish_ui_view(host.simulation_ui_updated.emit)
	check(host.ui_worker_day() == 3, "the first UI delivery advances the date")
	host.free()
	military.free()
	clock.free()


func check_country_panel(presentation) -> void:
	var ui := CountingUI.new()
	ui._country_panel = CountryPanel.new()
	ui.publication_views = presentation
	for event_driven in [true, false]:
		ui._country_ui_event_refresh_enabled = event_driven
		ui._country_next_refresh_ms = 0
		var before := ui.refreshes
		presentation.ui_refresh_enabled = false
		for tick in 2:
			ui._mark_country_panel_dirty(ui.COUNTRY_DIRTY_ALL, "settled")
			if event_driven:
				ui._country_next_refresh_ms = 0
				ui._flush_country_panel_refresh()
		check(ui.refreshes == before, "held country panel keeps its displayed model")
		presentation.ui_refresh_enabled = true
		presentation.publish_ui_view(func(_from, _day, _generation): pass)
		check(ui.refreshes == before + 1, "country panel receives one pending refresh while paused")
	var last_refresh := ui.refreshes
	presentation.ui_refresh_enabled = false
	ui._mark_country_panel_dirty(ui.COUNTRY_DIRTY_ALL, "settled")
	presentation.reset_worker_views()
	presentation.ui_refresh_enabled = true
	presentation.publish_ui_view(func(_from, _day, _generation): pass)
	check(ui.refreshes == last_refresh, "reset discards the previous world's panel refresh")
	ui._mark_country_panel_dirty(ui.COUNTRY_DIRTY_ALL, "settled")
	check(ui.refreshes == last_refresh + 1, "a new publication refreshes the panel after reset")
	ui._country_panel.free()
	ui.free()


func check_drawn_vision() -> void:
	var map := MapData.new(2, 1)
	var camera := MapCamera.new()
	var frame := preload("res://scripts/rendering/map_drawn_frame.gd").new()
	frame.attach(map)
	map.visible_arr = PackedByteArray([1, 0])
	map.explored_arr = PackedByteArray([1, 1])
	frame.received_day = 1
	frame.staged_day = 1
	frame.stage_vision(1, map.visible_arr, map.explored_arr)
	frame.submit(Transform2D.IDENTITY, Vector2(80, 40))
	map.visible_arr = PackedByteArray([0, 1])
	frame.stage_vision(2, map.visible_arr, map.explored_arr)
	check(not VisionSolver.displayed_cell_visible(map, 0), "no cell knowledge before the first map draw")
	check(VisionSolver.displayed_fog_state(map, 0) != VisionSolver.FOG_UNEXPLORED, "a pending frame is distinct from an unexplored cell")
	frame.present()
	check(VisionSolver.displayed_cell_visible(map, 0) and not VisionSolver.displayed_cell_visible(map, 1),
		"a newer same-day vision publication cannot change a submitted frame")
	check(not frame.fields_current(2), "same-day pending vision holds live cell queries")
	frame.submit(Transform2D.IDENTITY, Vector2(80, 40))
	frame.present()
	check(frame.fields_current(2) and VisionSolver.displayed_cell_visible(map, 1),
		"visible cells advance together with the displayed map")
	var target := preload("res://scripts/rendering/player_map_viewport.gd").new()
	target._camera = camera
	target.bind_map(map, 0)
	if DisplayServer.get_name() == "headless":
		check(camera.drawn_frame == null and target._map == null, "headless world has no draw dependency")
	frame.detach(map)
	target.free()
	camera.free()


func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
