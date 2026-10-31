extends SceneTree
## §11.7 time point 2: "structural transaction pending / successful ACK / rejected ACK".
##
## WHAT THE PLAN DEMANDS
##
##   `docs/plans/ideology-review/22-cell-program-cap-removal-plan-v3.md:799-809`
##   lists seven mandatory save time points. Point 2 is line 802:
##
##       结构事务 pending、成功 ACK、拒绝 ACK。
##
##   and line 809 is the rule for ALL of them:
##
##       每个时点比较连续运行与存档重载后的逐格有效因子、经济守恒结果、
##       一次性执行次数和业务状态。只测 fresh-world roundtrip 不足以通过。
##
##   So a save taken while a structural transaction is in flight must be compared
##   against the SAME timeline continued without a save -- never against a
##   freshly bootstrapped world.
##
## WHICH TRANSACTION THIS IS
##
##   The plan's §10.2 state machine (`...plan-v3.md:675-686`) runs a structural
##   intent through "既有 Effect/Modifier 结构事务与真实 ACK", and §8's ownership
##   table (`...plan-v3.md:242`) assigns "外部绑定、结构事务、一次性效果 ACK" to the
##   Effect domain. The transaction is therefore an `EffectRuntime` transaction:
##
##     lifecycle   submitted by the Effect evaluator (`effect_runtime.cpp:5437`),
##                 COMMITTED/ACKED as a whole, rejected as a whole
##     transitions `effect_runtime.cpp:5391-5399` (TRANSITION_APPLY for a managed
##                 lifecycle row that has not been applied yet)
##     ACK         `DCWorldExt.preflight_effect_transactions` ->
##                 `commit_effect_transactions` -> `ack_effect_transactions`
##                 (`gdext/src/world_ext_effect.cpp:1067-1080`, bound in
##                 `world_ext_bind_methods.cpp:663-668`). This is the same
##                 documented peer lifecycle `tests/effect/effect_runtime_test.gd`
##                 uses at lines 130-157.
##     rejection   `ack_effect_transactions` cannot produce it: a bad mask only
##                 increments a counter and leaves the row untouched
##                 (`effect_runtime.cpp:6744-6782`). A persisted REJECTED row is
##                 produced by exactly four paths -- native modifier ACK
##                 (`:5824-5832`), native country ACK (`:5995-6004`), native
##                 economy preflight (`:6183-6194`) and instance-generation
##                 supersession (`:2536-2547`). This fixture uses the last one,
##                 because it is the only one reachable with the fixture's own
##                 catalogs and no cross-domain adapter handshake:
##
##                   `DCWorldExt.submit_effect_instances` -> `submit_instances`
##                   -> `upsert_instance_pod` (`effect_runtime.cpp:3948`,
##                   `:2428`), and `upsert_instance_pod` rejects every unresolved
##                   transaction of the superseded generation at `:2536-2547`.
##
##   Both paths are exercised through the SAME instance, so the three sub-states
##   are three points of one timeline rather than three unrelated worlds.
##
## THE PROBE PROGRAM
##
##   A derived ideology card never opens an Effect transaction: its persistent
##   tier rows resolve to a declarative managed program and `emit_templates`
##   skips exactly those (`ideology_runtime.cpp:1688-1694`), which is why time
##   point 1 observes `pending_commands=0` throughout. A structural transaction
##   therefore has to be opened by a program of its own. This fixture appends one
##   (`test.structural_probe`) to the SAME domain catalog Resource before it is
##   compiled -- the substitution technique time point 1 already uses for
##   `cell.settlement` -- so both branches compile a byte-identical catalog and
##   `_catalog_hash` (checked by `restore`, `effect_runtime.cpp:7412`) matches.
##
##   The probe emits ONE modifier-domain command whose value comes from the
##   program (`CONST` -> `EMIT_COMMAND` with `VALUE_STACK_TOP`,
##   `effect_runtime.cpp:4736`). It is deliberately never dispatched to the
##   Modifier adapter, so the probe cannot perturb the two per-cell stats whose
##   exact equality is the §11.7 measurement; what it changes is only the
##   transaction state machine, which is what this time point isolates.
##
## THE CARD'S OWN STRUCTURAL TRANSACTION
##
##   Equipping the card also opens an Effect transaction of its own, and the
##   fixture MEASURES it rather than assuming it: `_prepare` polls the world right
##   after the equip lead and prints
##     ids=[1] keys=["ideology.persistent"] values=[65536]
##   i.e. one in-flight transaction carrying the card's persistent modifier row
##   (value 1.0). It comes from `emit_templates` (`ideology_runtime.cpp:1666`),
##   which emits the level's persistent row under the `ideology.command` program
##   (`:1718`) whenever the row does not resolve to a declarative managed program.
##
##   That transaction is SETTLED in the prefix (`_settle_transitions`), through the
##   same production handshake the daily graph runs
##   (`world_ext_bind_methods.cpp:635-648`):
##
##     dispatch_effect_native_modifier() -> run_modifier_daily(0)
##                                       -> ack_effect_native_modifier()
##                                       -> run_ideology_daily(0)   (the poll)
##
##   Settling is not cosmetic. Plan §10.1 ("while pending the OLD basis is used:
##   ... an equip card that is not yet confirmed produces no contribution") is
##   implemented in `collect_effect_activations`
##   (`ideology_runtime.cpp:2313-2321`), so an equip whose transaction is still
##   PLANNED contributes NOTHING and the derived cell layer is legitimately EMPTY.
##   Every per-cell column of §11.7 would then be the comparison of two empty
##   layers -- the very thing the NEG2 control exists to forbid. With the equip ACKed
##   the card is ACTIVE at level 0 and the layer carries its `public_hygiene_l1`
##   rows on all 42 owned cells x 2 stats.
##
##   The PROBE's transaction is the one that is deliberately left PLANNED: it says
##   so in the three sub-states below, and it is never dispatched to the Modifier
##   adapter. That is why the row counts are read honestly -- `poll` is filtered to
##   the probe's rows by `source_instance_id` (`_probe_poll`), so the card's own
##   (already compacted-away) ACKed row cannot be mistaken for the subject, while
##   `report()` stays world-wide and is only used for the rejected-row count (which
##   no ideology path can produce here -- the `_step_generation` attribution measures
##   that the count moves only when a probe generation is superseded).
##
## THE THREE SUB-STATES, AND HOW EACH IS PROVEN
##
##   S1 pending   the fire produced a PLANNED transaction that nobody ACKed.
##                Proven by the probe's `poll` row (status PLANNED, required mask
##                1, the program's exact value) and
##                `explain_effect().effect_applied==false`,
##                `last_acked_fire_sequence==0`, `fire_sequence==1`.
##   S2 ACKed     preflight+commit+ACK completed. ACKed rows are compacted away
##                (`compact_terminal_transactions`), so the durable proofs are an
##                empty probe `poll` and the latched `effect_applied==true` /
##                `last_acked_fire_sequence==1` / `applied_stack_count==1` that
##                only `apply_acked_instance_transition` can write
##                (`effect_runtime.cpp:4349-4391`).
##   S3 rejected  a newer generation of the same instance superseded the in-flight
##                transaction. Proven by `rejected_transactions==1` (a status
##                count, so it survives `capture`/`restore`) plus the attribution
##                measured in `_step_generation`: the instance's own in-flight
##                count drops 1->0 while the rejected row count grows 0->1, and
##                the no-op bump at generation 2 shows the opposite (nothing in
##                flight, nothing rejected).
##
##                `apply_rejected_instance_transition` deliberately leaves a
##                rejected program retryable (`effect_runtime.cpp:4394-4413`), so
##                the instance re-issues the intent on its next due day and the
##                save point carries BOTH the terminal REJECTED row and the fresh
##                PLANNED retry. That is the real shape of "rejected ACK" in this
##                runtime, not a simplification.
##
##   Every predicate is asserted BOTH at the save point and immediately after the
##   payload is restored into a freshly built runtime, so "the sub-state came
##   back" is measured rather than assumed.
##
## A SAVE / LOAD DEFECT THIS TIME POINT FOUND
##
##   A PKEF captured in the narrow window between the supersession rejection and
##   the instance's retry fire cannot be restored at all:
##   `upsert_instance_pod` rejects the superseded generation's transactions and
##   resets `fire_sequence` to 0 (`effect_runtime.cpp:2536-2557`), while `capture`
##   writes the rejected row's `transition_fire_sequence` (1) next to that 0 and
##   `restore` refuses the pair (`effect_runtime.cpp:7672-7677`) with
##   `pkef_transaction_transition_invalid`. The fixture does not depend on that
##   window -- S3 is taken after the retry fire, where
##   `transition_fire_sequence <= fire_sequence` holds again -- but it MEASURES
##   the window (NEG1 block, `[sv2/FINDING]`) and accepts either outcome, so a
##   future fix cannot make this fixture lie.
##
## WHAT IS COMPARED (the four §11.7 columns)
##
##   per-cell      presence / derived add / effective value on ALL 64 cells for
##                 two stats (one positive card command, one ".cut" command), read
##                 through the production shape of `get_effective_stat_value`
##   conservation  `get_economy_committed_audit_report` population/money/goods
##                 errors on both sides
##   one-shot      the probe's durable fire/ACK counters plus the ideology
##                 one-shot instance count, which must be 0 (I01: a derived card
##                 creates no Effect instances)
##   business      `get_ideology_business_state().hash` and its sections, the
##                 card snapshot, and the effect-transaction status row counts
##
##   Deliberately NOT compared across branches: `sample_day` / `layer_generation`
##   of the derived layer report. PKID does not persist the derived front
##   (`ideology_runtime.cpp:6387`), so a reload necessarily installs the rebuilt
##   front on its first post-restore day while the continuous run keeps the
##   install it already had. §11.7 compares the per-cell factors, not the cache's
##   install timestamp; the front's CONTENT is compared exactly (fingerprint over
##   both stats on all cells), which is the stronger statement. The values are
##   still printed so a change in shape stays visible.
##
## SAVE / RESTORE API (the production pair, in the production order)
##
##   `capture_effect_state()` / `restore_effect_state()` and
##   `capture_ideology_state()` / `restore_ideology_state()`. The shipped
##   coordinator registers PKEF before PKID and restores in that order
##   (`scripts/game/game_save_coordinator.gd:516` then `:542`; the bodies are
##   `:1139-1145` and `:1148-1156`), so this fixture captures and restores PKEF
##   first as well.
##
## NEGATIVE CONTROLS
##
##   Two, both counted separately from the fixture's own tally and both reported
##   with their observed failure count:
##     NEG1  the S1 (pending) payload is continued with the S3 script -- i.e. the
##           wrong sub-state's payload -- and must be DETECTED. It is detected on
##           the transaction columns (rejected row count, in-flight id, plan
##           hash, idempotency key, instance generation), not on the per-cell
##           columns: the probe deliberately cannot move an effective factor, so
##           a per-cell mismatch there would mean the probe had leaked into the
##           ideology layer.
##     NEG2  the S1 payload is restored and continued, but the ideology days are
##           skipped, so the derived front is never rebuilt: every per-cell column
##           must then report mismatches. This is the control that proves the
##           per-cell comparison is real rather than a comparison of two empties.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_save_transaction_states_test.gd

