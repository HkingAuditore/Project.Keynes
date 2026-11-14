#include "runtime_climate_passes.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <queue>
#include <utility>
#include <vector>

namespace pk {
namespace pk_async_climate {

// stage 12 RUNTIME_HYDROLOGY。计算体从 DCWorldExt::run_runtime_hydrology_pass
// 原样搬来：Dictionary 取值、slot 解引用、flush 与报告留在 Godot 侧的 wrapper 里，
// 这里一行算术都没改。派生系数在这里算，不在调用方算。
void hydrology_pass_pure(const HydrologyKnobs &k,
                         const HydrologyLanes &lanes,
                         HydrologyCanalState &canal,
                         HydrologyScratch &scratch,
                         HydrologyStats &stats) {
    const int n_cells = k.n_cells;
    if (n_cells <= 0) return;
    // 必需 lane 缺一条就整段不跑：半跑会把 store 写成前后不一致的状态，而那比
    // "这天没跑水文"难诊断得多。
    if (lanes.hydro_parent == nullptr || lanes.has_river == nullptr ||
        lanes.terrain == nullptr || lanes.landform == nullptr ||
        lanes.vegetation == nullptr || lanes.cover == nullptr ||
        lanes.elevation == nullptr || lanes.precip == nullptr ||
        lanes.intensity == nullptr || lanes.weather_type == nullptr ||
        lanes.temp == nullptr || lanes.heat == nullptr ||
        lanes.snowpack == nullptr || lanes.base_moisture == nullptr ||
        lanes.is_water == nullptr || lanes.vitality == nullptr ||
        lanes.canal_mask == nullptr || lanes.moisture == nullptr ||
        lanes.soil_moisture == nullptr || lanes.water_balance_30d == nullptr ||
        lanes.plant_water == nullptr || lanes.discharge == nullptr ||
        lanes.discharge_30d == nullptr || lanes.river_storage == nullptr ||
        lanes.groundwater == nullptr || lanes.runoff == nullptr ||
        lanes.canal_water == nullptr) {
        return;
    }

    const float precip_scale = k.precip_scale;
    const float snowmelt_scale = k.snowmelt_scale;
    const float soil_capacity = k.soil_capacity;
    const float infiltration_rate = k.infiltration_rate;
    const float quickflow_fraction = k.quickflow_fraction;
    const float baseflow_recession = k.baseflow_recession;
    const float channel_release = k.channel_release;
    const float lake_release = k.lake_release;
    const float discharge_ema = k.discharge_ema;
    const float bank_moisture_gain = k.bank_moisture_gain;
    const float river_moisture_floor = k.river_moisture_floor;
    const float riparian_moisture_floor = k.riparian_moisture_floor;
    const float river_evap_gain = k.river_evap_gain;
    const float moisture_response_rate = k.moisture_response_rate;
    const float flood_threshold = k.flood_threshold;
    const float snowpack_melt_temp_gain = k.snowpack_melt_temp_gain;
    const float snowpack_melt_sun_gain = k.snowpack_melt_sun_gain;
    const float plant_water_balance_weight = k.plant_water_balance_weight;
    const float plant_soil_buffer_weight = k.plant_soil_buffer_weight;
    const float plant_drought_penalty = k.plant_drought_penalty;
    const float dt_days = k.dt_days;
    const float baseflow_recession_eff = 1.0f - std::pow(1.0f - baseflow_recession, dt_days);
    const float discharge_ema_eff = 1.0f - std::pow(1.0f - discharge_ema, dt_days);
    const float nonriver_discharge_decay = std::pow(1.0f - discharge_ema * 0.5f, dt_days);
    const float soil_decay_eff = std::pow(0.985f, dt_days);
    const float water_balance_ema_eff = 1.0f - std::pow(1.0f - (1.0f / 30.0f), dt_days);
    const float moisture_response_alpha = 1.0f - std::pow(1.0f - moisture_response_rate, dt_days);

    const int32_t * const __restrict NB = lanes.neighbor_indices;
    const bool has_neighbor_indices = NB != nullptr;
    const int32_t * const __restrict HP = lanes.hydro_parent;
    const uint8_t * const __restrict HAS_RIV = lanes.has_river;
    const uint8_t * const __restrict TERR = lanes.terrain;
    const uint8_t * const __restrict LF = lanes.landform;
    const uint8_t * const __restrict VEG = lanes.vegetation;
    const uint8_t * const __restrict COV = lanes.cover;
    const float * const __restrict ELEV = lanes.elevation;
    const float * const __restrict PREC = lanes.precip;
    const float * const __restrict INTEN = lanes.intensity;
    const uint8_t * const __restrict WTYPE = lanes.weather_type;
    const float * const __restrict TEMP = lanes.temp;
    const float * const __restrict HEAT = lanes.heat;
    const float * const __restrict SNOWP = lanes.snowpack;
    float * const __restrict MOIST = lanes.moisture;
    const float * const __restrict BASE_M = lanes.base_moisture;
    float * const __restrict SOIL = lanes.soil_moisture;
    float * const __restrict WB30 = lanes.water_balance_30d;
    float * const __restrict PLANT_WATER = lanes.plant_water;
    const uint8_t * const __restrict IS_WATER = lanes.is_water;
    const float * const __restrict VITAL = lanes.vitality;
    float * const __restrict Q = lanes.discharge;
    float * const __restrict Q30 = lanes.discharge_30d;
    float * const __restrict STORAGE = lanes.river_storage;
    float * const __restrict GW = lanes.groundwater;
    float * const __restrict RUNOFF = lanes.runoff;
    const uint8_t * const __restrict CANAL_MASK = lanes.canal_mask;
    float * const __restrict CANAL_WATER = lanes.canal_water;

    // scratch 是复用缓冲，所以每天必须显式重置成原来的初值 —— assign 而不是
    // resize，否则昨天的 incoming 会当成今天的产流加进汇流里。
    scratch.child_count.assign(size_t(n_cells), 0);
    scratch.incoming.assign(size_t(n_cells), 0.0f);
    scratch.moisture_target.assign(size_t(n_cells), -1.0f);
    scratch.queue.clear();
    scratch.queue.reserve(size_t(n_cells));
    std::vector<int32_t> &child_count = scratch.child_count;
    std::vector<float> &incoming = scratch.incoming;
    std::vector<float> &moisture_target = scratch.moisture_target;
    std::vector<int32_t> &queue = scratch.queue;

    double water_in_total = 0.0;
    double outlet_total = 0.0;
    int runoff_source_cells = 0;
    int river_cells_processed = 0;
    int riparian_neighbor_touches = 0;
    int river_moisture_floor_touches = 0;
    int riparian_moisture_floor_touches = 0;
    float river_moisture_max_delta = 0.0f;
    float riparian_moisture_max_delta = 0.0f;
    int flood_candidate_count = 0;
    int canal_cells_processed = 0;
    int canal_edges_processed = 0;
    int canal_freshwater_cells = 0;
    int canal_saline_cells = 0;

    for (int i = 0; i < n_cells; ++i) {
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) child_count[size_t(p)] += 1;
    }

