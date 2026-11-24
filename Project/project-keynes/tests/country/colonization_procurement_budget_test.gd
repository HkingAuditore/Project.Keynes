extends "res://tests/family/family_colonization_runtime_test.gd"

## 锁定「派遣储备额度」这条拒单路径（2026-11-20）。
##
## 1. 单条物资缺口大于当天额度时，旧实现整行终态拒绝
##    （`colonization_procurement_budget_exhausted`），而队伍必须买到全部
##    缺口才出发，于是进度条 100% 也永远停在 PREPARING。目标行为：
##    按当天剩余额度部分成交，后续日子继续补买，直到齐套出发。
## 2. 队伍在周期中途建立时，本周期 `colonization_daily` 在周期开端被冻结为 0
##    （冻结只扫当时已处于筹备中的队伍），整周期每一次采购都被判超额。
##    目标行为：第一次采购时把本通道预算补发出来，本周期即可推进。


func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		quit(1)
		return
	compiled.erase("ok")
	_throttled_allowance_case(compiled.duplicate(true))
	_mid_epoch_budget_case(compiled.duplicate(true))
	print("=== colonization procurement budget: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


## 一天额度买不下一条缺口时，必须逐日部分成交，而不是整行拒单卡死。
func _throttled_allowance_case(catalog: Dictionary) -> void:
	var fixture := _make_fixture(catalog, 261120, 0, {},
		PackedStringArray(), 1, 40000000,
		{"economy_cadence_force_market_days": 1})
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	if ext == null or country == 0:
		return
	# 国库 4000（显示单位）· 0.1%/日 国库份额：一天的国家购买额只有 4 个单位，
	# 远低于一份完整开工包的任何一条建材缺口 —— 正是截图里的处境。
	var policy: Dictionary = ext.set_country_procurement_policy(country, true,
		10, 0, 0, 2611200)
	_expect("throttled procurement policy is accepted", bool(policy.get("ok", false)))
	if not bool(policy.get("ok", false)):
		print("throttled_policy=", policy)
		return
	var started := _start_single_colonization(ext, country, "throttled", 2611201)
	if started.is_empty():
		return
	_expect("a zero-stock party waits as PREPARING",
		bool(started.get("ok", false))
		and String(started.get("code", "")) == "colonization_preparing")
	if not bool(started.get("ok", false)):
		print("throttled_start=", started)
		return
	var handle := int(started.get("expedition_handle", 0))
	var every_good := PackedInt32Array()
	for good in range((catalog.good_ids as PackedStringArray).size()):
		every_good.append(good)
	var day := int(started.get("start_day", 0))
	var first_progress := 0
	var last_progress := 0
	var budget_rejections := 0
	var departed := false
	for step in range(40):
		day += 1
		if not _add_market_stock(ext, day, 2611300 + step * 64, 0, every_good,
				400000):
			_expect("daily restock is accepted at the source market", false)
			return
		_run_day(ext, day)
		var snap: Dictionary = ext.get_family_expedition_snapshot(country, handle)
		if String(snap.get("kit_procurement_rejection", "")) \
				== "colonization_procurement_budget_exhausted":
			budget_rejections += 1
		var progress := _expedition_cargo_total(ext, country, handle)
		if step < 3:
			print("[procurement-budget/day] ", day, " cargo=", progress,
				" allowance=", int(ext.country_procurement_snapshot(country).get(
					"colonization_daily_budget", -1)),
				" blocker=", String(snap.get("kit_blocker", "")),
				" topup=", int(snap.get("kit_topup_missing_units", -1)),
				" reason=", String(snap.get("kit_procurement_rejection", "")),
				" rejected_good=", int(snap.get("kit_procurement_rejected_good_id", -1)))
		if step < 3 and progress > 0:
			first_progress = progress
		last_progress = progress
		if _expedition_state(ext, country) == 1:
			departed = true
			break
	print("[procurement-budget/throttled] first=", first_progress, " last=",
		last_progress, " budget_rejections=", budget_rejections,
		" departed=", departed, " day=", day)
	# 部分成交：头几天内就要有托管，而不是「有货、有钱、进度 0%」。
	_expect("a line larger than one day's allowance still buys part of it",
		first_progress > 0)
	_expect("stocking keeps growing instead of stalling", last_progress > 0)
	# 额度不足不再是终态拒绝：按日额度补买，不应留下永久拒单记录。
	_expect("the daily allowance is not reported as a terminal rejection",
		budget_rejections == 0)
	_expect("throttled party departs once the allowance has been accrued",
		departed)
	var report: Dictionary = ext.get_economy_report()
	_expect("throttled stocking conserves population, cash and goods",
		not bool(report.get("fatal", false))
		and int(report.get("population_error", -1)) == 0
		and int(report.get("money_error", -1)) == 0
		and int(report.get("goods_error", -1)) == 0)
	if not departed or budget_rejections != 0:
		print("throttled_report=", report)
		print("throttled_snapshot=", ext.get_family_expedition_snapshot(
			country, handle))


## 周期中途建立的队伍必须在第一次采购时就拿到本周期额度。
func _mid_epoch_budget_case(catalog: Dictionary) -> void:
	var fixture := _make_fixture(catalog, 261121, 0, {},
		PackedStringArray(), 1, 40000000,
		{"economy_cadence_force_market_days": 3})
	var ext: Object = fixture.ext
	var country := int(fixture.country_handle)
	if ext == null or country == 0:
		return
	var cycle := int(ext.get_economy_report().get("market_cycle_days", 0))
	_expect("mid-epoch fixture locks a multi-day market cycle", cycle >= 2)
	if cycle < 2:
		print("mid_epoch_cycle=", cycle)
		return
	var policy: Dictionary = ext.set_country_procurement_policy(country, true,
		200, 0, 0, 2611210)
	_expect("mid-epoch procurement policy is accepted", bool(policy.get("ok", false)))
	if not bool(policy.get("ok", false)):
		return
	# 周期在没有任何开拓队时开端：本周期派遣储备按设计被冻结为 0。
	_run_day(ext, 1)
	var before: Dictionary = ext.country_procurement_snapshot(country)
	_expect("the frozen channel budget starts at zero with no demand",
		bool(before.get("ok", false))
		and int(before.get("colonization_daily_budget", -1)) == 0)
	# 贸易拓扑在周期内由地图重建，测试夹具要在开端后重新捕获一次才能继续报价。
	ext.capture_economy_trade_topology(fixture.neighbors, fixture.terrain,
		fixture.passable, fixture.costs, 2)
	var started := _start_single_colonization(ext, country, "mid-epoch", 2611211)
	if started.is_empty():
		var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
		var handles: PackedInt64Array = families.get("family_handles",
			PackedInt64Array())
		var probe: Dictionary = ext.get_family_colonization_quotes(country, 2,
			int(handles[0]) if handles.size() > 0 else 0, 0, 0, 64)
		print("[procurement-budget/mid-epoch] families=", families.get("total", -1),
			" epoch_active=", bool(ext.get_economy_report().get("epoch_active", true)),
			" quotes=", probe)
		return
	_expect("mid-epoch party waits as PREPARING",
		bool(started.get("ok", false))
		and String(started.get("code", "")) == "colonization_preparing")
	if not bool(started.get("ok", false)):
		print("mid_epoch_start=", started)
		return
	var handle := int(started.get("expedition_handle", 0))
	var repaired: Dictionary = ext.country_procurement_snapshot(country)
	print("[procurement-budget/mid-epoch] before=",
		int(before.get("colonization_daily_budget", -1)), " after=",
		int(repaired.get("colonization_daily_budget", -1)))
	_expect("a party created mid-epoch receives this epoch's channel budget",
		int(repaired.get("colonization_daily_budget", 0)) > 0)
	var every_good := PackedInt32Array()
	for good in range((catalog.good_ids as PackedStringArray).size()):
		every_good.append(good)
	var day := int(started.get("start_day", 0))
	var bought := 0
	var budget_rejections := 0
	for step in range(6):
		day += 1
		if not _add_market_stock(ext, day, 2611400 + step * 64, 0, every_good,
				400000):
			_expect("mid-epoch restock is accepted at the source market", false)
			return
		_run_day(ext, day)
		var snap: Dictionary = ext.get_family_expedition_snapshot(country, handle)
		if String(snap.get("kit_procurement_rejection", "")) \
				== "colonization_procurement_budget_exhausted":
			budget_rejections += 1
		bought = maxi(bought, _expedition_cargo_total(ext, country, handle))
		if _expedition_state(ext, country) == 1:
			break
	_expect("a mid-epoch party can buy from the source market", bought > 0)
	_expect("a mid-epoch party is not rejected for an empty channel budget",
		budget_rejections == 0)
	var report: Dictionary = ext.get_economy_report()
	_expect("mid-epoch stocking conserves population, cash and goods",
		not bool(report.get("fatal", false))
		and int(report.get("population_error", -1)) == 0
		and int(report.get("money_error", -1)) == 0
		and int(report.get("goods_error", -1)) == 0)
	if bought == 0 or budget_rejections != 0:
		print("mid_epoch_snapshot=", ext.get_family_expedition_snapshot(
			country, handle))
