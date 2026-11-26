// Synoptic circulation, cyclone, and weather field input declarations.

// ─── stage 11 WEATHER：synoptic 涡旋场 ψ 的整步推进 ─────────────────────────
//
// 全场一次、不可切片：半拉格朗日平移要读全场的 ψ_prev 快照，扩散也要读邻域的
// prev 值，按 [begin, end) 切会让后半段读到已被本轮改写的值。
struct SynopticAdvanceKnobs {
    float baroclinic = 0.40f;
    float damp = 0.90f;
    float diffuse = 0.05f;
    float seed_rate = 0.015f;
    float seed_amp = 0.42f;
    int   adv_cells = 3;
    // 播种哈希的 tick。同一 tick 必须给出同一批种子，所以它是输入而非内部计数。
    int   tick = 0;
    float cell_pos_scale = 1.0f;
    float wrap_width_x = 0.0f;
};

// psi / psi_prev 是调用方持有的跨 tick lane（生产是 DCWorldExt 成员，worker 是
// scratch）。两者都会被写：psi_prev 收本轮的整步快照，psi 收推进结果。
// temp_norm 必须是归一化温度（主循环用的 TR）。传实际量纲的 cell_temp 会让斜压
// 门的 smoothstep 恒为 1，ψ 随轮次指数饱和到 ±1 并铺满全场。
void synoptic_advance_pure(int n_cells,
                           const int32_t *neighbor_indices,
                           const float *pos_x,
                           const float *pos_y,
                           const float *wind_x,
                           const float *wind_y,
                           const float *temp_norm,
                           const SynopticAdvanceKnobs &knobs,
                           std::vector<float> &psi,
                           std::vector<float> &psi_prev);

// ─── stage 11 WEATHER：tropical cyclone 推进 + stamp（B8-2 自持）────────────
//
// 生产把它放在 DCWorldExt::_advance_and_stamp_cyclones（world_ext_weather.cpp），
// 在 weather field solve 的 start_idx==0 处调用一次；worker 现在也自持同一份状态与
// 同一段数学。为了让内核不依赖 godot::Vector2，条目里的向量拆成标量、位置拆成
// pos_x/pos_y 两条 lane —— 数学逐行照搬，不做任何"顺手优化"。
//
// 状态所有权：
//   * entries / next_stable_id 是跨天状态（可变长），生产在 DCWorldExt 成员里，
//     worker 在 kernel scratch 里，两者都通过 cyclone_state_encode/decode 走同一种
//     blob（capture 播种 + CLM2 持久化）。
//   * force_tag/visit_tag/force_x/y/lift 是当天派生 lane，由调用方持有。
//
// genesis（cyclone_wake_step 从前沿注入新气旋）仍留在主线程：它消费 WeatherFront
// 对象。本内核只负责已有气旋的推进、衰减与 stamp。
struct CycloneAdvanceKnobs {
    bool    enabled = false;
    float   dt_days = 1.0f;
    float   world_bounds_pos_y = 0.0f;
    float   world_bounds_size_y = 1.0f;
    float   wrap_width_x = 0.0f;
    int32_t max_radius_cells = 5;
};

struct CycloneEntry {
    uint64_t stable_id = 0;
    int64_t  key = 0;              // cell.q * 10000 + cell.r
    int32_t  cell_idx = -1;
    float    steering_x = 0.0f;
    float    steering_y = 0.0f;
    float    vec_x = 0.0f;
    float    vec_y = 0.0f;
    float    vec_init_x = 0.0f;
    float    vec_init_y = 0.0f;
    float    intensity = 0.0f;
    float    radius_cells = 2.0f;
    float    age_days = 0.0f;
    float    move_progress = 0.0f;
    int32_t  days_left = 0;        // compatibility projection
    int32_t  init_days = 0;
};

