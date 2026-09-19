#include "runtime_climate_physics.h"
#include "runtime_climate_pass_math.h"
#include <algorithm>
#include <cstdio>
#include <limits>
#ifdef PK_TEST_CLIMATE_WORKER
#include "runtime_climate_kernel.h"
#endif

using namespace pk::pk_async_physics;
#define CHECK(expr) do { if (!(expr)) { std::fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #expr); return false; } } while (0)

static bool state_roundtrip() {
    RuntimeClimatePhysicsState s, restored;
    s.resize(12);
    s.resize_water(5);
    s.ocean_psi[11] = 0.25f;
    s.ocean_psi_prev[11] = -0.5f;
    s.slp_prev[2] = 0.15f;
    s.synoptic_seeded = true;
    s.synoptic_tick = 13;
    s.synoptic_psi[4] = 0.23f;
    s.synoptic_psi_prev[4] = -0.11f;
    s.committed_day = 36;
    s.last_daily_day = s.last_wind_day = 36;
    s.last_slp_day = 30;
    s.last_ocean_day = 25;
    s.daily_due_seq = 7;
    s.initialized = true;
    s.input_generation = 128;
    s.cyclone_total_injected = 17;
    std::vector<uint8_t> blob, again;
    std::string error;
    CHECK(serialize_physics_state(s, blob, error));
    CHECK(restore_physics_state(blob.data(), blob.size(), restored, error));
    CHECK(restored.state_hash() == s.state_hash());
    CHECK(restored.ocean_psi.size() == 12 && restored.ocean_psi_prev[11] == -0.5f);
    CHECK(!restored.topo_valid && !restored.coast_valid && !restored.wind_traj_valid);
    CHECK(serialize_physics_state(restored, again, error) && blob == again);
    const uint64_t hash = restored.state_hash();
    for (size_t length = 1; length < blob.size(); ++length) {
        CHECK(!restore_physics_state(blob.data(), length, restored, error));
        CHECK(restored.state_hash() == hash);
    }
    auto corrupt = blob;
    corrupt.back() ^= 0x80;
    CHECK(!restore_physics_state(corrupt.data(), corrupt.size(), restored, error));
    CHECK(restored.state_hash() == hash);
    corrupt = blob;
    corrupt[120] = 0; corrupt[121] = 0; corrupt[122] = 0xC0; corrupt[123] = 0x7F;
    CHECK(!restore_physics_state(corrupt.data(), corrupt.size(), restored, error));
    CHECK(error == "physics_non_finite" && restored.state_hash() == hash);
    corrupt = blob; corrupt.push_back(0);
    CHECK(!restore_physics_state(corrupt.data(), corrupt.size(), restored, error));
    s.slp[0] = std::numeric_limits<float>::quiet_NaN();
    CHECK(!serialize_physics_state(s, again, error) && again == blob);
    s.slp[0] = 0; s.last_slp_day = 37;
    CHECK(!serialize_physics_state(s, again, error));
    s.last_slp_day = 30; s.wind_x[0] = 2;
    CHECK(!serialize_physics_state(s, again, error));
    CHECK(restore_physics_state(nullptr, 0, restored, error));
    CHECK(!restored.ready && !restored.initialized && restored.cell_count == 0);
    return true;
}

