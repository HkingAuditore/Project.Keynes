class_name EconomyFacade
extends RefCounted

signal economy_event_batch_available(meta: Dictionary)
signal economy_event_batch(batch: Dictionary)
signal construction_command_settled(result: Dictionary)
signal family_colonization_settled(result: Dictionary)
signal infrastructure_command_settled(result: Dictionary)

const DEFAULT_PROFILE_PATH := "res://data/economy/default_economy.tres"
const GOOD_PROFILE_DIR := "res://data/goods"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyProfileScript = preload("res://scripts/data/economy_profile.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
## 与原生 SAT_DIM_* 枚举同序，供 Inspector 与溯源面板直接展示。
const SATISFACTION_DIMENSION_NAMES := [
	"温饱", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展",
]

enum Opcode {
	TRANSFER_TO_COHORT = 1,
	MINT_TO_COHORT = 2,
	BURN_FROM_COHORT = 3,
	ADD_STOCK = 4,
	REMOVE_STOCK = 5,
	ADD_POPULATION = 6,
	MOVE_POPULATION = 7,
	CHANGE_SIGNATURE = 8,
	TRANSFER_FROM_COHORT = 9,
	BUILD = 10,
	DEMOLISH = 11,
	COUNTRY_GOOD_TO_MARKET = 12,
	MARKET_GOOD_TO_COUNTRY = 13,
	FAMILY_FREE_BUILDING = 14,
	FAMILY_POPULATION_REWARD = 15,
	TREASURY_SPONSORED_BUILD = 16,
	FAMILY_COLONIZATION_START = 17,
	FAMILY_COLONIZATION_CANCEL = 18,
	FAMILY_COLONIZATION_SETTLE = 19,
}

const OWNERSHIP_TREASURY_SPONSORED_PRIVATE := 1

var _world_ext: Object = null
var _profile = null
var _catalog: Dictionary = {}
var _configured: bool = false
var _profession_display_names: Dictionary = {}
var _ethnicity_display_names: Dictionary = {}
var _building_display_names: Dictionary = {}
var _need_display_names: Dictionary = {}
var _good_display_names: Dictionary = {}
var _family_trait_descriptions: Dictionary = {}
var _family_trait_effect_keys: Dictionary = {}
var _family_modifier_displays: Dictionary = {}
var _family_trigger_displays: Dictionary = {}
var _family_trait_sequence: int = 0
var _construction_receipt_cursor: int = 0
var _colonization_receipt_cursors: Dictionary = {}
var _canal_receipt_cursors: Dictionary = {}

func configure(world_ext: Object, cell_count: int, seed: int, profile = null) -> Dictionary:
	_world_ext = world_ext
	_profile = profile
	if _profile == null:
		_profile = ResourceLoader.load(DEFAULT_PROFILE_PATH, "Resource")
	if _world_ext == null or not _world_ext.has_method("configure_economy"):
		return {"ok": false, "reason": "DCWorldExt economy API unavailable"}
	if _profile == null:
		return {"ok": false, "reason": "EconomyProfile unavailable"}
	_catalog = EconomyCatalogScript.compile_native_catalog()
	if not bool(_catalog.get("ok", false)):
		return _catalog
	var native_catalog := _catalog.duplicate()
	native_catalog.erase("ok")
	_profession_display_names = _load_display_names(EconomyCatalogScript.PROFESSION_DIR)
	_ethnicity_display_names = _load_display_names(EconomyCatalogScript.ETHNICITY_DIR)
	_building_display_names = _load_display_names(EconomyCatalogScript.BUILDING_DIR)
	_need_display_names = EconomyCatalogScript.need_display_names()
	_good_display_names = _load_display_names(GOOD_PROFILE_DIR)
	_load_family_effect_displays()
	var result: Dictionary = _world_ext.configure_economy(
		native_catalog, _profile.to_native_profile(), cell_count, seed)
	_configured = bool(result.get("ok", false))
	_construction_receipt_cursor = 0
	_colonization_receipt_cursors.clear()
	_canal_receipt_cursors.clear()
	return result

func bootstrap(population_packet: Dictionary = {}, market_packet: Dictionary = {},
		building_packet: Dictionary = {}) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "economy facade is not configured"}
	var packet := population_packet
	if packet.is_empty():
		packet = {
			"cell_indices": PackedInt32Array(),
			"signature_ids": PackedInt32Array(),
			"population": PackedInt64Array(),
			"funds": PackedInt64Array(),
		}
	var markets := market_packet.duplicate(true)
	for key in building_packet:
		markets[key] = building_packet[key]
	return _world_ext.bootstrap_economy(packet, markets)

func submit(commands: Array[Dictionary]) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "economy facade is not configured"}
	var batch := {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(),
		"target_handles": PackedInt64Array(),
		"i32_0": PackedInt32Array(),
		"i32_1": PackedInt32Array(),
		"i64_0": PackedInt64Array(),
		"i64_1": PackedInt64Array(),
	}
	for command in commands:
		batch.opcodes.append(int(command.get("opcode", 0)))
		batch.effective_days.append(int(command.get("effective_day", 0)))
		batch.sequences.append(int(command.get("sequence", 0)))
		batch.target_handles.append(int(command.get("target_handle", 0)))
		batch.i32_0.append(int(command.get("i32_0", 0)))
		batch.i32_1.append(int(command.get("i32_1", 0)))
		batch.i64_0.append(int(command.get("i64_0", 0)))
		batch.i64_1.append(int(command.get("i64_1", 0)))
	return _world_ext.submit_economy_commands(batch)

func add_stock(cell_idx: int, good_id: StringName, quantity: int,
		effective_day: int, sequence: int) -> Dictionary:
	var goods: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	var good_idx: int = goods.find(String(good_id))
	if good_idx < 0:
		return {"ok": false, "reason": "unknown good id: %s" % String(good_id)}
	return submit([{
		"opcode": Opcode.ADD_STOCK,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": 0,
		"i32_0": cell_idx,
		"i32_1": good_idx,
		"i64_0": quantity,
		"i64_1": 0,
	}])

func mint_to_cohort(cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	if amount <= 0:
		return {"ok": false, "reason": "amount must be positive"}
	return submit([{
		"opcode": Opcode.MINT_TO_COHORT,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": cohort_handle,
		"i64_0": amount,
	}])

func burn_from_cohort(cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	if amount <= 0:
		return {"ok": false, "reason": "amount must be positive"}
	return submit([{
		"opcode": Opcode.BURN_FROM_COHORT,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": cohort_handle,
		"i64_0": amount,
	}])

func add_population(cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	if amount <= 0:
		return {"ok": false, "reason": "amount must be positive"}
	return submit([{
		"opcode": Opcode.ADD_POPULATION,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": cohort_handle,
		"i64_0": amount,
	}])

func transfer_country_cash_to_cohort(country_handle: int, cohort_handle: int,
		amount: int, effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.TRANSFER_TO_COHORT,
		"target_handle": cohort_handle, "i64_0": amount, "i64_1": country_handle,
		"effective_day": effective_day, "sequence": sequence}])

func transfer_cohort_cash_to_country(cohort_handle: int, country_handle: int,
		amount: int, effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.TRANSFER_FROM_COHORT,
		"target_handle": cohort_handle, "i64_0": amount, "i64_1": country_handle,
		"effective_day": effective_day, "sequence": sequence}])