struct CycloneLanes {
    const int32_t *neighbors = nullptr;   // [n_cells * 6]
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    // 规范纬度（cell_lat_norm，0..1，赤道=0.5）。可空。
    //
    // 为什么不能只用 pos_y / world_bounds：`_world_bounds` 是世界矩形，而
    // cell_pos_y 是格子局部世界坐标。两者尺度并不一致（例：50x48 地图上
    // water_ny ∈ [0.026,0.068]），按 world bounds 归一化得到的"纬度"会整体贴边，
    // 纬度带过滤器于是恒不命中。lat_norm 是 temp_baseline 用的同一条几何量，
    // 也是"纬度"的唯一规范来源；空指针时退回 world-y 公式（对拍/单测用）。
    const float   *lat_norm = nullptr;
    const uint8_t *terrain = nullptr;
    const float   *temp = nullptr;
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const float   *vapor = nullptr;
    const float   *instability = nullptr;
};

struct CycloneStamp {
    uint32_t *force_tag = nullptr;   // [n_cells]
    uint32_t *visit_tag = nullptr;   // [n_cells]
    float    *force_x = nullptr;     // [n_cells]
    float    *force_y = nullptr;     // [n_cells]
    float    *lift = nullptr;        // [n_cells]
    uint32_t force_generation = 1u;
    uint32_t visit_generation = 1u;
};

struct CycloneStats {
    int32_t touched_cells = 0;
    int32_t decayed = 0;
    int32_t alive = 0;
    // 推进前后的最大 intensity：用来区分"出生即死"是衰减项太狠（温度/势能
    // 项）还是 evict 条件（<0.075 / age>32）本身不对。
    float   entry_intensity_max_before = 0.0f;
    float   entry_intensity_max_after = 0.0f;
};

// genesis（出生）：生产版消费 WeatherFront 对象（type==STORM && intensity>=0.8 +
// 前沿 center/velocity），而前沿由 C++-only 的 summary pass 产出、ACTIVE 下主线程
// 天气被抑制时根本不存在。共享内核因此改成**基于格子状态**的等价判据：
//   * 前沿等价物 = 当天 weather_intensity >= intensity_gate(0.8) 的格子。
//     注意不能要求 weather_type == STORM：field solve 只有在已有 cyclone stamp
//     （cyclone_lift >= 0.58）时才把 type 写成 STORM，拿它当出生条件就是闭锁
//     （new storm 永远生不出来）。require_storm_type 只为复现旧闭锁做 A/B。
//     而 front 的 intensity 本来就从这条 intensity lane 派生，所以两者同源。
//   * 前沿 velocity 等价物 = 该格当天风场（前沿本来就随风移动）；
//   * 前沿 center → 格子的 world→qr 反查不需要了：候选格自己就是注入点；
//   * 唯一键用 cell_idx（生产用 q*10000+r，只用于"同格覆盖"，在 worker 内等价）。
// 其余阈值（水陆、温度、降水、云量、对流/辐合、风切变、纬度带、容量、每次出生数）
// 与生产 native-entity 路径逐条一致；纬度带用规范 lat_norm（生产用的
// world-y/world_bounds 在小地图上是退化量，见 CycloneLanes::lat_norm 注释）。
struct CycloneGenesisKnobs {
    bool    enabled = false;
    int32_t storm_type_id = -1;
    int32_t capacity = 24;
    int32_t births_per_commit = 2;
    float   min_temp = 0.58f;
    float   min_instability = 0.40f;
    float   max_shear = 0.42f;
    float   min_lat = 0.06f;
    float   max_lat = 0.40f;
    float   world_bounds_pos_y = 0.0f;
    float   world_bounds_size_y = 1.0f;
    float   intensity_gate = 0.8f;
    float   precip_gate = 0.05f;
    float   cloud_gate = 0.22f;
    float   wake_days = 32.0f;
    // 生产 genesis 消费 WeatherFront.type（summary 段产物）。worker 里没有 front
    // 对象，等价判据是 field solve 的 intensity lane，所以默认不查 weather_type。
    // A/B 时可额外要求格子已被分类为 STORM。
    bool    require_storm_type = false;
};

