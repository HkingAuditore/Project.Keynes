extends RefCounted
class_name DCDotsBootstrap

## Phase D.3 / dots-migration-roadmap §4.2 0.4：main.gd 拆分目的地。
## DCWorld + ViewAdapter + Scheduler 注册的所有引导逻辑。
##
## **当前状态**：骨架，main.gd 仍持有这些注册路径。
##
## ─── 待迁移代码段（从 main.gd 1901 行搬过来）──────────────────────
##
## 字段（从 main.gd var declaration 段搬）：
##   - `_view_adapter: DCViewAdapter` — 已在 B.1 添加
##   - `_dc_world` 相关引用 (_dcc_cp / _dc_cp 等 cache)
##   - `_dc_ecs_*` archetype 状态字段
##
## 函数：
##   - `_rebuild_view_adapter()` — Phase B.3 已加，迁本类
##   - DataCore CLI 解析（`_parse_data_core_cli` / `_apply_data_core_cli_to_profile`）
##   - DataCore runtime hot-toggle（`_toggle_data_core_weather_runtime` /
##     `_toggle_data_core_master_runtime`）
##   - DataCore flag snapshot（`_print_data_core_flag_snapshot`）
##   - 未来：use_dc_system_scheduler flag 接入（C.4 留给本 phase 完成）
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
## 1. 残留 main.gd 仅保留生命周期 + 输入处理；
## 2. 本类接受 main 节点的弱引用（用于读 generator / map / cp 等）；
## 3. 启动期由 main._ready 调 DCDotsBootstrap.new(self).bootstrap()；
## 4. 信号回调（ESC menu / hot-key）仍由 main 持有，但实际处理 forward 到本类。

func _init(_main_node) -> void:
	push_warning("[DCDotsBootstrap] not yet implemented — main.gd retains DataCore wiring")
