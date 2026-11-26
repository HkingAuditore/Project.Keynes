#include "economy_runtime.h"
#include <cstdio>
#include "selector_cell_cap.h"
#include "economy_effect_forward.h"
#include "effect_runtime.h"
#include "modifier_api.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <limits>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace pk {

namespace {

constexpr int32_t kManufacturingSector = 2;
constexpr int32_t kDominantShareFloorQ16 = NativeEconomyRuntime::Q16_ONE * 70 / 100;
constexpr int32_t kMonopolyShareFloorQ16 = NativeEconomyRuntime::Q16_ONE * 60 / 100;
constexpr int32_t kSpecializedDominantBonusQ16 = 3932; // +6%
constexpr int32_t kSpecializedOtherPenaltyQ16 = 1966; // -3%
constexpr int32_t kVersatileCraftsBonusQ16 = NativeEconomyRuntime::Q16_ONE;
constexpr int32_t kCompleteChainBonusQ16 = NativeEconomyRuntime::Q16_ONE;
constexpr int32_t kMonopolyBonusQ16 = NativeEconomyRuntime::Q16_ONE;

const char *kEffectSpecialized = "family.effect.specialized_industry";
const char *kEffectVersatile = "family.effect.versatile_crafts";
const char *kEffectCompleteChain = "family.effect.complete_chain";
const char *kEffectMonopoly = "family.effect.local_monopoly";
const char *kEffectRetain = "family.effect.retain_lineage";
const char *kEffectAbsorb = "family.effect.absorb_all";
const char *kEffectAncestral = "family.effect.ancestral_precept";
const char *kEffectBreakPast = "family.effect.break_with_past";
const char *kEffectSplitDowry = "family.effect.split_dowry";
const char *kEffectRainPrayer = "family.effect.rain_prayer";
const char *kEffectColdResist = "family.effect.cold_resist";
const char *kEffectWorkRelief = "family.effect.work_relief";
const char *kEffectBranching = "family.effect.branching_households";
const char *kEffectRemoteKin = "family.effect.remote_kin";
const char *kEffectFamilyLearning = "family.effect.family_learning";
const char *kEffectWealthyFew = "family.effect.wealthy_few_heirs";
const char *kEffectExpansionism = "family.effect.expansionism";
const char *kEffectMarketBully = "family.effect.market_bully";
const char *kEffectOneIndustry = "family.effect.one_industry_city";
const char *kEffectCityFounder = "family.effect.city_founder";
const char *kEffectNewNobility = "family.effect.new_nobility";
constexpr int32_t kLifecycleEventOnce = 2;
// Frozen numbering shared with EffectRuntime::TargetSelectorKind. R1 (6) is the
// first fan-out kind, which is what every "does this kind resolve to a list of
// cells" test below keys off; R2 (7) is kept only to document that 7 is a real,
// already-shipped kind and must never be reused.
constexpr int32_t kSelectorNeighborsR1 = 6;
constexpr int32_t kSelectorNeighborsR2 = 7;
constexpr int32_t kOneIndustryShareFloorQ16 = NativeEconomyRuntime::Q16_ONE * 70 / 100;
constexpr int32_t kDefaultRainThresholdQ16 = NativeEconomyRuntime::Q16_ONE / 4;
// Official family effects are a rare identity tag.  Small fixture catalogs
// used by focused runtime tests keep the old deterministic behavior; the
// shipped 48-effect catalog uses this gate before selecting a random-pool
// effect, so most families are defined by their traits alone.
constexpr uint64_t kOfficialRareEffectChancePercent = 20;

int32_t clamp_factor_q16(int64_t value) {
    return static_cast<int32_t>(std::clamp<int64_t>(value, 0,
        4 * NativeEconomyRuntime::Q16_ONE));
}

int32_t bonus_factor_q16(int32_t magnitude_q16, int32_t bonus_q16) {
    return clamp_factor_q16(static_cast<int64_t>(NativeEconomyRuntime::Q16_ONE) +
        static_cast<int64_t>(bonus_q16) * magnitude_q16 /
            NativeEconomyRuntime::Q16_ONE);
}

} // namespace

