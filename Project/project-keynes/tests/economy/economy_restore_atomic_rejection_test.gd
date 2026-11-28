extends "res://tests/economy/goods_storage_schema_test.gd"

const CELLS := 2
const SEED := 42
const PKEC_END_SECTION := 31
const HEADER_ENV_HASH_OFFSET := 120

var _instances: Array[Object] = []

func _run() -> void:
	_execute()
	_instances.clear()
	print("=== economy restore atomic rejection: %d checks, %d failures ===" % [_checks, _failures])

func _execute() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not _check("catalog compiles", bool(catalog.get("ok", false))):
		return
	var profile := _native_profile(false, 1)
	var ext := _configured(catalog, profile)
	if ext == null:
		return
	var signature: int = (catalog.signature_keys as PackedStringArray).find("worker|default")
	if not _check("worker signature exists", signature >= 0):
		return
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([signature, signature]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([10000000, 10000000]),
	}, {})
	if not _check("economy bootstraps", bool(boot.get("ok", false))):
		print("boot=", boot)
		return
	for day in range(2):
		var committed := _run_day(ext, day)
		if not _check("day %d commits cleanly" % day,
				bool(committed.get("done", false))
				and not bool(committed.get("fatal", false))
				and int(committed.get("population_error", 0)) == 0
				and int(committed.get("money_error", 0)) == 0
				and int(committed.get("goods_error", 0)) == 0):
			print("day %d report=" % day, committed)
			return

	var hash_before: int = ext.get_economy_state_hash()
	var report_before: Dictionary = ext.get_economy_report()
	if not _check("live economy bootstrapped before tests",
			bool(report_before.get("bootstrapped", false)) and hash_before != 0):
		print("report_before=", report_before)
		return

	var valid_pkec := _capture_pkec(ext)
	if not _check("valid PKEC captured", not valid_pkec.is_empty()):
		return
	var valid_ecp2_res: Dictionary = ext.capture_economy_ecp2(0)
	if not _check("valid ECP2 captured", bool(valid_ecp2_res.get("ok", false))):
		print("ecp2_capture=", valid_ecp2_res)
		return
	var valid_ecp2: PackedByteArray = valid_ecp2_res.get("bytes", PackedByteArray())
	if not _check("valid ECP2 bytes non-empty", valid_ecp2.size() > 32):
		return

	# 1. PKEC HEADER invalid schema version
	var bad_schema_header := valid_pkec[0].duplicate()
	bad_schema_header.encode_u16(4, 999)
	var begin1: Dictionary = ext.begin_economy_restore()
	_check("case1 begin_restore succeeds", bool(begin1.get("ok", false)))
	var feed1: Dictionary = ext.feed_economy_restore_chunk(bad_schema_header)
	_check("case1 invalid schema rejected", not bool(feed1.get("ok", true)))
	_assert_live_unchanged(ext, "case1_invalid_schema", hash_before, report_before)

	# 2. PKEC truncated (missing END chunk)
	var begin2: Dictionary = ext.begin_economy_restore()
	_check("case2 begin_restore succeeds", bool(begin2.get("ok", false)))
	var feed2_ok := true
	for chunk in valid_pkec:
		if chunk.decode_u16(6) == PKEC_END_SECTION:
			continue
		var res: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(res.get("ok", false)):
			feed2_ok = false
			break
	_check("case2 non-END chunks accepted", feed2_ok)
	var end2: Dictionary = ext.end_economy_restore()
	_check("case2 truncated PKEC rejected at end_restore",
		not bool(end2.get("ok", true)) and String(end2.get("reason", "")) == "restore_end_missing")
	_assert_live_unchanged(ext, "case2_truncated_pkec", hash_before, report_before)

	# 3. PKEC invalid field (tamper environment_hash in HEADER -> rejected in end_restore)
	var bad_env_chunks: Array[PackedByteArray] = []
	for i in range(valid_pkec.size()):
		var c := valid_pkec[i].duplicate()
		if i == 0:
			var orig_env_hash: int = c.decode_s64(HEADER_ENV_HASH_OFFSET)
			c.encode_s64(HEADER_ENV_HASH_OFFSET, orig_env_hash ^ 0x55AA)
		bad_env_chunks.append(c)
	var begin3: Dictionary = ext.begin_economy_restore()
	_check("case3 begin_restore succeeds", bool(begin3.get("ok", false)))
	var feed3_ok := true
	for chunk in bad_env_chunks:
		var res: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(res.get("ok", false)):
			feed3_ok = false
			print("case3 unexpected feed failure=", res)
			break
	_check("case3 all chunks fed before end_restore check", feed3_ok)
	var end3: Dictionary = ext.end_economy_restore()
	_check("case3 invalid environment_hash rejected at end_restore",
		not bool(end3.get("ok", true))
		and String(end3.get("reason", "")) == "restore_environment_hash_mismatch")
	_assert_live_unchanged(ext, "case3_invalid_env_hash", hash_before, report_before)

	# 4a. ECP2 truncated
	var truncated_ecp2 := valid_ecp2.slice(0, valid_ecp2.size() / 2)
	var res4a: Dictionary = ext.restore_economy_ecp2(truncated_ecp2)
	_check("case4a truncated ECP2 rejected", not bool(res4a.get("ok", true)))
	_assert_live_unchanged(ext, "case4a_truncated_ecp2", hash_before, report_before)

	# 4b. ECP2 checksum tampered
	var tampered_ecp2 := valid_ecp2.duplicate()
	tampered_ecp2[tampered_ecp2.size() - 1] ^= 0xFF
	var res4b: Dictionary = ext.restore_economy_ecp2(tampered_ecp2)
	_check("case4b tampered ECP2 rejected",
		not bool(res4b.get("ok", true))
		and String(res4b.get("reason", "")) == "ecp2_content_hash_mismatch")
	_assert_live_unchanged(ext, "case4b_tampered_ecp2", hash_before, report_before)

	# 4c. Valid ECP2 wire with matching cell_count/seed but mismatched Country state hash:
	# passes decode_ecp2() AND validate_ecp2_candidate(), enters apply_ecp2_authority()
	# staging, and is rejected inside staged->apply_ecp2_authority_internal().
	var other_ext := _build_world_with_different_country(catalog)
	var other_ecp2: PackedByteArray = other_ext.capture_economy_ecp2(1).get("bytes", PackedByteArray())
	_check("case4c foreign ECP2 captured", other_ecp2.size() > 0)
	var res4c: Dictionary = ext.restore_economy_ecp2(other_ecp2)
	var reason4c := String(res4c.get("reason", ""))
	_check("case4c foreign ECP2 rejected inside apply_ecp2_authority staging",
		not bool(res4c.get("ok", true))
		and not reason4c.begins_with("ecp2_"))
	_assert_live_unchanged(ext, "case4c_foreign_ecp2_staged", hash_before, report_before)
	other_ext = null

	# Post-rejection liveness: advance 1 more day cleanly
	var day2 := _run_day(ext, 2)
	_check("post-rejection day 2 advances cleanly",
		bool(day2.get("done", false))
		and not bool(day2.get("fatal", false))
		and int(day2.get("population_error", 0)) == 0
		and int(day2.get("money_error", 0)) == 0
		and int(day2.get("goods_error", 0)) == 0)

	# Post-rejection valid PKEC restore succeeds and restores exact hash_before
	var valid_pkec_ok := _restore_pkec(ext, valid_pkec)
	_check("post-rejection valid PKEC restore succeeds", valid_pkec_ok)
	_check("post-rejection valid PKEC restore matches hash_before",
		int(ext.get_economy_state_hash()) == hash_before)

	# Post-rejection valid ECP2 restore succeeds and restores exact hash_before
	var valid_ecp2_restore: Dictionary = ext.restore_economy_ecp2(valid_ecp2)
	_check("post-rejection valid ECP2 restore succeeds",
		bool(valid_ecp2_restore.get("ok", false)))
	_check("post-rejection valid ECP2 restore matches hash_before",
		int(ext.get_economy_state_hash()) == hash_before)

