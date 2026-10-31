extends SceneTree
## Plan section 18.1 evidence row: the last uncovered card mechanism --
## the CAPACITY-EXCEEDED rejection of an adopt.
##
## ===========================================================================
## WHY THIS MECHANISM HAD NEVER BEEN EXERCISED
## ===========================================================================
## `equip()` (ideology_runtime.cpp:4657-4682) runs its gates in this order:
##
##   :4659  known(country, id)                      -> ideology_unknown
##   :4660  pending_transition_count > 0 && !_synergies.empty()
##                                                  -> ideology_country_transition_pending
##   :4663  state = idea_state_for(..., create=true)-> ideology_state_unavailable
##   :4665  state->transition.active != 0           -> ideology_transition_pending
##   :4666  state->location == NATIONAL_SPIRIT      -> ideology_is_national_spirit
##   :4667  state->location == IDEOLOGY             -> return TRUE (no-op ok)
##   :4668  exclusion_allows(...)                   -> ideology_exclusion_group_conflict
##   :4669  support_gate(..., SUPPORT_ADOPT)        -> ideology_class_opinion_unavailable
##                                                     / ideology_critical_class_blocked
##                                                     / ideology_support_threshold_not_met
##   :4671  ideology_slot_cost(country) + definition.ideology_cost
##              > ideology_capacity_for(slot)       -> ideology_slot_capacity_exceeded
##   :4675  reconcile_level + start_transition      (the transition starts HERE)
##
## The capacity check is the LAST refusal before the transition starts, so every
## earlier gate has to PASS before it can ever be reached. Shipped cards all
## carry `class_stances`, so their ADOPT gate needs real political-class support
## -- that is why every previous attempt at this mechanism stopped at the support
## gate and the capacity branch stayed unmeasured.
##
## Two facts unlock it, both read out of the code and then MEASURED here:
##
##   1. `ideology_capacity` is an ordinary catalog key
##      (`catalog.get("ideology_capacity", 6)`, :782), so a test catalog can set
##      it to 1 (`_relaxed`, the same fixture-configuration device B1 uses to
##      raise the slot budget). `ideology_capacity_max` is set to 1 as well:
##      :785 takes `max(ideology_capacity, ideology_capacity_max)` and
##      `ideology_capacity_for` (:3941-3949) clamps to that maximum, so setting
##      only the base would leave the cap at the shipped 6.
##
##   2. A card with NO `class_stances` passes the ADOPT gate trivially:
##      `evaluate_support` short-circuits on `definition.stance_count == 0` and
##      returns `{available = true, allowed = true}` BEFORE it even looks at the
##      economy's class-opinion snapshot (:1251-1255). This fixture's cards carry
##      no stances, so `support_gate` cannot be the refuser -- and the same gate
##      is asserted per card through `explain_ideology`, which reports
##      `support_allowed[ADOPT]`, `support_available[ADOPT]` and
##      `support_blocking_classes[ADOPT]` for the real runtime, not a restatement.
##
## ===========================================================================
## THE FIXTURE'S TWO CARDS
## ===========================================================================
## Both are synthesised in memory (no file is touched, no C++ is touched) and
## both level rows are COPIES of a shipped card's level-0 rows:
##
##   test.capacity.alpha  (slot cost 1)
##     persistent_effects = [
##       <cost row>    action 1, domain 1, opcode 1, target_resolver 1,
##                     value_mode 0, value_q16 65536, duration -1, stacks 1,
##                     command_key "ideology.persistent",
##                     definition_key "ideology.public_hygiene"
##                     ^ the SAME field values as the shipped
##                       `EffectPublicHygieneCostL1`
##                       (default_ideology_catalog.tres:5272-5282)
##       <program row> action 1, domain 2, opcode 1, target_resolver 1,
##                     value_mode 1, value_q16 65536, duration -1, stacks 1,
##                     command_key "ideology.persistent",
##                     definition_key "public_hygiene_l1"
##                     ^ the SAME field values as the shipped
##                       `EffectPublicHygieneL1R0`
##                       (default_ideology_catalog.tres:5284-5295)
##     ]
##
##   test.capacity.beta   (slot cost 1, otherwise identical, EXCEPT)
##       <cost row>    definition_key "ideology.algorithmic_governance"
##                     ^ the same field values as the shipped
##                       `EffectAlgorithmicGovernanceL1`
##                       (default_ideology_catalog.tres:14046-14056), so the two
##                       cards' durable Modifier rows are attributable one-by-one
##
## Why BOTH row kinds are there, on purpose:
##
##   * the PROGRAM row is what routes the card to the DERIVED cell backend
##     (`decide_cell_program_backend` keeps a cell-domain, permanent,
##     kind-12/14/15/16 program on `DerivedCell`). The engine's own classifier is
##     asked through the `probe_cell_program_backend` binding in phase 1, so the
##     routing claim is not a GDScript opinion. It also gives the card a real
##     per-cell effect whose absence/presence this fixture can measure.
##
##   * the COST row is what makes the adopt a REAL transition. A row that
##     resolves to a managed program is skipped by `emit_templates`
##     (:1718-1723), so a program-only card commits synchronously and has no
##     pending window at all -- which would make the plan 9.3 / 10.1 timing
##     rules below unobservable. The cost row is emitted, the Effect transaction
##     is enqueued, and the transition stays PENDING until the handshake ACKs it.
##     It is also the durable artefact the "no residue" assertion counts: a card
##     that COULD leave a Modifier row behind is the only card for which "no
##     Modifier row" is a measurement instead of a tautology.
##
## Every command definition those rows need is already compiled from the SHIPPED
## catalog (`EffectDomainCatalog._ideology_command_definition` builds one Effect
## command per compiled persistent row, and `enqueue_external_effect_batch_pod`
## only admits a row whose (command_key, definition_key, action, domain, opcode,
## duration, stacks, payload) tuple matches one of them, :3484-3521). Copying a
## shipped row's fields verbatim is therefore what makes the batch admissible;
## inventing a new pair here would be refused with
## `effect_external_batch_definition_not_compiled`.
##
## ===========================================================================
## THE TIMING RULES THIS FIXTURE HAD TO OBEY (all measured below)
## ===========================================================================
## 9.3  a confirmed projection is eligible on `day + 1`, never on its
##      confirmation day (`_derived_basis_eligible_day = day + 1`, :3903-3912;
##      honoured by `step_derived_rebuild`, :7220-7231).
## 10.1 a PENDING transition contributes the OLD level, and a pending EQUIP has
##      no old level at all, so it contributes NOTHING until it settles
##      (`collect_effect_activations`, :2337-2345).
## Settle handshake, in this order (a different order deadlocks):
##      dispatch_effect_native_modifier() -> run_modifier_daily(day)
##      -> ack_effect_native_modifier(), then run_ideology_daily(day).
## `drain_derived_cell_layer(day)` must be given the CURRENT day; 0 is a silent
## no-op once anything has confirmed (the eligibility gate compares days).
##
## ===========================================================================
## PHASES
## ===========================================================================
##   0  catalogs, the two fixture cards, and the compiled facts the gate reads
##      (slot costs, exclusion groups, zero stance rows).
##   1  world CAP=1: card A is granted, discovered and adopted. The adopt really
##      enters a pending transition, the front shows NOTHING while it is in
##      flight (10.1), the transition SETTLES (a PENDING then a SETTLED receipt
##      for one sequence), the settle day publishes nothing (9.3) and the next
##      day publishes exactly 3277/65536 on every owned cell.
##   2  world CAP=1: card B is adopted. The refusal is exactly
##      `ideology_slot_capacity_exceeded`, and every earlier gate is shown to
##      have been satisfied (support allowed / available / no blocking class,
##      no exclusion group, INACTIVE, nothing pending) so the refusal cannot be
##      a support refusal wearing a different name.
##   3  the state did not move: slots_used still 1, B still INACTIVE, no pending
##      transition, and the runtime's own counters/receipts recorded exactly one
##      rejection.
##   4  no residue: the derived front's contribution_count, stat/cell counts and
##      per-cell `derived_add` are IDENTICAL to the pre-attempt reading and the
##      layer generation did not move; no COUNTRY-domain Modifier row names B's
##      cost definition and the Modifier journal holds no event for it -- while
##      A's own cost row is present, so the row probe is demonstrably live.
##   5  the positive control, world CAP=2 (fresh runtime, the SAME two cards):
##      A adopts (slots 1), then the SAME card B that was refused adopts
##      (slots 2), the front reads exactly 2 x 3277/65536, and B's cost row now
##      EXISTS -- which is what makes phase 4's zero a real zero.
##   6  the second control: re-adopting the already-equipped A at CAP=1 is an
##      `ok` no-op, not a capacity refusal. Measured, because the code returns
##      at :4667 BEFORE the capacity check at :4671, so slots_used(1) + cost(1)
##      > capacity(1) never gets evaluated for a card that is already on.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_capacity_exceeded_test.gd
##
## PHASE ORDER: the phases run 0, 1, 2, 3, 4, 6, 5. Phase 6 needs the CAP=1
## world with A already equipped, so it runs there; phase 5 builds its own fresh
## CAP=2 world and therefore comes last.
##
## Nothing is relaxed beyond the documented fixture configuration: no C++ change,
## no DLL swap, no worker, no environment-variable support-gate bypass
## (`PK_DISABLE_SUPPORT_GATE` is deliberately NOT used -- the ADOPT gate passes
## for a code reason this fixture asserts, not because the gate was removed).

const WIDTH := 5
const HEIGHT := 5
const CELLS: int = WIDTH * HEIGHT
## Cells asserted throughout. Cell 0 is skipped for the reason
## `ideology_mechanism_copier_school_test.gd` gives (it has its own guard history
## in `effective_value`); the selector is OWN_TERRITORY over a 5x5 world, so
## every owned cell carries the same value and four probes are enough.
const PROBE_CELLS := [3, 7, 12, 24]

