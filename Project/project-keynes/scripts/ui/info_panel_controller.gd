extends RefCounted
class_name DCInfoPanelController

## Phase D.3：右侧地块信息面板控制器拆分目的地。
##
## 当前 main.gd 持有 ~250 行 info panel 相关代码：
##   - @onready Label refs（_pos_label / _elev_label / _temp_label / ... 约 20 个）
##   - `_select_cell` / `_refresh_info_panel` (B.1 已改用 ViewAdapter)
##   - `_refresh_climate_line` / `_refresh_weather_line` / `_refresh_vitality_line`
##   - `_ensure_emergent_labels` + `_refresh_emergent_lines`
##   - `_temperature_band` / `_moisture_band` / `_elevation_band` / `_vitality_band`
##     / `_climate_zone_name`
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
## 1. 接受 main 节点 + ViewAdapter；
## 2. 信号源（_overlay_layer.cell_selected）仍由 main 转发；
## 3. UI Label refs 仍由 main 持有（@onready 必须在 Node 子类）；本类接收
##    一组 label 的 weak ref 作为构造参数；
## 4. 阶段 B.1 已把所有 cell.* 直接读改为 adapter.get_*；本类拆分时复用 adapter。
##
## 拆完后 main.gd 减少 ~250 行；本文件 ~250 行（行为完全 1:1 保留）。

func _init(_main_node, _adapter: DCViewAdapter) -> void:
	push_warning("[DCInfoPanelController] not yet implemented")
