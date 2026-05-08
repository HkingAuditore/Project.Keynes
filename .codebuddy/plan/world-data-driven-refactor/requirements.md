# 需求文档 — 世界系统数据驱动重构（Terrain / Vegetation / Climate）

## 引言

Project Keynes 已经在天气系统（`WeatherProfile` + `res://data/weather/*.tres`）验证了"Godot Resource 作为配置文件"的数据驱动模式。但目前**地形（Terrain）、植被（Vegetation）、气候与生成规则（Climate / WorldGen）**这三大世界模拟核心仍然以硬编码形式散落在脚本中：

- 地形：[terrain_type.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\terrain_type.gd) 的 27 个枚举 + `_DATA` / `_NAME_CN` 两张 `const Dictionary`（通行性、移动消耗、调试色、中文名）
- 植被：[vegetation_type.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\vegetation_type.gd) 的 24 个枚举 + **8 张** `const Dictionary`（名称、蒸腾、反照率、eco_score、理想温/湿度、温/湿度容差、演替链 richer、演替链 harsher）
- 气候/生成规则：[map_generator.gd](d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\map_generator.gd) 的 **50+** 个 `const` 魔数（`RIVER_FLOW_PERCENTILE` / `OROGRAPHIC_BOOST` / `RAIN_SHADOW_FACTOR` / `SEASONAL_MOISTURE_SCALE` / `LAKE_SEED_*` / `TRANSPIRATION_*` / `MAX_VOLCANOES` …）

**结果**：
- 改一个地形颜色、调整一条演替链、换一套世界生成参数，都必须改代码并重启；
- 美术 / 策划无法离开程序独立工作；
- 无法做出"温带海洋世界 / 冰河世界 / 沙漠世界 / 群岛世界"这类可切换的**世界预设**；
- 新增一种地形或植被要同步改 2~8 张表，极易遗漏。

本次重构目标：引入 `TerrainProfile` / `VegetationProfile` / `ClimateProfile` 三类 Resource（沿用 `WeatherProfile` 的模式），将上述三块全部抽离到 `.tres` 文件中，使得：

- 新增 / 调整地形 = 新建或修改一个 `.tres` 文件，**不改代码**
- 新增 / 调整植被 = 新建或修改一个 `.tres` 文件，**不改代码**
- 切换世界生成参数 = 切换 `ClimateProfile` 引用，**可在运行期支持"世界预设"选择**
- 美术 / 策划可在 Inspector 直接编辑所有数值、颜色、演替链
- 对其他调用方（UI / 经济模型 / baker / shader）**保持 API 签名不变**（Facade 转发到 Registry）

**非目标**（本次不做）：
- **不修改** shader（`world_map.gdshader` / `hex_terrain.gdshader` 的 biome 配色与水面表现保持不变，shader 端配置化作为未来 Visual Overhaul 批次再做）
- **不新增** 任何地形 / 植被 / 生成参数（仅完成现有 27 个地形 + 24 个植被 + 50+ 个气候常量的等价迁移）
- **不修改** `map_generator.gd` 的生成算法本身（Pass 顺序、数学公式、阶段划分不变，仅把常量替换为 `_climate.xxx` 字段读取）
- **不修改** 天气系统（`WeatherProfile` 已完成，不动）
- **不实现** "世界预设选择 UI"（本次只保证 `ClimateProfile` 可切换，UI 留给未来批次）
- **不修改** `TerrainType.TERRAIN` / `VegetationType.VEG` 枚举的值和顺序（渲染 baker / shader 仍依赖下标）

**兼容性强约束**：重构后使用默认 Profile 生成的世界必须与重构前在**固定随机种子下地块级别 byte-equal**（或极小浮动 < 0.1%），以确保架构切换不引入玩法回归。

---

## 需求

### 需求 1 — TerrainProfile 资源定义

**用户故事：** 作为一名策划 / 美术，我希望每种地形的全部可调参数都由一个 `.tres` 资源文件描述，以便在 Godot Inspector 中直接编辑而无需改代码。

#### 验收标准

