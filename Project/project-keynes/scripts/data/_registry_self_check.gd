# _registry_self_check.gd
# Lightweight self-check that verifies every TerrainProfile / VegetationProfile
# tres loads and that the default ClimateProfile is populated. Prints a one-
# shot summary to Output. Never blocks the game — it's informational.
#
# How to run:
#
#   1) From the Editor menu (one-off): `Project → Tools → Run Script...`,
#      pick this file. The summary appears in the Output panel.
#
#   2) Programmatically, from any boot hook / main.gd:
#
#          load("res://scripts/data/_registry_self_check.gd").new().run()
#
# Non-fatal: missing tres triggers push_warning() — Registries already fall
# back to safe defaults so gameplay keeps running.

@tool
extends RefCounted

# 显式 preload 各依赖脚本，避免 @tool 编辑期扫描时 class_name 全局表尚未
# 完成注册导致 parser 失败。
const _TerrainProfileScript = preload("res://scripts/data/terrain_profile.gd")
const _VegetationProfileScript = preload("res://scripts/data/vegetation_profile.gd")
const _ClimateProfileScript = preload("res://scripts/data/climate_profile.gd")
const _TerrainRegistryScript = preload("res://scripts/data/terrain_profile_registry.gd")
const _VegetationRegistryScript = preload("res://scripts/data/vegetation_profile_registry.gd")

const _CLIMATE_DEFAULT_PATH: String = "res://data/world/earth_like.tres"

# Convenience one-liner for boot-time invocation.
static func run_once() -> void:
	var inst := load("res://scripts/data/_registry_self_check.gd").new()
	inst.run()

func run() -> void:
	print("─── Registry self-check ─────────────────────────────")
	_check_terrain()
	_check_vegetation()
	_check_climate()
	print("─── Registry self-check done ────────────────────────")

func _check_terrain() -> void:
	TerrainProfileRegistry.ensure_loaded()
	var expected: int = TerrainProfileRegistry.profile_count()
	var profiles: Array = TerrainProfileRegistry.get_all_profiles()
	var missing: Array[int] = []
	var loaded: int = 0
	for i in range(profiles.size()):
		var p := profiles[i] as TerrainProfile
		# Fallback profiles are detectable by display_name == "Fallback";
		# real profiles set their own English name.
		if p == null or p.display_name == "Fallback":
			missing.append(i)
		else:
			loaded += 1
	print("  [Terrain]    %d / %d loaded" % [loaded, expected])
	if not missing.is_empty():
		push_warning(
			"Registry self-check: %d terrain profile(s) missing: %s"
			% [missing.size(), str(missing)]
		)

func _check_vegetation() -> void:
	VegetationProfileRegistry.ensure_loaded()
	var expected: int = VegetationProfileRegistry.profile_count()
	var profiles: Array = VegetationProfileRegistry.get_all_profiles()
	var missing: Array[int] = []
	var loaded: int = 0
	for i in range(profiles.size()):
		var p := profiles[i] as VegetationProfile
		if p == null or p.display_name_cn == "":
			missing.append(i)
		else:
			loaded += 1
	print("  [Vegetation] %d / %d loaded" % [loaded, expected])
	if not missing.is_empty():
		push_warning(
			"Registry self-check: %d vegetation profile(s) missing: %s"
			% [missing.size(), str(missing)]
		)

func _check_climate() -> void:
	var cp := ResourceLoader.load(_CLIMATE_DEFAULT_PATH, "Resource") as ClimateProfile
	if cp == null:
		print("  [Climate]    default missing at %s" % _CLIMATE_DEFAULT_PATH)
		push_warning("Registry self-check: %s missing" % _CLIMATE_DEFAULT_PATH)
		return
	# Sanity: a freshly new()-ed ClimateProfile has all defaults; we check a
	# few signature fields to confirm the tres actually overrode them rather
	# than silently loading as empty.
	var ok: bool = true
	var reasons: Array[String] = []
	if cp.seasonal_moisture_scale.size() != 4:
		ok = false
		reasons.append("seasonal_moisture_scale length != 4")
	if cp.satellites_per_main <= 0:
		ok = false
		reasons.append("satellites_per_main <= 0")
	if cp.max_volcanoes <= 0:
		ok = false
		reasons.append("max_volcanoes <= 0")
	if ok:
		print("  [Climate]    %s OK (seasonal=%s, volcanoes=%d)" % [
			_CLIMATE_DEFAULT_PATH,
			str(cp.seasonal_moisture_scale),
			cp.max_volcanoes,
		])
	else:
		print("  [Climate]    %s loaded but suspicious: %s" % [
			_CLIMATE_DEFAULT_PATH,
			", ".join(reasons),
		])
		push_warning(
			"Registry self-check: %s looks unpopulated (%s)"
			% [_CLIMATE_DEFAULT_PATH, ", ".join(reasons)]
		)
