extends "res://tests/economy/goods_storage_schema_test.gd"

# Public APIs only. PKEC supplies an explicit legal persisted fixture; the
# operation under test is the production ECP2 capture/restore, not a test codec.
# Full section37 bytes cover owner_slot and last_event_day, which the public
# per-cell inspector intentionally does not expose.
const CELLS := 2
const SEED := 42
const MOB_SECTION := 37
const ROW_BYTES := 34
var _instances: Array[Object] = []
var _evidence := {}

func _run() -> void:
	_execute()
	_instances.clear()
	print("STRATUM_SAVE_RESULT=" + JSON.stringify({
		"checks": _checks, "failures": _failures, "evidence": _evidence}))
	print("=== stratum save roundtrip: %d checks, %d failures ===" % [_checks, _failures])

func _execute() -> void:
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
	var committed := _run_day(base, 0)
	if not _check("base commits without accounting failure", bool(committed.get("done", false))
			and not bool(committed.get("fatal", false))
			and int(committed.get("population_error", 0)) == 0
			and int(committed.get("money_error", 0)) == 0
			and int(committed.get("goods_error", 0)) == 0):
		print("base report=", committed)
		return
	var country := _capture(base, true)
	var original := _capture(base, false)
	if country.is_empty() or original.is_empty():
		return
	var schema := original[0].decode_u16(4)
	if not _check("fixture uses current PKEC64", schema == 64):
		return
	var expected := _payload(profession, false)
	var other := _payload(profession, true)
	var seeded := _replace_mobilization(original, expected, schema)
	var empty := _replace_mobilization(original, PackedByteArray(), schema)
	var old_absent := _replace_mobilization(original, PackedByteArray(), 62, false)
	var source := _target(catalog, profile, country)
	if source == null or not _restore_pkec(source, seeded, "seed nonempty source"):
		return
	if not _check("source has all thirteen exact fields", _saved_payload(source) == expected):
		return
	var source_hash: int = source.get_economy_state_hash()
	var saved: Dictionary = source.capture_economy_ecp2(0)
	if not _check("nonempty production ECP2 capture succeeds", bool(saved.get("ok", false))):
		print("capture result=", saved)
		return
	var wire: PackedByteArray = saved.get("bytes", PackedByteArray())
	_evidence["source_rows_hex"] = expected.hex_encode()
	_evidence["source_state_hash"] = str(source_hash)
	_evidence["ecp2_schema"] = saved.get("schema_version", -1)
	_evidence["ecp2_contains_section37"] = _ecp2_has_mobilization(wire)
	_check("production ECP2 actually contains section37", bool(_evidence.ecp2_contains_section37))

	# A same-object roundtrip can hide dropped fields by retaining old memory.
	# The cold and deliberately different warm targets make that impossible.
	var cold := _target(catalog, profile, country)
	if cold == null:
		return
	_roundtrip(cold, wire, expected, source_hash, "cold")
	var warm := _target(catalog, profile, country)
	if warm == null or not _restore_pkec(warm,
			_replace_mobilization(original, other, schema), "seed different warm target"):
		return
	_check("warm fixture differs from source", _saved_payload(warm) == other and other != expected)
	_roundtrip(warm, wire, expected, source_hash, "warm")

	# An empty current save must clear rows from a previous world.
	var empty_source := _target(catalog, profile, country)
	if empty_source == null or not _restore_pkec(empty_source, empty, "seed empty source"):
		return
	var empty_hash: int = empty_source.get_economy_state_hash()
	var empty_saved: Dictionary = empty_source.capture_economy_ecp2(0)
	if not _check("empty production ECP2 capture succeeds", bool(empty_saved.get("ok", false))):
		return
	if not _restore_pkec(warm, seeded, "reseed warm before empty ECP2"):
		return
	_roundtrip(warm, empty_saved.get("bytes", PackedByteArray()), PackedByteArray(),
		empty_hash, "empty_current")

	# Exercise the existing PKEC62 decoder contract only. This uses today's
	# identical catalog and country identity, not a claim of old PKSV migration.
	if not _restore_pkec(warm, seeded, "reseed warm before PKEC62"):
		return
	if _restore_pkec(warm, old_absent, "existing PKEC62 structural compatibility"):
		_check("PKEC62 absence clears previous world rows", _saved_payload(warm).is_empty())
		_check("PKEC62 empty state hash equals current empty state",
			int(warm.get_economy_state_hash()) == empty_hash)

	# A rejected ECP2 must leave both authoritative rows and whole state intact.
	if not _restore_pkec(warm, seeded, "reseed warm before bad ECP2"):
		return
	var before_bad_hash: int = warm.get_economy_state_hash()
	var bad := wire.duplicate()
	bad[bad.size() - 1] ^= 1
	var rejected: Dictionary = warm.restore_economy_ecp2(bad)
	_check("corrupt ECP2 fails content checksum",
		String(rejected.get("reason", "")) == "ecp2_content_hash_mismatch")
	_check("rejected ECP2 preserves all rows and whole state",
		_saved_payload(warm) == expected and int(warm.get_economy_state_hash()) == before_bad_hash)
	# Removing the section while recalculating the outer checksum is a distinct
	# semantic error. Missing data must not be interpreted as a peaceful world;
	# the valid zero-record current section was exercised above.
	var missing := _without_mobilization(wire)
	var missing_result: Dictionary = warm.restore_economy_ecp2(missing)
	_check("current ECP2 missing section37 is rejected",
		String(missing_result.get("reason", "")) == "ecp2_stratum_mobilization_section_missing")
	_check("missing section rejection preserves all rows and whole state",
		_saved_payload(warm) == expected and int(warm.get_economy_state_hash()) == before_bad_hash)