1. WHEN 工程中不存在 `TerrainProfile` 类 THEN 系统 SHALL 在 `res://scripts/data/terrain_profile.gd` 创建一个 `class_name TerrainProfile extends Resource` 的新资源类。
2. WHEN `TerrainProfile` 被定义 THEN 系统 SHALL 提供以下 `@export` 字段：`terrain_type: int`（对应 `TerrainType.TERRAIN` 枚举值）、`display_name: String`（英文键名，用于 debug）、`display_name_cn: String`（UI 中文名）、`passable_land: bool`、`passable_sea: bool`、`move_cost: int`、`base_color: Color`（baker / debug 调色）。
3. IF 未来 shader 需要扩展字段（例如 `shore_tint: Color` / `highlight_tint: Color`）THEN `TerrainProfile` SHALL 允许新增字段而不破坏现有 `.tres` 的加载（新增字段默认值合理）。
4. IF 用户在 Inspector 中修改某字段 THEN 该修改 SHALL 通过 `@export` 自动保存到 `.tres` 并被 Git 以文本 diff 形式记录。

### 需求 2 — 现有 27 种地形的 Profile 数据迁移

**用户故事：** 作为一名开发者，我希望现有 27 种地形的所有硬编码数值被原样迁移到独立的 `.tres` 文件中，以保证玩家观感与行为零回归。

#### 验收标准

1. WHEN 需求 1 完成 THEN 系统 SHALL 在 `res://data/terrain/` 目录下创建 27 个 Profile 资源文件，文件名与 `TerrainType.TERRAIN` 枚举键名小写一一对应（如 `ocean.tres` / `coast.tres` / `plain.tres` / … / `badlands.tres`）。
2. WHEN 所有 27 份 `.tres` 创建完成 THEN 其 `passable_land` / `passable_sea` / `move_cost` / `base_color` / `display_name_cn` 字段 SHALL 与迁移前 `terrain_type.gd` 的 `_DATA` 与 `_NAME_CN` 字典**完全一致**（Color 十六进制精确匹配，bool 精确匹配，int 精确匹配）。
3. WHEN 某个 `.tres` 被加载 THEN 其 `terrain_type` 字段 SHALL 精确等于对应的 `TerrainType.TERRAIN.XXX` 枚举整数值（便于 Registry 反向索引）。

### 需求 3 — TerrainProfileRegistry 注册表

**用户故事：** 作为一名开发者，我希望通过 `TerrainType.TERRAIN` 枚举值就能 O(1) 取到对应的 `TerrainProfile`，以便调用方无需关心资源路径。

#### 验收标准

1. WHEN 注册表被创建 THEN 系统 SHALL 在 `res://scripts/data/terrain_profile_registry.gd` 定义 `class_name TerrainProfileRegistry` 静态工具类。
2. WHEN 注册表首次被访问 THEN 系统 SHALL 通过 `ResourceLoader.load` 一次性加载全部 27 个 `.tres` 文件并缓存于 `Dictionary[int, TerrainProfile]`（key = `TerrainType.TERRAIN`）。
3. WHEN 调用 `TerrainProfileRegistry.get_profile(t: int) -> TerrainProfile` THEN 系统 SHALL 返回对应 Profile；IF 未找到 THEN 系统 SHALL 返回 `OCEAN` 的 Profile 作为兜底并 `push_warning`。
4. WHEN 某个 `.tres` 文件缺失或 `terrain_type` 字段不合法 THEN 系统 SHALL 保持游戏可运行（使用兜底），并在 Output 打印清晰错误信息。

### 需求 4 — terrain_type.gd Facade 瘦身

**用户故事：** 作为一名开发者，我希望 `terrain_type.gd` 重构后成为薄 Facade，保留枚举与静态查询方法签名，但内部转发到 Registry。

#### 验收标准

1. WHEN `terrain_type.gd` 被改造 THEN 系统 SHALL **保留** `enum TERRAIN` 不变（含 27 个枚举值和顺序）。
2. WHEN `terrain_type.gd` 被改造 THEN 系统 SHALL **删除** `_DATA` 与 `_NAME_CN` 两个常量字典。
3. WHEN `terrain_type.gd` 被改造 THEN 系统 SHALL **保留** `get_data()` / `is_passable_land()` / `is_passable_sea()` / `get_move_cost()` / `get_color()` / `terrain_name()` / `terrain_name_cn()` 七个静态方法的签名，但其实现 SHALL 改为转发到 `TerrainProfileRegistry.get_profile(t)` 的对应字段。
4. WHEN 其他脚本（baker / MapGenerator / UI / debug）调用上述方法 THEN 其行为 SHALL 与重构前**完全一致**（无需修改调用方代码）。

### 需求 5 — VegetationProfile 资源定义

**用户故事：** 作为一名策划 / 生态设计师，我希望每种植被的气候适应性、生态反馈、演替链全部由一个 `.tres` 描述，以便独立调参。

