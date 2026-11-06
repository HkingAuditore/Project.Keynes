#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "native_simulation_host.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

void NativeEconomyRuntime::promote_person_for_family(int32_t family_index) {
    if (_person_runtime_mode.get() != 2 || family_index < 0 ||
        family_index >= static_cast<int32_t>(families_store().active.size()) ||
        families_store().active[family_index] == 0 ||
        persons_store().active_count >= _person_max_total.get()) return;
    const uint64_t family_handle = families_store().handle_for_index(family_index);
    int64_t family_people = 0, eligible_jobs = 0;
    int32_t best_edge = -1;
    if (_family_member_offsets.size() != families_store().active.size() + 1) return;
    for (int32_t p = _family_member_offsets[family_index];
         p < _family_member_offsets[family_index + 1]; ++p) {
        const int32_t edge_index = _family_member_edge_indices[p];
        const FamilyMembershipEdge &edge = family_memberships()[edge_index];
        family_people += std::max<int64_t>(0, edge.people);
        eligible_jobs += std::max<int64_t>(0,
            edge.owner_employed + edge.employee_employed);
        int32_t edge_slot = -1;
        int64_t represented_people = 0;
        if (population_store().valid_handle(edge.cohort_handle, edge_slot) &&
            _person_cohort_offsets.size() == population_store().active.size() + 1)
            for (int32_t pp = _person_cohort_offsets[edge_slot];
                 pp < _person_cohort_offsets[edge_slot + 1]; ++pp) {
                const int32_t person = _person_cohort_indices[pp];
                if (persons_store().family_handle[person] == family_handle)
                    ++represented_people;
            }
        if (represented_people >= edge.people ||
            edge.owner_employed + edge.employee_employed <= 0) continue;
        if (best_edge < 0 ||
            std::tie(edge.owner_employed, edge.employee_employed, edge.people,
                     edge.cohort_handle) >
            std::tie(family_memberships()[best_edge].owner_employed,
                     family_memberships()[best_edge].employee_employed,
                     family_memberships()[best_edge].people,
                     family_memberships()[best_edge].cohort_handle))
            best_edge = edge_index;
    }
    if (best_edge < 0 || family_people <= 0 || eligible_jobs <= 0) return;
    int32_t existing = _person_family_offsets.size() ==
            families_store().active.size() + 1
        ? _person_family_offsets[family_index + 1] -
            _person_family_offsets[family_index] : 0;
    const int32_t target = static_cast<int32_t>(std::min<int64_t>(
        _person_max_per_family.get(), std::min(family_people, eligible_jobs)));
    if (existing >= target) return;
    int32_t slot = -1;
    if (!population_store().valid_handle(
            family_memberships()[best_edge].cohort_handle, slot)) return;
    const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
    int32_t cell_people = 0;
    if (_person_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1))
        cell_people = _person_cell_offsets[cell + 1] - _person_cell_offsets[cell];
    else for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i) {
        int32_t candidate_slot = -1;
        if (persons_store().active[i] != 0 &&
            population_store().valid_handle(persons_store().cohort_handle[i], candidate_slot) &&
            population_store().page_cell[candidate_slot / COHORT_PAGE_SIZE] == cell) ++cell_people;
    }
    if (cell_people >= _person_max_per_cell.get()) return;
    const int32_t index = persons_store().allocate();
    const uint64_t handle = persons_store().handle_for_index(index);
    const int64_t identity_day = std::max<int64_t>(0, _current_day.get());
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(families_store().stable_id[family_index]));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(identity_day));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(index));
    int64_t stable_id = static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
    for (uint64_t probe = 1;
         _person_stable_ids.count(stable_id) != 0; ++probe) {
        stable_id = static_cast<int64_t>((trace_hash_mix(hash, probe) &
            0x7fffffffffffffffULL) | 1ULL);
    }
    int64_t weight_sum = 0;
    for (int32_t weight : _person_given_name_weights) weight_sum += weight;
    int64_t roll = static_cast<int64_t>(trace_hash_mix(hash, 0x474956454eULL) %
        static_cast<uint64_t>(std::max<int64_t>(1, weight_sum)));
    int32_t given = 0;
    for (; given + 1 < static_cast<int32_t>(_person_given_name_weights.size());
         ++given) {
        if (roll < _person_given_name_weights[given]) break;
        roll -= _person_given_name_weights[given];
    }
    uint32_t disambiguator = 0;
    const FamilyMembershipEdge &edge = family_memberships()[best_edge];
    int64_t existing_claim = 0;
    // Both aggregates only look at the promoting family, so walk the
    // person-family CSR plus anything promoted since its last rebuild instead
    // of the whole person table.
    if (_person_candidate_stamp.size() < persons_store().active.size())
        _person_candidate_stamp.resize(persons_store().active.size(), 0);
    if (++_person_candidate_generation == 0) {
        std::fill(_person_candidate_stamp.begin(),
                  _person_candidate_stamp.end(), 0);
        _person_candidate_generation = 1;
    }
    const auto accumulate_sibling = [&](int32_t i) {
        if (i == index || i < 0 ||
            i >= static_cast<int32_t>(persons_store().active.size())) return;
        if (persons_store().active[i] == 0 ||
            persons_store().family_handle[i] != family_handle) return;
        if (_person_candidate_stamp[static_cast<size_t>(i)] ==
            _person_candidate_generation) return;
        _person_candidate_stamp[static_cast<size_t>(i)] =
            _person_candidate_generation;
        if (persons_store().given_name_id[i] == given)
            disambiguator = std::max(disambiguator,
                persons_store().name_disambiguator[i] + 1U);
        if (persons_store().cohort_handle[i] == edge.cohort_handle)
            existing_claim += std::max<int64_t>(0, persons_store().cash_claim[i]);
    };
    const int32_t indexed_families =
        static_cast<int32_t>(_person_family_offsets.size()) - 1;
    if (family_index < indexed_families) {
        const int32_t begin = _person_family_offsets[family_index];
        const int32_t end = _person_family_offsets[family_index + 1];
        _scan_steps_person_linear += end - begin;
        note_scan_steps(end - begin);
        for (int32_t p = begin; p < end; ++p)
            accumulate_sibling(_person_family_indices[p]);
    }
    const auto promoted = _person_family_migrations.find(family_handle);
    if (promoted != _person_family_migrations.end()) {
        _scan_steps_person_linear +=
            static_cast<int64_t>(promoted->second.size());
        note_scan_steps(static_cast<int64_t>(promoted->second.size()));
        for (const int32_t sibling : promoted->second)
            accumulate_sibling(sibling);
    }
    const int64_t one_share = edge.people > 0
        ? edge.cash_claim / edge.people : 0;
    persons_store().stable_id.write_scalar(index, stable_id, market_mutation_sink());
    _person_stable_ids.insert(stable_id);
    persons_store().family_handle.write_scalar(index, family_handle, market_mutation_sink());
    _person_family_migrations[family_handle].push_back(index);
    persons_store().cohort_handle.write_scalar(index, edge.cohort_handle, market_mutation_sink());
    _person_cohort_migrations[edge.cohort_handle].push_back(index);
    persons_store().given_name_id.write_scalar(index, given, market_mutation_sink());
    persons_store().name_disambiguator.write_scalar(index, disambiguator, market_mutation_sink());
    persons_store().notable_since_day.write_scalar(index, identity_day, market_mutation_sink());
    persons_store().flags.write_scalar(index, existing == 0 ? 1U : 0U, market_mutation_sink());
    persons_store().cash_claim.write_scalar(index, std::min(one_share,
        std::max<int64_t>(0, edge.cash_claim - existing_claim)), market_mutation_sink());
    persons_store().needs_satisfaction.write_scalar(index, population_store().needs_satisfaction[slot], market_mutation_sink());
    persons_store().worst_need_id.write_scalar(index, population_store().worst_need_id[slot], market_mutation_sink());
    ++_persons_promoted;
    register_person_effect(index);
    _person_indices_dirty = true;
    (void)handle;
}

