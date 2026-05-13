extends RefCounted
class_name DCWeatherBaker

## Phase B.2 / dots-migration-roadmap §4.2 0.3：weather field / fronts 烘焙的
## 目的地文件（骨架）。
##
## **当前状态**：拆分骨架，**实际函数仍在 [`map_baker.gd`](../map_baker.gd)**。
##
## ─── 待迁移函数清单 ───────────────────────────────────────────────
##
## 主烘焙：
##   - `bake_weather_field_only` (line 2158) — vapor / cloud / precip / instability
##     / weather_intensity / weather_type 6 通道 atlas 重烘焙
##   - `_bake_wind_field` (line 2338) — 风带基线烘焙
##   - `_rasterize_wind_slice_from_hex` (line 2828)
##   - `_rasterize_wind_field_from_hex` (line 2857)
##   - `_ensure_pending_wind_size` (line 2816)
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
## 1. 接受 DCBakerContext；
## 2. 读 cell.<weather_intensity / weather_cloud / weather_precip / weather_vapor
##    / weather_convergence / weather_instability / weather_type> 走 ctx.adapter；
## 3. weather field init 标志（cell.weather_field_initialized）走
##    ctx.adapter.get_weather_field_init(idx)；
## 4. 16 fronts 当前是 GDScript 对象池（weather_system._active_fronts），暂不
##    走 adapter——它们是 entity，不是 cell；阶段 II Front pool DOTS 化后再调整。
##
## ─── 拆完后预期 ────────────────────────────────────────────────────
## 本文件 ~600 行。

func _init(_ctx: DCBakerContext) -> void:
	push_warning("[DCWeatherBaker] not yet implemented — call MapBaker directly")
