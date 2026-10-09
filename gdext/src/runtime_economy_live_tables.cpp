#include "runtime_economy_live_tables.h"

#include <algorithm>
#include <cstdint>

namespace pk {
EconomyTradeOrderStore::EconomyTradeOrderStore()
    : next_id(changes, {{9, 1001}, "trade.next_id", EconomyFieldEncoding::I64, 8}, 1),
      ids(changes, {{9, 1}, "trade.ids", EconomyFieldEncoding::I64, 8}),
      sources(changes, {{9, 2}, "trade.sources", EconomyFieldEncoding::I32, 4}),
      destinations(changes, {{9, 3}, "trade.destinations", EconomyFieldEncoding::I32, 4}),
      countries(changes, {{9, 4}, "trade.countries", EconomyFieldEncoding::I32, 4}),
      source_country_handles(changes, {{9, 5}, "trade.source_country_handles", EconomyFieldEncoding::U64, 8}),
      destination_country_handles(changes, {{9, 6}, "trade.destination_country_handles", EconomyFieldEncoding::U64, 8}),
      source_country_slots(changes, {{9, 7}, "trade.source_country_slots", EconomyFieldEncoding::I32, 4}),
      destination_country_slots(changes, {{9, 8}, "trade.destination_country_slots", EconomyFieldEncoding::I32, 4}),
      departure_days(changes, {{9, 9}, "trade.departure_days", EconomyFieldEncoding::I64, 8}),
      arrival_days(changes, {{9, 10}, "trade.arrival_days", EconomyFieldEncoding::I64, 8}),
      cash_escrow(changes, {{9, 11}, "trade.cash_escrow", EconomyFieldEncoding::I64, 8}),
      capacity_work(changes, {{9, 12}, "trade.capacity_work", EconomyFieldEncoding::I64, 8}),
      states(changes, {{9, 13}, "trade.states", EconomyFieldEncoding::U8, 1}),
      cargo_delivered(changes, {{9, 14}, "trade.cargo_delivered", EconomyFieldEncoding::U8, 1}),
      line_offsets(changes, {{9, 15}, "trade.line_offsets", EconomyFieldEncoding::I32, 4}),
      line_goods(changes, {{9, 16}, "trade.line_goods", EconomyFieldEncoding::I32, 4}),
      line_quantities(changes, {{9, 17}, "trade.line_quantities", EconomyFieldEncoding::I64, 8}),
      line_unit_prices(changes, {{9, 18}, "trade.line_unit_prices", EconomyFieldEncoding::I32, 4}),
      line_destination_prices(changes, {{9, 19}, "trade.line_destination_prices", EconomyFieldEncoding::I32, 4}),
      line_base_values(changes, {{9, 20}, "trade.line_base_values", EconomyFieldEncoding::I64, 8}),
      line_retail_values(changes, {{9, 21}, "trade.line_retail_values", EconomyFieldEncoding::I64, 8}),
      line_import_transfers(changes, {{9, 22}, "trade.line_import_transfers", EconomyFieldEncoding::I64, 8}),
      line_export_transfers(changes, {{9, 23}, "trade.line_export_transfers", EconomyFieldEncoding::I64, 8}),
      line_transaction_transfers(changes, {{9, 24}, "trade.line_transaction_transfers", EconomyFieldEncoding::I64, 8}),
      line_flags(changes, {{9, 25}, "trade.line_flags", EconomyFieldEncoding::U8, 1}),
      seller_offsets(changes, {{9, 26}, "trade.seller_offsets", EconomyFieldEncoding::I32, 4}),
      seller_handles(changes, {{9, 27}, "trade.seller_handles", EconomyFieldEncoding::U64, 8}),
      seller_weights(changes, {{9, 28}, "trade.seller_weights", EconomyFieldEncoding::I64, 8}) {}
EconomyTradeOrderStore::EconomyTradeOrderStore(const EconomyTradeOrderStore &other)
    : EconomyTradeOrderStore() { *this = other; }
EconomyTradeOrderStore &EconomyTradeOrderStore::operator=(const EconomyTradeOrderStore &other) {
    if (this == &other) return *this;
    ids.assign(other.ids.values());
    sources.assign(other.sources.values());
    destinations.assign(other.destinations.values());
    countries.assign(other.countries.values());
    source_country_handles.assign(other.source_country_handles.values());
    destination_country_handles.assign(other.destination_country_handles.values());
    source_country_slots.assign(other.source_country_slots.values());
    destination_country_slots.assign(other.destination_country_slots.values());
    departure_days.assign(other.departure_days.values());
    arrival_days.assign(other.arrival_days.values());
    cash_escrow.assign(other.cash_escrow.values());
    capacity_work.assign(other.capacity_work.values());
    states.assign(other.states.values());
    cargo_delivered.assign(other.cargo_delivered.values());
    line_offsets.assign(other.line_offsets.values());
    line_goods.assign(other.line_goods.values());
    line_quantities.assign(other.line_quantities.values());
    line_unit_prices.assign(other.line_unit_prices.values());
    line_destination_prices.assign(other.line_destination_prices.values());
    line_base_values.assign(other.line_base_values.values());
    line_retail_values.assign(other.line_retail_values.values());
    line_import_transfers.assign(other.line_import_transfers.values());
    line_export_transfers.assign(other.line_export_transfers.values());
    line_transaction_transfers.assign(other.line_transaction_transfers.values());
    line_flags.assign(other.line_flags.values());
    seller_offsets.assign(other.seller_offsets.values());
    seller_handles.assign(other.seller_handles.values());
    seller_weights.assign(other.seller_weights.values());
    arrival_bucket_days = other.arrival_bucket_days;
    arrival_bucket_offsets = other.arrival_bucket_offsets;
    arrival_bucket_orders = other.arrival_bucket_orders;
    arrival_buckets_dirty = other.arrival_buckets_dirty;
    next_id = other.next_id;
    return *this;
}
EconomyTradeOrderStore::EconomyTradeOrderStore(EconomyTradeOrderStore &&other)
    : EconomyTradeOrderStore() { *this = std::move(other); }
EconomyTradeOrderStore &EconomyTradeOrderStore::operator=(EconomyTradeOrderStore &&other) {
    if (this == &other) return *this;
    ids.move_from(other.ids);
    sources.move_from(other.sources);
    destinations.move_from(other.destinations);
    countries.move_from(other.countries);
    source_country_handles.move_from(other.source_country_handles);
    destination_country_handles.move_from(other.destination_country_handles);
    source_country_slots.move_from(other.source_country_slots);
    destination_country_slots.move_from(other.destination_country_slots);
    departure_days.move_from(other.departure_days);
    arrival_days.move_from(other.arrival_days);
    cash_escrow.move_from(other.cash_escrow);
    capacity_work.move_from(other.capacity_work);
    states.move_from(other.states);
    cargo_delivered.move_from(other.cargo_delivered);
    line_offsets.move_from(other.line_offsets);
    line_goods.move_from(other.line_goods);
    line_quantities.move_from(other.line_quantities);
    line_unit_prices.move_from(other.line_unit_prices);
    line_destination_prices.move_from(other.line_destination_prices);
    line_base_values.move_from(other.line_base_values);
    line_retail_values.move_from(other.line_retail_values);
    line_import_transfers.move_from(other.line_import_transfers);
    line_export_transfers.move_from(other.line_export_transfers);
    line_transaction_transfers.move_from(other.line_transaction_transfers);
    line_flags.move_from(other.line_flags);
    seller_offsets.move_from(other.seller_offsets);
    seller_handles.move_from(other.seller_handles);
    seller_weights.move_from(other.seller_weights);
    arrival_bucket_days = std::move(other.arrival_bucket_days);
    arrival_bucket_offsets = std::move(other.arrival_bucket_offsets);
    arrival_bucket_orders = std::move(other.arrival_bucket_orders);
    arrival_buckets_dirty = other.arrival_buckets_dirty;
    next_id = other.next_id;
    other.arrival_buckets_dirty = true;
    other.next_id = 1;
    return *this;
}

EconomyFamilyStore::EconomyFamilyStore()
    : active_count(changes, {{5, 1001}, "family.active_count", EconomyFieldEncoding::I64, 8}, 0),
      active(changes, {{5, 1}, "family.active", EconomyFieldEncoding::U8, 1}),
      generation(changes, {{5, 2}, "family.generation", EconomyFieldEncoding::U32, 4}),
      stable_id(changes, {{5, 3}, "family.stable_id", EconomyFieldEncoding::I64, 8}),
      surname_id(changes, {{5, 4}, "family.surname_id", EconomyFieldEncoding::I32, 4}),
      surname_disambiguator(changes, {{5, 5}, "family.surname_disambiguator", EconomyFieldEncoding::U32, 4}),
      founded_day(changes, {{5, 6}, "family.founded_day", EconomyFieldEncoding::I64, 8}),
      home_cell(changes, {{5, 7}, "family.home_cell", EconomyFieldEncoding::I32, 4}),
      origin_cell(changes, {{5, 8}, "family.origin_cell", EconomyFieldEncoding::I32, 4}),
      origin_ethnicity(changes, {{5, 9}, "family.origin_ethnicity", EconomyFieldEncoding::I32, 4}),
      culture_group_id(changes, {{5, 10}, "family.culture_group_id", EconomyFieldEncoding::I32, 4}),
      split_sequence(changes, {{5, 11}, "family.split_sequence", EconomyFieldEncoding::U32, 4}),
      decline_reviews(changes, {{5, 12}, "family.decline_reviews", EconomyFieldEncoding::U16, 2}),
      flags(changes, {{5, 13}, "family.flags", EconomyFieldEncoding::U16, 2}),
      free_indices(changes, {{5, 14}, "family.free_indices", EconomyFieldEncoding::I32, 4}) {}
EconomyFamilyStore::EconomyFamilyStore(const EconomyFamilyStore &other)
    : EconomyFamilyStore() { *this = other; }
EconomyFamilyStore &EconomyFamilyStore::operator=(const EconomyFamilyStore &other) {
    if (this == &other) return *this;
    active.assign(other.active.values());
    generation.assign(other.generation.values());
    stable_id.assign(other.stable_id.values());
    surname_id.assign(other.surname_id.values());
    surname_disambiguator.assign(other.surname_disambiguator.values());
    founded_day.assign(other.founded_day.values());
    home_cell.assign(other.home_cell.values());
    origin_cell.assign(other.origin_cell.values());
    origin_ethnicity.assign(other.origin_ethnicity.values());
    culture_group_id.assign(other.culture_group_id.values());
    split_sequence.assign(other.split_sequence.values());
    decline_reviews.assign(other.decline_reviews.values());
    flags.assign(other.flags.values());
    free_indices.assign(other.free_indices.values());
    active_count = other.active_count;
    return *this;
}
EconomyFamilyStore::EconomyFamilyStore(EconomyFamilyStore &&other)
    : EconomyFamilyStore() { *this = std::move(other); }
EconomyFamilyStore &EconomyFamilyStore::operator=(EconomyFamilyStore &&other) {
    if (this == &other) return *this;
    active.move_from(other.active);
    generation.move_from(other.generation);
    stable_id.move_from(other.stable_id);
    surname_id.move_from(other.surname_id);
    surname_disambiguator.move_from(other.surname_disambiguator);
    founded_day.move_from(other.founded_day);
    home_cell.move_from(other.home_cell);
    origin_cell.move_from(other.origin_cell);
    origin_ethnicity.move_from(other.origin_ethnicity);
    culture_group_id.move_from(other.culture_group_id);
    split_sequence.move_from(other.split_sequence);
    decline_reviews.move_from(other.decline_reviews);
    flags.move_from(other.flags);
    free_indices.move_from(other.free_indices);
    active_count = other.active_count;
    other.active_count = 0;
    return *this;
}


void EconomyFamilyStore::clear() {
    active.clear(); generation.clear(); stable_id.clear(); surname_id.clear();
    surname_disambiguator.clear(); founded_day.clear(); home_cell.clear();
    origin_cell.clear(); origin_ethnicity.clear(); culture_group_id.clear();
    split_sequence.clear(); decline_reviews.clear(); flags.clear();
    free_indices.clear(); active_count = 0;
}

int32_t EconomyFamilyStore::allocate() {
    int32_t index = -1;
    if (!free_indices.empty()) {
        const auto reusable = std::min_element(free_indices.begin(), free_indices.end());
        index = *reusable;
        free_indices.erase(reusable);
    } else {
        index = static_cast<int32_t>(active.size());
        active.push_back(0); generation.push_back(1); stable_id.push_back(0);
        surname_id.push_back(-1); surname_disambiguator.push_back(0);
        founded_day.push_back(-1); home_cell.push_back(-1); origin_cell.push_back(-1);
        origin_ethnicity.push_back(-1); culture_group_id.push_back(-1);
        split_sequence.push_back(0); decline_reviews.push_back(0);
        flags.push_back(0);
    }
    active.write_scalar(index, 1);
    stable_id.write_scalar(index, 0); surname_id.write_scalar(index, -1);
    surname_disambiguator.write_scalar(index, 0); founded_day.write_scalar(index, -1);
    home_cell.write_scalar(index, -1); origin_cell.write_scalar(index, -1);
    origin_ethnicity.write_scalar(index, -1); culture_group_id.write_scalar(index, -1);
    split_sequence.write_scalar(index, 0);
    decline_reviews.write_scalar(index, 0); flags.write_scalar(index, 0);
    ++active_count;
    return index;
}

void EconomyFamilyStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return;
    active.write_scalar(index, 0);
    generation.write_scalar(index, generation[index] == UINT32_MAX ? 1 : generation[index] + 1);
    free_indices.push_back(index);
    --active_count;
}

uint64_t EconomyFamilyStore::handle_for_index(int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) || active[index] == 0)
        return 0;
    return (static_cast<uint64_t>(generation[index]) << 32) |
        static_cast<uint32_t>(index);
}

bool EconomyFamilyStore::valid_handle(uint64_t handle,
                                      int32_t &index_out) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t gen = static_cast<uint32_t>(handle >> 32);
    if (index >= active.size() || active[index] == 0 || generation[index] != gen)
        return false;
    index_out = static_cast<int32_t>(index);
    return true;
}

} // namespace pk
