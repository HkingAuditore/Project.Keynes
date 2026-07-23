# data_overlay_baker.gd
# 把 MapData 中各 HexCell 的底层数值字段烘焙为一张 RGBA8 数据纹理，供
# data_overlay.gdshader 按 UV 采样并着色。
#
# 关键设计：
#   - 分辨率严格对齐 WorldData.derived_size（与 enum_atlas / scalar_atlas 一致）
#   - 利用 WorldData.cell_pixel_lists（每 cell → 它覆盖的像素 idx 列表）
#     一次 O(总像素数) 写入；不再逐像素重新 warp + cube_round。
#   - 像素编码：
#       R = 归一化数值（连续通道），或低 8 位类别 id（离散通道）
#       G = 保留：连续通道写 0；WEATHER 写 weather_intensity * 255
#       B = 预留（0）
#       A = 有效性标记：255 = 有效 / 0 = 无效（NaN/Inf/跨边界 null cell）
#   - 同一函数同时产出 stats 摘要（min/max/mean/median + 离散桶计数 + invalid_count）
#     给 Telemetry 分组直接用；不再对全图 cell 循环第二遍。
#
# 输出：
#   {
#     "texture"      : ImageTexture,  # 可直接 set_shader_parameter
#     "stats"        : Dictionary,    # { min, max, mean, median, count,
#                                    #   invalid_count, buckets:{id:count,...} }
#     "mode"         : int,           # 回传当前 mode 以便消费方校验一致
#     "value_scale"  : float,         # shader 反归一化需要的刻度（通常 1.0）
#     "value_offset" : float,         # shader 反归一化需要的偏移（通常 0.0）
#   }
#
# 玩家入口使用 bake_cell_lut()：静态 cell-index atlas 间接寻址，只写
# WorldData.lut_dims 的每-cell texel。上面的 bake() 是旧 debug 全图兼容路径。
class_name DataOverlayBaker

# 风带采样靠静态函数；这里 preload 一次以避免每 cell 反复 load。
const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")

# 降水 overlay 直接显示 weather pass 写出的实时 precipitation 字段。
const PRECIPITATION_NORM_MAX: float = 1.0

# 洋流模长归一化上限：cell.ocean_current.length() 的实际分布。
# 物理化路径已把 _OCEAN_CURRENT_SCALE 提高到 0.30，目标海面均值回到 0.18~0.35。
# 上限同步提高到 0.35，避免强流大面积饱和，同时让 0.15~0.25 的中强洋流落在色带中段。
# 同步影响 OCEAN_CURRENT_DIR 通道：dir_intensity = mag / OCEAN_CURRENT_NORM_MAX。
const OCEAN_CURRENT_NORM_MAX: float = 0.35

# 双向连续通道的对称半幅：value = 0.5 + clamp(raw / RANGE, -0.5, 0.5)
# OCEAN_HEAT_TRANSPORT 与 UPWELLING 都是带符号的异常量，0=中性、负=冷/下沉、正=暖/上升。
# 运行期 TTA 是每日平滑异常，实测 p95 常在 0.02~0.05；旧 ±0.4 会把有效信号压成中性灰。
const HEAT_TRANSPORT_NORM_RANGE: float = 0.08
const UPWELLING_NORM_RANGE: float = 1.0

# 风速归一化：读取物理风场写入的 cell.wind_speed；fallback 纬度风带约 0.15~1.1。
const WIND_SPEED_NORM_MAX: float = 1.7
const SLP_OVERLAY_NORM_RANGE: float = 0.35

# 用一张静态的空 1×1 纹理避免 mode=NONE 时 shader uniform 为 null。
static var _empty_tex: ImageTexture = null

static func get_empty_texture() -> ImageTexture:
	if _empty_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.0, 0.0, 0.0, 0.0))
		_empty_tex = ImageTexture.create_from_image(img)
	return _empty_tex

