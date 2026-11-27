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

bool NativeEconomyRuntime::build_family_split_offer(
        int32_t parent, int32_t cell, FamilyFoundingOffer &offer) const {
    if (parent < 0 || parent >= static_cast<int32_t>(families_store().active.size()) ||
        families_store().active[parent] == 0 || cell < 0 || cell >= _cell_count.get() ||
        cell == families_store().origin_cell[parent]) return false;
    int64_t people = 0;
    const uint64_t parent_handle = families_store().handle_for_index(parent);
    for (int32_t p = _family_member_offsets[parent]; p < _family_member_offsets[parent + 1]; ++p) {
        const auto &edge = family_memberships()[_family_member_edge_indices[p]];
        int32_t slot = -1;
        if (population_store().valid_handle(edge.cohort_handle, slot) &&
            population_store().page_cell[slot / COHORT_PAGE_SIZE] == cell)
            people += edge.people;
    }
    if (people < _family_split_population_threshold.get()) return false;
    offer.cell = cell;
    offer.source_family_handle = parent_handle;
    offer.milestone_population = _family_split_population_threshold.get();
    offer.created_day = _current_day.get();
    std::vector<int32_t> used_effects;
    for (int32_t card = 0; card < FAMILY_FOUNDING_CARD_COUNT; ++card) {
        uint64_t identity = 1469598103934665603ULL;
        identity = trace_hash_mix(identity, static_cast<uint64_t>(_seed.get()));
        identity = trace_hash_mix(identity, static_cast<uint64_t>(families_store().stable_id[parent]));
        identity = trace_hash_mix(identity, static_cast<uint32_t>(cell));
        identity = trace_hash_mix(identity, families_store().split_sequence[parent]);
        identity = trace_hash_mix(identity, static_cast<uint64_t>(_family_catalog_hash.get()));
        identity = trace_hash_mix(identity, static_cast<uint32_t>(card));
        identity = trace_hash_mix(identity, static_cast<uint64_t>(_next_family_founding_offer_id.get()));
        int64_t child_stable = static_cast<int64_t>((identity & 0x7fffffffffffffffULL) | 1ULL);
        for (uint64_t probe = 1; _family_stable_ids.count(child_stable) != 0; ++probe)
            child_stable = static_cast<int64_t>((trace_hash_mix(identity, probe) & 0x7fffffffffffffffULL) | 1ULL);
        // A split deliberately changes the family's identity: remove exactly
        // one inherited trait, then deterministically add one or two legal
        // traits. Effects are reconciled from this final child trait set.
        const uint16_t split_flags = families_store().flags[parent];
        const bool retain_only =
            (split_flags & FAMILY_FLAG_SPLIT_RETAIN_ONLY) != 0;
        const bool bonus_weight =
            !retain_only && (split_flags & FAMILY_FLAG_SPLIT_BONUS_WEIGHT) != 0;
        const bool replace_all =
            !retain_only && !bonus_weight &&
            (split_flags & FAMILY_FLAG_SPLIT_REPLACE) != 0;
        const int32_t weight_num = bonus_weight
            ? std::max<int32_t>(128, static_cast<int32_t>(
                split_flags >> FAMILY_FLAG_SPLIT_WEIGHT_SHIFT))
            : 128;
        int32_t parent_prestige = 0;
        int32_t parent_effect_id = -1;
        for (int32_t b = 0; b < static_cast<int32_t>(
                family_influences().active.size()); ++b) {
            if (family_influences().active[b] == 0 ||
                family_influences().family_handle[b] != parent_handle)
                continue;
            parent_prestige = std::max(parent_prestige,
                static_cast<int32_t>(family_influences().prestige_level[b]));
        }
        for (const FamilyEffectBinding &binding : _family_effect_bindings) {
            int32_t b = -1;
            if (!family_influences().valid_handle(binding.branch_handle, b) ||
                family_influences().family_handle[b] != parent_handle)
                continue;
            const int32_t eid = family_effect_id_for_key(binding.definition_key);
            if (eid >= 0 && eid < static_cast<int32_t>(_family_effect_source_kinds.size()) &&
                _family_effect_source_kinds[static_cast<size_t>(eid)] == 1) {
                parent_effect_id = eid;
                break;
            }
        }
        std::vector<FamilyTraitRoll> parent_traits;
        for (const FamilyTraitRoll &roll : family_trait_rolls())
            if (roll.family_handle == parent_handle) parent_traits.push_back(roll);
        std::sort(parent_traits.begin(), parent_traits.end(),
            [](const FamilyTraitRoll &a, const FamilyTraitRoll &b) {
                return a.trait_id < b.trait_id;
            });
        std::vector<FamilyTraitRoll> child_traits;
        std::vector<int32_t> removable_indices;
        for (int32_t candidate = 0; candidate < static_cast<int32_t>(
                parent_traits.size()); ++candidate) {
            bool required = false;
            for (int32_t other = 0; other < static_cast<int32_t>(
                    parent_traits.size()) && !required; ++other) {
                if (other == candidate) continue;
                const int32_t trait_id = parent_traits[other].trait_id;
                for (int32_t p = _family_trait_prerequisite_offsets[trait_id];
                        p < _family_trait_prerequisite_offsets[trait_id + 1]; ++p)
                    required |= _family_trait_prerequisites[p] ==
                        parent_traits[candidate].trait_id;
            }
            if (!required) removable_indices.push_back(candidate);
        }
        const int32_t tier = std::clamp(parent_prestige, 0, 5);
        if (retain_only) {
            static constexpr int32_t kRetainKeepPercent[6] = {
                60, 60, 70, 80, 90, 100
            };
            const int32_t keep_pct = kRetainKeepPercent[tier];
            const int32_t total = static_cast<int32_t>(parent_traits.size());
            const int32_t target_keep = keep_pct >= 100 ? total
                : std::max(0, (total * keep_pct + 50) / 100);
            int32_t to_remove = std::max(0, total - target_keep);
            std::vector<uint8_t> removed_mask(static_cast<size_t>(total), 0);
            std::vector<int32_t> pool = removable_indices;
            for (int32_t r = 0; r < to_remove && !pool.empty(); ++r) {
                const size_t pick = static_cast<size_t>(trace_hash_mix(
                    identity, 0x52454d4f5645ULL + static_cast<uint64_t>(r)) %
                    pool.size());
                removed_mask[static_cast<size_t>(pool[pick])] = 1;
                pool.erase(pool.begin() + static_cast<std::ptrdiff_t>(pick));
            }
            for (int32_t i = 0; i < total; ++i) {
                if (removed_mask[static_cast<size_t>(i)] != 0) continue;
                const FamilyTraitRoll &roll = parent_traits[static_cast<size_t>(i)];
                child_traits.push_back({uint64_t{0}, roll.trait_id,
                    roll.strength_q16, roll.core});
            }
        } else if (bonus_weight) {
            for (const FamilyTraitRoll &roll : parent_traits) {
                child_traits.push_back({uint64_t{0}, roll.trait_id,
                    roll.strength_q16, roll.core});
            }
        } else if (replace_all) {
            static constexpr int32_t kBreakReplacePercent[6] = {
                50, 50, 40, 30, 20, 10
            };
            const int32_t replace_pct = kBreakReplacePercent[tier];
            const int32_t total = static_cast<int32_t>(parent_traits.size());
            int32_t to_replace = (total * replace_pct + 50) / 100;
            if (total > 0 && replace_pct > 0 && to_replace == 0) to_replace = 1;
            std::vector<uint8_t> removed_mask(static_cast<size_t>(total), 0);
            std::vector<int32_t> pool = removable_indices;
            for (int32_t r = 0; r < to_replace && !pool.empty(); ++r) {
                const size_t pick = static_cast<size_t>(trace_hash_mix(
                    identity, 0x52454d4f5645ULL + static_cast<uint64_t>(r)) %
                    pool.size());
                removed_mask[static_cast<size_t>(pool[pick])] = 1;
                pool.erase(pool.begin() + static_cast<std::ptrdiff_t>(pick));
            }
            for (int32_t i = 0; i < total; ++i) {
                if (removed_mask[static_cast<size_t>(i)] != 0) continue;
                const FamilyTraitRoll &roll = parent_traits[static_cast<size_t>(i)];
                child_traits.push_back({uint64_t{0}, roll.trait_id,
                    roll.strength_q16, roll.core});
            }
        } else {
            const int32_t removed_index = removable_indices.empty() ? -1 :
                removable_indices[static_cast<size_t>(trace_hash_mix(identity,
                    0x52454d4f5645ULL) % removable_indices.size())];
            for (int32_t i = 0; i < static_cast<int32_t>(parent_traits.size()); ++i) {
                if (i == removed_index) continue;
                const FamilyTraitRoll &roll = parent_traits[i];
                child_traits.push_back({uint64_t{0}, roll.trait_id,
                    roll.strength_q16, roll.core});
            }
        }
        auto has_trait = [&](int32_t trait_id) {
            return std::any_of(child_traits.begin(), child_traits.end(),
                [&](const FamilyTraitRoll &roll) { return roll.trait_id == trait_id; });
        };
        auto legal_trait = [&](int32_t trait_id) {
            if (trait_id < 0 || trait_id >= static_cast<int32_t>(_family_trait_ids.size()) ||
                has_trait(trait_id)) return false;
            for (int32_t p = _family_trait_prerequisite_offsets[trait_id];
                    p < _family_trait_prerequisite_offsets[trait_id + 1]; ++p) {
                if (!has_trait(_family_trait_prerequisites[p])) return false;
            }
            for (int32_t p = _family_trait_exclusion_offsets[trait_id];
                    p < _family_trait_exclusion_offsets[trait_id + 1]; ++p) {
                if (has_trait(_family_trait_exclusions[p])) return false;
            }
            for (const FamilyTraitRoll &roll : child_traits) {
                for (int32_t p = _family_trait_exclusion_offsets[roll.trait_id];
                        p < _family_trait_exclusion_offsets[roll.trait_id + 1]; ++p) {
                    if (_family_trait_exclusions[p] == trait_id) return false;
                }
            }
            return (family_trait_technology_unlocked(trait_id, cell) &&
                family_trait_origin_gates_allow(trait_id, cell));
        };
        int32_t additions = 0;
        if (retain_only) {
            additions = 0;
        } else if (bonus_weight) {
            static constexpr int32_t kAbsorbExtraTraits[6] = {
                1, 1, 1, 2, 3, 4
            };
            additions = kAbsorbExtraTraits[tier];
        } else if (replace_all) {
            static constexpr int32_t kBreakExtraTraits[6] = {
                0, 0, 1, 1, 2, 3
            };
            const int32_t replaced_count = std::max(0,
                static_cast<int32_t>(parent_traits.size()) -
                static_cast<int32_t>(child_traits.size()));
            additions = std::max(1, replaced_count + kBreakExtraTraits[tier]);
        } else {
            additions = 1 + static_cast<int32_t>(
                trace_hash_mix(identity, 0x414444434f554e54ULL) % 2ULL);
        }
        for (int32_t add = 0; add < additions; ++add) {
            std::vector<int32_t> candidates;
            int64_t total_weight = 0;
            for (int32_t trait_id = 0; trait_id < static_cast<int32_t>(
                    _family_trait_ids.size()); ++trait_id) {
                if (!legal_trait(trait_id)) continue;
                candidates.push_back(trait_id);
                int64_t weight = std::max<int32_t>(1, _family_trait_weights[trait_id]);
                if (bonus_weight)
                    weight = std::max<int64_t>(1, weight * weight_num / 128);
                total_weight += weight;
            }
            if (candidates.empty() || total_weight <= 0) break;
            int64_t roll = static_cast<int64_t>(trace_hash_mix(identity,
                0x4144440000ULL + static_cast<uint64_t>(add)) %
                static_cast<uint64_t>(total_weight));
            int32_t chosen = candidates.back();
            for (int32_t trait_id : candidates) {
                int64_t weight = std::max<int32_t>(1,
                    _family_trait_weights[trait_id]);
                if (bonus_weight)
                    weight = std::max<int64_t>(1, weight * weight_num / 128);
                if (roll < weight) { chosen = trait_id; break; }
                roll -= weight;
            }
            const int32_t lo = _family_trait_strength_min_q16[chosen];
            const int32_t hi = _family_trait_strength_max_q16[chosen];
            const int32_t step = _family_trait_strength_step_q16[chosen];
            const int32_t steps = std::max(0, (hi - lo) / step);
            const int32_t strength = lo + step * static_cast<int32_t>(
                trace_hash_mix(identity, 0x535452454e475448ULL +
                    static_cast<uint64_t>(add)) % static_cast<uint64_t>(steps + 1));
            child_traits.push_back({uint64_t{0}, chosen, strength, 0});
        }

        FamilyFoundingCandidate candidate;
        candidate.stable_id = child_stable;
        candidate.surname_id = families_store().surname_id[parent];
        candidate.culture_group_id = families_store().culture_group_id[parent];
        candidate.founders = people;
        for (const auto &roll : child_traits) {
            candidate.trait_ids.push_back(roll.trait_id);
            candidate.trait_strength_q16.push_back(roll.strength_q16);
        }
        // Freeze a complete proposal; the UI never rolls traits or effects.
        if (retain_only) {
            static constexpr uint64_t kRetainKeepPercent[6] = {
                60, 60, 70, 80, 90, 100
            };
            if (parent_effect_id >= 0 &&
                trace_hash_mix(identity, 0x4b454550454646ULL) % 100ULL <
                    kRetainKeepPercent[tier]) {
                candidate.effect_id = parent_effect_id;
            } else {
                candidate.effect_id = -1;
            }
        } else if (bonus_weight && parent_effect_id >= 0 && tier < 2) {
            candidate.effect_id = parent_effect_id;
        } else {
            candidate.effect_id = roll_random_pool_family_effect(
                static_cast<uint64_t>(child_stable), cell, {}, used_effects);
        }
        if (candidate.effect_id >= 0) used_effects.push_back(candidate.effect_id);
        for (int32_t p = _family_owned_offsets[parent]; p < _family_owned_offsets[parent + 1]; ++p) {
            const auto &ownership = family_ownerships()[_family_owned_edge_indices[p]];
            const int32_t group = building_index_for_handle(ownership.building_handle);
            if (group < 0 || buildings_store().cell[group] != cell || ownership.owned_count <= 0) continue;
            candidate.building_handle = ownership.building_handle;
            candidate.building_type_id = buildings_store().type_id[group];
            candidate.owner_signature_id = buildings_store().owner_signature_id[group];
            break;
        }
        offer.candidates.push_back(std::move(candidate));
    }
    return !offer.candidates.empty();
}

