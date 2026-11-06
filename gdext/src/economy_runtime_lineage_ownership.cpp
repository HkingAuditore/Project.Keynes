#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
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

namespace {
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

void NativeEconomyRuntime::rebuild_family_indices(bool rebuild_derived) {
    const auto membership_started = Clock::now();
    const auto membership_erase_started = Clock::now();
    family_memberships().erase_if(
        [&](const FamilyMembershipEdge &edge) {
            int32_t family = -1, slot = -1;
            return edge.people <= 0 ||
                !families_store().valid_handle(edge.family_handle, family) ||
                !population_store().valid_handle(edge.cohort_handle, slot);
        });
    EconomyCostProbe::record("family.rebuild.membership_erase", _current_day.get(),
                             elapsed_ms(membership_erase_started));
    const auto membership_before = family_memberships().begin();
    const auto membership_after = family_memberships().end();
    const auto membership_less = [](const FamilyMembershipEdge &a,
                                    const FamilyMembershipEdge &b) {
        return std::tie(a.cohort_handle, a.family_handle) <
            std::tie(b.cohort_handle, b.family_handle);
    };
    // Steady-state rebuilds see an already sorted, duplicate-free ledger. The
    // container's sort()/swap() re-encode every row through the audited column,
    // so skip them when the order and keys are unchanged.
    if (!std::is_sorted(membership_before, membership_after, membership_less))
        family_memberships().sort(membership_less);
    bool membership_has_duplicates = false;
    for (size_t i = 1; i < family_memberships().size(); ++i) {
        if (family_memberships()[i - 1].cohort_handle ==
                family_memberships()[i].cohort_handle &&
            family_memberships()[i - 1].family_handle ==
                family_memberships()[i].family_handle) {
            membership_has_duplicates = true;
            break;
        }
    }
    if (membership_has_duplicates) {
        std::vector<FamilyMembershipEdge> merged_memberships;
        merged_memberships.reserve(family_memberships().size());
        for (const FamilyMembershipEdge &edge : family_memberships()) {
            if (!merged_memberships.empty() &&
                merged_memberships.back().cohort_handle == edge.cohort_handle &&
                merged_memberships.back().family_handle == edge.family_handle) {
                FamilyMembershipEdge &dst = merged_memberships.back();
                dst.people += edge.people;
                dst.cash_claim += edge.cash_claim;
                dst.population_basis = std::max(dst.population_basis,
                                                edge.population_basis);
                dst.funds_basis = std::max(dst.funds_basis, edge.funds_basis);
                // Employment is recomputed later; keep merge-only edges basis-valid.
                dst.owner_employed = 0;
                dst.employee_employed = 0;
                sanitize_family_membership_edge(dst);
            } else {
                merged_memberships.push_back(edge);
            }
        }
        family_memberships().swap(merged_memberships);
    }
    EconomyCostProbe::record("family.rebuild.membership_merge", _current_day.get(),
                             elapsed_ms(membership_erase_started));

    _family_member_offsets.assign(families_store().active.size() + 1, 0);
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        int32_t family = -1;
        if (families_store().valid_handle(edge.family_handle, family))
            ++_family_member_offsets[static_cast<size_t>(family) + 1];
    }
    for (size_t i = 0; i + 1 < _family_member_offsets.size(); ++i)
        _family_member_offsets[i + 1] += _family_member_offsets[i];
    _family_member_edge_indices.assign(family_memberships().size(), -1);
    std::vector<int32_t> family_member_cursor(_family_member_offsets.begin(),
                                               _family_member_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(family_memberships().size()); ++i) {
        int32_t family = -1;
        if (families_store().valid_handle(family_memberships()[i].family_handle, family))
            _family_member_edge_indices[family_member_cursor[family]++] = i;
    }

    EconomyCostProbe::record("family.rebuild.membership_csr", _current_day.get(),
                             elapsed_ms(membership_started));
    _rebuild_family_membership_ms += elapsed_ms(membership_started);
    const auto ownership_started = Clock::now();
    // Nothing below mutates the group lane, so the shared handle index stays valid
    // for the whole rebuild and we avoid re-hashing every building group.
    const std::unordered_map<uint64_t, int32_t> &building_by_handle =
        building_handle_index();
    family_ownerships().erase_if(
        [&](const FamilyBuildingOwnership &edge) {
            int32_t family = -1;
            return edge.owned_count <= 0 ||
                !families_store().valid_handle(edge.family_handle, family) ||
                building_by_handle.find(edge.building_handle) ==
                    building_by_handle.end();
        });
    const auto ownership_less = [](const FamilyBuildingOwnership &a,
                                   const FamilyBuildingOwnership &b) {
        return std::tie(a.building_handle, a.family_handle) <
            std::tie(b.building_handle, b.family_handle);
    };
    if (!std::is_sorted(family_ownerships().begin(), family_ownerships().end(),
                        ownership_less))
        family_ownerships().sort(ownership_less);
    bool ownership_has_duplicates = false;
    for (size_t i = 1; i < family_ownerships().size(); ++i) {
        if (family_ownerships()[i - 1].building_handle ==
                family_ownerships()[i].building_handle &&
            family_ownerships()[i - 1].family_handle ==
                family_ownerships()[i].family_handle) {
            ownership_has_duplicates = true;
            break;
        }
    }
    if (ownership_has_duplicates) {
        std::vector<FamilyBuildingOwnership> merged_ownerships;
        merged_ownerships.reserve(family_ownerships().size());
        for (const FamilyBuildingOwnership &edge : family_ownerships()) {
            if (!merged_ownerships.empty() &&
                merged_ownerships.back().building_handle == edge.building_handle &&
                merged_ownerships.back().family_handle == edge.family_handle) {
                merged_ownerships.back().owned_count += edge.owned_count;
                merged_ownerships.back().filled_owner += edge.filled_owner;
            } else {
                merged_ownerships.push_back(edge);
            }
        }
        family_ownerships().swap(merged_ownerships);
    }
    const auto ownership_sanitize_started = Clock::now();
    sanitize_family_ownership_edges();
    EconomyCostProbe::record("family.rebuild.ownership_sanitize", _current_day.get(),
                             elapsed_ms(ownership_sanitize_started));