int32_t NativeEconomyRuntime::family_effect_id_for_key(
        const std::string &program_key) const {
    const auto found = std::lower_bound(_family_effect_keys.begin(),
        _family_effect_keys.end(), program_key);
    if (found == _family_effect_keys.end() || *found != program_key)
        return -1;
    return static_cast<int32_t>(found - _family_effect_keys.begin());
}

int32_t NativeEconomyRuntime::family_effect_prestige_magnitude_q16(
        int32_t effect_id, int32_t prestige_level) const {
    if (effect_id < 0 || effect_id >= static_cast<int32_t>(_family_effect_keys.size()) ||
        _family_effect_magnitude_by_prestige_q16.size() <
            static_cast<size_t>(effect_id + 1) * 6U)
        return Q16_ONE;
    const int32_t level = std::clamp(prestige_level, 0, 5);
    return _family_effect_magnitude_by_prestige_q16[
        static_cast<size_t>(effect_id) * 6U + static_cast<size_t>(level)];
}

#include "economy_runtime_family_buff_industry.inc"
void NativeEconomyRuntime::apply_family_split_policy_flags(int32_t family_index,
                                                          uint16_t policy,
                                                          uint8_t weight_q8) {
    if (family_index < 0 || family_index >= static_cast<int32_t>(
            families_store().flags.size()) || families_store().active[family_index] == 0)
        return;
    uint16_t flags = families_store().flags[static_cast<size_t>(family_index)];
    flags &= static_cast<uint16_t>(~(FAMILY_FLAG_SPLIT_POLICY_MASK |
        (0xFFu << FAMILY_FLAG_SPLIT_WEIGHT_SHIFT)));
    const uint16_t selected = policy & FAMILY_FLAG_SPLIT_POLICY_MASK;
    const uint16_t mode = selected & FAMILY_FLAG_SPLIT_MODE_MASK;
    const uint16_t gifts = selected & (FAMILY_FLAG_SPLIT_GIFT_BUILDING |
        FAMILY_FLAG_SPLIT_GIFT_POPULATION);
    if (mode == FAMILY_FLAG_SPLIT_RETAIN_ONLY ||
        mode == FAMILY_FLAG_SPLIT_BONUS_WEIGHT ||
        mode == FAMILY_FLAG_SPLIT_REPLACE)
        flags |= mode;
    if (mode == FAMILY_FLAG_SPLIT_BONUS_WEIGHT)
        flags |= static_cast<uint16_t>(weight_q8) << FAMILY_FLAG_SPLIT_WEIGHT_SHIFT;
    flags |= gifts;
    families_store().flags.write_scalar(static_cast<size_t>(family_index), flags, market_mutation_sink());
}

bool NativeEconomyRuntime::apply_family_set_split_policy(const Command &cmd,
                                                         std::string &error) {
    (void)error;
    int32_t family = -1;
    int32_t branch = -1;
    if (families_store().valid_handle(cmd.target_handle, family)) {
    } else if (family_influences().valid_handle(cmd.target_handle, branch)) {
        if (!families_store().valid_handle(family_influences().family_handle[branch], family)) {
            ++_rejected_commands;
            return true;
        }
    } else {
        ++_rejected_commands;
        return true;
    }
    const uint16_t policy = static_cast<uint16_t>(cmd.i32_0) &
        FAMILY_FLAG_SPLIT_POLICY_MASK;
    const uint8_t weight = static_cast<uint8_t>(std::clamp<int64_t>(cmd.i64_0, 0, 255));
    apply_family_split_policy_flags(family, policy, weight);
    return true;
}

