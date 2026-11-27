extends RefCounted

## 物种保底（bio guarantee）：一张地图不该因为“某个物种一格都没有”而让整条科技线断掉
## （芦苇收割是野生稻采集/湿地稻作/稻田水利/精准灌溉的硬前置）。播种结果里 occupied=0
## 的物种按下面的阶梯逐级放宽**只对该物种生效的播种输入**，再向原生播种 pass 重发请求：
##   1. 去掉植被掩码（气候、地貌标志、载体仍然成立）
##   2. 去掉地貌标志（河湖/湿地/高地/干旱等）
##   3. 去掉载体资源（旱地/牧场/种植园承载力）
##   4. 气候带放宽到 persist 容差内（每日 pass 会剔除超出容差的植株，所以只能放到容差内）
## 放宽只作用于播种请求：日常推进继续用目录定义，保底种群能稳定存活，扩散仍受原规则约束。
## 气候容差必须与 gdext/src/world_ext_bio.cpp 的 kPersistClimateMargin（0.12）对齐。

const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")

const LEVELS: Array = [
	{"id": "drop_vegetation", "drop_veg": true, "drop_flags": false,
		"drop_carrier": false, "widen_climate": false, "absolve_climate": false},
	{"id": "drop_habitat_flags", "drop_veg": true, "drop_flags": true,
		"drop_carrier": false, "widen_climate": false, "absolve_climate": false},
	{"id": "drop_carrier", "drop_veg": true, "drop_flags": true,
		"drop_carrier": true, "widen_climate": false, "absolve_climate": false},
	{"id": "widen_climate", "drop_veg": true, "drop_flags": true,
		"drop_carrier": true, "widen_climate": true, "absolve_climate": false},
	{"id": "map_extremes", "drop_veg": true, "drop_flags": true,
		"drop_carrier": true, "widen_climate": false, "absolve_climate": true},
]
const MANUAL_LEVEL_ID := "manual_relict"
const MANUAL_MAX_PER_CELL: int = 3
const CLIMATE_MARGIN: float = 0.11
const ELEV_MARGIN: float = 0.075
const FILL_KEEP: float = 0.08
const MAX_COST: int = 3
const MUTABLE_KEYS := [
	"species_veg_mask0", "species_veg_mask1", "species_flags",
	"species_carrier_index", "species_carrier_alt_index",
	"species_temp_lo", "species_temp_hi", "species_moist_lo",
	"species_moist_hi", "species_elev_lo", "species_elev_hi",
	"species_fill_keep", "species_max_cost",
]


## 返回 {ok, seed_res, relaxed_levels, attempts, unplaceable}。relaxed_levels 与物种顺序对齐：
## -1 = 一枪命中，>=0 = 最终生效的保底阶梯，-2 = 阶梯用尽仍无法安置（极端世界）。
## 只有 occupied=0 的物种会被放宽，其它物种的播种结果保持不变。
## run_seed 由调用方提供（原生 run_bio_seed_pass 的封装）：本文件不直接持有原生句柄。
static func run(knobs: Dictionary, seed_res: Dictionary, run_seed: Callable) -> Dictionary:
	if not run_seed.is_valid():
		return {"ok": false, "reason": "seed_request_missing"}
	var species_count := (knobs.get("species_signal_ids", PackedInt32Array()) as PackedInt32Array).size()
	var relaxed := PackedInt32Array()
	relaxed.resize(species_count)
	relaxed.fill(-1)
	var result: Dictionary = {
		"ok": true,
		"seed_res": seed_res,
		"relaxed_levels": relaxed,
		"attempts": 1,
		"unplaceable": PackedStringArray(),
	}
	if species_count <= 0 or not bool(seed_res.get("ok", false)):
		return result
	var working: Dictionary = knobs
	var has_copy := false
	for level in range(LEVELS.size()):
		var occupied: PackedInt32Array = seed_res.get(
			"occupied_cell_counts", PackedInt32Array())
		var failing := PackedInt32Array()
		for species in range(species_count):
			if species < occupied.size() and int(occupied[species]) > 0:
				continue
			failing.append(species)
		if failing.is_empty():
			break
		if not has_copy:
			working = mutable_knobs(knobs)
			has_copy = true
		for species in failing:
			relax_species(working, species, level)
			relaxed[species] = level
		var relaxed_res: Dictionary = run_seed.call(working)
		result["attempts"] = int(result.get("attempts", 1)) + 1
		if not bool(relaxed_res.get("ok", false)):
			return {"ok": false, "reason": String(relaxed_res.get("reason", "guarantee_seed_failed"))}
		seed_res = relaxed_res
		result["seed_res"] = seed_res
	_place_manual_relicts(knobs, seed_res, relaxed)
	var occupied_final: PackedInt32Array = seed_res.get(
		"occupied_cell_counts", PackedInt32Array())
	var unplaceable := PackedStringArray()
	for species in range(species_count):
		if species < occupied_final.size() and int(occupied_final[species]) > 0:
			continue
		relaxed[species] = -2
		unplaceable.append(species_name(knobs, species))
	result["relaxed_levels"] = relaxed
	result["unplaceable"] = unplaceable
	return result


