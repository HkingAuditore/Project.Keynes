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

void NativeEconomyRuntime::record_investment_fatal_row(int32_t cell,
        const InvestmentCandidatePlan &plan, int32_t portfolio_index,
        int32_t portfolio_size, int32_t branch, int64_t owner_population,
        int64_t required_capital, int64_t carried, int64_t correction,
        int32_t owner_slot, int64_t owner_funds, bool source_drained) {
    InvestmentFatalRow &row = _investment_fatal_row;
    row = InvestmentFatalRow{};
    row.valid = true;
    row.branch = branch;
    row.cell = cell;
    row.type_id = plan.type_id;
    row.portfolio_index = portfolio_index;
    row.portfolio_size = portfolio_size;
    row.allocated_count = plan.allocated_count;
    row.owner_population = owner_population;
    row.funding_capital = plan.funding_capital;
    row.merchant_credit = plan.merchant_credit;
    row.required_capital = required_capital;
    row.carried = carried;
    row.correction = correction;
    row.sponsor_slot = plan.sponsor;
    row.sponsor_family_handle = plan.sponsor_family_handle;
    if (plan.sponsor >= 0 &&
        plan.sponsor < static_cast<int32_t>(population_store().active.size())) {
        row.sponsor_handle = static_cast<int64_t>(
            population_store().handle_for_slot(plan.sponsor));
        row.sponsor_population = population_store().population[plan.sponsor];
        row.sponsor_funds = population_store().funds[plan.sponsor];
    }
    row.owner_slot = owner_slot;
    row.owner_funds = owner_funds;
    row.source_drained = source_drained;
}

