#include "economy_runtime.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <limits>
#include <tuple>
#include <utility>
#include <vector>

// Branch demography, the membership claim ledger and the proportional
// membership split. See docs/cpp-dots-runtime/family-demography-ledger-design.md.

namespace pk {

namespace {

using Clock = std::chrono::steady_clock;
constexpr int64_t kQ16 = NativeEconomyRuntime::Q16_ONE;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

uint64_t mix64(uint64_t hash, uint64_t value) {
    hash ^= value + 0x9e3779b97f4a7c15ULL + (hash << 6U) + (hash >> 2U);
    hash ^= hash >> 30U;
    hash *= 0xbf58476d1ce4e5b9ULL;
    hash ^= hash >> 27U;
    hash *= 0x94d049bb133111ebULL;
    hash ^= hash >> 31U;
    return hash;
}

struct RoundedShare {
    int64_t expected_q16 = 0;
    int64_t cap = 0;
    uint64_t key = 0;
    int64_t alloc = 0;
};

std::vector<RoundedShare> &rounded_share_scratch() {
    thread_local std::vector<RoundedShare> scratch;
    scratch.clear();
    return scratch;
}

// Integer split to exactly `total` by systematic sampling: one hashed Q16
// offset over the cumulative expectations gives every party floor or ceil of
// its expectation with exactly that mean, independent of its position.
// Repairs (cap clamps, truncation residue) start at a hashed rotation so no
// position -- in particular the trailing anonymous party -- is favoured.
void round_shares(std::vector<RoundedShare> &shares, int64_t total, uint64_t seed) {
    if (shares.empty()) return;
    int64_t cumulative = static_cast<int64_t>((mix64(seed, 0x53595354ULL) >> 48U) & 0xffffULL);
    int64_t previous = cumulative >> 16;
    int64_t sum = 0;
    for (RoundedShare &share : shares) {
        cumulative += std::max<int64_t>(0, share.expected_q16);
        const int64_t current = cumulative >> 16;
        share.alloc = std::clamp<int64_t>(current - previous, 0,
                                          std::max<int64_t>(0, share.cap));
        previous = current;
        sum += share.alloc;
    }
    const size_t count = shares.size();
    const size_t start = static_cast<size_t>(mix64(seed, 0x524f54ULL) % count);
    for (size_t step = 0; step < count && sum > total; ++step) {
        RoundedShare &share = shares[(start + step) % count];
        const int64_t take = std::min(share.alloc, sum - total);
        share.alloc -= take;
        sum -= take;
    }
    for (size_t step = 0; step < count && sum < total; ++step) {
        RoundedShare &share = shares[(start + step) % count];
        const int64_t add = std::min(std::max<int64_t>(0, share.cap) - share.alloc,
                                     total - sum);
        if (add <= 0) continue;
        share.alloc += add;
        sum += add;
    }
}

// log2 of a Q16 ratio clamped to [1/4, 4], piecewise linear between powers
// of two; returns Q16 in [-2, 2].
int64_t log2_ratio_q16(int64_t ratio_q16) {
    const int64_t ratio = std::clamp<int64_t>(ratio_q16, kQ16 / 4, kQ16 * 4);
    int32_t bit = 0;
    while ((ratio >> (bit + 1)) != 0) ++bit;
    const int64_t base = int64_t(1) << bit;
    const int64_t frac_q16 = ((ratio - base) << 16) / base;
    return (static_cast<int64_t>(bit) - 16) * kQ16 + frac_q16;
}

// Rational logistic 1/2 + x / (2 (1 + |x|)), Q16 in and out.
int64_t soft_sigmoid_q16(int64_t x_q16) {
    const int64_t magnitude = x_q16 < 0 ? -x_q16 : x_q16;
    return kQ16 / 2 + (x_q16 * kQ16) / (2 * (kQ16 + magnitude));
}

} // namespace

void NativeEconomyRuntime::collect_family_edges_for_cohort(
        int32_t slot, std::vector<int32_t> &out) const {
    out.clear();
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()))
        return;
    const uint64_t handle = population_store().handle_for_slot(slot);
    const size_t size = family_memberships().size();
    const bool indexed = _family_csr_edge_count <= size &&
        _family_cohort_offsets.size() >= 2;
    if (!indexed) {
        for (size_t i = 0; i < size; ++i)
            if (family_memberships()[i].cohort_handle == handle)
                out.push_back(static_cast<int32_t>(i));
        return;
    }
    if (static_cast<size_t>(slot) + 1 < _family_cohort_offsets.size()) {
        for (int32_t p = _family_cohort_offsets[slot];
             p < _family_cohort_offsets[slot + 1]; ++p) {
            const int32_t edge = _family_cohort_edge_indices[p];
            if (edge >= 0 && static_cast<size_t>(edge) < size &&
                family_memberships()[edge].cohort_handle == handle)
                out.push_back(edge);
        }
    }
    for (size_t i = _family_csr_edge_count; i < size; ++i)
        if (family_memberships()[i].cohort_handle == handle)
            out.push_back(static_cast<int32_t>(i));
}

int64_t NativeEconomyRuntime::family_ledger_basis_for_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()))
        return 0;
    const uint64_t handle = population_store().handle_for_slot(slot);
    const size_t size = family_memberships().size();
    bool found = false;
    int64_t basis = 0;
    const auto visit = [&](size_t edge) {
        const FamilyMembershipEdge &row = family_memberships()[edge];
        if (row.cohort_handle != handle) return;
        found = true;
        basis = std::max(basis, row.funds_basis);
    };
    size_t tail = 0;
    if (_family_csr_edge_count <= size && _family_cohort_offsets.size() >= 2) {
        if (static_cast<size_t>(slot) + 1 < _family_cohort_offsets.size())
            for (int32_t p = _family_cohort_offsets[slot];
                 p < _family_cohort_offsets[slot + 1]; ++p) {
                const int32_t edge = _family_cohort_edge_indices[p];
                if (edge >= 0 && static_cast<size_t>(edge) < size) visit(edge);
            }
        tail = _family_csr_edge_count;
    }
    for (size_t i = tail; i < size; ++i) visit(i);
    return found ? basis : std::max<int64_t>(0, population_store().funds[slot]);
}

