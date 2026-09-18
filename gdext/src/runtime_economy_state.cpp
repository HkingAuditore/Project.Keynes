#include "runtime_economy_state.h"
#include <cstddef>
#include <cstring>

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

void RuntimeEconomyResourceStore::clear() noexcept {
    resource_count = 0;
    cell_count = 0;
    stock.clear();
    cell_generation.clear();
    remaining.clear();
    harvest_remaining.clear();
    deltas.clear();
    lane_generation.clear();
}

void RuntimeEconomyResourceStore::resize(int32_t resources, int32_t cells) {
    resource_count = std::max(0, resources);
    cell_count = std::max(0, cells);
    const size_t lanes = static_cast<size_t>(resource_count) *
        static_cast<size_t>(cell_count);
    stock.assign(lanes, 0);
    cell_generation.assign(static_cast<size_t>(cell_count), 0);
    remaining.assign(lanes, 0);
    harvest_remaining.assign(lanes, 0);
    deltas.assign(lanes, 0);
    lane_generation.assign(lanes, 0);
}

bool RuntimeEconomyResourceStore::shape_valid(
        uint32_t expected_lanes) const noexcept {
    if (resource_count < 0 || cell_count < 0) return false;
    const size_t expected =
        static_cast<size_t>(resource_count) * static_cast<size_t>(cell_count);
    if (expected_lanes != static_cast<uint32_t>(expected)) return false;
    if (stock.size() != expected) return false;
    if (cell_generation.size() != static_cast<size_t>(cell_count)) return false;
    return true;
}

void RuntimeEconomyResourceStore::append_wire(
        std::vector<uint8_t> &out) const {
    for (int64_t value : stock) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        out.insert(out.end(), bytes, bytes + sizeof(value));
    }
    for (uint32_t value : cell_generation) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        out.insert(out.end(), bytes, bytes + sizeof(value));
    }
}

bool RuntimeEconomyResourceStore::load_wire(const uint8_t *data, size_t size,
                                            uint32_t expected_lanes) {
    if (data == nullptr && size != 0) return false;
    if (resource_count < 0 || cell_count < 0) return false;
    const size_t lanes = static_cast<size_t>(resource_count) *
        static_cast<size_t>(cell_count);
    if (static_cast<uint32_t>(lanes) != expected_lanes) return false;
    const size_t expected_bytes =
        lanes * sizeof(int64_t) +
        static_cast<size_t>(cell_count) * sizeof(uint32_t);
    if (size != expected_bytes) return false;
    stock.resize(lanes);
    cell_generation.resize(static_cast<size_t>(cell_count));
    size_t offset = 0;
    for (size_t i = 0; i < lanes; ++i) {
        int64_t value = 0;
        std::memcpy(&value, data + offset, sizeof(value));
        stock[i] = value;
        offset += sizeof(value);
    }
    for (int32_t cell = 0; cell < cell_count; ++cell) {
        uint32_t value = 0;
        std::memcpy(&value, data + offset, sizeof(value));
        cell_generation[static_cast<size_t>(cell)] = value;
        offset += sizeof(value);
    }
    return offset == size;
}

