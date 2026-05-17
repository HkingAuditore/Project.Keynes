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
	{
		flag = &"use_gdext_sea_ice_atlas_pack",
		segment = "atlas_pack_sea_ice",
		required = false,
		description = "DOTS-Total-CPP 任务 8 伞段：sea_ice_atlas_upload dirty-tile pack C++ 化",
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
