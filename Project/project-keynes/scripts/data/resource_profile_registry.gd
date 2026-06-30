# resource_profile_registry.gd
# Single-point accessor for all natural-resource ResourceProfile definitions.
# Lazy-loaded on first access, cached in a static ordered Array.
#
# 顺序即权威：`_PROFILE_PATHS` 的下标 = C++ run_natural_resource_pass 的资源索引。
# 新增一种资源的 SOP：
#   1) 在 component_ids.gd / map_data.gd / component_schema.gd 加对应 cell.<res>_reserve 字段；
#   2) 跑 tools/codegen/gen_cpp_bind_table.py 重新生成 C++ bind table；
#   3) 新建 data/resources/<res>.tres（reserve_component 指向该字段）；
#   4) 在本文件 _PROFILE_PATHS 追加路径；
#   5) 重 build GDExtension。
#
# Consumers: MapGenerator（初始储量 bootstrap + 每日 pass knobs / fallback），
# NaturalResourceDailySystem（间接，经 generator helper）。

class_name ResourceProfileRegistry

# 显式 preload，保证 ResourceProfile 类在本脚本解析前已被 Godot 加载。
const _ResourceProfileScript = preload("res://scripts/data/resource_profile.gd")

const _PROFILE_PATHS: Array = [
	"res://data/resources/biomass.tres",
	"res://data/resources/iron_ore.tres",
	# 性能压测用 10 种测试资源（公式差异刻意拉大；删除时同步清 schema/map_data/component_ids）。
	"res://data/resources/freshwater.tres",
	"res://data/resources/timber.tres",
	"res://data/resources/coal.tres",
	"res://data/resources/oil.tres",
	"res://data/resources/clay.tres",
	"res://data/resources/wild_game.tres",
	"res://data/resources/peat.tres",
	"res://data/resources/stone.tres",
	"res://data/resources/wild_herbs.tres",
	"res://data/resources/geothermal.tres",
]

static var _ordered: Array = []        # Array[ResourceProfile]，按 _PROFILE_PATHS 顺序
static var _loaded: bool = false


# Idempotent bulk loader. 加载失败的条目跳过并 push_warning，不崩溃。
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_ordered.clear()
	for path in _PROFILE_PATHS:
		var res := ResourceLoader.load(path, "Resource") as ResourceProfile
		if res == null:
			push_warning("ResourceProfileRegistry: failed to load %s" % path)
			continue
		_ordered.append(res)


# 有序资源列表（下标 = C++ pass 资源索引）。
static func ordered() -> Array:
	ensure_loaded()
	return _ordered


static func count() -> int:
	ensure_loaded()
	return _ordered.size()


# 某 profile 储量字段对应的 MapData 属性名（map_field，如 "res_biomass_reserve_arr"）。
# 经 component_schema 查表，避免 .tres 重复维护。
static func reserve_map_field(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.reserve_component)
	return String(e.get("map_field", "")) if not e.is_empty() else ""


# 某 profile 储量字段对应的 C++ slot 名（cpp_name，如 "cell_res_biomass_reserve"）。
static func reserve_cpp_name(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.reserve_component)
	return String(e.get("cpp_name", "")) if not e.is_empty() else ""


# 组装 DCWorldExt.run_natural_resource_pass 的 knobs（不含 n_cells，由调用方补）。
# 所有平行数组按资源索引对齐；schema 缺失（cpp_name 为空）的资源会被整体跳过。
static func build_pass_knobs() -> Dictionary:
	ensure_loaded()
	var reserve_slots := PackedStringArray()
	var capacity := PackedFloat32Array()
	var land_only := PackedFloat32Array()
	var temp_lo := PackedFloat32Array()
	var temp_hi := PackedFloat32Array()
	var gen_base := PackedFloat32Array()
	var gen_temp := PackedFloat32Array()
	var gen_moisture := PackedFloat32Array()
	var gen_self := PackedFloat32Array()
	var decay_base := PackedFloat32Array()
	var decay_temp := PackedFloat32Array()
	var decay_moisture := PackedFloat32Array()
	var decay_self := PackedFloat32Array()
	for p in _ordered:
		var cpp_name: String = reserve_cpp_name(p)
		if cpp_name == "":
			push_warning("ResourceProfileRegistry: resource '%s' has no schema entry for %s; skipped" % [
				String(p.id), String(p.reserve_component)])
			continue
		reserve_slots.append(cpp_name)
		capacity.append(p.capacity)
		land_only.append(1.0 if p.land_only else 0.0)
		temp_lo.append(p.temp_lo)
		temp_hi.append(p.temp_hi)
		gen_base.append(p.gen_base)
		gen_temp.append(p.gen_temp)
		gen_moisture.append(p.gen_moisture)
		gen_self.append(p.gen_self)
		decay_base.append(p.decay_base)
		decay_temp.append(p.decay_temp)
		decay_moisture.append(p.decay_moisture)
		decay_self.append(p.decay_self)
	return {
		"resource_count": reserve_slots.size(),
		"reserve_slots": reserve_slots,
		"capacity": capacity,
		"land_only": land_only,
		"temp_lo": temp_lo,
		"temp_hi": temp_hi,
		"gen_base": gen_base,
		"gen_temp": gen_temp,
		"gen_moisture": gen_moisture,
		"gen_self": gen_self,
		"decay_base": decay_base,
		"decay_temp": decay_temp,
		"decay_moisture": decay_moisture,
		"decay_self": decay_self,
	}
