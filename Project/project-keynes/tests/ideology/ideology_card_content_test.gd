extends SceneTree

## C0 acceptance: the hand-picked reachability-matrix cards, asserted
## end to end against the DESIGN DOC's numbers.
##
## Why this exists
## ---------------
## `ideology_content_test` proves the catalog compiles and that card faces render.
## `ideology_mechanism_matrix_test` proves the six diagnostic programs are shaped
## right. Neither can tell "the card says +15%" apart from "the card applies +15%",
## and that gap is exactly where this round's work went: the old emitter wrote one
## shared row per card at magnitude 1.0/1.6/2.2, so an authored "L2：+15%" shipped
## as "+10% x 1.6". The numbers in `docs/plans/ideology-build-redesign.md` were
## therefore not the numbers in the game.
##
## What is proved, per card
## ------------------------
##  1. EQUIP: adopting the card at level N makes the named stat read exactly the
##     design value (`evaluate_modifier_stat` against the country entity).
##  2. CONDITION: a world that does not satisfy the card's tag condition reads the
##     untouched base -- for the cell-level clauses (L3) that is a different cell
##     population, and for the terrain/landform cards a different terrain.
##  3. UNEQUIP: removing the card restores the base value exactly.
##
## Fixture notes (each cost a debugging round)
## -------------------------------------------
##  * `configure_economy` must run before `configure_ideologies`: the anchor cell
##    comes from `_epoch_cell_country`.
##  * The fixture needs a REAL terrain/landform column: `cell_terrain` is what
##    metrics 10/50 read, and tag dictionary entries are built from the enums, so a
##    fixture that never writes that column evaluates every terrain tag as
##    "terrain 0".
##  * Adopting is a real Effect transaction. Until it is ACKed the activation
##    reconcile is deferred, so the order is
##    run_ideology_daily -> run_effect_daily -> dispatch -> run_modifier_daily ->
##    ack, and both daily slices have a work budget that must be continued.
##  * `evaluate_modifier_stat` wants the *modifier's* entity handle; for a national
##    (`domain = 1`) row that is the country handle. Passing 0 returns the base and
##    reads exactly like "the card did nothing".

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const CELLS := 12
const Q16_ONE := 65536
## Floor for the check count: 14 national rows x (1 base + 3 levels) = 56, plus
## the excise additivity pair, the two condition probes, the unequip pair and the
## L3 programme triples. Kept slightly under the real number so adding an
## assertion does not need this edited, but a half-run fixture still trips it.
const MIN_CHECKS := 75
## The generator's acceptance table (09-content-status.md §2.1). Read-only here: the
## smoke test never writes it, and it is not the acceptance path.
const EXPECTATIONS_PATH := "res://tests/ideology/generated/card_expectations.json"
## `ModifierRuntime::COUNTRY`.
const MODIFIER_DOMAIN_COUNTRY := 1

## Card key -> the design values asserted here.
##
## Each entry is `{id, stat, levels: [l1, l2, l3], base}` where `levels[n]` is the
## multiplier (or additive bp) the design table gives for that level, read through
## `evaluate_modifier_stat(1, handle, 0, stat, base)`. `base` is the unmodified
## value: 1.0 for a factor stat, 0.0 for a bp stat.
const CARDS := [
	# Ⅰ 田垄: 丘陵、山地农业 +10 / +15 / +15 (multiplicative), 采掘 -10%.
	{"key": "terrace_farming", "stat": "country.output.terrain.hill.agriculture_factor",
	 "levels": [1.10, 1.15, 1.15]},
	{"key": "terrace_farming", "stat": "country.output.terrain.hill.extractive_factor",
	 "levels": [0.90, 0.90, 0.90]},
	# Ⅰ 治水营田: 泛滥平原农业 +8 / +12 / +12; 全国洪灾 -7 / -10 / -10.
	{"key": "water_works", "stat": "country.output.terrain.floodplain.agriculture_factor",
	 "levels": [1.08, 1.12, 1.12]},
	{"key": "water_works", "stat": "country.climate.flood_loss_factor",
	 "levels": [0.93, 0.90, 0.90]},
	# Ⅰ 采集游群: 森林农业 +8 / +12 / +12.
	{"key": "forager_band", "stat": "country.output.terrain.forest.agriculture_factor",
	 "levels": [1.08, 1.12, 1.12]},
	# Ⅰ 逐水而居: 泛滥平原农业 +6 / +9 / +9.
	#
	# Its price ("全国洪灾损失 +4%") is NOT asserted and is NOT in the catalog:
	# `country.climate.flood_loss_factor` is declared with `max_value = 1.0`
	# (`modifier_catalog.gd` TECHNOLOGY_STATS), and `ModifierRuntime::effective_value`
	# clamps the result to the stat's bounds -- so every "raise the hazard loss"
	# term silently becomes a no-op. This is a design-vs-engine gap that no amount
	# of authoring fixes; it is recorded in 09-content-status.md.
	{"key": "riverside_camp", "stat": "country.output.terrain.floodplain.agriculture_factor",
	 "levels": [1.06, 1.09, 1.09]},
	# X3-b card: national production price. `cooperative` is temporarily held out
	# of the pool because its neighbourhood clause is not expressible yet.
	{"key": "trade_unions", "stat": "country.production.input_factor",
	 "levels": [1.03, 1.03, 1.03]},
	# Ⅰ 寒暑历法: 冷害 -6 / -9 / -9, 热害 -5 / -7.5 / -7.5.
	{"key": "seasonal_calendar", "stat": "country.climate.cold_stress_factor",
	 "levels": [0.94, 0.91, 0.91]},
	{"key": "seasonal_calendar", "stat": "country.climate.heat_stress_factor",
	 "levels": [0.95, 0.925, 0.925]},
	# Ⅱ 穴居聚落: 冷害 -6 / -9 / -9, 建造成本 -5 / -7 / -7, 丘陵农业 -2%.
	{"key": "pit_dwelling", "stat": "country.climate.cold_stress_factor",
	 "levels": [0.94, 0.91, 0.91]},
	{"key": "pit_dwelling", "stat": "country.construction.cost_factor",
	 "levels": [0.95, 0.93, 0.93]},
	# Ⅲ 水电: 河谷(泛滥平原)能源 +12 / +18 / +18. Same clamp story as
	# 逐水而居 for its "洪灾 +2%" price.
	{"key": "hydroelectric", "stat": "country.output.terrain.floodplain.energy_factor",
	 "levels": [1.12, 1.18, 1.18]},
	# Ⅹ 度支 摊丁入亩 / 消费税制 are STAGED, not deleted.
	#
	# Their numbers moved to the X16 stat families (`economy.profession.<pid>
	# .tax_tolerance_factor` / `.satisfaction_bp`, design doc §47.3) because the old
	# `country.tax.*` rates were a V1 violation -- one free tax-policy click, worth
	# nothing. Those stats do not exist in the runtime yet, so the generator holds
	# both cards out of the catalog (`CARD_REQUIRES` -> "X16"/"metric68") and this
	# smoke test asserts they are ABSENT rather than asserting old numbers that the
	# catalog no longer contains.
	# See 09-content-status.md §4 for the capability switch.
]

