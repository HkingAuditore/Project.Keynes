#pragma once

// S3：Climate 生产 pass 的共享纯内核缓冲。runtime_climate_passes.h 与本文件一样
// 不依赖 Godot，所以把 ClimateInputBuf 编入环境快照不会破坏"跨线程边界只允许传
// Godot 无关值"这条约束。
#include "runtime_climate_passes.h"
#include "runtime_climate_physics.h"
#include "economy_graph_kernels.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <limits>
#include <string>
#include <type_traits>
#include <vector>

namespace pk {

struct CountryPeerContext;

template <size_t N>
inline void runtime_copy_text(char (&destination)[N], const char *source) noexcept {
    static_assert(N > 0, "runtime diagnostic buffers must not be empty");
    size_t index = 0;
    if (source != nullptr) {
        for (; index + 1u < N && source[index] != '\0'; ++index)
            destination[index] = source[index];
    }
    destination[index] = '\0';
    for (++index; index < N; ++index) destination[index] = '\0';
}

// These types are deliberately independent of Godot.  They are the only
// values allowed to cross the NativeSimulationHost thread boundary.
constexpr uint32_t RUNTIME_COMMAND_QUEUE_CAPACITY = 4096u;
constexpr uint32_t RUNTIME_RECEIPT_QUEUE_CAPACITY = 8192u;
constexpr uint32_t RUNTIME_MAX_COMMAND_PAYLOAD = 1024u;
constexpr uint32_t RUNTIME_SNAPSHOT_RING_SIZE = 3u;
constexpr uint32_t RUNTIME_DIRTY_FAMILY_COUNT = 9u;
constexpr uint32_t RUNTIME_DOMAIN_INTENT_CAPACITY = 8192u;
constexpr uint32_t RUNTIME_DOMAIN_EVENT_CAPACITY = 8192u;
// Country -> Economy asset requests use a separate bounded transport.  The
// request is a semantic transaction record, not a copy of the Economy store;
// large/variable data stays in the main-thread Economy coordinator until the
// operation is explicitly admitted.
constexpr uint32_t RUNTIME_ECONOMY_ASSET_QUEUE_CAPACITY = 8192u;
constexpr uint32_t RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY = 32u;
// Stage layout v3 adds an explicit input-capture barrier and gives Climate
// its own domain bit.  Keep this independent from the legacy host envelope.
constexpr uint32_t RUNTIME_DOMAIN_STAGE_COUNT = 12u;
constexpr uint32_t RUNTIME_ALL_DOMAIN_MASK =
    (1u << RUNTIME_DOMAIN_STAGE_COUNT) - 1u;
constexpr uint32_t RUNTIME_DOMAIN_ABI_VERSION = 1u;
// POD section ABI is independently versioned from the legacy host envelope;
// the latter remains v1 so existing command/commit clients can continue to
// consume SHADOW diagnostics while the worker state wire shape evolves.
constexpr uint32_t RUNTIME_DOMAIN_POD_ABI_VERSION = 3u;
// PKSR is the immutable runtime envelope inside the PKSV v2 container.  A
// version bump is intentional: v1 did not carry an explicit ABI/section
// header and must be rejected instead of being guessed at restore time.
constexpr uint32_t RUNTIME_SAVE_BUNDLE_VERSION = 2u;
constexpr uint32_t RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE = 1u << 0;
constexpr uint32_t RUNTIME_SAVE_SECTION_DOMAIN_POD = 1u << 1;
constexpr uint32_t RUNTIME_SAVE_SECTION_CLIMATE = 1u << 2;
constexpr uint32_t RUNTIME_SAVE_SECTION_COUNTRY = 1u << 3;
// Stage H owns the first post-Country section bit.  Keep the later reserved
// domain bits distinct so a Trigger section cannot be mistaken for Modifier.
constexpr uint32_t RUNTIME_SAVE_SECTION_TRIGGER = 1u << 4;
constexpr uint32_t RUNTIME_SAVE_SECTION_MODIFIER = 1u << 5;
constexpr uint32_t RUNTIME_SAVE_SECTION_EVENTS = 1u << 6;
// F2-F6 keeps Effect in its own immutable POD section. This is deliberately
// separate from the legacy PKEF facade section and is not an ACTIVE gate.
constexpr uint32_t RUNTIME_SAVE_SECTION_EFFECT = 1u << 7;
constexpr uint32_t RUNTIME_SAVE_SECTION_IDEOLOGY = 1u << 8;
// D7 Country/Economy transaction journal section. Orthogonal to Economy POD
// authority; persists Host peer request/result continuation state only.
constexpr uint32_t RUNTIME_SAVE_SECTION_ECONOMY_ASSET = 1u << 9;
// Economy POD (ECP1) graph authority section. Orthogonal to D7T1 asset journal.
constexpr uint32_t RUNTIME_SAVE_SECTION_ECONOMY_POD = 1u << 10;

static_assert(RUNTIME_COMMAND_QUEUE_CAPACITY == 4096u,
              "runtime command queue capacity is part of the ABI");
static_assert(RUNTIME_RECEIPT_QUEUE_CAPACITY == 8192u,
              "runtime receipt queue capacity is part of the ABI");
static_assert(RUNTIME_MAX_COMMAND_PAYLOAD == 1024u,
              "runtime command payload limit is part of the ABI");

static_assert(RUNTIME_DOMAIN_STAGE_COUNT == 12u,
              "runtime domain barrier must contain exactly twelve stages");

enum class RuntimeWorkerState : uint8_t {
    STOPPED = 0,
    STARTING = 1,
    RUNNING = 2,
    PAUSED = 3,
    SAVE_PENDING = 4,
    STOPPING = 5,
    FAULTED = 6,
};

enum class RuntimeSimulationMode : uint8_t {
    OFF = 0,
    SHADOW = 1,
    ACTIVE = 2,
};

enum RuntimeDirtyFamily : uint32_t {
    RUNTIME_DIRTY_CLOCK = 1u << 0,
    RUNTIME_DIRTY_COUNTRY_STATE = 1u << 1,
    RUNTIME_DIRTY_COUNTRY_TERRITORY = 1u << 2,
    RUNTIME_DIRTY_COUNTRY_VISUAL_ERA = 1u << 3,
    RUNTIME_DIRTY_CLIMATE_FIELDS = 1u << 4,
    RUNTIME_DIRTY_WEATHER = 1u << 5,
    RUNTIME_DIRTY_ECONOMY_UI = 1u << 6,
    RUNTIME_DIRTY_EVENTS = 1u << 7,
    RUNTIME_DIRTY_OVERLAY = 1u << 8,
};

struct RuntimeCommandEnvelope {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    uint16_t domain = 0;
    uint16_t opcode = 0;
    uint32_t payload_offset = 0;
    uint32_t payload_size = 0;
};

struct RuntimeCommandPacket {
    RuntimeCommandEnvelope envelope;
    // Assigned exactly once by the accepting Host queue. It is deliberately
    // outside the legacy wire envelope so PKSR v2 remains readable while the
    // live worker preserves Country's production ordering.
    uint64_t submit_order = 0;
    std::array<uint8_t, RUNTIME_MAX_COMMAND_PAYLOAD> payload{};
};

// Climate 没有 worker command 枚举。B8-6 删掉了曾经的 5 个 opcode
// (NOOP/SET_POLICY/FORCE_STAGE_MASK/REQUEST_VISUAL_ACK/REQUEST_ECONOMY_ACK)：
// 全仓库没有消费者，而它们描述的三件事各有正式通道 ——
//   * policy / stage mask  → 每 tick 环境快照里的 climate_round_scalars 与
//                            stage knobs（唯一策略输入）；
//   * 脏信号               → day commit 的 dirty_families；
//   * 跨域通知             → 既有 RuntimeDomainIntent / ACK ring。
// 命令枚举必须有消费者才存在；预留空枚举只会让协议看起来比实际多一层，
// 而下一轮排查又要花时间证明它确实没人读。

// Events commands use an explicit little-endian payload. APPEND_BATCH carries
// a bounded array of RuntimeEventsIngressRecord values; the worker assigns IDs
// only after it has sorted commands by the shared protocol ordering.
enum class RuntimeEventsCommand : uint16_t {
    APPEND_BATCH = 1,
    ACK_CONSUMER = 2,
    CONFIGURE_CAPACITY = 3,
    CLEAR_RESET = 4,
};

enum class RuntimeReceiptCode : uint16_t {
    OK = 0,
    INVALID_PAYLOAD = 1,
    INVALID_VALUE = 2,
    PREFLIGHT_REJECTED = 3,
    WORKER_FAULTED = 4,
    QUEUE_CAPACITY_EXCEEDED = 5,
};

struct RuntimeCommandReceipt {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    int64_t effective_day = 0;
    uint64_t generation = 0;
    RuntimeReceiptCode code = RuntimeReceiptCode::OK;
};

// Self-describing section descriptor used inside PKSR v2. The payload itself
// is an immutable byte span owned by RuntimeSaveBundle; no worker pointer is
// ever serialized or exposed to Godot.
struct RuntimeDomainSaveSection {
    uint16_t domain = 0;
    uint16_t version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    uint32_t payload_offset = 0;
    uint32_t payload_size = 0;
    uint64_t checksum = 0;
};

struct RuntimeEnvironmentSnapshot {
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

// Shared validation for the main-thread facade and the worker publish gate.
// This function is intentionally Godot-free so tests can exercise the exact
// boundary without constructing a DCWorldExt object.
bool validate_runtime_environment_snapshot(const RuntimeEnvironmentSnapshot &snapshot,
                                           std::string &error);

// Fixed order for the native daily barrier.  The enum and the array below are
// deliberately independent from Godot scheduler names; domain migration can
// therefore add a POD handler without changing the worker protocol.
enum class RuntimeDomainId : uint16_t {
    INPUT_CAPTURE = 1,
    CLIMATE = 2,
    COUNTRY = 3,
    TRIGGER_INPUT = 4,
    IDEOLOGY = 5,
    EFFECT = 6,
    MODIFIER = 7,
    GAMEPLAY_EFFECT = 8,
    ECONOMY = 9,
    EVENTS = 10,
    VISUAL = 11,
    COMMIT = 12,
};

static_assert((1u << static_cast<uint16_t>(RuntimeDomainId::CLIMATE)) !=
              (1u << static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT)),
              "Climate and Trigger input must have distinct capability bits");
static_assert(RUNTIME_ALL_DOMAIN_MASK == 0xFFFu,
              "ABI v3 capability mask must cover all twelve stages");

// Stable stage order shared by every worker implementation. Keeping this in
// the protocol (rather than duplicating an array in each domain) makes a
// shadow world and an active world use the same barrier even while individual
// handlers are being migrated.
constexpr std::array<RuntimeDomainId, RUNTIME_DOMAIN_STAGE_COUNT>
runtime_domain_stage_order() {
    return {
        RuntimeDomainId::INPUT_CAPTURE,
        RuntimeDomainId::CLIMATE,
        RuntimeDomainId::COUNTRY,
        RuntimeDomainId::TRIGGER_INPUT,
        RuntimeDomainId::IDEOLOGY,
        RuntimeDomainId::EFFECT,
        RuntimeDomainId::MODIFIER,
        RuntimeDomainId::GAMEPLAY_EFFECT,
        RuntimeDomainId::ECONOMY,
        RuntimeDomainId::EVENTS,
        RuntimeDomainId::VISUAL,
        RuntimeDomainId::COMMIT,
    };
}

constexpr uint32_t runtime_domain_mask(RuntimeDomainId domain) {
    const uint16_t value = static_cast<uint16_t>(domain);
    return value >= 1u && value <= RUNTIME_DOMAIN_STAGE_COUNT
        ? (1u << (value - 1u)) : 0u;
}

static_assert(RUNTIME_DOMAIN_STAGE_COUNT == 12u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::INPUT_CAPTURE) == 1u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::CLIMATE) == 2u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::COUNTRY) == 3u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT) == 4u);
static_assert(static_cast<uint16_t>(RuntimeDomainId::COMMIT) == 12u);
static_assert(runtime_domain_mask(RuntimeDomainId::CLIMATE) !=
              runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT));