    for (int i = 0; i < n_cells; ++i) {
        const bool is_water = wf_is_water_terrain(TERR[i]) || LF[i] <= 3;
        const uint8_t wt = WTYPE[i];
        const float hydro_precip = wf_is_precip_weather_type(wt) ? PREC[i] : 0.0f;
        const float wet_event = ((wt == 2 || wt == 3 || wt == 7) ? 0.12f : 0.0f) * INTEN[i];
        const float precip_daily = std::max(0.0f, hydro_precip + wet_event) * precip_scale;
        const float melt_potential = std::max(0.0f, TEMP[i] - 0.24f) * snowpack_melt_temp_gain
            + std::max(0.0f, HEAT[i]) * snowpack_melt_sun_gain;
        const float snowmelt = std::min(std::max(0.0f, SNOWP[i]), melt_potential * dt_days) * snowmelt_scale;
        const float water_in = precip_daily * dt_days + snowmelt;
        water_in_total += double(water_in);

        const float wetness = dc_clampf((SOIL[i] + 0.5f) * 0.55f + BASE_M[i] * 0.25f + MOIST[i] * 0.20f, 0.0f, 1.0f);
        const float veg_absorb = (VEG[i] == 0 ? 0.0f : dc_clampf(VITAL[i], 0.0f, 1.0f)) * 0.14f;
        const float cover_runoff = (COV[i] == 1 || COV[i] == 2) ? 0.18f : ((COV[i] == 3) ? 0.10f : 0.0f);
        const float relief_runoff = dc_clampf((ELEV[i] - 0.55f) * 0.20f, 0.0f, 0.16f);
        const float saturation = dc_clampf((wetness - soil_capacity) / std::max(0.001f, 1.0f - soil_capacity), 0.0f, 1.0f);
        float runoff_coeff = quickflow_fraction + wetness * 0.32f + saturation * 0.35f + cover_runoff + relief_runoff - veg_absorb;
        runoff_coeff = is_water ? 1.0f : dc_clampf(runoff_coeff, 0.04f, 0.96f);
        const float quick_runoff = water_in * runoff_coeff;
        const float infiltration = is_water ? 0.0f : water_in * (1.0f - runoff_coeff) * infiltration_rate;

        GW[i] = std::max(0.0f, GW[i] + infiltration * 0.55f);
        const float baseflow = GW[i] * baseflow_recession_eff;
        GW[i] = std::max(0.0f, GW[i] - baseflow);
        const float local_runoff = quick_runoff + baseflow;
        RUNOFF[i] = local_runoff;
        incoming[size_t(i)] += local_runoff;
        if (local_runoff > 0.0001f) ++runoff_source_cells;

        const float daily_balance = dc_clampf(
            (water_in - quick_runoff - infiltration * 0.35f) / dt_days, -1.0f, 1.0f);
        SOIL[i] = dc_clampf(SOIL[i] * soil_decay_eff + infiltration * 0.16f - quick_runoff * 0.025f, -0.5f, 0.5f);
        WB30[i] = WB30[i] + (daily_balance - WB30[i]) * water_balance_ema_eff;

        if (child_count[size_t(i)] == 0) queue.push_back(i);
    }

