extends SceneTree

## L1-4b acceptance: the catalog <-> native contract for cell tags.
##
## Why this exists
## ---------------
## `gdext/src/target_tag.h` defines a tag as an OR of clauses, each clause an AND
## of `metric <op> threshold` rows. The table is *optional* on purpose: it is
## emitted as a parallel set of arrays rather than by widening
## `target_selector_param`, because widening that is a `count * 2 -> count * 4`
## breaking change for every existing catalog. The cost of "optional" is that
## nothing exercises the shape unless a test does, and a silently-absent table
## looks exactly like a table that failed to compile.
##
## So this file pins three things:
##
##  1. A catalog with no tags emits empty arrays and still configures. That is
##     the pre-tag path every shipped catalog takes today; if it ever needs a
##     protocol bump, this check breaks first.
##  2. A well-formed tag table survives `compile_native_catalog()` -> native
##     `configure()` unchanged, in the exact array layout the evaluator reads.
##  3. Every malformed shape is rejected *with a reason that names the
##     invariant*. Both layers are checked: the GDScript packer catches authoring
##     mistakes early with the tag name attached, and the native validator
##     catches a hand-built or stale payload that never went through it.
##
## The evaluation itself (does a tag actually select the right cells) lives in
## `economy_runtime_effect_selector_tests.cpp`, because it needs a grid.

const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")

const METRIC_LANDFORM := "cell.landform"
const METRIC_POPULATION := "cell.population"
const Q16_ONE := 65536

