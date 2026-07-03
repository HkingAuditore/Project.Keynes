# world_data.gd
# 由 MapBaker.synthesize_world 产出的"世界"——高分辨率地理仿真结果。
#
# - height_buffer    (hm_size, [0,1])：归一化海拔，深海到山顶
# - moisture_buffer  (derived_size, [0,1])：湿度，受 flow 扩散影响
# - flow_buffer      (derived_size, [0,1])：log-scaled 流量累积，0=干旱，1=主河道
# - biome_buffer     (derived_size, byte)：每像素 TerrainType.TERRAIN id
#
# 4 张对应的 ImageTexture 直接喂给 world_map.gdshader 做像素级合成。
# 同时提供给 MapGenerator 在 hex 中心采样，反推 cell.terrain / elevation / has_river。

class_name WorldData
extends RefCounted

# ─── 高分辨率原始 buffer（GDScript 端可直接采样） ─────────────────────────
var height_buffer: PackedFloat32Array = PackedFloat32Array()
var moisture_buffer: PackedFloat32Array = PackedFloat32Array()
var flow_buffer: PackedFloat32Array = PackedFloat32Array()
var biome_buffer: PackedByteArray = PackedByteArray()
# Milestone 2：植被 / 覆盖物双通道（与 biome_buffer 同分辨率，warp 完全一致，
# 因此 fragment 端 sample 同一 uv 直接对齐）。
#   - vegetation_buffer (R8) ：每像素 = VegetationType.VEG id（0..23）
#   - cover_buffer      (R8) ：每像素 = CoverType.CV id（0..5）
# 这两轴允许 shader 在不动现有 biome 着色路径的前提下，给 HILL/MOUNTAIN/PLAIN 等
# 主色单一的地形按真实植被微调色相，并把 SNOW/GLACIER/FLOODING 等覆盖物独立叠加。
var vegetation_buffer: PackedByteArray = PackedByteArray()
var cover_buffer: PackedByteArray = PackedByteArray()
# Phase 1：每像素 ny ∈ [0, 1]，shader 用来算半球 + 季节温度偏移
var latitude_buffer: PackedFloat32Array = PackedFloat32Array()
# Phase 3：每像素海洋洋流向量；陆地像素值无意义。RG 各编码 [-1, 1] → [0, 1]
var ocean_current_buffer: PackedByteArray = PackedByteArray()  # RG8
# Systemic Ocean Currents：每像素上升/下沉流强度。R8 编码：
#   0   = 下沉流满强度（映射为 upwelling_strength = -1）
#   128 = 无（0）
#   255 = 上升流满强度（+1）
# 产出自 MapBaker._bake_ocean_upwelling（高纬冷水汇点 + 沿岸 Ekman 抽吸识别）。
# 陆地像素维持 128（0）。由 MapGenerator._compute_ocean_currents 回填到
# HexCell.upwelling_strength，下游海冰 / 海洋生物 / 调试可视化共用。
var ocean_upwelling_buffer: PackedByteArray = PackedByteArray()  # R8
# Phase 6：每像素当前物理风向（C++/DOTS 风场快照光栅化；fallback 为纬度背景风）。RG8。
# 海洋洋流通过 Ekman 偏转读它当主驱动力；主地图水面和 WeatherLayer 仍消费它。

var wind_field_buffer: PackedByteArray = PackedByteArray()  # RG8
# [water-depth-tex 2026-06-26] 每像素海/湖统一归一水深（R8，0=岸/陆，255=最深）。
# C++ 在 post_base 算好 per-cell water_depth01（海洋 1-E/sea + 湖泊湖岸→湖心碗形），
# bake 经 pixel_to_cell_index 扇出到此 buffer → water_depth_tex；shader 每水像素 1 次采样。
var water_depth_buffer: PackedByteArray = PackedByteArray()  # R8
# 兼容旧调试/数据通道的海冰覆盖率 buffer。主地图海冰视觉已经改为 shader
# 按逐像素水温/纬度/水深派生，不再依赖此 buffer 上传。
var sea_ice_fraction_buffer: PackedByteArray = PackedByteArray()  # R8
# RGBA8 weather field texture, baked from per-cell weather state.
# R=WeatherType id, G=intensity, B=cloud, A=vapor.
var weather_field_buffer: PackedByteArray = PackedByteArray()
# RGBA8 dynamic cell atlas：把每日会变的真实 cell 状态喂给主地图材质。
# R=temperature, G=moisture/wetness, B=snow_cover, A=vegetation_vitality。
var dynamic_cell_atlas_buffer: PackedByteArray = PackedByteArray()
# RGBA8 ecology visual atlas. R=foliage_density, G=stress/dryness,
# B=vegetation transition age, A=recent growth/damage.
var ecology_visual_atlas_buffer: PackedByteArray = PackedByteArray()

