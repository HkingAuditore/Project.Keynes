#include "economy_runtime.h"
#include "country_runtime.h"
#include "effect_runtime.h"

#include <algorithm>
#include <array>
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
constexpr int32_t kDominantShareFloorQ16 = NativeEconomyRuntime::Q16_ONE * 2 / 3;
constexpr int32_t kMonopolyShareFloorQ16 = NativeEconomyRuntime::Q16_ONE * 60 / 100;
constexpr int32_t kSpecializedDominantBonusQ16 = 3932; // +6%
constexpr int32_t kSpecializedOtherPenaltyQ16 = 1966; // -3%

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
constexpr int32_t kSelectorNeighborsR1 = 6;
constexpr int32_t kSelectorNeighborsR2 = 7;
constexpr int32_t kOneIndustryShareFloorQ16 = NativeEconomyRuntime::Q16_ONE * 70 / 100;
constexpr int32_t kDefaultRainThresholdQ16 = NativeEconomyRuntime::Q16_ONE / 4;

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

const NativeEconomyRuntime::FamilyIndustryStats *
NativeEconomyRuntime::family_industry_stats_for(int32_t family_index,
                                                int32_t cell) const {
    const auto found = std::lower_bound(_family_industry_stats.begin(),
        _family_industry_stats.end(), std::make_pair(family_index, cell),
        [](const FamilyIndustryStats &row, const std::pair<int32_t, int32_t> &key) {
            return std::tie(row.family_index, row.cell) <
                std::tie(key.first, key.second);
        });
    if (found == _family_industry_stats.end() ||
        found->family_index != family_index || found->cell != cell)
        return nullptr;
    return &(*found);
}

int32_t NativeEconomyRuntime::family_owned_output_factor_q16(
        int32_t family_index, int32_t cell, int32_t sector,
        int32_t upgrade_family) const {
    int64_t factor = Q16_ONE;
    const auto begin = std::lower_bound(_family_owned_output_rows.begin(),
        _family_owned_output_rows.end(), family_index,
        [](const FamilyOwnedOutputRow &row, int32_t family) {
            return row.family_index < family;
        });
    for (auto it = begin; it != _family_owned_output_rows.end() &&
            it->family_index == family_index; ++it) {
        if (it->cell != cell) continue;
        const bool matches = it->kind == 0 ||
            (it->kind == 1 && it->dense_id == sector) ||
            (it->kind == 2 && it->dense_id == upgrade_family);
        if (!matches) continue;
        factor = factor * it->factor_q16 / Q16_ONE;
        factor = std::clamp<int64_t>(factor, 0, 4 * Q16_ONE);
    }
    return static_cast<int32_t>(factor);
}

int32_t NativeEconomyRuntime::family_group_owned_output_factor_q16(
        int32_t group_index) const {
    if (group_index < 0 || group_index >= static_cast<int32_t>(_buildings.size()))
        return Q16_ONE;
    const BuildingGroup &group = _buildings[static_cast<size_t>(group_index)];
    if (group.count <= 0) return Q16_ONE;
    if (_family_building_offsets.size() != _buildings.size() + 1) return Q16_ONE;
    const int32_t sector = group.type_id >= 0 &&
            group.type_id < static_cast<int32_t>(_building_economic_sectors.size())
        ? _building_economic_sectors[static_cast<size_t>(group.type_id)] : 2;
    const int32_t upgrade_family = group.type_id >= 0 &&
            group.type_id < static_cast<int32_t>(_building_upgrade_family_indices.size())
        ? _building_upgrade_family_indices[static_cast<size_t>(group.type_id)] : -1;
    int64_t blend = 0;
    int64_t attributed = 0;
    for (int32_t cursor = _family_building_offsets[static_cast<size_t>(group_index)];
         cursor < _family_building_offsets[static_cast<size_t>(group_index) + 1];
         ++cursor) {
        const int32_t edge_index = _family_building_edge_indices[
            static_cast<size_t>(cursor)];
        if (edge_index < 0 || edge_index >= static_cast<int32_t>(
                _family_ownerships.size()))
            continue;
        const FamilyBuildingOwnership &edge = _family_ownerships[
            static_cast<size_t>(edge_index)];
        int32_t family = -1;
        if (!_families.valid_handle(edge.family_handle, family)) continue;
        const int64_t owned = std::max<int64_t>(0, std::min(edge.owned_count,
            group.count - attributed));
        if (owned <= 0) continue;
        const int32_t factor = family_owned_output_factor_q16(family, group.cell,
            sector, upgrade_family);
        blend += owned * factor;
        attributed += owned;
    }
    if (attributed <= 0) return Q16_ONE;
    const int64_t anonymous = std::max<int64_t>(0, group.count - attributed);
    blend += anonymous * Q16_ONE;
    return clamp_factor_q16(blend / group.count);
}

