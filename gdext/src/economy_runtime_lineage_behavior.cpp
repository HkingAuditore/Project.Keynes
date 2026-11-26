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


int64_t NativeEconomyRuntime::family_population(uint64_t family_handle) const {
    auto add_transit = [&](int64_t total, int64_t &sat) {
        for (size_t i = 0; i < family_expeditions_store().active.size(); ++i) {
            if (family_expeditions_store().active[i] != 0 &&
                family_expeditions_store().family_handle[i] == family_handle)
                total = saturating_add(total,
                    family_expedition_payload_family_people(
                        static_cast<int32_t>(i)),
                    sat);
        }
        return total;
    };
    int32_t family = -1;
    if (families_store().valid_handle(family_handle, family) &&
        _family_member_offsets.size() == families_store().active.size() + 1) {
        int64_t total = 0, sat = 0;
        for (int32_t p = _family_member_offsets[family];
             p < _family_member_offsets[family + 1]; ++p)
            total = saturating_add(total, std::max<int64_t>(0,
                family_memberships()[_family_member_edge_indices[p]].people), sat);
        return add_transit(total, sat);
    }
    int64_t total = 0;
    int64_t sat = 0;
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        if (edge.family_handle == family_handle)
            total = saturating_add(total, std::max<int64_t>(0, edge.people), sat);
    }
    return add_transit(total, sat);
}

int64_t NativeEconomyRuntime::family_cash_claim(uint64_t family_handle) const {
    auto add_transit = [&](int64_t total, int64_t &sat) {
        for (size_t i = 0; i < family_expeditions_store().active.size(); ++i) {
            if (family_expeditions_store().active[i] == 0 ||
                family_expeditions_store().family_handle[i] != family_handle) continue;
            const uint32_t begin = family_expeditions_store().payload_begin[i];
            const uint32_t count = family_expeditions_store().payload_count[i];
            for (uint32_t p = 0; p < count; ++p)
                total = saturating_add(total, std::max<int64_t>(0,
                    family_expedition_payloads()[begin + p].cash_claim), sat);
        }
        return total;
    };
    int32_t family = -1;
    if (families_store().valid_handle(family_handle, family) &&
        _family_member_offsets.size() == families_store().active.size() + 1) {
        int64_t total = 0, sat = 0;
        for (int32_t p = _family_member_offsets[family];
             p < _family_member_offsets[family + 1]; ++p)
            total = saturating_add(total, std::max<int64_t>(0,
                family_memberships()[_family_member_edge_indices[p]].cash_claim), sat);
        return add_transit(total, sat);
    }
    int64_t total = 0;
    int64_t sat = 0;
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        if (edge.family_handle == family_handle)
            total = saturating_add(total, std::max<int64_t>(0, edge.cash_claim), sat);
    }
    return add_transit(total, sat);
}

int64_t NativeEconomyRuntime::family_owned_buildings(uint64_t family_handle) const {
    int32_t family = -1;
    if (families_store().valid_handle(family_handle, family) &&
        _family_owned_offsets.size() == families_store().active.size() + 1) {
        int64_t total = 0, sat = 0;
        for (int32_t p = _family_owned_offsets[family];
             p < _family_owned_offsets[family + 1]; ++p)
            total = saturating_add(total, std::max<int64_t>(0,
                family_ownerships().read_at(_family_owned_edge_indices[p], __FILE__, __LINE__).owned_count), sat);
        return total;
    }
    int64_t total = 0;
    int64_t sat = 0;
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        if (edge.family_handle == family_handle)
            total = saturating_add(total, std::max<int64_t>(0, edge.owned_count), sat);
    }
    return total;
}

void NativeEconomyRuntime::assign_core_family_traits(int32_t family_index) {
    if (family_index < 0 || family_index >= static_cast<int32_t>(
            families_store().active.size()) || families_store().active[family_index] == 0 ||
        _family_trait_ids.empty()) return;
    const uint64_t family_handle = families_store().handle_for_index(family_index);
    const int32_t origin = families_store().origin_cell[family_index];
    const int32_t home = families_store().home_cell[family_index];
    const int32_t tech_cell = origin >= 0 && origin < _cell_count.get() ? origin : home;
    const int32_t origin_cell = origin >= 0 && origin < _cell_count.get()
        ? origin : tech_cell;
    std::vector<int32_t> selected, strengths;
    roll_core_family_traits(static_cast<uint64_t>(
        families_store().stable_id[family_index]), tech_cell, origin_cell,
        selected, strengths);
    for (size_t i = 0; i < selected.size(); ++i)
        family_trait_rolls().push_back({family_handle, selected[i], strengths[i], 1});
    family_trait_rolls().sort(
        [](const FamilyTraitRoll &a, const FamilyTraitRoll &b) {
            return std::tie(a.family_handle, a.trait_id) <
                std::tie(b.family_handle, b.trait_id);
        });
    if (!selected.empty())
        mark_family_behavior_cache_dirty(FAMILY_BEHAVIOR_DIRTY_TRAITS);
}


