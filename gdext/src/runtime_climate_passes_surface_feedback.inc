// Albedo, vegetation dynamics, and climate feedback pass inputs.

// ─── albedo pass（stage 8）─────────────────────────────────────────────
//
// 生产侧 albedo 不属于 climate round：它在 native daily graph 的 stage_b 段跑，
// 用自己的 stride（cp.weather_albedo_stride，默认 10 次 weather 调用一次）。所以它
// 不能挂在 passes_mask 上跟着 round 走，只能由生产把"这一天到底跑没跑、用的什么
// 标量"如实记录下来，随 reference 一起发布给 worker。
//
// 它是 temp_arr 在一个仿真日内的最后一个写者（round 末尾 wind_surface/finalizer 之后
// 再叠一层反照率反馈）。worker 少了这一段，温度场就会在生产跑 albedo 的那些天单方面
// 落后一个 delta —— 这正是 S2 分叉矩阵里 temperature 被标成 CLIMATE_FEEDBACK 分叉的
// 真实原因（parity 的 stage 标签记的是"日内最后写者"，而写 temp 的是 albedo 段）。
struct ClimateAlbedoKnobs {
    // false = 这一天生产没跑 albedo，worker 必须也不跑。
    bool  ran = false;
    float reference_albedo = 0.0f;
    float temp_gain = 0.0f;
    float snow_cover_albedo = 0.75f;
    // CoverType.CV.SNOW = 1 / CV.GLACIER = 2（cover_type.gd）。
    uint8_t cover_snow_id = 1;
    uint8_t cover_glacier_id = 2;
};

// ─── climate_feedback pass（stage 10）──────────────────────────────────
//
// 与 albedo 同理，它也不在 climate round 里：跑在 native daily graph 的 stage_b 段、
// 用 cp.weather_feedback_stride 自己的节拍。所以同样由生产如实记录"这一天跑没跑、
// 用的什么标量"，随 reference 一起发布。
//
// 它写三个场：base_moisture / soil_moisture（都不是 worker store 的成员，worker 侧
// 只能用 scratch 承接，输出丢弃）和 vegetation_growth_pressure（是 store 成员，
// 必须写 worker 自己的那一份，否则 parity 就退化成"抄一遍生产的结果"）。
struct ClimateFeedbackKnobs {
    // false = 这一天生产没跑 feedback，worker 必须也不跑。
    bool  ran = false;
    float soil_gain = 0.0f;
    float veg_gain = 0.0f;
    float scale = 1.0f;
    float per_day_clamp = 0.0f;
    float ocean_drift_gain = 0.0f;
    // knobs["weather_to_base_moisture_gain"]，缺省 0 = 关闭这条反馈。
    float base_moisture_gain = 0.0f;
    bool  write_weather_veg_pressure = true;
    // weather 枚举 id。生产从 knobs 逐个取，缺一个就整段拒跑，所以这里没有默认值
    // 语义 —— -1 只是"没被记录过"，与任何真实 weather_type 都不相等。
    int32_t wt_rain_id = -1;
    int32_t wt_storm_id = -1;
    int32_t wt_monsoon_id = -1;
    int32_t wt_blizzard_id = -1;
    int32_t wt_drought_id = -1;
    int32_t wt_heatwave_id = -1;
};

// 生产 feedback 当天真正读到的输入。
//
// 为什么不能用 environment 快照的同名 lane：feedback 跑在 stage_b 段，也就是 weather
// 之后；而快照是 tick 起始拍的。weather_type / weather_intensity 在这两个时刻之间正好
// 被 weather pass 整场重写过，用快照那份等于拿昨天的天气算今天的反馈。
struct ClimateFeedbackInput {
    ClimateFeedbackKnobs knobs;
    int n_cells = 0;
    std::vector<uint8_t> is_water;
    std::vector<uint8_t> weather_type;
    std::vector<float>   weather_intensity;
    std::vector<uint8_t> weather_field_init;
    std::vector<float>   temp_transport_anomaly;
    // 这两条是 in/out，但都不是 worker store 的成员：记录的是生产读到的初值。
    std::vector<float>   base_moisture;
    std::vector<float>   soil_moisture;
};