const Q16_ONE := 65536
## The shipped kind-12 (OWN_TERRITORY) program both cards route to, the stat its
## first command writes, and that command's authored magnitude
## (default_ideology_effects.tres:5336-5357).
const PROGRAM_KEY := "public_hygiene_l1"
const PROGRAM_FULL_KEY := "ideology.effect.public_hygiene_l1"
const PROGRAM_STAT := "economy.city.birth_factor"
const PROGRAM_MAGNITUDE_Q16 := 3277
const PROGRAM_SELECTOR_KIND := 12

## The two shipped Modifier definitions the cards' cost rows name, one per card,
## so a durable row can be attributed to the card that made it.
const COST_DEFINITION_A := "ideology.public_hygiene"
const COST_DEFINITION_B := "ideology.algorithmic_governance"

const CARD_A := "test.capacity.alpha"
const CARD_B := "test.capacity.beta"

## The knob under test. `ideology_capacity_max` is set to the same number so
## `ideology_capacity_for` cannot grow past it (:785, :3941-3949).
const CAPACITY_ONE := 1
const CAPACITY_TWO := 2
## `IdeologyDefinition.ideology_slot_cost` for both cards. The gate evaluates
## `slots_used + THIS > capacity`.
const CARD_SLOT_COST := 1
## The cards carry exactly one level (index 0) so the adopt cannot drift to a
## higher level and change the cost while the fixture is measuring.
const LEVEL_THRESHOLD_Q16 := 0
const LEVEL_DAILY_Q16 := 0

## The refusal under test, spelled once.
const REFUSAL_CODE := "ideology_slot_capacity_exceeded"
## Every refusal `equip()` can produce BEFORE the capacity check. None of them
## may appear in the receipt this fixture reads.
const EARLIER_GATE_CODES := [
	"ideology_unknown",
	"ideology_country_transition_pending",
	"ideology_state_unavailable",
	"ideology_transition_pending",
	"ideology_is_national_spirit",
	"ideology_exclusion_group_conflict",
	"ideology_class_opinion_unavailable",
	"ideology_critical_class_blocked",
	"ideology_support_threshold_not_met",
]

## Opcodes (`ideology_runtime.h:74-86`), locations (`:87`), receipt statuses
## (`:89-91`), Modifier event kinds and domains (`modifier_runtime.h:41,50-52`).
const OP_DISCOVER := 1
const OP_GRANT := 2
const OP_EQUIP := 5
const LOCATION_INACTIVE := 0
const LOCATION_IDEOLOGY := 1
const LOCATION_NATIONAL_SPIRIT := 2
const RECEIPT_PENDING := 1
const RECEIPT_SETTLED := 2
const RECEIPT_REJECTED := 3
const EFFECT_PLANNED := 1
const DOMAIN_COUNTRY := 1
const MODIFIER_DOMAIN_COUNT := 4
const EVENT_APPLY := 1
const EVENT_REJECT := 8
const SUPPORT_ADOPT_INDEX := 0

