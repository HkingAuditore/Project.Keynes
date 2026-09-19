extends RefCounted
class_name DCFrontsSchema

## DataCore — Weather Front pool SoA Schema 单一源（B1 / Phase 1.2 预备）。
##
## 设计目标（dots-migration-roadmap §1.2 / dots-full-migration F.6）：
##
##   1. 把 `WeatherFront` (RefCounted OOP) 的 23 个字段拍平为 SoA 描述；
##   2. F.6 C++ 实装（`run_weather_front_advect_pass`）时直接按本表
##      构造 batch 输入/输出 PackedArray，无需 hardcode 字段名；
##   3. 阶段 II 数据所有权下移时，本 schema 升级为"权威"——`WeatherFront`
##      退化为 thin facade（getter 走 PackedArray，by world_idx）。
##
## 与 `DCComponentSchema` 的差异：
##   - **不**绑 MapData：fronts 不是 cell-level 字段；没有 `map_field`。
##   - **不**经 DCWorld 注册：weather_system 自持 PackedArray（首版），
##     直到阶段 II 真正升权威时再走 `world.create_pool` / `register_component`
##     路径（届时可与 cell_* slots 一样通过 `world.view_*` 读）。
##   - **由 weather_system 持有**：可在 `_active_fronts: Array[WeatherFront]`
##     的同时维护一份 SoA 镜像（双轨）；首版 OOP 仍权威，SoA 仅作 F.6 C++
##     pass 的批量参数缓冲。
##
## 加新 front 字段的 SOP（2 步）：
##   1. 在本文件 `FRONTS_SCHEMA` 末尾追加一行；
##   2. 在 `WeatherFront` 同步加 var + 在 `pack_into_dict` / `apply_dict`
##      静态方法里加对应字段（参考已加的 23 字段）。

const F32: int = DCComponentIds.F32
const I32: int = DCComponentIds.I32
const U8: int  = DCComponentIds.U8

# ─── FRONTS_SCHEMA — 23 条（与 WeatherFront 字段 1:1 对齐）────────────
#
# 字段 dict_key：在 pack_into_dict 输出 Dictionary 中的 key。命名约定：
#   - F32 列：`front_<field>` → PackedFloat32Array (size = n_fronts)
#   - U8/I32 列：同名 → PackedByteArray / PackedInt32Array (size = n_fronts)
#   - Vector2 拆为 .x / .y 两条 F32 列（C++ 端避免 Variant 装箱）
#
# 字段 owner：业务模块归属，仅作 lint 用。
const FRONTS_SCHEMA: Array = [
	# ─── 几何 / 位置（10 F32）──
	{ name = &"front.world_idx",        cpp_name = "front_world_idx",        dtype = I32, owner = "weather.front_pool" },
	{ name = &"front.center_x",         cpp_name = "front_center_x",         dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.center_y",         cpp_name = "front_center_y",         dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.radius",           cpp_name = "front_radius",           dtype = F32, owner = "weather.front_spawn" },
	{ name = &"front.velocity_x",       cpp_name = "front_velocity_x",       dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.velocity_y",       cpp_name = "front_velocity_y",       dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.axis_x",           cpp_name = "front_axis_x",           dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.axis_y",           cpp_name = "front_axis_y",           dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.stable_axis_x",    cpp_name = "front_stable_axis_x",    dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.stable_axis_y",    cpp_name = "front_stable_axis_y",    dtype = F32, owner = "weather.front_advect" },
	# ─── 形态 / 视觉（4 F32）──
	{ name = &"front.major_scale",      cpp_name = "front_major_scale",      dtype = F32, owner = "weather.front_spawn" },
	{ name = &"front.minor_scale",      cpp_name = "front_minor_scale",      dtype = F32, owner = "weather.front_spawn" },
	{ name = &"front.edge_seed",        cpp_name = "front_edge_seed",        dtype = F32, owner = "weather.front_spawn" },
	{ name = &"front.intensity",        cpp_name = "front_intensity",        dtype = F32, owner = "weather.front_advect" },
	# ─── 类型 / 寿命（3 I32 + 1 F32）──
	{ name = &"front.type",             cpp_name = "front_type",             dtype = I32, owner = "weather.front_spawn" },
	{ name = &"front.ttl_days",         cpp_name = "front_ttl_days",         dtype = I32, owner = "weather.front_spawn" },
	{ name = &"front.age_days",         cpp_name = "front_age_days",         dtype = I32, owner = "weather.front_advect" },
	{ name = &"front.decay_per_day",    cpp_name = "front_decay_per_day",    dtype = F32, owner = "weather.front_spawn" },
	# ─── 寿命派生量（4 F32，由 refresh_visual_lifecycle 计算）──
	{ name = &"front.life_progress",    cpp_name = "front_life_progress",    dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.cloud_amount",     cpp_name = "front_cloud_amount",     dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.precip_amount",    cpp_name = "front_precip_amount",    dtype = F32, owner = "weather.front_advect" },
	{ name = &"front.dissolve_amount",  cpp_name = "front_dissolve_amount",  dtype = F32, owner = "weather.front_advect" },
	# ─── 存活 marker（1 U8；从 is_alive() 派生）──
	# alive=1 表示 intensity > 0.01 且 age_days < ttl_days；F.6 C++ pass 用 alive 跳过 dead front。
	{ name = &"front.alive",            cpp_name = "front_alive",            dtype = U8,  owner = "weather.front_advect" },
]

const MAX_FRONTS: int = 16

## 全部条目数量。
static func count() -> int:
	return FRONTS_SCHEMA.size()

## 按 cpp_name 查 entry。
static func find_by_cpp_name(cpp_name: String) -> Dictionary:
	for e in FRONTS_SCHEMA:
		if String(e.cpp_name) == cpp_name:
			return e
	return {}

## 启动期一次性自检：检查所有 entry 字段完整。
static func validate_all() -> String:
	for i in range(FRONTS_SCHEMA.size()):
		var e: Dictionary = FRONTS_SCHEMA[i]
		if not e.has("name") or e.name == &"":
			return "[FRONTS_SCHEMA[%d]] missing 'name'" % i
		if not e.has("cpp_name") or String(e.cpp_name) == "":
			return "[FRONTS_SCHEMA[%d]] missing 'cpp_name'" % i
		if not e.has("dtype") or (int(e.dtype) != F32 and int(e.dtype) != I32 and int(e.dtype) != U8):
			return "[FRONTS_SCHEMA[%d]] invalid 'dtype' (must be F32 / I32 / U8)" % i
	return ""