    _family_owned_offsets.assign(families_store().active.size() + 1, 0);
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        int32_t family = -1;
        if (families_store().valid_handle(edge.family_handle, family))
            ++_family_owned_offsets[static_cast<size_t>(family) + 1];
    }
    for (size_t i = 0; i + 1 < _family_owned_offsets.size(); ++i)
        _family_owned_offsets[i + 1] += _family_owned_offsets[i];
    _family_owned_edge_indices.assign(family_ownerships().size(), -1);
    std::vector<int32_t> family_owned_cursor(_family_owned_offsets.begin(),
                                              _family_owned_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(family_ownerships().size()); ++i) {
        int32_t family = -1;
        if (families_store().valid_handle(family_ownerships().read_at(i, __FILE__, __LINE__).family_handle, family))
            _family_owned_edge_indices[family_owned_cursor[family]++] = i;
    }

    EconomyCostProbe::record("family.rebuild.ownership_block", _current_day.get(),
                             elapsed_ms(ownership_started));
    _rebuild_family_ownership_ms += elapsed_ms(ownership_started);
    const auto csr_started = Clock::now();
    _family_cohort_offsets.assign(population_store().active.size() + 1, 0);
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        int32_t slot = -1;
        if (population_store().valid_handle(edge.cohort_handle, slot))
            ++_family_cohort_offsets[static_cast<size_t>(slot) + 1];
    }
    for (size_t i = 0; i + 1 < _family_cohort_offsets.size(); ++i)
        _family_cohort_offsets[i + 1] += _family_cohort_offsets[i];
    _family_cohort_edge_indices.assign(family_memberships().size(), -1);
    std::vector<int32_t> cohort_cursor(_family_cohort_offsets.begin(),
                                       _family_cohort_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(family_memberships().size()); ++i) {
        int32_t slot = -1;
        if (population_store().valid_handle(family_memberships()[i].cohort_handle, slot))
            _family_cohort_edge_indices[cohort_cursor[slot]++] = i;
    }

    _family_building_offsets.assign(building_count() + 1, 0);
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        const auto it = building_by_handle.find(edge.building_handle);
        if (it != building_by_handle.end())
            ++_family_building_offsets[static_cast<size_t>(it->second) + 1];
    }
    for (size_t i = 0; i + 1 < _family_building_offsets.size(); ++i)
        _family_building_offsets[i + 1] += _family_building_offsets[i];
    _family_building_edge_indices.assign(family_ownerships().size(), -1);
    std::vector<int32_t> building_cursor(_family_building_offsets.begin(),
                                         _family_building_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(family_ownerships().size()); ++i) {
        const auto it = building_by_handle.find(family_ownerships().read_at(i, __FILE__, __LINE__).building_handle);
        if (it != building_by_handle.end())
            _family_building_edge_indices[building_cursor[it->second]++] = i;
    }

    _rebuild_family_csr_ms += elapsed_ms(csr_started);
    const auto cell_index_started = Clock::now();
    std::vector<std::pair<int32_t, int32_t>> cell_family;
    cell_family.reserve(family_memberships().size());
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        int32_t slot = -1, family = -1;
        if (!population_store().valid_handle(edge.cohort_handle, slot) ||
            !families_store().valid_handle(edge.family_handle, family)) continue;
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        if (cell >= 0) cell_family.emplace_back(cell, family);
    }
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        int32_t family = -1;
        const auto building = building_by_handle.find(edge.building_handle);
        if (!families_store().valid_handle(edge.family_handle, family) ||
            building == building_by_handle.end()) continue;
        const int32_t cell = buildings_store().cell[building->second];
        if (cell >= 0) cell_family.emplace_back(cell, family);
    }
    std::sort(cell_family.begin(), cell_family.end());
    cell_family.erase(std::unique(cell_family.begin(), cell_family.end()),
                      cell_family.end());
    _family_cell_offsets.assign(static_cast<size_t>(_cell_count.get()) + 1, 0);
    for (const auto &item : cell_family)
        ++_family_cell_offsets[static_cast<size_t>(item.first) + 1];
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell)
        _family_cell_offsets[cell + 1] += _family_cell_offsets[cell];
    _family_cell_indices.clear();
    _family_cell_indices.reserve(cell_family.size());
    for (const auto &item : cell_family) _family_cell_indices.push_back(item.second);
    _rebuild_family_cellindex_ms += elapsed_ms(cell_index_started);
    if (rebuild_derived) {
        rebuild_family_industry_metrics();
        rebuild_family_owned_output_csr();
    }
    _family_csr_edge_count = family_memberships().size();
    _family_indices_dirty = false;
}

