extends RefCounted
class_name DCDotsCompletionGate

## DataCore — DOTS Completion Gate（plan/dots-final-push 任务 1 占位 / 任务 9 升级）
##
## 集中索引"DOTS-Final-Push 计划新增的 use_gdext_* flag 是否已通过 SAME_SOURCE
## A/B 验收并应当强制为 true"。本类不持有 flag 值的权威——值仍由 ClimateProfile
## 持有，本类只提供：
##   1. SEGMENTS 元数据表，列出本计划新增的 5 段 C++ 化（albedo / veg_dyn /
##      climate_feedback / sea_ice / enum_atlas_pack）的 flag 名与启动期是否强制；
##   2. is_required(flag, cp) API，判断"该 flag 当前是否被门禁强制为 true"；
##   3. evaluate(cp) 启动期检查 —— 与 DCFeatureFlags.validate_against 互补，
##      在 bind_world / _setup_sus 入口被调用，对未达成强制要求的 flag 打印
##      明确 BLOCK 日志（与现有 F.1~F.5 的灰度规范一致）。
##
## 与 DCFeatureFlags 的关系：
##   FeatureFlags 表说"这些 flag 存在 / 默认值是什么"；
##   CompletionGate 表说"这些 flag 在本计划的验收闭环上是否强制为 true"。
##   两表完全正交：可以一个 flag 在 FeatureFlags 默认 false、但在 CompletionGate
##   被标记为 required（启动期阻断）；也可以默认 true 但 not required（仅提示）。
##
## 任务 1 阶段（当前）：所有段 required = false，仅占位 / 暴露查询；不阻断启动。
## 任务 9 阶段（验收通过后）：把 stage_b 三件套 + sea_ice + enum_atlas_pack 的
## required 字段升为 true，启动期未满足时打印 [DOTS-Final-Push] BLOCK 日志。

