extends "res://tests/economy/economy_stratum_save_restore_test.gd"

## Rebellion chain pacing. A failed action must not advance the stage: the
## simulation continues and the next event only opens when organization reaches
## the next gate (Victoria-style). Successful actions buy a cooldown, and only a
## final-stage failure loses the city immediately.
##
## The native row is seeded through the same public PKEC fixture the save test
## uses; nothing here reaches into runtime internals.

const CELL := 0
const FAILED_REVIEW_DAYS := 10
const FULL_ORGANIZATION_Q16 := 65535
const Rebellion = preload("res://scripts/politics/stratum_rebellion_content.gd")


func _run() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not _check("catalog compiles", bool(catalog.get("ok", false))):
		return
	var profile := _native_profile(false, 1)
	profile.market_cycle_days = 1
	var base := _configured(catalog, profile)
	if base == null:
		return
	var signature: int = (catalog.signature_keys as PackedStringArray).find("unemployed|default")
	var profession: int = (catalog.profession_ids as PackedStringArray).find("unemployed")
	if not _check("unemployed fixture ids exist", signature >= 0 and profession >= 0):
		return
	var boot: Dictionary = base.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([signature, signature]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([10000000, 10000000])}, {})
	if not _check("base bootstraps", bool(boot.get("ok", false))):
		return
	_run_day(base, 0)
	var original := _capture(base, false)
	var country := _capture(base, true)
	if not _check("fixture captures", not original.is_empty() and not country.is_empty()):
		return
	var schema := original[0].decode_u16(4)

	_organization_builds_gradually(catalog, profile, country, original, schema, profession)
	_organization_gates_match_thresholds(catalog, profile, country, original, schema, profession)
	_restored_long_interval_returns_to_normal(catalog, profile, country, original, schema, profession)
	_failed_action_does_not_escalate(catalog, profile, country, original, schema, profession)
	_final_stage_failure_loses_the_city(catalog, profile, country, original, schema, profession)
	_final_stage_amnesty_failure_loses_the_city(catalog, profile, country, original, schema, profession)
	_success_starts_cooldown(catalog, profile, country, original, schema, profession)
	_last_city_clear_is_explicit(catalog, profile, country, original, schema, profession)
	_offer_tooltips_match_the_rules()
	_instances.clear()
	print("=== stratum chain pacing: %d checks, %d failures ===" % [_checks, _failures])