const WIDTH := 8
const HEIGHT := 8
## `c >> 3` is `c / 8` without an integer-division warning for the row index.
const ROW_SHIFT := 3
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261028
## A permanent cell card (kind 12 = SELECTOR_OWN_TERRITORY, lifecycle 0). Same
## card time point 1 uses, so the derived path is the one under test.
const CARD_KEY := "idea.public_hygiene"
const STAT_ADD := "economy.city.birth_factor"
const STAT_CUT := "economy.city.need.housing.consumption_factor"
const Q16_ONE := 65536
## The level-1 persistent program of the card.
const PROGRAM_KEY := "ideology.effect.public_hygiene_l1"

## The structural-transaction probe (see the header).
const PROBE_KEY := "test.structural_probe"
const PROBE_COMMAND_KEY := "test.structural_probe.command"
const PROBE_DEFINITION_KEY := "test.structural_probe.modifier"
const PROBE_INSTANCE_ID := 9101
const PROBE_TARGET_GENERATION := 1
const PROBE_VALUE_Q16: int = 2 * Q16_ONE

## `EffectRuntime` transaction status codes (`effect_runtime.h`): 1 PLANNED,
## 2 PREFLIGHTED, 3 COMMITTED, 4 ACKED, 5 REJECTED. Only PLANNED is ever expected
## in a `poll` row here -- ACKED rows are compacted away and REJECTED rows are not
## returned by `poll_transactions` at all.
const TX_PLANNED := 1

const SUBSTATE_PENDING := "pending"
const SUBSTATE_ACKED := "acked"
const SUBSTATE_REJECTED := "rejected"

## One ideology day, driven to completion and repeated: the equip lead is applied
## by the daily slice, exactly as in time point 1.
const PREFIX_DAY0_SLICES := 4
## Upper bound on the settle rounds of `_settle_transitions`. One round is enough
## for an equip (dispatch -> modifier day -> ACK -> poll), two when the derived fold
## needs a second slice; 8 leaves room without ever spinning.
const SETTLE_ROUND_LIMIT := 8
## Days both branches must still run AFTER the last save point.
const DAYS_AFTER_SAVE := 2

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")

var _checks := 0
var _failures := 0
var _catalogs := {}
## Negative controls are expected to fail: their per-check lines are still
## printed (that IS the evidence) but they are not written to stderr.
var _suppress_stderr := false


func _init() -> void:
	_run()


