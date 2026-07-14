extends SceneTree

# natural_resource_init_deposit_test.gd
# 验收 MapGenerator._bootstrap_natural_resource_deposits 的多因子「地块自身情况」初始储量。
#
# 验证：
#   1. 差异化：不同地块（地貌 / 海拔 / 火山 / 河流 / 植被 / 空间噪声）得到不同初值，
#      而非全图统一。
#   2. 各因子方向正确：
#      - iron_ore：山地（地貌+海拔权重）> 平原（斑块矿脉负 base + 噪声）。
#      - copper_ore：火山格（init_volcano）> 非火山。
#      - clay：有河流（init_river）> 无河流（其余条件相同）。
#      - timber：森林植被（init_vegetation_weights）> 裸地。
#      - wild_game / pasture / 三类农业容量有各自偏向。
#      - marine_fish 位于海洋水格；淡水和淡水鱼不再是经济资源槽。
#   3. 矿产由资源局部斑块 + 同族地质省 + 矿带共同决定，固定 seed 可重放。
#   4. 不变量：所有资源有限非负；不符合 habitat 的地块储量为 0。
#
# Headless execution:
#   godot --headless --script tests/natural_resource_init_deposit_test.gd --quit

var _checks: int = 0
var _failures: int = 0

# cell 布局（n=12）：
const C_PLAIN: int = 0       # 平原 / 裸地 / 无水无火山（参照基准）
const C_MOUNTAIN: int = 1    # 山地 + 高海拔（iron 高）
const C_PEAK: int = 2        # 高峰 + 更高海拔
const C_VOLCANO: int = 3     # 火山格（copper_ore 高）
const C_RIVER: int = 4       # 平原 + 河流（clay 高）
const C_NORIVER: int = 5     # 平原 + 无河流（与 C_RIVER 配对，仅差河流）
const C_WATER: int = 6       # 水面格（land_only 资源应为 0）
const C_FOREST: int = 7      # 丘陵 + 温带阔叶林（timber 高）
const C_GRASS: int = 8       # 平原 + 温带草原（牛/野生动物高）
const C_LAKE: int = 9        # 湖泊水格（淡水资源）
const C_WET_FOREST: int = 10 # 湿热低地森林（香料/猪高）
const C_COOL_HILL: int = 11  # 凉爽丘陵草甸（羊/草药高）


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== natural resource init deposit test ===")
	ResourceProfileRegistry.ensure_loaded()
	var profiles: Array = ResourceProfileRegistry.ordered()
	if profiles.size() < 2:
		_skip("registry has <2 profiles")
		print("=== init deposit summary: %d checks, %d failures ===" % [_checks, _failures])
		return

	var n: int = 12
	var map := _build_map(n)
	var gen := MapGenerator.new()
	gen._bootstrap_natural_resource_deposits(map, null)

	_test_factor_directions(map, profiles)
	_test_differentiation(map, profiles, n)
	_test_invariants(map, profiles, n)
	_test_quantity_scale(map, profiles, n)
	_test_reserve_scale_configuration(profiles)
	_test_reserve_scale_application(profiles)
	_test_geology_fields(profiles)

	print("=== init deposit summary: %d checks, %d failures ===" % [_checks, _failures])


