# hex_cell.gd
# 单个六边形地块的数据容器
# 使用 cube 坐标系（q, r, s），约束: q + r + s == 0
#
# ─── PR-2.3 HexCell Facade Migration（master 手册 §3.10.3） ──────────────
# 目标：cell.<hot_field> 的语法保持不变，但底层走 DCWorld read_f32/write_f32。
# 完整状态：PR-2.3 分三阶段（B3b 阶段 3 已收工 2026-05-17）：
#   PR-2.3a [DONE]：facade 基础设施（_world 绑定 + use_facade flag + bind_world）。
#                    默认 _facade_enabled=false，向后兼容。
#   PR-2.3b [DONE]：21 个热字段（climate + weather + ocean）加 property setter/getter。
#                    默认 use_hexcell_facade=true 后转发到 world。
#   PR-2.3c [DONE]：默认开启 facade + B3b 植被动力学 5 字段下沉
#            （vegetation_vitality / vitality_low_streak / vitality_high_streak /
#             soil_moisture / vegetation_growth_pressure）→ 移除 map_generator
#            stage_b combined unpack 回灌循环（n_cells×5 字段每帧节省）。
#            实测稳态 wall=0.29ms（目标 ≤ 1.0ms，超额 3.4×），ROI 决策：B3b 收工。
#
# 后续可选项（已 ROI 评估为低优先，**默认不推进**）：
#   - 阶段 4：删除 5 字段的 var 双重存储（_<field>_backing），节省 ~680KB / 17000 cells
#   - 删除 flush_soa_to_cells / rebuild_soa_from_cells（map_data.gd）
#   - 清理冗余 var（如 temperature_breakdown 字典）
#
# 阶段 4 删除前置条件（master 手册 §3.10.4，未来若推进）：
#   1. 1000-tick SAME_SOURCE PASS（Ctrl+F3 触发；阈值 0.05 标量 / 0.01 长期均值）
#   2. ripgrep `cell\.\w+\s*=` 在 hot-loop 文件 = 0（写路径已全部下移到 world）
#   3. ripgrep `flush_soa_to_cells|rebuild_soa_from_cells` 全仓 = 0（仅 git history）

class_name HexCell

# --- Cube 坐标 ---
var q: int = 0
var r: int = 0
var s: int = 0  # 始终等于 -q - r，冗余存储以方便邻居计算

# --- DOTS-native：SoA index（Phase 3a Step 2.1 / B-pragmatic） ───────────────
# 由 MapData._build_indices() 在 bake/regenerate 末尾写入，等同 _cell_index[cell]。
# DCWorld 所有 cell-level component 的 idx 即 cell.index。
#   - hot loop（C++ / GDScript）：直接用 `arr[cell.index]`
#   - cold path（UI/baker/test）：world.read_*(comp_id, cell.index) helper
#   - -1 = 未通过 _build_indices 注册（断言用）
var index: int = -1

# --- PR-2.3a/b：HexCell Facade infrastructure ────────────────────────────
# _world：DCWorld 引用，由 bake_world / 加载存档末尾通过 bind_world() 注入。
#         null 时所有 property setter/getter 走 var fallback 路径，与旧行为完全兼容。
# _world_ext：DCWorldExt（C++）引用，plan/3b-single-read-source 引入。
#         非 null 时 facade 的 read 路径切到 ext.read_f32/i32/u8（直读 C++ slot），
#         结构性消除"C++ flush 与 GDScript-DCWorld SoA 脱钩"类 bug（典型现象：
#         cell.sea_ice_frac 冻结在初始日值，weather/climate/wind/ocean 12 处同款）。
#         为 null（gdext 未编译 / DCWorldExt 未注册）时 fallback 到 _world.read_*，
#         行为 = PR-2.3c 现状，100% 向后兼容。
#         **write 路径仍走 _world**——GDScript-DCWorld → MapData 的 CoW alias
#         从未脱钩；仅 read 切源即可消除问题面。
# _facade_enabled：是否对该 cell 启用 facade（read/write 转发到 world）。
#                  由 ClimateProfile.use_hexcell_facade 全局控制；调试可单 cell 关闭。
var _world = null
var _world_ext = null
var _facade_enabled: bool = false

