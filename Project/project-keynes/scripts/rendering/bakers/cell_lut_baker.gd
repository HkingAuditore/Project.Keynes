extends RefCounted
class_name DCCellLutBaker

# [cell-field 2026-11-18] cell_table（Texture2DArray）的字节布局与 offset 空间重排由
# cell_table_codec.gd 负责；本文件只做「取源数据 → 调 codec → 建/复用纹理 → update_layer」。
# 用 preload 而不是裸 class_name：`DCCellTableCodec` 的 class_name 要编辑器扫描写进
# .godot/global_script_class_cache.cfg 后才全局可见，headless / 首次运行时尚不存在
# （tests/world/cell_table_layout_test.gd 同做法）。
const CellTableCodecScript = preload("res://scripts/rendering/bakers/cell_table_codec.gd")
# [cell-field-overlays 2026-11-18] 风场字节的上游编码器。weather_table 的 layer2/3 必须与
# cloud_shadow_field 的 `wind_lut` **逐字节相同**，所以这里不另写一份编码，直接复用
# weather_wind_source.gd::build_bytes()（内部就是 build_image() + Image.get_data()）。
const WeatherWindSourceScript = preload("res://scripts/rendering/weather_wind_source.gd")

## 湖泊水深归一尺度（height 单位）：与 gdext/src/world_ext_bake.cpp:1088 的
## `LAKE_DEPTH_NORM` 同值。layer2.G 的水深 8bit 与 terrain_surface_tex.layer5.B 同公式。
const PK_LAKE_DEPTH_NORM := 0.16

# ─── [cell-field-overlays 2026-11-18] weather_table 层号（方案 §3.3）──────────────────
# Texture2DArray，RGBA8，map_w × map_h，1 texel = 1 格，**offset 空间**，无 mip。
# ```
#   layer 0 / 1  天气 A / B : R=type  G=intensity  B=cloud  A=vapor   （同 weather_lut 布局）
#   layer 2 / 3  风     A / B : RG=单位风向*0.5+0.5  B=speed/20  A=1   （同 wind_lut 编码）
# ```
# **双缓冲靠层号**：当前层号 cur ∈ {0,1}（WorldData.weather_table_cur），
# prev = 1 - cur；风同理 2 + cur / 2 + prev。每次提交只 update_layer 一层（天气）+ 一层
# （风），再翻转 cur，**不拷贝、不重传另一层**。层号常量与 shader 侧 O2 的
# `PK_WEATHER_LAYER_A/B`、`PK_WEATHER_WIND_LAYER_BASE(=2)` 必须同值。
const WEATHER_TABLE_LAYER_WEATHER_A := 0
const WEATHER_TABLE_LAYER_WEATHER_B := 1
const WEATHER_TABLE_LAYER_WIND_A := 2
const WEATHER_TABLE_LAYER_WIND_B := 3
const WEATHER_TABLE_LAYERS := 4
## 风的层号基址：wind_cur = WEATHER_TABLE_LAYER_WIND_BASE + cur。
const WEATHER_TABLE_LAYER_WIND_BASE := 2
## o2i == -1（南北 padding）的 texel：type 写 WT_CLEAR，其余通道 0。
## 真值 `WeatherType.WT.CLEAR`（weather_type.gd:24）= 0；
## tests/world/weather_table_layout_test.gd 里有等值断言，防止枚举被改后这条静默失效。
const WEATHER_TABLE_PAD_TYPE := 0





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



static func set_river_atlas_probe_enabled(baker: MapBaker, enabled: bool, map: MapData = null) -> Dictionary:
	baker._river_atlas_probe_enabled = enabled
	if enabled:
		baker._river_atlas_probe_rows.clear()
		# Cell selection is deferred to the next LUT bake so the GM click remains cheap.
		baker._river_atlas_probe_cells.clear()
	else:
		baker._river_atlas_probe_context.clear()
	return baker.get_river_atlas_probe_state()



static func get_river_atlas_probe_state(baker: MapBaker) -> Dictionary:
	return {
		"enabled": baker._river_atlas_probe_enabled,
		"sample_count": baker._river_atlas_probe_rows.size(),
		"cell_count": baker._river_atlas_probe_cells.size(),
	}



static func set_river_atlas_probe_context(baker: MapBaker, context: Dictionary) -> void:
	if baker._river_atlas_probe_enabled:
		baker._river_atlas_probe_context = context.duplicate(false)



static func dump_river_atlas_probe(baker: MapBaker) -> Dictionary:
	if baker._river_atlas_probe_rows.is_empty():
		return {"ok": false, "code": "probe_empty", "message": "Atlas 河谷采样暂无记录。"}
	var dir_path := "user://diagnostics"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "")
	var path := "%s/atlas_river_probe_%s.csv" % [dir_path, stamp]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "code": "probe_open_failed", "message": "无法写入 Atlas 河谷采样文件。"}
	var columns := PackedStringArray([
		"sample_seq", "tick_idx", "sim_day", "cell_index", "q", "r", "has_river",
		"river_flow", "river_discharge", "map_moisture", "cell_moisture",
		"map_vitality", "cell_vitality", "map_drought_stress", "map_heat_stress",
		"dyn_temp_byte", "dyn_moisture_byte", "dyn_snow_byte", "dyn_vitality_byte",
		"eco_foliage_byte", "eco_stress_byte", "eco_transition_byte", "eco_growth_byte",
		"lut_path", "lut_encode_path", "lut_catchup", "lut_dirty_cells",
	])
	file.store_line(",".join(columns))
	for row in baker._river_atlas_probe_rows:
		var values := PackedStringArray()
		for column in columns:
			values.append(baker._csv_escape(str(row.get(column, ""))))
		file.store_line(",".join(values))
	file.close()
	return {"ok": true, "path": path, "rows": baker._river_atlas_probe_rows.size()}



static func _csv_escape(baker: MapBaker, value: String) -> String:
	return '"%s"' % value.replace('"', '""')



static func _ensure_river_atlas_probe_cells(baker: MapBaker, map: MapData) -> void:
	if not baker._river_atlas_probe_cells.is_empty() or map == null:
		return
	var river_cells := PackedInt32Array()
	var control_cells := PackedInt32Array()
	var scan_count := mini(map.cell_count(), baker.RIVER_ATLAS_PROBE_SCAN_LIMIT)
	for idx in range(scan_count):
		var cell = map.cell_at(idx)
		if cell == null:
			continue
		if bool(cell.has_river) and river_cells.size() < baker.RIVER_ATLAS_PROBE_CELL_LIMIT:
			river_cells.append(idx)
		elif not bool(cell.has_river) and control_cells.size() < baker.RIVER_ATLAS_PROBE_CELL_LIMIT:
			control_cells.append(idx)
	baker._river_atlas_probe_cells.append_array(river_cells)
	baker._river_atlas_probe_cells.append_array(control_cells)



static func _record_river_atlas_probe(baker: MapBaker, map: MapData, out: Dictionary, dyn_data: PackedByteArray,
		eco_data: PackedByteArray) -> void:
	if not baker._river_atlas_probe_enabled or map == null:
		return
	baker._ensure_river_atlas_probe_cells(map)
	var lut_path := str(out.get("path", ""))
	var encode_path := str(out.get("lut_encode_path", ""))
	var dirty_cells := int(out.get("dirty_cells", out.get("dynamic_dirty_cells",
		baker._river_atlas_probe_context.get("dirty_count", -1))))
	for idx in baker._river_atlas_probe_cells:
		if baker._river_atlas_probe_rows.size() >= baker.RIVER_ATLAS_PROBE_SAMPLE_LIMIT:
			break
		var cell = map.cell_at(idx)
		if cell == null or idx < 0:
			continue
		var d4 := idx * 4
		if d4 + 3 >= dyn_data.size() or d4 + 3 >= eco_data.size():
			continue
		var row := {
			"sample_seq": baker._river_atlas_probe_rows.size(),
			"tick_idx": baker._river_atlas_probe_context.get("tick_idx", -1),
			"sim_day": baker._river_atlas_probe_context.get("sim_day", -1),
			"cell_index": idx, "q": int(cell.q), "r": int(cell.r),
			"has_river": 1 if bool(cell.has_river) else 0,
			"river_flow": float(cell.river_flow),
			"river_discharge": baker._probe_float(map.river_discharge_arr, idx),
			"map_moisture": baker._probe_float(map.moisture_arr, idx),
			"cell_moisture": float(cell.moisture),
			"map_vitality": baker._probe_float(map.vegetation_vitality_arr, idx),
			"cell_vitality": float(cell.vegetation_vitality),
			"map_drought_stress": baker._probe_float(map.vegetation_drought_stress_arr, idx),
			"map_heat_stress": baker._probe_float(map.vegetation_heat_stress_arr, idx),
			"dyn_temp_byte": int(dyn_data[d4]), "dyn_moisture_byte": int(dyn_data[d4 + 1]),
			"dyn_snow_byte": int(dyn_data[d4 + 2]), "dyn_vitality_byte": int(dyn_data[d4 + 3]),
			"eco_foliage_byte": int(eco_data[d4]), "eco_stress_byte": int(eco_data[d4 + 1]),
			"eco_transition_byte": int(eco_data[d4 + 2]), "eco_growth_byte": int(eco_data[d4 + 3]),
			"lut_path": lut_path, "lut_encode_path": encode_path,
			"lut_catchup": baker._river_atlas_probe_context.get("catchup", false),
			"lut_dirty_cells": dirty_cells,
		}
		baker._river_atlas_probe_rows.append(row)



