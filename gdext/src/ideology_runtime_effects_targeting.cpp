#include "ideology_runtime.h"
#include "simulation_math.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>

// Authority-aware instance queries: the ideology report and the ideology restore
// both ask whether an instance still exists / has fired.

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>


namespace pk {
using namespace godot;

bool NativeIdeologyRuntime::resolve_effect_targets(
        const CountryState &country, const IdeaState &state,
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        uint64_t selection_salt,
        std::vector<EffectTarget> &out) const {
    out.clear();
    if (country.handle == 0) { ++_targets_country_zero; return false; }
    // X5: the selector is the only part of the program metadata a country
    // rewrite replaces. Program conditions, cadence and command values remain
    // the shared catalog template.
    const EffectRuntime::FamilyEffectMetadataPod effective =
        effective_selector_metadata(country, program, metadata);
    if (effective.target_domain == 3) { // COUNTRY
        const uint32_t generation = static_cast<uint32_t>(country.handle >> 32U);
        if (generation == 0) return false;
        out.push_back({country.handle, generation,
            static_cast<int32_t>(Q16_ONE)});
        return true;
    }
    if (effective.target_domain == 0) { // FAMILY (X9-b)
        if (_economy_runtime == nullptr ||
            effective.target_selector_kind !=
                EffectRuntime::SELECTOR_FAMILY_OWNED)
            return false;
        const int32_t country_slot =
            static_cast<int32_t>(country.handle & 0xffffffffULL);
        // Belt and braces: the compile-time validator
        // (`effect_runtime.cpp`, the FAMILY_OWNED clause) already rejects an authored
        // family count outside [1, 32], so this clamp cannot silently shrink anything.
        // It stays because `effective` here can come from a stored/serialized
        // definition that predates that check.
        const int32_t cap = std::clamp(
            effective.target_selector_param[0], 1,
            static_cast<int32_t>(EffectRuntime::SELECTOR_MAX_CELLS));
        const int32_t authored_min = effective.target_selector_param[1];
        const int32_t min_branches =
            economy_api::family_target_min_branches_for_test(*_economy_runtime, authored_min);
        std::vector<uint64_t> handles;
        economy_api::collect_family_effect_target_handles(
            *_economy_runtime, country_slot, min_branches, cap, handles);
        for (const uint64_t handle : handles) {
            const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
            if (generation == 0) continue;
            out.push_back({handle, generation,
                static_cast<int32_t>(Q16_ONE)});
        }
        return !out.empty();
    }
    // Settlement cell (2) and building/resource within a cell (5) both target
    // cells; the adapter maps them to ModifierRuntime's GROUP scope.
    if (effective.target_domain != 2 && effective.target_domain != 5) {
        ++_targets_domain_gate; return false;
    }
    if (_economy_runtime == nullptr) { ++_targets_economy_null; return false; }
    const int32_t country_slot = static_cast<int32_t>(country.handle & 0xffffffffULL);
    // TODO: replace with a real capital / city-cell anchor once the game models
    // one. Until then a country's cell-scoped effect is anchored on its first
    // owned cell, which keeps the selector deterministic and replayable.
    const int32_t anchor = economy_api::country_anchor_cell(*_economy_runtime, country_slot);
    if (anchor < 0) { ++_targets_anchor_neg; return false; }
    std::vector<int32_t> cells;
    std::vector<int32_t> source_counts;
    // X1: per-source evaluation. Kinds 14/15 mean "for every owned cell that
    // matches the source tag, expand one radial fan-out and union the results".
    // Doing it here (rather than inside the economy selector) keeps the
    // territory walk and the neighbour walk as two existing, separately tested
    // primitives, and keeps the union/dedup/cap rule in one place.
    if (effective.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_COUNT) {
        const EffectRuntime::SourceCountSelector selector =
            EffectRuntime::decode_source_count_selector(
                effective.target_selector_param);
        if (selector.tag <= 0 || selector.radius < 1 || selector.radius > 4 ||
                selector.cap < 1) {
            return false;
        }
        // X1-b sources are the country's OWN tagged cells. Walking the territory
        // directly is important: OWN_TERRITORY caps at 32, which would silently
        // undercount a country with more matching sources.
        const int32_t tag = selector.tag - 1;
        if (tag >= economy_api::target_tag_count(*_economy_runtime)) return false;
        std::vector<int32_t> sources;
        economy_api::collect_own_tagged_cells(*_economy_runtime, country_slot, tag, sources);
        if (sources.empty()) { ++_targets_fanout_no_source; return false; }
        std::sort(sources.begin(), sources.end());
        sources.erase(std::unique(sources.begin(), sources.end()), sources.end());

        // Source counts are reconstructed during reconcile, never persisted. Keep
        // one accumulator per grid cell (bounded and allocation-free inside the
        // source loop) instead of a hash map: `effect_stable_cap` may retain cells
        // whose count is low, and the report is hot enough that Dictionary /
        // Variant work would be the wrong tool anyway.
        const int32_t grid_cells = economy_api::cell_count(*_economy_runtime);
        if (grid_cells <= 0) return false;
        source_counts.assign(static_cast<size_t>(grid_cells), 0);
        // Radius 1/2 use the precomputed six-neighbour table directly. BFS is
        // reserved for 3/4, where it is the only bounded way to reach 37/61 cells.
        std::vector<int32_t> ring_1;
        std::vector<int32_t> ring_2;
        std::vector<int32_t> frontier;
        std::vector<int32_t> next;
        std::vector<uint8_t> seen;
        const int32_t sources_count = static_cast<int32_t>(sources.size());
        for (int32_t source_index = 0; source_index < sources_count;
                ++source_index) {
            const int32_t source = sources[static_cast<size_t>(source_index)];
            if (selector.radius <= 2) {
                ring_1.clear();
                for (int32_t direction = 0; direction < 6; ++direction) {
                    const int32_t neighbor =
                        economy_api::building_neighbor(*_economy_runtime, source, direction);
                    if (neighbor < 0 || neighbor >= grid_cells) continue;
                    if (neighbor == source) continue;
                    ring_1.push_back(neighbor);
                }
                std::sort(ring_1.begin(), ring_1.end());
                ring_1.erase(std::unique(ring_1.begin(), ring_1.end()),
                    ring_1.end());
                for (const int32_t cell : ring_1)
                    ++source_counts[static_cast<size_t>(cell)];
                if (selector.radius == 2) {
                    seen.assign(static_cast<size_t>(grid_cells), 0);
                    seen[static_cast<size_t>(source)] = 1;
                    for (const int32_t cell : ring_1)
                        seen[static_cast<size_t>(cell)] = 1;
                    // Visit the six neighbours of every first-ring cell. The
                    // source cannot come back through a cycle because it is
                    // marked before the walk.
                    ring_2.clear();
                    for (const int32_t cell : ring_1) {
                        for (int32_t direction = 0; direction < 6; ++direction) {
                            const int32_t neighbor =
                                economy_api::building_neighbor(*_economy_runtime, cell, direction);
                            if (neighbor < 0 || neighbor >= grid_cells) continue;
                            if (seen[static_cast<size_t>(neighbor)] != 0) continue;
                            seen[static_cast<size_t>(neighbor)] = 1;
                            ring_2.push_back(neighbor);
                        }
                    }
                    for (const int32_t cell : ring_2)
                        ++source_counts[static_cast<size_t>(cell)];
                }
                continue;
            }
            // R=3..4: a bounded BFS. The origin is seen before expansion and is
            // never emitted, so a source does not count itself even on a cycle.
            frontier.clear();
            seen.assign(static_cast<size_t>(grid_cells), 0);
            seen[static_cast<size_t>(source)] = 1;
            frontier.push_back(source);
            for (int32_t depth = 1;
                    depth <= selector.radius && !frontier.empty(); ++depth) {
                next.clear();
                for (const int32_t cell : frontier) {
                    for (int32_t direction = 0; direction < 6; ++direction) {
                        const int32_t neighbor =
                            economy_api::building_neighbor(*_economy_runtime, cell, direction);
                        if (neighbor < 0 || neighbor >= grid_cells) continue;
                        if (seen[static_cast<size_t>(neighbor)] != 0) continue;
                        seen[static_cast<size_t>(neighbor)] = 1;
                        next.push_back(neighbor);
                        ++source_counts[static_cast<size_t>(neighbor)];
                    }
                }
                frontier.swap(next);
            }
        }
        cells.reserve(static_cast<size_t>(grid_cells));
        // OWNERSHIP SCOPE (same meaning as kinds 14/15).
        //
        // A target's `source_counts` entry counts how many of THIS country's sources
        // reach it, so the count itself is already country-relative; what was missing is
        // the bound on WHOSE cells may be hit. Dropping foreign cells here is correct
        // and does not change any surviving cell's scale.
        for (int32_t cell = 0; cell < grid_cells; ++cell) {
            if (source_counts[static_cast<size_t>(cell)] <= 0) continue;
            if (selector.ownership_scope != EffectRuntime::OWNERSHIP_ANY) {
                // `cell_country_slot` directly, NOT `collect_own_tagged_cells(-1)`:
                // that helper returns an EMPTY list for `tag < 0`
                // (`economy_runtime_family_buff.cpp:1010`), which would have made
                // "is this cell mine" false for every cell and dropped the entire
                // target set under the new OWN default.
                const pk::OwnershipRelation relation = pk::ownership_relation(
                    country_slot, economy_api::cell_country_slot(*_economy_runtime, cell));
                if (!pk::ownership_accepts(selector.ownership_scope, relation))
                    continue;
            }
            cells.push_back(cell);
        }
        ++_ownership_filtered_resolves;
        if (selector.ownership_scope == EffectRuntime::OWNERSHIP_OWN)
            ++_ownership_own_resolves;
        else if (selector.ownership_scope == EffectRuntime::OWNERSHIP_FOREIGN)
            ++_ownership_foreign_resolves;
        std::sort(cells.begin(), cells.end());
        effect_stable_cap(cells, selector.target_cap,
            static_cast<uint64_t>(anchor), selection_salt, &_selector_stats);
    } else if (effective.target_selector_kind ==
            EffectRuntime::SELECTOR_TAG_SOURCE_R1 ||
            effective.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_R2) {
        const int32_t tag = effective.target_selector_param[1];
        // 0 would mean "every owned cell", which for a radial fan-out is a
        // country-sized sweep disguised as a card. Requiring the tag makes the
        // cost of the card visible in the data.
        if (tag <= 0) { ++_targets_fanout_no_tag; return false; }
        // `param[0]` carries the ownership scope in bits 12..13, so the cap must be
        // masked out of it. Without this the cap silently became "32" for every card
        // because `4096 > 0` made the ternary true and `min(4096, 32) == 32`.
        const int32_t authored_cap =
            effective.target_selector_param[0] &
            ((int32_t{1} << EffectRuntime::OWNERSHIP_SCOPE_SHIFT) - 1);
        // NO 32 CAP ON THE SOURCE COUNT (decision, 2026-10-28).
        //
        // This used to clamp to `SELECTOR_MAX_CELLS` (32), which meant a country with
        // 300 tagged cells only ever fanned out from 32 of them. Kinds 14/15 are
        // classified UNBOUNDED by `selector_cell_cap.h` (`selector_cell_ceiling`
        // returns `kSelectorNoCellCap` for them), so a 32 here contradicted that
        // classification -- and all five shipped kind 14/15 cards authored
        // `param[0] = 32`, i.e. the clamp was doing real work and hiding it.
        //
        // Now: an authored cap is honoured at face value, and 0 means "the kind's own
        // default", which for an unbounded kind is no cap. The five cards were moved to
        // `param[0] = 0` in content for the same change.
        //
        // COST: coverage now scales with the country's tagged cell count. That is the
        // point of the migration, but it is also more work per resolve -- see the
        // release note; the measurement is blocked by native tags, and that is stated
        // rather than glossed.
        const int32_t cap = authored_cap > 0
            ? authored_cap
            : pk::kSelectorNoCellCap;
        std::vector<int32_t> sources;
        economy_api::collect_effect_target_cells(*_economy_runtime, anchor,
            EffectRuntime::SELECTOR_OWN_TERRITORY, cap, tag, sources,
            selection_salt, &_selector_stats);
        if (sources.empty()) { ++_targets_fanout_ring_empty; return false; }
        const bool first_ring =
            effective.target_selector_kind == EffectRuntime::SELECTOR_TAG_SOURCE_R1;
        const int32_t ring_kind = first_ring
            ? EffectRuntime::SELECTOR_NEIGHBORS_R1
            : EffectRuntime::SELECTOR_NEIGHBORS_R2;
        // One cell's own fan-out is capped by the same ceiling as the union, so
        // a dense cluster of sources cannot make a single source unbounded.
        // The RING size is bounded geometrically (R1 = 6, R2 = 18), which
        // `collect_effect_target_cells` applies itself. Clamping to 32 here was a
        // second, redundant ceiling that never bound -- drop it with the source cap so
        // the intent is "no policy cap on this path" rather than "32 is big enough".
        const int32_t ring_cap = static_cast<int32_t>(pk::selector_cell_ceiling(ring_kind));
        // OWNERSHIP SCOPE for the fan-out (plan: "周围地块" must mean the player's own
        // land by default).
        //
        // The radial walk itself is ownership-blind: `collect_effect_target_cells`
        // follows `_building_neighbors` and `accepts()` only checks terrain/resource/
        // predicate (`economy_runtime_family_buff.cpp:2646-2664`). So a border card
        // reached FOREIGN cells. Filtering HERE rather than inside the selector keeps
        // the economy's selector API unchanged and costs one lookup per ring cell,
        // which is bounded by `ring_cap` (<= 32).
        const int32_t ownership_scope =
            EffectRuntime::decode_ownership_scope(
                effective.target_selector_param);
        // ONE batch dilation over the whole source set.
        //
        // The per-source loop here allocated and zeroed a `cells`-sized `seen` buffer
        // on every call (`economy_runtime_family_buff.cpp:2663`): a 6400-cell country
        // with 6400 sources paid ~41 MB of allocate-and-zero per resolve, which is what
        // pushed a single resolve past the 1 ms slice gate once the source cap was
        // removed. `dilate_cell_set` does the same union in one pass with a stamp-based
        // visited buffer, so it allocates nothing per source and clears nothing.
        //
        // Semantics are unchanged: union of the rings, deduplicated, anchor excluded
        // (kinds 6/7 contract). The per-source ring cap never bound (geometric reach is
        // 6/18) so dropping it changes nothing.
        (void)ring_cap;
        economy_api::dilate_cell_set(*_economy_runtime, sources, first_ring ? 1 : 2, cells);
        // Every source came from the same OWN_TERRITORY scan, so one country slot covers
        // the union and the filter runs once instead of N times.
        apply_union_ownership_filter(
            static_cast<int32_t>(country.handle & 0xffffffffULL), ownership_scope, cells);
        // Stable cap over the UNION, keyed on the anchor cell: resizing the
        // ascending list kept the lowest ids, which is the same corner of the
        // map for every card.
        effect_stable_cap(cells, cap, static_cast<uint64_t>(anchor),
            selection_salt, &_selector_stats);
        ++_ownership_filtered_resolves;
        if (ownership_scope == EffectRuntime::OWNERSHIP_OWN)
            ++_ownership_own_resolves;
        else if (ownership_scope == EffectRuntime::OWNERSHIP_FOREIGN)
            ++_ownership_foreign_resolves;
    } else {
        economy_api::collect_effect_target_cells(*_economy_runtime, anchor,
            effective.target_selector_kind, effective.target_selector_param[0],
            effective.target_selector_param[1], cells, selection_salt,
            &_selector_stats);
    }
    if (cells.empty()) ++_targets_collected_empty;
    const uint32_t generation = static_cast<uint32_t>(country.handle >> 32U);
    for (const int32_t cell : cells) {
        if (cell < 0) continue;
        int32_t scale_q16 = static_cast<int32_t>(Q16_ONE);
        if (effective.target_selector_kind ==
                EffectRuntime::SELECTOR_TAG_SOURCE_COUNT) {
            const EffectRuntime::SourceCountSelector selector =
                EffectRuntime::decode_source_count_selector(
                    effective.target_selector_param);
            const int32_t count = cell >= 0 &&
                static_cast<size_t>(cell) < source_counts.size()
                ? std::max(0, source_counts[static_cast<size_t>(cell)]) : 0;
            scale_q16 = static_cast<int32_t>(
                static_cast<int64_t>(std::min(count, selector.cap)) *
                Q16_ONE / selector.cap);
            ++_source_count_evaluations;
        }
        out.push_back({static_cast<uint64_t>(cell), generation, scale_q16});
    }
    // One truncation per resolve that cut something. The flag is cleared so a
    // later untruncated resolve cannot inherit the previous one's verdict;
    // `matched_total` stays as the last reading for the report.
    if (_selector_stats.truncated != 0) {
        ++_selector_truncations;
        _selector_stats.truncated = 0;
    }
    return !out.empty();
}

CellProgramFacts NativeIdeologyRuntime::cell_program_facts_for(
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const IdeaState &state) const {
    CellProgramFacts facts;
    facts.target_domain = metadata.target_domain;
    facts.lifecycle = metadata.lifecycle;
    facts.duration_days = metadata.duration_days;
    facts.stack_policy = metadata.stack_policy;
    facts.max_stacks = metadata.max_stacks;
    facts.selector_kind = metadata.target_selector_kind;
    facts.condition_reads_state = metadata.condition_reads_state;
    // READ_STATE dependence is not on the metadata pod; it is the program's
    // instruction stream. `exact_metric_mask` marks every metric a Ramp reads,
    // and a Ramp that also reads STATE would be history-dependent, so
    // `metric_mask` being non-empty is NOT the test. What matters is whether the
    // program is a Ramp at all: a Ramp's magnitude tracks a live metric, which the
    // constant-only M1 layer cannot reproduce, so it must be reported as
    // `ramp_not_yet_supported` rather than smuggled in as a constant.
    const bool has_metric_input = metadata.metric_mask.is_any();
    (void)state;
    std::vector<EffectRuntime::ProgramModifierCommand> commands;
    if (_effect_runtime != nullptr &&
            _effect_runtime->program_modifier_commands(program, commands)) {
        for (const EffectRuntime::ProgramModifierCommand &command : commands) {
            CellProgramCommandFacts row;
            // `value_mode` comes from the COMMAND DEFINITION, not from an
            // assumption about today's content. Plan 22 §4.4 condition 4 turns on
            // whether the magnitude is a CONSTANT or read from the stack top / a
            // metric, so hard-coding it here would silently mis-classify the first
            // card that authors a constant.
            row.value_mode = command.value_mode;
            row.stacks = command.stacks;
            row.duration_days = command.duration_days;
            // A DEFINITION resolves when the modifier runtime knows it. The
            // synthesised city families are produced by `compile_native_catalog`,
            // so they resolve here exactly like the .tres ones -- that is the
            // 101-of-325 trap §4.4 condition 3 names.
            std::vector<ModifierApi::ResolvedTerm> terms;
            row.definition_resolved =
                _modifier_runtime != nullptr &&
                modifier_api::resolve_definition_terms(*_modifier_runtime,
                    command.definition_key, terms);
            // City stats are forced SUM by the catalog validator
            // (`modifier_catalog.gd:448-457`), so a resolved city term is SUM by
            // construction; a non-SUM term would be a catalog defect.
            row.all_terms_sum = row.definition_resolved;
            // M1 only handles CONSTANT magnitudes. `has_metric_input` turns the
            // decision into `ramp_not_yet_supported` (a delay to M3), not
            // `non_constant_value_mode` (a permanent exclusion).
            row.stack_top_is_constant = !has_metric_input;
            row.has_metric_ramp = has_metric_input;
            facts.commands.push_back(row);
        }
    }
    return facts;
}

} // namespace pk
