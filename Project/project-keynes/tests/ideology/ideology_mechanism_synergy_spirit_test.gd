extends SceneTree

## Evidence for plan section 18.1: synergy and national-spirit promotion.
##
## Both mechanisms are policy-free here: no support/opinion gate is involved, and
## every expected number is READ OUT of a compiled catalog or out of the authored
## Resource, never restated as a literal. The two rules under test:
##
## SYNERGY (gdext/src/ideology_runtime.cpp:1380-1405 `synergy_requirements_met`)
##   A synergy owns a slice of the flat requirement table
##   (`synergy_requirement_offsets/ideology_ids/min_levels/location_masks`). A row is
##   HELD when that card's IdeaState exists, `state.level >= minimum_level`, and
##   `location_mask & (1u << state.location)` is non-zero. `needed` is the authored
##   `min_count` when positive, otherwise the whole slice; `held >= needed` is the
##   activation predicate. Location values are INACTIVE=0, IDEOLOGY=1,
##   NATIONAL_SPIRIT=2, and the validator only admits masks in {2,4,6}
##   (:517-518): mask 6 is "either active slot", i.e. a promoted card still counts.
##
##   `collect_affected_synergies` (:1407-1483) is the ONLY place the activation bit
##   moves. It walks the reverse index (`ideology_synergy_offsets/ids`, one cursor per
##   card), bumps `_synergy_candidates_visited` once per candidate (:1438), and only
##   when the bit CHANGES does it emit effect commands: `templ.opcode` when turning on,
##   a hard-coded 2 (REMOVE) when turning off (:1472). That is what makes the effect
##   reversible and is what this fixture measures from both sides.
##
##   Because the bit is recomputed only inside a transition, and because a country may
##   only run one transition at a time when any synergy is compiled (:4550 equip,
##   :4576 unequip, :4593 promote, :3817 level-up), each step here must settle
##   completely before the next command is submitted.
##
## SPIRIT PROMOTION (gdext/src/ideology_runtime.cpp:4590-4616 `promote`)
##   Order of refusals:
##     1. `known()` else `ideology_unknown`;
##     2. another transition pending and synergies exist -> `ideology_country_transition_pending`;
##     3. `state->location != IDEOLOGY` -> `ideology_promotion_requires_equipped` (:4600-4602);
##     4. `state->level < definition.min_spirit_level` (column `national_spirit_min_levels`)
##        -> `ideology_national_spirit_level_insufficient` (:4605);
##     5. `spirit_slots_used + definition.spirit_cost > spirit_capacity_for(slot)`
##        (column `spirit_slot_costs`, capacity = `national_spirit_capacity` plus
##        `capacity_unlock_spirit_deltas` for owned technologies, :3840-3848)
##        -> `national_spirit_slot_capacity_exceeded` (:4606-4609);
##     6. the promote support gate (disabled in this fixture, see `_support_gate_off`).
##   On success `start_transition(..., NATIONAL_SPIRIT, ...)` relocates the card (:4612),
##   and `set_state_location` (:1542-1560) subtracts `ideology_cost` from the ideology
##   slot ledger and adds `spirit_cost` to the spirit ledger. Persistent Effect rows are
##   replaced at the SAME level, so the card keeps working after the move.
##
## What this file deliberately does NOT claim:
##   * synergy effect rows are country-scope (`domain = 1`), so "the per-cell value"
##     of a synergy is not a cell reading: the measured value is the country stat the
##     authored modifier definition names, read through `evaluate_modifier_stat`. The
##     cell clause of a card is a separate `domain = 2` program and is out of scope.
##   * the opinion/support gate is cleared, so this proves the state machine, not the
##     political price of promoting.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const CELLS := 12
const Q16_ONE := 65536
## `ModifierRuntime::COUNTRY`; the entity handle for a `domain = 1` row is the
## country handle (see the fixture note in ideology_card_content_test.gd).
const MODIFIER_DOMAIN_COUNTRY := 1
## `NativeIdeologyRuntime::ReceiptStatus`.
const RECEIPT_SETTLED := 2
const RECEIPT_REJECTED := 3
## `NativeIdeologyRuntime` command opcodes (`ideology_catalog.gd` / runtime header).
const OP_DISCOVER := 1
const OP_EQUIP := 5
const OP_UNEQUIP := 6
const OP_PROMOTE := 7
const OP_ADD_UNDERSTANDING := 8
## `RuntimeIdeologyPodLocation`.
const LOCATION_INACTIVE := 0
const LOCATION_IDEOLOGY := 1
const LOCATION_NATIONAL_SPIRIT := 2
## `IdeologySynergyDefinition.location_masks` bits.
const MASK_IDEOLOGY := 2
const MASK_NATIONAL_SPIRIT := 4

## --- The authored content this fixture selects ---------------------------------
## A named two-card bond: `synergy.granary_records` requires exactly these two cards
## at minimum level 0, and its effect is a single country modifier definition.
const SYNERGY_KEY := "synergy.granary_records"
const CARD_A := "idea.collective_stewardship"
const CARD_B := "idea.scholar_office"
## A third card used only for the `min_count` half of the rule: it shares a school
## with CARD_A, so pairing them reaches the resonance tier that needs two members.
const CARD_C := "idea.terrace_farming"
## Stat keys named by the synergy / resonance modifier definitions. Asserted to be
## untouched by the cards' OWN rows, so a difference between the two sides of each
## A/B pair is attributable to the synergy and not to the cards.
const STAT_DROUGHT := "country.climate.drought_loss_factor"
const STAT_PLAIN_AGRICULTURE := "country.output.terrain.plain.agriculture_factor"
const STAT_AGRICULTURE := "country.output.agriculture_factor"
const STAT_TRADE_CAPACITY := "country.trade.capacity_factor"

## Floor for the check count: a GDScript error makes a function return null and the
## caller carries on, which would otherwise print a green summary over an empty body.
## This is not hypothetical: an Int32/Int64 column mix-up in day 10 aborted that phase
## and still printed "0 failures", which is exactly what this floor exists to catch.
## The full run measures 144; raise the floor when assertions are added, never lower it.
const MIN_CHECKS := 144

var _checks := 0
var _failures := 0
## Measured defects that are NOT assertions: they print a `[FINDING]` line every run
## so the log carries the evidence, and the summary stays green because an assertion
## would pin the broken value instead of the contract. See `_phase_world` day 10.
var _findings := 0
var _next_sequence := 1
var _country_ir: Dictionary = {}
var _ideology_ir: Dictionary = {}
var _effect_ir: Dictionary = {}
var _ideology_catalog: Resource = null
var _modifier_catalog: Resource = null
var _dense: Dictionary = {}


func _stage(text: String) -> void:
	printerr("[stage] %s" % text)


func _finding(label: String, detail: String) -> void:
	_findings += 1
	printerr("[FINDING] %s (%s)" % [label, detail])


func _init() -> void:
	_run()
	if _checks < MIN_CHECKS:
		push_error("[FAIL] only %d checks ran; expected at least %d"
			% [_checks, MIN_CHECKS])
		_failures += 1
	print("=== ideology mechanism synergy+spirit: %d checks, %d failures ==="
		% [_checks, _failures])
	if _findings > 0:
		print("[findings] %d measured defect(s) reported above; see [FINDING] lines"
			% _findings)
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_stage("start")
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not _require("country catalog compiles",
			bool(_country_ir.get("ok", false))):
		return
	_ideology_catalog = IdeologyCatalogScript.load_default()
	if not _require("production ideology catalog loads", _ideology_catalog != null):
		return
	_ideology_ir = _ideology_catalog.compile_native_catalog(_country_ir, _country_ir)
	if not _require("production ideology catalog compiles",
			bool(_ideology_ir.get("ok", false)),
			String(_ideology_ir.get("reason", ""))):
		return
	_stage("ideology catalog compiled")
	var domain: Resource = EffectDomainCatalogScript.build()
	if not _require("effect domain catalog builds", domain != null):
		return
	_effect_ir = domain.compile_native_catalog()
	if not _require("effect catalog compiles",
			bool(_effect_ir.get("ok", false)),
			String(_effect_ir.get("reason", ""))):
		return
	_effect_ir.erase("ok")
	_modifier_catalog = ModifierCatalogScript.load_default()
	if not _require("modifier catalog loads", _modifier_catalog != null):
		return
	_stage("effect + modifier catalogs ready")
	if not _resolve_cards():
		return

	_phase_catalog_rules()
	_phase_world()
	_phase_capacity_unlocks()


# --------------------------------------------------------------------------- #
# 0. Catalog contract: the numbers every later assertion is derived from.
# --------------------------------------------------------------------------- #
func _resolve_cards() -> bool:
	var ids: PackedStringArray = _ideology_ir["ideology_ids"]
	_dense = {CARD_A: ids.find(CARD_A), CARD_B: ids.find(CARD_B),
		CARD_C: ids.find(CARD_C)}
	var ok := true
	for key in _dense:
		ok = _require("card %s is in the compiled catalog" % key,
			int(_dense[key]) >= 0, "index=%d" % int(_dense[key])) and ok
	var synergy_ids: PackedStringArray = _ideology_ir["synergy_ids"]
	_dense["__synergy"] = synergy_ids.find(SYNERGY_KEY)
	ok = _require("synergy %s is in the compiled catalog" % SYNERGY_KEY,
		int(_dense["__synergy"]) >= 0,
		"synergy count=%d" % synergy_ids.size()) and ok
	return ok


