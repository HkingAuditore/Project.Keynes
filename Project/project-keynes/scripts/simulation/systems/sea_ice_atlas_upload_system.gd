extends DCSystem
class_name SeaIceAtlasUploadSystem

## Phase C.3 — DCSystem 改写自 [`SeaIceAtlasUploadJob`](../sus/jobs/sea_ice_atlas_upload_job.gd)。
##
## 行为完全等价。
##
## reads / writes 声明：
##   - reads:  cell.sea_ice_frac（baker 从 cell 读取写到 R8 atlas）
##   - writes: 无（仅写 GPU 纹理）
##
## feature_flag：留空（基础设施 system，无 toggle）。

const _SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const _MapBakerScript = preload("res://scripts/rendering/map_baker.gd")

var baker: _MapBakerScript = null
var map: MapData = null
var world_data: WorldData = null
var stride: int = 2
var _pending_upload: bool = false
var _pending_prepare: Dictionary = {}


func _init(p_baker: _MapBakerScript, p_map: MapData, p_world: WorldData,
		p_stride: int) -> void:
	id = &"sea_ice_atlas_upload"
	priority = 250
	slice_budget_ms = 25.0
	must_run = false
	starvation_threshold = 8
	baker = p_baker
	map = p_map
	world_data = p_world
	stride = max(1, p_stride)
	policy = _SusPolicyScript.StridePolicy.new(stride, 0)


func declare_reads() -> Array[StringName]:
	return [DCComponentIds.CELL_SEA_ICE_FRAC]


func declare_writes() -> Array[StringName]:
	return []


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	if baker == null or map == null or world_data == null:
		return false
	if _pending_upload:
		return true
	return super.should_run(ctx)


func tick(_ctx) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if baker == null or map == null or world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0}
	if _pending_upload:
		var upload: Dictionary = baker.upload_prepared_sea_ice_fraction_atlas(world_data)
		_pending_upload = false
		var elapsed_upload_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		return {
			"done": true,
			"work_done": 0,
			"elapsed_ms": elapsed_upload_ms,
			"progress_ratio": 1.0,
			"phase": "upload",
			"path": String(_pending_prepare.get("path", "unknown")),
			"prepare_ms": float(_pending_prepare.get("prepare_ms", 0.0)),
			"image_ms": float(upload.get("image_ms", 0.0)),
			"upload_ms": float(upload.get("upload_ms", 0.0)),
			"dirty_cells": int(_pending_prepare.get("dirty_cells", 0)),
			"dirty_ratio": float(_pending_prepare.get("dirty_ratio", 0.0)),
		}
	var prep: Dictionary = baker.prepare_sea_ice_fraction_atlas(map, world_data)
	_pending_prepare = prep
	if bool(prep.get("prepared", false)) and bool(prep.get("dirty", false)):
		_pending_upload = true
	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	return {
		"done": true,
		"work_done": map.cell_count() if map != null else 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 0.5 if _pending_upload else 1.0,
		"phase": "prepare",
		"path": String(prep.get("path", "unknown")),
		"prepare_ms": float(prep.get("prepare_ms", elapsed_ms)),
		"image_ms": 0.0,
		"upload_ms": 0.0,
		"dirty_cells": int(prep.get("dirty_cells", 0)),
		"dirty_ratio": float(prep.get("dirty_ratio", 0.0)),
	}


func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = _SusPolicyScript.StridePolicy.new(stride, 0)
