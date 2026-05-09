# hex_cell.gd
# 单个六边形地块的数据容器
# 使用 cube 坐标系（q, r, s），约束: q + r + s == 0

class_name HexCell

# --- Cube 坐标 ---
var q: int = 0
var r: int = 0
var s: int = 0  # 始终等于 -q - r，冗余存储以方便邻居计算

# --- 地形（兼容轴；Milestone 1 起为 derived 字段） ---
# 仍是 baker / shader / 老 _apply_*_pass 的工作字段，
# 但语义上已被 landform / vegetation / cover 三轴取代。
# MapGenerator 在每个生成阶段末尾调用 _sync_axes_from_terrain
# 把三轴从 terrain + 上下文派生出来，UI 与新代码读三轴。
var terrain: TerrainType.TERRAIN = TerrainType.TERRAIN.OCEAN

# --- Milestone 1：拆分单轴 TerrainType 为三个独立轴 ---
# landform   ：仅描述海拔/海陆几何（PLAIN/HILL/MOUNTAIN/COAST/...）
# vegetation ：植被独立判断（HILL 上面可以是 TEMPERATE_DECIDUOUS）
# cover      ：临时/永久覆盖物（SNOW/GLACIER/SEA_ICE/...）
var landform: int = LandformType.LF.OCEAN
var vegetation: int = VegetationType.VEG.NONE
var cover: int = CoverType.CV.NONE

# --- 地貌附加信息 ---
var has_river: bool = false        # 是否有河流流经
var elevation: float = 0.0        # 归一化高度 [0, 1]，用于生成时的中间量
var moisture: float = 0.5         # 归一化湿度 [0, 1]，由生成器写入，烘焙时上采样到湿度纹理
# Phase 13：标记初始 elevation pass 阶段被强制下沉的"湖泊种子"，让 pit-fill 跳过这些 cell
var is_lake_seed: bool = false
# Phase 14：火山地标 flag（不参与 terrain 枚举，但 shader 端额外加红光烟柱）
var has_volcano: bool = false

# --- 大气候系统（Phase 2 + 5 + 8） ---
# base_moisture：生成阶段最终敲定的"年均湿度基线"（包含 coastal boost）。
# 季节湿度刷新会从这里出发，叠加当季雨影/季风，避免 moisture 跨季累积漂移。
# Phase 8：每年由 refresh_yearly 微调，让长期 FOREST → +base_moisture，长期 DESERT → -。
var base_moisture: float = 0.5
# base_terrain：第一次定型的"年均"地形，给季节重决策做参考（譬如雪地的真正持久性）。
var base_terrain: TerrainType.TERRAIN = TerrainType.TERRAIN.OCEAN
# Milestone 1：年均基线的三轴快照，季节波动从这里出发
var base_landform: int = LandformType.LF.OCEAN
var base_vegetation: int = VegetationType.VEG.NONE
# current_state：当季实时气候数据，由 MapGenerator.refresh_seasonal 写入。
# 其他系统（农业 / 移动 / AI）通过它读取"现在能不能种地"。
# 字段（Fast-tick perf opt C 之后）：{ "season": int, "biome": int,
#         "landform": int, "vegetation": int, "cover": int,
#         # Milestone 3：天气子系统每"日"覆写下面两个字段（CLEAR=0, intensity=0 表示无天气）
#         "weather": int, "weather_intensity": float }
# 注意：temperature / moisture / snow_cover / temp_baseline / temp_season_offset /
#       temp_30d_mean / temp_365d_mean / temp_dev_from_annual 已升级为 HexCell 的
#       强类型成员（见下），不再走字典（避免 GDScript 字典装箱/类型擦除的热路径开销）。
var current_state: Dictionary = {}

# Fast-tick perf opt (C)：fast-tick 热路径高频读写字段升级为强类型成员，
# 避免 current_state 字典的 hash 查找 + Variant 装箱开销。
# moisture 已在上方声明为 float（第 27 行）；下面是从字典迁移过来的 7 个。
var temperature: float = 0.0
var snow_cover: float = 0.0
# temp_baseline / temp_season_offset：refresh_climate_daily Pass A/B 写入，
# temperature_breakdown 调试字典与 UI 面板读取。命名去掉旧字典键的前导下划线。
var temp_baseline: float = 0.0
var temp_season_offset: float = 0.0
# 30/365 日滑动均值 + 偏离（Emergent Climate Coupling EMA）
var temp_30d_mean: float = 0.0
var temp_365d_mean: float = 0.0
var temp_dev_from_annual: float = 0.0
# Fast-tick perf opt (C)：EMA 首次初始化标志。旧版本用 -1.0 哨兵加字典查找
# 判断"是否首次"；升级为强类型 float 后 0.0 是合法气候值无法再作哨兵，
# 改用独立 bool。首次 refresh_climate_daily 写入后置 true。
var _ema_initialized: bool = false