static func _probe_float(baker: MapBaker, values: PackedFloat32Array, idx: int) -> float:
	return float(values[idx]) if idx >= 0 and idx < values.size() else NAN



static func bake_cell_luts(baker: MapBaker, map: MapData, world: WorldData, cache_valid: bool = false,
		publish_weather_lut: bool = true,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = true, defer_upload: bool = false) -> Dictionary:
	var total_t0_us := Time.get_ticks_usec()
	var report: Dictionary = {
		"path": "gdscript",
		"fallback": true,
		"reason": "",
		"elapsed_ms": 0.0,
		"lut_encode_path": "none",
		"lut_snow_source": "none",
		"weather_lut_published": false,
		"weather_lut_changed": false,
	}

	if map == null or world == null:
		report.reason = "missing_map_or_world"
		return report
	if not defer_upload:
		flush_staged_cell_lut_upload(baker, world)
	if world.lut_dims.x <= 0 or world.lut_dims.y <= 0:
		baker._ensure_cell_lut_dims(map, world)
	var lw: int = world.lut_dims.x
	var lh: int = world.lut_dims.y
	if lw <= 0 or lh <= 0:
		report.reason = "invalid_lut_dims"
		return report
	var n_cells: int = map.cell_count()
	var snow_cover_override: PackedFloat32Array = PackedFloat32Array()
	if map.snow_cover_arr.size() >= n_cells:
		snow_cover_override = map.snow_cover_arr
		report.lut_snow_source = "map_snow_cover_arr"
	else:
		report.lut_snow_source = "slot_or_facade"
	# 迷雾知识度：enum_lut 的 A 通道。两条打包路径（C++ encode_cell_luts 与下面的
	# GDScript fallback）必须都带上当前值，否则每日 LUT 重烘会把迷雾刷没、造成闪烁。
	# 真源只有 map.fog_k_arr 一份（VisionSolver 写），不存在第二份镜像。
	# 判据是"解算过没有"，不是数组大小：init_soa_from_bake 会把 fog_k_arr 分配成
	# 全 0，尺寸够但内容是未初始化状态。此时传下去会让 A 通道全 0（全图未探索），
	# 首帧整张地图变黑。解算前留空，两条打包路径都按全知 255 处理。
	var fog_k_override: PackedByteArray = map.fog_k_arr \
		if map.fog_solved and map.fog_k_arr.size() >= n_cells \
		else PackedByteArray()
	report["lut_fog_source"] = "map_fog_k_arr" if not fog_k_override.is_empty() else "none"
	# C++ 优先路径：scalar tight loop（即便 n_cells≈2400 也在 CPP 做，含 transition tracking）。
	if baker._world_ext != null:
		# Do not call refresh_slots_from_map() here: several native climate fields can be
		# newer in C++ slots than in MapData. Snow is different because weather/climate
		# already flush it for gameplay and diagnostics, so pass that one field explicitly.
		var out: Dictionary = baker._world_ext.encode_cell_luts({
			"map": map,
			"lut_w": lw,
			"lut_h": lh,
			"n_cells": n_cells,
			"terrain_lake": int(TerrainType.TERRAIN.LAKE),
			"terrain_sea_ice": int(TerrainType.TERRAIN.SEA_ICE),
			"veg_none": int(VegetationType.VEG.NONE),
			"cache_valid": cache_valid,
			"dirty_indices": dirty_indices,
			"force_full_encode": force_full_encode,
			"include_weather_lut": publish_weather_lut,
			"snow_cover_arr": snow_cover_override,
			"fog_k_arr": fog_k_override,
		})
		# Payload arrays are consumed locally. Never deep-copy or return them through the
		# scheduler/perf report: at 6400 cells the old path copied ~100 KiB several times.
		report = out.duplicate(false)
		report.erase("enum_lut")
		report.erase("dyn_lut")
		report.erase("eco_lut")
		report.erase("weather_lut")
		report["lut_encode_path"] = "gdext"
		baker._cell_lut_active_transition_count = int(out.get("active_transition_count", 0))
		if snow_cover_override.size() >= n_cells:
			report["lut_snow_source"] = "map_snow_cover_arr"
		if not bool(out.get("fallback", true)):
			var e = out.get("enum_lut", null)
			var d = out.get("dyn_lut", null)
			var c = out.get("eco_lut", null)
			if e is PackedByteArray and d is PackedByteArray and c is PackedByteArray:
				out["lut_encode_path"] = "gdext"
				baker._record_river_atlas_probe(map, out, d, c)
				report["dirty_cells"] = n_cells \
						if bool(out.get("full_encode", force_full_encode)) else dirty_indices.size()
				var wlut: PackedByteArray = out.get("weather_lut", PackedByteArray())
				if defer_upload:
					_stage_cell_lut_upload(baker, world, e, d, c, wlut)
				else:
					_publish_cell_lut_textures(baker, world, e, d, c, report,
							dirty_indices, force_full_encode)
					if not wlut.is_empty():
						report.merge(baker._publish_weather_lut_bytes(wlut, world, lw, lh), true)
				report["lut_total_ms"] = float(Time.get_ticks_usec() - total_t0_us) / 1000.0
				return report
	# A legacy/fallback encode publishes immediately. Flush an earlier native
	# batch first so a newer synchronous update cannot be replaced by it.
	flush_staged_cell_lut_upload(baker, world)
	baker._bake_cell_luts_gd(map, world, lw, lh, snow_cover_override, publish_weather_lut, fog_k_override)

	report["lut_encode_path"] = "gdscript"
	report["path"] = "gdscript"
	report["fallback"] = true
	return report


static func _publish_cell_lut_textures(baker: MapBaker, world: WorldData,
		e: PackedByteArray, d: PackedByteArray, c: PackedByteArray, report: Dictionary,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = true) -> void:
	var lw := world.lut_dims.x
	var lh := world.lut_dims.y
	var enum_changed: bool = world.enum_lut_tex == null \
			or baker._cell_enum_lut_bytes_cache.size() != e.size() \
			or baker._cell_enum_lut_bytes_cache != e
	var dyn_changed: bool = world.dyn_lut_tex == null \
			or baker._cell_dyn_lut_bytes_cache.size() != d.size() \
			or baker._cell_dyn_lut_bytes_cache != d
	var eco_changed: bool = world.eco_lut_tex == null \
			or baker._cell_eco_lut_bytes_cache.size() != c.size() \
			or baker._cell_eco_lut_bytes_cache != c
	# [qa-skip-lut-publish 2026-11-02] 二分"渲染线程崩溃是否来自每日
	# LUT 纹理上传"：pk_debug.cfg 里 `[render] skip_lut_publish=true`
	# 时只跳过 GPU 上传，模拟与报告照常（正常玩家没有该文件）。
	if baker._qa_skip_lut_publish():
		enum_changed = false
		dyn_changed = false
		eco_changed = false
	report["enum_lut_changed"] = enum_changed
	report["dyn_lut_changed"] = dyn_changed
	report["eco_lut_changed"] = eco_changed
	var upload_t0_us := Time.get_ticks_usec()
	if enum_changed:
		var enum_upload_t0_us := Time.get_ticks_usec()
		world.enum_lut_tex = baker._lut_tex_from_data(
			e, lw, lh, Image.FORMAT_RGBA8, world.enum_lut_tex)
		report["enum_lut_upload_ms"] = float(Time.get_ticks_usec() - enum_upload_t0_us) / 1000.0
		baker._cell_enum_lut_bytes_cache = e
	else:
		report["enum_lut_upload_ms"] = 0.0
	if dyn_changed:
		var dyn_upload_t0_us := Time.get_ticks_usec()
		# [dyn-lut-inplace 2026-11-02] 这里原来是"写后台纹理再交换引用"的
		# 双缓冲。后果是**每天换一个 Texture 对象**，hex_renderer 的
		# `_sync_cell_lut_textures()` 于是每天命中一次 stale-rebind 分支，
		# 在同一帧里给两张 world_map 材质换 sampler —— 真机渲染线程
		# 10~60 秒后 SIGSEGV 的主嫌疑点。`dyn_lut_tex_back` 全项目没有任何
		# 读者，双缓冲没换来收益；改成与 enum/eco 一致的原地 update()
		# （Godot 的 ImageTexture.update() 由 RenderingServer 排队，
		# 采样中的纹理更新是它的正常用法）。
		world.dyn_lut_tex = baker._lut_tex_from_data(
			d, lw, lh, Image.FORMAT_RGBA8, world.dyn_lut_tex)
		report["dyn_lut_upload_ms"] = float(Time.get_ticks_usec() - dyn_upload_t0_us) / 1000.0
		baker._cell_dyn_lut_bytes_cache = d
	else:
		report["dyn_lut_upload_ms"] = 0.0
	if eco_changed:
		var eco_upload_t0_us := Time.get_ticks_usec()
		world.eco_lut_tex = baker._lut_tex_from_data(
			c, lw, lh, Image.FORMAT_RGBA8, world.eco_lut_tex)
		report["eco_lut_upload_ms"] = float(Time.get_ticks_usec() - eco_upload_t0_us) / 1000.0
		baker._cell_eco_lut_bytes_cache = c
	else:
		report["eco_lut_upload_ms"] = 0.0
	report["texture_upload_ms"] = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
	# [cell-field 2026-11-18] cell_table 紧跟 eco_lut 发布（同一个 refresh），
	# 是追加工件：上面三张 LUT 的字节与上传时机一行没改。
	# layer0/2 由 enum_changed 门控重建，layer1 只在 dyn_changed 时重写 —— 与
	# dyn_lut 的更新节奏严格同步（每天都变的是 state，不是 class）。
	#
	# 放在 helper 里而不是 bake_cell_luts 的调用点：native 的 defer_upload 路径由
	# flush_staged_cell_lut_upload 直接调本函数发布，绕开 bake_cell_luts；表若留在
	# 调用点，那条路上 LUT 换了而表还是旧的。
	# map 取 baker._last_bake_map：发布器签名里没有 map，而整个会话就是 bake_world
	# 那一个实例（与 _publish_weather_table_from_luts 同一先例）；null 时
	# _publish_cell_table 自己会把 bound/layers 归零。
	report.merge(_publish_cell_table(baker, baker._last_bake_map, world, e, d,
		enum_changed, dyn_changed), true)
	var bounce_t0_us := Time.get_ticks_usec()
	report["bounce_lut_published"] = false
	if enum_changed or dyn_changed or world.bounce_lut_tex == null:
		report["bounce_lut_published"] = baker._publish_bounce_lut(
			e, d, world, lw, lh, dirty_indices, force_full_encode)
	report["bounce_lut_ms"] = float(Time.get_ticks_usec() - bounce_t0_us) / 1000.0