func _assert_live_unchanged(ext: Object, tag: String,
		hash_before: int, report_before: Dictionary) -> void:
	var hash_after: int = ext.get_economy_state_hash()
	var report_after: Dictionary = ext.get_economy_report()
	_check("%s: state hash unchanged" % tag, hash_after == hash_before)
	_check("%s: bootstrapped remains true" % tag, bool(report_after.get("bootstrapped", false)))
	_check("%s: last_committed_day unchanged" % tag,
		int(report_after.get("last_committed_day", -999)) == int(report_before.get("last_committed_day", -1)))
	_check("%s: cohort_count unchanged" % tag,
		int(report_after.get("cohort_count", -1)) == int(report_before.get("cohort_count", -2)))
	_check("%s: market_count unchanged" % tag,
		int(report_after.get("market_count", -1)) == int(report_before.get("market_count", -2)))
	_check("%s: building_group_count unchanged" % tag,
		int(report_after.get("building_group_count", -1)) == int(report_before.get("building_group_count", -2)))
	if hash_after != hash_before or not bool(report_after.get("bootstrapped", false)):
		print("  [DETAIL %s] hash_before=%d hash_after=%d bootstrapped=%s day=%s->%s cohorts=%s->%s" % [
			tag, hash_before, hash_after, str(report_after.get("bootstrapped", false)),
			str(report_before.get("last_committed_day", -1)), str(report_after.get("last_committed_day", -1)),
			str(report_before.get("cohort_count", -1)), str(report_after.get("cohort_count", -1))])

