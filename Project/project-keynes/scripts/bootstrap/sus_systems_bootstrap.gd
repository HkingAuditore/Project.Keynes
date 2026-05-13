extends RefCounted
class_name DCSusSystemsBootstrap

## Phase D.3：6 个 system 注册逻辑拆分目的地。
## 当前 main.gd 通过 `_generator._setup_sus(...)` 间接注册；future PR 把那段
## 注册代码（含 EnumAtlasUploadSystem / SeaIceAtlasUploadSystem / SeasonRefreshSystem /
## OceanCurrentsSystem / ClimateDailySystem / WeatherDCSystem 6 个 register_system
## 调用）搬到本类。
##
## ─── 待迁移代码段 ────────────────────────────────────────────────
##   - main.gd 中 SUS 注册前的预处理（policy / stride / depends_on 配置）
##   - 后续 use_dc_system_scheduler=true 时走 DCSystemScheduler.register_system 路径
##     （C.4 flag 已就位但 main.gd 未接入；本 phase 接入）
##
## 注册顺序（与 dots-system-design §4 case study 表一致）：
##   1. EnumAtlasUploadSystem — priority 140
##   2. SeaIceAtlasUploadSystem — priority 250
##   3. SeasonRefreshSystem — priority 50
##   4. OceanCurrentsSystem — priority 200
##   5. ClimateDailySystem — priority 100
##   6. WeatherDCSystem — priority ~150（depends_on climate_daily）
##
## DCSystemScheduler 路径会按拓扑序重写 priority；上面的 priority 仅 SUS 兼容路径用。
##
## ─── 拆完后 ────────────────────────────────────────────────────
## 本文件 ~200 行；main.gd 保留"调用 SusSystemsBootstrap.bootstrap(generator, scheduler)"。

func _init(_main_node) -> void:
	push_warning("[DCSusSystemsBootstrap] not yet implemented")
