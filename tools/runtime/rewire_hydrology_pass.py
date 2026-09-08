#!/usr/bin/env python
"""Replace the inline hydrology computation in DCWorldExt::run_runtime_hydrology_pass
with knob/lane assembly plus a call into pk_async_climate::hydrology_pass_pure."""
import io

SRC = 'gdext/src/world_ext_climate.cpp'

src = io.open(SRC, encoding='utf-8').read()

# ── 1. scalar knob block -> HydrologyKnobs assembly ───────────────────────────
SCALARS_BEGIN = '    const float precip_scale = knobs.has("hydro_precip_scale")'
SCALARS_END = '    const float NB = '  # placeholder, replaced below
b = src.index(SCALARS_BEGIN)
e = src.index('    const int32_t * const NB = has_neighbor_indices ? neighbor_indices.ptr() : nullptr;')
e = src.index('\n', e) + 1

KNOBS_ASSEMBLY = '''    // 标量收进 POD 结构体。派生系数（*_eff / *_alpha）不在这里算 —— 它们由
    // hydrology_pass_pure 按 dt_days 自己推，避免生产与 worker 各写一份公式。
    pk_async_climate::HydrologyKnobs hk;
    hk.n_cells = n_cells;
    const auto knob_f = [&knobs](const char *key, float fallback) {
        return knobs.has(key) ? float(knobs[key]) : fallback;
    };
    hk.precip_scale = knob_f("hydro_precip_scale", 1.0f);
    hk.snowmelt_scale = knob_f("hydro_snowmelt_scale", 0.55f);
    hk.soil_capacity = knobs.has("hydro_soil_capacity")
        ? std::max(0.05f, float(knobs["hydro_soil_capacity"])) : 0.75f;
    hk.infiltration_rate = knobs.has("hydro_infiltration_rate")
        ? dc_clampf(float(knobs["hydro_infiltration_rate"]), 0.0f, 1.0f) : 0.52f;
    hk.quickflow_fraction = knobs.has("hydro_quickflow_fraction")
        ? dc_clampf(float(knobs["hydro_quickflow_fraction"]), 0.0f, 1.0f) : 0.36f;
    hk.baseflow_recession = knobs.has("hydro_baseflow_recession")
        ? dc_clampf(float(knobs["hydro_baseflow_recession"]), 0.0f, 1.0f) : 0.035f;
    hk.channel_release = knobs.has("hydro_channel_release_rate")
        ? dc_clampf(float(knobs["hydro_channel_release_rate"]), 0.01f, 1.0f) : 0.62f;
    hk.lake_release = knobs.has("hydro_lake_release_rate")
        ? dc_clampf(float(knobs["hydro_lake_release_rate"]), 0.005f, 1.0f) : 0.18f;
    hk.discharge_ema = knobs.has("hydro_discharge_ema")
        ? dc_clampf(float(knobs["hydro_discharge_ema"]), 0.01f, 1.0f) : 0.08f;
    hk.bank_moisture_gain = knobs.has("hydro_bank_moisture_gain")
        ? dc_clampf(float(knobs["hydro_bank_moisture_gain"]), 0.0f, 0.25f) : 0.035f;
    hk.river_moisture_floor = knobs.has("hydro_river_moisture_floor")
        ? dc_clampf(float(knobs["hydro_river_moisture_floor"]), 0.0f, 1.0f) : 0.66f;
    hk.riparian_moisture_floor = knobs.has("hydro_riparian_moisture_floor")
        ? dc_clampf(float(knobs["hydro_riparian_moisture_floor"]), 0.0f, 1.0f) : 0.38f;
    hk.river_evap_gain = knobs.has("hydro_river_evap_gain")
        ? dc_clampf(float(knobs["hydro_river_evap_gain"]), 0.0f, 1.0f) : 0.12f;
    hk.moisture_response_rate = knobs.has("hydro_moisture_response_rate")
        ? dc_clampf(float(knobs["hydro_moisture_response_rate"]), 0.0f, 1.0f) : 0.08f;
    hk.flood_threshold = knobs.has("hydro_flood_threshold")
        ? std::max(0.01f, float(knobs["hydro_flood_threshold"])) : 2.2f;
    hk.snowpack_melt_temp_gain = knob_f("snowpack_melt_temp_gain", 0.22f);
    hk.snowpack_melt_sun_gain = knob_f("snowpack_melt_sun_gain", 0.12f);
    hk.plant_water_balance_weight = knob_f("plant_water_balance_weight", 0.35f);
    hk.plant_soil_buffer_weight = knob_f("plant_soil_buffer_weight", 0.25f);
    hk.plant_drought_penalty = knob_f("plant_drought_penalty", 0.65f);
    hk.dt_days = knobs.has("dt_days")
        ? dc_clampf(float(knobs["dt_days"]), 1.0f, 30.0f) : 1.0f;
    const float moisture_response_alpha =
        1.0f - std::pow(1.0f - hk.moisture_response_rate, hk.dt_days);
    PackedInt32Array neighbor_indices;
    if (knobs.has("neighbor_indices")) {
        neighbor_indices = knobs["neighbor_indices"];
    }
    const bool has_neighbor_indices = neighbor_indices.size() >= n_cells * 6;
'''
src = src[:b] + KNOBS_ASSEMBLY + src[e:]