bool NativeEconomyRuntime::investment_commit_portfolio(
        BuildingInvestmentCellContext &ctx, bool &population_changed,
        std::string &error) {
    // Per-cell trace for post-mortem diagnosis (re-initialised for every cell so
    // a fatal names the cell that actually failed).
    _investment_leg_trace.clear();
    auto &cell = ctx.cell;
    auto &portfolio = ctx.portfolio;
    auto &portfolio_size = ctx.portfolio_size;
    auto &portfolio_population_changed = ctx.portfolio_population_changed;
    auto &commit_material_plans = ctx.commit_material_plans;
    auto &commit_time_factor = ctx.commit_time_factor;
    auto &active_types = ctx.active_types;
    auto &total_buildings = ctx.total_buildings;
    auto &total_owner_population = ctx.total_owner_population;
    auto &max_type_owner_population = ctx.max_type_owner_population;
    using Candidate = BuildingInvestmentCellContext::Candidate;

    for (int32_t i = 0; i < portfolio_size; ++i) {
        Candidate &candidate = portfolio[i];
        if (candidate.plan.allocated_count <= 0) continue;
        // investment_portfolio_funds_feasible() replays the whole cell on a
        // snapshot taken before this loop. The live slot can already be short
        // by the time this leg runs: an earlier leg that emptied the sponsor
        // cohort leaves a released slot whose signature is retained, and
        // move_cohort_population() then returns success without moving a unit
        // (economy_runtime.cpp:1675-1677), so the backstop assertions below
        // would fire after the epoch was already half-written. Re-verify the
        // exact transfer this write is about to perform and trim the candidate
        // -- the documented prefix trim -- instead of writing then faulting.
        // See docs/architecture/feature-guides.md §自动建筑投资的资金预检.
        const bool sponsor_in_range = candidate.plan.sponsor >= 0 &&
            candidate.plan.sponsor < static_cast<int32_t>(
                population_store().active.size());
        const bool gate_type_in_range = candidate.plan.type_id >= 0 &&
            candidate.plan.type_id < static_cast<int32_t>(_building_types.size());
        if (sponsor_in_range && gate_type_in_range) {
            const bool planned_transition = static_cast<int32_t>(
                population_store().signature_id[candidate.plan.sponsor]) !=
                candidate.plan.owner_signature_id;
            const int64_t planned_capital = saturating_mul(
                candidate.plan.allocated_count, candidate.plan.funding_capital,
                _saturation_count);
            if (planned_transition) {
                const int64_t planned_owner_population = saturating_mul(
                    candidate.plan.allocated_count, std::max<int64_t>(1,
                        _building_types[candidate.plan.type_id].owner_slots_per_building),
                    _saturation_count);
                // The dry run keeps _family_owner_seats_guarded exact: it is a
                // per-epoch diagnostic counter, not a transfer side effect.
                const int64_t guarded_before = _family_owner_seats_guarded;
                bool planned_drain = false;
                const int64_t planned_carried = plan_cohort_move_cash(
                    candidate.plan.sponsor, cell, planned_owner_population,
                    candidate.plan.sponsor_family_handle, true, &planned_drain);
                _family_owner_seats_guarded = guarded_before;
                // Exact per-branch mirror of the two backstops below.
                //  * Drained source (:971-978) fires iff carried < required.
                //    A drain carries every fund unit, so carried equals the
                //    sponsor's whole balance and the condition is the same.
                //  * Normal move (:997-1003) reads funds[sponsor] AFTER
                //    move_cohort_population() already subtracted the carried
                //    cash, so its check
                //        (funds_before - carried) < (required - carried)
                //    cancels `carried` and reduces to
                //        funds_before < required.
                // Gating on the narrower `funds_before < required - carried`
                // would leave the window required - carried <= funds_before <
                // required unfunded-here-but-fatal-at-the-backstop, i.e. the
                // very drift this gate exists to remove.
                const bool would_drift = planned_drain
                    ? planned_carried < planned_capital
                    : planned_carried < planned_capital &&
                        population_store().funds[candidate.plan.sponsor] < planned_capital;
                if (would_drift) {
                    candidate.plan.allocated_count = 0;
                    ++_building_investment_capital_limited;
                    continue;
                }
            }
        }
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
        // Trace this leg as it executes: a later drift backstop can then be
        // diagnosed from one log line + this trace, without the player's save.
        if (_investment_leg_trace.size() < 16) {
            InvestmentLegTrace trace;
            trace.candidate = i;
            trace.type_id = candidate.plan.type_id;
            trace.allocated = candidate.plan.allocated_count;
            trace.transition = profession_transition;
            trace.sponsor_slot = candidate.plan.sponsor;
            trace.owner_population = owner_population;
            trace.required_capital = required_capital;
            trace.source_population_before = source_population_before;
            trace.source_funds_before = source_funds_before;
            trace.credit = merchant_credit;
            _investment_leg_trace.push_back(trace);
        }
        const auto trace_leg = [&]() -> InvestmentLegTrace * {
            return _investment_leg_trace.empty() ? nullptr : &_investment_leg_trace.back();
        };
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
            if (auto *leg = trace_leg()) {
                leg->owner_slot = owner_slot;
                leg->carried = carried;
                leg->source_drained = true;
                leg->owner_funds_after_move = population_store().funds[owner_slot];
            }
            if (carried < required_capital) {
                record_investment_fatal_row(cell, candidate.plan, i,
                    portfolio_size, 1, owner_population, required_capital,
                    carried, required_capital - carried, owner_slot,
                    population_store().funds[owner_slot], source_drained);
                error = "building_investment_capital_preflight_drift";
                return false;
            }
            ++_building_owner_mobility;
            _building_investment_owner_population_moved = saturating_add(
                _building_investment_owner_population_moved,
                owner_population, _saturation_count);
            _building_investment_capital_transferred = saturating_add(
                _building_investment_capital_transferred,
                carried, _saturation_count);
        } else if (profession_transition) {
            // Money follows people. `carried` is the wealth the movers bring
            // from their old cohort (their per-capita/family claim). It is a
            // minimum funding input, not a cap: any surplus above
            // required_capital stays with the new owner cohort instead of
            // being refunded to the profession they left. When the movers'
            // own claim is short, the sponsor group (family or anonymous
            // remainder) pools the difference, exactly as it was selected in
            // find_entrepreneur_source.
            const int64_t owner_funds_after =
                population_store().funds[owner_slot];
            const int64_t carried = owner_funds_after - target_funds_before;
            const int64_t correction = std::max<int64_t>(
                0, required_capital - carried);
            if (auto *leg = trace_leg()) {
                leg->owner_slot = owner_slot;
                leg->carried = carried;
                leg->correction = correction;
                leg->owner_funds_after_move = owner_funds_after;
            }
            if (correction > 0 &&
                population_store().funds[candidate.plan.sponsor] < correction) {
                record_investment_fatal_row(cell, candidate.plan, i,
                    portfolio_size, 2, owner_population, required_capital,
                    carried, correction, owner_slot, owner_funds_after,
                    source_drained);
                error = "building_investment_capital_preflight_drift";
                return false;
            }
            if (correction > 0) {
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
            // The building must receive its minimum capital. Overpay is the
            // movers' own carried wealth and is deliberately not refunded.
            if (sponsor_paid < required_capital) {
                error = "building_investment_capital_transfer_drift";
                return false;
            }
            ++_building_owner_mobility;
            _building_investment_owner_population_moved = saturating_add(
                _building_investment_owner_population_moved,
                owner_population, _saturation_count);
            _building_investment_capital_transferred = saturating_add(
                _building_investment_capital_transferred,
                sponsor_paid, _saturation_count);
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
        if (auto *leg = trace_leg()) {
            leg->owner_slot = owner_slot;
            if (!profession_transition)
                leg->owner_funds_after_move = population_store().funds[owner_slot];
            leg->owner_funds_after_credit = population_store().funds[owner_slot];
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
        for (auto &leg : _investment_leg_trace) {
            if (leg.candidate != i) continue;
            leg.material_cost = commit_material_plans[i].total_cost;
            leg.owner_funds_at_material = population_store().funds[owner_slot];
            break;
        }
        const BuildingType &type = _building_types[candidate.plan.type_id];
        const int32_t effective_construction_days =
            type.construction_days <= 0 ? 0 : std::max<int32_t>(1,
                static_cast<int32_t>(mul_div_sat(
                    type.construction_days, commit_time_factor,
                    Q16_ONE, _saturation_count)));
        _construction_sponsor_override = candidate.plan.sponsor_family_handle;
        _construction_sponsor_override_set = true;
        // Lets a materials drift name the leg order, not just the cell.
        _construction_fatal_portfolio_index = i;
        _construction_fatal_portfolio_size = portfolio_size;
        const bool built = commit_preflighted_build_command(
            command, owner_slot, commit_material_plans[i],
            effective_construction_days, 0, 0, 0, error);
        _construction_fatal_portfolio_index = -1;
        _construction_fatal_portfolio_size = 0;
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
    // The gate above may have trimmed a candidate after the preflight already
    // summed it into these aggregates. Recompute them from the legs that were
    // actually committed so the day report never counts a trimmed building.
    active_types = 0;
    total_buildings = 0;
    total_owner_population = 0;
    max_type_owner_population = 0;
    for (int32_t i = 0; i < portfolio_size; ++i) {
        const Candidate &committed = portfolio[i];
        if (committed.plan.allocated_count <= 0) continue;
        ++active_types;
        total_buildings = saturating_add(total_buildings,
            committed.plan.allocated_count, _saturation_count);
        const int64_t owner_population = saturating_mul(
            committed.plan.allocated_count, std::max<int64_t>(1,
                _building_types[committed.plan.type_id].owner_slots_per_building),
            _saturation_count);
        total_owner_population = saturating_add(
            total_owner_population, owner_population, _saturation_count);
        max_type_owner_population = std::max(
            max_type_owner_population, owner_population);
    }
    if (active_types <= 0) {
        // Every leg was trimmed before writing: nothing started this cycle,
        // which is the same outcome the preflight Skip path produces.
        return true;
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
