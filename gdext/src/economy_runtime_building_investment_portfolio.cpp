#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <tuple>


namespace pk {

bool NativeEconomyRuntime::investment_portfolio_funds_feasible(
        int32_t cell, const InvestmentCandidatePlan *const *plans,
        const ConstructionMaterialPlan *materials, int32_t count) const {
    struct Account {
        int32_t signature;
        int64_t population;
        int64_t funds;
    };
    std::vector<Account> accounts;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        accounts.push_back({static_cast<int32_t>(population_store().signature_id[slot]),
            population_store().population[slot], population_store().funds[slot]});
    });
    const auto account_index = [&](int32_t signature) {
        for (size_t i = 0; i < accounts.size(); ++i)
            if (accounts[i].signature == signature) return i;
        accounts.push_back({signature, 0, 0});
        return accounts.size() - 1;
    };
    std::vector<size_t> merchants;
    for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
        merchants.push_back(account_index(static_cast<int32_t>(
            population_store().signature_id[_merchant_slots[k]])));
    }
    int64_t sat = 0;
    // 按实际的两阶段顺序预演：全部迁人/注资/放贷之后，才逐张支付建材。
    // 商人自建款和已注入业主的建造款，不能再次当作另一项目的可用现金。
    for (int32_t i = 0; i < count; ++i) {
        const auto &plan = *plans[i];
        if (plan.allocated_count <= 0) continue;
        const size_t source = account_index(static_cast<int32_t>(
            population_store().signature_id[plan.sponsor]));
        const size_t owner = account_index(plan.owner_signature_id);
        const int64_t capital = saturating_mul(
            plan.allocated_count, plan.funding_capital, sat);
        if (source != owner) {
            const int64_t people = saturating_mul(plan.allocated_count,
                std::max<int64_t>(1, _building_types[plan.type_id].owner_slots_per_building), sat);
            // Sponsor selection protects one source occupant. Reject an
            // overlapping allocation that would invalidate its stable slot.
            if (people >= accounts[source].population ||
                accounts[source].funds < capital || accounts[owner].funds < 0)
                return false;
            accounts[source].population -= people;
            accounts[owner].population = saturating_add(accounts[owner].population, people, sat);
            accounts[source].funds -= capital;
            accounts[owner].funds = saturating_add(accounts[owner].funds, capital, sat);
        }
        const int64_t credit = saturating_mul(
            plan.allocated_count, plan.merchant_credit, sat);
        if (credit <= 0) continue;
        int64_t cash = 0;
        for (size_t merchant : merchants)
            cash = saturating_add(cash, std::max<int64_t>(0, accounts[merchant].funds), sat);
        if (cash < credit) return false;
        int64_t prefix = 0, distributed = 0;
        for (size_t merchant : merchants) {
            prefix = saturating_add(prefix, std::max<int64_t>(0, accounts[merchant].funds), sat);
            const int64_t next = mul_div_sat(credit, prefix, cash, sat);
            const int64_t share = std::min(std::max<int64_t>(0, next - distributed),
                std::max<int64_t>(0, accounts[merchant].funds));
            distributed = saturating_add(distributed, share, sat);
            accounts[merchant].funds -= share;
        }
        if (distributed != credit) return false;
        accounts[owner].funds = saturating_add(accounts[owner].funds, credit, sat);
    }
    for (int32_t i = 0; i < count; ++i) {
        const auto &plan = *plans[i];
        if (plan.allocated_count <= 0) continue;
        const size_t owner = account_index(plan.owner_signature_id);
        const int64_t cost = materials[i].total_cost;
        if (!materials[i].feasible || cost < 0 || accounts[owner].funds < cost)
            return false;
        accounts[owner].funds -= cost;
        int64_t population = 0;
        for (size_t merchant : merchants) {
            if (_signatures[accounts[merchant].signature].profession_id == _merchant_profession_id)
                population = saturating_add(population, accounts[merchant].population, sat);
        }
        if (cost > 0 && population <= 0) return false;
        int64_t prefix = 0, distributed = 0;
        for (size_t merchant : merchants) {
            if (_signatures[accounts[merchant].signature].profession_id != _merchant_profession_id ||
                accounts[merchant].population <= 0) continue;
            prefix = saturating_add(prefix, accounts[merchant].population, sat);
            const int64_t next = mul_div_sat(cost, prefix, population, sat);
            accounts[merchant].funds = saturating_add(accounts[merchant].funds,
                std::max<int64_t>(0, next - distributed), sat);
            distributed = next;
        }
    }
    return sat == 0;
}

