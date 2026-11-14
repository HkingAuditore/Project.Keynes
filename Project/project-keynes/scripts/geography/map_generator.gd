class_name MapGenerator
signal bake_progress(stage: String, fraction: float)
const TerrainGeneratorScript = preload("res://scripts/geography/map_generation/terrain_gen.gd")
const MapGenNativeDailyRuntimeScript = preload("res://scripts/simulation/climate/mapgen_native_daily_runtime.gd")
const MapGenClimatePassesAScript = preload("res://scripts/simulation/climate/mapgen_climate_passes_a.gd")

signal economy_runtime_fatal(day_index: int, reason: String, report: Dictionary)
const WindHeatTransportScript = preload("res://scripts/simulation/climate/wind_heat_transport.gd")
const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")
const DCClimateMath = preload("res://scripts/simulation/climate/climate_math.gd")
const ClimateProfileScript = preload("res://scripts/data/climate_profile.gd")
const DetailScatterChangeSetScript = preload("res://scripts/data/detail_scatter_change_set.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const EffectFacadeScript = preload("res://scripts/effect/effect_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EconomyTestBootstrapScript = preload("res://scripts/economy/economy_test_bootstrap.gd")
const StartLocationPolicyScript = preload("res://scripts/game/start_location_policy.gd")
const DiagnosticsBusScript = preload("res://scripts/geography/diagnostics_bus.gd")
const NativeGenerationBridgeScript = preload("res://scripts/geography/map_generation/native_generation_bridge.gd")
const NativeDailyBundleBuilderScript = preload("res://scripts/simulation/climate/native_daily_bundle_builder.gd")
const NativeDailyPublishScript = preload("res://scripts/simulation/climate/native_daily_publish.gd")
const RuntimeClimateCaptureScript = preload("res://scripts/simulation/climate/runtime_climate_capture.gd")
const SeasonRefreshCoordinatorScript = preload("res://scripts/simulation/climate/season_refresh_coordinator.gd")
const MapResourceInitializerScript = preload("res://scripts/simulation/economy/map_resource_initializer.gd")
const MapRuntimeBridgeScript = preload("res://scripts/game/map_runtime_bridge.gd")
const MapRulesInitializerScript = preload("res://scripts/game/map_rules_initializer.gd")
const MapCountryInitializerScript = preload("res://scripts/country/map_country_initializer.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")
const NativeDailySimJobScript = preload("res://scripts/simulation/sus/jobs/native_daily_sim_job.gd")
const DCSystemSchedulerScript = preload("res://scripts/data_core/dc_system_scheduler.gd")
const GameplayEventBusScript = preload("res://scripts/data_core/gameplay_event_bus.gd")
const NativeWorld = preload("res://scripts/data_core/native_world.gd")
const WeatherResearchSignalPublisherScript = preload(
	"res://scripts/research/weather_research_signal_publisher.gd")
const ClimateDailySystemScript = preload("res://scripts/simulation/systems/climate_daily_system.gd")
const SeaIceDailySystemScript = preload("res://scripts/simulation/systems/sea_ice_daily_system.gd")
const NaturalResourceDailySystemScript = preload("res://scripts/simulation/systems/natural_resource_daily_system.gd")
const BioOccupancyDailySystemScript = preload("res://scripts/simulation/systems/bio_occupancy_daily_system.gd")
const OceanCurrentsSystemScript = preload("res://scripts/simulation/systems/ocean_currents_system.gd")
const WeatherDCSystemScript = preload("res://scripts/simulation/systems/weather_system.gd")
const SeasonRefreshSystemScript = preload("res://scripts/simulation/systems/season_refresh_system.gd")
const EnumAtlasUploadSystemScript = preload("res://scripts/simulation/systems/enum_atlas_upload_system.gd")
const DynamicVisualAtlasUploadSystemScript = preload("res://scripts/simulation/systems/dynamic_visual_atlas_upload_system.gd")
const NativeEnvironmentRuntimeSystemScript = preload("res://scripts/simulation/systems/native_environment_runtime_system.gd")
const EffectRuntimeSystemScript = preload("res://scripts/simulation/systems/effect_runtime_system.gd")
const GameplayEffectSystemScript = preload("res://scripts/simulation/systems/gameplay_effect_system.gd")
const DCSusSystemsBootstrapScript = preload("res://scripts/bootstrap/sus_systems_bootstrap.gd")
@export var climate_profile: ClimateProfile = null
var _phys_skip_logged: bool = false
var _mapgen_native_daily_runtime: RefCounted = null
var _mapgen_climate_passes_a: RefCounted = null

var _wind_heat_transport: RefCounted = null

func _get_terrain_generator() -> RefCounted:
	if _terrain_generator == null:
		_terrain_generator = TerrainGeneratorScript.new(self)
	return _terrain_generator

func _get_wind_heat_transport() -> RefCounted:
	if _wind_heat_transport == null:
		_wind_heat_transport = WindHeatTransportScript.new(self)
	return _wind_heat_transport

func _get_mapgen_native_daily_runtime() -> RefCounted:
	if _mapgen_native_daily_runtime == null:
		_mapgen_native_daily_runtime = MapGenNativeDailyRuntimeScript.new(self)
	return _mapgen_native_daily_runtime

func _get_mapgen_climate_passes_a() -> RefCounted:
	if _mapgen_climate_passes_a == null:
		_mapgen_climate_passes_a = MapGenClimatePassesAScript.new(self)
	return _mapgen_climate_passes_a

func _get_climate_pass_b_module() -> RefCounted:
	_ensure_daily_pass_modules()
	return _climate_pass_b_module

func _c() -> ClimateProfile:
	return _get_native_generation_bridge()._c()
func _ocean_daily_wind_period_ticks_for(cp: ClimateProfile) -> int:
	if cp != null and cp.get("ocean_daily_wind_period_ticks") != null:
		return clampi(int(cp.ocean_daily_wind_period_ticks), 1, 60)
	return _OCEAN_DAILY_WIND_PERIOD_TICKS_DEFAULT
func _calendar_days_per_year() -> int:
	return _get_native_generation_bridge()._calendar_days_per_year()
func _season_phase_to_day_of_year(season_phase: float, days_per_year: int = 0) -> int:
	var dpy: int = clampi(days_per_year if days_per_year > 0 else _calendar_days_per_year(), 1, 3660)
	var p: float = fposmod(season_phase, 4.0)
	return clampi(int(floor((p / 4.0) * float(dpy))), 0, dpy - 1)
func _is_annual_log_tick(counter: int) -> bool:
	var dpy: int = _calendar_days_per_year()
	return counter == 1 or (counter > 0 and (counter % dpy) == 0)
var _height_warp:     FastNoiseLite     # 域扭曲；现仅供 rain-shadow jitter C++ 桥
var _rng:             RandomNumberGenerator
var _baker: MapBaker = null
var _terrain_generator: RefCounted = null
var _native_generation_bridge: RefCounted = null
var _native_daily_bundle_builder: RefCounted = null
var _native_daily_publish: RefCounted = null
var _runtime_climate_capture: RefCounted = null
var _season_refresh_coordinator: RefCounted = null
var _map_resource_initializer: RefCounted = null
var _map_runtime_bridge: RefCounted = null
var _map_rules_initializer: RefCounted = null
var _map_country_initializer: RefCounted = null
var _last_cfg: MapConfig = null
var _climate_pass_a_module: DCClimatePassA = null
var _climate_pass_b_module: DCClimatePassB = null
var _ocean_water_pass_module: DCOceanWaterPass = null
var _ocean_land_pass_module: DCOceanLandPass = null
var _sea_ice_daily_pass_module: DCSeaIceDailyPass = null
var _transpiration_pass_module: DCTranspirationPass = null
var _diagnostics_bus: RefCounted = DiagnosticsBusScript.new()
var _last_sea_ice_daily_breakdown: Dictionary = {}
var _last_climate_dirty_ratio: float = 1.0
var _last_climate_visited_ratio: float = 1.0
var _last_climate_pass_b_path: String = "full"  # "full" | "sparse"
var _pa_last_pushed_cells: int = 0
var _pa_last_total_cells: int = 0
var _weather_round_t0_us: int = 0
var _weather_round_tick_ms: float = 0.0
var _weather_round_fronts: Array[WeatherFront] = [] as Array[WeatherFront]
var _enum_atlas_biome_dirty: bool = false
var _enum_atlas_cover_dirty: bool = false
var _enum_atlas_vegetation_dirty: bool = false
var _last_enum_atlas_upload_breakdown: Dictionary = {}
var _pending_detail_scatter_refresh_indices: PackedInt32Array = PackedInt32Array()
var _pending_detail_scatter_change_sets: Array = []
var _detail_scatter_change_generation: int = 0
var _season_stage4_deltas: Dictionary = {}
var _last_sea_ice_atlas_upload_breakdown: Dictionary = {}
var _current_fast_tick_idx: int = 0
var _runtime_input_generation: int = 0
var _runtime_climate_trace_pending: Dictionary = {}
var _runtime_climate_reference_last_day: int = -1
var _runtime_climate_reference_last_hash: int = 0
var _runtime_climate_reference_failures: int = 0
var _runtime_climate_reference_last_error: String = ""
var _runtime_climate_catalog_hash: int = 0
var _runtime_climate_catalog_map_id: int = 0
var _runtime_climate_topology_generation: int = 1
var _runtime_climate_topology_map_id: int = 0
var _runtime_climate_neighbor_offsets: PackedInt32Array = PackedInt32Array()
var _runtime_climate_neighbor_offsets_map_id: int = 0
var _worker_environment_publisher_callsite: int = 0
var _save_prefetch_suspend_callback: Callable = Callable()
var _environment_publish_callsite_mask: int = 0
var _environment_publish_count: int = 0
var _environment_publish_suppressed: int = 0
var _environment_publish_orphan_day: int = -1
const ENV_CALLSITE_HOST_DAY_CHANGED := 1
const ENV_CALLSITE_SUS_TICK := 2
const ENV_CALLSITE_INLINE_DAY := 4
const ENV_CALLSITE_PREFETCH := 8
var _last_climate_breakdown: Dictionary = {}
var _pending_season_refresh: bool = false
var _season_refresh_in_progress: bool = false
var _pending_season_idx: int = 0
var _last_season_refresh_day: int = -1
var _last_capture_season_refresh_day: int = -1
var _last_season_refresh_breakdown: Dictionary = {}
var _scatter_sync_snap_landform := PackedByteArray()
var _scatter_sync_snap_vegetation := PackedByteArray()
var _scatter_sync_snap_cover := PackedByteArray()
var _last_detail_scatter_sync: Dictionary = {}
var detail_scatter_tick_sync_debug: bool = false
var _season_round_slots_fresh: bool = false
var _season_round_slots_skip_count: int = 0
var _season_round_refresh_keys := PackedStringArray([
	"cell_terrain", "cell_base_terrain", "cell_is_water",
	"cell_moisture", "cell_base_moisture", "cell_water_balance_30d",
	"cell_elevation", "cell_lat_norm", "cell_temp", "cell_temp_365d",
	"cell_wind_x", "cell_wind_y", "cell_has_river", "cell_river_flow",
	"cell_landform", "cell_vegetation", "cell_cover", "cell_snow_cover",
])
var _climate_daily_round_slots_fresh: bool = false
var _climate_daily_round_slots_skip_count: int = 0
var _climate_daily_round_slots_refresh_count: int = 0
var _season_round_slots_refresh_count: int = 0
var _season_round_b_plus_handle: int = 0
var _season_round_b_plus_logged: Dictionary = {}
var _season_round_b_plus_native_ms: float = 0.0
var _season_round_b_plus_slices_used: int = 0
var _season_round_b_plus_stages_done: int = 0
var _season_round_b_plus_publish_active: bool = false
var _season_round_b_plus_publish_cursor: int = 0
var _season_round_b_plus_facade_published: bool = false
var _season_round_b_plus_publish_terrain_fixed: int = 0
var _season_round_b_plus_publish_axis_fixed: int = 0
var _season_round_b_plus_publish_state_fixed: int = 0
var _season_knob_row_idx_cache: PackedInt32Array = PackedInt32Array()
var _season_knob_jitter_cache: PackedFloat32Array = PackedFloat32Array()
var _season_knob_cache_map_id: int = 0
var _season_knob_cache_cfg_id: int = 0
var _season_knob_cache_warp_id: int = 0
var _season_knob_cache_n: int = -1
var _b_plus_rounds_total: int = 0
var _b_plus_rounds_b_plus: int = 0
var _b_plus_rounds_fallback: int = 0
var _b_plus_slices_used_samples: PackedInt32Array = PackedInt32Array()
var _b_plus_stages_done_samples: PackedInt32Array = PackedInt32Array()
var _b_plus_native_ms_samples: PackedFloat32Array = PackedFloat32Array()
var _b_plus_wall_ms_samples: PackedFloat32Array = PackedFloat32Array()
var _b_plus_round_start_usec: int = 0
const _INSOL_MEAN_LUT_SIZE: int = 64                  # 65 桶，按 ny 离散，足够 80×60 图使用
const _INSOL_ANNUAL_SAMPLES: int = 16                 # 一年取 16 个 phase 采样点求平均
const _OCEAN_DAILY_WIND_PERIOD_TICKS_DEFAULT: int = 3
var _insol_mean_lut: PackedFloat32Array = PackedFloat32Array()
var _insol_mean_lut_tilt: float = -1.0                # 上次构表所用的 axial_tilt_deg，变化时失效
var _insol_driven_path_logged: bool = false           # 首次进入 insolation 主路径时打一次启动日志
const _INSOL_DAILY_LUT_SIZE: int = 64
var _last_hex_size: float = 22.0
var _current_season: int = -1
var _last_seed: int = 0
var _last_world: WorldData = null
var _weather_system: WeatherSystem = null
func get_weather_system() -> Object:
	return _weather_system
func get_data_core_world():
	return _data_core_world
func get_data_core_world_ext():
	return _data_core_world_ext
func get_gameplay_event_bus() -> Object:
	return _gameplay_event_bus
func _sync_data_core_runtime_terrain_mirror(map: MapData, reason: String) -> Dictionary:
	return _get_native_generation_bridge()._sync_data_core_runtime_terrain_mirror(map, reason)
func mark_runtime_terrain_mirror_dirty() -> void:
	_dc_terrain_mirror_dirty = true
func _climate_views_from_world(cp: ClimateProfile) -> Dictionary:
	return _get_native_generation_bridge()._climate_views_from_world(cp)
var _last_active_fronts: Array[WeatherFront] = [] as Array[WeatherFront]
var _weather_stride_logged: int = -1
var _refresh_daily_call_index: int = -1
var _weather_stage_b_call_index: int = -1
var _native_daily_hydrology_call_index: int = -1
var _native_daily_last_weather_embed_day: int = -1000000
var _typed_fields_migrated: bool = false
var _sus = null
var _sus_bootstrap: RefCounted = null
var _data_core_world: DCWorld = null
var _data_core_world_ext: RefCounted = null  # DCWorldExt（来自 gdext，无 GDScript class_name）
var _gameplay_event_bus: GameplayEventBus = GameplayEventBusScript.new()
const _DC_TERRAIN_MIRROR_SYNC_INITIAL_LOGS: int = 12
var _dc_terrain_mirror_sync_log_count: int = 0
var _dc_terrain_mirror_dirty: bool = true
var _ocean_water_done_phase: float = NAN
var _gdext_transp_runs: int = 0
var _gdext_transp_fallbacks: int = 0
var _gdext_transp_total_ms: float = 0.0
var _gdext_transp_first_attempt_logged: bool = false
var _gdext_transp_signature_checked: bool = false
var _gdext_transp_signature_ok: bool = false
var _gdext_transp_donor_table_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_albedo_table_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_ideal_temp_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_ideal_moist_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_temp_tol_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_moist_tol_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_weather_penalty_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_resistance_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_vegdyn_next_up_cached: PackedByteArray = PackedByteArray()
var _gdext_vegdyn_next_down_cached: PackedByteArray = PackedByteArray()
var _gdext_feedback_runs: int = 0
var _gdext_feedback_fallbacks: int = 0
var _gdext_feedback_total_ms: float = 0.0
var _gdext_feedback_first_attempt_logged: bool = false
var _gdext_feedback_signature_checked: bool = false
var _gdext_feedback_signature_ok: bool = false
var _gdext_stage_b_runs: int = 0
var _gdext_stage_b_fallbacks: int = 0
var _gdext_stage_b_total_ms: float = 0.0
var _gdext_stage_b_first_attempt_logged: bool = false
var _gdext_climate_b_runs: int = 0
var _gdext_climate_b_fallbacks: int = 0
var _gdext_climate_b_total_ms: float = 0.0
var _gdext_climate_b_first_attempt_logged: bool = false
var _gdext_climate_b_signature_checked: bool = false
var _gdext_climate_b_signature_ok: bool = false
var _gdext_climate_b_foliage_table_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_water_runs: int = 0
var _gdext_ocean_water_fallbacks: int = 0
var _gdext_ocean_water_total_ms: float = 0.0
var _gdext_ocean_water_first_attempt_logged: bool = false
var _gdext_ocean_water_signature_checked: bool = false
var _gdext_ocean_water_signature_ok: bool = false
var _gdext_ocean_land_runs: int = 0
var _gdext_ocean_land_fallbacks: int = 0
var _gdext_ocean_land_total_ms: float = 0.0
var _gdext_ocean_land_first_attempt_logged: bool = false
var _gdext_ocean_land_signature_checked: bool = false
var _gdext_ocean_land_signature_ok: bool = false
var _gdext_ocean_anomaly_buf_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_baseline_arr_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_current_x_arr_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_current_y_arr_cached: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_baseline_work_buf: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_temp_before_work_buf: PackedFloat32Array = PackedFloat32Array()
var _gdext_ocean_anomaly_work_buf: PackedFloat32Array = PackedFloat32Array()
var _gdext_wind_baseline_work_buf: PackedFloat32Array = PackedFloat32Array()
var _gdext_wind_temp_before_work_buf: PackedFloat32Array = PackedFloat32Array()
var _native_wind_baseline_cache: PackedFloat32Array = PackedFloat32Array()
var _native_wind_baseline_cache_map: MapData = null
var _native_daily_ema_all_initialized_cache_map: MapData = null
var _native_daily_ema_all_initialized_cache_size: int = 0
var _native_daily_ema_all_initialized_cache_true: bool = false
var _climate_ocean_slice_state: Dictionary = {}
const _CLIMATE_PASS_OCEAN_WATER: String = "ocean_water"
const _CLIMATE_PASS_OCEAN_LAND: String = "ocean_land"
const _CLIMATE_PASS_SEA_ICE: String = "sea_ice"
const _CLIMATE_PASS_STATUS_RUNNING: String = "running"
const _CLIMATE_PASS_STATUS_DONE: String = "done"
const _CLIMATE_PASS_STATUS_FAILED: String = "failed"
const _CLIMATE_PASS_STATUS_ABORTED: String = "aborted"
var _climate_pass_generation: int = 0
var _climate_pass_states: Dictionary = {}
var _gdext_sea_ice_runs: int = 0
var _gdext_sea_ice_fallbacks: int = 0
var _gdext_sea_ice_total_ms: float = 0.0
var _gdext_sea_ice_first_attempt_logged: bool = false
var _gdext_sea_ice_signature_checked: bool = false
var _gdext_sea_ice_signature_ok: bool = false
var _last_sea_ice_pass_day: float = -1.0
var _last_climate_pass_day: float = -1.0
var _climate_dt_cached_day: float = -1.0
var _climate_dt_cached_val: float = 1.0
var _last_weather_pass_day: float = -1.0
var _weather_dt_cached_day: float = -1.0
var _weather_dt_cached_val: float = 1.0
const _SEA_ICE_STAGE_NATIVE_COMPUTE: String = "native_compute"
const _SEA_ICE_STAGE_DENSE_SYNC_CHUNK: String = "dense_sync_chunk"
const _SEA_ICE_STAGE_TERRAIN_FLIP_CHUNK: String = "terrain_flip_chunk"
const _SEA_ICE_STAGE_COMMIT: String = "commit"
var _sea_ice_state_machine: Dictionary = {}
const _SEA_ICE_SLOW_DUMP_THRESHOLD_MS: float = 5.0
const _SEA_ICE_SLOW_DUMP_MIN_INTERVAL: int = 30
var _sea_ice_slow_dump_last_tick: int = -10000
const _WEATHER_SLOW_DUMP_TOTAL_THRESHOLD_MS: float = 5.0
const _WEATHER_SLOW_DUMP_CYCLONE_THRESHOLD_MS: float = 3.0
const _WEATHER_SLOW_DUMP_MIN_INTERVAL: int = 30
var _weather_slow_dump_last_tick: int = -10000
var _gdext_sea_ice_base_terrain_buf: PackedByteArray   = PackedByteArray()
var _gdext_sea_ice_tta_buf:          PackedFloat32Array = PackedFloat32Array()
var _gdext_sea_ice_upw_buf:          PackedFloat32Array = PackedFloat32Array()
var _gdext_sea_ice_temp_buf:         PackedFloat32Array = PackedFloat32Array()
var _gdext_sea_ice_insol_buf:        PackedFloat32Array = PackedFloat32Array()
func _validate_gdext_method_signature(method_name: String, expected_arg_count: int) -> bool:
	return _get_native_generation_bridge()._validate_gdext_method_signature(method_name, expected_arg_count)
var _ocean_currents_job: OceanCurrentsJob = null
var _ocean_currents_system = null
var _refresh_climate_daily_job = null
var _sea_ice_daily_job = null
var _natural_resource_daily_job = null
var _bio_occupancy_daily_job = null
var _bio_occupancy_slice_inflight: bool = false
var _bio_occupancy_day_pending: bool = false
var _native_daily_day_pending: bool = false
var _native_daily_climate_round_generation: int = 0
const _BIO_OCCUPANCY_KNOB_CACHE_VERSION: int = 2
var _bio_occupancy_knob_cache: Dictionary = {}
var _bio_occupancy_knob_cache_map_id: int = 0
var _bio_occupancy_knob_cache_n: int = -1
var _bio_occupancy_knob_cache_version: int = 0
var _bio_occupancy_native_configured_map_id: int = 0
var _bio_observation_country_handle: int = 0
var _economy_facade = null
var _economy_daily_job = null
var _country_facade = null
var _country_ai_facade = null
var _country_daily_job = null
var _modifier_facade = null
var _modifier_daily_job = null
var _trigger_facade = null
var _trigger_daily_job = null
var _effect_facade = null
var _effect_daily_job = null
var _gameplay_effect_job = null
var _ideology_facade = null
var _ideology_daily_job = null
var _military_facade = null
var _military_daily_job = null
var _military_registered_graph_active: bool = false
var _military_registered_graph_mode: int = 0
const ECONOMY_CONTINUATION_FALLBACK_BUDGET_MS := 8.0
const ECONOMY_CONTINUATION_MAX_SLICES_PER_FRAME := 64
const SAVE_BOUNDARY_COUNTRY_MAX_SLICES := 8
const NATIVE_DAILY_CONTINUATION_SLICE_HEADROOM_MS := 3.0
const BIO_OCCUPANCY_SLICE_CELLS := 2048
const EFFECT_ACK_CHAIN_MAX_PASSES := 8
const BARRIER_DIAG_LOG_STRIDE := 60
const RUNTIME_GRAPH_STALL_DIAG_PULSES := 30
const RUNTIME_GRAPH_STALL_DIAG_STRIDE := 300
const RUNTIME_GRAPH_STALL_RELEASE_PULSES := 1200
var _continuation_perf_pending: Dictionary = {}
var _barrier_diag_count: int = 0
var _runtime_graph_stall_day: int = -1
var _runtime_graph_stall_pulses: int = 0
var _runtime_graph_stall_released: bool = false
var _runtime_graph_economy_fatal_halted: bool = false
var _test_economy_bootstrap_enabled: bool = false
var _test_economy_population_scale: int = EconomyTestBootstrapScript.DEFAULT_POPULATION_SCALE
var _gameplay_start_context: Dictionary = {}
var _gameplay_start_report: Dictionary = {}
var _save_restore_preparation_enabled: bool = false
var _save_restore_seed: int = 0
var _natural_resource_pass_knobs: Dictionary = {}
var _deposit_noise_cache: Dictionary = {}
var _natural_resource_regen_factors_valid: bool = false
var _natural_resource_regen_factor_prime_ms: float = 0.0
var _last_natural_resource_report: Dictionary = {}
const NATURAL_RESOURCE_WILDERNESS_STRIDE: int = 60
const NATURAL_RESOURCE_LIVE_CATCHUP_MAX_DAYS: int = 5
var _natural_resource_last_day: PackedInt32Array = PackedInt32Array()
var _natural_resource_was_live: PackedByteArray = PackedByteArray()
var _natural_resource_refresh_keys: PackedStringArray = PackedStringArray([
	"cell_temp",
	"cell_moisture",
	"cell_is_water",
])
var _weather_refresh_system = null
var _weather_refresh_job: WeatherRefreshJob = null
var _dynamic_visual_atlas_upload_job = null
var _dyn_atlas_upload_stride: int = 2
var _enum_atlas_upload_job = null
var _native_daily_sim_job = null
var _native_environment_runtime_job = null
var _native_daily_configured: bool = false
var _runtime_graph_active: bool = false
var _capture_trace_left: int = 24
func _capture_trace(message: String) -> void:
	_get_native_generation_bridge()._capture_trace(message)
var _runtime_graph_last_country_generation: int = -1
var _runtime_graph_last_country_territory_generation: int = -1
var _runtime_graph_country_territory_sync_ms: float = 0.0
var _runtime_graph_country_event_dispatch_ms: float = 0.0
var _native_daily_last_result: Dictionary = {}
var _native_daily_slice_round_active: bool = false
var _native_daily_slice_unified_weather_embedded: bool = false
var _native_daily_slice_bundle_pass_keys: Array = []
var _native_daily_slice_active_bundle: Dictionary = {}
var _native_daily_slice_next_node_index: int = -1
var _native_daily_slice_range_active: bool = false
var _native_daily_finalizer_pending: bool = false
var _native_daily_finalizer_pending_res: Dictionary = {}
var _native_daily_finalizer_pending_breakdown: Dictionary = {}
var _native_daily_contract_round_seq: int = 0
var _native_daily_contract_sample_day: int = -1
var _native_daily_contract_sample_tick: int = -1
var _native_daily_contract_warned_over_budget: bool = false
var native_daily_slice_yield_nodes_override: PackedInt32Array = PackedInt32Array()
var _native_daily_slice_phase_locked: float = 0.0
var _native_daily_slice_temp_start_arr: PackedFloat32Array = PackedFloat32Array()
var _native_daily_slice_tta_start_arr: PackedFloat32Array = PackedFloat32Array()
var _native_daily_slice_thermal_start_arr: PackedFloat32Array = PackedFloat32Array()
var _native_daily_finalizer_heavy_diag: bool = false
var native_daily_finalizer_native_enabled: bool = true
const _NATIVE_DAILY_FINALIZER_DENSE_HINT_MARGIN: float = 0.10
const _NATIVE_DAILY_FINALIZER_DENSE_HINT_SAMPLE_PERIOD: int = 8
var _native_daily_finalizer_dense_hint_round: int = 0
var _native_daily_finalizer_prev_dirty_ratio_temp: float = -1.0
var _native_daily_finalizer_prev_dirty_ratio_tta: float = -1.0
var _native_daily_finalizer_prev_dirty_ratio_thermal: float = -1.0
const _NATIVE_DAILY_CONTRACT_FIXED_SLICE_ESTIMATE: int = 8
var _native_daily_round_bundle_accum_ms: float = 0.0
var _native_daily_round_native_accum_ms: float = 0.0
var _native_daily_round_apply_accum_ms: float = 0.0
var _native_daily_round_slice_count: int = 0
var _native_daily_static_bundle_cache_token: String = ""
var _native_daily_static_bundle_cache: Dictionary = {}
var _native_generation_base_report: Dictionary = {}
var last_generation_error: Dictionary = {}
var _mapgen_started_usec: int = 0
var _mapgen_stage: String = "preparing"
const MAPGEN_REQUIRED_NATIVE_METHODS := [
	"run_native_world_generate_full_pass",
	"run_native_world_generate_base_pass",
	"run_native_world_generate_post_base_pass",
	"run_bake_geometry_fields_pass",
]
var _native_daily_shadow_probe_logged: bool = false
var _unified_fast_tick_first_log_done: bool = false
var _unified_fast_tick_warned_fallback: bool = false
var _native_daily_front_signature: String = ""
var _native_daily_front_slot_sigs: PackedStringArray = PackedStringArray()
var _sus_map: MapData = null
var _sus_world: WorldData = null
var _environment_runtime: RefCounted = null
var _season_refresh_job = null
var _world_clock_ref = null
var _season_stage_path_logged: Dictionary = {}
var _row_lat_temp: PackedFloat32Array = PackedFloat32Array()
var _row_season_off: PackedFloat32Array = PackedFloat32Array()
var _row_tables_season: int = -1
var _row_tables_height: int = 0
func _ensure_row_tables(cfg: MapConfig, season: int) -> void:
	_get_native_generation_bridge()._ensure_row_tables(cfg, season)
func _ensure_daily_pass_modules() -> void:
	_get_native_generation_bridge()._ensure_daily_pass_modules()
var _loading_epoch := 0
const LoadingFrameGateScript = preload("res://scripts/geography/loading_frame_gate.gd")
var _loading_frames = LoadingFrameGateScript.new()
func generate(cfg: MapConfig, hex_size: float) -> Dictionary:
	return await _get_native_generation_bridge().generate(cfg, hex_size)
func _runtime_register_system(system) -> void:
	if _sus == null or system == null:
		return
	_sus.register_system(system)
func _runtime_build_topology(context: String) -> bool:
	return _get_native_generation_bridge()._runtime_build_topology(context)
func get_economy_facade():
	return _economy_facade
func get_military_facade():
	return _military_facade
func get_military_daily_job():
	return _military_daily_job
func get_military_report() -> Dictionary:
	return _military_facade.report() if _military_facade != null else {"configured": false}
func refresh_military_terrain(day: int = -1) -> Dictionary:
	return _get_map_country_initializer().refresh_military_terrain(day)
func get_country_facade():
	return _country_facade
func get_country_ai_facade():
	return _country_ai_facade
func get_country_report() -> Dictionary:
	return _country_facade.report() if _country_facade != null else {"configured": false}
func get_modifier_facade():
	return _get_map_rules_initializer().get_modifier_facade()
func get_trigger_facade():
	return _get_map_rules_initializer().get_trigger_facade()
func get_effect_facade():
	return _get_map_rules_initializer().get_effect_facade()
func get_ideology_facade():
	return _get_map_rules_initializer().get_ideology_facade()
func get_trigger_report() -> Dictionary:
	return _get_map_rules_initializer().get_trigger_report()
func get_effect_report() -> Dictionary:
	return _get_map_rules_initializer().get_effect_report()
func get_ideology_report() -> Dictionary:
	return _get_map_rules_initializer().get_ideology_report()
func get_modifier_report() -> Dictionary:
	return _get_map_rules_initializer().get_modifier_report()
func apply_runtime_trigger_snapshot(after_generation: int) -> Dictionary:
	return _get_map_rules_initializer().apply_runtime_trigger_snapshot(after_generation)
func apply_runtime_ideology_snapshot(after_generation: int) -> Dictionary:
	return _get_map_rules_initializer().apply_runtime_ideology_snapshot(after_generation)
func step_ideology_instance_refresh(day_index: int) -> Dictionary:
	return _get_map_rules_initializer().step_ideology_instance_refresh(day_index)
func step_ideology_derived_rebuild(day_index: int) -> Dictionary:
	return _get_map_rules_initializer().step_ideology_derived_rebuild(day_index)
func apply_runtime_modifier_snapshot(after_generation: int) -> Dictionary:
	return _get_map_rules_initializer().apply_runtime_modifier_snapshot(after_generation)
func apply_runtime_effect_snapshot(after_generation: int) -> Dictionary:
	return _get_map_rules_initializer().apply_runtime_effect_snapshot(after_generation)
func get_economy_report() -> Dictionary:
	return _economy_facade.report() if _economy_facade != null else {"configured": false}
func get_economy_perf_report() -> Dictionary:
	return _get_native_generation_bridge().get_economy_perf_report()
func get_runtime_perf_snapshot(detail_level: int = 0) -> Dictionary:
	return _get_native_generation_bridge().get_runtime_perf_snapshot(detail_level)
func runtime_graph_active() -> bool:
	return _runtime_graph_active
func set_runtime_interactive(interactive: bool) -> void:
	_get_map_runtime_bridge().set_runtime_interactive(interactive)
func set_runtime_qos_threaded(interactive: bool) -> Dictionary:
	return _get_map_runtime_bridge().set_runtime_qos_threaded(interactive)
func get_runtime_thread_report() -> Dictionary:
	return _get_map_runtime_bridge().get_runtime_thread_report()
func get_runtime_control_state() -> Dictionary:
	return _get_map_runtime_bridge().get_runtime_control_state()
func record_runtime_visual_timings(ui_input_to_feedback_ms: float,
		visual_apply_ms: float, gpu_upload_ms: float) -> Dictionary:
	return _get_map_runtime_bridge().record_runtime_visual_timings(
		ui_input_to_feedback_ms, visual_apply_ms, gpu_upload_ms)
func start_runtime_worker(config: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().start_runtime_worker(config)
func poll_runtime_events_snapshot(after_generation: int = 0) -> Dictionary:
	return _get_map_runtime_bridge().poll_runtime_events_snapshot(after_generation)
func set_runtime_clock_threaded(paused: bool, speed_days_per_second: float) -> Dictionary:
	return _get_map_runtime_bridge().set_runtime_clock_threaded(paused, speed_days_per_second)
func capture_runtime_inputs(inputs: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().capture_runtime_inputs(inputs)
func capture_country_worker_inputs() -> Dictionary:
	return _get_map_runtime_bridge().capture_country_worker_inputs()
func get_country_worker_read_view(after_generation: int = 0) -> Dictionary:
	return _get_map_runtime_bridge().get_country_worker_read_view(after_generation)
func service_country_worker_peer_adapter(max_intents: int = 64,
		shadow_replay: bool = true) -> Dictionary:
	return _get_map_runtime_bridge().service_country_worker_peer_adapter(max_intents, shadow_replay)
func get_country_economy_asset_protocol_status() -> Dictionary:
	return _get_map_runtime_bridge().get_country_economy_asset_protocol_status()
func poll_country_economy_asset_request() -> Dictionary:
	return _get_map_runtime_bridge().poll_country_economy_asset_request()
func submit_country_economy_asset_result(result: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().submit_country_economy_asset_result(result)
func submit_runtime_command(command: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().submit_runtime_command(command)
func poll_runtime_commit(after_generation: int = 0) -> Dictionary:
	return _get_map_runtime_bridge().poll_runtime_commit(after_generation)
func flush_runtime_economy_resource_writeback() -> Dictionary:
	return _get_map_runtime_bridge().flush_runtime_economy_resource_writeback()
func consume_runtime_visual_patch(generation: int, family: int, cursor: int,
		max_items: int) -> Dictionary:
	return _get_map_runtime_bridge().consume_runtime_visual_patch(
		generation, family, cursor, max_items)
func request_runtime_save(request_id: int) -> Dictionary:
	return _get_map_runtime_bridge().request_runtime_save(request_id)
func poll_runtime_save(request_id: int) -> Dictionary:
	return _get_map_runtime_bridge().poll_runtime_save(request_id)
func restore_runtime_bundle(bytes: PackedByteArray,
		external_ecp2: PackedByteArray = PackedByteArray()) -> Dictionary:
	return _get_map_runtime_bridge().restore_runtime_bundle(bytes, external_ecp2)
func request_runtime_stop() -> Dictionary:
	return _get_map_runtime_bridge().request_runtime_stop()
func set_economy_diagnostics_enabled(enabled: bool) -> void:
	_get_map_runtime_bridge().set_economy_diagnostics_enabled(enabled)
func set_test_economy_bootstrap_enabled(enabled: bool) -> void:
	_get_map_runtime_bridge().set_test_economy_bootstrap_enabled(enabled)
func set_test_economy_population_scale(scale: int) -> void:
	_get_map_runtime_bridge().set_test_economy_population_scale(scale)
func set_save_restore_preparation_enabled(enabled: bool) -> void:
	_get_map_runtime_bridge().set_save_restore_preparation_enabled(enabled)
func prepare_economy_save_restore_runtime() -> Dictionary:
	return _get_map_runtime_bridge().prepare_economy_save_restore_runtime()
func finalize_save_restore_runtime() -> Dictionary:
	return _get_map_runtime_bridge().finalize_save_restore_runtime()
func advance_save_boundary() -> void:
	_get_map_runtime_bridge().advance_save_boundary()
func native_daily_climate_suppressed() -> bool:
	return _data_core_world_ext != null and _data_core_world_ext.climate_main_thread_suppressed()
func _runtime_climate_failure(code: String, reason: String = "", day: int = -1) -> Dictionary:
	return _get_runtime_climate_capture()._runtime_climate_failure(code, reason, day)
func _runtime_climate_hash_append(hashing, label: String, value) -> void:
	_get_runtime_climate_capture()._runtime_climate_hash_append(hashing, label, value)
func _runtime_climate_hash_digest_value(digest: PackedByteArray) -> int:
	return _get_runtime_climate_capture()._runtime_climate_hash_digest_value(digest)
func _runtime_climate_catalog_hash_for_map(map: MapData) -> int:
	return _get_runtime_climate_capture()._runtime_climate_catalog_hash_for_map(map)
func _runtime_climate_topology_generation_for_map(map: MapData) -> int:
	return _get_runtime_climate_capture()._runtime_climate_topology_generation_for_map(map)
func _runtime_climate_optional_array(map: MapData, field_name: String, packed_type: int):
	return _get_runtime_climate_capture()._runtime_climate_optional_array(map, field_name, packed_type)
func _runtime_climate_neighbor_offsets_for_map(map: MapData) -> PackedInt32Array:
	return _get_runtime_climate_capture()._runtime_climate_neighbor_offsets_for_map(map)
func _runtime_climate_trace_has_older_pending(day: int) -> bool:
	return _get_runtime_climate_capture()._runtime_climate_trace_has_older_pending(day)
func set_worker_environment_publisher(callsite: int) -> void:
	_get_runtime_climate_capture().set_worker_environment_publisher(callsite)
func set_save_prefetch_suspend_callback(callback: Callable) -> void:
	_get_runtime_climate_capture().set_save_prefetch_suspend_callback(callback)
func _notify_save_prefetch_suspend() -> void:
	_get_runtime_climate_capture()._notify_save_prefetch_suspend()
func worker_environment_publisher_callsite() -> int:
	return _get_runtime_climate_capture().worker_environment_publisher_callsite()
func environment_publish_callsite_mask() -> int:
	return _get_runtime_climate_capture().environment_publish_callsite_mask()
func environment_publish_diagnostics() -> Dictionary:
	return _get_runtime_climate_capture().environment_publish_diagnostics()
func _runtime_environment_publish_allowed(callsite: int, day: int) -> bool:
	return _get_runtime_climate_capture()._runtime_environment_publish_allowed(callsite, day)
func capture_runtime_inputs_for_worker(day: int = -1, phase: float = -1.0,
		callsite: int = 0) -> Dictionary:
	return _get_runtime_climate_capture().capture_runtime_inputs_for_worker(day, phase, callsite)
func next_environment_day() -> int:
	return _get_runtime_climate_capture().next_environment_day()
func publish_environment_through(last_day: int, last_phase: float,
		callsite: int = 0) -> Dictionary:
	return _get_runtime_climate_capture().publish_environment_through(last_day, last_phase, callsite)
func _collect_runtime_climate_parity_fields(map: MapData) -> Dictionary:
	return _get_runtime_climate_capture()._collect_runtime_climate_parity_fields(map)
func _runtime_climate_parity_map_array(map: MapData, array_name: String):
	return _get_runtime_climate_capture()._runtime_climate_parity_map_array(map, array_name)
func _runtime_climate_reference_ready_for_day(day: int) -> bool:
	return _get_runtime_climate_capture()._runtime_climate_reference_ready_for_day(day)
func _publish_runtime_climate_reference(day: int, map: MapData = null) -> Dictionary:
	return _get_runtime_climate_capture()._publish_runtime_climate_reference(day, map)
func _publish_ready_runtime_climate_references(up_to_day: int,
		map: MapData = null) -> Dictionary:
	return _get_runtime_climate_capture()._publish_ready_runtime_climate_references(up_to_day, map)
func runtime_climate_trace_report() -> Dictionary:
	return _get_runtime_climate_capture().runtime_climate_trace_report()
func set_gameplay_start_config(config: Dictionary) -> void:
	_gameplay_start_context = {"config": config.duplicate(true)} if not config.is_empty() else {}
	_gameplay_start_report.clear()
func gameplay_start_report() -> Dictionary:
	return _gameplay_start_report.duplicate(true)
func consume_continuation_perf_summary() -> Dictionary:
	var out: Dictionary = _continuation_perf_pending.duplicate(true)
	_continuation_perf_pending.clear()
	return out
func _ensure_continuation_perf_pending() -> void:
	_get_map_runtime_bridge()._ensure_continuation_perf_pending()
func _record_continuation_slice(source: String, result: Dictionary, wall_ms: float) -> float:
	return _get_map_runtime_bridge()._record_continuation_slice(source, result, wall_ms)
func _finish_continuation_perf_frame(started_us: int, frame_slices: int,
		frame_max_slice_ms: float, budget_ms: float) -> void:
	_get_map_runtime_bridge()._finish_continuation_perf_frame(started_us, frame_slices, frame_max_slice_ms, budget_ms)
var _continuation_reentry_guard := false
func _continue_economy_inflight(day_index: int) -> void:
	_get_map_runtime_bridge()._continue_economy_inflight(day_index)
func _continue_economy_inflight_impl(day_index: int) -> void:
	_get_map_runtime_bridge()._continue_economy_inflight_impl(day_index)
func _advance_runtime_graph_pulse(day_index: int) -> Dictionary:
	return _get_map_runtime_bridge()._advance_runtime_graph_pulse(day_index)
func _halt_on_economy_fatal(day_index: int, economy_result: Dictionary) -> void:
	_get_map_runtime_bridge()._halt_on_economy_fatal(day_index, economy_result)
func _dispatch_runtime_graph_country_committed() -> void:
	_get_map_runtime_bridge()._dispatch_runtime_graph_country_committed()
func _track_runtime_graph_stall(day_index: int, token_status: int) -> bool:
	return _get_map_runtime_bridge()._track_runtime_graph_stall(day_index, token_status)
func _log_stalled_runtime_graph(day: int) -> void:
	_get_map_runtime_bridge()._log_stalled_runtime_graph(day)
func _day_stall_reason_name(mask: int) -> String:
	return _get_map_runtime_bridge()._day_stall_reason_name(mask)
func _domain_mask_names(mask: int) -> String:
	return _get_map_runtime_bridge()._domain_mask_names(mask)
func _log_stalled_runtime_graph_authority(day: int) -> void:
	_get_map_runtime_bridge()._log_stalled_runtime_graph_authority(day)
func _native_daily_slice_available() -> bool:
	return _data_core_world_ext != null
func _native_daily_missing_slice_report() -> Dictionary:
	return _get_map_runtime_bridge()._native_daily_missing_slice_report()
func _disabled_sea_ice_atlas_report(reason: String) -> Dictionary:
	return _get_map_runtime_bridge()._disabled_sea_ice_atlas_report(reason)
func _cell_facade_cids_of(cell: Object, field: StringName) -> PackedInt32Array:
	return _get_map_runtime_bridge()._cell_facade_cids_of(cell, field)
func _bind_cell_facade_with_cids(cell: Object, facade_on: bool,
		cid_gd: PackedInt32Array, cid_ext: PackedInt32Array) -> bool:
	return _get_map_runtime_bridge()._bind_cell_facade_with_cids(cell, facade_on, cid_gd, cid_ext)
func _setup_sus(map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	await _get_map_runtime_bridge()._setup_sus(map, world, cfg, hex_size)
func get_sus_bootstrap() -> RefCounted:
	return _sus_bootstrap
func get_environment_runtime() -> RefCounted:
	return _get_map_runtime_bridge().get_environment_runtime()
func ensure_environment_runtime(map: MapData, pixel_size: Vector2i = Vector2i.ZERO) -> RefCounted:
	return _get_map_runtime_bridge().ensure_environment_runtime(map, pixel_size)
func environment_runtime_status() -> Dictionary:
	return _get_map_runtime_bridge().environment_runtime_status()
func export_environment_runtime_state() -> Dictionary:
	return _get_map_runtime_bridge().export_environment_runtime_state()
func restore_environment_runtime_state(state: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().restore_environment_runtime_state(state)
func _hard_effect_ack_chain_due(day: int) -> bool:
	return _get_map_runtime_bridge()._hard_effect_ack_chain_due(day)
func _ack_native_effect_domain_bindings() -> void:
	_get_map_runtime_bridge()._ack_native_effect_domain_bindings()
func _log_stuck_day_barrier(day: int, economy_inflight: bool) -> void:
	_get_map_runtime_bridge()._log_stuck_day_barrier(day, economy_inflight)
func _drain_native_effect_ack_chain(ctx: SusTickContext) -> int:
	return _get_map_runtime_bridge()._drain_native_effect_ack_chain(ctx)
func environment_runtime_step_budgeted(budget_ms: float, max_cells: int = 0, max_pixels: int = 0, max_indices: int = 0, pipeline: StringName = &"ocean") -> Dictionary:
	return _get_map_runtime_bridge().environment_runtime_step_budgeted(budget_ms, max_cells, max_pixels, max_indices, pipeline)
func set_dyn_atlas_upload_stride(p_stride: int) -> void:
	_get_map_runtime_bridge().set_dyn_atlas_upload_stride(p_stride)
func set_enum_atlas_upload_stride(p_stride: int) -> void:
	_get_map_runtime_bridge().set_enum_atlas_upload_stride(p_stride)
func set_world_clock_ref(world_clock_node) -> void:
	_get_map_runtime_bridge().set_world_clock_ref(world_clock_node)
func _native_mode_is_active(cp, field_name: String) -> bool:
	if cp == null or cp.get(field_name) == null:
		return false
	return int(cp.get(field_name)) == 2
func _native_mode_is_shadow(cp, field_name: String) -> bool:
	if cp == null or cp.get(field_name) == null:
		return false
	return int(cp.get(field_name)) == 1
func _native_daily_live_f32(slot_name: String, fallback: PackedFloat32Array,
		n: int) -> PackedFloat32Array:
	return _get_native_daily_bundle_builder()._native_daily_live_f32(slot_name, fallback, n)
func _native_daily_live_u8(slot_name: String, fallback: PackedByteArray,
		n: int) -> PackedByteArray:
	return _get_native_daily_bundle_builder()._native_daily_live_u8(slot_name, fallback, n)
# Pass-A's solar lane keeps its live-slot fallback visible at the host boundary:
# _get_native_daily_bundle_builder()._native_daily_live_f32("cell_insolation_now", map.insolation_now_arr, n_cells)
func _native_daily_base_tick_knobs(ctx: SusTickContext) -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_base_tick_knobs(ctx)
func _build_native_daily_stage_b_knobs(map: MapData, cp_now, call_index: int,
		elapsed_days_per_call: float = 1.0) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_stage_b_knobs(map, cp_now, call_index, elapsed_days_per_call)
func _native_daily_season_cadence_policy(cp_now, call_index: int) -> Dictionary:
	# The native owner sets skip_vegetation_rewrite while vegetation_dynamics owns
	# the season rewrite; keep that contract visible at the MapGenerator boundary.
	return _get_native_daily_bundle_builder()._native_daily_season_cadence_policy(cp_now, call_index)
var _maritime_factor_cache: PackedFloat32Array = PackedFloat32Array()
var _maritime_factor_cache_key: String = ""
func _ensure_maritime_factor(map: MapData, decay_cells: float) -> PackedFloat32Array:
	return _get_mapgen_native_daily_runtime()._ensure_maritime_factor(map, decay_cells)
const _RUNTIME_CLIMATE_ROUND_REQUIRED_LANES: Array = [
	"is_water", "cover", "ema_initialized", "elevation", "base_moisture",
	"lat_norm", "temp_baseline_year", "temp", "temp_30d", "temp_365d",
	"thermal_energy", "snowpack",
]
var _runtime_climate_round_input_lanes_reported: bool = false
var _runtime_climate_distribute_reported: bool = false
var _runtime_climate_field_reported: bool = false
var _runtime_climate_worker_weather_embed_day: int = -1000000
var _runtime_climate_worker_stage_b_call_index: int = -1
func publish_worker_climate_visuals() -> Dictionary:
	return _get_mapgen_native_daily_runtime().publish_worker_climate_visuals()
func _build_runtime_climate_stage_knobs(map: MapData, day: int,
		authoritative: bool) -> Dictionary:
	return _get_runtime_climate_capture()._build_runtime_climate_stage_knobs(map, day, authoritative)
func _build_runtime_climate_round_input(
		map: MapData, season_phase: float,
		worker_authoritative: bool = false) -> Dictionary:
	return _get_runtime_climate_capture()._build_runtime_climate_round_input(map, season_phase, worker_authoritative)
func _build_runtime_climate_round_scalar_knobs(
		map: MapData, season_phase: float) -> Dictionary:
	return _get_runtime_climate_capture()._build_runtime_climate_round_scalar_knobs(map, season_phase)
func _build_native_daily_climate_pass_a_struct(map: MapData, cp_now, season_phase: float) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_climate_pass_a_struct(map, cp_now, season_phase)
func _build_native_daily_climate_pass_b_knobs(map: MapData, cp_now, season_phase: float) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_climate_pass_b_knobs(map, cp_now, season_phase)
func _build_native_daily_transpiration_knobs(map: MapData, cp_now) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_transpiration_knobs(map, cp_now)
func _build_native_daily_wind_knobs(map: MapData, cp_now) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_wind_knobs(map, cp_now)
func _temperature_transport_anomaly_knobs(cp_now) -> Dictionary:
	return _get_mapgen_native_daily_runtime()._temperature_transport_anomaly_knobs(cp_now)
func _apply_temperature_transport_anomaly_knobs(target: Dictionary, tta: Dictionary) -> void:
	for key in tta.keys():
		target[key] = tta[key]
func _prepare_temperature_transport_anomaly_state(map: MapData, n: int, cells: Array = [], prefer_cached: bool = false) -> PackedFloat32Array:
	return _get_mapgen_native_daily_runtime()._prepare_temperature_transport_anomaly_state(map, n, cells, prefer_cached)
func _valid_runtime_temp_or_baseline(temp_value: float, baseline: float) -> float:
	return baseline if is_nan(temp_value) or is_inf(temp_value) else temp_value
func _native_daily_ema_all_initialized(map: MapData, ema_init: PackedByteArray, n: int) -> bool:
	return _get_native_daily_bundle_builder()._native_daily_ema_all_initialized(map, ema_init, n)
func _build_native_daily_ocean_knobs(map: MapData, cp_now, season_phase: float) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_ocean_knobs(map, cp_now, season_phase)
func _publish_native_daily_temperature_transport_anomaly(
		map: MapData, bundle: Dictionary, breakdown: Dictionary = {}, result: Dictionary = {},
		skip_dense_write: bool = false) -> void:
	_get_native_daily_publish()._publish_native_daily_temperature_transport_anomaly(map, bundle, breakdown, result, skip_dense_write)
func _build_native_daily_sea_ice_knobs(
		map: MapData,
		cp_now,
		season_phase: float,
		commit_side_effects: bool,
		dt_cap_days: float = 30.0) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_sea_ice_knobs(map, cp_now, season_phase, commit_side_effects, dt_cap_days)
func _build_native_daily_runtime_hydrology_knobs(map: MapData, cp_now,
		dt_days: float = 1.0) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_runtime_hydrology_knobs(map, cp_now, dt_days)
func _native_daily_required_pass_keys(cp_now) -> PackedStringArray:
	return _get_native_daily_bundle_builder()._native_daily_required_pass_keys(cp_now)
func _native_daily_required_pass_keys_array(cp_now) -> Array[String]:
	return _get_native_daily_bundle_builder()._native_daily_required_pass_keys_array(cp_now)
func _native_daily_missing_required_pass_keys(bundle: Dictionary, required: PackedStringArray) -> PackedStringArray:
	return _get_native_daily_bundle_builder()._native_daily_missing_required_pass_keys(bundle, required)
func _native_daily_climate_round_state_snapshot() -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_climate_round_state_snapshot()
func _native_daily_ocean_physical_state_snapshot() -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_ocean_physical_state_snapshot()
func _native_daily_season_refresh_state_snapshot() -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_season_refresh_state_snapshot()
func _native_daily_weather_active_bootstrap_allowed(readiness: Dictionary) -> bool:
	return _get_native_daily_bundle_builder()._native_daily_weather_active_bootstrap_allowed(readiness)
func _native_daily_weather_cadence_stride(cp_now) -> int:
	return _get_native_daily_bundle_builder()._native_daily_weather_cadence_stride(cp_now)
func _native_daily_weather_cadence_due(cp_now, ctx: SusTickContext) -> bool:
	return _get_native_daily_bundle_builder()._native_daily_weather_cadence_due(cp_now, ctx)
func _native_daily_split_weather_node_enabled(cp_now) -> bool:
	return _get_native_daily_bundle_builder()._native_daily_split_weather_node_enabled(cp_now)
func _native_daily_weather_clock_values(default_phase: float) -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_weather_clock_values(default_phase)
func _build_native_daily_weather_super_knobs(
		ctx: SusTickContext,
		map: MapData,
		world: WorldData,
		phase_default: float,
		stage_b_knobs: Dictionary,
		runtime_hydrology_active: bool,
		commit_side_effects: bool,
		force_weather_embed: bool) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_weather_super_knobs(ctx, map, world, phase_default, stage_b_knobs, runtime_hydrology_active, commit_side_effects, force_weather_embed)
func _native_daily_boundary_contract(bundle: Dictionary, commit_side_effects: bool) -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_boundary_contract(bundle, commit_side_effects)
func _native_daily_static_bundle_cache_key(map: MapData, cp_now) -> String:
	return _get_native_daily_bundle_builder()._native_daily_static_bundle_cache_key(map, cp_now)
func _build_native_daily_static_bundle_shell(map: MapData, cp_now) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_static_bundle_shell(map, cp_now)
func _native_daily_get_static_bundle_shell(map: MapData, cp_now) -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_get_static_bundle_shell(map, cp_now)
func _build_native_daily_bundle(
		ctx: SusTickContext,
		map: MapData,
		_world: WorldData,
		commit_side_effects: bool = false,
		sea_ice_dt_cap_days: float = 30.0,
		commit_sea_ice_side_effects: bool = true,
		force_weather_embed: bool = false,
		defer_heavy_pass_knobs: bool = false) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_bundle(ctx, map, _world, commit_side_effects, sea_ice_dt_cap_days, commit_sea_ice_side_effects, force_weather_embed, defer_heavy_pass_knobs)
func _merge_native_daily_slice_patch_local(patch: Dictionary) -> void:
	_get_native_daily_bundle_builder()._merge_native_daily_slice_patch_local(patch)
func _native_daily_effective_yield_nodes(cp) -> PackedInt32Array:
	return _get_native_daily_bundle_builder()._native_daily_effective_yield_nodes(cp)
func _native_daily_sea_ice_dt_cap_days(cp) -> float:
	return _get_native_daily_bundle_builder()._native_daily_sea_ice_dt_cap_days(cp)
func _build_native_daily_slice_bundle_patch(
		next_node_index: int,
		ctx: SusTickContext,
		map: MapData,
		world: WorldData) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_slice_bundle_patch(next_node_index, ctx, map, world)
func _native_daily_bundle_pass_keys(bundle: Dictionary) -> Array[String]:
	return _get_native_daily_bundle_builder()._native_daily_bundle_pass_keys(bundle)
func _native_daily_capture_finalizer_start_state(map: MapData) -> void:
	_get_native_daily_publish()._native_daily_capture_finalizer_start_state(map)
func _native_daily_collect_f32_dirty(current: PackedFloat32Array, values: PackedFloat32Array,
		n: int, epsilon: float) -> Dictionary:
	return _get_native_daily_publish()._native_daily_collect_f32_dirty(current, values, n, epsilon)
func _native_daily_percentile_from_sorted(values: PackedFloat32Array, p: float) -> float:
	return _get_native_daily_publish()._native_daily_percentile_from_sorted(values, p)
func _native_daily_apply_finalizer(map: MapData) -> Dictionary:
	return _get_native_daily_publish()._native_daily_apply_finalizer(map)
func _merge_native_daily_finalizer_diag(target: Dictionary, diag: Dictionary) -> void:
	_get_native_daily_publish()._merge_native_daily_finalizer_diag(target, diag)
func _native_daily_add_complete_apply_ms(diag: Dictionary, key: String, elapsed_us: int) -> void:
	_get_native_daily_publish()._native_daily_add_complete_apply_ms(diag, key, elapsed_us)
func _native_daily_install_complete_apply_diag(
		res: Dictionary,
		breakdown: Dictionary,
		diag: Dictionary,
		apply_ms: float) -> void:
	_get_native_daily_publish()._native_daily_install_complete_apply_diag(res, breakdown, diag, apply_ms)
func _run_native_daily_shadow_probe(ctx: SusTickContext, map: MapData, world: WorldData) -> void:
	_get_mapgen_native_daily_runtime()._run_native_daily_shadow_probe(ctx, map, world)
func _configure_native_world_context(map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	_get_mapgen_native_daily_runtime()._configure_native_world_context(map, world, cfg, hex_size)
func _try_register_native_daily_sim_job(map: MapData, world: WorldData) -> bool:
	return _get_mapgen_native_daily_runtime()._try_register_native_daily_sim_job(map, world)
func _configure_native_daily_transaction_budget(job, cp) -> void:
	_get_mapgen_native_daily_runtime()._configure_native_daily_transaction_budget(job, cp)
func _try_register_native_environment_runtime_system(map: MapData, cp) -> bool:
	return _get_mapgen_native_daily_runtime()._try_register_native_environment_runtime_system(map, cp)
func _register_visual_upload_jobs(map: MapData, world: WorldData, hex_size: float, cp) -> void:
	_get_mapgen_native_daily_runtime()._register_visual_upload_jobs(map, world, hex_size, cp)
func _native_daily_make_front_signature(front: WeatherFront) -> String:
	return _get_native_daily_publish()._native_daily_make_front_signature(front)
func _native_daily_front_slot_signatures(fronts: Array) -> PackedStringArray:
	return _get_native_daily_publish()._native_daily_front_slot_signatures(fronts)
func _native_daily_fronts_signature_diff(prev: PackedStringArray, next: PackedStringArray) -> Dictionary:
	return _get_native_daily_publish()._native_daily_fronts_signature_diff(prev, next)
func _apply_vegetation_succession_candidates(map: MapData,
		indices: PackedInt32Array, to_vegetation: PackedByteArray, cp_now) -> int:
	return _get_native_daily_publish()._apply_vegetation_succession_candidates(map, indices, to_vegetation, cp_now)
func _apply_native_daily_visual_intents(res: Dictionary, breakdown: Dictionary,
		fronts_out: Array, map: MapData, world: WorldData) -> void:
	_get_native_daily_publish()._apply_native_daily_visual_intents(res, breakdown, fronts_out, map, world)
func _consume_native_daily_canal_visual_dirty_cells() -> PackedInt32Array:
	if _data_core_world_ext == null:
		return PackedInt32Array()
	return _data_core_world_ext.consume_canal_visual_dirty_cells()
func _record_native_daily_slice_climate_breakdown(res: Dictionary, breakdown: Dictionary, map: MapData, done: bool, rc_int: int) -> void:
	_get_native_daily_publish()._record_native_daily_slice_climate_breakdown(res, breakdown, map, done, rc_int)
func _record_native_daily_job_shell_diag(diag: Dictionary) -> void:
	if _diagnostics_bus.get_climate_breakdown().is_empty() or diag.is_empty():
		return
	_diagnostics_bus.merge_climate_breakdown(diag)
func _native_daily_contract_stride_days() -> int:
	return _get_mapgen_native_daily_runtime()._native_daily_contract_stride_days()
func _native_daily_contract_budget_days() -> int:
	return _get_mapgen_native_daily_runtime()._native_daily_contract_budget_days()
func _native_daily_contract_age_days_for(ctx: SusTickContext) -> int:
	if _native_daily_contract_sample_day < 0 or ctx == null:
		return 0
	return maxi(0, int(ctx.day_index) - _native_daily_contract_sample_day)
func _native_daily_effective_node_range_config(cp, ctx: SusTickContext, map_ref: MapData) -> Dictionary:
	return _get_mapgen_native_daily_runtime()._native_daily_effective_node_range_config(cp, ctx, map_ref)
func _native_daily_begin_contract_round(ctx: SusTickContext) -> void:
	_get_mapgen_native_daily_runtime()._native_daily_begin_contract_round(ctx)
func _native_daily_reset_contract_round() -> void:
	_native_daily_contract_sample_day = -1
	_native_daily_contract_sample_tick = -1
	_native_daily_contract_warned_over_budget = false
func _native_daily_stamp_contract(res: Dictionary, breakdown: Dictionary,
		ctx: SusTickContext, committed: bool, state: String) -> void:
	_get_mapgen_native_daily_runtime()._native_daily_stamp_contract(res, breakdown, ctx, committed, state)
func run_native_daily_slice_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	return _get_mapgen_native_daily_runtime().run_native_daily_slice_from_job(ctx, _map, _world)
func run_native_daily_tick_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	return _get_mapgen_native_daily_runtime().run_native_daily_tick_from_job(ctx, _map, _world)
func native_daily_last_result() -> Dictionary:
	return _native_daily_last_result.duplicate()
func native_daily_round_active() -> bool:
	return _native_daily_day_pending or (_native_daily_sim_job != null \
			and bool(_native_daily_sim_job.get("_native_round_active")))
func bio_occupancy_round_active() -> bool:
	return _bio_occupancy_slice_inflight or _bio_occupancy_day_pending
func sus_tick_daily(world_clock_node, day_index_override: int = -1,
		season_phase_override: float = NAN) -> Dictionary:
	return _get_mapgen_native_daily_runtime().sus_tick_daily(world_clock_node, day_index_override, season_phase_override)
func sus_reset_all() -> void:
	_get_mapgen_native_daily_runtime().sus_reset_all()
func sus_report_last_tick() -> Dictionary:
	if _sus == null:
		return {}
	return _sus.report_last_tick()
func set_current_fast_tick_idx(idx: int) -> void:
	_get_mapgen_native_daily_runtime().set_current_fast_tick_idx(idx)
func sus_climate_breakdown() -> Dictionary:
	return _diagnostics_bus.get_climate_breakdown()
func increment_climate_diagnostic_call_count() -> int:
	return _diagnostics_bus.increment_climate_call_count()
func climate_diagnostic_call_count() -> int:
	return _diagnostics_bus.get_climate_call_count()
func sus_ocean_currents_breakdown() -> Dictionary:
	return _get_mapgen_native_daily_runtime().sus_ocean_currents_breakdown()
func did_refresh_climate_run_this_tick() -> bool:
	return _refresh_climate_daily_job != null and _refresh_climate_daily_job.did_run_last_tick()
func last_refresh_climate_slice_ms() -> float:
	if _refresh_climate_daily_job == null:
		return 0.0
	return _refresh_climate_daily_job.last_slice_elapsed_ms()
func sus_weather_breakdown() -> Dictionary:
	return _normalized_weather_breakdown(_diagnostics_bus.get_weather_breakdown())
func merge_weather_job_breakdown(extra: Dictionary) -> void:
	_diagnostics_bus.merge_weather_breakdown(extra)
func _weather_front_count_from_value(v) -> int:
	return _get_mapgen_native_daily_runtime()._weather_front_count_from_value(v)
func _normalized_weather_breakdown(src: Dictionary) -> Dictionary:
	return _get_mapgen_native_daily_runtime()._normalized_weather_breakdown(src)
func has_pending_enum_atlas_upload() -> bool:
	return _enum_atlas_biome_dirty or _enum_atlas_cover_dirty or _enum_atlas_vegetation_dirty
func consume_pending_enum_atlas_axis() -> String:
	return _get_mapgen_native_daily_runtime().consume_pending_enum_atlas_axis()
func queue_detail_scatter_refresh(indices: PackedInt32Array) -> void:
	_get_mapgen_native_daily_runtime().queue_detail_scatter_refresh(indices)
func queue_detail_scatter_changes(changes) -> void:
	if changes == null or not changes.has_method("is_empty") or bool(changes.is_empty()):
		return
	_pending_detail_scatter_change_sets.append(changes.duplicate_set())
func has_pending_detail_scatter_refresh() -> bool:
	return _get_mapgen_native_daily_runtime().has_pending_detail_scatter_refresh()
func consume_pending_detail_scatter_refresh_indices() -> PackedInt32Array:
	return _get_mapgen_native_daily_runtime().consume_pending_detail_scatter_refresh_indices()
func consume_pending_detail_scatter_changes():
	return _get_mapgen_native_daily_runtime().consume_pending_detail_scatter_changes()
func record_enum_atlas_upload(axis: String, elapsed_ms: float) -> void:
	_get_mapgen_native_daily_runtime().record_enum_atlas_upload(axis, elapsed_ms)
func record_enum_atlas_upload_report(report: Dictionary) -> void:
	_get_mapgen_native_daily_runtime().record_enum_atlas_upload_report(report)
func sus_enum_atlas_breakdown() -> Dictionary:
	return _last_enum_atlas_upload_breakdown.duplicate()
func sus_sea_ice_atlas_breakdown() -> Dictionary:
	return _last_sea_ice_atlas_upload_breakdown.duplicate()
func sus_dynamic_visual_atlas_breakdown() -> Dictionary:
	return _get_mapgen_native_daily_runtime().sus_dynamic_visual_atlas_breakdown()
func _mark_enum_atlas_dirty(cover_dirty: bool, vegetation_dirty: bool, biome_dirty: bool = false) -> void:
	_enum_atlas_biome_dirty = _enum_atlas_biome_dirty or biome_dirty
	_enum_atlas_cover_dirty = _enum_atlas_cover_dirty or cover_dirty
	_enum_atlas_vegetation_dirty = _enum_atlas_vegetation_dirty or vegetation_dirty
func _season_refresh_edge_pending() -> bool:
	return _last_season_refresh_day != _last_capture_season_refresh_day
const RUNTIME_CLIMATE_DOMAIN_BIT := 1 << 1
const CLIMATE_AUTHORITY_GRANT_TIMEOUT_MS := 60000
func _climate_authority_grant_pending(thread_report: Dictionary) -> bool:
	return _get_mapgen_native_daily_runtime()._climate_authority_grant_pending(thread_report)
func _wait_climate_authority_grant() -> Dictionary:
	return _get_mapgen_native_daily_runtime()._wait_climate_authority_grant()
func season_refresh_defers_to_capture() -> bool:
	if _data_core_world_ext == null:
		return false
	return bool(get_runtime_thread_report().get("climate_worker_authoritative", false))
func sus_season_refresh_breakdown() -> Dictionary:
	return _last_season_refresh_breakdown.duplicate()
func _prime_scatter_sync_snapshot(map: MapData) -> void:
	_get_mapgen_native_daily_runtime()._prime_scatter_sync_snapshot(map)
func sync_detail_scatter_after_tick(map: MapData) -> void:
	_get_mapgen_native_daily_runtime().sync_detail_scatter_after_tick(map)
func _season_log_path_once(stage_key: String, path: String, detail: String) -> void:
	_get_mapgen_native_daily_runtime()._season_log_path_once(stage_key, path, detail)
func _ensure_season_round_slots_fresh() -> void:
	_get_mapgen_native_daily_runtime()._ensure_season_round_slots_fresh()
func _ensure_climate_daily_round_slots_fresh() -> void:
	_get_mapgen_native_daily_runtime()._ensure_climate_daily_round_slots_fresh()
func _mark_climate_daily_round_slots_stale() -> void:
	_climate_daily_round_slots_fresh = false
func _ensure_natural_resource_knobs() -> void:
	_get_mapgen_native_daily_runtime()._ensure_natural_resource_knobs()
func _on_modifier_events_available(batch: Dictionary) -> void:
	_get_map_resource_initializer()._on_modifier_events_available(batch)
func _prime_natural_resource_regen_factors(n_cells: int) -> Dictionary:
	return _get_map_resource_initializer()._prime_natural_resource_regen_factors(n_cells)
func _remember_natural_resource_report(report: Dictionary) -> Dictionary:
	_last_natural_resource_report = report.duplicate(true)
	_last_natural_resource_report["_tick_idx"] = _current_fast_tick_idx
	return report
func natural_resource_last_result() -> Dictionary:
	return _last_natural_resource_report.duplicate(true)
func _try_bootstrap_natural_resources_native(map_ref, cfg,
		habitat_arr: PackedByteArray, estuary_strength_arr: PackedFloat32Array) -> bool:
	return _get_map_resource_initializer()._try_bootstrap_natural_resources_native(map_ref, cfg, habitat_arr, estuary_strength_arr)
const BIO_LOG_CLASS_NAMES := [
	"none", "open_food", "wetland_food", "highland_food", "open_grazer",
	"forest_grazer", "dry_grazer", "cold_grazer", "tropical", "fiber_open",
	"fiber_wet", "fiber_forest",
]
const BIO_LOG_FOOD_IDS := ["bio.maize", "bio.wheat", "bio.rice", "bio.potato"]
const BIO_LOG_FOOD_NAMES := ["maize", "wheat", "rice", "potato"]
func _bio_log_food_bits() -> PackedInt32Array:
	return _get_map_resource_initializer()._bio_log_food_bits()
func _bio_carrier_reserve_fields(knobs: Dictionary) -> PackedStringArray:
	return _get_map_resource_initializer()._bio_carrier_reserve_fields(knobs)
func _bio_reserve_field_for(resource_id: String) -> String:
	return _get_map_resource_initializer()._bio_reserve_field_for(resource_id)
func _boot_facade_disabled_for_ab() -> bool:
	return OS.get_environment("PK_BOOT_FACADE_DISABLE").strip_edges() == "1"
func _bootstrap_world_facades(map_ref, cfg) -> bool:
	return _get_map_resource_initializer()._bootstrap_world_facades(map_ref, cfg)
func _knob_signature(knobs: Dictionary) -> int:
	return _get_map_resource_initializer()._knob_signature(knobs)
func run_natural_resource_pass_native(
		map_ref,
		dt_days: int = 1,
		cell_indices: PackedInt32Array = PackedInt32Array(),
		cell_dt_days: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return _get_map_resource_initializer().run_natural_resource_pass_native(map_ref, dt_days, cell_indices, cell_dt_days)
func economy_live_cells() -> PackedInt32Array:
	if _data_core_world_ext != null:
		return _data_core_world_ext.get_economy_live_cells()
	return PackedInt32Array()
func run_natural_resource_pass_for_runtime_commit(day: int) -> Dictionary:
	return _get_map_resource_initializer().run_natural_resource_pass_for_runtime_commit(day)
func _reset_natural_resource_cadence(n_cells: int, last_day: int) -> void:
	_get_map_resource_initializer()._reset_natural_resource_cadence(n_cells, last_day)
func _ensure_natural_resource_cadence(n_cells: int, day: int) -> void:
	if _natural_resource_last_day.size() != n_cells \
			or _natural_resource_was_live.size() != n_cells:
		_reset_natural_resource_cadence(n_cells, maxi(day - 1, 0))
func _natural_resource_dt_for_cell(cell: int, day: int, is_live: bool) -> int:
	return _get_map_resource_initializer()._natural_resource_dt_for_cell(cell, day, is_live)
func collect_natural_resource_pass_cells(day: int, live_cells: PackedInt32Array) -> Dictionary:
	return _get_map_resource_initializer().collect_natural_resource_pass_cells(day, live_cells)
func _commit_natural_resource_pass_days(day: int, cell_indices: PackedInt32Array, live_set: Dictionary) -> void:
	_get_map_resource_initializer()._commit_natural_resource_pass_days(day, cell_indices, live_set)
func run_natural_resource_pass_scheduled(map_ref, day: int, live_cells: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return _get_map_resource_initializer().run_natural_resource_pass_scheduled(map_ref, day, live_cells)
func catchup_natural_resources_for_live_cells(day: int) -> Dictionary:
	return _get_map_resource_initializer().catchup_natural_resources_for_live_cells(day)
func dump_climate_daily_round_slots_stats() -> Dictionary:
	return _get_map_resource_initializer().dump_climate_daily_round_slots_stats()
func _run_season_refresh_stage8_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return _get_map_resource_initializer()._run_season_refresh_stage8_gdext(map, _world, season)
func _run_season_refresh_stage11_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage11_gdext(map, _world, _season)
func _build_row_indices_for_gdext(map: MapData, cfg: MapConfig) -> PackedInt32Array:
	return _get_season_refresh_coordinator()._build_row_indices_for_gdext(map, cfg)
func _set_cell_runtime_terrain(map: MapData, cell: HexCell, terrain_id: int,
		sync_axes: bool = false, temperature_for_vegetation: float = -1.0,
		snow_cover: float = -1.0) -> void:
	_get_season_refresh_coordinator()._set_cell_runtime_terrain(map, cell, terrain_id, sync_axes, temperature_for_vegetation, snow_cover)
func _sync_runtime_axes_after_terrain(map: MapData, cell: HexCell, idx: int,
		temperature_for_vegetation: float = -1.0, snow_cover: float = -1.0) -> void:
	_get_season_refresh_coordinator()._sync_runtime_axes_after_terrain(map, cell, idx, temperature_for_vegetation, snow_cover)
func _clear_cell_vegetation_state(map: MapData, cell: HexCell, idx: int = -1) -> void:
	_get_season_refresh_coordinator()._clear_cell_vegetation_state(map, cell, idx)
func _write_runtime_enum_axes_dense(map: MapData) -> int:
	return _get_season_refresh_coordinator()._write_runtime_enum_axes_dense(map)
func _world_ext_u8_component_id(gd_name: StringName) -> int:
	return _get_season_refresh_coordinator()._world_ext_u8_component_id(gd_name)
func _apply_sea_ice_terrain_flips_indexed(map: MapData, indices: PackedInt32Array,
		terrain_values: PackedByteArray, sync_cells: bool = true) -> Dictionary:
	return _get_season_refresh_coordinator()._apply_sea_ice_terrain_flips_indexed(map, indices, terrain_values, sync_cells)
func _build_sea_ice_flip_batch(flip_to_ice_list: PackedInt32Array,
		flip_to_base_list: PackedInt32Array, flip_to_base_terrain: PackedByteArray,
		start: int = 0, end: int = -1) -> Dictionary:
	return _get_season_refresh_coordinator()._build_sea_ice_flip_batch(flip_to_ice_list, flip_to_base_list, flip_to_base_terrain, start, end)
func _build_vegetation_donor_table_for_gdext() -> PackedFloat32Array:
	return _get_season_refresh_coordinator()._build_vegetation_donor_table_for_gdext()
func _build_rain_shadow_jitter_for_gdext(map: MapData) -> PackedFloat32Array:
	return _get_season_refresh_coordinator()._build_rain_shadow_jitter_for_gdext(map)
func _run_season_refresh_stage1_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage1_gdext(map, _world, season)
func _run_season_refresh_stage2_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage2_gdext(map, _world, season)
func _run_season_refresh_stage3_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage3_gdext(map, _world, _season)
func _run_season_refresh_stage4_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage4_gdext(map, _world, season)
func _ensure_season_knob_geometry_cache(map: MapData, n_cells: int) -> bool:
	return _get_season_refresh_coordinator()._ensure_season_knob_geometry_cache(map, n_cells)
func _build_season_round_knobs(map: MapData, season: int) -> Dictionary:
	return _get_season_refresh_coordinator()._build_season_round_knobs(map, season)
func continue_finish_season_round_b_plus(map: MapData, max_cells: int = 128) -> Dictionary:
	return _get_season_refresh_coordinator().continue_finish_season_round_b_plus(map, max_cells)
func pop_b_plus_round_samples() -> Dictionary:
	return _get_season_refresh_coordinator().pop_b_plus_round_samples()
func soil_arr_size_mismatch(map: MapData) -> bool:
	return _get_season_refresh_coordinator().soil_arr_size_mismatch(map)
func _sync_stage8_facade_fields_from_soa(map: MapData) -> void:
	_get_season_refresh_coordinator()._sync_stage8_facade_fields_from_soa(map)
func sus_report_last_tick_summary() -> Dictionary:
	if _sus == null:
		return {}
	return _sus.report_last_tick_summary()
func sus_report_sim_budget_window() -> Dictionary:
	if _sus == null or not _sus.has_method("report_sim_budget_window"):
		return {}
	return _sus.report_sim_budget_window()
func sus_report_job_stats() -> Dictionary:
	return _get_season_refresh_coordinator().sus_report_job_stats()
func sus_report_skipped_summary() -> Dictionary:
	if _sus == null or not _sus.has_method("report_skipped_summary"):
		return {}
	return _sus.report_skipped_summary()
func _get_native_daily_bundle_builder() -> RefCounted:
	if _native_daily_bundle_builder == null:
		_native_daily_bundle_builder = NativeDailyBundleBuilderScript.new()
		_native_daily_bundle_builder._generator = self
	return _native_daily_bundle_builder
func _get_native_daily_publish() -> RefCounted:
	if _native_daily_publish == null:
		_native_daily_publish = NativeDailyPublishScript.new()
		_native_daily_publish._generator = self
	return _native_daily_publish
func _get_runtime_climate_capture() -> RefCounted:
	if _runtime_climate_capture == null:
		_runtime_climate_capture = RuntimeClimateCaptureScript.new()
		_runtime_climate_capture._generator = self
	return _runtime_climate_capture
func _get_season_refresh_coordinator() -> RefCounted:
	if _season_refresh_coordinator == null:
		_season_refresh_coordinator = SeasonRefreshCoordinatorScript.new()
		_season_refresh_coordinator._generator = self
	return _season_refresh_coordinator
func _biome_temperature(map: MapData, cell: HexCell, fallback: float) -> float:
	return _get_season_refresh_coordinator()._biome_temperature(map, cell, fallback)
func _biome_moisture(map: MapData, cell: HexCell) -> float:
	return _get_season_refresh_coordinator()._biome_moisture(map, cell)
func _get_map_resource_initializer() -> RefCounted:
	if _map_resource_initializer == null:
		_map_resource_initializer = MapResourceInitializerScript.new()
		_map_resource_initializer._generator = self
	return _map_resource_initializer
func _get_map_runtime_bridge() -> RefCounted:
	if _map_runtime_bridge == null:
		_map_runtime_bridge = MapRuntimeBridgeScript.new()
		_map_runtime_bridge._generator = self
	return _map_runtime_bridge
func _get_map_rules_initializer() -> RefCounted:
	if _map_rules_initializer == null:
		_map_rules_initializer = MapRulesInitializerScript.new()
		_map_rules_initializer._generator = self
	return _map_rules_initializer
func _get_map_country_initializer() -> RefCounted:
	if _map_country_initializer == null:
		_map_country_initializer = MapCountryInitializerScript.new()
		_map_country_initializer._generator = self
	return _map_country_initializer
func _get_native_generation_bridge() -> RefCounted:
	if _native_generation_bridge == null:
		_native_generation_bridge = NativeGenerationBridgeScript.new()
		_native_generation_bridge._generator = self
	return _native_generation_bridge
func _ensure_generation_world_ext() -> RefCounted:
	return _get_native_generation_bridge().ensure_world_ext()
func _native_generation_cfg_dict(cfg: MapConfig) -> Dictionary:
	return _get_native_generation_bridge().native_generation_cfg_dict(cfg)
func _native_generation_profile_dict() -> Dictionary:
	return _get_native_generation_bridge().native_generation_profile_dict()
func queue_season_refresh(season_idx: int) -> void:
	_get_season_refresh_coordinator().queue_season_refresh(season_idx)
func has_pending_season_refresh() -> bool:
	return _get_season_refresh_coordinator().has_pending_season_refresh()
func begin_pending_season_refresh() -> int:
	return _get_season_refresh_coordinator().begin_pending_season_refresh()
func begin_periodic_season_refresh() -> int:
	return _get_season_refresh_coordinator().begin_periodic_season_refresh()
func run_season_refresh_stage(map: MapData, world: WorldData, season_idx: int, stage: int) -> void:
	_get_season_refresh_coordinator().run_season_refresh_stage(map, world, season_idx, stage)
func run_season_refresh_stage_micro(map: MapData, _world: WorldData, season_idx: int, stage: int, cursor: int) -> Dictionary:
	return _get_season_refresh_coordinator().run_season_refresh_stage_micro(map, _world, season_idx, stage, cursor)
func finish_season_refresh(_map: MapData, _world: WorldData, _season_idx: int) -> void:
	_get_season_refresh_coordinator().finish_season_refresh(_map, _world, _season_idx)
func season_round_b_plus_available() -> bool:
	return _get_season_refresh_coordinator().season_round_b_plus_available()
func start_season_round_b_plus(map: MapData, _world: WorldData, season: int) -> int:
	return _get_season_refresh_coordinator().start_season_round_b_plus(map, _world, season)
func run_season_round_slice_b_plus(map: MapData, _world: WorldData, max_usec: int = 0) -> Dictionary:
	return _get_season_refresh_coordinator().run_season_round_slice_b_plus(map, _world, max_usec)
func begin_finish_season_round_b_plus(map: MapData, _world: WorldData, _season: int) -> void:
	_get_season_refresh_coordinator().begin_finish_season_round_b_plus(map, _world, _season)
func _abort_season_round_b_plus_safe() -> void:
	_get_season_refresh_coordinator()._abort_season_round_b_plus_safe()
func refresh_seasonal(map: MapData, world: WorldData, season_idx: int) -> void:
	_get_season_refresh_coordinator().refresh_seasonal(map, world, season_idx)
func _bootstrap_natural_resource_deposits(map_ref, cfg, cooperative: bool = false) -> void:
	await _get_map_resource_initializer()._bootstrap_natural_resource_deposits(map_ref, cfg, cooperative)
func _mapgen_env() -> Dictionary:
	return _get_terrain_generator()._mapgen_env()
func _mapgen_sanitize_report(src: Dictionary, depth: int = 2) -> Dictionary:
	return _get_terrain_generator()._mapgen_sanitize_report(src, depth)
func generation_preflight() -> Dictionary:
	return _get_native_generation_bridge().generation_preflight()
func _fail_generation(stage: String, reason: String, summary: String, hint: String = "") -> Dictionary:
	return _get_terrain_generator()._fail_generation(stage, reason, summary, hint)
func _generation_superseded(stage: String) -> Dictionary:
	return _get_terrain_generator()._generation_superseded(stage)
func last_generation_error_text() -> String:
	return _get_terrain_generator().last_generation_error_text()
func native_generation_base_report() -> Dictionary:
	return _native_generation_base_report
func _mapgen_native_smoke(w: int = 16, h: int = 12) -> Dictionary:
	return _get_native_generation_bridge().native_smoke(w, h)
static func mapgen_selfcheck_requested() -> bool:
	if OS.get_environment("PK_MAPGEN_SELFCHECK") == "1":
		return true
	for arg in OS.get_cmdline_user_args():
		if String(arg) == "--mapgen-selfcheck":
			return true
	for arg in OS.get_cmdline_args():
		if String(arg) == "--mapgen-selfcheck":
			return true
	return false
func run_mapgen_selfcheck(include_native_smoke: bool = true) -> Dictionary:
	return _get_terrain_generator().run_mapgen_selfcheck(include_native_smoke)
func _generate_cells_native_base(cfg: MapConfig, seed: int) -> MapData:
	return await _get_native_generation_bridge().generate_cells_native_base(cfg, seed)
func _init_noise(seed_val: int) -> void:
	_get_terrain_generator()._init_noise(seed_val)
const ALT_PEN_LINEAR: float = 0.40
const ALT_PEN_HIGH_AMP: float = 0.22
const ALT_PEN_HIGH_LO: float = 0.45
const ALT_PEN_HIGH_HI: float = 1.00
const ALT_PEN_ABS_ELEV_BLEND: float = 0.25
const _PUSH_EPS_TEMP: float = 1.0 / 512.0
const _PUSH_EPS_MOIST: float = 1.0 / 512.0
const _PUSH_EPS_SNOW: float = 1.0 / 256.0
func _alt_penalty_height(height_norm: float) -> float:
	return _get_terrain_generator()._alt_penalty_height(height_norm)
func _land_height_for_temperature(elevation: float, sea_level: float) -> float:
	return clampf((elevation - sea_level) / maxf(1.0 - sea_level, 0.001), 0.0, 1.0)
func _temperature_height_for_penalty(elevation: float, sea_level: float) -> float:
	var land_h: float = _land_height_for_temperature(elevation, sea_level)
	return lerpf(land_h, clampf(elevation, 0.0, 1.0), ALT_PEN_ABS_ELEV_BLEND)
func _alt_penalty(elevation: float, sea_level: float = -1.0) -> float:
	return _get_terrain_generator()._alt_penalty(elevation, sea_level)
func _derived_snow_cover(temp_now: float, land_h: float, terrain: int, cover: int) -> float:
	return _get_terrain_generator()._derived_snow_cover(temp_now, land_h, terrain, cover)
func _compute_temperature(ny: float, elevation: float, sea_level: float = -1.0) -> float:
	var lat_temp: float = DCClimateMath.lat_temp_bell_from_ny(ny)
	var alt_penalty: float = _alt_penalty(elevation, sea_level)
	return clampf(lat_temp - alt_penalty, 0.0, 1.0)
func _bootstrap_sea_ice_fraction(map: MapData, cfg: MapConfig) -> void:
	_get_terrain_generator()._bootstrap_sea_ice_fraction(map, cfg)
func _decide_terrain(elevation: float, temperature: float, moisture: float, cfg: MapConfig, permanent_only: bool = false) -> TerrainType.TERRAIN:
	return _get_terrain_generator()._decide_terrain(elevation, temperature, moisture, cfg, permanent_only)
func _derive_landform(cell: HexCell, cfg: MapConfig) -> int:
	return _get_terrain_generator()._derive_landform(cell, cfg)
func _derive_vegetation(cell: HexCell, landform: int, temperature: float) -> int:
	return _get_terrain_generator()._derive_vegetation(cell, landform, temperature)
func _whittaker_vegetation(temperature: float, moisture: float, landform: int) -> int:
	return _get_terrain_generator()._whittaker_vegetation(temperature, moisture, landform)
func _derive_cover(cell: HexCell, snow_cover: float) -> int:
	return _get_terrain_generator()._derive_cover(cell, snow_cover)
func _sync_axes_for_cell(cell: HexCell, cfg: MapConfig, snow_cover: float, temperature_override: float = -1.0) -> void:
	_get_terrain_generator()._sync_axes_for_cell(cell, cfg, snow_cover, temperature_override)
func _sync_axes_for_map(map: MapData, cfg: MapConfig) -> void:
	for cell: HexCell in map.all_cells():
		_sync_axes_for_cell(cell, cfg, 0.0)
func _compute_ocean_currents(map: MapData, world: WorldData, hex_size: float) -> void:
	_get_terrain_generator()._compute_ocean_currents(map, world, hex_size)
func _compute_terrain_perturbed_wind(map: MapData) -> void:
	_get_terrain_generator()._compute_terrain_perturbed_wind(map)
static func _is_water(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.LAKE \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
		or t == TerrainType.TERRAIN.SEA_ICE
func _generate_static_research_signals(map: MapData) -> void:
	_get_terrain_generator()._generate_static_research_signals(map)
func _append_natural_resource_research_signals(map: MapData) -> void:
	_get_terrain_generator()._append_natural_resource_research_signals(map)
func _bio_occupancy_base_knobs(map_ref: MapData) -> Dictionary:
	return _get_terrain_generator()._bio_occupancy_base_knobs(map_ref)
func _bio_occupancy_daily_knobs(map_ref: MapData) -> Dictionary:
	return _get_terrain_generator()._bio_occupancy_daily_knobs(map_ref)
func _bio_reserve_column(map_ref: MapData, resource_id: String, n: int,
		empty: PackedFloat32Array) -> PackedFloat32Array:
	return _get_terrain_generator()._bio_reserve_column(map_ref, resource_id, n, empty)
func _publish_bio_occupancy_to_runtime(map_ref: MapData) -> void:
	_get_terrain_generator()._publish_bio_occupancy_to_runtime(map_ref)
func _seed_bio_occupancy(map_ref: MapData) -> void:
	_get_terrain_generator()._seed_bio_occupancy(map_ref)
func _log_bio_occupancy_seed_summary(knobs: Dictionary, seed_res: Dictionary,
		landmass_count: int, province_count: int) -> void:
	_get_terrain_generator()._log_bio_occupancy_seed_summary(knobs, seed_res, landmass_count, province_count)
func _log_bio_occupancy_seed(knobs: Dictionary, seed_res: Dictionary, landmass_count: int,
		province_count: int) -> void:
	_get_terrain_generator()._log_bio_occupancy_seed(knobs, seed_res, landmass_count, province_count)
func _log_bio_occupancy_seed_native(report: Dictionary, knobs: Dictionary) -> void:
	_get_terrain_generator()._log_bio_occupancy_seed_native(report, knobs)
func _bio_landmass_summary_gdscript(occupancy: PackedInt32Array,
		landmass: PackedInt32Array, knobs: Dictionary,
		out_landmass: PackedInt32Array, out_classes: PackedStringArray,
		out_foods: PackedStringArray) -> void:
	_get_terrain_generator()._bio_landmass_summary_gdscript(occupancy, landmass, knobs, out_landmass, out_classes, out_foods)
func run_bio_occupancy_pass_native(map_ref, run_diffusion: bool = false,
		day_index: int = 0, slice_enabled: bool = false,
		bio_slice_cells: int = BIO_OCCUPANCY_SLICE_CELLS) -> Dictionary:
	return _get_terrain_generator().run_bio_occupancy_pass_native(map_ref, run_diffusion, day_index, slice_enabled, bio_slice_cells)
static func _is_permanent_landform(t: int) -> bool:
	return t == TerrainType.TERRAIN.OASIS \
			or t == TerrainType.TERRAIN.DELTA \
			or t == TerrainType.TERRAIN.SALT_FLAT \
			or t == TerrainType.TERRAIN.BADLANDS \
			or t == TerrainType.TERRAIN.CHAPARRAL \
			or t == TerrainType.TERRAIN.MOOR \
			or t == TerrainType.TERRAIN.FLOODPLAIN \
			or t == TerrainType.TERRAIN.MESA
func _cube_to_row(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.y, 0, cfg.height - 1)
func _cube_row_norm(cell: HexCell, cfg: MapConfig) -> float:
	return float(_cube_to_row(cell, cfg)) / float(maxi(cfg.height - 1, 1))
func public_cube_row_norm(cell: HexCell) -> float:
	if _last_cfg == null or cell == null:
		return 0.5
	return _cube_row_norm(cell, _last_cfg)
func _publish_native_generation_from_slots(map: MapData, cfg: MapConfig) -> bool:
	return _get_mapgen_climate_passes_a()._publish_native_generation_from_slots(map, cfg)
func _bake_temp_baseline_year_native(map: MapData) -> void:
	_get_mapgen_climate_passes_a()._bake_temp_baseline_year_native(map)
func _moisture_lat_weight(ny: float) -> float:
	var abs_lat := absf(ny * 2.0 - 1.0)
	var t := clampf((abs_lat - 0.18) / 0.64, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
func refresh_climate_daily(map: MapData, season_phase: float) -> void:
	_get_mapgen_climate_passes_a().refresh_climate_daily(map, season_phase)
func refresh_climate_loading(map: MapData, season_phase: float) -> void:
	await _get_mapgen_climate_passes_a().refresh_climate_loading(map, season_phase)
func _climate_pass_a(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_climate_pass_a_module.run(map, season_phase)
func _climate_pass_b(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_climate_pass_b_module.run(map, season_phase)
func _dump_sea_ice_breakdown_if_slow() -> void:
	_get_mapgen_climate_passes_a()._dump_sea_ice_breakdown_if_slow()
func _dump_weather_breakdown_if_slow() -> void:
	_get_mapgen_climate_passes_a()._dump_weather_breakdown_if_slow()
func _sea_ice_slice_budget_cells() -> int:
	return _get_mapgen_climate_passes_a()._sea_ice_slice_budget_cells()
func _sea_ice_solar_gate_enabled(cp) -> bool:
	return cp != null and cp.get("sea_ice_solar_gate_enabled") != null \
		and bool(cp.sea_ice_solar_gate_enabled)
func _sea_ice_freeze_gate(insolation_now: float, freeze_low: float, freeze_high: float) -> float:
	var hi: float = maxf(freeze_high, freeze_low + 0.001)
	return clampf(1.0 - smoothstep(freeze_low, hi, insolation_now), 0.0, 1.0)
func _sea_ice_insolation_input(map: MapData, cells: Array, season_phase: float) -> PackedFloat32Array:
	return _get_mapgen_climate_passes_a()._sea_ice_insolation_input(map, cells, season_phase)
func _abort_sea_ice_state_machine(reason: String = "abort") -> void:
	_get_mapgen_climate_passes_a()._abort_sea_ice_state_machine(reason)
func _begin_sea_ice_state_machine(map: MapData, season_phase: float, token: int) -> bool:
	return _get_mapgen_climate_passes_a()._begin_sea_ice_state_machine(map, season_phase, token)
func _run_sea_ice_state_machine_slice(map: MapData, season_phase: float, token: int) -> Dictionary:
	return _get_mapgen_climate_passes_a()._run_sea_ice_state_machine_slice(map, season_phase, token)
func _consume_sea_ice_dt_days(max_dt_days: float = 30.0) -> float:
	return _get_mapgen_climate_passes_a()._consume_sea_ice_dt_days(max_dt_days)
func _consume_climate_dt_days() -> float:
	return _get_mapgen_climate_passes_a()._consume_climate_dt_days()
func _consume_weather_dt_days() -> float:
	return _get_mapgen_climate_passes_a()._consume_weather_dt_days()
func _apply_sea_ice_daily_pass(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_sea_ice_daily_pass_module.run(map, season_phase)
func _ocean_water_pass(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_ocean_water_pass_module.run(map, season_phase)
func _ocean_land_pass(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_ocean_land_pass_module.run(map, season_phase)
func _build_climate_b_foliage_table() -> PackedFloat32Array:
	return _get_mapgen_climate_passes_a()._build_climate_b_foliage_table()
func _begin_ocean_heat_transport_sliced(map: MapData, season_phase: float, cp: ClimateProfile) -> bool:
	return _get_mapgen_climate_passes_a()._begin_ocean_heat_transport_sliced(map, season_phase, cp)
func _ocean_slice_budget_cells() -> int:
	return _get_mapgen_climate_passes_a()._ocean_slice_budget_cells()
func _make_climate_pass_result(pass_type: String, done: bool, elapsed_ms: float, processed_cells: int,
		cursor_start: int, cursor_end: int, status: String = "", token: int = 0,
		stage: String = "", abort_reason: String = "") -> Dictionary:
	return _get_mapgen_climate_passes_a()._make_climate_pass_result(pass_type, done, elapsed_ms, processed_cells, cursor_start, cursor_end, status, token, stage, abort_reason)
func _climate_pass_state_matches(pass_type: String, map: MapData, token: int = 0) -> bool:
	return _get_mapgen_climate_passes_a()._climate_pass_state_matches(pass_type, map, token)
func begin_climate_pass(pass_type: String, map: MapData, season_phase: float, opts: Dictionary = {}) -> Dictionary:
	return _get_mapgen_climate_passes_a().begin_climate_pass(pass_type, map, season_phase, opts)
func abort_climate_pass(pass_type: String, reason: String = "abort") -> Dictionary:
	return _get_mapgen_climate_passes_a().abort_climate_pass(pass_type, reason)
func _abort_all_climate_passes(reason: String = "abort_all") -> void:
	_get_mapgen_climate_passes_a()._abort_all_climate_passes(reason)
func _run_climate_pass_legacy_fallback(pass_type: String, map: MapData, season_phase: float, token: int, reason: String) -> Dictionary:
	push_error("[climate/%s] native failed: slice fallback retired (%s); previous fields retained" % [pass_type, reason])
	return _make_climate_pass_result(pass_type, false, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_FAILED, token, pass_type, reason)
func run_climate_pass_slice(pass_type: String, map: MapData, season_phase: float, opts: Dictionary = {}) -> Dictionary:
	return _get_mapgen_climate_passes_a().run_climate_pass_slice(pass_type, map, season_phase, opts)
func run_ocean_water_pass_slice(map: MapData, season_phase: float) -> Dictionary:
	_ensure_daily_pass_modules()
	return _ocean_water_pass_module.run_ocean_water_pass_slice(map, season_phase)
func run_ocean_land_pass_slice(map: MapData, season_phase: float) -> Dictionary:
	_ensure_daily_pass_modules()
	return _ocean_land_pass_module.run_ocean_land_pass_slice(map, season_phase)
func refresh_daily(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	var fronts: Array[WeatherFront] = refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
	refresh_daily_stage_b(map, world)
	return fronts
func publish_weather_lut_after_weather_commit(map: MapData, world: WorldData, native_lut: PackedByteArray = PackedByteArray(), force_changed: bool = false) -> Dictionary:
	return _get_climate_pass_b_module().publish_weather_lut_after_weather_commit(map, world, native_lut, force_changed)
func refresh_weather_daily(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	return _get_climate_pass_b_module().refresh_weather_daily(map, world, season_idx, climate_anomaly, season_phase)
func weather_native_daily_readiness_report() -> Dictionary:
	return _get_climate_pass_b_module().weather_native_daily_readiness_report()
func weather_native_daily_available() -> bool:
	return bool(weather_native_daily_readiness_report().get("ready", false))
func refresh_daily_stage_a(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	return _get_climate_pass_b_module().refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
func weather_uses_field_solver() -> bool:
	return _weather_system != null \
		and _weather_system.has_method("uses_weather_field") \
		and bool(_weather_system.uses_weather_field())
func weather_field_slice_cells() -> int:
	return _get_climate_pass_b_module().weather_field_slice_cells()
func begin_weather_refresh_stage_a(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> void:
	_get_climate_pass_b_module().begin_weather_refresh_stage_a(map, world, season_idx, climate_anomaly, season_phase)
func run_weather_refresh_stage_a_slice(cell_budget: int) -> Dictionary:
	return _get_climate_pass_b_module().run_weather_refresh_stage_a_slice(cell_budget)
func commit_weather_refresh_stage_a(map: MapData, world: WorldData) -> Array[WeatherFront]:
	return _get_climate_pass_b_module().commit_weather_refresh_stage_a(map, world)
func runtime_hydrology_enabled() -> bool:
	var cp_now := _c()
	return cp_now != null and bool(cp_now.runtime_hydrology_enabled)
func run_hydrology_discharge_pass_native(map: MapData, world: WorldData) -> Dictionary:
	return _get_climate_pass_b_module().run_hydrology_discharge_pass_native(map, world)
func refresh_daily_stage_b(map: MapData, world: WorldData) -> void:
	_get_climate_pass_b_module().refresh_daily_stage_b(map, world)
func active_weather_fronts() -> Array[WeatherFront]:
	if _weather_system == null:
		return [] as Array[WeatherFront]
	return _weather_system.active_fronts()
func set_weather_refresh_stride(s: int) -> void:
	_get_climate_pass_b_module().set_weather_refresh_stride(s)
func set_daily_climate_refresh_stride(s: int) -> void:
	_get_wind_heat_transport().set_daily_climate_refresh_stride(s)
func _build_transpiration_donor_table() -> PackedFloat32Array:
	return _get_wind_heat_transport()._build_transpiration_donor_table()
func _make_transpiration_native_unavailable(reason: String, t_wall_us: int, n_cells: int = 0) -> Dictionary:
	return _get_wind_heat_transport()._make_transpiration_native_unavailable(reason, t_wall_us, n_cells)
func _sync_transpiration_native_outputs(map: MapData, dirty_indices: PackedInt32Array, dirty_values: PackedFloat32Array) -> Dictionary:
	return _get_wind_heat_transport()._sync_transpiration_native_outputs(map, dirty_indices, dirty_values)
func run_transpiration_pass_native(map: MapData) -> Dictionary:
	_ensure_daily_pass_modules()
	return _transpiration_pass_module.run_native(map)
func _build_albedo_donor_table() -> PackedFloat32Array:
	return _get_wind_heat_transport()._build_albedo_donor_table()
const WEATHER_VITALITY_PENALTY: Dictionary = {
	WeatherType.WT.DROUGHT: 0.004,
	WeatherType.WT.BLIZZARD: 0.002,
	WeatherType.WT.HEATWAVE: 0.003,
	WeatherType.WT.STORM: 0.001,
	WeatherType.WT.MONSOON: 0.001,
}
func _ensure_vegdyn_lut() -> void:
	_get_wind_heat_transport()._ensure_vegdyn_lut()
func refresh_yearly(map: MapData, _world: WorldData) -> void:
	_get_wind_heat_transport().refresh_yearly(map, _world)
func _ecosystem_score_vegetation(history: PackedByteArray) -> float:
	return _get_wind_heat_transport()._ecosystem_score_vegetation(history)
func _ecosystem_score(history: PackedByteArray) -> float:
	return _get_wind_heat_transport()._ecosystem_score(history)
func _season_temp_offset(ny: float, season: int) -> float:
	var phase_mid: float = float(season) + 0.5
	return _insolation_season_offset(ny, phase_mid)
const _INSOLATION_DAYLEN_AMP: float = 0.35  # legacy 默认；运行时被 profile.insolation_daylen_amp 覆盖
func _subsolar_lat_rad(season_phase: float) -> float:
	return _get_wind_heat_transport()._subsolar_lat_rad(season_phase)
func _compute_insolation(ny: float, season_phase: float) -> float:
	return _get_wind_heat_transport()._compute_insolation(ny, season_phase)
func _insolation_annual_mean(ny: float) -> float:
	return _get_wind_heat_transport()._insolation_annual_mean(ny)
func _rebuild_insol_mean_lut() -> void:
	_get_wind_heat_transport()._rebuild_insol_mean_lut()
func _insol_dev(ny: float, season_phase: float) -> float:
	var mean_val: float = _insolation_annual_mean(ny)
	var now_val: float = _compute_insolation(ny, season_phase)
	return clampf(DCClimateMath.compute_insolation_dev_from_values(ny, now_val, mean_val), -1.0, 1.0)
func _insolation_season_offset(ny: float, season_phase: float) -> float:
	return _get_wind_heat_transport()._insolation_season_offset(ny, season_phase)
func month_of_year(season_phase: float) -> Dictionary:
	return _get_wind_heat_transport().month_of_year(season_phase)
func cell_ny(cell: HexCell) -> float:
	if cell == null or _last_cfg == null:
		return 0.5
	return _cube_row_norm(cell, _last_cfg)
func observe_local_month(cell: HexCell, season_phase: float) -> Dictionary:
	return _get_wind_heat_transport().observe_local_month(cell, season_phase)
func _build_native_wind_baseline(map: MapData) -> PackedFloat32Array:
	return _get_wind_heat_transport()._build_native_wind_baseline(map)
func _supports_wind_air_slot_temp() -> bool:
	return _data_core_world_ext != null \
			and bool(_data_core_world_ext.supports_wind_air_slot_temp())
func _publish_wind_heat_native_outputs(map: MapData) -> void:
	_get_wind_heat_transport()._publish_wind_heat_native_outputs(map)
func run_wind_air_mass_pass_native(map: MapData, season_phase: float) -> Dictionary:
	return _get_wind_heat_transport().run_wind_air_mass_pass_native(map, season_phase)
func run_wind_surface_pass_native(map: MapData, season_phase: float) -> Dictionary:
	return _get_wind_heat_transport().run_wind_surface_pass_native(map, season_phase)
func _wind_air_mass_pass(map: MapData, season_phase: float, cooperative: bool = false) -> void:
	await _get_wind_heat_transport()._wind_air_mass_pass(map, season_phase, cooperative)
func _wind_surface_pass(map: MapData, season_phase: float, cooperative: bool = false) -> void:
	await _get_wind_heat_transport()._wind_surface_pass(map, season_phase, cooperative)
func _on_baker_stage_progress(stage: String, fraction: float) -> void:
	var mapped_stage := "encode" if stage == "done" else stage
	bake_progress.emit(mapped_stage, lerpf(0.44, 0.88, clampf(fraction, 0.0, 1.0)))
func _yield_generation_frame():
	return _loading_frames.next_frame()
func run_async_climate_round_bench(pass_name: String = "transp") -> Dictionary:
	return _get_wind_heat_transport().run_async_climate_round_bench(pass_name)
func run_async_climate_round_stage1_bench() -> Dictionary:
	return run_async_climate_round_bench("transp")
func _bench_async_transp(map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	return _get_wind_heat_transport()._bench_async_transp(map, n_cells, cp_f5, report)
func _bench_async_pass_a(map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	return _get_wind_heat_transport()._bench_async_pass_a(map, n_cells, cp_f5, report)
func _busy_wait_poll(timeout_us: int) -> Dictionary:
	return _get_wind_heat_transport()._busy_wait_poll(timeout_us)
func _diff_f32_arrays(a: PackedFloat32Array, b: PackedFloat32Array, n: int) -> Dictionary:
	return _get_wind_heat_transport()._diff_f32_arrays(a, b, n)
func cancel_loading_work() -> void:
	_get_wind_heat_transport().cancel_loading_work()
var _loading_step_usec := 0
var _loading_step_name := ""
func _loading_profile_step(label: String) -> void:
	_get_wind_heat_transport()._loading_profile_step(label)
const LOADING_TAIL_START := 0.96
const LOADING_TAIL_CEIL := 0.995
const LOADING_TAIL_GAIN := 0.10
const LOADING_TAIL_STAGE_RULES := [
	["resource", "resources"],
	["bio", "ecology_bind"],
	["economy", "gameplay_bind"],
	["country", "gameplay_bind"],
	["ideology", "gameplay_bind"],
	["settlement", "gameplay_bind"],
	["modifier", "gameplay_bind"],
	["trigger", "gameplay_bind"],
	["effect", "gameplay_bind"],
	["native_daily", "runtime_bind"],
	["sus", "runtime_bind"],
	["topology", "runtime_bind"],
]
const LOADING_TAIL_STAGE_DEFAULT := "world_bind"
var _loading_tail_progress := 0.0
var _loading_tail_epoch := -1
var _loading_tail_world_id := 0
var _loading_tail_active := false
func _loading_tail_stage_for(label: String) -> String:
	return _get_wind_heat_transport()._loading_tail_stage_for(label)
func _emit_loading_tail_progress(label: String) -> void:
	_get_wind_heat_transport()._emit_loading_tail_progress(label)
var _generation_slice_start_usec := 0
func _generation_slice_due() -> bool:
	return _get_wind_heat_transport()._generation_slice_due()
func _prepare_season_geometry_cooperative(map: MapData, n: int) -> void:
	await _get_wind_heat_transport()._prepare_season_geometry_cooperative(map, n)
