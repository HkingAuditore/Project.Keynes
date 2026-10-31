extends SceneTree
## M1 prerequisite: real-world `epoch_begin_city_factor_ms` baseline.
##
## The synthetic probe (`ideology_cell_layer_m0_city_factor_probe.gd`) proved the
## city-factor refresh is dominated by an O(MAP) full-matrix repaint, but it used
## a uniform synthetic bootstrap (every cell identical), so its absolute
## milliseconds cannot be quoted as a B7/B11 threshold.
##
## This fixture generates a REAL production world and reads the same runtime
## counter across several epoch opens. That is the number §14.3 needs.
##
## Two measurement modes, deliberately both:
##
##   IDLE   no ideology card equipped beyond what the start grants.
##          This is the "B5 idle" reference and the baseline the derived layer
##          must not regress.
##
##   LOADED N ideology cell programs equipped on the player's country.
##          Cancelling the 32 cap changes the covered-cell count from <=32 to the
##          country's whole territory, so this is the shape that has to be
##          affordable.
##
## A real world at 60x40 is 2400 cells; the country holds a handful of them at
## start, which is exactly why the synthetic uniform bootstrap was misleading.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd

const WorldRuntimeHostScript = preload("res://scripts/game/world_runtime_host.gd")
const WorldClockScript = preload("res://scripts/geography/world_clock.gd")
const NewGameConfigScript = preload("res://scripts/game/new_game_config.gd")

const MAP_WIDTH := 60
const MAP_HEIGHT := 40
const SEED := 20261026
## Epoch opens to sample. The first one pays cold-start allocations; later ones
## are the steady-state cost that repeats every market cycle.
const EPOCH_SAMPLES := 6
## Cell cards to equip for the loaded arm. 12 matches the B1 fixture (12 cards
## per country) so the reading is comparable with the plan's B-series.
## Cells to give derived-shaped rows, i.e. the post-cancel coverage of a card.
## 6400 would be a whole-country card on a big map; 512 keeps the run bounded.
## Coverage size. Read from the environment so one binary can measure several
## sizes without editing the file: `PK_COVER_CELLS=800 godot ...`. The default
## stays 2000 so every existing report remains reproducible.
static func _cover_cells() -> int:
	var raw := OS.get_environment("PK_COVER_CELLS")
	if raw.is_valid_int() and int(raw) > 0:
		return int(raw)
	return 2000

var _host: Object = null
var _clock: Object = null
var _day := 0
var _checks := 0
var _failures := 0


func _init() -> void:
	_run()