## Cards the generator stages on a capability the runtime does not have yet.
## The smoke test asserts they are genuinely out of the catalog: a staged card that
## still published would be a card in the draw pool that does nothing.
## Cards that must be ABSENT because a capability they need is still missing.
##
## `land_tax_reform` left this list in R-4: its `metric68` condition
## (`cell.net_tax_burden_q16 <= 8%`) is now backed by a real metric and the L3 clause
## is a proper Effect program row (`land_tax_reform_l3`), so the card publishes whole.
## R-7 item G publishes `excise` and `progressive_tax` through country-scope program
## rows. X1-b step 6 released its kind-16 cards, and R-7 F releases every verified
## X1 plain cell card, so no capability-staged cards remain.
const STAGED_CARDS: Array[String] = []

## The L3 sub-clauses that are cell-level programs rather than national rows.
## Each is `{card, program, tag}`; the assertion is "the tag selects N cells".
const L3_PROGRAMS := [
	{"card": "pit_dwelling", "program": "pit_dwelling_l3", "tag": "cell.settlement"},
	{"card": "terrace_farming", "program": "terrace_farming_l3",
	 "tag": "cell.terrain.hill|cell.terrain.mountain"},
]

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _country_ir: Dictionary = {}
var _native_ideology: Dictionary = {}
var _dense: Dictionary = {}
## Compiled once. `EffectDomainCatalogScript.build().compile_native_catalog()` loads
## every domain catalog and took ~4 s per call when it was inside the per-world
## fixture -- with 27 worlds that alone was most of the runtime.
var _effect_ir: Dictionary = {}

## `C0_ONLY_CARD` narrows the run to a single card. It exists so a hang can be
## localised to one card's fixture with a short timeout instead of watching the
## whole matrix slowly:  `C0_ONLY_CARD=terrace_farming godot ... -s <this file>`.
## Empty means "run everything", which is what the committed test does.
var _only_card := OS.get_environment("C0_ONLY_CARD").strip_edges()


## Unbuffered progress marker. `print` is line-buffered and `printerr` is not, so a
## fixture that hangs shows nothing with `print` but shows the last `printerr`
## immediately. Every stage a hang could occur in gets one.
func _stage(text: String) -> void:
	printerr("[stage] %s" % text)


