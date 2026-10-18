extends "res://tests/goods_storage_schema_test.gd"

# Regression test for Codex task B root cause 3 (manual_2 restore).
#
# NativeEconomyRuntime::end_restore() used to require every persisted building
# role fill to fit the current lot capacity
#   fills <= group.count * role.slots_per_building
# and rejected the whole save with restore_building_employee_job_invalid when
# that did not hold.  A demolition / investment step may shrink the lot count
# *before* the next employment settlement, so a committed save legitimately
# carries the previous job allocation on top of fewer remaining lots.  Restore
# now caps the historical fills by the persisted cohort employment of the same
# (cell, profession) instead of by the new lot capacity.
#
# (a) Accept: a real ECP2 stream is captured from a live one-cell economy with
#     a committed coal-mine group; the building record is rewritten to two
#     lots -> one lot (demolition) while keeping more role fills than the new
#     capacity, and a persisted cohort lane of the role profession is given an
#     employee_employed total that covers those fills.  The restore must
#     succeed and a further capture_economy_ecp2 -> restore_economy_ecp2 must
#     keep get_economy_state_hash() identical (roundtrip).
# (b) Reject: the same fixture with one role fill raised above the persisted
#     cohort employment total must still return
#     restore_building_employee_job_invalid.
#
# Everything goes through the real stream API
# (begin_economy_save / read_economy_save_chunk / feed_economy_restore_chunk /
# end_economy_restore); only the ECP2 bytes are edited between capture and
# restore, which is exactly how a save from an older build looks.

const SAVE_SECTION_PAGES := 1
const SAVE_SECTION_BUILDINGS := 5

# ECP2 chunk header: u32 magic, u16 schema, u16 section, u32 records, u32 bytes.
const ECP2_CHUNK_HEADER := 16
# SAVE_SECTION_PAGES record: i32 page, i32 next, i32 cell, then 64 lanes.
const COHORT_PAGE_SIZE := 64
const PAGE_RECORD_HEADER := 12
const LANE_STRIDE := 122
const LANE_ACTIVE := 0
const LANE_SIGNATURE := 1
const LANE_POPULATION := 9
const LANE_OWNER_EMPLOYED := 63
const LANE_EMPLOYEE_EMPLOYED := 71
const PAGE_RECORD_BYTES := PAGE_RECORD_HEADER + COHORT_PAGE_SIZE * LANE_STRIDE

# Schema-56 SAVE_SECTION_BUILDINGS record: i32 cell, i32 type, i32 owner
# signature, i64 count, ... fixed business payload ..., i32 roles, then
# roles * 9 x i64 (the first i64 of each role block is the fill count).
const BUILDING_RECORD_COUNT_AT := 12
const BUILDING_RECORD_FILLED_OWNER_AT := 20
const BUILDING_RECORD_ROLES_AT := 327
const BUILDING_RECORD_ROLE_DATA_AT := 331
const BUILDING_RECORD_ROLE_STRIDE := 72
const BUILDING_SCHEMA_VERSION := 56

const SOURCE_SEED := 4242
const SOURCE_TEMPERATURE := 0.5
const LOT_COUNT := 2
const SHRUNK_LOT_COUNT := 1
const UNSATISFIABLE_FILL_MARGIN := 10000000