func _phase_catalog_rules() -> void:
	var synergy := int(_dense["__synergy"])
	var a := int(_dense[CARD_A])
	var b := int(_dense[CARD_B])
	var requirement_offsets: PackedInt32Array = _ideology_ir[
		"synergy_requirement_offsets"]
	var requirement_ids: PackedInt32Array = _ideology_ir[
		"synergy_requirement_ideology_ids"]
	var requirement_levels: PackedInt32Array = _ideology_ir[
		"synergy_requirement_min_levels"]
	var requirement_masks: PackedByteArray = _ideology_ir[
		"synergy_requirement_location_masks"]
	var effect_offsets: PackedInt32Array = _ideology_ir["synergy_effect_offsets"]
	var effect_domains: PackedInt32Array = _ideology_ir["synergy_effect_domains"]
	var effect_opcodes: PackedInt32Array = _ideology_ir["synergy_effect_opcodes"]
	var effect_values: PackedInt64Array = _ideology_ir[
		"synergy_effect_values_q16"]
	var effect_durations: PackedInt32Array = _ideology_ir[
		"synergy_effect_duration_days"]
	var effect_stacks: PackedInt32Array = _ideology_ir["synergy_effect_stacks"]
	var effect_keys: PackedStringArray = _ideology_ir[
		"synergy_effect_definition_keys"]
	var min_counts: PackedInt32Array = _ideology_ir["synergy_min_counts"]
	var begin := int(requirement_offsets[synergy])
	var end := int(requirement_offsets[synergy + 1])
	var rows := end - begin
	print("[phase 0] synergy=%d rows=%d effects=%d..%d min_count=%d"
		% [synergy, rows, int(effect_offsets[synergy]),
			int(effect_offsets[synergy + 1]), int(min_counts[synergy])])

	# --- SYNERGY: the requirement table is exactly the authored pair ----------
	_expect("catalog: granary_records requires exactly two cards", rows == 2,
		"rows=%d" % rows)
	var held := PackedInt32Array()
	for row in range(begin, end):
		held.append(int(requirement_ids[row]))
	_expect("catalog: the two requirements are collective_stewardship and scholar_office",
		held == PackedInt32Array([a, b]) or held == PackedInt32Array([b, a]),
		"rows=%s expected=[%d,%d]" % [str(held), a, b])
	var all_zero := true
	var all_either_slot := true
	for row in range(begin, end):
		if int(requirement_levels[row]) != 0:
			all_zero = false
		var mask := int(requirement_masks[row])
		if mask != (MASK_IDEOLOGY | MASK_NATIONAL_SPIRIT):
			all_either_slot = false
	_expect("catalog: both requirements are authored at minimum level 0", all_zero,
		str(requirement_levels.slice(begin, end)))
	# Mask 6 is what lets the bond survive a promotion; mask 2 would silently drop it.
	_expect("catalog: both requirements accept either active slot (mask 6)",
		all_either_slot, str(requirement_masks.slice(begin, end)))
	_expect("catalog: the named pair needs ALL of its rows (min_count 0 = all-of)",
		int(min_counts[synergy]) == 0, "min_count=%d" % int(min_counts[synergy]))

	# --- SYNERGY: its effect rows are reversible country modifier commands ----
	var effect_begin := int(effect_offsets[synergy])
	var effect_end := int(effect_offsets[synergy + 1])
	_expect("catalog: the bond carries at least one effect row",
		effect_end > effect_begin, "rows=%d" % (effect_end - effect_begin))
	var reversible := true
	var country_scope := true
	var unit_magnitude := true
	var single_stack := true
	var definition_key := ""
	for row in range(effect_begin, effect_end):
		if int(effect_opcodes[row]) != 1 or int(effect_durations[row]) != -1:
			reversible = false
		if int(effect_domains[row]) != MODIFIER_DOMAIN_COUNTRY:
			country_scope = false
		if int(effect_values[row]) != Q16_ONE:
			unit_magnitude = false
		if int(effect_stacks[row]) != 1:
			single_stack = false
		definition_key = String(effect_keys[row])
	_expect("catalog: every effect row is an apply of a permanent modifier",
		reversible)
	_expect("catalog: every effect row targets the country domain", country_scope,
		"domains=%s" % str(effect_domains.slice(effect_begin, effect_end)))
	# Magnitude 1.0 and one stack: the strength lives in the modifier definition's
	# terms only, which is why the expected value below can be computed from the
	# definition alone.
	_expect("catalog: every effect row fires at magnitude 1.0", unit_magnitude,
		"values=%s" % str(effect_values.slice(effect_begin, effect_end)))
	_expect("catalog: every effect row carries a single stack", single_stack,
		"stacks=%s" % str(effect_stacks.slice(effect_begin, effect_end)))
	var synergy_definition := _definition(_modifier_catalog, definition_key)
	_expect("catalog: the effect names a modifier definition that exists",
		synergy_definition != null, definition_key)

	# --- SYNERGY: the expected stat values come from the definition's terms ---
	if synergy_definition != null:
		var drought_terms := _term_count(synergy_definition, STAT_DROUGHT)
		var plain_terms := _term_count(synergy_definition, STAT_PLAIN_AGRICULTURE)
		_expect("catalog: the definition modifies the drought-loss factor once",
			drought_terms == 1, "terms=%d" % drought_terms)
		_expect("catalog: the definition modifies plain agriculture once",
			plain_terms == 1, "terms=%d" % plain_terms)
		var expected_drought := _stat_value(synergy_definition, STAT_DROUGHT, 1.0)
		var expected_plain := _stat_value(synergy_definition,
			STAT_PLAIN_AGRICULTURE, 1.0)
		print("[phase 0] catalog expectation: %s=%.5f %s=%.5f"
			% [STAT_DROUGHT, expected_drought, STAT_PLAIN_AGRICULTURE,
				expected_plain])
		# A CHECK THAT DISCRIMINATES: the bond's own factor must be far enough from
		# the identity that "no effect" cannot be confused with "effect applied".
		_expect("catalog: the bond's drought factor is distinguishable from identity",
			absf(expected_drought - 1.0) > 0.01, "%.5f" % expected_drought)
		_expect("catalog: the bond's plain-agriculture factor is distinguishable from identity",
			absf(expected_plain - 1.0) > 0.01, "%.5f" % expected_plain)
	# The cards' OWN rows must not touch the stats the bond is measured on, or the
	# A/B pairs below would prove nothing. This is the control for the whole file.
	for card_key in [CARD_A, CARD_B, CARD_C]:
		var card: Resource = _card_resource(card_key)
		if not _require("catalog: %s resolves to an authored Resource" % card_key,
				card != null):
			continue
		for stat in [STAT_DROUGHT, STAT_PLAIN_AGRICULTURE, STAT_AGRICULTURE]:
			var touched := 0
			for definition_key_row in _card_modifier_keys(card):
				var row_definition := _definition(_modifier_catalog,
					definition_key_row)
				if row_definition != null:
					touched += _term_count(row_definition, stat)
			_expect("catalog: %s's own rows leave %s untouched" % [card_key, stat],
				touched == 0, "terms=%d" % touched)
	# ... while the card's own row really is a live modifier definition, so the
	# "untouched" results above are not an artefact of a card with no rows at all.
	_expect("catalog: %s's own row targets %s (the control card)"
		% [CARD_A, STAT_TRADE_CAPACITY],
		_term_count(_definition(_modifier_catalog, _card_modifier_key_for(CARD_A)),
			STAT_TRADE_CAPACITY) == 1,
		"key=%s" % _card_modifier_key_for(CARD_A))
	_expect("catalog: %s declares at least one country-scope row" % CARD_B,
		_card_modifier_keys(_card_resource(CARD_B)).size() >= 1)

	# --- SPIRIT: the authored level gate and slot prices ----------------------
	var spirit_levels: PackedInt32Array = _ideology_ir["national_spirit_min_levels"]
	var spirit_costs: PackedInt32Array = _ideology_ir["spirit_slot_costs"]
	var ideology_costs: PackedInt32Array = _ideology_ir["ideology_slot_costs"]
	for card_key in [CARD_A, CARD_B]:
		var card: Resource = _card_resource(card_key)
		var index := int(_dense[card_key])
		_expect("catalog: %s compiles its authored spirit level gate" % card_key,
			int(spirit_levels[index]) == int(card.national_spirit_min_level),
			"compiled=%d authored=%d" % [int(spirit_levels[index]),
				int(card.national_spirit_min_level)])
		_expect("catalog: %s compiles its authored spirit slot cost" % card_key,
			int(spirit_costs[index]) == int(card.national_spirit_slot_cost),
			"compiled=%d authored=%d" % [int(spirit_costs[index]),
				int(card.national_spirit_slot_cost)])
		_expect("catalog: %s compiles its authored ideology slot cost" % card_key,
			int(ideology_costs[index]) == int(card.ideology_slot_cost),
			"compiled=%d authored=%d" % [int(ideology_costs[index]),
				int(card.ideology_slot_cost)])
	var gate := int(spirit_levels[int(_dense[CARD_A])])
	print("[phase 0] spirit gate: %s needs level >= %d, costs %d ideology / %d spirit"
		% [CARD_A, gate, int(ideology_costs[int(_dense[CARD_A])]),
			int(spirit_costs[int(_dense[CARD_A])])])
	# The gate has to be reachable inside a three-level card, and it must be BINDING:
	# a gate of 0 would make the "below the gate" half of this file untestable.
	_expect("catalog: the spirit gate is a real level above the adoption level",
		gate >= 1, "gate=%d" % gate)

	# --- SPIRIT: the capacity table ------------------------------------------
	var profile: Resource = _ideology_catalog.profile
	var base_spirit := int(profile.national_spirit_capacity)
	var max_spirit := maxi(base_spirit, int(profile.national_spirit_capacity_max))
	var deltas: PackedInt32Array = profile.capacity_unlock_spirit_deltas
	var total := 0
	for delta in deltas:
		total += int(delta)
	print("[phase 0] spirit capacity base=%d max=%d unlock deltas=%s (sum=%d)"
		% [base_spirit, max_spirit, str(deltas), total])
	_expect("catalog: the spirit unlocks can reach the declared capacity max",
		base_spirit + total >= max_spirit,
		"base=%d sum=%d max=%d" % [base_spirit, total, max_spirit])
	_expect("catalog: at least one technology carries a spirit delta", total > 0,
		"sum=%d" % total)
	# The compiled catalog must agree with the authored profile, otherwise the
	# capacity worlds below would be measuring a different table.
	var compiled_deltas: PackedInt32Array = _ideology_ir[
		"capacity_unlock_spirit_deltas"]
	_expect("catalog: compiled spirit deltas equal the authored profile",
		compiled_deltas == deltas, "compiled=%s authored=%s"
			% [str(compiled_deltas), str(deltas)])