# ─── map-visual-overhaul-v1：地图视觉重构新增 atlas（病灶 B / A）───

# dyn_atlas_smooth_buffer：dynamic_cell_atlas 的"沿 hex 邻接 box blur"产物，
#   shader 单点采样它即可得到跨 hex 平滑的 R=temp / G=moist / B=snow / A=vitality。
#   原 dynamic_cell_atlas_buffer 保留给调试/info 面板，不再供主 shader 消费。
# ice_state_buffer：R8，每像素 = 该 cell.sea_ice_frac × 255 量化。仅水域 cell 写
#   非零，陆地恒 0。shader 据此替换原 lat-driven 静态 ice mask（病灶 A 解药）。
var dyn_atlas_smooth_buffer: PackedByteArray = PackedByteArray()  # RGBA8
var ice_state_buffer: PackedByteArray = PackedByteArray()         # R8

# ─── 元数据 ───────────────────────────────────────────────────────────────
var hm_size: Vector2i = Vector2i.ZERO       # heightmap 分辨率（高，用于 hillshading）
var derived_size: Vector2i = Vector2i.ZERO  # 派生 buffer 分辨率（低，省内存）
var world_bounds: Rect2 = Rect2()
var wrap_period_x: float = 0.0
var sea_level: float = 0.42                  # 与 cfg.sea_level 一致，[0,1] 范围
var bake_seed: int = 0                       # Phase 2：复刷 biome_tex 时复用同一 seed

# ─── shader 用 ImageTexture（编码后） ─────────────────────────────────────
# v9.atlas：把 9 张 derived 贴图合并成 3 张 atlas，降低 sampler 绑定数与 uniform 上传量。
# height_tex 因为分辨率与精度需求独立保留（hm_size + RG8 16-bit）。
#
# enum_atlas_tex   (RGBA8 NEAREST, derived_size；map_index_atlas)
#   R = biome (TerrainType.TERRAIN id)
#   G/B = cell.index low/high byte
#   A = landform id

#
# scalar_atlas_tex (RGBA8 LINEAR, derived_size)
#   R = moisture              (原 moisture_tex)
#   G = flow_accum            (原 flow_tex)
#   B = latitude_norm         (原 latitude_tex)
#   A = 0（保留，无语义；原先是 sea_ice_fraction，自 SoA 阶段 1 起拆为独立 sea_ice_tex）
#
# vector_atlas_tex (RGBA8 LINEAR, derived_size)
#   RG = ocean_current  (原 ocean_current_tex，[-1,1] mapped from [0,1])
#   BA = wind_field     (原 wind_field_tex，[-1,1] mapped from [0,1])
var height_tex: ImageTexture
var enum_atlas_tex: ImageTexture
var scalar_atlas_tex: ImageTexture
var vector_atlas_tex: ImageTexture
# [river-render-restore 2026-06-19] 河流 SDF 专用 L8 纹理（derived_size）。
# scalar_atlas 退役后 flow 通道断供，has_river 链生成的 flow_buffer 从未上传 GPU →
# 河流在主地图完全不可见。这里把 flow_buffer 单独编码成一张轻量 L8 纹理重新接回 shader，
# 不复活整张 scalar_atlas（moisture/lat 仍走 LUT/uv）。bake_world 烘焙一次，之后不变。
var flow_tex: ImageTexture
# [water-depth-tex 2026-06-26] 海/湖统一水深 R8 纹理（derived_size，与 height/biome 同 uv）。
# 主水体 shader 按它做深浅着色（深海蓝 / 浅滩青 / 湖心暗），单次采样取代旧海洋邻域 + 湖泊多半径。
# bake_world 烘焙一次，之后不变；null 时 shader 回退旧逐邻域估算。
var water_depth_tex: ImageTexture
# [terrain-normal-bake 2026-06-25] 生成期烘焙的"总体地形法线"（RG8: nx,ny，hm_size）。
# 地形静态 → 运行期 shader 1 次采样拿宏观山脉走向，替代每帧宽半径 4-tap；细节法线运行期按
# biome/性能档叠。bake_world 烘焙一次，之后不变；与 height_tex 共用 uv。
var terrain_normal_tex: ImageTexture
# [terrain-horizon 2026-07-03] 生成期烘焙 8 方向 horizon angle（RGBA8，每通道拆 high/low
# nibble 承载两个方向）。运行期按 TOD 太阳方位插值，只遮蔽 direct lighting；移动端可为空。
var terrain_horizon_tex: ImageTexture
# 兼容旧调试/数据通道的海冰 R8 纹理。主地图海冰视觉不采样它；
# sea_ice_atlas_upload 默认不再注册。
var sea_ice_tex: ImageTexture
# Per-pixel weather field for WeatherLayer. Updated only after weather ticks.
var weather_field_tex: ImageTexture
# 主地图动态状态 atlas。低频/dirty 更新，shader 用它替代纯纬度派生温度/雪盖。
var dynamic_cell_atlas_tex: ImageTexture
# Ecology visual atlas, updated with the same low-frequency dirty path as
# dynamic_cell_atlas_tex.
var ecology_visual_atlas_tex: ImageTexture
# ─── map-visual-overhaul-v1：地图视觉重构新增 ImageTexture ───
# 主地图 fragment 严格 ≤8 sample 的"邻域平滑 / 海冰生命化"全部接到这里。
# 任何"看起来需要邻域"的视觉都由 baker 端预烘到这些 atlas，shader 单点采样。
var dyn_atlas_smooth_tex: ImageTexture     # RGBA8 LINEAR, derived_size（与 dynamic_cell_atlas 同尺寸）
var ice_state_tex: ImageTexture             # R8 LINEAR, derived_size（每像素 = sea_ice_frac × 255）
# Systemic Ocean Currents：独立的上升流 R8 纹理。仅调试可视化（F6 扩展）消费；
# 主视觉路径不需要它。bake_world 与 rebake_ocean_currents 都会同步更新。
var upwelling_tex: ImageTexture
# v10.noise-pack：共享 tileable 噪声包（256×256 RGBA8，filter_linear_mipmap + repeat_enable）。
# R=raw value noise；G/B/A=2/3/4 octave fBM 预积分。world_map 的 fbm(p,N)
# 全局降为 1 次 texture fetch，由 MapBaker lazy 生成，跨 world 实例共享同一张 ImageTexture。
var noise_tex: ImageTexture

