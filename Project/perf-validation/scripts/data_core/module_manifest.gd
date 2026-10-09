@tool
extends Resource
class_name DCModuleManifest

## DataCore — Module Manifest（B1 / dots-migration-roadmap §3）。
##
## 每个 DOTS 模块（climate / weather / economy / unit / AI / pollution …）
## 在自己的目录根放一份 `module_manifest.tres`，声明：
##   1. **读 / 写哪些 component**（reads / writes）→ 调度器 debug 校验依据；
##   2. **依赖哪些 pool / archetype**（pools / archetypes）→ 启动期 sanity check；
##   3. **挂在哪个 feature flag 下**（feature_flag）→ 与 DCFeatureFlags 对接；
##   4. **支持哪些 dispatch path**（legacy / dots_gdscript / dots_cpp / dots_cpp_async）；
##   5. **owner / 维护团队**（owner）→ dot-graph / module-ownership-map.md 生成。
##
## 调度器（DCSystemScheduler，Phase C.2）在 system register 时读取 manifest，
## 把 `declare_reads()` / `declare_writes()` 与 `manifest.reads` / `.writes`
## 做并集校验：如果 system 写了一个 manifest 没声明的 component，debug
## 构建 push_error 中止；这就是"模块互不影响"的物理保证。
##
## 加新模块的 SOP（dots-migration-roadmap §5 Step 1）：
##   1. 在模块根（如 scripts/simulation/economy/）创建 module_manifest.tres：
##        load("res://scripts/data_core/module_manifest.gd").new()
##        然后在 inspector 里填写 reads / writes / pools / archetypes /
##        feature_flag / dispatch_paths
##   2. 写新 DCSystem 子类，declare_reads/writes 与 manifest 1:1 对齐；
##   3. 在主 bootstrap 路径加 `if DCFeatureFlags.is_on(manifest.feature_flag, cp):`
##      → register system；
##   4. 完成。
##
## 资源类设计（@tool 让 inspector 编辑）：所有字段都是 @export，让
## module_manifest.tres 可以在 Godot editor 里直接图形化编辑。

# 模块逻辑名（如 &"climate" / &"weather" / &"economy"）。
# 不同模块的 module_id 必须唯一；DCSystemScheduler 注册时会校验。
@export var module_id: StringName = &""

# 关联的 feature flag（DCFeatureFlags.FLAGS 表里的 name）。
# 调度器 register 时调 `DCFeatureFlags.is_on(feature_flag, cp)` 决定是否挂载。
# 留空表示该模块"无 toggle，常驻挂载"（如 enum_atlas_upload 这类基础设施）。
@export var feature_flag: StringName = &""

# Component 名清单（DCComponentSchema.CELL_SCHEMA 中 entry.name 的子集）。
# 调度器 debug 校验：system 读 / 写到不在本表内的 component 时 push_error。
# 命名约定：`cell.<field>` / `front.<field>` / `<module>.<field>` 三段命名空间。
@export var reads: Array[StringName] = []
@export var writes: Array[StringName] = []

# Pool 名清单（DCComponentIds.POOL_* 形式，如 &"cells" / &"weather_fronts"）。
# 启动期 sanity check：system declare_pools() 应是 manifest.pools 的子集。
@export var pools: Array[StringName] = []

# Archetype 名清单（DCComponentIds.ARCH_* 形式，如 &"arch.weather_front"）。
@export var archetypes: Array[StringName] = []

# 该模块支持的 dispatch path 列表（按推荐顺序：legacy → 最高性能）。
# 实际选哪条由 ClimateProfile / 同名 enum / dispatch flag 决定；本字段仅
# 作元数据让"模块能跑哪几条 path"在一处可查。
#
# 标准取值（任意子集组合）：
#   "legacy"           — 纯 GDScript AoS 实现，永远存在的回退路径
#   "dots_gdscript"    — DCSystem + GDScript view_f32 hot loop
#   "dots_cpp"         — DCWorldExt::run_<module>_pass，C++ scalar
#   "dots_cpp_simd"    — 同上 + AVX2（performance-charter §3.1 触发条件）
#   "dots_cpp_thread"  — 同上 + WorkerThreadPool（§3.2 触发条件）
#   "dots_cpp_async"   — D-async（cpp-async-experiment-report 验证的 task pool）
@export var dispatch_paths: PackedStringArray = PackedStringArray(["legacy"])

# 业务 owner / 维护团队（dot-graph、module-ownership-map.md 生成用）。
@export var owner: String = ""

# 一句话描述（onboarding 文档 / debug overlay 用）。
@export var description: String = ""

# 关联的 .gd 文件路径（system 实现入口）。仅作文档/调试用。
@export var system_script_path: String = ""


## 校验本 manifest 是否合法（启动期由调度器调用）。
## 返回错误描述；空字符串表示通过。
func validate() -> String:
	if module_id == &"":
		return "module_id is empty"
	# Pool / archetype / component 名命名空间约定（仅 push_warning，不强制）
	for c in reads:
		if not _is_valid_component_namespace(c):
			push_warning("[DCModuleManifest:%s] reads contains unconventional name '%s' (expected cell.* / front.* / <module>.*)"
				% [String(module_id), String(c)])
	for c in writes:
		if not _is_valid_component_namespace(c):
			push_warning("[DCModuleManifest:%s] writes contains unconventional name '%s'"
				% [String(module_id), String(c)])
	# dispatch_paths 必须至少有一项
	if dispatch_paths.is_empty():
		return "dispatch_paths is empty (must contain at least 'legacy')"
	# feature_flag 若非空，应该在 DCFeatureFlags.FLAGS 里登记
	if feature_flag != &"" and not DCFeatureFlags.is_known(feature_flag):
		return "feature_flag '%s' is not registered in DCFeatureFlags.FLAGS" % String(feature_flag)
	return ""


## 该 manifest 是否声明了 component（按 read 或 write 任一方向）。
## DCSystemScheduler debug 校验时用：system 用了某 component 但 manifest 没声明 → 报错。
func declares(comp_name: StringName) -> bool:
	return reads.has(comp_name) or writes.has(comp_name)


## 该 manifest 是否声明了 component 为 read。
func declares_read(comp_name: StringName) -> bool:
	return reads.has(comp_name)


## 该 manifest 是否声明了 component 为 write。
func declares_write(comp_name: StringName) -> bool:
	return writes.has(comp_name)


## 调试摘要（debug overlay / log 用）。
func describe() -> String:
	return "DCModuleManifest[%s] flag=%s reads=%d writes=%d pools=%d paths=%s" % [
		String(module_id),
		String(feature_flag) if feature_flag != &"" else "(none)",
		reads.size(),
		writes.size(),
		pools.size(),
		str(Array(dispatch_paths)),
	]


# 内部：合法命名空间是 `cell.*` / `front.*` / `topology.*` / `<module>.*`。
# 这里只检查"包含 .（dot）字符"作为弱约束；严格分类留给后续 lint 工具。
static func _is_valid_component_namespace(c: StringName) -> bool:
	var s: String = String(c)
	return "." in s