bool NativeEconomyRuntime::resolve_family_split_offer(
        const FamilyFoundingOffer &offer, int32_t choice_index) {
    int32_t parent = -1;
    if (!families_store().valid_handle(offer.source_family_handle, parent) ||
        choice_index < 0 || choice_index >= static_cast<int32_t>(offer.candidates.size()) ||
        offer.cell == families_store().origin_cell[parent] ||
        family_population_in_cell(offer.source_family_handle, offer.cell) <= 0) return false;
    const auto &candidate = offer.candidates[static_cast<size_t>(choice_index)];
    if (_family_stable_ids.count(candidate.stable_id) != 0) return false;
    const int32_t child = families_store().allocate();
    reset_family_policy_factors(child);
    const uint64_t child_handle = families_store().handle_for_index(child);
    families_store().stable_id.write_scalar(child, candidate.stable_id, market_mutation_sink());
    _family_stable_ids.insert(candidate.stable_id);
    families_store().surname_id.write_scalar(child, candidate.surname_id, market_mutation_sink());
    families_store().surname_disambiguator.write_scalar(child, 0, market_mutation_sink());
    if (candidate.surname_id >= 0 && static_cast<size_t>(candidate.surname_id) < _family_surname_members.size()) {
        auto &bucket = _family_surname_members[candidate.surname_id];
        for (int32_t index : bucket) {
            if (index >= 0 && index < static_cast<int32_t>(families_store().active.size()) &&
                families_store().active[index] != 0 && index != child)
                families_store().surname_disambiguator.write_scalar(child, std::max(
                    families_store().surname_disambiguator[child],
                    families_store().surname_disambiguator[index] + 1U), market_mutation_sink());
        }
        bucket.push_back(child);
    }
    families_store().founded_day.write_scalar(child, std::max<int64_t>(0, _current_day.get()), market_mutation_sink());
    families_store().home_cell.write_scalar(child, offer.cell, market_mutation_sink());
    families_store().origin_cell.write_scalar(child, offer.cell, market_mutation_sink());
    families_store().origin_ethnicity.write_scalar(child, families_store().origin_ethnicity[parent], market_mutation_sink());
    families_store().culture_group_id.write_scalar(child, candidate.culture_group_id, market_mutation_sink());
    families_store().flags.write_scalar(child, static_cast<uint16_t>(
        families_store().flags[parent] & ~FAMILY_FLAG_STARTER), market_mutation_sink());
    families_store().split_sequence.write_scalar(child, 0, market_mutation_sink());
    families_store().split_sequence.write_scalar(parent, families_store().split_sequence[parent] + 1U, market_mutation_sink());
    transfer_family_branch(parent, child, offer.cell);
    const uint64_t parent_handle = offer.source_family_handle;
    for (size_t t = 0; t < candidate.trait_ids.size(); ++t) {
        uint8_t core = 0;
        for (const auto &roll : family_trait_rolls())
            if (roll.family_handle == parent_handle && roll.trait_id == candidate.trait_ids[t]) core = roll.core;
        family_trait_rolls().push_back({child_handle, candidate.trait_ids[t], candidate.trait_strength_q16[t], core});
    }
    mark_family_behavior_cache_dirty(FAMILY_BEHAVIOR_DIRTY_TRAITS);
    if (candidate.effect_id >= 0) {
        auto it = std::lower_bound(_family_founding_effects.begin(), _family_founding_effects.end(),
            std::make_pair(candidate.stable_id, std::numeric_limits<int32_t>::min()));
        _family_founding_effects.insert(it, {candidate.stable_id, candidate.effect_id});
    }
    auto lineage = std::lower_bound(_family_split_parents.begin(), _family_split_parents.end(),
        std::make_pair(candidate.stable_id, std::numeric_limits<int64_t>::min()));
    _family_split_parents.insert(lineage, {candidate.stable_id, families_store().stable_id[parent]});
    const uint16_t split_flags = families_store().flags[parent];
    if ((split_flags & (FAMILY_FLAG_SPLIT_GIFT_BUILDING |
            FAMILY_FLAG_SPLIT_GIFT_POPULATION)) != 0) {
        int32_t parent_prestige = 0;
        for (int32_t b = 0; b < static_cast<int32_t>(
                family_influences().active.size()); ++b) {
            if (family_influences().active[b] == 0 ||
                family_influences().family_handle[b] != parent_handle)
                continue;
            parent_prestige = std::max(parent_prestige,
                static_cast<int32_t>(family_influences().prestige_level[b]));
        }
        const int32_t tier = std::clamp(parent_prestige, 0, 5);
        static constexpr int32_t kSplitDowryBuildings[6] = {
            1, 1, 1, 2, 2, 3
        };
        static constexpr int64_t kSplitDowryPopulation[6] = {
            0, 0, 10, 0, 20, 30
        };
        int32_t gift_type = -1;
        int64_t sector_counts[5] = {0, 0, 0, 0, 0};
        for (const FamilyBuildingOwnership &ownership : family_ownerships()) {
            if ((ownership.family_handle != parent_handle &&
                 ownership.family_handle != child_handle) ||
                ownership.owned_count <= 0) continue;
            const int32_t group = building_index_for_handle(
                ownership.building_handle);
            if (group < 0 || group >= static_cast<int32_t>(building_count())) continue;
            const int32_t type_id = buildings_store().type_id[static_cast<size_t>(group)];
            if (type_id >= 0 && type_id < static_cast<int32_t>(_building_economic_sectors.size())) {
                const int32_t sector = _building_economic_sectors[static_cast<size_t>(type_id)];
                if (sector >= 0 && sector < 5)
                    sector_counts[sector] += ownership.owned_count;
            }
            if (gift_type < 0 && ownership.family_handle == child_handle &&
                buildings_store().cell[static_cast<size_t>(group)] == offer.cell) {
                gift_type = type_id;
            }
        }
        int32_t dominant_sector = -1;
        int64_t dominant_count = 0;
        for (int32_t s = 0; s < 5; ++s) {
            if (sector_counts[s] > dominant_count) {
                dominant_count = sector_counts[s];
                dominant_sector = s;
            }
        }
        if (dominant_sector >= 0) {
            std::vector<int32_t> legal_types;
            for (int32_t type_id = 0; type_id < static_cast<int32_t>(_building_types.size()); ++type_id) {
                if (type_id < static_cast<int32_t>(_building_economic_sectors.size()) &&
                    _building_economic_sectors[static_cast<size_t>(type_id)] == dominant_sector &&
                    building_available(offer.cell, type_id, true) &&
                    building_constructible(offer.cell, type_id, true) &&
                    evaluate_building_conditions(type_id, offer.cell) &&
                    family_free_building_resources_legal(
                        offer.cell, type_id, kSplitDowryBuildings[tier])) {
                    legal_types.push_back(type_id);
                }
            }
            if (!legal_types.empty()) {
                const uint64_t pick_hash = trace_hash_mix(
                    static_cast<uint64_t>(candidate.stable_id), 0x444f575259ULL);
                gift_type = legal_types[static_cast<size_t>(
                    pick_hash % legal_types.size())];
            }
        }
        PendingFamilySplitGift gift;
        gift.family_handle = child_handle;
        gift.cell = offer.cell;
        gift.flags = static_cast<uint16_t>(split_flags &
            (FAMILY_FLAG_SPLIT_GIFT_BUILDING | FAMILY_FLAG_SPLIT_GIFT_POPULATION));
        gift.building_type_id = gift_type;
        gift.building_count = kSplitDowryBuildings[tier];
        gift.population = kSplitDowryPopulation[tier];
        _pending_family_split_gifts.push_back(gift);
    }
    family_trait_rolls().sort([](const FamilyTraitRoll &a, const FamilyTraitRoll &b) {
        return std::tie(a.family_handle, a.trait_id) < std::tie(b.family_handle, b.trait_id);
    });
    ++_families_formed;
    return true;
}

