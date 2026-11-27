extends RefCounted
class_name DCCellLutBaker

const CellTableUpload = preload("res://scripts/rendering/bakers/cell_table_upload.gd")
const CellBounceLut = preload("res://scripts/rendering/bakers/cell_bounce_lut_baker.gd")

const RiverAtlasProbe = preload("res://scripts/rendering/bakers/river_atlas_probe.gd")
const WeatherTablePlan = preload("res://scripts/rendering/bakers/weather_table_plan.gd")

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
const PK_LAKE_DEPTH_NORM = CellTableUpload.PK_LAKE_DEPTH_NORM

const WEATHER_TABLE_LAYER_WEATHER_A := WeatherTablePlan.WEATHER_TABLE_LAYER_WEATHER_A
const WEATHER_TABLE_LAYER_WEATHER_B := WeatherTablePlan.WEATHER_TABLE_LAYER_WEATHER_B
const WEATHER_TABLE_LAYER_WIND_A := WeatherTablePlan.WEATHER_TABLE_LAYER_WIND_A
const WEATHER_TABLE_LAYER_WIND_B := WeatherTablePlan.WEATHER_TABLE_LAYER_WIND_B
const WEATHER_TABLE_LAYERS = CellTableUpload.WEATHER_TABLE_LAYERS
const WEATHER_TABLE_LAYER_WIND_BASE := WeatherTablePlan.WEATHER_TABLE_LAYER_WIND_BASE
const WEATHER_TABLE_PAD_TYPE := WeatherTablePlan.WEATHER_TABLE_PAD_TYPE
const WEATHER_CURTAIN_LUT_PAIR := &"weather_curtain_lut_pair"





static func _ensure_cell_lut_dims(baker: MapBaker, map: MapData, world: WorldData) -> void:
	CellBounceLut._ensure_cell_lut_dims(baker, map, world)

static func _publish_bounce_lut(baker: MapBaker, enum_data: PackedByteArray, dyn_data: PackedByteArray,
		world: WorldData, lw: int, lh: int,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full: bool = true) -> bool:
	return CellBounceLut._publish_bounce_lut(baker, enum_data, dyn_data, world, lw, lh, dirty_indices, force_full)

static func _publish_bounce_lut_gd(baker: MapBaker, enum_data: PackedByteArray, dyn_data: PackedByteArray,
		world: WorldData, lw: int, lh: int,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full: bool = true) -> bool:
	return CellBounceLut._publish_bounce_lut_gd(baker, enum_data, dyn_data, world, lw, lh, dirty_indices, force_full)


static func set_river_atlas_probe_enabled(baker: MapBaker, enabled: bool, map: MapData = null) -> Dictionary:
	return RiverAtlasProbe.set_river_atlas_probe_enabled(baker, enabled, map)



static func get_river_atlas_probe_state(baker: MapBaker) -> Dictionary:
	return RiverAtlasProbe.get_river_atlas_probe_state(baker)



static func set_river_atlas_probe_context(baker: MapBaker, context: Dictionary) -> void:
	RiverAtlasProbe.set_river_atlas_probe_context(baker, context)



static func dump_river_atlas_probe(baker: MapBaker) -> Dictionary:
	return RiverAtlasProbe.dump_river_atlas_probe(baker)



static func _csv_escape(baker: MapBaker, value: String) -> String:
	return '"%s"' % value.replace('"', '""')



static func _ensure_river_atlas_probe_cells(baker: MapBaker, map: MapData) -> void:
	RiverAtlasProbe._ensure_river_atlas_probe_cells(baker, map)



static func _record_river_atlas_probe(baker: MapBaker, map: MapData, out: Dictionary, dyn_data: PackedByteArray,
		eco_data: PackedByteArray) -> void:
	RiverAtlasProbe._record_river_atlas_probe(baker, map, out, dyn_data, eco_data)



static func _probe_float(baker: MapBaker, values: PackedFloat32Array, idx: int) -> float:
	return RiverAtlasProbe._probe_float(baker, values, idx)



