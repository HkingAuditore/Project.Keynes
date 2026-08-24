extends SceneTree

# Headless:
#   godot --headless --script tests/canal_runtime_test.gd --quit
#
# Domain-API-only acceptance test.  It intentionally never mutates canal slots
# and never routes through PlayerController.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== canal runtime: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var fixture := _make_fixture(catalog)
	var ext: Object = fixture.ext
	var map: MapData = fixture.map
	var country_handle := int(fixture.country_handle)
	var start_cell := int(fixture.start_cell)
	var end_cell := int(fixture.end_cell)
	var direction := int(fixture.direction)
	var reverse := (direction + 3) % 6
	if ext == null or country_handle == 0 or end_cell < 0:
		return

	var before_query_hash := int(ext.get_economy_state_hash())
	var quote: Dictionary = ext.get_canal_route_quote(
		country_handle, start_cell, end_cell, PackedInt32Array())
	var required_keys := ["ok", "code", "message", "quote_token",
		"country_handle", "snapshot_day", "route_cells", "route_edge_dirs",
		"new_edge_count", "reused_edge_count", "source_kind", "cash_required",
		"construction_days", "material_good_ids", "material_quantities",
		"topology_hash", "country_generation"]
	var has_shape := true
	for key in required_keys:
		has_shape = has_shape and quote.has(key)
	_expect("quote exposes the stable facade contract",
		bool(quote.get("ok", false)) and has_shape
		and String(quote.get("source_kind", "")) == "freshwater")
	_expect("read-side quote does not change authoritative simulation hash",
		int(ext.get_economy_state_hash()) == before_query_hash)
	if not bool(quote.get("ok", false)):
		print("quote=", quote)
		return
	var token := int(quote.quote_token)
	var detail: Dictionary = ext.get_canal_route_quote_detail(country_handle, token)
	var forbidden: Dictionary = ext.get_canal_route_quote_detail(
		country_handle + (1 << 32), token)
	_expect("detail returns only the server-frozen route",
		bool(detail.get("ok", false))
		and (detail.route_cells as PackedInt32Array) ==
			(quote.route_cells as PackedInt32Array)
		and (detail.route_edge_dirs as PackedInt32Array) ==
			(quote.route_edge_dirs as PackedInt32Array))
	_expect("quote tokens are country isolated",
		String(forbidden.get("code", "")) == "canal_quote_forbidden")

	var queued: Dictionary = ext.queue_canal_construction(
		country_handle, token, 1, 17)
	_expect("domain construction API preserves formal command shape",
		bool(queued.get("ok", false)) and String(queued.get("code", "")) == "ok"
		and int(queued.get("effective_day", -1)) == 1
		and int(queued.get("sequence", -1)) == 17)
	var day_one := _run_day(ext, 1)
	_expect("effective-day economy settlement starts the project",
		bool(day_one.get("done", false)) and not bool(day_one.get("fatal", false)))
	var receipts: Dictionary = ext.get_canal_construction_receipts(
		country_handle, 0, 64)
	var rows: Array = receipts.get("receipts", [])
	_expect("settlement receipt carries payment attribution and project handle",
		rows.size() == 1 and bool(rows[0].get("ok", false))
		and int(rows[0].get("sequence", -1)) == 17
		and int(rows[0].get("project_handle", 0)) != 0
		and int(rows[0].get("treasury_goods_used", 0)) > 0
		and int(rows[0].get("market_goods_used", -1)) == 0)

	# Save and restore the building project on the same configured domain.  The
	# country treasury remains at the post-payment state, matching production's
	# DataCore -> Effect -> Economy restore order.
	var hash_before_restore := int(ext.get_economy_state_hash())
	var saved := _save_economy(ext)
	var restored: Dictionary = _restore_economy(ext, saved.get("chunks", []))
	var restored_report: Dictionary = ext.get_economy_report()
	if int(saved.get("schema", 0)) != 37 or not bool(restored.get("ok", false)) \
			or int(ext.get_economy_state_hash()) != hash_before_restore \
			or int(restored_report.get("canal_project_building_count", 0)) != 1:
		print("restore debug saved=", saved.get("schema", 0), " result=", restored,
			" hash_before=", hash_before_restore, " hash_after=",
			int(ext.get_economy_state_hash()), " report=", {
				"building": restored_report.get("canal_project_building_count", -1),
				"awaiting": restored_report.get("canal_project_awaiting_effect_count", -1),
				"projects": restored_report.get("canal_project_count", -1),
			})
	_expect("PKEC v42 restores an in-flight canal project exactly",
		int(saved.get("schema", 0)) == 39 and bool(restored.get("ok", false))
		and int(ext.get_economy_state_hash()) == hash_before_restore
		and int(restored_report.get("canal_project_building_count", 0)) == 1)

	var ready_day := 1 + int(quote.construction_days)
	var ready := _run_day(ext, ready_day)
	var awaiting_report: Dictionary = ext.get_economy_report()
	if int(awaiting_report.get("canal_project_awaiting_effect_count", 0)) != 1:
		print("ready debug day=", ready_day, " ready=", ready, " report=", {
			"building": awaiting_report.get("canal_project_building_count", -1),
			"awaiting": awaiting_report.get("canal_project_awaiting_effect_count", -1),
			"completed": awaiting_report.get("canal_project_completed_count", -1),
		})
	_expect("finished construction waits for the cross-domain Effect ACK",
		bool(ready.get("done", false))
		and int(awaiting_report.get("canal_project_awaiting_effect_count", 0)) == 1)
	var effect_bytes: PackedByteArray = ext.capture_effect_state()
	var effect_restored: Dictionary = ext.restore_effect_state(effect_bytes)
	_expect("PKEF preserves the unacknowledged built-in canal transaction",
		not effect_bytes.is_empty() and effect_bytes.size() >= 8
		and bool(effect_restored.get("ok", false)))
	var dispatched: Dictionary = ext.dispatch_effect_native_gameplay()
	var committed: Dictionary = ext.run_gameplay_effects(ready_day)
	_expect("Effect preflight and atomic geography commit complete",
		int(dispatched.get("submitted_transactions", 0)) == 1
		and int(committed.get("committed", 0)) == 1
		and int(committed.get("rejected", -1)) == 0)
	_expect("the committed edge is reciprocal and appears all at once",
		(map.canal_edge_mask_arr[start_cell] & (1 << direction)) != 0
		and (map.canal_edge_mask_arr[end_cell] & (1 << reverse)) != 0)
	var mask_after_first_commit := map.canal_edge_mask_arr.duplicate()
	var journal: Dictionary = ext.snapshot_gameplay_event_journal({})
	var journal_restored: Dictionary = ext.restore_gameplay_event_journal(journal)
	_expect("journal v4 persists custom geography-commit idempotency evidence",
		int(journal.get("version", 0)) == 4
		and bool(journal_restored.get("ok", false)))
	var replay_restored: Dictionary = ext.restore_effect_state(effect_bytes)
	var replay_dispatched: Dictionary = ext.dispatch_effect_native_gameplay()
	var replay_committed: Dictionary = ext.run_gameplay_effects(ready_day)
	var acknowledged: Dictionary = ext.ack_effect_native_gameplay()
	if not bool(replay_restored.get("ok", false)) \
			or int(replay_dispatched.get("submitted_transactions", 0)) != 1 \
			or int(replay_committed.get("committed", -1)) != 0 \
			or int(acknowledged.get("acknowledged", 0)) != 1 \
			or map.canal_edge_mask_arr != mask_after_first_commit:
		print("replay debug restore=", replay_restored, " dispatch=",
			replay_dispatched, " commit=", replay_committed, " ack=", acknowledged,
			" mask_same=", map.canal_edge_mask_arr == mask_after_first_commit)
	_expect("crash replay is idempotent and reaches ACK without a second write",
		bool(replay_restored.get("ok", false))
		and int(replay_dispatched.get("submitted_transactions", 0)) == 1
		and int(replay_committed.get("committed", -1)) == 0
		and int(replay_committed.get("rejected", -1)) == 0
		and int(acknowledged.get("acknowledged", 0)) == 1
		and map.canal_edge_mask_arr == mask_after_first_commit)
	var dirty: PackedInt32Array = ext.consume_canal_visual_dirty_cells()
	_expect("only the completed route is published as visual dirtiness",
		dirty.has(start_cell) and dirty.has(end_cell))
	_run_day(ext, ready_day + 1)
	var completed_report: Dictionary = ext.get_economy_report()
	if int(completed_report.get("canal_project_completed_count", 0)) != 1:
		print("complete debug report=", {
			"building": completed_report.get("canal_project_building_count", -1),
			"awaiting": completed_report.get("canal_project_awaiting_effect_count", -1),
			"completed": completed_report.get("canal_project_completed_count", -1),
			"failed": completed_report.get("canal_project_failed_count", -1),
			"edges": completed_report.get("canal_edge_count", -1),
		})
	_expect("Economy archives the bounded route only after ACK",
		int(completed_report.get("canal_project_completed_count", 0)) == 1
		and int(completed_report.get("canal_edge_count", 0)) == 1)

	var hydro_parent_before := map.hydro_parent_arr.duplicate()
	var soil_before := map.soil_moisture_arr.duplicate()
	var hydro: Dictionary = ext.run_runtime_hydrology_pass({
		"n_cells": map.cell_count(),
		"neighbor_indices": map.neighbor_indices_packed(),
		"dt_days": 1.0,
	})
	_expect("sparse daily hydrology detects a freshwater canal",
		bool(hydro.get("published_to_slot", false))
		and int(hydro.get("canal_edges_processed", 0)) == 1
		and int(hydro.get("canal_freshwater_cells", 0)) == 2
		and map.canal_water_arr[start_cell] > 0.0
		and map.canal_water_arr[end_cell] > 0.0)
	_expect("freshwater canal raises local soil/plant water",
		map.soil_moisture_arr[end_cell] > soil_before[end_cell]
		and map.plant_available_water_arr[end_cell] > 0.0)
	_expect("canal hydrology leaves the natural drainage DAG unchanged",
		map.hydro_parent_arr == hydro_parent_before)