func _run() -> void:
	_catalogs = _compile_catalogs()
	if _catalogs.is_empty():
		_finish()
		return
	var ids: PackedStringArray = _catalogs["native_ideology"].get(
		"ideology_ids", PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("the card is in the compiled ideology catalog", dense >= 0,
		"%s -> dense=%d of %d" % [CARD_KEY, dense, ids.size()])
	if dense < 0:
		_finish()
		return
	_catalogs["dense"] = dense
	var steps: Array = _steps()

	# ── one continuous timeline, saved at the three sub-states ────────────
	var continuous: Dictionary = _prepare("continuous")
	var save_pending: Dictionary = _save_point(
		continuous, "S1/pending", SUBSTATE_PENDING)
	_run_steps(continuous, 0, 1, "continuous")
	var save_acked: Dictionary = _save_point(
		continuous, "S2/acked", SUBSTATE_ACKED)
	# day 1 (no re-fire: the ACK is latched), re-issue generation 2, day 2 fires
	# it, generation 3 rejects that transaction.
	_run_steps(continuous, 1, 5, "continuous")
	# The REJECTED row is durable from here on. This payload is captured BEFORE
	# the instance's own retry fire and is kept only for the documented-window
	# probe in `_negative_controls` (see the header FINDING note).
	var pkef_pre_retry: PackedByteArray = continuous["ext"].capture_effect_state()
	_expect("the pre-retry PKEF payload is produced", not pkef_pre_retry.is_empty(),
		str(pkef_pre_retry.size()))
	_run_steps(continuous, 5, 6, "continuous")
	var save_rejected: Dictionary = _save_point(
		continuous, "S3/rejected", SUBSTATE_REJECTED)
	# The rest of the timeline runs WITHOUT a save in between: that is the
	# "continuous run" every reloaded branch is compared against.
	_run_steps(continuous, 6, steps.size(), "continuous")
	var reference: Dictionary = _capture_state(continuous, "continuous-final")

	# ── reload from each sub-state, then the SAME remaining timeline ──────
	var r1: Dictionary = _reload("reload-S1", save_pending, SUBSTATE_PENDING)
	_run_steps(r1, 0, steps.size(), "reload-S1")
	_compare(reference, _capture_state(r1, "reload-S1-final"), "S1(pending)")

	var r2: Dictionary = _reload("reload-S2", save_acked, SUBSTATE_ACKED)
	_run_steps(r2, 1, steps.size(), "reload-S2")
	_compare(reference, _capture_state(r2, "reload-S2-final"), "S2(acked)")

	var r3: Dictionary = _reload("reload-S3", save_rejected, SUBSTATE_REJECTED)
	_run_steps(r3, 6, steps.size(), "reload-S3")
	_compare(reference, _capture_state(r3, "reload-S3-final"), "S3(rejected)")

	_negative_controls(reference, save_pending, pkef_pre_retry, steps)
	_finish()


# ─────────────────────────────────────────────────────────────────────────
# negative controls
# ─────────────────────────────────────────────────────────────────────────

## Both controls restore a real payload and run real steps; only the pairing is
## wrong. Their checks are printed but rolled back out of the fixture's tally, and
## a single assertion per control records the OBSERVED failure count.
func _negative_controls(reference: Dictionary, save_pending: Dictionary,
		pkef_pre_retry: PackedByteArray, steps: Array) -> void:
	_suppress_stderr = true

	# ── NEG1: wrong sub-state's payload ───────────────────────────────────
	print("[sv2/NEG1] restoring the S1 (pending) payload but continuing with the "
		+ "S3 (rejected) script")
	var n1: Dictionary = _new_world("neg1")
	_restore_payload(n1["ext"], save_pending, "neg1")
	var n1_checkpoint := _counters()
	_run_steps(n1, 6, steps.size(), "neg1")
	var n1_state := _capture_state(n1, "neg1-final")
	var n1_compare := _isolated_compare(reference, n1_state, "NEG1(wrong payload)")
	_restore_counters(n1_checkpoint)
	_expect("NEG1: continuing a PENDING payload with the rejected-state script is "
		+ "detected by the comparison", int(n1_compare["failures"]) > 0,
		str(n1_compare))
	print("[sv2/NEG1] comparison checks=%d failures=%d"
		% [int(n1_compare["checks"]), int(n1_compare["failures"])])

	# ── documented window: the payload taken BEFORE the retry fire ────────
	# Not a control: a measurement of a real save/load window this fixture found.
	# `upsert_instance_pod` rejects the superseded generation's transactions and
	# resets `fire_sequence` to 0 (`effect_runtime.cpp:2536-2557`), but `capture`
	# writes the rejected row's `transition_fire_sequence` (1) next to that 0, and
	# `restore` refuses the pair (`effect_runtime.cpp:7672-7677`,
	# `pkef_transaction_transition_invalid`). Either outcome is accepted here so
	# this fixture records the finding instead of depending on it.
	var pre_retry: Dictionary = n1["ext"].restore_effect_state(pkef_pre_retry)
	var pre_retry_reason := _reason(pre_retry)
	print("[sv2/FINDING] a PKEF captured between the supersession rejection and "
		+ "the retry fire restores=%s reason=%s"
		% [str(pre_retry.get("ok", false)), pre_retry_reason])
	_expect("the pre-retry REJECTED payload either restores or is refused with "
		+ "pkef_transaction_transition_invalid",
		bool(pre_retry.get("ok", false))
			or pre_retry_reason == "pkef_transaction_transition_invalid",
		pre_retry_reason)

	# ── NEG2: the reload that never rebuilds the derived front ────────────
	print("[sv2/NEG2] restoring the S1 payload and running the continuation "
		+ "WITHOUT any ideology day")
	var n2: Dictionary = _new_world("neg2")
	_restore_payload(n2["ext"], save_pending, "neg2")
	var n2_checkpoint := _counters()
	_run_steps_without_ideology_days(n2, 0, steps.size(), "neg2")
	var n2_state := _capture_state(n2, "neg2-final")
	var n2_compare := _isolated_compare(reference, n2_state, "NEG2(no rebuild)")
	_restore_counters(n2_checkpoint)
	_expect("NEG2: a reload that never rebuilds the derived front is detected on "
		+ "the per-cell columns", int(n2_compare["failures"]) > 0,
		str(n2_compare))
	print("[sv2/NEG2] comparison checks=%d failures=%d"
		% [int(n2_compare["checks"]), int(n2_compare["failures"])])

	_suppress_stderr = false


func _counters() -> Dictionary:
	return {"checks": _checks, "failures": _failures}


func _restore_counters(snapshot: Dictionary) -> void:
	_checks = int(snapshot["checks"])
	_failures = int(snapshot["failures"])


func _isolated_compare(reference: Dictionary, other: Dictionary,
		tag: String) -> Dictionary:
	var before := _counters()
	_compare(reference, other, tag)
	var out := {"checks": _checks - int(before["checks"]),
		"failures": _failures - int(before["failures"])}
	_restore_counters(before)
	return out


# ─────────────────────────────────────────────────────────────────────────
# the timeline
# ─────────────────────────────────────────────────────────────────────────

## Every step both branches run, in order. The save points are:
##   S1 = before index 0 (the fire produced a PLANNED transaction)
##   S2 = after  index 0 (preflight/commit/ACK completed)
##   S3 = after  index 5 (the generation bump rejected the in-flight transaction
##        and the instance has re-issued the intent)
##
## `generation` steps re-issue the SAME structural intent for a newer incarnation
## of the same instance -- that is how a structural transaction really gets
## superseded (`effect_runtime.cpp:2536-2547`). The bump at index 2 supersedes
## nothing (the row is already ACKed), the bump at index 4 is the rejection.
func _steps() -> Array:
	return [
		{"kind": "ack"},
		{"kind": "effect_day", "day": 1},
		{"kind": "generation", "generation": 2, "due": 2, "expects_reject": false},
		{"kind": "effect_day", "day": 2},
		{"kind": "generation", "generation": 3, "due": 2, "expects_reject": true},
		{"kind": "effect_day", "day": 3},
		{"kind": "effect_day", "day": 4},
		{"kind": "economy_day", "day": 1},
		{"kind": "ideology_day", "day": 1},
		{"kind": "economy_day", "day": 2},
		{"kind": "ideology_day", "day": 2},
		{"kind": "drain"},
	]


func _run_steps(world: Dictionary, begin: int, end: int, label: String) -> void:
	var ext: Object = world["ext"]
	for index in range(begin, mini(end, _steps().size())):
		var step: Dictionary = _steps()[index]
		match String(step["kind"]):
			"ack":
				_step_ack(ext, label)
			"effect_day":
				_run_one_effect_day(ext, int(step["day"]), label)
			"generation":
				_step_generation(world, int(step["generation"]), int(step["due"]),
					bool(step["expects_reject"]), label)
			"economy_day":
				_advance_economy_day(ext, int(step["day"]))
			"ideology_day":
				_run_one_ideology_day(ext, int(step["day"]), label)
			"drain":
				_step_drain(ext, DAYS_AFTER_SAVE, label)


## NEG2 only: identical to `_run_steps` minus every ideology day.
func _run_steps_without_ideology_days(world: Dictionary, begin: int, end: int,
		label: String) -> void:
	var ext: Object = world["ext"]
	for index in range(begin, mini(end, _steps().size())):
		var step: Dictionary = _steps()[index]
		match String(step["kind"]):
			"ack":
				_step_ack(ext, label)
			"effect_day":
				_run_one_effect_day(ext, int(step["day"]), label)
			"generation":
				_step_generation(world, int(step["generation"]), int(step["due"]),
					bool(step["expects_reject"]), label)
			"economy_day":
				_advance_economy_day(ext, int(step["day"]))
			"ideology_day":
				pass
			"drain":
				pass


# ─────────────────────────────────────────────────────────────────────────
# catalogs
# ─────────────────────────────────────────────────────────────────────────

func _compile_catalogs() -> Dictionary:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"
	# `EffectDomainCatalog.build()` short-circuits to a PRECOMPILED catalog when
	# one is cached; passing the ideology effects explicitly bypasses that cache.
	var domain: Resource = EffectDomainCatalogScript.build(
		null, IdeologyEffectCatalogScript.load_default())
	_install_satisfiable_tag(domain)
	_install_probe_program(domain)
	var effect_ir: Dictionary = domain.compile_native_catalog()
	effect_ir.erase("ok")
	var mod_ir: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	mod_ir.erase("ok")
	var catalog: Resource = IdeologyCatalogScript.load_default()
	var native_ideology: Dictionary = catalog.compile_native_catalog(
		country_ir, country_ir)
	native_ideology.erase("ok")
	if country_ir.is_empty() or effect_ir.is_empty() or mod_ir.is_empty() \
			or native_ideology.is_empty():
		_expect("all four native catalogs compile", false, "one of them is empty")
		return {}
	var keys: PackedStringArray = effect_ir.get("effect_keys", PackedStringArray())
	if keys.find(PROBE_KEY) < 0:
		_expect("the structural probe program is compiled into the effect catalog",
			false, "%s missing from %d programs" % [PROBE_KEY, keys.size()])
		return {}
	print("[sv2/catalog] %d effect programs, probe dense id=%d"
		% [keys.size(), keys.find(PROBE_KEY)])
	return {
		"country_ir": country_ir, "profile": profile, "effect_ir": effect_ir,
		"mod_ir": mod_ir, "native_ideology": native_ideology,
	}


## Declares `cell.settlement` as `cell.population >= 30`, which every cell of this
## fixture satisfies. The shipped predicate reads building data that a
## bootstrapped economy does not have, so a card filtered on it matches NOTHING --
## correct behaviour indistinguishable from "the card never equipped".
func _install_satisfiable_tag(domain: Resource) -> void:
	var rows: Array[Dictionary] = [{
		"metric": "cell.population",   # dense id 9 -- never move this
		"op": 0,                       # TARGET_TAG_GTE
		"threshold_q16": 30 * Q16_ONE,
		"clause": 0,
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


## Appends the structural probe to the domain catalog RESOURCE. The compiled
## Dictionary is never patched: `compile_native_catalog` owns the dense id order
## and `restore` validates `_catalog_hash`, so an edit after compilation would
## desynchronise exactly what this time point is about.
func _install_probe_program(domain: Resource) -> void:
	var definition := EffectDefinition.new()
	definition.key = StringName(PROBE_KEY)
	definition.version = 1
	definition.cadence_days = 1
	# `condition_count + instruction_count` must not exceed `max_work`
	# (`effect_runtime.cpp:1152-1155`); this program is CONST + EMIT_COMMAND.
	definition.max_work = 2
	# `lifecycle != 0` is what makes the row MANAGED
	# (`effect_runtime.cpp:2956`). Only a managed row carries an instance
	# transition on its fire (`:5391`) and therefore only a managed row's ACK
	# latches something `capture`/`restore` can be proved to have kept
	# (`apply_acked_instance_transition`, `:4349`). lifecycle 1 also needs a
	# positive `duration_days` and a command (`:1001`, `:1040`).
	definition.lifecycle = 1
	definition.duration_days = 30
	definition.stack_policy = 0
	definition.max_stacks = 1

	var constant := EffectInstruction.new()
	constant.op = 1       # CONST
	constant.value_q16 = PROBE_VALUE_Q16
	var emit := EffectInstruction.new()
	emit.op = 11          # EMIT_COMMAND
	emit.arg0 = 0
	definition.instructions = [constant, emit]

	var command := EffectCommand.new()
	command.action = 1            # MODIFIER command
	command.domain = 3            # ModifierRuntime domain (pinned by
	command.opcode = 1            # `_native_command_error`, effect_catalog.gd:328)
	command.target_resolver = 2   # TARGET_INSTANCE
	command.value_mode = 1        # VALUE_STACK_TOP
	command.duration_days = -1
	command.stacks = 1
	command.command_key = StringName(PROBE_COMMAND_KEY)
	command.definition_key = StringName(PROBE_DEFINITION_KEY)
	definition.commands = [command]

	var definitions: Array[Resource] = domain.definitions.duplicate()
	definitions.append(definition)
	domain.definitions = definitions


# ─────────────────────────────────────────────────────────────────────────
# world construction (identical for every branch)
# ─────────────────────────────────────────────────────────────────────────

func _new_world(label: String) -> Dictionary:
	var country_ir: Dictionary = _catalogs["country_ir"]
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	# Entities BEFORE slots: `write_*_range` does not grow a slot.
	ext.create_entities(CELLS)
	_ext_fill_environment(ext)
	_expect("%s: economy configures" % label,
		bool(ext.configure_economy(country_ir, _catalogs["profile"], CELLS, SEED)
			.get("ok", false)))
	var effects_cfg: Dictionary = ext.configure_effects(_catalogs["effect_ir"])
	_expect("%s: effects configure" % label, bool(effects_cfg.get("ok", false)),
		_reason(effects_cfg))
	_expect("%s: modifiers configure" % label,
		bool(ext.configure_modifiers(_catalogs["mod_ir"], CELLS).get("ok", false)))
	_expect("%s: country configures" % label,
		bool(ext.configure_country(country_ir, {
			"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": PackedStringArray(["tech.hunting"]),
		}, CELLS, SEED).get("ok", false)))

	# A scattered 2/3 of the grid: (x + 2y) % 3 != 0. Non-contiguous on purpose --
	# a uniform "everything is covered" territory would make a per-cell comparison
	# unable to see a shifted or dropped cell index.
	var owned_cells := PackedInt32Array()
	for c in range(CELLS):
		var x: int = c % WIDTH
		var y: int = c >> ROW_SHIFT
		if (x + 2 * y) % 3 != 0:
			owned_cells.append(c)
	_expect("%s: the fixture territory is a proper subset of the grid" % label,
		owned_cells.size() > 0 and owned_cells.size() < CELLS,
		"%d of %d" % [owned_cells.size(), CELLS])

	var boot: Dictionary = ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.sv2"]),
		"country_names": PackedStringArray(["Save Point Two"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, owned_cells.size()]),
		"territory_cells": owned_cells,
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, _u8_zero(CELLS))
	_expect("%s: the country bootstraps" % label, bool(boot.get("ok", false)),
		str(boot))
	var ideo_cfg: Dictionary = ext.configure_ideologies(_catalogs["native_ideology"])
	_expect("%s: ideologies configure" % label, bool(ideo_cfg.get("ok", false)),
		str(ideo_cfg.get("reason", ideo_cfg)))

	var owned := 0
	for c in range(CELLS):
		var cs: Dictionary = ext.get_country_cell_summary(c)
		if bool(cs.get("ok", false)) and bool(cs.get("owned", false)):
			owned += 1
	_expect("%s: bootstrap_country registered exactly the intended territory" % label,
		owned == owned_cells.size(), "%d vs %d" % [owned, owned_cells.size()])

	# `begin_or_reuse_economy_input_epoch` + one full day of slices leaves
	# `_epoch_active` false: the save points of this fixture all sit AFTER the
	# day-0 commit and BEFORE any further economy day, which is what lets the
	# reloaded branch own a byte-identical economy.
	var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1, "resource_generation": 1})
	_expect("%s: the economy epoch opens" % label, bool(epoch.get("ok", false)),
		str(epoch.get("reason", epoch.get("fatal_reason", "?"))))

	var econ_catalog: Dictionary = _catalogs.get("economy_catalog", {})
	if econ_catalog.is_empty():
		econ_catalog = EconomyCatalogScript.compile_native_catalog()
		_catalogs["economy_catalog"] = econ_catalog
	var sig_keys: PackedStringArray = econ_catalog.get(
		"signature_keys", PackedStringArray())
	var farmer: int = sig_keys.find("subsistence_farmer|default")
	var serf: int = sig_keys.find("serf|default")
	_expect("%s: the fixture resolves both bootstrap signatures" % label,
		farmer >= 0 and serf >= 0, "farmer=%d serf=%d" % [farmer, serf])
	var goods: int = (econ_catalog.get("good_ids", PackedStringArray())).size()
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods)
	stock.fill(0)
	var ci := PackedInt32Array()
	var si := PackedInt32Array()
	var pp := PackedInt64Array()
	var ff := PackedInt64Array()
	for c in range(CELLS):
		for pair in [[farmer, 20], [serf, 20]]:
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
	_expect("%s: the economy bootstraps" % label, bool(eb.get("ok", false)), str(eb))
	var slices := _advance_economy_day(ext, 0)
	_expect("%s: economy day 0 reaches its committed boundary" % label,
		slices > 0, str(slices))

	var handle := int(ext.get_country_cell_summary(owned_cells[0]).get(
		"country_handle", 0))
	_expect("%s: the fixture resolves the country handle" % label, handle != 0,
		str(handle))
	var economy: Dictionary = ext.get_economy_report()
	return {
		"label": label, "ext": ext, "handle": handle,
		"owned": owned_cells.size(), "owned_cells": owned_cells,
		"epoch_active": bool(economy.get("epoch_active", true)),
	}