# PR-2.3b：21 个 facade 字段 → cid 索引常量。bind_world() 时一次性 lookup。
# 顺序与 _COMP_NAMES 严格对齐；新增字段时两边都要补。
const _CID_TEMP                 := 0   # F32  cell.temp
const _CID_MOISTURE             := 1   # F32  cell.moisture
const _CID_SNOW_COVER           := 2   # F32  cell.snow_cover
const _CID_TEMP_BASELINE        := 3   # F32  cell.temp_baseline
const _CID_TEMP_30D             := 4   # F32  cell.temp_30d
const _CID_TEMP_365D            := 5   # F32  cell.temp_365d
const _CID_TEMP_ANOMALY         := 6   # F32  cell.temp_anomaly  (= temp_dev_from_annual)
const _CID_TEMP_SEASON_OFFSET   := 7   # F32  cell.temp_season_offset
const _CID_SEA_ICE_FRAC         := 8   # F32  cell.sea_ice_frac  (= sea_ice_fraction)
const _CID_WEATHER_INTENSITY    := 9   # F32  cell.weather_intensity
const _CID_WEATHER_CLOUD        := 10  # F32  cell.weather_cloud
const _CID_WEATHER_PRECIP       := 11  # F32  cell.weather_precip
const _CID_WEATHER_VAPOR        := 12  # F32  cell.weather_vapor
const _CID_WEATHER_CONVERGENCE  := 13  # F32  cell.weather_convergence
const _CID_WEATHER_INSTABILITY  := 14  # F32  cell.weather_instability
const _CID_AIR_MASS_TEMP_ANOM   := 15  # F32  cell.air_mass_temp_anomaly
const _CID_OCEAN_CURRENT_X      := 16  # F32  cell.ocean_current_x
const _CID_OCEAN_CURRENT_Y      := 17  # F32  cell.ocean_current_y
const _CID_WIND_X               := 18  # F32  cell.wind_x
const _CID_WIND_Y               := 19  # F32  cell.wind_y
const _CID_SLP                  := 20  # F32  cell.slp
const _CID_WIND_SPEED           := 21  # F32  cell.wind_speed
const _CID_UPWELLING_STRENGTH   := 22  # F32  cell.upwelling_strength
const _CID_WEATHER_TYPE         := 23  # U8   cell.weather_type
const _CID_WEATHER_FIELD_INIT   := 24  # U8   cell.weather_field_init  (bool)
const _CID_EMA_INITIALIZED      := 25  # U8   cell.ema_initialized      (bool)
# B3b 阶段 3：植被动力学 5 字段下沉 facade（消除 stage_b combined unpack 回灌）
const _CID_VEG_VITALITY         := 26  # F32  cell.vegetation_vitality
const _CID_VITALITY_LOW_STREAK  := 27  # I32  cell.vitality_low_streak
const _CID_VITALITY_HIGH_STREAK := 28  # I32  cell.vitality_high_streak
const _CID_SOIL_MOISTURE        := 29  # F32  cell.soil_moisture
const _CID_VEG_GROWTH_PRESSURE  := 30  # F32  cell.vegetation_growth_pressure
const _CID_WEATHER_PREV_TYPE    := 31  # U8   cell.weather_prev_type
const _CID_WEATHER_TARGET_TYPE  := 32  # U8   cell.weather_target_type
const _CID_WEATHER_TRANS_ALPHA  := 33  # F32  cell.weather_transition_alpha
const _CID_VEG_HEAT_STRESS      := 34  # F32  cell.vegetation_heat_stress
const _CID_VEG_DROUGHT_STRESS   := 35  # F32  cell.vegetation_drought_stress
const _CID_VEG_COLD_STRESS      := 36  # F32  cell.vegetation_cold_stress
const _CID_VEG_REGEN_SCORE      := 37  # F32  cell.vegetation_regen_score
const _CID_COUNT                := 38