void NativeEconomyRuntime::split_family_branches() {
    if (_family_runtime_mode.get() != 2 || _family_split_population_threshold.get() <= 0) return;
    if (_family_indices_dirty) rebuild_family_indices(false);
    struct Candidate { int32_t parent; int32_t cell; int64_t stable; };
    std::vector<Candidate> candidates;
    for (int32_t parent = 0; parent < static_cast<int32_t>(families_store().active.size()); ++parent) {
        if (families_store().active[parent] == 0) continue;
        std::map<int32_t, int64_t> branch_population;
        for (int32_t p = _family_member_offsets[parent]; p < _family_member_offsets[parent + 1]; ++p) {
            const auto &edge = family_memberships()[_family_member_edge_indices[p]];
            int32_t slot = -1;
            if (edge.people > 0 && population_store().valid_handle(edge.cohort_handle, slot))
                branch_population[population_store().page_cell[slot / COHORT_PAGE_SIZE]] += edge.people;
        }
        for (const auto &branch : branch_population)
            if (branch.first != families_store().origin_cell[parent] &&
                branch.second >= _family_split_population_threshold.get())
                candidates.push_back({parent, branch.first, families_store().stable_id[parent]});
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) {
        return std::tie(a.stable, a.cell) < std::tie(b.stable, b.cell);
    });
    for (const auto &candidate : candidates) {
        if (family_founding_offer_for_cell(candidate.cell) >= 0) continue;
        FamilyFoundingOffer offer;
        if (!build_family_split_offer(candidate.parent, candidate.cell, offer)) continue;
        offer.offer_id = _next_family_founding_offer_id++;
        if (family_founding_player_choice(candidate.cell)) {
            _family_founding_offers.push_back(std::move(offer));
            _family_founding_offer_index_dirty = true;
            ++_family_offers_opened;
        } else if (resolve_family_split_offer(offer, family_founding_auto_choice(offer))) {
            ++_family_offers_auto_resolved;
        }
    }
}

} // namespace pk