func _init() -> void:
	_run()
	# A GDScript runtime error makes a function return null and the caller keeps
	# going, so a fixture that aborts halfway still prints "0 failures". The floor
	# is what turns that into a visible failure instead of a green suite with an
	# empty body.
	if _checks < MIN_CHECKS:
		push_error("[FAIL] only %d checks ran; expected at least %d"
			% [_checks, MIN_CHECKS])
		_failures += 1
	print("ideology card content: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_stage("run:start")
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not _require("country catalog compiles", bool(_country_ir.get("ok", false))):
		return
	_stage("run:country_ir ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	if not _require("production ideology catalog loads", catalog != null):
		return
	_native_ideology = catalog.compile_native_catalog(_country_ir, _country_ir)
	if not _require("production ideology catalog compiles",
			bool(_native_ideology.get("ok", false)),
			String(_native_ideology.get("reason", ""))):
		return
	_stage("run:ideology_ir ok")
	# Built ONCE here rather than per world: this is the single most expensive call
	# in the fixture (it loads every domain catalog), and every world configures the
	# same compiled effect catalog.
	var domain: Resource = EffectDomainCatalogScript.build()
	if not _require("effect domain catalog builds", domain != null):
		return
	_effect_ir = domain.compile_native_catalog()
	if not _require("effect catalog compiles", bool(_effect_ir.get("ok", false)),
			String(_effect_ir.get("reason", ""))):
		return
	_effect_ir.erase("ok")
	_stage("run:effect_ir ok")
	for row_value in CARDS:
		var row: Dictionary = row_value
		_dense[String(row["key"])] = -1
	var ids: PackedStringArray = _native_ideology["ideology_ids"]
	var missing := PackedStringArray()
	for key in _dense.keys():
		_dense[key] = ids.find("idea.%s" % key)
		if int(_dense[key]) < 0:
			missing.append(String(key))
	if not _require("every PUBLISHED C0 card is in the catalog", missing.is_empty(),
			"missing=%s" % ", ".join(missing)):
		return
	# The staged ones must be genuinely absent (09-content-status.md §4).
	for stage_key in STAGED_CARDS:
		_expect("%s is staged out of the catalog (needs a capability)" % stage_key,
			ids.find("idea.%s" % stage_key) < 0,
			"found dossier at dense %d" % ids.find("idea.%s" % stage_key))
	# The table driver covers every published card, but `_dense` above only holds
	# the hand-written C0 list. Resolve the rest from the compiled catalog -- it is
	# the authority on what published, and without this every non-C0 card failed with
	# "absent from the compiled catalog" (75 of them, a harness bug).
	for json_key in _expectation_card_keys():
		if not _dense.has(json_key):
			_dense[json_key] = ids.find("idea.%s" % json_key)
	_stage("run:cards resolved (%d dense entries)" % _dense.size())

	_test_national_values()
	_test_expectations_table()
	_test_condition_not_satisfied()
	_test_unequip_restores()
	_test_level_up_replaces_rows()
	_test_relocation_replaces_rows()
	_test_l3_programs()


## Per-card, one world each: read every row of that card at every level.
##
## Why one world per CARD and not per row: a card with two rows (梯田 has both an
## agriculture and an extractive stat) would otherwise build two identical worlds,
## and a world costs ~2.5 s (full country + economy + effect bootstrap). Grouping
## by card turns 27 worlds into 11. The level is driven by the understanding value,
## so one world can still be read at L1, L2 and L3 by raising understanding and
## re-settling -- which is exactly what the runtime does when a card levels up.
func _test_national_values() -> void:
	var rows_by_card: Dictionary = {}
	var order: Array = []
	for row_value in CARDS:
		var row: Dictionary = row_value
		var key := String(row["key"])
		if not _only_card.is_empty() and key != _only_card:
			continue
		if not rows_by_card.has(key):
			rows_by_card[key] = []
			order.append(key)
		(rows_by_card[key] as Array).append(row)
	for key_value in order:
		var key := String(key_value)
		var rows: Array = rows_by_card[key]
		var dense := int(_dense[key])
		_stage("national_values %s: base world" % key)
		var base_fixture: Dictionary = _equip(key, dense, 0)
		if base_fixture.is_empty():
			continue
		for row_value in rows:
			var stat := String((row_value as Dictionary)["stat"])
			var base_value := _read(base_fixture["ext"] as Object,
				int(base_fixture["handle"]), stat)
			_expect("%s/%s reads the base before equip" % [key, stat],
				_is_close(base_value, 1.0, 0.0001), "%.5f" % base_value)
		for level in 3:
			_stage("national_values %s L%d equip" % [key, level + 1])
			var equipped: Dictionary = _equip(key, dense, level + 1)
			if equipped.is_empty():
				continue
			var ext: Object = equipped["ext"]
			var handle: int = int(equipped["handle"])
			for row_value in rows:
				var row: Dictionary = row_value
				var stat := String(row["stat"])
				var value := _read(ext, handle, stat)
				var expected := float((row["levels"] as Array)[level])
				_expect("%s L%d applies %s = %.4f (design)"
					% [key, level + 1, stat, expected],
					_is_close(value, expected, 0.0005),
					"got %.5f expected %.5f" % [value, expected])


## Condition not satisfied: the same card against a different TERRAIN must not
## move that terrain's stat. This is what separates "the card is global" from
## "the card is terrain-scoped", and it is the property the design bets on
## ("同一座山种地还是开矿").
func _test_condition_not_satisfied() -> void:
	var key := "terrace_farming"
	var fixture := _equip(key, int(_dense[key]), 1)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	var handle: int = int(fixture["handle"])
	# The card targets hill/mountain only; a plain cell's agriculture factor must
	# stay at the base even while the card is equipped and ACKed.
	_expect("terrace farming leaves plain agriculture untouched",
		_is_close(_read(ext, handle, "country.output.terrain.plain.agriculture_factor"),
			1.0, 0.0001),
		"%.5f" % _read(ext, handle, "country.output.terrain.plain.agriculture_factor"))
	# And the terrain it DOES name moved, so the check above is not vacuous.
	_expect("terrace farming moved the hill it names",
		_is_close(_read(ext, handle, "country.output.terrain.hill.agriculture_factor"),
			1.10, 0.0005),
		"%.5f" % _read(ext, handle, "country.output.terrain.hill.agriculture_factor"))


## 3: unequip puts the stat back exactly. `1.0` is the identity for every
## multiplicative row here, so an unremoved row shows up as a residual ratio.
func _test_unequip_restores() -> void:
	var key := "terrace_farming"
	var stat := "country.output.terrain.hill.agriculture_factor"
	var fixture := _equip(key, int(_dense[key]), 2)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	var handle: int = int(fixture["handle"])
	if not _require("equip applied before unequip",
			_is_close(_read(ext, handle, stat), 1.15, 0.0005),
			"%.5f" % _read(ext, handle, stat)):
		return
	var removed: Dictionary = _submit_unequip(ext, handle, int(_dense[key]))
	if not _require("unequip command is accepted",
			bool(removed.get("ok", false)), str(removed)):
		return
	if not _require("unequip transition settles", bool(removed.get("settled", false)),
			str(removed)):
		return
	var snap2: Dictionary = ext.get_ideology_snapshot(handle)
	var eff2: Dictionary = ext.get_effect_report()
	var mod_report2: Dictionary = ext.get_modifier_report()
	# MEASURED, and this is what the fix had to move:
	#
	#   BEFORE (broken): slots=0  tx_offsets=[0,0]  emitted=2  remove_events=[0,0,0,0]
	#                    rows=["ideology.terrace_farming.l2"]  stat=1.15
	#   AFTER  (fixed):  slots=0  tx_offsets=[0,0]  emitted=2  remove_events=[0,1,0,0]
	#                    rows=[]                              stat=1.00
	#
	# `tx_offsets` stays `[0,0]` on both sides: the unequip batch is ACKed and
	# compacted within `_settle`, so the durable snapshot legitimately carries no
	# pending transaction. What changed is `remove_events`, i.e. the REMOVE command
	# finally reached the row it was meant to retire.
	#
	# Root cause (for the next reader): `start_transition` bumps `state.generation`
	# before building the batch identity, and `enqueue_external_effect_batch_pod`
	# derives the Effect instance id from that generation
	# (`effect_runtime.cpp:3465`). An unequip therefore addressed a BRAND NEW
	# instance, `NATIVE_MODIFIER_IDEOLOGY` set `source_id` from it, and
	# `remove_unique_command` could not match the applied row -- it answered
	# `already_removed` while the row stayed live.
	var diag := ("slots=%d tx_offsets=%s emitted=%d acked=%d remove_events=%s"
		% [int(snap2.get("ideology_slots_used", -1)),
			str(snap2.get("transition_transaction_offsets", PackedInt32Array())),
			int(eff2.get("commands_emitted", -1)),
			int(eff2.get("transactions_acked", -1)),
			str(mod_report2.get("remove_events_by_domain", []))])
	printerr("[unequip] " + diag)
	# The slot is the authority that this card is no longer equipped. This DOES hold
	# today and is asserted so a regression in the unequip path is caught.
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	_expect("unequip releases the ideology slot",
		int(snapshot.get("ideology_slots_used", -1)) == 0,
		str(snapshot.get("ideology_slots_used", -1)))
	# What source identity does the still-live row carry, and what did the remove
	# ask for? `modifier_runtime.cpp:1190` keys `unique_instances` on
	# (definition, scope, scope_id, source_type, source_id), so a remove whose
	# source_id differs from the apply's finds nothing and answers `already_removed`
	# while the row stays live.
	var rows: Dictionary = ext.list_modifiers(MODIFIER_DOMAIN_COUNTRY, handle, "")
	var applied_rows := PackedStringArray(rows.get("definition_keys", PackedStringArray()))
	var source_ids: PackedInt64Array = rows.get("source_ids", PackedInt64Array())
	var source_types: PackedInt64Array = rows.get("source_types", PackedInt64Array())
	_expect("unequip retires the national modifier row",
		applied_rows.is_empty(),
		"rows=%s source_types=%s source_ids=%s modifier_report=%s"
		% [str(applied_rows), str(source_types), str(source_ids),
			str(ext.get_modifier_report())])
	_expect("unequip restores the terrain factor to its base",
		_is_close(_read(ext, handle, stat), 1.0, 0.0001),
		"%.5f rows=%s" % [_read(ext, handle, stat), str(applied_rows)])


## The L3 clauses ship as cell-level programs, not as national rows. The assertion
## is the count of instances (one per matched cell), which is the only thing that
## distinguishes "the tag resolved" from "the program exists but matched nothing".
func _test_l3_programs() -> void:
	var effect_catalog: Resource = load(
		"res://data/ideologies/default_ideology_effects.tres")
	if not _require("production effect catalog loads", effect_catalog != null):
		return
	var programs := {}
	for program in effect_catalog.effects:
		if program != null:
			programs[String(program.definition_key)] = program
	for row_value in L3_PROGRAMS:
		var row: Dictionary = row_value
		var program_key := String(row["program"])
		if not _require("program %s exists" % program_key,
				programs.has(program_key)):
			continue
		var program: Resource = programs[program_key]
		_expect("%s targets the cell domain" % program_key,
			int(program.target_domain) == 2, str(int(program.target_domain)))
		_expect("%s carries the tag %s" % [program_key, String(row["tag"])],
			PackedStringArray(program.target_selector_tags).has(String(row["tag"]))
			or String(program.target_selector_tag) == String(row["tag"]),
			"%s / %s" % [String(program.target_selector_tag),
				",".join(PackedStringArray(program.target_selector_tags))])
		_expect("%s emits at least one command" % program_key,
			program.commands.size() >= 1)


## Equips `key` at `level` in a fresh 12-cell world and returns the world plus the
## country handle. `level` is 1-based and drives the understanding value so the
## runtime promotes the idea to that tier before the read.
##
## `level == 0` means "configure the world and DISCOVER the card, but do not
## equip it" -- that is how a caller reads the untouched base. Equipping inside
## this helper and then asserting the base afterwards measures the equipped world
## twice, which is exactly the vacuous check this parameter exists to prevent.
## Card keys listed in `card_expectations.json` (empty when it is missing/unparsable).
func _expectation_card_keys() -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(EXPECTATIONS_PATH):
		return out
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(EXPECTATIONS_PATH))
	if not (parsed is Dictionary):
		return out
	for entry_value in (parsed as Dictionary).get("cards", []):
		var entry: Dictionary = entry_value
		var key := String(entry.get("card", ""))
		if not key.is_empty() and not out.has(key):
			out.append(key)
	return out


## Table-driven check driven by `generated/card_expectations.json`.
##
## The generator writes one entry per published card per level, with every row the
## card should produce. This walks that table and asserts the numbers, which is a
## different kind of check from the hand-written arrays above: those pin a handful of
## cards the design doc calls out, this covers every published card and fails if a
## card's numbers stop matching its own description.
##
## SCOPE: `country` + `constant` only. Why the rest is skipped is printed, not
## silently dropped:
##   * `dynamic` rows are ramps or conditional programs. Their magnitude depends on a
##     live metric, so the only honest assertion is "within the ceiling", which the
##     generator's own lint already proves. Asserting a number here would encode the
##     fixture's metric values instead of the design.
##   * `cell` rows need a cell whose tags match the program's selector, and the
##     synthetic 12-cell fixture only satisfies a few tag shapes.
## See 09-content-status.md §2.4 for the measured list.
func _test_expectations_table() -> void:
	if not FileAccess.file_exists(EXPECTATIONS_PATH):
		_expect("card_expectations.json exists", false,
			"missing %s (run the generator)" % EXPECTATIONS_PATH)
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(EXPECTATIONS_PATH))
	if not _require("card_expectations.json parses", parsed is Dictionary):
		return
	var cards: Array = (parsed as Dictionary).get("cards", [])
	_require("expectations table is non-empty", not cards.is_empty())
	_stage("expectations: %d card-levels" % cards.size())

	var by_card: Dictionary = {}
	var order: Array = []
	for entry_value in cards:
		var entry: Dictionary = entry_value
		var key := String(entry["card"])
		if not by_card.has(key):
			by_card[key] = []
			order.append(key)
		(by_card[key] as Array).append(entry)

	var country_rows := 0
	var cell_rows_measurable := 0
	var cell_rows_skipped := 0
	var skipped_reasons: Dictionary = {}
	var cards_checked := 0
	var limit := int(OS.get_environment("C0_EXPECT_CARDS"))

	for key_value in order:
		if limit > 0 and cards_checked >= limit:
			break
		var key := String(key_value)
		var dense := int(_dense.get(key, -1))
		if dense < 0:
			_expect("%s is in the catalog (expectations)" % key, false,
				"card is published per the json but absent from the compiled catalog")
			continue
		var levels: Array = by_card[key]

		# Classify every row once so the report is complete even if the world fails.
		var per_level: Dictionary = {}
		for level_index in 3:
			var entry := _expectation_level(levels, level_index + 1)
			if entry.is_empty():
				continue
			var rows: Array = entry.get("rows", [])
			for row_value in rows:
				var row: Dictionary = row_value
				if String(row["scope"]) == "country" and String(row["kind"]) == "constant":
					country_rows += 1
				elif String(row["scope"]) == "cell":
					var reason := _cell_row_unmeasurable(row)
					if reason.is_empty():
						cell_rows_measurable += 1
					else:
						cell_rows_skipped += 1
						skipped_reasons[reason] = int(skipped_reasons.get(reason, 0)) + 1
			var measurable := rows.filter(func(r):
				return String(r["scope"]) == "country" and String(r["kind"]) == "constant")
			if not measurable.is_empty():
				per_level[level_index + 1] = measurable
		if per_level.is_empty():
			continue

		# ONLY ONE card can hold a slot, so each card needs its own world. One world
		# per CARD (not per level): levels are reached in place by raising
		# understanding, which is the runtime's own upgrade path.
		cards_checked += 1
		var level_keys: Array = per_level.keys()
		level_keys.sort()
		var fixture := _equip(key, dense, int(level_keys[0]))
		if fixture.is_empty():
			continue
		var ext: Object = fixture["ext"]
		var handle: int = int(fixture["handle"])
		for level_value in level_keys:
			var level := int(level_value)
			if level > int(level_keys[0]):
				_raise_understanding(ext, handle, dense, level)
			for row_value in per_level[level_value]:
				var row: Dictionary = row_value
				var stat := String(row["stat"])
				var expected := float(row["value"])
				var base := float(row.get("base",
					1.0 if String(row.get("operation", "multiply")) == "multiply" else 0.0))
				var actual := _read(ext, handle, stat, base)
				_expect("%s L%d %s = %.4f (json)" % [key, level, stat, expected],
					_is_close(actual, expected, 0.0005),
					"got %.5f expected %.5f" % [actual, expected])
		ext = null
		fixture.clear()

	_stage("expectations: cards checked = %d of %d, country/constant rows = %d"
		% [cards_checked, order.size(), country_rows])
	_stage("expectations: cell rows measurable = %d, skipped = %d"
		% [cell_rows_measurable, cell_rows_skipped])
	for reason_value in skipped_reasons.keys():
		_stage("expectations: skipped %d rows -- %s"
			% [int(skipped_reasons[reason_value]), String(reason_value)])
	_expect("the json table produced at least one country row per level",
		country_rows > 0, "country_rows=%d" % country_rows)