# ─── Cell-index indirection（province-ID 间接寻址，feature-flag 可回退）───────
# 把"hex 内恒定"的视觉 atlas 改为"静态 cell 索引图 + per-cell LUT"间接寻址，
# 让 shader 自己做 pixel→cell 解析，把 fan-out 目标从 n_pix 压到 n_cells。
#
# map_index_atlas（复用 enum_atlas_tex 字段）：RGBA8 NEAREST，derived_size。
#   R=biome，G/B=cell.index 低/高字节，A=landform；map 外像素写哨兵 0xFFFF。

# enum_lut / dyn_lut / eco_lut：per-cell LUT 纹理（lut_dims 网格，NEAREST）。
#   enum_lut(RGB8)=biome/veg/cover；dyn_lut(RGBA8)=temp/wet/snow/(ice|vitality)；
#   eco_lut(RGBA8)=foliage/stress/transition/growth。更新=写 n_cells texel + 一次 update。
# lut_dims：(lut_w, lut_h)，lut_w=min(n_cells, 2048)，lut_h=ceil(n_cells/lut_w)。
var enum_lut_tex: ImageTexture
var dyn_lut_tex: ImageTexture
var eco_lut_tex: ImageTexture
# weather_lut（cloud-from-field 2026-06-20）：per-cell 天气场 LUT，RGBA8 NEAREST，lut_dims。
#   R=weather_type，G=intensity，B=cloud，A=vapor。由 encode_cell_luts 与 enum/dyn/eco 同批
#   产出（C++ 优先，GDScript fallback），weather_overlay.gdshader 经 cell-index 间接寻址逐格
#   采样驱动云分布——天气云不再用 fronts 椭圆摘要，而是精确对应 HexCell.weather_*。
var weather_lut_tex: ImageTexture
var weather_lut_prev_tex: ImageTexture  # 上一仿真帧 LUT(渲染帧间插值减两次更新间横跳)
var weather_lut_update_usec: int = 0  # LUT 上次更新时刻(weather_layer 据此与 LUT 节奏对齐推进 weather_lerp)
var lut_dims: Vector2i = Vector2i.ZERO

# v9.perf：每像素 → HexCell 引用 lookup（W*H 个，与 derived_size 严格对齐）。
# 在 _bake_height_biome_moisture 里第一遍 warp + cube_round 时顺手填好；之后
# rebake_*_only / rebake_biome_axes_only 不再需要重跑 noise 与 cube_round —— 
# 只是 O(W*H) 的纯 array indexing + cell 字段读取（~2-3ms vs 重跑的 ~25-30ms）。
# 注意：hex_size 改变会让 lookup 失效；MapBaker.bake_world 重跑时会重建。
var pixel_to_cell_lookup: Array = []  # Array[HexCell]，null 表示该像素落在 map 外

