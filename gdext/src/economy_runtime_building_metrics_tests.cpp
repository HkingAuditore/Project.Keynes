#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
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

bool EconomyTargetSelectorTests::run_building_investment_review(std::string &error) {
    // Investment batches must not erase the last review of other buildings.
    auto investment = std::make_unique<NativeEconomyRuntime>();
    auto &inv = *investment;
    inv._cell_count = 2;
    inv._building_types.resize(1);
    inv._startup_demand_runtime_mode = 0;
    for (int32_t cell : {0, 1, 1}) {
        NativeEconomyRuntime::BuildingGroup group;
        group.cell = cell;
        group.type_id = 0;
        group.count = 1;
        inv.append_building_group(group);
    }
    inv._building_cell_offsets = {0, 1, 3};
    inv._building_investment_rejection = {
        NativeEconomyRuntime::INVESTMENT_REJECTION_TARGET_MARGIN,
        NativeEconomyRuntime::INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY,
        NativeEconomyRuntime::INVESTMENT_REJECTION_TARGET_MARGIN};
    inv._building_investment_score_q16 = {123, 456, 789};
    inv._building_investment_payback_days = {12, 34, 56};
    inv._investment_review_cell_indices = {1};
    bool changed = false;
    if (!inv.run_endogenous_building_investment(0, 0, true, changed, error))
        return false;
    if (inv._building_investment_rejection[0] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_TARGET_MARGIN ||
        inv._building_investment_rejection[1] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY ||
        inv._building_investment_score_q16 != std::vector<int64_t>{123, 456, 789} ||
        inv._building_investment_payback_days != std::vector<int64_t>{12, 34, 56}) {
        error = "investment_batch_erased_last_building_review";
        return false;
    }
    // Re-entry in another epoch (including a carried batch) has the same rule.
    inv._epoch_id = inv._epoch_id.get() + 1;
    if (!inv.run_endogenous_building_investment(0, 0, false, changed, error))
        return false;
    if (inv._building_investment_rejection[0] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_TARGET_MARGIN) {
        error = "investment_continuation_erased_unreviewed_building";
        return false;
    }
    // An actual review replaces only this cell/type, including zeroing old
    // score/payback when the newly evaluated candidate is rejected.
    NativeEconomyRuntime::InvestmentExistingType existing;
    existing.first_group = existing.representative_group = 1;
    existing.last_group = 2;
    existing.owner_required = 1;
    existing.filled_owner = 0;
    inv._investment_existing_by_cell_type[
        NativeEconomyRuntime::BuildingInvestmentCellContext::cell_key(1, 0)] = existing;
    inv._epoch_cell_country = {0, 0};
    inv._epoch_country_building_type_offsets = {0, 1};
    inv._epoch_country_building_type_indices = {0};
    inv.market_store().cell_to_market = {0, 1};
    NativeEconomyRuntime::BuildingInvestmentCellContext ctx(1);
    inv._investment_max_growth_share_q16 = 0;
    inv.investment_evaluate_cell_types(ctx);
    if (inv._building_investment_rejection[1] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY ||
        inv._building_investment_score_q16[1] != 456 ||
        inv._building_investment_payback_days[1] != 34) {
        error = "investment_skipped_type_lost_last_review";
        return false;
    }
    ctx.cell_request.reason = NativeEconomyRuntime::INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP;
    inv._building_investment_rejection[1] = NativeEconomyRuntime::INVESTMENT_REJECTION_TARGET_MARGIN;
    inv.investment_evaluate_cell_types(ctx);
    if (inv._building_investment_rejection[1] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY ||
        inv._building_investment_score_q16[1] != 0 ||
        inv._building_investment_payback_days[1] != 0 ||
        inv._building_investment_rejection[2] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY ||
        inv._building_investment_score_q16[2] != 0 ||
        inv._building_investment_payback_days[2] != 0 ||
        inv._building_investment_rejection[0] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_TARGET_MARGIN) {
        error = "investment_review_did_not_replace_only_reviewed_building";
        return false;
    }
    inv.investment_mark_rejection(&existing, NativeEconomyRuntime::INVESTMENT_REJECTION_NONE);
    if (inv._building_investment_rejection[1] != 0 ||
        inv._building_investment_rejection[2] != 0 ||
        inv._building_investment_rejection[0] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_TARGET_MARGIN) {
        error = "investment_success_did_not_clear_only_reviewed_building";
        return false;
    }
    NativeEconomyRuntime::BuildingGroup replacement;
    replacement.cell = 0;
    replacement.type_id = 0;
    replacement.count = 1;
    inv.append_building_group(replacement);
    if (inv._building_investment_rejection[3] != 0 ||
        inv._building_investment_score_q16[3] != 0 ||
        inv._building_investment_payback_days[3] != 0 ||
        inv._building_investment_rejection[0] !=
            NativeEconomyRuntime::INVESTMENT_REJECTION_TARGET_MARGIN) {
        error = "investment_new_building_changed_existing_review";
        return false;
    }
    inv.clear_building_groups();
    inv.append_building_group(replacement);
    if (inv._building_investment_rejection[0] != 0 ||
        inv._building_investment_score_q16[0] != 0 ||
        inv._building_investment_payback_days[0] != 0) {
        error = "investment_replacement_inherited_another_buildings_review";
        return false;
    }
    return true;
}

} // namespace pk
