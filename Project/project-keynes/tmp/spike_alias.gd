@tool
extends EditorScript

# ─── Phase 3a Step 0: alias spike ────────────────────────────────────────
# Goal: figure out whether C++ side can mutate a PackedFloat32Array and have
# the GDScript side (the property owner) see the new value, without going
# through one explicit set() per write.
#
# The three variants (defined in world_ext.cpp) test:
#   v1 : naive          — get; set; ptrw-write
#   v2 : release        — get; set; drop ref; re-get; ptrw-write
#   v3 : write-then-set — get; ptrw-write; set
#
# Expected (per Godot's documented PackedArray CoW semantics):
#   v1 : FAIL   — ptrw() detaches because refcount > 1 at write time
#   v2 : FAIL   — same; just having a local PackedArray means refcount > 1
#   v3 : PASS   — ptrw() detaches into a brand-new buffer that is then
#                 explicitly pushed back via set(); GDScript ends up with
#                 the new buffer.
#
# Decision logic for Step 1 (bind_map_data alias strategy):
#   - if v3 PASS and v1/v2 FAIL  → use "write-then-set per hot loop pass"
#       (C++ does its tight loop on its private copy, then issues 1 set per
#        mutated array at end; cost ≈ 21 × set-op for full Pass-A regen).
#   - if v1 or v2 PASS           → cheaper alias possible; revisit Step 1.
#   - if all FAIL                → route A is dead, escalate.

class FakeMap:
	var temp_arr: PackedFloat32Array = PackedFloat32Array()

	func _init() -> void:
		temp_arr.resize(8)
		for i in range(8):
			temp_arr[i] = float(i)


func _check(label: String, fake: FakeMap, idx: int, sentinel: float, returned: float) -> void:
	# `returned` is what the C++ side read AFTER its mutation, via obj.get(prop)[idx].
	# `fake.temp_arr[idx]` is what the GDScript side sees right now.
	var script_side := fake.temp_arr[idx]
	var cpp_returned_ok := is_equal_approx(returned, sentinel)
	var script_side_ok := is_equal_approx(script_side, sentinel)
	var verdict: String
	if cpp_returned_ok and script_side_ok:
		verdict = "PASS"
	elif cpp_returned_ok and not script_side_ok:
		verdict = "PARTIAL (cpp re-read OK but GDScript-direct stale — should not happen)"
	else:
		verdict = "FAIL (CoW detached; GDScript still sees old value)"
	print("  ", label,
		"  sentinel=", sentinel,
		"  cpp_returned=", returned,
		"  gdscript_direct=", script_side,
		"  -> ", verdict)


func _run() -> void:
	print("=== DCWorldExt alias spike (Phase 3a Step 0) ===")
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt NOT registered — extension load failed silently.")
		return
	var w: Object = ClassDB.instantiate("DCWorldExt")
	if w == null:
		push_error("DCWorldExt instantiation failed")
		return

	# --- v1: naive ---
	var fake1 := FakeMap.new()
	var ret1: float = w._spike_alias_v1_naive(fake1, "temp_arr", 3, 111.0)
	_check("v1 naive          ", fake1, 3, 111.0, ret1)

	# --- v2: release ---
	var fake2 := FakeMap.new()
	var ret2: float = w._spike_alias_v2_release(fake2, "temp_arr", 3, 222.0)
	_check("v2 release        ", fake2, 3, 222.0, ret2)

	# --- v3: write-then-set ---
	var fake3 := FakeMap.new()
	var ret3: float = w._spike_alias_v3_write_then_set(fake3, "temp_arr", 3, 333.0)
	_check("v3 write-then-set ", fake3, 3, 333.0, ret3)

	# --- multi-write follow-up: under v3, can we issue many ptrw writes
	# inside one C++ call and then a single set at the end? That's the actual
	# pattern Step 1 needs (Pass-A writes ~2400 cells, ONE set per array). ---
	# The single-write ret3 result already proves this if PASS — keeping the
	# table separate aids triage if results split.

	print("=== Spike summary ===")
	print("  Decision rule:")
	print("    v3 PASS only           -> Step 1 uses 'write-then-set per hot loop pass'")
	print("    v1 or v2 also PASS     -> cheaper alias is available, revisit Step 1 design")
	print("    all FAIL               -> route A dead, escalate")
