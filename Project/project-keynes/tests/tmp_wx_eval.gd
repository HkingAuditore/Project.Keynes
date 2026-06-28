extends SceneTree

# Headless weather-quality eval. Reproduces the tile_data_record CSV analysis
# (weather-type histogram, per-cell variety, land/water field means, key field
# correlations) so weather-model changes can be measured before/after.
#
#   godot --headless --path <proj> --script tests/tmp_wx_eval.gd --quit
#   optional user args: warmup=60 sample=200 w=56 h=44

const SEED := 717171

var WARMUP := 90
var SAMPLE := 240
var MAP_W := 56
var MAP_H := 44
var P3_OFF := false  # p3off=1 → reset P3 precip knobs to pre-rebalance values for A/B

# WeatherType.WT: 0 CLEAR 1 RAIN 2 STORM 3 BLIZZARD 4 DROUGHT 5 FOG 6 HEATWAVE 7 MONSOON
const TYPE_NAMES := ["CLEAR","RAIN","STORM","BLIZZARD","DROUGHT","FOG","HEATWAVE","MONSOON"]


class Corr:
	var n := 0
	var mx := 0.0
	var my := 0.0
	var sx := 0.0
	var sy := 0.0
	var sxy := 0.0
	func add(x: float, y: float) -> void:
		n += 1
		var dx := x - mx
		var dy := y - my
		mx += dx / n
		my += dy / n
		sx += dx * (x - mx)
		sy += dy * (y - my)
		sxy += dx * (y - my)
	func r() -> float:
		if n < 2 or sx <= 0.0 or sy <= 0.0:
			return NAN
		return sxy / sqrt(sx * sy)


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("warmup="): WARMUP = int(s.substr(7))
		elif s.begins_with("sample="): SAMPLE = int(s.substr(7))
		elif s.begins_with("w="): MAP_W = int(s.substr(2))
		elif s.begins_with("h="): MAP_H = int(s.substr(2))
		elif s.begins_with("p3off="): P3_OFF = int(s.substr(6)) != 0
	print("=== weather eval (warmup=%d sample=%d %dx%d seed=%d p3_off=%s) ===" % [WARMUP, SAMPLE, MAP_W, MAP_H, SEED, str(P3_OFF)])
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt missing"); quit(0); return

	var profile := _make_profile()
	var cfg: MapConfig = MapConfig.make(MAP_W, MAP_H)
	cfg.seed = SEED
	cfg.num_continents = 3
	cfg.sea_level = 0.58
	cfg.continent_size = 0.72
	cfg.climate_profile = profile
	var gen := MapGenerator.new()
	gen.climate_profile = profile
	var generated: Dictionary = gen.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null) as MapData
	if map == null:
		print("  FAIL gen"); quit(0); return
	var n: int = map.soa_size()

	var day := 0
	for w in range(WARMUP):
		day += 1
		gen.sus_tick_daily(null, day, float(day % 365) / 365.0)

	var type_hist := {}
	var target_hist := {}
	var cell_types := {}
	var cell_last := {}
	var cell_changes := {}
	var land_sum := {}
	var water_sum := {}
	var land_n := 0
	var water_n := 0
	var fields := ["vapor","cloud","precip","conv","moisture","temp","tanom","windspd","instab"]
	for f in fields:
		land_sum[f] = 0.0
		water_sum[f] = 0.0
	var c_cv := Corr.new()  # cloud vs vapor
	var c_pv := Corr.new()  # precip vs vapor
	var c_pc := Corr.new()  # precip vs conv
	var c_pt := Corr.new()  # precip vs temp
	var c_cm := Corr.new()  # cloud vs moisture
	var c_vm := Corr.new()  # vapor vs moisture
	var c_ptw := Corr.new() # precip vs temp, WARM LAND only (temp>0.5)
	var c_pvw := Corr.new() # precip vs vapor, WARM LAND only
	var c_pcw := Corr.new() # precip vs conv,  WARM LAND only
	var warm_land_n := 0
	var land_vapor: Array[float] = []
	var land_temp: Array[float] = []
	var land_precip: Array[float] = []
	var water_precip: Array[float] = []
	var land_cloud: Array[float] = []
	var water_cloud: Array[float] = []
	# sea-ice diagnostics
	var ice_bucket_sum := {}   # temp-bucket(int temp*10) -> sum sea_ice_frac (water only)
	var ice_bucket_n := {}
	var ice_deltas: Array[float] = []  # |sea_ice_frac - prev| per water cell per tick
	var prev_sif: PackedFloat32Array = PackedFloat32Array()
	var frozen_cells := 0      # water cells with frac>=0.72 (terrain threshold), summed over ticks
	var water_cell_ticks := 0
	# per-cell temporal variance of precip/cloud (diagnose static-field vs threshold-misplacement)
	var pp_sum := PackedFloat32Array(); pp_sum.resize(n)
	var pp_sq := PackedFloat32Array(); pp_sq.resize(n)
	var cl_sum := PackedFloat32Array(); cl_sum.resize(n)
	var cl_sq := PackedFloat32Array(); cl_sq.resize(n)
	var pp_min := PackedFloat32Array(); pp_min.resize(n)
	var pp_max := PackedFloat32Array(); pp_max.resize(n)
	for i in range(n):
		pp_min[i] = 1.0e9; pp_max[i] = -1.0e9

	for s in range(SAMPLE):
		day += 1
		gen.sus_tick_daily(null, day, float(day % 365) / 365.0)
		var wt: PackedByteArray = map.weather_type_arr
		var tgt: PackedByteArray = map.weather_target_type_arr
		var vap: PackedFloat32Array = map.weather_vapor_arr
		var cld: PackedFloat32Array = map.weather_cloud_arr
		var prc: PackedFloat32Array = map.weather_precip_arr
		var cnv: PackedFloat32Array = map.weather_convergence_arr
		var moi: PackedFloat32Array = map.moisture_arr
		var tmp: PackedFloat32Array = map.temp_arr
		var tan: PackedFloat32Array = map.temp_anomaly_arr
		var wsp: PackedFloat32Array = map.wind_speed_arr
		var ins: PackedFloat32Array = map.weather_instability_arr
		var isw: PackedByteArray = map.is_water_arr
		var sif: PackedFloat32Array = map.sea_ice_frac_arr
		var has_prev := prev_sif.size() == n
		for i in range(n):
			var t := int(wt[i]) if i < wt.size() else 0
			type_hist[t] = int(type_hist.get(t, 0)) + 1
			if i < tgt.size():
				var tg := int(tgt[i])
				target_hist[tg] = int(target_hist.get(tg, 0)) + 1
			if not cell_types.has(i): cell_types[i] = {}
			(cell_types[i] as Dictionary)[t] = true
			if cell_last.has(i) and int(cell_last[i]) != t:
				cell_changes[i] = int(cell_changes.get(i, 0)) + 1
			cell_last[i] = t
			var vv := float(vap[i]) if i < vap.size() else 0.0
			var cc := float(cld[i]) if i < cld.size() else 0.0
			var pp := float(prc[i]) if i < prc.size() else 0.0
			var nn := float(cnv[i]) if i < cnv.size() else 0.0
			var mm := float(moi[i]) if i < moi.size() else 0.0
			var tt := float(tmp[i]) if i < tmp.size() else 0.0
			var ta := float(tan[i]) if i < tan.size() else 0.0
			var ws := float(wsp[i]) if i < wsp.size() else 0.0
			var ib := float(ins[i]) if i < ins.size() else 0.0
			pp_sum[i] += pp; pp_sq[i] += pp * pp
			cl_sum[i] += cc; cl_sq[i] += cc * cc
			if pp < pp_min[i]: pp_min[i] = pp
			if pp > pp_max[i]: pp_max[i] = pp
			var water := i < isw.size() and isw[i] != 0
			var bucket: Dictionary = water_sum if water else land_sum
			bucket["vapor"] += vv; bucket["cloud"] += cc; bucket["precip"] += pp
			bucket["conv"] += nn; bucket["moisture"] += mm; bucket["temp"] += tt
			bucket["tanom"] += ta; bucket["windspd"] += ws; bucket["instab"] += ib
			if water:
				water_n += 1
				if water_precip.size() < 200000: water_precip.append(pp)
				if water_cloud.size() < 200000: water_cloud.append(cc)
			else:
				land_n += 1
				if land_vapor.size() < 200000: land_vapor.append(vv)
				if land_temp.size() < 200000: land_temp.append(tt)
				if land_precip.size() < 200000: land_precip.append(pp)
				if land_cloud.size() < 200000: land_cloud.append(cc)
				if tt > 0.5:
					warm_land_n += 1
					c_ptw.add(pp, tt); c_pvw.add(pp, vv); c_pcw.add(pp, nn)
			c_cv.add(cc, vv); c_pv.add(pp, vv); c_pc.add(pp, nn)
			c_pt.add(pp, tt); c_cm.add(cc, mm); c_vm.add(vv, mm)
			if water and i < sif.size():
				var ice := float(sif[i])
				var tb := int(clampf(tt, 0.0, 0.999) * 10.0)
				ice_bucket_sum[tb] = float(ice_bucket_sum.get(tb, 0.0)) + ice
				ice_bucket_n[tb] = int(ice_bucket_n.get(tb, 0)) + 1
				water_cell_ticks += 1
				if ice >= 0.72: frozen_cells += 1
				if has_prev and ice_deltas.size() < 300000:
					ice_deltas.append(absf(ice - float(prev_sif[i])))
		prev_sif = sif.duplicate()

	var tot := 0
	for k in type_hist: tot += int(type_hist[k])
	print("\n--- weather_type histogram (current) ---")
	for k in range(8):
		var v := int(type_hist.get(k, 0))
		print("  %-9s(%d): %8d  (%.2f%%)" % [TYPE_NAMES[k], k, v, 100.0 * v / max(1, tot)])
	print("--- weather_target_type histogram ---")
	for k in range(8):
		var v := int(target_hist.get(k, 0))
		print("  %-9s(%d): %8d  (%.2f%%)" % [TYPE_NAMES[k], k, v, 100.0 * v / max(1, tot)])

	var variety := {}
	for i in cell_types:
		var d: int = (cell_types[i] as Dictionary).size()
		variety[d] = int(variety.get(d, 0)) + 1
	print("\n--- per-cell type variety (distinct types over sample) ---")
	for d in range(1, 9):
		if variety.has(d): print("  %d distinct: %d cells" % [d, int(variety[d])])
	var never := 0
	for i in range(n):
		if int(cell_changes.get(i, 0)) == 0: never += 1
	print("  cells that NEVER changed type: %d / %d (%.1f%%)" % [never, n, 100.0 * never / max(1, n)])

	# --- per-cell temporal variance of the FIELD (precip/cloud) ---
	# Static-field root-cause test: if most cells have ~0 temporal std in precip AND cloud,
	# the field itself is frozen (dynamics/psi too weak) -> threshold re-tuning cannot help.
	# If cells fluctuate (nonzero std) but type never flips, thresholds are mis-centered.
	var pstd: Array[float] = []
	var cstd: Array[float] = []
	var prange_static := 0   # cells whose precip varied < 0.005 over whole sample
	var crange_static := 0
	var sf := float(max(1, SAMPLE))
	for i in range(n):
		var pm := pp_sum[i] / sf
		var pv := maxf(0.0, pp_sq[i] / sf - pm * pm)
		var ps := sqrt(pv)
		var cm := cl_sum[i] / sf
		var cv := maxf(0.0, cl_sq[i] / sf - cm * cm)
		var cs := sqrt(cv)
		pstd.append(ps); cstd.append(cs)
		if (pp_max[i] - pp_min[i]) < 0.005: prange_static += 1
		if cs < 0.005: crange_static += 1
	pstd.sort(); cstd.sort()
	print("\n--- per-cell FIELD temporal variance over %d-day sample ---" % SAMPLE)
	if pstd.size() > 0:
		print("  precip std/cell  p50=%.4f p90=%.4f p99=%.4f max=%.4f" % [
			pstd[int(0.5*pstd.size())], pstd[int(0.9*pstd.size())],
			pstd[min(pstd.size()-1,int(0.99*pstd.size()))], pstd[pstd.size()-1]])
		print("  cloud  std/cell  p50=%.4f p90=%.4f p99=%.4f max=%.4f" % [
			cstd[int(0.5*cstd.size())], cstd[int(0.9*cstd.size())],
			cstd[min(cstd.size()-1,int(0.99*cstd.size()))], cstd[cstd.size()-1]])
	print("  cells with precip range < 0.005 (frozen precip): %d / %d (%.1f%%)" % [prange_static, n, 100.0*prange_static/max(1,n)])
	print("  cells with cloud  std   < 0.005 (frozen cloud ): %d / %d (%.1f%%)" % [crange_static, n, 100.0*crange_static/max(1,n)])

	# --- precip/cloud VALUE percentiles (land vs water) for classifier-threshold re-centering ---
	var _pct := func(arr: Array, label: String) -> void:
		if arr.size() == 0: return
		arr.sort()
		print("  %-16s p50=%.4f p75=%.4f p85=%.4f p90=%.4f p95=%.4f p99=%.4f" % [
			label, arr[int(0.50*arr.size())], arr[int(0.75*arr.size())], arr[int(0.85*arr.size())],
			arr[int(0.90*arr.size())], arr[int(0.95*arr.size())], arr[min(arr.size()-1,int(0.99*arr.size()))]])
	print("\n--- precip/cloud value percentiles (for threshold re-centering) ---")
	_pct.call(land_precip, "land precip")
	_pct.call(water_precip, "water precip")
	_pct.call(land_cloud, "land cloud")
	_pct.call(water_cloud, "water cloud")

	print("\n--- land/water field means ---")
	print("  %-10s %10s %10s" % ["field", "LAND", "WATER"])
	for f in fields:
		print("  %-10s %10.5f %10.5f" % [f, float(land_sum[f]) / max(1, land_n), float(water_sum[f]) / max(1, water_n)])
	land_vapor.sort()
	if land_vapor.size() > 0:
		var lv := land_vapor
		print("  land vapor p10=%.4f p50=%.4f p90=%.4f p99=%.4f" % [
			lv[int(0.1 * lv.size())], lv[int(0.5 * lv.size())],
			lv[int(0.9 * lv.size())], lv[min(lv.size()-1, int(0.99 * lv.size()))]])
	land_temp.sort()
	if land_temp.size() > 0:
		var lt := land_temp
		print("  land temp  p10=%.4f p50=%.4f p90=%.4f p99=%.4f" % [
			lt[int(0.1 * lt.size())], lt[int(0.5 * lt.size())],
			lt[int(0.9 * lt.size())], lt[min(lt.size()-1, int(0.99 * lt.size()))]])
	print("  warm-land (temp>0.5) samples: %d (%.1f%% of land)" % [warm_land_n, 100.0 * warm_land_n / max(1, land_n)])

	print("\n--- field correlations (Welford) ---")
	print("  r(cloud , vapor )=%+.3f   <- should be strongly POSITIVE" % c_cv.r())
	print("  r(precip, vapor )=%+.3f   <- should be POSITIVE" % c_pv.r())
	print("  r(precip, conv  )=%+.3f   <- should be POSITIVE" % c_pc.r())
	print("  r(precip, temp  )=%+.3f" % c_pt.r())
	print("  r(cloud , moist )=%+.3f" % c_cm.r())
	print("  r(vapor , moist )=%+.3f" % c_vm.r())
	print("  --- WARM LAND only (temp>0.5) ---")
	print("  r(precip, temp  | warm)=%+.3f   <- pathology if strongly POSITIVE" % c_ptw.r())
	print("  r(precip, vapor | warm)=%+.3f" % c_pvw.r())
	print("  r(precip, conv  | warm)=%+.3f" % c_pcw.r())
	print("\n--- SEA ICE diagnostics ---")
	print("  mean sea_ice_frac by temp bucket (water cells):")
	for tb in range(0, 10):
		if ice_bucket_n.has(tb):
			var mn: float = float(ice_bucket_sum[tb]) / float(max(1, int(ice_bucket_n[tb])))
			print("    temp[%.1f-%.1f): mean_ice=%.3f  (n=%d)" % [tb*0.1, tb*0.1+0.1, mn, int(ice_bucket_n[tb])])
	print("  frozen-cell ratio (frac>=0.72): %.1f%% of water-cell-ticks" % [100.0 * frozen_cells / max(1, water_cell_ticks)])
	ice_deltas.sort()
	if ice_deltas.size() > 0:
		var idl := ice_deltas
		print("  single-tick |delta sea_ice| p50=%.4f p90=%.4f p99=%.4f max=%.4f  (daily_delta_cap=0.07)" % [
			idl[int(0.5*idl.size())], idl[int(0.9*idl.size())],
			idl[min(idl.size()-1, int(0.99*idl.size()))], idl[idl.size()-1]])
	print("=== done ===")
	quit(0)


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
	if P3_OFF:
		# Pre-P3 baseline: revert the 4 precip-seasonality knobs to historic C++ defaults.
		p.weather_field_thermal_conv_precip = 0.30
		p.weather_field_stratiform_gain = 1.0
		p.weather_field_omega_ascent_gain = 0.40
		p.weather_cool_season_vapor_floor = 0.0
	return p
