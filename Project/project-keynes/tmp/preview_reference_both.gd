extends "res://tests/economy_performance_parity_test.gd"

## Original preview basis versus catalog-equivalent reuse on the same scheduler,
## with frozen cadence. Also compare each actor's goods and saturation delta.
func _run() -> void:
	OS.set_environment("PK_ECONOMY_MEMO_VERIFY", "1")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var original := _boot(compiled, 9, 997)
	var optimized := _boot(compiled, 9, 997)
	for day in range(_soak_days()):
		OS.set_environment("PK_ECONOMY_PREVIEW_BASIS_DISABLE", "1")
		var before: Dictionary = _run_compact_day(original, day)
		pass
		var after: Dictionary = _run_compact_day(optimized, day)
		_expect("day %d both paths complete" % day,
			bool(before.get("done", false)) and bool(after.get("done", false))
			and not bool(before.get("fatal", false))
			and not bool(after.get("fatal", false)))
		_expect("day %d complete state hash matches" % day,
			original.get_economy_state_hash() == optimized.get_economy_state_hash())
		if original.get_economy_state_hash() != optimized.get_economy_state_hash():
			for item in [["original", original], ["optimized", optimized]]:
				var file := FileAccess.open("res://tmp/preview_%s.json" % item[0], FileAccess.WRITE)
				file.store_string(JSON.stringify(item[1].get_economy_report(), "  "))
				item[1].begin_economy_forensics_save()
				var payload := FileAccess.open("res://tmp/preview_%s.pkec" % item[0], FileAccess.WRITE)
				while true:
					var chunk: PackedByteArray = item[1].read_economy_save_chunk()
					if chunk.is_empty(): break
					payload.store_buffer(chunk)
				item[1].end_economy_save()
			_finish()
			return
		for key in ["population_error", "money_error", "goods_error"]:
			_expect("day %d %s==0" % [day, key],
				int(before.get(key, -1)) == 0 and int(after.get(key, -1)) == 0)
	OS.unset_environment("PK_ECONOMY_MEMO_VERIFY")
	_finish()


func _finish() -> void:
	print("economy_preview_basis_parity_test checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