static func bake_cell_luts(baker: MapBaker, map: MapData, world: WorldData, cache_valid: bool = false,
		publish_weather_lut: bool = true,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = true, defer_upload: bool = false, runtime_commit: Dictionary = {}) -> Dictionary:
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
	var n_cells: int = map.cell_count()
	if lw <= 0 or lh <= 0 or n_cells <= 0 or lw * lh < n_cells:
		report.reason = "invalid_lut_dims"
		return report
	var frame = runtime_commit.get("cell_lut_frame", {})
	if runtime_commit.has("cell_lut_frame"):
		var ages = frame.get("transition_age") if frame is Dictionary else null
		var vitalities = frame.get("previous_vitality") if frame is Dictionary else null
		if not ages is PackedByteArray or not vitalities is PackedByteArray \
				or ages.size() != n_cells or vitalities.size() != n_cells:
			report.reason = "invalid_cell_lut_frame"
			push_warning("[cell-lut] Rejected worker publication: expected %d transition ages and previous vitalities" % n_cells)
			return report
	if not defer_upload:
		flush_staged_cell_lut_upload(baker, world)
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
		var options := {
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
		}
		if not frame.is_empty():
			options["cell_lut_frame"] = frame
		var out: Dictionary = baker._world_ext.encode_cell_luts(options)
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
				var full := bool(out.get("full_encode", force_full_encode))
				var classes: PackedInt32Array = runtime_commit.get("display_class_cells", dirty_indices)
				if defer_upload:
					_stage_cell_lut_upload(baker, world, e, d, c, wlut, dirty_indices, classes, full)
				else:
					_publish_cell_lut_textures(baker, world, e, d, c, report,
							dirty_indices, full, classes)
					if not wlut.is_empty():
						report.merge(baker._publish_weather_lut_bytes(wlut, world, lw, lh), true)
				report["lut_total_ms"] = float(Time.get_ticks_usec() - total_t0_us) / 1000.0
				return report
	# A legacy/fallback encode publishes immediately. Flush an earlier native
	# batch first so a newer synchronous update cannot be replaced by it.
	flush_staged_cell_lut_upload(baker, world)
	_bake_cell_luts_gd(baker, map, world, lw, lh, snow_cover_override,
		publish_weather_lut, fog_k_override, frame)

	report["lut_encode_path"] = "gdscript"
	report["path"] = "gdscript"
	report["fallback"] = true
	return report


static func _publish_cell_lut_textures(baker: MapBaker, world: WorldData,
		e: PackedByteArray, d: PackedByteArray, c: PackedByteArray, report: Dictionary,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = true,
		class_indices: PackedInt32Array = PackedInt32Array()) -> void:
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
		world.fog_texture_revision += 1
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
	# 那一个实例（天气表也用该引用）；null 时
	# _publish_cell_table 自己会把 bound/layers 归零。
	# [vision-dirty-aux] 视野脏格必须并进 class_indices：cell_table 的 aux 层
	# （layer2.R = 雾 k，PW_CELL_FIELD 路径唯一的 k 来源）只按 class_indices 重建。
	# 只填 dirty_indices 时 `_cell_table_static_words()` 的循环是 `indices.size()`=0 次，
	# aux 永远停在初始 255 —— 雾层在 draw list 里、k 读出来却全是"可见"（雾画不出来）。
	# 并集只覆盖真正变化的格，不需要 force_full_encode 的全量重编。
	var table_static_cells := class_indices
	if not dirty_indices.is_empty():
		table_static_cells = class_indices.duplicate()
		table_static_cells.append_array(dirty_indices)
	report.merge(_publish_cell_table(baker, baker._last_bake_map, world, e, d,
		enum_changed or not table_static_cells.is_empty(), dyn_changed,
		table_static_cells, force_full_encode or enum_changed), true)
	var bounce_t0_us := Time.get_ticks_usec()
	report["bounce_lut_published"] = false
	if enum_changed or dyn_changed or world.bounce_lut_tex == null:
		report["bounce_lut_published"] = baker._publish_bounce_lut(
			e, d, world, lw, lh, dirty_indices, force_full_encode)
	report["bounce_lut_ms"] = float(Time.get_ticks_usec() - bounce_t0_us) / 1000.0