func _run() -> void:
	_clock = WorldClockScript.new()
	_clock.auto_start = false
	_clock.debug_step_log = false
	get_root().add_child(_clock)
	_clock.pause(true)

	_host = WorldRuntimeHostScript.new()
	_host.map_width = MAP_WIDTH
	_host.map_height = MAP_HEIGHT
	_host.initial_seed = SEED
	# Formal start: the synthetic bootstrap can fail on generated terrain with no
	# timber/stone, which would leave no production reference (same reason the
	# parity gate uses `false`).
	_host.generate_test_economy_data = false
	_host.test_economy_population_scale = 100
	# Keep MODIFIER (bit 6) and ECONOMY (bit 8) OFF the worker authority mask.
	#
	# `runtime_domain_mask(N) == 1 << (N-1)` (`runtime_pod_protocol.h:569-573`):
	#   MODIFIER = 7 -> 0x040, ECONOMY = 9 -> 0x100.
	#
	# MODIFIER off: `submit_modifier_commands` is a QUEUE under worker authority
	# (`world_ext_modifier.cpp:159-160`, "E8: Host is the sole writer. Never
	# apply to legacy first."), so a main-thread GROUP row would never reach the
	# store being measured.
	#
	# ECONOMY off -- and this one cost a full round to find: with ECONOMY on the
	# worker, the main thread never runs `start_epoch`/`capture_country_epoch`,
	# so `epoch_begin_*` in the DETAIL report are STALE configuration-time values.
	# They read `country=27.903` identically for eight consecutive days, which is
	# impossible for a counter reset at `economy_runtime_epoch.cpp:464`. A fixture
	# that trusts them would report a confident, entirely fictional number.
	#
	# This does NOT weaken the measurement: `refresh_city_modifier_factors` reads
	# only Modifier buckets (`economy_runtime.cpp:7072-7097`) and never touches
	# ideology state, so a directly injected row is equivalent to what an equipped
	# cell card produces.
	_host.runtime_authority_domain_mask = 0xFFF & ~0x040 & ~0x100
	get_root().add_child(_host)
	# `_init()` runs before the tree is entered, so a child added here reports
	# `is_inside_tree() == false` for the rest of the frame and `generate_world()`
	# returns silently -- which downstream reads as "get_generator() is null".
	await process_frame

	_host.configure(null, null, _clock)
	var config: Object = NewGameConfigScript.create_default()
	config.country.name = "Cell Layer Cost"
	config.country.foreign_count = 2
	config.base.map_width = MAP_WIDTH
	config.base.map_height = MAP_HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = _host.configure_session({
		"kind": "new_game",
		"config": config.to_dictionary(),
	})
	if not _require("session configures", bool(session.get("ok", false)), str(session)):
		_finish(1)
		return

	await _host.generate_world(SEED)
	var generator = _host.get_generator()
	if not _require("production world generation succeeded", generator != null):
		_finish(2)
		return

	var map = _host.get_current_map()
	var cells: int = map.cell_count() if map != null else 0
	_require("map has cells", cells > 0, str(cells))
	print("[realworld-cost] map=%dx%d cells=%d" % [MAP_WIDTH, MAP_HEIGHT, cells])

	var economy_report: Dictionary = generator.get_economy_report()
	_require("economy is configured", bool(economy_report.get("configured", false)),
		str(economy_report.get("reason", "")))

	# Territory size decides how much the cancelled cap will actually cover.
	var owned := _player_cell_count(generator)
	print("[realworld-cost] player owned cells=%d" % owned)

	# ORDER MATTERS, and getting it wrong is why an earlier run produced NO DATA.
	#
	# The economy dies at day 4 with `money_conservation_failed` (a pre-existing
	# defect recorded in M0-7c). `_sample_epochs` consumes `EPOCH_SAMPLES + 1`
	# days per call, so running the three-tier sequence as idle -> loaded A ->
	# loaded B spends 21 days BEFORE the loaded tier starts: it inherits an
	# already-fatal economy and can never report anything.
	#
	# So the loaded tier goes FIRST, while the economy is still alive, and the
	# idle reference is taken last -- idle is a property of the world, not of the
	# card state at the moment it is measured, so taking it later costs nothing.
	var equipped := _equip_cell_cards(generator)
	print("[realworld-cost] injected rows on %d cells" % equipped)

	# CONTROL: run the SAME coverage twice and compare. If both epochs read the
	# idle value, the reader is short-circuiting on `_epoch_city_factor_stat_version`
	# and NO amount of injected coverage will move the number. Without this
	# control a 0.003 ms result looks identical to "the reader is cheap", which is
	# the wrong conclusion to publish.
	var first_pair: Array = _sample_epochs("loaded A (%d cells)" % equipped)
	_print_stats("loaded A (%d cells)" % equipped, first_pair)
	var second: Array = _sample_epochs("loaded B (%d cells)" % equipped)
	_print_stats("loaded B (%d cells)" % equipped, second)

	# `idle` = no player ideology equipped. Its reading is ~0 because
	# `collect_scope_ids` returns nothing and `refresh_city_output_modifier_factors`
	# short-circuits on version, which is what "idle must stay free" means -- but it
	# MUST NOT be quoted as the cost of the feature.
	#
	# Taken LAST: by now the economy has usually gone fatal, and that is fine --
	# a fatal economy stops opening epochs but the idle reference does not depend
	# on a live one. The validity gate below rejects stale readings either way.
	var idle: Array = _sample_epochs("idle (no cards)")
	_print_stats("idle (no cards)", idle)

	if idle.is_empty() or second.is_empty():
		# One of the tiers produced nothing. Say which, instead of indexing an
		# empty array and reporting an engine error as a measurement failure.
		print("")
		print("[realworld-cost] INCOMPLETE: idle=%d loaded=%d samples."
			% [idle.size(), second.size()])
		print("[realworld-cost] The missing tier is the one that ran after the")
		print("[realworld-cost] economy went fatal (pre-existing day-4 defect).")
		_require("both tiers produced samples", false,
			"idle=%d loaded=%d" % [idle.size(), second.size()])
		_finish(0 if _failures == 0 else 1)
		return
	var idle_steady := float(idle[idle.size() - 1])
	var loaded_steady := float(second[second.size() - 1])
	var resolved := not is_equal_approx(loaded_steady, idle_steady)
	print("")
	if resolved:
		print("[realworld-cost] RESOLVED: loaded %.4f ms vs idle %.4f ms"
			% [loaded_steady, idle_steady])
	else:
		print("[realworld-cost] NOT RESOLVED: loaded == idle (%.4f ms)." % idle_steady)
		print("[realworld-cost] The reader short-circuited on "
			+ "`_epoch_city_factor_stat_version` (economy_runtime.cpp:7016-7018),")
		print("[realworld-cost] so this fixture CANNOT measure the loaded cost.")
		print("[realworld-cost] Do not quote the idle number as the feature cost.")

	print("")
	print("[realworld-cost] cost model check (plan §14.1):")
	print("  map term  = cells x 155      = %d int32 writes" % (cells * 155))
	print("  cover term = owned x 156     = %d queries" % (owned * 156))
	if owned * 156 > cells * 155:
		print("  => coverage dominates on this map")
	else:
		print("  => MAP dominates on this map (~%dx coverage)"
			% max(1, (cells * 155) / max(1, owned * 156)))
	_finish(0 if _failures == 0 else 3)