# Phase 8：过去若干季的 biome 快照（环形缓冲），给 refresh_yearly 评分用。
# 长度固定 HISTORY_LEN = 8（≈ 2 年）。生命周期：每季 push 当前 terrain。
# Milestone 1：vegetation_history 平行环形缓冲，新代码评分用真实植被轴。
const HISTORY_LEN := 8
var biome_history: PackedByteArray = PackedByteArray()
var vegetation_history: PackedByteArray = PackedByteArray()
var _history_idx: int = 0
var _veg_history_idx: int = 0

# --- Milestone 4：植被生命值 + 演替计数器 ---
# vegetation_vitality ∈ [0, 1]：当前植被对当地气候的"健康度"。
#   1.0 = 完美贴合，会向 NEXT_RICHER 演替；0.0 = 严重不适，会向 NEXT_HARSHER 退化。
# _vitality_low_streak ：连续多少天 vitality < LOW_THRESHOLD（用于触发退化）。
# _vitality_high_streak：连续多少天 vitality > HIGH_THRESHOLD（用于触发升级）。
# 演替触发后两个 streak 都 reset 为 0。
var vegetation_vitality: float = 0.7
var _vitality_low_streak: int = 0
var _vitality_high_streak: int = 0

func push_biome_history(biome: int) -> void:
	if biome_history.size() < HISTORY_LEN:
		biome_history.resize(HISTORY_LEN)
		# 第一次 push 时把整个环形缓冲填同一个值，避免初期 score 偏差
		for i in range(HISTORY_LEN):
			biome_history[i] = biome & 0xFF
	biome_history[_history_idx] = biome & 0xFF
	_history_idx = (_history_idx + 1) % HISTORY_LEN

func push_vegetation_history(veg: int) -> void:
	if vegetation_history.size() < HISTORY_LEN:
		vegetation_history.resize(HISTORY_LEN)
		for i in range(HISTORY_LEN):
			vegetation_history[i] = veg & 0xFF
	vegetation_history[_veg_history_idx] = veg & 0xFF
	_veg_history_idx = (_veg_history_idx + 1) % HISTORY_LEN

# --- 通行性（由 terrain 决定，生成后缓存于此供外部快速读取）---
var passable_land: bool = false
var passable_sea: bool = false

# --- 任务 7：洋流向量（逻辑层）─────────────────────────────────
# 仅对 is_water == true 的 cell 有意义；陆地 cell 维持 Vector2.ZERO。
# 来源：MapGenerator._compute_ocean_currents 在 bake_world 后从
#       WorldData 的高分辨率 ocean_current_buffer 采样出来的 per-cell 值。
# 含义：向量长度 ≈ 洋流强度 [0, 1]；方向为归一化后的水平分量。
# 用途：
#   - 渲染层：main.gd 把打包后的场编码为 RG16F 纹理传给 water shader 做流线 scroll
#   - 将来的逻辑层：鱼群 / 航运 / 大陆影响扩散等 AI 直接读 cell.ocean_current
var ocean_current: Vector2 = Vector2.ZERO

# --- 地形扰动后的实际风场（per-cell；六边形尺度） ───────────────────────────
# 由 MapGenerator._compute_terrain_perturbed_wind 在 bake_world 后写入。
# x/y 含义同 WindBelt.wind_at（屏幕坐标系：+x=东，+y=南），但**未归一化**：
# 长度 = 该 cell 受地形扰动后的相对风速（理论 [0, ~2]），陆地摩擦衰减、山脉
# 阻挡降速 + 转向、山脊伯努利加速、海岸海陆风加速等局地效应都已并入。
# 用途：
#   - Data Overlay 的 WIND_DIR / WIND_SPEED 通道直接读它，让"风速/风向"图例
#     呈现真实的山脉绕流形态（而不是单调的纬向带）
#   - 未来局地天气推进、火灾蔓延、传播等系统的风源
# 不影响：
#   - WorldData.wind_field_buffer 仍是 ny-only 的"纬度风基线"，weather_system
#     的锋面 advection 与 ocean_current 的 Ekman 偏转继续读它（保持地球级
#     纬向洋流 / 大气环流的稳定形态，不被局地地形噪声污染）
var wind_vector: Vector2 = Vector2.ZERO