void NativeEconomyRuntime::rebuild_family_industry_metrics() {
    _family_industry_stats.clear();
    if (_families.active.empty() || _building_cell_offsets.size() !=
            static_cast<size_t>(_cell_count) + 1)
        return;
    const std::unordered_map<uint64_t, int32_t> &building_by_handle =
        building_handle_index();
    std::vector<uint32_t> catalog_tiers(_building_upgrade_family_ids.size(), 0);
    std::vector<int32_t> catalog_tier_count(_building_upgrade_family_ids.size(), 0);
    for (size_t type = 0; type < _building_upgrade_family_indices.size(); ++type) {
        const int32_t family = _building_upgrade_family_indices[type];
        const int32_t tier = type < _building_upgrade_tiers.size()
            ? _building_upgrade_tiers[type] : -1;
        if (family < 0 || family >= static_cast<int32_t>(catalog_tiers.size()) ||
            tier < 0 || tier >= 32) continue;
        const uint32_t bit = 1u << static_cast<uint32_t>(tier);
        if ((catalog_tiers[static_cast<size_t>(family)] & bit) == 0)
            ++catalog_tier_count[static_cast<size_t>(family)];
        catalog_tiers[static_cast<size_t>(family)] |= bit;
    }
    std::vector<std::vector<int32_t>> family_cells(_families.active.size());
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            _family_influences.active.size()); ++branch) {
        if (_family_influences.active[branch] == 0) continue;
        int32_t family = -1;
        if (!_families.valid_handle(_family_influences.family_handle[branch], family) ||
            family < 0 || family >= static_cast<int32_t>(family_cells.size()))
            continue;
        const int32_t cell = _family_influences.cell[branch];
        if (cell >= 0 && cell < _cell_count)
            family_cells[static_cast<size_t>(family)].push_back(cell);
    }
    for (int32_t family = 0; family < static_cast<int32_t>(_families.active.size());
         ++family) {
        if (_families.active[family] == 0) continue;
        auto &cells = family_cells[static_cast<size_t>(family)];
        if (cells.empty()) {
            const int32_t home = _families.home_cell[family];
            if (home >= 0 && home < _cell_count) cells.push_back(home);
        }
        std::sort(cells.begin(), cells.end());
        cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
        const uint64_t family_handle = _families.handle_for_index(family);
        for (int32_t cell : cells) {
            FamilyIndustryStats stats;
            stats.family_index = family;
            stats.cell = cell;
            int64_t sector_owned[5] = {0, 0, 0, 0, 0};
            int64_t total_owned = 0;
            std::unordered_map<int32_t, int64_t> owned_by_family;
            std::unordered_map<int32_t, uint32_t> owned_tiers;
            if (family < static_cast<int32_t>(_family_owned_offsets.size()) - 1) {
                for (int32_t cursor = _family_owned_offsets[static_cast<size_t>(family)];
                     cursor < _family_owned_offsets[static_cast<size_t>(family) + 1];
                     ++cursor) {
                    const int32_t edge_index = _family_owned_edge_indices[
                        static_cast<size_t>(cursor)];
                    if (edge_index < 0 || edge_index >= static_cast<int32_t>(
                            _family_ownerships.size()))
                        continue;
                    const FamilyBuildingOwnership &edge = _family_ownerships[
                        static_cast<size_t>(edge_index)];
                    if (edge.family_handle != family_handle) continue;
                    const auto found = building_by_handle.find(edge.building_handle);
                    if (found == building_by_handle.end()) continue;
                    const BuildingGroup &group = _buildings[
                        static_cast<size_t>(found->second)];
                    if (group.cell != cell || group.count <= 0 ||
                        group.operating_state != 0) continue;
                    const int64_t owned = std::max<int64_t>(0,
                        std::min(edge.owned_count, group.count));
                    if (owned <= 0) continue;
                    const int32_t type_id = group.type_id;
                    const int32_t sector = type_id >= 0 && type_id < static_cast<int32_t>(
                            _building_economic_sectors.size())
                        ? _building_economic_sectors[static_cast<size_t>(type_id)] : -1;
                    if (sector >= 0 && sector < 5) {
                        sector_owned[sector] += owned;
                        if (sector == kManufacturingSector)
                            stats.has_owned_manufacturing = 1;
                    }
                    total_owned += owned;
                    const int32_t upgrade_family = type_id >= 0 &&
                            type_id < static_cast<int32_t>(
                                _building_upgrade_family_indices.size())
                        ? _building_upgrade_family_indices[static_cast<size_t>(type_id)]
                        : -1;
                    const int32_t tier = type_id >= 0 &&
                            type_id < static_cast<int32_t>(_building_upgrade_tiers.size())
                        ? _building_upgrade_tiers[static_cast<size_t>(type_id)] : -1;
                    if (upgrade_family >= 0) {
                        owned_by_family[upgrade_family] += owned;
                        if (tier >= 0 && tier < 32)
                            owned_tiers[upgrade_family] |=
                                1u << static_cast<uint32_t>(tier);
                    }
                }
            }
            std::unordered_map<int32_t, int64_t> cell_by_family;
            for (int32_t group_index = _building_cell_offsets[static_cast<size_t>(cell)];
                 group_index < _building_cell_offsets[static_cast<size_t>(cell) + 1];
                 ++group_index) {
                const BuildingGroup &group = _buildings[static_cast<size_t>(group_index)];
                if (group.count <= 0 || group.operating_state != 0) continue;
                const int32_t type_id = group.type_id;
                const int32_t upgrade_family = type_id >= 0 &&
                        type_id < static_cast<int32_t>(
                            _building_upgrade_family_indices.size())
                    ? _building_upgrade_family_indices[static_cast<size_t>(type_id)]
                    : -1;
                if (upgrade_family >= 0)
                    cell_by_family[upgrade_family] += group.count;
            }
            int32_t distinct = 0;
            int32_t dominant = -1;
            int64_t dominant_owned = 0;
            for (int32_t sector = 0; sector < 5; ++sector) {
                if (sector_owned[sector] <= 0) continue;
                ++distinct;
                if (sector_owned[sector] > dominant_owned) {
                    dominant_owned = sector_owned[sector];
                    dominant = sector;
                }
            }
            stats.distinct_sector_count = distinct;
            stats.dominant_sector_id = dominant;
            stats.dominant_sector_share_q16 = total_owned > 0
                ? static_cast<int32_t>(std::clamp<int64_t>(
                    dominant_owned * Q16_ONE / total_owned, 0, Q16_ONE)) : 0;
            int32_t complete = 0;
            int32_t best_share = -1;
            int32_t best_complete_share = -1;
            int32_t best_uf = -1;
            int32_t best_complete_uf = -1;
            for (const auto &owned : owned_by_family) {
                const int32_t uf = owned.first;
                const int64_t cell_total = cell_by_family[uf];
                const int32_t share = cell_total > 0
                    ? static_cast<int32_t>(std::clamp<int64_t>(
                        owned.second * Q16_ONE / cell_total, 0, Q16_ONE)) : 0;
                if (share > best_share || (share == best_share &&
                        (best_uf < 0 || uf < best_uf))) {
                    best_share = share;
                    best_uf = uf;
                }
                const uint32_t required = uf >= 0 &&
                        uf < static_cast<int32_t>(catalog_tiers.size())
                    ? catalog_tiers[static_cast<size_t>(uf)] : 0;
                const int32_t required_count = uf >= 0 &&
                        uf < static_cast<int32_t>(catalog_tier_count.size())
                    ? catalog_tier_count[static_cast<size_t>(uf)] : 0;
                const uint32_t have = owned_tiers[uf];
                if (required_count >= 2 && required != 0 && (have & required) == required) {
                    ++complete;
                    if (share > best_complete_share || (share == best_complete_share &&
                            (best_complete_uf < 0 || uf < best_complete_uf))) {
                        best_complete_share = share;
                        best_complete_uf = uf;
                    }
                }
            }
            stats.complete_chain_count = complete;
            stats.max_local_chain_share_q16 = std::max(0, best_share);
            stats.max_chain_upgrade_family_id = complete > 0 ? best_complete_uf : best_uf;
            _family_industry_stats.push_back(stats);
        }
    }
    std::sort(_family_industry_stats.begin(), _family_industry_stats.end(),
        [](const FamilyIndustryStats &a, const FamilyIndustryStats &b) {
            return std::tie(a.family_index, a.cell) <
                std::tie(b.family_index, b.cell);
        });
}

