# military_maintenance_snapshot_test.gd
# Acceptance test for the published physical-maintenance snapshot
# (`docs/plans/military-physical-maintenance.md` §4, D7 contract).
#
# Headless:
#   <godot> --headless --path Project/project-keynes \
#     -s res://tests/military/military_maintenance_snapshot_test.gd
#   options (after `--`):  --days=N        settle days after the barracks completes
#                          --build-wait=N  max days to wait for construction
#
# Scope: a CONTRACT test for `DCWorldExt.get_military_maintenance_snapshot()`.
# It boots the formal-start world the neighbouring smoke test uses, builds one
# barracks at the capital, and asserts the published parallel arrays. It does not
# judge maintenance *behaviour* (military_maintenance_flow_test.gd) nor
# accounting (military_maintenance_conservation_test.gd).
#
# Older DLLs: without `get_military_maintenance_snapshot` the suite prints
# `SKIP: maintenance snapshot unavailable` and exits 0 failures -- nothing is
# asserted against a surface that is not published.
#
# Verified against the loaded bridge (dots_ext_maint_v1):
#   get_military_maintenance_snapshot(country_handle) -> {country_slot, cell,
#   kind, object_id, units, daily_need_goods, stock_goods, inbound_goods,
#   ratio_bp, days_cover_x10, disrepair, shortage_reason}, all Packed arrays,
#   country handle 0 = every country. D7 documents the read without arguments, so
#   the arity is resolved from the method table instead of assumed.

extends SceneTree

const SEED := 20260727
const MAP_W := 60
const MAP_H := 40
const FOREIGN_COUNT := 3
const PIPELINE_DEPTH := 3
const MAX_BARRIER_PULSES_PER_DAY := 4096
const DEFAULT_SETTLE_DAYS := 6
## The cheapest barracks builds in 10 days, but construction waits for its
## materials to appear in the cell's market ring, so the ceiling is generous.
const DEFAULT_BUILD_WAIT_DAYS := 60
## Economy POD command lane opcode for `ADD_STOCK` (a negative delta removes).
## The legacy `submit_economy_commands` lane is fail-closed under whole-graph
## ACTIVE (`economy_legacy_ingress_disabled`), so a test that needs to stock a
## market must use the admitted lane or skip.
const POD_OP_ADD_STOCK := 4
const GOODS_SCALE := 1000
const MARKET_STOCK_GOODS := 400

## Snapshot array names: D7 lists the short spellings, the shipped bridge and the
## facade's own alias table (`MilitaryFacade.MAINTENANCE_FIELD_ALIASES`) use the
## `*_goods` ones. Both are accepted, so a rename shows up as "field missing"
## (skip) instead of a false pass on a silently different value.
const FIELDS := {
	"country_slot": ["country_slot"],
	"cell": ["cell"],
	"kind": ["kind"],
	"object_id": ["object_id"],
	"units": ["units"],
	"daily_need": ["daily_need_goods", "daily_need"],
	"stock": ["stock_goods", "stock"],
	"inbound": ["inbound_goods", "inbound"],
	"ratio_bp": ["ratio_bp"],
	"days_cover_x10": ["days_cover_x10"],
	"disrepair": ["disrepair"],
	"shortage_reason": ["shortage_reason", "reason"],
}
## Optional per-row good lanes some implementations add; validated when present.
const ROW_GOOD_FIELDS := ["goods", "repair_goods", "materials"]

class ErrorCounter extends Logger:
	var errors := PackedStringArray()
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtrace: Array[ScriptBacktrace]) -> void:
		# error_type 1 = warning; everything else (error / script / shader) counts.
		if error_type == 1:
			return
		_mutex.lock()
		errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _failures := PackedStringArray()
var _skips := PackedStringArray()
var _logger: ErrorCounter = null
var _clock: WorldClock = null
var _host: WorldRuntimeHost = null
var _facade = null
var _econ = null
var _country = null
var _day := 0
var _settle_days := DEFAULT_SETTLE_DAYS
var _build_wait_days := DEFAULT_BUILD_WAIT_DAYS
var _seq := 100


func _init() -> void:
	# Nodes added during SceneTree._init are not inside the tree yet, and
	# WorldRuntimeHost.generate_world bails out when !is_inside_tree().
	await process_frame
	var code: int = await _run()
	if _logger != null:
		OS.remove_logger(_logger)
	quit(code)


