#pragma once

#include <cstdint>
#include <algorithm>
#include <vector>
#include "runtime_economy_population_store.h"
#include "runtime_economy_building_store.h"
#include "runtime_economy_trade_escrow_store.h"
#include "runtime_economy_family_store.h"
#include "runtime_economy_live_tables.h"
#include "runtime_economy_family_side_tables.h"

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

// Phase-2.5.1: live resource SoA (dense resource×cell stock + per-cell gen).
// Replaces the ABI9 opaque payload as the in-memory authority for the committed
// mirror; ECP ABI9 still packs these columns to/from wire bytes.
struct RuntimeEconomyResourceStore {
    int32_t resource_count = 0;
    int32_t cell_count = 0;
    std::vector<int64_t> stock;
    std::vector<uint32_t> cell_generation;
    // A+Y N9: epoch harvest scratch, parallel to `stock`. These lanes are the
    // live home for NativeEconomyRuntime's per-epoch remaining/harvest/delta
    // bookkeeping while the store is bound, so there is no second copy. They
    // are deliberately absent from the ABI9 wire, `wire_content_hash()` and
    // `shape_valid()`, which stay stock + cell_generation only.
    std::vector<int64_t> remaining;
    std::vector<int64_t> harvest_remaining;
    std::vector<int64_t> deltas;
    std::vector<uint32_t> lane_generation;

    void clear() noexcept;
    void resize(int32_t resources, int32_t cells);
    uint32_t lane_count() const noexcept {
        return static_cast<uint32_t>(stock.size());
    }
    bool shape_valid(uint32_t expected_lanes) const noexcept;
    // Pack / unpack the historical ABI9 opaque wire layout
    // (int64 stock lanes + uint32 cell gens).
    void append_wire(std::vector<uint8_t> &out) const;
    bool load_wire(const uint8_t *data, size_t size, uint32_t expected_lanes);
    uint64_t wire_content_hash() const noexcept;