void NativeEconomyRuntime::grant_random_pool_family_effect(
        int32_t family_index, bool submit_changes) {
    if (!submit_changes || family_index < 0 ||
        family_index >= static_cast<int32_t>(families_store().active.size()) ||
        families_store().active[family_index] == 0 ||
        _effect_runtime == nullptr || _family_effect_keys.empty())
        return;
    const uint64_t family_handle = families_store().handle_for_index(family_index);
    std::vector<int32_t> owned;
    bool has_random_pool = false;
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        int32_t branch = -1;
        if (!family_influences().valid_handle(binding.branch_handle, branch) ||
            family_influences().family_handle[branch] != family_handle)
            continue;
        const int32_t effect_id = family_effect_id_for_key(binding.definition_key);
        if (effect_id >= 0) owned.push_back(effect_id);
        int32_t source_kind = -1;
        if (effect_id >= 0 && effect_id < static_cast<int32_t>(
                _family_effect_source_kinds.size()))
            source_kind = _family_effect_source_kinds[static_cast<size_t>(effect_id)];
        else {
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (_effect_runtime->family_effect_metadata_pod(
                    binding.definition_key, metadata))
                source_kind = metadata.source_kind;
        }
        if (source_kind == 1) has_random_pool = true;
    }
    if (has_random_pool) return;
    std::sort(owned.begin(), owned.end());
    owned.erase(std::unique(owned.begin(), owned.end()), owned.end());
    const int32_t origin = families_store().origin_cell[family_index];
    const int32_t home = families_store().home_cell[family_index];
    const int32_t tech_cell = origin >= 0 && origin < _cell_count.get() ? origin : home;
    int32_t chosen = family_founding_effect_for(
        families_store().stable_id[family_index]);
    if (chosen >= 0) {
        bool allowed = chosen < static_cast<int32_t>(_family_effect_keys.size());
        for (int32_t mine : owned) {
            if (!allowed) break;
            if (mine + 1 >= static_cast<int32_t>(_family_effect_exclusion_offsets.size()))
                continue;
            for (int32_t p = _family_effect_exclusion_offsets[static_cast<size_t>(mine)];
                 allowed && p < _family_effect_exclusion_offsets[
                    static_cast<size_t>(mine) + 1]; ++p)
                allowed = _family_effect_exclusions[static_cast<size_t>(p)] != chosen;
        }
        if (!allowed) chosen = -1;
    }
    if (chosen < 0)
        chosen = roll_random_pool_family_effect(static_cast<uint64_t>(
            families_store().stable_id[family_index]), tech_cell, owned, {});
    if (chosen < 0) return;
    grant_family_effect_to_branches(family_index, chosen);
}

int32_t NativeEconomyRuntime::roll_random_pool_family_effect(
        uint64_t stable_id, int32_t tech_cell,
        const std::vector<int32_t> &owned,
        const std::vector<int32_t> &avoid) const {
    if (_family_effect_keys.empty()) return -1;
    uint64_t rng = 1469598103934665603ULL;
    rng = trace_hash_mix(rng, static_cast<uint64_t>(_seed.get()));
    rng = trace_hash_mix(rng, stable_id);
    rng = trace_hash_mix(rng, static_cast<uint32_t>(
        _family_effect_catalog_version));
    if (_family_effect_keys.size() >= 20 &&
            trace_hash_mix(rng, 0x524152455F454646ULL) % 100ULL >=
                kOfficialRareEffectChancePercent)
        return -1;
    std::vector<int32_t> candidates;
    int64_t total_weight = 0;
    for (int32_t effect_id = 0; effect_id < static_cast<int32_t>(
            _family_effect_keys.size()); ++effect_id) {
        if (effect_id >= static_cast<int32_t>(_family_effect_random_pool_eligible.size()) ||
            _family_effect_random_pool_eligible[static_cast<size_t>(effect_id)] == 0)
            continue;
        if (!family_effect_technology_unlocked(effect_id, tech_cell))
            continue;
        if (std::find(avoid.begin(), avoid.end(), effect_id) != avoid.end())
            continue;
        bool allowed = true;
        if (effect_id + 1 < static_cast<int32_t>(
                _family_effect_exclusion_offsets.size())) {
            for (int32_t p = _family_effect_exclusion_offsets[
                    static_cast<size_t>(effect_id)];
                 allowed && p < _family_effect_exclusion_offsets[
                    static_cast<size_t>(effect_id) + 1]; ++p) {
                allowed = !std::binary_search(owned.begin(), owned.end(),
                    _family_effect_exclusions[static_cast<size_t>(p)]);
            }
        }
        for (int32_t chosen : owned) {
            if (!allowed) break;
            if (chosen + 1 >= static_cast<int32_t>(_family_effect_exclusion_offsets.size()))
                continue;
            for (int32_t p = _family_effect_exclusion_offsets[static_cast<size_t>(chosen)];
                 allowed && p < _family_effect_exclusion_offsets[
                    static_cast<size_t>(chosen) + 1]; ++p)
                allowed = _family_effect_exclusions[static_cast<size_t>(p)] != effect_id;
        }
        if (!allowed) continue;
        const int32_t weight = effect_id < static_cast<int32_t>(
                _family_effect_weights.size())
            ? std::max(1, _family_effect_weights[static_cast<size_t>(effect_id)]) : 1;
        candidates.push_back(effect_id);
        total_weight += weight;
    }
    if (candidates.empty() || total_weight <= 0) return -1;
    int64_t roll = static_cast<int64_t>(trace_hash_mix(rng, 0x5049434bULL) %
        static_cast<uint64_t>(total_weight));
    int32_t chosen = candidates.back();
    for (int32_t candidate : candidates) {
        const int32_t weight = candidate < static_cast<int32_t>(
                _family_effect_weights.size())
            ? std::max(1, _family_effect_weights[static_cast<size_t>(candidate)]) : 1;
        if (roll < weight) {
            chosen = candidate;
            break;
        }
        roll -= weight;
    }
    return chosen;
}