void NativeEconomyRuntime::normalize_family_memberships(bool rebuild_derived,
                                                        bool commit_ledger) {
    // This is the one mandatory rebuild per commit. It runs after all
    // population and building changes for the epoch, so it is what prunes
    // edges orphaned by cohort release or building demolition. The later
    // rebuilds in the commit are gated on the dirty flag and rely on it.
    const auto family_normalize_started = Clock::now();
    rebuild_family_indices(rebuild_derived);
    const double family_normalize_rebuild_ms =
        elapsed_ms(family_normalize_started);
    // Membership counts are attributed event by event (births, deaths,
    // moves), so this pass only enforces the down-caps. The claim ledger
    // settles once per commit: business profit by staffed owner posts, the
    // remaining cohort cash delta per capita.
    const auto family_normalize_ledger_started = Clock::now();
    if (commit_ledger) settle_family_claim_ledger();
    const double family_normalize_ledger_ms =
        elapsed_ms(family_normalize_ledger_started);
    const bool has_business = commit_ledger &&
        _family_ledger_business_by_edge.size() == family_memberships().size();
    bool rescale_emptied_edge = false;
    size_t begin = 0;
    while (begin < family_memberships().size()) {
        size_t end = begin + 1;
        while (end < family_memberships().size() &&
               family_memberships()[end].cohort_handle ==
                   family_memberships()[begin].cohort_handle) ++end;
        int32_t slot = -1;
        if (!population_store().valid_handle(
                family_memberships()[begin].cohort_handle, slot)) {
            begin = end;
            continue;
        }
        const int64_t current_pop = std::max<int64_t>(0,
            population_store().population[slot]);
        const int64_t current_funds = std::max<int64_t>(0,
            population_store().funds[slot]);
        int64_t old_people = 0, funds_basis = 0;
        for (size_t i = begin; i < end; ++i) {
            old_people += std::max<int64_t>(0, family_memberships()[i].people);
            funds_basis = std::max(funds_basis, family_memberships()[i].funds_basis);
        }
        const bool cap_people = old_people > current_pop;
        if (cap_people) ++_family_reconcile_corrections;
        int64_t remainder = 0;
        if (commit_ledger) {
            const int64_t business = static_cast<size_t>(slot) <
                    _family_ledger_business_by_slot.size()
                ? _family_ledger_business_by_slot[slot] : 0;
            remainder = saturating_sub(saturating_sub(current_funds, funds_basis,
                _saturation_count), business, _saturation_count);
        }
        int64_t people_prefix = 0, people_done = 0, claim_total = 0;
        for (size_t i = begin; i < end; ++i) {
            // Compute against the read-only row first and only take the mutable
            // lease when a field actually changes: on a steady day most edges
            // keep identical claim/basis values, and the per-column audit
            // preimage borrow dominated this pass.
            const FamilyMembershipEdge &edge_view = family_memberships()[i];
            const int64_t people_before = std::max<int64_t>(0, edge_view.people);
            int64_t next_people = people_before;
            if (cap_people) {
                people_prefix += people_before;
                const int64_t next_target = mul_div_sat(current_pop, people_prefix,
                    old_people, _saturation_count);
                next_people = std::max<int64_t>(0, next_target - people_done);
                people_done = next_target;
            }
            int64_t next_claim = edge_view.cash_claim;
            int64_t next_funds_basis = edge_view.funds_basis;
            int64_t next_population_basis = edge_view.population_basis;
            if (commit_ledger) {
                int64_t claim = std::max<int64_t>(0, edge_view.cash_claim);
                if (has_business)
                    claim = saturating_add(claim, _family_ledger_business_by_edge[i],
                                           _saturation_count);
                if (current_pop > 0 && remainder != 0)
                    claim = saturating_add(claim, mul_div_sat(remainder,
                        people_before, current_pop, _saturation_count),
                        _saturation_count);
                next_claim = claim;
                next_funds_basis = current_funds;
                next_population_basis = current_pop;
            }
            next_claim = next_people > 0
                ? std::max<int64_t>(0, next_claim) : 0;
            claim_total = saturating_add(claim_total, next_claim, _saturation_count);
            const bool changed = next_people != edge_view.people ||
                next_claim != edge_view.cash_claim ||
                next_funds_basis != edge_view.funds_basis ||
                next_population_basis != edge_view.population_basis ||
                edge_view.owner_employed != 0 ||
                edge_view.employee_employed != 0;
            if (changed) {
                auto edge_write = family_memberships().edit_row(i,
                    market_mutation_sink());
                FamilyMembershipEdge &edge = edge_write[0];
                edge.people = next_people;
                edge.cash_claim = next_claim;
                edge.funds_basis = next_funds_basis;
                edge.population_basis = next_population_basis;
                edge.owner_employed = 0;
                edge.employee_employed = 0;
            }
            if (people_before > 0 && next_people <= 0) rescale_emptied_edge = true;
        }
        if (claim_total > current_funds) {
            ++_family_ledger_clamps;
            int64_t claim_prefix = 0, claim_done = 0;
            for (size_t i = begin; i < end; ++i) {
                auto edge_write = family_memberships().edit_row(i, market_mutation_sink());
                FamilyMembershipEdge &edge = edge_write[0];
                claim_prefix += edge.cash_claim;
                const int64_t next_claim = mul_div_sat(current_funds, claim_prefix,
                    claim_total, _saturation_count);
                edge.cash_claim = std::max<int64_t>(0, next_claim - claim_done);
                claim_done = next_claim;
            }
        }
        begin = end;
    }
    for (int32_t slot : _family_ledger_touched_slots)
        if (static_cast<size_t>(slot) < _family_ledger_business_by_slot.size())
            _family_ledger_business_by_slot[slot] = 0;
    _family_ledger_touched_slots.clear();
    EconomyCostProbe::record("family.normalize.rebuild_ms", _current_day.get(),
                             family_normalize_rebuild_ms);
    EconomyCostProbe::record("family.normalize.ledger_ms", _current_day.get(),
                             family_normalize_ledger_ms);
    EconomyCostProbe::record("family.normalize.caps_ms", _current_day.get(),
                             elapsed_ms(family_normalize_started) -
                                 family_normalize_rebuild_ms -
                                 family_normalize_ledger_ms);
    // Capping never adds, removes or reorders edges, so the CSR built above
    // stays exact unless an edge was emptied and now has to be pruned.
    if (rescale_emptied_edge) {
        _family_indices_dirty = true;
        rebuild_family_indices(rebuild_derived);
    }
}

