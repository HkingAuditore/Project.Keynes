# 需求文档 — 世界系统重构 Parser Error 根治（class_name 全局注册竞态）

## 引言

在 [`world-data-driven-refactor`](d:\Godot\ProjectKeynes\Project.Keynes\.codebuddy\plan\world-data-driven-refactor\requirements.md) 阶段 A/B/C 合入后，Godot 编辑器首次冷启动时抛出：

```
Parser Error: Could not parse global class "MapGenerator" from "res://scripts/map_generator.gd".
```

### 根因

Godot 4 的**全局类注册表**（磁盘缓存文件 `.godot/global_script_class_cache.cfg`）在首次扫描工程 / 新增 `class_name` 脚本时，会出现"**A 被解析时 B 还没注册到全局表**"的竞态：

1. `map_generator.gd` 在 `@export var climate_profile: ClimateProfile = null` 里把 `ClimateProfile`（一个 `class_name`）当作类型注解使用；
2. 若 Godot 调度顺序让 `map_generator.gd` 先被解析，此时 `climate_profile.gd` 的 `class_name ClimateProfile` 尚未注册到全局表，parser 找不到 `ClimateProfile` 类型；
3. `@export` 字段类型注解解析失败 → 整个 `map_generator.gd` 解析失败 → 全局类 `MapGenerator` 无法被注册；
4. 报错信息顶格展示为 "Could not parse global class MapGenerator"，容易被误解为 `map_generator.gd` 自身有语法问题。

**此问题在项目里已经出现过一次**：`map_generator.gd` 顶部的注释 `# 显式 preload，避免新建 class_name 文件时 Godot 全局类注册表偶发未拾取的问题` + `const WindBeltScript = preload("res://scripts/wind_belt.gd")` 就是针对 `WindBelt` 类踩过同一个坑。世界数据驱动重构一次性新增了 5 个 `class_name`（`ClimateProfile` / `TerrainProfile` / `VegetationProfile` / `TerrainProfileRegistry` / `VegetationProfileRegistry`），彼此之间以及它们与 `MapGenerator` / `TerrainType` / `VegetationType` 之间有多条类型引用链，竞态概率被放大，必须系统性加固。

### 目标

对所有**跨脚本引用了其它 class_name 的文件**，统一采用 `const XxxScript = preload("res://...gd")` 显式 preload，强制 Godot 在解析本脚本前先加载并注册被依赖的脚本。消除冷启动 / 首次导入 / 删除 `.godot/` 后重新导入时的偶发 parser error。

### 非目标

- **不修改** 数据驱动重构的业务逻辑（`MapGenerator` 生成算法、Registry 兜底策略、Facade 转发语义均保持不变）。
- **不删除** 已有的 `class_name` 声明。这些 `class_name` 仍然是官方推荐用法，提供静态类型、Inspector 友好度与 `as ClimateProfile` 的转型能力；本次修复只是**在依赖方补 preload 常量**，而不是改为纯 `preload` 替代 `class_name`。
- **不扩大范围** 到与本次 parser error 无关的其它 `class_name` 文件（如 `WeatherProfile` / `WindBelt` 等已有保护措施的脚本）。

### 兼容性强约束

- 所有 `preload` 常量命名统一为 `_XxxScript`（下划线前缀标记"仅为加载顺序服务、不被业务代码直接使用"），避免与业务代码里已有的变量/常量冲突。
- `preload` 常量**不得**被业务代码消费（否则会形成真正的运行期依赖、影响热重载）；业务代码继续通过 `class_name` 符号引用类型。
- 修复后在 `.godot/` 被整体删除的情况下，重新打开 Godot 编辑器必须**一次**成功完成全量 reimport 且不再抛 "Could not parse global class" 错误。

---

## 需求

### 需求 1 — MapGenerator 对 ClimateProfile 的显式 preload

**用户故事：** 作为一名开发者，我希望 `map_generator.gd` 在解析阶段就确定性地能找到 `ClimateProfile` 类型，以便 `@export var climate_profile: ClimateProfile` 字段不再因全局类注册顺序而报 parser error。

