#include "economy_runtime.h"

#include <cstdlib>
#include "selector_cell_cap.h"
#include "economy_effect_forward.h"
#include "country_runtime.h"
#include "effect_runtime.h"
#include "modifier_runtime.h"
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
    const int32_t family_scoped = family_scoped_output_factor_q16(
        families_store().handle_for_index(family_index));
    factor = factor * family_scoped / Q16_ONE;
    factor = std::clamp<int64_t>(factor, 0, 4 * Q16_ONE);
    return static_cast<int32_t>(factor);
}

int32_t NativeEconomyRuntime::family_scoped_output_factor_q16(
        uint64_t family_handle) const {
    if (_modifier_runtime == nullptr || _family_scoped_output_stat_id < 0 ||
        family_handle == 0)
        return Q16_ONE;
    return static_cast<int32_t>(std::clamp<int64_t>(
        static_cast<int64_t>(std::llround(
            _modifier_runtime->effective_value(ModifierRuntime::ECONOMY,
                _family_scoped_output_stat_id, family_handle, 0, 1.0) *
                Q16_ONE)),
        0, 4 * Q16_ONE));
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

godot::Dictionary NativeEconomyRuntime::building_context_ready_for_test() const {
    godot::Dictionary out;
    const int32_t cells = _cell_count.get();
    out["cells"] = static_cast<int64_t>(cells);
    out["neighbors"] = static_cast<int64_t>(_building_neighbors.size());
    out["neighbors_expected"] = static_cast<int64_t>(cells) * 6;
    out["terrain"] = static_cast<int64_t>(_building_terrain.size());
    out["is_water"] = static_cast<int64_t>(_building_is_water.size());
    out["has_river"] = static_cast<int64_t>(_building_has_river.size());
    // CONTENT, not just sizes. An all -1 neighbour table has the right length and would
    // pass a size-only check, while every radial selector returns "no cells" -- which is
    // exactly the ambiguity this probe exists to remove.
    int64_t valid_neighbors = 0;
    for (const int32_t neighbor : _building_neighbors)
        if (neighbor >= 0 && neighbor < cells) ++valid_neighbors;
    out["valid_neighbors"] = valid_neighbors;
    out["has_any_neighbor"] = valid_neighbors > 0;
    out["ready"] = _building_neighbors.size() == static_cast<size_t>(cells) * 6 &&
        _building_terrain.size() == static_cast<size_t>(cells) &&
        _building_is_water.size() == static_cast<size_t>(cells) &&
        _building_has_river.size() == static_cast<size_t>(cells) &&
        valid_neighbors > 0;
    return out;
}

int32_t NativeEconomyRuntime::cell_country_slot(int32_t cell) const {
    if (cell < 0) return -1;
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

void NativeEconomyRuntime::collect_own_tagged_cells(
        int32_t country_slot, int32_t tag,
        std::vector<int32_t> &out_cells) const {
    out_cells.clear();
    if (country_slot < 0 || tag < 0 || tag >= _target_tags.count()) return;
    const std::shared_ptr<const TagSnapshot> tags_here = tag_snapshot();
    const TagSnapshot *const tags_ptr = tags_here.get();
    if (tags_ptr == nullptr) return;
    const int32_t owned = country_cell_count(country_slot);
    out_cells.reserve(static_cast<size_t>(std::max(0, owned)));
    for (int32_t index = 0; index < owned; ++index) {
        const int32_t cell = country_cell_at(country_slot, index);
        if (cell < 0) continue;
        if (snapshot_has_tag(tags_ptr, cell, tag)) out_cells.push_back(cell);
    }
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
    // R-3b: CONFIG-PHASE OR BOUNDARY-LOCK ONLY. This rebuilds the epoch snapshot,
    // which is the one thing `_published_tag_snapshot_generation` has a single
    // writer for, so two concurrent calls would race the counter and could publish
    // two snapshots carrying the same generation (a reader then reads "unchanged").
    //
    // Legitimate callers:
    //   * `configure_economy` / `configure_effects` at session configuration, before
    //     any epoch or worker thread exists;
    //   * a caller holding `NativeSimulationHost::try_lock_economy_input_capture`,
    //     the same lock `capture_country_epoch` is serialized by.
    // A caller that neither is at configuration nor holds that lock must not call
    // this. The check below cannot test the lock itself (this runtime does not own
    // it), so it makes the offending STATE visible instead: a rebuild already in
    // flight means "this call is concurrent with one", and refusing it here would
    // silently leave the OLD table's bits published -- hence the loud line, not a
    // silent early-out.
    if (_tag_snapshot_building.load(std::memory_order_acquire)) {
        pk::log_error("[economy/tag] set_target_tags while a snapshot rebuild is in "
                      "flight (calls=%llu): the caller must be at configuration or "
                      "hold the economy input capture lock",
                      static_cast<unsigned long long>(tag_snapshot_builds()));
        _tag_snapshot_concurrent_writes.fetch_add(1, std::memory_order_relaxed);
    }
    _target_tags = tags;
    // Any published snapshot was derived from the previous table, so it is stale
    // even if the cell columns have not moved.
    std::atomic_store_explicit(&_tag_snapshot,
        std::shared_ptr<const TagSnapshot>(), std::memory_order_release);
    // Rebuild immediately when the epoch data this table needs is already present.
    //
    // Dropping the pointer and waiting for the next `capture_country_epoch` leaves a
    // window in which every tag query answers "no tags" -- and if the caller attached
    // tags mid-epoch, that window lasts until the NEXT capture, so cards silently stop
    // matching in between. Rebuilding here closes it: the table just changed, the
    // columns it reads are available, so the snapshot can be produced right now.
    //
    // Guarded on the same inputs `rebuild_epoch_tag_snapshot` uses. When the epoch has
    // not captured yet (`_epoch_cell_country` short) there is nothing to build from
    // and the pointer correctly stays null until commit.
    const int32_t cells = _cell_count.get();
    if (cells > 0 && _epoch_cell_country.size() >= static_cast<size_t>(cells))
        rebuild_epoch_tag_snapshot();
}

namespace {
// X7 counted tags. Slot order MUST match FAMILY_METRIC_COUNTRY_*_CELL_COUNT
// ids 56..61 one-for-one: slot i is published as metric (56 + i). Appending a
// tag means appending a metric id in the same commit -- there is no runtime
// mapping between the two lists.
//
// Declared ABOVE `rebuild_epoch_tag_snapshot` (R-3): the snapshot builder fills the
// per-country counts, so it needs this table; the old placement worked only while
// the counts were built by a later function.
struct CountryTagCountSlot {
    const char *tag_name;
};
constexpr CountryTagCountSlot kCountryTagCountSlots[] = {
    {"cell.sector.agriculture"},
    {"cell.sector.extractive"},
    {"cell.sector.manufacturing"},
    {"cell.chained"},
    {"cell.specialized_high"},
    {"cell.market"},
    {"cell.settlement"},
    // Per-good slots. `cell.produces.<good>` is defined as "dominant output good
    // == that good", so these are exactly "how many cells mainly make silver".
    {"cell.produces.silver"},
    {"cell.produces.salt"},
    {"cell.produces.iron_ore"},
    {"cell.produces.coal"},
};
constexpr int32_t kCountryTagCountSlotCount =
    static_cast<int32_t>(sizeof(kCountryTagCountSlots) /
                         sizeof(kCountryTagCountSlots[0]));
} // namespace

void NativeEconomyRuntime::rebuild_epoch_tag_snapshot() {
    // M4: measure before deciding whether a per-tag incremental update is worth
    // building (the "stamp / touched scratch" task). A ScopedTimer so every early
    // return below is still counted.
    struct BuildTimer {
        std::atomic<double> &out_ms;
        std::atomic<int64_t> &out_count;
        std::chrono::steady_clock::time_point start =
            std::chrono::steady_clock::now();
        ~BuildTimer() {
            const double ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start).count();
            out_ms.store(ms, std::memory_order_relaxed);
            out_count.fetch_add(1, std::memory_order_relaxed);
        }
    } build_timer{_last_tag_snapshot_build_ms, _tag_snapshot_build_count};
    // R-3: build ONE immutable snapshot and publish it with a single atomic store.
    //
    // History of this function, because the first "fix" was not one:
    //   1. Originally the tables were built lazily INSIDE const query methods, so the
    //      first reader after an epoch boundary mutated them from whatever thread
    //      queried first.
    //   2. Making the build eager at commit did not remove the race -- it moved the
    //      `clear()` + `assign()` onto the commit thread while the main thread's
    //      `step_ideology_instance_refresh -> reconcile` still iterated the same
    //      vectors. A reader could walk a buffer the writer had just freed.
    //   3. This version never mutates published storage. A fresh TagSnapshot is
    //      allocated, filled, and swapped in atomically; readers keep the old one
    //      alive through their shared_ptr for the duration of their read.
    //   4. R-3b: it also does nothing when nothing reads it. See `tag_snapshot_needed`.
    //
    // SINGLE WRITER (R-3b): this is the only function that assigns
    // `_published_tag_snapshot_generation`, and its two callers are serialized by
    // construction -- `capture_country_epoch` (the epoch owner) and `set_target_tags`
    // (config time, or a caller holding the boundary lock).
    const bool want_bits = tag_bits_needed();
    const bool want_specialized = specialized_good_count_needed();    // "Only one thread builds" (R-3b). A concurrent second caller returns and keeps
    // the previously published snapshot: stale at worst, never torn, and the next
    // epoch rebuilds it. Without this the two callers would race on
    // `_published_tag_snapshot_generation` and could publish two snapshots carrying
    // the same generation, which a reader would read as "nothing changed".
    struct BuildGuard {
        std::atomic<bool> &flag;
        bool owned = false;
        ~BuildGuard() { if (owned) flag.store(false, std::memory_order_release); }
    } build_guard{_tag_snapshot_building};
    {
        bool expected = false;
        if (!_tag_snapshot_building.compare_exchange_strong(expected, true,
                std::memory_order_acq_rel, std::memory_order_acquire)) {
            _tag_snapshot_skips.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        build_guard.owned = true;
    }
    if (!want_bits && !want_specialized) {
        // Nobody consumes either table this epoch, so the per-cell metric sample and
        // the per-country sweep would buy exactly nothing. Drop the stale snapshot
        // rather than leave a previous epoch's bits readable: a consumer set that
        // later asks for tags must not be answered from a generation it never
        // declared, and `tag_snapshot()` reporting a miss is the honest signal.
        std::atomic_store_explicit(&_tag_snapshot,
            std::shared_ptr<const TagSnapshot>(), std::memory_order_release);
        _tag_snapshot_skips.fetch_add(1, std::memory_order_relaxed);
        const std::shared_ptr<const CellTagOverrideSet> overrides =
            std::atomic_load_explicit(&_cell_tag_override_snapshot,
                std::memory_order_acquire);
        _tag_snapshot_override_generation =
            overrides == nullptr ? 0 : overrides->generation;
        return;
    }
    auto snapshot = std::make_shared<TagSnapshot>();
    snapshot->tag_count = want_bits ? _target_tags.count() : 0;
    const int32_t cells = _cell_count.get();
    const int32_t tags = snapshot->tag_count;
    const std::shared_ptr<const CellTagOverrideSet> tag_overrides =
        std::atomic_load_explicit(&_cell_tag_override_snapshot,
            std::memory_order_acquire);
    const uint64_t tag_override_generation =
        tag_overrides == nullptr ? 0 : tag_overrides->generation;

    if (tags > 0 && cells > 0) {
        const int32_t words = (cells + 63) / 64;
        snapshot->tag_words = words;
        snapshot->tag_bits.assign(
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
        // Tags with NO rows can never match: `matches()` returns false immediately
        // (`target_tag.h:203`). Precomputing the active set turns a `cells x tags`
        // sweep into `cells x active_tags`, and the shipped catalogue declares far
        // more tags than any one world's table actually uses.
        // Narrow to the CONSUMED tags (M4-22).
        //
        // `tags_needed` was a bare bool, so a world whose cards read ONE tag still paid
        // `cells x 296` matches -- 35.66 ms at 6400 cells. The consumer set now carries
        // the ids; an EMPTY set with `tags_needed` true means "the publisher could not
        // name them" and is treated as all tags, so a conservative publisher can never
        // silently narrow the target set.
        const std::shared_ptr<const EffectInputConsumers> consumers =
            std::atomic_load_explicit(&_effect_input_consumers,
                std::memory_order_acquire);
        // Test switch: force the "all tags" fallback so the narrowing can be A/B'd
        // with ONE binary. Without a switch the two arms are different builds, and a
        // build-to-build timing comparison confounds the change with the build.
        static const bool force_all_tags = []() {
            const char *value = std::getenv("PK_TAG_FORCE_ALL");
            return value != nullptr && value[0] == '1';
        }();
        const std::vector<int32_t> *consumed =
            (consumers == nullptr || force_all_tags)
                ? nullptr : &consumers->tag_ids;
        std::vector<int32_t> active_tags;
        if (consumed != nullptr && !consumed->empty()) {
            active_tags.reserve(consumed->size());
            for (const int32_t tag : *consumed) {
                if (tag < 0 || tag >= tags) continue;          // stale id
                if (_target_tags.end(tag) <= _target_tags.begin(tag)) continue;
                active_tags.push_back(tag);
            }
        } else {
            active_tags.reserve(static_cast<size_t>(tags));
            for (int32_t tag = 0; tag < tags; ++tag) {
                if (_target_tags.end(tag) > _target_tags.begin(tag))
                    active_tags.push_back(tag);
            }
        }
        _tag_active_tag_count = static_cast<int64_t>(active_tags.size());
        _tag_consumed_tag_count = consumed == nullptr
            ? 0 : static_cast<int64_t>(consumed->size());
        _tag_declared_tag_count = tags;
        const int32_t active = static_cast<int32_t>(active_tags.size());
        for (int32_t cell = 0; cell < cells; ++cell) {
            sample_effect_metrics(cell, metric_count, values.data(), mask);
            const size_t word = static_cast<size_t>(cell / 64);
            const uint64_t bit = uint64_t{1} << (cell % 64);
            const std::vector<CellTagOverride> *cell_overrides = nullptr;
            if (tag_overrides != nullptr) {
                const auto override_it = tag_overrides->cells.find(cell);
                if (override_it != tag_overrides->cells.end())
                    cell_overrides = &override_it->second;
            }
            for (int32_t index = 0; index < active; ++index) {
                const int32_t tag = active_tags[static_cast<size_t>(index)];
                bool matches =
                    _target_tags.matches(tag, values.data(), metric_count);
                if (cell_overrides != nullptr &&
                        tag < static_cast<int32_t>(
                            cell_overrides->size())) {
                    const CellTagOverride &override =
                        (*cell_overrides)[static_cast<size_t>(tag)];
                    if (override.force_true != 0)
                        matches = true;
                    else if (override.force_false != 0)
                        matches = false;
                }
                if (!matches) continue;
                snapshot->tag_bits[static_cast<size_t>(tag) *
                                       static_cast<size_t>(words) + word] |= bit;
            }
        }
    }

    // X7 counts are derived from the SAME bits, into the same snapshot, so a reader
    // can never see bits from one epoch beside counts from another.
    if (snapshot->tag_words > 0 && cells > 0 &&
        _epoch_cell_country.size() >= static_cast<size_t>(cells)) {
        int32_t countries = _epoch_country_count;
        for (int32_t cell = 0; cell < cells; ++cell) {
            const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
            if (country >= countries) countries = country + 1;
        }
        if (countries > 0) {
            int32_t tag_index[kCountryTagCountSlotCount];
            for (int32_t slot = 0; slot < kCountryTagCountSlotCount; ++slot) {
                tag_index[slot] = -1;
                const std::string wanted = kCountryTagCountSlots[slot].tag_name;
                for (int32_t tag = 0; tag < tags; ++tag) {
                    if (_target_tags.names[static_cast<size_t>(tag)] == wanted) {
                        tag_index[slot] = tag;
                        break;
                    }
                }
            }
            snapshot->country_count = countries;
            snapshot->country_tag_counts.assign(
                static_cast<size_t>(countries) *
                    static_cast<size_t>(kCountryTagCountSlotCount), 0);
            for (int32_t cell = 0; cell < cells; ++cell) {
                const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
                if (country < 0 || country >= countries) continue;
                const size_t word = static_cast<size_t>(cell / 64);
                const uint64_t bit = uint64_t{1} << (cell % 64);
                const size_t row = static_cast<size_t>(country) *
                    static_cast<size_t>(kCountryTagCountSlotCount);
                for (int32_t slot = 0; slot < kCountryTagCountSlotCount; ++slot) {
                    const int32_t tag = tag_index[slot];
                    if (tag < 0) continue;
                    const size_t index = static_cast<size_t>(tag) *
                        static_cast<size_t>(snapshot->tag_words) + word;
                    if (index >= snapshot->tag_bits.size()) continue;
                    if ((snapshot->tag_bits[index] & bit) == 0) continue;
                    ++snapshot->country_tag_counts[row + static_cast<size_t>(slot)];
                }
            }
        }
    }

    // X7b (metric 67): distinct specialized goods per country, in the SAME snapshot.
    //
    // Moved here from `ensure_country_specialized_goods()` (R-3). That was the worst
    // of the lazy builds: a const getter that sampled per-cell metrics and grew a
    // vector-of-vectors while the epoch columns could be moving underneath it.
    // Computing it with the tag bits keeps one epoch's answer in one object.
    //
    // R-3b: gated on its OWN consumer flag. Metric 67 reads no tag table, so a
    // catalog that declares the metric but no tags still gets its counts, and a
    // catalog that declares tags but not the metric no longer pays for this pass.
    if (want_specialized && cells > 0 &&
        _epoch_cell_country.size() >= static_cast<size_t>(cells)) {
        int32_t countries = _epoch_country_count;
        for (int32_t cell = 0; cell < cells; ++cell) {
            const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
            if (country >= countries) countries = country + 1;
        }
        if (countries > 0) {
            std::vector<std::vector<uint32_t>> specialized_bits(
                static_cast<size_t>(countries));
            MetricMask mask;
            mask.set(FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID);
            mask.set(FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16);
            std::vector<int64_t> values(static_cast<size_t>(FAMILY_METRIC_COUNT), 0);
            const int64_t specialized_share = Q16_ONE * 60 / 100;
            for (int32_t cell = 0; cell < cells; ++cell) {
                const int32_t country =
                    _epoch_cell_country[static_cast<size_t>(cell)];
                if (country < 0 || country >= countries) continue;
                sample_effect_metrics(cell, FAMILY_METRIC_COUNT, values.data(),
                                      mask);
                const int64_t good_q16 =
                    values[FAMILY_METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID];
                if (good_q16 < 0) continue;
                if (values[FAMILY_METRIC_CELL_TOP_OUTPUT_GOOD_SHARE_Q16] <
                        specialized_share)
                    continue;
                const int32_t good = static_cast<int32_t>(good_q16 / Q16_ONE);
                if (good < 0) continue;
                std::vector<uint32_t> &bits =
                    specialized_bits[static_cast<size_t>(country)];
                const size_t word = static_cast<size_t>(good / 32);
                if (bits.size() <= word) bits.resize(word + 1u, 0u);
                bits[word] |= uint32_t{1} << (good % 32);
            }
            snapshot->country_specialized_good_count.assign(
                static_cast<size_t>(countries), 0);
            for (int32_t country = 0; country < countries; ++country) {
                int32_t distinct = 0;
                for (const uint32_t word :
                        specialized_bits[static_cast<size_t>(country)]) {
                    uint32_t remaining = word;
                    while (remaining != 0) {
                        remaining &= remaining - 1u;
                        ++distinct;
                    }
                }
                snapshot->country_specialized_good_count[
                    static_cast<size_t>(country)] = distinct;
            }
        }
    }

    snapshot->generation = _published_tag_snapshot_generation + 1u;
    _published_tag_snapshot_generation = snapshot->generation;
    // The single mutation of published state: swap the pointer.
    std::atomic_store_explicit(&_tag_snapshot,
        std::shared_ptr<const TagSnapshot>(std::move(snapshot)),
        std::memory_order_release);
    _tag_snapshot_builds.fetch_add(1, std::memory_order_relaxed);
    _tag_snapshot_override_generation = tag_override_generation;
}

void NativeEconomyRuntime::rebuild_epoch_geo_columns() {
    const int32_t cells = _cell_count.get();
    if (cells <= 0 || _epoch_cell_country.size() != static_cast<size_t>(cells) ||
        _building_neighbors.size() != static_cast<size_t>(cells) * 6 ||
        _building_is_water.size() != static_cast<size_t>(cells) ||
        _building_has_river.size() != static_cast<size_t>(cells)) {
        _epoch_cell_geo_flags.clear();
        _epoch_cell_waterway_component_size.clear();
        return;
    }
    const uint64_t canal_hash = canal_topology_hash();
    if (!_epoch_cell_geo_flags.empty() &&
        _geo_flags_territory_hash == _epoch_country_topology_hash &&
        _geo_flags_canal_hash == canal_hash) {
        return;
    }

    _epoch_cell_geo_flags.assign(static_cast<size_t>(cells), 0);
    _epoch_cell_waterway_component_size.assign(static_cast<size_t>(cells), 0);
    const bool have_canal_mask =
        _trade_topology.canal_edge_mask.size() == static_cast<size_t>(cells);
    for (int32_t cell = 0; cell < cells; ++cell) {
        int32_t flags = _building_has_river[static_cast<size_t>(cell)] != 0 ? 1 : 0;
        const bool own_water = _building_is_water[static_cast<size_t>(cell)] != 0;
        if (have_canal_mask &&
            _trade_topology.canal_edge_mask[static_cast<size_t>(cell)] != 0) {
            flags |= 4;
        }
        const int32_t owner = _epoch_cell_country[static_cast<size_t>(cell)];
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _building_neighbors[
                static_cast<size_t>(cell) * 6 + static_cast<size_t>(direction)];
            if (neighbor < 0 || neighbor >= cells) continue;
            if (_building_is_water[static_cast<size_t>(neighbor)] != 0)
                flags |= 2;
            const int32_t neighbor_owner =
                _epoch_cell_country[static_cast<size_t>(neighbor)];
            if (!own_water &&
                _building_is_water[static_cast<size_t>(neighbor)] == 0 &&
                owner >= 0 && neighbor_owner >= 0 && owner != neighbor_owner) {
                flags |= 8;
            }
        }
        _epoch_cell_geo_flags[static_cast<size_t>(cell)] = flags;
    }

    // Connected component over river/canal land cells of the same territory.
    // Owner -1 is one bucket; component size is per cell rather than a global id
    // because no X12 card consumes basin ids. Water cells are excluded on both
    // sides of the traversal: the contract says metric 76 is zero on water.
    std::vector<uint8_t> visited(static_cast<size_t>(cells), 0);
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(cells));
    for (int32_t start = 0; start < cells; ++start) {
        if (_building_is_water[static_cast<size_t>(start)] != 0) continue;
        const bool waterway =
            (_epoch_cell_geo_flags[static_cast<size_t>(start)] & 5) != 0;
        if (!waterway || visited[static_cast<size_t>(start)] != 0) continue;
        const int32_t owner = _epoch_cell_country[static_cast<size_t>(start)];
        queue.clear();
        queue.push_back(start);
        visited[static_cast<size_t>(start)] = 1;
        for (size_t cursor = 0; cursor < queue.size(); ++cursor) {
            const int32_t cell = queue[cursor];
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 + static_cast<size_t>(direction)];
                if (neighbor < 0 || neighbor >= cells ||
                    visited[static_cast<size_t>(neighbor)] != 0) continue;
                if (_building_is_water[static_cast<size_t>(neighbor)] != 0) continue;
                if ((_epoch_cell_geo_flags[static_cast<size_t>(neighbor)] & 5) == 0 ||
                    _epoch_cell_country[static_cast<size_t>(neighbor)] != owner)
                    continue;
                visited[static_cast<size_t>(neighbor)] = 1;
                queue.push_back(neighbor);
            }
        }
        const int32_t component_size = static_cast<int32_t>(queue.size());
        for (const int32_t cell : queue)
            _epoch_cell_waterway_component_size[static_cast<size_t>(cell)] =
                component_size;
    }
    _geo_flags_territory_hash = _epoch_country_topology_hash;
    _geo_flags_canal_hash = canal_hash;
    _geo_flags_rebuilds.fetch_add(1, std::memory_order_relaxed);
}

