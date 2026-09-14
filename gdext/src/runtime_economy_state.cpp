#include "runtime_economy_state.h"
#include <cstddef>

namespace pk {
void RuntimeEconomyMarketStore::clear() {
    market_count = 0;
    good_count = 0;
    stock.clear();
    price.clear();
    demand_ema.clear();
    last_shortage_q16.clear();
    cell_to_market.clear();
    price_ceilings.clear();
}

namespace {
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t mix(uint64_t hash, uint64_t value) noexcept {
    hash ^= value;
    return hash * FNV_PRIME;
}

template <typename T>
void mix_vector(uint64_t &hash, const std::vector<T> &values) noexcept {
    hash = mix(hash, values.size());
    for (const T value : values)
        hash = mix(hash, static_cast<uint64_t>(value));
}
} // namespace

void RuntimeEconomyLedgerState::clear() noexcept {
    source_state_hash = 0;
    ledger_hash = 0;
    generation = 0;
    committed_day = -1;
    market_count = 0;
    good_count = 0;
    cohort_active.clear();
    cohort_cell.clear();
    cohort_slot.clear();
    cohort_signature_id.clear();
    cohort_generation.clear();
    cohort_reserved.clear();
    cohort_reservation_owner.clear();
    cohort_population.clear();
    cohort_funds.clear();
    cohort_epoch_income.clear();
    cohort_epoch_expense.clear();
    cohort_needs_satisfaction.clear();
    cohort_composite_satisfaction.clear();
    cohort_owner_employed.clear();
    cohort_employee_employed.clear();
    market_stock.clear();
    market_price.clear();
    market_demand_ema.clear();
    market_last_shortage_q16.clear();
    market_cell_to_market.clear();
    building.clear();
    trade_escrow.clear();
    family.clear();
    resource.clear();
    epoch_cursor.clear();
}

bool RuntimeEconomyLedgerState::has_extended_columns() const noexcept {
    return !cohort_generation.empty() || !market_last_shortage_q16.empty() ||
           !market_cell_to_market.empty();
}

bool RuntimeEconomyLedgerState::has_diagnostics_columns() const noexcept {
    return !cohort_reserved.empty() || !cohort_reservation_owner.empty() ||
           !cohort_needs_satisfaction.empty() ||
           !cohort_composite_satisfaction.empty() ||
           !cohort_owner_employed.empty() || !cohort_employee_employed.empty();
}

bool RuntimeEconomyLedgerState::valid() const noexcept {
    if (generation == 0 || committed_day < 0 || market_count < 0 || good_count < 0)
        return false;
    const std::size_t cohorts = cohort_active.size();
    const std::size_t market_lanes = static_cast<std::size_t>(market_count) *
        static_cast<std::size_t>(good_count);
    if (!(cohort_cell.size() == cohorts &&
          cohort_slot.size() == cohorts &&
          cohort_signature_id.size() == cohorts &&
          cohort_population.size() == cohorts && cohort_funds.size() == cohorts &&
          cohort_epoch_income.size() == cohorts &&
          cohort_epoch_expense.size() == cohorts &&
          market_stock.size() == market_lanes && market_price.size() == market_lanes &&
          market_demand_ema.size() == market_lanes)) {
        return false;
    }
    if (has_extended_columns()) {
        if (!(cohort_generation.size() == cohorts &&
              market_last_shortage_q16.size() == market_lanes &&
              market_cell_to_market.size() ==
                  static_cast<std::size_t>(market_count))) {
            return false;
        }
    }
    if (has_diagnostics_columns()) {
        if (!(cohort_reserved.size() == cohorts &&
              cohort_reservation_owner.size() == cohorts &&
              cohort_needs_satisfaction.size() == cohorts &&
              cohort_composite_satisfaction.size() == cohorts &&
              cohort_owner_employed.size() == cohorts &&
              cohort_employee_employed.size() == cohorts)) {
            return false;
        }
    }
    if (!building.valid() || !trade_escrow.valid() || !family.valid() ||
        !resource.valid() || !epoch_cursor.valid())
        return false;
    // ABI7 requires both building and trade blocks together (all-or-nothing).
    if (building.captured != trade_escrow.captured) return false;
    // ABI8 family requires the ABI7 building/trade pair.
    if (family.captured && !building.captured) return false;
    // ABI9 resource + epoch-cursor are paired and require ABI8 family.
    if (resource.captured != epoch_cursor.captured) return false;
    if (resource.captured && !family.captured) return false;
    return true;
}

uint64_t RuntimeEconomyLedgerState::computed_hash() const noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = mix(hash, generation);
    hash = mix(hash, static_cast<uint64_t>(committed_day));
    hash = mix(hash, static_cast<uint32_t>(market_count));
    hash = mix(hash, static_cast<uint32_t>(good_count));
    mix_vector(hash, cohort_active);
    mix_vector(hash, cohort_cell);
    mix_vector(hash, cohort_slot);
    mix_vector(hash, cohort_signature_id);
    mix_vector(hash, cohort_generation);
    mix_vector(hash, cohort_reserved);
    mix_vector(hash, cohort_reservation_owner);
    mix_vector(hash, cohort_population);
    mix_vector(hash, cohort_funds);
    mix_vector(hash, cohort_epoch_income);
    mix_vector(hash, cohort_epoch_expense);
    mix_vector(hash, cohort_needs_satisfaction);
    mix_vector(hash, cohort_composite_satisfaction);
    mix_vector(hash, cohort_owner_employed);
    mix_vector(hash, cohort_employee_employed);
    mix_vector(hash, market_stock);
    mix_vector(hash, market_price);
    mix_vector(hash, market_demand_ema);
    mix_vector(hash, market_last_shortage_q16);
    mix_vector(hash, market_cell_to_market);
    hash = mix(hash, building.captured ? 1u : 0u);
    hash = mix(hash, building.catalog_hash);
    hash = mix(hash, building.content_hash);
    hash = mix(hash, building.group_count);
    hash = mix(hash, building.pending_count);
    hash = mix(hash, building.role_lane_count);
    mix_vector(hash, building.payload);
    hash = mix(hash, trade_escrow.captured ? 1u : 0u);
    hash = mix(hash, trade_escrow.country_trade_revision);
    hash = mix(hash, static_cast<uint64_t>(trade_escrow.next_id));
    hash = mix(hash, trade_escrow.order_count);
    hash = mix(hash, trade_escrow.content_hash);
    mix_vector(hash, trade_escrow.payload);
    hash = mix(hash, family.captured ? 1u : 0u);
    hash = mix(hash, family.catalog_hash);
    hash = mix(hash, family.person_catalog_hash);
    hash = mix(hash, family.trait_catalog_hash);
    hash = mix(hash, static_cast<uint64_t>(family.runtime_mode));
    hash = mix(hash, static_cast<uint64_t>(family.person_runtime_mode));
    hash = mix(hash, family.family_count);
    hash = mix(hash, family.membership_count);
    hash = mix(hash, family.ownership_count);
    hash = mix(hash, family.person_count);
    hash = mix(hash, family.person_need_count);
    hash = mix(hash, family.trait_count);
    hash = mix(hash, family.influence_count);
    hash = mix(hash, family.trait_command_count);
    hash = mix(hash, family.expedition_count);
    hash = mix(hash, static_cast<uint64_t>(family.next_expedition_stable_id));
    hash = mix(hash, family.content_hash);
    mix_vector(hash, family.payload);
    hash = mix(hash, resource.captured ? 1u : 0u);
    hash = mix(hash, resource.catalog_hash);
    hash = mix(hash, resource.environment_hash);
    hash = mix(hash, static_cast<uint64_t>(resource.context_day));
    hash = mix(hash, static_cast<uint64_t>(resource.resource_count));
    hash = mix(hash, static_cast<uint64_t>(resource.cell_count));
    hash = mix(hash, resource.lane_count);
    hash = mix(hash, static_cast<uint64_t>(resource.min_reserve_q16));
    hash = mix(hash, static_cast<uint64_t>(resource.safe_harvest_q16));
    hash = mix(hash, static_cast<uint64_t>(resource.min_horizon_days));
    hash = mix(hash, resource.content_hash);
    mix_vector(hash, resource.payload);
    hash = mix(hash, epoch_cursor.captured ? 1u : 0u);
    hash = mix(hash, static_cast<uint64_t>(epoch_cursor.sample_day));
    hash = mix(hash, static_cast<uint64_t>(epoch_cursor.current_day));
    hash = mix(hash, static_cast<uint64_t>(epoch_cursor.last_committed_day));
    hash = mix(hash, static_cast<uint64_t>(epoch_cursor.epoch_id));
    hash = mix(hash, static_cast<uint64_t>(epoch_cursor.epoch_days));
    hash = mix(hash, epoch_cursor.epoch_active);
    hash = mix(hash, static_cast<uint64_t>(epoch_cursor.native_stage));
    hash = mix(hash, epoch_cursor.graph_completed_mask);
    hash = mix(hash, epoch_cursor.content_hash);
    mix_vector(hash, epoch_cursor.payload);
    return hash;
}

uint64_t RuntimeEconomyLedgerState::recompute_hash() noexcept {
    const uint64_t hash = computed_hash();
    ledger_hash = hash;
    return hash;
}

} // namespace pk