void NativeEconomyRuntime::investment_allocate_portfolio(
        BuildingInvestmentCellContext &ctx) {
    auto &cell = ctx.cell;
    auto &cell_population = ctx.cell_population;
    auto &employment_gap = ctx.employment_gap;
    auto &cell_request = ctx.cell_request;
    auto &portfolio = ctx.portfolio;
    auto &portfolio_size = ctx.portfolio_size;
    auto &available_credit = ctx.available_credit;
    auto &portfolio_population_changed = ctx.portfolio_population_changed;
    auto &active_types = ctx.active_types;
    auto &country = ctx.country;
    using Candidate = BuildingInvestmentCellContext::Candidate;

    _building_investment_candidates = saturating_add(
        _building_investment_candidates, portfolio_size, _saturation_count);

    const int64_t merchant_cash = investment_merchant_cash(cell);
    const int64_t outstanding_credit =
        investment_outstanding_credit(cell);
    const int64_t credit_exposure = mul_div_sat(
        merchant_cash, _merchant_credit_exposure_q16.get(),
        Q16_ONE, _saturation_count);
    const int64_t merchant_reserve = mul_div_sat(
        merchant_cash, _merchant_procurement_cash_reserve_q16.get(),
        Q16_ONE, _saturation_count);
    available_credit = std::max<int64_t>(0, std::min(
        credit_exposure - std::min(credit_exposure, outstanding_credit),
        merchant_cash - std::min(merchant_cash, merchant_reserve)));

    auto previously_allocated_owner_population = [&](int32_t sponsor,
                                                      uint64_t family) {
        int64_t used = 0;
        for (int32_t j = 0; j < portfolio_size; ++j) {
            if (portfolio[j].plan.sponsor != sponsor ||
                portfolio[j].plan.sponsor_family_handle != family) continue;
            used = saturating_add(used, saturating_mul(
                portfolio[j].plan.allocated_count,
                std::max<int64_t>(1, _building_types[
                    portfolio[j].plan.type_id].owner_slots_per_building),
                _saturation_count), _saturation_count);
        }
        return used;
    };
    auto previously_allocated_capital = [&](int32_t sponsor,
                                            uint64_t family) {
        int64_t used = 0;
        for (int32_t j = 0; j < portfolio_size; ++j) {
            if (portfolio[j].plan.sponsor != sponsor ||
                portfolio[j].plan.sponsor_family_handle != family) continue;
            used = saturating_add(used, saturating_mul(
                portfolio[j].plan.allocated_count,
                portfolio[j].plan.funding_capital, _saturation_count),
                _saturation_count);
        }
        return used;
    };
    auto previously_allocated_credit = [&]() {
        int64_t used = 0;
        for (int32_t j = 0; j < portfolio_size; ++j) {
            if (!portfolio[j].plan.uses_merchant_credit) continue;
            used = saturating_add(used, saturating_mul(
                portfolio[j].plan.allocated_count,
                portfolio[j].plan.merchant_credit, _saturation_count),
                _saturation_count);
        }
        return used;
    };
    auto previously_allocated_driver = [&](int32_t good_id) {
        int64_t used = 0;
        for (int32_t j = 0; j < portfolio_size; ++j) {
            if (portfolio[j].driver_good_id != good_id) continue;
            used = saturating_add(used, saturating_mul(
                portfolio[j].plan.allocated_count,
                portfolio[j].driver_output_per_building,
                _saturation_count), _saturation_count);
        }
        return used;
    };
    auto previously_allocated_resource = [&](int32_t resource_id) {
        int64_t used = 0;
        for (int32_t j = 0; j < portfolio_size; ++j) {
            if (portfolio[j].plan.allocated_count <= 0) continue;
            const BuildingType &allocated_type =
                _building_types[portfolio[j].plan.type_id];
            for (int32_t edge = 0;
                 edge < allocated_type.resource_count; ++edge) {
                const ResourceAmount &item = _building_resources[
                    allocated_type.resource_begin + edge];
                if ((item.mode != 0 && item.mode != 1) ||
                    item.resource_id != resource_id) continue;
                const int64_t effective_quantity =
                    effective_resource_use_quantity(
                        cell, item.resource_id, item.quantity,
                        _saturation_count);
                used = saturating_add(used, saturating_mul(
                    portfolio[j].plan.allocated_count, effective_quantity,
                    _saturation_count), _saturation_count);
            }
        }
        return used;
    };
    auto previously_allocated_catchup_jobs = [&]() {
        int64_t used = 0;
        for (int32_t j = 0; j < portfolio_size; ++j) {
            used = saturating_add(used, saturating_mul(
                portfolio[j].plan.allocated_count,
                portfolio[j].jobs_per_building, _saturation_count),
                _saturation_count);
        }
        return used;
    };
    const int32_t investment_cost_factor = country >= 0 &&
            country < static_cast<int32_t>(
                _epoch_country_construction_cost_factor_q16.size())
        ? _epoch_country_construction_cost_factor_q16[country] : Q16_ONE;
    auto reserved_material_adjustment = [&]() {
        std::vector<int64_t> adjustment(_good_ids.size(), 0);
        for (int32_t j = 0; j < portfolio_size; ++j) {
            if (portfolio[j].plan.allocated_count <= 0) continue;
            ConstructionMaterialPlan reserved_plan;
            if (!plan_construction_materials(
                    cell, portfolio[j].plan.type_id, portfolio[j].plan.allocated_count,
                    investment_cost_factor, reserved_plan, &adjustment)) {
                adjustment.clear();
                return adjustment;
            }
            for (size_t item = 0; item < reserved_plan.good_ids.size(); ++item) {
                const int32_t good = reserved_plan.good_ids[item];
                if (good >= 0 && good < static_cast<int32_t>(adjustment.size())) {
                    adjustment[good] = saturating_sub(
                        adjustment[good], reserved_plan.quantities[item],
                        _saturation_count);
                }
            }
        }
        return adjustment;
    };
    auto additional_capacity = [&](int32_t index) {
        Candidate &candidate = portfolio[index];
        const BuildingType &type = _building_types[candidate.plan.type_id];
        int64_t cap = std::max<int64_t>(
            0, candidate.desired_count - candidate.plan.allocated_count);
        cap = std::min<int64_t>(cap, std::max<int64_t>(
            0, candidate.plan.max_batch_count - candidate.plan.allocated_count));
        if (candidate.plan.request.reason ==
                INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP) {
            const int64_t remaining_jobs = std::max<int64_t>(
                0, employment_gap - previously_allocated_catchup_jobs());
            if (remaining_jobs <= 0) return int64_t{0};
            const int64_t jobs_per_building = std::max<int64_t>(
                1, candidate.jobs_per_building);
            cap = std::min<int64_t>(cap,
                (remaining_jobs + jobs_per_building - 1) /
                    jobs_per_building);
        }
        if (cap <= 0) return int64_t{0};
        const int64_t owner_slots = std::max<int64_t>(
            1, type.owner_slots_per_building);
        // Hard staffing ceiling: never schedule more owner lots than the
        // live population can fill after existing + pending + already
        // allocated lots. Willing-sponsor math alone still allowed
        // survival-driven empty shells to outrun a 20-person cell.
        // Profession-transition sponsors who already hold an owner seat
        // are a reallocation: they remain inside committed_owner_slots and
        // must not be blocked when spare unemployed headcount is ~0.
        if (!candidate.reallocates_owner_seat) {
            int64_t committed_owner_slots = 0;
            for (const auto &entry : _investment_existing_by_cell_type) {
                if (static_cast<int32_t>(entry.first >> 32) != cell) continue;
                committed_owner_slots = saturating_add(committed_owner_slots,
                    std::max<int64_t>(0, entry.second.owner_required),
                    _saturation_count);
            }
            for (const auto &entry : _investment_pending_by_cell_type) {
                if (static_cast<int32_t>(entry.first >> 32) != cell) continue;
                const int32_t pending_type = static_cast<int32_t>(
                    entry.first & 0xffffffffu);
                if (pending_type < 0 || pending_type >= static_cast<int32_t>(
                        _building_types.size())) continue;
                committed_owner_slots = saturating_add(committed_owner_slots,
                    saturating_mul(std::max<int64_t>(0, entry.second),
                        std::max<int64_t>(1, _building_types[pending_type]
                            .owner_slots_per_building),
                        _saturation_count),
                    _saturation_count);
            }
            for (int32_t j = 0; j < portfolio_size; ++j) {
                if (portfolio[j].plan.allocated_count <= 0) continue;
                const BuildingType &allocated_type =
                    _building_types[portfolio[j].plan.type_id];
                committed_owner_slots = saturating_add(committed_owner_slots,
                    saturating_mul(portfolio[j].plan.allocated_count,
                        std::max<int64_t>(1,
                            allocated_type.owner_slots_per_building),
                        _saturation_count),
                    _saturation_count);
            }
            const int64_t staffing_cap = std::max<int64_t>(0,
                cell_population - committed_owner_slots) / owner_slots;
            if (staffing_cap < cap)
                ++_building_investment_owner_population_limited;
            cap = std::min(cap, staffing_cap);
            if (cap <= 0) return int64_t{0};
        }
        const int64_t owner_remaining = std::max<int64_t>(
            0, candidate.willing_population -
                previously_allocated_owner_population(candidate.plan.sponsor,
                    candidate.plan.sponsor_family_handle));
        const int64_t owner_cap = owner_remaining / owner_slots;
        if (owner_cap < cap) ++_building_investment_owner_population_limited;
        cap = std::min(cap, owner_cap);
        const int64_t capital_remaining = std::max<int64_t>(
            0, candidate.transferable_capital -
                previously_allocated_capital(candidate.plan.sponsor,
                    candidate.plan.sponsor_family_handle));
        const int64_t capital_cap = candidate.plan.funding_capital > 0
            ? capital_remaining / candidate.plan.funding_capital
            : cap;
        if (capital_cap < cap) ++_building_investment_capital_limited;
        cap = std::min(cap, capital_cap);
        if (candidate.plan.uses_merchant_credit &&
            candidate.plan.merchant_credit > 0) {
            const int64_t credit_cap = std::max<int64_t>(
                0, available_credit - previously_allocated_credit()) /
                candidate.plan.merchant_credit;
            if (credit_cap < cap) ++_building_investment_capital_limited;
            cap = std::min(cap, credit_cap);
        }
        const std::vector<int64_t> adjustment =
            reserved_material_adjustment();
        if (adjustment.empty() && !_good_ids.empty()) {
            ++_building_investment_material_limited;
            return int64_t{0};
        }
        int64_t material_lo = 0;
        int64_t material_hi = cap;
        // 建材凑得齐还不够：同格其它类型先占走便宜的首选材料后，剩下的
        // 替代品会把单价推高，重算出的这批建材总价必须仍在候选自己冻结
        // 的资金包络（自筹 + 商人信贷）之内，否则批量在这里就要收窄。
        const int64_t funded_per_building = saturating_add(
            candidate.plan.funding_capital, candidate.plan.merchant_credit,
            _saturation_count);
        bool cost_envelope_limited = false;
        while (material_lo < material_hi) {
            const int64_t mid = material_lo +
                (material_hi - material_lo + 1) / 2;
            ConstructionMaterialPlan candidate_plan;
            if (!plan_construction_materials(cell, candidate.plan.type_id, mid,
                    investment_cost_factor, candidate_plan, &adjustment)) {
                material_hi = mid - 1;
                continue;
            }
            if (candidate_plan.total_cost > saturating_mul(
                    mid, funded_per_building, _saturation_count)) {
                cost_envelope_limited = true;
                material_hi = mid - 1;
                continue;
            }
            material_lo = mid;
        }
        if (material_lo < cap) {
            if (cost_envelope_limited) ++_building_investment_capital_limited;
            else {
                ++_building_investment_material_limited;
                record_investment_material_demand(cell, candidate.plan.type_id,
                    1, investment_cost_factor);
            }
        }
        cap = std::min(cap, material_lo);
        for (int32_t edge = 0; edge < type.resource_count; ++edge) {
            const ResourceAmount &item = _building_resources[
                type.resource_begin + edge];
            if (item.quantity <= 0) continue;
            const size_t resource_idx = static_cast<size_t>(
                item.resource_id) * _cell_count.get() + cell;
            const int64_t committed =
                investment_resource_committed(resource_idx);
            const int64_t effective_quantity = std::max<int64_t>(1,
                effective_resource_use_quantity(
                    cell, item.resource_id, item.quantity,
                    _saturation_count));
            int64_t resource_cap = 0;
            if (item.mode == 1) {
                const int64_t available =
                    available_resource_amount(item, cell);
                resource_cap = std::max<int64_t>(0,
                    available - committed -
                    previously_allocated_resource(item.resource_id)) /
                    effective_quantity;
            } else if (item.mode == 0 &&
                       _resource_safe_harvest_q16.get() > 0) {
                int64_t daily_budget = 0;
                if (resource_is_renewable(item.resource_id)) {
                    daily_budget = renewable_safe_harvest(
                        item.resource_id, cell);
                } else if (resource_idx <
                           resource_remaining_lanes().size()) {
                    daily_budget = std::max<int64_t>(0,
                        resource_remaining_lanes()[resource_idx]) /
                        std::max<int64_t>(1, _resource_min_horizon_days.get());
                }
                resource_cap = std::max<int64_t>(0,
                    daily_budget - committed -
                    previously_allocated_resource(item.resource_id)) /
                    effective_quantity;
            } else {
                continue;
            }
            cap = std::min(cap, resource_cap);
        }
        if (candidate.driver_output_per_building > 0) {
            const int64_t target_gap = mul_div_sat(
                std::max<int64_t>(0, candidate.driver_deficit),
                _investment_gap_fill_share_q16.get(), Q16_ONE,
                _saturation_count);
            const int64_t remaining_gap = std::max<int64_t>(
                0, target_gap - previously_allocated_driver(
                    candidate.driver_good_id));
            const int64_t demand_cap = remaining_gap > 0
                ? std::max<int64_t>(1, saturating_add(
                    remaining_gap,
                    candidate.driver_output_per_building - 1,
                    _saturation_count) /
                    candidate.driver_output_per_building)
                : 0;
            if (demand_cap < cap) ++_building_investment_demand_limited;
            cap = std::min(cap, demand_cap);
        }
        return std::max<int64_t>(0, cap);
    };

    // First seed distinct industries, then use four fixed water-fill
    // rounds. Work is bounded by the portfolio width, never by build count.
    portfolio_population_changed = false;
    for (int32_t i = 0; i < portfolio_size; ++i) {
        if (portfolio[i].plan.request.reason ==
                INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP &&
            previously_allocated_catchup_jobs() >= employment_gap) break;
        if (additional_capacity(i) > 0)
            portfolio[i].plan.allocated_count = 1;
    }
    for (int32_t round = 0; round < 4; ++round) {
        int64_t weight_sum = 0;
        int64_t remaining_sum = 0;
        std::array<int64_t, 4> caps{};
        for (int32_t i = 0; i < portfolio_size; ++i) {
            caps[i] = additional_capacity(i);
            if (caps[i] <= 0) continue;
            weight_sum = saturating_add(weight_sum,
                std::max<int64_t>(1, portfolio[i].score_q16),
                _saturation_count);
            remaining_sum = saturating_add(
                remaining_sum, caps[i], _saturation_count);
        }
        if (weight_sum <= 0 || remaining_sum <= 0) break;
        const int64_t round_budget = saturating_add(
            remaining_sum, 3 - round, _saturation_count) / (4 - round);
        for (int32_t i = 0; i < portfolio_size; ++i) {
            if (caps[i] <= 0) continue;
            int64_t add = mul_div_sat(
                round_budget, std::max<int64_t>(
                    1, portfolio[i].score_q16),
                weight_sum, _saturation_count);
            if (add <= 0) add = 1;
            add = std::min(add, additional_capacity(i));
            portfolio[i].plan.allocated_count = saturating_add(
                portfolio[i].plan.allocated_count, add, _saturation_count);
        }
    }

    active_types = 0;
    for (int32_t i = 0; i < portfolio_size; ++i)
        if (portfolio[i].plan.allocated_count > 0) ++active_types;
    if (active_types >= 2 &&
        _investment_max_type_owner_share_q16.get() < Q16_ONE) {
        for (int32_t pass = 0; pass < 4; ++pass) {
            bool changed = false;
            int64_t total_owner_slots = 0;
            for (int32_t i = 0; i < portfolio_size; ++i) {
                total_owner_slots = saturating_add(total_owner_slots,
                    saturating_mul(portfolio[i].plan.allocated_count,
                        std::max<int64_t>(1, _building_types[
                            portfolio[i].plan.type_id].owner_slots_per_building),
                        _saturation_count), _saturation_count);
            }
            for (int32_t i = 0; i < portfolio_size; ++i) {
                const int64_t owner_slots = std::max<int64_t>(
                    1, _building_types[
                        portfolio[i].plan.type_id].owner_slots_per_building);
                const int64_t own = saturating_mul(
                    portfolio[i].plan.allocated_count, owner_slots,
                    _saturation_count);
                const int64_t other = std::max<int64_t>(
                    0, total_owner_slots - own);
                const int64_t allowed_owner = mul_div_sat(
                    other, _investment_max_type_owner_share_q16.get(),
                    Q16_ONE - _investment_max_type_owner_share_q16.get(),
                    _saturation_count);
                const int64_t allowed_count = allowed_owner / owner_slots;
                if (portfolio[i].plan.allocated_count > allowed_count) {
                    portfolio[i].plan.allocated_count = allowed_count;
                    changed = true;
                }
            }
            if (!changed) break;
        }
        // A bounded second pass redistributes capacity released by the
        // concentration correction without reopening the candidate scan.
        for (int32_t pass = 0; pass < 4; ++pass) {
            bool changed = false;
            int64_t total_owner_slots = 0;
            for (int32_t i = 0; i < portfolio_size; ++i) {
                total_owner_slots = saturating_add(total_owner_slots,
                    saturating_mul(portfolio[i].plan.allocated_count,
                        std::max<int64_t>(1, _building_types[
                            portfolio[i].plan.type_id].owner_slots_per_building),
                        _saturation_count), _saturation_count);
            }
            for (int32_t i = 0; i < portfolio_size; ++i) {
                const int64_t owner_slots = std::max<int64_t>(
                    1, _building_types[
                        portfolio[i].plan.type_id].owner_slots_per_building);
                const int64_t own = saturating_mul(
                    portfolio[i].plan.allocated_count, owner_slots,
                    _saturation_count);
                const int64_t other = std::max<int64_t>(
                    0, total_owner_slots - own);
                const int64_t allowed_owner = mul_div_sat(
                    other, _investment_max_type_owner_share_q16.get(),
                    Q16_ONE - _investment_max_type_owner_share_q16.get(),
                    _saturation_count);
                const int64_t share_add_cap = std::max<int64_t>(
                    0, allowed_owner / owner_slots -
                        portfolio[i].plan.allocated_count);
                const int64_t add = std::min(
                    share_add_cap, additional_capacity(i));
                if (add <= 0) continue;
                portfolio[i].plan.allocated_count = saturating_add(
                    portfolio[i].plan.allocated_count, add,
                    _saturation_count);
                total_owner_slots = saturating_add(
                    total_owner_slots,
                    saturating_mul(add, owner_slots,
                        _saturation_count), _saturation_count);
                changed = true;
            }
            if (!changed) break;
        }
    }

}

