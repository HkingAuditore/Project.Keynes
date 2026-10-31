extends SceneTree

# --- B4: "about 1% of the cells flip across the tag threshold every day" -----
#
# WHAT THIS FIXTURE IS FOR
#
# B4 asks two questions no existing fixture could answer:
#
#   (a) HOW MUCH DOES THE CHANGE COST -- from "4 cells moved" to "the tag tables
#       and every consumer agree again";
#   (b) HOW WIDE IS THE DIRTY SCOPE  -- after a 1% flip, how many cells count as
#       changed: 1% of the grid, or the whole grid?
#
# WHY `ideology_tag_snapshot_stress_test.gd` COULD NOT ANSWER IT
#
# That fixture flips tags with `set_effect_metric_override_for_test`, which is
# GLOBAL: one call moves `cell.population` for EVERY cell, so every tag bit flips
# at once. On its 36-cell grid "1%" would be 0.36 cells. The per-day churn B4 is
# about cannot exist there at all.
#
# This fixture drives the PER-CELL API instead:
#
#     ext.set_cell_tag_override_for_test(tag_key, cell, on)
#
# Each call copies the immutable override set, records one cell's state for one
# tag, and swaps it in atomically (`economy_runtime_family_buff.cpp:2171-2200`).
# `rebuild_epoch_tag_snapshot` reads that set per cell (`:1290-1309`), so exactly
# the cells this fixture names cross the threshold. That is what makes a 1% churn
# expressible instead of "all or nothing".
#
# MEASURED DESIGN
#
#   * 4 countries x 100 cells = 400 cells. 1% = 4 cells/day, 20 measured days.
#   * 18 days flip 4 cells; 2 days (`QUIET_DAYS`) flip NOTHING. The quiet days are
#     the control for (a): if collection were proportional to the churn, a quiet
#     day would be free. It is not -- see the assertion names.
#   * 4 of the flipping days also push 2 tagged cells back DOWN, so the dirty
#     scope is exercised in both directions. An up-only fixture cannot tell
#     "collect the diff" from "collect the additions".
#   * The natural tag state is held OFF for every cell (the global
#     `cell.population` override sits below the declared threshold), so the
#     published tag set is EXACTLY the set this fixture forced true. That is what
#     lets the test compare the published bitset against a model bit for bit
#     instead of guessing at a trend.
#
# WHAT THE RUNTIME DOES **NOT** EXPORT (a finding, not a workaround)
#
# There is no report field for "how many tag bits changed since the last build".
# `tag_snapshot_*` (`economy_runtime_diagnostics.cpp:1396-1473`) exports builds,
# skips, misses, loads, build_ms and concurrent_writes -- i.e. the COST of
# collection -- and nothing about the size of the diff. The dirty scope here is
# therefore reconstructed from the PUBLISHED snapshot in two independent ways:
#
#   1. `query_effect_target_cells(anchor, SELECTOR_OWN_TERRITORY, 0, tag)` per
#      country enumerates the tagged cells of each territory, so the symmetric
#      difference between two days IS the changed-cell set;
#   2. `sample_effect_metric_probe(62, ...)` reads
#      FAMILY_METRIC_COUNTRY_SETTLEMENT_CELL_COUNT, which the rebuild fills from
#      the SAME bitset (`country_tag_counts`), so the sum over countries is a
#      second, independent count of the dirty scope.
#
# Run:
#   <godot> --headless --path Project/project-keynes \
#     -s tests/ideology/ideology_b4_tag_flip_volume_test.gd

const COUNTRY_COUNT := 4
const CELLS_PER_COUNTRY := 100
const CELL_COUNT := COUNTRY_COUNT * CELLS_PER_COUNTRY		# 400
# 1% of 400 cells.
const FLIP_PER_DAY := 4
const MEASURED_DAYS := 20
# Days with ZERO flips: the control that separates "cost tracks the churn" from
# "cost is a full-grid rebuild that happens anyway".
const QUIET_DAYS := [7, 14]
# Every 5th measured day pushes tagged cells back DOWN as well.
const DOWN_FLIP_EVERY := 5
const DOWN_FLIPS_PER_DAY := 2
# 0.01 * CELL_COUNT * MEASURED_DAYS. Written out so the arithmetic is checkable
# without running the fixture.
const EXPECTED_FLIPS := 80
const Q16_ONE := 65536
const SEED := 20261028
# `EffectRuntime::SELECTOR_OWN_TERRITORY` with param1 = a 1-based tag id.
const SEL_OWN_TERRITORY := 12
# `FamilyEffectMetricId::FAMILY_METRIC_CELL_POPULATION` (`economy_runtime.h:397`):
# the RUNTIME metric id the native sampler indexes by, i.e. what
# `set_effect_metric_override_for_test` takes.
const METRIC_CELL_POPULATION := 9
# `FamilyEffectMetricId::FAMILY_METRIC_COUNTRY_SETTLEMENT_CELL_COUNT`
# (`economy_runtime.h:520`). Filled by the rebuild from `country_tag_counts` for
# the tag literally named "cell.settlement" (`kCountryTagCountSlots`), which is
# why this fixture's tag uses that exact name.
const METRIC_COUNTRY_SETTLEMENT_CELL_COUNT := 62
# The flip: cells at or above this population carry the tag.
const TAG_POPULATION := 400
# Population every cell is held at. Below TAG_POPULATION, so the NATURAL tag state
# is false everywhere and only the per-cell overrides can turn a bit on.
const POPULATION_LOW := 120
const TAG_NAME := "cell.settlement"
# 1-based id in the selector's `param[1]` (`TargetTagDictionary.tag_index`).
const TAG_INDEX := 1
# The metric the tag row names. It must also be declared in
# `EffectCatalog.metric_keys`, or the build fails with
# `target_tag_metric_not_declared`.
const TAG_METRIC_KEY := "cell.population"
# The Effect program the equipped-card slot points at (`ideology.effect.<key>`).
# Nothing equips it: `publish_effect_input_consumers` reads the CATALOG
# (`rebuild_level_managed_if_needed`), so declaring it is what makes
# `tag_snapshot_needed` true -- i.e. what makes the tables get built per epoch.
const CELL_CARD_PROGRAM := "b4.tag_churn"

