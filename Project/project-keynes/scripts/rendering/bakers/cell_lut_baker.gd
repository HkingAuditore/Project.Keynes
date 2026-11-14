extends RefCounted
class_name DCCellLutBaker





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

static func _publish_bounce_lut(baker: MapBaker, enum_data: PackedByteArray, dyn_data: PackedByteArray,
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
		force_full_encode: bool = true) -> Dictionary:
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
				report["dirty_cells"] = n_cells \
						if bool(out.get("full_encode", force_full_encode)) \
						else dirty_indices.size()
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
				var bounce_t0_us := Time.get_ticks_usec()
				report["bounce_lut_published"] = false
				if enum_changed or dyn_changed or world.bounce_lut_tex == null:
					report["bounce_lut_published"] = baker._publish_bounce_lut(
						e, d, world, lw, lh, dirty_indices, force_full_encode)
				report["bounce_lut_ms"] = float(Time.get_ticks_usec() - bounce_t0_us) / 1000.0
				# weather LUT 发布已从动态视觉 LUT 日刷中解耦；初次 bake 或 weather_refresh commit 才更新时间戳。

				var wlut = out.get("weather_lut", null)
				if publish_weather_lut and wlut is PackedByteArray:
					var wx_report: Dictionary = baker._publish_weather_lut_bytes(wlut, world, lw, lh)
					report.merge(wx_report, true)
				report["lut_total_ms"] = float(Time.get_ticks_usec() - total_t0_us) / 1000.0
				return report
	baker._bake_cell_luts_gd(map, world, lw, lh, snow_cover_override, publish_weather_lut, fog_k_override)

	report["lut_encode_path"] = "gdscript"
	report["path"] = "gdscript"
	report["fallback"] = true
	return report


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
	baker._publish_bounce_lut(enum_data, dyn_data, world, lw, lh)
	if publish_weather_lut:
		baker._publish_weather_lut_bytes(weather_data, world, lw, lh)



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
	var has_current_tex: bool = world.weather_lut_tex != null and world.weather_lut_tex.get_size() == Vector2(float(lw), float(lh))
	var changed: bool = (not has_current_tex) or baker._prev_weather_lut_bytes.size() != data.size() or baker._prev_weather_lut_bytes != data
	if not changed:
		report.weather_lut_reason = "unchanged"
		return report
	var prev_bytes: PackedByteArray = baker._prev_weather_lut_bytes if baker._prev_weather_lut_bytes.size() == data.size() and baker._prev_weather_lut_bytes.size() > 0 else data
	world.weather_lut_prev_tex = baker._lut_tex_from_data(prev_bytes, lw, lh, Image.FORMAT_RGBA8, world.weather_lut_prev_tex)
	world.weather_lut_tex = baker._lut_tex_from_data(data, lw, lh, Image.FORMAT_RGBA8, world.weather_lut_tex)
	baker._prev_weather_lut_bytes = data.duplicate()
	world.weather_lut_update_usec = Time.get_ticks_usec()
	report.weather_lut_published = true
	report.weather_lut_changed = true
	report.weather_lut_reason = "changed"
	return report



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
		publish_weather_lut: bool = false) -> Dictionary:
	if world == null or world.lut_dims.x <= 0 or world.lut_dims.y <= 0:
		return {"path": "none", "fallback": true, "reason": "missing_world_or_lut_dims"}
	# cache_valid=true：C++ encode_cell_luts 按 prev 推进 eco transition_age（每日衰减）。
	return baker.bake_cell_luts(map, world, true, publish_weather_lut, dirty_indices, force_full_encode)



static func cell_lut_active_transition_pending(baker: MapBaker) -> bool:
	return baker._cell_lut_active_transition_count > 0



# Systemic Ocean Currents：独立 R8 upwelling 纹理编码（L8 单通道，LINEAR 过滤）。
# 源 buffer 编码：0 = 下沉满 / 128 = 中性 / 255 = 上升满。
# shader 端只在 ocean_current_debug 开启时采样，主路径不读。