func _ext_fill_environment(ext: Object) -> void:
	# The 10 environment slots `capture_environment` requires. Registered AFTER
	# `create_entities` so they are sized.
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


# ─────────────────────────────────────────────────────────────────────────
# prefix: equip the card and install the derived front, at economy day 0
# ─────────────────────────────────────────────────────────────────────────
##
## The prefix deliberately does NOT advance the economy past day 0, and it advances
## the ideology to day 1 (not further). Both facts are load-bearing:
##
##   * the economy is not part of PKEF/PKID, so a reloaded branch can only own the
##     same economy if neither branch had moved it before the save point;
##   * `run_ideology_daily(day)` accrues per day, so a reloaded branch that had to
##     replay days 1..n would double-credit them. The ideology reaches day 1 INSIDE
##     the prefix, i.e. BEFORE the payload is captured, so every reloaded branch
##     inherits that day's accrual from the save and the `ideology_day 1` step in
##     the continuation is a legal re-entry (`_last_day < day` is false,
##     `ideology_runtime.cpp:5019`), not a second credit.
##
## Day 1 is where the card's derived contribution first becomes publishable: plan
## §9.3 makes the projection confirmed on day D eligible only from D + 1, so the
## day-0 settle (below) is refused by `step_derived_rebuild` and day 1 is the first
## rebuild that may adopt it.
func _prepare(label: String) -> Dictionary:
	var world: Dictionary = _new_world(label)
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	_submit(ext, _batch(2, 0, -1, 64 * Q16_ONE, 1), handle)   # GRANT points
	_submit(ext, _batch(1, 0, int(_catalogs["dense"]), 0, 2), handle)  # DISCOVER
	_submit(ext, _batch(5, 0, int(_catalogs["dense"]), 0, 3), handle)  # EQUIP
	_run_ideology_days(ext, 0, PREFIX_DAY0_SLICES)
	# THE §10.1 SETTLE. The equip command only REQUESTED the transition; the card
	# contributes nothing to the derived layer until the transition's Effect
	# transactions are ACKed and polled (`ideology_runtime.cpp:2313-2321`). This runs
	# on day 0, before the probe exists, so the probe's own transaction stays
	# PLANNED -- which is what makes S1 the "pending" save point.
	_settle_transitions(ext, 0, label)
	# ── plan §9.3: confirmed on day 0 means ELIGIBLE FROM DAY 1 ──────────────
	#
	# The poll that just settled the equip records `confirmed_day = 0` and
	# `eligible_from_day = 1` (`ideology_runtime.cpp:3845-3846`), and
	# `step_derived_rebuild` RETURNS WITHOUT ADOPTING while
	# `day < eligible_from_day` (`:7045-7048`). Day 0's collect step runs inside
	# the same slice that polled the ACK, so it is refused: the card's projection
	# cannot be published on the day it was confirmed, only one day later. That
	# refusal is a legitimate state the plan asks to be covered, so it is asserted
	# here rather than skipped.
	var confirmed: Dictionary = ext.get_ideology_report()
	_expect("%s: the day-0 settle leaves the projection CONFIRMED (0) but not yet "
		% label + "ELIGIBLE (eligible_from_day == 1)",
		int(confirmed.get("derived_basis_confirmed_day", -1)) == 0
			and int(confirmed.get("derived_basis_eligible_day", -1)) == 1,
		"confirmed=%s eligible=%s" % [
			str(confirmed.get("derived_basis_confirmed_day", "?")),
			str(confirmed.get("derived_basis_eligible_day", "?"))])
	_expect("%s: the confirmation-day rebuild is REFUSED by the eligibility gate"
		% label,
		int(confirmed.get("derived_rebuild_gated_by_eligibility", 0)) > 0,
		"gated=%s" % str(confirmed.get(
			"derived_rebuild_gated_by_eligibility", "?")))
	var confirmed_layer: Dictionary = ext.get_derived_cell_layer_report()
	_expect("%s: nothing is published on the confirmation day itself" % label,
		not bool(confirmed_layer.get("installed", true))
			and int(confirmed_layer.get("cell_count", -1)) == 0,
		"installed=%s cells=%s" % [
			str(confirmed_layer.get("installed", "?")),
			str(confirmed_layer.get("cell_count", "?"))])
	# THE ELIGIBILITY DAY. Its rebuild is the first one allowed to adopt the
	# confirmed projection, so the front appears here, built FOR day 1. This is the
	# only ordering change the plan §9.3 contract asks of the fixture: read the
	# layer on or after `eligible_from_day`, never on the confirmation day.
	_run_one_ideology_day(ext, 1, label)
	_step_drain(ext, 1, label)
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	_expect("%s: the derived cell layer is installed before the first save point"
		% label, int(layer.get("installed", 0)) != 0
			and int(layer.get("cell_count", 0)) > 0, str(layer))
	_expect("%s: the front is built FOR the eligibility day (sample_day == 1)"
		% label, int(layer.get("sample_day", -1)) == 1,
		"sample_day=%s" % str(layer.get("sample_day", "?")))
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	_expect("%s: the card is equipped in the IDEOLOGY slot before the first save"
		% label, _active_locations(snapshot) > 0,
		str(snapshot.get("locations", "?")))
	print("[sv2/%s] prefix layer cells=%s business=%s"
		% [label, str(layer.get("cell_count", "?")),
			str(ext.get_ideology_business_state().get("hash", "?"))])
	# The §9.3 dates and the refusal count at the save point's basis. Printed so the
	# "the projection is confirmed and no longer gated" claim has a number in the
	# log, not only a passing assertion.
	print("[sv2/%s] basis confirmed_day=%s eligible_from_day=%s gated=%s"
		% [label, str(confirmed.get("derived_basis_confirmed_day", "?")),
			str(confirmed.get("derived_basis_eligible_day", "?")),
			str(ext.get_ideology_report().get(
				"derived_rebuild_gated_by_eligibility", "?"))])
	# Evidence for the header note on the card's OWN transaction: after the settle
	# the equip's row is ACKed and compacted away, so what is left here is the state
	# the save point really carries. Printed, not asserted -- the probe is submitted
	# AFTER this line, so nothing of the probe can hide in this number.
	var equip_poll: Dictionary = _pending_transactions(ext)
	print("[sv2/%s] prefix in-flight Effect transactions after the settle ids=%s "
		% [label, str(equip_poll.get("transaction_ids", "?"))]
		+ "keys=%s values=%s"
		% [str(equip_poll.get("command_keys", "?")),
			str(equip_poll.get("command_values_q16", "?"))])
	# The probe's structural transaction is opened here, so the first save point
	# is the PENDING one.
	var probe: Dictionary = _submit_probe(ext, 1, 0)
	_expect("%s: the structural probe instance is admitted" % label,
		int(probe.get("rejected", -1)) == 0 and bool(probe.get("ok", false)), str(probe))
	_run_one_effect_day(ext, 0, label)
	return world