func _check(label: String, ok: bool) -> bool:
	_expect(label, ok)
	return ok

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

func _target(catalog: Dictionary, profile: Dictionary,
		country: Array[PackedByteArray]) -> Object:
	var ext := _configured(catalog, profile)
	if ext == null:
		return null
	var result: Dictionary = ext.begin_country_restore()
	if not _check("country restore begins", bool(result.get("ok", false))):
		return null
	for chunk in country:
		result = ext.feed_country_restore_chunk(chunk)
		if not _check("country chunk accepted", bool(result.get("ok", false))):
			print("country feed=", result)
			return null
	result = ext.end_country_restore()
	return ext if _check("country restore completes", bool(result.get("ok", false))) else null

func _capture(ext: Object, country: bool) -> Array[PackedByteArray]:
	var chunks: Array[PackedByteArray] = []
	var begin: Dictionary = ext.begin_country_save(65536) if country else ext.begin_economy_save(65536)
	if not _check("capture begins", bool(begin.get("ok", false))):
		print("capture begin=", begin)
		return chunks
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(65536) if country else ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var done: Dictionary = ext.end_country_save() if country else ext.end_economy_save()
	_check("capture completes", bool(done.get("ok", false)))
	return chunks

func _restore_pkec(ext: Object, chunks: Array[PackedByteArray], label: String) -> bool:
	var result: Dictionary = ext.begin_economy_restore()
	if not _check(label + " begins", bool(result.get("ok", false))):
		print(label, " begin=", result)
		return false
	for chunk in chunks:
		result = ext.feed_economy_restore_chunk(chunk)
		if not bool(result.get("ok", false)):
			_check(label + " accepts all chunks", false)
			print(label, " feed=", result, " section=", chunk.decode_u16(6))
			return false
	result = ext.end_economy_restore()
	var ok := _check(label + " completes", bool(result.get("ok", false)))
	if not ok:
		print(label, " end=", result)
	return ok

func _saved_payload(ext: Object) -> PackedByteArray:
	var payload := PackedByteArray()
	var found := false
	for chunk in _capture(ext, false):
		if chunk.decode_u16(6) == MOB_SECTION:
			found = true
			_check("saved row framing is exact", chunk.size() == 16 + chunk.decode_u32(8) * ROW_BYTES)
			payload.append_array(chunk.slice(16))
	_check("PKEC writer emits section37 even when empty", found)
	return payload

func _roundtrip(ext: Object, wire: PackedByteArray, expected: PackedByteArray,
		expected_hash: int, label: String) -> void:
	var result: Dictionary = ext.restore_economy_ecp2(wire)
	_evidence[label + "_restore"] = result.duplicate(true)
	if not _check(label + " ECP2 restores", bool(result.get("ok", false))):
		print(label, " restore=", result)
		return
	var actual := _saved_payload(ext)
	var actual_hash: int = ext.get_economy_state_hash()
	_evidence[label + "_rows_hex"] = actual.hex_encode()
	_evidence[label + "_state_hash"] = str(actual_hash)
	_check(label + " all thirteen persisted fields match", actual == expected)
	_check(label + " whole state hash matches", actual_hash == expected_hash)

