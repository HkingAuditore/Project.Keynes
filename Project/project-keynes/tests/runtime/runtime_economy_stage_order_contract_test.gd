extends SceneTree

var _checks := 0
var _failures := 0

const EXPECTED_STAGES := [
	"BUILDING_PLAN",
	"TRADE_SETTLE",
	"LEDGER_APPLY",
	"BUILDING_EMPLOYMENT",
	"BUILDING_PRODUCTION",
	"HOUSEHOLD_MARKET",
	"GOVERNMENT_RESEARCH_PROCUREMENT",
	"TRADE_DISPATCH",
	"STRUCTURAL_COMMIT",
	"BUILDING_COMMIT",
	"FAMILY_COMMIT",
	"PERSON_COMMIT",
	"AGGREGATE_PUBLISH",
]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		_finish()
		return
	var ext := DCWorldExt.new()
	_expect("Economy stage-order contract is exported",
		ext.has_method("runtime_economy_stage_order_contract_test"))
	if not ext.has_method("runtime_economy_stage_order_contract_test"):
		_finish()
		return

	var result: Dictionary = ext.runtime_economy_stage_order_contract_test()
	_expect("Economy stage-order contract passes", bool(result.get("ok", false)))
	_expect("Economy stage count is 13", int(result.get("stage_count", 0)) == 13)
	_expect("Economy all-stage mask is 0x1FFF",
		int(result.get("all_stage_mask", 0)) == 0x1FFF)

	var names: PackedStringArray = result.get("stage_names", PackedStringArray())
	_expect("Economy stage name count matches", names.size() == EXPECTED_STAGES.size())
	for i in range(mini(names.size(), EXPECTED_STAGES.size())):
		_expect("Economy stage[%d] is %s" % [i, EXPECTED_STAGES[i]],
			str(names[i]) == EXPECTED_STAGES[i])

	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	print("FAIL: ", label)


func _finish() -> void:
	print("runtime_economy_stage_order_contract_test checks=%s failures=%s" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
