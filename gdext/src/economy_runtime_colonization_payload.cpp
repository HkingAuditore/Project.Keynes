#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include <algorithm>
#include <chrono>
#include <functional>
#include <numeric>
#include <tuple>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
#include "economy_runtime_colonization_internal.h"

bool NativeEconomyRuntime::reserve_family_expedition_payload_slots(
        int32_t expedition, uint32_t begin, uint32_t end, bool stop_on_failure) {
    const uint64_t owner = family_expeditions_store().handle_for_index(expedition);
    bool reserved = true;
    for (uint32_t p = begin; p < end; ++p) {
        auto payload_write = family_expedition_payloads().edit_row(p, market_mutation_sink());
        FamilyExpeditionPayload &payload = payload_write[0];
        payload.reserved_slot = population_store().reserve_slot(
            family_expeditions_store().target_cell[expedition],
            static_cast<uint32_t>(payload.signature), owner);
        if (payload.reserved_slot < 0) {
            reserved = false;
            if (stop_on_failure) return false;
        }
    }
    return reserved;
}

void NativeEconomyRuntime::unwind_family_expedition_payload_extract(
        int32_t expedition) {
    if (expedition < 0 ||
        expedition >= static_cast<int32_t>(family_expeditions_store().active.size()) ||
        family_expeditions_store().active[expedition] == 0) return;
    const uint64_t family_handle = family_expeditions_store().family_handle[expedition];
    const uint64_t owner = family_expeditions_store().handle_for_index(expedition);
    const uint32_t begin = family_expeditions_store().payload_begin[expedition];
    uint32_t count = family_expeditions_store().payload_count[expedition];
    if (begin > family_expedition_payloads().size()) return;
    if (count == 0 && family_expedition_payloads().size() > begin)
        count = static_cast<uint32_t>(family_expedition_payloads().size() - begin);
    const uint32_t end = std::min<uint32_t>(
        begin + count, static_cast<uint32_t>(family_expedition_payloads().size()));
    uint32_t person_begin = static_cast<uint32_t>(
        family_expedition_person_handles().size());
    for (uint32_t p = begin; p < end; ++p) {
        auto payload_write = family_expedition_payloads().edit_row(p, market_mutation_sink());
        FamilyExpeditionPayload &payload = payload_write[0];
        population_store().release_reserved_slot(payload.reserved_slot, owner);
        payload.reserved_slot = -1;
        person_begin = std::min(person_begin, payload.person_begin);
        int32_t slot = -1;
        if (population_store().valid_handle(payload.source_cohort_handle, slot)) {
            audit_touch_population_lane(slot);
            touch_accounting_slot(slot);
            population_store().population.write_scalar(slot, population_store().population[slot] + (payload.people), market_mutation_sink());
            population_store().owner_employed.write_scalar(slot, saturating_add(
                population_store().owner_employed[slot],
                payload.owner_employed, _saturation_count), market_mutation_sink());
            population_store().employee_employed.write_scalar(slot, saturating_add(
                population_store().employee_employed[slot],
                payload.employee_employed, _saturation_count), market_mutation_sink());
            population_store().funds.write_scalar(slot, population_store().funds[slot] + (payload.funds), market_mutation_sink());
            population_store().epoch_income.write_scalar(slot, population_store().epoch_income[slot] + (payload.epoch_income), market_mutation_sink());
            population_store().epoch_expense.write_scalar(slot, population_store().epoch_expense[slot] + (payload.epoch_expense), market_mutation_sink());
            population_store().epoch_in_kind_income.write_scalar(slot, population_store().epoch_in_kind_income[slot] + (payload.epoch_in_kind_income), market_mutation_sink());
            population_store().income_ema.write_scalar(slot, population_store().income_ema[slot] + (payload.income_ema), market_mutation_sink());
            population_store().epoch_tax_paid.write_scalar(slot, population_store().epoch_tax_paid[slot] + (payload.epoch_tax_paid), market_mutation_sink());
            population_store().epoch_subsidy_received.write_scalar(slot, population_store().epoch_subsidy_received[slot] + (payload.epoch_subsidy_received), market_mutation_sink());
            population_store().income_baseline_ema.write_scalar(slot, population_store().income_baseline_ema[slot] + (payload.income_baseline_ema), market_mutation_sink());
            population_store().demography_residual.write_scalar(slot, population_store().demography_residual[slot] + (payload.demography_residual), market_mutation_sink());
            shift_family_ledger_basis(slot, payload.funds);
        }
        auto membership = std::find_if(family_memberships().begin(),
            family_memberships().end(), [&](const FamilyMembershipEdge &edge) {
                return edge.family_handle == family_handle &&
                    edge.cohort_handle == payload.source_cohort_handle;
            });
        // 随行平民从未离开家族边，回滚时也不能凭空造出一条成员边。
        if (payload.anonymous != 0) continue;
        if (membership == family_memberships().end()) {
            family_memberships().push_back({family_handle,
                payload.source_cohort_handle, payload.people, payload.cash_claim,
                payload.people, slot >= 0 ? family_ledger_basis_for_slot(slot)
                    : payload.funds, payload.owner_employed,
                payload.employee_employed});
        } else {
            auto membership_write = family_memberships().edit_row(membership - family_memberships().begin(), market_mutation_sink());
            auto &membership_row = membership_write[0];
            membership_row.people += payload.people;
            membership_row.cash_claim += payload.cash_claim;
            membership_row.owner_employed += payload.owner_employed;
            membership_row.employee_employed += payload.employee_employed;
            membership_row.population_basis += payload.people;
        }
        const uint32_t person_end = std::min<uint32_t>(
            payload.person_begin + payload.person_count,
            static_cast<uint32_t>(family_expedition_person_handles().size()));
        for (uint32_t i = payload.person_begin; i < person_end; ++i) {
            int32_t person = -1;
            if (persons_store().valid_handle(family_expedition_person_handles()[i],
                    person))
                persons_store().cohort_handle.write_scalar(person, payload.source_cohort_handle, market_mutation_sink());
        }
    }
    if (end > begin)
        family_expedition_payloads().resize(begin);
    if (person_begin < family_expedition_person_handles().size())
        family_expedition_person_handles().resize(person_begin);
    family_expeditions_store().payload_count.write_scalar(expedition, 0, market_mutation_sink());
    family_expeditions_store().population.write_scalar(expedition, 0, market_mutation_sink());
    family_expeditions_store().anonymous.write_scalar(expedition, 0, market_mutation_sink());
    _family_indices_dirty = true;
    _person_indices_dirty = true;
}

