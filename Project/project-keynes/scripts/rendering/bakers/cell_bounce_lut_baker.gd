extends RefCounted

## Sizes per-cell lookup textures and publishes their terrain bounce values.


static func _ensure_cell_lut_dims(baker: MapBaker, map: MapData, world: WorldData) -> void:
	if world == null:
		return
	var n_cells: int = map.cell_count() if map != null else 0
	if n_cells <= 0:
		n_cells = 1
	var lut_w: int = mini(n_cells, 2048)
	if lut_w < 1:
		lut_w = 1
	var lut_h: int = int(ceil(float(n_cells) / float(lut_w)))
	if lut_h < 1:
		lut_h = 1
	world.lut_dims = Vector2i(lut_w, lut_h)


# per-cell LUT 全量烘焙 dispatcher：C++（DCWorldExt.encode_cell_luts）优先，
# 失败回退 GDScript（skill rule 11，保留至 A/B parity 验证通过）。
# 字节量化与 fan-out 路径同源（enum=terrain/vegetation/cover、
# dyn=_dynamic_cell_signature/pk_atlas_sig_dynamic、
# eco=_ecology_visual_signature/pk_atlas_sig_ecology），保证间接寻址与旧 atlas
# bit-equivalent。cache_valid=true 时 C++ 端按 prev 推进 eco transition_age；
# 初次 bake 传 false（transition 归零）。daily 刷新走 refresh_cell_luts_daily。
# ── [terrain-gi 2026-07-31] per-cell 弹射代表色 ────────────────────────────
# 按 TerrainType.TERRAIN 枚举下标排列的地表代表反照率。新增地形必须在尾部追加，
# 否则该地形会落到 _BOUNCE_FALLBACK。
#
# 这是**近似量**，刻意不与 land_pipeline 的 fragment albedo 做 bit-equal 镜像：
# 弹射项在 shader 侧乘了 (1 - V_sky) 与 ≤0.3 的 gi_bounce_strength，能量占比极低，
# 色相偏差不可见；而维护一份精确镜像意味着 biome_color / 物候 / 环境调色的每次改动
# 都要同步改这里，代价远大于收益。参见 docs/cpp-dots-runtime/terrain-gi-bake.md。

# Native byte encoding and script reference share the same palette and upload
# boundary. A short input leaves the existing cache/texture untouched in both.
static func _publish_bounce_lut(baker: MapBaker, enum_data: PackedByteArray, dyn_data: PackedByteArray,
		world: WorldData, lw: int, lh: int,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full: bool = true) -> bool:
	if baker._world_ext != null:
		var out: Dictionary = baker._world_ext.encode_cell_luts({
			"bounce_only": true,
			"lut_w": lw, "lut_h": lh,
			"enum_lut": enum_data, "dyn_lut": dyn_data,
			"bounce_lut": baker._cell_bounce_lut_bytes_cache,
			"dirty_indices": dirty_indices,
			"force_full_encode": force_full or world.bounce_lut_tex == null,
			"bounce_palette": baker._BOUNCE_ALBEDO,
			"bounce_fallback": baker._BOUNCE_FALLBACK,
			"bounce_dry": baker._BOUNCE_DRY,
			"bounce_snow": baker._BOUNCE_SNOW,
			"bounce_water_terrains": baker._BOUNCE_WATER_TERRAINS,
		})
		if not bool(out.get("fallback", true)):
			if not bool(out.get("bounce_lut_changed", false)):
				return false
			baker._cell_bounce_lut_bytes_cache = out["bounce_lut"]
			world.bounce_lut_tex = baker._lut_tex_from_data(
				baker._cell_bounce_lut_bytes_cache, lw, lh, Image.FORMAT_RGBA8, world.bounce_lut_tex)
			return true
		if not str(out.get("reason", "")).is_empty():
			push_warning("[cell-lut] native bounce fallback: %s" % str(out["reason"]))
	return _publish_bounce_lut_gd(baker, enum_data, dyn_data, world, lw, lh, dirty_indices, force_full)


static func _publish_bounce_lut_gd(baker: MapBaker, enum_data: PackedByteArray, dyn_data: PackedByteArray,
		world: WorldData, lw: int, lh: int,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full: bool = true) -> bool:
	var slots: int = lw * lh
	if enum_data.size() < slots * 4 or dyn_data.size() < slots * 4:
		return false
	var full_rebuild: bool = force_full or world.bounce_lut_tex == null \
			or baker._cell_bounce_lut_bytes_cache.size() != slots * 4
	if full_rebuild:
		baker._cell_bounce_lut_bytes_cache = PackedByteArray()
		baker._cell_bounce_lut_bytes_cache.resize(slots * 4)
	var work_indices: PackedInt32Array = dirty_indices
	if full_rebuild:
		work_indices = PackedInt32Array()
		work_indices.resize(slots)
		for i in range(slots):
			work_indices[i] = i
	elif work_indices.is_empty():
		return false
	var terrain_count: int = baker._BOUNCE_ALBEDO.size()
	var changed: bool = full_rebuild or world.bounce_lut_tex == null
	for raw_idx in work_indices:
		var i := int(raw_idx)
		if i < 0 or i >= slots:
			continue
		var base: int = i * 4
		var terrain: int = enum_data[base]
		var col: Color = baker._BOUNCE_ALBEDO[terrain] if terrain < terrain_count else baker._BOUNCE_FALLBACK
		var is_water: bool = terrain in baker._BOUNCE_WATER_TERRAINS
		if not is_water:
			# dyn_lut：B=snow_cover，A=陆地 vegetation_vitality。枯萎向干黄褪色，
			# 积雪向雪白覆盖——两者都是每日刷新的，弹射色因此自动跟随季节与天气。
			var vitality: float = float(dyn_data[base + 3]) / 255.0
			col = col.lerp(baker._BOUNCE_DRY, (1.0 - vitality) * 0.25)
			var snow: float = float(dyn_data[base + 2]) / 255.0
			col = col.lerp(baker._BOUNCE_SNOW, snow)
		var r := int(clampf(col.r, 0.0, 1.0) * 255.0)
		var g := int(clampf(col.g, 0.0, 1.0) * 255.0)
		var b := int(clampf(col.b, 0.0, 1.0) * 255.0)
		var a := 0 if is_water else 255
		if baker._cell_bounce_lut_bytes_cache[base] != r \
				or baker._cell_bounce_lut_bytes_cache[base + 1] != g \
				or baker._cell_bounce_lut_bytes_cache[base + 2] != b \
				or baker._cell_bounce_lut_bytes_cache[base + 3] != a:
			changed = true
			baker._cell_bounce_lut_bytes_cache[base] = r
			baker._cell_bounce_lut_bytes_cache[base + 1] = g
			baker._cell_bounce_lut_bytes_cache[base + 2] = b
			baker._cell_bounce_lut_bytes_cache[base + 3] = a
	if not changed:
		return false
	world.bounce_lut_tex = baker._lut_tex_from_data(
		baker._cell_bounce_lut_bytes_cache, lw, lh, Image.FORMAT_RGBA8, world.bounce_lut_tex)
	return true