void NativeEconomyRuntime::shift_family_ledger_basis(int32_t slot, int64_t delta) {
    if (delta == 0 || family_memberships().empty()) return;
    collect_family_edges_for_cohort(slot, _family_edge_scratch);
    for (int32_t edge : _family_edge_scratch) {
        auto edge_write = family_memberships().edit_row(edge, market_mutation_sink());
        edge_write[0].funds_basis = std::max<int64_t>(0, saturating_add(
            edge_write[0].funds_basis, delta, _saturation_count));
    }
}

void NativeEconomyRuntime::attribute_family_funds_delta(
        int32_t slot, uint64_t family_handle, int64_t delta) {
    if (delta == 0 || family_memberships().empty()) return;
    collect_family_edges_for_cohort(slot, _family_edge_scratch);
    if (_family_edge_scratch.empty()) return;
    const int64_t funds = std::max<int64_t>(0, population_store().funds[slot]);
    for (int32_t edge : _family_edge_scratch) {
        auto edge_write = family_memberships().edit_row(edge, market_mutation_sink());
        FamilyMembershipEdge &row = edge_write[0];
        row.funds_basis = std::max<int64_t>(0, saturating_add(
            row.funds_basis, delta, _saturation_count));
        if (family_handle != 0 && row.family_handle == family_handle)
            row.cash_claim = std::clamp<int64_t>(saturating_add(
                row.cash_claim, delta, _saturation_count), 0, funds);
    }
}

void NativeEconomyRuntime::rebuild_family_owner_seats() {
    _family_owner_seat_rows.clear();
    if (_family_runtime_mode.get() != 2 || family_ownerships().empty()) return;
    int64_t sat = 0;
    for (int32_t i = 0; i < static_cast<int32_t>(family_ownerships().size()); ++i) {
        const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
            i, __FILE__, __LINE__);
        if (ownership.owned_count <= 0 || ownership.family_handle == 0) continue;
        const int32_t building = building_index_for_handle(ownership.building_handle);
        if (building < 0) continue;
        const auto group = building_view(static_cast<size_t>(building));
        if (group.owner_signature_id < 0 || group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size())) continue;
        const int64_t seats = saturating_mul(ownership.owned_count,
            _building_types[group.type_id].owner_slots_per_building, sat);
        if (seats <= 0) continue;
        const int32_t owner_slot = find_cohort_slot(group.cell, group.owner_signature_id);
        if (owner_slot < 0) continue;
        _family_owner_seat_rows.push_back({population_store().handle_for_slot(owner_slot),
                                           ownership.family_handle, seats});
    }
    std::sort(_family_owner_seat_rows.begin(), _family_owner_seat_rows.end(),
        [](const FamilyOwnerSeatRow &a, const FamilyOwnerSeatRow &b) {
            return std::tie(a.cohort_handle, a.family_handle) <
                std::tie(b.cohort_handle, b.family_handle);
        });
    size_t merged = 0;
    for (size_t i = 0; i < _family_owner_seat_rows.size(); ++i) {
        if (merged > 0 &&
            _family_owner_seat_rows[merged - 1].cohort_handle ==
                _family_owner_seat_rows[i].cohort_handle &&
            _family_owner_seat_rows[merged - 1].family_handle ==
                _family_owner_seat_rows[i].family_handle) {
            _family_owner_seat_rows[merged - 1].seats = saturating_add(
                _family_owner_seat_rows[merged - 1].seats,
                _family_owner_seat_rows[i].seats, sat);
        } else {
            _family_owner_seat_rows[merged++] = _family_owner_seat_rows[i];
        }
    }
    _family_owner_seat_rows.resize(merged);
    _saturation_count = saturating_add(_saturation_count, sat, _saturation_count);
}

int64_t NativeEconomyRuntime::family_owner_seats(uint64_t cohort_handle,
                                                 uint64_t family_handle) const {
    if (_family_owner_seat_rows.empty()) return 0;
    const auto found = std::lower_bound(_family_owner_seat_rows.begin(),
        _family_owner_seat_rows.end(), std::make_pair(cohort_handle, family_handle),
        [](const FamilyOwnerSeatRow &row, const std::pair<uint64_t, uint64_t> &key) {
            return std::tie(row.cohort_handle, row.family_handle) <
                std::tie(key.first, key.second);
        });
    return found != _family_owner_seat_rows.end() &&
            found->cohort_handle == cohort_handle && found->family_handle == family_handle
        ? found->seats : 0;
}

uint64_t NativeEconomyRuntime::owning_family_for_owner_hire(
        int32_t group_index, int32_t pool_slot) const {
    if (group_index < 0 || pool_slot < 0 ||
        _family_building_offsets.size() != building_count() + 1 ||
        _family_cohort_offsets.size() != population_store().active.size() + 1 ||
        static_cast<size_t>(pool_slot) + 1 >= _family_cohort_offsets.size()) return 0;
    const int32_t pool_begin = _family_cohort_offsets[pool_slot];
    const int32_t pool_end = _family_cohort_offsets[pool_slot + 1];
    if (pool_begin == pool_end) return 0;
    const uint64_t building_handle = buildings_store().modifier_handle[group_index];
    const uint64_t pool_handle = population_store().handle_for_slot(pool_slot);
    uint64_t best = 0;
    int64_t best_owned = 0;
    for (int32_t p = _family_building_offsets[group_index];
         p < _family_building_offsets[group_index + 1]; ++p) {
        const int32_t index = _family_building_edge_indices[p];
        if (index < 0 || index >= static_cast<int32_t>(family_ownerships().size())) continue;
        const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
            index, __FILE__, __LINE__);
        if (ownership.building_handle != building_handle || ownership.owned_count <= 0 ||
            ownership.owned_count < best_owned) continue;
        for (int32_t q = pool_begin; q < pool_end; ++q) {
            const int32_t edge = _family_cohort_edge_indices[q];
            if (edge < 0 || static_cast<size_t>(edge) >= family_memberships().size()) continue;
            const FamilyMembershipEdge &member = family_memberships()[edge];
            if (member.cohort_handle != pool_handle ||
                member.family_handle != ownership.family_handle || member.people <= 0)
                continue;
            if (ownership.owned_count > best_owned ||
                (ownership.owned_count == best_owned && ownership.family_handle < best)) {
                best = ownership.family_handle;
                best_owned = ownership.owned_count;
            }
            break;
        }
    }
    return best;
}

