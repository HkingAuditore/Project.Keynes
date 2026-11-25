#include "economy_invariant_probe.h"
#include "economy_runtime.h"

#include <array>
#include <memory>

namespace pk {

bool EconomyInvariantProbe::run_demand_basis_cache(std::string &error) {
    auto runtime = std::make_unique<NativeEconomyRuntime>();
    auto &rt = *runtime;
    constexpr int32_t cells = 6400;
    constexpr int32_t last_cell = cells - 1;
    rt._cell_count = cells;
    rt._sample_day = 7;
    rt._needs.resize(2);
    rt._variants.resize(3);
    rt._needs[0].variant_count = 1;
    rt._needs[1].variant_begin = 1;
    rt._needs[1].variant_count = 2;
    rt._needs[0].quantity_env_curve = 0;
    rt._variants[1].preference_env_curve = 0;
    rt._environment_curves.resize(1);
    auto &curve = rt._environment_curves[0];
    for (int32_t &value : curve.values_q16) value = 65536;
    curve.values_q16[0] = 32768;

    using Basis = std::array<std::vector<int64_t>, 5>;
    const auto direct = [&](const NativeEconomyRuntime::EnvironmentSample &sample) {
        Basis out;
        int64_t sat = 0;
        rt.build_demand_basis(-1, sample, out[0], out[1], out[2], out[3], out[4], sat);
        return out;
    };
    const auto cached = [&](int32_t cell, const NativeEconomyRuntime::EnvironmentSample &sample) {
        Basis out;
        int64_t sat = 0;
        rt.build_demand_basis_cached(cell, -1, sample, out[0], out[1], out[2],
                                     out[3], out[4], sat);
        return out;
    };
    NativeEconomyRuntime::EnvironmentSample cold;
    cold.temperature_q16 = 0;
    const NativeEconomyRuntime::EnvironmentSample warm;
    const auto cold_basis = direct(cold);
    const auto warm_basis = direct(warm);
    if (cold_basis == warm_basis || cached(last_cell, cold) != cold_basis ||
            cached(-1, warm) != warm_basis || cached(cells, cold) != cold_basis ||
            rt._demand_basis_cache.index_bytes() != 0 ||
            rt._demand_basis_cache.values_bytes() != 0) {
        error = "demand_basis_unregistered_cell_must_compute_without_allocating_cache";
        return false;
    }

    rt.register_demand_basis_cell(last_cell);
    rt.register_demand_basis_cell(last_cell);
    rt.register_demand_basis_cell(0);
    if (rt._demand_basis_cache.slots.size() != 2 ||
            cached(last_cell, cold) != cold_basis || cached(0, warm) != warm_basis ||
            cached(last_cell, warm) != cold_basis || cached(0, cold) != warm_basis) {
        error = "demand_basis_cell_slot_reuse_or_isolation_failed";
        return false;
    }

    // The employment refresh must overwrite the ready row using the current
    // environment, while leaving the other market's first write intact.
    rt._epoch_building_cells = {last_cell};
    rt.market_store().cell_to_market.assign(cells, -1);
    rt.prepare_due_demand_basis_cache();
    if (cached(last_cell, cold) != warm_basis || cached(0, cold) != warm_basis) {
        error = "demand_basis_employment_refresh_did_not_replace_the_cached_row";
        return false;
    }

    const int64_t value_bytes = rt._demand_basis_cache.values_bytes();
    rt.clear_demand_basis_day();
    ++rt._sample_day;
    rt.register_demand_basis_cell(0);
    if (rt._demand_basis_cache.cell_to_slot[last_cell] != -1 ||
            cached(0, cold) != cold_basis || cached(last_cell, warm) != warm_basis ||
            rt._demand_basis_cache.slots.size() != 1 ||
            rt._demand_basis_cache.values_bytes() != value_bytes) {
        error = "demand_basis_new_day_reused_stale_lookup_or_values";
        return false;
    }

    constexpr int32_t dense_cells = 3;
    auto dense = std::make_unique<NativeEconomyRuntime>();
    dense->_cell_count = dense_cells;
    dense->_needs.resize(1);
    for (int32_t cell = 0; cell < dense_cells; ++cell)
        dense->register_demand_basis_cell(cell);
    if (dense->_demand_basis_cache.values.capacity() >
            dense_cells * dense->demand_basis_row_width()) {
        error = "demand_basis_dense_world_capacity_exceeds_its_cell_count";
        return false;
    }
    return true;
}

} // namespace pk