## Injects `covered` GROUP-scope modifier rows on the player's cells, which is
## exactly the shape `collect_scope_ids` enumerates for the city-factor reader.
##
## Why not equip real ideology cards: under worker authority `equip` only queues
## (`applied=0`), and driving the worker's day transaction from a SceneTree
## script faults it with `day_wait_peer_stall_timeout` (see M0-7c §4). The cost
## being measured does not depend on where the row came from -- the reader reads
## Modifier buckets only -- so injecting the row directly measures the same
## function. The row's stat is `economy.city.birth_factor`, which IS in
## `_city_factor_stat_ids_scratch` (`economy_runtime.cpp:7003`).
##
## The count assertion is load-bearing: a fixture that injects zero rows makes
## `loaded` a duplicate of `idle`, and that reading would then be quoted as
## "the feature costs nothing".
func _equip_cell_cards(generator) -> int:
	var ext = generator.get_data_core_world_ext()
	if ext == null:
		_require("world ext available", false)
		return 0
	var handle := _player_handle(generator)
	if handle == 0:
		print("[realworld-cost] player handle unavailable; injecting on cells 0..N")
	var owned := _player_cell_count(generator)
	var cover := _cover_cells()
	var target := cover if owned <= 0 else mini(cover, owned)

	# One batch, no per-row round trip: the point is the READ cost, not the
	# submit cost.
	var opcodes := PackedInt32Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var days := PackedInt64Array()
	var definitions := PackedStringArray()
	var domains := PackedInt32Array()
	var scopes := PackedInt32Array()
	var entities := PackedInt64Array()
	var groups := PackedInt64Array()
	var source_types := PackedInt64Array()
	var source_ids := PackedInt64Array()
	var durations := PackedInt32Array()
	var stacks := PackedInt32Array()
	var magnitudes := PackedInt32Array()
	var handles_out := PackedInt64Array()

	for i in range(target):
		opcodes.append(1)
		producers.append(1)
		sequences.append(i)
		days.append(int(_day))
		definitions.append("economy.city.birth_factor")
		domains.append(2)
		scopes.append(1)  # GROUP
		entities.append(0)
		groups.append(i)
		source_types.append(1)
		source_ids.append(i + 1)
		durations.append(-1)
		stacks.append(1)
		magnitudes.append(1)
		handles_out.append(0)

	var submitted: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": opcodes,
		"producer_ids": producers,
		"sequences": sequences,
		"effective_days": days,
		"definition_keys": definitions,
		"domains": domains,
		"scopes": scopes,
		"entity_handles": entities,
		"group_handles": groups,
		"source_types": source_types,
		"source_ids": source_ids,
		"duration_days": durations,
		"stacks": stacks,
		"magnitude_q16": magnitudes,
		"modifier_handles": handles_out,
	})
	_require("modifier rows accepted", bool(submitted.get("ok", false)), str(submitted))
	var applied: Dictionary = ext.run_modifier_daily(int(_day))
	_require("modifier rows applied", bool(applied.get("ok", false)), str(applied))

	# Verify the row is actually readable at a cell the reader will visit.
	var live: float = ext.evaluate_modifier_stat(2, 0, 0, "economy.city.birth_factor", 1.0)
	_require("injected row is readable (else `loaded` == `idle`)",
		not is_equal_approx(live, 1.0), "cell0 birth_factor=%f" % live)

	# Second gate: did `collect_scope_ids` see them? The reader only walks the
	# cells that function returns, and that is a DIFFERENT question from "is the
	# row readable" -- a row can be live in a bucket the collector's wanted-stat
	# list does not contain, in which case the reader legitimately skips it.
	print("[realworld-cost] scope_ids probe: birth_factor@cell512=%f cell511=%f"
		% [ext.evaluate_modifier_stat(2, 0, 512, "economy.city.birth_factor", 1.0),
			ext.evaluate_modifier_stat(2, 0, 511, "economy.city.birth_factor", 1.0)])
	return target