func _organization_builds_gradually(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	var ext := _seeded(catalog, profile, country, original, schema, profession, 0, 0)
	if ext == null:
		return
	var report := _run_day(ext, 1)
	_check("the first day of organization commits", bool(report.get("done", false)))
	var organization := int(_snapshot(ext).get("mobilization_q16", -1))
	# Even a fully aggrieved profession gains at most 65535 / 180 on day one.
	_check("natural organization rises at the 180-day rate", organization > 0 and organization <= 364)


func _organization_gates_match_thresholds(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	# This city has enough mobilization power. Maximum organizing capacity also
	# exercises the last fixed-point step from just below full organization.
	var cases := [
		[1, 36045, 1], [1, 39322, 2],
		[2, 52429, 2], [2, 58983, 3],
		[3, 64881, 3], [3, FULL_ORGANIZATION_Q16 - 1, 4],
	]
	for scenario in cases:
		var stage: int = scenario[0]
		var initial: int = scenario[1]
		var expected_stage: int = scenario[2]
		var ext := _seeded(catalog, profile, country, original, schema, profession,
			stage, initial, 1, 1, 0, FULL_ORGANIZATION_Q16)
		if ext == null:
			return
		var report := _run_day(ext, 1)
		_check("stage %d threshold review commits" % stage, bool(report.get("done", false)))
		var row := _snapshot(ext)
		_check("stage %d starting at %d Q16 reaches stage %d" % [stage, initial, expected_stage],
			int(row.get("stage", -1)) == expected_stage)
		if expected_stage == 4:
			_check("natural accumulation can reach full organization",
				int(row.get("mobilization_q16", -1)) == FULL_ORGANIZATION_Q16)


func _restored_long_interval_returns_to_normal(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	var ext := _seeded(catalog, profile, country, original, schema, profession, 1, 62000, 1, 240)
	if ext == null:
		return
	var report := _run_day(ext, 1)
	_check("the first day after restore commits", bool(report.get("done", false)))
	var row := _snapshot(ext)
	_check("the restored 240-day delay returns to the stage-one review date",
		int(row.get("stage", -1)) == 1 and int(row.get("next_check_day", -1)) == 14)

	report = _run_day(ext, 14)
	_check("the restored review day commits", bool(report.get("done", false)))
	row = _snapshot(ext)
	_check("both gates can still trigger natural escalation on the normal review day",
		int(row.get("stage", -1)) == 2 and int(row.get("next_check_day", -1)) == 26)


func _failed_action_does_not_escalate(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	var initial_organization := [19661, 39322, 58983]
	var failed_action_increase := [1311, 1966, 2621]
	for index in initial_organization.size():
		var stage := index + 1
		var initial: int = initial_organization[index]
		var ext := _seeded(catalog, profile, country, original, schema, profession, stage, initial)
		if ext == null:
			return
		var applied: bool = ext.apply_mobilization_result(CELL, profession, 2, false)
		var row := _snapshot(ext)
		_check("stage %d failed crackdown applies" % stage, applied)
		_check("stage %d failure keeps the current stage and ownership" % stage,
			int(row.get("stage", -1)) == stage and int(row.get("flags", 0)) & 8 == 0)
		_check("stage %d failure adds the smaller organization increase" % stage,
			int(row.get("mobilization_q16", -1)) == initial + failed_action_increase[index])
		_check("stage %d failure schedules the next review ten days out" % stage,
			int(row.get("next_check_day", -1)) == FAILED_REVIEW_DAYS)

		if stage == 3:
			var report := _run_day(ext, FAILED_REVIEW_DAYS)
			_check("stage-three failure reaches its scheduled review", bool(report.get("done", false)))
			row = _snapshot(ext)
			_check("the failed crackdown cannot carry stage three through the next gate",
				int(row.get("stage", -1)) == 3 and int(row.get("mobilization_q16", -1)) < FULL_ORGANIZATION_Q16
				and int(row.get("next_check_day", -1)) == FAILED_REVIEW_DAYS * 2)


func _final_stage_failure_loses_the_city(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	var ext := _seeded(catalog, profile, country, original, schema, profession, 4, 60000)
	if ext == null:
		return
	var applied: bool = ext.apply_mobilization_result(CELL, profession, 2, false)
	var row := _snapshot(ext)
	_check("final-stage crackdown failure applies", applied)
	_check("final-stage crackdown failure marks the cell for independence",
		int(row.get("stage", -1)) == 4 and (int(row.get("flags", 0)) & 8) != 0)


func _final_stage_amnesty_failure_loses_the_city(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	var ext := _seeded(catalog, profile, country, original, schema, profession, 4, 60000)
	if ext == null:
		return
	var applied: bool = ext.apply_mobilization_result(CELL, profession, 4, false)
	var row := _snapshot(ext)
	_check("final-stage amnesty failure applies", applied)
	_check("final-stage amnesty failure uses the same independence rule",
		int(row.get("stage", -1)) == 4 and (int(row.get("flags", 0)) & 8) != 0)


func _success_starts_cooldown(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	var ext := _seeded(catalog, profile, country, original, schema, profession, 2, 45000)
	if ext == null:
		return
	var applied: bool = ext.apply_mobilization_result(CELL, profession, 2, true)
	var row := _snapshot(ext)
	var cooldown := int(row.get("cooldown_until_day", -1))
	_check("successful crackdown applies", applied)
	_check("successful crackdown lowers the stage", int(row.get("stage", -1)) == 1)
	_check("successful crackdown opens a 180-day cooldown", cooldown == 180)
	_check("successful crackdown does not re-check before the cooldown ends",
		int(row.get("next_check_day", -1)) == cooldown)


func _last_city_clear_is_explicit(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	var ext := _seeded(catalog, profile, country, original, schema, profession, 4, 60000, 9)
	if ext == null:
		return
	var before := _snapshot(ext)
	var cleared: int = ext.clear_cell_mobilization_independence(CELL)
	var after := _snapshot(ext)
	_check("last-city clear reports the cleared row", cleared == 1)
	_check("last-city clear removes the independence bit",
		(int(before.get("flags", 0)) & 8) != 0 and
		(int(after.get("flags", 0)) & 8) == 0)
	_check("last-city clear keeps the chain stage", int(after.get("stage", -1)) == 4)


func _offer_tooltips_match_the_rules() -> void:
	var early := Rebellion.build(1, "匠户", "测试城", [2], {}, [0])
	var early_hint := String(early.options[0].tooltip_hint)
	_check("early crackdown tooltip does not promise immediate independence",
		early_hint.contains("组织度上涨") and not early_hint.contains("脱离"))
	var final_def := Rebellion.build(4, "匠户", "测试城", [2], {}, [0])
	_check("final crackdown tooltip warns about independence",
		String(final_def.options[0].tooltip_hint).contains("脱离"))
	var ignored := Rebellion.build(1, "匠户", "测试城", [3], {}, [0])
	_check("ignore tooltip no longer claims the stage advances",
		not String(ignored.options[0].tooltip_hint).contains("阶段"))


func _seeded(catalog: Dictionary, profile: Dictionary, country: Array[PackedByteArray],
		original: Array[PackedByteArray], schema: int, profession: int, stage: int,
		mob: int, flags: int = 1, next_check_day: int = 0,
		initial_satisfaction: int = -1, trauma: int = 0) -> Object:
	var ext := _target(catalog, profile, country)
	if ext == null:
		return null
	var row := _row(CELL, profession, stage, mob, flags, next_check_day)
	if initial_satisfaction >= 0:
		row.encode_u16(12, initial_satisfaction)
	row.encode_u16(32, trauma)
	if not _restore_pkec(ext, _replace_mobilization(original, row, schema), "seed stage %d" % stage):
		return null
	return ext


func _snapshot(ext: Object) -> Dictionary:
	var snap: Dictionary = ext.get_cell_mobilization_snapshot(CELL)
	var rows: Array = snap.get("rows", [])
	return rows[0] if not rows.is_empty() else {}


func _row(cell: int, profession: int, stage: int, mob: int, flags: int,
		next_check_day: int) -> PackedByteArray:
	var payload := PackedByteArray()
	payload.resize(ROW_BYTES)
	payload.encode_s32(0, cell)
	payload.encode_u16(4, profession)
	payload.encode_s32(6, 0)
	payload.encode_u16(10, mob)
	payload.encode_u16(12, mob)
	payload.encode_u16(14, 26214)
	payload.encode_u16(16, 30000)
	payload[18] = stage
	payload[19] = flags
	payload.encode_s32(20, next_check_day)
	payload.encode_s32(24, 0)
	payload.encode_s32(28, 0)
	payload.encode_u16(32, 0)
	return payload
