#include "economy_graph_stage_dispatch.h"

#include "economy_runtime.h"

#include <algorithm>
#include <cstdio>

namespace pk {
namespace {

void finish_ok(EconomyStageResult &result, const RuntimeEconomyEpochInput &input,
               NativeEconomyRuntime *runtime) {
    result.work_units = input.cell_count;
    result.state_hash = static_cast<uint64_t>(
        std::max<int64_t>(0, runtime->state_hash()));
    result.ok = true;
    result.fatal = false;
}

void fail_stage(EconomyStageResult &result, std::string &error,
                const std::string &detail, const char *reason_tag) {
    error = detail;
    result.ok = false;
    result.fatal = true;
    std::snprintf(result.fatal_reason, sizeof(result.fatal_reason), "%s",
                  reason_tag != nullptr ? reason_tag : "economy_stage");
}

} // namespace

bool economy_dispatch_mutate_stage(void *runtime_hook,
                                   RuntimeEconomyGraphStage stage,
                                   EconomyStageCursor &cursor,
                                   const RuntimeEconomyEpochInput &input,
                                   EconomyStageResult &result,
                                   std::string &error) {
    result.reset();
    error.clear();
    auto *runtime = static_cast<NativeEconomyRuntime *>(runtime_hook);
    if (runtime == nullptr) {
        error = "economy_dispatch_runtime_null";
        result.ok = false;
        return false;
    }

    const std::vector<int32_t> &building_cells =
        !runtime->_epoch_building_cells.empty() ? runtime->_epoch_building_cells
                                                : runtime->_building_active_cells;

    switch (stage) {
    case RuntimeEconomyGraphStage::BUILDING_PLAN: {
        NativeEconomyRuntime::BuildingPlanResult plan;
        std::string plan_error;
        const int32_t active_end =
            static_cast<int32_t>(runtime->_building_active_cells.size());
        if (!runtime->prepare_building_economic_plan(0, active_end, nullptr,
                                                     plan, plan_error) ||
            !plan.ok) {
            fail_stage(result, error,
                       plan_error.empty()
                           ? (plan.error.empty()
                                  ? "economy_dispatch_building_plan_failed"
                                  : plan.error)
                           : plan_error,
                       "building_plan");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::TRADE_SETTLE: {
        std::string settle_error;
        if (!runtime->settle_due_trade_orders(settle_error)) {
            fail_stage(result, error,
                       settle_error.empty()
                           ? "economy_dispatch_trade_settle_failed"
                           : settle_error,
                       "trade_settle");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::LEDGER_APPLY: {
        const int32_t n =
            static_cast<int32_t>(runtime->_epoch_commands.size());
        if (static_cast<int32_t>(cursor.command_cursor) >= n) {
            finish_ok(result, input, runtime);
            return true;
        }
        runtime->_command_cursor =
            static_cast<int32_t>(cursor.command_cursor);
        const int32_t end = std::min<int32_t>(
            n, runtime->_command_cursor + runtime->_commands_per_slice);
        for (; runtime->_command_cursor < end; ++runtime->_command_cursor) {
            const NativeEconomyRuntime::Command &command =
                runtime->_epoch_commands[static_cast<size_t>(
                    runtime->_command_cursor)];
            std::string cmd_error;
            if (!runtime->apply_command(command, cmd_error)) {
                fail_stage(result, error,
                           cmd_error.empty()
                               ? "economy_dispatch_ledger_apply_failed"
                               : cmd_error,
                           "ledger_apply");
                cursor.command_cursor =
                    static_cast<uint32_t>(runtime->_command_cursor);
                return false;
            }
        }
        cursor.command_cursor =
            static_cast<uint32_t>(runtime->_command_cursor);
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::BUILDING_EMPLOYMENT: {
        std::string emp_error;
        for (int32_t cell : building_cells) {
            if (!runtime->run_building_employment_cell(cell, true, emp_error)) {
                fail_stage(result, error,
                           emp_error.empty()
                               ? "economy_dispatch_employment_failed"
                               : emp_error,
                           "building_employment");
                return false;
            }
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::BUILDING_PRODUCTION: {
        std::string prod_error;
        for (int32_t cell : building_cells) {
            NativeEconomyRuntime::ProductionResult prod;
            if (!runtime->run_building_production_cell(cell, prod,
                                                      prod_error)) {
                fail_stage(result, error,
                           prod_error.empty()
                               ? "economy_dispatch_production_failed"
                               : prod_error,
                           "building_production");
                return false;
            }
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::HOUSEHOLD_MARKET:
        return runtime->kernel_run_household_market_boundary(cursor, input,
                                                             result, error);
    case RuntimeEconomyGraphStage::GOVERNMENT_RESEARCH_PROCUREMENT: {
        std::string research_error;
        if (!runtime->run_government_research_procurement(research_error)) {
            fail_stage(result, error,
                       research_error.empty()
                           ? "economy_dispatch_research_failed"
                           : research_error,
                       "research");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::TRADE_DISPATCH: {
        std::string dispatch_error;
        if (!runtime->dispatch_trade_candidates(dispatch_error)) {
            fail_stage(result, error,
                       dispatch_error.empty()
                           ? "economy_dispatch_trade_dispatch_failed"
                           : dispatch_error,
                       "trade_dispatch");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::STRUCTURAL_COMMIT: {
        const int32_t n =
            static_cast<int32_t>(runtime->_structural_commands.size());
        if (n <= 0 || runtime->_structural_cursor >= n) {
            finish_ok(result, input, runtime);
            return true;
        }
        const int32_t end = std::min<int32_t>(
            n, runtime->_structural_cursor + runtime->_commands_per_slice);
        for (; runtime->_structural_cursor < end;
             ++runtime->_structural_cursor) {
            std::string structural_error;
            if (!runtime->commit_structural(
                    runtime->_structural_commands[static_cast<size_t>(
                        runtime->_structural_cursor)],
                    structural_error)) {
                fail_stage(result, error,
                           structural_error.empty()
                               ? "economy_dispatch_structural_failed"
                               : structural_error,
                           "structural_commit");
                return false;
            }
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::BUILDING_COMMIT: {
        (void)cursor;
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::FAMILY_COMMIT: {
        int64_t work = 0;
        std::string family_error;
        if (!runtime->run_family_commit_slice(work, family_error)) {
            fail_stage(result, error,
                       family_error.empty()
                           ? "economy_dispatch_family_commit_failed"
                           : family_error,
                       "family_commit");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::PERSON_COMMIT: {
        int64_t work = 0;
        std::string person_error;
        if (!runtime->run_person_commit_slice(work, person_error)) {
            fail_stage(result, error,
                       person_error.empty()
                           ? "economy_dispatch_person_commit_failed"
                           : person_error,
                       "person_commit");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::AGGREGATE_PUBLISH: {
        int64_t work = 0;
        std::string publish_error;
        if (!runtime->publish_epoch_slice(work, publish_error)) {
            fail_stage(result, error,
                       publish_error.empty()
                           ? "economy_dispatch_publish_failed"
                           : publish_error,
                       "aggregate_publish");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::COUNT:
        break;
    }
    error = "economy_dispatch_stage_unknown";
    result.ok = false;
    return false;
}

} // namespace pk