#### 验收标准

1. WHEN `map_generator.gd` 被加载 THEN 文件顶部 `class_name MapGenerator` 之后 SHALL 存在 `const ClimateProfileScript = preload("res://scripts/data/climate_profile.gd")` 语句。
2. WHEN 该 preload 被添加 THEN `@export var climate_profile: ClimateProfile = null` 字段 SHALL 保持类型注解不变（仍为 `ClimateProfile` 而非 `Resource`）。
3. WHEN Godot 在 `.godot/` 被清空的情况下冷启动 THEN Output 面板 SHALL 不出现 "Could not parse global class MapGenerator" 错误。
4. IF 未来在 `map_generator.gd` 中新增对另一个 `class_name` 的类型引用 THEN 开发者 SHALL 在同一区块追加对应的 `_XxxScript` preload 常量。

### 需求 2 — 两个 Registry 对其 Profile 类的显式 preload

**用户故事：** 作为一名开发者，我希望 `TerrainProfileRegistry` / `VegetationProfileRegistry` 在解析时能确定性地找到 `TerrainProfile` / `VegetationProfile` 类型，以便静态字段类型标注（如 `static var _fallback: TerrainProfile = null` 与返回类型 `-> TerrainProfile`）不引发 parser error。

#### 验收标准

1. WHEN `terrain_profile_registry.gd` 被加载 THEN 文件顶部 `class_name TerrainProfileRegistry` 之后 SHALL 存在 `const _TerrainProfileScript = preload("res://scripts/data/terrain_profile.gd")` 语句。
2. WHEN `vegetation_profile_registry.gd` 被加载 THEN 文件顶部 `class_name VegetationProfileRegistry` 之后 SHALL 存在 `const _VegetationProfileScript = preload("res://scripts/data/vegetation_profile.gd")` 语句。
3. WHEN 上述 preload 被添加 THEN 两份 Registry 的 `_PROFILE_PATHS` 字典、`ensure_loaded` / `get_profile` / `get_all_profiles` / `profile_count` 等静态方法 SHALL 保持实现不变。
4. WHEN 运行时调用 `TerrainProfileRegistry.get_profile(0)` 与 `VegetationProfileRegistry.get_profile(0)` THEN 返回值 SHALL 与本次修复前完全一致（值语义不变）。

### 需求 3 — 两个 Facade（TerrainType / VegetationType）对 Registry 的显式 preload

**用户故事：** 作为一名开发者，我希望 `terrain_type.gd` / `vegetation_type.gd` 这两个 Facade 在解析时能确定性地找到 `TerrainProfileRegistry` / `VegetationProfileRegistry` 类，以便任何首次扫描序列下静态方法 `TerrainProfileRegistry.get_profile(...)` 的调用点都可被解析器识别。

#### 验收标准

1. WHEN `terrain_type.gd` 被加载 THEN 文件顶部 `class_name TerrainType` 之后 SHALL 存在 `const _TerrainProfileRegistryScript = preload("res://scripts/data/terrain_profile_registry.gd")` 语句。
2. WHEN `vegetation_type.gd` 被加载 THEN 文件顶部 `class_name VegetationType` 之后 SHALL 存在 `const _VegetationProfileRegistryScript = preload("res://scripts/data/vegetation_profile_registry.gd")` 语句。
3. WHEN 上述 preload 被添加 THEN 两份 Facade 的 `enum TERRAIN` / `enum VEG` 及所有 Facade 静态方法 SHALL 保持签名与实现逻辑不变（仍然转发到 Registry）。
4. WHEN 外部调用方（baker / MapGenerator / UI）消费 `TerrainType.get_data()` / `VegetationType.name_cn()` 等方法 THEN 行为 SHALL 与本次修复前完全一致。

### 需求 4 — 自测脚本 `_registry_self_check.gd` 的完整 preload 集

**用户故事：** 作为一名开发者，我希望 `@tool` 自测脚本在编辑期加载时不因任何一个它引用的 class_name 未注册而 parse 失败，以保证自测工具"永远可用"。