static_assert(RUNTIME_ALL_DOMAIN_MASK ==
              ((1u << RUNTIME_DOMAIN_STAGE_COUNT) - 1u));

struct RuntimeDayContext {
    int64_t day = 0;
    double season_phase = 0.0;
    double speed_scale = 1.0;
    uint64_t input_generation = 0;
    // Points at a worker-owned immutable snapshot for the duration of one
    // day. It is never retained by a domain after the day barrier returns.
    const RuntimeEnvironmentSnapshot *environment = nullptr;
};

// Common metadata carried by every real domain plan/commit.  The record is
// POD-only; dynamic payloads remain in the owning immutable snapshot or in a
// preallocated intent arena.
struct RuntimeDomainHeader {
    uint16_t domain = 0;
    uint16_t abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint32_t dirty_families = 0;
    uint64_t state_hash = 0;
    uint64_t work_units = 0;
    uint32_t intent_count = 0;
    uint32_t ack_count = 0;
    uint8_t preflight_ok = 1;
    uint8_t reserved[3]{};
    char fallback_reason[64]{};
};

struct RuntimeDomainPlan {
    RuntimeDomainId domain = RuntimeDomainId::COUNTRY;
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint8_t completed = 0;
};

struct RuntimeDayPlan {
    RuntimeDayContext context;
    std::array<RuntimeDomainPlan, RUNTIME_DOMAIN_STAGE_COUNT> stages{};
    uint32_t stage_count = RUNTIME_DOMAIN_STAGE_COUNT;
};