# Daily-sim perf opt：water cell → PackedInt32Array(像素 index 列表) 反向索引。
# 在 _bake_height_biome_moisture 的同一次循环里，pixel_to_cell_lookup 写入时
# 顺带按 cell 分桶。`bake_sea_ice_fraction_only` 据此**只遍历水格像素**，把
# 全图 620k 像素循环降到 ~180k（水占 ~30%）；同时按 cell 量化字节后批量写入，
# 而不是每像素重新读取 sea_ice_fraction → clampf → round。
# - key   : HexCell 引用（仅 _is_water(terrain) 的格子；陆地恒 0 不需要写入像素）
# - value : PackedInt32Array，元素是该 cell 在 derived buffer 中覆盖的像素 1D index
# 当 bake_world 重跑时连同 pixel_to_cell_lookup 一起重建；其它路径只读。
var water_cell_pixel_lists: Dictionary = {}

# Daily-sim perf opt 阶段 P：**所有 cell**（含陆地） → PackedInt32Array 反向索引。
# 与 water_cell_pixel_lists 同源构建（_bake_height_biome_moisture 的同一桶式分发），
# 但覆盖整图所有非空 cell。给 rebake_cover_tex_only / rebake_vegetation_tex_only 用——
# weather_system 每日翻 cover 的 cell 一般 < 30 个，而当前 fast path 仍需扫 614k 像素
# 拷贝所有 byte。改造后逐 cell 比对 byte 缓存，只写真正变化的 cell 像素列表，典型日
# 像素操作量从 614k 降到 < 5k（命中率 ~99% 跳过），与 ice_bake 完全同构。
# - key   : HexCell 引用（包括陆地）
# - value : PackedInt32Array，该 cell 在 derived buffer 中覆盖的像素 1D index
# bake_world 重跑时与 pixel_to_cell_lookup 同步重建。
var cell_pixel_lists: Dictionary = {}

# P1：cell_pixel_lists 的 SoA 形态（CSR 布局）。
# 给 dynamic_visual_atlas 4 个 phase 的 _pack_csr_for_cells 走 fast path 用，
# 消除 Dictionary[HexCell→PackedInt32Array] 的 K 次 has() + get() 哈希查找。
#
# 布局（与 cell.index 严格对齐，长度 = map.cell_count()）：
#   cell_first_px_arr[cell_idx]    : 该 cell 在 flat_px_indices_arr 里的起始偏移
#                                    (-1 = 该 cell 无像素 / map 外)
#   cell_px_count_arr[cell_idx]    : 该 cell 拥有的像素数量（0 = 无像素）
#   flat_px_indices_arr            : 所有 cell 的像素 idx 串接（按 cell_idx 顺序）
#
# 与 Dictionary 版本同源构建（_bake_height_biome_moisture 同一桶分发）；
# Dict 版本仍保留——给 finalize / rebake_cover_tex_only 等仍按 cell_key 查的
# 旧路径继续跑。water_cell_pixel_lists 在 production 代码里始终为空（仅测试用），
# 因此不为它构建 SoA 镜像。
var cell_first_px_arr: PackedInt32Array = PackedInt32Array()
var cell_px_count_arr: PackedInt32Array = PackedInt32Array()
var flat_px_indices_arr: PackedInt32Array = PackedInt32Array()

# ─── 采样接口（给 MapGenerator 在 hex 中心采样用） ────────────────────────

func sample_height(world_pos: Vector2) -> float:
	return _bilinear_float(height_buffer, hm_size, world_pos)

func sample_flow(world_pos: Vector2) -> float:
	return _bilinear_float(flow_buffer, derived_size, world_pos)

func sample_moisture(world_pos: Vector2) -> float:
	return _bilinear_float(moisture_buffer, derived_size, world_pos)

func sample_biome(world_pos: Vector2) -> int:
	return _sample_byte(biome_buffer, world_pos)

# Milestone 2：植被 / 覆盖物采样接口，调用方语义与 sample_biome 完全一致。
func sample_vegetation(world_pos: Vector2) -> int:
	return _sample_byte(vegetation_buffer, world_pos)

func sample_cover(world_pos: Vector2) -> int:
	return _sample_byte(cover_buffer, world_pos)

