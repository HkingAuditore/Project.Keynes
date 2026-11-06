extends RefCounted

# Test-only: retain actual receipts and both encodings, including the existing
# PKEC non-idempotent re-encoding. Restore Country before Economy on the idle owner.
static func capture(ext: Object, restored: Object, operations: Array, configure_economy: Callable, country_reencoding_delta: Array = []) -> Dictionary:
	var receipts: Array = []
	var protocol: Dictionary = ext.get_country_report().get("economy_asset_transactions", {})
	for id in range(1, int(protocol.get("next_transaction_id", 0))):
		var receipt: Dictionary = ext.get_country_economy_asset_transaction(id)
		if int(receipt.get("operation", 0)) in operations:
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
	# Most fixtures are byte-identical. The colony fixture records its existing
	# embedded Modifier version delta explicitly; never normalize those bytes.
	assert(differences == country_reencoding_delta)
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