static func _stage_cell_lut_upload(baker: MapBaker, world: WorldData,
		enum_bytes: PackedByteArray, dyn_bytes: PackedByteArray, eco_bytes: PackedByteArray,
		weather_bytes: PackedByteArray, dirty: PackedInt32Array,
		classes: PackedInt32Array, full: bool) -> void:
	var pending := world.staged_cell_lut_upload
	pending["full_encode"] = full or bool(pending.get("full_encode", false))
	if not pending.full_encode:
		pending["dirty"] = _merge_staged_cells(pending.get("dirty", PackedInt32Array()), dirty)
		pending["classes"] = _merge_staged_cells(pending.get("classes", PackedInt32Array()), classes)
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


static func _merge_staged_cells(previous: PackedInt32Array, current: PackedInt32Array) -> PackedInt32Array:
	if previous.is_empty():
		return current
	if current.is_empty():
		return previous
	var cells := {}
	for cell in previous:
		cells[cell] = true
	for cell in current:
		cells[cell] = true
	return PackedInt32Array(cells.keys())


static func flush_staged_cell_lut_upload(baker: MapBaker, world: WorldData) -> void:
	if world == null or world.staged_cell_lut_upload.is_empty():
		return
	var pending := world.staged_cell_lut_upload
	world.staged_cell_lut_upload = {}
	_publish_cell_lut_textures(baker, world, pending["enum_bytes"],
			pending["dyn_bytes"], pending["eco_bytes"], {}, pending.get("dirty", PackedInt32Array()),
			pending.full_encode, pending.get("classes", PackedInt32Array()))
	if pending.has("weather_current"):
		_upload_weather_lut_pair(baker, world, world.lut_dims.x, world.lut_dims.y,
				pending["weather_previous"], pending["weather_current"])


# GDScript fallback：per-cell LUT 全量烘焙（C++ encode_cell_luts 不可用时）。

static func _bake_cell_luts_gd(baker: MapBaker, map: MapData, world: WorldData, lw: int, lh: int,
		snow_cover_override: PackedFloat32Array = PackedFloat32Array(),
		publish_weather_lut: bool = true,
		fog_k_override: PackedByteArray = PackedByteArray(), cell_lut_frame: Dictionary = {}) -> void:
	var slots: int = lw * lh
	var transition_ages: PackedByteArray = cell_lut_frame.get("transition_age", PackedByteArray())
	var previous_vitalities: PackedByteArray = cell_lut_frame.get("previous_vitality", PackedByteArray())
	var has_transition := not cell_lut_frame.is_empty()
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
		var age := transition_ages[ci] if has_transition else 0
		var previous_vit := previous_vitalities[ci] if has_transition else cur_vit_byte
		var esig: int = baker._ecology_visual_signature(cell, age, previous_vit, snow_override)
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
	world.fog_texture_revision += 1
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
	return CellTableUpload.cell_table_layer_target(n_cells, map_w, map_h)

static func _publish_cell_table(baker: MapBaker, map: MapData, world: WorldData,
		enum_bytes: PackedByteArray, dyn_bytes: PackedByteArray,
		static_changed: bool = true, state_changed: bool = true,
		class_indices: PackedInt32Array = PackedInt32Array(), full_classes: bool = true) -> Dictionary:
	return CellTableUpload._publish_cell_table(baker, map, world, enum_bytes, dyn_bytes, static_changed, state_changed, class_indices, full_classes)

static func _cell_index_table_bytes(source: PackedByteArray, n_cells: int,
		map_w: int, map_h: int) -> PackedByteArray:
	return CellTableUpload._cell_index_table_bytes(source, n_cells, map_w, map_h)

static func cell_table_images_valid(images: Array, required: Array) -> bool:
	return CellTableUpload.cell_table_images_valid(images, required)

static func _cell_table_static_words(map: MapData, world: WorldData, enums: PackedByteArray,
		classes: PackedInt32Array, aux: PackedInt32Array,
		indices: PackedInt32Array, full: bool) -> Array[PackedInt32Array]:
	return CellTableUpload._cell_table_static_words(map, world, enums, classes, aux, indices, full)

static func _cell_words_to_offset(words: PackedInt32Array, layout: Dictionary) -> PackedInt32Array:
	return CellTableUpload._cell_words_to_offset(words, layout)

