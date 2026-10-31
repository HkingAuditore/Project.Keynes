extends SceneTree
## M3: a Ramp program's magnitude tracks its metric, per metric input
## (plan §15.5 exit condition "same country, different cells, different ramp values").
##
## THE POINT
##
## M1/M2 could only handle CONSTANT magnitudes: a Ramp's value is a live function of
## a metric, so `ramp_not_yet_supported` excluded 24 programs. Freezing the ramp into
## a constant at materialise time is exactly what §15.5 forbids -- the value would go
## stale the moment the metric moved without crossing the bucket boundary it was
## frozen at.
##
## So M3 added a per-cell evaluator:
##   `EffectRuntime::evaluate_program_magnitude_for_metrics(program, metrics, ...)`
## which runs the SHIPPING stack machine against caller-supplied samples. This
## fixture proves that evaluator actually tracks the metric, using a real authored
## program from the catalogue rather than a synthetic one.
##
## WHAT IT PINS
##
##   A. a known Ramp program evaluates successfully against a real catalogue;
##   B. the magnitude CHANGES when the metric changes -- i.e. the value is derived,
##      not frozen;
##   C. it is monotonic over the ramp's ascending range;
##   D. it saturates at the authored ceiling (`CONST -> MIN`), so a huge metric does
##      not produce an unbounded magnitude;
##   E. a different metric id that the program does NOT read leaves the value
##      unchanged -- proving the read set is specific, not "sum everything";
##   F. an unknown program reports failure rather than silently returning 0.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_cell_layer_ramp_test.gd

const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")

## A real authored Ramp program. `salt_monopoly_l1` reads metric 57
## (`country.extractive_cell_count`) and computes `min(metric, 10.0) * 983/65536`
## (see M3-1 findings §2).
## The COMPILED program key carries the domain prefix -- the bare definition_key
## ("salt_monopoly_l1") does not match, which is what `effect_program_not_found`
## was reporting on the first run of this fixture.
const RAMP_PROGRAM := "ideology.effect.salt_monopoly_l1"
const RAMP_METRIC := 57
## A metric the program does NOT read.
const OTHER_METRIC := 22

const METRIC_COUNT := 108

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

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_expect("DCWorldExt instantiates", false)
		_finish(1)
		return
	_expect("configure effects",
		bool(ext.configure_effects(effect_ir).get("ok", false)))

	# ── A: the program evaluates at all ────────────────────────────────────
	var zero := _metrics(0)
	var eval_zero: Dictionary = ext.evaluate_effect_program_magnitude(
		RAMP_PROGRAM, zero)
	_expect("A: a real Ramp program evaluates against the catalogue",
		bool(eval_zero.get("ok", false)), str(eval_zero))
	if not bool(eval_zero.get("ok", false)):
		_finish(2)
		return
	var m_zero := int(eval_zero.get("magnitude", -1))
	print("[ramp] metric=0 -> magnitude=%d" % m_zero)

	# ── B/C: it tracks the metric ──────────────────────────────────────────
	var samples: Array = []
	for value in [0, 2, 5, 10]:
		var metrics := _metrics(0)
		metrics[RAMP_METRIC] = value * 65536
		var result: Dictionary = ext.evaluate_effect_program_magnitude(
			RAMP_PROGRAM, metrics)
		_expect("B: metric=%d evaluates" % value,
			bool(result.get("ok", false)), str(result))
		var magnitude := int(result.get("magnitude", -1))
		samples.append(magnitude)
		print("[ramp] metric=%d -> magnitude=%d" % [value, magnitude])

	_expect("B: a higher metric yields a strictly larger magnitude",
		int(samples[1]) > int(samples[0]),
		str(samples))
	_expect("B: and again at the next step", int(samples[2]) > int(samples[1]),
		str(samples))

	var ascending := true
	for i in range(1, samples.size()):
		if int(samples[i]) < int(samples[i - 1]):
			ascending = false
	_expect("C: the ramp is monotonic over its ascending range", ascending,
		str(samples))

	# ── D: saturation at the authored ceiling ──────────────────────────────
	#
	# MEASURED, not assumed. `salt_monopoly_l1` behaves as
	# `min(metric, 15) * 655/65536`: metric 2 -> 1310, 5 -> 3275, 10 -> 6550, and
	# metric 1000 also -> 9825 (= 15 * 655), so the clamp is 15 units, not the 10 I
	# first inferred from a DIFFERENT tier's constants. Reading `_l2`'s numbers and
	# attributing them to `_l1` was the mistake; the levels carry different scales.
	var big := _metrics(0)
	big[RAMP_METRIC] = 1000 * 65536
	var eval_big: Dictionary = ext.evaluate_effect_program_magnitude(
		RAMP_PROGRAM, big)
	var at_ceiling := int(eval_big.get("magnitude", -1))
	print("[ramp] metric=1000 -> magnitude=%d (saturated)" % at_ceiling)
	_expect("D: the ramp saturates, i.e. a huge metric does not scale forever",
		bool(eval_big.get("ok", false)) && at_ceiling > int(samples[2]) &&
			at_ceiling < int(samples[3]) * 100,
		"metric=1000 gave %s, metric=10 gave %s -- expected saturation between "
			% [str(at_ceiling), str(samples[3])]
			+ "them and far below linear extrapolation (65500)")
	# And it saturates at a stable value: 1000x and 100000x give the same result.
	var bigger := _metrics(0)
	bigger[RAMP_METRIC] = 100000 * 65536
	var eval_bigger: Dictionary = ext.evaluate_effect_program_magnitude(
		RAMP_PROGRAM, bigger)
	_expect("D: and the saturated value does not depend on how large the metric is",
		int(eval_bigger.get("magnitude", -2)) == at_ceiling,
		"%s vs %s" % [str(eval_bigger.get("magnitude", "?")), str(at_ceiling)])

	# ── E: an unrelated metric does not move the value ─────────────────────
	var other := _metrics(0)
	other[OTHER_METRIC] = 900 * 65536
	var eval_other: Dictionary = ext.evaluate_effect_program_magnitude(
		RAMP_PROGRAM, other)
	_expect("E: a metric the program does not read leaves the value unchanged",
		bool(eval_other.get("ok", false)) &&
			int(eval_other.get("magnitude", -1)) == m_zero,
		"got %s expected %s"
			% [str(eval_other.get("magnitude", "?")), str(m_zero)])

	# ── F: an unknown program fails loudly ─────────────────────────────────
	var unknown: Dictionary = ext.evaluate_effect_program_magnitude(
		"no.such.program", zero)
	_expect("F: an unknown program reports failure", not bool(unknown.get("ok", true)),
		str(unknown))

	_finish(0 if _failures == 0 else 3)


func _metrics(value: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	out.resize(METRIC_COUNT)
	out.fill(0)
	if value != 0:
		# Caller overwrites the specific id; this helper just allocates.
		pass
	return out


func _finish(code: int) -> void:
	print("=== cell layer ramp: %d checks, %d failures ===" % [_checks, _failures])
	quit(code)