int64_t NativeEconomyRuntime::family_people_on_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()))
        return 0;
    int64_t people = 0;
    if (_family_cohort_offsets.size() == population_store().active.size() + 1) {
        for (int32_t p = _family_cohort_offsets[slot];
             p < _family_cohort_offsets[slot + 1]; ++p)
            people += std::max<int64_t>(0, family_memberships()[
                _family_cohort_edge_indices[p]].people);
        return people;
    }
    const uint64_t handle = population_store().handle_for_slot(slot);
    for (const FamilyMembershipEdge &edge : family_memberships())
        if (edge.cohort_handle == handle)
            people += std::max<int64_t>(0, edge.people);
    return people;
}

int64_t NativeEconomyRuntime::family_owned_owner_slots_in_cell(
        int32_t family_index, int32_t cell) const {
    if (family_index < 0 || cell < 0 ||
        family_index >= static_cast<int32_t>(families_store().active.size()) ||
        families_store().active[family_index] == 0)
        return 0;
    const uint64_t handle = families_store().handle_for_index(family_index);
    int64_t slots = 0;
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        if (edge.family_handle != handle) continue;
        const int32_t building = building_index_for_handle(edge.building_handle);
        if (building < 0) continue;
        const auto group = building_view(static_cast<size_t>(building));
        if (group.cell != cell || group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
        int64_t sat = 0;
        slots = saturating_add(slots, saturating_mul(std::max<int64_t>(0,
            edge.owned_count),
            std::max<int64_t>(0, _building_types[group.type_id]
                .owner_slots_per_building), sat), sat);
    }
    return slots;
}

void NativeEconomyRuntime::add_family_household_people(
        uint64_t family_handle, int32_t slot, int64_t take) {
    if (slot < 0 || take <= 0) return;
    const uint64_t cohort = population_store().handle_for_slot(slot);
    const int64_t current_pop = std::max<int64_t>(0, population_store().population[slot]);
    const int64_t current_funds = std::max<int64_t>(0, population_store().funds[slot]);
    collect_family_edges_for_cohort(slot, _family_edge_scratch);
    int64_t family_people = 0, family_claim = 0, basis = 0;
    int32_t found = -1;
    for (int32_t i : _family_edge_scratch) {
        const FamilyMembershipEdge &edge = family_memberships()[i];
        family_people += std::max<int64_t>(0, edge.people);
        family_claim += std::max<int64_t>(0, edge.cash_claim);
        basis = std::max(basis, edge.funds_basis);
        if (edge.family_handle == family_handle) found = i;
    }
    const int64_t anonymous = std::max<int64_t>(0, current_pop - family_people);
    take = std::min(take, anonymous);
    if (take <= 0) return;
    const int64_t anonymous_cash = std::max<int64_t>(0, current_funds - family_claim);
    const int64_t added_claim = anonymous > 0
        ? mul_div_sat(anonymous_cash, take, anonymous, _saturation_count) : 0;
    if (found >= 0) {
        auto edge_write = family_memberships().edit_row(found, market_mutation_sink());
        FamilyMembershipEdge &edge = edge_write[0];
        edge.people = saturating_add(edge.people, take, _saturation_count);
        edge.cash_claim = saturating_add(edge.cash_claim, added_claim,
            _saturation_count);
        return;
    }
    FamilyMembershipEdge membership;
    membership.family_handle = family_handle;
    membership.cohort_handle = cohort;
    membership.people = take;
    membership.cash_claim = added_claim;
    membership.population_basis = current_pop;
    membership.funds_basis = _family_edge_scratch.empty() ? current_funds : basis;
    family_memberships().push_back(membership);
    _family_indices_dirty = true;
}