static func _cell_table_image(data: PackedByteArray, w: int, h: int) -> Image:
	return CellTableUpload._cell_table_image(data, w, h)

static func _cell_offset_layout(baker: MapBaker, map: MapData, map_w: int, map_h: int) -> Dictionary:
	return CellTableUpload._cell_offset_layout(baker, map, map_w, map_h)

static func _build_offset_to_index(map: MapData, map_w: int, map_h: int) -> PackedInt32Array:
	return CellTableUpload._build_offset_to_index(map, map_w, map_h)

static func weather_table_commit_plan(weather_src: PackedByteArray, wind_src: PackedByteArray,
		o2i: PackedInt32Array, map_w: int, map_h: int, n_cells: int,
		cur_before: int, identity: bool = false) -> Dictionary:
	return CellTableUpload.weather_table_commit_plan(weather_src, wind_src, o2i, map_w, map_h, n_cells, cur_before, identity)

static func _publish_weather_table(baker: MapBaker, map: MapData, world: WorldData,
		weather_bytes: PackedByteArray, wind_bytes: PackedByteArray) -> Dictionary:
	return CellTableUpload._publish_weather_table(baker, map, world, weather_bytes, wind_bytes)

static func _create_weather_table_array(images: Array[Image]) -> Texture2DArray:
	return CellTableUpload._create_weather_table_array(images)

static func _create_cell_table_array(images: Array[Image]) -> Texture2DArray:
	return CellTableUpload._create_cell_table_array(images)


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
	report.weather_lut_published = true
	report.weather_lut_changed = true
	report.weather_lut_reason = "changed"
	report.merge(_upload_weather_lut_pair(baker, world, lw, lh, prev_bytes, data), true)
	return report


# Immediate and staged uploads share this publication boundary.
static func _upload_weather_lut_pair(baker: MapBaker, world: WorldData, lw: int, lh: int,
		previous: PackedByteArray, current: PackedByteArray) -> Dictionary:
	world.weather_lut_prev_tex = baker._lut_tex_from_data(
			previous, lw, lh, Image.FORMAT_RGBA8, world.weather_lut_prev_tex)
	world.weather_lut_tex = baker._lut_tex_from_data(
			current, lw, lh, Image.FORMAT_RGBA8, world.weather_lut_tex)
	# Keep the exact bytes used by the rain/snow meshes available without a GPU readback.
	world.weather_lut_tex.set_meta(WEATHER_CURTAIN_LUT_PAIR, [previous, current])
	baker._prev_weather_lut_bytes = current
	var stamp := maxi(Time.get_ticks_usec(), world.weather_lut_update_usec + 1)
	var map: MapData = baker._last_bake_map
	var dims := Vector2i(lw, lh)
	var wind_bytes := WeatherWindSourceScript.build_bytes(map, dims)
	var report := _publish_weather_table(baker, map, world, current, wind_bytes)
	# Expose the new timestamp after the table and index-ordered wind are ready.
	world.publish_weather_wind(map, dims, stamp, wind_bytes)
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
		publish_weather_lut: bool = false, defer_upload: bool = false,
		runtime_commit: Dictionary = {}) -> Dictionary:
	if world == null or world.lut_dims.x <= 0 or world.lut_dims.y <= 0:
		return {"path": "none", "fallback": true, "reason": "missing_world_or_lut_dims"}
	# cache_valid=true：C++ encode_cell_luts 按 prev 推进 eco transition_age（每日衰减）。
	if defer_upload or not runtime_commit.is_empty():
		return bake_cell_luts(baker, map, world, true, publish_weather_lut,
				dirty_indices, force_full_encode, defer_upload, runtime_commit)
	return baker.bake_cell_luts(map, world, true, publish_weather_lut, dirty_indices, force_full_encode)



static func cell_lut_active_transition_pending(baker: MapBaker) -> bool:
	return baker._cell_lut_active_transition_count > 0



# Systemic Ocean Currents：独立 R8 upwelling 纹理编码（L8 单通道，LINEAR 过滤）。
# 源 buffer 编码：0 = 下沉满 / 128 = 中性 / 255 = 上升满。
# shader 端只在 ocean_current_debug 开启时采样，主路径不读。
