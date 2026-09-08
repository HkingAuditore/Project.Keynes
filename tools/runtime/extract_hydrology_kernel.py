#!/usr/bin/env python
"""Transplant the runtime hydrology computation body from world_ext_climate.cpp
into runtime_climate_passes.cpp as pk_async_climate::hydrology_pass_pure.

The body is moved verbatim. Everything the body needs is re-bound in a prologue
via local aliases with the exact original names, so not a single expression
inside the computation changes -- which is the whole point: any rewrite of the
arithmetic would have to be re-validated against 30 days of parity output.
"""
import io
import re
import sys

SRC = 'gdext/src/world_ext_climate.cpp'
DST = 'gdext/src/runtime_climate_passes.cpp'

BEGIN = '    for (int i = 0; i < n_cells; ++i) {\n        const int32_t p = HP[i];'
END = '    const float q_p95 = river_q.empty() ? 0.0f :'

src = io.open(SRC, encoding='utf-8').read()
b = src.index(BEGIN)
e = src.index(END)
e = src.index('\n', e) + 1
body = src[b:e]

# The only non-POD references left in the body are the five DCWorldExt canal
# members and the topology generation counter.
renames = [
    ('_canal_hydrology_compiled_generation', 'canal.compiled_generation'),
    ('_canal_hydrology_compiled_cell_count', 'canal.compiled_cell_count'),
    ('_canal_hydrology_source_kind', 'canal.source_kind'),
    ('_canal_hydrology_strength', 'canal.strength'),
    ('_canal_hydrology_cells', 'canal.cells'),
    ('_canal_topology_generation', 'canal.topology_generation'),
]
for old, new in renames:
    body = body.replace(old, new)
assert '_canal' not in body, 'unrenamed canal member left in body'
assert 'knobs[' not in body and 'knobs.has' not in body, 'Dictionary access in body'
assert '_slots' not in body, 'slot access in body'

PROLOGUE = '''// stage 12 RUNTIME_HYDROLOGY。计算体从 DCWorldExt::run_runtime_hydrology_pass
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

'''

EPILOGUE = '''
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

'''

dst = io.open(DST, encoding='utf-8').read()
MARKER = '// 邻域几何缓存：self->nb 的 wrapped delta 与 1/sqrt(dl2)。'
assert dst.count(MARKER) == 1, dst.count(MARKER)
if 'hydrology_pass_pure' in dst:
    sys.exit('hydrology_pass_pure already present -- refusing to inject twice')
dst = dst.replace(MARKER, PROLOGUE + body + EPILOGUE + MARKER)
io.open(DST, 'w', encoding='utf-8', newline='').write(dst)
print('injected hydrology_pass_pure, body lines =', body.count('\n'))