# 核心烘焙入口。
#   map             : MapData（all_cells / cell_pixel_lists 的数据源）
#   world           : WorldData（提供 derived_size 与 cell_pixel_lists）
#   mode            : OverlayMode.MODE
#   climate         : ClimateProfile（保留签名兼容；真实降水不再读取四季表）
#   season_phase    : 天文相位输入（保留签名兼容；真实降水不再由相位估算）
#   adapter_override: 可选 DCViewAdapter 实例。若提供则 baker 直接使用它，
#                     否则按 legacy 行为新建 DCViewAdapter.Cell。设计目的：
#                     让 baker 与 info_panel / 其他 UI 共用 main._view_adapter
#                     这个**唯一真值源**，避免 DOTS 中期阶段 Cell adapter
#                     (cell.temperature, 走 facade → DCWorld slot) 与
#                     World adapter (直读 map.temp_arr) 因 buffer drift
#                     (C++ flush CoW / resize) 而产生的"overlay 颜色 vs
#                     详情面板温度"不一致问题。详见 docs/dots-f4-validation
#                     §2.2.b 与 view_adapter.gd 头部注释。
#   existing_tex    : 可选 ImageTexture。若提供且 size 匹配，走 .update(img)
#                     路径复用 GPU 资源；否则新建一张。设计动机：
#                     debug-overlay-perf v1（2026-06-12）发现 x20 倍速下每个
#                     游戏日重建 1080×574 ImageTexture 触发 GPU 资源销毁 +
#                     VRAM 重分配，单次 ~8-15ms 同步阻塞，是温度/天气 overlay
#                     卡顿主因。返回结果里同时给出 texture 字段（与旧契约一致）。
#   existing_buf    : 可选 PackedByteArray。若提供且 size 匹配，复用并清零
#                     而非每帧 resize 2.4MB；进一步降低 GC 压力。
#   world_ext       : 可选 DCWorldExt（C++ co-processor）。若提供且实现了
#                     encode_overlay_atlas 且 world 的 SoA pixel CSR 已构建，
#                     则把 O(n_pixels) 的内层像素 fan-out 下沉到 C++（debug
#                     模式温度/天气 overlay 卡顿主因之一）。per-cell 采样仍在
#                     GDScript（仅 ~n_cells 次，分支重、含非 schema 字段，留
#                     GDScript 零 bit-divergence 风险）。ext 缺失 / 旧 DLL /
#                     SoA 未建 / C++ 返回 fallback 时透明回退到 GDScript fan-out。
#                     详见 docs/cpp-dots-runtime/computation-pipelines.md。
# 返回上面注释中的 Dictionary；任一前置缺失都返回一个"空但有效"的结果，
# 调用方据此把 overlay 退回 NONE 即可，不会污染 shader 参数。
# 返回额外字段：
#   "path"               : "gdext_fanout" / "gdscript_fanout" / "gdscript_fanout_soa"
#   "cpp_fallback_reason": String（C++ 返回 fallback 时的理由，否则空）
static func bake(
	map,
	world,
	mode: int,
	climate,
	season_phase: float,
	adapter_override: DCViewAdapter = null,
	existing_tex: ImageTexture = null,
	existing_buf: PackedByteArray = PackedByteArray(),
	world_ext = null
) -> Dictionary:
	var empty_result := {
		"texture": get_empty_texture(),
		"stats": _empty_stats(),
		"mode": mode,
		"value_scale": 1.0,
		"value_offset": 0.0,
	}
	if mode == OverlayMode.MODE.NONE:
		return empty_result
	if map == null or world == null:
		return empty_result
	var derived: Vector2i = world.derived_size
	if derived.x <= 0 or derived.y <= 0:
		return empty_result

	# B.1 (dots-migration-roadmap §3 B2)：构造一份 CellViewAdapter，让本 baker
	# 通过 adapter.get_<field>(cell.index) 读取 schema-mirrored 字段而非
	# 直接 cell.<field>。CellViewAdapter 内部直读 HexCell 强类型成员，行为
	# 与改造前完全等价；阶段 II 切换到 WorldViewAdapter 时本 baker 一行不动。
	# 非 schema 字段（passable_sea / temperature_transport_anomaly /
	# upwelling_strength / slp / wind_speed / wind_stress_curl / ocean_psi /
	# vegetation_vitality）继续走 cell.<field>——它们没有 SoA 对位，本 phase
	# 不在迁移范围内。
	#
	# 方案 A 修复（overlay vs info-panel 温度不一致）：
	# 优先使用 adapter_override（main._view_adapter）。这样 overlay 烘焙与
	# info_panel 详情面板共享同一 adapter 实例，避免在 DCFeatureFlags
	# use_world_view_adapter=true 时一边走 Cell（cell.temperature → facade →
	# DCWorld slot）一边走 World（直读 map.temp_arr），在 C++ flush CoW /
	# resize 引发 buffer drift 时出现颜色与数字偏差。
	var adapter: DCViewAdapter = adapter_override
	if adapter == null:
		adapter = DCViewAdapter.Cell.new(map.iter_cells())

	var total_px: int = derived.x * derived.y
	# P0/P2（debug-overlay-perf v1，2026-06-12）：复用 caller 提供的 buf，避免
	# 每帧重新分配 2.4MB（1080×574×4）触发 GDScript GC + 堆碎片。size 不匹配
	# 时安全回退到新建。fill(0) 是 PackedByteArray 原生方法（C++ memset），
	# 比 GDScript `for i in range(620544): buf[i*4+3] = 0` 快 ~50 倍。
	var buf: PackedByteArray = existing_buf
	var n_bytes: int = total_px * 4
	if buf.size() != n_bytes:
		buf = PackedByteArray()
		buf.resize(n_bytes)

	# DOTS（debug-overlay-perf v2，2026-06-12）：把 O(n_pixels) 的内层像素 fan-out
	# 下沉 C++（encode_overlay_atlas）。前置：world_ext 实现该 method（向前兼容
	# 旧 DLL）+ world 的 SoA pixel CSR（cell_first_px_arr 等，map_baker 在
	# _ensure_world_cell_pixel_csr 里整图一次性构建）已就绪。任一不满足 → cpp_path
	# = false，走原 GDScript Dict fan-out。约定与 4 张视觉 atlas 一致：恒走 ext +
	# has_method 探测，无 ClimateProfile flag（dots-flag-prune-pr1 round 2）。
	var soa_ready: bool = world.cell_first_px_arr.size() > 0 \
		and world.cell_px_count_arr.size() > 0 \
		and not world.flat_px_indices_arr.is_empty()
	var ext_ready: bool = world_ext != null \
		and world_ext.has_method(&"encode_overlay_atlas")
	var cpp_path: bool = soa_ready and ext_ready
	var n_cells_soa: int = world.cell_first_px_arr.size() if cpp_path else 0
	# cpp_path 下按 cell.index 收集 per-cell R/G byte + 有效标记；C++ 端做 fan-out。
	# resize 会零填充 → 无效 cell 天然 valid=0、不写像素。
	var cell_r_arr: PackedByteArray = PackedByteArray()
	var cell_g_arr: PackedByteArray = PackedByteArray()
	var cell_valid_arr: PackedByteArray = PackedByteArray()
	if cpp_path:
		cell_r_arr.resize(n_cells_soa)
		cell_g_arr.resize(n_cells_soa)
		cell_valid_arr.resize(n_cells_soa)
	else:
		# 非 cpp_path（GDScript Dict / SoA fan-out）需要先清零 buffer；cpp_path
		# 让 C++ memset，省一次 GDScript fill（C++ 返回 fallback 时再补 fill）。
		buf.fill(0)
	# 默认：全部像素 alpha=0（无效），shader 端渲染为中性灰。
	# 这样地图外/未覆盖像素不会出现颜色残影。
	# （旧实现：for i in range(total_px): buf[i*4+3] = 0；现在改为 fill(0) 后
	# 在 cell 循环里仅对有效 cell 的覆盖像素写 alpha=255，达到等价语义但
	# 省去 62 万次 GDScript 字节赋值。）

	# P2（debug-overlay-perf v1，2026-06-12）：把 stats 字段从 Dictionary 里拎
	# 出来变成强类型局部变量。原实现每 cell 至少 3-5 次 `int(stats.xxx) + 1`
	# 的 Variant→int 转换 + Dictionary key 查找，2400 cells × 5 次 ≈ 12000 次
	# Variant 装箱/拆箱。改成局部变量后 cell 循环完毕再一次性写回 Dictionary。
	var stats_min: float = INF
	var stats_max: float = -INF
	var stats_sum: float = 0.0
	var stats_count: int = 0
	var stats_invalid: int = 0
	var stats_near_zero: int = 0
	var stats_buckets: Dictionary = {}
	# values_for_median 改用 PackedFloat32Array，消除 Variant 装箱开销。
	var values_for_median: PackedFloat32Array = PackedFloat32Array()
	values_for_median.resize(cells_size_hint(map))
	var values_for_median_n: int = 0  # 真实长度（resize 是上限预分配）

	var cells: Array = map.all_cells()
	var use_pixel_lists: bool = world.cell_pixel_lists != null \
		and not world.cell_pixel_lists.is_empty()

	# 预备：CLIMATE_ZONE 需要每 cell 的真实 ny。直接采样 world.latitude_buffer
	# （map_baker._bake_latitude_buffer 已逐像素烘焙），与 main.gd 右侧"纬度"
	# 标签、shader 的半球判断完全一致。
	var lat_buf: PackedFloat32Array = world.latitude_buffer
	var lat_buf_size: int = lat_buf.size()

	# P2 hoist：mode 谓词外提，避免每 cell 重复跑 OverlayMode.is_discrete 函数调用。
	var mode_is_discrete: bool = OverlayMode.is_discrete(mode)
	var mode_is_climate_zone: bool = (mode == OverlayMode.MODE.CLIMATE_ZONE)

	for cell in cells:
		if cell == null:
			continue
		var sample := _sample_cell(cell, adapter, mode, climate, season_phase, world, map, lat_buf, lat_buf_size)
		var value: float = float(sample.get("value", 0.0))
		var bucket: int = int(sample.get("bucket", 0))
		var intensity: float = clampf(float(sample.get("intensity", 0.0)), 0.0, 1.0)
		var is_valid: bool = bool(sample.get("valid", true))
		# 方向型通道（WIND_DIR / OCEAN_CURRENT_DIR）：sample 返回 hue + dir_intensity，
		# 这里把它们重映射到 baker 协议——R = hue（[0,1] → 0..255）、G = dir_intensity。
		# shader 端按 mode 取 R 反推 hue 走 hsv2rgb。
		var is_vector_mode: bool = bool(sample.get("vector_mode", false))
		if is_vector_mode and is_valid:
			value = clampf(float(sample.get("hue", 0.0)), 0.0, 1.0)
			intensity = clampf(float(sample.get("dir_intensity", 0.0)), 0.0, 1.0)

		if is_valid and (is_nan(value) or is_inf(value)):
			is_valid = false
		# CLIMATE_ZONE 按 |ny - 0.5| 自己推导，不来自 cell；永远 valid
		# （即使数值类字段 NaN，气候带也能画）
		if mode_is_climate_zone:
			is_valid = true

		# 分离编码：连续通道 → R=归一化值；离散通道 → R=类别/档位；G=强度
		# 方向型通道 → R=hue(归一化角度)、G=强度
		# P2：用 `int(x * 255.0 + 0.5)` 替代 `int(round(x * 255.0))`，少一个函数调用。
		var r_byte: int = 0
		var g_byte: int = 0
		if is_valid:
			if mode_is_discrete:
				r_byte = clampi(bucket, 0, 255)
				g_byte = clampi(int(intensity * 255.0 + 0.5), 0, 255)
			elif is_vector_mode:
				r_byte = clampi(int(clampf(value, 0.0, 1.0) * 255.0 + 0.5), 0, 255)
				g_byte = clampi(int(intensity * 255.0 + 0.5), 0, 255)
			else:
				r_byte = clampi(int(clampf(value, 0.0, 1.0) * 255.0 + 0.5), 0, 255)

		# 统计（离散/连续/方向 分别记账）
		if not is_valid:
			stats_invalid += 1
		else:
			if not mode_is_discrete and _is_near_zero_sample(mode, value, intensity, is_vector_mode):
				stats_near_zero += 1
			if mode_is_discrete:
				stats_buckets[bucket] = int(stats_buckets.get(bucket, 0)) + 1
				stats_count += 1
			elif is_vector_mode:
				# 方向型通道 stats 描述的是"强度"分布（hue 的 min/max 没意义）。
				if intensity < stats_min: stats_min = intensity
				if intensity > stats_max: stats_max = intensity
				stats_sum += intensity
				stats_count += 1
				if values_for_median_n < values_for_median.size():
					values_for_median[values_for_median_n] = intensity
				else:
					values_for_median.append(intensity)
				values_for_median_n += 1
			else:
				if value < stats_min: stats_min = value
				if value > stats_max: stats_max = value
				stats_sum += value
				stats_count += 1
				if values_for_median_n < values_for_median.size():
					values_for_median[values_for_median_n] = value
				else:
					values_for_median.append(value)
				values_for_median_n += 1

		# 把该 cell 的结果写入它覆盖的所有像素。
		# P2（debug-overlay-perf v1，2026-06-12）：buf 已 fill(0)，无效 cell 的
		# 像素天然保留 alpha=0；只在 is_valid 时写四字节，省去无效 cell 的
		# 像素循环（小幅度收益，但配合 fill(0) 让无效像素从两次写变零次写）。
		# DOTS（debug-overlay-perf v2，2026-06-12）：cpp_path 下不在 GDScript 写
		# 像素，只按 cell.index 记录 R/G byte + 有效标记，留给 C++ fan-out。
		if cpp_path:
			var ci: int = int(cell.index)
			if is_valid and ci >= 0 and ci < n_cells_soa:
				cell_r_arr[ci] = r_byte
				cell_g_arr[ci] = g_byte
				cell_valid_arr[ci] = 1
		elif use_pixel_lists and is_valid:
			var pixels: PackedInt32Array = world.cell_pixel_lists.get(
				cell, PackedInt32Array()
			)
			for px_idx in pixels:
				if px_idx < 0 or px_idx >= total_px:
					continue
				var base := px_idx * 4
				buf[base] = r_byte
				buf[base + 1] = g_byte
				# buf[base + 2] = 0  # fill(0) 已写 0
				buf[base + 3] = 255
		# 若 cell_pixel_lists 未建（老地图），跳过像素写入，
		# 但仍保留统计，避免 Telemetry 崩溃。

	# P2 统计写回：把强类型局部变量装回 Dictionary。median 用 PackedFloat32Array
	# 的 in-place sort，避免 Variant 装箱。values_for_median 的真实长度由
	# values_for_median_n 控制（resize 是上限预分配，可能尾部有零值）。
	var stats := {
		"min": 0.0,
		"max": 0.0,
		"mean": 0.0,
		"median": 0.0,
		"count": stats_count,
		"invalid_count": stats_invalid,
		"near_zero_count": stats_near_zero,
		"buckets": stats_buckets,
		"sum": stats_sum,
	}
	if stats_count > 0 and not mode_is_discrete:
		stats["mean"] = stats_sum / float(stats_count)
		# 截断到真实长度后排序。PackedFloat32Array 没有 resize-shrink-without-copy，
		# 取子集后 sort。注意 sort 影响 values_for_median 内容（caller 不再读）。
		if values_for_median_n < values_for_median.size():
			values_for_median.resize(values_for_median_n)
		values_for_median.sort()
		var mid := values_for_median_n / 2
		if values_for_median_n % 2 == 1:
			stats["median"] = values_for_median[mid]
		else:
			stats["median"] = (values_for_median[mid - 1] + values_for_median[mid]) * 0.5
	stats["min"] = 0.0 if stats_min == INF else stats_min
	stats["max"] = 0.0 if stats_max == -INF else stats_max

	# DOTS（debug-overlay-perf v2，2026-06-12）：cpp_path 下把 per-cell R/G byte +
	# 有效标记 + world 持久 SoA CSR 交给 C++ encode_overlay_atlas，由它清零 buffer
	# 并扇出写像素（典型 ~62 万次写）。复用 world.flat_px_indices_arr 整图 flat，
	# first/count 直接索引（与 4 张视觉 atlas 共用语义），传参仅引用计数 +1。
	# C++ 返回 fallback（理论上仅参数非法）时透明回退到 GDScript SoA fan-out。
	var bake_path: String = "gdscript_fanout"
	var cpp_fallback_reason: String = ""
	if cpp_path:
		var res: Dictionary = world_ext.encode_overlay_atlas({
			"n_pix": total_px,
			"n_cells": n_cells_soa,
			"atlas_buffer": buf,
			"cell_first_px": world.cell_first_px_arr,
			"cell_px_count": world.cell_px_count_arr,
			"flat_px_indices": world.flat_px_indices_arr,
			"cell_r": cell_r_arr,
			"cell_g": cell_g_arr,
			"cell_valid": cell_valid_arr,
		})
		if not bool(res.get("fallback", true)):
			buf = res.get("atlas_buffer", buf)
			bake_path = "gdext_fanout"
		else:
			# C++ 拒绝（参数非法）→ GDScript SoA fan-out 兜底。先清零 buffer
			# （cpp_path 没在 GDScript 提前 fill），再用同一份 per-cell byte +
			# SoA CSR 复刻 C++ 写像素逻辑，保证 bit-equal。
			cpp_fallback_reason = String(res.get("reason", "cpp_fallback"))
			buf.fill(0)
			_fanout_cell_bytes_soa(
				buf, world, cell_r_arr, cell_g_arr, cell_valid_arr,
				total_px, n_cells_soa
			)
			bake_path = "gdscript_fanout_soa"

	var img := Image.create_from_data(
		derived.x, derived.y, false, Image.FORMAT_RGBA8, buf
	)
	# P0（debug-overlay-perf v1，2026-06-12）：优先复用 caller 提供的
	# ImageTexture，走 .update(img) 路径——比 create_from_image 快 5-10 倍
	# 且不触发 GPU 资源销毁/重建。size 不匹配（首帧 / derived_size 变更）
	# 时安全 fallback 到新建。
	# Hot path 假设 caller（main._refresh_overlay_data）持久化 _overlay_tex
	# 并在每次调用时回传。
	var tex: ImageTexture = existing_tex
	var need_new: bool = (tex == null) or (tex.get_size() != Vector2(float(derived.x), float(derived.y)))
	if need_new:
		tex = ImageTexture.create_from_image(img)
	else:
		tex.update(img)

	return {
		"texture": tex,
		"buf": buf,                     # 让 caller 缓存复用（P0）
		"stats": stats,
		"mode": mode,
		"value_scale": 1.0,
		"value_offset": 0.0,
		"path": bake_path,
		"cpp_fallback_reason": cpp_fallback_reason,
	}


