extends RefCounted

const MapTables = preload("res://scripts/geography/map_generator_tables.gd")

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
var _environment_publish_callsite_mask: int = 0
var _environment_publish_count: int = 0
var _environment_publish_orphan_day: int = -1
const ENV_CALLSITE_HOST_DAY_CHANGED := 1
const ENV_CALLSITE_SUS_TICK := 2
const ENV_CALLSITE_INLINE_DAY := 4
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
var _last_active_fronts: Array[WeatherFront] = [] as Array[WeatherFront]
var _refresh_daily_call_index: int = -1
var _weather_stage_b_call_index: int = -1
var _native_daily_hydrology_call_index: int = -1
var _typed_fields_migrated: bool = false
var _sus = null
var _sus_bootstrap: RefCounted = null
var _data_core_world: DCWorld = null
var _data_core_world_ext: RefCounted = null
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
const MAPGEN_REQUIRED_NATIVE_METHODS = MapTables.MAPGEN_REQUIRED_NATIVE_METHODS
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
func _ensure_daily_pass_modules() -> void:
	_get_native_generation_bridge()._ensure_daily_pass_modules()
var _loading_epoch := 0
const LoadingFrameGateScript = preload("res://scripts/geography/loading_frame_gate.gd")
var _loading_frames = LoadingFrameGateScript.new()
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
func environment_publish_callsite_mask() -> int:
	return _get_runtime_climate_capture().environment_publish_callsite_mask()
func environment_publish_diagnostics() -> Dictionary:
	return _get_runtime_climate_capture().environment_publish_diagnostics()
func _runtime_environment_publish_allowed(callsite: int, day: int) -> bool:
	return _get_runtime_climate_capture()._runtime_environment_publish_allowed(callsite, day)
func initialize_world_environment(notice_history: Array = []) -> Dictionary:
	return _get_runtime_climate_capture().initialize_world_environment(notice_history)

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
var _continuation_reentry_guard := false
func _native_daily_live_f32(slot_name: String, fallback: PackedFloat32Array,
		n: int) -> PackedFloat32Array:
	return _get_native_daily_bundle_builder()._native_daily_live_f32(slot_name, fallback, n)
func _native_daily_live_u8(slot_name: String, fallback: PackedByteArray,
		n: int) -> PackedByteArray:
	return _get_native_daily_bundle_builder()._native_daily_live_u8(slot_name, fallback, n)
func _native_daily_base_tick_knobs(ctx: SusTickContext) -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_base_tick_knobs(ctx)
func _build_native_daily_stage_b_knobs(map: MapData, cp_now, call_index: int,
		elapsed_days_per_call: float = 1.0) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_stage_b_knobs(map, cp_now, call_index, elapsed_days_per_call)
func _native_daily_season_cadence_policy(cp_now, call_index: int) -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_season_cadence_policy(cp_now, call_index)
var _maritime_factor_cache: PackedFloat32Array = PackedFloat32Array()
var _maritime_factor_cache_key: String = ""
func _ensure_maritime_factor(map: MapData, decay_cells: float) -> PackedFloat32Array:
	return _get_mapgen_native_daily_runtime()._ensure_maritime_factor(map, decay_cells)
const _RUNTIME_CLIMATE_ROUND_REQUIRED_LANES = MapTables._RUNTIME_CLIMATE_ROUND_REQUIRED_LANES
var _runtime_climate_round_input_lanes_reported: bool = false
var _runtime_climate_distribute_reported: bool = false
var _runtime_climate_field_reported: bool = false
var _runtime_climate_worker_weather_embed_day: int = -1000000
var _runtime_climate_worker_stage_b_call_index: int = -1
func publish_worker_climate_visuals(defer_upload: bool = false, commit: Dictionary = {}) -> Dictionary:
	return _get_mapgen_native_daily_runtime().publish_worker_climate_visuals(defer_upload, commit)
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
func _prepare_temperature_transport_anomaly_state(map: MapData, n: int, cells: Array = [], prefer_cached: bool = false) -> PackedFloat32Array:
	return _get_mapgen_native_daily_runtime()._prepare_temperature_transport_anomaly_state(map, n, cells, prefer_cached)
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
func _native_daily_split_weather_node_enabled(cp_now) -> bool:
	return _get_native_daily_bundle_builder()._native_daily_split_weather_node_enabled(cp_now)
func _native_daily_weather_clock_values(default_phase: float) -> Dictionary:
	return _get_native_daily_bundle_builder()._native_daily_weather_clock_values(default_phase)
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
		defer_heavy_pass_knobs: bool = false) -> Dictionary:
	return _get_native_daily_bundle_builder()._build_native_daily_bundle(ctx, map, _world, commit_side_effects, sea_ice_dt_cap_days, commit_sea_ice_side_effects, defer_heavy_pass_knobs)
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
func _record_native_daily_slice_climate_breakdown(res: Dictionary, breakdown: Dictionary, map: MapData, done: bool, rc_int: int) -> void:
	_get_native_daily_publish()._record_native_daily_slice_climate_breakdown(res, breakdown, map, done, rc_int)