    for (size_t qh = 0; qh < queue.size(); ++qh) {
        const int i = queue[qh];
        const bool is_channel = HAS_RIV[i] != 0 || wf_is_water_terrain(TERR[i]) || LF[i] <= 3;
        const bool is_lake = wf_is_water_terrain(TERR[i]) && TERR[i] != 0;
        float outflow = incoming[size_t(i)];
        if (is_channel) {
            const float release_daily = is_lake ? lake_release : channel_release;
            const float release = 1.0f - std::pow(1.0f - release_daily, dt_days);
            STORAGE[i] = std::max(0.0f, STORAGE[i] + incoming[size_t(i)]);
            outflow = STORAGE[i] * release;
            STORAGE[i] = std::max(0.0f, STORAGE[i] - outflow);
            ++river_cells_processed;
        } else {
            STORAGE[i] = 0.0f;
        }
        Q[i] = (HAS_RIV[i] != 0 || wf_is_water_terrain(TERR[i])) ? outflow : 0.0f;
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) {
            incoming[size_t(p)] += outflow;
            child_count[size_t(p)] -= 1;
            if (child_count[size_t(p)] == 0) queue.push_back(p);
        } else {
            outlet_total += double(outflow);
        }
    }

    for (int i = 0; i < n_cells; ++i) {
        if (child_count[size_t(i)] <= 0) continue;
        const int32_t p = HP[i];
        if (p >= 0 && p < n_cells && p != i) incoming[size_t(p)] += incoming[size_t(i)];
        else outlet_total += double(incoming[size_t(i)]);
    }