# ─────────────────────────────────────────────────────────────────────────
# steps
# ─────────────────────────────────────────────────────────────────────────

func _step_ack(ext: Object, label: String) -> void:
	var poll: Dictionary = _probe_poll(ext)
	_expect("%s: exactly one probe transaction is in flight before the ACK"
		% label, int(poll["count"]) == 1, str(int(poll["count"])))
	if int(poll["count"]) != 1:
		return
	var ids: PackedInt64Array = poll["ids"]
	var masks: PackedInt32Array = poll["masks"]
	var statuses: PackedInt32Array = poll["statuses"]
	_expect("%s: the in-flight transaction is PLANNED with a real ACK mask"
		% label, int(statuses[0]) == TX_PLANNED and int(masks[0]) != 0,
		"status=%d mask=%d" % [int(statuses[0]), int(masks[0])])
	var batch := {
		"transaction_ids": PackedInt64Array([ids[0]]),
		"ack_masks": PackedInt32Array([masks[0]]),
	}
	# ACK cannot bypass preflight and commit (`effect_runtime.cpp:6716-6719`).
	var early: Dictionary = ext.ack_effect_transactions(batch)
	_expect("%s: an ACK straight from PLANNED is refused" % label,
		not bool(early.get("ok", true)), str(early))
	var pre: Dictionary = ext.preflight_effect_transactions(batch)
	_expect("%s: the structural transaction preflights" % label,
		bool(pre.get("ok", false)), str(pre))
	var commit: Dictionary = ext.commit_effect_transactions(batch)
	_expect("%s: the structural transaction commits" % label,
		bool(commit.get("ok", false)), str(commit))
	var ack: Dictionary = ext.ack_effect_transactions(batch)
	_expect("%s: the structural transaction is ACKed" % label,
		bool(ack.get("ok", false)) and int(ack.get("acknowledged", 0)) == 1, str(ack))


## Re-issuing the same structural intent on a newer generation. `upsert_instance_pod`
## rejects every still-unresolved transaction of the superseded generation
## (`effect_runtime.cpp:2536-2547`); this step MEASURES that instead of assuming
## it, and attributes the rejection to this instance (the fixture's only source of
## rejections) by requiring the report's rejected row count to grow by exactly one
## while the instance's own in-flight count drops to zero.
func _step_generation(world: Dictionary, generation: int, due_day: int,
		expects_reject: bool, label: String) -> void:
	var ext: Object = world["ext"]
	var before: Dictionary = _probe_poll(ext)
	var rejected_before := int(ext.get_effect_report().get(
		"rejected_transactions", -1))
	var result: Dictionary = _submit_probe(ext, generation, due_day)
	_expect("%s: the structural intent is re-issued for generation %d"
		% [label, generation],
		bool(result.get("ok", false)) and int(result.get("rejected", -1)) == 0,
		str(result))
	var after: Dictionary = _probe_poll(ext)
	var rejected_after := int(ext.get_effect_report().get(
		"rejected_transactions", -1))
	if expects_reject:
		_expect("%s: the generation bump REJECTED the in-flight structural "
			% label + "transaction",
			int(before["count"]) == 1 and int(after["count"]) == 0
				and rejected_after == rejected_before + 1,
			"in_flight %d->%d rejected %d->%d" % [int(before["count"]),
				int(after["count"]), rejected_before, rejected_after])
		print("[sv2/%s] supersession: in_flight %d->%d, rejected rows %d->%d"
			% [label, int(before["count"]), int(after["count"]), rejected_before,
				rejected_after])
	else:
		_expect("%s: a bump with nothing in flight rejects nothing (control on "
			+ "the attribution above)", rejected_after == rejected_before,
			"rejected %d->%d" % [rejected_before, rejected_after])


func _step_drain(ext: Object, day: int, label: String) -> void:
	# If a day's slices ended before the sharded rebuild folded, drain it
	# explicitly. `complete` must be true either way.
	var drained: Dictionary = ext.drain_derived_cell_layer(day)
	_expect("%s: the derived rebuild has no work left after day %d" % [label, day],
		bool(drained.get("complete", false)), str(drained))


# ─────────────────────────────────────────────────────────────────────────
# ideology / effect / economy driving
# ─────────────────────────────────────────────────────────────────────────

## One ideology day, driven to completion. `run_ideology_daily` is a SLICE stage:
## a single call may come back `done=false` with the day still in progress.
func _run_one_ideology_day(ext: Object, day: int, label: String) -> bool:
	var done := false
	var last := {}
	for _i in range(512):
		last = ext.run_ideology_daily(day)
		if not bool(last.get("ok", true)):
			_expect("%s: ideology day %d reports ok" % [label, day], false, str(last))
			return false
		if bool(last.get("done", false)):
			done = true
			break
	_expect("%s: ideology day %d completes" % [label, day], done, str(last))
	return done


func _run_ideology_days(ext: Object, day: int, count: int) -> void:
	for _i in range(count):
		_run_one_ideology_day(ext, day, "prefix")


## Settles every in-flight ideology transition (plan §10.1).
##
## `equip()` only REQUESTS the transition: `start_transition` writes
## `state.location`/`state.level` at request time (`ideology_runtime.cpp:3631-3634`)
## and only `poll_pending_transition` commits it once every Effect transaction of
## the transition is ACKED (`:3776-3836`). Plan §10.1 turns that into an observable
## rule -- an equip card that is not yet confirmed produces no contribution,
## implemented in `collect_effect_activations` (`:2313-2321`) -- so a card whose
## equip is still pending contributes NOTHING and the derived cell layer stays
## empty.
##
## The order is the production daily graph's (`world_ext_bind_methods.cpp:635-648`):
##
##   dispatch_effect_native_modifier() -> run_modifier_daily(day)
##                                     -> ack_effect_native_modifier()
##                                     -> run_ideology_daily(day)   (the poll)
##
## `run_modifier_daily` is MANDATORY between the dispatch and the ACK: without it
## the dispatched rows never complete, the ACK keeps reporting `pending` and
## `pending_transitions` never returns to 0. The ideology day index is the caller's
## current day -- it only ever moves forward, and the poll stage runs on every slice
## regardless of the day, which is why re-entering the same day settles a transition
## requested earlier on that day.
##
## Called from `_prepare` only. The probe is submitted AFTER it, so the probe's own
## transaction stays PLANNED and S1 stays the "pending" save point.
func _settle_transitions(ext: Object, day: int, label: String) -> bool:
	for _round in range(SETTLE_ROUND_LIMIT):
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var acked: Dictionary = ext.ack_effect_native_modifier()
		if not bool(acked.get("ok", true)):
			_expect("%s: the native modifier ACK on day %d succeeds" % [label, day],
				false, str(acked))
			return false
		_run_one_ideology_day(ext, day, label)
		if int(ext.get_ideology_report().get("pending_transitions", -1)) == 0:
			return true
	_expect("%s: every ideology transition settles to 0 pending on day %d"
		% [label, day], false,
		str(ext.get_ideology_report().get("pending_transitions", "?")))
	return false


func _run_one_effect_day(ext: Object, day: int, label: String) -> void:
	var done := false
	var last := {}
	for _i in range(256):
		last = ext.run_effect_daily(day)
		if not bool(last.get("ok", true)):
			_expect("%s: effect day %d reports ok" % [label, day], false, str(last))
			return
		if bool(last.get("done", false)):
			done = true
			break
	_expect("%s: effect day %d completes" % [label, day], done, str(last))


func _advance_economy_day(ext: Object, day: int) -> int:
	for s in range(4096):
		var r: Dictionary = ext.run_economy_slice({"day_index": day, "tick_index": s})
		if bool(r.get("fatal", false)):
			_expect("economy day %d stays non-fatal" % day, false,
				str(r.get("fatal_reason", r)))
			return s
		if bool(r.get("done", false)):
			return s + 1
	_expect("economy day %d completes" % day, false, "4096 slices")
	return 0


# ─────────────────────────────────────────────────────────────────────────
# the structural probe instance
# ─────────────────────────────────────────────────────────────────────────

func _submit_probe(ext: Object, generation: int, due_day: int) -> Dictionary:
	return ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([PROBE_INSTANCE_ID]),
		"program_keys": PackedStringArray([PROBE_KEY]),
		"generations": PackedInt32Array([generation]),
		"target_handles": PackedInt64Array([0]),
		"target_generations": PackedInt32Array([PROBE_TARGET_GENERATION]),
		"next_due_days": PackedInt64Array([due_day]),
	})


func _pending_transactions(ext: Object) -> Dictionary:
	return ext.poll_effect_transactions(0, 16)


