#include "economy_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include <algorithm>
#include <chrono>
#include <functional>
#include <numeric>
#include <tuple>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
#include "economy_runtime_colonization_internal.h"

EconomyFamilyExpeditionStore::EconomyFamilyExpeditionStore()
    : active_count(changes, {{8, 1001}, "expedition.active_count", EconomyFieldEncoding::I64, 8}, 0),
      active(changes, {{8, 1}, "expedition.active", EconomyFieldEncoding::U8, 1}),
      generation(changes, {{8, 2}, "expedition.generation", EconomyFieldEncoding::U32, 4}),
      stable_id(changes, {{8, 3}, "expedition.stable_id", EconomyFieldEncoding::I64, 8}),
      country_handle(changes, {{8, 4}, "expedition.country_handle", EconomyFieldEncoding::U64, 8}),
      family_handle(changes, {{8, 5}, "expedition.family_handle", EconomyFieldEncoding::U64, 8}),
      source_cell(changes, {{8, 6}, "expedition.source_cell", EconomyFieldEncoding::I32, 4}),
      target_cell(changes, {{8, 7}, "expedition.target_cell", EconomyFieldEncoding::I32, 4}),
      departure_day(changes, {{8, 8}, "expedition.departure_day", EconomyFieldEncoding::I64, 8}),
      due_day(changes, {{8, 9}, "expedition.due_day", EconomyFieldEncoding::I64, 8}),
      route_cost(changes, {{8, 10}, "expedition.route_cost", EconomyFieldEncoding::I32, 4}),
      speed(changes, {{8, 11}, "expedition.speed", EconomyFieldEncoding::I32, 4}),
      state(changes, {{8, 12}, "expedition.state", EconomyFieldEncoding::U8, 1}),
      population(changes, {{8, 13}, "expedition.population", EconomyFieldEncoding::I64, 8}),
      anonymous(changes, {{8, 30}, "expedition.anonymous", EconomyFieldEncoding::I64, 8}),
      route_begin(changes, {{8, 14}, "expedition.route_begin", EconomyFieldEncoding::U32, 4}),
      route_count(changes, {{8, 15}, "expedition.route_count", EconomyFieldEncoding::U32, 4}),
      payload_begin(changes, {{8, 16}, "expedition.payload_begin", EconomyFieldEncoding::U32, 4}),
      payload_count(changes, {{8, 17}, "expedition.payload_count", EconomyFieldEncoding::U32, 4}),
      cargo_begin(changes, {{8, 18}, "expedition.cargo_begin", EconomyFieldEncoding::U32, 4}),
      cargo_count(changes, {{8, 19}, "expedition.cargo_count", EconomyFieldEncoding::U32, 4}),
      kit_building_begin(changes, {{8, 20}, "expedition.kit_building_begin", EconomyFieldEncoding::U32, 4}),
      kit_building_count(changes, {{8, 21}, "expedition.kit_building_count", EconomyFieldEncoding::U32, 4}),
      kit_bridge_required_units(changes, {{8, 22}, "expedition.kit_bridge_required_units", EconomyFieldEncoding::I64, 8}),
      kit_material_required_units(changes, {{8, 23}, "expedition.kit_material_required_units", EconomyFieldEncoding::I64, 8}),
      kit_missing_stock_identity(changes, {{8, 24}, "expedition.kit_missing_stock_identity", EconomyFieldEncoding::U64, 8}),
      missing_good_begin(changes, {{8, 25}, "expedition.missing_good_begin", EconomyFieldEncoding::U32, 4}),
      missing_good_count(changes, {{8, 26}, "expedition.missing_good_count", EconomyFieldEncoding::U32, 4}),
      effect_transaction_id(changes, {{8, 27}, "expedition.effect_transaction_id", EconomyFieldEncoding::I64, 8}),
      idempotency_key(changes, {{8, 28}, "expedition.idempotency_key", EconomyFieldEncoding::U64, 8}),
      free_indices(changes, {{8, 29}, "expedition.free_indices", EconomyFieldEncoding::I32, 4}) {}