# --------------------------------------------------------------------------- #
# 1. One world: synergy on both sides, then spirit promotion with every guard.
# --------------------------------------------------------------------------- #
func _phase_world() -> void:
	_stage("world: building")
	var world := _build_world(PackedStringArray(["tech.hunting"]))
	if world.is_empty():
		return
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var a := int(_dense[CARD_A])
	var b := int(_dense[CARD_B])
	var c := int(_dense[CARD_C])
	var synergy := int(_dense["__synergy"])
	var spirit_levels: PackedInt32Array = _ideology_ir["national_spirit_min_levels"]
	var spirit_costs: PackedInt32Array = _ideology_ir["spirit_slot_costs"]
	var ideology_costs: PackedInt32Array = _ideology_ir["ideology_slot_costs"]
	var gate := int(spirit_levels[a])

	# ---------------- day 0: discover, baseline, no synergy active -----------
	_stage("world d0 discover")
	var day := 0
	_submit(ext, day, [{"op": OP_DISCOVER, "idea": a},
		{"op": OP_DISCOVER, "idea": b}, {"op": OP_DISCOVER, "idea": c}])
	_expect("world: discover batch settles", _settle(ext, day))
	var snap := _snapshot(ext, handle)
	_expect("world: all three cards are known",
		_frame(snap, "known_ids", -1).size() >= 3)
	var drought := _read(ext, handle, STAT_DROUGHT)
	var plain := _read(ext, handle, STAT_PLAIN_AGRICULTURE)
	var agriculture := _read(ext, handle, STAT_AGRICULTURE)
	print("[phase 1] baseline: drought=%.5f plain=%.5f agriculture=%.5f slots=%d/%d spirit=%d/%d active=%s"
		% [drought, plain, agriculture, int(snap["ideology_slots_used"]),
			int(snap["ideology_slots_capacity"]),
			int(snap["national_spirit_slots_used"]),
			int(snap["national_spirit_slots_capacity"]),
			str(snap["active_synergy_ids"])])
	_expect("world: the baseline reads the identity factor (drought)",
		_is_close(drought, 1.0, 0.000001), "%.6f" % drought)
	_expect("world: the baseline reads the identity factor (plain agriculture)",
		_is_close(plain, 1.0, 0.000001), "%.6f" % plain)
	_expect("world: no synergy is active before any card is equipped",
		_active_ids(snap).find(synergy) < 0, str(snap["active_synergy_ids"]))

	# ---------------- day 1: SPIRIT GUARD 1, nothing equipped ----------------
	_stage("world d1 promote-without-equip")
	day = 1
	var cursor := _receipt_cursor(ext)
	_submit(ext, day, [{"op": OP_PROMOTE, "idea": a}])
	_settle(ext, day)
	var guard_one := _last_receipt(ext, cursor, OP_PROMOTE, a)
	print("[phase 2] promote with no equipped idea: status=%d reason=%s"
		% [int(guard_one.get("status", 0)), String(guard_one.get("reason", ""))])
	_expect("spirit guard: promotion of a discovered but NOT equipped card is refused",
		int(guard_one.get("status", 0)) == RECEIPT_REJECTED,
		str(guard_one))
	_expect("spirit guard: the refusal names ideology_promotion_requires_equipped",
		String(guard_one.get("reason", "")) == "ideology_promotion_requires_equipped",
		String(guard_one.get("reason", "")))
	snap = _snapshot(ext, handle)
	_expect("spirit guard: a refused promotion leaves both slot ledgers at zero",
		int(snap["ideology_slots_used"]) == 0
			and int(snap["national_spirit_slots_used"]) == 0,
		"ideology=%d spirit=%d" % [int(snap["ideology_slots_used"]),
			int(snap["national_spirit_slots_used"])])
	_expect("spirit guard: explain_ideologies agrees promotion is unavailable",
		_promote_allowed(ext, handle, a) == 0)

	# ---------------- day 2: near miss (one ingredient) + pending guard ------
	_stage("world d2 equip A, second equip while pending")
	day = 2
	cursor = _receipt_cursor(ext)
	# Two equips in ONE batch, A first by sequence. The first starts a country
	# transition; the second must be refused because a synergy is compiled (:4550).
	_submit(ext, day, [{"op": OP_EQUIP, "idea": a}, {"op": OP_EQUIP, "idea": b}])
	_settle(ext, day)
	var pending_refusal := _last_receipt(ext, cursor, OP_EQUIP, b)
	print("[phase 3] second equip while one transition is pending: status=%d reason=%s"
		% [int(pending_refusal.get("status", 0)),
			String(pending_refusal.get("reason", ""))])
	_expect("synergy gate: a second equip is refused while a country transition is pending",
		int(pending_refusal.get("status", 0)) == RECEIPT_REJECTED,
		str(pending_refusal))
	_expect("synergy gate: the refusal names ideology_country_transition_pending",
		String(pending_refusal.get("reason", ""))
			== "ideology_country_transition_pending",
		String(pending_refusal.get("reason", "")))
	snap = _snapshot(ext, handle)
	_expect("synergy gate: the first equip still settles on its own",
		int(snap["ideology_slots_used"]) == int(ideology_costs[a]),
		"slots=%d expected=%d" % [int(snap["ideology_slots_used"]),
			int(ideology_costs[a])])
	# NEAR MISS 1 -- the pairing is incomplete, so the bond must do NOTHING.
	drought = _read(ext, handle, STAT_DROUGHT)
	plain = _read(ext, handle, STAT_PLAIN_AGRICULTURE)
	print("[phase 3] near miss (one of two cards): drought=%.5f plain=%.5f active=%s slots=%d/%d"
		% [drought, plain, str(snap["active_synergy_ids"]),
			int(snap["ideology_slots_used"]), int(snap["ideology_slots_capacity"])])
	_expect("near miss: granary_records is NOT active with only one of its two cards",
		_active_ids(snap).find(synergy) < 0, str(snap["active_synergy_ids"]))
	_expect("near miss: the drought factor is untouched (no 0.95 term)",
		_is_close(drought, 1.0, 0.000001), "%.6f" % drought)
	_expect("near miss: plain agriculture is untouched (no 1.03 term)",
		_is_close(plain, 1.0, 0.000001), "%.6f" % plain)
	_expect("near miss: no modifier row for the bond is live",
		not _has_modifier_row(ext, handle, _synergy_definition_key()),
		str(_modifier_rows(ext, handle)))

	# ---------------- day 3: SPIRIT GUARD 2, the level gate ------------------
	_stage("world d3 promote below the level gate")
	day = 3
	cursor = _receipt_cursor(ext)
	_submit(ext, day, [{"op": OP_PROMOTE, "idea": a}])
	_settle(ext, day)
	var guard_two := _last_receipt(ext, cursor, OP_PROMOTE, a)
	var level_now := _level(ext, handle, a)
	print("[phase 4] promote at level %d (gate %d): status=%d reason=%s"
		% [level_now, gate, int(guard_two.get("status", 0)),
			String(guard_two.get("reason", ""))])
	_expect("spirit guard: the equipped card is below the authored spirit level gate",
		level_now < gate, "level=%d gate=%d" % [level_now, gate])
	_expect("spirit guard: promotion below national_spirit_min_level is refused",
		int(guard_two.get("status", 0)) == RECEIPT_REJECTED, str(guard_two))
	_expect("spirit guard: the refusal names ideology_national_spirit_level_insufficient",
		String(guard_two.get("reason", ""))
			== "ideology_national_spirit_level_insufficient",
		String(guard_two.get("reason", "")))
	_expect("spirit guard: explain_ideologies reports promotion unavailable below the gate",
		_promote_allowed(ext, handle, a) == 0)
	snap = _snapshot(ext, handle)
	_expect("spirit guard: the level refusal did not consume a spirit slot",
		int(snap["national_spirit_slots_used"]) == 0,
		"spirit=%d" % int(snap["national_spirit_slots_used"]))

	# ---------------- day 4: the QUALIFYING pair ------------------------------
	_stage("world d4 equip B (qualifying pair)")
	day = 4
	_submit(ext, day, [{"op": OP_EQUIP, "idea": b}])
	_expect("world: the second card's equip settles", _settle(ext, day))
	snap = _snapshot(ext, handle)
	var active := _active_ids(snap)
	drought = _read(ext, handle, STAT_DROUGHT)
	plain = _read(ext, handle, STAT_PLAIN_AGRICULTURE)
	var expected_drought := _expected_country_stat(STAT_DROUGHT, active)
	var expected_plain := _expected_country_stat(STAT_PLAIN_AGRICULTURE, active)
	var synergy_report: Dictionary = ext.get_ideology_report()
	print("[phase 5] qualifying pair: active=%s drought=%.5f (expected %.5f) plain=%.5f (expected %.5f) candidates=%d"
		% [str(snap["active_synergy_ids"]), drought, expected_drought, plain,
			expected_plain, int(synergy_report.get("synergy_candidates_visited", 0))])
	_expect("qualifying: granary_records becomes active with both cards equipped",
		active.find(synergy) >= 0, str(snap["active_synergy_ids"]))
	_expect("qualifying: the runtime reports a nonzero active-synergy count",
		int(snap["ideology_scalar_active_synergy_count"]) >= 1,
		"count=%d" % int(snap["ideology_scalar_active_synergy_count"]))
	_expect("qualifying: a modifier row for the bond is live",
		_has_modifier_row(ext, handle, _synergy_definition_key()),
		str(_modifier_rows(ext, handle)))
	_expect("qualifying: the drought factor equals the catalog-derived value",
		_is_close(drought, expected_drought, 0.0005),
		"got %.6f expected %.6f" % [drought, expected_drought])
	_expect("qualifying: plain agriculture equals the catalog-derived value",
		_is_close(plain, expected_plain, 0.0005),
		"got %.6f expected %.6f" % [plain, expected_plain])
	# The counter is the only public proof that the reverse index was walked.
	_expect("qualifying: synergy_candidates_visited advanced past zero",
		int(synergy_report.get("synergy_candidates_visited", 0)) > 0,
		"candidates=%d" % int(synergy_report.get("synergy_candidates_visited", 0)))
	_expect("qualifying: both cards hold an ideology slot",
		int(snap["ideology_slots_used"])
			== int(ideology_costs[a]) + int(ideology_costs[b]),
		"slots=%d" % int(snap["ideology_slots_used"]))

	# ---------------- day 5: meet the level gate ----------------------------
	_stage("world d5 raise understanding to the gate")
	day = 5
	var threshold := _level_threshold(a, gate)
	print("[phase 6] granting %d understanding (tier %d threshold %d)"
		% [threshold, gate, threshold])
	_expect("spirit: the level threshold for the gate is a real nonzero tier",
		threshold > 0, "threshold=%d" % threshold)
	_submit(ext, day, [{"op": OP_ADD_UNDERSTANDING, "idea": a,
		"value": threshold}])
	_expect("spirit: the understanding grant settles", _settle(ext, day))
	level_now = _level(ext, handle, a)
	_expect("spirit: the card reaches the level the gate demands",
		level_now >= gate, "level=%d gate=%d" % [level_now, gate])
	snap = _snapshot(ext, handle)
	_expect("spirit: reaching the gate flips explain_ideologies to promote-allowed",
		_promote_allowed(ext, handle, a) == 1,
		"promote_allowed=%d" % _promote_allowed(ext, handle, a))
	print("[phase 6] level=%d promote_allowed=%d ideology_slots=%d spirit=%d/%d"
		% [level_now, _promote_allowed(ext, handle, a),
			int(snap["ideology_slots_used"]),
			int(snap["national_spirit_slots_used"]),
			int(snap["national_spirit_slots_capacity"])])

	# ---------------- day 6: PROMOTE ---------------------------------------
	_stage("world d6 promote")
	day = 6
	var slots_before := int(snap["ideology_slots_used"])
	var spirit_before := int(snap["national_spirit_slots_used"])
	cursor = _receipt_cursor(ext)
	_submit(ext, day, [{"op": OP_PROMOTE, "idea": a}])
	_expect("spirit: the promotion settles", _settle(ext, day))
	var promote_receipt := _last_receipt(ext, cursor, OP_PROMOTE, a)
	snap = _snapshot(ext, handle)
	# `locations` is parallel to `idea_ids` (the country's materialized idea rows),
	# NOT indexed by dense ideology id: indexing it by `a` reads row `a`.
	var location_a := _location(ext, handle, a)
	var location_b := _location(ext, handle, b)
	var slots_after := int(snap["ideology_slots_used"])
	var spirit_after := int(snap["national_spirit_slots_used"])
	var spirit_capacity := int(snap["national_spirit_slots_capacity"])
	print("[phase 7] promote: status=%d location=%d ideology_slots %d->%d spirit %d->%d/%d"
		% [int(promote_receipt.get("status", 0)), location_a, slots_before,
			slots_after, spirit_before, spirit_after, spirit_capacity])
	_expect("spirit: the promotion is accepted (settled receipt)",
		int(promote_receipt.get("status", 0)) == RECEIPT_SETTLED,
		str(promote_receipt))
	_expect("spirit: the card's location becomes NATIONAL_SPIRIT",
		location_a == LOCATION_NATIONAL_SPIRIT,
		"location=%d expected=%d" % [location_a, LOCATION_NATIONAL_SPIRIT])
	# The card that was NOT promoted must not have moved, or "the location changed"
	# would only prove that some location changed.
	_expect("spirit: the other equipped card stays in an ideology slot",
		location_b == LOCATION_IDEOLOGY,
		"location=%d expected=%d" % [location_b, LOCATION_IDEOLOGY])
	# The observable consequence, in slot units taken from the compiled catalog.
	_expect("spirit: the ideology slot ledger drops by exactly the card's ideology cost",
		slots_after == slots_before - int(ideology_costs[a]),
		"before=%d after=%d cost=%d" % [slots_before, slots_after,
			int(ideology_costs[a])])
	_expect("spirit: the spirit slot ledger rises by exactly the card's spirit cost",
		spirit_after == spirit_before + int(spirit_costs[a]),
		"before=%d after=%d cost=%d" % [spirit_before, spirit_after,
			int(spirit_costs[a])])
	_expect("spirit: the card's spirit cost is drawn from the real capacity pool",
		spirit_after <= spirit_capacity and spirit_after > 0,
		"used=%d capacity=%d" % [spirit_after, spirit_capacity])
	_expect("spirit: the card keeps its own persistent modifier row after the move",
		_has_modifier_row(ext, handle, _card_modifier_key(a)),
		str(_modifier_rows(ext, handle)))
	# Mask 6 again, now with the relocated card: the bond must NOT drop.
	active = _active_ids(snap)
	drought = _read(ext, handle, STAT_DROUGHT)
	plain = _read(ext, handle, STAT_PLAIN_AGRICULTURE)
	print("[phase 7] after promotion: active=%s drought=%.5f plain=%.5f"
		% [str(snap["active_synergy_ids"]), drought, plain])
	_expect("spirit: the bond survives the move because its mask accepts spirit slots",
		active.find(synergy) >= 0, str(snap["active_synergy_ids"]))
	_expect("spirit: the bond's drought factor survives the move unchanged",
		_is_close(drought, _expected_country_stat(STAT_DROUGHT, active), 0.0005),
		"got %.6f expected %.6f"
			% [drought, _expected_country_stat(STAT_DROUGHT, active)])
	_expect("spirit: the bond's plain-agriculture factor survives the move unchanged",
		_is_close(plain, _expected_country_stat(STAT_PLAIN_AGRICULTURE, active),
			0.0005),
		"got %.6f expected %.6f" % [plain,
			_expected_country_stat(STAT_PLAIN_AGRICULTURE, active)])
	_expect("spirit: a promoted card is no longer promotion-eligible",
		_promote_allowed(ext, handle, a) == 0)

	# ---------------- day 7: the min_count half of the rule -----------------
	_stage("world d7 count-based synergy")
	day = 7
	var count_synergy := _find_count_synergy(c, a)
	if count_synergy < 0:
		_expect("count rule: a min_count>=2 synergy covering the two agrarian cards exists",
			false, "none found")
		return
	var count_key := String((_ideology_ir["synergy_ids"] as PackedStringArray)[
		count_synergy])
	active = _active_ids(snap)
	var agriculture_before := _read(ext, handle, STAT_AGRICULTURE)
	var expected_before := _expected_country_stat(STAT_AGRICULTURE, active)
	print("[phase 8] count rule near miss (%s, min_count=%d): active_members=%d agriculture=%.5f expected=%.5f"
		% [count_key, int((_ideology_ir["synergy_min_counts"] as PackedInt32Array)[
			count_synergy]), _active_member_count(count_synergy, snap), agriculture_before,
			expected_before])
	# NEAR MISS 2 -- one member short of the tier: the term must be absent.
	_expect("count rule: the tier is not active one member short",
		active.find(count_synergy) < 0, str(snap["active_synergy_ids"]))
	_expect("count rule: the shortfall is within the tier's required count",
		_active_member_count(count_synergy, snap)
			< _synergy_needed(count_synergy),
		"members=%d needed=%d" % [_active_member_count(count_synergy, snap),
			_synergy_needed(count_synergy)])
	_expect("count rule: the tier's agriculture factor is absent before the second member",
		_is_close(agriculture_before, expected_before, 0.000001),
		"got %.6f expected %.6f" % [agriculture_before, expected_before])
	# And the discriminating half: equipping the third card reaches min_count.
	_submit(ext, day, [{"op": OP_EQUIP, "idea": c}])
	_expect("count rule: the third card's equip settles", _settle(ext, day))
	snap = _snapshot(ext, handle)
	active = _active_ids(snap)
	var agriculture_after := _read(ext, handle, STAT_AGRICULTURE)
	var expected_after := _expected_country_stat(STAT_AGRICULTURE, active)
	print("[phase 8] count rule qualifying: active=%s members=%d agriculture=%.5f (expected %.5f) slots=%d/%d spirit=%d/%d"
		% [str(snap["active_synergy_ids"]), _active_member_count(count_synergy, snap),
			agriculture_after, expected_after, int(snap["ideology_slots_used"]),
			int(snap["ideology_slots_capacity"]),
			int(snap["national_spirit_slots_used"]),
			int(snap["national_spirit_slots_capacity"])])
	_expect("count rule: reaching min_count activates the tier",
		active.find(count_synergy) >= 0,
		"members=%d needed=%d active=%s" % [_active_member_count(count_synergy, snap),
			_synergy_needed(count_synergy), str(snap["active_synergy_ids"])])
	_expect("count rule: the promoted member counts toward the tier (mask 6)",
		_active_member_count(count_synergy, snap) >= _synergy_needed(count_synergy),
		"members=%d needed=%d" % [_active_member_count(count_synergy, snap),
			_synergy_needed(count_synergy)])
	_expect("count rule: the tier's agriculture factor equals the catalog-derived value",
		_is_close(agriculture_after, expected_after, 0.0005),
		"got %.6f expected %.6f" % [agriculture_after, expected_after])
	_expect("count rule: the tier's factor is distinguishable from the near miss",
		absf(expected_after - expected_before) > 0.005,
		"before %.6f after %.6f" % [expected_before, expected_after])
	_expect("count rule: the qualifying bond is still active alongside the tier",
		active.find(synergy) >= 0, str(snap["active_synergy_ids"]))

	# ---------------- day 8/9: SPIRIT GUARD 3, the bounded pool -------------
	# The spirit pool is FULL (one card of cost 1 in a pool of capacity 1), so a
	# second promotion must be refused on capacity even once its level gate is met.
	# That is what makes "promotion consumes a slot" a real consequence instead of
	# bookkeeping, and `capacity_unlock_spirit_deltas` (phase 10) is what widens it.
	_stage("world d8 raise B to its spirit gate")
	day = 8
	var threshold_b := _level_threshold(b, int(spirit_levels[b]))
	_submit(ext, day, [{"op": OP_ADD_UNDERSTANDING, "idea": b,
		"value": threshold_b}])
	_expect("spirit capacity: the second card reaches its own gate",
		_settle(ext, day) and _level(ext, handle, b) >= int(spirit_levels[b]),
		"level=%d gate=%d" % [_level(ext, handle, b), int(spirit_levels[b])])
	snap = _snapshot(ext, handle)
	_expect("spirit capacity: the second card is level-eligible but not capacity-eligible",
		int(spirit_levels[b]) <= _level(ext, handle, b)
			and _promote_allowed(ext, handle, b) == 0,
		"level=%d gate=%d promote_allowed=%d"
			% [_level(ext, handle, b), int(spirit_levels[b]),
				_promote_allowed(ext, handle, b)])
	_stage("world d9 promote into a full spirit pool")
	day = 9
	cursor = _receipt_cursor(ext)
	_submit(ext, day, [{"op": OP_PROMOTE, "idea": b}])
	_settle(ext, day)
	var guard_three := _last_receipt(ext, cursor, OP_PROMOTE, b)
	snap = _snapshot(ext, handle)
	print("[phase 9] promote into a full spirit pool: status=%d reason=%s spirit=%d/%d ideology=%d/%d"
		% [int(guard_three.get("status", 0)),
			String(guard_three.get("reason", "")),
			int(snap["national_spirit_slots_used"]),
			int(snap["national_spirit_slots_capacity"]),
			int(snap["ideology_slots_used"]),
			int(snap["ideology_slots_capacity"])])
	_expect("spirit capacity: promotion into a full pool is refused",
		int(guard_three.get("status", 0)) == RECEIPT_REJECTED, str(guard_three))
	_expect("spirit capacity: the refusal names national_spirit_slot_capacity_exceeded",
		String(guard_three.get("reason", ""))
			== "national_spirit_slot_capacity_exceeded",
		String(guard_three.get("reason", "")))
	_expect("spirit capacity: the refused card stays in its ideology slot",
		_location(ext, handle, b) == LOCATION_IDEOLOGY,
		"location=%d" % _location(ext, handle, b))
	_expect("spirit capacity: the refusal does not overdraw the spirit ledger",
		int(snap["national_spirit_slots_used"])
			== int(spirit_costs[a]),
		"used=%d expected=%d" % [int(snap["national_spirit_slots_used"]),
			int(spirit_costs[a])])
	_expect("spirit capacity: the pool is exactly saturated, not over-drawn",
		int(snap["national_spirit_slots_used"])
			== int(snap["national_spirit_slots_capacity"]),
		"used=%d capacity=%d" % [int(snap["national_spirit_slots_used"]),
			int(snap["national_spirit_slots_capacity"])])

	# ---------------- day 10: the bond must also turn OFF --------------------
	# `collect_affected_synergies` emits a REMOVE (:1472) when a previously met
	# requirement stops being met, so the partner card is unequipped and the
	# activation bit must clear. The MAGNITUDE half of this direction is the one
	# place in this fixture that is not asserted: it measures a defect instead (see
	# the `_finding` block below), because the row the ACTIVATION installed is never
	# retired and pinning the broken value would enshrine it.
	_stage("world d10 unequip B, the bond must release")
	day = 10
	var removes_before: PackedInt64Array = ext.get_modifier_report().get(
		"remove_events_by_domain", PackedInt64Array())
	_submit(ext, day, [{"op": OP_UNEQUIP, "idea": b}])
	_expect("synergy release: the unequip settles", _settle(ext, day))
	var modifier_report: Dictionary = ext.get_modifier_report()
	var removes_after: PackedInt64Array = modifier_report.get(
		"remove_events_by_domain", PackedInt64Array())
	# Card B's own rows: ONE remove (the L2 row). A delta of two means the bond's
	# REMOVE also reached the Modifier runtime and was answered `already_removed`; a
	# delta of one means it never got that far. Which one it is decides where the
	# defect lives, so it is measured rather than assumed.
	var country_removes := (int(removes_after[1]) if removes_after.size() > 1 else -1) \
		- (int(removes_before[1]) if removes_before.size() > 1 else -1)
	snap = _snapshot(ext, handle)
	active = _active_ids(snap)
	drought = _read(ext, handle, STAT_DROUGHT)
	plain = _read(ext, handle, STAT_PLAIN_AGRICULTURE)
	agriculture = _read(ext, handle, STAT_AGRICULTURE)
	print("[phase 10] after unequipping B: active=%s drought=%.5f plain=%.5f agriculture=%.5f slots=%d/%d spirit=%d/%d removes=%s (country delta %d)"
		% [str(snap["active_synergy_ids"]), drought, plain, agriculture,
			int(snap["ideology_slots_used"]),
			int(snap["ideology_slots_capacity"]),
			int(snap["national_spirit_slots_used"]),
			int(snap["national_spirit_slots_capacity"]),
			str(removes_after), country_removes])
	# The rule half that IS correct: the activation predicate is recomputed and the
	# bit clears as soon as a member stops being equipped.
	_expect("synergy release: the bond deactivates when one of its cards leaves",
		active.find(synergy) < 0, str(snap["active_synergy_ids"]))
	_expect("synergy release: the count-based tier survives, it lost no member",
		active.find(count_synergy) >= 0, str(snap["active_synergy_ids"]))
	_expect("synergy release: that tier's factor is still applied",
		_is_close(agriculture,
			_expected_country_stat(STAT_AGRICULTURE, active), 0.0005),
		"got %.6f expected %.6f" % [agriculture,
			_expected_country_stat(STAT_AGRICULTURE, active)])
	# ---- MEASURED DEFECT, reported instead of asserted ----------------------
	# The ACTIVATION bit is correct, yet the country row installed by the ACTIVATION
	# survives, so the deactivated bond keeps modifying the country. Measurements
	# above: `active` lost the bond, the row list still names it, the two factors
	# still read 0.95000 / 1.03000, and the unequip produced exactly ONE country
	# removal event -- card B's own row. The bond's REMOVE produced none, and it did
	# not fail either: `ModifierRuntime` answers `already_removed` and increments no
	# counter in that case (remove_events is bumped only by a real removal).
	# Root cause, from the code and consistent with every number above:
	#   * a synergy row is an EXTERNAL effect batch command, so the row's Modifier
	#     source is the batch's Effect instance id (effect_runtime.cpp:5662-5663);
	#   * that id is hash(source_type, transition_source_id, first.effect_id,
	#     fire_sequence) (effect_runtime.cpp:3561-3566). `start_transition` enqueues
	#     the scratch under a NEW-generation batch id while assuming the scratch only
	#     holds rows "that BELONG to the new generation: the APPLY rows, on-enter
	#     one-shots and synergy rows" (ideology_runtime.cpp:3675-3695) -- but
	#     `collect_affected_synergies` also puts DEACTIVATION rows in that same
	#     scratch (:1472), and they carry fire_sequence with bit 63 set
	#     (:1468-1469). So the remove's instance id, hence its Modifier source_id,
	#     can never equal the apply's;
	#   * ModifierRuntime keys unique rows on (definition, scope, scope_id,
	#     source_type, source_id) (modifier_runtime.cpp:1201-1202) and answers
	#     `already_removed` when that key misses (modifier_runtime.cpp:1207-1209),
	#     which leaves the row live and is not an error at any layer.
	# The card's OWN rows do not suffer this: they are managed Effect instances whose
	# identity is the card, not the transition.
	# Consequence: once a synergy has been activated it can never be retired, so its
	# effect leaks for the rest of the game. Not verifiable from GDScript: the
	# source_id the REMOVE carries (it is not exposed by any query).
	if _has_modifier_row(ext, handle, _synergy_definition_key()):
		_finding("synergy release: the deactivated bond's modifier row is STILL live",
			"rows=%s drought=%.5f plain=%.5f active=%s removes=%s country_delta=%d"
				% [str(_modifier_rows(ext, handle)), drought, plain,
					str(snap["active_synergy_ids"]), str(removes_after),
					country_removes])
	else:
		# Post-fix contract: this branch runs the moment the row is retired, and then
		# guards the retirement against regressing.
		_expect("synergy release: the bond's modifier row is retired", true)
		_expect("synergy release: the drought factor returns to the identity",
			_is_close(drought, 1.0, 0.000001), "%.6f" % drought)
		_expect("synergy release: plain agriculture returns to the identity",
			_is_close(plain, 1.0, 0.000001), "%.6f" % plain)