#### 验收标准

1. WHEN 工程中不存在 `VegetationProfile` 类 THEN 系统 SHALL 在 `res://scripts/data/vegetation_profile.gd` 创建一个 `class_name VegetationProfile extends Resource` 的新资源类。
2. WHEN `VegetationProfile` 被定义 THEN 系统 SHALL 提供以下 **身份** 字段：`veg_type: int`（对应 `VegetationType.VEG`）、`display_name_cn: String`。
3. WHEN `VegetationProfile` 被定义 THEN 系统 SHALL 提供以下 **生态物理** 字段：`transpiration: float`（[0, 1]）、`albedo: float`（[0, 1]）、`eco_score: float`（可负，典型 -0.8 ~ +1.2）。
4. WHEN `VegetationProfile` 被定义 THEN 系统 SHALL 提供以下 **气候适应性** 字段：`ideal_temp: float`（[0, 1]）、`ideal_moist: float`（[0, 1]）、`temp_tolerance: float`（默认 0.18）、`moist_tolerance: float`（默认 0.18）。
5. WHEN `VegetationProfile` 被定义 THEN 系统 SHALL 提供以下 **演替链** 字段：`next_richer: int`（升级下家的 `VegetationType.VEG` 值，-1 表示链尾）、`next_harsher: int`（退化下家的 `VegetationType.VEG` 值，-1 表示链尾）。
6. IF 用户在 Inspector 中修改某字段 THEN 该修改 SHALL 通过 `@export` 自动保存到 `.tres` 并被 Git 以文本 diff 形式记录。

### 需求 6 — 现有 24 种植被的 Profile 数据迁移

**用户故事：** 作为一名开发者，我希望现有 24 种植被的所有硬编码数值被原样迁移到独立的 `.tres` 文件中，以保证演替 / 生态反馈 / vitality 计算零回归。

#### 验收标准

1. WHEN 需求 5 完成 THEN 系统 SHALL 在 `res://data/vegetation/` 目录下创建 24 个 Profile 资源文件，文件名与 `VegetationType.VEG` 枚举键名小写一一对应（如 `none.tres` / `tundra.tres` / `taiga.tres` / `tropical_rainforest.tres` / `mangrove.tres` 等）。
2. WHEN 所有 24 份 `.tres` 创建完成 THEN 其 `transpiration` / `albedo` / `eco_score` / `ideal_temp` / `ideal_moist` / `display_name_cn` 字段 SHALL 与迁移前 `vegetation_type.gd` 的对应字典**完全一致**（float 精确匹配，字符串精确匹配）。
3. WHEN 某植被在原 `_TEMP_TOLERANCE` / `_MOIST_TOLERANCE` 中有自定义值 THEN 其 `.tres` 的 `temp_tolerance` / `moist_tolerance` 字段 SHALL 填入该自定义值；IF 原字典中不存在 THEN `.tres` 字段 SHALL 填入默认 0.18。
4. WHEN 某植被在原 `_NEXT_RICHER` / `_NEXT_HARSHER` 中有下家 THEN 其 `.tres` 的 `next_richer` / `next_harsher` 字段 SHALL 填入对应 `VegetationType.VEG` 整数值；IF 链尾（原字典中无 key） THEN 字段 SHALL 填入 `-1`（或自身 VEG 值）作为"链尾"哨兵。

### 需求 7 — VegetationProfileRegistry 与 vegetation_type.gd Facade

**用户故事：** 作为一名开发者，我希望植被系统和地形系统采用完全一致的 Registry + Facade 模式，以降低团队心智负担。

#### 验收标准

1. WHEN 注册表被创建 THEN 系统 SHALL 在 `res://scripts/data/vegetation_profile_registry.gd` 定义 `class_name VegetationProfileRegistry` 静态工具类，接口与 `TerrainProfileRegistry` 对称（`get_profile(v: int) -> VegetationProfile`）。
2. WHEN `vegetation_type.gd` 被改造 THEN 系统 SHALL **保留** `enum VEG` 不变（24 个值和顺序），并 **删除** 8 张常量字典。
3. WHEN `vegetation_type.gd` 被改造 THEN 系统 SHALL **保留** `name_cn()` / `transpiration()` / `albedo()` / `eco_score()` / `climate_compat_score()` / `next_in_succession()` 六个静态方法的签名，但内部实现 SHALL 改为从 Registry 取值。
4. WHEN `climate_compat_score(v, temp, moist)` 被调用 THEN 其返回值 SHALL 与重构前完全一致（高斯公式不变，只是 ideal/tolerance 来自 Profile 而非常量）。
5. WHEN `next_in_succession(v, direction)` 被调用 THEN 其行为 SHALL 与重构前完全一致；IF Profile 的 `next_richer` / `next_harsher` 等于 -1 或等于自身 veg_type THEN 方法 SHALL 返回原 `v`（链尾语义保持不变）。

