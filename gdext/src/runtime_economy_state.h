#pragma once

#include <cstdint>
#include <algorithm>
#include <vector>
#include "runtime_economy_population_store.h"

namespace pk {

struct RuntimeEconomyPriceCeilingState {
    int32_t good = -1;
    int32_t limit = 0;
    uint16_t confirmation_days = 0;
};

// Live market storage, independent of the Godot facade and formula executor.
// Preserve column order and sparse price-ceiling rows for existing PKEC I/O.
struct RuntimeEconomyMarketStore {
    int32_t market_count = 0;
    int32_t good_count = 0;
    std::vector<int64_t> stock;
    std::vector<int32_t> price;
    std::vector<int64_t> demand_ema;
    std::vector<uint16_t> last_shortage_q16;
    std::vector<int32_t> cell_to_market;
    std::vector<std::vector<RuntimeEconomyPriceCeilingState>> price_ceilings;

    void clear();
    int64_t index(int32_t market, int32_t good) const {
        return static_cast<int64_t>(market) * good_count + good;
    }
};

// Committed-only business columns shared by the legacy-to-POD migration.
// Derived CSR, catalog data, and any partially settled epoch state remain in
// their current owners until their stages move to the worker.
//
// Phase-2.1 (ECP ABI5): handle generation + market signal columns.
// Phase-2.2 (ECP ABI6): reservations + population satisfaction/employment
// diagnostics.
// Phase-2.3.1 (ECP ABI7): building + trade-escrow committed payloads (PKEC-
// equivalent opaque records).
// Phase-2.3.2 (ECP ABI8): family/person opaque committed payloads.
// Phase-2.3.3 (ECP ABI9): resource snapshot + epoch-cursor committed payloads.
struct RuntimeEconomyBuildingCommittedBlock {
    bool captured = false;
    uint64_t catalog_hash = 0;
    uint64_t content_hash = 0;
    uint32_t group_count = 0;
    uint32_t pending_count = 0;
    uint32_t role_lane_count = 0;
    // Concatenated PKEC-shaped building + pending-construction records.
    std::vector<uint8_t> payload;

    void clear() noexcept {
        captured = false;
        catalog_hash = 0;
        content_hash = 0;
        group_count = 0;
        pending_count = 0;
        role_lane_count = 0;
        payload.clear();
    }
    bool valid() const noexcept { return true; }
};

struct RuntimeEconomyTradeEscrowCommittedBlock {
    bool captured = false;
    uint64_t country_trade_revision = 0;
    int64_t next_id = 1;
    uint32_t order_count = 0;
    uint64_t content_hash = 0;
    // Concatenated PKEC-shaped trade-order records (header + lines + sellers).
    std::vector<uint8_t> payload;

    void clear() noexcept {
        captured = false;
        country_trade_revision = 0;
        next_id = 1;
        order_count = 0;
        content_hash = 0;
        payload.clear();
    }
    bool valid() const noexcept { return true; }
};

struct RuntimeEconomyFamilyCommittedBlock {
    bool captured = false;
    uint64_t catalog_hash = 0;
    uint64_t person_catalog_hash = 0;
    uint64_t trait_catalog_hash = 0;
    int32_t runtime_mode = 0;
    int32_t person_runtime_mode = 0;
    uint32_t family_count = 0;
    uint32_t membership_count = 0;
    uint32_t ownership_count = 0;
    uint32_t person_count = 0;
    uint32_t person_need_count = 0;
    uint32_t trait_count = 0;
    uint32_t influence_count = 0;
    uint32_t trait_command_count = 0;
    uint32_t expedition_count = 0;
    int64_t next_expedition_stable_id = 1;
    uint64_t content_hash = 0;
    // Concatenated PKEC-shaped family/person/expedition records.
    std::vector<uint8_t> payload;

    void clear() noexcept {
        captured = false;
        catalog_hash = 0;
        person_catalog_hash = 0;
        trait_catalog_hash = 0;
        runtime_mode = 0;
        person_runtime_mode = 0;
        family_count = 0;
        membership_count = 0;
        ownership_count = 0;
        person_count = 0;
        person_need_count = 0;
        trait_count = 0;
        influence_count = 0;
        trait_command_count = 0;
        expedition_count = 0;
        next_expedition_stable_id = 1;
        content_hash = 0;
        payload.clear();
    }
    bool valid() const noexcept { return true; }
};

struct RuntimeEconomyResourceCommittedBlock {
    bool captured = false;
    uint64_t catalog_hash = 0;
    uint64_t environment_hash = 0;
    int64_t context_day = -1;
    int32_t resource_count = 0;
    int32_t cell_count = 0;
    uint32_t lane_count = 0;
    int32_t min_reserve_q16 = 0;
    int32_t safe_harvest_q16 = 0;
    int32_t min_horizon_days = 0;
    uint64_t content_hash = 0;
    // Dense resource snapshot + per-cell generation stamps.
    std::vector<uint8_t> payload;

