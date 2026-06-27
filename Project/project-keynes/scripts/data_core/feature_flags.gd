extends RefCounted
class_name DCFeatureFlags

## DataCore — FeatureFlagRegistry（B1 / dots-migration-roadmap §3）。
## PR-4.4 hot-reload 走 DCFlagBus（独立 Node singleton + signal）；本类保持纯 static。
##
##
## 集中索引项目中所有"双轨切换"性质的 feature flag。**本类不持有 flag 值
## 的权威**——值仍然由 ClimateProfile / MapConfig 等业务 Resource 持有；
## 本类只提供：
##   1. 一份 FLAGS 元数据表，让"项目里到底有哪些 flag、谁是 owner、
##      默认值是什么"在一个地方可查（替代散落 12+ 处 @export var
##      use_*/enable_* 的不可索引现状）；
##   2. `is_on(flag, cp)` API，作为 `cp.<flag>` 直读的薄层 wrapper，
##      让模块迁移过程中可以加打点 / 调试日志 / future hot-reload 钩子，
##      而不动业务 caller；
##   3. 启动期 sanity check，让 typo 在第一时间报出来（FLAGS 里声明了
##      `&"use_data_core_xxxx"` 但 ClimateProfile 上根本没这个字段时报错）。
##
## 加新 flag 的 SOP：
##   1. 在 ClimateProfile.gd（或对应业务 Resource）加 `@export var <flag>: bool`；
##   2. 在本文件的 FLAGS 表追加一行 `{ name = ..., owner = ..., default = ... }`；
##   3. 业务 caller 用 `DCFeatureFlags.is_on(&"<flag>", cp)` 而不是 `cp.<flag>`
##      （阶段 II 改造时机械替换；新代码统一走本 API）。
##
## 与 dots-migration-roadmap §5 的关系：
##   每个 DCSystem 子类的 `feature_flag()` 返回一个 StringName，调度器在
##   注册时去 FLAGS 表里查 owner / default，并给 system 跑 is_on 决定是否
##   挂载。这让"模块 A 走 dots_cpp、模块 B 仍 legacy"成为单 flag toggle。

