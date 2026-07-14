# resource_profile_registry.gd
# Single-point accessor for all natural-resource ResourceProfile definitions.
# Lazy-loaded on first access, cached in a static ordered Array.
#
# 顺序即权威：`_PROFILE_PATHS` 的下标 = C++ run_natural_resource_pass 的资源索引。
# 新增一种资源的 SOP：
#   1) 在 component_ids.gd / map_data.gd / component_schema.gd 加对应 reserve + extra_change 字段；
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
	"res://data/resources/timber.tres",
	"res://data/resources/stone.tres",
	"res://data/resources/fertile_soil.tres",
	"res://data/resources/arable_land.tres",
	"res://data/resources/paddy_land.tres",
	"res://data/resources/plantation_land.tres",
	"res://data/resources/pasture.tres",
	"res://data/resources/coal.tres",
	"res://data/resources/oil.tres",
	"res://data/resources/natural_gas.tres",
	"res://data/resources/copper_ore.tres",
	"res://data/resources/iron_ore.tres",
	"res://data/resources/gold_ore.tres",
	"res://data/resources/silver_ore.tres",
	"res://data/resources/salt.tres",
	"res://data/resources/saltpeter.tres",
	"res://data/resources/rare_earth.tres",
	"res://data/resources/clay.tres",
	"res://data/resources/wild_game.tres",
	"res://data/resources/marine_fish.tres",
	"res://data/resources/bauxite.tres",
	"res://data/resources/limestone.tres",
	"res://data/resources/silica_sand.tres",
	"res://data/resources/phosphate_rock.tres",
	"res://data/resources/tin_ore.tres",
	"res://data/resources/lead_ore.tres",
	"res://data/resources/zinc_ore.tres",
	"res://data/resources/manganese_ore.tres",
	"res://data/resources/sulfur.tres",
	"res://data/resources/flint.tres",
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

## Deposits remain present in MapData regardless of this result. This helper is
## for inspectors/map overlays only; extraction is independently gated by the
## extractor building's `technology_tags` in NativeEconomyRuntime.
static func discovery_visible(p: ResourceProfile,
		unlocked_technology_ids: PackedStringArray) -> bool:
	if p == null:
		return false
	for tag in p.discovery_technology_tags:
		var stable_id := String(tag)
		if stable_id.begins_with("tech.") and not unlocked_technology_ids.has(stable_id):
			return false
	return true

static func habitat_code(p: ResourceProfile) -> int:
	if p == null:
		return -1
	var habitat := String(p.habitat_mode)
	if habitat == "legacy":
		habitat = "land" if p.land_only else "any"
	# Transitional aliases for hand-authored profiles from the first habitat revision.
	if habitat == "marine_access": habitat = "marine_water"
	if habitat == "freshwater_access": habitat = "freshwater"
	return int({"any": 0, "land": 1, "marine_water": 2,
		"freshwater": 3}.get(habitat, -1))


static func habitat_available(p: ResourceProfile, mask: int) -> bool:
	match habitat_code(p):
		0: return true
		1: return (mask & 1) != 0
		2: return (mask & 2) != 0
		3: return (mask & 4) != 0
	return false


# 某 profile 储量字段对应的 MapData 属性名（map_field，如 "res_timber_reserve_arr"）。
# 经 component_schema 查表，避免 .tres 重复维护。
static func reserve_map_field(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.reserve_component)
	return String(e.get("map_field", "")) if not e.is_empty() else ""


# 某 profile 储量字段对应的 C++ slot 名（cpp_name，如 "cell_res_timber_reserve"）。
static func reserve_cpp_name(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.reserve_component)
	return String(e.get("cpp_name", "")) if not e.is_empty() else ""


# 某 profile 对应的额外变化 C++ slot 名（如 "cell_res_timber_extra_change"）。
# 命名从 reserve_component 派生，避免每个 .tres 重复维护。
static func extra_change_cpp_name(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var extra_name := StringName(String(p.reserve_component).replace("_reserve", "_extra_change"))
	var e: Dictionary = DCComponentSchema.find_by_name(extra_name)
	return String(e.get("cpp_name", "")) if not e.is_empty() else ""


# 某 profile 对应的额外变化 MapData 字段名（如 "res_timber_extra_change_arr"）。
static func extra_change_map_field(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var extra_name := StringName(String(p.reserve_component).replace("_reserve", "_extra_change"))
	var e: Dictionary = DCComponentSchema.find_by_name(extra_name)
	return String(e.get("map_field", "")) if not e.is_empty() else ""


# 组装 DCWorldExt.run_natural_resource_pass 的 knobs（不含 n_cells，由调用方补）。
# 所有平行数组按资源索引对齐；schema 缺失（cpp_name 为空）的资源会被整体跳过。
static func build_pass_knobs() -> Dictionary:
	ensure_loaded()
	var reserve_slots := PackedStringArray()
	var extra_change_slots := PackedStringArray()
	var habitat_modes := PackedInt32Array()
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
	var climate_temp_opt := PackedFloat32Array()
	var climate_temp_tol := PackedFloat32Array()
	var climate_moisture_opt := PackedFloat32Array()
	var climate_moisture_tol := PackedFloat32Array()
	var runtime_climate_fit_weight := PackedFloat32Array()
	var decay_stress := PackedFloat32Array()
	for p in _ordered:
		var cpp_name: String = reserve_cpp_name(p)
		var extra_cpp_name: String = extra_change_cpp_name(p)
		if cpp_name == "" or extra_cpp_name == "":
			push_warning("ResourceProfileRegistry: resource '%s' has incomplete schema entry for %s; skipped" % [
				String(p.id), String(p.reserve_component)])
			continue
		reserve_slots.append(cpp_name)
		extra_change_slots.append(extra_cpp_name)
		habitat_modes.append(habitat_code(p))
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
		climate_temp_opt.append(p.climate_temp_opt)
		climate_temp_tol.append(p.climate_temp_tol)
		climate_moisture_opt.append(p.climate_moisture_opt)
		climate_moisture_tol.append(p.climate_moisture_tol)
		runtime_climate_fit_weight.append(p.runtime_climate_fit_weight)
		decay_stress.append(p.decay_stress)
	return {
		"resource_count": reserve_slots.size(),
		"reserve_slots": reserve_slots,
		"extra_change_slots": extra_change_slots,
		"habitat_modes": habitat_modes,
		"habitat_mask_slot": "cell_resource_habitat_mask",
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
		"climate_temp_opt": climate_temp_opt,
		"climate_temp_tol": climate_temp_tol,
		"climate_moisture_opt": climate_moisture_opt,
		"climate_moisture_tol": climate_moisture_tol,
		"runtime_climate_fit_weight": runtime_climate_fit_weight,
		"decay_stress": decay_stress,
	}
