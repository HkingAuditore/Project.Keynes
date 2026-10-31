extends SceneTree
## Evidence for the just-landed I01 fix: a copier card's level-2 bonus must reach
## the DERIVED cell backend, not only the legacy instance path.
##
## ===========================================================================
## WHAT WAS FIXED
## ===========================================================================
## I01 is this project's rule "one program, one backend". A card is expressed
## either by the derived cell layer or by the legacy instance path, and switching
## backend must not change the numbers.
##
## A copier card (`copy_left_programs`) at level >= 2 scales the programs it
## COPIES by 1.2x. The factor existed only in the instance branch:
##
##   ideology_runtime.cpp:2640-2645   (LEGACY / instance)
##       const int32_t copy_scale_q16 =
##           definition.copy_left_programs != 0 && state.level >= 2
##               ? kCopierLevelTwoScaleQ16 : static_cast<int32_t>(Q16_ONE);
##
## and the literal `78643` was spelled inline. The fix adds the same term to the
## derived branch and extracts the literal into ONE shared constant:
##
##   ideology_runtime.cpp:62          constexpr int32_t kCopierLevelTwoScaleQ16 = 78643;
##   ideology_runtime.cpp:2476-2490   (DERIVED)
##       double derived_copy_scale = 1.0;
##       if (definition.copy_left_programs != 0 && state.level >= 2)
##           derived_copy_scale = kCopierLevelTwoScaleQ16 / Q16_ONE;
##       ...
##       single.magnitude_scale = target_scale * derived_school_scale
##                                * derived_copy_scale;
##
## `magnitude_scale` is what the materialiser folds into each term's `add`
## (`ideology_runtime.cpp:2598-2606`), so the derived path now scales the copied
## program's magnitude exactly the way the instance path scales
## `activation_scale_q16`.
##
## ===========================================================================
## WHAT THIS FIXTURE PROVES (and how)
## ===========================================================================
## The fixture does NOT read code and does NOT re-implement the runtime. It builds
## a world, equips real cards, promotes them through the real command path, and
## reads the number a shipping consumer would read:
##
##   get_effective_stat_value(stat, cell, 0, 1.0)["derived_add"]
##
## which comes from `ModifierRuntime::effective_value` merging the installed
## `DerivedCellFront` row for that (stat, cell) -- the derived backend's output.
##
## A DERIVED COPIER CARD cannot be made by pointing a card at the shipped copier:
## `idea.algorithmic_governance` carries Modifier-domain rows, and
## `decide_cell_program_backend` (gdext/src/cell_program_eligibility.h:109-186)
## keeps every non-cell program on the instance path (its first test is
## `target_domain != 2`). So the fixture synthesises three cards in memory
## (no file is touched) whose level rows are ROUTING MARKERS to the shipped,
## kind-12 `public_hygiene_l1` program (`target_domain = 2`,
## `target_selector_kind = 12` = OWN_TERRITORY, permanent, constant magnitude):
##
##   test.dcs.source    copyable = true,  copy_left_programs = false, 1 level  (slot 0)
##   test.dcs.copier    copyable = false, copy_left_programs = true,  3 levels (slot 1)
##   test.dcs.control   copyable = false, copy_left_programs = false, 3 levels
##
## The source is a ONE-level donor so the level list the copier copies can never
## change under the measurement. The two cards under test carry three levels so that
## level index 2 -- the `state.level >= 2` gate -- exists.
##
## The two cards under test differ by EXACTLY ONE catalog byte
## (`ideology_copy_left_programs`) and carry the SAME three levels pointing at the
## SAME program, so any numeric difference between them is that byte.
##
## ---------------------------------------------------------------------------
## WHY THE COPIER'S ADD IS MEASURED BY SUBTRACTION
## ---------------------------------------------------------------------------
## A copier with no left slot contributes NOTHING (`copy_source_state` returns
## false when `slot_index == 0`, ideology_runtime.cpp:1799), so the source card
## must be ACTIVE in slot 0 for the copier to copy anything -- and an active
## source contributes its own program too. The front folds every contribution into
## one `DerivedCellContribution` per (stat, cell) (`slot.sum_add += add`,
## derived_cell_materializer.cpp:162), so the copier's own add is:
##
##   A(level) = front_add(with copier at `level`) - front_add(source alone)
##
## `S` (source alone) is measured first and every reading below is difference
## against it. Both operands are exact binary values (see the arithmetic note), so
## the subtraction is exact and loses nothing.
##
## ---------------------------------------------------------------------------
## THE NUMBERS, DERIVED FROM CONTENT (never from a "> 0")
## ---------------------------------------------------------------------------
## `public_hygiene_l1` is `CONST 3277 -> EMIT` (default_ideology_effects.tres:
## 5336-5357) against the generated `economy.city.birth_factor` definition, which
## carries one ADD term of value 1.0 (modifier_catalog.gd:513-537 -- "ADD 1.0, not
## MULTIPLY 1.0"). The derived term is therefore `term.value * stacks *
## magnitude/Q16` = 1.0 * 1 * 3277/65536, so:
##
##   S        = 3277 / 65536                         = 0.0500030517578125
##   A1       = S                                             (level index 0)
##   A2       = S * 78643 / 65536                             (level index 2)
##            = 3277 * 78643 / 2^32  = 257713111 / 2^32
##
## Every one of those is exactly representable as a double (3277, 78643 and
## 257713111 are far below 2^53 and the divisors are powers of two), and IEEE
## multiplication of two exact operands whose product is representable is exact.
## So the fixture asserts the INTEGER identity
## `round(A2 * 2^32) == 3277 * 78643` as well as the float form.
##
## ---------------------------------------------------------------------------
## 1.2 IS NOT 78643/65536, AND THAT IS ASSERTED, NOT ROUNDED AWAY
## ---------------------------------------------------------------------------
## `kCopierLevelTwoScaleQ16 = 78643` is 1.1999969482421875, i.e. 3.0517578125e-6
## BELOW 1.2. So `|A2 - A1 * 1.2|` is not zero and CANNOT be zero for any nonzero
## A1: it is exactly `A1 * (1.2 - 78643/65536)` = 1.52597e-7 here. Writing
## `assert |A2 - A1*1.2| == 0` would be asserting the constant is 1.2, which it is
## not, and loosening the epsilon until it passes would hide a real regression.
##
## The fixture therefore asserts the STRONG form -- `A2 == A1 * (78643/65536)`
## exactly, and the integer identity above -- and then asserts that the residual
## against the stated "1.2" is EXACTLY the constant's own rounding, so a reader can
## see that the only thing missing from "1.2" is the Q16 quantisation:
##
##   |A2 - A1*1.2| == A1 * (1.2 - 78643/65536)   (to 1e-15)
##
## ---------------------------------------------------------------------------
## PHASES
## ---------------------------------------------------------------------------
##   0  the three test cards reach the DERIVED backend (engine-classified), and
##      the runtime's rollout covers the cell selector kinds {12,14,15,16};
##   1  source alone: S = 3277/Q16 on every probed cell, front = 2 stats x 25
##      cells, one generation;
##   2  copier at level index 0 (the baseline, A1): the front DOUBLES (the copier
##      reproduces the source verbatim at scale 1.0), so A1 == S exactly; the
##      level is asserted to be 0 and the transition to be settled BEFORE the read
##      (plan 10.1: a pending card contributes the OLD level);
##   3  copier at level index 1: the factor is NOT applied yet (`state.level >= 2`),
##      so the candidate is content-identical and the front is NOT reinstalled
##      (plan I13) while the collector DID run again -- the discriminating control
##      that separates "levelled up" from "copier at level >= 2";
##   4  copier at level index 2: A2 == A1 * 78643/65536 exactly, the front IS
##      reinstalled (content changed), and the "1.2" residual is the constant's own
##      rounding;
##   5  the NON-COPIER control card at the SAME level index 2 does NOT scale: its
##      add stays bit-identical to its own level-0 add, so the factor is tied to
##      `copy_left_programs`, not to levelling up;
##   6  the shipped catalog: exactly one copier, ZERO cards that are both a copier
##      and a cell-targeting (derived) effect, plus named detail on the one copier
##      that exists. This is the assertion that goes RED the day content adds a
##      derived copier. The fixture's OWN copier card is run through the same
##      predicate to prove the predicate is not vacuous.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_derived_copier_scale_test.gd

const WIDTH := 5
const HEIGHT := 5
const CELLS: int = WIDTH * HEIGHT
## Cells asserted throughout. Cell 0 is skipped for the reason
## `ideology_mechanism_copier_school_test.gd` gives (it has its own guard history
## in `effective_value`); the selector is OWN_TERRITORY over a 5x5 world, so every
## owned cell carries the same value and four probes are enough to show it.
const PROBE_CELLS := [3, 7, 12, 24]

const Q16_ONE := 65536
## `kCopierLevelTwoScaleQ16` (ideology_runtime.cpp:62). Spelled as the shared
## constant's VALUE on purpose: if the constant moves, this fixture's exact
## expectations must be re-derived from it, not silently re-baselined.
const COPIER_SCALE_Q16 := 78643
## The number the change is described by ("1.2x"), kept separately so the fixture
## can measure the difference between the description and the constant.
const STATED_COPIER_SCALE := 1.2

