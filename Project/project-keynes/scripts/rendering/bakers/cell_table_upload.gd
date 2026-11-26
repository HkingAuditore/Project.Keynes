extends RefCounted

## Packs cell and weather lookup layers and updates their texture arrays.

const CellTableCodecScript = preload("res://scripts/rendering/bakers/cell_table_codec.gd")
const WeatherTablePlan = preload("res://scripts/rendering/bakers/weather_table_plan.gd")
const PK_LAKE_DEPTH_NORM := 0.16
const WEATHER_TABLE_LAYERS := WeatherTablePlan.WEATHER_TABLE_LAYERS

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
		var packed := _cell_table_static_words(map, world, enum_bytes,
			previous_class.duplicate(), previous_aux.duplicate(), class_indices, need_all or full_classes)
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
