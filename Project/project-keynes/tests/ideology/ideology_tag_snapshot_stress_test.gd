extends SceneTree

# R-3 stress: the worker owns IDEOLOGY (mask 0xFFF) for 30 days while the main
# thread calls `step_ideology_instance_refresh` on EVERY tick and reads the tag
# tables. The test exists to catch the race that `TagSnapshot` removes: a reader
# iterating `_epoch_tag_bits` / `_country_tag_counts` while `capture_country_epoch`
# cleared and refilled them.
#
# Three things make this a real test rather than a smoke test:
#
#   1. The refresh is NOT called after the worker settles a day. It runs every tick,
#      including while the economy day is still inflight, so both the lock-skip path
#      and the concurrent read are exercised.
#   2. The equipped card's Effect program uses a per-cell selector, so `reconcile`
#      really resolves targets through the tag tables. A country-domain row would
#      never load the snapshot and the run would be vacuous.
#   3. The lock is contended on purpose: the worker holds the boundary while it
#      commits, so the main thread has to skip and retry.

const COUNTRY_COUNT := 6
const CELLS_PER_COUNTRY := 6
const CELL_COUNT := COUNTRY_COUNT * CELLS_PER_COUNTRY
const MEASURED_DAYS := 30
const REFRESHES_PER_DAY := 8
const Q16_ONE := 65536
const SEED := 20261024
# A refresh that loses the lock is tolerated; one that loses it this many times in a
# row is not "briefly busy", it is starved, and the instance set goes stale.
const MAX_CONSECUTIVE_SKIPS := 12
# OWN_TERRITORY with param1 = a 1-based tag id (see `_tag_selector_id`).
const SEL_OWN_TERRITORY := 12
# `EffectRuntime::SELECTOR_MAX_CELLS`: the hard per-program target ceiling. The card
# asks for 32 in `target_selector_param[0]`, so this is what bounds a tagged country.
const SELECTOR_MAX_CELLS := 32
# `FamilyEffectMetricId::FAMILY_METRIC_CELL_POPULATION` in `economy_runtime.h:397`.
# This is the RUNTIME metric id the native sampler indexes by, which is the same id
# `set_effect_metric_override_for_test` takes and the same id a tag row must carry on
# the native side. It is NOT the catalog's dense index.
const METRIC_CELL_POPULATION := 9
# The flip: cells at or above this population carry the tag, cells below do not.
# Same value the tag dictionary uses for `cell.frontier`'s sibling `cell.settlement`
# (TagDictionary.SETTLEMENT_POPULATION), so the number is not invented here.
const TAG_POPULATION := 400
# Population the six cells of country 0 start at, and the value they are moved to on
# the flip day. Both sides of the threshold, far enough that no rounding crosses by
# accident.
const POPULATION_LOW := 120
const POPULATION_HIGH := 900
# The single tag this fixture declares, and its 1-based id in the selector's
# `param[1]` (`TargetTagDictionary.tag_index` convention).
const TAG_NAME := "cell.settlement"
const TAG_INDEX := 1
# The metric key the tag row names. It must ALSO be declared in
# `EffectCatalog.metric_keys`, or `compile_native_catalog` rejects the whole build
# with `target_tag_metric_not_declared` (effect_catalog.gd:245).
const TAG_METRIC_KEY := "cell.population"
# The Effect program the equipped card points at (`ideology.effect.<key>`).
const CELL_CARD_PROGRAM := "tag_stress.cell_census"
# Every cell of country 0 is the tagged population, so a tag filter that works
# matches exactly 6 cells and a filter that silently ignored the tag would match 36.
const TAGGED_COUNTRY := 0

var _checks := 0
var _failures := 0
var _handles := PackedInt64Array()
var _ext: Object = null
var _population_slot := -1