bool NativeEconomyRuntime::rebuild_epoch_family_cell_metrics() {
    const auto &influences = family_influences();
    uint64_t signature = 1469598103934665603ULL;
    const auto mix = [&](uint64_t value) {
        signature ^= value;
        signature *= 1099511628211ULL;
    };
    mix(static_cast<uint64_t>(influences.active.size()));
    mix(influences.active.mutation_revision());
    mix(influences.family_handle.mutation_revision());
    mix(influences.cell.mutation_revision());
    mix(influences.building_share_q16.mutation_revision());
    mix(influences.score_q16.mutation_revision());
    if (signature == _family_cell_metric_signature &&
        _epoch_cell_family_branch_count.size() ==
            static_cast<size_t>(_cell_count.get()))
        return false;

    const int32_t cells = _cell_count.get();
    std::vector<int32_t> branch_count(static_cast<size_t>(std::max(0, cells)), 0);
    std::vector<int64_t> max_prestige(static_cast<size_t>(std::max(0, cells)), 0);
    std::vector<int32_t> max_asset_share(
        static_cast<size_t>(std::max(0, cells)), 0);
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            influences.active.size()); ++branch) {
        if (influences.active[branch] == 0) continue;
        const int32_t cell = influences.cell[branch];
        if (cell < 0 || cell >= cells) continue;
        ++branch_count[static_cast<size_t>(cell)];
        max_prestige[static_cast<size_t>(cell)] = std::max<int64_t>(
            max_prestige[static_cast<size_t>(cell)],
            influences.score_q16[branch]);
        max_asset_share[static_cast<size_t>(cell)] = std::max<int32_t>(
            max_asset_share[static_cast<size_t>(cell)],
            influences.building_share_q16[branch]);
    }
    _family_cell_metric_changed_cells.assign(
        static_cast<size_t>(std::max(0, cells)), 0);
    for (int32_t cell = 0; cell < cells; ++cell) {
        const size_t slot = static_cast<size_t>(cell);
        if ((cell < static_cast<int32_t>(_epoch_cell_family_branch_count.size()) &&
                _epoch_cell_family_branch_count[slot] != branch_count[slot]) ||
            (cell < static_cast<int32_t>(
                _epoch_cell_max_branch_prestige_q16.size()) &&
                _epoch_cell_max_branch_prestige_q16[slot] != max_prestige[slot]) ||
            (cell < static_cast<int32_t>(
                _epoch_cell_family_asset_share_q16.size()) &&
                _epoch_cell_family_asset_share_q16[slot] != max_asset_share[slot]))
            _family_cell_metric_changed_cells[slot] = 1;
    }
    _epoch_cell_family_branch_count = std::move(branch_count);
    _epoch_cell_max_branch_prestige_q16 = std::move(max_prestige);
    _epoch_cell_family_asset_share_q16 = std::move(max_asset_share);
    _family_cell_metric_signature = signature;
    _family_cell_metric_rebuilds.fetch_add(1, std::memory_order_relaxed);
    return true;
}