struct CycloneGenesisLanes {
    const uint8_t *terrain = nullptr;          // [n_cells]
    const uint8_t *water_lut = nullptr;        // [256] water terrain ids
    const uint8_t *weather_type = nullptr;     // [n_cells]
    const float   *weather_intensity = nullptr;// [n_cells]
    const float   *temp = nullptr;             // [n_cells]
    const float   *precip = nullptr;           // [n_cells]
    const float   *cloud = nullptr;            // [n_cells]
    const float   *instability = nullptr;      // [n_cells]
    const float   *wind_x = nullptr;           // [n_cells]
    const float   *wind_y = nullptr;           // [n_cells]
    const float   *wind_speed = nullptr;       // [n_cells]
    const float   *pos_x = nullptr;            // [n_cells]
    const float   *pos_y = nullptr;            // [n_cells]
    float wrap_width_x = 0.0f;
    const float   *lat_norm = nullptr;         // [n_cells]，可空，语义同 CycloneLanes
    const int32_t *neighbors = nullptr;        // [n_cells * 6]
    const uint8_t *is_water = nullptr;         // [n_cells]，可空（用 LUT 判定）
};

struct CycloneGenesisStats {
    int32_t injected = 0;
    int32_t replaced = 0;
    int32_t alive = 0;
    // 漏斗计数（诊断用）：每一格候选按顺序过闸，失败即停。soak 里
    // "injected=0" 时靠这四个数判断是水陆/纬度/物理量还是强度门槛挡住。
    int32_t cand_water = 0;     // 过水陆
    int32_t cand_lat = 0;       // 过纬度带
    int32_t cand_physical = 0;  // 过 temp/precip/cloud/instability
    int32_t cand_intensity = 0; // 过 intensity_gate
    int32_t cand_shear = 0;     // 过风切变（= 真正可出生）
    // 物理闸细分（只在纬度带内累加）：四个条件各自失败多少格。
    int32_t fail_temp = 0;
    int32_t fail_precip = 0;
    int32_t fail_cloud = 0;
    int32_t fail_instability = 0;
    // 纬度带内水格里当前 weather_type == storm_type_id 的个数。用来区分
    // "worker 分类根本没产出 STORM（气候不够强）"与"产出了但强度不够"。
    int32_t type_storm = 0;
    float   max_intensity = 0.0f;
    float   max_precip = 0.0f;
    float   max_cloud = 0.0f;
    float   max_instability = 0.0f;
    float   max_convergence = 0.0f;
};

void cyclone_genesis_pure(int n_cells,
                          const CycloneGenesisKnobs &knobs,
                          const CycloneGenesisLanes &lanes,
                          std::vector<CycloneEntry> &entries,
                          uint64_t &next_stable_id,
                          CycloneGenesisStats &stats);

void cyclone_advance_and_stamp_pure(int n_cells,
                                    const CycloneAdvanceKnobs &knobs,
                                    const CycloneLanes &lanes,
                                    std::vector<CycloneEntry> &entries,
                                    CycloneStamp &stamp,
                                    CycloneStats &stats);

// blob：u32 magic "CYC1" + u32 version + u32 count + u64 next_stable_id + count × record。
// 生产 capture、worker 冷启动播种与 CLM2 ABI 6 持久化共用同一份编码。
std::vector<uint8_t> cyclone_state_encode(const std::vector<CycloneEntry> &entries,
                                          uint64_t next_stable_id);
void cyclone_state_decode(const std::vector<uint8_t> &blob,
                          std::vector<CycloneEntry> &entries,
                          uint64_t &next_stable_id);

// ─── stage 11 WEATHER：field solve 主循环 ───────────────────────────────────
//