void NativeEconomyRuntime::rebuild_family_demography_weights() {
    const auto started = Clock::now();
    _family_demography_rows.clear();
    rebuild_family_owner_seats();
    if (_family_runtime_mode.get() != 2 || families_store().active_count <= 0 ||
        family_memberships().empty()) {
        _family_demography_weights_ms = elapsed_ms(started);
        return;
    }
    ensure_family_policy_factors();
    struct Aggregate {
        int32_t cell = -1;
        uint64_t family_handle = 0;
        int32_t family_index = -1;
        int64_t people = 0;
        int64_t claim = 0;
        int64_t survival_weighted = 0;
        int64_t employed = 0;
    };
    std::vector<Aggregate> rows;
    rows.reserve(family_memberships().size());
    int64_t sat = 0;
    for (size_t i = 0; i < family_memberships().size(); ++i) {
        const FamilyMembershipEdge &edge = family_memberships()[i];
        int32_t family = -1, slot = -1;
        if (edge.people <= 0 ||
            !families_store().valid_handle(edge.family_handle, family) ||
            !population_store().valid_handle(edge.cohort_handle, slot)) continue;
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        if (cell < 0 || cell >= _cell_count.get()) continue;
        rows.push_back({cell, edge.family_handle, family, edge.people,
            std::max<int64_t>(0, edge.cash_claim),
            saturating_mul(edge.people, population_store().needs_satisfaction[slot], sat),
            std::min(edge.people, std::max<int64_t>(0, edge.owner_employed) +
                std::max<int64_t>(0, edge.employee_employed))});
    }
    std::sort(rows.begin(), rows.end(), [](const Aggregate &a, const Aggregate &b) {
        return std::tie(a.cell, a.family_handle) < std::tie(b.cell, b.family_handle);
    });
    size_t merged = 0;
    for (size_t i = 0; i < rows.size(); ++i) {
        if (merged > 0 && rows[merged - 1].cell == rows[i].cell &&
            rows[merged - 1].family_handle == rows[i].family_handle) {
            Aggregate &dst = rows[merged - 1];
            dst.people = saturating_add(dst.people, rows[i].people, sat);
            dst.claim = saturating_add(dst.claim, rows[i].claim, sat);
            dst.survival_weighted = saturating_add(dst.survival_weighted,
                rows[i].survival_weighted, sat);
            dst.employed = saturating_add(dst.employed, rows[i].employed, sat);
        } else {
            rows[merged++] = rows[i];
        }
    }
    rows.resize(merged);

    std::vector<std::tuple<uint64_t, int32_t, int32_t>> branches;
    branches.reserve(family_influences().active.size());
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            family_influences().active.size()); ++branch)
        if (family_influences().active[branch] != 0)
            branches.emplace_back(family_influences().family_handle[branch],
                                  family_influences().cell[branch], branch);
    std::sort(branches.begin(), branches.end());

    const size_t ethnicity_count = std::max<size_t>(1, _ethnicity_ids.size());
    std::vector<int64_t> ethnic_population(ethnicity_count, 0);
    std::vector<int64_t> ethnic_funds(ethnicity_count, 0);
    _family_demography_rows.reserve(rows.size());
    std::vector<int64_t> target_totals;
    size_t begin = 0;
    while (begin < rows.size()) {
        const int32_t cell = rows[begin].cell;
        size_t end = begin + 1;
        while (end < rows.size() && rows[end].cell == cell) ++end;
        std::fill(ethnic_population.begin(), ethnic_population.end(), 0);
        std::fill(ethnic_funds.begin(), ethnic_funds.end(), 0);
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const uint32_t signature = population_store().signature_id[slot];
            if (signature >= _signatures.size()) return;
            const int32_t ethnicity = _signatures[signature].ethnicity_id;
            if (ethnicity < 0 || static_cast<size_t>(ethnicity) >= ethnicity_count) return;
            ethnic_population[ethnicity] = saturating_add(ethnic_population[ethnicity],
                std::max<int64_t>(0, population_store().population[slot]), sat);
            ethnic_funds[ethnicity] = saturating_add(ethnic_funds[ethnicity],
                std::max<int64_t>(0, population_store().funds[slot]), sat);
        });
        const size_t cell_rows_begin = _family_demography_rows.size();
        for (size_t i = begin; i < end; ++i) {
            const Aggregate &row = rows[i];
            FamilyDemographyRow out;
            out.cell = cell;
            out.family_handle = row.family_handle;
            out.family_index = row.family_index;
            out.people = row.people;
            const int32_t origin = families_store().origin_ethnicity[row.family_index];
            out.ethnicity = origin >= 0 && static_cast<size_t>(origin) < ethnicity_count
                ? origin : -1;
            const int64_t population = out.ethnicity >= 0
                ? std::max(ethnic_population[out.ethnicity], row.people) : row.people;
            const int64_t funds = out.ethnicity >= 0 ? ethnic_funds[out.ethnicity] : 0;
            out.ethnic_population = population;
            out.share_q16 = static_cast<int32_t>(std::clamp<int64_t>(
                mul_div_sat(row.people, kQ16, std::max<int64_t>(1, population), sat),
                0, kQ16));

            int32_t building_share_q16 = 0;
            const auto found = std::lower_bound(branches.begin(), branches.end(),
                std::make_tuple(row.family_handle, cell, std::numeric_limits<int32_t>::min()));
            if (found != branches.end() && std::get<0>(*found) == row.family_handle &&
                std::get<1>(*found) == cell)
                building_share_q16 = family_influences().building_share_q16[std::get<2>(*found)];
            const int64_t building_q16 = std::clamp<int64_t>(mul_div_sat(
                building_share_q16, kQ16, FAMILY_HEALTH_BUILDING_REF_Q16, sat), 0, kQ16);
            // Relative wealth: family per-capita claim over the local
            // per-capita funds of the same ethnicity.
            const int64_t ratio_q16 = funds > 0
                ? mul_div_sat(mul_div_sat(row.claim, population, row.people, sat),
                              kQ16, funds, sat)
                : (row.claim > 0 ? kQ16 * 4 : kQ16);
            const int64_t wealth_q16 = log2_ratio_q16(ratio_q16) / 2;
            const int64_t employment_q16 = std::clamp<int64_t>(
                mul_div_sat(row.employed, 2 * kQ16, row.people, sat) - kQ16, -kQ16, kQ16);
            const int64_t health_q16 =
                (FAMILY_HEALTH_BUILDING_WEIGHT_Q16 * building_q16 +
                 FAMILY_HEALTH_WEALTH_WEIGHT_Q16 * wealth_q16 +
                 FAMILY_HEALTH_EMPLOYMENT_WEIGHT_Q16 * employment_q16) / kQ16;
            out.health_q16 = static_cast<int32_t>(std::clamp<int64_t>(
                health_q16, -8 * kQ16, 8 * kQ16));
            int64_t target_q16 = FAMILY_TARGET_SHARE_MIN_Q16 +
                (FAMILY_TARGET_SHARE_MAX_Q16 - FAMILY_TARGET_SHARE_MIN_Q16) *
                    soft_sigmoid_q16(out.health_q16) / kQ16;
            if (static_cast<size_t>(row.family_index) < _family_absorb_bonus_q16.size()) {
                const int64_t bonus = _family_absorb_bonus_q16[row.family_index];
                if (bonus > 0)
                    target_q16 = std::min<int64_t>(FAMILY_TARGET_SHARE_MAX_Q16,
                        target_q16 + bonus * FAMILY_ABSORB_TARGET_BONUS_Q16 / kQ16);
            }
            // Distress reads subsistence (the mortality signal) and cash.
            const int64_t threshold = std::max<int64_t>(1,
                _starvation_satisfaction_threshold_q16);
            const int64_t survival_q16 = row.survival_weighted / row.people;
            const int64_t subsistence_distress = std::clamp<int64_t>(
                mul_div_sat(threshold - survival_q16, kQ16, threshold, sat), 0, kQ16);
            const int64_t cash_distress = std::clamp<int64_t>(mul_div_sat(
                FAMILY_CASH_DISTRESS_RATIO_Q16 - ratio_q16, kQ16,
                FAMILY_CASH_DISTRESS_RATIO_Q16, sat), 0, kQ16);
            const int64_t distress_q16 = std::max(subsistence_distress,
                cash_distress * FAMILY_CASH_DISTRESS_WEIGHT_Q16 / kQ16);
            out.distress_q16 = static_cast<int32_t>(distress_q16);
            const int64_t relief = kQ16 - distress_q16;
            out.target_share_q16 = static_cast<int32_t>(
                target_q16 * relief / kQ16 * relief / kQ16);
            _family_demography_rows.push_back(out);
        }
        // Same-ethnicity targets in one cell share the S_total ceiling.
        const size_t cell_rows_end = _family_demography_rows.size();
        target_totals.clear();
        for (size_t i = cell_rows_begin; i < cell_rows_end; ++i) {
            const int32_t ethnicity = _family_demography_rows[i].ethnicity;
            int64_t total = 0;
            for (size_t j = cell_rows_begin; j < cell_rows_end; ++j)
                if (_family_demography_rows[j].ethnicity == ethnicity)
                    total += _family_demography_rows[j].target_share_q16;
            target_totals.push_back(total);
        }
        for (size_t i = cell_rows_begin; i < cell_rows_end; ++i) {
            const int64_t total = target_totals[i - cell_rows_begin];
            if (total > FAMILY_TARGET_SHARE_TOTAL_Q16)
                _family_demography_rows[i].target_share_q16 = static_cast<int32_t>(
                    int64_t(_family_demography_rows[i].target_share_q16) *
                    FAMILY_TARGET_SHARE_TOTAL_Q16 / total);
        }
        for (size_t i = cell_rows_begin; i < cell_rows_end; ++i) {
            FamilyDemographyRow &out = _family_demography_rows[i];
            const int64_t target = out.target_share_q16;
            const int64_t deviation_q16 = std::clamp<int64_t>(
                (target - out.share_q16) * kQ16 /
                    std::max<int64_t>(target, FAMILY_TARGET_SHARE_EPSILON_Q16),
                -kQ16, kQ16);
            const int64_t distress = out.distress_q16;
            int64_t birth_weight = std::clamp<int64_t>(kQ16 +
                FAMILY_BIRTH_SLOPE_Q16 * deviation_q16 / kQ16 -
                FAMILY_BIRTH_DISTRESS_SLOPE_Q16 * distress / kQ16,
                FAMILY_WEIGHT_MIN_Q16, FAMILY_WEIGHT_MAX_Q16);
            if (static_cast<size_t>(out.family_index) < _family_birth_factor_q16.size())
                birth_weight = birth_weight *
                    std::max<int64_t>(0, _family_birth_factor_q16[out.family_index]) / kQ16;
            out.birth_weight_q16 = static_cast<int32_t>(birth_weight);
            out.death_weight_q16 = static_cast<int32_t>(std::clamp<int64_t>(kQ16 -
                FAMILY_DEATH_SLOPE_Q16 * deviation_q16 / kQ16 +
                FAMILY_DEATH_DISTRESS_SLOPE_Q16 * distress / kQ16,
                FAMILY_WEIGHT_MIN_Q16, FAMILY_WEIGHT_MAX_Q16));
        }
        begin = end;
    }
    _family_demography_weights_ms = elapsed_ms(started);
}

