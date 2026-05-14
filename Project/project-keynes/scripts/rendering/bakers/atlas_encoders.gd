extends RefCounted
class_name DCAtlasEncoders

## Phase B.2 / dots-migration-roadmap §4.2 0.3：纯像素 encode helper 集中地。
##
## **当前状态**：骨架；map_baker.gd 内的 6 个 `_encode_*_tex` / `_encode_*_atlas`
## 静态 helper（line 1866-2020）逻辑独立、无内部状态依赖、是天然的"先迁移
## 候选"。可以是本 Phase 实际实施的第一批迁移（每个 helper 独立 PR）。
##
## ─── 待迁移函数清单 ───────────────────────────────────────────────
##
## 全部为 static func，从 map_baker.gd 完整搬过来即可（零行为变更）：
##   - `_encode_height_tex(buf: PackedFloat32Array, size: Vector2i) -> ImageTexture` (line 1866)
##   - `_encode_enum_atlas(biome_buf, veg_buf, river_sdf_buf, size, existing) -> ImageTexture` (line 1888)
##   - `_encode_scalar_atlas(moist_buf, flow_buf, latitude_buf, size, existing) -> ImageTexture` (line 1918)
##   - `_encode_vector_atlas(ocean_buf, wind_buf, upwelling_buf, size, existing) -> ImageTexture` (line 1940)
##   - `_encode_upwelling_tex(upwelling_buf, size, existing) -> ImageTexture` (line 1967)
##   - `_encode_r8_tex(buf: PackedByteArray, size, existing) -> ImageTexture` (line 1991)
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
## 1. 全部为 static —— 无 ctx 依赖，迁移最简单；
## 2. map_baker.gd 内调用点改为 `DCAtlasEncoders._encode_xxx(...)` 一行替换；
## 3. 迁移 PR 只搬 helper 不动 caller，bit-equal 验收 = 像素级对比 atlas
##    内容应完全一致。
##
## ─── 推荐迁移顺序（每个独立 PR，30 分钟内完成）───────────────────
## 1. _encode_height_tex — 最简单（单字段 → R8 编码）
## 2. _encode_r8_tex     — 通用 R8 encoder（被多个调用方复用，迁移收益大） [PR-3.1.1 完成]
## 3. _encode_enum_atlas — 3 输入 → RGBA8（biome/veg/river）
## 4. _encode_scalar_atlas — 3 输入 → RGBA8（moist/flow/lat）
## 5. _encode_vector_atlas — 3 输入 → RGBA8（ocean/wind/upwelling）
## 6. _encode_upwelling_tex — 单输入 → RGBA8


# ═══════════════════════════════════════════════════════════════════════
# 通用 R8 → ImageTexture 编码（L8 LINEAR）
# ═══════════════════════════════════════════════════════════════════════
#
# PR-3.1.1（master 手册 §6.2）：从 map_baker.gd:_encode_r8_tex 整体搬迁。
# caller 改一行：DCAtlasEncoders.encode_r8_tex(...)。
#
# 传入 existing（非 null + 同尺寸）会尝试原地 update 以复用 GPU 句柄，
# 避免 refresh_climate_daily 每日创建新纹理带来的驱动层分配开销。
static func encode_r8_tex(buf: PackedByteArray, size: Vector2i, existing: ImageTexture) -> ImageTexture:
	var W: int = size.x
	var H: int = size.y
	var n: int = W * H
	var data: PackedByteArray = PackedByteArray()
	data.resize(n)
	var has_buf: bool = buf.size() >= n
	for i in range(n):
		data[i] = buf[i] if has_buf else 0
	var img: Image = Image.create_from_data(W, H, false, Image.FORMAT_L8, data)
	if existing != null and existing.get_size() == Vector2(float(W), float(H)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)