// Compact worker-local result. Dynamic visual intents and command receipts are
// copied to RuntimeCommit separately, so this summary stays trivially copyable.
struct RuntimeDayCommit {
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint32_t completed_stage_count = 0;
    uint32_t completed_domain_mask = 0;
    uint64_t state_hash = 0;
    uint8_t preflight_ok = 1;
    // Country/Economy peer barriers may leave the day incomplete while the
    // worker keeps ownership. The host uses this to keep the day open without
    // advancing the authoritative committed watermark.
    uint8_t continuation_pending = 0;
};

// Domain ABI result. A handler must fill this record without constructing a
// Godot value. `preflight_ok=0` is a deterministic barrier failure; the host
// turns it into a command receipt/fault according to the domain policy.
struct RuntimeDomainCommit {
    RuntimeDomainId domain = RuntimeDomainId::COUNTRY;
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint64_t state_hash = 0;
    uint32_t intent_count = 0;
    uint32_t ack_count = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
    char fallback_reason[64]{};
};

// Shared cross-domain POD records. Keeping one definition in the protocol
// prevents each adapter from silently inventing different ACK or intent
// semantics while the domains are migrated one at a time.
enum class RuntimeDomainAckCode : uint16_t {
    OK = 0,
    RETRY = 1,
    REJECTED = 2,
    STALE_GENERATION = 3,
};

struct RuntimeDomainAck {
    uint64_t request_id = 0;
    uint64_t transaction_id = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    uint16_t domain = 0;
    RuntimeDomainAckCode code = RuntimeDomainAckCode::OK;
    int64_t effective_day = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    // Country peer ACKs may carry the committed technology state so the
    // worker can complete a pending activation without reaching into the
    // Effect/Modifier store. Other domains leave this at zero.
    uint8_t technology_flags = 0;
    uint8_t reserved_technology_flags[7]{};
};

constexpr uint16_t RUNTIME_DOMAIN_INTENT_DEFERRED = 1u << 0;
constexpr uint16_t RUNTIME_DOMAIN_INTENT_REQUIRES_ACK = 1u << 1;

struct RuntimeDomainIntent {
    uint16_t source_domain = 0;
    uint16_t target_domain = 0;
    uint16_t opcode = 0;
    uint16_t flags = 0;
    uint64_t source_id = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int64_t value = 0;
    int64_t effective_day = 0;
    std::array<int64_t, 4> payload{};
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    // Fixed Modifier command lanes. Generic domains may leave these at their
    // defaults; Effect uses them so duration/stack/magnitude survive the POD
    // handoff without an opaque byte payload.
    int32_t duration_days = -2;
    int32_t stacks = 1;
    int32_t magnitude_q16 = 65536;
    int32_t reserved = 0;
    uint64_t group_handle = 0;
    uint64_t modifier_handle = 0;
    // Effect fills these lanes with the typed action (1..6) and the stable
    // command idempotency identity. Other domains leave them at zero.
    uint16_t effect_action = 0;
    uint16_t reserved_effect = 0;
    uint32_t reserved_effect_flags = 0;
    uint64_t idempotency_key = 0;
};

// K2-B Country/Economy transaction wire contract.  These records are fixed
// size and trivially copyable so the worker can publish them without exposing
// a Godot value or a mutable Economy container.  The business state machine
// is intentionally explicit: after Country has prepared its side, the peer
// may only advance the same transaction identity; it must never create a new
// transaction to retry a post-decision step.
enum class RuntimeEconomyAssetOperation : uint16_t {
    RESEARCH_PURCHASE = 1,
    FISCAL_RESERVE = 2,
    FISCAL_RETURN = 3,
    FISCAL_COLLECT = 4,
    CASH_TO_COHORT = 5,
    CASH_FROM_COHORT = 6,
    GOOD_TO_MARKET = 7,
    GOOD_FROM_MARKET = 8,
    TREASURY_SPEND = 9,
};

enum class RuntimeEconomyAssetState : uint8_t {
    CREATED = 1,
    COUNTRY_PREPARED = 2,
    PEER_PREPARED = 3,
    COMMIT_DECIDED = 4,
    COUNTRY_APPLIED = 5,
    PEER_APPLIED = 6,
    COMPLETED = 7,
    REJECTED = 8,
    AWAITING_PEER_PREPARED = 9,
    AWAITING_PEER_APPLIED = 10,
    FAULTED = 11,
};

enum class RuntimeEconomyAssetResultCode : uint8_t {
    ACCEPTED = 0,
    PENDING = 1,
    PEER_PREPARED = 2,
    COMMIT_DECIDED = 3,
    PEER_APPLIED = 4,
    COMPLETED = 5,
    REJECTED = 6,
    FAULTED = 7,
};

enum class RuntimeEconomyAssetProtocolError : uint16_t {
    NONE = 0,
    PROTOCOL_MISMATCH = 1,
    REQUEST_INVALID = 2,
    REQUEST_UNKNOWN = 3,
    REQUEST_DUPLICATE_MISMATCH = 4,
    RESULT_IDENTITY_MISMATCH = 5,
    RESULT_STATE_INVALID = 6,
    RESULT_DUPLICATE_MISMATCH = 7,
    SESSION_MISMATCH = 8,
    GENERATION_MISMATCH = 9,
    CAPACITY_EXCEEDED = 10,
};

constexpr uint32_t RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION = 1u;
constexpr size_t RUNTIME_ECONOMY_ASSET_REASON_CAPACITY = 64u;

struct RuntimeEconomyAssetRequest {
    uint32_t protocol_version = RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION;
    RuntimeEconomyAssetOperation operation =
        RuntimeEconomyAssetOperation::RESEARCH_PURCHASE;
    RuntimeEconomyAssetState state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    uint8_t all_or_nothing = 0;
    uint8_t reserved0 = 0;
    uint16_t reserved1 = 0;
    uint64_t session_epoch = 0;
    uint64_t transaction_id = 0;
    uint64_t request_id = 0;
    uint32_t origin_domain = static_cast<uint32_t>(RuntimeDomainId::COUNTRY);
    int64_t origin_epoch = -1;
    int32_t origin_stage = -1;
    uint32_t continuation_index = 0;
    int64_t day = -1;
    uint64_t operation_sequence = 0;
    uint64_t country_generation = 0;
    uint64_t peer_generation = 0;
    uint64_t country_handle = 0;
    int32_t country_slot = -1;
    int32_t target_slot = -1;
    uint64_t target_handle = 0;
    int32_t good_id = -1;
    uint32_t good_count = 0;
    std::array<int32_t, RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY> good_ids{};
    std::array<int64_t, RUNTIME_ECONOMY_ASSET_GOOD_CAPACITY> good_quantities{};
    int64_t requested_quantity = 0;
    int64_t prepared_quantity = 0;
    int64_t requested_cash = 0;
    int64_t reserved_cash = 0;
    int64_t requested_goods_total = 0;
    int64_t reserved_goods_total = 0;
};

