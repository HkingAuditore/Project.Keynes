// Frozen environment inputs, their manifest, and validation.

struct RuntimeEnvironmentSnapshot {
    // Host 私有 sealed copy 的派生摘要，不参与原输入 hash 或保存协议。
    // publish_environment 完整校验后覆盖它，调用方提供的值从不被信任。
    uint64_t sealed_climate_input_hash = 0;
    // 主线程捕获，发布后不可变；worker 仅在对应 epoch 开始前消费。
    std::shared_ptr<const RuntimeEconomyDayInput> economy_input;
    // Compiled on the Godot/main-thread capture boundary. A worker accepts a
    // frame only when it targets the same ABI/catalog/map shape it bootstrapped
    // with; source objects and profile strings never cross this boundary.
    uint32_t climate_catalog_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    uint64_t climate_catalog_hash = 0;
    uint32_t climate_map_width = 0;
    uint32_t climate_map_height = 0;
    uint64_t generation = 0;
    int64_t day = 0;
    // Sparse fixtures remain legal for diagnostics while the migration is in
    // SHADOW. Production frames set this flag so the worker rejects any
    // missing lane instead of synthesizing a per-cell default.
    bool climate_input_complete = false;
    float dt_days = 1.0f;
    uint32_t cell_count = 0;
    bool topology_validated = false;
    double season_phase = 0.0;
    double climate_anomaly = 0.0;
    uint64_t vision_revision = 0;
    uint64_t topology_generation = 0;
    bool fog_solved = false;
    std::vector<float> cell_temp;
    std::vector<float> cell_temp_30d;
    std::vector<float> cell_temp_365d;
    std::vector<float> cell_temp_baseline_year;
    std::vector<float> cell_base_moisture;
    std::vector<float> cell_moisture;
    std::vector<float> cell_plant_available_water;
    std::vector<float> cell_soil_moisture;
    std::vector<float> cell_water_balance_30d;
    std::vector<float> cell_weather_precip;
    std::vector<float> cell_snow_cover;
    std::vector<float> cell_weather_intensity;
    std::vector<float> cell_weather_vapor;
    std::vector<float> cell_weather_cloud_water;
    std::vector<float> cell_weather_cloud;
    std::vector<uint8_t> cell_weather_type;
    std::vector<uint8_t> cell_weather_transition;
    std::vector<float> cell_sea_ice_frac_prev;
    std::vector<float> cell_river_discharge_30d;
    std::vector<float> cell_vegetation_vitality;
    std::vector<float> cell_insolation_dev;
    std::vector<float> cell_heat_input;
    std::vector<float> cell_wind_x;
    std::vector<float> cell_wind_y;
    std::vector<float> cell_wind_speed;
    // B8 P2：物理环流求解器仍在主线程（cyclone/monsoon/traj/SLP/洋流），但下面
    // 两条是 weather field solve 的直接输入，必须先能 transport，才谈得上把求解器
    // 搬进 worker。traj 只有通过生产同一套指纹/资格校验时才有值；空 = worker 与
    // 生产一起走 hopping 回退。monsoon 是主线程物理求解的派生量，允许为零。
    std::vector<float> cell_wind_traj_w;
    std::vector<int32_t> cell_wind_traj_idx;
    std::vector<float> cell_monsoon_thermal;
    // B8-2：worker 自持 cyclone 的冷启动种子。生产条目表在 DCWorldExt 成员里，
    // capture 用同一个 encode 把它变成 blob；worker 第一次见到有效 blob 时接管，
    // 之后自己推进并随 CLM2 ABI 6 持久化。genesis（从前沿注入新气旋）仍留在主线程，
    // 所以这里只搬已有条目，不搬前沿。
    std::vector<uint8_t> cyclone_seed_blob;
    bool   cyclone_enabled = false;
    float  cyclone_dt_days = 1.0f;
    int32_t cyclone_max_radius_cells = 5;
    float  cyclone_world_bounds_pos_y = 0.0f;
    float  cyclone_world_bounds_size_y = 1.0f;
    float  cyclone_wrap_width_x = 0.0f;
    // genesis（出生）判据：ACTIVE 下没有 WeatherFront，worker 用当天 weather_type /
    // intensity 作为"前沿等价物"，阈值与生产 native-entity 路径逐条一致。
    int32_t cyclone_storm_type_id = -1;
    int32_t cyclone_capacity = 24;
    int32_t cyclone_births_per_commit = 2;
    float  cyclone_min_temp = 0.58f;
    float  cyclone_min_instability = 0.40f;
    float  cyclone_max_shear = 0.42f;
    float  cyclone_min_lat = 0.06f;
    float  cyclone_max_lat = 0.40f;
    float  cyclone_wake_days = 32.0f;
    // ── B8 P2：worker 侧物理环流 prepass 的标量（Pod，Godot 无依赖）──────────
    //
    // 只搬常量：per-cell lane 用快照里已有的 terrain/landform/pos/lat_norm/
    // elevation/风 lane。来源是 MapBaker::runtime_physics_knobs()（生产四个
    // stage base dict 的标量投影），保证 worker 与生产读同一份 profile 值。
    // ready=0 时 missing_key 给出第一个缺席的键（诊断用），worker 不跑物理。
    struct ClimatePhysicsKnobs {
        // SLP
        float slp_lat_amp = 0.16f;
        float slp_land_amp = 0.55f;
        float slp_water_damp = 0.20f;
        float slp_interior_boost = 1.30f;
        float slp_coast_damp = 0.60f;
        float slp_thermal_weight = 0.0f;
        float slp_ice_high_weight = 0.0f;
        float slp_snow_high_weight = 0.0f;
        float slp_moist_low_weight = 0.12f;
        float slp_response_rate = 0.55f;
        float slp_synoptic_amp = 0.075f;
        float slp_target_p95 = 0.18f;
        int32_t slp_mobile_low_count = 0;
        float slp_mobile_low_amp = 0.0f;
        float slp_mobile_low_sigma = 0.16f;
        float slp_mobile_low_period_days = 38.0f;
        int32_t slp_smooth_passes = 1;
        int32_t slp_recenter = 1;
        // WIND
        float wind_response_rate = 0.25f;
        float wind_max_turn_deg_per_day = 32.0f;
        float wind_min_flux_for_dir_update = 0.035f;
        float wind_synoptic_amp = 0.055f;
        float wind_synoptic_period_days = 6.0f;
        int32_t wind_terrain_aware = 1;
        int32_t wind_belt_only_debug = 0;
        float wind_momentum_advect_w = 0.0f;
        float wind_momentum_diffuse_w_daily = 0.0f;
        int32_t wind_traj_table_enabled = 0;
        float wind_traj_pos_scale = 0.65f;
        float wind_traj_dt_days = 10.0f;
        int32_t wind_traj_weather_share = 1;
        float wind_div_damp_alpha = 0.0f;
        int32_t thermal_monsoon_enabled = 0;
        float thermal_monsoon_lat_limit = 0.45f;
        float thermal_monsoon_deadband = 0.015f;
        float thermal_monsoon_full_contrast = 0.08f;
        float thermal_monsoon_gain = 0.85f;
        float thermal_monsoon_breeze_floor = 0.20f;
        // 共享
        int32_t days_per_year = 365;
        float axial_tilt_deg = 23.5f;
        float insolation_daylen_amp = 0.35f;
        int32_t lat_lut_bins = 1024;
        int32_t land_lf_mountain = -1;
        int32_t land_lf_peak = -1;
        int32_t land_lf_hill = -1;
        pk_async_physics::PsiSolveKnobs psi;
        pk_async_physics::UpwellingKnobs upwelling;
        bool psi_warm_start = true;
        bool daily_split = false;
        int32_t daily_period_days = 1;
        int32_t ocean_period_days = 30;
        int32_t world_seed = 0;
        double wrap_origin_x = 0.0;
        double wrap_period_x = 0.0;
        // 物理水域专用，不能使用 round 的 LAKE/SEA_ICE LUT。
        std::array<uint8_t, 4> water_terrain_ids{};
        uint8_t water_id_count = 0;
        bool enabled = false;
        // 就绪标记 + 诊断
        uint8_t ready = 0;
        char missing_key[48]{};
        bool validate(std::string &error) const;
    };
    ClimatePhysicsKnobs climate_physics_knobs;
    // 仅 legacy/cold bootstrap 使用；worker 接管后不再收回这些主线程解。
    std::vector<float> climate_physics_seed_slp;
    std::vector<float> climate_physics_seed_psi;
    std::vector<float> climate_physics_seed_upwelling;
    std::vector<float> cell_ocean_current_x;
    std::vector<float> cell_ocean_current_y;
    std::vector<float> cell_air_mass_temp_anomaly;
    std::vector<float> cell_ocean_thermal_anomaly;
    std::vector<float> cell_local_thermal_anomaly;
    std::vector<float> cell_temperature_transport_anomaly;
    std::vector<uint8_t> cell_ema_initialized;
    std::vector<float> cell_elevation;
    // weather field 的平流与几何缓存要用格子平面坐标。生产从 knobs 的 cell_pos
    // （PackedVector2Array）解交织出两条 float lane，快照这里直接存解好的两条。
    std::vector<float> cell_pos_x;
    std::vector<float> cell_pos_y;
    std::vector<float> cell_lat_norm;
    std::vector<float> cell_geometry_area;
    std::vector<float> cell_wind_band;
    std::vector<float> cell_ocean_heat_capacity;
    // Either CSR (neighbor_offsets + neighbor_indices) or the legacy fixed
    // six-neighbour layout may be supplied by the main-thread capture path.
    // Worker code consumes only the copied native vectors.
    std::vector<int32_t> neighbor_offsets;
    std::vector<int32_t> neighbor_indices;
    std::vector<int32_t> hydro_parent;
    std::vector<int32_t> province_ids;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> landform;
    std::vector<uint8_t> vegetation;
    std::vector<uint8_t> cover;
    std::vector<uint8_t> is_water;
    std::vector<uint8_t> has_river;
    std::vector<uint8_t> canal_edge_mask;
    std::vector<float> canal_water;
    std::vector<uint8_t> trade_passable_lut;
    std::vector<int32_t> trade_move_cost_lut;
    std::vector<uint8_t> visible;
    std::vector<uint8_t> military_base_landform;
    std::vector<uint8_t> military_settlement_tier;
    std::vector<float> building_resource_reserve;
    std::vector<float> building_resource_extra;
    // S3（断点 2 的解法）：生产 Climate round 的输入缓冲，由主线程 capture 时用
    // DCWorldExt::fill_climate_round_input 填充——与 async_climate_round_kick 走
    // 的是同一段提取代码。worker 拿到它之后直接调 runtime_climate_passes.h 里的
    // 共享纯内核，因此不再需要在 worker 侧维护第二套 pass 实现。
    //
    // n_cells == 0 表示这一帧没有携带 round 输入（旧 harness / 稀疏 fixture）。
    // 此时 worker 退回旧的诊断近似实现，并在 parity 报告里如实标注。
    pk_async_climate::ClimateInputBuf climate_round_input;
    // 这一天生产 stage_b 的 albedo 段跑没跑、用的什么标量。由 reference publish 如实
    // 填入（见 RuntimeClimateTrace::mark_reference_ready），worker 照此决定跑不跑
    // stage 8。它与 climate_round_ran 相互独立：albedo 走 stage_b 自己的 stride。
    pk_async_climate::ClimateAlbedoKnobs climate_albedo;
    // stage 10（climate_feedback）同理，但它需要的不只是标量：feedback 跑在 weather
    // 之后，而快照是 tick 起始拍的，weather_type / weather_intensity 在这两个时刻之间
    // 被 weather pass 整场重写过。所以生产必须整份留存它自己读到的 lane。
    //
    // shared_ptr 而不是内联结构：快照本身每天都会被克隆一次（mark_reference_ready），
    // 内联 7 条 per-cell lane 等于每天多拷 60 KB，而其中大多数天 feedback 根本没跑。
    // nullptr = 这一天生产没跑 feedback，worker 也不跑。
    std::shared_ptr<const pk_async_climate::ClimateFeedbackInput> climate_feedback;
    // stage 11 同理。它额外带七组跨 tick 状态的初值（ψ / 对流抑制 / 气旋强迫 /
    // 季风热力 / 轨迹表），worker 第一次跑 weather 时靠它播种。
    std::shared_ptr<const pk_async_climate::WeatherFieldInput> climate_weather;
    // stage 12 同理。它额外带运河拓扑代号，worker 的运河编译缓存按它失效。
    std::shared_ptr<const pk_async_climate::HydrologyInput> climate_hydrology;
    // weather distribute 同理。snow_cover / snowpack / cover 的当日最后一个写者。
    std::shared_ptr<const pk_async_climate::WeatherDistributeInput> climate_weather_distribute;
    // stage 9（vegetation_dynamics）同理，且更彻底：它读的 8 张查表来自 GDScript 的
    // vegetation catalog，worker 侧完全没有获取途径，只能整份随 reference 发布。
    // nullptr = 这一天生产没跑 vegetation_dynamics，worker 也不跑。
    std::shared_ptr<const pk_async_climate::VegetationDynamicsInput> climate_vegetation;
    // 生产这一天跑过哪些 Climate stage（1 << RuntimeClimateStage）。见
    // RuntimeClimateReferencePublish::production_stage_mask。worker 只读不写。
    int climate_production_stage_mask = 0;
    // 季末一次的反馈消费。见 RuntimeClimateReferencePublish::seasonal_feedback_ran。
    bool  climate_seasonal_feedback_ran = false;
    float climate_seasonal_feedback_decay = 1.0f;
    // 季末 season refresh 跑了没。为真时 worker 在当天 advance 之前把 moisture
    // 从 input 收回来——那一天 moisture 不是 worker 算的。
    bool  climate_season_refresh_ran = false;
    std::vector<float> season_growth_pressure;
    // Climate 是不是在 worker 手上（= 主线程那侧被抑制门整段关掉了）。
    //
    // 生产被抑制之后，凡是「由生产 pass 顺带记录、再随 reference publish 交给 worker」
    // 的东西都会静默停更。这个标志门控 worker 侧对这类缺口的补偿，目前有两处：
    //
    //   1. round scalars —— fill_climate_round_input 只填 per-cell lane，scalars 唯一
    //      的填充点是 run_climate_pass_a 里的 record_production_pass_a_scalars。
    //      ACTIVE 下 season_phase 因此停在默认 0.0，pass_a 每天按同一个季节相位算
    //      日照，温度场整年没有振幅。
    //   2. plant_available_water —— PAW 是 f(moisture, WB30, soil) 的纯派生量，
    //      ACTIVE 下从 input 播种等于读自己昨天回灌的那份（它在回灌表里，而 capture
    //      早于 _sus.tick()），闭环导致它只在 vegetation_dynamics 那几天动。
    //
    // 两处都必须门控而不能无条件做：SHADOW 下 round_in 来自 reference publish，
    // scalars 是生产记录的真值；PAW 也必须跟着生产每 48/49 天一次的节拍走。无条件
    // 补偿会让 parity 立刻分叉。
    //
    // 与 own_snow_state / own_field_state 是同一套「ACTIVE 下谁负责」的区分，只是那
    // 两条问的是跨天状态谁持有，这条问的是被抑制的记录谁补。
    bool  climate_worker_authoritative = false;
    std::vector<double> climate_capture_cursors; // CLM2 continuation, not a POD wire field.
    float climate_paw_water_balance_weight = 0.35f;
    float climate_paw_soil_buffer_weight = 0.25f;
    float climate_paw_drought_penalty = 0.65f;
    // 生产 Climate round 是按 stride 跑的，不是每日一轮（实测 60x40 下约每 10 日
    // 一轮）。worker 若每天都跑 pass_a，就会在生产没动的日子里单方面推进温度场——
    // 分叉矩阵会把这种节拍错位报成算法分叉。
    //
    // 默认 true = "照常跑"。只有 reference publish 才有资格按生产侧真实情况把它
    // 改成 false。默认取 false 会让任何没显式设过它的 fixture 静默变成整域 no-op，
    // 那种默认值的代价是测试全绿但什么都没算。
    bool climate_round_ran = true;
    // round 不变量（neighbor_indices / donor / foliage / albedo 表）。与 per-day
    // 输入分开，因为它只在 bind_map_data 之后变一次。
    pk_async_climate::ClimateRoundStaticKnobs climate_round_static_knobs;
};
// Frozen input manifest for the twelve-domain barrier.  This is deliberately
// numeric-only: it is safe to retain in the worker and in ECP2 without
// crossing the Godot/Object boundary.  A manifest is valid only for one
// effective day and one input generation.
struct RuntimeInputCaptureManifest {
    uint32_t abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    uint64_t session_epoch = 0;
    uint64_t input_generation = 0;
    int64_t effective_day = -1;
    uint64_t map_generation = 0;
    uint64_t country_generation = 0;
    uint64_t building_generation = 0;
    uint64_t resource_generation = 0;
    uint64_t catalog_hash = 0;
    uint64_t command_watermark = 0;
    uint64_t input_hash = 0;
    uint8_t frozen = 0;
    uint8_t validated = 0;
};

// Shared validation for the main-thread facade and the worker publish gate.
// This function is intentionally Godot-free so tests can exercise the exact
// boundary without constructing a DCWorldExt object.
bool validate_runtime_environment_snapshot(const RuntimeEnvironmentSnapshot &snapshot,
                                           std::string &error);
