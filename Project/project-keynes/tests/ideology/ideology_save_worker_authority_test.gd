extends SceneTree

## §11.7 time point 7: "worker 已提交而主线程镜像滞后；四种权威组合及权威翻转" -- the
## one half of it that had NO evidence at all: A SAVE TAKEN WHILE THE WORKER OWNS
## IDEOLOGY, restored into a DIFFERENT world.
##
## WHY THIS TIME POINT COULD NOT BE TESTED UNTIL NOW
##
##   `run_ideology_daily` returns `suppressed` under IDEOLOGY worker authority and it
##   was the only production caller of `step_derived_rebuild`, so under worker authority
##   the derived cell layer produced NOTHING (no `installed` front, no cells, no
##   contributions). A save taken there could only ever prove "an empty projection
##   restores as empty". The pump that fixes that (`DCWorldExt::
##   step_ideology_derived_rebuild`, the `MapGenerator` wrapper, and the host tick pump)
##   landed days ago and is pinned by `ideology_worker_derived_pump_test` (55/0), which
##   is what makes THIS fixture possible: a real projection now exists on the worker leg
##   for the first time, so the round trip has something to carry.
##
## WHAT THE PLAN DEMANDS OF A TIME POINT (22-cell-program-cap-removal-plan-v3.md:809)
##
##   "每个时点比较连续运行与存档重载后的逐格有效因子" -- compare, per cell, after save
##   and reload. A fresh-world roundtrip on its own does not pass. This fixture is the
##   round trip ACROSS THE WORKER BOUNDARY: the payload is captured from a runtime whose
##   state was authored by the worker (the main-thread `NativeIdeologyRuntime` is a
##   MIRROR there: `submit_ideology_commands` forwards and applies nothing locally,
##   `world_ext_ideology.cpp:176-200`, and every idea row arrives through
##   `apply_pod_snapshot`, `ideology_runtime.cpp:949`), and it is restored into a SECOND,
##   freshly generated world that has never seen that worker's day.
##
## THE FOUR THINGS THIS HAS TO PROVE, AND WHY EACH ONE IS SEPARATE
##
##   1. A PROJECTION EXISTS UNDER WORKER AUTHORITY BEFORE THE SAVE. `installed=true`,
##      `cell_count>0`, `contribution_count>0`, plus the `layer_generation` /
##      `confirmed_day` / `eligible_day` it was built from. Without this the rest of the
##      fixture would compare two empty layers and pass vacuously.
##   2. THE CAPTURE HAPPENS WHILE THE WORKER OWNS IDEOLOGY, in the mandatory
##      PKEF -> PKID order (`game_save_coordinator` registers them that way; PKID alone
##      rejects with `ideology_effect_binding_missing_or_mismatched`). Both payloads are
##      asserted non-empty and their SIZES are recorded, because a 4-byte payload would
##      also be "non-empty".
##   3. THE RESTORED WORLD REBUILDS THE SAME PROJECTION. PKID does not carry the derived
##      front (`ideology_runtime.cpp:6387` captures country rows and nothing else), so
##      the front must be REBUILT from the restored rows. The comparison is
##      `get_effective_stat_value(...)` on EVERY cell of the grid: same covered cells,
##      and `max |derived_add| difference == 0`.
##   4. THE §9.3 DATES SURVIVE. `confirmed_day` / `eligible_day` are in the PKID tail
##      (schema 14) precisely so a load can tell which projections are not eligible yet;
##      they are restored verbatim and must satisfy `eligible == confirmed + 1`. The same
##      tail carries the §18.5 sample day and the local scalar basis, and both are walked
##      and matched against the front this world actually installed.
##
## THE NEGATIVE CONTROLS, AND WHY THEY ARE BYTE FLIPS INSIDE THE TAIL
##
##   A restore that accepts anything proves nothing about what it accepted. Three bytes of
##   the PKID tail are flipped -- the execution-contract identity (already in the tail,
##   `ideology_runtime.cpp:6954`), the applied-basis block's `terms_digest`, and its
##   `selector_kind` (`:6928-6940`) -- and each must be REFUSED with its own named reason,
##   leaving the runtime untouched; a truncated PKEF is the fourth. The tail offsets are
##   DERIVED FROM CONSTANTS and the basis block is WALKED, never addressed by a hard-coded
##   distance from the end: the block is variable length, so any fixture that hard-codes
##   "40 bytes from the end" is a fixture that breaks silently the day a card gains a term.
##   Two more controls exist because the first version of this fixture got the tail
##   arithmetic wrong by four bytes and the corruption was ACCEPTED rather than refused:
##   the walk is asserted to land on the dates, and every refusal is asserted to name its
##   reason instead of merely returning `ok=false`.
##
## HOW THE PUMP IS DRIVEN (identical to the pinned pump fixture)
##
##   A `-s` fixture has no tick loop, so the bound facade is called directly:
##   `ext.step_ideology_derived_rebuild(day)`. It answers
##   `{ok, done, pending, day, code}`; `code == "economy_day_inflight"` means the worker
##   held the economy-input-capture boundary for its own day transaction and the call
##   must be retried (normal contention, recorded per day). `ok == false` is NOT a
##   failure either: the sharded rebuild returns false from its collect step to mean
##   "the fold happens in later steps" (`ideology_runtime.cpp:7686`).
##
## WHY THE RESTORE LEG DOES NOT ADVANCE THE WORKER BEFORE THE COMPARISON
##
##   The main-thread runtime under worker authority is a MIRROR: its rows are replaced
##   wholesale by every accepted pod snapshot (`apply_pod_snapshot`,
##   `ideology_runtime.cpp:1227-1229`). A day is therefore not neutral with respect to the
##   restored rows, and the round trip plan §11.7 asks for is measured BEFORE one is run:
##   `_run_restore_leg` rebuilds at the restored ELIGIBILITY day with the world clock where
##   the fresh world left it.
##
##   The follow-up -- "does the load survive a worker day?" -- is NOT left as a measurement
##   any more: it is `_assert_load_durability` below, and it asserts.
##
## THE LOAD IS NOW DURABLE, AND THIS IS THE PART THAT USED TO FAIL
##
##   `capture_ideology_state` / `restore_ideology_state` are main-thread facade calls, and
##   the worker has its own state machine (`RuntimeIdeologyPodAuthority`), so before the
##   import channel existed the POD never learned it had been restored from. MEASURED then:
##   the first write-back applied generation 1 and REPLACED the restored rows with the
##   worker's own (empty) state -- `idea_rows [82,1,0,0] -> []`, the mirrored §9.3 dates
##   `7/8 -> 2/3` (the worker's committed day, not the payload's), and the next pump then
##   cleared the front (`installed=false`, `cells=0`).
##
##   `restore_ideology_state` now pushes the restored state INTO the worker through the
##   POD's own state-adoption entry point (`DCWorldExt::restore_ideology_state` ->
##   `import_ideology_pod_state` -> `NativeIdeologyRuntime::export_pod_import_state` ->
##   `RuntimeIdeologyPodAuthority::serialize_snapshot` -> the host's
##   `restore_ideology_pod_save`, which is the same call the runtime save bundle uses).
##   The POD ADOPTS that state: its committed day, rows, points, RNG, offer and — the
##   field that decides the mirrored §9.3 dates — its `committed_day`.
##
##   So the durability phase asserts, after at least one real worker write-back on the
##   loaded world: the payload's idea rows, the payload's §9.3 dates, the payload's front
##   (same cell count, same per-cell `derived_add`), and that a post-write-back pump still
##   produces that front. `worker_import` on the restore result names the channel, and
##   `ideology_pod_committed_day` proves the WORKER's calendar became the payload's.
##
##   A worker day at or below the imported day is a no-op day for the POD, not
##   `ideology_day_not_monotonic`: the imported state already settles it. Without that rule
##   the POD would refuse every day until its own calendar caught up and publish nothing,
##   which freezes the mirror instead of adopting the load.
##
## THE ONE THING THAT DOES NOT ROUND-TRIP, MEASURED AND REPORTED RATHER THAN ASSERTED AWAY
##
##   PKEF is captured first and offered to the restore first, but under EFFECT worker
##   authority (0xFFF owns EFFECT too) the payload's own rows violate a restore condition:
##   the rows written back from the worker carry `applied_stack_count=1` while the
##   facade-local `effect_applied` latch they are paired with is still `0`, and
##   `EffectRuntime::restore` refuses that pair with `pkef_instance_identity_invalid`
##   (`effect_runtime.cpp:7561-7562`). The SAME payload is refused by the runtime that
##   PRODUCED it (`[NEG/NC5]`), so this is not "a different world" and it is not this
##   fixture's doing. The IDEOLOGY section is unaffected: PKID's own `worker_origin` flag
##   short-circuits every Effect binding and instance query
##   (`ideology_runtime.cpp:7367-7373`), which is exactly why the projection still
##   round-trips. `[NEG/NC5][PKEF-ROWS]` names the row and the condition.
##
## WHAT IS REPORTED AND NOT ASSERTED
##
##   The exact `confirmed_day` / `eligible_day` pair (asserted equal across the boundary,
##   printed because it mirrors the worker's own `committed_day`), the payload sizes, the
##   per-day pump attempt ledger, and every refusal reason verbatim.
##
## THE NEGATIVE CONTROL (a NO-WORKER world)
##
##   The import may not change the MAIN-THREAD path. `_run_main_thread_negative_control`
##   builds a third world with no worker grant at all, restores the SAME worker-authored
##   PKID into it, and asserts the pre-change behaviour: the restore is accepted, it
##   carries NO `worker_import` key (the path is not taken at all), the rows and the §9.3
##   dates are the payload's, and a day of main-thread ideology leaves them alone. A
##   no-worker world runs `run_ideology_daily` itself, so this leg is also the proof that
##   the import did not become a second writer on the day path.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_save_worker_authority_test.gd

const WIDTH := 16
const HEIGHT := 12
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261029
const WORKER_SPEED := 10.0
const Q16_ONE := 65536

# RuntimeDomainId -> bit, read out of `runtime_pod_protocol.h`.
const DOMAIN_IDEOLOGY := 0x010
const DOMAIN_EFFECT := 0x020
# 0xFFF grants every domain to the worker. NOT 0xF7F (older ideology fixtures), which
# clears GAMEPLAY_EFFECT 0x080 and STILL leaves ideology on the main thread.
const MASK_WORKER_IDEOLOGY := 0xFFF

const CARD := "idea.public_hygiene"
const PROGRAM := "ideology.effect.public_hygiene_l1"
const STAT_ADD := "economy.city.birth_factor"
const TAG_A := "cell.settlement"
const TAG_B := "cell.terrain.tundra"
const POPULATION_Q16 := 800 * Q16_ONE

const OP_DISCOVER := 1
const OP_GRANT_POINTS := 2
const OP_EQUIP := 5
const OP_ADD_UNDERSTANDING := 8

# ---- PKID (Ideology) wire constants, from `ideology_runtime.cpp:42-43` and the v14
# ---- tail written at the end of `capture()`. Every tail offset below is the distance
# ---- from the END of the payload and is DERIVED, never guessed.
const PKID_MAGIC := 0x44494B50        # "PKID" little endian
const PKID_SCHEMA := 14
const PKID_SAVE_END := 0x21444E45     # "END!" little endian
const PKID_TAIL_END := 4              # u32 SAVE_END
const PKID_TAIL_CONTRACT := PKID_TAIL_END + 8        # u64 execution contract
const PKID_TAIL_ELIGIBLE := PKID_TAIL_CONTRACT + 8   # i64 eligible_day
const PKID_TAIL_CONFIRMED := PKID_TAIL_ELIGIBLE + 8  # i64 confirmed_day
# plan 18.5: the projection's sample day, then the scalar-basis block's own length.
const PKID_TAIL_SAMPLE_DAY := PKID_TAIL_CONFIRMED + 8  # i64 sample day
const PKID_TAIL_SCALAR_LEN := PKID_TAIL_SAMPLE_DAY + 4 # u32 scalar-block length
const PKID_HEADER_FIXED := 4 + 4 + 8 + 8 + 8 + 8     # magic/schema/catalog/day/order/hash
const PKID_PRODUCER_ROW := 4 + 8                     # i32 id + i64 sequence
const PKID_BASIS_ROW_FIXED := 8 + 4 + 4 + 4 + 4 + 8  # handle/kind/p0/p1/digest + lengths
# plan 18.5 scalar row: u64 country_handle + i32 metric_id + i64 value_q16, no strings.
const PKID_SCALAR_ROW := 8 + 4 + 8
# ---- PKEF (Effect) header, schema 14 (see `ideology_save_payload_robustness_test`).
const PKEF_MAGIC := 0x46454B50        # "PKEF" little endian
const PKEF_OFF_NEXT_ACTIVATION := 64  # u64
const PKEF_OFF_INSTANCE_COUNT := 72   # u32
# One instance row, up to (and including) its own u32 metric count. The metric slab that
# follows is `metric_count` int64 values and then `metric_count` presence bytes.
const PKEF_INSTANCE_FIXED := 8 + 4 + 4 + 4 + 8 + 8 + 8 + 4 + 4 + 4 + 8 + 8 + 8 + 8 \
	+ 1 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 8 + 8 + 8 + 1 + 1 + 8 + 8 + 1 + 4

const MAX_SLICES_PER_DAY := 256
const ATTEMPTS_PER_DAY := 8
const ATTEMPT_SLEEP_MS := 2
const PUMP_DAYS := 22
# The restore leg pumps ONE day (the restored eligibility day) but the boundary lock
# there is uncontended, so a few more attempts than the ledger's budget is headroom,
# not a different contract.
const RESTORE_PUMP_ATTEMPTS := 24
const DAY_WAIT_MS := 9000
const POD_WAIT_MS := 4000
# The durability probe drives real days on the loaded world until the worker's ideology
# pod has committed at least one of them. It is bounded because it is a measurement, and
# its per-day pod wait is shortened so the probe cannot dominate the run.
const AFTER_DAY_LIMIT := 6
const AFTER_DAY_POD_WAIT_MS := 250
const GLOBAL_BUDGET_MS := 720000
const PEER_PASSES := 6
const PEER_BATCH := 96
const INFLIGHT_CODE := "economy_day_inflight"

