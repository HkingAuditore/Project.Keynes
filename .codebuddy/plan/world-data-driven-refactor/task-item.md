# 实施计划 — 世界系统数据驱动重构（Terrain / Vegetation / Climate）

本任务清单由 [requirements.md](d:\Godot\ProjectKeynes\Project.Keynes\.codebuddy\plan\world-data-driven-refactor\requirements.md) 派生，按四个阶段组织。每一阶段均可独立合入；阶段 C 改动 `map_generator.gd` 大文件，必须在阶段 A/B 之后执行。

---

## 阶段 A — 地形数据驱动（低风险，先做）

- [ ] 1. 创建 TerrainProfile 资源类与 27 份 tres 数据迁移
   - 新建 `res://scripts/data/terrain_profile.gd`，`class_name TerrainProfile extends Resource`，定义字段：`terrain_type: int` / `display_name: String` / `display_name_cn: String` / `passable_land: bool` / `passable_sea: bool` / `move_cost: int` / `base_color: Color`（所有字段带 `@export` 与合理默认值）
   - 在 `res://data/terrain/` 下创建 27 个 `.tres`（`ocean.tres` / `coast.tres` / `plain.tres` / `grassland.tres` / `forest.tres` / `hill.tres` / `mountain.tres` / `desert.tres` / `tundra.tres` / `snow.tres` / `swamp.tres` / `jungle.tres` / `savanna.tres` / `taiga.tres` / `steppe.tres` / `shrubland.tres` / `mangrove.tres` / `glacier.tres` / `lake.tres` / `reef.tres` / `sea_ice.tres` / `kelp.tres` / `delta.tres` / `oasis.tres` / `salt_flat.tres` / `badlands.tres`，以及 `ocean.tres`=0 下的其余全集）
   - 每份 `.tres` 的字段值严格复制自当前 `terrain_type.gd` 的 `_DATA` 与 `_NAME_CN`（Color 十六进制、bool、int 精确一致）
   - _需求：1.1, 1.2, 1.4, 2.1, 2.2, 2.3_

- [ ] 2. 实现 TerrainProfileRegistry 并把 terrain_type.gd 改为 Facade
   - 新建 `res://scripts/data/terrain_profile_registry.gd`（`class_name TerrainProfileRegistry`）：内部维护 `_PATHS: Dictionary[int, String]` 与懒加载缓存 `_CACHE: Dictionary[int, TerrainProfile]`，暴露静态方法 `get_profile(t: int) -> TerrainProfile`；未命中时返回 `OCEAN` 兜底并 `push_warning`
   - 修改 `res://scripts/terrain_type.gd`：保留 `enum TERRAIN` 不动；删除 `_DATA` 与 `_NAME_CN` 两个常量字典；将 `get_data` / `is_passable_land` / `is_passable_sea` / `get_move_cost` / `get_color` / `terrain_name` / `terrain_name_cn` 七个静态方法的实现改为转发到 `TerrainProfileRegistry.get_profile(t)` 对应字段；方法签名保持不变
   - 启动工程确认 baker / MapGenerator / UI 调用方行为与重构前一致
   - _需求：3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 4.4_

---

## 阶段 B — 植被数据驱动（低风险，紧跟）

- [ ] 3. 创建 VegetationProfile 资源类与 24 份 tres 数据迁移
   - 新建 `res://scripts/data/vegetation_profile.gd`，`class_name VegetationProfile extends Resource`，字段：`veg_type: int` / `display_name_cn: String` / `transpiration: float` / `albedo: float` / `eco_score: float` / `ideal_temp: float` / `ideal_moist: float` / `temp_tolerance: float`（默认 0.18） / `moist_tolerance: float`（默认 0.18） / `next_richer: int`（默认 -1） / `next_harsher: int`（默认 -1）
   - 在 `res://data/vegetation/` 下创建 24 个 `.tres`，文件名对应 `VegetationType.VEG` 枚举小写（`none` / `polar_desert` / `tundra` / `alpine_tundra` / `alpine_meadow` / `taiga` / `boreal_shrub` / `temperate_deciduous` / `temperate_conifer` / `temperate_grassland` / `temperate_steppe` / `mediterranean_shrub` / `subtropical_forest` / `savanna` / `tropical_rainforest` / `tropical_dry_forest` / `desert_scrub` / `xeric_desert` / `oasis_veg` / `mangrove` / `swamp` / `marsh` / `kelp_forest` / `coral_reef`）
   - 每份 `.tres` 严格复制自当前 `vegetation_type.gd` 的 `_NAME_CN` / `_TRANSPIRATION` / `_ALBEDO` / `_ECO_SCORE` / `_IDEAL_TEMP` / `_IDEAL_MOIST` / `_TEMP_TOLERANCE` / `_MOIST_TOLERANCE` / `_NEXT_RICHER` / `_NEXT_HARSHER`；容差字典未命中时填 0.18；演替链字典未命中时填 -1
   - _需求：5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 6.1, 6.2, 6.3, 6.4_