bool NativeEconomyRuntime::rebuild_epoch_family_country_metrics() {
    const auto &families = families_store();
    const auto &influences = family_influences();
    uint64_t signature = 1469598103934665603ULL;
    const auto mix = [&](uint64_t value) {
        signature ^= value;
        signature *= 1099511628211ULL;
    };
    mix(families.active.size());
    mix(families.active.mutation_revision());
    mix(families.founded_day.mutation_revision());
    mix(families.home_cell.mutation_revision());
    mix(families.origin_cell.mutation_revision());
    mix(influences.active.size());
    mix(influences.active.mutation_revision());
    mix(influences.family_handle.mutation_revision());
    mix(influences.cell.mutation_revision());
    mix(_epoch_country_topology_hash);
    if (signature == _family_country_metric_signature &&
        _epoch_country_family_remote_branch_count.size() ==
            static_cast<size_t>(std::max(0, _epoch_country_count)))
        return false;

    const int32_t countries = std::max(0, _epoch_country_count);
    std::vector<int32_t> branches_by_family(
        static_cast<size_t>(std::max(0, static_cast<int32_t>(
            families.active.size()))), 0);
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            influences.active.size()); ++branch) {
        if (influences.active[branch] == 0) continue;
        int32_t family = -1;
        if (!families.valid_handle(influences.family_handle[branch], family) ||
            family < 0 || family >= static_cast<int32_t>(branches_by_family.size()))
            continue;
        ++branches_by_family[static_cast<size_t>(family)];
    }

    std::vector<int32_t> family_country(
        families.active.size(), -1);
    std::vector<int32_t> remote(
        static_cast<size_t>(countries), 0);
    std::vector<int32_t> large_families(
        static_cast<size_t>(countries), 0);
    std::vector<int64_t> oldest_founded(
        static_cast<size_t>(countries), std::numeric_limits<int64_t>::max());
    std::vector<int64_t> founded_sum(
        static_cast<size_t>(countries), 0);
    std::vector<int32_t> family_count(
        static_cast<size_t>(countries), 0);
    for (int32_t family = 0; family < static_cast<int32_t>(
            families.active.size()); ++family) {
        if (families.active[family] == 0) continue;
        const int32_t country = cell_country_slot(families.home_cell[family]);
        if (country < 0 || country >= countries) continue;
        family_country[static_cast<size_t>(family)] = country;
        if (branches_by_family[static_cast<size_t>(family)] >= 3)
            ++large_families[static_cast<size_t>(country)];
        oldest_founded[static_cast<size_t>(country)] = std::min<int64_t>(
            oldest_founded[static_cast<size_t>(country)],
            families.founded_day[family]);
        founded_sum[static_cast<size_t>(country)] +=
            families.founded_day[family];
        ++family_count[static_cast<size_t>(country)];
    }

    // "Remote" means at least five hex steps from the family's ancestral
    // origin, not merely away from its current home cell. BFS only four rings
    // and counts a branch as remote when its cell was not reached. A family
    // whose origin is invalid contributes no remote evidence.
    const int32_t cells = std::max(0, _cell_count.get());
    std::vector<int32_t> distance(
        static_cast<size_t>(cells), std::numeric_limits<int32_t>::max());
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(cells));
    for (int32_t family = 0; family < static_cast<int32_t>(
            families.active.size()); ++family) {
        if (families.active[family] == 0) continue;
        const int32_t country = family_country[static_cast<size_t>(family)];
        if (country < 0) continue;
        const int32_t origin = families.origin_cell[family];
        if (origin < 0 || origin >= cells ||
                _building_neighbors.size() !=
                    static_cast<size_t>(cells) * 6)
            continue;
        std::fill(distance.begin(), distance.end(),
            std::numeric_limits<int32_t>::max());
        queue.clear();
        distance[static_cast<size_t>(origin)] = 0;
        queue.push_back(origin);
        for (size_t head = 0; head < queue.size(); ++head) {
            const int32_t cell = queue[head];
            const int32_t next_distance = distance[
                static_cast<size_t>(cell)] + 1;
            if (next_distance > 4) continue;
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _building_neighbors[
                    static_cast<size_t>(cell) * 6 +
                    static_cast<size_t>(direction)];
                if (neighbor < 0 || neighbor >= cells ||
                        distance[static_cast<size_t>(neighbor)] !=
                            std::numeric_limits<int32_t>::max())
                    continue;
                distance[static_cast<size_t>(neighbor)] = next_distance;
                queue.push_back(neighbor);
            }
        }
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                influences.active.size()); ++branch) {
            if (influences.active[branch] == 0) continue;
            int32_t branch_family = -1;
            if (!families.valid_handle(
                    influences.family_handle[branch], branch_family) ||
                    branch_family != family)
                continue;
            const int32_t branch_cell = influences.cell[branch];
            if (branch_cell < 0 || branch_cell >= cells)
                continue;
            if (distance[static_cast<size_t>(branch_cell)] ==
                    std::numeric_limits<int32_t>::max())
                ++remote[static_cast<size_t>(country)];
        }
    }

    std::vector<uint8_t> changed(
        static_cast<size_t>(countries), 0);
    const auto column_changed = [&](const auto &old_values,
                                    const auto &new_values) {
        for (int32_t country = 0; country < countries; ++country) {
            const size_t slot = static_cast<size_t>(country);
            if (slot >= old_values.size() || old_values[slot] != new_values[slot])
                changed[slot] = 1;
        }
    };
    column_changed(_epoch_country_family_remote_branch_count, remote);
    column_changed(_epoch_country_families_with_at_least_3_branches,
        large_families);
    column_changed(_epoch_country_oldest_family_founded_day, oldest_founded);
    column_changed(_epoch_country_family_founded_day_sum, founded_sum);
    column_changed(_epoch_country_family_count, family_count);
    _epoch_country_family_remote_branch_count = std::move(remote);
    _epoch_country_families_with_at_least_3_branches =
        std::move(large_families);
    _epoch_country_oldest_family_founded_day = std::move(oldest_founded);
    _epoch_country_family_founded_day_sum = std::move(founded_sum);
    _epoch_country_family_count = std::move(family_count);
    _family_country_metric_changed_countries = std::move(changed);
    _family_country_metric_signature = signature;
    _family_country_metric_rebuilds.fetch_add(1, std::memory_order_relaxed);
    return true;
}

