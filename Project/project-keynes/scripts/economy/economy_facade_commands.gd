extends RefCounted

## Builds and forwards requests for economy, construction and colonization.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyFacadeDisplayScript = preload(
	"res://scripts/economy/economy_facade_display.gd")
const OWNERSHIP_TREASURY_SPONSORED_PRIVATE := 1
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
	# 35: 国库出资拆除。16 在移除侧的镜像：官营建筑组的属主是保留的官营签名，
	# 不是任何活着的族群，所以普通拆除（11）永远够不到它——11 用族群句柄反解属主。
	TREASURY_SPONSORED_DEMOLISH = 35,
	FAMILY_COLONIZATION_START = 17,
	FAMILY_COLONIZATION_CANCEL = 18,
	FAMILY_COLONIZATION_SETTLE = 19,
	FAMILY_ABSORB_ANONYMOUS = 21,
	FAMILY_PURCHASE_DISCOUNT = 22,
}


static func bootstrap(host, population_packet: Dictionary = {}, market_packet: Dictionary = {},
		building_packet: Dictionary = {}) -> Dictionary:
	if not host._configured:
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
	return host._world_ext.bootstrap_economy(packet, markets)


static func submit(host, commands: Array[Dictionary]) -> Dictionary:
	if not host._configured:
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
	return host._world_ext.submit_economy_commands(batch)


static func add_stock(host, cell_idx: int, good_id: StringName, quantity: int,
		effective_day: int, sequence: int) -> Dictionary:
	var goods: PackedStringArray = host._catalog.get("good_ids", PackedStringArray())
	var good_idx: int = goods.find(String(good_id))
	if good_idx < 0:
		return {"ok": false, "reason": "unknown good id: %s" % String(good_id)}
	var command_batch: Array[Dictionary] = [{
		"opcode": Opcode.ADD_STOCK,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": 0,
		"i32_0": cell_idx,
		"i32_1": good_idx,
		"i64_0": quantity,
		"i64_1": 0,
	}]
	return host.submit(command_batch)


