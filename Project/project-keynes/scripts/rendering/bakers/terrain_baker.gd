extends RefCounted
class_name DCTerrainBaker

## Phase B.2 / dots-migration-roadmap §4.2 0.3：terrain / landform / vegetation /
## cover 烘焙的目的地文件（骨架）。
##
## **当前状态**：拆分骨架，**实际函数仍在 [`map_baker.gd`](../map_baker.gd)**。
## 后续 PR 从下面 TODO 列表逐函数迁移过来；本类目前不被调用，留作 destination 锚点。
##
## ─── 待迁移函数清单（从 map_baker.gd 搬过来时，每个函数独立 PR 验证 bit-equal）─
##
## 一次性烘焙（每次 generate 调一次）：
##   - `_bake_height_biome_moisture` (line 1315) — 高度场 / biome / moisture 主烘焙
##   - `bake_world` 中 terrain/landform/vegetation atlas 部分 (line 243-418 的 ~70%)
##   - `_bake_volcano_field` (line 2281)
##   - `_bake_river_sdf` + 配套 `_trace_*` / `_warp_river_chain` / `_catmull_*`
##     / `_stamp_polyline_binary` / `_chamfer_sdt` (line 1651-1864)
##   - `_hydraulic_erosion` (line 1499)
##
## 增量重烘焙（季节切换 / 单轴更新）：
##   - `rebake_biome_tex_only` (line 419)
##   - `rebake_cover_tex_only` (line 425)
##   - `rebake_vegetation_tex_only` (line 430)
##   - `rebake_biome_axes_only` (line 1108)
##   - `_rebake_single_axis` (line 920)
##   - `_rewrite_axis_buffers` (line 1202)
##
## 共享内部 helper（搬过来时考虑放 baker_context.gd 还是这里）：
##   - `_world_to_cube_f` / `_cube_round` / `_neighbor_dir` / `_barycentric`
##   - `_resolve_hm_size` / `_init_noise`
##
## ─── 拆分原则 ────────────────────────────────────────────────────────
## 1. 子 baker 接受 DCBakerContext，不直接持 MapData / WorldData ref；
## 2. 读 schema-mirrored cell 字段必须走 ctx.adapter（非 cell.<field>）；
## 3. 写仍按既有路径（rebake_biome_tex_only 等已是 stateful 写法，迁过来时
##    保持原签名 + 加 ctx 参数）；
## 4. 每个函数迁移 PR 必须跑 startup 截图对比像素级一致才能合入。
##
## ─── 拆完后的预期 ────────────────────────────────────────────────────
## 本文件 ~600 行；map_baker.gd 残留约 150 行做调度入口。

func _init(_ctx: DCBakerContext) -> void:
	# 占位构造。实际实现等函数迁移过来时填。
	push_warning("[DCTerrainBaker] not yet implemented — call MapBaker directly")