# Flag 注册项 schema（Dictionary 字段）：
#   name        — StringName，flag 名（既是注册表 key 也是 Resource 上的属性名）
#   owner       — String，业务 owner / 维护团队（仅文档用）
#   default     — bool，默认值（与 Resource 上 @export 的 default 必须一致；
#                 启动期 sanity check 会比对）
#   resource    — String，flag 所在的 Resource 类型名（默认 "ClimateProfile"）
#   description — String，一句话描述（dot-graph / debug overlay 用）
#
# 注：dispatch_path / dispatch_paths（如 demo_thermal_gradient_path 是 enum
# 而非 bool）此处不强行纳入；它们仍以普通 @export 存在于业务 Resource，
# 通过普通 cp.<field> 读。本表只索引 bool 类型 flag。
const FLAGS: Array = [
	# ─── DataCore 主开关（已删除）──────────────────────────────────────
	# use_data_core / use_data_core_weather / use_data_core_climate 已在
	# dots-flag-prune-pr1（2026-05-22）随 ClimateProfile 字段一同删除——
	# DataCore 已恒走单路径，不再有 bind/unbind 切换语义。
	# ─── SoA / 稀疏更新（Climate-Weather 2ms Budget Plan）──────────────
	{
		name = &"use_soa_pipeline",
		owner = "climate.pass_a",
		default = false,
		resource = "ClimateProfile",
		description = "SoA pipeline + round 末 flush_soa_to_cells，为 sparse_climate / sparse_weather 前置",
	},
	{
		name = &"use_sparse_climate",
		owner = "climate.pass_a",
		default = false,
		resource = "ClimateProfile",
		description = "依赖 use_soa_pipeline；启用 climate_dirty_mask 增量更新（非全图 sweep）",
	},
	{
		name = &"use_sparse_weather",
		owner = "weather.field_solver",
		default = false,
		resource = "ClimateProfile",
		description = "依赖 use_soa_pipeline；启用 weather_dirty_mask 增量更新",
	},
	{
		name = &"use_low_freq_ocean_psi",
		owner = "ocean.physical_circulation",
		default = false,
		resource = "ClimateProfile",
		description = "海盆 ψ 求解降频（季节级而非每日），降低 SOR 迭代占比",
	},
	{
		name = &"use_partial_atlas_upload",
		owner = "rendering.atlas",
		default = false,
		resource = "ClimateProfile",
		description = "海冰 / enum atlas 仅上传 dirty 区域（非全 RGBA8 重传）",
	},
	# ─── Climate / Weather 业务开关 ────────────────────────────────────
	{
		name = &"daily_climate_interpolation",
		owner = "climate.daily",
		default = true,
		resource = "ClimateProfile",
		description = "每日插值 climate（false 时仅季节切换日重算）",
	},
	{
		name = &"weather_advect_use_wind_vector",
		owner = "weather.field_solver",
		default = true,
		resource = "ClimateProfile",
		description = "weather 锁面 advect 优先采用地形扰动后的 wind_vector，而非 wind_field 基线",
	},
	{
		name = &"enable_local_climate_coupling",
		owner = "climate.pass_b",
		default = true,
		resource = "ClimateProfile",
		description = "Pass B（局部气候耦合 + transp 反馈）总开关；false 时仅跑 Pass A 基线",
	},
	{
		name = &"enable_terrain_aware_wind",
		owner = "map_generation.wind",
		default = true,
		resource = "ClimateProfile",
		description = "地形扰动后 wind_vector 写入开关；false 时 cell.wind_vector 维持纬度基线",
	},
	{
		name = &"enable_ocean_heat_transport",
		owner = "ocean.heat_transport",
		default = true,
		resource = "ClimateProfile",
		description = "洋流热输运 water_pass + land_pass 总开关",
	},
	# ─── Demo / Reference impl（仅 demo，禁止真实游戏机制依赖）────────
	{
		name = &"demo_thermal_gradient_enabled",
		owner = "demo.thermal_gradient",
		default = false,
		resource = "ClimateProfile",
		description = "performance-charter §12.6 reference Pass #2 总开关；attach cell.demo.thermal_gradient slot",
	},
	# ─── 新增（Phase B / C 引入）─────────────────────────────────────
	# 这些 flag 当前还不在 ClimateProfile 上，registry 先占位（default 为 false
	# 表示功能未启用）；阶段 B/C 实现时同步在 ClimateProfile 加 @export 字段
	# 并解开下面的 sanity check skip。
	{
		name = &"use_world_view_adapter",
		owner = "rendering.view_adapter",
		default = true,
		resource = "ClimateProfile",
		description = "Phase B.3：true 时走 DCViewAdapter.World（DOTS）；false 时走 .Cell（legacy）。注：dots-flag-prune-pr1 已删除 ClimateProfile 上同名字段，本表保留作为 sentinel-true 让 DCFeatureFlags.is_on() 在字段缺失时返回 true",
	},
	# ─── 注：use_hexcell_facade / use_dc_system_scheduler 已在 dots-flag-prune-pr1
	# （2026-05-22）连同 ClimateProfile 字段一并删除——HexCell facade 与 DCSystemScheduler
	# 已恒走单路径，不再有 legacy 兼容分支。
	# ─── Phase F / dots-full-migration §F.1-F.6（已删除）─────────────────────
	# 17 个 hot pass C++ 化 flag（climate_pass_a/b / ocean_water/land /
	# sea_ice + sea_ice_atlas_prepare / transpiration / weather_front/field/
	# distribute/summary/field_pixel / albedo / vegetation_dynamics /
	# climate_feedback / ocean_currents_pixel / sea_ice_atlas_pack /
	# enum_atlas_pack）已在 dots-flag-prune-pr1（2026-05-22）随 ClimateProfile
	# 字段一同删除——所有 hot pass 已恒走 ext != null + has_method 探测分支，
	# C++ 不可用时仍透明 fallback 到 GDScript（保留 ext.is_null 单边分支）。

	# ─── Weather Hot-Path C++ 化（已删除）────────────────────────────────────
	# use_gdext_weather_distribute / use_gdext_weather_summary 同上批删除。
	# use_gdext_wind_field / use_gdext_physical_circulation / use_gdext_season_refresh
	# 已在 dots-flag-prune-pr1 round 2（2026-05-22）随 ClimateProfile 字段一同删除——
	# 三个 hot pass 已恒走 ext != null + has_method 探测分支，C++ 不可用时透明 fallback
	# 到 GDScript（保留 ext.is_null 单边分支），不再需要 caller 端 flag 控制。
	# ─── Phase B+：season refresh round 一次跨界整 round 切片调度（已删除）─
	# use_gdext_season_round 已在 dots-flag-prune-pr1（2026-05-22）随
	# ClimateProfile 字段一同删除——season round 已恒走单路径。
	# ─── DOTS-Final-Push（已删除）：stage_b 三件套独立 flag 已固化为单路径 ──
	# use_gdext_albedo / use_gdext_vegetation_dynamics / use_gdext_climate_feedback
	# 已在 dots-flag-prune-pr1（2026-05-22）随 ClimateProfile 字段一同删除。
	# stage_b_combined 走双轨入口仍由独立 flag 控制（保留下面）。
	# ─── 方案 B：stage_b 三段合并（plan/stage-b-combine）─────────────────────
	# refresh_daily_stage_b 入口走单 cpp call run_stage_b_pass，把 albedo +
	# veg_dyn + feedback 三段合并执行，消除 GDScript 端 3 次 pack/unpack 围栏。
	# 前置条件：上面三个独立 cpp 路径已 ACTIVE（日志 first run elapsed < 0.1ms）。
	# 验收：SAME_SOURCE A/B 30 tick；目标 stage_b 累加 6–15ms → ≤ 1.5ms，
	# weather_refresh ran p95 3.51ms → ≤ 1.0ms。
	# use_gdext_stage_b_combined 已在 dots-flag-prune-pr1 round 2（2026-05-22）一并删除——
	# stage_b 合并单 cpp call 入口已恒走 ext + has_method 探测分支。
	# ─── DOTS-Final-Push：atlas pack C++ 化（部分已删除）──────────────────────
	# use_gdext_enum_atlas_pack 已在 dots-flag-prune-pr1（2026-05-22）随
	# ClimateProfile 字段一同删除——enum_atlas pack 已恒走单路径。
	# ─── DOTS-Total-CPP Phase A.2 / C.1（已删除）：unified fast tick + schedule graph ──
	# use_gdext_unified_fast_tick / use_gdext_system_schedule 已在
	# dots-flag-prune-pr1（2026-05-22）随 ClimateProfile 字段一同删除——
	# 调度路径与 native bundle 已恒走单路径。
	# ─── DOTS-Total-CPP：剩余 GDScript 残余下沉 C++（已删除）──────────────
	# use_gdext_ocean_currents_pixel / use_gdext_weather_field_pixel /
	# use_gdext_sea_ice_atlas_pack 已在 dots-flag-prune-pr1（2026-05-22）
	# 随 ClimateProfile 字段一同删除——所有像素 baker 与 atlas pack 已恒走 C++ 单路径
	# （C++ 不可用时 baker 内部仍会透明 fallback 到 GDScript，不需要 caller 端 flag）。
	# ─── Phase A.1（dots-total-cpp roadmap）：fronts zero-copy SoA ───────────
	# C++ 端 run_weather_summary_fronts_pass 在原 out["fronts"]: Array[Dict] 之外
	# 额外输出 out["fronts_soa"]: Dict{front_*: Packed*Array}（23 列，命名与
	# scripts/data_core/fronts_schema.gd FRONTS_SCHEMA cpp_name 严格 1:1）。
	# 跨语言 Variant entry 从 ~17*N → ~24 ref（与 N 无关），marshalling ~90% 削减。
	# use_gdext_fronts_soa 已在 dots-flag-prune-pr1 round 2（2026-05-22）一并删除——
	# fronts_soa 路径已恒走 ext + has_method 探测分支，缺失字段时自动回退 Array[Dict]。
	# ─── Phase A.3（dots-total-cpp roadmap）：常驻 knobs RID ─────────────────
	# weather_system / map_generator 持久化 KnobsHandle（C++ POD struct + dirty-
	# write 缓存 Dict）；ClimateProfile.changed 时触发段级 invalidate；hot path 4 个
	# _build_*_knobs 拿 to_*_knobs_dict() 缓存输出（稳态 CoW 零分配）。
	# 实测节省 ~71 标量 Variant 装箱 / 帧 ≈ 0.05-0.1ms。
	# use_gdext_resident_knobs 已在 dots-flag-prune-pr1 round 2（2026-05-22）一并删除——
	# resident knobs 路径已恒走 ClassDB.class_exists('KnobsHandle') 探测分支。
	# ─── Dirty-Push Atlas Encode（plan/dirty-push-atlas-encode）──────────────
	# 4 张运行期 atlas baker 改造：sim 端 setter / DCWorld write API 漏斗式
	# 推送 cell-level dirty mask；baker 入口 read_and_clear 一次拿 dirty cells
	# 喂给 chunk_step，避免 N=1e5 全图扫。配 sig 二防线避免量化后无变化的
	# GPU upload。阶段 F 接 DCWorldExt encode_* pass 走 C++/SIMD。
	# dirty_push_enabled / cpp_atlas_encode_enabled 已在 dots-flag-prune-pr1 round 2
	# （2026-05-22）一并删除——dirty mask 推送已恒走单路径，cpp encode 路径已恒走
	# ext + has_method 探测分支（缺失自动回退 GDScript mask 路径）。
	# ─── Atlas Pipeline CPP（plan/atlas-pipeline-cpp，2026-05-20）─────────────
	# dynamic_visual_atlas_upload_system 每帧热路径整套搬到 C++：dirty 消费 →
	# 4 张 atlas value-diff（per-atlas prev_sigs snapshot 兜底 dirty 语义 bug）
	# → 1-跳邻居膨胀（smooth 用）→ CSR 打包 → 4 张 atlas encode → 4-phase 调
	# 度节流。GD 端薄壳每 tick 只调一次 DCWorldExt.run_atlas_pipeline_step(opts)，
	# 拿 atlas_buffers Dict 后做 4 次 ImageTexture.update。
	#
	# 与 cpp_atlas_encode_enabled 互补：本 flag 涵盖 dirty/diff/dilate/CSR/调度的
	# 全部 GDScript 计算下沉，cpp_atlas_encode_enabled 仅控制 per-phase encode-only。
	# true 时 ext 缺失自动回退到旧 GD 4-phase 状态机。
	# cpp_atlas_pipeline_enabled 已在 dots-flag-prune-pr1 round 2（2026-05-22）一并删除——
	# atlas pipeline 已恒走 ext + has_method 探测分支（ext 缺失自动回退到旧 GD 4-phase）。
	# ─── plan/sim-2ms-simd-dirty-budget（2026-05-21）：SIMD 内核 + 线程兜底 ─
	# 复刻 bench_pass_a_full_simd 模板把 climate Pass-B / ocean water / ocean
	# land 三大 hot pass 升级到 AVX2 SIMD 8-lane + scalar tail；线程兜底独立
	# 总开关。所有 flag 默认 false，1000-tick mean ≥ 30% 加速 + 年度统计 |Δ|
	# < 0.5% 验收后逐项开启。前置 use_gdext_climate_pass_b / use_gdext_ocean_*
	# 必须 ACTIVE，否则 simd flag 静默忽略。
	# use_gdext_pass_b_simd / use_gdext_ocean_water_simd / use_gdext_ocean_land_simd /
	# use_gdext_thread_fallback / use_atlas_dirty_throttle 已在 dots-flag-prune-pr1
	# round 2（2026-05-22）一并删除——SIMD 内核与 thread fallback 已固化为 C++ 端
	# 内部实现细节（C++ 内部根据 CPU 特性 / 数据规模自动选择 scalar/SIMD/threaded
	# 三档执行路径），不再需要 caller 端 flag 控制。enum atlas upload 节流同理。
	# plan/sim-2ms-simd-dirty-budget 任务 7（2026-05-21）：dynamic_visual_atlas pipeline
	# 4 个工作 phase（DYNAMIC / ECOLOGY / SMOOTH / ICE）的 dirty 路径 kill-switch。
	# 默认 true 与 cpp run_atlas_pipeline_step 现行 dirty 编码行为一致；false 时
	# dvas_system 不向 cpp 传 dirty_indices 且加 force_full_encode=true，cpp 覆盖
	# dirty_path_used=false → 4 phase 全部走 all_cells（与 cache_invalid 首帧路径
	# 等价），保留 SAME_SOURCE A/B 30 tick 校验能力（任务 7 验收 + 回归排障入口）。
	# use_gdext_dynamic_atlas_terminal_dirty 已在 dots-flag-prune-pr1 round 2
	# （2026-05-22）一并删除——dynamic_visual_atlas dirty 编码恒走 cpp 现行 dirty 路径，
	# 不再保留 A/B 对照 kill-switch（生产无理由切 false 已实证）。
	# ─── Phase 1A（plan/sus-cpp-port）：SUS 调度外壳 native 化（已删除）────
	# use_gdext_sus_scheduler 已在 dots-flag-prune-pr1（2026-05-22）随
	# ClimateProfile 字段一同删除——SusScheduler/DCSystemScheduler 上的同名
	# 字段、10 处 hot-path if 与失败 fallback 写回均同步清理，恒走 C++ 单路径。
]


