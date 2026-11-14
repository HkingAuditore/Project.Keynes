# military_maintenance_conservation_test.gd
# Conservation / accounting acceptance test for physical military maintenance
# (`docs/plans/military-physical-maintenance.md` §3 S1-8, S4-8, S5-1, S5-5, §4).
#
# Headless:
#   <godot> --headless --path Project/project-keynes \
#     -s res://tests/military/military_maintenance_conservation_test.gd
#   options (after `--`):  --days=N        world window length (default 30)
#                          --build-wait=N  max days to wait for construction
#
# Three sections, each useful on its own:
#
#  1. NATIVE LEDGER (always runs). A bare `DCWorldExt` configured with a minimal
#     catalog and a 2x2 synthetic terrain is stepped for >= 30 days. With no
#     Country/Economy attached no goods can move, so this proves the daily loop
#     and `reconcile_ledger()` bookkeeping do not drift -- it is explicitly NOT
#     the world-level identity, which section 3 owns.
#
#  2. PKMI ROUND TRIP (always runs, and is the section that matters most today).
#     encode -> restore -> encode must be byte identical with an unchanged
#     state_hash; a rejected restore must be transactional (live hash unchanged);
#     a truncated stream must be refused, not crash; and a version field patched
#     DOWN must be refused with `pkmi_version_mismatch`.
#     Layout: the bridge wraps the core PKMI stream as
#       u32 magic | u32 wrapper_version | u32 core_size | core PKMI bytes | ...
#     so the PKMI magic sits at offset 12 and the *core* version u32 at
#     `pkmi_magic + 4`. Both version fields are patched and both must be
#     rejected; the reason for the core one must contain `pkmi_version_mismatch`
#     (that is the "patch the u32 at offset 4" case, read on the PKMI stream).
#
#  3. WORLD ACCOUNTING (skipped when the harness cannot build a barracks).
#     >= 30 stepped days with `reconcile_delta == 0` every day, a save ->
#     restore -> save round trip, then >= 3 more days with no negative stock and
#     the ledger still balanced. The purchase-outstanding half needs a barracks
#     in a cell whose market is one cell away; the early-game player owns exactly
#     one cell, so that precondition is reported as a SKIP instead of being
#     faked.

extends SceneTree

const SEED := 20260727
const MAP_W := 60
const MAP_H := 40
const FOREIGN_COUNT := 3
const PIPELINE_DEPTH := 3
const MAX_BARRIER_PULSES_PER_DAY := 4096
const BARE_DAYS := 30
const DEFAULT_WORLD_DAYS := 30
const DEFAULT_BUILD_WAIT_DAYS := 60
const POST_RESTORE_DAYS := 4
## Economy POD lane opcode for `ADD_STOCK`; the legacy GM lane is fail-closed
## under whole-graph ACTIVE.
const POD_OP_ADD_STOCK := 4
const GOODS_SCALE := 1000
const STOCK_QTY := 400

const PKMI_MAGIC := 0x494d4b50  # "PKMI" little endian
const CORE_OFFSET := 12         # magic + wrapper version + core size

class ErrorCounter extends Logger:
	var errors := PackedStringArray()
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtrace: Array[ScriptBacktrace]) -> void:
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
var _country = null
var _econ = null
var _day := 0
var _world_days := DEFAULT_WORLD_DAYS
var _build_wait_days := DEFAULT_BUILD_WAIT_DAYS
var _capital := -1
var _player := 0
var _seq := 300


func _init() -> void:
	await process_frame
	var code: int = await _run()
	if _logger != null:
		OS.remove_logger(_logger)
	quit(code)


func _run() -> int:
	_parse_args()
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("conservation", "DCWorldExt is not in this build")
		return _finish()
	if ClassDB.class_exists("Logger"):
		_logger = ErrorCounter.new()
		OS.add_logger(_logger)
	var ext = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("configure_military") \
			or not ext.has_method("run_military_daily"):
		_skip("conservation", "military bindings missing in the loaded dots_ext")
		return _finish()

	var core_ok := await _section_native_ledger(ext)
	if core_ok:
		_section_pkmi(ext)
	await _section_world()
	return _finish()