static func mint_to_cohort(host, cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	if amount <= 0:
		return {"ok": false, "reason": "amount must be positive"}
	var command_batch: Array[Dictionary] = [{
		"opcode": Opcode.MINT_TO_COHORT,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": cohort_handle,
		"i64_0": amount,
	}]
	return host.submit(command_batch)

## GM 铸币与转账同批提交，复用原生审计和国家资金协调器。


static func mint_to_treasury(host, country_handle: int, cell_idx: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	if amount <= 0 or country_handle == 0:
		return {"ok": false, "reason": "invalid_treasury_mint"}
	var snapshot: Dictionary = host.population_cell_snapshot(cell_idx)
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	if handles.is_empty():
		return {"ok": false, "reason": "treasury_mint_cohort_unavailable"}
	var command_batch: Array[Dictionary] = [
		{"opcode": Opcode.MINT_TO_COHORT, "target_handle": handles[0],
			"i64_0": amount, "effective_day": effective_day, "sequence": sequence},
		{"opcode": Opcode.TRANSFER_FROM_COHORT, "target_handle": handles[0],
			"i64_0": amount, "i64_1": country_handle,
			"effective_day": effective_day, "sequence": sequence + 1},
	]
	return host.submit(command_batch)


static func burn_from_cohort(host, cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	if amount <= 0:
		return {"ok": false, "reason": "amount must be positive"}
	var command_batch: Array[Dictionary] = [{
		"opcode": Opcode.BURN_FROM_COHORT,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": cohort_handle,
		"i64_0": amount,
	}]
	return host.submit(command_batch)


static func add_population(host, cohort_handle: int, amount: int,
		effective_day: int, sequence: int) -> Dictionary:
	if amount <= 0:
		return {"ok": false, "reason": "amount must be positive"}
	var command_batch: Array[Dictionary] = [{
		"opcode": Opcode.ADD_POPULATION,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": cohort_handle,
		"i64_0": amount,
	}]
	return host.submit(command_batch)


static func transfer_country_cash_to_cohort(host, country_handle: int, cohort_handle: int,
		amount: int, effective_day: int, sequence: int) -> Dictionary:
	var command_batch: Array[Dictionary] = [{"opcode": Opcode.TRANSFER_TO_COHORT,
		"target_handle": cohort_handle, "i64_0": amount, "i64_1": country_handle,
		"effective_day": effective_day, "sequence": sequence}]
	return host.submit(command_batch)


static func transfer_cohort_cash_to_country(host, cohort_handle: int, country_handle: int,
		amount: int, effective_day: int, sequence: int) -> Dictionary:
	var command_batch: Array[Dictionary] = [{"opcode": Opcode.TRANSFER_FROM_COHORT,
		"target_handle": cohort_handle, "i64_0": amount, "i64_1": country_handle,
		"effective_day": effective_day, "sequence": sequence}]
	return host.submit(command_batch)


static func transfer_country_good_to_market(host, country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return host._submit_country_good_transfer(Opcode.COUNTRY_GOOD_TO_MARKET, country_handle,
		cell_idx, good_id, quantity, effective_day, sequence)


static func transfer_market_good_to_country(host, country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return host._submit_country_good_transfer(Opcode.MARKET_GOOD_TO_COUNTRY, country_handle,
		cell_idx, good_id, quantity, effective_day, sequence)


static func _submit_country_good_transfer(host, opcode: int, country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	var goods: PackedStringArray = host._catalog.get("good_ids", PackedStringArray())
	var good_idx := goods.find(String(good_id))
	if good_idx < 0:
		return {"ok": false, "reason": "unknown good id: %s" % String(good_id)}
	var command_batch: Array[Dictionary] = [{"opcode": opcode, "target_handle": country_handle,
		"i32_0": cell_idx, "i32_1": good_idx, "i64_0": quantity,
		"effective_day": effective_day, "sequence": sequence}]
	return host.submit(command_batch)


static func construction_type_columns(host) -> Dictionary:
	return EconomyFacadeDisplayScript.construction_type_columns(host._catalog, host._good_display_names)


## Sector ids in compiled column order (index == `building_economic_sectors`).


static func construction_sector_ids(host) -> PackedStringArray:
	return PackedStringArray(EconomyCatalogScript.BUILDING_SECTOR_IDS)


## Every catalog entry that matches the technology gate, the sector and the
## search needle — unpaged. The construction workspace sorts the whole set
## before slicing a page, so the ordering is global instead of per-page.


static func construction_candidates(host, search: String = "",
		technology_available: PackedByteArray = PackedByteArray(),
		sector: int = -1) -> PackedInt32Array:
	var ids: PackedStringArray = host._catalog.get("building_type_ids", PackedStringArray())
	var enforce_technology := technology_available.size() == ids.size()
	var sectors: PackedInt32Array = host._catalog.get(
		"building_economic_sectors", PackedInt32Array())
	var enforce_sector := sector >= 0 and sectors.size() == ids.size()
	var matches := PackedInt32Array()
	var needle := search.strip_edges().to_lower()
	for type_id in range(ids.size()):
		if enforce_technology and technology_available[type_id] == 0:
			continue
		if enforce_sector and int(sectors[type_id]) != sector:
			continue
		var stable_id := String(ids[type_id])
		var display_name := String(host._building_display_names.get(stable_id, stable_id))
		if needle.is_empty() or stable_id.to_lower().contains(needle) \
				or display_name.to_lower().contains(needle):
			matches.append(type_id)
	return matches


static func construction_catalog(host, search: String = "", offset: int = 0,
		limit: int = 32,
		technology_available: PackedByteArray = PackedByteArray(),
		sector: int = -1) -> Dictionary:
	var matches: PackedInt32Array = host.construction_candidates(search, technology_available, sector)
	var begin := clampi(offset, 0, matches.size())
	var end := mini(matches.size(), begin + clampi(limit, 1, 32))
	return {"ok": true, "total": matches.size(), "offset": begin,
		"limit": clampi(limit, 1, 32), "type_ids": matches.slice(begin, end)}


## Quotes an explicit type list. The caller owns filtering and paging, so the
## workspace never has to re-derive the catalog page it just displayed.


static func construction_quotes(host, country_handle: int, cell_idx: int,
		type_ids: PackedInt32Array) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "construction_quote_api_unavailable"}
	var quotes: Dictionary = host._world_ext.get_treasury_construction_quotes(
		country_handle, cell_idx, type_ids)
	if not bool(quotes.get("ok", false)):
		return quotes
	var stable_ids: PackedStringArray = host._catalog.get(
		"building_type_ids", PackedStringArray())
	var good_ids: PackedStringArray = host._catalog.get("good_ids", PackedStringArray())
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
	# The quote's own prices, not a second market-snapshot read: the displayed
	# subtotals must add up to the quoted cash even if a tick happens between.
	var material_prices: PackedInt32Array = quotes.get(
		"material_prices", PackedInt32Array())
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
				"name": String(host._good_display_names.get(good_id, good_id)),
				"required": int(material_required[edge]),
				"treasury": int(material_treasury[edge]),
				"market": int(material_market[edge]),
				"unit_price": int(material_prices[edge]) \
					if edge < material_prices.size() else 0})
		items.append({"type_id": type_id, "building_id": stable_id,
			"name": String(host._building_display_names.get(stable_id, stable_id)),
			"eligible": i < eligible.size() and eligible[i] != 0,
			"reason_code": String(reasons[i]) if i < reasons.size() else "command_rejected",
			"cash_required": int(cash[i]) if i < cash.size() else 0,
			"treasury_goods_used": int(treasury_totals[i]) if i < treasury_totals.size() else 0,
			"market_goods_used": int(market_totals[i]) if i < market_totals.size() else 0,
			"materials": materials})
	return {"ok": true, "items": items,
		"snapshot_day": int(quotes.get("snapshot_day", -1)), "nonbinding": true}


## 营造是一条正式经济命令。当原生端把 StageOps 作为生产写入边界时，旧批量入口
## `submit_economy_commands` 是 fail-closed 的（`economy_legacy_ingress_disabled`），
## 所以优先走专用入口 `queue_treasury_sponsored_build`：命令进经济属主的收件箱，
## 在下一个 epoch 结算并照常产出营造回执。旧批量入口只留给没有该方法的旧 DLL。


static func treasury_sponsored_build(host, country_handle: int, cell_idx: int,
		building_id: StringName, effective_day: int, sequence: int,
		ownership_policy: StringName = &"treasury_sponsored_private") -> Dictionary:
	if ownership_policy != &"treasury_sponsored_private":
		return {"ok": false, "code": "unsupported_ownership_policy",
			"reason": "unsupported_ownership_policy",
			"message": host._construction_result_message("unsupported_ownership_policy"),
			"effective_day": effective_day, "sequence": sequence}
	var type_id: int = host.building_type_id(building_id)
	if type_id < 0:
		print("[construction] reject: unknown building_id=%s (catalog=%d types)" % [
			String(building_id),
			int((host._catalog.get("building_type_ids", PackedStringArray()) as PackedStringArray).size())])
		return {"ok": false, "code": "construction_target_invalid",
			"reason": "construction_target_invalid",
			"message": host._construction_result_message("construction_target_invalid"),
			"effective_day": effective_day, "sequence": sequence}
	if host._configured:
		var queued: Dictionary = host._world_ext.queue_treasury_sponsored_build(
			country_handle, cell_idx, type_id, effective_day, sequence)
		if not bool(queued.get("ok", false)):
			var code := String(queued.get("code", "command_rejected"))
			queued["reason"] = code
			queued["message"] = host._construction_result_message(code)
		print("[construction] queue cell=%d type=%d(%s) day=%d seq=%d -> ok=%s code=%s" % [
			cell_idx, type_id, String(building_id), effective_day, sequence,
			str(queued.get("ok", false)), str(queued.get("code", ""))])
		return queued
	var command_batch: Array[Dictionary] = [{"opcode": Opcode.TREASURY_SPONSORED_BUILD,
		"effective_day": effective_day, "sequence": sequence,
		"target_handle": country_handle, "i32_0": cell_idx, "i32_1": type_id,
		"i64_0": 1, "i64_1": OWNERSHIP_TREASURY_SPONSORED_PRIVATE}]
	var legacy: Dictionary = host.submit(command_batch)
	if not bool(legacy.get("ok", false)) \
			and String(legacy.get("reason", "")) == "economy_legacy_ingress_disabled":
		# 旧 DLL 没有专用入口，而当前生产写入边界拒绝旧批量提交。
		legacy["code"] = "construction_ingress_unavailable"
		legacy["message"] = "游戏组件版本过旧，营造功能不可用。请更新游戏。"
	return legacy


## 拆除的镜像入口：官营建筑先在经济账本里减座数，军事侧随后才读出变化。
## 与 `treasury_sponsored_build` 同构，所以两条命令的回执形状、拒因码与
## 「先扣后建 / 先减后记」的顺序约束完全一致。


static func treasury_sponsored_demolish(host, country_handle: int, cell_idx: int,
		building_id: StringName, count: int, effective_day: int,
		sequence: int) -> Dictionary:
	var type_id: int = host.building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "code": "demolish_target_invalid",
			"reason": "demolish_target_invalid",
			"message": host._demolish_result_message("demolish_target_invalid"),
			"effective_day": effective_day, "sequence": sequence}
	if host._configured:
		var queued: Dictionary = host._world_ext.queue_treasury_sponsored_demolish(
			country_handle, cell_idx, type_id, count, effective_day, sequence)
		if not bool(queued.get("ok", false)):
			var code := String(queued.get("code", "command_rejected"))
			queued["reason"] = code
			queued["message"] = host._demolish_result_message(code)
		return queued
	# 旧 DLL 没有专用入口，而当前生产写入边界拒绝旧批量提交：明确说不可用，
	# 而不是退回到一条永远够不到官营建筑组的普通拆除。
	return {"ok": false, "code": "demolish_ingress_unavailable",
		"reason": "demolish_ingress_unavailable",
		"message": "游戏组件版本过旧，拆除功能不可用。请更新游戏。",
		"effective_day": effective_day, "sequence": sequence}


static func dispatch_construction_command_receipts(host) -> void:
	if not host._configured:
		return
	var page: Dictionary = host._world_ext.get_construction_command_receipts(
		host._construction_receipt_cursor, 64)
	if bool(page.get("ok", false)):
		host.emit_construction_command_receipts(page.get("receipts", []))


static func emit_construction_command_receipts(host, receipts: Array) -> void:
	var stable_ids: PackedStringArray = host._catalog.get(
		"building_type_ids", PackedStringArray())
	for raw: Dictionary in receipts:
		var receipt_id := int(raw.get("receipt_id", -1))
		if receipt_id <= host._construction_receipt_cursor:
			continue
		host._construction_receipt_cursor = receipt_id
		var result := raw.duplicate()
		var type_id := int(result.get("type_id", -1))
		result["building_id"] = String(stable_ids[type_id]) if type_id >= 0 \
				and type_id < stable_ids.size() else ""
		var code := String(result.get("code", "command_rejected"))
		result["message"] = host._demolish_result_message(code) \
			if String(result.get("command", "")) == "military.state.demolish" \
			else host._construction_result_message(code)
		print("[construction] receipt id=%s seq=%s cell=%s type=%s ok=%s code=%s settled_day=%s" % [
			str(result.get("receipt_id", -1)), str(result.get("sequence", -1)),
			str(result.get("cell_idx", -1)), str(result.get("type_id", -1)),
			str(result.get("ok", false)), str(result.get("code", "")),
			str(result.get("settled_day", -1))])
		host.construction_command_settled.emit(result)


static func get_canal_route_quote(host, country_handle: int, start_cell: int, end_cell: int,
		waypoints: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "canal_runtime_unavailable",
			"message": "canal_runtime_unavailable"}
	return host._world_ext.get_canal_route_quote(
		country_handle, start_cell, end_cell, waypoints)


static func get_canal_route_quote_detail(host, country_handle: int,
		quote_token: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "canal_runtime_unavailable",
			"message": "canal_runtime_unavailable"}
	return host._world_ext.get_canal_route_quote_detail(country_handle, quote_token)


static func queue_canal_construction(host, country_handle: int, quote_token: int,
		effective_day: int, sequence: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "canal_runtime_unavailable",
			"message": "canal_runtime_unavailable",
			"effective_day": effective_day, "sequence": sequence}
	return host._world_ext.queue_canal_construction(
		country_handle, quote_token, effective_day, sequence)


static func family_colonization_quotes(host, country_handle: int, target_cell: int,
		family_filter: int = 0, source_filter: int = -1,
		offset: int = 0, limit: int = 64) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "family_colonization_unavailable"}
	var page: Dictionary = host._world_ext.get_family_colonization_quotes(country_handle, target_cell,
		family_filter, source_filter, offset, limit)
	if bool(page.get("ok", false)):
		var names := EconomyFacadeDisplayScript.settlement_name_lookup(host)
		var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
		var source_names := PackedStringArray()
		for cell in sources:
			var name := String(names.get(int(cell), "")).strip_edges()
			source_names.append(name if not name.is_empty() else "聚落 %d" % (int(cell) + 1))
		page["source_settlement_names"] = source_names
	return page


static func family_colonization_quote_detail(host, quote_token: int,
		population: int = -1) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "family_colonization_unavailable"}
	var detail: Dictionary = host._world_ext.get_family_colonization_quote_detail(
		quote_token, population)
	if not bool(detail.get("ok", false)):
		return detail
	var stable_ids: PackedStringArray = host._catalog.get(
		"profession_ids", PackedStringArray())
	var names := PackedStringArray()
	var ids := PackedStringArray()
	for profession_id in detail.get("profession_ids", PackedInt32Array()):
		var stable_id := String(stable_ids[profession_id]) if profession_id >= 0 \
			and profession_id < stable_ids.size() else ""
		ids.append(stable_id)
		names.append(String(host._profession_display_names.get(stable_id, stable_id)))
	detail["profession_stable_ids"] = ids
	detail["profession_display_names"] = names
	var building_ids: PackedStringArray = host._catalog.get(
		"building_type_ids", PackedStringArray())
	var kit_names := PackedStringArray()
	for type_id in detail.get("kit_building_ids", PackedInt32Array()):
		kit_names.append(String(building_ids[type_id]) if type_id >= 0 \
			and type_id < building_ids.size() else "")
	detail["kit_building_stable_ids"] = kit_names
	detail["kit_building_display_names"] = EconomyFacadeDisplayScript.mapped_names(kit_names, host._building_display_names)
	return detail