## 通过 StringName 取 flag 元数据；不存在返回空 Dictionary。
static func find(flag_name: StringName) -> Dictionary:
	for f in FLAGS:
		if f.name == flag_name:
			return f
	return {}


## 该 flag 是否已注册（startup 校验、debug menu 列表用）。
static func is_known(flag_name: StringName) -> bool:
	return not find(flag_name).is_empty()


## 取 flag 的 owner 字符串（debug overlay / dot-graph 用）。
static func owner_of(flag_name: StringName) -> String:
	var meta: Dictionary = find(flag_name)
	return String(meta.get("owner", "")) if not meta.is_empty() else ""


## 取 flag 的默认值（启动期 sanity check 用）。
static func default_of(flag_name: StringName) -> bool:
	var meta: Dictionary = find(flag_name)
	return bool(meta.get("default", false)) if not meta.is_empty() else false


## 从 Resource（通常是 ClimateProfile 实例）按 flag_name 反射读 bool。
##
## profile 为 null 时返回 default。flag 未注册时 push_warning（debug 构建）
## 并退到 cp.get(flag_name) 直读，避免新代码因 typo 静默失败。
##
## 设计说明：本 API 是 `cp.<flag>` 的薄 wrapper，不改变现有 caller 的语义；
## 但走本 API 让未来加 hot-reload 钩子 / 调试 toggle / per-frame log 时
## 不需要改 caller。新代码统一走本 API。
static func is_on(flag_name: StringName, profile) -> bool:
	if profile == null:
		return default_of(flag_name)
	var meta: Dictionary = find(flag_name)
	if meta.is_empty() and OS.is_debug_build():
		push_warning("[DCFeatureFlags] is_on('%s'): flag not registered in FLAGS table" % String(flag_name))
	# 直接从 profile 读取（与 cp.<flag> 语义一致）
	# Note: GDScript Object.get() returns Variant; bool() 自动转换。
	var v: Variant = profile.get(String(flag_name))
	if typeof(v) == TYPE_NIL:
		return bool(meta.get("default", false))
	return bool(v)