const RETRY_ATTEMPTS := 1
const RETRY_INFLIGHT := 2

const WorkerWaitHelper = preload("res://tests/ideology/ideology_worker_wait_helper.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0
var _next_sequence := 1
var _run_started_ms := 0
var _budget_exhausted := false
var _worlds: Array = []
# The country the restore leg is about. Kept on the fixture so the refusal controls can
# fingerprint the same country row they must leave untouched.
var _restore_handle := 0
# Per-day wait for the worker's pod day. A member, not a constant, because the durability
# probe at the end drives days only to OBSERVE the pod and must not pay the full 4 s on a
# day the pod does not commit.
var _pod_wait_ms := POD_WAIT_MS


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology save worker authority: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	_gate_facts()
	var captured := await _run_capture_leg()
	var restored := await _run_restore_leg(captured)
	_compare_projections(captured, restored)
	_run_negative_controls(captured, restored)
	_assert_load_durability(captured, restored)
	await _run_main_thread_negative_control(captured)
	_teardown_all()
	return 0


# =========================================================================
# Phase 0: the mask and the tail layout, computed rather than assumed
# =========================================================================
func _gate_facts() -> void:
	_expect("GATE: 0xFFF grants BOTH the ideology bit and the effect bit to the worker",
		(MASK_WORKER_IDEOLOGY & DOMAIN_IDEOLOGY) != 0
			and (MASK_WORKER_IDEOLOGY & DOMAIN_EFFECT) != 0,
		"0x%03X" % MASK_WORKER_IDEOLOGY)
	# The tail is a fixed shape from the end: SAVE_END, contract, eligible, confirmed,
	# sample day, scalar-block length. Asserting the arithmetic here is what lets every
	# offset below be a constant expression instead of a magic number copied out of a
	# C++ file.
	#
	# MEASURED, not guessed: the first version of this fixture asserted 36 here (one
	# field too far) and the walk read `basis_len = 123254003` out of the middle of the
	# basis block. The dates and the contract were already right at 28/20/12, which is
	# how the off-by-four was localised to this one constant.
	#
	# v14 moved the first variable-length length field from 32 to 40: the §18.5 sample
	# day (8) and the scalar block's own length (4) now sit in front of the applied
	# block, and the dates keep 28/20/12 because both additions are IN FRONT of them.
	_expect("GATE: the schema 14 tail is addressable from the END with constants "
		+ "(scalar_len @-%d, sample_day @-%d, confirmed @-%d, eligible @-%d, "
		% [PKID_TAIL_SCALAR_LEN, PKID_TAIL_SAMPLE_DAY, PKID_TAIL_CONFIRMED,
			PKID_TAIL_ELIGIBLE]
		+ "contract @-%d, SAVE_END @-%d)" % [PKID_TAIL_CONTRACT, PKID_TAIL_END],
		PKID_TAIL_SCALAR_LEN == 40 and PKID_TAIL_SAMPLE_DAY == 36
			and PKID_TAIL_CONFIRMED == 28
			and PKID_TAIL_ELIGIBLE == 20 and PKID_TAIL_CONTRACT == 12
			and PKID_TAIL_END == 4 and PKID_SCHEMA == 14
			and PKID_BASIS_ROW_FIXED == 32
			and PKID_SCALAR_ROW == 20
			and PKEF_INSTANCE_FIXED == 176,
		"end=%d contract=%d eligible=%d confirmed=%d sample_day=%d scalar_len=%d "
			% [PKID_TAIL_END, PKID_TAIL_CONTRACT, PKID_TAIL_ELIGIBLE,
				PKID_TAIL_CONFIRMED, PKID_TAIL_SAMPLE_DAY, PKID_TAIL_SCALAR_LEN]
			+ "scalar_row=%d pdef_instance=%d"
			% [PKID_SCALAR_ROW, PKEF_INSTANCE_FIXED])


# =========================================================================
# Phase 1: the capture leg -- a real projection under worker authority
# =========================================================================
func _run_capture_leg() -> Dictionary:
	print("[W] building world: ACTIVE worker, mask 0x%03X (the worker owns ideology "
		% MASK_WORKER_IDEOLOGY + "and effect; the main-thread ideology day is suppressed)")
	var w := await _build_world(_world_spec("W-capture"), true)
	_expect("W: the ACTIVE worker world builds", not w.is_empty(),
		"building failed (see the BUILD lines above)")
	if w.is_empty():
		return {}
	_worlds.append(w)
	w["pump"] = true
	_install_selector_fixture(w, "W")
	var opening := _layer_state(w["ext"])
	w["visits_at_start"] = int(opening["cell_layer_rebuild_visits"])
	w["generation_at_start"] = int(opening["layer_generation"])
	print("[W] starting counters: rebuild_visits=%d layer_generation=%d installed=%s "
		% [int(w["visits_at_start"]), int(w["generation_at_start"]),
			str(opening["installed"])]
		+ "cells=%d contributions=%d"
		% [int(opening["cell_count"]), int(opening["contribution_count"])])
	_drive_days(w, 3)
	var thread_report: Dictionary = w["ext"].get_runtime_thread_report()
	var mask := int(thread_report.get("authoritative_domain_mask", -1))
	print("[W] worker report after 3 days: state=%s mode=%s mask=0x%03X ready=%s "
		% [String(thread_report.get("simulation_host_state", "?")),
			String(thread_report.get("simulation_thread_mode", "?")), mask,
			str(thread_report.get("simulation_worker_ready", "?"))]
		+ "fault='%s' pod_day=%s"
		% [String(thread_report.get("fault_code", "")),
			str(thread_report.get("ideology_pod_committed_day", "?"))])
	_expect("W: the worker really owns the ideology domain (the mask is DEFERRED and "
		+ "reads 0x000 until the pod is ready, so it is read after days, not at build)",
		mask == MASK_WORKER_IDEOLOGY and (mask & DOMAIN_IDEOLOGY) != 0,
		"mask=0x%03X blocker='%s'" % [mask, String(thread_report.get(
			"simulation_worker_blocker", ""))])
	_expect("W: the main-thread ideology day IS suppressed (path=IDEOLOGY_WORKER), "
		+ "which is exactly why the derived rebuild needs the pump",
		bool(w["last_suppressed"])
			and String((w["last_ideology"] as Dictionary).get("path", "")) \
				== "IDEOLOGY_WORKER",
		str(w["last_ideology"]))
	await _equip_card(w, CARD, "W", 10)
	var first_day := int(w["tick"])
	for _index in range(PUMP_DAYS):
		if bool(w.get("faulted", false)) or _budget_exhausted:
			break
		_drive_day(w)
		if int(w["first_installed_day"]) >= 0:
			break
	var day_at_capture := int(w["tick"])
	var final := _layer_state(w["ext"])
	print("[W] after %d pumped days (day %d -> %d): installed=%s cells=%d "
		% [int(w.get("pumped_days", 0)), first_day, day_at_capture,
			str(final["installed"]), int(final["cell_count"])]
		+ "contributions=%d stats=%d generation=%d sample_day=%d rebuild_visits=%d "
		% [int(final["contribution_count"]), int(final["stat_count"]),
			int(final["layer_generation"]), int(final["sample_day"]),
			int(final["cell_layer_rebuild_visits"])]
		+ "confirmed=%d eligible=%d gated=%d fault='%s'"
		% [int(final["basis_confirmed_day"]), int(final["basis_eligible_day"]),
			int(final["gated_by_eligibility"]), _worker_fault(w["ext"])])
	_print_pump_table(w)
	# ---- 1. A PROJECTION EXISTS ----------------------------------------
	_expect("W[1/4]: a derived projection exists UNDER WORKER AUTHORITY before the "
		+ "save (installed=true, cell_count>0, contribution_count>0)",
		bool(final["installed"]) and int(final["cell_count"]) > 0
			and int(final["contribution_count"]) > 0,
		"installed=%s cells=%d contributions=%d visits=%d day=%d fault='%s'"
			% [str(final["installed"]), int(final["cell_count"]),
				int(final["contribution_count"]),
				int(final["cell_layer_rebuild_visits"]), day_at_capture,
				_worker_fault(w["ext"])])
	_expect("W[1/4]: the rebuild really ran -- cell_layer_rebuild_visits grew and "
		+ "layer_generation bumped off their starting values",
		int(final["cell_layer_rebuild_visits"]) > int(w["visits_at_start"])
			and int(final["layer_generation"]) > int(w["generation_at_start"]),
		"visits %d -> %d, generation %d -> %d"
			% [int(w["visits_at_start"]), int(final["cell_layer_rebuild_visits"]),
				int(w["generation_at_start"]), int(final["layer_generation"])])
	_expect("W[9.3]: the basis pair is real (both dates >= 0) and eligible == "
		+ "confirmed + 1, and the front did not install before its eligibility day",
		int(final["basis_confirmed_day"]) >= 0
			and int(final["basis_eligible_day"])
				== int(final["basis_confirmed_day"]) + 1
			and int(w["first_installed_day"]) >= 0
			and int(w["first_installed_day"]) >= int(w.get(
				"eligible_at_first_install", -1)),
		"confirmed=%d eligible=%d first_installed_day=%d eligible_at_install=%d"
			% [int(final["basis_confirmed_day"]),
				int(final["basis_eligible_day"]), int(w["first_installed_day"]),
				int(w.get("eligible_at_first_install", -1))])
	var days: Array = w.get("days", [])
	var pumped := 0
	var attempts_total := 0
	var inflight_total := 0
	var bad_rows := 0
	for row_value in days:
		var row: Dictionary = row_value
		if not bool(row.get("pumped", false)):
			continue
		pumped += 1
		attempts_total += int(row["attempts"])
		inflight_total += int(row["inflight"])
		if int(row["attempts"]) < 1 or int(row["attempts"]) > ATTEMPTS_PER_DAY \
				or int(row["inflight"]) < 0 \
				or int(row["inflight"]) > int(row["attempts"]):
			bad_rows += 1
	print("[W][RETRY] pumped_days=%d calls=%d inflight=%d incomplete_rows=%d"
		% [pumped, attempts_total, inflight_total, bad_rows])
	_expect("W[RETRY]: every pumped day recorded a complete attempt ledger, so 'the "
		+ "layer appeared' is not an accident of one lucky call",
		pumped > 0 and bad_rows == 0,
		"pumped=%d bad_rows=%d calls=%d inflight=%d"
			% [pumped, bad_rows, attempts_total, inflight_total])
	var probe := _probe_all_cells(w["ext"], STAT_ADD, int(w["cells"]))
	var magnitude := _program_magnitude(w, PROGRAM, "W")
	var expected := float(magnitude) / float(Q16_ONE)
	var first_cell := -1
	var present: PackedByteArray = probe["present"]
	for cell in range(present.size()):
		if present[cell] != 0:
			first_cell = cell
			break
	var observed := 0.0
	if first_cell >= 0:
		observed = float((probe["add"] as PackedFloat64Array)[first_cell])
	print("[W][MAGNITUDE] %s magnitude=%d expected add=%.10f observed=%.10f covered=%d "
		% [PROGRAM, magnitude, expected, observed, int(probe["covered"])]
		+ "at cell %d" % first_cell)
	_expect("W[MAGNITUDE]: the installed add equals the catalog magnitude of the "
		+ "card's own program -- the layer carries the AUTHORED contribution, so the "
		+ "comparison below is not the agreement of two zeros",
		first_cell >= 0 and absf(observed - expected) <= 1e-9
			and int(probe["covered"]) > 0,
		"first_cell=%d observed=%.10f expected=%.10f covered=%d"
			% [first_cell, observed, expected, int(probe["covered"])])
	# ---- 2. THE CAPTURE, while the worker owns ideology ------------------
	var rows_before := _idea_rows(w["ext"], int(w["handle"]))
	var pkef: PackedByteArray = w["ext"].capture_effect_state()
	var pkid: PackedByteArray = w["ext"].capture_ideology_state()
	print("[W][PAYLOAD] PKEF=%d bytes PKID=%d bytes (captured PKEF first, PKID second)"
		% [pkef.size(), pkid.size()])
	_expect("W[2/4]: the PKEF (Effect) payload is produced and is a whole section, "
		+ "not a stub",
		pkef.size() > 92 and _magic_of(pkef) == PKEF_MAGIC,
		"%d bytes magic=0x%08X" % [pkef.size(),
			pkef.decode_u32(0) if pkef.size() >= 4 else 0])
	_expect("W[2/4]: the PKID (Ideology) payload is produced and carries the PKID "
		+ "magic and schema 14",
		pkid.size() > PKID_TAIL_SCALAR_LEN + PKID_HEADER_FIXED
			and _magic_of(pkid) == PKID_MAGIC
			and pkid.decode_s32(4) == PKID_SCHEMA,
		"%d bytes magic=0x%08X schema=%s" % [pkid.size(), _magic_of(pkid),
			str(pkid.decode_s32(4) if pkid.size() >= 8 else -1)])
	var worker_origin := _pkid_worker_origin(pkid)
	print("[W][PAYLOAD] PKID worker_origin byte=%d (1 = this payload describes state the "
		% worker_origin + "WORKER authored; 0 = a main-thread-authority payload)")
	_expect("W[2/4]: the PKID payload is marked as WORKER-authored, so 'captured under "
		+ "worker authority' is a property of the bytes and not of the prose",
		worker_origin == 1, "worker_origin=%d" % worker_origin)
	var tail := _walk_pkid_tail(pkid)
	print("[W][TAIL] bytes=%d basis_len=%d basis_rows=%d basis_walk_end=%d "
		% [pkid.size(), int(tail["basis_len"]), int(tail["rows"]),
			int(tail["walk_end"])]
		+ "scalar_len=%d scalar_rows=%d scalar_end=%d sample_day=%d "
		% [int(tail["scalar_len"]), int(tail["scalar_rows"]),
			int(tail["scalar_walk_end"]), int(tail["sample_day"])]
		+ "confirmed=%d eligible=%d contract=0x%016X save_end=0x%08X tail_ok=%s"
		% [int(tail["confirmed"]), int(tail["eligible"]), int(tail["contract"]),
			int(tail["save_end"]), str(tail["ok"])])
	_expect("W[TAIL]: the v14 tail is WALKED, not assumed -- BOTH variable-length "
		+ "blocks' declared lengths land exactly on the field that declares them "
		+ "(the §18.5 scalar block then the §18.2 applied basis), and SAVE_END closes "
		+ "the payload",
		bool(tail["ok"]) and bool(tail["scalar_ok"])
			and int(tail["save_end"]) == PKID_SAVE_END
			and int(tail["confirmed"]) == int(final["basis_confirmed_day"])
			and int(tail["eligible"]) == int(final["basis_eligible_day"])
			and int(tail["rows"]) >= 1,
		"%s" % str(tail))
	# Plan 18.5: the payload's sample day is the day the projection it describes was
	# built for -- and this fixture PUMPED that projection through the production
	# rebuild (`step_ideology_derived_rebuild`), so the front's own `sample_day` is the
	# reference. A payload that disagreed with the projection it came from would be an
	# identity about nothing.
	_expect("W[TAIL]: the §18.5 sample day in the payload (%d) is the one the front "
		% int(tail["sample_day"]) + "that was captured was built for (%s)"
		% str(final.get("sample_day", "?")),
		int(tail["sample_day"]) == int(final.get("sample_day", -999)),
		"payload=%d front=%s" % [int(tail["sample_day"]),
			str(final.get("sample_day", "?"))])
	_expect("W[TAIL]: the §18.5 scalar block carries real rows (%d) for this world"
		% int(tail["scalar_rows"]), int(tail["scalar_rows"]) >= 1,
		str(tail["scalar_rows"]))
	return {
		"world": w, "day": day_at_capture, "state": final, "probe": probe,
		"magnitude": magnitude, "expected": expected, "pkef": pkef, "pkid": pkid,
		"rows": rows_before, "handle": int(w["handle"]), "tail": tail,
	}


# =========================================================================
# Phase 2: the restore leg -- a DIFFERENT, freshly generated world
# =========================================================================
func _run_restore_leg(captured: Dictionary) -> Dictionary:
	if captured.is_empty():
		_fail("R: there is nothing to restore (the capture leg produced no payload)")
		return {}
	print("[R] building a SECOND world from the same bootstrap (mask 0x%03X). It has "
		% MASK_WORKER_IDEOLOGY + "never run this worker's day and has never seen an "
		+ "ideology command")
	var w := await _build_world(_world_spec("R-restore"), true)
	_expect("R: the fresh restore world builds", not w.is_empty(),
		"building failed (see the BUILD lines above)")
	if w.is_empty():
		return {}
	_worlds.append(w)
	w["pump"] = false
	var ext: Object = w["ext"]
	_restore_handle = int(w["handle"])
	var captured_world: Dictionary = captured["world"]
	var opening := _layer_state(ext)
	var opening_rows := _idea_rows(ext, int(w["handle"]))
	print("[R] before the restore: day=%d installed=%s cells=%d contributions=%d "
		% [int(w["tick"]), str(opening["installed"]), int(opening["cell_count"]),
			int(opening["contribution_count"])]
		+ "confirmed=%d eligible=%d idea_rows=%d"
		% [int(opening["basis_confirmed_day"]), int(opening["basis_eligible_day"]),
			opening_rows.size()])
	# ---- 3a. it really is a different, EMPTY world -----------------------
	_expect("R[1/4]: the restore world is a DIFFERENT runtime, and it carries NO "
		+ "projection and NO idea rows before the load -- so anything measured after "
		+ "this point came out of the payload",
		ext.get_instance_id() != (captured_world["ext"] as Object).get_instance_id()
			and opening_rows.is_empty()
			and not bool(opening["installed"]),
		"instance %d vs %d, idea_rows=%d installed=%s"
			% [ext.get_instance_id(),
				(captured_world["ext"] as Object).get_instance_id(),
				opening_rows.size(), str(opening["installed"])])
	# ---- 3b. the production order: PKEF first, then PKID ----------------
	var pkef_result: Dictionary = ext.restore_effect_state(captured["pkef"])
	print("[R][RESTORE] PKEF ok=%s reason='%s'"
		% [str(pkef_result.get("ok", false)),
			String(pkef_result.get("reason", ""))])
	# The ORDER is the mandatory part (PKEF first, PKID second: `game_save_coordinator`
	# registers them that way and PKID's binding check assumes the Effect section has
	# already landed). Whether the Effect section itself ACCEPTS is a separate fact about
	# this build, so the check is "the call ran and answered honestly" -- a silent
	# no-op or a crash is what must not happen -- and the OUTCOME is reported and then
	# cross-checked against the same-world control in the negative-control phase.
	# Nothing downstream depends on it: PKID's own `worker_origin` flag short-circuits
	# every Effect binding and instance query (`ideology_runtime.cpp:7367-7373`).
	_expect("R[2/4]: the PKEF section is offered to the restore FIRST (the production "
		+ "order), so PKID is never the first section seen, and the answer is honest "
		+ "-- ok, or a named refusal reason, never a silent no-op",
		pkef_result.has("ok")
			and (bool(pkef_result.get("ok", false))
				or not String(pkef_result.get("reason", "")).is_empty()),
		"ok=%s reason='%s'" % [str(pkef_result.get("ok", false)),
			String(pkef_result.get("reason", ""))])
	var pkid_result: Dictionary = ext.restore_ideology_state(captured["pkid"])
	print("[R][RESTORE] PKID ok=%s reason='%s' state_hash=%s worker_origin=%s"
		% [str(pkid_result.get("ok", false)),
			String(pkid_result.get("reason", "")),
			str(pkid_result.get("state_hash", "?")),
			str(pkid_result.get("worker_origin", "?"))])
	# The worker import of the restored state (`import_ideology_pod_state`): without it the
	# worker publishes over the restore and the load does not last. `economy_day_inflight`
	# means the worker held its day; the write-back path then retries (see the durability
	# phase, which is what actually asserts the outcome).
	print("[R][RESTORE] worker import: channel='%s' imported=%s detail='%s'"
		% [String(pkid_result.get("worker_import", "<absent>")),
			str(pkid_result.get("worker_imported", false)),
			String(pkid_result.get("worker_import_detail", ""))])
	# §18.5: a scalar-basis refusal says WHICH row disagreed; print it, so a red line here
	# is a finding with data in it instead of a reason code to bisect by hand.
	if String(pkid_result.get("reason", "")) == "ideology_save_scalar_basis_mismatch":
		print("[R][RESTORE] scalar-basis mismatch detail: %s"
			% String(ext.get_ideology_report().get(
				"local_scalar_basis_mismatch_detail", "<none>")))
	_expect("R[2/4]: the PKID payload captured under worker authority restores into "
		+ "the different world",
		bool(pkid_result.get("ok", false)),
		"ok=%s reason='%s'" % [str(pkid_result.get("ok", false)),
			String(pkid_result.get("reason", ""))])
	if not bool(pkid_result.get("ok", false)):
		return {"world": w, "state": opening, "probe": {}, "refused": true,
			"reason": String(pkid_result.get("reason", "")),
			"pkef_ok": bool(pkef_result.get("ok", false)),
			"pkef_reason": String(pkef_result.get("reason", "")),
			"import_result": pkid_result}
	# ---- 4. the rows and the §9.3 dates came back -----------------------
	var loaded := _layer_state(ext)
	var loaded_rows := _idea_rows(ext, int(w["handle"]))
	var captured_rows: PackedInt32Array = captured["rows"]
	print("[R][ROWS] captured=%s / restored=%s"
		% [str(captured_rows), str(loaded_rows)])
	_expect("R[3/4]: the restored idea rows are the captured rows, field for field "
		+ "(idea id, location, level, pending flag)",
		captured_rows == loaded_rows,
		"captured=%s restored=%s" % [str(captured_rows), str(loaded_rows)])
	_expect("R[3/4]: the card is LIVE in the restored world (location=1, no pending "
		+ "transition), so the projection below has a real basis",
		_location_of(w, CARD) == 1, "location=%d" % _location_of(w, CARD))
	print("[R][9.3] confirmed=%d eligible=%d (capture: %d / %d)"
		% [int(loaded["basis_confirmed_day"]), int(loaded["basis_eligible_day"]),
			int((captured["state"] as Dictionary)["basis_confirmed_day"]),
			int((captured["state"] as Dictionary)["basis_eligible_day"])])
	_expect("R[4/4]: the §9.3 dates survive the boundary unchanged",
		int(loaded["basis_confirmed_day"])
			== int((captured["state"] as Dictionary)["basis_confirmed_day"])
			and int(loaded["basis_eligible_day"])
			== int((captured["state"] as Dictionary)["basis_eligible_day"]),
		"restored=%d/%d captured=%d/%d"
			% [int(loaded["basis_confirmed_day"]),
				int(loaded["basis_eligible_day"]),
				int((captured["state"] as Dictionary)["basis_confirmed_day"]),
				int((captured["state"] as Dictionary)["basis_eligible_day"])])
	_expect("R[4/4]: after the restore they still satisfy eligible == confirmed + 1 "
		+ "(the pair is not merely copied, it still obeys §9.3)",
		int(loaded["basis_confirmed_day"]) >= 0
			and int(loaded["basis_eligible_day"])
				== int(loaded["basis_confirmed_day"]) + 1,
		"confirmed=%d eligible=%d" % [int(loaded["basis_confirmed_day"]),
			int(loaded["basis_eligible_day"])])
	# PKID does not carry the front, so the world must have NOTHING yet. If this ever
	# fails, the comparison below is comparing a carried front with a rebuilt one.
	_expect("R[3/4]: the restored world still has NO derived front -- PKID does not "
		+ "persist it, so the projection below can only come from a REBUILD",
		not bool(loaded["installed"]) and int(loaded["cell_count"]) <= 0,
		"installed=%s cells=%d" % [str(loaded["installed"]),
			int(loaded["cell_count"])])
	# The tag/metric fixture is WORLD INPUT (the board the selector reads), not ideology
	# state, so it is re-installed into the restore world exactly as the map would be
	# when a save is loaded. It changes WHICH cells a selector matches, never the
	# magnitudes the payload carries.
	_install_selector_fixture(w, "R")
	# ---- rebuild at the restored eligibility day ------------------------
	var rebuild_day := int(loaded["basis_eligible_day"])
	if rebuild_day < 0:
		rebuild_day = int(w["tick"]) + 1
	var pump := _pump_derived(w, rebuild_day, RESTORE_PUMP_ATTEMPTS)
	print("[R][PUMP] day=%d calls=%d inflight=%d done=%s pending=%s code='%s'"
		% [rebuild_day, int(pump.get("attempts", 0)),
			int(pump.get("inflight", 0)), str(pump.get("done", false)),
			str(pump.get("pending", false)), String(pump.get("code", ""))])
	var drained: Dictionary = ext.drain_derived_cell_layer(rebuild_day)
	var after := _layer_state(ext)
	print("[R] after the rebuild at day %d: installed=%s cells=%d contributions=%d "
		% [rebuild_day, str(after["installed"]), int(after["cell_count"]),
			int(after["contribution_count"])]
		+ "stats=%d generation=%d sample_day=%d visits=%d gated=%d drain_steps=%d"
		% [int(after["stat_count"]), int(after["layer_generation"]),
			int(after["sample_day"]), int(after["cell_layer_rebuild_visits"]),
			int(after["gated_by_eligibility"]), int(drained.get("steps", -1))])
	_expect("R[3/4]: the restored world REBUILDS a projection (installed=true, "
		+ "cell_count>0, contribution_count>0)",
		bool(after["installed"]) and int(after["cell_count"]) > 0
			and int(after["contribution_count"]) > 0,
		"installed=%s cells=%d contributions=%d day=%d"
			% [str(after["installed"]), int(after["cell_count"]),
				int(after["contribution_count"]), rebuild_day])
	var probe := _probe_all_cells(ext, STAT_ADD, int(w["cells"]))
	print("[R] probe: covered=%d add_sum=%.10f" % [int(probe["covered"]),
		float(probe["add_sum"])])
	return {"world": w, "state": after, "probe": probe, "refused": false,
		"reason": "", "day": rebuild_day, "pump": pump,
		"pkef_ok": bool(pkef_result.get("ok", false)),
		"pkef_reason": String(pkef_result.get("reason", "")),
		"import_result": pkid_result}


# =========================================================================
# Phase 3: the per-cell comparison across the boundary
# =========================================================================
func _compare_projections(captured: Dictionary, restored: Dictionary) -> void:
	_negative_control()
	if captured.is_empty() or restored.is_empty() or bool(restored.get("refused", true)):
		_fail("PARITY: both sides produced a projection (a leg could not be measured "
			+ "or the restore was refused with '%s')"
			% String(restored.get("reason", "")))
		return
	var diff := _compare_probes(captured["probe"], restored["probe"])
	var captured_state: Dictionary = captured["state"]
	var restored_state: Dictionary = restored["state"]
	var captured_covered := int((captured["probe"] as Dictionary)["covered"])
	var restored_covered := int((restored["probe"] as Dictionary)["covered"])
	var captured_sum := float((captured["probe"] as Dictionary)["add_sum"])
	var restored_sum := float((restored["probe"] as Dictionary)["add_sum"])
	print("[PARITY] cells compared=%d covered(captured)=%d covered(restored)=%d "
		% [int(diff["cells"]), captured_covered, restored_covered]
		+ "presence_mismatch=%d add_mismatch=%d max_abs_add_diff=%.17f "
		% [int(diff["presence_mismatch"]), int(diff["add_mismatch"]),
			float(diff["max_abs_add_diff"])]
		+ "max_abs_value_diff=%.10f add_sum=%.10f/%.10f"
		% [float(diff["max_abs_value_diff"]), captured_sum, restored_sum])
	print("[PARITY] front: cell_count=%d/%d contributions=%d/%d generation=%d/%d "
		% [int(captured_state["cell_count"]), int(restored_state["cell_count"]),
			int(captured_state["contribution_count"]),
			int(restored_state["contribution_count"]),
			int(captured_state["layer_generation"]),
			int(restored_state["layer_generation"])]
		+ "confirmed=%d/%d eligible=%d/%d day=%d/%d"
		% [int(captured_state["basis_confirmed_day"]),
			int(restored_state["basis_confirmed_day"]),
			int(captured_state["basis_eligible_day"]),
			int(restored_state["basis_eligible_day"]),
			int(captured["day"]), int(restored["day"])])
	_expect("PARITY[HEADLINE]: the projection captured under worker authority comes "
		+ "back in a DIFFERENT world with the same covered cells and a per-cell "
		+ "|derived_add| difference of exactly 0",
		int(diff["cells"]) == CELLS and int(diff["presence_mismatch"]) == 0
			and float(diff["max_abs_add_diff"]) == 0.0
			and captured_covered > 0 and captured_covered == restored_covered,
		"cells=%d presence_mismatch=%d max_abs_add_diff=%.17f covered=%d/%d"
			% [int(diff["cells"]), int(diff["presence_mismatch"]),
				float(diff["max_abs_add_diff"]), captured_covered,
				restored_covered])
	_expect("PARITY: the two sides report the same front SHAPE, so the agreement is "
		+ "over the same structure and not over two empty layers",
		int(captured_state["cell_count"]) == int(restored_state["cell_count"])
			and int(captured_state["contribution_count"])
				== int(restored_state["contribution_count"]),
		"cell_count=%d/%d contributions=%d/%d"
			% [int(captured_state["cell_count"]), int(restored_state["cell_count"]),
				int(captured_state["contribution_count"]),
				int(restored_state["contribution_count"])])
	var expected := float(captured["expected"])
	var restored_first := -1
	var present: PackedByteArray = (restored["probe"] as Dictionary)["present"]
	for cell in range(present.size()):
		if present[cell] != 0:
			restored_first = cell
			break
	var restored_add := 0.0
	if restored_first >= 0:
		var restored_adds: PackedFloat64Array = \
			(restored["probe"] as Dictionary)["add"]
		restored_add = float(restored_adds[restored_first])
	_expect("PARITY: the restored cell carries the AUTHORED magnitude, not just a "
		+ "value that happens to equal the other leg's",
		restored_first >= 0 and absf(restored_add - expected) <= 1e-9,
		"restored_first=%d restored_add=%.10f expected=%.10f"
			% [restored_first, restored_add, expected])


## The comparator must be able to say "different", in memory, before it is trusted with
## two worlds. Flips one presence byte and moves one add by 1e-9.
func _negative_control() -> void:
	var probe := {
		"present": PackedByteArray([1, 1, 0]),
		"add": PackedFloat64Array([0.05, 0.0, 0.0]),
		"value": PackedFloat64Array([1.05, 1.0, 1.0]),
	}
	var same_diff := _compare_probes(probe, probe)
	_expect("NEG: identical probes compare equal with 0 mismatches",
		int(same_diff["presence_mismatch"]) == 0
			and float(same_diff["max_abs_add_diff"]) == 0.0, str(same_diff))
	var moved := {
		"present": PackedByteArray([1, 0, 0]),
		"add": PackedFloat64Array([0.05 + 1e-9, 0.0, 0.0]),
		"value": PackedFloat64Array([1.05, 1.0, 1.0]),
	}
	var moved_diff := _compare_probes(moved, probe)
	_expect("NEG: one flipped presence byte and one 1e-9 add are BOTH reported",
		int(moved_diff["presence_mismatch"]) == 1
			and float(moved_diff["max_abs_add_diff"]) > 0.0, str(moved_diff))


# =========================================================================
# Phase 4: the negative controls -- a corrupt payload must be REFUSED BY NAME
# =========================================================================
func _run_negative_controls(captured: Dictionary, restored: Dictionary) -> void:
	if captured.is_empty() or restored.is_empty():
		_fail("NEG: the payloads exist, so the refusal controls can run")
		return
	var target: Object = restored["world"]["ext"]
	var pkid: PackedByteArray = captured["pkid"]
	var tail: Dictionary = captured["tail"]
	var size := pkid.size()
	# ---- NC1: the execution-contract identity, from the DERIVED offset ----
	var contract_offset := size - PKID_TAIL_CONTRACT
	var contract_payload := pkid.duplicate()
	var contract := contract_payload.decode_u64(contract_offset)
	contract_payload.encode_u64(contract_offset, contract ^ 1)
	print("[NEG/NC1] PKID execution contract at offset %d (size %d - %d): "
		% [contract_offset, size, PKID_TAIL_CONTRACT]
		+ "0x%016X -> 0x%016X" % [contract, contract ^ 1])
	_refuse(target, "NC1 contract", contract_payload,
		"cell_program_execution_contract_mismatch",
		"a payload produced under DIFFERENT execution rules must be refused, not "
		+ "reinterpreted (plan 11.5)")
	# ---- NC2/NC3: inside the applied-basis block, addressed by WALKING it -----
	# v14 added the §18.5 scalar block IN FRONT of the applied basis, so the block's
	# start is no longer a constant distance from the END: it comes from the walk, which
	# reads the scalar block's length first. That is the whole reason both blocks carry
	# a trailing length.
	var basis_begin := int(tail["basis_begin"])
	var row_offsets := _pkid_basis_row_offsets(pkid, basis_begin)
	print("[NEG/NC2] the basis block starts at %d (%d rows, %d bytes); its first row's "
		% [basis_begin, int(tail["rows"]), int(tail["basis_len"])]
		+ "selector kind is at %d and its terms digest at %d (both WALKED, not a "
		% [int(row_offsets["kind"]), int(row_offsets["digest"])]
		+ "fixed distance from the end)")
	_expect("NEG/NC2: the walked basis row is addressable inside the payload",
		bool(row_offsets["ok"]),
		"basis_begin=%d size=%d offsets=%s" % [basis_begin, size, str(row_offsets)])
	if bool(row_offsets["ok"]):
		var basis_payload := pkid.duplicate()
		var digest_offset := int(row_offsets["digest"])
		var digest := basis_payload.decode_u64(digest_offset)
		basis_payload.encode_u64(digest_offset, digest ^ 1)
		_refuse(target, "NC2 basis digest", basis_payload,
			"ideology_save_applied_basis_mismatch",
			"the basis block is re-derived from the restored rows and compared, so a "
			+ "single flipped digest bit must not survive")
		var kind_payload := pkid.duplicate()
		kind_payload.encode_s32(int(row_offsets["kind"]), -1)
		_refuse(target, "NC3 basis selector kind", kind_payload,
			"ideology_save_applied_basis_invalid",
			"a selector kind that cannot describe a real program is refused by name "
			+ "at the row, before it can reach the state hash")
	# ---- NC6/NC7: the §18.5 scalar block and sample day, WALKED ------------
	#
	# Same rule as NC2/NC3: the byte is addressed through the walk, never at a fixed
	# distance from the end.
	var scalar_begin := int(tail["scalar_begin"])
	var scalar_rows := int(tail["scalar_rows"])
	var scalar_value_off := scalar_begin + 4 + 12   # first row's value_q16
	print("[NEG/NC6] the scalar block starts at %d (%d rows, %d bytes); the first row's "
		% [scalar_begin, scalar_rows, int(tail["scalar_len"])]
		+ "value is at %d, the sample day is at %d (both DERIVED)"
		% [scalar_value_off, size - PKID_TAIL_SAMPLE_DAY])
	_expect("NEG/NC6: the walked scalar row is addressable inside the payload",
		scalar_rows >= 1 and scalar_value_off + 8 <= int(tail["scalar_walk_end"]),
		"begin=%d value=%d rows=%d end=%d" % [scalar_begin, scalar_value_off,
			scalar_rows, int(tail["scalar_walk_end"])])
	if scalar_rows >= 1:
		var value_payload := pkid.duplicate()
		value_payload.encode_u8(scalar_value_off,
			value_payload.decode_u8(scalar_value_off) ^ 0x01)
		_refuse(target, "NC6 scalar value", value_payload,
			"ideology_save_scalar_basis_mismatch",
			"the scalar values are re-derived from the restored rows and compared, so "
			+ "a single flipped value bit must not survive")
		var day_payload := pkid.duplicate()
		day_payload.encode_s64(size - PKID_TAIL_SAMPLE_DAY,
			day_payload.decode_s64(size - PKID_TAIL_SAMPLE_DAY) + 1007)
		_refuse(target, "NC7 sample day", day_payload,
			"ideology_save_state_hash_mismatch",
			"the sample day takes part in no content comparison, so only the state "
			+ "hash can catch it -- which is what proves it is inside the hash")
	# ---- NC4: PKEF truncated to its magic only ------------------------------
	var before := _ideology_fingerprint(target, _restore_handle)
	var truncated: Dictionary = target.restore_effect_state(
		captured["pkef"].slice(0, 4))
	var truncated_reason := String(truncated.get("reason", ""))
	print("[NEG/NC4] PKEF truncated to 4 bytes -> ok=%s reason='%s'"
		% [str(truncated.get("ok", true)), truncated_reason])
	_expect("NEG/NC4: a 4-byte PKEF is REFUSED with a named reason (no silent "
		+ "acceptance of a truncated section)",
		not bool(truncated.get("ok", true)) and not truncated_reason.is_empty(),
		"ok=%s reason='%s'" % [str(truncated.get("ok", true)), truncated_reason])
	_expect("NEG/NC4: the refusal left the ideology runtime untouched",
		_ideology_fingerprint(target, _restore_handle) == before,
		"fingerprint changed")
	# ---- NC5: is the PKEF answer about the DESTINATION or about the PAYLOAD? ----
	#
	# The same bytes, offered to the runtime that PRODUCED them. A refusal there cannot
	# be blamed on "a different world", so the two answers together say which fact the
	# refusal is. This is the control that keeps the [R][RESTORE] line above from being
	# read as "restoring into another world is special".
	var source_ext: Object = captured["world"]["ext"]
	var source_before := _ideology_fingerprint(source_ext, int(captured["handle"]))
	var same_world: Dictionary = source_ext.restore_effect_state(captured["pkef"])
	var same_ok := bool(same_world.get("ok", true))
	var same_reason := String(same_world.get("reason", ""))
	print("[NEG/NC5] the SAME PKEF offered to the runtime that PRODUCED it: ok=%s "
		% str(same_ok) + "reason='%s' | offered to the fresh world: ok=%s reason='%s'"
		% [same_reason, str(restored.get("pkef_ok", true)),
			String(restored.get("pkef_reason", ""))])
	_expect("NEG/NC5: the PKEF answer is a property of the PAYLOAD, not of the "
		+ "destination world -- the runtime that wrote it gives the same answer",
		same_ok == bool(restored.get("pkef_ok", same_ok))
			and (same_ok or same_reason == String(restored.get("pkef_reason", ""))),
		"same_world ok=%s reason='%s' / fresh_world ok=%s reason='%s'"
			% [str(same_ok), same_reason, str(restored.get("pkef_ok", "?")),
				String(restored.get("pkef_reason", ""))])
	_expect("NEG/NC5: the same-world attempt left that runtime untouched too",
		_ideology_fingerprint(source_ext, int(captured["handle"])) == source_before,
		"fingerprint changed")
	var diagnosis := _diagnose_pkef(captured["pkef"])
	print("[NEG/NC5][PKEF-ROWS] next_activation_sequence=%d instances=%d "
		% [int(diagnosis["next_activation"]), int(diagnosis["instances"])]
		+ "max_instance_activation_sequence=%d violations=%d first='%s' error='%s'"
		% [int(diagnosis["max_activation"]), int(diagnosis["violations"]),
			String(diagnosis["first"]), String(diagnosis["error"])])
	for row_value in (diagnosis["rows"] as Array).slice(0, 4):
		print("  [PKEF-ROW] %s" % String(row_value))
	if not bool(restored.get("pkef_ok", false)) and int(diagnosis["violations"]) > 0:
		print("[NEG/NC5][FINDING] PKEF captured under EFFECT worker authority cannot be "
			+ "restored ANYWHERE, not merely into another world: the rows written back "
			+ "from the worker carry `applied_stack_count=1` while the facade-local "
			+ "`effect_applied` latch they are paired with is still 0, and `restore` "
			+ "refuses that pair with 'pkef_instance_identity_invalid' "
			+ "(effect_runtime.cpp:7561-7562). The IDEOLOGY section is unaffected -- "
			+ "PKID's `worker_origin` flag short-circuits every Effect binding and "
			+ "instance query (ideology_runtime.cpp:7367-7373), which is why the "
			+ "projection below still round-trips. Not a defect in this fixture and not "
			+ "something it may paper over: it is a fact about the Effect domain's save "
			+ "and it is reported, not asserted away.")
	_expect("NEG/NC5: the PKEF ANSWER IS EXPLAINED BY THE PAYLOAD'S OWN ROWS -- a row "
		+ "condition the restore checks fails on the bytes themselves, so the refusal "
		+ "is diagnostic and not a destination mismatch",
		bool(restored.get("pkef_ok", false))
			or (int(diagnosis["violations"]) > 0
				and String(diagnosis["error"]).is_empty()),
		"violations=%d first='%s' error='%s' rows=%s"
			% [int(diagnosis["violations"]), String(diagnosis["first"]),
				String(diagnosis["error"]), str(diagnosis["rows"])])
	# ---- and a CLEAN PKID still restores afterwards -------------------------
	# The four refusals above all target the IDEOLOGY section (three deliberate
	# corruptions and one truncation). PKID is therefore what the clean control repeats:
	# it proves a refusal is not a half-applied one.
	var clean_ideology: Dictionary = target.restore_ideology_state(captured["pkid"])
	var clean_ok := bool(clean_ideology.get("ok", false))
	var clean_reason := String(clean_ideology.get("reason", ""))
	print(("[NEG/CLEAN] after four refusals the untouched PKID restores again: ok=%s "
		+ "reason='%s'") % [str(clean_ok), clean_reason])
	_expect("NEG/CLEAN: a refused restore is not a half-applied one -- the untouched "
		+ "PKID still restores after four refusals",
		clean_ok, "ok=%s reason='%s'" % [str(clean_ok), clean_reason])


## THE DURABILITY PHASE: the load must survive the worker's own write-back.
##
##   Under worker authority the main-thread runtime is a MIRROR whose rows are replaced
##   wholesale by every accepted pod snapshot (`apply_pod_snapshot`,
##   `ideology_runtime.cpp:1227-1229`), so "the projection came back" and "the load is
##   durable" are two different claims. This phase asserts the second one:
##
##     1. the restored state is pushed INTO the worker (`[R][IMPORT]`, and
##        `ideology_pod_committed_day` becomes the PAYLOAD's confirmed day, which is the
##        worker's own calendar adopting the restored one);
##     2. real days are driven until the pod has committed, because a fresh worker world
##        spends its first days starting the pod up (`pod_day` reading -1) and a
##        superseded day (calendar at or below the imported floor) plans nothing;
##     3. the production write-back is invoked by hand (it lives on the SUS tick,
##        `world_runtime_host.gd:1422`/`:1102`, which a `-s` fixture does not run) and the
##        restored rows, the §9.3 dates and the front are re-read;
##     4. a pump at the restored eligibility day then rebuilds the projection from
##        whatever the rows are AFTER the write-back -- the step that used to clear the
##        front.
func _assert_load_durability(captured: Dictionary, restored: Dictionary) -> void:
	if captured.is_empty() or restored.is_empty() \
			or bool(restored.get("refused", true)):
		_fail("DUR: the durability phase needs a restored world with a projection")
		return
	var w: Dictionary = restored["world"]
	var target: Object = w["ext"]
	var handle := _restore_handle
	var payload_rows: PackedInt32Array = captured["rows"]
	var payload_state: Dictionary = captured["state"]
	var payload_probe: Dictionary = captured["probe"]
	# ---- 1. the import channel, from the restore result ---------------------
	var import_result: Dictionary = restored.get("import_result", {})
	var import_code := String(import_result.get("worker_import", "<absent>"))
	print("[R][IMPORT] restore_ideology_state answered worker_import='%s' "
		% import_code + "imported=%s detail='%s'"
		% [str(import_result.get("worker_imported", false)),
			String(import_result.get("worker_import_detail", ""))])
	_expect("DUR[1/4]: the restore PUSHES the restored state into the worker, and the "
		+ "result names the channel (`worker_import` is `applied`, or "
		+ "`economy_day_inflight` when the worker held its day and the write-back retries)",
		import_code == "applied" or import_code == "economy_day_inflight",
		"worker_import='%s' detail='%s'" % [import_code,
			String(import_result.get("worker_import_detail", ""))])
	var rows_before := _idea_rows(target, handle)
	var layer_before := _layer_state(target)
	var pod_before := int(target.get_runtime_thread_report().get(
		"ideology_pod_committed_day", -1))
	var mask_before := int(target.get_runtime_thread_report().get(
		"authoritative_domain_mask", -1))
	w["pump"] = false
	# A fresh worker world spends its first days starting the pod up (`pod_day` reads -1
	# and the authority mask is still 0x000), so ONE day says nothing about durability.
	# Drive until the pod has committed the imported day, or the bound is reached.
	_pod_wait_ms = AFTER_DAY_POD_WAIT_MS
	var driven := 0
	var last_ok := false
	for _index in range(AFTER_DAY_LIMIT):
		if bool(w.get("faulted", false)) or _budget_exhausted:
			break
		var outcome := _drive_day(w)
		driven += 1
		last_ok = bool(outcome.get("ok", false))
		if int(target.get_runtime_thread_report().get(
				"ideology_pod_committed_day", -1)) > pod_before:
			break
	_pod_wait_ms = POD_WAIT_MS
	var rows_after := _idea_rows(target, handle)
	var layer_after := _layer_state(target)
	var pod_after := int(target.get_runtime_thread_report().get(
		"ideology_pod_committed_day", -1))
	var mask_after := int(target.get_runtime_thread_report().get(
		"authoritative_domain_mask", -1))
	print("[R][AFTER-DAY] %d real day(s) after the load (last ok=%s, day %d): idea_rows "
		% [driven, str(last_ok), int(w["tick"])]
		+ "%s -> %s | installed %s -> %s | cells %d -> %d | confirmed/eligible %d/%d -> "
		% [str(rows_before), str(rows_after), str(layer_before["installed"]),
			str(layer_after["installed"]), int(layer_before["cell_count"]),
			int(layer_after["cell_count"]), int(layer_before["basis_confirmed_day"]),
			int(layer_before["basis_eligible_day"])]
		+ "%d/%d | pod_day %d -> %d | mask 0x%03X -> 0x%03X | fault='%s'"
		% [int(layer_after["basis_confirmed_day"]),
			int(layer_after["basis_eligible_day"]), pod_before, pod_after,
			mask_before, mask_after, _worker_fault(target)])
	# ---- 2. the worker's calendar became the payload's ----------------------
	_expect("DUR[2/4]: the worker's committed day is the PAYLOAD's confirmed day (%d), "
		% int(payload_state["basis_confirmed_day"])
		+ "not its own calendar -- the import superseded it, it did not merge",
		pod_after == int(payload_state["basis_confirmed_day"]),
		"pod_committed_day=%d payload_confirmed=%d (was %d)"
			% [pod_after, int(payload_state["basis_confirmed_day"]), pod_before])
	var layer_report: Dictionary = target.get_ideology_report()
	_expect("DUR[2/4]: the worker import is recorded as APPLIED on the runtime (not "
		+ "still pending and not refused), so the mirror is no longer holding the load "
		+ "against the worker",
		String(layer_report.get("worker_import_last_code", "")) == "applied"
			and not bool(layer_report.get("worker_import_pending", true)),
		"last_code='%s' pending=%s attempts=%s"
			% [String(layer_report.get("worker_import_last_code", "?")),
				str(layer_report.get("worker_import_pending", "?")),
				str(layer_report.get("worker_import_attempts", "?"))])
	# ---- 3. the write-back itself, which decides the question ---------------
	#
	# The production caller is `world_runtime_host._consume_ideology_worker_snapshot_
	# if_authoritative()` (`world_runtime_host.gd:1453`), and that lives on the SUS runtime
	# TICK, not on `run_daily_tick` -- which is why the days above did not move the mirror
	# on their own. A `-s` fixture has no tick loop, so the facade the host calls is called
	# here directly with the "latest ready snapshot" cursor. It is retried because a
	# snapshot published BEFORE the import loses the generation race on purpose
	# (`ideology_pod_snapshot_superseded`), and because a day the worker holds the boundary
	# answers `economy_day_inflight`; both are contention, not verdicts.
	var applied: Dictionary = {}
	var writeback_attempts := 0
	var superseded_seen := false
	for _index in range(AFTER_DAY_LIMIT):
		if bool(w.get("faulted", false)) or _budget_exhausted:
			break
		writeback_attempts += 1
		applied = w["generator"].apply_runtime_ideology_snapshot(-1)
		if bool(applied.get("applied", false)):
			break
		if bool(applied.get("superseded", false)):
			superseded_seen = true
		var code := String(applied.get("code", ""))
		if code == "ideology_worker_imported" or code == "economy_day_inflight" \
				or code == "ideology_snapshot_unavailable" \
				or code == "ideology_pod_snapshot_superseded":
			OS.delay_msec(4)
			_drive_day(w)
			continue
		break
	print("[R][AFTER-DAY] write-back apply_runtime_ideology_snapshot(-1) after %d "
		% writeback_attempts + "attempt(s): ok=%s applied=%s superseded_seen=%s "
		% [str(applied.get("ok", "?")), str(applied.get("applied", "?")),
			str(superseded_seen)]
		+ "generation=%s code='%s'"
		% [str(applied.get("generation", "?")), String(applied.get("code", ""))])
	var rows_written := _idea_rows(target, handle)
	var layer_written := _layer_state(target)
	print("[R][AFTER-DAY] after the write-back: idea_rows %s -> %s | installed %s -> %s "
		% [str(rows_after), str(rows_written), str(layer_after["installed"]),
			str(layer_written["installed"])]
		+ "| cells %d -> %d | confirmed/eligible %d/%d -> %d/%d"
		% [int(layer_after["cell_count"]), int(layer_written["cell_count"]),
			int(layer_after["basis_confirmed_day"]),
			int(layer_after["basis_eligible_day"]),
			int(layer_written["basis_confirmed_day"]),
			int(layer_written["basis_eligible_day"])])
	_expect("DUR[3/4]: a real worker write-back RAN on the loaded world (a snapshot was "
		+ "applied, not refused), so the assertions below are about a load that met the "
		+ "worker's own publish path",
		writeback_attempts > 0 and bool(applied.get("applied", false)),
		"attempts=%d ok=%s applied=%s code='%s'"
			% [writeback_attempts, str(applied.get("ok", "?")),
				str(applied.get("applied", "?")), String(applied.get("code", ""))])
	# ---- 4. HEADLINE: the payload's rows/dates/front survive that write-back ----
	_expect("DUR[4/4][HEADLINE]: the restored IDEA ROWS are still the payload's after "
		+ "the write-back (the worker adopted them instead of publishing over them)",
		rows_written == payload_rows and rows_written.size() > 0,
		"payload=%s write-back=%s (before the write-back: %s)"
			% [str(payload_rows), str(rows_written), str(rows_after)])
	_expect("DUR[4/4][HEADLINE]: the mirrored §9.3 dates are STILL the payload's (%d/%d) "
		% [int(payload_state["basis_confirmed_day"]),
			int(payload_state["basis_eligible_day"])]
		+ "after the write-back -- not the worker's committed day",
		int(layer_written["basis_confirmed_day"])
			== int(payload_state["basis_confirmed_day"])
			and int(layer_written["basis_eligible_day"])
				== int(payload_state["basis_eligible_day"]),
		"payload=%d/%d write-back=%d/%d"
			% [int(payload_state["basis_confirmed_day"]),
				int(payload_state["basis_eligible_day"]),
				int(layer_written["basis_confirmed_day"]),
				int(layer_written["basis_eligible_day"])])
	# One pump at the restored eligibility day, exactly as the host pump would: the front
	# must be rebuilt FROM the surviving rows, and the rows must not move in the process.
	var pump_day := int(restored.get("day", int(w["tick"])))
	var pump := _pump_derived(w, pump_day, RESTORE_PUMP_ATTEMPTS)
	var layer_pumped := _layer_state(target)
	var rows_pumped := _idea_rows(target, handle)
	var probe_pumped := _probe_all_cells(target, STAT_ADD, int(w["cells"]))
	var diff := _compare_probes(payload_probe, probe_pumped)
	print("[R][AFTER-DAY] pump at day %d: calls=%d inflight=%d done=%s code='%s' -> "
		% [pump_day, int(pump.get("attempts", 0)), int(pump.get("inflight", 0)),
			str(pump.get("done", false)), String(pump.get("code", ""))]
		+ "installed=%s cells=%d contributions=%d gated=%d | rows %s"
		% [str(layer_pumped["installed"]), int(layer_pumped["cell_count"]),
			int(layer_pumped["contribution_count"]),
			int(layer_pumped["gated_by_eligibility"]), str(rows_pumped)])
	print("[R][AFTER-DAY][PARITY] cells=%d presence_mismatch=%d add_mismatch=%d "
		% [int(diff["cells"]), int(diff["presence_mismatch"]),
			int(diff["add_mismatch"])]
		+ "max_abs_add_diff=%.17f covered(payload)=%d covered(reloaded)=%d"
		% [float(diff["max_abs_add_diff"]), int(payload_probe["covered"]),
			int(probe_pumped["covered"])])
	_expect("DUR[4/4][HEADLINE]: the front is STILL INSTALLED after the write-back and "
		+ "the pump, with the payload's cell/contribution counts",
		bool(layer_pumped["installed"])
			and int(layer_pumped["cell_count"]) == int(payload_state["cell_count"])
			and int(layer_pumped["contribution_count"])
				== int(payload_state["contribution_count"]),
		"installed=%s cells=%d (payload %d) contributions=%d (payload %d)"
			% [str(layer_pumped["installed"]), int(layer_pumped["cell_count"]),
				int(payload_state["cell_count"]),
				int(layer_pumped["contribution_count"]),
				int(payload_state["contribution_count"])])
	_expect("DUR[4/4][HEADLINE]: the per-cell values are the payload's, cell for cell "
		+ "(presence mismatch 0, |derived_add| difference exactly 0)",
		int(diff["cells"]) == CELLS and int(diff["presence_mismatch"]) == 0
			and int(diff["add_mismatch"]) == 0
			and float(diff["max_abs_add_diff"]) == 0.0
			and int(payload_probe["covered"]) > 0,
		"cells=%d presence_mismatch=%d add_mismatch=%d max_abs_add_diff=%.17f"
			% [int(diff["cells"]), int(diff["presence_mismatch"]),
				int(diff["add_mismatch"]), float(diff["max_abs_add_diff"])])
	_expect("DUR[4/4]: the pump rebuilt from the surviving rows -- the idea rows are "
		+ "unchanged by it, so the front above came from the restored cards",
		rows_pumped == payload_rows,
		"payload=%s after pump=%s" % [str(payload_rows), str(rows_pumped)])


## THE NEGATIVE CONTROL: ideology on the MAIN thread (no worker grant at all).
##
##   The import must not touch the main-thread path, and the way to prove that is to run
##   it: a third world is built with NO authority mask, the SAME worker-authored PKID is
##   restored into it, and the pre-change behaviour is asserted -- accepted, `worker_import`
##   ABSENT (the branch is not even reached), the payload's rows and §9.3 dates, and a day
##   of main-thread `run_ideology_daily` that leaves both alone.
func _run_main_thread_negative_control(captured: Dictionary) -> void:
	if captured.is_empty():
		_fail("NC/MAIN: the captured payload exists, so the control can run")
		return
	print("[NC/MAIN] building a NO-WORKER world (authority off, mask 0x000) to restore the "
		+ "same PKID into -- the main-thread path must behave exactly as before")
	var spec := _world_spec("NC-main")
	spec["authority"] = false
	spec["shadow_on_generate"] = false
	spec["parity_forcing"] = false
	spec["mask"] = 0
	var w := await _build_world(spec, false)
	_expect("NC/MAIN: the no-worker world builds", not w.is_empty(),
		"building failed (see the BUILD lines above)")
	if w.is_empty():
		return
	_worlds.append(w)
	var ext: Object = w["ext"]
	var handle := int(w["handle"])
	var mask := int(ext.get_runtime_thread_report().get(
		"authoritative_domain_mask", -1)) \
		if ext.has_method("get_runtime_thread_report") else -1
	print("[NC/MAIN] worker mask=0x%03X, day=%d, idea_rows before=%s"
		% [mask, int(w["tick"]), str(_idea_rows(ext, handle))])
	var restored: Dictionary = ext.restore_ideology_state(captured["pkid"])
	print("[NC/MAIN] PKID into the no-worker world: ok=%s reason='%s' worker_import=%s"
		% [str(restored.get("ok", false)), String(restored.get("reason", "")),
			("ABSENT" if not restored.has("worker_import")
				else String(restored.get("worker_import")))])
	_expect("NC/MAIN[1/3]: the worker-authored PKID still restores on the MAIN-THREAD "
		+ "path (the fix did not gate the restore behind a worker)",
		bool(restored.get("ok", false)),
		"ok=%s reason='%s'" % [str(restored.get("ok", false)),
			String(restored.get("reason", ""))])
	_expect("NC/MAIN[2/3]: the main-thread path carries NO `worker_import` key -- the "
		+ "import branch is not reached at all, so its result shape is the one it always "
		+ "had",
		not restored.has("worker_import"),
		"keys=%s" % str(restored.keys()))
	var rows_restored := _idea_rows(ext, handle)
	var layer_restored := _layer_state(ext)
	print("[NC/MAIN] rows=%s confirmed/eligible=%d/%d"
		% [str(rows_restored), int(layer_restored["basis_confirmed_day"]),
			int(layer_restored["basis_eligible_day"])])
	_expect("NC/MAIN[2/3]: the rows and the §9.3 dates are the payload's, exactly as "
		+ "before the import existed",
		rows_restored == PackedInt32Array(captured["rows"])
			and int(layer_restored["basis_confirmed_day"])
				== int((captured["state"] as Dictionary)["basis_confirmed_day"])
			and int(layer_restored["basis_eligible_day"])
				== int((captured["state"] as Dictionary)["basis_eligible_day"]),
		"rows=%s payload=%s dates=%d/%d payload=%d/%d"
			% [str(rows_restored), str(captured["rows"]),
				int(layer_restored["basis_confirmed_day"]),
				int(layer_restored["basis_eligible_day"]),
				int((captured["state"] as Dictionary)["basis_confirmed_day"]),
				int((captured["state"] as Dictionary)["basis_eligible_day"])])
	# A main-thread day: `run_ideology_daily` is NOT suppressed here, so it settles on the
	# main thread and must leave the restored rows alone (nothing to equip, nothing to
	# promote). This is the leg that would break if the import had become a second writer.
	_drive_day(w)
	var rows_after_day := _idea_rows(ext, handle)
	var layer_after_day := _layer_state(ext)
	print("[NC/MAIN] after one main-thread day %d: rows=%s confirmed/eligible=%d/%d "
		% [int(w["tick"]), str(rows_after_day),
			int(layer_after_day["basis_confirmed_day"]),
			int(layer_after_day["basis_eligible_day"])]
		+ "suppressed=%s path='%s'"
		% [str(w["last_suppressed"]),
			String((w["last_ideology"] as Dictionary).get("path", ""))])
	_expect("NC/MAIN[3/3]: one real main-thread ideology day leaves the restored rows "
		+ "and dates alone, and the day RAN on the main thread (not suppressed)",
		rows_after_day == rows_restored
			and int(layer_after_day["basis_confirmed_day"])
				== int(layer_restored["basis_confirmed_day"])
			and not bool(w["last_suppressed"]),
		"rows=%s -> %s dates=%d/%d -> %d/%d suppressed=%s path='%s'"
			% [str(rows_restored), str(rows_after_day),
				int(layer_restored["basis_confirmed_day"]),
				int(layer_restored["basis_eligible_day"]),
				int(layer_after_day["basis_confirmed_day"]),
				int(layer_after_day["basis_eligible_day"]),
				str(w["last_suppressed"]),
				String((w["last_ideology"] as Dictionary).get("path", ""))])


func _refuse(target: Object, label: String, payload: PackedByteArray,
		expected_reason: String, why: String) -> String:
	var before := _ideology_fingerprint(target, _restore_handle)
	var result: Dictionary = target.restore_ideology_state(payload)
	var reason := String(result.get("reason", ""))
	var after := _ideology_fingerprint(target, _restore_handle)
	print("[NEG/%s] ok=%s reason='%s' state_unchanged=%s"
		% [label, str(result.get("ok", true)), reason, str(before == after)])
	_expect("NEG/%s: the corrupted payload is REFUSED (ok=false) -- %s"
		% [label, why], not bool(result.get("ok", true)),
		"ok=%s reason='%s'" % [str(result.get("ok", true)), reason])
	_expect("NEG/%s: the refusal NAMES %s" % [label, expected_reason],
		reason == expected_reason, "reason='%s' expected='%s'"
			% [reason, expected_reason])
	_expect("NEG/%s: the refusal left the runtime untouched (a refused restore is "
		+ "not a half-applied one)" % label, before == after, "fingerprint changed")
	return reason


# =========================================================================
# PKID wire helpers -- offsets derived, the basis block WALKED
# =========================================================================
func _magic_of(bytes: PackedByteArray) -> int:
	return bytes.decode_u32(0) if bytes.size() >= 4 else 0


## Walks the header up to the `worker_origin` flag: magic/schema/catalog/last_day/
## submit_order/state_hash, the producer high-watermark table, `points_revision_seen`,
## then one byte (`ideology_runtime.cpp:6806-6819`).
func _pkid_worker_origin(bytes: PackedByteArray) -> int:
	var cursor := PKID_HEADER_FIXED
	if cursor + 8 > bytes.size():
		return -1
	var producers := int(bytes.decode_u64(cursor))
	cursor += 8
	if producers < 0 or producers > 65536:
		return -1
	cursor += producers * PKID_PRODUCER_ROW
	cursor += 8          # points_revision_seen
	if cursor + 1 > bytes.size():
		return -1
	return int(bytes.decode_u8(cursor))


func _pkid_string_len(bytes: PackedByteArray, cursor: int) -> int:
	if cursor + 4 > bytes.size():
		return 0
	var length := int(bytes.decode_u32(cursor))
	return length + 4


## The byte offsets of the FIRST applied-basis row's `selector_kind` and `terms_digest`,
## found by WALKING the row (u64 handle, string program key, i32 kind, string selector id,
## i32 param0, i32 param1, u64 digest). A hard-coded distance from the start of the block
## would be wrong the moment a program key changes length, and a hard-coded distance from
## the END would be wrong the moment a card gains a term -- both are silent.
func _pkid_basis_row_offsets(bytes: PackedByteArray, basis_begin: int) -> Dictionary:
	var out := {"ok": false, "kind": -1, "digest": -1}
	var cursor := basis_begin + 4          # past the row count
	if cursor + 8 > bytes.size():
		return out
	cursor += 8                            # country handle
	var key_len := _pkid_string_len(bytes, cursor)
	if key_len < 4 or cursor + key_len > bytes.size():
		return out
	cursor += key_len                      # program key
	out["kind"] = cursor
	cursor += 4                            # selector kind
	var id_len := _pkid_string_len(bytes, cursor)
	if id_len < 4 or cursor + id_len > bytes.size():
		return out
	cursor += id_len                       # selector id
	cursor += 4 + 4                        # selector_param[0], selector_param[1]
	out["digest"] = cursor
	out["ok"] = cursor + 8 <= bytes.size()
	return out


## Walks the PKEF instance rows and evaluates, on the BYTES, the same row conditions
## `EffectRuntime::restore` refuses on (`effect_runtime.cpp:7548-7584`). This exists so a
## refusal of a payload this build wrote can be localised to a row instead of being
## reported as an opaque code. Row layout taken from `capture()` (`:7292-7338`).
func _diagnose_pkef(bytes: PackedByteArray) -> Dictionary:
	var out := {"ok": false, "next_activation": 0, "instances": 0,
		"max_activation": 0, "violations": 0, "first": "", "error": "",
		"rows": []}
	if bytes.size() < PKEF_OFF_INSTANCE_COUNT + 4:
		out["error"] = "payload shorter than the instance header"
		return out
	var next_activation := int(bytes.decode_u64(PKEF_OFF_NEXT_ACTIVATION))
	var count := int(bytes.decode_u32(PKEF_OFF_INSTANCE_COUNT))
	out["next_activation"] = next_activation
	out["instances"] = count
	var cursor := PKEF_OFF_INSTANCE_COUNT + 4
	var max_activation := 0
	var rows: Array = out["rows"]
	for index in range(count):
		if cursor + PKEF_INSTANCE_FIXED > bytes.size():
			out["error"] = "instance %d truncated at %d" % [index, cursor]
			return out
		var base := cursor
		var instance_id := int(bytes.decode_s64(base + 0))
		var generation := int(bytes.decode_u32(base + 8))
		var program_id := int(bytes.decode_s32(base + 12))
		var input_revision := int(bytes.decode_s64(base + 64))
		var last_evaluated := int(bytes.decode_s64(base + 72))
		var fire_sequence := int(bytes.decode_u64(base + 80))
		var max_stacks := int(bytes.decode_s32(base + 113))
		var stack_count := int(bytes.decode_s32(base + 117))
		var applied_stack_count := int(bytes.decode_s32(base + 121))
		var activation_sequence := int(bytes.decode_u64(base + 129))
		var effect_applied := int(bytes.decode_u8(base + 153))
		var applied_input_revision := int(bytes.decode_s64(base + 155))
		var last_acked := int(bytes.decode_u64(base + 163))
		var metric_count := int(bytes.decode_u32(base + 172))
		max_activation = maxi(max_activation, activation_sequence)
		var breach := ""
		if instance_id != 0 and activation_sequence >= next_activation:
			breach = "activation_sequence %d >= next_activation_sequence %d" \
				% [activation_sequence, next_activation]
		elif instance_id != 0 and (instance_id < 0 or generation == 0
				or program_id < 0 or activation_sequence == 0):
			breach = "id/generation/program/activation identity"
		elif max_stacks <= 0 or stack_count <= 0 or stack_count > max_stacks:
			breach = "stack_count %d / max_stacks %d" % [stack_count, max_stacks]
		elif (effect_applied == 0) != (applied_stack_count == 0):
			breach = "effect_applied %d vs applied_stack_count %d" \
				% [effect_applied, applied_stack_count]
		elif applied_input_revision > input_revision:
			breach = "applied_input_revision %d > input_revision %d" \
				% [applied_input_revision, input_revision]
		elif last_acked > fire_sequence:
			breach = "last_acked_fire_sequence %d > fire_sequence %d" \
				% [last_acked, fire_sequence]
		elif last_evaluated > input_revision:
			breach = "last_evaluated_input_revision %d > input_revision %d" \
				% [last_evaluated, input_revision]
		if not breach.is_empty():
			out["violations"] = int(out["violations"]) + 1
			if String(out["first"]).is_empty():
				out["first"] = "instance %d: %s" % [instance_id, breach]
		if rows.size() < 8:
			rows.append("id=%d gen=%d prog=%d activation=%d next=%d stack=%d/%d "
				% [instance_id, generation, program_id, activation_sequence,
					next_activation, stack_count, max_stacks]
				+ "input_rev=%d applied_rev=%d %s"
				% [input_revision, applied_input_revision,
					("BREACH: " + breach) if not breach.is_empty() else "ok"])
		cursor = base + PKEF_INSTANCE_FIXED + metric_count * 9
	out["max_activation"] = max_activation
	out["ok"] = true
	return out


## Reads the v14 tail from the END (SAVE_END / contract / eligible / confirmed / sample
## day / scalar-block length) and WALKS BOTH variable-length blocks it delimits, in the
## order the writer lays them down: the plan-18.5 scalar block first (it is nearest the
## tail), then the plan-18.2 applied basis.
##
## `ok` is true only when each block's declared length lands exactly on the length field
## that declares it, i.e. when neither length is a number the reader never checks.
func _walk_pkid_tail(bytes: PackedByteArray) -> Dictionary:
	var out := {
		"ok": false, "size": bytes.size(), "basis_len": -1, "rows": -1,
		"walk_end": -1, "confirmed": -1, "eligible": -1, "contract": 0,
		"save_end": 0, "error": "", "sample_day": 0, "scalar_len": -1,
		"scalar_rows": -1, "scalar_begin": -1, "basis_begin": -1,
		"scalar_walk_end": -1, "scalar_ok": false,
	}
	var size := bytes.size()
	if size <= PKID_TAIL_SCALAR_LEN:
		out["error"] = "payload shorter than the tail"
		return out
	out["save_end"] = bytes.decode_u32(size - PKID_TAIL_END)
	out["contract"] = bytes.decode_u64(size - PKID_TAIL_CONTRACT)
	out["eligible"] = bytes.decode_s64(size - PKID_TAIL_ELIGIBLE)
	out["confirmed"] = bytes.decode_s64(size - PKID_TAIL_CONFIRMED)
	out["sample_day"] = bytes.decode_s64(size - PKID_TAIL_SAMPLE_DAY)
	# ---- block 1: the §18.5 local scalar basis (nearest the tail) -----------
	var scalar_len := int(bytes.decode_u32(size - PKID_TAIL_SCALAR_LEN))
	out["scalar_len"] = scalar_len
	var scalar_begin := size - PKID_TAIL_SCALAR_LEN - scalar_len
	out["scalar_begin"] = scalar_begin
	if scalar_begin < PKID_HEADER_FIXED or scalar_len < 4:
		out["error"] = "scalar block does not fit: begin=%d len=%d" % [
			scalar_begin, scalar_len]
		return out
	var scalar_rows := int(bytes.decode_u32(scalar_begin))
	out["scalar_rows"] = scalar_rows
	if scalar_rows < 0 or scalar_rows > 1000000:
		out["error"] = "scalar row count %d" % scalar_rows
		return out
	var scalar_cursor := scalar_begin + 4 + scalar_rows * PKID_SCALAR_ROW
	out["scalar_walk_end"] = scalar_cursor
	out["scalar_ok"] = scalar_cursor == size - PKID_TAIL_SCALAR_LEN
	if not bool(out["scalar_ok"]):
		out["error"] = "scalar walk ended at %d, its length field is at %d" % [
			scalar_cursor, size - PKID_TAIL_SCALAR_LEN]
		return out
	# ---- block 2: the §18.2 applied-program basis --------------------------
	var basis_len_offset := scalar_begin - 4
	var basis_len := int(bytes.decode_u32(basis_len_offset))
	out["basis_len"] = basis_len
	var block_begin := basis_len_offset - basis_len
	out["basis_begin"] = block_begin
	if block_begin < PKID_HEADER_FIXED or basis_len < 4:
		out["error"] = "basis block does not fit: begin=%d len=%d" % [
			block_begin, basis_len]
		return out
	var cursor := block_begin
	var rows := int(bytes.decode_u32(cursor))
	cursor += 4
	if rows < 0 or rows > 1000000:
		out["error"] = "basis row count %d" % rows
		return out
	for _index in range(rows):
		cursor += 8                                        # country handle
		var key_len := _pkid_string_len(bytes, cursor)      # program key
		if key_len < 4 or cursor + key_len > size:
			out["error"] = "program key overruns at %d" % cursor
			return out
		cursor += key_len
		cursor += 4                                        # selector kind
		var id_len := _pkid_string_len(bytes, cursor)       # selector id
		if id_len < 4 or cursor + id_len > size:
			out["error"] = "selector id overruns at %d" % cursor
			return out
		cursor += id_len
		cursor += 4 + 4 + 8                                # param0/param1/digest
	out["rows"] = rows
	out["walk_end"] = cursor
	out["ok"] = cursor == basis_len_offset
	if not bool(out["ok"]):
		out["error"] = "basis walk ended at %d, its length field is at %d" % [
			cursor, basis_len_offset]
	return out


func _ideology_fingerprint(ext: Object, handle: int) -> String:
	var layer := _layer_state(ext)
	var report: Dictionary = ext.get_ideology_report()
	return "layer(installed=%s cells=%d contributions=%d gen=%d)" % [
		str(layer["installed"]), int(layer["cell_count"]),
		int(layer["contribution_count"]), int(layer["layer_generation"])] \
		+ " dates(%d/%d) rows(%d)" % [int(layer["basis_confirmed_day"]),
			int(layer["basis_eligible_day"]), _idea_rows(ext, handle).size()] \
		+ " contract(%s) basis(%s/%s) pending(%s)" % [
			str(report.get("execution_contract_hash", "?")),
			str(report.get("applied_program_basis_rows", "?")),
			str(report.get("applied_program_basis_digest", "?")),
			str(report.get("pending_transitions", "?"))]


## The fields PKID restores about the country's ideas, flattened so two sides can be
## compared with `==` and printed as one line.
func _idea_rows(ext: Object, handle: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if ext == null:
		return out
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var locations: PackedInt32Array = snapshot.get(
		"locations", PackedInt32Array())
	var levels: PackedInt32Array = snapshot.get("levels", PackedInt32Array())
	var pending: PackedByteArray = snapshot.get(
		"transition_pending", PackedByteArray())
	for index in range(ids.size()):
		out.append(int(ids[index]))
		out.append(int(locations[index]) if index < locations.size() else -1)
		out.append(int(levels[index]) if index < levels.size() else -1)
		out.append(int(pending[index]) if index < pending.size() else -1)
	return out


# =========================================================================
# world construction (identical to the pinned `ideology_worker_derived_pump_test`)
# =========================================================================
func _world_spec(name: String) -> Dictionary:
	return {
		"name": name,
		"width": WIDTH, "height": HEIGHT, "seed": SEED,
		"foreign_count": 1,
		"authority": true,
		"shadow_on_generate": true,
		"parity_forcing": true,
		"mask": MASK_WORKER_IDEOLOGY,
	}


func _build_world(spec: Dictionary, worker: bool) -> Dictionary:
	var width := int(spec.get("width", WIDTH))
	var height := int(spec.get("height", HEIGHT))
	var seed := int(spec.get("seed", SEED))
	var name := String(spec.get("name", "world"))
	var started := Time.get_ticks_msec()
	print("[BUILD/%s] generating %dx%d seed=%d mask=0x%03X authority=%s"
		% [name, width, height, seed, int(spec.get("mask", MASK_WORKER_IDEOLOGY)),
			str(spec.get("authority", false))])
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = width
	host.map_height = height
	host.initial_seed = seed
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = bool(spec.get("authority", false))
	host.runtime_shadow_on_generate = bool(spec.get("shadow_on_generate", true))
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = int(spec.get("mask", MASK_WORKER_IDEOLOGY))
	host.runtime_parity_forcing = bool(spec.get("parity_forcing", false))
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	if bool(spec.get("authority", false)):
		host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "W %s" % name
	config.country.foreign_count = int(spec.get("foreign_count", 1))
	config.base.map_width = width
	config.base.map_height = height
	config.base.initial_seed = seed
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("BUILD/%s: the session configures" % name,
			bool(session.get("ok", false)), str(session)):
		return {}
	await host.generate_world(seed)
	var generator: MapGenerator = host.get_generator()
	if not _require("BUILD/%s: production world generation succeeded" % name,
			generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("BUILD/%s: production DCWorldExt is bound" % name, ext != null):
		return {}
	if worker:
		ext.set_runtime_ideology_parity_enabled(false)
		ext.set_runtime_clock(true, WORKER_SPEED)
	var w := {
		"name": name, "host": host, "clock": clock, "ext": ext,
		"generator": generator, "tick": 0, "cells": width * height,
		"handle": 0, "started_ms": Time.get_ticks_msec(),
		"last_ideology": {}, "last_suppressed": false, "last_effect": {},
		"slices": 0, "faulted": false, "fault_reported": false, "seed": seed,
		"pump": false, "days": [], "pumped_days": 0,
		"first_installed_day": -1, "confirmed_at_first_install": -1,
		"eligible_at_first_install": -1,
	}
	var handles := _country_handles(w)
	if not _require("BUILD/%s: the world has at least one country" % name,
			handles.size() >= 1, str(handles)):
		return {}
	w["handle"] = int(handles[0])
	w["tick"] = maxi(0, _world_day(ext))
	print("[BUILD/%s] ready in %d ms: countries=%d handle=%d start_day=%d"
		% [name, Time.get_ticks_msec() - started, handles.size(),
			int(w["handle"]), int(w["tick"])])
	return w


func _country_handles(w: Dictionary) -> PackedInt64Array:
	var ext: Object = w["ext"]
	var seen := {}
	var out := PackedInt64Array()
	for cell in range(int(w["cells"])):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		var handle := int(summary.get("country_handle", 0))
		if handle == 0 or seen.has(handle):
			continue
		seen[handle] = true
		out.append(handle)
	return out


# =========================================================================
# day driving
# =========================================================================
func _service_peers(ext: Object, passes: int = PEER_PASSES) -> void:
	if not ext.has_method("service_country_worker_peer_adapter"):
		return
	for _pass in range(passes):
		ext.service_country_worker_peer_adapter(PEER_BATCH, true)


func _drive_days(w: Dictionary, days: int) -> void:
	for _index in range(days):
		_drive_day(w)


func _drive_day(w: Dictionary) -> Dictionary:
	if bool(w.get("faulted", false)):
		return {"ok": false, "faulted": true}
	if _budget_exhausted:
		return {"ok": false, "budget": true}
	if Time.get_ticks_msec() - _run_started_ms > GLOBAL_BUDGET_MS:
		_budget_exhausted = true
		print("[BUDGET] wall-clock budget exhausted at day %d of '%s'"
			% [int(w["tick"]), String(w["name"])])
		return {"ok": false, "budget": true}
	var ext: Object = w["ext"]
	var clock: WorldClock = w["clock"]
	var host: WorldRuntimeHost = w["host"]
	var fault := _worker_fault(ext)
	if not fault.is_empty():
		w["faulted"] = true
		if not bool(w.get("fault_reported", false)):
			w["fault_reported"] = true
			print("[%s][FINDING] the worker faulted with '%s' at day %d -- the "
				% [String(w["name"]), fault, int(w["tick"])]
				+ "remaining days are not driven and what was measured is reported")
		return {"ok": false, "fault": fault}
	w["tick"] = int(w["tick"]) + 1
	var day := int(w["tick"])
	clock.current_day = float(day)
	_service_peers(ext)
	if ext.has_method("publish_ideology_worker_inputs"):
		ext.publish_ideology_worker_inputs()
	host.run_daily_tick(day, clock.season_phase_for_day(day))
	host.finish_daily_tick(0.0, {})
	var pulses := 0
	while _has_hard_barrier(clock) and pulses < 400:
		clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
	# Production settle handshake only on the main-thread side; under worker authority
	# the worker's own graph owns it and a second handshake here would double-apply.
	var ideology: Dictionary = {}
	var slices := 0
	for _slice in range(MAX_SLICES_PER_DAY):
		slices += 1
		ideology = ext.run_ideology_daily(day)
		if not bool(ideology.get("ok", true)):
			break
		if bool(ideology.get("suppressed", false)):
			break
		if bool(ideology.get("done", false)):
			break
	w["last_ideology"] = ideology
	w["last_suppressed"] = bool(ideology.get("suppressed", false))
	w["slices"] = int(w.get("slices", 0)) + slices
	if not bool(ideology.get("suppressed", false)):
		for _slice in range(16):
			var effect_slice: Dictionary = ext.run_effect_daily(day)
			w["last_effect"] = effect_slice
			if not bool(effect_slice.get("ok", true)):
				break
			if bool(effect_slice.get("done", true)):
				break
		ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		ext.ack_effect_native_modifier()
	var pump := {}
	if bool(w.get("pump", false)):
		pump = _pump_derived(w, day, ATTEMPTS_PER_DAY)
		w["pumped_days"] = int(w.get("pumped_days", 0)) + 1
	var drained: Dictionary = ext.drain_derived_cell_layer(day)
	if bool(ideology.get("suppressed", false)):
		# Under worker authority the day is committed by the worker; wait for it so the
		# mirrored basis dates do not fall behind the calendar the pump is using.
		var before := int(ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_await_pod_day(w, before, _pod_wait_ms)
	_record_day(w, day, pump, drained)
	return {"ok": true, "day": day, "slices": slices, "drained": drained,
		"pump": pump, "suppressed": bool(ideology.get("suppressed", false))}


## Calls the BOUND facade until it reports the rebuild finished, and accounts for every
## call. `economy_day_inflight` is the worker holding the economy-input-capture boundary
## for its own day transaction; the facade has asked it to park, so a short sleep gives
## it the boundary window the next call needs. That is contention, not a failure.
func _pump_derived(w: Dictionary, day: int, attempts: int) -> Dictionary:
	var ext: Object = w["ext"]
	var calls := 0
	var inflight := 0
	var done := false
	var first_lock := false
	var pending := false
	var code := ""
	while calls < attempts:
		calls += 1
		var stepped: Dictionary = ext.step_ideology_derived_rebuild(day)
		code = String(stepped.get("code", ""))
		if code == INFLIGHT_CODE:
			inflight += 1
			OS.delay_msec(ATTEMPT_SLEEP_MS)
			continue
		if calls == 1:
			first_lock = true
		pending = bool(stepped.get("pending", true))
		if bool(stepped.get("done", false)) and not pending:
			done = true
			break
	return {"attempts": calls, "inflight": inflight, "acquired": calls - inflight,
		"done": done, "pending": pending, "first_lock": first_lock, "code": code}


func _record_day(w: Dictionary, day: int, pump: Dictionary, drained: Dictionary) -> void:
	var state := _layer_state(w["ext"])
	var pumped := not pump.is_empty()
	var row := {
		"day": day, "pumped": pumped, "attempts": int(pump.get("attempts", 0)),
		"acquired": int(pump.get("acquired", 0)),
		"inflight": int(pump.get("inflight", 0)),
		"first_lock": bool(pump.get("first_lock", false)),
		"done": bool(pump.get("done", false)),
		"drain_steps": int(drained.get("steps", -1)),
		"installed": bool(state["installed"]),
		"cells": int(state["cell_count"]),
		"contributions": int(state["contribution_count"]),
		"generation": int(state["layer_generation"]),
		"confirmed": int(state["basis_confirmed_day"]),
		"eligible": int(state["basis_eligible_day"]),
		"gated": int(state["gated_by_eligibility"]),
	}
	if pumped:
		print("[PUMP/%s] day=%d calls=%d acquired=%d inflight=%d done=%s "
			% [String(w["name"]), day, int(row["attempts"]), int(row["acquired"]),
				int(row["inflight"]), str(row["done"])]
			+ "drain_steps=%d | installed=%s cells=%d contributions=%d gen=%d "
			% [int(row["drain_steps"]), str(row["installed"]), int(row["cells"]),
				int(row["contributions"]), int(row["generation"])]
			+ "confirmed=%d eligible=%d gated=%d"
			% [int(row["confirmed"]), int(row["eligible"]), int(row["gated"])])
	(w["days"] as Array).append(row)
	if int(w["first_installed_day"]) < 0 and bool(state["installed"]) \
			and int(state["cell_count"]) > 0:
		w["first_installed_day"] = day
		w["confirmed_at_first_install"] = int(state["basis_confirmed_day"])
		w["eligible_at_first_install"] = int(state["basis_eligible_day"])
		print("[%s][LAYER] the derived cell layer is installed for the first time on "
			% String(w["name"])
			+ "day %d: cells=%d contributions=%d generation=%d (confirmed=%d "
			% [day, int(state["cell_count"]), int(state["contribution_count"]),
				int(state["layer_generation"]), int(state["basis_confirmed_day"])]
			+ "eligible=%d)" % int(state["basis_eligible_day"]))


func _print_pump_table(w: Dictionary) -> void:
	var days: Array = w.get("days", [])
	print("[%s][TABLE] day | calls | acquired | inflight | done | drain_steps | "
		% String(w["name"]) + "installed | cells | contributions | gen")
	for row_value in days:
		var row: Dictionary = row_value
		if not bool(row.get("pumped", false)):
			continue
		print("  %3d | %5d | %8d | %8d | %5s | %11d | %9s | %5d | %13d | %3d"
			% [int(row["day"]), int(row["attempts"]), int(row["acquired"]),
				int(row["inflight"]), str(row["done"]), int(row["drain_steps"]),
				str(row["installed"]), int(row["cells"]), int(row["contributions"]),
				int(row["generation"])])


func _await_pod_day(w: Dictionary, before: int, timeout_ms: int) -> int:
	var ext: Object = w["ext"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	var day := before
	while Time.get_ticks_msec() < deadline:
		var report: Dictionary = ext.get_runtime_thread_report()
		day = int(report.get("ideology_pod_committed_day", -1))
		if day > before:
			break
		if String(report.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"]:
			break
		_service_peers(ext, 1)
		OS.delay_msec(2)
	return day


func _has_hard_barrier(clock: Object) -> bool:
	return bool(clock.has_hard_barrier()) if clock.has_method(
		"has_hard_barrier") else false


func _worker_fault(ext: Object) -> String:
	if ext == null or not ext.has_method("get_runtime_thread_report"):
		return ""
	return String(ext.get_runtime_thread_report().get("fault_code", ""))


func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_runtime_thread_report"):
		return 0
	var report: Dictionary = ext.get_runtime_thread_report()
	for key in ["world_day", "ideology_pod_committed_day", "day"]:
		if report.has(key):
			return int(report[key])
	return 0


# =========================================================================
# ideology commands
# =========================================================================
func _submit(w: Dictionary, rows: Array) -> Dictionary:
	var ext: Object = w["ext"]
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	var tick := int(w["tick"])
	for row_value in rows:
		var row: Dictionary = row_value
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", tick)))
		producers.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", w["handle"])))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return ext.submit_ideology_commands({
		"opcodes": opcodes, "effective_days": days, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"source_priorities": priorities, "offer_generations": generations,
		"choice_indices": choices, "gate_ids": gates,
	})


func _dense_id(card: String) -> int:
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	if not bool(native.get("ok", false)):
		return -1
	var wanted := card if card.begins_with("idea.") else "idea.%s" % card
	return PackedStringArray(native.get("ideology_ids",
		PackedStringArray())).find(wanted)


func _equip_card(w: Dictionary, card: String, label: String,
		wait_days: int = 10) -> bool:
	var dense := _dense_id(card)
	_expect("%s: %s is in the compiled ideology catalog" % [label, card], dense >= 0,
		"dense=%d" % dense)
	if dense < 0:
		return false
	var gate: Dictionary = DrawGateHelper.grant_draw_gates(
		w["host"], card, int(w["handle"]), int(w["tick"]), _next_sequence)
	_expect("%s: %s draw gates clear" % [label, card],
		bool(gate.get("ok", false)), str(gate))
	if not bool(gate.get("ok", false)):
		return false
	_next_sequence = maxi(_next_sequence, int(gate.get(
		"next_sequence", _next_sequence)))
	_drive_day(w)
	# The same three-step preamble B1 uses for every card: one point grant, the
	# discover, and a zero-value understanding row.
	var preamble: Dictionary = _submit(w, [
		{"op": OP_GRANT_POINTS, "idea": -1, "value": 64 * Q16_ONE},
		{"op": OP_DISCOVER, "idea": dense},
		{"op": OP_ADD_UNDERSTANDING, "idea": dense, "value": 0},
	])
	_expect("%s: %s grant/discover/understanding accepted" % [label, card],
		bool(preamble.get("ok", false)), str(preamble))
	_drive_days(w, 2)
	var equipped: Dictionary = _submit(w, [{"op": OP_EQUIP, "idea": dense}])
	_expect("%s: %s equip accepted (path from the worker: %s)" % [label, card,
		String(equipped.get("path", ""))], bool(equipped.get("ok", false)),
		str(equipped))
	# The transition settles on a later day; wait for the card to be LIVE rather than
	# assuming a fixed number of days.
	await WorkerWaitHelper.wait_for(
		func() -> bool:
			return _location_of(w, card) == 1,
		wait_days, DAY_WAIT_MS * 2,
		func() -> void:
			_drive_day(w))
	_expect("%s: %s is live (location=1) under worker authority" % [label, card],
		_location_of(w, card) == 1,
		"location=%d last_error='%s'" % [_location_of(w, card),
			String(_snapshot(w).get("last_error", ""))])
	return _location_of(w, card) == 1


func _snapshot(w: Dictionary) -> Dictionary:
	var ext: Object = w["ext"]
	return ext.get_ideology_snapshot(int(w["handle"]))


func _location_of(w: Dictionary, card: String) -> int:
	var dense := _dense_id(card)
	if dense < 0:
		return -1
	var snapshot := _snapshot(w)
	var ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var locations: PackedInt32Array = snapshot.get(
		"locations", PackedInt32Array())
	var pending: PackedByteArray = snapshot.get(
		"transition_pending", PackedByteArray())
	var row := ids.find(dense)
	if row < 0 or row >= locations.size():
		return -1
	if row < pending.size() and int(pending[row]) != 0:
		return -1
	return int(locations[row])


# =========================================================================
# the cell layer: tag fixture, reads, comparison
# =========================================================================
## Pins the two card predicates on the owned land cells and the population metric above
## their thresholds, exactly as `ideology_x6c_worker_test.gd` does for a worker world.
## `refresh_effect_input_digest_for_test()` is what makes the override visible to the
## pod, which resolves selectors against the published input digest.
func _install_selector_fixture(w: Dictionary, label: String) -> void:
	var ext: Object = w["ext"]
	if not ext.has_method("set_cell_tag_override_for_test"):
		return
	var cleared: Dictionary = ext.clear_cell_tag_overrides_for_test()
	_require("%s: prior tag overrides cleared" % label,
		bool(cleared.get("ok", false)), str(cleared))
	var metric := _effect_metric_id("cell.population")
	if metric >= 0:
		var population: Dictionary = ext.set_effect_metric_override_for_test(
			metric, POPULATION_Q16, true)
		_require("%s: cell.population pinned" % label,
			bool(population.get("ok", false)), str(population))
	var cells := _owned_land_cells(w, 8)
	var tagged := 0
	for cell in cells:
		for tag in [TAG_A, TAG_B]:
			var result: Dictionary = ext.set_cell_tag_override_for_test(
				String(tag), int(cell), true)
			if bool(result.get("ok", false)):
				tagged += 1
	print("[SETUP/%s] selector fixture: owned_land_cells=%d tags_set=%d metric=%d"
		% [label, cells.size(), tagged, metric])
	ext.refresh_effect_input_digest_for_test()


func _owned_land_cells(w: Dictionary, limit: int) -> PackedInt32Array:
	var ext: Object = w["ext"]
	var out := PackedInt32Array()
	var map = w["host"].get_current_map() if w["host"].has_method(
		"get_current_map") else null
	for cell in range(int(w["cells"])):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != int(w["handle"]):
			continue
		if map != null and bool(map.is_water_arr[cell]):
			continue
		out.append(cell)
		if out.size() >= limit:
			break
	return out


func _effect_metric_id(metric_key: String) -> int:
	var catalog: Resource = load("res://data/effects/default_effect_catalog.tres")
	if catalog == null:
		return -1
	var compiled: Dictionary = catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return -1
	return PackedStringArray(compiled.get("metric_keys",
		PackedStringArray())).find(metric_key)


func _layer_state(ext: Object) -> Dictionary:
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var ideology: Dictionary = ext.get_ideology_report()
	return {
		"installed": bool(layer.get("installed", false)),
		"cell_count": int(layer.get("cell_count", -1)),
		"contribution_count": int(layer.get("contribution_count", -1)),
		"stat_count": int(layer.get("stat_count", -1)),
		"layer_generation": int(layer.get("layer_generation", -1)),
		"sample_day": int(layer.get("sample_day", -1)),
		"cell_layer_rebuild_visits": int(ideology.get(
			"cell_layer_rebuild_visits", -1)),
		"derived_rebuild_pending": bool(ideology.get(
			"derived_rebuild_pending", false)),
		"basis_confirmed_day": int(ideology.get(
			"derived_basis_confirmed_day", -1)),
		"basis_eligible_day": int(ideology.get(
			"derived_basis_eligible_day", -1)),
		"gated_by_eligibility": int(ideology.get(
			"derived_rebuild_gated_by_eligibility", -1)),
	}


## The production read shape: entity_handle 0 with the CELL in the group slot, the pair
## `economy_runtime_family_buff.cpp` passes.
func _probe_all_cells(ext: Object, stat: String, cells: int) -> Dictionary:
	var present := PackedByteArray()
	present.resize(cells)
	var add := PackedFloat64Array()
	add.resize(cells)
	var value := PackedFloat64Array()
	value.resize(cells)
	var covered := 0
	var add_sum := 0.0
	for cell in range(cells):
		var probe: Dictionary = ext.get_effective_stat_value(stat, cell, 0, 1.0)
		if not bool(probe.get("ok", false)):
			continue
		present[cell] = 1 if bool(probe.get("derived_present", false)) else 0
		add[cell] = float(probe.get("derived_add", 0.0))
		value[cell] = float(probe.get("value", 1.0))
		if present[cell] != 0:
			covered += 1
			add_sum += add[cell]
	return {"present": present, "add": add, "value": value,
		"covered": covered, "add_sum": add_sum}


func _compare_probes(a: Dictionary, b: Dictionary) -> Dictionary:
	var cells := 0
	var presence_mismatch := 0
	var add_mismatch := 0
	var value_mismatch := 0
	var max_add_diff := 0.0
	var max_value_diff := 0.0
	var present_a: PackedByteArray = a["present"]
	var present_b: PackedByteArray = b["present"]
	var add_a: PackedFloat64Array = a["add"]
	var add_b: PackedFloat64Array = b["add"]
	var value_a: PackedFloat64Array = a["value"]
	var value_b: PackedFloat64Array = b["value"]
	for cell in range(mini(present_a.size(), present_b.size())):
		cells += 1
		if int(present_a[cell]) != int(present_b[cell]):
			presence_mismatch += 1
		var add_diff: float = absf(float(add_a[cell]) - float(add_b[cell]))
		if add_diff != 0.0:
			add_mismatch += 1
			max_add_diff = maxf(max_add_diff, add_diff)
		var value_diff: float = absf(float(value_a[cell]) - float(value_b[cell]))
		if value_diff != 0.0:
			value_mismatch += 1
			max_value_diff = maxf(max_value_diff, value_diff)
	return {"cells": cells, "presence_mismatch": presence_mismatch,
		"add_mismatch": add_mismatch, "value_mismatch": value_mismatch,
		"max_abs_add_diff": max_add_diff, "max_abs_value_diff": max_value_diff}


func _program_magnitude(w: Dictionary, program_key: String, label: String) -> int:
	var metrics := PackedInt64Array()
	metrics.resize(120)
	metrics.fill(0)
	var result: Dictionary = w["ext"].evaluate_effect_program_magnitude(
		program_key, metrics)
	_expect("%s: %s evaluates against the catalog" % [label, program_key],
		bool(result.get("ok", false)), str(result))
	return int(result.get("magnitude", 0))


# =========================================================================
# teardown + assertions
# =========================================================================
func _teardown_all() -> void:
	for index in range(_worlds.size() - 1, -1, -1):
		var w: Dictionary = _worlds[index]
		var ext: Object = w.get("ext", null)
		if ext != null and ext.has_method("request_runtime_stop"):
			ext.request_runtime_stop()
		var host: Object = w.get("host", null)
		if host != null and is_instance_valid(host):
			host.queue_free()
		var clock: Object = w.get("clock", null)
		if clock != null and is_instance_valid(clock):
			clock.queue_free()
	_worlds.clear()


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("[PASS] " + label)
		return
	_failures += 1
	printerr("[FAIL] " + label
		+ ((" :: " + detail) if not detail.is_empty() else ""))


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _fail(label: String) -> void:
	_expect(label, false)
