extends SceneTree

# Headless maritime-moderation eval for [climate-zone-fix P2].
# Proves the coastal "distance-to-sea" season-offset damping actually shrinks the
# annual temperature swing of coastal land (necessary condition for Cfb), by an
# A/B over maritime_season_damp ∈ {0.0 (off), 0.45 (on)} on the SAME seed/map.
#
#   godot --headless --path <proj> --script tests/tmp_maritime_eval.gd --quit
#   optional user args: w=60 h=40 seed=717171 warmup=365 sample=365 decay=4.0
#
# For each damp value we generate the production map, run a full warmup year to
# reach quasi-steady seasonal state, then track per-cell min/max temp over a
# sample year → annual swing = max-min. Land cells are bucketed by maritime_factor
# (coastal≈1 / inland≈0). Expectation: with damp=0 swing is ~flat across buckets;
# with damp=0.45 the coastal bucket swing drops markedly (≈ damp*factor reduction),
# and mid-latitude coastal cells gain a low-swing "oceanic (Cfb-like)" signature.

const SEED_DEFAULT := 717171
var MAP_W := 60
var MAP_H := 40
var SEED := SEED_DEFAULT
var WARMUP := 365
var SAMPLE := 365
var DECAY := 4.0
var DAMP_A := 0.45   # old default
var DAMP_B := 0.55   # new default ([2026-06-28夜] bumped to grow Cfb)


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("w="): MAP_W = int(s.substr(2))
		elif s.begins_with("h="): MAP_H = int(s.substr(2))
		elif s.begins_with("seed="): SEED = int(s.substr(5))
		elif s.begins_with("warmup="): WARMUP = int(s.substr(7))
		elif s.begins_with("sample="): SAMPLE = int(s.substr(7))
		elif s.begins_with("decay="): DECAY = float(s.substr(6))
		elif s.begins_with("dampa="): DAMP_A = float(s.substr(6))
		elif s.begins_with("dampb="): DAMP_B = float(s.substr(6))
	print("=== maritime eval (%dx%d seed=%d warmup=%d sample=%d decay=%.1f) [climate-zone-fix P2] ===" % [
		MAP_W, MAP_H, SEED, WARMUP, SAMPLE, DECAY])
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt missing"); quit(0); return

	var off := _run_case(DAMP_A)
	var on := _run_case(DAMP_B)
	if off.is_empty() or on.is_empty():
		print("  FAIL: a case produced no data"); quit(1); return

	print("\n========== A/B SUMMARY (annual temp swing by maritime bucket) ==========")
	print("  bucket            damp=%.2f      damp=%.2f     Δ(B-A)" % [DAMP_A, DAMP_B])
	var labels := ["coastal(f>0.6)", "near(0.3-0.6)", "inland(f<0.1)"]
	for k in ["coastal", "near", "inland"]:
		var i := ["coastal", "near", "inland"].find(k)
		var so: float = off["swing"][k]
		var sn: float = on["swing"][k]
		print("  %-16s  %8.4f       %8.4f     %+8.4f" % [labels[i], so, sn, sn - so])
	print("\n  coastal swing reduction (B vs A): %.1f%%" % [
		100.0 * (off["swing"]["coastal"] - on["swing"]["coastal"]) / maxf(0.0001, off["swing"]["coastal"])])
	print("  mid-lat coastal Cfb-like (low swing + COOL summer): damp=%.2f -> %d  damp=%.2f -> %d cells" % [
		DAMP_A, int(off["cfb_like"]), DAMP_B, int(on["cfb_like"])])
	print("=== done ===")
	quit(0)


func _run_case(damp: float) -> Dictionary:
	var profile := _make_profile()
	profile.maritime_season_damp = damp
	profile.maritime_decay_cells = DECAY
	var cfg: MapConfig = MapConfig.make(MAP_W, MAP_H)
	cfg.seed = SEED
	cfg.num_continents = 2
	cfg.sea_level = 0.42
	cfg.continent_size = 0.9
	cfg.river_count = 8
	cfg.climate_profile = profile
	var gen := MapGenerator.new()
	gen.climate_profile = profile
	var generated: Dictionary = gen.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	if map == null:
		return {}
	var n: int = map.soa_size()
	var isw: PackedByteArray = map.is_water_arr
	var mar: PackedFloat32Array = gen._ensure_maritime_factor(map, DECAY)
	var lat: PackedFloat32Array = map.cell_lat_norm_arr

	var day := 0
	for w in range(WARMUP):
		day += 1
		gen.sus_tick_daily(null, day, float(day % 365) / 365.0)

	var tmin := PackedFloat32Array(); tmin.resize(n)
	var tmax := PackedFloat32Array(); tmax.resize(n)
	for i in range(n):
		tmin[i] = 1e9
		tmax[i] = -1e9
	var tmean := PackedFloat32Array(); tmean.resize(n)
	for s in range(SAMPLE):
		day += 1
		gen.sus_tick_daily(null, day, float(day % 365) / 365.0)
		var tmp: PackedFloat32Array = map.temp_arr
		for i in range(n):
			if i >= isw.size() or isw[i] != 0:
				continue
			var t := float(tmp[i]) if i < tmp.size() else 0.0
			if t < tmin[i]: tmin[i] = t
			if t > tmax[i]: tmax[i] = t
			tmean[i] += t

	# Bucket annual swing by maritime factor.
	var sum := {"coastal": 0.0, "near": 0.0, "inland": 0.0}
	var cnt := {"coastal": 0, "near": 0, "inland": 0}
	var cfb_like := 0
	for i in range(n):
		if i >= isw.size() or isw[i] != 0:
			continue
		var f := float(mar[i]) if i < mar.size() else 0.0
		var swing := float(tmax[i]) - float(tmin[i])
		var mean := tmean[i] / float(maxi(1, SAMPLE))
		var bucket := ""
		if f > 0.6: bucket = "coastal"
		elif f >= 0.3: bucket = "near"
		elif f < 0.1: bucket = "inland"
		if bucket != "":
			sum[bucket] += swing
			cnt[bucket] = int(cnt[bucket]) + 1
		# Cfb-like proxy (matches wx_koppen Cfb gate): mid-lat coastal, low swing,
		# and a COOL summer (annual max temp < 0.60) — the Cfb≠Cfa discriminator.
		var latn := absf(float(lat[i])) if i < lat.size() else 0.0
		var mid_lat := latn >= 0.30 and latn <= 0.75
		var summer_max := float(tmax[i])
		if mid_lat and f > 0.5 and swing < 0.26 and summer_max < 0.60 and mean > 0.30:
			cfb_like += 1
	var swing_avg := {}
	for k in ["coastal", "near", "inland"]:
		swing_avg[k] = float(sum[k]) / float(maxi(1, int(cnt[k])))
	print("  [damp=%.2f] land bucket counts: coastal=%d near=%d inland=%d | swing coastal=%.4f near=%.4f inland=%.4f | cfb_like=%d" % [
		damp, int(cnt["coastal"]), int(cnt["near"]), int(cnt["inland"]),
		swing_avg["coastal"], swing_avg["near"], swing_avg["inland"], cfb_like])
	return {"swing": swing_avg, "cfb_like": cfb_like}


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