const NativeEconomyRuntime::FamilyDemographyRow *
NativeEconomyRuntime::family_demography_row(uint64_t family_handle,
                                            int32_t cell) const {
    const auto found = std::lower_bound(_family_demography_rows.begin(),
        _family_demography_rows.end(), std::make_pair(cell, family_handle),
        [](const FamilyDemographyRow &row, const std::pair<int32_t, uint64_t> &key) {
            return std::tie(row.cell, row.family_handle) <
                std::tie(key.first, key.second);
        });
    if (found == _family_demography_rows.end() || found->cell != cell ||
        found->family_handle != family_handle) return nullptr;
    return &*found;
}

void NativeEconomyRuntime::apply_family_death_attribution(
        int32_t slot, int64_t population_before, int64_t deaths) {
    if (deaths <= 0 || population_before <= 0 || slot < 0 ||
        slot >= static_cast<int32_t>(population_store().active.size())) return;
    collect_family_edges_for_cohort(slot, _family_edge_scratch);
    if (_family_edge_scratch.empty()) {
        record_person_demography(slot, population_before, deaths);
        return;
    }
    const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
    const uint64_t cohort_handle = population_store().handle_for_slot(slot);
    int64_t sat = 0;
    int64_t family_people = 0;
    for (int32_t edge : _family_edge_scratch)
        family_people += std::max<int64_t>(0, family_memberships()[edge].people);
    const int64_t anonymous = std::max<int64_t>(0, population_before - family_people);
    std::vector<RoundedShare> &shares = rounded_share_scratch();
    int64_t denominator = saturating_mul(anonymous, kQ16, sat);
    for (int32_t edge : _family_edge_scratch) {
        const FamilyMembershipEdge &row = family_memberships()[edge];
        const FamilyDemographyRow *demography = family_demography_row(row.family_handle, cell);
        const int64_t weight = demography != nullptr ? demography->death_weight_q16 : kQ16;
        const int64_t weighted = saturating_mul(std::max<int64_t>(0, row.people), weight, sat);
        denominator = saturating_add(denominator, weighted, sat);
        shares.push_back({weighted, std::max<int64_t>(0, row.people), row.family_handle, 0});
    }
    shares.push_back({saturating_mul(anonymous, kQ16, sat), anonymous, 0, 0});
    if (denominator <= 0) return;
    for (RoundedShare &share : shares)
        share.expected_q16 = mul_div_sat(saturating_mul(deaths, kQ16, sat),
                                         share.expected_q16, denominator, sat);
    uint64_t seed = mix64(static_cast<uint64_t>(_seed.get()), 0x46444541544855ULL); // "FDEATH"
    seed = mix64(seed, static_cast<uint64_t>(_epoch_id.get()));
    seed = mix64(seed, cohort_handle);
    round_shares(shares, std::min(deaths, population_before), seed);
    for (size_t i = 0; i < _family_edge_scratch.size(); ++i) {
        const int64_t died = shares[i].alloc;
        if (died <= 0) continue;
        const int32_t edge = _family_edge_scratch[i];
        int64_t people_before = 0;
        uint64_t family_handle = 0;
        {
            auto edge_write = family_memberships().edit_row(edge, market_mutation_sink());
            FamilyMembershipEdge &row = edge_write[0];
            people_before = row.people;
            family_handle = row.family_handle;
            row.people = std::max<int64_t>(0, row.people - died);
            row.owner_employed = std::min(row.owner_employed, row.people);
            row.employee_employed = std::min(row.employee_employed,
                                             row.people - row.owner_employed);
            if (row.people == 0) _family_indices_dirty = true;
        }
        _family_deaths_attributed += died;
        record_person_deaths_for_family(slot, family_handle, people_before, died);
    }
}