void NativeEconomyRuntime::refresh_class_opinion_metrics() {
    const CountryClassOpinionSnapshot &snapshot = country_class_opinion_snapshot();
    const std::vector<int64_t> &source_population =
        _class_opinion_source_override_enabled
        ? _class_opinion_override_population : snapshot.population;
    const std::vector<int32_t> &source_satisfaction_q16 =
        _class_opinion_source_override_enabled
        ? _class_opinion_override_satisfaction_q16 : snapshot.satisfaction_q16;
    const std::vector<int64_t> &source_satisfaction_weighted =
        _class_opinion_source_override_enabled
        ? _class_opinion_override_weighted : snapshot.satisfaction_weighted;
    const int32_t country_count = std::max(0, _epoch_country_count);
    auto source_hash = [&]() {
        uint64_t hash = 1469598103934665603ULL;
        auto mix = [](uint64_t value_hash, uint64_t value) {
            value_hash ^= value;
            value_hash *= 1099511628211ULL;
            return value_hash;
        };
        hash = mix(hash, static_cast<uint64_t>(snapshot.country_count));
        hash = mix(hash, static_cast<uint64_t>(snapshot.class_count));
        for (const int64_t value : source_population)
            hash = mix(hash, static_cast<uint64_t>(value));
        for (const int32_t value : source_satisfaction_q16)
            hash = mix(hash, static_cast<uint32_t>(value));
        for (const int64_t value : source_satisfaction_weighted)
            hash = mix(hash, static_cast<uint64_t>(value));
        return hash;
    }();
    if (source_hash == _class_metric_source_content_hash &&
        static_cast<int32_t>(_epoch_country_weighted_satisfaction_q16.size()) ==
            country_count &&
        static_cast<int32_t>(_epoch_country_farmer_satisfaction_q16.size()) ==
            country_count &&
        static_cast<int32_t>(_epoch_country_worker_satisfaction_q16.size()) ==
            country_count)
        return;
    std::vector<int64_t> class_values(
        static_cast<size_t>(country_count), 0);
    std::vector<int64_t> weighted_values(
        static_cast<size_t>(country_count), 0);
    std::vector<int64_t> farmer_values(
        static_cast<size_t>(country_count), 0);
    std::vector<int64_t> worker_values(
        static_cast<size_t>(country_count), 0);
    // The catalog has four classes (farmer, general, technology, worker) in
    // sorted order. Each copied row owns its own validity check: a fixture with
    // fewer classes must still publish the rows it does have instead of
    // zeroing all three.
    const int32_t general_class = [&]() {
        const auto found = std::lower_bound(_political_class_ids.begin(),
            _political_class_ids.end(), std::string("general"));
        return found != _political_class_ids.end() && *found == "general"
            ? static_cast<int32_t>(found - _political_class_ids.begin()) : -1;
    }();
    const int32_t farmer_class = [&]() {
        const auto found = std::lower_bound(_political_class_ids.begin(),
            _political_class_ids.end(), std::string("farmer"));
        return found != _political_class_ids.end() && *found == "farmer"
            ? static_cast<int32_t>(found - _political_class_ids.begin()) : -1;
    }();
    const int32_t worker_class = [&]() {
        const auto found = std::lower_bound(_political_class_ids.begin(),
            _political_class_ids.end(), std::string("worker"));
        return found != _political_class_ids.end() && *found == "worker"
            ? static_cast<int32_t>(found - _political_class_ids.begin()) : -1;
    }();
    const int64_t snapshot_row_count =
        static_cast<int64_t>(snapshot.country_count) * snapshot.class_count;
    const bool class_rows_valid =
        static_cast<int64_t>(source_satisfaction_q16.size()) == snapshot_row_count &&
        static_cast<int64_t>(source_population.size()) == snapshot_row_count &&
        static_cast<int64_t>(source_satisfaction_weighted.size()) ==
            snapshot_row_count;
    if (class_rows_valid) {
        for (int32_t country = 0; country < country_count; ++country) {
            if (country >= snapshot.country_count) break;
            const size_t row_base = static_cast<size_t>(country) *
                static_cast<size_t>(snapshot.class_count);
            if (general_class >= 0)
                class_values[static_cast<size_t>(country)] =
                    source_satisfaction_q16[row_base +
                        static_cast<size_t>(general_class)];
            if (farmer_class >= 0)
                farmer_values[static_cast<size_t>(country)] =
                    source_satisfaction_q16[row_base +
                        static_cast<size_t>(farmer_class)];
            if (worker_class >= 0)
                worker_values[static_cast<size_t>(country)] =
                    source_satisfaction_q16[row_base +
                        static_cast<size_t>(worker_class)];
        }
    }
    // The committed snapshot has no influence column. Population is the honest
    // v1 weight available in Economy; ideology's influence weight is not read
    // across the authority boundary. Both values are Q16 ratios.
    for (int32_t country = 0; country < country_count; ++country) {
        if (country >= snapshot.country_count) break;
        int64_t country_population = 0;
        int64_t country_weighted = 0;
        for (int32_t political_class = 0;
             political_class < snapshot.class_count; ++political_class) {
            const size_t row = static_cast<size_t>(country) *
                static_cast<size_t>(snapshot.class_count) +
                static_cast<size_t>(political_class);
            if (row >= source_population.size() ||
                row >= source_satisfaction_weighted.size())
                break;
            country_population = saturating_add(country_population,
                std::max<int64_t>(0, source_population[row]),
                _saturation_count);
            country_weighted = saturating_add(country_weighted,
                std::max<int64_t>(0, source_satisfaction_weighted[row]),
                _saturation_count);
        }
        if (country_population > 0)
            weighted_values[static_cast<size_t>(country)] =
                std::clamp<int64_t>(
                    country_weighted / country_population, 0, Q16_ONE);
    }
    const bool changed =
        class_values != _epoch_country_class_satisfaction_q16 ||
        weighted_values != _epoch_country_weighted_satisfaction_q16 ||
        farmer_values != _epoch_country_farmer_satisfaction_q16 ||
        worker_values != _epoch_country_worker_satisfaction_q16;
    _epoch_country_class_satisfaction_q16 = std::move(class_values);
    _epoch_country_weighted_satisfaction_q16 = std::move(weighted_values);
    _epoch_country_farmer_satisfaction_q16 = std::move(farmer_values);
    _epoch_country_worker_satisfaction_q16 = std::move(worker_values);
    _class_metric_source_revision = snapshot.revision;
    _class_metric_source_content_hash = source_hash;
    _class_metric_source_epoch_day = snapshot.epoch_day;
    if (changed) _class_metric_rebuilds.fetch_add(1, std::memory_order_relaxed);
}

