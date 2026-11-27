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

void NativeEconomyRuntime::dissolve_family(uint64_t family_handle) {
    int32_t index = -1;
    if (!families_store().valid_handle(family_handle, index)) return;
    family_memberships().erase_if( [&](const FamilyMembershipEdge &edge) {
            return edge.family_handle == family_handle;
        });
    _family_csr_edge_count = SIZE_MAX;
    family_ownerships().erase_if( [&](const FamilyBuildingOwnership &edge) {
            return edge.family_handle == family_handle;
        });
    family_trait_rolls().erase_if( [&](const FamilyTraitRoll &roll) {
            return roll.family_handle == family_handle;
        });
    mark_family_behavior_cache_dirty(FAMILY_BEHAVIOR_DIRTY_TRAITS);
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0 ||
            family_influences().family_handle[branch] != family_handle) continue;
        const uint64_t branch_handle =
            family_influences().handle_for_index(branch);
        clear_family_branch_effects(branch_handle);
        family_influences().release(branch);
    }
    _family_stable_ids.erase(families_store().stable_id[index]);
    reset_family_policy_factors(index);
    families_store().release(index);
    ++_families_dissolved;
    _family_indices_dirty = true;
}

void NativeEconomyRuntime::rebuild_family_influences(bool rebuild_derived) {
    struct Key {
        uint64_t family = 0;
        int32_t cell = -1;
        bool operator<(const Key &other) const noexcept {
            return std::tie(family, cell) < std::tie(other.family, other.cell);
        }
    };
    struct Aggregate {
        int64_t population = 0, cash = 0, asset = 0;
        int64_t satisfaction_weighted = 0;
    };
    // Iteration allocates branch handles and schedules their effects.
    std::map<Key, Aggregate> aggregates;
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        int32_t family = -1, slot = -1;
        if (!families_store().valid_handle(edge.family_handle, family) ||
            !population_store().valid_handle(edge.cohort_handle, slot)) continue;
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        if (cell < 0 || cell >= _cell_count.get()) continue;
        Aggregate &aggregate = aggregates[{edge.family_handle, cell}];
        const int64_t people = std::max<int64_t>(0, edge.people);
        aggregate.population = saturating_add(aggregate.population, people,
                                              _saturation_count);
        aggregate.cash = saturating_add(aggregate.cash,
            std::max<int64_t>(0, edge.cash_claim), _saturation_count);
        aggregate.satisfaction_weighted = saturating_add(
            aggregate.satisfaction_weighted,
            saturating_mul(population_store().composite_satisfaction[slot], people,
                           _saturation_count), _saturation_count);
    }
    const std::unordered_map<uint64_t, int32_t> &building_by_handle =
        building_handle_index();
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        int32_t family = -1;
        const auto found = building_by_handle.find(edge.building_handle);
        if (!families_store().valid_handle(edge.family_handle, family) ||
            found == building_by_handle.end()) continue;
        const auto group = building_view(static_cast<size_t>(found->second));
        const int64_t unit_value = building_reset_capital_value(group);
        Aggregate &aggregate = aggregates[{edge.family_handle, group.cell}];
        aggregate.asset = saturating_add(aggregate.asset, saturating_mul(
            unit_value, std::max<int64_t>(0, edge.owned_count),
            _saturation_count), _saturation_count);
    }

    std::vector<uint8_t> relevant_cells(static_cast<size_t>(_cell_count.get()), 0);
    for (const auto &item : aggregates)
        if (item.first.cell >= 0 && item.first.cell < _cell_count.get())
            relevant_cells[item.first.cell] = 1;
    std::vector<int64_t> total_population(static_cast<size_t>(_cell_count.get()), 0);
    std::vector<int64_t> total_cash(static_cast<size_t>(_cell_count.get()), 0);
    std::vector<int64_t> total_asset(static_cast<size_t>(_cell_count.get()), 0);
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        if (relevant_cells[cell] == 0) continue;
        total_population[cell] = std::max<int64_t>(
            0, _committed_cells[cell].population);
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            total_cash[cell] = saturating_add(total_cash[cell],
                std::max<int64_t>(0, population_store().funds[slot]),
                _saturation_count);
        });
    }
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_view(pk_row);
        if (group.cell < 0 || group.cell >= _cell_count.get() || group.count <= 0 ||
            relevant_cells[group.cell] == 0) continue;
        total_asset[group.cell] = saturating_add(total_asset[group.cell],
            saturating_mul(building_reset_capital_value(group), group.count,
                _saturation_count), _saturation_count);
    }

    std::map<Key, int32_t> existing;
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch)
        if (family_influences().active[branch] != 0)
            existing[{family_influences().family_handle[branch],
                      family_influences().cell[branch]}] = branch;
    std::vector<uint8_t> seen(family_influences().active.size(), 0);
    const int32_t thresholds[6] = {0,
        Q16_ONE * 2 / 100, Q16_ONE * 5 / 100, Q16_ONE * 10 / 100,
        Q16_ONE * 20 / 100, Q16_ONE * 40 / 100};
    for (const auto &item : aggregates) {
        if (item.second.population <= 0 && item.second.cash <= 0 &&
            item.second.asset <= 0) continue;
        const Key key = item.first;
        int32_t branch = -1;
        bool changed = false;
        const auto found = existing.find(key);
        if (found == existing.end()) {
            branch = family_influences().allocate();
            if (seen.size() < family_influences().active.size())
                seen.resize(family_influences().active.size(), 0);
            family_influences().family_handle.write_scalar(branch, key.family, market_mutation_sink());
            family_influences().cell.write_scalar(branch, key.cell, market_mutation_sink());
            int32_t family = -1;
            uint64_t hash = 1469598103934665603ULL;
            if (families_store().valid_handle(key.family, family))
                hash = trace_hash_mix(hash, static_cast<uint64_t>(
                    families_store().stable_id[family]));
            hash = trace_hash_mix(hash, static_cast<uint32_t>(key.cell));
            family_influences().stable_id.write_scalar(branch, static_cast<int64_t>(
                (hash & 0x7fffffffffffffffULL) | 1ULL), market_mutation_sink());
            changed = true;
        } else {
            branch = found->second;
        }
        seen[branch] = 1;
        family_influences().population.write_scalar(branch, item.second.population, market_mutation_sink());
        family_influences().cash.write_scalar(branch, item.second.cash, market_mutation_sink());
        family_influences().building_asset.write_scalar(branch, item.second.asset, market_mutation_sink());
        const auto share = [&](int64_t value, int64_t total) -> int32_t {
            return total > 0 ? static_cast<int32_t>(std::clamp<int64_t>(
                mul_div_sat(value, Q16_ONE, total, _saturation_count),
                0, Q16_ONE)) : 0;
        };
        family_influences().population_share_q16.write_scalar(branch, share(
            item.second.population, total_population[key.cell]), market_mutation_sink());
        family_influences().cash_share_q16.write_scalar(branch, share(
            item.second.cash, total_cash[key.cell]), market_mutation_sink());
        family_influences().building_share_q16.write_scalar(branch, share(
            item.second.asset, total_asset[key.cell]), market_mutation_sink());
        // The 25/35/40 prestige formula is deliberately untouched: satisfaction
        // is recorded alongside it and only gates the survival review below.
        family_influences().score_q16.write_scalar(branch, static_cast<int32_t>(
            (static_cast<int64_t>(family_influences().population_share_q16[branch]) * 25 +
             static_cast<int64_t>(family_influences().cash_share_q16[branch]) * 35 +
             static_cast<int64_t>(family_influences().building_share_q16[branch]) * 40) / 100), market_mutation_sink());
        family_influences().satisfaction_q16.write_scalar(branch, item.second.population > 0
            ? static_cast<int32_t>(std::clamp<int64_t>(
                  item.second.satisfaction_weighted / item.second.population,
                  0, Q16_ONE - 1))
            : static_cast<int32_t>(Q16_ONE - 1), market_mutation_sink());
        const int64_t phase = family_influences().stable_id[branch] % 30;
        const bool review_due = _current_day.get() >= 0 &&
            ((_current_day.get() % 30 + 30) % 30) == phase;
        if (review_due && family_influences().last_review_day[branch] != _current_day.get()) {
            family_influences().last_review_day.write_scalar(branch, _current_day.get(), market_mutation_sink());
            const int32_t current = family_influences().prestige_level[branch];
            int32_t upgrade_target = 0, downgrade_target = 0;
            for (int32_t level = 1; level <= 5; ++level) {
                if (family_influences().score_q16[branch] >= thresholds[level])
                    upgrade_target = level;
                if (family_influences().score_q16[branch] >=
                        thresholds[level] * 80 / 100)
                    downgrade_target = level;
            }
            // A branch whose own members live in the bottom pressure bands has
            // no standing to rise, however much cash and land it controls.
            // Decline is never blocked, so this can only slow promotion.
            const bool members_discontent =
                family_influences().satisfaction_q16[branch] <
                _satisfaction_pressure_thresholds_q16[1];
            int32_t target = current;
            if (upgrade_target > current && !members_discontent)
                target = upgrade_target;
            else if (downgrade_target < current) target = downgrade_target;
            if (target == current) {
                family_influences().pending_target_level.write_scalar(branch, static_cast<uint8_t>(current), market_mutation_sink());
                family_influences().review_streak.write_scalar(branch, 0, market_mutation_sink());
            } else {
                const int32_t previous =
                    family_influences().pending_target_level[branch];
                const bool same_direction =
                    (target > current && previous > current) ||
                    (target < current && previous < current);
                family_influences().pending_target_level.write_scalar(branch, static_cast<uint8_t>(target), market_mutation_sink());
                family_influences().review_streak.write_scalar(branch, static_cast<uint8_t>(
                    same_direction ? std::min<int32_t>(255,
                        family_influences().review_streak[branch] + 1) : 1), market_mutation_sink());
                if (family_influences().review_streak[branch] >= 2) {
                    family_influences().prestige_level.write_scalar(branch, static_cast<uint8_t>(target), market_mutation_sink());
                    family_influences().review_streak.write_scalar(branch, 0, market_mutation_sink());
                    changed = true;
                    if (target > current) {
                        int32_t family_index = -1;
                        if (families_store().valid_handle(key.family, family_index))
                            fire_family_event_once_effect(family_index,
                                "family.effect.new_nobility");
                    }
                }
            }
        }
        const uint64_t branch_handle =
            family_influences().handle_for_index(branch);
        // Every declared metric except id 0 (the branch magnitude, which the
        // binding supplies as strength_q16 rather than a sample).
        const MetricMask FAMILY_COMMIT_METRICS = [] {
            MetricMask mask = MetricMask::all_declared(FAMILY_METRIC_COUNT);
            mask.unset(FAMILY_METRIC_MAGNITUDE_Q16);
            // X9-a cell aggregates are sampled once from the completed branch
            // cache below, not once per branch while the cache is still moving.
            mask.unset(FAMILY_METRIC_CELL_FAMILY_BRANCH_COUNT);
            mask.unset(FAMILY_METRIC_CELL_MAX_BRANCH_PRESTIGE_Q16);
            mask.unset(FAMILY_METRIC_CELL_FAMILY_ASSET_SHARE_Q16);
            mask.unset(FAMILY_METRIC_COUNTRY_FAMILY_REMOTE_BRANCH_COUNT);
            mask.unset(FAMILY_METRIC_COUNTRY_FAMILIES_WITH_AT_LEAST_3_BRANCHES);
            mask.unset(FAMILY_METRIC_COUNTRY_MAX_FAMILY_AGE_DAYS);
            mask.unset(FAMILY_METRIC_COUNTRY_AVG_FAMILY_AGE_DAYS);
            mask.unset(FAMILY_METRIC_COUNTRY_ENERGY_CELL_COUNT);
            mask.unset(
                FAMILY_METRIC_COUNTRY_ABUNDANT_MOUNTAIN_FOREST_CELL_COUNT);
            mask.unset(FAMILY_METRIC_COUNTRY_LANDFORM_SIGNAL_COUNT);
            mask.unset(FAMILY_METRIC_COUNTRY_WEATHER_SIGNAL_COUNT);
            mask.unset(FAMILY_METRIC_COUNTRY_BIO_SIGNAL_COUNT);
            return mask;
        }();
        refresh_family_effect_metrics_for_branch(branch_handle,
            family_effect_metric_revision(1), FAMILY_COMMIT_METRICS);
        if (changed) reconcile_family_branch_effects(branch_handle, true);
    }
    for (int32_t branch = 0; branch < static_cast<int32_t>(seen.size()); ++branch) {
        if (family_influences().active[branch] == 0 || seen[branch] != 0) continue;
        const uint64_t handle = family_influences().handle_for_index(branch);
        clear_family_branch_effects(handle);
        family_influences().release(branch);
    }
    rebuild_family_policy_scalars();
    mark_family_behavior_cache_dirty(FAMILY_BEHAVIOR_DIRTY_INFLUENCES);
    if (rebuild_epoch_family_cell_metrics()) {
        const MetricMask family_cell_metrics = [] {
            MetricMask mask;
            mask.set(FAMILY_METRIC_CELL_FAMILY_BRANCH_COUNT);
            mask.set(FAMILY_METRIC_CELL_MAX_BRANCH_PRESTIGE_Q16);
            mask.set(FAMILY_METRIC_CELL_FAMILY_ASSET_SHARE_Q16);
            return mask;
        }();
        const int64_t revision = family_effect_metric_revision(1);
        for (int32_t cell = 0; cell < static_cast<int32_t>(
                _family_cell_metric_changed_cells.size()); ++cell) {
            if (_family_cell_metric_changed_cells[static_cast<size_t>(cell)] == 0)
                continue;
            refresh_family_effect_metrics_for_cell(
                cell, revision, family_cell_metrics);
        }
    }
    if (rebuild_epoch_family_country_metrics()) {
        const MetricMask family_country_metrics = [] {
            MetricMask mask;
            mask.set(FAMILY_METRIC_COUNTRY_FAMILY_REMOTE_BRANCH_COUNT);
            mask.set(FAMILY_METRIC_COUNTRY_FAMILIES_WITH_AT_LEAST_3_BRANCHES);
            mask.set(FAMILY_METRIC_COUNTRY_MAX_FAMILY_AGE_DAYS);
            mask.set(FAMILY_METRIC_COUNTRY_AVG_FAMILY_AGE_DAYS);
            return mask;
        }();
        const int64_t revision = family_effect_metric_revision(2);
        for (int32_t country = 0; country < static_cast<int32_t>(
                _family_country_metric_changed_countries.size()); ++country) {
            if (_family_country_metric_changed_countries[
                    static_cast<size_t>(country)] == 0)
                continue;
            const int32_t anchor = country_anchor_cell(country);
            if (anchor >= 0)
                refresh_family_effect_metrics_for_cell(
                    anchor, revision, family_country_metrics);
        }
    }
    if (rebuild_derived) {
        rebuild_family_industry_metrics();
        rebuild_family_behavior_cache();
        rebuild_family_owned_output_csr();
    }
    apply_pending_family_split_gifts();
}

