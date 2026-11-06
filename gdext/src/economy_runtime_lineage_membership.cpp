#include "economy_cost_probe.h"
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

int64_t NativeEconomyRuntime::family_effect_metric_revision(int32_t phase) const {
    const int64_t day = std::max<int64_t>(0, _current_day.get());
    constexpr int64_t PHASE_COUNT = 4;
    if (day >= (std::numeric_limits<int64_t>::max() - PHASE_COUNT) /
                   PHASE_COUNT)
        return std::numeric_limits<int64_t>::max();
    return (day + 1) * PHASE_COUNT + std::clamp<int32_t>(phase, 0, 3);
}

void NativeEconomyRuntime::refresh_family_effect_metrics_for_branch(
        uint64_t branch_handle, int64_t revision, const MetricMask &requested_mask) {
    const auto found = _family_effect_instances_by_branch.find(branch_handle);
    if (found == _family_effect_instances_by_branch.end()) return;
    const std::vector<int64_t> instance_ids = found->second;
    for (const int64_t instance_id : instance_ids) {
        const auto indexed = _family_effect_binding_by_instance.find(instance_id);
        if (indexed == _family_effect_binding_by_instance.end()) continue;
        publish_family_effect_metrics(_family_effect_bindings[indexed->second],
                                      revision, requested_mask);
    }
}

void NativeEconomyRuntime::refresh_family_effect_metrics_for_cell(
        int32_t cell, int64_t revision, const MetricMask &requested_mask) {
    const auto found = _family_effect_instances_by_cell.find(cell);
    if (found == _family_effect_instances_by_cell.end()) return;
    const std::vector<int64_t> instance_ids = found->second;
    for (const int64_t instance_id : instance_ids) {
        const auto indexed = _family_effect_binding_by_instance.find(instance_id);
        if (indexed == _family_effect_binding_by_instance.end()) continue;
        publish_family_effect_metrics(_family_effect_bindings[indexed->second],
                                      revision, requested_mask);
    }
}

int64_t NativeEconomyRuntime::family_household_target_people(
        int64_t owner_slots) const {
    int64_t sat = 0;
    const int64_t slots = std::max<int64_t>(1, owner_slots);
    const int64_t target = saturating_mul(slots,
        std::max(1, _family_household_people_per_owner_slot), sat);
    return std::clamp<int64_t>(target, slots,
        std::max<int64_t>(slots, _family_household_max_people));
}

int64_t NativeEconomyRuntime::family_household_people_for_slot(
        int32_t slot, int64_t owner_slots) const {
    if (slot < 0 || owner_slots <= 0) return std::max<int64_t>(0, owner_slots);
    const int64_t available = std::max<int64_t>(0,
        population_store().population[slot] - family_people_on_slot(slot));
    if (available <= owner_slots) return available;
    const int64_t target = family_household_target_people(owner_slots);
    return std::clamp<int64_t>(target, owner_slots, available);
}

void NativeEconomyRuntime::transfer_family_branch(int32_t parent, int32_t child, int32_t cell) {
    const uint64_t parent_handle = families_store().handle_for_index(parent);
    const uint64_t child_handle = families_store().handle_for_index(child);
    // Transfers only rewrite existing rows; the CSR row positions remain valid
    // until the structural rebuild, including several splits in one commit.
    for (int32_t p = _family_member_offsets[parent]; p < _family_member_offsets[parent + 1]; ++p) {
        auto edge_write = family_memberships().edit_row(_family_member_edge_indices[p], market_mutation_sink());
        auto &edge = edge_write[0];
        int32_t slot = -1;
        if (edge.family_handle == parent_handle && edge.people > 0 &&
            population_store().valid_handle(edge.cohort_handle, slot) &&
            population_store().page_cell[slot / COHORT_PAGE_SIZE] == cell)
            edge.family_handle = child_handle;
    }
    for (int32_t p = _family_owned_offsets[parent]; p < _family_owned_offsets[parent + 1]; ++p) {
        auto ownership_write = family_ownerships().edit_row(_family_owned_edge_indices[p], market_mutation_sink());
        auto &ownership = ownership_write[0];
        const int32_t group = building_index_for_handle(ownership.building_handle);
        if (ownership.family_handle == parent_handle && ownership.owned_count > 0 &&
            group >= 0 && buildings_store().cell[group] == cell)
            ownership.family_handle = child_handle;
    }
    const bool person_csr = static_cast<size_t>(parent + 1) < _person_family_offsets.size();
    const int32_t begin = person_csr ? _person_family_offsets[parent] : 0;
    const int32_t end = person_csr ? _person_family_offsets[parent + 1]
        : static_cast<int32_t>(persons_store().active.size());
    for (int32_t p = begin; p < end; ++p) {
        const int32_t person = person_csr ? _person_family_indices[p] : p;
        if (persons_store().active[person] == 0 || persons_store().family_handle[person] != parent_handle) continue;
        int32_t slot = -1;
        bool move = population_store().valid_handle(persons_store().cohort_handle[person], slot) &&
            population_store().page_cell[slot / COHORT_PAGE_SIZE] == cell;
        const int32_t group = building_index_for_handle(persons_store().building_handle[person]);
        if (!move && group >= 0 && buildings_store().cell[group] == cell) move = true;
        if (move) persons_store().family_handle.write_scalar(person, child_handle, market_mutation_sink());
    }
    _family_indices_dirty = true;
    _person_indices_dirty = true;
}

} // namespace pk
