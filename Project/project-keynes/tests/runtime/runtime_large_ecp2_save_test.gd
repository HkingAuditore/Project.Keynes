extends SceneTree

# Synthetic ECP2 crosses the old 64 MiB cap without requiring a long game.
# The zero-filled audit payload lets the fixture calculate FNV in O(log n).
const LIMIT := 64 * 1024 * 1024
const OFFSET := 1469598103934665603
const PRIME := 1099511628211
const PKSR_SECTION_MASK_OFFSET := 85
const PKSR_ECP2_SECTION := 1 << 11
const PKSR_EFFECT_TRANSPORT_SECTION := 1 << 13
const EMPTY_EFFECT_TRANSPORT_SIZE := 28
var _failures := 0
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var ext := DCWorldExt.new()
	# Matches runtime_economy_ecp2.h through the native descriptor, not PKEC's schema.
	var checkpoint_format: Dictionary = ext.get_economy_checkpoint_format()
	_expect("published ECP2 contract remains ABI4/schema63",
		int(checkpoint_format.abi_version) == 4 and int(checkpoint_format.schema_version) == 63)
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW", "graph_coverage_complete": false,
		"day": 0, "speed_days_per_second": 0.0, "paused": true})
	_expect("shadow host starts", bool(started.get("ok", false)))
	ext.request_runtime_save(9002)
	var saved: Dictionary = {}
	for attempt in 500:
		saved = ext.poll_runtime_save(9002)
		if bool(saved.get("ready", false)):
			break
		OS.delay_msec(10)
	_expect("base PKSR captured", bool(saved.get("ready", false)))
	ext.request_runtime_stop()
	for attempt in 500:
		if String(ext.get_runtime_thread_report().get("simulation_host_state", "")) == "STOPPED":
			break
		OS.delay_msec(10)
	var base: PackedByteArray = saved.get("bytes", PackedByteArray())
	if base.is_empty():
		_finish()
		return
	base.resize(base.size() - 8)
	var section_mask := base.decode_u32(PKSR_SECTION_MASK_OFFSET)
	var effect_transport := PackedByteArray()
	if (section_mask & PKSR_EFFECT_TRANSPORT_SECTION) != 0:
		# ETQ2 is the last PKSR section. The idle fixture has no entries in
		# its four queues, so insert the synthetic ECP2 before this tail.
		var tail_offset := base.size() - EMPTY_EFFECT_TRANSPORT_SIZE
		var empty_tail := tail_offset >= 0 and base.decode_u32(tail_offset) == 0x32515445
		for offset in range(tail_offset + 12, base.size(), 4):
			empty_tail = empty_tail and base.decode_u32(offset) == 0
		_expect("idle save has an empty Effect transport tail", empty_tail)
		if not empty_tail:
			_finish()
			return
		effect_transport = base.slice(tail_offset)
		base.resize(tail_offset)
	base.encode_u32(PKSR_SECTION_MASK_OFFSET, section_mask | PKSR_ECP2_SECTION)

	var prefix := PackedByteArray()
	prefix.resize(24 + 4 + 128)
	prefix.encode_u32(0, 0x32504345)
	prefix.encode_u32(4, int(checkpoint_format.abi_version))
	prefix.encode_u32(8, int(checkpoint_format.schema_version))
	prefix.encode_u32(12, 0x2ffff)
	prefix.encode_u32(24, 128)
	prefix.encode_u32(28, int(checkpoint_format.schema_version))
	prefix.encode_u32(32, int(checkpoint_format.abi_version))
	prefix.encode_u32(152, 2) # envelope hash_version
	var suffix := PackedByteArray()
	var zero_count := LIMIT + 17
	for bit in range(1, 18):
		if bit == 16:
			continue
		var target := prefix if bit <= 12 else suffix
		var at := target.size()
		target.resize(at + 8)
		target.encode_u32(at, 1 << bit)
		target.encode_u32(at + 4, zero_count if bit == 12 else 0)
		if bit <= 12:
			prefix = target
		else:
			suffix = target
	prefix.encode_u64(16, _hash_parts(prefix.slice(24), zero_count, suffix))
	var zeros := PackedByteArray()
	zeros.resize(zero_count)
	var full := prefix + zeros + suffix
	var full_checksum := _hash_parts(prefix, zero_count, suffix)
	var healthy := _bundle(base, full, full_checksum,
		_hash_parts(_section_prefix(base, full.size()) + prefix, zero_count, suffix),
		effect_transport)
	var restored: Dictionary = ext.restore_runtime_bundle(healthy)
	_expect("complete ECP2 above 64 MiB restores", bool(restored.get("restored", false)))
	_expect("complete ECP2 needs no recovery", not bool(restored.get("recovered_truncated_ecp2", false)))
	healthy = PackedByteArray()
	var truncated := full.slice(0, LIMIT)
	var cut_checksum := _hash_parts(prefix, LIMIT - prefix.size(), PackedByteArray())
	var legacy := _bundle(base, truncated, cut_checksum,
		_hash_parts(_section_prefix(base, LIMIT) + prefix, LIMIT - prefix.size(), PackedByteArray()),
		effect_transport)
	var rejected: Dictionary = ext.restore_runtime_bundle(legacy)
	_expect("truncation without complete duplicate is rejected",
		String(rejected.get("code", "")) == "ecp2_content_hash_mismatch")
	restored = ext.restore_runtime_bundle(legacy, full)
	_expect("verified duplicate recovers legacy truncation", bool(restored.get("restored", false))
		and bool(restored.get("recovered_truncated_ecp2", false)))
	full[28] ^= 1
	rejected = ext.restore_runtime_bundle(legacy, full)
	_expect("different duplicate prefix is rejected", not bool(rejected.get("ok", false)))
	full[28] ^= 1
	full[full.size() - 1] ^= 1
	rejected = ext.restore_runtime_bundle(legacy, full)
	_expect("corrupt duplicate tail is rejected", not bool(rejected.get("ok", false)))
	full[full.size() - 1] ^= 1
	legacy[legacy.size() - 1] ^= 1
	rejected = ext.restore_runtime_bundle(legacy, full)
	_expect("corrupt PKSR checksum cannot enter recovery",
		String(rejected.get("code", "")) == "runtime_bundle_checksum_failed")
	_finish()


func _section_prefix(base: PackedByteArray, size: int) -> PackedByteArray:
	var header := PackedByteArray()
	header.resize(8)
	header.encode_u32(0, 0x32504345)
	header.encode_u32(4, size)
	return base + header


func _bundle(base: PackedByteArray, payload: PackedByteArray, checksum: int,
		body_hash: int, effect_transport: PackedByteArray) -> PackedByteArray:
	var section_checksum := PackedByteArray()
	section_checksum.resize(8)
	section_checksum.encode_u64(0, checksum)
	var trailer := section_checksum + effect_transport
	var bundle_checksum := PackedByteArray()
	bundle_checksum.resize(8)
	bundle_checksum.encode_u64(0, _fnv(trailer, body_hash))
	return _section_prefix(base, payload.size()) + payload + trailer + bundle_checksum


func _hash_parts(prefix: PackedByteArray, zeros: int, suffix: PackedByteArray) -> int:
	var hash := _fnv(prefix, OFFSET)
	var factor := PRIME
	while zeros > 0:
		if (zeros & 1) != 0:
			hash *= factor
		factor *= factor
		zeros >>= 1
	return _fnv(suffix, hash)


func _fnv(bytes: PackedByteArray, hash: int) -> int:
	for byte in bytes:
		hash = (hash ^ byte) * PRIME
	return hash


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	print("=== runtime large ECP2 save: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