# StringName 列表（与 _CID_* 同序）。GDScript 4 const + Array 内 StringName
# 字面量是合法 const expression，可以直接用。
const _COMP_NAMES: Array[StringName] = [
	&"cell.temp",
	&"cell.moisture",
	&"cell.snow_cover",
	&"cell.temp_baseline",
	&"cell.temp_30d",
	&"cell.temp_365d",
	&"cell.temp_anomaly",
	&"cell.temp_season_offset",
	&"cell.sea_ice_frac",
	&"cell.weather_intensity",
	&"cell.weather_cloud",
	&"cell.weather_precip",
	&"cell.weather_vapor",
	&"cell.weather_convergence",
	&"cell.weather_instability",
	&"cell.air_mass_temp_anomaly",
	&"cell.ocean_current_x",
	&"cell.ocean_current_y",
	&"cell.wind_x",
	&"cell.wind_y",
	&"cell.slp",
	&"cell.wind_speed",
	&"cell.upwelling_strength",
	&"cell.weather_type",
	&"cell.weather_field_init",
	&"cell.ema_initialized",
	# B3b 阶段 3：植被动力学 5 字段
	&"cell.vegetation_vitality",
	&"cell.vitality_low_streak",
	&"cell.vitality_high_streak",
	&"cell.soil_moisture",
	&"cell.vegetation_growth_pressure",
	&"cell.weather_prev_type",
	&"cell.weather_target_type",
	&"cell.weather_transition_alpha",
	&"cell.vegetation_heat_stress",
	&"cell.vegetation_drought_stress",
	&"cell.vegetation_cold_stress",
	&"cell.vegetation_regen_score",
]

# 每个 cell 持有一份 cid 缓存，size = _CID_COUNT，未注册条目存 -1。
# bind_world() 时一次填充；运行期不变。
#
# _cid_array     : GDScript-DCWorld 这一侧的 cid（StringName = &"cell.xxx"）
#                  → setter 走 _world.write_*(cid, ...) 用它
#                  → ext == null 时 fallback getter 走 _world.read_*(cid, ...) 用它
# _cid_array_ext : DCWorldExt（C++）这一侧的 cid（StringName = &"cell_xxx"，点→下划线）
#                  → ext != null 时 getter 走 _world_ext.read_*(_cid_array_ext[i], idx)
#
# 为什么必须分两份：两边注册表是独立的——schema demo 字段在 GDScript 侧被过滤，
# 在 C++ 端 BIND_TABLE 全量自动注册；且未来任一侧加额外注册都会让 cid 编号错位。
# 不能假设 cid 同步（PR-3b 初版以为同步导致 sea_ice / 雪线读 cid 错位 → 全 0）。
var _cid_array: PackedInt32Array = PackedInt32Array()
var _cid_array_ext: PackedInt32Array = PackedInt32Array()

## 把本 cell 绑定到 DCWorld + 启用 facade。bake_world / load_save 末尾调用一次。
## 调用前必须保证 cell.index 已通过 _build_indices() 写入（>= 0）。
##
## plan/3b-single-read-source：第三参 `world_ext` 是可选的 DCWorldExt 引用。
##   - 传入非 null（且 gdext 已加载）：facade 21 个 getter 切到 ext.read_*；
##     write 路径仍走 world（保持 GDScript-DCWorld → MapData CoW 单链路）。
##   - 传入 null：getter fallback 到 world.read_*，行为 = PR-2.3c 现状。
##   - 旧调用方（两参签名）：world_ext 默认 null，完全兼容。
##
## cid 缓存策略（双数组）：两侧注册表独立 → cid 编号不一定同步。
##   _cid_array     ← world.component_id(&"cell.xxx")           （setter / fallback read 用）
##   _cid_array_ext ← world_ext.component_id(&"cell_xxx")       （ext.read_* 用）
##   cpp_name 一律由 String(gd_name).replace(".", "_") 机械推导——与
##   component_schema.gd 全部 50 条目的命名约定 1:1 对齐（点→下划线无例外）。
##   若 ext 这一侧某字段没有注册（理论上不应发生）→ _cid_array_ext[i] = -1，
##   对应 getter 走 cid >= 0 检查时会回落到 backing 字段，安全降级。
func bind_world(world, enable_facade: bool = false, world_ext = null) -> void:
	_world = world
	_world_ext = world_ext
	_facade_enabled = enable_facade and (world != null) and (index >= 0)
	# 填充 cid 缓存（即使 enable_facade=false 也填，给未来 hot reload 切 true 用）
	if world != null:
		_cid_array.resize(_CID_COUNT)
		_cid_array_ext.resize(_CID_COUNT)
		for i in range(_CID_COUNT):
			var gd_name: StringName = _COMP_NAMES[i]
			_cid_array[i] = world.component_id(gd_name)
			if world_ext != null:
				# 机械点→下划线推导 cpp_name（与 component_schema.gd 全表约定一致）
				var cpp_name: StringName = StringName(String(gd_name).replace(".", "_"))
				_cid_array_ext[i] = int(world_ext.component_id(cpp_name))
			else:
				_cid_array_ext[i] = -1
	else:
		_cid_array = PackedInt32Array()
		_cid_array_ext = PackedInt32Array()

## 解绑（卸载世界 / 重新生成时调用，避免悬空引用）。
func unbind_world() -> void:
	_world = null
	_world_ext = null
	_facade_enabled = false
	_cid_array = PackedInt32Array()
	_cid_array_ext = PackedInt32Array()


func is_facade_enabled() -> bool:
	return _facade_enabled

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
# moisture：归一化湿度 [0, 1]。PR-2.3b facade 化（→ cell.moisture SoA）。
var _moisture_backing: float = 0.5
var moisture: float = 0.5:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_MOISTURE]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_MOISTURE], index)
				return _world.read_f32(cid, index)
		return _moisture_backing
	set(v):
		_moisture_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_MOISTURE]
			if cid >= 0:
				_world.write_f32(cid, index, v)
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

# Fast-tick weather-field cache. WeatherSystem writes these typed members first
# and mirrors them into current_state for existing UI / baker consumers.
# PR-2.3b：8 个 weather 字段 facade 化（→ cell.weather_* SoA + cell.weather_field_init U8）。
var _weather_field_initialized_backing: bool = false
var weather_field_initialized: bool = false:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_FIELD_INIT]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_u8(_cid_array_ext[_CID_WEATHER_FIELD_INIT], index) > 0
				return _world.read_u8(cid, index) > 0
		return _weather_field_initialized_backing
	set(v):
		_weather_field_initialized_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_FIELD_INIT]
			if cid >= 0:
				_world.write_u8(cid, index, 1 if v else 0)
var _weather_type_backing: int = 0
var weather_type: int = 0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_TYPE]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_u8(_cid_array_ext[_CID_WEATHER_TYPE], index)
				return _world.read_u8(cid, index)
		return _weather_type_backing
	set(v):
		_weather_type_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_TYPE]
			if cid >= 0:
				_world.write_u8(cid, index, v)
var _weather_prev_type_backing: int = 0
var weather_prev_type: int = 0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_PREV_TYPE]
			if cid >= 0:
				if _world_ext != null and _cid_array_ext[_CID_WEATHER_PREV_TYPE] >= 0:
					return _world_ext.read_u8(_cid_array_ext[_CID_WEATHER_PREV_TYPE], index)
				return _world.read_u8(cid, index)
		return _weather_prev_type_backing
	set(v):
		_weather_prev_type_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_PREV_TYPE]
			if cid >= 0:
				_world.write_u8(cid, index, v)
var _weather_target_type_backing: int = 0
var weather_target_type: int = 0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_TARGET_TYPE]
			if cid >= 0:
				if _world_ext != null and _cid_array_ext[_CID_WEATHER_TARGET_TYPE] >= 0:
					return _world_ext.read_u8(_cid_array_ext[_CID_WEATHER_TARGET_TYPE], index)
				return _world.read_u8(cid, index)
		return _weather_target_type_backing
	set(v):
		_weather_target_type_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_TARGET_TYPE]
			if cid >= 0:
				_world.write_u8(cid, index, v)
var _weather_transition_alpha_backing: float = 1.0
var weather_transition_alpha: float = 1.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_TRANS_ALPHA]
			if cid >= 0:
				if _world_ext != null and _cid_array_ext[_CID_WEATHER_TRANS_ALPHA] >= 0:
					return _world_ext.read_f32(_cid_array_ext[_CID_WEATHER_TRANS_ALPHA], index)
				return _world.read_f32(cid, index)
		return _weather_transition_alpha_backing
	set(v):
		_weather_transition_alpha_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_TRANS_ALPHA]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _weather_intensity_backing: float = 0.0
var weather_intensity: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_INTENSITY]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_WEATHER_INTENSITY], index)
				return _world.read_f32(cid, index)
		return _weather_intensity_backing
	set(v):
		_weather_intensity_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_INTENSITY]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _weather_cloud_backing: float = 0.0
var weather_cloud: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_CLOUD]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_WEATHER_CLOUD], index)
				return _world.read_f32(cid, index)
		return _weather_cloud_backing
	set(v):
		_weather_cloud_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_CLOUD]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _weather_precip_backing: float = 0.0
var weather_precip: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_PRECIP]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_WEATHER_PRECIP], index)
				return _world.read_f32(cid, index)
		return _weather_precip_backing
	set(v):
		_weather_precip_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_PRECIP]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _weather_vapor_backing: float = 0.0
var weather_vapor: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_VAPOR]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_WEATHER_VAPOR], index)
				return _world.read_f32(cid, index)
		return _weather_vapor_backing
	set(v):
		_weather_vapor_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_VAPOR]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _weather_instability_backing: float = 0.0
var weather_instability: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_INSTABILITY]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_WEATHER_INSTABILITY], index)
				return _world.read_f32(cid, index)
		return _weather_instability_backing
	set(v):
		_weather_instability_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_INSTABILITY]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _weather_convergence_backing: float = 0.0
var weather_convergence: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_CONVERGENCE]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_WEATHER_CONVERGENCE], index)
				return _world.read_f32(cid, index)
		return _weather_convergence_backing
	set(v):
		_weather_convergence_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WEATHER_CONVERGENCE]
			if cid >= 0:
				_world.write_f32(cid, index, v)

# Fast-tick perf opt (C)：fast-tick 热路径高频读写字段升级为强类型成员，
# 避免 current_state 字典的 hash 查找 + Variant 装箱开销。
# moisture 已在上方声明为 float（第 27 行）；下面是从字典迁移过来的 7 个。
# PR-2.3b：temperature / snow_cover / temp_baseline / temp_season_offset /
#          temp_30d_mean / temp_365d_mean / temp_dev_from_annual facade 化。
var _temperature_backing: float = 0.0
var temperature: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_TEMP], index)
				return _world.read_f32(cid, index)
		return _temperature_backing
	set(v):
		_temperature_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _snow_cover_backing: float = 0.0
var snow_cover: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_SNOW_COVER]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_SNOW_COVER], index)
				return _world.read_f32(cid, index)
		return _snow_cover_backing
	set(v):
		_snow_cover_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_SNOW_COVER]
			if cid >= 0:
				_world.write_f32(cid, index, v)
# Phase 3c：积雪累积。
# accumulated_snow_days：BLIZZARD 命中天数计数器（>=0）。每个有效降雪日 +1，
#   温度高于 0.30（约 -2°C）时反向衰减（实际 -1）。
# pre_snow_cover：被 SNOW 替换前的原 cover（CoverType.CV）；融化后恢复。-1 表示未触发过。
# 阈值：accumulated_snow_days >= SNOW_ACCUM_DAYS_REQ（3）时正式把 cover 升为 SNOW；
# accumulated_snow_days <= 0 且 cover==SNOW 时融化恢复 pre_snow_cover。
var accumulated_snow_days: int = 0
var pre_snow_cover: int = -1
# temp_baseline / temp_season_offset：refresh_climate_daily Pass A/B 写入，
# temperature_breakdown 调试字典与 UI 面板读取。命名去掉旧字典键的前导下划线。
# PR-2.3b：5 个温度系字段 + _ema_initialized facade 化。
var _temp_baseline_backing: float = 0.0
var temp_baseline: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_BASELINE]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_TEMP_BASELINE], index)
				return _world.read_f32(cid, index)
		return _temp_baseline_backing
	set(v):
		_temp_baseline_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_BASELINE]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _temp_season_offset_backing: float = 0.0
var temp_season_offset: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_SEASON_OFFSET]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_TEMP_SEASON_OFFSET], index)
				return _world.read_f32(cid, index)
		return _temp_season_offset_backing
	set(v):
		_temp_season_offset_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_SEASON_OFFSET]
			if cid >= 0:
				_world.write_f32(cid, index, v)
# 30/365 日滑动均值 + 偏离（Emergent Climate Coupling EMA）
var _temp_30d_mean_backing: float = 0.0
var temp_30d_mean: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_30D]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_TEMP_30D], index)
				return _world.read_f32(cid, index)
		return _temp_30d_mean_backing
	set(v):
		_temp_30d_mean_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_30D]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _temp_365d_mean_backing: float = 0.0
var temp_365d_mean: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_365D]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_TEMP_365D], index)
				return _world.read_f32(cid, index)
		return _temp_365d_mean_backing
	set(v):
		_temp_365d_mean_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_365D]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _temp_dev_from_annual_backing: float = 0.0
var temp_dev_from_annual: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_ANOMALY]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_TEMP_ANOMALY], index)
				return _world.read_f32(cid, index)
		return _temp_dev_from_annual_backing
	set(v):
		_temp_dev_from_annual_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_TEMP_ANOMALY]
			if cid >= 0:
				_world.write_f32(cid, index, v)
# Fast-tick perf opt (C)：EMA 首次初始化标志。旧版本用 -1.0 哨兵加字典查找
# 判断"是否首次"；升级为强类型 float 后 0.0 是合法气候值无法再作哨兵，
# 改用独立 bool。首次 refresh_climate_daily 写入后置 true。
var __ema_initialized_backing: bool = false
var _ema_initialized: bool = false:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_EMA_INITIALIZED]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_u8(_cid_array_ext[_CID_EMA_INITIALIZED], index) > 0
				return _world.read_u8(cid, index) > 0
		return __ema_initialized_backing
	set(v):
		__ema_initialized_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_EMA_INITIALIZED]
			if cid >= 0:
				_world.write_u8(cid, index, 1 if v else 0)

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
# B3b 阶段 3：3 个字段全部 facade 化（→ cell.vegetation_vitality SoA F32 +
# cell.vitality_low_streak / cell.vitality_high_streak SoA I32）。stage_b combined
# pass 完成后无需再做 unpack 回灌循环；hot path 直读 SoA 即可。
var _vegetation_vitality_backing: float = 0.7
var vegetation_vitality: float = 0.7:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_VITALITY]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_VEG_VITALITY], index)
				return _world.read_f32(cid, index)
		return _vegetation_vitality_backing
	set(v):
		_vegetation_vitality_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_VITALITY]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var __vitality_low_streak_backing: int = 0
var _vitality_low_streak: int = 0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VITALITY_LOW_STREAK]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_i32(_cid_array_ext[_CID_VITALITY_LOW_STREAK], index)
				return _world.read_i32(cid, index)
		return __vitality_low_streak_backing
	set(v):
		__vitality_low_streak_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VITALITY_LOW_STREAK]
			if cid >= 0:
				_world.write_i32(cid, index, v)
var __vitality_high_streak_backing: int = 0
var _vitality_high_streak: int = 0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VITALITY_HIGH_STREAK]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_i32(_cid_array_ext[_CID_VITALITY_HIGH_STREAK], index)
				return _world.read_i32(cid, index)
		return __vitality_high_streak_backing
	set(v):
		__vitality_high_streak_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VITALITY_HIGH_STREAK]
			if cid >= 0:
				_world.write_i32(cid, index, v)

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
# PR-2.3b：ocean_current facade 化（→ cell.ocean_current_x / cell.ocean_current_y SoA）。
# 同 wind_vector 注意事项：禁止 `cell.ocean_current.x = v` 写法。
var _ocean_current_backing: Vector2 = Vector2.ZERO
var ocean_current: Vector2 = Vector2.ZERO:
	get:
		if _facade_enabled:
			var cid_x: int = _cid_array[_CID_OCEAN_CURRENT_X]
			var cid_y: int = _cid_array[_CID_OCEAN_CURRENT_Y]
			if cid_x >= 0 and cid_y >= 0:
				if _world_ext != null:
					return Vector2(_world_ext.read_f32(_cid_array_ext[_CID_OCEAN_CURRENT_X], index), _world_ext.read_f32(_cid_array_ext[_CID_OCEAN_CURRENT_Y], index))
				return Vector2(_world.read_f32(cid_x, index), _world.read_f32(cid_y, index))
		return _ocean_current_backing
	set(v):
		_ocean_current_backing = v
		if _facade_enabled:
			var cid_x: int = _cid_array[_CID_OCEAN_CURRENT_X]
			var cid_y: int = _cid_array[_CID_OCEAN_CURRENT_Y]
			if cid_x >= 0 and cid_y >= 0:
				_world.write_f32(cid_x, index, v.x)
				_world.write_f32(cid_y, index, v.y)

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
# PR-2.3b：wind_vector facade 化（→ cell.wind_x / cell.wind_y SoA 双 cid）。
# 注意：Vector2 是 value type，调用方做 `cell.wind_vector.x = v` 会退化为
#       get → 改副本 → 副本丢失（不会触发 set）。所以禁止此写法，调用方
#       必须用 `cell.wind_vector = Vector2(x, y)` 整体赋值。已在 PR-2.3b
#       审计阶段确认 ripgrep 全仓 0 hit（除 flush_soa_to_cells 即将删除）。
var _wind_vector_backing: Vector2 = Vector2.ZERO
var wind_vector: Vector2 = Vector2.ZERO:
	get:
		if _facade_enabled:
			var cid_x: int = _cid_array[_CID_WIND_X]
			var cid_y: int = _cid_array[_CID_WIND_Y]
			if cid_x >= 0 and cid_y >= 0:
				if _world_ext != null:
					return Vector2(_world_ext.read_f32(_cid_array_ext[_CID_WIND_X], index), _world_ext.read_f32(_cid_array_ext[_CID_WIND_Y], index))
				return Vector2(_world.read_f32(cid_x, index), _world.read_f32(cid_y, index))
		return _wind_vector_backing
	set(v):
		_wind_vector_backing = v
		if _facade_enabled:
			var cid_x: int = _cid_array[_CID_WIND_X]
			var cid_y: int = _cid_array[_CID_WIND_Y]
			if cid_x >= 0 and cid_y >= 0:
				_world.write_f32(cid_x, index, v.x)
				_world.write_f32(cid_y, index, v.y)

# --- Systemic Ocean Currents：上升流与热输运 ─────────────────────────────
# upwelling_strength ∈ [-1, 1]：
#   正值 = 上升流（沿岸 Ekman 抽吸、富营养），对下游 REEF/KELP/PELAGIC_BLOOM 放宽阈值；
#   负值 = 下沉流（高纬冷咸水汇点），当前主要给海冰 pass 做冷源修正。
#   仅对 is_water cell 有意义；陆地维持 0。由 MapGenerator._compute_ocean_currents
#   从 WorldData.ocean_upwelling_buffer 采样得到。
var _upwelling_strength_backing: float = 0.0
var upwelling_strength: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_UPWELLING_STRENGTH]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_UPWELLING_STRENGTH], index)
				return _world.read_f32(cid, index)
		return _upwelling_strength_backing
	set(v):
		_upwelling_strength_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_UPWELLING_STRENGTH]
			if cid >= 0:
				_world.write_f32(cid, index, v)

# --- Physical Wind & Ocean Circulation（物理化大气/海洋环流；hex 域求解） ─────
# 本块字段由 MapBaker 物理化求解器在每轮洋流烘焙时写入，仅当
# ClimateProfile.physical_circulation_enabled = true 时被填充；关闭时维持 0
# 不影响下游兜底逻辑。所有字段都是"可观测中间量"，方便 overlay 调试。
#
# slp ∈ [-1, 1] 归一化的海平面气压偏差（sea level pressure proxy）。
#   正值 = 高压（副热带 / 大陆冬季内陆），负值 = 低压（赤道 / 副极地 / 大陆夏季内陆）。
#   计算：纬度基线（赤道-/副热带+/副极地-/极地+）+ 海陆性 × 季节调制 + 邻域扩散平滑。
#   下游：物理化风场用 -∇slp 当压力梯度风源项。
var _slp_backing: float = 0.0
var slp: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_SLP]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_SLP], index)
				return _world.read_f32(cid, index)
		return _slp_backing
	set(v):
		_slp_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_SLP]
			if cid >= 0:
				_world.write_f32(cid, index, v)
# wind_speed：物理化风速（相对量级）。与 wind_vector 配对：
#   wind_vector 单位向量给方向，wind_speed 给强度。weather_system advection
#   与 ψ 求解的风应力 τ ≈ wind_speed² × wind_vector 都需要它。
var _wind_speed_backing: float = 0.0
var wind_speed: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WIND_SPEED]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_WIND_SPEED], index)
				return _world.read_f32(cid, index)
		return _wind_speed_backing
	set(v):
		_wind_speed_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_WIND_SPEED]
			if cid >= 0:
				_world.write_f32(cid, index, v)
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
# PR-2.3b：facade 化（→ cell.air_mass_temp_anomaly SoA）。
var _air_mass_temp_anomaly_backing: float = 0.0
var air_mass_temp_anomaly: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_AIR_MASS_TEMP_ANOM]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_AIR_MASS_TEMP_ANOM], index)
				return _world.read_f32(cid, index)
		return _air_mass_temp_anomaly_backing
	set(v):
		_air_mass_temp_anomaly_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_AIR_MASS_TEMP_ANOM]
			if cid >= 0:
				_world.write_f32(cid, index, v)

