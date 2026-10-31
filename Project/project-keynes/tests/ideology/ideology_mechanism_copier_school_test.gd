extends SceneTree
## Plan Section 18.1 evidence for two mechanisms that had none: **copier** (copy) and
## **school (school-of-thought)**.
##
## ---------------------------------------------------------------------------
## COPIER (`copy_left_programs`)
## ---------------------------------------------------------------------------
## A card whose definition carries `copy_left_programs` must use the programs of
## the idea in its LEFT slot instead of its own list. The whole rule lives in
## three places:
##
##   * `copy_source_state()`  (ideology_runtime.cpp:1760-1781) -- finds the card in
##     the slot to the left. It refuses when the card has no left slot
##     (`slot_index == 0`, :1769) or when it is the only card in its location;
##   * `copy_source_programs()` (:1783-1808) -- returns the SOURCE's level
##     `persistent_effects`, and returns an EMPTY list when the source is
##     noncopyable (`definition.copyable == 0`, :1800);
##   * `collect_effect_activations()` (:2290-2293) -- "A copier never falls back to
##     its own managed list. No left slot (or a noncopyable source) means it has
##     no managed activations."
##
## The fixture therefore asserts the three observable consequences, not the code:
##
##   P1  a copyable source alone paints its program on every owned cell;
##   P2  adding the copier to the right of it paints the SOURCE's program a SECOND
##       time (the derived add doubles exactly) -- the copier copied the source;
##   P3  the same copier with NO left slot contributes nothing at all: the derived
##       front is not even installed (this is the "never falls back to its own
##       list" half, and the interesting one);
##   P4/P5  the same source with `copyable` cleared leaves the copier with nothing
##       to copy -- the front stays exactly at the P1 size instead of doubling.
##
## P4/P5 differs from P1/P2 by ONE catalog byte (`ideology_copyable`), so the
## pair isolates `copy_source_programs`' :1800 branch rather than proving
## "something happened".
##
## Expected values are computed from the catalogue, never from a `> 0`:
## `public_hygiene_l1` is `CONST 3277 -> EMIT` (default_ideology_effects.tres),
## so the exact derived add is 3277 / 65536 on `economy.city.birth_factor`.
##
## ---------------------------------------------------------------------------
## SCHOOL (school strength factor)
## ---------------------------------------------------------------------------
## Six schools are declared in catalog order (`ideology_school_keys`); each has a
## strength stat (`school_strength_factor_stat_keys`, ideology_runtime.cpp:215-216).
## A card's program magnitude is multiplied by its OWN school's factor:
##
##   ideology_runtime.cpp:2545-2552
##       const int32_t school_index = definition.school_index;
##       if (!program_writes_school_strength(program, school_index))
##           activation_scale_q16 = activation_scale_q16 *
##               school_strength_scale_q16(country, school_index) / Q16_ONE;
##       activation_scale_q16 = clamp(activation_scale_q16, Q16/4, 4*Q16);
##
## and `school_strength_scale_q16()` (:3948-3989) reads the country's Modifier
## bucket for that school's stat and clamps it to [0.5, 2.0].
##
## TWO THINGS A READER MUST KNOW, both measured here:
##
##   1. the scale is applied on BOTH backends now, and that is recent. The
##      instance (LEGACY) branch multiplies `activation_scale_q16` at
##      :2610-2615. The DerivedCell branch multiplies each
##      `DerivedProgramContribution::magnitude_scale` at :2414-2443, behind the
##      SAME `program_writes_school_strength` guard. Before that second site
##      landed, a school's strength moved its country-domain cards and silently
##      did nothing for its kind-12 cell cards -- the majority of the catalog.
##      Phases E/F measure the INSTANCE path (`get_ideology_effect_instance_report`
##      -> `magnitude_scales`); phases G/H measure the DERIVED path
##      (`get_effective_stat_value` -> `derived_add`). Neither measures code.
##   2. no shipped card writes a school-strength stat -- the only definition in
##      `default_modifier_catalog.tres` that targets one is the harmony template
##      (`ideology.country.ideology.school_strength_factor.harmony`, :6389/6395),
##      and no ideology program references it. So `program_writes_school_strength`
##      cannot be tripped by shipped content, and phase G does NOT synthesise a
##      card to trip it: it MEASURES that zero and says so, so the day content
##      starts writing the stat the fixture reports it instead of lying.
##      The factor is a Modifier input, so the fixture SUPPLIES it through
##      `submit_modifier_commands` with the same shape the runtime itself uses
##      (domain=COUNTRY, scope=ENTITY, value 2.0).
##
## A multiplier term is interpolated, not applied raw (`modifier_runtime.cpp:775-781`):
##      factor = 1 + (term.factor - 1) * magnitude
## so a magnitude of 0.25 on the value-2.0 term yields exactly 1.25.
##
## The fixture then asserts:
##   S1  a Mobilization card starts at scale 1.00;
##   S2  raising the Mobilization factor to 1.25 scales THAT card to exactly 1.25;
##   S3  raising the Commerce factor to 1.50 does NOT change the Mobilization card
##       (the discriminating half -- a card only reads its own school);
##   S4  a Commerce card is unaffected by the Mobilization factor;
##   S5  and reaches exactly 1.50 from its own school's factor;
##   S6  the kind-12 `idea.public_hygiene` derived add is exactly 3277/Q16;
##   S7  driving THAT card's own school to 1.25 scales the derived add by exactly
##       1.25 (A1 == A0 * 1.25, tolerance 1e-9);
##   S8  A1 != A0, and the front was actually REINSTALLED (`layer_generation`
##       rose), so S7 cannot pass on a stale front;
##   S9  driving ANOTHER school to 1.50 leaves the derived add untouched -- and in
##       a world where the card's own factor never moved, the derived add is still
##       exactly A0;
##   S10 no shipped program trips the self-reference guard (measured, not claimed).
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_mechanism_copier_school_test.gd

const WIDTH := 5
const HEIGHT := 5
const CELLS: int = WIDTH * HEIGHT
## A cell asserted throughout. Any owned cell behaves the same; 3 keeps the number
## away from cell 0, which has its own guard history in `effective_value`.
const PROBE_CELL := 3

## The ONLY card in content with `copy_left_programs = true`
## (default_ideology_catalog.tres:14138, `idea.algorithmic_governance`, school
## `learning`, era 10). Found with:
##   Select-String -Path data/ideologies/default_ideology_catalog.tres \
##     -Pattern 'copy_left_programs'
const COPIER := "idea.algorithmic_governance"
## Kind-12 permanent card whose L1 program is `public_hygiene_l1` =
## `CONST 3277 -> EMIT 0` / `CONST 5243 -> EMIT 1` (two commands).
const SOURCE := "idea.public_hygiene"
const SOURCE_STAT := "economy.city.birth_factor"
const SOURCE_MAGNITUDE_Q16 := 3277
## `slot_index` the source occupies first, then the copier's (0 then 1).
const SOURCE_SLOT := 0
const COPIER_SLOT := 1

## Instance-path cards for the school phase. A program stays on the instance
## backend when `decide_cell_program_backend()` cannot express it
## (cell_program_eligibility.h:109-186); `target_domain != 2` is the first exit
## (:114). `treasury_reserve_l1_*` and `family_office_l1` both carry
## `target_domain = 3`, so they keep `magnitude_scale_q16` -- the only column the
## school factor is visible in.
const MOB_CARD := "idea.treasury_reserve"
const MOB_STAT := "country.ideology.school_strength_factor.mobilization"
const COM_CARD := "idea.family_office"
const COM_STAT := "country.ideology.school_strength_factor.commerce"
const SCHOOL_DEF_PREFIX := "test.school_strength."

## Phase G/H: the school the DERIVED card (`idea.public_hygiene`, the same kind-12
## card phase A uses) is authored in, and the school used as the discriminating
## control. Both are read back from the compiled catalog rather than trusted from
## these constants -- the constants exist so a content change shows up as a named
## failure instead of a silent swap. `school_id = "mobilization"` is authored at
## `default_ideology_catalog.tres:5400`.
const DERIVED_OWN_SCHOOL := "mobilization"
const DERIVED_OTHER_SCHOOL := "commerce"

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")
const ModifierDefinitionScript = preload("res://scripts/modifier/modifier_definition.gd")
const ModifierTermScript = preload("res://scripts/modifier/modifier_term.gd")

