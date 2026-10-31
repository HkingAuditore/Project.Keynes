extends SceneTree
## Runs the native target-selector self-test, which now covers plan 22 §13.4's
## `unbounded` row (31 / 32 / 33 / 200 / 1000+ cells through the REAL selector).
##
## WHY THIS WRAPPER EXISTS
##
## `EconomyTargetSelectorTests::run` is a `friend` of `NativeEconomyRuntime`
## (`economy_runtime.h:179`), so the 32+ assertions had to live in that C++ file to
## get at the private territory columns. It is compiled into the DLL with no
## `main()`, and reaches GDScript through
## `runtime_economy_target_selector_self_test()`.
##
## So the assertion lives in C++ and this fixture is what makes it RUN in CI:
## without a caller the self-test is dead code that never executes, which is the
## "test that certifies itself" shape §13.1 forbids.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_unbounded_test.gd

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
	if ext == null:
		_expect("DCWorldExt instantiates", false)
		_finish(1)
		return

	# The self-test is self-contained: it builds its own territory and neighbours
	# (including a 2400-cell grid for the 200 / 1000 cases), so no catalog or
	# economy configuration is required. That is deliberate -- requiring a live
	# epoch is exactly what made the 33..N range unverifiable before (M1-13).
	var ok := bool(ext.runtime_economy_target_selector_self_test())
	_expect("the native target-selector self-test passes (incl. 31/32/33/200/1000+)",
		ok, "see the printerr output above for the failing check name")

	_finish(0 if _failures == 0 else 3)


func _finish(code: int) -> void:
	print("=== cell layer unbounded: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
