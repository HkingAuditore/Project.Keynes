// Temperature and wind kernels and weather field publication inputs.

// ─── stage 1 PASS_B ────────────────────────────────────────────────────────
//
// 生产 run_climate_pass_b 与 worker _async_pass_b_kernel_pure 曾是两份独立实现，
// 逐行比对只差一处：worker 多了一个 cover == GLACIER 时把 snow_cover 抬到 0.80 的
// 钳位。生产 pass_b 没有这一步（albedo pass 与 weather_distribute 有，大概是照它们
// 补的），于是 d_albedo → LANOM → t_eff → d_evap → moisture 整条链偏移，moisture
// 在分叉矩阵里挂着 0.78 的最大差。两份实现合成一个内核就是为了让这种"抄漏一行"
// 不再可能。
struct ClimatePassBKnobs {
    int    n_cells = 0;
    float  winter_boost = 0.0f;
    float  snow_cool = 0.0f;
    float  veg_cool = 0.0f;
    float  diurnal_amp = 0.0f;
    float  evap_gain = 0.0f;
    float  rs_threshold = 0.0f;
    float  rs_factor = 0.0f;
    int    rs_lookback = 0;
    double wrap_period_x = 0.0;
    float  t_freeze = 0.0f;
    float  coupling_gain = 0.0f;
    float  coast_leak = 0.0f;
    // 0 = 关闭海冰反照率→温度反馈尾循环。
    float  sea_ice_albedo_cooling = 0.0f;
    double season_phase = 0.0;
    float  snowpack_cover_low = 0.05f;
    float  snowpack_cover_full = 0.32f;
    int    foliage_size = 0;
};

struct ClimatePassBLanes {
    // temp 快照：pass_b 不写 cell_temp，改累加 local_thermal_anomaly，由
    // wind_surface 末端合成回温度。d_albedo / d_coastal / d_landform 都以这份
    // 快照为基准，所以它必须是写入发生【之前】的那一份。
    const float   *temp_snapshot = nullptr;
    const float   *snowpack = nullptr;
    const float   *elevation = nullptr;
    const float   *lat_norm = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const float   *insolation_dev = nullptr;
    const float   *temp_transport_anomaly = nullptr;
    const uint8_t *is_water = nullptr;
    const uint8_t *landform = nullptr;
    const uint8_t *vegetation = nullptr;
    // 可为 nullptr：此时跳过海冰反照率尾循环。
    const float   *sea_ice_frac = nullptr;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6
    const float   *foliage_table = nullptr;      // size = knobs.foliage_size

    // in/out
    float *local_thermal_anomaly = nullptr;
    float *moisture = nullptr;
};

// 整图一次调用：跳过水域跑主循环，再跑海冰尾循环。
void climate_pass_b_pure(const ClimatePassBKnobs &knobs,
                         const ClimatePassBLanes &lanes);

// 分块驱动，供生产 _thread / _simd 变体按预筛 land_idx 切分。雨影段沿风向逐步回溯
// 上风格（rs_lookback 步），只读邻居，逐 cell 独立，所以可安全并行。
void climate_pass_b_land_range_pure(const ClimatePassBKnobs &knobs,
                                    const ClimatePassBLanes &lanes,
                                    const int *land_idx,
                                    int begin, int end);

// 海冰反照率→水域 LANOM 尾循环。必须在主循环全部写完之后跑。
void climate_pass_b_sea_ice_tail_pure(const ClimatePassBKnobs &knobs,
                                      const ClimatePassBLanes &lanes);