## One real semantic day through the host driver, barrier-drained.
##
## The worker needs three services every tick or it faults with
## `day_wait_peer_stall_timeout` (`realworld_cost.stderr.log`, day=9):
##   * `service_country_worker_peer_adapter` -- the Country peer adapter,
##   * `publish_ideology_worker_inputs`      -- the opinion/ideology input handoff,
##   * a clock step via `set_runtime_clock`.
## The parity gate (`runtime_ideology_parity_test.gd:117-177`) does exactly this
## and is the reference for the ordering. Omitting them looks like "the worker
## is slow" and silently ends as FAULTED with an empty ideology snapshot.
func _run_day() -> void:
	_day += 1
	var ext = _host.get_generator().get_data_core_world_ext() \
		if _host.get_generator() != null else null

	var phase: float = _clock.season_phase_for_day(int(_day))
	_clock.current_day = float(int(_day))
	_host.run_daily_tick(int(_day), phase)
	_host.finish_daily_tick(0.0, {})

	var pulses := 0
	while _has_hard_barrier(_clock) and pulses < 400:
		_clock.simulation_backpressure_pulse.emit(int(_day))
		if ext != null:
			if ext.has_method("service_country_worker_peer_adapter"):
				ext.service_country_worker_peer_adapter(64, true)
			if ext.has_method("publish_ideology_worker_inputs"):
				ext.publish_ideology_worker_inputs()
		pulses += 1

	if ext != null:
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		if ext.has_method("publish_ideology_worker_inputs"):
			ext.publish_ideology_worker_inputs()


func _batch(rows: Array, first_sequence: int) -> Dictionary:
	var batch := {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"source_priorities": PackedInt32Array(),
		"producer_ids": PackedInt32Array(),
		"sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(),
		"ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(),
		"offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(),
		"gate_ids": PackedInt32Array(),
	}
	var sequence := first_sequence
	for row in rows:
		batch.opcodes.append(int(row.op))
		batch.effective_days.append(int(row.day))
		batch.source_priorities.append(0)
		batch.producer_ids.append(1)
		batch.sequences.append(sequence)
		sequence += 1
		batch.country_handles.append(int(row.handle))
		batch.ideology_ids.append(int(row.get("idea", -1)))
		batch.values_q16.append(int(row.get("value", 0)))
		batch.offer_generations.append(int(row.get("offer", 0)))
		batch.choice_indices.append(int(row.get("choice", 0)))
		batch.gate_ids.append(int(row.get("gate", 0)))
	return batch


func _player_handle(generator) -> int:
	var country = generator.get_country_facade()
	if country == null:
		return 0
	var starts: Array = generator.get("_gameplay_start_context").get(
		"country_starts", []) if generator.get("_gameplay_start_context") != null else []
	for start_value in starts:
		var start: Dictionary = start_value
		if not bool(start.get("is_player", false)):
			continue
		return int(country.cell_summary(int(start.get("cell", -1))).get(
			"country_handle", 0))
	return 0