struct RuntimeEconomyAssetResult {
    uint32_t protocol_version = RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION;
    RuntimeEconomyAssetResultCode code = RuntimeEconomyAssetResultCode::REJECTED;
    RuntimeEconomyAssetState state = RuntimeEconomyAssetState::REJECTED;
    uint8_t accepted = 0;
    uint8_t reserved0 = 0;
    uint16_t reserved1 = 0;
    uint64_t session_epoch = 0;
    uint64_t transaction_id = 0;
    uint64_t request_id = 0;
    RuntimeEconomyAssetOperation operation =
        RuntimeEconomyAssetOperation::RESEARCH_PURCHASE;
    uint32_t continuation_index = 0;
    int64_t day = -1;
    uint64_t country_generation = 0;
    uint64_t peer_generation = 0;
    uint64_t committed_peer_generation = 0;
    int32_t country_slot = -1;
    int32_t target_slot = -1;
    int64_t committed_quantity = 0;
    int64_t committed_cash = 0;
    int64_t committed_goods_total = 0;
    std::array<char, RUNTIME_ECONOMY_ASSET_REASON_CAPACITY> reason{};
};

struct RuntimeEconomyAssetProtocolStatus {
    uint32_t protocol_version = RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION;
    uint32_t queued_requests = 0;
    uint32_t pending_requests = 0;
    uint32_t terminal_requests = 0;
    uint32_t rejected_results = 0;
    uint32_t faulted_transactions = 0;
    uint32_t recovered_transactions = 0;
    uint32_t duplicate_messages = 0;
    uint64_t session_epoch = 0;
    uint64_t last_transaction_id = 0;
    uint64_t last_request_id = 0;
    RuntimeEconomyAssetProtocolError last_error =
        RuntimeEconomyAssetProtocolError::NONE;
    std::array<char, RUNTIME_ECONOMY_ASSET_REASON_CAPACITY> last_reason{};
};

struct RuntimeDomainTiming {
    uint64_t work_units = 0;
    uint32_t intent_count = 0;
    uint32_t ack_count = 0;
    uint64_t state_hash = 0;
    double elapsed_ms = 0.0;
};

struct RuntimeDomainReport {
    RuntimeDomainId domain = RuntimeDomainId::COMMIT;
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint32_t dirty_families = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
    uint8_t fallback = 0;
    uint8_t reserved = 0;
    char fallback_reason[64]{};
    RuntimeDomainTiming timing{};
};

struct RuntimeDomainSnapshot {
    RuntimeDomainHeader header{};
    std::vector<uint8_t> payload;
};

static_assert(std::is_trivially_copyable_v<RuntimeDomainAck>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainIntent>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyAssetRequest>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyAssetResult>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyAssetProtocolStatus>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainTiming>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainReport>);

// Economy is the first large cross-domain migration target. These records are
// intentionally handle/index based: all strings, Dictionaries and catalog
// lookups stay on the main-thread facade or cold bootstrap path.
struct RuntimeEconomyDayContext {
    int64_t day = 0;
    uint64_t input_generation = 0;
    uint64_t country_generation = 0;
    uint64_t modifier_generation = 0;
    const RuntimeEnvironmentSnapshot *environment = nullptr;
};

struct RuntimeEconomyDayCommit {
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    uint64_t state_hash = 0;
    uint32_t changed_cells = 0;
    uint32_t changed_cohorts = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
};

// Country-domain ABI used by the Phase B adapter.  These records are
// deliberately smaller than the Godot-facing country report: a worker may
// pass them between fixed stages without constructing dynamic Godot values.
// The adapter is currently opt-in; the legacy facade remains authoritative
// until all country command/economy barriers are migrated.
struct RuntimeCountryDayContext {
    int64_t day = 0;
    double speed_scale = 1.0;
    uint64_t input_generation = 0;
    // Immutable peer facts captured at the semantic Country boundary.  The
    // pointer is borrowed for one cooperative step and is never retained by a
    // worker after the call returns.
    const CountryPeerContext *peer_context = nullptr;
};

enum class RuntimeCountryPodError : uint16_t {
    NONE = 0,
    NOT_BOOTSTRAPPED = 1,
    INVALID_CONTEXT = 2,
    COMMAND_BATCH_PENDING = 3,
    CROSS_DOMAIN_BARRIER_REQUIRED = 4,
    COMMAND_REJECTED = 5,
};

struct RuntimeCountryDayCommit {
    uint32_t dirty_families = 0;
    uint32_t changed_countries = 0;
    uint32_t changed_territory_cells = 0;
    uint64_t research_work_units = 0;
    uint64_t state_hash = 0;
    uint64_t country_generation = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 0;
    uint8_t ack_required = 0;
    uint8_t reserved = 0;
    RuntimeCountryPodError error_code = RuntimeCountryPodError::NONE;
};

