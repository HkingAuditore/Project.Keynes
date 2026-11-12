extends SceneTree

## Headless contract test for EraAdvancementService + EraAdvancementCatalog
## (docs/cpp-dots-runtime/era-advancement-runtime.md §3/§5/§6) using fake
## Country/Economy facades. Run:
##   godot --headless --path Project/project-keynes --script res://tests/era/era_advancement_service_test.gd

const ServiceScript = preload("res://scripts/era/era_advancement_service.gd")
const CatalogScript = preload("res://scripts/era/era_advancement_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

const HANDLE := 4294967297


class FakeCountry:
	extends RefCounted
	var catalog: Dictionary = {}
	var era := 0
	var territory := 4
	var goods := {}
	var states := PackedInt32Array()
	var offer_status := "NONE"
	var grants: Array = []
	var advances: Array = []
	var advance_ok := true

	func current_era_index(_handle: int) -> int:
		return era

	func snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "territory_count": territory}

	func treasury_snapshot(_handle: int) -> Dictionary:
		var ids := PackedStringArray()
		var quantities := PackedInt64Array()
		for key in goods:
			ids.append(String(key))
			quantities.append(int(goods[key]))
		return {"ok": true, "cash": 0, "good_ids": ids, "quantities": quantities}

	func research_snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "technology_states": states}

	func native_catalog() -> Dictionary:
		return catalog

	func era_reward_offer() -> Dictionary:
		return {"ok": true, "status": offer_status}

	func grant_technology(handle: int, technology_id: StringName, day: int,
			sequence: int) -> Dictionary:
		grants.append({"handle": handle, "id": technology_id, "day": day, "sequence": sequence})
		return {"ok": true}

	func advance_era(handle: int, milestone: StringName, indices: PackedInt32Array,
			quantities: PackedInt64Array, day: int, sequence: int) -> Dictionary:
		advances.append({"handle": handle, "milestone": milestone, "indices": indices,
			"quantities": quantities, "day": day, "sequence": sequence})
		return {"ok": advance_ok, "reason": "" if advance_ok else "country_treasury_goods_insufficient"}

	func set_state(technology_id: String, state: int) -> void:
		var index := (catalog.technology_ids as PackedStringArray).find(technology_id)
		states[index] = state


class FakeEconomy:
	extends RefCounted
	var ids := PackedStringArray()
	var population := 0
	var buildings := 0
	var trade_total := 0
	var targets: Array = []
	var policies: Array = []

	func good_ids() -> PackedStringArray:
		return ids

	func good_display_name(index: int) -> String:
		return "名称:%s" % ids[index]

	func country_economy_overview(_handle: int, view: String = "summary") -> Dictionary:
		return {"ok": true, "view": view, "population": population,
			"building_units": buildings}

	func country_procurement_snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "national_daily_budget": 1234, "era_daily_budget": 600,
			"trade_orders_total": trade_total}

	func set_era_procurement_target(handle: int, active: bool, indices: PackedInt32Array,
			quantities: PackedInt64Array, day: int, sequence: int) -> Dictionary:
		targets.append({"handle": handle, "active": active, "indices": indices,
			"quantities": quantities, "day": day, "sequence": sequence})
		return {"ok": true}

	func set_country_procurement_policy(handle: int, enabled: bool, treasury_bp: int,
			research_bp: int, day: int, sequence: int,
			era_bp: int = -1, colonization_bp: int = -1) -> Dictionary:
		policies.append({"handle": handle, "enabled": enabled, "treasury": treasury_bp,
			"research": research_bp, "day": day, "sequence": sequence,
			"era": era_bp, "colonization": colonization_bp})
		return {"ok": true}


var _failures := 0
var _sequence := 100
var _advanced: Array = []


func _next_sequence() -> int:
	_sequence += 1
	return _sequence