# --- Systemic Ocean Currents：上升流与热输运 ─────────────────────────────
# upwelling_strength ∈ [-1, 1]：
#   正值 = 上升流（沿岸 Ekman 抽吸、富营养），对下游 REEF/KELP/PELAGIC_BLOOM 放宽阈值；
#   负值 = 下沉流（高纬冷咸水汇点），当前主要给海冰 pass 做冷源修正。
#   仅对 is_water cell 有意义；陆地维持 0。由 MapGenerator._compute_ocean_currents
#   从 WorldData.ocean_upwelling_buffer 采样得到。
var upwelling_strength: float = 0.0

# --- Physical Wind & Ocean Circulation（物理化大气/海洋环流；hex 域求解） ─────
# 本块字段由 MapBaker 物理化求解器在每轮洋流烘焙时写入，仅当
# ClimateProfile.physical_circulation_enabled = true 时被填充；关闭时维持 0
# 不影响下游兜底逻辑。所有字段都是"可观测中间量"，方便 overlay 调试。
#
# slp ∈ [-1, 1] 归一化的海平面气压偏差（sea level pressure proxy）。
#   正值 = 高压（副热带 / 大陆冬季内陆），负值 = 低压（赤道 / 副极地 / 大陆夏季内陆）。
#   计算：纬度基线（赤道-/副热带+/副极地-/极地+）+ 海陆性 × 季节调制 + 邻域扩散平滑。
#   下游：物理化风场用 -∇slp 当压力梯度风源项。
var slp: float = 0.0
# wind_speed：物理化风速（相对量级）。与 wind_vector 配对：
#   wind_vector 单位向量给方向，wind_speed 给强度。weather_system advection
#   与 ψ 求解的风应力 τ ≈ wind_speed² × wind_vector 都需要它。
var wind_speed: float = 0.0
# wind_stress_curl：风应力旋度 curl(τ)。海盆 ψ 求解的源项；overlay 调试可视化用。
#   仅水域 cell 有意义，陆地维持 0。
var wind_stress_curl: float = 0.0
# ocean_psi：海盆流函数 ψ。由 SOR 求解 ∇²ψ = -curl(τ)/β（β-plane Stommel 简化）；
#   边界条件：陆地 ψ = 0。回算：u = -∂ψ/∂y, v = ∂ψ/∂x → cell.ocean_current。
#   仅水域 cell 有意义；overlay 等高线调试可视化用。
var ocean_psi: float = 0.0

# temperature_transport_anomaly：
#   由 _apply_ocean_heat_transport_pass 写入的"洋流输运带来的温度偏差"，
#   单位与 current_state.temperature 一致（相对于该 cell 纬度基线温度）。
#   水 cell：自身沿 -ocean_current 方向回溯上游温度混合后的偏差；
#   陆地 cell：沿岸水 cell 异常按 dot(邻接方向, current) 加权平均后的注入值。
#   供海冰 pass / F7 调试可视化 / 未来玩法读取。
var temperature_transport_anomaly: float = 0.0

# air_mass_temp_anomaly：
#   由风温耦合系统写入的"气团输运带来的温度偏差"，
#   单位与 current_state.temperature 一致（相对于该 cell 纬度基线温度）。
#   沿 -wind_vector 方向回溯上游气团温度混合后的偏差，
#   影响气温、海冰、植被、天气系统等气候要素。
#   对称复刻洋流热输运的设计模式。
var air_mass_temp_anomaly: float = 0.0

# --- Emergent Climate Coupling 字段（Phase E） ────────────────────────
# sea_ice_fraction ∈ [0, 1]：水体 cell 的当前海冰覆盖度（半快半慢量）。
#   归入"慢层 / map layer"，由 _apply_sea_ice_daily_pass 每日**增量**推进。
#   跨过 ClimateProfile.sea_ice_terrain_threshold 时翻转 cell.terrain，
#   跌回 threshold - hysteresis 时翻回 base_terrain。陆地 cell 始终为 0。
var sea_ice_fraction: float = 0.0