EconomyFamilyExpeditionStore::EconomyFamilyExpeditionStore(const EconomyFamilyExpeditionStore &other)
    : EconomyFamilyExpeditionStore() { *this = other; }
EconomyFamilyExpeditionStore &EconomyFamilyExpeditionStore::operator=(const EconomyFamilyExpeditionStore &other) {
    if (this == &other) return *this;
    active.assign(other.active.values());
    generation.assign(other.generation.values());
    stable_id.assign(other.stable_id.values());
    country_handle.assign(other.country_handle.values());
    family_handle.assign(other.family_handle.values());
    source_cell.assign(other.source_cell.values());
    target_cell.assign(other.target_cell.values());
    departure_day.assign(other.departure_day.values());
    due_day.assign(other.due_day.values());
    route_cost.assign(other.route_cost.values());
    speed.assign(other.speed.values());
    state.assign(other.state.values());
    population.assign(other.population.values());
    anonymous.assign(other.anonymous.values());
    route_begin.assign(other.route_begin.values());
    route_count.assign(other.route_count.values());
    payload_begin.assign(other.payload_begin.values());
    payload_count.assign(other.payload_count.values());
    cargo_begin.assign(other.cargo_begin.values());
    cargo_count.assign(other.cargo_count.values());
    kit_building_begin.assign(other.kit_building_begin.values());
    kit_building_count.assign(other.kit_building_count.values());
    kit_bridge_required_units.assign(other.kit_bridge_required_units.values());
    kit_material_required_units.assign(other.kit_material_required_units.values());
    kit_missing_stock_identity.assign(other.kit_missing_stock_identity.values());
    missing_good_begin.assign(other.missing_good_begin.values());
    missing_good_count.assign(other.missing_good_count.values());
    effect_transaction_id.assign(other.effect_transaction_id.values());
    idempotency_key.assign(other.idempotency_key.values());
    free_indices.assign(other.free_indices.values());
    active_count = other.active_count;
    return *this;
}
EconomyFamilyExpeditionStore::EconomyFamilyExpeditionStore(EconomyFamilyExpeditionStore &&other)
    : EconomyFamilyExpeditionStore() { *this = std::move(other); }
EconomyFamilyExpeditionStore &EconomyFamilyExpeditionStore::operator=(EconomyFamilyExpeditionStore &&other) {
    if (this == &other) return *this;
    active.move_from(other.active);
    generation.move_from(other.generation);
    stable_id.move_from(other.stable_id);
    country_handle.move_from(other.country_handle);
    family_handle.move_from(other.family_handle);
    source_cell.move_from(other.source_cell);
    target_cell.move_from(other.target_cell);
    departure_day.move_from(other.departure_day);
    due_day.move_from(other.due_day);
    route_cost.move_from(other.route_cost);
    speed.move_from(other.speed);
    state.move_from(other.state);
    population.move_from(other.population);
    anonymous.move_from(other.anonymous);
    route_begin.move_from(other.route_begin);
    route_count.move_from(other.route_count);
    payload_begin.move_from(other.payload_begin);
    payload_count.move_from(other.payload_count);
    cargo_begin.move_from(other.cargo_begin);
    cargo_count.move_from(other.cargo_count);
    kit_building_begin.move_from(other.kit_building_begin);
    kit_building_count.move_from(other.kit_building_count);
    kit_bridge_required_units.move_from(other.kit_bridge_required_units);
    kit_material_required_units.move_from(other.kit_material_required_units);
    kit_missing_stock_identity.move_from(other.kit_missing_stock_identity);
    missing_good_begin.move_from(other.missing_good_begin);
    missing_good_count.move_from(other.missing_good_count);
    effect_transaction_id.move_from(other.effect_transaction_id);
    idempotency_key.move_from(other.idempotency_key);
    free_indices.move_from(other.free_indices);
    active_count = other.active_count;
    other.active_count = 0;
    return *this;
}