## Runs real semantic days through the SAME host driver the parity gate uses
## (`run_daily_tick` + `finish_daily_tick`), collecting
## `epoch_begin_city_factor_ms` from the economy report. The first sample is
## discarded: it pays cold-start allocations that never repeat.
func _sample_epochs(label: String) -> Array:
	var samples: Array = []
	var generator = _host.get_generator()
	if generator == null:
		_require("%s: generator present" % label, false)
		return samples

	# REPEATED MEASUREMENT, not one number quoted twice.
	#
	# The cumulative `city_factor_epoch_ms` only moves when a build actually runs,
	# and a completed build short-circuits every later day on the version gate. So
	# sampling several days WITHOUT touching the modifier plane returns the same
	# frozen value N times -- which is what an earlier version of this fixture did,
	# NOTE: `PK_REPEAT_BUILDS` was tried and does NOT work (M2-14). Bumping the stat
	# version mid-run cannot force a rebuild: the reader already collected its work
	# set inside this epoch, and a completed build short-circuits the rest of the
	# day; the bumped row only becomes visible in the NEXT epoch, which early-outs
	# on the very version the bump was meant to change. `version_probe` stayed
	# identical for five consecutive days.
	#
	# Independent samples therefore come from SEPARATE PROCESS RUNS (each gets a
	# fresh world), not from repeating days inside one run.
	for i in range(EPOCH_SAMPLES + 1):
		_day = int(_day) + 1
		var phase: float = _clock.season_phase_for_day(int(_day))
		_clock.current_day = float(int(_day))
		_host.run_daily_tick(int(_day), phase)
		_host.finish_daily_tick(0.0, {})
		# Drain hard barriers so the day actually commits; the same pulse loop the
		# parity gate uses, with the same bound.
		var pulses := 0
		while _has_hard_barrier(_clock) and pulses < 400:
			_clock.simulation_backpressure_pulse.emit(int(_day))
			pulses += 1

		var report: Dictionary = generator.get_economy_report()
		# Sample the CUMULATIVE epoch figure: `epoch_begin_city_factor_ms` measures
		# one shard call, which for a multi-shard build is the small remainder
		# (M2-10/M2-11). The cumulative field is what §14.3 needs.
		var epoch_ms := float(report.get("city_factor_epoch_ms", -1.0))
		var epoch_slices := int(report.get("city_factor_epoch_slices", 0))
		var epoch_cells := int(report.get("city_factor_epoch_cells", 0))
		# `slices`/`epoch_cells` repeating exactly means the build did NOT re-run:
		# a real rebuild resets them then re-accumulates, so the sum would differ at
		# least slightly. Printing the live version proves whether the bump landed.
		var live_version := int(ext_version_probe(generator))
		print("[realworld-cost]   version_probe=%d day=%d" % [live_version, _day])
		var ms := epoch_ms if epoch_ms > 0.0 else float(
			report.get("epoch_begin_city_factor_ms", -1.0))
		# VALIDITY GATE: an economy that went fatal stops opening epochs, so every
		# later read returns the LAST epoch's counters. That produced 13 identical
		# readings (`country=29.059`) in an earlier run whose economy died at day 4
		# with `money_conservation_failed`. Identical readings across different days
		# are impossible for a counter reset in `clear_epoch_metrics`, so treat
		# them as the stale-data signal they are.
		if bool(report.get("fatal", false)):
			_require("%s: economy still healthy" % label, false,
				"economy went fatal; every reading after this is stale")
			return samples
		# `city_factor_work_cells` is the decisive number: without it, a fast reading
		# is indistinguishable from "the reader skipped the work set". A 2000-cell
		# coverage reporting 12 work cells would make the timing meaningless.
		# The 156 multiplier assumed by the §14.1 model is `2 + need_count +
		# good_count`. If this world has far fewer goods than 134, the model's
		# constant is wrong for THIS world and the timing must be read against the
		# real multiplier, not the assumed one.
		print("[realworld-cost]   counts: good_count=%d need_count=%s"
			% [int(report.get("good_count", -1)),
				str(report.get("need_count", "n/a"))])
		print("[realworld-cost]   counters: country=%.3f reset=%.3f workset=%.3f city=%.3f work_cells=%d collected=%d processed=%d cursor=%d epoch_ms=%.3f slices=%d epoch_cells=%d"
			% [float(report.get("epoch_begin_country_ms", -1.0)),
				float(report.get("epoch_begin_reset_ms", -1.0)),
				float(report.get("epoch_begin_workset_ms", -1.0)), ms,
				int(report.get("city_factor_work_cells", -1)),
				int(report.get("city_factor_collected_cells", -1)),
				int(report.get("city_factor_cells_processed", -1)),
				int(report.get("city_factor_shard_cursor", -99)),
				float(report.get("city_factor_epoch_ms", -1.0)),
				int(report.get("city_factor_epoch_slices", -1)),
				int(report.get("city_factor_epoch_cells", -1))])
		if i == 0:
			print("[realworld-cost] %s warmup (discarded) = %.3f ms" % [label, ms])
			continue
		if epoch_cells <= 0:
			# No completed build this day: recording it would add a zero to the
			# distribution and drag the percentiles down.
			continue
		print("[realworld-cost] %s sample %d: %.3f ms over %d slices / %d cells"
			% [label, samples.size(), epoch_ms, epoch_slices, epoch_cells])
		samples.append(ms)
	_require("%s produced samples" % label, not samples.is_empty(), str(samples))
	return samples