## 启动期 sanity check：遍历 FLAGS，对每个非 pending 项验证 profile 上确实
## 有同名 @export 字段，且默认值与 FLAGS 声明的 default 一致（防止改了
## ClimateProfile 默认值忘了同步 FLAGS 表）。
##
## 返回错误描述（空字符串表示全部通过）。bind_world 入口 / _setup_sus 启动
## 期可调用，违约时 push_error 中止。
##
## profiles：Dictionary<String, Resource>，按 resource 类型名映射到该类型
## 的"参考实例"——通常是默认 new() 出来的；validate 用它判断"@export 字段
## 是否真的存在 + 默认值一致性"。
static func validate_against(profiles: Dictionary) -> String:
	for f in FLAGS:
		if bool(f.get("pending", false)):
			continue
		var resource_name: String = String(f.get("resource", "ClimateProfile"))
		if not profiles.has(resource_name):
			# 找不到该 resource 实例就跳过（caller 不一定提供所有 profile）
			continue
		var prof = profiles[resource_name]
		if prof == null:
			continue
		# 走 get(...) 反射 —— 不存在时返回 null
		var v: Variant = prof.get(String(f.name))
		if typeof(v) == TYPE_NIL:
			return "[FLAGS] '%s' declared in registry but not found on %s" % [String(f.name), resource_name]
		# 默认值一致性比对（仅在 prof 真的是 default-constructed 时有效；
		# caller 应该传一份默认实例进来）
		if bool(v) != bool(f.default) and OS.is_debug_build():
			# 这是 warning 不是 error：用户也可能合法地改了 default
			push_warning("[FLAGS] '%s' default mismatch: registry=%s, profile=%s"
				% [String(f.name), str(f.default), str(v)])
	return ""


