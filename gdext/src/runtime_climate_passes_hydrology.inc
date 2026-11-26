// Runtime hydrology input, state and kernel declarations.

// ─── stage 12 RUNTIME_HYDROLOGY ────────────────────────────────────────────
//
// 标量原样带过来，派生系数（*_eff / *_alpha）由内核自己按 dt_days 算：原先生产侧
// 算一份、worker 侧再算一份，就等于把同一个公式写两遍，哪天改了一个忘了另一个就
// 是一次静默分叉。
struct HydrologyKnobs {
    int   n_cells = 0;
    float precip_scale = 1.0f;
    float snowmelt_scale = 0.55f;
    float soil_capacity = 0.75f;
    float infiltration_rate = 0.52f;
    float quickflow_fraction = 0.36f;
    float baseflow_recession = 0.035f;
    float channel_release = 0.62f;
    float lake_release = 0.18f;
    float discharge_ema = 0.08f;
    float bank_moisture_gain = 0.035f;
    float river_moisture_floor = 0.66f;
    float riparian_moisture_floor = 0.38f;
    float river_evap_gain = 0.12f;
    float moisture_response_rate = 0.08f;
    float flood_threshold = 2.2f;
    float snowpack_melt_temp_gain = 0.22f;
    float snowpack_melt_sun_gain = 0.12f;
    float plant_water_balance_weight = 0.35f;
    float plant_soil_buffer_weight = 0.25f;
    float plant_drought_penalty = 0.65f;
    float dt_days = 1.0f;
};

struct HydrologyLanes {
    // 只读
    const int32_t *hydro_parent = nullptr;      // HP，排水 DAG 的父格
    const uint8_t *has_river = nullptr;         // HAS_RIV
    const uint8_t *terrain = nullptr;           // TERR
    const uint8_t *landform = nullptr;          // LF
    const uint8_t *vegetation = nullptr;        // VEG
    const uint8_t *cover = nullptr;             // COV
    const float   *elevation = nullptr;         // ELEV
    const float   *precip = nullptr;            // PREC
    const float   *intensity = nullptr;         // INTEN
    const uint8_t *weather_type = nullptr;      // WTYPE
    const float   *temp = nullptr;              // TEMP
    const float   *heat = nullptr;              // HEAT
    const float   *snowpack = nullptr;          // SNOWP，本 pass 只读不写
    const float   *base_moisture = nullptr;     // BASE_M
    const uint8_t *is_water = nullptr;          // IS_WATER
    const float   *vitality = nullptr;          // VITAL
    const uint8_t *canal_mask = nullptr;        // CANAL_MASK，6 方向边掩码
    // nullptr 时整个运河段跳过并清空编译缓存（与生产 has_neighbor_indices 一致）。
    const int32_t *neighbor_indices = nullptr;  // NB，size = n_cells * 6

    // 读写（跨 tick 状态，属于 RuntimeClimateStore 的成员）
    float *moisture = nullptr;                  // MOIST
    float *soil_moisture = nullptr;             // SOIL
    float *water_balance_30d = nullptr;         // WB30
    float *plant_water = nullptr;               // PLANT_WATER
    float *discharge = nullptr;                 // Q
    float *discharge_30d = nullptr;             // Q30
    float *river_storage = nullptr;             // STORAGE
    float *groundwater = nullptr;               // GW
    float *runoff = nullptr;                    // RUNOFF
    float *canal_water = nullptr;               // CANAL_WATER
};

// 运河编译态。原先是 DCWorldExt 的五个成员，worker 拿不到，所以整组抬成显式参数：
// 主线程传自己那份，worker 传自己那份，各自按 topology_generation 失效。
struct HydrologyCanalState {
    uint64_t topology_generation = 0;
    uint64_t compiled_generation = ~0ull;
    int32_t  compiled_cell_count = -1;
    std::vector<int32_t> cells;
    std::vector<uint8_t> source_kind;   // 0=无 1=咸水 2=淡水
    std::vector<float>   strength;
};