## Player-facing high-performance path. It writes exactly one RGBA8 texel per
## cell into WorldData.lut_dims and never constructs a derived-resolution image.
static func bake_cell_lut(
	map,
	world,
	mode: int,
	climate,
	season_phase: float,
	adapter_override: DCViewAdapter = null,
	resource_profile: ResourceProfile = null,
	existing_tex: ImageTexture = null,
	existing_buf: PackedByteArray = PackedByteArray(),
	existing_image: Image = null
) -> Dictionary:
	var dims: Vector2i = world.lut_dims if world != null else Vector2i.ZERO
	if map == null or world == null or mode == OverlayMode.MODE.NONE \
			or dims.x <= 0 or dims.y <= 0:
		return {
			"texture": get_empty_texture(), "buf": PackedByteArray(),
			"stats": _empty_stats(), "mode": mode, "path": "cell_lut",
			"upload_bytes": 0,
		}

	var adapter: DCViewAdapter = adapter_override
	if adapter == null:
		adapter = DCViewAdapter.Cell.new(map.iter_cells())
	var byte_count := dims.x * dims.y * 4
	var buf := existing_buf
	if buf.size() != byte_count:
		buf = PackedByteArray()
		buf.resize(byte_count)
	buf.fill(0)

	var reserves: PackedFloat32Array = PackedFloat32Array()
	var habitat: PackedByteArray = map.resource_habitat_mask_arr
	var reference := 1.0
	if mode == OverlayMode.MODE.RESOURCE_RESERVE and resource_profile != null:
		var field := ResourceProfileRegistry.reserve_map_field(resource_profile)
		if field != "":
			reserves = map.get(field)
		reference = ResourceProfileRegistry.reference_reserve(resource_profile)

	var valid_count := 0
	var invalid_count := 0
	var min_value := INF
	var max_value := -INF
	var sum_value := 0.0
	var buckets: Dictionary = {}
	var mode_is_discrete := OverlayMode.is_discrete(mode)
	var temp_arr: PackedFloat32Array = map.temp_arr
	var moisture_arr: PackedFloat32Array = map.moisture_arr
	var elevation_arr: PackedFloat32Array = map.elevation_arr
	var landform_arr: PackedByteArray = map.landform_arr
	var vegetation_arr: PackedByteArray = map.vegetation_arr
	var wind_x_arr: PackedFloat32Array = map.wind_x_arr
	var wind_y_arr: PackedFloat32Array = map.wind_y_arr
	var wind_speed_arr: PackedFloat32Array = map.wind_speed_arr
	var current_x_arr: PackedFloat32Array = map.ocean_current_x_arr
	var current_y_arr: PackedFloat32Array = map.ocean_current_y_arr
	var is_water_arr: PackedByteArray = map.is_water_arr
	var n_cells := mini(map.cell_count(), dims.x * dims.y)
	for idx in range(n_cells):
		var valid := true
		var vector_mode := false
		var value := 0.0
		var intensity := 0.0
		var bucket := 0
		match mode:
			OverlayMode.MODE.ELEVATION:
				value = clampf(float(elevation_arr[idx]), 0.0, 1.0)
			OverlayMode.MODE.LANDFORM:
				bucket = int(landform_arr[idx])
			OverlayMode.MODE.VEGETATION_TYPE:
				bucket = int(vegetation_arr[idx])
			OverlayMode.MODE.TEMPERATURE:
				value = clampf(float(temp_arr[idx]), 0.0, 1.0)
			OverlayMode.MODE.HUMIDITY:
				value = clampf(float(moisture_arr[idx]), 0.0, 1.0)
			OverlayMode.MODE.WIND_DIR:
				var wx := float(wind_x_arr[idx])
				var wy := float(wind_y_arr[idx])
				var mag := sqrt(wx * wx + wy * wy)
				valid = mag >= 0.0001
				if valid:
					value = fposmod(atan2(wy, wx) / TAU + 0.5, 1.0)
					var speed := float(wind_speed_arr[idx])
					intensity = clampf((speed if speed > 0.0001 else mag) /
						WIND_SPEED_NORM_MAX, 0.0, 1.0)
					vector_mode = true
			OverlayMode.MODE.OCEAN_CURRENT_DIR:
				valid = idx < is_water_arr.size() and is_water_arr[idx] != 0
				if valid:
					var ox := float(current_x_arr[idx])
					var oy := float(current_y_arr[idx])
					var ocean_mag := sqrt(ox * ox + oy * oy)
					valid = ocean_mag >= 0.0001
					if valid:
						value = fposmod(atan2(oy, ox) / TAU + 0.5, 1.0)
						intensity = clampf(ocean_mag / OCEAN_CURRENT_NORM_MAX, 0.0, 1.0)
						vector_mode = true
			OverlayMode.MODE.RESOURCE_RESERVE:
				var reserve := float(reserves[idx]) if idx < reserves.size() else 0.0
				var mask := int(habitat[idx]) if idx < habitat.size() else 0
				valid = resource_profile != null \
					and ResourceProfileRegistry.habitat_available(resource_profile, mask) \
					and reserve > 0.0
				value = clampf(reserve / maxf(reference, 1.0), 0.0, 1.0)
			_:
				var cell = map.cell_at(idx)
				var sample := _sample_cell(
					cell, adapter, mode, climate, season_phase, world, map,
					world.latitude_buffer, world.latitude_buffer.size()
				)
				valid = bool(sample.get("valid", true))
				value = float(sample.get("value", 0.0))
				intensity = clampf(float(sample.get("intensity", 0.0)), 0.0, 1.0)
				bucket = int(sample.get("bucket", 0))
				vector_mode = bool(sample.get("vector_mode", false))
				if vector_mode:
					value = clampf(float(sample.get("hue", 0.0)), 0.0, 1.0)
					intensity = clampf(float(sample.get("dir_intensity", 0.0)), 0.0, 1.0)
		if valid and (is_nan(value) or is_inf(value)):
			valid = false
		if not valid:
			invalid_count += 1
			continue

		var base := idx * 4
		buf[base] = clampi(bucket if mode_is_discrete else int(
			clampf(value, 0.0, 1.0) * 255.0 + 0.5), 0, 255)
		buf[base + 1] = clampi(int(intensity * 255.0 + 0.5), 0, 255)
		buf[base + 3] = 255
		valid_count += 1
		if mode_is_discrete:
			buckets[bucket] = int(buckets.get(bucket, 0)) + 1
		else:
			var measured := intensity if vector_mode else value
			min_value = minf(min_value, measured)
			max_value = maxf(max_value, measured)
			sum_value += measured

	var img := existing_image
	if img == null or img.get_size() != dims or img.get_format() != Image.FORMAT_RGBA8:
		img = Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RGBA8, buf)
	else:
		img.set_data(dims.x, dims.y, false, Image.FORMAT_RGBA8, buf)
	var tex := existing_tex
	if tex == null or tex.get_size() != Vector2(dims):
		tex = ImageTexture.create_from_image(img)
	else:
		tex.update(img)
	return {
		"texture": tex,
		"image": img,
		"buf": buf,
		"mode": mode,
		"path": "cell_lut",
		"upload_bytes": byte_count,
		"stats": {
			"min": 0.0 if min_value == INF else min_value,
			"max": 0.0 if max_value == -INF else max_value,
			"mean": sum_value / float(valid_count) if valid_count > 0 and not mode_is_discrete else 0.0,
			"median": 0.0,
			"count": valid_count,
			"invalid_count": invalid_count,
			"near_zero_count": 0,
			"buckets": buckets,
			"sum": sum_value,
		},
	}