static func _stage_cell_lut_upload(baker: MapBaker, world: WorldData,
		enum_bytes: PackedByteArray, dyn_bytes: PackedByteArray, eco_bytes: PackedByteArray,
		weather_bytes: PackedByteArray) -> void:
	var pending := world.staged_cell_lut_upload
	pending["enum_bytes"] = enum_bytes
	pending["dyn_bytes"] = dyn_bytes
	pending["eco_bytes"] = eco_bytes
	if weather_bytes.is_empty():
		return
	# Keep the last two distinct snapshots so a batch feeds the same interpolation pair
	# as individual uploads. Packed arrays keep their old bytes via copy-on-write.
	var current: PackedByteArray = pending.get("weather_current", baker._prev_weather_lut_bytes)
	var has_current := pending.has("weather_current") or (world.weather_lut_tex != null
			and world.weather_lut_tex.get_size() == Vector2(world.lut_dims))
	if has_current and current == weather_bytes:
		return
	pending["weather_previous"] = current if current.size() == weather_bytes.size() else weather_bytes
	pending["weather_current"] = weather_bytes


static func flush_staged_cell_lut_upload(baker: MapBaker, world: WorldData) -> void:
	if world == null or world.staged_cell_lut_upload.is_empty():
		return
	var pending := world.staged_cell_lut_upload
	world.staged_cell_lut_upload = {}
	_publish_cell_lut_textures(baker, world, pending["enum_bytes"],
			pending["dyn_bytes"], pending["eco_bytes"], {})
	if pending.has("weather_current"):
		_upload_weather_lut_pair(baker, world, world.lut_dims.x, world.lut_dims.y,
				pending["weather_previous"], pending["weather_current"])


# GDScript fallback：per-cell LUT 全量烘焙（C++ encode_cell_luts 不可用时）。

static func _bake_cell_luts_gd(baker: MapBaker, map: MapData, world: WorldData, lw: int, lh: int,
		snow_cover_override: PackedFloat32Array = PackedFloat32Array(),
		publish_weather_lut: bool = true,
		fog_k_override: PackedByteArray = PackedByteArray()) -> void:
	var slots: int = lw * lh
	var enum_data := PackedByteArray(); enum_data.resize(slots * 4)
	var dyn_data := PackedByteArray(); dyn_data.resize(slots * 4)
	var eco_data := PackedByteArray(); eco_data.resize(slots * 4)
	var weather_data := PackedByteArray(); weather_data.resize(slots * 4)

	for cell in map.all_cells():
		if cell == null:
			continue
		var ci: int = int(cell.index)
		if ci < 0 or ci >= slots:
			continue
		# enum LUT：R=terrain G=vegetation B=cover A=迷雾知识度 k（与 C++ 同布局）。
		# 未接线时 A=255（全知），保证迷雾系统关闭时视觉与改造前一致。
		var e4: int = ci * 4
		enum_data[e4]     = int(cell.terrain) & 0xFF
		enum_data[e4 + 1] = int(cell.vegetation) & 0xFF
		enum_data[e4 + 2] = int(cell.cover) & 0xFF
		enum_data[e4 + 3] = fog_k_override[ci] if ci < fog_k_override.size() else 255
		var snow_override: float = snow_cover_override[ci] if ci < snow_cover_override.size() else -1.0
		var dsig: int = baker._dynamic_cell_signature(cell, snow_override)
		var d4: int = ci * 4
		dyn_data[d4]     = dsig & 0xFF
		dyn_data[d4 + 1] = (dsig >> 8) & 0xFF
		dyn_data[d4 + 2] = (dsig >> 16) & 0xFF
		dyn_data[d4 + 3] = (dsig >> 24) & 0xFF
		var cur_vit_byte: int = baker._q01_byte(float(cell.vegetation_vitality))
		var esig: int = baker._ecology_visual_signature(cell, 0, cur_vit_byte, snow_override)
		var c4: int = ci * 4
		eco_data[c4]     = esig & 0xFF
		eco_data[c4 + 1] = (esig >> 8) & 0xFF
		eco_data[c4 + 2] = (esig >> 16) & 0xFF
		eco_data[c4 + 3] = (esig >> 24) & 0xFF
		# weather LUT：R=type, G=intensity, B=cloud, A=vapor（与 C++ encode_cell_luts 同布局）
		var w4: int = ci * 4
		weather_data[w4]     = int(cell.weather_type) & 0xFF
		weather_data[w4 + 1] = baker._q01_byte(float(cell.weather_intensity))
		weather_data[w4 + 2] = baker._q01_byte(float(cell.weather_cloud))
		weather_data[w4 + 3] = baker._q01_byte(float(cell.weather_vapor))
	world.enum_lut_tex = baker._lut_tex_from_data(enum_data, lw, lh, Image.FORMAT_RGBA8, world.enum_lut_tex)
	# [dyn-lut-inplace 2026-11-02] 以前这里对 dyn_lut 做前后台双缓冲交换：
	#   var dyn_front := world.dyn_lut_tex
	#   world.dyn_lut_tex = _lut_tex_from_data(..., world.dyn_lut_tex_back)
	#   world.dyn_lut_tex_back = dyn_front
	# 后果是**每天换一个 Texture 对象**（两个对象往复），hex_renderer 的
	# `_sync_cell_lut_textures()` 就会每天命中一次"stale LUT rebind"分支，在同一个
	# 帧里给两张 world_map 材质换 sampler（真机渲染线程 10~60s 后 SIGSEGV 的嫌疑点）。
	# dyn_lut_tex_back 全项目没有任何读者，双缓冲没有换来任何收益，改成和
	# enum/eco LUT 一样的原地 update()。
	world.dyn_lut_tex = baker._lut_tex_from_data(
		dyn_data, lw, lh, Image.FORMAT_RGBA8, world.dyn_lut_tex)
	world.eco_lut_tex = baker._lut_tex_from_data(eco_data, lw, lh, Image.FORMAT_RGBA8, world.eco_lut_tex)
	# [cell-field 2026-11-18] 与 gdext 分支同节奏：三张 LUT 刷完紧接着发 cell_table。
	# 这条路径本来就是全量重烘（enum/dyn 都刚重算），static/state 都按 true 传。
	_publish_cell_table(baker, map, world, enum_data, dyn_data, true, true)
	_publish_bounce_lut_gd(baker, enum_data, dyn_data, world, lw, lh)
	if publish_weather_lut:
		baker._publish_weather_lut_bytes(weather_data, world, lw, lh)