func _check(label: String, ok: bool) -> bool:
	_expect(label, ok)
	return ok

func _build_world_with_different_country(catalog: Dictionary) -> Object:
	var other := _new_ext(CELLS, 0.1)
	_instances.append(other)
	other.configure_country(catalog,
		{"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray()},
		CELLS, SEED)
	other.bootstrap_country({}, PackedByteArray([0, 0]))
	other.configure_economy(catalog, _native_profile(false, 1), CELLS, SEED)
	var signature: int = (catalog.signature_keys as PackedStringArray).find("worker|default")
	other.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([signature, signature]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([10000000, 10000000]),
	}, {})
	for day in range(2):
		_run_day(other, day)
	return other

func _configured(catalog: Dictionary, profile: Dictionary) -> Object:
	var ext := _new_ext(CELLS, 0.1)
	_instances.append(ext)
	if not _check("country configures", CountryTestHelper.configure_all_technologies(
			ext, catalog, CELLS, SEED)):
		return null
	var result: Dictionary = ext.configure_economy(catalog, profile, CELLS, SEED)
	if not _check("economy configures", bool(result.get("ok", false))):
		print("configuration result=", result)
		return null
	return ext

func _capture_pkec(ext: Object) -> Array[PackedByteArray]:
	var chunks: Array[PackedByteArray] = []
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		print("begin_economy_save=", begin)
		return chunks
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var done: Dictionary = ext.end_economy_save()
	if not bool(done.get("ok", false)):
		print("end_economy_save=", done)
		return []
	return chunks

func _restore_pkec(ext: Object, chunks: Array[PackedByteArray]) -> bool:
	var res: Dictionary = ext.begin_economy_restore()
	if not bool(res.get("ok", false)):
		print("valid pkec begin=", res)
		return false
	for chunk in chunks:
		res = ext.feed_economy_restore_chunk(chunk)
		if not bool(res.get("ok", false)):
			print("valid pkec feed=", res)
			return false
	res = ext.end_economy_restore()
	if not bool(res.get("ok", false)):
		print("valid pkec end=", res)
		return false
	return true
