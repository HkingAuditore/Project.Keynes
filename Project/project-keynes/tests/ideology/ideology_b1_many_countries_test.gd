extends SceneTree
## B1 (plan section 14.2): 64 countries x 12 equipped idea cards per country, all of
## it on the MAIN THREAD (no worker, no second runtime).
##
## WHY THIS SCENARIO EXISTS
##
## Every other cell-layer gate in this project measures ONE country (B7, B8) or two
## (B10). B1 is the coexistence question at the scale the plan actually promises:
## does the derived cell layer stay correct and instance-free when the world has
## sixty-four independent card sets live at the same time?
##
## That is a different question from "is the layer correct", because three of the
## four things that can go wrong here are SCALE failures:
##
##   1. **Silent zero.** A front that emits nothing still reports fine. The only
##      way to tell "no contributions" apart from "no cards" is to assert on the
##      collector's own counters (`collect_entries`, `collect_derived_emitted`,
##      `cell_layer_rows_emitted`) AND on the front's per-country provenance.
##   2. **Instances.** The whole point of the migration is `instances = 0`
##      (plan section 1.1 / 12.4 / I01). A single card left on the instance backend
##      turns the derived layer into a second copy of the same effect, which is
##      invisible in the front's numbers and wrong in the game.
##   3. **One country only.** The rebuild walks `_countries` and the front is a
##      single shared object (see `step_derived_rebuild`). A fold that stops after
##      the first country looks identical to a complete one from `cell_count`
##      alone, so the number that is asserted here is the DISTINCT HANDLE COUNT in
##      the front -- 64, or the fixture failed.
##   4. **Per-cell thresholds.** The old per-card machinery (understanding
##      thresholds, level transitions, synergy settling) still runs on every one of
##      the 768 live cards. Its counters are printed so a reader can see that the
##      legacy path was exercised, not bypassed.
##
## THE FIXTURE
##
## A 32x16 world (512 cells) split into 64 contiguous 8-cell strips, one per
## country. Each country discovers and equips the same 12 cards. The cards are
## chosen from shipped content so that EVERY program row of every card is
## structurally eligible for the derived backend (cell domain, permanent,
## selector kind 12/14/15/16, single stack), which is what makes `instances = 0`
## an achievable assertion rather than a wish.
##
## Every tag in the domain catalog is rewritten to a satisfiable
## `cell.population >= 20` predicate. A freshly bootstrapped economy has
## population but no buildings, so the shipped predicates are legitimately false
## everywhere and every card would cover zero cells -- correct behaviour that is
## indistinguishable from "the card matched nothing" (measured in B7 as
## `own_tag_rejected = 6400`). Names are kept, only the rows change, so the
## catalog's synergy overrides keep resolving.
##
## Nothing about the runtime is relaxed: no worker is started, no DLL is swapped,
## no C++ path is bypassed. This is the same main-thread call set the game uses.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_b1_many_countries_test.gd

