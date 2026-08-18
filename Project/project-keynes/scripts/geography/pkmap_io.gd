class_name PkmapIO
extends RefCounted

const PKAUTH_MAGIC := "PKAU"
const PKMAP_MAGIC := "PKMP"
const FORMAT_VERSION := 1

const PAYLOAD_KEYS := [
	"q_arr", "r_arr", "s_arr",
	"elevation_arr", "moisture_arr", "base_moisture_arr",
	"temp_arr", "temp_baseline_arr", "temp_30d_arr", "temp_365d_arr",
	"terrain_arr", "base_terrain_arr", "landform_arr", "base_landform_arr",
	"vegetation_arr", "base_vegetation_arr", "cover_arr",
	"vegetation_vitality_arr", "soil_moisture_arr", "water_balance_30d_arr",
	"plant_available_water_arr", "vegetation_growth_pressure_arr",
	"vegetation_heat_stress_arr", "vegetation_drought_stress_arr",
	"vegetation_cold_stress_arr", "vegetation_regen_score_arr",
	"has_river_arr", "river_flow_arr", "river_downstream_arr", "hydro_parent_arr",
	"has_volcano_arr", "is_lake_seed_arr", "water_depth_arr", "is_water_arr",
]


static func odd_r_qr_arrays(width: int, height: int) -> Dictionary:
	var n := width * height
	var q_arr := PackedInt32Array()
	var r_arr := PackedInt32Array()
	q_arr.resize(n)
	r_arr.resize(n)
	for row in range(height):
		for col in range(width):
			var i := row * width + col
			var cube := HexUtils.offset_to_cube(col, row)
			q_arr[i] = cube.x
			r_arr[i] = cube.y
	return {"q_arr": q_arr, "r_arr": r_arr, "n_cells": n}


static func initial_terrain_from_elevation(
		elevation: PackedFloat32Array, width: int, height: int, sea_level: float) -> PackedByteArray:
	var n := width * height
	var terrain := PackedByteArray()
	terrain.resize(n)
	for row in range(height):
		for col in range(width):
			var i := row * width + col
			if float(elevation[i]) < sea_level:
				terrain[i] = TerrainType.TERRAIN.OCEAN
			else:
				# COAST is shallow WATER in this engine (pk_is_water_terrain).
				# Marking land-next-to-ocean as COAST makes whole coastlines is_water=1
				# and post_base skips redecide on water, so they stay flooded.
				terrain[i] = TerrainType.TERRAIN.PLAIN
	return terrain