void EconomyFamilyExpeditionStore::clear() {
    active.clear(); generation.clear(); stable_id.clear();
    country_handle.clear(); family_handle.clear(); source_cell.clear();
    target_cell.clear(); departure_day.clear(); due_day.clear();
    route_cost.clear(); speed.clear(); state.clear(); population.clear();
    anonymous.clear();
    route_begin.clear(); route_count.clear(); payload_begin.clear();
    payload_count.clear(); cargo_begin.clear(); cargo_count.clear();
    kit_building_begin.clear(); kit_building_count.clear();
    kit_bridge_required_units.clear(); kit_material_required_units.clear();
    kit_missing_stock_identity.clear();
    missing_good_begin.clear(); missing_good_count.clear();
    effect_transaction_id.clear();
    idempotency_key.clear(); free_indices.clear(); active_count = 0;
}

int32_t EconomyFamilyExpeditionStore::allocate() {
    int32_t index = -1;
    if (!free_indices.empty()) {
        index = free_indices.back();
        free_indices.pop_back();
        generation.write_scalar(index, std::max<uint32_t>(1, generation[index] + 1));
        cargo_begin.write_scalar(index, 0); cargo_count.write_scalar(index, 0);
        kit_building_begin.write_scalar(index, 0); kit_building_count.write_scalar(index, 0);
        kit_bridge_required_units.write_scalar(index, 0);
        kit_material_required_units.write_scalar(index, 0);
        kit_missing_stock_identity.write_scalar(index, 0);
        missing_good_begin.write_scalar(index, 0); missing_good_count.write_scalar(index, 0);
    } else {
        index = static_cast<int32_t>(active.size());
        active.push_back(0); generation.push_back(1); stable_id.push_back(0);
        country_handle.push_back(0); family_handle.push_back(0);
        source_cell.push_back(-1); target_cell.push_back(-1);
        departure_day.push_back(-1); due_day.push_back(-1);
        route_cost.push_back(0); speed.push_back(COLONIZATION_SPEED);
        state.push_back(EXPEDITION_OUTBOUND); population.push_back(0);
        anonymous.push_back(0);
        route_begin.push_back(0); route_count.push_back(0);
        payload_begin.push_back(0); payload_count.push_back(0);
        cargo_begin.push_back(0); cargo_count.push_back(0);
        kit_building_begin.push_back(0); kit_building_count.push_back(0);
        kit_bridge_required_units.push_back(0);
        kit_material_required_units.push_back(0);
        kit_missing_stock_identity.push_back(0);
        missing_good_begin.push_back(0); missing_good_count.push_back(0);
        effect_transaction_id.push_back(0); idempotency_key.push_back(0);
    }
    active.write_scalar(index, 1);
    ++active_count;
    return index;
}

void EconomyFamilyExpeditionStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0) return;
    active.write_scalar(index, 0);
    country_handle.write_scalar(index, 0); family_handle.write_scalar(index, 0);
    population.write_scalar(index, 0); effect_transaction_id.write_scalar(index, 0);
    anonymous.write_scalar(index, 0);
    free_indices.push_back(index);
    --active_count;
}

uint64_t EconomyFamilyExpeditionStore::handle_for_index(
        int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0) return 0;
    return (static_cast<uint64_t>(generation[index]) << 32U) |
        static_cast<uint32_t>(index);
}

bool EconomyFamilyExpeditionStore::valid_handle(
        uint64_t handle, int32_t &index_out) const {
    const int32_t index = static_cast<int32_t>(handle & 0xffffffffULL);
    const uint32_t expected = static_cast<uint32_t>(handle >> 32U);
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0 || generation[index] != expected) return false;
    index_out = index;
    return true;
}


} // namespace pk