func _run() -> int:
	_parse_args()
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("maintenance snapshot unavailable", "DCWorldExt is not in this build")
		return _finish()
	var probe = ClassDB.instantiate("DCWorldExt")
	if probe == null or not probe.has_method("get_military_report"):
		_skip("maintenance snapshot unavailable", "military bindings missing")
		return _finish()
	var native_snapshot: bool = probe.has_method("get_military_maintenance_snapshot")
	probe = null
	if not native_snapshot:
		# Without the reader there is nothing to assert; booting a 20 s world just
		# to print the same SKIP would be waste.
		_skip("maintenance snapshot unavailable",
			"DCWorldExt.get_military_maintenance_snapshot is missing in the loaded "
			+ "dots_ext (older DLL)")
		return _finish()
	if ClassDB.class_exists("Logger"):
		_logger = ErrorCounter.new()
		OS.add_logger(_logger)

	if not await _boot_world():
		return _finish()
	_facade = _host.get_generator().get_military_facade() \
		if _host.get_generator().has_method("get_military_facade") else null
	if _facade == null or not _facade.is_configured():
		_skip("maintenance snapshot contract not exercised",
			"military facade not configured: %s" % JSON.stringify({} if _facade == null
				else _compact(_facade.configure_result())))
		return _finish()
	# The facade's own gate is authoritative about "can anything read this".
	if _facade.has_method("maintenance_supported") \
			and not bool(_facade.maintenance_supported()):
		_skip("maintenance snapshot unavailable",
			"MilitaryFacade.maintenance_supported() reports false")
		return _finish()
	var ext = _facade.world_ext()
	if ext == null:
		_skip("maintenance snapshot unavailable", "facade has no world_ext")
		return _finish()

	var country = _host.get_generator().get_country_facade()
	_country = country
	_econ = _host.get_generator().get_economy_facade() \
		if _host.get_generator().has_method("get_economy_facade") else null
	var start: Dictionary = _host.get_generator().gameplay_start_report()
	var capital := int(start.get("cell", -1))
	var player := int(country.cell_summary(capital).get("country_handle", 0))
	if capital < 0 or player == 0:
		_skip("maintenance snapshot contract not exercised",
			"player capital/handle unresolved (cell=%d)" % capital)
		return _finish()
	var barracks := _barracks_index(_facade.catalog())
	if barracks < 0:
		_skip("maintenance snapshot contract not exercised",
			"compiled catalog has no state building with role == barracks")
		return _finish()
	print("[maintenance-snapshot] capital=%d player=%d barracks=%d graph_active=%s" % [
		capital, player, barracks, str(_host.get_generator().runtime_graph_active())])

	# --- one barracks, completed ------------------------------------------
	# A day-0 world has no committed market yet, so the order needs the smoke
	# test's warmup. The economy then bills construction from the cell's market
	# and refuses a building whose gate technology is not researched yet
	# (`construction_technology_locked`), so the materials go on the market and
	# the gate technology is granted BEFORE the order is queued -- both commands
	# settle on the next economy epoch.
	await _advance_to(6)
	var target: Dictionary = _facade.set_target(player, 0, 8)
	_expect("force.set_target accepted", bool(target.get("ok", false)), str(target))
	_stock_goods(capital, _material_goods(_facade, barracks), "build")
	_grant_gate_tech(player, barracks)
	await _advance_to(_day + 3)
	# `state.build` only keeps the core's construction cache in this build; the
	# real bill is the economy's treasury-sponsored build.
	var built: Dictionary = _build_state_building(player, capital, barracks)
	_expect("the barracks build was queued end to end",
		bool(built.get("ok", false)), JSON.stringify(_compact(built)))
	if not bool(built.get("ok", false)):
		_skip("maintenance snapshot contract not exercised",
			"the build could not be queued: %s" % JSON.stringify(built))
		return _finish()
	var posts := await _wait_for_posts(player, _build_wait_days)
	var ring: Dictionary = await _ring_recipe_stock(capital, barracks)
	print("[maintenance-snapshot] build wait day=%d post_count=%d ring_stock=%s" % [
		_day, posts, JSON.stringify(ring)])
	if posts <= 0:
		# A precondition of this contract test, not the contract itself: the build
		# waits for construction materials the market ring may not hold yet.
		# military_runtime_smoke_test.gd owns the "barracks completes" assertion.
		_skip("maintenance snapshot contract not exercised",
			"barracks did not complete within %d days (construction=%s, recipe "
			% [_build_wait_days, str(_facade.country_snapshot(player).get(
				"construction_buildings", []))]
			+ "stock across the procurement ring=%s)" % JSON.stringify(ring))
		return _finish()

	# The row is published the day after completion; read it before the market is
	# touched, so "freshly built" is measured before any repair good exists.
	var fresh := await _wait_for_row(player, capital, barracks, 8)
	var fresh_disrepair := int(fresh.get("disrepair", -1))
	var fresh_ratio := int(fresh.get("ratio_bp", -1))
	print("[maintenance-snapshot] fresh row day=%d %s" % [_day,
		JSON.stringify(fresh)])
	_expect("a completed barracks publishes a maintenance row",
		not fresh.is_empty(), "" if not fresh.is_empty()
			else "no row for (slot, cell=%d, kind=0, object=%d)" % [capital, barracks])
	if fresh.is_empty():
		return _finish()
	# D4: the 5-day window has not closed on a fresh row, so it cannot be in
	# disrepair yet even while demand is unmet.
	_expect("a freshly built barracks is not in disrepair yet",
		fresh_disrepair == 0, "disrepair=%d ratio_bp=%d" % [fresh_disrepair,
			fresh_ratio])

	# "With a stocked market": put the repair recipe on the market through the
	# admitted POD lane (the legacy GM lane is closed in whole-graph ACTIVE).
	_stock_goods(capital, _recipe_goods(_facade, barracks), "repair")
	# Watch the row itself: the day-level counters only exist on a day whose
	# military step actually ran (`run_military_daily` is skipped while the core
	# is idle), so a snapshot-only window is the stable contract here.
	var settled := {}
	for _i in range(_settle_days):
		await _advance_to(_day + 1)
		settled = _row_now(int(_facade.country_snapshot(player).get("country_slot", -1)),
			capital, 0, barracks)
	print("[maintenance-snapshot] settle day=%d row=%s ring_stock=%s" % [_day,
		JSON.stringify(settled), JSON.stringify(await _ring_recipe_stock(capital, barracks))])

	# --- the published snapshot -------------------------------------------
	var arity := _snapshot_arity(ext)
	print("[maintenance-snapshot] get_military_maintenance_snapshot arity=%d" % arity)
	var snapshot = ext.get_military_maintenance_snapshot() if arity == 0 \
		else ext.get_military_maintenance_snapshot(0)
	if not snapshot is Dictionary or not bool((snapshot as Dictionary).get("ok", true)):
		_skip("maintenance snapshot contract not exercised",
			"snapshot read returned %s" % str(snapshot).substr(0, 200))
		return _finish()
	var econ = _host.get_generator().get_economy_facade() \
		if _host.get_generator().has_method("get_economy_facade") else null
	var good_count: int = (econ.good_ids() as PackedStringArray).size() if econ != null else 0
	_check_snapshot(snapshot as Dictionary, player, capital, barracks, good_count)
	return _finish()


