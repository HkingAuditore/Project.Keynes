extends SceneTree

const WorkerVisual = preload("res://scripts/simulation/ocean/ocean_currents_worker_visual.gd")
const PIXEL_SIZE := Vector2i(3, 2)
const SLICE_COUNT := 3


class PhysicsSource extends RefCounted:
	var info: Dictionary
	var fields: Dictionary
	var full_reads := 0

	func publish(map: MapData, day: int, direction: float) -> void:
		info = {
			"ready": true, "ok": true, "authoritative": true,
			"map_instance_id": map.get_instance_id(), "cell_count": map.soa_size(),
			"committed_day": day, "input_generation": day, "generation": day,
		}
		var vector := PackedFloat32Array()
		var zero := PackedFloat32Array()
		var speed := PackedFloat32Array()
		vector.resize(map.soa_size())
		zero.resize(map.soa_size())
		speed.resize(map.soa_size())
		vector.fill(direction)
		speed.fill(1.7)
		fields = info.merged({
			"slp": zero, "wind_x": vector, "wind_y": zero, "wind_speed": speed,
			"ocean_current_x": vector, "ocean_current_y": zero, "upwelling": vector,
		})

	func get_climate_physics_commit_info() -> Dictionary:
		return info

	func get_climate_physics_read_view() -> Dictionary:
		full_reads += 1
		return fields

	func native_ocean_physical_step(_context: Dictionary) -> Dictionary:
		return {}