## 最后一级兜底：小图上生态行会（食物/放牧/纤维/特产）会互相挤满格位，原生播种
## 因此仍可能给不出格子。这里按“离该物种气候中心最近且未达 3 物种上限”的陆地格
## 直接补一格（只放宽行会互斥，不突破每格 3 物种上限），并同步占用数组与计数。
static func _place_manual_relicts(knobs: Dictionary, seed_res: Dictionary,
		relaxed: PackedInt32Array) -> int:
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	var occupied: PackedInt32Array = seed_res.get(
		"occupied_cell_counts", PackedInt32Array())
	var n := occupancy.size()
	if n <= 0 or occupied.is_empty():
		return 0
	var species_bits: PackedInt32Array = knobs.get(
		"species_occupancy_bits", PackedInt32Array())
	var is_water: PackedByteArray = knobs.get("is_water", PackedByteArray())
	var temp: PackedFloat32Array = knobs.get("temperature", PackedFloat32Array())
	var moist: PackedFloat32Array = knobs.get("moisture", PackedFloat32Array())
	var elev: PackedFloat32Array = knobs.get("elevation", PackedFloat32Array())
	if is_water.size() != n or temp.size() != n or moist.size() != n or elev.size() != n:
		return 0
	var temp_lo: PackedFloat32Array = knobs["species_temp_lo"]
	var temp_hi: PackedFloat32Array = knobs["species_temp_hi"]
	var moist_lo: PackedFloat32Array = knobs["species_moist_lo"]
	var moist_hi: PackedFloat32Array = knobs["species_moist_hi"]
	var elev_lo: PackedFloat32Array = knobs["species_elev_lo"]
	var elev_hi: PackedFloat32Array = knobs["species_elev_hi"]
	var placed := 0
	for species in range(mini(species_bits.size(), mini(occupied.size(), relaxed.size()))):
		if int(occupied[species]) > 0:
			continue
		var bit := int(species_bits[species])
		if bit < 0 or bit >= 32:
			continue
		if species >= mini(temp_lo.size(), mini(temp_hi.size(), mini(
				moist_lo.size(), mini(moist_hi.size(), mini(elev_lo.size(), elev_hi.size()))))):
			continue
		var mask := 1 << bit
		var t_mid := 0.5 * (float(temp_lo[species]) + float(temp_hi[species]))
		var m_mid := 0.5 * (float(moist_lo[species]) + float(moist_hi[species]))
		var e_mid := 0.5 * (float(elev_lo[species]) + float(elev_hi[species]))
		var best := -1
		var best_score := INF
		for cell in range(n):
			if is_water[cell] != 0:
				continue
			var cell_bits := int(occupancy[cell])
			if (cell_bits & mask) != 0:
				best = cell
				break
			if _popcount(cell_bits) >= MANUAL_MAX_PER_CELL:
				continue
			var score := absf(float(temp[cell]) - t_mid) \
				+ absf(float(moist[cell]) - m_mid) \
				+ absf(float(elev[cell]) - e_mid)
			if score < best_score:
				best_score = score
				best = cell
		if best < 0:
			continue
		if (int(occupancy[best]) & mask) == 0:
			occupancy[best] = int(occupancy[best]) | mask
			occupied[species] = int(occupied[species]) + 1
			placed += 1
		relaxed[species] = LEVELS.size()
	seed_res["occupancy_bits"] = occupancy
	seed_res["occupied_cell_counts"] = occupied
	return placed


static func _popcount(value: int) -> int:
	var bits := value
	var count := 0
	while bits != 0:
		bits &= bits - 1
		count += 1
	return count


