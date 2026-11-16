extends RefCounted

# --- 统计工具 ---

## 统计各地形数量，返回 Dictionary { TERRAIN: count }
static func terrain_stats(cells: Dictionary) -> Dictionary:
	var stats: Dictionary = {}
	for cell in cells.values():
		var t = cell.terrain
		stats[t] = stats.get(t, 0) + 1
	return stats

# --- Emergent Climate Coupling：慢层只读访问器 ──────────────────────────
# 天气 / 快层 pass 应通过该访问器读取慢层字段，而不是直接读 cell.base_* /
# cell.landform / cell.terrain / cell.cover / cell.elevation / cell.ocean_current 等。
# 这样日后如果把慢层数据迁移到独立容器或做并行化，调用方不需要修改。
#
# 参数：
#   qr     — 目标 cell 的 cube 坐标（Vector3i）
#   fields — 慢层字段名列表，允许值：
#              "elevation", "landform", "terrain", "cover",
#              "base_temperature", "base_moisture", "base_vegetation", "base_terrain",
#              "ocean_current", "upwelling_strength", "temperature_transport_anomaly",
#              "sea_ice_fraction", "soil_moisture", "vegetation_growth_pressure",
#              "has_river", "has_volcano"
# 返回：Dictionary，键为字段名、值为该字段当前值；cell 不存在时返回空字典。
#
# Debug 守卫：字段名拼写错误时在 OS.is_debug_build() 下 push_warning 一次。
# 快层 pass 禁止对返回的 Dictionary 写入后再回写 HexCell（本函数只读）。
const _SLOW_LAYER_FIELDS: Dictionary = {
	"elevation": true, "landform": true, "terrain": true, "cover": true,
	"base_temperature": true, "base_moisture": true,
	"base_vegetation": true, "base_terrain": true,
	"ocean_current": true, "upwelling_strength": true,
	"temperature_transport_anomaly": true,
	"sea_ice_fraction": true, "soil_moisture": true,
	"vegetation_growth_pressure": true,
	"has_river": true, "has_volcano": true,
}

static func sample_slow_layer(cells: Dictionary, qr: Vector3i, fields: Array) -> Dictionary:
	var cell: HexCell = cells.get(qr, null)
	if cell == null:
		return {}
	var out: Dictionary = {}
	for f in fields:
		var key: String = str(f)
		if not _SLOW_LAYER_FIELDS.has(key):
			if OS.is_debug_build():
				push_warning("sample_slow_layer: unknown slow-layer field '%s'" % key)
			continue
		# 基础字段映射（GDScript 对 Object 可直接用字符串访问属性）
		match key:
			"base_temperature":
				# HexCell 上并没有 base_temperature（仅 base_moisture / base_terrain 等）；
				# Fast-tick perf opt (C)：temp_baseline 已升级为 HexCell 强类型成员，
				# 直接读，不再走 current_state["_temp_baseline"] 字典查找。
				out[key] = cell.temp_baseline
			_:
				out[key] = cell.get(key)
	return out