## Reads the version token the reader compares.
##
## Kept from the M2-14 investigation: it is what proved the version does NOT change
## across days, which is the reason independent samples need separate processes.
func ext_version_probe(generator) -> int:
	var ext = generator.get_data_core_world_ext()
	if ext == null:
		return -1
	var sid := int(ext.resolve_modifier_stat("economy.city.birth_factor").get(
		"stat_id", -1))
	if sid < 0:
		return -2
	return int(ext.modifier_stat_bucket_version(2, PackedInt32Array([sid])))

func _has_hard_barrier(clock) -> bool:
	# Mirrors the parity gate's check (`runtime_ideology_parity_test.gd:355-366`):
	# the barrier set lives on `_simulation_backpressure_sources`, and a renamed
	# key must fail visibly rather than spin forever.
	var sources := [
		&"economy_day_barrier",
		&"country_day_barrier",
		&"ideology_day_barrier",
		&"bio_occupancy_day_barrier",
		&"native_daily_day_barrier",
	]
	var set = clock.get("_simulation_backpressure_sources")
	if set == null:
		return false
	for source in sources:
		if set.has(source):
			return true
	return false


func _print_stats(label: String, samples: Array) -> void:
	if samples.is_empty():
		print("[realworld-cost] %s NO DATA" % label)
		return
	var sorted := samples.duplicate()
	sorted.sort()
	var total := 0.0
	for v in sorted:
		total += float(v)
	print("[realworld-cost] %s n=%d min=%.3f p50=%.3f max=%.3f mean=%.3f ms  raw=%s"
		% [label, sorted.size(), float(sorted[0]),
			float(sorted[sorted.size() / 2]), float(sorted[-1]),
			total / float(sorted.size()), str(samples)])


func _player_cell_count(generator) -> int:
	var country = generator.get_country_facade()
	if country == null:
		return 0
	var report: Dictionary = country.report()
	for key in ["player_cell_count", "territory_cell_count", "owned_cell_count"]:
		if report.has(key):
			return int(report[key])
	# Last resort: the anchor cell tells us whether the country has ANY territory,
	# which is the question that matters. Returning -1 here (the M2-9 run) looked
	# like "the player owns nothing" but only meant the report has no territory
	# key -- `country.report()` exposes `cell_count` (the whole map), not ownership.
	var eco = generator.get_economy_facade()
	if eco != null and eco.has_method("player_territory_cell_count"):
		return int(eco.player_territory_cell_count())
	# No aggregate accessor. Ask the anchor instead: `anchor >= 0` means the
	# country owns at least one cell, which is the question that matters; the exact
	# count is reported separately by the injection step.
	#
	# `generator.get_data_core_world_ext()` is the public path this fixture already
	# uses elsewhere (`:200`, `:294`).
	var world_ext: Object = generator.get_data_core_world_ext()
	if world_ext != null and world_ext.has_method("query_country_anchor_cell"):
		if int(world_ext.query_country_anchor_cell(0)) >= 0:
			return -2  # sentinel: territory exists, exact count unavailable
	return -1


func _require(label: String, ok: bool, detail: String = "") -> bool:
	_checks += 1
	if ok:
		return true
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])
	return false


func _finish(code: int) -> void:
	if _host != null:
		_host.queue_free()
	if _clock != null:
		_clock.queue_free()
	print("=== cell layer realworld cost: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