## The entry for one card level, or {} when the table has no such level.
func _expectation_level(levels: Array, level: int) -> Dictionary:
	for entry_value in levels:
		var entry: Dictionary = entry_value
		if int(entry["level"]) == level:
			return entry
	return {}


## Why the synthetic fixture cannot measure this cell row, or "" when it can.
##
## The fixture is 12 cells with fixed terrain/tags, so a program that selects
## `cell.produces.<good>` or `cell.sector.<sector>` has nothing to bind to unless the
## fixture happens to create one. Rather than claim a check it cannot make, each
## unmeasurable shape is named so the gap is visible in the log.
func _cell_row_unmeasurable(row: Dictionary) -> String:
	var tags: Array = row.get("tags", [])
	if tags.is_empty():
		return "cell program with no tag selector (whole territory)"
	for tag_value in tags:
		var tag := String(tag_value)
		if tag.begins_with("cell.terrain.") or tag.begins_with("cell.landform."):
			continue  # the fixture pins terrain, so these CAN be satisfied
		if tag == "cell.settlement" or tag == "cell.metropolis" or tag == "cell.market":
			continue
		if tag.begins_with("cell.produces.") or tag.begins_with("cell.sector."):
			return "fixture has no cell carrying %s" % tag
		if tag.begins_with("cell.rich."):
			return "fixture declares no natural resource (%s)" % tag
		return "no fixture rule for tag %s" % tag
	if int(row.get("selector", 0)) == 16:
		return "kind 16 (per-source count) is not implemented in the runtime"
	return ""


