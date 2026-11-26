#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
#include "economy_cohort_move_cash.h"
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
        struct Claim {
            uint64_t handle;
            int64_t people;
            int64_t cash;
        };

        int32_t signature;
        int32_t slot;
        int64_t population;
        int64_t funds;
        bool families_loaded = false;
        std::vector<Claim> families{};

        Claim *family(uint64_t handle) {
            for (auto &family : families)
                if (family.handle == handle) return &family;
            return nullptr;
        }
    };
    std::vector<Account> accounts;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        accounts.push_back({static_cast<int32_t>(population_store().signature_id[slot]), slot,
            population_store().population[slot], population_store().funds[slot]});
    });
    const auto account_index = [&](int32_t signature) {
        for (size_t i = 0; i < accounts.size(); ++i)
            if (accounts[i].signature == signature) return i;
        accounts.push_back({signature, -1, 0, 0});
        return accounts.size() - 1;
    };
    std::vector<size_t> merchants;
    for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
        merchants.push_back(account_index(static_cast<int32_t>(
            population_store().signature_id[_merchant_slots[k]])));
    }
    int64_t sat = 0;
    std::vector<int32_t> family_edges;
    const auto load_families = [&](Account &account) {
        if (account.families_loaded) return;
        account.families_loaded = true;
        if (account.slot < 0) return;
        for_each_cohort_cash_claim(account.slot, family_edges,
            [&](uint64_t handle, int64_t people, int64_t cash) {
                account.families.push_back({handle, people, cash});
            });
    };
    const auto attribute_cash = [&](Account &account, uint64_t family_handle, int64_t delta) {
        if (family_handle == 0 || delta == 0) return;
        load_families(account);
        if (auto *family = account.family(family_handle)) {
            family->cash = std::clamp<int64_t>(saturating_add(family->cash, delta, sat),
                0, std::max<int64_t>(0, account.funds));
        }
    };
    // 按实际的两阶段顺序预演：全部迁人/注资/放贷之后，才逐张支付建材。
    // 商人自建款和已注入业主的建造款，不能再次当作另一项目的可用现金。
    for (int32_t i = 0; i < count; ++i) {
        const auto &plan = *plans[i];
        if (plan.allocated_count <= 0) continue;
        const size_t source = account_index(static_cast<int32_t>(
            population_store().signature_id[plan.sponsor]));
        const size_t owner = account_index(plan.owner_signature_id);
        const int64_t required_capital = saturating_mul(
            plan.allocated_count, plan.funding_capital, sat);
        if (source != owner) {
            const int64_t people = saturating_mul(plan.allocated_count,
                std::max<int64_t>(1, _building_types[plan.type_id].owner_slots_per_building), sat);
            Account &from = accounts[source];
            Account &to = accounts[owner];
            // Keep the source slot alive so later plans and the frozen merchant
            // list still refer to the same cohort.
            if (people >= from.population || from.funds < required_capital || to.funds < 0)
                return false;
            load_families(from);
            // The cash carried by the movers is resolved by the same rule the
            // commit writes with (economy_cohort_move_cash.h cohort_move_cash).
            // Keeping one definition is what makes this replay a valid
            // certificate for the later write; a second formula here is how a
            // funded prefix used to become a building_investment_capital_
            // preflight_drift stop after the population had already moved.
            int64_t family_people = 0;
            int64_t family_claim = 0;
            for (const auto &family : from.families) {
                family_people = saturating_add(family_people,
                    std::max<int64_t>(0, family.people), sat);
                family_claim = saturating_add(family_claim,
                    std::max<int64_t>(0, family.cash), sat);
            }
            const bool family_plan_valid = !from.families.empty();
            int64_t moved_claim = 0;
            int64_t anonymous_moved = 0;
            if (plan.sponsor_family_handle != 0) {
                auto *family = from.family(plan.sponsor_family_handle);
                // A prior leg may have moved the selected people. Reject this
                // prefix if the live move would fall back to other parties.
                if (family == nullptr || family->people < people) return false;
                moved_claim = std::min(family_move_cash_share(
                    std::max<int64_t>(0, family->cash), people, family->people,
                    sat, mul_div_sat), from.funds);
                family->people -= people;
                family->cash -= moved_claim;
                load_families(to);
                if (auto *destination_family = to.family(plan.sponsor_family_handle)) {
                    destination_family->people = saturating_add(destination_family->people, people, sat);
                    destination_family->cash = saturating_add(destination_family->cash, moved_claim, sat);
                } else {
                    to.families.push_back({plan.sponsor_family_handle, people, moved_claim});
                }
            } else {
                const int64_t anonymous_people = std::max<int64_t>(0, from.population - family_people);
                if (anonymous_people < people) return false;
                anonymous_moved = people;
            }
            const int64_t carried = cohort_move_cash(from.funds, from.population, people,
                family_plan_valid, moved_claim, family_claim, anonymous_moved,
                std::max<int64_t>(0, from.population - family_people), sat, mul_div_sat);
            const int64_t capital = std::max(required_capital, carried);
            const int64_t top_up = capital - carried;
            from.population -= people;
            to.population = saturating_add(to.population, people, sat);
            from.funds -= capital;
            to.funds = saturating_add(to.funds, capital, sat);
            attribute_cash(from, plan.sponsor_family_handle, -top_up);
            attribute_cash(to, plan.sponsor_family_handle, top_up);
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
        attribute_cash(accounts[owner], plan.sponsor_family_handle, credit);
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

} // namespace pk