func _native_daily_contract_stride_days() -> int:
	return _get_mapgen_native_daily_runtime()._native_daily_contract_stride_days()
func _native_daily_contract_budget_days() -> int:
	return _get_mapgen_native_daily_runtime()._native_daily_contract_budget_days()
func _native_daily_effective_node_range_config(cp, ctx: SusTickContext, map_ref: MapData) -> Dictionary:
	return _get_mapgen_native_daily_runtime()._native_daily_effective_node_range_config(cp, ctx, map_ref)
func _native_daily_begin_contract_round(ctx: SusTickContext) -> void:
	_get_mapgen_native_daily_runtime()._native_daily_begin_contract_round(ctx)
func _native_daily_stamp_contract(res: Dictionary, breakdown: Dictionary,
		ctx: SusTickContext, committed: bool, state: String) -> void:
	_get_mapgen_native_daily_runtime()._native_daily_stamp_contract(res, breakdown, ctx, committed, state)
func run_native_daily_slice_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	return _get_mapgen_native_daily_runtime().run_native_daily_slice_from_job(ctx, _map, _world)
func run_native_daily_tick_from_job(ctx: SusTickContext, _map: MapData, _world: WorldData) -> Dictionary:
	return _get_mapgen_native_daily_runtime().run_native_daily_tick_from_job(ctx, _map, _world)
func sus_tick_daily(world_clock_node, day_index_override: int = -1,
		season_phase_override: float = NAN) -> Dictionary:
	return _get_mapgen_native_daily_runtime().sus_tick_daily(world_clock_node, day_index_override, season_phase_override)
func sus_reset_all() -> void:
	_get_mapgen_native_daily_runtime().sus_reset_all()
func set_current_fast_tick_idx(idx: int) -> void:
	_get_mapgen_native_daily_runtime().set_current_fast_tick_idx(idx)
func sus_ocean_currents_breakdown() -> Dictionary:
	return _get_mapgen_native_daily_runtime().sus_ocean_currents_breakdown()
func _weather_front_count_from_value(v) -> int:
	return _get_mapgen_native_daily_runtime()._weather_front_count_from_value(v)
func _normalized_weather_breakdown(src: Dictionary) -> Dictionary:
	return _get_mapgen_native_daily_runtime()._normalized_weather_breakdown(src)
func consume_pending_enum_atlas_axis() -> String:
	return _get_mapgen_native_daily_runtime().consume_pending_enum_atlas_axis()
func queue_detail_scatter_refresh(indices: PackedInt32Array) -> void:
	_get_mapgen_native_daily_runtime().queue_detail_scatter_refresh(indices)
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
func sus_dynamic_visual_atlas_breakdown() -> Dictionary:
	return _get_mapgen_native_daily_runtime().sus_dynamic_visual_atlas_breakdown()
const RUNTIME_CLIMATE_DOMAIN_BIT := 1 << 1
const CLIMATE_AUTHORITY_GRANT_TIMEOUT_MS := 60000
func _climate_authority_grant_pending(thread_report: Dictionary) -> bool:
	return _get_mapgen_native_daily_runtime()._climate_authority_grant_pending(thread_report)
func _wait_climate_authority_grant() -> Dictionary:
	return _get_mapgen_native_daily_runtime()._wait_climate_authority_grant()
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
func _ensure_natural_resource_knobs() -> void:
	_get_mapgen_native_daily_runtime()._ensure_natural_resource_knobs()
const BIO_LOG_CLASS_NAMES = MapTables.BIO_LOG_CLASS_NAMES
const BIO_LOG_FOOD_IDS := ["bio.maize", "bio.wheat", "bio.rice", "bio.potato"]
const BIO_LOG_FOOD_NAMES := ["maize", "wheat", "rice", "potato"]
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
const ALT_PEN_LINEAR: float = 0.40
const ALT_PEN_HIGH_AMP: float = 0.22
const ALT_PEN_HIGH_LO: float = 0.45
const ALT_PEN_HIGH_HI: float = 1.00
const ALT_PEN_ABS_ELEV_BLEND: float = 0.25
const _PUSH_EPS_TEMP: float = 1.0 / 512.0
const _PUSH_EPS_MOIST: float = 1.0 / 512.0
const _PUSH_EPS_SNOW: float = 1.0 / 256.0
const WEATHER_VITALITY_PENALTY = MapTables.WEATHER_VITALITY_PENALTY
const _INSOLATION_DAYLEN_AMP: float = 0.35  # legacy 默认；运行时被 profile.insolation_daylen_amp 覆盖
var _loading_step_usec := 0
var _loading_step_name := ""
const LOADING_TAIL_START := 0.96
const LOADING_TAIL_CEIL := 0.995
const LOADING_TAIL_GAIN := 0.10
const LOADING_TAIL_STAGE_RULES = MapTables.LOADING_TAIL_STAGE_RULES
const LOADING_TAIL_STAGE_DEFAULT := "world_bind"
var _loading_tail_progress := 0.0
var _loading_tail_epoch := -1
var _loading_tail_world_id := 0
var _loading_tail_active := false
var _generation_slice_start_usec := 0