# ------------------------------------------------------- 1. native ledger

## Bare core + synthetic terrain: >= 30 days of the native daily loop with no
## Country/Economy attached. Nothing can be bought, delivered or eaten, so the
## only thing under test is that `reconcile_ledger()` stays exactly 0 and the day
## cursor advances (the identity must not drift on an idle world).
func _section_native_ledger(ext) -> bool:
	var catalog := {
		"units": [{"id": "militia", "militia": true, "attack": 0.5,
			"defense": 0.6, "speed": 1.0, "training_days": 0}],
		"state_buildings": [],
	}
	var configured: Dictionary = ext.configure_military(catalog, SEED)
	_expect("bare core configures from a minimal catalog",
		bool(configured.get("ok", false)), str(configured))
	if not bool(configured.get("ok", false)):
		_skip("native ledger run", "core did not configure: %s"
			% str(configured.get("reason", "")))
		return false
	# 2x2 hex box with no adjacency: enough for the daily loop, too small to hold
	# a procurement ring, so no goods can ever move.
	var neighbors := PackedInt32Array()
	neighbors.resize(4 * 6)
	neighbors.fill(-1)
	var terrain: Dictionary = ext.set_military_terrain({
		"cell_count": 4, "width": 2, "height": 2, "neighbors": neighbors,
		"landform": PackedByteArray([0, 0, 0, 0]),
		"vegetation": PackedByteArray([0, 0, 0, 0]),
		"cover": PackedByteArray([0, 0, 0, 0]),
		"is_water": PackedByteArray([0, 0, 0, 0]),
		"has_river": PackedByteArray([0, 0, 0, 0]),
		"settlement_tier": PackedByteArray([0, 0, 0, 0]),
	})
	_expect("bare core takes a synthetic terrain", bool(terrain.get("ok", false)),
		str(terrain))
	if not bool(terrain.get("ok", false)):
		return false

	var bad: PackedStringArray = []
	for day in range(1, BARE_DAYS + 1):
		var report: Dictionary = ext.run_military_daily({"day_index": day})
		if not bool(report.get("ok", false)):
			_skip("native ledger run", "day %d refused: %s" % [day,
				str(report.get("reason", ""))])
			return false
		if int(report.get("reconcile_delta", -1)) != 0:
			bad.append("day%d delta=%d" % [day, int(report.get("reconcile_delta", 0))])
		if int(report.get("maintenance_spend", -1)) != 0:
			bad.append("day%d spend=%d on an empty world" % [day,
				int(report.get("maintenance_spend", 0))])
	var final: Dictionary = ext.get_military_report()
	print("[maintenance-conservation] bare ledger days=%d last_step_day=%s ledger=%s" % [
		BARE_DAYS, str(final.get("last_step_day", -1)), JSON.stringify({
			"received": final.get("ledger_received", "MISSING"),
			"consumed": final.get("ledger_consumed", "MISSING"),
			"stock": final.get("ledger_stock", "MISSING"),
			"transit": final.get("ledger_transit", "MISSING"),
			"reconcile_delta": final.get("reconcile_delta", "MISSING")})])
	_expect("native ledger: reconcile_delta == 0 on every one of %d days"
		% BARE_DAYS, bad.is_empty(), ", ".join(bad))
	_expect("native ledger: the day cursor advanced through the run",
		int(final.get("last_step_day", -1)) == BARE_DAYS,
		"last_step_day=%s" % str(final.get("last_step_day", -1)))
	return true


# --------------------------------------------------------------- 2. PKMI