func _payload(profession: int, different: bool) -> PackedByteArray:
	var payload := PackedByteArray()
	payload.resize(2 * ROW_BYTES)
	for row in 2:
		var at := row * ROW_BYTES
		var delta := 137 if different else 0
		payload.encode_s32(at, row)
		payload.encode_u16(at + 4, profession)
		payload.encode_s32(at + 6, 0)
		payload.encode_u16(at + 10, 12345 + row * 1000 + delta)
		payload.encode_u16(at + 12, 2345 + row + delta)
		payload.encode_u16(at + 14, 32768 + row + delta)
		payload.encode_u16(at + 16, 54321 - row - delta)
		payload[at + 18] = 2 + row
		payload[at + 19] = 1 + row
		payload.encode_s32(at + 20, 17 + row + delta)
		payload.encode_s32(at + 24, 29 + row + delta)
		payload.encode_s32(at + 28, -1 if row == 0 else 0)
		payload.encode_u16(at + 32, 4567 + row + delta)
	return payload

func _replace_mobilization(chunks: Array[PackedByteArray], payload: PackedByteArray,
		schema: int, include_section: bool = true) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	for original_chunk in chunks:
		if original_chunk.decode_u16(6) == MOB_SECTION:
			continue
		var chunk := original_chunk.duplicate()
		# PKEC64 appends four i64 producer-history columns to each signal row.
		# The old structural fixture must use its actual 36-byte wire layout.
		if original_chunk.decode_u16(4) >= 64 and schema < 64 and chunk.decode_u16(6) == 8:
			chunk = original_chunk.slice(0, 16)
			for row in original_chunk.decode_u32(8):
				chunk.append_array(original_chunk.slice(16 + row * 68, 16 + row * 68 + 36))
			chunk.encode_u32(12, chunk.size() - 16)
		chunk.encode_u16(4, schema)
		if chunk.decode_u16(6) == 31 and include_section:
			var mob := PackedByteArray()
			mob.resize(16)
			mob.encode_u32(0, 0x43454b50)
			mob.encode_u16(4, schema)
			mob.encode_u16(6, MOB_SECTION)
			mob.encode_u32(8, payload.size() / ROW_BYTES)
			mob.encode_u32(12, payload.size())
			mob.append_array(payload)
			out.append(mob)
		out.append(chunk)
	return out

func _ecp2_has_mobilization(wire: PackedByteArray) -> bool:
	if wire.size() < 28 or wire.decode_u32(0) != 0x32504345:
		return false
	var at := 28 + wire.decode_u32(24)
	while at + 8 <= wire.size():
		var size := wire.decode_u32(at + 4)
		var begin := at + 8
		var end := begin + size
		if end > wire.size():
			return false
		var cursor := begin
		while cursor + 16 <= end and wire.decode_u32(cursor) == 0x43454b50:
			var length := wire.decode_u32(cursor + 12)
			if cursor + 16 + length > end:
				return false
			if wire.decode_u16(cursor + 6) == MOB_SECTION:
				return true
			cursor += 16 + length
		at = end
	return false

func _without_mobilization(wire: PackedByteArray) -> PackedByteArray:
	var at := 28 + wire.decode_u32(24)
	var out := wire.slice(0, at)
	while at + 8 <= wire.size():
		var bit := wire.decode_u32(at)
		var end := at + 8 + wire.decode_u32(at + 4)
		var cursor := at + 8
		var payload := PackedByteArray()
		while cursor + 16 <= end and wire.decode_u32(cursor) == 0x43454b50:
			var next := cursor + 16 + wire.decode_u32(cursor + 12)
			if wire.decode_u16(cursor + 6) != MOB_SECTION:
				payload.append_array(wire.slice(cursor, next))
			cursor = next
		payload.append_array(wire.slice(cursor, end))
		var header := PackedByteArray()
		header.resize(8)
		header.encode_u32(0, bit)
		header.encode_u32(4, payload.size())
		out.append_array(header)
		out.append_array(payload)
		at = end
	var hash_value: int = 1469598103934665603
	for byte in out.slice(24):
		hash_value = (hash_value ^ byte) * 1099511628211
	out.encode_u64(16, hash_value)
	return out