void NativeEconomyRuntime::refresh_technology_metrics() {
    const int32_t country_count = std::max(0, _epoch_country_count);
    const int32_t words = std::max(0, _epoch_country_technology_words);
    const auto popcount = [](uint64_t value) {
        int32_t count = 0;
        while (value != 0) {
            value &= value - 1;
            ++count;
        }
        return count;
    };
    uint64_t source_hash = 1469598103934665603ULL;
    auto mix = [](uint64_t hash, uint64_t value) {
        hash ^= value;
        hash *= 1099511628211ULL;
        return hash;
    };
    source_hash = mix(source_hash, static_cast<uint64_t>(country_count));
    source_hash = mix(source_hash, static_cast<uint64_t>(words));
    const size_t expected_words = static_cast<size_t>(country_count) *
        static_cast<size_t>(words);
    for (size_t word = 0;
         word < expected_words && word < _epoch_country_technologies.size();
         ++word) {
        source_hash = mix(source_hash, _epoch_country_technologies[word]);
    }
    if (source_hash == _technology_metric_source_hash &&
        static_cast<int32_t>(_epoch_country_completed_tech_count.size()) ==
            country_count)
        return;
    std::vector<int64_t> total(
        static_cast<size_t>(country_count), 0);
    std::vector<int64_t> domain_counts(
        static_cast<size_t>(country_count) * 4, 0);
    for (int32_t country = 0; country < country_count; ++country) {
        int64_t country_total = 0;
        for (int32_t word = 0; word < words; ++word) {
            const size_t index =
                static_cast<size_t>(country) * static_cast<size_t>(words) +
                static_cast<size_t>(word);
            if (index >= _epoch_country_technologies.size()) break;
            const uint64_t bits = _epoch_country_technologies[index];
            country_total += popcount(bits);
            for (size_t domain = 0; domain < 4; ++domain) {
                const size_t mask_index =
                    domain * static_cast<size_t>(words) +
                    static_cast<size_t>(word);
                if (mask_index >= _technology_domain_masks.size()) continue;
                const uint64_t domain_bits =
                    bits & _technology_domain_masks[mask_index];
                domain_counts[static_cast<size_t>(country) * 4 + domain] +=
                    popcount(domain_bits);
            }
        }
        total[static_cast<size_t>(country)] = country_total;
    }
    std::vector<int64_t> domain_0(static_cast<size_t>(country_count), 0);
    std::vector<int64_t> domain_1(static_cast<size_t>(country_count), 0);
    std::vector<int64_t> domain_2(static_cast<size_t>(country_count), 0);
    std::vector<int64_t> domain_3(static_cast<size_t>(country_count), 0);
    for (int32_t country = 0; country < country_count; ++country) {
        const size_t row = static_cast<size_t>(country) * 4;
        domain_0[static_cast<size_t>(country)] = domain_counts[row];
        domain_1[static_cast<size_t>(country)] = domain_counts[row + 1];
        domain_2[static_cast<size_t>(country)] = domain_counts[row + 2];
        domain_3[static_cast<size_t>(country)] = domain_counts[row + 3];
    }
    const bool changed =
        total != _epoch_country_completed_tech_count ||
        domain_0 != _epoch_country_completed_tech_count_domain_0 ||
        domain_1 != _epoch_country_completed_tech_count_domain_1 ||
        domain_2 != _epoch_country_completed_tech_count_domain_2 ||
        domain_3 != _epoch_country_completed_tech_count_domain_3;
    _epoch_country_completed_tech_count = std::move(total);
    _epoch_country_completed_tech_count_domain_0 = std::move(domain_0);
    _epoch_country_completed_tech_count_domain_1 = std::move(domain_1);
    _epoch_country_completed_tech_count_domain_2 = std::move(domain_2);
    _epoch_country_completed_tech_count_domain_3 = std::move(domain_3);
    _technology_metric_source_hash = source_hash;
    if (changed)
        _technology_metric_rebuilds.fetch_add(1, std::memory_order_relaxed);
}

void NativeEconomyRuntime::refresh_neighbor_distinct_goods_metrics() {
    const int32_t cells = _cell_count.get();
    if (cells <= 0 ||
        _building_cell_offsets.size() != static_cast<size_t>(cells) + 1 ||
        _building_neighbors.size() != static_cast<size_t>(cells) * 6) {
        if (!_epoch_cell_neighbor_distinct_goods.empty()) {
            _epoch_cell_neighbor_distinct_goods.clear();
            _neighbor_distinct_goods_source_hash = 0;
            _neighbor_distinct_goods_rebuilds.fetch_add(
                1, std::memory_order_relaxed);
        }
        return;
    }

    uint64_t source_hash = 1469598103934665603ULL;
    const auto mix = [](uint64_t hash, uint64_t value) {
        hash ^= value;
        hash *= 1099511628211ULL;
        return hash;
    };
    source_hash = mix(source_hash, static_cast<uint64_t>(cells));
    for (size_t index = 0; index < _building_cell_offsets.size(); ++index) {
        source_hash = mix(source_hash,
            static_cast<uint64_t>(_building_cell_offsets[index]));
    }
    for (const int32_t neighbor : _building_neighbors) {
        source_hash = mix(source_hash,
            static_cast<uint64_t>(static_cast<uint32_t>(neighbor)));
    }
    // Hash the metric's actual inputs, not raw production magnitudes. A stable
    // mine can report a different last_output every day while still dominating
    // the same good; rebuilding 87 in that case would make the idle contract
    // depend on price noise. dominant_output_good_at() resolves ties and output
    // shares, so two equal dominant ids guarantee the distinct-neighbour answer
    // is unchanged.
    for (int32_t cell = 0; cell < cells; ++cell) {
        int32_t share_q16 = 0;
        const int32_t good = dominant_output_good_at(cell, share_q16);
        source_hash = mix(source_hash,
            static_cast<uint64_t>(static_cast<uint32_t>(good + 1)));
    }
    if (source_hash == _neighbor_distinct_goods_source_hash &&
        _epoch_cell_neighbor_distinct_goods.size() ==
            static_cast<size_t>(cells))
        return;

    std::vector<int32_t> counts(static_cast<size_t>(cells), 0);
    for (int32_t cell = 0; cell < cells; ++cell) {
        int32_t distinct[6] = {-1, -1, -1, -1, -1, -1};
        int32_t distinct_count = 0;
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _building_neighbors[
                static_cast<size_t>(cell) * 6 +
                static_cast<size_t>(direction)];
            if (neighbor < 0 || neighbor >= cells) continue;
            int32_t share_q16 = 0;
            const int32_t good = dominant_output_good_at(
                neighbor, share_q16);
            if (good < 0) continue;
            bool duplicate = false;
            for (int32_t slot = 0; slot < distinct_count; ++slot) {
                if (distinct[slot] == good) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) distinct[distinct_count++] = good;
        }
        counts[static_cast<size_t>(cell)] = distinct_count;
    }
    _neighbor_distinct_goods_rebuilds.fetch_add(
        1, std::memory_order_relaxed);
    _epoch_cell_neighbor_distinct_goods = std::move(counts);
    _neighbor_distinct_goods_source_hash = source_hash;
}

