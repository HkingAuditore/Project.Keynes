#pragma once

#include <cstdint>
#include <vector>

namespace pk {

// Phase-2.5.3: live trade-escrow SoA for the committed ledger mirror.
// Order header SoA + CSR line/seller lanes. ECP ABI7 wire remains the historical
// packed layout (per-order header + nested lines + sellers).
// NativeEconomyRuntime::TradeOrderStore arrival_bucket_* vectors are a separate
// derived cache and are never serialized or hashed — wire_content_hash() here
// covers committed order columns only.
struct RuntimeEconomyTradeEscrowStore {
    // --- order SoA ---
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
    std::vector<int32_t> line_count;
    std::vector<int32_t> line_begin;
    std::vector<int32_t> seller_count;
    std::vector<int32_t> seller_begin;

    // --- line SoA ---
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

    // --- seller SoA ---
    std::vector<uint64_t> seller_handles;
    std::vector<int64_t> seller_weights;

    void clear() noexcept;
    uint32_t num_orders() const noexcept {
        return static_cast<uint32_t>(ids.size());
    }
    uint32_t num_lines() const noexcept {
        return static_cast<uint32_t>(line_goods.size());
    }
    uint32_t num_sellers() const noexcept {
        return static_cast<uint32_t>(seller_handles.size());
    }
    bool shape_valid(uint32_t expected_orders) const noexcept;
    void append_wire(std::vector<uint8_t> &out) const;
    bool load_wire(const uint8_t *data, size_t size, uint32_t expected_orders);
    uint64_t wire_content_hash() const noexcept;
    uint64_t mix_wire_hash(uint64_t hash) const noexcept;

private:
    template <typename Sink> void visit_wire(Sink &out) const;
};

} // namespace pk
