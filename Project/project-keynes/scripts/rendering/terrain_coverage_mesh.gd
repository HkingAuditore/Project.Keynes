class_name TerrainCoverageMesh
extends RefCounted

## [terrain-split 2026-11-01] 主地形 land / water 保守覆盖网格生成器。
##
## 由 HexRenderer 在 set_map / _rebuild（一次性）调用，产出两张 ArrayMesh：
##   - land_mesh ：覆盖「可能出现陆地像素」的 block 集合（每 block 一个 quad）
##   - water_mesh：覆盖「可能出现水面像素」的 block 集合（每 block 一个 quad）
## 渲染器把陆地 program 挂到 _world_quad（mesh=land_mesh）、水面 program 挂到
## _water_quad（mesh=water_mesh）；shader 仍按逐像素 is_water 互补 discard，所以这
## 两张网格只是**保守超集**：纯区域只光栅化自己那条 program，混合 block 两边都画，
## 最终每个像素仍只被自己的 program 上色一次，视觉与拆分前逐像素一致。
##
## 设计契约见 docs/plans/terrain-split-implementation-plan.md §2.3（逐条对应）：
##   1) 世界矩形 / wrap 与 HexRenderer._build_world_quad_mesh() 完全一致：
##      wrap_period_x > 0.0001 时几何 x 用 [0, P)，并在 -P / 0 / +P 三个 offset 各复制
##      一整份几何进**同一个** ArrayMesh（三角形数 = 3×）；否则只有 1 份。
##   2) 分类源必须与 shader 内 is_water 同源：shader 走 map_index_atlas.GB 的
##      per-pixel cell id → enum_lut.R 的静态 biome（`bake_cell_luts` 里
##      `enum_data[ci*4] = int(cell.terrain)`）；CPU 侧对应
##      `world.pixel_to_cell_lookup[i]`（per-pixel cell）→ `cell.terrain` →
##      `MapData.is_water_render_lut()`。`null`（地图外 padding）在 shader 里走
##      `biome = B_SEA_ICE` 的水面管线，因此归 **water**。
##   3) 保守覆盖：block 内只要出现该类像素（按 texel 矩形相交判定，不按像素中心，
##      因此 block 尺寸小于 texel 时也不会漏）就进该类 mesh；随后两张 mesh 各自按
##      8 邻域外扩 MARGIN_BLOCKS 个 block，吸收 CPU 掩码与 tiled bake / 索引图的
##      边界差异。边界 block 的 quad 裁剪到世界矩形内。
##   4) 每个 block 一个 quad（4 顶点 / 2 三角形，ARRAY_INDEX 索引绘制），顶点是
##      world 坐标（与现有整张 quad 同语义；canvas_item 里 MODEL_MATRIX * VERTEX）；
##      一条 ArrayMesh 一个 surface；不新建材质、不新增 sampler。
##   5) 一次性构建，运行期不重建（陆地/水面分类在运行期不变，海冰翻转两侧都是水）。
##   6) 失败（world / mask 数据缺失、尺寸不符、退化参数等）→ 返回 ok=false + 明确
##      reason，渲染器回退整张 quad + 单 program；本模块绝不抛异常。
##
## 成功返回：
##   {ok: true, reason: "",
##    land_mesh: ArrayMesh, water_mesh: ArrayMesh,
##    stats: {build_ms, blocks_x, blocks_y, block_world, land_blocks, water_blocks,
##            mixed_blocks, land_tris, water_tris, wrap_copies, margin_blocks}}
## stats 语义（与测试/报告对齐）：
##   - blocks_x/blocks_y  ：block 网格维度（含 wrap 时按 x∈[0,P) 计算）
##   - land_blocks/water_blocks：**外扩后**各自 mesh 的 block 数（不含 wrap 副本）
##   - mixed_blocks       ：原始分类中同时含陆地与水面像素的 block 数（外扩前）
##   - land_tris/water_tris：实际写进 ArrayMesh 的三角形数（含 wrap 3 份）
##   - wrap_copies        ：1 或 3
## 失败返回：{ok: false, reason: String, land_mesh: null, water_mesh: null, stats: 上述字典}
##
## 接线（给 HexRenderer）：
##   var r: Dictionary = TerrainCoverageMesh.build(
##           world, world.world_bounds, _wrap_period_x())
##   if bool(r.get("ok", false)):
##       _world_quad.mesh = r.get("land_mesh")
##       _water_quad.mesh = r.get("water_mesh")
##   else:
##       # 回退今天的整张 quad + 单 program
## 只读 world.pixel_to_cell_lookup / derived_size / world_bounds；不改任何 world 字段。

