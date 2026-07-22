extends SceneTree

const MapGeneratorScript = preload("res://scripts/geography/map_generator.gd")

# Headless diagnostic for the "large-map sea-ice visual frozen while numbers change" bug.
#
# Symptom (user, real device): on small/medium maps sea ice renders/melts seasonally;
# on a LARGE map the sea-ice VISUAL never changes although sea_ice_frac numbers do.
#
# Sea-ice visual path:  cell_sea_ice_frac slot -> encode_cell_luts (dyn_lut.a)
#                       -> dynamic_visual_atlas_upload job uploads dyn_lut tex
#                       -> shader dyns.a -> water_pipeline w_ice.
#
# This probe runs the SAME production scheduler (gen.sus_tick_daily) at two map sizes
# and, per sampled day, measures three things for high-latitude WATER cells:
#   MAP_SIF    : MapData.sea_ice_frac_arr            (the "numbers" the user sees changing)
#   ENCODE_A   : dyn_lut.a from a forced bake_cell_luts (reads the C++ slot)  -> slot freshness
#   DVA run    : did the dynamic_visual_atlas_upload job actually run this tick (scheduler report)
#
# Interpretation:
#   MAP_SIF changes + DVA rarely/never runs            -> root cause B: visual job starved (size-gated)
#   MAP_SIF changes + DVA runs but ENCODE_A frozen     -> root cause A: cell_sea_ice_frac slot stale
#   MAP_SIF changes + DVA runs + ENCODE_A changes      -> not reproduced headless (GPU/driver upload path)
#
#   godot --headless --path <proj> --script tests/tmp_seaice_visual_eval.gd --quit
#   optional user args: seed=717171 warmup=120 sample=240 sizes=60x40,100x64 minlat=0.78

var SEED := 717171
var WARMUP := 120
var SAMPLE := 240
var MINLAT := 0.78
var SIZES := [Vector2i(60, 40), Vector2i(100, 64)]


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("seed="): SEED = int(s.substr(5))
		elif s.begins_with("warmup="): WARMUP = int(s.substr(7))
		elif s.begins_with("sample="): SAMPLE = int(s.substr(7))
		elif s.begins_with("minlat="): MINLAT = float(s.substr(7))
		elif s.begins_with("sizes="):
			SIZES = []
			for tok in s.substr(6).split(",", false):
				var wh := str(tok).split("x", false)
				if wh.size() == 2:
					SIZES.append(Vector2i(int(wh[0]), int(wh[1])))
	print("=== sea-ice visual eval (seed=%d warmup=%d sample=%d minlat=%.2f) ===" % [
		SEED, WARMUP, SAMPLE, MINLAT])
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt missing"); quit(0); return
	for sz in SIZES:
		_run_case(int(sz.x), int(sz.y))
	print("=== done ===")
	quit(0)