NativeEconomyRuntime::InvestmentPreflightResult
NativeEconomyRuntime::investment_preflight_portfolio(
        BuildingInvestmentCellContext &ctx, std::string &error) {
    auto &cell = ctx.cell;
    auto &portfolio = ctx.portfolio;
    auto &portfolio_size = ctx.portfolio_size;
    auto &available_credit = ctx.available_credit;
    auto &active_types = ctx.active_types;
    auto &total_buildings = ctx.total_buildings;
    auto &total_owner_population = ctx.total_owner_population;
    auto &max_type_owner_population = ctx.max_type_owner_population;
    auto &commit_material_plans = ctx.commit_material_plans;
    auto &commit_cost_factor = ctx.commit_cost_factor;
    auto &commit_time_factor = ctx.commit_time_factor;
    auto &country = ctx.country;
    auto &market = ctx.market;
    using Candidate = BuildingInvestmentCellContext::Candidate;

    // Freeze the exact aggregate invoices for the whole portfolio before
    // moving population or money. The generic BUILD entry point reports a
    // business rejection by returning true without appending construction;
    // calling it after those mutations made any quote/commit mismatch fatal
    // and left the three conservation ledgers dirty. Planning against one
    // shared virtual stock vector also makes substitute selection identical
    // to the later stable portfolio commit order.
    commit_material_plans = {};
    std::vector<int64_t> commit_virtual_stock(_good_ids.size(), 0);
    for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
        commit_virtual_stock[static_cast<size_t>(good)] =
            std::max<int64_t>(0, market_store().stock[market_store().index(market, good)]);
    }
    std::vector<int64_t> trial_virtual_stock;
    commit_cost_factor = country >= 0 &&
            country < static_cast<int32_t>(
                _epoch_country_construction_cost_factor_q16.size())
        ? _epoch_country_construction_cost_factor_q16[country] : Q16_ONE;
    commit_time_factor = country >= 0 &&
            country < static_cast<int32_t>(
                _epoch_country_construction_time_factor_q16.size())
        ? _epoch_country_construction_time_factor_q16[country] : Q16_ONE;
    // 分配阶段逐类型看到的库存，和这里四种类型排队共用同一份库存之后
    // 剩下的材料并不相同：便宜的首选材料被前面的类型占走后，后面只能
    // 买更贵的替代品。用与下单完全一致的顺序和库存重算发票，超出资金
    // 包络就把批量收窄（可以收到零，视作这次不投），把矛盾解决在改动
    // 人口和资金之前，而不是留给下面的兜底断言。
    for (int32_t i = 0; i < portfolio_size; ++i) {
        Candidate &candidate = portfolio[i];
        if (candidate.plan.allocated_count <= 0) continue;
        if (!building_available(cell, candidate.plan.type_id, true) ||
            !evaluate_building_conditions(candidate.plan.type_id, cell) ||
            candidate.plan.owner_signature_id < 0 ||
            candidate.plan.owner_signature_id >= static_cast<int32_t>(
                _signatures.size()) ||
            _signatures[candidate.plan.owner_signature_id].profession_id !=
                _building_types[candidate.plan.type_id].owner_profession_id) {
            error = "building_investment_catalog_preflight_drift";
            return InvestmentPreflightResult::Fatal;
        }
        const int64_t funded_per_building = saturating_add(
            candidate.plan.funding_capital, candidate.plan.merchant_credit,
            _saturation_count);
        ConstructionMaterialPlan &plan = commit_material_plans[i];
        // 整批撑得住是常态，先按完整批量试一次并直接接管扣减后的库存，
        // 稳态下不额外增加一次 plan 调用。
        trial_virtual_stock = commit_virtual_stock;
        const bool full_batch_affordable = plan_construction_materials(
                cell, candidate.plan.type_id, candidate.plan.allocated_count,
                commit_cost_factor, plan, nullptr,
                &trial_virtual_stock) &&
            plan.total_cost <= saturating_mul(candidate.plan.allocated_count,
                funded_per_building, _saturation_count);
        if (full_batch_affordable) {
            commit_virtual_stock.swap(trial_virtual_stock);
        } else {
            // 单位造价随批量单调不减（每栋都在剩余库存里挑当时最便宜的
            // 材料），所以「撑得住」是单调谓词，可以二分。
            int64_t affordable_lo = 0;
            int64_t affordable_hi = candidate.plan.allocated_count - 1;
            while (affordable_lo < affordable_hi) {
                const int64_t mid = affordable_lo +
                    (affordable_hi - affordable_lo + 1) / 2;
                trial_virtual_stock = commit_virtual_stock;
                ConstructionMaterialPlan trial_plan;
                if (plan_construction_materials(cell, candidate.plan.type_id, mid,
                        commit_cost_factor, trial_plan, nullptr,
                        &trial_virtual_stock) &&
                    trial_plan.total_cost <= saturating_mul(
                        mid, funded_per_building, _saturation_count)) {
                    affordable_lo = mid;
                } else {
                    affordable_hi = mid - 1;
                }
            }
            _building_investment_cost_envelope_trimmed = saturating_add(
                _building_investment_cost_envelope_trimmed,
                candidate.plan.allocated_count - affordable_lo,
                _saturation_count);
            candidate.plan.allocated_count = affordable_lo;
            if (candidate.plan.allocated_count <= 0) {
                plan = ConstructionMaterialPlan{};
                continue;
            }
            if (!plan_construction_materials(
                    cell, candidate.plan.type_id, candidate.plan.allocated_count,
                    commit_cost_factor, plan, nullptr,
                    &commit_virtual_stock)) {
                error = "building_investment_material_preflight_drift";
                return InvestmentPreflightResult::Fatal;
            }
        }
        // 收窄之后这里只是兜底断言。真的还超说明另有未知漏洞，此时停在
        // fatal 比带着错账继续跑安全。
        if (plan.total_cost > saturating_mul(candidate.plan.allocated_count,
                funded_per_building, _saturation_count)) {
            error = "building_investment_cost_preflight_drift";
            return InvestmentPreflightResult::Fatal;
        }
    }

    std::array<const InvestmentCandidatePlan *, 4> funding_plans{};
    for (int32_t i = 0; i < portfolio_size; ++i)
        funding_plans[i] = &portfolio[i].plan;
    while (!investment_portfolio_funds_feasible(cell, funding_plans.data(),
            commit_material_plans.data(), portfolio_size)) {
        // 保留得分较高的前缀。只移除尾部项目，前面的冻结材料发票无需重算。
        int32_t last = portfolio_size - 1;
        while (last >= 0 && portfolio[last].plan.allocated_count <= 0) --last;
        if (last < 0) break;
        portfolio[last].plan.allocated_count = 0;
        ++_building_investment_capital_limited;
    }

    // 汇总和信贷额度都必须用收窄之后的批量重算，否则会按已经作废的旧
    // 栋数迁移人口、透支商人信贷。
    active_types = 0;
    total_buildings = 0;
    total_owner_population = 0;
    max_type_owner_population = 0;
    for (int32_t i = 0; i < portfolio_size; ++i) {
        Candidate &candidate = portfolio[i];
        if (candidate.plan.allocated_count <= 0) continue;
        ++active_types;
        total_buildings = saturating_add(
            total_buildings, candidate.plan.allocated_count,
            _saturation_count);
        const int64_t owner_population = saturating_mul(
            candidate.plan.allocated_count, std::max<int64_t>(
                1, _building_types[
                    candidate.plan.type_id].owner_slots_per_building),
            _saturation_count);
        total_owner_population = saturating_add(
            total_owner_population, owner_population, _saturation_count);
        max_type_owner_population = std::max(
            max_type_owner_population, owner_population);
    }
    if (active_types <= 0 || total_buildings <= 0)
        return InvestmentPreflightResult::Skip;
    int64_t portfolio_credit_required = 0;
    for (int32_t i = 0; i < portfolio_size; ++i) {
        if (!portfolio[i].plan.uses_merchant_credit ||
            portfolio[i].plan.allocated_count <= 0) continue;
        portfolio_credit_required = saturating_add(
            portfolio_credit_required,
            saturating_mul(portfolio[i].plan.allocated_count,
                portfolio[i].plan.merchant_credit, _saturation_count),
            _saturation_count);
    }
    if (portfolio_credit_required > available_credit) {
        error = "building_investment_startup_credit_overcommit";
        return InvestmentPreflightResult::Fatal;
    }

    return InvestmentPreflightResult::Ready;
}