void NativeEconomyRuntime::clip_cell_employment_and_defer_reconcile(
        int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get()) return;
    // move_cohort_population leaves the source cohort's job lanes to its
    // caller, and the POD ledger export rejects owner + employee > population.
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int64_t population = std::max<int64_t>(0,
            population_store().population[slot]);
        const int64_t owner = std::clamp<int64_t>(
            population_store().owner_employed[slot], 0, population);
        const int64_t employee = std::clamp<int64_t>(
            population_store().employee_employed[slot], 0, population - owner);
        if (owner != population_store().owner_employed[slot])
            population_store().owner_employed.write_scalar(slot, owner,
                market_mutation_sink());
        if (employee != population_store().employee_employed[slot])
            population_store().employee_employed.write_scalar(slot, employee,
                market_mutation_sink());
    });
    // The clip keeps the ledger exportable; building fills still have to be
    // re-derived from the moved people, which only the structural reconcile
    // does. Inside an epoch the touched list reaches it before it is cleared.
    if (!_epoch_active) _deferred_population_reconcile_cells.push_back(cell);
}

bool NativeEconomyRuntime::extract_family_expedition_anonymous_lanes(
        int32_t expedition, std::string &error) {
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            family_expeditions_store().active.size()) ||
        family_expeditions_store().active[expedition] == 0) {
        error = "colonization_expedition_invalid";
        return false;
    }
    const int64_t requested = std::max<int64_t>(0,
        family_expeditions_store().anonymous[expedition]);
    if (requested <= 0) return true;
    const uint64_t family_handle =
        family_expeditions_store().family_handle[expedition];
    const int32_t source_cell = family_expeditions_store().source_cell[expedition];
    int32_t family = -1;
    if (!families_store().valid_handle(family_handle, family)) {
        error = "colonization_family_invalid";
        return false;
    }
    const int32_t ethnicity = families_store().origin_ethnicity[family];
    struct Candidate { int32_t slot; int64_t people; uint64_t stable; };
    std::vector<Candidate> candidates;
    // 家族载荷抽离会同时扣减 cohort 人口与成员边，匿名余量不变，因此这里
    // 看到的就是家族走后的无家族人口。
    population_store().for_each_in_cell(source_cell, [&](int32_t slot) {
        int64_t people = std::max<int64_t>(0,
            population_store().population[slot] - family_people_on_slot(slot));
        if (is_merchant_slot(slot)) people = std::max<int64_t>(0, people - 1);
        if (people <= 0) return;
        const int32_t signature = static_cast<int32_t>(
            population_store().signature_id[slot]);
        if (signature < 0 ||
            signature >= static_cast<int32_t>(_signatures.size())) return;
        // 军人不随行，与家族派遣同一规则。
        if (profession_is_state_service_only(_signatures[signature].profession_id))
            return;
        if (ethnicity >= 0 && _signatures[signature].ethnicity_id != ethnicity)
            return;
        candidates.push_back({slot, people,
            population_store().handle_for_slot(slot)});
    });
    std::sort(candidates.begin(), candidates.end(),
        [](const Candidate &a, const Candidate &b) {
            if (a.people != b.people) return a.people > b.people;
            return a.stable < b.stable;
        });
    int64_t remaining = requested;
    for (const Candidate &candidate : candidates) {
        if (remaining <= 0) break;
        const int64_t take = std::min(candidate.people, remaining);
        if (take <= 0) continue;
        const int32_t slot = candidate.slot;
        const int64_t source_population = std::max<int64_t>(1,
            population_store().population[slot]);
        FamilyExpeditionPayload payload;
        payload.anonymous = 1;
        payload.source_cohort_handle = population_store().handle_for_slot(slot);
        payload.signature = static_cast<int32_t>(
            population_store().signature_id[slot]);
        payload.people = take;
        payload.funds = mul_div_sat(population_store().funds[slot], take,
            source_population, _saturation_count);
        payload.epoch_income = mul_div_sat(population_store().epoch_income[slot],
            take, source_population, _saturation_count);
        payload.epoch_expense = mul_div_sat(population_store().epoch_expense[slot],
            take, source_population, _saturation_count);
        payload.epoch_in_kind_income = mul_div_sat(
            population_store().epoch_in_kind_income[slot], take,
            source_population, _saturation_count);
        payload.income_ema = mul_div_sat(population_store().income_ema[slot],
            take, source_population, _saturation_count);
        payload.epoch_tax_paid = mul_div_sat(population_store().epoch_tax_paid[slot],
            take, source_population, _saturation_count);
        payload.epoch_subsidy_received = mul_div_sat(
            population_store().epoch_subsidy_received[slot], take,
            source_population, _saturation_count);
        payload.income_baseline_ema = mul_div_sat(
            population_store().income_baseline_ema[slot], take,
            source_population, _saturation_count);
        payload.demography_residual = mul_div_sat(
            population_store().demography_residual[slot], take,
            source_population, _saturation_count);
        // 无家族人口不持有现金权益：资金按人口比例随行，落在目标格的匿名余款里。
        payload.cash_claim = 0;
        const int64_t source_owner = std::clamp<int64_t>(
            population_store().owner_employed[slot], 0, source_population);
        payload.owner_employed = std::min<int64_t>(take, mul_div_sat(
            source_owner, take, source_population, _saturation_count));
        const int64_t source_employee = std::clamp<int64_t>(
            population_store().employee_employed[slot], 0,
            std::max<int64_t>(0, source_population - source_owner));
        payload.employee_employed = std::min<int64_t>(
            std::max<int64_t>(0, take - payload.owner_employed),
            mul_div_sat(source_employee, take, source_population,
                _saturation_count));
        payload.needs_satisfaction = population_store().needs_satisfaction[slot];
        payload.worst_need_id = population_store().worst_need_id[slot];
        payload.composite_satisfaction =
            population_store().composite_satisfaction[slot];
        payload.worst_dimension_id = population_store().worst_dimension_id[slot];
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            payload.satisfaction_dims[dim] = population_store().satisfaction_dims[
                static_cast<size_t>(slot) * SAT_DIM_COUNT + dim];
        payload.person_begin = static_cast<uint32_t>(
            family_expedition_person_handles().size());
        payload.person_count = 0;
        audit_touch_population_lane(slot);
        population_store().population.write_scalar(slot,
            population_store().population[slot] - take, market_mutation_sink());
        population_store().owner_employed.write_scalar(slot, saturating_sub(
            population_store().owner_employed[slot], payload.owner_employed,
            _saturation_count), market_mutation_sink());
        population_store().employee_employed.write_scalar(slot, saturating_sub(
            population_store().employee_employed[slot],
            payload.employee_employed, _saturation_count), market_mutation_sink());
        population_store().funds.write_scalar(slot,
            population_store().funds[slot] - payload.funds,
            market_mutation_sink());
        population_store().epoch_income.write_scalar(slot,
            population_store().epoch_income[slot] - payload.epoch_income,
            market_mutation_sink());
        population_store().epoch_expense.write_scalar(slot,
            population_store().epoch_expense[slot] - payload.epoch_expense,
            market_mutation_sink());
        population_store().epoch_in_kind_income.write_scalar(slot,
            population_store().epoch_in_kind_income[slot] -
                payload.epoch_in_kind_income, market_mutation_sink());
        population_store().income_ema.write_scalar(slot,
            population_store().income_ema[slot] - payload.income_ema,
            market_mutation_sink());
        population_store().epoch_tax_paid.write_scalar(slot,
            population_store().epoch_tax_paid[slot] - payload.epoch_tax_paid,
            market_mutation_sink());
        population_store().epoch_subsidy_received.write_scalar(slot,
            population_store().epoch_subsidy_received[slot] -
                payload.epoch_subsidy_received, market_mutation_sink());
        population_store().income_baseline_ema.write_scalar(slot,
            population_store().income_baseline_ema[slot] -
                payload.income_baseline_ema, market_mutation_sink());
        population_store().demography_residual.write_scalar(slot,
            population_store().demography_residual[slot] -
                payload.demography_residual, market_mutation_sink());
        shift_family_ledger_basis(slot, -payload.funds);
        family_expedition_payloads().push_back(payload);
        family_expeditions_store().payload_count.write_scalar(expedition,
            static_cast<uint32_t>(family_expedition_payloads().size()) -
                family_expeditions_store().payload_begin[expedition],
            market_mutation_sink());
        remaining -= take;
    }
    // 源池可能在提交与出发之间缩小（别的队伍先走了），按实际人数成行而不是
    // 让整条命令失败：家族人数才是玩家的意图。
    const int64_t actual = requested - remaining;
    if (actual != family_expeditions_store().anonymous[expedition])
        family_expeditions_store().anonymous.write_scalar(expedition, actual,
            market_mutation_sink());
    return true;
}

