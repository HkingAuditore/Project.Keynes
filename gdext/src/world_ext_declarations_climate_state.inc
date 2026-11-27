// Climate capture, solver scratch, and physical field caches.

    godot::Dictionary run_economy_slice_internal(const godot::Dictionary &ctx,
                                                  bool compact);
    void invalidate_economy_input_capture_cache(bool force_full);
    // ---- diag log toggle (Fix #11 second pass, 2026-06-16) ----
    bool _diag_logs_enabled = true;

    // ---- registry ----
    godot::Vector<Slot>                       _slots;
    godot::HashMap<godot::StringName, int>    _slot_by_name;

    // Exact input bits shared by synchronous and worker-round capture.
    std::vector<float> _insol_annual_mean_cache;
    std::vector<float> _insol_cache_latitudes;
    float _insol_cache_tilt = 0.0f;
    float _insol_cache_daylen = 0.0f;

    // ---- S3: sync run_climate_pass_a 的共享内核 scratch ------------------
    // run_climate_pass_a 不再自带第二份 pass-A 算法，而是把 _slots 快照进这两个
    // buffer 后调 pk_async_climate::_async_pass_a_kernel_pure —— 与 async round 和
    // SHADOW worker 完全同一份代码。buffer 常驻，避免每日 tick 重新分配 24 条列。
    pk_async_climate::ClimateInputBuf          _pass_a_sync_input_buf;
    pk_async_climate::ClimateOutputBuf         _pass_a_sync_output_buf;

    // run_transpiration_pass 同样已委派给 _async_transp_kernel_pure。
    pk_async_climate::ClimateInputBuf          _transp_sync_input_buf;
    pk_async_climate::ClimateOutputBuf         _transp_sync_output_buf;
    pk_async_climate::ClimateWorkBuf           _transp_sync_work_buf;

    // ---- S3: 生产 round 输入的所有权 --------------------------------------
    // 本 reference 周期内生产 pass_a 实际用过的输入缓冲。publish reference 时交给
    // trace 帧，让 worker 跑的是"生产这一天真的跑了 round、且用的就是这份输入"。
    // 空 shared_ptr = 这一天生产没跑 round（round 走 stride，不是每日一轮），
    // worker 据此整段跳过 Climate；否则它会在生产没动的日子里单方面推进温度场。
    std::shared_ptr<const pk_async_climate::ClimateInputBuf> _production_round_input;
    // 生产各 sync pass 真实用过的标量。pass_a 的那一份在 _production_round_input 里，
    // 其余 6 个 pass 没有 ClimateInputBuf 可留存（它们直接从 knobs Dictionary 读、写
    // slot），所以这里单独攒一份：每个 pass 跑到时把自己那段标量写进来，publish 时随
    // reference 一起发布。
    //
    // 为什么必须这么做：SHADOW capture 侧的 round input 依赖 ClimateDailySystem，而
    // native_daily 路径下它根本没注册，于是 pb_/ow_/ol_/wa_/ws_/si_ 这些标量在 worker
    // 侧全是 ClimateRoundScalars 的结构默认值 —— worker 跑的是同一份内核，但吃的是不同
    // 的 knobs，分叉矩阵会把它报成算法分叉。
    pk_async_climate::ClimateRoundScalars _production_round_scalars;
    // 哪几段标量这一轮真的被生产写过（bit 位与 passes_mask 一致）。没写过的段不参与
    // overlay —— 否则会把"生产这天没跑这个 pass"写成"用默认 knobs 跑过"。
    int _production_round_scalar_mask = 0;
    // wind_air 的 baseline_arr 与风场回溯轨迹表。两者都不是 slot：baseline 是
    // GDScript 按 map 缓存的静态数组、由 knobs 传入，轨迹表是物理风场的派生量且
    // 带指纹校验。capture 侧都取不到，所以在生产跑 wind_air 时照抄一份，publish
    // 时随 reference 发布。ran 由 n_cells > 0 表示；publish 后复位。
    std::shared_ptr<const pk_async_climate::WindAirInput> _production_wind_air;
    // pass_b 的海冰浓度 lane（生产从 MapData 镜像取，既不是 slot 也不在 pass_a 的
    // kin 里）。见 ClimatePassBInput 的注释：缺它会让水格的 LANOM 停在 0。
    std::shared_ptr<const pk_async_climate::ClimatePassBInput> _production_pass_b;
    // sea_ice 的温度 lane（同上，非 slot）。
    std::shared_ptr<const pk_async_climate::SeaIceInput> _production_sea_ice;
    // wind_surface 读到的 oanom（同上，非 worker 权威）。
    std::shared_ptr<const pk_async_climate::WindSurfaceInput> _production_wind_surface;
    std::shared_ptr<const pk_async_climate::OceanWaterInput> _production_ocean_water;
    // 同理，但针对 albedo：它跑在 native daily graph 的 stage_b 段、用自己的 stride，
    // 与 climate round 不同步。ran=false（默认）即"这一天生产没跑 albedo"。publish 后
    // 复位，下一天必须由新的一次 albedo 段重新置位。
    pk_async_climate::ClimateAlbedoKnobs _production_albedo;
    // stage 10 同理，但它需要的不只是标量：feedback 读的 weather lane 与 tick 起始的
    // 快照不是一份，所以整份输入都得留存。shared_ptr 是因为 publish 之后 worker 线程
    // 还要持有它，而主线程下一天就会覆盖这个成员。
    std::shared_ptr<const pk_async_climate::ClimateFeedbackInput> _production_feedback;
    // stage 11 同理。它是 round 内最后一批写者之一，且带七组跨 tick 状态的初值。
    std::shared_ptr<const pk_async_climate::WeatherFieldInput> _production_weather;
    // stage 12 同理。
    std::shared_ptr<const pk_async_climate::HydrologyInput> _production_hydrology;
    // weather distribute 同理。
    std::shared_ptr<const pk_async_climate::WeatherDistributeInput> _production_weather_distribute;
    // stage 9 同理。它比 feedback 更必须整份留存：8 张查表来自 GDScript catalog，
    // worker 侧根本没有获取途径。
    std::shared_ptr<const pk_async_climate::VegetationDynamicsInput> _production_vegetation;
    // 生产这一天跑过哪些 Climate stage（1 << RuntimeClimateStage）。对尚未提取成共享
    // 内核的 stage 也照实置位 —— 分叉矩阵里 stage 9..13 的字段有两种可能成因（worker
    // 缺实现 / 生产这天本来也没跑），只有这个掩码能把它们分开。publish 后复位。
    //
    // 实测这件事很重要：stage_b 的三个子 stride（albedo 10 / vegetation 5 /
    // feedback 10）是按 weather 调用次数计的，而 weather 自己还有 bucket stride，
    // 于是 30 日窗口里 feedback 一次都不会触发。
    int _production_stage_mask = 0;
    // 季末反馈消费（map_generator.gd::_consume_feedback_buffers）。它是纯 GDScript
    // pass，不经过任何 record_production_* 路径，所以只能由 GDScript 主动报进来。
    bool  _production_seasonal_feedback_ran = false;
    float _production_seasonal_feedback_decay = 1.0f;
    bool  _production_season_refresh_ran = false;
    // 节拍诊断：配错一天会表现成"算法分叉"，所以前若干天照实打出 round_ran。
    int _publish_cadence_reports_left = 34;
    // 生产自增量诊断：上一次 publish 的 reference。round_ran=0 且 stage mask=0x0 的
    // 那一天，如果 reference 相对前一天变了，就证明存在 14 stage 之外的写者（例如
    // native daily finalizer）。这比反推分叉矩阵直接得多，且不依赖任何猜测。
    std::shared_ptr<const RuntimeClimateStore> _last_published_climate_reference;

    // ---- S3: pass_a 输出 → reference 边界诊断 -----------------------------
    // 输入侧对齐之后，剩下的可能性是 reference 不等于 pass_a 的输出（同一 tick 里
    // 有更晚的 pass 覆写了这几条 MapData 数组）。这里留存本 tick pass_a 写出的 4 条
    // 场，publish reference 时比一次。
    std::vector<float>                         _pass_a_last_temp_baseline;
    std::vector<float>                         _pass_a_last_thermal_energy;
    std::vector<float>                         _pass_a_last_temp_30d;
    std::vector<float>                         _pass_a_last_temp_365d;
    int                                        _pass_a_reference_boundary_reports_left = 4;

    // ---- SLP lat-LUT annual-mean sub-cache (perf 2026-07-05, Item 5) ----
    // run_slp_field_pass 每 pass 按 ny 预建 LUT_BINS 档 lut_solar_heat，其中
    // dc_insolation_annual_mean(ny_b, axial_tilt, daylen)（16×9 trig/bin）与 season 无关，
    // 每 pass 重算纯属冗余。缓存该年均 LUT，指纹 = FNV-1a(LUT_BINS, axial_tilt bits,
    // daylen bits)。insol_now / solar_dev / base_lat 仍每 pass 重建（season-dependent）。
    // 命中即逐位复用存储值 → bit-equal；仅在 bins/planet 常数变化时重建（≈一次）。
    std::vector<float>                        _slp_insol_mean_lut;
    uint64_t                                  _slp_insol_mean_lut_fp = 0;
    bool                                      _slp_insol_mean_lut_valid = false;

    // ---- PSI water-topology cache (perf 2026-07-05, Item 6) ----
    // run_psi_solver_pass 每 tick 重建 cell_to_water / water_to_cell / nb_w（水域邻接
    // 域内索引），这三者纯由水掩膜(TR+water_ids)与邻接表(NB)决定，与风/温度无关，故对
    // 静态地图逐 tick 恒等。海冰是独立 cell_sea_ice_frac F32 slot，**不改 terrain id**，
    // 所以水掩膜生成后即静态。缓存拓扑，指纹 = FNV-1a(n_cells, water_ids, 全 TR 字节,
    // 全 NB 整型) —— 自校验：地形或邻接一旦变化指纹即失配、自动重建，无需外部失效钩子。
    // 命中即逐位复用 → nb_w/water_to_cell/cell_to_water bit-identical。仅在 map regen /
    // 地形 flip 时重建（≈生成期一次）。主线程同步调用，成员存储线程安全。
    std::vector<int>                          _psi_cell_to_water;
    std::vector<int>                          _psi_water_to_cell;
    std::vector<int>                          _psi_nb_w;
    int                                       _psi_topo_n_water = 0;
    uint64_t                                  _psi_topo_fp = 0;
    bool                                      _psi_topo_valid = false;

    // ---- phys pass 每调用固定开销缓存 (perf 2026-07-08, Item 1) ----
    // run_slp_field_pass / run_wind_field_pass / run_psi_solver_pass /
    // run_physical_circulation_pass 每个调用都会 component_id(StringName("cell_*"))
    // 解析 7~13 次 slot id + 重建 256 字节 is_water_lut + 解包 neighbor_indices，
    // 这部分与 cell 内容无关、对静态地图逐调用恒等。统一在此缓存，指纹 =
    // FNV-1a(n_cells, water_ids) —— 地图 regen / 水掩膜变化即失配自动重建，不挂 _bound 钩子。
    // 命中后四个 pass 直接用成员，省掉重复 StringName 解析与 LUT 重建。
    // 注意：neighbor_indices 仍由 knob 传入（保留 fallback 路径），此处只缓存 slot id + LUT。
    int _phys_sid_pos_x = -1, _phys_sid_pos_y = -1, _phys_sid_terrain = -1;
    // 纬度归一化权威（与 world_ext_climate.cpp 同源）。物理 pass 曾用
    // (cell_pos_y - world_bounds_pos_y)/world_bounds_size_y 自行重算 ny，两者单位不同
    // 导致全图恒为极地；详见 world_ext_physical.cpp::phys_make_lat_norm 注释。
    int _phys_sid_lat_norm = -1;
    int _phys_sid_landform = -1;
    int _phys_sid_wind_x = -1, _phys_sid_wind_y = -1, _phys_sid_wind_spd = -1;
    int _phys_sid_slp = -1;
    int _phys_sid_temp = -1, _phys_sid_temp_an = -1;
    int _phys_sid_snow = -1, _phys_sid_ice = -1;
    int _phys_sid_wvap = -1, _phys_sid_wcld = -1;
    int _phys_sid_ocx = -1, _phys_sid_ocy = -1, _phys_sid_psi_prev = -1;
    int _phys_sid_upwelling = -1;
    int _phys_sid_elev = -1;  // NS 化 Phase 4:洋流深度耦合/地形转向读 elevation slot
    bool     _phys_is_water_lut[256];
    uint64_t _phys_static_fp = 0;
    bool     _phys_static_valid = false;

    // ---- phys pass cell-range 切片缓存 (perf 2026-07-08, Item 2) ----
    // SLP Pass A 结果跨切片累加的持久 buffer；Pass B 平滑 + recenter/p95/融合/发布
    // 只在末切片(end_idx==n_cells)对完整 buffer 跑一次 → 切片开启仍逐位等价全量 pass。
    // 大小随 n_cells 变化（无指纹，size 失配即 resize；solve 内被 Pass A 全量覆盖）。
    std::vector<float> _phys_slp_buf;
    // SLP thermal_abs（仅在 A_LAND/THERMAL_WEIGHT/ICE/SNOW 权重非 0 时填充；用于末切片
    // slp_thermal_p95 诊断）。同样持久化，使切片开启时末切片统计基于完整场而非末切片局部。
    std::vector<float> _phys_slp_thermal_abs;
    // WIND coast/sea BFS 结果缓存（指纹 = FNV(TR 字节 + water_ids + NB 整型)，
    // 地图静态恒等；与 _psi_topo 同套路，主线程同步调用、成员存储线程安全）。
    // 命中即 coast_dist/sea_dist 等逐位复用，免去每切片重建 BFS（≈地图期一次）。
    std::vector<int8_t>  _phys_wind_coast_dist;
    std::vector<float>   _phys_wind_coast_sea_x;
    std::vector<float>   _phys_wind_coast_sea_y;
    std::vector<int32_t> _phys_wind_coast_sea_anchor;
    std::vector<int8_t>  _phys_wind_sea_dist;
    std::vector<float>   _phys_wind_sea_land_x;
    std::vector<float>   _phys_wind_sea_land_y;
    std::vector<int32_t> _phys_wind_sea_land_anchor;
    // Signed, normalized land-minus-sea contrast sampled by the physical wind
    // pass.  Weather reads it as derived scratch for WT_MONSOON classification.
    std::vector<float>   _phys_monsoon_thermal;
    uint64_t _phys_wind_coast_fp = 0;
    bool     _phys_wind_coast_valid = false;
    double   _phys_wind_coast_build_ms = 0.0;
    bool     _phys_wind_coast_last_hit = false;
    int      _monsoon_eligible_cells = 0;
    int      _monsoon_onshore_cells = 0;
    int      _monsoon_offshore_cells = 0;
    float    _monsoon_contrast_abs_max = 0.0f;

    // Low-order ENSO modes. Basin topology and per-cell forcing are derived
    // caches; only EnsoBasinState is authoritative and serialized.
    struct EnsoBasinMeta {
        uint64_t signature = 0;
        int member_begin = 0;
        int member_count = 0;
        float span_x = 0.0f;
    };
    struct EnsoBasinState {
        uint64_t signature = 0;
        float temp_index = 0.0f;
        float recharge_index = 0.0f;
        float wind_ema = 0.0f;
        float wind_anomaly = 0.0f;
        int64_t last_update_tick = -1;
    };
    std::vector<int8_t> _enso_basin_id;
    std::vector<float> _enso_eastness;
    std::vector<float> _enso_prev_forcing;
    std::vector<int32_t> _enso_members;
    std::vector<EnsoBasinMeta> _enso_basins;
    std::vector<EnsoBasinState> _enso_states;
    std::vector<double> _enso_wind_sum;
    std::vector<int32_t> _enso_wind_count;
    uint64_t _enso_cache_fp = 0;
    bool _enso_cache_valid = false;
    bool _enso_cache_last_hit = false;
    double _enso_cache_build_ms = 0.0;
    godot::Dictionary _climate_modes_pending_restore;

    // ---- NS 化:风场回溯轨迹表缓存(Phase 0, plan/NS化气候动力学四方向深化) ----
    // 半拉格朗日几何缓存:每 cell 回溯终点所在三角形 (i0=self宿主, i1, i2) +
    // 重心权重 (w0,w1,w2),共 24B/cell(110k 格约 2.6MB)。wind pass 末由最终风槽
    // 构建;指纹 = pk_wind_state_fp(n_cells, WX, WY, WSP) 64 降采样。消费端
    // (weather field solve / wind_air) 复算指纹比对,失配落旧 hopping 并
    // _phys_wind_traj_stale_count++ 上报。派生 scratch,不占 component slot。
    std::vector<int32_t> _phys_wind_traj_idx;  // n*3
    std::vector<float>   _phys_wind_traj_w;    // n*3
    uint64_t _phys_wind_traj_fp = 0;
    uint32_t _phys_wind_traj_gen = 0;          // 构建代数(每次成功构建递增)
    bool     _phys_wind_traj_valid = false;
    bool     _phys_wind_traj_consume_enabled = true;  // knob wind_traj_weather_share
    int      _phys_wind_traj_stale_count = 0;
    // 动量旧通量快照(成员化):切片执行时由首切片(start_idx==0)重建、后续切片
    // 复用 → 切片==全量逐位一致(若每切片各拍,前序切片写回会污染后续邻居旧值)。
    std::vector<float> _phys_wind_snap_fx;  // n
    std::vector<float> _phys_wind_snap_fy;  // n
