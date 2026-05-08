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
# 字段：{ "season": int, "temperature": float, "moisture": float, "snow_cover": float,
#         "biome": int, "landform": int, "vegetation": int, "cover": int,
#         # Milestone 3：天气子系统每"日"覆写下面两个字段（CLEAR=0, intensity=0 表示无天气）
#         "weather": int, "weather_intensity": float }
# 注意：weather 临时调整 temperature / moisture，但不写回 base_*；
# 季节切换 refresh_seasonal 重新从 base_moisture 出发，weather 不会污染长期生态记忆。
var current_state: Dictionary = {}

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

# --- 构造 ---
func _init(p_q: int = 0, p_r: int = 0) -> void:
	q = p_q
	r = p_r
	s = -p_q - p_r

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
	var sc: float = float(current_state.get("snow_cover", 0.0))
	if season == 3 and sc > 0.6:
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