uint64_t RuntimeEconomyResourceStore::wire_content_hash() const noexcept {
    constexpr uint64_t kOffset = 1469598103934665603ull;
    constexpr uint64_t kPrime = 1099511628211ull;
    uint64_t hash = kOffset;
    auto mix_bytes = [&](const uint8_t *bytes, size_t count) {
        for (size_t i = 0; i < count; ++i) {
            hash ^= bytes[i];
            hash *= kPrime;
        }
    };
    for (int64_t value : stock) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        mix_bytes(bytes, sizeof(value));
    }
    for (uint32_t value : cell_generation) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
        mix_bytes(bytes, sizeof(value));
    }
    return hash;
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
        for (std::size_t i = 0; i < cohorts; ++i) {
            if (cohort_active[i] != 0 && cohort_generation[i] == 0)
                return false;
        }
        for (const int32_t market : market_cell_to_market) {
            if (market < -1 || market >= market_count) return false;
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
        for (std::size_t i = 0; i < cohorts; ++i) {
            if (cohort_active[i] == 0) continue;
            if (cohort_reserved[i] != 0 &&
                cohort_reservation_owner[i] == 0) {
                return false;
            }
            if (cohort_owner_employed[i] < 0 ||
                cohort_employee_employed[i] < 0) {
                return false;
            }
            if (cohort_population[i] >= 0 &&
                cohort_owner_employed[i] + cohort_employee_employed[i] >
                    cohort_population[i]) {
                return false;
            }
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

    if (building.captured) {
        const auto &store = building.store;
        for (uint32_t g = 0; g < building.group_count; ++g) {
            const std::size_t gi = static_cast<std::size_t>(g);
            if (store.merchant_debt_principal[gi] < 0 ||
                store.merchant_debt_premium[gi] < 0) {
                return false;
            }
            if (store.merchant_debt_principal[gi] == 0 &&
                (store.merchant_debt_premium[gi] != 0 ||
                 store.merchant_debt_term_cycles_left[gi] != 0)) {
                return false;
            }
            if (store.employee_fill_begin[gi] < -1) return false;
            if (store.last_input_selection_begin[gi] < -1) return false;
            // Role/input spans are allocated as a pair; a half-set index is
            // never a valid committed shape. role_begin CSR monotonicity is
            // already enforced by store.shape_valid().
            if ((store.employee_fill_begin[gi] < 0) !=
                (store.last_input_selection_begin[gi] < 0)) {
                return false;
            }
            if (store.role_count[gi] < 0) return false;
        }
        for (uint32_t p = 0; p < building.pending_count; ++p) {
            const std::size_t pi = static_cast<std::size_t>(p);
            if (store.pending_merchant_debt_principal[pi] < 0 ||
                store.pending_merchant_debt_premium[pi] < 0) {
                return false;
            }
            if (store.pending_merchant_debt_principal[pi] == 0 &&
                (store.pending_merchant_debt_premium[pi] != 0 ||
                 store.pending_merchant_debt_term_cycles_left[pi] != 0)) {
                return false;
            }
        }
        if (building.content_hash != 0 &&
            building.content_hash != store.wire_content_hash()) {
            return false;
        }
    }

    if (family.captured) {
        const auto &store = family.store;
        for (std::size_t i = 0; i < store.person_family_equity_share_q32.size();
             ++i) {
            if (store.person_family_equity_share_q32[i] < 0) return false;
        }
        for (std::size_t i = 0; i < store.influence_population_share_q16.size();
             ++i) {
            if (store.influence_population_share_q16[i] < 0 ||
                store.influence_cash_share_q16[i] < 0 ||
                store.influence_building_share_q16[i] < 0) {
                return false;
            }
        }
        if (family.content_hash != 0 &&
            family.content_hash != store.wire_content_hash()) {
            return false;
        }
    }

    if (trade_escrow.captured && trade_escrow.content_hash != 0 &&
        trade_escrow.content_hash != trade_escrow.store.wire_content_hash()) {
        return false;
    }
    if (resource.captured && resource.content_hash != 0 &&
        resource.content_hash != resource.store.wire_content_hash()) {
        return false;
    }

    if (epoch_cursor.captured) {
        if (epoch_cursor.last_committed_day < 0) return false;
        if (epoch_cursor.current_day < epoch_cursor.last_committed_day)
            return false;
        if (epoch_cursor.sample_day > epoch_cursor.current_day &&
            epoch_cursor.sample_day >= 0 && epoch_cursor.current_day >= 0) {
            // sample_day may equal current_day at idle; never run ahead of
            // current_day past the committed horizon without an active epoch.
            if (epoch_cursor.epoch_active == 0 &&
                epoch_cursor.sample_day > epoch_cursor.current_day) {
                return false;
            }
        }
        if (epoch_cursor.content_hash != 0 &&
            epoch_cursor.content_hash !=
                epoch_cursor.store.wire_content_hash()) {
            return false;
        }
    }

    // committed_day on the ledger mirrors the capture stamp; it must not run
    // ahead of the epoch-cursor current day when both are present.
    if (epoch_cursor.captured && epoch_cursor.current_day >= 0 &&
        committed_day > epoch_cursor.current_day) {
        return false;
    }
    if (epoch_cursor.captured && epoch_cursor.last_committed_day >= 0 &&
        committed_day < epoch_cursor.last_committed_day) {
        return false;
    }

    if (ledger_hash != 0 && ledger_hash != computed_hash()) return false;
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
    {
        std::vector<uint8_t> building_wire;
        building.store.append_wire(building_wire);
        mix_vector(hash, building_wire);
    }
    hash = mix(hash, trade_escrow.captured ? 1u : 0u);
    hash = mix(hash, trade_escrow.country_trade_revision);
    hash = mix(hash, static_cast<uint64_t>(trade_escrow.next_id));
    hash = mix(hash, trade_escrow.order_count);
    hash = mix(hash, trade_escrow.content_hash);
    {
        std::vector<uint8_t> trade_wire;
        trade_escrow.store.append_wire(trade_wire);
        mix_vector(hash, trade_wire);
    }
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
    {
        std::vector<uint8_t> family_wire;
        family.store.append_wire(family_wire);
        mix_vector(hash, family_wire);
    }
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
    mix_vector(hash, resource.store.stock);
    mix_vector(hash, resource.store.cell_generation);
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
    {
        std::vector<uint8_t> cursor_wire;
        epoch_cursor.store.append_wire(cursor_wire);
        mix_vector(hash, cursor_wire);
    }
    return hash;
}

uint64_t RuntimeEconomyLedgerState::recompute_hash() noexcept {
    const uint64_t hash = computed_hash();
    ledger_hash = hash;
    return hash;
}

} // namespace pk