void NativeEconomyRuntime::bind_notable_person_jobs() {
    _person_previous_building_handle = persons_store().building_handle;
    _person_previous_job_kind = persons_store().job_kind;
    _person_previous_employee_role_index = persons_store().employee_role_index;
    for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i) {
        if (persons_store().active[i] == 0) continue;
        persons_store().building_handle.write_scalar(i, 0, market_mutation_sink()); persons_store().job_kind.write_scalar(i, 0, market_mutation_sink());
        persons_store().employee_role_index.write_scalar(i, -1, market_mutation_sink());
    }
    if (_person_family_offsets.size() != families_store().active.size() + 1)
        rebuild_person_indices();
    // Owners: family ownership and exact owner-signature membership are hard
    // constraints. Capacity counters avoid materializing individual job slots.
    for (int32_t family = 0; family < static_cast<int32_t>(
            families_store().active.size()); ++family) {
        if (families_store().active[family] == 0) continue;
        for (int32_t op = _family_owned_offsets[family];
             op < _family_owned_offsets[family + 1]; ++op) {
            const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
                _family_owned_edge_indices[op], __FILE__, __LINE__);
            const int32_t building = building_index_for_handle(
                ownership.building_handle);
            if (building < 0) continue;
            const auto group = building_view(static_cast<size_t>(building));
            const int32_t owner_slot = find_cohort_slot(
                group.cell, group.owner_signature_id);
            if (owner_slot < 0) continue;
            int64_t remaining = std::max<int64_t>(0, ownership.filled_owner);
            for (int32_t pp = _person_family_offsets[family];
                 pp < _person_family_offsets[family + 1] && remaining > 0; ++pp) {
                const int32_t person = _person_family_indices[pp];
                if (persons_store().job_kind[person] != 0 ||
                    persons_store().cohort_handle[person] !=
                        population_store().handle_for_slot(owner_slot)) continue;
                persons_store().building_handle.write_scalar(person, ownership.building_handle, market_mutation_sink());
                persons_store().job_kind.write_scalar(person, 1, market_mutation_sink());
                if (_person_previous_job_kind[person] != 1 ||
                    _person_previous_building_handle[person] !=
                        ownership.building_handle)
                    persons_store().job_since_day.write_scalar(person, std::max<int64_t>(0,
                        _current_day.get()), market_mutation_sink());
                const int64_t net = group.last_revenue - group.last_input_cost -
                    group.last_wages_paid;
                persons_store().epoch_business_result.write_scalar(person, ownership.filled_owner > 0
                    ? net / ownership.filled_owner : 0, market_mutation_sink());
                --remaining; ++_person_jobs_bound;
            }
        }
    }
    // Employees: assign only within the exact cohort profession and committed
    // role fill. Existing aggregate role fill remains untouched.
    std::vector<int64_t> role_used(_building_employee_filled.size(), 0);
    for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i) {
        if (persons_store().active[i] == 0 || persons_store().job_kind[i] != 0) continue;
        int32_t slot = -1;
        if (!population_store().valid_handle(persons_store().cohort_handle[i], slot)) continue;
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size()))
            continue;
        const int32_t profession = _signatures[signature].profession_id;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1] && persons_store().job_kind[i] == 0; ++g) {
            const auto group = building_view(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t role_lane = group.employee_fill_begin + r;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession || role_lane < 0 ||
                    role_lane >= static_cast<int32_t>(_building_employee_filled.size()) ||
                    role_used[role_lane] >= _building_employee_filled[role_lane]) continue;
                persons_store().building_handle.write_scalar(i, group.modifier_handle, market_mutation_sink());
                persons_store().job_kind.write_scalar(i, 2, market_mutation_sink());
                persons_store().employee_role_index.write_scalar(i, r, market_mutation_sink());
                if (_person_previous_job_kind[i] != 2 ||
                    _person_previous_building_handle[i] != group.modifier_handle ||
                    _person_previous_employee_role_index[i] != r)
                    persons_store().job_since_day.write_scalar(i, std::max<int64_t>(0,
                        _current_day.get()), market_mutation_sink());
                persons_store().epoch_job_income.write_scalar(i, _building_employee_filled[role_lane] > 0
                    ? (_building_role_base_wage_paid[role_lane] +
                       _building_role_bonus_paid[role_lane]) /
                        _building_employee_filled[role_lane] : 0, market_mutation_sink());
                ++role_used[role_lane]; ++_person_jobs_bound;
                break;
            }
        }
    }
    for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i)
        if (persons_store().active[i] != 0 && persons_store().job_kind[i] == 0)
            persons_store().job_since_day.write_scalar(i, -1, market_mutation_sink());
}