// ─── stage 4 WIND_AIR / stage 5 WIND_SURFACE ──────────────────────────────
//
// 这两个 pass 是 climate round 里温度链条的收尾：wind_air 算出 air-mass
// anomaly，wind_surface 把 baseline + transport(ocean + air) + local anomaly
// 合成回 cell_temp——它是 round 内 cell_temp 的唯一写者。
//
// 它们此前各有两份实现。wind_surface 的两份主循环恰好逐位相同（纯属运气），
// wind_air 的两份不同：
//   1. 生产在风场轨迹表命中时用三点重心插值取上游温度，worker 那份只有离散
//      跳格分支，永远走 fallback；
//   2. 生产对 temp_self / temp_up 各有 isfinite 兜底回 baseline，worker 那份
//      直接取原值；
//   3. 生产的 baseline_arr 是 GDScript 传进来的 _compute_temperature(lat, elev)
//      静态基线，worker 那份读的是 temp_baseline_year。
// 三条叠起来让 air_anomaly 偏，wind_surface 再把偏差合成进 cell_temp，于是
// temperature 成为分叉矩阵里第一个红的字段。合成一个内核就是让这三条不可能
// 再各自漂移。
struct WindAirKnobs {
    int   n_cells = 0;
    int   advect_steps = 0;
    float heat_mix = 0.0f;
    float wrap_period_x = 0.0f;
};

struct WindAirLanes {
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    // 生产的 TB：read_temp_from_slot 时是 cell_temp slot，否则是 temp_before_arr。
    // round 内只有 wind_surface 写 cell_temp，且它在 wind_air 之后，所以两者同值。
    const float   *temp_before = nullptr;
    // 生产的 baseline_arr = _compute_temperature(lat_norm, elevation)，按 map 缓存。
    const float   *baseline = nullptr;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6
    // 轨迹表：命中时用三点重心插值取上游温度。两者同时非空才生效，否则走离散
    // 跳格。风场派生量且带指纹校验，worker 无法重建，必须照抄生产当天用过的。
    const int32_t *traj_idx = nullptr;           // [n_cells * 3]
    const float   *traj_w = nullptr;             // [n_cells * 3]

    float *air_anomaly = nullptr;                // 纯输出，逐 cell 先清零
};

// [start_idx, end_idx) 区间版；生产分片调用，worker 一次跑全图。
void wind_air_pure(const WindAirKnobs &knobs, const WindAirLanes &lanes,
                   int start_idx, int end_idx);

struct WindSurfaceKnobs {
    int   n_cells = 0;
    float air_leak = 0.0f;
    float wrap_period_x = 0.0f;
    float cold_transport_form = 0.06f;
    float cold_transport_melt = 0.11f;
};

struct WindSurfaceLanes {
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const uint8_t *is_water = nullptr;
    // 合成的三个来源。baseline 非有限时回退到 fallback_baseline。
    const float   *baseline = nullptr;
    const float   *fallback_baseline = nullptr;
    // 可为 nullptr：此时 ocean 项按 0 计（本 round 没跑 ocean pass）。
    const float   *ocean_anomaly = nullptr;
    const float   *local_anomaly = nullptr;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6
    // air anomaly 必须是 Jacobi 读：邻居读的是本 pass 之前的整套旧值。生产用
    // arr.duplicate() 做快照，调用方须保证 air_anomaly_in 与 out 不是同一块。
    const float   *air_anomaly_in = nullptr;

    float *air_anomaly_out = nullptr;
    float *temp_out = nullptr;
};

void wind_surface_pure(const WindSurfaceKnobs &knobs,
                       const WindSurfaceLanes &lanes,
                       int start_idx, int end_idx);