void NativeEconomyRuntime::sample_effect_metrics(
        int32_t cell, int32_t metric_count, int64_t *out_metrics,
        const MetricMask &metric_mask) const {
    // family_index / branch are -1 by construction: an ideology card is not
    // attached to a family, so a metric that only exists in a family context
    // must read 0 rather than inherit whatever family happened to be nearby.
    fill_family_behavior_metrics(-1, -1, cell, out_metrics, metric_count,
                                 metric_mask);
    // R-3b: the test override belongs HERE, not only in the digest.
    //
    // `set_effect_metric_override_for_test` exists because a headless fixture cannot
    // steer a metric precisely enough to cross a threshold on demand. It was applied
    // by `refresh_effect_input_digest` alone, so the digest and the tag bitset read
    // DIFFERENT epochs: the digest hashed the override while `rebuild_epoch_tag_snapshot`
    // sampled the raw value, which means a fixture that moved the override could flip
    // a revision without ever flipping a tag (and a tag stress test could never make
    // `tag_changes` happen at all). Applying it at the one sampling point makes
    // "what the epoch contains" answer the same question everywhere.
    //
    // Deliberately NOT gated on `metric_mask.test(metric)`: the mask is the set of
    // metrics a TAG ROW named by key, while the override is set by NUMBER. A fixture
    // that overrides metric 13 to move `cell.population` and a tag table that reaches
    // population through a different key would otherwise silently disagree -- the
    // override would be set and never read, and the reported symptom would be "the
    // tag never flipped" rather than "the override was filtered out".
    const std::shared_ptr<const EffectMetricOverrideSet> overrides =
        std::atomic_load_explicit(&_effect_metric_override_snapshot,
            std::memory_order_acquire);
    if (overrides == nullptr || out_metrics == nullptr) return;
    const int32_t limit = std::min(metric_count,
        static_cast<int32_t>(FAMILY_METRIC_COUNT));
    for (int32_t metric = 0; metric < limit; ++metric) {
        const size_t slot = static_cast<size_t>(metric);
        if (overrides->set[slot] == 0) continue;
        out_metrics[slot] = overrides->values[slot];
    }
}