    float q_max = 0.0f;
    std::vector<float> river_q;
    river_q.reserve(size_t(n_cells));
    for (int i = 0; i < n_cells; ++i) {
        if (HAS_RIV[i] == 0 && !wf_is_water_terrain(TERR[i])) {
            Q[i] = 0.0f;
            Q30[i] = std::max(0.0f, Q30[i] * nonriver_discharge_decay);
            continue;
        }
        q_max = std::max(q_max, Q[i]);
        river_q.push_back(Q[i]);
    }
    const float denom = std::log1p(std::max(q_max, 0.001f));
    for (int i = 0; i < n_cells; ++i) {
        if (HAS_RIV[i] == 0 && !wf_is_water_terrain(TERR[i])) continue;
        const float q_norm = dc_clampf(std::log1p(std::max(0.0f, Q[i])) / denom, 0.0f, 1.0f);
        Q30[i] = dc_clampf(Q30[i] + (q_norm - Q30[i]) * discharge_ema_eff, 0.0f, 1.0f);
        if (HAS_RIV[i] != 0 && Q30[i] > flood_threshold) ++flood_candidate_count;
        if (HAS_RIV[i] != 0) {
            const float bank_gain = Q30[i] * bank_moisture_gain;
            const float moisture_floor = dc_clampf(
                river_moisture_floor + Q30[i] * river_evap_gain * 0.5f, 0.0f, 1.0f);
            moisture_target[size_t(i)] = std::max(moisture_target[size_t(i)], moisture_floor);
            SOIL[i] = dc_clampf(SOIL[i] + bank_gain, -0.5f, 0.5f);
            WB30[i] = dc_clampf(WB30[i] + bank_gain * 0.5f, -1.0f, 1.0f);
            if (NB != nullptr && bank_gain > 0.0f) {
                const float neighbor_gain = bank_gain * 0.45f;
                const int nb_base = i * 6;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[nb_base + d];
                    if (ni < 0 || ni >= n_cells || ni == i) continue;
                    const bool nb_is_water = wf_is_water_terrain(TERR[ni]) || LF[ni] <= 3;
                    if (nb_is_water || HAS_RIV[ni] != 0) continue;
                    const float neighbor_floor = dc_clampf(
                        riparian_moisture_floor + Q30[i] * river_evap_gain * 0.25f, 0.0f, 1.0f);
                    moisture_target[size_t(ni)] = std::max(moisture_target[size_t(ni)], neighbor_floor);
                    SOIL[ni] = dc_clampf(SOIL[ni] + neighbor_gain, -0.5f, 0.5f);
                    WB30[ni] = dc_clampf(WB30[ni] + neighbor_gain * 0.5f, -1.0f, 1.0f);
                    ++riparian_neighbor_touches;
                }
            }
        }
    }

    // Sparse artificial-water phase. It is deliberately downstream of the
    // natural drainage DAG: HP/incoming/Q/STORAGE are read-only here, so canals
    // neither divert natural rivers nor create/destroy discharge.
    if (has_neighbor_indices) {
        if (canal.compiled_generation != canal.topology_generation ||
            canal.compiled_cell_count != n_cells) {
            // Clear water left by cells removed from the topology, then do the
            // only full-map canal scan. Normal daily passes below touch only
            // the compiled canal cells and their immediate neighbors.
            for (const int32_t cell : canal.cells) {
                if (cell >= 0 && cell < n_cells) CANAL_WATER[cell] = 0.0f;
            }
            canal.cells.clear();
            canal.cells.reserve(256);
            for (int32_t cell = 0; cell < n_cells; ++cell) {
                if ((CANAL_MASK[cell] & 0x3fU) != 0)
                    canal.cells.push_back(cell);
            }
            canal.source_kind.assign(size_t(n_cells), 0);
            canal.strength.assign(size_t(n_cells), 0.0f);
            canal.compiled_generation = canal.topology_generation;
            canal.compiled_cell_count = n_cells;
        }
        std::vector<uint8_t> &source_kind = canal.source_kind;
        std::vector<float> &strength = canal.strength;
        using CanalNode = std::pair<float, int32_t>;
        std::priority_queue<CanalNode> propagation;
        for (const int32_t cell : canal.cells) {
            CANAL_WATER[cell] = 0.0f;
            source_kind[size_t(cell)] = 0;
            strength[size_t(cell)] = 0.0f;
            uint8_t source = HAS_RIV[cell] != 0 || TERR[cell] == 18 ? 2 : 0;
            for (int direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = NB[cell * 6 + direction];
                if (neighbor < 0 || neighbor >= n_cells) continue;
                if (HAS_RIV[neighbor] != 0 || TERR[neighbor] == 18) source = 2;
                else if (source == 0 && (TERR[neighbor] == 0 || TERR[neighbor] == 1 ||
                         TERR[neighbor] == 19 || TERR[neighbor] == 20 ||
                         TERR[neighbor] == 21)) source = 1;
            }
            if (source != 0) {
                source_kind[size_t(cell)] = source;
                strength[size_t(cell)] = 1.0f;
                propagation.push({1.0f, cell});
            }
        }
        while (!propagation.empty()) {
            const auto [current_strength, cell] = propagation.top();
            propagation.pop();
            if (current_strength + 0.000001f < strength[size_t(cell)]) continue;
            for (int direction = 0; direction < 6; ++direction) {
                if ((CANAL_MASK[cell] & (1U << direction)) == 0) continue;
                const int32_t neighbor = NB[cell * 6 + direction];
                if (neighbor < 0 || neighbor >= n_cells ||
                    (CANAL_MASK[neighbor] & (1U << ((direction + 3) % 6))) == 0)
                    continue;
                ++canal_edges_processed;
                const float next_strength = current_strength * 0.96f;
                // Freshwater wins deterministic ties over saline.
                if (next_strength > strength[size_t(neighbor)] + 0.000001f ||
                    (std::abs(next_strength - strength[size_t(neighbor)]) <= 0.000001f &&
                     source_kind[size_t(cell)] > source_kind[size_t(neighbor)])) {
                    strength[size_t(neighbor)] = next_strength;
                    source_kind[size_t(neighbor)] = source_kind[size_t(cell)];
                    propagation.push({next_strength, neighbor});
                }
            }
        }
        canal_edges_processed /= 2;
        for (const int32_t cell : canal.cells) {
            const float available = dc_clampf(strength[size_t(cell)], 0.0f, 1.0f);
            CANAL_WATER[cell] = available;
            ++canal_cells_processed;
            if (source_kind[size_t(cell)] == 2) {
                ++canal_freshwater_cells;
                const float own_target = dc_clampf(
                    river_moisture_floor * 0.60f * available, 0.0f, 1.0f);
                moisture_target[size_t(cell)] = std::max(
                    moisture_target[size_t(cell)], own_target);
                const float soil_target = dc_clampf(available * 0.30f, -0.5f, 0.5f);
                SOIL[cell] += (soil_target - SOIL[cell]) * moisture_response_alpha * 0.60f;
                WB30[cell] += (available * 0.35f - WB30[cell]) *
                    water_balance_ema_eff * 0.60f;
                for (int direction = 0; direction < 6; ++direction) {
                    const int32_t neighbor = NB[cell * 6 + direction];
                    if (neighbor < 0 || neighbor >= n_cells || IS_WATER[neighbor] != 0)
                        continue;
                    const float neighbor_target = dc_clampf(
                        riparian_moisture_floor * 0.50f * available, 0.0f, 1.0f);
                    moisture_target[size_t(neighbor)] = std::max(
                        moisture_target[size_t(neighbor)], neighbor_target);
                    SOIL[neighbor] += (available * 0.18f - SOIL[neighbor]) *
                        moisture_response_alpha * 0.50f;
                    WB30[neighbor] += (available * 0.20f - WB30[neighbor]) *
                        water_balance_ema_eff * 0.50f;
                }
            } else if (source_kind[size_t(cell)] == 1) {
                ++canal_saline_cells;
                const float saline_target = dc_clampf(MOIST[cell] +
                    river_evap_gain * 0.20f * available, 0.0f, 1.0f);
                moisture_target[size_t(cell)] = std::max(
                    moisture_target[size_t(cell)], saline_target);
            }
        }
    } else {
        for (const int32_t cell : canal.cells) {
            if (cell >= 0 && cell < n_cells) CANAL_WATER[cell] = 0.0f;
        }
        canal.cells.clear();
        canal.source_kind.clear();
        canal.strength.clear();
        canal.compiled_generation = std::numeric_limits<uint64_t>::max();
        canal.compiled_cell_count = -1;
    }

    // Aggregate all river/canal influences first, then approach the strongest target once per cell.
    // This prevents multi-river neighbors from receiving several response steps in one pass.
    if (moisture_response_alpha > 0.0f) {
        for (int i = 0; i < n_cells; ++i) {
            const float target = moisture_target[size_t(i)];
            if (target < 0.0f || MOIST[i] >= target) continue;
            const float before = MOIST[i];
            MOIST[i] = dc_clampf(before + (target - before) * moisture_response_alpha, 0.0f, 1.0f);
            const float delta = MOIST[i] - before;
            if (HAS_RIV[i] != 0) {
                ++river_moisture_floor_touches;
                river_moisture_max_delta = std::max(river_moisture_max_delta, delta);
            } else {
                ++riparian_moisture_floor_touches;
                riparian_moisture_max_delta = std::max(riparian_moisture_max_delta, delta);
            }
        }
    }

    for (int i = 0; i < n_cells; ++i) {
        PLANT_WATER[i] = IS_WATER[i] != 0 ? 0.0f : pk_plant_available_water(
            MOIST[i], WB30[i], SOIL[i], plant_water_balance_weight,
            plant_soil_buffer_weight, plant_drought_penalty);
    }
    std::sort(river_q.begin(), river_q.end());
    const float q_p95 = river_q.empty() ? 0.0f : river_q[size_t(std::min<int>(int(river_q.size()) - 1, int(std::floor(double(river_q.size() - 1) * 0.95))))];

    stats.water_in_total = water_in_total;
    stats.outlet_total = outlet_total;
    stats.runoff_source_cells = runoff_source_cells;
    stats.river_cells_processed = river_cells_processed;
    stats.riparian_neighbor_touches = riparian_neighbor_touches;
    stats.river_moisture_floor_touches = river_moisture_floor_touches;
    stats.riparian_moisture_floor_touches = riparian_moisture_floor_touches;
    stats.river_moisture_max_delta = river_moisture_max_delta;
    stats.riparian_moisture_max_delta = riparian_moisture_max_delta;
    stats.flood_candidate_count = flood_candidate_count;
    stats.canal_cells_processed = canal_cells_processed;
    stats.canal_edges_processed = canal_edges_processed;
    stats.canal_freshwater_cells = canal_freshwater_cells;
    stats.canal_saline_cells = canal_saline_cells;
    stats.q_max = q_max;
    stats.q_p95 = q_p95;
}

} // namespace pk_async_climate
} // namespace pk
