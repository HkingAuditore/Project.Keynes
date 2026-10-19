extends SceneTree

# M2a step 4 gate: `submit_effect_instances` / `retire_effect_instance` were
# collapsed into EffectInstanceForwarder. This fixture pins the LEGACY
# (non-worker-authoritative) contract so the refactor cannot quietly change what
# callers already depend on:
#
#   - both entry points report effect_runtime_unavailable before configure
#   - a legacy submit still returns EffectRuntime's dictionary shape, still
#     carries no "path" key, and still best-effort mirrors into the worker
#     transport (the mirror was folded into the forwarder, not deleted)
#   - the declarative rule from effect_declarative_validation.h is applied on
#     this path exactly once (managed program + wrong source_kinds is rejected)
#   - retire keeps the main-thread semantics: a missing instance is success
#
# The WORKER-authoritative path needs a granted EFFECT bit (0x020), which needs
# the full upstream authority chain. That is covered by
# tests/ideology_effect_worker_forward_test.gd (M2a step 6), not here.

var _checks := 0
var _failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		_finish()
		return
	var ext := DCWorldExt.new()

	# --- 0. Pre-configure: the guard must still say "runtime unavailable" -----
	var early: Dictionary = ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([1]),
		"program_keys": PackedStringArray(["effect.none"]),
	})
	_expect("submit before configure reports effect_runtime_unavailable",
		not bool(early.get("ok", true)) and
		str(early.get("reason", "")) == "effect_runtime_unavailable")
	var early_retire: Dictionary = ext.retire_effect_instance(1, 1, 0)
	_expect("retire before configure reports effect_runtime_unavailable",
		not bool(early_retire.get("ok", true)) and
		str(early_retire.get("reason", "")) == "effect_runtime_unavailable")

	# --- 1. Configure the production Effect catalog ---------------------------
	var catalog := preload("res://scripts/effect/effect_domain_catalog.gd").build()
	_expect("Effect catalog builds", catalog != null)
	if catalog == null:
		_finish()
		return
	var native: Dictionary = catalog.compile_native_catalog()
	var configured: Dictionary = ext.configure_effects(native)
	_expect("Effect catalog configures",
		bool(configured.get("ok", false)) and
		bool(configured.get("effect_pod_ready", false)))
	if not bool(configured.get("ok", false)):
		_finish()
		return

	var keys: PackedStringArray = native.get("effect_keys", PackedStringArray())
	var kinds: PackedInt32Array = native.get("source_kinds", PackedInt32Array())
	var managed: PackedByteArray = native.get("managed_flags", PackedByteArray())
	var expressible: PackedByteArray = native.get("pod_expressible",
		PackedByteArray())
	# A plain (non-managed) POD-expressible program: the legacy writer accepts it
	# and the mirror can carry it, so a mirror count of 0 would be a real
	# regression rather than "this program is not pod expressible".
	var plain_index := -1
	var managed_index := -1
	for i in range(keys.size()):
		var is_managed := managed.size() > i and managed[i] == 1
		var is_expressible := expressible.size() > i and expressible[i] == 1
		if is_managed and managed_index < 0:
			managed_index = i
		if not is_managed and is_expressible and plain_index < 0:
			plain_index = i
	_expect("catalog exposes at least one pod-expressible unmanaged program",
		plain_index >= 0)
	if plain_index < 0:
		_finish()
		return

	# --- 2. Legacy submit keeps the pre-M2a shape ----------------------------
	var batch := _legacy_batch(77001, keys[plain_index], 1, true)
	var submitted: Dictionary = ext.submit_effect_instances(batch)
	if not bool(submitted.get("ok", false)):
		print("[effect-forwarder] legacy submit rejected: %s" % submitted)
	_expect("legacy submit reports ok", bool(submitted.get("ok", false)))
	_expect("legacy submit carries no EFFECT_WORKER path marker",
		not submitted.has("path"))
	_expect("legacy submit returns the accepted instance id",
		PackedInt64Array(submitted.get("instance_ids", PackedInt64Array())).size() == 1 and
		int(PackedInt64Array(submitted.get("instance_ids",
			PackedInt64Array()))[0]) == 77001)
	# The F7 SHADOW mirror used to be a second hand-written copy of the batch
	# parser. It is now fed from the forwarder, which is only correct if it is
	# still there and still queues.
	_expect("legacy submit still mirrors into the worker transport",
		submitted.has("effect_pod_mirrored") and
		int(submitted.get("effect_pod_mirrored", 0)) == 1)

	# --- 3. Re-submitting the same identity is idempotent -------------------
	var again: Dictionary = ext.submit_effect_instances(
		_legacy_batch(77001, keys[plain_index], 3, true))
	_expect("legacy resubmit of the same identity is accepted",
		bool(again.get("ok", false)))
	_expect("legacy resubmit still mirrors", 
		int(again.get("effect_pod_mirrored", 0)) == 1)

	# NOTE on return shapes, which differ by path and always have:
	#   legacy  -> ok == true means "the batch was processed"; per-row refusals
	#              show up as rejected > 0 with an empty instance_ids, and no
	#              reason token is surfaced.
	#   worker  -> ok == false as soon as one row is refused (pre-M2a behaviour),
	#              with a reason token.
	# The forwarder preserves each path's shape; only the validation RULE is now
	# shared. Asserting ok == false on the legacy path would be wrong.

	# --- 4. Unknown program is rejected on the legacy path ------------------
	var unknown: Dictionary = ext.submit_effect_instances(
		_legacy_batch(77002, "effect.program_missing", 1, true))
	_expect("legacy submit refuses an unknown program key",
		bool(unknown.get("ok", false)) and
		int(unknown.get("rejected", 0)) == 1 and
		PackedInt64Array(unknown.get("instance_ids", PackedInt64Array())).is_empty())

	# --- 5. The declarative rule is applied exactly once --------------------
	# Managed programs must declare their own source kind and must retire
	# through retire_effect_instance instead of submitting active=false.
	if managed_index >= 0:
		var wrong_kind := _legacy_batch(77003, keys[managed_index], 1, true)
		wrong_kind["source_kinds"] = PackedInt32Array([int(kinds[managed_index]) + 1])
		var mismatched: Dictionary = ext.submit_effect_instances(wrong_kind)
		_expect("legacy submit refuses a managed program with the wrong source kind",
			int(mismatched.get("rejected", 0)) == 1 and
			PackedInt64Array(mismatched.get("instance_ids",
				PackedInt64Array())).is_empty())

		var deactivate := _legacy_batch(77004, keys[managed_index], 1, false)
		deactivate["source_kinds"] = PackedInt32Array([int(kinds[managed_index])])
		var retired_inline: Dictionary = ext.submit_effect_instances(deactivate)
		_expect("legacy submit refuses to deactivate a managed program inline",
			int(retired_inline.get("rejected", 0)) == 1 and
			PackedInt64Array(retired_inline.get("instance_ids",
				PackedInt64Array())).is_empty())

		# Control: the same row with the right kind is accepted, so the two
		# refusals above are the rule firing and not the fixture being broken.
		var right_kind := _legacy_batch(77005, keys[managed_index], 1, true)
		right_kind["source_kinds"] = PackedInt32Array([int(kinds[managed_index])])
		var accepted_managed: Dictionary = ext.submit_effect_instances(right_kind)
		_expect("legacy submit accepts the same managed program with the right kind",
			int(accepted_managed.get("rejected", 0)) == 0 and
			PackedInt64Array(accepted_managed.get("instance_ids",
				PackedInt64Array())).size() == 1)
	else:
		print("[effect-forwarder] no managed program in the catalog; \
skipping the declarative-rule cases")

	# --- 6. Retire keeps main-thread semantics ------------------------------
	var retired: Dictionary = ext.retire_effect_instance(77001, 1, 0)
	_expect("legacy retire of a live instance succeeds",
		bool(retired.get("ok", false)) and retired.has("effect_pod_mirrored"))
	var missing: Dictionary = ext.retire_effect_instance(999999, 1, 0)
	_expect("legacy retire of a missing instance is a no-op success",
		bool(missing.get("ok", true)))
	var stale_gen: Dictionary = ext.retire_effect_instance(77001, 99, 0)
	_expect("legacy retire with a stale generation is rejected",
		not bool(stale_gen.get("ok", true)))

	_finish()

func _legacy_batch(instance_id: int, program_key: String, level: int,
		active: bool) -> Dictionary:
	var batch := {}
	batch["instance_ids"] = PackedInt64Array([instance_id])
	batch["program_keys"] = PackedStringArray([program_key])
	batch["generations"] = PackedInt32Array([1])
	batch["source_types"] = PackedInt32Array([0])
	batch["source_ids"] = PackedInt64Array([7])
	batch["source_handles"] = PackedInt64Array([7])
	batch["target_handles"] = PackedInt64Array([4242])
	batch["target_generations"] = PackedInt32Array([1])
	batch["levels"] = PackedInt32Array([level])
	batch["next_due_days"] = PackedInt64Array([0])
	batch["active"] = PackedByteArray([1 if active else 0])
	return batch

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)

func _finish() -> void:
	print("=== runtime Effect forwarder: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)
