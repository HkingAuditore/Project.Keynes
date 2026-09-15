#include "runtime_economy_trade_escrow_store.h"

#include <cstring>

namespace pk {
namespace {

constexpr uint64_t kFnvOffset = 1469598103934665603ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

template <typename T>
void append_pod(std::vector<uint8_t> &out, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), bytes, bytes + sizeof(T));
}

template <typename T>
bool read_pod(const uint8_t *&p, const uint8_t *end, T &value) {
    if (static_cast<size_t>(end - p) < sizeof(T)) return false;
    std::memcpy(&value, p, sizeof(T));
    p += sizeof(T);
    return true;
}

template <typename T>
bool column_size(const std::vector<T> &column, size_t expected) {
    return column.size() == expected;
}

} // namespace

void RuntimeEconomyTradeEscrowStore::clear() noexcept {
    ids.clear();
    sources.clear();
    destinations.clear();
    countries.clear();
    source_country_handles.clear();
    destination_country_handles.clear();
    source_country_slots.clear();
    destination_country_slots.clear();
    departure_days.clear();
    arrival_days.clear();
    cash_escrow.clear();
    capacity_work.clear();
    states.clear();
    cargo_delivered.clear();
    line_count.clear();
    line_begin.clear();
    seller_count.clear();
    seller_begin.clear();
    line_goods.clear();
    line_quantities.clear();
    line_unit_prices.clear();
    line_destination_prices.clear();
    line_base_values.clear();
    line_retail_values.clear();
    line_import_transfers.clear();
    line_export_transfers.clear();
    line_transaction_transfers.clear();
    line_flags.clear();
    seller_handles.clear();
    seller_weights.clear();
}

bool RuntimeEconomyTradeEscrowStore::shape_valid(
        uint32_t expected_orders) const noexcept {
    const size_t orders = static_cast<size_t>(expected_orders);
    if (!(column_size(ids, orders) && column_size(sources, orders) &&
          column_size(destinations, orders) && column_size(countries, orders) &&
          column_size(source_country_handles, orders) &&
          column_size(destination_country_handles, orders) &&
          column_size(source_country_slots, orders) &&
          column_size(destination_country_slots, orders) &&
          column_size(departure_days, orders) &&
          column_size(arrival_days, orders) &&
          column_size(cash_escrow, orders) &&
          column_size(capacity_work, orders) && column_size(states, orders) &&
          column_size(cargo_delivered, orders) &&
          column_size(line_count, orders) && column_size(line_begin, orders) &&
          column_size(seller_count, orders) &&
          column_size(seller_begin, orders))) {
        return false;
    }
    const size_t lines = line_goods.size();
    if (!(column_size(line_quantities, lines) &&
          column_size(line_unit_prices, lines) &&
          column_size(line_destination_prices, lines) &&
          column_size(line_base_values, lines) &&
          column_size(line_retail_values, lines) &&
          column_size(line_import_transfers, lines) &&
          column_size(line_export_transfers, lines) &&
          column_size(line_transaction_transfers, lines) &&
          column_size(line_flags, lines))) {
        return false;
    }
    const size_t sellers = seller_handles.size();
    if (!column_size(seller_weights, sellers)) return false;

    uint32_t line_sum = 0;
    uint32_t seller_sum = 0;
    for (size_t i = 0; i < orders; ++i) {
        if (line_count[i] < 0 || seller_count[i] < 0) return false;
        if (line_begin[i] != static_cast<int32_t>(line_sum)) return false;
        if (seller_begin[i] != static_cast<int32_t>(seller_sum)) return false;
        line_sum += static_cast<uint32_t>(line_count[i]);
        seller_sum += static_cast<uint32_t>(seller_count[i]);
    }
    return line_sum == static_cast<uint32_t>(lines) &&
           seller_sum == static_cast<uint32_t>(sellers);
}

