#pragma once

#include "runtime_authoritative_domains.h"
#include "runtime_climate_passes.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

// Numeric cold-start contract for the worker Climate graph. The facade builds
// this from the selected profile and map constants before a trace is accepted.
struct RuntimeClimateCatalog {
    static constexpr uint32_t FORMULA_VERSION = 1u;
    uint32_t abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    uint32_t formula_version = FORMULA_VERSION;
    uint32_t cell_count = 0;
    uint32_t map_width = 0;
    uint32_t map_height = 0;
    uint64_t hash = 0;
    // Pass-A numeric configuration. Values are copied from the immutable
    // capture boundary; defaults preserve the existing diagnostic fixture.
    float insol_amp = 0.20f;
    float insol_gain = 1.0f;
    float axial_tilt_deg = 23.5f;
    float day_length_gain = 0.35f;
    float solar_gain = 1.0f;
    float insol_dev_min = -1.0f;
    float insol_dev_max = 1.0f;
    float land_continentality = 1.0f;
    float thermal_inertia_land = 0.35f;
    float thermal_inertia_water = 0.045f;
    float thermal_inertia_snow = 0.09f;
    float thermal_inertia_high_mountain = 0.16f;
    float thermal_daily_delta_cap = 0.15f;
    float runtime_moisture_base_relax_rate = 0.24f;
    float runtime_moisture_weather_vapor_weight = 0.12f;
    float runtime_moisture_precip_weight = 0.78f;
    float runtime_moisture_soil_weight = 1.82f;
    float runtime_moisture_soil_dry_weight = 2.21f;
    float runtime_moisture_water_balance_weight = 1.04f;
    float runtime_moisture_water_balance_dry_weight = 1.30f;
    float snowpack_cover_low = 0.05f;
    float snowpack_cover_full = 0.80f;
    float sea_level = 0.5f;
    float dt_days_cap = 30.0f;
    float sea_ice_freeze = -1.8f;
    float sea_ice_melt = -0.5f;
    float soil_capacity = 1.0f;
    uint32_t days_per_year = 365u;
};

enum class RuntimeClimateStage : uint8_t {
    PASS_A = 0,
    PASS_B,
    OCEAN_WATER,
    OCEAN_LAND,
    WIND_AIR,
    WIND_SURFACE,
    SEA_ICE,
    TRANSPIRATION,
    ALBEDO,
    VEGETATION_DYNAMICS,
    CLIMATE_FEEDBACK,
    WEATHER,
    RUNTIME_HYDROLOGY,
    STAGE_B_AFTER_HYDROLOGY,
    COUNT,
};

constexpr size_t RUNTIME_CLIMATE_STAGE_COUNT =
    static_cast<size_t>(RuntimeClimateStage::COUNT);

// 生产侧用的位常量（runtime_climate_passes.h）必须与本枚举一致，否则 production /
// worker 两个掩码会各说各话，而它们的差集正是"缺哪个 stage"的判据。
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_PASS_A ==
                  1 << static_cast<int>(RuntimeClimateStage::PASS_A), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_PASS_B ==
                  1 << static_cast<int>(RuntimeClimateStage::PASS_B), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_OCEAN_WATER ==
                  1 << static_cast<int>(RuntimeClimateStage::OCEAN_WATER), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_OCEAN_LAND ==
                  1 << static_cast<int>(RuntimeClimateStage::OCEAN_LAND), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_WIND_AIR ==
                  1 << static_cast<int>(RuntimeClimateStage::WIND_AIR), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_WIND_SURFACE ==
                  1 << static_cast<int>(RuntimeClimateStage::WIND_SURFACE), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_SEA_ICE ==
                  1 << static_cast<int>(RuntimeClimateStage::SEA_ICE), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_TRANSPIRATION ==
                  1 << static_cast<int>(RuntimeClimateStage::TRANSPIRATION), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_ALBEDO ==
                  1 << static_cast<int>(RuntimeClimateStage::ALBEDO), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS ==
                  1 << static_cast<int>(RuntimeClimateStage::VEGETATION_DYNAMICS), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_CLIMATE_FEEDBACK ==
                  1 << static_cast<int>(RuntimeClimateStage::CLIMATE_FEEDBACK), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_WEATHER ==
                  1 << static_cast<int>(RuntimeClimateStage::WEATHER), "");
static_assert(pk_async_climate::CLIMATE_STAGE_BIT_RUNTIME_HYDROLOGY ==
                  1 << static_cast<int>(RuntimeClimateStage::RUNTIME_HYDROLOGY), "");