# soil_moisture / vegetation_growth_pressure：天气 → 慢层反馈缓冲字段。
#   由 _apply_weather_to_map_feedback_pass 在每日末以**很小权重**（≤ 0.5%）
#   累加，由 refresh_seasonal 在季末消费并按 feedback_decay 衰减。
#   它们使"连下三个月雨"等长期天气累积可以缓慢影响 base_moisture / 演替判定，
#   但当天的雨绝不直接重写 base_*，从而维持快慢双时间尺度。
var soil_moisture: float = 0.0
var vegetation_growth_pressure: float = 0.0

# temperature_breakdown：调试用的温度分解字典（仅在选中地块面板查看时填充）。
#   key ∈ {baseline, season, albedo, coastal, landform}，值单位与 temperature 一致。
#   非选中 cell 维持空字典，避免热路径开销。
var temperature_breakdown: Dictionary = {}

# --- 构造 ---
func _init(p_q: int = 0, p_r: int = 0) -> void:
	q = p_q
	r = p_r
	s = -p_q - p_r

# Fast-tick perf opt (C)：旧存档/老路径迁移。若 current_state 字典中仍带有
# 已迁移为强类型成员的键，则搬到成员变量后从字典中 erase，避免双写/双读。
# 新代码永远不写这些键；该方法只是一次性的兜底，让老存档 / 调试流程也能平滑切过去。
func _migrate_typed_fields_from_dict() -> void:
	if current_state.is_empty():
		return
	if current_state.has("temperature"):
		temperature = float(current_state["temperature"])
		current_state.erase("temperature")
	if current_state.has("moisture"):
		moisture = float(current_state["moisture"])
		current_state.erase("moisture")
	if current_state.has("snow_cover"):
		snow_cover = float(current_state["snow_cover"])
		current_state.erase("snow_cover")
	if current_state.has("_temp_baseline"):
		temp_baseline = float(current_state["_temp_baseline"])
		current_state.erase("_temp_baseline")
	if current_state.has("_temp_season_offset"):
		temp_season_offset = float(current_state["_temp_season_offset"])
		current_state.erase("_temp_season_offset")
	if current_state.has("temp_30d_mean"):
		temp_30d_mean = float(current_state["temp_30d_mean"])
		current_state.erase("temp_30d_mean")
	if current_state.has("temp_365d_mean"):
		temp_365d_mean = float(current_state["temp_365d_mean"])
		current_state.erase("temp_365d_mean")
	if current_state.has("temp_dev_from_annual"):
		temp_dev_from_annual = float(current_state["temp_dev_from_annual"])
		current_state.erase("temp_dev_from_annual")

# --- 坐标工具 ---
func cube_coords() -> Vector3i:
	return Vector3i(q, r, s)

func set_from_cube(coords: Vector3i) -> void:
	q = coords.x
	r = coords.y
	s = coords.z

# --- 通行性更新（设置 terrain 后调用）---
func apply_terrain(t: TerrainType.TERRAIN) -> void:
	terrain = t
	passable_land = TerrainType.is_passable_land(t)
	passable_sea  = TerrainType.is_passable_sea(t)

# --- Phase 5：季节通行性 hook ---
# 雪地 + 冬季 → 不可通行；其他维持 base 通行性。
# 后续可以扩展：洪泛季节河谷不可通行、沙漠夏季消耗翻倍 etc.
# season: 0=春 1=夏 2=秋 3=冬
func is_passable_in_season(season: int) -> bool:
	# 永久 SNOW 地块本来就不可通行
	if not passable_land:
		return false
	# 冬季的 TUNDRA / 高山雪盖按当季 snow_cover 判定
	# Fast-tick perf opt (C)：snow_cover 已升级为强类型成员，直接读，不再走字典。
	if season == 3 and snow_cover > 0.6:
		return false
	return true

# --- 调试输出 ---
# 注意：不要重写 Object.to_string()（GDScript 引擎的 _to_string 才是正确钩子）
func describe() -> String:
	return "HexCell(%d,%d,%d) terrain=%s river=%s" % [
		q, r, s,
		TerrainType.terrain_name(terrain),
		str(has_river)
	]

func _to_string() -> String:
	return describe()
