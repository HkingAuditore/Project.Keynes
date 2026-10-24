extends SceneTree

## R-4 X16 / metric 68 / metric 69 acceptance on the WORKER path.
##
## What this proves that the card-content smoke test cannot: the two new profession
## stats reach the cohort that owns them THROUGH the worker (pod plans -> intent -> ACK
## -> Modifier POD applies -> epoch freeze -> satisfaction), and the effect goes away
## when the card does.
##
## The value under test is always the FROZEN epoch value
## (`get_epoch_profession_report`), never a raw Modifier read: a card can declare the
## stat and still never reach a cohort if the freeze does not pick it up, and that is
## exactly the failure a Modifier-only assertion would miss.
##
## Run: godot --headless --path Project/project-keynes \
##        -s tests/ideology/ideology_x16_worker_test.gd

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261023
# 10, not 30: the country peer adapter is serviced from the test loop, and at 30 the
# worker outruns it and dies with country_worker_peer_stall_timeout before any card
# can equip. The seven-card acceptance uses the same 10.
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const METRIC_NET_TAX_BURDEN := 68
const METRIC_TREASURY_RESERVE := 69
## The compiled-catalog input. `compile_native_catalog(country_ir, economy_ir)` takes
## the economy catalog twice in every existing caller, and the ideology definitions
## resolve their economy-side keys from it.
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyDrawGateHelper = preload(
	"res://tests/ideology/ideology_draw_gate_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _handle := 0
var _country_slot := 0
var _settled_cell := 0
var _empty_cell := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _tick := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x16 worker: %d checks, %d failures ===" % [_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	var fixture := await _build_world()
	if fixture.is_empty():
		printerr("ERROR: [FAIL] x16 fixture unavailable; checks=%d failures=%d"
			% [_checks, _failures])
		return 1
	_host = fixture["host"]
	_clock = fixture["clock"]
	_ext = fixture["ext"]
	_handle = int(fixture["handle"])
	_country_slot = int(fixture["country_slot"])
	_settled_cell = int(fixture["settled_cell"])
	_empty_cell = int(fixture["empty_cell"])
	_test_stat_published()
	_test_landlord_tolerance()
	if _failures == 0:
		_test_negative_bias_under_ceiling()
	_test_net_tax_burden_metric()
	_test_treasury_reserve_metric()
	_teardown()
	return 0


## The two stat families must be addressable through the frozen epoch table. A missing
## entry means `modifier_catalog.gd`, the generator and the C++ resolver disagree, and
## every X16 card would silently do nothing.
func _test_stat_published() -> void:
	var report: Dictionary = _ext.get_epoch_profession_report(_country_slot)
	if not _require("the epoch profession report is available",
			bool(report.get("ok", false)), str(report.get("reason", ""))):
		return
	var ids := PackedStringArray(report.get("profession_ids", PackedStringArray()))
	var tolerance := PackedInt64Array(report.get(
		"tax_tolerance_q16", PackedInt64Array()))
	_expect("the report carries one tolerance per profession (%d ids, %d values)" % [
			ids.size(), tolerance.size()], ids.size() == tolerance.size(),
		"%d vs %d" % [ids.size(), tolerance.size()])
	# The professions the cards in this file touch must be present, otherwise the index
	# lookups below would silently read the wrong slot.
	for profession_id in ["landlord", "merchant"]:
		_expect("profession %s is in the epoch report" % profession_id,
			ids.has(profession_id), str(ids))


## `land_value` L1 is `landlord tax_tolerance x1.15`.
func _test_landlord_tolerance() -> void:
	var baseline := _read_tolerance("landlord")
	_expect("baseline landlord tolerance is the design default 1.00000 (got %.5f)"
			% baseline, _is_close(baseline, 1.0, 0.0001), "%.5f" % baseline)
	if not _equip("land_value"):
		return
	var equipped := _read_tolerance("landlord")
	# MAIN-THREAD CONTROL, printed alongside the frozen value.
	#
	# The two can disagree, and when they do the answer is not "the freeze is broken":
	# the Modifier rows live in the Modifier POD while the worker owns MODIFIER, and a
	# GDScript frame callback copies them into the main-thread ModifierRuntime
	# (`apply_runtime_modifier_snapshot`). The economy epoch capture runs on the WORKER
	# thread and reads that same main-thread runtime, so a row can be visible to a
	# main-thread query and still be absent when an epoch freezes.
	var main_thread_value := _read_modifier_stat(
		"economy.profession.landlord.tax_tolerance_factor")
	_stage("land_value: frozen=%.5f main_thread_modifier=%.5f"
		% [equipped, main_thread_value])
	_expect("land_value raises landlord tax tolerance to 1.15000 (got %.5f)" % equipped,
		_is_close(equipped, 1.15, 0.0005), "%.5f frozen / %.5f main-thread"
			% [equipped, main_thread_value])
	# Per-profession means per-profession: a shared index would move everyone.
	var other := _read_tolerance("merchant")
	_expect("land_value leaves the merchant tolerance untouched (got %.5f)" % other,
		_is_close(other, 1.0, 0.0001), "%.5f" % other)
	if not _unequip("land_value"):
		return
	var restored := _read_tolerance("landlord")
	_expect("unequipping land_value restores the landlord tolerance (got %.5f)"
			% restored, _is_close(restored, 1.0, 0.0001), "%.5f" % restored)


## `tax_holiday` L1 is `merchant satisfaction -200 bp`.
##
## The bias is applied BEFORE the needs ceiling, so the observable consequence is that
## the merchant cohort's satisfaction does not RISE and the frozen bias is negative. If
## the bias were added after `min(raw, ceiling)` it would be clamped away in a satisfied
## world; the frozen-table assert is what keeps that case distinguishable.
func _test_negative_bias_under_ceiling() -> void:
	var before := _merchant_composite()
	if not _equip("tax_holiday"):
		return
	var bias := _read_satisfaction_bias("merchant")
	_expect("tax_holiday sets a negative merchant bias (got %d bp)" % bias, bias < 0,
		str(bias))
	var after := _merchant_composite()
	_expect("tax_holiday does not raise merchant satisfaction (%.5f -> %.5f)" % [
			before, after], after <= before + 0.0001,
		"%.5f -> %.5f" % [before, after])
	_unequip("tax_holiday")
	var cleared := _read_satisfaction_bias("merchant")
	_expect("unequipping tax_holiday clears the merchant bias (got %d bp)" % cleared,
		cleared == 0, str(cleared))


## metric 68: `cell.net_tax_burden_q16`.
##
## Uses the real epoch accounting path -- no `set_effect_metric_override_for_test`.
##
## Two distinct "zero" cases, and they must NOT be conflated:
##   * a cell with NO cohort at all reports Q16_ONE (the documented "no signal" value a
##     generator ramp treats as fully burdened);
##   * a cell whose cohorts booked income but paid no tax reports 0.
## The first version of this test measured an unowned-but-populated cell and expected
## Q16_ONE, which is the second case -- the runtime was right and the assertion wrong.
func _test_net_tax_burden_metric() -> void:
	var cohort_free := _cohort_free_cell()
	if cohort_free < 0:
		# No cell without cohorts in this fixture, so the "no signal" branch cannot be
		# exercised here. State that instead of asserting on a populated cell and
		# calling the metric wrong.
		_stage("metric 68: no cohort-free cell in this fixture; "
			+ "the Q16_ONE branch is covered by the unit of the same name")
	else:
		var value_empty := _metric(METRIC_NET_TAX_BURDEN, cohort_free)
		_expect("metric 68 on a cohort-free cell is Q16_ONE (got %d)" % value_empty,
			value_empty == Q16_ONE, str(value_empty))
	var value_settled := _metric(METRIC_NET_TAX_BURDEN, _settled_cell)
	_expect("metric 68 on a settled cell is in [0, Q16_ONE] (got %d)" % value_settled,
		value_settled >= 0 and value_settled <= Q16_ONE, str(value_settled))


## metric 69: `country.treasury_reserve_ratio_pct`, in percentage points.
func _test_treasury_reserve_metric() -> void:
	var value := _metric(METRIC_TREASURY_RESERVE, _settled_cell)
	_expect("metric 69 reports a non-negative reserve ratio (got %d)" % value,
		value >= 0, str(value))
	# The probe publishes percentage points in Q16, matching `count_q16`.
	_expect("metric 69 stays inside the clamp (got %d)" % value,
		value <= 1000 * Q16_ONE, str(value))


# ── world / worker plumbing ────────────────────────────────────────────────

func _build_world() -> Dictionary:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = WIDTH
	host.map_height = HEIGHT
	host.initial_seed = SEED
	# Every profession must be seeded: the X16 stats are per-profession, and a world
	# with only the starter profession has no landlord or merchant cohort to measure.
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = 0xFFF
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 X16"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("x16 session configures", bool(session.get("ok", false)),
			str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("production world generation succeeded", generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("production DCWorldExt is bound", ext != null):
		return {}
	# Bind the members BEFORE driving: `_drive_days` uses `_host` / `_clock` / `_ext`,
	# and calling it from inside the builder while they were still null is how the
	# first run died with "Invalid assignment of property 'current_day' on Nil".
	_host = host
	_clock = clock
	_ext = ext
	ext.set_runtime_ideology_parity_enabled(true)
	ext.set_runtime_clock(true, WORKER_SPEED)
	if not _require("worker reaches a paused boundary",
			_wait_worker_paused(ext)):
		return {}
	# Resolve the player country from territory, then its slot: the epoch arrays are
	# slot-indexed, so a handle would not be usable directly.
	var handle := 0
	var country_slot := 0
	var settled := 0
	var empty := 0
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		var cell_handle := int(summary.get("country_handle", 0))
		if cell_handle == 0:
			if empty == 0:
				empty = cell
			continue
		if handle == 0:
			handle = cell_handle
			country_slot = int(summary.get("country_slot", 0))
			settled = cell
	if not _require("worker path resolves the player country", handle != 0):
		return {}
	if not _require("a settled cell exists for the cohort probes", settled != 0):
		return {}
	# Seed the driver calendar from the committed day: generation already ran day 1, and
	# driving `run_daily_tick(1)` again re-enters a day the host considers finished.
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	return {"host": host, "clock": clock, "ext": ext, "handle": handle,
		"country_slot": country_slot, "settled_cell": settled, "empty_cell": empty}


func _teardown() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


## Drives `days` worker days: pulse the clock, drain the hard barriers, service the
## country peer, publish opinion inputs, then WAIT for the pod to commit the day -- not
## merely for the host to park (`state == PAUSED` also happens before a commit).
func _drive_days(days: int) -> int:
	for _day in range(days):
		_tick += 1
		_clock.current_day = float(_tick)
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		if _ext.has_method("publish_ideology_worker_inputs"):
			_ext.publish_ideology_worker_inputs()
		_host.run_daily_tick(_tick, _clock.season_phase_for_day(_tick))
		_host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier() and pulses < 400:
			_clock.simulation_backpressure_pulse.emit(_tick)
			pulses += 1
		_ext.set_runtime_clock(false, WORKER_SPEED)
		var before := int(_ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_wait_pod_day(before, 2000)
		_ext.set_runtime_clock(true, WORKER_SPEED)
	return _tick


func _equip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		_fail("%s absent from the compiled catalog" % card)
		return false
	# DISCOVER then EQUIP are two daily plans: the pod's EQUIP requires `known_bits`,
	# which only DISCOVER sets. Batching both makes the EQUIP fail with
	# `ideology_unknown`.
	# Grant the gates BEFORE submitting DISCOVER.
	#
	# `_submit` only reports "the batch was accepted by the ingress"; the pod evaluates
	# `requirements_met` asynchronously and answers `ideology_discovery_not_allowed` in
	# a receipt. So gating this on `discovered.ok` never fires -- measured: the receipt
	# still said `ideology_discovery_not_allowed` after an equip attempt that "succeeded".
	var gates: Dictionary = IdeologyDrawGateHelper.grant_draw_gates(
		_host, card, _handle, _tick, _next_sequence)
	if not _require("%s: worker grants its draw gates" % card,
			bool(gates.get("ok", false)), str(gates)):
		return false
	_next_sequence = maxi(_next_sequence, int(gates.get(
		"next_sequence", _next_sequence)))
	_drive_days(1)
	var discovered: Dictionary = _submit([{"op": 1, "day": _tick, "handle": _handle,
		"idea": dense}])
	if not _require("%s: worker accepts discover" % card,
			bool(discovered.get("ok", false)), str(discovered)):
		return false
	_drive_days(3)
	var equipped: Dictionary = _submit([{"op": 5, "day": _tick, "handle": _handle,
		"idea": dense}])
	if not _require("%s: worker accepts equip" % card,
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	_drive_days(8)
	# The command being ACCEPTED is not the same as the card being installed: the pod
	# ACKs asynchronously, and a rejected transition still returns ok from the submit.
	# Assert the two observable consequences before measuring anything downstream --
	# otherwise "the freeze is broken" and "the card never equipped" look identical.
	var slot_deadline := Time.get_ticks_msec() + 20000
	var slots_used := 0
	var known_id := -1
	while Time.get_ticks_msec() < slot_deadline:
		var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
		known_id = -1
		var known_ids := PackedInt32Array(snapshot.get(
			"known_ids", PackedInt32Array()))
		if known_ids.has(dense):
			known_id = dense
		slots_used = int(snapshot.get(
			"ideology_slots_used", -1))
		if known_id == dense and slots_used >= 1:
			break
		_drive_days(1)
	if known_id != dense:
		# The worker may enforce the same producer high-watermark as the main
		# thread: DISCOVER with sequence N is a deterministic no-op on a replay,
		# and then EQUIP with N+1 sees `ideology_unknown`. Give the fixture a
		# fresh producer sequence and retry discovery once.
		_next_sequence += 1
		var retried: Dictionary = _submit([{"op": 1, "day": _tick,
			"handle": _handle, "idea": dense}])
		if not _require("%s: worker accepts retried discover" % card,
				bool(retried.get("ok", false)), str(retried)):
			return false
		_drive_days(3)
		_next_sequence += 1
		var equipped_retry: Dictionary = _submit([{"op": 5, "day": _tick,
			"handle": _handle, "idea": dense}])
		if not _require("%s: worker accepts retried equip" % card,
				bool(equipped_retry.get("ok", false)), str(equipped_retry)):
			return false
		_drive_days(8)
		var retry_snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
		known_id = dense if PackedInt32Array(retry_snapshot.get(
			"known_ids", PackedInt32Array())).has(dense) else -1
		slots_used = int(retry_snapshot.get("ideology_slots_used", -1))
	if not _require("%s: the card actually occupies a slot (slots=%d)" % [
			card, slots_used], slots_used >= 1, str(slots_used)):
		# Print WHY: the pod records a receipt reason for every rejected command
		# (`ideology_support_threshold_not_met`, `ideology_unknown`,
		# `ideology_discovery_not_allowed`, ...). Without it "slots=0" is unactionable.
		if _ext.has_method("poll_ideology_receipts"):
			var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
			printerr("[x16-equip] %s receipts opcodes=%s reasons=%s" % [
				card, str(receipts.get("opcodes", PackedInt32Array())),
				str(receipts.get("reasons", PackedStringArray()))])
		var report: Dictionary = _ext.get_runtime_thread_report()
		printerr("[x16-equip] %s modifier_ready=%s modifier_reason=%s "
			% [card, str(report.get("modifier_pod_ready", null)),
				str(report.get("modifier_pod_fallback_reason", ""))])
		printerr("[x16-equip] %s effect_ready=%s effect_reason=%s "
			% [card, str(report.get("effect_pod_ready", null)),
				str(report.get("effect_pod_fallback_reason", ""))])
		printerr("[x16-equip] %s ideology_ready=%s ideology_reason=%s "
			% [card, str(report.get("ideology_pod_ready", null)),
				str(report.get("ideology_pod_fallback_reason", ""))])
		printerr("[x16-equip] %s snapshot=%s" % [
			card, str(_ext.get_ideology_snapshot(_handle))])
		return false
	var row_deadline := Time.get_ticks_msec() + 20000
	var rows := PackedStringArray()
	while Time.get_ticks_msec() < row_deadline:
		var listed: Dictionary = _ext.list_modifiers(1, _handle, "")
		rows = PackedStringArray(listed.get(
			"definition_keys", PackedStringArray()))
		if not rows.is_empty():
			break
		_drive_days(1)
	if not _require("%s: the card wrote a national modifier row (rows=%s)" % [
			card, str(rows)], not rows.is_empty(), str(rows)):
		return false
	return true


## Drives days until the frozen per-profession table changes, or gives up.
##
## Bounded and explicit: the X16 stats are read once per epoch by design (a satisfaction
## loop that resolved a modifier per cohort would both cost a lookup each and let two
## cohorts in one country see different tolerances), so a test that asserts on them has
## to cross an epoch boundary first.
## The X16 values are frozen once per epoch, and the probe showed an epoch is captured
## on EVERY driven day in this fixture (`epoch_id` went 0..90 over 90 days), so a card
## equipped on day N shows up on day N+1. Waiting longer than that does not help -- it
## only spends time without servicing the country peer, which is what killed the worker
## with `country_worker_peer_stall_timeout` while an earlier version waited 60 days.
func _wait_epoch_freeze() -> void:
	var before := _read_tolerance("landlord") + float(_read_satisfaction_bias("merchant"))
	for _day in range(5):
		_drive_days(1)
		var now := _read_tolerance("landlord") + \
			float(_read_satisfaction_bias("merchant"))
		if not is_equal_approx(now, before):
			_stage("epoch freeze wait: table changed after %d day(s) (%.5f -> %.5f)"
				% [_day + 1, before, now])
			return
	_stage("epoch freeze wait: table unchanged after 5 days (still %.5f)" % before)


func _unequip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		return false
	var result: Dictionary = _submit([{"op": 6, "day": _tick, "handle": _handle,
		"idea": dense}])
	if not _require("%s: worker accepts unequip" % card,
			bool(result.get("ok", false)), str(result)):
		return false
	var slot_deadline := Time.get_ticks_msec() + 5000
	var slots_used := int(_ext.get_ideology_snapshot(_handle).get(
		"ideology_slots_used", -1))
	while Time.get_ticks_msec() < slot_deadline and slots_used >= 1:
		_drive_days(1)
		slots_used = int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1))
	if not _require("%s: unequip releases the ideology slot (slots=%d)" % [
			card, slots_used], slots_used == 0, str(slots_used)):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[x16-unequip] %s opcodes=%s statuses=%s reasons=%s" % [
			card, str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("statuses", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray()))])
		return false
	_wait_epoch_freeze()
	var report: Dictionary = _ext.get_runtime_thread_report()
	_stage("%s: after unequip pod_day=%d slots=%d rows=%s receipts=%s" % [
		card, int(report.get("ideology_pod_committed_day", -1)),
		int(_ext.get_ideology_snapshot(_handle).get("ideology_slots_used", -1)),
		str(_ext.list_modifiers(1, _handle, "").get(
			"definition_keys", PackedStringArray())),
		str(_ext.poll_ideology_receipts(0, 8).get(
			"reasons", PackedStringArray()))])
	return true