# DOTS（debug-overlay-perf v2，2026-06-12）：encode_overlay_atlas 的 GDScript 等价
# fan-out，仅在 cpp_path 命中但 C++ 返回 fallback 时用作兜底。逻辑与 C++ 端
# byte-for-byte 一致：按 cell.index 读 SoA CSR，把有效 cell 的 (R, G, 0, 255)
# 写到它覆盖的全部像素。调用前 caller 须已 buf.fill(0)。
static func _fanout_cell_bytes_soa(
	buf: PackedByteArray,
	world,
	cell_r_arr: PackedByteArray,
	cell_g_arr: PackedByteArray,
	cell_valid_arr: PackedByteArray,
	total_px: int,
	n_cells_soa: int
) -> void:
	var first_px: PackedInt32Array = world.cell_first_px_arr
	var px_count: PackedInt32Array = world.cell_px_count_arr
	var flat_px: PackedInt32Array = world.flat_px_indices_arr
	var flat_n: int = flat_px.size()
	for ci in range(n_cells_soa):
		if cell_valid_arr[ci] == 0:
			continue
		var first: int = first_px[ci]
		var count: int = px_count[ci]
		if first < 0 or count <= 0:
			continue
		var r_byte: int = cell_r_arr[ci]
		var g_byte: int = cell_g_arr[ci]
		for p in range(count):
			var fi: int = first + p
			if fi < 0 or fi >= flat_n:
				continue
			var px_idx: int = flat_px[fi]
			if px_idx < 0 or px_idx >= total_px:
				continue
			var base: int = px_idx * 4
			buf[base] = r_byte
			buf[base + 1] = g_byte
			buf[base + 3] = 255