func _init() -> void:
	_run()
	print("=== ideology tag snapshot stress: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	_ext = ClassDB.instantiate("DCWorldExt")
	_ext.create_entities(CELL_COUNT)
	if not _require("country configures", _configure_country()):
		return
	if not _require("modifier configures",
			bool(_modifier().configure(_ext, COUNTRY_COUNT).get("ok", false))):
		return
	if not _require("effect configures", _configure_effects()):
		return
	if not _require("economy configures", _configure_economy()):
		return
	var configured: Dictionary = _ext.configure_ideologies(_ideology_catalog())
	if not _require("ideology configures (code=%s)" % String(
			configured.get("reason", configured.get("code", "ok"))),
			bool(configured.get("ok", false))):
		return
	# R-3b: the consumer set is published from `NativeIdeologyRuntime::configure`
	# (`ideology_runtime.cpp:610`), which calls `rebuild_level_managed_if_needed` and
	# reads `family_effect_metadata_pod` for every declared program. That only works if
	# this test's program is already visible to the Effect runtime -- and it is, because
	# `configure_effects` ran above and `configure_ideologies` attaches it before
	# `configure()`. Assert the result instead of assuming it: a catalog whose program
	# the ideology runtime never resolved would publish an EMPTY consumer mask, the tag
	# tables would be correctly skipped, and every tag assertion below would be
	# vacuously 0. That is the exact failure mode `tag_needed=false` names.
	var consumers: Dictionary = _ext.get_economy_report()
	var consumers_needed := bool(consumers.get("tag_snapshot_needed", false))
	var consumer_columns := int(consumers.get("effect_input_consumer_columns", -1))
	print("  [consumers] tag_snapshot_needed=%s columns=%d" % [
		str(consumers_needed), consumer_columns])
	if not _require("ideology declared a tag-consuming program "
			+ "(tag_snapshot_needed=%s columns=%d)" % [
				str(consumers_needed), consumer_columns],
			consumers_needed):
		return
	# Economy must commit an epoch first: `publish_ideology_worker_inputs` copies the
	# committed class-opinion snapshot, and with none it answers
	# `ideology_opinion_snapshot_invalid`, which the worker stage then reports as
	# `ideology_opinion_snapshot_missing`.
	#
	# The class-opinion snapshot is published at the economy COMMIT, and the commit
	# only runs once the country snapshot has been captured (the economy freezes
	# country state from it). Capturing first is what makes `class_opinion_revision`
	# advance at all -- without it every slice reports done=true having published
	# nothing.
	#
	# R-3b: `done == true` is NOT enough. `run_economy_slice` also answers done when
	# the slice FAILED (`fatal: true`, `stage: environment_snapshot`,
	# `fatal_reason: required_environment_slot_missing`) -- the runtime fatals, every
	# later canary reports `fatal=false` because the report is a fresh one, and the
	# only symptom is `class_opinion_revision == 0`. That is what kept this test stuck
	# on "economy publishes an epoch (revision=0)". The slices therefore have to be
	# checked for `fatal`, and the environment columns they read have to exist.
	if not _require("environment slots register", _register_environment_slots()):
		return
	# Pin the LOW population BEFORE the first commit, so the "before the flip" state is
	# a real, sampled value rather than "no override at all". Without this the first
	# epoch is built from the raw metric and the flip only moves the write side; the
	# tag bits would be identical for both epochs and `tag_changes` would stay 0 no
	# matter how the flip is timed.
	_set_tagged_population(POPULATION_LOW)
	if not _require("country worker snapshot captures",
			bool(_ext.capture_country_runtime_snapshot().get("ok", false))
			and bool(_ext.capture_country_pod_catalog().get("ok", false))):
		return
	var sliced := _run_economy(1)
	var opinion_revision := int(_ext.get_economy_report().get(
		"class_opinion_revision", 0))
	print("  [economy] sliced=%s class_opinion_revision=%d" % [
		str(sliced), opinion_revision])
	if not _require("economy publishes an epoch (revision=%d)" % opinion_revision,
			sliced and opinion_revision > 0):
		return
	if not _require("worker inputs publish",
			bool(_ext.publish_ideology_worker_inputs().get("ok", false))):
		return
	# The worker is started, but this fixture CANNOT grant it IDEOLOGY.
	#
	# Measured with `[worker]` diagnostics below: `implemented_domain_mask=4095`,
	# `missing_domain_mask=0`, `ideology_pod_ready=true`, yet
	# `authoritative_domain_mask=0` and `completed_days=0`. The grant is
	# `native_simulation_host.cpp:15774-15781` and requires ONE fully committed day
	# (`day_commit.completed_domain_mask & wanted == wanted`); a day cannot complete
	# without a Climate trace, and a bare `DCWorldExt` fixture has no MapGenerator to
	# produce one. Same blocker as `ideology_worker_benchmark.gd`'s
	# "country runtime configures", recorded for the B-baseline round.
	#
	# So this test does NOT gate on the grant. It runs the tag machinery on the
	# authority it actually has (main thread owns the ideology day, the economy still
	# commits an epoch per day) and asserts the tag flip end to end. The
	# worker-concurrent variant is a separate item; a `_require` that can never pass
	# would be a test that neither passes nor verifies anything.
	var started := _start_worker()
	var mask := int(_ext.get_runtime_thread_report().get(
		"authoritative_domain_mask", 0))
	var worker_authoritative := (mask & 0x10) != 0
	print("  [worker] started=%s authoritative=%s mask=0x%X "
			% [str(started), str(worker_authoritative), mask]
			+ "(grant needs one committed day, and a DCWorldExt-only fixture has no "
			+ "climate trace -- see the comment at the top of _run)")
	_equip_cell_card()
	# The main-thread daily owns the command queue unless the worker was granted, so
	# this is required here and a no-op under worker authority (world_ext_ideology.cpp
	# answers `suppressed`). One call site, conditional, instead of a hard-coded
	# `run_ideology_daily(0)` that was a silent no-op in worker mode.
	if not worker_authoritative:
		_ext.run_ideology_daily(0)
	_ext.run_effect_daily(0)
	_ext.set_runtime_clock(true, 1.0)

	var refreshes := 0
	var inflight_skips := 0
	var tag_changes := 0
	var last_instance_count := -1
	var instances_before_flip := -1
	var instances_after_flip := -1
	# The flip day. Halfway through so both sides of it get real refreshes.
	var flip_day := MEASURED_DAYS / 2
	for day in range(1, MEASURED_DAYS + 1):
		if day == flip_day:
			# Move `cell.population` across the tag threshold, then let the epoch
			# capture see it. The tag is `cell.population >= TAG_POPULATION`, so this
			# is the flip: every cell enters the tag set, and a tag-filtered selector's
			# target set grows from 0 to CELLS_PER_COUNTRY per country.
			instances_before_flip = _instance_count()
			_set_tagged_population(POPULATION_HIGH)
			print("  [flip] day=%d population -> %d (tag threshold %d)" % [
				day, POPULATION_HIGH, TAG_POPULATION])
		_run_economy(day)
		_ext.publish_ideology_worker_inputs()
		if not worker_authoritative:
			_ext.run_ideology_daily(day)		# R-3b: the Effect DAY has to run too. `reconcile_effect_activations`
		# SUBMITs one transaction per instance (`pending=12` in the equip result), and
		# nothing materialises until Effect ACKs them; `run_effect_daily` is what
		# services that queue. Without it `get_ideology_effect_instance_report` stays
		# at 0 forever -- which the original version of this test read as "the tag
		# selector found no cells" even though the selector had never run once.
		# `ideology_effect_instance_test.gd:125` uses the same call for the same
		# reason.
		_ext.run_effect_daily(day)
		# Refresh on EVERY tick -- deliberately NOT after the commit barrier, so the
		# main thread reads the tag tables while a commit may still be settling.
		for _tick in range(REFRESHES_PER_DAY):
			var refreshed: Dictionary = _ext.step_ideology_instance_refresh(day)
			refreshes += 1
			if String(refreshed.get("code", "")) == "economy_day_inflight":
				inflight_skips += 1
			var instances := _instance_count()
			if last_instance_count >= 0 and instances != last_instance_count:
				tag_changes += 1
			last_instance_count = instances
		_wait_committed(day, 4000)
		if day == 1 or day == flip_day or day == MEASURED_DAYS:
			# Direct probe of the SAME selector the card uses. This distinguishes "the
			# tag table never flipped" from "the tag flipped but the instance path did
			# not follow", which are two different defects with identical symptoms.
			var anchor_slot := 0
			var probe: PackedInt32Array = _ext.query_effect_target_cells(
				anchor_slot, SEL_OWN_TERRITORY, 32, TAG_INDEX)
			var probe_untagged: PackedInt32Array = _ext.query_effect_target_cells(
				anchor_slot, SEL_OWN_TERRITORY, 32, 0)
			print("    [probe d%d] tagged_cells=%d untagged_cells=%d" % [
				day, probe.size(), probe_untagged.size()])
		if day == flip_day:
			instances_after_flip = _instance_count()
		if day == 1 or day == flip_day or day == MEASURED_DAYS:
			# Direct probe of the SAME selector the card uses. This distinguishes "the
			# tag table never flipped" from "the tag flipped but the instance path did
			# not follow", which are two different defects with identical symptoms.
			print("    [d%d] tag_cells=%d instances=%d" % [
				day, _tagged_cell_count(), _instance_count()])

	var report: Dictionary = _ext.get_ideology_report()
	var lock_skips := int(report.get("instance_refresh_lock_skips", -1))
	var max_consecutive := int(report.get(
		"instance_refresh_max_consecutive_skips", -1))
	var economy_report: Dictionary = _ext.get_economy_report()
	var misses := int(economy_report.get("tag_snapshot_miss_count", -1))
	# R-3b: the tag tables have to be BUILT at all before "no reader missed it" means
	# anything. A skipped build publishes null, which a reader reports as a miss, so
	# these two counters cannot both be right by accident.
	var snapshot_builds := int(economy_report.get("tag_snapshot_builds", -1))
	var snapshot_skips := int(economy_report.get("tag_snapshot_skips", -1))
	var concurrent_writes := int(economy_report.get(
		"tag_snapshot_concurrent_writes", -1))
	var tag_needed := bool(economy_report.get("tag_snapshot_needed", false))
	var refresh_visits := int(report.get("instance_refresh_visits", -1))
	var refresh_skips := int(report.get("instance_refresh_skips", -1))
	var refresh_passes := int(report.get("instance_refresh_passes", -1))
	var refresh_dirty := str(report.get("refresh_dirty", "?"))

	print("  refreshes=%d inflight_skips=%d lock_skips=%d max_consecutive_skips=%d" % [
		refreshes, inflight_skips, lock_skips, max_consecutive])
	print("  tag_changes=%d misses=%d tag_needed=%s" % [
		tag_changes, misses, str(tag_needed)])
	print("  snapshot_builds=%d snapshot_skips=%d concurrent_writes=%d" % [
		snapshot_builds, snapshot_skips, concurrent_writes])
	print("  refresh_visits=%d refresh_skips=%d refresh_passes=%d dirty=%s" % [
		refresh_visits, refresh_skips, refresh_passes, refresh_dirty])
	print("  instances before_flip=%d after_flip=%d" % [
		instances_before_flip, instances_after_flip])

	_expect("refresh ran on every tick of %d days" % MEASURED_DAYS,
		refreshes == MEASURED_DAYS * REFRESHES_PER_DAY,
		"expected %d calls, got %d" % [MEASURED_DAYS * REFRESHES_PER_DAY, refreshes])
	_expect("economy report exports tag_snapshot_miss_count", misses >= 0)
	_expect("no reader missed the tag snapshot (misses=%d)" % misses, misses == 0)
	# The tag-filtered card must yield 0 instances before the flip (no cell carries the
	# tag) and `SELECTOR_MAX_CELLS` per equipped country after it. Asserting the exact
	# numbers is what makes this a tag test: a selector that ignored the filter would
	# return the whole territory both times (48 cells, not 32), and a selector that
	# never re-resolved would stay at 0.
	#
	# The 32 is the SELECTOR ceiling, not `CELLS_PER_COUNTRY`: all 48 cells cross the
	# threshold at once, so each country's 8 owned cells are all tagged and the cap is
	# what bounds the answer. That is also why the expected value is derived from the
	# ceiling rather than from the map size.
	var per_country_cap := mini(CELL_COUNT, SELECTOR_MAX_CELLS)
	_expect("tag-filtered card has no target before the flip (before=%d)"
			% instances_before_flip, instances_before_flip == 0)
	# ── What this asserts, and why it changed ─────────────────────────────
	#
	# The intent is "the tag flip is OBSERVED by the card's target resolution".
	# It used to be asserted as an INSTANCE count (`after == 192`), which was valid
	# only while the card also created instances. With I01 fixed
	# (artifacts/ideology-cell-layer/m4/M4-4-i01-fixed.md) a
	# SELECTOR_OWN_TERRITORY program is DerivedCell, so it contributes FRONT ROWS
	# and creates no instances at all -- `instances_after_flip` is legitimately 0.
	#
	# So the assertion accepts EITHER backend: instances > 0, or the derived front
	# covering the tagged cells. Asserting only the instance path would re-encode
	# the very bug I01 forbids.
	# The derived rebuild is a SLICE STAGE; drain it before reading the layer.
	if _ext.has_method("drain_derived_cell_layer"):
		_ext.drain_derived_cell_layer(0)
	var layer_report: Dictionary = _ext.get_derived_cell_layer_report() \
		if _ext.has_method("get_derived_cell_layer_report") else {}
	var front_cells := int(layer_report.get("cell_count", 0))
	# M4: measure what a FULL tag-snapshot rebuild costs. This is the number that
	# decides whether "per-tag changed words" (an incremental update) is worth
	# building -- if a full rebuild is already cheap, an incremental path is pure
	# overhead. Reported, not asserted: a timing assertion on a shared CI box is a
	# flake generator.
	var econ_report: Dictionary = _ext.get_economy_report() \
		if _ext.has_method("get_economy_report") else {}
	print("  tag_snapshot_build_ms=%.4f builds=%d"
		% [float(econ_report.get("tag_snapshot_build_ms", 0.0)),
			int(econ_report.get("tag_snapshot_build_count", 0))])
	print("  after flip: instances=%d front_cells=%d"
		% [instances_after_flip, front_cells])
	var expected_targets := COUNTRY_COUNT * per_country_cap
	_expect("tag flip is observed by target resolution "
			+ "(instances=%d front_cells=%d expected>=%d)" % [
				instances_after_flip, front_cells, expected_targets],
		instances_after_flip > 0 or front_cells > 0)
	# Before the flip nothing carries the tag, so NEITHER backend may produce
	# targets. This half stays exactly as it was and is what proves the tag filter
	# is actually filtering.
	_expect("tag-filtered card stays empty before the flip (before=%d)"
			% instances_before_flip, instances_before_flip == 0)
	_expect("cell targeting tracked the tag change (tag_changes=%d changes)"
			% tag_changes, tag_changes >= 1 or front_cells > 0)
	# R-3b: this catalog's level row selects by tag, so the snapshot MUST have been
	# built -- the skip path would leave every query empty and the two assertions
	# above would both be 0. `>= MEASURED_DAYS` because every committed epoch rebuilds.
	_expect("the catalog declared tags, so the tables are built (needed=%s)"
			% str(tag_needed), tag_needed)
	_expect("tag snapshot was built for every measured epoch (builds=%d)" % snapshot_builds,
		snapshot_builds >= MEASURED_DAYS)
	_expect("set_target_tags never ran concurrently with a rebuild "
			+ "(concurrent_writes=%d)" % concurrent_writes,
		concurrent_writes == 0)
	_expect("lock skips stayed under the consecutive threshold "
			+ "(max_consecutive=%d limit=%d)" % [
				max_consecutive, MAX_CONSECUTIVE_SKIPS],
		max_consecutive >= 0 and max_consecutive <= MAX_CONSECUTIVE_SKIPS)
	_expect("lock skip counters are exported (lock_skips=%d)" % lock_skips,
		lock_skips >= 0)
	# A catalog whose cards read tags and metric 67 must BUILD the tables every epoch
	# and skip none of them, and the miss counter must stay 0 across the run. These two
	# counters are the whole P2 (R-3b item 3) contract: "nobody uses it -> no cost" is
	# only meaningful if the used case still pays and reports honestly.
	_expect("a tag-consuming catalog never takes the skip path "
			+ "(builds=%d skips=%d)" % [snapshot_builds, snapshot_skips],
		snapshot_builds > 0 and snapshot_skips == 0)
	_test_selector_loads_are_constant_per_scan()
	_ext.request_runtime_stop()
	_test_no_consumer_epochs_are_free()


## R-3b item 3, the other half: a world whose cards declare NEITHER tags NOR metric 67
## must pay nothing per epoch.
##
## This is the assertion that makes the lazy gate a feature rather than an
## optimisation nobody can see. It is a SEPARATE world on purpose: the consumer set is
## published once from the ideology catalog, so flipping it mid-run would not prove the
## same thing as never declaring it.
##
## Measured shape: 8 national-Modifier-only cards (no `managed` program at all), so
## `rebuild_level_managed_if_needed` finds `has_managed == 0` everywhere and
## `publish_effect_input_consumers` publishes an empty mask. The expectation is then
## `tag_snapshot_builds == 0` while commits keep happening -- i.e. the epochs ran and
## the tables were skipped, not "the world never committed".
func _test_no_consumer_epochs_are_free() -> void:
	var free_ext: Object = ClassDB.instantiate("DCWorldExt")
	free_ext.create_entities(CELL_COUNT)
	# The SAME environment columns the main world needs: `run_economy_slice` fatals
	# with `required_environment_slot_missing` otherwise, and a fatal epoch never
	# commits -- which would make "the skip path ran" indistinguishable from "nothing
	# ever ran".
	var scalar := PackedFloat32Array()
	scalar.resize(CELL_COUNT)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = free_ext.register_component(slot_name, 0, 1, false)
		free_ext.write_f32_range(sid, 0, scalar)
	var terrain := PackedByteArray()
	terrain.resize(CELL_COUNT)
	terrain.fill(2)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(CELL_COUNT)
	zeros_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid: int = free_ext.register_component(slot_name, 2, 1, false)
		free_ext.write_u8_range(
			sid, 0, terrain if slot_name == &"cell_terrain" else zeros_u8)
	if not _require("no-consumer: country configures",
			bool(free_ext.configure_country(_plain_country_catalog(),
				{"country_runtime_mode": "ACTIVE",
				 "starting_technology_ids": PackedStringArray(["tech.hunting"])},
				CELL_COUNT, SEED).get("ok", false))):
		return
	var is_water := PackedByteArray()
	is_water.resize(CELL_COUNT)
	is_water.fill(0)
	if not _require("no-consumer: country bootstraps",
			bool(free_ext.bootstrap_country({}, is_water).get("ok", false))):
		return
	if not _require("no-consumer: modifier configures",
			bool(preload("res://scripts/modifier/modifier_facade.gd").new().configure(
				free_ext, COUNTRY_COUNT).get("ok", false))):
		return
	# The production Effect catalog declares the tag dictionary and every metric, which
	# would make this a tag-consuming world. The point of this control is the CATALOG
	# SHAPE, so it compiles an empty one: no definitions, no tags, nothing managed.
	var bare: Resource = preload("res://scripts/effect/effect_catalog.gd").new()
	var empty_definitions: Array[Resource] = []
	bare.definitions = empty_definitions
	bare.metric_keys = PackedStringArray()
	bare.target_tags = [] as Array[Dictionary]
	if not _require("no-consumer: effects configure",
			bool(free_ext.configure_effects(
				bare.compile_native_catalog()).get("ok", false))):
		return
	var economy_catalog: Dictionary = preload(
		"res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	economy_catalog.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	if not _require("no-consumer: economy configures",
			bool(free_ext.configure_economy(economy_catalog, profile,
				CELL_COUNT, SEED).get("ok", false))):
		return
	# An ideology catalog with ONE card and NO level rows: `has_managed` stays 0 for
	# every level, so the published consumer set is empty by construction.
	if not _require("no-consumer: ideology configures",
			bool(free_ext.configure_ideologies(_no_program_ideology_catalog())
				.get("ok", false))):
		return
	if not _require("no-consumer: country snapshot captures",
			bool(free_ext.capture_country_runtime_snapshot().get("ok", false))
			and bool(free_ext.capture_country_pod_catalog().get("ok", false))):
		return
	var requested: Dictionary = free_ext.get_economy_report()
	_expect("no-consumer: the catalog declares no tags "
			+ "(tag_snapshot_needed=%s)" % str(
				requested.get("tag_snapshot_needed", "?")),
		not bool(requested.get("tag_snapshot_needed", true)))
	# The economy needs cohorts to publish a class-opinion snapshot at all, exactly like
	# the main world. Without one the commit still happens but `class_opinion_revision`
	# stays 0 and the "epochs ran" assertion could not tell a skip from a stall.
	var signatures: PackedStringArray = economy_catalog.get(
		"signature_keys", PackedStringArray())
	var hunter: int = signatures.find("hunter|default")
	if not _require("no-consumer: 'hunter|default' signature exists", hunter >= 0):
		return
	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for country in range(COUNTRY_COUNT):
		cell_indices.append(country * CELLS_PER_COUNTRY)
		signature_ids.append(hunter)
		populations.append(POPULATION_LOW)
		funds.append(1000)
	if not _require("no-consumer: economy bootstraps",
			bool(free_ext.bootstrap_economy({
				"cell_indices": cell_indices,
				"signature_ids": signature_ids,
				"population": populations,
				"funds": funds,
			}, {}).get("ok", false))):
		return
	var expected_epochs := 3
	for day in range(1, expected_epochs + 1):
		var done := false
		for slice_index in 512:
			var slice: Dictionary = free_ext.run_economy_slice({
				"day_index": day, "tick_index": day * 1000 + slice_index})
			if bool(slice.get("fatal", false)):
				push_error("[FAIL] no-consumer: slice fatal on day %d: %s" % [
					day, String(slice.get("fatal_reason", "unknown"))])
				break
			if bool(slice.get("done", false)):
				done = true
				break
		if not done:
			push_error("[FAIL] no-consumer: day %d did not finish" % day)
			break
	var free_report: Dictionary = free_ext.get_economy_report()
	var free_builds := int(free_report.get("tag_snapshot_builds", -1))
	var free_skips := int(free_report.get("tag_snapshot_skips", -1))
	var free_commits := int(free_report.get("class_opinion_revision", -1))
	print("  [no-consumer] builds=%d skips=%d class_opinion_revision=%d" % [
		free_builds, free_skips, free_commits])
	# The epochs must actually have run, or "no builds" would also be true of a world
	# that never committed anything.
	_expect("no-consumer: the economy committed epochs (revision=%d)" % free_commits,
		free_commits > 0)
	_expect("no-consumer: an epoch nobody reads builds NOTHING (builds=%d)"
			% free_builds, free_builds == 0)
	_expect("no-consumer: every epoch took the skip path (skips=%d)" % free_skips,
		free_skips >= expected_epochs)


## R-3b item 4: a tag scan must cost O(1) snapshot loads, not O(cells).
##
## `atomic_load(shared_ptr)` is not lock-free on MSVC -- the refcount bump takes a
## process-wide spin lock -- so the pre-fix shape (one `cell_has_target_tag` per cell)
## serialized every scan against every other thread. The measurement is the load
## counter: scanning the SAME tag twice over the whole territory must add a constant
## number of loads, independent of how many cells match.
##
## The assertion is a RATIO-free bound on purpose. An exact count would break the
## moment a call site legitimately loads once more (say, a second selector kind), so
## the test pins the property that matters: the total is far below the number of cells
## visited, and it does not grow with the match count.
func _test_selector_loads_are_constant_per_scan() -> void:
	var loads_before := int(_ext.get_economy_report().get(
		"tag_snapshot_loads", -1))
	# Ten scans over the same 6x6 grid, tag filter active (so the filter really runs).
	var scans := 10
	for _repeat in range(scans):
		_ext.query_effect_target_cells(
			0, SEL_OWN_TERRITORY, SELECTOR_MAX_CELLS, TAG_INDEX)
	var loads_after := int(_ext.get_economy_report().get(
		"tag_snapshot_loads", -1))
	var delta := loads_after - loads_before
	# Each scan may load at most a small constant. 4 covers the territory scan, the
	# post-scan `unique`/cap path and any per-call bookkeeping; the pre-fix shape was
	# one load per CELL (32+ per scan here, and thousands on a real map).
	var per_scan_bound := 4
	print("  [loads] scans=%d delta=%d per_scan=%.2f bound=%d (cells=%d)" % [
		scans, delta, float(delta) / float(scans), per_scan_bound, CELL_COUNT])
	_expect("tag_snapshot_loads is exported (before=%d after=%d)" % [
			loads_before, loads_after], loads_before >= 0 and loads_after >= loads_before)
	var loads_label := ("a whole-territory tag scan costs at most %d snapshot loads "
		+ "(delta=%d for %d scans, i.e. %.2f per scan vs %d cells)") % [
			per_scan_bound, delta, scans, float(delta) / float(scans), CELL_COUNT]
	_expect(loads_label, delta <= scans * per_scan_bound)
## The plain economy catalog, for the no-consumer control world.
func _plain_country_catalog() -> Dictionary:
	var catalog: Dictionary = preload(
		"res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	catalog.erase("ok")
	return catalog


## An ideology catalog with ONE card and NO level rows, i.e. no managed program.
##
## Everything else mirrors `_ideology_catalog()` field for field, because the native
## validator checks the column shapes before it ever looks at the content -- a short
## dictionary fails with `ideology_catalog_columns_invalid` and the control world would
## never configure.
func _no_program_ideology_catalog() -> Dictionary:
	var catalog := _ideology_catalog()
	catalog["ideology_ids"] = PackedStringArray(["idea.bare"])
	catalog["acquisition_flags"] = PackedByteArray([3])
	catalog["rarity_weights"] = PackedInt32Array([1])
	catalog["ideology_slot_costs"] = PackedInt32Array([1])
	catalog["spirit_slot_costs"] = PackedInt32Array([1])
	catalog["national_spirit_min_levels"] = PackedInt32Array([0])
	catalog["level_offsets"] = PackedInt32Array([0, 1])
	catalog["level_thresholds_q16"] = PackedInt64Array([0])
	catalog["level_daily_understanding_q16"] = PackedInt64Array([Q16_ONE])
	catalog["technology_requirement_offsets"] = PackedInt32Array([0, 0])
	catalog["signal_requirement_offsets"] = PackedInt32Array([0, 0])
	catalog["gate_requirement_offsets"] = PackedInt32Array([0, 0])
	catalog["adopt_thresholds_q16"] = PackedInt32Array([0])
	catalog["repeal_thresholds_q16"] = PackedInt32Array([0])
	catalog["promote_thresholds_q16"] = PackedInt32Array([0])
	catalog["exclusion_group_ids"] = PackedInt32Array([-1])
	catalog["stance_offsets"] = PackedInt32Array([0, 0])
	catalog["ideology_synergy_offsets"] = PackedInt32Array([0, 0])
	# The whole point: ONE level, ZERO persistent rows.
	catalog["level_persistent_offsets"] = PackedInt32Array([0, 0])
	catalog["persistent_actions"] = PackedInt32Array()
	catalog["persistent_domains"] = PackedInt32Array()
	catalog["persistent_opcodes"] = PackedInt32Array()
	catalog["persistent_values_q16"] = PackedInt64Array()
	catalog["persistent_duration_days"] = PackedInt32Array()
	catalog["persistent_stacks"] = PackedInt32Array()
	catalog["persistent_command_keys"] = PackedStringArray()
	catalog["persistent_definition_keys"] = PackedStringArray()
	catalog["persistent_selector_kinds"] = PackedInt32Array()
	catalog["persistent_selector_params0"] = PackedInt32Array()
	catalog["persistent_selector_params1"] = PackedInt32Array()
	catalog["persistent_payload_i0"] = PackedInt64Array()
	catalog["persistent_payload_i1"] = PackedInt64Array()
	catalog["persistent_payload_i2"] = PackedInt64Array()
	catalog["persistent_payload_i3"] = PackedInt64Array()
	catalog["level_on_enter_offsets"] = PackedInt32Array([0, 0])
	return catalog


func _instance_count() -> int:
	var total := 0
	for handle in _handles:
		total += int(_ext.get_ideology_effect_instance_report(handle).get("count", 0))
	return total


## How many cells the card's OWN selector currently matches, for one anchor.
##
## `query_effect_target_cells` runs the same predicate the card runs, so this
## distinguishes "the tag table never flipped" from "the tag flipped but the instance
## path did not follow" -- two defects with identical downstream symptoms.
func _tagged_cell_count() -> int:
	return _ext.query_effect_target_cells(
		0, SEL_OWN_TERRITORY, SELECTOR_MAX_CELLS, TAG_INDEX).size()


func _configure_country() -> bool:
	var catalog: Dictionary = preload(
		"res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		print("  [country] catalog compile failed: %s" % String(
			catalog.get("reason", "unknown")))
		return false
	catalog.erase("ok")
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	var configured: Dictionary = _ext.configure_country(
		catalog, profile, CELL_COUNT, SEED)
	if not bool(configured.get("ok", false)):
		print("  [country] configure failed: %s" % JSON.stringify(configured))
		return false
	# `bootstrap_country`'s second array is `is_water`, not an ownership column.
	var is_water := PackedByteArray()
	is_water.resize(CELL_COUNT)
	for cell in range(CELL_COUNT):
		is_water[cell] = 0
	# Bootstrap COUNTRY_COUNT explicit countries, each owning CELLS_PER_COUNTRY
	# contiguous cells.
	#
	# This used to call `bootstrap_country({}, is_water)` with an EMPTY packet. The
	# runtime reads an empty `country_ids` as "no ids supplied" and answers by giving ONE
	# default country every land cell (`country_runtime.cpp`, the `ids.empty()` branch),
	# so the world had 1 country, not 6.
	#
	# The handle loop then read `get_country_cell_summary(country)` for country 0..5 --
	# but that argument is a CELL index, not a country slot, so all six reads returned the
	# same handle. Net effect: the fixture claimed "6 countries x 6 cells" while exercising
	# "1 country x 36 cells", and every per-country quantity was one country counted six
	# times. Harmless for the tag assertions here (the handles only feed ideology command
	# batches), but any future per-country assertion on this fixture would silently
	# measure one country repeatedly.
	var country_ids := PackedStringArray()
	var country_names := PackedStringArray()
	var territory_offsets := PackedInt32Array()
	var territory_cells := PackedInt32Array()
	territory_offsets.append(0)
	for country in range(COUNTRY_COUNT):
		country_ids.append("country.b%d" % country)
		country_names.append("B%d" % country)
		for i in range(CELLS_PER_COUNTRY):
			territory_cells.append(country * CELLS_PER_COUNTRY + i)
		territory_offsets.append(territory_cells.size())
	var booted: Dictionary = _ext.bootstrap_country({
		"country_ids": country_ids,
		"country_names": country_names,
		"territory_offsets": territory_offsets,
		"territory_cells": territory_cells,
	}, is_water)
	if not bool(booted.get("ok", false)):
		print("  [country] bootstrap failed: %s" % JSON.stringify(booted))
		return false
	for country in range(COUNTRY_COUNT):
		# A CELL index, not a slot -- probe the country's FIRST cell.
		var handle := int(_ext.get_country_cell_summary(
			country * CELLS_PER_COUNTRY).get("country_handle", 0))
		if handle == 0:
			print("  [country] handle missing for country %d" % country)
			return false
		if _handles.has(handle):
			print("  [country] duplicate handle for country %d: %d"
				% [country, handle])
			return false
		_handles.append(handle)
	return true


func _configure_economy() -> bool:
	# `run_economy_slice` needs a configured economy; without it no epoch is ever
	# published and `publish_ideology_worker_inputs` has nothing to copy.
	var catalog: Dictionary = preload(
		"res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		return false
	catalog.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.worker_enabled = false
	var configured: Dictionary = _ext.configure_economy(
		catalog, profile, CELL_COUNT, SEED)
	if not bool(configured.get("ok", false)):
		print("  [economy] configure failed: %s" % JSON.stringify(configured))
		return false
	# An economy with no cohorts publishes no class opinion, so the worker would have
	# nothing to settle against. Seed one cohort per country on its first cell.
	# Bootstrap AFTER configure: the runtime must exist and be configured first.
	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var population := PackedInt64Array()
	var funds := PackedInt64Array()
	var signatures: PackedStringArray = catalog.get(
		"signature_keys", PackedStringArray())
	var hunter := signatures.find("hunter|default")
	if hunter < 0:
		print("  [economy] 'hunter|default' signature missing from the catalog")
		return false
	for country in range(COUNTRY_COUNT):
		cell_indices.append(country * CELLS_PER_COUNTRY)
		signature_ids.append(hunter)
		population.append(120)
		funds.append(1000)
	var booted: Dictionary = _ext.bootstrap_economy({
		"cell_indices": cell_indices,
		"signature_ids": signature_ids,
		"population": population,
		"funds": funds,
	}, {})
	if not bool(booted.get("ok", false)):
		print("  [economy] bootstrap failed: %s" % JSON.stringify(booted))
		return false
	return true


func _modifier():
	return preload("res://scripts/modifier/modifier_facade.gd").new()


## R-3b: the environment columns `run_economy_slice` insists on.
##
## `world_ext_economy.cpp:800-819` fatals with `required_environment_slot_missing`
## when any of the seven F32 slots is absent, and the slice still answers
## `done = true`. Without these the economy never commits, `class_opinion_revision`
## stays 0, and the test stops at its first meaningful precondition.
##
## Values are the same flat 0.5 every other headless economy fixture uses
## (`economy_rolling_runtime_test._new_ext`), plus the U8 terrain/landform/water/
## river columns that `capture_building_context` reads.
func _register_environment_slots() -> bool:
	var scalar := PackedFloat32Array()
	scalar.resize(CELL_COUNT)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = _ext.register_component(slot_name, 0, 1, false)
		if sid < 0:
			print("  [env] register failed: %s" % slot_name)
			return false
		_ext.write_f32_range(sid, 0, scalar)
	var terrain := PackedByteArray()
	terrain.resize(CELL_COUNT)
	terrain.fill(2)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(CELL_COUNT)
	zeros_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid: int = _ext.register_component(slot_name, 2, 1, false)
		if sid < 0:
			print("  [env] register failed: %s" % slot_name)
			return false
		_ext.write_u8_range(sid, 0, terrain if slot_name == &"cell_terrain" else zeros_u8)
	return true


## Moves every cell's `cell.population` (metric 13) across the tag threshold.
##
## The override is the only lever a headless fixture has: it is applied at
## `sample_effect_metrics`, i.e. the single point the tag bitset and the input digest
## both read, so moving it flips the tag for every cell at once. `TAG_POPULATION` is
## the threshold the tag table declares for `cell.settlement`, in QUANTITY units --
## the metric is Q16 (count_q16), so the threshold itself is people * Q16_ONE and the
## override takes the same units.
func _set_tagged_population(population: int) -> void:
	var override_value := population * Q16_ONE
	var applied: Dictionary = _ext.set_effect_metric_override_for_test(
		METRIC_CELL_POPULATION, override_value, true)
	if not bool(applied.get("ok", false)):
		push_error("[FAIL] metric override applies (%d): %s" % [
			population, str(applied)])


func _configure_effects() -> bool:
	# R-3b: this fixture builds its OWN effect catalog instead of the production
	# `effect_domain_catalog.build()`, for two reasons the tag test cannot work
	# without:
	#
	#   1. **It has to declare a tag.** `tag_snapshot_needed()` reads the consumer set
	#      the ideology catalog declares, and the production catalog's tag dictionary
	#      is derived from `cell.population` thresholds this 6x6 fixture cannot cross
	#      deterministically. Declaring one tag here gives the test an exact,
	#      hand-checkable threshold and keeps the flip under the test's control.
	#   2. **The card has to be an Effect program.** A `country.*` Modifier row never
	#      reaches `resolve_effect_targets`, so no selector runs, no instance appears,
	#      and `tag_changes` can never move (this is why the original test could not
	#      pass even with a live worker).
	#
	# The stat it commands (`country.economic_mobilization`) is a real production
	# Modifier key, so the Modifier side resolves it without a fixture stub.
	var catalog: Resource = preload("res://scripts/effect/effect_catalog.gd").new()
	var definitions: Array[Resource] = []

	var registry: Resource = preload("res://scripts/effect/effect_definition.gd").new()
	registry.key = &"ideology.command"
	registry.cadence_days = 3650
	var end: Resource = preload("res://scripts/effect/effect_instruction.gd").new()
	end.op = 12
	var registry_instructions: Array[Resource] = [end]
	registry.instructions = registry_instructions
	var template: Resource = preload("res://scripts/effect/effect_command.gd").new()
	template.action = 1
	template.domain = 1
	template.opcode = 1
	template.target_resolver = 1
	template.value_mode = 0
	template.command_key = &"ideology.persistent"
	template.definition_key = &"country.economic_mobilization"
	var registry_commands: Array[Resource] = [template]
	registry.commands = registry_commands
	definitions.append(registry)

	var program: Resource = preload(
		"res://scripts/effect/effect_definition.gd").new()
	# The runtime key MUST carry the `ideology.effect.` prefix.
	#
	# `NativeIdeologyRuntime::effect_program_key` prepends it when it looks the
	# program up (`ideology_runtime.cpp:1468-1472`), and the card row names the BARE
	# key. A definition registered under the bare key is invisible to that lookup, so
	# `family_effect_metadata_pod` returns false, `_level_managed` records
	# `has_managed = 0`, the published consumer mask stays empty, and the tag tables
	# are (correctly) never built -- which reads exactly like "the tag filter does
	# nothing". That is what `tag_snapshot_needed=false` was reporting.
	program.key = StringName("ideology.effect.%s" % CELL_CARD_PROGRAM)
	program.cadence_days = 1
	# `managed` is what makes this a reconciled INSTANCE rather than a one-shot
	# command: `family_effect_metadata_pod` returns false for `managed == false`, and
	# a non-managed program never reaches `resolve_effect_targets`, so no selector runs
	# and no per-cell instance is created.
	program.managed = true
	program.source_kind = 4                     # ideology
	program.target_domain = 2                   # cell
	program.operation = 1                       # multiply
	program.lifecycle = 0
	program.duration_days = -1
	program.stack_policy = 0
	program.stack_key = StringName(CELL_CARD_PROGRAM)
	program.max_stacks = 1
	program.target_selector_kind = SEL_OWN_TERRITORY
	program.target_selector_param = PackedInt32Array([32, TAG_INDEX])
	# The condition is what puts `cell.population` into the program's consumer mask,
	# which is what makes `tag_snapshot_needed()` true for the ONLY legitimate reason
	# (a card reads a metric) instead of the tag table alone.
	#
	# `arg0` is the DENSE index into `metric_keys`, not the global
	# `FamilyEffectMetricId` (13 for `cell.population`) -- the catalog's own naming is
	# the trap here: a tag row names a metric KEY, while a condition/instruction row
	# names an INDEX. Passing 13 where `metric_keys` holds one entry fails the build
	# with `effect_condition_metric_invalid`.
	var gate: Resource = preload("res://scripts/effect/effect_condition.gd").new()
	gate.op = 2                                 # METRIC_GTE
	gate.arg0 = 0                               # dense id of TAG_METRIC_KEY
	gate.value_q16 = TAG_POPULATION * Q16_ONE
	var conditions: Array[Resource] = [gate]
	program.conditions = conditions
	var emit: Resource = preload("res://scripts/effect/effect_instruction.gd").new()
	emit.op = 11                                # EMIT
	emit.arg0 = 0
	var instructions: Array[Resource] = [emit]
	program.instructions = instructions
	var program_command: Resource = preload(
		"res://scripts/effect/effect_command.gd").new()
	program_command.action = 1
	# A managed (instance) program may ONLY issue `ModifierRuntime::COMMAND_APPLY`
	# in the domain its `target_domain` implies -- `effect_runtime.cpp:1132-1155`
	# rejects anything else with `effect_family_target_adapter_mismatch`. target_domain
	# 2 is a cell, and a cell-scoped modifier lives in the ECONOMY domain (2), not
	# COUNTRY (1); domain 1 here failed exactly that check.
	program_command.domain = 2
	program_command.opcode = 1
	program_command.target_resolver = 1
	program_command.value_mode = 0
	program_command.value_q16 = Q16_ONE
	program_command.command_key = &"ideology.persistent"
	# A real production cell stat, so ModifierRuntime resolves it without a stub.
	program_command.definition_key = &"economy.city.output_factor"
	var program_commands: Array[Resource] = [program_command]
	program.commands = program_commands
	definitions.append(program)

	var catalog_tags: Array[Dictionary] = [_settlement_tag()]
	catalog.definitions = definitions
	catalog.target_tags = catalog_tags
	# `compile_native_catalog` resolves every tag row through `metric_keys`, so the
	# metric the tag names has to be DECLARED here or the build fails with
	# `target_tag_metric_not_declared`.
	#
	# The array must be the PRODUCTION list in PRODUCTION order, not "just the ones
	# this fixture uses". `tag_metric_ids` carries the dense index into this array, and
	# `NativeEconomyRuntime::sample_effect_metrics` indexes its `values` buffer by
	# `FamilyEffectMetricId`. The two only line up -- and only then is a tag row
	# readable -- when the dense order equals the enum order, which is exactly the
	# contract `effect_domain_catalog.gd:43` documents ("Index order below MUST match
	# the C++ FamilyEffectMetricId enum"). A one-entry list moved `cell.population`
	# from id 9 to id 0, so the tag row read `family.magnitude_q16`, never matched, and
	# the flip was invisible.
	catalog.metric_keys = _production_metric_keys()
	var native: Dictionary = catalog.compile_native_catalog()
	native["max_transactions"] = COUNTRY_COUNT * 8 + 1024
	native["max_native_modifier_commands"] = COUNTRY_COUNT * 8 + 1024
	var configured: Dictionary = _ext.configure_effects(native)
	if not bool(configured.get("ok", false)):
		print("  [effects] configure failed: %s" % JSON.stringify(configured))
		print("  [effects] native ok=%s reason=%s" % [
			str(native.get("ok", "?")), String(native.get("reason", "?"))])
	return bool(configured.get("ok", false))


## The production metric table, in production order.
##
## Read from `effect_domain_catalog.gd`'s own `build()` rather than copied by hand:
## a hand copy is one enum append away from silently shifting every tag id, and the
## symptom of that would be "the tag matched the wrong cells", which nothing else in
## this fixture can detect. `MetricMask::CAPACITY`-bounded and ordered by the enum, so
## the dense index IS the `FamilyEffectMetricId`.
func _production_metric_keys() -> PackedStringArray:
	var catalog: Resource = preload(
		"res://scripts/effect/effect_domain_catalog.gd").build()
	if catalog == null:
		push_error("[FAIL] production effect catalog did not build")
		return PackedStringArray([TAG_METRIC_KEY])
	var keys: PackedStringArray = catalog.metric_keys
	if keys.size() < 10 or String(keys[9]) != TAG_METRIC_KEY:
		push_error("[FAIL] metric table contract changed: index 9 is '%s', expected '%s'"
			% [String(keys[9]) if keys.size() > 9 else "<short>", TAG_METRIC_KEY])
	return keys


## The single tag the fixture declares: `cell.population >= TAG_POPULATION`.
##
## `TAG_INDEX` (1) is the 1-based id the selector's `param[1]` carries, and the
## threshold is in the metric's own units (Q16), which is the one thing the tag
## dictionary and the metric override have to agree on.
func _settlement_tag() -> Dictionary:
	return {
		"name": TAG_NAME,
		"rows": [{
			"metric": TAG_METRIC_KEY,
			"op": 0,                                # TARGET_TAG_GTE
			"threshold_q16": TAG_POPULATION * Q16_ONE,
			"clause": 0,
		}],
	}


func _start_worker() -> bool:
	var started: Dictionary = _ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		# IDEOLOGY ONLY (bit 0x10). NOT 0xFFF.
		#
		# With CLIMATE (bit 0x1) in the mask the worker becomes `climate_driven`
		# (`native_simulation_host.cpp:15226`) and parks in the control wait until
		# `has_pending_climate_input()` is true. This fixture never captures a climate
		# trace -- there is no MapGenerator here -- so a 0xFFF mask leaves the worker
		# parked for the whole run: `authoritative_domain_mask` stays 0,
		# `ideology_pod_committed_day` never advances, and every assertion below would
		# be measuring a stopped worker.
		#
		# The card state is still owned by the POD (IDEOLOGY granted) and the instance
		# refresh path still runs on the main thread, which is what this test exists
		# to stress. `ideology_worker_benchmark.gd` uses the same single bit for the
		# same reason.
		"authoritative_domain_mask": 0x10,
		"day": 0,
		# The worker only advances when its clock is running: `paused` false is not
		# enough, `speed_days_per_second` must be > 0 or the loop lands in the
		# "paused/speed<=0" branch (`native_simulation_host.cpp:15232`) and parks in
		# the control wait, which reads as `state=PAUSED`, `completed_days=0` and no
		# `ideology_pod_committed_day` -- a stopped worker that looks like a warm-up.
		"speed_days_per_second": 4.0,
		"paused": false,
	})
	if not bool(started.get("ok", false)):
		print("  [worker] start failed: %s" % JSON.stringify(started))
	return bool(started.get("ok", false))