const WIDTH := 32
const HEIGHT := 16
const CELLS: int = WIDTH * HEIGHT          # 512 cells
const COUNTRY_COUNT := 64
const CELLS_PER_COUNTRY := 8               # 64 x 8 = 512, the whole grid
const CARDS_PER_COUNTRY := 12
const Q16_ONE := 65536
## Below the 30 people this fixture puts on every cell, so the synthetic tag
## predicate is satisfied everywhere and a zero front can only mean a defect.
const POPULATION_FLOOR := 20
const EPOCH_ID := 1
## A day is sliced: one `run_ideology_daily` call is NOT a day. The loop below
## waits for `done` and for `pending_transitions == 0`, so the bound only has to
## be larger than the number of stages a day can need. Measured at this size:
## ~12 calls per day, because the fold is sharded by a 0.45 ms time budget.
const MAX_SLICES_PER_DAY := 512
## A hang detector, not a performance gate. Wall clock on a shared build machine
## is a flake generator; anything near this bound is a hang, not a slow machine.
const WALL_CLOCK_BUDGET_MS := 900000
## 12 shipped cards whose every program row is derived-eligible, picked from
## distinct eras and schools with no two in the same exclusion group so the whole
## set can legally be equipped at once (verified against
## data/ideologies/default_ideology_catalog.tres + default_ideology_effects.tres).
##
## All twelve are selector kind 12 (OWN_TERRITORY). That is deliberate: an
## earlier version of this fixture used three kind-16 (TAG_SOURCE_COUNT) cards to
## exercise the fan-out path and MEASURED `targets_collected_empty = 3072` -- the
## fan-out kinds resolve no targets in an economy with no buildings, so those
## three cards were equipped and live yet contributed nothing. B1 is the scale
## gate, so it uses the shape that actually lands; the fan-out gap is a separate
## finding and belongs to B8, not here.
const CARD_KEYS: Array = [
	"idea.fire_keeping",          # era 0, harmony,      birth factor
	"idea.kin_hearth",            # era 0, mobilization, birth + housing need, 2 commands
	"idea.hunting_tradition",     # era 0, mobilization, game meat output
	"idea.ever_normal_granary",   # era 2, agrarian,     staple food need (.cut)
	"idea.open_ports",            # era 2, commerce,     city output
	"idea.village_compact",       # era 3, agrarian,     agriculture building output
	"idea.three_field_rotation",  # era 1, agrarian,     fertile soil regen
	"idea.scholar_office",        # era 1, learning,     knowledge building output
	"idea.standardization",       # era 1, industry,     manufacturing building output
	"idea.household_weaving",     # era 1, industry,     cloth output
	"idea.coppice_rotation",      # era 1, harmony,      timber regen + lumber (.cut), 2 commands
	"idea.public_hygiene",        # era 3, mobilization, birth + housing need (.cut), 2 commands
]
## The DISTINCT catalog stat each of the 12 cards above lands on (the `.cut`
## variants are sign suffixes on the same stat, not stats of their own: probing
## them by name returns `stat_unknown`).
const CARD_STATS: Array = [
	"economy.city.birth_factor",
	"economy.city.need.housing.consumption_factor",
	"economy.city.good.game_meat.output_factor",
	"economy.city.need.staple_food.consumption_factor",
	"economy.city.output_factor",
	"economy.city.building.agriculture_output_factor",
	"economy.city.resource.fertile_soil.regen_factor",
	"economy.city.building.knowledge_output_factor",
	"economy.city.building.manufacturing_output_factor",
	"economy.city.good.cloth.output_factor",
	"economy.city.resource.timber.regen_factor",
	"economy.city.good.lumber.output_factor",
]

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const IdeologyProfileScript = preload("res://scripts/ideology/ideology_profile.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

var _checks := 0
var _failures := 0
var _seq := 0
## Accumulated day-stepping evidence, filled by `_step_day`.
var _day_calls := 0
var _days_stepped := 0
## Effect-transaction ack bookkeeping (see `_ack_effect_transactions`).
var _effect_cursor := 0
var _effect_acked := 0
var _effect_ack_failures := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	var started_ms := Time.get_ticks_msec()

	# ── catalogs ─────────────────────────────────────────────────────────
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var econ_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	# `EffectDomainCatalog.build()` short-circuits to a cached precompiled catalog
	# when one exists, and a stale cache predates the ideology merge, which makes
	# every card row take the `pod_fail` exit. Passing the program catalog
	# explicitly bypasses the cache so the merge always runs (see B7).
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	var rewritten_tags := _make_all_tags_satisfiable(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	# 12 cards per country is the SCENARIO, and the shipped profile caps a country
	# at 2 (+5 unlock techs, max 6). The fixture owns the scenario, so it raises the
	# slot budget on the RESOURCE (consumed by `compile_native_catalog`) instead of
	# equipping fewer cards and calling it 12.
	_raise_ideology_capacity(catalog, CARDS_PER_COUNTRY)
	var native_ideology: Dictionary = catalog.compile_native_catalog(
		country_ir, country_ir)
	native_ideology.erase("ok")
	print("[B1] catalog: tags_rewritten=%d capacity=%d"
		% [rewritten_tags, int(native_ideology.get("ideology_capacity", -1))])

	var ids: PackedStringArray = native_ideology.get("ideology_ids",
		PackedStringArray())
	var dense_cards := PackedInt32Array()
	var missing := PackedStringArray()
	for key in CARD_KEYS:
		var dense := ids.find(String(key))
		if dense < 0:
			missing.append(String(key))
		dense_cards.append(dense)
	_expect("A5: all 12 chosen cards are in the compiled catalog",
		missing.is_empty(), "missing=%s" % str(missing))
	if not missing.is_empty():
		_finish(1)
		return
	_expect("A5b: the 12 cards are 12 DISTINCT dense ids",
		_distinct_count(dense_cards) == CARDS_PER_COUNTRY,
		str(dense_cards))

	# ── world + runtimes (main thread only) ──────────────────────────────
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot and fails
	# silently otherwise.
	ext.create_entities(CELLS)
	_fill_environment(ext)
	_expect("A0: economy configures",
		bool(ext.configure_economy(country_ir, profile, CELLS, 4242).get("ok", false)))
	_expect("A0b: effects configure",
		bool(ext.configure_effects(effect_ir).get("ok", false)))
	_expect("A0c: modifiers configure",
		bool(ext.configure_modifiers(mod_ir, CELLS).get("ok", false)))
	_expect("A0d: country configures", bool(ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 4242).get("ok", false)))

	# ── A: 64 countries, 8 contiguous cells each, explicit CSR ──────────
	#
	# `territory_offsets` must be a real CSR: length countries+1, starting at 0,
	# ending at territory_cells.size(). An EMPTY `country_ids` makes the runtime
	# hand every land cell to one default country, which would silently turn this
	# fixture into a 1-country one.
	var country_ids := PackedStringArray()
	var country_names := PackedStringArray()
	var cash := PackedInt64Array()
	var offsets := PackedInt32Array()
	var territory := PackedInt32Array()
	offsets.append(0)
	for index in range(COUNTRY_COUNT):
		country_ids.append("country.b1.%d" % index)
		country_names.append("B1-%d" % index)
		cash.append(0)
		for slot in range(CELLS_PER_COUNTRY):
			territory.append(index * CELLS_PER_COUNTRY + slot)
		offsets.append(territory.size())
	_expect("A1a: the CSR covers the whole grid",
		territory.size() == CELLS and int(offsets[0]) == 0
			and int(offsets[offsets.size() - 1]) == CELLS,
		"cells=%d last_offset=%d" % [territory.size(),
			int(offsets[offsets.size() - 1])])
	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": country_ids,
		"country_names": country_names,
		"country_cash": cash,
		"territory_offsets": offsets,
		"territory_cells": territory,
		"technology_offsets": _zero_offsets(COUNTRY_COUNT),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": _zero_offsets(COUNTRY_COUNT),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("A1: all 64 countries bootstrap", bool(boot.get("ok", false)), str(boot))

	var ideo_cfg: Dictionary = ext.configure_ideologies(native_ideology)
	_expect("A1b: ideologies configure", bool(ideo_cfg.get("ok", false)),
		str(ideo_cfg.get("reason", ideo_cfg.get("fatal_reason", str(ideo_cfg)))))

	# Resolve one handle per country from the COUNTRY runtime, not from the
	# economy epoch: the epoch snapshot is empty until it is captured, and asking
	# it first reported widest=0 and looked like "bootstrap_country failed".
	var handles := PackedInt64Array()
	var owned_counts := PackedInt32Array()
	for index in range(COUNTRY_COUNT):
		var anchor: int = index * CELLS_PER_COUNTRY
		var owned := 0
		var resolved := 0
		for slot in range(CELLS_PER_COUNTRY):
			var summary: Dictionary = ext.get_country_cell_summary(anchor + slot)
			if bool(summary.get("owned", false)):
				owned += 1
			var cell_handle := int(summary.get("country_handle", 0))
			if cell_handle != 0:
				resolved = cell_handle
		handles.append(resolved)
		owned_counts.append(owned)
	var distinct_handles := _distinct_count(handles)
	var all_nonzero := true
	for handle in handles:
		if int(handle) == 0:
			all_nonzero = false
	_expect("A2: every country resolved a non-zero handle", all_nonzero,
		str(handles))
	_expect("A2b: the 64 countries are 64 DISTINCT handles",
		distinct_handles == COUNTRY_COUNT,
		"distinct=%d of %d" % [distinct_handles, COUNTRY_COUNT])
	var min_owned := 1 << 30
	var max_owned := 0
	for count in owned_counts:
		min_owned = mini(min_owned, int(count))
		max_owned = maxi(max_owned, int(count))
	print("[B1] territory: countries=%d cells=%d owned_per_country=%d..%d"
		% [COUNTRY_COUNT, CELLS, min_owned, max_owned])
	_expect("A3: every country owns exactly %d cells" % CELLS_PER_COUNTRY,
		min_owned == CELLS_PER_COUNTRY and max_owned == CELLS_PER_COUNTRY,
		"min=%d max=%d" % [min_owned, max_owned])
	var territories: Dictionary = ext.get_country_territory_counts()
	# Reads the ECONOMY epoch snapshot, which is empty until `capture_country_epoch`
	# runs -- hence the zeros below. The country-runtime counts above are the ones
	# that prove the bootstrap landed.
	print("[B1] economy-epoch territory (empty until capture): countries=%s widest=%s total=%s"
		% [str(territories.get("country_count", "?")),
			str(territories.get("widest", "?")),
			str(territories.get("total_cells", "?"))])

	# ── economy: one colonist signature per cell, one committed day ──────
	var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, _epoch(EPOCH_ID, 0))
	_expect("A4a: the economy epoch opens", bool(epoch.get("ok", false)),
		str(epoch.get("reason", epoch.get("fatal_reason", "?"))))
	var sig_keys: PackedStringArray = econ_catalog.get("signature_keys",
		PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var economy_ok := false
	var economy_slices := 0
	if farmer >= 0:
		var stock := PackedInt64Array()
		stock.resize(CELLS * goods)
		stock.fill(0)
		var cell_idx := PackedInt32Array()
		var sig_idx := PackedInt32Array()
		var population := PackedInt64Array()
		var funds := PackedInt64Array()
		for cell in range(CELLS):
			cell_idx.append(cell)
			sig_idx.append(farmer)
			population.append(30)
			funds.append(10000000)
		economy_ok = bool(ext.bootstrap_economy({
			"cell_indices": cell_idx, "signature_ids": sig_idx,
			"population": population, "funds": funds,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		}).get("ok", false))
		for slice_index in range(512):
			economy_slices += 1
			if bool(ext.run_economy_slice({
					"day_index": 0, "tick_index": slice_index}).get("done", false)):
				break
	_expect("A4: the economy bootstraps", economy_ok)
	print("[B1] economy: day 0 finished after %d slices" % economy_slices)

	# ── equip 12 cards in each of the 64 countries ───────────────────────
	var equip: Dictionary = _equip_all(ext, handles, dense_cards)
	_expect("B0: every equip round settled without hitting the slice cap",
		bool(equip.get("ok", true)), str(equip.get("failure", "?")))
	print("[B1] equip: rounds=%d days_stepped=%d calls=%d rejected_commands=%d"
		% [int(equip.get("rounds", 0)), _days_stepped, _day_calls,
			int(equip.get("rejected", -1))])

	var per_country: Dictionary = _equipped_per_country(ext, handles)
	print("[B1] equipped cards per country: min=%d max=%d total=%d"
		% [int(per_country.get("min", -1)), int(per_country.get("max", -1)),
			int(per_country.get("total", -1))])
	_expect("B1: every country carries exactly %d equipped cards" % CARDS_PER_COUNTRY,
		int(per_country.get("min", -1)) == CARDS_PER_COUNTRY
			and int(per_country.get("max", -1)) == CARDS_PER_COUNTRY,
		"min=%s max=%s" % [str(per_country.get("min", "?")),
			str(per_country.get("max", "?"))])
	_expect("B1b: exactly %d cards are live in total" % (COUNTRY_COUNT * CARDS_PER_COUNTRY),
		int(per_country.get("total", -1)) == COUNTRY_COUNT * CARDS_PER_COUNTRY,
		"total=%s" % str(per_country.get("total", "?")))

	# The derived rebuild is a SLICE STAGE, so a reader who looks right after the
	# last `run_ideology_daily` may see a half-built front. Drain it explicitly
	# instead of guessing a call count.
	var drained: Dictionary = ext.drain_derived_cell_layer(_days_stepped)
	var drain_ok := bool(drained.get("ok", false)) and bool(drained.get("complete", false))
	print("[B1] drain: steps=%s complete=%s"
		% [str(drained.get("steps", "?")), str(drained.get("complete", "?"))])

	# ── C: the derived layer really produced contributions ───────────────
	# Fetched AFTER the drain: `cell_layer_rows_emitted` is copied from the last
	# COMPLETED materialise, so a report taken before the fold finished would
	# still hold the previous day's number.
	var report: Dictionary = ext.get_ideology_report()
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var materialize: Dictionary = ext.get_derived_materialize_report()
	var multi: Dictionary = ext.get_derived_multi_country_report()
	var rows_emitted := int(report.get("cell_layer_rows_emitted", -1))
	var collect_entries := int(report.get("collect_entries", -1))
	var collect_derived := int(report.get("collect_derived_emitted", -1))
	# `cell_layer_contribs_passed` is a DEAD counter: `_derived_contribs_passed`
	# is exported in `NativeIdeologyRuntime::report()` but nothing writes it since
	# the one-shot rebuild was removed (grep: one write site, the report line
	# itself). It is printed for the record and NOT asserted -- an assertion on it
	# would demand a number the production path cannot produce. The live
	# equivalents are `commands_folded` (work the fold actually did) and the
	# front's own `contribution_count`.
	var contribs_passed := int(report.get("cell_layer_contribs_passed", -1))
	var commands_folded := int(materialize.get("commands_folded", -1))
	var collect_templates := int(report.get("collect_templates", -1))
	var front_cells := int(layer.get("cell_count", 0))
	var front_contribs := int(layer.get("contribution_count", 0))
	var front_stats := int(layer.get("stat_count", 0))
	print("[B1] FLOW rows_emitted=%d commands_folded=%d dead_contribs_passed=%d "
		% [rows_emitted, commands_folded, contribs_passed]
		+ "collect_entries=%d collect_templates=%d collect_derived_emitted=%d "
		% [collect_entries, collect_templates, collect_derived]
		+ "collect_pod_fail=%d collect_targets_fail=%d program_empty=%d"
		% [int(report.get("collect_pod_fail", -1)),
			int(report.get("collect_targets_fail", -1)),
			int(report.get("collect_program_empty", -1))])
	print("[B1] TARGETS country_zero=%s domain_gate=%s economy_null=%s anchor_neg=%s "
		% [str(report.get("targets_country_zero", "?")),
			str(report.get("targets_domain_gate", "?")),
			str(report.get("targets_economy_null", "?")),
			str(report.get("targets_anchor_neg", "?"))]
		+ "collected_empty=%s fanout_no_tag=%s fanout_no_source=%s ring_empty=%s"
		% [str(report.get("targets_collected_empty", "?")),
			str(report.get("targets_fanout_no_tag", "?")),
			str(report.get("targets_fanout_no_source", "?")),
			str(report.get("targets_fanout_ring_empty", "?"))])
	print("[B1] FRONT installed=%s generation=%s stats=%d cells=%d contribs=%d "
		% [str(layer.get("installed", "?")), str(layer.get("layer_generation", "?")),
			front_stats, front_cells, front_contribs]
		+ "front_bytes=%s rows=%s programs_seen=%s programs_derived=%s"
		% [str(layer.get("front_bytes", "?")), str(materialize.get("rows_emitted", "?")),
			str(materialize.get("programs_seen", "?")),
			str(materialize.get("programs_derived", "?"))])
	# `truncated` is a hard section 12.4 condition: the derived path must never
	# drop a target. `missing_stat` counts contributions whose stat the Modifier
	# catalog does not know -- a CONTENT defect, reported rather than asserted here
	# because it is not this fixture's premise.
	print("[B1] FOLD truncated=%s missing_stat=%s pod_ok_keys=%s pod_fail_keys=%s"
		% [str(materialize.get("truncated", "?")),
			str(materialize.get("missing_stat", "?")),
			str(report.get("collect_pod_ok_keys", PackedStringArray())),
			str(report.get("collect_pod_fail_keys", PackedStringArray()))])
	_expect("C8: the derived fold did not truncate any target",
		int(materialize.get("truncated", -1)) == 0,
		"truncated=%s" % str(materialize.get("truncated", "?")))
	print("[B1] PROVENANCE countries_in_front=%d multi_country_cells=%d max_contributors=%d"
		% [(multi.get("countries", PackedInt64Array()) as PackedInt64Array).size(),
			int(multi.get("multi_country_cells", -1)),
			int(multi.get("max_contributors", -1))])

	_expect("A6: the runtime allocated a row for all 64 countries",
		int(report.get("countries_allocated", 0)) >= COUNTRY_COUNT,
		"countries_allocated=%s" % str(report.get("countries_allocated", "?")))
	_expect("C0: the derived rebuild drained to completion", drain_ok, str(drained))
	_expect("C1: the derived layer emitted rows", rows_emitted > 0,
		"cell_layer_rows_emitted=%d" % rows_emitted)
	_expect("C2: the collector admitted every live card",
		collect_entries >= COUNTRY_COUNT * CARDS_PER_COUNTRY,
		"collect_entries=%d expected>=%d"
			% [collect_entries, COUNTRY_COUNT * CARDS_PER_COUNTRY])
	_expect("C3: the collector produced derived contributions",
		collect_derived > 0, "collect_derived_emitted=%d" % collect_derived)
	_expect("C4: contributions reached the fold", commands_folded > 0,
		"commands_folded=%d (cell_layer_contribs_passed=%d is a dead counter: "
			% [commands_folded, contribs_passed]
		+ "exported by report() but never written since the one-shot rebuild was "
		+ "removed, so it cannot be evidence)")
	_expect("C5: the front is installed and covers cells",
		bool(layer.get("installed", false)) and front_cells > 0
			and front_contribs > 0,
		"installed=%s cells=%d contribs=%d"
			% [str(layer.get("installed", "?")), front_cells, front_contribs])
	# The one number a per-country fold cannot fake: the front is a single shared
	# object, so "64 distinct handles" can only be true if every country's rows
	# were folded into the same front.
	var front_countries: PackedInt64Array = multi.get("countries", PackedInt64Array())
	_expect("C6: all 64 countries reached the ONE shared front",
		front_countries.size() == COUNTRY_COUNT,
		"countries_in_front=%d expected=%d" % [front_countries.size(), COUNTRY_COUNT])

	# ── C7: per-card reach ───────────────────────────────────────────────
	#
	# The front is keyed by (stat, cell), so a total cannot say WHICH of the 12
	# cards landed. These are the 12 distinct stats the chosen cards name; the
	# probe reads one cell of country 0 through the same `effective_value` bridge
	# the economy uses, so a card that resolved no targets shows up as a missing
	# stat instead of hiding inside the row count.
	var stats_present := 0
	for stat_key in CARD_STATS:
		var probe: Dictionary = ext.get_effective_stat_value(String(stat_key), 0, 0, 1.0)
		var present := bool(probe.get("derived_present", false))
		if present:
			stats_present += 1
		print("[B1] CARD stat=%s ok=%s present=%s add=%s value=%s"
			% [String(stat_key), str(probe.get("ok", "?")), str(present),
				str(probe.get("derived_add", "?")), str(probe.get("value", "?"))])
	print("[B1] CARD stats present on cell 0: %d of %d"
		% [stats_present, CARD_STATS.size()])
	_expect("C7: every one of the 12 cards contributes to a cell",
		stats_present == CARD_STATS.size(),
		"present=%d of %d" % [stats_present, CARD_STATS.size()])
	_expect("C7b: the front carries one stat row per card stat",
		front_stats >= CARD_STATS.size(),
		"stat_count=%d cards=%d" % [front_stats, CARD_STATS.size()])

	# ── D: zero per-cell instances (I01, the point of the migration) ─────
	var instance_total := 0
	var instance_countries := 0
	var busiest := 0
	for handle in handles:
		var instances: Dictionary = ext.get_ideology_effect_instance_report(int(handle))
		var count := int(instances.get("count", 0))
		instance_total += count
		if count > 0:
			instance_countries += 1
			busiest = maxi(busiest, count)
	print("[B1] INSTANCES total=%d countries_with_instances=%d busiest=%d"
		% [instance_total, instance_countries, busiest])
	_expect("D1: a derived card set creates ZERO Effect instances",
		instance_total == 0,
		"instances=%d across %d countries (busiest=%d); a derived program must not "
			% [instance_total, instance_countries, busiest]
		+ "also create instances (I01)")

	# ── E: no errors, and the legacy per-card thresholds still ran ───────
	var last_error := String(report.get("last_error", ""))
	print("[B1] LEGACY commands_applied=%s commands_rejected=%s levels_advanced=%s "
		% [str(report.get("commands_applied", "?")),
			str(report.get("commands_rejected", "?")),
			str(report.get("levels_advanced", "?"))]
		+ "offers_opened=%s support_evaluations=%s ramp_terms_evaluated=%s "
		% [str(report.get("offers_opened", "?")),
			str(report.get("support_evaluations", "?")),
			str(report.get("ramp_terms_evaluated", "?"))]
		+ "program_evaluations=%s program_failures=%s"
		% [str(report.get("derived_program_evaluations", "?")),
			str(report.get("derived_program_failures", "?"))])
	_expect("E1: no runtime error was recorded", last_error.is_empty(),
		"last_error='%s'" % last_error)
	print("[B1] EFFECT transactions acked=%d ack_failures=%d"
		% [_effect_acked, _effect_ack_failures])
	_expect("E0: every Effect transaction the equips produced was acked",
		_effect_ack_failures == 0, "failures=%d" % _effect_ack_failures)
	print("[B1] TIMING rebuild_visits=%s steps=%s worst_step_ms=%.3f "
		% [str(report.get("cell_layer_rebuild_visits", "?")),
			str(report.get("cell_layer_rebuild_steps", "?")),
			float(report.get("cell_layer_rebuild_ms", 0.0))]
		+ "collect_ms=%.3f materialise_ms=%.3f slices_max_ms=%.3f"
		% [float(report.get("cell_layer_collect_ms", 0.0)),
			float(report.get("cell_layer_materialise_ms", 0.0)),
			float(report.get("max_slice_ms", 0.0))])

	var elapsed_ms := Time.get_ticks_msec() - started_ms
	print("[B1] === evidence: countries=%d cells_per_country=%d cards_per_country=%d "
		% [COUNTRY_COUNT, CELLS_PER_COUNTRY, CARDS_PER_COUNTRY]
		+ "live_cards=%d front_rows_emitted=%d front_cells=%d front_contribs=%d "
		% [int(per_country.get("total", 0)), rows_emitted, front_cells, front_contribs]
		+ "collect_entries=%d collect_derived=%d instances=%d days=%d elapsed_ms=%d ==="
		% [collect_entries, collect_derived, instance_total, _days_stepped,
			elapsed_ms])
	_expect("F1: the run finished inside the slice cap on every day",
		_day_calls > 0 and bool(equip.get("ok", true)),
		"days=%d calls=%d" % [_days_stepped, _day_calls])
	_expect("F2: the run finished inside the wall-clock budget (hang detector)",
		elapsed_ms < WALL_CLOCK_BUDGET_MS,
		"elapsed_ms=%d budget=%d" % [elapsed_ms, WALL_CLOCK_BUDGET_MS])

	# ---- PEAK MEMORY (plan 18.3) ----------------------------------------
	#
	# B1 rebuilds the front 12 times (one generation per equip round), so the
	# "retained + candidate coexist" case is definitely exercised here -- unlike B7,
	# which installs once and therefore never sees a `previous` front.
	var peakc: Dictionary = ext.get_ideology_report()
	var peak_retained := int(peakc.get("peak_retained_bytes", -1))
	var peak_candidate := int(peakc.get("peak_candidate_bytes", -1))
	var peak_total := int(peakc.get("peak_total_bytes", -1))
	print("[B1] PEAK retained=%d candidate=%d total=%d (bytes of the derived structure)"
		% [peak_retained, peak_candidate, peak_total])
	_expect("18.3: peak memory was recorded across the rebuilds", peak_total > 0,
		str(peak_total))
	_expect("18.3: a RETAINED front coexisted with a candidate", peak_retained > 0,
		str(peak_retained))
	_expect("18.3: total peak is the sum of both fronts",
		peak_total >= peak_retained + peak_candidate or
			peak_total == peak_retained + peak_candidate,
		"total=%d retained=%d candidate=%d"
			% [peak_total, peak_retained, peak_candidate])

	_finish(0 if _failures == 0 else 3)


## Discovers and equips all 12 cards in all 64 countries.
##
## ONE card per country per round on purpose. `equip()` refuses while the country
## already has a transition pending (`ideology_country_transition_pending`) and
## the shipped catalog HAS synergies, so submitting 12 equips for one country in
## one batch would apply the first and reject the other 11 -- a silent 1/12
## coverage that still reports `installed = true`.
func _equip_all(ext: Object, handles: PackedInt64Array,
		cards: PackedInt32Array) -> Dictionary:
	var day := 0
	# One point grant per country. `equip()` does not charge points, but the
	# proven sequence in B7/B10 grants them first and a fixture that skips a step
	# the runtime expects is how "the card was never equipped" gets misread as
	# "the derived layer does nothing".
	var grant_rows: Array = []
	for handle in handles:
		grant_rows.append({"op": 2, "day": 0, "handle": int(handle),
			"idea": -1, "value": 64 * Q16_ONE})
	ext.submit_ideology_commands(_commands(grant_rows))

	var discover_rows: Array = []
	for handle in handles:
		for card in cards:
			discover_rows.append({"op": 1, "day": 0, "handle": int(handle),
				"idea": int(card)})
	ext.submit_ideology_commands(_commands(discover_rows))
	day = _advance(ext, day, 3)

	var understand_rows: Array = []
	for handle in handles:
		for card in cards:
			understand_rows.append({"op": 8, "day": 0, "handle": int(handle),
				"idea": int(card), "value": 0})
	ext.submit_ideology_commands(_commands(understand_rows))
	day = _advance(ext, day, 3)

	var rounds := 0
	for card in cards:
		var equip_rows: Array = []
		for handle in handles:
			equip_rows.append({"op": 5, "day": 0, "handle": int(handle),
				"idea": int(card)})
		ext.submit_ideology_commands(_commands(equip_rows))
		# A round is not finished when the command is applied: the equip starts a
		# transition that only settles on a later poll, and the NEXT round's equip
		# is refused for that country until it does.
		var stepped: Dictionary = _step_day(ext, day)
		day += 1
		rounds += 1
		if not bool(stepped.get("ok", false)):
			return {"ok": false, "rounds": rounds, "rejected": -1,
				"failure": "round %d (card %d) day %d: %s"
					% [rounds, int(card), day - 1, str(stepped)]}

	# One more day so the last round's level transitions settle and the front is
	# rebuilt once more against the fully equipped world.
	var settle: Dictionary = _step_day(ext, day)
	day += 1
	if not bool(settle.get("ok", false)):
		return {"ok": false, "rounds": rounds, "rejected": -1,
			"failure": "settle day %d: %s" % [day - 1, str(settle)]}

	# Receipts are the only place a rejection names its reason. Count them so a
	# failure below can say WHICH command the runtime refused.
	var rejected := 0
	var reasons := PackedStringArray()
	var receipts: Dictionary = ext.poll_ideology_receipts(0, 4096)
	var statuses: PackedInt32Array = receipts.get("statuses", PackedInt32Array())
	var receipt_reasons: PackedStringArray = receipts.get("reasons",
		PackedStringArray())
	for index in range(statuses.size()):
		if int(statuses[index]) != 3:
			continue
		rejected += 1
		if reasons.size() < 5:
			reasons.append(String(receipt_reasons[index])
				if index < receipt_reasons.size() else "")
	if rejected > 0:
		print("[B1] rejected command reasons: %s" % str(reasons))
	return {"ok": true, "rounds": rounds, "rejected": rejected}


## Runs one day to completion: commands, transitions, active progress, instance
## refresh and the sharded derived rebuild. `done` alone is NOT enough -- the
## next equip round is refused while a transition is still pending -- so the loop
## also waits for `pending_transitions == 0`.
func _step_day(ext: Object, day: int) -> Dictionary:
	var calls := 0
	var last: Dictionary = {}
	for _slice in range(MAX_SLICES_PER_DAY):
		calls += 1
		_day_calls += 1
		last = ext.run_ideology_daily(day)
		if not bool(last.get("ok", true)):
			return {"ok": false, "calls": calls, "result": last}
		# WHY THE FIXTURE ACKS EFFECT TRANSACTIONS ITSELF
		#
		# An equip starts a transition and the transition only settles once its
		# Effect transactions are ACKED (`poll_pending_transition` reads
		# `transaction_status_pod`). In production two things do that: the Effect
		# worker, or the native domain peers (Modifier/Country/Economy). This
		# fixture has neither -- it is main-thread only and has no runtime host --
		# so nothing ever acks and `pending_transition_count` stays > 0 forever.
		# Measured before this was wired: `pending_transitions = 64` after 512
		# slices, so only ONE card per country could ever be equipped.
		#
		# The peer lifecycle itself is public API and is driven exactly as
		# `tests/effect/effect_runtime_test.gd:130-151` drives it:
		# preflight -> commit -> ack. This is the fixture playing the acker, not a
		# bypass of the runtime.
		_ack_effect_transactions(ext)
		if bool(last.get("done", false)) \
				and int(last.get("pending_transitions", 0)) == 0:
			_days_stepped += 1
			return {"ok": true, "calls": calls,
				"stage": String(last.get("stage", ""))}
	return {"ok": false, "calls": calls, "result": last}


## Drives every unfinished Effect transaction to ACKED.
##
## Polls pages of the transaction log (the API caps a page at 1024), then runs
## the three documented phases over the whole set. `ack_masks` must equal each
## transaction's `required_ack_mask`, which is exactly what the poll returns, so
## the fixture never invents an ack it was not asked for.
func _ack_effect_transactions(ext: Object) -> Dictionary:
	var ids := PackedInt64Array()
	var masks := PackedInt32Array()
	var cursor := _effect_cursor
	for _page in range(16):
		var polled: Dictionary = ext.poll_effect_transactions(cursor, 1024)
		var page_ids: PackedInt64Array = polled.get("transaction_ids",
			PackedInt64Array())
		if page_ids.is_empty():
			break
		var page_masks: PackedInt32Array = polled.get("required_ack_masks",
			PackedInt32Array())
		for index in range(page_ids.size()):
			var mask := int(page_masks[index]) if index < page_masks.size() else 0
			if mask == 0:
				continue
			ids.append(int(page_ids[index]))
			masks.append(mask)
		cursor = int(page_ids[page_ids.size() - 1])
	_effect_cursor = cursor
	if ids.is_empty():
		return {"seen": 0}
	var batch := {"transaction_ids": ids, "ack_masks": masks}
	var preflight: Dictionary = ext.preflight_effect_transactions(batch)
	var commit: Dictionary = ext.commit_effect_transactions(batch)
	var ack: Dictionary = ext.ack_effect_transactions(batch)
	_effect_acked += int(ack.get("acknowledged", 0))
	if not bool(preflight.get("ok", true)) or not bool(commit.get("ok", true)) \
			or not bool(ack.get("ok", true)):
		_effect_ack_failures += 1
		if _effect_ack_failures == 1:
			printerr("FAIL E0a: effect transaction lifecycle refused: preflight=%s commit=%s ack=%s"
				% [str(preflight), str(commit), str(ack)])
	return {"seen": ids.size(), "acked": int(ack.get("acknowledged", 0))}


func _advance(ext: Object, first_day: int, days: int) -> int:
	var day := first_day
	for _index in range(days):
		var stepped: Dictionary = _step_day(ext, day)
		# A day that cannot finish is a real failure, not a detail: the equip
		# rounds afterwards would be refused for a reason the receipt list can no
		# longer attribute. Reported through `_expect` so the counts stay honest.
		_expect("F0: day %d reached done with no pending transition" % day,
			bool(stepped.get("ok", false)), str(stepped))
		day += 1
	return day


func _equipped_per_country(ext: Object, handles: PackedInt64Array) -> Dictionary:
	var minimum := 1 << 30
	var maximum := 0
	var total := 0
	for handle in handles:
		var snapshot: Dictionary = ext.get_ideology_snapshot(int(handle))
		var locations: PackedInt32Array = snapshot.get("locations",
			PackedInt32Array())
		var equipped := 0
		for location in locations:
			if int(location) != 0:
				equipped += 1
		minimum = mini(minimum, equipped)
		maximum = maxi(maximum, equipped)
		total += equipped
	return {"min": minimum, "max": maximum, "total": total}


## Rewrites EVERY tag predicate to `cell.population >= POPULATION_FLOOR`.
##
## Names are kept and only the rows change: the ideology catalog declares synergy
## overrides that name other tags, and a tag that no longer resolves fails
## `configure_ideologies` with `ideology_synergy_override_tag_unknown`. Replacing
## the whole list (instead of one entry, as B7 does) is what makes 12 cards with
## 12 different tag filters all land on the same bootstrapped cells.
##
## `metric_keys` is deliberately NOT touched: `tag_metric_ids` carries the DENSE
## INDEX into that array, and a short list moves `cell.population` off its id, so
## the row reads the wrong metric and the tag never matches.
func _make_all_tags_satisfiable(domain: Resource) -> int:
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	var replaced := 0
	for index in range(tags.size()):
		var name := String(tags[index].get("name", ""))
		if name.is_empty():
			continue
		var row := {
			"metric": "cell.population",
			"op": 0,                                  # TARGET_TAG_GTE
			"threshold_q16": POPULATION_FLOOR * Q16_ONE,
			"clause": 0,
		}
		var rows: Array[Dictionary] = [row]
		tags[index] = {"name": name, "rows": rows}
		replaced += 1
	domain.target_tags = tags
	return replaced


## Raises the per-country ideology slot budget so 12 cards fit.
##
## The shipped profile is capacity 2, growing to 6 with technology. B1's premise
## is 12 cards per country, so the scenario raises the NUMBER the runtime reads
## rather than equipping 6 and calling it 12. This is fixture configuration, not
## a runtime change: `compile_native_catalog` reads the resource, and the native
## side only ever sees the compiled values.
func _raise_ideology_capacity(catalog: Resource, capacity: int) -> void:
	var source: Resource = catalog.profile
	var raised: Resource = source.duplicate() if source != null \
		else IdeologyProfileScript.new()
	raised.ideology_capacity = capacity
	raised.ideology_capacity_max = capacity
	catalog.profile = raised


func _zero_offsets(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(count + 1)
	out.fill(0)
	return out


func _distinct_count(values) -> int:
	var seen := {}
	for value in values:
		seen[int(value)] = true
	return seen.size()


func _fill_environment(ext: Object) -> void:
	# The environment slots `capture_environment` requires, registered AFTER
	# `create_entities` so they are sized.
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(CELLS)
	var zeros_u := PackedByteArray()
	zeros_u.resize(CELLS)
	for slot_name in f32_slots:
		var sid := int(ext.component_id(slot_name))
		if sid < 0:
			sid = int(ext.register_component(slot_name, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zeros_f)
	for slot_name in u8_slots:
		var sid := int(ext.component_id(slot_name))
		if sid < 0:
			sid = int(ext.register_component(slot_name, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zeros_u)


func _epoch(epoch: int, sample_day: int) -> Dictionary:
	return {
		"sample_day": sample_day, "epoch_id": epoch, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1}


func _u8_zero(count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(count)
	return out


## Command batch. Every column must be the SAME length as `opcodes`, and
## `sequences` is the idempotency key: it must stay monotonic ACROSS batches, or
## every later command looks like a duplicate and is dropped silently.
func _commands(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row in rows:
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		producers.append(1)
		_seq += 1
		sequences.append(_seq)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return {
		"opcodes": opcodes, "effective_days": days,
		"source_priorities": priorities, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	}


func _finish(code: int) -> void:
	print("=== B1 many countries: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
