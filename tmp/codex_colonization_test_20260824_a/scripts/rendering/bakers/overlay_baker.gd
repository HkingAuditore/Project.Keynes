extends RefCounted
class_name DCOverlayBaker

## Phase B.2 / dots-migration-roadmap §4.2 0.3：overlay / debug 通道烘焙的目的
## 地文件（骨架）。
##
## **当前状态**：拆分骨架。本类是 [`data_overlay_baker.gd`](../data_overlay_baker.gd)
## 的 OOP wrapper（data_overlay_baker.gd 已是独立文件且在 B.1 完成 ViewAdapter
## 接入），不需要从 map_baker.gd 迁移函数；实际拆分时只需把
## `MapBaker` 内对 `_atlas_dirty_rows_overlay` 等 overlay-specific 字段移出来
## 到本类持有，并把 `data_overlay_baker.gd` 的 static `bake` 改成接受
## DCBakerContext 的实例方法（仍保留 static 调用兼容）。
##
## ─── 待迁移函数清单 ───────────────────────────────────────────────
##
## - 现有 [`data_overlay_baker.gd::bake`](../data_overlay_baker.gd) 的 static
##   bake() 改造：保留 static 入口（向后兼容），内部 delegate 到本类的实例方法
##   `bake(ctx, mode, climate, season_phase)`。
## - `bake_ocean_currents` 系列（line 476-720）按 overlay 视角看其实是
##   "洋流方向 / 速度的 atlas 上传"，可考虑划入 overlay_baker 而非
##   ocean_baker（避免再多一个子文件）。
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
## 1. 接受 DCBakerContext；
## 2. 读侧已 B.1 完成（data_overlay_baker.gd 已走 adapter）；
## 3. dirty mask 走 ctx.dirty_rows_overlay。
##
## ─── 拆完后预期 ────────────────────────────────────────────────────
## 本文件 ~500 行（含从 map_baker.gd 迁出的 ocean current atlas + data_overlay
## 的 OOP 化部分）。

func _init(_ctx: DCBakerContext) -> void:
	push_warning("[DCOverlayBaker] not yet implemented — DataOverlayBaker.bake remains the entry")