## `TargetSelectorKind`-side values, mirrored by `ideology_effect_definition.gd`.
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
## `probe_cell_program_backend` is a binding on the world object, so the engine's
## own backend decision can only be asked once a world exists.
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
	print("=== PHASE 0: catalogs, the two fixture cards, and the compiled gate facts ===")
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
	# population but no buildings.
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
		declared_programs.has(PROGRAM_FULL_KEY) and programs.has(PROGRAM_FULL_KEY),
		"%s absent from %d declared programs"
			% [PROGRAM_FULL_KEY, declared_programs.size()])
	if not programs.has(PROGRAM_FULL_KEY):
		_finish(2)
		return
	# The two cost definitions must exist in the compiled Modifier catalog, or the
	# cost rows would be rejected at dispatch and the adopt would never settle.
	var mod_keys: PackedStringArray = mod_ir.get("definition_keys", PackedStringArray())
	_expect("both cost definitions resolve in the compiled Modifier catalog",
		mod_keys.has(COST_DEFINITION_A) and mod_keys.has(COST_DEFINITION_B),
		"A=%s B=%s (of %d definitions)"
			% [str(mod_keys.has(COST_DEFINITION_A)),
				str(mod_keys.has(COST_DEFINITION_B)), mod_keys.size()])

	var catalog: Resource = IdeologyCatalogScript.load_default()
	# The compiled catalog is derived from this resource, so the two test cards are
	# appended HERE -- in memory only.
	_add_fixture_cards(catalog)
	# Pin the program set the compiler reads to the one this fixture measured, so
	# the compiled catalog and the EffectCatalog cannot disagree about it.
	catalog.effect_programs = effect_catalog
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	_expect("the ideology catalog compiles with the two fixture cards",
		bool(native.get("ok", false)),
		str(native.get("reason", native.get("fatal_reason", ""))))
	if not bool(native.get("ok", false)):
		_finish(2)
		return
	native.erase("ok")

	var ids: PackedStringArray = native.get("ideology_ids", PackedStringArray())
	var a_dense := ids.find(CARD_A)
	var b_dense := ids.find(CARD_B)
	_expect("card A is in the compiled catalog", a_dense >= 0, str(a_dense))
	_expect("card B is in the compiled catalog", b_dense >= 0, str(b_dense))
	if a_dense < 0 or b_dense < 0:
		_finish(2)
		return

	# ---- the facts `equip()` reads, straight out of the compiled catalog ----
	var slot_costs: PackedInt32Array = native.get("ideology_slot_costs", PackedInt32Array())
	var exclusion_groups: PackedInt32Array = native.get(
		"exclusion_group_ids", PackedInt32Array())
	var stance_offsets: PackedInt32Array = native.get(
		"stance_offsets", PackedInt32Array())
	var level_offsets: PackedInt32Array = native.get("level_offsets", PackedInt32Array())
	_expect("both cards cost 1 ideology slot (`ideology_slot_costs` == 1)",
		int(slot_costs[a_dense]) == CARD_SLOT_COST
			and int(slot_costs[b_dense]) == CARD_SLOT_COST,
		"A=%d B=%d" % [int(slot_costs[a_dense]), int(slot_costs[b_dense])])
	# -1 is what `exclusion_allows` (:1355-1357) reads as "this card excludes
	# nothing", i.e. the gate cannot fire for either card.
	print("[0] exclusion_group ids: A=%d B=%d (-1 = no group)"
		% [int(exclusion_groups[a_dense]), int(exclusion_groups[b_dense])])
	_expect("neither card belongs to an exclusion group (exclusion_allows cannot "
		+ "refuse them)", int(exclusion_groups[a_dense]) == -1
			and int(exclusion_groups[b_dense]) == -1,
		"A=%d B=%d" % [int(exclusion_groups[a_dense]), int(exclusion_groups[b_dense])])
	var a_stances := int(stance_offsets[a_dense + 1]) - int(stance_offsets[a_dense])
	var b_stances := int(stance_offsets[b_dense + 1]) - int(stance_offsets[b_dense])
	print("[0] compiled class stance rows: A=%d B=%d (0 = `evaluate_support` "
		% [a_stances, b_stances] + "short-circuits to allowed)")
	_expect("both cards compile with ZERO class stance rows -- the reason their "
		+ "ADOPT support gate passes without a class-opinion snapshot",
		a_stances == 0 and b_stances == 0, "A=%d B=%d" % [a_stances, b_stances])
	_expect("both cards have exactly one level (so the adopt cannot level up "
		+ "under the measurement)",
		int(level_offsets[a_dense + 1]) - int(level_offsets[a_dense]) == 1
			and int(level_offsets[b_dense + 1]) - int(level_offsets[b_dense]) == 1,
		"A=%d B=%d" % [
			int(level_offsets[a_dense + 1]) - int(level_offsets[a_dense]),
			int(level_offsets[b_dense + 1]) - int(level_offsets[b_dense])])

	# ---- the two capacity worlds -----------------------------------------
	var cap1: Dictionary = _relaxed(native, CAPACITY_ONE)
	var cap2: Dictionary = _relaxed(native, CAPACITY_TWO)
	_expect("the CAP=1 catalog really carries ideology_capacity 1 / max 1",
		int(cap1.get("ideology_capacity", -1)) == CAPACITY_ONE
			and int(cap1.get("ideology_capacity_max", -1)) == CAPACITY_ONE,
		"%s / %s" % [str(cap1.get("ideology_capacity", "?")),
			str(cap1.get("ideology_capacity_max", "?"))])
	_expect("the CAP=2 catalog really carries ideology_capacity 2 / max 2",
		int(cap2.get("ideology_capacity", -1)) == CAPACITY_TWO
			and int(cap2.get("ideology_capacity_max", -1)) == CAPACITY_TWO,
		"%s / %s" % [str(cap2.get("ideology_capacity", "?")),
			str(cap2.get("ideology_capacity_max", "?"))])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 1: world CAP=1 -- card A adopts through a SETTLED transition ===")
	# ---------------------------------------------------------------------
	var ext1: Object = _build_world(country_ir, profile, effect_ir, mod_ir, cap1, "cap1")
	var handle1 := _handle(ext1)
	print("[1] runtime capacity: ideology_slots_capacity=%d (slots_used=%d)"
		% [_slots_capacity(ext1), _slots_used(ext1)])
	_expect("1: the runtime reports capacity 1 for this country, read back from "
		+ "`ideology_capacity_for`",
		_slots_capacity(ext1) == CAPACITY_ONE, str(_slots_capacity(ext1)))

	# ---- the program really is a DERIVED program ------------------------
	var program: Resource = programs[PROGRAM_FULL_KEY]
	var probe: Dictionary = _probe_program_backend(program, mod_ir)
	print("[1] program %s  domain=%d kind=%d lifecycle=%d -> backend=%s reason=%s"
		% [PROGRAM_FULL_KEY, int(program.target_domain),
			int(program.target_selector_kind), int(program.lifecycle),
			String(probe.get("backend", "?")), String(probe.get("reason", "?"))])
	_expect("1: the program both cards route to is classified DerivedCell by "
		+ "`decide_cell_program_backend`",
		String(probe.get("backend", "")) == "DerivedCell", str(probe))
	_expect("1: its selector kind is 12 (OWN_TERRITORY), a cell selector",
		int(program.target_selector_kind) == PROGRAM_SELECTOR_KIND,
		str(program.target_selector_kind))
	_expect("1: its lifecycle is PERMANENT (the other half of the derived "
		+ "classification)", int(program.lifecycle) == LIFECYCLE_PERMANENT,
		str(program.lifecycle))
	var rollout: Dictionary = ext1.get_cell_program_rollout()
	var kinds: PackedInt32Array = rollout.get("enabled_kinds", PackedInt32Array())
	var kinds_ok := kinds.size() == 4
	for wanted in DERIVED_SELECTOR_KINDS:
		kinds_ok = kinds_ok and kinds.has(int(wanted))
	print("[1] derived-layer rollout enabled kinds = %s" % str(kinds))
	_expect("1: the runtime's derived rollout covers exactly kinds 12/14/15/16",
		kinds_ok, str(kinds))
	_expect("1: the shipped program is owned by the Effect reconciler",
		bool(ext1.effect_program_is_managed(PROGRAM_FULL_KEY)), PROGRAM_FULL_KEY)

	# ---- grant + discover both cards ------------------------------------
	_submit_op(ext1, OP_GRANT, -1, 64 * Q16_ONE, "1/grant")
	_submit_op(ext1, OP_DISCOVER, a_dense, 0, "1/discover A")
	_submit_op(ext1, OP_DISCOVER, b_dense, 0, "1/discover B")
	_tick(ext1, "1/discover")
	var known: PackedInt32Array = _snapshot(ext1, handle1).get(
		"known_ids", PackedInt32Array())
	_expect("1: both cards are DISCOVERED (known_ids contains both)",
		known.has(a_dense) and known.has(b_dense), str(known))
	# `reconcile_level` moves a freshly created IdeaState from level -1 to the
	# highest unlocked level (0 here) and counts that as an advance, so discovery
	# -- not the adopt -- is where `levels_advanced` moves.
	print(("[1] levels_advanced after discovery = %d (2 discovered cards, each "
		+ "reconciled -1 -> 0)") % _advanced(ext1))
	_expect("1: discovery reconciled both cards from level -1 to 0, and nothing "
		+ "else advanced",
		_advanced(ext1) == 2 and _level_of(ext1, handle1, a_dense) == 0
			and _level_of(ext1, handle1, b_dense) == 0,
		"advanced=%d levels=%d/%d" % [_advanced(ext1),
			_level_of(ext1, handle1, a_dense), _level_of(ext1, handle1, b_dense)])

	# ---- the pre-state ---------------------------------------------------
	_expect("1: nothing is in flight before the first adopt",
		_pending(ext1) == 0, str(_pending(ext1)))
	_expect("1: slots_used starts at 0", _slots_used(ext1) == 0,
		str(_slots_used(ext1)))
	_expect("1: card A starts INACTIVE",
		_location_of(ext1, handle1, a_dense) == LOCATION_INACTIVE,
		_locations(ext1, handle1))
	var pre_front := _measure(ext1, "1/pre")
	_expect("1: no derived contribution exists before any card is active "
		+ "(present=0 on every probe cell and add == 0)",
		int(pre_front["present_sum"]) == 0
			and _is_close(float((pre_front["adds"] as PackedFloat64Array)[0]), 0.0, 0.0),
		"present=%d add=%.17f" % [int(pre_front["present_sum"]),
			float((pre_front["adds"] as PackedFloat64Array)[0])])

	# ---- adopt A, with the timing rules measured at each step -----------
	var advanced_before_adopt := _advanced(ext1)
	var a_run := _equip_card(ext1, a_dense, "1/A")
	print("[1] A: request day=%d  pending_at_request=%d  location_after=%d  "
		% [int(a_run["request_day"]), int(a_run["pending_at_request"]),
			int(a_run["location_after_request"])]
		+ "slots_after=%d  settle_day=%d  settle_days=%d  pending_after=%d"
		% [int(a_run["slots_after_request"]), int(a_run["settle_day"]),
			int(a_run["settle_days"]), int(a_run["pending_after"])])
	print("[1] A receipts: %s" % _receipt_text(a_run["receipts"]))
	_expect("1: the adopt really entered a transition (pending_transitions == 1 "
		+ "while it is in flight)",
		int(a_run["pending_at_request"]) == 1, str(a_run["pending_at_request"]))
	_expect("1: the card's own transition flag is set while it is in flight",
		int(a_run["transition_pending_byte"]) == 1,
		str(a_run["transition_pending_byte"]))
	_expect("1: the pending adopt carries exactly one PLANNED Effect transaction",
		(a_run["transaction_statuses"] as PackedInt32Array)
			== PackedInt32Array([EFFECT_PLANNED]),
		str(a_run["transaction_statuses"]))
	var pending_adds: PackedFloat64Array = (a_run["pending_front"] as Dictionary)["adds"]
	print("[1] while PENDING: present=%d add[0]=%.17f"
		% [int((a_run["pending_front"] as Dictionary)["present_sum"]),
			float(pending_adds[0])])
	_expect("1: while PENDING the front shows NOTHING from A (plan 10.1: a pending "
		+ "equip has no old level to contribute)",
		int((a_run["pending_front"] as Dictionary)["present_sum"]) == 0
			and _is_close(float(pending_adds[0]), 0.0, 0.0),
		"present=%d add=%.17f" % [
			int((a_run["pending_front"] as Dictionary)["present_sum"]),
			float(pending_adds[0])])
	_expect("1: A is equipped (location == IDEOLOGY == 1) once the command lands",
		int(a_run["location_after_request"]) == LOCATION_IDEOLOGY,
		str(a_run["location_after_request"]))
	_expect("1: slots_used == 1 at request time (A's slot cost is charged when the "
		+ "transition starts)", int(a_run["slots_after_request"]) == 1,
		str(a_run["slots_after_request"]))
	_expect("1: the level-0 adopt transition SETTLED (pending_transitions == 0 "
		+ "within %d settle day(s))" % int(a_run["settle_days"]),
		int(a_run["pending_after"]) == 0, str(a_run["pending_after"]))
	var a_receipts: Array = a_run["receipts"]
	var a_statuses := PackedInt32Array()
	for receipt in a_receipts:
		a_statuses.append(int(receipt["status"]))
	_expect("1: the ONE equip sequence is journalled as PENDING(1) then SETTLED(2) "
		+ "-- that pair is the settle",
		a_statuses == PackedInt32Array([RECEIPT_PENDING, RECEIPT_SETTLED]),
		_receipt_text(a_receipts))
	var settled_receipt: Dictionary = {}
	for receipt in a_receipts:
		if int(receipt["status"]) == RECEIPT_SETTLED:
			settled_receipt = receipt
	_expect("1: the SETTLED receipt is stamped with the settle day (%d)"
		% int(a_run["settle_day"]),
		int(settled_receipt.get("day", -1)) == int(a_run["settle_day"]),
		"receipt day=%s settle day=%d"
			% [str(settled_receipt.get("day", "?")), int(a_run["settle_day"])])
	_expect("1: the card is at level index 0 (its only level)",
		_level_of(ext1, handle1, a_dense) == 0,
		str(_level_of(ext1, handle1, a_dense)))
	_expect("1: the adopt is a LOCATION transition, not a level-up "
		+ "(levels_advanced stayed %d)" % advanced_before_adopt,
		_advanced(ext1) == advanced_before_adopt,
		"%d -> %d" % [advanced_before_adopt, _advanced(ext1)])
	var settle_adds: PackedFloat64Array = (a_run["settle_front"] as Dictionary)["adds"]
	print("[1] on the SETTLE day %d: present=%d add[0]=%.17f (plan 9.3 says the "
		% [int(a_run["settle_day"]),
			int((a_run["settle_front"] as Dictionary)["present_sum"]),
			float(settle_adds[0])] + "projection is eligible tomorrow)")
	_expect("1: the settle day itself publishes NOTHING (plan 9.3: "
		+ "eligible_from_day = settle_day + 1)",
		int((a_run["settle_front"] as Dictionary)["present_sum"]) == 0
			and _is_close(float(settle_adds[0]), 0.0, 0.0),
		"present=%d add=%.17f" % [
			int((a_run["settle_front"] as Dictionary)["present_sum"]),
			float(settle_adds[0])])
	_tick(ext1, "1/publish")
	var published := _measure(ext1, "1/published")
	var expect_s := float(PROGRAM_MAGNITUDE_Q16) / float(Q16_ONE)
	_expect("1: the front is published on settle_day + 1 (sample_day %d, expected %d)"
		% [int(published["sample_day"]), int(a_run["settle_day"]) + 1],
		int(published["sample_day"]) == int(a_run["settle_day"]) + 1,
		str(published["sample_day"]))
	_expect_front(ext1, "1", published, 50, 50, 2)
	_expect_cells(ext1, "1", published, expect_s)
	var published_adds: PackedFloat64Array = published["adds"]
	_expect("1: the published add is exactly 3277/Q16 (0.0500030517578125)",
		_is_close(float(published_adds[0]), expect_s, 1e-15),
		"actual=%.17f expected=%.17f" % [float(published_adds[0]), expect_s])
	_expect("1: 3277/Q16 is EXACTLY the authored magnitude (add * 65536 == 3277)",
		int(round(float(published_adds[0]) * float(Q16_ONE))) == PROGRAM_MAGNITUDE_Q16,
		"add*65536=%.6f" % (float(published_adds[0]) * float(Q16_ONE)))
	_expect("1: slots_used is still 1 after the settle", _slots_used(ext1) == 1,
		str(_slots_used(ext1)))

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 2: world CAP=1 -- card B is refused by the CAPACITY gate ===")
	# ---------------------------------------------------------------------
	var pre_attempt_front := _measure(ext1, "2/pre-attempt")
	var pre_attempt_rows := _country_rows(ext1, handle1)
	var pre_attempt_all_rows := _all_modifier_rows(ext1)
	var pre_attempt_journal_b := _journal_summary(ext1, COST_DEFINITION_B)
	var pre_attempt_journal_a := _journal_summary(ext1, COST_DEFINITION_A)
	var rejected_before := _rejected(ext1)
	var applied_before := _applied(ext1)
	var advanced_before := _advanced(ext1)

	var explain_b: Dictionary = ext1.explain_ideology(handle1, b_dense)
	var b_stance_rows: PackedInt32Array = explain_b.get(
		"stance_class_indices", PackedInt32Array())
	var b_allowed: PackedByteArray = explain_b.get("support_allowed", PackedByteArray())
	var b_available: PackedByteArray = explain_b.get(
		"support_available", PackedByteArray())
	var b_blocking: PackedInt32Array = explain_b.get(
		"support_blocking_classes", PackedInt32Array())
	print("[2] B before the attempt: location=%d level=%d known=%s"
		% [int(explain_b.get("location", -1)), int(explain_b.get("level", -1)),
			str(explain_b.get("known", false))])
	print("[2] B ADOPT support: allowed=%s available=%s blocking=%s stance_rows=%d"
		% [str(b_allowed), str(b_available), str(b_blocking), b_stance_rows.size()])
	_expect("2: B carries no class stances at all (the compiled gate input)",
		b_stance_rows.is_empty(), str(b_stance_rows))
	_expect("2: B's ADOPT support gate reports AVAILABLE (the runtime evaluated it)",
		b_available.size() > SUPPORT_ADOPT_INDEX and int(
			b_available[SUPPORT_ADOPT_INDEX]) == 1, str(b_available))
	_expect("2: B's ADOPT support gate reports ALLOWED -- the support gate is "
		+ "therefore NOT the refuser",
		b_allowed.size() > SUPPORT_ADOPT_INDEX and int(
			b_allowed[SUPPORT_ADOPT_INDEX]) == 1, str(b_allowed))
	_expect("2: B has no blocking critical class",
		b_blocking.size() > SUPPORT_ADOPT_INDEX
			and int(b_blocking[SUPPORT_ADOPT_INDEX]) == -1, str(b_blocking))
	_expect("2: B is INACTIVE before the attempt -- not IDEOLOGY(1), not "
		+ "NATIONAL_SPIRIT(2)",
		int(explain_b.get("location", LOCATION_NATIONAL_SPIRIT)) == LOCATION_INACTIVE,
		str(explain_b.get("location", "?")))
	var slot_cost_b := int(slot_costs[b_dense])
	var slots_before := _slots_used(ext1)
	var capacity_before := _slots_capacity(ext1)
	print("[2] capacity gate arithmetic: slots_used(%d) + B.ideology_cost(%d) = %d "
		% [slots_before, slot_cost_b, slots_before + slot_cost_b]
		+ "> capacity(%d) -> %s"
		% [capacity_before,
			"EXCEEDED" if slots_before + slot_cost_b > capacity_before else "not exceeded"])
	_expect("2: the arithmetic the capacity gate evaluates is 1 + 1 = 2 > 1",
		slots_before + slot_cost_b > capacity_before,
		"%d + %d > %d" % [slots_before, slot_cost_b, capacity_before])
	_expect("2: nothing else is pending before the attempt (so the pending guards "
		+ "cannot be the refuser)", _pending(ext1) == 0, str(_pending(ext1)))

	var b_sequence := _submit_op(ext1, OP_EQUIP, b_dense, 0, "2/B")
	_tick(ext1, "2/refuse")
	var b_receipts := _receipts_for(ext1, b_sequence)
	var b_codes := PackedStringArray()
	for receipt in b_receipts:
		b_codes.append(String(receipt["reason"]))
	print("[2] B receipts: %s" % _receipt_text(b_receipts))
	_expect("2: the adopt of B is REFUSED (exactly one receipt, status 3 == REJECTED)",
		b_receipts.size() == 1
			and int((b_receipts[0] as Dictionary)["status"]) == RECEIPT_REJECTED,
		_receipt_text(b_receipts))
	_expect("2: the refusal code is EXACTLY '%s'" % REFUSAL_CODE,
		b_codes == PackedStringArray([REFUSAL_CODE]), str(b_codes))
	_expect("2: the receipt is the EQUIP command for card B itself (opcode %d, "
		% OP_EQUIP + "idea == B's dense id %d)" % b_dense,
		b_receipts.size() == 1
			and int((b_receipts[0] as Dictionary)["opcode"]) == OP_EQUIP
			and int((b_receipts[0] as Dictionary)["idea"]) == b_dense,
		_receipt_text(b_receipts))
	_expect("2: the runtime's own last_error records the same code",
		String(_report(ext1).get("last_error", "")) == REFUSAL_CODE,
		String(_report(ext1).get("last_error", "")))
	var earlier_seen := PackedStringArray()
	for code in EARLIER_GATE_CODES:
		if b_codes.has(String(code)):
			earlier_seen.append(String(code))
	_expect("2: NONE of the 9 earlier equip gates produced the refusal %s"
		% str(EARLIER_GATE_CODES), earlier_seen.is_empty(), str(earlier_seen))

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 3: the refused adopt moved NOTHING ===")
	# ---------------------------------------------------------------------
	var b_location := _location_of(ext1, handle1, b_dense)
	var slots_after := _slots_used(ext1)
	print("[3] slots_used %d -> %d   B location %d -> %d   pending=%d"
		% [slots_before, slots_after, LOCATION_INACTIVE, b_location, _pending(ext1)])
	_expect("3: slots_used is still 1 after the refusal", slots_after == 1,
		str(slots_after))
	_expect("3: card B is still INACTIVE (location 0)", b_location == LOCATION_INACTIVE,
		str(b_location))
	_expect("3: B is still at level index 0", _level_of(ext1, handle1, b_dense) == 0,
		str(_level_of(ext1, handle1, b_dense)))
	_expect("3: B earned no understanding from the refused command",
		_understanding_of(ext1, handle1, b_dense) == 0,
		str(_understanding_of(ext1, handle1, b_dense)))
	_expect("3: pending_transitions == 0 (no transition was started)",
		_pending(ext1) == 0, str(_pending(ext1)))
	var rejected_after := _rejected(ext1)
	print("[3] runtime counters: commands_rejected %d -> %d, commands_applied %d -> %d, "
		% [rejected_before, rejected_after, applied_before, _applied(ext1)]
		+ "levels_advanced %d -> %d"
		% [advanced_before, _advanced(ext1)])
	_expect("3: commands_rejected grew by exactly 1",
		rejected_after - rejected_before == 1,
		"%d -> %d" % [rejected_before, rejected_after])
	_expect("3: commands_applied did NOT grow (the refusal is not an application)",
		_applied(ext1) == applied_before,
		"%d -> %d" % [applied_before, _applied(ext1)])
	_expect("3: levels_advanced did not move", _advanced(ext1) == advanced_before,
		"%d -> %d" % [advanced_before, _advanced(ext1)])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 4: the refused adopt left NO residue ===")
	# ---------------------------------------------------------------------
	var after_attempt_front := _measure(ext1, "4/post-attempt")
	print("[4] front pre-attempt : gen=%d contribs=%d cells=%d stats=%d add[0]=%.17f"
		% [int(pre_attempt_front["gen"]), int(pre_attempt_front["contribs"]),
			int(pre_attempt_front["cells"]), int(pre_attempt_front["stats"]),
			float((pre_attempt_front["adds"] as PackedFloat64Array)[0])])
	print("[4] front post-attempt: gen=%d contribs=%d cells=%d stats=%d add[0]=%.17f"
		% [int(after_attempt_front["gen"]), int(after_attempt_front["contribs"]),
			int(after_attempt_front["cells"]), int(after_attempt_front["stats"]),
			float((after_attempt_front["adds"] as PackedFloat64Array)[0])])
	_expect("4: the front's contribution_count is IDENTICAL to the pre-attempt "
		+ "reading",
		int(after_attempt_front["contribs"]) == int(pre_attempt_front["contribs"]),
		"%d -> %d" % [int(pre_attempt_front["contribs"]),
			int(after_attempt_front["contribs"])])
	_expect("4: the front's stat and cell counts are IDENTICAL",
		int(after_attempt_front["stats"]) == int(pre_attempt_front["stats"])
			and int(after_attempt_front["cells"]) == int(pre_attempt_front["cells"]),
		"stats %d->%d cells %d->%d" % [int(pre_attempt_front["stats"]),
			int(after_attempt_front["stats"]), int(pre_attempt_front["cells"]),
			int(after_attempt_front["cells"])])
	_expect("4: every probe cell's derived_add is BIT-IDENTICAL to the pre-attempt "
		+ "reading",
		_adds_identical(pre_attempt_front["adds"], after_attempt_front["adds"]),
		_adds_text(pre_attempt_front["adds"]) + " vs "
			+ _adds_text(after_attempt_front["adds"]))
	_expect("4: the front was NOT reinstalled by the refused attempt "
		+ "(layer_generation unchanged)",
		int(after_attempt_front["gen"]) == int(pre_attempt_front["gen"]),
		"%d -> %d" % [int(pre_attempt_front["gen"]),
			int(after_attempt_front["gen"])])
	_expect("4: the ideology day's derived stage still ran (rebuild visits %d -> %d), "
		% [int(pre_attempt_front["rebuilds"]), int(after_attempt_front["rebuilds"])]
		+ "so 'unchanged' means re-evaluated-and-equal, not never-looked",
		int(after_attempt_front["rebuilds"]) > int(pre_attempt_front["rebuilds"]),
		"%d -> %d" % [int(pre_attempt_front["rebuilds"]),
			int(after_attempt_front["rebuilds"])])
	var post_attempt_rows := _country_rows(ext1, handle1)
	print("[4] country-domain Modifier rows for %s: A(%s)=%d B(%s)=%d  total rows=%d"
		% [CARD_A, COST_DEFINITION_A, int(post_attempt_rows["a"]),
			COST_DEFINITION_B, int(post_attempt_rows["b"]),
			int(post_attempt_rows["count"])])
	_expect("4: NO country-domain Modifier row names B's cost definition "
		+ "(`%s`)" % COST_DEFINITION_B, int(post_attempt_rows["b"]) == 0,
		str(post_attempt_rows["keys"]))
	_expect("4: the row probe is live -- A's own cost row is still there and is "
		+ "exactly one", int(post_attempt_rows["a"]) == 1, str(post_attempt_rows["keys"]))
	_expect("4: the country-domain row set is unchanged by the refused attempt",
		(post_attempt_rows["keys"] as PackedStringArray)
			== (pre_attempt_rows["keys"] as PackedStringArray),
		"%s vs %s" % [str(pre_attempt_rows["keys"]), str(post_attempt_rows["keys"])])
	_expect("4: the whole Modifier store holds the same number of rows",
		_all_modifier_rows(ext1) == pre_attempt_all_rows,
		"%d -> %d" % [pre_attempt_all_rows, _all_modifier_rows(ext1)])
	var post_attempt_journal_b := _journal_summary(ext1, COST_DEFINITION_B)
	var post_attempt_journal_a := _journal_summary(ext1, COST_DEFINITION_A)
	print("[4] Modifier journal: A(%s) apply=%d reject=%d ; B(%s) apply=%d reject=%d "
		% [COST_DEFINITION_A, int(pre_attempt_journal_a["apply"]),
			int(pre_attempt_journal_a["reject"]), COST_DEFINITION_B,
			int(post_attempt_journal_b["apply"]), int(post_attempt_journal_b["reject"])]
		+ "(overflow=%d)" % int(post_attempt_journal_b["overflow"]))
	_expect("4: the Modifier journal holds NO apply and NO reject event for B's "
		+ "definition",
		int(post_attempt_journal_b["apply"]) == 0
			and int(post_attempt_journal_b["reject"]) == 0,
		str(post_attempt_journal_b))
	_expect("4: the journal probe is live -- A's definition has at least one APPLY "
		+ "event in it", int(pre_attempt_journal_a["apply"]) >= 1,
		str(pre_attempt_journal_a))
	_expect("4: the journal was not truncated (journal_overflow == 0), so a missing "
		+ "B event is not a rolled-over buffer",
		int(post_attempt_journal_b["overflow"]) == 0,
		str(post_attempt_journal_b["overflow"]))
	# The rejection was an EVENT out of `equip`, not a mid-batch rollback: the
	# capacity gate sits BEFORE `start_transition` (:4671 vs :4675), so no Effect
	# batch was ever enqueued and `ModifierRuntime::remove_rows_for_source` has
	# nothing to undo. That is asserted above by measuring rather than by quoting
	# this comment.
	_expect("4: the receipt's refusal is a pre-transition refusal -- no Effect "
		+ "transaction was ever created for B",
		(_snapshot(ext1, handle1).get("transition_transaction_ids",
			PackedInt64Array()) as PackedInt64Array).is_empty(),
		str(_snapshot(ext1, handle1).get("transition_transaction_ids",
			PackedInt64Array())))

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 6: world CAP=1 -- re-adopting the already-equipped A ===")
	# ---------------------------------------------------------------------
	# The capacity check is `slots_used + cost > capacity`, and for A that is now
	# 1 + 1 > 1 -- true. The code returns at :4667 (`location == IDEOLOGY`) before
	# the capacity block at :4671, so the re-adopt must be an ok no-op. Measured.
	var front_before_reapply := _measure(ext1, "6/pre re-adopt")
	var rejected_before_reapply := _rejected(ext1)
	var a_sequence := _submit_op(ext1, OP_EQUIP, a_dense, 0, "6/A re-adopt")
	_tick(ext1, "6/re-adopt")
	var a_readopt_receipts := _receipts_for(ext1, a_sequence)
	# NOTE: `_receipts_for` returns EVERY receipt for that sequence, and this
	# sequence is new, so the list holds only this command's outcome.
	var readopt_codes := PackedStringArray()
	for receipt in a_readopt_receipts:
		readopt_codes.append(String(receipt["reason"]))
	print("[6] A re-adopt receipts: %s" % _receipt_text(a_readopt_receipts))
	_expect("6: re-adopting the already-equipped A is an OK no-op -- one receipt, "
		+ "status 2 (SETTLED), empty reason",
		a_readopt_receipts.size() == 1
			and int((a_readopt_receipts[0] as Dictionary)["status"]) == RECEIPT_SETTLED
			and String((a_readopt_receipts[0] as Dictionary)["reason"]).is_empty(),
		_receipt_text(a_readopt_receipts))
	_expect("6: it did NOT trip the capacity gate, even though slots_used(1) + "
		+ "cost(1) > capacity(1)",
		not readopt_codes.has(REFUSAL_CODE), str(readopt_codes))
	_expect("6: slots_used is still 1", _slots_used(ext1) == 1,
		str(_slots_used(ext1)))
	_expect("6: A is still IDEOLOGY at level index 0",
		_location_of(ext1, handle1, a_dense) == LOCATION_IDEOLOGY
			and _level_of(ext1, handle1, a_dense) == 0,
		"%s %s" % [_locations(ext1, handle1),
			str(_level_of(ext1, handle1, a_dense))])
	_expect("6: no transition was started by the no-op", _pending(ext1) == 0,
		str(_pending(ext1)))
	_expect("6: the runtime counted no rejection", _rejected(ext1) == rejected_before_reapply,
		"%d -> %d" % [rejected_before_reapply, _rejected(ext1)])
	var front_after_reapply := _measure(ext1, "6/post re-adopt")
	_expect("6: the front is untouched (same contribution_count, same per-cell add, "
		+ "same generation)",
		int(front_after_reapply["contribs"]) == int(front_before_reapply["contribs"])
			and int(front_after_reapply["gen"]) == int(front_before_reapply["gen"])
			and _adds_identical(front_before_reapply["adds"],
				front_after_reapply["adds"]),
		"gen %d->%d" % [int(front_before_reapply["gen"]),
			int(front_after_reapply["gen"])])

	# ---------------------------------------------------------------------
	print("")
	print("=== PHASE 5: world CAP=2 -- the SAME card B adopts (positive control) ===")
	# ---------------------------------------------------------------------
	var ext2: Object = _build_world(country_ir, profile, effect_ir, mod_ir, cap2, "cap2")
	var handle2 := _handle(ext2)
	print("[5] runtime capacity: ideology_slots_capacity=%d (slots_used=%d)"
		% [_slots_capacity(ext2), _slots_used(ext2)])
	_expect("5: the fresh runtime reports capacity 2", _slots_capacity(ext2) == 2,
		str(_slots_capacity(ext2)))
	_submit_op(ext2, OP_GRANT, -1, 64 * Q16_ONE, "5/grant")
	_submit_op(ext2, OP_DISCOVER, a_dense, 0, "5/discover A")
	_submit_op(ext2, OP_DISCOVER, b_dense, 0, "5/discover B")
	_tick(ext2, "5/discover")

	var a_run2 := _equip_card(ext2, a_dense, "5/A")
	_tick(ext2, "5/A publish")
	var a_front2 := _measure(ext2, "5/A alone")
	_expect("5: A adopts in the CAP=2 world too (pending settled, slots 1, "
		+ "location IDEOLOGY)",
		int(a_run2["pending_after"]) == 0
			and _slots_used(ext2) == 1
			and _location_of(ext2, handle2, a_dense) == LOCATION_IDEOLOGY,
		"pending=%d slots=%d loc=%s" % [int(a_run2["pending_after"]),
			_slots_used(ext2), _locations(ext2, handle2)])
	_expect_front(ext2, "5/A", a_front2, 50, 50, 2)
	_expect_cells(ext2, "5/A", a_front2, expect_s)

	var slots_before_b := _slots_used(ext2)
	var capacity2 := _slots_capacity(ext2)
	print("[5] capacity gate arithmetic for B at CAP=2: slots_used(%d) + cost(%d) = %d "
		% [slots_before_b, slot_cost_b, slots_before_b + slot_cost_b]
		+ "<= capacity(%d) -> admits" % capacity2)
	_expect("5: the same arithmetic that refused at CAP=1 now fits (1 + 1 = 2 <= 2)",
		slots_before_b + slot_cost_b <= capacity2,
		"%d + %d <= %d" % [slots_before_b, slot_cost_b, capacity2])
	var b_run2 := _equip_card(ext2, b_dense, "5/B")
	print("[5] B: pending_at_request=%d settle_day=%d pending_after=%d receipts=%s"
		% [int(b_run2["pending_at_request"]), int(b_run2["settle_day"]),
			int(b_run2["pending_after"]), _receipt_text(b_run2["receipts"])])
	_expect("5: B's adopt also enters a real transition (pending == 1 in flight)",
		int(b_run2["pending_at_request"]) == 1, str(b_run2["pending_at_request"]))
	_expect("5: B's slot cost is charged the moment its transition starts "
		+ "(slots_used == 2 while still pending)",
		int(b_run2["slots_after_request"]) == 2, str(b_run2["slots_after_request"]))
	_expect("5: B's transition SETTLED", int(b_run2["pending_after"]) == 0,
		str(b_run2["pending_after"]))
	_tick(ext2, "5/B publish")
	var both_front := _measure(ext2, "5/A+B")
	print("[5] B location=%d level=%d slots_used=%d capacity=%d"
		% [_location_of(ext2, handle2, b_dense), _level_of(ext2, handle2, b_dense),
			_slots_used(ext2), _slots_capacity(ext2)])
	_expect("5: the SAME card B that was refused at CAP=1 is now IDEOLOGY at level 0",
		_location_of(ext2, handle2, b_dense) == LOCATION_IDEOLOGY
			and _level_of(ext2, handle2, b_dense) == 0,
		"%s %s" % [_locations(ext2, handle2),
			str(_level_of(ext2, handle2, b_dense))])
	_expect("5: slots_used == 2 (both cards charged)", _slots_used(ext2) == 2,
		str(_slots_used(ext2)))
	_expect("5: pending_transitions == 0 after both settles", _pending(ext2) == 0,
		str(_pending(ext2)))
	_expect_front(ext2, "5", both_front, 50, 50, 2)
	var both_adds: PackedFloat64Array = both_front["adds"]
	var expected_both := expect_s + expect_s
	print("[5] front add with both cards = %.17f (2 x 3277/Q16 = %.17f)"
		% [float(both_adds[0]), expected_both])
	_expect_cells(ext2, "5", both_front, expected_both)
	_expect("5: the two-card add is EXACTLY 2 x 3277/Q16 (add * 65536 == 6554)",
		int(round(float(both_adds[0]) * float(Q16_ONE)))
			== PROGRAM_MAGNITUDE_Q16 * 2,
		"add*65536=%.6f expected=%d"
			% [float(both_adds[0]) * float(Q16_ONE), PROGRAM_MAGNITUDE_Q16 * 2])
	_expect("5: the second card ADDED to the front instead of replacing it "
		+ "(A alone %.17f -> both %.17f)" % [float((a_front2["adds"]
			as PackedFloat64Array)[0]), float(both_adds[0])],
		_is_close(float(both_adds[0]),
			float((a_front2["adds"] as PackedFloat64Array)[0]) + expect_s, 1e-15),
		"a-alone=%.17f both=%.17f" % [
			float((a_front2["adds"] as PackedFloat64Array)[0]), float(both_adds[0])])
	# ---- and the Modifier residue probe is now demonstrably non-vacuous ----
	var rows2 := _country_rows(ext2, handle2)
	var journal2_a := _journal_summary(ext2, COST_DEFINITION_A)
	var journal2_b := _journal_summary(ext2, COST_DEFINITION_B)
	print("[5] country-domain Modifier rows: A(%s)=%d B(%s)=%d total=%d"
		% [COST_DEFINITION_A, int(rows2["a"]), COST_DEFINITION_B, int(rows2["b"]),
			int(rows2["count"])])
	print("[5] Modifier journal: A apply=%d  B apply=%d"
		% [int(journal2_a["apply"]), int(journal2_b["apply"])])
	_expect("5: B's cost row EXISTS once B is admitted -- exactly one country-domain "
		+ "row for its definition", int(rows2["b"]) == 1, str(rows2["keys"]))
	_expect("5: A's cost row is still exactly one", int(rows2["a"]) == 1,
		str(rows2["keys"]))
	_expect("5: the journal records an APPLY for B's definition (so the phase-4 zero "
		+ "was a real absence, not a probe that cannot see rows)",
		int(journal2_b["apply"]) >= 1, str(journal2_b))
	_expect("5: the front's contribution structure did not change when the second "
		+ "card was admitted (same 2 stats x 25 (stat,cell) pairs)",
		int(both_front["contribs"]) == int(a_front2["contribs"])
			and int(both_front["cells"]) == int(a_front2["cells"])
			and int(both_front["stats"]) == int(a_front2["stats"]),
		"a=%d/%d/%d both=%d/%d/%d" % [int(a_front2["contribs"]),
			int(a_front2["cells"]), int(a_front2["stats"]),
			int(both_front["contribs"]), int(both_front["cells"]),
			int(both_front["stats"])])

	# ---------------------------------------------------------------------
	print("")
	print("=== SUMMARY ===")
	# ---------------------------------------------------------------------
	print("  capacity                       = %d (catalog ideology_capacity / _max)" % CAPACITY_ONE)
	print("  A alone, published add          = %.17f  (3277/Q16 = %.17f)"
		% [float(published_adds[0]), expect_s])
	print("  refusal code                    = %s" % str(b_codes))
	print("  slots_used before / after       = %d / %d" % [slots_before, slots_after])
	print("  B location before / after       = %d / %d (0 = INACTIVE)"
		% [LOCATION_INACTIVE, b_location])
	print("  pending_transitions after       = %d" % _pending(ext1))
	print("  front contribs before / after   = %d / %d"
		% [int(pre_attempt_front["contribs"]), int(after_attempt_front["contribs"])])
	print("  front generation before / after = %d / %d"
		% [int(pre_attempt_front["gen"]), int(after_attempt_front["gen"])])
	print("  B Modifier rows at CAP=1        = %d" % int(post_attempt_rows["b"]))
	print("  B Modifier rows at CAP=2        = %d" % int(rows2["b"]))
	print("  CAP=2 add with both cards       = %.17f  (2 x 3277/Q16)"
		% float(both_adds[0]))
	print("")
	_finish(0 if _failures == 0 else 1)