int32_t NativeEconomyRuntime::family_trait_behavior_factor_q16(
        uint64_t family_handle, int32_t axis, int32_t selector_kind,
        int32_t selector_id, int32_t cell) const {
    const uint32_t family_index = static_cast<uint32_t>(family_handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(family_handle >> 32U);
    if (_family_behavior_factor_offsets.size() < 2 ||
        family_index >= _family_behavior_factor_offsets.size() - 1 ||
        family_index >= families_store().generation.size() ||
        families_store().active[family_index] == 0 ||
        families_store().generation[family_index] != generation)
        return Q16_ONE;
    const int32_t begin = _family_behavior_factor_offsets[family_index];
    const int32_t end = _family_behavior_factor_offsets[family_index + 1];
    static const bool linear = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FAMILY_LOOKUP_LINEAR);
        return value && std::strcmp(value, "1") == 0;
    }();
    static const bool verify_index = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FAMILY_LOOKUP_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (!linear) {
        // rebuild_family_behavior_cache 按完整键排序并合并唯一行。查询只可能
        // 命中全局/本格的 exact selector 与职业 class，共最多四行。
        std::array<int32_t, 4> matches{};
        int32_t count = 0;
        const auto first = _family_behavior_factor_rows.begin() + begin;
        const auto last = _family_behavior_factor_rows.begin() + end;
        const auto find = [&](int32_t row_cell, int32_t kind, int32_t id) {
            const auto key = std::make_tuple(row_cell, FAMILY_SCORE_CANDIDATE_WEIGHT,
                axis, kind, id);
            const auto it = std::lower_bound(first, last, key,
                [](const FamilyBehaviorFactorRow &row, const auto &wanted) {
                    return std::tie(row.cell, row.score_term, row.axis,
                        row.selector_kind, row.selector_id) < wanted;
                });
            if (it != last && std::tie(it->cell, it->score_term, it->axis,
                    it->selector_kind, it->selector_id) == key)
                matches[count++] = static_cast<int32_t>(it - _family_behavior_factor_rows.begin());
        };
        const bool has_class = axis == 1 && selector_kind == 0 && selector_id >= 0 &&
            selector_id < static_cast<int32_t>(_profession_class_index.size());
        const auto find_cell = [&](int32_t row_cell) {
            find(row_cell, selector_kind, selector_id);
            if (has_class)
                find(row_cell, FAMILY_BEHAVIOR_SELECTOR_PROFESSION_CLASS,
                    _profession_class_index[static_cast<size_t>(selector_id)]);
        };
        find_cell(-1);
        if (cell >= 0) find_cell(cell);
        // 保持原 CSR 的乘法/截断顺序，而不是按查询顺序合并。
        std::sort(matches.begin(), matches.begin() + count);
        int64_t indexed = Q16_ONE;
        for (int32_t i = 0; i < count; ++i)
            indexed = indexed * _family_behavior_factor_rows[matches[i]].factor_q16 / Q16_ONE;
        const int32_t result = static_cast<int32_t>(std::clamp<int64_t>(indexed, 0, 4 * Q16_ONE));
        if (!verify_index) return result;
        int64_t reference = Q16_ONE;
        for (int32_t row = begin; row < end; ++row) {
            const auto &entry = _family_behavior_factor_rows[row];
            const bool exact = entry.selector_kind == selector_kind && entry.selector_id == selector_id;
            const bool profession_class = has_class &&
                entry.selector_kind == FAMILY_BEHAVIOR_SELECTOR_PROFESSION_CLASS &&
                _profession_class_index[static_cast<size_t>(selector_id)] == entry.selector_id;
            if (entry.score_term == FAMILY_SCORE_CANDIDATE_WEIGHT && entry.axis == axis &&
                    (exact || profession_class) && (entry.cell < 0 || entry.cell == cell))
                reference = reference * entry.factor_q16 / Q16_ONE;
        }
        if (result != static_cast<int32_t>(std::clamp<int64_t>(reference, 0, 4 * Q16_ONE))) {
            std::fprintf(stderr, "[family-factor-index-mismatch] family=%u cell=%d axis=%d\n",
                family_index, cell, axis);
            std::abort();
        }
        return result;
    }
    int64_t factor = Q16_ONE;
    bool found = false;
    for (int32_t row = begin; row < end; ++row) {
        const FamilyBehaviorFactorRow &entry = _family_behavior_factor_rows[
            static_cast<size_t>(row)];
        if (entry.score_term != FAMILY_SCORE_CANDIDATE_WEIGHT) continue;
        if (entry.axis != axis) continue;
        const bool exact_selector = entry.selector_kind == selector_kind &&
            entry.selector_id == selector_id;
        const bool profession_class_selector = axis == 1 &&
            selector_kind == 0 &&
            entry.selector_kind ==
                FAMILY_BEHAVIOR_SELECTOR_PROFESSION_CLASS &&
            selector_id >= 0 && selector_id < static_cast<int32_t>(
                _profession_class_index.size()) &&
            _profession_class_index[static_cast<size_t>(selector_id)] ==
                entry.selector_id;
        if (!exact_selector && !profession_class_selector) continue;
        if (entry.cell >= 0 && entry.cell != cell) continue;
        factor = factor * entry.factor_q16 / Q16_ONE;
        found = true;
    }
    return found ? static_cast<int32_t>(std::clamp<int64_t>(factor, 0, 4 * Q16_ONE))
        : Q16_ONE;
}