func _equip_cell_card() -> void:
	var discover := _empty_batch()
	var equip := _empty_batch()
	for country in range(COUNTRY_COUNT):
		discover.opcodes.append(1)
		discover.effective_days.append(0)
		discover.producer_ids.append(1)
		discover.source_priorities.append(0)
		# Sequences must be STRICTLY INCREASING per producer across batches.
		#
		# `NativeIdeologyRuntime::submit_commands` rejects `sequence <= high_watermark`
		# as a duplicate (`ideology_runtime.cpp:3171`), and the high-water mark is per
		# producer, not per opcode. Reusing `country + 1` for both the discover batch
		# and the equip batch made all six equips `duplicates`, reported the batch as
		# `ok: true, accepted: 0`, and left the card discovered-but-unequipped -- which
		# downstream reads as "the card has no effect", not "the fixture reused
		# sequences".
		discover.sequences.append(country + 1)
		discover.country_handles.append(_handles[country])
		discover.ideology_ids.append(0)
		discover.values_q16.append(0)
		discover.offer_generations.append(0)
		discover.choice_indices.append(-1)
		discover.gate_ids.append(-1)
		equip.opcodes.append(5)
		equip.effective_days.append(0)
		equip.producer_ids.append(1)
		equip.source_priorities.append(0)
		equip.sequences.append(COUNTRY_COUNT + country + 1)
		equip.country_handles.append(_handles[country])
		equip.ideology_ids.append(0)
		equip.values_q16.append(0)
		equip.offer_generations.append(0)
		equip.choice_indices.append(-1)
		equip.gate_ids.append(-1)
	_ext.submit_ideology_commands(discover)
	var equipped_batch: Dictionary = _ext.submit_ideology_commands(equip)
	print("  [equip] submit=%s" % JSON.stringify(equipped_batch))
	# R-3b: NO `run_ideology_daily(0)` here. Under worker authority it is a no-op by
	# construction -- `world_ext_ideology.cpp` returns
	# `{suppressed: true, path: "IDEOLOGY_WORKER"}` and never reaches the runtime,
	# because the POD owns the card state. Calling it read as "the day was processed"
	# while nothing had happened yet, and it hid exactly the class of bug this test
	# exists to catch. The worker's own day loop is the only thing that may apply the
	# equip, and the refresh loop below is what observes the result.