# ─── [cell-field-web 2026-11-18] layer3 class_by_index 的可发布判据 ────────────────
# 判定 + 降级警告的唯一出口。发布器（_publish_cell_table）与 layout 测试都调它，
# 避免"测试复述一遍判据、发布器里是另一份字面量"的分叉。
#
# 返回「这一版数据对外承诺的 cell_table 层数」，直接写进 WorldData.cell_table_layers：
#   CellTableCodecScript.LAYER_COUNT(4)           = layer3 已发布，shader 可按 cell.index 查
#   CellTableCodecScript.LAYER_CLASS_BY_INDEX(3)  = 只有 offset 空间三层；第 4 层是整层
#                                                   FILL_BYTE 占位 + 一条 warning
#
# 装不下（n_cells > map_w × map_h）时**只能**降级：层尺寸必须与 layer0 相同，换一种尺寸
# 会让 shader 里唯一的 `cell_table_size` 出现两套语义（Web 方案 §3.1）。
static func cell_table_layer_target(n_cells: int, map_w: int, map_h: int) -> int:
	if CellTableCodecScript.index_space_fits(n_cells, map_w, map_h):
		return CellTableCodecScript.LAYER_COUNT
	push_warning("[cell-table] layer3 class_by_index needs %d <= %d x %d texels; publishing %d layers"
		% [n_cells, map_w, map_h, CellTableCodecScript.LAYER_CLASS_BY_INDEX])
	return CellTableCodecScript.LAYER_CLASS_BY_INDEX