void NativeEconomyRuntime::set_epoch_country_technologies_for_test(
        const std::vector<uint64_t> &bits) {
    _epoch_country_technologies = bits;
    _technology_metric_input_override = bits;
    _technology_metric_input_override_enabled = true;
    refresh_technology_metrics();
}

void NativeEconomyRuntime::clear_epoch_country_technologies_for_test() {
    _technology_metric_input_override.clear();
    _technology_metric_input_override_enabled = false;
    refresh_technology_metrics();
}

void NativeEconomyRuntime::set_class_opinion_source_override_for_test(
        const std::vector<int64_t> &population,
        const std::vector<int32_t> &satisfaction_q16,
        const std::vector<int64_t> &satisfaction_weighted) {
    _class_opinion_override_population = population;
    _class_opinion_override_satisfaction_q16 = satisfaction_q16;
    _class_opinion_override_weighted = satisfaction_weighted;
    const CountryClassOpinionSnapshot &committed =
        country_class_opinion_snapshot();
    _class_opinion_override_revision = std::max(
        _class_opinion_override_revision + 1u, committed.revision + 1u);
    _class_opinion_override_commit_day = std::max(
        _class_opinion_override_commit_day + 1, committed.commit_day + 1);
    _class_opinion_source_override_enabled = true;
}

bool NativeEconomyRuntime::class_opinion_source_override_enabled_for_test() const {
    return _class_opinion_source_override_enabled;
}

NativeEconomyRuntime::CountryClassOpinionSnapshot
NativeEconomyRuntime::country_class_opinion_source_snapshot() const {
    CountryClassOpinionSnapshot out = country_class_opinion_snapshot();
    if (!_class_opinion_source_override_enabled)
        return out;
    const size_t rows = static_cast<size_t>(std::max(0, out.country_count)) *
        static_cast<size_t>(std::max(0, out.class_count));
    if (_class_opinion_override_population.size() != rows ||
        _class_opinion_override_satisfaction_q16.size() != rows ||
        _class_opinion_override_weighted.size() != rows ||
        out.country_population.size() !=
            static_cast<size_t>(std::max(0, out.country_count)))
        return out;
    out.population = _class_opinion_override_population;
    out.satisfaction_q16 = _class_opinion_override_satisfaction_q16;
    out.satisfaction_weighted = _class_opinion_override_weighted;
    out.revision = _class_opinion_override_revision;
    out.commit_day = _class_opinion_override_commit_day;
    out.period_index = out.commit_day / std::max<int64_t>(1, out.period_days);
    // Ideology accrues against the country total, not the published live total.
    // Recompute it from the same overridden rows so the worker and class metrics
    // cannot disagree about the population delta.
    std::fill(out.country_population.begin(), out.country_population.end(), 0);
    int64_t saturation_count = 0;
    for (int32_t country = 0; country < out.country_count; ++country) {
        for (int32_t political_class = 0;
             political_class < out.class_count; ++political_class) {
            const size_t row = static_cast<size_t>(country) *
                static_cast<size_t>(out.class_count) +
                static_cast<size_t>(political_class);
            out.country_population[static_cast<size_t>(country)] =
                saturating_add(
                    out.country_population[static_cast<size_t>(country)],
                    std::max<int64_t>(0, out.population[row]),
                    saturation_count);
        }
    }
    return out;
}

void NativeEconomyRuntime::clear_class_opinion_source_override_for_test() {
    _class_opinion_override_population.clear();
    _class_opinion_override_satisfaction_q16.clear();
    _class_opinion_override_weighted.clear();
    _class_opinion_source_override_enabled = false;
}

namespace {
inline uint64_t effect_input_mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}
} // namespace

void NativeEconomyRuntime::set_effect_input_consumers(
        const MetricMask &cell_metrics, bool tags_needed, bool families_needed,
        const std::array<std::vector<int64_t>, FAMILY_METRIC_COUNT>
            &metric_thresholds,
        const std::vector<int32_t> &tag_ids) {
    const std::shared_ptr<const EffectInputConsumers> previous =
        std::atomic_load_explicit(&_effect_input_consumers,
            std::memory_order_acquire);
    // Republishing the same consumer set must NOT create a new generation: the
    // caller re-publishes on every configure, and a fresh generation resets the
    // per-metric published digests, which would bump every metric on every pass.
    if (previous != nullptr &&
            previous->metric_mask == cell_metrics &&
            previous->tags_needed == tags_needed &&
            previous->tag_ids == tag_ids &&
            previous->families_needed == families_needed &&
            previous->thresholds == metric_thresholds) {
        return;
    }
    auto consumers = std::make_shared<EffectInputConsumers>();
    consumers->metric_mask = cell_metrics;
    consumers->tags_needed = tags_needed;
    consumers->tag_ids = tag_ids;
    consumers->families_needed = families_needed;
    consumers->thresholds = metric_thresholds;
    consumers->generation = previous == nullptr ? 1 : previous->generation + 1;
    std::atomic_store_explicit(&_effect_input_consumers,
        std::shared_ptr<const EffectInputConsumers>(std::move(consumers)),
        std::memory_order_release);
    // No `_published_effect_input_digest = 0` here any more: that was a main-thread
    // write into the digest thread's state. The generation bump above makes the
    // digest republish on its own side.
}

void NativeEconomyRuntime::set_effect_metric_override(int32_t metric,
        int64_t value, bool has_value) {
    if (metric < 0 ||
            metric >= static_cast<int32_t>(FAMILY_METRIC_COUNT))
        return;
    const size_t slot = static_cast<size_t>(metric);
    auto next = std::make_shared<EffectMetricOverrideSet>();
    const std::shared_ptr<const EffectMetricOverrideSet> previous =
        std::atomic_load_explicit(&_effect_metric_override_snapshot,
            std::memory_order_acquire);
    if (previous != nullptr) {
        next->values = previous->values;
        next->set = previous->set;
        next->generation = previous->generation;
    }
    next->values[slot] = value;
    next->set[slot] = has_value ? 1 : 0;
    ++next->generation;
    std::atomic_store_explicit(&_effect_metric_override_snapshot,
        std::shared_ptr<const EffectMetricOverrideSet>(std::move(next)),
        std::memory_order_release);
}

bool NativeEconomyRuntime::set_cell_tag_override_for_test(
        const std::string &tag_key, int32_t cell, bool on) {
    if (cell < 0 || cell >= _cell_count.get()) return false;
    int32_t tag = -1;
    for (int32_t index = 0; index < _target_tags.count(); ++index) {
        if (_target_tags.names[static_cast<size_t>(index)] != tag_key) continue;
        tag = index;
        break;
    }
    if (tag < 0) return false;
    auto next = std::make_shared<CellTagOverrideSet>();
    const std::shared_ptr<const CellTagOverrideSet> previous =
        std::atomic_load_explicit(&_cell_tag_override_snapshot,
            std::memory_order_acquire);
    if (previous != nullptr) {
        next->cells = previous->cells;
        next->generation = previous->generation;
    }
    std::vector<CellTagOverride> &cell_overrides = next->cells[cell];
    if (cell_overrides.size() <= static_cast<size_t>(tag))
        cell_overrides.resize(static_cast<size_t>(tag) + 1u);
    CellTagOverride &override = cell_overrides[static_cast<size_t>(tag)];
    override.force_true = on ? 1 : 0;
    override.force_false = on ? 0 : 1;
    ++next->generation;
    std::atomic_store_explicit(&_cell_tag_override_snapshot,
        std::shared_ptr<const CellTagOverrideSet>(std::move(next)),
        std::memory_order_release);
    return true;
}

void NativeEconomyRuntime::clear_cell_tag_overrides_for_test() {
    auto next = std::make_shared<CellTagOverrideSet>();
    const std::shared_ptr<const CellTagOverrideSet> previous =
        std::atomic_load_explicit(&_cell_tag_override_snapshot,
            std::memory_order_acquire);
    if (previous != nullptr) next->generation = previous->generation;
    ++next->generation;
    std::atomic_store_explicit(&_cell_tag_override_snapshot,
        std::shared_ptr<const CellTagOverrideSet>(std::move(next)),
        std::memory_order_release);
}