bool NativeEconomyRuntime::extract_family_expedition_payload(
        int32_t expedition, int64_t requested, std::string &error) {
    const auto started = std::chrono::steady_clock::now();
    const uint64_t family_handle = family_expeditions_store().family_handle[expedition];
    const int32_t source_cell = family_expeditions_store().source_cell[expedition];
    struct Candidate { int32_t edge; int32_t slot; int64_t people;
        bool unemployed; uint64_t stable; int64_t selected = 0; };
    std::vector<Candidate> candidates;
    int32_t family = -1;
    if (!families_store().valid_handle(family_handle, family)) {
        error = "colonization_family_invalid"; return false;
    }
    const bool csr = _family_member_offsets.size() == families_store().active.size() + 1;
    const int32_t begin = csr ? _family_member_offsets[family] : 0;
    const int32_t end = csr ? _family_member_offsets[family + 1]
        : static_cast<int32_t>(family_memberships().size());
    for (int32_t p = begin; p < end; ++p) {
        const int32_t edge_index = csr ? _family_member_edge_indices[p] : p;
        const FamilyMembershipEdge &edge = family_memberships()[edge_index];
        int32_t slot = -1;
        if (edge.family_handle != family_handle || edge.people <= 0 ||
            !population_store().valid_handle(edge.cohort_handle, slot) ||
            population_store().page_cell[slot / COHORT_PAGE_SIZE] != source_cell) continue;
        const int32_t signature = static_cast<int32_t>(
            population_store().signature_id[slot]);
        // Military v1: soldiers are never drawn into a colonization party.
        if (profession_is_state_service_only(
                _signatures[signature].profession_id)) continue;
        candidates.push_back({edge_index, slot, edge.people,
            _signatures[signature].profession_id == _unemployed_profession_id,
            edge.cohort_handle, 0});
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a,
            const Candidate &b) {
        return std::tuple<bool, uint64_t, int32_t>(
                   !a.unemployed, a.stable, a.edge) <
               std::tuple<bool, uint64_t, int32_t>(
                   !b.unemployed, b.stable, b.edge);
    });
    int64_t remaining = requested;
    for (Candidate &candidate : candidates) {
        if (!candidate.unemployed || remaining <= 0) continue;
        candidate.selected = std::min(candidate.people, remaining);
        remaining -= candidate.selected;
    }
    if (remaining > 0) {
        int64_t pool = 0;
        for (const Candidate &candidate : candidates)
            if (!candidate.unemployed) pool += candidate.people;
        if (pool < remaining) { error = "colonization_population_insufficient"; return false; }
        struct Remainder { int32_t candidate; int64_t remainder; int32_t profession;
            int32_t ethnicity; uint64_t stable; };
        std::vector<Remainder> remainders;
        int64_t allocated = 0;
        for (int32_t i = 0; i < static_cast<int32_t>(candidates.size()); ++i) {
            Candidate &candidate = candidates[i];
            if (candidate.unemployed) continue;
            candidate.selected = mul_div_sat(remaining, candidate.people,
                pool, _saturation_count);
            allocated += candidate.selected;
            const int32_t signature = static_cast<int32_t>(
                population_store().signature_id[candidate.slot]);
            remainders.push_back({i, static_cast<int64_t>(mul_mod_u64(
                    static_cast<uint64_t>(remaining),
                    static_cast<uint64_t>(candidate.people),
                    static_cast<uint64_t>(pool))),
                _signatures[signature].profession_id,
                _signatures[signature].ethnicity_id, candidate.stable});
        }
        std::sort(remainders.begin(), remainders.end(), [](const Remainder &a,
                const Remainder &b) {
            if (a.remainder != b.remainder) return a.remainder > b.remainder;
            return std::tie(a.profession, a.ethnicity, a.stable) <
                   std::tie(b.profession, b.ethnicity, b.stable);
        });
        for (int64_t i = allocated; i < remaining; ++i)
            ++candidates[remainders[static_cast<size_t>(i - allocated)].candidate].selected;
    }
    int64_t merchant_population = living_merchant_population(source_cell);
    int64_t merchant_selected = 0;
    for (const Candidate &candidate : candidates) {
        if (candidate.selected > 0 && is_merchant_slot(candidate.slot))
            merchant_selected += candidate.selected;
    }
    int64_t overflow = merchant_selected -
        std::max<int64_t>(0, merchant_population - 1);
    for (int32_t i = static_cast<int32_t>(candidates.size()) - 1;
         i >= 0 && overflow > 0; --i) {
        Candidate &candidate = candidates[i];
        if (candidate.selected <= 0 || !is_merchant_slot(candidate.slot))
            continue;
        const int64_t reduce = std::min(overflow, candidate.selected);
        candidate.selected -= reduce;
        overflow -= reduce;
    }
    // Leaving the last living merchant can drop selected below the quoted
    // request. Refill from remaining non-merchant family capacity so the
    // transit count still matches the command; otherwise reject before
    // mutating ledgers. A stale scalar of requested people against a smaller
    // payload is what tripped population_conservation_failed after in-epoch
    // starts.
    int64_t selected_total = 0;
    for (const Candidate &candidate : candidates)
        selected_total += candidate.selected;
    int64_t shortfall = requested - selected_total;
    for (Candidate &candidate : candidates) {
        if (shortfall <= 0) break;
        if (is_merchant_slot(candidate.slot) ||
            candidate.selected >= candidate.people) continue;
        const int64_t take = std::min(shortfall,
            candidate.people - candidate.selected);
        candidate.selected += take;
        shortfall -= take;
    }
    selected_total = 0;
    for (const Candidate &candidate : candidates)
        selected_total += candidate.selected;
    if (selected_total != requested) {
        error = "colonization_population_insufficient";
        return false;
    }
    family_expeditions_store().payload_begin.write_scalar(expedition, static_cast<uint32_t>(
        family_expedition_payloads().size()), market_mutation_sink());
    family_expeditions_store().payload_count.write_scalar(expedition, 0, market_mutation_sink());
    std::vector<std::pair<int32_t, int64_t>> basis_shifts;
    for (Candidate &candidate : candidates) {
        if (candidate.selected <= 0) continue;
        auto edge_write = family_memberships().edit_row(candidate.edge, market_mutation_sink());
        FamilyMembershipEdge &edge = edge_write[0];
        const int32_t slot = candidate.slot;
        const int64_t source_population = population_store().population[slot];
        if (candidate.selected > edge.people || candidate.selected >=
                family_population_in_cell(family_handle, source_cell)) {
            error = "colonization_population_guard_failed";
            for (const auto &shift : basis_shifts)
                shift_family_ledger_basis(shift.first, -shift.second);
            unwind_family_expedition_payload_extract(expedition);
            return false;
        }
        FamilyExpeditionPayload payload;
        payload.source_cohort_handle = edge.cohort_handle;
        payload.signature = static_cast<int32_t>(population_store().signature_id[slot]);
        payload.people = candidate.selected;
        payload.funds = mul_div_sat(population_store().funds[slot], candidate.selected,
            source_population, _saturation_count);
        payload.epoch_income = mul_div_sat(population_store().epoch_income[slot],
            candidate.selected, source_population, _saturation_count);
        payload.epoch_expense = mul_div_sat(population_store().epoch_expense[slot],
            candidate.selected, source_population, _saturation_count);
        payload.epoch_in_kind_income = mul_div_sat(
            population_store().epoch_in_kind_income[slot], candidate.selected,
            source_population, _saturation_count);
        payload.income_ema = mul_div_sat(population_store().income_ema[slot],
            candidate.selected, source_population, _saturation_count);
        payload.epoch_tax_paid = mul_div_sat(population_store().epoch_tax_paid[slot],
            candidate.selected, source_population, _saturation_count);
        payload.epoch_subsidy_received = mul_div_sat(
            population_store().epoch_subsidy_received[slot], candidate.selected,
            source_population, _saturation_count);
        payload.income_baseline_ema = mul_div_sat(
            population_store().income_baseline_ema[slot], candidate.selected,
            source_population, _saturation_count);
        payload.demography_residual = mul_div_sat(
            population_store().demography_residual[slot], candidate.selected,
            source_population, _saturation_count);
        payload.cash_claim = mul_div_sat(edge.cash_claim, candidate.selected,
            edge.people, _saturation_count);
        // Family employment attribution is a derived split and can lag the
        // authoritative cohort lane after a building/employment pass.  A
        // zero attribution must not make a populated employed cohort look
        // unemployed during extraction: the source population lane is what
        // the ledger export validates.  When no family edge carries a lane,
        // distribute the authoritative lane by this edge's population and
        // then take the selected share.
        int64_t attributed_owner = 0;
        int64_t attributed_employee = 0;
        for (const FamilyMembershipEdge &other : family_memberships()) {
            if (other.cohort_handle != edge.cohort_handle) continue;
            attributed_owner = saturating_add(attributed_owner,
                std::max<int64_t>(0, other.owner_employed),
                _saturation_count);
            attributed_employee = saturating_add(attributed_employee,
                std::max<int64_t>(0, other.employee_employed),
                _saturation_count);
        }
        const int64_t source_owner = std::clamp<int64_t>(
            population_store().owner_employed[slot], 0, source_population);
        const int64_t source_employee = std::clamp<int64_t>(
            population_store().employee_employed[slot], 0,
            std::max<int64_t>(0, source_population - source_owner));
        const int64_t edge_owner = attributed_owner == 0 && source_owner > 0
            ? mul_div_sat(source_owner, edge.people, source_population,
                _saturation_count)
            : std::max<int64_t>(0, edge.owner_employed);
        const int64_t edge_employee = attributed_employee == 0 &&
                source_employee > 0
            ? mul_div_sat(source_employee, edge.people, source_population,
                _saturation_count)
            : std::max<int64_t>(0, edge.employee_employed);
        payload.owner_employed = std::min<int64_t>(candidate.selected,
            mul_div_sat(edge_owner, candidate.selected, edge.people,
                _saturation_count));
        payload.employee_employed = std::min<int64_t>(
            std::max<int64_t>(0, candidate.selected - payload.owner_employed),
            mul_div_sat(edge_employee, candidate.selected, edge.people,
                _saturation_count));
        payload.needs_satisfaction = population_store().needs_satisfaction[slot];
        payload.worst_need_id = population_store().worst_need_id[slot];
        payload.composite_satisfaction =
            population_store().composite_satisfaction[slot];
        payload.worst_dimension_id = population_store().worst_dimension_id[slot];
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            payload.satisfaction_dims[dim] = population_store().satisfaction_dims[
                static_cast<size_t>(slot) * SAT_DIM_COUNT + dim];
        payload.person_begin = static_cast<uint32_t>(
            family_expedition_person_handles().size());
        std::vector<int32_t> people;
        for (int32_t person = 0; person < static_cast<int32_t>(
                persons_store().active.size()); ++person) {
            if (persons_store().active[person] != 0 &&
                persons_store().family_handle[person] == family_handle &&
                persons_store().cohort_handle[person] == edge.cohort_handle)
                people.push_back(person);
        }
        std::sort(people.begin(), people.end(), [&](int32_t a, int32_t b) {
            return std::tie(persons_store().stable_id[a], a) <
                   std::tie(persons_store().stable_id[b], b);
        });
        int64_t remaining_people = edge.people;
        int64_t remaining_selected = candidate.selected;
        for (const int32_t person : people) {
            uint64_t hash = 1469598103934665603ULL;
            hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
            hash = trace_hash_mix(hash, static_cast<uint64_t>(
                family_expeditions_store().stable_id[expedition]));
            hash = trace_hash_mix(hash, static_cast<uint64_t>(
                persons_store().stable_id[person]));
            if (remaining_people > 0 && remaining_selected > 0 &&
                static_cast<int64_t>(hash % static_cast<uint64_t>(
                    remaining_people)) < remaining_selected) {
                family_expedition_person_handles().push_back(
                    persons_store().handle_for_index(person));
                persons_store().cohort_handle.write_scalar(person, 0, market_mutation_sink());
                persons_store().building_handle.write_scalar(person, 0, market_mutation_sink());
                persons_store().job_kind.write_scalar(person, 0, market_mutation_sink());
                persons_store().employee_role_index.write_scalar(person, -1, market_mutation_sink());
                --remaining_selected;
            }
            --remaining_people;
        }
        payload.person_count = static_cast<uint32_t>(
            family_expedition_person_handles().size()) - payload.person_begin;
        audit_touch_population_lane(slot);
        population_store().population.write_scalar(slot, population_store().population[slot] - (payload.people), market_mutation_sink());
        population_store().owner_employed.write_scalar(slot, saturating_sub(
            population_store().owner_employed[slot], payload.owner_employed,
            _saturation_count), market_mutation_sink());
        population_store().employee_employed.write_scalar(slot, saturating_sub(
            population_store().employee_employed[slot],
            payload.employee_employed, _saturation_count), market_mutation_sink());
        population_store().funds.write_scalar(slot, population_store().funds[slot] - (payload.funds), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, population_store().epoch_income[slot] - (payload.epoch_income), market_mutation_sink());
        population_store().epoch_expense.write_scalar(slot, population_store().epoch_expense[slot] - (payload.epoch_expense), market_mutation_sink());
        population_store().epoch_in_kind_income.write_scalar(slot, population_store().epoch_in_kind_income[slot] - (payload.epoch_in_kind_income), market_mutation_sink());
        population_store().income_ema.write_scalar(slot, population_store().income_ema[slot] - (payload.income_ema), market_mutation_sink());
        population_store().epoch_tax_paid.write_scalar(slot, population_store().epoch_tax_paid[slot] - (payload.epoch_tax_paid), market_mutation_sink());
        population_store().epoch_subsidy_received.write_scalar(slot, population_store().epoch_subsidy_received[slot] - (payload.epoch_subsidy_received), market_mutation_sink());
        population_store().income_baseline_ema.write_scalar(slot, population_store().income_baseline_ema[slot] - (payload.income_baseline_ema), market_mutation_sink());
        population_store().demography_residual.write_scalar(slot, population_store().demography_residual[slot] - (payload.demography_residual), market_mutation_sink());
        edge.people -= payload.people; edge.cash_claim -= payload.cash_claim;
        edge.owner_employed = std::max<int64_t>(0,
            edge_owner - payload.owner_employed);
        edge.employee_employed = std::max<int64_t>(0,
            edge_employee - payload.employee_employed);
        edge.population_basis = std::max<int64_t>(0,
            edge.population_basis - payload.people);
        basis_shifts.emplace_back(slot, payload.funds);
        family_expedition_payloads().push_back(payload);
        family_expeditions_store().payload_count.write_scalar(expedition, static_cast<uint32_t>(family_expedition_payloads().size()) -
            family_expeditions_store().payload_begin[expedition], market_mutation_sink());
    }
    if (!extract_family_expedition_anonymous_lanes(expedition, error)) {
        unwind_family_expedition_payload_extract(expedition);
        return false;
    }
    // The departing payload is a structural outflow, not a ledger delta.
    for (const auto &shift : basis_shifts)
        shift_family_ledger_basis(shift.first, -shift.second);
    // Population extraction is a structural mutation.  Keep the authoritative
    // cohort employment lanes clipped to the remaining population before any
    // POD mirror/export can observe the command, including rounding across
    // multiple family membership edges.
    clip_cell_employment_and_defer_reconcile(source_cell);
    family_expeditions_store().payload_count.write_scalar(expedition, static_cast<uint32_t>(
        family_expedition_payloads().size()) -
        family_expeditions_store().payload_begin[expedition], market_mutation_sink());
    if (family_expeditions_store().payload_count[expedition] == 0) {
        error = "colonization_payload_empty";
        unwind_family_expedition_payload_extract(expedition);
        return false;
    }
    const uint32_t payload_begin = family_expeditions_store().payload_begin[expedition];
    const uint32_t payload_end = payload_begin +
        family_expeditions_store().payload_count[expedition];
    if (!reserve_family_expedition_payload_slots(
            expedition, payload_begin, payload_end, true)) {
        error = "colonization_target_slot_reservation_failed";
        unwind_family_expedition_payload_extract(expedition);
        return false;
    }
    family_expeditions_store().population.write_scalar(expedition,
        family_expedition_payload_family_people(expedition), market_mutation_sink());
    family_expeditions_store().anonymous.write_scalar(expedition,
        family_expedition_anonymous_people(expedition), market_mutation_sink());
    _family_indices_dirty = true; _person_indices_dirty = true;
    _structural_touched_cells.push_back(source_cell);
    if (!repair_cell_merchant_and_rebuild(source_cell, error)) {
        unwind_family_expedition_payload_extract(expedition);
        return false;
    }
    _colonization_payload_split_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return true;
}