## `poll_effect_transactions` returns every in-flight transaction of the world,
## including the one the CARD's own equip opened (see the header note on
## `ideology.command`). This fixture's subject is the probe, so every assertion
## reads the probe's rows only, selected by `source_instance_id`.
func _probe_poll(ext: Object) -> Dictionary:
	var raw: Dictionary = _pending_transactions(ext)
	var ids := PackedInt64Array()
	var statuses := PackedInt32Array()
	var masks := PackedInt32Array()
	var hashes := PackedInt64Array()
	var values := PackedInt64Array()
	var keys := PackedStringArray()
	var idempotency := PackedInt64Array()
	var raw_ids: PackedInt64Array = raw.get("transaction_ids", PackedInt64Array())
	var sources: PackedInt64Array = raw.get("source_instance_ids",
		PackedInt64Array())
	var raw_statuses: PackedInt32Array = raw.get("statuses", PackedInt32Array())
	var raw_masks: PackedInt32Array = raw.get("required_ack_masks",
		PackedInt32Array())
	var raw_hashes: PackedInt64Array = raw.get("plan_hashes", PackedInt64Array())
	var raw_values: PackedInt64Array = raw.get("command_values_q16",
		PackedInt64Array())
	var raw_keys: PackedStringArray = raw.get("command_keys", PackedStringArray())
	var raw_idem: PackedInt64Array = raw.get("command_idempotency_keys",
		PackedInt64Array())
	var offsets: PackedInt32Array = raw.get("command_offsets", PackedInt32Array())
	for i in range(mini(int(raw.get("count", 0)), raw_ids.size())):
		if i >= sources.size() or int(sources[i]) != PROBE_INSTANCE_ID:
			continue
		ids.append(raw_ids[i])
		if i < raw_statuses.size():
			statuses.append(raw_statuses[i])
		if i < raw_masks.size():
			masks.append(raw_masks[i])
		if i < raw_hashes.size():
			hashes.append(raw_hashes[i])
		if i + 1 < offsets.size():
			for c in range(int(offsets[i]), int(offsets[i + 1])):
				if c < raw_values.size():
					values.append(raw_values[c])
				if c < raw_keys.size():
					keys.append(raw_keys[c])
				if c < raw_idem.size():
					idempotency.append(raw_idem[c])
	return {
		"count": ids.size(), "ids": ids, "statuses": statuses, "masks": masks,
		"hashes": hashes, "values": values, "keys": keys,
		"idempotency": idempotency, "raw_count": int(raw.get("count", -1)),
	}


func _probe_explain(ext: Object) -> Dictionary:
	return ext.explain_effect(PROBE_INSTANCE_ID)


## The sub-state predicates of the header, used on BOTH sides of every save: at
## the save point of the continuous timeline and again immediately after the
## payload has been restored.
func _expect_substate(ext: Object, substate: String, tag: String) -> void:
	var report: Dictionary = ext.get_effect_report()
	var explain: Dictionary = _probe_explain(ext)
	var poll: Dictionary = _probe_poll(ext)
	var probe_pending := int(poll["count"])
	var rejected_rows := int(report.get("rejected_transactions", -1))
	print(("[sv2/%s] substate=%s probe_in_flight=%d rejected_rows=%d "
		+ "generation=%s fire_sequence=%s effect_applied=%s last_acked=%s")
		% [tag, substate, probe_pending, rejected_rows,
			str(explain.get("generation", "?")),
			str(explain.get("fire_sequence", "?")),
			str(explain.get("effect_applied", "?")),
			str(explain.get("last_acked_fire_sequence", "?"))])
	if substate == SUBSTATE_PENDING:
		_expect("%s: the structural transaction is PENDING at this point" % tag,
			probe_pending == 1 and rejected_rows == 0,
			"in_flight=%d rejected=%d" % [probe_pending, rejected_rows])
		var statuses: PackedInt32Array = poll["statuses"]
		var masks: PackedInt32Array = poll["masks"]
		var values: PackedInt64Array = poll["values"]
		_expect("%s: the pending row is PLANNED, waits for mask 1 and carries the "
			% tag + "program's value",
			statuses.size() == 1 and int(statuses[0]) == TX_PLANNED
				and masks.size() == 1 and int(masks[0]) == 1
				and values.size() == 1 and int(values[0]) == PROBE_VALUE_Q16,
			"status=%s mask=%s value=%s" % [str(statuses), str(masks), str(values)])
		_expect("%s: no ACK has been latched yet" % tag,
			not bool(explain.get("effect_applied", true))
				and int(explain.get("last_acked_fire_sequence", -1)) == 0
				and int(explain.get("fire_sequence", -1)) == 1,
			str(explain))
	elif substate == SUBSTATE_ACKED:
		# ACKed rows are compacted away (`compact_terminal_transactions`), so an
		# empty poll is the expected shape once ACKed: the durable proofs are the
		# counters only `apply_acked_instance_transition` writes.
		_expect("%s: the structural transaction has RESOLVED at this point" % tag,
			probe_pending == 0 and rejected_rows == 0,
			"in_flight=%d rejected=%d" % [probe_pending, rejected_rows])
		_expect("%s: the ACK is latched on the instance" % tag,
			bool(explain.get("effect_applied", false))
				and int(explain.get("last_acked_fire_sequence", -1)) == 1
				and int(explain.get("applied_stack_count", -1)) == 1
				and int(explain.get("fire_sequence", -1)) == 1,
			"effect_applied=%s last_acked=%s applied_stacks=%s fire=%s" % [
				str(explain.get("effect_applied", "?")),
				str(explain.get("last_acked_fire_sequence", "?")),
				str(explain.get("applied_stack_count", "?")),
				str(explain.get("fire_sequence", "?"))])
	elif substate == SUBSTATE_REJECTED:
		_expect("%s: the structural transaction is REJECTED at this point" % tag,
			rejected_rows == 1, "rejected=%d" % rejected_rows)
		# The rejected row is terminal and invisible to `poll`; what the world
		# still shows is the instance's own RE-ISSUED intent, because
		# `apply_rejected_instance_transition` deliberately leaves the program
		# retryable (`effect_runtime.cpp:4394-4413`).
		_expect("%s: the rejected intent left no applied state and was re-issued"
			% tag,
			not bool(explain.get("effect_applied", true))
				and int(explain.get("last_acked_fire_sequence", -1)) == 0
				and int(explain.get("generation", -1)) == 3
				and int(explain.get("fire_sequence", -1)) == 1
				and probe_pending == 1,
			"applied=%s last_acked=%s gen=%s fire=%s in_flight=%d" % [
				str(explain.get("effect_applied", "?")),
				str(explain.get("last_acked_fire_sequence", "?")),
				str(explain.get("generation", "?")),
				str(explain.get("fire_sequence", "?")), probe_pending])
		var statuses: PackedInt32Array = poll["statuses"]
		_expect("%s: the re-issued intent is a fresh PLANNED transaction" % tag,
			statuses.size() == 1 and int(statuses[0]) == TX_PLANNED,
			str(statuses))
	else:
		_expect("%s: unknown sub-state %s" % [tag, substate], false, "")


# ─────────────────────────────────────────────────────────────────────────
# save / restore
# ─────────────────────────────────────────────────────────────────────────

func _save_point(world: Dictionary, tag: String,
		substate: String) -> Dictionary:
	var ext: Object = world["ext"]
	var pkef: PackedByteArray = ext.capture_effect_state()
	_expect("%s: PKEF payload is produced" % tag, not pkef.is_empty(),
		str(pkef.size()))
	var pkid: PackedByteArray = ext.capture_ideology_state()
	_expect("%s: PKID payload is produced" % tag, not pkid.is_empty(),
		str(pkid.size()))
	_expect("%s: the PKEF payload carries the PKEF magic" % tag,
		_ascii_magic(pkef) == "PKEF", "%s (%d bytes)" % [_ascii_magic(pkef),
			pkef.size()])
	_expect("%s: the PKID payload carries the PKID magic" % tag,
		_ascii_magic(pkid) == "PKID", "%s (%d bytes)" % [_ascii_magic(pkid),
			pkid.size()])
	_expect_substate(ext, substate, tag)
	return {"pkef": pkef, "pkid": pkid}


func _reload(label: String, payload: Dictionary, substate: String) -> Dictionary:
	var world: Dictionary = _new_world(label)
	_restore_payload(world["ext"], payload, label)
	# The sub-state itself must survive the round trip, not just "restore ok".
	_expect_substate(world["ext"], substate, label)
	return world


func _restore_payload(ext: Object, payload: Dictionary, label: String) -> void:
	# Production order (`game_save_coordinator.gd:516` then `:542`).
	var effect_result: Dictionary = ext.restore_effect_state(payload["pkef"])
	_expect("%s: PKEF restores into a freshly built runtime" % label,
		bool(effect_result.get("ok", false)), _reason(effect_result))
	var ideology_result: Dictionary = ext.restore_ideology_state(payload["pkid"])
	_expect("%s: PKID restores into a freshly built runtime" % label,
		bool(ideology_result.get("ok", false)), _reason(ideology_result))


func _reason(result: Dictionary) -> String:
	return String(result.get("reason", str(result)))


# ─────────────────────────────────────────────────────────────────────────
# state capture + comparison
# ─────────────────────────────────────────────────────────────────────────