// ─── vegetation_dynamics pass（stage 9）────────────────────────────────
//
// 与 albedo / feedback 同类：不在 climate round 里，跑在 native daily graph 的
// stage_b 段，用自己的节拍。所以同样由生产如实记录"这一天跑没跑、用的什么标量与表"，
// 随 reference 一起发布。
//
// 它写的场里，worker store 有对应成员的是：plant_available_water、
// vegetation_growth_pressure、vegetation_vitality、vegetation_heat_stress、
// vegetation_drought_stress、vegetation_cold_stress、vegetation_growth_streak
// （= high_streak）、vegetation_drought_streak（= low_streak）。
// regen_score 只有 uint8 的 vegetation_succession_candidate 与之近似，没有 float
// 成员可承接，所以 worker 侧用 scratch（与 feedback 的 soil_moisture 同处理）。
struct VegetationDynamicsKnobs {
    // false = 这一天生产没跑 vegetation_dynamics，worker 必须也不跑。
    bool  ran = false;
    // knobs["day_scale"] 先 max(1.0) 过一遍再存，与生产一致。
    float scale = 1.0f;
    int32_t streak_days = 0;
    float vitality_change_rate = 0.0f;
    float compat_harshness = 1.0f;
    float low_threshold = 0.0f;
    float high_threshold = 1.0f;
    int32_t succession_degrade_days = 0;
    int32_t succession_upgrade_days = 0;
    int32_t n_wt = 0;
    int32_t wt_clear_id = 0;
    uint8_t veg_none_id = 0;
    float weather_penalty_scale = 1.0f;
    float plant_water_balance_weight = 0.0f;
    float plant_soil_buffer_weight = 0.0f;
    float plant_drought_penalty = 0.0f;
    float succession_min_compat_gain = 0.0f;
    float low_vitality_damping_threshold = 0.40f;
    int32_t succession_cooldown_days = 30;
    // 生产 GDScript 演替后处理用的"降级后 vitality 重置目标"（默认 0.75；升级用
    // 固定 0.7）。worker 自持演替时必须拿到同一个值，否则同一次演替后两侧 vitality
    // 会系统性分叉。
    float degrade_reset_target = 0.75f;
    // 只有 use_soa=true 的 stage_b 路径能开；关闭时 heat/drought/cold/regen 四条
    // in/out lane 允许为 nullptr。
    bool  stress_enabled = false;
    // = clamp(scale / vegetation_stress_memory_days, 0, 1)，生产算好再存，
    // 避免两侧各自做一次除法产生 ULP 差。
    float stress_blend = 0.0f;
    int32_t wt_blizzard_id = -1;
    int32_t wt_drought_id = -1;
    int32_t wt_heatwave_id = -1;
    // 表维度。n_veg 由 ideal_temp_table 长度决定；wt_pen_size 可以 > n_wt。
    int32_t n_veg = 0;
    int32_t wt_pen_size = 0;
};

// VEG-indexed / weather-indexed 查表。生产直接传 PackedArray 的 ptr()，零拷贝。
struct VegetationDynamicsTables {
    const float   *ideal_temp = nullptr;       // [n_veg]
    const float   *ideal_moist = nullptr;      // [n_veg]
    const float   *temp_tol = nullptr;         // [n_veg]
    const float   *moist_tol = nullptr;        // [n_veg]
    const float   *weather_penalty = nullptr;  // [wt_pen_size]
    const float   *resistance = nullptr;       // [n_veg * n_wt]
    const uint8_t *next_up = nullptr;          // [n_veg]
    const uint8_t *next_down = nullptr;        // [n_veg]（当前算法未读，保留对齐生产签名）
};

// per-cell in/out lane 指针。soil_moisture 与 vegetation_growth_pressure 允许为
// nullptr（生产 stage_b 里这两个 component 可能没绑），此时按 0 处理 / 不写。
struct VegetationDynamicsLanes {
    const uint8_t *is_water = nullptr;
    const uint8_t *terrain = nullptr;
    const uint8_t *landform = nullptr;
    const uint8_t *vegetation = nullptr;
    const float   *temp_30d = nullptr;
    const float   *moisture = nullptr;
    const float   *water_balance_30d = nullptr;
    const float   *soil_moisture = nullptr;
    const uint8_t *weather_type = nullptr;
    const float   *weather_intensity = nullptr;
    const uint8_t *weather_field_init = nullptr;
    float   *plant_available_water = nullptr;
    float   *vegetation_growth_pressure = nullptr;
    float   *vitality = nullptr;
    int32_t *low_streak = nullptr;
    int32_t *high_streak = nullptr;
    float   *heat_stress = nullptr;
    float   *drought_stress = nullptr;
    float   *cold_stress = nullptr;
    float   *regen_score = nullptr;
};

// 演替候选输出。cell idx 必须严格升序 —— 生产的并行变体按 task_idx 升序 merge
// 来维持这个契约，GDScript 后处理依赖它。
struct VegetationDynamicsEmit {
    std::vector<int32_t> indices;
    std::vector<uint8_t> to_veg;

    void merge_into(VegetationDynamicsEmit &dst) const {
        dst.indices.insert(dst.indices.end(), indices.begin(), indices.end());
        dst.to_veg.insert(dst.to_veg.end(), to_veg.begin(), to_veg.end());
    }
};

// 生产 vegetation_dynamics 当天真正读到的输入。
//
// 与 ClimateFeedbackInput 同一理由：stage 9 跑在 weather 之后，environment 快照那份
// weather_type / weather_intensity 是 tick 起始拍的，用它等于拿昨天的天气算今天的植被。
// terrain / landform / vegetation 三条也必须记录 —— vegetation 会被上一天的演替后处理
// （GDScript 侧）改写，而那条写入不在任何 climate stage 里。
struct VegetationDynamicsInput {
    VegetationDynamicsKnobs knobs;
    int n_cells = 0;
    std::vector<float>   ideal_temp;
    std::vector<float>   ideal_moist;
    std::vector<float>   temp_tol;
    std::vector<float>   moist_tol;
    std::vector<float>   weather_penalty;
    std::vector<float>   resistance;
    std::vector<uint8_t> next_up;
    std::vector<uint8_t> next_down;
    std::vector<uint8_t> is_water;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> landform;
    std::vector<uint8_t> vegetation;
    std::vector<float>   temp_30d;
    std::vector<float>   moisture;
    std::vector<float>   water_balance_30d;
    std::vector<float>   soil_moisture;
    std::vector<uint8_t> weather_type;
    std::vector<float>   weather_intensity;
    std::vector<uint8_t> weather_field_init;
    // regen_score 没有 worker store 成员可承接：记录生产读到的初值，worker 用 scratch。
    std::vector<float>   regen_score;
    // soil_moisture lane 在生产 stage_b 里可能没绑（SOIL_COMP == nullptr）。
    bool has_soil_moisture = false;
    bool has_growth_pressure = false;
};