void NativeEconomyRuntime::record_person_deaths_for_family(
        int32_t cohort_slot, uint64_t family_handle, int64_t people_before,
        int64_t deaths) {
    if (_person_runtime_mode.get() != 2 || deaths <= 0 || people_before <= 0 ||
        cohort_slot < 0 || static_cast<size_t>(cohort_slot) + 1 >=
            _person_cohort_offsets.size()) return;
    thread_local std::vector<int32_t> candidates;
    candidates.clear();
    for (int32_t p = _person_cohort_offsets[cohort_slot];
         p < _person_cohort_offsets[cohort_slot + 1]; ++p) {
        const int32_t person = _person_cohort_indices[p];
        if (persons_store().active[person] != 0 &&
            persons_store().family_handle[person] == family_handle)
            candidates.push_back(person);
    }
    if (candidates.empty()) return;
    std::sort(candidates.begin(), candidates.end(), [&](int32_t a, int32_t b) {
        return std::tie(persons_store().stable_id[a], a) <
            std::tie(persons_store().stable_id[b], b);
    });
    int64_t remaining_population = people_before;
    int64_t remaining_deaths = std::min(deaths, people_before);
    for (int32_t person : candidates) {
        if (remaining_population <= 0 || remaining_deaths <= 0) break;
        uint64_t hash = 1469598103934665603ULL;
        hash = trace_hash_mix(hash, 0x504445415448ULL); // "PDEATH"
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed.get()));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_epoch_id.get()));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(persons_store().stable_id[person]));
        if (static_cast<int64_t>(hash % static_cast<uint64_t>(remaining_population)) <
                remaining_deaths) {
            retire_person(person);
            --remaining_deaths; ++_persons_died;
        }
        --remaining_population;
    }
}

void NativeEconomyRuntime::apply_family_birth_attribution(int32_t slot, int64_t births) {
    if (births <= 0 || _family_demography_rows.empty() || slot < 0 ||
        slot >= static_cast<int32_t>(population_store().active.size())) return;
    const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
    const uint32_t signature = population_store().signature_id[slot];
    if (signature >= _signatures.size()) return;
    const int32_t ethnicity = _signatures[signature].ethnicity_id;
    auto first = std::lower_bound(_family_demography_rows.begin(),
        _family_demography_rows.end(), cell,
        [](const FamilyDemographyRow &row, int32_t key) { return row.cell < key; });
    std::vector<RoundedShare> &shares = rounded_share_scratch();
    int64_t family_share = 0;
    int64_t sat = 0;
    for (auto it = first; it != _family_demography_rows.end() && it->cell == cell; ++it) {
        if (it->ethnicity != ethnicity || it->share_q16 <= 0) continue;
        int32_t family = -1;
        if (!families_store().valid_handle(it->family_handle, family)) continue;
        family_share += it->share_q16;
        shares.push_back({saturating_mul(it->share_q16, it->birth_weight_q16, sat),
                          births, it->family_handle, 0});
    }
    if (shares.empty()) return;
    const size_t family_rows = shares.size();
    const int64_t anonymous_share = std::max<int64_t>(0, kQ16 - family_share);
    shares.push_back({saturating_mul(anonymous_share, kQ16, sat), births, 0, 0});
    int64_t denominator = 0;
    for (const RoundedShare &share : shares)
        denominator = saturating_add(denominator, share.expected_q16, sat);
    if (denominator <= 0) return;
    for (RoundedShare &share : shares)
        share.expected_q16 = mul_div_sat(saturating_mul(births, kQ16, sat),
                                         share.expected_q16, denominator, sat);
    uint64_t seed = mix64(static_cast<uint64_t>(_seed.get()), 0x464249525448ULL); // "FBIRTH"
    seed = mix64(seed, static_cast<uint64_t>(_epoch_id.get()));
    seed = mix64(seed, population_store().handle_for_slot(slot));
    round_shares(shares, births, seed);
    collect_family_edges_for_cohort(slot, _family_edge_scratch);
    const int64_t sibling_basis = family_ledger_basis_for_slot(slot);
    const uint64_t cohort_handle = population_store().handle_for_slot(slot);
    for (size_t i = 0; i < family_rows; ++i) {
        const int64_t born = shares[i].alloc;
        const uint64_t family_handle = shares[i].key;
        if (born <= 0) continue;
        bool merged = false;
        for (int32_t edge : _family_edge_scratch) {
            if (family_memberships()[edge].family_handle != family_handle) continue;
            auto edge_write = family_memberships().edit_row(edge, market_mutation_sink());
            edge_write[0].people = saturating_add(edge_write[0].people, born, _saturation_count);
            merged = true;
            break;
        }
        if (!merged) {
            FamilyMembershipEdge membership;
            membership.family_handle = family_handle;
            membership.cohort_handle = cohort_handle;
            membership.people = born;
            membership.population_basis = population_store().population[slot];
            membership.funds_basis = sibling_basis;
            family_memberships().push_back(membership);
            _family_indices_dirty = true;
        }
        _family_births_attributed += born;
    }
}