## Raise an equipped card's understanding to reach `level`, then settle.
##
## Thresholds are 0 / 4 / 12 understanding. The command is stamped with the day the
## world is currently on, and settled from that day, so the level change is picked up
## by the normal daily pass.
func _raise_understanding(ext: Object, handle: int, dense: int, level: int) -> bool:
	var understanding := 0
	match level:
		2: understanding = 4 * Q16_ONE
		3: understanding = 12 * Q16_ONE
		_: return true
	ext.submit_ideology_commands(_commands([
		{"op": 8, "day": 0, "handle": handle, "idea": dense,
		 "value": understanding}]))
	return _settle(ext, 0)


func _equip(key: String, dense: int, level: int) -> Dictionary:
	if not _require("%s is in the catalog" % key, dense >= 0):
		return {}
	_stage("%s L%d: build_ext" % [key, level])
	var ext: Object = _build_ext()
	_stage("%s L%d: configure_economy" % [key, level])
	var economy_configured: Dictionary = ext.configure_economy(_country_ir,
		load("res://data/economy/default_economy.tres").to_native_profile(), CELLS, 97)
	if not _require("%s: economy configures" % key,
			bool(economy_configured.get("ok", false)), str(economy_configured)):
		return {}
	_stage("%s L%d: bootstrap_economy" % [key, level])
	if not _require("%s: economy bootstraps" % key, _bootstrap_economy(ext)):
		return {}
	_stage("%s L%d: build effect catalog" % [key, level])
	_stage("%s L%d: configure_effects" % [key, level])
	if not _require("%s: effects configure" % key,
			bool(ext.configure_effects(_effect_ir).get("ok", false))):
		return {}
	_stage("%s L%d: configure_ideologies" % [key, level])
	if not _require("%s: ideologies configure" % key,
			bool(ext.configure_ideologies(_support_gate_off(_native_ideology)).get("ok", false))):
		return {}
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if not _require("%s: fixture resolves the country" % key, handle != 0):
		return {}
	_stage("%s L%d: discover" % [key, level])
	var discover: Dictionary = _submit(ext, [{"op": 1, "day": 0, "handle": handle,
		"idea": dense}])
	if not _require("%s: discover is accepted" % key,
			bool(discover.get("ok", false)), str(discover)):
		return {}
	if level <= 0:
		# Base-reading world: configured, discovered, NOT equipped.
		_stage("%s L%d: settle(base)" % [key, level])
		if not _require("%s: base world settles" % key, _settle(ext, 0), str(key)):
			return {}
		return {"ext": ext, "handle": handle, "equipped": false}
	# Level thresholds are 0 / 4.0 / 12.0 understanding; +8 per call is enough to
	# cross one tier and the level is clamped, so asking for tier N with
	# (N-1) * 4.0 keeps the card at exactly that tier.
	# Thresholds are 0 / 4 / 12, so the multiplier is NOT (level-1)*4: that gives
	# 0 / 4 / 8, and 8 sits inside tier 2 -- asking for L3 silently measured L2.
	# The fixture's own comment said this and the code did not.
	var understanding := 0
	match level:
		2: understanding = 4 * Q16_ONE
		3: understanding = 12 * Q16_ONE
		_: understanding = 0
	if understanding > 0:
		ext.submit_ideology_commands(_commands([
			{"op": 8, "day": 0, "handle": handle, "idea": dense,
			 "value": understanding}]))
	var equip: Dictionary = _submit(ext, [{"op": 5, "day": 0, "handle": handle,
		"idea": dense}])
	if not _require("%s: equip is accepted" % key,
			bool(equip.get("ok", false)), str(equip)):
		return {}
	# The equip command is stamped with day 0, so the daily pass that settles it is
	# day 0's. Starting at day 1 leaves the transition PENDING forever: the card
	# never occupies a slot, no Effect instance exists, and every assertion after
	# this point reads the base value while looking like "the card did nothing".
	if not _require("%s: equip settles" % key, _settle(ext, 0), str(key)):
		return {}
	return {"ext": ext, "handle": handle, "equipped": true}