static func start_family_colonization(host, country_handle: int, family_handle: int,
		source_cell: int, target_cell: int, population: int, quote_token: int,
		effective_day: int, sequence: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "family_colonization_unavailable"}
	return host._world_ext.start_family_colonization(country_handle, family_handle,
		source_cell, target_cell, population, quote_token, effective_day, sequence)


static func cancel_family_colonization(host, country_handle: int, expedition_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "family_colonization_unavailable"}
	return host._world_ext.cancel_family_colonization(country_handle,
		expedition_handle, effective_day, sequence)


## 国家购买预算（时代晋升 §2.2）。transient：读档后由玩家会话重推。
## 原生侧只把请求放进收件箱，在下一个经济周期开始时生效。
## era/colonization 传 -1 表示本次不改该通道的份额。


static func set_country_procurement_policy(host, country_handle: int, enabled: bool,
		treasury_share_bp: int, research_share_bp: int,
		effective_day: int, sequence: int,
		era_share_bp: int = -1, colonization_share_bp: int = -1) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "procurement_policy_unavailable"}
	return host._world_ext.set_country_procurement_policy(country_handle, enabled,
		clampi(treasury_share_bp, 0, 10000), clampi(research_share_bp, 0, 10000),
		effective_day, sequence,
		-1 if era_share_bp < 0 else clampi(era_share_bp, 0, 10000),
		-1 if colonization_share_bp < 0 else clampi(colonization_share_bp, 0, 10000))