    int64_t index(int32_t resource, int32_t cell) const {
        return static_cast<int64_t>(resource) * cell_count + cell;
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
// Phase-2.5.1: resource payload unpacked into RuntimeEconomyResourceStore SoA.
// Phase-2.5.2: building payload unpacked into RuntimeEconomyBuildingStore SoA;
// ECP ABI7 wire remains packed bytes for save compatibility.
// Phase-2.5.3: trade-escrow payload unpacked into RuntimeEconomyTradeEscrowStore;
// ECP ABI7 wire remains packed bytes for save compatibility.
// Phase-2.5.5: family payload unpacked into RuntimeEconomyFamilyStore SoA;
// ECP ABI8 wire remains packed bytes for save compatibility.
struct RuntimeEconomyBuildingCommittedBlock {
    bool captured = false;
    uint64_t catalog_hash = 0;
    uint64_t content_hash = 0;
    uint32_t group_count = 0;
    uint32_t pending_count = 0;
    uint32_t role_lane_count = 0;
    // Phase-2.5.2: typed SoA (was ABI7 opaque payload).
    RuntimeEconomyBuildingStore store;

    void clear() noexcept {
        captured = false;
        catalog_hash = 0;
        content_hash = 0;
        group_count = 0;
        pending_count = 0;
        role_lane_count = 0;
        store.clear();
    }
    void sync_counts_from_store() noexcept {
        group_count = store.num_groups();
        pending_count = store.num_pending();
        role_lane_count = store.num_role_lanes();
    }
    void recompute_content_hash() noexcept {
        content_hash = store.wire_content_hash();
    }
    bool valid() const noexcept {
        if (!captured) return true;
        return store.shape_valid(group_count, pending_count, role_lane_count);
    }
};

struct RuntimeEconomyTradeEscrowCommittedBlock {
    bool captured = false;
    uint64_t country_trade_revision = 0;
    int64_t next_id = 1;
    uint32_t order_count = 0;
    uint64_t content_hash = 0;
    // Phase-2.5.3: typed SoA (was ABI7 opaque payload).
    RuntimeEconomyTradeEscrowStore store;

    void clear() noexcept {
        captured = false;
        country_trade_revision = 0;
        next_id = 1;
        order_count = 0;
        content_hash = 0;
        store.clear();
    }
    void sync_counts_from_store() noexcept {
        order_count = store.num_orders();
    }
    void recompute_content_hash() noexcept {
        content_hash = store.wire_content_hash();
    }
    bool valid() const noexcept {
        if (!captured) return true;
        return store.shape_valid(order_count);
    }
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
    // Phase-2.5.5: typed SoA (was ABI8 opaque payload).
    RuntimeEconomyFamilyStore store;

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
        store.clear();
    }
    void sync_counts_from_store() noexcept {
        family_count = store.num_families();
        membership_count = store.num_memberships();
        ownership_count = store.num_ownerships();
        person_count = store.num_persons();
        person_need_count = store.num_person_needs();
        trait_count = store.num_traits();
        influence_count = store.num_influences();
        trait_command_count = store.num_trait_commands();
        expedition_count = store.num_expeditions();
    }
    void recompute_content_hash() noexcept {
        content_hash = store.wire_content_hash();
    }
    bool valid() const noexcept {
        if (!captured) return true;
        return store.shape_valid(
            family_count, membership_count, ownership_count, person_count,
            person_need_count, trait_count, influence_count,
            trait_command_count, expedition_count);
    }
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
    // Phase-2.5.1: typed SoA (was ABI9 opaque payload).
    RuntimeEconomyResourceStore store;

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
        store.clear();
    }
    void sync_counts_from_store() noexcept {
        resource_count = store.resource_count;
        cell_count = store.cell_count;
        lane_count = store.lane_count();
    }
    void recompute_content_hash() noexcept {
        content_hash = store.wire_content_hash();
    }
    bool valid() const noexcept {
        if (!captured) return true;
        if (resource_count < 0 || cell_count < 0) return false;
        if (store.resource_count != resource_count ||
            store.cell_count != cell_count) {
            return false;
        }
        return store.shape_valid(lane_count);
    }
};

// Phase-2.5.4: epoch-cursor idle marker unpacked from ABI9 opaque payload.
// Mid-epoch resume blobs remain future work; committed-day mirror is idle-only.
struct RuntimeEconomyEpochCursorStore {
    uint8_t idle_marker = 0;

    void clear() noexcept { idle_marker = 0; }
    void append_wire(std::vector<uint8_t> &out) const {
        out.push_back(idle_marker);
    }
    bool load_wire(const uint8_t *data, size_t size) {
        if (size != 1 || data == nullptr) return false;
        idle_marker = data[0];
        return true;
    }
    uint64_t wire_content_hash() const noexcept {
        constexpr uint64_t kFnvOffset = 1469598103934665603ull;
        constexpr uint64_t kFnvPrime = 1099511628211ull;
        uint64_t hash = kFnvOffset;
        hash ^= idle_marker;
        hash *= kFnvPrime;
        return hash;
    }
    bool shape_valid() const noexcept { return true; }
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
    // Phase-2.5.4: typed idle marker (was ABI9 opaque payload).
    RuntimeEconomyEpochCursorStore store;

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
        store.clear();
    }
    void recompute_content_hash() noexcept {
        content_hash = store.wire_content_hash();
    }
    bool valid() const noexcept {
        if (!captured) return true;
        return store.shape_valid();
    }
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
    bool valid(const char **reason = nullptr) const noexcept;
};

