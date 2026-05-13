extends RefCounted
class_name DCClimateBaker

## Phase B.2 / dots-migration-roadmap §4.2 0.3：climate 烘焙的目的地文件（骨架）。
##
## **当前状态**：拆分骨架，**实际函数仍在 [`map_baker.gd`](../map_baker.gd)**。
## 后续 PR 从下面 TODO 列表逐函数迁移过来。
##
## ─── 待迁移函数清单 ───────────────────────────────────────────────
##
## 一次性烘焙：
##   - `_bake_latitude_buffer` (line 2322) — 纬度查找表
##   - `bake_world` 中 climate atlas 部分（temperature / moisture / snow_cover
##     / sea_ice 上传到 R8/RGBA8 atlas）
##
## 增量重烘焙（每日 climate tick / 季节切换）：
##   - `bake_sea_ice_fraction_only` (line 2021) — 仅海冰分量重烘焙
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
## 1. 接受 DCBakerContext；
## 2. 读 cell.<temperature/moisture/snow_cover/sea_ice_fraction> 必须走
##    ctx.adapter.get_<field>(cell.index)；
## 3. atlas encoding 走 atlas_encoders 子模块（避免重复 encode 逻辑）；
## 4. dirty mask 走 ctx.dirty_rows_climate（partial atlas upload 用）。
##
## ─── 拆完后预期 ────────────────────────────────────────────────────
## 本文件 ~500 行。

func _init(_ctx: DCBakerContext) -> void:
	push_warning("[DCClimateBaker] not yet implemented — call MapBaker directly")