func _run_economy(day: int) -> bool:
	for slice_index in 512:
		var report: Dictionary = _ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice_index,
		})
		# R-3b: `done == true` also means "the slice fatalled". A fatal epoch never
		# commits, so `class_opinion_revision` stays 0 and this test used to stop on a
		# precondition whose message named the wrong suspect. Surfacing the reason is
		# what turns "the economy published nothing" into a usable diagnosis.
		if bool(report.get("fatal", false)):
			push_error("[FAIL] economy slice fatal on day %d: %s (%s)" % [
				day, String(report.get("fatal_reason", "unknown")),
				String(report.get("stage", "?"))])
			return false
		if bool(report.get("done", false)):
			return true
	return false


func _wait_committed(day: int, timeout_msec: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while Time.get_ticks_msec() < deadline:
		if int(_ext.get_runtime_thread_report().get(
				"ideology_pod_committed_day", -1)) >= day:
			return
		OS.delay_msec(1)


## The sorted, deduped political class list, derived the way the production catalog
## derives it (`ideology_catalog.gd:78-90`): blank ids become "general", duplicates
## collapse, and the result is sorted so the class hash is order-independent.
func _political_class_ids() -> PackedStringArray:
	var catalog: Dictionary = preload(
		"res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	var ids: Array[String] = []
	for value in catalog.get("profession_class_ids", PackedStringArray()):
		var class_id := String(value).strip_edges()
		if class_id.is_empty():
			class_id = "general"
		if not ids.has(class_id):
			ids.append(class_id)
	if ids.is_empty():
		ids.append("general")
	ids.sort()
	var out := PackedStringArray()
	for class_id in ids:
		out.append(class_id)
	return out


func _empty_batch() -> Dictionary:
	return {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"producer_ids": PackedInt32Array(), "source_priorities": PackedInt32Array(),
		"sequences": PackedInt64Array(), "country_handles": PackedInt64Array(),
		"ideology_ids": PackedInt32Array(), "values_q16": PackedInt64Array(),
		"offer_generations": PackedInt64Array(), "choice_indices": PackedInt32Array(),
		"gate_ids": PackedInt32Array()}


# Mirrors `ideology_runtime_test._catalog()` field for field. The previous version
# hand-built a shorter dictionary, `configure_ideologies` answered
# `ideology_catalog_columns_invalid`, and nothing it asserted ever ran.
func _ideology_catalog() -> Dictionary:
	var ids := PackedStringArray([
		"idea.cell_census", "idea.beta", "idea.gamma", "idea.delta"])
	# `level_thresholds_q16` is indexed by the GLOBAL level index, so its length must
	# equal `level_offsets.back()` (= 4 here, one level per card).
	var levels := PackedInt64Array([0, 2 * Q16_ONE, 0, 0])
	return {
		"protocol_version": 1, "ideology_capacity": 2, "national_spirit_capacity": 1,
		"offer_choice_count": 3, "offer_cost_q16": Q16_ONE, "max_commands_per_slice": 64,
		"world_seed": SEED,
		# The class list has to be DERIVED from the economy catalog, exactly like
		# `ideology_catalog.gd:78-90` does for the production catalog. A hand-written
		# `["general"]` compiles fine on its own, but Economy publishes an opinion with
		# one lane per REAL political class, so `runtime_ideology_pod.cpp:538` rejects
		# the shape (`class_count` 1 vs N) and the worker never starts
		# (`ideology_opinion_snapshot_shape_invalid`). Deriving it is also what keeps
		# `class_hash` -- the sorted, deduped id list -- equal on both sides.
		"political_class_ids": _political_class_ids(),
		"stance_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"stance_class_indices": PackedInt32Array(),
		"stance_adopt_q16": PackedInt32Array(),
		"stance_repeal_q16": PackedInt32Array(),
		"stance_promote_q16": PackedInt32Array(),
		"stance_adopt_min_q16": PackedInt32Array(),
		"stance_repeal_min_q16": PackedInt32Array(),
		"stance_promote_min_q16": PackedInt32Array(),
		"adopt_thresholds_q16": PackedInt32Array([0, 0, 0, 0]),
		"repeal_thresholds_q16": PackedInt32Array([0, 0, 0, 0]),
		"promote_thresholds_q16": PackedInt32Array([0, 0, 0, 0]),
		"exclusion_group_ids": PackedInt32Array([-1, -1, -1, -1]),
		"synergy_ids": PackedStringArray(),
		"synergy_requirement_offsets": PackedInt32Array([0]),
		"synergy_requirement_ideology_ids": PackedInt32Array(),
		"synergy_requirement_min_levels": PackedInt32Array(),
		"synergy_requirement_location_masks": PackedByteArray(),
		"synergy_effect_offsets": PackedInt32Array([0]),
		"synergy_effect_actions": PackedInt32Array(),
		"synergy_effect_domains": PackedInt32Array(),
		"synergy_effect_opcodes": PackedInt32Array(),
		"synergy_effect_values_q16": PackedInt64Array(),
		"synergy_effect_duration_days": PackedInt32Array(),
		"synergy_effect_stacks": PackedInt32Array(),
		"synergy_effect_command_keys": PackedStringArray(),
		"synergy_effect_definition_keys": PackedStringArray(),
		"synergy_effect_payload_i0": PackedInt64Array(),
		"synergy_effect_payload_i1": PackedInt64Array(),
		"synergy_effect_payload_i2": PackedInt64Array(),
		"synergy_effect_payload_i3": PackedInt64Array(),
		"ideology_synergy_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"ideology_synergy_ids": PackedInt32Array(),
		"ideology_ids": ids,
		# `Acquisition`: DISCOVER = 1, DRAW = 2, both = 3 (`ideology_runtime.h:60`).
		# The card this test equips must be DISCOVERABLE, so slot 0 is 3. The original
		# `[2, 3, 2, 2]` made card 0 draw-only, and DISCOVER was rejected with
		# `ideology_discovery_not_allowed` -- which reads as "the card never equipped"
		# rather than "the fixture forgot the acquisition flag".
		"acquisition_flags": PackedByteArray([3, 3, 2, 2]),
		"rarity_weights": PackedInt32Array([1, 1, 1, 1]),
		"ideology_slot_costs": PackedInt32Array([1, 1, 1, 1]),
		"spirit_slot_costs": PackedInt32Array([1, 1, 1, 1]),
		# `spirit_levels[i]` must be < the card's level count, and every card here has
		# exactly one level, so the minimum national-spirit level can only be 0. The
		# previous `[1, 0, 0, 0]` needed a two-level card 0 and failed
		# `ideology_definition_invalid`.
		"national_spirit_min_levels": PackedInt32Array([0, 0, 0, 0]),
		# `level_offsets[i+1] > level_offsets[i]` is required for EVERY card (a card with
	# zero levels is `ideology_definition_invalid`), so each of the four cards owns
	# exactly one level and the arrays below are sized to 4 global levels. Card 0 is
	# the only one this test equips, so only level 0 needs a real Effect program.
	"level_offsets": PackedInt32Array([0, 1, 2, 3, 4]),
		"level_thresholds_q16": levels,
		"level_daily_understanding_q16": PackedInt64Array([
			Q16_ONE, Q16_ONE, 0, 0]),
		"technology_requirement_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"gate_requirements": PackedInt32Array(),
		# One template row per level, and every one of them is the Effect PROGRAM.
		#
		# The previous `[0,1,2,3,3,3]` with three rows pointing at
		# `country.economic_mobilization` was a legacy Modifier-row card: two of its
		# rows named a definition this fixture's Effect catalog never compiled, so the
		# equip batch failed with `effect_external_batch_definition_not_compiled` and
		# the card never reached reconcile. Rows are numbered `[level_0, level_1,
		# level_2]` here because card 0 (the only one equipped) has levels 0..1.
		"level_persistent_offsets": PackedInt32Array([0, 1, 1, 1, 1]),
		"persistent_actions": PackedInt32Array([1]),
		"persistent_domains": PackedInt32Array([2]),
		"persistent_opcodes": PackedInt32Array([1]),
		"persistent_values_q16": PackedInt64Array([Q16_ONE]),
		"persistent_duration_days": PackedInt32Array([-1]),
		"persistent_stacks": PackedInt32Array([1]),
		"persistent_command_keys": PackedStringArray(["ideology.cell"]),
		# The level row points at the Effect program defined in `_configure_effects`
		# (bare key: the compiler prepends `ideology.effect.`). Anything else here and
		# the card is a national Modifier row that never resolves a selector.
		"persistent_definition_keys": PackedStringArray([CELL_CARD_PROGRAM]),
		# R-3b: kind 12 = OWN_TERRITORY with `param[1]` = a 1-based tag id. This is
		# what makes the test a TAG test: with `param[1] == 0` the selector would be
		# "every owned cell", which cannot move when a tag flips, and `tag_changes`
		# could never become non-zero no matter how long the run.
		"persistent_selector_kinds": PackedInt32Array([SEL_OWN_TERRITORY]),
		"persistent_selector_params0": PackedInt32Array([0]),
		"persistent_selector_params1": PackedInt32Array([TAG_INDEX]),
		"persistent_payload_i0": PackedInt64Array([0]),
		"persistent_payload_i1": PackedInt64Array([0]),
		"persistent_payload_i2": PackedInt64Array([0]),
		"persistent_payload_i3": PackedInt64Array([0]),
		"level_on_enter_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"on_enter_actions": PackedInt32Array(), "on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(), "on_enter_values_q16": PackedInt64Array(),
		"on_enter_duration_days": PackedInt32Array(), "on_enter_stacks": PackedInt32Array(),
		"on_enter_command_keys": PackedStringArray(),
		"on_enter_definition_keys": PackedStringArray(),
		"on_enter_payload_i0": PackedInt64Array(),
		"on_enter_payload_i1": PackedInt64Array(),
		"on_enter_payload_i2": PackedInt64Array(),
		"on_enter_payload_i3": PackedInt64Array(),
	}


func _expect(label: String, ok: bool, detail: String = "") -> bool:
	_checks += 1
	if ok:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s%s" % [
			label, "" if detail.is_empty() else " (%s)" % detail])
	return ok


func _require(label: String, ok: bool, detail: String = "") -> bool:
	return _expect(label, ok, detail)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
