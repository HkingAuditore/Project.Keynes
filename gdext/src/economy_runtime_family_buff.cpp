#include "economy_runtime.h"
#include "economy_effect_forward.h"
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
// Frozen numbering shared with EffectRuntime::TargetSelectorKind. R1 (6) is the
// first fan-out kind, which is what every "does this kind resolve to a list of
// cells" test below keys off; R2 (7) is kept only to document that 7 is a real,
// already-shipped kind and must never be reused.
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
    if (group_index < 0 || group_index >= static_cast<int32_t>(building_count()))
        return Q16_ONE;
    const auto group = building_at(static_cast<size_t>(static_cast<size_t>(group_index)));
    if (group.count <= 0) return Q16_ONE;
    if (_family_building_offsets.size() != building_count() + 1) return Q16_ONE;
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
                family_ownerships().size()))
            continue;
        const FamilyBuildingOwnership &edge = family_ownerships().read_at(
            static_cast<size_t>(edge_index), __FILE__, __LINE__);
        int32_t family = -1;
        if (!families_store().valid_handle(edge.family_handle, family)) continue;
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
    if (families_store().active.empty() || _building_cell_offsets.size() !=
            static_cast<size_t>(_cell_count.get()) + 1)
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
    std::vector<std::vector<int32_t>> family_cells(families_store().active.size());
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0) continue;
        int32_t family = -1;
        if (!families_store().valid_handle(family_influences().family_handle[branch], family) ||
            family < 0 || family >= static_cast<int32_t>(family_cells.size()))
            continue;
        const int32_t cell = family_influences().cell[branch];
        if (cell >= 0 && cell < _cell_count.get())
            family_cells[static_cast<size_t>(family)].push_back(cell);
    }
    for (int32_t family = 0; family < static_cast<int32_t>(families_store().active.size());
         ++family) {
        if (families_store().active[family] == 0) continue;
        auto &cells = family_cells[static_cast<size_t>(family)];
        if (cells.empty()) {
            const int32_t home = families_store().home_cell[family];
            if (home >= 0 && home < _cell_count.get()) cells.push_back(home);
        }
        std::sort(cells.begin(), cells.end());
        cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
        const uint64_t family_handle = families_store().handle_for_index(family);
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
                            family_ownerships().size()))
                        continue;
                    const FamilyBuildingOwnership &edge = family_ownerships().read_at(
                        static_cast<size_t>(edge_index), __FILE__, __LINE__);
                    if (edge.family_handle != family_handle) continue;
                    const auto found = building_by_handle.find(edge.building_handle);
                    if (found == building_by_handle.end()) continue;
                    const auto group = building_view(static_cast<size_t>(found->second));
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
                const auto group = building_view(static_cast<size_t>(group_index));
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
        if (!family_influences().valid_handle(binding.branch_handle, branch) ||
            !families_store().valid_handle(family_influences().family_handle[branch], family))
            continue;
        const int32_t cell = family_influences().cell[branch];
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
        std::vector<int32_t> target_cells;
        collect_family_effect_target_cells(source_cell, metadata.target_selector_kind,
            target_cells);
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
                    _country_runtime->country_handle_for_cell(country_cell));
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
        if (static_cast<uint64_t>(_country_runtime->country_handle_for_cell(home)) !=
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
            const int64_t expires_day =
                metadata.lifecycle == 1 && metadata.stack_policy == 1
                    ? std::max<int64_t>(0, _current_day.get()) +
                        static_cast<int64_t>(metadata.duration_days)
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

void NativeEconomyRuntime::collect_family_effect_target_cells(
        int32_t source_cell, int32_t selector_kind,
        std::vector<int32_t> &out_cells) const {
    // Family rows never carried selector params, so 0 means "runtime default".
    collect_effect_target_cells(source_cell, selector_kind, 0, 0, out_cells);
}

int32_t NativeEconomyRuntime::dominant_resource_at(int32_t cell) const {
    const int32_t cells = _cell_count.get();
    if (cell < 0 || cell >= cells) return -1;
    const auto &stock = resource_stock_lanes();
    const size_t stride = static_cast<size_t>(cells);
    const size_t resource_count = stock.size() / stride;
    int32_t best = -1;
    int64_t best_value = 0;
    for (size_t resource = 0; resource < resource_count; ++resource) {
        const size_t index = resource * stride + static_cast<size_t>(cell);
        const int64_t value = stock[index];
        // Strict '>' keeps ties on the lowest resource id, so the answer does
        // not depend on iteration order.
        if (value <= 0 || value <= best_value) continue;
        best_value = value;
        best = static_cast<int32_t>(resource);
    }
    return best;
}

int32_t NativeEconomyRuntime::dominant_resource_stock_share_q16(int32_t cell) const {
    const int32_t cells = _cell_count.get();
    if (cell < 0 || cell >= cells) return 0;
    const auto &stock = resource_stock_lanes();
    const size_t stride = static_cast<size_t>(cells);
    const size_t resource_count = stock.size() / stride;
    int64_t total = 0;
    int64_t best = 0;
    for (size_t resource = 0; resource < resource_count; ++resource) {
        const int64_t value = stock[resource * stride + static_cast<size_t>(cell)];
        if (value <= 0) continue;
        total += value;
        if (value > best) best = value;
    }
    if (total <= 0 || best <= 0) return 0;
    return static_cast<int32_t>(std::clamp<int64_t>(
        best * Q16_ONE / total, 0, Q16_ONE));
}

int32_t NativeEconomyRuntime::dominant_output_good_at(
        int32_t cell, int32_t &out_share_q16) const {
    out_share_q16 = 0;
    const int32_t cells = _cell_count.get();
    if (cell < 0 || cell >= cells) return -1;
    if (_building_cell_offsets.size() != static_cast<size_t>(cells) + 1) return -1;
    // last_output is already net of output_factor_q16 (see
    // effective_building_output_quantity_at), so spreading it across the
    // authored mix yields a genuine output share -- injecting the sector
    // coefficient again here would square it and break the feedback loop.
    std::unordered_map<int32_t, int64_t> good_output;
    int64_t total = 0;
    for (int32_t group_index = _building_cell_offsets[static_cast<size_t>(cell)];
         group_index < _building_cell_offsets[static_cast<size_t>(cell) + 1];
         ++group_index) {
        const auto group = building_view(static_cast<size_t>(group_index));
        if (group.count <= 0 || group.last_output <= 0) continue;
        if (group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
        const BuildingType &type = _building_types[static_cast<size_t>(group.type_id)];
        if (type.output_count <= 0) continue;
        int64_t mix_total = 0;
        for (int32_t output = type.output_begin;
             output < type.output_begin + type.output_count; ++output) {
            if (output < 0 || output >= static_cast<int32_t>(_building_outputs.size()))
                continue;
            const int64_t quantity =
                _building_outputs[static_cast<size_t>(output)].quantity;
            if (quantity > 0) mix_total += quantity;
        }
        if (mix_total <= 0) continue;
        for (int32_t output = type.output_begin;
             output < type.output_begin + type.output_count; ++output) {
            if (output < 0 || output >= static_cast<int32_t>(_building_outputs.size()))
                continue;
            const GoodAmount &item = _building_outputs[static_cast<size_t>(output)];
            if (item.good_id < 0 || item.quantity <= 0) continue;
            const int64_t share = group.last_output * item.quantity / mix_total;
            if (share <= 0) continue;
            good_output[item.good_id] += share;
            total += share;
        }
    }
    if (total <= 0) return -1;
    int32_t best_good = -1;
    int64_t best = 0;
    // unordered_map iteration order is unspecified, so the tie-break on the
    // lowest good id is what makes the answer deterministic.
    for (const auto &entry : good_output) {
        if (entry.second <= 0) continue;
        if (entry.second > best ||
            (entry.second == best && (best_good < 0 || entry.first < best_good))) {
            best = entry.second;
            best_good = entry.first;
        }
    }
    if (best_good < 0) return -1;
    out_share_q16 = static_cast<int32_t>(std::clamp<int64_t>(
        best * Q16_ONE / total, 0, Q16_ONE));
    return best_good;
}

int32_t NativeEconomyRuntime::cell_country_slot(int32_t cell) const {    if (cell < 0) return -1;
    if (_epoch_cell_country.size() != static_cast<size_t>(_cell_count.get()))
        return -1;
    if (cell >= static_cast<int32_t>(_epoch_cell_country.size())) return -1;
    return _epoch_cell_country[static_cast<size_t>(cell)];
}

void NativeEconomyRuntime::rebuild_country_territory_index() {
    _epoch_country_cell_offsets.clear();
    _epoch_country_cells.clear();
    const int32_t cells = _cell_count.get();
    const int32_t countries = std::max(0, _epoch_country_count);
    // Unowned cells are represented as negative slots and simply never enter the
    // CSR, so the index answers "owned by a real country", not "slot value".
    if (cells <= 0 || countries <= 0 ||
        _epoch_cell_country.size() != static_cast<size_t>(cells))
        return;
    _epoch_country_cell_offsets.assign(static_cast<size_t>(countries) + 1u, 0);
    int32_t owned = 0;
    for (const int32_t owner : _epoch_cell_country) {
        if (owner < 0 || owner >= countries) continue;
        ++_epoch_country_cell_offsets[static_cast<size_t>(owner) + 1u];
        ++owned;
    }
    for (size_t i = 1; i < _epoch_country_cell_offsets.size(); ++i)
        _epoch_country_cell_offsets[i] += _epoch_country_cell_offsets[i - 1u];
    _epoch_country_cells.assign(static_cast<size_t>(owned), -1);
    std::vector<int32_t> cursor = _epoch_country_cell_offsets;
    // Ascending scatter order is load bearing: it makes every slice ascending, so
    // a cell cap keeps the lowest cell ids and the selector stays replayable.
    for (int32_t cell = 0; cell < cells; ++cell) {
        const int32_t owner = _epoch_cell_country[static_cast<size_t>(cell)];
        if (owner < 0 || owner >= countries) continue;
        _epoch_country_cells[static_cast<size_t>(
            cursor[static_cast<size_t>(owner)]++)] = cell;
    }
}

bool NativeEconomyRuntime::country_territory_index_ready() const {
    if (_epoch_country_cell_offsets.empty()) return false;
    if (_epoch_country_cell_offsets.size() !=
        static_cast<size_t>(std::max(0, _epoch_country_count)) + 1u)
        return false;
    return _epoch_country_cell_offsets.back() ==
        static_cast<int32_t>(_epoch_country_cells.size());
}

int32_t NativeEconomyRuntime::country_cell_count(int32_t country_slot) const {
    if (country_slot < 0) return 0;
    if (country_territory_index_ready()) {
        if (country_slot + 1 >=
            static_cast<int32_t>(_epoch_country_cell_offsets.size()))
            return 0;
        return _epoch_country_cell_offsets[static_cast<size_t>(country_slot) + 1u] -
            _epoch_country_cell_offsets[static_cast<size_t>(country_slot)];
    }
    const int32_t cells = _cell_count.get();
    if (cells <= 0 || _epoch_cell_country.size() != static_cast<size_t>(cells))
        return 0;
    int32_t count = 0;
    for (const int32_t owner : _epoch_cell_country)
        if (owner == country_slot) ++count;
    return count;
}

int32_t NativeEconomyRuntime::country_cell_at(
        int32_t country_slot, int32_t index) const {
    if (country_slot < 0 || index < 0) return -1;
    if (country_territory_index_ready()) {
        if (country_slot + 1 >=
            static_cast<int32_t>(_epoch_country_cell_offsets.size()))
            return -1;
        const int32_t begin = _epoch_country_cell_offsets[static_cast<size_t>(country_slot)];
        const int32_t end = _epoch_country_cell_offsets[static_cast<size_t>(country_slot) + 1u];
        if (index >= end - begin) return -1;
        return _epoch_country_cells[static_cast<size_t>(begin) + static_cast<size_t>(index)];
    }
    // Fallback: walk the ownership column in cell order, which is exactly the
    // order the index would have produced.
    const int32_t cells = _cell_count.get();
    if (cells <= 0 || _epoch_cell_country.size() != static_cast<size_t>(cells))
        return -1;
    int32_t seen = 0;
    for (int32_t cell = 0; cell < cells; ++cell) {
        if (_epoch_cell_country[static_cast<size_t>(cell)] != country_slot) continue;
        if (seen == index) return cell;
        ++seen;
    }
    return -1;
}

int32_t NativeEconomyRuntime::country_anchor_cell(int32_t country_slot) const {
    if (country_slot < 0) return -1;
    const int32_t cells = _cell_count.get();
    if (_epoch_cell_country.size() != static_cast<size_t>(cells)) return -1;
    // Fast path: the index was scattered in ascending cell order, so its first
    // slice entry is by construction the lowest owned cell -- the exact value the
    // linear scan below returns. Once the index is consistent it is the
    // authoritative answer, including "this slot owns nothing".
    if (country_territory_index_ready()) {
        if (country_slot + 1 >=
            static_cast<int32_t>(_epoch_country_cell_offsets.size()))
            return -1;
        return country_cell_at(country_slot, 0);
    }
    for (int32_t cell = 0; cell < cells; ++cell) {
        if (_epoch_cell_country[static_cast<size_t>(cell)] == country_slot)
            return cell;
    }
    return -1;
}

void NativeEconomyRuntime::set_target_tags(const TargetTagTable &tags) {
    _target_tags = tags;
    // Any cached bitset was derived from the previous table, so it is stale even
    // if the cell columns have not moved.
    _epoch_tag_bits_valid = false;
    _epoch_tag_bits.clear();
    _epoch_tag_words = 0;
}

void NativeEconomyRuntime::ensure_epoch_tag_bits() const {
    if (_epoch_tag_bits_valid) return;
    // Set first: a trivial or failed build must not be retried on every query.
    _epoch_tag_bits_valid = true;
    _epoch_tag_bits.clear();
    _epoch_tag_words = 0;
    const int32_t tags = _target_tags.count();
    const int32_t cells = _cell_count.get();
    if (tags <= 0 || cells <= 0) return;
    const int32_t words = (cells + 63) / 64;
    _epoch_tag_words = words;
    _epoch_tag_bits.assign(
        static_cast<size_t>(tags) * static_cast<size_t>(words), uint64_t{0});
    // One sample per cell covers every tag: the mask is the union of the ids the
    // table reads, so the sampler skips the other ~40 metrics entirely. This is
    // the whole reason a bitset exists instead of per-query sampling -- the
    // per-cell metric row is the expensive part, and paying it once per epoch is
    // what makes the tag filter usable inside reconcile.
    MetricMask mask;
    _target_tags.collect_metric_mask(mask);
    const int32_t metric_count = static_cast<int32_t>(FAMILY_METRIC_COUNT);
    std::vector<int64_t> values(static_cast<size_t>(metric_count), 0);
    for (int32_t cell = 0; cell < cells; ++cell) {
        sample_effect_metrics(cell, metric_count, values.data(), mask);
        const size_t word = static_cast<size_t>(cell / 64);
        const uint64_t bit = uint64_t{1} << (cell % 64);
        for (int32_t tag = 0; tag < tags; ++tag) {
            if (!_target_tags.matches(tag, values.data(), metric_count)) continue;
            _epoch_tag_bits[static_cast<size_t>(tag) * static_cast<size_t>(words) +
                             word] |= bit;
        }
    }
}

bool NativeEconomyRuntime::cell_has_target_tag(int32_t cell, int32_t tag) const {
    if (cell < 0 || tag < 0) return false;
    ensure_epoch_tag_bits();
    if (_epoch_tag_words <= 0) return false;
    if (cell >= _cell_count.get()) return false;
    const size_t index = static_cast<size_t>(tag) *
        static_cast<size_t>(_epoch_tag_words) + static_cast<size_t>(cell / 64);
    if (index >= _epoch_tag_bits.size()) return false;
    return (_epoch_tag_bits[index] & (uint64_t{1} << (cell % 64))) != 0;
}

void NativeEconomyRuntime::collect_effect_target_cells(
        int32_t source_cell, int32_t selector_kind, int32_t param0, int32_t param1,
        std::vector<int32_t> &out_cells) const {
    out_cells.clear();
    const int32_t cells = _cell_count.get();
    if (source_cell < 0 || source_cell >= cells) return;
    // Anything that is not a generalised selector resolves to the anchor only,
    // which is exactly what the pre-existing 0..5 kinds meant.
    if (selector_kind < EffectRuntime::SELECTOR_NEIGHBORS_R1 ||
        selector_kind > EffectRuntime::SELECTOR_MAX_KIND) {
        out_cells.push_back(source_cell);
        return;
    }
    // Territory selector: walk the ownership index instead of the neighbour
    // graph. Handled before the building-snapshot guards below because "every
    // cell my country owns" is an ownership question -- it must keep working
    // when the building snapshot has not been captured (for example between an
    // epoch capture and the first building refresh).
    if (selector_kind == EffectRuntime::SELECTOR_OWN_TERRITORY) {
        // param1 == 0 -> every owned cell. param1 >= 1 -> 1-based tag id into
        // the catalog's tag table (target_tag.h). The tag filter replaced the
        // three hard-coded river/water predicates this kind shipped with: those
        // were placeholders for exactly this, and nothing in content uses kind
        // 12 yet, so there is no shipped number to move.
        const int32_t tag = param1 > 0 ? param1 - 1 : -1;
        if (tag >= _target_tags.count()) {
            // An unknown tag must not degrade to "match everything": a card
            // whose tag was renamed would quietly start hitting the whole
            // country instead of failing visibly.
            return;
        }
        const int32_t country = cell_country_slot(source_cell);
        if (country < 0) {
            out_cells.push_back(source_cell);
            return;
        }
        // The whole point of this kind is "as many as the instance budget
        // allows", so a missing param0 defaults to the hard ceiling rather than
        // the 8-cell fan-out of the radial kinds.
        const int32_t cap = param0 > 0
            ? std::min(param0, EffectRuntime::SELECTOR_MAX_CELLS)
            : EffectRuntime::SELECTOR_MAX_CELLS;
        const int32_t owned = country_cell_count(country);
        out_cells.reserve(static_cast<size_t>(
            std::min(cap, std::max(0, owned))));
        for (int32_t index = 0; index < owned; ++index) {
            if (static_cast<int32_t>(out_cells.size()) >= cap) break;
            const int32_t cell = country_cell_at(country, index);
            if (cell < 0) continue;
            if (tag >= 0 && !cell_has_target_tag(cell, tag)) continue;
            out_cells.push_back(cell);
        }
        // A country that owns nothing (or whose territory matches no tag)
        // yields nothing on purpose: falling back to the anchor would apply a
        // "only on matching cells" card to a cell that does not match.
        std::sort(out_cells.begin(), out_cells.end());
        out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
        return;
    }
    // Grid-wide tag selector: the ownership-free twin of the branch above.
    // Same 1-based tag ids, same "unknown tag yields nothing" rule, but the
    // candidate set is the whole grid instead of one country. Handled before
    // the building-snapshot guards for the same reason as territory: a tag is
    // a metric reading, not a neighbour-graph walk, so it must keep working
    // when the building columns have not been captured yet.
    if (selector_kind == EffectRuntime::SELECTOR_TAG_ANY_CELL) {
        const int32_t tag = param1 > 0 ? param1 - 1 : -1;
        if (tag >= _target_tags.count()) return;
        // param0 == 0 means "as many as the budget allows", matching territory.
        const int32_t tag_cap = param0 > 0
            ? std::min(param0, EffectRuntime::SELECTOR_MAX_CELLS)
            : EffectRuntime::SELECTOR_MAX_CELLS;
        for (int32_t cell = 0; cell < cells; ++cell) {
            if (static_cast<int32_t>(out_cells.size()) >= tag_cap) break;
            if (tag >= 0 && !cell_has_target_tag(cell, tag)) continue;
            out_cells.push_back(cell);
        }
        // Ascending cell id, so with more matches than the cap the kept subset
        // is a pure function of the grid. It is geographically arbitrary on a
        // large map -- the cap exists to bound the instance table (9 slots x 32
        // = 288 of 4096), not to rank cells -- but "the 32 lowest ids" is at
        // least replayable, which "the 32 nearest the anchor" would not be for
        // a grid-wide card that has no meaningful anchor.
        std::sort(out_cells.begin(), out_cells.end());
        out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
        return;
    }
    if (_building_neighbors.size() != static_cast<size_t>(cells) * 6) return;
    // The generalised kinds read per-cell columns that share the neighbour
    // snapshot's lifetime. A half-populated snapshot must degrade to "no
    // targets" rather than index past the end of a shorter column.
    const size_t cells_size = static_cast<size_t>(cells);
    if (_building_terrain.size() != cells_size ||
        _building_is_water.size() != cells_size ||
        _building_has_river.size() != cells_size)
        return;

    // R1/R2 keep their historical 18-cell ceiling so existing family effect
    // numbers do not move; the generalised kinds default to a smaller fan-out
    // because they fan out instances rather than one aggregated binding.
    const int32_t default_cap =
        selector_kind <= EffectRuntime::SELECTOR_NEIGHBORS_R2
        ? 18 : EffectRuntime::SELECTOR_DEFAULT_CELLS;
    const int32_t cap = param0 > 0
        ? std::min(param0, EffectRuntime::SELECTOR_MAX_CELLS)
        : default_cap;
    // Kinds 6/7 keep the family contract of never returning the anchor itself.
    // The generalised kinds include it, because a "component" or "within N"
    // that silently excludes its own anchor makes a lone cell behave as if the
    // effect did not exist.
    const bool include_anchor =
        selector_kind >= EffectRuntime::SELECTOR_SAME_TERRAIN_COMPONENT;
    // param0 is always the fan-out cap; param1 carries the kind-specific
    // argument (predicate id, or hop count for SELECTOR_DISTANCE_N). Reusing
    // param0 as the hop count would silently couple "reach 2 hops" with
    // "return at most 2 cells", which is never what an author means.
    int32_t max_depth = 0;
    switch (selector_kind) {
        case EffectRuntime::SELECTOR_NEIGHBORS_R1: max_depth = 1; break;
        case EffectRuntime::SELECTOR_NEIGHBORS_R2: max_depth = 2; break;
        case EffectRuntime::SELECTOR_DISTANCE_N:
            max_depth = param1 > 0
                ? std::min(param1, EffectRuntime::SELECTOR_MAX_CELLS) : 3;
            break;
        default: max_depth = cells; break;
    }

    // Predicate ids for SELECTOR_PREDICATE_ANY_CELL. Only per-cell columns that
    // already exist are exposed here; output-share predicates arrive with the
    // metric write-back milestone.
    auto matches_predicate = [&](int32_t cell) {
        switch (param1) {
            case 1: return _building_has_river[static_cast<size_t>(cell)] != 0;
            case 2: return _building_is_water[static_cast<size_t>(cell)] != 0;
            case 3: return _building_is_water[static_cast<size_t>(cell)] == 0;
            default: return false;
        }
    };
    const int32_t anchor_terrain = _building_terrain[static_cast<size_t>(source_cell)];
    const int32_t anchor_resource = dominant_resource_at(source_cell);
    auto accepts = [&](int32_t cell) {
        switch (selector_kind) {
            case EffectRuntime::SELECTOR_SAME_TERRAIN_COMPONENT:
                return _building_terrain[static_cast<size_t>(cell)] == anchor_terrain;
            case EffectRuntime::SELECTOR_SAME_RESOURCE_COMPONENT:
                return anchor_resource >= 0 &&
                    dominant_resource_at(cell) == anchor_resource;
            case EffectRuntime::SELECTOR_PREDICATE_ANY_CELL:
                return matches_predicate(cell);
            default:
                return true;
        }
    };

    // A predicate selector is grid-wide by definition: the author asks for
    // "every cell with a river", not "the river cells reachable from here".
    // Walking it with the component BFS below would silently confine the answer
    // to cells bordering the anchor, because that walk only expands through
    // cells that already passed the predicate.
    if (selector_kind == EffectRuntime::SELECTOR_PREDICATE_ANY_CELL) {
        for (int32_t cell = 0; cell < cells; ++cell) {
            if (static_cast<int32_t>(out_cells.size()) >= cap) break;
            if (matches_predicate(cell)) out_cells.push_back(cell);
        }
        std::sort(out_cells.begin(), out_cells.end());
        out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
        if (static_cast<int32_t>(out_cells.size()) > cap) out_cells.resize(cap);
        return;
    }

    std::vector<uint8_t> seen(static_cast<size_t>(cells), 0);
    seen[static_cast<size_t>(source_cell)] = 1;
    if (include_anchor && accepts(source_cell)) out_cells.push_back(source_cell);
    if (include_anchor && static_cast<int32_t>(out_cells.size()) >= cap) return;
    // Breadth-first so the cap keeps the *nearest* cells and the order is a
    // pure function of the grid, never of hash iteration.
    std::vector<int32_t> frontier;
    frontier.push_back(source_cell);
    std::vector<int32_t> next;
    for (int32_t depth = 0; depth < max_depth && !frontier.empty(); ++depth) {
        next.clear();
        for (const int32_t cell : frontier) {
            for (int32_t dir = 0; dir < 6; ++dir) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 + dir];
                if (neighbor < 0 || neighbor >= cells) continue;
                if (seen[static_cast<size_t>(neighbor)] != 0) continue;
                seen[static_cast<size_t>(neighbor)] = 1;
                if (!accepts(neighbor)) continue;
                next.push_back(neighbor);
                out_cells.push_back(neighbor);
                if (static_cast<int32_t>(out_cells.size()) >= cap) break;
            }
            if (static_cast<int32_t>(out_cells.size()) >= cap) break;
        }
        if (static_cast<int32_t>(out_cells.size()) >= cap) break;
        frontier.swap(next);
    }
    std::sort(out_cells.begin(), out_cells.end());
    out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
    if (static_cast<int32_t>(out_cells.size()) > cap) out_cells.resize(cap);
}

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
            gift.building_type_id >= 0) {
            Command cmd;
            cmd.opcode = COMMAND_FAMILY_FREE_BUILDING;
            cmd.effective_day = _current_day.get();
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
            cmd.effective_day = _current_day.get();
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
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
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
    for (size_t family = 0; family < families_store().active.size(); ++family) {
        if (families_store().active[family] == 0) continue;
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
        if (cell < 0 || cell >= _cell_count.get()) return;
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
        if (!family_influences().valid_handle(binding.branch_handle, branch) ||
            !families_store().valid_handle(family_influences().family_handle[branch], family))
            continue;
        const int32_t cell = family_influences().cell[branch];
        const int32_t magnitude = clamp_factor_q16(binding.strength_q16);
        // Direct policies consume only these five signals. Most bindings have
        // no metric condition and need no population/building/resource scans.
        MetricMask mask;
        if (binding.definition_key == kEffectWorkRelief)
            mask.set(FAMILY_METRIC_CELL_UNEMPLOYMENT_Q16);
        else if (binding.definition_key == kEffectRemoteKin)
            mask.set(FAMILY_METRIC_FAMILY_REMOTE_BRANCH_COUNT);
        else if (binding.definition_key == kEffectWealthyFew)
            mask.set(FAMILY_METRIC_FAMILY_CASH_PER_CAPITA_VS_CELL_Q16);
        else if (binding.definition_key == kEffectOneIndustry) {
            mask.set(FAMILY_METRIC_CELL_DOMINANT_SECTOR_ID);
            mask.set(FAMILY_METRIC_CELL_DOMINANT_SECTOR_SHARE_Q16);
        }
        fill_family_behavior_metrics(family, branch, cell, metrics.data(),
            FAMILY_METRIC_COUNT, mask);
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