## The save contract: encode -> restore -> encode is byte identical, the hash is
## preserved, a rejected restore is transactional, and a lowered version field is
## refused with `pkmi_version_mismatch` (never a crash).
func _section_pkmi(ext) -> void:
	var bytes: PackedByteArray = ext.encode_military_state()
	_expect("PKMI encodes", not bytes.is_empty(), "bytes=%d" % bytes.size())
	if bytes.is_empty():
		return
	var hash_before := int(ext.get_military_report().get("state_hash", 0))
	var restored: Dictionary = ext.restore_military_state(bytes)
	_expect("PKMI restores its own stream", bool(restored.get("ok", false)),
		str(restored))
	var hash_after := int(ext.get_military_report().get("state_hash", 0))
	_expect("PKMI encode -> restore preserves state_hash", hash_after == hash_before,
		"%d -> %d" % [hash_before, hash_after])
	var again: PackedByteArray = ext.encode_military_state()
	_expect("PKMI re-encode is byte identical", again == bytes,
		"%d vs %d bytes" % [again.size(), bytes.size()])

	var core_offset := _find_magic(bytes)
	print("[maintenance-conservation] pkmi bytes=%d core_offset=%d version=%d" % [
		bytes.size(), core_offset, _read_u32(bytes, core_offset + 4)
			if core_offset >= 0 else -1])
	if core_offset < 0:
		_skip("PKMI version rejection",
			"the PKMI magic is not inside the encoded bytes; the wrapper layout "
			+ "changed and this test needs updating")
		return

	# (a) the core stream's version u32, i.e. "the u32 at offset 4" of PKMI.
	var core_version := _read_u32(bytes, core_offset + 4)
	var patched := bytes.duplicate()
	_write_u32(patched, core_offset + 4, maxi(0, core_version - 1))
	var rejected: Dictionary = ext.restore_military_state(patched)
	var reason := String(rejected.get("reason", rejected.get("code", "")))
	_expect("PKMI rejects a lower core version with pkmi_version_mismatch",
		not bool(rejected.get("ok", true)) and reason.contains("pkmi_version_mismatch"),
		"ok=%s reason=%s (patched %d -> %d at offset %d)" % [
			str(rejected.get("ok", true)), reason, core_version,
			maxi(0, core_version - 1), core_offset + 4])
	var hash_after_reject := int(ext.get_military_report().get("state_hash", 0))
	_expect("a rejected PKMI version leaves the live state untouched",
		hash_after_reject == hash_before, "%d -> %d" % [hash_before,
			hash_after_reject])

	# (b) the wrapper version u32 at byte offset 4 of the encoded stream.
	var wrapper_version := _read_u32(bytes, 4)
	var wrapper_patched := bytes.duplicate()
	_write_u32(wrapper_patched, 4, maxi(0, wrapper_version - 1))
	var wrapper_rejected: Dictionary = ext.restore_military_state(wrapper_patched)
	var wrapper_reason := String(wrapper_rejected.get("reason",
		wrapper_rejected.get("code", "")))
	_expect("PKMI rejects a lower wrapper version at byte offset 4",
		not bool(wrapper_rejected.get("ok", true)) \
			and wrapper_reason.contains("version_mismatch"),
		"ok=%s reason=%s (patched %d -> %d)" % [
			str(wrapper_rejected.get("ok", true)), wrapper_reason,
			wrapper_version, maxi(0, wrapper_version - 1)])

	# (c) truncated stream: refused, not a crash, and the live state survives.
	var truncated := bytes.slice(0, maxi(0, int(bytes.size() / 2)))
	var trunc_result: Dictionary = ext.restore_military_state(truncated)
	_expect("a truncated PKMI stream is refused without touching the state",
		not bool(trunc_result.get("ok", true)), str(trunc_result))
	_expect("the live state still round-trips after the refused restores",
		ext.encode_military_state() == bytes,
		"%d vs %d bytes" % [(ext.encode_military_state() as PackedByteArray).size(),
			bytes.size()])


# ------------------------------------------------------------- 3. world