// Immutable, worker-safe country input.  This is intentionally a numeric
// projection of NativeCountryRuntime: strings, Godot values and peer-runtime
// pointers never cross the simulation thread boundary.  The vectors are
// copied once at a main-thread capture boundary and then treated as const by
// the POD adapter.
struct RuntimeCountryPodSnapshot {
    // Transport identity captured with the immutable input. Zero is retained
    // for older diagnostic fixtures and normalized by the worker authority.
    uint64_t session_epoch = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    int64_t committed_day = -1;
    int64_t last_research_day = -1;
    uint32_t cell_count = 0;
    uint32_t country_count = 0;
    uint32_t technology_words = 0;
    uint32_t technology_count = 0;
    uint32_t good_count = 0;
    uint32_t profession_count = 0;
    uint32_t building_type_count = 0;
    uint32_t research_signal_words = 0;
    uint32_t research_signal_count = 0;
    // Catalog identity is captured with the immutable country projection. A
    // worker must reject a snapshot whose catalog is not the one it was
    // bootstrapped against; strings and Godot catalog objects never cross the
    // worker boundary.
    uint64_t catalog_hash = 0;
    bool bootstrapped = false;
    bool research_active_index_valid = false;
    std::vector<uint8_t> country_active;
    std::vector<uint32_t> country_generation;
    // Identity strings are copied once at the command/snapshot boundary. They
    // never participate in the numeric hot loop, but CREATE/RENAME must still
    // have the same durable semantics as the synchronous core.
    std::vector<std::string> country_stable_ids;
    std::vector<std::string> country_display_names;
    // Sorted dense slots whose research state can make progress on the next
    // day.  This is a derived membership index captured from Country's
    // native hot loop; an empty vector is accepted for compatibility and
    // means the adapter must conservatively scan all country slots.
    std::vector<int32_t> research_active_country_slots;
    std::vector<int32_t> territory_count;
    std::vector<uint64_t> country_state_version;
    std::vector<int64_t> country_cash;
    std::vector<int64_t> country_goods;
    std::vector<int32_t> cell_country_slot;
    std::vector<int32_t> territory_offsets;
    std::vector<int32_t> territory_cells;
    std::vector<uint64_t> country_technologies;
    std::vector<uint64_t> country_discovered;
    std::vector<uint64_t> country_pending_technologies;
    std::vector<uint64_t> country_research_signals;
    std::vector<int32_t> research_signal_cell_offsets;
    std::vector<uint64_t> research_signal_cells;
    std::vector<int32_t> research_signal_evidence_offsets;
    struct SignalEvidence {
        int32_t signal = -1;
        int32_t count = 0;
        int64_t first_day = -1;
        int64_t last_day = -1;
        int32_t first_cell = -1;
    };
    std::vector<SignalEvidence> research_signal_evidence;
    std::vector<int32_t> research_queues;
    std::vector<uint8_t> research_queue_lengths;
    std::vector<int32_t> research_weights_bp;
    std::vector<int64_t> research_daily_budgets;
    std::vector<int64_t> research_deferred_points;
    std::vector<int64_t> research_progress_total;
    std::vector<int64_t> research_completed_total;
    // Per-technology progress is required for deterministic plan/replay. The
    // legacy probe only exported aggregate totals; a worker authority must
    // reject captures that omit this matrix.
    std::vector<int64_t> research_progress;
    // Peer modifier inputs captured at the same semantic boundary. They are
    // required for deterministic completion-day arithmetic and are not a
    // second mutable authority.
    std::vector<double> research_cost_factor;
    std::vector<double> research_efficiency;
    // Dense numeric flags for pending technology peer state. A value is the
    // OR of CountryPeerTechnologyState flags for (country, technology).
    std::vector<uint8_t> research_peer_flags;
    std::vector<uint8_t> research_auto_purchase;
    std::vector<int64_t> research_purchased_total;
    std::vector<int64_t> research_consumed_total;
    static constexpr uint32_t TAX_KIND_COUNT = 5u;
    std::vector<int32_t> country_tax_defaults;
    std::vector<int32_t> country_tax_default_modes;
    std::vector<int32_t> country_income_tax_overrides;
    std::vector<int32_t> country_consumption_tax_overrides;
    std::vector<int32_t> country_business_tax_overrides;
    std::vector<int32_t> country_import_tax_overrides;
    std::vector<int32_t> country_export_tax_overrides;
    std::vector<int32_t> country_income_tax_mode_overrides;
    std::vector<int32_t> country_consumption_tax_mode_overrides;
    std::vector<int32_t> country_business_tax_mode_overrides;
    std::vector<int32_t> country_import_tax_mode_overrides;
    std::vector<int32_t> country_export_tax_mode_overrides;
    struct CellTaxOverride {
        int32_t kind = -1;
        int32_t item = -1;
        int32_t rate = std::numeric_limits<int32_t>::min();
        int32_t mode = std::numeric_limits<int32_t>::min();
    };
    struct CellTaxPolicy {
        std::array<int32_t, TAX_KIND_COUNT> defaults{};
        std::array<int32_t, TAX_KIND_COUNT> modes{};
        std::vector<CellTaxOverride> overrides;
    };
    std::vector<uint32_t> cell_tax_policy_ids;
    std::vector<CellTaxPolicy> cell_tax_policies;
    std::vector<uint8_t> is_water;
};

// Main-thread read view for a committed worker Country state. `generation` is
// the monotonic publication cursor, not necessarily the Country business
// generation: a rejected peer boundary may commit Country-side state without
// advancing the business generation, and must still be visible to readers.
// The snapshot remains immutable and owned by the host; the patch is the only
// territory payload copied for the normal publish path. `full_snapshot_required` is
// set when a consumer has missed the immediately preceding generation and
// therefore cannot safely apply the retained sparse patch by itself.
struct RuntimeCountryReadView {
    bool available = false;
    bool full_snapshot_required = false;
    uint64_t generation = 0;
    uint64_t patch_base_generation = 0;
    int64_t committed_day = -1;
    uint64_t state_hash = 0;
    uint32_t dirty_families = 0;
    uint64_t territory_watermark = 0;
    uint64_t research_watermark = 0;
    uint64_t tax_watermark = 0;
    uint64_t visual_watermark = 0;
    uint32_t country_count = 0;
    uint32_t cell_count = 0;
    std::vector<int32_t> changed_cells;
    std::vector<int32_t> changed_owners;
    std::shared_ptr<const RuntimeCountryPodSnapshot> snapshot;
};

// Numeric, immutable catalog compiled by the main-thread facade before a
// worker is started. Strings and Godot catalog objects never cross the worker
// boundary. The condition CSR is explicit so a worker can reject an
// incomplete capture instead of guessing at reference semantics.
struct RuntimeCountryPodCatalog {
    uint64_t catalog_hash = 0;
    uint32_t technology_count = 0;
    uint32_t technology_words = 0;
    int32_t technology_points_good_id = -1;
    bool research_conditions_complete = false;
    std::vector<int64_t> technology_costs;
    std::vector<int32_t> technology_domains;
    std::vector<int32_t> technology_flags;
    // Stable numeric projection of whether a technology has a peer Effect /
    // Modifier activation requirement. String definition keys stay main-thread
    // catalog data and never cross into the worker.
    std::vector<uint8_t> technology_effect_required;
    std::vector<int32_t> prerequisite_offsets;
    std::vector<int32_t> prerequisites;
    std::vector<int32_t> milestone_offsets;
    std::vector<int32_t> milestone_candidates;
    std::vector<int32_t> milestone_required_counts;
    std::vector<int32_t> entry_milestone_indices;
    std::vector<int32_t> research_condition_offsets;
    std::vector<int32_t> research_condition_ops;
    std::vector<int32_t> research_condition_refs;
    std::vector<int64_t> research_condition_values;
    // Discovery/reveal conditions are distinct from queue eligibility. They
    // must cross the worker boundary because DISCOVER_COUNTRY_SIGNAL can make
    // technologies visible before they are researchable.
    std::vector<int32_t> reveal_condition_offsets;
    std::vector<int32_t> reveal_condition_ops;
    std::vector<int32_t> reveal_condition_refs;
    std::vector<int64_t> reveal_condition_values;
    std::vector<int32_t> starting_technologies;
};

struct RuntimeCountryPodDiagnostics {
    uint64_t snapshot_generation = 0;
    uint64_t state_hash = 0;
    uint64_t work_units = 0;
    uint32_t active_country_count = 0;
    uint32_t active_index_count = 0;
    uint32_t pending_checks = 0;
    uint32_t changed_country_count = 0;
    uint32_t changed_cell_count = 0;
    uint8_t ack_pending = 0;
    char blocker[64]{};
};

// Country command payload used by the Phase B adapter.  This is deliberately
// a fixed-size, string-free record: stable/display names and catalog ids are
// resolved on the Godot facade before a command crosses the worker boundary.
// The record is also useful to the synchronous reference path because it makes
// the validation contract identical before the full Country store is moved
// behind NativeSimulationHost.
constexpr uint32_t RUNTIME_COUNTRY_COMMAND_BATCH_CAPACITY = 256u;
constexpr uint32_t RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT = 4u;
constexpr size_t RUNTIME_COUNTRY_STABLE_ID_CAPACITY = 96u;
constexpr size_t RUNTIME_COUNTRY_DISPLAY_NAME_CAPACITY = 192u;