const DEFAULT_BLOCK_WORLD := 16.0
const MARGIN_BLOCKS := 1
## 与 HexRenderer._build_world_quad_mesh() 的 wrap 判定阈值保持一致。
const WRAP_EPSILON := 0.0001
const MIN_BLOCK_WORLD := 0.25
const MIN_WORLD_SIZE := 0.001
const MAX_BLOCKS_PER_AXIS := 8192
const MAX_TOTAL_BLOCKS := 4_000_000

const MapDataScript = preload("res://scripts/geography/map_data.gd")


static func build(world: WorldData, world_bounds: Rect2,
		wrap_period_x: float, block_world: float = DEFAULT_BLOCK_WORLD) -> Dictionary:
	var t0_us: int = Time.get_ticks_usec()
	var stats := _empty_stats(block_world)
	if world == null:
		return _failure("world_null", stats, t0_us)

	var bounds_pos := world_bounds.position
	var bounds_size := world_bounds.size
	if not (is_finite(bounds_pos.x) and is_finite(bounds_pos.y)
			and is_finite(bounds_size.x) and is_finite(bounds_size.y)):
		return _failure("invalid_world_bounds_non_finite", stats, t0_us)
	if bounds_size.x <= MIN_WORLD_SIZE or bounds_size.y <= MIN_WORLD_SIZE:
		return _failure("invalid_world_bounds_size:%s" % str(bounds_size), stats, t0_us)

	if not is_finite(wrap_period_x):
		return _failure("invalid_wrap_period_x_non_finite", stats, t0_us)

	var block: float = float(block_world)
	if not is_finite(block) or block < MIN_BLOCK_WORLD:
		return _failure("invalid_block_world:%s" % str(block_world), stats, t0_us)

	var derived: Vector2i = world.derived_size
	if derived.x <= 0 or derived.y <= 0:
		return _failure("invalid_derived_size:%s" % str(derived), stats, t0_us)
	var dw: int = derived.x
	var dh: int = derived.y
	var pix_count: int = dw * dh

	var lookup: Array = world.pixel_to_cell_lookup
	if lookup.is_empty():
		return _failure("missing_pixel_to_cell_lookup", stats, t0_us)
	if lookup.size() != pix_count:
		return _failure("pixel_to_cell_lookup_size_mismatch:%d!=%d" % [
				lookup.size(), pix_count], stats, t0_us)

	# ── 世界矩形 / wrap：与 HexRenderer._build_world_quad_mesh() 同一套规则 ──
	var wrap: bool = wrap_period_x > WRAP_EPSILON
	var gx: float = 0.0 if wrap else bounds_pos.x
	var gsx: float = wrap_period_x if wrap else bounds_size.x
	var gy: float = bounds_pos.y
	var gsy: float = bounds_size.y
	if not (is_finite(gx) and is_finite(gsx) and is_finite(gy) and is_finite(gsy)) \
			or gsx <= MIN_WORLD_SIZE or gsy <= MIN_WORLD_SIZE:
		return _failure("invalid_geometry_rect", stats, t0_us)

	var bx_count: int = _block_count(gsx, block)
	var by_count: int = _block_count(gsy, block)
	if bx_count <= 0 or by_count <= 0:
		return _failure("degenerate_block_grid:%dx%d" % [bx_count, by_count], stats, t0_us)
	if bx_count > MAX_BLOCKS_PER_AXIS or by_count > MAX_BLOCKS_PER_AXIS:
		return _failure("too_many_blocks:%dx%d" % [bx_count, by_count], stats, t0_us)
	var total_blocks: int = bx_count * by_count
	if total_blocks > MAX_TOTAL_BLOCKS:
		return _failure("too_many_blocks_total:%d" % total_blocks, stats, t0_us)

	var wrap_offsets := _wrap_offsets(wrap, wrap_period_x)
	var wrap_copies: int = wrap_offsets.size()
	stats["blocks_x"] = bx_count
	stats["blocks_y"] = by_count
	stats["block_world"] = block
	stats["wrap_copies"] = wrap_copies

	# ── 1) 逐像素水掩码（1 = water）。分类源 = pixel_to_cell_lookup → cell.terrain。 ──
	var pixel_water := _build_pixel_water_mask(lookup, pix_count)
	if pixel_water.is_empty():
		return _failure("pixel_water_mask_build_failed", stats, t0_us)

	# ── 2) block 像素窗口（texel 矩形相交判定，保守） ──
	var texel_w: float = bounds_size.x / float(dw)
	var texel_h: float = bounds_size.y / float(dh)
	if texel_w <= 0.0 or texel_h <= 0.0:
		return _failure("degenerate_texel_size", stats, t0_us)
	var tex_off_x: float = bounds_pos.x - gx
	var tex_off_y: float = bounds_pos.y - gy
	var col0 := PackedInt32Array(); col0.resize(bx_count)
	var col1 := PackedInt32Array(); col1.resize(bx_count)
	for bx in range(bx_count):
		var span := _texel_span(float(bx) * block, minf(float(bx + 1) * block, gsx),
				tex_off_x, texel_w, dw)
		col0[bx] = span.x
		col1[bx] = span.y
	var row0 := PackedInt32Array(); row0.resize(by_count)
	var row1 := PackedInt32Array(); row1.resize(by_count)
	for by in range(by_count):
		var span := _texel_span(float(by) * block, minf(float(by + 1) * block, gsy),
				tex_off_y, texel_h, dh)
		row0[by] = span.x
		row1[by] = span.y

	# ── 3) 原始 block 分类：bit0 = 含陆地像素，bit1 = 含水像素 ──
	# 无像素窗口的 block（理论上只会在退化参数下出现）按 padding 规则归 water。
	var raw := PackedByteArray(); raw.resize(total_blocks)
	var mixed_blocks: int = 0
	for by in range(by_count):
		var row_base: int = by * bx_count
		var py0: int = row0[by]
		var py1: int = row1[by]
		if py0 > py1:
			for bx in range(bx_count):
				raw[row_base + bx] = 2
			continue
		for bx in range(bx_count):
			var px0: int = col0[bx]
			var px1: int = col1[bx]
			var has_land: bool = false
			var has_water: bool = false
			if px0 > px1:
				has_water = true
			else:
				for py in range(py0, py1 + 1):
					var mask_row: int = py * dw
					for px in range(px0, px1 + 1):
						if pixel_water[mask_row + px] != 0:
							has_water = true
						else:
							has_land = true
					if has_land and has_water:
						break
			var cls: int = 0
			if has_land:
				cls |= 1
			if has_water:
				cls |= 2
			if cls == 3:
				mixed_blocks += 1
			raw[row_base + bx] = cls
	stats["mixed_blocks"] = mixed_blocks

	# ── 4) 8 邻域外扩 MARGIN_BLOCKS（两张 mesh 各自独立） ──
	var land_flags := PackedByteArray(); land_flags.resize(total_blocks)
	var water_flags := PackedByteArray(); water_flags.resize(total_blocks)
	_expand_flags(raw, bx_count, by_count, land_flags, water_flags)

	# ── 5) 几何：每个入选 block 一个裁剪后的 quad；wrap 时整个几何复制 3 份 ──
	var land_result := _emit_mesh(land_flags, bx_count, by_count,
			gx, gy, gsx, gsy, block, wrap_offsets)
	if not bool(land_result.get("ok", false)):
		return _failure(String(land_result.get("reason", "land_mesh_build_failed")), stats, t0_us)
	var water_result := _emit_mesh(water_flags, bx_count, by_count,
			gx, gy, gsx, gsy, block, wrap_offsets)
	if not bool(water_result.get("ok", false)):
		return _failure(String(water_result.get("reason", "water_mesh_build_failed")), stats, t0_us)

	var land_blocks: int = int(land_result.get("blocks", 0))
	var water_blocks: int = int(water_result.get("blocks", 0))
	stats["land_blocks"] = land_blocks
	stats["water_blocks"] = water_blocks
	stats["land_tris"] = land_blocks * 2 * wrap_copies
	stats["water_tris"] = water_blocks * 2 * wrap_copies
	stats["build_ms"] = _elapsed_ms(t0_us)
	return {
		"ok": true,
		"reason": "",
		"land_mesh": land_result.get("mesh", null),
		"water_mesh": water_result.get("mesh", null),
		"stats": stats,
	}