func transfer_country_good_to_market(country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return _submit_country_good_transfer(Opcode.COUNTRY_GOOD_TO_MARKET, country_handle,
		cell_idx, good_id, quantity, effective_day, sequence)

func transfer_market_good_to_country(country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return _submit_country_good_transfer(Opcode.MARKET_GOOD_TO_COUNTRY, country_handle,
		cell_idx, good_id, quantity, effective_day, sequence)

func _submit_country_good_transfer(opcode: int, country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	var goods: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	var good_idx := goods.find(String(good_id))
	if good_idx < 0:
		return {"ok": false, "reason": "unknown good id: %s" % String(good_id)}
	return submit([{"opcode": opcode, "target_handle": country_handle,
		"i32_0": cell_idx, "i32_1": good_idx, "i64_0": quantity,
		"effective_day": effective_day, "sequence": sequence}])

func population_cell_summary(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	if _world_ext.has_method("get_population_cell_summary"):
		return _world_ext.get_population_cell_summary(cell_idx)
	return _world_ext.get_population_cell_snapshot(cell_idx)

func named_settlement_snapshot() -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"get_named_settlement_snapshot"):
		return {"ok": false, "reason": "native settlement runtime unavailable"}
	return _world_ext.get_named_settlement_snapshot()

func settlement_delta(since_revision: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_settlement_delta"):
		return {"ok": false, "reason": "native settlement runtime unavailable"}
	return _world_ext.get_settlement_delta(since_revision)


func population_cell_snapshot(cell_idx: int, include_details: bool = true) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_population_cell_snapshot(
		cell_idx, include_details)
	if snapshot.has("populations"):
		_attach_population_display_metadata(snapshot)
		snapshot["details_available"] = true
		snapshot["details_pending"] = false
	else:
		snapshot["details_available"] = false
		snapshot["details_pending"] = bool(snapshot.get("busy", false))
	return snapshot

func market_cell_snapshot(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_market_cell_snapshot(cell_idx)
	var has_details := snapshot.has("good_ids")
	if has_details:
		snapshot["details_available"] = true
		snapshot["details_pending"] = false
	else:
		snapshot["details_available"] = false
		snapshot["details_pending"] = bool(snapshot.get("busy", false))
	return snapshot

## 冷路径满意度溯源。只读且只在原生 slice 之间安全，Inspector 打开时才调用。
func explain_cohort_satisfaction(cohort_handle: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("explain_cohort_satisfaction"):
		return {"ok": false, "reason": "satisfaction explain API unavailable"}
	var explained: Dictionary = _world_ext.explain_cohort_satisfaction(cohort_handle)
	if bool(explained.get("ok", false)):
		explained["dimension_names"] = SATISFACTION_DIMENSION_NAMES
	return explained


func cell_satisfaction_attractiveness(cell_idx: int) -> Dictionary:
	if not _configured \
			or not _world_ext.has_method("get_cell_satisfaction_attractiveness"):
		return {"ok": false, "reason": "satisfaction attractiveness API unavailable"}
	var attractiveness: Dictionary = \
		_world_ext.get_cell_satisfaction_attractiveness(cell_idx)
	if bool(attractiveness.get("ok", false)):
		attractiveness["dimension_names"] = SATISFACTION_DIMENSION_NAMES
	return attractiveness


func trade_orders_for_cell(cell_idx: int, offset: int = 0, limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_trade_orders_for_cell"):
		return {"ok": false, "reason": "trade order API unavailable", "total": 0}
	var page: Dictionary = _world_ext.get_trade_orders_for_cell(cell_idx, offset, limit)
	page["good_ids"] = _catalog.get("good_ids", PackedStringArray())
	return page


func country_trade_snapshot(country_handle: int, view: String = "summary",
		offset: int = 0, limit: int = 32) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_country_trade_snapshot"):
		return {"ok": false, "reason": "country trade API unavailable",
			"view": view, "total": 0}
	var page: Dictionary = _world_ext.get_country_trade_snapshot(
		country_handle, view, offset, clampi(limit, 1, 64))
	page["good_ids"] = _catalog.get("good_ids", PackedStringArray())
	return page


func good_display_name(good_index: int) -> String:
	var ids: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	if good_index < 0 or good_index >= ids.size():
		return "物资 %d" % good_index
	var stable_id := String(ids[good_index])
	return String(_good_display_names.get(stable_id, stable_id))


func profession_display_name(profession_id: StringName) -> String:
	var stable_id := String(profession_id)
	return String(_profession_display_names.get(stable_id, stable_id))

func building_cell_snapshot(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_building_cell_snapshot(cell_idx)
	if snapshot.has("building_type_ids"):
		_attach_building_display_metadata(snapshot)
	return snapshot


func construction_catalog(search: String = "", offset: int = 0,
		limit: int = 32,
		technology_available: PackedByteArray = PackedByteArray()) -> Dictionary:
	var ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	var enforce_technology := technology_available.size() == ids.size()
	var matches := PackedInt32Array()
	var needle := search.strip_edges().to_lower()
	for type_id in range(ids.size()):
		if enforce_technology and technology_available[type_id] == 0:
			continue
		var stable_id := String(ids[type_id])
		var display_name := String(_building_display_names.get(stable_id, stable_id))
		if needle.is_empty() or stable_id.to_lower().contains(needle) \
				or display_name.to_lower().contains(needle):
			matches.append(type_id)
	var begin := clampi(offset, 0, matches.size())
	var end := mini(matches.size(), begin + clampi(limit, 1, 32))
	return {"ok": true, "total": matches.size(), "offset": begin,
		"limit": clampi(limit, 1, 32), "type_ids": matches.slice(begin, end)}


func treasury_construction_options(country_handle: int, cell_idx: int,
		search: String = "", offset: int = 0, limit: int = 32) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_treasury_construction_quotes"):
		return {"ok": false, "reason": "construction_quote_api_unavailable"}
	var building_snapshot: Dictionary = building_cell_snapshot(cell_idx)
	var stable_ids: PackedStringArray = _catalog.get(
		"building_type_ids", PackedStringArray())
	var technology_available: PackedByteArray = building_snapshot.get(
		"building_technology_available", PackedByteArray())
	if not bool(building_snapshot.get("ok", false)) \
			or technology_available.size() != stable_ids.size():
		return {"ok": false, "reason": "construction_technology_snapshot_unavailable"}
	var page := construction_catalog(
		search, offset, limit, technology_available)
	var type_ids: PackedInt32Array = page.get("type_ids", PackedInt32Array())
	var quotes: Dictionary = _world_ext.get_treasury_construction_quotes(
		country_handle, cell_idx, type_ids)
	if not bool(quotes.get("ok", false)):
		return quotes
	var good_ids: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	var eligible: PackedByteArray = quotes.get("eligible", PackedByteArray())
	var reasons: PackedStringArray = quotes.get("reason_codes", PackedStringArray())
	var cash: PackedInt64Array = quotes.get("cash_required", PackedInt64Array())
	var treasury_totals: PackedInt64Array = quotes.get(
		"treasury_goods_used", PackedInt64Array())
	var market_totals: PackedInt64Array = quotes.get(
		"market_goods_used", PackedInt64Array())
	var material_offsets: PackedInt32Array = quotes.get(
		"material_offsets", PackedInt32Array())
	var material_good_ids: PackedInt32Array = quotes.get(
		"material_good_ids", PackedInt32Array())
	var material_required: PackedInt64Array = quotes.get(
		"material_required", PackedInt64Array())
	var material_treasury: PackedInt64Array = quotes.get(
		"material_treasury", PackedInt64Array())
	var material_market: PackedInt64Array = quotes.get(
		"material_market", PackedInt64Array())
	var items := []
	for i in range(type_ids.size()):
		var type_id := int(type_ids[i])
		var stable_id := String(stable_ids[type_id]) if type_id >= 0 \
				and type_id < stable_ids.size() else ""
		var materials := []
		var material_begin := int(material_offsets[i]) if i < material_offsets.size() else 0
		var material_end := int(material_offsets[i + 1]) \
				if i + 1 < material_offsets.size() else material_begin
		for edge in range(material_begin, material_end):
			var good_idx := int(material_good_ids[edge])
			var good_id := String(good_ids[good_idx]) if good_idx >= 0 \
					and good_idx < good_ids.size() else ""
			materials.append({"good_id": good_id,
				"name": String(_good_display_names.get(good_id, good_id)),
				"required": int(material_required[edge]),
				"treasury": int(material_treasury[edge]),
				"market": int(material_market[edge])})
		items.append({"type_id": type_id, "building_id": stable_id,
			"name": String(_building_display_names.get(stable_id, stable_id)),
			"eligible": i < eligible.size() and eligible[i] != 0,
			"reason_code": String(reasons[i]) if i < reasons.size() else "command_rejected",
			"cash_required": int(cash[i]) if i < cash.size() else 0,
			"treasury_goods_used": int(treasury_totals[i]) if i < treasury_totals.size() else 0,
			"market_goods_used": int(market_totals[i]) if i < market_totals.size() else 0,
			"materials": materials})
	return {"ok": true, "items": items, "total": int(page.get("total", 0)),
		"offset": int(page.get("offset", 0)), "limit": int(page.get("limit", 32)),
		"snapshot_day": int(quotes.get("snapshot_day", -1)), "nonbinding": true}


func treasury_sponsored_build(country_handle: int, cell_idx: int,
		building_id: StringName, effective_day: int, sequence: int,
		ownership_policy: StringName = &"treasury_sponsored_private") -> Dictionary:
	if ownership_policy != &"treasury_sponsored_private":
		return {"ok": false, "reason": "unsupported_ownership_policy"}
	var type_id := building_type_id(building_id)
	if type_id < 0:
		return {"ok": false, "reason": "construction_target_invalid"}
	return submit([{"opcode": Opcode.TREASURY_SPONSORED_BUILD,
		"effective_day": effective_day, "sequence": sequence,
		"target_handle": country_handle, "i32_0": cell_idx, "i32_1": type_id,
		"i64_0": 1, "i64_1": OWNERSHIP_TREASURY_SPONSORED_PRIVATE}])


func dispatch_construction_command_receipts() -> void:
	if not _configured or not _world_ext.has_method(
			"get_construction_command_receipts"):
		return
	var page: Dictionary = _world_ext.get_construction_command_receipts(
		_construction_receipt_cursor, 64)
	if not bool(page.get("ok", false)):
		return
	var stable_ids: PackedStringArray = _catalog.get(
		"building_type_ids", PackedStringArray())
	for raw in page.get("receipts", []):
		var result: Dictionary = raw
		var type_id := int(result.get("type_id", -1))
		result["building_id"] = String(stable_ids[type_id]) if type_id >= 0 \
				and type_id < stable_ids.size() else ""
		result["message"] = _construction_result_message(
			String(result.get("code", "command_rejected")))
		construction_command_settled.emit(result)
	_construction_receipt_cursor = maxi(_construction_receipt_cursor,
		int(page.get("last_receipt_id", _construction_receipt_cursor)))


func get_canal_route_quote(country_handle: int, start_cell: int, end_cell: int,
		waypoints: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_canal_route_quote"):
		return {"ok": false, "code": "canal_runtime_unavailable",
			"message": "canal_runtime_unavailable"}
	return _world_ext.get_canal_route_quote(
		country_handle, start_cell, end_cell, waypoints)


func get_canal_route_quote_detail(country_handle: int,
		quote_token: int) -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"get_canal_route_quote_detail"):
		return {"ok": false, "code": "canal_runtime_unavailable",
			"message": "canal_runtime_unavailable"}
	return _world_ext.get_canal_route_quote_detail(country_handle, quote_token)


func queue_canal_construction(country_handle: int, quote_token: int,
		effective_day: int, sequence: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("queue_canal_construction"):
		return {"ok": false, "code": "canal_runtime_unavailable",
			"message": "canal_runtime_unavailable",
			"effective_day": effective_day, "sequence": sequence}
	return _world_ext.queue_canal_construction(
		country_handle, quote_token, effective_day, sequence)


func dispatch_canal_construction_receipts(country_handle: int) -> void:
	if not _configured or not _world_ext.has_method(
			"get_canal_construction_receipts"):
		return
	var cursor := int(_canal_receipt_cursors.get(country_handle, 0))
	var page: Dictionary = _world_ext.get_canal_construction_receipts(
		country_handle, cursor, 64)
	if not bool(page.get("ok", false)):
		return
	for raw in page.get("receipts", []):
		var result: Dictionary = raw
		cursor = maxi(cursor, int(result.get("receipt_id", cursor)))
		infrastructure_command_settled.emit(result)
	_canal_receipt_cursors[country_handle] = cursor


func family_colonization_quotes(country_handle: int, target_cell: int,
		family_filter: int = 0, source_filter: int = -1,
		offset: int = 0, limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_colonization_quotes"):
		return {"ok": false, "code": "family_colonization_unavailable"}
	return _world_ext.get_family_colonization_quotes(country_handle, target_cell,
		family_filter, source_filter, offset, limit)


func family_colonization_quote_detail(quote_token: int,
		population: int = -1) -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"get_family_colonization_quote_detail"):
		return {"ok": false, "code": "family_colonization_unavailable"}
	var detail: Dictionary = _world_ext.get_family_colonization_quote_detail(
		quote_token, population)
	if not bool(detail.get("ok", false)):
		return detail
	var stable_ids: PackedStringArray = _catalog.get(
		"profession_ids", PackedStringArray())
	var names := PackedStringArray()
	var ids := PackedStringArray()
	for profession_id in detail.get("profession_ids", PackedInt32Array()):
		var stable_id := String(stable_ids[profession_id]) if profession_id >= 0 \
			and profession_id < stable_ids.size() else ""
		ids.append(stable_id)
		names.append(String(_profession_display_names.get(stable_id, stable_id)))
	detail["profession_stable_ids"] = ids
	detail["profession_display_names"] = names
	var building_ids: PackedStringArray = _catalog.get(
		"building_type_ids", PackedStringArray())
	var kit_names := PackedStringArray()
	for type_id in detail.get("kit_building_ids", PackedInt32Array()):
		kit_names.append(String(building_ids[type_id]) if type_id >= 0 \
			and type_id < building_ids.size() else "")
	detail["kit_building_stable_ids"] = kit_names
	return detail


func start_family_colonization(country_handle: int, family_handle: int,
		source_cell: int, target_cell: int, population: int, quote_token: int,
		effective_day: int, sequence: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("start_family_colonization"):
		return {"ok": false, "code": "family_colonization_unavailable"}
	return _world_ext.start_family_colonization(country_handle, family_handle,
		source_cell, target_cell, population, quote_token, effective_day, sequence)


func cancel_family_colonization(country_handle: int, expedition_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("cancel_family_colonization"):
		return {"ok": false, "code": "family_colonization_unavailable"}
	return _world_ext.cancel_family_colonization(country_handle,
		expedition_handle, effective_day, sequence)


func family_expeditions(country_handle: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_expeditions"):
		return {"ok": false, "code": "family_colonization_unavailable"}
	return _world_ext.get_family_expeditions(country_handle, offset, limit)


func family_expedition_snapshot(country_handle: int,
		expedition_handle: int) -> Dictionary:
	if not _configured or not _world_ext.has_method(
			"get_family_expedition_snapshot"):
		return {"ok": false, "code": "family_colonization_unavailable"}
	return _world_ext.get_family_expedition_snapshot(country_handle,
		expedition_handle)


func dispatch_family_colonization_receipts(country_handle: int) -> void:
	if not _configured or country_handle == 0 or not _world_ext.has_method(
			"get_family_colonization_receipts"):
		return
	var cursor := int(_colonization_receipt_cursors.get(country_handle, 0))
	var page: Dictionary = _world_ext.get_family_colonization_receipts(
		country_handle, cursor, 64)
	if not bool(page.get("ok", false)):
		return
	for raw in page.get("receipts", []):
		var result: Dictionary = raw
		result["country_handle"] = country_handle
		var code := String(result.get("code", ""))
		result["ok"] = not code.begins_with("colonization_")
		result["message"] = _colonization_result_message(code)
		family_colonization_settled.emit(result)
	_colonization_receipt_cursors[country_handle] = maxi(cursor,
		int(page.get("last_receipt_id", cursor)))


static func _colonization_result_message(code: String) -> String:
	return {
		"STARTED": "开拓队已经出发。",
		"CANCELLED_RETURNING": "开拓已取消，队伍正在返程。",
		"TARGET_LOST_RETURNING": "目标已被占领，队伍正在返程。",
		"CLAIMED": "开拓成功，目标已纳入领土。",
		"RELOCATED": "迁徙成功，人员已并入目标地块。",
		"RETURNED": "开拓队已返回原出发地。",
		"colonization_requote_required": "地图、视野或领土已变化，排队派遣未能出发。",
		"colonization_population_insufficient": "结算时源分支人口已不足，排队派遣未能出发。",
		"colonization_duplicate_target": "本国已有队伍前往该目标，排队派遣未能出发。",
		"colonization_family_cell_capacity": "目标地块家族已满，排队派遣未能出发。",
	}.get(code, "开拓队状态已更新。")


static func _construction_result_message(code: String) -> String:
	return {
		"ok": "建筑已开工。",
		"construction_cell_not_owned": "目标地块已不属于玩家国家。",
		"construction_technology_locked": "建造所需科技尚未解锁。",
		"construction_obsolete": "该建筑层级已经淘汰。",
		"construction_conditions_failed": "目标地块不满足建筑放置条件。",
		"construction_resource_unavailable": "当地自然资源承载不足。",
		"construction_materials_insufficient": "国库与当地市场的建材总量不足。",
		"construction_treasury_cash_insufficient": "国库资金不足以购买缺少的建材。",
		"construction_market_unavailable": "当地市场没有可结算的商人。",
		"unsupported_ownership_policy": "当前版本不支持该产权策略。",
	}.get(code, "修建命令未能执行。")


func family_cell_snapshot(cell_idx: int, offset: int = 0, limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_cell_snapshot"):
		return {"ok": false, "reason": "family_runtime_unavailable"}
	return _world_ext.get_family_cell_snapshot(cell_idx, offset, limit)


func family_snapshot(family_handle: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_snapshot"):
		return {"ok": false, "reason": "family_runtime_unavailable"}
	var snapshot: Dictionary = _world_ext.get_family_snapshot(family_handle)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var profession_ids: PackedInt32Array = snapshot.get(
		"profession_ids", PackedInt32Array())
	var profession_names := PackedStringArray()
	var catalog_professions: PackedStringArray = _catalog.get(
		"profession_ids", PackedStringArray())
	for profession_id in profession_ids:
		profession_names.append(catalog_professions[profession_id]
			if profession_id >= 0 and profession_id < catalog_professions.size()
			else "")
	snapshot["profession_stable_ids"] = profession_names
	var origin_cell := int(snapshot.get("origin_cell", -1))
	var settlement_name := ""
	var settlements := named_settlement_snapshot()
	var cells: PackedInt32Array = settlements.get("cell_indices", PackedInt32Array())
	var names: PackedStringArray = settlements.get("settlement_names", PackedStringArray())
	for i in range(mini(cells.size(), names.size())):
		if int(cells[i]) == origin_cell:
			settlement_name = String(names[i])
			break
	snapshot["origin_settlement_name"] = settlement_name
	var surname := String(snapshot.get("surname", ""))
	var format := String(snapshot.get("culture_group_naming_format", "CITY_SURNAME_SUFFIX"))
	var separator := String(snapshot.get("culture_group_separator", "-"))
	var suffix := String(snapshot.get("culture_group_suffix", "氏"))
	var family_name := surname
	if not settlement_name.is_empty():
		match format:
			"CITY_SEPARATOR_SURNAME": family_name = "%s%s%s" % [settlement_name, separator, surname]
			"CITY_SURNAME": family_name = "%s%s" % [settlement_name, surname]
			_: family_name = "%s%s%s" % [settlement_name, surname, suffix]
	var collision_index := 1
	var origin_families := family_cell_snapshot(origin_cell, 0, 256)
	var origin_cells: PackedInt32Array = origin_families.get("origin_cells", PackedInt32Array())
	var surnames: PackedStringArray = origin_families.get("surnames", PackedStringArray())
	var stable_ids: PackedInt64Array = origin_families.get("stable_ids", PackedInt64Array())
	var collisions: Array[int] = []
	for i in range(mini(origin_cells.size(), mini(surnames.size(), stable_ids.size()))):
		if int(origin_cells[i]) == origin_cell and String(surnames[i]) == surname:
			collisions.append(int(stable_ids[i]))
	collisions.sort()
	if collisions.size() > 1:
		collision_index = collisions.find(int(snapshot.get("stable_id", 0))) + 1
		family_name += " (%d)" % collision_index
	snapshot["family_name_collision_index"] = collision_index
	snapshot["family_name"] = family_name
	return snapshot


func get_family_traits(family_handle: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_traits"):
		return {"ok": false, "reason": "family_trait_runtime_unavailable"}
	var snapshot: Dictionary = _world_ext.get_family_traits(family_handle)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var axes: PackedInt32Array = snapshot.get(
		"behavior_axes", PackedInt32Array())
	var selector_ids: PackedInt32Array = snapshot.get(
		"behavior_selector_ids", PackedInt32Array())
	var stable_ids := PackedStringArray()
	var display_names := PackedStringArray()
	for index in range(mini(axes.size(), selector_ids.size())):
		var source_ids := PackedStringArray()
		var names: Dictionary = {}
		match int(axes[index]):
			0:
				source_ids = _catalog.get("building_type_ids", PackedStringArray())
				names = _building_display_names
			1:
				source_ids = _catalog.get("profession_ids", PackedStringArray())
				names = _profession_display_names
			2:
				source_ids = _catalog.get("need_ids", PackedStringArray())
				names = _need_display_names
			3:
				source_ids = _catalog.get("good_ids", PackedStringArray())
				names = _good_display_names
		var selector_id := int(selector_ids[index])
		var stable_id := String(source_ids[selector_id]) \
			if selector_id >= 0 and selector_id < source_ids.size() else ""
		stable_ids.append(stable_id)
		display_names.append(String(names.get(stable_id, stable_id)))
	snapshot["behavior_selector_stable_ids"] = stable_ids
	snapshot["behavior_selector_display_names"] = display_names
	var trait_keys: PackedStringArray = snapshot.get("trait_keys", PackedStringArray())
	snapshot["descriptions"] = _family_trait_description_column(trait_keys)
	snapshot["effect_display_names"] = _family_trait_effect_display_names(trait_keys)
	return snapshot


func family_branches(family_handle: int, offset: int = 0, limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_branches"):
		return {"ok": false, "reason": "family_runtime_unavailable"}
	return _world_ext.get_family_branches(family_handle, offset, limit)


func get_family_branch_effects(family_handle: int, cell_idx: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_branch_effects"):
		return {"ok": false, "reason": "family_trait_runtime_unavailable"}
	var snapshot: Dictionary = _world_ext.get_family_branch_effects(
		family_handle, cell_idx)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var modifier_keys: PackedStringArray = snapshot.get(
		"modifier_definition_keys", PackedStringArray())
	snapshot["modifier_display_names"] = _mapped_effect_names(
		modifier_keys, _family_modifier_displays)
	snapshot["modifier_descriptions"] = _mapped_effect_descriptions(
		modifier_keys, _family_modifier_displays)
	var trigger_keys: PackedStringArray = snapshot.get(
		"trigger_definition_keys", PackedStringArray())
	snapshot["trigger_display_names"] = _mapped_effect_names(
		trigger_keys, _family_trigger_displays)
	snapshot["trigger_descriptions"] = _mapped_effect_descriptions(
		trigger_keys, _family_trigger_displays)
	return snapshot


func queue_family_trait_mutation(family_handle: int, operation: Variant,
		trait_key: StringName, strength_q16: int = 65536,
		effective_day: int = 0, priority: int = 100,
		sequence: int = -1) -> int:
	if not _configured or not _world_ext.has_method("submit_family_trait_commands"):
		return 0
	var opcode: int = int(operation) if typeof(operation) == TYPE_INT else {
		"grant": 1, "remove": 2, "set_strength": 3,
	}.get(String(operation), 0)
	if sequence < 0:
		_family_trait_sequence += 1
		sequence = _family_trait_sequence
	var result: Dictionary = _world_ext.submit_family_trait_commands({
		"protocol_version": 1,
		"operations": PackedInt32Array([opcode]),
		"family_handles": PackedInt64Array([family_handle]),
		"trait_keys": PackedStringArray([String(trait_key)]),
		"strength_q16": PackedInt32Array([strength_q16]),
		"effective_days": PackedInt64Array([effective_day]),
		"priorities": PackedInt32Array([priority]),
		"sequences": PackedInt64Array([sequence]),
	})
	var orders: PackedInt64Array = result.get("request_orders", PackedInt64Array())
	return int(orders[0]) if bool(result.get("ok", false)) and not orders.is_empty() else 0


func queue_family_trigger_reward(effect: Dictionary) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "economy facade is not configured"}
	var command_key := String(effect.get("command_key", ""))
	var opcode := 0
	var building_type := -1
	if command_key == "family.free_building":
		opcode = Opcode.FAMILY_FREE_BUILDING
		var building_ids: PackedStringArray = _catalog.get(
			"building_type_ids", PackedStringArray())
		building_type = building_ids.find(String(effect.get("definition_key", "")))
		if building_type < 0:
			return {"ok": false, "reason": "family_reward_building_unknown"}
	elif command_key == "family.population_reward":
		opcode = Opcode.FAMILY_POPULATION_REWARD
	else:
		return {"ok": false, "reason": "family_reward_command_unknown"}
	return submit([{
		"opcode": opcode,
		"effective_day": int(effect.get("effective_day", 0)),
		"sequence": maxi(0, int(effect.get("effect_id", 0))),
		"target_handle": int(effect.get("target_handle", 0)),
		"i32_0": int(effect.get("payload_i0", 0)),
		"i32_1": building_type,
		"i64_0": maxi(1, int(effect.get("resolved_value", 1))),
		"i64_1": int(effect.get("effect_id", 0)),
	}])


func family_industries(family_handle: int, offset: int = 0, limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_industries"):
		return {"ok": false, "reason": "family_runtime_unavailable"}
	var snapshot: Dictionary = _world_ext.get_family_industries(
		family_handle, offset, limit)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var ids: PackedInt32Array = snapshot.get("building_type_ids", PackedInt32Array())
	var names := PackedStringArray()
	var catalog_ids: PackedStringArray = _catalog.get(
		"building_type_ids", PackedStringArray())
	for type_id in ids:
		names.append(catalog_ids[type_id]
			if type_id >= 0 and type_id < catalog_ids.size() else "")
	snapshot["building_type_stable_ids"] = names
	return snapshot


func family_notable_people(family_handle: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_family_notable_people"):
		return {"ok": false, "reason": "notable_person_runtime_unavailable"}
	var page: Dictionary = _world_ext.get_family_notable_people(
		family_handle, offset, limit)
	if not bool(page.get("ok", false)):
		return page
	var family: Dictionary = family_snapshot(family_handle)
	_attach_notable_person_page_names(page, String(family.get("surname", "")))
	return page


func notable_person_snapshot(person_handle: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_notable_person_snapshot"):
		return {"ok": false, "reason": "notable_person_runtime_unavailable"}
	var snapshot: Dictionary = _world_ext.get_notable_person_snapshot(person_handle)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	snapshot["full_name"] = _format_person_name(
		String(snapshot.get("surname", "")),
		String(snapshot.get("given_name", "")),
		int(snapshot.get("name_disambiguator", 0)))
	var profession_idx := int(snapshot.get("profession_id", -1))
	var professions: PackedStringArray = _catalog.get(
		"profession_ids", PackedStringArray())
	var profession_id := professions[profession_idx] \
		if profession_idx >= 0 and profession_idx < professions.size() else ""
	snapshot["profession_stable_id"] = profession_id
	snapshot["profession_display_name"] = String(
		_profession_display_names.get(String(profession_id), String(profession_id)))
	var building_idx := int(snapshot.get("building_type_id", -1))
	var building_ids: PackedStringArray = _catalog.get(
		"building_type_ids", PackedStringArray())
	var building_id := building_ids[building_idx] \
		if building_idx >= 0 and building_idx < building_ids.size() else ""
	snapshot["building_type_stable_id"] = building_id
	snapshot["building_type_display_name"] = String(
		_building_display_names.get(String(building_id), String(building_id)))
	return snapshot


func notable_person_needs(person_handle: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_notable_person_needs"):
		return {"ok": false, "reason": "notable_person_runtime_unavailable"}
	var page: Dictionary = _world_ext.get_notable_person_needs(
		person_handle, offset, limit)
	if not bool(page.get("ok", false)):
		return page
	var need_indices: PackedInt32Array = page.get("need_ids", PackedInt32Array())
	var catalog_needs: PackedStringArray = _catalog.get("need_ids", PackedStringArray())
	var stable_ids := PackedStringArray()
	var display_names := PackedStringArray()
	for need_idx in need_indices:
		var stable_id := catalog_needs[need_idx] \
			if need_idx >= 0 and need_idx < catalog_needs.size() else ""
		stable_ids.append(stable_id)
		display_names.append(String(_need_display_names.get(
			String(stable_id), String(stable_id))))
	page["need_stable_ids"] = stable_ids
	page["need_display_names"] = display_names
	return page


func building_notable_people(building_handle: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_building_notable_people"):
		return {"ok": false, "reason": "notable_person_runtime_unavailable"}
	var page: Dictionary = _world_ext.get_building_notable_people(
		building_handle, offset, limit)
	if not bool(page.get("ok", false)):
		return page
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var surnames := {}
	for family_handle in families:
		if surnames.has(family_handle):
			continue
		var family: Dictionary = family_snapshot(family_handle)
		surnames[family_handle] = String(family.get("surname", ""))
	_attach_notable_person_page_names(page, "", surnames)
	return page


func _attach_notable_person_page_names(page: Dictionary, surname: String,
		surnames_by_family: Dictionary = {}) -> void:
	var given_indices: PackedInt32Array = page.get(
		"given_name_indices", PackedInt32Array())
	var disambiguators: PackedInt32Array = page.get(
		"name_disambiguators", PackedInt32Array())
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var given_catalog: PackedStringArray = _catalog.get(
		"person_given_name_text", PackedStringArray())
	var given_names := PackedStringArray()
	var full_names := PackedStringArray()
	for i in given_indices.size():
		var given_idx := int(given_indices[i])
		var given := given_catalog[given_idx] \
			if given_idx >= 0 and given_idx < given_catalog.size() else ""
		var row_surname := surname
		if not surnames_by_family.is_empty() and i < families.size():
			row_surname = String(surnames_by_family.get(families[i], ""))
		var disambiguator := int(disambiguators[i]) \
			if i < disambiguators.size() else 0
		given_names.append(given)
		full_names.append(_format_person_name(row_surname, given, disambiguator))
	page["given_names"] = given_names
	page["full_names"] = full_names


func _format_person_name(surname: String, given_name: String,
		disambiguator: int) -> String:
	var base := surname + given_name
	return base if disambiguator <= 0 else "%s·%d" % [base, disambiguator + 1]

func _attach_building_display_metadata(snapshot: Dictionary) -> void:
	var type_ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var type_names := PackedStringArray()
	for stable_id in type_ids:
		type_names.append(String(_building_display_names.get(String(stable_id), String(stable_id))))
	var profession_ids: PackedStringArray = _catalog.get("profession_ids", PackedStringArray())
	var profession_names := PackedStringArray()
	for stable_id in profession_ids:
		profession_names.append(String(_profession_display_names.get(String(stable_id), String(stable_id))))
	snapshot["building_type_display_names"] = type_names
	snapshot["profession_stable_ids"] = profession_ids
	snapshot["profession_display_names"] = profession_names
	for key in [
		"signature_profession_ids", "building_owner_profession_ids", "building_owner_slots",
		"building_employee_offsets", "building_employee_profession_ids", "building_employee_slots",
		"building_input_offsets", "building_input_good_ids", "building_input_quantities",
		"building_input_required_q16",
		"building_input_category_ids", "building_input_min_quality_levels",
		"building_input_candidate_offsets", "building_input_candidate_good_ids",
		"building_input_candidate_efficiency_q16", "building_upgrade_family_ids",
		"building_construction_candidate_offsets", "building_construction_candidate_good_ids",
		"building_construction_candidate_efficiency_q16",
		"building_upgrade_family_indices", "building_upgrade_tiers",
		"building_production_climate_profile_indices", "production_climate_profile_ids",
		"building_behavior_ids",
		"building_output_offsets", "building_output_good_ids", "building_output_quantities",
		"building_resource_ids", "building_resource_offsets", "building_production_resource_ids",
		"building_production_resource_quantities", "building_production_resource_modes",
		"building_production_resource_access_modes",
		"building_resource_generation_offsets",
		"building_resource_generation_ids", "building_resource_generation_quantities",
		"building_resource_generation_floor_q16", "building_kinds",
		"building_technology_tag_offsets", "building_technology_tags", "good_ids",
		"good_category_ids", "good_substitution_category_offsets",
		"good_substitution_category_ids", "good_storage_modes", "good_monetary_issue_values",
		"good_production_quality_levels", "good_production_efficiency_q16",
		"good_technology_tag_offsets", "good_technology_tags",
	]:
		snapshot[key] = _catalog.get(key)

func building_type_id(building_id: StringName) -> int:
	var ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	return ids.find(String(building_id))

func building_job_spec(building_id: StringName) -> Dictionary:
	var type_ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	var type_id := type_ids.find(String(building_id))
	if type_id < 0:
		return {"ok": false, "reason": "unknown building type: %s" % String(building_id)}
	var profession_ids: PackedStringArray = _catalog.get("profession_ids", PackedStringArray())
	var owner_professions: PackedInt32Array = _catalog.get(
		"building_owner_profession_ids", PackedInt32Array())
	var owner_slots: PackedInt64Array = _catalog.get("building_owner_slots", PackedInt64Array())
	var employee_offsets: PackedInt32Array = _catalog.get(
		"building_employee_offsets", PackedInt32Array())
	var employee_professions: PackedInt32Array = _catalog.get(
		"building_employee_profession_ids", PackedInt32Array())
	var employee_slots: PackedInt64Array = _catalog.get(
		"building_employee_slots", PackedInt64Array())
	if type_id >= owner_professions.size() or type_id >= owner_slots.size() or \
			type_id + 1 >= employee_offsets.size():
		return {"ok": false, "reason": "building job catalog shape invalid"}
	var owner_profession_idx := int(owner_professions[type_id])
	if owner_profession_idx < 0 or owner_profession_idx >= profession_ids.size():
		return {"ok": false, "reason": "building owner profession invalid"}
	var role_professions := PackedStringArray()
	var role_slots := PackedInt64Array()
	for role in range(employee_offsets[type_id], employee_offsets[type_id + 1]):
		var profession_idx := int(employee_professions[role])
		if profession_idx < 0 or profession_idx >= profession_ids.size():
			return {"ok": false, "reason": "building employee profession invalid"}
		role_professions.append(profession_ids[profession_idx])
		role_slots.append(employee_slots[role])
	return {
		"ok": true,
		"type_id": type_id,
		"stable_id": String(building_id),
		"owner_profession": profession_ids[owner_profession_idx],
		"owner_slots": owner_slots[type_id],
		"employee_professions": role_professions,
		"employee_slots": role_slots,
	}

func building_placement_spec(building_id: StringName) -> Dictionary:
	var type_ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	var type_id := type_ids.find(String(building_id))
	if type_id < 0:
		return {"ok": false, "reason": "unknown building type: %s" % String(building_id)}
	var good_ids: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	var resource_ids: PackedStringArray = _catalog.get(
		"building_resource_ids", PackedStringArray())
	var input_goods := _stable_ids_from_catalog_range(type_id, good_ids,
		"building_input_offsets", "building_input_good_ids")
	var output_goods := _stable_ids_from_catalog_range(type_id, good_ids,
		"building_output_offsets", "building_output_good_ids")
	var input_quantities_all: PackedInt64Array = _catalog.get(
		"building_input_quantities", PackedInt64Array())
	var input_required_all: PackedInt32Array = _catalog.get(
		"building_input_required_q16", PackedInt32Array())
	var output_quantities_all: PackedInt64Array = _catalog.get(
		"building_output_quantities", PackedInt64Array())
	var production_resources := _stable_ids_from_catalog_range(type_id, resource_ids,
		"building_resource_offsets", "building_production_resource_ids")
	var technology_offsets: PackedInt32Array = _catalog.get(
		"building_technology_tag_offsets", PackedInt32Array())
	var technology_tags: PackedStringArray = _catalog.get(
		"building_technology_tags", PackedStringArray())
	var input_categories_all: PackedStringArray = _catalog.get(
		"building_input_category_ids", PackedStringArray())
	var input_min_levels_all: PackedInt32Array = _catalog.get(
		"building_input_min_quality_levels", PackedInt32Array())
	var candidate_offsets_all: PackedInt32Array = _catalog.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidate_goods_all: PackedInt32Array = _catalog.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	var candidate_efficiencies_all: PackedInt32Array = _catalog.get(
		"building_input_candidate_efficiency_q16", PackedInt32Array())
	var good_categories: PackedStringArray = _catalog.get(
		"good_category_ids", PackedStringArray())
	var good_substitution_offsets: PackedInt32Array = _catalog.get(
		"good_substitution_category_offsets", PackedInt32Array())
	var good_substitution_ids: PackedStringArray = _catalog.get(
		"good_substitution_category_ids", PackedStringArray())
	if not bool(input_goods.get("ok", false)) or not bool(output_goods.get("ok", false)) \
			or not bool(production_resources.get("ok", false)):
		return {"ok": false, "reason": "building placement catalog shape invalid"}
	var kinds: PackedInt32Array = _catalog.get("building_kinds", PackedInt32Array())
	var quantities: PackedInt64Array = _catalog.get(
		"building_production_resource_quantities", PackedInt64Array())
	var modes: PackedInt32Array = _catalog.get(
		"building_production_resource_modes", PackedInt32Array())
	var access_modes: PackedInt32Array = _catalog.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var family_ids: PackedStringArray = _catalog.get(
		"building_upgrade_family_ids", PackedStringArray())
	var family_indices: PackedInt32Array = _catalog.get(
		"building_upgrade_family_indices", PackedInt32Array())
	var upgrade_tiers: PackedInt32Array = _catalog.get(
		"building_upgrade_tiers", PackedInt32Array())
	var resource_begin := int(production_resources.begin)
	var resource_end := int(production_resources.end)
	if type_id >= kinds.size() or type_id >= family_indices.size() \
			or type_id >= upgrade_tiers.size() \
			or resource_end > quantities.size() or resource_end > modes.size() \
			or resource_end > access_modes.size() or type_id + 1 >= technology_offsets.size():
		return {"ok": false, "reason": "building placement resource columns invalid"}
	var technology_begin := int(technology_offsets[type_id])
	var technology_end := int(technology_offsets[type_id + 1])
	var input_begin := int(input_goods.begin)
	var input_end := int(input_goods.end)
	if technology_begin < 0 or technology_end < technology_begin \
			or technology_end > technology_tags.size() or input_end > input_categories_all.size() \
			or input_end > input_min_levels_all.size() or input_end >= candidate_offsets_all.size() \
			or input_end > input_quantities_all.size() \
			or input_end > input_required_all.size() \
			or int(output_goods.end) > output_quantities_all.size():
		return {"ok": false, "reason": "building placement technology columns invalid"}
	var local_candidate_offsets := PackedInt32Array([0])
	var local_candidate_good_ids := PackedStringArray()
	var local_candidate_efficiencies := PackedInt32Array()
	for input_idx in range(input_begin, input_end):
		var candidate_begin := int(candidate_offsets_all[input_idx])
		var candidate_end := int(candidate_offsets_all[input_idx + 1])
		if candidate_begin < 0 or candidate_end < candidate_begin \
				or candidate_end > candidate_goods_all.size() \
				or candidate_end > candidate_efficiencies_all.size():
			return {"ok": false, "reason": "building placement candidate columns invalid"}
		for candidate_idx in range(candidate_begin, candidate_end):
			var good_idx := int(candidate_goods_all[candidate_idx])
			if good_idx < 0 or good_idx >= good_ids.size():
				return {"ok": false, "reason": "building placement candidate good invalid"}
			local_candidate_good_ids.append(good_ids[good_idx])
			local_candidate_efficiencies.append(candidate_efficiencies_all[candidate_idx])
		local_candidate_offsets.append(local_candidate_good_ids.size())
	var output_categories := PackedStringArray()
	var output_substitution_offsets := PackedInt32Array([0])
	var output_substitution_ids := PackedStringArray()
	for good_id in output_goods.ids:
		var good_idx := good_ids.find(String(good_id))
		output_categories.append(String(good_categories[good_idx]) \
			if good_idx >= 0 and good_idx < good_categories.size() else "")
		if good_idx < 0 or good_idx + 1 >= good_substitution_offsets.size():
			return {"ok": false, "reason": "building output substitution categories invalid"}
		var category_begin := int(good_substitution_offsets[good_idx])
		var category_end := int(good_substitution_offsets[good_idx + 1])
		if category_begin < 0 or category_end <= category_begin \
				or category_end > good_substitution_ids.size():
			return {"ok": false, "reason": "building output substitution category range invalid"}
		output_substitution_ids.append_array(
			good_substitution_ids.slice(category_begin, category_end))
		output_substitution_offsets.append(output_substitution_ids.size())
	var family_idx := int(family_indices[type_id])
	var higher_tier_ids := PackedStringArray()
	if family_idx >= 0:
		for candidate in range(type_ids.size()):
			if candidate < family_indices.size() and candidate < upgrade_tiers.size() \
					and int(family_indices[candidate]) == family_idx \
					and int(upgrade_tiers[candidate]) > int(upgrade_tiers[type_id]):
				higher_tier_ids.append(type_ids[candidate])
	return {
		"ok": true,
		"type_id": type_id,
		"stable_id": String(building_id),
		"kind": int(kinds[type_id]),
		"upgrade_family_id": family_ids[family_idx] \
			if family_idx >= 0 and family_idx < family_ids.size() else "",
		"upgrade_tier": int(upgrade_tiers[type_id]),
		"higher_tier_building_ids": higher_tier_ids,
		"input_good_ids": input_goods.ids,
		"input_quantities": input_quantities_all.slice(input_begin, input_end),
		"input_required_q16": input_required_all.slice(input_begin, input_end),
		"input_category_ids": input_categories_all.slice(input_begin, input_end),
		"input_min_quality_levels": input_min_levels_all.slice(input_begin, input_end),
		"input_candidate_offsets": local_candidate_offsets,
		"input_candidate_good_ids": local_candidate_good_ids,
		"input_candidate_efficiency_q16": local_candidate_efficiencies,
		"output_good_ids": output_goods.ids,
		"output_quantities": output_quantities_all.slice(
			int(output_goods.begin), int(output_goods.end)),
		"output_category_ids": output_categories,
		"output_substitution_category_offsets": output_substitution_offsets,
		"output_substitution_category_ids": output_substitution_ids,
		"resource_ids": production_resources.ids,
		"resource_quantities": quantities.slice(resource_begin, resource_end),
		"resource_modes": modes.slice(resource_begin, resource_end),
		"resource_access_modes": access_modes.slice(resource_begin, resource_end),
		"technology_tags": technology_tags.slice(technology_begin, technology_end),
	}

func _stable_ids_from_catalog_range(type_id: int, stable_ids: PackedStringArray,
		offset_key: String, index_key: String) -> Dictionary:
	var offsets: PackedInt32Array = _catalog.get(offset_key, PackedInt32Array())
	var indices: PackedInt32Array = _catalog.get(index_key, PackedInt32Array())
	if type_id + 1 >= offsets.size():
		return {"ok": false}
	var begin := int(offsets[type_id])
	var end := int(offsets[type_id + 1])
	if begin < 0 or end < begin or end > indices.size():
		return {"ok": false}
	var ids := PackedStringArray()
	for edge in range(begin, end):
		var stable_idx := int(indices[edge])
		if stable_idx < 0 or stable_idx >= stable_ids.size():
			return {"ok": false}
		ids.append(stable_ids[stable_idx])
	return {"ok": true, "ids": ids, "begin": begin, "end": end}

func build(cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	var type_id := building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "reason": "invalid building type or count"}
	return submit([{
		"opcode": Opcode.BUILD,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": owner_handle,
		"i32_0": cell_idx,
		"i32_1": type_id,
		"i64_0": count,
		"i64_1": 0,
	}])

func demolish(cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	var type_id := building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "reason": "invalid building type or count"}
	return submit([{
		"opcode": Opcode.DEMOLISH,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": owner_handle,
		"i32_0": cell_idx,
		"i32_1": type_id,
		"i64_0": count,
		"i64_1": 0,
	}])

func report() -> Dictionary:
	return _world_ext.get_economy_report() if _configured else {"configured": false}

func native_catalog() -> Dictionary:
	return _catalog.duplicate(false)

func signature_id(profession_id: StringName, ethnicity_id: StringName) -> int:
	var key := "%s|%s" % [String(profession_id), String(ethnicity_id)]
	var keys: PackedStringArray = _catalog.get("signature_keys", PackedStringArray())
	return keys.find(key)

func good_ids() -> PackedStringArray:
	return (_catalog.get("good_ids", PackedStringArray()) as PackedStringArray).duplicate()

func profession_ids() -> PackedStringArray:
	return (_catalog.get("profession_ids", PackedStringArray()) as PackedStringArray).duplicate()

func building_type_ids() -> PackedStringArray:
	return (_catalog.get("building_type_ids", PackedStringArray()) as PackedStringArray).duplicate()

## Cold-path bootstrap view of the same compiled columns consumed by the native runtime.
## This deliberately exposes only finance inputs; runtime authority remains in C++.
func bootstrap_finance_columns() -> Dictionary:
	var result := {}
	for key in [
		"good_ids", "good_default_price", "good_inventory_target_ratios_q16",
		"good_merchant_buy_factor_q16", "good_monetary_issue_values",
		"good_technology_tag_offsets", "good_technology_tags",
		"plan_ids", "plan_need_offsets", "need_ids", "need_living_cost_weights_q16",
		"need_stable_ids", "need_base_qty_per_person", "need_quantity_env_curve_ids",
		"need_variant_offsets", "variant_preference_q16",
		"variant_preference_env_curve_ids", "variant_component_offsets",
		"component_good_ids", "component_qty_per_need", "environment_curve_signal_ids",
		"environment_curve_values_q16", "ethnicity_need_factor_q16",
		"signature_ethnicity_ids", "signature_plan_ids",
	]:
		result[key] = _catalog.get(key)
	var ratios: PackedInt32Array = result.get(
		"good_inventory_target_ratios_q16", PackedInt32Array())
	var target_days := PackedInt32Array()
	target_days.resize(ratios.size())
	for good_idx in range(ratios.size()):
		target_days[good_idx] = int(_profile.merchant_market_making_days_q16) * \
			int(ratios[good_idx]) / 65536
	result["good_target_inventory_days_q16"] = target_days
	result["living_cost_base_plan_id"] = String(_profile.living_cost_base_plan_id)
	return result

func bootstrap_cycle_days(cohort_count: int, market_count: int = 0,
		active_building_cell_count: int = 0, building_group_count: int = 0) -> int:
	if _profile == null:
		return 1
	# Native locks N from populated work plus machine timing. This helper only
	# reports the profile maximum (1–5). It never restores 50/334 auto cadence.
	var maximum := clampi(int(_profile.market_max_cycle_days), 1, 5)
	var configured := int(_profile.market_cycle_days)
	if configured <= 0:
		configured = maximum
	return clampi(configured, 1, maximum)

func _attach_population_display_metadata(snapshot: Dictionary) -> void:
	var profession_ids: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var ethnicity_ids: PackedStringArray = snapshot.get(
		"ethnicity_stable_ids", PackedStringArray())
	var profession_names := PackedStringArray()
	var ethnicity_names := PackedStringArray()
	for stable_id in profession_ids:
		profession_names.append(String(_profession_display_names.get(
			String(stable_id), String(stable_id))))
	for stable_id in ethnicity_ids:
		ethnicity_names.append(String(_ethnicity_display_names.get(
			String(stable_id), String(stable_id))))
	snapshot["profession_display_names"] = profession_names
	snapshot["ethnicity_display_names"] = ethnicity_names


func _load_family_effect_displays() -> void:
	_family_trait_descriptions.clear()
	_family_trait_effect_keys.clear()
	_family_modifier_displays.clear()
	_family_trigger_displays.clear()
	var trait_catalog = FamilyTraitCatalogScript.load_default()
	if trait_catalog != null:
		for definition in trait_catalog.traits:
			if definition == null:
				continue
			var trait_key := String(definition.key).strip_edges()
			if trait_key.is_empty():
				continue
			_family_trait_descriptions[trait_key] = String(
				definition.description).strip_edges()
			var effect_keys := PackedStringArray()
			var seen := {}
			for effect in definition.modifiers:
				if effect == null:
					continue
				var modifier_key := String(effect.definition_key).strip_edges()
				if modifier_key.is_empty() or seen.has(modifier_key):
					continue
				seen[modifier_key] = true
				effect_keys.append(modifier_key)
			for binding in definition.triggers:
				if binding == null:
					continue
				for raw_key in binding.definition_keys_by_tier:
					var trigger_key := String(raw_key).strip_edges()
					if trigger_key.is_empty() or seen.has(trigger_key):
						continue
					seen[trigger_key] = true
					effect_keys.append(trigger_key)
			_family_trait_effect_keys[trait_key] = effect_keys
	var modifier_catalog = ModifierCatalogScript.load_default()
	if modifier_catalog != null:
		for definition in modifier_catalog.definitions:
			_store_effect_display(_family_modifier_displays, definition)
	var trigger_catalog = TriggerCatalogScript.load_default()
	if trigger_catalog != null:
		for definition in trigger_catalog.definitions:
			_store_effect_display(_family_trigger_displays, definition)


static func _store_effect_display(table: Dictionary, definition: Resource) -> void:
	if definition == null:
		return
	var key := String(definition.get("key")).strip_edges()
	if key.is_empty():
		return
	table[key] = {
		"display_name": String(definition.get("display_name")).strip_edges(),
		"description": String(definition.get("description")).strip_edges(),
	}


func _family_trait_description_column(trait_keys: PackedStringArray) -> PackedStringArray:
	var descriptions := PackedStringArray()
	for trait_key in trait_keys:
		descriptions.append(String(_family_trait_descriptions.get(String(trait_key), "")))
	return descriptions


func _family_trait_effect_display_names(trait_keys: PackedStringArray) -> PackedStringArray:
	var names := PackedStringArray()
	var seen := {}
	for trait_key in trait_keys:
		var effect_keys: PackedStringArray = _family_trait_effect_keys.get(
			String(trait_key), PackedStringArray())
		for effect_key in effect_keys:
			var display := _effect_display_name(String(effect_key))
			if display.is_empty() or seen.has(display):
				continue
			seen[display] = true
			names.append(display)
	return names


func _effect_display_name(effect_key: String) -> String:
	var modifier: Dictionary = _family_modifier_displays.get(effect_key, {})
	var modifier_name := String(modifier.get("display_name", ""))
	if not modifier_name.is_empty():
		return modifier_name
	var trigger: Dictionary = _family_trigger_displays.get(effect_key, {})
	var trigger_name := String(trigger.get("display_name", ""))
	if not trigger_name.is_empty():
		return trigger_name
	return ""


func _mapped_effect_names(keys: PackedStringArray, table: Dictionary) -> PackedStringArray:
	var names := PackedStringArray()
	for key in keys:
		var entry: Dictionary = table.get(String(key), {})
		var display := String(entry.get("display_name", "")).strip_edges()
		names.append(display if not display.is_empty() else String(key))
	return names


func _mapped_effect_descriptions(keys: PackedStringArray, table: Dictionary) -> PackedStringArray:
	var descriptions := PackedStringArray()
	for key in keys:
		var entry: Dictionary = table.get(String(key), {})
		descriptions.append(String(entry.get("description", "")).strip_edges())
	return descriptions


static func _load_display_names(directory: String) -> Dictionary:
	var result := {}
	# [pk-export-remap] 见 economy_catalog.gd::_load_resources() 同名注释——导出
	# 包里 DirAccess 看到的是带 .remap 后缀的目录项，用 ResourceLoader.list_directory()
	# 才能拿到 x.tres 逻辑名。
	var paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(directory):
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [directory, file_name])
	paths.sort()
	for path in paths:
		var profile = ResourceLoader.load(path, "Resource")
		if profile == null:
			continue
		var stable_id := String(profile.get("id"))
		if stable_id == "":
			continue
		var display_name := String(profile.get("display_name"))
		result[stable_id] = display_name if display_name != "" else stable_id
	return result

func begin_save() -> Dictionary:
	return _world_ext.begin_economy_save(_profile.save_chunk_bytes) if _configured else {"ok": false, "reason": "not configured"}

func read_save_chunk() -> PackedByteArray:
	return _world_ext.read_economy_save_chunk(_profile.save_chunk_bytes) if _configured else PackedByteArray()

func end_save() -> Dictionary:
	return _world_ext.end_economy_save() if _configured else {"ok": false, "reason": "not configured"}

func restore_bytes(bytes: PackedByteArray, _chunk_bytes: int = -1) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	var begun: Dictionary = _world_ext.begin_economy_restore()
	if not bool(begun.get("ok", false)):
		return begun
	var cursor := 0
	while cursor < bytes.size():
		# PKSV stores concatenated native PKEC frames. Recover each exact frame
		# boundary from its 16-byte little-endian header before feeding C++.
		if bytes.size() - cursor < 16:
			return {"ok": false, "reason": "save_chunk_header_invalid"}
		var payload_bytes := _read_u32_le(bytes, cursor + 12)
		var chunk_end := cursor + 16 + payload_bytes
		if payload_bytes < 0 or chunk_end > bytes.size():
			return {"ok": false, "reason": "save_chunk_header_invalid"}
		var fed: Dictionary = _world_ext.feed_economy_restore_chunk(
			bytes.slice(cursor, chunk_end))
		if not bool(fed.get("ok", false)):
			return fed
		cursor = chunk_end
	return _world_ext.end_economy_restore()


static func _read_u32_le(bytes: PackedByteArray, offset: int) -> int:
	return int(bytes[offset]) \
		| (int(bytes[offset + 1]) << 8) \
		| (int(bytes[offset + 2]) << 16) \
		| (int(bytes[offset + 3]) << 24)


func event_schema() -> Dictionary:
	if not _configured or not _world_ext.has_method("get_economy_event_schema"):
		return {"ok": false, "reason": "economy event API unavailable"}
	return _world_ext.get_economy_event_schema()

func set_trace_cells(cells: PackedInt32Array) -> Dictionary:
	if not _configured or not _world_ext.has_method("set_economy_trace_filter"):
		return {"ok": false, "reason": "economy event API unavailable"}
	return _world_ext.set_economy_trace_filter({"cells": cells})

func set_inspector_trace_cell(cell_idx: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("set_economy_inspector_trace_cell"):
		return {"ok": false, "reason": "economy inspector trace API unavailable"}
	return _world_ext.set_economy_inspector_trace_cell(cell_idx)

func poll_events(consumer_id: StringName, max_events: int = -1,
		kind: int = 0, cell: int = -1, after_event_id: int = -1) -> Dictionary:
	if not _configured or not _world_ext.has_method("poll_economy_events"):
		return {"ok": false, "reason": "economy event API unavailable", "count": 0}
	var opts := {
		"consumer_id": consumer_id,
		"max_events": _profile.economy_trace_poll_max_events if max_events < 0 else max_events,
		"kind": kind,
		"cell": cell,
	}
	if after_event_id >= 0:
		opts["after_event_id"] = after_event_id
	return _world_ext.poll_economy_events(opts)

func ack_events(consumer_id: StringName, up_to_event_id: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("ack_economy_events"):
		return {"ok": false, "reason": "economy event API unavailable"}
	return _world_ext.ack_economy_events(consumer_id, up_to_event_id)

func trace_report() -> Dictionary:
	if not _configured or not _world_ext.has_method("get_economy_trace_report"):
		return {"ok": false, "reason": "economy event API unavailable"}
	return _world_ext.get_economy_trace_report()

func dispatch_committed_events(meta: Dictionary) -> void:
	if not bool(meta.get("economy_event_batch_published", false)):
		return
	economy_event_batch_available.emit(meta)
	var batch := poll_events(&"economy_facade_handlers")
	if int(batch.get("count", 0)) <= 0:
		return
	economy_event_batch.emit(batch)
	ack_events(&"economy_facade_handlers", int(batch.get("last_event_id", 0)))

func begin_event_archive(chunk_bytes: int = -1) -> Dictionary:
	if not _configured or not _world_ext.has_method("begin_economy_event_archive"):
		return {"ok": false, "reason": "economy event archive API unavailable"}
	return _world_ext.begin_economy_event_archive(
		_profile.save_chunk_bytes if chunk_bytes < 0 else chunk_bytes)

func read_event_archive_chunk(max_bytes: int = -1) -> PackedByteArray:
	if not _configured or not _world_ext.has_method("read_economy_event_archive_chunk"):
		return PackedByteArray()
	return _world_ext.read_economy_event_archive_chunk(
		_profile.save_chunk_bytes if max_bytes < 0 else max_bytes)

func end_event_archive() -> Dictionary:
	if not _configured or not _world_ext.has_method("end_economy_event_archive"):
		return {"ok": false, "reason": "economy event archive API unavailable"}
	return _world_ext.end_economy_event_archive()

func write_event_archive(path: String, chunk_bytes: int = -1) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	var file := FileAccess.open_compressed(
		path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return {"ok": false, "reason": "event archive file open failed",
			"error": FileAccess.get_open_error()}
	var begin := begin_event_archive(chunk_bytes)
	if not bool(begin.get("ok", false)):
		file.close()
		return begin
	var chunks := 0
	var bytes_written := 0
	while true:
		var chunk := read_event_archive_chunk(chunk_bytes)
		if chunk.is_empty():
			break
		file.store_buffer(chunk)
		chunks += 1
		bytes_written += chunk.size()
	file.close()
	var ended := end_event_archive()
	ended["path"] = path
	ended["chunks"] = chunks
	ended["uncompressed_bytes"] = bytes_written
	return ended

func world_ext() -> Object:
	return _world_ext

func profile():
	return _profile

func is_configured() -> bool:
	return _configured