## World accounting: the goods identity over >= 30 stepped days, then a save ->
## restore -> save round trip and >= 3 more days with no negative stock and the
## ledger still balanced.
func _section_world() -> void:
	if not await _boot_world():
		return
	_facade = _host.get_generator().get_military_facade() \
		if _host.get_generator().has_method("get_military_facade") else null
	if _facade == null or not _facade.is_configured():
		_skip("world accounting", "military facade not configured: %s"
			% JSON.stringify({} if _facade == null
				else _compact(_facade.configure_result())))
		return
	_country = _host.get_generator().get_country_facade() \
		if _host.get_generator().has_method("get_country_facade") else null
	_econ = _host.get_generator().get_economy_facade() \
		if _host.get_generator().has_method("get_economy_facade") else null
	var start: Dictionary = _host.get_generator().gameplay_start_report()
	_capital = int(start.get("cell", -1))
	_player = int(_country.cell_summary(_capital).get("country_handle", 0))
	var barracks := _role_index(_facade.catalog(), 0)
	if _capital < 0 or _player == 0 or barracks < 0:
		_skip("world accounting", "capital/handle/barracks unresolved (cell=%d handle=%d barracks=%d)"
			% [_capital, _player, barracks])
		return

	await _advance_to(6)
	_facade.set_target(_player, 0, 8)
	# The economy bills construction from the cell's market and refuses a building
	# whose gate technology is not researched (`construction_technology_locked`),
	# so the harness stocks the build materials and grants the gate first; both
	# settle on the next economy epoch. `state.build` alone only books a cache.
	await _stock_goods(_capital, _material_goods(barracks), "build")
	_grant_gate_tech(barracks)
	await _advance_to(_day + 3)
	var built: Dictionary = _build_state_building(barracks)
	print("[maintenance-conservation] build queued=%s" % JSON.stringify(
		_compact(built)))
	var posts := 0
	for _i in range(_build_wait_days):
		posts = int(_facade.country_snapshot(_player).get("post_count", 0))
		if posts > 0:
			break
		await _advance_to(_day + 1)
	if posts <= 0:
		_skip("world accounting", "no barracks completed within %d days, so no "
			% _build_wait_days + "maintenance purchase can ever be made "
			+ "(construction materials never reached the cell)")
		return

	# --- >= 30 days with a balanced ledger --------------------------------
	var bad_balance := PackedStringArray()
	var bad_stock := PackedStringArray()
	var spend_total := 0
	var cash_floor := -1
	var max_cash := 0
	var backlog_days := 0
	for _i in range(_world_days):
		await _advance_to(_day + 1)
		var report: Dictionary = _facade.report()
		var daily: Dictionary = _facade.last_daily_report()
		if int(report.get("reconcile_delta", -1)) != 0:
			bad_balance.append("day%d delta=%d" % [_day,
				int(report.get("reconcile_delta", 0))])
		if int(report.get("ledger_stock", -1)) < 0 \
				or int(report.get("ledger_transit", -1)) < 0:
			bad_stock.append("day%d stock=%s transit=%s" % [_day,
				str(report.get("ledger_stock", "?")), str(report.get("ledger_transit", "?"))])
		spend_total += int(daily.get("maintenance_spend", 0))
		if int(daily.get("maintenance_backlog", 0)) > 0:
			backlog_days += 1
		var cash := int(_country.treasury_snapshot(_player).get("cash", 0))
		max_cash = maxi(max_cash, cash)
		if cash_floor < 0 or cash < cash_floor:
			cash_floor = cash
	print("[maintenance-conservation] world days=%d spend_total=%d backlog_days=%d cash=%d..%d" % [
		_world_days, spend_total, backlog_days, cash_floor, max_cash])
	_expect("world: reconcile_delta == 0 on every one of %d stepped days"
		% _world_days, bad_balance.is_empty(), ", ".join(bad_balance))
	_expect("world: ledger_stock / ledger_transit are never negative",
		bad_stock.is_empty(), ", ".join(bad_stock))
	# Money leaves the treasury for real settled purchases only, so the sum booked
	# cannot exceed the cash the country actually held (S1-4 / D5).
	_expect("world: settled maintenance spend never exceeds the treasury cash",
		spend_total <= max_cash, "spend=%d max_cash=%d" % [spend_total, max_cash])
	if backlog_days == 0:
		_skip("purchase outstanding across a save",
			"no day reported maintenance_backlog > 0, so there was no paid-but-"
			+ "undelivered purchase to save; a convoy also needs a barracks one "
			+ "cell from a market and the early-game country owns a single cell")
		_skip("treasury debits == settled purchase amounts",
			"no per-category cashflow telemetry: get_country_treasury_snapshot "
			+ "exposes only cash/good_ids/quantities, so a maintenance debit cannot "
			+ "be separated from tax, wages and general procurement")

	# --- save -> restore -> save -----------------------------------------
	var hash_before := int(_facade.state_hash())
	var bytes: PackedByteArray = _facade.encode_state()
	_expect("world: PKMI encodes", not bytes.is_empty(), "bytes=%d" % bytes.size())
	if bytes.is_empty():
		return
	var restored: Dictionary = _facade.restore_state(bytes)
	_expect("world: PKMI restores", bool(restored.get("ok", false)), str(restored))
	_expect("world: restore preserves state_hash",
		int(_facade.state_hash()) == hash_before, "%d -> %d" % [hash_before,
			int(_facade.state_hash())])
	_expect("world: re-encode is byte identical", _facade.encode_state() == bytes,
		"%d vs %d bytes" % [(_facade.encode_state() as PackedByteArray).size(),
			bytes.size()])

	# --- continue after the restore --------------------------------------
	var continued_bad := PackedStringArray()
	for _i in range(POST_RESTORE_DAYS):
		await _advance_to(_day + 1)
		var report: Dictionary = _facade.report()
		if int(report.get("reconcile_delta", -1)) != 0:
			continued_bad.append("day%d delta=%d" % [_day,
				int(report.get("reconcile_delta", 0))])
		if int(report.get("ledger_stock", -1)) < 0 \
				or int(report.get("ledger_transit", -1)) < 0:
			continued_bad.append("day%d stock/transit negative" % _day)
	print("[maintenance-conservation] continued days=%d bad=%s" % [
		POST_RESTORE_DAYS, ", ".join(continued_bad)])
	_expect("world: %d days after the restore keep the ledger balanced and "
		% POST_RESTORE_DAYS + "non-negative (no duplicated or vanished goods)",
		continued_bad.is_empty(), ", ".join(continued_bad))


