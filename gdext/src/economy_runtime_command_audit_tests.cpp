#include "economy_runtime.h"
#include "economy_runtime_test_access.h"
#include "runtime_economy_pod.h"

#include <memory>

namespace pk {

bool EconomyTargetSelectorTests::run_owned_stock_audit(std::string &error) {
    auto authority = std::make_unique<RuntimeEconomyPodAuthority>();
    auto runtime = std::make_unique<NativeEconomyRuntime>();
    auto &rt = *runtime;
    authority->initialize_state(2, 2);
    authority->set_authority_mode(RuntimeEconomyAuthorityMode::POD_ACTIVE);
    auto &owned = authority->state();
    // This is the production OwnedState alias. No live-world scheduler or wall
    // clock chooses whether the command falls before or after an epoch close.
    rt._formula_owned = &owned;
    rt._cell_count = 2;
    rt._good_merchant_buy_factor_q16 = {65536, 65536};
    rt._closing_audit_mode = 2;
    rt._closing_audit_runtime_disabled = false;
    const auto expect = [&](bool ok, const char *label) {
        if (!ok && error.empty()) error = label;
        return ok;
    };
    const auto apply = [&](int32_t opcode, int32_t good, int64_t quantity,
                           int64_t expected_settled) {
        RuntimeEconomyPodCommand command;
        command.opcode = opcode;
        command.target_cell = 0;
        command.target_country = good;
        command.payload0 = quantity;
        int64_t settled = -1;
        return authority->try_apply_owned_core_command(command, error, settled) &&
            rt.pull_owned_command_result(owned, command, settled, error) &&
            expect(settled == expected_settled, "owned_stock_audit_settled_quantity");
    };
    const auto run = [&]() {
        owned.market.stock.write_scalar(0, 120);
        owned.market.stock.write_scalar(1, 80);
        rt._closing_totals = rt.audit_totals();
        rt.begin_incremental_audit_epoch();
        rt._epoch_active = false;
        // The completed epoch never wrote either lane. Both 400000-unit
        // additions must be part of the next opening, even after the per-epoch
        // explicit delta has reset. The old implementation loses all 800000.
        if (!apply(NativeEconomyRuntime::COMMAND_ADD_STOCK, 0, 400000, 400000) ||
            !apply(NativeEconomyRuntime::COMMAND_ADD_STOCK, 1, 400000, 400000))
            return false;
        if (!expect(rt._explicit_stock_delta == 800000,
                    "owned_stock_audit_explicit_delta_once")) return false;
        rt.clear_epoch_metrics();
        const auto opening = rt.audit_totals_from_shadow(rt._closing_totals);
        const auto full = rt.audit_totals();
        if (!expect(opening.goods_stock == 800200 &&
                    opening.goods_stock == full.goods_stock &&
                    rt._explicit_stock_delta == 0,
                    "owned_stock_audit_idle_opening_missing_800000")) return false;
        rt._opening_totals = opening;
        rt.begin_incremental_audit_epoch();
        rt._epoch_active = true;
        // Repeated writes of one lane register it once. The active-epoch
        // ledger still books each settled quantity, including capped removal.
        if (!apply(NativeEconomyRuntime::COMMAND_REMOVE_STOCK, 0, 17, 17) ||
            !apply(NativeEconomyRuntime::COMMAND_REMOVE_STOCK, 0, 23, 23) ||
            !apply(NativeEconomyRuntime::COMMAND_ADD_STOCK, 0, 9, 9) ||
            !apply(NativeEconomyRuntime::COMMAND_REMOVE_STOCK, 1, 900000, 400080))
            return false;
        const auto closing = rt.incremental_audit_totals();
        if (!expect(closing.goods_stock == rt.audit_totals().goods_stock &&
                    closing.goods_stock == opening.goods_stock + rt._explicit_stock_delta &&
                    rt._audit_market_touched_lanes.size() == 2,
                    "owned_stock_audit_active_ledger_and_dedup")) return false;
        rt._closing_totals = closing;
        rt.commit_incremental_audit_shadow();
        rt._epoch_active = false;
        rt.clear_epoch_metrics();
        const auto next = rt.audit_totals_from_shadow(rt._closing_totals);
        if (!expect(next.goods_stock == closing.goods_stock,
                    "owned_stock_audit_next_epoch_no_duplicate")) return false;
        rt._opening_totals = next;
        rt.begin_incremental_audit_epoch();
        // Another idle command after the shadow advances must be included in
        // the new generation rather than suppressed by the prior lane stamp.
        if (!apply(NativeEconomyRuntime::COMMAND_ADD_STOCK, 0, 11, 11)) return false;
        rt.clear_epoch_metrics();
        if (!expect(rt.audit_totals_from_shadow(rt._closing_totals).goods_stock ==
                        closing.goods_stock + 11 &&
                    rt.audit_totals().goods_stock == closing.goods_stock + 11,
                    "owned_stock_audit_next_generation_notification")) return false;

        // Exercise the restore-derived-state boundary, not a second save codec:
        // clear candidate scratch, install replacement stores, then run the
        // same audit snapshot/shadow rebuild used by end_restore(). The full
        // ECP2 round-trip remains covered by the world save/replay fixtures.
        rt.prepare_restore_candidate_scratch();
        authority->initialize_state(2, 2);
        owned.market.stock.write_scalar(0, 13);
        owned.market.stock.write_scalar(1, 17);
        rt._closing_totals = rt.audit_totals();
        rt._opening_totals = rt._closing_totals;
        rt.rebuild_incremental_audit_shadow();
        rt._closing_audit_force_full = true;
        rt.begin_incremental_audit_epoch();
        if (!apply(NativeEconomyRuntime::COMMAND_ADD_STOCK, 0, 7, 7) ||
            !apply(NativeEconomyRuntime::COMMAND_REMOVE_STOCK, 1, 4, 4))
            return false;
        rt.clear_epoch_metrics();
        return expect(rt.audit_totals_from_shadow(rt._closing_totals).goods_stock == 33 &&
                      rt.audit_totals().goods_stock == 33 &&
                      rt._audit_market_touched_lanes.size() == 2,
                      "owned_stock_audit_restore_rebuild_discards_old_lanes");
    };
    const bool ok = run();
    // The fixture only aliases the store; it does not own a world handoff.
    rt._formula_owned = nullptr;
    return ok;
}

} // namespace pk