# ── 2. lane pointer block -> HydrologyLanes assembly ─────────────────────────
LANES_BEGIN = '    const int32_t * const __restrict HP = _slots.write[sid_hparent].arr_i32.ptr();'
LANES_END = '''    float * const __restrict CANAL_WATER =
        _slots.write[sid_canal_water].arr_f32.ptrw();
'''
b = src.index(LANES_BEGIN)
e = src.index(LANES_END) + len(LANES_END)

LANES_ASSEMBLY = '''    pk_async_climate::HydrologyLanes hl;
    hl.hydro_parent = _slots.write[sid_hparent].arr_i32.ptr();
    hl.has_river = _slots.write[sid_has_riv].arr_u8.ptr();
    hl.terrain = _slots.write[sid_terrain].arr_u8.ptr();
    hl.landform = _slots.write[sid_landform].arr_u8.ptr();
    hl.vegetation = _slots.write[sid_veg].arr_u8.ptr();
    hl.cover = _slots.write[sid_cover].arr_u8.ptr();
    hl.elevation = _slots.write[sid_elev].arr_f32.ptr();
    hl.precip = _slots.write[sid_precip].arr_f32.ptr();
    hl.intensity = _slots.write[sid_intensity].arr_f32.ptr();
    hl.weather_type = _slots.write[sid_wtype].arr_u8.ptr();
    hl.temp = _slots.write[sid_temp].arr_f32.ptr();
    hl.heat = _slots.write[sid_heat].arr_f32.ptr();
    hl.snowpack = _slots.write[sid_snowpack].arr_f32.ptr();
    hl.base_moisture = _slots.write[sid_base_m].arr_f32.ptr();
    hl.is_water = _slots.write[sid_is_water].arr_u8.ptr();
    hl.vitality = _slots.write[sid_vital].arr_f32.ptr();
    hl.canal_mask = _slots.write[sid_canal_mask].arr_u8.ptr();
    hl.neighbor_indices = has_neighbor_indices ? neighbor_indices.ptr() : nullptr;
    hl.moisture = _slots.write[sid_moist].arr_f32.ptrw();
    hl.soil_moisture = _slots.write[sid_soil].arr_f32.ptrw();
    hl.water_balance_30d = _slots.write[sid_wb30].arr_f32.ptrw();
    hl.plant_water = _slots.write[sid_plant_water].arr_f32.ptrw();
    hl.discharge = _slots.write[sid_q].arr_f32.ptrw();
    hl.discharge_30d = _slots.write[sid_q30].arr_f32.ptrw();
    hl.river_storage = _slots.write[sid_storage].arr_f32.ptrw();
    hl.groundwater = _slots.write[sid_gw].arr_f32.ptrw();
    hl.runoff = _slots.write[sid_runoff].arr_f32.ptrw();
    hl.canal_water = _slots.write[sid_canal_water].arr_f32.ptrw();
'''
src = src[:b] + LANES_ASSEMBLY + src[e:]

# ── 3. computation body -> kernel call ───────────────────────────────────────
BODY_BEGIN = '''    std::vector<int32_t> child_count(size_t(n_cells), 0);'''
BODY_END = '    const float q_p95 = river_q.empty() ? 0.0f :'
b = src.index(BODY_BEGIN)
e = src.index(BODY_END)
e = src.index('\n', e) + 1

CALL = '''    // stage 12 的数值核心已抽成共享纯内核 pk_async_climate::hydrology_pass_pure。
    // 运河编译态整组抬进 HydrologyCanalState：以前它是五个 DCWorldExt 成员，worker
    // 拿不到，于是水文根本没法在 worker 侧跑。现在主线程与 worker 各持一份、各自按
    // topology_generation 失效。
    _hydrology_canal.topology_generation = _canal_topology_generation;
    pk_async_climate::HydrologyStats hs;
    // 记录给 worker 对拍用的输入。必须在内核之前：MOIST / SOIL / WB30 / Q / Q30 /
    // STORAGE / GW / CANAL_WATER 都是 in/out，跑完再记就变成记结果。
    record_production_hydrology_input(hk, hl, has_neighbor_indices,
                                     _canal_topology_generation, n_cells);
    pk_async_climate::hydrology_pass_pure(hk, hl, _hydrology_canal,
                                        _hydrology_scratch, hs);
    _canal_hydrology_compiled_generation = _hydrology_canal.compiled_generation;
    _canal_hydrology_compiled_cell_count = _hydrology_canal.compiled_cell_count;

    const double water_in_total = hs.water_in_total;
    const double outlet_total = hs.outlet_total;
    const int runoff_source_cells = hs.runoff_source_cells;
    const int river_cells_processed = hs.river_cells_processed;
    const int riparian_neighbor_touches = hs.riparian_neighbor_touches;
    const int river_moisture_floor_touches = hs.river_moisture_floor_touches;
    const int riparian_moisture_floor_touches = hs.riparian_moisture_floor_touches;
    const float river_moisture_max_delta = hs.river_moisture_max_delta;
    const float riparian_moisture_max_delta = hs.riparian_moisture_max_delta;
    const int flood_candidate_count = hs.flood_candidate_count;
    const int canal_cells_processed = hs.canal_cells_processed;
    const int canal_edges_processed = hs.canal_edges_processed;
    const int canal_freshwater_cells = hs.canal_freshwater_cells;
    const int canal_saline_cells = hs.canal_saline_cells;
    const float q_max = hs.q_max;
    const float q_p95 = hs.q_p95;
'''
src = src[:b] + CALL + src[e:]

io.open(SRC, 'w', encoding='utf-8', newline='').write(src)
print('rewired run_runtime_hydrology_pass')