# -- the fixture's cards --------------------------------------------------

## Appends the two test cards to the LOADED catalog resource. Nothing is written
## to disk.
##
## Both level rows are copies of SHIPPED rows (see the header), which is what
## makes the adopt emit an admissible Effect batch AND reach the derived backend
## at the same time:
##
##   * the program row is skipped by `emit_templates` (:1718-1723) because it
##     resolves to a managed program, so it contributes no Effect command -- it
##     only reaches the derived collector;
##   * the cost row does NOT resolve to a program, so it IS emitted, which is
##     what makes the transition PENDING (and therefore observable).
func _add_fixture_cards(catalog: Resource) -> void:
	for pair in [[CARD_A, COST_DEFINITION_A], [CARD_B, COST_DEFINITION_B]]:
		var definition: Resource = IdeologyDefinitionScript.new()
		definition.id = StringName(String(pair[0]))
		definition.icon_key = &"country.politics"
		definition.name_key = StringName("test %s" % String(pair[0]))
		definition.detail_key = "synthesised by ideology_capacity_exceeded_test"
		definition.school_id = &"learning"
		definition.rarity = 1
		definition.rarity_weight = 100
		definition.ideology_slot_cost = CARD_SLOT_COST
		definition.national_spirit_slot_cost = 1
		definition.acquisition_flags = 3  # DISCOVER | DRAW
		definition.national_spirit_min_level = 0
		# NO `class_stances`: `evaluate_support` short-circuits on
		# `stance_count == 0` and returns allowed BEFORE it reads the economy's
		# class-opinion snapshot (:1251-1255). That is the whole reason the ADOPT
		# gate can pass in a bootstrapped world, and phase 2 asserts it through
		# `explain_ideology` rather than assuming it.
		definition.adopt_threshold_q16 = -65536
		definition.repeal_threshold_q16 = -65536
		definition.promote_threshold_q16 = -65536
		definition.era_index = 0
		definition.copy_left_programs = false
		definition.copyable = true
		var level: Resource = IdeologyLevelDefinitionScript.new()
		level.understanding_threshold_q16 = LEVEL_THRESHOLD_Q16
		level.daily_understanding_q16 = LEVEL_DAILY_Q16
		var rows: Array[Resource] = []
		rows.append(_cost_row(String(pair[1])))
		rows.append(_program_row())
		level.persistent_effects = rows
		var levels: Array[Resource] = [level]
		definition.levels = levels
		catalog.definitions.append(definition)


