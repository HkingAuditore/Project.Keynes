#include "ideology_runtime.h"
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

namespace {
constexpr int32_t kEconomyMetricCount = EconomyApi::FAMILY_METRIC_COUNT;
}

bool NativeIdeologyRuntime::emit_templates(uint64_t country_handle, int32_t ideology_id,
        int32_t level, int32_t begin, int32_t count, bool remove, int64_t day,
        uint64_t salt,
        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
        std::string &error) {
    if (count <= 0) return true;
    if (_effect_runtime == nullptr) { error = "ideology_effect_runtime_unavailable"; return false; }
    if (static_cast<int64_t>(commands.size()) + count >
            _max_transition_commands) {
        error = "ideology_transition_command_limit_exceeded";
        return false;
    }
    const std::vector<EffectTemplate> &templates = remove
        ? _persistent_templates : (salt == 0 ? _persistent_templates : _on_enter_templates);
    const int64_t tier_source_id = static_cast<int64_t>(
        (static_cast<uint64_t>(ideology_id + 1) << 32U) | static_cast<uint32_t>(level + 1));
    for (int32_t offset = 0; offset < count; ++offset) {
        const EffectTemplate &templ = templates[static_cast<size_t>(begin + offset)];
        // Persisted tier rows (salt 0) that resolve to a declarative managed
        // program are owned by reconcile_effect_activations(). Emitting them
        // here as well would apply the same effect twice. On-enter one-shots
        // keep using this batch: they are events, not state.
        if (salt == 0 && _effect_runtime != nullptr) {
            const std::string program = effect_program_key(templ.definition_key);
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!program.empty() &&
                    _effect_runtime->family_effect_metadata_pod(program, metadata))
                continue;
        }
        // The APPLY and its matching REMOVE must mint the SAME effect identity.
        //
        // `enqueue_external_effect_batch_pod` derives the instance id from
        // (source_type, transition_source_id, first.effect_id, first.fire_sequence)
        // and that instance id becomes the Modifier row's `source_id`
        // (`effect_runtime.cpp`: NATIVE_MODIFIER_IDEOLOGY sets
        // `source_id = source_instance->id`). A REMOVE is matched by
        // `remove_unique_command`, which keys `unique_instances` on
        // (definition, scope, scope_id, source_type, source_id) and answers
        // `already_removed` on a miss -- so any difference here leaves the applied
        // row alive while reporting success.
        //
        // `remove` used to be mixed into this hash, which guaranteed that
        // difference: every unequip retired the slot and the binding but left the
        // national Modifier row in place, and the stat kept its buffed value.
        uint64_t hash = 1469598103934665603ULL;
        hash = mixv(hash, country_handle); hash = mixv(hash, ideology_id); hash = mixv(hash, level);
        hash = mixv(hash, begin + offset); hash = mixv(hash, salt);
        const int64_t effect_id = static_cast<int64_t>(hash & 0x7fffffffffffffffULL);
        const int32_t opcode = remove ? 2 : templ.opcode; // Modifier COMMAND_REMOVE
        EffectRuntime::ExternalEffectCommandPod command;
        command.effect_id = effect_id;
        command.source_id = tier_source_id;
        command.program_key = "ideology.command";
        command.fire_sequence = static_cast<uint64_t>(offset + 1);
        command.action = templ.action;
        command.domain = templ.domain;
        command.opcode = opcode;
        command.resolved_value = templ.value_q16;
        command.duration_days = templ.duration_days;
        command.stacks = templ.stacks;
        command.command_key = templ.command_key;
        command.definition_key = templ.definition_key;
        command.payload = templ.payload;
        commands.push_back(std::move(command));
    }
    return true;
}

std::string NativeIdeologyRuntime::effect_program_key(
        const std::string &definition_key) {
    if (definition_key.empty()) return {};
    return "ideology.effect." + definition_key;
}

int64_t NativeIdeologyRuntime::effect_instance_id(uint64_t country_handle,
        int32_t ideology_id, uint8_t location, int32_t level,
        const std::string &program, uint64_t target_handle, int32_t layer) {
    // Pure function of the owning identity and the target. Anything that makes
    // the id depend on time, iteration order or counters leaks orphan
    // instances across a save/load round trip.
    uint64_t h = 1469598103934665603ULL;
    h = mixv(h, country_handle);
    h = mixv(h, ideology_id);
    h = mixv(h, location);
    h = mixv(h, level);
    h = mix(h, program.data(), program.size());
    h = mixv(h, target_handle);
    // Only for stacked programs. Mixing 0 unconditionally would renumber every
    // instance in every save, for an argument that is 0 for all of them.
    if (layer != 0) h = mixv(h, layer);
    const int64_t id = static_cast<int64_t>(h & 0x7fffffffffffffffULL);
    return id == 0 ? 1 : id;
}

bool NativeIdeologyRuntime::copy_source_state(const CountryState &country,
        const IdeaState &state, const IdeaState *&source) const {
    source = nullptr;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    if (_definitions[static_cast<size_t>(
            state.ideology_id)].copy_left_programs == 0)
        return false;
    if (state.location == INACTIVE || state.slot_index == 0)
        return false;
    const uint8_t wanted_slot = static_cast<uint8_t>(state.slot_index - 1);
    for (const IdeaState &candidate : country.ideas) {
        if (candidate.location != state.location ||
                candidate.slot_index != wanted_slot ||
                candidate.ideology_id == state.ideology_id)
            continue;
        source = &candidate;
        return true;
    }
    return false;
}

