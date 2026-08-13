extends DCSystem
class_name BioOccupancyDailySystem

## Daily occupancy: local extinction and agricultural introduce every day;
## neighbor diffusion on an internal cadence. Native authority is
## `run_bio_occupancy_pass`. Country knowledge is submitted only for 0→1
## occupancy on already-explored cells.

const _SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var diffusion_stride: int = 8
var _last_path: String = "none"


func _init(p_generator, p_map: MapData, p_diffusion_stride: int = 8) -> void:
	id = &"bio_occupancy_daily"
	priority = 121
	slice_budget_ms = 0.40
	max_slices_per_tick = 1
	must_run = true
	generator = p_generator
	map = p_map
	diffusion_stride = maxi(1, p_diffusion_stride)
	policy = _SusPolicyScript.StridePolicy.new(1, 0)


func declare_reads() -> Array[StringName]:
	return [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_IS_WATER,
		DCComponentIds.CELL_HAS_RIVER,
		DCComponentIds.CELL_EXPLORED,
		DCComponentIds.CELL_RES_PASTURE_RESERVE,
		DCComponentIds.CELL_RES_WILD_GAME_RESERVE,
		DCComponentIds.CELL_RES_ARABLE_LAND_RESERVE,
		DCComponentIds.CELL_RES_PADDY_LAND_RESERVE,
		DCComponentIds.CELL_RES_PLANTATION_LAND_RESERVE,
		DCComponentIds.CELL_LANDMASS_ID,
		DCComponentIds.CELL_PROVINCE_ID,
	]


func declare_writes() -> Array[StringName]:
	return [DCComponentIds.CELL_BIO_OCCUPANCY_BITS]


func declare_pools() -> Array[StringName]:
	return [DCComponentIds.POOL_CELLS]


func feature_flag() -> StringName:
	return &""


func tick(ctx) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	if generator == null or map == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}
	var day_index := 0
	if ctx != null:
		day_index = int(ctx.day_index)
	var run_diffusion := (day_index % diffusion_stride) == 0
	var res: Dictionary = {}
	if generator.has_method("run_bio_occupancy_pass_native"):
		res = generator.run_bio_occupancy_pass_native(map, run_diffusion, day_index)
	_last_path = str(res.get("path", "none"))
	_submit_occupancy_discoveries(res, day_index)
	var elapsed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	return {
		"done": true,
		"work_done": map.cell_count(),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"stage_name": "bio_occupancy_daily",
		"path": _last_path,
		"run_diffusion": run_diffusion,
		"newly_occupied": int((res.get("newly_occupied_cells", PackedInt32Array()) as PackedInt32Array).size()),
	}


func _submit_occupancy_discoveries(res: Dictionary, day_index: int) -> void:
	if generator == null or not generator.has_method("get_country_facade") \
			or not generator.has_method("gameplay_start_report"):
		return
	var facade = generator.get_country_facade()
	if facade == null:
		return
	var start_cell := int(generator.gameplay_start_report().get("cell", -1))
	if start_cell < 0:
		return
	var handle := int(facade.cell_summary(start_cell).get("country_handle", 0))
	if handle == 0:
		return
	var cells: PackedInt32Array = res.get("newly_occupied_cells", PackedInt32Array())
	var signals: PackedInt32Array = res.get("newly_occupied_signal_ids", PackedInt32Array())
	if cells.size() != signals.size() or cells.is_empty():
		return
	var commands: Array[Dictionary] = []
	var day := day_index + 1
	for i in range(cells.size()):
		commands.append({
			"opcode": CountryFacade.Opcode.DISCOVER_COUNTRY_SIGNAL,
			"target_handle": handle,
			"signal": int(signals[i]),
			"cell": int(cells[i]),
			"value": 1,
			"effective_day": day,
			"sequence": int(cells[i]) * 32 + i,
		})
	if not commands.is_empty():
		facade.submit(commands)
