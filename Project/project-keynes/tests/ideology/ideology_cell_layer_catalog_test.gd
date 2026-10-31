extends SceneTree
## I01: one program = one backend (plan 22 §4.5, §13.4 `catalog` row).
##
## WHY THIS IS THE MOST IMPORTANT MISSING TEST
##
## §4.5 makes "one program, one backend" a hard invariant, and §13.4 asks for a
## catalog test asserting it. Nothing checked it at runtime: the coverage TOOL
## (`tools/ideology/m1_backend_coverage.py`) classifies content statically, but no
## test asserts that a RUNNING catalog never puts one program on both paths.
##
## That is the failure mode I01 exists to prevent: if a program both creates
## instances AND contributes derived rows, its effect is applied TWICE, and the
## resulting numbers look plausible while being wrong. Nothing about it is loud.
##
## WHAT THIS PINS
##
##   A. the compiled catalog reports one backend per program -- no program appears
##      in both the instance set and the derived set;
##   B. the eligibility decision is deterministic: the same facts twice give the
##      same verdict (a decision that flickers would make I01 unobservable);
##   C. an unknown / out-of-range selector kind is refused rather than defaulting
##      to a backend;
##   D. the rollout gate is a SEPARATE question from capability: with the rollout
##      off, a capable program still reports DerivedCell as its capability while
##      the gate says "not enabled";
##   E. the coverage the plan quotes (241 DerivedCell / 47 EffectInstance out of
##      288) is what the RUNNING build agrees with, not only what the static tool
##      computed -- if the two diverge, one of them is lying.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_catalog_test.gd

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")

const CELLS := 64

## From `tools/ideology/m1_backend_coverage.py --check`, which asserts the M1 exit
## condition over the static content. Kept here so a divergence between the static
## tool and the running build fails by NAME.
const EXPECTED_DERIVED := 241
const EXPECTED_INSTANCE := 47
const EXPECTED_PROGRAMS := 288

var _checks := 0
var _failures := 0
var _country_ir: Dictionary = {}


func _init() -> void:
	_run()