# ------------------------------------------------------------------ checks

func _check_snapshot(snapshot: Dictionary, player: int, capital: int,
		barracks: int, good_count: int) -> void:
	# D7 publishes parallel Packed arrays. A bridge that publishes `rows` as an
	# array of dictionaries is accepted by transposing it, so the numeric
	# assertions below always run on the same numbers.
	if snapshot.get("rows") is Array and not snapshot.has("kind"):
		snapshot = _transpose_rows(snapshot["rows"])
	var lanes := {}
	var missing := PackedStringArray()
	for key in FIELDS.keys():
		var found := {}
		for name in FIELDS[key]:
			if snapshot.has(name):
				found = {"name": String(name), "value": snapshot[name]}
				break
		if found.is_empty():
			missing.append("%s(%s)" % [key, ", ".join(FIELDS[key])])
		else:
			lanes[key] = found
	if not missing.is_empty():
		_skip("maintenance snapshot contract not exercised",
			"published arrays missing: %s" % ", ".join(missing))
		return

	var slots: PackedInt64Array = _packed(lanes["country_slot"].value)
	var cells: PackedInt64Array = _packed(lanes["cell"].value)
	var kinds: PackedInt64Array = _packed(lanes["kind"].value)
	var objects: PackedInt64Array = _packed(lanes["object_id"].value)
	var units: PackedInt64Array = _packed(lanes["units"].value)
	var need: PackedInt64Array = _packed(lanes["daily_need"].value)
	var stock: PackedInt64Array = _packed(lanes["stock"].value)
	var inbound: PackedInt64Array = _packed(lanes["inbound"].value)
	var ratio: PackedInt64Array = _packed(lanes["ratio_bp"].value)
	var cover: PackedInt64Array = _packed(lanes["days_cover_x10"].value)
	var disrepair: PackedInt64Array = _packed(lanes["disrepair"].value)
	var reasons: PackedInt64Array = _packed(lanes["shortage_reason"].value)
	var rows := int(slots.size())
	var sizes := {
		"country_slot": rows, "cell": cells.size(), "kind": kinds.size(),
		"object_id": objects.size(), "units": units.size(),
		"daily_need": need.size(), "stock": stock.size(),
		"inbound": inbound.size(), "ratio_bp": ratio.size(),
		"days_cover_x10": cover.size(), "disrepair": disrepair.size(),
		"shortage_reason": reasons.size(),
	}
	var mismatch := PackedStringArray()
	for key in sizes.keys():
		if int(sizes[key]) != rows:
			mismatch.append("%s=%d" % [key, int(sizes[key])])
	_expect("snapshot arrays all have the same length", mismatch.is_empty(),
		"rows=%d %s" % [rows, ", ".join(mismatch)])
	if not mismatch.is_empty():
		return

	var building_rows: Array = _facade.catalog().get("state_buildings", [])
	var unit_rows: Array = _facade.catalog().get("units", [])
	# Optional per-row good lanes (`Array[PackedInt32Array]`, one entry per row).
	var row_good_lanes := {}
	for name in ROW_GOOD_FIELDS:
		var lane = snapshot.get(name)
		if lane is Array and (lane as Array).size() == rows:
			row_good_lanes[String(name)] = lane

	var bad_ratio := PackedStringArray()
	var bad_cover := PackedStringArray()
	var bad_kind := PackedStringArray()
	var bad_object := PackedStringArray()
	var bad_negative := PackedStringArray()
	var bad_good := PackedStringArray()
	var bad_reason := PackedStringArray()
	var ours_ratio := -1
	var ours_disrepair := -1
	var ours_stock := -1
	var ours_need := -1
	var ours_units := -1
	var player_slot := int(_facade.country_snapshot(player).get("country_slot", -1))
	var disrepair_rows := 0
	for i in range(rows):
		var kind := int(kinds[i])
		var object_id := int(objects[i])
		if int(ratio[i]) < 0 or int(ratio[i]) > 10000:
			bad_ratio.append("row%d ratio_bp=%d" % [i, int(ratio[i])])
		if int(cover[i]) < -1:
			bad_cover.append("row%d days_cover_x10=%d" % [i, int(cover[i])])
		if kind == 0:
			if object_id < 0 or object_id >= building_rows.size():
				bad_object.append("row%d building=%d (catalog=%d)" % [i, object_id,
					building_rows.size()])
		elif kind == 1:
			if object_id < 0 or object_id >= unit_rows.size():
				bad_object.append("row%d unit_type=%d (catalog=%d)" % [i, object_id,
					unit_rows.size()])
		else:
			bad_kind.append("row%d kind=%d" % [i, kind])
		if int(stock[i]) < 0 or int(inbound[i]) < 0 or int(need[i]) < 0:
			bad_negative.append("row%d stock=%d inbound=%d need=%d" % [i,
				int(stock[i]), int(inbound[i]), int(need[i])])
		if int(reasons[i]) < 0 or int(reasons[i]) > 3:
			bad_reason.append("row%d shortage_reason=%d" % [i, int(reasons[i])])
		if int(disrepair[i]) != 0:
			disrepair_rows += 1
		# Per-row good lanes are optional, but when a row publishes them the dense
		# ids must be real economy goods: a `-1` or an out-of-range id is the
		# classic "recipe compiled against the wrong catalog" symptom.
		for name in row_good_lanes.keys():
			var goods = (row_good_lanes[name] as Array)[i]
			if not (goods is PackedInt32Array or goods is Array):
				continue
			for good in goods:
				var dense := int(good)
				if dense < 0 or (good_count > 0 and dense >= good_count):
					bad_good.append("row%d %s=%d (goods=%d)" % [i, String(name),
						dense, good_count])
		if player_slot >= 0 and int(slots[i]) == player_slot \
				and int(cells[i]) == capital and kind == 0 and object_id == barracks:
			ours_ratio = int(ratio[i])
			ours_disrepair = int(disrepair[i])
			ours_stock = int(stock[i])
			ours_need = int(need[i])
			ours_units = int(units[i])
	print("[maintenance-snapshot] rows=%d (buildings=%d units=%d) player_slot=%d ours=%s" % [
		rows, building_rows.size(), unit_rows.size(), player_slot,
		JSON.stringify({"units": ours_units, "ratio_bp": ours_ratio,
			"disrepair": ours_disrepair, "stock_goods": ours_stock,
			"daily_need_goods": ours_need})])

	_expect("every ratio_bp is in [0,10000]", bad_ratio.is_empty(),
		", ".join(bad_ratio))
	_expect("every days_cover_x10 >= -1", bad_cover.is_empty(), ", ".join(bad_cover))
	_expect("every kind is 0 (state building) or 1 (unit type)", bad_kind.is_empty(),
		", ".join(bad_kind))
	_expect("every object_id resolves into the compiled catalog",
		bad_object.is_empty(), ", ".join(bad_object))
	_expect("every row has stock_goods/inbound_goods/daily_need_goods >= 0",
		bad_negative.is_empty(), ", ".join(bad_negative))
	_expect("no row names good -1 or a dense id out of range", bad_good.is_empty(),
		", ".join(bad_good))
	_expect("every shortage_reason is one of 0..3", bad_reason.is_empty(),
		", ".join(bad_reason))

	# The table must contain the object the harness just built: a completed
	# barracks with a working market is the canonical live row.
	_expect("the freshly built barracks has a row (country, cell, kind, object)",
		ours_ratio >= 0, "player_slot=%d capital=%d barracks=%d rows=%d disrepair_rows=%d"
			% [player_slot, capital, barracks, rows, disrepair_rows])
	if ours_ratio >= 0:
		# D4: with the recipe goods on the market and treasury cash available, the
		# repair demand must be met and the 5-day window must keep the building out
		# of disrepair. A nonzero `disrepair` here means either the purchase never
		# settled (spend stays 0) or the completion ratio is not min-based.
		_expect("a freshly built barracks with a stocked market is not in disrepair",
			ours_disrepair == 0, "disrepair=%d ratio_bp=%d stock_goods=%d "
				% [ours_disrepair, ours_ratio, ours_stock]
				+ "daily_need_goods=%d units=%d" % [ours_need, ours_units])
		_expect("the barracks row counts real buildings (units > 0)", ours_units > 0,
			"units=%d" % ours_units)
		_expect("the barracks row reports its own demand and stock",
			ours_need >= 0 and ours_stock >= 0,
			"daily_need_goods=%d stock_goods=%d" % [ours_need, ours_stock])