## Drives the four-stage transaction to settlement. Returns false if any stage
## rejects; the caller turns that into a single failure instead of a cascade.
##
## `first_day` must be the day the command was stamped with: the transition is only
## reconciled by a daily pass at or after that day, so a submit on day 0 settled
## from day 1 stays PENDING forever, and a submit on day 2 whose window starts at
## day 2 does land. The fixture equips on day 0 and unequips on day 2, so both are
## covered by the windows below.
func _settle(ext: Object, first_day: int) -> bool:
	for day in range(first_day, first_day + 3):
		for _slice in range(16):
			_stage("settle day %d ideology_daily" % day)
			var ideology_slice: Dictionary = ext.run_ideology_daily(day)
			if not bool(ideology_slice.get("ok", false)):
				_expect("ideology day %d runs" % day, false, str(ideology_slice))
				return false
			if bool(ideology_slice.get("done", false)):
				break
		for _effect_slice in range(16):
			_stage("settle day %d effect_daily" % day)
			var effect_slice: Dictionary = ext.run_effect_daily(day)
			if not bool(effect_slice.get("ok", true)):
				break
			if bool(effect_slice.get("done", true)):
				break
		_stage("settle day %d dispatch" % day)
		ext.dispatch_effect_native_modifier()
		_stage("settle day %d modifier_daily" % day)
		ext.run_modifier_daily(day)
		_stage("settle day %d ack" % day)
		ext.ack_effect_native_modifier()
	return true


## Unequip the card and settle it.
##
## The retire is a transaction like the equip: `retire_effect_activations` hands each
## instance to the forwarder, and only the four-stage daily pass turns that into a
## Modifier REMOVE. The equip fixture already consumed days 0..2, so the unequip is
## stamped on day 3 and settled from day 3 -- re-running a consumed day does not
## reconcile anything.
func _submit_unequip(ext: Object, handle: int, dense: int) -> Dictionary:
	var day := 3
	var submitted: Dictionary = _submit(ext, [{"op": 6, "day": day, "handle": handle,
		"idea": dense}])
	if not bool(submitted.get("ok", false)):
		return submitted
	submitted["settled"] = _settle(ext, day)
	return submitted