func _init() -> void:
	var technology: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	_expect("technology catalog compiles", bool(technology.get("ok", false)))
	var economy_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(economy_catalog.get("ok", false)))
	_check_catalog(technology, economy_catalog)

	var country := FakeCountry.new()
	country.catalog = technology
	country.states.resize((technology.technology_ids as PackedStringArray).size())
	var economy := FakeEconomy.new()
	economy.ids = economy_catalog.good_ids
	var service = ServiceScript.new()
	service.era_advanced.connect(func(old_index: int, new_index: int,
			buffs: PackedStringArray) -> void:
		_advanced.append([old_index, new_index, buffs]))
	_expect("first bind reports a new session",
		service.bind(country, economy, HANDLE, Callable(self, "_next_sequence")))
	_expect("rebinding the same session is not new",
		not service.bind(country, economy, HANDLE, Callable(self, "_next_sequence")))
	service.push_runtime_state(1)
	_expect("default policy pushed at session start",
		economy.policies.size() == 1 and int(economy.policies[0].treasury) == 200
		and int(economy.policies[0].research) == 5000 and bool(economy.policies[0].enabled))

	# --- 条件判定：科技为硬性条件 + 经济三项里满足两项 -------------------------
	# 门槛会随领土与时代变化，所以这里不写死人数/建筑数，而是直接读模型里的 target。
	economy.population = 0
	economy.buildings = 0
	var model: Dictionary = service.refresh(0)
	_check_snapshot_shape(model)
	_expect("no economy condition met keeps era locked",
		String(model.status) == "locked" and int(model.conditions_met) == 0
		and not bool(model.can_start) and int(model.next_era_index) == 1)
	_expect("start rejected while locked",
		String(service.start(1, _next_sequence()).code) == "era_advance_conditions_unmet")
	economy.population = int(_condition(model, "population").target)
	model = service.refresh(0, true)
	_expect("one economy condition met keeps era locked",
		String(model.status) == "locked" and int(model.conditions_met) == 1
		and not bool(model.can_start))
	economy.buildings = int(_condition(model, "buildings").target)
	model = service.refresh(0, true)
	_expect("two economy conditions still keep era locked (tech is mandatory)",
		String(model.status) == "locked" and int(model.conditions_met) == 2
		and not bool(model.can_start))
	var tech_row: Dictionary = _condition(model, "tech")
	_expect("tech condition counts non-milestone stone technologies",
		int(tech_row.target) > 0 and not bool(tech_row.met))
	_fill_tech_ratio(country, technology, 0, 0.62)
	model = service.refresh(0, true)
	_expect("62% stone technologies satisfies the 60% tech condition",
		bool(_condition(model, "tech").met))
	_expect("tech + two economy conditions make era ready",
		String(model.status) == "ready" and int(model.conditions_met) == 3 and bool(model.can_start))
	_expect("buff preview lists stone prelude and agrarian buffs",
		(model.buffs_preview as PackedStringArray).size() == 6)

	# --- trade counter --------------------------------------------------------
	# Day 0 sampled trade_orders_total = 0 as the session baseline.
	economy.trade_total = 10
	service.refresh(1)
	economy.trade_total = 25
	model = service.refresh(2)
	_expect("trade orders are counted from the session baseline",
		int(_condition(model, "trade").current) == 25)

	# --- start freezes territory and requirements -----------------------------
	var start: Dictionary = service.start(3, _next_sequence())
	_expect("start accepted", bool(start.ok) and String(start.code) == "era_advance_started")
	var target: Dictionary = economy.targets.back()
	var logs_index := (economy.ids as PackedStringArray).find("logs")
	_expect("start pushes an active era target", bool(target.active)
		and (target.indices as PackedInt32Array).size() == 3
		and int((target.indices as PackedInt32Array)[0]) == logs_index)
	# Derive the expectation from the catalog so content tuning (which goods the
	# first advancement asks for) never silently breaks this assertion.
	var first_rows: Array = CatalogScript.procurement_goods(1)
	var last_row: Dictionary = first_rows[first_rows.size() - 1]
	var first_row: Dictionary = first_rows[0]
	_expect("requirement = per_cell * territory when above floor",
		int((target.quantities as PackedInt64Array)[0])
			== CatalogScript.required_quantity(first_row, 4)
		and int((target.quantities as PackedInt64Array)[2])
			== CatalogScript.required_quantity(last_row, 4))
	_expect("requirement falls back to floor for tiny territory",
		CatalogScript.required_quantity({"per_cell": 10000, "floor": 20000}, 1) == 30000
		and CatalogScript.required_quantity({"per_cell": 10000, "floor": 20000}, 5) == 70000)
	_expect("first advancement grants the stone milestone prelude",
		country.grants.size() == 1 and StringName(country.grants[0].id) == &"tech.settled_knowledge")
	country.territory = 10
	model = service.refresh(3, true)
	_expect("requirements stay frozen when territory grows",
		String(model.status) == "purchasing" and int(model.frozen_territory_count) == 4
		and int(model.territory_count) == 10
		and int((model.costs as Array)[0].required)
			== CatalogScript.required_quantity(
				(CatalogScript.procurement_goods(1) as Array)[0], 4))
	_expect("start while purchasing is rejected",
		String(service.start(3, _next_sequence()).code) == "era_advance_in_progress")

	# --- pause / resume pushes ------------------------------------------------
	var pushes := economy.targets.size()
	_expect("pause accepted", bool(service.pause(4, _next_sequence()).ok))
	_expect("pause pushes inactive target", economy.targets.size() == pushes + 1
		and not bool(economy.targets.back().active))
	_expect("snapshot reports paused", String(service.snapshot().status) == "paused")
	_expect("pause twice rejected", not bool(service.pause(4, _next_sequence()).ok))
	_expect("resume accepted", bool(service.resume(4, _next_sequence()).ok))
	_expect("resume pushes the same frozen target", bool(economy.targets.back().active)
		and int((economy.targets.back().quantities as PackedInt64Array)[0])
			== CatalogScript.required_quantity(
				(CatalogScript.procurement_goods(1) as Array)[0], 4))

	# --- save / restore round trip --------------------------------------------
	var saved: Dictionary = service.to_save()
	var restored = ServiceScript.new()
	restored.bind(country, economy, HANDLE, Callable(self, "_next_sequence"))
	restored.restore(saved)
	pushes = economy.targets.size()
	var policy_pushes := economy.policies.size()
	restored.push_runtime_state(5)
	var restored_model: Dictionary = restored.refresh(4, true)
	_expect("restore keeps purchasing state and frozen requirements",
		String(restored_model.status) == "purchasing"
		and int(restored_model.frozen_territory_count) == 4
		and int((restored_model.costs as Array)[0].required)
			== CatalogScript.required_quantity(
				(CatalogScript.procurement_goods(1) as Array)[0], 4)
		and int(_condition(restored_model, "trade").current) == 25)
	_expect("restore re-pushes policy and active target",
		economy.policies.size() == policy_pushes + 1 and economy.targets.size() == pushes + 1
		and bool(economy.targets.back().active))
	_expect("save payload round-trips", JSON.stringify(restored.to_save()) == JSON.stringify(saved))

	# --- completion submission -----------------------------------------------
	for i in range((target.indices as PackedInt32Array).size()):
		country.goods[String(economy.ids[int(target.indices[i])])] = int(target.quantities[i])
	model = service.refresh(5)
	_expect("stocked treasury waits for the prelude milestone",
		country.advances.is_empty() and String(model.status) == "purchasing"
		and is_equal_approx(float(model.progress), 1.0))
	country.set_state("tech.settled_knowledge", 5)
	country.offer_status = "OPEN"
	service.refresh(6)
	_expect("open era reward offer defers completion", country.advances.is_empty()
		and not service.blocked_reason().is_empty())
	country.offer_status = "NONE"
	country.advance_ok = false
	model = service.refresh(7)
	_expect("rejected advance stays purchasing",
		country.advances.size() == 1 and String(model.status) == "purchasing")
	country.advance_ok = true
	pushes = economy.targets.size()
	model = service.refresh(8)
	var advance: Dictionary = country.advances.back()
	_expect("retry submits advance_era with the target milestone and frozen goods",
		country.advances.size() == 2 and StringName(advance.milestone) == &"tech.agrarian_society"
		and int(advance.day) == 9 and (advance.indices as PackedInt32Array) == (target.indices as PackedInt32Array)
		and (advance.quantities as PackedInt64Array) == (target.quantities as PackedInt64Array))
	_expect("completion stops economy purchasing", String(model.status) == "completing"
		and economy.targets.size() == pushes + 1 and not bool(economy.targets.back().active))
	model = service.refresh(9)
	_expect("no duplicate submission while completing", country.advances.size() == 2)

	# --- era ACK --------------------------------------------------------------
	country.set_state("tech.agrarian_society", 5)
	country.era = 1
	economy.trade_total = 40
	model = service.refresh(10)
	_expect("era_advanced emitted once with buffs", _advanced.size() == 1
		and int(_advanced[0][0]) == 0 and int(_advanced[0][1]) == 1
		and (_advanced[0][2] as PackedStringArray).size() == 6)
	_expect("after advancement the next era is evaluated fresh",
		int(model.current_era_index) == 1 and int(model.next_era_index) == 2
		and String(model.status) in ["locked", "ready"]
		and int(_condition(model, "trade").current) == 0
		and int(model.frozen_territory_count) == 0)

	# --- policy command -------------------------------------------------------
	_expect("invalid policy rejected",
		not bool(ServiceScript.validate_policy(10001, 0).ok))
	_expect("policy update pushes new shares",
		bool(service.set_policy(500, 2500, 11, _next_sequence()).ok)
		and int(economy.policies.back().treasury) == 500
		and int(service.policy().research_share_bp) == 2500)

	# --- max era -------------------------------------------------------------
	country.era = 10
	model = service.refresh(12)
	_expect("highest era reports max", String(model.status) == "max"
		and int(model.next_era_index) == -1)

	# --- controller contract additions ---------------------------------------
	for command in [&"era.advance.start", &"era.advance.pause", &"era.advance.resume",
			&"procurement.set_policy"]:
		_expect("controller allowlists %s" % command,
			PlayerControllerScript.SUPPORTED_COMMANDS.has(command))
	_expect("milestones are detected for research rejection",
		PlayerControllerScript.is_milestone_technology(&"tech.agrarian_society")
		and not PlayerControllerScript.is_milestone_technology(&"tech.hunting"))

	print("=== era advancement service: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _check_catalog(technology: Dictionary, economy_catalog: Dictionary) -> void:
	var good_ids: PackedStringArray = economy_catalog.get("good_ids", PackedStringArray())
	for good_id in CatalogScript.all_good_ids():
		_expect("procurement good exists: %s" % good_id, good_ids.has(good_id))
	# The first advancement happens in the opening economy. A required good that
	# no one produces yet can never be bought, so the purchase would sit at
	# partial progress forever (flint did exactly that in a real session).
	const START_MARKET_GOODS := ["clothing", "game_meat", "gathered_plants", "logs"]
	for row in CatalogScript.procurement_goods(1):
		_expect("first advancement good is sold at game start: %s" % String(row.good_id),
			START_MARKET_GOODS.has(String(row.good_id)))
	for target in range(1, 11):
		_expect("era %d has rules" % target, CatalogScript.is_valid_target(target)
			and CatalogScript.population_threshold(target) > CatalogScript.population_threshold(target - 1)
			and CatalogScript.building_threshold(target) > CatalogScript.building_threshold(target - 1)
			and CatalogScript.trade_order_threshold(target) > CatalogScript.trade_order_threshold(target - 1)
			and not CatalogScript.procurement_goods(target).is_empty())
	var ids: PackedStringArray = technology.technology_ids
	var offsets: PackedInt32Array = technology.technology_modifier_term_offsets
	for era_index in range(11):
		var milestone := String(CatalogScript.milestone_id(era_index))
		var index := ids.find(milestone)
		_expect("milestone %s carries 2-3 buff terms" % milestone, index >= 0
			and offsets[index + 1] - offsets[index] >= 2 and offsets[index + 1] - offsets[index] <= 3)
		_expect("milestone %s summary is a promotion buff" % milestone,
			String(technology.technology_effect_summaries[index]).begins_with("时代晋升效果："))
		_expect("buff lines match terms for %s" % milestone,
			CatalogScript.milestone_buff_lines(StringName(milestone)).size()
			== offsets[index + 1] - offsets[index])


func _check_snapshot_shape(model: Dictionary) -> void:
	var keys := ["ok", "current_era_index", "current_era_name", "next_era_index",
		"next_era_name", "status", "conditions", "conditions_met", "conditions_required",
		"can_start", "territory_count", "frozen_territory_count", "costs", "progress",
		"buffs_preview", "budget"]
	var sorted_model: Array = model.keys()
	sorted_model.sort()
	keys.sort()
	_expect("snapshot has exactly the §5 keys", sorted_model == keys)
	_expect("conditions are tech/population/buildings/trade",
		(model.conditions as Array).size() == 4
		and String(model.conditions[0].key) == "tech"
		and String(model.conditions[3].key) == "trade")
	for row in model.conditions:
		var row_keys: Array = (row as Dictionary).keys()
		row_keys.erase("tooltip")   # optional explanatory tooltip (all rows)
		row_keys.erase("mandatory")  # tech row is always mandatory since v5
		row_keys.sort()
		_expect("condition row shape", row_keys == ["current", "key", "label", "met", "target", "text"])
	for row in model.costs:
		var cost_keys: Array = (row as Dictionary).keys()
		cost_keys.sort()
		_expect("cost row shape", cost_keys == ["good_id", "in_treasury", "name", "ratio", "required"])
	var budget_keys: Array = (model.budget as Dictionary).keys()
	budget_keys.sort()
	_expect("budget shape", budget_keys == ["colonization_daily",
		"colonization_share_bp", "era_daily", "era_share_bp", "national_daily",
		"research_share_bp", "treasury_share_bp"])
	_expect("buffs preview is PackedStringArray", model.buffs_preview is PackedStringArray)
	_expect("conditions_required is 3 (tech mandatory + 2 of 3 economy)",
		int(model.conditions_required) == 3)


func _fill_tech_ratio(country: FakeCountry, technology: Dictionary, era_index: int,
		ratio: float) -> void:
	var era_id := String((technology.technology_era_ids_ordered as PackedStringArray)[era_index])
	var candidates: Array = []
	for index in range((technology.technology_ids as PackedStringArray).size()):
		if String(technology.technology_era_ids[index]) == era_id \
				and (int(technology.technology_flags[index]) & 2) == 0:
			candidates.append(index)
	var needed := int(ceil(float(candidates.size()) * ratio))
	for i in range(needed):
		country.states[int(candidates[i])] = 5


func _condition(model: Dictionary, key: String) -> Dictionary:
	for row in model.get("conditions", []):
		if String(row.key) == key:
			return row
	return {}


func _expect(label: String, condition: bool) -> void:
	if condition:
		return
	_failures += 1
	push_error("FAIL: %s" % label)
	print("FAIL: %s" % label)