# ------------------------------------------------------------------ harness

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
	# NewGameConfig caps the country name at 32 characters.
	config.country.name = "Military Maintenance Conserve"
	config.country.foreign_count = FOREIGN_COUNT
	config.base.map_width = MAP_W
	config.base.map_height = MAP_H
	config.base.initial_seed = SEED
	var session: Dictionary = _host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not bool(session.get("ok", false)):
		_skip("world accounting", "session configure failed: %s"
			% JSON.stringify(_compact(session)))
		return false
	await _host.generate_world(SEED)
	if _host.get_current_map() == null or _host.get_generator() == null:
		_skip("world accounting", "world generation failed")
		return false
	var runtime_ext = _host.get_generator().get_data_core_world_ext() \
		if _host.get_generator().has_method("get_data_core_world_ext") else null
	if _host.runtime_climate_authority_enabled and runtime_ext != null \
			and runtime_ext.has_method("set_runtime_clock"):
		runtime_ext.set_runtime_clock(false, 50.0)
	return true


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
	for _frame in range(64):
		_host._consume_runtime_commit_if_ready()
		if _facade == null or int(_facade.report().get("last_step_day", -1)) \
				>= _day - 1 - PIPELINE_DEPTH:
			break
		await process_frame


func _has_hard_barrier() -> bool:
	return _clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or _clock._simulation_backpressure_sources.has(&"economy_day_barrier")


# ------------------------------------------------------------------ bytes