const Q16_ONE := 65536
## `Q16_ONE / 4` on the value-2.0 school term -> exactly 1.25.
const FACTOR_LOW := 16384
## `Q16_ONE / 2` -> exactly 1.50.
const FACTOR_HIGH := 32768

var _checks := 0
var _failures := 0
var _seq := 0
var _day := 0


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
	# -- shared catalogs --------------------------------------------------
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	# `cell.settlement` (the kind-12 tag every card carries) is re-declared as a
	# population threshold, because a bootstrapped economy has population but no
	# buildings -- see ideology_b7_wide_territory_test.gd:_install_satisfiable_tag.
	# Kept as a variable (not inlined) because phase G walks it: the self-reference
	# guard `program_writes_school_strength` is defined over program -> command ->
	# modifier-definition -> term, so measuring whether shipped content can reach it
	# needs both authored resources, not the compiled IR.
	var effect_catalog: Resource = IdeologyEffectCatalogScript.load_default()
	var domain: Resource = EffectDomainCatalogScript.build(null, effect_catalog)
	_install_satisfiable_tag(domain)

	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_catalog: Resource = ModifierCatalogScript.load_default()
	# Two school-strength definitions, one per school the fixture exercises. No
	# shipped definition writes anything but harmony, so without these the factor
	# could not be raised at all (see the header).
	_add_school_definition(mod_catalog, "mobilization", MOB_STAT)
	_add_school_definition(mod_catalog, "commerce", COM_STAT)
	var mod_ir: Dictionary = mod_catalog.compile_native_catalog()
	_expect("the modifier catalog compiles with the two test school terms",
		bool(mod_ir.get("ok", false)), str(mod_ir.get("reason", "")))
	mod_ir.erase("ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	native.erase("ok")
	_relax_catalog(native)
	var ids: PackedStringArray = native.get("ideology_ids", PackedStringArray())
	var copier_dense := ids.find(COPIER)
	var source_dense := ids.find(SOURCE)
	_expect("the copier card is in the compiled catalog", copier_dense >= 0,
		str(copier_dense))
	_expect("the source card is in the compiled catalog", source_dense >= 0,
		str(source_dense))
	if copier_dense < 0 or source_dense < 0:
		_finish(1)
		return
	var copy_flags: PackedByteArray = native.get(
		"ideology_copy_left_programs", PackedByteArray())
	var copyable: PackedByteArray = native.get("ideology_copyable", PackedByteArray())
	_expect("exactly one card in content is a copier",
		_count_set(copy_flags) == 1, str(_count_set(copy_flags)))
	_expect("the copier is the card the fixture names",
		int(copy_flags[copier_dense]) == 1, str(copy_flags[copier_dense]))
	_expect("the copier is not itself copyable",
		int(copyable[copier_dense]) == 0, str(copyable[copier_dense]))
	_expect("the source card IS copyable", int(copyable[source_dense]) == 1,
		str(copyable[source_dense]))

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE A/B: copier with a copyable source in its LEFT slot ===")
	# ---------------------------------------------------------------------
	var expect_alone := float(SOURCE_MAGNITUDE_Q16) / float(Q16_ONE)
	var ext_a := _build_world(country_ir, profile, effect_ir, mod_ir, native, "copy")
	var handle_a := _handle(ext_a)
	_equip(ext_a, ids, SOURCE)
	_expect("A: the source alone occupies slot 0",
		_slot_of(ext_a, handle_a, source_dense) == SOURCE_SLOT,
		_slots(ext_a, handle_a))
	var alone: Dictionary = _derived_probe(ext_a)
	var front_alone: Dictionary = ext_a.get_derived_cell_layer_report()
	print("[A] source alone      value=%.10f derived_add=%.10f contributors=%s"
		% [float(alone.get("value", -1.0)), float(alone.get("derived_add", -1.0)),
			str(alone.get("derived_contributors", "?"))])
	print("[A] front alone       contributions=%s cells=%s stats=%s"
		% [str(front_alone.get("contribution_count", "?")),
			str(front_alone.get("cell_count", "?")),
			str(front_alone.get("stat_count", "?"))])
	_expect("A: the source's program is a derived row on the probed cell",
		bool(alone.get("derived_present", false)), str(alone))
	_expect("A: the source alone contributes exactly 3277/Q16 (0.0500030517)",
		_is_close(float(alone.get("derived_add", -1.0)), expect_alone),
		"actual=%.10f expected=%.10f"
			% [float(alone.get("derived_add", -1.0)), expect_alone])
	_expect("A: exactly one contributor paints the cell",
		int(alone.get("derived_contributors", -1)) == 1,
		str(alone.get("derived_contributors", "?")))
	var contribs_alone := int(front_alone.get("contribution_count", -1))
	_expect("A: the front is 2 stats x 25 cells", contribs_alone == 50,
		str(contribs_alone))

	_equip(ext_a, ids, COPIER)
	_expect("B: the copier lands in slot 1, to the RIGHT of the source",
		_slot_of(ext_a, handle_a, copier_dense) == COPIER_SLOT,
		_slots(ext_a, handle_a))
	_expect("B: the copier is ACTIVE (location 1), not merely known",
		_location_of(ext_a, handle_a, copier_dense) == 1,
		_locations(ext_a, handle_a))
	var both: Dictionary = _derived_probe(ext_a)
	var front_both: Dictionary = ext_a.get_derived_cell_layer_report()
	print("[B] source + copier   value=%.10f derived_add=%.10f contributors=%s"
		% [float(both.get("value", -1.0)), float(both.get("derived_add", -1.0)),
			str(both.get("derived_contributors", "?"))])
	print("[B] front now         contributions=%s cells=%s stats=%s"
		% [str(front_both.get("contribution_count", "?")),
			str(front_both.get("cell_count", "?")),
			str(front_both.get("stat_count", "?"))])
	print("[B] expected          derived_add=%.10f (2 x %.10f)"
		% [2.0 * expect_alone, expect_alone])
	# The copier copies the source's LEVEL program list verbatim, so the derived
	# add must be the source's contribution counted TWICE -- not merely non-zero.
	_expect("B: the copier reproduces the source's program exactly (add doubles)",
		_is_close(float(both.get("derived_add", -1.0)), 2.0 * expect_alone),
		"actual=%.10f expected=%.10f"
			% [float(both.get("derived_add", -1.0)), 2.0 * expect_alone])
	_expect("B: the merged value is 1 + 2 x 3277/Q16",
		_is_close(float(both.get("value", -1.0)), 1.0 + 2.0 * expect_alone),
		"actual=%.10f expected=%.10f"
			% [float(both.get("value", -1.0)), 1.0 + 2.0 * expect_alone])
	_expect("B: the copier's contribution is the SOURCE's stat, not its own",
		int(front_both.get("stat_count", -1)) == int(front_alone.get("stat_count", -2)),
		"before=%s after=%s" % [str(front_alone.get("stat_count", "?")),
			str(front_both.get("stat_count", "?"))])
	# The front holds ONE `DerivedCellContribution` per (stat, cell) and folds every
	# contributing program into that row's `sum_add`, so a copy does NOT add rows --
	# it adds to the row. That is why the row count has to stay put while the add
	# doubles: asserting "the front doubles" would be asserting the wrong structure.
	_expect("B: the front keeps one row per (stat, cell); the copy folds into it",
		int(front_both.get("contribution_count", -1)) == contribs_alone,
		"before=%d after=%s" % [contribs_alone,
			str(front_both.get("contribution_count", "?"))])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE C: the copier with NO left slot contributes nothing ===")
	# ---------------------------------------------------------------------
	var ext_c := _build_world(country_ir, profile, effect_ir, mod_ir, native, "noleft")
	var handle_c := _handle(ext_c)
	_equip(ext_c, ids, COPIER)
	_expect("C: the copier is ACTIVE in slot 0",
		_location_of(ext_c, handle_c, copier_dense) == 1 and
			_slot_of(ext_c, handle_c, copier_dense) == 0,
		"%s %s" % [_locations(ext_c, handle_c), _slots(ext_c, handle_c)])
	var solo: Dictionary = _derived_probe(ext_c)
	var front_solo: Dictionary = ext_c.get_derived_cell_layer_report()
	var inst_c: Dictionary = ext_c.get_ideology_effect_instance_report(handle_c)
	print("[C] copier alone      value=%.10f derived_present=%s"
		% [float(solo.get("value", -1.0)), str(solo.get("derived_present", "?"))])
	print("[C] front             installed=%s cells=%s contributions=%s"
		% [str(front_solo.get("installed", "?")),
			str(front_solo.get("cell_count", "?")),
			str(front_solo.get("contribution_count", "?"))])
	print("[C] instances         count=%s" % str(inst_c.get("count", "?")))
	_expect("C: NO left slot means NO derived row at all",
		not bool(solo.get("derived_present", true)), str(solo))
	_expect("C: the merged value is the untouched base",
		_is_close(float(solo.get("value", -1.0)), 1.0),
		str(solo.get("value", "?")))
	_expect("C: the derived front is not even installed",
		not bool(front_solo.get("installed", true)),
		str(front_solo.get("installed", "?")))
	# `get_derived_cell_layer_report` omits `contribution_count` entirely when no
	# front is installed, so the count that is always present is `cell_count`.
	_expect("C: zero derived coverage", int(front_solo.get("cell_count", -1)) == 0,
		str(front_solo.get("cell_count", "?")))
	_expect("C: zero managed instances",
		int(inst_c.get("count", -1)) == 0, str(inst_c.get("count", "?")))
	# The negative is only meaningful because the SAME copier does contribute in
	# phase B; assert that explicitly so a fixture that silently broke equip in
	# BOTH worlds cannot pass.
	_expect("C: the phase-B copier DID contribute (the negative is not vacuous)",
		int(front_both.get("contribution_count", 0)) > 0,
		str(front_both.get("contribution_count", "?")))

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE D: a NONCOPYABLE source gives the copier nothing ===")
	# ---------------------------------------------------------------------
	# One byte differs from phase A: `ideology_copyable[source] = 0`, which is the
	# exact flag `copy_source_programs()` tests at ideology_runtime.cpp:1800.
	var native_nc: Dictionary = native.duplicate(true)
	var nc_flags: PackedByteArray = (native_nc.get(
		"ideology_copyable", PackedByteArray()) as PackedByteArray).duplicate()
	nc_flags[source_dense] = 0
	native_nc["ideology_copyable"] = nc_flags
	var ext_d := _build_world(country_ir, profile, effect_ir, mod_ir, native_nc, "noncopy")
	var handle_d := _handle(ext_d)
	_equip(ext_d, ids, SOURCE)
	var d_alone: Dictionary = _derived_probe(ext_d)
	var d_front_alone: Dictionary = ext_d.get_derived_cell_layer_report()
	print("[D] noncopyable alone value=%.10f derived_add=%.10f contributors=%s"
		% [float(d_alone.get("value", -1.0)), float(d_alone.get("derived_add", -1.0)),
			str(d_alone.get("derived_contributors", "?"))])
	_expect("D: clearing `copyable` does not change what the source itself does",
		_is_close(float(d_alone.get("derived_add", -1.0)), expect_alone),
		"actual=%.10f expected=%.10f"
			% [float(d_alone.get("derived_add", -1.0)), expect_alone])
	_equip(ext_d, ids, COPIER)
	_expect("D: the copier is ACTIVE in slot 1",
		_location_of(ext_d, handle_d, copier_dense) == 1 and
			_slot_of(ext_d, handle_d, copier_dense) == COPIER_SLOT,
		"%s %s" % [_locations(ext_d, handle_d), _slots(ext_d, handle_d)])
	var d_both: Dictionary = _derived_probe(ext_d)
	var d_front_both: Dictionary = ext_d.get_derived_cell_layer_report()
	print("[D] + copier          value=%.10f derived_add=%.10f contributors=%s"
		% [float(d_both.get("value", -1.0)), float(d_both.get("derived_add", -1.0)),
			str(d_both.get("derived_contributors", "?"))])
	print("[D] front             before=%s after=%s"
		% [str(d_front_alone.get("contribution_count", "?")),
			str(d_front_both.get("contribution_count", "?"))])
	_expect("D: a noncopyable source leaves the copier with nothing to copy",
		_is_close(float(d_both.get("derived_add", -1.0)), expect_alone),
		"actual=%.10f expected=%.10f (the phase-B value would be %.10f)"
			% [float(d_both.get("derived_add", -1.0)), expect_alone,
				2.0 * expect_alone])
	_expect("D: the merged value is 1 + 3277/Q16, NOT the phase-B double",
		_is_close(float(d_both.get("value", -1.0)), 1.0 + expect_alone),
		"actual=%.10f expected=%.10f"
			% [float(d_both.get("value", -1.0)), 1.0 + expect_alone])
	_expect("D: the front does NOT grow (it did in phase B)",
		int(d_front_both.get("contribution_count", -1)) ==
			int(d_front_alone.get("contribution_count", -2)),
		"before=%s after=%s" % [str(d_front_alone.get("contribution_count", "?")),
			str(d_front_both.get("contribution_count", "?"))])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE E: the school strength factor on a Mobilization card ===")
	# ---------------------------------------------------------------------
	var mob_dense := ids.find(MOB_CARD)
	var com_dense := ids.find(COM_CARD)
	_expect("E: the Mobilization card is in the catalog", mob_dense >= 0, str(mob_dense))
	_expect("E: the Commerce card is in the catalog", com_dense >= 0, str(com_dense))
	var schools: PackedInt32Array = native.get(
		"ideology_school_indices", PackedInt32Array())
	var school_keys: PackedStringArray = native.get(
		"ideology_school_keys", PackedStringArray())
	print("[E] school order      %s" % str(school_keys))
	_expect("E: the fixture's two cards really sit in DIFFERENT schools",
		int(schools[mob_dense]) != int(schools[com_dense]),
		"mob=%d com=%d" % [int(schools[mob_dense]), int(schools[com_dense])])
	_expect("E: the Mobilization card's school is `mobilization`",
		String(school_keys[int(schools[mob_dense])]) == "mobilization",
		String(school_keys[int(schools[mob_dense])]))

	var ext_e := _build_world(country_ir, profile, effect_ir, mod_ir, native, "mob")
	var handle_e := _handle(ext_e)
	_equip(ext_e, ids, MOB_CARD)
	var mob_scale0 := _instance_scale(ext_e, handle_e, mob_dense)
	print("[E] baseline          mob scale=%.6f factor=%.6f"
		% [mob_scale0, _school_factor(ext_e, handle_e, MOB_STAT)])
	_expect("E: instances exist for the Mobilization card (so the column is real)",
		_instance_count(ext_e, handle_e) > 0,
		str(_instance_count(ext_e, handle_e)))
	_expect("E: with no school term the scale is exactly 1.00",
		_is_close(mob_scale0, 1.0), "%.6f" % mob_scale0)

	_inject_school_term(ext_e, handle_e, "mobilization", FACTOR_LOW)
	var mob_factor := _school_factor(ext_e, handle_e, MOB_STAT)
	print("[E] after mob 1.25    mob factor=%.6f" % mob_factor)
	_expect("E: the Mobilization school factor reads exactly 1.25",
		_is_close(mob_factor, 1.25, 0.000001), "%.8f" % mob_factor)
	_reconcile(ext_e, ids, MOB_CARD)
	var mob_scale1 := _instance_scale(ext_e, handle_e, mob_dense)
	print("[E] mob scale         %.6f (expected 1.25)" % mob_scale1)
	_expect("E: the Mobilization card's scale becomes exactly 1.25",
		_is_close(mob_scale1, 1.25, 0.000001), "%.8f" % mob_scale1)

	# -- the discriminating half: ANOTHER school's factor is not this card's --
	_inject_school_term(ext_e, handle_e, "commerce", FACTOR_HIGH)
	var com_factor_e := _school_factor(ext_e, handle_e, COM_STAT)
	print("[E] after com 1.50    com factor=%.6f  mob factor=%.6f"
		% [com_factor_e, _school_factor(ext_e, handle_e, MOB_STAT)])
	_expect("E: the Commerce factor really rose to 1.50 (the control is live)",
		_is_close(com_factor_e, 1.5, 0.000001), "%.8f" % com_factor_e)
	_reconcile(ext_e, ids, MOB_CARD)
	var mob_scale2 := _instance_scale(ext_e, handle_e, mob_dense)
	print("[E] mob scale         %.6f (must stay 1.25)" % mob_scale2)
	_expect("E: a Commerce factor does NOT touch the Mobilization card",
		_is_close(mob_scale2, 1.25, 0.000001), "%.8f" % mob_scale2)

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE F: the same two factors on a Commerce card ===")
	# ---------------------------------------------------------------------
	var ext_f := _build_world(country_ir, profile, effect_ir, mod_ir, native, "com")
	var handle_f := _handle(ext_f)
	_equip(ext_f, ids, COM_CARD)
	var com_scale0 := _instance_scale(ext_f, handle_f, com_dense)
	print("[F] baseline          com scale=%.6f" % com_scale0)
	_expect("F: the Commerce card starts at scale 1.00",
		_is_close(com_scale0, 1.0), "%.6f" % com_scale0)
	_inject_school_term(ext_f, handle_f, "mobilization", FACTOR_LOW)
	_reconcile(ext_f, ids, COM_CARD)
	var com_scale1 := _instance_scale(ext_f, handle_f, com_dense)
	print("[F] after mob 1.25    com scale=%.6f (must stay 1.00)" % com_scale1)
	_expect("F: a Mobilization factor does NOT touch the Commerce card",
		_is_close(com_scale1, 1.0, 0.000001), "%.8f" % com_scale1)
	_inject_school_term(ext_f, handle_f, "commerce", FACTOR_HIGH)
	var com_factor_f := _school_factor(ext_f, handle_f, COM_STAT)
	_reconcile(ext_f, ids, COM_CARD)
	var com_scale2 := _instance_scale(ext_f, handle_f, com_dense)
	print("[F] after com 1.50    factor=%.6f com scale=%.6f (expected 1.50)"
		% [com_factor_f, com_scale2])
	_expect("F: the Commerce school factor reads exactly 1.50",
		_is_close(com_factor_f, 1.5, 0.000001), "%.8f" % com_factor_f)
	_expect("F: the Commerce card's scale becomes exactly 1.50",
		_is_close(com_scale2, 1.5, 0.000001), "%.8f" % com_scale2)

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE G: the school factor reaches the DERIVED backend ===")
	# ---------------------------------------------------------------------
	# Everything above reads `_instance_scale`, i.e. the LEGACY branch
	# (ideology_runtime.cpp:2607-2617). That branch has always multiplied by
	# `school_strength_scale_q16`; the DERIVED branch (:2399-2455) used to skip it,
	# so a kind-12 card -- 2 of the 3 selector kinds and most of the catalog --
	# ignored its own school. It now scales each
	# `DerivedProgramContribution::magnitude_scale` by the same factor, behind the
	# same self-reference guard (:2414-2443).
	#
	# So this phase re-measures the card phase A already proved reaches the derived
	# layer (`idea.public_hygiene`: kind-12, L1 = CONST 3277 -> EMIT, so the exact
	# derived add is 3277/Q16), through the same reader phase A used
	# (`get_effective_stat_value` -> `derived_add`), and moves ONLY the school
	# strength. If A1 is not A0 * 1.25 the derived path still refuses the factor --
	# that would be a finding, and the assertion below is written to fail on it, not
	# to hide it.
	var school_stats: PackedStringArray = native.get(
		"school_strength_factor_stat_keys", PackedStringArray())
	_expect("G: the compiled catalog carries one strength stat per school",
		school_stats.size() == school_keys.size(),
		"%d stats / %d schools" % [school_stats.size(), school_keys.size()])
	var hyg_school := int(schools[source_dense])
	_expect("G: the derived card has an in-range school index",
		hyg_school >= 0 and hyg_school < school_keys.size(), str(hyg_school))
	if school_stats.size() != school_keys.size() or hyg_school < 0 \
			or hyg_school >= school_keys.size():
		_finish(4)
		return
	var hyg_school_name := String(school_keys[hyg_school])
	# `_school_strength_factor_stat_keys` is parallel to `_school_keys`
	# (ideology_runtime.cpp:211-216, 4004-4005), so this is the stat
	# `school_strength_scale_q16` will read for THIS card -- not a constant the
	# fixture hopes matches.
	var hyg_stat := String(school_stats[hyg_school])
	print("[G] derived card      %s  school=%s  stat=%s"
		% [SOURCE, hyg_school_name, hyg_stat])
	_expect("G: the derived card is authored in the `%s` school"
		% DERIVED_OWN_SCHOOL, hyg_school_name == DERIVED_OWN_SCHOOL, hyg_school_name)
	_expect("G: the card's own school strength stat is `%s`" % MOB_STAT,
		hyg_stat == MOB_STAT, hyg_stat)
	_expect("G: the control school `%s` is NOT the card's own school"
		% DERIVED_OTHER_SCHOOL, hyg_school_name != DERIVED_OTHER_SCHOOL,
		hyg_school_name)

	# `program_writes_school_strength` (:3996-4020) resolves a program's commands to
	# Modifier definitions and looks for a term on the CARD'S OWN school stat.
	# MEASURED, not assumed: no shipped ideology program references a definition
	# carrying such a term (the only one is the harmony template,
	# default_modifier_catalog.tres:6389, and default_ideology_effects.tres names it
	# nowhere). The guard's "do not scale" half is therefore unreachable from
	# content, so it is NOT synthesised here -- the fixture measures the zero and
	# will report the day content starts writing the stat.
	var guard_programs := _count_school_strength_programs(
		effect_catalog, mod_catalog, school_stats)
	print("[G] shipped programs writing a school-strength stat = %d"
		% guard_programs)
	_expect("G: no shipped program writes a school-strength stat (guard unreachable)",
		guard_programs == 0, str(guard_programs))

	var ext_g := _build_world(country_ir, profile, effect_ir, mod_ir, native,
		"derived")
	var handle_g := _handle(ext_g)
	_equip(ext_g, ids, SOURCE)
	# `_equip` already spent the settle day AND the section 9.3 eligibility day, and
	# ended with `_drain(_day)`, so the front below is the one adopted for the
	# CURRENT day. Reading on the settle day itself would show `installed = false`.
	var front_g0: Dictionary = ext_g.get_derived_cell_layer_report()
	var g0: Dictionary = _derived_probe(ext_g)
	var a0 := float(g0.get("derived_add", -1.0))
	var gen0 := int(front_g0.get("layer_generation", -1))
	# `cell_layer_rebuild_visits` counts calls into `step_derived_rebuild`
	# (ideology_runtime.cpp:7095). It is the only observable that says "the
	# collector RAN on this day", which matters for the control below: when the
	# candidate is content-identical the front is deliberately not reinstalled
	# (plan I13), so the generation cannot move and would otherwise be ambiguous.
	var reb0 := _rebuild_visits(ext_g)
	print("[G] baseline          derived_add=%.10f value=%.10f contributors=%s"
		% [a0, float(g0.get("value", -1.0)),
			str(g0.get("derived_contributors", "?"))])
	var front_line := "[G] front             installed=%s contributions=%s cells=%s"
	front_line += " stats=%s gen=%d sample_day=%s rebuilds=%d"
	print(front_line % [str(front_g0.get("installed", "?")),
		str(front_g0.get("contribution_count", "?")),
		str(front_g0.get("cell_count", "?")),
		str(front_g0.get("stat_count", "?")), gen0,
		str(front_g0.get("sample_day", "?")), reb0])
	# Non-vacuity: the front must actually cover the 25 owned cells with two stats,
	# otherwise every ratio below is a comparison of two absences.
	_expect("G: the derived front is installed and covers 2 stats x 25 cells",
		bool(front_g0.get("installed", false))
			and int(front_g0.get("contribution_count", -1)) == 50
			and int(front_g0.get("cell_count", -1)) == 50,
		"installed=%s contributions=%s cells=%s"
			% [str(front_g0.get("installed", "?")),
				str(front_g0.get("contribution_count", "?")),
				str(front_g0.get("cell_count", "?"))])
	_expect("G: A0, the derived per-cell add, is the authored L1 add 3277/Q16",
		_is_close(a0, expect_alone),
		"actual=%.12f expected=%.12f" % [a0, expect_alone])
	_expect("G: exactly one contributor paints the probed cell",
		int(g0.get("derived_contributors", -1)) == 1,
		str(g0.get("derived_contributors", "?")))
	var hyg_factor_0 := _school_factor(ext_g, handle_g, hyg_stat)
	_expect("G: before any injection the card's own factor is exactly 1.00",
		_is_close(hyg_factor_0, 1.0, 0.000001), "%.8f" % hyg_factor_0)

	# -- own school to 1.25 -------------------------------------------------
	_inject_school_term(ext_g, handle_g, hyg_school_name, FACTOR_LOW)
	var hyg_factor_1 := _school_factor(ext_g, handle_g, hyg_stat)
	print("[G] after own 1.25    factor=%.8f" % hyg_factor_1)
	_expect("G: the card's own school factor reads exactly 1.25",
		_is_close(hyg_factor_1, 1.25, 0.000001), "%.8f" % hyg_factor_1)
	_reconcile(ext_g, ids, SOURCE)
	var front_g1: Dictionary = ext_g.get_derived_cell_layer_report()
	var g1: Dictionary = _derived_probe(ext_g)
	var a1 := float(g1.get("derived_add", -1.0))
	var gen1 := int(front_g1.get("layer_generation", -1))
	var reb1 := _rebuild_visits(ext_g)
	print("[G] after own 1.25    derived_add=%.12f expected=%.12f"
		% [a1, a0 * 1.25])
	print("[G] front             gen %d -> %d  rebuilds %d -> %d  sample_day=%s"
		% [gen0, gen1, reb0, reb1, str(front_g1.get("sample_day", "?"))])
	# `layer_generation` only moves when a candidate with DIFFERENT content is
	# installed (modifier_runtime.cpp:1693-1699), so this is the check that the
	# number below came from a rebuild rather than from an unchanged front.
	_expect("G: the front is REINSTALLED after the factor changes (gen %d -> %d)"
		% [gen0, gen1], gen1 > gen0, "%d -> %d" % [gen0, gen1])
	_expect("G: the collector ran on that day (rebuilds %d -> %d)"
		% [reb0, reb1], reb1 > reb0, "%d -> %d" % [reb0, reb1])
	_expect("G: the derived add scales by exactly 1.25 (A1 == A0 * 1.25)",
		_is_close(a1, a0 * 1.25),
		"actual=%.12f expected=%.12f (a0=%.12f, missed by %.12f)"
			% [a1, a0 * 1.25, a0, absf(a1 - a0 * 1.25)])
	_expect("G: A1 is not A0 (the 1.25 assertion is not vacuous)",
		not _is_close(a1, a0), "a0=%.12f a1=%.12f" % [a0, a1])
	_expect("G: the factor scaled the MAGNITUDE, not the contributor count",
		int(g1.get("derived_contributors", -1)) == 1,
		str(g1.get("derived_contributors", "?")))
	_expect("G: the merged stat value is 1 + A1 (the row really moved)",
		_is_close(float(g1.get("value", -1.0)), 1.0 + a1),
		"actual=%.12f expected=%.12f"
			% [float(g1.get("value", -1.0)), 1.0 + a1])

	# -- ANOTHER school to 1.50 --------------------------------------------
	_inject_school_term(ext_g, handle_g, DERIVED_OTHER_SCHOOL, FACTOR_HIGH)
	var com_factor_g := _school_factor(ext_g, handle_g, COM_STAT)
	var hyg_factor_2 := _school_factor(ext_g, handle_g, hyg_stat)
	print("[G] after other 1.50  com=%.8f own=%.8f"
		% [com_factor_g, hyg_factor_2])
	_expect("G: the control school's factor really rose to 1.50 (it is live)",
		_is_close(com_factor_g, 1.5, 0.000001), "%.8f" % com_factor_g)
	_expect("G: the card's own factor is still 1.25 (the control is additive)",
		_is_close(hyg_factor_2, 1.25, 0.000001), "%.8f" % hyg_factor_2)
	_reconcile(ext_g, ids, SOURCE)
	var front_g2: Dictionary = ext_g.get_derived_cell_layer_report()
	var g2: Dictionary = _derived_probe(ext_g)
	var a2 := float(g2.get("derived_add", -1.0))
	var gen2 := int(front_g2.get("layer_generation", -1))
	var reb2 := _rebuild_visits(ext_g)
	print("[G] after other 1.50  derived_add=%.12f (must stay A1=%.12f; A0=%.12f)"
		% [a2, a1, a0])
	print("[G] front             gen %d -> %d  rebuilds %d -> %d"
		% [gen1, gen2, reb1, reb2])
	# The own-school 1.25 term is still in the store, so "the other school did
	# nothing" means the add is UNCHANGED at A1 -- not that it fell back to A0. The
	# baseline form of the same claim is phase H, where the own factor never moved.
	#
	# Non-vacuity for "unchanged" needs BOTH halves: the collector ran (else nothing
	# was re-evaluated) AND its candidate was content-identical, so
	# `install_derived_cell_layer` took the plan-I13 skip and did NOT bump the
	# generation (modifier_runtime.cpp:1693-1698). A generation that had moved here
	# would mean the other school's factor DID reach this card.
	_expect("G: the collector ran again with the other school at 1.50 (rebuilds %d -> %d)"
		% [reb1, reb2], reb2 > reb1, "%d -> %d" % [reb1, reb2])
	var skip_label := "G: its candidate is content-identical, so the front is NOT "
	skip_label += "reinstalled (gen stays %d)" % gen1
	_expect(skip_label, gen2 == gen1, "%d -> %d" % [gen1, gen2])
	_expect("G: another school's factor does NOT touch this card's derived add",
		_is_close(a2, a1),
		"actual=%.12f expected=%.12f (unchanged); missed by %.12f"
			% [a2, a1, absf(a2 - a1)])
	_expect("G: and the own-school factor is still in force (A2 != A0)",
		not _is_close(a2, a0), "a0=%.12f a2=%.12f" % [a0, a2])
	_expect("G: A2 is exactly A0 * 1.25, not 1.50 or 1.875 stacked on top",
		_is_close(a2, a0 * 1.25),
		"actual=%.12f expected=%.12f" % [a2, a0 * 1.25])

	# -- REMOVE the own-school term: the derived add returns to A0 ----------
	# The literal form of the discriminating control. `COMMAND_REMOVE` (opcode 2) is
	# handle-addressed and ignores the definition key (modifier_runtime.cpp:1361-1365
	# -> `remove_handle`), so the handle comes from `list_modifiers`, which is how the
	# game itself addresses an applied modifier. The OTHER school stays at 1.50
	# throughout: with it live and the own factor back to 1.00, the derived add must
	# be exactly A0 again. That also proves the derived path tracks the factor DOWN,
	# not only up.
	var own_def := "%s%s" % [SCHOOL_DEF_PREFIX, hyg_school_name]
	var own_handle := _test_modifier_handle(ext_g, handle_g, hyg_stat, own_def)
	print("[G] own term handle   %d (%s)" % [own_handle, own_def])
	_expect("G: the own-school term is addressable in the COUNTRY store",
		own_handle != 0, str(own_handle))
	if own_handle != 0:
		_remove_school_term(ext_g, own_handle)
		var hyg_factor_3 := _school_factor(ext_g, handle_g, hyg_stat)
		_expect("G: the card's own factor is back to exactly 1.00",
			_is_close(hyg_factor_3, 1.0, 0.000001), "%.8f" % hyg_factor_3)
		_reconcile(ext_g, ids, SOURCE)
		var front_g3: Dictionary = ext_g.get_derived_cell_layer_report()
		var g3: Dictionary = _derived_probe(ext_g)
		var a3 := float(g3.get("derived_add", -1.0))
		var gen3 := int(front_g3.get("layer_generation", -1))
		var com_factor_3 := _school_factor(ext_g, handle_g, COM_STAT)
		var down_line := "[G] own term removed  derived_add=%.12f (A0=%.12f) "
		down_line += "com=%.8f gen %d -> %d"
		print(down_line % [a3, a0, com_factor_3, gen2, gen3])
		_expect("G: the control school is still at 1.50 (the control stays live)",
			_is_close(com_factor_3, 1.5, 0.000001), "%.8f" % com_factor_3)
		_expect("G: the front is reinstalled on the way DOWN too (gen %d -> %d)"
			% [gen2, gen3], gen3 > gen2, "%d -> %d" % [gen2, gen3])
		_expect("G: with only the OTHER school live, the derived add returns to A0",
			_is_close(a3, a0),
			"actual=%.12f expected=%.12f" % [a3, a0])
		_expect("G: and it is NOT the 1.25 value (the return is not a stale read)",
			not _is_close(a3, a1), "a1=%.12f a3=%.12f" % [a1, a3])
		# The whole point, as numbers rather than as verdicts: the exact miss
		# distances. All three are 0 when the derived path applies the factor, and a
		# reader can see that without trusting any boolean above.
		var miss_line := "[G] |A1 - A0*1.25| = %.17f  |A2 - A1| = %.17f  "
		miss_line += "|A3 - A0| = %.17f"
		print(miss_line % [absf(a1 - a0 * 1.25), absf(a2 - a1), absf(a3 - a0)])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE H: another school ALONE leaves the derived add at A0 ===")
	# ---------------------------------------------------------------------
	# Phase G's control runs with the card's own factor already at 1.25, so there
	# "the other school did nothing" reads as "unchanged at A1". The cleanest form
	# needs a world where the card's own factor has NEVER moved: drive only the
	# other school to 1.50 and the derived add must still be exactly A0. Without
	# this, a reader could argue phase G proved only that the two terms cancel.
	var ext_h := _build_world(country_ir, profile, effect_ir, mod_ir, native, "other")
	var handle_h := _handle(ext_h)
	_equip(ext_h, ids, SOURCE)
	var h0: Dictionary = _derived_probe(ext_h)
	var a0_other := float(h0.get("derived_add", -1.0))
	var h_front0: Dictionary = ext_h.get_derived_cell_layer_report()
	var h_gen0 := int(h_front0.get("layer_generation", -1))
	var h_reb0 := _rebuild_visits(ext_h)
	print("[H] baseline          derived_add=%.12f (A0 from G = %.12f) gen=%d"
		% [a0_other, a0, h_gen0])
	_expect("H: a second world reproduces A0 exactly (the baseline is deterministic)",
		_is_close(a0_other, a0), "a0=%.12f other=%.12f" % [a0, a0_other])
	_inject_school_term(ext_h, handle_h, DERIVED_OTHER_SCHOOL, FACTOR_HIGH)
	var com_factor_h := _school_factor(ext_h, handle_h, COM_STAT)
	var hyg_factor_h := _school_factor(ext_h, handle_h, hyg_stat)
	print("[H] after other 1.50  com=%.8f own=%.8f"
		% [com_factor_h, hyg_factor_h])
	_expect("H: the control school's factor reads exactly 1.50",
		_is_close(com_factor_h, 1.5, 0.000001), "%.8f" % com_factor_h)
	_expect("H: the card's own school factor never moved (still 1.00)",
		_is_close(hyg_factor_h, 1.0, 0.000001), "%.8f" % hyg_factor_h)
	_reconcile(ext_h, ids, SOURCE)
	var h1: Dictionary = _derived_probe(ext_h)
	var a1_other := float(h1.get("derived_add", -1.0))
	var h_front1: Dictionary = ext_h.get_derived_cell_layer_report()
	var h_gen1 := int(h_front1.get("layer_generation", -1))
	var h_reb1 := _rebuild_visits(ext_h)
	var h_line := "[H] after other 1.50  derived_add=%.12f (must stay A0=%.12f)"
	h_line += " gen %d -> %d rebuilds %d -> %d"
	print(h_line % [a1_other, a0, h_gen0, h_gen1, h_reb0, h_reb1])
	# Same pair as phase G's control: the collector ran (so the factor was
	# re-evaluated) and its candidate was content-identical (so nothing installed).
	_expect("H: the collector ran with the other school at 1.50 (rebuilds %d -> %d)"
		% [h_reb0, h_reb1], h_reb1 > h_reb0, "%d -> %d" % [h_reb0, h_reb1])
	_expect("H: its candidate is content-identical, so the front is NOT reinstalled",
		h_gen1 == h_gen0, "%d -> %d" % [h_gen0, h_gen1])
	_expect("H: with only the OTHER school driven, the derived add stays at A0",
		_is_close(a1_other, a0),
		"actual=%.12f expected=%.12f" % [a1_other, a0])
	# A zero here would satisfy the previous check for the wrong reason, so pin the
	# front as still live on the probed cell.
	_expect("H: the cell still carries the card's derived row (not a cleared front)",
		bool(h1.get("derived_present", false))
			and int(h1.get("derived_contributors", 0)) >= 1
			and not _is_close(a1_other, 0.0),
		"present=%s contributors=%s add=%.12f"
			% [str(h1.get("derived_present", "?")),
				str(h1.get("derived_contributors", "?")), a1_other])

	print("")
	_finish(0 if _failures == 0 else 3)


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
	_expect("%s: the country bootstraps" % tag, bool(boot.get("ok", false)), str(boot))
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
		_expect("%s: the economy bootstraps" % tag, bool(eb.get("ok", false)), str(eb))
		for s in range(512):
			if bool(ext.run_economy_slice(
					{"day_index": 0, "tick_index": s}).get("done", false)):
				break
	return ext


## Fixture knobs on the COMPILED catalogue (no file is touched):
##   * draw requirements are dropped -- `idea.algorithmic_governance` is era 10 and
##     wants `tech.cognitive_automation`, which this bootstrap does not have;
##   * slot capacity is raised so two cards fit;
##   * every card's ADOPT support threshold is floored, because support is derived
##     from the economy's per-class opinion and a 25-cell bootstrap does not carry
##     the classes the late cards are authored against (`support_gate`,
##     ideology_runtime.cpp:1308-1326);
##   * SYNERGIES are emptied. This one is not cosmetic -- see the note below.
##
## WHY THE SYNERGY TABLES MUST BE EMPTY
##
## `equip()` rejects the whole command while ANY transition is in flight:
##
##     if (country.pending_transition_count > 0 && !_synergies.empty()) {
##         error = "ideology_country_transition_pending"; return false;
##     }                                        // ideology_runtime.cpp:4550-4552
##
## and a transition only settles once every effect transaction it emitted is ACKed
## (`poll_pending_transition`, :3739-3751). A card whose level carries a persistent
## effect that is NOT a managed program emits that effect into a legacy batch
## (`emit_templates`, :1683-1694), and a headless fixture has no Effect runtime
## tick, so the transaction stays PENDING forever. Measured before this knob: the
## first EQUIP's receipt was `status 1 (PENDING)` with `pending_transitions: 1` and
## `pending_transition_visits: 37` after 24 further days, and the copier's equip was
## rejected `ideology_country_transition_pending` at :4550 -- so a two-card world
## could not be built at all. With `_synergies` empty the guard is skipped (it is
## synergy-specific by construction) and both cards equip.
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
	# -- synergies: none --------------------------------------------------
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


## Appends a school-strength definition to the loaded modifier catalogue.
## Term shape copied from the shipped harmony template
## (`default_modifier_catalog.tres:6387-6401`): operation MULTIPLY (2), value 2.0,
## so `factor = 1 + (2.0 - 1.0) * magnitude` (modifier_runtime.cpp:779).
func _add_school_definition(cat: Resource, tag: String, stat_key: String) -> void:
	var definition: Resource = ModifierDefinitionScript.new()
	definition.key = StringName("%s%s" % [SCHOOL_DEF_PREFIX, tag])
	definition.display_name = "test school strength %s" % tag
	definition.domain = 1
	definition.stack_policy = 1
	definition.default_duration_days = -1
	var term: Resource = ModifierTermScript.new()
	term.stat_key = StringName(stat_key)
	term.operation = 2
	term.value = 2.0
	var terms: Array[Resource] = [term]
	definition.terms = terms
	cat.definitions.append(definition)


## Counts the SHIPPED ideology programs that could trip
## `program_writes_school_strength` (ideology_runtime.cpp:3996-4020), i.e. that
## reference a Modifier definition carrying a term on one of this catalog's
## `country.ideology.school_strength_factor.*` stats.
##
## Why this is a CHECK and not a comment: the guard's whole job is "a card that
## writes its own school's strength must not then be scaled by it", and no shipped
## card does that -- so the branch is unreachable from content and cannot be
## exercised without inventing a card, which the fixture deliberately does not do.
## Measuring the zero keeps the claim honest today and turns red (with the count)
## the moment content writes the stat, at which point the scaling half of the guard
## needs its own case.
##
## The walk mirrors the C++: program -> commands -> `definition_key` -> terms ->
## `stat_key`. It OVER-approximates on purpose (`program_modifier_commands` filters
## on action/domain, this does not), so a zero here is a genuine zero.
func _count_school_strength_programs(effects: Resource, cat: Resource,
		stat_keys: PackedStringArray) -> int:
	if effects == null or cat == null or stat_keys.is_empty():
		return -1
	var guarded := {}
	for definition in cat.definitions:
		if definition == null:
			continue
		for term in definition.terms:
			if term == null:
				continue
			if stat_keys.find(String(term.stat_key)) >= 0:
				guarded[String(definition.key)] = true
				break
	var total := 0
	for effect in effects.effects:
		if effect == null:
			continue
		for command in effect.commands:
			if command == null:
				continue
			if guarded.has(String(command.definition_key)):
				total += 1
				break
	return total


# -- driving the ideology and modifier runtimes ---------------------------

## Advances the ideology runtime by one day AND drives the native Effect
## adapters, which is what the production daily graph does every day
## (`world_ext_bind_methods.cpp:633-638`):
##
##   run_ideology_daily(day)              poll (settles what is ACKed) -> rebuild
##   dispatch_effect_native_modifier()
##   run_modifier_daily(day)              MANDATORY between dispatch and ACK
##   ack_effect_native_modifier()
##
## The handshake is not cosmetic. An equip/level transition only becomes a
## CONTRIBUTION once its Effect batch is ACKed AND a later ideology day polls it
## (`poll_pending_transition`, ideology_runtime.cpp:3764-3846); until then
## `collect_effect_activations` contributes nothing at all (:2313-2321, plan
## 10.1). Without this the whole fixture measured a world whose cards were
## equipped but contributed zero rows -- every derived check read an empty front.
##
## The day index MUST increase: a transition only settles on a LATER day, and
## replaying day 0..n leaves `pending_transition_count > 0`.
func _day_step(ext: Object) -> void:
	_day += 1
	ext.run_ideology_daily(_day)
	_serve_native_adapters(ext, _day)


## The native Effect adapter pulse. Bounded: it stops as soon as the Modifier
## side reports no pending rows, which is the state the ideology poll needs to see.
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
		if int(acked.get("acknowledged", 0)) > 0 \
				and int(acked.get("pending", 0)) == 0:
			return
		if int(ext.get_ideology_report().get("pending_transitions", -1)) == 0:
			return


## grant points -> discover -> understanding -> equip, then wait for the
## transition to SETTLE and rebuild the derived front.
##
## Waiting matters: `equip()` refuses with `ideology_country_transition_pending`
## while any transition is in flight (ideology_runtime.cpp:4550-4552), and the
## refusal is a command RESULT, not a throw -- a fixture that does not check it
## silently measures a world where the second card never got equipped.
func _equip(ext: Object, ids: PackedStringArray, key: String) -> void:
	var dense := ids.find(key)
	if dense < 0:
		printerr("FAIL %s is absent from the compiled catalog" % key)
		_failures += 1
		return
	var handle := _handle(ext)
	var before := int(_snapshot(ext, handle).get(
		"ideology_slots_used", 0))
	_submit(ext, {"op": 2, "handle": handle, "idea": -1, "value": 64 * Q16_ONE})
	_submit(ext, {"op": 1, "handle": handle, "idea": dense})
	for i in range(0, 3):
		_day_step(ext)
	_submit(ext, {"op": 8, "handle": handle, "idea": dense, "value": 0})
	for i in range(0, 3):
		_day_step(ext)
	_submit(ext, {"op": 5, "handle": handle, "idea": dense})
	for i in range(0, 4):
		_day_step(ext)
	# Poll until the card is ACTIVE. A rejected equip never becomes active, so this
	# also bounds the damage: the caller's next assertion sees location 0.
	# NOTE what `location == 1` does and does NOT mean: `equip` writes it at REQUEST
	# time (`start_transition`, ideology_runtime.cpp:3631-3633), so being active is
	# necessary but NOT sufficient for a contribution -- see the settle loop below.
	var days := 0
	while _location_of(ext, handle, dense) != 1 and days < 24:
		_day_step(ext)
		days += 1
	if _location_of(ext, handle, dense) != 1:
		printerr("[equip %s] never became active: loc=%s slots=%s used=%d->%s"
			% [key, _locations(ext, handle), _slots(ext, handle), before,
				str(_snapshot(ext, handle).get("ideology_slots_used", "?"))])
		if ext.has_method("poll_ideology_receipts"):
			printerr("[equip receipts] %s" % str(ext.poll_ideology_receipts(0, 64)))
		printerr("[equip report] %s" % str(ext.get_ideology_report()))
	# ---- SETTLE: an equip only becomes a CONTRIBUTION after the ACK ---------
	# While the transition is unACKed, `collect_effect_activations` returns
	# immediately (`previous_location == INACTIVE`, ideology_runtime.cpp:2313-2321,
	# plan 10.1: "an unACKed equip contributes nothing"). The front is therefore
	# EMPTY until the adapter handshake ACKs the equip batch and the next ideology
	# day polls the transition. Every derived read below depends on this loop.
	var settle_days := 0
	var pending := int(ext.get_ideology_report().get("pending_transitions", -1))
	while pending != 0 and settle_days < 16:
		_day_step(ext)
		settle_days += 1
		pending = int(ext.get_ideology_report().get("pending_transitions", -1))
	_expect("%s: the equip transition SETTLES (pending_transitions == 0 after %d "
		% [key, settle_days] + "extra day(s))", pending == 0,
		"pending_transitions=%d" % pending)
	# ---- ELIGIBILITY (plan section 9.3): the settle day itself publishes NOTHING -
	#
	# The poll that settled the transition above recorded
	# `derived_basis_confirmed_day = D` and `derived_basis_eligible_day = D + 1`, and
	# `step_derived_rebuild(D)` is REFUSED by the eligibility gate
	# (ideology_runtime.cpp:7045-7048): the confirmed projection may not be adopted
	# before D + 1. One more ideology day is therefore what makes the card's derived
	# contribution observable. Reading the layer on the settle day itself would
	# legitimately report `installed = false`, which is exactly what this fixture
	# measured before this day was added -- a correct runtime read as an empty front.
	_day_step(ext)
	# One reconcile so the instance path has rows before the caller reads them.
	if ext.has_method("reconcile_ideology_effects_for_test"):
		ext.reconcile_ideology_effects_for_test(handle)
	_drain(ext)


## Rebuilds the derived front and re-runs the effect reconciler so a CHANGED
## school factor reaches the stored `magnitude_scale_q16`.
func _reconcile(ext: Object, ids: PackedStringArray, key: String) -> void:
	_day_step(ext)
	if ext.has_method("reconcile_ideology_effects_for_test"):
		var result: Dictionary = ext.reconcile_ideology_effects_for_test(_handle(ext))
		if not bool(result.get("ok", false)):
			printerr("[reconcile %s] %s" % [key, str(result)])
	_drain(ext)


func _drain(ext: Object) -> void:
	if ext.has_method("drain_derived_cell_layer"):
		# The DAY argument matters (plan section 9.3): `drain_derived_cell_layer`
		# drives `step_derived_rebuild(day_index)`, and that refuses any day before
		# the confirmed projection's `eligible_from_day` (ideology_runtime.cpp:
		# 7045-7048). Draining with a stale day -- this used to pass 0 -- is silently
		# refused and leaves the front half-built, so the CURRENT day is passed.
		ext.drain_derived_cell_layer(_day)


func _submit(ext: Object, row: Dictionary) -> void:
	row["day"] = _day
	var result: Dictionary = ext.submit_ideology_commands(_commands([row]))
	# A rejected command returns a reason instead of applying; printing it is the
	# only way "the card never activated" can be told apart from "the card applied
	# nothing".
	if not bool(result.get("ok", true)):
		printerr("[submit op=%d idea=%d] %s"
			% [int(row.get("op", 0)), int(row.get("idea", -1)), str(result)])


## Raises one school's strength to `1 + magnitude` by applying the test definition
## through the real Modifier ingress. Domain COUNTRY (1), scope ENTITY (2) and the
## country handle -- the same (domain, scope, scope_id) tuple the worker snapshot
## reads (native_simulation_host.cpp:9826-9853) and the same one
## `school_strength_scale_q16` falls back to (ideology_runtime.cpp:3976-3985).
func _inject_school_term(ext: Object, handle: int, tag: String,
		magnitude_q16: int) -> void:
	_seq += 1
	var submitted: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([_seq]),
		"effective_days": PackedInt64Array([_day]),
		"definition_keys": PackedStringArray(["%s%s" % [SCHOOL_DEF_PREFIX, tag]]),
		"domains": PackedInt32Array([1]),
		"scopes": PackedInt32Array([2]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([9]),
		"source_ids": PackedInt64Array([1]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([magnitude_q16]),
		"modifier_handles": PackedInt64Array([0]),
	})
	_expect("school term %s submits" % tag, bool(submitted.get("ok", false)),
		str(submitted))
	_day += 1
	var ran: Dictionary = ext.run_modifier_daily(_day)
	var rejects: PackedStringArray = ran.get("error_reasons", PackedStringArray())
	_expect("school term %s applies without a reject (%s)" % [tag, str(rejects)],
		int(ran.get("commands_rejected_total", 0)) == 0, str(ran))


# -- readers --------------------------------------------------------------

func _handle(ext: Object) -> int:
	return int(ext.get_country_cell_summary(0).get("country_handle", 0))


## The handle `list_modifiers` reports for the fixture's own test definition on
## this country, or 0 when it is not applied. `COMMAND_REMOVE` is handle-addressed
## and IGNORES the definition key (modifier_runtime.cpp:1361-1365 goes straight to
## `remove_handle`), and the fixture does not retain `request_ids`, so the handle is
## read back from the store the same way the game reads an applied modifier.
func _test_modifier_handle(ext: Object, handle: int, stat_key: String,
		definition_key: String) -> int:
	var listed: Dictionary = ext.list_modifiers(1, handle, stat_key)
	var handles: PackedInt64Array = listed.get("handles", PackedInt64Array())
	var keys: PackedStringArray = listed.get("definition_keys", PackedStringArray())
	for index in range(mini(handles.size(), keys.size())):
		if String(keys[index]) == definition_key:
			return int(handles[index])
	return 0


## Removes an applied modifier by handle through the real ingress and commits it
## with `run_modifier_daily` -- the same two-step shape `_inject_school_term` uses.
## `definition_keys` still has to carry one entry (the batch shape check requires
## it, modifier_runtime.cpp:585-592) even though the remove path ignores it.
func _remove_school_term(ext: Object, modifier_handle: int) -> void:
	_seq += 1
	var submitted: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([2]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([_seq]),
		"effective_days": PackedInt64Array([_day]),
		"definition_keys": PackedStringArray([""]),
		"domains": PackedInt32Array([1]),
		"scopes": PackedInt32Array([2]),
		"entity_handles": PackedInt64Array([0]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([0]),
		"source_ids": PackedInt64Array([0]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([Q16_ONE]),
		"modifier_handles": PackedInt64Array([modifier_handle]),
	})
	_expect("school term removal submits", bool(submitted.get("ok", false)),
		str(submitted))
	_day += 1
	var ran: Dictionary = ext.run_modifier_daily(_day)
	var rejects: PackedStringArray = ran.get("error_reasons", PackedStringArray())
	_expect("school term removal applies without a reject (%s)" % str(rejects),
		int(ran.get("commands_rejected_total", 0)) == 0, str(ran))


func _derived_probe(ext: Object) -> Dictionary:
	# entity_handle MUST be 0 and the CELL goes in the group slot: that is the pair
	# the production reader uses (economy_runtime_family_buff.cpp:7127).
	return ext.get_effective_stat_value(SOURCE_STAT, PROBE_CELL, 0, 1.0)


func _school_factor(ext: Object, handle: int, stat_key: String) -> float:
	return float(ext.evaluate_modifier_stat(1, handle, 0, stat_key, 1.0))


## How many times `step_derived_rebuild` has been entered
## (ideology_runtime.cpp:7095 increments `_cell_layer_rebuild_visits` on EVERY
## entry). The only observable that separates "the derived layer was rebuilt and
## the result happened to be identical" from "the derived layer was never rebuilt",
## which the `layer_generation` counter alone cannot do: a content-identical
## candidate is deliberately NOT installed (modifier_runtime.cpp:1693-1698).
func _rebuild_visits(ext: Object) -> int:
	return int(ext.get_ideology_report().get("cell_layer_rebuild_visits", -1))


func _snapshot(ext: Object, handle: int) -> Dictionary:
	return ext.get_ideology_snapshot(handle)


func _slots(ext: Object, handle: int) -> String:
	return str(_snapshot(ext, handle).get("slot_indices", PackedInt32Array()))


func _locations(ext: Object, handle: int) -> String:
	return str(_snapshot(ext, handle).get("locations", PackedInt32Array()))


func _slot_of(ext: Object, handle: int, dense: int) -> int:
	var fields: Dictionary = _snapshot(ext, handle)
	var idea_ids: PackedInt32Array = fields.get("idea_ids", PackedInt32Array())
	var slots: PackedInt32Array = fields.get("slot_indices", PackedInt32Array())
	var index := idea_ids.find(dense)
	if index < 0 or index >= slots.size():
		return -1
	return int(slots[index])


func _location_of(ext: Object, handle: int, dense: int) -> int:
	var fields: Dictionary = _snapshot(ext, handle)
	var idea_ids: PackedInt32Array = fields.get("idea_ids", PackedInt32Array())
	var locations: PackedInt32Array = fields.get("locations", PackedInt32Array())
	var index := idea_ids.find(dense)
	if index < 0 or index >= locations.size():
		return -1
	return int(locations[index])


func _instance_count(ext: Object, handle: int) -> int:
	return int(ext.get_ideology_effect_instance_report(handle).get("count", 0))


## The instance-path magnitude scale of one card, in Q16 -> float. A card owns one
## instance per resolved target, so every row for `dense` must agree; the largest
## is returned so a partially updated set is still visible in the printout.
func _instance_scale(ext: Object, handle: int, dense: int) -> float:
	var report: Dictionary = ext.get_ideology_effect_instance_report(handle)
	var idea_ids: PackedInt64Array = report.get("idea_ids", PackedInt64Array())
	var scales: PackedInt32Array = report.get("magnitude_scales", PackedInt32Array())
	var found := -1.0
	for index in range(mini(idea_ids.size(), scales.size())):
		if int(idea_ids[index]) != dense:
			continue
		var value := float(scales[index]) / float(Q16_ONE)
		if value > found:
			found = value
	return found


# -- misc -----------------------------------------------------------------

func _count_set(flags: PackedByteArray) -> int:
	var total := 0
	for flag in flags:
		if int(flag) == 1:
			total += 1
	return total


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
		# `sequences` is the idempotency key and must be monotonic ACROSS batches
		# (M3-18).
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
	print("=== copier + school: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