bool NativeIdeologyRuntime::copy_source_programs(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    const IdeaState *source = nullptr;
    if (!copy_source_state(country, state, source) || source == nullptr)
        return false;
    if (source->ideology_id < 0 ||
            source->ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    if (source->level < 0) return true;
    const Definition &definition = _definitions[
        static_cast<size_t>(source->ideology_id)];
    if (source->level >= definition.level_count) return true;
    // Legendary/rule cards are never copy sources, at any copier level. The
    // source program list is still the source's level list, never its live
    // Effect instance table.
    if (definition.copyable == 0) return true;
    const Level &row = _levels[
        static_cast<size_t>(definition.level_begin + source->level)];
    out.reserve(static_cast<size_t>(row.persistent_count));
    for (int32_t offset = 0; offset < row.persistent_count; ++offset)
        out.push_back(&_persistent_templates[
            static_cast<size_t>(row.persistent_begin + offset)]);
    return true;
}

void NativeIdeologyRuntime::collect_copied_legacy_templates(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()) ||
            state.level < 0)
        return;
    const Definition &definition = _definitions[
        static_cast<size_t>(state.ideology_id)];
    if (state.level >= definition.level_count) return;
    const Level &own_level = _levels[
        static_cast<size_t>(definition.level_begin + state.level)];
    if (definition.copy_left_programs == 0) {
        out.reserve(static_cast<size_t>(own_level.persistent_count));
        for (int32_t offset = 0; offset < own_level.persistent_count; ++offset)
            out.push_back(&_persistent_templates[
                static_cast<size_t>(own_level.persistent_begin + offset)]);
        return;
    }
    // `emit_level_effects` is the legacy Modifier batch. Managed rows are owned by
    // the Effect reconciler, not this path, but the copier's own national/price
    // rows must remain active even when its managed list comes from a neighbour.
    for (int32_t offset = 0; offset < own_level.persistent_count; ++offset) {
        const EffectTemplate *templ = &_persistent_templates[
            static_cast<size_t>(own_level.persistent_begin + offset)];
        const std::string program = effect_program_key(templ->definition_key);
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (_effect_runtime != nullptr && !program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        out.push_back(templ);
    }
    std::vector<const EffectTemplate *> copied;
    if (!copy_source_programs(country, state, copied)) return;
    for (const EffectTemplate *templ : copied) {
        const std::string program = effect_program_key(templ->definition_key);
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (_effect_runtime != nullptr && !program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        out.push_back(templ);
    }
}

void NativeIdeologyRuntime::apply_fan_out_ownership_filter(
        int32_t source_cell, int32_t ownership_scope,
        std::vector<int32_t> &cells) const {
    if (_economy_runtime == nullptr) return;
    if (ownership_scope == EffectRuntime::OWNERSHIP_ANY) return;
    // The source came out of OWN_TERRITORY, so its owner IS the card's country.
    // Read per source rather than once: a multi-country world can have sources in
    // different slots once the collector is widened, and a cached slot would silently
    // mis-filter.
    const int32_t source_country = economy_api::cell_country_slot(*_economy_runtime, source_cell);
    if (source_country < 0) return;
    cells.erase(
        std::remove_if(cells.begin(), cells.end(),
            [&](int32_t target) {
                // Three cases, not two: an unowned target is neither own nor "another
                // country", and FOREIGN must not swallow neutral land.
                const pk::OwnershipRelation relation = pk::ownership_relation(
                    source_country, economy_api::cell_country_slot(*_economy_runtime, target));
                return !pk::ownership_accepts(ownership_scope, relation);
            }),
        cells.end());
}

void NativeIdeologyRuntime::apply_union_ownership_filter(
        int32_t country_slot, int32_t ownership_scope,
        std::vector<int32_t> &cells) const {
    if (_economy_runtime == nullptr) return;
    if (ownership_scope == EffectRuntime::OWNERSHIP_ANY) return;
    if (country_slot < 0) return;
    cells.erase(
        std::remove_if(cells.begin(), cells.end(),
            [&](int32_t target) {
                const pk::OwnershipRelation relation = pk::ownership_relation(
                    country_slot, economy_api::cell_country_slot(*_economy_runtime, target));
                return !pk::ownership_accepts(ownership_scope, relation);
            }),
        cells.end());
}

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

void NativeIdeologyRuntime::resolve_program_fold_terms(
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const std::string &program,
        std::vector<DerivedProgramContribution::Term> &out,
        bool count_diagnostics) const {
    out.clear();
    std::vector<EffectRuntime::ProgramModifierCommand> commands;
    if (_effect_runtime == nullptr ||
            !_effect_runtime->program_modifier_commands(program, commands) ||
            _modifier_runtime == nullptr)
        return;
    for (const EffectRuntime::ProgramModifierCommand &command : commands) {
        std::vector<ModifierApi::ResolvedTerm> terms;
        if (!modifier_api::resolve_definition_terms(*_modifier_runtime,
                command.definition_key, terms))
            continue;  // counted by the materializer's missing_stat
        const int64_t magnitude = std::clamp<int64_t>(
            command.value_q16, 0, ModifierApi::MAX_MAGNITUDE_Q16);
        // ── M3: a metric-fed ramp must stay a LIVE function ──────
        //
        // `command.value_q16` is only meaningful when the magnitude is
        // a compile-time constant. For a Ramp it holds whatever the top
        // of the value stack was, NOT the program's output, so folding it
        // here would freeze the effect at the metric value seen during
        // materialise -- precisely the stale "threshold bucket" that
        // plan §15.5 forbids.
        //
        // So the term records WHICH metric it follows and at what scale,
        // and the materializer evaluates it per cell (the shipping stack
        // machine is already reachable through
        // `evaluate_program_magnitude_for_metrics`).
        //
        // A program reading several metrics would need a per-term
        // distinction no authored content currently requires; the FIRST
        // readable id is recorded so the choice is explicit rather than
        // silently made during evaluation.
        // A Ramp is exactly "not a compile-time constant AND reads a
        // metric": `value_mode != VALUE_CONSTANT` alone would also catch
        // a stack-top command that reads no metric, and
        // `metric_mask.is_any()` alone would catch a program whose
        // CONDITIONS read a metric while its magnitude stays constant.
        const bool ramp = command.value_mode !=
                EffectRuntime::VALUE_CONSTANT &&
            metadata.metric_mask.is_any();
        // Diagnostic: a ramp card that reports `taken=0 deferred=0` is
        // indistinguishable from one whose metrics never reached this
        // branch. These counters say which half of the condition failed.
        //
        // NOT counted when the caller only wants the digest: the applied-basis
        // rebuild runs on every capture, and a save must not move a number that
        // fixtures read as an exact measurement of the fold.
        if (count_diagnostics &&
                command.value_mode != EffectRuntime::VALUE_CONSTANT) {
            ++_ramp_candidates;
            if (metadata.metric_mask.is_any()) ++_ramp_metric_ok;
        }
        int32_t ramp_metric_id = -1;
        if (ramp) {
            for (int32_t id = 0; id < MetricMask::CAPACITY; ++id) {
                if (metadata.metric_mask.test(id)) {
                    ramp_metric_id = id;
                    break;
                }
            }
        }
        for (const ModifierApi::ResolvedTerm &term : terms) {
            DerivedProgramContribution::Term row;
            row.stat_id = term.stat_id;
            row.operation = term.operation;
            // Plan §5.4: `term.add * stacks * magnitude`. The sign
            // lives in the DEFINITION (a `.cut` twin is a SUBTRACT
            // term whose value is negative), never in the magnitude,
            // because magnitudes are clamped to [0, 4].
            const double scaled_magnitude =
                static_cast<double>(magnitude) /
                static_cast<double>(Q16_ONE);
            const double stacks =
                static_cast<double>(std::max(1, command.stacks));
            if (ramp && ramp_metric_id >= 0) {
                // The resolved term value becomes the SCALE; the
                // magnitude arrives per cell from the sample. `add` and
                // `factor` stay neutral here because the materializer
                // substitutes the sampled value for them -- leaving a
                // constant in `add` would double-count.
                row.magnitude_source =
                    DerivedProgramContribution::MagnitudeSource::RampMetric;
                row.metric_id = ramp_metric_id;
                // THE PROGRAM OWNS THE MAGNITUDE, not `term.value`.
                //
                // An earlier version scaled by `term.value * stacks / Q16`
                // and claimed in a comment that "the authored MIN/MAX inside
                // the instruction stream already bound the sample". That is
                // false: the derived path never executes the instruction
                // stream, so it sampled the RAW metric.
                //
                // Measured on `salt_monopoly_l1`
                // (`CONST 655 -> READ_METRIC -> CONST 983040 -> MIN -> MUL
                // -> EMIT`): the interpreter gives a constant 9825 while the
                // derived path gave 40 and 120 for the same two inputs, and
                // the contribution saturated the stat at its clamp_max
                // (M5-13). The key travels with the term so the materializer
                // can ask the stack machine instead.
                row.program_key = intern_program_key(program);
                row.ramp_scale = term.value * stacks /
                    static_cast<double>(Q16_ONE);
                row.ramp_has_ceil = false;
                row.add = 0.0;
                row.factor = 1.0;
            } else {
                row.add = term.operation == ModifierApi::ADD
                    ? term.value * stacks * scaled_magnitude : 0.0;
                row.factor = term.operation == ModifierApi::ADD
                    ? 1.0 : std::pow(term.value, stacks);
            }
            out.push_back(row);
        }
    }
}

bool NativeIdeologyRuntime::resolve_contribution_templates(
        const CountryState &country, const IdeaState &state,
        int32_t &contribution_level,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    contribution_level = -1;
    if (state.location == INACTIVE) return false;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    // ── WHICH LEVEL DOES A PENDING CARD CONTRIBUTE? (plan §10.1) ─────────────
    //
    // "pending 期间使用旧基础": a pending TRANSITION serves the previous level, and a
    // pending EQUIP has `previous_location == INACTIVE`, i.e. the card was not
    // equipped before, so it contributes NOTHING until its ACK lands.
    int32_t level = state.level;
    if (state.transition.active != 0) {
        if (state.transition.previous_location == INACTIVE) return false;
        if (state.transition.previous_level < 0) return false;
        level = state.transition.previous_level;
    }
    if (level < 0 || level >= definition.level_count) return false;
    contribution_level = level;
    if (definition.copy_left_programs != 0) {
        // A copier never falls back to its own managed list. No left slot (or
        // a noncopyable source) means it has no managed activations.
        (void)copy_source_programs(country, state, out);
    } else {
        const Level &row = _levels[
            static_cast<size_t>(definition.level_begin + level)];
        out.reserve(static_cast<size_t>(row.persistent_count));
        for (int32_t offset = 0; offset < row.persistent_count; ++offset)
            out.push_back(&_persistent_templates[
                static_cast<size_t>(row.persistent_begin + offset)]);
    }
    return true;
}

bool NativeIdeologyRuntime::collect_effect_activations(
        const CountryState &country, const IdeaState &state,
        std::vector<EffectActivation> &out,
        std::vector<DerivedProgramContribution> *out_derived) const {
    out.clear();
    if (_effect_runtime == nullptr) return true;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return true;
    ++_collect_entries;
    // ── WHICH LEVEL DOES A PENDING CARD CONTRIBUTE? (plan §10.1) ─────────────
    //
    // The plan says: "pending 期间使用旧基础：升级保留旧等级，卸卡保留旧贡献，尚未确认的装卡
    // 不产生贡献". This implements it.
    //
    // `start_transition` writes `state.level = target` at REQUEST time (`:3598`), so
    // reading `state.level` here served the NEW level's magnitudes while the transition's
    // Effect transactions had not been ACKed at all. Measured on a level-up with
    // `transition_transaction_statuses == [1, 1]` (both PLANNED, zero ACKs): the covered
    // cell already read the L2 add 0.08000183 instead of the L1 0.05000305. Settling then
    // changed nothing, which is exactly why a content check could not see it -- only
    // comparing the pending window against the settled state could (M5-69).
    //
    // `:5006-5007` -- the daily understanding accrual for this SAME card -- already does
    // it right:
    //
    //     growth_level = state->transition.active != 0 ? previous_level : state->level
    //
    // The two halves of one card disagreed. This makes the contribution half agree, and
    // adds the other half of the same rule: a pending EQUIP has
    // `previous_location == INACTIVE`, i.e. the card was not equipped before, so it must
    // contribute NOTHING until its ACK lands.
    if (state.location == INACTIVE) return true;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    int32_t contribution_level = -1;
    std::vector<const EffectTemplate *> active_templates;
    // The level-selection rule lives in ONE place now
    // (`resolve_contribution_templates`), because the applied-program basis has to
    // read the same level: a second copy is exactly the M5-69 defect, where the
    // contribution half and the accrual half disagreed about a pending transition.
    if (!resolve_contribution_templates(country, state, contribution_level,
            active_templates))
        return true;
    for (const EffectTemplate *templ_ptr : active_templates) {
        ++_collect_templates;
        const EffectTemplate &templ = *templ_ptr;
        const std::string program = effect_program_key(templ.definition_key);
        if (program.empty()) { ++_collect_program_empty; continue; }
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(program, metadata)) {
            // No declarative program: the row stays on the legacy batch.
            ++_collect_pod_fail;
            // Record WHICH program: a bare count cannot tell "the card never became
            // active" apart from "the card is active but its program is missing".
            if (_collect_pod_fail_keys.size() < 8)
                _collect_pod_fail_keys.push_back(program);
            continue;
        }
        // Record the SUCCESSES too: a cost entry legitimately fails POD, so the failure
        // list alone cannot say whether the card's real effect resolved.
        if (_collect_pod_ok_keys.size() < 8)
            _collect_pod_ok_keys.push_back(program);
        (void)state;
        std::vector<EffectTarget> targets;
        const bool targets_ok = resolve_effect_targets(country, state, program,
            metadata, effect_program_hash(program), targets);
        if (!targets_ok) { ++_collect_targets_fail; continue; }

        // ── Backend split (plan 22 §4.4 / §4.5 / I01) ──────────────────────
        //
        // The eligibility column is consulted ONCE, here. A DerivedCell program
        // contributes rows to the Modifier derived layer and creates NO
        // instances -- which is what removes the 32-cell cap for it, because the
        // cap below exists only to bound the instance table.
        //
        // Everything else keeps the instance path unchanged. I01 forbids one
        // program having two backends in the same configuration, so this is an
        // exclusive branch, not an addition.
        const CellProgramDecision backend =
            decide_cell_program_backend(cell_program_facts_for(
                program, metadata, state));
        // ── I01 is decided by CAPABILITY + ROLLOUT, not by the caller ─────
        //
        // This used to require `out_derived != nullptr` as well, which meant the
        // INSTANCE call site (`reconcile_effect_activations`, :2483, passes nullptr)
        // ignored the rollout entirely while the DERIVED call site
        // (`step_derived_rebuild`) honoured it. With a batch enabled both ran,
        // so the same program created instances AND contributed rows -- a direct
        // violation of I01 ("one program, one backend") and the reason the M4
        // per-source scale fix appeared to do nothing: the value the fixture read
        // came from the surviving INSTANCE, not from the derived row
        // (measured `present=[1,1,1,1]`, see M4-3).
        //
        // The condition is now "should this program be derived", and the caller only
        // decides whether it CAN receive rows. A derived program is skipped by the
        // instance path either way.
        const bool derive_this_program =
            cell_program_rollout_enabled(metadata.target_selector_kind) &&
            backend.backend == CellProgramBackend::DerivedCell;
        if (derive_this_program && out_derived == nullptr) {
            // Derived backend, but this call site collects no rows: emit NOTHING so
            // the instance path cannot double-apply it. `step_derived_rebuild`
            // is the only producer of the derived rows.
            continue;
        }
        if (derive_this_program) {
            // ── One contribution PER TARGET, not one per program ──────────
            //
            // `EffectTarget` carries `magnitude_scale_q16`
            // (ideology_runtime.h:456), and for SELECTOR_TAG_SOURCE_COUNT the
            // instance path normalises it to `min(count, cap) / cap`
            // (ideology_runtime.cpp:2079-2081). Collecting every cell into ONE
            // contribution threw that scale away, so a cell bracketed by two
            // sources read 1.23999 where the instance path reads 1.12 -- a
            // difference of exactly one source contribution (measured, see
            // artifacts/ideology-cell-layer/m4/M4-2-per-source-scale-rootcause.md).
            //
            // Emitting one contribution per target keeps the fold in the
            // materializer unchanged (it already walks contribution -> cells) and
            // lets each cell carry its own scale.
            // ── school strength must reach the DERIVED backend too ────────
            //
            // It used to be applied only on the instance path, which multiplies
            // `activation_scale_q16` by `school_strength_scale_q16` (the LEGACY branch
            // below does exactly that). So a school's strength affected its
            // country-domain cards and silently did nothing for its kind-12 cell cards
            // -- the majority of the catalog. A mechanism that works on one of two
            // backends is worse than one that works on neither, because it lies: a
            // designer writes "agrarian school strength +25%", verifies it on a
            // country-domain card, and most agrarian cards never move.
            //
            // This mirrors the instance path exactly, INCLUDING its self-reference
            // guard: a card that itself writes its own school's strength stat must not
            // then be scaled by it.
            //
            // Zero-risk when written: no shipped content writes any of the six
            // `country.ideology.school_strength_factor.*` stats (measured: zero
            // modifier-definition terms target them), so the factor is 1.0 in every
            // shipped configuration and this multiplies by 1.0. It only starts to
            // matter the day content drives the stat -- which is the point: doing it
            // now is free, doing it then is a re-balance of every derived card.
            double derived_school_scale = 1.0;
            {
                const int32_t school_index = definition.school_index;
                if (!program_writes_school_strength(program, school_index)) {
                    derived_school_scale = static_cast<double>(
                        school_strength_scale_q16(country, school_index)) /
                        static_cast<double>(Q16_ONE);
                }
            }
            // I01: the backend must not change what a program does. The instance branch
            // scales a copier's copied programs by 1.2x at level >= 2; without the same
            // term here a derived copier would silently drop that bonus.
            //
            // Measured: shipped content has exactly one copier
            // (idea.algorithmic_governance) and its effects target the Modifier domain,
            // not cells, so this is a no-op today. It stops being one the moment a copier
            // targets cells -- which is precisely what I01 is for.
            double derived_copy_scale = 1.0;
            if (definition.copy_left_programs != 0 && state.level >= 2)
                derived_copy_scale = static_cast<double>(kCopierLevelTwoScaleQ16) /
                    static_cast<double>(Q16_ONE);
            // Plan 22 §5.2: a program-level condition gates each TARGET. This path
            // used to skip it, so the 41 conditional OWN_TERRITORY programs
            // (village_compact, subsidy_state, ...) applied to every candidate
            // cell whatever their metric said (lifecycle / country_ramp fixtures,
            // 2026-11-14). Sampled at the target through the economy sampler the
            // instance path and the ramp sampler read, test overrides included.
            // No economy means the condition cannot be read: emit nothing.
            // Same slab as the instance path: economy metrics, then the ideology
            // scalars (equipped count, era, ...). The scalars are fixed for this
            // card and sit above the range the sampler rewrites per target.
            std::vector<int64_t> condition_metrics;
            if (metadata.condition_count > 0) {
                if (_economy_runtime == nullptr) continue;
                condition_metrics.assign(static_cast<size_t>(std::max(
                    kEconomyMetricCount, _effect_runtime->metric_count())), 0);
                fill_ideology_scalars(country, state, condition_metrics);
            }
            std::vector<DerivedProgramContribution> per_target;
            per_target.reserve(targets.size());
            for (const EffectTarget &t : targets) {
                if (!condition_metrics.empty()) {
                    const int32_t count =
                        static_cast<int32_t>(condition_metrics.size());
                    economy_api::sample_effect_metrics(*_economy_runtime,
                        static_cast<int32_t>(t.handle), kEconomyMetricCount,
                        condition_metrics.data(), metadata.metric_mask);
                    bool passes = false;
                    std::string condition_error;
                    if (!_effect_runtime->evaluate_program_conditions_for_metrics(
                            program, condition_metrics.data(), count, passes,
                            condition_error) || !passes)
                        continue;
                }
                DerivedProgramContribution single;
                single.source_country = country.handle;
                single.ideology_id = state.ideology_id;
                single.level = contribution_level;
                single.program_hash = effect_program_hash(program);
                single.backend = CellProgramBackend::DerivedCell;
                single.cells.push_back(static_cast<int32_t>(t.handle));
                single.magnitude_scale =
                    static_cast<double>(t.magnitude_scale_q16) /
                    static_cast<double>(Q16_ONE) * derived_school_scale *
                    derived_copy_scale;
                per_target.push_back(std::move(single));
            }
            std::vector<DerivedProgramContribution::Term> fold_terms;
            resolve_program_fold_terms(metadata, program, fold_terms, true);
            for (const DerivedProgramContribution::Term &row : fold_terms) {
                // A SUBTRACT term arrives as ADD with a negative value
                // from the resolver, so a `.cut` card must fold its
                // magnitude negatively rather than being dropped.
                for (DerivedProgramContribution &single : per_target) {
                    DerivedProgramContribution::Term scaled = row;
                    // `magnitude_scale` is 1.0 for every selector except
                    // TAG_SOURCE_COUNT, so this is a no-op for kinds 12/14/15.
                    scaled.add *= single.magnitude_scale;
                    if (scaled.operation != 0)
                        scaled.factor = std::pow(scaled.factor,
                            single.magnitude_scale);
                    single.terms.push_back(scaled);
                }
            }
            // Hand to the caller's accumulator; `collect_effect_activations`
            // stays a pure collector so `reconcile_effect_activations` (and the
            // pod mirror) can decide when to materialise.
            for (DerivedProgramContribution &single : per_target) {
                out_derived->push_back(std::move(single));
                ++_collect_derived_emitted;
            }
            continue;  // no instance, no cap, no ACK
        }
        // LEGACY INSTANCE PROTECTION: one instance per resolved target, capped so a
        // wide selector cannot flood the instance table.
        //
        // This branch is reached ONLY by programs the derived layer did not take
        // (`continue` above handles those). So the 32 here bounds INSTANCES, not cell
        // coverage -- a derived card covers the whole territory with zero instances.
        if (static_cast<int32_t>(targets.size()) >
                EffectRuntime::LEGACY_INSTANCE_MAX_CELLS)
            targets.resize(static_cast<size_t>(
                EffectRuntime::LEGACY_INSTANCE_MAX_CELLS));
        // ADD_STACK rows own one instance PER LAYER, not one instance carrying a
        // stack count: the whole point of L2-8 is that layers can expire
        // independently, and a single instance has a single `duration_days`. Any
        // other policy keeps exactly one instance, so their ids are unchanged.
        const bool layered = metadata.stack_policy == 2; // ADD_STACK
        const int32_t layers = layered
            ? std::clamp(templ.stacks, 1, std::max(1, metadata.max_stacks)) : 1;
        // Hoisted out of the target x layer loops: the value depends only on the
        // country, the program, and the copier level, so a 32-cell x 3-layer row
        // would otherwise rescan every synergy 96 times for the same answer.
        const int32_t copy_scale_q16 =
            definition.copy_left_programs != 0 && state.level >= 2
                ? kCopierLevelTwoScaleQ16 : static_cast<int32_t>(Q16_ONE);
        int64_t activation_scale_q16 =
            static_cast<int64_t>(magnitude_scale_for(country, program)) *
            copy_scale_q16 / Q16_ONE;
        const int32_t school_index = definition.school_index;
        if (!program_writes_school_strength(program, school_index)) {
            activation_scale_q16 =
                activation_scale_q16 *
                school_strength_scale_q16(country, school_index) / Q16_ONE;
        }
        activation_scale_q16 = std::clamp<int64_t>(
            activation_scale_q16, Q16_ONE / 4, 4 * Q16_ONE);
        for (const auto &target : targets) {
            for (int32_t layer = 0; layer < layers; ++layer) {
                EffectActivation activation;
                activation.program = program;
                activation.source_kind = metadata.source_kind;
                activation.target_domain = metadata.target_domain;
                activation.metric_mask = metadata.metric_mask;
                activation.scalar_mask = metadata.scalar_mask;
                // L3-9: resolved per country from ACTIVE synergies, so the same
                // program can be rewritten for one country and untouched for
                // another. 1.0 when no active synergy targets it.
                const int32_t target_scale_q16 = static_cast<int32_t>(
                    static_cast<int64_t>(activation_scale_q16) *
                    target.magnitude_scale_q16 / Q16_ONE);
                activation.magnitude_scale_q16 = target_scale_q16;
                activation.ref.magnitude_scale_q16 = target_scale_q16;
                activation.ref.program_hash = effect_program_hash(program);
                activation.ref.target_handle = target.handle;
                activation.ref.target_generation = target.generation;
                activation.ref.instance_id = effect_instance_id(country.handle,
                    state.ideology_id, state.location, state.level, program,
                    target.handle, layer);
                activation.ref.generation = std::max(1U, state.generation);
                out.push_back(std::move(activation));
            }
        }
    }
    std::sort(out.begin(), out.end(),
        [](const EffectActivation &lhs, const EffectActivation &rhs) {
            if (lhs.ref.instance_id != rhs.ref.instance_id)
                return lhs.ref.instance_id < rhs.ref.instance_id;
            return lhs.program < rhs.program;
        });
    return true;
}

