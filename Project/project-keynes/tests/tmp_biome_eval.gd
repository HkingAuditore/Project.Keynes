extends SceneTree

# Headless biome-distribution eval for [climate-zone-fix P1].
# Generates a full map with the real (C++) generation pipeline and dumps the
# land vegetation_arr histogram + terrain histogram + land temp/moisture
# percentiles, so the P1 decision-tree recalibration (MEDIT down, rainforest /
# subtropical-forest / savanna up) can be measured before/after.
#
#   godot --headless --path <proj> --script tests/tmp_biome_eval.gd --quit
#   optional user args: w=56 h=44 seed=717171

# Match production world config (main.gd @export defaults): 60x40, 2 continents,
# continent_size 0.9, sea_level 0.42, river_count 8 → ~1360 land cells (matches the
# user CSV). Generation+runtime moisture distribution is highly config-sensitive,
# so the headless biome eval must use the SAME config as the recorded game.
const SEED_DEFAULT := 717171
var MAP_W := 60
var MAP_H := 40
var SEED := SEED_DEFAULT
var WARMUP := 60
var SAMPLE := 120

# VEG enum order (vegetation_type.gd) — index == enum id.
const VEG_NAMES := [
	"NONE","POLAR_DESERT","TUNDRA","ALPINE_TUNDRA","ALPINE_MEADOW","TAIGA",
	"BOREAL_SHRUB","TEMP_DECIDUOUS","TEMP_CONIFER","TEMP_GRASSLAND","TEMP_STEPPE",
	"MEDIT_SHRUB","SUBTROPICAL_FOREST","SAVANNA","TROP_RAINFOREST","TROP_DRY_FOREST",
	"DESERT_SCRUB","XERIC_DESERT","OASIS_VEG","MANGROVE","SWAMP","MARSH",
	"KELP_FOREST","CORAL_REEF","CLOUD_FOREST","MONSOON_FOREST",
]
const TERRAIN_NAMES := [
	"OCEAN","COAST","PLAIN","GRASSLAND","FOREST","HILL","MOUNTAIN","DESERT","TUNDRA",
	"SNOW","SWAMP","JUNGLE","SAVANNA","TAIGA","STEPPE","SHRUBLAND","MANGROVE","GLACIER",
	"LAKE","REEF","SEA_ICE","KELP","DELTA","OASIS","SALT_FLAT","BADLANDS","COLD_DESERT",
	"CHAPARRAL","MOOR","FLOODPLAIN","MESA",
]


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("w="): MAP_W = int(s.substr(2))
		elif s.begins_with("h="): MAP_H = int(s.substr(2))
		elif s.begins_with("seed="): SEED = int(s.substr(5))
		elif s.begins_with("warmup="): WARMUP = int(s.substr(7))
		elif s.begins_with("sample="): SAMPLE = int(s.substr(7))
	print("=== biome eval (%dx%d seed=%d warmup=%d sample=%d) [climate-zone-fix P1] ===" % [MAP_W, MAP_H, SEED, WARMUP, SAMPLE])
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt missing"); quit(0); return

	var profile := _make_profile()
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
		print("  FAIL gen"); quit(1); return
	var n: int = map.soa_size()

	# Tick so season_refresh re-decides terrain/vegetation with RUNTIME temp/moisture
	# (stage_2_redecide). Accumulate the land vegetation histogram over a sample window
	# (terrain swings seasonally) to mirror the CSV aggregate methodology.
	var day := 0
	for w in range(WARMUP):
		day += 1
		gen.sus_tick_daily(null, day, float(day % 365) / 365.0)

	var isw: PackedByteArray = map.is_water_arr
	var veg_hist := {}
	var ter_hist := {}
	var land_cell_total := 0
	var land_samples := 0
	var land_moist: Array[float] = []
	var land_temp: Array[float] = []
	for s in range(SAMPLE):
		day += 1
		gen.sus_tick_daily(null, day, float(day % 365) / 365.0)
		var veg: PackedByteArray = map.vegetation_arr
		var ter: PackedByteArray = map.terrain_arr
		var moi: PackedFloat32Array = map.moisture_arr
		var tmp: PackedFloat32Array = map.temp_arr
		var land_this := 0
		for i in range(n):
			var water := i < isw.size() and isw[i] != 0
			if water:
				continue
			land_this += 1
			land_samples += 1
			var v := int(veg[i]) if i < veg.size() else 0
			veg_hist[v] = int(veg_hist.get(v, 0)) + 1
			var t := int(ter[i]) if i < ter.size() else 0
			ter_hist[t] = int(ter_hist.get(t, 0)) + 1
			# percentiles only from the final sample tick to keep arrays small
			if s == SAMPLE - 1:
				if i < moi.size(): land_moist.append(float(moi[i]))
				if i < tmp.size(): land_temp.append(float(tmp[i]))
		land_cell_total = land_this
	var land_n := maxi(1, land_samples)

	print("\n--- land vegetation histogram (n_land=%d, avg over %d sample ticks) ---" % [land_cell_total, SAMPLE])
	var veg_keys := veg_hist.keys()
	veg_keys.sort_custom(func(a, b): return int(veg_hist[a]) > int(veg_hist[b]))
	for v in veg_keys:
		var c: int = int(veg_hist[v])
		var nm: String = VEG_NAMES[v] if v >= 0 and v < VEG_NAMES.size() else ("veg%d" % v)
		print("  %-20s(%2d): %5d  (%.1f%%)" % [nm, v, c, 100.0 * c / max(1, land_n)])

	print("\n--- land terrain histogram ---")
	var ter_keys := ter_hist.keys()
	ter_keys.sort_custom(func(a, b): return int(ter_hist[a]) > int(ter_hist[b]))
	for t in ter_keys:
		var c: int = int(ter_hist[t])
		var nm: String = TERRAIN_NAMES[t] if t >= 0 and t < TERRAIN_NAMES.size() else ("ter%d" % t)
		print("  %-14s(%2d): %5d  (%.1f%%)" % [nm, t, c, 100.0 * c / max(1, land_n)])

	land_moist.sort()
	land_temp.sort()
	var _pct := func(arr: Array, label: String) -> void:
		if arr.size() == 0: return
		print("  %-12s p10=%.3f p25=%.3f p50=%.3f p75=%.3f p90=%.3f max=%.3f" % [
			label, arr[int(0.10*arr.size())], arr[int(0.25*arr.size())], arr[int(0.50*arr.size())],
			arr[int(0.75*arr.size())], arr[int(0.90*arr.size())], arr[arr.size()-1]])
	print("\n--- land field percentiles (threshold sanity) ---")
	_pct.call(land_moist, "moisture")
	_pct.call(land_temp, "temperature")

	# key P1 deltas vs prior CSV(164054): MEDIT 21.0%, RAINFOREST 1.0%, SUBTROP_FOREST 0.1%, SAVANNA 0.6%
	var pct := func(id: int) -> float: return 100.0 * float(int(veg_hist.get(id, 0))) / max(1, land_n)
	print("\n--- P1 key biomes (prior CSV in parens) ---")
	print("  MEDIT_SHRUB        : %.1f%%  (was 21.0%%)" % pct.call(11))
	print("  TROP_RAINFOREST    : %.1f%%  (was  1.0%%)" % pct.call(14))
	print("  SUBTROPICAL_FOREST : %.1f%%  (was  0.1%%)" % pct.call(12))
	print("  SAVANNA            : %.1f%%  (was  0.6%%)" % pct.call(13))
	print("  MONSOON_FOREST     : %.1f%%  (was 16.0%%)" % pct.call(25))
	print("  TROP_DRY_FOREST    : %.1f%%" % pct.call(15))
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
	return p