int64_t NativeEconomyRuntime::plan_family_membership_move(
        int32_t source_slot, int32_t destination_cell, int64_t moved_population,
        uint64_t preferred_family_handle, bool preferred_family_strict) {
    _family_move_plan.clear();
    if (moved_population <= 0 || family_memberships().empty()) return moved_population;
    collect_family_edges_for_cohort(source_slot, _family_edge_scratch);
    if (_family_edge_scratch.empty()) return moved_population;
    const int64_t population = std::max<int64_t>(0,
        population_store().population[source_slot]);
    int64_t family_people = 0;
    for (int32_t edge : _family_edge_scratch)
        family_people += std::max<int64_t>(0, family_memberships()[edge].people);
    const int64_t anonymous = std::max<int64_t>(0, population - family_people);
    const int64_t moving = std::min(moved_population, population);
    int64_t sat = 0;
    // Party 0..n-1 are family edges, party n is anonymous.
    std::vector<RoundedShare> &shares = rounded_share_scratch();
    thread_local std::vector<int64_t> full_caps;
    thread_local std::vector<int64_t> strict_alloc;
    full_caps.clear();
    strict_alloc.assign(_family_edge_scratch.size() + 1, 0);
    int64_t remaining = moving;
    if (preferred_family_strict) {
        for (size_t i = 0; i < _family_edge_scratch.size(); ++i) {
            const FamilyMembershipEdge &row = family_memberships()[_family_edge_scratch[i]];
            if (preferred_family_handle == 0 || row.family_handle != preferred_family_handle)
                continue;
            strict_alloc[i] = std::min(remaining, std::max<int64_t>(0, row.people));
            remaining -= strict_alloc[i];
        }
        if (preferred_family_handle == 0) {
            strict_alloc.back() = std::min(remaining, anonymous);
            remaining -= strict_alloc.back();
        }
    }
    thread_local std::vector<int64_t> guarded;
    guarded.assign(_family_edge_scratch.size() + 1, 0);
    const uint64_t source_handle = population_store().handle_for_slot(source_slot);
    int64_t total_weight = 0;
    for (size_t i = 0; i < _family_edge_scratch.size(); ++i) {
        const FamilyMembershipEdge &row = family_memberships()[_family_edge_scratch[i]];
        const int64_t members = std::max<int64_t>(0, row.people) - strict_alloc[i];
        // Members holding the family's own owner seats leave last.
        if (!_family_owner_seat_rows.empty() && members > 0 &&
            !(preferred_family_strict && row.family_handle == preferred_family_handle))
            guarded[i] = std::min(members,
                family_owner_seats(source_handle, row.family_handle));
        const int64_t people = members - guarded[i];
        int64_t cap = people;
        const int32_t mobility = family_behavior_score_term_q16(
            row.family_handle, destination_cell, FAMILY_SCORE_CAREER_MOBILITY);
        if (mobility < kQ16) cap = mul_div_sat(people, mobility, kQ16, sat);
        int64_t weight = saturating_mul(cap, kQ16, sat);
        if (!preferred_family_strict && preferred_family_handle != 0 &&
            row.family_handle == preferred_family_handle)
            weight = saturating_mul(cap, FAMILY_PREFERRED_MOVE_WEIGHT_Q16, sat);
        total_weight = saturating_add(total_weight, weight, sat);
        shares.push_back({weight, cap, row.family_handle, 0});
        full_caps.push_back(people);
    }
    const int64_t anonymous_left = anonymous - strict_alloc.back();
    shares.push_back({saturating_mul(anonymous_left, kQ16, sat), anonymous_left, 0, 0});
    full_caps.push_back(anonymous_left);
    total_weight = saturating_add(total_weight, shares.back().expected_q16, sat);
    for (RoundedShare &share : shares) share.alloc = 0;
    if (remaining > 0) {
        if (total_weight > 0) {
            for (RoundedShare &share : shares)
                share.expected_q16 = mul_div_sat(saturating_mul(remaining, kQ16, sat),
                                                 share.expected_q16, total_weight, sat);
            uint64_t seed = mix64(static_cast<uint64_t>(_seed.get()), 0x464d4f5645ULL); // "FMOVE"
            seed = mix64(seed, static_cast<uint64_t>(_epoch_id.get()));
            seed = mix64(seed, source_handle);
            seed = mix64(seed, static_cast<uint64_t>(population));
            seed = mix64(seed, static_cast<uint64_t>(static_cast<uint32_t>(destination_cell)));
            round_shares(shares, remaining, seed);
        }
        int64_t placed = 0;
        for (const RoundedShare &share : shares) placed += share.alloc;
        // Mobility caps may leave the move short; the cohort move itself is
        // fixed, so fill the rest from the uncapped headcount, and only then
        // from guarded owner-seat holders.
        for (size_t i = 0; i < shares.size() && placed < remaining; ++i) {
            const int64_t add = std::min(full_caps[i] - shares[i].alloc, remaining - placed);
            if (add <= 0) continue;
            shares[i].alloc += add;
            placed += add;
        }
        int64_t guard_total = 0;
        for (size_t i = 0; i < shares.size(); ++i) {
            guard_total += guarded[i];
            if (placed >= remaining) continue;
            const int64_t add = std::min(guarded[i], remaining - placed);
            if (add <= 0) continue;
            shares[i].alloc += add;
            placed += add;
            guard_total -= add;
        }
        _family_owner_seats_guarded += guard_total;
    }
    for (size_t i = 0; i < _family_edge_scratch.size(); ++i) {
        const int64_t people = strict_alloc[i] + shares[i].alloc;
        if (people <= 0) continue;
        const FamilyMembershipEdge &row = family_memberships()[_family_edge_scratch[i]];
        const int64_t claim = people >= row.people
            ? std::max<int64_t>(0, row.cash_claim)
            : mul_div_sat(std::max<int64_t>(0, row.cash_claim), people,
                          std::max<int64_t>(1, row.people), sat);
        _family_move_plan.push_back({_family_edge_scratch[i], people, claim});
    }
    return strict_alloc.back() + shares.back().alloc;
}