void NativeEconomyRuntime::reconcile_person_claims() {
    if (_person_family_offsets.size() != families_store().active.size() + 1)
        rebuild_person_indices();
    for (const FamilyMembershipEdge &membership : family_memberships()) {
        int32_t slot = -1;
        if (!population_store().valid_handle(membership.cohort_handle, slot)) continue;
        std::vector<int32_t> members;
        int64_t raw_total = 0;
        for (int32_t p = _person_cohort_offsets[slot];
             p < _person_cohort_offsets[slot + 1]; ++p) {
            const int32_t person = _person_cohort_indices[p];
            if (persons_store().family_handle[person] != membership.family_handle) continue;
            members.push_back(person);
            const int64_t opening = person < static_cast<int32_t>(
                    _person_opening_cash_claim.size())
                ? _person_opening_cash_claim[person] : persons_store().cash_claim[person];
            const int64_t raw = std::max<int64_t>(0, opening +
                persons_store().epoch_job_income[person] +
                persons_store().epoch_business_result[person] -
                persons_store().epoch_consumption_expense[person]);
            persons_store().cash_claim.write_scalar(person, raw, market_mutation_sink());
            raw_total = saturating_add(raw_total, raw, _saturation_count);
        }
        if (raw_total > membership.cash_claim && raw_total > 0) {
            int64_t prefix = 0, distributed = 0;
            for (int32_t person : members) {
                prefix = saturating_add(prefix, persons_store().cash_claim[person],
                                        _saturation_count);
                const int64_t next = mul_div_sat(membership.cash_claim, prefix,
                    raw_total, _saturation_count);
                persons_store().cash_claim.write_scalar(person, std::max<int64_t>(0,
                    next - distributed), market_mutation_sink());
                distributed = next;
            }
        }
        for (int32_t person : members) {
            const int64_t daily_income = _epoch_days.get() > 0
                ? persons_store().epoch_job_income[person] / _epoch_days.get() : 0;
            persons_store().income_ema.write_scalar(person, (persons_store().income_ema[person] * 7 +
                daily_income) / 8, market_mutation_sink());
        }
    }
}

uint64_t NativeEconomyRuntime::sponsor_family_for_cohort(
        uint64_t cohort_handle, int32_t cell) const {
    uint64_t best = 0;
    int64_t best_claim = -1;
    int32_t slot = -1;
    if (!population_store().valid_handle(cohort_handle, slot) ||
        population_store().page_cell[slot / COHORT_PAGE_SIZE] != cell ||
        _family_cohort_offsets.size() != population_store().active.size() + 1)
        return 0;
    for (int32_t p = _family_cohort_offsets[slot];
         p < _family_cohort_offsets[slot + 1]; ++p) {
        const FamilyMembershipEdge &edge = family_memberships()[
            _family_cohort_edge_indices[p]];
        if (edge.cash_claim < best_claim) continue;
        if (edge.cash_claim > best_claim || edge.family_handle < best) {
            best = edge.family_handle;
            best_claim = edge.cash_claim;
        }
    }
    return best;
}

} // namespace pk
