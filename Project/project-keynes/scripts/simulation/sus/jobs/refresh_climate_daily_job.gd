# 使用路径引用 extends 而非 class_name 引用，避免 .godot/global_script_class_cache
# 在首次扫描时遇到"父类 class_name 尚未注册"的 parse 顺序问题。
extends "res://scripts/simulation/systems/climate_daily_system.gd"
class_name RefreshClimateDailyJob

## Phase W.1 — DCSystem 原生重写后的兼容薄壳（dots-migration-roadmap §I.2）。
##
## 原 419 行 6-stage round 切片逻辑 + 25 个 _comp_cell_* cache 已全部上提到
## [`ClimateDailySystem`](../../systems/climate_daily_system.gd)。本类作为
## 向后兼容的薄壳保留，让：
##   - map_generator.gd 的 `const RefreshClimateDailyJobScript = preload(...)`
##     在 `use_dc_system_scheduler=false` 路径下仍能直接 new 出合法的 SusJob 实例；
##   - 旧 plan 文档 / 注释引用 `RefreshClimateDailyJob` 类名时不至于断链；
##   - W.5 阶段彻底删除 legacy SUS register 路径时可直接 rm 本文件。
##
## 类层级：RefreshClimateDailyJob extends ClimateDailySystem extends DCSystem
##         extends SusJob。所有业务逻辑在 ClimateDailySystem。
##
## 构造参数与父类完全一致；本类不重写任何方法。
