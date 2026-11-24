extends RefCounted
class_name DCCellLutBaker

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
const PK_LAKE_DEPTH_NORM := 0.16

const WEATHER_TABLE_LAYER_WEATHER_A := WeatherTablePlan.WEATHER_TABLE_LAYER_WEATHER_A
const WEATHER_TABLE_LAYER_WEATHER_B := WeatherTablePlan.WEATHER_TABLE_LAYER_WEATHER_B
const WEATHER_TABLE_LAYER_WIND_A := WeatherTablePlan.WEATHER_TABLE_LAYER_WIND_A
const WEATHER_TABLE_LAYER_WIND_B := WeatherTablePlan.WEATHER_TABLE_LAYER_WIND_B
const WEATHER_TABLE_LAYERS := WeatherTablePlan.WEATHER_TABLE_LAYERS
const WEATHER_TABLE_LAYER_WIND_BASE := WeatherTablePlan.WEATHER_TABLE_LAYER_WIND_BASE
const WEATHER_TABLE_PAD_TYPE := WeatherTablePlan.WEATHER_TABLE_PAD_TYPE
const WEATHER_CURTAIN_LUT_PAIR := &"weather_curtain_lut_pair"





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
			"runtime_frame": runtime_commit.has("display_dirty_cells"),
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
	baker._bake_cell_luts_gd(map, world, lw, lh, snow_cover_override, publish_weather_lut, fog_k_override)

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
	# 那一个实例（与 _publish_weather_table_from_luts 同一先例）；null 时
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
		_publish_weather_table_from_luts(baker, world, pending["weather_current"],
			world.lut_dims.x, world.lut_dims.y)


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
	if CellTableCodecScript.index_space_fits(n_cells, map_w, map_h):
		return CellTableCodecScript.LAYER_COUNT
	push_warning("[cell-table] layer3 class_by_index needs %d <= %d x %d texels; publishing %d layers"
		% [n_cells, map_w, map_h, CellTableCodecScript.LAYER_CLASS_BY_INDEX])
	return CellTableCodecScript.LAYER_CLASS_BY_INDEX