void NativeEconomyRuntime::grant_family_effect_to_branches(
        int32_t family_index, int32_t chosen) {
    const uint64_t family_handle = families_store().handle_for_index(family_index);
    const std::string &key = _family_effect_keys[static_cast<size_t>(chosen)];
    int32_t prestige = 0;
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0 ||
            family_influences().family_handle[branch] != family_handle) continue;
        prestige = std::max(prestige,
            static_cast<int32_t>(family_influences().prestige_level[branch]));
    }
    const int32_t magnitude = family_effect_prestige_magnitude_q16(chosen, prestige);
    if (key == kEffectRetain)
        apply_family_split_policy_flags(family_index, FAMILY_FLAG_SPLIT_RETAIN_ONLY, 0);
    else if (key == kEffectAbsorb) {
        const int32_t q7 = static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(magnitude) * 128 / Q16_ONE, 128, 255));
        apply_family_split_policy_flags(family_index, FAMILY_FLAG_SPLIT_BONUS_WEIGHT,
            static_cast<uint8_t>(q7));
    } else if (key == kEffectBreakPast)
        apply_family_split_policy_flags(family_index, FAMILY_FLAG_SPLIT_REPLACE, 0);
    else if (key == kEffectSplitDowry)
        apply_family_split_policy_flags(family_index,
            FAMILY_FLAG_SPLIT_GIFT_BUILDING | FAMILY_FLAG_SPLIT_GIFT_POPULATION, 0);
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0 ||
            family_influences().family_handle[branch] != family_handle) continue;
        const uint64_t branch_handle = family_influences().handle_for_index(branch);
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(key, metadata)) continue;
        const int32_t source_cell = family_influences().cell[branch];
        const int32_t branch_prestige = family_influences().prestige_level[branch];
        std::vector<int32_t> target_cells;
        collect_family_effect_target_cells(source_cell, metadata.target_selector_kind,
            target_cells, key, branch_prestige);
        if (target_cells.empty() && (metadata.target_domain == 2 ||
                metadata.target_domain == 4 || metadata.target_domain == 5))
            continue;
        const bool event_once = metadata.lifecycle == kLifecycleEventOnce;
        auto bind_one = [&](int32_t target_cell) {
            uint64_t identity = trace_hash_mix(1469598103934665603ULL,
                static_cast<uint64_t>(family_influences().stable_id[branch]));
            identity = trace_hash_mix(identity, static_cast<uint32_t>(source_cell));
            identity = trace_hash_mix(identity, static_cast<uint32_t>(
                std::max(0, target_cell)));
            uint64_t definition_hash = 1469598103934665603ULL;
            for (unsigned char ch : key)
                definition_hash = trace_hash_mix(definition_hash, ch);
            identity = trace_hash_mix(identity, definition_hash);
            const int64_t instance_id = static_cast<int64_t>(identity &
                0x7fffffffffffffffULL);
            uint64_t target_handle = 0;
            uint32_t target_generation = 0;
            if (metadata.target_domain == 1) {
                target_handle = branch_handle;
                target_generation = static_cast<uint32_t>(branch_handle >> 32U);
                // Same rule the reconcile resolver enforces: a Branch-domain row
                // with generation 0 is rejected by the pod, so decline the target
                // here instead of queueing a row that can never land.
                if (target_generation == 0) return;
            } else if (metadata.target_domain == 0) {
                target_handle = family_handle;
                target_generation = static_cast<uint32_t>(family_handle >> 32U);
            } else if (metadata.target_domain == 3 && _country_runtime != nullptr) {
                const int32_t country_cell = target_cell >= 0 ? target_cell : source_cell;
                target_handle = static_cast<uint64_t>(
                    country_reads().country_handle_for_cell(country_cell));
                target_generation = static_cast<uint32_t>(target_handle >> 32U);
                if (target_handle == 0) return;
            } else {
                const int32_t resolved = target_cell >= 0 ? target_cell : source_cell;
                if (resolved < 0 || resolved >= _cell_count.get()) return;
                target_handle = static_cast<uint64_t>(resolved);
                target_generation = 1;
            }
            if (!event_once) {
                std::string error;
                if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                        instance_id, key,
                        static_cast<uint32_t>(branch_handle >> 32U), 0x46414d50,
                        static_cast<int64_t>(family_influences().stable_id[branch]),
                        branch_handle, target_handle, target_generation, prestige,
                        _current_day.get(), -1, true, error))
                    return;
                if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                        instance_id, static_cast<uint32_t>(branch_handle >> 32U),
                        0, family_effect_metric_revision(1), magnitude, error))
                    return;
            }
            add_family_effect_binding({branch_handle, key, magnitude, instance_id,
                static_cast<uint32_t>(branch_handle >> 32U), metadata.target_domain,
                target_handle, target_generation, metadata.metric_mask});
            if (!event_once) {
                const auto indexed = _family_effect_binding_by_instance.find(instance_id);
                if (indexed != _family_effect_binding_by_instance.end())
                    publish_family_effect_metrics(
                        _family_effect_bindings[indexed->second],
                        family_effect_metric_revision(1),
                        MetricMask::all_declared(FAMILY_METRIC_COUNT));
            }
        };
        // Every fan-out kind (6 and above) resolves to a list, so every entry
        // gets its own binding. Restricting this to R1/R2 meant kinds 8..12
        // resolved a whole territory and then bound a single anchor cell.
        if (metadata.target_selector_kind >= kSelectorNeighborsR1) {
            for (int32_t target_cell : target_cells) bind_one(target_cell);
        } else {
            bind_one(source_cell);
        }
    }
}