void NativeEconomyRuntime::absorb_family_households() {
    if (_family_runtime_mode.get() != 2 || families_store().active_count <= 0) return;
    struct CellFamily {
        int32_t family = -1;
        int32_t cell = -1;
        uint64_t handle = 0;
        int64_t slots = 0;
        int64_t people = 0;
    };
    // Only same-day founders draw a household here; established branches
    // grow through births and recruit_family_dependents.
    const int64_t today = std::max<int64_t>(0, _current_day.get());
    std::vector<CellFamily> rows;
    for (int32_t family = 0; family < static_cast<int32_t>(families_store().active.size());
         ++family) {
        if (families_store().active[family] == 0 ||
            families_store().founded_day[family] != today) continue;
        const uint64_t handle = families_store().handle_for_index(family);
        for (const FamilyBuildingOwnership &edge : family_ownerships()) {
            if (edge.family_handle != handle || edge.owned_count <= 0) continue;
            const int32_t building = building_index_for_handle(edge.building_handle);
            if (building < 0) continue;
            const int32_t cell = buildings_store().cell[building];
            if (cell < 0) continue;
            size_t index = rows.size();
            for (size_t i = 0; i < rows.size(); ++i) {
                if (rows[i].family == family && rows[i].cell == cell) {
                    index = i;
                    break;
                }
            }
            if (index == rows.size())
                rows.push_back({family, cell, handle, 0, 0});
        }
    }
    if (rows.empty()) return;
    for (CellFamily &row : rows)
        row.slots = family_owned_owner_slots_in_cell(row.family, row.cell);
    std::vector<int64_t> cell_population(
        static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    std::vector<int64_t> cell_family_people(
        static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    std::vector<uint8_t> cell_counted(
        static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    for (const CellFamily &row : rows) {
        if (row.cell < 0 || row.cell >= _cell_count.get() || cell_counted[row.cell] != 0)
            continue;
        cell_counted[row.cell] = 1;
        population_store().for_each_in_cell(row.cell, [&](int32_t slot) {
            cell_population[row.cell] += std::max<int64_t>(0,
                population_store().population[slot]);
        });
    }
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        int32_t family = -1, slot = -1;
        if (!families_store().valid_handle(edge.family_handle, family) ||
            !population_store().valid_handle(edge.cohort_handle, slot)) continue;
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        const int64_t people = std::max<int64_t>(0, edge.people);
        if (cell >= 0 && cell < _cell_count.get())
            cell_family_people[cell] += people;
        for (CellFamily &row : rows) {
            if (row.family == family && row.cell == cell)
                row.people += people;
        }
    }
    std::sort(rows.begin(), rows.end(), [&](const CellFamily &a,
            const CellFamily &b) {
        const int64_t a_id = a.family >= 0 ? families_store().stable_id[a.family] : 0;
        const int64_t b_id = b.family >= 0 ? families_store().stable_id[b.family] : 0;
        return std::tie(a.cell, a_id, a.family) < std::tie(b.cell, b_id, b.family);
    });
    for (CellFamily &row : rows) {
        if (row.slots <= 0) continue;
        int64_t need = std::max<int64_t>(0,
            family_household_target_people(row.slots) - row.people);
        if (row.cell >= 0 && row.cell < _cell_count.get()) {
            const int64_t room = std::max<int64_t>(0, mul_div_sat(
                cell_population[row.cell], FAMILY_TARGET_SHARE_TOTAL_Q16, Q16_ONE,
                _saturation_count) - cell_family_people[row.cell]);
            need = std::min(need, room);
        }
        if (need <= 0) continue;
        std::vector<int32_t> owner_signatures;
        for (const FamilyBuildingOwnership &edge : family_ownerships()) {
            if (edge.family_handle != row.handle) continue;
            const int32_t building = building_index_for_handle(edge.building_handle);
            if (building < 0 || buildings_store().cell[building] != row.cell) continue;
            const int32_t signature = buildings_store().owner_signature_id[building];
            if (signature < 0) continue;
            if (std::find(owner_signatures.begin(), owner_signatures.end(),
                    signature) == owner_signatures.end())
                owner_signatures.push_back(signature);
        }
        std::sort(owner_signatures.begin(), owner_signatures.end());
        auto absorb_slot = [&](int32_t slot) {
            if (need <= 0 || slot < 0) return;
            int64_t claimed = 0;
            const uint64_t cohort = population_store().handle_for_slot(slot);
            for (const FamilyMembershipEdge &edge : family_memberships())
                if (edge.cohort_handle == cohort)
                    claimed += std::max<int64_t>(0, edge.people);
            const int64_t available = std::max<int64_t>(0,
                population_store().population[slot] - claimed - 1);
            const int64_t take = std::min(need, available);
            if (take <= 0) return;
            add_family_household_people(row.handle, slot, take);
            need -= take;
            row.people += take;
            if (row.cell >= 0 && row.cell < _cell_count.get())
                cell_family_people[row.cell] += take;
        };
        population_store().for_each_in_cell(row.cell, [&](int32_t slot) {
            if (need <= 0) return;
            const int32_t signature = population_store().signature_id[slot];
            if (std::binary_search(owner_signatures.begin(),
                    owner_signatures.end(), signature))
                absorb_slot(slot);
        });
    }
}

void NativeEconomyRuntime::attribute_family_owner_employment_for_cell(
        int32_t cell) {
    if (_family_runtime_mode.get() != 2 || cell < 0 ||
        cell >= _cell_count.get() || _family_building_offsets.size() !=
            building_count() + 1) return;
    const int32_t first = _building_cell_offsets[cell];
    const int32_t last = _building_cell_offsets[cell + 1];
    const bool trace_attribution = cell == _inspector_trace_cell;
    if (trace_attribution) _family_clamp_traces.clear();
    thread_local std::vector<std::pair<int32_t, int64_t>> member_seats;
    member_seats.clear();
    for (int32_t g = first; g < last; ++g) {
        {
            const auto view = building_view(static_cast<size_t>(g));
            if (view.count <= 0 || view.owner_signature_id < 0) continue;
        }
        auto group = building_at(static_cast<size_t>(g));
        const int32_t ob = _family_building_offsets[g];
        const int32_t oe = _family_building_offsets[g + 1];
        const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
        if (owner_slot < 0) {
            // No local cohort can operate this group, so both the owner fill
            // and every family's share of it are zero.
            group.filled_owner = 0;
            for (int32_t p = ob; p < oe; ++p) {
                auto ownership_write = family_ownerships().edit_row(_family_building_edge_indices[p], market_mutation_sink());
                ownership_write[0].filled_owner = 0;
            }
            if (trace_attribution)
                _family_clamp_traces.push_back({g, 0, 0, 0, 0, 0, 0});
            continue;
        }
        const int64_t cohort_population = std::max<int64_t>(0,
            population_store().population[owner_slot]);
        // Owner seats were already bounded by the profession clamp above, which
        // is the only real constraint: a group cannot seat more proprietors
        // than the profession has people. Family membership is an attribution
        // overlay on that result, never an admission rule -- gating seats by
        // membership made surplus members unemployable and left them shed and
        // rehired every epoch, burning the whole cell mobility budget.
        // A family staffs its own posts with its own members first; members
        // already seated in another group of the same cohort are not reused.
        const int64_t filled = std::max<int64_t>(0, group.filled_owner);
        const int32_t cb = static_cast<size_t>(owner_slot) + 1 <
                _family_cohort_offsets.size() ? _family_cohort_offsets[owner_slot] : 0;
        const int32_t ce = static_cast<size_t>(owner_slot) + 1 <
                _family_cohort_offsets.size() ? _family_cohort_offsets[owner_slot + 1] : 0;
        int64_t family_people = 0;
        int64_t family_owned = 0;
        int64_t remaining_filled = filled;
        for (int32_t p = ob; p < oe; ++p) {
            auto ownership_write = family_ownerships().edit_row(_family_building_edge_indices[p], market_mutation_sink());
            FamilyBuildingOwnership &ownership = ownership_write[0];
            ownership.owned_count = std::min(std::max<int64_t>(0,
                ownership.owned_count), std::max<int64_t>(0,
                    group.count - family_owned));
            family_owned += ownership.owned_count;
            int32_t member_edge = -1;
            int64_t members = 0;
            for (int32_t q = cb; q < ce; ++q) {
                const int32_t candidate = _family_cohort_edge_indices[q];
                if (family_memberships()[candidate].family_handle ==
                        ownership.family_handle) {
                    member_edge = candidate;
                    members = std::max<int64_t>(0,
                        family_memberships()[candidate].people);
                    break;
                }
            }
            family_people = saturating_add(family_people, members, _saturation_count);
            int64_t *used = nullptr;
            if (member_edge >= 0) {
                for (auto &item : member_seats)
                    if (item.first == member_edge) used = &item.second;
                if (used == nullptr) {
                    member_seats.emplace_back(member_edge, 0);
                    used = &member_seats.back().second;
                }
            }
            const int64_t posts = saturating_mul(ownership.owned_count,
                std::max<int64_t>(0, _building_types[group.type_id].owner_slots_per_building),
                _saturation_count);
            const int64_t seat = used == nullptr ? 0 : std::min({posts,
                std::max<int64_t>(0, members - *used), remaining_filled});
            ownership.filled_owner = std::max<int64_t>(0, seat);
            if (used != nullptr) *used += ownership.filled_owner;
            remaining_filled -= ownership.filled_owner;
            _family_owner_jobs_filled += ownership.filled_owner;
            const int64_t target = posts;
            _family_owner_jobs_vacant += std::max<int64_t>(0,
                target - ownership.filled_owner);
        }
        if (trace_attribution)
            _family_clamp_traces.push_back({g, family_owned, family_people,
                                            std::max<int64_t>(0,
                                                cohort_population - family_people),
                                            cohort_population,
                                            filled, group.filled_owner});
    }
}

void NativeEconomyRuntime::sanitize_family_membership_edge(
        FamilyMembershipEdge &edge) {
    if (edge.people < 0) edge.people = 0;
    if (edge.cash_claim < 0) edge.cash_claim = 0;
    if (edge.population_basis < edge.people)
        edge.population_basis = edge.people;
    if (edge.funds_basis < 0) edge.funds_basis = 0;
    if (edge.owner_employed < 0) edge.owner_employed = 0;
    if (edge.employee_employed < 0) edge.employee_employed = 0;
    if (edge.owner_employed > edge.people)
        edge.owner_employed = edge.people;
    if (edge.owner_employed + edge.employee_employed > edge.people)
        edge.employee_employed = edge.people - edge.owner_employed;
}

void NativeEconomyRuntime::sanitize_family_ownership_edges() {
    if (family_ownerships().empty()) return;
    const std::unordered_map<uint64_t, int32_t> &building_by_handle =
        building_handle_index();
    std::vector<int64_t> claimed(building_count(), 0);
    for (size_t edge_row = 0; edge_row < family_ownerships().size(); ++edge_row) {
        const FamilyBuildingOwnership &edge_view = family_ownerships()[edge_row];
        int64_t next_owned = edge_view.owned_count;
        int64_t next_filled = edge_view.filled_owner;
        const auto found = building_by_handle.find(edge_view.building_handle);
        if (found == building_by_handle.end()) {
            next_owned = 0;
            next_filled = 0;
        } else {
            const size_t group = static_cast<size_t>(found->second);
            const auto building = building_view(static_cast<size_t>(group));
            next_owned = std::clamp<int64_t>(edge_view.owned_count, 0,
                std::max<int64_t>(0, building.count - claimed[group]));
            claimed[group] += next_owned;
            int64_t capacity_sat = 0;
            const int64_t owner_capacity = building.type_id >= 0 &&
                building.type_id < static_cast<int32_t>(_building_types.size())
                ? saturating_mul(next_owned, std::max<int64_t>(0,
                    _building_types[static_cast<size_t>(building.type_id)]
                        .owner_slots_per_building), capacity_sat)
                : 0;
            next_filled = std::clamp<int64_t>(edge_view.filled_owner, 0,
                capacity_sat != 0 ? 0 : owner_capacity);
        }
        if (next_owned == edge_view.owned_count &&
            next_filled == edge_view.filled_owner) continue;
        auto edge_write = family_ownerships().edit_row(edge_row,
            market_mutation_sink());
        edge_write[0].owned_count = next_owned;
        edge_write[0].filled_owner = next_filled;
    }
    family_ownerships().erase_if( [](const FamilyBuildingOwnership &edge) {
            return edge.owned_count <= 0;
        });
}

void NativeEconomyRuntime::update_family_employment_attribution() {
    for (size_t edge_row = 0; edge_row < family_memberships().size(); ++edge_row) {
        const FamilyMembershipEdge &edge_view = family_memberships()[edge_row];
        if (edge_view.owner_employed == 0 && edge_view.employee_employed == 0)
            continue;
        auto edge_write = family_memberships().edit_row(edge_row,
            market_mutation_sink());
        edge_write[0].owner_employed = 0;
        edge_write[0].employee_employed = 0;
    }
    if (_family_building_offsets.size() != building_count() + 1 ||
        _family_cohort_offsets.size() != population_store().active.size() + 1)
        return;
    for (int32_t group_index = 0;
         group_index < static_cast<int32_t>(building_count()); ++group_index) {
        const auto group = building_view(static_cast<size_t>(group_index));
        const int32_t slot = find_cohort_slot(group.cell,
                                              group.owner_signature_id);
        if (slot < 0) continue;
        for (int32_t ownership_pos = _family_building_offsets[group_index];
             ownership_pos < _family_building_offsets[group_index + 1];
             ++ownership_pos) {
            const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
                _family_building_edge_indices[ownership_pos], __FILE__, __LINE__);
            for (int32_t p = _family_cohort_offsets[slot];
                 p < _family_cohort_offsets[slot + 1]; ++p) {
                auto edge_write = family_memberships().edit_row(
                    _family_cohort_edge_indices[p], market_mutation_sink());
                FamilyMembershipEdge &edge = edge_write[0];
                if (edge.family_handle == ownership.family_handle) {
                    edge.owner_employed = std::min(edge.people,
                        saturating_add(edge.owner_employed,
                            ownership.filled_owner, _saturation_count));
                    break;
                }
            }
        }
    }
    size_t begin = 0;
    while (begin < family_memberships().size()) {
        size_t end = begin + 1;
        while (end < family_memberships().size() &&
               family_memberships()[end].cohort_handle ==
                   family_memberships()[begin].cohort_handle) ++end;
        int32_t slot = -1;
        if (population_store().valid_handle(
                family_memberships()[begin].cohort_handle, slot)) {
            // Owner seats on anonymous posts are shared by everyone not
            // already seated on a family post, in proportion.
            int64_t family_seated = 0;
            for (size_t i = begin; i < end; ++i)
                family_seated += family_memberships()[i].owner_employed;
            const int64_t anonymous_seats = std::max<int64_t>(0,
                population_store().owner_employed[slot] - family_seated);
            const int64_t free_population = std::max<int64_t>(1,
                population_store().population[slot] - family_seated);
            if (anonymous_seats > 0) {
                int64_t free_prefix = 0, seated = 0;
                for (size_t i = begin; i < end; ++i) {
                    auto edge_write = family_memberships().edit_row(i, market_mutation_sink());
                    FamilyMembershipEdge &edge = edge_write[0];
                    free_prefix += std::max<int64_t>(0, edge.people - edge.owner_employed);
                    const int64_t next = mul_div_sat(anonymous_seats,
                        std::min(free_prefix, free_population), free_population,
                        _saturation_count);
                    edge.owner_employed = std::min(edge.people, saturating_add(
                        edge.owner_employed, std::max<int64_t>(0, next - seated),
                        _saturation_count));
                    seated = next;
                }
            }
            const int64_t cohort_employee = std::max<int64_t>(0,
                population_store().employee_employed[slot]);
            const int64_t cohort_capacity = std::max<int64_t>(1,
                population_store().population[slot] -
                population_store().owner_employed[slot]);
            int64_t prefix = 0, distributed = 0;
            for (size_t i = begin; i < end; ++i) {
                auto edge_write = family_memberships().edit_row(i, market_mutation_sink());
                FamilyMembershipEdge &edge = edge_write[0];
                const int64_t capacity = std::max<int64_t>(0,
                    edge.people - edge.owner_employed);
                prefix += capacity;
                const int64_t next = mul_div_sat(cohort_employee,
                    std::min(prefix, cohort_capacity), cohort_capacity,
                    _saturation_count);
                edge.employee_employed = std::max<int64_t>(0,
                    next - distributed);
                distributed = next;
                sanitize_family_membership_edge(edge);
            }
        } else {
            for (size_t i = begin; i < end; ++i) {
                auto edge_write = family_memberships().edit_row(i, market_mutation_sink());
                sanitize_family_membership_edge(edge_write[0]);
            }
        }
        begin = end;
    }
}

int32_t NativeEconomyRuntime::create_family_for_building(
        int32_t cell, int32_t building_index, int64_t founders,
        int64_t filled_owner, bool allow_small_starter,
        const FamilyFoundingIdentity *identity) {
    if (cell < 0 || cell >= _cell_count.get() || building_index < 0 ||
        building_index >= static_cast<int32_t>(building_count()) || founders <= 0 ||
        (!allow_small_starter && founders < _family_min_founder_people.get())) return -1;
    const auto group = building_view(static_cast<size_t>(building_index));
    if (group.cell != cell || group.count <= 0 || group.modifier_handle == 0)
        return -1;
    const int32_t slot = find_cohort_slot(cell, group.owner_signature_id);
    if (slot < 0 || population_store().population[slot] < founders) return -1;
    const int64_t identity_day = std::max<int64_t>(0, _current_day.get());
    const int32_t family_index = families_store().allocate();
    reset_family_policy_factors(family_index);
    const uint64_t family_handle = families_store().handle_for_index(family_index);
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(identity_day));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(cell));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(family_index));
    if (identity != nullptr && identity->stable_id > 0)
        hash = static_cast<uint64_t>(identity->stable_id);
    int64_t stable_id = identity != nullptr && identity->stable_id > 0
        ? identity->stable_id
        : static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
    for (uint64_t probe = 1;
         _family_stable_ids.count(stable_id) != 0; ++probe) {
        stable_id = static_cast<int64_t>((trace_hash_mix(hash, probe) &
            0x7fffffffffffffffULL) | 1ULL);
    }
    families_store().stable_id.write_scalar(family_index, stable_id, market_mutation_sink());
    _family_stable_ids.insert(stable_id);
    const int32_t founder_ethnicity = _signatures[group.owner_signature_id].ethnicity_id;
    const int32_t culture_group = founder_ethnicity >= 0 &&
        founder_ethnicity < static_cast<int32_t>(_ethnicity_culture_group_ids.size())
        ? _ethnicity_culture_group_ids[founder_ethnicity] : 0;
    int32_t surname = 0;
    if (identity != nullptr && identity->surname_id >= 0 &&
        identity->surname_id < static_cast<int32_t>(_family_surname_weights.size())) {
        surname = identity->surname_id;
    } else {
        int64_t total_weight = 0;
        for (size_t i = 0; i < _family_surname_weights.size(); ++i)
            if (_family_surname_culture_group_ids[i] == culture_group)
                total_weight += _family_surname_weights[i];
        int64_t roll = static_cast<int64_t>(trace_hash_mix(
            trace_hash_mix(hash, static_cast<uint64_t>(culture_group)),
            0x5355524eULL) % static_cast<uint64_t>(std::max<int64_t>(1, total_weight)));
        for (int32_t candidate = 0; candidate < static_cast<int32_t>(_family_surname_weights.size()); ++candidate) {
            if (_family_surname_culture_group_ids[candidate] != culture_group) continue;
            if (roll < _family_surname_weights[candidate]) { surname = candidate; break; }
            roll -= _family_surname_weights[candidate];
        }
    }
    uint32_t disambiguator = 0;
    // Only same-surname families can shift the disambiguator, so consult that
    // bucket rather than the whole family table. Entries are validated on read
    // because retirement leaves them behind until the bucket is compacted.
    if (surname >= 0) {
        if (static_cast<size_t>(surname) >= _family_surname_members.size())
            _family_surname_members.resize(static_cast<size_t>(surname) + 1);
        std::vector<int32_t> &bucket =
            _family_surname_members[static_cast<size_t>(surname)];
        _scan_steps_family_linear += static_cast<int64_t>(bucket.size());
        note_scan_steps(static_cast<int64_t>(bucket.size()));
        size_t kept = 0;
        for (size_t b = 0; b < bucket.size(); ++b) {
            const int32_t i = bucket[b];
            if (i == family_index || i < 0 ||
                i >= static_cast<int32_t>(families_store().active.size()) ||
                families_store().active[i] == 0 || families_store().surname_id[i] != surname)
                continue;
            bucket[kept++] = i;
            disambiguator = std::max(disambiguator,
                families_store().surname_disambiguator[i] + 1U);
        }
        bucket.resize(kept);
        bucket.push_back(family_index);
    }
    families_store().surname_id.write_scalar(family_index, surname, market_mutation_sink());
    families_store().surname_disambiguator.write_scalar(family_index, disambiguator, market_mutation_sink());
    families_store().founded_day.write_scalar(family_index, identity_day, market_mutation_sink());
    families_store().home_cell.write_scalar(family_index, cell, market_mutation_sink());
    families_store().origin_cell.write_scalar(family_index, cell, market_mutation_sink());
    families_store().origin_ethnicity.write_scalar(family_index, founder_ethnicity, market_mutation_sink());
    families_store().culture_group_id.write_scalar(family_index, culture_group, market_mutation_sink());
    families_store().split_sequence.write_scalar(family_index, 0, market_mutation_sink());
    if (allow_small_starter)
        families_store().flags.write_scalar(family_index, families_store().flags[family_index] | (FAMILY_FLAG_STARTER), market_mutation_sink());
    FamilyMembershipEdge membership;
    membership.family_handle = family_handle;
    membership.cohort_handle = population_store().handle_for_slot(slot);
    membership.people = founders;
    membership.cash_claim = population_store().population[slot] > 0
        ? mul_div_sat(population_store().funds[slot], founders,
            population_store().population[slot], _saturation_count) : 0;
    membership.population_basis = population_store().population[slot];
    membership.funds_basis = family_ledger_basis_for_slot(slot);
    membership.owner_employed = std::clamp<int64_t>(filled_owner, 0, founders);
    family_memberships().push_back(membership);
    const int64_t founder_owner_capacity = group.type_id >= 0 &&
        group.type_id < static_cast<int32_t>(_building_types.size())
        ? std::max<int64_t>(0, _building_types[static_cast<size_t>(group.type_id)]
            .owner_slots_per_building) : 0;
    family_ownerships().push_back({family_handle, group.modifier_handle, 1,
        std::min(membership.owner_employed, founder_owner_capacity)});
    if (identity != nullptr && identity->trait_ids != nullptr &&
        identity->trait_strength_q16 != nullptr &&
        identity->trait_ids->size() == identity->trait_strength_q16->size()) {
        bool pushed = false;
        for (size_t i = 0; i < identity->trait_ids->size(); ++i) {
            const int32_t trait_id = (*identity->trait_ids)[i];
            if (trait_id < 0 || trait_id >= static_cast<int32_t>(_family_trait_ids.size()))
                continue;
            family_trait_rolls().push_back({family_handle, trait_id,
                (*identity->trait_strength_q16)[i], 1});
            pushed = true;
        }
        family_trait_rolls().sort(
            [](const FamilyTraitRoll &a, const FamilyTraitRoll &b) {
                return std::tie(a.family_handle, a.trait_id) <
                    std::tie(b.family_handle, b.trait_id);
            });
        if (pushed) mark_family_behavior_cache_dirty(FAMILY_BEHAVIOR_DIRTY_TRAITS);
    } else {
        assign_core_family_traits(family_index);
    }
    if (identity != nullptr && identity->effect_id >= 0) {
        auto it = std::lower_bound(_family_founding_effects.begin(),
            _family_founding_effects.end(), std::make_pair(stable_id,
                std::numeric_limits<int32_t>::min()));
        if (it != _family_founding_effects.end() && it->first == stable_id)
            _family_founding_effects.write_record(it - _family_founding_effects.begin(),
                std::make_pair(stable_id, identity->effect_id));
        else
            _family_founding_effects.insert(it, {stable_id, identity->effect_id});
    }
    ++_families_formed;
    _family_indices_dirty = true;
    return family_index;
}

} // namespace pk
