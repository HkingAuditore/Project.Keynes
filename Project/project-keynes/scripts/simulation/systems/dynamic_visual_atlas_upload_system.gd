extends DCSystem
class_name DynamicVisualAtlasUploadSystem

## Updates low-frequency visual atlases used by the main map shader.
## This replaces the old piggyback path inside sea_ice_atlas_upload; sea ice is
## now derived in shader from water temperature, so this system only refreshes
## dynamic cell state and ecology visuals.

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")

var baker: MapBakerScript = null
var map: MapData = null
var world_data: WorldData = null
var stride: int = 2


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData, p_stride: int = 2) -> void:
	id = &"dynamic_visual_atlas_upload"
	priority = 250
	slice_budget_ms = 0.45
	max_slices_per_tick = 1
	must_run = false
	starvation_threshold = 0
	baker = p_baker
	map = p_map
	world_data = p_world
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


func tick(_ctx) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if baker == null or map == null or world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}
	var dynamic_report: Dictionary = {}
	if baker.has_method("rebake_dynamic_cell_atlas_only"):
		dynamic_report = baker.rebake_dynamic_cell_atlas_only(map, world_data)
	var ecology_report: Dictionary = {}
	if baker.has_method("rebake_ecology_visual_atlas_only"):
		ecology_report = baker.rebake_ecology_visual_atlas_only(map, world_data)
	var elapsed_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	return {
		"done": true,
		"work_done": map.cell_count(),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"phase": "upload",
		"stage_name": "dynamic_visual_atlas_upload",
		"dynamic_dirty_cells": int(dynamic_report.get("dirty_cells", 0)),
		"dynamic_ms": float(dynamic_report.get("elapsed_ms", 0.0)),
		"ecology_dirty_cells": int(ecology_report.get("dirty_cells", 0)),
		"ecology_ms": float(ecology_report.get("elapsed_ms", 0.0)),
	}


func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)