void RuntimeEconomyTradeEscrowStore::append_wire(
        std::vector<uint8_t> &out) const {
    const size_t orders = ids.size();
    for (size_t o = 0; o < orders; ++o) {
        append_pod(out, ids[o]);
        append_pod(out, sources[o]);
        append_pod(out, destinations[o]);
        append_pod(out, countries[o]);
        append_pod(out, source_country_handles[o]);
        append_pod(out, destination_country_handles[o]);
        append_pod(out, source_country_slots[o]);
        append_pod(out, destination_country_slots[o]);
        append_pod(out, departure_days[o]);
        append_pod(out, arrival_days[o]);
        append_pod(out, cash_escrow[o]);
        append_pod(out, capacity_work[o]);
        append_pod(out, states[o]);
        append_pod(out, cargo_delivered[o]);
        append_pod(out, line_count[o]);
        append_pod(out, seller_count[o]);
        const int32_t line_start = line_begin[o];
        const int32_t lines = line_count[o];
        for (int32_t i = 0; i < lines; ++i) {
            const size_t index = static_cast<size_t>(line_start + i);
            append_pod(out, line_goods[index]);
            append_pod(out, line_quantities[index]);
            append_pod(out, line_unit_prices[index]);
            append_pod(out, line_destination_prices[index]);
            append_pod(out, line_base_values[index]);
            append_pod(out, line_retail_values[index]);
            append_pod(out, line_import_transfers[index]);
            append_pod(out, line_export_transfers[index]);
            append_pod(out, line_transaction_transfers[index]);
            append_pod(out, line_flags[index]);
        }
        const int32_t seller_start = seller_begin[o];
        const int32_t sellers = seller_count[o];
        for (int32_t i = 0; i < sellers; ++i) {
            const size_t index = static_cast<size_t>(seller_start + i);
            append_pod(out, seller_handles[index]);
            append_pod(out, seller_weights[index]);
        }
    }
}

bool RuntimeEconomyTradeEscrowStore::load_wire(const uint8_t *data, size_t size,
                                               uint32_t expected_orders) {
    clear();
    if (data == nullptr && size != 0) return false;
    const uint8_t *p = data;
    const uint8_t *end = data + size;
    ids.reserve(expected_orders);
    for (uint32_t o = 0; o < expected_orders; ++o) {
        int64_t v_i64 = 0;
        int32_t v_i32 = 0;
        uint64_t v_u64 = 0;
        uint8_t v_u8 = 0;
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        ids.push_back(v_i64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        sources.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        destinations.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        countries.push_back(v_i32);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        source_country_handles.push_back(v_u64);
        if (!read_pod(p, end, v_u64)) {
            clear();
            return false;
        }
        destination_country_handles.push_back(v_u64);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        source_country_slots.push_back(v_i32);
        if (!read_pod(p, end, v_i32)) {
            clear();
            return false;
        }
        destination_country_slots.push_back(v_i32);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        departure_days.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        arrival_days.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        cash_escrow.push_back(v_i64);
        if (!read_pod(p, end, v_i64)) {
            clear();
            return false;
        }
        capacity_work.push_back(v_i64);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        states.push_back(v_u8);
        if (!read_pod(p, end, v_u8)) {
            clear();
            return false;
        }
        cargo_delivered.push_back(v_u8);
        int32_t lines = 0;
        int32_t sellers = 0;
        if (!read_pod(p, end, lines) || !read_pod(p, end, sellers) || lines < 0 ||
            sellers < 0) {
            clear();
            return false;
        }
        line_count.push_back(lines);
        line_begin.push_back(static_cast<int32_t>(line_goods.size()));
        seller_count.push_back(sellers);
        seller_begin.push_back(static_cast<int32_t>(seller_handles.size()));
        for (int32_t i = 0; i < lines; ++i) {
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            line_goods.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            line_quantities.push_back(v_i64);
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            line_unit_prices.push_back(v_i32);
            if (!read_pod(p, end, v_i32)) {
                clear();
                return false;
            }
            line_destination_prices.push_back(v_i32);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            line_base_values.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            line_retail_values.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            line_import_transfers.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            line_export_transfers.push_back(v_i64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            line_transaction_transfers.push_back(v_i64);
            if (!read_pod(p, end, v_u8)) {
                clear();
                return false;
            }
            line_flags.push_back(v_u8);
        }
        for (int32_t i = 0; i < sellers; ++i) {
            if (!read_pod(p, end, v_u64)) {
                clear();
                return false;
            }
            seller_handles.push_back(v_u64);
            if (!read_pod(p, end, v_i64)) {
                clear();
                return false;
            }
            seller_weights.push_back(v_i64);
        }
    }
    if (p != end) {
        clear();
        return false;
    }
    return shape_valid(expected_orders);
}

uint64_t RuntimeEconomyTradeEscrowStore::wire_content_hash() const noexcept {
    std::vector<uint8_t> wire;
    append_wire(wire);
    uint64_t hash = kFnvOffset;
    for (uint8_t byte : wire) {
        hash ^= byte;
        hash *= kFnvPrime;
    }
    return hash;
}

} // namespace pk
