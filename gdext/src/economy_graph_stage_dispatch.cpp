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

void flush_formula_owned_mirrors(NativeEconomyRuntime *runtime) {
    if (runtime == nullptr || !runtime->formula_owned_bound()) return;
    runtime->flush_formula_owned_domain_mirrors();
}

} // namespace

bool economy_dispatch_mutate_stage(EconomySoAView &view,
                                   RuntimeEconomyGraphStage stage,
                                   EconomyStageCursor &cursor,
                                   const RuntimeEconomyEpochInput &input,
                                   EconomyStageResult &result,
                                   std::string &error) {
    result.reset();
    error.clear();
    auto *runtime =
        static_cast<NativeEconomyRuntime *>(view.runtime_hook);
    if (runtime == nullptr) {
        error = "economy_dispatch_runtime_null";
        result.ok = false;
        return false;
    }
    if (runtime->formula_owned_bound() &&
        (view.population == nullptr || view.market == nullptr ||
         view.buildings == nullptr)) {
        fail_stage(result, error, "economy_dispatch_soa_view_incomplete",
                   "soa_view_incomplete");
        return false;
    }

    switch (stage) {
    case RuntimeEconomyGraphStage::BUILDING_PLAN: {
        int64_t work = 0;
        std::string plan_error;
        if (!runtime->run_building_plan_drain(work, plan_error)) {
            fail_stage(result, error,
                       plan_error.empty()
                           ? "economy_dispatch_building_plan_failed"
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
        flush_formula_owned_mirrors(runtime);
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::LEDGER_APPLY: {
        int64_t work = 0;
        std::string ledger_error;
        if (static_cast<int32_t>(cursor.command_cursor) >
            runtime->_command_cursor) {
            runtime->_command_cursor =
                static_cast<int32_t>(cursor.command_cursor);
        }
        if (!runtime->run_ledger_apply_drain(work, ledger_error)) {
            fail_stage(result, error,
                       ledger_error.empty()
                           ? "economy_dispatch_ledger_apply_failed"
                           : ledger_error,
                       "ledger_apply");
            cursor.command_cursor =
                static_cast<uint32_t>(runtime->_command_cursor);
            return false;
        }
        cursor.command_cursor =
            static_cast<uint32_t>(runtime->_command_cursor);
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::BUILDING_EMPLOYMENT: {
        int64_t work = 0;
        std::string emp_error;
        if (!runtime->run_building_employment_drain(work, emp_error)) {
            fail_stage(result, error,
                       emp_error.empty()
                           ? "economy_dispatch_employment_failed"
                           : emp_error,
                       "building_employment");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::BUILDING_PRODUCTION: {
        int64_t work = 0;
        std::string prod_error;
        if (!runtime->run_building_production_drain(work, prod_error)) {
            fail_stage(result, error,
                       prod_error.empty()
                           ? "economy_dispatch_production_failed"
                           : prod_error,
                       "building_production");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::HOUSEHOLD_MARKET: {
        int64_t work = 0;
        std::string household_error;
        if (!runtime->run_household_market_drain(work, household_error)) {
            fail_stage(result, error,
                       household_error.empty()
                           ? "economy_dispatch_household_failed"
                           : household_error,
                       "household_market");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::GOVERNMENT_RESEARCH_PROCUREMENT: {
        int64_t work = 0;
        std::string research_error;
        if (!runtime->run_government_research_drain(work, research_error)) {
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
        flush_formula_owned_mirrors(runtime);
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::STRUCTURAL_COMMIT: {
        int64_t work = 0;
        std::string structural_error;
        if (!runtime->run_structural_commit_drain(work, structural_error)) {
            fail_stage(result, error,
                       structural_error.empty()
                           ? "economy_dispatch_structural_failed"
                           : structural_error,
                       "structural_commit");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::BUILDING_COMMIT: {
        int64_t work = 0;
        std::string building_error;
        if (!runtime->run_building_commit_slice(work, building_error)) {
            fail_stage(result, error,
                       building_error.empty()
                           ? "economy_dispatch_building_commit_failed"
                           : building_error,
                       "building_commit");
            return false;
        }
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::FAMILY_COMMIT: {
        int64_t work = 0;
        std::string family_error;
        if (!runtime->run_family_commit_drain(work, family_error)) {
            fail_stage(result, error,
                       family_error.empty()
                           ? "economy_dispatch_family_commit_failed"
                           : family_error,
                       "family_commit");
            return false;
        }
        flush_formula_owned_mirrors(runtime);
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::PERSON_COMMIT: {
        int64_t work = 0;
        std::string person_error;
        if (!runtime->run_person_commit_drain(work, person_error)) {
            fail_stage(result, error,
                       person_error.empty()
                           ? "economy_dispatch_person_commit_failed"
                           : person_error,
                       "person_commit");
            return false;
        }
        flush_formula_owned_mirrors(runtime);
        finish_ok(result, input, runtime);
        return true;
    }
    case RuntimeEconomyGraphStage::AGGREGATE_PUBLISH: {
        int64_t work = 0;
        std::string publish_error;
        if (!runtime->run_aggregate_publish_drain(work, publish_error)) {
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
