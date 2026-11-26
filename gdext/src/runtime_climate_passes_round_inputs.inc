// Round wind, ice, and finalizer input and kernel declarations.

// wind_air 的两样东西无法从 slot 快照里取，只能由生产那一侧在跑 pass 时记下来：
//   baseline —— GDScript 按 map 缓存的 _compute_temperature(lat, elev) 静态基线，
//               不是任何一条 slot，也不等于 temp_baseline_year；
//   traj_*  —— 物理风场派生的回溯轨迹表，带指纹校验，worker 重建不出同一份。
// 生产没命中轨迹表时 traj_* 为空，worker 一并走离散跳格分支。
struct WindAirInput {
    int                  n_cells = 0;
    std::vector<float>   baseline;
    std::vector<int32_t> traj_idx;   // 空 或 [n_cells * 3]
    std::vector<float>   traj_w;     // 空 或 [n_cells * 3]
    // 风场本身也要照抄。它是 slot 产物，但 physics 的解算是跨 tick 分片的，capture
    // 抓快照的时刻与生产 wind_air 真正读 slot 的时刻不在同一片上 —— 于是两边拿到
    // 的是同一个 tick 内风向略有旋转的两份值。差得极小，却足以让整条温度链条不
    // 逐位相等。
    std::vector<float>   wind_x;
    std::vector<float>   wind_y;
    std::vector<float>   wind_speed;
};

void overlay_production_wind_air(ClimateInputBuf &base, const WindAirInput &prod);

// pass_b 的海冰浓度 lane。生产从 map.sea_ice_frac_arr（MapData 镜像）取，它既不在
// slot 覆盖清单里，也不在 pass_a 留存的那份 kin 里，于是 worker 侧一直是空的。
// 空 lane 让 pass_b 的水域尾循环整段静默跳过 —— 而那是水格唯一的 LANOM 来源
// （主循环 `if (is_water) continue`）。后果是每个水格的 local anomaly 停在 0，
// wind_surface 合成出的 cell_temp 随之偏，temperature 因此成为分叉矩阵里第一个
// 红的字段。pass_b 的守卫清单不含这条 lane，所以它连 starve 都不会报。
struct ClimatePassBInput {
    int                n_cells = 0;
    std::vector<float> sea_ice_frac;
    // TTA 同理且更隐蔽：它根本不是 slot，而是
    // knobs["temp_transport_anomaly"] —— GDScript 从
    // map.temperature_transport_anomaly_arr 传入，而那份数组由**分片的**
    // ocean pass 逐片增量写（map_generator.gd:16651）。所以它与 oanom 一样不属于
    // worker：pass_b 的 d_coastal / d_evap 两项都读邻居的 TTA，读错就会让 LANOM 偏，
    // 进而沿 wind_surface → temperature 一路传下去。
    std::vector<float> temp_transport_anomaly;
};

void overlay_production_pass_b(ClimateInputBuf &base, const ClimatePassBInput &prod);

// ─── stage 0x40 SEA_ICE ───────────────────────────────────────────────────
//
// worker 的 _async_sea_ice_kernel_pure 是 2026-06-16 那版算法的抄本：单步推进
// `d_frac = clamp(rate) * dt_days`，solar_melt 用 prev_frac 算一次遮蔽。生产在
// 2026-06-28 换成了按日子步积分（n_sub = ceil(dt_days)，每步重算 solar_exposure
// 并在饱和时提前 break），worker 没跟上。dt_days == 1 时两者逐位等价，所以这个
// 漂移只在加速档下暴露 —— 正是最难在对拍里稳定复现的那一类。合成一个内核之后
// 这种"生产改了、抄本没改"的错位不再可能。
struct SeaIceKnobs {
    int   n_cells = 0;
    float k_freeze = 0.0f;
    float k_melt = 0.0f;
    float t_form = 0.0f;
    float t_melt = 0.0f;
    float contagion = 0.0f;
    float threshold = 0.0f;
    float hysteresis = 0.0f;
    float ice_delay = 0.0f;
    bool  enable_ocean_heat_transport = false;
    bool  solar_gate_enabled = false;
    float freeze_insol_low = 0.0f;
    float freeze_insol_high = 0.0f;
    float solar_melt_start = 0.0f;
    float solar_melt_gain = 0.0f;
    float min_thick_ice_solar_exposure = 0.32f;
    float daily_delta_cap = 0.070f;
    // 未 clamp 传入即可：内核自己按 [0, 0.20] / [0, 30] 收口，两边同一份收口逻辑。
    float edge_mix_rate = 0.035f;
    float dt_days = 1.0f;
    int   terrain_lake_id = -1;
    int   terrain_sea_ice_id = -1;
    int   terrain_ocean_id = -1;
};

struct SeaIceLanes {
    // 生产读的是 cell_terrain slot；翻转由调用方在拿到 emit 之后自己落，内核只读。
    const uint8_t *terrain = nullptr;
    const uint8_t *base_terrain = nullptr;
    // 注意不是 cell_temp slot：生产刻意从 GDScript 的 cell.temperature 打包传入，
    // 与 SoA cell_temp（ocean_land 之后的修正温度）不是同一个量。读错会多算冰。
    const float   *cell_temperature = nullptr;
    const float   *temp_transport_anomaly = nullptr;
    const float   *ocean_thermal_anomaly = nullptr;
    const float   *upwelling_strength = nullptr;
    const float   *insolation_now = nullptr;
    const uint8_t *water_terrain_ids = nullptr;
    int            water_terrain_ids_size = 0;
    const int32_t *neighbor_indices = nullptr;   // size >= n_cells * 6