# 逐 cell 按 mode 做采样。
# 返回 { value: float(0..1), bucket: int, intensity: float(0..1), valid: bool }
# value  —— 连续通道使用；离散通道忽略
# bucket —— 离散通道使用（CLIMATE_ZONE 档位 / WeatherType.WT id）
# intensity —— 仅 WEATHER 通道用于控制 alpha
static func _sample_cell(
	cell,
	adapter: DCViewAdapter,
	mode: int,
	climate,
	season_phase: float,
	world,
	map,
	lat_buf: PackedFloat32Array,
	lat_buf_size: int
) -> Dictionary:
	# B.1：所有 schema-mirrored 字段从 adapter 读，cell.* 仅留 non-schema
	# 字段（passable_sea / vegetation_vitality / temperature_transport_anomaly /
	# upwelling_strength / slp / wind_speed / wind_stress_curl / ocean_psi）。
	var idx: int = int(cell.index)
	match mode:
		OverlayMode.MODE.TEMPERATURE:
			return {
				"value": clampf(adapter.get_temp(idx), 0.0, 1.0),
				"valid": true,
			}
		OverlayMode.MODE.PRECIPITATION:
			var precip: float = adapter.get_weather_precip(idx)
			return {
				"value": clampf(precip / PRECIPITATION_NORM_MAX, 0.0, 1.0),
				"valid": true,
			}
		OverlayMode.MODE.CLIMATE_ZONE:
			# 与 main.gd._climate_zone_name 一致：用 world.latitude_buffer 取真实 ny。
			# 直接取该 cell 覆盖的第一个像素 idx，查 latitude_buffer[idx]。
			# 这是 map_baker 渲染所用的同一份 ny，保证 overlay / 文字标签 / shader
			# 三方完全一致；buffer 缺失时回退到 _latitude_hint 的近似（仅极旧地图）。
			var ny_like: float = _cell_latitude(cell, world, lat_buf, lat_buf_size)
			var lat_dev: float = absf(ny_like - 0.5) * 2.0  # 0(赤道)..1(极)
			var zone: int = clampi(int(lat_dev * 5.0), 0, 4)
			return {
				"bucket": zone,
				"valid": true,
			}
		OverlayMode.MODE.HUMIDITY:
			return {
				"value": clampf(adapter.get_moisture(idx), 0.0, 1.0),
				"valid": true,
			}
		OverlayMode.MODE.WEATHER:
			var has_weather: bool = adapter.get_weather_field_init(idx)
			var w: int = adapter.get_weather_type(idx) if has_weather else WeatherType.WT.CLEAR
			var intensity: float = adapter.get_weather_intensity(idx) if has_weather else 0.0
			return {
				"bucket": w,
				"intensity": clampf(intensity, 0.0, 1.0),
				"valid": true,
			}
		OverlayMode.MODE.VEGETATION_VITALITY:
			# 水域 cell 不参与植被健康度采样：用 HexCell.passable_sea 作为"水"
			# 的 proxy（TerrainProfileRegistry 已把 OCEAN/SEA_ICE/COAST/LAKE/REEF
			# 等水面地形标记 passable_sea=true）。陆上植被（即使 passable_land=false
			# 的高山 SNOW）仍参与采样，只是 vitality 默认 0.7，无特殊处理。
			if bool(cell.passable_sea):
				return { "value": 0.0, "valid": false }
			return {
				"value": clampf(float(cell.vegetation_vitality), 0.0, 1.0),
				"valid": true,
			}
		OverlayMode.MODE.OCEAN_CURRENT:
			# 仅水域有效：陆地 ocean_current 维持 0，画出来无意义且会被中性灰污染。
			# 用 passable_sea 当水的 proxy（与 VEGETATION_VITALITY 同口径）。
			if not bool(cell.passable_sea):
				return { "value": 0.0, "valid": false }
			var mag: float = adapter.get_ocean_current(idx).length()
			return {
				"value": clampf(mag / OCEAN_CURRENT_NORM_MAX, 0.0, 1.0),
				"valid": true,
			}
		OverlayMode.MODE.OCEAN_HEAT_TRANSPORT:
			# 仅水域有意义：洋流给该格相对静水状态的温度增减。
			# 双向归一化到 [0, 1]：0 = 强冷输入、0.5 = 中性、1 = 强暖输入。
			if not bool(cell.passable_sea):
				return { "value": 0.5, "valid": false }
			var raw_t: float = float(cell.temperature_transport_anomaly)
			var n_t: float = 0.5 + clampf(raw_t / (HEAT_TRANSPORT_NORM_RANGE * 2.0), -0.5, 0.5)
			return {
				"value": n_t,
				"valid": true,
			}
		OverlayMode.MODE.UPWELLING:
			# 仅水域有意义：upwelling_strength ∈ [-1, 1]，正=上升流（营养上涌）。
			# 同样双向归一化到 [0, 1]：0 = 强下沉、0.5 = 中性、1 = 强上升。
			if not bool(cell.passable_sea):
				return { "value": 0.5, "valid": false }
			var raw_u: float = adapter.get_upwelling_strength(idx)
			var n_u: float = 0.5 + clampf(raw_u / (UPWELLING_NORM_RANGE * 2.0), -0.5, 0.5)
			return {
				"value": n_u,
				"valid": true,
			}
		OverlayMode.MODE.WIND_SPEED:
			# 注意：wind_at() 总是 normalize（服务于风向场 advection），不能反推
			# 风速。这里读物理循环写入的 wind_speed SoA / facade 真值。
			# 值域 ≈ [0.15, 1.7]，由 WIND_SPEED_NORM_MAX 钳到 [0, 1]。
			# 全图都有效，包括海洋和高山。
			var w_speed: float = adapter.get_wind_speed(idx)
			return {
				"value": clampf(w_speed / WIND_SPEED_NORM_MAX, 0.0, 1.0),
				"valid": true,
			}
		OverlayMode.MODE.BIOME_GROUP:
			# 把 cell.terrain（27 种）映射到 OverlayMode.TERRAIN_TO_BIOME_GROUP 的
			# 10 个生态大类，避免离散调色板膨胀到难以辨认。
			var t_b: int = adapter.get_terrain(idx)
			var bgroup: int = 9  # 默认 fallback：未分类
			if t_b >= 0 and t_b < OverlayMode.TERRAIN_TO_BIOME_GROUP.size():
				bgroup = int(OverlayMode.TERRAIN_TO_BIOME_GROUP[t_b])
			return {
				"bucket": bgroup,
				"valid": true,
			}
		OverlayMode.MODE.LANDFORM:
			return {
				"bucket": adapter.get_landform(idx),
				"valid": true,
			}
		OverlayMode.MODE.ELEVATION:
			return {
				"value": clampf(adapter.get_elevation(idx), 0.0, 1.0),
				"valid": true,
			}
		OverlayMode.MODE.VEGETATION_TYPE:
			return {
				"bucket": adapter.get_vegetation(idx),
				"valid": true,
			}
		OverlayMode.MODE.WIND_DIR:
			# 方向型通道：hue = atan2(dy, dx) / (2π) + 0.5（[0,1]），value = mag/NORM_MAX
			# 使用 cell.wind_vector 给方向，cell.wind_speed 给强度。
			var wv: Vector2 = adapter.get_wind_vector(idx)
			var mag_w: float = wv.length()
			if mag_w < 0.0001:
				return { "value": 0.0, "valid": false }
			var speed_w: float = adapter.get_wind_speed(idx)
			if speed_w <= 0.0001:
				speed_w = mag_w
			var ang_w: float = atan2(wv.y, wv.x)
			var hue_w: float = (ang_w / TAU) + 0.5  # [0, 1)
			hue_w = fposmod(hue_w, 1.0)
			# value 用 baker 现成的 R 通道；intensity 复用 G 通道存模长（HSV 的 V）
			# 但当前编码协议 R=value，G=intensity；我们让 R=hue，G=norm_mag。
			# 通过返回特殊字段 hue / dir_intensity，主循环里特别处理写入。
			return {
				"hue": hue_w,
				"dir_intensity": clampf(speed_w / WIND_SPEED_NORM_MAX, 0.0, 1.0),
				"valid": true,
				"vector_mode": true,
			}
		OverlayMode.MODE.OCEAN_CURRENT_DIR:
			# 仅水域有效；陆地无意义。复用 cell.ocean_current。
			if not bool(cell.passable_sea):
				return { "value": 0.0, "valid": false }
			var oc: Vector2 = adapter.get_ocean_current(idx)
			var mag_o: float = oc.length()
			if mag_o < 0.0001:
				return { "value": 0.0, "valid": false }
			var ang_o: float = atan2(oc.y, oc.x)
			var hue_o: float = fposmod((ang_o / TAU) + 0.5, 1.0)
			return {
				"hue": hue_o,
				"dir_intensity": clampf(mag_o / OCEAN_CURRENT_NORM_MAX, 0.0, 1.0),
				"valid": true,
				"vector_mode": true,
			}
		OverlayMode.MODE.SLP:
			# Physical Wind & Ocean Circulation 调试通道：海陆压力（双向）。
			# cell.slp ∈ [-1, 1] 归一化（陆地夏低冬高、海洋季节波动小）。
			# 全图都有效；diverging 渐变 → 0=低压(冷色) / 0.5=中性 / 1=高压(暖色)。
			var slp_raw: float = adapter.get_slp(idx)
			var n_slp: float = 0.5 + clampf(slp_raw / (SLP_OVERLAY_NORM_RANGE * 2.0), -0.5, 0.5)
			return {
				"value": n_slp,
				"valid": true,
			}
		OverlayMode.MODE.WIND_STRESS_CURL:
			# 仅水域有意义（陆地不参与海盆 ψ 求解）。cell.wind_stress_curl 由
			# PhysicalCirculationSolver 在 ψ 求解前的源项计算阶段写入；典型量级
			# ~ ±0.5（无量纲，只用于 overlay 视觉对比）。
			if not bool(cell.passable_sea):
				return { "value": 0.5, "valid": false }
			var curl_raw: float = adapter.get_wind_stress_curl(idx)
			var n_curl: float = 0.5 + clampf(curl_raw * 1.0, -0.5, 0.5)
			return {
				"value": n_curl,
				"valid": true,
			}
		OverlayMode.MODE.OCEAN_PSI:
			# 仅水域有效。流函数 ψ 的等高线 = 流线，diverging 渐变让北半球反气旋
			# (ψ 中部小)与南半球反气旋(ψ 中部大)以同色对称呈现。
			# cell.ocean_psi 量级 ~ ±5（数值随地图尺寸变化），稳健做法：scan max abs 后
			# 归一化；这里简化用经验常数 5.0。
			if not bool(cell.passable_sea):
				return { "value": 0.5, "valid": false }
			var psi_raw: float = adapter.get_ocean_psi(idx)
			var n_psi: float = 0.5 + clampf(psi_raw / 10.0, -0.5, 0.5)
			return {
				"value": n_psi,
				"valid": true,
			}
		OverlayMode.MODE.DEMO_THERMAL_GRADIENT:
			# Reference-impl Pass #2 (demo-only, performance-charter §12.6)。
			# 采样 MapData.demo_thermal_gradient_arr[cell.index]——该字段由 C++
			# _ext.run_thermal_gradient_pass + flush snapshot 填充；开关关闭时
			# size=0，安全返回 valid=false 避免走错路。
			if map == null:
				return { "value": 0.0, "valid": false }
			var dtg_arr: PackedFloat32Array = map.demo_thermal_gradient_arr
			var dtg_n: int = dtg_arr.size()
			if dtg_n <= 0:
				return { "value": 0.0, "valid": false }
			var dtg_idx: int = int(cell.index)
			if dtg_idx < 0 or dtg_idx >= dtg_n:
				return { "value": 0.0, "valid": false }
			return {
				"value": clampf(dtg_arr[dtg_idx], 0.0, 1.0),
				"valid": true,
			}
		_:
			return { "value": 0.0, "valid": false }