func _submit(rows: Array) -> Dictionary:
	return _ext.submit_ideology_commands(_commands(rows))


func _commands(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producer := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row in rows:
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		producer.append(1)
		# Sequences must be unique ACROSS batches; reusing one makes the whole batch
		# look like a duplicate and it is dropped without an error.
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return {
		"opcodes": opcodes, "effective_days": days, "producer_ids": producer,
		"sequences": sequences, "country_handles": handles, "ideology_ids": ideas,
		"values_q16": values, "source_priorities": priorities,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	}


## Dense id of `card` in the compiled catalog.
##
## Uses `compile_native_catalog()`, not `catalog.definitions`: the compiled table is the
## authority on what actually published (a definition can exist on the Resource and be
## dropped during compile), and it is what `submit_ideology_commands` indexes into.
func _dense_id(card: String) -> int:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	if not bool(native.get("ok", false)):
		_fail("ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get("ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


## Read the stat straight from the main-thread ModifierRuntime.
##
## Used only as a CONTROL next to the frozen value: a disagreement between the two is
## the signal that the epoch freeze and a main-thread query are looking at different
## states, which is what the X16 probe is investigating.
func _read_modifier_stat(stat_key: String) -> float:
	if not _ext.has_method("evaluate_modifier_stat"):
		return -1.0
	return float(_ext.evaluate_modifier_stat(1, _handle, 0, stat_key, 1.0))


## Grants the technology / research-signal gates a card's DISCOVER is checked against,
## through the same `CountryFacade` the research UI uses.
##
## The worker pod ANDs every declared requirement, so a card with a technology gate can
## never be discovered in a fresh fixture -- the world has not researched anything yet.
## In a real session the player's own territory supplies those signals, so this is
## fixture setup rather than content behaviour.
func _read_tolerance(profession_id: String) -> float:
	var report: Dictionary = _ext.get_epoch_profession_report(_country_slot)
	var ids := PackedStringArray(report.get("profession_ids", PackedStringArray()))
	var values := PackedInt64Array(report.get("tax_tolerance_q16", PackedInt64Array()))
	var index := ids.find(profession_id)
	return float(values[index]) / float(Q16_ONE) if index >= 0 else -1.0


func _read_satisfaction_bias(profession_id: String) -> int:
	var report: Dictionary = _ext.get_epoch_profession_report(_country_slot)
	var ids := PackedStringArray(report.get("profession_ids", PackedStringArray()))
	var values := PackedInt64Array(report.get("satisfaction_bp", PackedInt64Array()))
	var index := ids.find(profession_id)
	return int(values[index]) if index >= 0 else 0


## A cell with NO population cohort at all, or -1 when the fixture has none.
##
## The earlier version fell back to `_empty_cell` (an unowned cell), which is NOT the
## same thing: an unowned cell can still hold residents who booked income, so metric 68
## legitimately reports 0 there. The assertion then failed with `got 6760` while the
## runtime was right. Returning -1 makes the caller skip the check with a stated reason
## instead of measuring the wrong cell and blaming the metric.
func _cohort_free_cell() -> int:
	if not _ext.has_method("get_population_cell_snapshot"):
		return -1
	for cell in range(WIDTH * HEIGHT):
		var snapshot: Dictionary = _ext.get_population_cell_snapshot(cell, false)
		if not bool(snapshot.get("ok", false)):
			continue
		if int(snapshot.get("cohort_count", -1)) == 0:
			return cell
	return -1


## The merchant cohort's composite satisfaction on the settled cell, from the committed
## population snapshot. Falls back to the cell average when there is no merchant cohort,
## so the assert still measures "did anything move".
func _merchant_composite() -> float:
	if not _ext.has_method("get_population_cell_snapshot"):
		return -1.0
	var snapshot: Dictionary = _ext.get_population_cell_snapshot(_settled_cell, true)
	if not bool(snapshot.get("ok", false)):
		return -1.0
	var professions := PackedStringArray(snapshot.get(
		"cohort_profession_ids", PackedStringArray()))
	var satisfaction := PackedInt64Array(snapshot.get(
		"cohort_composite_satisfaction", PackedInt64Array()))
	var index := professions.find("merchant")
	if index < 0:
		if satisfaction.is_empty():
			return -1.0
		var total := 0
		for value in satisfaction:
			total += int(value)
		return float(total) / float(satisfaction.size()) / float(Q16_ONE)
	return float(satisfaction[index]) / float(Q16_ONE)


func _metric(metric_id: int, cell: int) -> int:
	var result: Dictionary = _ext.sample_effect_metric_probe(metric_id, cell,
		_handle)
	if not bool(result.get("ok", false)):
		_fail("metric %d probe failed: %s" % [metric_id,
			str(result.get("reason", "unknown"))])
		return -1
	return int(result.get("value", -1))


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method("has_hard_barrier") \
		else false


## Services the Country peer while waiting for the pod to advance, matching the
## production worker loop. The pod cannot commit a day while an Effect peer result
## is still queued.
func _wait_pod_day(baseline: int, timeout_msec: int) -> int:
	var deadline := Time.get_ticks_msec() + timeout_msec
	var reached := baseline
	while Time.get_ticks_msec() < deadline:
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(2)
		var report: Dictionary = _ext.get_runtime_thread_report()
		reached = int(report.get("ideology_pod_committed_day", -1))
		if reached > baseline:
			return reached
		if String(report.get("simulation_host_state", "")) in [
				"STOPPED", "FAULTED"]:
			return reached
	return reached


func _wait_worker_paused(ext: Object) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == "PAUSED":
			return true
		if state in ["STOPPED", "FAULTED"]:
			return false
		OS.delay_msec(2)
	return false


func _is_close(a: float, b: float, tolerance: float) -> bool:
	return absf(a - b) <= tolerance


## The committed economy day. `get_current_day` does not exist on DCWorldExt (calling it
## is a silent SCRIPT ERROR), so the day comes out of the report.
func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_economy_report"):
		return 0
	return int(ext.get_economy_report().get("current_day", 0))


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("ERROR: [FAIL] %s%s" % [label,
		(" (%s)" % detail) if not detail.is_empty() else ""])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _stage(text: String) -> void:
	print("[stage] %s" % text)


func _fail(reason: String) -> void:
	_failures += 1
	printerr("ERROR: [FAIL] %s" % reason)