## The shipped `EffectPublicHygieneCostL1` / `EffectAlgorithmicGovernanceL1`
## shape: a permanent COUNTRY-domain Modifier APPLY whose magnitude is 65536
## (1.0 in Q16), so it raises no stat it touches and only exists as a row.
func _cost_row(definition_key: String) -> Resource:
	var row: Resource = EffectCommandScript.new()
	row.action = 1            # MODIFIER_COMMAND
	row.domain = DOMAIN_COUNTRY
	row.opcode = 1            # ModifierRuntime::COMMAND_APPLY
	row.target_resolver = 1   # TARGET_INSTANCE
	row.value_mode = 0        # VALUE_CONSTANT
	row.value_q16 = Q16_ONE
	row.duration_days = -1    # permanent
	row.stacks = 1
	row.command_key = &"ideology.persistent"
	row.definition_key = StringName(definition_key)
	return row


## The shipped `EffectPublicHygieneL1R0` shape: a routing marker to the kind-12
## program. `value_mode = 1` (VALUE_STACK_TOP) and `domain = 2` (CELL) are copied
## from the authored row so the tuple matches the compiled command definition.
func _program_row() -> Resource:
	var row: Resource = EffectCommandScript.new()
	row.action = 1
	row.domain = TARGET_DOMAIN_CELL
	row.opcode = 1
	row.target_resolver = 1
	row.value_mode = 1
	row.value_q16 = Q16_ONE
	row.duration_days = -1
	row.stacks = 1
	row.command_key = &"ideology.persistent"
	row.definition_key = StringName(PROGRAM_KEY)
	return row