func _run_case(w: int, h: int) -> void:
	var profile := _make_profile()
	var cfg: MapConfig = MapConfig.make(w, h)
	cfg.seed = SEED
	cfg.num_continents = 2
	cfg.sea_level = 0.42
	cfg.continent_size = 0.9
	cfg.river_count = 8
	cfg.climate_profile = profile
	var gen = MapGeneratorScript.new()
	gen.climate_profile = profile
	var generated: Dictionary = await gen.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	var world = generated.get("world_data", null)
	if map == null or world == null:
		print("  [%dx%d] FAIL: no map/world" % [w, h]); return
	var n: int = map.soa_size()
	var isw: PackedByteArray = map.is_water_arr
	var lat: PackedFloat32Array = map.cell_lat_norm_arr
	var lw: int = int(world.lut_dims.x)
	var lh: int = int(world.lut_dims.y)

	# High-latitude water cells = sea-ice candidates.
	var polar: PackedInt32Array = PackedInt32Array()
	for i in range(n):
		if i < isw.size() and isw[i] == 0:
			continue
		var la := absf(float(lat[i])) if i < lat.size() else 0.0
		if la >= MINLAT:
			polar.append(i)
	if polar.size() == 0:
		print("  [%dx%d] no polar water cells at minlat=%.2f" % [w, h, MINLAT]); return

	var baker = gen._baker
	var dva = gen._dynamic_visual_atlas_upload_job

	var sif_min := {}
	var sif_max := {}
	var enc_min := {}
	var enc_max := {}
	for c in polar:
		sif_min[c] = 1e9; sif_max[c] = -1e9
		enc_min[c] = 999; enc_max[c] = -1

	var day := 0
	for _i in range(WARMUP):
		day += 1
		gen.sus_tick_daily(null, day, float(day % 365) / 365.0)

	var dva_ran := 0
	var dva_skip := {}
	var encode_path_gdscript := 0
	var encode_path_gdext := 0
	for _s in range(SAMPLE):
		day += 1
		gen.sus_tick_daily(null, day, float(day % 365) / 365.0)

		# 1) numbers (MapData)
		var sif: PackedFloat32Array = map.sea_ice_frac_arr
		for c in polar:
			var v := float(sif[c]) if c < sif.size() else 0.0
			if v < sif_min[c]: sif_min[c] = v
			if v > sif_max[c]: sif_max[c] = v

		# 2) did the visual upload job actually run this tick?
		var rep: Dictionary = gen._sus.report_last_tick()
		var jrep: Dictionary = rep.get(&"dynamic_visual_atlas_upload", {})
		if jrep.is_empty():
			jrep = rep.get("dynamic_visual_atlas_upload", {})
		var reason := str(jrep.get("skipped_reason", ""))
		if reason == "":
			dva_ran += 1
		else:
			dva_skip[reason] = int(dva_skip.get(reason, 0)) + 1

		# 3) slot freshness: force a bake and read dyn_lut.a directly from the encode bytes
		var brep: Dictionary = baker.bake_cell_luts(map, world, true, false)
		var path := str(brep.get("lut_encode_path", brep.get("path", "")))
		if path == "gdext": encode_path_gdext += 1
		else: encode_path_gdscript += 1
		var dyn = brep.get("dyn_lut", null)
		if dyn is PackedByteArray and dyn.size() >= lw * lh * 4:
			for c in polar:
				var off := c * 4 + 3
				if off < dyn.size():
					var a := int(dyn[off])
					if a < enc_min[c]: enc_min[c] = a
					if a > enc_max[c]: enc_max[c] = a

	# Aggregate per-cell amplitudes.
	var sif_amp_sum := 0.0
	var sif_amp_max := 0.0
	var enc_amp_sum := 0.0
	var enc_amp_max := 0
	var enc_frozen_cells := 0
	for c in polar:
		var sa := float(sif_max[c]) - float(sif_min[c])
		if sif_max[c] < -1e8: sa = 0.0
		sif_amp_sum += sa
		if sa > sif_amp_max: sif_amp_max = sa
		var ea := int(enc_max[c]) - int(enc_min[c])
		if enc_max[c] < 0: ea = 0
		enc_amp_sum += float(ea)
		if ea > enc_amp_max: enc_amp_max = ea
		# cell whose numbers move >5% but encoded byte never moves -> visually frozen
		if sa > 0.05 and ea <= 1:
			enc_frozen_cells += 1

	var np := float(polar.size())
	print("\n  --- [%dx%d] n=%d  lut=%dx%d  polar_water=%d ---" % [
		w, h, n, lw, lh, polar.size()])
	print("    MAP_SIF  amplitude  avg=%.3f  max=%.3f   (numbers; expect >0)" % [
		sif_amp_sum / maxf(1.0, np), sif_amp_max])
	print("    ENCODE_A amplitude  avg=%.2f  max=%d  (dyn_lut.a byte 0..255; slot freshness)" % [
		enc_amp_sum / maxf(1.0, np), enc_amp_max])
	print("    encode path:  gdext=%d  gdscript=%d" % [encode_path_gdext, encode_path_gdscript])
	print("    DVA upload job: ran=%d / %d ticks   skipped=%s" % [
		dva_ran, SAMPLE, str(dva_skip)])
	print("    polar cells whose numbers move but encoded byte is frozen: %d / %d" % [
		enc_frozen_cells, polar.size()])
	if dva != null:
		print("    DVA last breakdown: %s" % str(gen.sus_dynamic_visual_atlas_breakdown()))


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var p: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	p.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	p.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	p.native_shadow_diff_enabled = false
	p.native_climate_round_active_owner_enabled = true
	p.native_weather_transaction_active_owner_enabled = true
	p.native_ocean_physical_active_owner_enabled = true
	p.weather_field_enabled = true
	p.native_daily_spread_across_ticks = false
	return p