static func _is_near_zero_sample(mode: int, value: float, intensity: float, is_vector_mode: bool) -> bool:
	if is_vector_mode:
		return intensity <= 0.025
	match mode:
		OverlayMode.MODE.OCEAN_CURRENT, OverlayMode.MODE.WIND_SPEED:
			return value <= 0.025
		OverlayMode.MODE.OCEAN_HEAT_TRANSPORT, OverlayMode.MODE.UPWELLING, OverlayMode.MODE.SLP, OverlayMode.MODE.WIND_STRESS_CURL, OverlayMode.MODE.OCEAN_PSI:
			return absf(value - 0.5) <= 0.01
		_:
			return false

# 取得 cell 的真实归一化纬度 ny ∈ [0, 1]。
# 优先级：
#   1. 用 world.cell_pixel_lists[cell] 第一个像素 idx 查 world.latitude_buffer
#      —— 这就是 map_baker 渲染时实际使用的 ny，与 main.gd 标签 / shader 半球
#      判断完全一致，是权威来源。
#   2. fallback：极旧地图没有 latitude_buffer / cell_pixel_lists 时，退到
#      _latitude_hint 的轴坐标近似（精度差，仅保证不崩）。
static func _cell_latitude(
	cell,
	world,
	lat_buf: PackedFloat32Array,
	lat_buf_size: int
) -> float:
	if world != null and lat_buf_size > 0 and world.cell_pixel_lists != null \
			and not world.cell_pixel_lists.is_empty():
		var pixels: PackedInt32Array = world.cell_pixel_lists.get(
			cell, PackedInt32Array()
		)
		if pixels.size() > 0:
			var idx: int = pixels[0]
			if idx >= 0 and idx < lat_buf_size:
				return lat_buf[idx]
	return _latitude_hint(cell)

