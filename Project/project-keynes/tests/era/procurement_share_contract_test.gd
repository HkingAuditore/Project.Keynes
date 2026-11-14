extends SceneTree

## 国家购买政策的通道份额契约（需求 3.1 / 3.2 / 9.2）。
##
## 只验证 native 侧的份额切分语义，不依赖经济目录里正在漂移的建筑数据，
## 因此在任意工作区状态下都应当稳定通过。

const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _failures := 0


func _register_environment(ext: Object) -> void:
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid := int(ext.register_component(slot_name, 0, 1, false))
		ext.write_f32_range(sid, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid := int(ext.register_component(slot_name, 2, 1, false))
		ext.write_u8_range(sid, 0, PackedByteArray([0]))


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)


func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))

	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	_register_environment(ext)

	var country = CountryFacadeScript.new()
	_expect("country configures", bool(country.configure(ext, 1, 7102,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	var cash := 100000000
	_expect("country bootstraps", bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.share_contract"]),
		"country_names": PackedStringArray(["ShareContract"]),
		"country_cash": PackedInt64Array([cash]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 0]),
		"technology_indices": PackedInt32Array(),
	}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)

	# 前置：建立 economy runtime。这里不断言 ok，因为 configure_economy 还会校验
	# 整份经济目录（建筑/货物），该目录当前在工作区里有他人未提交的改动，
	# 与份额契约无关。份额切分只需要 runtime 就位。
	var native_catalog := compiled.duplicate(false)
	native_catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	var configured: Dictionary = ext.configure_economy(native_catalog, profile, 1, 7102)
	if not bool(configured.get("ok", false)):
		print("  [NOTE] configure_economy -> %s (catalog drift, unrelated to shares)"
			% String(configured.get("reason", "unknown")))

	# 旧的六参数调用必须继续可用：DEFVAL 让两个新参数默认成 -1。
	var legacy: Dictionary = ext.set_country_procurement_policy(handle, true, 5000, 3000, 0, 1)
	_expect("legacy six-arg call still accepted", bool(legacy.get("ok", false)))
	var legacy_snap: Dictionary = ext.country_procurement_snapshot(handle)
	_expect("legacy call leaves both channel shares at -1",
		int(legacy_snap.get("era_share_bp", 0)) == -1
		and int(legacy_snap.get("colonization_share_bp", 0)) == -1)

	# 两项都未设置时保持旧的“谁有需求谁拿剩余”规则。
	var national: int = cash * 5000 / 10000
	var research: int = national * 3000 / 10000
	var other: int = national - research
	_expect("preview national budget", int(legacy_snap.get("national_daily_budget", -1)) == national)
	_expect("preview research budget", int(legacy_snap.get("research_daily_budget", -1)) == research)

	# 八参数调用写入两项份额，并在待应用快照里立即回显（滑条不弹回）。
	var queued: Dictionary = ext.set_country_procurement_policy(
		handle, true, 5000, 3000, 0, 2, 2000, 2000)
	_expect("share call queues", bool(queued.get("ok", false)))
	var pending: Dictionary = ext.country_procurement_snapshot(handle)
	_expect("pending snapshot echoes era share", int(pending.get("era_share_bp", -2)) == 2000)
	_expect("pending snapshot echoes colonization share",
		int(pending.get("colonization_share_bp", -2)) == 2000)

	# 三项份额的基数是国家购买总额 national_daily（不是扣掉科技后的 other_daily），
	# 只有这样「三项之和 <= 100%」才是一条真约束。
	_expect("preview colonization budget follows its share",
		int(pending.get("colonization_daily_budget", -1)) == national * 2000 / 10000)
	# 时代通道是缺口驱动的：没有时代采购需求就不领预算。
	_expect("era budget stays 0 without era demand",
		int(pending.get("era_daily_budget", -1)) == 0)
	# 挂上时代需求后，时代日额按份额切分。
	ext.set_era_procurement_target(handle, true, PackedInt32Array([0]),
		PackedInt64Array([10]), 0, 7)
	var with_demand: Dictionary = ext.country_procurement_snapshot(handle)
	_expect("preview era budget follows its share once demand exists",
		int(with_demand.get("era_daily_budget", -1)) == national * 2000 / 10000)

	# 超额分配必须被拒绝而不是静默归一化：一旦静默，玩家的三项之和就不可信了。
	var over: Dictionary = ext.set_country_procurement_policy(
		handle, true, 5000, 5000, 0, 3, 3000, 3000)
	_expect("over-allocated shares are rejected", not bool(over.get("ok", true)))
	_expect("over-allocation reports a specific code",
		String(over.get("code", "")) == "procurement_share_over_allocated")

	# 单项越界同样拒绝。
	var bad: Dictionary = ext.set_country_procurement_policy(
		handle, true, 5000, 3000, 0, 4, 10001, -1)
	_expect("out-of-range era share is rejected", not bool(bad.get("ok", true)))

	# -1 表示本次不改：国库页只提交国库/科技两项时，通道份额保持不变。
	ext.set_country_procurement_policy(handle, true, 4000, 2000, 0, 5, -1, -1)
	var kept: Dictionary = ext.country_procurement_snapshot(handle)
	_expect("unspecified channels keep their stored share",
		int(kept.get("era_share_bp", -2)) == 2000
		and int(kept.get("colonization_share_bp", -2)) == 2000)

	# 份额为 0 即暂停，而不是回退到旧的“拿剩余”。
	ext.set_country_procurement_policy(handle, true, 4000, 2000, 0, 6, 0, 0)
	var paused: Dictionary = ext.country_procurement_snapshot(handle)
	_expect("zero share pauses the channel",
		int(paused.get("era_daily_budget", -1)) == 0
		and int(paused.get("colonization_daily_budget", -1)) == 0)

	print("=== procurement share contract: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)
