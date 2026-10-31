extends SceneTree
## Minimal probe: does a GLOBAL-scope ECONOMY modifier row reach the GLOBAL key?
##
## WHY THIS FILE EXISTS
##
## `ideology_cell_layer_numeric_test.gd` could not assert the GLOBAL scope: a row
## submitted with `scopes=[0]` did not change the evaluated value, while the same
## shape with `scopes=[1]` (GROUP) did. Two rounds of investigation did not find
## why, and the numeric fixture now declares that it does NOT cover GLOBAL.
##
## This probe narrows the question to one submit and one read, with the store's
## own `report()` as the witness -- `scopes` and `handles` are separate columns
## there, so the stored scope is directly observable instead of inferred from a
## value that could be wrong for unrelated reasons.
##
## WHAT IT SETTLES
##
##   * whether the row is stored with scope 0 at all;
##   * whether a stored GLOBAL row is visible to `effective_value`;
##   * therefore whether the numeric fixture's gap is a FIXTURE bug or a PRODUCT bug.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_global_scope_probe.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")

const CELLS := 64
const STAT := "economy.city.birth_factor"
const DOMAIN_ECONOMY := 2

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	catalog.erase("ok")
	ext.configure_modifiers(catalog, CELLS)
	var stat_id := int(ext.resolve_modifier_stat(STAT).get("stat_id", -1))
	print("[global] stat_id=%d" % stat_id)

	# ── the GLOBAL submit, verbatim ────────────────────────────────────────
	var submit: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([-1]),
		"definition_keys": PackedStringArray([STAT]),
		"domains": PackedInt32Array([DOMAIN_ECONOMY]),
		"scopes": PackedInt32Array([0]),          # GLOBAL
		"entity_handles": PackedInt64Array([0]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([2]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([int(round(2.0 * 65536.0))]),
		"modifier_handles": PackedInt64Array([0]),
	})
	print("[global] submit=%s" % str(submit))
	var drained: Dictionary = ext.run_modifier_daily(0)
	print("[global] drain=%s" % str(drained))

	# `get_modifier_report()` has NO `scopes`/`handles` columns -- those belong to
	# `explain_modifier_stat()`. An earlier version of this probe asserted on the
	# report and failed with empty arrays, which looked like "the row was not
	# stored" when the truth was "wrong accessor". Reading `explain` is the fix.
	var report: Dictionary = ext.get_modifier_report()
	print("[global] report bucket_count_by_domain=%s"
		% str(report.get("bucket_count_by_domain", "?")))

	var explanation: Dictionary = ext.explain_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	print("[global] explain scopes=%s handles=%s sum_add=%s"
		% [str(explanation.get("scopes", "?")),
			str(explanation.get("handles", "?")),
			str(explanation.get("sum_add", "?"))])

	var scopes: PackedInt32Array = explanation.get("scopes", PackedInt32Array())
	_expect("the row is stored", scopes.size() > 0, str(scopes))
	if scopes.size() > 0:
		_expect("the stored scope is GLOBAL (0)",
			int(scopes[0]) == 0,
			"stored %d, submitted 0 -- a mismatch here is a command-path bug"
				% int(scopes[0]))

	# And the read: base 1.0 plus a GLOBAL add of 2.0 must be 3.0.
	var value: float = ext.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	print("[global] evaluated at cell 7 = %s" % str(value))
	if scopes.size() > 0 and int(scopes[0]) == 0:
		# The row IS stored as GLOBAL, so the read must see it. Failing here means
		# `effective_value` does not look up the GLOBAL key -- a product bug that
		# would affect every GLOBAL modifier, not just the derived layer.
		_expect("a stored GLOBAL row is visible to effective_value",
			absf(value - 3.0) < 1e-4,
			"got %s expected 3.0 -- the row is stored as GLOBAL, so the read is "
				% str(value) + "dropping it")
	else:
		print("[global] scope mismatch: the read assertion is skipped because the "
			+ "row is not stored as GLOBAL")

	# Control: the same shape with GROUP must work, which isolates the variable.
	var ext2: Object = ClassDB.instantiate("DCWorldExt")
	ext2.configure_modifiers(catalog, CELLS)
	ext2.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([-1]),
		"definition_keys": PackedStringArray([STAT]),
		"domains": PackedInt32Array([DOMAIN_ECONOMY]),
		"scopes": PackedInt32Array([1]),          # GROUP
		"entity_handles": PackedInt64Array([0]),
		"group_handles": PackedInt64Array([7]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([2]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([int(round(2.0 * 65536.0))]),
		"modifier_handles": PackedInt64Array([0]),
	})
	ext2.run_modifier_daily(0)
	var control: float = ext2.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	print("[global] GROUP control at cell 7 = %s" % str(control))
	_expect("the GROUP control works (isolates the variable)",
		absf(control - 3.0) < 1e-4, str(control))

	# ── magnitude clamp: does an oversized add survive? ────────────────────
	# `magnitude_q16` is clamped to [0, MAX_MAGNITUDE_Q16] before it is applied, so
	# an add of 100 becomes MAX, not 100. That is by design, but it means a test
	# that expects "a huge add lands on the stat ceiling" only holds if MAX is
	# itself at or above the ceiling.
	var ext3: Object = ClassDB.instantiate("DCWorldExt")
	ext3.configure_modifiers(catalog, CELLS)
	var big_submit: Dictionary = ext3.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([-1]),
		"definition_keys": PackedStringArray([STAT]),
		"domains": PackedInt32Array([DOMAIN_ECONOMY]),
		"scopes": PackedInt32Array([0]),          # GLOBAL
		"entity_handles": PackedInt64Array([0]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([2]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([int(round(100.0 * 65536.0))]),
		"modifier_handles": PackedInt64Array([0]),
	})
	ext3.run_modifier_daily(0)
	var big_value: float = ext3.evaluate_modifier_stat(
		DOMAIN_ECONOMY, 0, 7, STAT, 1.0)
	print("[global] oversized add 100 -> value=%s submit_ok=%s"
		% [str(big_value), str(big_submit.get("ok", false))])
	print("[global] oversized drain commands_applied=%s reject_events=%s"
		% [str(ext3.get_modifier_report().get("commands_applied_total", "?")),
			str(ext3.get_modifier_report().get("reject_events_by_domain", "?"))])
	# MEASURED BEHAVIOUR, not a wish: an oversized magnitude is REJECTED, not
	# clamped. The first version of this probe asserted "the value must move",
	# which failed and looked like a bug -- it is not. `magnitude_q16` above
	# `MAX_MAGNITUDE_Q16` fails validation, so the command never applies and the
	# value legitimately stays at the base.
	var reject_events: PackedInt64Array = ext3.get_modifier_report().get(
		"reject_events_by_domain", PackedInt64Array())
	var rejected := reject_events.size() > DOMAIN_ECONOMY \
		and int(reject_events[DOMAIN_ECONOMY]) > 0
	_expect("an oversized magnitude is REJECTED, not silently clamped",
		rejected, "reject_events=%s" % str(reject_events))
	_expect("and the value therefore stays at the base",
		absf(big_value - 1.0) < 1e-4, str(big_value))

	_finish(0 if _failures == 0 else 3)


func _finish(code: int) -> void:
	print("=== global scope probe: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