var _checks := 0
var _failures := 0
var _handles := PackedInt64Array()
var _ext: Object = null
var _override_calls := 0
var _override_rejected := 0
var _first_reject_code := ""


func _init() -> void:
	_run()
	print("=== B4 tag flip volume: %d checks, %d failures ===" % [
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
	# The consumer set is published from `NativeIdeologyRuntime::configure`, which
	# reads `family_effect_metadata_pod` for every declared program. If that lookup
	# fails the consumer mask is empty, `tag_snapshot_needed` is false, every epoch
	# takes the SKIP path, the published snapshot is null, and every tag assertion
	# below would be vacuously 0. Asserting the precondition is what keeps this
	# fixture from passing while measuring nothing.
	var consumers: Dictionary = _ext.get_economy_report()
	var tags_needed := bool(consumers.get("tag_snapshot_needed", false))
	print("  [consumers] tag_snapshot_needed=%s" % str(tags_needed))
	if not _require("the catalog declares a tag-consuming program "
			+ "(tag_snapshot_needed=%s)" % str(tags_needed), tags_needed):
		return
	# `run_economy_slice` fatals with `required_environment_slot_missing` -- and
	# still answers done=true -- when these columns are absent, which would make
	# "the epoch never committed" look like "the tag never flipped".
	if not _require("environment slots register", _register_environment_slots()):
		return
	# Pin `cell.population` BELOW the tag threshold for every cell before the first
	# commit. Without this the first epoch is built from whatever the economy
	# happens to hold and a natural crossing would be indistinguishable from the
	# forced one this fixture is measuring.
	_set_population_override(POPULATION_LOW)
	if not _require("country snapshot captures",
			bool(_ext.capture_country_runtime_snapshot().get("ok", false))
			and bool(_ext.capture_country_pod_catalog().get("ok", false))):
		return
	# Warm-up day: commits the first epoch, which is what populates the territory
	# index every tag query below walks. No flips yet.
	if not _require("warm-up economy day commits", _run_economy(1)):
		return
	var warmup: Dictionary = _ext.get_economy_report()
	print("  [warm-up] class_opinion_revision=%d builds=%d skips=%d misses=%d" % [
		int(warmup.get("class_opinion_revision", -1)),
		int(warmup.get("tag_snapshot_builds", -1)),
		int(warmup.get("tag_snapshot_skips", -1)),
		int(warmup.get("tag_snapshot_miss_count", -1))])
	if _ext.has_method("get_economy_territory_plane"):
		print("  [territory] plane=%s" % str(_ext.get_economy_territory_plane()))

	# ---- the flip universe -------------------------------------------------
	# Enumerated from the SAME territory index the selector walks, not assumed from
	# the bootstrap packet: if the economy saw a different ownership plane, every
	# count below would be measured against cells no query can see.
	var per_country := _owned_cells_per_country()
	var owned_total := 0
	var widest := 0
	# Four DISTINCT handles, not four copies of one: `get_country_cell_summary`
	# takes a cell index, so probing slots instead of cells silently returns the
	# same country four times and a one-country "4-country grid" would pass every
	# count below while measuring nothing about locality.
	var distinct_countries := {}
	for handle in _handles:
		distinct_countries[handle] = true
	for country in range(COUNTRY_COUNT):
		var cells: PackedInt32Array = per_country[country]
		owned_total += cells.size()
		widest = maxi(widest, cells.size())
		print("  [owned] country %d (handle=%d): %d cells" % [
			country, _handles[country], cells.size()])
	_expect("the grid holds %d distinct countries (handles=%s)" % [
			COUNTRY_COUNT, str(_handles)],
		distinct_countries.size() == COUNTRY_COUNT)
	var ownership_label := "every cell belongs to exactly one country "
	ownership_label += "(owned=%d of %d cells, widest=%d)" % [
		owned_total, CELL_COUNT, widest]
	if not _require(ownership_label, owned_total == CELL_COUNT):
		return
	# One cell per country per round, so a day's 4 flips land in 4 different
	# countries. A run that stuffed every flip into country 0 would leave the
	# per-country counts of the other three flat and the dirty-scope locality
	# unmeasured.
	var flip_order := PackedInt32Array()
	for round_index in range(CELLS_PER_COUNTRY):
		for country in range(COUNTRY_COUNT):
			var cells: PackedInt32Array = per_country[country]
			if round_index < cells.size():
				flip_order.append(cells[round_index])
	if not _require("the flip schedule covers the whole grid (order=%d)" % (
			flip_order.size()), flip_order.size() == CELL_COUNT):
		return

	# ---- baseline: nothing carries the tag yet -----------------------------
	var previous := _tagged_cells()
	print("  [baseline] tagged=%d (expected 0: the natural tag is held off)" % (
		previous.size()))
	if not _require("no cell carries the tag before the first flip (tagged=%d)" % (
			previous.size()), previous.is_empty()):
		return

	# ---- the measured run --------------------------------------------------
	var model := {}					# cell -> true: the fixture's own tag set
	var tagged_fifo := PackedInt32Array()	# tagged cells, oldest first
	var up_cursor := 0
	var flips_total := 0
	var up_total := 0
	var down_total := 0
	var changed_total := 0
	var max_changed := 0
	var model_mismatch_days := 0
	var churn_mismatch_days := 0
	var commits_missing := 0
	var publish_failures := 0
	var quiet_builds := 0
	var quiet_changes := 0
	var builds_total := 0
	var day_cost_ms: Array[float] = []
	var flip_cost_ms: Array[float] = []
	var build_cost_ms: Array[float] = []
	var quiet_build_ms: Array[float] = []
	var flip_build_ms: Array[float] = []
	var last_report: Dictionary = {}
	for index in range(1, MEASURED_DAYS + 1):
		var day := index + 1
		var quiet := QUIET_DAYS.has(index)
		var flips_today := 0
		var flip_started := Time.get_ticks_usec()
		if not quiet:
			var down_today := DOWN_FLIPS_PER_DAY \
				if index % DOWN_FLIP_EVERY == 0 else 0
			while down_today > 0 and not tagged_fifo.is_empty():
				var down_cell: int = tagged_fifo[0]
				tagged_fifo.remove_at(0)
				if not _apply_flip(down_cell, false):
					break
				model.erase(down_cell)
				down_total += 1
				flips_today += 1
				down_today -= 1
			while flips_today < FLIP_PER_DAY and up_cursor < flip_order.size():
				var up_cell: int = flip_order[up_cursor]
				up_cursor += 1
				if not _apply_flip(up_cell, true):
					break
				model[up_cell] = true
				tagged_fifo.append(up_cell)
				up_total += 1
				flips_today += 1
		if _override_rejected > 0:
			# The API refused the cell. Report WHY and stop: continuing would
			# measure a run whose churn never reached the tag table.
			print("  [reject] first code=%s after %d calls" % [
				_first_reject_code, _override_calls])
			break
		flips_total += flips_today
		var flip_finished := Time.get_ticks_usec()
		flip_cost_ms.append(float(flip_finished - flip_started) / 1000.0)

		# The day step: commit the epoch (which rebuilds the tag snapshot), then
		# the ideology day. Timed as a block, because that block is what a caller
		# pays after touching 1% of the cells.
		var builds_before := int(
			_ext.get_economy_report().get("tag_snapshot_builds", -1))
		var step_started := Time.get_ticks_usec()
		var stepped := _run_economy(day)
		var published: Dictionary = _ext.publish_ideology_worker_inputs()
		_ext.run_ideology_daily(day)
		var step_finished := Time.get_ticks_usec()
		day_cost_ms.append(float(step_finished - step_started) / 1000.0)
		if not bool(published.get("ok", false)):
			publish_failures += 1
		var report: Dictionary = _ext.get_economy_report()
		last_report = report
		var builds_after := int(report.get("tag_snapshot_builds", -1))
		var builds_today := builds_after - builds_before
		builds_total += builds_today
		build_cost_ms.append(float(report.get("tag_snapshot_build_ms", 0.0)))
		if quiet:
			quiet_build_ms.append(float(report.get("tag_snapshot_build_ms", 0.0)))
		else:
			flip_build_ms.append(float(report.get("tag_snapshot_build_ms", 0.0)))
		if int(report.get("class_opinion_revision", 0)) <= 0:
			commits_missing += 1

		# ---- dirty scope: what actually changed in the published snapshot ---
		var current := _tagged_cells()
		var changed := _changed_between(previous, current)
		changed_total += changed
		max_changed = maxi(max_changed, changed)
		if not _matches_model(current, model):
			model_mismatch_days += 1
		if changed != flips_today:
			churn_mismatch_days += 1
		if quiet:
			quiet_builds += builds_today
			quiet_changes += changed
		print("    [d%02d] flips=%d changed=%d tagged=%d builds=+%d "
				% [index, flips_today, changed, current.size(), builds_today]
				+ "build_ms=%.4f flip_us=%d day_us=%d" % [
					float(report.get("tag_snapshot_build_ms", 0.0)),
					flip_finished - flip_started,
					step_finished - step_started])
		previous = current
		if not stepped:
			break

	# ---- final counters ----------------------------------------------------
	var report: Dictionary = last_report if not last_report.is_empty() \
		else _ext.get_economy_report()
	var builds := int(report.get("tag_snapshot_builds", -1))
	var skips := int(report.get("tag_snapshot_skips", -1))
	var misses := int(report.get("tag_snapshot_miss_count", -1))
	var concurrent := int(report.get("tag_snapshot_concurrent_writes", -1))
	var loads := int(report.get("tag_snapshot_loads", -1))
	var declared_tags := int(report.get("tag_declared_tags", -1))
	var active_tags := int(report.get("tag_active_tags", -1))
	var consumed_tags := int(report.get("tag_consumed_tags", -1))
	var ideology_report: Dictionary = _ext.get_ideology_report()
	var metric_sum := _metric_country_tag_sum()
	var last_tagged := previous.size()
	# The dirty-scope arithmetic, stated once so the report can be quoted:
	# a 1% churn over CELL_COUNT cells must be ~FLIP_PER_DAY changed cells, and
	# `changed_total` is the sum of the per-day symmetric differences.
	print("  [volume] cells=%d days=%d flips=%d (up=%d down=%d) expected=%d" % [
		CELL_COUNT, MEASURED_DAYS, flips_total, up_total, down_total,
		EXPECTED_FLIPS])
	print("  [tag] builds=%d skips=%d misses=%d concurrent_writes=%d loads=%d" % [
		builds, skips, misses, concurrent, loads])
	print("  [tag] per-day rebuild deltas summed=%d over %d measured days "
			% [builds_total, MEASURED_DAYS]
			+ "(the warm-up day contributed the other %d)" % (builds - builds_total))
	print("  [tag] declared_tags=%d active_tags=%d consumed_tags=%d" % [
		declared_tags, active_tags, consumed_tags])
	print("  [dirty] changed_cell_days=%d max_changed_per_day=%d "
			% [changed_total, max_changed]
			+ "final_tagged=%d (%.2f%% of the grid)" % [
				last_tagged, 100.0 * float(last_tagged) / float(CELL_COUNT)])
	print("  [dirty] per-country tagged count sum (metric 62) = %d, "
			% metric_sum
			+ "published set = %d (must agree)" % last_tagged)
	print("  [dirty] NO economy-report field carries the changed-tag-cell count: "
			+ "scope reconstructed from the published snapshot (see the header)")
	print("  [ideology] instance_refresh_visits=%s refresh_dirty_present=%s" % [
		str(ideology_report.get("instance_refresh_visits", "?")),
		str(ideology_report.has("refresh_dirty"))])
	print("    (context only: no card is equipped, so this is not the tag path)")
	print(_stat(day_cost_ms, "per-day step (commit + ideology day) ms"))
	print(_stat(flip_cost_ms, "per-day flip batch (override calls) ms"))
	print(_stat(build_cost_ms, "per-day tag snapshot rebuild ms"))
	# The same number split by HOW MUCH changed, which is the (a) half of B4: if
	# collection tracked the churn, the two medians would differ by the churn ratio
	# (0 cells vs 4 cells). They should not differ at all, because the rebuild is a
	# full-grid sweep.
	print(_stat(quiet_build_ms, "rebuild ms on days with ZERO flips"))
	print(_stat(flip_build_ms, "rebuild ms on days with 4 flips"))

	# ---- assertions --------------------------------------------------------
	_expect("the per-cell tag override is accepted on every call "
			+ "(calls=%d rejected=%d)" % [_override_calls, _override_rejected],
		_override_calls > 0 and _override_rejected == 0,
		"first code=%s" % _first_reject_code)
	# About 1% of the grid per day. Generous band (+-factor 2) because the exact
	# number depends on the quiet days and the down-flip cadence, but the ORDER OF
	# MAGNITUDE is the claim: a fixture that flipped 100% or 0.01% per day would
	# fail here.
	_expect("1%% of the grid flips per day (total=%d over %d days, expected ~%d)"
			% [flips_total, MEASURED_DAYS, EXPECTED_FLIPS],
		flips_total >= EXPECTED_FLIPS / 2 and flips_total <= EXPECTED_FLIPS * 2,
		"total=%d" % flips_total)
	_expect("both directions are exercised (up=%d down=%d, at least 2 down)"
			% [up_total, down_total], up_total > 0 and down_total >= 2)
	_expect("tag_changes > 0: the tag really moved (changed cell-days=%d)" % (
			changed_total), changed_total > 0)
	_expect("the tag snapshot was rebuilt at least once (builds=%d)" % builds,
		builds > 0)
	_expect("every measured day rebuilt the tables at least once "
			+ "(per-day deltas summed=%d over %d days)" % [
				builds_total, MEASURED_DAYS],
		builds_total >= MEASURED_DAYS)
	_expect("no reader missed the tag snapshot (tag_snapshot_miss_count=%d)" % (
			misses), misses == 0)
	_expect("a tag-consuming catalog never takes the skip path (skips=%d)" % (
			skips), skips == 0)
	# THE B4 CLAIM: after a 1% flip the dirty scope is the churn, not the grid.
	_expect("dirty scope is the churn, not the grid "
			+ "(max changed/day=%d of %d cells, %.2f%%)" % [
				max_changed, CELL_COUNT,
				100.0 * float(max_changed) / float(CELL_COUNT)],
		max_changed <= FLIP_PER_DAY * 2 and max_changed * 10 < CELL_COUNT)
	_expect("the published tag set equals the fixture's model every day "
			+ "(mismatched days=%d)" % model_mismatch_days,
		model_mismatch_days == 0)
	_expect("every flip day moved exactly the cells it flipped "
			+ "(mismatched days=%d)" % churn_mismatch_days,
		churn_mismatch_days == 0)
	# The control for (a): the collection cost is NOT proportional to the churn.
	# Two days changed nothing at all, and the rebuild still ran on both.
	_expect("a day with zero flips still pays a full rebuild "
			+ "(quiet days=%d, builds=%d, changed=%d)" % [
				QUIET_DAYS.size(), quiet_builds, quiet_changes],
		quiet_builds >= QUIET_DAYS.size() and quiet_changes == 0)
	# Second, independent view of the dirty scope, read through the metric every
	# card sees rather than through the selector.
	_expect("the per-country count metric agrees with the published set "
			+ "(metric 62 sum=%d, published=%d)" % [metric_sum, last_tagged],
		metric_sum == last_tagged)
	_expect("the economy committed every measured day (missing=%d)" % (
			commits_missing), commits_missing == 0)
	_expect("worker inputs publish every measured day (failures=%d)" % (
			publish_failures), publish_failures == 0)
	_expect("set_target_tags never ran concurrently with a rebuild "
			+ "(concurrent_writes=%d)" % concurrent, concurrent == 0)
	# The gap, asserted so it cannot be forgotten: while this stays absent, the
	# dirty scope can only be reconstructed from the published snapshot.
	_expect("the economy report has no changed-tag-cell counter "
			+ "(the B4 evidence gap)", not report.has("tag_changed_cell_count"))

	# --- probe: does the collection cost track the CHURN or the GRID? --------
	#
	# Ten times the daily churn in ONE batch (36 cells, 9% of the grid), one day.
	# If collection were proportional to the diff this rebuild would cost ~10x a
	# 4-cell one. The TIMING half is printed, not asserted (a wall-clock assertion
	# is a flake generator); the deterministic half -- exactly one rebuild per day
	# no matter how much (or how little) changed -- is asserted.
	var probe_cells := 36
	var probe_applied := 0
	for step in range(probe_cells):
		if up_cursor >= flip_order.size():
			break
		var probe_cell: int = flip_order[up_cursor]
		up_cursor += 1
		if not _apply_flip(probe_cell, true):
			break
		probe_applied += 1
	var probe_builds_before := int(
		_ext.get_economy_report().get("tag_snapshot_builds", -1))
	var probe_started := Time.get_ticks_usec()
	var probe_stepped := _run_economy(MEASURED_DAYS + 2)
	var probe_usec := Time.get_ticks_usec() - probe_started
	var probe_report: Dictionary = _ext.get_economy_report()
	var probe_builds := int(probe_report.get("tag_snapshot_builds", -1)) \
		- probe_builds_before
	var probe_tagged := _tagged_cells().size()
	print("  [probe] churn=%d cells (%.0f%% of the grid) in one day: builds=+%d "
			% [probe_applied, 100.0 * float(probe_applied) / float(CELL_COUNT),
				probe_builds]
			+ "build_ms=%.4f day_us=%d tagged=%d" % [
				float(probe_report.get("tag_snapshot_build_ms", 0.0)),
				probe_usec, probe_tagged])
	_expect("the 9% churn probe day also takes exactly one rebuild "
			+ "(builds=+%d for %d cells)" % [probe_builds, probe_applied],
		probe_stepped and probe_applied == probe_cells and probe_builds == 1)


# --- setup ----------------------------------------------------------------


## 4 countries, 100 contiguous cells each, defined by the bootstrap packet.
##
## Explicit territory instead of the default even split: B4 needs to know that a
## day's 4 flips land in 4 different countries, and the per-country tag count
## metric is only meaningful when every country really owns a block.
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
	var country_ids := PackedStringArray()
	var country_names := PackedStringArray()
	var country_cash := PackedInt64Array()
	var territory_offsets := PackedInt32Array()
	var territory_cells := PackedInt32Array()
	var technology_offsets := PackedInt32Array()
	var treasury_offsets := PackedInt32Array()
	for country in range(COUNTRY_COUNT):
		country_ids.append("country.b4.%d" % country)
		country_names.append("B4 Country %d" % country)
		country_cash.append(1000)
		territory_offsets.append(country * CELLS_PER_COUNTRY)
		technology_offsets.append(0)
		treasury_offsets.append(0)
		for step in range(CELLS_PER_COUNTRY):
			territory_cells.append(country * CELLS_PER_COUNTRY + step)
	territory_offsets.append(CELL_COUNT)
	technology_offsets.append(0)
	treasury_offsets.append(0)
	var is_water := PackedByteArray()
	is_water.resize(CELL_COUNT)
	is_water.fill(0)
	var booted: Dictionary = _ext.bootstrap_country({
		"country_ids": country_ids,
		"country_names": country_names,
		"country_cash": country_cash,
		"territory_offsets": territory_offsets,
		"territory_cells": territory_cells,
		"technology_offsets": technology_offsets,
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": treasury_offsets,
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, is_water)
	if not bool(booted.get("ok", false)):
		print("  [country] bootstrap failed: %s" % JSON.stringify(booted))
		return false
	for country in range(COUNTRY_COUNT):
		# `get_country_cell_summary` takes a CELL index, not a country slot: probing
		# `country` reads cell `country`, and cells 0..3 all belong to country 0 --
		# which is how a fixture ends up holding four copies of one handle. Probe
		# the first cell of each block instead.
		var summary: Dictionary = _ext.get_country_cell_summary(
			country * CELLS_PER_COUNTRY)
		var handle := int(summary.get("country_handle", 0))
		if handle == 0:
			print("  [country] handle missing for the block owned by country %d: %s" % [
				country, JSON.stringify(summary)])
			return false
		_handles.append(handle)
	return true


func _configure_economy() -> bool:
	# `run_economy_slice` needs a configured economy; without it no epoch is ever
	# published and the tag tables are never rebuilt (`rebuild_epoch_tag_snapshot`
	# is called from `capture_country_epoch`).
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
	# One cohort per country, on its lowest cell. Populations stay far below
	# TAG_POPULATION so the natural tag state cannot drift onto a flipped cell and
	# break the model comparison.
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
		population.append(POPULATION_LOW)
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


## The environment columns `run_economy_slice` insists on.
##
## `world_ext_economy.cpp` fatals with `required_environment_slot_missing` when any
## of the F32 slots is absent, and the slice still answers `done = true`. Same flat
## 0.5 fill every other headless economy fixture uses.
func _register_environment_slots() -> bool:
	var scalar := PackedFloat32Array()
	scalar.resize(CELL_COUNT)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation",
			&"cell_temp_365d"]:
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
			&"cell_is_water", &"cell_has_river", &"cell_weather_type",
			&"cell_cover"]:
		var sid: int = _ext.register_component(slot_name, 2, 1, false)
		if sid < 0:
			print("  [env] register failed: %s" % slot_name)
			return false
		_ext.write_u8_range(
			sid, 0, terrain if slot_name == &"cell_terrain" else zeros_u8)
	return true


## Holds `cell.population` at `population` for every cell, through the single
## sampling point (`sample_effect_metrics`) both the tag bitset and the input
## digest read. This is what keeps the NATURAL tag state false everywhere.
func _set_population_override(population: int) -> void:
	var applied: Dictionary = _ext.set_effect_metric_override_for_test(
		METRIC_CELL_POPULATION, population * Q16_ONE, true)
	if not bool(applied.get("ok", false)):
		push_error("[FAIL] metric override applies: %s" % str(applied))


## The fixture's own Effect catalog.
##
## It has to declare the tag itself: the production tag dictionary derives
## `cell.settlement` from a population threshold this fixture cannot cross
## deterministically, and a card that never reads a tag would leave
## `tag_snapshot_needed` false -- in which case every epoch takes the skip path
## and there is nothing to measure.
func _configure_effects() -> bool:
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
	# The runtime key MUST carry the `ideology.effect.` prefix:
	# `NativeIdeologyRuntime::effect_program_key` prepends it when it looks the
	# program up, and the card row names the BARE key. A definition under the bare
	# key is invisible to that lookup, so `family_effect_metadata_pod` returns
	# false, `has_managed` stays 0, the consumer mask stays empty, and the tag
	# tables are (correctly) never built -- which reads exactly like "the tag
	# filter does nothing".
	program.key = StringName("ideology.effect.%s" % CELL_CARD_PROGRAM)
	program.cadence_days = 1
	program.managed = true
	program.source_kind = 4			# ideology
	program.target_domain = 2		# cell
	program.operation = 1			# multiply
	program.lifecycle = 0
	program.duration_days = -1
	program.stack_policy = 0
	program.stack_key = StringName(CELL_CARD_PROGRAM)
	program.max_stacks = 1
	program.target_selector_kind = SEL_OWN_TERRITORY
	program.target_selector_param = PackedInt32Array([32, TAG_INDEX])
	# The condition is what puts `cell.population` into the program's consumer
	# mask, which is what makes `tag_snapshot_needed` true for the ONLY legitimate
	# reason (a card reads a metric) rather than for the tag table alone.
	#
	# `arg0` is the DENSE index into `metric_keys`, not the global
	# `FamilyEffectMetricId`.
	var gate: Resource = preload("res://scripts/effect/effect_condition.gd").new()
	gate.op = 2					# METRIC_GTE
	gate.arg0 = 0					# dense id of TAG_METRIC_KEY
	gate.value_q16 = TAG_POPULATION * Q16_ONE
	var conditions: Array[Resource] = [gate]
	program.conditions = conditions
	var emit: Resource = preload("res://scripts/effect/effect_instruction.gd").new()
	emit.op = 11					# EMIT
	emit.arg0 = 0
	var instructions: Array[Resource] = [emit]
	program.instructions = instructions
	var program_command: Resource = preload(
		"res://scripts/effect/effect_command.gd").new()
	program_command.action = 1
	# A managed (instance) program may only issue COMMAND_APPLY in the domain its
	# `target_domain` implies; a cell-scoped modifier lives in the ECONOMY domain.
	program_command.domain = 2
	program_command.opcode = 1
	program_command.target_resolver = 1
	program_command.value_mode = 0
	program_command.value_q16 = Q16_ONE
	program_command.command_key = &"ideology.persistent"
	program_command.definition_key = &"economy.city.output_factor"
	var program_commands: Array[Resource] = [program_command]
	program.commands = program_commands
	definitions.append(program)

	var catalog_tags: Array[Dictionary] = [_settlement_tag()]
	catalog.definitions = definitions
	catalog.target_tags = catalog_tags
	# The PRODUCTION metric table in PRODUCTION order: `tag_metric_ids` carries the
	# dense index into this array while the sampler indexes by
	# `FamilyEffectMetricId`. The two line up only when the dense order equals the
	# enum order; a one-entry list would move `cell.population` from id 9 to 0 and
	# the flip would be invisible.
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


## The production metric table, in production order, read from the catalog's own
## `build()` rather than copied by hand: a hand copy is one enum append away from
## silently shifting every tag id.
func _production_metric_keys() -> PackedStringArray:
	var catalog: Resource = preload(
		"res://scripts/effect/effect_domain_catalog.gd").build()
	if catalog == null:
		push_error("[FAIL] production effect catalog did not build")
		return PackedStringArray([TAG_METRIC_KEY])
	var keys: PackedStringArray = catalog.metric_keys
	if keys.size() < 10 or String(keys[9]) != TAG_METRIC_KEY:
		push_error("[FAIL] metric table contract changed: index 9 is '%s', "
			% [String(keys[9]) if keys.size() > 9 else "<short>"]
			+ "expected '%s'" % TAG_METRIC_KEY)
	return keys


## The single tag this fixture declares: `cell.population >= TAG_POPULATION`.
func _settlement_tag() -> Dictionary:
	return {
		"name": TAG_NAME,
		"rows": [{
			"metric": TAG_METRIC_KEY,
			"op": 0,				# TARGET_TAG_GTE
			"threshold_q16": TAG_POPULATION * Q16_ONE,
			"clause": 0,
		}],
	}


## The sorted, deduped political class list, derived the way the production
## catalog derives it (`ideology_catalog.gd:78-90`).
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


## Field-for-field the catalog `ideology_tag_snapshot_stress_test.gd` uses, which
## is the shape the native validator accepts. The one thing that matters for B4 is
## the level row: `persistent_definition_keys` names the managed program and
## `persistent_selector_params1` carries the 1-based tag id, so the program
## consumes a tag and the tables get built.
func _ideology_catalog() -> Dictionary:
	var ids := PackedStringArray([
		"idea.b4_churn", "idea.beta", "idea.gamma", "idea.delta"])
	var levels := PackedInt64Array([0, 2 * Q16_ONE, 0, 0])
	return {
		"protocol_version": 1, "ideology_capacity": 2, "national_spirit_capacity": 1,
		"offer_choice_count": 3, "offer_cost_q16": Q16_ONE, "max_commands_per_slice": 64,
		"world_seed": SEED,
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
		# `Acquisition`: DISCOVER = 1, DRAW = 2, both = 3.
		"acquisition_flags": PackedByteArray([3, 3, 2, 2]),
		"rarity_weights": PackedInt32Array([1, 1, 1, 1]),
		"ideology_slot_costs": PackedInt32Array([1, 1, 1, 1]),
		"spirit_slot_costs": PackedInt32Array([1, 1, 1, 1]),
		"national_spirit_min_levels": PackedInt32Array([0, 0, 0, 0]),
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
		# One template row per level; card 0's row is the Effect PROGRAM.
		"level_persistent_offsets": PackedInt32Array([0, 1, 1, 1, 1]),
		"persistent_actions": PackedInt32Array([1]),
		"persistent_domains": PackedInt32Array([2]),
		"persistent_opcodes": PackedInt32Array([1]),
		"persistent_values_q16": PackedInt64Array([Q16_ONE]),
		"persistent_duration_days": PackedInt32Array([-1]),
		"persistent_stacks": PackedInt32Array([1]),
		"persistent_command_keys": PackedStringArray(["ideology.cell"]),
		"persistent_definition_keys": PackedStringArray([CELL_CARD_PROGRAM]),
		# Kind 12 = OWN_TERRITORY with `param[1]` = a 1-based tag id. This is what
		# makes B4 a TAG test: with `param[1] == 0` the selector would be "every
		# owned cell", which cannot move when a tag flips.
		"persistent_selector_kinds": PackedInt32Array([SEL_OWN_TERRITORY]),
		"persistent_selector_params0": PackedInt32Array([0]),
		"persistent_selector_params1": PackedInt32Array([TAG_INDEX]),
		"persistent_payload_i0": PackedInt64Array([0]),
		"persistent_payload_i1": PackedInt64Array([0]),
		"persistent_payload_i2": PackedInt64Array([0]),
		"persistent_payload_i3": PackedInt64Array([0]),
		"level_on_enter_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
		"on_enter_actions": PackedInt32Array(), "on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(),
		"on_enter_values_q16": PackedInt64Array(),
		"on_enter_duration_days": PackedInt32Array(),
		"on_enter_stacks": PackedInt32Array(),
		"on_enter_command_keys": PackedStringArray(),
		"on_enter_definition_keys": PackedStringArray(),
		"on_enter_payload_i0": PackedInt64Array(),
		"on_enter_payload_i1": PackedInt64Array(),
		"on_enter_payload_i2": PackedInt64Array(),
		"on_enter_payload_i3": PackedInt64Array(),
	}


# --- measurement helpers --------------------------------------------------


## One cell, one tag, one direction. Returns false when the runtime refused it,
## which is the one failure B4 has to report instead of measuring around.
func _apply_flip(cell: int, on: bool) -> bool:
	var applied: Dictionary = _ext.set_cell_tag_override_for_test(TAG_NAME, cell, on)
	_override_calls += 1
	if bool(applied.get("ok", false)):
		return true
	_override_rejected += 1
	if _first_reject_code.is_empty():
		_first_reject_code = String(applied.get("code", "unknown"))
	return false


## The tagged cells of every country's territory, read out of the PUBLISHED
## snapshot. `param0 = 0` means "the kind's own default", which for the territory
## selector resolves to the map size (`selector_cell_cap.h:102-113`), so a
## 100-cell country is enumerated completely rather than capped at 32.
func _tagged_cells() -> PackedInt32Array:
	var out := PackedInt32Array()
	for country in range(COUNTRY_COUNT):
		var anchor := int(_ext.query_country_anchor_cell(country))
		if anchor < 0:
			continue
		var cells: PackedInt32Array = _ext.query_effect_target_cells(
			anchor, SEL_OWN_TERRITORY, 0, TAG_INDEX)
		out.append_array(cells)
	out.sort()
	return out


## Every cell each country owns, from the same index the selector walks.
func _owned_cells_per_country() -> Array:
	var out: Array = []
	for country in range(COUNTRY_COUNT):
		var anchor := int(_ext.query_country_anchor_cell(country))
		if anchor < 0:
			out.append(PackedInt32Array())
			continue
		out.append(_ext.query_effect_target_cells(
			anchor, SEL_OWN_TERRITORY, 0, 0))
	return out


## Size of the symmetric difference: how many cells changed between two snapshots.
## This is the dirty scope, measured, not inferred.
func _changed_between(before: PackedInt32Array, after: PackedInt32Array) -> int:
	var seen := {}
	for cell in before:
		seen[cell] = true
	var common := 0
	for cell in after:
		if seen.has(cell):
			common += 1
	return before.size() + after.size() - 2 * common


## Does the published set equal the fixture's model exactly? Set equality, not a
## count comparison: a run that dropped one cell and gained another would have the
## right SIZE and the wrong scope.
func _matches_model(cells: PackedInt32Array, model: Dictionary) -> bool:
	if cells.size() != model.size():
		return false
	for cell in cells:
		if not model.has(cell):
			return false
	return true


## Sum of FAMILY_METRIC_COUNTRY_SETTLEMENT_CELL_COUNT over the four countries.
##
## The rebuild fills `country_tag_counts` from the SAME bitset the selector reads,
## so this is a second, independent measurement of the dirty scope -- and it is
## the one a card would actually see. `count_q16` is `count * 65536`
## (`economy_runtime.cpp:16884`), hence the shift.
func _metric_country_tag_sum() -> int:
	var total := 0
	for country in range(COUNTRY_COUNT):
		var anchor := int(_ext.query_country_anchor_cell(country))
		if anchor < 0:
			return -1
		var probe: Dictionary = _ext.sample_effect_metric_probe(
			METRIC_COUNTRY_SETTLEMENT_CELL_COUNT, anchor, 0)
		if not bool(probe.get("ok", false)):
			return -1
		total += int(probe.get("value", 0)) >> 16
	return total


## `min / median / max` of one per-day series, printed rather than asserted: a
## wall-clock assertion on a shared machine is a flake generator.
func _stat(values: Array, label: String) -> String:
	var ordered := values.duplicate()
	ordered.sort()
	var count := ordered.size()
	if count == 0:
		return "  [cost] %s: no samples" % label
	var mid := count >> 1
	var median := float(ordered[mid])
	if count % 2 == 0:
		median = (float(ordered[mid - 1]) + float(ordered[mid])) * 0.5
	return "  [cost] %s: min=%.3f median=%.3f max=%.3f (n=%d)" % [
		label, float(ordered[0]), median, float(ordered[count - 1]), count]


func _run_economy(day: int) -> bool:
	# 4096 slices: the bound has to cover a 400-cell day, not the 36-cell day the
	# stress fixture was written for.
	for slice_index in range(4096):
		var report: Dictionary = _ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 10000 + slice_index,
		})
		# `done == true` also means "the slice fatalled"; a fatal epoch never
		# commits, so the tag snapshot is never rebuilt from this day's overrides.
		if bool(report.get("fatal", false)):
			push_error("[FAIL] economy slice fatal on day %d: %s (%s)" % [
				day, String(report.get("fatal_reason", "unknown")),
				String(report.get("stage", "?"))])
			return false
		if bool(report.get("done", false)):
			return true
	push_error("[FAIL] economy day %d did not finish in 4096 slices" % day)
	return false


# --- assertion plumbing ---------------------------------------------------


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
