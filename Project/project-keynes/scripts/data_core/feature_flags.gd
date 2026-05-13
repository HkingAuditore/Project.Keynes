extends RefCounted
class_name DCFeatureFlags

## DataCore — FeatureFlagRegistry（B1 / dots-migration-roadmap §3）。
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
		default = false,
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
		name = &"use_dc_system_scheduler",
		owner = "data_core.scheduler",
		default = false,
		resource = "ClimateProfile",
		description = "Phase C.4：true 时走 DCSystemScheduler；false 时走 SusScheduler 兼容路径",
	},
	# ─── Phase F / dots-full-migration §F.1-F.6：6 hot pass C++ 化 flags ────
	# 对应 DCWorldExt::run_<name>_pass stub。当前所有 stub 返回 -1.0 → fallback；
	# 后续 PR 填实际算法 + bit-equal 验收通过后切 true。
	{
		name = &"use_gdext_weather_field",
		owner = "weather.field_solver",
		default = false,
		resource = "ClimateProfile",
		description = "Phase F.1 (P0)：weather field solve C++ 化；目标 13ms → < 2ms",
	},
	{
		name = &"use_gdext_ocean_water",
		owner = "ocean.heat_transport",
		default = false,
		resource = "ClimateProfile",
		description = "Phase F.2a (P1)：ocean water pass C++ 化；目标 3.4ms → < 0.5ms",
	},
	{
		name = &"use_gdext_ocean_land",
		owner = "ocean.heat_transport",
		default = false,
		resource = "ClimateProfile",
		description = "Phase F.2b (P1)：ocean land pass C++ 化；目标 3.4ms → < 0.5ms",
	},
	{
		name = &"use_gdext_climate_pass_b",
		owner = "climate.pass_b",
		default = false,
		resource = "ClimateProfile",
		description = "Phase F.3 (P1)：climate Pass-B C++ 化；目标 5.2ms → < 0.5ms",
	},
	{
		name = &"use_gdext_sea_ice",
		owner = "climate.sea_ice",
		default = false,
		resource = "ClimateProfile",
		description = "Phase F.4 (P2)：sea ice daily pass C++ 化；目标 5.1ms → < 0.5ms；terrain 翻转走 ECB",
	},
	{
		name = &"use_gdext_transpiration",
		owner = "biology.transpiration",
		default = false,
		resource = "ClimateProfile",
		description = "Phase F.5 (P2)：transpiration pass C++ 化；目标 3.2ms → < 0.3ms",
	},
	{
		name = &"use_gdext_weather_front",
		owner = "weather.fronts",
		default = false,
		resource = "ClimateProfile",
		description = "Phase F.6 (P3)：weather front advect C++ 化 + front pool DOTS 化；目标 3.0ms → < 0.5ms",
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