void NativeEconomyRuntime::apply_due_family_trait_commands() {
    _family_trait_commands.stable_sort(
        [](const FamilyTraitCommand &a, const FamilyTraitCommand &b) {
            if (a.effective_day != b.effective_day)
                return a.effective_day < b.effective_day;
            if (a.priority != b.priority) return a.priority < b.priority;
            if (a.sequence != b.sequence) return a.sequence < b.sequence;
            return a.submit_order < b.submit_order;
        });
    std::vector<FamilyTraitCommand> retained;
    std::unordered_set<uint64_t> changed_families;
    for (const FamilyTraitCommand &command : _family_trait_commands) {
        if (command.effective_day > _current_day.get()) {
            retained.push_back(command);
            continue;
        }
        int32_t family = -1;
        if (!families_store().valid_handle(command.family_handle, family) ||
            command.trait_id < 0 || command.trait_id >= static_cast<int32_t>(
                _family_trait_ids.size())) continue;
        auto found = std::find_if(family_trait_rolls().begin(), family_trait_rolls().end(),
            [&](const FamilyTraitRoll &roll) {
                return roll.family_handle == command.family_handle &&
                    roll.trait_id == command.trait_id;
            });
        if (command.operation == 2) {
            if (found == family_trait_rolls().end() || found->core != 0) continue;
            family_trait_rolls().erase(found);
            changed_families.insert(command.family_handle);
            continue;
        }
        if (command.operation == 3) {
            if (found == family_trait_rolls().end()) continue;
            if (found->strength_q16 != command.strength_q16) {
                auto found_write = family_trait_rolls().edit_row(found - family_trait_rolls().begin(), market_mutation_sink());
                found_write[0].strength_q16 = command.strength_q16;
                changed_families.insert(command.family_handle);
            }
            continue;
        }
        if (command.operation != 1) continue;
        if (found != family_trait_rolls().end()) {
            if (found->core == 0 && found->strength_q16 != command.strength_q16) {
                auto found_write = family_trait_rolls().edit_row(found - family_trait_rolls().begin(), market_mutation_sink());
                found_write[0].strength_q16 = command.strength_q16;
                changed_families.insert(command.family_handle);
            }
            continue;
        }
        bool allowed = true;
        for (int32_t p = _family_trait_prerequisite_offsets[command.trait_id];
             p < _family_trait_prerequisite_offsets[command.trait_id + 1]; ++p) {
            const int32_t required = _family_trait_prerequisites[p];
            allowed = allowed && std::any_of(family_trait_rolls().begin(),
                family_trait_rolls().end(), [&](const FamilyTraitRoll &roll) {
                    return roll.family_handle == command.family_handle &&
                        roll.trait_id == required;
                });
        }
        for (int32_t p = _family_trait_exclusion_offsets[command.trait_id];
             allowed && p < _family_trait_exclusion_offsets[command.trait_id + 1]; ++p) {
            const int32_t excluded = _family_trait_exclusions[p];
            allowed = !std::any_of(family_trait_rolls().begin(), family_trait_rolls().end(),
                [&](const FamilyTraitRoll &roll) {
                    return roll.family_handle == command.family_handle &&
                        roll.trait_id == excluded;
                });
        }
        if (!allowed) continue;
        family_trait_rolls().push_back({command.family_handle, command.trait_id,
                                  command.strength_q16, 0});
        changed_families.insert(command.family_handle);
    }
    _family_trait_commands.swap(retained);
    family_trait_rolls().sort(
        [](const FamilyTraitRoll &a, const FamilyTraitRoll &b) {
            return std::tie(a.family_handle, a.trait_id) <
                std::tie(b.family_handle, b.trait_id);
        });
    if (!changed_families.empty())
        mark_family_behavior_cache_dirty(FAMILY_BEHAVIOR_DIRTY_TRAITS);
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0 ||
            changed_families.find(family_influences().family_handle[branch]) ==
                changed_families.end()) continue;
        reconcile_family_branch_effects(
            family_influences().handle_for_index(branch), true);
    }
}