# ─── [cell-field 2026-11-18] cell_table：per-cell 属性表（Texture2DArray，offset 空间）───────
# 契约：docs/plans/terrain-cell-field-contract.md §3（层布局，offset 空间）/ §5.3（发布）。
# 方案：docs/plans/terrain-hex-mesh-implementation-plan.md §3.4。
#
# 与三张 LUT 的关系：**额外的产物，不是替代品**。enum/dyn/eco 的字节与上传时机一行没改，
# 关闭 PK_CELL_FIELD 时 shader 仍旧读它们；cell_table 只是把同一份字节按 offset 空间再排
# 一遍给新管线用。
#
# 为什么必须重排：`cell.index` 是 `_cells` 字典的插入顺序（map_data.gd），shader 由 hex
# 坐标推不出来。重排表就是 `terrain_index_baker.gd::build_cell_inputs()` 产出的
# `offset_to_index`（`o2i[off.y*map_w + posmod(off.x, map_w)] = ci`），这里按同一规则现场
# 建一遍（O(n_cells)，与三张 LUT 的打包同一量级）——不新增第二个数据源，也不额外持有一份
# 长期缓存（地图/回绕/map 尺寸一变，缓存就错，而这条路径本来就要遍历 n_cells）。
#
# 刷新策略（daily 路径）：
#   need_all    = 纹理缺失 / 尺寸或层数不符 / 上次发布失败（bound=false）
#   need_static = need_all or static_changed → layer0 class + layer2 aux + layer3 class_by_index
#   need_state  = need_all or state_changed  → layer1 state（与 dyn_lut 同源）
# 两者都 false 且已 bound ⇒ 直接返回，不碰 GPU（每日只有 state 变时省掉两层重建）。
# 调用方给的 static_changed：gdext 分支传 `enum_changed`（fog_k 搭车 enum_lut.A，因此探索
# 变化也会触发 class 重建——一张 ≤100×64 的 O(n) 字节拷贝，取舍是"不引入新缓存字段"）；
# GD fallback 分支恒 true（那条路径本来就全量重烘）。state_changed 传 `dyn_changed`。
#
# [cell-field-web 2026-11-18] layer3 class_by_index（Web 方案 §3.1）：
#   内容与 layer0 **逐字节同值**，只是不重排（第 i 格落在 (i % map_w, i / map_w)）。
#   因此它与 layer0 **写在同一个 if need_static 分支里**、用同一批 terr/veg/cover/landform
#   字节生成、受同一个 static_changed 判定门控——方案 §6 风险表点名了「只更新 layer0、
#   忘了 layer3」这条，唯一的结构性对策就是"同一个发布函数、同一次判定"。
#   前提 n_cells ≤ map_w × map_h：装不下时 layer3 不可发布 ⇒ 整层写 FILL_BYTE 占位、
#   world.cell_table_layers 记 3、push_warning，绝不把越界/错位的字节静默写进纹理。
static func _publish_cell_table(baker: MapBaker, map: MapData, world: WorldData,
		enum_bytes: PackedByteArray, dyn_bytes: PackedByteArray,
		static_changed: bool = true, state_changed: bool = true) -> Dictionary:
	var report: Dictionary = {
		"cell_table_published": false,
		"cell_table_reason": "",
		"cell_table_layers": "",
		"cell_table_layers_published": 0,
		"cell_table_ms": 0.0,
	}
	if world == null:
		report.cell_table_reason = "missing_world"
		return report
	if map == null or enum_bytes.is_empty() or dyn_bytes.is_empty():
		# 没有源字节就没有合法的表；宁可标明"未绑定"也不留旧数据冒充新数据。
		# [cell-field-web 2026-11-18] 层数同时归零：渲染推送按 `layers >= 4` 决定
		# cell_class_index_bound，残留的旧值会让 shader 去读一张已经不存在的层。
		world.cell_table_bound = false
		world.cell_table_layers = 0
		report.cell_table_reason = "missing_map_or_lut_bytes"
		return report
	var map_w: int = int(map.width)
	var map_h: int = int(map.height)
	var n_cells: int = map.cell_count()
	if map_w <= 0 or map_h <= 0 or n_cells <= 0:
		world.cell_table_bound = false
		world.cell_table_layers = 0
		report.cell_table_reason = "invalid_map_dims_or_cells"
		return report
	var bytes_per_cell: int = CellTableCodecScript.BYTES_PER_TEXEL
	if enum_bytes.size() < n_cells * bytes_per_cell or dyn_bytes.size() < n_cells * bytes_per_cell:
		# LUT 网格比 n_cells 小 ⇒ 三层都会读到错位/越界字节。宁可不发布。
		world.cell_table_bound = false
		world.cell_table_layers = 0
		push_warning("[cell-table] LUT payload too small (enum %d / dyn %d bytes for %d cells)"
			% [enum_bytes.size(), dyn_bytes.size(), n_cells])
		report.cell_table_reason = "lut_payload_too_small"
		return report
	# [cell-field-web 2026-11-18] layer3 的前提条件（Web 方案 §3.1）：index 空间要求
	# n_cells ≤ map_w × map_h，且层尺寸必须与 layer0 相同。装不下时**不发布** layer3
	# （对外承诺 3 层 ⇒ cell_class_index_bound = false），不打补丁换尺寸。
	# 判定与降级警告都走 cell_table_layer_target()：发布器与测试共用同一个出口。
	var published_layers: int = cell_table_layer_target(n_cells, map_w, map_h)
	var index_space_ok: bool = published_layers >= CellTableCodecScript.LAYER_COUNT
	# [qa-skip-lut-publish 2026-11-02] 与 LUT 上传同一个 QA 开关：二分"渲染线程崩溃是否
	# 来自每日纹理上传"时必须一起跳过，否则新增的上传点会污染结论。
	if baker._qa_skip_lut_publish():
		report.cell_table_reason = "qa_skip_lut_publish"
		return report

	var t0_us: int = Time.get_ticks_usec()
	var dims := Vector2i(map_w, map_h)
	var layer_count: int = CellTableCodecScript.LAYER_COUNT
	var tex: Texture2DArray = world.cell_table_tex
	var shape_ok: bool = tex != null \
			and tex.get_width() == map_w and tex.get_height() == map_h \
			and tex.get_layers() == layer_count
	# 尺寸/层数不符或上次失败 ⇒ 整张重建；否则复用同一个 Texture2DArray 逐层 update_layer
	# （P0 平台探针已验证 Vulkan / OpenGL3 上 update_layer 只动目标层）。
	var need_all: bool = not shape_ok or not world.cell_table_bound \
			or world.cell_table_dims != dims
	var need_static: bool = need_all or static_changed
	var need_state: bool = need_all or state_changed
	if not need_static and not need_state:
		report.cell_table_reason = "unchanged"
		return report

	# ── 1) 重排表 + per-cell 通道：一遍 map.all_cells()，O(n_cells) ─────────────
	# [cell-field-overlays 2026-11-18] o2i 的构造规则抽成 _build_offset_to_index()，
	# 与 weather_table 的发布器**共用同一个出口**（原来这段是内联的，一旦两份规则漂移，
	# cell_table 与 weather_table 会用两套 offset 语义而各自都"自洽"）。规则本身没变：
	#   off = HexUtils.cube_to_offset(q, r)；只丢 row 越界（南北 padding）；
	#   col 走 posmod(map_w)（odd-r 回绕，东侧越界落 col 0、西侧落 map_w-1）。
	var o2i: PackedInt32Array = _build_offset_to_index(map, map_w, map_h)
	# layer0.A landform：**不在 enum_lut 里**。首选 map.landform_arr（SoA，与
	# terrain_baker.gd::_landform_bytes_for_map 的 fast path 同一份字节，也是 native
	# surface bake 的 `cell_landform` 来源）；SoA 还没建好时在下面的循环里读 cell.landform
	# 补齐（同 terrain_index_baker.gd:49 的做法）。
	var landform_bytes: PackedByteArray = map.landform_arr
	var fill_landform: bool = landform_bytes.size() < n_cells
	# layer2.G 水深 8bit：per-cell 水面高度取自 cell.water_depth（terrain_index_baker 打包成
	# `cell_water_depth` 的同一个字段），在格心按 C++ 公式折算成 depth01。
	var water_depth_bytes := PackedByteArray()
	if need_static:
		water_depth_bytes.resize(n_cells)
		if fill_landform:
			landform_bytes = PackedByteArray()
			landform_bytes.resize(n_cells)
	# C++ 归一化分母：湖泊 0.16（world_ext_bake.cpp:1088），海水=sea_level
	# （world_ext_bake.cpp:1084 的 knobs["sea_level"]，GDScript 侧同一来源 world.sea_level）。
	var sea_norm: float = maxf(float(world.sea_level), 1e-4)
	var lake_norm: float = maxf(PK_LAKE_DEPTH_NORM, 1e-4)
	for cell in map.all_cells():
		if cell == null:
			continue
		var ci: int = int(cell.index)
		if ci < 0 or ci >= n_cells:
			continue
		if not need_static:
			continue
		if fill_landform:
			landform_bytes[ci] = int(cell.landform) & 0xFF
		# 水深：镜像 world_ext_bake.cpp:1099-1115（terrain_surface_tex.layer5.B 的来源）
		# 的逐像素公式 `depth01 = clamp01((surface - height) / (is_lake ? 0.16 : sea))`，
		# 在**格心**用 cell.elevation 代替烘焙高度求值 ⇒ 与 layer5.B 同式、同 8bit 量化
		# （`round(depth01*255)`），格心附近同量级；不是逐字节相等——layer5.B 用的是含
		# carve/侵蚀的逐像素高度。水面高度 ≤ 1e-4 判陆格 ⇒ 0（与 C++ 的 surface 判据一致）。
		var level: float = float(cell.water_depth)
		if level > 1e-4:
			var norm: float = sea_norm
			if int(cell.terrain) == int(TerrainType.TERRAIN.LAKE):
				norm = lake_norm
			var draw: float = maxf(level - float(cell.elevation), 0.0)
			water_depth_bytes[ci] = CellTableCodecScript.q01_byte(draw / norm)

	# ── 2) 四层字节（按 cell.index 生成 → layer0/1/2 重排到 offset 空间，layer3 不重排）──
	var class_image: Image = null
	var aux_image: Image = null
	var state_image: Image = null
	var class_index_image: Image = null
	if need_static:
		# layer0：R/G/B 直接取 enum_lut 的 R/G/B（同一份量化值 ⇒ 与 LUT 逐字节一致，
		# 类别通道不会出现"表与 LUT 说法不同"的二义），A=landform。
		var terr := PackedByteArray(); terr.resize(n_cells)
		var veg := PackedByteArray(); veg.resize(n_cells)
		var cover := PackedByteArray(); cover.resize(n_cells)
		var fog_k := PackedByteArray(); fog_k.resize(n_cells)
		for ci in range(n_cells):
			var e4: int = ci * bytes_per_cell
			terr[ci] = enum_bytes[e4]
			veg[ci] = enum_bytes[e4 + 1]
			cover[ci] = enum_bytes[e4 + 2]
			# layer2.R fog_k：就是 enum_lut.A 的当前值（world_data.gd 的 A 通道注释 +
			# world_ext_cell_luts.cpp:390 `FOGK[ci]`，迷雾的唯一真源，不另建镜像）。
			fog_k[ci] = enum_bytes[e4 + 3]
		class_image = _cell_table_image(CellTableCodecScript.reorder_to_offset(
			CellTableCodecScript.class_bytes(n_cells, terr, veg, cover, landform_bytes),
			o2i, map_w, map_h), map_w, map_h)
		# layer2：R=fog_k、G=water_depth（8bit，与 layer5.B 同精度）、B=flags（预留，恒 0）、
		# A=0。flags 传 null ⇒ codec 写 documented 默认 0。
		aux_image = _cell_table_image(CellTableCodecScript.reorder_to_offset(
			CellTableCodecScript.aux_bytes(n_cells, fog_k, water_depth_bytes, null),
			o2i, map_w, map_h), map_w, map_h)
		# [cell-field-web 2026-11-18] layer3 class_by_index：**同一批** terr/veg/cover/
		# landform_bytes，**同一个** need_static 判定，与 layer0 并排生成——方案 §6 的
		# 「只更新 layer0、忘了 layer3」在这里没有第二种可能。区别只有一处：不调
		# reorder_to_offset（index 空间的原样字节），所以两层内容必然互为重排。
		var class_index_bytes := PackedByteArray()
		if index_space_ok:
			class_index_bytes = CellTableCodecScript.class_by_index_bytes(
				n_cells, terr, veg, cover, landform_bytes, map_w, map_h)
			if class_index_bytes.size() != map_w * map_h * bytes_per_cell:
				push_error("[cell-table] layer3 class_by_index payload %d bytes, want %d for %dx%d"
					% [class_index_bytes.size(), map_w * map_h * bytes_per_cell, map_w, map_h])
				index_space_ok = false
		if not index_space_ok:
			# 装不下 ⇒ 不写 index 空间的数据（会越界/错位），但仍要凑够 LAYER_COUNT 层才
			# 能建 Texture2DArray：整层写 FILL_BYTE 占位，配合 cell_table_layers = 3。
			class_index_bytes = CellTableCodecScript.index_space_fill_bytes(map_w, map_h)
		class_index_image = _cell_table_image(class_index_bytes, map_w, map_h)
	if need_state:
		# layer1：与 dyn_lut **逐字节同源**（R=temp G=wet B=snow A=vitality|sea_ice），
		# 只做一次 offset 重排，不做任何重新量化。
		state_image = _cell_table_image(CellTableCodecScript.reorder_to_offset(
			dyn_bytes, o2i, map_w, map_h), map_w, map_h)
	if need_static and (class_image == null or aux_image == null or class_index_image == null):
		world.cell_table_bound = false
		world.cell_table_layers = 0
		report.cell_table_reason = "layer_payload_mismatch"
		report.cell_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return report
	if need_state and state_image == null:
		world.cell_table_bound = false
		world.cell_table_layers = 0
		report.cell_table_reason = "layer_payload_mismatch"
		report.cell_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return report

	# ── 3) 建表 / 逐层刷新 ────────────────────────────────────────────────────
	var updated_layers := PackedStringArray()
	if need_all:
		var images: Array[Image] = [class_image, state_image, aux_image, class_index_image]
		tex = _create_cell_table_array(images)
		if tex == null:
			# 建不起来就明确标未绑定：shader 走"无表"退化，而不是读一张半成品。
			world.cell_table_bound = false
			world.cell_table_layers = 0
			report.cell_table_reason = "create_failed"
			report.cell_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
			return report
		world.cell_table_tex = tex
		updated_layers.append_array(PackedStringArray(["class", "state", "aux"]))
		if index_space_ok:
			updated_layers.append("class_by_index")
	else:
		if need_static:
			tex.update_layer(class_image, CellTableCodecScript.LAYER_CLASS)
			tex.update_layer(aux_image, CellTableCodecScript.LAYER_AUX)
			updated_layers.append("class")
			updated_layers.append("aux")
			# [cell-field-web 2026-11-18] layer3 与 layer0 **同分支**更新：同一个
			# static_changed 判定下的两层，任何一个单独跳过都会让 Web 的 GI 弹射色
			# 与 class 层说法不一致（方案 §6 风险表）。
			if index_space_ok:
				tex.update_layer(class_index_image,
					CellTableCodecScript.LAYER_CLASS_BY_INDEX)
				updated_layers.append("class_by_index")
		if need_state:
			tex.update_layer(state_image, CellTableCodecScript.LAYER_STATE)
			updated_layers.append("state")
	world.cell_table_dims = dims
	world.cell_table_bound = true
	# [cell-field-web 2026-11-18] 实际**可读**的层数：index 空间装不下时只承诺 3 层
	# （第 4 层是占位零层，shader 侧 cell_class_index_bound 会因此为 false）。
	world.cell_table_layers = published_layers if index_space_ok \
			else CellTableCodecScript.LAYER_CLASS_BY_INDEX
	report.cell_table_published = true
	report.cell_table_reason = "ok"
	report.cell_table_layers = ",".join(updated_layers)
	report.cell_table_layers_published = int(world.cell_table_layers)
	report.cell_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	return report