int32_t NativeEconomyRuntime::family_behavior_score_term_q16(
        uint64_t family_handle, int32_t cell, int32_t score_term) const {
    if (score_term <= FAMILY_SCORE_CANDIDATE_WEIGHT) return Q16_ONE;
    const uint32_t family_index = static_cast<uint32_t>(family_handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(family_handle >> 32U);
    if (_family_behavior_factor_offsets.size() < 2 ||
        family_index >= _family_behavior_factor_offsets.size() - 1 ||
        family_index >= families_store().generation.size() ||
        families_store().active[family_index] == 0 ||
        families_store().generation[family_index] != generation)
        return Q16_ONE;
    const int32_t begin = _family_behavior_factor_offsets[family_index];
    const int32_t end = _family_behavior_factor_offsets[family_index + 1];
    static const bool linear = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FAMILY_LOOKUP_LINEAR);
        return value && std::strcmp(value, "1") == 0;
    }();
    static const bool verify_index = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FAMILY_LOOKUP_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    int32_t indexed_result = Q16_ONE;
    if (!linear) {
        int64_t indexed = Q16_ONE;
        const auto first = _family_behavior_factor_rows.begin() + begin;
        const auto last = _family_behavior_factor_rows.begin() + end;
        const auto apply_cell = [&](int32_t row_cell) {
            const auto key = std::make_tuple(row_cell, score_term);
            auto it = std::lower_bound(first, last, key,
                [](const FamilyBehaviorFactorRow &row, const auto &wanted) {
                    return std::tie(row.cell, row.score_term) < wanted;
                });
            for (; it != last && it->cell == row_cell && it->score_term == score_term; ++it)
                indexed = indexed * it->factor_q16 / Q16_ONE;
        };
        apply_cell(-1);
        if (cell >= 0) apply_cell(cell);
        indexed_result = static_cast<int32_t>(std::clamp<int64_t>(indexed, 0, 4 * Q16_ONE));
        if (!verify_index) return indexed_result;
    }
    int64_t factor = Q16_ONE;
    bool found = false;
    for (int32_t row = begin; row < end; ++row) {
        const FamilyBehaviorFactorRow &entry = _family_behavior_factor_rows[
            static_cast<size_t>(row)];
        if (entry.score_term != score_term) continue;
        if (entry.cell >= 0 && entry.cell != cell) continue;
        factor = factor * entry.factor_q16 / Q16_ONE;
        found = true;
    }
    const int32_t result = found ? static_cast<int32_t>(std::clamp<int64_t>(factor, 0, 4 * Q16_ONE))
        : Q16_ONE;
    if (!linear && result != indexed_result) {
        std::fprintf(stderr, "[family-score-index-mismatch] family=%u cell=%d term=%d\n",
            family_index, cell, score_term);
        std::abort();
    }
    return result;
}

int32_t NativeEconomyRuntime::family_purchase_pay_factor_q16(
        int32_t cohort_slot) const {
    if (cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            population_store().active.size()) || population_store().active[cohort_slot] == 0 ||
        _family_cohort_offsets.size() != population_store().active.size() + 1)
        return Q16_ONE;
    const int64_t population = std::max<int64_t>(1,
        population_store().population[cohort_slot]);
    int64_t pay = Q16_ONE;
    int64_t sat = 0;
    for (int32_t p = _family_cohort_offsets[cohort_slot];
         p < _family_cohort_offsets[cohort_slot + 1]; ++p) {
        const FamilyMembershipEdge &edge = family_memberships()[
            _family_cohort_edge_indices[p]];
        if (edge.people <= 0 || edge.family_handle == 0) continue;
        int32_t family = -1;
        if (!families_store().valid_handle(edge.family_handle, family)) continue;
        int32_t factor = Q16_ONE;
        if (family >= 0 && family < static_cast<int32_t>(
                _family_purchase_factor_q16.size()))
            factor = _family_purchase_factor_q16[family];
        if (factor >= Q16_ONE) continue;
        const int64_t share = mul_div_sat(edge.people, Q16_ONE, population, sat);
        const int64_t discount = mul_div_sat(share, Q16_ONE - factor, Q16_ONE, sat);
        pay = saturating_sub(pay, discount, sat);
    }
    return static_cast<int32_t>(std::clamp<int64_t>(pay, 0, Q16_ONE));
}

