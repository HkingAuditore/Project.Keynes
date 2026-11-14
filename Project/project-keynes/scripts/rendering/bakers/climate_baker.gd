extends RefCounted
class_name DCClimateBaker
## Climate atlas baking and incremental sea-ice uploads.
##
## The host owns mutable buffers and profiles; these static methods receive the
## host explicitly and keep the native/GDScript result handling unchanged.

const AtlasEncodersScript = preload("res://scripts/rendering/bakers/atlas_encoders.gd")

static func bake_sea_ice_fraction_only(baker: MapBaker, map: MapData, world: WorldData) -> void:
	# [sea-ice-atlas-skip 2026-06-16] flag 关（默认）→ 整条 prepare/upload no-op
	# （sea_ice_tex 已退役，无 shader 采样者，运行时 upload job 也不注册）。
	if not DCFeatureFlags.sea_ice_atlas_active():
		return
	var prep: Dictionary = baker.prepare_sea_ice_fraction_atlas(map, world)
	if bool(prep.get("prepared", false)) and bool(prep.get("dirty", true)):
		baker.upload_prepared_sea_ice_fraction_atlas(world)



static func prepare_sea_ice_fraction_atlas(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var out: Dictionary = {
		"prepared": false,
		"dirty": false,
		"prepare_ms": 0.0,
		"path": "none",
		"dirty_cells": 0,
		"dirty_ratio": 0.0,
	}
	# [sea-ice-atlas-skip 2026-06-16] flag 关（默认）→ 直接返回 not-prepared，
	# 调用方据此不会 enqueue upload。sea_ice_tex 已退役（无 shader 采样者）。
	if not DCFeatureFlags.sea_ice_atlas_active():
		out["path"] = "disabled"
		return out
	if world == null or map == null:
		return out
	var W: int = int(world.derived_size.x)
	var H: int = int(world.derived_size.y)
	var n: int = W * H
	if n <= 0:
		return out
	if world.pixel_to_cell_lookup.size() != n:
		push_warning("MapBaker.prepare_sea_ice_fraction_atlas: pixel_to_cell_lookup missing; falling back to zeros")
		var zero_buf := PackedByteArray()
		zero_buf.resize(n)
		baker._sea_ice_only_buf = zero_buf
		world.sea_ice_fraction_buffer = zero_buf
		out["prepared"] = true
		out["dirty"] = true
		out["path"] = "zero_fallback"
		out["prepare_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
		return out

	baker._ensure_sea_ice_pixel_to_cell_index(map, world)
	# DOTS-Final-Push 修复：优先用 set_climate_profile() 注入的引用；fallback 才走
	# 老的 world.get("config") 路径——但 WorldData 没有 config 字段，那条永远是 null。
	var cp = baker._climate_profile
	if cp == null:
		var cfg_legacy = world.get("config")
		cp = cfg_legacy.climate_profile if cfg_legacy != null and "climate_profile" in cfg_legacy else null
	var use_native: bool = cp != null \
			and baker._world_ext != null and baker._world_ext.has_method("run_sea_ice_atlas_prepare")
	# DOTS-Final-Push 任务 6.2：once-only 诊断打印——把 use_native 几个条件分别状态
	# 暴露出来，定位 path=gdscript 的真因。dots-flag-prune-pr1 (2026-05-22)：
	# use_gdext_sea_ice_atlas_prepare flag 已删，路径现恒走 ext + has_method 探测。
	if not baker._sea_ice_path_logged:
		baker._sea_ice_path_logged = true
		var cp_ok: bool = cp != null
		var ext_ok: bool = baker._world_ext != null
		var method_ok: bool = ext_ok and baker._world_ext.has_method("run_sea_ice_atlas_prepare")
		print("[sea_ice_atlas_prepare] path-decision once-only: cp=%s ext=%s method=%s -> use_native=%s" % [
			str(cp_ok), str(ext_ok), str(method_ok), str(use_native)
		])
	if use_native:
		if baker._world_ext.has_method("refresh_slots_from_map"):
			baker._world_ext.refresh_slots_from_map()
		var ret: Dictionary = baker._world_ext.run_sea_ice_atlas_prepare({
			"n_cells": map.cell_count(),
			"width": W,
			"height": H,
			"pixel_to_cell_index": baker._sea_ice_pixel_to_cell_idx,
			"previous_cell_bytes": baker._last_sea_ice_cell_bytes_packed,
		})
		if not bool(ret.get("fallback", true)):
			baker._sea_ice_only_buf = ret.get("buffer", PackedByteArray())
			baker._last_sea_ice_cell_bytes_packed = ret.get("cell_bytes", PackedByteArray())
			world.sea_ice_fraction_buffer = baker._sea_ice_only_buf
			baker._sea_ice_cache_size = Vector2i(W, H)
			out["prepared"] = baker._sea_ice_only_buf.size() == n
			out["dirty_cells"] = int(ret.get("dirty_cells", map.cell_count()))
			out["dirty_ratio"] = float(ret.get("dirty_ratio", 1.0))
			out["dirty"] = int(out.get("dirty_cells", 0)) > 0 or world.sea_ice_tex == null
			out["path"] = "gdext"
			out["prepare_ms"] = float(ret.get("prepare_ms", ret.get("elapsed_ms", 0.0)))
			return out
		else:
			out["fallback_reason"] = String(ret.get("reason", "unknown"))

	var gd_ret: Dictionary = baker._prepare_sea_ice_fraction_atlas_gd(map, world, W, H, n)
	gd_ret["prepare_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	return gd_ret



static func upload_prepared_sea_ice_fraction_atlas(baker: MapBaker, world: WorldData) -> Dictionary:
	var out: Dictionary = {"uploaded": false, "image_ms": 0.0, "upload_ms": 0.0, "elapsed_ms": 0.0}
	# [sea-ice-atlas-skip 2026-06-16] flag 关（默认）→ no-op（不 create/update sea_ice_tex）。
	if not DCFeatureFlags.sea_ice_atlas_active():
		return out
	if world == null:
		return out
	var W: int = int(world.derived_size.x)
	var H: int = int(world.derived_size.y)
	if W <= 0 or H <= 0 or baker._sea_ice_only_buf.size() != W * H:
		return out
	var t0: int = Time.get_ticks_usec()
	world.sea_ice_tex = DCAtlasEncoders.upload_single_channel(
		baker._sea_ice_only_buf, W, H, world.sea_ice_tex)
	var t2: int = Time.get_ticks_usec()
	out["uploaded"] = true
	out["image_ms"] = 0.0
	out["upload_ms"] = (t2 - t0) / 1000.0
	out["elapsed_ms"] = (t2 - t0) / 1000.0
	return out



static func ensure_sea_ice_pixel_to_cell_index(baker: MapBaker, map: MapData, world: WorldData) -> void:
	var n: int = int(world.derived_size.x) * int(world.derived_size.y)
	if baker._sea_ice_cache_size == world.derived_size and baker._sea_ice_pixel_to_cell_idx.size() == n:
		return
	baker._sea_ice_pixel_to_cell_idx = PackedInt32Array()
	baker._sea_ice_pixel_to_cell_idx.resize(n)
	var lookup := world.pixel_to_cell_lookup
	for i in range(n):
		var cell = lookup[i]
		baker._sea_ice_pixel_to_cell_idx[i] = map.index_of(cell) if cell != null else -1



static func prepare_sea_ice_fraction_atlas_gd(baker: MapBaker, map: MapData, world: WorldData, W: int, H: int, n: int) -> Dictionary:
	# DOTS-Final-Push 任务 6.2 / 方案 A：之前每次 prepare 都跑 2400 cell 字节比对
	# 后再无条件跑 28800 像素回扫（var px in range(n)），即便所有 cell 都没翻面也
	# 一样。32-day 的 sea_ice_atlas_upload p95=49ms（极端 232ms）的 prepare 部分
	# 大概率卡在这里。优化：先做 cell 字节比对，dirty_cells==0 且 sea_ice_tex
	# 已存在时直接 dirty=false 返回——不重新填 baker._sea_ice_only_buf（保持上一帧的
	# buffer）。旧 upload job 已删除，当前生产路径不会进入 prepare/upload。
	var cell_bytes := PackedByteArray()
	cell_bytes.resize(map.cell_count())
	var dirty_cells: int = 0
	for i in range(map.cell_count()):
		var cell: HexCell = map.cell_at(i)
		var b: int = 0
		if cell != null and baker._is_water(cell.terrain):
			# 使用 baker._q01_byte_ice 保留低浓度冰的连续数据；可见强度由 shader 阈值决定。
			# 与 ice_state_atlas_chunk_step 的语义一致（fraction>0 → byte>=1）。
			b = baker._q01_byte_ice(float(cell.sea_ice_fraction))
		cell_bytes[i] = b
		if baker._last_sea_ice_cell_bytes_packed.size() <= i or int(baker._last_sea_ice_cell_bytes_packed[i]) != b:
			dirty_cells += 1
	# Early-return：所有 cell 字节都没翻面 + 纹理已建立 + 缓存大小匹配 →
	# 不重做 28800 像素回扫，直接复用上一帧 baker._sea_ice_only_buf（caller 不会
	# 走 upload 分支，sea_ice_tex 维持当前内容）。
	if dirty_cells == 0 and world.sea_ice_tex != null \
			and baker._sea_ice_cache_size == Vector2i(W, H) \
			and baker._sea_ice_only_buf.size() == n:
		# baker._last_sea_ice_cell_bytes_packed 已与本帧一致，无需再赋值。
		world.sea_ice_fraction_buffer = baker._sea_ice_only_buf
		return {
			"prepared": true,
			"dirty": false,
			"prepare_ms": 0.0,
			"path": "gdscript_skip",
			"dirty_cells": 0,
			"dirty_ratio": 0.0,
		}
	# 有翻面 → 走完整像素回扫。
	baker._sea_ice_only_buf = PackedByteArray()
	baker._sea_ice_only_buf.resize(n)
	for px in range(n):
		var ci: int = baker._sea_ice_pixel_to_cell_idx[px] if px < baker._sea_ice_pixel_to_cell_idx.size() else -1
		baker._sea_ice_only_buf[px] = cell_bytes[ci] if ci >= 0 and ci < cell_bytes.size() else 0
	baker._last_sea_ice_cell_bytes_packed = cell_bytes
	world.sea_ice_fraction_buffer = baker._sea_ice_only_buf
	baker._sea_ice_cache_size = Vector2i(W, H)
	return {
		"prepared": true,
		"dirty": dirty_cells > 0 or world.sea_ice_tex == null,
		"prepare_ms": 0.0,
		"path": "gdscript",
		"dirty_cells": dirty_cells,
		"dirty_ratio": float(dirty_cells) / float(maxi(map.cell_count(), 1)),
	}


static func bake_latitude_buffer(_bounds: Rect2, size: Vector2i, world_ext: Object) -> PackedFloat32Array:
	var W: int = size.x
	var H: int = size.y
	var empty := PackedFloat32Array()
	empty.resize(maxi(W * H, 0))
	if W <= 0 or H <= 0:
		return empty
	if world_ext == null:
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
