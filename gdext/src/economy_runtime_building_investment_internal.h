#pragma once

#include "economy_runtime.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <vector>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

struct NativeEconomyRuntime::BuildingInvestmentCellContext {
    struct Candidate {
        // Canonical physical/economic candidate. Execution-only metadata below
        // is deliberately kept separate from the plan's economics.
        InvestmentCandidatePlan plan;
        int64_t shortage_q16 = 0;
        int64_t score_q16 = 0;
        int32_t driver_good_id = -1;
        int64_t driver_deficit = 0;
        int64_t driver_output_per_building = 0;
        int64_t willing_population = 0;
        int64_t transferable_capital = 0;
        int64_t income_improvement_q16 = 0;
        int64_t desired_count = 0;
        int64_t jobs_per_building = 0;
        int64_t stealable = 0;
        int64_t challenger_unit_cost = 0;
        int64_t incumbent_unit_cost = 0;
        int64_t cost_advantage_q16 = 0;
        bool displaces_incumbents = false;
        bool startup_driven = false;
        // Sponsor already occupies an owner seat and will move into the new
        // type's profession. Spare-population staffing must not treat that as
        // a net-new body demand (it zero-sum reallocates committed seats).
        bool reallocates_owner_seat = false;
    };

    int32_t cell = -1;
    bool capture_investment_diagnostics = false;
    int64_t cell_population = 0;
    int64_t cell_unemployed = 0;
    std::vector<int64_t> &cell_profession_population;
    int64_t employment_gap = 0;
    InvestmentRequestContext cell_request;
    std::array<Candidate, 4> portfolio{};
    int32_t portfolio_size = 0;
    bool eligible_but_unfunded = false;
    int32_t market = -1;
    int32_t country = -1;
    int32_t available_begin = 0;
    int32_t available_end = 0;
    int64_t available_credit = 0;
    bool portfolio_population_changed = false;
    int32_t active_types = 0;
    std::array<ConstructionMaterialPlan, 4> commit_material_plans{};
    int32_t commit_cost_factor = Q16_ONE;
    int32_t commit_time_factor = Q16_ONE;
    int64_t total_buildings = 0;
    int64_t total_owner_population = 0;
    int64_t max_type_owner_population = 0;

    explicit BuildingInvestmentCellContext(int32_t cell_value);
    BuildingInvestmentCellContext(const BuildingInvestmentCellContext &) = delete;
    BuildingInvestmentCellContext &operator=(
        const BuildingInvestmentCellContext &) = delete;
    BuildingInvestmentCellContext(BuildingInvestmentCellContext &&) = delete;
    BuildingInvestmentCellContext &operator=(BuildingInvestmentCellContext &&) = delete;

    void insert_candidate(const Candidate &candidate, int32_t max_types) {
        int32_t pos = portfolio_size;
        for (int32_t i = 0; i < portfolio_size; ++i) {
            if (better(candidate, portfolio[i])) {
                pos = i;
                break;
            }
        }
        if (pos >= max_types) return;
        const int32_t new_size = std::min(max_types, portfolio_size + 1);
        for (int32_t i = new_size - 1; i > pos; --i)
            portfolio[i] = portfolio[i - 1];
        portfolio[pos] = candidate;
        portfolio_size = new_size;
    }

    static bool better(const Candidate &a, const Candidate &b) {
        if (b.plan.type_id < 0) return true;
        if (a.plan.target_return_on_capital_q16 !=
                b.plan.target_return_on_capital_q16)
            return a.plan.target_return_on_capital_q16 >
                b.plan.target_return_on_capital_q16;
        if (a.cost_advantage_q16 != b.cost_advantage_q16)
            return a.cost_advantage_q16 > b.cost_advantage_q16;
        if (a.driver_good_id == b.driver_good_id &&
            a.challenger_unit_cost != b.challenger_unit_cost)
            return a.challenger_unit_cost < b.challenger_unit_cost;
        if (a.score_q16 != b.score_q16) return a.score_q16 > b.score_q16;
        if (a.plan.payback_days != b.plan.payback_days)
            return a.plan.payback_days < b.plan.payback_days;
        if (a.income_improvement_q16 != b.income_improvement_q16)
            return a.income_improvement_q16 > b.income_improvement_q16;
        if (a.plan.target_profit_per_day != b.plan.target_profit_per_day)
            return a.plan.target_profit_per_day > b.plan.target_profit_per_day;
        if (a.jobs_per_building != b.jobs_per_building)
            return a.jobs_per_building > b.jobs_per_building;
        if (a.plan.type_id != b.plan.type_id) return a.plan.type_id < b.plan.type_id;
        return a.plan.owner_signature_id < b.plan.owner_signature_id;
    }

    static uint64_t cell_key(int32_t cell, int32_t id) {
        return (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
            static_cast<uint32_t>(id);
    }
};


} // namespace pk