int32_t NativeEconomyRuntime::family_free_building_type_id(
        const Command &cmd) const {
    const int32_t authored = cmd.i32_1;
    if (authored >= 0 && authored < static_cast<int32_t>(_building_types.size()))
        return authored;
    const int32_t from_payload = static_cast<int32_t>(cmd.i64_1);
    if (from_payload >= 0 &&
        from_payload < static_cast<int32_t>(_building_types.size()))
        return from_payload;
    int32_t branch = -1;
    int32_t family = -1;
    if (family_influences().valid_handle(cmd.target_handle, branch) &&
        families_store().valid_handle(family_influences().family_handle[branch], family)) {
        const int32_t cell = family_influences().cell[branch];
        const int64_t count = std::max<int64_t>(1, cmd.i64_0);
        if (family < static_cast<int32_t>(_family_owned_offsets.size()) - 1) {
            const uint64_t family_handle = families_store().handle_for_index(family);
            const auto &by_handle = building_handle_index();
            for (int32_t cursor = _family_owned_offsets[static_cast<size_t>(family)];
                 cursor < _family_owned_offsets[static_cast<size_t>(family) + 1];
                 ++cursor) {
                const int32_t edge_index = _family_owned_edge_indices[
                    static_cast<size_t>(cursor)];
                if (edge_index < 0 || edge_index >= static_cast<int32_t>(
                        family_ownerships().size()))
                    continue;
                const FamilyBuildingOwnership &edge = family_ownerships().read_at(
                    static_cast<size_t>(edge_index), __FILE__, __LINE__);
                if (edge.family_handle != family_handle || edge.owned_count <= 0)
                    continue;
                const auto found = by_handle.find(edge.building_handle);
                if (found == by_handle.end()) continue;
                const auto group = building_view(static_cast<size_t>(found->second));
                if (group.cell != cell || group.count <= 0) continue;
                const int32_t type_id = group.type_id;
                if (type_id >= 0 && type_id < static_cast<int32_t>(_building_types.size()) &&
                    building_available(cell, type_id, true) &&
                    building_constructible(cell, type_id, true) &&
                    evaluate_building_conditions(type_id, cell) &&
                    family_free_building_resources_legal(cell, type_id, count)) {
                    return type_id;
                }
            }
        }
        for (int32_t type_id = 0; type_id < static_cast<int32_t>(_building_types.size()); ++type_id) {
            if (_building_types[type_id].owner_slots_per_building > 0 &&
                building_available(cell, type_id, true) &&
                building_constructible(cell, type_id, true) &&
                evaluate_building_conditions(type_id, cell) &&
                family_free_building_resources_legal(cell, type_id, count))
                return type_id;
        }
    }
    return -1;
}

int32_t NativeEconomyRuntime::family_consumption_factor_q16(
        int32_t cohort_slot, int32_t need_id) const {
    if (cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            population_store().active.size()) || population_store().active[cohort_slot] == 0 ||
        _family_cohort_offsets.size() != population_store().active.size() + 1)
        return Q16_ONE;
    const int64_t population = std::max<int64_t>(1,
        population_store().population[cohort_slot]);
    const int32_t cell = population_store().page_cell[cohort_slot / COHORT_PAGE_SIZE];
    int64_t sat = 0;
    int64_t weighted = saturating_mul(population, Q16_ONE, sat);
    for (int32_t p = _family_cohort_offsets[cohort_slot];
         p < _family_cohort_offsets[cohort_slot + 1]; ++p) {
        const FamilyMembershipEdge &edge = family_memberships()[
            _family_cohort_edge_indices[p]];
        if (edge.people <= 0 || edge.family_handle == 0) continue;
        const int32_t factor = family_trait_behavior_factor_q16(
            edge.family_handle, 2, 0, need_id, cell);
        weighted = saturating_add(weighted,
            saturating_mul(edge.people, static_cast<int64_t>(factor) - Q16_ONE,
                sat), sat);
    }
    int64_t factor = mul_div_sat(weighted, 1, population, sat);
    const size_t city_index = static_cast<size_t>(std::max(0, cell)) *
        _need_ids.size() + static_cast<size_t>(std::max(0, need_id));
    if (cell >= 0 && cell < _cell_count.get() && need_id >= 0 &&
        need_id < static_cast<int32_t>(_need_ids.size()) &&
        city_index < _epoch_cell_need_consumption_factor_q16.size()) {
        factor = mul_div_sat(factor,
            _epoch_cell_need_consumption_factor_q16[city_index], Q16_ONE, sat);
    }
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country >= 0 && country < static_cast<int32_t>(
            _epoch_country_household_consumption_factor_q16.size()))
        factor = mul_div_sat(factor,
            _epoch_country_household_consumption_factor_q16[country], Q16_ONE, sat);
    return static_cast<int32_t>(std::clamp<int64_t>(
        factor, 0, 4 * Q16_ONE));
}

