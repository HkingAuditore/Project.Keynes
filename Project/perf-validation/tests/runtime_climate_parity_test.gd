extends SceneTree

# S1 acceptance: the production reference path and the worker must reduce the
# same Climate state to the same value.
#
# Before this existed, the worker compared its FNV-1a state_hash (which mixes in
# generation, rng_state and history bookkeeping) against a GDScript SHA-256
# digest over a different field set. That equality could only hold by a 2^-56
# collision, so SHADOW Climate could never commit a single day. These checks
# pin the property that makes the comparison possible at all.

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("checks: %d, failures: %d" % [_checks, _failures])
	if _failures == 0:
		print("runtime climate parity: PASS")
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: %s" % label)


func _run() -> void:
	print("=== runtime climate parity contract ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt available", false)
		return
	var ext := DCWorldExt.new()
	for method in [
		"runtime_climate_parity_contract_test",
		"compute_runtime_climate_parity_hash",
		"get_runtime_climate_parity_fields",
	]:
		_expect("%s is exported" % method, ext.has_method(method))
	if _failures > 0:
		return

	var contract: Dictionary = ext.runtime_climate_parity_contract_test()
	_expect("C++ parity contract self-test passes (%s)" % str(contract.get("code", "")),
		bool(contract.get("ok", false)))
	var comparable := int(contract.get("fields_comparable", 0))
	var total := int(contract.get("fields_total", 0))
	print("field table: %d comparable of %d, parity version %s" % [
		comparable, total, str(contract.get("parity_version", 0))])
	_expect("at least one comparable field", comparable > 0)
	_expect("comparable set is a subset", comparable <= total)

	_check_field_table(ext, total)
	_check_two_paths_agree(ext, comparable)
	_check_bookkeeping_is_excluded(ext)
	_check_rejects_incomplete_input(ext)


func _check_field_table(ext: Object, expected_total: int) -> void:
	var table: Array = ext.get_runtime_climate_parity_fields()
	_expect("field table is exposed with %d entries" % expected_total,
		table.size() == expected_total)
	var seen := {}
	var excluded := 0
	for entry in table:
		var name := String(entry.get("name", ""))
		_expect("field has a name", name != "")
		_expect("field %s is unique" % name, not seen.has(name))
		seen[name] = true
		var comparability := String(entry.get("comparability", ""))
		if comparability != "comparable":
			excluded += 1
			# An excluded field must say why, otherwise a real gap looks like
			# an intentional omission.
			_expect("excluded field %s carries a note" % name,
				String(entry.get("note", "")) != "")
			print("  excluded %-32s %-14s %s" % [
				name, comparability, String(entry.get("note", ""))])
		_expect("field %s declares a kind" % name,
			String(entry.get("kind", "")) in ["f32", "i32", "u8"])
	print("excluded fields: %d" % excluded)

	# The table drives the MapData mapping, so every referenced array must
	# actually exist on MapData or the reference would silently hash zeros.
	var map := MapData.new(4, 4)
	for entry in table:
		if String(entry.get("comparability", "")) != "comparable":
			continue
		var array_name := String(entry.get("map_data_array", ""))
		var value = map.get(array_name)
		_expect("MapData exposes %s for field %s" % [array_name, String(entry.get("name", ""))],
			value != null and typeof(value) in [
				TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_BYTE_ARRAY])


func _build_fields(ext: Object, cells: int, seed_offset: float) -> Dictionary:
	var fields := {}
	fields["cell_count"] = cells
	fields["climate_anomaly"] = 0.125
	for entry in ext.get_runtime_climate_parity_fields():
		if String(entry.get("comparability", "")) != "comparable":
			continue
		var name := String(entry.get("name", ""))
		var kind := String(entry.get("kind", ""))
		match kind:
			"f32":
				var floats := PackedFloat32Array()
				floats.resize(cells)
				for i in range(cells):
					floats[i] = seed_offset + float(i) * 0.5
				fields[name] = floats
			"i32":
				var ints := PackedInt32Array()
				ints.resize(cells)
				for i in range(cells):
					ints[i] = i
				fields[name] = ints
			"u8":
				var bytes := PackedByteArray()
				bytes.resize(cells)
				for i in range(cells):
					bytes[i] = i % 7
				fields[name] = bytes
	return fields