## 读档/生成后把“地图本地生态型”写回 knobs：某些物种的保底残存格在目录气候带之外，
## 若不把该物种的气候边界放宽到覆盖这些格，下一日 persist 会把它剔除。
## 纯函数于 (occupancy, 气候数组)，同存档在任何会话得到同一结果，保证读档前后逐日一致。
static func realize_bounds(knobs: Dictionary, map_ref) -> int:
	var n: int = map_ref.cell_count()
	var occupancy: PackedInt32Array = map_ref.bio_occupancy_bits_arr
	if n <= 0 or occupancy.size() != n:
		return 0
	var species_bits: PackedInt32Array = knobs.get(
		"species_occupancy_bits", PackedInt32Array())
	var is_water: PackedByteArray = map_ref.is_water_arr
	var temp: PackedFloat32Array = map_ref.temp_30d_arr
	if temp.size() != n:
		temp = map_ref.temp_arr
	var moist: PackedFloat32Array = map_ref.moisture_arr
	var elev: PackedFloat32Array = map_ref.elevation_arr
	if is_water.size() != n or temp.size() != n or moist.size() != n or elev.size() != n:
		return 0
	var temp_lo: PackedFloat32Array = knobs["species_temp_lo"]
	var temp_hi: PackedFloat32Array = knobs["species_temp_hi"]
	var moist_lo: PackedFloat32Array = knobs["species_moist_lo"]
	var moist_hi: PackedFloat32Array = knobs["species_moist_hi"]
	var elev_lo: PackedFloat32Array = knobs["species_elev_lo"]
	var elev_hi: PackedFloat32Array = knobs["species_elev_hi"]
	var widened := 0
	for species in range(species_bits.size()):
		var bit := int(species_bits[species])
		if bit < 0 or bit >= 32:
			continue
		if species >= mini(temp_lo.size(), mini(temp_hi.size(), mini(
				moist_lo.size(), mini(moist_hi.size(), mini(elev_lo.size(), elev_hi.size()))))):
			continue
		var mask := 1 << bit
		var lo_t := float(temp_lo[species])
		var hi_t := float(temp_hi[species])
		var lo_m := float(moist_lo[species])
		var hi_m := float(moist_hi[species])
		var lo_e := float(elev_lo[species])
		var hi_e := float(elev_hi[species])
		var touched := false
		for cell in range(n):
			if (int(occupancy[cell]) & mask) == 0 or is_water[cell] != 0:
				continue
			if float(temp[cell]) < lo_t:
				lo_t = float(temp[cell])
				touched = true
			if float(temp[cell]) > hi_t:
				hi_t = float(temp[cell])
				touched = true
			if float(moist[cell]) < lo_m:
				lo_m = float(moist[cell])
				touched = true
			if float(moist[cell]) > hi_m:
				hi_m = float(moist[cell])
				touched = true
			if float(elev[cell]) < lo_e:
				lo_e = float(elev[cell])
				touched = true
			if float(elev[cell]) > hi_e:
				hi_e = float(elev[cell])
				touched = true
		if not touched:
			continue
		temp_lo[species] = lo_t
		temp_hi[species] = hi_t
		moist_lo[species] = lo_m
		moist_hi[species] = hi_m
		elev_lo[species] = lo_e
		elev_hi[species] = hi_e
		knobs["species_temp_lo"] = temp_lo
		knobs["species_temp_hi"] = temp_hi
		knobs["species_moist_lo"] = moist_lo
		knobs["species_moist_hi"] = moist_hi
		knobs["species_elev_lo"] = elev_lo
		knobs["species_elev_hi"] = elev_hi
		widened += 1
	return widened


## 只复制会被保底阶梯改写的数组，避免深拷贝邻居表等大字段。
static func mutable_knobs(knobs: Dictionary) -> Dictionary:
	var out: Dictionary = knobs.duplicate(false)
	for key in MUTABLE_KEYS:
		var source: Variant = knobs.get(key, null)
		if source != null:
			out[key] = source.duplicate()
	return out


