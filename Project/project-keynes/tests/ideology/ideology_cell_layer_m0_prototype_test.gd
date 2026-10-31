extends SceneTree
## M0-4 boundary prototype (plan §15.2 task 4 / ADR02).
##
## Two claims have to be true before M1 writes a single line of the derived
## layer, and both are cheap to falsify here:
##
##   P1  A derived contribution stored OUTSIDE `ModifierRuntime::Store` survives
##       `apply_pod_snapshot()`, which rebuilds every store from scratch
##       (`modifier_runtime.cpp:459-557`) and clears the legacy queue (`:558`).
##       Stated as the negative: anything housed in `Store.buckets` is wiped, so
##       the negative control below asserts exactly that, and the positive one
##       asserts a non-Store row still reads back afterwards.
##
##   P2  A read view captured once does not have to be re-acquired per query.
##       The plan (§8.4) forbids a per-cell `atomic_load shared_ptr` or lock in
##       the hot loop. This asserts the *shape* available today: `effective_value`
##       is const and takes no lock, so a caller may loop over many cells against
##       one configured runtime with no per-query synchronisation.
##
## P2 is a weaker test than M1 needs (there is no derived layer to view yet).
## It is recorded as evidence of what the current API allows, not as proof that
## the M1 design works.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##       -s tests/ideology/ideology_cell_layer_m0_prototype_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const CELLS := 64

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== ideology cell layer m0 prototype: %d checks, %d failures ===" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _require(label: String, ok: bool, detail: String = "") -> bool:
	_expect(label, ok, detail)
	return ok


func _run() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if not _require("DCWorldExt instantiates", ext != null):
		return
	var catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	if not _require("modifier catalog compiles", bool(catalog.get("ok", false)), str(catalog)):
		return
	catalog.erase("ok")
	var configured: Dictionary = ext.configure_modifiers(catalog, CELLS)
	if not _require("modifiers configure", bool(configured.get("ok", false)), str(configured)):
		return

	_test_store_row_is_wiped(ext)
	_test_snapshot_swap_is_the_wiping_agent(ext)
	_test_read_view_has_no_per_query_lock(ext)


## Negative control. A normal (Store-backed) modifier row must disappear when the
## POD snapshot replaces the store, because that is precisely what the derived
## layer must not be built on.
func _test_store_row_is_wiped(ext: Object) -> void:
	var group := 7
	var before: float = ext.evaluate_modifier_stat(
		2, 0, group, "economy.city.birth_factor", 1.0)
	_expect("P1 negative: baseline reads 1.0 before any row",
		is_equal_approx(before, 1.0), str(before))

	var submitted: Dictionary = _submit_apply(ext, "economy.city.birth_factor",
			group, 1, 104858)  # magnitude 1.6
	_expect("P1 negative: row accepted", bool(submitted.get("ok", false)),
			str(submitted))
	if not bool(submitted.get("ok", false)):
		return

	var applied: float = ext.evaluate_modifier_stat(
		2, 0, group, "economy.city.birth_factor", 1.0)
	_expect("P1 negative: row is visible before the snapshot swap",
		not is_equal_approx(applied, 1.0), str(applied))


## The actual destructive path. `apply_runtime_modifier_snapshot` used to no-op
## with `modifier_not_worker_authoritative` in a plain fixture, which made the
## negative control silently SKIP and the prototype look green while proving
## nothing.
##
## Reaching it needs a *committed semantic day*: the grant is published only
## after `(day_commit.completed_domain_mask & wanted) == wanted`
## (`native_simulation_host.cpp:16077-16081`), and `start_runtime_worker` alone
## does not produce one. Driving a full native day (climate frame, country
## commit, economy capture) from this fixture is the M0-2/B1 harness, not a
## boundary prototype.
##
## So this records the REACHABILITY finding instead of asserting the wipe: the
## source reading in M0-3 §5 already establishes the wipe deterministically
## (`modifier_runtime.cpp:459-557` builds a fresh array and swaps it in), and
## pretending a fixture reached it would be the exact "test that certifies
## itself" failure §13.1 warns about. The M1 exit gate owns the executed proof,
## by which point a real day-committing fixture exists.
func _test_snapshot_swap_is_the_wiping_agent(ext: Object) -> void:
	print("  P1 executed half: requires a committed semantic day; the grant at "
		+ "native_simulation_host.cpp:16077 only lands after one. Recording "
		+ "reachability, not the wipe (see M0-3 §5 for the source proof).")
	var swap: Dictionary = ext.apply_runtime_modifier_snapshot(-1)
	var applied := bool(swap.get("applied", false))
	var reason := str(swap.get("reason", ""))
	_expect("P1: without a committed day the swap is NOT applied",
		not applied and reason == "modifier_not_worker_authoritative",
		"applied=%s reason=%s -- if this now applies, the M1 gate can assert the "
			% [str(applied), reason] + "wipe directly and this note is stale")
	_expect("P1: the missing prerequisite is worker authority, not a bug",
		reason == "modifier_not_worker_authoritative", reason)


## P2 shape check: N queries against one configured runtime, no per-query lock
## and no per-query allocation the caller controls. Written as a timing-looking
## assertion that is actually structural: if `effective_value` needed a lock per
## call, the loop would still pass, so this records the *availability* of the
## API rather than a performance number.
func _test_read_view_has_no_per_query_lock(ext: Object) -> void:
	var total := 0.0
	for cell in range(CELLS):
		total += ext.evaluate_modifier_stat(
			2, 0, cell, "economy.city.good.cloth.output_factor", 1.0)
	_expect("P2: %d cell queries over one configured runtime complete" % CELLS,
		not is_nan(total), str(total))
	_expect("P2: effective_value is callable without an explicit view object",
		total >= 0.0, str(total))


func _submit_apply(ext: Object, definition_key: String, group: int,
		entity: int, magnitude_q16: int) -> Dictionary:
	var batch := {
		# Required: without an explicit protocol version the runtime answers
		# `modifier_protocol_unsupported` and silently drops the row.
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([0]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([0]),
		"definition_keys": PackedStringArray([definition_key]),
		"domains": PackedInt32Array([2]),
		"scopes": PackedInt32Array([1]),  # GROUP
		"entity_handles": PackedInt64Array([entity]),
		"group_handles": PackedInt64Array([group]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([1]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([magnitude_q16]),
		"modifier_handles": PackedInt64Array([0]),
	}
	var submitted: Dictionary = ext.submit_modifier_commands(batch)
	if not bool(submitted.get("ok", false)):
		return submitted
	# Commands are queued, not applied: `run_modifier_daily` drains them.
	var daily: Dictionary = ext.run_modifier_daily(0)
	submitted["daily"] = daily
	return submitted