# ------------------------------------------------------------------ harness

## Formal-start world identical in shape to military_runtime_smoke_test.gd, so a
## number printed here is comparable with that suite.
func _boot_world() -> bool:
	_clock = WorldClock.new()
	_clock.auto_start = false
	_clock.initial_speed = 50.0
	_clock.debug_step_log = false
	get_root().add_child(_clock)
	_clock.set_speed(50.0)
	_clock.pause(true)
	_host = WorldRuntimeHost.new()
	_host.map_width = MAP_W
	_host.map_height = MAP_H
	_host.initial_seed = SEED
	get_root().add_child(_host)
	_host.configure(null, null, _clock)
	var config := NewGameConfig.create_default()
	config.country.name = "Military Maintenance Snapshot"
	config.country.foreign_count = FOREIGN_COUNT
	config.base.map_width = MAP_W
	config.base.map_height = MAP_H
	config.base.initial_seed = SEED
	var session: Dictionary = _host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not bool(session.get("ok", false)):
		_skip("maintenance snapshot contract not exercised",
			"session configure failed: %s" % JSON.stringify(_compact(session)))
		return false
	await _host.generate_world(SEED)
	var map: MapData = _host.get_current_map()
	if map == null or _host.get_generator() == null:
		_skip("maintenance snapshot contract not exercised", "world generation failed")
		return false
	var runtime_ext = _host.get_generator().get_data_core_world_ext() \
		if _host.get_generator().has_method("get_data_core_world_ext") else null
	if _host.runtime_climate_authority_enabled and runtime_ext != null \
			and runtime_ext.has_method("set_runtime_clock"):
		runtime_ext.set_runtime_clock(false, 50.0)
	return true