# -- catalog configuration -------------------------------------------------

## Fixture knobs on a COPY of the compiled catalogue (no file is touched):
##   * draw requirements are dropped (a bootstrapped world has none of the late
##     technologies the cards are authored against);
##   * the ideology slot capacity is set to `capacity` -- the knob under test --
##     and `ideology_capacity_max` with it, because :785 clamps the effective
##     capacity to that maximum;
##   * ADOPT support thresholds are floored (the fixture's own cards carry no
##     class stances and would pass anyway, but this keeps a shipped card from
##     being the reason a command is refused);
##   * SYNERGIES are emptied, so the country-level pending guard
##     (:4660-4662, `pending_transition_count > 0 && !_synergies.empty()`) is
##     skipped by its own term and a second equip is decided by the per-card and
##     capacity rules this fixture is about.
func _relaxed(native: Dictionary, capacity: int) -> Dictionary:
	var relaxed: Dictionary = native.duplicate(true)
	var count := (relaxed.get("ideology_ids", PackedStringArray()) as PackedStringArray).size()
	for pair in [
			["technology_requirement_offsets", "technology_requirements"],
			["signal_requirement_offsets", "signal_requirements"],
			["gate_requirement_offsets", "gate_requirements"]]:
		var offsets := PackedInt32Array()
		offsets.resize(count + 1)
		offsets.fill(0)
		relaxed[pair[0]] = offsets
		relaxed[pair[1]] = PackedInt32Array()
	relaxed["ideology_capacity"] = capacity
	relaxed["ideology_capacity_max"] = capacity
	var adopt := PackedInt32Array()
	adopt.resize(count)
	adopt.fill(-65536)
	relaxed["adopt_thresholds_q16"] = adopt
	var per_idea_zero := PackedInt32Array()
	per_idea_zero.resize(count + 1)
	per_idea_zero.fill(0)
	relaxed["ideology_synergy_offsets"] = per_idea_zero
	relaxed["ideology_synergy_ids"] = PackedInt32Array()
	relaxed["synergy_ids"] = PackedStringArray()
	relaxed["synergy_min_counts"] = PackedInt32Array()
	relaxed["synergy_requirement_offsets"] = PackedInt32Array([0])
	relaxed["synergy_requirement_ideology_ids"] = PackedInt32Array()
	relaxed["synergy_requirement_min_levels"] = PackedInt32Array()
	relaxed["synergy_requirement_location_masks"] = PackedByteArray()
	relaxed["synergy_effect_offsets"] = PackedInt32Array([0])
	for key in ["synergy_effect_actions", "synergy_effect_domains",
			"synergy_effect_opcodes", "synergy_effect_duration_days",
			"synergy_effect_stacks"]:
		relaxed[key] = PackedInt32Array()
	for key in ["synergy_effect_values_q16", "synergy_effect_payload_i0",
			"synergy_effect_payload_i1", "synergy_effect_payload_i2",
			"synergy_effect_payload_i3"]:
		relaxed[key] = PackedInt64Array()
	for key in ["synergy_effect_command_keys", "synergy_effect_definition_keys"]:
		relaxed[key] = PackedStringArray()
	relaxed["synergy_override_offsets"] = PackedInt32Array([0])
	relaxed["synergy_override_programs"] = PackedStringArray()
	for key in ["synergy_override_scales", "synergy_override_match_kinds",
			"synergy_override_fields", "synergy_override_values"]:
		relaxed[key] = PackedInt32Array()
	for key in ["synergy_override_match_values", "synergy_override_tag_names"]:
		relaxed[key] = PackedStringArray()
	return relaxed


