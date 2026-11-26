// Ocean heat transport inputs and land surface feedback kernel declarations.

// ─── OCEAN_WATER / OCEAN_LAND ──────────────────────────────────────────────
//
// 这两个 pass 之前是全 Climate 里最厚的一坨平行实现：生产侧
// run_ocean_{water,land}_pass 各有 scalar / simd / thread 三份，worker 侧
// _async_ocean_{water,land}_kernel_pure 又各抄一份，共八份。而且因为生产在对拍用的
// 60×40 上从不跑 ocean（`prod_knobs` 恒 0x72，两位从不置位），worker 那两份抄本是
// **零对拍覆盖**的 —— 谁都没验证过它们对不对。
//
// 偏偏 `ocean_thermal_anomaly` 是 wind_surface → temperature 那条链的链头。也就是说
// P7 让 Climate 转 ACTIVE 之后，worker 第一件事就要靠这两份从未验证的内核自产
// oanom。所以这里先把主循环合成一份，去掉"抄本各自漂移"这个风险面。
//
// 区间语义：生产按 start_idx/end_idx 跨 tick 分片，worker 整图一次跑完。内核接
// [start_idx, end_idx) 两种都能表达，不在内核里假设任何一种。
struct OceanWaterKnobs {
    int   n_cells = 0;
    int   start_idx = 0;
    int   end_idx = 0;
    int   advect_steps = 0;
    float heat_mix = 0.0f;
    float wrap_period_x = 0.0f;
    float tta_source_cap = 0.22f;          // 调用方负责先 clamp 到 [0, 0.5]
    float tta_blend_rate = 0.70f;          // [0, 1]
    float tta_zero_current_decay = 0.06f;  // [0, 1]
    // 生产取 knobs["cold_transport_{form,melt}_threshold"]；worker 之前错用了
    // sea_ice 的 si_t_form / si_t_melt —— 是两组不同的 knob，别再混。
    float cold_transport_form = 0.06f;
    float cold_transport_melt = 0.11f;
};

struct OceanWaterLanes {
    const uint8_t *is_water = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const float   *ocean_current_x = nullptr;
    const float   *ocean_current_y = nullptr;
    // 生产传 knobs["baseline_arr"] / ["temp_before_arr"]；worker 旧抄本擅自等同为
    // temp_baseline_year / temp，并在注释里自认是"假设"。wind_air 上同样的假设已经
    // 被证伪过一次，所以这里由调用方显式给，内核不猜。
    const float   *baseline = nullptr;
    const float   *temp_before = nullptr;
    const float   *sea_ice_frac = nullptr;
    const int32_t *neighbors = nullptr;

    float *ocean_anomaly = nullptr;  // in/out：water cell 覆盖写
    float *tta_inout = nullptr;      // in/out：生产的 anomaly_out
};

void ocean_water_pure(const OceanWaterKnobs &knobs, const OceanWaterLanes &lanes);

// 生产的 ocean_water 吃 knobs["baseline_arr"] / ["temp_before_arr"]，两者都是
// map_generator 当场算出来的派生量（baseline 在 EMA 未全初始化时走一条冷启动
// 重建路径，temp_before 是专门的 work buffer）。旧 worker 拄本把它们擅自等同为
// temp_baseline_year / temp 并在注释里自认是“假设”—— wind_air 上同样的假设已经被
// 证伪过一次。在消费点抽真值，才能让 worker 自产 oanom（而不是靠 overlay 借）。
struct OceanWaterInput {
    int                n_cells = 0;
    std::vector<float> baseline;
    std::vector<float> temp_before;
};

void overlay_production_ocean_water(ClimateInputBuf &base, const OceanWaterInput &prod);

struct OceanLandKnobs {
    int   n_cells = 0;
    int   start_idx = 0;
    int   end_idx = 0;
    float effective_leak = 0.0f;
    float wrap_period_x = 0.0f;
    float tta_source_cap = 0.22f;  // 调用方负责先 clamp
    float tta_blend_rate = 0.70f;
    float tta_decay_rate = 0.04f;
};

struct OceanLandLanes {
    const uint8_t *is_water = nullptr;
    const float   *pos_x = nullptr;
    const float   *pos_y = nullptr;
    const float   *ocean_current_x = nullptr;
    const float   *ocean_current_y = nullptr;
    const int32_t *neighbors = nullptr;

    // land cell 读 water 邻居的 anomaly（water pass 已 finalize），写自己的。
    // 两个集合不相交，所以同一个数组 in-place 安全。
    float *tta_inout = nullptr;
    float *ocean_anomaly = nullptr;  // in/out：land cell 累加
};

void ocean_land_pure(const OceanLandKnobs &knobs, const OceanLandLanes &lanes);

// albedo：逐 cell、无邻居、原地改温度。生产侧持有的是 Godot 的 PackedArray，worker
// 侧持有的是 std::vector，所以签名走裸指针 —— 两边都不必为了调用它先拷一份 buffer。
// temp 是 in/out。albedo_table 索引是 vegetation id，越界按 0 反照率处理（与生产一致）。
void albedo_apply_pure(const ClimateAlbedoKnobs &knobs,
                       const uint8_t *is_water,
                       const uint8_t *vegetation,
                       const uint8_t *cover,
                       const float *albedo_table,
                       int albedo_size,
                       float *temp,
                       int n_cells);

// climate_feedback：逐 cell + 6 邻居 gather，但只写自身的 BM / SOIL / VGP，所以
// [begin, end) 可以任意拆分并行（生产的 _thread 变体正是这么用的）。
//
// veg_growth_pressure 允许为 nullptr —— knobs.write_weather_veg_pressure 为假时生产
// 也不碰它。base_moisture / soil_moisture 是 in/out。
void climate_feedback_apply_pure(const ClimateFeedbackKnobs &knobs,
                                 const uint8_t *is_water,
                                 const uint8_t *weather_type,
                                 const float *weather_intensity,
                                 const uint8_t *weather_field_init,
                                 const int32_t *neighbor_indices,
                                 const float *temp_transport_anomaly,
                                 float *base_moisture,
                                 float *soil_moisture,
                                 float *veg_growth_pressure,
                                 int begin,
                                 int end);

// vegetation_dynamics：逐 cell 独立（只读表 + 自身 lane，只写自身 lane），所以
// [begin, end) 可以任意拆分并行；生产的 _thread 变体按 task_idx 升序 merge emit
// 来保持 cell idx 升序契约。
void vegetation_dynamics_apply_pure(const VegetationDynamicsKnobs &knobs,
                                    const VegetationDynamicsTables &tables,
                                    const VegetationDynamicsLanes &lanes,
                                    int begin,
                                    int end,
                                    VegetationDynamicsEmit &emit);