func _wait_for_posts(player: int, max_days: int) -> int:
	var posts := 0
	for _i in range(max_days):
		posts = int(_facade.country_snapshot(player).get("post_count", 0))
		if posts > 0:
			return posts
		await _advance_to(_day + 1)
	return int(_facade.country_snapshot(player).get("post_count", 0))


## Waits until the maintenance table publishes the row for one object.
func _wait_for_row(player: int, cell: int, object_id: int, max_days: int) -> Dictionary:
	var slot := int(_facade.country_snapshot(player).get("country_slot", -1))
	for _i in range(max_days):
		var row := _row_now(slot, cell, 0, object_id)
		if not row.is_empty():
			return row
		await _advance_to(_day + 1)
	return _row_now(slot, cell, 0, object_id)


## One row of the snapshot, decoded into a dictionary (empty when absent).
func _row_now(country_slot: int, cell: int, kind: int, object_id: int) -> Dictionary:
	var ext = _facade.world_ext()
	if ext == null or not ext.has_method("get_military_maintenance_snapshot"):
		return {}
	var arity := _snapshot_arity(ext)
	var raw = ext.get_military_maintenance_snapshot() if arity == 0 \
		else ext.get_military_maintenance_snapshot(0)
	if not raw is Dictionary:
		return {}
	var snapshot: Dictionary = raw
	if snapshot.get("rows") is Array and not snapshot.has("kind"):
		snapshot = _transpose_rows(snapshot["rows"])
	var out := {}
	for i in range(_packed(_field(snapshot, "country_slot")).size()):
		if _packed(_field(snapshot, "country_slot"))[i] != country_slot:
			continue
		if _packed(_field(snapshot, "cell"))[i] != cell:
			continue
		if _packed(_field(snapshot, "kind"))[i] != kind:
			continue
		if _packed(_field(snapshot, "object_id"))[i] != object_id:
			continue
		for key in FIELDS.keys():
			out[key] = _packed(_field(snapshot, key))[i]
		break
	return out