# Segment 注册项 schema：
#   flag        — StringName，对应 ClimateProfile 上的 use_gdext_* 字段名
#   segment     — String，段标签（用于日志与基线文件名）
#   required    — bool，启动期是否强制为 true（任务 9 升级时翻为 true）
#   description — String，一句话描述（debug overlay / startup log 用）
const SEGMENTS: Array = [
	{
		flag = &"use_gdext_albedo",
		segment = "albedo",
		required = false,
		description = "DOTS-Final-Push 任务 2：_apply_albedo_pass C++ 化",
	},
	{
		flag = &"use_gdext_vegetation_dynamics",
		segment = "vegetation_dynamics",
		required = false,
		description = "DOTS-Final-Push 任务 3：_apply_vegetation_dynamics C++ 化",
	},
	{
		flag = &"use_gdext_climate_feedback",
		segment = "climate_feedback",
		required = false,
		description = "DOTS-Final-Push 任务 4：_apply_weather_to_map_feedback_pass C++ 化",
	},
	{
		flag = &"use_gdext_stage_b_combined",
		segment = "stage_b_combined",
		required = false,
		description = "方案 B：stage_b albedo+veg_dyn+feedback 合并为单 cpp call run_stage_b_pass（消除 pack/unpack 围栏，目标 6–15ms → ≤ 1.5ms）",
	},
	{
		flag = &"use_gdext_sea_ice",
		segment = "sea_ice_full",
		required = false,
		description = "DOTS-Final-Push 任务 5：run_sea_ice_daily_pass 完整实装（替换 stub）",
	},
	{
		flag = &"use_gdext_enum_atlas_pack",
		segment = "enum_atlas_pack",
		required = false,
		description = "DOTS-Final-Push 任务 6.1：enum_atlas_upload pack C++ 化",
	},
	# ─── DOTS-Total-CPP（plan/dots-total-cpp）：5 段新增门禁 ────────────────
	# 任务 1 阶段：required 全为 false；任务 9 过后翻 true，启动期未满足不 push_error 阻断。
	{
		flag = &"use_gdext_season_refresh",
		segment = "season_refresh_pipeline",
		required = false,
		description = "DOTS-Total-CPP 任务 2：season_refresh 11 stage gdext pipeline（stage 8 已 C++；stage 0/4/7/10 本计划新增；stage 1/2/3/5/6 仍走 GDScript fallback——参考 8.4 条款）",
	},
	{
		flag = &"use_gdext_physical_circulation",
		segment = "ocean_circulation",
		required = false,
		description = "DOTS-Total-CPP 任务 3+4+5：ocean_currents 单 slice 一次性 round（while 循环跑完 7 stage + run_ocean_field_rasterize C++ 单次直出）",
	},
	{
		flag = &"use_gdext_ocean_currents_pixel",
		segment = "ocean_currents_pixel",
		required = false,
		description = "DOTS-Total-CPP 任务 4：run_ocean_field_rasterize C++ 单次 hex→byte 直出（替代 17 个 GDScript pixel slice，干掉 25ms slow slice 源头）",
	},
	{
		flag = &"use_gdext_ocean_water",
		segment = "ocean_water",
		required = false,
		description = "DOTS-Total-CPP 任务 6：run_ocean_water_pass C++ 化 + climate_daily 同 tick 复用 ocean_water_done_tick meta",
	},
	{
		flag = &"use_gdext_weather_field_pixel",
		segment = "weather_field_pixel",
		required = false,
		description = "DOTS-Total-CPP 任务 7：weather_refresh wrapper 精简（mock 警告限频 + bake_weather_field_only DEPRECATED 标注）",
	},
	{
		flag = &"use_gdext_enum_atlas_pack",
		segment = "atlas_pack_enum",
		required = false,
		description = "DOTS-Total-CPP 任务 8 伞段：enum_atlas_upload dirty-tile pack（与 sea_ice_atlas_pack 同步验收）",
	},
	# ─── DOTS-Total-CPP（plan/dots-total-cpp Phase A.2）：unified fast tick ──
	# native_daily_sim_mode=ACTIVE 时，把 weather refresh daily 的 4 组 super_knobs
	# 平铺进 run_native_daily_tick 的 bundle["weather_knobs"]，让 C++ 端单次跨界
	# 跑完 11 段 native_daily + 5 段 weather（共 16 段）。required=false：Phase A
	# 收尾期门禁仅占位；Phase A 验收（SAME_SOURCE 1000-tick A/B + 72h soak）
	# 通过后翻 true。
	{
		flag = &"use_gdext_unified_fast_tick",
		segment = "unified_fast_tick",
		required = false,
		description = "Phase A.2：把 weather refresh daily 嵌入 run_native_daily_tick 的 bundle.weather_knobs，单次跨界跑完 16 段；目标省 1 次 Variant marshalling fix-cost ≈ 50-100μs/帧",
	},
	# Phase C.1：System schedule graph 静态 DAG。门禁占位，required=false；
	# SAME_SOURCE 1000-tick A/B（breakdown ms 字段 epsilon 1e-5 + fronts
	# bit-equal）+ 72h soak 0 crash 通过后翻 true。
	{
		flag = &"use_gdext_system_schedule",
		segment = "system_schedule",
		required = false,
		description = "Phase C.1：把 run_native_daily_tick 内 11 段 if-chain 抽象为 SCHEDULE_GRAPH[] + dispatch loop，bit-equal；为 C.3 job_graph 拓扑分组奠基。",
	},
	{
		flag = &"use_gdext_sea_ice_atlas_pack",
		segment = "atlas_pack_sea_ice",
		required = false,
		description = "DOTS-Total-CPP 任务 8 伞段：sea_ice_atlas_upload dirty-tile pack C++ 化",
	},
	# ─── DOTS-Final-Frontier（plan/dots-final-frontier）：season_refresh stage 1-8 + SIMD 三件套 ──
	# 真·收尾：此前 stage 0/8/11 已 C++（伞段 season_refresh_pipeline 上方），本计划补齐
	# stage 1-8 全量下沉 + 翻开 pass_b/ocean_water/ocean_land 三 SIMD flag。
	# 任务 1 阶段（phase 0）：required = false 仅占位；phase 6/7 验收通过后翻 true。
	{
		flag = &"use_gdext_season_refresh",
		segment = "season_refresh_stage_1_to_8",
		required = false,
		description = "DOTS-Final-Frontier：season_refresh stage 1-8 全量 C++ 化（rain_shadow/redecide/river_eco/veg_feedback/shrubland/mangrove/glacier/swamp）。复用 use_gdext_season_refresh 总开关 + per-stage helper gate。",
	},
	# ─── DOTS-Final-Frontier Phase B+：season refresh full-round single-call ──
	# 在 stage 1-8 全量 C++ 化的基础上，进一步把 12-stage round 的"调度层"也下沉：
	# GDScript 端从每 slice 12 次跨界塌缩为 start/run_slice/finish 3 次跨界，
	# 切片粒度退化为 stage 边界（b1）。算法实现完全复用 stage 1-8 已 bit-equal 的
	# C++ 路径，仅多一层 round_state 调度，验收复用 SAME_SOURCE 1000-tick A/B。
	# 行为变更：history.push 由原 8 次/round 收敛为 1 次/round（用户已接受）。
	# 任务 1 阶段（B+1/B+2）：required = false 仅占位；B+3 1000-tick A/B 通过后翻 true。
	{
		flag = &"use_gdext_season_round",
		segment = "season_round_full",
		required = false,
		description = "DOTS-Final-Frontier Phase B+：season_refresh 12-stage round 单 C++ 调用 + stage-boundary 切片（b1）。GDScript→C++ 跨界 12→3，facade sync 8→1，history push 8→1。验收门槛：SAME_SOURCE 1000-tick A/B + fast_ms p95 ≤ 5ms。依赖 use_gdext_season_refresh = true（B+ 路径内部仍调 stage 1-8 helper）。",
	},
	{
		flag = &"use_gdext_pass_b_simd",
		segment = "simd_avx2_pass_b",
		required = false,
		description = "DOTS-Final-Frontier：climate Pass-B AVX2 8-lane SIMD 升级。验收门槛：1000-tick mean ≥30% 加速 + bit-equal。",
	},
	{
		flag = &"use_gdext_ocean_water_simd",
		segment = "simd_avx2_ocean_water",
		required = false,
		description = "DOTS-Final-Frontier：ocean water pass AVX2 8-lane SIMD 升级。验收门槛：1000-tick mean ≥30% 加速 + bit-equal。",
	},
	{
		flag = &"use_gdext_ocean_land_simd",
		segment = "simd_avx2_ocean_land",
		required = false,
		description = "DOTS-Final-Frontier：ocean land pass AVX2 8-lane SIMD 升级。验收门槛：1000-tick mean ≥30% 加速 + bit-equal。",
	},
	# ─── Phase A.1（dots-total-cpp roadmap）：fronts zero-copy SoA ───────────
	# C++ 端 run_weather_summary_fronts_pass 在 out["fronts"] 之外并存输出
	# out["fronts_soa"] = Dict{front_*: Packed*Array}（23 列）。GDScript 端
	# _unpack_summary_soa_to_fronts 按 idx 读 PackedArray 列，跨语言开销
	# 从 ~17*N Variant entry → ~24 PackedArray ref。phase 1（当前）：required=false
	# 仅占位；1000-tick A/B fronts 字段 epsilon ≤ 1e-5 + elapsed_ms 不退化
	# 验收通过后 phase 2 翻 required=true。
	{
		flag = &"use_gdext_fronts_soa",
		segment = "fronts_soa_zero_copy",
		required = false,
		description = "Phase A.1：fronts zero-copy SoA。C++ 端 build_front_dict 并存 SoA Dict 输出，GDScript 走列扫描构造 WeatherFront；目标 marshalling ~90% 削减、_unpack_summary_dict_to_front fallback 一帧零拷贝。",
	},
	# ─── Phase A.3（dots-total-cpp roadmap）：常驻 knobs RID ────────────
	# weather_system / map_generator 持久化 KnobsHandle 实例，hot-path 4 个
	# _build_*_knobs 走 to_*_knobs_dict() 缓存输出。ClimateProfile.changed 时
	# 段级 invalidate；稳态重建频率应 ≤1 Hz（_*_rebuild_count 验收口径）。
	# phase 1（当前）：required=false 仅占位；1000-tick A/B 4 段 Dict bit-equal
	# 验收通过后 phase 2 翻 required=true。
	{
		flag = &"use_gdext_resident_knobs",
		segment = "resident_knobs",
		required = false,
		description = "Phase A.3：常驻 KnobsHandle RID。ClimateProfile.changed → 段级 invalidate；hot-path 4 个 build_*_knobs 拿 to_*_knobs_dict() 缓存输出，节省 ~71 标量 Variant 装箱 / 帧。",
	},
]