func _run() -> void:
	print("=== economy building job restore regression ===")
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("building-regression catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		print(catalog)
		_finish()
		return
	var native_catalog: Dictionary = catalog.duplicate(true)
	native_catalog.erase("ok")
	var building_ids: PackedStringArray = native_catalog.building_type_ids
	var mine_id := building_ids.find("coal_mine")
	_expect("fixture building type coal_mine exists", mine_id >= 0)
	if mine_id < 0:
		_finish()
		return
	var role_slots := _role_slots(native_catalog, mine_id)
	_expect("fixture building exposes employee roles", role_slots.size() > 0
		and role_slots[0] > 0)
	if role_slots.is_empty():
		_finish()
		return
	print("  fixture coal_mine=%d role_slots=%s" % [mine_id, str(role_slots)])

	var profile: Dictionary = _building_profile()
	var source: Object = _configured_source(native_catalog, profile)
	if source == null:
		_finish()
		return
	var built: Dictionary = _build_committed_mine(source, native_catalog, mine_id)
	_expect("fixture commits a coal mine group",
		int(built.get("group_index", -1)) >= 0
		and int(built.get("count", 0)) == LOT_COUNT)
	if int(built.get("group_index", -1)) < 0:
		_finish()
		return
	print("  fixture committed count=%d filled_owner=%d" % [
		int(built.get("count", 0)), int(built.get("filled_owner", 0))])

	var country_chunks: Array[PackedByteArray] = _capture_country_chunks(source)
	var chunks: Array[PackedByteArray] = _capture_economy_chunks(source)
	_expect("fixture captures PKCN chunks", not country_chunks.is_empty())
	_expect("fixture captures PKEC chunks", chunks.size() >= 3)
	var buildings_chunk := _find_section_chunk(chunks, SAVE_SECTION_BUILDINGS)
	_expect("fixture captures a SAVE_SECTION_BUILDINGS chunk", buildings_chunk >= 0)
	if country_chunks.is_empty() or buildings_chunk < 0:
		_finish()
		return
	var schema_version := chunks[buildings_chunk].decode_u16(4)
	_expect("fixture ECP2 uses the covered schema version",
		schema_version == BUILDING_SCHEMA_VERSION)
	var records: Array = _decode_building_records(chunks[buildings_chunk])
	var target_record: Dictionary = {}
	for record in records:
		if int(record.cell) == 0 and int(record.type_id) == mine_id:
			target_record = record
			break
	_expect("fixture save contains the committed mine record",
		not target_record.is_empty() and int(target_record.count) == LOT_COUNT)
	if target_record.is_empty():
		_finish()
		return

	# The role we turn into the historical over-capacity fill.
	var profession_ids: PackedInt32Array = native_catalog.building_employee_profession_ids
	var employee_offsets: PackedInt32Array = native_catalog.building_employee_offsets
	var role_profession := int(profession_ids[int(employee_offsets[mine_id])])
	var profession_name := String(
		(native_catalog.profession_ids as PackedStringArray)[role_profession])
	var signature_keys: PackedStringArray = native_catalog.signature_keys
	var role_signature := signature_keys.find("%s|default" % profession_name)
	_expect("fixture finds the role profession signature", role_signature >= 0)
	if role_signature < 0:
		_finish()
		return
	var over_capacity_fills := SHRUNK_LOT_COUNT * int(role_slots[0]) + 1
	print("  plan role0_profession=%s signature=%d fills=%d shrunk_capacity=%d" % [
		profession_name, role_signature, over_capacity_fills,
		SHRUNK_LOT_COUNT * int(role_slots[0])])
	print("  saved record=", {
		"cell": int(target_record.cell), "type_id": int(target_record.type_id),
		"owner": int(target_record.owner_signature_id),
		"count": int(target_record.count), "filled_owner": int(target_record.filled_owner),
		"roles": int(target_record.roles), "fills": target_record.fills})

	# (a) Persist the demolition state: one remaining lot, while the last
	# committed job allocation survives on the same record.
	var accepted_chunks := _duplicate_chunks(chunks)
	var shrunk: PackedByteArray = accepted_chunks[buildings_chunk].duplicate()
	shrunk.encode_s64(int(target_record.at) + BUILDING_RECORD_COUNT_AT,
		SHRUNK_LOT_COUNT)
	shrunk.encode_s64(int(target_record.at) + BUILDING_RECORD_FILLED_OWNER_AT, 1)
	for role in range(int(target_record.roles)):
		shrunk.encode_s64(int(target_record.at) + BUILDING_RECORD_ROLE_DATA_AT
			+ role * BUILDING_RECORD_ROLE_STRIDE, 0)
	shrunk.encode_s64(int(target_record.at) + BUILDING_RECORD_ROLE_DATA_AT,
		over_capacity_fills)
	accepted_chunks[buildings_chunk] = shrunk
	var lane: Dictionary = _ensure_employed_lane(
		accepted_chunks, native_catalog, role_signature, over_capacity_fills)
	_expect("fixture persists a cohort lane covering the historical fills",
		bool(lane.get("ok", false)))
	if not bool(lane.get("ok", false)):
		print("  lane fixture failed: ", lane)
		_finish()
		return
	print("  accepted fixture lane=", lane)
	_expect("fixture fills exceed the shrunk lot capacity",
		_any_role_above_shrunk_capacity(
			PackedInt64Array([over_capacity_fills]), role_slots, SHRUNK_LOT_COUNT))

	var accepted: Dictionary = _restore_economy_fixture(
		native_catalog, profile, country_chunks, accepted_chunks)
	var accepted_result: Dictionary = accepted.result
	_expect("fills above the shrunk lot capacity restore successfully",
		bool(accepted_result.get("ok", false)))
	if not bool(accepted_result.get("ok", false)):
		print("  accepted restore rejected: ", accepted_result)
	else:
		var restored: Object = accepted.ext
		var saved: Dictionary = restored.capture_economy_ecp2(0)
		_expect("edited restore state captures again", bool(saved.get("ok", false)))
		var before_hash: int = restored.get_economy_state_hash()
		var roundtrip: Dictionary = restored.restore_economy_ecp2(
			saved.get("bytes", PackedByteArray()))
		_expect("capture/restore of the accepted state is hash exact",
			bool(roundtrip.get("ok", false))
			and int(restored.get_economy_state_hash()) == before_hash)
		if not bool(roundtrip.get("ok", false)):
			print("  accepted roundtrip rejected: ", roundtrip)

	# (b) Same fixture, same cell/profession, but the historical fill is larger
	# than everything the persisted cohorts could have employed there.
	var rejected_chunks := _duplicate_chunks(accepted_chunks)
	var inflated: PackedByteArray = rejected_chunks[buildings_chunk].duplicate()
	inflated.encode_s64(int(target_record.at) + BUILDING_RECORD_ROLE_DATA_AT,
		over_capacity_fills + UNSATISFIABLE_FILL_MARGIN)
	rejected_chunks[buildings_chunk] = inflated
	var rejected: Dictionary = _restore_economy_fixture(
		native_catalog, profile, country_chunks, rejected_chunks)
	var rejected_result: Dictionary = rejected.result
	_expect("fills above persisted cohort employment stay rejected",
		String(rejected_result.get("reason", "")) ==
			"restore_building_employee_job_invalid")
	if String(rejected_result.get("reason", "")) != "restore_building_employee_job_invalid":
		print("  rejection result: ", rejected_result)
	_finish()


func _building_profile() -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 5
	profile.market_runtime_mode = "ACTIVE"
	# Keep the fixture deterministic: no random family rolls / startup demand.
	profile.startup_demand_runtime_mode = "OFF"
	profile.family_runtime_mode = "OFF"
	# Focused fixture keeps the historical five-day market lock so the
	# construction boundary is stable on a one-cell world.
	profile.economy_cadence_force_market_days = 5
	profile.economy_cadence_force_slow_days = 10
	profile.economy_cadence_force_investment_days = 10
	profile.investment_review_days = 10
	return profile


func _configured_source(catalog: Dictionary, profile: Dictionary) -> Object:
	var ext: Object = _new_building_ext(catalog, 1, SOURCE_TEMPERATURE)
	_expect("fixture country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, SOURCE_SEED))
	_expect("fixture economy configures",
		bool(ext.configure_economy(catalog, profile, 1, SOURCE_SEED).get("ok", false)))
	var keys: PackedStringArray = catalog.signature_keys
	var signatures := PackedInt32Array()
	for key in ["industrialist|default", "miner|default", "manager|default",
			"merchant|default"]:
		var signature := keys.find(key)
		_expect("fixture signature %s exists" % key, signature >= 0)
		if signature < 0:
			return null
		signatures.append(signature)
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000000)
	# A real coal shortage makes the mine an executable employer; without it
	# the fixture building has no planned capacity.
	var goods: PackedStringArray = catalog.good_ids
	var coal_good := goods.find("coal")
	_expect("fixture catalog exposes the coal good", coal_good >= 0)
	if coal_good >= 0:
		stock[coal_good] = 0
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": signatures,
		"population": PackedInt64Array([5, 100, 10, 10]),
		"funds": PackedInt64Array(
			[1000000000000, 1000000, 1000000, 10000000]),
	}, {"stock": stock})
	_expect("fixture population and merchant bootstrap", bool(boot.get("ok", false)))
	# Give the cell a real coal deposit so the collector can extract at all.
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	var coal_resource := resource_ids.find("coal")
	if coal_resource >= 0:
		var coal_slot: int = ext.component_id(StringName(
			(catalog.building_resource_reserve_slots as PackedStringArray)[coal_resource]))
		_expect("fixture registers the coal reserve slot", coal_slot >= 0)
		if coal_slot >= 0:
			ext.write_f32_range(coal_slot, 0, PackedFloat32Array([1000000000000.0]))
	return ext