void NativeEconomyRuntime::rebuild_family_owned_output_csr() {
    _family_owned_output_rows.clear();
    std::vector<FamilyOwnedOutputRow> expanded;
    expanded.reserve(_family_effect_bindings.size());
    auto append_row = [&](int32_t family, int32_t cell, int32_t kind,
                          int32_t dense_id, int32_t factor) {
        if (family < 0 || cell < 0 || factor == Q16_ONE) return;
        expanded.push_back({family, cell, kind, dense_id,
            clamp_factor_q16(factor)});
    };
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        int32_t branch = -1;
        int32_t family = -1;
        if (!_family_influences.valid_handle(binding.branch_handle, branch) ||
            !_families.valid_handle(_family_influences.family_handle[branch], family))
            continue;
        const int32_t cell = _family_influences.cell[branch];
        const FamilyIndustryStats *stats = family_industry_stats_for(family, cell);
        if (stats == nullptr) continue;
        const int32_t magnitude = clamp_factor_q16(binding.strength_q16);
        if (binding.definition_key == kEffectSpecialized) {
            if (!(stats->distinct_sector_count == 1 ||
                    stats->dominant_sector_share_q16 >= kDominantShareFloorQ16) ||
                stats->dominant_sector_id < 0)
                continue;
            for (int32_t sector = 0; sector < 5; ++sector) {
                const int32_t bonus = sector == stats->dominant_sector_id
                    ? kSpecializedDominantBonusQ16 : -kSpecializedOtherPenaltyQ16;
                append_row(family, cell, 1, sector,
                    bonus_factor_q16(magnitude, bonus));
            }
        } else if (binding.definition_key == kEffectVersatile) {
            if (stats->distinct_sector_count < 3) continue;
            append_row(family, cell, 0, 0, clamp_factor_q16(
                static_cast<int64_t>(Q16_ONE) + magnitude));
        } else if (binding.definition_key == kEffectCompleteChain) {
            if (stats->complete_chain_count < 1 ||
                stats->max_chain_upgrade_family_id < 0) continue;
            append_row(family, cell, 2, stats->max_chain_upgrade_family_id,
                clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude));
        } else if (binding.definition_key == kEffectMonopoly) {
            if (stats->max_local_chain_share_q16 < kMonopolyShareFloorQ16 ||
                stats->max_chain_upgrade_family_id < 0) continue;
            append_row(family, cell, 2, stats->max_chain_upgrade_family_id,
                clamp_factor_q16(static_cast<int64_t>(Q16_ONE) + magnitude));
        }
    }
    std::sort(expanded.begin(), expanded.end(),
        [](const FamilyOwnedOutputRow &a, const FamilyOwnedOutputRow &b) {
            return std::tie(a.family_index, a.cell, a.kind, a.dense_id) <
                std::tie(b.family_index, b.cell, b.kind, b.dense_id);
        });
    for (const FamilyOwnedOutputRow &row : expanded) {
        if (!_family_owned_output_rows.empty() &&
            _family_owned_output_rows.back().family_index == row.family_index &&
            _family_owned_output_rows.back().cell == row.cell &&
            _family_owned_output_rows.back().kind == row.kind &&
            _family_owned_output_rows.back().dense_id == row.dense_id) {
            const int64_t combined = static_cast<int64_t>(
                _family_owned_output_rows.back().factor_q16) * row.factor_q16 /
                Q16_ONE;
            _family_owned_output_rows.back().factor_q16 = clamp_factor_q16(combined);
        } else {
            _family_owned_output_rows.push_back(row);
        }
    }
}

