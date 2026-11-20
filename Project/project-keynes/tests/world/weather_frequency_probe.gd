# weather_frequency_probe.gd
#
# 计划 docs/plans/weather-precipitation-frequency-plan.md W1-2：
# 降水频率的标定与验收探针。输出 M1/M2/M3/M5/M6 与五元组，以及三条自洽性判定。
#
# 指标定义（计划 §1）：
#   M1 land_rain      陆地格中降水类型的占比
#   M2 conc           P̄_rainy / mean_P（集中度；与 M1 同population）
#   M3 area           同 M1，同时报 ΣP / mean_P / P̄_rainy / conc / mean_P/soft_cap 下界
#   M5 type_mix       8 种天气类型占比
#   M6 moist_sat      moisture == 1.0 的占比 + 陆地 moisture/base_moisture 中位对比
#   M4 hp_rain 需要 synoptic ψ，MapData 上没有这条 lane ⇒ 由存档侧
#      tools/analyze_weather_frequency.py 计算（计划 §12 已知局限 4）
#
# 分类口径：用 weather_target_type（分类器本 tick 的原始输出），不用 weather_type。
# display type 要过类型过渡状态机（alpha 需连续若干次 commit 才切换），headless 短窗口里
# 会一直停在 prev —— 实测 3 天后 display 仍是全 CLEAR 而 target 已有 30% 降水。
# 存档侧同样有 weather_target_type lane，两边口径一致。
#
# 自洽性（计划 §6.1，任一不成立即视为口径错误，不许拿面积数字做结论）：
#   C1  area ≈ 1/conc               相对误差 < 5%（必须同 population）
#   C2  area ≥ mean_P/soft_cap
#   C3  窗口内 Σ(vapor+cloud_water) 变化 / 日均 ΣP < 1%（≥30 日窗口，跳前 7 日 spin-up）
#
# Headless:
#   godot --headless --path Project/project-keynes \
#     --script res://tests/world/weather_frequency_probe.gd -- --days=30 --seed=20260727 --label=w1
#
# 输出：stdout 一行 `WEATHER_FREQ_JSON=<json>`，并把同一 JSON 落到
# `<repo>/tmp/weather_freq_<label>.json`（tmp/ 已 gitignore）。

extends SceneTree

const MAX_SLICES_PER_DAY := 2048
const DEFAULT_DAYS := 30
const DEFAULT_SEED := 20260727
const DEFAULT_LABEL := "probe"
const DEFAULT_W := 60
const DEFAULT_H := 40
const WARMUP_DAYS := 7
# M4 的高压区判定阈值，与 tools/analyze_weather_frequency.py 的 HP_PSI_THRESHOLD 一致。
const HP_PSI_THRESHOLD := -0.05

const TYPE_NAMES := ["CLEAR", "RAIN", "STORM", "BLIZZARD", "DROUGHT", "FOG", "HEATWAVE", "MONSOON"]
const PRECIP_TYPES := [1, 2, 3, 7]