# 用 cell 的 (q, r) 估算 ny ∈ [0, 1]。仅作为 latitude_buffer 缺失时的 fallback。
# 注意：这只是粗略近似，hex 轴坐标到 offset-row 的真实换算依赖具体布局，
# 5 档气候带分档足以容错；正常路径请走 _cell_latitude。
static func _latitude_hint(cell) -> float:
	# fallback 估算：直接用 axial 的 r 当行号（pointy-top 下 r 与垂直方向最对齐）。
	# 旧版本曾用 `r + 0.5*q`，这是对角线方向，会导致 overlay 呈左上→右下斜带 bug。
	var row_like: float = float(cell.r)
	# 世界半高的经验常量（hex 坐标下 map_height ~ 80..200），做一个稳定的归一化：
	var half_h: float = 90.0
	var ny: float = 0.5 + clampf(row_like / (2.0 * half_h), -0.5, 0.5)
	return ny

static func _empty_stats() -> Dictionary:
	return {
		"min": 0.0,
		"max": 0.0,
		"mean": 0.0,
		"median": 0.0,
		"count": 0,
		"invalid_count": 0,
		"near_zero_count": 0,
		"buckets": {},
		"sum": 0.0,
	}


# P2（debug-overlay-perf v1，2026-06-12）：给 values_for_median 预分配 cell 上限，
# 消除 PackedFloat32Array 反复 append 触发的 reallocation。Map 没有 cell_count
# 方法时退到一个保守上限（4096），不会错算结果——多余位会被 resize 截断。
static func cells_size_hint(map) -> int:
	if map == null:
		return 4096
	if map.has_method("cell_count"):
		return int(map.cell_count())
	if map.has_method("all_cells"):
		return int(map.all_cells().size())
	return 4096