// RuntimeThreadReport sizes its per-stage timing arrays from the pass-side
// constant; a drift here would silently truncate the exported cadence table.
static_assert(static_cast<size_t>(pk_async_climate::CLIMATE_STAGE_SLOT_COUNT) ==
                  RUNTIME_CLIMATE_STAGE_COUNT,
              "climate stage slot count is out of sync with RuntimeClimateStage");

struct RuntimeClimateKernelReport {
    std::array<uint64_t, RUNTIME_CLIMATE_STAGE_COUNT> stage_work{};
    std::array<double, RUNTIME_CLIMATE_STAGE_COUNT> stage_ms{};
    uint64_t work_units = 0;
    uint32_t changed_cells = 0;
    uint64_t input_hash = 0;
    uint64_t state_hash = 0;
    uint8_t completed = 0;
    // 共享 round 里实际跑过 / 因输入 lane 不完整而被跳过的 pass（bit 位 = passes_mask，
    // 0 pass_a .. 8 finalizer）。starved != 0 是输入边界故障，不是算法分叉；两者混在
    // 一起会让分叉矩阵完全误导。
    int round_passes_ran = 0;
    int round_passes_starved = 0;
    // 按 RuntimeClimateStage 索引的位掩码（1 << stage），两个都是"这一天"的事实：
    //   production_stage_mask — 生产跑了哪些 stage（随 reference 发布过来）。
    //   stage_ran_mask        — worker 跑了哪些 stage。
    // 差集 = "生产算了、worker 没算"，这正是分叉矩阵里 stage 9..13 那些字段的成因。
    // 没有这两个掩码就无法区分"worker 缺实现"和"这一天生产本来也没跑"——后者在
    // 30 日窗口里其实占大多数，把它们混在一起会严重高估剩余工作量。
    int production_stage_mask = 0;
    int stage_ran_mask = 0;
    char error[64]{};
};

struct RuntimeClimateParityReport {
    bool compared = false;
    bool matched = false;
    int64_t day = -1;
    uint32_t cell = 0;
    uint16_t stage = 0;
    uint64_t input_generation = 0;
    uint64_t base_generation = 0;
    uint64_t trace_hash = 0;
    uint64_t reference_state_hash = 0;
    uint64_t worker_state_hash = 0;
    char field[48]{};
    char reference_bits[24]{};
    char worker_bits[24]{};
    char reason[64]{};
};

struct RuntimeClimateVisualIntent {
    uint32_t cell = 0;
    uint16_t field = 0;
    float value = 0.0f;
    uint64_t generation = 0;
};

// Pure C++ staged kernel. It does not own clock, host, visual resources, or
// source objects. The caller supplies two preallocated stores: plan writes the
// next store; commit swaps them only at the day barrier.
class RuntimeClimateKernel {
public:
    void reset(uint32_t cell_count);
    bool compile_catalog(const RuntimeEnvironmentSnapshot &input,
                         RuntimeClimateCatalog &catalog, std::string &error) const;
    bool plan_day(int64_t day, const RuntimeEnvironmentSnapshot &input,
                  const RuntimeClimateCatalog &catalog,
                  const RuntimeClimateStore &current, RuntimeClimateStore &next,
                  RuntimeClimateKernelReport &report) const;
    static void commit(RuntimeClimateStore &current, RuntimeClimateStore &next);
    static uint64_t input_hash(const RuntimeEnvironmentSnapshot &input);
    static bool self_test(std::string &error);

    // distribute 写完的 soil_moisture。它没有 store 成员，所以既不进 PKEC 存档也不
    // 进 writeback ring 的 payload（那个 payload 就是 store 本身）—— 但 ACTIVE 下它
    // 必须能回到 MapData：主线程的 distribute 被抑制门关掉了，worker 这份如果也丢弃，
    // 这条场就没有任何日频写者。实测表现是非零 cell 恒定在初始那一批（537），而主
    // 线程那侧 240 天内从 914 长到 1845。
    //
    // 跨天累积由 MapData 承载：每天从 environment 播种进 scratch、算完回灌，所以这里
    // 只需要把当天的结果暴露出去，worker 不需要自持它。
    const std::vector<float> &distribute_soil_moisture() const {
        return _distribute_soil_scratch;
    }

    // weather_commit 写完的 field_init。没有 store 成员，必须走 snapshot extras
    // 才能回到 MapData；理由见 RuntimeClimateSnapshot::weather_field_init。
    const std::vector<uint8_t> &weather_field_init() const {
        return _weather_field_init_scratch;
    }