bool NativeEconomyRuntime::investment_commit_portfolio(
        BuildingInvestmentCellContext &ctx, bool &population_changed,
        std::string &error) {
    auto &cell = ctx.cell;
    auto &portfolio = ctx.portfolio;
    auto &portfolio_size = ctx.portfolio_size;
    auto &portfolio_population_changed = ctx.portfolio_population_changed;
    auto &commit_material_plans = ctx.commit_material_plans;
    auto &commit_time_factor = ctx.commit_time_factor;
    auto &total_buildings = ctx.total_buildings;
    auto &total_owner_population = ctx.total_owner_population;
    auto &max_type_owner_population = ctx.max_type_owner_population;
    using Candidate = BuildingInvestmentCellContext::Candidate;

    for (int32_t i = 0; i < portfolio_size; ++i) {
        Candidate &candidate = portfolio[i];
        if (candidate.plan.allocated_count <= 0) continue;
        const int64_t source_funds_before =
            population_store().funds[candidate.plan.sponsor];
        const int64_t source_population_before =
            population_store().population[candidate.plan.sponsor];
        const int64_t source_handle =
            population_store().handle_for_slot(candidate.plan.sponsor);
        const bool profession_transition = static_cast<int32_t>(
            population_store().signature_id[candidate.plan.sponsor]) !=
            candidate.plan.owner_signature_id;
        const int32_t target_before_slot = find_cohort_slot(
            cell, candidate.plan.owner_signature_id);
        const int64_t target_funds_before = target_before_slot >= 0
            ? population_store().funds[target_before_slot] : 0;
        const int64_t target_population_before = target_before_slot >= 0
            ? population_store().population[target_before_slot] : 0;
        const int64_t owner_population = saturating_mul(
            candidate.plan.allocated_count, std::max<int64_t>(
                1, _building_types[
                    candidate.plan.type_id].owner_slots_per_building),
            _saturation_count);
        const int64_t required_capital = saturating_mul(
            candidate.plan.allocated_count, candidate.plan.funding_capital,
            _saturation_count);
        const int64_t merchant_credit = saturating_mul(
            candidate.plan.allocated_count, candidate.plan.merchant_credit,
            _saturation_count);
        bool source_drained = false;
        if (profession_transition && !move_cohort_population(
                candidate.plan.sponsor, cell, candidate.plan.owner_signature_id,
                owner_population, error, &source_drained,
                candidate.plan.sponsor_family_handle, true)) return false;
        // A full-cohort profession transition releases the sponsor slot by
        // design. Only a partial move that still drained the source is a
        // ledger fault (family/rounding residue path).
        if (source_drained && source_population_before > owner_population) {
            error = "building_investment_source_unexpectedly_drained";
            return false;
        }
        portfolio_population_changed =
            portfolio_population_changed || profession_transition;
        population_changed = population_changed || profession_transition;
        const int32_t owner_slot = profession_transition
            ? find_cohort_slot(cell, candidate.plan.owner_signature_id)
            : candidate.plan.sponsor;
        if (owner_slot < 0 || owner_slot >= static_cast<int32_t>(
                population_store().active.size()) ||
                population_store().active[owner_slot] == 0) {
            error = "building_investment_owner_transition_failed";
            return false;
        }
        if (profession_transition && source_drained) {
            // Sponsor slot is gone; every fund unit already moved with the
            // people. Surplus above required_capital stays on the owner.
            const int64_t carried =
                population_store().funds[owner_slot] - target_funds_before;
            if (carried < required_capital) {
                error = "building_investment_capital_preflight_drift";
                return false;
            }
            ++_building_owner_mobility;
            _building_investment_owner_population_moved = saturating_add(
                _building_investment_owner_population_moved,
                owner_population, _saturation_count);
            _building_investment_capital_transferred = saturating_add(
                _building_investment_capital_transferred,
                required_capital, _saturation_count);
        } else if (profession_transition) {
            // `carried` is the ledger delta on the destination. When the
            // destination already held a negative balance, that delta can
            // exceed the post-move liquid funds on the slot; only the
            // non-negative balance is refundable surplus.
            const int64_t owner_funds_after =
                population_store().funds[owner_slot];
            const int64_t carried = owner_funds_after - target_funds_before;
            int64_t correction = required_capital - carried;
            if (correction > 0 &&
                population_store().funds[candidate.plan.sponsor] < correction) {
                error = "building_investment_capital_preflight_drift";
                return false;
            }
            if (correction < 0) {
                const int64_t refund = -correction;
                const int64_t payable = std::min<int64_t>(
                    refund, std::max<int64_t>(0, owner_funds_after));
                // Unpayable surplus patched a destination deficit and
                // stays absorbed there; sponsor already lost it via the
                // move and will therefore pay more than required_capital.
                correction = -payable;
            }
            if (correction != 0) {
                touch_accounting_slot(candidate.plan.sponsor);
                touch_accounting_slot(owner_slot);
                population_store().funds.write_scalar(candidate.plan.sponsor,
                    saturating_sub(
                        population_store().funds[candidate.plan.sponsor],
                        correction, _saturation_count),
                    market_mutation_sink());
                population_store().funds.write_scalar(owner_slot,
                    saturating_add(
                        population_store().funds[owner_slot], correction,
                        _saturation_count),
                    market_mutation_sink());
                attribute_family_funds_delta(candidate.plan.sponsor,
                    candidate.plan.sponsor_family_handle, -correction);
                attribute_family_funds_delta(owner_slot,
                    candidate.plan.sponsor_family_handle, correction);
            }
            const int64_t sponsor_paid = source_funds_before -
                population_store().funds[candidate.plan.sponsor];
            // Must fund the building; overpay is allowed only when a
            // destination deficit absorbed unpayable refund surplus.
            if (sponsor_paid < required_capital ||
                (sponsor_paid != required_capital &&
                    correction == required_capital - carried)) {
                error = "building_investment_capital_transfer_drift";
                return false;
            }
            ++_building_owner_mobility;
            _building_investment_owner_population_moved = saturating_add(
                _building_investment_owner_population_moved,
                owner_population, _saturation_count);
            _building_investment_capital_transferred = saturating_add(
                _building_investment_capital_transferred,
                required_capital, _saturation_count);
        }
        if (profession_transition && trace_detail_for_cell(cell)) {
            const int64_t target_handle =
                population_store().handle_for_slot(owner_slot);
            std::vector<EventLeg> legs;
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                source_handle, -1, source_population_before,
                source_drained ? 0
                    : population_store().population[candidate.plan.sponsor]});
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                source_handle, -1, source_funds_before,
                source_drained ? 0
                    : population_store().funds[candidate.plan.sponsor]});
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                target_handle, -1, target_population_before,
                population_store().population[owner_slot]});
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                target_handle, -1, target_funds_before,
                population_store().funds[owner_slot]});
            trace_append(EVENT_STRUCTURAL_CHANGE,
                static_cast<int32_t>(Stage::BUILDING_COMMIT), cell,
                SUBJECT_COHORT, target_handle, candidate.plan.type_id, -1,
                required_capital, source_handle, target_handle,
                -(_epoch_id.get() * std::max<int64_t>(1, _cell_count.get()) +
                  cell * 4 + i + 1), &legs);
        }
        if (merchant_credit > 0) {
            if (debit_local_merchants(cell, merchant_credit,
                                      CASHFLOW_MERCHANT_BUSINESS,
                                      &_saturation_count) != merchant_credit) {
                error = "building_investment_startup_credit_preflight_drift";
                return false;
            }
            touch_accounting_slot(owner_slot);
            population_store().funds.write_scalar(owner_slot, saturating_add(
                population_store().funds[owner_slot], merchant_credit,
                _saturation_count), market_mutation_sink());
            attribute_family_funds_delta(owner_slot,
                candidate.plan.sponsor_family_handle, merchant_credit);
            trace_record_cashflow(cell, population_store().handle_for_slot(owner_slot),
                                  CASHFLOW_OTHER, merchant_credit, 0);
            _investment_outstanding_credit_by_cell[cell] = saturating_add(
                _investment_outstanding_credit_by_cell[cell],
                merchant_credit, _saturation_count);
            _merchant_credit_drawn = saturating_add(
                _merchant_credit_drawn, merchant_credit, _saturation_count);
            if (cell >= 0 && cell < static_cast<int32_t>(
                    _merchant_credit_drawn_by_cell.size())) {
                _merchant_credit_drawn_by_cell[cell] = saturating_add(
                    _merchant_credit_drawn_by_cell[cell], merchant_credit,
                    _saturation_count);
            }
        }
    }
    // Population slots are stable and later ordinals never revisit this
    // cell. Defer the global merchant CSR rebuild until the deterministic
    // slice commit below instead of rebuilding it once per changed cell.
    population_changed = population_changed ||
        portfolio_population_changed;

    int64_t started_types = 0;
    for (int32_t i = 0; i < portfolio_size; ++i) {
        Candidate &candidate = portfolio[i];
        if (candidate.plan.allocated_count <= 0) continue;
        const int32_t owner_slot = find_cohort_slot(
            cell, candidate.plan.owner_signature_id);
        if (owner_slot < 0) {
            error = "building_investment_owner_missing_after_portfolio";
            return false;
        }
        Command command;
        command.opcode = COMMAND_BUILD;
        command.effective_day = _current_day.get();
        command.sequence = -(_epoch_id.get() * std::max<int64_t>(
            1, _cell_count.get()) + cell * 4 + i + 1);
        command.target_handle =
            population_store().handle_for_slot(owner_slot);
        command.i32_0 = cell;
        command.i32_1 = candidate.plan.type_id;
        command.i64_0 = candidate.plan.allocated_count;
        const int64_t consumed_before = _construction_goods_consumed;
        const BuildingType &type = _building_types[candidate.plan.type_id];
        const int32_t effective_construction_days =
            type.construction_days <= 0 ? 0 : std::max<int32_t>(1,
                static_cast<int32_t>(mul_div_sat(
                    type.construction_days, commit_time_factor,
                    Q16_ONE, _saturation_count)));
        _construction_sponsor_override = candidate.plan.sponsor_family_handle;
        _construction_sponsor_override_set = true;
        const bool built = commit_preflighted_build_command(
            command, owner_slot, commit_material_plans[i],
            effective_construction_days, 0, 0, 0, error);
        _construction_sponsor_override_set = false;
        if (!built) return false;
        if (candidate.plan.merchant_credit > 0) {
            auto pending =
                pending_construction_at(pending_construction_count() - 1);
            const int64_t credit = saturating_mul(
                candidate.plan.allocated_count, candidate.plan.merchant_credit,
                _saturation_count);
            pending.merchant_debt_principal = saturating_add(
                pending.merchant_debt_principal, credit,
                _saturation_count);
            const int64_t premium = saturating_add(
                saturating_mul(credit, _merchant_credit_premium_q16.get(),
                               _saturation_count),
                Q16_ONE - 1, _saturation_count) / Q16_ONE;
            pending.merchant_debt_premium = saturating_add(
                pending.merchant_debt_premium, premium,
                _saturation_count);
            pending.merchant_debt_term_cycles_left = static_cast<uint16_t>(
                _merchant_credit_term_cycles.get());
        }
        pending_construction_at(pending_construction_count() - 1)
            .sponsor_family_handle = candidate.plan.sponsor_family_handle;
        const int64_t consumed =
            _construction_goods_consumed - consumed_before;
        _publish_accum.goods_stock = saturating_sub(
            _publish_accum.goods_stock, consumed, _saturation_count);
        ++_building_investments_started;
        consume_remote_startup_demand(
            cell, candidate.driver_good_id,
            saturating_mul(candidate.driver_output_per_building,
                candidate.plan.allocated_count, _saturation_count));
        if (candidate.startup_driven) {
            _startup_demand_buildings_started = saturating_add(
                _startup_demand_buildings_started,
                candidate.plan.allocated_count, _saturation_count);
        }
        if (candidate.displaces_incumbents)
            ++_building_investment_displacement_starts;
        ++started_types;
        const uint64_t pending_key = BuildingInvestmentCellContext::cell_key(cell, candidate.plan.type_id);
        _investment_pending_by_cell_type[pending_key] = saturating_add(
            _investment_pending_by_cell_type[pending_key],
            candidate.plan.allocated_count, _saturation_count);
    }
    ++_building_investment_portfolios_started;
    _building_investment_types_started = saturating_add(
        _building_investment_types_started, started_types,
        _saturation_count);
    _building_investment_buildings_started = saturating_add(
        _building_investment_buildings_started, total_buildings,
        _saturation_count);
    _building_investment_jobs_started = saturating_add(
        _building_investment_jobs_started, total_owner_population,
        _saturation_count);
    if (total_owner_population > 0) {
        _building_investment_max_type_owner_share_q16 = std::max(
            _building_investment_max_type_owner_share_q16,
            mul_div_sat(max_type_owner_population, Q16_ONE,
                total_owner_population, _saturation_count));
    }
    return true;
}

} // namespace pk