# --------------------------------------------------------------------------- #
# 2. capacity_unlock_spirit_deltas: the spirit pool really is technology-gated.
# --------------------------------------------------------------------------- #
func _phase_capacity_unlocks() -> void:
	var profile: Resource = _ideology_catalog.profile
	var base_spirit := int(profile.national_spirit_capacity)
	var max_spirit := maxi(base_spirit, int(profile.national_spirit_capacity_max))
	var base_ideology := int(profile.ideology_capacity)
	var max_ideology := maxi(base_ideology, int(profile.ideology_capacity_max))
	if not _require("capacity: the authored unlock tables are parallel",
			profile.capacity_unlock_technology_keys.size()
				== profile.capacity_unlock_spirit_deltas.size()
			and profile.capacity_unlock_technology_keys.size()
				== profile.capacity_unlock_ideology_deltas.size()):
		return
	var spirit_tech := ""
	var spirit_delta := 0
	for index in profile.capacity_unlock_technology_keys.size():
		var delta := int(profile.capacity_unlock_spirit_deltas[index])
		if delta != 0:
			spirit_tech = String(profile.capacity_unlock_technology_keys[index])
			spirit_delta = delta
			break
	if not _require("capacity: a technology carries a spirit delta",
			not spirit_tech.is_empty()):
		return
	_stage("capacity worlds")
	var base_world := _capacity_world(PackedStringArray(["tech.hunting"]))
	var unlocked := _capacity_world(PackedStringArray(["tech.hunting", spirit_tech]))
	var every := PackedStringArray(["tech.hunting"])
	for key in profile.capacity_unlock_technology_keys:
		every.append(String(key))
	var capped := _capacity_world(every)
	if base_world.is_empty() or unlocked.is_empty() or capped.is_empty():
		return
	print("[phase 11] capacity: base spirit=%d ideology=%d | +%s spirit=%d ideology=%d | all unlocks spirit=%d ideology=%d (max %d/%d)"
		% [int(base_world["spirit"]), int(base_world["ideology"]), spirit_tech,
			int(unlocked["spirit"]), int(unlocked["ideology"]),
			int(capped["spirit"]), int(capped["ideology"]), max_spirit,
			max_ideology])
	_expect("capacity: the baseline world reports the profile's spirit capacity",
		int(base_world["spirit"]) == base_spirit,
		"got %d expected %d" % [int(base_world["spirit"]), base_spirit])
	_expect("capacity: the baseline world reports the profile's ideology capacity",
		int(base_world["ideology"]) == base_ideology,
		"got %d expected %d" % [int(base_world["ideology"]), base_ideology])
	_expect("capacity: owning the spirit-unlock technology adds exactly its delta",
		int(unlocked["spirit"]) == mini(base_spirit + spirit_delta, max_spirit),
		"got %d expected %d (delta %d)"
			% [int(unlocked["spirit"]), mini(base_spirit + spirit_delta, max_spirit),
				spirit_delta])
	_expect("capacity: owning every unlock clamps the spirit pool at its declared max",
		int(capped["spirit"]) == max_spirit,
		"got %d max %d" % [int(capped["spirit"]), max_spirit])
	_expect("capacity: owning every unlock clamps the ideology pool at its declared max",
		int(capped["ideology"]) == max_ideology,
		"got %d max %d" % [int(capped["ideology"]), max_ideology])
	_expect("capacity: the spirit pool is smaller than the ideology pool at baseline",
		base_spirit < base_ideology, "spirit=%d ideology=%d"
			% [base_spirit, base_ideology])