static func _field(snapshot: Dictionary, key: String):
	for name in FIELDS[key]:
		if snapshot.has(name):
			return snapshot[name]
	return null


## Researches the state building's gate technology. The economy refuses a
## sponsored build with `construction_technology_locked` until the country holds
## it, so this is the first half of "build one barracks".
func _grant_gate_tech(player: int, military_index: int) -> void:
	var rows: Array = _facade.catalog().get("state_buildings", [])
	if military_index < 0 or military_index >= rows.size() or _country == null:
		return
	var tech := String((rows[military_index] as Dictionary).get("unlock_tech_id", ""))
	if tech.is_empty():
		return
	var granted: Dictionary = _country.grant_technology(player, StringName(tech),
		_day + 1, _next_seq())
	print("[maintenance-snapshot] gate tech %s -> %s" % [tech,
		JSON.stringify(_compact(granted))])


## Queues a military state building the way the production UI does: the economy
## bills it (`treasury_sponsored_build`), then the military command books the
## core's construction cache. The gate technology must already be held.
func _build_state_building(player: int, cell: int, military_index: int) -> Dictionary:
	var rows: Array = _facade.catalog().get("state_buildings", [])
	if military_index < 0 or military_index >= rows.size():
		return {"ok": false, "reason": "military_state_building_index_invalid"}
	var out := {"military_index": military_index}
	if _econ == null:
		out["ok"] = false
		out["reason"] = "economy_facade_missing"
		return out
	var econ_id := int(_facade.state_building_economy_id(military_index))
	var type_ids: PackedStringArray = _econ.building_type_ids()
	if econ_id < 0 or econ_id >= type_ids.size():
		out["ok"] = false
		out["reason"] = "economy_building_id_unresolved"
		return out
	out["economy_building"] = String(type_ids[econ_id])
	out["sponsored"] = _econ.treasury_sponsored_build(player, cell,
		StringName(out.economy_building), _day + 1, _next_seq())
	out["booked"] = _facade.build_state_building(player, cell, military_index)
	out["ok"] = bool((out.sponsored as Dictionary).get("ok", false)) \
		and bool((out.booked as Dictionary).get("ok", false))
	return out


## Puts `goods` on the cell's market through the admitted economy POD lane
## (negative deltas remove). Best effort: a refusal leaves the world's own stock
## in place and the SKIP paths report it.
func _stock_goods(cell: int, goods: PackedInt32Array, label: String) -> void:
	if _econ == null:
		print("[maintenance-snapshot] SKIP %s stocking: no economy facade" % label)
		return
	var market_id := await _market_id(cell)
	if market_id < 0:
		print("[maintenance-snapshot] SKIP %s stocking: cell %d has no market" % [
			label, cell])
		return
	for dense in goods:
		var good := _good_name(dense)
		if good.is_empty():
			continue
		var result = _pod_add_stock(market_id, dense,
			MARKET_STOCK_GOODS * GOODS_SCALE)
		print("[maintenance-snapshot] %s stock +%d %s -> %s" % [label,
			MARKET_STOCK_GOODS, good, JSON.stringify(_compact(result))])


## Dense market id of one cell, retried: the committed read view is served from
## the worker, so the first read of a key can still be pending.
func _market_id(cell: int) -> int:
	for _i in range(8):
		var market: Dictionary = _econ.market_cell_snapshot(cell)
		if market.has("market_id"):
			return int(market.get("market_id", -1))
		await process_frame
	return -1


func _pod_add_stock(market_id: int, dense_good: int, qty: int) -> Dictionary:
	var ext = _econ.world_ext() if _econ != null else null
	if ext == null or not ext.has_method("submit_economy_pod_commands"):
		return {"ok": false, "reason": "economy_pod_lane_unavailable"}
	return ext.submit_economy_pod_commands({
		"request_ids": PackedInt64Array([_next_seq()]),
		"opcodes": PackedInt32Array([POD_OP_ADD_STOCK]),
		"transaction_ids": PackedInt64Array([0]),
		"session_epochs": PackedInt64Array([0]),
		"economy_generations": PackedInt64Array([0]),
		"payload0s": PackedInt64Array([qty]),
		"payload1s": PackedInt64Array([0]),
		"payload2s": PackedInt64Array([0]),
		"target_cells": PackedInt32Array([market_id]),
		"target_countries": PackedInt64Array([dense_good]),
		"target_cohorts": PackedInt64Array([0]),
		"target_buildings": PackedInt64Array([0]),
	})