void NativeEconomyRuntime::grant_ancestral_precept_for_country(
        uint64_t country_handle) {
    if (country_handle == 0 || _effect_runtime == nullptr ||
        _country_runtime == nullptr) return;
    const int32_t effect_id = family_effect_id_for_key(kEffectAncestral);
    if (effect_id < 0) return;
    for (int32_t family = 0; family < static_cast<int32_t>(families_store().active.size());
         ++family) {
        if (families_store().active[family] == 0) continue;
        const int32_t home = families_store().home_cell[family];
        if (static_cast<uint64_t>(country_reads().country_handle_for_cell(home)) !=
            country_handle)
            continue;
        const uint64_t family_handle = families_store().handle_for_index(family);
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                family_influences().active.size()); ++branch) {
            if (family_influences().active[branch] == 0 ||
                family_influences().family_handle[branch] != family_handle) continue;
            const uint64_t branch_handle = family_influences().handle_for_index(branch);
            const int32_t prestige = family_influences().prestige_level[branch];
            const int32_t magnitude = family_effect_prestige_magnitude_q16(
                effect_id, prestige);
            uint64_t identity = trace_hash_mix(1469598103934665603ULL,
                static_cast<uint64_t>(family_influences().stable_id[branch]));
            identity = trace_hash_mix(identity, static_cast<uint32_t>(
                family_influences().cell[branch]));
            uint64_t definition_hash = 1469598103934665603ULL;
            for (unsigned char ch : std::string(kEffectAncestral))
                definition_hash = trace_hash_mix(definition_hash, ch);
            identity = trace_hash_mix(identity, definition_hash);
            const int64_t instance_id = static_cast<int64_t>(identity &
                0x7fffffffffffffffULL);
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!_effect_runtime->family_effect_metadata_pod(kEffectAncestral, metadata))
                continue;
            uint64_t target_handle = country_handle;
            uint32_t target_generation = static_cast<uint32_t>(country_handle >> 32U);
            if (metadata.target_domain == 1) {
                target_handle = branch_handle;
                target_generation = static_cast<uint32_t>(branch_handle >> 32U);
                if (target_generation == 0) continue;
            } else if (metadata.target_domain == 2 || metadata.target_domain == 5) {
                target_handle = static_cast<uint64_t>(family_influences().cell[branch]);
                target_generation = 1;
            }
            std::string error;
            // Managed-duration instances must carry their expiry from creation.
            // The pod derives expires_day only inside evaluate(), so an
            // instance whose trigger never fires would live forever. Both
            // authorities now read the same absolute day out of the metadata the
            // caller already resolved.
            static constexpr int32_t kAncestralDurations[6] = {
                180, 180, 240, 300, 365, 540
            };
            const int32_t ancestral_duration =
                kAncestralDurations[std::clamp(prestige, 0, 5)];
            const int64_t expires_day =
                metadata.lifecycle == 1 && metadata.stack_policy == 1
                    ? std::max<int64_t>(0, _current_day.get()) +
                        static_cast<int64_t>(ancestral_duration)
                    : -1;
            if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                    instance_id, kEffectAncestral,
                    static_cast<uint32_t>(branch_handle >> 32U), 0x46414d43,
                    static_cast<int64_t>(family_influences().stable_id[branch]),
                    branch_handle, target_handle, target_generation, prestige,
                    _current_day.get(), expires_day, true, error))
                continue;
            if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                    instance_id, static_cast<uint32_t>(branch_handle >> 32U), 0,
                    family_effect_metric_revision(1), magnitude, error))
                continue;
            add_family_effect_binding({branch_handle, kEffectAncestral, magnitude,
                instance_id, static_cast<uint32_t>(branch_handle >> 32U),
                metadata.target_domain, target_handle, target_generation,
                metadata.metric_mask});
            const auto indexed = _family_effect_binding_by_instance.find(instance_id);
            if (indexed != _family_effect_binding_by_instance.end())
                publish_family_effect_metrics(
                    _family_effect_bindings[indexed->second],
                    family_effect_metric_revision(1),
                    MetricMask::all_declared(FAMILY_METRIC_COUNT));
        }
    }
}