static bool forcing_and_divergence() {
    SlpPassAKnobs a, b;
    a.world_seed = b.world_seed = 421;
    std::vector<float> base, heat, base_cached, heat_cached, mean(32);
    for (int i = 0; i < 32; ++i) mean[i] = pk::dc_insolation_annual_mean(float(i) / 31, 23.5f, 0.35f);
    prepare_slp_forcing(a, 32, 0.4f, 23.5f, 0.35f, 17, 6, 8, 0.16f, 0.06f, 16, base, heat);
    prepare_slp_forcing(b, 32, 0.4f, 23.5f, 0.35f, 17, 6, 8, 0.16f, 0.06f, 16, base_cached, heat_cached, mean.data());
    CHECK(base == base_cached && heat == heat_cached);
    CHECK(a.n_mobile_low == 8 && a.syn_phase == b.syn_phase);
    for (int i = 0; i < 8; ++i) CHECK(a.mobile_low_cx[i] == b.mobile_low_cx[i] && a.mobile_low_cy[i] == b.mobile_low_cy[i]);
    prepare_slp_forcing(b, 32, 0.4f, 23.5f, 0.35f, 18, 6, 8, 0.16f, 0.06f, 16, base_cached, heat_cached);
    CHECK(a.mobile_low_cx[0] != b.mobile_low_cx[0] && a.syn_phase != b.syn_phase);
    constexpr int n = 5;
    std::vector<int32_t> nb(n * 6, -1);
    std::vector<float> x(n, 1), y(n, 0), speed{0.2f, 0.6f, 0.9f, 0.4f, 0.3f}, div(n), sliced(n);
    for (int i = 0; i < n; ++i) { nb[i * 6] = (i + 1) % n; nb[i * 6 + 3] = (i + n - 1) % n; }
    wind_divergence_range(n, 0, n, nb.data(), x.data(), y.data(), speed.data(), div.data());
    wind_divergence_range(n, 0, 2, nb.data(), x.data(), y.data(), speed.data(), sliced.data());
    wind_divergence_range(n, 2, n, nb.data(), x.data(), y.data(), speed.data(), sliced.data());
    CHECK(div == sliced);
    auto sx = x, sy = y, ss = speed;
    wind_divergence_apply_range(n, 0, n, nb.data(), div.data(), 0.1, x.data(), y.data(), speed.data());
    wind_divergence_apply_range(n, 0, 2, nb.data(), sliced.data(), 0.1, sx.data(), sy.data(), ss.data());
    wind_divergence_apply_range(n, 2, n, nb.data(), sliced.data(), 0.1, sx.data(), sy.data(), ss.data());
    CHECK(x == sx && y == sy && speed == ss);
    return true;
}

static bool psi_alias(bool all_land) {
    constexpr int n = 12;
    RuntimeClimatePhysicsState s;
    s.resize(n);
    std::vector<uint8_t> terrain(n, 0);
    std::vector<int32_t> nb(n * 6, -1);
    std::vector<float> lat(n), temp(n, 0.5f);
    bool water[256]{}; water[1] = true;
    for (int i = 0; i < n; ++i) {
        terrain[i] = !all_land && i % 3 != 0 ? 1 : 0;
        lat[i] = 0.15f + 0.7f * float(i) / float(n - 1);
        nb[i * 6] = (i + 1) % n;
        nb[i * 6 + 3] = (i + n - 1) % n;
        s.wind_speed[i] = 0.4f + float(i) * 0.02f;
        s.ocean_current_x[i] = 0.3f;
        s.ocean_current_y[i] = -0.2f;
        s.ocean_psi[i] = 0.01f * float(i);
    }
    const int nw = int(std::count(terrain.begin(), terrain.end(), 1));
    s.resize_water(nw);
    if (nw) CHECK(psi_topology_build_pure(n, terrain.data(), nb.data(), water,
        s.cell_to_water.data(), s.water_to_cell.data(), s.nb_w.data()) == nw);
    PsiSolveKnobs k;
    k.total_iters = 4; k.min_iters = 4; k.response_rate = 0.25f;
    PsiSolveLanes l;
    l.n_cells = n; l.n_water = nw; l.neighbors = nb.data(); l.terrain = terrain.data();
    l.is_water_lut = water; l.cell_to_water = s.cell_to_water.data();
    l.water_to_cell = s.water_to_cell.data(); l.nb_w = s.nb_w.data();
    l.wind_x = s.wind_x.data(); l.wind_y = s.wind_y.data(); l.wind_speed = s.wind_speed.data();
    l.lat_norm = lat.data(); l.temp = temp.data(); l.prev_psi = s.ocean_psi.data();
    const auto old_x = s.ocean_current_x, old_y = s.ocean_current_y;
    const auto old_psi = s.ocean_psi;
    std::vector<float> expected_x(n), expected_y(n), expected_psi(n), expected_curl(n);
    l.old_ocean_x = old_x.data(); l.old_ocean_y = old_y.data();
    l.out_ocean_x = expected_x.data(); l.out_ocean_y = expected_y.data();
    l.out_psi = expected_psi.data(); l.out_curl = expected_curl.data();
    PsiSolveScratch scratch{s.psi_tau_x.data(), s.psi_tau_y.data(), s.psi_ny.data(), s.psi_ls.data(),
        s.psi_curl.data(), s.psi_beta.data(), s.psi_r.data(), s.psi_source.data(), s.psi_work.data()};
    PsiSolveStats stats;
    CHECK(psi_solve_pure(k, l, scratch, stats));
    l.prev_psi = old_psi.data();
    l.old_ocean_x = l.out_ocean_x = s.ocean_current_x.data();
    l.old_ocean_y = l.out_ocean_y = s.ocean_current_y.data();
    l.out_psi = s.ocean_psi.data(); l.out_curl = s.wind_stress_curl.data();
    CHECK(psi_solve_pure(k, l, scratch, stats));
    CHECK(s.ocean_current_x == expected_x && s.ocean_current_y == expected_y);
    CHECK(s.ocean_psi == expected_psi && s.wind_stress_curl == expected_curl);
    for (int i = 0; i < n; ++i) if (!terrain[i])
        CHECK(s.ocean_current_x[i] == 0 && s.ocean_current_y[i] == 0 && s.ocean_psi[i] == 0);
    return true;
}