void NativeEconomyRuntime::move_family_membership(
        int32_t source_slot, int32_t destination_slot, int64_t moved_funds) {
    auto &memo = living_cost_memo_state();
    if (memo.owner == this) memo.quotes.clear();
    if (source_slot < 0 || destination_slot < 0) {
        _family_move_plan.clear();
        return;
    }
    const uint64_t source_handle = population_store().handle_for_slot(source_slot);
    const uint64_t destination_handle = population_store().handle_for_slot(destination_slot);
    shift_family_ledger_basis(source_slot, -moved_funds);
    shift_family_ledger_basis(destination_slot, moved_funds);
    if (_family_move_plan.empty()) return;
    collect_family_edges_for_cohort(destination_slot, _family_destination_edge_scratch);
    const std::vector<int32_t> &destination_edges = _family_destination_edge_scratch;
    const int64_t destination_basis = family_ledger_basis_for_slot(destination_slot);
    for (const FamilyMovePlanRow &move : _family_move_plan) {
        FamilyMembershipEdge source = family_memberships()[move.edge];
        if (source.cohort_handle != source_handle || move.people <= 0) continue;
        const int64_t people = std::min(move.people, std::max<int64_t>(0, source.people));
        const int64_t claim = std::min(move.claim, std::max<int64_t>(0, source.cash_claim));
        if (people <= 0) continue;
        move_notable_people(source_handle, destination_handle,
            source.family_handle, source.people, people);
        source.people -= people;
        source.cash_claim -= claim;
        source.population_basis = std::max<int64_t>(0, source.population_basis - people);
        source.owner_employed = std::min(source.owner_employed, source.people);
        source.employee_employed = std::min(source.employee_employed,
                                            source.people - source.owner_employed);
        family_memberships().write_record(move.edge, source, market_mutation_sink());
        bool merged = false;
        for (int32_t edge : destination_edges) {
            if (family_memberships()[edge].family_handle != source.family_handle) continue;
            auto edge_write = family_memberships().edit_row(edge, market_mutation_sink());
            edge_write[0].people = saturating_add(edge_write[0].people, people,
                                                  _saturation_count);
            edge_write[0].cash_claim = saturating_add(edge_write[0].cash_claim, claim,
                                                      _saturation_count);
            merged = true;
            break;
        }
        if (!merged) {
            FamilyMembershipEdge moved;
            moved.family_handle = source.family_handle;
            moved.cohort_handle = destination_handle;
            moved.people = people;
            moved.cash_claim = claim;
            moved.population_basis = population_store().population[destination_slot];
            moved.funds_basis = destination_basis;
            family_memberships().push_back(moved);
        }
    }
    _family_move_plan.clear();
    _family_indices_dirty = true;
}

void NativeEconomyRuntime::settle_family_claim_ledger() {
    const size_t edge_count = family_memberships().size();
    _family_ledger_business_by_edge.assign(edge_count, 0);
    if (_family_ledger_business_by_slot.size() < population_store().active.size())
        _family_ledger_business_by_slot.resize(population_store().active.size(), 0);
    _family_ledger_touched_slots.clear();
    int64_t sat = 0;
    if (_family_building_offsets.size() == building_count() + 1 &&
        _family_cell_offsets.size() == static_cast<size_t>(_cell_count.get()) + 1 &&
        _building_cell_offsets.size() == static_cast<size_t>(_cell_count.get()) + 1) {
        for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
            if (_family_cell_offsets[cell] == _family_cell_offsets[cell + 1]) continue;
            for (int32_t g = _building_cell_offsets[cell];
                 g < _building_cell_offsets[cell + 1]; ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.count <= 0 || group.owner_signature_id < 0) continue;
                const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
                if (owner_slot < 0 || static_cast<size_t>(owner_slot) + 1 >=
                        _family_cohort_offsets.size() ||
                    _family_cohort_offsets[owner_slot] ==
                        _family_cohort_offsets[owner_slot + 1]) continue;
                const int64_t net = saturating_sub(saturating_sub(saturating_sub(
                    group.last_revenue, group.last_input_cost, sat),
                    group.last_wages_paid, sat), group.last_maintenance_cost, sat);
                if (net == 0) continue;
                if (_family_ledger_business_by_slot[owner_slot] == 0)
                    _family_ledger_touched_slots.push_back(owner_slot);
                _family_ledger_business_by_slot[owner_slot] = saturating_add(
                    _family_ledger_business_by_slot[owner_slot], net, sat);
                for (int32_t p = _family_building_offsets[g];
                     p < _family_building_offsets[g + 1]; ++p) {
                    const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
                        _family_building_edge_indices[p], __FILE__, __LINE__);
                    // Profit follows the posts the family actually staffs;
                    // an idle group's carrying cost follows ownership.
                    const int64_t share = group.filled_owner > 0
                        ? mul_div_sat(net, std::max<int64_t>(0, ownership.filled_owner),
                                      group.filled_owner, sat)
                        : mul_div_sat(net, std::max<int64_t>(0, ownership.owned_count),
                                      group.count, sat);
                    if (share == 0) continue;
                    for (int32_t q = _family_cohort_offsets[owner_slot];
                         q < _family_cohort_offsets[owner_slot + 1]; ++q) {
                        const int32_t edge = _family_cohort_edge_indices[q];
                        if (family_memberships()[edge].family_handle !=
                                ownership.family_handle) continue;
                        _family_ledger_business_by_edge[edge] = saturating_add(
                            _family_ledger_business_by_edge[edge], share, sat);
                        break;
                    }
                }
            }
        }
    }
    _saturation_count = saturating_add(_saturation_count, sat, _saturation_count);
}

