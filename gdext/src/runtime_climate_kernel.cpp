#include "runtime_climate_kernel.h"
#include "runtime_climate_formulas.h"
// S3：生产 Climate pass 的共享纯内核。worker 不再维护第二套 stage 实现。
#include "runtime_climate_passes.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

namespace pk {
namespace {
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t mix(uint64_t value, uint64_t input) noexcept {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6u) + (value >> 2u);
    return value * FNV_PRIME;
}

template <typename T>
uint64_t mix_vector(uint64_t hash, const std::vector<T> &values) noexcept {
    hash = mix(hash, values.size());
    for (const T &value : values) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        for (size_t i = 0; i < sizeof(T); ++i) hash = mix(hash, bytes[i]);
    }
    return hash;
}

float read_or(const std::vector<float> &values, size_t index, float fallback) noexcept {
    return index < values.size() ? values[index] : fallback;
}

uint8_t read_or(const std::vector<uint8_t> &values, size_t index, uint8_t fallback) noexcept {
    return index < values.size() ? values[index] : fallback;
}

void copy_error(RuntimeClimateKernelReport &report, const char *error) {
    size_t index = 0;
    for (; error != nullptr && error[index] != '\0' && index + 1 < sizeof(report.error); ++index)
        report.error[index] = error[index];
    report.error[index] = '\0';
}

template <typename T>
void copy_lane(std::vector<T> &destination, const std::vector<T> &source) {
    std::copy(source.begin(), source.end(), destination.begin());
}

void copy_store_lanes(RuntimeClimateStore &next, const RuntimeClimateStore &current) {
    copy_lane(next.temperature, current.temperature);
    copy_lane(next.temperature_30d_ema, current.temperature_30d_ema);
    copy_lane(next.temperature_365d_ema, current.temperature_365d_ema);
    copy_lane(next.temperature_baseline, current.temperature_baseline);
    copy_lane(next.thermal_energy, current.thermal_energy);
    copy_lane(next.moisture, current.moisture);
    copy_lane(next.plant_available_water, current.plant_available_water);
    copy_lane(next.water_balance_30d, current.water_balance_30d);
    copy_lane(next.weather_precipitation, current.weather_precipitation);
    copy_lane(next.weather_intensity, current.weather_intensity);
    copy_lane(next.vapor, current.vapor);
    copy_lane(next.cloud_water, current.cloud_water);
    copy_lane(next.cloud_cover, current.cloud_cover);
    copy_lane(next.convergence, current.convergence);
    copy_lane(next.instability, current.instability);
    copy_lane(next.weather_type, current.weather_type);
    copy_lane(next.weather_prev_type, current.weather_prev_type);
    copy_lane(next.weather_target_type, current.weather_target_type);
    copy_lane(next.weather_transition_alpha, current.weather_transition_alpha);
    copy_lane(next.snow_cover, current.snow_cover);
    copy_lane(next.snowpack, current.snowpack);
    copy_lane(next.sea_ice, current.sea_ice);
    copy_lane(next.runoff, current.runoff);
    copy_lane(next.groundwater, current.groundwater);
    copy_lane(next.river_storage, current.river_storage);
    copy_lane(next.river_discharge, current.river_discharge);
    copy_lane(next.riparian_moisture, current.riparian_moisture);
    copy_lane(next.vegetation_vitality, current.vegetation_vitality);
    copy_lane(next.vegetation_growth_pressure, current.vegetation_growth_pressure);
    copy_lane(next.vegetation_heat_stress, current.vegetation_heat_stress);
    copy_lane(next.vegetation_drought_stress, current.vegetation_drought_stress);
    copy_lane(next.vegetation_cold_stress, current.vegetation_cold_stress);
    copy_lane(next.vegetation_growth_streak, current.vegetation_growth_streak);
    copy_lane(next.vegetation_drought_streak, current.vegetation_drought_streak);
    copy_lane(next.vegetation_succession_candidate, current.vegetation_succession_candidate);
    copy_lane(next.temperature_history, current.temperature_history);
    next.cell_count = current.cell_count;
    next.generation = current.generation;
    next.climate_generation = current.climate_generation;
    next.committed_day = current.committed_day;
    next.climate_anomaly = current.climate_anomaly;
    next.annual_temperature_drift = current.annual_temperature_drift;
    next.rng_state = current.rng_state;
    next.annual_rng_state = current.annual_rng_state;
    next.history_cursor = current.history_cursor;
}

float normalised_rng(uint64_t &value) noexcept {
    return climate_formula::normalized_rng(value);
}

template <typename Fn>
void run_stage(RuntimeClimateKernelReport &report, RuntimeClimateStage stage, Fn &&body) {
    const auto begin = std::chrono::steady_clock::now();
    const uint64_t work = body();
    const size_t index = static_cast<size_t>(stage);
    report.stage_work[index] = work;
    report.work_units += work;
    report.stage_ms[index] = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - begin).count();
}
} // namespace

void RuntimeClimateKernel::reset(uint32_t) {}

bool RuntimeClimateKernel::compile_catalog(const RuntimeEnvironmentSnapshot &input,
                                           RuntimeClimateCatalog &catalog,
                                           std::string &error) const {
    if (input.climate_catalog_abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION ||
        input.cell_count == 0) {
        error = "climate_catalog_abi_or_shape_invalid";
        return false;
    }
    // Formula parameters belong to the immutable worker catalog, not to the
    // per-day environment protocol.  Reset first so a catalog compiled for a
    // new topology cannot accidentally retain values from a previous map.
    catalog = RuntimeClimateCatalog{};
    catalog.abi_version = input.climate_catalog_abi_version;
    catalog.cell_count = input.cell_count;
    catalog.map_width = input.climate_map_width;
    catalog.map_height = input.climate_map_height;
    // A catalog hash is static metadata, never a day-varying input hash. The
    // facade may provide a compiled profile hash; otherwise derive a stable
    // shape/topology identity that survives daily dynamic field changes.
    catalog.hash = input.climate_catalog_hash != 0 ? input.climate_catalog_hash :
        (0x434c494d415445ull ^ static_cast<uint64_t>(input.cell_count) ^
         (static_cast<uint64_t>(input.climate_map_width) << 16u) ^
         (static_cast<uint64_t>(input.climate_map_height) << 32u) ^
         input.topology_generation);
    if (catalog.hash == 0) {
        error = "climate_catalog_hash_invalid";
        return false;
    }
    return true;
}

uint64_t RuntimeClimateKernel::input_hash(const RuntimeEnvironmentSnapshot &input) {
    uint64_t hash = mix(FNV_OFFSET, input.generation);
    hash = mix(hash, static_cast<uint64_t>(input.day));
    hash = mix(hash, input.cell_count);
    hash = mix(hash, input.climate_catalog_abi_version);
    hash = mix(hash, input.climate_catalog_hash);
    hash = mix(hash, input.climate_map_width);
    hash = mix(hash, input.climate_map_height);
    hash = mix(hash, input.topology_generation);
    hash = mix(hash, input.vision_revision);
    hash = mix(hash, input.topology_validated ? 1u : 0u);
    hash = mix(hash, input.fog_solved ? 1u : 0u);
    hash = mix(hash, input.climate_input_complete ? 1u : 0u);
    uint32_t dt_bits = 0;
    std::memcpy(&dt_bits, &input.dt_days, sizeof(input.dt_days));
    hash = mix(hash, dt_bits);
    uint64_t season_bits = 0;
    uint64_t anomaly_bits = 0;
    std::memcpy(&season_bits, &input.season_phase, sizeof(input.season_phase));
    std::memcpy(&anomaly_bits, &input.climate_anomaly, sizeof(input.climate_anomaly));
    hash = mix(hash, season_bits);
    hash = mix(hash, anomaly_bits);
    hash = mix_vector(hash, input.cell_temp);
    hash = mix_vector(hash, input.cell_temp_30d);
    hash = mix_vector(hash, input.cell_temp_365d);
    hash = mix_vector(hash, input.cell_temp_baseline_year);
    hash = mix_vector(hash, input.cell_base_moisture);
    hash = mix_vector(hash, input.cell_moisture);
    hash = mix_vector(hash, input.cell_plant_available_water);
    hash = mix_vector(hash, input.cell_soil_moisture);
    hash = mix_vector(hash, input.cell_water_balance_30d);
    hash = mix_vector(hash, input.cell_weather_precip);
    hash = mix_vector(hash, input.cell_snow_cover);
    hash = mix_vector(hash, input.cell_weather_intensity);
    hash = mix_vector(hash, input.cell_weather_vapor);
    hash = mix_vector(hash, input.cell_weather_cloud_water);
    hash = mix_vector(hash, input.cell_weather_cloud);
    hash = mix_vector(hash, input.cell_weather_type);
    hash = mix_vector(hash, input.cell_weather_transition);
    hash = mix_vector(hash, input.cell_sea_ice_frac_prev);
    hash = mix_vector(hash, input.cell_river_discharge_30d);
    hash = mix_vector(hash, input.cell_vegetation_vitality);
    hash = mix_vector(hash, input.cell_insolation_dev);
    hash = mix_vector(hash, input.cell_heat_input);
    hash = mix_vector(hash, input.cell_wind_x);
    hash = mix_vector(hash, input.cell_wind_y);
    hash = mix_vector(hash, input.cell_wind_speed);
    hash = mix_vector(hash, input.cell_ocean_current_x);
    hash = mix_vector(hash, input.cell_ocean_current_y);
    hash = mix_vector(hash, input.cell_air_mass_temp_anomaly);
    hash = mix_vector(hash, input.cell_ocean_thermal_anomaly);
    hash = mix_vector(hash, input.cell_local_thermal_anomaly);
    hash = mix_vector(hash, input.cell_temperature_transport_anomaly);
    hash = mix_vector(hash, input.cell_ema_initialized);
    hash = mix_vector(hash, input.cell_elevation);
    hash = mix_vector(hash, input.cell_lat_norm);
    hash = mix_vector(hash, input.cell_geometry_area);
    hash = mix_vector(hash, input.cell_wind_band);
    hash = mix_vector(hash, input.cell_ocean_heat_capacity);
    hash = mix_vector(hash, input.neighbor_offsets);
    hash = mix_vector(hash, input.neighbor_indices);
    hash = mix_vector(hash, input.hydro_parent);
    hash = mix_vector(hash, input.terrain);
    hash = mix_vector(hash, input.landform);
    hash = mix_vector(hash, input.vegetation);
    hash = mix_vector(hash, input.cover);
    hash = mix_vector(hash, input.is_water);
    hash = mix_vector(hash, input.has_river);
    hash = mix_vector(hash, input.canal_edge_mask);
    hash = mix_vector(hash, input.canal_water);
    hash = mix_vector(hash, input.trade_passable_lut);
    hash = mix_vector(hash, input.trade_move_cost_lut);
    hash = mix_vector(hash, input.visible);
    hash = mix_vector(hash, input.building_resource_reserve);
    hash = mix_vector(hash, input.building_resource_extra);
    return hash;
}