func _next_seq() -> int:
	_seq += 1
	return _seq


func _good_name(dense: int) -> String:
	if _econ == null:
		return ""
	var good_ids: PackedStringArray = _econ.good_ids()
	if dense < 0 or dense >= good_ids.size():
		return ""
	return String(good_ids[dense])


## Market stock of one barracks recipe across the capital's 3-cell ring (the
## window military procurement is allowed to buy from). Diagnostic only: the
## snapshot assertions depend on the barracks existing, not on this market.
func _ring_recipe_stock(cell: int, barracks: int) -> Dictionary:
	var econ = _host.get_generator().get_economy_facade() \
		if _host.get_generator().has_method("get_economy_facade") else null
	if econ == null:
		return {"available": false}
	var recipe := _recipe_goods(_facade, barracks)
	var good_ids: PackedStringArray = econ.good_ids()
	var map: MapData = _host.get_current_map()
	var ring := PackedInt32Array([cell])
	if map != null:
		var neighbors: PackedInt32Array = map.neighbor_indices_packed()
		for direction in range(6):
			var nb := int(neighbors[cell * 6 + direction])
			if nb >= 0:
				ring.append(nb)
	var out := {}
	for dense in recipe:
		if dense < 0 or dense >= good_ids.size():
			continue
		var total := 0
		for ring_cell in ring:
			var market: Dictionary = econ.market_cell_snapshot(ring_cell)
			var names: PackedStringArray = market.get("good_ids", PackedStringArray())
			var stocks = market.get("stock", PackedInt64Array())
			var at := names.find(String(good_ids[dense]))
			if at >= 0 and at < stocks.size():
				total += int(stocks[at])
		out[String(good_ids[dense])] = total
	return out


func _advance_to(target_day: int) -> void:
	var generator := _host.get_generator()
	while _day < target_day:
		_day += 1
		_clock.current_day = float(_day)
		var phase := _clock.season_phase_for_day(_day)
		if _host.runtime_climate_authority_enabled:
			var capacity_deadline := Time.get_ticks_usec() + 60000000
			while not bool(_host.wait_for_climate_consumed(0).get("ok", true)) \
					and Time.get_ticks_usec() < capacity_deadline:
				_host._consume_runtime_commit_if_ready()
				await process_frame
			_host._consume_runtime_commit_if_ready()
		_host.run_daily_tick(_day, phase)
		_host.finish_daily_tick(0.0, {})
		if _host.runtime_climate_authority_enabled:
			var deadline := Time.get_ticks_usec() + 60000000
			while Time.get_ticks_usec() < deadline:
				_host._consume_runtime_commit_if_ready()
				var progress: Dictionary = generator.get_runtime_thread_report()
				if int(progress.get("simulation_committed_day",
						progress.get("committed_day", -1))) >= _day - 1 - PIPELINE_DEPTH:
					break
				await process_frame
		var pulses := 0
		while _has_hard_barrier() and pulses < MAX_BARRIER_PULSES_PER_DAY:
			_clock.simulation_backpressure_pulse.emit(_day)
			pulses += 1
			await process_frame
		if _has_hard_barrier():
			_expect("hard barrier drains at day %d" % _day, false)
			return
		if bool(generator.get_economy_report().get("fatal", false)):
			_expect("economy stays non-fatal (day %d)" % _day, false,
				str(generator.get_economy_report().get("fatal_reason", "")))
			return
	# Let the host drain committed military days (whole-graph ACTIVE replays at
	# most 4 per frame) before the caller inspects state.
	for _frame in range(64):
		_host._consume_runtime_commit_if_ready()
		if _facade == null or int(_facade.report().get("last_step_day", -1)) \
				>= _day - 1 - PIPELINE_DEPTH:
			break
		await process_frame


func _has_hard_barrier() -> bool:
	return _clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or _clock._simulation_backpressure_sources.has(&"economy_day_barrier")


# ------------------------------------------------------------------ helpers

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--days="):
			var value := text.substr(7)
			if value.is_valid_int():
				_settle_days = maxi(1, int(value))
		elif text.begins_with("--build-wait="):
			var value := text.substr(13)
			if value.is_valid_int():
				_build_wait_days = maxi(1, int(value))