void NativeEconomyRuntime::apply_family_split_policy_flags(int32_t family_index,
                                                          uint16_t policy,
                                                          uint8_t weight_q8) {
    if (family_index < 0 || family_index >= static_cast<int32_t>(
            _families.flags.size()) || _families.active[family_index] == 0)
        return;
    uint16_t flags = _families.flags[static_cast<size_t>(family_index)];
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
    _families.flags[static_cast<size_t>(family_index)] = flags;
}

bool NativeEconomyRuntime::apply_family_set_split_policy(const Command &cmd,
                                                         std::string &error) {
    (void)error;
    int32_t family = -1;
    int32_t branch = -1;
    if (_families.valid_handle(cmd.target_handle, family)) {
    } else if (_family_influences.valid_handle(cmd.target_handle, branch)) {
        if (!_families.valid_handle(_family_influences.family_handle[branch], family)) {
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
        family_index >= static_cast<int32_t>(_families.active.size()) ||
        _families.active[family_index] == 0 ||
        _effect_runtime == nullptr || _family_effect_keys.empty())
        return;
    uint64_t rng = 1469598103934665603ULL;
    rng = trace_hash_mix(rng, static_cast<uint64_t>(_seed));
    rng = trace_hash_mix(rng, static_cast<uint64_t>(
        _families.stable_id[family_index]));
    rng = trace_hash_mix(rng, static_cast<uint32_t>(
        _family_effect_catalog_version));
    const uint64_t family_handle = _families.handle_for_index(family_index);
    std::vector<int32_t> owned;
    bool has_random_pool = false;
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        int32_t branch = -1;
        if (!_family_influences.valid_handle(binding.branch_handle, branch) ||
            _family_influences.family_handle[branch] != family_handle)
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
    const int32_t origin = _families.origin_cell[family_index];
    const int32_t home = _families.home_cell[family_index];
    const int32_t tech_cell = origin >= 0 && origin < _cell_count ? origin : home;
    std::vector<int32_t> candidates;
    int64_t total_weight = 0;
    for (int32_t effect_id = 0; effect_id < static_cast<int32_t>(
            _family_effect_keys.size()); ++effect_id) {
        if (effect_id >= static_cast<int32_t>(_family_effect_random_pool_eligible.size()) ||
            _family_effect_random_pool_eligible[static_cast<size_t>(effect_id)] == 0)
            continue;
        if (!family_effect_technology_unlocked(effect_id, tech_cell))
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
    if (candidates.empty() || total_weight <= 0) return;
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
    const std::string &key = _family_effect_keys[static_cast<size_t>(chosen)];
    int32_t prestige = 0;
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            _family_influences.active.size()); ++branch) {
        if (_family_influences.active[branch] == 0 ||
            _family_influences.family_handle[branch] != family_handle) continue;
        prestige = std::max(prestige,
            static_cast<int32_t>(_family_influences.prestige_level[branch]));
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
            _family_influences.active.size()); ++branch) {
        if (_family_influences.active[branch] == 0 ||
            _family_influences.family_handle[branch] != family_handle) continue;
        const uint64_t branch_handle = _family_influences.handle_for_index(branch);
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(key, metadata)) continue;
        const int32_t source_cell = _family_influences.cell[branch];
        std::vector<int32_t> target_cells;
        collect_family_effect_target_cells(source_cell, metadata.target_selector_kind,
            target_cells);
        if (target_cells.empty() && (metadata.target_domain == 2 ||
                metadata.target_domain == 4 || metadata.target_domain == 5))
            continue;
        const bool event_once = metadata.lifecycle == kLifecycleEventOnce;
        auto bind_one = [&](int32_t target_cell) {
            uint64_t identity = trace_hash_mix(1469598103934665603ULL,
                static_cast<uint64_t>(_family_influences.stable_id[branch]));
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
            } else if (metadata.target_domain == 0) {
                target_handle = family_handle;
                target_generation = static_cast<uint32_t>(family_handle >> 32U);
            } else if (metadata.target_domain == 3 && _country_runtime != nullptr) {
                const int32_t country_cell = target_cell >= 0 ? target_cell : source_cell;
                target_handle = static_cast<uint64_t>(
                    _country_runtime->country_handle_for_cell(country_cell));
                target_generation = static_cast<uint32_t>(target_handle >> 32U);
                if (target_handle == 0) return;
            } else {
                const int32_t resolved = target_cell >= 0 ? target_cell : source_cell;
                if (resolved < 0 || resolved >= _cell_count) return;
                target_handle = static_cast<uint64_t>(resolved);
                target_generation = 1;
            }
            if (!event_once) {
                std::string error;
                if (!_effect_runtime->upsert_instance_pod(instance_id, key,
                        static_cast<uint32_t>(branch_handle >> 32U), 0x46414d50,
                        static_cast<int64_t>(_family_influences.stable_id[branch]),
                        branch_handle, target_handle, target_generation, prestige,
                        _current_day, true, error))
                    return;
                if (!_effect_runtime->set_metric_pod(instance_id, 0,
                        family_effect_metric_revision(1), magnitude, error))
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
                        std::numeric_limits<uint64_t>::max());
            }
        };
        if (metadata.target_selector_kind == kSelectorNeighborsR1 ||
            metadata.target_selector_kind == kSelectorNeighborsR2) {
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
    for (int32_t family = 0; family < static_cast<int32_t>(_families.active.size());
         ++family) {
        if (_families.active[family] == 0) continue;
        const int32_t home = _families.home_cell[family];
        if (static_cast<uint64_t>(_country_runtime->country_handle_for_cell(home)) !=
            country_handle)
            continue;
        const uint64_t family_handle = _families.handle_for_index(family);
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                _family_influences.active.size()); ++branch) {
            if (_family_influences.active[branch] == 0 ||
                _family_influences.family_handle[branch] != family_handle) continue;
            const uint64_t branch_handle = _family_influences.handle_for_index(branch);
            const int32_t prestige = _family_influences.prestige_level[branch];
            const int32_t magnitude = family_effect_prestige_magnitude_q16(
                effect_id, prestige);
            uint64_t identity = trace_hash_mix(1469598103934665603ULL,
                static_cast<uint64_t>(_family_influences.stable_id[branch]));
            identity = trace_hash_mix(identity, static_cast<uint32_t>(
                _family_influences.cell[branch]));
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
            } else if (metadata.target_domain == 2 || metadata.target_domain == 5) {
                target_handle = static_cast<uint64_t>(_family_influences.cell[branch]);
                target_generation = 1;
            }
            std::string error;
            if (!_effect_runtime->upsert_instance_pod(instance_id, kEffectAncestral,
                    static_cast<uint32_t>(branch_handle >> 32U), 0x46414d43,
                    static_cast<int64_t>(_family_influences.stable_id[branch]),
                    branch_handle, target_handle, target_generation, prestige,
                    _current_day, true, error))
                continue;
            _effect_runtime->refresh_managed_duration_pod(instance_id,
                static_cast<uint32_t>(branch_handle >> 32U), _current_day);
            if (!_effect_runtime->set_metric_pod(instance_id, 0,
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
                    std::numeric_limits<uint64_t>::max());
        }
    }
}

