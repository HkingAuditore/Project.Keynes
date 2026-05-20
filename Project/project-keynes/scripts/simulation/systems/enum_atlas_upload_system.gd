extends DCSystem
class_name EnumAtlasUploadSystem

## Phase C.3 — DCSystem 改写自 [`EnumAtlasUploadJob`](../sus/jobs/enum_atlas_upload_job.gd)。
##
## 行为完全等价（迁移到 DCSystem 框架仅为统一调度入口 + reads/writes 自动校验）；
## DCSystemScheduler 接管时直接 register_system(EnumAtlasUploadSystem.new(...))。
##
## reads / writes 声明：
##   - reads:  cell.cover / cell.vegetation（baker 从 cell.<field> 读取来烘焙
##             atlas；当前 baker 仍直接走 cell，B.2 完成后会改走 ViewAdapter）
##   - writes: 无（baker 写的是 GPU 纹理，不写 cell-level component）
##
## feature_flag：留空（基础设施 system，无 toggle）。

const _MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const _SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var baker: _MapBakerScript = null
var map: MapData = null
var world_data: WorldData = null  # 与 DCSystem._world (DCWorld) 区分
var hex_size: float = 0.0
var stride: int = 2
var world_ext = null


func _init(p_generator, p_baker: _MapBakerScript, p_map: MapData,
		p_world: WorldData, p_hex_size: float, p_stride: int, p_world_ext = null) -> void:
	id = &"enum_atlas_upload"
	priority = 140
	slice_budget_ms = 0.45
	max_slices_per_tick = 1
	must_run = false
	starvation_threshold = 0
	generator = p_generator
	baker = p_baker
	map = p_map
	world_data = p_world
	hex_size = p_hex_size
	stride = max(1, p_stride)
	world_ext = p_world_ext
	policy = _SusPolicyScript.StridePolicy.new(stride, 0)


# ─── DCSystem 声明 ─────────────────────────────────────────────────

func declare_reads() -> Array[StringName]:
	# baker 烘焙 cover_tex 与 vegetation_tex 时读 cell.cover / cell.vegetation。
	return [DCComponentIds.CELL_TERRAIN, DCComponentIds.CELL_COVER, DCComponentIds.CELL_VEGETATION]


func declare_writes() -> Array[StringName]:
	# 仅写 GPU 纹理，不写任何 cell-level component。
	return []


func feature_flag() -> StringName:
	return &""  # 常驻挂载，无 toggle


# ─── tick / 兼容 SusJob ────────────────────────────────────────────

func should_run(ctx: SusTickContext) -> bool:
	if generator == null or baker == null or map == null or world_data == null:
		return false
	if not generator.has_method("has_pending_enum_atlas_upload"):
		return false
	if not bool(generator.has_pending_enum_atlas_upload()):
		return false
	return super.should_run(ctx)


func tick(_ctx) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or baker == null or map == null or world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}
	if world_ext != null and baker.has_method("set_world_ext"):
		baker.set_world_ext(world_ext)
	var axis: String = ""
	if generator.has_method("consume_pending_enum_atlas_axis"):
		axis = str(generator.consume_pending_enum_atlas_axis())
	if axis == "biome":
		baker.rebake_biome_tex_only(map, world_data, hex_size)
	elif axis == "cover":
		baker.rebake_cover_tex_only(map, world_data, hex_size)
	elif axis == "vegetation":
		baker.rebake_vegetation_tex_only(map, world_data, hex_size)
	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	var report: Dictionary = {}
	if baker != null and baker.has_method("get_last_enum_atlas_upload_report"):
		report = baker.get_last_enum_atlas_upload_report()
	if report.is_empty():
		report = {"axis": axis, "elapsed_ms": elapsed_ms, "path": "unknown"}
	report["axis"] = axis
	report["elapsed_ms"] = elapsed_ms
	if generator.has_method("record_enum_atlas_upload_report"):
		generator.record_enum_atlas_upload_report(report)
	elif generator.has_method("record_enum_atlas_upload"):
		generator.record_enum_atlas_upload(axis, elapsed_ms)
	return {
		"stage_name": "atlas_%s" % axis if axis != "" else "atlas_noop",
		"substage": str(report.get("path", "")),
		"axis": axis,
		"path": str(report.get("path", "")),
		"done": true,
		"work_done": 1 if axis != "" else 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
	}


func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = _SusPolicyScript.StridePolicy.new(stride, 0)