bool RuntimeClimateKernel::plan_day(int64_t day, const RuntimeEnvironmentSnapshot &input,
                                    const RuntimeClimateCatalog &catalog,
                                    const RuntimeClimateStore &current,
                                    RuntimeClimateStore &next,
                                    RuntimeClimateKernelReport &report) const {
    report = RuntimeClimateKernelReport{};
    std::string error;
    std::string current_error;
    std::string next_error;
    if (!validate_runtime_environment_snapshot(input, error) ||
        !current.validate(current_error) || !next.validate(next_error) ||
        catalog.abi_version != RUNTIME_DOMAIN_POD_ABI_VERSION ||
        catalog.cell_count != current.cell_count || next.cell_count != current.cell_count ||
        (input.climate_catalog_hash != 0 && input.climate_catalog_hash != catalog.hash) ||
        day < 0 || current.committed_day >= day) {
        const char *reason = !error.empty() ? error.c_str() :
            (!current_error.empty() ? current_error.c_str() :
            (!next_error.empty() ? next_error.c_str() : "climate_kernel_preflight_failed"));
        copy_error(report, reason);
        return false;
    }
    copy_store_lanes(next, current);
    // climate_anomaly 是季节系统给出的全局量，不是 Climate 域自己的状态：生产每 tick
    // 从 environment 提供它，而 worker 的 store 只在 day % 365 == 0 改写。两者因此长期
    // 不等，且这个差异不在 parity 字段表里（只进 parity_hash），会一直隐身。它进
    // weather knobs 与温度合成，采纳生产的值是长期正确的语义 —— 年度漂移仍由下面的
    // annual_temperature_drift 维护，供 ACTIVE 模式下 environment 缺值时兜底。
    if (std::isfinite(input.climate_anomaly)) {
        next.climate_anomaly = static_cast<float>(input.climate_anomaly);
    }
    // 季末地理级重算在当天 climate round 之前跑（SUS priority 50 vs 210）。
    // capture 里的 cell_moisture 是 tick 开头、refresh 之前的快照，不能当权威。
    // 生产 pass_a 的输入才是 stage 0/1/3/4 全部写完之后的值。没有 production
    // overlay 时退回 stage 0：陆地 moisture = clamp(base, 0, 1)，水体 = base。
    // ACTIVE 之后这条语义依然成立：season refresh 保持在主线程，它是地理权威。
    if (input.climate_season_refresh_ran &&
        next.moisture.size() == current.cell_count) {
        const auto &round_moist = input.climate_round_input.moisture;
        const auto &round_base = input.climate_round_input.base_moisture;
        if (input.climate_round_ran &&
            round_moist.size() == current.cell_count) {
            for (size_t i = 0; i < current.cell_count; ++i) {
                const float m = round_moist[i];
                if (std::isfinite(m)) next.moisture[i] = m;
            }
        } else {
            const auto &bases = !round_base.empty() ? round_base
                                                    : input.cell_base_moisture;
            const auto &water = input.climate_round_input.is_water.empty()
                ? input.is_water : input.climate_round_input.is_water;
            if (bases.size() == current.cell_count) {
                for (size_t i = 0; i < current.cell_count; ++i) {
                    const float base = bases[i];
                    if (!std::isfinite(base)) continue;
                    const bool is_water = i < water.size() && water[i] != 0u;
                    const float m = is_water ? base
                        : climate_formula::clamp01(base);
                    next.moisture[i] = m;
                }
            }
        }
    }
    // PAW 每天在这里重算，而不是从 input 收回。它是 f(moisture, WB30, soil) 的纯派生
    // 量，没有跨天累积，所以「收回」这个动作本身就是错的抽象。
    //
    // 不收回的理由是收了没用。ACTIVE 下 PAW 有两份，通过 MapData 首尾相接：
    //
    //   next.plant_available_water（store，进回灌表）
    //       ↑ 每 48 天被 vegetation_dynamics 写一次，别处不写
    //   input.climate_round_input.plant_*（capture 从 slot 填，喂共享 round）
    //       ↑ 就是上面那份昨天回灌的结果
    //
    // 于是 PAW 只在 vegetation_dynamics 那几天动一下 —— 实测 150 天两个值
    // （0.296 / 0.302），而主线程那侧单调降 12%（0.294 → 0.258）。transpiration 每天拿
    // PAW 乘 heat 算 vegetation_growth_pressure，所以整条植被链的活跃 cell 集合跟着锁死。
    //
    // season refresh 那侧的写入也进不来：capture 早于 _sus.tick()（见
    // world_ext_simulation_host.cpp 里 fill_climate_round_input 那处说明），而 season
    // refresh 跑在 _sus.tick() 里，它写完 MapData 之后，第二天开头的回灌就把它覆盖了。
    // moisture 没有这个问题，因为它的收回走 base_moisture，那条场没有 store 成员、不在
    // 回灌表里，主线程仍是它唯一的写者。
    //
    // SHADOW 必须保持原样（PAW 跟着生产的 48/49 天节拍走），每天自算会立刻分叉，所以
    // 这一段由 climate_own_paw 门控。
    //
    // 用 next 而不是 current 读 moisture：上面那段收回可能刚把 season refresh 的
    // base_moisture 写进 next.moisture，PAW 应当看到它。soil 只能从 environment 读 ——
    // 它没有 store 成员，worker 手里那份是 distribute 的 scratch，跨天累积由 MapData
    // 承载（见 RuntimeClimateSnapshot::soil_moisture）。
    if (input.climate_worker_authoritative &&
        next.plant_available_water.size() == current.cell_count &&
        next.moisture.size() == current.cell_count &&
        next.water_balance_30d.size() == current.cell_count) {
        const auto &soil = input.cell_soil_moisture;
        const auto &water = input.is_water;
        for (size_t i = 0; i < current.cell_count; ++i) {
            // 水域格 PAW 恒 0，与生产两处调用点的 is_water 分支一致
            // （runtime_climate_passes.cpp:2602 与 :5043）。
            if (i < water.size() && water[i] != 0u) {
                next.plant_available_water[i] = 0.0f;
                continue;
            }
            next.plant_available_water[i] = climate_formula::plant_available_water(
                next.moisture[i], next.water_balance_30d[i],
                i < soil.size() ? soil[i] : 0.0f,
                input.climate_paw_water_balance_weight,
                input.climate_paw_soil_buffer_weight,
                input.climate_paw_drought_penalty);
        }
    }
    // 生产 stage 11（consume_feedback_buffers）在 climate round / hydrology 之前
    // 把 VGP *= decay。放在全部 stage 之后会让当天 hydrology 仍按未衰减的 VGP
    // 抽水，比完之后 VGP 本身却是绿的——day 28 的 moisture/PAW/河网链就是这样。
    if (input.climate_seasonal_feedback_ran &&
        next.vegetation_growth_pressure.size() == current.cell_count) {
        const float decay = input.climate_seasonal_feedback_decay;
        if (std::isfinite(decay)) {
            for (size_t i = 0; i < current.cell_count; ++i) {
                next.vegetation_growth_pressure[i] *= decay;
            }
        }
    }
    report.input_hash = input_hash(input);
    // 生产这一天跑了哪些 stage。与下面累积的 report.stage_ran_mask 的差集就是
    // "生产算了、worker 没算"——分叉矩阵里 stage 9..13 的字段全靠它归因。
    report.production_stage_mask = input.climate_production_stage_mask;

    // 生产 Climate round 按 stride 跑，不是每日一轮。这一天生产没跑 round 时，
    // reference 里 Climate 拥有的场与前一天完全相同，所以 worker 也必须一个 stage
    // 都不跑：copy_store_lanes 已经把状态原样搬过来了，直接收工即为等价。
    // 反之若 worker 每天都跑，它会在生产没动的日子里单方面推进温度场，而分叉矩阵
    // 会把这种节拍错位报成算法分叉。
    // albedo 不在 climate round 里：它跑在 native daily graph 的 stage_b 段、用
    // cp.weather_albedo_stride 自己的节拍。所以"这一天 worker 要不要干活"是两个
    // 独立条件的并集 —— 只看 round 会漏掉那些生产只跑了 albedo 的日子，而 albedo 是
    // temp 的日内最后写者，漏一天温度场就整场落后一个 delta。
    // feedback（stage 10）同在 stage_b 段、同样有自己的 stride，所以是第三个独立条件。
    // vegetation_dynamics（stage 9）与 feedback（stage 10）同在 stage_b 段、各有自己的
    // stride，所以是第三、第四个独立条件。
    const bool vegetation_requested = input.climate_vegetation != nullptr &&
        input.climate_vegetation->knobs.ran &&
        input.climate_vegetation->n_cells == static_cast<int>(current.cell_count);
    const bool feedback_requested = input.climate_feedback != nullptr &&
        input.climate_feedback->knobs.ran &&
        input.climate_feedback->n_cells == static_cast<int>(current.cell_count);
    // weather（stage 11）跑在 round 末尾，但有自己的 weather bucket cadence，所以同样
    // 是一个独立条件：只看 round 会在"生产这天只跑了 weather"的日子上什么都不做。
    const bool weather_requested = input.climate_weather != nullptr &&
        input.climate_weather->ran &&
        input.climate_weather->n_cells == static_cast<int>(current.cell_count);
    // hydrology（stage 12）有 runtime_hydrology_stride 自己的节拍，同样是一个独立条件。
    const bool hydrology_requested = input.climate_hydrology != nullptr &&
        input.climate_hydrology->ran &&
        input.climate_hydrology->n_cells == static_cast<int>(current.cell_count);
    // weather distribute 跟 weather bucket 同节拍，但它自己的记录可能缺席（字段不全）。
    const bool distribute_requested =
        input.climate_weather_distribute != nullptr &&
        input.climate_weather_distribute->ran &&
        input.climate_weather_distribute->n_cells == static_cast<int>(current.cell_count);
    if (!input.climate_round_ran && !input.climate_albedo.ran &&
        !vegetation_requested && !feedback_requested && !weather_requested &&
        !hydrology_requested && !distribute_requested) {
        // 物理场一个不动，但日期/代号必须照常推进：committed_day 是单调性门禁和
        // restore 校验的依据，停在旧值会让后面某一天被判成回退。
        next.committed_day = day;
        ++next.generation;
        ++next.climate_generation;
        report.completed = 1;
        report.state_hash = next.state_hash();
        return true;
    }

    const size_t cells = current.cell_count;
    const float season = static_cast<float>(input.season_phase);
    // The capture boundary carries the actual logical-day delta. Clamping to
    // one day here silently slowed stride/fast-forward runs and made EMA,
    // transition, hydrology and sea-ice state depend on call frequency.
    const float dt = std::clamp(input.dt_days, 1.0f,
                                std::max(1.0f, catalog.dt_days_cap));

    // S3（断点 2）：优先走生产共享纯内核。round_in 由主线程 capture 时用
    // DCWorldExt::fill_climate_round_input 填好，与 async_climate_round_kick 走同
    // 一段提取代码，所以 worker 与生产 round 吃的是逐位相同的输入。
    //
    // n_cells 不匹配（旧 harness / 稀疏 fixture / 未接线的地图）时退回下面的诊断
    // 近似实现。这条回退路径不具备 parity 语义，只用于让 SHADOW 诊断不中断。
    const pk_async_climate::ClimateInputBuf &round_in = input.climate_round_input;
    const bool shared_passes_available =
        input.climate_round_ran &&
        round_in.n_cells > 0 && static_cast<size_t>(round_in.n_cells) == cells;

    // ─── 共享 round：9 个 pass 一次跑完（生产用的同一份编排 + 同一份内核）────
    //
    // 覆盖 stage PASS_A..TRANSPIRATION。这里刻意不逐 stage 分别调用内核：pass 之间
    // 的 in←out 接力字段是编排的一部分，拆开调用就等于在 worker 里重写一遍顺序。
    //
    // shared_passes_available 为假时（旧 harness / 未接线的地图）落到下面的诊断近似，
    // 那条路径没有 parity 语义，只保证 SHADOW 诊断不中断。
    bool shared_round_ran = false;
    if (shared_passes_available) {
        _round_in = round_in;   // 编排在 in 上做接力，必须给它可变副本
        // water terrain LUT 走 static knobs（它不是 per-cell lane，capture 的 slot 兜底
        // 覆盖不到）。round input 里没带时从 static knobs 补，否则 sea_ice 会饿死。
        if (_round_in.water_terrain_ids.empty()) {
            _round_in.water_terrain_ids =
                input.climate_round_static_knobs.water_terrain_ids;
        }
        // scalars 由 capture 侧整套填好（world_ext_simulation_host.cpp 里
        // climate_round_scalars 那段），这里不再逐字段补。
        //
        // 留一道 season_phase 的兜底：它是 scalars 里唯一的时变量，0.0 不是"合理
        // 默认"而是"永远的春分"，日照整年不动。旧 harness / 未接线的地图不传
        // climate_round_scalars 时，至少不能让整个季节链停摆。
        if (input.climate_worker_authoritative &&
            _round_in.scalars.season_phase == 0.0 && input.season_phase != 0.0) {
            _round_in.scalars.season_phase = input.season_phase;
        }
        _round_out.n_cells = static_cast<int>(cells);
        pk_async_climate::ClimateRoundPassTiming timing;
        const bool round_ok = pk_async_climate::run_climate_round_passes(
            _round_in, input.climate_round_static_knobs, _round_work, _round_out,
            &timing);

        // 一次性诊断（worker 线程，不能用 Godot 的 print）：说明这一天走的是共享编排
        // 还是下面的近似回退。回退是静默的，而两者的数值差一个数量级，缺了这行日志
        // 就只能从分叉矩阵反推。
        static std::atomic<bool> shared_path_logged{false};
        bool expected = false;
        if (shared_path_logged.compare_exchange_strong(expected, true)) {
            std::fprintf(stderr,
                "[climate-kernel][round] shared=%d ok=%d n_cells=%d mask=0x%X "
                "ran=0x%X starved=0x%X knobs_cells=%d\n",
                1, round_ok ? 1 : 0, round_in.n_cells,
                round_in.scalars.passes_mask, timing.passes_ran,
                timing.passes_starved,
                input.climate_round_static_knobs.n_cells);
            std::fflush(stderr);
        }
        // starved = 这个 pass 被 mask 启用了，但输入 lane 不完整所以没跑。它的 out
        // 字段留空，下面的 scatter 会静默 no-op —— 于是 worker 少跑了半个 round，而
        // 分叉矩阵只会看到"某些字段停在昨天的值"，和算法分叉长得一模一样。所以这里
        // 必须当作输入边界故障报出来，而不是当成一次成功的 round。
        if (timing.passes_starved != 0) {
            report.round_passes_starved = timing.passes_starved;
            static std::atomic<bool> starved_logged{false};
            bool starved_expected = false;
            if (starved_logged.compare_exchange_strong(starved_expected, true)) {
                std::fprintf(stderr,
                    "[climate-kernel][round] input starved passes=0x%X — "
                    "round input lanes incomplete (n=%d)\n",
                    timing.passes_starved, _round_in.n_cells);
                // 只报"哪个 pass 饿死"还得回头对着守卫条件人工比对；直接把这个 pass
                // 需要的 lane 长度打出来，缺哪条一眼可见。
                if ((timing.passes_starved & 0x40) != 0) {
                    std::fprintf(stderr,
                        "[climate-kernel][round]   sea_ice lanes: terrain=%zu "
                        "base_terrain=%zu sea_ice_frac_inout=%zu tta=%zu "
                        "upwelling=%zu insol_now=%zu cell_temp_arr=%zu "
                        "water_terrain_ids=%zu\n",
                        _round_in.terrain.size(), _round_in.base_terrain.size(),
                        _round_in.sea_ice_frac_inout.size(),
                        _round_in.temp_transport_anomaly.size(),
                        _round_in.upwelling_strength.size(),
                        _round_in.insolation_now.size(),
                        _round_in.cell_temperature_arr.size(),
                        _round_in.water_terrain_ids.size());
                }
                std::fflush(stderr);
            }
        }
        report.round_passes_ran = timing.passes_ran;
        // passes_mask 的 bit 0..7 与 RuntimeClimateStage 的 PASS_A..TRANSPIRATION
        // 一一对应；bit 8 是 finalizer，它不是一个 stage（没有自己的 stage 槽位）。
        report.stage_ran_mask |= timing.passes_ran & 0xFF;
        if (!round_ok) {
            runtime_copy_text(report.error, "climate_shared_round_failed");
            return false;
        }

        // 把编排输出散射回 store。只写生产侧确实由这些 pass 授权的 lane——
        // 多写一条就会掩盖后面尚未接入共享实现的 stage 的真实分叉。
        auto scatter = [cells](std::vector<float> &dst,
                               const std::vector<float> &src) {
            if (src.size() == cells) std::memcpy(dst.data(), src.data(),
                                                 cells * sizeof(float));
        };
        scatter(next.temperature_baseline, _round_out.temp_baseline);
        scatter(next.thermal_energy,       _round_out.thermal_energy);
        scatter(next.moisture,             _round_out.moisture);
        scatter(next.temperature_30d_ema,  _round_out.temp_30d);
        scatter(next.temperature_365d_ema, _round_out.temp_365d);
        scatter(next.snowpack,             _round_out.snowpack);
        // cell_temp 由 wind_surface 末端合成、finalizer 收尾 clamp；这是 round 内
        // 温度场的唯一授权写者。
        scatter(next.temperature,          _round_out.temp);
        scatter(next.sea_ice,              _round_out.sea_ice_frac);

        // 逐 pass 耗时记进对应 stage 槽位（索引与 passes_mask 的 bit 位一致）。
        // finalizer 没有独立 stage 槽，它的耗时并入 round 尾巴不单列。
        static constexpr RuntimeClimateStage PASS_STAGES[8] = {
            RuntimeClimateStage::PASS_A,       RuntimeClimateStage::PASS_B,
            RuntimeClimateStage::OCEAN_WATER,  RuntimeClimateStage::OCEAN_LAND,
            RuntimeClimateStage::WIND_AIR,     RuntimeClimateStage::WIND_SURFACE,
            RuntimeClimateStage::SEA_ICE,      RuntimeClimateStage::TRANSPIRATION,
        };
        for (size_t k = 0; k < 8; ++k) {
            // 只记真的跑过的 pass。以前这里无条件按 cells 记账，于是被 mask 关掉或
            // 被 starve 掉的 pass 也会报出一份满额工作量而耗时为 0——导出到
            // performance.csv 之后，那一行看起来像"这个 stage 免费算完了 2400 个
            // cell"，恰好是最容易被当成优化成果的假象。
            if ((timing.passes_ran & (1 << k)) == 0) continue;
            const size_t slot = static_cast<size_t>(PASS_STAGES[k]);
            report.stage_ms[slot] = static_cast<double>(timing.pass_us[k]) / 1000.0;
            report.stage_work[slot] = static_cast<uint64_t>(cells);
            report.work_units += static_cast<uint64_t>(cells);
        }
        shared_round_ran = true;
    }

    // ─── 以下是 shared_passes_available == false 时的诊断近似 ─────────────
    // 它们不具备 parity 语义。共享 round 跑过时必须整段跳过，否则会把刚算出来的
    // 场重新覆盖成近似值。
    if (input.climate_round_ran && !shared_round_ran) {
    run_stage(report, RuntimeClimateStage::PASS_A, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float ny = climate_formula::clamp01(
                read_or(input.cell_lat_norm, i, 0.5f));
            const float elevation = read_or(input.cell_elevation, i, 0.0f);
            const bool is_water = read_or(input.is_water, i, 0u) != 0u;
            const float annual_mean = climate_formula::annual_insolation_mean(
                ny, catalog.axial_tilt_deg, catalog.day_length_gain);
            const float current_insolation = climate_formula::daily_insolation(
                ny, season, catalog.axial_tilt_deg, catalog.day_length_gain);
            float deviation = climate_formula::insolation_season_dev(
                ny, current_insolation,
                annual_mean);
            deviation = climate_formula::clamp(
                deviation, catalog.insol_dev_min, catalog.insol_dev_max);

            float base_moisture = read_or(input.cell_base_moisture, i,
                                          read_or(input.cell_moisture, i, 0.0f));
            base_moisture = climate_formula::clamp01(base_moisture);
            float moisture_target = base_moisture;
            if (!is_water) {
                if (input.cell_weather_vapor.size() == cells) {
                    const float vapor = climate_formula::clamp(
                        input.cell_weather_vapor[i], 0.0f, 1.0f);
                    moisture_target += (vapor - base_moisture * 0.15f) *
                        catalog.runtime_moisture_weather_vapor_weight;
                }
                if (input.cell_weather_precip.size() == cells) {
                    moisture_target += climate_formula::clamp(
                        input.cell_weather_precip[i], 0.0f, 1.0f) *
                        catalog.runtime_moisture_precip_weight;
                }
                if (input.cell_soil_moisture.size() == cells) {
                    moisture_target += climate_formula::signed_hydrology_contribution(
                        climate_formula::clamp(input.cell_soil_moisture[i], -0.5f, 0.5f),
                        catalog.runtime_moisture_soil_weight,
                        catalog.runtime_moisture_soil_dry_weight);
                }
                if (input.cell_water_balance_30d.size() == cells) {
                    moisture_target += climate_formula::signed_hydrology_contribution(
                        climate_formula::clamp(input.cell_water_balance_30d[i], -1.0f, 1.0f),
                        catalog.runtime_moisture_water_balance_weight,
                        catalog.runtime_moisture_water_balance_dry_weight);
                }
                moisture_target = climate_formula::clamp01(moisture_target);
            }
            float previous_moisture = read_or(input.cell_moisture, i,
                                              current.moisture[i]);
            if (!std::isfinite(previous_moisture) || previous_moisture < 0.0f ||
                previous_moisture > 1.0f) {
                previous_moisture = moisture_target;
            }
            const float moisture_alpha = climate_formula::thermal_alpha_eff(
                catalog.runtime_moisture_base_relax_rate, dt);
            const float moisture_now = is_water ? moisture_target :
                climate_formula::clamp01(previous_moisture +
                    (moisture_target - previous_moisture) *
                    moisture_alpha);

            float temp_year = read_or(input.cell_temp_baseline_year, i,
                                      0.0f) - static_cast<float>(
                                          climate_formula::altitude_penalty(
                                              elevation, catalog.sea_level));
            temp_year = climate_formula::clamp01(temp_year);
            const float insolation_gain = catalog.insol_amp * catalog.insol_gain;
            float season_offset = climate_formula::season_offset_continental(
                insolation_gain, is_water,
                current.temperature_365d_ema[i], deviation,
                catalog.land_continentality);
            float radiative_target = climate_formula::clamp01(temp_year + season_offset);
            const float current_temp = read_or(input.cell_temp, i,
                                               current.temperature[i]);
            float previous_energy = current.thermal_energy[i];
            if (current.committed_day < 0) previous_energy = current_temp;
            float alpha = catalog.thermal_inertia_land;
            const uint8_t cover = read_or(input.cover, i, 0u);
            const float snowpack = current.snowpack[i];
            if (is_water) alpha = catalog.thermal_inertia_water;
            else if (cover == 2u || snowpack > catalog.snowpack_cover_low)
                alpha = catalog.thermal_inertia_snow;
            else if (elevation > 0.70f)
                alpha = catalog.thermal_inertia_high_mountain;
            alpha = climate_formula::thermal_alpha_eff(alpha, dt);
            const float heat_next = previous_energy +
                (radiative_target - previous_energy) * alpha;
            const float delta_cap = std::max(0.0f,
                catalog.thermal_daily_delta_cap) * dt;
            const float temp_now = climate_formula::clamp01(
                previous_energy + climate_formula::clamp(
                    heat_next - previous_energy, -delta_cap, delta_cap));
            next.temperature_baseline[i] = temp_now;
            next.thermal_energy[i] = heat_next;
            next.moisture[i] = moisture_now;
            next.temperature_30d_ema[i] = current.temperature_30d_ema[i] +
                (temp_now - current.temperature_30d_ema[i]) *
                climate_formula::thermal_alpha_eff(1.0f / 30.0f, dt);
            next.temperature_365d_ema[i] = current.temperature_365d_ema[i] +
                (temp_now - current.temperature_365d_ema[i]) *
                climate_formula::thermal_alpha_eff(
                    1.0f / static_cast<float>(std::max(1u, catalog.days_per_year)), dt);
            next.snowpack[i] = is_water ? 0.0f : snowpack;
            next.snow_cover[i] = climate_formula::clamp01(next.snowpack[i]);
            next.temperature[i] = temp_now;
            next.convergence[i] = 0.0f;
            next.vapor[i] = read_or(input.cell_weather_vapor, i, current.vapor[i]);
            next.weather_precipitation[i] = read_or(input.cell_weather_precip, i,
                                                     current.weather_precipitation[i]);
            next.weather_intensity[i] = read_or(input.cell_weather_intensity, i,
                                                current.weather_intensity[i]);
            next.plant_available_water[i] = read_or(input.cell_plant_available_water,
                                                    i, current.plant_available_water[i]);
        }
        return static_cast<uint64_t>(cells) * 6u;
    });
    run_stage(report, RuntimeClimateStage::PASS_B, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float moisture = read_or(input.cell_moisture, i, current.moisture[i]);
            const float terrain = static_cast<float>(read_or(input.terrain, i, 0u));
            next.moisture[i] = std::clamp(moisture + (terrain > 0.0f ? -0.002f : 0.002f), 0.0f, 1.0f);
            next.temperature[i] = next.thermal_energy[i] + next.temperature_baseline[i] * 0.05f;
        }
        return static_cast<uint64_t>(cells) * 3u;
    });
    run_stage(report, RuntimeClimateStage::OCEAN_WATER, [&]() {
        for (size_t i = 0; i < cells; ++i) if (read_or(input.is_water, i, 0u) != 0) {
            next.temperature[i] = next.temperature[i] * 0.96f + current.temperature_365d_ema[i] * 0.04f;
        }
        return static_cast<uint64_t>(cells);
    });
    run_stage(report, RuntimeClimateStage::OCEAN_LAND, [&]() {
        for (size_t i = 0; i < cells; ++i) if (read_or(input.is_water, i, 0u) == 0) {
            next.temperature[i] += (next.moisture[i] - 0.5f) * 0.15f;
        }
        return static_cast<uint64_t>(cells);
    });
    run_stage(report, RuntimeClimateStage::WIND_AIR, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            float sum = 0.0f;
            uint32_t count = 0;
            const size_t begin = input.neighbor_offsets.empty() ? i * 6u :
                static_cast<size_t>(input.neighbor_offsets[i]);
            const size_t end = input.neighbor_offsets.empty() ? begin + 6u :
                static_cast<size_t>(input.neighbor_offsets[i + 1u]);
            for (size_t p = begin; p < end && p < input.neighbor_indices.size(); ++p) {
                const int32_t n = input.neighbor_indices[p];
                if (n >= 0) { sum += next.temperature[static_cast<size_t>(n)]; ++count; }
            }
            next.convergence[i] = count == 0 ? 0.0f : (sum / static_cast<float>(count) - next.temperature[i]);
        }
        return static_cast<uint64_t>(cells) * 7u;
    });
    run_stage(report, RuntimeClimateStage::WIND_SURFACE, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] += next.convergence[i] * 0.18f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::SEA_ICE, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            float ice = current.sea_ice[i];
            if (read_or(input.is_water, i, 0u) != 0) {
                if (next.temperature[i] < catalog.sea_ice_freeze) ice += 0.04f * dt;
                else if (next.temperature[i] > catalog.sea_ice_melt) ice -= 0.03f * dt;
            } else ice = 0.0f;
            next.sea_ice[i] = std::clamp(ice, 0.0f, 1.0f);
            next.snowpack[i] = std::max(0.0f, current.snowpack[i] +
                (next.temperature[i] < 0.0f ? 0.01f : -0.02f * dt));
            next.snow_cover[i] = std::clamp(next.snowpack[i], 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 5u;
    });
    run_stage(report, RuntimeClimateStage::TRANSPIRATION, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float heat = std::max(0.0f, next.temperature[i] - 3.0f) / 35.0f;
            next.vegetation_growth_pressure[i] = std::clamp(next.plant_available_water[i] * heat, 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::ALBEDO, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] -= next.snow_cover[i] * 0.4f + next.sea_ice[i] * 0.25f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::VEGETATION_DYNAMICS, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.vegetation_heat_stress[i] = std::clamp((next.temperature[i] - 30.0f) / 20.0f, 0.0f, 1.0f);
            next.vegetation_drought_stress[i] = 1.0f - std::clamp(next.plant_available_water[i], 0.0f, 1.0f);
            next.vegetation_cold_stress[i] = std::clamp((-next.temperature[i]) / 20.0f, 0.0f, 1.0f);
            const float pressure = next.vegetation_growth_pressure[i] -
                (next.vegetation_heat_stress[i] + next.vegetation_drought_stress[i] + next.vegetation_cold_stress[i]) / 3.0f;
            next.vegetation_vitality[i] = std::clamp(current.vegetation_vitality[i] + pressure * 0.02f, 0.0f, 1.0f);
            next.vegetation_growth_streak[i] = pressure > 0.0f ? current.vegetation_growth_streak[i] + 1 : 0;
            next.vegetation_drought_streak[i] = next.vegetation_drought_stress[i] > 0.7f ? current.vegetation_drought_streak[i] + 1 : 0;
            next.vegetation_succession_candidate[i] = next.vegetation_growth_streak[i] >= 30 ? 1u : 0u;
        }
        return static_cast<uint64_t>(cells) * 9u;
    });
    run_stage(report, RuntimeClimateStage::CLIMATE_FEEDBACK, [&]() {
        for (size_t i = 0; i < cells; ++i) next.temperature[i] += (next.vegetation_vitality[i] - 0.5f) * 0.05f;
        return static_cast<uint64_t>(cells) * 2u;
    });
    run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.vapor[i] = std::clamp(next.moisture[i] + std::max(0.0f, next.temperature[i]) * 0.004f, 0.0f, 1.0f);
            next.cloud_water[i] = std::max(0.0f, next.vapor[i] + next.convergence[i] * 0.02f - 0.35f);
            next.cloud_cover[i] = std::clamp(next.cloud_water[i] * 2.0f, 0.0f, 1.0f);
            next.instability[i] = std::clamp(std::abs(next.temperature[i] - next.temperature_30d_ema[i]) / 12.0f, 0.0f, 1.0f);
            const float precipitation = std::max(0.0f, next.cloud_water[i] * (0.25f + next.instability[i]));
            next.weather_precipitation[i] = precipitation;
            next.weather_intensity[i] = std::clamp(precipitation * 4.0f, 0.0f, 1.0f);
            const uint8_t type = precipitation > 0.20f ? 3u : precipitation > 0.04f ? 2u : next.cloud_cover[i] > 0.35f ? 1u : 0u;
            // 过渡三条 lane：这条诊断近似路径没有生产的 rate/dt knob，只记"从哪个
            // 类型过渡到哪个类型"，alpha 立即完成。它不具备 parity 语义（整条
            // fallback 都不具备），真正的过渡状态机在 stage 11 的共享内核里。
            if (next.weather_target_type[i] != type) {
                next.weather_prev_type[i] = current.weather_type[i];
                next.weather_target_type[i] = type;
            }
            next.weather_transition_alpha[i] = 0.0f;
            next.weather_type[i] = type;
        }
        return static_cast<uint64_t>(cells) * 10u;
    });
    run_stage(report, RuntimeClimateStage::RUNTIME_HYDROLOGY, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            const float melt = next.temperature[i] > 0.0f ? std::min(next.snowpack[i], next.temperature[i] * 0.01f) : 0.0f;
            next.snowpack[i] -= melt;
            const float inflow = next.weather_precipitation[i] + melt + read_or(input.canal_water, i, 0.0f);
            const float water = std::clamp(current.plant_available_water[i] + inflow - next.vegetation_growth_pressure[i] * 0.015f, 0.0f, catalog.soil_capacity);
            next.plant_available_water[i] = water;
            next.water_balance_30d[i] = current.water_balance_30d[i] * (29.0f / 30.0f) + (inflow - next.vegetation_growth_pressure[i] * 0.015f) / 30.0f;
            next.runoff[i] = std::max(0.0f, water - 0.85f);
            next.groundwater[i] = std::max(0.0f, current.groundwater[i] * 0.995f + next.runoff[i] * 0.15f);
            next.river_storage[i] = std::max(0.0f, current.river_storage[i] + next.runoff[i] - current.river_discharge[i]);
            next.river_discharge[i] = next.river_storage[i] * (read_or(input.has_river, i, 0u) != 0 ? 0.25f : 0.02f);
            next.riparian_moisture[i] = std::clamp(water + next.river_discharge[i] * 0.25f, 0.0f, 1.0f);
        }
        return static_cast<uint64_t>(cells) * 11u;
    });
    run_stage(report, RuntimeClimateStage::STAGE_B_AFTER_HYDROLOGY, [&]() {
        for (size_t i = 0; i < cells; ++i) {
            next.moisture[i] = std::clamp(next.moisture[i] * 0.9f + next.plant_available_water[i] * 0.1f, 0.0f, 1.0f);
            if (next.temperature[i] != current.temperature[i] ||
                next.plant_available_water[i] != current.plant_available_water[i] ||
                next.weather_precipitation[i] != current.weather_precipitation[i]) ++report.changed_cells;
        }
        return static_cast<uint64_t>(cells) * 3u;
    });
    }

    // ─── stage 8 ALBEDO（共享纯内核，节拍独立于 round）────────────────────
    //
    // 生产侧 albedo 是一个仿真日内 temp 的最后一个写者：round 末尾 wind_surface /
    // finalizer 定下温度后，stage_b 再叠一层 (reference_albedo - alb) * gain。所以这里
    // 必须排在 round 之后，且只在生产当天真的跑过 albedo 时跑。
    //
    // 输入全部取自 environment 快照（is_water / vegetation / cover）与 static knobs 的
    // albedo_table —— 与生产 stage_b 从 SoA slot 读的是同一批 lane。
    // 走了上面那条近似回退时不叠 albedo：那条路径自带一份 ALBEDO 近似，再叠一次共享
    // 内核等于对同一天算两遍。回退路径本来就没有 parity 语义，保持它自洽即可。
    const bool shared_albedo_ran = input.climate_albedo.ran &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_albedo_ran) {
        run_stage(report, RuntimeClimateStage::ALBEDO, [&]() {
            const auto &knobs = input.climate_round_static_knobs;
            if (input.is_water.size() != cells ||
                input.vegetation.size() != cells ||
                input.cover.size() != cells ||
                knobs.albedo_table.empty()) {
                return static_cast<uint64_t>(0);
            }
            pk_async_climate::albedo_apply_pure(
                input.climate_albedo, input.is_water.data(),
                input.vegetation.data(), input.cover.data(),
                knobs.albedo_table.data(),
                static_cast<int>(knobs.albedo_table.size()),
                next.temperature.data(), static_cast<int>(cells));
            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_ALBEDO;
            return static_cast<uint64_t>(cells);
        });
    }

    // ─── stage 9 VEGETATION_DYNAMICS（共享纯内核，节拍独立于 round）────────
    //
    // 顺序必须夹在 albedo 与 feedback 之间：生产 stage_b 就是 ① albedo → ②
    // vegetation → ③ feedback 这个顺序，而三段之间通过 SoA 直接接力
    //（albedo 写 temp、vegetation 写 plant_available_water、feedback 读改后的场）。
    //
    // 输入 lane 的取值来源分两类，这个划分是当前 S3 进度的直接反映：
    //   - is_water / terrain / landform / vegetation / temp_30d / moisture /
    //     water_balance_30d / weather_* 取生产的记录。其中 water_balance_30d 与
    //     weather_* 的生产者（hydrology / weather）还没有共享实现，用 worker 自己
    //     那份必然分叉；而 vegetation 会被 GDScript 侧的演替后处理改写，那次写入
    //     不属于任何 climate stage，快照里也拿不到。stage 11/12 提取完成后，这几条
    //     才有资格换成 worker 自己的场。
    //   - vitality / streak / heat / drought / cold 与 plant_available_water /
    //     vegetation_growth_pressure 是 store 成员，必须读写 worker 自己那一份，
    //     否则 parity 就退化成"把生产的结果抄一遍"。
    //   - regen_score 没有 float store 成员，用 scratch 承接生产读到的初值后丢弃。
    const bool shared_vegetation_ran = vegetation_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_vegetation_ran) {
        run_stage(report, RuntimeClimateStage::VEGETATION_DYNAMICS, [&]() {
            const pk_async_climate::VegetationDynamicsInput &vd = *input.climate_vegetation;
            if (vd.is_water.size() != cells || vd.terrain.size() != cells ||
                vd.landform.size() != cells || vd.vegetation.size() != cells ||
                vd.temp_30d.size() != cells || vd.moisture.size() != cells ||
                vd.water_balance_30d.size() != cells ||
                vd.weather_type.size() != cells ||
                vd.weather_intensity.size() != cells ||
                vd.weather_field_init.size() != cells ||
                next.plant_available_water.size() != cells ||
                next.vegetation_vitality.size() != cells ||
                next.vegetation_drought_streak.size() != cells ||
                next.vegetation_growth_streak.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                return static_cast<uint64_t>(0);
            }
            pk_async_climate::VegetationDynamicsKnobs knobs = vd.knobs;
            pk_async_climate::VegetationDynamicsTables tables;
            tables.ideal_temp = vd.ideal_temp.data();
            tables.ideal_moist = vd.ideal_moist.data();
            tables.temp_tol = vd.temp_tol.data();
            tables.moist_tol = vd.moist_tol.data();
            tables.weather_penalty = vd.weather_penalty.data();
            tables.resistance = vd.resistance.data();
            tables.next_up = vd.next_up.data();
            tables.next_down = vd.next_down.data();

            pk_async_climate::VegetationDynamicsLanes lanes;
            lanes.is_water = vd.is_water.data();
            lanes.terrain = vd.terrain.data();
            lanes.landform = vd.landform.data();
            lanes.vegetation = vd.vegetation.data();
            lanes.temp_30d = vd.temp_30d.data();
            lanes.moisture = vd.moisture.data();
            lanes.water_balance_30d = vd.water_balance_30d.data();
            lanes.soil_moisture = vd.has_soil_moisture ? vd.soil_moisture.data() : nullptr;
            lanes.weather_type = vd.weather_type.data();
            lanes.weather_intensity = vd.weather_intensity.data();
            lanes.weather_field_init = vd.weather_field_init.data();
            lanes.plant_available_water = next.plant_available_water.data();
            lanes.vegetation_growth_pressure =
                (vd.has_growth_pressure &&
                 next.vegetation_growth_pressure.size() == cells)
                    ? next.vegetation_growth_pressure.data() : nullptr;
            lanes.vitality = next.vegetation_vitality.data();
            lanes.low_streak = next.vegetation_drought_streak.data();
            lanes.high_streak = next.vegetation_growth_streak.data();
            if (knobs.stress_enabled) {
                if (next.vegetation_heat_stress.size() != cells ||
                    next.vegetation_drought_stress.size() != cells ||
                    next.vegetation_cold_stress.size() != cells ||
                    vd.regen_score.size() != cells) {
                    return static_cast<uint64_t>(0);
                }
                lanes.heat_stress = next.vegetation_heat_stress.data();
                lanes.drought_stress = next.vegetation_drought_stress.data();
                lanes.cold_stress = next.vegetation_cold_stress.data();
                _vegetation_regen_scratch = vd.regen_score;
                lanes.regen_score = _vegetation_regen_scratch.data();
            }
            pk_async_climate::VegetationDynamicsEmit emit;
            pk_async_climate::vegetation_dynamics_apply_pure(
                knobs, tables, lanes, 0, static_cast<int>(cells), emit);
            // 演替本身（写 cell.vegetation）由 GDScript 后处理执行，不在 store 里，
            // 所以 worker 只消费 emit 的规模用作 stage 统计。
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_VEGETATION_DYNAMICS;
            return static_cast<uint64_t>(cells);
        });
    }

    // ─── stage 10 CLIMATE_FEEDBACK（共享纯内核，节拍独立于 round）──────────
    //
    // 输入整份取自生产的记录，而不是 environment 快照的同名 lane：feedback 跑在
    // stage_b 段（weather 之后），快照是 tick 起始拍的，weather_type /
    // weather_intensity 在这两个时刻之间正好被 weather pass 整场重写过。
    //
    // 状态所有权分两类，不能混：
    //   base_moisture / soil_moisture — 不在 canonical parity 字段表里，worker store
    //       也没有对应成员。用 scratch 承接生产读到的初值，输出丢弃。
    //   vegetation_growth_pressure — 是 store 成员。必须读写 worker 自己那一份，
    //       否则 parity 就退化成"把生产的结果抄一遍"，什么都验不出来。
    const bool shared_feedback_ran = feedback_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_feedback_ran) {
        run_stage(report, RuntimeClimateStage::CLIMATE_FEEDBACK, [&]() {
            const pk_async_climate::ClimateFeedbackInput &fb = *input.climate_feedback;
            const auto &neighbors = input.climate_round_static_knobs.neighbor_indices;
            if (fb.is_water.size() != cells || fb.weather_type.size() != cells ||
                fb.weather_intensity.size() != cells ||
                fb.weather_field_init.size() != cells ||
                fb.temp_transport_anomaly.size() != cells ||
                fb.base_moisture.size() != cells ||
                fb.soil_moisture.size() != cells ||
                neighbors.size() < cells * 6u ||
                next.vegetation_growth_pressure.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                // production_stage_mask 里有 feedback 而 stage_ran_mask 里没有，
                // 差集就会把它报出来，不会变成一次静默 no-op。
                return static_cast<uint64_t>(0);
            }
            _feedback_base_moisture = fb.base_moisture;
            _feedback_soil_moisture = fb.soil_moisture;
            pk_async_climate::climate_feedback_apply_pure(
                fb.knobs, fb.is_water.data(), fb.weather_type.data(),
                fb.weather_intensity.data(), fb.weather_field_init.data(),
                neighbors.data(), fb.temp_transport_anomaly.data(),
                _feedback_base_moisture.data(), _feedback_soil_moisture.data(),
                next.vegetation_growth_pressure.data(),
                0, static_cast<int>(cells));
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_CLIMATE_FEEDBACK;
            return static_cast<uint64_t>(cells);
        });
    }

    // ─── stage 11 WEATHER（共享纯内核，weather bucket 自己的 cadence）────────
    //
    // 状态所有权在这一段分得最细，因为 weather 是 climate 里跨 tick 状态最多的一段：
    //
    //   worker 自己那一份（store 成员，真正被对拍的量）：
    //       vapor / cloud_water / cloud_cover / weather_precipitation /
    //       weather_intensity / convergence / instability / weather_type 与过渡三条。
    //       prev_* 输入也取自 worker 的 store —— 也就是它自己昨天算出来的场。天气
    //       是强惯性系统（vapor/cloud 都带 inertia 项），所以逐日累积的偏差会被
    //       如实放大出来，这正是这一段该验的东西。
    //   生产记录那一份（worker 无从重建）：
    //       风场、温度、湿度等读 lane —— 它们的生产者（wind / pass_b）还没提取；
    //       ψ、对流抑制、气旋强迫、季风热力、回溯轨迹表 —— 都不是 store 成员，且
    //       ψ 与轨迹表都由 wind pass 派生并带指纹校验。这几组照抄生产当天用过的
    //       那一份，输出丢弃。stage 12/13 与 wind 提取完之后才有资格换成 worker 的。
    //
    // use_next_outputs 在 worker 侧一律取 false：生产 native daily 走 staged，把原始
    // 类型写进 int32 next buffer、由 commit pass 落成显示类型；worker 没有 commit
    // pass，用 direct 语义可以在同一次调用里直接得到显示类型。这个 flag 在内核里只
    // 切换"写 int32 原始类型"与"写 u8 显示类型 + field_init"，不影响任何数值。
    const bool shared_weather_ran = weather_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_weather_ran) {
        run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
            const pk_async_climate::WeatherFieldInput &wx = *input.climate_weather;
            const auto &neighbors = input.climate_round_static_knobs.neighbor_indices;
            const auto lane_ok = [cells](const std::vector<float> &v) {
                return v.size() == cells;
            };
            if (!lane_ok(wx.temp_read) || !lane_ok(wx.moisture_read) ||
                !lane_ok(wx.air_anomaly) || !lane_ok(wx.wind_x) ||
                !lane_ok(wx.wind_y) || !lane_ok(wx.wind_speed) ||
                !lane_ok(wx.elevation) || !lane_ok(wx.pos_x) ||
                !lane_ok(wx.pos_y) || !lane_ok(wx.temp_transport_anomaly) ||
                wx.terrain.size() != cells || wx.has_river.size() != cells ||
                wx.vegetation.size() != cells ||
                neighbors.size() < cells * 6u ||
                next.vapor.size() != cells || next.cloud_water.size() != cells ||
                next.cloud_cover.size() != cells ||
                next.weather_precipitation.size() != cells ||
                next.weather_intensity.size() != cells ||
                next.convergence.size() != cells ||
                next.instability.size() != cells ||
                next.weather_type.size() != cells ||
                next.weather_prev_type.size() != cells ||
                next.weather_target_type.size() != cells ||
                next.weather_transition_alpha.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                // 这一段的 bit 与 distribute 共用（同属 stage 11），所以静默返回
                // 会被 distribute 的成功掩盖 —— 说一次哪条短了。
                static std::atomic<bool> wx_starved_reported{false};
                bool expected = false;
                if (wx_starved_reported.compare_exchange_strong(expected, true)) {
                    std::fprintf(stderr,
                        "[climate/worker] weather starved: temp=%zu moist=%zu air=%zu "
                        "wx=%zu wy=%zu wspd=%zu elev=%zu posx=%zu posy=%zu tta=%zu "
                        "terrain=%zu river=%zu veg=%zu nb=%zu | store vapor=%zu "
                        "cloudw=%zu cloud=%zu precip=%zu intens=%zu conv=%zu "
                        "instab=%zu type=%zu prev=%zu target=%zu alpha=%zu | cells=%zu\n",
                        wx.temp_read.size(), wx.moisture_read.size(),
                        wx.air_anomaly.size(), wx.wind_x.size(), wx.wind_y.size(),
                        wx.wind_speed.size(), wx.elevation.size(), wx.pos_x.size(),
                        wx.pos_y.size(), wx.temp_transport_anomaly.size(),
                        wx.terrain.size(), wx.has_river.size(),
                        wx.vegetation.size(), neighbors.size(),
                        next.vapor.size(), next.cloud_water.size(),
                        next.cloud_cover.size(), next.weather_precipitation.size(),
                        next.weather_intensity.size(), next.convergence.size(),
                        next.instability.size(), next.weather_type.size(),
                        next.weather_prev_type.size(),
                        next.weather_target_type.size(),
                        next.weather_transition_alpha.size(), cells);
                }
                return static_cast<uint64_t>(0);
            }
            // prev_* 必须是独立缓冲：内核会读 PREV_CNV[upstream_idx]，upstream 可能
            // 小于 i，与 OUT_CNV 共用同一块内存就会读到本轮已经改写过的值。生产
            // staged 路径用的是两块 buffer，这里跟着分开。
            _weather_prev_vapor = next.vapor;
            _weather_prev_precip = next.weather_precipitation;
            _weather_prev_cloud_water = next.cloud_water;
            _weather_prev_cloud = next.cloud_cover;
            _weather_prev_convergence = next.convergence;
            // own_field_state 决定 conv_inhib 跨天归属（见 WeatherFieldInput）。
            if (!wx.own_field_state || _weather_conv_inhib.size() != cells) {
                _weather_conv_inhib = wx.conv_inhib;
            }
            // field_init 是"这张图的天气场是否已经解算过一次"，一置 1 就长期为真。
            // 从前这里每轮 assign(cells, 0)，于是 distribute 侧读到的永远是"未初始化"
            // （它按 field_init 决定 weather_type/intensity/precip 取真值还是取 0），
            // worker 的天气输出因此成片写零。只在首次分配，之后由 commit 置位。
            const bool field_init_fresh =
                _weather_field_init_scratch.size() != cells;
            if (field_init_fresh) {
                _weather_field_init_scratch.assign(cells, 0u);
            }
            // 生产生成阶段通常已经把 field_init 置 1。worker 若从全零起步会按
            // moisture*0.15 重做 spinup，vapor 因此整场偏 0.15。
            // own_field_state 下只首次播种。commit 会把解算过的格子置 1，每天拿
            // input 覆盖会把这份记忆抹掉 —— 若覆盖成全 1，下面的 spinup 就被整场
            // 跳过，prev_vapor 停在 store 的 0，水汽循环永远起不来（vapor / precip
            // 全场恒 0）；若覆盖成全 0 则每天重做 spinup，同样不是演化。
            if (wx.field_init.size() == cells &&
                (!wx.own_field_state || field_init_fresh)) {
                _weather_field_init_scratch = wx.field_init;
            }
            // 未初始化的格子不读 SoA vapor/precip —— 那份此刻还是零，而生产按稳态
            // 量级 moisture * WEATHER_SPINUP_VAPOR_FRACTION 起步（field_solver.gd 的
            // 首帧暴雨修复：prev_vapor=moisture 会让首 tick 处处过饱和）。少了这一步，
            // worker 首轮的 prev_vapor 就整场低 0.15，而天气是强惯性系统，这个偏差
            // 会一路带到 cloud / instability / precipitation。
            if (wx.moisture_read.size() == cells) {
                constexpr float WEATHER_SPINUP_VAPOR_FRACTION = 0.15f;
                for (size_t i = 0; i < cells; ++i) {
                    if (_weather_field_init_scratch[i] > 0) continue;
                    _weather_prev_vapor[i] =
                        wx.moisture_read[i] * WEATHER_SPINUP_VAPOR_FRACTION;
                    _weather_prev_precip[i] = 0.0f;
                }
            }
            // staged next buffer：生产 native daily 的 weather_advance 把结果写进
            // 调用方给的 next buffer（weather_type 走 int32），再由 weather_commit
            // 落到 slot 并解析 display/transition/field_init。worker 必须走同一分支，
            // 否则两边在同一 stage 上跑同一内核的不同分支。
            auto ensure_f32 = [cells](std::vector<float> &v) {
                if (v.size() != cells) v.assign(cells, 0.0f);
            };
            ensure_f32(_wx_next_vapor);
            ensure_f32(_wx_next_cloud);
            ensure_f32(_wx_next_cloud_water);
            ensure_f32(_wx_next_precip);
            ensure_f32(_wx_next_instability);
            ensure_f32(_wx_next_intensity);
            ensure_f32(_wx_next_convergence);
            if (_wx_next_type.size() != cells) _wx_next_type.assign(cells, 0);
            if (_weather_dirty_scratch.size() != cells) {
                _weather_dirty_scratch.assign(cells, 0u);
            }

            pk_async_climate::WeatherFieldKnobs knobs = wx.knobs;
            knobs.use_next_outputs = true;

            pk_async_climate::WeatherFieldLanes lanes;
            lanes.temp_read = wx.temp_read.data();
            lanes.moisture_read = wx.moisture_read.data();
            lanes.air_anomaly = wx.air_anomaly.data();
            lanes.wind_x = wx.wind_x.data();
            lanes.wind_y = wx.wind_y.data();
            lanes.wind_speed = wx.wind_speed.data();
            lanes.terrain = wx.terrain.data();
            lanes.has_river = wx.has_river.data();
            lanes.river_q30 = lane_ok(wx.river_q30) ? wx.river_q30.data() : nullptr;
            lanes.elevation = wx.elevation.data();
            lanes.vegetation = wx.vegetation.data();
            lanes.soil_moisture =
                lane_ok(wx.soil_moisture) ? wx.soil_moisture.data() : nullptr;
            lanes.vitality = lane_ok(wx.vitality) ? wx.vitality.data() : nullptr;
            lanes.sea_ice = lane_ok(wx.sea_ice) ? wx.sea_ice.data() : nullptr;
            lanes.pos_x = wx.pos_x.data();
            lanes.pos_y = wx.pos_y.data();
            lanes.temp_anomaly =
                lane_ok(wx.temp_anomaly) ? wx.temp_anomaly.data() : nullptr;
            lanes.snow_cover =
                lane_ok(wx.snow_cover) ? wx.snow_cover.data() : nullptr;
            lanes.neighbor_indices = neighbors.data();
            lanes.temp_transport_anomaly = wx.temp_transport_anomaly.data();
            lanes.prev_vapor = _weather_prev_vapor.data();
            lanes.prev_precip = _weather_prev_precip.data();
            lanes.prev_cloud_water = _weather_prev_cloud_water.data();
            lanes.prev_cloud = _weather_prev_cloud.data();
            lanes.prev_convergence = _weather_prev_convergence.data();
            // staged 分支：写 next buffer，类型走 int32；transition 三条与
            // field_init 在这一步是 nullptr（与生产 world_ext_weather.cpp:698-705
            // 的 use_next_outputs=true 分支一致），由随后的 commit 解析。
            lanes.out_vapor = _wx_next_vapor.data();
            lanes.out_cloud = _wx_next_cloud.data();
            lanes.out_cloud_water = _wx_next_cloud_water.data();
            lanes.out_precip = _wx_next_precip.data();
            lanes.out_instability = _wx_next_instability.data();
            lanes.out_intensity = _wx_next_intensity.data();
            lanes.out_convergence = _wx_next_convergence.data();
            lanes.out_type_i32 = _wx_next_type.data();
            lanes.out_type_u8 = nullptr;
            lanes.out_prev_type = nullptr;
            lanes.out_target_type = nullptr;
            lanes.out_alpha = nullptr;
            lanes.out_field_init = nullptr;

            pk_async_climate::WeatherFieldState state;
            state.conv_inhib =
                _weather_conv_inhib.size() == cells ? _weather_conv_inhib.data() : nullptr;
            state.psi = (wx.synoptic_enabled && wx.psi.size() == cells)
                ? wx.psi.data() : nullptr;
            if (wx.cyclone_tag.size() == cells) {
                state.cyclone_tag = wx.cyclone_tag.data();
                state.cyclone_tag_count = static_cast<int>(cells);
                state.cyclone_generation = wx.cyclone_generation;
                state.cyclone_lift =
                    lane_ok(wx.cyclone_lift) ? wx.cyclone_lift.data() : nullptr;
                state.cyclone_x = lane_ok(wx.cyclone_x) ? wx.cyclone_x.data() : nullptr;
                state.cyclone_y = lane_ok(wx.cyclone_y) ? wx.cyclone_y.data() : nullptr;
            }
            if (lane_ok(wx.monsoon_thermal)) {
                state.monsoon_thermal = wx.monsoon_thermal.data();
                state.monsoon_thermal_count = static_cast<int>(cells);
            }
            if (wx.traj_idx.size() == cells * 3u && wx.traj_w.size() == cells * 3u) {
                state.traj_idx = wx.traj_idx.data();
                state.traj_w = wx.traj_w.data();
            }
            // 几何缓存由 worker 自己按 pos + wrap 重建：内核里缓存命中与 _xy 现算
            // 是同序同式，bit-equal，所以这块纯粹是省时间。
            const size_t geom_n = cells * 6u;
            if (_weather_geom_dx.size() != geom_n) {
                _weather_geom_dx.assign(geom_n, 0.0f);
                _weather_geom_dy.assign(geom_n, 0.0f);
                _weather_geom_invd.assign(geom_n, 0.0f);
            }
            pk_async_climate::weather_field_geometry_cache_pure(
                static_cast<int>(cells), neighbors.data(), wx.pos_x.data(),
                wx.pos_y.data(), knobs.weather_wrap_width_x,
                _weather_geom_dx.data(), _weather_geom_dy.data(),
                _weather_geom_invd.data());
            state.geom_dx = _weather_geom_dx.data();
            state.geom_dy = _weather_geom_dy.data();
            state.geom_invd = _weather_geom_invd.data();

            pk_async_climate::weather_field_solve_pure(
                knobs, lanes, state, 0, static_cast<int>(cells));

            // weather_commit：把 next buffer 落到 store，并解析 display_type /
            // transition 三条 / field_init。生产 native daily 的 weather_commit 节点
            // 做的就是这件事，走的是同一份 weather_commit_pure。
            pk_async_climate::WeatherCommitKnobs ck;
            ck.n_cells                    = static_cast<int>(cells);
            ck.refresh_convergence        = false;   // 不需要 delta 报告
            ck.weather_transition_enabled = wx.knobs.weather_transition_enabled;
            ck.transition_rate            = wx.knobs.weather_transition_alpha_rate;
            ck.transition_dt_days         = wx.knobs.weather_transition_dt_days;
            ck.lut_slots                  = 0;

            pk_async_climate::WeatherCommitLanes cl;
            cl.next_vapor        = _wx_next_vapor.data();
            cl.next_cloud        = _wx_next_cloud.data();
            cl.next_cloud_water  = _wx_next_cloud_water.data();
            cl.next_precip       = _wx_next_precip.data();
            cl.next_instability  = _wx_next_instability.data();
            cl.next_intensity    = _wx_next_intensity.data();
            cl.next_convergence  = _wx_next_convergence.data();
            cl.next_type         = _wx_next_type.data();
            cl.prev_vapor        = _weather_prev_vapor.data();
            cl.neighbor_indices  = neighbors.data();
            cl.intensity         = next.weather_intensity.data();
            cl.cloud             = next.cloud_cover.data();
            cl.cloud_water       = next.cloud_water.data();
            cl.precip            = next.weather_precipitation.data();
            cl.vapor             = next.vapor.data();
            cl.convergence       = next.convergence.data();
            cl.instability       = next.instability.data();
            cl.type              = next.weather_type.data();
            cl.prev_type         = next.weather_prev_type.data();
            cl.target_type       = next.weather_target_type.data();
            cl.transition_alpha  = next.weather_transition_alpha.data();
            cl.field_init        = _weather_field_init_scratch.data();
            cl.dirty             = _weather_dirty_scratch.data();
            cl.lut               = nullptr;
            cl.convergence_deltas = nullptr;

            pk_async_climate::WeatherCommitStats cs;
            pk_async_climate::weather_commit_pure(ck, cl, cs);

            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
            return static_cast<uint64_t>(cells) * 6u;
        });
    }

    // ─── stage 11 后段 weather distribute（共享纯内核）────────────────────────
    //
    // 必须排在 field solve 之后、hydrology 之前：生产 native daily 的节点序是
    // weather_field → weather_commit → weather_distribute → … → runtime_hydrology，
    // 而 distribute 读 field solve 写出的 weather_type / intensity / precip，又写
    // hydrology 要读的 snowpack。
    //
    //   worker 自己那一份：temperature / moisture / snow_cover / snowpack /
    //       water_balance_30d。前两条是 distribute 之后仍会被 stage_b 改的量，后三条
    //       就是这一段的产物 —— snow_cover 尤其关键，sea_ice 与 albedo 都读它。
    //   生产记录那一份：weather_* 四条读 lane 取 worker 自己 store（field solve 刚
    //       写的），heat / elevation / landform / terrain 取记录；cover 与两条积雪
    //       计数、soil_moisture 没有 store 成员，用 scratch 承接初值后丢弃。
    const bool shared_distribute_ran = distribute_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_distribute_ran) {
        run_stage(report, RuntimeClimateStage::WEATHER, [&]() {
            const pk_async_climate::WeatherDistributeInput &wd =
                *input.climate_weather_distribute;
            if (wd.heat.size() != cells || wd.elevation.size() != cells ||
                wd.landform.size() != cells || wd.terrain.size() != cells ||
                wd.weather_intensity.size() != cells ||
                wd.weather_precip.size() != cells ||
                wd.weather_type.size() != cells ||
                wd.weather_field_init.size() != cells ||
                wd.cover.size() != cells || wd.soil_moisture.size() != cells ||
                wd.accumulated_snow_days.size() != cells ||
                wd.pre_snow_cover.size() != cells ||
                next.temperature.size() != cells || next.moisture.size() != cells ||
                next.snow_cover.size() != cells || next.snowpack.size() != cells ||
                next.water_balance_30d.size() != cells) {
                return static_cast<uint64_t>(0);
            }
            _distribute_cover_scratch = wd.cover;
            _distribute_soil_scratch = wd.soil_moisture;
            // 两条积雪计数：own_snow_state 决定跨天由谁持有（见
            // WeatherDistributeInput 那里的说明）。SHADOW 每天跟生产播种以便对拍
            // 同一条状态链；ACTIVE 只在首次（或换图）建立初值，之后 worker 自持
            // —— 否则会一直拿生产那份不再推进的缓存重置，snow_accum_days_req
            // 永远攒不满，snow_cover 于是恒为 0。
            const bool seed_snow_state = !wd.own_snow_state ||
                _distribute_acc_snow_scratch.size() != cells ||
                _distribute_pre_cover_scratch.size() != cells;
            if (seed_snow_state) {
                _distribute_acc_snow_scratch = wd.accumulated_snow_days;
                _distribute_pre_cover_scratch = wd.pre_snow_cover;
            }

            pk_async_climate::WeatherDistributeLanes lanes;
            lanes.temp = next.temperature.data();
            lanes.moisture = next.moisture.data();
            lanes.snow_cover = next.snow_cover.data();
            lanes.snowpack = next.snowpack.data();
            lanes.water_balance_30d = next.water_balance_30d.data();
            lanes.soil_moisture = _distribute_soil_scratch.data();
            lanes.cover = _distribute_cover_scratch.data();
            lanes.heat = wd.heat.data();
            lanes.elevation = wd.elevation.data();
            lanes.landform = wd.landform.data();
            lanes.terrain = wd.terrain.data();
            // 这四条走 worker 自己的 store：field solve 刚刚写过它们，拿生产的记录
            // 等于把 field solve 的对拍结果绕过去，那一段就白验了。
            // weather_field_init 没有 store 成员，而 field solve 在 worker 侧总是走
            // direct 语义（一定写 field_init=1），所以直接给全 1。
            lanes.weather_intensity = next.weather_intensity.data();
            lanes.weather_precip = next.weather_precipitation.data();
            lanes.weather_type = next.weather_type.data();
            if (_distribute_field_init_scratch.size() != cells) {
                _distribute_field_init_scratch.assign(cells, 1u);
            }
            lanes.weather_field_init = _distribute_field_init_scratch.data();

            pk_async_climate::WeatherDistributeState state;
            state.accumulated_snow_days = _distribute_acc_snow_scratch.data();
            state.pre_snow_cover = _distribute_pre_cover_scratch.data();

            pk_async_climate::WeatherDistributeEmit emit;
            pk_async_climate::weather_distribute_pure(wd.knobs, lanes, state, emit);
            report.stage_ran_mask |= pk_async_climate::CLIMATE_STAGE_BIT_WEATHER;
            return static_cast<uint64_t>(cells) * 8u;
        });
    }

    // ─── stage 12 RUNTIME_HYDROLOGY（共享纯内核，runtime_hydrology_stride）──────
    //
    // 这一段的状态几乎全是 store 成员，所以它是目前 parity 信号最强的一段：
    //
    //   worker 自己那一份（被对拍的量）：moisture / plant_available_water /
    //       water_balance_30d / runoff / groundwater / river_storage /
    //       river_discharge / riparian_moisture，以及 soil_moisture 与
    //       river_discharge_30d、canal_water 这三条 scratch。前八条都是逐日累积的
    //       水量账，一天算错就再也回不来，所以这里不能拿生产的初值播种。
    //   生产记录那一份：降水 / 天气类型 / 温度 / 热输入 / 积雪 / 植被活力 / 运河
    //       掩码等读 lane —— 它们的生产者（weather distribute / pass_b / 演替）还没
    //       提取，或者根本不是 climate stage。
    //
    // hydro_parent 直接取 environment 快照那份：它只在地图生成/regen 时重建，快照
    // 本来就带着它，再往 HydrologyInput 里抄一遍纯属每天多拷一张全图 int32。
    const bool shared_hydrology_ran = hydrology_requested &&
        (shared_round_ran || !input.climate_round_ran);
    if (shared_hydrology_ran) {
        run_stage(report, RuntimeClimateStage::RUNTIME_HYDROLOGY, [&]() {
            const pk_async_climate::HydrologyInput &hy = *input.climate_hydrology;
            const auto &neighbors = input.climate_round_static_knobs.neighbor_indices;
            if (hy.has_river.size() != cells || hy.terrain.size() != cells ||
                hy.landform.size() != cells || hy.vegetation.size() != cells ||
                hy.cover.size() != cells || hy.elevation.size() != cells ||
                hy.precip.size() != cells || hy.intensity.size() != cells ||
                hy.weather_type.size() != cells || hy.temp.size() != cells ||
                hy.heat.size() != cells || hy.snowpack.size() != cells ||
                hy.base_moisture.size() != cells || hy.is_water.size() != cells ||
                hy.vitality.size() != cells || hy.canal_mask.size() != cells ||
                hy.soil_moisture.size() != cells ||
                hy.discharge_30d.size() != cells ||
                input.hydro_parent.size() != cells ||
                next.moisture.size() != cells ||
                next.plant_available_water.size() != cells ||
                next.water_balance_30d.size() != cells ||
                next.runoff.size() != cells || next.groundwater.size() != cells ||
                next.river_storage.size() != cells ||
                next.river_discharge.size() != cells) {
                // 与 round 的 starved 同类：输入边界不完整，不是算法分叉。
                return static_cast<uint64_t>(0);
            }
            // soil_moisture / river_discharge_30d / canal_water 没有 store 成员。前两
            // 条都是 in/out 的累积量，用 scratch 承接生产读到的初值再丢弃 —— 与
            // feedback 的 soil_moisture 同处理。canal_water 是每轮重算的派生量。
            _hydrology_soil_scratch = hy.soil_moisture;
            _hydrology_q30_scratch = hy.discharge_30d;
            if (hy.canal_water.size() == cells) {
                // 与 soil / q30 同理：canal_water 跨日存活，必须每天回到生产读到的
                // 初值。只在首次分配就等于让 worker 带着自己那份独立累积往邻格灌水。
                _hydrology_canal_water_scratch = hy.canal_water;
            } else if (_hydrology_canal_water_scratch.size() != cells) {
                _hydrology_canal_water_scratch.assign(cells, 0.0f);
            }

            pk_async_climate::HydrologyLanes lanes;
            lanes.hydro_parent = input.hydro_parent.data();
            lanes.has_river = hy.has_river.data();
            lanes.terrain = hy.terrain.data();
            lanes.landform = hy.landform.data();
            lanes.vegetation = hy.vegetation.data();
            lanes.cover = hy.cover.data();
            lanes.elevation = hy.elevation.data();
            lanes.precip = hy.precip.data();
            lanes.intensity = hy.intensity.data();
            lanes.weather_type = hy.weather_type.data();
            lanes.temp = hy.temp.data();
            lanes.heat = hy.heat.data();
            lanes.snowpack = hy.snowpack.data();
            lanes.base_moisture = hy.base_moisture.data();
            lanes.is_water = hy.is_water.data();
            lanes.vitality = hy.vitality.data();
            lanes.canal_mask = hy.canal_mask.data();
            lanes.neighbor_indices = (hy.has_neighbors && neighbors.size() >= cells * 6u)
                ? neighbors.data() : nullptr;
            lanes.moisture = next.moisture.data();
            lanes.soil_moisture = _hydrology_soil_scratch.data();
            lanes.water_balance_30d = next.water_balance_30d.data();
            lanes.plant_water = next.plant_available_water.data();
            lanes.discharge = next.river_discharge.data();
            lanes.discharge_30d = _hydrology_q30_scratch.data();
            lanes.river_storage = next.river_storage.data();
            lanes.groundwater = next.groundwater.data();
            lanes.runoff = next.runoff.data();
            lanes.canal_water = _hydrology_canal_water_scratch.data();

            _hydrology_canal.topology_generation = hy.canal_topology_generation;
            pk_async_climate::HydrologyStats stats;
            pk_async_climate::hydrology_pass_pure(hy.knobs, lanes, _hydrology_canal,
                                                _hydrology_scratch, stats);
            // riparian_moisture 是 store 成员但生产侧没有对应 slot（分叉表里标
            // map_data.gd declares no riparian_moisture_arr）。它的物理定义就是河道
            // 影响后的可用水，这里跟着 plant_available_water 走，免得停在昨天的值。
            if (next.riparian_moisture.size() == cells) {
                for (size_t i = 0; i < cells; ++i) {
                    next.riparian_moisture[i] = next.plant_available_water[i];
                }
            }
            report.stage_ran_mask |=
                pk_async_climate::CLIMATE_STAGE_BIT_RUNTIME_HYDROLOGY;
            return static_cast<uint64_t>(cells) * 11u;
        });
    }

    if (shared_round_ran || shared_albedo_ran || shared_vegetation_ran ||
        shared_feedback_ran || shared_weather_ran || shared_hydrology_ran ||
        shared_distribute_ran) {
        // 共享内核模式下 changed_cells 由实际写过的场决定。还没有共享实现的 stage
        // （vegetation / weather / hydrology / stage_b）对应的 lane 停在昨天的值——
        // 这是"worker 未实现"的诚实表示，分叉矩阵会照实报出来；用近似值填反而会把它
        // 伪装成算法分叉。
        report.changed_cells = 0;
        for (size_t i = 0; i < cells; ++i) {
            if (next.temperature[i] != current.temperature[i] ||
                next.moisture[i] != current.moisture[i] ||
                next.temperature_baseline[i] != current.temperature_baseline[i] ||
                next.vegetation_growth_pressure[i] !=
                    current.vegetation_growth_pressure[i] ||
                next.vegetation_vitality[i] != current.vegetation_vitality[i] ||
                next.plant_available_water[i] != current.plant_available_water[i]) {
                ++report.changed_cells;
            }
        }
    }
    next.committed_day = day;
    ++next.generation;
    ++next.climate_generation;
    if (day > 0 && day % 365 == 0) {
        next.annual_temperature_drift = (normalised_rng(next.annual_rng_state) - 0.5f) * 0.4f;
        next.climate_anomaly = next.annual_temperature_drift;
    }
    const size_t history_offset = static_cast<size_t>(next.history_cursor % 365u) * cells;
    for (size_t i = 0; i < cells; ++i) next.temperature_history[history_offset + i] = next.temperature[i];
    next.history_cursor = (next.history_cursor + 1u) % 365u;

    // PK_CLIMATE_TRACE_CELL=<idx>：打印一格在这一天前后的值。定位累积类分歧时，
    // 「进来就已经是两倍」和「这一天变成两倍」是完全不同的两条线索，而分叉矩阵只给
    // 得出后者的结果。
    static const long trace_cell = [] {
        const char *v = std::getenv("PK_CLIMATE_TRACE_CELL");
        return v != nullptr ? std::strtol(v, nullptr, 10) : -1L;
    }();
    if (trace_cell >= 0 && static_cast<size_t>(trace_cell) < cells) {
        const size_t c = static_cast<size_t>(trace_cell);
        std::fprintf(stderr,
            "[cell-trace] day=%lld cell=%zu stage_mask=0x%X "
            "growth_pressure %.9g -> %.9g | paw %.9g -> %.9g | moisture %.9g -> %.9g\n",
            static_cast<long long>(day), c, report.stage_ran_mask,
            current.vegetation_growth_pressure[c], next.vegetation_growth_pressure[c],
            current.plant_available_water[c], next.plant_available_water[c],
            current.moisture[c], next.moisture[c]);
        std::fflush(stderr);
    }
    report.state_hash = next.state_hash();
    report.completed = 1;
    return true;
}