var _days := DEFAULT_DAYS
var _seed := DEFAULT_SEED
var _label := DEFAULT_LABEL
var _width := DEFAULT_W
var _height := DEFAULT_H
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_parse_args()
	var config := NewGameConfig.create_default()
	config.country.name = "Weather Freq Probe"
	config.country.foreign_count = 0
	config.base.map_width = _width
	config.base.map_height = _height
	config.base.initial_seed = _seed
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8

	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)

	var host := WorldRuntimeHost.new()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	# 生产权威路径：native daily ACTIVE。AUTO 会随尺寸/策略漂移，探针必须钉死。
	host.set_climate_authority_override("force_on")

	var configured: Dictionary = host.configure_session({"kind": "new_game", "config": config.to_dictionary()})
	if not bool(configured.get("ok", false)):
		_fail("session configures: %s" % str(configured))
		await _shutdown(host, clock)
		return
	await host.generate_world()
	var map: MapData = host.current_map()
	if map == null:
		_fail("world generates: map is null (见 tmp 里的 mapgen fatal；不同种子可能触发既有的 gameplay_bind 内容校验失败)")
		await _shutdown(host, clock)
		return

	var soft_cap := ClimateProfile.new().weather_extreme_precip_soft_cap
	clock.pause(false)
	var series: Array = []
	var last: Dictionary = {}
	# 采样对齐（W2 实测发现的坑）：native daily ACTIVE 的 weather 提交有**一天权限滞后**
	# （soak policy 的 `temp_arr` gap 条目已记录同一现象）。若在 `simulation_committed_day == d`
	# 之后立刻读，读到的是 d 还是 d-1 取决于当轮 catch-up 有没有跑到 weather 阶段 ——
	# 两次同配置运行会差整整一天（实测 w1-baseline 与 w2-legacy 逐日序列正好错开一天）。
	# 修法：推进到 d+1 再读，标签记 d。滞后 ≤ 1 天 ⇒ 此时 d 的 weather 一定已提交，
	# 且永远是同一滞后，A/B 才可比。
	for day in range(1, _days + 2):
		var ok: bool = await _advance_day(host, clock, day)
		if not ok:
			_fail("day %d did not commit" % day)
			break
		if day < 2:
			continue
		last = _snapshot(map, soft_cap, _read_synoptic_psi(host, map))
		last["day"] = day - 1
		last["sampled_after_commit_day"] = day
		series.append(last)
		if (day - 1) % 10 == 0 or (day - 1) == _days:
			print("[weather-freq] day %d land_rain=%.2f%% all=%.2f%% conc=%.3f mean_P=%.4f"
				% [day - 1, float(last["land_rain_pct"]), float(last["all_rain_pct"]),
					float(last["land_concentration"]), float(last["mean_precip"])])

	var report := {
		"label": _label,
		"seed": _seed,
		"map": "%dx%d" % [_width, _height],
		"cells": map.cell_count(),
		"requested_days": _days,
		"committed_days": series.size(),
		"soft_cap": soft_cap,
		"last": last,
		"series": series,
	}
	_judge(report)
	print("WEATHER_FREQ_JSON=" + JSON.stringify(report))
	_write_json(report)
	await _shutdown(host, clock)

func _parse_args() -> void:
	for raw in OS.get_cmdline_user_args():
		var arg := String(raw)
		if arg.begins_with("--days="):
			_days = maxi(1, int(arg.substr("--days=".length())))
		elif arg.begins_with("--seed="):
			_seed = int(arg.substr("--seed=".length()))
		elif arg.begins_with("--label="):
			_label = arg.substr("--label=".length())
		elif arg.begins_with("--w="):
			_width = maxi(8, int(arg.substr("--w=".length())))
		elif arg.begins_with("--h="):
			_height = maxi(8, int(arg.substr("--h=".length())))

func _advance_day(host: WorldRuntimeHost, clock: WorldClock, day: int) -> bool:
	var generator := host.get_generator()
	clock.current_day = float(day + 1)
	host.run_daily_tick(day + 1, clock.season_phase())
	host.finish_daily_tick(0.0, {})
	for _slice in range(MAX_SLICES_PER_DAY):
		host._process(0.0)
		var runtime: Dictionary = generator.get_runtime_thread_report()
		if String(runtime.get("simulation_host_state", "")) == "FAULTED":
			return false
		if int(runtime.get("simulation_committed_day", -1)) >= day:
			return true
		await process_frame
	return false

# ── ψ（只有 physics read view 有，MapData 没有这条 lane）──────────────────────
func _read_synoptic_psi(host: WorldRuntimeHost, map: MapData) -> PackedFloat32Array:
	var generator := host.get_generator()
	if generator == null or not generator.has_method("get_data_core_world_ext"):
		return PackedFloat32Array()
	var ext = generator.get_data_core_world_ext()
	if ext == null or not ext.has_method("get_climate_physics_read_view"):
		return PackedFloat32Array()
	var view: Dictionary = ext.get_climate_physics_read_view()
	if not bool(view.get("ready", false)):
		return PackedFloat32Array()
	var psi: PackedFloat32Array = view.get("synoptic_psi", PackedFloat32Array())
	if psi.size() != map.cell_count():
		return PackedFloat32Array()
	return psi