var _job: OceanCurrentsJob
var _source := PhysicsSource.new()
var _tick := 0
var _commits := 0
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var map := _make_map()
	var world := _make_world(map)
	var baker := MapBaker.new()
	if not _bind_rasterizer(baker, map):
		quit(1)
		return
	var cfg := MapConfig.make(map.width, map.height)
	cfg.climate_profile = ClimateProfile.new()
	cfg.climate_profile.ocean_pixel_subslice_count = SLICE_COUNT
	_job = OceanCurrentsJob.new(baker, map, world, cfg, 10.0, 30, SLICE_COUNT)
	_job.on_commit = func(): _commits += 1
	_source.publish(map, 1, 1.0)
	_job.data_core_world_ext = _source

	var original := _pixels(world)
	DCFeatureFlags.set_ocean_current_visual(false)
	var idle := _slice(0.25)
	_expect(idle.committed_day == 1 and _source.full_reads == 0 and _job._visual_round_id == 0,
		"closed layer reports the committed day without a full read")

	DCFeatureFlags.set_ocean_current_visual(true)
	_expect(_slice(0.25).stage_name == "ocean_pixel_slice" and _source.full_reads == 1,
		"first draw reads the complete fields once")
	_source.publish(map, 2, -1.0)
	_expect(_raster_to_pending(0.5) and _source.full_reads == 1 and _pixels(world) == original,
		"continuation neither rereads physics nor publishes partial pixels")
	_expect(_commit(0.5) and _source.full_reads == 1 and _pixels(world) == _expected_pixels(1),
		"deferred upload contains only day one's currents, upwelling and wind")
	_expect(baker._runtime_physics_visual_view.is_empty(), "completed draw releases its pinned fields")

	idle = _slice(0.75)
	_expect(idle.committed_day == 2 and _source.full_reads == 1 and _commits == 1,
		"same-season idle reports the newer date without drawing it")
	DCFeatureFlags.set_ocean_current_visual(false)
	_slice(0.75)
	DCFeatureFlags.set_ocean_current_visual(true)
	_expect(_slice(0.75).done and _source.full_reads == 1 and _commits == 1
		and _pixels(world) == _expected_pixels(1), "reopening in the same season keeps the displayed pixels")
	var mobile := WorkerVisual.run_if_authoritative(_job, _context(1.25), Time.get_ticks_usec(), true)
	_expect(mobile.done and _source.full_reads == 1 and _job._visual_round_id == 1,
		"desktop probe exercises the mobile skip after the first completed draw")
	DCFeatureFlags.set_ocean_current_visual(false)
	_slice(1.25)
	_expect(_source.full_reads == 1 and _commits == 1, "closed layer skips a due season")
	DCFeatureFlags.set_ocean_current_visual(true)
	_slice(1.25)
	_expect(_raster_to_pending(1.25) and _commit(1.25)
		and _source.full_reads == 2 and _pixels(world) == _expected_pixels(-1),
		"reopening in the due season draws the latest commit once")

	_check_rejections()
	_check_source_switch()
	_check_map_switch()
	_check_authority_loss()
	print("ocean currents visual query: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check_rejections() -> void:
	var displayed := _pixels(_job.world)
	var reads := _source.full_reads
	var round_id := _job._visual_round_id
	_source.publish(_job.map, 3, 1.0)
	_source.info.input_generation = 0
	_expect(_slice(2.25).raster_fallback_reason == "physics_visual_commit_invalid"
		and _source.full_reads == reads, "invalid commit information is refused before a full read")
	_source.info.input_generation = 3
	_source.fields.input_generation = 4
	_expect(_slice(2.25).raster_fallback_reason == "physics_visual_view_invalid",
		"the full view must match the checked commit")
	_source.fields.input_generation = 3
	_source.fields.upwelling = PackedFloat32Array()
	_expect(_slice(2.25).raster_fallback_reason == "physics_visual_view_invalid",
		"missing raster input is refused")
	_expect(_pixels(_job.world) == displayed and _job._visual_round_id == round_id
		and _source.full_reads == reads + 2, "rejected data leaves the display and season gate intact")
	_source.publish(_job.map, 3, 1.0)


func _check_source_switch() -> void:
	var displayed := _pixels(_job.world)
	var commits := _commits
	_slice(2.25)
	_expect(_raster_to_pending(2.25), "valid data can start the previously rejected season")
	var previous := _source
	_source = PhysicsSource.new()
	_source.publish(_job.map, 4, 0.0)
	_job.data_core_world_ext = _source
	_expect(_slice(2.25).stage_name == "ocean_pixel_slice" and _source.full_reads == 1
		and _commits == commits and _pixels(_job.world) == displayed,
		"switching providers discards pixels waiting to upload")
	_expect(_raster_to_pending(2.25) and _commit(2.25) and _source.full_reads == 1
		and _pixels(_job.world) == _expected_pixels(0), "replacement provider draws a complete round")
	_expect(previous.full_reads == 5, "old provider stops at its last draw attempt")


func _check_map_switch() -> void:
	var previous_world := _job.world
	var displayed := _pixels(previous_world)
	_slice(3.25)
	_expect(_job._visual_round_active, "old map has partial pixels")
	_job.map = _make_map()
	_job.world = _make_world(_job.map)
	var empty_display := _pixels(_job.world)
	if not _bind_rasterizer(_job.baker, _job.map):
		return
	_expect(_slice(3.25).raster_fallback_reason == "physics_visual_map_mismatch"
		and not _job._visual_round_active and _source.full_reads == 2
		and _pixels(previous_world) == displayed and _pixels(_job.world) == empty_display,
		"a same-sized replacement map refuses the old commit and drops the partial pixels")
	_source.publish(_job.map, 5, 1.0)
	_source.info.cell_count += 1
	_expect(_slice(3.25).raster_fallback_reason == "physics_visual_map_mismatch"
		and _source.full_reads == 2, "wrong map dimensions are refused without a full read")
	_source.publish(_job.map, 5, 1.0)
	_slice(3.25)
	_expect(_raster_to_pending(3.25) and _commit(3.25) and _source.full_reads == 3
		and _pixels(_job.world) == _expected_pixels(1), "replacement map draws only its own data")


func _check_authority_loss() -> void:
	var displayed := _pixels(_job.world)
	_slice(0.25)
	_expect(_raster_to_pending(0.25), "worker round is waiting to publish")
	var reads := _source.full_reads
	var commits := _commits
	_source.info.authoritative = false
	# Choose a tick between legacy physical and wind updates.
	_tick += _job.wind_period_ticks - _tick % _job.wind_period_ticks
	_expect(_slice(0.25).stage_name == "ocean_policy_wait" and _source.full_reads == reads
		and _commits == commits and _pixels(_job.world) == displayed
		and _job.baker._runtime_physics_visual_view.is_empty(),
		"authority loss returns to the legacy path without publishing the worker's pending pixels")
	_source.publish(_job.map, 6, -1.0)
	_slice(0.25)
	_expect(_raster_to_pending(0.25) and _commit(0.25) and _source.full_reads == reads + 1
		and _pixels(_job.world) == _expected_pixels(-1), "regaining authority starts with its new commit")


func _make_map() -> MapData:
	var map := MapData.new(2, 1)
	for q in map.width:
		var cell := HexCell.new()
		cell.q = q
		cell.s = -q
		cell.terrain = TerrainType.TERRAIN.OCEAN
		map.set_cell(cell)
	map.rebuild_soa_from_cells()
	return map


func _make_world(map: MapData) -> WorldData:
	var world := WorldData.new()
	world.derived_size = PIXEL_SIZE
	for pixel in PIXEL_SIZE.x * PIXEL_SIZE.y:
		world.pixel_to_cell_lookup.append(map.get_cell(pixel % map.width, 0))
	return world


func _bind_rasterizer(baker: MapBaker, map: MapData) -> bool:
	var ext := NativeWorld.create()
	if not _expect(ext != null and ext.bind_map_data(map), "native rasterizer binds the fixture"):
		return false
	baker.set_world_ext(ext)
	return true


func _context(phase: float) -> SusTickContext:
	_tick += 1
	return SusTickContext.make(_tick, _tick, phase, 1.0, &"day_changed")


func _slice(phase: float) -> Dictionary:
	return _job.run_slice(_context(phase))


func _raster_to_pending(phase: float) -> bool:
	for _index in range(1, SLICE_COUNT):
		if not _slice(phase).get("raster_used_cpp", false):
			return false
	return _job._visual_pending_commit


func _commit(phase: float) -> bool:
	return _slice(phase).stage_name == "ocean_pixel_commit_deferred"


func _pixels(world: WorldData) -> Array:
	return [world.ocean_current_buffer, world.ocean_upwelling_buffer, world.wind_field_buffer]


func _expected_pixels(direction: int) -> Array:
	var vectors := PackedByteArray()
	var upwelling := PackedByteArray()
	var vector_byte: int = [0, 128, 255][direction + 1]
	var upwelling_byte: int = [1, 128, 255][direction + 1]
	for _pixel in PIXEL_SIZE.x * PIXEL_SIZE.y:
		vectors.append_array(PackedByteArray([vector_byte, 128]))
		upwelling.append(upwelling_byte)
	return [vectors, upwelling, vectors]


func _expect(ok: bool, description: String) -> bool:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[FAIL] " + description)
	return ok