# ─── 逐像素水掩码 ────────────────────────────────────────────────────────
# 与 shader is_water 同源：cell.terrain 即 enum_lut.R 的静态 biome；
# null cell = 地图外 padding → shader 里 biome=B_SEA_ICE → water。
# 容错：非 HexCell 的 duck-typed cell 走 Object.get("terrain")，取不到也归 water。
static func _build_pixel_water_mask(lookup: Array, pix_count: int) -> PackedByteArray:
	var lut: PackedByteArray = MapDataScript.is_water_render_lut()
	if lut.size() < 256:
		return PackedByteArray()
	var mask := PackedByteArray()
	mask.resize(pix_count)
	var prev_cell: Variant = null
	var prev_water: int = 1
	for i in range(pix_count):
		var cell: Variant = lookup[i]
		if cell != prev_cell:
			prev_cell = cell
			if cell == null:
				prev_water = 1
			elif cell is HexCell:
				prev_water = 1 if lut[int((cell as HexCell).terrain) & 0xFF] != 0 else 0
			elif cell is Object:
				var t: Variant = (cell as Object).get("terrain")
				prev_water = 1 if t == null or lut[int(t) & 0xFF] != 0 else 0
			else:
				prev_water = 1
		mask[i] = prev_water
	return mask


# ─── texel 矩形 → block 索引窗口（保守：取矩形相交，不只像素中心） ─────────
# block 区间 [lo, hi)（已裁剪到几何矩形）、纹理原点相对几何原点的偏移 off、
# 每 texel 世界尺寸 texel、该轴纹理像素数 n。
# 返回 Vector2i(起始像素 index, 结束像素 index)，闭区间；block 被裁剪成零宽时返回 (1, 0)。
# 窗口落在纹理左侧/右侧外面时分别钳到首/末 texel —— 与 shader 的 uv clamp(0,1) 行为一致
# （wrap + 正 world_origin 等极端布局也不会把 block 误判成 padding/water）。
static func _texel_span(lo: float, hi: float, off: float, texel: float, n: int) -> Vector2i:
	if hi <= lo:
		return Vector2i(1, 0)
	var a: float = (lo - off) / texel
	var b: float = (hi - off) / texel
	var i0: int = int(floor(a))
	var i1: int = int(ceil(b)) - 1
	if i1 < 0:
		return Vector2i(0, 0)
	if i0 > n - 1:
		return Vector2i(n - 1, n - 1)
	return Vector2i(clampi(i0, 0, n - 1), clampi(i1, 0, n - 1))