# ─── 构造 12 格、字段差异化的 MapData ───────────────────────────────
func _build_map(n: int) -> MapData:
	var map := MapData.new(n, 1)
	# 填 _cells 使 cell_count()==n（bootstrap 仅用它取 n，逐 index 读 SoA）。
	for i in range(n):
		map.set_cell(HexCell.new(i, 0))
	map._build_indices()

	var LF = LandformType.LF
	var VEG = VegetationType.VEG

	var temp := PackedFloat32Array();    temp.resize(n)
	var moist := PackedFloat32Array();   moist.resize(n)
	var water := PackedByteArray();      water.resize(n)
	var elev := PackedFloat32Array();    elev.resize(n)
	var lf := PackedByteArray();         lf.resize(n)
	var veg := PackedByteArray();        veg.resize(n)
	var river := PackedByteArray();      river.resize(n)
	var lake := PackedByteArray();       lake.resize(n)
	var volcano := PackedByteArray();    volcano.resize(n)
	var posx := PackedFloat32Array();    posx.resize(n)
	var posy := PackedFloat32Array();    posy.resize(n)

	# 统一气候（让差异只来自新因子；河流配对格也需完全一致的气候）。
	for i in range(n):
		temp[i] = 15.0
		moist[i] = 0.5
		water[i] = 0
		elev[i] = 0.02
		lf[i] = LF.PLAIN
		veg[i] = VEG.NONE
		river[i] = 0
		lake[i] = 0
		volcano[i] = 0
		posx[i] = float(i) * 37.0     # 各格位置不同 → 噪声采样不同
		posy[i] = float(i) * 19.0

	lf[C_MOUNTAIN] = LF.MOUNTAIN;  elev[C_MOUNTAIN] = 0.78
	lf[C_PEAK] = LF.PEAK;          elev[C_PEAK] = 0.92
	lf[C_VOLCANO] = LF.VOLCANO;    elev[C_VOLCANO] = 0.70;  volcano[C_VOLCANO] = 1
	river[C_RIVER] = 1                                       # 仅此项区别于 C_NORIVER
	water[C_WATER] = 1;            lf[C_WATER] = LF.OCEAN
	lf[C_FOREST] = LF.HILL;        veg[C_FOREST] = VEG.TEMPERATE_DECIDUOUS;  elev[C_FOREST] = 0.40
	veg[C_GRASS] = VEG.TEMPERATE_GRASSLAND
	water[C_LAKE] = 1;             lf[C_LAKE] = LF.LAKE
	temp[C_WET_FOREST] = 27.0;     moist[C_WET_FOREST] = 0.84; lf[C_WET_FOREST] = LF.LOWLAND; veg[C_WET_FOREST] = VEG.TROPICAL_RAINFOREST
	temp[C_COOL_HILL] = 8.0;       moist[C_COOL_HILL] = 0.55;  lf[C_COOL_HILL] = LF.HILL; elev[C_COOL_HILL] = 0.48; veg[C_COOL_HILL] = VEG.ALPINE_MEADOW
	# 河流配对格共享采样坐标，隔离 init_river 因子，不让局部噪声/地质场混入比较。
	posx[C_NORIVER] = posx[C_RIVER]
	posy[C_NORIVER] = posy[C_RIVER]

	map.temp_arr = temp
	map.moisture_arr = moist
	map.is_water_arr = water
	map.elevation_arr = elev
	map.landform_arr = lf
	map.vegetation_arr = veg
	map.has_river_arr = river
	map.is_lake_seed_arr = lake
	map.has_volcano_arr = volcano
	map.cell_pos_x_arr = posx
	map.cell_pos_y_arr = posy
	return map


# ─── 因子方向正确性 ─────────────────────────────────────────────
func _test_factor_directions(map: MapData, profiles: Array) -> void:
	var iron := _res_arr(map, profiles, "iron_ore")
	if iron.size() >= 8:
		_expect("iron_ore: 山地 > 平原（地貌+海拔）", iron[C_MOUNTAIN] > iron[C_PLAIN])
		_expect("iron_ore: 高峰 > 平原", iron[C_PEAK] > iron[C_PLAIN])
		_expect("iron_ore: 水面格=0（land_only）", is_equal_approx(iron[C_WATER], 0.0))

	var copper := _res_arr(map, profiles, "copper_ore")
	if copper.size() >= 8:
		_expect("copper_ore: 火山 > 平原（init_volcano）", copper[C_VOLCANO] > copper[C_PLAIN])

	var clay := _res_arr(map, profiles, "clay")
	if clay.size() >= 8:
		_expect("clay: 有河流 > 无河流（仅差 init_river）", clay[C_RIVER] > clay[C_NORIVER])

	var timber := _res_arr(map, profiles, "timber")
	if timber.size() >= 8:
		_expect("timber: 森林 > 裸地（init_vegetation_weights）", timber[C_FOREST] > timber[C_PLAIN])

	var wild_game := _res_arr(map, profiles, "wild_game")
	if wild_game.size() >= 12:
		_expect("wild_game: 森林/草地 > 裸地", maxf(wild_game[C_FOREST], wild_game[C_GRASS]) > wild_game[C_PLAIN])
	var pasture := _res_arr(map, profiles, "pasture")
	if pasture.size() >= 12:
		_expect("pasture: grassland > bare land", pasture[C_GRASS] > pasture[C_PLAIN])

	var arable := _res_arr(map, profiles, "arable_land")
	if arable.size() >= 12:
		_expect("arable_land: 河岸平原 > 山峰", arable[C_RIVER] > arable[C_PEAK])

	var paddy := _res_arr(map, profiles, "paddy_land")
	if paddy.size() >= 12:
		_expect("paddy_land: 河岸 > 无河流平原", paddy[C_RIVER] > paddy[C_NORIVER])

	var plantation := _res_arr(map, profiles, "plantation_land")
	if plantation.size() >= 12:
		_expect("plantation_land: 湿热森林 > 凉爽丘陵", plantation[C_WET_FOREST] > plantation[C_COOL_HILL])
	var marine := _res_arr(map, profiles, "marine_fish")
	var habitat: PackedByteArray = map.resource_habitat_mask_arr
	if marine.size() >= 12:
		_expect("ocean water cell contains marine fish", (habitat[C_WATER] & 2) != 0 and marine[C_WATER] > 0.0)
		_expect("adjacent shore does not store marine fish", (habitat[C_NORIVER] & 2) == 0 and is_equal_approx(marine[C_NORIVER], 0.0))
	_expect("freshwater resources retired from DataCore",
		_res_arr(map, profiles, "freshwater_fish").is_empty() and
		_res_arr(map, profiles, "fresh_water").is_empty())


