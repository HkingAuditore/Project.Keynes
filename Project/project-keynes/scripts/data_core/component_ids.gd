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
const CELL_WEATHER_PRECIP: StringName = &"cell.weather_precip"
const CELL_WEATHER_TYPE: StringName = &"cell.weather_type"
const CELL_ELEVATION: StringName = &"cell.elevation"
const CELL_BASE_MOISTURE: StringName = &"cell.base_moisture"
const CELL_OCEAN_CURRENT_X: StringName = &"cell.ocean_current_x"
const CELL_OCEAN_CURRENT_Y: StringName = &"cell.ocean_current_y"
const CELL_WIND_X: StringName = &"cell.wind_x"
const CELL_WIND_Y: StringName = &"cell.wind_y"
const CELL_POS_X: StringName = &"cell.pos_x"
const CELL_POS_Y: StringName = &"cell.pos_y"
const CELL_LAT_NORM: StringName = &"cell.lat_norm"
const CELL_TEMP_BASELINE_YEAR: StringName = &"cell.temp_baseline_year"
const CELL_TERRAIN: StringName = &"cell.terrain"
const CELL_LANDFORM: StringName = &"cell.landform"
const CELL_VEGETATION: StringName = &"cell.vegetation"
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

# ─── Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个 component ──────
# 写入侧：map_generator._climate_pass_a_soa（每天每 cell 写一次）。
# 读取侧：_apply_ocean_heat_transport_water_soa / _land_soa（读 ema_initialized
#         决定是否冷启动），UI breakdown（temp_season_offset，flush 后从 cell 读）。
const CELL_EMA_INITIALIZED: StringName = &"cell.ema_initialized"             # u8 0/1
const CELL_TEMP_SEASON_OFFSET: StringName = &"cell.temp_season_offset"       # f32

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