void NativeEconomyRuntime::notify_era_milestone_activated(uint64_t country_handle) {
    grant_ancestral_precept_for_country(country_handle);
}

void NativeEconomyRuntime::collect_family_effect_target_cells(
        int32_t source_cell, int32_t selector_kind,
        std::vector<int32_t> &out_cells) const {
    out_cells.clear();
    if (source_cell < 0 || source_cell >= _cell_count) return;
    if (selector_kind != kSelectorNeighborsR1 && selector_kind != kSelectorNeighborsR2) {
        out_cells.push_back(source_cell);
        return;
    }
    if (_building_neighbors.size() != static_cast<size_t>(_cell_count) * 6)
        return;
    std::unordered_set<int32_t> unique;
    auto push_ring = [&](int32_t cell) {
        for (int32_t dir = 0; dir < 6; ++dir) {
            const int32_t neighbor = _building_neighbors[
                static_cast<size_t>(cell) * 6 + dir];
            if (neighbor < 0 || neighbor >= _cell_count || neighbor == source_cell)
                continue;
            unique.insert(neighbor);
        }
    };
    push_ring(source_cell);
    if (selector_kind == kSelectorNeighborsR2) {
        const std::vector<int32_t> ring1(unique.begin(), unique.end());
        for (int32_t cell : ring1) push_ring(cell);
    }
    out_cells.assign(unique.begin(), unique.end());
    std::sort(out_cells.begin(), out_cells.end());
    if (static_cast<int32_t>(out_cells.size()) > 18)
        out_cells.resize(18);
}