static func relax_species(knobs: Dictionary, species: int, level: int) -> void:
	var spec: Dictionary = LEVELS[level]
	if bool(spec.get("drop_veg", false)):
		var veg0: PackedInt32Array = knobs["species_veg_mask0"]
		var veg1: PackedInt32Array = knobs["species_veg_mask1"]
		if species < mini(veg0.size(), veg1.size()):
			veg0[species] = 0
			veg1[species] = 0
			knobs["species_veg_mask0"] = veg0
			knobs["species_veg_mask1"] = veg1
	if bool(spec.get("drop_flags", false)):
		var flags: PackedInt32Array = knobs["species_flags"]
		if species < flags.size():
			flags[species] = 0
			knobs["species_flags"] = flags
	if bool(spec.get("drop_carrier", false)):
		var primary: PackedInt32Array = knobs["species_carrier_index"]
		var alt: PackedInt32Array = knobs["species_carrier_alt_index"]
		if species < mini(primary.size(), alt.size()):
			primary[species] = -1
			alt[species] = -1
			knobs["species_carrier_index"] = primary
			knobs["species_carrier_alt_index"] = alt
	if bool(spec.get("widen_climate", false)):
		var temp_lo: PackedFloat32Array = knobs["species_temp_lo"]
		var temp_hi: PackedFloat32Array = knobs["species_temp_hi"]
		var moist_lo: PackedFloat32Array = knobs["species_moist_lo"]
		var moist_hi: PackedFloat32Array = knobs["species_moist_hi"]
		var elev_lo: PackedFloat32Array = knobs["species_elev_lo"]
		var elev_hi: PackedFloat32Array = knobs["species_elev_hi"]
		if species < mini(temp_lo.size(), temp_hi.size()) \
				and species < mini(moist_lo.size(), moist_hi.size()) \
				and species < mini(elev_lo.size(), elev_hi.size()):
			temp_lo[species] = maxf(0.0, temp_lo[species] - CLIMATE_MARGIN)
			temp_hi[species] = minf(1.0, temp_hi[species] + CLIMATE_MARGIN)
			moist_lo[species] = maxf(0.0, moist_lo[species] - CLIMATE_MARGIN)
			moist_hi[species] = minf(1.0, moist_hi[species] + CLIMATE_MARGIN)
			elev_lo[species] = maxf(0.0, elev_lo[species] - ELEV_MARGIN)
			elev_hi[species] = minf(1.0, elev_hi[species] + ELEV_MARGIN)
			knobs["species_temp_lo"] = temp_lo
			knobs["species_temp_hi"] = temp_hi
			knobs["species_moist_lo"] = moist_lo
			knobs["species_moist_hi"] = moist_hi
			knobs["species_elev_lo"] = elev_lo
			knobs["species_elev_hi"] = elev_hi
	if bool(spec.get("absolve_climate", false)):
		# 最后一级：气候全放开，让任何陆地格都能成为该物种的残存点。
		var t_lo: PackedFloat32Array = knobs["species_temp_lo"]
		var t_hi: PackedFloat32Array = knobs["species_temp_hi"]
		var m_lo: PackedFloat32Array = knobs["species_moist_lo"]
		var m_hi: PackedFloat32Array = knobs["species_moist_hi"]
		var e_lo: PackedFloat32Array = knobs["species_elev_lo"]
		var e_hi: PackedFloat32Array = knobs["species_elev_hi"]
		if species < mini(t_lo.size(), t_hi.size()) \
				and species < mini(m_lo.size(), m_hi.size()) \
				and species < mini(e_lo.size(), e_hi.size()):
			t_lo[species] = 0.0
			t_hi[species] = 1.0
			m_lo[species] = 0.0
			m_hi[species] = 1.0
			e_lo[species] = 0.0
			e_hi[species] = 1.0
			knobs["species_temp_lo"] = t_lo
			knobs["species_temp_hi"] = t_hi
			knobs["species_moist_lo"] = m_lo
			knobs["species_moist_hi"] = m_hi
			knobs["species_elev_lo"] = e_lo
			knobs["species_elev_hi"] = e_hi
	# 放宽后的物种只留小片残存种群，避免它铺满整块大陆。
	var fill: PackedFloat32Array = knobs["species_fill_keep"]
	if species < fill.size():
		fill[species] = minf(fill[species], FILL_KEEP)
		knobs["species_fill_keep"] = fill
	var cost: PackedInt32Array = knobs["species_max_cost"]
	if species < cost.size():
		cost[species] = mini(cost[species], MAX_COST)
		knobs["species_max_cost"] = cost


static func species_name(knobs: Dictionary, species: int) -> String:
	var catalog: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var species_signals: PackedInt32Array = knobs.get("species_signal_ids", PackedInt32Array())
	if species < species_signals.size():
		var signal_index := int(species_signals[species])
		if signal_index >= 0 and signal_index < ids.size():
			return String(ids[signal_index])
	return str(species)