## Offset of the "PKMI" magic inside the bridge wrapper (-1 when absent).
static func _find_magic(bytes: PackedByteArray) -> int:
	for offset in range(0, maxi(0, bytes.size() - 4)):
		if _read_u32(bytes, offset) == PKMI_MAGIC:
			return offset
	return -1


static func _read_u32(bytes: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + 4 > bytes.size():
		return -1
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8) \
		| (int(bytes[offset + 2]) << 16) | (int(bytes[offset + 3]) << 24)


static func _write_u32(bytes: PackedByteArray, offset: int, value: int) -> void:
	if offset < 0 or offset + 4 > bytes.size():
		return
	for i in range(4):
		bytes[offset + i] = (value >> (i * 8)) & 0xFF


# ------------------------------------------------------------------ static

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text.begins_with("--days="):
			var value := text.substr(7)
			if value.is_valid_int():
				_world_days = maxi(1, int(value))
		elif text.begins_with("--build-wait="):
			var value := text.substr(13)
			if value.is_valid_int():
				_build_wait_days = maxi(1, int(value))


static func _role_index(catalog: Dictionary, role: int) -> int:
	var buildings: Array = catalog.get("state_buildings", [])
	for index in range(buildings.size()):
		if int((buildings[index] as Dictionary).get("role", -1)) == role:
			return index
	return -1


## Researches the state building's gate technology (the economy answers
## `construction_technology_locked` until the country holds it).
func _grant_gate_tech(military_index: int) -> void:
	var rows: Array = _facade.catalog().get("state_buildings", [])
	if military_index < 0 or military_index >= rows.size() or _country == null:
		return
	var tech := String((rows[military_index] as Dictionary).get("unlock_tech_id", ""))
	if tech.is_empty():
		return
	var granted: Dictionary = _country.grant_technology(_player, StringName(tech),
		_day + 1, _next_seq())
	print("[maintenance-conservation] gate tech %s -> %s" % [tech,
		JSON.stringify(_compact(granted))])


## Queues the building the way the production UI does: economy bill first, then
## the military bookkeeping command that keeps the core's construction cache.
func _build_state_building(military_index: int) -> Dictionary:
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
	out["sponsored"] = _econ.treasury_sponsored_build(_player, _capital,
		StringName(out.economy_building), _day + 1, _next_seq())
	out["booked"] = _facade.build_state_building(_player, _capital, military_index)
	out["ok"] = bool((out.sponsored as Dictionary).get("ok", false)) \
		and bool((out.booked as Dictionary).get("ok", false))
	return out


## Puts `goods` on the cell's market through the admitted POD command lane: the
## legacy GM lane is fail-closed under whole-graph ACTIVE.
func _stock_goods(cell: int, goods: PackedInt32Array, label: String) -> void:
	if _econ == null:
		return
	var market_id := await _market_id(cell)
	if market_id < 0:
		print("[maintenance-conservation] SKIP %s stocking: no market at %d" % [
			label, cell])
		return
	for dense in goods:
		var type_ids: PackedStringArray = _econ.good_ids()
		if dense < 0 or dense >= type_ids.size():
			continue
		var result: Dictionary = _pod_add_stock(market_id, dense, STOCK_QTY * GOODS_SCALE)
		print("[maintenance-conservation] %s stock %s -> %s" % [label,
			String(type_ids[dense]), JSON.stringify(_compact(result))])


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


## Dense economy good ids of the building's construction bill (`material_goods`),
## which the economy charges from the cell's market when the order settles.
func _material_goods(building_index: int) -> PackedInt32Array:
	var rows: Array = _facade.catalog().get("state_buildings", [])
	if building_index < 0 or building_index >= rows.size():
		return PackedInt32Array()
	return (rows[building_index] as Dictionary).get("material_goods",
		PackedInt32Array())


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
	print("=== military maintenance conservation: %d failures, %d skips ===" % [
		_failures.size(), _skips.size()])
	for failure in _failures:
		print("  FAILED: " + failure)
	print("%d failures" % _failures.size())
	return 0 if _failures.is_empty() else 1