## 时代收购目标（§2.3）。active=false 清空目标（暂停）；已买入国库的物资不退回。
## required_quantities 以 GOODS_SCALE 计。


static func set_era_procurement_target(host, country_handle: int, active: bool,
		good_indices: PackedInt32Array, required_quantities: PackedInt64Array,
		effective_day: int, sequence: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "era_procurement_unavailable"}
	return host._world_ext.set_era_procurement_target(country_handle, active,
		good_indices, required_quantities, effective_day, sequence)


## §2.4 快照：policy/预算分配/时代收购进度/trade_orders_total。


static func country_procurement_snapshot(host, country_handle: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "procurement_snapshot_unavailable"}
	return host._world_ext.country_procurement_snapshot(country_handle)


static func family_expeditions(host, country_handle: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "family_colonization_unavailable"}
	return host._world_ext.get_family_expeditions(country_handle, offset, limit)


static func family_expedition_snapshot(host, country_handle: int,
		expedition_handle: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "code": "family_colonization_unavailable"}
	return host._world_ext.get_family_expedition_snapshot(country_handle,
		expedition_handle)


static func dispatch_family_colonization_receipts(host, country_handle: int) -> void:
	if not host._configured or country_handle == 0:
		return
	var cursor := int(host._colonization_receipt_cursors.get(country_handle, 0))
	var page: Dictionary = host._world_ext.get_family_colonization_receipts(
		country_handle, cursor, 64)
	if bool(page.get("ok", false)):
		host.emit_family_colonization_receipts(page.get("receipts", []), country_handle)