void NativeEconomyRuntime::notify_era_milestone_activated(uint64_t country_handle) {
    grant_ancestral_precept_for_country(country_handle);
}

#include "economy_runtime_family_buff_targeting.inc"
void NativeEconomyRuntime::fire_family_event_once_effect(int32_t family_index,
                                                         const std::string &program_key) {
    if (family_index < 0 || family_index >= static_cast<int32_t>(
            families_store().active.size()) || families_store().active[family_index] == 0 ||
        _effect_runtime == nullptr || program_key.empty())
        return;
    const uint64_t family_handle = families_store().handle_for_index(family_index);
    const int32_t effect_id = family_effect_id_for_key(program_key);
    for (size_t i = 0; i < _family_effect_bindings.size(); ++i) {
        auto binding_write = _family_effect_bindings.edit_row(i);
        FamilyEffectBinding &binding = binding_write[0];
        if (binding.definition_key != program_key) continue;
        int32_t branch = -1;
        if (!family_influences().valid_handle(binding.branch_handle, branch) ||
            family_influences().family_handle[branch] != family_handle)
            continue;
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(program_key, metadata) ||
            metadata.lifecycle != kLifecycleEventOnce)
            continue;
        const int32_t prestige = family_influences().prestige_level[branch];
        const int32_t magnitude = effect_id >= 0
            ? family_effect_prestige_magnitude_q16(effect_id, prestige)
            : binding.strength_q16;
        // EVENT_ONCE pays out once per *trigger*, so every fire has to start from
        // a fresh instance generation. The generation is what resets the fire
        // bookkeeping (fire_sequence / effect_applied), rejects still-pending
        // fire transactions of the previous trigger and keeps the command
        // idempotency key distinct from it. Without the bump the same row keeps
        // its identity, its pending transaction can be compacted without an ACK
        // and the cadence then replays the payout with a new fire_sequence --
        // which is exactly how city_founder's "+220 people" paid out once per
        // day for 75 days in the reported save.
        ++binding.generation;
        if (binding.generation == 0) binding.generation = 1;
        std::string error;
        if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                binding.instance_id, program_key, binding.generation, 0x46414d45,
                static_cast<int64_t>(family_influences().stable_id[branch]),
                binding.branch_handle, binding.target_handle,
                binding.target_generation, prestige, _current_day.get(), -1, true,
                error))
            continue;
        if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                binding.instance_id, binding.generation, 0,
                family_effect_metric_revision(1), magnitude, error))
            continue;
        binding.strength_q16 = magnitude;
        publish_family_effect_metrics(binding, family_effect_metric_revision(1),
            MetricMask::all_declared(FAMILY_METRIC_COUNT));
    }
}

