extends SceneTree

## Exercise the real session service through its Country/Economy ports. The
## stubs own replies and record commands; conditions/orders are never mocked.
const Service = preload("res://scripts/era/era_advancement_service.gd")
const Rules = preload("res://scripts/era/era_advancement_catalog.gd")
## Gate derived from the rule so a ratio retune does not silently desync the test.
const TECH_GATE := int(ceil(10.0 * Rules.TECH_COMPLETION_RATIO))

class CountryPort extends RefCounted:
	var era := 0
	var territory := 10
	var catalog: Dictionary
	var states := PackedInt32Array()
	var stock := {}
	var reward := "NONE"
	var grants: Array = []
	var advances: Array = []
	func current_era_index(_handle: int) -> int: return era
	func snapshot(_handle: int) -> Dictionary: return {"territory_count": territory}
	func native_catalog() -> Dictionary: return catalog
	func research_snapshot(_handle: int) -> Dictionary: return {"technology_states": states}
	func treasury_snapshot(_handle: int) -> Dictionary:
		var ids := PackedStringArray()
		var quantities := PackedInt64Array()
		for id in stock:
			ids.append(id)
			quantities.append(stock[id])
		return {"good_ids": ids, "quantities": quantities}
	func era_reward_offer() -> Dictionary: return {"ok": true, "status": reward}
	func grant_technology(handle: int, id: StringName, day: int, sequence: int) -> Dictionary:
		grants.append([handle, id, day, sequence])
		states[catalog.technology_ids.find(String(id))] = 4
		return {"ok": true}
	func advance_era(handle: int, id: StringName, indices: PackedInt32Array,
			quantities: PackedInt64Array, day: int, sequence: int) -> Dictionary:
		advances.append([handle, id, indices.duplicate(), quantities.duplicate(), day, sequence])
		return {"ok": true}

class EconomyPort extends RefCounted:
	var population := 2000000
	var buildings := 2000000
	var orders := 0
	var available := true
	var targets: Array = []
	func good_ids() -> PackedStringArray: return Rules.all_good_ids()
	func good_display_name(index: int) -> String: return good_ids()[index]
	func country_economy_overview(_handle: int, _detail: String) -> Dictionary:
		return {"ok": true, "population": population, "building_units": buildings}
	func country_procurement_snapshot(_handle: int) -> Dictionary:
		return {"ok": available, "trade_orders_total": orders}
	func set_era_procurement_target(handle: int, active: bool, ids: PackedInt32Array,
			quantities: PackedInt64Array, day: int, sequence: int) -> Dictionary:
		targets.append([handle, active, ids.duplicate(), quantities.duplicate(), day, sequence])
		return {"ok": true}
	func set_country_procurement_policy(_handle: int, _enabled: bool, _share: int,
			_research: int, _day: int, _sequence: int, _era: int, _colonization: int) -> Dictionary:
		return {"ok": true}

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_check_ten_eras()
	_check_orders_and_restore()
	_check_completion()
	_check_trade_observations()
	print("era advancement service: %d checks, %d failures" % [checks, failures])
	call_deferred("quit", 0 if failures == 0 else 1)

func _fixture(era: int = 0) -> Dictionary:
	var country := CountryPort.new()
	country.era = era
	var ids := PackedStringArray()
	var eras := PackedStringArray()
	var flags := PackedInt32Array()
	var order := PackedStringArray()
	for index in range(11):
		var era_id: String = Rules.era_id(index)
		order.append(era_id)
		for tech in range(10):
			ids.append("fixture.%d.%d" % [index, tech])
			eras.append(era_id)
			flags.append(0)
		ids.append(String(Rules.milestone_id(index)))
		eras.append(era_id)
		flags.append(2)
	ids.append("app.fixture") # Intersections never count as research progress.
	eras.append(Rules.era_id(era))
	flags.append(0)
	country.catalog = {"technology_ids": ids, "technology_era_ids": eras,
		"technology_flags": flags, "technology_era_ids_ordered": order}
	country.states.resize(ids.size())
	for index in range(TECH_GATE): country.states[era * 11 + index] = 5
	var economy := EconomyPort.new()
	var service := Service.new()
	service.bind(country, economy, 77)
	service.refresh(0)
	return {"service": service, "country": country, "economy": economy}

func _row(model: Dictionary, key: String) -> Dictionary:
	for row in model.conditions:
		if row.key == key: return row
	return {}

func _check_ten_eras() -> void:
	for target in range(1, 11):
		var f := _fixture(target - 1)
		var service = f.service
		var model: Dictionary = service.preview()
		_expect("era %d has ten eligible technologies and a %d-tech gate" % [target, TECH_GATE],
			_row(model, "tech").target == TECH_GATE and _row(model, "tech").current == TECH_GATE
			and _row(model, "tech").mandatory)
		_expect("era %d uses the reviewed national gates at ten cells" % target,
			_row(model, "population").target == Rules.population_threshold(target, 10)
			and _row(model, "buildings").target == Rules.building_threshold(target, 10)
			and _row(model, "trade").target == Rules.trade_order_threshold(target, 10))
		f.country.territory = 1
		var small: Dictionary = service.preview()
		f.country.territory = 2
		var large: Dictionary = service.preview()
		for key in ["population", "buildings", "trade"]:
			_expect("each additional cell raises %s in era %d" % [key, target],
				_row(large, key).target > _row(small, key).target)
		for index in small.costs.size():
			_expect("each additional cell raises the procurement basket",
				large.costs[index].required > small.costs[index].required)
		f.country.territory = 10
		f.economy.population = Rules.population_threshold(target, 10)
		f.economy.buildings = Rules.building_threshold(target, 10) - 1
		_expect("one economic gate is insufficient at its boundary", not service.preview().can_start)
		f.economy.buildings += 1
		_expect("technology plus two exact economic gates unlocks advancement", service.preview().can_start)
		f.country.states[(target - 1) * 11 + TECH_GATE - 1] = 0
		f.economy.orders = Rules.trade_order_threshold(target, 10)
		service.refresh(1)
		_expect("all three economic gates cannot substitute for required technology",
			service.preview().status == Service.STATUS_LOCKED
			and not service.start(2, 1).ok and f.economy.targets.is_empty())