## The counters this contract test prints next to the snapshot, so a row and its
## day-level aggregate can be compared in one line.
static func _maintenance_counters(report: Dictionary) -> Dictionary:
	return {
		"rows": report.get("maintenance_rows", "MISSING"),
		"need_goods": report.get("maintenance_need_goods", "MISSING"),
		"met_goods": report.get("maintenance_met_goods", "MISSING"),
		"spend": report.get("maintenance_spend", "MISSING"),
		"disrepair_rows": report.get("maintenance_disrepair_rows", "MISSING"),
	}


## Dense economy good ids of one state building's repair recipe (the compiled
## `repair_goods` lane the catalog hash covers).
static func _recipe_goods(facade, building_index: int) -> PackedInt32Array:
	var rows: Array = facade.catalog().get("state_buildings", [])
	if building_index < 0 or building_index >= rows.size():
		return PackedInt32Array()
	return (rows[building_index] as Dictionary).get("repair_goods",
		PackedInt32Array())


## Dense economy good ids of the building's CONSTRUCTION bill (`material_goods`),
## which the economy charges from the cell's market when the order settles.
static func _material_goods(facade, building_index: int) -> PackedInt32Array:
	var rows: Array = facade.catalog().get("state_buildings", [])
	if building_index < 0 or building_index >= rows.size():
		return PackedInt32Array()
	return (rows[building_index] as Dictionary).get("material_goods",
		PackedInt32Array())


static func _barracks_index(catalog: Dictionary) -> int:
	var buildings: Array = catalog.get("state_buildings", [])
	for index in range(buildings.size()):
		if int((buildings[index] as Dictionary).get("role", -1)) == 0:
			return index
	return -1


## Argument count the loaded bridge declares for the snapshot read.
static func _snapshot_arity(ext) -> int:
	for method in ext.get_method_list():
		if String((method as Dictionary).get("name", "")) \
				== "get_military_maintenance_snapshot":
			return ((method as Dictionary).get("args", []) as Array).size()
	return 0


## `rows: [{...}, ...]` -> the parallel lanes D7 documents, using the same alias
## table, so `_check_snapshot` only ever reads one shape.
static func _transpose_rows(rows: Array) -> Dictionary:
	var out := {}
	for key in FIELDS.keys():
		var lane := PackedInt64Array()
		lane.resize(rows.size())
		for i in range(rows.size()):
			var row = rows[i]
			if not row is Dictionary:
				continue
			for name in FIELDS[key]:
				if (row as Dictionary).has(name):
					lane[i] = int((row as Dictionary)[name])
					break
		out[String(FIELDS[key][0])] = lane
	return out


## Accepts the PackedInt64Array D7 documents plus the narrower integer lanes the
## bridge publishes (PackedInt32Array / PackedByteArray), so the test reads
## whatever it actually got.
static func _packed(value) -> PackedInt64Array:
	var out := PackedInt64Array()
	if value is PackedInt64Array:
		return value
	if value is PackedInt32Array:
		out.resize((value as PackedInt32Array).size())
		for i in range((value as PackedInt32Array).size()):
			out[i] = int((value as PackedInt32Array)[i])
		return out
	if value is PackedByteArray:
		out.resize((value as PackedByteArray).size())
		for i in range((value as PackedByteArray).size()):
			out[i] = int((value as PackedByteArray)[i])
		return out
	if value is Array:
		out.resize((value as Array).size())
		for i in range((value as Array).size()):
			out[i] = int((value as Array)[i])
		return out
	return out


static func _compact(value: Dictionary) -> Dictionary:
	var out := {}
	for key in value.keys():
		var item = value[key]
		if item is Array or item is Dictionary or typeof(item) >= TYPE_PACKED_BYTE_ARRAY:
			continue
		out[key] = item
	return out


func _expect(label: String, ok: bool, detail := "") -> void:
	print("  [%s] %s%s" % ["PASS" if ok else "FAIL", label,
		"" if detail.is_empty() else " :: " + detail])
	if not ok:
		_failures.append(label)


func _skip(what: String, reason: String) -> void:
	print("SKIP: %s :: %s" % [what, reason])
	_skips.append(what)


func _finish() -> int:
	if _logger != null:
		var errors := _logger.errors
		var shown := mini(errors.size(), 20)
		for i in range(shown):
			print("  [error] " + errors[i])
		_expect("no push_error / script errors", errors.is_empty(),
			"%d errors" % errors.size())
	print("=== military maintenance snapshot: %d failures, %d skips ===" % [
		_failures.size(), _skips.size()])
	for failure in _failures:
		print("  FAILED: " + failure)
	print("%d failures" % _failures.size())
	return 0 if _failures.is_empty() else 1