void RuntimeClimateKernel::commit(RuntimeClimateStore &current, RuntimeClimateStore &next) {
    using std::swap;
    swap(current, next);
}

bool RuntimeClimateKernel::self_test(std::string &error) {
    if (!climate_formula::self_test()) {
        error = "climate_formula_self_test_failed";
        return false;
    }
    RuntimeEnvironmentSnapshot input;
    input.generation = 1;
    input.day = 0;
    input.cell_count = 2;
    input.climate_catalog_hash = 7;
    input.cell_temp = {15.0f, -8.0f};
    input.cell_moisture = {0.5f, 0.25f};
    input.cell_plant_available_water = {0.7f, 0.2f};
    input.terrain = {1, 0};
    input.is_water = {0, 1};
    input.neighbor_offsets = {0, 1, 2};
    input.neighbor_indices = {1, 0};
    RuntimeClimateStore current;
    RuntimeClimateStore next;
    current.reset(2);
    next.reset(2);
    RuntimeClimateCatalog catalog;
    RuntimeClimateKernel kernel;
    if (!kernel.compile_catalog(input, catalog, error)) return false;
    RuntimeClimateKernelReport report;
    if (!kernel.plan_day(0, input, catalog, current, next, report) || !report.completed) {
        error = report.error;
        return false;
    }
    commit(current, next);
    if (current.committed_day != 0 || current.state_hash() != report.state_hash || report.work_units == 0) {
        error = "climate_kernel_self_test_state_invalid";
        return false;
    }
    return true;
}
} // namespace pk