bool NativeEconomyRuntime::restore_family_expedition_payload(
        int32_t expedition, int32_t destination_cell, std::string &error) {
    if (destination_cell < 0 || destination_cell >= _cell_count.get()) {
        error = "colonization_destination_invalid"; return false;
    }
    const uint64_t family_handle = family_expeditions_store().family_handle[expedition];
    const uint32_t begin = family_expeditions_store().payload_begin[expedition];
    const uint32_t end = begin + family_expeditions_store().payload_count[expedition];
    if (end > family_expedition_payloads().size()) {
        error = "colonization_payload_range_invalid"; return false;
    }
    for (uint32_t p = begin; p < end; ++p) {
        auto payload_write = family_expedition_payloads().edit_row(p, market_mutation_sink());
        FamilyExpeditionPayload &payload = payload_write[0];
        const uint64_t reservation_owner =
            family_expeditions_store().handle_for_index(expedition);
        int32_t slot = -1;
        if (destination_cell == family_expeditions_store().target_cell[expedition]) {
            slot = population_store().claim_reserved_slot(payload.reserved_slot,
                destination_cell, static_cast<uint32_t>(payload.signature),
                reservation_owner);
        } else {
            population_store().release_reserved_slot(payload.reserved_slot,
                                               reservation_owner);
            slot = population_store().allocate_slot(destination_cell,
                static_cast<uint32_t>(payload.signature));
        }
        if (slot < 0) { error = "colonization_reserved_slot_unavailable"; return false; }
        payload.reserved_slot = -1;
        const int64_t old_population = population_store().population[slot];
        const int64_t merged_population = old_population + payload.people;
        // Employment leaves the source cohort together with the payload.  Put
        // it back on the destination lane as part of the same atomic merge;
        // otherwise family attribution can reconstruct jobs against a stale
        // population and the next POD export rejects the ledger.
        const int64_t incoming_employment = std::min<int64_t>(
            payload.people,
            std::max<int64_t>(0, payload.owner_employed) +
            std::max<int64_t>(0, payload.employee_employed));
        const int64_t incoming_owner_employed = std::min<int64_t>(
            std::max<int64_t>(0, payload.owner_employed), incoming_employment);
        const int64_t incoming_employee_employed = std::min<int64_t>(
            std::max<int64_t>(0, payload.employee_employed),
            incoming_employment - incoming_owner_employed);
        auto blend = [&](uint16_t old_value, uint16_t incoming) {
            if (merged_population <= 0) return incoming;
            return static_cast<uint16_t>((static_cast<int64_t>(old_value) *
                old_population + static_cast<int64_t>(incoming) * payload.people) /
                merged_population);
        };
        audit_touch_population_lane(slot); touch_accounting_slot(slot);
        population_store().population.write_scalar(slot, merged_population, market_mutation_sink());
        population_store().owner_employed.write_scalar(slot, saturating_add(
            population_store().owner_employed[slot],
            incoming_owner_employed, _saturation_count), market_mutation_sink());
        population_store().employee_employed.write_scalar(slot, saturating_add(
            population_store().employee_employed[slot],
            incoming_employee_employed, _saturation_count), market_mutation_sink());
        const int64_t total_employment =
            population_store().owner_employed[slot] +
            population_store().employee_employed[slot];
        if (total_employment > merged_population) {
            population_store().employee_employed.write_scalar(slot, std::max<int64_t>(
                0, merged_population - population_store().owner_employed[slot]), market_mutation_sink());
        }
        population_store().funds.write_scalar(slot, population_store().funds[slot] + (payload.funds), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, population_store().epoch_income[slot] + (payload.epoch_income), market_mutation_sink());
        population_store().epoch_expense.write_scalar(slot, population_store().epoch_expense[slot] + (payload.epoch_expense), market_mutation_sink());
        population_store().epoch_in_kind_income.write_scalar(slot, population_store().epoch_in_kind_income[slot] + (payload.epoch_in_kind_income), market_mutation_sink());
        population_store().income_ema.write_scalar(slot, population_store().income_ema[slot] + (payload.income_ema), market_mutation_sink());
        population_store().epoch_tax_paid.write_scalar(slot, population_store().epoch_tax_paid[slot] + (payload.epoch_tax_paid), market_mutation_sink());
        population_store().epoch_subsidy_received.write_scalar(slot, population_store().epoch_subsidy_received[slot] + (payload.epoch_subsidy_received), market_mutation_sink());
        population_store().income_baseline_ema.write_scalar(slot, population_store().income_baseline_ema[slot] + (payload.income_baseline_ema), market_mutation_sink());
        population_store().demography_residual.write_scalar(slot, population_store().demography_residual[slot] + (payload.demography_residual), market_mutation_sink());
        population_store().needs_satisfaction.write_scalar(slot, blend(
            population_store().needs_satisfaction[slot], payload.needs_satisfaction), market_mutation_sink());
        population_store().composite_satisfaction.write_scalar(slot, blend(
            population_store().composite_satisfaction[slot],
            payload.composite_satisfaction), market_mutation_sink());
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            const size_t lane = static_cast<size_t>(slot) * SAT_DIM_COUNT + dim;
            population_store().satisfaction_dims.write_scalar(lane, blend(
                population_store().satisfaction_dims[lane],
                payload.satisfaction_dims[dim]), market_mutation_sink());
        }
        if (old_population == 0) {
            population_store().worst_need_id.write_scalar(slot, payload.worst_need_id, market_mutation_sink());
            population_store().worst_dimension_id.write_scalar(slot, payload.worst_dimension_id, market_mutation_sink());
        }
        const uint64_t cohort_handle = population_store().handle_for_slot(slot);
        shift_family_ledger_basis(slot, payload.funds);
        // 随行平民落地后仍是本地无家族人口：登记成员边会凭空把移民变成族人，
        // 也会污染目标地的家族份额。他们只能经招收/absorb 正常入籍。
        if (payload.anonymous == 0) {
            family_memberships().push_back({family_handle, cohort_handle,
                payload.people, payload.cash_claim, merged_population,
                family_ledger_basis_for_slot(slot), incoming_owner_employed,
                incoming_employee_employed});
        }
        if (static_cast<size_t>(payload.person_begin) + payload.person_count >
                family_expedition_person_handles().size()) {
            error = "colonization_person_payload_range_invalid"; return false;
        }
        for (uint32_t i = 0; i < payload.person_count; ++i) {
            int32_t person = -1;
            if (persons_store().valid_handle(
                    family_expedition_person_handles()[payload.person_begin + i],
                    person))
                persons_store().cohort_handle.write_scalar(person, cohort_handle, market_mutation_sink());
        }
    }
    _family_indices_dirty = true; _person_indices_dirty = true;
    _structural_touched_cells.push_back(destination_cell);
    clip_cell_employment_and_defer_reconcile(destination_cell);
    return true;
}