func _test_differentiation(map: MapData, profiles: Array, n: int) -> void:
	var land_cells: Array = [C_PLAIN, C_MOUNTAIN, C_PEAK, C_RIVER, C_NORIVER, C_FOREST]
	var any_varied: bool = false
	var varied_count: int = 0
	for p in profiles:
		var arr: PackedFloat32Array = map.get(ResourceProfileRegistry.reserve_map_field(p))
		if arr.size() < n:
			continue
		var lo := INF
		var hi := -INF
		for c in land_cells:
			lo = minf(lo, arr[c])
			hi = maxf(hi, arr[c])
		if hi - lo > 1e-6:
			varied_count += 1
			any_varied = true
	_expect("至少一种资源在陆地格间出现差异（非统一）", any_varied)
	# 多数资源都应差异化（≥ 一半），证明因子普遍生效，而非个例。
	_expect("过半资源出现陆地格差异（varied=%d / %d）" % [varied_count, profiles.size()],
			varied_count * 2 >= profiles.size())


# ─── 不变量：有限非负，不符合 habitat 的地块为 0 ───────────────────
func _test_invariants(map: MapData, profiles: Array, n: int) -> void:
	var all_ok: bool = true
	var detail: String = ""
	var habitat: PackedByteArray = map.resource_habitat_mask_arr
	for p in profiles:
		var arr: PackedFloat32Array = map.get(ResourceProfileRegistry.reserve_map_field(p))
		if arr.size() != n:
			all_ok = false
			detail = "%s size %d != %d" % [String(p.id), arr.size(), n]
			break
		for i in range(n):
			if not is_finite(arr[i]) or arr[i] < -1e-4:
				all_ok = false
				detail = "%s[%d]=%s" % [String(p.id), i, str(arr[i])]
				break
			if not ResourceProfileRegistry.habitat_available(p, int(habitat[i])) and not is_equal_approx(arr[i], 0.0):
				all_ok = false
				detail = "%s[%d]=%s outside habitat" % [String(p.id), i, str(arr[i])]
				break
		if not all_ok:
			break
	if not all_ok:
		printerr("  [detail] %s" % detail)
	_expect("所有资源有限非负，且 habitat 外为 0", all_ok)
	_expect("至少一个陆地格缺少多数矿产（矿脉稀疏）", _has_sparse_mineral_cell(map, profiles, n))


func _test_quantity_scale(map: MapData, profiles: Array, n: int) -> void:
	var max_value: float = 0.0
	for p in profiles:
		var arr: PackedFloat32Array = map.get(ResourceProfileRegistry.reserve_map_field(p))
		for i in range(mini(n, arr.size())):
			max_value = maxf(max_value, arr[i])
	_expect("自然资源初值使用直接资源量级（max > 1）", max_value > 1.0)


func _test_reserve_scale_configuration(profiles: Array) -> void:
	var capacity_ids := ["arable_land", "fertile_soil", "paddy_land", "plantation_land", "pasture"]
	var renewable_ids := ["marine_fish", "timber", "wild_game"]
	var scales_ok := profiles.size() == 30
	for profile in profiles:
		var resource_id := String(profile.id)
		var expected := 1.0 if resource_id in capacity_ids else \
			(2.0 if resource_id in renewable_ids else 8.0)
		scales_ok = scales_ok and is_equal_approx(float(profile.init_reserve_scale), expected)
	_expect("资源初始储量按 capacity 1x、可再生 2x、地质资源 8x 分级", scales_ok)


func _test_reserve_scale_application(profiles: Array) -> void:
	var coal = null
	for profile in profiles:
		if String(profile.id) == "coal":
			coal = profile
			break
	if coal == null:
		_expect("初始储量倍率实际作用于 bootstrap", false)
		return
	var configured_scale := float(coal.init_reserve_scale)
	var unscaled_map := _build_flat_geology_map(256)
	var scaled_map := _build_flat_geology_map(256)
	var gen := MapGenerator.new()
	coal.init_reserve_scale = 1.0
	gen._bootstrap_natural_resource_deposits(unscaled_map, {"seed": 81031})
	coal.init_reserve_scale = configured_scale
	gen._bootstrap_natural_resource_deposits(scaled_map, {"seed": 81031})
	var unscaled := _res_arr(unscaled_map, profiles, "coal")
	var scaled := _res_arr(scaled_map, profiles, "coal")
	var found_positive := false
	var scale_matches := unscaled.size() == scaled.size()
	for i in range(unscaled.size()):
		if unscaled[i] <= 0.001:
			continue
		found_positive = true
		var expected := unscaled[i] * configured_scale
		if absf(scaled[i] - expected) > maxf(1.0, absf(expected) * 0.00001):
			scale_matches = false
			break
	_expect("初始储量倍率实际作用于 bootstrap", found_positive and scale_matches)