// Mirrors NativeEconomyRuntime::StructuralCommand for OwnedState queues.
struct RuntimeEconomyOwnedStructuralCommand {
    int32_t opcode = 0;
    int32_t source_slot = -1;
    int32_t cell = -1;
    int32_t signature = -1;
    int64_t population = 0;
    int64_t funds = 0;
    int64_t sequence = 0;
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
    // Phase-2.5.2: live building SoA view (mirrors building.store when captured).
    RuntimeEconomyBuildingStore buildings;
    RuntimeEconomyTradeEscrowCommittedBlock trade_escrow;
    // Phase-2.5.3: ECP trade-escrow projection (packed from live_trade_orders).
    RuntimeEconomyTradeEscrowStore trade_orders;
    RuntimeEconomyFamilyCommittedBlock family;
    // Phase-2.5.5: ECP family projection (packed from live_families).
    RuntimeEconomyFamilyStore families;
    // A+Y N3/N4: live trade/family authority. NativeEconomyRuntime aliases
    // these through trade_orders_store()/families_store() while bound; its
    // own locals are only the unbound fallback.
    EconomyTradeOrderStore live_trade_orders;
    EconomyFamilyStore live_families;
    // A+Y N5: live notable-family side tables. Same rule as live_families —
    // NativeEconomyRuntime aliases these through persons_store(),
    // family_memberships(), family_expeditions_store(), ... while bound.
    // Derived CSR rebuild caches over these rows stay NER-local.
    EconomyNotablePersonStore live_persons;
    std::vector<EconomyFamilyMembershipEdge> live_memberships;
    std::vector<EconomyFamilyBuildingOwnership> live_ownerships;
    EconomyFamilyExpeditionStore live_expeditions;
    std::vector<int32_t> live_expedition_route_cells;
    std::vector<int32_t> live_expedition_route_costs;
    std::vector<EconomyFamilyExpeditionPayload> live_expedition_payloads;
    std::vector<uint64_t> live_expedition_person_handles;
    std::vector<EconomyFamilyExpeditionCargoLine> live_expedition_cargo;
    std::vector<EconomyFamilyExpeditionKitBuilding> live_expedition_kit_buildings;
    std::vector<int32_t> live_expedition_missing_good_ids;
    std::vector<int64_t> live_expedition_missing_good_quantities;
    EconomyFamilyCellInfluenceStore live_influences;
    std::vector<EconomyFamilyTraitRoll> live_traits;
    std::vector<EconomyPersonNeedState> live_person_needs;
    RuntimeEconomyResourceCommittedBlock resource;
    // Phase-2.5.1: live resource SoA view (mirrors resource.store when captured).
    RuntimeEconomyResourceStore resources;
    RuntimeEconomyEpochCursorCommittedBlock epoch_cursor;
    // Phase-2.5.4: live epoch-cursor view (mirrors epoch_cursor.store).
    RuntimeEconomyEpochCursorStore epoch_cursors;
    uint64_t state_generation = 0;
    int64_t sample_day = -1;
    int64_t committed_day = -1;
    // Phase-3: population command side effects mirrored before NER pull.
    int64_t external_population_delta = 0;
    std::vector<RuntimeEconomyOwnedStructuralCommand> structural_commands;

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
        buildings.clear();
        trade_escrow.clear();
        trade_orders.clear();
        live_trade_orders.clear();
        family.clear();
        families.clear();
        live_families.clear();
        live_persons.clear();
        live_memberships.clear();
        live_ownerships.clear();
        live_expeditions.clear();
        live_expedition_route_cells.clear();
        live_expedition_route_costs.clear();
        live_expedition_payloads.clear();
        live_expedition_person_handles.clear();
        live_expedition_cargo.clear();
        live_expedition_kit_buildings.clear();
        live_expedition_missing_good_ids.clear();
        live_expedition_missing_good_quantities.clear();
        live_influences.clear();
        live_traits.clear();
        live_person_needs.clear();
        resource.clear();
        resources.clear();
        epoch_cursor.clear();
        epoch_cursors.clear();
        state_generation = 0;
        sample_day = -1;
        committed_day = -1;
        external_population_delta = 0;
        structural_commands.clear();
    }
};

} // namespace pk