bool NativeEconomyRuntime::finalize_immediate_family_expedition_settlement(
        int32_t destination_cell, std::string &error) {
    if (!repair_cell_merchant_and_rebuild(destination_cell, error)) return false;

    normalize_family_memberships(false);
    update_family_employment_attribution();
    if (_family_indices_dirty) rebuild_family_indices(false);
    rebuild_family_industry_metrics();
    rebuild_family_influences(false);
    rebuild_family_behavior_cache();
    rebuild_family_owned_output_csr();
    if (_person_indices_dirty) rebuild_person_indices();

    if (destination_cell >= 0 && destination_cell < _cell_count.get()) {
        const CellSummary summary = build_cell_summary(destination_cell);
        if (destination_cell < static_cast<int32_t>(_committed_cells.size()))
            _committed_cells[destination_cell] = summary;
        if (destination_cell < static_cast<int32_t>(_staging_cells.size()))
            _staging_cells[destination_cell] = summary;
        if (destination_cell < static_cast<int32_t>(
                _cell_population_gen.size()))
            _cell_population_gen.write_scalar(destination_cell, _cell_population_gen[destination_cell] + 1, market_mutation_sink());
    }
    // Restore already audit-touches the destination lane. Rebuilding the
    // incremental shadow after that would snapshot post-merge population and
    // drop the +people / -transit delta for this epoch.
    if (!_epoch_active) rebuild_incremental_audit_shadow();
    note_family_expedition_audit_invalidation();
    return true;
}

void NativeEconomyRuntime::release_family_expedition_reservations(
        int32_t expedition) {
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            family_expeditions_store().active.size()) ||
        family_expeditions_store().active[expedition] == 0) return;
    const uint64_t owner = family_expeditions_store().handle_for_index(expedition);
    const uint32_t begin = family_expeditions_store().payload_begin[expedition];
    const uint32_t end = std::min<uint32_t>(
        begin + family_expeditions_store().payload_count[expedition],
        static_cast<uint32_t>(family_expedition_payloads().size()));
    for (uint32_t p = begin; p < end; ++p) {
        auto payload_write = family_expedition_payloads().edit_row(p, market_mutation_sink());
        FamilyExpeditionPayload &payload = payload_write[0];
        population_store().release_reserved_slot(payload.reserved_slot, owner);
        payload.reserved_slot = -1;
    }
    population_store().reclaim_empty_pages(family_expeditions_store().target_cell[expedition]);
}


} // namespace pk
