#pragma once

#include <cstdint>
#include <vector>

namespace pk {

// A+Y N3/N4: live trade-order and family identity tables.
//
// These were nested inside NativeEconomyRuntime. They are freestanding so
// RuntimeEconomyOwnedState can own the live instances; NativeEconomyRuntime
// aliases them through trade_orders_store()/families_store() whenever a
// formula OwnedState is bound, exactly like population/market.
//
// The ECP projections (RuntimeEconomyTradeEscrowStore /
// RuntimeEconomyFamilyStore) remain separate wire-facing mirrors packed from
// these live tables at flush/capture time.

// Live in-flight trade orders (CSR lines + CSR seller attribution).
struct EconomyTradeOrderStore {
    enum State : uint8_t { IN_TRANSIT = 0, WAITING_RECEIVER = 1 };
    std::vector<int64_t> ids;
    std::vector<int32_t> sources;
    std::vector<int32_t> destinations;
    std::vector<int32_t> countries;
    std::vector<uint64_t> source_country_handles;
    std::vector<uint64_t> destination_country_handles;
    std::vector<int32_t> source_country_slots;
    std::vector<int32_t> destination_country_slots;
    std::vector<int64_t> departure_days;
    std::vector<int64_t> arrival_days;
    std::vector<int64_t> cash_escrow;
    std::vector<int64_t> capacity_work;
    std::vector<uint8_t> states;
    std::vector<uint8_t> cargo_delivered;
    std::vector<int32_t> line_offsets;
    std::vector<int32_t> line_goods;
    std::vector<int64_t> line_quantities;
    std::vector<int32_t> line_unit_prices;
    std::vector<int32_t> line_destination_prices;
    std::vector<int64_t> line_base_values;
    std::vector<int64_t> line_retail_values;
    std::vector<int64_t> line_import_transfers;
    std::vector<int64_t> line_export_transfers;
    std::vector<int64_t> line_transaction_transfers;
    std::vector<uint8_t> line_flags;
    std::vector<int32_t> seller_offsets;
    std::vector<uint64_t> seller_handles;
    std::vector<int64_t> seller_weights;
    // Derived CSR time buckets — runtime-only cache for due-order scans.
    // NOT ECP1 / wire_content_hash authority: append_wire and committed
    // capture hash order SoA columns only; arrival_days[] is the persisted
    // schedule. Rebuilt after dispatch, compaction, and restore.
    std::vector<int64_t> arrival_bucket_days;
    std::vector<int32_t> arrival_bucket_offsets;
    std::vector<int32_t> arrival_bucket_orders;
    bool arrival_buckets_dirty = true;
    int64_t next_id = 1;

    void clear() {
        ids.clear(); sources.clear(); destinations.clear(); countries.clear();
        source_country_handles.clear(); destination_country_handles.clear();
        source_country_slots.clear(); destination_country_slots.clear();
        departure_days.clear(); arrival_days.clear(); cash_escrow.clear();
        capacity_work.clear(); states.clear(); cargo_delivered.clear();
        line_offsets.assign(1, 0); line_goods.clear(); line_quantities.clear();
        line_unit_prices.clear(); line_destination_prices.clear();
        line_base_values.clear(); line_retail_values.clear();
        line_import_transfers.clear(); line_export_transfers.clear();
        line_transaction_transfers.clear();
        line_flags.clear(); seller_offsets.assign(1, 0);
        seller_handles.clear(); seller_weights.clear();
        arrival_bucket_days.clear(); arrival_bucket_offsets.assign(1, 0);
        arrival_bucket_orders.clear(); arrival_buckets_dirty = true;
        next_id = 1;
    }
    int32_t size() const { return static_cast<int32_t>(ids.size()); }
};

// Live family identity table (generation-stamped handle slots).
struct EconomyFamilyStore {
    std::vector<uint8_t> active;
    std::vector<uint32_t> generation;
    std::vector<int64_t> stable_id;
    std::vector<int32_t> surname_id;
    std::vector<uint32_t> surname_disambiguator;
    std::vector<int64_t> founded_day;
    std::vector<int32_t> home_cell;
    std::vector<int32_t> origin_cell;
    std::vector<int32_t> origin_ethnicity;
    std::vector<int32_t> culture_group_id;
    std::vector<uint32_t> split_sequence;
    std::vector<uint16_t> decline_reviews;
    std::vector<uint16_t> flags;
    std::vector<int32_t> free_indices;
    int64_t active_count = 0;

    void clear();
    int32_t allocate();
    void release(int32_t index);
    uint64_t handle_for_index(int32_t index) const;
    bool valid_handle(uint64_t handle, int32_t &index_out) const;
};

} // namespace pk
