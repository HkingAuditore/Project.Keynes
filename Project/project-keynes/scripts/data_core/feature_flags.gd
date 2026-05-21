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
	# ─── DataCore 主开关 ─────────────────────────────────────────────────
	{
		name = &"use_data_core",
		owner = "data_core.bootstrap",
		default = true,
		resource = "ClimateProfile",
		description = "在 _setup_sus 期把 MapData 挂入 DCWorld；为 false 时所有 system 走 legacy AoS 路径",
	},
	{
		name = &"use_data_core_weather",
		owner = "weather.system",
		default = false,
		resource = "ClimateProfile",
		description = "依赖 use_data_core；为 true 时 weather front 走 World 镜像 + view_f32 hot loop",
	},
	{
		name = &"use_data_core_climate",
		owner = "climate.daily",
		default = false,
		resource = "ClimateProfile",
		description = "依赖 use_data_core；为 true 时 climate Pass-A/B SoA hot loop 走 view_f32",
	},
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
		default = false,
		resource = "ClimateProfile",
		description = "Phase B.3：true 时走 DCViewAdapter.World（DOTS）；false 时走 .Cell（legacy）。依赖 use_data_core",
	},
	{
		name = &"use_hexcell_facade",
		owner = "data_core.hex_cell_facade",
		default = true,
		resource = "ClimateProfile",
		description = "PR-2.3b/任务 4：HexCell 21 个热字段 setter/getter 透传到 DCWorld SoA；启用后 cell.<field> = v 等价 world.write_f32(cid, idx, v)。依赖 use_data_core 已 bind world",
	},
	{
		name = &"use_dc_system_scheduler",
		owner = "data_core.scheduler",
		default = true,
		resource = "ClimateProfile",
		description = "Phase C.4 / 任务 6：true 时走 DCSystemScheduler（reads/writes 拓扑校验）；false 时走 SusScheduler 兼容路径。earth_like.tres 已启用",
	},
	# ─── Phase F / dots-full-migration §F.1-F.6：6 hot pass C++ 化 flags ────
	# 任务 5（dots-completion）：7 个 hot pass flag 默认 false → true。
	# C++ stub 返回 -1.0 时仍透明 fallback 到 GDScript；earth_like.tres 生产 profile 已验证。
	{
		name = &"use_gdext_weather_field",
		owner = "weather.field_solver",
		default = true,
		resource = "ClimateProfile",
		description = "Phase F.1 (P0)：weather field solve C++ 化；目标 13ms → < 2ms",
	},
	{
		name = &"use_gdext_ocean_water",
		owner = "ocean.heat_transport",
		default = true,
		resource = "ClimateProfile",
		description = "Phase F.2a (P1)：ocean water pass C++ 化；目标 3.4ms → < 0.5ms",
	},
	{
		name = &"use_gdext_ocean_land",
		owner = "ocean.heat_transport",
		default = true,
		resource = "ClimateProfile",
		description = "Phase F.2b (P1)：ocean land pass C++ 化；目标 3.4ms → < 0.5ms",
	},
	{
		name = &"use_gdext_climate_pass_b",
		owner = "climate.pass_b",
		default = true,
		resource = "ClimateProfile",
		description = "Phase F.3 (P1)：climate Pass-B C++ 化；目标 5.2ms → < 0.5ms",
	},
	{
		name = &"use_gdext_sea_ice",
		owner = "climate.sea_ice",
		default = true,
		resource = "ClimateProfile",
		description = "Phase F.4 (P2)：sea ice daily pass C++ 化；目标 5.1ms → < 0.5ms；terrain 翻转走 ECB",
	},
	{
		name = &"use_gdext_sea_ice_atlas_prepare",
		owner = "rendering.sea_ice_atlas",
		default = true,
		resource = "ClimateProfile",
		description = "Prepare sea-ice R8 atlas buffer in DCWorldExt; Godot texture upload remains main-thread.",
	},
	{
		name = &"use_gdext_transpiration",
		owner = "biology.transpiration",
		default = true,
		resource = "ClimateProfile",
		description = "Phase F.5 (P2)：transpiration pass C++ 化；目标 3.2ms → < 0.3ms",
	},
	{
		name = &"use_gdext_weather_front",
		owner = "weather.fronts",
		default = true,
		resource = "ClimateProfile",
		description = "Phase F.6 (P3)：weather front advect C++ 化 + front pool DOTS 化；目标 3.0ms → < 0.5ms",
	},
	# ─── Weather Hot-Path C++ 化（dist + summary）：plan/weather-hotpath-cpp ───
	# 把 _distribute_weather_field_to_cells（~11.6ms）与 _build_field_summary_fronts
	# （~17.8ms）下沉到 DCWorldExt。两个 flag 独立切换；C++ 端持久化 prev_seeds /
	# prev_membership 跨 tick 维护，flag 切换时通过 reset_weather_summary_state() 清空。
	{
		name = &"use_gdext_weather_distribute",
		owner = "weather.distribute",
		default = true,
		resource = "ClimateProfile",
		description = "Weather hot-path：_distribute_weather_field_to_cells C++ 化；目标 11.6ms → < 1.5ms",
	},
	{
		name = &"use_gdext_weather_summary",
		owner = "weather.summary",
		default = true,
		resource = "ClimateProfile",
		description = "Weather hot-path：_build_field_summary_fronts C++ 化（含 BFS 继承 + EMA velocity）；目标 17.8ms → < 3.0ms",
	},
	{
		name = &"use_gdext_climate_pass_a",
		owner = "simulation.climate.pass_a",
		default = true,
		resource = "ClimateProfile",
		description = "PR-2.passA-unblock：climate Pass-A C++ 化；目标 ~10ms → < 0.5ms。dots-final-push 验收 PASS，默认开启",
	},
	{
		name = &"use_gdext_wind_field",
		owner = "simulation.ocean.wind_field",
		default = true,
		resource = "ClimateProfile",
		description = "Block B (P1)：wind field C++ 化；目标 p95 35.55ms → < 5ms。C++ 返回 fallback 时自动回退 GDScript",
	},
	{
		name = &"use_gdext_physical_circulation",
		owner = "simulation.ocean.physical",
		default = true,
		resource = "ClimateProfile",
		description = "C++ physical circulation path for wind/upwelling hot fields.",
	},
	{
		name = &"use_gdext_season_refresh",
		owner = "simulation.season_refresh",
		default = true,
		resource = "ClimateProfile",
		description = "C++ season refresh path when DCWorldExt exposes run_season_refresh_stage.",
	},
	# ─── Phase B+（2026-05-21）：season refresh round 一次跨界整 round 切片调度 ───
	# 上层调度升级：GDScript 跨界 12→1，facade sync 8→1，history push 8→1
	# （行为变更：B+ 路径下 round 末尾仅 1 次 push，修复 ring buffer 同 round
	# 多次写入的污染）。算法层完全复用 use_gdext_season_refresh 的 12 个 stage
	# C++ 实装；本 flag 仅切换调度路径。验收：1000-tick A/B diff
	# (terrain/landform/vegetation/cover/moisture, epsilon=0/1e-5) +
	# fast_ms p95 ≤5ms + stage 7 atomic 单帧 ≤3ms。
	{
		name = &"use_gdext_season_round",
		owner = "simulation.season_refresh",
		default = false,
		resource = "ClimateProfile",
		description = "Phase B+: season refresh full round in single C++ call with stage-boundary slicing.",
	},
	# ─── DOTS-Final-Push (plan/dots-final-push)：stage_b 三件套 C++ 化 ───────
	# 目标：weather_refresh p95 27.66ms → ≤ 5ms。三个 flag 独立切换；C++ 不可用
	# 时透明 fallback 到 GDScript 并打印一次 [stage_b] gdext path UNAVAILABLE。
	# 默认 false：上线前需完成 SAME_SOURCE A/B 30 tick numeric drift ≤ 1e-5 验收。
	{
		name = &"use_gdext_albedo",
		owner = "climate.albedo",
		default = true,
		resource = "ClimateProfile",
		description = "DOTS-Final-Push：_apply_albedo_pass C++ 化；目标 ~3.6ms → < 0.5ms。验收 PASS，默认开启",
	},
	{
		name = &"use_gdext_vegetation_dynamics",
		owner = "biology.vegetation_dynamics",
		default = true,
		resource = "ClimateProfile",
		description = "DOTS-Final-Push：_apply_vegetation_dynamics C++ 化（返回 vegetation_dirty 标志）；目标 ~9.2ms → < 1.0ms。验收 PASS，默认开启",
	},
	{
		name = &"use_gdext_climate_feedback",
		owner = "climate.weather_feedback",
		default = true,
		resource = "ClimateProfile",
		description = "DOTS-Final-Push：_apply_weather_to_map_feedback_pass C++ 化（小权重累加 ≤ 0.5%/日）；目标 ~6.1ms → < 0.5ms。验收 PASS，默认开启",
	},
	# ─── 方案 B：stage_b 三段合并（plan/stage-b-combine）─────────────────────
	# refresh_daily_stage_b 入口走单 cpp call run_stage_b_pass，把 albedo +
	# veg_dyn + feedback 三段合并执行，消除 GDScript 端 3 次 pack/unpack 围栏。
	# 前置条件：上面三个独立 cpp 路径已 ACTIVE（日志 first run elapsed < 0.1ms）。
	# 验收：SAME_SOURCE A/B 30 tick；目标 stage_b 累加 6–15ms → ≤ 1.5ms，
	# weather_refresh ran p95 3.51ms → ≤ 1.0ms。
	{
		name = &"use_gdext_stage_b_combined",
		owner = "climate.stage_b_combined",
		default = false,
		resource = "ClimateProfile",
		description = "方案 B：stage_b albedo+veg_dyn+feedback 合并单 cpp call，消除 pack/unpack 围栏；目标 6–15ms → ≤ 1.5ms",
	},
	# ─── DOTS-Final-Push：atlas pack C++ 化 ──────────────────────────────────
	# 与已有的 use_gdext_sea_ice_atlas_prepare 协作。目标：sea_ice_atlas_upload
	# p95 49.23ms → ≤ 8ms；enum_atlas_upload p95 ≤ 3ms。
	{
		name = &"use_gdext_enum_atlas_pack",
		owner = "rendering.enum_atlas",
		default = false,
		resource = "ClimateProfile",
		description = "DOTS-Final-Push：enum_atlas_upload 的 cell→PackedByteArray 打包走 C++（climate_vector / vegetation 等枚举轴）",
	},
	# ─── DOTS-Total-CPP（plan/dots-total-cpp）：所有剩余热点下沉 C++ ──────
	# 5 个新 flag 中 2 个复用已有的 use_gdext_season_refresh / use_gdext_ocean_water；
	# 下面三个为本计划新增。全部默认 false，SAME_SOURCE A/B 验收后才翻 true。
	{
		name = &"use_gdext_ocean_currents_pixel",
		owner = "rendering.ocean_currents",
		default = true,
		resource = "ClimateProfile",
		description = "DOTS-Total-CPP：bake_ocean_currents_slice 像素填充走 C++（仅产 PackedByteArray，不调 RenderingServer）。目标 25ms slice → < 6ms。验收 PASS，默认开启",
	},
	{
		name = &"use_gdext_weather_field_pixel",
		owner = "rendering.weather_field",
		default = true,
		resource = "ClimateProfile",
		description = "DOTS-Total-CPP：bake_weather_field_only 像素填充走 C++（仅产 PackedByteArray）。目标 wrapper ≤ 2ms。验收 PASS，默认开启",
	},
	{
		name = &"use_gdext_sea_ice_atlas_pack",
		owner = "rendering.sea_ice_atlas",
		default = true,
		resource = "ClimateProfile",
		description = "DOTS-Total-CPP：sea_ice_atlas_upload pack 走 C++ dirty-tile 增量打包（与 use_gdext_sea_ice_atlas_prepare 互补）。验收 PASS，默认开启",
	},
	# ─── Dirty-Push Atlas Encode（plan/dirty-push-atlas-encode）──────────────
	# 4 张运行期 atlas baker 改造：sim 端 setter / DCWorld write API 漏斗式
	# 推送 cell-level dirty mask；baker 入口 read_and_clear 一次拿 dirty cells
	# 喂给 chunk_step，避免 N=1e5 全图扫。配 sig 二防线避免量化后无变化的
	# GPU upload。阶段 F 接 DCWorldExt encode_* pass 走 C++/SIMD。
	{
		name = &"dirty_push_enabled",
		owner = "rendering.atlas",
		default = true,
		resource = "ClimateProfile",
		description = "Phase D：baker 入口走 DCWorld.read_and_clear_dirty_mask() 拿 dirty cells 替换 all_cells；fallback 到 all_cells 当 mask 不可用",
	},
	{
		name = &"cpp_atlas_encode_enabled",
		owner = "rendering.atlas",
		default = false,
		resource = "ClimateProfile",
		description = "Phase F：DCWorldExt encode_dynamic_cell_atlas / encode_ecology_visual_atlas / encode_dyn_smooth_atlas / encode_ice_state_atlas 4 个 C++/SIMD pass 启用；ext 缺失自动回退到 dirty_push_enabled 的 GDScript mask 路径",
	},
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
	{
		name = &"cpp_atlas_pipeline_enabled",
		owner = "rendering.atlas",
		default = true,
		resource = "ClimateProfile",
		description = "Phase G：4 张运行期 atlas（dynamic_cell/ecology_visual/dyn_smooth/ice_state）全管线 C++ 化。GD 端只剩 ImageTexture.update 薄壳。ext 缺失或 has_method 失败自动回退到旧 GD 4-phase 状态机",
	},
	# ─── plan/sim-2ms-simd-dirty-budget（2026-05-21）：SIMD 内核 + 线程兜底 ─
	# 复刻 bench_pass_a_full_simd 模板把 climate Pass-B / ocean water / ocean
	# land 三大 hot pass 升级到 AVX2 SIMD 8-lane + scalar tail；线程兜底独立
	# 总开关。所有 flag 默认 false，1000-tick mean ≥ 30% 加速 + 年度统计 |Δ|
	# < 0.5% 验收后逐项开启。前置 use_gdext_climate_pass_b / use_gdext_ocean_*
	# 必须 ACTIVE，否则 simd flag 静默忽略。
	{
		name = &"use_gdext_pass_b_simd",
		owner = "climate.pass_b",
		default = false,
		resource = "ClimateProfile",
		description = "plan/sim-2ms-simd-dirty-budget：climate Pass-B AVX2 SIMD 8-lane kernel；目标 0.86ms → < 0.15ms",
	},
	{
		name = &"use_gdext_ocean_water_simd",
		owner = "ocean.heat_transport",
		default = false,
		resource = "ClimateProfile",
		description = "plan/sim-2ms-simd-dirty-budget：ocean water pass AVX2 SIMD 8-lane kernel；目标 0.4ms → < 0.1ms",
	},
	{
		name = &"use_gdext_ocean_land_simd",
		owner = "ocean.heat_transport",
		default = false,
		resource = "ClimateProfile",
		description = "plan/sim-2ms-simd-dirty-budget：ocean land pass AVX2 SIMD 8-lane kernel；目标 0.4ms → < 0.1ms",
	},
	{
		name = &"use_gdext_thread_fallback",
		owner = "data_core.thread_fallback",
		default = false,
		resource = "ClimateProfile",
		description = "plan/sim-2ms-simd-dirty-budget：总开关，SIMD 路径不达标或大地图场景时启用 WorkerThreadPool _thread 降级（复刻 bench_pass_a_full_thread 模板）",
	},
	{
		name = &"use_atlas_dirty_throttle",
		owner = "rendering.map_baker",
		default = false,
		resource = "ClimateProfile",
		description = "plan/sim-2ms-simd-dirty-budget：enum atlas upload 节流。累积 dirty cell 数 / 跳过次数 / 距上次 flush 的 tick 数，达阈值才 image_create + texture.update。Godot 4 无 partial texture upload API（#65762），整图 1.8MB upload 是 1.27ms 瓶颈；节流目标 ≥50% 跳过率 → 节省 ~0.6-0.9ms。视觉残影由 64-tick 自愈 + 强制 flush 钩子兜底",
	},
	# plan/sim-2ms-simd-dirty-budget 任务 7（2026-05-21）：dynamic_visual_atlas pipeline
	# 4 个工作 phase（DYNAMIC / ECOLOGY / SMOOTH / ICE）的 dirty 路径 kill-switch。
	# 默认 true 与 cpp run_atlas_pipeline_step 现行 dirty 编码行为一致；false 时
	# dvas_system 不向 cpp 传 dirty_indices 且加 force_full_encode=true，cpp 覆盖
	# dirty_path_used=false → 4 phase 全部走 all_cells（与 cache_invalid 首帧路径
	# 等价），保留 SAME_SOURCE A/B 30 tick 校验能力（任务 7 验收 + 回归排障入口）。
	{
		name = &"use_gdext_dynamic_atlas_terminal_dirty",
		owner = "rendering.dynamic_visual_atlas",
		default = true,
		resource = "ClimateProfile",
		description = "plan/sim-2ms-simd-dirty-budget 任务 7：dynamic_visual_atlas 4 phase dirty 编码 kill-switch。默认 true 走 cpp 现行 dirty 路径；false 时 dvas_system 跳过传 dirty_indices 且 opts.force_full_encode=true 让 cpp 覆盖 dirty_path_used=false 强制全集编码。仅作为 A/B 对照与回归排障入口，生产无理由切 false",
	},
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