    void clear() noexcept {
        captured = false;
        catalog_hash = 0;
        environment_hash = 0;
        context_day = -1;
        resource_count = 0;
        cell_count = 0;
        lane_count = 0;
        min_reserve_q16 = 0;
        safe_harvest_q16 = 0;
        min_horizon_days = 0;
        content_hash = 0;
        payload.clear();
    }
    bool valid() const noexcept { return true; }
};

struct RuntimeEconomyEpochCursorCommittedBlock {
    bool captured = false;
    int64_t sample_day = -1;
    int64_t current_day = -1;
    int64_t last_committed_day = -1;
    int64_t epoch_id = 0;
    int32_t epoch_days = 0;
    uint8_t epoch_active = 0;
    int32_t native_stage = 0;
    uint32_t graph_completed_mask = 0;
    uint64_t content_hash = 0;
    // Mid-epoch resume blob; empty when committed-day idle.
    std::vector<uint8_t> payload;

    void clear() noexcept {
        captured = false;
        sample_day = -1;
        current_day = -1;
        last_committed_day = -1;
        epoch_id = 0;
        epoch_days = 0;
        epoch_active = 0;
        native_stage = 0;
        graph_completed_mask = 0;
        content_hash = 0;
        payload.clear();
    }
    bool valid() const noexcept { return true; }
};

struct RuntimeEconomyLedgerState {
    uint64_t source_state_hash = 0;
    uint64_t ledger_hash = 0;
    uint64_t generation = 0;
    int64_t committed_day = -1;
    int32_t market_count = 0;
    int32_t good_count = 0;

    std::vector<uint8_t> cohort_active;
    std::vector<int32_t> cohort_cell;
    std::vector<int32_t> cohort_slot;
    std::vector<uint32_t> cohort_signature_id;
    std::vector<uint32_t> cohort_generation;
    std::vector<uint8_t> cohort_reserved;
    std::vector<uint64_t> cohort_reservation_owner;
    std::vector<int64_t> cohort_population;
    std::vector<int64_t> cohort_funds;
    std::vector<int64_t> cohort_epoch_income;
    std::vector<int64_t> cohort_epoch_expense;
    std::vector<uint16_t> cohort_needs_satisfaction;
    std::vector<uint16_t> cohort_composite_satisfaction;
    std::vector<int64_t> cohort_owner_employed;
    std::vector<int64_t> cohort_employee_employed;
    std::vector<int64_t> market_stock;
    std::vector<int32_t> market_price;
    std::vector<int64_t> market_demand_ema;
    std::vector<uint16_t> market_last_shortage_q16;
    std::vector<int32_t> market_cell_to_market;
    RuntimeEconomyBuildingCommittedBlock building;
    RuntimeEconomyTradeEscrowCommittedBlock trade_escrow;
    RuntimeEconomyFamilyCommittedBlock family;
    RuntimeEconomyResourceCommittedBlock resource;
    RuntimeEconomyEpochCursorCommittedBlock epoch_cursor;

    void clear() noexcept;
    // True when ABI5 extended columns are populated (all-or-nothing).
    bool has_extended_columns() const noexcept;
    // True when ABI6 reservation/diagnostic columns are populated.
    bool has_diagnostics_columns() const noexcept;
    bool has_building_columns() const noexcept { return building.captured; }
    bool has_trade_escrow_columns() const noexcept {
        return trade_escrow.captured;
    }
    bool has_family_columns() const noexcept { return family.captured; }
    bool has_resource_columns() const noexcept { return resource.captured; }
    bool has_epoch_cursor_columns() const noexcept {
        return epoch_cursor.captured;
    }
    uint64_t computed_hash() const noexcept;
    uint64_t recompute_hash() noexcept;
    bool valid() const noexcept;
};

// Migration-owned state container.  During the staged migration this is an
// independent POD state, not a view into NativeEconomyRuntime.  Keeping the
// container explicit prevents a copied summary from being mistaken for an
// ownership transfer and gives the worker a stable home for future stores.
struct RuntimeEconomyOwnedState {
    RuntimeEconomyPopulationStore population;
    RuntimeEconomyMarketStore market;
    RuntimeEconomyLedgerState committed;
    RuntimeEconomyBuildingCommittedBlock building;
    RuntimeEconomyTradeEscrowCommittedBlock trade_escrow;
    RuntimeEconomyFamilyCommittedBlock family;
    RuntimeEconomyResourceCommittedBlock resource;
    RuntimeEconomyEpochCursorCommittedBlock epoch_cursor;
    uint64_t state_generation = 0;
    int64_t sample_day = -1;
    int64_t committed_day = -1;

    void clear(int32_t cells, int32_t goods) {
        population.clear(cells);
        market.clear();
        market.market_count = std::max(0, cells);
        market.good_count = std::max(0, goods);
        const size_t lanes = static_cast<size_t>(market.market_count) *
            static_cast<size_t>(market.good_count);
        market.stock.assign(lanes, 0);
        market.price.assign(lanes, 1);
        market.demand_ema.assign(lanes, 0);
        market.last_shortage_q16.assign(lanes, 0);
        market.cell_to_market.resize(static_cast<size_t>(market.market_count));
        for (int32_t cell = 0; cell < market.market_count; ++cell)
            market.cell_to_market[static_cast<size_t>(cell)] = cell;
        market.price_ceilings.resize(static_cast<size_t>(market.market_count));
        committed.clear();
        building.clear();
        trade_escrow.clear();
        family.clear();
        resource.clear();
        epoch_cursor.clear();
        state_generation = 0;
        sample_day = -1;
        committed_day = -1;
    }
};

} // namespace pk
