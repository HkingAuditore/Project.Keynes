extends "res://scripts/simulation/sus/sus_job.gd"
class_name EnumAtlasUploadJob

const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var baker: MapBakerScript = null
var map: MapData = null
var world: WorldData = null
var hex_size: float = 0.0
var stride: int = 2


func _init(p_generator, p_baker: MapBakerScript, p_map: MapData,
		p_world: WorldData, p_hex_size: float, p_stride: int) -> void:
	id = &"enum_atlas_upload"
	priority = 140
	slice_budget_ms = 0.45
	max_slices_per_tick = 1
	must_run = false
	# Starvation 防护（2026-05-11）：cover/veg 纹理上传被 frame_budget_exhausted
	# 频繁跳过（30 ticks 内 ran=2 / skipped=11）。阈值 6 保证地表变化能稳定可视化。
	starvation_threshold = 0
	generator = p_generator
	baker = p_baker
	map = p_map
	world = p_world
	hex_size = p_hex_size
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or baker == null or map == null or world == null:
		return false
	if not generator.has_method("has_pending_enum_atlas_upload"):
		return false
	if not bool(generator.has_pending_enum_atlas_upload()):
		return false
	return super.should_run(ctx)


func run_slice(_ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or baker == null or map == null or world == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	var axis: String = ""
	if generator.has_method("consume_pending_enum_atlas_axis"):
		axis = str(generator.consume_pending_enum_atlas_axis())
	if axis == "biome":
		baker.rebake_biome_tex_only(map, world, hex_size)
	elif axis == "cover":
		baker.rebake_cover_tex_only(map, world, hex_size)
	elif axis == "vegetation":
		baker.rebake_vegetation_tex_only(map, world, hex_size)

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
		"done": true,
		"work_done": 1 if axis != "" else 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"axis": axis,
		"path": str(report.get("path", "")),
		"stage_name": "atlas_%s" % axis if axis != "" else "atlas_noop",
		"substage": str(report.get("path", "")),
	}


func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)