//
// 所有标量 knob 都在这里，热循环里不再有 knobs.get —— 原实现在循环内每 cell 各查
// 一次 thermal_monsoon_enabled 和 cyclone_storm_type_id（一次 Dictionary 查找 +
// 一次 Variant 转换 × n_cells），并且那两次查找是这个循环里唯一的 Godot 调用。
struct WeatherFieldKnobs {
    int   n_cells = 0;
    float climate_anomaly = 0.0f;
    bool  refresh_convergence = false;
    bool  apply_convergence_boost = true;
    // use_next_outputs：staged（native daily）路径写独立的 next buffer，direct 路径
    // 原地改 slot。它决定 weather_type 写 int32 还是 uint8，以及过渡三条与
    // weather_field_init 是否落盘 —— 不能由指针非空推断，两条路径的输出集合不同。
    bool  use_next_outputs = false;

    int   field_advect_steps = 3;
    float field_diffusion = 0.04f;
    float field_ocean_evap_gain = 0.55f;
    float field_precip_inertia = 0.40f;
    float field_precip_spatial_smooth = 0.30f;
    float field_cloud_inertia = 0.74f;
    float field_wet_terrain_precip_damping = 0.60f;
    float field_lake_precip_damping = 0.65f;
    float field_lake_evap_scale = 0.35f;
    float field_extreme_precip_soft_cap = 0.16f;
    float field_extreme_precip_softness = 0.20f;
    float field_land_evapotranspiration_gain = 0.85f;
    float field_ocean_precip_suppression = 0.95f;
    float field_frontogenesis_gain = 0.42f;
    float field_rain_shadow_drying = 0.35f;
    float field_advect_vapor = 0.95f;
    float field_advect_cloud = 0.94f;
    float field_rh_condense = 0.55f;
    float field_static_cond_w = 1.00f;
    float field_condense_rate = 0.45f;
    float field_lift_cond_gain = 0.80f;
    float field_conv_cond_gain = 1.00f;
    float field_thermal_conv_cond = 1.15f;
    float field_thermal_conv_precip = 0.30f;
    float field_autoconversion = 0.16f;
    float field_precip_base_frac = 0.08f;
    float field_lift_precip_gain = 0.45f;
    float field_conv_precip_gain = 1.95f;
    float field_oro_precip_gain = 0.30f;
    float field_stratiform_gain = 1.0f;
    float field_cool_season_vapor_floor = 0.0f;
    float field_cloud_reevap = 0.28f;

    float weather_cell_pos_scale = 1.0f;
    float weather_wrap_width_x = 0.0f;
    bool  cold_precip_as_blizzard = true;
    float snow_classification_margin = 0.03f;

    // Hadley/Ferrel omega 的纬度廓线。wb_size_y <= 0.001 时 omega_ny 退化为 0.5。
    float weather_lat_te_norm = 0.5f;
    float omega_ascent_gain = 0.40f;
    float world_bounds_pos_y = 0.0f;
    float world_bounds_size_y = 0.0f;

    // ψ 的耦合项（ψ 自身的演化 knob 在 SynopticAdvanceKnobs）。
    float syn_supp = 0.75f;
    float syn_enh = 0.45f;
    float syn_front_force = 0.55f;
    float syn_front_enh = 0.70f;
    float syn_base_lift = 1.55f;

    bool  weather_transition_enabled = false;
    float weather_transition_alpha_rate = 1.0f;
    float weather_transition_dt_days = 1.0f;

    // 原本在热循环里查 knobs 的两个。
    bool    thermal_monsoon_enabled = false;
    uint8_t cyclone_storm_type_id = 2;

    // W4：RAIN 判定的降水率门槛（陆/水各一档）。缺省值 = 旧的 0.040/0.032，
    // 由 ClimateProfile.weather_precip_classify_gate_land/water 下发；W4 验收时改 profile，不改代码。
    float classify_gate_land = 0.040f;
    float classify_gate_water = 0.032f;

    // W6：分类器用的温度距平钳制。与 distribute 改温度的 `weather_temp_anomaly_cap`(0.025)
    // 是两件事 —— 混用会把天气对温度的扰动放大 5 倍。
    float classify_anomaly_cap = 0.12f;
};