// ─── stage 11 中段：weather field commit ───────────────────────────────────
//
// 生产的 weather stage 是两步的：weather_advance 把结果解算进调用方给的 next
// buffer（use_next_outputs = true，weather_type 写 int32），随后 weather_commit
// 把 next 落到 slot，并在这一步才解析 display_type / prev_type / target_type /
// alpha / field_init / dirty / LUT。
//
// worker 此前硬编码 use_next_outputs = false，走的是同一个 solve 内核的 direct
// 分支——那条分支里 transition 三条与 field_init 由 solve 自己写。两边因此在同
// 一个 stage 上跑了不同分支，worker 侧 weather_target_type /
// weather_transition_alpha / precipitation / intensity / cloud 成片写出字面零。
// 把 commit 也提成共享内核，worker 才能跟生产走同一条 staged 路径。
struct WeatherCommitKnobs {
    int   n_cells = 0;
    bool  refresh_convergence = false;
    bool  weather_transition_enabled = false;
    // 均已 clamp：rate [0,1]，dt_days [0,30]。
    float transition_rate = 1.0f;
    float transition_dt_days = 1.0f;
    // LUT 槽位数，>= n_cells；lut 为 nullptr 时忽略。
    int   lut_slots = 0;
};

struct WeatherCommitLanes {
    // solve 写出的 next buffer（只读）
    const float   *next_vapor = nullptr;
    const float   *next_cloud = nullptr;
    // 可为 nullptr：此时按 next_cloud * 0.5 推断，与生产一致。
    const float   *next_cloud_water = nullptr;
    const float   *next_precip = nullptr;
    const float   *next_instability = nullptr;
    const float   *next_intensity = nullptr;
    const float   *next_convergence = nullptr;
    const int32_t *next_type = nullptr;
    // solve 之前的 vapor，用于水量收支误差
    const float   *prev_vapor = nullptr;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6

    // slot 侧 in/out：先被读作"上一 tick 的展示态"，再被覆写
    float   *intensity = nullptr;
    float   *cloud = nullptr;
    float   *cloud_water = nullptr;          // 可为 nullptr
    float   *precip = nullptr;
    float   *vapor = nullptr;
    float   *convergence = nullptr;
    float   *instability = nullptr;
    uint8_t *type = nullptr;
    uint8_t *prev_type = nullptr;            // transition 关时可为 nullptr
    uint8_t *target_type = nullptr;          // 同上
    float   *transition_alpha = nullptr;     // 同上
    uint8_t *field_init = nullptr;
    uint8_t *dirty = nullptr;

    // 纯输出，可为 nullptr
    uint8_t *lut = nullptr;                  // lut_slots * 4
    float   *convergence_deltas = nullptr;   // 容量 n_cells，按 dirty 计数紧凑写
};

struct WeatherCommitStats {
    int    dirty_count = 0;
    int    convergence_dirty_count = 0;
    double water_budget_error_sum = 0.0;   // 调用方自行除以 n_cells
};

// 整图一次调用：dirty 会向 6 邻居扩散，逐 cell 之间有写交叉，不切片。
void weather_commit_pure(const WeatherCommitKnobs &knobs,
                         const WeatherCommitLanes &lanes,
                         WeatherCommitStats &stats);

// ─── stage 11 后段：weather distribute ─────────────────────────────────────
//
// 它是 snow_cover / snowpack / cover 当天的最后一个写者，而 sea_ice 与 albedo 都读
// snow_cover。分叉矩阵曾把 snow_cover 挂在 SEA_ICE 上，于是这一个缺口在矩阵里长成了
// 三行"算法分叉"（snow_cover / sea_ice / temperature）。
struct WeatherDistributeKnobs {
    int   n_cells = 0;
    float snow_min_intensity = 0.0f;
    float snow_freeze_t = 0.0f;
    float snow_melt_t = 0.0f;
    float snow_intensity_snow = 0.0f;
    int   snow_accum_days_req = 0;
    float flood_heavy_int = 0.0f;
    float flood_heavy_pre = 0.0f;
    float flood_low_int = 0.0f;
    float flood_low_elev = 0.0f;
    float flood_low_moist = 0.0f;
    int   wt_clear = 0;
    int   cv_snow = 0;
    int   cv_none = 0;
    int   cv_flooding = 0;
    float snowpack_accum_gain = 0.10f;
    float snowpack_melt_temp_gain = 0.22f;
    float snowpack_melt_sun_gain = 0.12f;
    float snowpack_cover_low = 0.05f;
    float snowpack_cover_full = 0.32f;
    // threshold = 0 关闭气候态物理雪线 floor。
    float snowline_temp_threshold = 0.24f;
    float snowline_band = 0.22f;
    float weather_temp_anomaly_cap = 0.025f;
    bool  direct_moisture_enabled = false;
    // 按 WeatherType 枚举索引的四张 8 项剖面表。
    float   temp_delta[8]{};
    float   moist_delta[8]{};
    uint8_t can_form_snow[8]{};
    uint8_t can_form_flood[8]{};
};

