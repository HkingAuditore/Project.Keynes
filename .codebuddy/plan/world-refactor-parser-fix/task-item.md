# 实施计划 — 世界系统重构 Parser Error 根治（class_name 全局注册竞态）

本任务清单由 [requirements.md](d:\Godot\ProjectKeynes\Project.Keynes\.codebuddy\plan\world-refactor-parser-fix\requirements.md) 派生，需求 1~4 的代码修复已在对话中先行完成，本清单作为正式归档。

---

## 阶段 Fix — 6 个文件的 preload 加固（代码已合入，此任务用于 Code Review 对照）

- [x] 1. 为 `map_generator.gd` 补加 `ClimateProfileScript` preload
   - 在 `class_name MapGenerator` 与 `const WindBeltScript = preload(...)` 之后追加：
     `const ClimateProfileScript = preload("res://scripts/data/climate_profile.gd")`
   - 保持 `@export var climate_profile: ClimateProfile = null` 的类型注解不变
   - 保留原有解释注释（仿 WindBelt 那段），说明本 preload 的唯一目的是加载顺序
   - _需求：1.1, 1.2, 1.4_

- [x] 2. 为两个 Registry 补加其 Profile 类的 preload
   - `terrain_profile_registry.gd`：`class_name TerrainProfileRegistry` 后追加 `const _TerrainProfileScript = preload("res://scripts/data/terrain_profile.gd")`
   - `vegetation_profile_registry.gd`：`class_name VegetationProfileRegistry` 后追加 `const _VegetationProfileScript = preload("res://scripts/data/vegetation_profile.gd")`
   - 两个文件的 `_PROFILE_PATHS`、`ensure_loaded` / `get_profile` / `get_all_profiles` / `profile_count`、静态字段类型标注等实现保持不变
   - _需求：2.1, 2.2, 2.3, 2.4_

- [x] 3. 为两个 Facade（TerrainType / VegetationType）补加对 Registry 的 preload
   - `terrain_type.gd`：`class_name TerrainType` 后、`enum TERRAIN` 前追加 `const _TerrainProfileRegistryScript = preload("res://scripts/data/terrain_profile_registry.gd")`
   - `vegetation_type.gd`：`class_name VegetationType` 后、`enum VEG` 前追加 `const _VegetationProfileRegistryScript = preload("res://scripts/data/vegetation_profile_registry.gd")`
   - 两个 Facade 的 `enum` 定义、静态方法签名与实现保持不变，外部调用方无需修改
   - _需求：3.1, 3.2, 3.3, 3.4_

- [x] 4. 为 `_registry_self_check.gd` 补齐 5 条 preload
   - 在 `@tool` + `extends RefCounted` 之后追加 5 个下划线前缀 const：
     `_TerrainProfileScript` / `_VegetationProfileScript` / `_ClimateProfileScript` / `_TerrainRegistryScript` / `_VegetationRegistryScript`，路径各自指向对应 `.gd`
   - `_CLIMATE_DEFAULT_PATH` 常量与 `run_once` / `run` / `_check_*` 方法保持不变
   - _需求：4.1, 4.2, 4.3, 4.4_

---

## 阶段 Verify — 用户本地验证（需要用户执行，不能由工具代替）

- [ ] 5. 清缓存并冷启动验证 Parser Error 已根治
   - 关闭 Godot 编辑器进程
   - 删除 `d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\.godot\global_script_class_cache.cfg`（如步骤 5 仍报错，则进一步删除整个 `.godot\` 目录）
   - 重新打开 Godot 编辑器，等待全量 reimport 完成
   - 确认 Output 面板中不再出现 "Could not parse global class" 形式的 error
   - F5 启动游戏，进入主菜单 → 点击生成世界，确认能正常生成且观感与修复前一致（如需 byte-equal 验证，使用固定随机种子对比 HexCell 直方图）
   - _需求：5.1, 5.2, 5.3, 5.4_

---

## 阶段 Doc — 团队规范沉淀（防回归）

- [ ] 6. 在 `res://data/README.md` 新增"class_name 加载顺序防御"小节
   - 在已有的"新增地形 / 新增植被 / 新增世界预设"三小节之后追加新小节，标题可选 `@export var x: MyClass` 与 class_name 加载顺序
   - 正文要点：
     - 当脚本 A 在 `@export`、`static var`、方法签名类型注解或函数体中引用另一个 `class_name B` 时，在 A 文件顶部 `class_name A` 之后追加 `const _BScript = preload("res://path/to/b.gd")`
     - 常量名以下划线开头表示"仅为加载顺序服务、不被业务代码消费"
     - 即使未来 Godot 官方修复 class_name 注册顺序问题，该保护也不主动回退（作为防御性代码留存）
   - 附一张"正面样例表"，列出本次修复的 6 个文件与它们各自新增的 preload 常量，便于 Code Review 对照
   - 小节篇幅控制在 30 行以内，保持 README 整体不超过 150 行的约束
   - _需求：6.1, 6.2, 6.3_