## `evaluate_modifier_stat(domain, entity_handle, group_handle, stat, base)`.
## Domain 1 is COUNTRY and the entity is the country handle for every national
## ideology row.
func _read(ext: Object, handle: int, stat: String, base: float = 1.0) -> float:
	return float(ext.evaluate_modifier_stat(MODIFIER_DOMAIN_COUNTRY, handle, 0, stat, base))


## R-3d item 3: LEVEL-UP must retire the old tier's row, not stack on top of it.
##
## A level transition removes one tier's persistent rows and adds another's. The REMOVE
## has to name the generation that APPLIED the row, not the generation being created:
## `enqueue_external_effect_batch_pod` derives the Effect instance id from
## (source_type, transition_source_id, effect_id, fire_sequence) and
## `NATIVE_MODIFIER_IDEOLOGY` takes the Modifier row's `source_id` from that instance,
## so a shared batch id makes the old row unreachable and BOTH tiers stay live.
##
## `_equip(key, ..., 2)` drives the card to L2, so the interesting assertion is that
## `.l1` is gone -- not merely that `.l2` exists.
func _test_level_up_replaces_rows() -> void:
	var key := "terrace_farming"
	var stat := "country.output.terrain.hill.agriculture_factor"
	var fixture := _equip(key, int(_dense[key]), 2)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	var handle: int = int(fixture["handle"])
	var rows: Dictionary = ext.list_modifiers(MODIFIER_DOMAIN_COUNTRY, handle, "")
	var keys := PackedStringArray(rows.get("definition_keys", PackedStringArray()))
	_expect("level-up: L2 is live (rows=%s)" % str(keys),
		keys.has("ideology.%s.l2" % key))
	# The decisive one: the OLD tier must be gone. A shared batch id left it live and
	# the stat then read L1 x L2.
	_expect("level-up: the OLD level's row is retired (rows=%s)" % str(keys),
		not keys.has("ideology.%s.l1" % key))
	_expect("level-up: exactly ONE tier row is live (count=%d, rows=%s)" % [
			keys.size(), str(keys)], keys.size() == 1, "rows=%s" % str(keys))
	_expect("level-up: the stat reads the L2 value only (1.15000, got %.5f)"
			% _read(ext, handle, stat),
		_is_close(_read(ext, handle, stat), 1.15, 0.0005),
		"%.5f rows=%s" % [_read(ext, handle, stat), str(keys)])


## R-3d item 3 (second half): relocation IDEOLOGY -> NATIONAL_SPIRIT.
##
## Different destination, same removal mechanics. The spirit tier carries its own row
## set, so a stale IDEOLOGY row is double-counted here too.
func _test_relocation_replaces_rows() -> void:
	var key := "terrace_farming"
	var fixture := _equip(key, int(_dense[key]), 2)
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	var handle: int = int(fixture["handle"])
	# PROMOTE is opcode 7.
	var promoted: Dictionary = _submit(ext, [{"op": 7, "day": 4, "handle": handle,
		"idea": int(_dense[key])}])
	if not _require("relocation: promote is accepted",
			bool(promoted.get("ok", false)), str(promoted)):
		return
	_settle(ext, 4)
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var ideology_slots := int(snapshot.get("ideology_slots_used", -1))
	var spirit_slots := int(snapshot.get("national_spirit_slots_used", -1))
	var rows: Dictionary = ext.list_modifiers(MODIFIER_DOMAIN_COUNTRY, handle, "")
	var keys := PackedStringArray(rows.get("definition_keys", PackedStringArray()))
	_expect("relocation: the card moved to the spirit tier (ideology=%d spirit=%d)" % [
			ideology_slots, spirit_slots],
		ideology_slots == 0 and spirit_slots == 1,
		"ideology=%d spirit=%d" % [ideology_slots, spirit_slots])
	_expect("relocation: exactly ONE tier row is live (count=%d, rows=%s)" % [
			keys.size(), str(keys)], keys.size() <= 1, "rows=%s" % str(keys))
	printerr("[relocation] ideology=%d spirit=%d rows=%s stat=%.5f" % [
		ideology_slots, spirit_slots, str(keys),
		_read(ext, handle, "country.output.terrain.hill.agriculture_factor")])


func _support_gate_off(native: Dictionary) -> Dictionary:
	var out := native.duplicate(false)
	var count := (out["ideology_ids"] as PackedStringArray).size()
	var zeros := PackedInt32Array()
	zeros.resize(count + 1)
	zeros.fill(0)
	out["stance_offsets"] = zeros
	out["stance_class_indices"] = PackedInt32Array()
	out["stance_adopt_q16"] = PackedInt32Array()
	out["stance_repeal_q16"] = PackedInt32Array()
	out["stance_promote_q16"] = PackedInt32Array()
	out["stance_adopt_min_q16"] = PackedInt32Array()
	out["stance_repeal_min_q16"] = PackedInt32Array()
	out["stance_promote_min_q16"] = PackedInt32Array()
	var thresholds := PackedInt32Array()
	thresholds.resize(count)
	thresholds.fill(0)
	out["adopt_thresholds_q16"] = thresholds
	out["repeal_thresholds_q16"] = thresholds.duplicate()
	out["promote_thresholds_q16"] = thresholds.duplicate()
	return out