struct WeatherDistributeLanes {
    // 读写
    float   *temp = nullptr;
    float   *moisture = nullptr;              // 仅 direct_moisture_enabled 时写
    float   *snow_cover = nullptr;
    float   *snowpack = nullptr;
    float   *water_balance_30d = nullptr;
    float   *soil_moisture = nullptr;
    uint8_t *cover = nullptr;
    // 只读
    const float   *heat = nullptr;
    const float   *elevation = nullptr;
    const uint8_t *landform = nullptr;
    const uint8_t *terrain = nullptr;
    const float   *weather_intensity = nullptr;
    const float   *weather_precip = nullptr;
    const uint8_t *weather_type = nullptr;
    const uint8_t *weather_field_init = nullptr;
};

// 积雪连续天数与被雪覆盖前的 cover。两条都是 in/out 的跨 tick 状态，生产侧由
// GDScript 持有并经 knobs 往返，所以不在任何 slot 里，也不是 store 成员。
struct WeatherDistributeState {
    int32_t *accumulated_snow_days = nullptr;
    int32_t *pre_snow_cover = nullptr;
};

struct WeatherDistributeEmit {
    std::vector<int32_t> changed_cells;
    bool cover_dirty = false;
};

// 逐 cell 独立（只写 lanes.*[i] 与 state.*[i]），但 emit.changed_cells 的追加顺序
// 必须是升序 cell —— 下游把它当有序集合用。所以不暴露 range 版本。
void weather_distribute_pure(const WeatherDistributeKnobs &knobs,
                             const WeatherDistributeLanes &lanes,
                             const WeatherDistributeState &state,
                             WeatherDistributeEmit &emit);

// 生产 weather distribute 当天真正读到的输入，供 worker 对拍。
struct WeatherDistributeInput {
    WeatherDistributeKnobs knobs;
    int  n_cells = 0;
    bool ran = false;

    std::vector<float>   heat;
    std::vector<float>   elevation;
    std::vector<uint8_t> landform;
    std::vector<uint8_t> terrain;
    std::vector<float>   weather_intensity;
    std::vector<float>   weather_precip;
    std::vector<uint8_t> weather_type;
    std::vector<uint8_t> weather_field_init;
    // 没有 store 成员承接的 in/out：cover 与两条积雪计数。记初值、worker 用 scratch。
    std::vector<uint8_t> cover;
    std::vector<int32_t> accumulated_snow_days;
    std::vector<int32_t> pre_snow_cover;
    std::vector<float>   soil_moisture;
    // 两条积雪计数由谁跨天持有。
    //
    // SHADOW（record_production_* 填这份输入）留 false：那时生产是权威写者，
    // worker 每天跟着它播种，才是在对拍同一条状态链；自持会让两边从第一天就
    // 各走一条积雪账，parity 把它报成算法分叉。
    //
    // ACTIVE（capture 填这份输入）置 true：这两条没有 SoA 镜像（HexCell 的 AoS
    // 字段，不在 component_schema 里），既不在 environment 快照里也不经回灌回到
    // MapData，而生产 distribute 正是被抑制的那一方 —— 它那份缓存不再推进，
    // 每天拿它播种会让 snow_accum_days_req 永远攒不满。
    bool own_snow_state = false;
};