    // pass_a 的日照/热量输出，同样没有 store 成员、同样在 ACTIVE 下失去主线程写者。
    // 直接给 _round_out 的引用：这些 lane 每天被共享 round 重写，不跨天累积。
    const pk_async_climate::ClimateOutputBuf &round_output() const {
        return _round_out;
    }

private:
    // 共享 round 编排的 scratch 缓冲。plan_day 是 const 因为它不改动 kernel 的
    // 语义状态；这三个只是复用的内存，每天重新分配 200+ KB 才是真问题。
    mutable pk_async_climate::ClimateInputBuf  _round_in;
    mutable pk_async_climate::ClimateOutputBuf _round_out;
    mutable pk_async_climate::ClimateWorkBuf   _round_work;
    // stage 10 feedback 写三个场，其中 base_moisture / soil_moisture 都不是
    // RuntimeClimateStore 的成员 —— worker 没有地方持有它们，也不该持有：它们不在
    // canonical parity 字段表里，生产是唯一权威。用 scratch 承接后丢弃，只有
    // vegetation_growth_pressure 写进 worker 自己的 store。
    mutable std::vector<float> _feedback_base_moisture;
    mutable std::vector<float> _feedback_soil_moisture;
    // stage 9 同理：regen_score 只有 uint8 的 vegetation_succession_candidate 与之近似，
    // 没有 float 成员可承接，所以也走 scratch。
    mutable std::vector<float> _vegetation_regen_scratch;
    // stage 11 的 scratch 分两类。
    //
    // prev_* 五条是 worker 自己 store 的当日副本：内核读 PREV_CNV[upstream_idx]，
    // upstream 可能小于 i，与 out 共用一块内存就会读到本轮已改写的值。生产 staged
    // 路径本来就是两块 buffer，这里跟着分开，否则不是同一个算法。
    mutable std::vector<float> _weather_prev_vapor;
    mutable std::vector<float> _weather_prev_precip;
    mutable std::vector<float> _weather_prev_cloud_water;
    mutable std::vector<float> _weather_prev_cloud;
    mutable std::vector<float> _weather_prev_convergence;
    // conv_inhib 与 field_init 没有 store 成员：前者每天从生产记录播种、输出丢弃，
    // 后者是"这格初始化过没有"的一次性标记，经 snapshot extras 回灌 MapData。
    mutable std::vector<float> _weather_conv_inhib;
    mutable std::vector<uint8_t> _weather_field_init_scratch;
    // staged next buffer：生产 weather_advance → weather_commit 两步之间的中转。
    // worker 走同一条 staged 路径，所以也要自己的一份。
    mutable std::vector<float>   _wx_next_vapor;
    mutable std::vector<float>   _wx_next_cloud;
    mutable std::vector<float>   _wx_next_cloud_water;
    mutable std::vector<float>   _wx_next_precip;
    mutable std::vector<float>   _wx_next_instability;
    mutable std::vector<float>   _wx_next_intensity;
    mutable std::vector<float>   _wx_next_convergence;
    mutable std::vector<int32_t> _wx_next_type;
    // commit 的 dirty 标记：worker 不需要它的下游（视觉脏区），但内核要一块可写。
    mutable std::vector<uint8_t> _weather_dirty_scratch;
    // 邻域几何缓存。可由 pos + wrap 完全重建，所以不进 store、也不从生产记录抄。
    mutable std::vector<float> _weather_geom_dx;
    mutable std::vector<float> _weather_geom_dy;
    mutable std::vector<float> _weather_geom_invd;
    // stage 12。soil_moisture 与 river_discharge_30d 都是 in/out 的累积量却没有 store
    // 成员，canal_water 是每轮重算的派生量：三条都走 scratch。
    mutable std::vector<float> _hydrology_soil_scratch;
    mutable std::vector<float> _hydrology_q30_scratch;
    mutable std::vector<float> _hydrology_canal_water_scratch;
    // 运河编译态与每日临时缓冲，与主线程各持一份。
    mutable pk_async_climate::HydrologyCanalState _hydrology_canal;
    mutable pk_async_climate::HydrologyScratch _hydrology_scratch;
    // weather distribute。cover / 两条积雪计数 / soil_moisture / field_init 都没有
    // store 成员：前四条每天从生产记录播种、输出丢弃，field_init 固定为 1。
    mutable std::vector<uint8_t> _distribute_cover_scratch;
    mutable std::vector<int32_t> _distribute_acc_snow_scratch;
    mutable std::vector<int32_t> _distribute_pre_cover_scratch;
    mutable std::vector<float>   _distribute_soil_scratch;
    mutable std::vector<uint8_t> _distribute_field_init_scratch;
};

} // namespace pk