// 每日重置的临时缓冲。抬成参数只为省掉每天四次分配，语义上是纯局部量。
struct HydrologyScratch {
    std::vector<int32_t> child_count;
    std::vector<float>   incoming;
    std::vector<float>   moisture_target;
    std::vector<int32_t> queue;
};

struct HydrologyStats {
    double water_in_total = 0.0;
    double outlet_total = 0.0;
    int   runoff_source_cells = 0;
    int   river_cells_processed = 0;
    int   riparian_neighbor_touches = 0;
    int   river_moisture_floor_touches = 0;
    int   riparian_moisture_floor_touches = 0;
    float river_moisture_max_delta = 0.0f;
    float riparian_moisture_max_delta = 0.0f;
    int   flood_candidate_count = 0;
    int   canal_cells_processed = 0;
    int   canal_edges_processed = 0;
    int   canal_freshwater_cells = 0;
    int   canal_saline_cells = 0;
    float q_max = 0.0f;
    float q_p95 = 0.0f;
};

// 整图一次调用，没有 [begin, end) 版本，这不是偷懒：
//   - 汇流是 Kahn 拓扑序（叶→出口），队列顺序即数据依赖，切不开；
//   - 孤儿格 flush 依赖汇流跑完后剩下的 child_count；
//   - 河岸与运河段都往邻格写 SOIL/WB30，分段就有写竞态；
//   - 运河传播是 max-heap 松弛，且淡水优先的平局规则依赖全局松弛顺序。
// 只有本地水平衡、moisture 收敛与 plant_available_water 三段是逐格独立的，单独切
// 出来并行收益不足以抵掉三次同步，所以整段串行。
void hydrology_pass_pure(const HydrologyKnobs &knobs,
                         const HydrologyLanes &lanes,
                         HydrologyCanalState &canal,
                         HydrologyScratch &scratch,
                         HydrologyStats &stats);

// 生产 stage 12 当天真正读到的输入，供 worker 对拍。与 weather 同理：hydrology 跑在
// weather 之后，environment 快照那份降水/天气类型是 tick 起始拍的。
struct HydrologyInput {
    HydrologyKnobs knobs;
    int  n_cells = 0;
    bool ran = false;
    bool has_neighbors = false;

    std::vector<uint8_t> has_river;
    std::vector<uint8_t> terrain;
    std::vector<uint8_t> landform;
    std::vector<uint8_t> vegetation;
    std::vector<uint8_t> cover;
    std::vector<float>   elevation;
    std::vector<float>   precip;
    std::vector<float>   intensity;
    std::vector<uint8_t> weather_type;
    std::vector<float>   temp;
    std::vector<float>   heat;
    std::vector<float>   snowpack;
    std::vector<float>   base_moisture;
    std::vector<uint8_t> is_water;
    std::vector<float>   vitality;
    std::vector<uint8_t> canal_mask;
    // soil_moisture 与 discharge_30d 都是 in/out 的累积量，却没有 RuntimeClimateStore
    // 成员可承接。记生产读到的初值，worker 用 scratch 接一下、输出丢弃。不记的
    // 后果很具体：Q30 从零起步 → 河岸增湿 bank_gain 偏小 → SOIL/WB30 整场偏移。
    std::vector<float>   soil_moisture;
    std::vector<float>   discharge_30d;
    // canal_water 同样是 in/out 且跨日存活。漏记它的后果比 Q30 更凶：worker 的
    // scratch 只在首次分配，之后带着自己那份独立累积往邻格灌水，几轮之后把 moisture
    // 与 plant_available_water 顶到饱和 1.0（生产侧同格是 0.2~0.36）。
    std::vector<float>   canal_water;
    // 运河拓扑代号。worker 侧的编译缓存按它失效，所以必须跟着输入一起过来。
    uint64_t canal_topology_generation = 0;
};