func _capture_state(world: Dictionary, label: String) -> Dictionary:
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var cells := {}
	for stat in [STAT_ADD, STAT_CUT]:
		cells[stat] = _probe_all_cells(ext, stat)
	var layer_cells := int(layer.get("cell_count", 0))
	var expected_layer_cells := 2 * int(world["owned"])
	# THE "the layer really came back" assertion. PKEF/PKID do not carry the
	# derived front, so a non-zero, exactly right cell count can only come from a
	# rebuild.
	_expect("%s: the runtime HAS a derived cell layer" % label,
		int(layer.get("installed", 0)) != 0 and layer_cells > 0,
		"installed=%s cells=%s" % [str(layer.get("installed", "?")),
			str(layer_cells)])
	_expect("%s: the layer covers exactly the owned cells x 2 stats" % label,
		layer_cells == expected_layer_cells,
		"%d vs %d" % [layer_cells, expected_layer_cells])
	_expect("%s: the layer carries the expected contribution count" % label,
		int(layer.get("contribution_count", 0)) == expected_layer_cells,
		"%d vs %d" % [int(layer.get("contribution_count", 0)),
			expected_layer_cells])
	# Coverage sanity: a covered cell must move off the identity base and an
	# uncovered one must stay on it. Without this the per-cell comparison could
	# pass on two worlds where the layer is empty everywhere.
	var covered_cell := int((world["owned_cells"] as PackedInt32Array)[0])
	var uncovered_cell := -1
	for c in range(CELLS):
		if not (world["owned_cells"] as PackedInt32Array).has(c):
			uncovered_cell = c
			break
	var covered_probe: Dictionary = ext.get_effective_stat_value(
		STAT_ADD, covered_cell, 0, 1.0)
	var uncovered_probe: Dictionary = ext.get_effective_stat_value(
		STAT_ADD, uncovered_cell, 0, 1.0)
	_expect("%s: a covered cell carries a derived contribution" % label,
		bool(covered_probe.get("derived_present", false)), str(covered_probe))
	_expect("%s: a covered cell's merged value leaves the identity base" % label,
		absf(float(covered_probe.get("value", 1.0)) - 1.0) > 1e-9,
		str(covered_probe.get("value", "?")))
	_expect("%s: an unowned cell stays at the identity base" % label,
		not bool(uncovered_probe.get("derived_present", true))
		and absf(float(uncovered_probe.get("value", 1.0)) - 1.0) < 1e-12,
		str(uncovered_probe))
	# ABSOLUTE correctness, not just equality between two runs: the covered cells
	# must carry the CARD's own magnitude, read from the program interpreter.
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	var interp: Dictionary = ext.evaluate_effect_program_magnitude(
		PROGRAM_KEY, metrics)
	var expected_add := float(int(interp.get("magnitude", 0))) / float(Q16_ONE)
	_expect("%s: the card's persistent program evaluates" % label,
		bool(interp.get("ok", false)), str(interp))
	var covered_add := float(covered_probe.get("derived_add", 0.0))
	_expect("%s: the covered add equals the program magnitude / Q16 (%.8f)"
		% [label, expected_add],
		absf(covered_add - expected_add) <= 1e-6,
		"derived=%.8f expected=%.8f" % [covered_add, expected_add])

	var business: Dictionary = ext.get_ideology_business_state()
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var instances: Dictionary = ext.get_ideology_effect_instance_report(handle)
	var report: Dictionary = ext.get_ideology_report()
	var audit: Dictionary = ext.get_economy_committed_audit_report()
	var economy: Dictionary = ext.get_economy_report()
	var effect_report: Dictionary = ext.get_effect_report()
	var poll: Dictionary = _probe_poll(ext)
	var explain: Dictionary = _probe_explain(ext)
	var out := {
		"label": label, "cells": cells, "layer": layer,
		"business": business, "instances": int(instances.get("count", -1)),
		"layer_sample_day": int(layer.get("sample_day", -1)),
		"layer_generation": int(layer.get("layer_generation", -1)),
		"snapshot": {
			"locations": snapshot.get("locations", PackedInt32Array()),
			"levels": snapshot.get("levels", PackedInt32Array()),
			"idea_ids": snapshot.get("idea_ids", PackedInt32Array()),
			"understanding_q16": snapshot.get("understanding_q16",
				PackedInt64Array()),
			"points_q16": int(snapshot.get("ideology_points_q16", 0)),
			"lifetime_points_q16": int(snapshot.get("lifetime_points_q16", 0)),
			"pending_commands": int(report.get("pending_commands", -1)),
			"pending_transitions": int(report.get("pending_transitions", -1)),
		},
		"effect": {
			"probe_in_flight": int(poll["count"]),
			"probe_ids": poll["ids"],
			"probe_statuses": poll["statuses"],
			"probe_masks": poll["masks"],
			"probe_values": poll["values"],
			"probe_hashes": poll["hashes"],
			"probe_keys": poll["keys"],
			"probe_idempotency": poll["idempotency"],
			"world_in_flight": int(effect_report.get("pending_transactions", -1)),
			"rejected_rows": int(effect_report.get("rejected_transactions", -1)),
			"acked_rows": int(effect_report.get("acked_transactions", -1)),
			"probe_generation": int(explain.get("generation", -1)),
			"probe_fire_sequence": int(explain.get("fire_sequence", -1)),
			"probe_effect_applied": bool(explain.get("effect_applied", false)),
			"probe_last_acked": int(explain.get("last_acked_fire_sequence", -1)),
			"probe_applied_stack_count": int(explain.get("applied_stack_count", -1)),
			"probe_next_due_day": int(explain.get("next_due_day", -1)),
		},
		"audit": audit, "economy_newest_day": int(
			economy.get("newest_state_day", -1)),
		"fingerprint": "",
	}
	out["fingerprint"] = _fingerprint(cells)
	print("[sv2/%s] layer cells=%d contributions=%s day=%s generation=%s"
		% [label, layer_cells, str(layer.get("contribution_count", "?")),
			str(layer.get("sample_day", "?")),
			str(layer.get("layer_generation", "?"))])
	_expect("%s: the economy reached the last continued day" % label,
		int(economy.get("newest_state_day", -1)) == DAYS_AFTER_SAVE,
		str(economy.get("newest_state_day", "?")))
	print("[sv2/%s] transaction probe_in_flight=%s rejected_rows=%s acked_rows=%s "
		% [label, str(out["effect"]["probe_in_flight"]),
			str(out["effect"]["rejected_rows"]),
			str(out["effect"]["acked_rows"])]
		+ "probe_ids=%s" % str(out["effect"]["probe_ids"]))
	print("[sv2/%s] probe generation=%s fire=%s applied=%s last_acked=%s"
		% [label, str(out["effect"]["probe_generation"]),
			str(out["effect"]["probe_fire_sequence"]),
			str(out["effect"]["probe_effect_applied"]),
			str(out["effect"]["probe_last_acked"])])
	print("[sv2/%s] business hash=%s points=%s ideas=%s instances=%d pending=%d"
		% [label, str(business.get("hash", "?")), str(business.get("points", "?")),
			str(business.get("ideas", "?")), int(instances.get("count", -1)),
			int(report.get("pending_commands", -1))])
	print("[sv2/%s] audit available=%s pop_err=%s money_err=%s goods_err=%s"
		% [label, str(audit.get("available", false)),
			str(audit.get("population_error", "?")),
			str(audit.get("money_error", "?")),
			str(audit.get("goods_error", "?"))])
	print("[sv2/%s] per-cell fingerprint=%s" % [label, out["fingerprint"]])
	var add_cells: PackedFloat64Array = (cells[STAT_ADD] as Dictionary)["value"]
	var present: PackedByteArray = (cells[STAT_ADD] as Dictionary)["present"]
	var first := PackedStringArray()
	for c in range(mini(8, CELLS)):
		first.append("%d:%s/%.8f" % [c, str(int(present[c])), add_cells[c]])
	print("[sv2/%s] first 8 cells (present/value, %s)=%s"
		% [label, STAT_ADD, ", ".join(first)])
	return out


func _probe_all_cells(ext: Object, stat: String) -> Dictionary:
	var present := PackedByteArray()
	present.resize(CELLS)
	var add := PackedFloat64Array()
	add.resize(CELLS)
	var value := PackedFloat64Array()
	value.resize(CELLS)
	for c in range(CELLS):
		# The production read shape: entity_handle 0 and the CELL in the group slot,
		# which is the pair `economy_runtime_family_buff.cpp` passes.
		var probe: Dictionary = ext.get_effective_stat_value(stat, c, 0, 1.0)
		if not bool(probe.get("ok", false)):
			present[c] = 0
			continue
		present[c] = 1 if bool(probe.get("derived_present", false)) else 0
		add[c] = float(probe.get("derived_add", 0.0))
		value[c] = float(probe.get("value", 1.0))
	return {"present": present, "add": add, "value": value}


func _fingerprint(cells: Dictionary) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for stat in [STAT_ADD, STAT_CUT]:
		var row: Dictionary = cells[stat]
		context.update(var_to_bytes(row["present"]))
		context.update(var_to_bytes(row["add"]))
		context.update(var_to_bytes(row["value"]))
	return context.finish().hex_encode()