# ─── [cell-field 2026-11-18] cell_table：per-cell 属性表（Texture2DArray，offset 空间）───────
# 契约：docs/plans/terrain-cell-field-contract.md §3（层布局，offset 空间）/ §5.3（发布）。
# 方案：docs/plans/terrain-hex-mesh-implementation-plan.md §3.4。
#
# 与旧 LUT 共用字节来源，另按 offset 空间发布。class 与 class_by_index
# 由同一份 RGBA 数据派生。超出 index 空间时，第 4 层是占位图。
static func _publish_cell_table(baker: MapBaker, map: MapData, world: WorldData,
		enum_bytes: PackedByteArray, dyn_bytes: PackedByteArray,
		static_changed: bool = true, state_changed: bool = true,
		class_indices: PackedInt32Array = PackedInt32Array(), full_classes: bool = true) -> Dictionary:
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

	var t0_us := Time.get_ticks_usec()
	var dims := Vector2i(map_w, map_h)
	var layout := _cell_offset_layout(baker, map, map_w, map_h)
	var cache := baker._cell_table_source_cache
	var tex: Texture2DArray = world.cell_table_tex
	var need_all: bool = tex == null or not world.cell_table_bound or world.cell_table_dims != dims \
			or tex.get_layers() != CellTableCodecScript.LAYER_COUNT \
			or tex.get_width() != map_w or tex.get_height() != map_h \
			or cache.get("texture") != tex or cache.get("layout") != layout
	if not need_all and not static_changed and not state_changed:
		report.cell_table_reason = "unchanged"
		return report
	var previous_class: PackedInt32Array = cache.get("class", PackedInt32Array())
	var previous_aux: PackedInt32Array = cache.get("aux", PackedInt32Array())
	var previous_state: PackedByteArray = cache.get("state", PackedByteArray())
	var classes := previous_class
	var aux := previous_aux
	var state := previous_state
	var images: Array[Image] = [null, null, null, null]
	var required_images := [false, false, false, false]
	if need_all or static_changed:
		var packed := _cell_table_static_words(map, world, enum_bytes, classes, aux,
			class_indices, need_all or full_classes)
		classes = packed[0]
		aux = packed[1]
		if need_all or classes != previous_class:
			required_images[CellTableCodecScript.LAYER_CLASS] = true
			images[CellTableCodecScript.LAYER_CLASS] = _cell_table_image(
				_cell_words_to_offset(classes, layout).to_byte_array(), map_w, map_h)
			if index_space_ok:
				required_images[CellTableCodecScript.LAYER_CLASS_BY_INDEX] = true
				var by_index := _cell_index_table_bytes(
					classes.to_byte_array(), n_cells, map_w, map_h)
				images[CellTableCodecScript.LAYER_CLASS_BY_INDEX] = _cell_table_image(
					by_index, map_w, map_h)
			elif need_all:
				required_images[CellTableCodecScript.LAYER_CLASS_BY_INDEX] = true
				images[CellTableCodecScript.LAYER_CLASS_BY_INDEX] = _cell_table_image(
					CellTableCodecScript.index_space_fill_bytes(map_w, map_h), map_w, map_h)
		# [aux-upload-gate] 绑静态重建，不用「值相等」判断：值比较在缓存领先 GPU 时会
		# 永久判为「没变」，aux 就再也传不上去。静态重建一次多传一层 60×40 RGBA8（≈9.6 KB）。
		if need_all or static_changed:
			required_images[CellTableCodecScript.LAYER_AUX] = true
			images[CellTableCodecScript.LAYER_AUX] = _cell_table_image(
				_cell_words_to_offset(aux, layout).to_byte_array(), map_w, map_h)
	if need_all or state_changed:
		# A row-major map already has the same order as the source LUT.
		if layout.identity:
			state = dyn_bytes if dyn_bytes.size() == map_w * map_h * bytes_per_cell \
				else dyn_bytes.slice(0, map_w * map_h * bytes_per_cell)
		else:
			state = _cell_words_to_offset(dyn_bytes.to_int32_array(), layout).to_byte_array()
		if need_all or state != previous_state:
			required_images[CellTableCodecScript.LAYER_STATE] = true
			images[CellTableCodecScript.LAYER_STATE] = _cell_table_image(state, map_w, map_h)
	if need_all:
		required_images.fill(true)
	if not cell_table_images_valid(images, required_images):
		world.cell_table_bound = false
		world.cell_table_layers = 0
		report.cell_table_reason = "layer_payload_mismatch"
		report.cell_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return report

	if need_all:
		tex = _create_cell_table_array(images)
		if tex == null:
			world.cell_table_bound = false
			world.cell_table_layers = 0
			report.cell_table_reason = "create_failed"
			report.cell_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
			return report
		world.cell_table_tex = tex
		world.cell_table_dims = dims
		world.cell_table_bound = true
		world.cell_table_layers = published_layers

	var updated_layers := PackedStringArray()
	var names := ["class", "state", "aux", "class_by_index"]
	var uploaded := {"class": false, "state": false, "aux": false, "class_by_index": false}
	for layer in [CellTableCodecScript.LAYER_CLASS, CellTableCodecScript.LAYER_AUX,
			CellTableCodecScript.LAYER_CLASS_BY_INDEX, CellTableCodecScript.LAYER_STATE]:
		if images[layer] == null:
			continue
		if not need_all:
			# Godot accepts an entire layer Image. Unchanged layers never get here.
			tex.update_layer(images[layer], layer)
		# need_all 时 `_create_cell_table_array(images)` 已用这张图重建纹理，等价于已上传。
		uploaded[names[layer]] = true
		if layer < published_layers:
			updated_layers.append(names[layer])
	var aux_image := images[CellTableCodecScript.LAYER_AUX]
	if aux_image != null:
		world.fog_texture_revision += 1
		world.cell_table_fog_coverage_source = aux_image
		world.cell_table_fog_coverage = null
	if images[CellTableCodecScript.LAYER_CLASS] != null or aux_image != null:
		world.land_base_revision += 1
	# [aux-upload-gate] 缓存只能记**真正上传成功**的那一份。原来无条件写回算出来的 `aux`：
	# 一旦某次没建 image（`aux != previous_aux` 比的是「算过的值」）也就没上传，但缓存已经
	# 变成新值，之后每次都相等 ⇒ 永远不再上传，GPU 停在首帧 255。实测就是
	# `aux_cache.R=0 / aux@offset=255 / gpu_aux_zero=0/2400`，表现为「雾从来没画过」。
	# 改为按层 dirty：未上传的层沿用上次上传的字节，等值比较才真正等于「脏」。
	baker._cell_table_source_cache = {"texture": tex, "layout": layout,
		"class": classes if uploaded["class"] else previous_class,
		"aux": aux if uploaded["aux"] else previous_aux,
		"state": state if uploaded["state"] else previous_state}
	report.cell_table_published = not updated_layers.is_empty()
	report.cell_table_reason = "ok" if report.cell_table_published else "unchanged"
	report.cell_table_layers = ",".join(updated_layers)
	report.cell_table_layers_published = int(world.cell_table_layers)
	report.cell_table_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	return report