int32_t NativeEconomyRuntime::family_good_consumption_factor_q16(
        int32_t cohort_slot, int32_t good_id) const {
    if (cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            population_store().active.size()) || population_store().active[cohort_slot] == 0 ||
        good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()))
        return Q16_ONE;
    const int64_t population = std::max<int64_t>(1,
        population_store().population[cohort_slot]);
    const int32_t cell = population_store().page_cell[cohort_slot / COHORT_PAGE_SIZE];
    int64_t sat = 0;
    int64_t weighted = saturating_mul(population, Q16_ONE, sat);
    if (!family_trait_rolls().empty() && _family_cohort_offsets.size() ==
            population_store().active.size() + 1) {
        for (int32_t p = _family_cohort_offsets[cohort_slot];
             p < _family_cohort_offsets[cohort_slot + 1]; ++p) {
            const FamilyMembershipEdge &edge = family_memberships()[
                _family_cohort_edge_indices[p]];
            if (edge.people <= 0 || edge.family_handle == 0) continue;
            const int32_t factor = family_trait_behavior_factor_q16(
                edge.family_handle, 3, 0, good_id, cell);
            weighted = saturating_add(weighted,
                saturating_mul(edge.people,
                    static_cast<int64_t>(factor) - Q16_ONE, sat), sat);
        }
    }
    int64_t factor = mul_div_sat(weighted, 1, population, sat);
    const size_t city_index = static_cast<size_t>(std::max(0, cell)) *
        _good_ids.size() + static_cast<size_t>(good_id);
    if (cell >= 0 && cell < _cell_count.get() && city_index <
            _epoch_cell_good_consumption_factor_q16.size()) {
        factor = mul_div_sat(factor,
            _epoch_cell_good_consumption_factor_q16[city_index],
            Q16_ONE, sat);
    }
    return static_cast<int32_t>(std::clamp<int64_t>(
        factor, 0, 4 * Q16_ONE));
}

uint64_t NativeEconomyRuntime::preferred_family_for_cohort(
        int32_t cohort_slot, int32_t axis, int32_t selector_kind,
        int32_t selector_id) const {
    if (cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            population_store().active.size()) || _family_cohort_offsets.size() !=
            population_store().active.size() + 1) return 0;
    const int32_t cell = population_store().page_cell[cohort_slot / COHORT_PAGE_SIZE];
    const int32_t profession_share = axis == 1
        ? cell_profession_share_q16(cell, selector_id) : 0;
    uint64_t best = 0;
    int32_t best_factor = Q16_ONE;
    int64_t best_people = -1;
    int64_t sat = 0;
    for (int32_t p = _family_cohort_offsets[cohort_slot];
         p < _family_cohort_offsets[cohort_slot + 1]; ++p) {
        const FamilyMembershipEdge &edge = family_memberships()[
            _family_cohort_edge_indices[p]];
        if (edge.family_handle == 0 || edge.people <= 0) continue;
        int32_t factor = family_trait_behavior_factor_q16(
            edge.family_handle, axis, selector_kind, selector_id, cell);
        if (axis == 1) {
            const int32_t popularity = family_behavior_score_term_q16(
                edge.family_handle, cell, FAMILY_SCORE_LOCAL_POPULARITY);
            if (popularity != Q16_ONE)
                factor = static_cast<int32_t>(mul_div_sat(factor,
                    Q16_ONE + mul_div_sat(popularity - Q16_ONE,
                        profession_share, Q16_ONE, sat), Q16_ONE, sat));
            const int32_t mobility = family_behavior_score_term_q16(
                edge.family_handle, cell, FAMILY_SCORE_CAREER_MOBILITY);
            if (mobility != Q16_ONE)
                factor = static_cast<int32_t>(mul_div_sat(factor, mobility,
                    Q16_ONE, sat));
        }
        if (factor <= Q16_ONE) continue;
        if (factor > best_factor || (factor == best_factor &&
                (edge.people > best_people || (edge.people == best_people &&
                 (best == 0 || edge.family_handle < best))))) {
            best = edge.family_handle;
            best_factor = factor;
            best_people = edge.people;
        }
    }
    return best;
}

