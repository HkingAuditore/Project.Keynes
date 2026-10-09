#pragma once

#include <cstdint>
#include <vector>
#include "economy_tracked_column.h"
#include "economy_tracked_scalar.h"

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
    ChangeRegistry changes;
    enum State : uint8_t { IN_TRANSIT = 0, WAITING_RECEIVER = 1 };
    EconomyTrackedColumn<int64_t> ids;
    EconomyTrackedColumn<int32_t> sources;
    EconomyTrackedColumn<int32_t> destinations;
    EconomyTrackedColumn<int32_t> countries;
    EconomyTrackedColumn<uint64_t> source_country_handles;
    EconomyTrackedColumn<uint64_t> destination_country_handles;
    EconomyTrackedColumn<int32_t> source_country_slots;
    EconomyTrackedColumn<int32_t> destination_country_slots;
    EconomyTrackedColumn<int64_t> departure_days;
    EconomyTrackedColumn<int64_t> arrival_days;
    EconomyTrackedColumn<int64_t> cash_escrow;
    EconomyTrackedColumn<int64_t> capacity_work;
    EconomyTrackedColumn<uint8_t> states;
    EconomyTrackedColumn<uint8_t> cargo_delivered;
    EconomyTrackedColumn<int32_t> line_offsets;
    EconomyTrackedColumn<int32_t> line_goods;
    EconomyTrackedColumn<int64_t> line_quantities;
    EconomyTrackedColumn<int32_t> line_unit_prices;
    EconomyTrackedColumn<int32_t> line_destination_prices;
    EconomyTrackedColumn<int64_t> line_base_values;
    EconomyTrackedColumn<int64_t> line_retail_values;
    EconomyTrackedColumn<int64_t> line_import_transfers;
    EconomyTrackedColumn<int64_t> line_export_transfers;
    EconomyTrackedColumn<int64_t> line_transaction_transfers;
    EconomyTrackedColumn<uint8_t> line_flags;
    EconomyTrackedColumn<int32_t> seller_offsets;
    EconomyTrackedColumn<uint64_t> seller_handles;
    EconomyTrackedColumn<int64_t> seller_weights;
    // Derived CSR time buckets — runtime-only cache for due-order scans.
    // NOT ECP1 / wire_content_hash authority: append_wire and committed
    // capture hash order SoA columns only; arrival_days[] is the persisted
    // schedule. Rebuilt after dispatch, compaction, and restore.
    std::vector<int64_t> arrival_bucket_days;
    std::vector<int32_t> arrival_bucket_offsets;
    std::vector<int32_t> arrival_bucket_orders;
    bool arrival_buckets_dirty = true;
    EconomyTrackedScalar<int64_t> next_id;

    EconomyTradeOrderStore();
    EconomyTradeOrderStore(const EconomyTradeOrderStore &other);
    EconomyTradeOrderStore(EconomyTradeOrderStore &&other);
    EconomyTradeOrderStore &operator=(const EconomyTradeOrderStore &other);
    EconomyTradeOrderStore &operator=(EconomyTradeOrderStore &&other);

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
    // Canonical field traversal uses the same bindings as the writers.
    template<class Visitor> void visit_registered_columns(Visitor &&visit) const {
        visit(ids);
        visit(sources);
        visit(destinations);
        visit(countries);
        visit(source_country_handles);
        visit(destination_country_handles);
        visit(source_country_slots);
        visit(destination_country_slots);
        visit(departure_days);
        visit(arrival_days);
        visit(cash_escrow);
        visit(capacity_work);
        visit(states);
        visit(cargo_delivered);
        visit(line_offsets);
        visit(line_goods);
        visit(line_quantities);
        visit(line_unit_prices);
        visit(line_destination_prices);
        visit(line_base_values);
        visit(line_retail_values);
        visit(line_import_transfers);
        visit(line_export_transfers);
        visit(line_transaction_transfers);
        visit(line_flags);
        visit(seller_offsets);
        visit(seller_handles);
        visit(seller_weights);
        visit(next_id.column());
    }

};

// Live family identity table (generation-stamped handle slots).
struct EconomyFamilyStore {
    ChangeRegistry changes;
    EconomyTrackedColumn<uint8_t> active;
    EconomyTrackedColumn<uint32_t> generation;
    EconomyTrackedColumn<int64_t> stable_id;
    EconomyTrackedColumn<int32_t> surname_id;
    EconomyTrackedColumn<uint32_t> surname_disambiguator;
    EconomyTrackedColumn<int64_t> founded_day;
    EconomyTrackedColumn<int32_t> home_cell;
    EconomyTrackedColumn<int32_t> origin_cell;
    EconomyTrackedColumn<int32_t> origin_ethnicity;
    EconomyTrackedColumn<int32_t> culture_group_id;
    EconomyTrackedColumn<uint32_t> split_sequence;
    EconomyTrackedColumn<uint16_t> decline_reviews;
    EconomyTrackedColumn<uint16_t> flags;
    EconomyTrackedColumn<int32_t> free_indices;
    EconomyTrackedScalar<int64_t> active_count;


    EconomyFamilyStore();
    EconomyFamilyStore(const EconomyFamilyStore &other);
    EconomyFamilyStore(EconomyFamilyStore &&other);
    EconomyFamilyStore &operator=(const EconomyFamilyStore &other);
    EconomyFamilyStore &operator=(EconomyFamilyStore &&other);
    void clear();
    int32_t allocate();
    void release(int32_t index);
    uint64_t handle_for_index(int32_t index) const;
    bool valid_handle(uint64_t handle, int32_t &index_out) const;
    // Canonical field traversal uses the same bindings as the writers.
    template<class Visitor> void visit_registered_columns(Visitor &&visit) const {
        visit(active);
        visit(generation);
        visit(stable_id);
        visit(surname_id);
        visit(surname_disambiguator);
        visit(founded_day);
        visit(home_cell);
        visit(origin_cell);
        visit(origin_ethnicity);
        visit(culture_group_id);
        visit(split_sequence);
        visit(decline_reviews);
        visit(flags);
        visit(free_indices);
        visit(active_count.column());
    }

};

} // namespace pk