- [ ] 4. 实现 VegetationProfileRegistry 并把 vegetation_type.gd 改为 Facade
   - 新建 `res://scripts/data/vegetation_profile_registry.gd`（`class_name VegetationProfileRegistry`），接口与 `TerrainProfileRegistry` 对称：`get_profile(v: int) -> VegetationProfile`，兜底返回 `VEG.NONE` 的 profile 并 `push_warning`
   - 修改 `res://scripts/vegetation_type.gd`：保留 `enum VEG`；删除 8 张常量字典；保留 `name_cn` / `transpiration` / `albedo` / `eco_score` / `climate_compat_score` / `next_in_succession` 六个静态方法签名，内部改为从 Registry 取值
   - `climate_compat_score` 的高斯公式不动；`next_in_succession` 遇到 `next_richer == -1` 或 `next_harsher == -1` 或等于自身 veg_type 时返回原 `v`（链尾语义不变）
   - _需求：7.1, 7.2, 7.3, 7.4, 7.5_

---

## 阶段 C — 气候/世界生成数据驱动（中风险，动大文件）

- [ ] 5. 创建 ClimateProfile 资源类并定义全部字段分组
   - 新建 `res://scripts/data/climate_profile.gd`，`class_name ClimateProfile extends Resource`
   - 按语义分组定义 `@export` 字段，完整覆盖 `map_generator.gd` 顶层模块所有 `const`（大陆形态 20 项 / 湿度与降水 6 项 / 季节 1 项 Array[float] / 水文 6 项 / 植被→气候反馈 12 项 / 特殊地物 5 项），字段名与原常量名一一对应（小写下划线），已废弃字段（如 `prevailing_wind`）保留并在注释中标注"已废弃"
   - 为每个字段填入与当前 `map_generator.gd` const 完全一致的默认值（确保即便 tres 未指定也不会跑偏）
   - _需求：8.1, 8.2, 8.3, 8.4_

- [ ] 6. 创建 earth_like.tres 并把 map_generator.gd 改为读 ClimateProfile
   - 在 `res://data/world/earth_like.tres` 创建默认 `ClimateProfile` 资源，所有字段值与 `map_generator.gd` 对应 `const` 逐项精确一致
   - 修改 `res://scripts/map_generator.gd`（大文件）：
     - 在类顶部新增 `@export var climate_profile: ClimateProfile`，`_ready` / `generate` 入口中若 `climate_profile == null` 则 `load("res://data/world/earth_like.tres")` 懒加载
     - 将 50+ 个原 `const`（`RIVER_FLOW_PERCENTILE` / `OROGRAPHIC_BOOST` / `RAIN_SHADOW_*` / `SEASONAL_MOISTURE_SCALE` / `CONTINENT_WARP_AMP` / `EDGE_FALLOFF_*` / `MAIN_RADIUS_*` / `SATELLITE_*` / `LAKE_SEED_*` / `VEG_*_DONOR` / `TRANSPIRATION_*` / `SEA_ICE_*` / `MAX_VOLCANOES` / `VOLCANO_*` 等）**全部删除**
     - 所有原 const 引用点替换为 `climate_profile.xxx`（用 Ripgrep 精确定位每一处引用；避免双数据源）
   - _需求：9.1, 9.2, 9.3, 9.5_

- [ ] 7. 验证 map_generator 固定种子下生成结果 byte-equal
   - 重构前用固定 seed 跑一次生成，记录每个 HexCell 的 `terrain` / `landform` / `vegetation` / `elevation` / `moisture` / `temperature` 快照（或直接记录 terrain 分布直方图、海陆比例、河流数量）
   - 重构后用同一 seed + 默认 `earth_like.tres` 再跑一次，离散字段逐格 byte-equal，浮点字段 `< 1e-5` 误差
   - 不通过时修正常量值或调用点，直到满足
   - _需求：9.4, 10.1_

---

## 阶段 D — 收尾（自测脚本 + 文档）

- [ ] 8. 添加 Registry 自测脚本
   - 新建 `res://scripts/data/_registry_self_check.gd`（`@tool` 或挂一个开发期 autoload）
   - 启动时打印：①27 个 TerrainProfile 加载状态；②24 个 VegetationProfile 加载状态；③ClimateProfile 关键字段是否为默认占位值（如全 0）
   - 任一缺失时 `push_warning` 清晰提示"缺失 `res://data/xxx/yyy.tres`"，但不阻塞游戏启动（依赖 Registry 的兜底）
   - _需求：10.2, 10.3, 10.4_

- [ ] 9. 撰写 `res://data/README.md` 指南
   - 三小节：**新增地形**（新建 tres → 改 TERRAIN 枚举 → 改 `TerrainProfileRegistry._PATHS` → 可选处理 baker/shader 下标）、**新增植被**（新建 tres → 改 VEG 枚举 → 改 `VegetationProfileRegistry._PATHS` → 检查演替链闭合）、**新增世界预设**（复制 earth_like.tres 重命名 → Inspector 调数值 → `MapGenerator.climate_profile` 指向）
   - 至少包含一个完整示例（推荐 `ice_age.tres` 世界预设，列出关键字段如何从 earth_like 偏移）
   - 对语义不直观的字段（`rain_shadow_lookback` / `satellite_separation_factor` / `transpiration_outflow_rate` 等）给一句话说明与典型取值
   - 全文不超过 150 行
   - _需求：11.1, 11.2, 11.3_
