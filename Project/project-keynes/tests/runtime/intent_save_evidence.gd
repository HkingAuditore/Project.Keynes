extends RefCounted

# Test-only: retain actual receipts and both encodings, including the existing
# PKEC non-idempotent re-encoding. Restore Country before Economy on the idle owner.
static func capture(ext: Object, restored: Object, operations: Array, configure_economy: Callable, country_modifier_restore_steps: int = 0) -> Dictionary:
	var receipts: Array = []
	var protocol: Dictionary = ext.get_country_report().get("economy_asset_transactions", {})
	for id in range(1, int(protocol.get("next_transaction_id", 0))):
		var receipt: Dictionary = ext.get_country_economy_asset_transaction(id)
		if int(receipt.get("operation", 0)) in operations:
			assert(bool(receipt.get("ok", false)))
			if int(receipt.operation) in [1, 9]:
				assert(bool(receipt.get("all_or_nothing", false)))
			assert(String(receipt.get("status_name", "")) == "completed")
			assert(bool(receipt.get("conservation_ok", false)))
			assert(int(receipt.get("committed_quantity", 0)) > 0 or int(receipt.get("committed_cash", 0)) > 0)
			receipts.append(receipt)
	for operation in operations:
		assert(receipts.any(func(row: Dictionary) -> bool: return int(row.operation) == operation))
	var country := save_chunks(ext, "country")
	var economy := save_chunks(ext, "economy")
	var before_hash := str(ext.get_economy_state_hash())
	for domain in ["country", "economy"]:
		if domain == "economy":
			assert(bool(configure_economy.call().get("ok", false)))
		assert(bool(restored.call("begin_" + domain + "_restore").get("ok", false)))
		for chunk in (country if domain == "country" else economy):
			assert(bool(restored.call("feed_" + domain + "_restore_chunk", chunk).get("ok", false)))
		assert(bool(restored.call("end_" + domain + "_restore").get("ok", false)))
	var after_country := save_chunks(restored, "country")
	var left := PackedByteArray()
	var right := PackedByteArray()
	for chunk in country: left.append_array(chunk)
	for chunk in after_country: right.append_array(chunk)
	var differences: Array = []
	assert(left.size() == right.size())
	for i in range(left.size()):
		if left[i] != right[i]: differences.append([i, left[i], right[i]])
	# Country ends with [Modifier byte count:u64][PKMD bytes][end:u32].
	# Colonization restores Modifier once explicitly, then again through Country.
	# Check that exact version increment at its structural position; content can
	# change the preceding Country size. Every other byte must remain identical.
	var expected_country := left.duplicate()
	assert(country_modifier_restore_steps in [0, 2])
	if country_modifier_restore_steps > 0:
		var modifier: PackedByteArray = ext.capture_modifier_domain(1)
		var offset := left.size() - 4 - modifier.size()
		assert(offset >= 8 and left.decode_u64(offset - 8) == modifier.size())
		assert(left.slice(offset, offset + modifier.size()) == modifier)
		assert(modifier.slice(0, 4).get_string_from_ascii() == "PKMD")
		# PKMD: magic:u32, schema:u32, domain:i32, catalog:u64, day:i64.
		var version_offset := offset + 28
		expected_country.encode_u64(version_offset, left.decode_u64(version_offset) + country_modifier_restore_steps)
	assert(expected_country == right)
	assert(str(ext.get_country_state_hash()) == str(restored.get_country_state_hash()))
	assert(before_hash == str(restored.get_economy_state_hash()))
	return {"receipts": receipts, "country_sha256": digest(country),
		"economy_sha256": digest(economy), "restored_economy_sha256": digest(save_chunks(restored, "economy")),
		"economy_state_hash": before_hash, "restored_country_sha256": digest(after_country),
		"country_reencoding_delta": differences}

static func save_chunks(restored: Object, domain: String) -> Array:
	assert(bool(restored.call("begin_" + domain + "_save", 65536).get("ok", false)))
	var chunks: Array = []
	while true:
		var chunk: PackedByteArray = restored.call("read_" + domain + "_save_chunk", 65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	assert(bool(restored.call("end_" + domain + "_save").get("ok", false)))
	return chunks

static func digest(chunks: Array) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for chunk in chunks:
		context.update(chunk)
	return context.finish().hex_encode()
