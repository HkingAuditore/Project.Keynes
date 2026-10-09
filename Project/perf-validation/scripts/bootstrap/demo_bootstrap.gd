extends RefCounted
class_name DCDemoBootstrap

## Phase D.3：demo_thermal_gradient 接入逻辑拆分目的地。
##
## ─── 待迁移代码段 ────────────────────────────────────────────────
##   - main.gd 内 `_run_demo_thermal_gradient_pass_if_enabled`
##   - DCEcsScheduler 创建 + register（仅在 demo path 用）
##   - DCEcsArchetype 状态字段 `_dc_ecs_archetype_dirty` /
##     `_dc_ecs_land_archetype_id`
##   - performance-charter §12.6 Pass #2/#3 接入（含 LEGACY / ECS / ECS_ARCHETYPE
##     三 dispatch path 切换，由 ClimateProfile.demo_thermal_gradient_path enum 决定）
##   - F-key 调试热键（F8/F9/F10/F11/F12 中与 demo 相关的部分）
##
## 拆完后本文件 ~200 行；main.gd 仅保留"按 day_changed 信号调用 demo bootstrap.tick"。

func _init(_main_node) -> void:
	push_warning("[DCDemoBootstrap] not yet implemented")