## 通过 flag StringName 取段元数据；不存在返回空 Dictionary。
static func find(flag_name: StringName) -> Dictionary:
	for seg in SEGMENTS:
		if seg.flag == flag_name:
			return seg
	return {}


## 该段当前是否被门禁强制为 true。
## 任务 1 阶段恒返回 false；任务 9 升级后按 SEGMENTS 表中的 required 字段返回。
static func is_required(flag_name: StringName) -> bool:
	var seg: Dictionary = find(flag_name)
	if seg.is_empty():
		return false
	return bool(seg.get("required", false))


## 取段标签（基线文件名 / 日志用）。
static func segment_of(flag_name: StringName) -> String:
	var seg: Dictionary = find(flag_name)
	return String(seg.get("segment", "")) if not seg.is_empty() else ""


## 启动期检查：对每个 required = true 的段，验证 cp.<flag> 是否为 true。
## 不满足时返回错误描述列表（空数组表示全部通过）。
##
## 任务 1 阶段：SEGMENTS 表中 required 全为 false，本函数恒返回空数组。
## 任务 9 升级：required 字段被翻为 true 后，启动期 caller 应在该函数返回非空时
## 打印 [DOTS-Final-Push] BLOCK 日志（与 DCFeatureFlags.validate_against 配合）。
static func evaluate(profile) -> Array:
	var failures: Array = []
	if profile == null:
		return failures
	for seg in SEGMENTS:
		if not bool(seg.get("required", false)):
			continue
		var flag_name: StringName = seg.flag
		var v: Variant = profile.get(String(flag_name))
		var enabled: bool = false
		if typeof(v) != TYPE_NIL:
			enabled = bool(v)
		if not enabled:
			failures.append("[DOTS-Final-Push] BLOCK: required flag '%s' (segment=%s) is not enabled on ClimateProfile" % [
				String(flag_name), String(seg.get("segment", "")),
			])
	return failures