void NativeEconomyRuntime::fire_family_event_once_effect(int32_t family_index,
                                                         const std::string &program_key) {
    if (family_index < 0 || family_index >= static_cast<int32_t>(
            _families.active.size()) || _families.active[family_index] == 0 ||
        _effect_runtime == nullptr || program_key.empty())
        return;
    const uint64_t family_handle = _families.handle_for_index(family_index);
    const int32_t effect_id = family_effect_id_for_key(program_key);
    for (size_t i = 0; i < _family_effect_bindings.size(); ++i) {
        FamilyEffectBinding &binding = _family_effect_bindings[i];
        if (binding.definition_key != program_key) continue;
        int32_t branch = -1;
        if (!_family_influences.valid_handle(binding.branch_handle, branch) ||
            _family_influences.family_handle[branch] != family_handle)
            continue;
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(program_key, metadata) ||
            metadata.lifecycle != kLifecycleEventOnce)
            continue;
        const int32_t prestige = _family_influences.prestige_level[branch];
        const int32_t magnitude = effect_id >= 0
            ? family_effect_prestige_magnitude_q16(effect_id, prestige)
            : binding.strength_q16;
        std::string error;
        if (!_effect_runtime->upsert_instance_pod(binding.instance_id, program_key,
                binding.generation, 0x46414d45,
                static_cast<int64_t>(_family_influences.stable_id[branch]),
                binding.branch_handle, binding.target_handle,
                binding.target_generation, prestige, _current_day, true, error))
            continue;
        _effect_runtime->set_metric_pod(binding.instance_id, 0,
            family_effect_metric_revision(1), magnitude, error);
        binding.strength_q16 = magnitude;
        publish_family_effect_metrics(binding, family_effect_metric_revision(1),
            std::numeric_limits<uint64_t>::max());
    }
}

