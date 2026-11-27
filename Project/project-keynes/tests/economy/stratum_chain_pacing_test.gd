extends "res://tests/economy/economy_stratum_save_restore_test.gd"

## Rebellion chain pacing. A failed action must not advance the stage: the
## simulation continues and the next event only opens when organization reaches
## the next gate (Victoria-style). Successful actions buy a cooldown, and only a
## final-stage failure loses the city immediately.
##
## The native row is seeded through the same public PKEC fixture the save test
## uses; nothing here reaches into runtime internals.

const CELL := 0
const Rebellion = preload("res://scripts/politics/stratum_rebellion_content.gd")


func _run() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not _check("catalog compiles", bool(catalog.get("ok", false))):
		return
	var profile := _native_profile(false, 1)
	var base := _configured(catalog, profile)
	if base == null:
		return
	var signature: int = (catalog.signature_keys as PackedStringArray).find("worker|default")
	var profession: int = (catalog.profession_ids as PackedStringArray).find("worker")
	if not _check("worker fixture ids exist", signature >= 0 and profession >= 0):
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

	_failed_action_does_not_escalate(catalog, profile, country, original, schema, profession)
	_final_stage_failure_loses_the_city(catalog, profile, country, original, schema, profession)
	_final_stage_amnesty_failure_loses_the_city(catalog, profile, country, original, schema, profession)
	_success_starts_cooldown(catalog, profile, country, original, schema, profession)
	_last_city_clear_is_explicit(catalog, profile, country, original, schema, profession)
	_offer_tooltips_match_the_rules()
	_instances.clear()
	print("=== stratum chain pacing: %d checks, %d failures ===" % [_checks, _failures])


func _failed_action_does_not_escalate(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray], original: Array[PackedByteArray],
		schema: int, profession: int) -> void:
	var ext := _seeded(catalog, profile, country, original, schema, profession, 1, 40000)
	if ext == null:
		return
	var applied: bool = ext.apply_mobilization_result(CELL, profession, 2, false)
	var row := _snapshot(ext)
	_check("failed crackdown applies", applied)
	_check("failed crackdown keeps the chain at the current stage", int(row.get("stage", -1)) == 1)
	_check("failed crackdown does not mark independence", int(row.get("flags", 0)) & 8 == 0)
	_check("failed crackdown schedules the next review ten days out",
		int(row.get("next_check_day", -1)) == 10)

	ext = _seeded(catalog, profile, country, original, schema, profession, 3, 50000)
	if ext == null:
		return
	applied = ext.apply_mobilization_result(CELL, profession, 2, false)
	row = _snapshot(ext)
	_check("stage-three crackdown failure applies", applied)
	_check("stage-three crackdown failure does not skip the uprising event",
		int(row.get("stage", -1)) == 3 and int(row.get("flags", 0)) & 8 == 0)


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
		mob: int, flags: int = 1) -> Object:
	var ext := _target(catalog, profile, country)
	if ext == null:
		return null
	if not _restore_pkec(ext, _replace_mobilization(original,
			_row(CELL, profession, stage, mob, flags), schema), "seed stage %d" % stage):
		return null
	return ext


func _snapshot(ext: Object) -> Dictionary:
	var snap: Dictionary = ext.get_cell_mobilization_snapshot(CELL)
	var rows: Array = snap.get("rows", [])
	return rows[0] if not rows.is_empty() else {}


func _row(cell: int, profession: int, stage: int, mob: int, flags: int = 1) -> PackedByteArray:
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
	payload.encode_s32(20, 0)
	payload.encode_s32(24, 0)
	payload.encode_s32(28, 0)
	payload.encode_u16(32, 0)
	return payload
