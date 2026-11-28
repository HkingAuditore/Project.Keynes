extends "res://tests/economy/economy_rolling_runtime_test.gd"

# Regression test for K1 (Issue #5):
# Default cell tax rows must not collide on bit-packed keys when the same
# country configures distinct cell default rates/modes (e.g. absolute 1 vs
# absolute 16777217 = (1 << 24) + 1).
#
# Run: godot --headless --path Project/project-keynes --script res://tests/economy/cell_tax_row_settlement_test.gd

const RATE_LOW := 1
const RATE_COLLIDING_HIGH := 16777217 # (1 << 24) + 1

var _checks := 0


func _init() -> void:
	_run()
	print("=== cell tax row settlement: %d checks, %d failures ===" % [_checks, failures])
	quit(0 if failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	super._expect(label, condition)


func _set_cell_tax_default(ext: Object, handle: int, cell: int, kind: int,
		value: int, mode: int, day: int, sequence: int) -> bool:
	var batch := {
		"opcodes": PackedInt32Array([15]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([handle]),
		"cell_indices": PackedInt32Array([cell]),
		"aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"tax_kinds": PackedInt32Array([kind]),
		"tax_item_indices": PackedInt32Array([-1]),
		"tax_rate_basis_points": PackedInt32Array([value]),
		"tax_assessment_modes": PackedInt32Array([mode]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	}
	return bool(ext.submit_country_commands(batch).get("ok", false)) \
		and bool(ext.run_country_slice({"day_index": day}).get("ok", false))


func _cell_total_funds(ext: Object, cell: int) -> int:
	var snapshot: Dictionary = ext.get_population_cell_snapshot(cell)
	return int(snapshot.get("funds", -1))


func _run_pair(compiled: Dictionary, catalog: Dictionary, profile: Dictionary,
		rate_cell0: int, rate_cell1: int, seed: int) -> Dictionary:
	var runtime := _new_runtime(compiled, catalog, profile, seed)
	var handle := int(runtime.get_country_cell_summary(0).country_handle)
	var handle1 := int(runtime.get_country_cell_summary(1).country_handle)
	_expect("cell 0 and cell 1 share the same country (%d/%d)" % [rate_cell0, rate_cell1],
		handle > 0 and handle == handle1)
	_expect("cell 0 absolute income tax %d commits" % rate_cell0,
		_set_cell_tax_default(runtime, handle, 0, 0, rate_cell0, 1, 0, 1))
	_expect("cell 1 absolute income tax %d commits" % rate_cell1,
		_set_cell_tax_default(runtime, handle, 1, 0, rate_cell1, 1, 0, 2))
	# Run one full rolling cycle (PHASE_COUNT = 5 days) so cell 0 and cell 1
	# each settle exactly once.
	for day in range(PHASE_COUNT):
		_validate_day(runtime, day)
		if bool(runtime.get_economy_report().get("fatal", false)):
			break
	var fiscal: Dictionary = runtime.get_country_fiscal_snapshot(handle)
	var collected: PackedInt64Array = fiscal.get("cumulative_collected", PackedInt64Array())
	var result := {
		"income_collected": int(collected[0]) if collected.size() > 0 else -1,
		"cell0_funds": _cell_total_funds(runtime, 0),
		"cell1_funds": _cell_total_funds(runtime, 1),
	}
	runtime = null
	return result


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	profile.economy_cadence_force_market_days = 5
	profile.economy_cadence_force_plan_days = 10
	profile.economy_cadence_force_investment_days = 10

	# Control: both cells at RATE_LOW (1).
	var both_low := _run_pair(compiled, catalog, profile, RATE_LOW, RATE_LOW, 92031)
	# Order A: cell 0 = 1, cell 1 = 16777217.
	# With the bit-packing collision bug, cell 1 reuses cell 0's row (rate=1).
	var low_then_high := _run_pair(
		compiled, catalog, profile, RATE_LOW, RATE_COLLIDING_HIGH, 92031)
	# Order B: cell 0 = 16777217, cell 1 = 1.
	# With the bit-packing collision bug, cell 1 reuses cell 0's row (rate=16777217).
	var high_then_low := _run_pair(
		compiled, catalog, profile, RATE_COLLIDING_HIGH, RATE_LOW, 92031)

	print("  [INFO] both_low=%s low_then_high=%s high_then_low=%s" % [
		str(both_low), str(low_then_high), str(high_then_low)])

	_expect("both_low collects positive income tax and preserves cell funds",
		int(both_low.income_collected) > 0 and
		int(both_low.cell0_funds) > 0 and int(both_low.cell1_funds) > 0)
	_expect("cell 1 with rate=16777217 is not aliased to cell 0 rate=1",
		int(low_then_high.cell0_funds) == int(both_low.cell0_funds) and
		int(low_then_high.cell1_funds) == 0 and
		int(low_then_high.income_collected) > int(both_low.income_collected) * 100)
	_expect("cell 1 with rate=1 is not aliased to cell 0 rate=16777217",
		int(high_then_low.cell0_funds) == 0 and
		int(high_then_low.cell1_funds) == int(both_low.cell1_funds) and
		int(high_then_low.income_collected) > int(both_low.income_collected) * 100)
	_expect("symmetric rate assignments yield identical total country income tax",
		int(low_then_high.income_collected) == int(high_then_low.income_collected))