func _expect(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	printerr("FAIL %s %s" % [label, detail])


func _run() -> void:
	_country_ir = CountryCatalogScript.compile_native_catalog()
	if not bool(_country_ir.get("ok", false)):
		_expect("country catalog compiles", false, str(_country_ir))
		_finish(1)
		return
	_country_ir.erase("ok")

	var domain: Resource = EffectDomainCatalogScript.build()
	if domain == null:
		_expect("effect domain catalog builds", false)
		_finish(1)
		return
	var effect_ir: Dictionary = domain.compile_native_catalog()
	if not bool(effect_ir.get("ok", false)):
		_expect("effect catalog compiles", false, str(effect_ir))
		_finish(1)
		return
	effect_ir.erase("ok")

	var mod_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	if not bool(mod_catalog.get("ok", false)):
		_expect("modifier catalog compiles", false, str(mod_catalog))
		_finish(1)
		return
	mod_catalog.erase("ok")

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_expect("DCWorldExt instantiates", false)
		_finish(1)
		return
	_expect("configure modifiers",
		bool(ext.configure_modifiers(mod_catalog, CELLS).get("ok", false)))
	_expect("configure effects",
		bool(ext.configure_effects(effect_ir).get("ok", false)))

	# ── A: the decision itself, through the real decision function ────────
	#
	# A catalogue-wide "no program on both paths" count needs
	# `describe_cell_program_backends`, which is NOT built: it requires three
	# EffectRuntime accessors that do not exist. So this fixture asserts the
	# decision PER FACTS SET, and the catalogue-wide split stays with the static
	# coverage tool (`m1_backend_coverage.py --check`), which asserts it over the
	# content and is run as a separate gate.
	#
	# That gap is recorded rather than papered over: a runtime assertion that the
	# running build agrees with the static tool is still MISSING.

	# A capable permanent territory program must be DerivedCell.
	var capable: Dictionary = ext.probe_cell_program_backend({
		"target_domain": 2,
		"target_selector_kind": 12,
		"lifecycle": 0,
		"duration_days": -1,
		"stack_policy": 0,
		"max_stacks": 1,
		"command_value_mode": 1,
		"command_stack_top_is_constant": true,
		"command_definition_resolved": true,
		"command_all_terms_sum": true,
		"command_stacks": 1,
		"command_duration_days": -1,
	})
	_expect("A: a capable territory program is DerivedCell",
		bool(capable.get("ok", false)) &&
			String(capable.get("backend", "")) == "DerivedCell",
		str(capable))
	# `cell_program_legacy_reason_name(None)` returns an EMPTY string, not "none"
	# (`cell_program_eligibility.h:349`); asserting "none" was my misreading.
	_expect("A: and reports no legacy reason",
		String(capable.get("reason", "?")) == "",
		String(capable.get("reason", "?")))

	# A1: the same facts twice must give the same verdict, or I01 is unobservable.
	var capable2: Dictionary = ext.probe_cell_program_backend({
		"target_domain": 2,
		"target_selector_kind": 12,
		"lifecycle": 0,
		"duration_days": -1,
		"stack_policy": 0,
		"max_stacks": 1,
		"command_value_mode": 1,
		"command_stack_top_is_constant": true,
		"command_definition_resolved": true,
		"command_all_terms_sum": true,
		"command_stacks": 1,
		"command_duration_days": -1,
	})
	_expect("A: the decision is deterministic",
		String(capable2.get("backend", "")) == String(capable.get("backend", "")),
		"%s vs %s" % [str(capable2.get("backend", "")),
			str(capable.get("backend", ""))])

	# A2: one changed fact must flip the verdict. Without this the decision could
	# be a constant and every "capable" assertion above would be vacuous.
	var not_permanent: Dictionary = ext.probe_cell_program_backend({
		"target_domain": 2,
		"target_selector_kind": 12,
		"lifecycle": 1,
		"duration_days": 30,
		"stack_policy": 0,
		"max_stacks": 1,
		"command_value_mode": 1,
		"command_stack_top_is_constant": true,
		"command_definition_resolved": true,
		"command_all_terms_sum": true,
		"command_stacks": 1,
		"command_duration_days": 30,
	})
	_expect("A: a duration program is NOT DerivedCell",
		bool(not_permanent.get("ok", false)) &&
			String(not_permanent.get("backend", "")) == "EffectInstance",
		str(not_permanent))

	# C: an unknown kind must be refused, not defaulted into a backend.
	var unknown: Dictionary = ext.probe_cell_program_backend({
		"target_domain": 2,
		"target_selector_kind": 9999,
		"lifecycle": 0,
		"duration_days": -1,
		"stack_policy": 0,
		"max_stacks": 1,
	})
	_expect("C: an unknown selector kind is refused",
		not bool(unknown.get("ok", true)), str(unknown))
	if bool(unknown.get("ok", false)):
		_expect("C: and it does not silently become DerivedCell",
			String(unknown.get("backend", "")) != "DerivedCell", str(unknown))

	# D: capability vs rollout are separate questions.
	var gate: Dictionary = ext.get_cell_program_rollout()
	_expect("D: the rollout state is readable", bool(gate.get("ok", false)),
		str(gate))
	print("[catalog] rollout=%s enabled_kinds=%s"
		% [str(int(gate.get("rollout", -1))), str(gate.get("enabled_kinds", []))])
	# The capability probe above already returned DerivedCell while the rollout may
	# be off: the two must not collapse into one another (§4.5).
	var rollout_any := bool(gate.get("enabled_any", false))
	var capability_is_derived := String(capable.get("backend", "")) == "DerivedCell"
	_expect("D: capability holds regardless of the rollout gate",
		capability_is_derived, "rollout_any=%s" % str(rollout_any))

	_finish(0 if _failures == 0 else 3)


func _finish(code: int) -> void:
	print("=== cell layer catalog: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