void NativeIdeologyRuntime::collect_idea_program_domains(
        const CountryState &country, const IdeaState &state,
        std::unordered_map<uint64_t, int32_t> &out) const {
    out.clear();
    if (_effect_runtime == nullptr) return;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return;
    // Same preconditions as collect_effect_activations: an inactive or
    // out-of-range idea owns no instances, so it owns no labels either.
    if (state.location == INACTIVE || state.level < 0) return;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    if (state.level >= definition.level_count) return;
    std::vector<const EffectTemplate *> active_templates;
    if (definition.copy_left_programs != 0) {
        (void)copy_source_programs(country, state, active_templates);
    } else {
        const Level &row = _levels[
            static_cast<size_t>(definition.level_begin + state.level)];
        active_templates.reserve(static_cast<size_t>(row.persistent_count));
        for (int32_t offset = 0; offset < row.persistent_count; ++offset)
            active_templates.push_back(&_persistent_templates[
                static_cast<size_t>(row.persistent_begin + offset)]);
    }
    for (const EffectTemplate *templ_ptr : active_templates) {
        const EffectTemplate &templ = *templ_ptr;
        const std::string program = effect_program_key(templ.definition_key);
        if (program.empty()) continue;
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        const EffectRuntime::FamilyEffectMetadataPod effective =
            effective_selector_metadata(country, program, metadata);
        out[effect_program_hash(program)] = effective.target_domain;
    }
}

