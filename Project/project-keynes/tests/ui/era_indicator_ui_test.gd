extends SceneTree

const Catalog = preload("res://scripts/economy/technology_catalog.gd")
const VM = preload("res://scripts/ui/era_indicator_view_model.gd")
var failures := 0

class CountryReadStub extends RefCounted:
	func ui_snapshot(handle: int, mask: int) -> Dictionary:
		return {"ok": handle == 42 and mask == 0, "summary": {"country_name": "测试王国", "territory_count": 36}}
	func treasury_snapshot(handle: int) -> Dictionary:
		return {"ok": handle == 42, "cash": 1234560000}

class EconomyReadStub extends RefCounted:
	func country_economy_overview(handle: int, view: String) -> Dictionary:
		return {"ok": handle == 42 and view == "summary", "population": 6789}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.mode = Window.MODE_WINDOWED
	root.content_scale_size = Vector2i.ZERO
	var catalog: Dictionary = Catalog.compile_native_catalog()
	var milestones: PackedInt32Array = catalog.technology_era_milestone_indices
	var states := PackedInt32Array()
	states.resize(catalog.technology_ids.size())
	var progress := PackedInt64Array()
	progress.resize(states.size())
	var vm := VM.new()
	var ledger := EconomyGdpLedger.new()
	ledger.set("_has_sample", true)
	ledger.set("_national_ytd", 2345670000.0)
	var overview := vm.build_overview(CountryReadStub.new(), EconomyReadStub.new(), 42, ledger)
	_check("overview reads player summary and converts native currency units",
		overview.country_name == "测试王国" and overview.territory == "36"
		and overview.cash == UITokens.format_compact_number_cn(123456.0, 2)
		and overview.gdp == UITokens.format_compact_number_cn(234567.0, 2) and overview.population == "6789")
	var snapshot := {"technology_states": states, "technology_progress": progress,
		"queue_technology_indices": PackedInt32Array()}
	var model := vm.build(snapshot)
	_check("new country starts at stone", model.era_id == "stone" and not model.researching)
	states[milestones[0]] = 5
	states[milestones[1]] = 3
	progress[milestones[1]] = int(catalog.technology_costs[milestones[1]]) / 2
	snapshot = {"technology_states": states, "technology_progress": progress,
		"queue_technology_indices": PackedInt32Array([milestones[1]])}
	model = vm.build(snapshot)
	_check("queued milestone uses authoritative scaled cost", model.era_id == "stone"
		and model.researching and is_equal_approx(float(model.progress), 0.5))
	states[milestones[1]] = 4
	snapshot.technology_states = states
	model = vm.build(snapshot)
	_check("pending ACK fills progress without advancing era", model.era_id == "stone" and model.progress == 1.0)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	var bg := ColorRect.new()
	bg.color = Color(0.18, 0.23, 0.19)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(bg)
	var bar := load("res://scenes/ui/player_top_bar.tscn").instantiate() as Control
	host.add_child(bar)
	var badge := load("res://scenes/ui/era_indicator.tscn").instantiate() as EraIndicator
	host.add_child(badge)
	var flight := load("res://scenes/ui/era_transition_flight.tscn").instantiate() as EraTransitionFlight
	host.add_child(flight)
	var dialog := load("res://scenes/ui/era_reward_dialog.tscn").instantiate() as EraRewardDialog
	host.add_child(dialog)
	var manager := GameUIManager.new()
	manager.set("_top_bar", bar)
	manager.set("_era_indicator", badge)
	manager.set("_era_flight", flight)
	manager.set("_era_reward_dialog", dialog)
	badge.era_advanced.connect(manager._on_era_indicator_advanced)
	flight.landed.connect(manager._on_era_flight_landed)
	badge.pressed.connect(manager._on_era_indicator_pressed)
	dialog.dismiss_requested.connect(manager._on_era_popup_dismissed)
	await process_frame
	badge.set_model(model)
	(bar as PlayerTopBar).set_era_name(String(model.era_name))
	_check("initial bind never plays promotion", not badge.get("_celebrating"))
	var body := badge.get_node("Badge") as Control
	for dimensions in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		root.mode = Window.MODE_WINDOWED
		root.size = dimensions
		await create_timer(0.15).timeout
		_check("badge is top centered at %s" % dimensions,
			is_equal_approx(badge.global_position.x + 110.0, dimensions.x * 0.5)
			and is_equal_approx(body.global_position.y, -110.0))
		await _capture("collapsed_%dx%d" % [dimensions.x, dimensions.y])
	badge.get_node("Hit").emit_signal("mouse_entered")
	await create_timer(UITokens.ERA_BADGE_SLIDE_SECONDS + 0.06).timeout
	_check("hover only peeks and enlarges badge", is_equal_approx(body.position.y, UITokens.ERA_BADGE_HOVER_Y)
		and is_equal_approx(body.scale.x, UITokens.ERA_BADGE_HOVER_SCALE))
	_check("badge has no redundant era caption", badge.get_node_or_null("Badge/Status") == null)
	_check("hover hit region stays at screen edge while badge slides down",
		(badge.get_node("Hit") as Control).get_global_rect().has_point(Vector2(root.size.x * 0.5, 1.0)))
	badge.set_offer_available(true)
	await _capture("reward_hover")
	_check("reward reminder updates shader edge", bool((badge.get_node("Badge/Icon").material as ShaderMaterial).get_shader_parameter("reward_available")))
	badge.get_node("Hit").emit_signal("pressed")
	dialog.refresh_overview(overview)
	await create_timer(UITokens.ERA_BADGE_SLIDE_SECONDS + 0.06).timeout
	_check("click fully reveals badge and opens a four-metric overview",
		is_equal_approx(body.position.y, 10.0) and dialog.visible and not dialog.is_offer_open()
		and dialog.get_node("%Metrics").get_child_count() == 4)
	await _capture("country_overview")
	manager._on_era_popup_dismissed()
	badge.get_node("Hit").emit_signal("mouse_exited")
	await create_timer(0.2).timeout
	states[milestones[1]] = 5
	snapshot.technology_states = states
	model = vm.build(snapshot)
	_check("only ACK advances era", model.era_id == "agrarian" and not model.researching)
	badge.set_model(model)
	_check("live era advance starts ceremony", badge.get("_celebrating"))
	_check("advancement does not fully expand badge without click", body.position.y < 0.0 and not dialog.visible)
	_check("calendar retains old era during flight", (bar as PlayerTopBar).era_name_target().text == "石器时代")
	await create_timer(1.1).timeout
	await _capture("promotion")
	await create_timer(0.70).timeout
	_check("calendar changes only after light arrives", (bar as PlayerTopBar).era_name_target().text == "农耕时代")
	_check("landing clears pending label transfer", String(manager.get("_era_transfer_name")).is_empty())
	await _capture("calendar_arrival")
	await create_timer(1.2).timeout
	_check("ceremony finishes without a repeating effect", not badge.get("_celebrating"))
	manager.show_era_reward_offer({"offer_generation": 8, "alternatives": [
		{"icon_id": "industry", "title": "生产动员", "description": "制造业产出提高 10%，建设效率提高 5%。"},
		{"icon_id": "flask", "title": "广域科研", "description": "科研投入效率提高 12%。"},
		{"icon_id": "people", "title": "国家组织", "description": "行政效率提高 8%，国内流通效率提高 5%。"}]})
	dialog.refresh_overview(overview)
	for dimensions in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		root.mode = Window.MODE_WINDOWED
		root.size = dimensions
		await create_timer(0.3).timeout
		var popup := dialog.get_node("%Popup") as Control
		_check("compact overview and reward fit viewport %s" % dimensions,
			popup.get_global_rect().end.y <= dimensions.y - 8 and popup.size.x <= 600
			and is_equal_approx(popup.get_global_rect().get_center().x, dimensions.x * 0.5)
			and dialog.mouse_filter == Control.MOUSE_FILTER_IGNORE and dialog.is_offer_open())
		await _capture("compact_rewards_%dx%d" % [dimensions.x, dimensions.y])
	dialog.close_offer()
	_check("reward ACK removes choices but retains the overview", dialog.visible and not dialog.is_offer_open())
	manager._on_era_popup_dismissed()
	badge.reset_for_world()
	badge.set_model(model)
	_check("restore establishes baseline without replaying ceremony", not badge.get("_celebrating"))
	_check("world reset returns badge to half-hidden state", is_equal_approx(body.position.y, -110.0))
	host.queue_free()
	manager.free()
	await process_frame
	print("era_indicator_ui_test: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://test_output/era_indicator")
	root.get_texture().get_image().save_png("res://test_output/era_indicator/%s.png" % label)
	print("[capture] %s viewport=%s" % [label, root.get_texture().get_size()])

func _check(label: String, ok: bool) -> void:
	if ok:
		print("[PASS] " + label)
	else:
		failures += 1
		push_error("[FAIL] " + label)
