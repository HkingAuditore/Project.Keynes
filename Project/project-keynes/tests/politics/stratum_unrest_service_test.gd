extends SceneTree

## Service-level coverage for the rebellion bridge without a full world:
## option resolution, concession payment, and the independence -> war sequence.

const ServiceScript = preload("res://scripts/politics/stratum_unrest_service.gd")
const ContentScript = preload("res://scripts/politics/stratum_rebellion_content.gd")

var _checks := 0
var _failures := 0


class MockClock:
	var paused := true


class MockEconomy:
	var applied: Array = []
	var payments: Array = []
	func is_configured() -> bool: return true
	func mobilization_odds(_cell: int, _prof: int, _action: int, _spend: int) -> Dictionary:
		return {"ok": true, "p_success_q16": 40000, "cost_bp": 50}
	func apply_mobilization_result(cell: int, prof: int, action: int, success: bool) -> bool:
		applied.append([cell, prof, action, success])
		return true
	func settlement_display_name(_cell: int) -> String: return "测试城"
	func profession_ids() -> PackedStringArray: return PackedStringArray(["farmer"])
	func population_cell_snapshot(_cell: int, _details: bool) -> Dictionary:
		return {"handles": PackedInt64Array([77]), "populations": PackedInt64Array([100])}
	func transfer_country_cash_to_cohort(_country: int, cohort: int, amount: int,
			_day: int, _seq: int) -> Dictionary:
		payments.append([cohort, amount])
		return {"ok": true}


class MockCountry:
	var handle := 1
	func cell_summary(_cell: int) -> Dictionary:
		return {"country_handle": handle, "territory_count": 2}
	func snapshot(_handle: int) -> Dictionary:
		return {"cash": 100000}
	func create_country(_stable_id: StringName, _name: String, _cell: int,
			_day: int, _seq: int) -> Dictionary:
		handle = 9
		return {"ok": true}


class MockMilitary:
	var wars: Array = []
	func cell_snapshot(_cell: int) -> Dictionary:
		return {"present": 0, "garrison": 0}
	func declare_war(country: int, target: int) -> Dictionary:
		wars.append([country, target])
		return {"ok": true}


func _init() -> void:
	_run()
	print("stratum unrest service: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var service = ServiceScript.new()
	var economy := MockEconomy.new()
	var country := MockCountry.new()
	var military := MockMilitary.new()
	service.configure(null, null, MockClock.new(), null, economy, country,
		military, 1, 12345)
	service.step_daily(9)
	var record := {
		"chosen_option_index": 0,
		"rolled_outcome_index": 0,
		"day": 9,
		"meta": {
			"kind": "rebellion", "cell": 5, "profession": 0, "stage": 4,
			"owner_handle": 1,
			"actions": [ContentScript.ACTION_ABANDON],
			"cost_bps": [0],
		},
	}
	service.on_offer_resolved(record)
	_expect("abandon applies as a successful action",
		economy.applied.size() == 1 and
		int(economy.applied[0][2]) == ContentScript.ACTION_ABANDON and
		bool(economy.applied[0][3]))
	_expect("abandon queues independence",
		service.export_state().get("pending_independence", []).size() == 1)
	service.step_daily(10)
	_expect("independence creates a country on the next day",
		country.handle == 9)
	service.step_daily(11)
	_expect("the old sovereign declares war once the split lands",
		military.wars.size() == 1 and int(military.wars[0][0]) == 1 and
		int(military.wars[0][1]) == 9)
	_expect("the independence queue drains after the war",
		service.export_state().get("pending_independence", []).is_empty())

	# A concession pays treasury cash to the local primary cohort.
	var paid := MockEconomy.new()
	var paid_service = ServiceScript.new()
	paid_service.configure(null, null, MockClock.new(), null, paid,
		MockCountry.new(), MockMilitary.new(), 1, 12345)
	paid_service.step_daily(1)
	paid_service.on_offer_resolved({
		"chosen_option_index": 0,
		"rolled_outcome_index": 0,
		"day": 1,
		"meta": {
			"kind": "rebellion", "cell": 5, "profession": 0, "stage": 1,
			"owner_handle": 1,
			"actions": [ContentScript.ACTION_CONCEDE],
			"cost_bps": [50],
		},
	})
	_expect("concession pays the primary cohort",
		paid.payments.size() == 1 and int(paid.payments[0][0]) == 77 and
		int(paid.payments[0][1]) == 500)
	_expect("concession still applies the native result",
		paid.applied.size() == 1 and
		int(paid.applied[0][2]) == ContentScript.ACTION_CONCEDE)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s" % label)