void NativeEconomyRuntime::recruit_family_dependents() {
    if (_family_runtime_mode.get() != 2 || _family_demography_rows.empty() ||
        _family_member_offsets.size() != families_store().active.size() + 1) return;
    const int32_t review_days = std::max(1, _family_review_days.get());
    const int64_t day_phase = (_current_day.get() % review_days + review_days) % review_days;
    int64_t sat = 0;
    size_t begin = 0;
    while (begin < _family_demography_rows.size()) {
        const int32_t cell = _family_demography_rows[begin].cell;
        size_t end = begin + 1;
        while (end < _family_demography_rows.size() &&
               _family_demography_rows[end].cell == cell) ++end;
        for (size_t i = begin; i < end; ++i) {
            const FamilyDemographyRow &row = _family_demography_rows[i];
            int32_t family = -1;
            if (!families_store().valid_handle(row.family_handle, family)) continue;
            uint64_t phase_hash = mix64(static_cast<uint64_t>(families_store().stable_id[family]),
                                        static_cast<uint32_t>(cell));
            if (static_cast<int64_t>(phase_hash % static_cast<uint64_t>(review_days)) != day_phase)
                continue;
            if (row.target_share_q16 <= row.share_q16 || row.ethnic_population <= 0) continue;
            int64_t same_ethnicity_people = 0;
            for (size_t j = begin; j < end; ++j)
                if (_family_demography_rows[j].ethnicity == row.ethnicity)
                    same_ethnicity_people += _family_demography_rows[j].people;
            const int64_t room = std::max<int64_t>(0, mul_div_sat(row.ethnic_population,
                FAMILY_TARGET_SHARE_TOTAL_Q16, kQ16, sat) - same_ethnicity_people);
            int64_t want = std::min(room, mul_div_sat(mul_div_sat(row.ethnic_population,
                row.target_share_q16 - row.share_q16, kQ16, sat),
                FAMILY_RECRUIT_RATE_Q16, kQ16, sat));
            if (want <= 0) continue;
            // Dependents attach to cohorts the branch already lives in,
            // largest anonymous pool first, keeping one anonymous person.
            std::vector<std::pair<int64_t, int32_t>> pools;
            for (int32_t p = _family_member_offsets[family];
                 p < _family_member_offsets[family + 1]; ++p) {
                const FamilyMembershipEdge &edge = family_memberships()[
                    _family_member_edge_indices[p]];
                int32_t slot = -1;
                if (!population_store().valid_handle(edge.cohort_handle, slot) ||
                    population_store().page_cell[slot / COHORT_PAGE_SIZE] != cell) continue;
                const uint32_t signature = population_store().signature_id[slot];
                if (signature >= _signatures.size() ||
                    _signatures[signature].ethnicity_id != row.ethnicity) continue;
                collect_family_edges_for_cohort(slot, _family_edge_scratch);
                int64_t claimed = 0;
                for (int32_t other : _family_edge_scratch)
                    claimed += std::max<int64_t>(0, family_memberships()[other].people);
                const int64_t anonymous = std::max<int64_t>(0,
                    population_store().population[slot] - claimed - 1);
                if (anonymous > 0) pools.emplace_back(-anonymous, slot);
            }
            std::sort(pools.begin(), pools.end());
            for (const auto &pool : pools) {
                if (want <= 0) break;
                const int64_t take = std::min(want, -pool.first);
                add_family_household_people(row.family_handle, pool.second, take);
                want -= take;
                _family_people_recruited += take;
            }
        }
        begin = end;
    }
}

void NativeEconomyRuntime::release_unstaffable_family_ownership(int32_t family_index) {
    if (family_index < 0 ||
        _family_owned_offsets.size() != families_store().active.size() + 1) return;
    const uint64_t handle = families_store().handle_for_index(family_index);
    for (int32_t p = _family_owned_offsets[family_index];
         p < _family_owned_offsets[family_index + 1]; ++p) {
        const int32_t ownership_index = _family_owned_edge_indices[p];
        const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
            ownership_index, __FILE__, __LINE__);
        if (ownership.family_handle != handle || ownership.owned_count <= 0) continue;
        const int32_t building = building_index_for_handle(ownership.building_handle);
        if (building < 0) continue;
        const auto group = building_view(static_cast<size_t>(building));
        const int32_t owner_slot = find_cohort_slot(group.cell, group.owner_signature_id);
        int64_t members = 0;
        if (owner_slot >= 0) {
            collect_family_edges_for_cohort(owner_slot, _family_edge_scratch);
            for (int32_t edge : _family_edge_scratch)
                if (family_memberships()[edge].family_handle == handle)
                    members += std::max<int64_t>(0, family_memberships()[edge].people);
        }
        if (members > 0) continue;
        // Open owner seats plus idle members of the owner ethnicity: owner
        // hiring pulls this family first, so keep the units for that pass.
        if (group.owner_signature_id >= 0 &&
            group.owner_signature_id < static_cast<int32_t>(_signatures.size()) &&
            group.filled_owner < planned_owner_demand(group, _saturation_count)) {
            const int32_t unemployed = unemployed_signature_for_ethnicity(
                _signatures[group.owner_signature_id].ethnicity_id);
            const int32_t pool = unemployed >= 0
                ? find_cohort_slot(group.cell, unemployed) : -1;
            bool idle_members = false;
            if (pool >= 0) {
                collect_family_edges_for_cohort(pool, _family_edge_scratch);
                for (int32_t edge : _family_edge_scratch)
                    if (family_memberships()[edge].family_handle == handle &&
                        family_memberships()[edge].people > 0) {
                        idle_members = true;
                        break;
                    }
            }
            if (idle_members) {
                ++_family_release_deferred;
                continue;
            }
        }
        // Release in steps so one bad review cannot strip a branch.
        auto ownership_write = family_ownerships().edit_row(ownership_index,
                                                           market_mutation_sink());
        const int64_t owned = ownership_write[0].owned_count;
        const int64_t released = std::min(owned, std::max<int64_t>(1,
            (owned + FAMILY_RELEASE_STEP_DIVISOR - 1) / FAMILY_RELEASE_STEP_DIVISOR));
        _family_units_released += released;
        ownership_write[0].owned_count = owned - released;
        ownership_write[0].filled_owner = 0;
        _family_indices_dirty = true;
    }
}

} // namespace pk