# --------------------------------------------------------------------------- #
# World construction (mirrors ideology_card_content_test's proven fixture).
# --------------------------------------------------------------------------- #
func _build_world(tech_keys: PackedStringArray) -> Dictionary:
	_stage("build_world:ext")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default(
		).compile_native_catalog()
	modifier_catalog.erase("ok")
	if not _require("world: modifiers configure",
			bool(ext.configure_modifiers(modifier_catalog, CELLS).get("ok", false))):
		return {}
	_register_cell_components(ext)
	_stage("build_world:country")
	if not _require("world: country configures", bool(ext.configure_country(
			_country_ir, {
				"country_runtime_mode": "ACTIVE",
				"starting_technology_ids": tech_keys,
			}, CELLS, 97).get("ok", false))):
		return {}
	var territory := PackedInt32Array()
	for cell in range(CELLS):
		territory.append(cell)
	var outcome: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.synergy_spirit_test"]),
		"country_names": PackedStringArray(["Synergy Spirit Test"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		# Empty technology CSR: the country runtime then applies the
		# starting_technology_ids handed to configure_country (country_runtime.cpp
		# :1185-1194). A non-empty CSR REPLACES that list, which silently granted
		# nothing on the first run of this fixture.
		"technology_offsets": PackedInt32Array(),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill(CELLS, 0))
	if not _require("world: country bootstraps", bool(outcome.get("ok", false)),
			str(outcome)):
		return {}
	_stage("build_world:economy")
	# `configure_economy` must run BEFORE `configure_ideologies`: the anchor cell
	# comes from `_epoch_cell_country`.
	if not _require("world: economy configures", bool(ext.configure_economy(
			_country_ir, load("res://data/economy/default_economy.tres"
				).to_native_profile(), CELLS, 97).get("ok", false))):
		return {}
	if not _require("world: economy bootstraps", _bootstrap_economy(ext)):
		return {}
	_stage("build_world:effects")
	if not _require("world: effects configure",
			bool(ext.configure_effects(_effect_ir).get("ok", false))):
		return {}
	_stage("build_world:ideologies")
	if not _require("world: ideologies configure", bool(ext.configure_ideologies(
			_support_gate_off(_ideology_ir)).get("ok", false))):
		return {}
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if not _require("world: the country handle resolves", handle != 0):
		return {}
	return {"ext": ext, "handle": handle}


## A country + ideology world with no economy and no effects. Enough for the slot
## ledgers, which only consult the country runtime's technology bits.
func _capacity_world(tech_keys: PackedStringArray) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_register_cell_components(ext)
	if not _require("capacity world: country configures", bool(ext.configure_country(
			_country_ir, {
				"country_runtime_mode": "ACTIVE",
				"starting_technology_ids": tech_keys,
			}, CELLS, 97).get("ok", false))):
		return {}
	var territory := PackedInt32Array()
	for cell in range(CELLS):
		territory.append(cell)
	var outcome: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.synergy_spirit_capacity"]),
		"country_names": PackedStringArray(["Capacity Probe"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, CELLS]),
		"territory_cells": territory,
		# Empty technology CSR: the country runtime then applies the
		# starting_technology_ids handed to configure_country (country_runtime.cpp
		# :1185-1194). A non-empty CSR REPLACES that list, which silently granted
		# nothing on the first run of this fixture.
		"technology_offsets": PackedInt32Array(),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_fill(CELLS, 0))
	if not _require("capacity world: country bootstraps",
			bool(outcome.get("ok", false)), str(outcome)):
		return {}
	if not _require("capacity world: ideologies configure",
			bool(ext.configure_ideologies(
				_support_gate_off(_ideology_ir)).get("ok", false))):
		return {}
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	if not _require("capacity world: the country handle resolves", handle != 0):
		return {}
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	return {
		"spirit": int(snapshot.get("national_spirit_slots_capacity", -1)),
		"ideology": int(snapshot.get("ideology_slots_capacity", -1)),
	}