## 列出所有已注册段的 flag 名（debug overlay / 启动期摘要日志用）。
static func list_flags() -> Array:
	var out: Array = []
	for seg in SEGMENTS:
		out.append(seg.flag)
	return out


## 列出当前被门禁强制为 true 的段 flag 名。任务 1 阶段恒返回空数组。
static func list_required_flags() -> Array:
	var out: Array = []
	for seg in SEGMENTS:
		if bool(seg.get("required", false)):
			out.append(seg.flag)
	return out


## ── 任务 8：A/B 验收夹具入口（不引入新框架，复用 dots_soak_ab_runner + F3 hotkey）─
##
## 调用方式：玩家在 main 场景按 F3（main.gd line 465 已有 hotkey）启动
## DCSoakABRunner.start(main_node, 30, Mode.SAME_SOURCE)，跑完后在
## .workbuddy/baselines/master-<date>/ 下出现 same_A_30tick.tsv / same_B_30tick.tsv。
##
## 本函数把"本计划新增的 5 段当前 flag 状态 + 该段对应的基线文件命名 + 单段
## 验收门槛"打印出来，让 caller 一眼看清"哪些段已经处于 ON 等待 SAME_SOURCE
## 验收 / 哪些段还在 OFF 不该 toggle"。
##
## 验收闭环（与 _evaluate_same_source 在 dots_soak_ab_runner.gd line 273 衔接）：
##   1. 跑 SAME_SOURCE A/B（F3）→ 同 DataCore 状态跑两遍 30 tick
##   2. 多阈值评估：
##      - 标量字段 worst < 0.05 (`_SAME_SOURCE_SCALAR_THRESHOLD`)
##      - 长期字段 worst < 0.01 (`_SAME_SOURCE_LONGTERM_THRESHOLD`)
##      - 随机字段豁免（pid_seed / weather_seed 等）
##   3. PASS → 把对应段在 SEGMENTS 表中翻成 required = true（任务 9）
##   4. FAIL → 默认 flag 保持 false 不阻塞主线（需求 5.4）
##
## 返回：Array of Dictionary，每段一项：
##   {
##     segment: String,
##     flag: StringName,
##     enabled_now: bool,         # 当前 ClimateProfile 该 flag 的真实值
##     required: bool,            # SEGMENTS 表中是否被强制
##     baseline_a_hint: String,   # 跑 SAME_SOURCE 时该段会落到的基线文件提示
##     baseline_b_hint: String,
##     description: String,
##   }
static func collect_acceptance_status(profile) -> Array:
	var out: Array = []
	if profile == null:
		return out
	# baseline 命名复用现有 dots_soak_ab_runner 的 same_{A,B}_30tick.tsv 模板：
	# 单一 .tsv 已经覆盖全字段（37 SoA + 6 派生），段验收复用同一份基线、按
	# 段相关字段子集做 worst 评估，不需要按段单独建文件——这与现有 ab runner
	# 的设计一致（一份 TSV → 多段共评）。
	for seg in SEGMENTS:
		var flag_name: StringName = seg.flag
		var v: Variant = profile.get(String(flag_name))
		var enabled: bool = (typeof(v) != TYPE_NIL) and bool(v)
		out.append({
			"segment": String(seg.get("segment", "")),
			"flag": flag_name,
			"enabled_now": enabled,
			"required": bool(seg.get("required", false)),
			"baseline_a_hint": ".workbuddy/baselines/master-<date>/same_A_30tick.tsv",
			"baseline_b_hint": ".workbuddy/baselines/master-<date>/same_B_30tick.tsv",
			"description": String(seg.get("description", "")),
		})
	return out