void NativeEconomyRuntime::refresh_effect_input_digest() {
    // One load for the whole pass: the consumer set is immutable once published.
    const std::shared_ptr<const EffectInputConsumers> consumers =
        std::atomic_load_explicit(&_effect_input_consumers,
            std::memory_order_acquire);
    if (consumers == nullptr) return;
    if (!consumers->tags_needed && !consumers->families_needed &&
            consumers->metric_mask.is_none())
        return;
    const std::shared_ptr<const CellTagOverrideSet> tag_overrides =
        std::atomic_load_explicit(&_cell_tag_override_snapshot,
            std::memory_order_acquire);
    const uint64_t tag_override_generation =
        tag_overrides == nullptr ? 0 : tag_overrides->generation;
    if (tag_override_generation != _tag_snapshot_override_generation) {
        rebuild_epoch_tag_snapshot();
        refresh_effect_input_digest();
        return;
    }
    const auto started = std::chrono::steady_clock::now();
    // Copy-on-write: bump the revisions on a private copy and publish the whole
    // snapshot in one atomic store at the end, so no reader can observe a half
    // updated set (P3-B).
    const std::shared_ptr<const EffectInputSnapshot> previous =
        std::atomic_load_explicit(&_effect_input_snapshot,
            std::memory_order_acquire);
    auto next = previous != nullptr
        ? std::make_shared<EffectInputSnapshot>(*previous)
        : std::make_shared<EffectInputSnapshot>();
    const std::shared_ptr<const EffectMetricOverrideSet> overrides =
        std::atomic_load_explicit(&_effect_metric_override_snapshot,
            std::memory_order_acquire);
    bool changed = false;
    uint64_t digest = 1469598103934665603ULL;
    // ── territory revision ────────────────────────────────────────────────
    // Ownership, not the country state hash: state_hash folds cash and goods in,
    // both of which move on every settlement, so keying on it would advance the
    // revision daily and defeat the gate entirely (04 §3.1).
    uint64_t territory_digest = 1469598103934665603ULL;
    territory_digest = effect_input_mix(territory_digest,
        static_cast<uint64_t>(_epoch_cell_country.size()));
    for (const int32_t country : _epoch_cell_country) {
        territory_digest = effect_input_mix(territory_digest,
            static_cast<uint64_t>(static_cast<uint32_t>(country)));
    }
    digest = effect_input_mix(digest, territory_digest);
    if (territory_digest != _effect_territory_published) {
        _effect_territory_published = territory_digest;
        ++next->territory_revision;
        changed = true;
    }
    // ── family revision ───────────────────────────────────────────────────
    // X9-b resolves family-owned targets from the Economy-side family tables.
    // Hash every input that can change target eligibility: identity/home cell,
    // branch generation/family/cell, and the ownership rows that make a family
    // own at least one building. Hash only when a family-target consumer exists
    // so unrelated cards keep their zero-refresh idle window.
    if (consumers->families_needed) {
        uint64_t family_digest = 1469598103934665603ULL;
        const auto &families = families_store();
        family_digest = effect_input_mix(family_digest,
            static_cast<uint64_t>(families.active.size()));
        for (int32_t family = 0; family < static_cast<int32_t>(
                families.active.size()); ++family) {
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(families.active[family]));
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(families.generation[family]));
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(static_cast<uint32_t>(
                    families.home_cell[family])));
        }
        const auto &branches = family_influences();
        family_digest = effect_input_mix(family_digest,
            static_cast<uint64_t>(branches.active.size()));
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                branches.active.size()); ++branch) {
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(branches.active[branch]));
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(branches.generation[branch]));
            family_digest = effect_input_mix(family_digest,
                branches.family_handle[branch]);
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(static_cast<uint32_t>(
                    branches.cell[branch])));
        }
        const auto &ownerships = family_ownerships();
        family_digest = effect_input_mix(family_digest,
            static_cast<uint64_t>(ownerships.size()));
        for (const FamilyBuildingOwnership &ownership : ownerships) {
            family_digest = effect_input_mix(family_digest,
                ownership.family_handle);
            family_digest = effect_input_mix(family_digest,
                ownership.building_handle);
            family_digest = effect_input_mix(family_digest,
                static_cast<uint64_t>(static_cast<uint32_t>(
                    std::max<int64_t>(0, ownership.owned_count))));
        }
        family_digest = effect_input_mix(family_digest,
            static_cast<uint64_t>(static_cast<uint32_t>(
                _family_target_min_branches_override_for_test)));
        digest = effect_input_mix(digest, family_digest);
        if (family_digest != _effect_family_published) {
            _effect_family_published = family_digest;
            ++next->family_revision;
            changed = true;
        }
    }
    // ── tag revision ──────────────────────────────────────────────────────
    if (consumers->tags_needed) {
        // R-3: ONE atomic load for the whole digest, so the bits hashed here all
        // belong to the same epoch. The local pointer also keeps that snapshot alive
        // if a commit publishes a new one mid-loop.
        const std::shared_ptr<const TagSnapshot> tags_snapshot = tag_snapshot();
        const uint64_t words = tags_snapshot == nullptr
            ? 0 : static_cast<uint64_t>(tags_snapshot->tag_words);
        uint64_t tag_digest = effect_input_mix(1469598103934665603ULL, words);
        if (tags_snapshot != nullptr) {
            for (const uint64_t word : tags_snapshot->tag_bits)
                tag_digest = effect_input_mix(tag_digest, word);
        }
        digest = effect_input_mix(digest, tag_digest);
        if (tag_digest != _effect_tag_published) {
            _effect_tag_published = tag_digest;
            ++next->tag_revision;
            changed = true;
        }
    }
    if (consumers->metric_mask.is_any()) {
        const int32_t cells = _cell_count.get();
        const int32_t metric_count = static_cast<int32_t>(FAMILY_METRIC_COUNT);
        std::vector<int64_t> values(static_cast<size_t>(metric_count), 0);
        // One digest per metric, so a card can depend on the metrics it reads
        // rather than on "some metric somewhere moved".
        std::array<uint64_t, FAMILY_METRIC_COUNT> per_metric;
        per_metric.fill(1469598103934665603ULL);
        digest = effect_input_mix(digest, static_cast<uint64_t>(cells));
        for (int32_t cell = 0; cell < cells; ++cell) {
            sample_effect_metrics(cell, metric_count, values.data(),
                consumers->metric_mask);
            for (int32_t metric = 0; metric < metric_count; ++metric) {
                if (!consumers->metric_mask.test(metric)) continue;
                int64_t sampled = values[static_cast<size_t>(metric)];
                if (overrides != nullptr &&
                        overrides->set[static_cast<size_t>(metric)] != 0)
                    sampled = overrides->values[static_cast<size_t>(metric)];
                // Threshold bucketing (review §3): if any card compares this
                // metric against N, the digest carries "how many N are <= value"
                // instead of the raw number. Crossing a threshold is exactly the
                // event that can flip a condition, and it needs no unit table --
                // population, counts and category ids all work the same way.
                const std::vector<int64_t> &metric_thresholds =
                    consumers->thresholds[static_cast<size_t>(metric)];
                if (!metric_thresholds.empty())
                    sampled = static_cast<int64_t>(
                        std::upper_bound(metric_thresholds.begin(),
                                         metric_thresholds.end(), sampled) -
                        metric_thresholds.begin());
                per_metric[static_cast<size_t>(metric)] = effect_input_mix(
                    per_metric[static_cast<size_t>(metric)],
                    static_cast<uint64_t>(sampled));
            }
        }
        // Fold the per-metric digests into the global one (so its meaning is
        // unchanged) and bump the revision of each metric that actually moved.
        for (int32_t metric = 0; metric < metric_count; ++metric) {
            if (!consumers->metric_mask.test(metric)) continue;
            const size_t slot = static_cast<size_t>(metric);
            digest = effect_input_mix(digest, per_metric[slot]);
            if (per_metric[slot] != _effect_metric_published[slot]) {
                _effect_metric_published[slot] = per_metric[slot];
                ++next->metric_revision[slot];
                changed = true;
            }
        }
    }
    ++_effect_input_digest_computations;
    _effect_input_digest_ms += std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    // A changed consumer set makes the old digest incomparable, so it republishes
    // even when the value happens to match.
    const bool consumers_changed =
        consumers->generation != _published_consumers_generation;
    const uint64_t override_generation =
        overrides == nullptr ? 0 : overrides->generation;
    const bool override_changed = override_generation != _published_override_generation;
    const bool tag_override_changed =
        tag_override_generation != _tag_override_published_generation;
    // KNOWN GAP (review round 3, P2): a metric that leaves the mask and later
    // re-enters with a digest equal to the stale stored one will not bump. The
    // fix is to force a bump for slots newly present in the mask; resetting all
    // published digests on every consumer change (the first attempt) made every
    // metric bump on every pass, which is worse. Global revision still moves, so
    // nothing is silently lost -- only the per-card narrowing misses one refresh.
    if (digest != _published_effect_input_digest || consumers_changed ||
            override_changed || tag_override_changed) {
        _published_effect_input_digest = digest;
        _published_consumers_generation = consumers->generation;
        _published_override_generation = override_generation;
        _tag_override_published_generation = tag_override_generation;
        _effect_input_revision.fetch_add(1, std::memory_order_release);
    }
    if (changed || previous == nullptr) {
        ++next->generation;
        std::atomic_store_explicit(&_effect_input_snapshot,
            std::shared_ptr<const EffectInputSnapshot>(std::move(next)),
            std::memory_order_release);
    }
}