func _register_cell_components(ext: Object) -> void:
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation",
			&"cell_temp_365d"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, _f32_fill(CELLS, 0.5))
	# Terrain must be a REAL id: tag dictionary entries are built from the enum, so
	# an all-zero column makes every terrain tag mean "terrain 0".
	var terrain := PackedByteArray()
	terrain.resize(CELLS)
	terrain.fill(_terrain_id("HILL"))
	for slot_name in [&"cell_landform", &"cell_vegetation", &"cell_is_water",
			&"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var slot: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(slot, 0, _u8_fill(CELLS, 0))
	var terrain_slot: int = ext.register_component(&"cell_terrain", 2, 1, false)
	ext.write_u8_range(terrain_slot, 0, terrain)
	var reserve_slots: PackedStringArray = _country_ir[
		"building_resource_reserve_slots"]
	var extra_slots: PackedStringArray = _country_ir["building_resource_extra_slots"]
	for index in reserve_slots.size():
		var reserve: int = ext.register_component(
			StringName(reserve_slots[index]), 0, 1, false)
		var extra: int = ext.register_component(
			StringName(extra_slots[index]), 0, 1, false)
		ext.write_f32_range(reserve, 0, _f32_fill(CELLS, 1000000.0))
		ext.write_f32_range(extra, 0, _f32_fill(CELLS, 0.0))


func _bootstrap_economy(ext: Object) -> bool:
	var building_id := (_country_ir["building_type_ids"] as PackedStringArray).find(
		"gathering_ground")
	var owner_sig := (_country_ir["signature_keys"] as PackedStringArray).find(
		"forager|default")
	if not _require("world: fixture finds its building type and owner signature",
			building_id >= 0 and owner_sig >= 0):
		return false
	var stock := PackedInt64Array()
	stock.resize((_country_ir["good_ids"] as PackedStringArray).size() * CELLS)
	stock.fill(100000000)
	var cells := PackedInt32Array()
	var signatures := PackedInt32Array()
	var population := PackedInt64Array()
	var funds := PackedInt64Array()
	var buildings := PackedInt32Array()
	var owners := PackedInt32Array()
	var counts := PackedInt64Array()
	for cell in range(CELLS):
		cells.append(cell)
		signatures.append(owner_sig)
		population.append(400)
		funds.append(1000000000000000)
		buildings.append(building_id)
		owners.append(owner_sig)
		counts.append(1)
	var outcome: Dictionary = ext.bootstrap_economy({
		"cell_indices": cells,
		"signature_ids": signatures,
		"population": population,
		"funds": funds,
		"forced_named_cells": cells,
		"founder_family_cells": cells,
		"founder_family_building_type_ids": buildings,
		"founder_family_owner_signature_ids": owners,
	}, {
		"stock": stock,
		"building_cells": cells,
		"building_type_ids": buildings,
		"building_owner_signature_ids": owners,
		"building_counts": counts,
	})
	return _require("world: economy bootstraps", bool(outcome.get("ok", false)),
		str(outcome))


# --------------------------------------------------------------------------- #
# Command plumbing.
# --------------------------------------------------------------------------- #
func _submit(ext: Object, day: int, rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var priorities := PackedInt32Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var offers := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	for row_value in rows:
		var row: Dictionary = row_value
		opcodes.append(int(row.get("op", 0)))
		days.append(day)
		priorities.append(0)
		producers.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(handle)
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		offers.append(0)
		choices.append(-1)
		gates.append(-1)
	return ext.submit_ideology_commands({
		"opcodes": opcodes,
		"effective_days": days,
		"source_priorities": priorities,
		"producer_ids": producers,
		"sequences": sequences,
		"country_handles": handles,
		"ideology_ids": ideas,
		"values_q16": values,
		"offer_generations": offers,
		"choice_indices": choices,
		"gate_ids": gates,
	})


## Four-stage settlement. A transition is only reconciled by a daily pass at or
## after the day it was stamped with, and the Effect transaction has to be
## dispatched, run through the Modifier runtime and ACKed before the next command
## may start (see `ideology_country_transition_pending`).
func _settle(ext: Object, first_day: int) -> bool:
	var settled := true
	for offset in 3:
		var day := first_day + offset
		var ideology_done := false
		for _slice in 32:
			var slice: Dictionary = ext.run_ideology_daily(day)
			if not bool(slice.get("ok", false)):
				settled = false
				break
			if bool(slice.get("done", false)):
				ideology_done = true
				break
		if not ideology_done:
			settled = false
		for _effect_slice in 16:
			var effect_slice: Dictionary = ext.run_effect_daily(day)
			if not bool(effect_slice.get("ok", true)):
				break
			if bool(effect_slice.get("done", true)):
				break
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		ext.ack_effect_native_modifier()
	return settled


func _receipt_cursor(ext: Object) -> int:
	var batch: Dictionary = ext.poll_ideology_receipts(0, 4096)
	var ids: PackedInt64Array = batch.get("receipt_ids", PackedInt64Array())
	return int(ids[ids.size() - 1]) if not ids.is_empty() else 0


## The last receipt for one (opcode, card) pair after `after_id`. Filtering by both
## keeps an unrelated card's receipt from answering the question.
func _last_receipt(ext: Object, after_id: int, opcode: int, dense: int) -> Dictionary:
	var batch: Dictionary = ext.poll_ideology_receipts(after_id, 4096)
	var ids: PackedInt64Array = batch.get("receipt_ids", PackedInt64Array())
	var opcodes: PackedInt32Array = batch.get("opcodes", PackedInt32Array())
	var ideas: PackedInt32Array = batch.get("ideology_ids", PackedInt32Array())
	var statuses: PackedInt32Array = batch.get("statuses", PackedInt32Array())
	var reasons: PackedStringArray = batch.get("reasons", PackedStringArray())
	var found := {}
	for index in ids.size():
		if int(opcodes[index]) == opcode and int(ideas[index]) == dense:
			found = {"id": int(ids[index]), "status": int(statuses[index]),
				"reason": String(reasons[index])}
	return found


# --------------------------------------------------------------------------- #
# Runtime readers.
# --------------------------------------------------------------------------- #
func _snapshot(ext: Object, handle: int) -> Dictionary:
	return ext.get_ideology_snapshot(handle)


func _active_ids(snapshot: Dictionary) -> PackedInt32Array:
	return snapshot.get("active_synergy_ids", PackedInt32Array())


func _frame(snapshot: Dictionary, key: String, fallback: int) -> PackedInt32Array:
	return snapshot.get(key, PackedInt32Array([fallback]))


func _level(ext: Object, handle: int, dense: int) -> int:
	var snapshot: Dictionary = _snapshot(ext, handle)
	var ids: PackedInt32Array = _frame(snapshot, "idea_ids", -1)
	var levels: PackedInt32Array = _frame(snapshot, "levels", -1)
	for index in ids.size():
		if int(ids[index]) == dense:
			return int(levels[index])
	return -1


## The card's `RuntimeIdeologyPodLocation` from the snapshot's parallel columns.
func _location(ext: Object, handle: int, dense: int) -> int:
	var snapshot: Dictionary = _snapshot(ext, handle)
	var ids: PackedInt32Array = _frame(snapshot, "idea_ids", -1)
	var locations: PackedInt32Array = _frame(snapshot, "locations", -1)
	for index in ids.size():
		if int(ids[index]) == dense:
			return int(locations[index])
	return -1


func _promote_allowed(ext: Object, handle: int, dense: int) -> int:
	var explain: Dictionary = ext.explain_ideologies(
		handle, PackedInt32Array([dense]))
	var allowed: PackedByteArray = explain.get("promote_allowed", PackedByteArray())
	return int(allowed[0]) if not allowed.is_empty() else -1


## `evaluate_modifier_stat(domain, entity_handle, group_handle, stat, base)`.
func _read(ext: Object, handle: int, stat: String, base: float = 1.0) -> float:
	return float(ext.evaluate_modifier_stat(MODIFIER_DOMAIN_COUNTRY, handle, 0,
		stat, base))


func _modifier_rows(ext: Object, handle: int) -> PackedStringArray:
	var rows: Dictionary = ext.list_modifiers(MODIFIER_DOMAIN_COUNTRY, handle, "")
	return rows.get("definition_keys", PackedStringArray())


func _has_modifier_row(ext: Object, handle: int, key: String) -> bool:
	return _modifier_rows(ext, handle).has(key)


# --------------------------------------------------------------------------- #
# Catalog derivation helpers. Nothing below restates a game number.
# --------------------------------------------------------------------------- #
func _definition(catalog: Resource, key: String) -> Resource:
	if catalog == null or key.is_empty():
		return null
	for candidate in catalog.definitions:
		if candidate != null and String(candidate.key) == key:
			return candidate
	return null


func _term_count(definition: Resource, stat: String) -> int:
	var count := 0
	for term in definition.terms:
		if term != null and String(term.stat_key) == stat:
			count += 1
	return count


## Applies a modifier definition's terms for ONE stat to `base`, using the same
## operation semantics as the runtime table (0 add, 1 subtract, 2 multiply,
## 3 divide). Magnitude 1.0 / one stack are asserted separately, so the definition
## alone determines the value.
func _stat_value(definition: Resource, stat: String, base: float) -> float:
	var value := base
	for term in definition.terms:
		if term == null or String(term.stat_key) != stat:
			continue
		match int(term.operation):
			0: value += float(term.value)
			1: value -= float(term.value)
			2: value *= float(term.value)
			3:
				if not is_zero_approx(float(term.value)):
					value /= float(term.value)
	return value


## The country stat implied by the ACTIVE synergy set the runtime reports, with each
## synergy's magnitude applied through the modifier definition it names. Comparing
## this against `evaluate_modifier_stat` is what makes every value assertion a
## catalog check rather than a literal.
func _expected_country_stat(stat: String, active: PackedInt32Array) -> float:
	var offsets: PackedInt32Array = _ideology_ir["synergy_effect_offsets"]
	var domains: PackedInt32Array = _ideology_ir["synergy_effect_domains"]
	var keys: PackedStringArray = _ideology_ir["synergy_effect_definition_keys"]
	var value := 1.0
	for synergy in active:
		if synergy < 0 or synergy + 1 >= offsets.size():
			continue
		for row in range(int(offsets[synergy]), int(offsets[synergy + 1])):
			if int(domains[row]) != MODIFIER_DOMAIN_COUNTRY:
				continue
			var definition := _definition(_modifier_catalog, String(keys[row]))
			if definition != null:
				value = _stat_value(definition, stat, value)
	return value


func _synergy_definition_key() -> String:
	var synergy := int(_dense.get("__synergy", -1))
	if synergy < 0:
		return ""
	var offsets: PackedInt32Array = _ideology_ir["synergy_effect_offsets"]
	var keys: PackedStringArray = _ideology_ir["synergy_effect_definition_keys"]
	var begin := int(offsets[synergy])
	if begin + 1 > keys.size():
		return ""
	return String(keys[begin])


## The modifier definition a card's own persistent row uses. Read from the authored
## Resource rather than guessed: the row lives on the card's level entries.
func _card_modifier_key(dense: int) -> String:
	var ids: PackedStringArray = _ideology_ir["ideology_ids"]
	return _card_modifier_key_for(String(ids[dense]))


func _card_modifier_key_for(card_key: String) -> String:
	var card: Resource = _card_resource(card_key)
	for key in _card_modifier_keys(card):
		return key
	return ""


## Every country-domain modifier definition key a card's levels name.
func _card_modifier_keys(card: Resource) -> PackedStringArray:
	var keys := PackedStringArray()
	if card == null:
		return keys
	for level in card.levels:
		if level == null:
			continue
		for effect in level.persistent_effects:
			if effect == null:
				continue
			if int(effect.domain) != MODIFIER_DOMAIN_COUNTRY:
				continue
			var key := String(effect.definition_key)
			if key.is_empty() or keys.has(key):
				continue
			# Cell programs and modifier definitions share the column; only the
			# modifier catalog can tell which is which.
			if _definition(_modifier_catalog, key) != null:
				keys.append(key)
	return keys


func _card_resource(card_key: String) -> Resource:
	if _ideology_catalog == null:
		return null
	for candidate in _ideology_catalog.definitions:
		if candidate != null and String(candidate.id) == card_key:
			return candidate
	return null


## 1-based tier index `tier` -> the understanding value that unlocks it.
func _level_threshold(dense: int, tier: int) -> int:
	var offsets: PackedInt32Array = _ideology_ir["level_offsets"]
	var thresholds: PackedInt64Array = _ideology_ir["level_thresholds_q16"]
	var begin := int(offsets[dense])
	var index := begin + tier
	if index < 0 or index >= thresholds.size():
		return -1
	return int(thresholds[index])


## The synergy with `min_count >= 2` whose requirement slice covers both `first`
## and `second`. Used for the count half of the rule.
func _find_count_synergy(first: int, second: int) -> int:
	var min_counts: PackedInt32Array = _ideology_ir["synergy_min_counts"]
	var offsets: PackedInt32Array = _ideology_ir["synergy_requirement_offsets"]
	var requirement_ids: PackedInt32Array = _ideology_ir[
		"synergy_requirement_ideology_ids"]
	for synergy in min_counts.size():
		if int(min_counts[synergy]) < 2:
			continue
		var has_first := false
		var has_second := false
		for row in range(int(offsets[synergy]), int(offsets[synergy + 1])):
			if int(requirement_ids[row]) == first:
				has_first = true
			elif int(requirement_ids[row]) == second:
				has_second = true
		if has_first and has_second:
			return synergy
	return -1


func _synergy_needed(synergy: int) -> int:
	var min_counts: PackedInt32Array = _ideology_ir["synergy_min_counts"]
	var offsets: PackedInt32Array = _ideology_ir["synergy_requirement_offsets"]
	var needed := int(min_counts[synergy])
	if needed <= 0:
		needed = int(offsets[synergy + 1]) - int(offsets[synergy])
	return needed


## How many of `synergy`'s requirement rows are held, evaluated from the snapshot's
## own (level, location) columns using the same predicate as
## `synergy_requirements_met` (level >= minimum_level, mask & (1 << location)).
func _active_member_count(synergy: int, snapshot: Dictionary) -> int:
	var offsets: PackedInt32Array = _ideology_ir["synergy_requirement_offsets"]
	var requirement_ids: PackedInt32Array = _ideology_ir[
		"synergy_requirement_ideology_ids"]
	var requirement_levels: PackedInt32Array = _ideology_ir[
		"synergy_requirement_min_levels"]
	var requirement_masks: PackedByteArray = _ideology_ir[
		"synergy_requirement_location_masks"]
	var ids: PackedInt32Array = _frame(snapshot, "idea_ids", -1)
	var levels: PackedInt32Array = _frame(snapshot, "levels", -1)
	var locations: PackedInt32Array = _frame(snapshot, "locations", LOCATION_INACTIVE)
	var held := 0
	for row in range(int(offsets[synergy]), int(offsets[synergy + 1])):
		var wanted := int(requirement_ids[row])
		for index in ids.size():
			if int(ids[index]) != wanted:
				continue
			if int(levels[index]) < int(requirement_levels[row]):
				continue
			if (int(requirement_masks[row]) & (1 << int(locations[index]))) == 0:
				continue
			held += 1
			break
	return held


# --------------------------------------------------------------------------- #
# Small utilities.
# --------------------------------------------------------------------------- #
func _support_gate_off(native: Dictionary) -> Dictionary:
	# `stance_count == 0` is the documented "no support gate" shape. This fixture
	# measures the transition state machine, not the political price of adopting.
	var out: Dictionary = native.duplicate(false)
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


func _terrain_id(member: String) -> int:
	var enum_table: Dictionary = load(
		"res://scripts/geography/terrain_type.gd").TERRAIN
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