## 一行打印每段的当前状态（启动期 / debug overlay 用）。
##
## 使用：
##   var gate := DCDotsCompletionGate.new()
##   for line in gate.format_acceptance_lines(climate_profile):
##       print(line)
##
## 输出形如：
##   [DOTS-Final-Push] albedo            : flag=use_gdext_albedo               enabled=true  required=false  desc=任务 2：…
static func format_acceptance_lines(profile) -> Array:
	var lines: Array = []
	var rows: Array = collect_acceptance_status(profile)
	if rows.is_empty():
		lines.append("[DOTS-Final-Push] (no profile bound)")
		return lines
	# 列宽对齐：segment 最长 19 (vegetation_dynamics)，flag 最长 33 (use_gdext_vegetation_dynamics)
	for r in rows:
		lines.append("[DOTS-Final-Push] %-19s : flag=%-33s enabled=%-5s required=%-5s desc=%s" % [
			String(r.get("segment", "")),
			String(r.get("flag", "")),
			str(bool(r.get("enabled_now", false))),
			str(bool(r.get("required", false))),
			String(r.get("description", "")),
		])
	# 末行附 SAME_SOURCE 验收门槛提示
	lines.append("[DOTS-Final-Push] acceptance protocol = SAME_SOURCE 30 tick (F3 hotkey, see scripts/tools/dots_soak_ab_runner.gd)")
	lines.append("[DOTS-Final-Push] thresholds = scalar<0.05  longterm<0.01  random fields exempted (pid_seed, weather_seed, …)")
	return lines
