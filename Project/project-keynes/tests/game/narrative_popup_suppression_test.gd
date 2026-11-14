extends SceneTree

const Flow = preload("res://scripts/narrative/narrative_event_flow.gd")
const Service = preload("res://scripts/narrative/narrative_event_service.gd")
const Catalog = preload("res://scripts/narrative/narrative_event_catalog.gd")

var failures := 0
var checks := 0

class ControllerStub extends Node:
	var service
	var flow
	var busy := false
	func era_reward_locked() -> bool: return busy
	func family_founding_locked() -> bool: return false
	func ideology_draw_phase() -> String: return ""
	func sync_ui() -> void: flow.try_present()
	func clear_cell_highlights() -> void: pass
	func request_command(_id: StringName, args: Dictionary) -> Dictionary:
		return service.choose_option(args.offer_id, args.offer_generation, args.option_index, 21)

class UiStub extends RefCounted:
	var opened := 0
	var is_open := false
	func show_narrative_event_offer(_offer: Dictionary) -> void:
		opened += 1
		is_open = true
	func close_narrative_event_offer() -> void: is_open = false
	func is_narrative_event_modal_open() -> bool: return is_open

func _init() -> void:
	call_deferred("_run")

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _enqueue(service, catalog) -> void:
	service.enqueue_event_offer(catalog.get_event(&"evt.climate.severe_drought"),
		3, 20, &"", true, {"cell_idx": 3, "population": 40})

func _run() -> void:
	for initial_paused in [false, true]:
		var clock := WorldClock.new()
		clock.set_speed(50.0)
		clock.pause(initial_paused)
		var catalog = Catalog.build_default_catalog()
		var service = Service.new()
		service.configure(null, null, null, clock, 1, 877972513, catalog)
		var controller := ControllerStub.new()
		controller.service = service
		var ui := UiStub.new()
		var flow = Flow.new()
		controller.flow = flow
		flow.configure(controller, null, clock, ui, service)
		flow.set_popups_suppressed(true)
		for event_index in range(3):
			_enqueue(service, catalog)
			flow.try_present()
			_expect("suppressed event preserves clock mode and speed",
				clock.paused == initial_paused and clock.speed_multiplier == 50.0)
		_expect("suppressed events resolve without modal or residual lock",
			service.chronicle_total_count() == 3 and ui.opened == 0
			and not flow.is_locked() and not flow.capture().restore_pending)
		flow.on_outcome_acknowledged()
		_expect("duplicate acknowledgement leaves clock untouched",
			clock.paused == initial_paused and clock.speed_multiplier == 50.0)
		# A normally opened event owns a real clock snapshot. Suppression must release it.
		flow.set_popups_suppressed(false)
		_enqueue(service, catalog)
		_expect("normal event pauses and displays modal", clock.paused and flow.is_locked() and ui.is_open)
		flow.set_popups_suppressed(true)
		controller.busy = true
		flow.try_present()
		_expect("another modal delays restoration", clock.paused and flow.capture().restore_pending)
		controller.busy = false
		flow.try_present()
		_expect("suppression restores acquired pause once busy ends",
			clock.paused == initial_paused and clock.speed_multiplier == 50.0
			and not flow.capture().restore_pending and not ui.is_open)
		clock.set_speed(10.0)
		_enqueue(service, catalog)
		flow.try_present()
		_expect("later suppressed event cannot replay previous speed", clock.speed_multiplier == 10.0)
		flow.set_popups_suppressed(false)
		_enqueue(service, catalog)
		var offer: Dictionary = service.active_offer()
		flow.on_option_chosen(offer.offer_id, offer.offer_generation, 0)
		_expect("normal event completion restores running clock",
			not clock.paused and clock.speed_multiplier == 10.0 and not flow.is_locked())
		# A restored open modal must release the persisted pre-modal snapshot as well.
		flow.restore({"locked": true, "was_paused": initial_paused, "previous_speed": 5.0})
		flow.set_popups_suppressed(true)
		flow.try_present()
		_expect("suppression releases restored modal pause",
			clock.paused == initial_paused and clock.speed_multiplier == 5.0
			and not flow.capture().locked and not flow.capture().restore_pending)
		clock.latch_authority_fault_hold()
		_enqueue(service, catalog)
		flow.try_present()
		_expect("automatic acknowledgement preserves authority fault hold",
			clock.paused and clock.authority_fault_hold and clock.speed_multiplier == 5.0)
		controller.flow = null
		controller.free()
		clock.free()
	print("narrative_popup_suppression_test: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