void NativeEconomyRuntime::review_family_lifecycle() {
    std::vector<uint64_t> dissolve;
    for (int32_t i = 0; i < static_cast<int32_t>(families_store().active.size()); ++i) {
        if (families_store().active[i] == 0) continue;
        const uint64_t handle = families_store().handle_for_index(i);
        const int64_t pop = family_population(handle);
        const int64_t assets = family_owned_buildings(handle);
        if (pop <= 0) { dissolve.push_back(handle); continue; }
        int32_t best_cell = families_store().home_cell[i];
        int64_t best_pop = -1;
        std::unordered_map<int32_t, int64_t> branch_pop;
        const int32_t member_begin = _family_member_offsets.size() ==
                families_store().active.size() + 1
            ? _family_member_offsets[i] : 0;
        const int32_t member_end = _family_member_offsets.size() ==
                families_store().active.size() + 1
            ? _family_member_offsets[i + 1]
            : static_cast<int32_t>(family_memberships().size());
        for (int32_t p = member_begin; p < member_end; ++p) {
            const FamilyMembershipEdge &edge = family_memberships()[
                _family_member_offsets.size() == families_store().active.size() + 1
                    ? _family_member_edge_indices[p] : p];
            if (edge.family_handle != handle) continue;
            int32_t slot = -1;
            if (!population_store().valid_handle(edge.cohort_handle, slot)) continue;
            branch_pop[population_store().page_cell[slot / COHORT_PAGE_SIZE]] += edge.people;
        }
        for (const auto &branch : branch_pop) {
            if (branch.second > best_pop ||
                (branch.second == best_pop && branch.first < best_cell)) {
                best_cell = branch.first; best_pop = branch.second;
            }
        }
        if (families_store().home_cell[i] != best_cell) {
            families_store().home_cell.write_scalar(i, best_cell, market_mutation_sink());
            mark_family_behavior_cache_dirty(
                FAMILY_BEHAVIOR_DIRTY_HOME_CELL);
        }
        const int64_t phase = (families_store().stable_id[i] % _family_review_days.get() +
            _family_review_days.get()) % _family_review_days.get();
        if ((_current_day.get() % _family_review_days.get() + _family_review_days.get()) %
                _family_review_days.get() != phase) continue;
        release_unstaffable_family_ownership(i);
        const bool starter = (families_store().flags[i] & FAMILY_FLAG_STARTER) != 0;
        if (!starter && assets <= 0 && pop < FAMILY_MIN_ACTIVE_PEOPLE) {
            families_store().decline_reviews.write_scalar(i, static_cast<uint16_t>(std::min(
                65535, static_cast<int>(families_store().decline_reviews[i]) + 1)), market_mutation_sink());
            if (families_store().decline_reviews[i] >= _family_decline_reviews.get())
                dissolve.push_back(handle);
        } else {
            families_store().decline_reviews.write_scalar(i, 0, market_mutation_sink());
        }
    }
    for (uint64_t handle : dissolve) dissolve_family(handle);
}

} // namespace pk