# ── 指标快照 ────────────────────────────────────────────────────────────────
# 逐格读 HexCell：weather_precip / weather_vapor / weather_convergence / weather_type
# 的 getter 都代理到 world_ext 权威 slot（hex_cell.gd:302/398/414/446）。
# MapData 的 `*_arr` 是镜像，只有 rebuild_soa_from_cells() 才同步，而那个函数会重置
# country_slot / 视野，不能对运行中的世界调用。
# 例外：cloud_water 在 component_schema 注册了但 HexCell 没暴露属性，只能读
# `map.weather_cloud_water_arr`（该数组由 native weather pass 直接写）。
func _snapshot(map: MapData, soft_cap: float, psi: PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var n := map.cell_count()
	var have_psi := psi.size() == n
	var hp_total := 0
	var hp_rain := 0
	var cloud_water_arr: PackedFloat32Array = map.weather_cloud_water_arr
	var has_cw := cloud_water_arr.size() >= n

	var hist := {}
	var hist_display := {}
	for name in TYPE_NAMES:
		hist[name] = 0
		hist_display[name] = 0

	# 每个 population 独立累计：恒等式 area = 1/conc 只在同一 population 内成立。
	# 混用「陆地面积 ÷ 全图集中度」会给出伪偏差（本探针第一版就是这么错的：6.5%）。
	var acc := {
		"all": _acc(), "land": _acc(), "water": _acc(),
	}
	var moist_sat := 0
	var land_moist: Array = []
	var land_base: Array = []
	var land_precip: Array = []
	var heat_warm := 0
	var heat_ta := 0
	var heat_p12 := 0
	var heat_c24 := 0
	var heat_v12 := 0
	var drought_hit := 0
	var conv_values: Array = []
	var sum_vapor := 0.0
	var sum_cloud_water := 0.0

	for cell: HexCell in map.iter_cells():
		var idx: int = cell.index
		var display := int(cell.weather_type)
		var target := int(cell.weather_target_type)
		if display >= 0 and display < TYPE_NAMES.size():
			hist_display[TYPE_NAMES[display]] += 1
		if target >= 0 and target < TYPE_NAMES.size():
			hist[TYPE_NAMES[target]] += 1
		var raining := PRECIP_TYPES.has(target)
		var p := float(cell.weather_precip)
		var v := float(cell.weather_vapor)
		var cw := float(cloud_water_arr[idx]) if has_cw else 0.0
		sum_vapor += v
		sum_cloud_water += cw
		conv_values.append(float(cell.weather_convergence))
		if have_psi and float(psi[idx]) < HP_PSI_THRESHOLD:
			hp_total += 1
			if raining:
				hp_rain += 1
		if float(cell.moisture) >= 0.99999:
			moist_sat += 1
		_accumulate(acc["all"], p, raining)
		if MapData.terrain_is_water_u8(int(cell.terrain)) != 0:
			_accumulate(acc["water"], p, raining)
		else:
			_accumulate(acc["land"], p, raining)
			land_moist.append(float(cell.moisture))
			land_base.append(float(cell.base_moisture))
			land_precip.append(p)
			# 诊断：DROUGHT/HEATWAVE 的判据分解（W6 残留：HEATWAVE 恒 0，要看清哪个条件绑死）
			if float(cell.temperature) > 0.55:
				heat_warm += 1
				# 与 host 侧一致：距平 = temp − temp_30d，再按 weather_classify_anomaly_cap 钳制
				var ta: float = clampf(float(cell.temperature) - float(cell.temp_30d_mean), -0.12, 0.12)
				var cl := float(cell.weather_cloud)
				var va := float(cell.weather_vapor)
				if ta > 0.04:
					heat_ta += 1
					if p < 0.012:
						heat_p12 += 1
						if cl < 0.24:
							heat_c24 += 1
							if va < 0.12:
								heat_v12 += 1
				if ta > 0.05 and p < 0.006 and cl < 0.18:
					drought_hit += 1

	var land := _rates(acc["land"], soft_cap)
	var water := _rates(acc["water"], soft_cap)
	var all := _rates(acc["all"], soft_cap)

	return {
		"cells": n,
		"land_cells": int(acc["land"]["total"]),
		"water_cells": int(acc["water"]["total"]),
		"type_hist": hist,
		"type_hist_display": hist_display,
		# M1 陆地
		"land_rain_pct": land["area_pct"],
		# 全图（陆 + 水）
		"all_rain_pct": all["area_pct"],
		"water_rain_pct": water["area_pct"],
		# 五元组 —— 陆地（C1/C2 用这一组）
		"land_sum_precip": land["sum_precip"],
		"land_mean_precip": land["mean_precip"],
		"land_mean_precip_rainy": land["mean_precip_rainy"],
		"land_concentration": land["concentration"],
		"land_identity_area_pct": land["identity_area_pct"],
		"land_lower_bound_pct": land["lower_bound_pct"],
		# 五元组 —— 全图
		"sum_precip": all["sum_precip"],
		"mean_precip": all["mean_precip"],
		"mean_precip_rainy": all["mean_precip_rainy"],
		"concentration": all["concentration"],
		"identity_area_pct": all["identity_area_pct"],
		"lower_bound_pct": all["lower_bound_pct"],
		"rainy_cells": int(acc["all"]["rainy"]),
		"sum_vapor": sum_vapor,
		"sum_cloud_water": sum_cloud_water,
		# W4 需要「陆地降水率 p80」来定分类门，所以把降水分布分位一起报。
		"land_precip_p50": _percentile(land_precip, 0.50),
		"land_precip_p80": _percentile(land_precip, 0.80),
		"land_precip_p90": _percentile(land_precip, 0.90),
		"moisture_sat_pct": 100.0 * float(moist_sat) / float(maxi(1, n)),
		"land_moisture_median": _median(land_moist),
		"land_base_moisture_median": _median(land_base),
		"convergence_median": _median(conv_values),
		# W3 需要按新分布定分位，所以三个分位一起报。
		"convergence_p50": _percentile(conv_values, 0.50),
		"convergence_p90": _percentile(conv_values, 0.90),
		"convergence_p95": _percentile(conv_values, 0.95),
		"convergence_mean": _mean(conv_values),
		# W6 诊断：热区（temp>0.55 的陆地）逐级满足 DROUGHT/HEATWAVE 判据的格数
		"heat_diag": {
			"warm": heat_warm, "ta_gt_004": heat_ta, "and_precip_lt_012": heat_p12,
			"and_cloud_lt_024": heat_c24, "and_vapor_lt_012_HEATWAVE": heat_v12,
			"drought_conditions": drought_hit,
		},
		# M4：高压区（ψ<-0.05）降水占比。ψ 只在 physics read view 里，MapData 没有这条 lane。
		"psi_available": have_psi,
		"hp_cells": hp_total,
		"hp_rain_pct": (100.0 * float(hp_rain) / float(hp_total)) if hp_total > 0 else 0.0,
	}

func _acc() -> Dictionary:
	return {"total": 0, "rainy": 0, "sum_precip": 0.0, "sum_precip_rainy": 0.0}

func _accumulate(a: Dictionary, precip: float, raining: bool) -> void:
	a["total"] = int(a["total"]) + 1
	a["sum_precip"] = float(a["sum_precip"]) + precip
	if raining:
		a["rainy"] = int(a["rainy"]) + 1
	if precip > 0.0:
		a["sum_precip_rainy"] = float(a["sum_precip_rainy"]) + precip
	# 注意：P̄_rainy 的分母用「目标类型为降水」的格数（与 area 同 population），
	# 而不是 precip>0 的格数，否则 area=1/conc 不再成立。

func _rates(a: Dictionary, soft_cap: float) -> Dictionary:
	var total := maxi(1, int(a["total"]))
	var rainy := int(a["rainy"])
	var sum_precip := float(a["sum_precip"])
	var mean_precip := sum_precip / float(total)
	var mean_precip_rainy := (sum_precip / float(rainy)) if rainy > 0 else 0.0
	var conc := (mean_precip_rainy / mean_precip) if mean_precip > 0.0 else 0.0
	var area_pct := 100.0 * float(rainy) / float(total)
	var identity_area_pct := (100.0 * mean_precip / mean_precip_rainy) if mean_precip_rainy > 0.0 else 0.0
	return {
		"total": total,
		"rainy": rainy,
		"sum_precip": sum_precip,
		"mean_precip": mean_precip,
		"mean_precip_rainy": mean_precip_rainy,
		"concentration": conc,
		"area_pct": area_pct,
		"identity_area_pct": identity_area_pct,
		"lower_bound_pct": 100.0 * mean_precip / soft_cap if soft_cap > 0.0 else 0.0,
	}

# ── 自洽性判定 ──────────────────────────────────────────────────────────────
func _judge(report: Dictionary) -> void:
	var last: Dictionary = report.get("last", {})
	if last.is_empty():
		_fail("no committed day to judge")
		return
	# C1：area ≈ 1/conc，陆地与全图各算一次
	for prefix in ["land_", ""]:
		var area := float(last.get(prefix + "rain_pct" if prefix == "land_" else "all_rain_pct", 0.0))
		var conc := float(last.get(prefix + "concentration", 0.0))
		if conc <= 0.0:
			_fail("C1 %sconcentration is zero (no precipitating cell)" % prefix)
			continue
		var expected := 100.0 / conc
		var rel := absf(area - expected) / maxf(expected, 1e-6)
		_expect(rel < 0.05, "C1 %sarea ≈ 1/conc (area=%.2f%% 1/conc=%.2f%% rel=%.3f)"
			% [prefix, area, expected, rel])
	# C2：area ≥ mean_P/soft_cap
	for prefix in ["land_", ""]:
		var area := float(last.get(prefix + "rain_pct" if prefix == "land_" else "all_rain_pct", 0.0))
		var lower := float(last.get(prefix + "lower_bound_pct", 0.0))
		_expect(area >= lower - 1e-6, "C2 %sarea ≥ mean_P/soft_cap (area=%.2f%% lower=%.2f%%)"
			% [prefix, area, lower])
	# C3：水收支。阈值分两档，因为短窗口被 spin-up 主导：
	#   30–179 日：只判「没有失控累积」，|Δcolumn|/日均ΣP < 0.25
	#   ≥180 日  ：判「近似闭合」，< 0.02
	# 实测：新图 day 7→30 是 0.1998（vapor 仍在从零灌入），而玩家存档 365 日窗口是 0.0013。
	var series: Array = report.get("series", [])
	var warmup := maxi(5, int(series.size() * 0.25))
	if series.size() - warmup >= 10:
		var window: Array = series.slice(warmup, series.size())
		var first: Dictionary = window[0]
		var lastc: Dictionary = window[window.size() - 1]
		var column_first := float(first.get("sum_vapor", 0.0)) + float(first.get("sum_cloud_water", 0.0))
		var column_last := float(lastc.get("sum_vapor", 0.0)) + float(lastc.get("sum_cloud_water", 0.0))
		var drift := absf(column_last - column_first)
		var daily := 0.0
		for row in window:
			daily += float(row.get("sum_precip", 0.0))
		daily /= float(window.size())
		# 口径修正（2026-11-20）：旧式 `|Δcolumn| / dailyΣP` **没有按窗口天数归一**，
		# 同一个净漂移在 23 日窗口算 0.80、在 45 日窗口算 1.51，跨窗口不可比 —— 是我的量纲错误。
		# 正确口径：净漂移 ÷ 窗口总吞吐 = (Δcolumn/days)/dailyΣP，即「每天净失衡占日雨量的比例」。
		var imbalance := drift / maxf(daily * float(window.size()), 1e-6)
		# 5%/天 = 「有界但没闭合」；0.5%/天 = 「近似闭合」，只在 ≥180 日窗口判。
		var threshold := 0.005 if window.size() >= 180 else 0.05
		var mode := "closed" if threshold < 0.01 else "bounded"
		_expect(imbalance < threshold,
			"C3 water budget %s (%d days, net drift %.3f%%/day of dailyΣP, limit %.2f%%/day, Δcolumn=%.2f dailyΣP=%.2f)"
			% [mode, window.size(), 100.0 * imbalance, 100.0 * threshold, drift, daily])
		report["budget_imbalance"] = imbalance
		report["budget_window_days"] = window.size()
		report["budget_mode"] = mode
	else:
		print("[weather-freq] C3 skipped (window %d days too short; run --days=30+ for the budget check)"
			% (series.size() - warmup))

	print("[weather-freq] LAND  rain=%.2f%% conc=%.3f mean_P=%.4f P_bar=%.4f ΣP=%.2f lower=%.2f%%"
		% [float(last.get("land_rain_pct", 0.0)), float(last.get("land_concentration", 0.0)),
			float(last.get("land_mean_precip", 0.0)), float(last.get("land_mean_precip_rainy", 0.0)),
			float(last.get("land_sum_precip", 0.0)), float(last.get("land_lower_bound_pct", 0.0))])
	print("[weather-freq] ALL   rain=%.2f%% conc=%.3f mean_P=%.4f moist_sat=%.1f%% land_moist_med=%.3f land_base_med=%.3f conv_med=%.3f"
		% [float(last.get("all_rain_pct", 0.0)), float(last.get("concentration", 0.0)),
			float(last.get("mean_precip", 0.0)), float(last.get("moisture_sat_pct", 0.0)),
			float(last.get("land_moisture_median", 0.0)), float(last.get("land_base_moisture_median", 0.0)),
			float(last.get("convergence_median", 0.0))])
	var hist: Dictionary = last.get("type_hist", {})
	var mix := []
	for name in TYPE_NAMES:
		mix.append("%s=%.1f%%" % [name, 100.0 * float(hist.get(name, 0)) / float(maxi(1, int(last.get("cells", 1))))])
	print("[weather-freq] target type_mix " + " ".join(mix))

func _write_json(report: Dictionary) -> void:
	var dir := ProjectSettings.globalize_path("res://").path_join("../../tmp").simplify_path()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("weather_freq_%s.json" % _label)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("[weather-freq] WARN could not write %s" % path)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("[weather-freq] wrote %s" % path)

func _shutdown(host: WorldRuntimeHost, clock: WorldClock) -> void:
	await host.close_world()
	host.free()
	clock.free()
	print("=== weather frequency probe done: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)

# ── 小工具 ──────────────────────────────────────────────────────────────────
func _median(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var mid := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return float(sorted[mid])
	return 0.5 * (float(sorted[mid - 1]) + float(sorted[mid]))

func _percentile(values: Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var pos: float = clampf(q, 0.0, 1.0) * float(sorted.size() - 1)
	var lo := int(floor(pos))
	var hi := int(ceil(pos))
	if lo == hi:
		return float(sorted[lo])
	var t := pos - float(lo)
	return lerpf(float(sorted[lo]), float(sorted[hi]), t)

func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for v in values:
		total += float(v)
	return total / float(values.size())

func _expect(cond: bool, msg: String) -> void:
	if not cond:
		_fail(msg)

func _fail(msg: String) -> void:
	_failures += 1
	push_error("[weather-freq][FAIL] " + msg)
	print("[weather-freq][FAIL] " + msg)