func _has_sparse_mineral_cell(map: MapData, profiles: Array, n: int) -> bool:
	var water: PackedByteArray = map.is_water_arr
	var minerals: Array = profiles.filter(func(p): return String(p.geology_family_id) != "")
	for i in range(n):
		if water.size() > i and water[i] != 0:
			continue
		var present: int = 0
		for p in minerals:
			var arr: PackedFloat32Array = map.get(ResourceProfileRegistry.reserve_map_field(p))
			if arr.size() > i and arr[i] > 0.0001:
				present += 1
		if present < minerals.size() / 2:
			return true
	return false


func _test_geology_fields(profiles: Array) -> void:
	var a := _build_flat_geology_map(256)
	var b := _build_flat_geology_map(256)
	var c := _build_flat_geology_map(256)
	var gen := MapGenerator.new()
	gen._bootstrap_natural_resource_deposits(a, {"seed": 73021})
	gen._bootstrap_natural_resource_deposits(b, {"seed": 73021})
	gen._bootstrap_natural_resource_deposits(c, {"seed": 73022})
	var copper := _res_arr(a, profiles, "copper_ore")
	var gold := _res_arr(a, profiles, "gold_ore")
	var copper_same_seed := _res_arr(b, profiles, "copper_ore")
	var copper_other_seed := _res_arr(c, profiles, "copper_ore")
	_expect("geology generation is deterministic for the same seed", copper == copper_same_seed)
	_expect("geology generation changes with map seed", copper != copper_other_seed)
	_expect("same hydrothermal family shares provinces/belts",
		_correlation(copper, gold) > 0.15)


func _build_flat_geology_map(n: int) -> MapData:
	var map := MapData.new(n, 1)
	for i in range(n):
		map.set_cell(HexCell.new(i, 0))
	map._build_indices()
	var temp := PackedFloat32Array(); temp.resize(n); temp.fill(15.0)
	var moist := PackedFloat32Array(); moist.resize(n); moist.fill(0.5)
	var water := PackedByteArray(); water.resize(n); water.fill(0)
	var elevation := PackedFloat32Array(); elevation.resize(n); elevation.fill(0.55)
	var landform := PackedByteArray(); landform.resize(n); landform.fill(LandformType.LF.HILL)
	var vegetation := PackedByteArray(); vegetation.resize(n); vegetation.fill(VegetationType.VEG.NONE)
	var zero := PackedByteArray(); zero.resize(n); zero.fill(0)
	var px := PackedFloat32Array(); px.resize(n)
	var py := PackedFloat32Array(); py.resize(n)
	for i in range(n):
		px[i] = float(i % 32) * 19.0
		py[i] = float(i / 32) * 23.0
	map.temp_arr = temp
	map.moisture_arr = moist
	map.is_water_arr = water
	map.elevation_arr = elevation
	map.landform_arr = landform
	map.vegetation_arr = vegetation
	map.has_river_arr = zero.duplicate()
	map.is_lake_seed_arr = zero.duplicate()
	map.has_volcano_arr = zero.duplicate()
	map.cell_pos_x_arr = px
	map.cell_pos_y_arr = py
	return map


func _correlation(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size() or a.size() < 2:
		return 0.0
	var mean_a := 0.0
	var mean_b := 0.0
	for i in range(a.size()):
		mean_a += a[i]
		mean_b += b[i]
	mean_a /= a.size()
	mean_b /= b.size()
	var covariance := 0.0
	var variance_a := 0.0
	var variance_b := 0.0
	for i in range(a.size()):
		var da := a[i] - mean_a
		var db := b[i] - mean_b
		covariance += da * db
		variance_a += da * da
		variance_b += db * db
	return covariance / sqrt(variance_a * variance_b) if variance_a > 0.0 and variance_b > 0.0 else 0.0


# ─── 工具 ───────────────────────────────────────────────────────
func _res_arr(map: MapData, profiles: Array, id_name: String) -> PackedFloat32Array:
	for p in profiles:
		if String(p.id) == id_name:
			return map.get(ResourceProfileRegistry.reserve_map_field(p))
	return PackedFloat32Array()


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