## A non-full index-space table has a zero-filled tail, but its source must still
## contain exactly one RGBA word per cell. Never let resize() conceal a short or
## oversized source payload.
static func _cell_index_table_bytes(source: PackedByteArray, n_cells: int,
		map_w: int, map_h: int) -> PackedByteArray:
	var want_source := n_cells * CellTableCodecScript.BYTES_PER_TEXEL
	var want_table := map_w * map_h * CellTableCodecScript.BYTES_PER_TEXEL
	if n_cells <= 0 or map_w <= 0 or map_h <= 0 or n_cells > map_w * map_h \
			or source.size() != want_source:
		return PackedByteArray()
	var output := PackedByteArray()
	output.resize(want_table)
	output.fill(CellTableCodecScript.FILL_BYTE)
	for i in source.size():
		output[i] = source[i]
	return output


## Null is allowed only for layers that this incremental commit does not update.
static func cell_table_images_valid(images: Array, required: Array) -> bool:
	if images.size() != CellTableCodecScript.LAYER_COUNT \
			or required.size() != CellTableCodecScript.LAYER_COUNT:
		return false
	for layer in CellTableCodecScript.LAYER_COUNT:
		if bool(required[layer]) and images[layer] == null:
			return false
	return true


static func _cell_table_static_words(map: MapData, world: WorldData, enums: PackedByteArray,
		classes: PackedInt32Array, aux: PackedInt32Array,
		indices: PackedInt32Array, full: bool) -> Array[PackedInt32Array]:
	var count := map.cell_count()
	full = full or classes.size() != count or aux.size() != count
	classes.resize(count)
	aux.resize(count)
	var landforms := map.landform_arr
	var sea_norm := maxf(world.sea_level, 1e-4)
	var words := enums.to_int32_array()
	for row in (count if full else indices.size()):
		var index := row if full else indices[row]
		var cell := map.cell_at(index)
		if cell == null:
			continue
		var landform := int(landforms[index]) if index < landforms.size() else int(cell.landform)
		var depth := 0
		if cell.water_depth > 1e-4:
			var norm := PK_LAKE_DEPTH_NORM if cell.terrain == TerrainType.TERRAIN.LAKE else sea_norm
			depth = CellTableCodecScript.q01_byte(maxf(cell.water_depth - cell.elevation, 0.0) / norm)
		var word := words[index]
		classes[index] = (word & 0x00ffffff) | (landform << 24)
		aux[index] = ((word >> 24) & 0xff) | (depth << 8)
	return [classes, aux]


static func _cell_words_to_offset(words: PackedInt32Array, layout: Dictionary) -> PackedInt32Array:
	if layout.identity:
		return words
	var offsets: PackedInt32Array = layout.offsets
	var reordered := PackedInt32Array()
	reordered.resize(offsets.size())
	for offset in offsets.size():
		var index := offsets[offset]
		if index >= 0 and index < words.size():
			reordered[offset] = words[index]
	return reordered


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
## Index order is fixed after generation. Share the lookup with weather and
## invalidate it on rebake, map replacement or a shape/count change.
static func _cell_offset_layout(baker: MapBaker, map: MapData, map_w: int, map_h: int) -> Dictionary:
	var key := [map, map_w, map_h, map.cell_count()]
	if map.has_indices() and baker._cell_offset_layout.get("key") == key:
		return baker._cell_offset_layout
	var offsets := _build_offset_to_index(map, map_w, map_h)
	var identity := offsets.size() == map.cell_count()
	if identity:
		for index in offsets.size():
			if offsets[index] != index:
				identity = false
				break
	var layout := {"key": key, "offsets": offsets, "identity": identity}
	if map.has_indices():
		baker._cell_offset_layout = layout
	return layout


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


static func weather_table_commit_plan(weather_src: PackedByteArray, wind_src: PackedByteArray,
		o2i: PackedInt32Array, map_w: int, map_h: int, n_cells: int,
		cur_before: int, identity: bool = false) -> Dictionary:
	return WeatherTablePlan.weather_table_commit_plan(weather_src, wind_src, o2i, map_w, map_h, n_cells, cur_before, identity)


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
	var layout := _cell_offset_layout(baker, map, map_w, map_h)
	var plan: Dictionary = weather_table_commit_plan(
		weather_bytes, wind_bytes, layout.offsets, map_w, map_h, n_cells,
		world.weather_table_cur, layout.identity)
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
			plan = weather_table_commit_plan(weather_bytes, wind_bytes, layout.offsets,
				map_w, map_h, n_cells, -1, layout.identity)
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
	# Keep the exact bytes used by the rain/snow meshes available without a GPU readback.
	world.weather_lut_tex.set_meta(WEATHER_CURTAIN_LUT_PAIR, [previous, current])
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
