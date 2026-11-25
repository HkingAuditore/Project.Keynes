#include "economy_runtime.h"
#include "country_api.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <set>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

Dictionary NativeEconomyRuntime::trade_orders_for_cell(
        int32_t cell_idx, int32_t offset, int32_t limit,
        int32_t good_index) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count.get()) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const int32_t good_count = market_store().good_count.get();
    if (good_index < -1 || good_index >= good_count) {
        out["ok"] = false;
        out["reason"] = "good_out_of_range";
        return out;
    }
    offset = std::max(0, offset);
    limit = std::clamp(limit, 1, 256);
    // The order store is bounded by EconomyProfile.trade_max_orders. Collect
    // matching indices once, then page the stable (arrival_day, id) ordering so
    // repeated and filtered queries stay deterministic and bounded.
    std::vector<int32_t> matches;
    matches.reserve(static_cast<size_t>(std::max(0, trade_orders_store().size())));
    for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
        const bool outbound = trade_orders_store().sources[order] == cell_idx;
        const bool inbound = trade_orders_store().destinations[order] == cell_idx;
        if (!outbound && !inbound) continue;
        if (good_index >= 0) {
            bool has_good = false;
            for (int32_t line = trade_orders_store().line_offsets[order];
                 line < trade_orders_store().line_offsets[order + 1]; ++line) {
                if (trade_orders_store().line_goods[line] == good_index) {
                    has_good = true;
                    break;
                }
            }
            if (!has_good) continue;
        }
        matches.push_back(order);
    }
    std::stable_sort(matches.begin(), matches.end(),
        [this](int32_t lhs, int32_t rhs) {
            const int64_t lhs_arrival = trade_orders_store().arrival_days[lhs];
            const int64_t rhs_arrival = trade_orders_store().arrival_days[rhs];
            if (lhs_arrival != rhs_arrival) return lhs_arrival < rhs_arrival;
            return trade_orders_store().ids[lhs] < trade_orders_store().ids[rhs];
        });
    const int32_t total = static_cast<int32_t>(matches.size());
    const int32_t page_begin = std::min(offset, total);
    const int32_t end = std::min(total, page_begin + limit);
    PackedInt64Array order_ids;
    PackedInt32Array directions;
    PackedInt32Array sources;
    PackedInt32Array destinations;
    PackedInt32Array countries;
    PackedInt64Array source_country_handles;
    PackedInt64Array destination_country_handles;
    PackedInt32Array source_country_slots;
    PackedInt32Array destination_country_slots;
    PackedInt64Array departure_days;
    PackedInt64Array arrival_days;
    PackedInt64Array base_cash;
    PackedInt64Array cash_escrow;
    PackedInt64Array capacity_work;
    PackedByteArray order_flags;
    PackedByteArray states;
    PackedByteArray cargo_delivered;
    PackedInt32Array line_offsets;
    PackedInt32Array line_goods;
    PackedInt64Array line_quantities;
    PackedInt32Array line_unit_prices;
    PackedInt32Array line_destination_prices;
    PackedInt64Array line_base_values;
    PackedInt64Array line_retail_values;
    PackedInt64Array line_import_transfers;
    PackedInt64Array line_export_transfers;
    PackedInt64Array line_transaction_transfers;
    PackedByteArray line_flags;
    line_offsets.push_back(0);
    for (int32_t position = page_begin; position < end; ++position) {
        const int32_t order = matches[static_cast<size_t>(position)];
        const bool outbound = trade_orders_store().sources[order] == cell_idx;
        order_ids.push_back(trade_orders_store().ids[order]);
        directions.push_back(outbound ? -1 : 1);
        sources.push_back(trade_orders_store().sources[order]);
        destinations.push_back(trade_orders_store().destinations[order]);
        countries.push_back(trade_orders_store().countries[order]);
        source_country_handles.push_back(
            static_cast<int64_t>(trade_orders_store().source_country_handles[order]));
        destination_country_handles.push_back(
            static_cast<int64_t>(trade_orders_store().destination_country_handles[order]));
        source_country_slots.push_back(trade_orders_store().source_country_slots[order]);
        destination_country_slots.push_back(
            trade_orders_store().destination_country_slots[order]);
        departure_days.push_back(trade_orders_store().departure_days[order]);
        arrival_days.push_back(trade_orders_store().arrival_days[order]);
        int64_t order_base = 0;
        int64_t query_saturation = 0;
        uint8_t combined_flags = 0;
        cash_escrow.push_back(trade_orders_store().cash_escrow[order]);
        capacity_work.push_back(trade_orders_store().capacity_work[order]);
        states.push_back(trade_orders_store().states[order]);
        cargo_delivered.push_back(trade_orders_store().cargo_delivered[order]);
        for (int32_t line = trade_orders_store().line_offsets[order];
             line < trade_orders_store().line_offsets[order + 1]; ++line) {
            if (good_index >= 0 &&
                trade_orders_store().line_goods[line] != good_index) continue;
            line_goods.push_back(trade_orders_store().line_goods[line]);
            line_quantities.push_back(trade_orders_store().line_quantities[line]);
            line_unit_prices.push_back(trade_orders_store().line_unit_prices[line]);
            line_destination_prices.push_back(
                trade_orders_store().line_destination_prices[line]);
            line_base_values.push_back(trade_orders_store().line_base_values[line]);
            line_retail_values.push_back(trade_orders_store().line_retail_values[line]);
            line_import_transfers.push_back(
                trade_orders_store().line_import_transfers[line]);
            line_export_transfers.push_back(
                trade_orders_store().line_export_transfers[line]);
            line_transaction_transfers.push_back(
                trade_orders_store().line_transaction_transfers[line]);
            line_flags.push_back(trade_orders_store().line_flags[line]);
            order_base = saturating_add(order_base,
                trade_orders_store().line_base_values[line], query_saturation);
            combined_flags |= trade_orders_store().line_flags[line];
        }
        base_cash.push_back(order_base);
        order_flags.push_back(combined_flags);
        line_offsets.push_back(line_goods.size());
    }
    out["ok"] = true;
    out["offset"] = offset;
    out["limit"] = limit;
    out["page_begin"] = page_begin;
    out["total"] = total;
    out["has_more"] = end < total;
    out["economy_generation"] = static_cast<int64_t>(_committed_generation);
    out["sample_day"] = static_cast<int64_t>(_sample_day);
    out["good_index"] = good_index;
    out["order_ids"] = order_ids;
    out["directions"] = directions;
    out["source_cells"] = sources;
    out["destination_cells"] = destinations;
    out["country_slots"] = countries;
    out["source_country_handles"] = source_country_handles;
    out["destination_country_handles"] = destination_country_handles;
    out["source_country_slots"] = source_country_slots;
    out["destination_country_slots"] = destination_country_slots;
    out["departure_days"] = departure_days;
    out["arrival_days"] = arrival_days;
    out["base_cash"] = base_cash;
    out["cash_escrow"] = cash_escrow;
    out["capacity_work"] = capacity_work;
    out["order_flags"] = order_flags;
    out["states"] = states;
    out["cargo_delivered"] = cargo_delivered;
    out["line_offsets"] = line_offsets;
    out["line_good_ids"] = line_goods;
    out["line_quantities"] = line_quantities;
    out["line_unit_prices"] = line_unit_prices;
    out["line_destination_prices"] = line_destination_prices;
    out["line_base_values"] = line_base_values;
    out["line_retail_values"] = line_retail_values;
    out["line_import_transfers"] = line_import_transfers;
    out["line_export_transfers"] = line_export_transfers;
    out["line_transaction_transfers"] = line_transaction_transfers;
    out["line_flags"] = line_flags;
    return out;
}

} // namespace pk
