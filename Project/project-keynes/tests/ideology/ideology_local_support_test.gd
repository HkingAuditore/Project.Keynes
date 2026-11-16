extends SceneTree

## Unit test for the cell-level support math. No world, no catalog, no economy:
## pure function in, numbers out. Asserts a minimum check count so a GDScript
## silent abort cannot read as "0 failures".

const LocalSupportScript = preload("res://scripts/ideology/ideology_local_support.gd")
const Q16 := 65536

var _checks := 0
var _failures := 0


func _init() -> void:
	# One class only: local support equals that class's stance exactly.
	var single := LocalSupportScript.rows(
		PackedInt32Array([Q16 / 2, -Q16 / 2]), PackedInt64Array([100, 900]),
		2, 1)
	_expect("single row count", single.size() == 1)
	var expect_weighted := (100 * (Q16 / 2) + 900 * (-(Q16 / 2))) / 1000
	_expect("single weighted average",
		int(single[0]["support_q16"]) == expect_weighted)
	_expect("population total", int(single[0]["population"]) == 1000)

	# Two cells, different mixes: the same stances must produce different support.
	var two := LocalSupportScript.rows(
		PackedInt32Array([Q16, 0, -Q16]), PackedInt64Array([1000, 0, 0, 0, 0, 1000]),
		3, 2)
	_expect("two rows", two.size() == 2)
	_expect("cell A all class 0", int(two[0]["support_q16"]) == Q16)
	_expect("cell B all class 2", int(two[1]["support_q16"]) == -Q16)

	# Empty population must not divide by zero and must read as neutral.
	var empty := LocalSupportScript.rows(PackedInt32Array([Q16]), PackedInt64Array([0]),
		1, 1)
	_expect("empty cell neutral", int(empty[0]["support_q16"]) == 0)
	_expect("empty cell population", int(empty[0]["population"]) == 0)

	# Short population column (a catalog mismatch) stops at the available classes.
	var short_rows := LocalSupportScript.rows(
		PackedInt32Array([Q16, Q16]), PackedInt64Array([10]), 2, 1)
	_expect("short column still scores", int(short_rows[0]["support_q16"]) == Q16)

	var summary: Dictionary = LocalSupportScript.summarize(two)
	_expect("summary ok", bool(summary.get("ok", false)))
	_expect("summary average", int(summary.get("average_q16", 0)) == 0)
	_expect("summary lowest", int(summary.get("lowest_q16", 0)) == -Q16)
	_expect("summary cells", int(summary.get("cells", 0)) == 2)
	_expect("empty summary", not bool(LocalSupportScript.summarize([]).get("ok", true)))

	print("%d checks, %d failures" % [_checks, _failures])
	_expect("minimum check count", _checks >= 13)
	quit(0 if _failures == 0 else 1)


func _expect(what: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		print("FAIL ", what)