#### 验收标准

1. WHEN `_registry_self_check.gd` 被加载 THEN 文件顶部 `@tool` + `extends RefCounted` 之后 SHALL 存在一组 preload 常量，覆盖它引用的**全部** 5 个 class_name：`TerrainProfile` / `VegetationProfile` / `ClimateProfile` / `TerrainProfileRegistry` / `VegetationProfileRegistry`。
2. WHEN preload 常量被添加 THEN 它们的命名 SHALL 全部采用下划线前缀（如 `_TerrainProfileScript`），保持"仅为加载顺序服务"的语义清晰。
3. WHEN 用户通过 `Project → Tools → Run Script...` 或 `load(...).new().run()` 执行自测 THEN 输出的 27+24+1 份资源加载报告 SHALL 与本次修复前完全一致。
4. IF 未来扩展自测脚本以覆盖更多 class_name（例如 `WeatherProfile`）THEN 开发者 SHALL 在 preload 常量区块追加对应项。

### 需求 5 — 回归验证与缓存清理流程

**用户故事：** 作为一名开发者 / QA，我希望有一个可重复的验证步骤确认 parser error 已被根治，以便放心关闭该问题。

#### 验收标准

1. WHEN 所有 preload 加固完成 THEN 验证流程 SHALL 至少包含以下步骤：① 关闭 Godot 编辑器 → ② 删除项目 `.godot/global_script_class_cache.cfg` → ③ 重新打开 Godot 编辑器 → ④ 等待 reimport 完成。
2. WHEN 上述流程执行完成 THEN Output 面板 SHALL 不再出现任何 "Could not parse global class" 形式的 error。
3. WHEN reimport 完成后 THEN 按 F5 启动游戏 SHALL 能顺利进入主菜单并生成世界，生成结果（离散字段）与本次修复前在相同随机种子下**完全一致**（byte-equal）。
4. IF ③ 步重启后仍有同类 parser error THEN 开发者 SHALL 进一步删除整个 `.godot/` 目录重新触发全量 reimport；IF 仍不能修复 THEN 说明仍有漏网 class_name 引用需排查，SHALL 在 `requirements.md` 追加一轮需求。

### 需求 6 — 开发规范沉淀（防回归）

**用户故事：** 作为一名团队新成员，我希望有一条清晰的规则告诉我"新增 class_name 脚本被另一个 class_name 脚本引用时该做什么"，以便不再重复踩这个坑。

#### 验收标准

1. WHEN 本次修复完成 THEN 系统 SHALL 在 [`res://data/README.md`](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\README.md)（阶段 D 创建的指南文档）新增一个小节 "`@export var x: MyClass` 与 class_name 加载顺序"，说明：
   - 当脚本 A 在 `@export`、`static var`、方法签名类型注解或函数体中引用另一个 `class_name B` 时，A 文件顶部 SHALL 追加 `const _BScript = preload("res://path/to/b.gd")`；
   - `_BScript` 常量名以**下划线开头**表示"仅为加载顺序服务，不被业务代码消费"；
   - 该保护在 Godot 修复 class_name 注册顺序问题之后仍然无害，不需要在未来回退。
2. WHEN 该小节被撰写 THEN 其 SHALL 提供本次修复的 6 个文件作为"正面样例表"（文件 → 新增的 preload 清单），方便团队 Code Review 比对。
3. IF Godot 官方后续发布修复 class_name 注册顺序的版本 THEN 本规则 SHALL 保留（作为防御性代码），不主动回滚。

---

## 实施建议

本次修复范围窄、风险低，**一个阶段即可完成**：

- **阶段 Fix**：需求 1~4，6 个文件的 preload 加固（实际已在对话中直接完成，见 git commit 历史）；
- **阶段 Verify**：需求 5，开发者本地执行"清缓存 → 重启 → F5"验证；
- **阶段 Doc**：需求 6，在 `data/README.md` 沉淀规范。

---

能否进入任务规划阶段？