## Op codes, mirrored from `TargetTagOp` in gdext/src/target_tag.h.
const TAG_GTE := 0
const TAG_LTE := 1
const TAG_EQ := 2
const TAG_NEQ := 3

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("target tag catalog: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	_test_no_tags_is_unchanged()
	_test_well_formed_table_round_trips()
	_test_authoring_errors()
	_test_native_shape_rejects_mutated_payload()


## 1. The pre-tag path. Absent table -> empty arrays -> native keeps zero tags.
func _test_no_tags_is_unchanged() -> void:
	var catalog := _catalog()
	var compiled: Dictionary = catalog.compile_native_catalog()
	_expect("no-tag catalog compiles", bool(compiled.get("ok", false)),
		str(compiled.get("reason", "")))
	_expect("no-tag catalog emits an empty name table",
		(compiled.get("target_tags", PackedStringArray()) as PackedStringArray).is_empty())
	_expect("no-tag catalog emits no offsets",
		(compiled.get("tag_offsets", PackedInt32Array()) as PackedInt32Array).is_empty())
	_expect("no-tag catalog emits no rows",
		(compiled.get("tag_metric_ids", PackedInt32Array()) as PackedInt32Array).is_empty())
	# The whole point of "optional": a catalog without tags must still load.
	var accepted := _configure(compiled)
	_expect("no-tag catalog configures", bool(accepted.get("ok", false)),
		str(accepted))


## 2. A well-formed table must arrive in exactly the layout the evaluator reads.
func _test_well_formed_table_round_trips() -> void:
	var catalog := _catalog()
	# The property is Array[Dictionary], so the literal has to be typed too; an
	# untyped Array is rejected at assignment time.
	var tag_rows_a: Array[Dictionary] = [
		{"metric": METRIC_POPULATION, "op": TAG_GTE,
			"threshold_q16": 100 * Q16_ONE, "clause": 0},
	]
	var tag_rows_b: Array[Dictionary] = [
		{"metric": METRIC_LANDFORM, "op": TAG_EQ,
			"threshold_q16": 0, "clause": 0},
		{"metric": METRIC_POPULATION, "op": TAG_LTE,
			"threshold_q16": Q16_ONE, "clause": 1},
	]
	var tags: Array[Dictionary] = [
		{"name": "developed", "rows": tag_rows_a},
		# Two clauses -> OR: "landform is 0, or population is tiny".
		{"name": "frontier", "rows": tag_rows_b},
	]
	catalog.target_tags = tags
	var compiled: Dictionary = catalog.compile_native_catalog()
	_expect("tag catalog compiles", bool(compiled.get("ok", false)),
		str(compiled.get("reason", "")))
	var names: PackedStringArray = compiled.get("target_tags", PackedStringArray())
	_expect("tag names keep author order",
		names == PackedStringArray(["developed", "frontier"]), str(names))
	var offsets: PackedInt32Array = compiled.get("tag_offsets", PackedInt32Array())
	_expect("tag offsets are a tag_count + 1 CSR",
		offsets == PackedInt32Array([0, 1, 3]), str(offsets))
	var ids: PackedInt32Array = compiled.get("tag_metric_ids", PackedInt32Array())
	_expect("tag metric ids resolve against metric_keys",
		ids == PackedInt32Array([1, 0, 1]), str(ids))
	var ops: PackedInt32Array = compiled.get("tag_metric_ops", PackedInt32Array())
	_expect("tag ops keep author order",
		ops == PackedInt32Array([TAG_GTE, TAG_EQ, TAG_LTE]), str(ops))
	var clauses: PackedInt32Array = compiled.get(
		"tag_metric_clauses", PackedInt32Array())
	_expect("tag clauses keep author order and grouping",
		clauses == PackedInt32Array([0, 0, 1]), str(clauses))
	var thresholds: PackedInt64Array = compiled.get(
		"tag_metric_thresholds_q16", PackedInt64Array())
	_expect("tag thresholds are Q16 and untouched",
		thresholds == PackedInt64Array([100 * Q16_ONE, 0, Q16_ONE]), str(thresholds))
	var accepted := _configure(compiled)
	_expect("well-formed tag table configures", bool(accepted.get("ok", false)),
		str(accepted))


## 3. Authoring mistakes caught in GDScript, where the tag name is still known.
func _test_authoring_errors() -> void:
	var cases := [
		{
			"label": "undeclared metric",
			"tags": _tags([
				_tag("typo", [
					_row("cell.does_not_exist", TAG_GTE, 0, 0),
				]),
			]),
			"reason": "target_tag_metric_not_declared:cell.does_not_exist",
		},
		{
			"label": "tag with no rows",
			"tags": _tags([_tag("empty", [])]),
			"reason": "target_tag_has_no_rows",
		},
		{
			"label": "empty tag name",
			"tags": _tags([
				_tag("", [_row(METRIC_LANDFORM, TAG_EQ, 0, 0)]),
			]),
			"reason": "target_tag_name_empty",
		},
		{
			"label": "unknown op",
			"tags": _tags([
				_tag("badop", [_row(METRIC_LANDFORM, 9, 0, 0)]),
			]),
			"reason": "target_tag_op_invalid",
		},
		{
			"label": "clause ids decrease",
			"tags": _tags([
				_tag("unsorted", [
					_row(METRIC_LANDFORM, TAG_EQ, 0, 2),
					_row(METRIC_POPULATION, TAG_GTE, 0, 1),
				]),
			]),
			"reason": "target_tag_clause_not_sorted",
		},
	]
	for entry in cases:
		var catalog := _catalog()
		catalog.target_tags = entry["tags"]
		var compiled: Dictionary = catalog.compile_native_catalog()
		_expect("%s is rejected" % entry["label"],
			not bool(compiled.get("ok", true)), str(compiled))
		_expect("%s names the invariant" % entry["label"],
			String(compiled.get("reason", "")) == String(entry["reason"]),
			str(compiled.get("reason", "")))


## 4. A payload that never went through the packer still has to be rejected.
##    Mutating the compiled dictionary is the only way to simulate a stale or
##    hand-built catalog from GDScript.
func _test_native_shape_rejects_mutated_payload() -> void:
	var catalog := _catalog()
	catalog.target_tags = _tags([
		_tag("frontier", [_row(METRIC_LANDFORM, TAG_EQ, 0, 0)]),
	])
	var base: Dictionary = catalog.compile_native_catalog()
	_expect("mutated-payload fixture compiles first",
		bool(base.get("ok", false)), str(base.get("reason", "")))

	# Offset CSR that does not land on the row count.
	var bad_offsets := base.duplicate(true)
	bad_offsets["tag_offsets"] = PackedInt32Array([0, 5])
	var rejected := _configure(bad_offsets)
	_expect("offset tail past the row count is rejected",
		not bool(rejected.get("ok", true)), str(rejected))
	_expect("rejection names the column shape",
		String(rejected.get("reason", "")) == "target_tag_offsets_bounds_invalid",
		str(rejected.get("reason", "")))

	# Column lengths that disagree with each other.
	var bad_columns := base.duplicate(true)
	bad_columns["tag_metric_ops"] = PackedInt32Array()
	rejected = _configure(bad_columns)
	_expect("mismatched tag column lengths are rejected",
		not bool(rejected.get("ok", true)), str(rejected))
	_expect("mismatched columns name the column contract",
		String(rejected.get("reason", "")) == "target_tag_columns_invalid",
		str(rejected.get("reason", "")))

	# Row pointing past the declared metric table: the sampler would read 0
	# forever, so the card would never fire and nothing would say why.
	var bad_metric := base.duplicate(true)
	bad_metric["tag_metric_ids"] = PackedInt32Array([2])
	rejected = _configure(bad_metric)
	_expect("metric id past metric_keys is rejected",
		not bool(rejected.get("ok", true)), str(rejected))
	_expect("undeclared metric id names its contract",
		String(rejected.get("reason", "")) == "target_tag_metric_not_declared",
		str(rejected.get("reason", "")))


## Minimal catalog: two metric ids and no definitions. A zero-definition catalog
## is legal (every per-definition column is empty), which keeps this test about
## the tag contract instead of about definition authoring.
func _catalog() -> Resource:
	var catalog: Resource = EffectCatalogScript.new()
	catalog.metric_keys = PackedStringArray([METRIC_LANDFORM, METRIC_POPULATION])
	return catalog


func _row(metric: String, op: int, threshold_q16: int, clause: int) -> Dictionary:
	return {"metric": metric, "op": op,
		"threshold_q16": threshold_q16, "clause": clause}


## `rows` is deliberately untyped: the inner list is only ever read back through
## `tag.get("rows", [])`, and an `Array[Dictionary]` parameter would reject the
## plain array literals the cases above are written with.
func _tag(name: String, rows: Array) -> Dictionary:
	return {"name": name, "rows": rows}


## The property is `Array[Dictionary]`; assigning a plain Array raises at
## runtime, so the outer list is converted here once instead of in every case.
func _tags(entries: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry in entries:
		out.append(entry)
	return out


func _configure(compiled: Dictionary) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	return ext.configure_effects(compiled)


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		if detail.is_empty():
			push_error("[FAIL] %s" % label)
		else:
			push_error("[FAIL] %s (%s)" % [label, detail])