## Declares `cell.settlement` (the kind-12 tag `public_hygiene_l1` filters on) as
## `cell.population >= 30`, because a bootstrapped economy has population but no
## buildings -- see ideology_mechanism_copier_school_test.gd.
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
## facts of `program`'s FIRST command.
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
		facts["command_stack_top_is_constant"] = int(command.value_mode) == 1
		facts["command_definition_resolved"] = _definition_resolved(mod_ir,
			String(command.definition_key))
		facts["command_all_terms_sum"] = _definition_all_add(mod_ir,
			String(command.definition_key))
		facts["command_stacks"] = int(command.stacks)
		facts["command_duration_days"] = int(command.duration_days)
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

## One day: the native Effect adapters, then the whole ideology day, then the
## derived drain for the SAME day.
func _tick(ext: Object, label: String) -> void:
	_day += 1
	_serve_native_adapters(ext, _day, label)
	_ideology_day(ext, _day, label)
	var drained := _drain(ext)
	_expect("%s: the derived drain for day %d reports complete"
		% [label, _day], bool(drained.get("complete", false)),
		str(drained))


## `dispatch_effect_native_modifier()` -> `run_modifier_daily(day)` ->
## `ack_effect_native_modifier()`, the sequence the settle contract requires: the
## ACK must complete BEFORE the ideology poll that turns it into a settled
## transition (:3830-3852), so the adapter pulse runs first and the day's own
## slices follow. Bounded by the Effect side's own `pending` count.
func _serve_native_adapters(ext: Object, day: int, label: String) -> Dictionary:
	var rounds := 0
	var acknowledged := 0
	var last_dispatch := {}
	var last_ack := {}
	for _i in range(8):
		rounds += 1
		ext.run_effect_daily(day)
		var dispatched: Dictionary = ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var acked: Dictionary = ext.ack_effect_native_modifier()
		ext.dispatch_effect_native_country()
		ext.ack_effect_native_country()
		last_dispatch = dispatched
		last_ack = acked
		if not bool(dispatched.get("ok", true)) or not bool(acked.get("ok", true)):
			_expect("%s: the native modifier adapters accept day %d"
				% [label, day], false,
				"dispatch=%s ack=%s" % [str(dispatched), str(acked)])
			break
		acknowledged += int(acked.get("acknowledged", 0))
		if int(acked.get("acknowledged", 0)) > 0 \
				and int(acked.get("pending", 0)) == 0:
			break
		if _pending(ext) == 0:
			break
	return {"rounds": rounds, "acknowledged": acknowledged,
		"dispatch": last_dispatch, "ack": last_ack}


## `run_ideology_daily` is a SLICE stage (`done=false` while the day, the rebuild
## or the command queue still has work), so the loop is bounded by the runtime's
## own `done` flag rather than by a guessed call count.
func _ideology_day(ext: Object, day: int, label: String) -> bool:
	for _i in range(MAX_DAY_SLICES):
		var ran: Dictionary = ext.run_ideology_daily(day)
		if not bool(ran.get("ok", true)):
			_expect("%s: ideology day %d reports ok" % [label, day], false, str(ran))
			return false
		if bool(ran.get("done", false)):
			return true
	_expect("%s: ideology day %d completes within %d slices"
		% [label, day, MAX_DAY_SLICES], false, "never reported done")
	return false


## `drain_derived_cell_layer(day)` drives `step_derived_rebuild(day)`, which
## refuses any day before the confirmed projection's eligibility day
## (:7220-7231) -- so the CURRENT day is passed. `0` would be a silent no-op
## once anything has confirmed.
func _drain(ext: Object) -> Dictionary:
	if not ext.has_method("drain_derived_cell_layer"):
		return {"ok": false, "complete": false, "reason": "binding_missing"}
	return ext.drain_derived_cell_layer(_day)