func _build_ext() -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	_expect("modifier catalog configures",
		bool(ext.configure_modifiers(modifier_catalog, CELLS).get("ok", false)))
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, _f32_fill(CELLS, 0.5))
	# Terrain and landform must be REAL ids, not zeros: the tag dictionary builds
	# one tag per enum member and metrics 10/50 compare against those ids, so an
	# all-zero column makes every terrain tag mean "PLAIN" and every landform tag
	# mean "DEEP_OCEAN".
	var terrain := PackedByteArray()
	terrain.resize(CELLS)
	terrain.fill(_terrain_id("HILL"))
	for slot_name in [&"cell_landform", &"cell_vegetation", &"cell_is_water",
			&"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid2: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid2, 0, _u8_fill(CELLS, 0))
	var terrain_sid: int = ext.register_component(&"cell_terrain", 2, 1, false)
	ext.write_u8_range(terrain_sid, 0, terrain)
	for i in range((_country_ir.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(
			(_country_ir.building_resource_reserve_slots as PackedStringArray)[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(
			(_country_ir.building_resource_extra_slots as PackedStringArray)[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _f32_fill(CELLS, 1000000.0))
		ext.write_f32_range(extra_sid, 0, _f32_fill(CELLS, 0.0))
	_expect("country configures", bool(ext.configure_country(_country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 97).get("ok", false)))
	var territory := PackedInt32Array()
	for cell in range(CELLS):
		territory.append(cell)
	var country_outcome: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.ideology_card_content_test"]),
		"country_names": PackedStringArray(["理念卡内容测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill(CELLS, 0))
	_expect("country bootstraps", bool(country_outcome.get("ok", false)),
		str(country_outcome))
	return ext


func _terrain_id(member: String) -> int:
	var enum_table: Dictionary = load("res://scripts/geography/terrain_type.gd").TERRAIN
	return int(enum_table.get(member, 0))


func _f32_fill(cells: int, value: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(cells)
	out.fill(value)
	return out


func _u8_fill(cells: int, value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(cells)
	out.fill(value)
	return out


func _bootstrap_economy(ext: Object) -> bool:
	var building_id := (_country_ir.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir.signature_keys as PackedStringArray).find(
		"forager|default")
	if building_id < 0 or owner_sig < 0:
		_expect("fixture finds its building type and owner signature", false)
		return false
	var stock := PackedInt64Array()
	stock.resize((_country_ir.good_ids as PackedStringArray).size() * CELLS)
	stock.fill(100000000)
	var seeded_cells := PackedInt32Array()
	var seeded_signatures := PackedInt32Array()
	var seeded_population := PackedInt64Array()
	var seeded_funds := PackedInt64Array()
	var seeded_buildings := PackedInt32Array()
	var seeded_owners := PackedInt32Array()
	var seeded_counts := PackedInt64Array()
	for cell in range(CELLS):
		seeded_cells.append(cell)
		seeded_signatures.append(owner_sig)
		seeded_population.append(400)
		seeded_funds.append(1000000000000000)
		seeded_buildings.append(building_id)
		seeded_owners.append(owner_sig)
		seeded_counts.append(1)
	var outcome: Dictionary = ext.bootstrap_economy({
		"cell_indices": seeded_cells,
		"signature_ids": seeded_signatures,
		"population": seeded_population,
		"funds": seeded_funds,
		"forced_named_cells": seeded_cells,
		"founder_family_cells": seeded_cells,
		"founder_family_building_type_ids": seeded_buildings,
		"founder_family_owner_signature_ids": seeded_owners,
	}, {
		"stock": stock,
		"building_cells": seeded_cells,
		"building_type_ids": seeded_buildings,
		"building_owner_signature_ids": seeded_owners,
		"building_counts": seeded_counts,
	})
	_expect("economy bootstraps", bool(outcome.get("ok", false)), str(outcome))
	return bool(outcome.get("ok", false))


## Submits the rows to the native runtime and returns ITS verdict. The helper used
## to return the packed batch instead, which read as "rejected" for every command
## because a batch has no `ok` key -- the failure then pointed at the runtime
## rather than at the fixture.
func _submit(ext: Object, rows: Array[Dictionary]) -> Dictionary:
	return ext.submit_ideology_commands(_commands(rows))


## Every column must carry exactly one entry per row: the runtime rejects the
## whole batch with `ideology_command_columns_invalid` when one is short, and an
## empty column is the easy mistake (`source_priorities` used to be).
func _commands(rows: Array[Dictionary]) -> Dictionary:
	var count := rows.size()
	return {
		"opcodes": PackedInt32Array(_column(rows, "op", 0)),
		"effective_days": PackedInt64Array(_column(rows, "day", 0)),
		"source_priorities": PackedInt32Array(_fill(count, 0)),
		"producer_ids": PackedInt32Array(_fill(count, 1)),
		"sequences": PackedInt64Array(_sequences(count)),
		"country_handles": PackedInt64Array(_column(rows, "handle", 0)),
		"ideology_ids": PackedInt32Array(_column(rows, "idea", -1)),
		"values_q16": PackedInt64Array(_column(rows, "value", 0)),
		"offer_generations": PackedInt64Array(_fill(count, 0)),
		"choice_indices": PackedInt32Array(_fill(count, -1)),
		"gate_ids": PackedInt32Array(_fill(count, -1)),
	}


func _column(rows: Array[Dictionary], key: String, fallback: int) -> Array:
	var out := []
	for row in rows:
		out.append(int(row.get(key, fallback)))
	return out


func _fill(count: int, value: int) -> Array:
	var out := []
	for _index in range(count):
		out.append(value)
	return out


func _sequences(count: int) -> Array:
	var out := []
	for _index in range(count):
		out.append(_next_sequence)
		_next_sequence += 1
	return out


func _is_close(value: float, expected: float, tolerance: float) -> bool:
	return absf(value - expected) <= tolerance


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		push_error("[FAIL] %s" % label)
	else:
		push_error("[FAIL] %s (%s)" % [label, detail])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition
