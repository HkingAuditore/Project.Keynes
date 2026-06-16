extends RefCounted
class_name DCComponentIds

## DataCore — Component dtype enum + StringName 常量集中表。
##
## 设计目标：
##   1. 让所有 system / job 通过常量名引用 component，禁止散落 magic string；
##   2. 给 World.bind_map_data() 提供一张"MapData 现有 25 个 PackedArray ↔ component"
##      的对照表，复用 SoA、零拷贝；
##   3. 为天气迁移期与未来扩展（economy / units / AI）预留 front-level
##      component 命名空间，避免和 cell-level 命名冲突。

# ─── dtype 枚举 ────────────────────────────────────────────────
# DCWorld.register_component(dtype) 接受这些值；非法值在注册时 push_error。
enum {
	F32 = 0,         # PackedFloat32Array, stride=1
	I32 = 1,         # PackedInt32Array, stride=1
	U8 = 2,          # PackedByteArray, stride=1
	VEC2_F32 = 3,    # 内部拆为两个 PackedFloat32Array (x, y)，stride 不再走 packed
	VEC3_F32 = 4,    # 内部拆为三个 PackedFloat32Array (x, y, z)
}

## 把 dtype 映射到底层 PackedArray 类型枚举，便于注册时分配。
##  - F32 / VEC2_F32 / VEC3_F32 → 由 World 自行创建 PackedFloat32Array（VEC2/3 内部拆轴）
##  - I32 → PackedInt32Array
##  - U8 → PackedByteArray
const DTYPE_NAMES: Dictionary = {
	F32: "F32", I32: "I32", U8: "U8",
	VEC2_F32: "VEC2_F32", VEC3_F32: "VEC3_F32",
}

# ─── Cell-level 内置 component 名（与 MapData SoA 一一对应） ──────────
# 命名约定：CELL_* 前缀。bind_map_data() 时按这张表把 MapData 字段挂入 World。
const CELL_TEMP: StringName = &"cell.temp"
const CELL_TEMP_BASELINE: StringName = &"cell.temp_baseline"
const CELL_TEMP_30D: StringName = &"cell.temp_30d"
const CELL_TEMP_365D: StringName = &"cell.temp_365d"
const CELL_TEMP_ANOMALY: StringName = &"cell.temp_anomaly"
const CELL_MOISTURE: StringName = &"cell.moisture"
const CELL_SNOW_COVER: StringName = &"cell.snow_cover"
const CELL_SEA_ICE_FRAC: StringName = &"cell.sea_ice_frac"
const CELL_WEATHER_INTENSITY: StringName = &"cell.weather_intensity"
const CELL_WEATHER_CLOUD: StringName = &"cell.weather_cloud"
const CELL_WEATHER_CLOUD_WATER: StringName = &"cell.weather_cloud_water"
const CELL_WEATHER_PRECIP: StringName = &"cell.weather_precip"
const CELL_WEATHER_TYPE: StringName = &"cell.weather_type"
const CELL_WEATHER_PREV_TYPE: StringName = &"cell.weather_prev_type"
const CELL_WEATHER_TARGET_TYPE: StringName = &"cell.weather_target_type"
const CELL_WEATHER_TRANSITION_ALPHA: StringName = &"cell.weather_transition_alpha"
const CELL_ELEVATION: StringName = &"cell.elevation"
const CELL_BASE_MOISTURE: StringName = &"cell.base_moisture"
const CELL_OCEAN_CURRENT_X: StringName = &"cell.ocean_current_x"
const CELL_OCEAN_CURRENT_Y: StringName = &"cell.ocean_current_y"
const CELL_WIND_X: StringName = &"cell.wind_x"
const CELL_WIND_Y: StringName = &"cell.wind_y"
const CELL_SLP: StringName = &"cell.slp"
const CELL_WIND_SPEED: StringName = &"cell.wind_speed"
const CELL_UPWELLING_STRENGTH: StringName = &"cell.upwelling_strength"
# Fix #11 (2026-06-15): PSI 求解的中间诊断数组，schema 化以让 C++ run_psi_solver_pass
# 直接 published_to_slot，跳过 GDScript 2400-loop 写回。
const CELL_WIND_STRESS_CURL: StringName = &"cell.wind_stress_curl"
const CELL_OCEAN_PSI: StringName = &"cell.ocean_psi"
const CELL_POS_X: StringName = &"cell.pos_x"
const CELL_POS_Y: StringName = &"cell.pos_y"
const CELL_LAT_NORM: StringName = &"cell.lat_norm"
const CELL_TEMP_BASELINE_YEAR: StringName = &"cell.temp_baseline_year"
const CELL_TERRAIN: StringName = &"cell.terrain"
const CELL_LANDFORM: StringName = &"cell.landform"
const CELL_VEGETATION: StringName = &"cell.vegetation"
const CELL_BASE_TERRAIN: StringName = &"cell.base_terrain"
const CELL_BASE_LANDFORM: StringName = &"cell.base_landform"
const CELL_BASE_VEGETATION: StringName = &"cell.base_vegetation"
const CELL_COVER: StringName = &"cell.cover"
const CELL_IS_WATER: StringName = &"cell.is_water"
const CELL_CLIMATE_DIRTY: StringName = &"cell.climate_dirty_mask"
const CELL_WEATHER_DIRTY: StringName = &"cell.weather_dirty_mask"

# ─── B-full Step-2：Weather hot loop view_f32 化新增 6 个 component ──────
# 写入侧：weather_system 的 commit_weather_field_solve（vapor/convergence/
# instability/field_init）、map_generator._climate_pass_b（air_mass_temp_anomaly）、
# map_generator 地图生成期（has_river）。
# 读取侧：weather_system 三段式 hot loop（全部）+ renderer 在 round 末经
# flush_soa_to_cells 拿一致快照。
const CELL_WEATHER_VAPOR: StringName = &"cell.weather_vapor"
const CELL_WEATHER_CONVERGENCE: StringName = &"cell.weather_convergence"
const CELL_WEATHER_INSTABILITY: StringName = &"cell.weather_instability"
const CELL_WEATHER_FIELD_INIT: StringName = &"cell.weather_field_init"   # u8 0/1
const CELL_AIR_MASS_TEMP_ANOMALY: StringName = &"cell.air_mass_temp_anomaly"
const CELL_HAS_RIVER: StringName = &"cell.has_river"                     # u8 0/1

# ─── A 修复（climate-temp-pingpong-fix-2026-06）— 显式 anomaly 合成新增 2 个 ──
# 历史：在 2026-06-12 的 tile_data 分析中，pass_a / pass_b / ocean_water / ocean_land
#       与 wind_surface 都在写 cell_temp，导致 stage 周期级 ping-pong（p99|ΔT|=0.11，
#       max=0.28，52% cells 出现 sign flip）。
# 修复架构：
#   - pass_a → cell_temp_baseline（不再写 cell_temp；temp_baseline 含义改为
#       "radiative + 热惯性后的瞬时 baseline"，每日重写）
#   - ocean_water/land → cell.ocean_thermal_anomaly（不再写 cell_temp）
#   - pass_b → cell.local_thermal_anomaly（不再写 cell_temp）
#   - wind_air_mass → cell.air_mass_temp_anomaly（已合规，不动）
#   - wind_surface → cell_temp = clamp(baseline + ocean_anom + local_anom + air_anom)
#       唯一写者，下游 weather_field_solve 才读 cell_temp。
const CELL_OCEAN_THERMAL_ANOMALY: StringName = &"cell.ocean_thermal_anomaly" # f32
const CELL_LOCAL_THERMAL_ANOMALY: StringName = &"cell.local_thermal_anomaly" # f32

# ─── Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个 component ──────
# 写入侧：map_generator._climate_pass_a_soa（每天每 cell 写一次）。
# 读取侧：_apply_ocean_heat_transport_water_soa / _land_soa（读 ema_initialized
#         决定是否冷启动），UI breakdown（temp_season_offset，flush 后从 cell 读）。
const CELL_EMA_INITIALIZED: StringName = &"cell.ema_initialized"             # u8 0/1
const CELL_TEMP_SEASON_OFFSET: StringName = &"cell.temp_season_offset"       # f32
const CELL_INSOLATION_NOW: StringName = &"cell.insolation_now"               # f32, [0,1]
const CELL_INSOLATION_DEV: StringName = &"cell.insolation_dev"               # f32, normalized anomaly
const CELL_DAY_LENGTH: StringName = &"cell.day_length"                       # f32, [0,1]
const CELL_HEAT_INPUT: StringName = &"cell.heat_input"                       # f32, [0,1]
const CELL_THERMAL_ENERGY: StringName = &"cell.thermal_energy"               # f32, [0,1]
const CELL_SNOWPACK: StringName = &"cell.snowpack"                           # f32, normalized SWE [0,1]
const CELL_WATER_BALANCE_30D: StringName = &"cell.water_balance_30d"          # f32, [-1,1]

# ─── B3b：植被动力学字段全量下沉 SoA（消除 stage_b combined pack/unpack） ──
# 历史：这 6 个字段原先只在 HexCell 上做强类型 var，stage_b combined pass
# 每帧要把 cells[i].<field> pack 成 PackedArray 喂给 cpp，cpp 算完 GDScript
# 又把结果 unpack 回 cell.<field>。breakdown 显示 pack+unpack 合计 ~7ms，
# 占整个 stage_b wall 的 95%。下沉到 SoA 后 cpp 端直读 _slots，pack/unpack
# 完全消失，目标 wall ≈ 0.3-0.5ms。
# 命名严格 1:1 对齐 HexCell 字段名（vegetation_vitality / _vitality_low_streak /
# _vitality_high_streak / soil_moisture / vegetation_growth_pressure /
# temperature_transport_anomaly），方便阶段 3 把 _trigger_succession / legacy
# fallback 改成 `world.write_f32_range(slot_id, ...)` 时搜索/重构。
# 写入侧：cpp run_stage_b_pass 直写 _slots（阶段 2 后），加上 _trigger_succession
#         / GDScript legacy fallback / save-load。
# 读取侧：cpp run_stage_b_pass 直读 _slots（阶段 2 后），加上 UI / overlay /
#         baker / save 序列化（通过 snapshot_f32 / snapshot_i32）。
const CELL_VEGETATION_VITALITY: StringName       = &"cell.vegetation_vitality"        # f32
const CELL_VITALITY_LOW_STREAK: StringName       = &"cell.vitality_low_streak"        # i32
const CELL_VITALITY_HIGH_STREAK: StringName      = &"cell.vitality_high_streak"       # i32
const CELL_SOIL_MOISTURE: StringName             = &"cell.soil_moisture"              # f32
const CELL_VEGETATION_GROWTH_PRESSURE: StringName = &"cell.vegetation_growth_pressure" # f32
const CELL_TEMPERATURE_TRANSPORT_ANOMALY: StringName = &"cell.temperature_transport_anomaly" # f32
const CELL_VEGETATION_HEAT_STRESS: StringName = &"cell.vegetation_heat_stress" # f32
const CELL_VEGETATION_DROUGHT_STRESS: StringName = &"cell.vegetation_drought_stress" # f32
const CELL_VEGETATION_COLD_STRESS: StringName = &"cell.vegetation_cold_stress" # f32
const CELL_VEGETATION_REGEN_SCORE: StringName = &"cell.vegetation_regen_score" # f32


# ─── Reference-impl Pass #2 — `cell.demo.*` 命名空间（demo-only） ─────────
# 命名纪律：`cell.demo.*` 是参考实现（performance-charter §12.5/§12.6）专用
#   命名空间。任何真实游戏机制（climate / weather / biome / vegetation / UI
#   tooltip 等）**禁止**读取或依赖该前缀下的字段。
# 持久化纪律：该前缀下字段**不应进入永久存档**——它们由 demo pass 在每帧 /
#   每日重算，存档恢复后立即被覆盖，没有保存价值。如果未来存档代码采用
#   "扫描全部已注册 slot"的方式自动覆盖，须在存档加载侧显式跳过 `cell.demo.*`。
const CELL_DEMO_THERMAL_GRADIENT: StringName = &"cell.demo.thermal_gradient" # f32, [0,1]

## 内置拓扑 component（HexNeighborTopology）— 由 bind_map_data() 自动注册。
const TOPOLOGY_HEX_NEIGHBORS: StringName = &"topology.hex_neighbors"

# ─── Front-level component 名（供天气迁移使用） ──────────────────
# 命名约定：FRONT_* 前缀。这些 component 不归 MapData 持有，由 DCWorld
# 独立分配，长度 = 当前 front entity 数。
const FRONT_POS_X: StringName = &"front.pos_x"
const FRONT_POS_Y: StringName = &"front.pos_y"
const FRONT_VEL_X: StringName = &"front.vel_x"
const FRONT_VEL_Y: StringName = &"front.vel_y"
const FRONT_KIND: StringName = &"front.kind"
const FRONT_STRENGTH: StringName = &"front.strength"
const FRONT_RADIUS: StringName = &"front.radius"
const FRONT_AGE: StringName = &"front.age"

## Archetype 命名空间（分组用，非 component）。
const ARCH_CELL: StringName = &"arch.cell"
const ARCH_WEATHER_FRONT: StringName = &"arch.weather_front"

## Pool 命名空间（I2.A，多 entity pool 注册）。
##  - cells：由 World.bind_map_data 自动建（容量 = MapData.cell_count()）。
##  - weather_fronts：由 weather_refresh_job._on_world_bound 在 bind 之后建。
##  - 未来 unit / army / economy 等子系统按需追加 POOL_*。
const POOL_CELLS: StringName = &"cells"
const POOL_WEATHER_FRONTS: StringName = &"weather_fronts"


## 工具函数：判断 dtype 是否为合法值。
static func is_valid_dtype(d: int) -> bool:
	return d == F32 or d == I32 or d == U8 or d == VEC2_F32 or d == VEC3_F32


## 工具函数：dtype → 人读名（日志 / 错误用）。
static func dtype_name(d: int) -> String:
	return String(DTYPE_NAMES.get(d, "UNKNOWN"))