static func emit_family_colonization_receipts(host, receipts: Array, country_handle: int = 0) -> void:
	for raw: Dictionary in receipts:
		var country := int(raw.get("country_handle", country_handle))
		var receipt_id := int(raw.get("receipt_id", -1))
		if receipt_id <= int(host._colonization_receipt_cursors.get(country, 0)):
			continue
		host._colonization_receipt_cursors[country] = receipt_id
		var result := raw.duplicate()
		result["country_handle"] = country
		var code := String(result.get("code", ""))
		result["ok"] = not code.begins_with("colonization_")
		result["message"] = host._colonization_result_message(code)
		host.family_colonization_settled.emit(result)


static func building_job_spec(host, building_id: StringName) -> Dictionary:
	var type_ids: PackedStringArray = host._catalog.get("building_type_ids", PackedStringArray())
	var type_id := type_ids.find(String(building_id))
	if type_id < 0:
		return {"ok": false, "reason": "unknown building type: %s" % String(building_id)}
	var profession_ids: PackedStringArray = host._catalog.get("profession_ids", PackedStringArray())
	var owner_professions: PackedInt32Array = host._catalog.get(
		"building_owner_profession_ids", PackedInt32Array())
	var owner_slots: PackedInt64Array = host._catalog.get("building_owner_slots", PackedInt64Array())
	var employee_offsets: PackedInt32Array = host._catalog.get(
		"building_employee_offsets", PackedInt32Array())
	var employee_professions: PackedInt32Array = host._catalog.get(
		"building_employee_profession_ids", PackedInt32Array())
	var employee_slots: PackedInt64Array = host._catalog.get(
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


static func building_placement_spec(host, building_id: StringName) -> Dictionary:
	return preload("res://scripts/economy/building_placement_catalog.gd").query(host._catalog, building_id)


static func build(host, cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	var type_id: int = host.building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "reason": "invalid building type or count"}
	var command_batch: Array[Dictionary] = [{
		"opcode": Opcode.BUILD,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": owner_handle,
		"i32_0": cell_idx,
		"i32_1": type_id,
		"i64_0": count,
		"i64_1": 0,
	}]
	return host.submit(command_batch)


static func demolish(host, cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	var type_id: int = host.building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "reason": "invalid building type or count"}
	var command_batch: Array[Dictionary] = [{
		"opcode": Opcode.DEMOLISH,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": owner_handle,
		"i32_0": cell_idx,
		"i32_1": type_id,
		"i64_0": count,
		"i64_1": 0,
	}]
	return host.submit(command_batch)