func _build_committed_mine(ext: Object, catalog: Dictionary,
		mine_id: int) -> Dictionary:
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var owner_signature := (catalog.signature_keys as PackedStringArray).find(
		"industrialist|default")
	var owner_row := (population.signature_ids as PackedInt32Array).find(owner_signature)
	var owner_handle := int((population.handles as PackedInt64Array)[owner_row]) \
		if owner_row >= 0 else 0
	_expect("fixture owner handle exists", owner_handle != 0)
	if owner_handle == 0:
		return {}
	var submit: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([10]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([owner_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([mine_id]),
		"i64_0": PackedInt64Array([LOT_COUNT]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("fixture build command accepted", bool(submit.get("ok", false)))
	if not bool(submit.get("ok", false)):
		return {}
	for day in range(3):
		var report: Dictionary = _run_building_day(ext, day)
		if not bool(report.get("done", false)):
			print("  fixture day %d did not commit: %s" % [day, report])
			return {}
		var buildings: Dictionary = ext.get_building_cell_snapshot(0)
		var group_type_ids: PackedInt32Array = buildings.get(
			"group_type_ids", PackedInt32Array())
		var group_index := group_type_ids.find(mine_id)
		print("  fixture day %d groups=%s counts=%s" % [
			day, str(group_type_ids), str(buildings.get("group_counts"))])
		if group_index >= 0:
			return {
				"group_index": group_index,
				"count": int((buildings.group_counts as PackedInt64Array)[group_index]),
				"filled_owner": int(
					(buildings.filled_owner as PackedInt64Array)[group_index]),
			}
	return {}


func _role_slots(catalog: Dictionary, type_id: int) -> PackedInt64Array:
	var offsets: PackedInt32Array = catalog.building_employee_offsets
	var slots: PackedInt64Array = catalog.building_employee_slots
	var out := PackedInt64Array()
	for role in range(int(offsets[type_id]), int(offsets[type_id + 1])):
		out.append(int(slots[role]))
	return out


func _any_role_above_shrunk_capacity(fills: PackedInt64Array,
		role_slots: PackedInt64Array, lot_count: int) -> bool:
	for role in range(mini(fills.size(), role_slots.size())):
		if int(fills[role]) > lot_count * int(role_slots[role]):
			return true
	return false


func _new_building_ext(catalog: Dictionary, cells: int, temperature: float) -> Object:
	var ext: Object = _new_ext(cells, temperature)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	var ecology_capacities: PackedInt64Array = \
		catalog.building_resource_ecology_capacity
	for i in range(resource_ids.size()):
		var reserve_sid: int = ext.register_component(
			StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(
			StringName(extra_slots[i]), 0, 1, false)
		var reserve := PackedFloat32Array()
		reserve.resize(cells)
		reserve.fill(maxf(1000.0,
			float(ecology_capacities[i]) / 1000.0 if
			i < ecology_capacities.size() else 1000.0))
		var extra := PackedFloat32Array()
		extra.resize(cells)
		extra.fill(0.0)
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, extra)
	return ext


func _run_building_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	var simulation_day := day * 5
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": simulation_day,
			"tick_index": simulation_day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _capture_country_chunks(ext: Object) -> Array[PackedByteArray]:
	var begin: Dictionary = ext.begin_country_save(65536)
	_expect("fixture PKCN save begins", bool(begin.get("ok", false)))
	var chunks: Array[PackedByteArray] = []
	while true:
		var bytes: PackedByteArray = ext.read_country_save_chunk(65536)
		if bytes.is_empty():
			break
		chunks.append(bytes)
	_expect("fixture PKCN save completes",
		bool(ext.end_country_save().get("ok", false)))
	return chunks


func _capture_economy_chunks(ext: Object) -> Array[PackedByteArray]:
	var begin: Dictionary = ext.begin_economy_save(65536)
	_expect("fixture PKEC save begins", bool(begin.get("ok", false)))
	var chunks: Array[PackedByteArray] = []
	while true:
		var bytes: PackedByteArray = ext.read_economy_save_chunk(65536)
		if bytes.is_empty():
			break
		chunks.append(bytes)
	_expect("fixture PKEC save completes",
		bool(ext.end_economy_save().get("ok", false)))
	return chunks


func _duplicate_chunks(chunks: Array[PackedByteArray]) -> Array[PackedByteArray]:
	var copy: Array[PackedByteArray] = []
	for chunk in chunks:
		copy.append(chunk)
	return copy


func _find_section_chunk(chunks: Array[PackedByteArray], section: int) -> int:
	for index in range(chunks.size()):
		if chunks[index].size() >= ECP2_CHUNK_HEADER \
				and chunks[index].decode_u16(6) == section:
			return index
	return -1


func _decode_building_records(chunk: PackedByteArray) -> Array:
	var records: Array = []
	if chunk.size() < ECP2_CHUNK_HEADER:
		return records
	var record_count := int(chunk.decode_u32(8))
	var at := ECP2_CHUNK_HEADER
	for _record in range(record_count):
		if at + BUILDING_RECORD_ROLE_DATA_AT > chunk.size():
			return []
		var roles := int(chunk.decode_s32(at + BUILDING_RECORD_ROLES_AT))
		var record_end := at + BUILDING_RECORD_ROLE_DATA_AT \
			+ roles * BUILDING_RECORD_ROLE_STRIDE
		if roles < 0 or record_end > chunk.size():
			return []
		var fills := PackedInt64Array()
		for role in range(roles):
			fills.append(chunk.decode_s64(
				at + BUILDING_RECORD_ROLE_DATA_AT + role * BUILDING_RECORD_ROLE_STRIDE))
		records.append({
			"at": at,
			"cell": chunk.decode_s32(at),
			"type_id": chunk.decode_s32(at + 4),
			"owner_signature_id": chunk.decode_s32(at + 8),
			"count": chunk.decode_s64(at + BUILDING_RECORD_COUNT_AT),
			"filled_owner": chunk.decode_s64(at + BUILDING_RECORD_FILLED_OWNER_AT),
			"roles": roles,
			"fills": fills,
		})
		at = record_end
	return records


func _scan_cell_lanes(chunks: Array[PackedByteArray], cell: int) -> Array:
	var lanes: Array = []
	for chunk_index in range(chunks.size()):
		var chunk: PackedByteArray = chunks[chunk_index]
		if chunk.size() < ECP2_CHUNK_HEADER \
				or chunk.decode_u16(6) != SAVE_SECTION_PAGES:
			continue
		var page_count := int(chunk.decode_u32(8))
		for page in range(page_count):
			var page_at := ECP2_CHUNK_HEADER + page * PAGE_RECORD_BYTES
			if page_at + PAGE_RECORD_BYTES > chunk.size():
				continue
			if chunk.decode_s32(page_at + 8) != cell:
				continue
			for lane in range(COHORT_PAGE_SIZE):
				var at := page_at + PAGE_RECORD_HEADER + lane * LANE_STRIDE
				if chunk[at + LANE_ACTIVE] == 0:
					continue
				lanes.append({
					"chunk_index": chunk_index,
					"at": at,
					"signature": int(chunk.decode_u32(at + LANE_SIGNATURE)),
					"population": int(chunk.decode_s64(at + LANE_POPULATION)),
					"owner_employed": int(chunk.decode_s64(at + LANE_OWNER_EMPLOYED)),
					"employee_employed": int(chunk.decode_s64(at + LANE_EMPLOYEE_EMPLOYED)),
				})
	return lanes


func _ensure_employed_lane(chunks: Array[PackedByteArray], catalog: Dictionary,
		signature: int, employed: int) -> Dictionary:
	var lanes := _scan_cell_lanes(chunks, 0)
	var target: Dictionary = {}
	for lane in lanes:
		if int(lane.signature) == signature:
			target = lane
			break
	var converted := false
	if target.is_empty():
		var signature_professions: PackedInt32Array = catalog.signature_profession_ids
		var profession_ids: PackedStringArray = catalog.profession_ids
		var unemployed_profession := profession_ids.find("unemployed")
		var merchant_profession := profession_ids.find("merchant")
		var industrialist_profession := profession_ids.find("industrialist")
		for lane in lanes:
			var lane_signature := int(lane.signature)
			if lane_signature >= signature_professions.size():
				continue
			if int(signature_professions[lane_signature]) != unemployed_profession:
				continue
			if int(lane.population) <= 0:
				continue
			target = lane
			break
		if target.is_empty():
			for lane in lanes:
				var lane_signature := int(lane.signature)
				if lane_signature >= signature_professions.size():
					continue
				var profession := int(signature_professions[lane_signature])
				if profession == merchant_profession \
						or profession == industrialist_profession \
						or profession == unemployed_profession:
					continue
				if int(lane.employee_employed) != 0 or int(lane.owner_employed) != 0:
					continue
				target = lane
				break
		if target.is_empty():
			return {"ok": false, "reason": "no_convertible_cohort_lane"}
		converted = true
	var chunk: PackedByteArray = chunks[int(target.chunk_index)].duplicate()
	var at := int(target.at)
	chunk.encode_u32(at + LANE_SIGNATURE, signature)
	chunk.encode_s64(at + LANE_OWNER_EMPLOYED, 0)
	chunk.encode_s64(at + LANE_EMPLOYEE_EMPLOYED, employed)
	chunk.encode_s64(at + LANE_POPULATION,
		maxi(int(target.population), employed))
	chunks[int(target.chunk_index)] = chunk
	return {
		"ok": true,
		"converted": converted,
		"chunk_index": int(target.chunk_index),
		"lane_at": at,
		"signature": signature,
		"employee_employed": employed,
		"population": maxi(int(target.population), employed),
	}


func _restore_economy_fixture(catalog: Dictionary, profile: Dictionary,
		country_chunks: Array[PackedByteArray],
		chunks: Array[PackedByteArray]) -> Dictionary:
	var ext: Object = _new_building_ext(catalog, 1, SOURCE_TEMPERATURE)
	var configured: Dictionary = ext.configure_economy(catalog, profile, 1, SOURCE_SEED)
	if not bool(configured.get("ok", false)):
		return {"ext": ext, "result": configured}
	ext.begin_country_restore()
	for chunk in country_chunks:
		ext.feed_country_restore_chunk(chunk)
	var country_result: Dictionary = ext.end_country_restore()
	if not bool(country_result.get("ok", false)):
		return {"ext": ext, "result": country_result}
	ext.begin_economy_restore()
	for chunk in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(fed.get("ok", false)):
			return {"ext": ext, "result": fed}
	return {"ext": ext, "result": ext.end_economy_restore()}
