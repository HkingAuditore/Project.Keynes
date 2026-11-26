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

namespace {
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

bool NativeEconomyRuntime::run_family_commit_slice(int64_t &work_done,
                                                    std::string &error) {
    error.clear();
    // Phase-2.4.3.2 fail-closed: StageOps must not skip fiscal settlement.
    if (_stage == Stage::FISCAL_SETTLEMENT) {
        error = "family_commit_fiscal_unsettled";
        return false;
    }
    if (_stage != Stage::FAMILY_COMMIT &&
        _stage != Stage::WAIT_COMMIT) {
        // Already past family (or idle); treat as no-op like building slice.
        return true;
    }
    if (_stage == Stage::WAIT_COMMIT) {
        _stage = Stage::FAMILY_COMMIT;
    }
    if (_family_commit_phase == 0) {
        if (_family_runtime_mode.get() == 0 && families_store().active_count == 0) {
            _person_commit_phase = 0;
            _person_commit_cursor = 0;
            _stage = Stage::PERSON_COMMIT;
            ++work_done;
            return true;
        }
        _family_commit_normalize_ms = 0.0;
        _family_commit_attribution_ms = 0.0;
        _family_commit_form_ms = 0.0;
        _family_commit_index_ms = 0.0;
        _family_commit_lifecycle_ms = 0.0;
        _family_commit_influence_ms = 0.0;
        _family_behavior_cache_ms = 0.0;
        _family_behavior_cache_rebuilds = 0;
        _family_behavior_cache_skips = 0;
        _family_behavior_metric_contexts_built = 0;
        _family_behavior_condition_edges_evaluated = 0;
        _family_behavior_cache_last_reasons = 0;
        _rebuild_family_membership_ms = 0.0;
        _rebuild_family_ownership_ms = 0.0;
        _rebuild_family_csr_ms = 0.0;
        _rebuild_family_cellindex_ms = 0.0;
        const auto normalize_started = Clock::now();
        if (!_family_trait_behavior_condition_ops.empty())
            mark_family_behavior_cache_dirty(
                FAMILY_BEHAVIOR_DIRTY_CONDITION_METRICS);
        apply_due_family_trait_commands();
        apply_due_family_founding_choices();
        normalize_family_memberships(false, true);
        recruit_family_dependents();
        absorb_family_households();
        // Attribution walks cohort-contiguous edges; only edges created by
        // recruitment or same-day founding break that order.
        if (_family_indices_dirty) rebuild_family_indices(false);
        _family_commit_normalize_ms += elapsed_ms(normalize_started);
        const auto attribution_started = Clock::now();
        update_family_employment_attribution();
        _family_commit_attribution_ms += elapsed_ms(attribution_started);
        // 沿用活跃经济格；补入本轮新人口页和待处理 offer，避免空格扫描，
        // 同时不漏掉迁入、新建以及已经无人居住但仍需收尾的选择。
        auto &review_cells = _family_review_cells_scratch;
        review_cells.clear();
        const char *workset_disabled = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_ACTIVE_WORKSET_DISABLE);
        if (workset_disabled && std::strcmp(workset_disabled, "1") == 0) {
            review_cells.resize(static_cast<size_t>(_cell_count.get()));
            std::iota(review_cells.begin(), review_cells.end(), 0);
        } else {
            review_cells = _economy_live_cells;
            const auto append_cell = [&](int32_t cell) {
                if (cell >= 0 && cell < _cell_count.get()) review_cells.push_back(cell);
            };
            for (int32_t cell : population_store().page_cell) append_cell(cell);
            for (int32_t cell : _building_active_cells) append_cell(cell);
            for (const auto &offer : _family_founding_offers) append_cell(offer.cell);
            std::sort(review_cells.begin(), review_cells.end());
            review_cells.erase(std::unique(review_cells.begin(), review_cells.end()), review_cells.end());
        }
        if (_family_runtime_mode.get() == 2 && _family_milestones_reached.size() !=
                static_cast<size_t>(_cell_count.get()))
            _family_milestones_reached.resize(static_cast<size_t>(_cell_count.get()), 0);
        _family_commit_cursor = 0;
        _family_commit_phase = 1;
        ++work_done;
        return true;
    }
    if (_family_commit_phase == 1) {
        const auto form_started = Clock::now();
        const int32_t scan_budget = std::max(1,
            _family_cells_per_slice * _family_review_days.get());
        const int32_t begin = _family_commit_cursor;
        const int32_t end = std::min(static_cast<int32_t>(_family_review_cells_scratch.size()),
            _family_commit_cursor + scan_budget);
        for (; _family_commit_cursor < end; ++_family_commit_cursor) {
            const int32_t cell = _family_review_cells_scratch[_family_commit_cursor];
            // Opening founders are created only by bootstrap. An emptied
            // capital must not silently manufacture a replacement household.
            review_family_milestone(cell);
        }
        work_done += end - begin;
        EconomyCostProbe::record("family.review_cells", _current_day.get(), 0.0,
            static_cast<uint64_t>(end - begin));
        _family_commit_form_ms += elapsed_ms(form_started);
        if (_family_commit_cursor < static_cast<int32_t>(_family_review_cells_scratch.size())) return true;
        _family_commit_phase = 2;
        return true;
    }
    // Formation may have appended authoritative edges after the normalization
    // CSR was built. Absorb dependents before rebuild so the same-day founders
    // reach the cell household target from remaining anonymous people. Rebuild
    // before lifecycle so each review is O(edges-of-family), including families
    // formed in this same commit. When nothing was formed the flag stays clear
    // and the CSR is still exact.
    absorb_family_households();
    const auto first_index_started = Clock::now();
    bool structure_changed = _family_indices_dirty;
    if (_family_indices_dirty) rebuild_family_indices(false);
    _family_commit_index_ms += elapsed_ms(first_index_started);
    const int64_t families_before_split = families_store().active_count;
    split_family_branches();
    structure_changed = structure_changed || families_store().active_count != families_before_split ||
        _family_indices_dirty;
    if (_family_indices_dirty) rebuild_family_indices(false);
    const auto lifecycle_started = Clock::now();
    review_family_lifecycle();
    _family_commit_lifecycle_ms += elapsed_ms(lifecycle_started);
    const auto second_index_started = Clock::now();
    structure_changed = structure_changed || _family_indices_dirty;
    if (_family_indices_dirty) rebuild_family_indices(false);
    _family_commit_index_ms += elapsed_ms(second_index_started);
    // Derived caches are published once from the final canonical edge set.
    // Industry metrics must precede influence/effect reconciliation because
    // conditional Family metrics read them.
    bool has_influence = false;
    for (uint8_t flag : family_influences().active) {
        if (flag != 0) {
            has_influence = true;
            break;
        }
    }
    const bool refresh_influence = structure_changed ||
        (!family_memberships().empty() && !has_influence) ||
        (_epoch_id.get() % FAMILY_INFLUENCE_REFRESH_EPOCHS) == 0;
    if (refresh_influence || structure_changed)
        rebuild_family_industry_metrics();
    const auto influence_started = Clock::now();
    if (refresh_influence)
        rebuild_family_influences(false);
    _family_commit_influence_ms += elapsed_ms(influence_started);
    rebuild_family_behavior_cache();
    if (structure_changed || refresh_influence)
        rebuild_family_owned_output_csr();
    prune_family_founding_effects();
    _family_membership_edges_processed +=
        static_cast<int64_t>(family_memberships().size());
    _family_ownership_edges_processed +=
        static_cast<int64_t>(family_ownerships().size());
    _family_commit_phase = 0;
    _family_commit_cursor = 0;
    _person_commit_phase = 0;
    _person_commit_cursor = 0;
    _stage = Stage::PERSON_COMMIT;
    ++work_done;
    return true;
}

} // namespace pk
