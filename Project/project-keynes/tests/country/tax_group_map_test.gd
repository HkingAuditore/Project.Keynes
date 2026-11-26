extends SceneTree

# Tax group map contract (T1 of the tax rework): grouping is derived only from
# catalog columns that already exist, ordering is first-appearance (so a saved
# game and a fresh compile agree), and every bucket covers exactly one building.
#
# Run: godot --headless --path <project> --script res://tests/country/tax_group_map_test.gd

const TaxGroupMap = preload("res://scripts/country/tax_group_map.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run_synthetic()
	_run_real_catalog()
	print("tax group map: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run_synthetic() -> void:
	# Two civil sectors plus military (index 5) so the six-entry sector list is
	# exercised; `military` must not silently land in another bucket.
	var catalog := {
		"building_type_ids": PackedStringArray(["a", "b", "c", "d", "e"]),
		"building_economic_sectors": PackedInt32Array([0, 0, 2, 2, 5]),
		"building_owner_profession_ids": PackedStringArray(
			["farmer", "farmer", "factory_owner", "farmer", "general"]),
		"building_industry_chain_ids": PackedStringArray(
			["chain.wheat", "chain.wheat", "chain.steel", "chain.cloth", "military.fort"]),
		# 档位轴：故意让 rank 顺序与建筑顺序不一致，才能验出组是按档位排的。
		"building_maturity_ranks": PackedInt32Array([2, 1, 4, 4, 0]),
		# 产物轴：CSR 前缀和，e 没有产出。
		"building_output_offsets": PackedInt32Array([0, 1, 2, 3, 4, 4]),
		"building_output_good_ids": PackedInt32Array([0, 1, 2, 2, 0]),
		"good_ids": PackedStringArray(["wheat_grain", "planks", "cloth"]),
		"good_category_ids": PackedStringArray(
			["starchy_staple", "construction", "textile"]),
	}

	var sector_owner: Dictionary = TaxGroupMap.build(catalog, TaxGroupMap.MODE_SECTOR_OWNER)
	_expect("sector_owner builds", bool(sector_owner.get("ok", false)))
	if bool(sector_owner.get("ok", false)):
		_expect("sector_owner -> 4 groups", int(sector_owner["group_count"]) == 4)
		_expect("sector_owner ids keep first-appearance order",
			sector_owner["group_ids"] == PackedStringArray([
				"agriculture|farmer", "manufacturing|factory_owner",
				"manufacturing|farmer", "military|general"]))
		_expect("a and b share a group",
			int(sector_owner["building_group_indices"][0])
				== int(sector_owner["building_group_indices"][1]))
		_expect("c and d split by owner",
			int(sector_owner["building_group_indices"][2])
				!= int(sector_owner["building_group_indices"][3]))
		_expect("military is its own group",
			int(sector_owner["building_group_indices"][4]) == 3)
		var counts: PackedInt32Array = sector_owner["group_building_counts"]
		var total := 0
		for value in counts:
			total += int(value)
		_expect("group counts cover every building", total == 5)
		var members: PackedInt32Array = TaxGroupMap.buildings_in_group(
			sector_owner["building_group_indices"], 0)
		_expect("buildings_in_group returns both members",
			members == PackedInt32Array([0, 1]))

	var sector_only: Dictionary = TaxGroupMap.build(catalog, TaxGroupMap.MODE_SECTOR)
	_expect("sector mode -> 3 groups", sector_only.get("ok", false)
		and int(sector_only["group_count"]) == 3)

	var chain_mode: Dictionary = TaxGroupMap.build(catalog, TaxGroupMap.MODE_CHAIN)
	_expect("chain mode -> 4 groups", chain_mode.get("ok", false)
		and int(chain_mode["group_count"]) == 4)

	# 档位轴：组按 rank 升序排（不按首次出现），rank 0 的军事建筑不能被丢掉。
	var rank_mode: Dictionary = TaxGroupMap.build(catalog, TaxGroupMap.MODE_MATURITY_RANK)
	_expect("maturity_rank builds", bool(rank_mode.get("ok", false)))
	if bool(rank_mode.get("ok", false)):
		_expect("maturity_rank groups sorted by rank", rank_mode["group_ids"]
			== PackedStringArray(["rank_0", "rank_1", "rank_2", "rank_4"]))
		_expect("maturity_rank labels are the canonical names", rank_mode["group_labels"]
			== PackedStringArray(["(未入档)", "自然获取", "家户试作", "组织化生产"]))
		_expect("same rank shares a group",
			int(rank_mode["building_group_indices"][2])
				== int(rank_mode["building_group_indices"][3]))
		_expect("rank 0 building lands in (未入档)",
			int(rank_mode["building_group_indices"][4]) == 0)
		_expect("rank_0 group counts one building",
			int(rank_mode["group_building_counts"][0]) == 1)

	# 产物轴：按首个产出货分组，没有产出的建筑单独一组。
	var good_mode: Dictionary = TaxGroupMap.build(catalog, TaxGroupMap.MODE_OUTPUT_GOOD)
	_expect("output_good builds", bool(good_mode.get("ok", false)))
	if bool(good_mode.get("ok", false)):
		_expect("output_good keys are the first output good", good_mode["group_ids"]
			== PackedStringArray(["wheat_grain", "planks", "cloth", "no_output"]))
		_expect("same good shares a group",
			int(good_mode["building_group_indices"][2])
				== int(good_mode["building_group_indices"][3]))
		_expect("building without output goes to no_output",
			int(good_mode["building_group_indices"][4]) == 3)

	var short_rank := catalog.duplicate(true)
	short_rank["building_maturity_ranks"] = PackedInt32Array([1, 2])
	_expect("short maturity column rejected",
		not bool(TaxGroupMap.build(short_rank, TaxGroupMap.MODE_MATURITY_RANK).get("ok", true)))

	var short_output := catalog.duplicate(true)
	short_output["building_output_offsets"] = PackedInt32Array([0, 1])
	_expect("short output offsets rejected",
		not bool(TaxGroupMap.build(short_output, TaxGroupMap.MODE_OUTPUT_GOOD).get("ok", true)))

	var unstable: Dictionary = TaxGroupMap.build(catalog, "nope")
	_expect("unknown mode rejected", not bool(unstable.get("ok", true)))

	var bad_sector := catalog.duplicate(true)
	bad_sector["building_economic_sectors"] = PackedInt32Array([0, 0, 2, 2, 9])
	var rejected: Dictionary = TaxGroupMap.build(bad_sector, TaxGroupMap.MODE_SECTOR)
	_expect("out-of-range sector rejected", not bool(rejected.get("ok", true)))
	_expect("out-of-range rejection names the building",
		String(rejected.get("building", "")) == "e")

	var short_owner := catalog.duplicate(true)
	short_owner["building_owner_profession_ids"] = PackedStringArray(["farmer"])
	var short_owner_result: Dictionary = TaxGroupMap.build(
		short_owner, TaxGroupMap.MODE_SECTOR_OWNER)
	_expect("owner column length mismatch rejected",
		not bool(short_owner_result.get("ok", true)))


func _run_real_catalog() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var ok := bool(compiled.get("ok", false))
	_expect("catalog compiles", ok)
	if not ok:
		print("    reason: %s" % String(compiled.get("reason", "")))
		return

	for mode in TaxGroupMap.MODES:
		var built: Dictionary = TaxGroupMap.build(compiled, mode)
		_expect("%s builds on the real catalog" % mode, bool(built.get("ok", false)))
		if not bool(built.get("ok", false)):
			print("    reason: %s" % String(built.get("reason", "")))
			continue
		var building_count := int(built["building_count"])
		var group_count := int(built["group_count"])
		var counts: PackedInt32Array = built["group_building_counts"]
		var total := 0
		var widest := 0
		for value in counts:
			total += int(value)
			widest = maxi(widest, int(value))
		_expect("%s buckets cover every building" % mode, total == building_count)
		_expect("%s groups are fewer than buildings" % mode, group_count < building_count)
		print("    %-13s buildings=%d groups=%d widest=%d" % [
			mode, building_count, group_count, widest])

	# 档位轴的实测基数：军械 17 座全部 rank 0，所以「未入档」必须是一组真存在的组，
	# 并且每个组名都得出自规范名表——数据里 rank 4 有四种写法，界面不能跟着抖。
	var rank_built: Dictionary = TaxGroupMap.build(compiled, TaxGroupMap.MODE_MATURITY_RANK)
	if bool(rank_built.get("ok", false)):
		var rank_ids: PackedStringArray = rank_built["group_ids"]
		var rank_labels: PackedStringArray = rank_built["group_labels"]
		var canonical := {}
		for value in TaxGroupMap.RANK_LABELS.values():
			canonical[String(value)] = true
		var labels_ok := true
		for label in rank_labels:
			if not canonical.has(String(label)):
				labels_ok = false
		_expect("real rank labels all come from the canonical table", labels_ok)
		_expect("real rank groups are ordered by rank", rank_ids.size() > 0
			and String(rank_ids[0]) == "rank_0")
		_expect("(未入档) group is non-empty on the real catalog",
			int(rank_built["group_building_counts"][0]) > 0)
		print("    rank groups=%s" % str(rank_labels))

	# 产物轴：每座有产出的建筑都得落在某个货上，不能整体落进 no_output。
	var good_built: Dictionary = TaxGroupMap.build(compiled, TaxGroupMap.MODE_OUTPUT_GOOD)
	if bool(good_built.get("ok", false)):
		var good_ids: PackedStringArray = good_built["group_ids"]
		var no_output := good_ids.find(TaxGroupMap.NO_OUTPUT_GROUP_ID)
		var fallback := 0 if no_output < 0 else int(
			good_built["group_building_counts"][no_output])
		_expect("output_good leaves most buildings on a real good",
			fallback < int(good_built["building_count"]))
		print("    output groups=%d no_output=%d" % [int(good_built["group_count"]), fallback])

	# 商品大类轴：全目录 171 种商品应全部落入已命名大类（0 未分类），且食物拆分为 4 个大类。
	var good_cat_axis: Dictionary = TaxGroupMap.build_axis(
		compiled, TaxGroupMap.AXIS_GOOD_CATEGORY, TaxGroupMap.SUBJECT_GOOD)
	_expect("good_category axis builds on real catalog", bool(good_cat_axis.get("ok", false)))
	if bool(good_cat_axis.get("ok", false)):
		var cat_gids: PackedStringArray = good_cat_axis["group_ids"]
		_expect("good_category covers all goods with zero unclassified",
			not cat_gids.has(TaxGroupMap.UNCLASSIFIED_ID))
		_expect("good_category splits food into staple/meat/processed/beverages",
			cat_gids.has("staple_food") and cat_gids.has("meat_seafood")
			and cat_gids.has("processed_food") and cat_gids.has("beverages_spices"))
		print("    good_category groups=%d" % int(good_cat_axis["group_count"]))