## The shipped program every test card routes to. Kind 12 (OWN_TERRITORY), cell
## domain, permanent, constant magnitude -- the shape `decide_cell_program_backend`
## admits to the derived layer.
const PROGRAM_KEY := "public_hygiene_l1"
const PROGRAM_FULL_KEY := "ideology.effect.public_hygiene_l1"
## The stat its first command writes, and that command's authored magnitude
## (default_ideology_effects.tres:5346-5357).
const PROGRAM_STAT := "economy.city.birth_factor"
const PROGRAM_MAGNITUDE_Q16 := 3277

## The one shipped copier (`default_ideology_catalog.tres:14124`) and the Modifier
## definition all three of its level rows name.
const SHIPPED_COPIER := "idea.algorithmic_governance"
const SHIPPED_COPIER_DEFINITION := "ideology.algorithmic_governance"
## The shipped card the copier mechanism was first measured against; used here only
## to report that a copy SOURCE is copyable in shipped content.
const SHIPPED_COPY_SOURCE := "idea.public_hygiene"

## Fixture cards. The prefix is how the shipped-catalog audit tells the fixture's
## in-memory additions from authored content.
const FIXTURE_PREFIX := "test.dcs."
const SOURCE_CARD := "test.dcs.source"
const COPIER_CARD := "test.dcs.copier"
const CONTROL_CARD := "test.dcs.control"
## Three levels: index 0 = the baseline, index 1 = levelled up but BELOW the
## `state.level >= 2` gate, index 2 = the copier factor. Thresholds are dense and
## the daily accrual is 0, so understanding only moves when the fixture says so and
## the level never drifts on its own.
const LEVEL_THRESHOLDS_Q16 := [0, 65536, 131072]
const LEVEL_DAILY_Q16 := 0

## Opcodes (`ideology_runtime.h:73-86`) and locations (`:87`).
const OP_DISCOVER := 1
const OP_GRANT := 2
const OP_EQUIP := 5
const OP_ADD_UNDERSTANDING := 8
const LOCATION_INACTIVE := 0
const LOCATION_IDEOLOGY := 1

## `TargetSelectorKind.SETTLEMENT_CELL`-side values (`ideology_effect_definition.gd`
## mirrors `cell_program_eligibility.h:95-105`).
const TARGET_DOMAIN_CELL := 2
const LIFECYCLE_PERMANENT := 0
const DERIVED_SELECTOR_KINDS := [12, 14, 15, 16]