# --- Emergent Climate Coupling 字段（Phase E） ────────────────────────
# sea_ice_fraction ∈ [0, 1]：水体 cell 的当前海冰覆盖度（半快半慢量）。
#   归入"慢层 / map layer"，由 _apply_sea_ice_daily_pass 每日**增量**推进。
#   跨过 ClimateProfile.sea_ice_terrain_threshold 时翻转 cell.terrain，
#   跌回 threshold - hysteresis 时翻回 base_terrain。陆地 cell 始终为 0。
# PR-2.3b：facade 化（→ cell.sea_ice_frac SoA；注意属性名 vs schema 名 不同）。
var _sea_ice_fraction_backing: float = 0.0
var sea_ice_fraction: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_SEA_ICE_FRAC]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_SEA_ICE_FRAC], index)
				return _world.read_f32(cid, index)
		return _sea_ice_fraction_backing
	set(v):
		_sea_ice_fraction_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_SEA_ICE_FRAC]
			if cid >= 0:
				_world.write_f32(cid, index, v)

# soil_moisture / vegetation_growth_pressure：天气 → 慢层反馈缓冲字段。
#   由 _apply_weather_to_map_feedback_pass 在每日末以**很小权重**（≤ 0.5%）
#   累加，由 refresh_seasonal 在季末消费并按 feedback_decay 衰减。
#   它们使"连下三个月雨"等长期天气累积可以缓慢影响 base_moisture / 演替判定，
#   但当天的雨绝不直接重写 base_*，从而维持快慢双时间尺度。
# B3b 阶段 3：facade 化（→ cell.soil_moisture / cell.vegetation_growth_pressure SoA F32）。
var _soil_moisture_backing: float = 0.0
var soil_moisture: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_SOIL_MOISTURE]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_SOIL_MOISTURE], index)
				return _world.read_f32(cid, index)
		return _soil_moisture_backing
	set(v):
		_soil_moisture_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_SOIL_MOISTURE]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _vegetation_growth_pressure_backing: float = 0.0
var vegetation_growth_pressure: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_GROWTH_PRESSURE]
			if cid >= 0:
				if _world_ext != null:
					return _world_ext.read_f32(_cid_array_ext[_CID_VEG_GROWTH_PRESSURE], index)
				return _world.read_f32(cid, index)
		return _vegetation_growth_pressure_backing
	set(v):
		_vegetation_growth_pressure_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_GROWTH_PRESSURE]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _vegetation_heat_stress_backing: float = 0.0
var vegetation_heat_stress: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_HEAT_STRESS]
			if cid >= 0:
				if _world_ext != null and _cid_array_ext[_CID_VEG_HEAT_STRESS] >= 0:
					return _world_ext.read_f32(_cid_array_ext[_CID_VEG_HEAT_STRESS], index)
				return _world.read_f32(cid, index)
		return _vegetation_heat_stress_backing
	set(v):
		_vegetation_heat_stress_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_HEAT_STRESS]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _vegetation_drought_stress_backing: float = 0.0
var vegetation_drought_stress: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_DROUGHT_STRESS]
			if cid >= 0:
				if _world_ext != null and _cid_array_ext[_CID_VEG_DROUGHT_STRESS] >= 0:
					return _world_ext.read_f32(_cid_array_ext[_CID_VEG_DROUGHT_STRESS], index)
				return _world.read_f32(cid, index)
		return _vegetation_drought_stress_backing
	set(v):
		_vegetation_drought_stress_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_DROUGHT_STRESS]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _vegetation_cold_stress_backing: float = 0.0
var vegetation_cold_stress: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_COLD_STRESS]
			if cid >= 0:
				if _world_ext != null and _cid_array_ext[_CID_VEG_COLD_STRESS] >= 0:
					return _world_ext.read_f32(_cid_array_ext[_CID_VEG_COLD_STRESS], index)
				return _world.read_f32(cid, index)
		return _vegetation_cold_stress_backing
	set(v):
		_vegetation_cold_stress_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_COLD_STRESS]
			if cid >= 0:
				_world.write_f32(cid, index, v)
var _vegetation_regen_score_backing: float = 0.0
var vegetation_regen_score: float = 0.0:
	get:
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_REGEN_SCORE]
			if cid >= 0:
				if _world_ext != null and _cid_array_ext[_CID_VEG_REGEN_SCORE] >= 0:
					return _world_ext.read_f32(_cid_array_ext[_CID_VEG_REGEN_SCORE], index)
				return _world.read_f32(cid, index)
		return _vegetation_regen_score_backing
	set(v):
		_vegetation_regen_score_backing = v
		if _facade_enabled:
			var cid: int = _cid_array[_CID_VEG_REGEN_SCORE]
			if cid >= 0:
				_world.write_f32(cid, index, v)

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