func _check_two_paths_agree(ext: Object, comparable: int) -> void:
	var cells := 12
	var fields := _build_fields(ext, cells, 1.5)
	var first: Dictionary = ext.compute_runtime_climate_parity_hash(fields)
	_expect("reference reduction succeeds (%s)" % str(first.get("code", "")),
		bool(first.get("ok", false)))
	if not bool(first.get("ok", false)):
		print("  missing: %s" % str(first.get("missing_fields", [])))
		return
	_expect("every comparable field was hashed",
		int(first.get("fields_hashed", 0)) == comparable)
	var hash_a := int(first.get("parity_hash", 0))
	_expect("reference hash is non-zero", hash_a != 0)

	# Same state twice must reduce identically; a hash that depends on call
	# order or on transient state would make daily comparison meaningless.
	var second: Dictionary = ext.compute_runtime_climate_parity_hash(
		_build_fields(ext, cells, 1.5))
	_expect("reduction is deterministic across calls",
		int(second.get("parity_hash", 0)) == hash_a)

	# A different physical state must reduce differently, otherwise the
	# comparison would pass for any input at all.
	var changed := _build_fields(ext, cells, 1.5)
	var temperature: PackedFloat32Array = changed["temperature"]
	temperature[3] += 0.25
	changed["temperature"] = temperature
	var third: Dictionary = ext.compute_runtime_climate_parity_hash(changed)
	_expect("a changed field changes the hash",
		int(third.get("parity_hash", 0)) != hash_a)

	# Cell count is part of the reduction, so two map sizes cannot collide.
	var resized: Dictionary = ext.compute_runtime_climate_parity_hash(
		_build_fields(ext, cells + 1, 1.5))
	_expect("cell count participates in the reduction",
		int(resized.get("parity_hash", 0)) != hash_a)


func _check_bookkeeping_is_excluded(ext: Object) -> void:
	# The reference path has no generation or rng state to supply. If the
	# reduction depended on them, supplying only physical fields could not
	# produce a hash the worker also reaches, which was the original defect.
	var fields := _build_fields(ext, 8, -2.0)
	var baseline: Dictionary = ext.compute_runtime_climate_parity_hash(fields)
	if not bool(baseline.get("ok", false)):
		_expect("baseline reduction for bookkeeping check", false)
		return
	var with_noise := fields.duplicate(true)
	for ignored_key in ["generation", "climate_generation", "committed_day",
			"rng_state", "annual_rng_state", "history_cursor",
			"annual_temperature_drift", "temperature_history"]:
		with_noise[ignored_key] = 987654321
	var noisy: Dictionary = ext.compute_runtime_climate_parity_hash(with_noise)
	_expect("worker bookkeeping keys cannot influence the reference hash",
		int(noisy.get("parity_hash", 0)) == int(baseline.get("parity_hash", 0)))

	var anomaly := fields.duplicate(true)
	anomaly["climate_anomaly"] = 0.875
	var shifted: Dictionary = ext.compute_runtime_climate_parity_hash(anomaly)
	_expect("climate anomaly is part of the reduction",
		int(shifted.get("parity_hash", 0)) != int(baseline.get("parity_hash", 0)))


func _check_rejects_incomplete_input(ext: Object) -> void:
	# A partial reference must fail loudly. Hashing absent arrays as zeros
	# would surface later as a fake Climate divergence.
	var fields := _build_fields(ext, 6, 0.5)
	fields.erase("temperature")
	var partial: Dictionary = ext.compute_runtime_climate_parity_hash(fields)
	_expect("an incomplete reference is rejected", not bool(partial.get("ok", true)))
	_expect("rejection names the missing field",
		String(partial.get("code", "")) == "climate_parity_fields_missing" \
			and Array(partial.get("missing_fields", [])).has("temperature"))

	var short_fields := _build_fields(ext, 6, 0.5)
	var truncated: PackedFloat32Array = short_fields["moisture"]
	truncated.resize(3)
	short_fields["moisture"] = truncated
	var mismatched: Dictionary = ext.compute_runtime_climate_parity_hash(short_fields)
	_expect("a wrong-length array is rejected", not bool(mismatched.get("ok", true)))

	var no_cells := _build_fields(ext, 6, 0.5)
	no_cells.erase("cell_count")
	var headless: Dictionary = ext.compute_runtime_climate_parity_hash(no_cells)
	_expect("a missing cell_count is rejected", not bool(headless.get("ok", true)))