# ─── 8 邻域外扩 ──────────────────────────────────────────────────────────
# raw bit0=land bit1=water。外扩语义：block 自身或任一 8 邻域含该类像素 → 该类 mesh 覆盖它。
static func _expand_flags(raw: PackedByteArray, bx_count: int, by_count: int,
		land_flags: PackedByteArray, water_flags: PackedByteArray) -> void:
	for by in range(by_count):
		var ny0: int = maxi(by - 1, 0)
		var ny1: int = mini(by + 1, by_count - 1)
		var row_base: int = by * bx_count
		for bx in range(bx_count):
			var nx0: int = maxi(bx - 1, 0)
			var nx1: int = mini(bx + 1, bx_count - 1)
			var near: int = 0
			for ny in range(ny0, ny1 + 1):
				var nrow: int = ny * bx_count
				for nx in range(nx0, nx1 + 1):
					near |= raw[nrow + nx]
				if near == 3:
					break
			var idx: int = row_base + bx
			land_flags[idx] = 1 if (near & 1) != 0 else 0
			water_flags[idx] = 1 if (near & 2) != 0 else 0


# ─── 几何生成 ────────────────────────────────────────────────────────────
# 返回 {ok: bool, reason: String, mesh: ArrayMesh, blocks: int}。
# blocks = 入选 block 数（不含 wrap 副本）；mesh 里三角形数 = blocks * 2 * wrap_copies。
static func _emit_mesh(flags: PackedByteArray, bx_count: int, by_count: int,
		gx: float, gy: float, gsx: float, gsy: float, block: float,
		wrap_offsets: PackedFloat32Array) -> Dictionary:
	var base_blocks: int = 0
	for i in range(flags.size()):
		if flags[i] != 0:
			base_blocks += 1
	var mesh := ArrayMesh.new()
	if base_blocks == 0:
		# 空 mesh 合法：MeshInstance2D 挂无 surface 的 ArrayMesh = 什么都不画。
		return {"ok": true, "reason": "", "mesh": mesh, "blocks": 0}

	var copies: int = wrap_offsets.size()
	var total_quads: int = base_blocks * copies
	var verts := PackedVector2Array(); verts.resize(total_quads * 4)
	var indices := PackedInt32Array(); indices.resize(total_quads * 6)
	var right: float = gx + gsx
	var bottom: float = gy + gsy
	var quads: int = 0
	for copy in range(copies):
		var ox: float = float(wrap_offsets[copy])
		for by in range(by_count):
			var y0: float = gy + float(by) * block
			var y1: float = minf(y0 + block, bottom)
			if y1 <= y0:
				continue
			var row_base: int = by * bx_count
			for bx in range(bx_count):
				if flags[row_base + bx] == 0:
					continue
				var x0: float = gx + float(bx) * block
				var x1: float = minf(x0 + block, right)
				if x1 <= x0:
					continue
				var wx0: float = x0 + ox
				var wx1: float = x1 + ox
				if not (is_finite(wx0) and is_finite(wx1) and is_finite(y0) and is_finite(y1)):
					return {"ok": false, "reason": "non_finite_vertex", "mesh": null, "blocks": 0}
				var vi: int = quads * 4
				var ii: int = quads * 6
				verts[vi] = Vector2(wx0, y0)
				verts[vi + 1] = Vector2(wx1, y0)
				verts[vi + 2] = Vector2(wx1, y1)
				verts[vi + 3] = Vector2(wx0, y1)
				# 与 HexRenderer._build_world_quad_mesh() 相同的三角形/绕序。
				indices[ii] = vi
				indices[ii + 1] = vi + 1
				indices[ii + 2] = vi + 2
				indices[ii + 3] = vi
				indices[ii + 4] = vi + 2
				indices[ii + 5] = vi + 3
				quads += 1
	if quads == 0:
		return {"ok": true, "reason": "", "mesh": mesh, "blocks": base_blocks}
	if quads < total_quads:
		verts.resize(quads * 4)
		indices.resize(quads * 6)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"ok": true, "reason": "", "mesh": mesh, "blocks": base_blocks}


