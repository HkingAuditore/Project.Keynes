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
#   3. 不变量：所有资源所有格有限非负；land_only 资源水面格为 0。
#
# Headless execution:
#   godot --headless --script tests/natural_resource_init_deposit_test.gd --quit

var _checks: int = 0
var _failures: int = 0

# cell 布局（n=8）：
const C_PLAIN: int = 0       # 平原 / 裸地 / 无水无火山（参照基准）
const C_MOUNTAIN: int = 1    # 山地 + 高海拔（iron 高）
const C_PEAK: int = 2        # 高峰 + 更高海拔
const C_VOLCANO: int = 3     # 火山格（copper_ore 高）
const C_RIVER: int = 4       # 平原 + 河流（clay 高）
const C_NORIVER: int = 5     # 平原 + 无河流（与 C_RIVER 配对，仅差河流）
const C_WATER: int = 6       # 水面格（land_only 资源应为 0）
const C_FOREST: int = 7      # 丘陵 + 温带阔叶林（timber 高）


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

	var n: int = 8
	var map := _build_map(n)
	var gen := MapGenerator.new()
	gen._bootstrap_natural_resource_deposits(map, null)

	_test_factor_directions(map, profiles)
	_test_differentiation(map, profiles, n)
	_test_invariants(map, profiles, n)

	print("=== init deposit summary: %d checks, %d failures ===" % [_checks, _failures])


# ─── 构造 8 格、字段差异化的 MapData ────────────────────────────────
func _build_map(n: int) -> MapData:
	var map := MapData.new(n, 1)
	# 填 _cells 使 cell_count()==n（bootstrap 仅用它取 n，逐 index 读 SoA）。
	for i in range(n):
		map.set_cell(HexCell.new(i, 0))

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


# ─── 整体差异化（非全图统一）──────────────────────────────────────
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


# ─── 不变量：有限非负，land_only 水面格为 0 ────────────────────────
func _test_invariants(map: MapData, profiles: Array, n: int) -> void:
	var all_ok: bool = true
	var detail: String = ""
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
			if bool(p.land_only) and i == C_WATER and not is_equal_approx(arr[i], 0.0):
				all_ok = false
				detail = "%s water=%s expected 0" % [String(p.id), str(arr[i])]
				break
		if not all_ok:
			break
	if not all_ok:
		printerr("  [detail] %s" % detail)
	_expect("所有资源所有格有限非负，land_only 水面格为 0", all_ok)


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