## 列出全部已注册 flag 的 StringName（debug menu 用）。
static func all_names() -> Array:
	var out: Array = []
	for f in FLAGS:
		out.append(f.name)
	return out


## 列出指定 owner 名下的全部 flag（dot-graph / 模块文档生成用）。
static func by_owner(owner_name: String) -> Array:
	var out: Array = []
	for f in FLAGS:
		if String(f.get("owner", "")) == owner_name:
			out.append(f.name)
	return out


# ─── Cell-index indirection（province-ID 间接寻址，plan: cell-index atlas indirection）──
# 渲染路径 meta-backed toggle，语义与 map_baker 的 `force_atlas_quarter_size`
# （main.gd:694 `Engine.set_meta`）一致：不进 FLAGS / ClimateProfile sanity 表，
# 由 Engine meta 充当进程级单一数据源，render / bake / upload 三处统一用本 accessor 读。
#
# cell-index 现在是唯一渲染路径。旧 per-pixel 动态 atlas 路径不再作为 A/B fallback。
const CELL_INDIRECTION_META: StringName = &"cell_indirection_enabled"

## 当前是否启用 cell-index 间接寻址（render / bake / upload 统一读这里）。
static func cell_indirection_active() -> bool:
	return true

## 设置 cell-index 间接寻址开关（debug console / 热键 / 启动配置调用）。
static func set_cell_indirection(enabled: bool) -> void:
	Engine.set_meta(CELL_INDIRECTION_META, true)