void NativeEconomyRuntime::rebuild_family_effect_binding_index() {
    _family_effect_binding_by_instance.clear();
    _family_effect_instances_by_branch.clear();
    _family_effect_instances_by_cell.clear();
    for (size_t index = 0; index < _family_effect_bindings.size(); ++index) {
        const FamilyEffectBinding &binding = _family_effect_bindings[index];
        if (binding.instance_id <= 0) continue;
        _family_effect_binding_by_instance[binding.instance_id] = index;
        _family_effect_instances_by_branch[binding.branch_handle].push_back(
            binding.instance_id);
        int32_t branch = -1;
        if (family_influences().valid_handle(binding.branch_handle, branch))
            _family_effect_instances_by_cell[family_influences().cell[branch]]
                .push_back(binding.instance_id);
    }
    mark_family_behavior_cache_dirty(
        FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS);
}

void NativeEconomyRuntime::add_family_effect_binding(
        FamilyEffectBinding binding) {
    if (binding.instance_id <= 0 ||
        _family_effect_binding_by_instance.find(binding.instance_id) !=
            _family_effect_binding_by_instance.end())
        return;
    const size_t index = _family_effect_bindings.size();
    _family_effect_bindings.push_back(std::move(binding));
    const FamilyEffectBinding &stored = _family_effect_bindings.back();
    _family_effect_binding_by_instance[stored.instance_id] = index;
    _family_effect_instances_by_branch[stored.branch_handle].push_back(
        stored.instance_id);
    int32_t branch_index = -1;
    if (family_influences().valid_handle(stored.branch_handle, branch_index))
        _family_effect_instances_by_cell[family_influences().cell[branch_index]]
            .push_back(stored.instance_id);
    mark_family_behavior_cache_dirty(
        FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS);
}

void NativeEconomyRuntime::remove_family_effect_binding(size_t index) {
    if (index >= _family_effect_bindings.size()) return;
    const FamilyEffectBinding removed = _family_effect_bindings[index];
    _family_effect_binding_by_instance.erase(removed.instance_id);
    auto branch = _family_effect_instances_by_branch.find(removed.branch_handle);
    if (branch != _family_effect_instances_by_branch.end()) {
        auto &ids = branch->second;
        ids.erase(std::remove(ids.begin(), ids.end(), removed.instance_id),
                  ids.end());
        if (ids.empty()) _family_effect_instances_by_branch.erase(branch);
    }
    int32_t branch_index = -1;
    if (family_influences().valid_handle(removed.branch_handle, branch_index)) {
        auto cell = _family_effect_instances_by_cell.find(
            family_influences().cell[branch_index]);
        if (cell != _family_effect_instances_by_cell.end()) {
            auto &ids = cell->second;
            ids.erase(std::remove(ids.begin(), ids.end(), removed.instance_id),
                      ids.end());
            if (ids.empty()) _family_effect_instances_by_cell.erase(cell);
        }
    }
    const size_t last = _family_effect_bindings.size() - 1;
    if (index != last) {
        _family_effect_bindings.write_record(index, _family_effect_bindings[last]);
        _family_effect_binding_by_instance[
            _family_effect_bindings[index].instance_id] = index;
    }
    _family_effect_bindings.pop_back();
    mark_family_behavior_cache_dirty(
        FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS);
}

bool NativeEconomyRuntime::publish_family_effect_metrics(
        const FamilyEffectBinding &binding, int64_t revision,
        const MetricMask &requested_mask) {
    if (_effect_runtime == nullptr || binding.instance_id <= 0) return false;
    int32_t branch = -1, family = -1;
    if (!family_influences().valid_handle(binding.branch_handle, branch) ||
        !families_store().valid_handle(family_influences().family_handle[branch], family))
        return false;
    const MetricMask mask = binding.metric_mask & requested_mask;
    if (mask.is_none()) return true;
    const int32_t cell = family_influences().cell[branch];
    std::array<int64_t, FAMILY_METRIC_COUNT> metrics{};
    fill_family_behavior_metrics(family, branch, cell, metrics.data(),
        FAMILY_METRIC_COUNT, mask);
    metrics[FAMILY_METRIC_MAGNITUDE_Q16] = binding.strength_q16;
    std::string error;
    for (int32_t metric_id = 0; metric_id < FAMILY_METRIC_COUNT; ++metric_id) {
        if (!mask.test(metric_id)) continue;
        if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                binding.instance_id, binding.generation, metric_id, revision,
                metrics[static_cast<size_t>(metric_id)], error))
            return false;
    }
    return true;
}

} // namespace pk
