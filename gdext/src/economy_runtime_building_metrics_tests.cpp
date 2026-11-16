#include "economy_runtime.h"
#include "economy_runtime_test_access.h"

#include <array>
#include <memory>

namespace pk {

bool EconomyTargetSelectorTests::run_building_chain_metrics(std::string &error) {
    auto runtime = std::make_unique<NativeEconomyRuntime>();
    auto &rt = *runtime;
    rt._cell_count = 4;
    rt._building_upgrade_family_ids = {"complete", "missing", "single", "high"};
    rt._building_upgrade_family_indices = {0, 0, 0, 1, 1, 2, 2, 3, 3};
    rt._building_upgrade_tiers = {0, 1, 1, 0, 2, 0, 0, 0, 31};
    rt.rebuild_building_upgrade_requirements();
    // Cell 0: complete chain plus a duplicate tier, and an incomplete chain.
    // Cell 1: two types of the same tier must NOT count as a complete chain.
    // Cell 2: tier 31 must survive the unsigned bit mask. Cell 3 is empty.
    const int32_t types[] = {0, 1, 2, 3, 5, 6, 7, 8};
    const int32_t cells[] = {0, 0, 0, 0, 1, 1, 2, 2};
    for (size_t i = 0; i < 8; ++i) {
        NativeEconomyRuntime::BuildingGroup group;
        group.cell = cells[i];
        group.type_id = types[i];
        group.count = 1;
        rt.append_building_group(group);
    }
    rt._building_cell_offsets = {0, 4, 6, 8, 8};
    MetricMask mask;
    mask.set(NativeEconomyRuntime::FAMILY_METRIC_CELL_COMPLETE_CHAIN_COUNT);
    std::array<int64_t, NativeEconomyRuntime::FAMILY_METRIC_COUNT> values{};
    for (int repeat = 0; repeat < 3; ++repeat) {
        for (int cell = 0; cell < 4; ++cell) {
            rt.sample_effect_metrics(cell, values.size(), values.data(), mask);
            const int64_t expected = (cell == 0 || cell == 2) ? 65536 : 0;
            if (values[NativeEconomyRuntime::FAMILY_METRIC_CELL_COMPLETE_CHAIN_COUNT] != expected) {
                error = "building_chain_complete_distinct_and_empty";
                return false;
            }
        }
    }
    if (rt._building_upgrade_catalog_builds != 1 ||
        rt._building_upgrade_catalog_rows != 9) {
        error = "building_chain_sampling_does_not_rebuild_catalog";
        return false;
    }
    // Structural changes use current building rows, not a cached cell answer.
    rt.building_at(1).count = 0;
    rt.building_at(2).count = 0;
    rt.sample_effect_metrics(0, values.size(), values.data(), mask);
    if (values[NativeEconomyRuntime::FAMILY_METRIC_CELL_COMPLETE_CHAIN_COUNT] != 0) {
        error = "building_chain_removed_tier_is_immediately_visible";
        return false;
    }
    rt.reset("building_chain_catalog_reset");
    if (!rt._building_upgrade_required_tiers.empty() ||
        rt._building_upgrade_catalog_builds != 0) {
        error = "building_chain_reset_clears_catalog";
        return false;
    }
    rt._building_upgrade_family_ids = {"replacement"};
    rt._building_upgrade_family_indices = {0, 0};
    rt._building_upgrade_tiers = {2, 3};
    rt.rebuild_building_upgrade_requirements();
    if (rt._building_upgrade_required_tiers != std::vector<uint32_t>{12}) {
        error = "building_chain_new_catalog_replaces_old_tiers";
        return false;
    }
    return true;
}

} // namespace pk