## 一层 offset 空间字节 → RGBA8 Image（尺寸必须正好 map_w*map_h*4）。
## 返回 null 只可能是调用方传进来的字节长度不对（reorder_to_offset 恒返回满尺寸）。
static func _cell_table_image(data: PackedByteArray, w: int, h: int) -> Image:
	var expected: int = maxi(w, 0) * maxi(h, 0) * CellTableCodecScript.BYTES_PER_TEXEL
	if w <= 0 or h <= 0 or data.size() != expected:
		push_warning("[cell-table] layer payload %d bytes, want %d for %dx%d"
			% [data.size(), expected, w, h])
		return null
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)


# ═══════════════════════════════════════════════════════════════════════════════
# [cell-field-overlays 2026-11-18] weather_table：天气 + 风的 offset 空间表
# 方案 §3.3（层契约 / 双缓冲靠层号 / padding 规则）；结构照 _publish_cell_table：
# 同一套「形状判定 → 整张重建 or update_layer → 失败一律 bound=false 不越界」。
#
# 为什么要有它：天气 overlay 的场函数（`pk_hex_tri`）给出的是 **offset 坐标**，现有
# `weather_lut` / `wind_lut` 按 `cell.index` 排列。要么每张表先读一次 map_index 做间接寻址
# （依赖读，延迟串行），要么在发布时按 o2i 重排一次（本文件的做法，与 cell_table 同源）。
#
# 双缓冲：
#   提交 N    :  cur = 0/1（WorldData.weather_table_cur），prev = 1 - cur
#               wind_cur = 2 + cur，wind_prev = 2 + (1 - cur)
#   每次提交  :  只 update_layer `back = 1 - cur`（天气）与 `2 + back`（风），然后 cur = back。
#               老 cur 层原封不动 ⇒ 它自然成为新的 prev，**不需要拷贝**。
#   首次/重建 :  4 层全部写同一份数据、cur = 0（等价于今天 prev = cur 的首次发布）。
# ═══════════════════════════════════════════════════════════════════════════════

## offset 线性下标 → cell.index 的构造规则（唯一出口）。
##
## 与 terrain_index_baker.gd:54-56（build_cell_inputs）逐字一致：
##   off = HexUtils.cube_to_offset(q, r)；只丢 row 越界（南北 padding，o2i 保持 -1）；
##   col 走 posmod(map_w)（odd-r 回绕，东侧越界落 col 0、西侧落 map_w-1）。
## `_publish_cell_table` 与 `weather_table_commit_plan` 都调它 —— 两份重排表不可能漂移。
static func _build_offset_to_index(map: MapData, map_w: int, map_h: int) -> PackedInt32Array:
	var o2i := PackedInt32Array()
	if map == null or map_w <= 0 or map_h <= 0:
		return o2i
	o2i.resize(map_w * map_h)
	o2i.fill(-1)
	for cell in map.all_cells():
		if cell == null:
			continue
		var ci: int = int(cell.index)
		if ci < 0:
			continue
		var off: Vector2i = HexUtils.cube_to_offset(cell.q, cell.r)
		if off.y >= 0 and off.y < map_h:
			o2i[off.y * map_w + posmod(off.x, map_w)] = ci
	return o2i


## 一次天气提交的**纯字节计划**（不碰 GPU）：发布器与布局测试共用同一个出口。
##
## 入参全部是 index 空间的原始字节（长度 = lut_w * lut_h * 4，按 cell.index 排布）：
##   weather_src : R=type G=intensity B=cloud A=vapor（weather_lut 字节）
##   wind_src    : RG=风向*0.5+0.5 B=speed/20 A=1（wind_lut 字节）
##   o2i         : _build_offset_to_index() 的结果（map_w * map_h，-1 = padding）
##   cur_before  : 上一次提交后的层号（0/1），-1 = 还没有任何一次成功提交
##
## 返回：
##   ok           : false 时 reason 说明原因，调用方必须把 weather_table_valid 置 false
##   重建（rebuild）: 首次提交 / cur_before 非法 ⇒ 4 层全写、next_cur = 0
##   增量           : 只写 back = 1 - cur_before（天气）与 2 + back（风），next_cur = back
##   layer_ids    : 本次要 update_layer 的层号（PackedInt32Array）
##   layer_bytes  : 与 layer_ids 一一对应的、已是 offset 空间的字节
static func weather_table_commit_plan(weather_src: PackedByteArray, wind_src: PackedByteArray,
		o2i: PackedInt32Array, map_w: int, map_h: int, n_cells: int,
		cur_before: int) -> Dictionary:
	var plan: Dictionary = {
		"ok": false,
		"reason": "",
		"rebuild": false,
		"next_cur": -1,
		"layer_ids": PackedInt32Array(),
		"layer_bytes": [],
	}
	if map_w <= 0 or map_h <= 0:
		plan.reason = "invalid_map_dims"
		return plan
	if n_cells <= 0:
		plan.reason = "invalid_cell_count"
		return plan
	var bytes_per_cell: int = CellTableCodecScript.BYTES_PER_TEXEL
	if o2i.size() != map_w * map_h:
		# 重排表的长度必须与纹理尺寸一致，否则 offset 语义直接错位。
		plan.reason = "offset_to_index_size_mismatch"
		return plan
	if map_w * map_h < n_cells:
		# offset 空间装不下全部 cell：重排会丢格（不是越界写，但也绝不发布）。
		plan.reason = "offset_space_too_small"
		return plan
	# 长度判据照 _publish_cell_table：LUT 网格比 n_cells 小时读到的就是错位字节。
	if weather_src.size() < n_cells * bytes_per_cell or wind_src.size() < n_cells * bytes_per_cell:
		plan.reason = "lut_payload_too_small"
		return plan
	var weather_layer: PackedByteArray = CellTableCodecScript.reorder_to_offset(
		weather_src, o2i, map_w, map_h, bytes_per_cell, WEATHER_TABLE_PAD_TYPE)
	var wind_layer: PackedByteArray = CellTableCodecScript.reorder_to_offset(
		wind_src, o2i, map_w, map_h, bytes_per_cell, 0)
	var want: int = map_w * map_h * bytes_per_cell
	if weather_layer.size() != want or wind_layer.size() != want:
		# reorder_to_offset 在 texels<=0 时才返回空；这里等价于上面的尺寸检查，留着做双保险。
		plan.reason = "reorder_size_mismatch"
		return plan
	plan.ok = true
	plan.reason = "ok"
	if cur_before != WEATHER_TABLE_LAYER_WEATHER_A and cur_before != WEATHER_TABLE_LAYER_WEATHER_B:
		# 首次提交（或上次失败后 cur 被清成 -1）：整张重建，4 层写同一份。
		plan.rebuild = true
		plan.next_cur = WEATHER_TABLE_LAYER_WEATHER_A
		plan.layer_ids = PackedInt32Array([
			WEATHER_TABLE_LAYER_WEATHER_A, WEATHER_TABLE_LAYER_WEATHER_B,
			WEATHER_TABLE_LAYER_WIND_A, WEATHER_TABLE_LAYER_WIND_B])
		plan.layer_bytes = [
			weather_layer, weather_layer.duplicate(), wind_layer, wind_layer.duplicate()]
		return plan
	var back: int = WEATHER_TABLE_LAYER_WEATHER_A if cur_before == WEATHER_TABLE_LAYER_WEATHER_B \
		else WEATHER_TABLE_LAYER_WEATHER_B
	plan.rebuild = false
	plan.next_cur = back
	plan.layer_ids = PackedInt32Array([back, WEATHER_TABLE_LAYER_WIND_BASE + back])
	plan.layer_bytes = [weather_layer, wind_layer]
	return plan