void NativeIdeologyRuntime::retire_effect_activations(IdeaState &state,
        int64_t day) {
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) {
        state.effect_instances.clear();
        return;
    }
    for (const IdeaState::EffectInstanceRef &ref : state.effect_instances) {
        // `attached()`, not just non-null: DCWorldExt creates the forwarder with
        // the world and only attach()es it once the Effect catalog exists, and an
        // unattached forwarder answers retire() with unavailable() -- dropping the
        // retire instead of falling back to the legacy authority.
        if (_effect_forwarder != nullptr && _effect_forwarder->attached()) {
            _effect_forwarder->retire(ref.instance_id, ref.generation, day);
            continue;
        }
        std::string ignored;
        _effect_runtime->retire_instance_pod(
            ref.instance_id, ref.generation, day, ignored);
    }
    state.effect_instances.clear();
}

bool NativeIdeologyRuntime::reconcile_effect_activations(
        const CountryState &country, IdeaState &state, int64_t day,
        std::string &error) {
    error.clear();
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) return true;
    std::vector<EffectActivation> desired;
    // Derived contributions are NOT materialised here.
    //
    // `reconcile_effect_activations` runs once per (country, idea) from four
    // call sites. Building a WHOLE front from one country's data and
    // installing it means the last reconcile erases every other country's
    // rows. The materialiser therefore lives in
    // `step_derived_rebuild()`, which walks every country and builds one
    // front -- a global operation for a global output.
    if (!collect_effect_activations(country, state, desired)) return true;

    // Retire before submitting so a superseded instance can never coexist with
    // its replacement for a single tick.
    for (const IdeaState::EffectInstanceRef &held : state.effect_instances) {
        bool keep = false;
        for (const EffectActivation &want : desired) {
            if (want.ref.instance_id == held.instance_id) {
                keep = true;
                break;
            }
        }
        if (keep) continue;
        // Same attached() rule as retire_effect_activations above.
        if (_effect_forwarder != nullptr && _effect_forwarder->attached()) {
            _effect_forwarder->retire(held.instance_id, held.generation, day);
            continue;
        }
        std::string ignored;
        _effect_runtime->retire_instance_pod(
            held.instance_id, held.generation, day, ignored);
    }

    std::vector<const EffectActivation *> added;
    for (const EffectActivation &want : desired) {
        bool present = false;
        for (const IdeaState::EffectInstanceRef &held : state.effect_instances) {
            // The scale is part of "present": a synergy flip can change a
            // card's strength without touching its identity, and skipping the
            // submit here is exactly the X5 bug (the instance keeps the old
            // multiplier until something else makes it re-submit).
            if (held.instance_id == want.ref.instance_id &&
                    held.generation == want.ref.generation &&
                    held.magnitude_scale_q16 == want.ref.magnitude_scale_q16) {
                present = true;
                break;
            }
        }
        if (!present) added.push_back(&want);
    }

    if (!added.empty()) {
        const int32_t count = static_cast<int32_t>(added.size());
        PackedInt64Array ids;
        PackedStringArray program_keys;
        PackedInt32Array generations;
        PackedInt32Array source_types;
        PackedInt32Array source_kinds;
        PackedInt64Array source_ids;
        PackedInt64Array source_handles;
        PackedInt64Array target_handles;
        PackedInt32Array target_generations;
        PackedInt32Array levels;
        PackedByteArray active;
        PackedInt64Array next_due_days;
        PackedInt32Array magnitude_scales;
        ids.resize(count);
        program_keys.resize(count);
        generations.resize(count);
        source_types.resize(count);
        source_kinds.resize(count);
        source_ids.resize(count);
        source_handles.resize(count);
        target_handles.resize(count);
        target_generations.resize(count);
        levels.resize(count);
        active.resize(count);
        next_due_days.resize(count);
        magnitude_scales.resize(count);
        const int32_t source_id = state.ideology_id + 1;
        for (int32_t i = 0; i < count; ++i) {
            const EffectActivation &activation = *added[static_cast<size_t>(i)];
            ids[i] = activation.ref.instance_id;
            program_keys[i] = String(activation.program.c_str());
            generations[i] = static_cast<int32_t>(activation.ref.generation);
            source_types[i] = static_cast<int32_t>(0x4944454f); // IDEO
            source_kinds[i] = activation.source_kind;
            source_ids[i] = source_id;
            source_handles[i] = static_cast<int64_t>(country.handle);
            target_handles[i] = static_cast<int64_t>(activation.ref.target_handle);
            target_generations[i] = static_cast<int32_t>(activation.ref.target_generation);
            levels[i] = std::max(0, state.level);
            active[i] = 1;
            next_due_days[i] = day;
            magnitude_scales[i] = activation.magnitude_scale_q16;
        }
        Dictionary batch;
        batch["instance_ids"] = ids;
        batch["program_keys"] = program_keys;
        batch["generations"] = generations;
        batch["source_types"] = source_types;
        batch["source_kinds"] = source_kinds;
        batch["source_ids"] = source_ids;
        batch["source_handles"] = source_handles;
        batch["target_handles"] = target_handles;
        batch["target_generations"] = target_generations;
        batch["levels"] = levels;
        batch["next_due_days"] = next_due_days;
        batch["magnitude_scales"] = magnitude_scales;
        // A5 NOTE: no `latched` column is sent here, deliberately.
        //
        // Everything in `added` is by definition an instance the Effect side does
        // NOT already hold (a held one with matching id/generation/scale is
        // filtered out above), so this side has no knowledge of its latch --
        // sending a column of zeros would be a claim, and `submit_instances`
        // treats an explicit column as authoritative. Omitting the column means
        // "not owned here", which is the truth: the evaluating authority keeps its
        // own latch, and the write-back path (`apply_pod_snapshot`) carries it
        // back. The forwarder's builder also reads no latch from these rows.
        batch["active"] = active;
        // Same attached() rule as the retires: submit_batch on an unattached
        // forwarder can only answer effect_runtime_unavailable, which would read
        // as a rejected card instead of "use the legacy authority".
        const bool forward =
            _effect_forwarder != nullptr && _effect_forwarder->attached();
        const Dictionary result = forward
            ? _effect_forwarder->submit_batch(batch)
            : _effect_runtime->submit_instances(batch);
        if (!static_cast<bool>(result.get("ok", false))) {
            Variant reason = result.get("reason", Variant());
            error = reason.get_type() == Variant::STRING
                ? std::string(String(reason).utf8().get_data())
                : std::string("ideology_effect_instance_submit_failed");
            return false;
        }
        if (int32_t(result.get("rejected", 0)) > 0) {
            error = "ideology_effect_instance_submit_rejected";
            return false;
        }
    }

    // ── Metric snapshots ────────────────────────────────────────────────────
    // A managed ideology program that conditions on a metric reads whatever was
    // last written for its instance. Nothing used to write, so every METRIC_GTE
    // compared `0 >= threshold` and was permanently false while METRIC_LTE was
    // permanently true -- which is why the V1..V6 mechanism cards could only be
    // asserted as declarations, never observed firing.
    //
    // Published on every reconcile that changes something, not only on
    // creation: a condition has to see the world move, and the world moves
    // every day. The digest below is what keeps "the world moves" from being
    // read as "the input changed" -- an identical publish is skipped whole.
    //
    // Cell programs sample their own target cell, so "this cell's extractive
    // share >= 60%" means the cell the effect lands on. Country programs sample
    // the country anchor: country metrics are identical on every owned cell, and
    // the cache key has to be a cell because that is what the sampler takes.
    // One sample per distinct cell per reconcile: nine cards pointing at the
    // same cell cost one building scan, not nine.
    if (!desired.empty()) {
        constexpr int32_t metric_count = kEconomyMetricCount;
        const int32_t effect_metric_count = _effect_runtime == nullptr
            ? metric_count : _effect_runtime->metric_count();
        const int64_t revision = day > (std::numeric_limits<int64_t>::max() - 1) / 4
            ? std::numeric_limits<int64_t>::max() : day * 4 + 1;
        // O3: sample each cell ONCE with the union of the masks that target it.
        // The old `all_declared` mask forced every reconcile to compute all 68
        // columns, and the X7 country counts among them rebuild the whole-map
        // tag bitset -- the most expensive thing in this function.
        std::unordered_map<int32_t, MetricMask> mask_by_cell;
        std::vector<std::pair<int32_t, EffectActivation *>> pending_publishes;
        std::vector<EffectActivation *> pending_scalar_publishes;
        for (EffectActivation &activation : desired) {
            if (activation.metric_mask.is_none() && activation.scalar_mask.is_none())
                continue;
            int32_t cell = -1;
            if (activation.target_domain == 3) {
                // A country program reads country-wide Economy metrics from its
                // anchor cell, but ideology scalars are identical for every
                // cell of the country. Keep a scalar-only country program
                // publishable even when Economy is not attached.
                if (activation.metric_mask.is_none()) {
                    pending_scalar_publishes.push_back(&activation);
                    continue;
                }
                if (_economy_runtime == nullptr) continue;
                const int32_t country_slot =
                    static_cast<int32_t>(country.handle & 0xffffffffULL);
                cell = economy_api::country_anchor_cell(*_economy_runtime, country_slot);
            } else if (activation.target_domain == 2 ||
                       activation.target_domain == 5) {
                const int64_t raw = static_cast<int64_t>(
                    activation.ref.target_handle);
                if (raw < 0 || raw > std::numeric_limits<int32_t>::max())
                    continue;
                cell = static_cast<int32_t>(raw);
            } else {
                continue;
            }
            if (cell < 0) continue;
            mask_by_cell[cell] |= activation.metric_mask;
            pending_publishes.emplace_back(cell, &activation);
        }
        // Ideology scalars are country-wide, so one vector serves every
        // cell. Economy never receives these ids; only the Effect instance
        // slab sees them.
        std::vector<int64_t> scalar_values;
        const bool wants_ideology_scalars =
            !pending_scalar_publishes.empty() ||
            std::any_of(pending_publishes.begin(), pending_publishes.end(),
                [](const std::pair<int32_t, EffectActivation *> &publish) {
                    return publish.second->scalar_mask.is_any();
                });
        if (wants_ideology_scalars) {
            scalar_values.assign(static_cast<size_t>(effect_metric_count), 0);
            fill_ideology_scalars(country, state, scalar_values);
        }
        std::unordered_map<int32_t, std::vector<int64_t>> sampled_by_cell;
        sampled_by_cell.reserve(mask_by_cell.size());
        for (const auto &entry : mask_by_cell) {
            std::vector<int64_t> values(static_cast<size_t>(effect_metric_count), 0);
            std::vector<int32_t> economy_ids;
            entry.second.collect_ids(0, metric_count, economy_ids);
            if (_economy_runtime != nullptr && !economy_ids.empty()) {
                MetricMask economy_mask;
                for (int32_t metric_id : economy_ids) economy_mask.set(metric_id);
                economy_api::sample_effect_metrics(*_economy_runtime, entry.first, metric_count, values.data(),
                    economy_mask);
            }
            if (wants_ideology_scalars)
                fill_ideology_scalars(country, state, values);
            sampled_by_cell.emplace(entry.first, std::move(values));
        }
        // Previous publish per instance. Built before `effect_instances` is
        // rebuilt below; a level change advances the generation, which
        // invalidates the digest by construction.
        std::unordered_map<int64_t, size_t> held_by_instance;
        held_by_instance.reserve(state.effect_instances.size());
        for (size_t held = 0; held < state.effect_instances.size(); ++held)
            held_by_instance.emplace(state.effect_instances[held].instance_id, held);
        for (const auto &publish : pending_publishes) {
            EffectActivation &activation = *publish.second;
            auto found = sampled_by_cell.find(publish.first);
            if (found == sampled_by_cell.end()) continue;
            MetricMask publish_mask = activation.metric_mask;
            publish_mask |= activation.scalar_mask;
            const uint64_t digest = metric_publish_digest(
                publish_mask, found->second);
            const auto held = held_by_instance.find(activation.ref.instance_id);
            if (held != held_by_instance.end()) {
                const IdeaState::EffectInstanceRef &previous =
                    state.effect_instances[held->second];
                if (previous.generation == activation.ref.generation &&
                        previous.metric_digest == digest) {
                    // Same columns, same values, same instance. Publishing
                    // again would advance the Effect input revision and mint a
                    // Modifier transaction for a world that did not move.
                    activation.ref.metric_digest = digest;
                    ++_metric_publishes_skipped;
                    continue;
                }
            }
            std::string metric_error;
            bool published = true;
            for (int32_t metric_id = 0; metric_id < effect_metric_count;
                    ++metric_id) {
                // MetricMask covers 256 ids (infra item L0-1), so this is a
                // plain membership test rather than a shift that would be
                // undefined past 63.
                if (!publish_mask.test(metric_id)) continue;
                // A rejected metric (stale instance raced by a retire) must not
                // fail the reconcile: the instance set is already correct.
                if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                        activation.ref.instance_id, activation.ref.generation,
                        metric_id, revision,
                        found->second[static_cast<size_t>(metric_id)],
                        metric_error)) {
                    published = false;
                    break;
                }
            }
            // Only stamp the digest when every column landed, so a partial
            // publish is retried instead of being remembered as done.
            if (published) {
                activation.ref.metric_digest = digest;
                ++_metric_publishes;
            }
        }
        // Scalar-only activations skip Economy coordinate resolution but still
        // publish the derived inputs into the Effect instance's metric slab.
        for (EffectActivation *activation : pending_scalar_publishes) {
            MetricMask publish_mask = activation->scalar_mask;
            const uint64_t digest = metric_publish_digest(
                publish_mask, scalar_values);
            const auto held = held_by_instance.find(activation->ref.instance_id);
            if (held != held_by_instance.end()) {
                const IdeaState::EffectInstanceRef &previous =
                    state.effect_instances[held->second];
                if (previous.generation == activation->ref.generation &&
                        previous.metric_digest == digest) {
                    activation->ref.metric_digest = digest;
                    ++_metric_publishes_skipped;
                    continue;
                }
            }
            std::string metric_error;
            bool published = true;
            for (int32_t metric_id = 0; metric_id < effect_metric_count;
                    ++metric_id) {
                if (!publish_mask.test(metric_id)) continue;
                if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                        activation->ref.instance_id, activation->ref.generation,
                        metric_id, revision,
                        scalar_values[static_cast<size_t>(metric_id)],
                        metric_error)) {
                    published = false;
                    break;
                }
            }
            if (published) {
                activation->ref.metric_digest = digest;
                ++_metric_publishes;
            }
        }
    }

    state.effect_instances.clear();
    state.effect_instances.reserve(desired.size());
    for (const EffectActivation &activation : desired)
        state.effect_instances.push_back(activation.ref);
    // Stamp the input signature AFTER the set is rebuilt. Every path that
    // reconciles -- transition, restore, worker write-back, refresh -- leaves
    // this current, which is what lets a later refresh skip the card without
    // re-deriving anything.
    state.activation_signature = compute_activation_signature(country, state);
    return true;
}




} // namespace pk
