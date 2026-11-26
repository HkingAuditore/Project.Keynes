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

bool NativeEconomyRuntime::rebuild_family_behavior_cache() {
    if (!_family_behavior_cache_dirty) {
        ++_family_behavior_cache_skips;
        return false;
    }
    // Track B (user-approved): the behavior cache is a slow-moving planning
    // input; keep the previous rebuild for up to N days. The dirty flag stays
    // set so the next due day rebuilds with current state.
    static const bool track_b_enabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B);
        return !(value && std::strcmp(value, "0") == 0);
    }();
    static const int32_t track_b_family_cache_cadence = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_FAMILY_CACHE_CADENCE);
        const int32_t parsed = value ? std::atoi(value) : 0;
        return parsed > 0 ? std::min<int32_t>(parsed, 30) : 5;
    }();
    static const int32_t track_b_family_cache_offset = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_FAMILY_CACHE_OFFSET);
        const int32_t parsed = value ? std::atoi(value) : 0;
        return parsed != 0 ? std::abs(parsed) : 1;
    }();
    const int64_t family_cache_day = _current_day.get();
    const bool structural_trait_or_effect_dirty =
        (_family_behavior_cache_dirty_reasons &
         (FAMILY_BEHAVIOR_DIRTY_INITIAL | FAMILY_BEHAVIOR_DIRTY_TRAITS |
          FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS |
          FAMILY_BEHAVIOR_DIRTY_INFLUENCES | FAMILY_BEHAVIOR_DIRTY_HOME_CELL)) != 0;
    const int32_t family_cache_phase =
        static_cast<int32_t>(((family_cache_day - track_b_family_cache_offset) %
            track_b_family_cache_cadence + track_b_family_cache_cadence) %
            track_b_family_cache_cadence);
    if (!structural_trait_or_effect_dirty &&
        track_b_enabled && track_b_family_cache_cadence > 1 &&
        _track_b_family_cache_last_day !=
            std::numeric_limits<int64_t>::min() &&
        family_cache_phase != 0 &&
        family_cache_day - _track_b_family_cache_last_day <
            track_b_family_cache_cadence) {
        ++_family_behavior_cache_skips;
        EconomyCostProbe::record("family.track_b_cache_skip",
                                 _current_day.get(), 0.0, 1u);
        return false;
    }
    _track_b_family_cache_last_day = family_cache_day;
    const auto cache_started = Clock::now();
    EconomyCostProbe behavior_cost("family.behavior_cache", _current_day.get());
    static const bool full_metrics = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FAMILY_METRIC_MASK_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    static const bool verify_metrics = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    const uint32_t rebuild_reasons = _family_behavior_cache_dirty_reasons;
    ensure_family_policy_factors();
    using TaggedRow = FamilyBehaviorSourceRow;
    struct FamilyCellContext {
        int32_t cell = -1;
        int32_t branch = -1;
        std::array<int64_t, FAMILY_METRIC_COUNT> metrics{};
        std::array<int64_t, FAMILY_METRIC_COUNT> reference_metrics{};
        bool metrics_ready = false;
    };
    // Freeze the branch lookup together with the family cell workset. Looking
    // up a branch by rescanning the entire influence store for every
    // conditioned trait edge turns this rebuild into O(edges * branches).
    // Reuse per-thread scratch across daily rebuilds: the tagged-row and
    // per-family cell lists are recreated every epoch and their allocations
    // (plus ~1 MB of row storage) were a steady daily cost.
    static thread_local std::vector<std::vector<FamilyCellContext>> family_cells;
    family_cells.resize(families_store().active.size());
    for (auto &cells : family_cells) cells.clear();
    static thread_local std::vector<MetricMask> family_metric_masks;
    family_metric_masks.assign(family_cells.size(), MetricMask{});
    for (const FamilyTraitRoll &roll : family_trait_rolls()) {
        int32_t family = -1;
        if (families_store().valid_handle(roll.family_handle, family) &&
            roll.trait_id >= 0 && roll.trait_id < static_cast<int32_t>(
                _family_trait_behavior_metric_masks.size()))
            family_metric_masks[static_cast<size_t>(family)] |=
                _family_trait_behavior_metric_masks[static_cast<size_t>(roll.trait_id)];
    }
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0) continue;
        int32_t family_index = -1;
        if (!families_store().valid_handle(family_influences().family_handle[branch],
                family_index) || family_index < 0 ||
            family_index >= static_cast<int32_t>(family_cells.size()))
            continue;
        const int32_t cell = family_influences().cell[branch];
        if (cell < 0 || cell >= _cell_count.get()) continue;
        family_cells[static_cast<size_t>(family_index)].push_back(
            FamilyCellContext{cell, branch, {}, {}, false});
    }
    for (int32_t family = 0; family < static_cast<int32_t>(family_cells.size());
         ++family) {
        auto &cells = family_cells[static_cast<size_t>(family)];
        if (cells.empty() && families_store().active[family] != 0) {
            const int32_t home = families_store().home_cell[family];
            if (home >= 0 && home < _cell_count.get())
                cells.push_back(FamilyCellContext{home, -1, {}, {}, false});
        }
        std::sort(cells.begin(), cells.end(), [](const auto &a, const auto &b) {
            return std::tie(a.cell, a.branch) < std::tie(b.cell, b.branch);
        });
        cells.erase(std::unique(cells.begin(), cells.end(),
            [](const auto &a, const auto &b) { return a.cell == b.cell; }),
            cells.end());
    }
    static thread_local std::vector<TaggedRow> expanded;
    expanded.clear();
    expanded.reserve(std::max<size_t>(expanded.capacity(),
        family_trait_rolls().size() * 2));
    for (const FamilyTraitRoll &roll : family_trait_rolls()) {
        int32_t family_index = -1;
        if (!families_store().valid_handle(roll.family_handle, family_index) ||
            roll.trait_id < 0 || roll.trait_id >= static_cast<int32_t>(
                _family_trait_behavior_offsets.size()) - 1)
            continue;
        for (int32_t edge = _family_trait_behavior_offsets[roll.trait_id];
             edge < _family_trait_behavior_offsets[roll.trait_id + 1]; ++edge) {
            const int64_t preferred = _family_trait_behavior_factors_q16[edge];
            const int64_t scaled = Q16_ONE + (preferred - Q16_ONE) *
                static_cast<int64_t>(roll.strength_q16) / Q16_ONE;
            const int32_t factor = static_cast<int32_t>(
                std::clamp<int64_t>(scaled, 0, 4 * Q16_ONE));
            const int32_t score_term = edge < static_cast<int32_t>(
                    _family_trait_behavior_score_terms.size())
                ? _family_trait_behavior_score_terms[edge] : 0;
            FamilyBehaviorFactorRow base;
            base.score_term = score_term;
            base.axis = _family_trait_behavior_axes[edge];
            base.selector_kind = _family_trait_behavior_selector_kinds[edge];
            base.selector_id = _family_trait_behavior_selector_ids[edge];
            base.factor_q16 = factor;
            const bool has_conditions =
                edge + 1 < static_cast<int32_t>(
                    _family_trait_behavior_condition_offsets.size()) &&
                _family_trait_behavior_condition_offsets[edge] <
                    _family_trait_behavior_condition_offsets[
                        static_cast<size_t>(edge) + 1];
            if (!has_conditions) {
                base.cell = -1;
                expanded.push_back({family_index, base});
                continue;
            }
            std::vector<FamilyCellContext> &cells =
                family_cells[static_cast<size_t>(family_index)];
            for (FamilyCellContext &context : cells) {
                if (!context.metrics_ready) {
                    const MetricMask mask = full_metrics ? MetricMask::all()
                        : family_metric_masks[static_cast<size_t>(family_index)];
                    fill_family_behavior_metrics(family_index, context.branch,
                        context.cell, context.metrics.data(), FAMILY_METRIC_COUNT, mask);
                    if (verify_metrics && !full_metrics) {
                        fill_family_behavior_metrics(family_index, context.branch,
                            context.cell, context.reference_metrics.data(), FAMILY_METRIC_COUNT);
                        for (int32_t metric = 0; metric < FAMILY_METRIC_COUNT; ++metric) {
                            if (mask.test(metric) &&
                                context.metrics[metric] != context.reference_metrics[metric]) {
                                std::fprintf(stderr, "[family-metric-mask-mismatch] day=%lld family=%d cell=%d metric=%d\n",
                                    static_cast<long long>(_current_day.get()), family_index,
                                    context.cell, metric);
                                std::abort();
                            }
                        }
                    }
                    const int32_t computed = mask.count(FAMILY_METRIC_COUNT);
                    EconomyCostProbe::record("family.behavior_metrics", _current_day.get(), 0.0, computed);
                    context.metrics_ready = true;
                    ++_family_behavior_metric_contexts_built;
                }
                ++_family_behavior_condition_edges_evaluated;
                const bool accepted = evaluate_family_behavior_conditions(edge,
                    context.metrics.data(), FAMILY_METRIC_COUNT);
                if (verify_metrics && !full_metrics && accepted !=
                        evaluate_family_behavior_conditions(edge,
                            context.reference_metrics.data(), FAMILY_METRIC_COUNT)) {
                    std::fprintf(stderr, "[family-condition-mask-mismatch] day=%lld family=%d cell=%d edge=%d\n",
                        static_cast<long long>(_current_day.get()), family_index, context.cell, edge);
                    std::abort();
                }
                if (!accepted)
                    continue;
                base.cell = context.cell;
                expanded.push_back({family_index, base});
            }
        }
    }
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        if (binding.definition_key != "family.effect.family_learning") continue;
        int32_t branch = -1;
        int32_t family_index = -1;
        if (!family_influences().valid_handle(binding.branch_handle, branch) ||
            !families_store().valid_handle(family_influences().family_handle[branch],
                family_index))
            continue;
        if (_family_knowledge_class_index < 0) {
            for (size_t i = 0; i < _carrying_class_ids.size(); ++i) {
                if (_carrying_class_ids[i] == "technology") {
                    _family_knowledge_class_index = static_cast<int32_t>(i);
                    break;
                }
            }
        }
        if (_family_knowledge_class_index < 0) continue;
        const int32_t prestige = std::clamp<int32_t>(
            family_influences().prestige_level[branch], 0, 5);
        static constexpr int64_t kLearningPopStep[6] = {
            100, 100, 80, 60, 40, 20
        };
        const int64_t family_pop = family_population(
            family_influences().family_handle[branch]);
        int64_t steps = family_pop / kLearningPopStep[prestige];
        if (steps <= 0) {
            if (binding.strength_q16 <= Q16_ONE) continue;
            steps = 1;
        }
        const int32_t factor = binding.strength_q16 <= Q16_ONE
            ? static_cast<int32_t>(std::clamp<int64_t>(
                static_cast<int64_t>(Q16_ONE) +
                    steps * static_cast<int64_t>(binding.strength_q16),
                0, 4 * Q16_ONE))
            : static_cast<int32_t>(std::clamp<int64_t>(
                binding.strength_q16, 0, 4 * Q16_ONE));
        FamilyBehaviorFactorRow row;
        row.cell = -1;
        row.score_term = FAMILY_SCORE_CANDIDATE_WEIGHT;
        row.axis = 1;
        row.selector_kind = FAMILY_BEHAVIOR_SELECTOR_PROFESSION_CLASS;
        row.selector_id = _family_knowledge_class_index;
        row.factor_q16 = factor;
        expanded.push_back({family_index, row});
    }
    static const bool full_cache = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_ACTIVE_WORKSET_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    static const bool verify_cache = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    // 每天仍评估真实条件；阈值未跨越时，展开后的完整整数行常常完全相同。
    // 精确比较包括输入顺序和 factor，不用 hash，也不延迟条件生效。
    const bool unchanged = !full_cache && expanded == _family_behavior_source_rows &&
        _family_behavior_factor_offsets.size() == families_store().active.size() + 1;
    if (unchanged && !verify_cache) {
        _family_behavior_cache_dirty = false;
        _family_behavior_cache_dirty_reasons = 0;
        _family_behavior_cache_last_reasons = rebuild_reasons;
        ++_family_behavior_cache_skips;
        _family_behavior_cache_ms += elapsed_ms(cache_started);
        EconomyCostProbe::record("family.behavior_rows_reused", _current_day.get(), 0.0, expanded.size());
        return false;
    }
    const auto reference_rows = unchanged ? _family_behavior_factor_rows : std::vector<FamilyBehaviorFactorRow>{};
    const auto reference_offsets = unchanged ? _family_behavior_factor_offsets : std::vector<int32_t>{};
    _family_behavior_source_rows = expanded;
    std::sort(expanded.begin(), expanded.end(), [](const TaggedRow &a,
            const TaggedRow &b) {
        return std::tie(a.family_index, a.row.cell, a.row.score_term, a.row.axis,
                        a.row.selector_kind, a.row.selector_id) <
               std::tie(b.family_index, b.row.cell, b.row.score_term, b.row.axis,
                        b.row.selector_kind, b.row.selector_id);
    });
    static thread_local std::vector<TaggedRow> merged;
    merged.clear();
    merged.reserve(std::max<size_t>(merged.capacity(), expanded.size()));
    for (const TaggedRow &entry : expanded) {
        if (!merged.empty() &&
            merged.back().family_index == entry.family_index &&
            merged.back().row.cell == entry.row.cell &&
            merged.back().row.score_term == entry.row.score_term &&
            merged.back().row.axis == entry.row.axis &&
            merged.back().row.selector_kind == entry.row.selector_kind &&
            merged.back().row.selector_id == entry.row.selector_id) {
            const int64_t combined = static_cast<int64_t>(
                merged.back().row.factor_q16) * entry.row.factor_q16 / Q16_ONE;
            merged.back().row.factor_q16 = static_cast<int32_t>(
                std::clamp<int64_t>(combined, 0, 4 * Q16_ONE));
        } else {
            merged.push_back(entry);
        }
    }
    _family_behavior_factor_offsets.assign(families_store().active.size() + 1, 0);
    for (const TaggedRow &entry : merged) {
        if (entry.family_index >= 0 && entry.family_index <
            static_cast<int32_t>(families_store().active.size()))
            ++_family_behavior_factor_offsets[static_cast<size_t>(entry.family_index) + 1];
    }
    for (size_t i = 0; i + 1 < _family_behavior_factor_offsets.size(); ++i)
        _family_behavior_factor_offsets[i + 1] += _family_behavior_factor_offsets[i];
    _family_behavior_factor_rows.clear();
    _family_behavior_factor_rows.reserve(merged.size());
    for (const TaggedRow &entry : merged)
        _family_behavior_factor_rows.push_back(entry.row);
    _family_behavior_class_rows = static_cast<int64_t>(std::count_if(
        _family_behavior_factor_rows.begin(), _family_behavior_factor_rows.end(),
        [](const FamilyBehaviorFactorRow &row) {
            return row.selector_kind ==
                FAMILY_BEHAVIOR_SELECTOR_PROFESSION_CLASS;
        }));
    if (unchanged && (reference_rows != _family_behavior_factor_rows ||
            reference_offsets != _family_behavior_factor_offsets)) {
        std::fprintf(stderr, "[family-behavior-reuse-mismatch] day=%lld\n",
            static_cast<long long>(_current_day.get()));
        std::abort();
    }
    _family_behavior_cache_dirty = false;
    _family_behavior_cache_dirty_reasons = 0;
    _family_behavior_cache_last_reasons = rebuild_reasons;
    ++_family_behavior_cache_rebuilds;
    _family_behavior_cache_ms += elapsed_ms(cache_started);
    return true;
}

} // namespace pk