## weather_table 发布器。入口挂在 `_publish_weather_lut_bytes` —— 即**现有天气提交点**，
## 不新建节拍：weather_lut 真的换字节的那一次，weather_table 也翻一层。
##
## 与 cell_table 发布器的对应关系：
##   * 同样的 QA 跳过开关（_qa_skip_lut_publish）——二分"渲染线程崩溃是否来自纹理上传"时
##     新增的上传点必须一起跳过，否则结论被污染；
##   * 同样的"形状不对就整张重建，否则 update_layer 逐层复用"；
##   * 失败一律 `weather_table_valid = false` + `weather_table_cur = -1`（shader 退回旧 LUT），
##     绝不留半成品，也绝不越界写。
static func _publish_weather_table(baker: MapBaker, map: MapData, world: WorldData,
		weather_bytes: PackedByteArray, wind_bytes: PackedByteArray) -> Dictionary:
	var t0_us: int = Time.get_ticks_usec()
	var report: Dictionary = {
		"weather_table_published": false,
		"weather_table_rebuilt": false,
		"weather_table_cur": -1,
		"weather_table_reason": "",
		"weather_table_ms": 0.0,
	}
	if world == null:
		report.weather_table_reason = "missing_world"
		return report
	if baker._qa_skip_lut_publish():
		# 不动已有表：QA 开关的语义是"只跳过 GPU 上传"，模拟与报告照常。
		report.weather_table_reason = "qa_skip_lut_publish"
		return report
	if map == null:
		# 拿不到 map 就重建不出 o2i。宁可标明"不可用"也不留旧数据冒充新数据。
		world.weather_table_valid = false
		world.weather_table_cur = -1
		report.weather_table_reason = "missing_map"
		return report
	var map_w: int = int(map.width)
	var map_h: int = int(map.height)
	var n_cells: int = map.cell_count()
	var o2i: PackedInt32Array = _build_offset_to_index(map, map_w, map_h)
	var plan: Dictionary = weather_table_commit_plan(
		weather_bytes, wind_bytes, o2i, map_w, map_h, n_cells, world.weather_table_cur)
	if not bool(plan.get("ok", false)):
		world.weather_table_valid = false
		world.weather_table_cur = -1
		report.weather_table_reason = String(plan.get("reason", "plan_failed"))
		report.weather_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		push_warning("[weather-table] skipped: %s (weather %d / wind %d bytes, %dx%d, %d cells)"
			% [report.weather_table_reason, weather_bytes.size(), wind_bytes.size(),
				map_w, map_h, n_cells])
		return report

	var dims := Vector2i(map_w, map_h)
	var tex: Texture2DArray = world.weather_table_tex
	# update_layer 可用性：GLES3 / WebGL2 上由 Web 方案 W0 的 P0 探针验；这里按
	# 「Texture2DArray 有没有这个方法」判，不可用就走整张重建（约 38 KB，可忽略）。
	var can_update_layer: bool = tex != null and tex.has_method("update_layer")
	var shape_ok: bool = can_update_layer \
			and tex.get_width() == map_w and tex.get_height() == map_h \
			and tex.get_layers() == WEATHER_TABLE_LAYERS \
			and world.weather_table_dims == dims \
			and world.weather_table_valid \
			and not bool(plan.get("rebuild", false))
	var layer_ids: PackedInt32Array = plan.get("layer_ids", PackedInt32Array())
	var layer_bytes: Array = plan.get("layer_bytes", [])
	if shape_ok:
		# ── 增量：只写 back（天气）+ 2+back（风）两层，其余两层原封不动 ──────────
		for i in range(layer_ids.size()):
			var data: PackedByteArray = layer_bytes[i]
			var image: Image = _cell_table_image(data, map_w, map_h)
			if image == null:
				world.weather_table_valid = false
				world.weather_table_cur = -1
				report.weather_table_reason = "layer_payload_mismatch"
				report.weather_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
				return report
			tex.update_layer(image, layer_ids[i])
	else:
		# ── 整张重建：4 层 Image 按层号排好，一次 create_from_images ─────────────
		if not bool(plan.get("rebuild", false)):
			# 增量计划但形状不对 ⇒ 提级成重建（首次 / 换图 / 上次失败 / 无 update_layer）。
			plan = weather_table_commit_plan(weather_bytes, wind_bytes, o2i,
				map_w, map_h, n_cells, -1)
			if not bool(plan.get("ok", false)):
				world.weather_table_valid = false
				world.weather_table_cur = -1
				report.weather_table_reason = String(plan.get("reason", "plan_failed"))
				report.weather_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
				return report
			layer_ids = plan.get("layer_ids", PackedInt32Array())
			layer_bytes = plan.get("layer_bytes", [])
		var images: Array[Image] = []
		images.resize(WEATHER_TABLE_LAYERS)
		for i in range(layer_ids.size()):
			var image2: Image = _cell_table_image(layer_bytes[i], map_w, map_h)
			if image2 == null:
				world.weather_table_valid = false
				world.weather_table_cur = -1
				report.weather_table_reason = "layer_payload_mismatch"
				report.weather_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
				return report
			images[layer_ids[i]] = image2
		for li in range(WEATHER_TABLE_LAYERS):
			if images[li] == null:
				# 层号缺一个就建不起来（Texture2DArray 必须每层同尺寸同格式）。
				world.weather_table_valid = false
				world.weather_table_cur = -1
				report.weather_table_reason = "layer_missing"
				report.weather_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
				return report
		var rebuilt: Texture2DArray = _create_weather_table_array(images)
		if rebuilt == null:
			world.weather_table_valid = false
			world.weather_table_cur = -1
			report.weather_table_reason = "create_failed"
			report.weather_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
			return report
		world.weather_table_tex = rebuilt
		report.weather_table_rebuilt = true

	world.weather_table_dims = dims
	world.weather_table_cur = int(plan.get("next_cur", -1))
	world.weather_table_valid = true
	report.weather_table_published = true
	report.weather_table_cur = int(world.weather_table_cur)
	report.weather_table_reason = "rebuilt" if bool(report.weather_table_rebuilt) else "flipped"
	report.weather_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	return report


## 四层同尺寸 RGBA8 Image → Texture2DArray（照 `_create_cell_table_array` 的建法：
## 层数不符 / create 失败一律 push_error + null，由调用方把 weather_table_valid 置 false）。
## 层数恒为 WEATHER_TABLE_LAYERS(4)：层号是双缓冲的唯一载体，层数随数据变化会让
## `weather_cur_layer` 的语义在运行期抖动。
static func _create_weather_table_array(images: Array[Image]) -> Texture2DArray:
	if images.size() != WEATHER_TABLE_LAYERS:
		push_error("[weather-table] weather_table needs %d layers, got %d"
			% [WEATHER_TABLE_LAYERS, images.size()])
		return null
	var array := Texture2DArray.new()
	var err := array.create_from_images(images)
	if err != OK:
		push_error("[weather-table] weather_table_tex create_from_images failed: %s"
			% error_string(err))
		return null
	return array


## 四层同尺寸 RGBA8 Image → Texture2DArray（镜像 surface_baker.gd::_create_surface_array
## 的建法：层数不符 / create 失败一律 push_error + null，由调用方把 cell_table_bound 置 false）。
## [cell-field-web 2026-11-18] 层数固定 = CellTableCodecScript.LAYER_COUNT（4，含 layer3
## class_by_index）。index 空间装不下时第 4 层是整层 FILL_BYTE 占位，层数仍然必须是 4——
## 层数一旦随数据变化，shader 的 cell_table_size / 层数判定就会每天抖动。
static func _create_cell_table_array(images: Array[Image]) -> Texture2DArray:
	var layer_count: int = CellTableCodecScript.LAYER_COUNT
	if images.size() != layer_count:
		push_error("[cell-table] cell_table needs %d layers, got %d"
			% [layer_count, images.size()])
		return null
	var array := Texture2DArray.new()
	var err := array.create_from_images(images)
	if err != OK:
		push_error("[cell-table] cell_table_tex create_from_images failed: %s" % error_string(err))
		return null
	return array



static func _lut_tex_from_data(baker: MapBaker, data: PackedByteArray, w: int, h: int, fmt: int, existing: ImageTexture) -> ImageTexture:
	var img := Image.create_from_data(w, h, false, fmt, data)
	if existing != null and existing.get_size() == Vector2(float(w), float(h)):
		existing.update(img)
		return existing
	return ImageTexture.create_from_image(img)



static func _publish_weather_lut_bytes(baker: MapBaker, data: PackedByteArray, world: WorldData, lw: int, lh: int, force_changed: bool = false) -> Dictionary:

	var report: Dictionary = {
		"weather_lut_published": false,
		"weather_lut_changed": false,
		"weather_lut_reason": "",
	}
	if world == null or data.is_empty() or lw <= 0 or lh <= 0:
		report.weather_lut_reason = "invalid_weather_lut_args"
		return report
	flush_staged_cell_lut_upload(baker, world)
	var has_current_tex: bool = world.weather_lut_tex != null and world.weather_lut_tex.get_size() == Vector2(float(lw), float(lh))
	var changed: bool = (not has_current_tex) or baker._prev_weather_lut_bytes.size() != data.size() or baker._prev_weather_lut_bytes != data
	if not changed:
		report.weather_lut_reason = "unchanged"
		return report
	var prev_bytes: PackedByteArray = baker._prev_weather_lut_bytes if baker._prev_weather_lut_bytes.size() == data.size() and baker._prev_weather_lut_bytes.size() > 0 else data
	_upload_weather_lut_pair(baker, world, lw, lh, prev_bytes, data)
	report.weather_lut_published = true
	report.weather_lut_changed = true
	report.weather_lut_reason = "changed"
	# [cell-field-overlays 2026-11-18] weather_table **就地**跟在 weather_lut 后面发布：
	# 这是同一个提交点（weather_lut 真的换字节的那一次），不新建节拍 —— 与 cell_table
	# 紧跟三张 LUT 的关系完全对称（上面三行 weather_lut 的字节与时机一行没改）。
	# 风场字节从**同一个提交点**的上游取：weather_wind_source.build_bytes() 就是
	# cloud_shadow_field 的 wind_lut 编码器，同一次提交一起重排写入 layer2/3。
	report.merge(_publish_weather_table_from_luts(baker, world, data, lw, lh), true)
	return report