struct RuntimeCountryCommand {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    uint64_t submit_order = 0;
    uint64_t observed_generation = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    uint16_t opcode = 0;
    uint16_t reserved = 0;
    uint64_t target_handle = 0;
    int32_t cell = -1;
    int32_t aux = -1;
    int32_t domain = -1;
    int32_t position = -1;
    std::array<int32_t, RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT> weights_bp{
        {2500, 2500, 2500, 2500}};
    int32_t tax_kind = -1;
    int32_t tax_item = -1;
    int32_t tax_rate_basis_points = 0;
    int32_t tax_assessment_mode = 0;
    int64_t value = 0;
    std::array<char, RUNTIME_COUNTRY_STABLE_ID_CAPACITY> stable_id{};
    std::array<char, RUNTIME_COUNTRY_DISPLAY_NAME_CAPACITY> display_name{};
};

struct RuntimeCountryCommandBatch {
    uint32_t count = 0;
    std::array<RuntimeCountryCommand,
               RUNTIME_COUNTRY_COMMAND_BATCH_CAPACITY> commands{};
};

inline bool runtime_country_research_weights_valid(
        const std::array<int32_t, RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT> &weights) noexcept {
    int64_t total = 0;
    for (const int32_t weight : weights) {
        if (weight < 0 || weight > 10000) return false;
        total += weight;
    }
    return total == 10000;
}

static_assert(std::is_trivially_copyable_v<RuntimeCommandEnvelope>);
static_assert(std::is_trivially_copyable_v<RuntimeCommandPacket>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainHeader>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainSaveSection>);
static_assert(std::is_trivially_copyable_v<RuntimeDayContext>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainPlan>);
static_assert(std::is_trivially_copyable_v<RuntimeDayPlan>);
static_assert(std::is_trivially_copyable_v<RuntimeDayCommit>);
static_assert(std::is_trivially_copyable_v<RuntimeDomainCommit>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyDayContext>);
static_assert(std::is_trivially_copyable_v<RuntimeEconomyDayCommit>);
static_assert(std::is_trivially_copyable_v<RuntimeCountryDayContext>);
static_assert(std::is_trivially_copyable_v<RuntimeCountryDayCommit>);
static_assert(std::is_trivially_copyable_v<RuntimeCountryCommand>);
static_assert(std::is_trivially_copyable_v<RuntimeCountryCommandBatch>);

struct RuntimeCommitHeader {
    uint64_t generation = 0;
    int64_t from_day = 0;
    int64_t committed_day = 0;
    uint64_t produced_at_us = 0;
    uint32_t dirty_families = 0;
    uint64_t state_hash = 0;
    uint32_t command_receipt_count = 0;
    // Last commit generation that touched each dirty family, indexed by the
    // bit position in RuntimeDirtyFamily.  Keeping this in the immutable
    // header lets the main thread discard an old family patch independently
    // from newer clock/economy/event publications.
    std::array<uint64_t, RUNTIME_DIRTY_FAMILY_COUNT> dirty_family_generations{};
};

struct RuntimeVisualIntent {
    uint32_t family = 0;
    uint32_t cell_index = 0;
    uint32_t field_id = 0;
    int32_t value_i32 = 0;
    float value_f32 = 0.0f;
};

struct RuntimeCommit {
    RuntimeCommitHeader header;
    std::vector<RuntimeVisualIntent> visual_intents;
    std::vector<RuntimeCommandReceipt> receipts;
};