// per-cell in/out lane。read lane 是 tick 起始快照或 slot，write lane 视
// use_next_outputs 指向 next buffer 或 slot 本身。允许为 nullptr 的：
//   river_q30 / soil_moisture / vitality / sea_ice / prev_cloud_water /
//   temp_anomaly / snow_cover（对应 component 没绑时按默认值处理）
//   out_cloud_water / out_type_u8 / out_type_i32 / out_field_init /
//   out_prev_type / out_target_type / out_alpha（按路径二选一）
struct WeatherFieldLanes {
    const float   *temp_read = nullptr;        // TR
    const float   *moisture_read = nullptr;    // MR
    const float   *air_anomaly = nullptr;      // AA
    const float   *wind_x = nullptr;
    const float   *wind_y = nullptr;
    const float   *wind_speed = nullptr;
    const uint8_t *terrain = nullptr;
    const uint8_t *has_river = nullptr;
    const float   *river_q30 = nullptr;
    const float   *elevation = nullptr;
    const uint8_t *vegetation = nullptr;
    const float   *soil_moisture = nullptr;
    const float   *vitality = nullptr;
    const float   *sea_ice = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const float   *temp_anomaly = nullptr;     // 分类用的温度距平（TANO）
    const float   *snow_cover = nullptr;
    const int32_t *neighbor_indices = nullptr;
    const float   *prev_vapor = nullptr;
    const float   *prev_precip = nullptr;
    const float   *prev_cloud_water = nullptr;
    const float   *temp_transport_anomaly = nullptr;  // TA
    const float   *prev_convergence = nullptr;
    const float   *prev_cloud = nullptr;

    float   *out_vapor = nullptr;
    float   *out_cloud = nullptr;
    float   *out_cloud_water = nullptr;
    float   *out_precip = nullptr;
    float   *out_instability = nullptr;
    float   *out_intensity = nullptr;
    float   *out_convergence = nullptr;
    uint8_t *out_type_u8 = nullptr;
    int32_t *out_type_i32 = nullptr;
    uint8_t *out_prev_type = nullptr;
    uint8_t *out_target_type = nullptr;
    float   *out_alpha = nullptr;
    uint8_t *out_field_init = nullptr;
};

// 跨 tick / 每轮预算的状态。这七组在 RuntimeClimateStore 里都没有成员：
//   - conv_inhib：真正的跨 tick 状态（对流抑制的双稳记忆），in/out。
//   - psi：ψ 场，由 synoptic_advance_pure 每轮推进，这里只读。
//   - cyclone_*：气旋实体每轮 stamp 出来的 per-cell 强迫，只读。
//   - monsoon_thermal：wind pass 留下的热力季风因子，只读。
//   - traj_*：半拉格朗日轨迹表，风场指纹命中才非空，只读。
//   - geom_*：邻域几何缓存，每轮 start_idx==0 重算，只读。
// 几何缓存与轨迹表是可重算的派生量（geometry_cache_pure 就地重建），其余必须随
// reference 记录初值，否则 worker 的第一天会从零起步而生产不是。
struct WeatherFieldState {
    float *conv_inhib = nullptr;               // in/out，可为 nullptr

    const float *psi = nullptr;                // 只读；nullptr = ψ 耦合关闭

    // 气旋强迫。tag[i] == generation 才算本轮被 stamp 过。
    const uint32_t *cyclone_tag = nullptr;
    int             cyclone_tag_count = 0;
    uint32_t        cyclone_generation = 0;
    const float    *cyclone_lift = nullptr;
    const float    *cyclone_x = nullptr;
    const float    *cyclone_y = nullptr;

    const float *monsoon_thermal = nullptr;
    int          monsoon_thermal_count = 0;

    const int32_t *traj_idx = nullptr;         // [n_cells * 3]
    const float   *traj_w = nullptr;           // [n_cells * 3]

    // 三条同时非空才算命中；缺任何一条都退回逐次重算的 _xy 变体（两路 bit-equal）。
    const float *geom_dx = nullptr;
    const float *geom_dy = nullptr;
    const float *geom_invd = nullptr;
};