# Milestone 3：盛行风采样（RG8 解码回 [-1, 1]）。给 WeatherSystem 推进锋面用。
func sample_wind(world_pos: Vector2) -> Vector2:
	if wind_field_buffer.is_empty():
		return Vector2.ZERO
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	var idx := (y * W + x) * 2
	if idx + 1 >= wind_field_buffer.size():
		return Vector2.ZERO
	var r: float = float(wind_field_buffer[idx]) / 255.0 * 2.0 - 1.0
	var g: float = float(wind_field_buffer[idx + 1]) / 255.0 * 2.0 - 1.0
	return Vector2(r, g)

# 任务 7：洋流采样（RG8 解码回 [-1, 1]）。给 MapGenerator._compute_ocean_currents 将
# per-pixel 场折返到 per-cell（HexCell.ocean_current）。也可给将来的逻辑系统直读。
func sample_ocean_current(world_pos: Vector2) -> Vector2:
	if ocean_current_buffer.is_empty():
		return Vector2.ZERO
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	var idx := (y * W + x) * 2
	if idx + 1 >= ocean_current_buffer.size():
		return Vector2.ZERO
	var r: float = float(ocean_current_buffer[idx]) / 255.0 * 2.0 - 1.0
	var g: float = float(ocean_current_buffer[idx + 1]) / 255.0 * 2.0 - 1.0
	return Vector2(r, g)

# Systemic Ocean Currents：上升/下沉流采样（R8 解码回 [-1, 1]）。
# 语义与 ocean_upwelling_buffer 字段注释一致。
func sample_upwelling(world_pos: Vector2) -> float:
	if ocean_upwelling_buffer.is_empty():
		return 0.0
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	var idx := y * W + x
	if idx >= ocean_upwelling_buffer.size():
		return 0.0
	return (float(ocean_upwelling_buffer[idx]) / 255.0) * 2.0 - 1.0

# 任务 7：打包所有 is_water cell 的 ocean_current 为 PackedVector2Array（按主存储遥历顺序）。
# 供渲染层纹理化（编码为 RG16F）上传给 water shader 做流线 scroll 使用。
#
# 结果顺序与 map.all_cells() 一致；陆地 cell 对应的项为 Vector2.ZERO。
func get_ocean_current_field(map) -> PackedVector2Array:
	var arr := PackedVector2Array()
	if map == null:
		return arr
	var cells: Array = map.all_cells()
	arr.resize(cells.size())
	for i in range(cells.size()):
		var cell = cells[i]
		arr[i] = cell.ocean_current if cell != null else Vector2.ZERO
	return arr

func _sample_byte(buf: PackedByteArray, world_pos: Vector2) -> int:
	if buf.is_empty():
		return 0
	var uv := _world_to_uv(world_pos)
	var W := derived_size.x
	var H := derived_size.y
	var x := clampi(int(round(uv.x * float(W - 1))), 0, W - 1)
	var y := clampi(int(round(uv.y * float(H - 1))), 0, H - 1)
	return int(buf[y * W + x])

# ─── 内部 ─────────────────────────────────────────────────────────────────

func _world_to_uv(world_pos: Vector2) -> Vector2:
	if world_bounds.size.x < 0.001 or world_bounds.size.y < 0.001:
		return Vector2(0.5, 0.5)
	var sample_x := world_pos.x
	if wrap_period_x > 0.0001:
		sample_x = fposmod(sample_x, wrap_period_x)
	var u := (sample_x - world_bounds.position.x) / world_bounds.size.x
	var v := (world_pos.y - world_bounds.position.y) / world_bounds.size.y
	return Vector2(clampf(u, 0.0, 1.0), clampf(v, 0.0, 1.0))

func _bilinear_float(buf: PackedFloat32Array, size: Vector2i, world_pos: Vector2) -> float:
	if buf.is_empty() or size.x <= 0 or size.y <= 0:
		return 0.0
	var uv := _world_to_uv(world_pos)
	var W := size.x
	var H := size.y
	var fx := uv.x * float(W - 1)
	var fy := uv.y * float(H - 1)
	var x0 := clampi(int(floor(fx)), 0, W - 1)
	var y0 := clampi(int(floor(fy)), 0, H - 1)
	var x1 := mini(x0 + 1, W - 1)
	var y1 := mini(y0 + 1, H - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var v00 := buf[y0 * W + x0]
	var v10 := buf[y0 * W + x1]
	var v01 := buf[y1 * W + x0]
	var v11 := buf[y1 * W + x1]
	var v0 := lerpf(v00, v10, tx)
	var v1 := lerpf(v01, v11, tx)
	return lerpf(v0, v1, ty)