# ─── 洋流/风场"逐像素视觉"开关（vector_atlas pipeline） ──────────────────────
# vector_atlas（RG=洋流、BA=风场）已退役。仿真读 per-cell HexCell.wind_vector /
# 洋流场，不依赖该贴图；shader 固定使用中性向量 / axis-only 漂移。
const OCEAN_CURRENT_VISUAL_META: StringName = &"ocean_current_visual_enabled"

## 当前是否启用洋流/风场逐像素视觉（bake / commit / job / render 统一读这里）。
static func ocean_current_visual_active() -> bool:
	return false

## 设置洋流/风场逐像素视觉开关（main.gd @export → _generate_and_render 推送）。
static func set_ocean_current_visual(enabled: bool) -> void:
	Engine.set_meta(OCEAN_CURRENT_VISUAL_META, false)


# ─── 旧 sea_ice_tex（R8）逐像素海冰贴图开关 ───────────────────────────────────
# [sea-ice-atlas-skip 2026-06-16] sea_ice_tex 是**已退役的死贴图**：
#   · 任何着色器都不声明/采样它；
#   · 运行时 sea_ice_atlas_upload job/system 已删除，prepare/upload 没有 live 调用者；
#   · 主地图海冰视觉由水路径 shader 按 水温/纬度/水深派生（indirection 开时走 dyn_lut.a）。
# 唯一残留成本是 `bake_world` 每次重生成时 encode 一张全零 R8（~0.6MB 显存 + 编码）。
#
# 与 cell_indirection 同语义：默认缺失 = **false（退役/关闭）**——直接省掉那张死贴图。
# 开为 true 仅为兼容旧调试/数据通道（`dots_soak_dump` 的 sea_ice_fraction_buffer 哈希）。
# 改勾选后需重新生成地图才生效。
const SEA_ICE_ATLAS_META: StringName = &"sea_ice_atlas_enabled"

## 当前是否启用旧 sea_ice_tex 逐像素海冰贴图 + prepare/upload（bake / render 统一读）。
static func sea_ice_atlas_active() -> bool:
	return false

## 设置旧 sea_ice_tex 海冰贴图开关（main.gd @export → _generate_and_render 推送）。
static func set_sea_ice_atlas(enabled: bool) -> void:
	Engine.set_meta(SEA_ICE_ATLAS_META, false)