## 天气提交点 → weather_table 的一步接线：取 map（发布器里没有 map 入参，用 bake 时留的
## 引用）+ 风场字节，然后交给 _publish_weather_table。
##
## 为什么 map 取 `baker._last_bake_map`：`_publish_weather_lut_bytes` 的三个入口里只有
## `refresh_weather_lut_from_weather` 拿得到 map（native / 切片入口都只有 world），
## 而 map 实例在整个会话里就是 bake_world 的那一个（`map_baker.gd:706` 写入），
## 所以这是一个已有引用、不是新增数据源。
static func _publish_weather_table_from_luts(baker: MapBaker, world: WorldData,
		weather_bytes: PackedByteArray, lw: int, lh: int) -> Dictionary:
	var map: MapData = baker._last_bake_map
	if map == null:
		# 没有 map 就重建不出 offset_to_index：明确报不可用，shader 退回旧 LUT 路径。
		if world != null and world.weather_table_tex != null:
			world.weather_table_valid = false
			world.weather_table_cur = -1
		return {
			"weather_table_published": false,
			"weather_table_reason": "missing_map",
		}
	var wind_bytes: PackedByteArray = WeatherWindSourceScript.build_bytes(map, Vector2i(lw, lh))
	return _publish_weather_table(baker, map, world, weather_bytes, wind_bytes)


static func _upload_weather_lut_pair(baker: MapBaker, world: WorldData, lw: int, lh: int,
		previous: PackedByteArray, current: PackedByteArray) -> void:
	world.weather_lut_prev_tex = baker._lut_tex_from_data(
			previous, lw, lh, Image.FORMAT_RGBA8, world.weather_lut_prev_tex)
	world.weather_lut_tex = baker._lut_tex_from_data(
			current, lw, lh, Image.FORMAT_RGBA8, world.weather_lut_tex)
	baker._prev_weather_lut_bytes = current
	world.weather_lut_update_usec = Time.get_ticks_usec()



static func publish_weather_lut_bytes_from_native(baker: MapBaker, data: PackedByteArray, world: WorldData, force_changed: bool = false) -> Dictionary:
	var report: Dictionary = {
		"path": "weather_lut_native_upload",
		"fallback": false,
		"reason": "",
		"elapsed_ms": 0.0,
		"weather_lut_published": false,
		"weather_lut_changed": false,
	}
	var t0: int = Time.get_ticks_usec()
	if world == null or data.is_empty():
		report.fallback = true
		report.reason = "missing_world_or_data"
		return report
	var lw: int = world.lut_dims.x
	var lh: int = world.lut_dims.y
	if lw <= 0 or lh <= 0 or data.size() != lw * lh * 4:
		report.fallback = true
		report.reason = "invalid_lut_dims_or_size"
		return report
	baker._weather_lut_bytes_cache = data.duplicate()
	report.merge(baker._publish_weather_lut_bytes(data, world, lw, lh, force_changed), true)
	report.elapsed_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	return report



static func refresh_weather_lut_from_weather(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:

	var report: Dictionary = {
		"path": "weather_lut_upload",
		"fallback": false,
		"reason": "",
		"elapsed_ms": 0.0,
		"weather_lut_published": false,
		"weather_lut_changed": false,
		"weather_lut_dirty_count": 0,
		"weather_lut_full_rebuild": false,
	}
	var t0: int = Time.get_ticks_usec()
	if map == null or world == null:
		report.fallback = true
		report.reason = "missing_map_or_world"
		return report
	if world.lut_dims.x <= 0 or world.lut_dims.y <= 0:
		baker._ensure_cell_lut_dims(map, world)
	var lw: int = world.lut_dims.x
	var lh: int = world.lut_dims.y
	if lw <= 0 or lh <= 0:
		report.fallback = true
		report.reason = "invalid_lut_dims"
		return report
	var n_cells: int = map.cell_count()
	var slots: int = lw * lh
	if n_cells <= 0 or slots < n_cells:
		report.fallback = true
		report.reason = "invalid_cell_count_or_slots"
		return report
	var total_bytes: int = slots * 4
	var full_rebuild: bool = baker._weather_lut_bytes_cache.size() != total_bytes
	if full_rebuild:
		baker._weather_lut_bytes_cache = PackedByteArray()
		baker._weather_lut_bytes_cache.resize(total_bytes)
	report.weather_lut_full_rebuild = full_rebuild
	var type_arr: PackedByteArray = map.weather_type_arr
	var intensity_arr: PackedFloat32Array = map.weather_intensity_arr
	var cloud_arr: PackedFloat32Array = map.weather_cloud_arr
	var vapor_arr: PackedFloat32Array = map.weather_vapor_arr
	var dirty_mask: PackedByteArray = map.weather_dirty_mask
	var has_soa: bool = type_arr.size() >= n_cells and intensity_arr.size() >= n_cells \
			and cloud_arr.size() >= n_cells and vapor_arr.size() >= n_cells
	if not has_soa:
		full_rebuild = true
		report.weather_lut_full_rebuild = true
	var changed: bool = full_rebuild
	var dirty_count: int = 0
	if has_soa:
		for ci in range(n_cells):
			if not full_rebuild and (dirty_mask.size() < n_cells or int(dirty_mask[ci]) == 0):
				continue
			dirty_count += 1
			var w4: int = ci * 4
			var b0: int = int(type_arr[ci]) & 0xFF
			var b1: int = baker._q01_byte(float(intensity_arr[ci]))
			var b2: int = baker._q01_byte(float(cloud_arr[ci]))
			var b3: int = baker._q01_byte(float(vapor_arr[ci]))
			if baker._weather_lut_bytes_cache[w4] != b0 or baker._weather_lut_bytes_cache[w4 + 1] != b1 \
					or baker._weather_lut_bytes_cache[w4 + 2] != b2 or baker._weather_lut_bytes_cache[w4 + 3] != b3:
				changed = true
				baker._weather_lut_bytes_cache[w4] = b0
				baker._weather_lut_bytes_cache[w4 + 1] = b1
				baker._weather_lut_bytes_cache[w4 + 2] = b2
				baker._weather_lut_bytes_cache[w4 + 3] = b3
	else:
		for cell in map.all_cells():
			if cell == null:
				continue
			var ci: int = int(cell.index)
			if ci < 0 or ci >= slots:
				continue
			dirty_count += 1
			var w4: int = ci * 4
			baker._weather_lut_bytes_cache[w4] = int(cell.weather_type) & 0xFF
			baker._weather_lut_bytes_cache[w4 + 1] = baker._q01_byte(float(cell.weather_intensity))
			baker._weather_lut_bytes_cache[w4 + 2] = baker._q01_byte(float(cell.weather_cloud))
			baker._weather_lut_bytes_cache[w4 + 3] = baker._q01_byte(float(cell.weather_vapor))
	report.weather_lut_dirty_count = dirty_count
	if not changed:
		report.weather_lut_reason = "unchanged_dirty_subset"
		report.elapsed_ms = float(Time.get_ticks_usec() - t0) / 1000.0
		return report
	report.merge(baker._publish_weather_lut_bytes(baker._weather_lut_bytes_cache, world, lw, lh, true), true)

	report.elapsed_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	return report



# daily LUT 全量刷新：cell 视觉状态每日变化（enum 翻面 / temp / snow / vitality 等），
# per-cell LUT（n_cells ~2400）全量重烘 ~0.1-0.3ms，远小于旧 per-pixel fan-out。
# 由 DynamicVisualAtlasUploadSystem 每 stride 起点调用（仅 flag 开启时）；weather_lut 已并入
# weather_refresh commit path 同步生成并发布，避免不同 cadence 重置 weather_lerp。


static func refresh_cell_luts_daily(baker: MapBaker, map: MapData, world: WorldData,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = true,
		publish_weather_lut: bool = false, defer_upload: bool = false) -> Dictionary:
	if world == null or world.lut_dims.x <= 0 or world.lut_dims.y <= 0:
		return {"path": "none", "fallback": true, "reason": "missing_world_or_lut_dims"}
	# cache_valid=true：C++ encode_cell_luts 按 prev 推进 eco transition_age（每日衰减）。
	if defer_upload:
		return bake_cell_luts(baker, map, world, true, publish_weather_lut,
				dirty_indices, force_full_encode, true)
	return baker.bake_cell_luts(map, world, true, publish_weather_lut, dirty_indices, force_full_encode)



static func cell_lut_active_transition_pending(baker: MapBaker) -> bool:
	return baker._cell_lut_active_transition_count > 0



# Systemic Ocean Currents：独立 R8 upwelling 纹理编码（L8 单通道，LINEAR 过滤）。
# 源 buffer 编码：0 = 下沉满 / 128 = 中性 / 255 = 上升满。
# shader 端只在 ocean_current_debug 开启时采样，主路径不读。