struct RuntimeThreadReport {
    uint32_t domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    uint32_t pod_domain_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    RuntimeWorkerState state = RuntimeWorkerState::STOPPED;
    RuntimeSimulationMode mode = RuntimeSimulationMode::OFF;
    bool graph_coverage_complete = false;
    // Coverage is a prerequisite, not proof that the worker owns gameplay
    // authority.  This remains false until every daily domain has a native
    // POD handler and the worker has completed the full barrier.
    bool authority_ready = false;
    uint32_t required_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    uint32_t implemented_domain_mask = 0;
    uint32_t missing_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    // Per-domain authority. `authority_ready` above keeps its whole-graph
    // meaning: it stays false until every domain has a POD handler. A domain
    // whose parity is proven can be promoted on its own before that, which is
    // what these two describe.
    //
    //   requested   = the mask the caller asked to own at start()
    //   authoritative = the subset the worker has actually proven at a barrier
    //
    // Main-thread schedule gates read `authoritative_domain_mask`, never
    // `authority_ready`; a partial promotion must suppress exactly the
    // promoted domains and leave the rest on the main thread.
    uint32_t requested_authority_mask = 0;
    uint32_t authoritative_domain_mask = 0;
    char graph_coverage_state[32]{};
    char coverage_blocker[64]{};
    bool interactive = false;
    bool paused = true;
    double speed_days_per_second = 0.0;
    int64_t committed_day = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t last_commit_produced_at_us = 0;
    uint64_t last_visual_publish_at_us = 0;
    double snapshot_staleness_ms = 0.0;
    // Main-thread visual timings are fed back through the facade. They stay in
    // the POD report so CSV/diagnostic consumers have one stable namespace.
    double ui_input_to_feedback_ms = 0.0;
    double visual_apply_ms = 0.0;
    double gpu_upload_ms = 0.0;
    // Facade calls are intentionally non-blocking.  Keep this explicit in
    // the report so a future bridge cannot silently introduce a wait.
    uint64_t main_wait_on_sim_us = 0;
    uint64_t environment_generation = 0;
    int64_t environment_day = 0;
    uint32_t environment_cell_count = 0;
    bool environment_topology_validated = false;
    uint64_t invalid_environment_rejected = 0;
    uint64_t stale_environment_rejected = 0;
    uint64_t command_queue_capacity_exceeded = 0;
    uint64_t receipt_queue_capacity_exceeded = 0;
    uint64_t snapshot_publish_drop_count = 0;
    uint64_t snapshot_publish_throttled_count = 0;
    uint64_t worker_fault_count = 0;
    uint64_t completed_days = 0;
    uint32_t day_stage_count = 0;
    uint32_t day_completed_stage_count = 0;
    uint64_t day_work_units = 0;
    // SHADOW-only worker ABI diagnostics. These fields describe the pure POD
    // pipeline even while implemented_domain_mask correctly remains partial.
    uint32_t pod_completed_domain_mask = 0;
    uint32_t pod_completed_stage_count = 0;
    uint64_t pod_work_units = 0;
    uint32_t pod_intent_count = 0;
    uint32_t pod_fallback_count = 0;
    bool economy_pod_ready = false;
    bool economy_pod_committed = false;
    bool economy_pod_authority_ready = false;
    int64_t economy_pod_committed_day = -1;
    int64_t economy_pod_epoch_sample_day = -1;
    uint64_t economy_pod_generation = 0;
    uint64_t economy_pod_state_hash = 0;
    uint64_t economy_pod_input_generation = 0;
    uint64_t economy_pod_country_generation = 0;
    uint32_t economy_pod_completed_stage_mask = 0;
    uint32_t economy_pod_pending_outbox = 0;
    uint32_t economy_pod_pending_inbox = 0;
    uint32_t economy_pod_operation_gate_mask = 0;
    uint32_t economy_pod_parity_ready_mask = 0;
    uint32_t economy_replay_completed_stage_mask = 0;
    uint32_t economy_replay_stage_cursor = 0;
    uint64_t economy_replay_input_hash = 0;
    uint64_t economy_replay_base_hash = 0;
    uint64_t economy_replay_next_hash = 0;
    std::array<uint64_t, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> economy_replay_stage_hash{};
    std::array<uint64_t, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> economy_replay_stage_work{};
    std::array<double, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> economy_replay_stage_ms{};
    bool economy_replay_input_captured = false;
    bool economy_replay_committed = false;
    bool economy_replay_parity_ready = false;
    char economy_replay_fallback_reason[64]{};
    // Consolidated SHADOW domain-authority runner metrics. These are
    // diagnostic only; implemented_domain_mask remains the promotion gate.
    uint32_t domain_authority_planned_mask = 0;
    uint32_t domain_authority_committed_mask = 0;
    uint32_t domain_authority_ack_count = 0;
    uint64_t domain_authority_input_hash = 0;
    uint64_t domain_authority_state_hash = 0;
    double domain_authority_plan_ms = 0.0;
    double domain_authority_replay_ms = 0.0;
    char domain_authority_fallback_reason[64]{};
    uint32_t domain_stage_fallback_count = 0;
    char domain_stage_fallback_reason[64]{};
    bool climate_pod_ready = false;
    double climate_pod_plan_ms = 0.0;
    double climate_pod_replay_ms = 0.0;
    uint64_t climate_pod_work_units = 0;
    uint32_t climate_pod_changed_cells = 0;
    uint64_t climate_pod_state_hash = 0;
    uint64_t climate_pod_reference_hash = 0;
    bool climate_pod_parity_compared = false;
    bool climate_pod_parity_matched = false;
    uint64_t climate_pod_parity_mismatch_count = 0;
    char climate_pod_parity_reason[64]{};
    int64_t climate_parity_day = -1;
    uint16_t climate_parity_stage = 0;
    uint32_t climate_parity_cell = 0;
    uint64_t climate_parity_input_generation = 0;
    uint64_t climate_parity_base_generation = 0;
    uint64_t climate_parity_trace_hash = 0;
    char climate_parity_field[48]{};
    char climate_parity_reference_bits[24]{};
    char climate_parity_worker_bits[24]{};
    char climate_pod_fallback_reason[64]{};
    // 1 << RuntimeClimateStage 的位掩码。差集（production & ~worker）= "生产算了、
    // worker 没算"，这是分叉矩阵里 stage 9..13 那些字段唯一可信的归因来源；缺了它
    // "worker 缺实现"和"这一天生产本来也没跑"在矩阵上长得一模一样。
    int32_t climate_production_stage_mask = 0;
    int32_t climate_worker_stage_mask = 0;
    // ── B8-2：worker 自持 cyclone 的当日事实 ─────────────────────────────
    // alive = 当天推进/淘汰后仍在 store blob 里的条目数；injected/replaced 是
    // 当天 genesis 的动作；decayed 是推进淘汰数；touched 是 stamp 覆盖格数。
    // 这四个数让 soak/C3 的 JSON 能直接判定"气旋有没有非平凡演化"，不必去
    // 解析 stderr 的 [climate/worker][b8] 诊断。
    int32_t climate_cyclone_alive = 0;
    int32_t climate_cyclone_injected = 0;
    int32_t climate_cyclone_replaced = 0;
    int32_t climate_cyclone_decayed = 0;
    int32_t climate_cyclone_touched = 0;
    // 逐 stage 的 worker 侧耗时与工作量，索引即 RuntimeClimateStage。
    // RuntimeClimateVerticalReport 早就有这两条，但没进 ThreadReport，GDScript 因此
    // 拿不到任何 per-stage 数据，performance.csv 只能记一个总的 climate_pod_plan_ms。
    // ACTIVE 下"哪个 stage 变慢了"必须能在不重编译的情况下回答。
    std::array<double, static_cast<size_t>(
        pk_async_climate::CLIMATE_STAGE_SLOT_COUNT)> climate_stage_ms{};
    std::array<uint64_t, static_cast<size_t>(
        pk_async_climate::CLIMATE_STAGE_SLOT_COUNT)> climate_stage_work{};
    // ── B8 P0：Climate 交付游标 ──────────────────────────────────────────
    // `climate_committed_day` 是 worker Climate store 的日，不是 worker 时钟；
    // `climate_consumed_generation` 统计 worker 实际尝试过 plan 的环境代次
    // （成功失败都算），所以主线程可以问"这一天输入被看到没有"，而不必等提交成功。
    //
    // environment_* 把"worker 慢"与"输入被覆盖/溢出"分开：FIFO ring 下未消费深度 =
    // pending；溢出丢弃 = dropped；SHADOW force 覆盖 = superseded。
    int64_t climate_committed_day = -1;
    uint64_t climate_consumed_generation = 0;
    uint64_t environment_published_days = 0;
    uint64_t environment_consumed_days = 0;
    uint64_t environment_superseded_days = 0;
    uint64_t environment_dropped_days = 0;
    uint64_t environment_ring_pending = 0;
    uint64_t climate_wait_total_ms = 0;
    uint64_t climate_wait_last_ms = 0;
    uint64_t climate_wait_max_ms = 0;
    uint32_t command_queue_depth = 0;
    uint32_t receipt_queue_depth = 0;
    double time_debt_days = 0.0;
    uint32_t climate_trace_depth = 0;
    int64_t climate_trace_front_day = -1;
    int64_t climate_trace_lag_days = 0;
    uint64_t climate_trace_latest_hash = 0;
    uint64_t climate_trace_capacity_exceeded = 0;
    uint64_t climate_trace_consumed = 0;
    uint64_t climate_trace_missing = 0;
    uint32_t climate_trace_captured = 0;
    uint32_t climate_trace_reference_ready = 0;
    uint32_t climate_trace_consumable = 0;
    uint64_t climate_trace_reference_rejected = 0;
    uint64_t climate_trace_reference_pending = 0;
      uint32_t executor_workers = 0;
      uint64_t country_pod_snapshot_generation = 0;
      uint64_t country_pod_state_hash = 0;
      uint64_t country_pod_work_units = 0;
      uint32_t country_pod_active_country_count = 0;
      uint32_t country_pod_active_index_count = 0;
    uint32_t country_pod_pending_checks = 0;
    bool country_pod_ack_pending = false;
    char country_pod_blocker[64]{};
    // Country worker transport status is copied into the immutable report
    // snapshot by NativeSimulationHost::report().  The Godot formatter must
    // only consume these fields; it cannot reach back into the host object.
    bool country_worker_configured = false;
    bool country_worker_plan_active = false;
    bool country_worker_waiting_for_peer = false;
    uint32_t country_worker_pending_intents = 0;
    uint32_t country_worker_queued_intents = 0;
    uint32_t country_worker_result_count = 0;
    uint32_t country_worker_rejected_results = 0;
    uint64_t country_worker_session_epoch = 0;
    uint64_t country_worker_country_generation = 0;
    int64_t country_worker_day = -1;
    uint32_t country_worker_continuation_index = 0;
    uint64_t country_worker_boundary_id = 0;
    uint64_t country_worker_last_admitted_submit_order = 0;
    uint64_t country_worker_expected_base_generation = 0;
    uint64_t country_worker_catalog_hash = 0;
    bool country_worker_authoritative = false;
    char country_worker_last_reason[64]{};
    uint8_t country_parity_compared = 0;
    uint8_t country_parity_matched = 0;
    uint64_t country_parity_compared_count = 0;
    uint64_t country_parity_matched_count = 0;
    int64_t country_parity_first_mismatch_day = -1;
    uint64_t country_parity_reference_hash = 0;
    uint64_t country_parity_worker_hash = 0;
    int32_t country_parity_index = -1;
    char country_parity_status[64]{};
    char country_parity_field[48]{};
    bool modifier_pod_ready = false;
    double modifier_pod_plan_ms = 0.0;
    double modifier_pod_replay_ms = 0.0;
    uint64_t modifier_pod_work_units = 0;
    uint64_t modifier_pod_state_hash = 0;
    uint64_t modifier_pod_snapshot_generation = 0;
    uint32_t modifier_pod_ack_count = 0;
    char modifier_pod_fallback_reason[64]{};
    // F7 SHADOW Effect Host stage telemetry. Effect remains outside
    // implemented_domain_mask until F8; these fields only prove the worker
    // day stage ran and never grant ACTIVE authority.
    bool effect_pod_ready = false;
    double effect_pod_plan_ms = 0.0;
    double effect_pod_replay_ms = 0.0;
    uint64_t effect_pod_state_hash = 0;
    uint64_t effect_pod_snapshot_generation = 0;
    uint32_t effect_pod_ack_count = 0;
    uint32_t effect_pod_intent_count = 0;
    char effect_pod_fallback_reason[64]{};
    bool ideology_pod_ready = false;
    double ideology_pod_plan_ms = 0.0;
    double ideology_pod_replay_ms = 0.0;
    uint64_t ideology_pod_state_hash = 0;
    uint64_t ideology_pod_snapshot_generation = 0;
    uint32_t ideology_pod_pending_transition_count = 0;
    uint32_t ideology_pod_intent_count = 0;
    char ideology_pod_fallback_reason[64]{};
    bool events_probe_enabled = false;
    bool events_pod_ready = false;
    double events_pod_plan_ms = 0.0;
    double events_pod_replay_ms = 0.0;
    uint64_t events_pod_state_hash = 0;
    uint64_t events_pod_snapshot_generation = 0;
    uint32_t events_pod_event_count = 0;
    uint32_t events_pod_ack_count = 0;
    uint64_t events_pod_drop_count = 0;
    char events_pod_fallback_reason[64]{};
    // Trigger POD SHADOW parity. These fields are diagnostic only and never
    // contribute to implemented_domain_mask or authoritative_domain_mask.
    int64_t trigger_parity_day = -1;
    int64_t trigger_reference_day = -1;
    uint64_t trigger_input_hash = 0;
    uint64_t trigger_reference_input_hash = 0;
    uint64_t trigger_reference_state_hash = 0;
    uint64_t trigger_worker_state_hash = 0;
    uint64_t trigger_reference_effect_hash = 0;
    uint64_t trigger_worker_effect_hash = 0;
    uint32_t trigger_required_ack_count = 0;
    uint32_t trigger_received_ack_count = 0;
    uint32_t trigger_pending_ack_count = 0;
    uint64_t trigger_generation = 0;
    int64_t trigger_committed_day = -1;
    int64_t trigger_acked_effect_id = 0;
    uint32_t trigger_pending_command_count = 0;
    uint8_t trigger_parity_compared = 0;
    uint8_t trigger_parity_matched = 0;
    int32_t trigger_first_divergence_index = -1;
    char trigger_first_divergence_kind[32]{};
    char trigger_blocker[64]{};
    // H7/H8 ACTIVE Trigger stage. The parity fields above describe the POD
    // authority against the synchronous reference frame; these describe the
    // worker stage that owns it.
    bool trigger_pod_ready = false;
    double trigger_pod_plan_ms = 0.0;
    double trigger_pod_replay_ms = 0.0;
    uint64_t trigger_pod_state_hash = 0;
    uint64_t trigger_pod_snapshot_generation = 0;
    uint32_t trigger_pod_intent_count = 0;
    uint32_t trigger_pod_ack_count = 0;
    char trigger_pod_fallback_reason[64]{};
    char fault_code[64]{};
};