void NativeEconomyRuntime::apply_pending_family_split_gifts() {
    if (_pending_family_split_gifts.empty()) return;
    std::vector<PendingFamilySplitGift> pending;
    pending.swap(_pending_family_split_gifts);
    for (const PendingFamilySplitGift &gift : pending) {
        int32_t family = -1;
        if (!_families.valid_handle(gift.family_handle, family)) continue;
        int32_t branch = -1;
        for (int32_t i = 0; i < static_cast<int32_t>(_family_influences.active.size());
             ++i) {
            if (_family_influences.active[i] != 0 &&
                _family_influences.family_handle[i] == gift.family_handle &&
                _family_influences.cell[i] == gift.cell) {
                branch = i;
                break;
            }
        }
        if (branch < 0) continue;
        const uint64_t branch_handle = _family_influences.handle_for_index(branch);
        std::string error;
        if ((gift.flags & FAMILY_FLAG_SPLIT_GIFT_BUILDING) != 0 &&
            gift.building_type_id >= 0) {
            Command cmd;
            cmd.opcode = COMMAND_FAMILY_FREE_BUILDING;
            cmd.effective_day = _current_day;
            cmd.sequence = 1;
            cmd.target_handle = branch_handle;
            cmd.i32_0 = 0;
            cmd.i32_1 = gift.building_type_id;
            cmd.i64_0 = 1;
            apply_family_free_building_reward(cmd, error);
        }
        if ((gift.flags & FAMILY_FLAG_SPLIT_GIFT_POPULATION) != 0 &&
            gift.population > 0) {
            Command cmd;
            cmd.opcode = COMMAND_FAMILY_POPULATION_REWARD;
            cmd.effective_day = _current_day;
            cmd.sequence = 2;
            cmd.target_handle = branch_handle;
            cmd.i32_0 = 0;
            cmd.i64_0 = gift.population;
            apply_family_population_reward(cmd, error);
        }
    }
}