## 保底阶梯的逐物种记录：哪几种被放宽到哪一级、有没有完全安置不了的物种。
static func log_summary(knobs: Dictionary, guarantee: Dictionary) -> void:
	if guarantee.is_empty():
		return
	var relaxed_levels: PackedInt32Array = guarantee.get(
		"relaxed_levels", PackedInt32Array())
	var by_level := {}
	var relaxed_count := 0
	for species in range(relaxed_levels.size()):
		var level := int(relaxed_levels[species])
		if level < 0:
			continue
		relaxed_count += 1
		var level_id := String(LEVELS[level].get("id", str(level))) \
			if level < LEVELS.size() else MANUAL_LEVEL_ID
		by_level[level_id] = int(by_level.get(level_id, 0)) + 1
		print("[bio-occupancy]   relax %s level=%s" % [
			species_name(knobs, species), level_id])
	print("[bio-occupancy] guarantee attempts=%d relaxed=%d by_level=%s unplaceable=%s" % [
		int(guarantee.get("attempts", 1)), relaxed_count, str(by_level),
		str(guarantee.get("unplaceable", PackedStringArray()))])


## 播种诊断日志：物种行 + landmass 聚合行。native 与 GDScript 两条路径共用同一份打印，
## 保证日志逐字相同。
static func log_seed(knobs: Dictionary, seed_res: Dictionary, landmass_count: int,
		province_count: int, generator) -> void:
	generator._log_bio_occupancy_seed_summary(knobs, seed_res, landmass_count, province_count)
	var landmass_ids := PackedInt32Array()
	var classes_out := PackedStringArray()
	var foods_out := PackedStringArray()
	generator._get_terrain_generator()._bio_landmass_summary_gdscript(
		seed_res.get("occupancy_bits", PackedInt32Array()),
		knobs.get("landmass_ids", PackedInt32Array()),
		knobs, landmass_ids, classes_out, foods_out)
	for i in range(landmass_ids.size()):
		print("[bio-occupancy]   landmass %d classes=%s foods=%s" % [
			int(landmass_ids[i]), String(classes_out[i]), String(foods_out[i])])


## 生成期入口：融合 boot pass（真机正常路径）或逐段 bootstrap 跑完后调用。
## 只在确实有物种 occupied=0 时才重建 knobs、重发播种请求并重新发布占领位集；
## 没有缺席物种时零副作用。返回阶梯记录，空字典表示未触发。
static func ensure_after_boot(generator, map_ref, seed_res: Dictionary) -> Dictionary:
	var occupied: PackedInt32Array = seed_res.get(
		"occupied_cell_counts", PackedInt32Array())
	if occupied.is_empty():
		return {}
	var missing := false
	for count in occupied:
		if int(count) <= 0:
			missing = true
			break
	if not missing:
		return {}
	var knobs: Dictionary = generator._bio_occupancy_base_knobs(map_ref, true)
	if not bool(knobs.get("ok", false)):
		return {"ok": false, "reason": "knobs_unavailable"}
	knobs["landmass_ids"] = map_ref.landmass_id_arr
	knobs["province_ids"] = map_ref.province_id_arr
	var run_seed := func(call_knobs: Dictionary) -> Dictionary:
		return generator._data_core_world_ext.run_bio_seed_pass(call_knobs)
	var guarantee: Dictionary = run(knobs, seed_res, run_seed)
	if not bool(guarantee.get("ok", false)):
		push_warning("[bio-occupancy] guarantee pass failed: %s" % String(
			guarantee.get("reason", "unknown")))
		return guarantee
	var new_res: Dictionary = guarantee.get("seed_res", {})
	var occupancy: PackedInt32Array = new_res.get("occupancy_bits", PackedInt32Array())
	if occupancy.size() != map_ref.cell_count():
		return {"ok": false, "reason": "occupancy_shape_invalid"}
	map_ref.bio_occupancy_bits_arr = occupancy
	generator._publish_bio_occupancy_to_runtime(map_ref)
	# 保底残存格可能落在目录气候带外：作废 knobs 缓存与原生 configure，让下一次
	# 日推进用 realize_bounds 把地图本地气候边界写回，读档后由同一存档重算得到同结果。
	generator._bio_occupancy_knob_cache_version = 0
	generator._bio_occupancy_native_configured_map_id = 0
	log_summary(knobs, guarantee)
	return guarantee