const MAX_DAY_SLICES := 64
const MAX_SETTLE_DAYS := 12

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const IdeologyDefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const IdeologyLevelDefinitionScript = preload(
	"res://scripts/ideology/ideology_level_definition.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

var _checks := 0
var _failures := 0
var _seq := 0
var _day := 0
## `cells * cells` as a double: the denominator of the exact Q16 expectation.
var _q16_squared := float(Q16_ONE) * float(Q16_ONE)
## `probe_cell_program_backend` is a binding on the world object, so the engine's
## own backend decision can only be asked once a world exists. The first world
## built is kept here for that one question.
var _probe_host: Object = null


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("  ok   %s" % label)
		return
	_failures += 1
	printerr("FAIL %s  %s" % [label, detail])


func _run() -> void:
	# ---------------------------------------------------------------------
	print("=== PHASE 0: catalogs, the fixture cards, and the derived backend ===")
	# ---------------------------------------------------------------------
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	# `EffectDomainCatalog.build()` short-circuits to a PRECOMPILED catalog when one
	# is cached, so the ideology effect programs are passed explicitly to bypass it
	# (the same reason ideology_mechanism_equip_level_test.gd:1207-1212 does).
	var effect_catalog: Resource = IdeologyEffectCatalogScript.load_default()
	var domain: Resource = EffectDomainCatalogScript.build(null, effect_catalog)
	# `cell.settlement` (the kind-12 tag `public_hygiene_l1` filters on) is
	# re-declared as a population threshold, because a bootstrapped economy has
	# population but no buildings -- see
	# ideology_mechanism_copier_school_test.gd:_install_satisfiable_tag.
	_install_satisfiable_tag(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	_expect("the modifier catalog compiles", bool(mod_ir.get("ok", false)),
		str(mod_ir.get("reason", "")))
	mod_ir.erase("ok")

	var declared_programs: Dictionary = effect_catalog.program_key_set()
	var programs: Dictionary = _program_index(effect_catalog)
	_expect("the shipped effect catalog declares the program the fixture routes to",
		declared_programs.has(PROGRAM_FULL_KEY)
			and programs.has(PROGRAM_FULL_KEY),
		"%s absent from %d declared programs"
			% [PROGRAM_FULL_KEY, declared_programs.size()])
	if not programs.has(PROGRAM_FULL_KEY):
		_finish(2)
		return

	var catalog: Resource = IdeologyCatalogScript.load_default()
	# The compiled catalog is derived from this resource, so the three test cards are
	# appended HERE -- in memory only. No file is written and no C++ is touched.
	_add_fixture_cards(catalog)
	# Pin the program set the compiler reads to the one this fixture measured, so
	# the compiled catalog and the EffectCatalog cannot disagree about it.
	catalog.effect_programs = effect_catalog
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	_expect("the ideology catalog compiles with the three fixture cards",
		bool(native.get("ok", false)),
		str(native.get("reason", native.get("fatal_reason", ""))))
	native.erase("ok")
	_relax_catalog(native)
	var ids: PackedStringArray = native.get("ideology_ids", PackedStringArray())
	var source_dense := ids.find(SOURCE_CARD)
	var copier_dense := ids.find(COPIER_CARD)
	var control_dense := ids.find(CONTROL_CARD)
	_expect("the source card is in the compiled catalog", source_dense >= 0,
		str(source_dense))
	_expect("the copier card is in the compiled catalog", copier_dense >= 0,
		str(copier_dense))
	_expect("the control card is in the compiled catalog", control_dense >= 0,
		str(control_dense))
	if source_dense < 0 or copier_dense < 0 or control_dense < 0:
		_finish(2)
		return
	var copy_flags: PackedByteArray = native.get(
		"ideology_copy_left_programs", PackedByteArray())
	var copyable: PackedByteArray = native.get("ideology_copyable", PackedByteArray())
	_expect("the copier card compiles with copy_left_programs = 1",
		int(copy_flags[copier_dense]) == 1, str(copy_flags[copier_dense]))
	_expect("the source and control cards compile with copy_left_programs = 0",
		int(copy_flags[source_dense]) == 0 and int(copy_flags[control_dense]) == 0,
		"source=%d control=%d" % [int(copy_flags[source_dense]),
			int(copy_flags[control_dense])])
	_expect("the source card is copyable and the copier/control cards are not",
		int(copyable[source_dense]) == 1 and int(copyable[copier_dense]) == 0
			and int(copyable[control_dense]) == 0,
		"source=%d copier=%d control=%d" % [int(copyable[source_dense]),
			int(copyable[copier_dense]), int(copyable[control_dense])])
	var levels: PackedInt32Array = native.get("level_offsets", PackedInt32Array())
	var level_counts := PackedInt32Array()
	for dense in [source_dense, copier_dense, control_dense]:
		level_counts.append(int(levels[dense + 1]) - int(levels[dense]))
	_expect("the source has 1 level and the copier/control have 3 each (so level "
		+ "index 2 exists)", level_counts == PackedInt32Array([1, 3, 3]),
		str(level_counts))

	# ---- world 1: source -> + copier ------------------------------------
	var ext: Object = _build_world(country_ir, profile, effect_ir, mod_ir, native,
		"dcs")
	var handle := _handle(ext)

	# ---- the program really is a DERIVED program ------------------------
	# The engine's own classifier, not a GDScript restatement of it: the probe is a
	# binding on the world, so it is asked once the world exists.
	var program: Resource = programs[PROGRAM_FULL_KEY]
	var probe: Dictionary = _probe_program_backend(program, mod_ir)
	print("[0] program %s  domain=%d kind=%d lifecycle=%d -> backend=%s reason=%s"
		% [PROGRAM_FULL_KEY, int(program.target_domain),
			int(program.target_selector_kind), int(program.lifecycle),
			String(probe.get("backend", "?")), String(probe.get("reason", "?"))])
	_expect("the program the fixture routes to is classified DerivedCell by "
		+ "`decide_cell_program_backend`",
		String(probe.get("backend", "")) == "DerivedCell", str(probe))
	_expect("its selector kind is 12 (OWN_TERRITORY), a cell selector",
		int(program.target_selector_kind) == 12,
		str(program.target_selector_kind))
	var rollout: Dictionary = ext.get_cell_program_rollout()
	var kinds: PackedInt32Array = rollout.get("enabled_kinds", PackedInt32Array())
	var kinds_ok := kinds.size() == 4
	for wanted in DERIVED_SELECTOR_KINDS:
		kinds_ok = kinds_ok and kinds.has(int(wanted))
	print("[0] derived-layer rollout enabled kinds = %s" % str(kinds))
	_expect("the runtime's derived rollout covers exactly the cell selector kinds "
		+ "12/14/15/16 (so a kind-12 copier has a derived backend to reach)",
		kinds_ok, str(kinds))
	_expect("the shipped program is owned by the Effect reconciler, not the legacy "
		+ "Modifier batch", bool(ext.effect_program_is_managed(PROGRAM_FULL_KEY)),
		PROGRAM_FULL_KEY)

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 1: the source alone (S) ===")
	# ---------------------------------------------------------------------
	_equip(ext, ids, SOURCE_CARD)
	_expect("1: the source occupies slot 0 (nothing to its left)",
		_slot_of(ext, handle, source_dense) == 0, _slots(ext, handle))
	_expect("1: the source is ACTIVE (location 1)", _location_of(ext, handle,
		source_dense) == LOCATION_IDEOLOGY, _locations(ext, handle))
	_expect("1: the source is at level index 0", _level_of(ext, handle,
		source_dense) == 0, str(_level_of(ext, handle, source_dense)))
	var m_source := _measure(ext, "1/source alone")
	_expect_front(ext, "1", m_source, 50, 50, 2)
	var expect_s := float(PROGRAM_MAGNITUDE_Q16) / float(Q16_ONE)
	_expect_cells(ext, "1", m_source, expect_s)
	var adds_s: PackedFloat64Array = m_source["adds"]
	_expect("1: the source alone contributes exactly 3277/Q16 (0.0500030517578125)",
		_is_close(float(adds_s[0]), expect_s, 1e-15),
		"actual=%.17f expected=%.17f" % [float(adds_s[0]), expect_s])
	_expect("1: 3277/Q16 is EXACTLY the authored magnitude "
		+ "(add * 65536 == 3277)",
		int(round(float(adds_s[0]) * float(Q16_ONE))) == PROGRAM_MAGNITUDE_Q16,
		"add*65536=%.6f" % (float(adds_s[0]) * float(Q16_ONE)))
	var s := float(adds_s[0])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 2: + copier at level index 0 (the A1 baseline) ===")
	# ---------------------------------------------------------------------
	_equip(ext, ids, COPIER_CARD)
	_expect("2: the copier lands in slot 1, to the RIGHT of the source",
		_slot_of(ext, handle, copier_dense) == 1, _slots(ext, handle))
	_expect("2: the copier is ACTIVE (location 1)",
		_location_of(ext, handle, copier_dense) == LOCATION_IDEOLOGY,
		_locations(ext, handle))
	_expect("2: the copier is at level index 0 -- BELOW the `state.level >= 2` gate",
		_level_of(ext, handle, copier_dense) == 0,
		str(_level_of(ext, handle, copier_dense)))
	_expect("2: no transition is in flight before the read (plan 10.1: a pending "
		+ "card would contribute the OLD level)",
		_pending(ext) == 0, str(_pending(ext)))
	var m_l0 := _measure(ext, "2/copier L0")
	_expect_front(ext, "2", m_l0, 50, 50, 2)
	_expect("2: the copier's contribution REINSTALLED the front (generation %d -> %d)"
		% [int(m_source["gen"]), int(m_l0["gen"])],
		int(m_l0["gen"]) > int(m_source["gen"]),
		"%d -> %d" % [int(m_source["gen"]), int(m_l0["gen"])])
	_expect("2: the collector ran again (rebuild visits %d -> %d)"
		% [int(m_source["rebuilds"]), int(m_l0["rebuilds"])],
		int(m_l0["rebuilds"]) > int(m_source["rebuilds"]),
		"%d -> %d" % [int(m_source["rebuilds"]), int(m_l0["rebuilds"])])
	var adds_l0: PackedFloat64Array = m_l0["adds"]
	# The copier copies the source's level list VERBATIM, so at level 0 the copied
	# program is the same program at scale 1.0 and the front must double exactly.
	_expect_cells(ext, "2", m_l0, s + s)
	_expect("2: the copier reproduces the source exactly at level 0 "
		+ "(front add == 2 x S), so A1 below is the COPIER's own add and not noise",
		_is_close(float(adds_l0[0]), s + s, 1e-15),
		"actual=%.17f expected=%.17f" % [float(adds_l0[0]), s + s])
	_expect("2: the merged stat value is 1 + 2S (the front really reached the "
		+ "reader)", _is_close(float((m_l0["values"] as PackedFloat64Array)[0]),
		1.0 + s + s, 1e-15),
		"actual=%.17f expected=%.17f"
			% [float((m_l0["values"] as PackedFloat64Array)[0]), 1.0 + s + s])
	var a1 := float(adds_l0[0]) - s
	print("[2] A1 = front(L0) - S = %.17f - %.17f = %.17f" % [float(adds_l0[0]), s, a1])
	_expect("2: A1 (the copier's own add at level 0) IS S, bit for bit",
		_is_close(a1, s, 1e-15), "a1=%.17f s=%.17f" % [a1, s])
	_expect("2: A1 is exactly 3277/Q16 (integer identity)",
		int(round(a1 * float(Q16_ONE))) == PROGRAM_MAGNITUDE_Q16,
		"a1*65536=%.6f" % (a1 * float(Q16_ONE)))

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 3: copier at level index 1 -- levelled up, factor NOT applied ===")
	# ---------------------------------------------------------------------
	# `state.level >= 2` is the gate (ideology_runtime.cpp:2477), so index 1 must
	# still read A1. This is the half of the evidence that separates "the card
	# levelled up" from "the copier factor fired".
	var m_l1 := _advance_and_measure(ext, COPIER_CARD, copier_dense, 1,
		"3/copier L1")
	var adds_l1: PackedFloat64Array = m_l1["adds"]
	var a_mid := float(adds_l1[0]) - s
	print("[3] A(index 1) = %.17f (A1 = %.17f, 1.2 x A1 would be %.17f)"
		% [a_mid, a1, a1 * STATED_COPIER_SCALE])
	_expect("3: at level index 1 the copier's add is STILL A1 (the factor is gated "
		+ "at level >= 2, not at 'levelled up')",
		_is_close(a_mid, a1, 1e-15),
		"actual=%.17f expected=%.17f (1.2 x A1 = %.17f)"
			% [a_mid, a1, a1 * STATED_COPIER_SCALE])
	_expect("3: and it is NOT 1.2 x A1 (the two candidates differ by 0.2 x A1 = "
		+ "%.9f, which is 1.3e6 times the residual phase 4 pins)"
			% (a1 * (STATED_COPIER_SCALE - 1.0)),
		not _is_close(a_mid, a1 * STATED_COPIER_SCALE, 1e-6),
		"actual=%.17f forbidden=%.17f" % [a_mid, a1 * STATED_COPIER_SCALE])
	# Plan I13: an identical candidate is an idempotent no-op, so the generation
	# must NOT move here -- and that is itself the proof that the level change did
	# not alter a single derived number.
	_expect("3: the candidate is content-identical, so the front is NOT reinstalled "
		+ "(generation stays %d)" % int(m_l0["gen"]),
		int(m_l1["gen"]) == int(m_l0["gen"]),
		"%d -> %d" % [int(m_l0["gen"]), int(m_l1["gen"])])
	var volume_label := "3: the collector still RAN on that day (rebuild visits "
	volume_label += "%d -> %d), so 'unchanged' means re-evaluated-and-equal, not "
	volume_label += "never-looked"
	_expect(volume_label % [int(m_l0["rebuilds"]), int(m_l1["rebuilds"])],
		int(m_l1["rebuilds"]) > int(m_l0["rebuilds"]),
		"%d -> %d" % [int(m_l0["rebuilds"]), int(m_l1["rebuilds"])])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 4: copier at level index 2 (A2) -- the fix under test ===")
	# ---------------------------------------------------------------------
	var m_l2 := _advance_and_measure(ext, COPIER_CARD, copier_dense, 2,
		"4/copier L2")
	var adds_l2: PackedFloat64Array = m_l2["adds"]
	var a2 := float(adds_l2[0]) - s
	var scale := float(COPIER_SCALE_Q16) / float(Q16_ONE)
	var stated := a1 * STATED_COPIER_SCALE
	var residual := absf(a2 - stated)
	var predicted := a1 * (STATED_COPIER_SCALE - scale)
	print("[4] A2 = front(L2) - S = %.17f - %.17f = %.17f" % [float(adds_l2[0]), s, a2])
	print("[4] A2 / A1 = %.17f   (78643/65536 = %.17f, stated 1.2)"
		% [a2 / a1, scale])
	print("[4] |A2 - A1*(78643/65536)| = %.17f" % absf(a2 - a1 * scale))
	print("[4] |A2 - A1*1.2|           = %.17f  (predicted A1*(1.2 - 78643/65536) "
		% residual + "= %.17f)" % predicted)
	_expect("4: the level really moved to index 2 before the read",
		_level_of(ext, handle, copier_dense) == 2,
		str(_level_of(ext, handle, copier_dense)))
	_expect("4: the level-2 transition SETTLED before the read (pending == 0, plan "
		+ "10.1)", _pending(ext) == 0, str(_pending(ext)))
	_expect_front(ext, "4", m_l2, 50, 50, 2)
	_expect("4: the front IS reinstalled at level 2 (generation %d -> %d)"
		% [int(m_l1["gen"]), int(m_l2["gen"])],
		int(m_l2["gen"]) > int(m_l1["gen"]),
		"%d -> %d" % [int(m_l1["gen"]), int(m_l2["gen"])])
	_expect("4: the collector ran again (rebuild visits %d -> %d)"
		% [int(m_l1["rebuilds"]), int(m_l2["rebuilds"])],
		int(m_l2["rebuilds"]) > int(m_l1["rebuilds"]),
		"%d -> %d" % [int(m_l1["rebuilds"]), int(m_l2["rebuilds"])])
	# THE SPEC, in the constant's own units: A2 == A1 * 78643/65536.
	_expect("4: the derived add scales by EXACTLY 78643/65536 "
		+ "(A2 == A1 * kCopierLevelTwoScaleQ16 / Q16)",
		_is_close(a2, a1 * scale, 1e-15),
		"actual=%.17f expected=%.17f (missed by %.12f)"
			% [a2, a1 * scale, absf(a2 - a1 * scale)])
	_expect("4: and it scales by exactly 1.2 to within the constant's own "
		+ "quantisation: |A2 - A1*1.2| == A1*(1.2 - 78643/65536)",
		_is_close(residual, predicted, 1e-15),
		"actual=%.17f predicted=%.17f (diff %.12f)"
			% [residual, predicted, absf(residual - predicted)])
	# The residual is NOT zero and must not be asserted to be: 78643/65536 is
	# 1.1999969482421875. Assert its size so a reader can see it is quantization and
	# not a missing factor (a missing factor would make it 0.2*A1 = 0.01).
	var residual_label := "4: the |A2 - A1*1.2| residual is ~1.5e-7, i.e. 0.2*A1 = "
	residual_label += "%.9f, which is 65000x larger -- a MISSING factor could not "
	residual_label += "hide inside it"
	_expect(residual_label % (a1 * (STATED_COPIER_SCALE - 1.0)),
		residual > 0.0 and residual < a1 * (STATED_COPIER_SCALE - 1.0) / 1000.0,
		"residual=%.17f 0.2*A1=%.17f" % [residual,
			a1 * (STATED_COPIER_SCALE - 1.0)])
	_expect("4: A2 * 2^32 == 3277 * 78643 (exact integer identity, no epsilon)",
		int(round(a2 * _q16_squared)) == PROGRAM_MAGNITUDE_Q16 * COPIER_SCALE_Q16,
		"a2*65536^2=%.6f expected=%d"
			% [a2 * _q16_squared, PROGRAM_MAGNITUDE_Q16 * COPIER_SCALE_Q16])
	_expect("4: A2 != A1 (the 1.2 assertion is not vacuous)", not _is_close(a2, a1),
		"a1=%.17f a2=%.17f" % [a1, a2])
	_expect("4: the front's contribution structure did not change -- only the "
		+ "MAGNITUDE scaled (one row per stat per cell, 2 x 25)",
		int(m_l2["contribs"]) == int(m_l0["contribs"])
			and int(m_l2["cells"]) == int(m_l0["cells"])
			and int(m_l2["stats"]) == int(m_l0["stats"]),
		"l0=%d/%d/%d l2=%d/%d/%d" % [int(m_l0["contribs"]), int(m_l0["cells"]),
			int(m_l0["stats"]), int(m_l2["contribs"]), int(m_l2["cells"]),
			int(m_l2["stats"])])
	_expect("4: the merged stat value is 1 + S + A2 (the reader sees the scaled "
		+ "row)", _is_close(float((m_l2["values"] as PackedFloat64Array)[0]),
		1.0 + s + a2, 1e-15),
		"actual=%.17f expected=%.17f"
			% [float((m_l2["values"] as PackedFloat64Array)[0]), 1.0 + s + a2])
	_expect_cells(ext, "4", m_l2, s + a2)
	var ratio := a2 / a1
	print("[4] ratio A2/A1 = %.12f   |A2 - A1*1.2| = %.12f" % [ratio, residual])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 5: the NON-COPIER control at the SAME level ===")
	# ---------------------------------------------------------------------
	# Same three levels, same routing row, same program, same day machinery. The
	# only difference from `test.dcs.copier` is the `copy_left_programs` byte, so if
	# this card scaled too the factor would be about levelling up rather than about
	# copying -- and the phase-4 number would mean nothing.
	var ext2: Object = _build_world(country_ir, profile, effect_ir, mod_ir, native,
		"dcsctl")
	var handle2 := _handle(ext2)
	_equip(ext2, ids, CONTROL_CARD)
	_expect("5: the control card is ACTIVE in slot 0 at level index 0",
		_location_of(ext2, handle2, control_dense) == LOCATION_IDEOLOGY
			and _level_of(ext2, handle2, control_dense) == 0,
		"%s %s" % [_locations(ext2, handle2),
			str(_level_of(ext2, handle2, control_dense))])
	var m_c0 := _measure(ext2, "5/control L0")
	_expect_front(ext2, "5", m_c0, 50, 50, 2)
	var adds_c0: PackedFloat64Array = m_c0["adds"]
	var v0 := float(adds_c0[0])
	print("[5] control add at level 0 = %.17f (A1 = %.17f)" % [v0, a1])
	_expect("5: the control card's level-0 add is the same S the copier's source "
		+ "paints (one program, one backend)", _is_close(v0, s, 1e-15),
		"actual=%.17f expected=%.17f" % [v0, s])
	var m_c2 := _advance_and_measure(ext2, CONTROL_CARD, control_dense, 2,
		"5/control L2")
	var adds_c2: PackedFloat64Array = m_c2["adds"]
	var v2 := float(adds_c2[0])
	var control_delta := absf(v2 - v0)
	print("[5] control add at level 2 = %.17f" % v2)
	print("[5] |V2 - V0| = %.17f   |V2 - V0*1.2| = %.17f"
		% [control_delta, absf(v2 - v0 * STATED_COPIER_SCALE)])
	_expect("5: the control card's level-2 add is BIT-IDENTICAL to its level-0 add "
		+ "(no factor), |V2 - V0| == 0", _is_close(v2, v0, 1e-15),
		"v0=%.17f v2=%.17f" % [v0, v2])
	_expect("5: and it is NOT 1.2 x V0 -- |V2 - V0*1.2| = 0.2*V0 = %.9f, which is "
		% (v0 * (STATED_COPIER_SCALE - 1.0))
		+ "44000x the copier's own |A2 - A1*1.2| (%.12f)" % residual,
		_is_close(absf(v2 - v0 * STATED_COPIER_SCALE), v0 * 0.2, 1e-15),
		"actual=%.17f expected=%.17f"
			% [absf(v2 - v0 * STATED_COPIER_SCALE), v0 * 0.2])
	_expect("5: the control's front was NOT reinstalled at level 2 either "
		+ "(generation %d -> %d)" % [int(m_c0["gen"]), int(m_c2["gen"])],
		int(m_c2["gen"]) == int(m_c0["gen"]),
		"%d -> %d" % [int(m_c0["gen"]), int(m_c2["gen"])])
	var control_volume_label := "5: but the collector ran (rebuild visits "
	control_volume_label += "%d -> %d), so the control is a measurement, not a "
	control_volume_label += "skipped day"
	_expect(control_volume_label % [int(m_c0["rebuilds"]), int(m_c2["rebuilds"])],
		int(m_c2["rebuilds"]) > int(m_c0["rebuilds"]),
		"%d -> %d" % [int(m_c0["rebuilds"]), int(m_c2["rebuilds"])])
	# The discrimination, as one number: the copier's ratio is 78643/65536 and the
	# control's is 1.0. A fixture that could not tell them apart would be measuring
	# nothing.
	_expect("5: the copier's ratio (%.12f) differs from the control's (%.12f)"
		% [ratio, v2 / v0], not _is_close(ratio, v2 / v0, 1e-6),
		"copier=%.17f control=%.17f" % [ratio, v2 / v0])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 6: the shipped catalog ===")
	# ---------------------------------------------------------------------
	_audit_shipped(catalog, declared_programs, programs)

	# ---------------------------------------------------------------------
	print("")
	print("=== SUMMARY (all values are `derived_add` on %s) ===" % PROGRAM_STAT)
	# ---------------------------------------------------------------------
	print("  S   (source alone)            = %.17f  (3277/Q16 = %.17f)"
		% [s, expect_s])
	print("  A1  (copier at level index 0) = %.17f" % a1)
	print("  A?  (copier at level index 1) = %.17f  (unchanged: below the gate)"
		% a_mid)
	print("  A2  (copier at level index 2) = %.17f" % a2)
	print("  ratio A2/A1                   = %.17f  (78643/65536 = %.17f)"
		% [ratio, scale])
	print("  |A2 - A1*(78643/65536)|       = %.12f" % absf(a2 - a1 * scale))
	print("  |A2 - A1*1.2|                 = %.12f" % residual)
	print("  A1*(1.2 - 78643/65536)        = %.12f" % predicted)
	print("  control V0 -> V2              = %.17f -> %.17f  (delta %.12f)"
		% [v0, v2, control_delta])
	print("  |V2 - V0*1.2|                 = %.9f"
		% absf(v2 - v0 * STATED_COPIER_SCALE))
	print("")
	_finish(0 if _failures == 0 else 1)


# -- the fixture's cards --------------------------------------------------

## Appends the three test cards to the LOADED catalog resource. Nothing is written
## to disk; this is the same "configure the in-memory copy" shape
## `ideology_mechanism_copier_school_test.gd:_relax_catalog` uses.
##
## Each card's level rows are ROUTING MARKERS (`_append_effect_rows`,
## ideology_catalog.gd:676-692): a row whose `definition_key` names a declared
## program contributes no Modifier command of its own, because the program owns the
## selector, the magnitude and the conditions. That is why the same row shape gives
## a DERIVED effect here while `idea.algorithmic_governance`'s rows -- which name a
## Modifier definition -- stay on the instance path.
##
## Giving the rows to every level (rather than leaving the levels empty) is what
## makes the cards "cell-targeting at levels 0/1/2"; and because a program row is
## skipped by `emit_templates` (`ideology_runtime.cpp:1718-1723`), a level change
## emits NO Effect transaction, so the transitions in this fixture commit
## synchronously instead of sitting PENDING.
func _add_fixture_cards(catalog: Resource) -> void:
	for row in [
			# id, copy_left_programs, copyable, level count
			[SOURCE_CARD, false, true, 1],
			[COPIER_CARD, true, false, 3],
			[CONTROL_CARD, false, false, 3]]:
		var definition: Resource = IdeologyDefinitionScript.new()
		definition.id = StringName(String(row[0]))
		definition.icon_key = &"country.politics"
		definition.name_key = StringName("test %s" % String(row[0]))
		definition.detail_key = "synthesised by ideology_derived_copier_scale_test"
		definition.school_id = &"learning"
		definition.rarity = 1
		definition.rarity_weight = 100
		definition.ideology_slot_cost = 1
		definition.national_spirit_slot_cost = 1
		definition.acquisition_flags = 3  # DISCOVER | DRAW
		definition.national_spirit_min_level = 0
		# The support gate reads the compiled stance table; a card with no
		# `class_stances` is unconditionally allowed
		# (`evaluate_support`, ideology_runtime.cpp:1251-1255), so these thresholds
		# only keep the value meaningful for a reader.
		definition.adopt_threshold_q16 = -65536
		definition.repeal_threshold_q16 = -65536
		definition.promote_threshold_q16 = -65536
		definition.era_index = 0
		definition.copy_left_programs = bool(row[1])
		definition.copyable = bool(row[2])
		# The SOURCE has ONE level: it is a static program donor, so the list the
		# copier copies can never change under the measurement. The two cards under
		# test have three, so level index 2 (the `state.level >= 2` gate) exists.
		var levels: Array[Resource] = []
		for index in range(int(row[3])):
			var level: Resource = IdeologyLevelDefinitionScript.new()
			level.understanding_threshold_q16 = int(LEVEL_THRESHOLDS_Q16[index])
			level.daily_understanding_q16 = LEVEL_DAILY_Q16
			var rows: Array[Resource] = []
			var marker: Resource = EffectCommandScript.new()
			marker.action = 1
			marker.domain = 2
			marker.opcode = 1
			marker.target_resolver = 1
			marker.value_mode = 0
			marker.value_q16 = Q16_ONE
			marker.duration_days = -1
			marker.stacks = 1
			marker.command_key = &"ideology.persistent"
			marker.definition_key = StringName(PROGRAM_KEY)
			rows.append(marker)
			level.persistent_effects = rows
			levels.append(level)
		definition.levels = levels
		catalog.definitions.append(definition)


# -- the shipped-catalog audit --------------------------------------------

## The assertion that goes RED the day content adds a derived copier.
##
## The predicate is the `decide_cell_program_backend` half that a content change
## moves: a row is DERIVED-CELL when it names a declared program whose
## `target_domain` is the cell domain, whose `lifecycle` is permanent, and whose
## selector kind is one of {12, 14, 15, 16}. Those are the same four kinds
## `cell_program_selector_supported` admits (cell_program_eligibility.h:95-105) and
## the same four `get_cell_program_rollout` reports enabled -- both asserted in
## phase 0, so this predicate is anchored to the engine rather than being a private
## opinion.
##
## It OVER-approximates (it ignores the per-command conditions), which is the safe
## direction for a guard: a false positive turns the fixture red and gets looked at,
## a false negative would let a derived copier ship unmeasured.
func _audit_shipped(catalog: Resource, declared: Dictionary,
		programs: Dictionary) -> void:
	var shipped_total := 0
	var shipped_derived := 0
	var shipped_copiers: PackedStringArray = []
	var shipped_derived_copiers: PackedStringArray = []
	var shipped_derived_examples: PackedStringArray = []
	var fixture_total := 0
	var fixture_derived_copiers: PackedStringArray = []
	var shipped_copier_definition: Resource = null
	for definition in catalog.definitions:
		if definition == null:
			continue
		var card_id := String(definition.id)
		var is_fixture := card_id.begins_with(FIXTURE_PREFIX)
		var derived_programs := _derived_programs_of(definition, declared, programs)
		if is_fixture:
			fixture_total += 1
			if bool(definition.copy_left_programs) and not derived_programs.is_empty():
				fixture_derived_copiers.append(card_id)
			continue
		shipped_total += 1
		if bool(definition.copy_left_programs):
			shipped_copiers.append(card_id)
			shipped_copier_definition = definition
		if not derived_programs.is_empty():
			shipped_derived += 1
			if shipped_derived_examples.size() < 5:
				shipped_derived_examples.append(card_id)
			if bool(definition.copy_left_programs):
				shipped_derived_copiers.append(card_id)
	print("[6] shipped cards                      = %d" % shipped_total)
	print("[6] shipped copiers                    = %d %s"
		% [shipped_copiers.size(), str(shipped_copiers)])
	print("[6] shipped cards with a derived (cell-targeting) effect = %d"
		% shipped_derived)
	print("[6] shipped DERIVED COPIERS            = %d %s"
		% [shipped_derived_copiers.size(), str(shipped_derived_copiers)])
	print("[6] first derived cards                = %s"
		% str(shipped_derived_examples))
	print("[6] fixture cards excluded from the audit = %d %s"
		% [fixture_total, str(fixture_derived_copiers)])
	_expect("6: the shipped catalog carries exactly one copier card",
		shipped_copiers.size() == 1, str(shipped_copiers))
	_expect("6: that copier is `%s`" % SHIPPED_COPIER,
		shipped_copiers == PackedStringArray([SHIPPED_COPIER]),
		str(shipped_copiers))
	_expect("6: the audit finds derived cards at all (a zero here would make the "
		+ "next assertion vacuous)", shipped_derived > 0, str(shipped_derived))
	_expect("6: NO shipped card is both a copier and a cell-targeting (derived) "
		+ "effect -- so the derived copier factor is shipped-impact-free",
		shipped_derived_copiers.is_empty(), str(shipped_derived_copiers))
	_expect("6: the fixture contributed exactly three cards and they are excluded "
		+ "from the shipped counts", fixture_total == 3, str(fixture_total))
	# THE GUARD IS LIVE: the fixture's own copier card, run through the SAME
	# predicate, IS a derived copier. So the zero above is a real zero, not a
	# predicate that can never fire.
	_expect("6: the fixture's derived copier card DOES satisfy the same predicate "
		+ "(the guard can fire)", fixture_derived_copiers
			== PackedStringArray([COPIER_CARD]), str(fixture_derived_copiers))

	# ---- why the one shipped copier escapes: named, per level ----------
	var rows_seen := 0
	var legacy_rows := 0
	var definitions := {}
	if shipped_copier_definition != null:
		for level in shipped_copier_definition.levels:
			for effect in level.persistent_effects:
				rows_seen += 1
				if effect == null:
					continue
				definitions[String(effect.definition_key)] = true
				var declared_key := String(effect.definition_key)
				var is_program := declared.has(
					IdeologyCatalogScript.PROGRAM_KEY_PREFIX + declared_key)
				var cell_shape := int(effect.domain) == 2 \
					and int(effect.target_resolver) == 1
				if not is_program and not cell_shape:
					legacy_rows += 1
		print("[6] the shipped copier's rows      = %d (%d NOT a declared program, "
			% [rows_seen, legacy_rows] + "definition keys %s)" % str(definitions.keys()))
	_expect("6: the shipped copier has one block row per level (3 total)",
		rows_seen == 3, str(rows_seen))
	_expect("6: all three rows are Modifier-domain commands, not programs "
		+ "(so only the instance path can express the card)",
		legacy_rows == 3, "%d of %d" % [legacy_rows, rows_seen])
	_expect("6: every row names the same Modifier definition `%s`"
		% SHIPPED_COPIER_DEFINITION,
		definitions.size() == 1 and definitions.has(SHIPPED_COPIER_DEFINITION),
		str(definitions.keys()))
	_expect("6: no shipped level row of any card routes to a program named "
		+ "`%s`" % SHIPPED_COPIER_DEFINITION,
		not declared.has("ideology.effect.%s" % SHIPPED_COPIER_DEFINITION),
		"ideology.effect.%s is declared" % SHIPPED_COPIER_DEFINITION)
	# The `target_resolver = 1` / `duration_days = -1` shape the content claim is
	# made of, checked byte by byte on the shipped rows.
	var resolver_ok := true
	var duration_ok := true
	var domain_ok := true
	if shipped_copier_definition != null:
		for level in shipped_copier_definition.levels:
			for effect in level.persistent_effects:
				if effect == null:
					continue
				resolver_ok = resolver_ok and int(effect.target_resolver) == 1
				duration_ok = duration_ok and int(effect.duration_days) == -1
				domain_ok = domain_ok and int(effect.domain) == 1
	_expect("6: every shipped copier row has target_resolver = 1 (a Modifier-domain "
		+ "command, not a cell selector)", resolver_ok, str(resolver_ok))
	_expect("6: every shipped copier row has duration_days = -1 (permanent)",
		duration_ok, str(duration_ok))
	_expect("6: every shipped copier row has domain = 1 (COUNTRY, not the cell "
		+ "domain 2)", domain_ok, str(domain_ok))

	# ---- and the copy SOURCE side is live in shipped content -----------
	var source_copyable := false
	var source_found := false
	for definition in catalog.definitions:
		if definition != null and String(definition.id) == SHIPPED_COPY_SOURCE:
			source_found = true
			source_copyable = bool(definition.copyable)
	_expect("6: the shipped card the copier mechanism documents as its source "
		+ "(`%s`) exists and is copyable" % SHIPPED_COPY_SOURCE,
		source_found and source_copyable,
		"found=%s copyable=%s" % [str(source_found), str(source_copyable)])


## Program keys (`ideology.effect.<bare>`) a card's LEVEL rows route to that the
## derived layer can express. Empty means the card never reaches the derived backend
## through its own levels.
func _derived_programs_of(definition: Resource, declared: Dictionary,
		programs: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for level in definition.levels:
		if level == null:
			continue
		for effect in level.persistent_effects:
			if effect == null:
				continue
			var key := IdeologyCatalogScript.PROGRAM_KEY_PREFIX \
				+ String(effect.definition_key)
			if not declared.has(key) or not programs.has(key):
				continue
			var program: Resource = programs[key]
			if int(program.target_domain) != TARGET_DOMAIN_CELL:
				continue
			if int(program.lifecycle) != LIFECYCLE_PERMANENT:
				continue
			if not DERIVED_SELECTOR_KINDS.has(int(program.target_selector_kind)):
				continue
			if not out.has(key):
				out.append(key)
	return out


func _program_index(effect_catalog: Resource) -> Dictionary:
	var out := {}
	for effect in effect_catalog.effects:
		if effect == null:
			continue
		var key := String(effect.program_key())
		if not key.is_empty():
			out[key] = effect
	return out


## The engine's own `decide_cell_program_backend`, driven through the bound
## `probe_cell_program_backend` bridge (world_ext_modifier.cpp:901-963) with the
## facts of `program`'s FIRST command. One command is enough here because the
## question is "is this kind of program derived at all", and the first command's
## facts are the ones that decide it for a single-command program like
## `public_hygiene_l1`.
func _probe_program_backend(program: Resource, mod_ir: Dictionary) -> Dictionary:
	var facts := {
		"target_domain": int(program.target_domain),
		"target_selector_kind": int(program.target_selector_kind),
		"lifecycle": int(program.lifecycle),
		"duration_days": int(program.duration_days),
		"stack_policy": int(program.stack_policy),
		"max_stacks": int(program.max_stacks),
	}
	var commands: Array = program.commands
	if not commands.is_empty() and commands[0] != null:
		var command: Resource = commands[0]
		facts["command_value_mode"] = int(command.value_mode)
		# `public_hygiene_l1`'s instructions are `CONST -> EMIT`, i.e. a stack-top
		# magnitude that is still a compile-time constant
		# (`CellProgramCommandFacts.stack_top_is_constant`,
		# cell_program_eligibility.h:52-56).
		facts["command_stack_top_is_constant"] = int(command.value_mode) == 1
		facts["command_definition_resolved"] = _definition_resolved(mod_ir,
			String(command.definition_key))
		facts["command_all_terms_sum"] = _definition_all_add(mod_ir,
			String(command.definition_key))
		facts["command_stacks"] = int(command.stacks)
		facts["command_duration_days"] = int(command.duration_days)
	return _probe_backend(facts)


func _probe_backend(facts: Dictionary) -> Dictionary:
	if _probe_host != null:
		return _probe_host.probe_cell_program_backend(facts)
	return {"ok": false, "reason": "probe_host_unavailable", "backend": ""}


func _definition_resolved(mod_ir: Dictionary, definition_key: String) -> bool:
	var keys: PackedStringArray = mod_ir.get("definition_keys", PackedStringArray())
	return keys.has(definition_key)


## Every term of `definition_key` is an ADD (operation 0), which is condition 9 of
## `decide_cell_program_backend` (cell_program_eligibility.h:174-179).
func _definition_all_add(mod_ir: Dictionary, definition_key: String) -> bool:
	var keys: PackedStringArray = mod_ir.get("definition_keys", PackedStringArray())
	var offsets: PackedInt32Array = mod_ir.get(
		"definition_term_offsets", PackedInt32Array())
	var operations: PackedInt32Array = mod_ir.get("term_operations", PackedInt32Array())
	var index := keys.find(definition_key)
	if index < 0 or index + 1 >= offsets.size():
		return false
	var begin := int(offsets[index])
	var end := int(offsets[index + 1])
	if end <= begin:
		return false
	for row in range(begin, end):
		if row >= operations.size():
			return false
		if int(operations[row]) != 0:
			return false
	return true


# -- driving the world ----------------------------------------------------

## One ideology day plus the native Effect adapter pulse. The handshake order is
## the one the settle contract requires: the ACK must complete BEFORE the ideology
## poll that turns it into a settled transition (`poll_pending_transition`,
## ideology_runtime.cpp:3830-3852), so the adapter pulse runs first and the day's
## own slices follow.
##
## `run_ideology_daily` is a SLICE stage (`done=false` while the day, the rebuild or
## the command queue still has work), so the loop is bounded by the runtime's own
## `done` flag rather than by a guessed call count.
func _day_step(ext: Object) -> void:
	_day += 1
	_serve_native_adapters(ext, _day)
	for _i in range(MAX_DAY_SLICES):
		var ran: Dictionary = ext.run_ideology_daily(_day)
		if not bool(ran.get("ok", true)):
			printerr("[day %d] run_ideology_daily: %s" % [_day, str(ran)])
			return
		if bool(ran.get("done", false)):
			return
	printerr("[day %d] run_ideology_daily never reported done" % _day)


## `dispatch_effect_native_modifier()` -> `run_modifier_daily(day)` ->
## `ack_effect_native_modifier()`, the sequence the plan calls the settle
## handshake. Bounded: it stops as soon as the Modifier side reports no pending
## rows, which is the state the ideology poll needs to see.
func _serve_native_adapters(ext: Object, day: int) -> void:
	for _i in range(8):
		ext.run_effect_daily(day)
		var dispatched: Dictionary = ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var acked: Dictionary = ext.ack_effect_native_modifier()
		ext.dispatch_effect_native_country()
		ext.ack_effect_native_country()
		if not bool(dispatched.get("ok", true)) or not bool(acked.get("ok", true)):
			printerr("[adapters day=%d] dispatch=%s ack=%s"
				% [day, str(dispatched), str(acked)])
			return
		if int(acked.get("acknowledged", 0)) > 0 and int(acked.get("pending", 0)) == 0:
			return
		if _pending(ext) == 0:
			return


## grant -> discover -> equip, then wait for the level transition to SETTLE and the
## derived front to be adopted. `equip` refuses while a transition is in flight
## (`ideology_country_transition_pending`, ideology_runtime.cpp:4660-4662), and the
## refusal is a command RESULT rather than a throw, so it is checked -- a fixture
## that ignored it would silently measure a world where the card never equipped.
func _equip(ext: Object, ids: PackedStringArray, key: String) -> void:
	var dense := ids.find(key)
	if dense < 0:
		_expect("%s is present in the compiled catalog" % key, false, str(dense))
		return
	var handle := _handle(ext)
	_submit(ext, {"op": OP_GRANT, "handle": handle, "idea": -1, "value": 64 * Q16_ONE})
	_submit(ext, {"op": OP_DISCOVER, "handle": handle, "idea": dense})
	_day_step(ext)
	var known: PackedInt32Array = _snapshot(ext, handle).get(
		"known_ids", PackedInt32Array())
	_expect("%s: the card is DISCOVERED before the equip (known_ids contains it)"
		% key, known.has(dense), str(known))
	_submit(ext, {"op": OP_EQUIP, "handle": handle, "idea": dense})
	var days := 0
	while _location_of(ext, handle, dense) != LOCATION_IDEOLOGY and days < 24:
		_day_step(ext)
		days += 1
	if _location_of(ext, handle, dense) != LOCATION_IDEOLOGY:
		printerr("[equip %s] never became active: loc=%s slots=%s"
			% [key, _locations(ext, handle), _slots(ext, handle)])
		printerr("[equip receipts] %s" % str(ext.poll_ideology_receipts(0, 64)))
	_expect("%s: the equip lands ACTIVE (location 1)" % key,
		_location_of(ext, handle, dense) == LOCATION_IDEOLOGY,
		_locations(ext, handle))
	_settle(ext, key)
	_drain(ext)


## Raises the card to level index `target` through the real `ADD_UNDERSTANDING`
## path, then MEASURES. The level and the transition state are asserted before the
## read: a silent level-0 measurement is exactly the failure mode this fixture
## exists to prevent.
##
## The promotion is driven one level at a time (`start_next_level_transition`
## advances exactly one level per visit, ideology_runtime.cpp:3924-3938), and the
## understanding delta is computed from the authored threshold table this fixture
## itself compiled into the card, so no magic number can drift out of step.
func _advance_and_measure(ext: Object, key: String,
		dense: int, target: int, label: String) -> Dictionary:
	var handle := _handle(ext)
	var thresholds := _level_thresholds()
	var guard := 0
	while _level_of(ext, handle, dense) < target and guard < 8:
		var level := _level_of(ext, handle, dense)
		if level < 0 or level + 1 >= thresholds.size():
			break
		var understanding := _understanding_of(ext, handle, dense)
		var need := int(thresholds[level + 1]) - understanding
		if need <= 0:
			need = 1
		_submit(ext, {"op": OP_ADD_UNDERSTANDING, "handle": handle, "idea": dense,
			"value": need})
		_day_step(ext)
		guard += 1
	var reached := _level_of(ext, handle, dense)
	_expect("%s: the card really reached level index %d (level=%d, %d promotion "
		% [label, target, reached, guard]
		+ "step(s)) -- a silent level-0 measurement would make everything below "
		+ "meaningless", reached == target, str(reached))
	_settle(ext, key)
	_expect("%s: no transition is in flight at the measurement (plan 10.1: a "
		% label + "pending card contributes the OLD level)", _pending(ext) == 0,
		str(_pending(ext)))
	_drain(ext)
	return _measure(ext, label)


## Steps days until every transition has settled, bounded.
func _settle(ext: Object, key: String) -> void:
	var days := 0
	while _pending(ext) != 0 and days < MAX_SETTLE_DAYS:
		_day_step(ext)
		days += 1
	if days > 0:
		print("[settle] %s: %d extra day(s), pending_transitions=%d"
			% [key, days, _pending(ext)])


## `drain_derived_cell_layer(day)` drives `step_derived_rebuild(day)`, and that
## refuses any day before the confirmed projection's `eligible_from_day`
## (ideology_runtime.cpp:7220-7231) -- so the CURRENT day is passed. `0` would be a
## silent no-op once anything has confirmed.
func _drain(ext: Object) -> void:
	if ext.has_method("drain_derived_cell_layer"):
		ext.drain_derived_cell_layer(_day)


func _submit(ext: Object, row: Dictionary) -> void:
	row["day"] = _day
	var result: Dictionary = ext.submit_ideology_commands(_commands([row]))
	if not bool(result.get("ok", true)):
		printerr("[submit op=%d idea=%d] %s"
			% [int(row.get("op", 0)), int(row.get("idea", -1)), str(result)])


func _commands(rows: Array) -> Dictionary:
	var count: int = rows.size()
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
	for i in range(count):
		var row: Dictionary = rows[i]
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		producers.append(1)
		# `sequences` is the idempotency key and must be monotonic ACROSS batches.
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


# -- measurement ----------------------------------------------------------

## Reads the derived front's own slice of one stat on every probe cell, plus the
## layer bookkeeping that makes the read non-vacuous: the front must be installed,
## cover `2 stats x 25 cells`, and the generation / rebuild counters must show the
## layer really moved (or really did not) on this step.
func _measure(ext: Object, label: String) -> Dictionary:
	var front: Dictionary = ext.get_derived_cell_layer_report()
	var report: Dictionary = ext.get_ideology_report()
	var adds := PackedFloat64Array()
	var values := PackedFloat64Array()
	var present := PackedByteArray()
	for cell in PROBE_CELLS:
		# entity_handle MUST be 0 and the CELL goes in the group slot: that is the
		# pair the production reader uses (economy_runtime_family_buff.cpp:7127).
		var probe: Dictionary = ext.get_effective_stat_value(PROGRAM_STAT,
			int(cell), 0, 1.0)
		present.append(1 if bool(probe.get("derived_present", false)) else 0)
		adds.append(float(probe.get("derived_add", 0.0)))
		values.append(float(probe.get("value", 0.0)))
	var cells_line := PackedStringArray()
	for index in range(PROBE_CELLS.size()):
		cells_line.append("%d:%.12f" % [int(PROBE_CELLS[index]), float(adds[index])])
	print("[%s] derived_add %s" % [label, ", ".join(cells_line)])
	print("[%s] front installed=%s stats=%s cells=%s contributions=%s gen=%d "
		% [label, str(front.get("installed", "?")),
			str(front.get("stat_count", "?")), str(front.get("cell_count", "?")),
			str(front.get("contribution_count", "?")),
			int(front.get("layer_generation", -1))]
		+ "sample_day=%s rebuilds=%d pending=%d values[0]=%.12f"
		% [str(front.get("sample_day", "?")),
			int(report.get("cell_layer_rebuild_visits", -1)), _pending(ext),
			float(values[0])])
	return {
		"adds": adds, "values": values, "present": present,
		"gen": int(front.get("layer_generation", -1)),
		"installed": bool(front.get("installed", false)),
		"cells": int(front.get("cell_count", -1)),
		"contribs": int(front.get("contribution_count", -1)),
		"stats": int(front.get("stat_count", -1)),
		"rebuilds": int(report.get("cell_layer_rebuild_visits", -1)),
		"days": int(front.get("sample_day", -1)),
	}


## The front must really be there and really cover the territory. Without this, a
## ratio between two absences would pass as evidence.
func _expect_front(ext: Object, label: String, measured: Dictionary,
		want_cells: int, want_contribs: int, want_stats: int) -> void:
	_expect("%s: the derived front is installed" % label,
		bool(measured.get("installed", false)), str(measured.get("installed")))
	_expect("%s: the front covers %d cells (2 stats x 25 owned cells)"
		% [label, want_cells], int(measured["cells"]) == want_cells,
		str(measured["cells"]))
	_expect("%s: the front holds %d contributions" % [label, want_contribs],
		int(measured["contribs"]) == want_contribs, str(measured["contribs"]))
	_expect("%s: the front holds %d stats" % [label, want_stats],
		int(measured["stats"]) == want_stats, str(measured["stats"]))
	var present := PackedByteArray()
	for cell in PROBE_CELLS:
		present.append(1 if bool(ext.get_effective_stat_value(PROGRAM_STAT,
			int(cell), 0, 1.0).get("derived_present", false)) else 0)
	var all_present := true
	for flag in present:
		all_present = all_present and int(flag) == 1
	_expect("%s: every probe cell carries a derived row for %s"
		% [label, PROGRAM_STAT], all_present, str(present))


## Every probe cell must show the SAME add. A selector that covered only some cells
## would satisfy a single-cell assertion by accident.
func _expect_cells(ext: Object, label: String, measured: Dictionary,
		expected: float) -> void:
	var adds: PackedFloat64Array = measured["adds"]
	var all_ok := adds.size() == PROBE_CELLS.size()
	var detail := PackedStringArray()
	for index in range(adds.size()):
		detail.append("%d:%.17f" % [int(PROBE_CELLS[index]), float(adds[index])])
		all_ok = all_ok and _is_close(float(adds[index]), expected, 1e-15)
	_expect("%s: all %d probe cells read the same add %.17f"
		% [label, PROBE_CELLS.size(), expected], all_ok,
		"%s (expected %.17f)" % [", ".join(detail), expected])


# -- readers --------------------------------------------------------------

func _handle(ext: Object) -> int:
	return int(ext.get_country_cell_summary(0).get("country_handle", 0))


func _snapshot(ext: Object, handle: int) -> Dictionary:
	return ext.get_ideology_snapshot(handle)


func _pending(ext: Object) -> int:
	return int(ext.get_ideology_report().get("pending_transitions", -1))


func _index_of(ext: Object, handle: int, dense: int) -> int:
	var idea_ids: PackedInt32Array = _snapshot(ext, handle).get(
		"idea_ids", PackedInt32Array())
	return idea_ids.find(dense)


func _slot_of(ext: Object, handle: int, dense: int) -> int:
	var fields: Dictionary = _snapshot(ext, handle)
	var slots: PackedInt32Array = fields.get("slot_indices", PackedInt32Array())
	var index := _index_of(ext, handle, dense)
	if index < 0 or index >= slots.size():
		return -1
	return int(slots[index])


func _location_of(ext: Object, handle: int, dense: int) -> int:
	var fields: Dictionary = _snapshot(ext, handle)
	var locations: PackedInt32Array = fields.get("locations", PackedInt32Array())
	var index := _index_of(ext, handle, dense)
	if index < 0 or index >= locations.size():
		return -1
	return int(locations[index])


func _level_of(ext: Object, handle: int, dense: int) -> int:
	var fields: Dictionary = _snapshot(ext, handle)
	var levels: PackedInt32Array = fields.get("levels", PackedInt32Array())
	var index := _index_of(ext, handle, dense)
	if index < 0 or index >= levels.size():
		return -1
	return int(levels[index])


func _understanding_of(ext: Object, handle: int, dense: int) -> int:
	var fields: Dictionary = _snapshot(ext, handle)
	var values: PackedInt64Array = fields.get(
		"understanding_q16", PackedInt64Array())
	var index := _index_of(ext, handle, dense)
	if index < 0 or index >= values.size():
		return 0
	return int(values[index])


## The per-level understanding thresholds the fixture authored (all three cards
## share one table), so the promotion delta can never drift from the levels the
## catalog compiled.
func _level_thresholds() -> PackedInt64Array:
	var out := PackedInt64Array()
	for threshold in LEVEL_THRESHOLDS_Q16:
		out.append(int(threshold))
	return out


func _slots(ext: Object, handle: int) -> String:
	return str(_snapshot(ext, handle).get("slot_indices", PackedInt32Array()))


func _locations(ext: Object, handle: int) -> String:
	return str(_snapshot(ext, handle).get("locations", PackedInt32Array()))


# -- world construction ---------------------------------------------------

func _build_world(country_ir: Dictionary, profile: Dictionary,
		effect_ir: Dictionary, mod_ir: Dictionary, native: Dictionary,
		tag: String) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot (M3-20).
	ext.create_entities(CELLS)
	_fill_environment(ext)
	var ok := true
	ok = ok and bool(ext.configure_economy(
		country_ir, profile, CELLS, 97).get("ok", false))
	ok = ok and bool(ext.configure_effects(effect_ir).get("ok", false))
	ok = ok and bool(ext.configure_modifiers(mod_ir, CELLS).get("ok", false))
	ok = ok and bool(ext.configure_country(country_ir, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}, CELLS, 97).get("ok", false))
	_expect("%s: the world configures" % tag, ok)
	var territory := PackedInt32Array()
	for c in range(CELLS):
		territory.append(c)
	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.%s" % tag]),
		"country_names": PackedStringArray(["World %s" % tag]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("%s: the country bootstraps" % tag, bool(boot.get("ok", false)),
		str(boot))
	var cfg: Dictionary = ext.configure_ideologies(native)
	_expect("%s: ideologies configure" % tag, bool(cfg.get("ok", false)),
		str(cfg.get("reason", cfg.get("fatal_reason", str(cfg)))))
	_expect("%s: the economy epoch opens" % tag,
		bool(ext.begin_or_reuse_economy_input_epoch(0, {
			"sample_day": 0, "epoch_id": 1, "map_generation": 1,
			"building_generation": 1, "country_generation": 1,
			"resource_generation": 1}).get("ok", false)))
	var econ: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var sig_keys: PackedStringArray = econ.get("signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var serf: int = sig_keys.find("serf|default")
	var goods: int = (econ.get("good_ids", PackedStringArray())).size()
	if farmer >= 0:
		var stock := PackedInt64Array()
		stock.resize(CELLS * goods)
		stock.fill(0)
		var ci := PackedInt32Array()
		var si := PackedInt32Array()
		var pp := PackedInt64Array()
		var ff := PackedInt64Array()
		# 40 people per cell, above the 30 that `_install_satisfiable_tag` requires
		# of `cell.settlement`, so the kind-12 selector covers all 25 cells.
		for c in range(CELLS):
			for pair in [[farmer, 20], [serf, 20]]:
				if int(pair[0]) < 0:
					continue
				ci.append(c)
				si.append(int(pair[0]))
				pp.append(int(pair[1]))
				ff.append(10000000)
		var eb: Dictionary = ext.bootstrap_economy({
			"cell_indices": ci, "signature_ids": si,
			"population": pp, "funds": ff,
		}, {
			"stock": stock,
			"building_cells": PackedInt32Array(),
			"building_type_ids": PackedInt32Array(),
			"building_owner_signatures": PackedInt32Array(),
			"building_counts": PackedInt64Array(),
		})
		_expect("%s: the economy bootstraps" % tag, bool(eb.get("ok", false)),
			str(eb))
		for s in range(512):
			if bool(ext.run_economy_slice(
					{"day_index": 0, "tick_index": s}).get("done", false)):
				break
	if _probe_host == null:
		_probe_host = ext
	return ext


## Fixture knobs on the COMPILED catalogue (no file is touched):
##   * draw requirements are dropped (a bootstrapped world has none of the late
##     technologies the cards are authored against);
##   * slot capacity is raised so two cards fit;
##   * ADOPT support thresholds are floored -- the fixture's own cards carry no
##     class stances and would pass anyway (`evaluate_support` short-circuits when
##     `stance_count == 0`), but the shipped cards do not, and a world with no class
##     opinion snapshot would otherwise make `equip` refuse;
##   * SYNERGIES are emptied. `equip` refuses the whole command while ANY transition
##     is in flight AND a synergy exists
##     (`if (country.pending_transition_count > 0 && !_synergies.empty())`,
##     ideology_runtime.cpp:4660-4662), and a card whose level carries a non-program
##     Modifier row emits that row into a legacy Effect batch which a headless
##     fixture cannot always ACK. With the tables empty the guard is skipped (it is
##     synergy-specific by construction) and every equip below is deterministic.
func _relax_catalog(native: Dictionary) -> void:
	var count := (native.get("ideology_ids", PackedStringArray()) as PackedStringArray).size()
	for pair in [
			["technology_requirement_offsets", "technology_requirements"],
			["signal_requirement_offsets", "signal_requirements"],
			["gate_requirement_offsets", "gate_requirements"]]:
		var offsets := PackedInt32Array()
		offsets.resize(count + 1)
		offsets.fill(0)
		native[pair[0]] = offsets
		native[pair[1]] = PackedInt32Array()
	native["ideology_capacity"] = 6
	native["ideology_capacity_max"] = 6
	var adopt := PackedInt32Array()
	adopt.resize(count)
	adopt.fill(-65536)
	native["adopt_thresholds_q16"] = adopt
	var per_idea_zero := PackedInt32Array()
	per_idea_zero.resize(count + 1)
	per_idea_zero.fill(0)
	native["ideology_synergy_offsets"] = per_idea_zero
	native["ideology_synergy_ids"] = PackedInt32Array()
	native["synergy_ids"] = PackedStringArray()
	native["synergy_min_counts"] = PackedInt32Array()
	native["synergy_requirement_offsets"] = PackedInt32Array([0])
	native["synergy_requirement_ideology_ids"] = PackedInt32Array()
	native["synergy_requirement_min_levels"] = PackedInt32Array()
	native["synergy_requirement_location_masks"] = PackedByteArray()
	native["synergy_effect_offsets"] = PackedInt32Array([0])
	for key in ["synergy_effect_actions", "synergy_effect_domains",
			"synergy_effect_opcodes", "synergy_effect_duration_days",
			"synergy_effect_stacks"]:
		native[key] = PackedInt32Array()
	for key in ["synergy_effect_values_q16", "synergy_effect_payload_i0",
			"synergy_effect_payload_i1", "synergy_effect_payload_i2",
			"synergy_effect_payload_i3"]:
		native[key] = PackedInt64Array()
	for key in ["synergy_effect_command_keys", "synergy_effect_definition_keys"]:
		native[key] = PackedStringArray()
	native["synergy_override_offsets"] = PackedInt32Array([0])
	native["synergy_override_programs"] = PackedStringArray()
	for key in ["synergy_override_scales", "synergy_override_match_kinds",
			"synergy_override_fields", "synergy_override_values"]:
		native[key] = PackedInt32Array()
	for key in ["synergy_override_match_values", "synergy_override_tag_names"]:
		native[key] = PackedStringArray()


func _install_satisfiable_tag(domain: Resource) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population", "op": 0,
		"threshold_q16": 30 * Q16_ONE, "clause": 0,
	}]
	var tag := {"name": "cell.settlement", "rows": rows}
	var tags: Array[Dictionary] = domain.target_tags.duplicate()
	for i in range(tags.size()):
		if String(tags[i].get("name", "")) == "cell.settlement":
			tags[i] = tag
			domain.target_tags = tags
			return
	tags.append(tag)
	domain.target_tags = tags


# -- misc -----------------------------------------------------------------

func _is_close(a: float, b: float, tolerance: float = 1e-9) -> bool:
	return absf(a - b) <= tolerance


func _fill_environment(ext: Object) -> void:
	# The 10 environment slots `capture_environment` requires (M3-19).
	var f32_slots := ["cell_temp", "cell_temp_30d", "cell_moisture",
		"cell_plant_available_water", "cell_weather_precip", "cell_snow_cover",
		"cell_weather_intensity", "cell_temp_365d"]
	var u8_slots := ["cell_weather_type", "cell_cover"]
	var zeros_f := PackedFloat32Array()
	zeros_f.resize(CELLS)
	var zeros_u := PackedByteArray()
	zeros_u.resize(CELLS)
	for n in f32_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 0, 1, false))
		if sid >= 0:
			ext.write_f32_range(sid, 0, zeros_f)
	for n in u8_slots:
		var sid := int(ext.component_id(n))
		if sid < 0:
			sid = int(ext.register_component(n, 2, 1, false))
		if sid >= 0:
			ext.write_u8_range(sid, 0, zeros_u)


func _u8_zero(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	return out


func _finish(code: int) -> void:
	print("=== derived copier scale: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
