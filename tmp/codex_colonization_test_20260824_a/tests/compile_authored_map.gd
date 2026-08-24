extends SceneTree

# Headless authored-map compiler. Reads PKAUTH, runs C++ post_base, writes PKMAP.
#
#   godot --headless --path Project/project-keynes --script res://tests/compile_authored_map.gd -- \
#     auth=.../map.pkauth out=.../map.pkmap

const PkmapIOScript = preload("res://scripts/geography/pkmap_io.gd")


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var args := _arguments()
	var auth_path := str(args.get("auth", "")).strip_edges()
	var out_path := str(args.get("out", "")).strip_edges()
	if auth_path.is_empty() or out_path.is_empty():
		push_error("[authored-compile] require auth= and out=")
		return 2
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[authored-compile] DCWorldExt unavailable; rebuild dots_ext.dll")
		return 3
	var auth: Dictionary = PkmapIOScript.read_pkauth(auth_path)
	if not bool(auth.get("ok", false)):
		push_error("[authored-compile] PKAUTH: %s" % String(auth.get("message", "")))
		return 2
	var width := int(auth.get("width", 0))
	var height := int(auth.get("height", 0))
	var n := int(auth.get("n_cells", width * height))
	var seed := int(auth.get("seed", 1))
	var sea_level := float(auth.get("sea_level", 0.5))
	if n != width * height or n <= 0:
		push_error("[authored-compile] n_cells=%d != %d*%d" % [n, width, height])
		return 2

	var qr: Dictionary = PkmapIOScript.odd_r_qr_arrays(width, height)
	var elevation: PackedFloat32Array = auth["elevation_arr"]
	var moisture: PackedFloat32Array = auth["moisture_arr"]
	var terrain: PackedByteArray = PkmapIOScript.initial_terrain_from_elevation(
		elevation, width, height, sea_level)
	var input := {
		"q_arr": qr["q_arr"],
		"r_arr": qr["r_arr"],
		"elevation_arr": elevation,
		"moisture_arr": moisture,
		"terrain_arr": terrain,
		"is_lake_seed_arr": auth.get("is_lake_seed_arr", PackedByteArray()),
	}

	var generator := MapGenerator.new()
	var cfg := MapConfig.make(width, height)
	cfg.sea_level = sea_level
	cfg.seed = seed
	var cfg_dict: Dictionary = generator._native_generation_cfg_dict(cfg)
	var profile_dict: Dictionary = generator._native_generation_profile_dict()

	var ext_obj: Object = ClassDB.instantiate("DCWorldExt")
	if ext_obj == null:
		push_error("[authored-compile] ClassDB.instantiate(DCWorldExt) failed")
		return 3
	if not ext_obj.has_method("run_native_world_generate_post_base_pass"):
		push_error("[authored-compile] missing run_native_world_generate_post_base_pass")
		return 3
	var post_res: Dictionary = ext_obj.run_native_world_generate_post_base_pass(
		seed, cfg_dict, profile_dict, input)
	if int(post_res.get("rc", -1)) != 0 or bool(post_res.get("fallback", true)):
		push_error("[authored-compile] post_base failed rc=%s fallback=%s reason=%s" % [
			str(post_res.get("rc", -1)),
			str(post_res.get("fallback", true)),
			String(post_res.get("fallback_reason", post_res.get("reason", "unknown"))),
		])
		return 4
	if int(post_res.get("n_cells", 0)) != n:
		push_error("[authored-compile] post_base n_cells mismatch")
		return 4

	var payload: Dictionary = PkmapIOScript.payload_from_native_result(post_res)
	var header := {
		"width": width,
		"height": height,
		"n_cells": n,
		"sea_level": sea_level,
		"seed": seed,
		"native_algorithm": String(post_res.get("native_algorithm", "")),
		"lake_count": int(post_res.get("lake_count", 0)),
		"river_count": int(post_res.get("river_count", 0)),
	}
	var written: Dictionary = PkmapIOScript.write_pkmap(out_path, header, payload)
	if not bool(written.get("ok", false)):
		push_error("[authored-compile] write PKMAP: %s" % String(written.get("message", "")))
		return 2
	print("[authored-compile] wrote %s n=%d lakes=%d rivers=%d fallback=false" % [
		out_path,
		n,
		int(post_res.get("lake_count", 0)),
		int(post_res.get("river_count", 0)),
	])
	return 0


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out