    // in/out
    float *sea_ice_frac = nullptr;
};

struct SeaIceEmit {
    std::vector<int32_t> flip_to_ice;
    std::vector<int32_t> flip_to_base;
    std::vector<uint8_t> flip_to_base_terrain;
    int water_count = 0;
    int flipped_count = 0;
};

// 复用的临时 buffer；worker 侧按 round 常驻，生产侧每次现开也无妨。
struct SeaIceScratch {
    std::vector<uint8_t> has_cold_neighbor;
    std::vector<float>   prev_sif;
};

void sea_ice_pure(const SeaIceKnobs &knobs,
                  const SeaIceLanes &lanes,
                  SeaIceScratch &scratch,
                  SeaIceEmit &emit);

// sea_ice 的温度 lane 同样不是 slot 产物（见 SeaIceLanes::cell_temperature）。
struct SeaIceInput {
    int                n_cells = 0;
    std::vector<float> cell_temperature;
    // 其余消费点 lane。capture 读的是 tick 某一刻的 slot，sea_ice 读的是
    // 当天自己那一拍；只记温度会让 worker 用陈旧的 upwelling / insolation /
    // oanom 去跑同一份内核。
    std::vector<float>   upwelling_strength;
    std::vector<float>   insolation_now;
    std::vector<float>   ocean_thermal_anomaly;
    std::vector<float>   temp_transport_anomaly;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> base_terrain;
    std::vector<float>   sea_ice_frac;
    std::vector<uint8_t> water_terrain_ids;
};

void overlay_production_sea_ice(ClimateInputBuf &base, const SeaIceInput &prod);

// ─── stage 0x20 WIND_SURFACE：oanom 的权威归属 ─────────────────────────────
//
// `cell_ocean_thermal_anomaly` 是本轮定位到的分叉链头，而它**不是**算法分歧：
//
//   - pass_a 末尾把 oanom / lanom 清零，开启新一日累加；
//   - 本该由 OCEAN_WATER / OCEAN_LAND 重新填，但生产的这两个 pass 跑在 climate
//     round 之外、且按 start_idx/end_idx 跨 tick 分片（`_publish_cadence` 实测
//     `prod_knobs` 恒为 0x72，ocean 两位一次都没置位）；
//   - 于是生产的 wind_surface 读到的是一份"跨日携带"的 oanom，而 worker 一次跑完
//     整个 round，自己的 pass_a 把它清成了 0。
//
// 结论：在 SHADOW 下 worker 不是 oanom 的权威 —— 生产的分片 ocean stage 才是。
// 所以照 WindAirInput 的同一个配方，把生产 wind_surface 真正读到的那份 oanom 记下
// 来，在 worker 的 pass_a 之后重新注入。lanom 不在此列：它由 pass_b 在 round 内
// 重新累加，worker 是它的权威。
struct WindSurfaceInput {
    int                n_cells = 0;
    std::vector<float> ocean_anomaly;
};

void overlay_production_wind_surface(ClimateInputBuf &base, const WindSurfaceInput &prod);

// ─── native daily finalizer ────────────────────────────────────────────────
//
// 生产的 run_native_daily_finalizer 顶上写着一条不能忽略的约束：GDScript 的
// float 是 64 位，`clampf` / `absf` 都在 double 里算，PackedFloat32 读出来会提升成
// double，只有存回时才收窄。要跟 GDScript 逐位相等，**每一个中间量都必须是
// double，只在写回那一步收窄**——注释原话是「float32 内核会在 TTA clamp 上偏
// ~1e-5，随后传进下一轮的 ocean / weather / hydrology」。
//
// worker 的 _async_finalizer_kernel_pure 全程用 float，正好踩中这条。它是温度链上
// 最后一处平行实现：wind_surface 出口两边已逐位相等，temperature 仍差 ~4e-4，就是
// 这里来的。合成一份 double 内核之后，"照着 GDScript 抄成 float32" 不再可能。
struct FinalizerKnobs {
    int    n_cells = 0;
    bool   temp_cap_enabled = true;
    double temp_cap = 0.15;
    double tta_cap = 0.12;
    // 起始值缺失时不做 cap（与生产的 has_* 判定一致）。
    bool   has_temp_start = false;
    bool   has_tta_start = false;
};

struct FinalizerLanes {
    const float   *temp_start = nullptr;   // has_temp_start 为真时必须非空
    const float   *tta_start = nullptr;    // has_tta_start 为真时必须非空
    const uint8_t *ema = nullptr;          // 可为 nullptr
    int            ema_size = 0;

    // in/out
    float *temp = nullptr;
    float *tta = nullptr;
    float *thermal = nullptr;              // 可为 nullptr = 这一轮不初始化 thermal

    // 纯输出，可为 nullptr。worker 要拿它们算 p95/p99，生产不需要。
    float *temp_deltas = nullptr;          // 容量 n_cells
    float *preclamp_temp_deltas = nullptr; // 容量 n_cells
};

struct FinalizerStats {
    double max_temp_delta = 0.0;
    double preclamp_max_temp_delta = 0.0;
    double max_transport_anomaly = 0.0;
    int    temp_delta_gt_005 = 0;
    int    temp_delta_gt_010 = 0;
    int    temp_delta_gt_020 = 0;
    int    temp_clamped = 0;
    int    tta_clamped = 0;
    int    thermal_init = 0;
};

void finalizer_pure(const FinalizerKnobs &knobs,
                    const FinalizerLanes &lanes,
                    FinalizerStats &stats);
