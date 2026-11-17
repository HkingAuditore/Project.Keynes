extends SceneTree
# 世界绘制层带契约：树冠必须压住建筑主体。
#
# 层带数值分别写在 building_visual_layer.gd（Z_BAND_*）和
# vegetation_family_layer.gd（Z_BAND_CANOPY*、_family_z）里，没有共享常量源——
# 正是这种"两份数字"的写法让建筑 body 停在 3、树冠停在 2，房子一直盖在树冠之上。
# 这个测试守的是**关系**而不是具体数字：以后重排层带时，只要关系不破就能通过。
const BuildingLayer = preload("res://scripts/rendering/building_visual_layer.gd")
const VegetationLayer = preload("res://scripts/rendering/vegetation_family_layer.gd")
const ResourceLayer = preload("res://scripts/rendering/resource_visual_layer.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("run")


func check(label: String, ok: bool) -> void:
	_checks += 1
	print("[world-draw-bands] ", "PASS " if ok else "FAIL ", label)
	if not ok:
		_failures += 1
		push_error(label)


func run() -> void:
	var vegetation := VegetationLayer.new()
	var canopy: int = vegetation._family_z(VegetationLayer.FAMILY_CANOPY)
	var canopy_shadow: int = vegetation._family_shadow_z(
		VegetationLayer.FAMILY_CANOPY)
	var brush: int = vegetation._family_z(VegetationLayer.FAMILY_BRUSH)
	var hardscape: int = vegetation._family_z(VegetationLayer.FAMILY_HARDSCAPE)
	var ground: int = vegetation._family_z(VegetationLayer.FAMILY_GROUND)
	vegetation.free()

	check("canopy draws above house bodies", canopy > BuildingLayer.Z_BAND_BODY)
	check("canopy shadow stays below house bodies",
		canopy_shadow < BuildingLayer.Z_BAND_BODY)
	check("house body draws above its own ground decal",
		BuildingLayer.Z_BAND_BODY > BuildingLayer.Z_BAND_DECAL)
	check("house body draws above its own shadow hull",
		BuildingLayer.Z_BAND_BODY > BuildingLayer.Z_BAND_SHADOW)
	check("far macro settlement blob stays below house bodies",
		BuildingLayer.Z_BAND_BODY > BuildingLayer.Z_BAND_MACRO)
	check("shadow hull stays above the decal it darkens",
		BuildingLayer.Z_BAND_SHADOW >= BuildingLayer.Z_BAND_DECAL)
	check("brush stays below house bodies", brush < BuildingLayer.Z_BAND_BODY)
	check("hardscape stays below house bodies",
		hardscape < BuildingLayer.Z_BAND_BODY)
	check("ground cover stays below every other band",
		ground < brush and ground < BuildingLayer.Z_BAND_DECAL)
	check("resource props stay below house bodies",
		ResourceLayer.RESOURCE_Z < BuildingLayer.Z_BAND_BODY)
	_check_profiles(canopy)
	check("resource props stay below canopy",
		ResourceLayer.RESOURCE_Z < canopy)

	print("[world-draw-bands] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


# 默认运行时走的是旧散布层（detail_scatter_family_renderer_enabled=false），
# 树冠的 z 直接来自 data/visual/*.tres 的 render_z_index。上一条"成对维护"在代码里，
# 这一条守的是**数据**：任何 profile 都不许占用建筑主体那一层，树类必须站在树冠层带上。
func _check_profiles(canopy: int) -> void:
	var dir := DirAccess.open("res://data/visual")
	if dir == null:
		check("visual profile directory is readable", false)
		return
	var seen := 0
	for file in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var profile: Resource = load("res://data/visual/" + file)
		if profile == null:
			continue
		var raw_z = profile.get("render_z_index")
		if raw_z == null:
			continue
		seen += 1
		var z := int(raw_z)
		check("%s does not sit on the house body band" % file,
			z != BuildingLayer.Z_BAND_BODY)
		var kind := int(profile.get("detail_kind"))
		if kind == 1 or kind == 3 or kind == 4:  # Tree / Conifer / Palm
			check("%s tree canopy sits on the canopy band" % file, z == canopy)
	check("visual profiles declare a draw band", seen >= 20)
