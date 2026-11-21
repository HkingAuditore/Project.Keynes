extends RefCounted

## Canonical framing and digest conversion for climate input identity. Catalog and topology caches stay with the generator.

static func _runtime_climate_hash_append(hashing, label: String, value) -> void:
	# Packed arrays are hashed as their native bytes (float32/int32/uint8
	# bit-patterns), while scalar metadata is framed as UTF-8 text. The field
	# labels and lengths make concatenation unambiguous and keep the reference
	# hash stable across runs without relying on Dictionary iteration order.
	hashing.update((label + "#").to_utf8_buffer())
	if value is PackedFloat32Array:
		var f32: PackedFloat32Array = value
		hashing.update(("f32:%d:" % f32.size()).to_utf8_buffer())
		hashing.update(f32.to_byte_array())
		return
	if value is PackedFloat64Array:
		var f64: PackedFloat64Array = value
		hashing.update(("f64:%d:" % f64.size()).to_utf8_buffer())
		hashing.update(f64.to_byte_array())
		return
	if value is PackedInt32Array:
		var i32: PackedInt32Array = value
		hashing.update(("i32:%d:" % i32.size()).to_utf8_buffer())
		hashing.update(i32.to_byte_array())
		return
	if value is PackedInt64Array:
		var i64: PackedInt64Array = value
		hashing.update(("i64:%d:" % i64.size()).to_utf8_buffer())
		hashing.update(i64.to_byte_array())
		return
	if value is PackedByteArray:
		var bytes: PackedByteArray = value
		hashing.update(("u8:%d:" % bytes.size()).to_utf8_buffer())
		hashing.update(bytes)
		return
	if value is PackedStringArray:
		var strings: PackedStringArray = value
		hashing.update(("str:%d:" % strings.size()).to_utf8_buffer())
		hashing.update("\n".join(strings).to_utf8_buffer())
		return
	if value is Array or value is Dictionary:
		hashing.update(var_to_bytes(value))
		return
	# str(), not String(): the String constructor rejects plain int/float/bool
	# arguments at runtime, which silently dropped every scalar knob from the
	# catalog hash instead of framing it.
	hashing.update(str(value).to_utf8_buffer())


static func _runtime_climate_hash_digest_value(digest: PackedByteArray) -> int:
	var value: int = 0
	# Seven bytes keep the result positive in Godot's signed 64-bit Variant int,
	# while retaining 56 bits of SHA-256 entropy. C++ rejects zero hashes.
	for i in range(mini(7, digest.size())):
		value = (value << 8) | int(digest[i])
	return maxi(1, value)


static func catalog_hash(map: MapData, cp: ClimateProfile) -> int:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update("runtime-climate-catalog-v1\n".to_utf8_buffer())
	_runtime_climate_hash_append(hashing, "abi", 3)
	_runtime_climate_hash_append(hashing, "width", int(map.width))
	_runtime_climate_hash_append(hashing, "height", int(map.height))
	_runtime_climate_hash_append(hashing, "cells", int(map.cell_count()))
	if cp != null:
		# Only immutable numeric/profile knobs belong in the catalog. Dynamic
		# day fields are deliberately excluded and remain input snapshot data.
		for field_name in PackedStringArray([
			"solar_amplitude", "lapse_rate", "sea_ice_freeze_threshold",
			"sea_ice_melt_threshold", "soil_water_capacity", "hydrology_enabled",
			"weather_advect_use_wind_vector", "veg_feedback_elev_decay",
		]):
			var field_value = cp.get(field_name)
			if field_value != null:
				_runtime_climate_hash_append(hashing, field_name, field_value)
	# Static map identity is included once per generated MapData instance. These
	# arrays are not re-read by the worker; they only detect a mismatched map.
	_runtime_climate_hash_append(hashing, "elevation", map.elevation_arr)
	_runtime_climate_hash_append(hashing, "lat_norm", map.cell_lat_norm_arr)
	_runtime_climate_hash_append(hashing, "terrain", map.terrain_arr)
	_runtime_climate_hash_append(hashing, "landform", map.landform_arr)
	_runtime_climate_hash_append(hashing, "water", map.is_water_arr)
	_runtime_climate_hash_append(hashing, "hydro_parent", map.hydro_parent_arr)
	_runtime_climate_hash_append(hashing, "neighbours", map.neighbor_indices_packed())
	return _runtime_climate_hash_digest_value(hashing.finish())