// The bundle is immutable after publication.  It deliberately contains only
// bytes and scalar metadata so the Godot facade can copy it without exposing
// any runtime store or Godot object to the worker.
struct RuntimeSaveBundle {
    uint64_t request_id = 0;
    int64_t committed_day = 0;
    bool paused = true;
    double speed_days_per_second = 0.0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t environment_generation = 0;
    int64_t environment_day = 0;
    double climate_anomaly = 0.0;
    double time_debt_days = 0.0;
    uint32_t bundle_version = RUNTIME_SAVE_BUNDLE_VERSION;
    uint32_t runtime_domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    uint32_t section_mask = RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE;
    uint64_t checksum = 0;
    std::vector<uint8_t> bytes;
    // Commands that were already accepted by the host but had not reached a
    // day boundary when SAVE_REQUEST was observed. They stay in protocol order
    // and are restored into the worker's pending list before the next day.
    std::vector<RuntimeCommandPacket> pending_commands;
    std::vector<uint8_t> domain_pod_bytes;
    // Independent climate section. It is immutable bytes encoded by the
    // worker at a completed day barrier; Godot only copies/writes these bytes.
    std::vector<uint8_t> climate_bytes;
    // CPD2 v2 wraps the exact PKCN payload used by the normal Country provider
    // plus worker protocol metadata. country_pkcn_bytes is not another wire
    // section; it lets the save coordinator reuse the same capture.
    std::vector<uint8_t> country_bytes;
    std::vector<uint8_t> country_pkcn_bytes;
    std::vector<uint8_t> trigger_bytes;
    std::vector<uint8_t> modifier_bytes;
    std::vector<uint8_t> events_bytes;
    std::vector<uint8_t> effect_bytes;
    std::vector<uint8_t> ideology_bytes;
    // Economy POD ECP1 section (graph authority snapshot).
    std::vector<uint8_t> economy_pod_bytes;
    // D7T1 Host Country/Economy asset journal. Independent of Economy POD
    // section ownership; restores peer continuation without granting Economy
    // ACTIVE authority.
    std::vector<uint8_t> economy_asset_bytes;
    std::array<uint64_t, 256> producer_sequences{};
    uint64_t fallback_producer_sequence = 0;
};

} // namespace pk