func _compare(reference: Dictionary, other: Dictionary, tag: String) -> void:
	# ── §11.7 column 1: per-cell effective factors ────────────────────────
	for stat in [STAT_ADD, STAT_CUT]:
		var a: Dictionary = reference["cells"][stat]
		var b: Dictionary = other["cells"][stat]
		_expect("%s: %s derived presence matches on every one of %d cells"
			% [tag, stat, CELLS],
			_presence_diff(a["present"], b["present"]).begins_with("mismatches=0"),
			_presence_diff(a["present"], b["present"]))
		_expect("%s: %s derived add matches EXACTLY on every cell"
			% [tag, stat],
			_float_diff(a["add"], b["add"]).begins_with("mismatches=0"),
			_float_diff(a["add"], b["add"]))
		_expect("%s: %s effective value matches EXACTLY on every cell"
			% [tag, stat],
			_float_diff(a["value"], b["value"]).begins_with("mismatches=0"),
			_float_diff(a["value"], b["value"]))
	_expect("%s: the per-cell fingerprint hash is identical" % tag,
		String(reference["fingerprint"]) == String(other["fingerprint"]),
		"%s vs %s" % [reference["fingerprint"], other["fingerprint"]])
	# ── §11.7 column 4: business state ────────────────────────────────────
	var ref_business: Dictionary = reference["business"]
	var other_business: Dictionary = other["business"]
	_expect("%s: ideology business state hash matches" % tag,
		int(ref_business.get("hash", 0)) == int(other_business.get("hash", 0)),
		"%s vs %s" % [str(ref_business.get("hash", "?")),
			str(other_business.get("hash", "?"))])
	for section in ["points", "baseline", "history", "draw", "bits", "offer", "ideas"]:
		_expect("%s: business section %s matches" % [tag, section],
			int(ref_business.get(section, -1)) == int(other_business.get(section, -1)),
			"%s vs %s" % [str(ref_business.get(section, "?")),
				str(other_business.get(section, "?"))])
	_expect("%s: the card is equipped (IDEOLOGY slot) on both sides" % tag,
		_active_locations(reference["snapshot"]) == _active_locations(
			other["snapshot"]) and _active_locations(reference["snapshot"]) > 0,
		"%d vs %d" % [_active_locations(reference["snapshot"]),
			_active_locations(other["snapshot"])])
	_expect("%s: the equipped card keeps the same level and understanding" % tag,
		str(reference["snapshot"]["levels"]) == str(other["snapshot"]["levels"])
		and str(reference["snapshot"]["understanding_q16"])
			== str(other["snapshot"]["understanding_q16"]),
		"%s / %s vs %s / %s" % [
			str(reference["snapshot"]["levels"]),
			str(reference["snapshot"]["understanding_q16"]),
			str(other["snapshot"]["levels"]),
			str(other["snapshot"]["understanding_q16"])])
	_expect("%s: no ideology command is left pending in either run" % tag,
		int(reference["snapshot"]["pending_commands"]) == 0
		and int(other["snapshot"]["pending_commands"]) == 0,
		"%d vs %d" % [int(reference["snapshot"]["pending_commands"]),
			int(other["snapshot"]["pending_commands"])])
	_expect("%s: both runs carry the same in-flight transition count" % tag,
		int(reference["snapshot"]["pending_transitions"])
		== int(other["snapshot"]["pending_transitions"]),
		"%d vs %d" % [int(reference["snapshot"]["pending_transitions"]),
			int(other["snapshot"]["pending_transitions"])])
	# ── the structural transaction itself ─────────────────────────────────
	var ref_effect: Dictionary = reference["effect"]
	var other_effect: Dictionary = other["effect"]
	_expect("%s: the rejected row count matches on both sides" % tag,
		int(ref_effect["rejected_rows"]) == int(other_effect["rejected_rows"])
		and int(ref_effect["rejected_rows"]) == 1,
		"%d vs %d" % [int(ref_effect["rejected_rows"]),
			int(other_effect["rejected_rows"])])
	_expect("%s: the same number of Effect transactions is still in flight" % tag,
		int(ref_effect["world_in_flight"]) == int(other_effect["world_in_flight"]),
		"%d vs %d" % [int(ref_effect["world_in_flight"]),
			int(other_effect["world_in_flight"])])
	_expect("%s: the same number of probe transactions is still in flight" % tag,
		int(ref_effect["probe_in_flight"]) == int(other_effect["probe_in_flight"]),
		"%d vs %d" % [int(ref_effect["probe_in_flight"]),
			int(other_effect["probe_in_flight"])])
	_expect("%s: the in-flight probe ids, statuses and masks match" % tag,
		str(ref_effect["probe_ids"]) == str(other_effect["probe_ids"])
		and str(ref_effect["probe_statuses"]) == str(
			other_effect["probe_statuses"])
		and str(ref_effect["probe_masks"]) == str(other_effect["probe_masks"]),
		"%s vs %s" % [str(ref_effect["probe_ids"]),
			str(other_effect["probe_ids"])])
	_expect("%s: the in-flight plan hashes and command values match" % tag,
		str(ref_effect["probe_hashes"]) == str(other_effect["probe_hashes"])
		and str(ref_effect["probe_values"]) == str(other_effect["probe_values"]),
		"%s vs %s" % [str(ref_effect["probe_hashes"]),
			str(other_effect["probe_hashes"])])
	_expect("%s: the in-flight idempotency keys match (no duplicate intent)" % tag,
		str(ref_effect["probe_idempotency"])
			== str(other_effect["probe_idempotency"]),
		"%s vs %s" % [str(ref_effect["probe_idempotency"]),
			str(other_effect["probe_idempotency"])])
	# §11.7 column 3: one-shot execution counts. `fire_sequence` is the durable
	# number of times the program fired; `last_acked_fire_sequence` the number of
	# times an ACK consumed one.
	_expect("%s: the probe fired the same number of times (one-shot count)" % tag,
		int(ref_effect["probe_fire_sequence"]) == int(
			other_effect["probe_fire_sequence"]),
		"%d vs %d" % [int(ref_effect["probe_fire_sequence"]),
			int(other_effect["probe_fire_sequence"])])
	_expect("%s: the probe latched the same ACK count and applied state" % tag,
		int(ref_effect["probe_last_acked"]) == int(other_effect["probe_last_acked"])
		and bool(ref_effect["probe_effect_applied"])
			== bool(other_effect["probe_effect_applied"])
		and int(ref_effect["probe_applied_stack_count"]) == int(
			other_effect["probe_applied_stack_count"]),
		"%s vs %s" % [str(ref_effect), str(other_effect)])
	_expect("%s: the probe instance is on the same generation and due day" % tag,
		int(ref_effect["probe_generation"]) == int(
			other_effect["probe_generation"])
		and int(ref_effect["probe_next_due_day"]) == int(
			other_effect["probe_next_due_day"]),
		"gen %d/%d due %d/%d" % [
			int(ref_effect["probe_generation"]),
			int(other_effect["probe_generation"]),
			int(ref_effect["probe_next_due_day"]),
			int(other_effect["probe_next_due_day"])])
	_expect("%s: one-shot effect instance count is 0 in both runs (I01)" % tag,
		int(reference["instances"]) == 0 and int(other["instances"]) == 0,
		"%d vs %d" % [int(reference["instances"]), int(other["instances"])])
	_expect("%s: both runs advanced the economy to the same committed day" % tag,
		int(reference["economy_newest_day"]) == int(other["economy_newest_day"]),
		"%d vs %d" % [int(reference["economy_newest_day"]),
			int(other["economy_newest_day"])])
	# ── §11.7 column 2: economy conservation ──────────────────────────────
	var ref_audit: Dictionary = reference["audit"]
	var other_audit: Dictionary = other["audit"]
	_expect("%s: the committed economy audit is available on both sides" % tag,
		bool(ref_audit.get("available", false))
			and bool(other_audit.get("available", false)),
		"%s vs %s" % [str(ref_audit.get("available", "?")),
			str(other_audit.get("available", "?"))])
	_expect("%s: economy conservation errors are 0 on both sides" % tag,
		int(ref_audit.get("population_error", -1)) == 0
		and int(ref_audit.get("money_error", -1)) == 0
		and int(ref_audit.get("goods_error", -1)) == 0
		and int(other_audit.get("population_error", -1)) == 0
		and int(other_audit.get("money_error", -1)) == 0
		and int(other_audit.get("goods_error", -1)) == 0,
		"%s vs %s" % [str(ref_audit), str(other_audit)])


func _snapshot_locations(snapshot: Dictionary) -> PackedInt32Array:
	return snapshot.get("locations", PackedInt32Array())


func _active_locations(snapshot: Dictionary) -> int:
	var locations: PackedInt32Array = _snapshot_locations(snapshot)
	var count := 0
	for value in locations:
		if int(value) != 0:
			count += 1
	return count


func _presence_diff(a: PackedByteArray, b: PackedByteArray) -> String:
	if a.size() != b.size():
		return "size %d vs %d" % [a.size(), b.size()]
	var mismatches := 0
	var first := -1
	for i in range(a.size()):
		if a[i] != b[i]:
			mismatches += 1
			if first < 0:
				first = i
	return "mismatches=%d first=%d" % [mismatches, first]


func _float_diff(a: PackedFloat64Array, b: PackedFloat64Array) -> String:
	if a.size() != b.size():
		return "size %d vs %d" % [a.size(), b.size()]
	var mismatches := 0
	var first := -1
	var worst := 0.0
	for i in range(a.size()):
		if a[i] != b[i]:
			mismatches += 1
			if first < 0:
				first = i
			worst = maxf(worst, absf(a[i] - b[i]))
	return "mismatches=%d first=%d max_abs_diff=%.12f" % [mismatches, first, worst]


# ─────────────────────────────────────────────────────────────────────────
# ideology command batches
# ─────────────────────────────────────────────────────────────────────────

## One command row. The country handle is stamped in at submit time by `_submit`,
## because the handle only exists once that branch's world is built.
func _batch(op: int, day: int, idea: int, value_q16: int,
		sequence: int) -> Dictionary:
	return {
		"opcodes": PackedInt32Array([op]),
		"effective_days": PackedInt64Array([day]),
		"source_priorities": PackedInt32Array([0]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([sequence]),
		"country_handles": PackedInt64Array([0]),
		"ideology_ids": PackedInt32Array([idea]),
		"values_q16": PackedInt64Array([value_q16]),
		"offer_generations": PackedInt64Array([0]),
		"choice_indices": PackedInt32Array([-1]),
		"gate_ids": PackedInt32Array([-1]),
	}


func _submit(ext: Object, batch: Dictionary, handle: int) -> void:
	var copy: Dictionary = batch.duplicate(true)
	copy["country_handles"] = PackedInt64Array([handle])
	var result: Dictionary = ext.submit_ideology_commands(copy)
	_expect("ideology batch (seq %d) is admitted" % int(batch["sequences"][0]),
		bool(result.get("ok", false)), str(result))


# ─────────────────────────────────────────────────────────────────────────
# reporting
# ─────────────────────────────────────────────────────────────────────────

func _ascii_magic(bytes: PackedByteArray) -> String:
	return bytes.slice(0, mini(4, bytes.size())).get_string_from_ascii()


## Every check is printed, pass or fail: §11.7 evidence is the LIST of things that
## were compared, and a log that only shows failures cannot tell a reader whether
## the per-cell comparison ran at all.
func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	print("  [FAIL] %s %s" % [label, detail])
	if not _suppress_stderr:
		printerr("FAIL %s %s" % [label, detail])


func _finish() -> void:
	print("=== ideology save at structural transaction states (§11.7 time point 2): "
		+ "%d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