func _make_fixture(catalog: Dictionary) -> Dictionary:
	const CELL_COUNT := 8
	var map := MapData.new(4, 2)
	for r in range(2):
		for q in range(4):
			var cell := HexCell.new(q, r)
			cell.terrain = TerrainType.TERRAIN.PLAIN
			cell.landform = LandformType.LF.PLAIN
			cell.elevation = 0.50
			cell.base_moisture = 0.10
			cell.moisture = 0.10
			if q == 0 and r == 0:
				cell.has_river = true
				cell.river_flow = 1.0
			map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	var neighbors := map.neighbor_indices_packed()
	var start_cell := 0
	var end_cell := -1
	var direction := -1
	for candidate_direction in range(6):
		var candidate := neighbors[start_cell * 6 + candidate_direction]
		if candidate >= 0 and candidate != start_cell:
			end_cell = candidate
			direction = candidate_direction
			break
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("map binds to native world", bool(ext.bind_map_data(map)))
	var effect_catalog := EffectCatalogScript.new()
	_expect("Effect runtime configures built-in canal transactions",
		bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get(
			"ok", false)))
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": catalog.technology_ids,
	}
	_expect("country runtime configures", bool(ext.configure_country(
		catalog, country_profile, CELL_COUNT, 260811).get("ok", false)))
	var technology_indices := PackedInt32Array()
	technology_indices.resize((catalog.technology_ids as PackedStringArray).size())
	for index in range(technology_indices.size()):
		technology_indices[index] = index
	var territory := PackedInt32Array()
	territory.resize(CELL_COUNT)
	for cell in range(CELL_COUNT):
		territory[cell] = cell
	var good_ids: PackedStringArray = catalog.good_ids
	var lumber := good_ids.find("lumber")
	var bricks := good_ids.find("bricks")
	var boot_country: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.canal_test"]),
		"country_names": PackedStringArray(["Canal Test"]),
		"country_cash": PackedInt64Array([1000000000]),
		"territory_offsets": PackedInt32Array([0, CELL_COUNT]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 2]),
		"treasury_good_indices": PackedInt32Array([lumber, bricks]),
		"treasury_quantities": PackedInt64Array([1000000, 1000000]),
	}, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]))
	_expect("single country owns the full quoted route",
		bool(boot_country.get("ok", false)))
	var country_handle := int(ext.get_country_cell_summary(0).country_handle)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "OFF"
	profile.notable_person_runtime_mode = "OFF"
	profile.market_cycle_days = 1
	_expect("economy runtime configures", bool(ext.configure_economy(
		catalog, profile, CELL_COUNT, 260811).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var forager := signatures.find("forager|default")
	var merchant := signatures.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize(CELL_COUNT * good_ids.size())
	stock.fill(1000000)
	_expect("economy bootstraps with a local public-works market", bool(
		ext.bootstrap_economy({
			"cell_indices": PackedInt32Array([0, 0]),
			"signature_ids": PackedInt32Array([forager, merchant]),
			"population": PackedInt64Array([10, 2]),
			"funds": PackedInt64Array([1000000, 1000000]),
		}, {"stock": stock}).get("ok", false)))
	var day_zero := _run_day(ext, 0)
	_expect("day zero captures geography, climate and trade topology",
		bool(day_zero.get("done", false)) and not bool(day_zero.get("fatal", false)))
	return {"ext": ext, "map": map, "country_handle": country_handle,
		"start_cell": start_cell, "end_cell": end_cell, "direction": direction}


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _save_economy(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var ended: Dictionary = ext.end_economy_save()
	return {"ok": bool(ended.get("ok", false)),
		"schema": int(begin.get("schema_version", 0)), "chunks": chunks}


func _restore_economy(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for chunk in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()