void NativeEconomyRuntime::apply_pending_family_split_gifts() {
    if (_pending_family_split_gifts.empty()) return;
    std::vector<PendingFamilySplitGift> pending;
    pending.swap(_pending_family_split_gifts);
    for (const PendingFamilySplitGift &gift : pending) {
        int32_t family = -1;
        if (!families_store().valid_handle(gift.family_handle, family)) continue;
        int32_t branch = -1;
        for (int32_t i = 0; i < static_cast<int32_t>(family_influences().active.size());
             ++i) {
            if (family_influences().active[i] != 0 &&
                family_influences().family_handle[i] == gift.family_handle &&
                family_influences().cell[i] == gift.cell) {
                branch = i;
                break;
            }
        }
        if (branch < 0) continue;
        const uint64_t branch_handle = family_influences().handle_for_index(branch);
        std::string error;
        if ((gift.flags & FAMILY_FLAG_SPLIT_GIFT_BUILDING) != 0 &&
            gift.building_type_id >= 0 && gift.building_count > 0) {
            Command cmd;
            cmd.opcode = COMMAND_FAMILY_FREE_BUILDING;
            cmd.effective_day = _current_day.get();
            cmd.sequence = 1;
            cmd.target_handle = branch_handle;
            cmd.i32_0 = 0;
            cmd.i32_1 = gift.building_type_id;
            cmd.i64_0 = gift.building_count;
            apply_family_free_building_reward(cmd, error);
        }
        if ((gift.flags & FAMILY_FLAG_SPLIT_GIFT_POPULATION) != 0 &&
            gift.population > 0) {
            Command cmd;
            cmd.opcode = COMMAND_FAMILY_POPULATION_REWARD;
            cmd.effective_day = _current_day.get();
            cmd.sequence = 2;
            cmd.target_handle = branch_handle;
            cmd.i32_0 = 0;
            cmd.i64_0 = gift.population;
            apply_family_population_reward(cmd, error);
        }
    }
}

#include "economy_runtime_family_buff_policy.inc"
} // namespace pk