void NativeEconomyRuntime::rebuild_family_policy_scalars() {
    ensure_family_policy_factors();
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count));
    const size_t sector_span = cells * 5U;
    auto reset_stamped = [&](std::vector<int32_t> &lane, int32_t fill,
                             size_t expected) {
        if (lane.size() != expected) {
            lane.assign(expected, fill);
            return;
        }
        for (int32_t cell : _family_policy_stamped_cells) {
            if (cell < 0 || static_cast<size_t>(cell) >= cells) continue;
            if (expected == cells) {
                lane[static_cast<size_t>(cell)] = fill;
            } else {
                for (int32_t sector = 0; sector < 5; ++sector)
                    lane[static_cast<size_t>(cell) * 5U + sector] = fill;
            }
        }
    };
    reset_stamped(_epoch_cell_rain_event_threshold_q16, kDefaultRainThresholdQ16, cells);
    reset_stamped(_epoch_cell_cold_capacity_factor_q16, Q16_ONE, cells);
    reset_stamped(_epoch_cell_sector_output_factor_q16, Q16_ONE, sector_span);
    _family_policy_stamped_cells.clear();
    for (size_t family = 0; family < _families.active.size(); ++family) {
        if (_families.active[family] == 0) continue;
        _family_investment_factor_q16[family] = Q16_ONE;
        _family_birth_factor_q16[family] = Q16_ONE;
        _family_purchase_factor_q16[family] = Q16_ONE;
        if (family < _family_colonization_population_reward.size())
            _family_colonization_population_reward[family] = 0;
    }
    if (_family_knowledge_class_index < 0) {
        for (size_t i = 0; i < _carrying_class_ids.size(); ++i) {
            if (_carrying_class_ids[i] == "technology") {
                _family_knowledge_class_index = static_cast<int32_t>(i);
                break;
            }
        }
    }
    auto stamp_cell = [&](int32_t cell) {
        if (cell < 0 || cell >= _cell_count) return;
        _family_policy_stamped_cells.push_back(cell);
    };
    auto mix_family_factor = [](int32_t &slot, int32_t magnitude) {
        const int64_t mixed = static_cast<int64_t>(slot) *
            std::max(1, magnitude) / NativeEconomyRuntime::Q16_ONE;
        slot = clamp_factor_q16(mixed);
    };
    std::array<int64_t, FAMILY_METRIC_COUNT> metrics{};
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        int32_t branch = -1;
        int32_t family = -1;
        if (!_family_influences.valid_handle(binding.branch_handle, branch) ||
            !_families.valid_handle(_family_influences.family_handle[branch], family))
            continue;
        const int32_t cell = _family_influences.cell[branch];
        const int32_t magnitude = clamp_factor_q16(binding.strength_q16);
        fill_family_behavior_metrics(family, branch, cell, metrics.data(),
            FAMILY_METRIC_COUNT);
        if (binding.definition_key == kEffectWorkRelief) {
            if (metrics[FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16] >= Q16_ONE * 15 / 100)
                mix_family_factor(_family_investment_factor_q16[
                    static_cast<size_t>(family)], magnitude);
        } else if (binding.definition_key == kEffectRemoteKin) {
            if (metrics[FAMILY_METRIC_FAMILY_REMOTE_BRANCH_COUNT] > 0)
                mix_family_factor(_family_investment_factor_q16[
                    static_cast<size_t>(family)], magnitude);
        } else if (binding.definition_key == kEffectWealthyFew) {
            if (metrics[FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16] > Q16_ONE) {
                mix_family_factor(_family_investment_factor_q16[
                    static_cast<size_t>(family)], magnitude);
                const int32_t birth_cut = clamp_factor_q16(
                    static_cast<int64_t>(Q16_ONE) * Q16_ONE /
                    std::max(1, magnitude));
                mix_family_factor(_family_birth_factor_q16[
                    static_cast<size_t>(family)], birth_cut);
            }
        } else if (binding.definition_key == kEffectBranching) {
            mix_family_factor(_family_birth_factor_q16[
                static_cast<size_t>(family)], magnitude);
        } else if (binding.definition_key == kEffectMarketBully) {
            const int32_t pay = clamp_factor_q16(
                static_cast<int64_t>(Q16_ONE) * Q16_ONE / std::max(1, magnitude));
            mix_family_factor(_family_purchase_factor_q16[
                static_cast<size_t>(family)],
                std::min(pay, static_cast<int32_t>(Q16_ONE)));
            mix_family_factor(_family_investment_factor_q16[
                static_cast<size_t>(family)], magnitude);
        } else if (binding.definition_key == kEffectExpansionism) {
            const int32_t amount = std::max(1, magnitude / static_cast<int32_t>(Q16_ONE / 8));
            if (family < static_cast<int32_t>(
                    _family_colonization_population_reward.size()))
                _family_colonization_population_reward[
                    static_cast<size_t>(family)] = std::max(
                    _family_colonization_population_reward[
                        static_cast<size_t>(family)], amount);
        } else if (binding.definition_key == kEffectRainPrayer && cell >= 0 &&
                   static_cast<size_t>(cell) <
                       _epoch_cell_rain_event_threshold_q16.size()) {
            const int32_t lowered = std::max(1,
                static_cast<int32_t>(static_cast<int64_t>(kDefaultRainThresholdQ16) *
                    Q16_ONE / std::max(1, magnitude)));
            _epoch_cell_rain_event_threshold_q16[static_cast<size_t>(cell)] =
                std::min(_epoch_cell_rain_event_threshold_q16[
                    static_cast<size_t>(cell)], lowered);
            stamp_cell(cell);
        } else if (binding.definition_key == kEffectColdResist && cell >= 0 &&
                   static_cast<size_t>(cell) <
                       _epoch_cell_cold_capacity_factor_q16.size()) {
            mix_family_factor(_epoch_cell_cold_capacity_factor_q16[
                static_cast<size_t>(cell)], magnitude);
            stamp_cell(cell);
        } else if (binding.definition_key == kEffectOneIndustry && cell >= 0) {
            const int32_t share = static_cast<int32_t>(
                metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16]);
            const int64_t sector_metric = metrics[FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID];
            const int32_t sector = sector_metric < 0 ? -1 :
                static_cast<int32_t>(sector_metric / Q16_ONE);
            if (share >= kOneIndustryShareFloorQ16 && sector >= 0 && sector < 5 &&
                _epoch_cell_sector_output_factor_q16.size() == sector_span) {
                const size_t index = static_cast<size_t>(cell) * 5U +
                    static_cast<size_t>(sector);
                mix_family_factor(_epoch_cell_sector_output_factor_q16[index],
                    magnitude);
                stamp_cell(cell);
            }
        } else if (binding.definition_key == kEffectRetain) {
            apply_family_split_policy_flags(family, FAMILY_FLAG_SPLIT_RETAIN_ONLY, 0);
        } else if (binding.definition_key == kEffectAbsorb) {
            const int32_t q7 = static_cast<int32_t>(std::clamp<int64_t>(
                static_cast<int64_t>(magnitude) * 128 / Q16_ONE, 128, 255));
            apply_family_split_policy_flags(family, FAMILY_FLAG_SPLIT_BONUS_WEIGHT,
                static_cast<uint8_t>(q7));
        } else if (binding.definition_key == kEffectBreakPast) {
            apply_family_split_policy_flags(family, FAMILY_FLAG_SPLIT_REPLACE, 0);
        } else if (binding.definition_key == kEffectSplitDowry) {
            apply_family_split_policy_flags(family,
                FAMILY_FLAG_SPLIT_GIFT_BUILDING | FAMILY_FLAG_SPLIT_GIFT_POPULATION, 0);
        }
    }
    std::sort(_family_policy_stamped_cells.begin(), _family_policy_stamped_cells.end());
    _family_policy_stamped_cells.erase(std::unique(_family_policy_stamped_cells.begin(),
        _family_policy_stamped_cells.end()), _family_policy_stamped_cells.end());
}

} // namespace pk
