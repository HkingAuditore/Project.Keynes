#include "economy_runtime.h"
#include "economy_runtime_test_access.h"

#include <memory>

namespace pk {

bool EconomyTargetSelectorTests::run_country_epoch_cache(std::string &error) {
    auto runtime = std::make_unique<NativeEconomyRuntime>();
    auto &rt = *runtime;
    const auto expect = [&](bool ok, const char *label) {
        if (!ok) error = label;
        return ok;
    };
    const auto initialize = [&]() {
        rt._cell_count = 6;
        rt._epoch_country_count = 2;
        rt._epoch_country_technology_words = 1;
        rt._epoch_country_handles = std::vector<uint64_t>{1ull << 32, (1ull << 32) | 1};
        rt._epoch_country_technologies = {1, 0};
        rt._epoch_cell_country = {0, 1, -1, 0, 1, 5};
        rt._technology_ids = {"a", "b", "c"};
        rt._good_ids = {"g0", "g1", "g2"};
        rt._good_technology_offsets = {0, 1, 2, 2};
        rt._good_required_technologies = {0, 1};
        rt._good_trade_enabled = {0, 1, 0};
        rt._good_storage_modes = {0, 0, 0};
        rt._profession_ids = {"p0", "p1"};
        rt._profession_technology_offsets = {0, 2, 2};
        rt._profession_required_technologies = {0, 1};
        rt._components.resize(3);
        rt._components[0].good_id = 0;
        rt._components[1].good_id = 0;
        rt._components[2].good_id = 1;
        rt._variants.resize(2);
        rt._variants[0].component_begin = 0;
        rt._variants[0].component_count = 1;
        rt._variants[1].component_begin = 1;
        rt._variants[1].component_count = 2;
        rt._building_types.resize(2);
        rt._building_technology_offsets = {0, 1, 1};
        rt._building_required_technologies = {0};
        rt._building_all_technology_offsets = {0, 1, 1};
        rt._building_all_required_technologies = {1};
        rt._building_dependency_branch_offsets = {0, 1, 2};
        rt._building_dependency_branch_technology_offsets = {0, 1, 1};
        rt._building_dependency_branch_technologies = {2};
        rt._building_dependency_branch_group_offsets = {0, 0, 0};
    };
    initialize();
    rt.refresh_country_availability_cache();
    rt.refresh_country_territory_cache();
    if (!expect(rt._epoch_country_good_available ==
                    std::vector<uint8_t>{1, 0, 1, 0, 0, 1} &&
                rt._epoch_country_market_available ==
                    std::vector<uint8_t>{1, 1, 1, 0, 1, 1} &&
                rt._epoch_country_profession_available ==
                    std::vector<uint8_t>{1, 1, 0, 1} &&
                rt._epoch_country_variant_available ==
                    std::vector<uint8_t>{1, 0, 0, 0} &&
                rt._epoch_country_building_available ==
                    std::vector<uint8_t>{0, 1, 0, 1},
                "country_cache_initial_availability")) return false;
    if (!expect(rt._epoch_country_cell_offsets == std::vector<int32_t>{0, 2, 4} &&
                rt._epoch_country_cells == std::vector<int32_t>{0, 3, 1, 4},
                "country_cache_sorted_territory")) return false;
    const uint64_t initial_hash = rt._epoch_country_topology_hash;
    for (int i = 0; i < 3; ++i) {
        // Cash/tax/research progress can advance the broad Country generation
        // without changing either input. Such changes must retain both caches.
        ++rt._epoch_country_generation;
        rt.refresh_country_availability_cache();
        rt.refresh_country_territory_cache();
    }
    if (!expect(rt._country_availability_cache.hits.load() == 3 &&
                rt._country_availability_cache.rebuilds.load() == 1 &&
                rt._country_territory_cache.hits.load() == 3 &&
                rt._country_territory_cache.rebuilds.load() == 1 &&
                rt._epoch_country_topology_hash == initial_hash,
                "country_cache_unchanged_inputs_reuse")) return false;

    // The real test hook updates both the epoch column and the separate
    // technology metric's source hash before the next availability capture.
    rt.set_epoch_country_technologies_for_test({7, 0});
    rt.refresh_country_availability_cache();
    if (!expect(rt._epoch_country_building_available[0] == 1 &&
                rt._epoch_country_variant_available[1] == 1 &&
                rt._country_availability_cache.rebuilds.load() == 2,
                "country_cache_technology_hook_unlocks")) return false;
    rt.clear_epoch_country_technologies_for_test();
    rt._epoch_country_technologies = {1, 0};
    rt.refresh_country_availability_cache();
    if (!expect(rt._epoch_country_building_available[0] == 0 &&
                rt._epoch_country_variant_available[1] == 0,
                "country_cache_technology_revoke_rebuilds")) return false;

    rt._epoch_cell_country[0] = 1;
    rt.refresh_country_territory_cache();
    if (!expect(rt._epoch_country_cell_offsets == std::vector<int32_t>{0, 1, 4} &&
                rt._epoch_country_cells == std::vector<int32_t>{3, 0, 1, 4} &&
                rt._epoch_country_topology_hash != initial_hash,
                "country_cache_territory_transfer_rebuilds")) return false;
    rt._epoch_country_count = 6;
    rt.refresh_country_territory_cache();
    if (!expect(rt.country_cell_count(5) == 1 && rt.country_cell_at(5, 0) == 5,
                "country_cache_country_growth_revalidates_owner")) return false;
    rt._epoch_country_count = 2;
    rt._epoch_country_handles = std::vector<uint64_t>{2ull << 32, (1ull << 32) | 1};
    const uint64_t technology_rebuilds = rt._country_availability_cache.rebuilds.load();
    rt.refresh_country_availability_cache();
    if (!expect(rt._country_availability_cache.rebuilds.load() ==
                    technology_rebuilds + 1,
                "country_cache_reused_country_slot_rebuilds")) return false;

    // Corrupt/cleared derived columns are never accepted merely because the
    // cached input is unchanged (restore and hand-built fixtures use this).
    rt._epoch_country_good_available.clear();
    rt._epoch_country_cell_offsets.clear();
    rt.refresh_country_availability_cache();
    rt.refresh_country_territory_cache();
    if (!expect(rt._epoch_country_good_available.size() == 6 &&
                rt.country_cell_count(0) == 1,
                "country_cache_cleared_output_rebuilds")) return false;
    const auto expected_goods = rt._epoch_country_good_available;
    const auto expected_buildings = rt._epoch_country_building_available;
    const auto expected_offsets = rt._epoch_country_cell_offsets;
    const auto expected_cells = rt._epoch_country_cells;
    const uint64_t expected_hash = rt._epoch_country_topology_hash;
    rt._country_availability_cache.invalidate();
    rt._country_territory_cache.invalidate();
    rt.refresh_country_availability_cache();
    rt.refresh_country_territory_cache();
    if (!expect(rt._epoch_country_good_available == expected_goods &&
                rt._epoch_country_building_available == expected_buildings &&
                rt._epoch_country_cell_offsets == expected_offsets &&
                rt._epoch_country_cells == expected_cells &&
                rt._epoch_country_topology_hash == expected_hash,
                "country_cache_invalidated_rebuild_is_identical")) return false;
    rt.prepare_restore_candidate_scratch();
    if (!expect(!rt._country_availability_cache.valid &&
                !rt._country_territory_cache.valid,
                "country_cache_restore_invalidates_inputs")) return false;

    rt.reset("country_cache_test_reconfigure");
    initialize();
    // Same shapes and country identities, but a newly configured catalog uses
    // another prerequisite. reset must prevent a false cache hit.
    rt._good_required_technologies[0] = 2;
    rt.refresh_country_availability_cache();
    rt.refresh_country_territory_cache();
    if (!expect(rt._epoch_country_good_available[0] == 0 &&
                rt._country_availability_cache.rebuilds.load() == 1 &&
                rt._country_availability_cache.hits.load() == 0 &&
                rt._country_territory_cache.rebuilds.load() == 1,
                "country_cache_new_catalog_invalidates")) return false;
    return true;
}

} // namespace pk