func _submit_op(ext: Object, op: int, idea: int, value_q16: int, label: String) -> int:
	_seq += 1
	var batch := {
		"opcodes": PackedInt32Array([op]),
		"effective_days": PackedInt64Array([_day]),
		"source_priorities": PackedInt32Array([0]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([_seq]),
		"country_handles": PackedInt64Array([_handle(ext)]),
		"ideology_ids": PackedInt32Array([idea]),
		"values_q16": PackedInt64Array([value_q16]),
		"offer_generations": PackedInt64Array([0]),
		"choice_indices": PackedInt32Array([-1]),
		"gate_ids": PackedInt32Array([-1]),
	}
	var result: Dictionary = ext.submit_ideology_commands(batch)
	_expect("%s: command seq %d (opcode %d) is admitted by the queue"
		% [label, _seq, op], bool(result.get("ok", false))
			and int(result.get("accepted", 0)) == 1, str(result))
	return _seq


## Submits the equip, then watches it through the whole transition:
##   * one tick applies the command (the transition starts here, still pending);
##   * the pending window is measured (§10.1);
##   * further ticks run the handshake and the poll until `pending == 0`.
## The returned dictionary carries every reading the caller asserts on, so no
## assertion has to re-derive a day number.
func _equip_card(ext: Object, dense: int, label: String) -> Dictionary:
	var handle := _handle(ext)
	var request_day := _day
	var before_location := _location_of(ext, handle, dense)
	var before_slots := _slots_used(ext)
	var sequence := _submit_op(ext, OP_EQUIP, dense, 0, label)
	_tick(ext, "%s/apply" % label)
	var pending_at_request := _pending(ext)
	var transition_byte := _transition_byte(ext, handle, dense)
	var transaction_statuses := _transition_transaction_statuses(ext, handle, dense)
	var after_location := _location_of(ext, handle, dense)
	var after_slots := _slots_used(ext)
	var pending_front := _measure(ext, "%s/pending" % label)
	var settle_days := 0
	while _pending(ext) != 0 and settle_days < MAX_SETTLE_DAYS:
		_tick(ext, "%s/settle" % label)
		settle_days += 1
	var settle_front := _measure(ext, "%s/settle-day" % label)
	return {
		"dense": dense, "sequence": sequence, "request_day": request_day,
		"before_location": before_location, "before_slots": before_slots,
		"pending_at_request": pending_at_request,
		"transition_pending_byte": transition_byte,
		"transaction_statuses": transaction_statuses,
		"location_after_request": after_location,
		"slots_after_request": after_slots,
		"pending_front": pending_front,
		"settle_days": settle_days, "settle_day": _day,
		"pending_after": _pending(ext),
		"settle_front": settle_front,
		"receipts": _receipts_for(ext, sequence),
	}


# -- measurement ----------------------------------------------------------

## Reads the derived front's own slice of one stat on every probe cell, plus the
## bookkeeping that makes the read non-vacuous: the front's shape, its
## generation, and the rebuild counter that says whether the day looked at all.
func _measure(ext: Object, label: String) -> Dictionary:
	var front: Dictionary = ext.get_derived_cell_layer_report()
	var report: Dictionary = ext.get_ideology_report()
	var adds := PackedFloat64Array()
	var values := PackedFloat64Array()
	var present := PackedByteArray()
	var present_sum := 0
	for cell in PROBE_CELLS:
		# entity_handle MUST be 0 and the CELL goes in the group slot: that is the
		# pair the production reader uses.
		var probe: Dictionary = ext.get_effective_stat_value(PROGRAM_STAT, int(cell), 0,
			1.0)
		var is_present := bool(probe.get("derived_present", false))
		present.append(1 if is_present else 0)
		if is_present:
			present_sum += 1
		adds.append(float(probe.get("derived_add", 0.0)))
		values.append(float(probe.get("value", 0.0)))
	print("[%s] derived_add %s" % [label, _adds_text(adds)])
	print("[%s] front installed=%s stats=%s cells=%s contributions=%s gen=%d "
		% [label, str(front.get("installed", "?")),
			str(front.get("stat_count", "?")), str(front.get("cell_count", "?")),
			str(front.get("contribution_count", "?")),
			int(front.get("layer_generation", -1))]
		+ "sample_day=%s rebuilds=%d pending=%d present=%d"
		% [str(front.get("sample_day", "?")),
			int(report.get("cell_layer_rebuild_visits", -1)), _pending(ext),
			present_sum])
	return {
		"adds": adds, "values": values, "present": present,
		"present_sum": present_sum,
		"gen": int(front.get("layer_generation", -1)),
		"installed": bool(front.get("installed", false)),
		"cells": int(front.get("cell_count", -1)),
		"contribs": int(front.get("contribution_count", -1)),
		"stats": int(front.get("stat_count", -1)),
		"sample_day": int(front.get("sample_day", -1)),
		"rebuilds": int(report.get("cell_layer_rebuild_visits", -1)),
	}


## The front must really be there and really cover the territory. Without this, a
## comparison between two absences would pass as evidence.
func _expect_front(ext: Object, label: String, measured: Dictionary,
		want_cells: int, want_contribs: int, want_stats: int) -> void:
	_expect("%s: the derived front is installed" % label,
		bool(measured.get("installed", false)), str(measured.get("installed")))
	_expect("%s: the front covers %d (stat,cell) pairs (2 stats x 25 owned cells)"
		% [label, want_cells], int(measured["cells"]) == want_cells,
		str(measured["cells"]))
	_expect("%s: the front holds %d contributions" % [label, want_contribs],
		int(measured["contribs"]) == want_contribs, str(measured["contribs"]))
	_expect("%s: the front holds %d stats" % [label, want_stats],
		int(measured["stats"]) == want_stats, str(measured["stats"]))
	var all_present := true
	for flag in (measured["present"] as PackedByteArray):
		all_present = all_present and int(flag) == 1
	_expect("%s: every probe cell carries a derived row for %s"
		% [label, PROGRAM_STAT], all_present, str(measured["present"]))


## Every probe cell must show the SAME add. A selector that covered only some
## cells would satisfy a single-cell assertion by accident.
func _expect_cells(ext: Object, label: String, measured: Dictionary,
		expected: float) -> void:
	var adds: PackedFloat64Array = measured["adds"]
	var all_ok := adds.size() == PROBE_CELLS.size()
	for index in range(adds.size()):
		all_ok = all_ok and _is_close(float(adds[index]), expected, 1e-15)
	_expect("%s: all %d probe cells read the same add %.17f"
		% [label, PROBE_CELLS.size(), expected], all_ok,
		"%s (expected %.17f)" % [_adds_text(adds), expected])


# -- readers --------------------------------------------------------------

func _handle(ext: Object) -> int:
	return int(ext.get_country_cell_summary(0).get("country_handle", 0))


func _snapshot(ext: Object, handle: int) -> Dictionary:
	return ext.get_ideology_snapshot(handle)


func _report(ext: Object) -> Dictionary:
	return ext.get_ideology_report()


func _pending(ext: Object) -> int:
	return int(_report(ext).get("pending_transitions", -1))


func _rejected(ext: Object) -> int:
	return int(_report(ext).get("commands_rejected", -1))


func _applied(ext: Object) -> int:
	return int(_report(ext).get("commands_applied", -1))


func _advanced(ext: Object) -> int:
	return int(_report(ext).get("levels_advanced", -1))


func _slots_used(ext: Object) -> int:
	return int(_snapshot(ext, _handle(ext)).get("ideology_slots_used", -1))


func _slots_capacity(ext: Object) -> int:
	return int(_snapshot(ext, _handle(ext)).get("ideology_slots_capacity", -1))


func _locations(ext: Object, handle: int) -> String:
	return str(_snapshot(ext, handle).get("locations", PackedInt32Array()))


func _index_of(ext: Object, handle: int, dense: int) -> int:
	var idea_ids: PackedInt32Array = _snapshot(ext, handle).get(
		"idea_ids", PackedInt32Array())
	return idea_ids.find(dense)


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


## The per-idea `transition_pending` flag, which is the card's own transition
## state rather than the country's aggregate.
func _transition_byte(ext: Object, handle: int, dense: int) -> int:
	var fields: Dictionary = _snapshot(ext, handle)
	var flags: PackedByteArray = fields.get("transition_pending", PackedByteArray())
	var index := _index_of(ext, handle, dense)
	if index < 0 or index >= flags.size():
		return -1
	return int(flags[index])


## The Effect transaction statuses of that card's in-flight transition.
func _transition_transaction_statuses(ext: Object, handle: int, dense: int) -> PackedInt32Array:
	var fields: Dictionary = _snapshot(ext, handle)
	var offsets: PackedInt32Array = fields.get(
		"transition_transaction_offsets", PackedInt32Array())
	var statuses: PackedInt32Array = fields.get(
		"transition_transaction_statuses", PackedInt32Array())
	var index := _index_of(ext, handle, dense)
	var out := PackedInt32Array()
	if index < 0 or index + 1 >= offsets.size():
		return out
	var begin := int(offsets[index])
	var end := int(offsets[index + 1])
	for row in range(begin, mini(end, statuses.size())):
		out.append(int(statuses[row]))
	return out


func _receipts_for(ext: Object, sequence: int) -> Array:
	var polled: Dictionary = ext.poll_ideology_receipts(0, 4096)
	var sequences: PackedInt64Array = polled.get("sequences", PackedInt64Array())
	var statuses: PackedInt32Array = polled.get("statuses", PackedInt32Array())
	var opcodes: PackedInt32Array = polled.get("opcodes", PackedInt32Array())
	var days: PackedInt64Array = polled.get("settled_days", PackedInt64Array())
	var ideas: PackedInt32Array = polled.get("ideology_ids", PackedInt32Array())
	var reasons: PackedStringArray = polled.get("reasons", PackedStringArray())
	var out := []
	for i in range(sequences.size()):
		if int(sequences[i]) != sequence:
			continue
		out.append({
			"status": int(statuses[i]) if i < statuses.size() else -1,
			"opcode": int(opcodes[i]) if i < opcodes.size() else -1,
			"day": int(days[i]) if i < days.size() else -1,
			"idea": int(ideas[i]) if i < ideas.size() else -1,
			"reason": String(reasons[i]) if i < reasons.size() else "",
		})
	return out


func _receipt_text(receipts: Array) -> String:
	var parts := PackedStringArray()
	for receipt in receipts:
		parts.append("{status=%d opcode=%d day=%d idea=%d reason='%s'}"
			% [int(receipt["status"]), int(receipt["opcode"]), int(receipt["day"]),
				int(receipt["idea"]), String(receipt["reason"])])
	return "[%s]" % ", ".join(parts)


## LIVE COUNTRY-domain Modifier rows, counted per definition key. The two cards
## use different definitions, so a count of 1 is attributable to the card that
## wrote it -- which is what makes "zero rows for B" a measurement.
func _country_rows(ext: Object, handle: int) -> Dictionary:
	var rows: Dictionary = ext.list_modifiers(DOMAIN_COUNTRY, handle, "")
	var keys: PackedStringArray = PackedStringArray()
	if bool(rows.get("ok", false)):
		keys = rows.get("definition_keys", PackedStringArray())
	var a_count := 0
	var b_count := 0
	for key in keys:
		if String(key) == COST_DEFINITION_A:
			a_count += 1
		elif String(key) == COST_DEFINITION_B:
			b_count += 1
	return {"ok": bool(rows.get("ok", false)), "keys": keys, "count": keys.size(),
		"a": a_count, "b": b_count}


## Every live row in every Modifier domain, so "the store did not grow" is not
## scoped to one domain.
func _all_modifier_rows(ext: Object) -> int:
	var total := 0
	for domain in range(MODIFIER_DOMAIN_COUNT):
		var rows: Dictionary = ext.list_modifiers(domain, 0, "")
		if not bool(rows.get("ok", false)):
			return -1
		total += (rows.get("definition_keys", PackedStringArray()) as PackedStringArray).size()
	return total


## The Modifier journal, summarised for one definition: how many APPLY and how
## many REJECT removal events it has. `EVENT_REJECT` is what a rollback through
## `remove_rows_for_source` journals, so a refused batch that had committed rows
## would show up here even if the store were cleaned up.
func _journal_summary(ext: Object, definition_key: String) -> Dictionary:
	var events: Dictionary = ext.poll_modifier_events(0, 512)
	var keys: PackedStringArray = events.get("definition_keys", PackedStringArray())
	var kinds: PackedInt32Array = events.get("kinds", PackedInt32Array())
	var apply := 0
	var reject := 0
	for i in range(keys.size()):
		if String(keys[i]) != definition_key:
			continue
		var kind := int(kinds[i]) if i < kinds.size() else -1
		if kind == EVENT_APPLY:
			apply += 1
		elif kind == EVENT_REJECT:
			reject += 1
	return {"apply": apply, "reject": reject,
		"overflow": int(events.get("journal_overflow", -1))}


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
		_expect("%s: the economy bootstraps" % tag, bool(eb.get("ok", false)), str(eb))
		for s in range(512):
			if bool(ext.run_economy_slice(
					{"day_index": 0, "tick_index": s}).get("done", false)):
				break
	if _probe_host == null:
		_probe_host = ext
	return ext


# -- misc -----------------------------------------------------------------

func _adds_text(adds: PackedFloat64Array) -> String:
	var parts := PackedStringArray()
	for index in range(adds.size()):
		parts.append("%d:%.17f" % [int(PROBE_CELLS[index]), float(adds[index])])
	return ", ".join(parts)


## Bit-identical, not "close": the residue claim is that nothing moved.
func _adds_identical(left: PackedFloat64Array, right: PackedFloat64Array) -> bool:
	if left.size() != right.size():
		return false
	for index in range(left.size()):
		if float(left[index]) != float(right[index]):
			return false
	return true


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
	print("=== ideology capacity exceeded: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code)
