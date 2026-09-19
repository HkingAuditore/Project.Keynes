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
##   - `bake_latitude_buffer` — native 纬度场结果校验与空结果策略
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

static func bake_latitude_buffer(_bounds: Rect2, size: Vector2i, world_ext: Object) -> PackedFloat32Array:
	var W: int = size.x
	var H: int = size.y
	var empty := PackedFloat32Array()
	empty.resize(maxi(W * H, 0))
	if W <= 0 or H <= 0:
		return empty
	if world_ext == null or not world_ext.has_method("run_bake_latitude_field_pass"):
		push_error("[bake_latitude_buffer] native latitude pass unavailable")
		return empty
	var rep: Dictionary = world_ext.run_bake_latitude_field_pass({"width": W, "height": H})
	var ok: bool = rep != null and typeof(rep) == TYPE_DICTIONARY and not bool(rep.get("fallback", true))
	var latitude: PackedFloat32Array = rep.get("latitude_buffer", PackedFloat32Array()) if ok else PackedFloat32Array()
	if not ok or latitude.size() != W * H:
		push_error("[bake_latitude_buffer] native result invalid (reason=%s)" % (
			String(rep.get("reason", "unknown")) if rep != null and typeof(rep) == TYPE_DICTIONARY else "null"))
		return empty
	return latitude