### 需求 8 — ClimateProfile 资源定义

**用户故事：** 作为一名策划 / 世界设计师，我希望一整套世界生成参数（地形形态、湿度、季节、水文、生态反馈、特殊地物）由一个 `.tres` 描述，以便做出多套可切换的"世界预设"。

#### 验收标准

1. WHEN 工程中不存在 `ClimateProfile` 类 THEN 系统 SHALL 在 `res://scripts/data/climate_profile.gd` 创建一个 `class_name ClimateProfile extends Resource` 的新资源类。
2. WHEN `ClimateProfile` 被定义 THEN 系统 SHALL 按语义**分组**提供下列 `@export` 字段（字段名与 `map_generator.gd` 的原常量一一对应，便于对照）：

   **[大陆形态]**：`continent_warp_amp: float`、`dist_field_weight: float`、`noise_weight: float`、`ridge_boost_amp: float`、`meso_weight: float`、`offshore_amp: float`、`edge_falloff_start: float`、`edge_falloff_end: float`、`edge_falloff_depth: float`、`main_radius_min: float`、`main_radius_max: float`、`satellite_radius_min: float`、`satellite_radius_max: float`、`satellites_per_main: int`、`main_placement_min: float`、`main_placement_max: float`、`satellite_placement_min: float`、`satellite_placement_max: float`、`main_separation_factor: float`、`satellite_separation_factor: float`。

   **[湿度与降水]**：`coastal_moisture_boost: float`、`orographic_boost: float`、`rain_shadow_threshold: float`、`rain_shadow_factor: float`、`rain_shadow_lookback: int`、`prevailing_wind: Vector2`。

   **[季节]**：`seasonal_moisture_scale: Array[float]`（长度恒为 4）。

   **[水文]**：`river_flow_percentile: float`、`pit_fill_max_iters: int`、`lake_seed_freq: float`、`lake_seed_threshold: float`、`lake_seed_depth: float`、`lake_seed_min_interior: float`。

   **[植被→气候反馈]**：`transpiration_outflow_rate: float`、`transpiration_self_rate: float`、`veg_forest_donor: float`、`veg_swamp_donor: float`、`veg_grassland_donor: float`、`veg_desert_donor: float`、`veg_jungle_donor: float`、`veg_taiga_donor: float`、`veg_savanna_donor: float`、`veg_oasis_donor: float`、`veg_delta_donor: float`、`veg_salt_flat_donor: float`。

   **[特殊地物]**：`sea_ice_form_threshold: float`、`sea_ice_melt_threshold: float`、`max_volcanoes: int`、`volcano_min_dist: int`、`volcano_min_land_h: float`。

3. WHEN `ClimateProfile` 所有字段定义完成 THEN 其字段总数 SHALL **完整覆盖** `map_generator.gd` 中所有形如 `const XXX := YYY` 的顶层模块常量（本次需求中列出的 50+ 个），**不遗漏**，**不新增**。
4. IF 某个原常量带有 `# 已废弃` 注释（如 `PREVAILING_WIND`）THEN 该字段 SHALL 仍然被保留在 Profile 中（保持兼容），并在字段文档注释中同步"已废弃"说明。

### 需求 9 — 默认 ClimateProfile 数据迁移与 map_generator 接入

**用户故事：** 作为一名开发者，我希望创建一份"earth-like 默认 Profile"与当前硬编码常量完全等价，并把 `map_generator.gd` 的所有常量读取点改为从 Profile 读，以保证生成结果与重构前**完全一致**。

#### 验收标准