func _check_orders_and_restore() -> void:
	var f := _fixture()
	var service = f.service
	_expect("ready first-era purchase is accepted", service.start(2, 100).ok)
	var procurement := Rules.procurement_goods(1)
	var expected_ids := PackedStringArray()
	var expected := PackedInt64Array()
	for row_value in procurement:
		var row: Dictionary = row_value
		expected_ids.append(String(row.good_id))
		expected.append(Rules.required_quantity(row, 10))
	var sent: Array = f.economy.targets[0]
	_expect("the real procurement port receives the catalog procurement basket",
		sent[0] == 77 and sent[1] and sent[3] == expected and sent[4] == 2 and sent[5] == 100)
	var names := PackedStringArray()
	for index in sent[2]: names.append(f.economy.good_ids()[index])
	_expect("goods indices correspond to the frozen authored basket", names == expected_ids)
	_expect("first purchase grants the stone prelude once", f.country.grants.size() == 1
		and f.country.grants[0][1] == Rules.milestone_id(0))
	f.country.territory = 20
	_expect("pause disables new buying without erasing the frozen order", service.pause(3, 101).ok)
	var saved: Dictionary = service.to_save()
	_expect("expansion and pause preserve the initial purchase requirements",
		saved.frozen_territory == 10 and saved.required_good_ids == expected_ids
		and saved.required_quantities == expected)
	var restored := Service.new()
	restored.restore(saved)
	restored.bind(f.country, f.economy, 77)
	_expect("restore before first bind preserves the paused purchase",
		restored.preview().status == Service.STATUS_PAUSED
		and restored.to_save().required_quantities == expected)
	_expect("resume sends the saved quantities after expansion", restored.resume(4, 102).ok
		and f.economy.targets[-1][3] == expected and f.country.grants.size() == 1)
	var old_order := saved.duplicate(true)
	old_order.required_quantities = PackedInt64Array([12, 18, 9])
	restored.restore(old_order)
	_expect("an older started order is honored without recalculating current prices",
		restored.resume(5, 103).ok and f.economy.targets[-1][3] == PackedInt64Array([12, 18, 9]))
	restored.bind(CountryPort.new(), EconomyPort.new(), 78)
	_expect("binding a different world clears the previous frozen order",
		restored.to_save().phase.is_empty() and restored.to_save().required_good_ids.is_empty())

func _check_completion() -> void:
	var f := _fixture()
	var service = f.service
	service.start(2, 1)
	var saved: Dictionary = service.to_save()
	for index in saved.required_good_ids.size():
		f.country.stock[saved.required_good_ids[index]] = saved.required_quantities[index]
	f.country.states[f.country.catalog.technology_ids.find(String(Rules.milestone_id(0)))] = 5
	f.country.stock.logs -= 1
	service.refresh(2)
	_expect("one fixed-point unit short never submits a completion", f.country.advances.is_empty())
	f.country.stock.logs += 1
	f.country.reward = "OPEN"
	service.refresh(3)
	_expect("the prior era reward must settle before another milestone", f.country.advances.is_empty())
	f.country.reward = "NONE"
	service.refresh(4)
	_expect("exact stock submits one atomic Country completion", f.country.advances.size() == 1
		and f.country.advances[0][1] == Rules.milestone_id(1)
		and f.country.advances[0][3] == saved.required_quantities
		and service.preview().status == Service.STATUS_COMPLETING)
	service.refresh(4, true)
	service.refresh(4, true)
	_expect("same-day UI refreshes do not repeat a completion", f.country.advances.size() == 1)
	var events: Array = []
	service.era_advanced.connect(func(old: int, next: int, _buffs: PackedStringArray): events.append([old, next]))
	f.country.era = 1
	service.refresh(5)
	service.refresh(5, true)
	_expect("the committed era releases the order and announces the change once",
		service.to_save().phase.is_empty() and events == [[0, 1]])

func _check_trade_observations() -> void:
	var f := _fixture()
	f.economy.orders = 10
	f.service.refresh(1)
	var saved: Dictionary = f.service.to_save()
	_expect("the service records only newly observed orders", saved.trade_accumulated == 10)
	f.service.restore(saved)
	f.economy.orders = 100
	f.service.refresh(2)
	_expect("the first restored counter is a baseline", f.service.to_save().trade_accumulated == 10)
	f.economy.orders = 105
	f.service.refresh(3)
	f.economy.available = false
	f.service.refresh(4)
	f.economy.available = true
	f.economy.orders = 108
	f.service.refresh(5)
	_expect("a temporarily unavailable read never invents trade orders",
		f.service.to_save().trade_accumulated == 18)

func _expect(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label)