static func read_pkauth(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _error("pkauth_missing", "PKAUTH 不存在：%s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 12:
		return _error("pkauth_truncated", "PKAUTH 已截断。")
	var magic := file.get_buffer(4).get_string_from_ascii()
	var version := int(file.get_32())
	var header_length := int(file.get_32())
	if magic != PKAUTH_MAGIC or version != FORMAT_VERSION or header_length <= 0:
		return _error("pkauth_header_invalid", "PKAUTH 头无效。")
	var parsed = JSON.parse_string(file.get_buffer(header_length).get_string_from_utf8())
	if not parsed is Dictionary:
		return _error("pkauth_header_invalid", "PKAUTH 头无法解析。")
	var header := parsed as Dictionary
	var width := int(header.get("width", 0))
	var height := int(header.get("height", 0))
	var n := width * height
	if width <= 0 or height <= 0 or int(header.get("n_cells", n)) != n:
		return _error("size_mismatch", "PKAUTH 尺寸无效。")
	var elevation := _read_f32_array(file, n)
	var moisture := _read_f32_array(file, n)
	var lake_seed := file.get_buffer(n)
	if elevation.size() != n or moisture.size() != n or lake_seed.size() != n:
		return _error("pkauth_truncated", "PKAUTH 数组截断。")
	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"header": header,
		"width": width,
		"height": height,
		"n_cells": n,
		"sea_level": float(header.get("sea_level", 0.5)),
		"seed": int(header.get("seed", 0)),
		"elevation_arr": elevation,
		"moisture_arr": moisture,
		"is_lake_seed_arr": lake_seed,
	}


static func write_pkmap(path: String, header_fields: Dictionary, payload: Dictionary) -> Dictionary:
	var bytes := var_to_bytes(payload)
	var digest := _sha256(bytes)
	var compressed := PackedByteArray() if bytes.is_empty() else bytes.compress(FileAccess.COMPRESSION_ZSTD)
	var header := header_fields.duplicate(true)
	header.merge({
		"magic": PKMAP_MAGIC,
		"format_version": FORMAT_VERSION,
		"generator_hash": SaveRepository.compatibility_hash(),
		"content_hash": digest,
		"uncompressed_length": bytes.size(),
		"compressed_length": compressed.size(),
	}, true)
	var header_bytes := JSON.stringify(header).to_utf8_buffer()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _error("pkmap_open_failed", "无法写入 PKMAP：%s" % path)
	file.store_buffer(PKMAP_MAGIC.to_ascii_buffer())
	file.store_32(FORMAT_VERSION)
	file.store_32(header_bytes.size())
	file.store_buffer(header_bytes)
	file.store_buffer(compressed)
	file.flush()
	file.close()
	return {"ok": true, "code": "ok", "message": "", "path": path, "header": header}


static func read_pkmap(path: String) -> Dictionary:
	var peeked := peek_pkmap(path)
	if not bool(peeked.get("ok", false)):
		return peeked
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error("pkmap_missing", "PKMAP 无法打开。")
	file.get_buffer(4)
	file.get_32()
	var header_length := int(file.get_32())
	file.get_buffer(header_length)
	var header: Dictionary = peeked.get("header", {})
	var uncompressed := int(header.get("uncompressed_length", -1))
	var compressed_length := int(header.get("compressed_length", file.get_length() - file.get_position()))
	var packed := file.get_buffer(compressed_length)
	var bytes := PackedByteArray()
	if uncompressed > 0:
		bytes = packed.decompress(uncompressed, FileAccess.COMPRESSION_ZSTD)
	if bytes.size() != uncompressed:
		return _error("pkmap_decompress_failed", "PKMAP 解压失败。")
	if _sha256(bytes) != String(header.get("content_hash", "")):
		return _error("pkmap_checksum_failed", "PKMAP content_hash 不匹配。")
	if String(header.get("generator_hash", "")) != SaveRepository.compatibility_hash():
		return _error("pkmap_incompatible", "PKMAP generator_hash 与当前生成器不兼容。")
	var payload = bytes_to_var(bytes)
	if not payload is Dictionary:
		return _error("pkmap_payload_invalid", "PKMAP payload 不是 Dictionary。")
	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"header": header,
		"payload": payload,
		"width": int(header.get("width", 0)),
		"height": int(header.get("height", 0)),
		"n_cells": int(header.get("n_cells", 0)),
		"sea_level": float(header.get("sea_level", 0.5)),
		"seed": int(header.get("seed", 0)),
	}


static func peek_pkmap(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _error("pkmap_missing", "PKMAP 不存在：%s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 12:
		return _error("pkmap_truncated", "PKMAP 已截断。")
	var magic := file.get_buffer(4).get_string_from_ascii()
	var version := int(file.get_32())
	var header_length := int(file.get_32())
	if magic != PKMAP_MAGIC or version != FORMAT_VERSION or header_length <= 0 \
			or header_length > file.get_length() - 12:
		return _error("pkmap_header_invalid", "PKMAP 头无效。")
	var parsed = JSON.parse_string(file.get_buffer(header_length).get_string_from_utf8())
	if not parsed is Dictionary:
		return _error("pkmap_header_invalid", "PKMAP 头无法解析。")
	var header := parsed as Dictionary
	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"header": header,
		"width": int(header.get("width", 0)),
		"height": int(header.get("height", 0)),
		"n_cells": int(header.get("n_cells", 0)),
		"sea_level": float(header.get("sea_level", 0.5)),
		"seed": int(header.get("seed", 0)),
	}


static func payload_from_native_result(res: Dictionary) -> Dictionary:
	var payload := {}
	for key in PAYLOAD_KEYS:
		if res.has(key):
			payload[key] = res[key]
	payload["n_cells"] = int(res.get("n_cells", 0))
	return payload


static func native_result_from_payload(payload: Dictionary, header: Dictionary) -> Dictionary:
	var res := payload.duplicate(true)
	res["rc"] = 0
	res["fallback"] = false
	res["path"] = "pkmap"
	res["n_cells"] = int(header.get("n_cells", res.get("n_cells", 0)))
	res["native_algorithm"] = "pkmap"
	return res


static func _read_f32_array(file: FileAccess, n: int) -> PackedFloat32Array:
	var buf := file.get_buffer(n * 4)
	if buf.size() != n * 4:
		return PackedFloat32Array()
	var peer := StreamPeerBuffer.new()
	peer.data_array = buf
	peer.big_endian = false
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		out[i] = peer.get_float()
	return out


static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		context.update(bytes)
	return context.finish().hex_encode()


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