#ifdef PK_TEST_CLIMATE_WORKER
static bool worker_progress(bool all_land) {
    constexpr int n = 12;
    pk::RuntimeEnvironmentSnapshot in;
    in.cell_count = n; in.generation = 1; in.day = 0;
    in.climate_worker_authoritative = true; in.climate_round_ran = false;
    in.terrain.assign(n, 0); in.landform.assign(n, 0); in.is_water.assign(n, 0);
    in.neighbor_indices.assign(n * 6, -1);
    in.cell_pos_x.resize(n); in.cell_pos_y.resize(n); in.cell_lat_norm.resize(n);
    in.cell_elevation.assign(n, 0.3f); in.cell_temperature_transport_anomaly.assign(n, 0);
    in.cell_wind_x.assign(n, 1); in.cell_wind_y.assign(n, 0); in.cell_wind_speed.assign(n, 0.5f);
    in.cell_ocean_current_x.assign(n, 0); in.cell_ocean_current_y.assign(n, 0);
    for (int i = 0; i < n; ++i) {
        in.terrain[i] = !all_land && i % 3 ? 1 : 0;
        in.is_water[i] = in.terrain[i];
        in.cell_pos_x[i] = float(i % 4) * 1.7320508f;
        in.cell_pos_y[i] = float(i / 4) * 1.5f;
        in.cell_lat_norm[i] = 0.1f + 0.8f * float(i / 4) / 2;
        if (i % 4 < 3) in.neighbor_indices[i * 6] = i + 1;
        if (i % 4) in.neighbor_indices[i * 6 + 3] = i - 1;
        if (i >= 4) in.neighbor_indices[i * 6 + 1] = i - 4;
        if (i + 4 < n) in.neighbor_indices[i * 6 + 4] = i + 4;
    }
    auto &k = in.climate_physics_knobs;
    k.ready = 1; k.enabled = true; k.water_id_count = 4;
    k.water_terrain_ids = {1, 2, 3, 4};
    k.land_lf_hill = 1; k.land_lf_mountain = 2; k.land_lf_peak = 3;
    k.daily_split = true; k.daily_period_days = 2; k.ocean_period_days = 3;
    k.lat_lut_bins = 16; k.world_seed = 713;
    k.wind_traj_table_enabled = 1; k.wind_momentum_advect_w = 0.1f;
    k.wind_momentum_diffuse_w_daily = 0.01f; k.wind_div_damp_alpha = 0.05f;
    k.slp_mobile_low_count = 2; k.slp_mobile_low_amp = 0.03f;
    pk::RuntimeClimateKernel kernel, resumed;
    pk::RuntimeClimateCatalog catalog;
    pk::RuntimeClimateStore current, next, retry;
    current.reset(n); next.reset(n); retry.reset(n);
    current.temperature.assign(n, 0.65f);
    current.temperature_baseline.assign(n, 0.65f);
    current.thermal_energy.assign(n, 0.65f);
    std::string error;
    CHECK(kernel.compile_catalog(in, catalog, error));
    pk::RuntimeClimateKernelReport report;
    CHECK(kernel.plan_day(0, in, catalog, current, next, report));
    CHECK(!next.physics_state.empty() && report.completed);
    const auto first = next.physics_state;
    CHECK(kernel.plan_day(0, in, catalog, current, retry, report));
    CHECK(retry.physics_state == first && current.physics_state.empty());
    // Production capture sends canonical CSR offsets beside the six-wide
    // table. This must not silently disable the physical prepass.
    in.neighbor_offsets.resize(n + 1);
    for (int i = 0; i <= n; ++i) in.neighbor_offsets[i] = i * 6;
    CHECK(pk::runtime_climate_physics_inputs_ready(in, n, error));
    CHECK(kernel.plan_day(0, in, catalog, current, retry, report));
    CHECK(retry.physics_state == first);
    in.neighbor_offsets[2] = 11;
    CHECK(!pk::runtime_climate_physics_inputs_ready(in, n, error));
    in.neighbor_offsets[2] = 12;
    retry.temperature[0] = std::numeric_limits<float>::quiet_NaN();
    CHECK(kernel.plan_day(0, in, catalog, current, retry, report));
    CHECK(retry.physics_state == first);
    RuntimeClimatePhysicsState state;
    CHECK(restore_physics_state(first.data(), first.size(), state, error));
    CHECK(state.initialized && state.last_slp_day == 0 && state.last_wind_day == 0 && state.last_ocean_day == 0);
    CHECK(state.wind_speed != in.cell_wind_speed);
    if (!all_land) CHECK(std::any_of(state.ocean_psi.begin(), state.ocean_psi.end(), [](float v) { return v != 0; }));
    const auto wind0 = state.wind_x, slp0 = state.slp, ocean0 = state.ocean_psi;
    pk::RuntimeClimateKernel::commit(current, next);
    for (int day = 1; day <= 6; ++day) {
        in.day = day; in.generation = day + 1; in.season_phase = float(day) * 0.03f;
        // 接管后主线程风种子改变不应影响计划，也不能因无 weather/round 停止物理。
        in.cell_wind_x.assign(n, -1);
        CHECK(kernel.plan_day(day, in, catalog, current, next, report));
        auto changed_seed = in;
        changed_seed.cell_wind_x.assign(n, 1);
        changed_seed.cell_ocean_current_x.assign(n, 0.4f);
        CHECK(resumed.plan_day(day, changed_seed, catalog, current, retry, report));
        CHECK(next.physics_state == retry.physics_state);
        CHECK(restore_physics_state(next.physics_state.data(), next.physics_state.size(), state, error));
        if (day == 1) CHECK(state.wind_x == wind0 && state.slp == slp0 && state.ocean_psi == ocean0);
        if (day == 2) CHECK(state.last_wind_day == 2 && state.last_slp_day == 0);
        if (day == 3) CHECK(state.last_ocean_day == 3);
        if (day == 4) CHECK(state.last_slp_day == 4 && state.last_wind_day == 2);
        pk::RuntimeClimateKernel::commit(current, next);
    }
    CHECK(state.daily_due_seq == 4 && state.last_ocean_day == 6);
    auto damaged = current;
    damaged.physics_state.back() ^= 1;
    in.day = 7;
    CHECK(!kernel.plan_day(7, in, catalog, damaged, next, report));
    in.climate_worker_authoritative = false;
    CHECK(kernel.plan_day(7, in, catalog, current, next, report));
    CHECK(restore_physics_state(next.physics_state.data(), next.physics_state.size(), state, error));
    CHECK(!state.initialized); // SHADOW 不接管物理。
    return true;
}
#endif

int main() {
    std::string error;
    if (!self_test(error)) { std::fprintf(stderr, "%s\n", error.c_str()); return 1; }
    if (!state_roundtrip() || !forcing_and_divergence() || !psi_alias(false) || !psi_alias(true)) return 1;
#ifdef PK_TEST_CLIMATE_WORKER
    if (!worker_progress(false) || !worker_progress(true)) return 1;
#endif
    std::puts("PASS climate physics focused tests");
    return 0;
}