// REMOVED (R-3): `ensure_country_tag_counts` and `build_country_tag_counts` are
// gone. The per-country counts live in the same immutable TagSnapshot as the tag
// bits they are derived from, so there is nothing to build or invalidate here;
// readers call `tag_snapshot()`.

// REMOVED (R-3): `ensure_country_specialized_goods` (X7b, metric 67) used to build
// lazily from a const getter here. It is now computed inside
// `rebuild_epoch_tag_snapshot()` and published in the same `TagSnapshot` as the tag
// bits, so one epoch's answer is always one object. Readers use `tag_snapshot()`.

bool NativeEconomyRuntime::cell_has_target_tag(int32_t cell, int32_t tag) const {
    if (cell < 0 || tag < 0) return false;
    // R-3: one atomic load; the local pointer owns the storage for this read.
    //
    // R-3b: SINGLE-SHOT ONLY. `atomic_load(shared_ptr)` is not lock-free on MSVC --
    // it takes a process-wide spin lock -- so calling this once per cell inside a
    // scan is O(cells) global locks. Loop callers must load `tag_snapshot()` once and
    // use `snapshot_has_tag()`. Kept as the convenient single-query form (and the
    // selector fixtures' entry point) rather than deleted, because "is this one cell
    // tagged" is a legitimate question the callers outside a loop still ask.
    const std::shared_ptr<const TagSnapshot> snapshot = tag_snapshot();
    if (cell >= _cell_count.get()) return false;
    return snapshot_has_tag(snapshot.get(), cell, tag);
}

void NativeEconomyRuntime::collect_effect_target_cells(
        int32_t source_cell, int32_t selector_kind, int32_t param0, int32_t param1,
        std::vector<int32_t> &out_cells, uint64_t selection_salt,
        EffectSelectorStats *stats) const {
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
        ++_own_territory_branch;
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
        // Plan 22 M2-2/M2-5: the ceiling comes from `selector_cell_ceiling`,
        // which reports "no policy cap" for territory queries, and only the map
        // size bounds the result.
        //
        // `param0 == 0` means "the kind's own default", which for a territory
        // query is now the whole territory: the map size is the only bound.
        // Passing the legacy 32 here would have kept the cap alive no matter
        // what the content said -- the cap has to be relinquished in BOTH
        // places, which is why plan 22 M2-1 insists on the ordering.
        //
        // A card that EXPLICITLY authors 32 still gets 32, so the content
        // update and this code change stay separate, reviewable steps.
        const int32_t cap = resolve_selector_cell_cap(
            EffectRuntime::SELECTOR_OWN_TERRITORY, param0, cells);
        const int32_t owned = country_cell_count(country);
        _own_territory_owned += owned;
        _own_last_source_cell = source_cell;
        _own_last_country = country;
        _own_last_cap = cap;
        _own_last_tag = tag;
        _own_first_cell_ok = owned > 0 ? country_cell_at(country, 0) : -999;
        out_cells.reserve(static_cast<size_t>(std::max(0, owned)));
        // R-3b: ONE atomic load for the whole scan. `cell_has_target_tag` per cell
        // would take the shared_ptr spin lock `owned` times; the local pointer also
        // keeps the bits alive if a commit swaps a new snapshot in mid-loop, so every
        // cell in this answer is judged against the SAME epoch.
        const std::shared_ptr<const TagSnapshot> tags_here =
            tag >= 0 ? tag_snapshot() : std::shared_ptr<const TagSnapshot>();
        const TagSnapshot *const tags_ptr = tags_here.get();
        // Collect EVERY match first. Breaking at `cap` here is what made the
        // kept subset "the lowest ids in territory order", i.e. always the same
        // corner of every country.
        for (int32_t index = 0; index < owned; ++index) {
            const int32_t cell = country_cell_at(country, index);
            if (cell < 0) { ++_own_cell_neg; continue; }
            if (tag >= 0 && !snapshot_has_tag(tags_ptr, cell, tag)) {
                ++_own_tag_rejected; continue;
            }
            out_cells.push_back(cell);
            ++_own_pushed_raw;
        }
        // A country that owns nothing (or whose territory matches no tag)
        // yields nothing on purpose: falling back to the anchor would apply a
        // "only on matching cells" card to a cell that does not match.
        std::sort(out_cells.begin(), out_cells.end());
        out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
        effect_stable_cap(out_cells, cap, static_cast<uint64_t>(source_cell),
            selection_salt, stats);
        _own_territory_emitted += static_cast<int64_t>(out_cells.size());
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
        // R-3b: same single load as the territory branch above -- this loop is
        // grid-wide, so a per-cell load here is the worst case of the spin lock.
        const std::shared_ptr<const TagSnapshot> tags_here =
            tag >= 0 ? tag_snapshot() : std::shared_ptr<const TagSnapshot>();
        const TagSnapshot *const tags_ptr = tags_here.get();
        for (int32_t cell = 0; cell < cells; ++cell) {
            if (tag >= 0 && !snapshot_has_tag(tags_ptr, cell, tag)) continue;
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
        // Grid-wide cards have no anchor, so the salt is what keeps two cards
        // from sampling the same cells.
        effect_stable_cap(out_cells, tag_cap, 0, selection_salt, stats);
        return;
    }
    // 14/15 (X1 source-tag radial) are composite: IdeologyRuntime first walks
    // the territory with OWN_TERRITORY to pick the source cells, then asks for a
    // radial fan-out from each. A direct call with these kinds has no defined
    // anchor semantics, so answer "no cells" instead of falling through to the
    // neighbour walk and quietly behaving like R1/R2.
    if (selector_kind >= EffectRuntime::SELECTOR_TAG_SOURCE_R1) return;
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

void NativeEconomyRuntime::dilate_cell_set(const std::vector<int32_t> &sources,
                                          int32_t depth,
                                          std::vector<int32_t> &out_cells) const {
    out_cells.clear();
    if (sources.empty() || depth <= 0) return;
    const int32_t cells = _cell_count.get();
    if (cells <= 0) return;
    if (_building_neighbors.size() != static_cast<size_t>(cells) * 6) return;

    // One buffer for the whole expansion, reused across calls via a stamp counter: an
    // entry counts as visited only when it carries the CURRENT stamp, so reuse costs
    // neither an allocation nor a `cells`-sized clear.
    //
    // THREAD_LOCAL, not a member. The loop this replaced allocated a LOCAL vector on
    // every call, so it was safe to call from any thread. A shared member buffer would
    // have introduced a data race between the ideology worker and the main thread, which
    // is a regression the equivalence assertion could never catch (it runs on one
    // thread). `thread_local` keeps the allocation-free reuse AND the thread safety.
    static thread_local std::vector<int32_t> stamp_buffer;
    static thread_local int32_t stamp_current = 0;
    if (stamp_buffer.size() != static_cast<size_t>(cells))
        stamp_buffer.assign(static_cast<size_t>(cells), 0);
    ++stamp_current;
    if (stamp_current <= 0) {
        std::fill(stamp_buffer.begin(), stamp_buffer.end(), 0);
        stamp_current = 1;
    }
    const int32_t stamp = stamp_current;

    // SOURCES ARE NOT PRE-MARKED AS OUTPUT.
    //
    // The first version of this seeded every source into the visited buffer, which
    // silently DROPPED any cell that is both a source and a neighbour of another source.
    // The per-source loop never drops such a cell: it is a legitimately discovered
    // neighbour. The equivalence assertion (`dilate_matches_per_source_union`) caught it.
    //
    // So sources only enter the frontier; a source becomes part of the OUTPUT when some
    // other source's expansion reaches it, exactly as the loop would produce.
    std::vector<int32_t> frontier = sources;
    std::vector<int32_t> next;
    out_cells.reserve(sources.size() * static_cast<size_t>(depth == 1 ? 6 : 18));
    for (int32_t level = 0; level < depth && !frontier.empty(); ++level) {
        next.clear();
        for (const int32_t cell : frontier) {
            if (cell < 0 || cell >= cells) continue;
            const size_t base = static_cast<size_t>(cell) * 6;
            for (int32_t dir = 0; dir < 6; ++dir) {
                const int32_t neighbor = _building_neighbors[base + static_cast<size_t>(dir)];
                if (neighbor < 0 || neighbor >= cells) continue;
                if (stamp_buffer[static_cast<size_t>(neighbor)] == stamp) continue;
                stamp_buffer[static_cast<size_t>(neighbor)] = stamp;
                // Kinds 6/7 apply no terrain or predicate filter (`accepts()` is true for
                // them), so bounds plus the stamp is the whole test.
                out_cells.push_back(neighbor);
                next.push_back(neighbor);
            }
        }
        frontier.swap(next);
    }
    std::sort(out_cells.begin(), out_cells.end());
    out_cells.erase(std::unique(out_cells.begin(), out_cells.end()), out_cells.end());
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