1. WHEN 需求 8 完成 THEN 系统 SHALL 在 `res://data/world/earth_like.tres` 创建一份默认 `ClimateProfile`，其每个字段值 SHALL 与 `map_generator.gd` 中对应 `const` 的当前值**完全一致**（float/int/Array 逐项精确匹配）。
2. WHEN `MapGenerator` 被改造 THEN 系统 SHALL 新增 `@export var climate_profile: ClimateProfile` 字段（在 Inspector 可指定；若为 null，则通过 `load("res://data/world/earth_like.tres")` 懒加载兜底）。
3. WHEN `MapGenerator._generate_xxx_pass` 系列方法内部需要读取某个原常量 THEN 系统 SHALL 改为读取 `climate_profile.xxx` 字段；原 `const` 定义 SHALL 被**删除**（避免双数据源）。
4. WHEN 使用**相同的随机种子和相同的默认 Profile** 运行生成 THEN 生成出的所有 HexCell 的 `terrain` / `landform` / `vegetation` / `elevation` / `moisture` / `temperature` 字段 SHALL 与重构前**完全一致**（float 允许 < 1e-5 的浮点误差，离散字段必须 byte-equal）。
5. IF 用户在 Inspector 中切换 `climate_profile` 到另一份 `.tres`（例如未来的 `ice_age.tres`） THEN `MapGenerator.generate()` SHALL 产出完全不同但合理的世界，且**无需重启引擎或修改任何代码**。

### 需求 10 — 自测与回归验证

**用户故事：** 作为一名开发者 / QA，我希望有一个可重复的自测步骤确认数据迁移的正确性，以便放心推进后续批次。

#### 验收标准

1. WHEN 重构完成后运行游戏 THEN 在任意固定种子下，重构前后生成的地图的 `terrain` 分布直方图、`vegetation` 分布直方图、海陆比例、河流数量 SHALL 完全一致（离散字段 byte-equal）。
2. WHEN 重构完成后 THEN 系统 SHALL 在 `res://scripts/data/` 下提供一个**可选的**自测脚本（如 `_registry_self_check.gd` 或 `_tool` 菜单项），启动时一次性打印：①27 个 TerrainProfile 是否全部成功加载、②24 个 VegetationProfile 是否全部成功加载、③ClimateProfile 所有字段是否非默认占位值。
3. WHEN 自测脚本检测到缺失 THEN 其 SHALL 在 Output 打印清晰的"缺失 XX.tres"警告，但不阻塞游戏启动（通过 Registry 的兜底机制继续运行）。
4. WHEN 重构完成后 THEN UI 面板（hex_info_panel 等）显示的地形中文名、植被中文名、可通行性 SHALL 与重构前完全一致。

### 需求 11 — 文档与示例

**用户故事：** 作为一名团队新成员，我希望看到一份清晰的"如何新增一种地形 / 植被 / 世界预设"文档，以便独立完成而无需阅读全部源码。

#### 验收标准

1. WHEN 重构完成 THEN 系统 SHALL 在 `res://data/README.md` 提供一份不超过 150 行的简短指南，分三小节描述：
   - **新增一种地形**：新建 `.tres` → 在 `TerrainType.TERRAIN` 枚举加值 → 在 `TerrainProfileRegistry._PATHS` 注册路径 → （可选）在 baker / shader 中处理新下标。
   - **新增一种植被**：新建 `.tres` → 在 `VegetationType.VEG` 枚举加值 → 在 `VegetationProfileRegistry._PATHS` 注册路径 → 检查演替链 `next_richer` / `next_harsher` 闭合。
   - **新增一种世界预设**：复制 `earth_like.tres` 重命名（如 `ice_age.tres`）→ 在 Inspector 调数值 → 在 `MapGenerator.climate_profile` 指向新 `.tres` → 无需改代码。
2. WHEN 指南被撰写 THEN 其 SHALL 包含至少一个完整示例（例如虚构的 "HOT_SPRING 温泉"地形或 "ice_age.tres" 世界预设）展示典型字段填写。
3. IF 某字段语义不明显（如 `rain_shadow_lookback` / `satellite_separation_factor` / `transpiration_outflow_rate`） THEN 指南 SHALL 提供一句话解释其含义与典型取值范围。

---

## 分阶段实施建议（对应任务文档）

为控制风险，本次重构**分三个独立阶段**交付，每个阶段都能独立合入且不阻塞其他阶段：

- **阶段 A（低风险，先做）**：需求 1~4，TerrainProfile + Registry + Facade + 27 个 tres 迁移
- **阶段 B（低风险，紧跟）**：需求 5~7，VegetationProfile + Registry + Facade + 24 个 tres 迁移
- **阶段 C（中风险，最后做）**：需求 8~9，ClimateProfile + 默认 earth_like.tres + map_generator.gd 接入（动 93KB 大文件，需谨慎回归）
- **阶段 D（收尾）**：需求 10~11，自测脚本 + README 文档

---

能否进入任务规划阶段？