# ─── 小工具 ──────────────────────────────────────────────────────────────
static func _wrap_offsets(wrap: bool, wrap_period_x: float) -> PackedFloat32Array:
	# 与 HexRenderer._build_world_quad_mesh() 逐位一致：同一个 PackedFloat32Array 构造。
	if not wrap:
		return PackedFloat32Array([0.0])
	return PackedFloat32Array([-wrap_period_x, 0.0, wrap_period_x])


static func _block_count(extent: float, block: float) -> int:
	var n: int = int(extent / block)
	if float(n) * block < extent - 0.0001:
		n += 1
	return n


static func _empty_stats(block_world: float) -> Dictionary:
	return {
		"build_ms": 0.0,
		"blocks_x": 0,
		"blocks_y": 0,
		"block_world": float(block_world),
		"land_blocks": 0,
		"water_blocks": 0,
		"mixed_blocks": 0,
		"land_tris": 0,
		"water_tris": 0,
		"wrap_copies": 1,
		"margin_blocks": MARGIN_BLOCKS,
	}


static func _elapsed_ms(t0_us: int) -> float:
	return float(Time.get_ticks_usec() - t0_us) / 1000.0


static func _failure(reason: String, stats: Dictionary, t0_us: int) -> Dictionary:
	stats["build_ms"] = _elapsed_ms(t0_us)
	return {
		"ok": false,
		"reason": reason,
		"land_mesh": null,
		"water_mesh": null,
		"stats": stats,
	}
