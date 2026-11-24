#include "economy_runtime.h"
#include "country_api.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <numeric>
#include <unordered_map>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

void NativeEconomyRuntime::rebuild_country_trade_indices() {
    _country_good_trade_index.clear();
    _country_partner_trade_index.clear();
    _tariff_history_index.clear();
    _country_good_display_rows.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), {});
    _country_partner_display_rows.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), {});
    _country_good_display_dirty.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _country_partner_display_dirty.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    _country_good_trade_index.reserve(_country_good_trade.countries.size());
    _country_partner_trade_index.reserve(
        _country_partner_trade.countries.size());
    _tariff_history_index.reserve(_tariff_history.countries.size());
    const auto key_for = [](int32_t first, int32_t second) {
        return (static_cast<uint64_t>(static_cast<uint32_t>(first)) << 32) |
            static_cast<uint32_t>(second);
    };
    for (int32_t i = 0; i < static_cast<int32_t>(
            _country_good_trade.countries.size()); ++i) {
        const int32_t country = _country_good_trade.countries[i];
        _country_good_trade_index.emplace(
            key_for(country, _country_good_trade.goods[i]), i);
        if (country >= 0 && country < _epoch_country_count)
            _country_good_display_rows[static_cast<size_t>(country)].push_back(i);
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        auto &rows = _country_good_display_rows[static_cast<size_t>(country)];
        std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
            if (_country_good_trade.goods[a] != _country_good_trade.goods[b])
                return _country_good_trade.goods[a] < _country_good_trade.goods[b];
            return a < b;
        });
    }
    for (int32_t i = 0; i < static_cast<int32_t>(
            _country_partner_trade.countries.size()); ++i) {
        const int32_t country = _country_partner_trade.countries[i];
        _country_partner_trade_index.emplace(
            key_for(country, _country_partner_trade.partners[i]), i);
        if (country >= 0 && country < _epoch_country_count)
            _country_partner_display_rows[static_cast<size_t>(country)].push_back(i);
    }
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        auto &rows = _country_partner_display_rows[static_cast<size_t>(country)];
        std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
            if (_country_partner_trade.partners[a] !=
                    _country_partner_trade.partners[b])
                return _country_partner_trade.partners[a] <
                    _country_partner_trade.partners[b];
            return a < b;
        });
    }
    for (int32_t i = 0; i < static_cast<int32_t>(
            _tariff_history.countries.size()); ++i) {
        _tariff_history_index.emplace(key_for(_tariff_history.countries[i],
            _tariff_history.kinds[i]), i);
    }
}

void NativeEconomyRuntime::sort_dirty_country_trade_display_indices() {
    const int32_t countries = std::min<int32_t>(_epoch_country_count,
        static_cast<int32_t>(_country_good_display_rows.size()));
    for (int32_t country = 0; country < countries; ++country) {
        if (country >= static_cast<int32_t>(_country_good_display_dirty.size()) ||
            _country_good_display_dirty[static_cast<size_t>(country)] == 0)
            continue;
        auto &rows = _country_good_display_rows[static_cast<size_t>(country)];
        std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
            if (_country_good_trade.goods[a] != _country_good_trade.goods[b])
                return _country_good_trade.goods[a] < _country_good_trade.goods[b];
            return a < b;
        });
        _country_good_display_dirty[static_cast<size_t>(country)] = 0;
    }
    const int32_t partner_countries = std::min<int32_t>(_epoch_country_count,
        static_cast<int32_t>(_country_partner_display_rows.size()));
    for (int32_t country = 0; country < partner_countries; ++country) {
        if (country >= static_cast<int32_t>(_country_partner_display_dirty.size()) ||
            _country_partner_display_dirty[static_cast<size_t>(country)] == 0)
            continue;
        auto &rows = _country_partner_display_rows[static_cast<size_t>(country)];
        std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
            if (_country_partner_trade.partners[a] !=
                    _country_partner_trade.partners[b])
                return _country_partner_trade.partners[a] <
                    _country_partner_trade.partners[b];
            return a < b;
        });
        _country_partner_display_dirty[static_cast<size_t>(country)] = 0;
    }
}

bool NativeEconomyRuntime::capture_trade_topology(
        const int32_t *neighbor_indices, const uint8_t *terrain,
        const uint8_t *canal_edge_mask, const float *canal_water,
        const uint8_t *trade_passable_lut, const int32_t *trade_move_cost_lut,
        int32_t count, uint64_t generation, std::string &error,
        const uint8_t *landform, const uint8_t *has_river) {
    if (!_configured || count != _cell_count.get() || neighbor_indices == nullptr ||
        terrain == nullptr || canal_edge_mask == nullptr || canal_water == nullptr ||
        trade_passable_lut == nullptr ||
        trade_move_cost_lut == nullptr) {
        error = "trade_topology_snapshot_invalid";
        return false;
    }
    uint64_t hash = 1469598103934665603ULL;
    auto mix_u32 = [&](uint32_t value) {
        for (int32_t b = 0; b < 4; ++b) {
            hash ^= static_cast<uint8_t>((value >> (b * 8)) & 0xffU);
            hash *= 1099511628211ULL;
        }
    };
    std::vector<int32_t> neighbors(static_cast<size_t>(count) * 6, -1);
    std::vector<uint8_t> passable(static_cast<size_t>(count), 0);
    std::vector<int32_t> enter_cost(static_cast<size_t>(count), 0);
    std::vector<int32_t> edge_cost(static_cast<size_t>(count) * 6, 0);
    std::vector<uint8_t> canal_mask(static_cast<size_t>(count), 0);
    std::vector<float> canal_water_snapshot(static_cast<size_t>(count), 0.0f);
    std::vector<uint8_t> water_class;
    std::vector<uint8_t> river;
    fill_trade_water_columns(terrain, landform, has_river, count, water_class, river);
    for (int32_t cell = 0; cell < count; ++cell) {
        const uint8_t terrain_id = terrain[cell];
        const bool navigable_water = water_class[static_cast<size_t>(cell)] != WATER_CLASS_NONE;
        passable[cell] = (!navigable_water && trade_passable_lut[terrain_id] != 0) ? 1 : 0;
        enter_cost[cell] = passable[cell] != 0 ? trade_move_cost_lut[terrain_id] : 0;
        if (passable[cell] != 0 && enter_cost[cell] <= 0) {
            error = "trade_passable_cell_has_nonpositive_cost";
            return false;
        }
        mix_u32(passable[cell]);
        mix_u32(static_cast<uint32_t>(enter_cost[cell]));
        mix_u32(water_class[static_cast<size_t>(cell)]);
        mix_u32(river[static_cast<size_t>(cell)]);
        canal_mask[cell] = canal_edge_mask[cell] & 0x3fU;
        canal_water_snapshot[cell] = std::max(0.0f, canal_water[cell]);
        mix_u32(canal_mask[cell]);
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = neighbor_indices[cell * 6 + direction];
            const int32_t valid = neighbor >= 0 && neighbor < count && neighbor != cell
                ? neighbor : -1;
            neighbors[static_cast<size_t>(cell) * 6 + direction] = valid;
            mix_u32(static_cast<uint32_t>(valid));
        }
    }
    for (int32_t cell = 0; cell < count; ++cell) {
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = neighbors[static_cast<size_t>(cell) * 6 + direction];
            if (neighbor < 0 || passable[cell] == 0 || passable[neighbor] == 0) continue;
            const bool canal = (canal_mask[cell] & (1U << direction)) != 0 &&
                (canal_mask[neighbor] & (1U << ((direction + 3) % 6))) != 0;
            edge_cost[static_cast<size_t>(cell) * 6 + direction] = canal
                ? std::max(1, enter_cost[neighbor] / 2) : enter_cost[neighbor];
            mix_u32(static_cast<uint32_t>(edge_cost[static_cast<size_t>(cell) * 6 + direction]));
        }
    }
    const uint64_t normalized_hash = (hash & 0x7fffffffffffffffULL) | 1ULL;
    // The normalized content hash is authoritative. Callers may refresh their
    // own generation for unrelated map state; identical trade topology must
    // not throw away an incremental plan. A real content change always advances
    // our internal generation even when the caller reuses a stale token.
    if (_trade_topology.ready && _trade_topology.topology_hash == normalized_hash) return true;
    const bool resumes_saved_plan = !_trade_topology.ready &&
        _trade_topology.topology_hash == normalized_hash;
    if (_trade_topology.ready) {
        ++_trade_topology_content_change_count;
        ++_trade_plan_reset_count;
        _trade_last_plan_reset_reason = "normalized_topology_changed";
    } else {
        _trade_last_plan_reset_reason = "initial_topology_capture";
    }
    const uint64_t resolved_generation = resumes_saved_plan
        ? _trade_topology.topology_generation
        : std::max<uint64_t>(_trade_topology.topology_generation + 1, generation);
    _trade_topology.neighbors.swap(neighbors);
    _trade_topology.passable.swap(passable);
    _trade_topology.enter_cost.swap(enter_cost);
    _trade_topology.edge_cost.swap(edge_cost);
    _trade_topology.canal_edge_mask.swap(canal_mask);
    _trade_topology.canal_water.swap(canal_water_snapshot);
    _trade_topology.water_class.swap(water_class);
    _trade_topology.has_river.swap(river);
    _trade_topology.component.assign(static_cast<size_t>(count), -1);
    _trade_topology.topology_hash = normalized_hash;
    _trade_topology.topology_generation = resolved_generation;
    _trade_topology.component_country_hash = 0;
    _trade_topology.ready = true;
    build_water_transport_graphs();
    if (!resumes_saved_plan) _trade_plan.clear_transient();
    return true;
}

bool NativeEconomyRuntime::capture_trade_visibility(
        const uint8_t *visible, int32_t count, bool fog_solved, bool from_map,
        std::string &error) {
    _trade_visibility_manual = !from_map;
    _epoch_player_country_slot = _country_runtime != nullptr
        ? country_reads().starting_country_slot() : -1;
    if (!fog_solved) {
        _epoch_trade_vision_gated = false;
        _epoch_cell_visible.clear();
        return true;
    }
    if (!_configured || visible == nullptr || count != _cell_count.get()) {
        error = "trade_visibility_snapshot_invalid";
        return false;
    }
    _epoch_cell_visible.assign(visible, visible + count);
    _epoch_trade_vision_gated = true;
    return true;
}

bool NativeEconomyRuntime::trade_vision_allows_pair(
        int32_t source, int32_t destination) const {
    // 未解算 = 全知。解算后只有玩家开局国参与的订单要求两端当前可见；
    // AI↔AI 与走廊格不受玩家迷雾限制。
    if (!_epoch_trade_vision_gated) return true;
    if (source < 0 || destination < 0 || source >= _cell_count.get() ||
        destination >= _cell_count.get()) return false;
    if (_epoch_cell_visible.size() != static_cast<size_t>(_cell_count.get())) return true;
    const int32_t player = _epoch_player_country_slot;
    if (player < 0) return true;
    if (_epoch_cell_country.size() != static_cast<size_t>(_cell_count.get())) return true;
    if (_epoch_cell_country[static_cast<size_t>(source)] != player &&
        _epoch_cell_country[static_cast<size_t>(destination)] != player) {
        return true;
    }
    return _epoch_cell_visible[static_cast<size_t>(source)] != 0 &&
        _epoch_cell_visible[static_cast<size_t>(destination)] != 0;
}

bool NativeEconomyRuntime::refresh_canal_topology(
        const uint8_t *canal_edge_mask, const float *canal_water,
        int32_t count, std::string &error) {
    if (!_trade_topology.ready || count != _cell_count.get() ||
        canal_edge_mask == nullptr || canal_water == nullptr ||
        _trade_topology.neighbors.size() != static_cast<size_t>(count) * 6) {
        error = "canal_topology_snapshot_invalid";
        return false;
    }
    uint64_t hash = 1469598103934665603ULL;
    auto mix_u32 = [&](uint32_t value) {
        for (int b = 0; b < 4; ++b) {
            hash ^= static_cast<uint8_t>((value >> (b * 8)) & 0xffU);
            hash *= 1099511628211ULL;
        }
    };
    std::vector<uint8_t> mask(static_cast<size_t>(count));
    std::vector<float> water(static_cast<size_t>(count));
    std::vector<int32_t> costs(static_cast<size_t>(count) * 6, 0);
    for (int32_t cell = 0; cell < count; ++cell) {
        mask[cell] = canal_edge_mask[cell] & 0x3fU;
        water[cell] = std::max(0.0f, canal_water[cell]);
        mix_u32(_trade_topology.passable[cell]);
        mix_u32(static_cast<uint32_t>(_trade_topology.enter_cost[cell]));
        mix_u32(_trade_topology.water_class.size() == static_cast<size_t>(count)
            ? _trade_topology.water_class[static_cast<size_t>(cell)] : 0);
        mix_u32(_trade_topology.has_river.size() == static_cast<size_t>(count)
            ? _trade_topology.has_river[static_cast<size_t>(cell)] : 0);
        mix_u32(mask[cell]);
        for (int direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[cell * 6 + direction];
            mix_u32(static_cast<uint32_t>(neighbor));
        }
    }
    for (int32_t cell = 0; cell < count; ++cell) {
        for (int direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[cell * 6 + direction];
            if (neighbor < 0 || _trade_topology.passable[cell] == 0 ||
                _trade_topology.passable[neighbor] == 0) continue;
            const bool canal = (mask[cell] & (1U << direction)) != 0 &&
                (mask[neighbor] & (1U << ((direction + 3) % 6))) != 0;
            costs[cell * 6 + direction] = canal
                ? std::max(1, _trade_topology.enter_cost[neighbor] / 2)
                : _trade_topology.enter_cost[neighbor];
            mix_u32(static_cast<uint32_t>(costs[cell * 6 + direction]));
        }
    }
    const uint64_t normalized = (hash & 0x7fffffffffffffffULL) | 1ULL;
    if (normalized == _trade_topology.topology_hash) {
        _trade_topology.canal_water.swap(water);
        return true;
    }
    _trade_topology.canal_edge_mask.swap(mask);
    _trade_topology.canal_water.swap(water);
    _trade_topology.edge_cost.swap(costs);
    _trade_topology.topology_hash = normalized;
    ++_trade_topology.topology_generation;
    if (_trade_topology.component_layers.size() ==
            static_cast<size_t>(WATER_LAYER_COUNT) * static_cast<size_t>(count)) {
        _trade_topology.component.assign(
            _trade_topology.component_layers.begin(),
            _trade_topology.component_layers.begin() + count);
        _trade_topology.component_country_hash = normalized;
    } else {
        _trade_topology.component_country_hash = 0;
        _trade_topology.component.assign(static_cast<size_t>(count), -1);
    }
    ++_trade_topology_content_change_count;
    ++_trade_plan_reset_count;
    _trade_last_plan_reset_reason = "canal_topology_changed";
    _trade_plan.clear_transient();
    return true;
}

int32_t NativeEconomyRuntime::trade_edge_cost(
        int32_t from_cell, int32_t to_cell) const {
    if (from_cell < 0 || from_cell >= _cell_count.get() || to_cell < 0 ||
        to_cell >= _cell_count.get()) return 0;
    for (int direction = 0; direction < 6; ++direction) {
        if (_trade_topology.neighbors[from_cell * 6 + direction] == to_cell) {
            if (_trade_topology.edge_cost.size() ==
                    static_cast<size_t>(_cell_count.get()) * 6)
                return std::max(1, _trade_topology.edge_cost[
                    from_cell * 6 + direction]);
            return std::max(1, _trade_topology.enter_cost[to_cell]);
        }
    }
    return 0;
}


int32_t NativeEconomyRuntime::estimate_trade_price(
        int32_t market, int32_t good, int64_t stock_after, int64_t &sat) const {
    const int64_t index = market_store().index(market, good);
    const int32_t signal = market_signal_index(market, good);
    const PricePressure pressure = price_pressure(
        market, good, market_store().demand_ema[index], std::max<int64_t>(0, stock_after),
        market_store().last_shortage_q16[index], signal, sat);
    bool rate_clamped = false;
    bool rise_damped = false;
    const int64_t current_price = market_store().price[index];
    const int64_t next = next_price_v6(good, current_price, pressure,
        std::max(1, _epoch_days.get()), sat, rate_clamped, rise_damped);
    // Share the settlement shaping so a planned destination price can never
    // exceed a price the settlement path is actually able to reach.
    return static_cast<int32_t>(shape_price(
        market_price_ceiling(market, good, pressure.adjustment_anchor_price),
        current_price, next, sat, nullptr, nullptr));
}

int64_t NativeEconomyRuntime::trade_relief_pressure_q16(
        int32_t market, int32_t good, int64_t &sat) const {
    if (market < 0 || market >= market_store().market_count.get() || good < 0 ||
        good >= market_store().good_count.get()) return 0;
    const int64_t index = market_store().index(market, good);
    int64_t pressure = 0;
    const bool survival_good =
        (good < static_cast<int32_t>(_survival_food_good_mask.size()) &&
         _survival_food_good_mask[good] != 0) ||
        (good < static_cast<int32_t>(_survival_clothing_good_mask.size()) &&
         _survival_clothing_good_mask[good] != 0);
    if (survival_good) {
        pressure = std::max<int64_t>(pressure,
            std::clamp<int64_t>(market_store().last_shortage_q16[index], 0, Q16_ONE));
    }
    const int32_t signal = market_signal_index(market, good);
    if (signal >= 0 && signal < static_cast<int32_t>(
            _epoch_desired_business_demand.size())) {
        const int64_t desired = _epoch_desired_business_demand[signal];
        const int64_t funded = signal < static_cast<int32_t>(
            _epoch_funded_business_demand.size())
            ? _epoch_funded_business_demand[signal] : 0;
        if (desired > funded) {
            pressure = std::max<int64_t>(pressure, std::clamp<int64_t>(
                mul_div_sat(desired - funded, Q16_ONE,
                            std::max<int64_t>(1, desired), sat), 0, Q16_ONE));
        }
    }
    const int64_t procurement = std::max<int64_t>(0,
        epoch_procurement_demand_daily_for_market(market, good) -
        epoch_research_demand_daily_for_market(market, good));
    if (procurement > 0) {
        pressure = std::max(pressure, std::clamp<int64_t>(mul_div_sat(
            std::max<int64_t>(0, procurement - market_store().stock[index]), Q16_ONE,
            procurement, sat), 0, Q16_ONE));
    }
    // Shadow derived demand is intentionally absent from the relief lane.
    // Otherwise a price-only upstream signal would create an actual import
    // target and spend merchant cash before a real downstream withdrawal.
    if (signal >= 0 && signal < static_cast<int32_t>(
            _production_input_reserve.size())) {
        const int64_t reserve = merchant_protected_reserve(signal);
        const int64_t stock = std::max<int64_t>(0, market_store().stock[index]);
        if (reserve > stock) {
            pressure = std::max<int64_t>(pressure, std::clamp<int64_t>(
                mul_div_sat(reserve - stock, Q16_ONE, std::max<int64_t>(1, reserve), sat),
                0, Q16_ONE));
        }
    }
    return pressure;
}

int64_t NativeEconomyRuntime::trade_local_stock_target(
        int32_t market, int32_t good, int64_t &sat) const {
    if (market < 0 || market >= market_store().market_count.get() || good < 0 ||
        good >= market_store().good_count.get()) return 0;
    const int64_t index = market_store().index(market, good);
    int64_t demand = market_store().demand_ema[index];
    const int32_t signal = market_signal_index(market, good);
    if (signal >= 0) demand = saturating_add(
        demand, _market_signals.business_demand_ema[signal], sat);
    demand = saturating_add(demand, std::max<int64_t>(0,
        epoch_procurement_demand_daily_for_market(market, good) -
        epoch_research_demand_daily_for_market(market, good)), sat);
    // Derived demand is not a stock target.  It may influence price pressure
    // and investment ordering, but never creates a trade procurement lane.
    const int64_t relief_q16 = trade_relief_pressure_q16(market, good, sat);
    if (relief_q16 > 0) {
        const int64_t relief_base = std::max<int64_t>(demand, GOODS_SCALE);
        demand = saturating_add(demand,
            mul_div_sat(relief_base, relief_q16, Q16_ONE, sat), sat);
    }
    int64_t target = mul_div_sat(
        demand, _good_target_inventory_days_q16[good], Q16_ONE, sat);
    target = mul_div_sat(target, _trade_import_fill_fraction_q16.get(), Q16_ONE, sat);
    if (signal >= 0) {
        target = std::max(target, merchant_protected_reserve(signal));
    }
    return std::max<int64_t>(0, target);
}

int64_t NativeEconomyRuntime::trade_export_floor(
        int32_t market, int32_t good, int64_t &sat) const {
    if (market < 0 || market >= market_store().market_count.get() || good < 0 ||
        good >= market_store().good_count.get()) return 0;
    const int32_t signal = market_signal_index(market, good);
    const int32_t flow = const_cast<NativeEconomyRuntime *>(this)->trade_flow_index(
        market, good, false);
    const int64_t realized = signal >= 0
        ? _market_signals.realized_withdrawal_ema[signal] : 0;
    const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
    const int64_t stock = market_store().stock[market_store().index(market, good)];
    const int64_t merchant_target = merchant_inventory_target(
        market, good, signal, realized, exports, 0, sat);
    int64_t floor = mul_div_sat(
        merchant_target, _trade_export_inventory_fraction_q16.get(), Q16_ONE, sat);
    floor = std::max(floor, saturating_mul(
        realized, _trade_export_floor_days.get(), sat));
    if (signal >= 0) {
        floor = std::max(floor, merchant_protected_reserve(signal));
    }
    return std::clamp<int64_t>(floor, 0, std::max<int64_t>(0, stock));
}

int64_t NativeEconomyRuntime::profitable_trade_quantity(
        int32_t source, int32_t destination, int32_t good,
        int64_t max_quantity, bool relief_route, int32_t &source_price,
        int32_t &destination_price, int64_t &profit, int64_t &margin_q16,
        int64_t &sat) const {
    source_price = destination_price = 0;
    profit = margin_q16 = 0;
    if (max_quantity <= 0) return 0;
    const int64_t source_stock = market_store().stock[market_store().index(source, good)];
    const int64_t destination_stock = market_store().stock[market_store().index(destination, good)];
    auto quote = [&](int64_t quantity, int32_t &quoted_source,
                     int32_t &quoted_destination, int64_t &quoted_profit,
                     int64_t &quoted_margin) {
        quoted_source = estimate_trade_price(
            source, good, source_stock - quantity, sat);
        quoted_destination = estimate_trade_price(
            destination, good, destination_stock + quantity, sat);
        const TradeQuote trade_quote = make_trade_quote(
            source, destination, good, quantity, quoted_source,
            quoted_destination, relief_route, sat);
        quoted_margin = trade_quote.margin_q16;
        quoted_profit = trade_quote.combined_profit;
        const bool cash_safe = trade_quote.importer_outlay >= 0 &&
            trade_quote.importer_profit >= 0 &&
            trade_quote.exporter_receipt > 0;
        return cash_safe && (relief_route
            ? trade_quote.combined_profit >= 0
            : (trade_quote.combined_profit > 0 &&
               trade_quote.margin_q16 >= _trade_min_margin_q16.get()));
    };
    int64_t low = 1;
    int64_t high = max_quantity;
    int64_t best = 0;
    while (low <= high) {
        const int64_t mid = low + (high - low) / 2;
        int32_t quoted_source = 0;
        int32_t quoted_destination = 0;
        int64_t quoted_profit = 0;
        int64_t quoted_margin = 0;
        if (quote(mid, quoted_source, quoted_destination,
                  quoted_profit, quoted_margin)) {
            best = mid;
            source_price = quoted_source;
            destination_price = quoted_destination;
            profit = quoted_profit;
            margin_q16 = quoted_margin;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    if (best > 0 && best != max_quantity) {
        quote(best, source_price, destination_price, profit, margin_q16);
    }
    return best;
}

NativeEconomyRuntime::TradeQuote NativeEconomyRuntime::make_trade_quote(
        int32_t source, int32_t destination, int32_t good, int64_t quantity,
        int32_t source_price, int32_t destination_price,
        bool relief_route, int64_t &saturation_count) const {
    TradeQuote quote;
    quote.source_price = std::max(0, source_price);
    quote.destination_price = std::max(0, destination_price);
    quote.base = goods_cost(std::max<int64_t>(0, quantity), quote.source_price, saturation_count);
    quote.retail = goods_cost(std::max<int64_t>(0, quantity), quote.destination_price, saturation_count);
    const int32_t source_country = source >= 0 &&
            source < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[static_cast<size_t>(source)] : -1;
    const int32_t destination_country = destination >= 0 &&
            destination < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[static_cast<size_t>(destination)] : -1;
    quote.foreign = source_country >= 0 && destination_country >= 0 &&
        source_country != destination_country;
    if (quote.foreign) {
        const int32_t import_rate = frozen_tax_rate(
            destination, CountryApi::TAX_IMPORT, good);
        const int32_t export_rate = frozen_tax_rate(
            source, CountryApi::TAX_EXPORT, good);
        const int32_t import_mode = frozen_tax_mode(
            destination, CountryApi::TAX_IMPORT, good);
        const int32_t export_mode = frozen_tax_mode(
            source, CountryApi::TAX_EXPORT, good);
        const int64_t qty = std::max<int64_t>(0, quantity);
        const int64_t import_amount =
            import_mode == CountryApi::TAX_MODE_ABSOLUTE
                ? saturating_mul(qty,
                    std::abs(static_cast<int64_t>(import_rate)),
                    saturation_count)
                : mul_div_sat(quote.base,
                    std::abs(static_cast<int64_t>(import_rate)), 10000,
                    saturation_count);
        const int64_t export_amount =
            export_mode == CountryApi::TAX_MODE_ABSOLUTE
                ? saturating_mul(qty,
                    std::abs(static_cast<int64_t>(export_rate)),
                    saturation_count)
                : mul_div_sat(quote.base,
                    std::abs(static_cast<int64_t>(export_rate)), 10000,
                    saturation_count);
        quote.import_transfer = import_rate < 0 ? -import_amount : import_amount;
        quote.export_transfer = export_rate < 0 ? -export_amount : export_amount;
    }
    // Inter-cell dispatch is an inventory transfer. Positive transaction tax
    // applies at the buyer endpoint; negative rates wait for final household
    // or enterprise-input absorption to prevent closed inventory subsidy loops.
    const int32_t transaction_rate = frozen_tax_rate(
        destination, CountryApi::TAX_TRANSACTION, good);
    const int32_t transaction_mode = frozen_tax_mode(
        destination, CountryApi::TAX_TRANSACTION, good);
    if (transaction_rate > 0) {
        quote.transaction_transfer =
            transaction_mode == CountryApi::TAX_MODE_ABSOLUTE
                ? saturating_mul(std::max<int64_t>(0, quantity),
                    static_cast<int64_t>(transaction_rate), saturation_count)
                : mul_div_sat(quote.base, transaction_rate, 10000,
                    saturation_count);
    }
    quote.importer_outlay = saturating_add(
        saturating_add(quote.base, quote.import_transfer, saturation_count),
        quote.transaction_transfer, saturation_count);
    quote.exporter_receipt = saturating_sub(
        quote.base, quote.export_transfer, saturation_count);
    quote.importer_profit = saturating_sub(
        quote.retail, quote.importer_outlay, saturation_count);
    quote.combined_profit = saturating_sub(
        saturating_sub(saturating_sub(saturating_sub(
            quote.retail, quote.base, saturation_count),
            quote.import_transfer, saturation_count),
            quote.transaction_transfer, saturation_count),
        quote.export_transfer, saturation_count);
    quote.margin_q16 = mul_div_sat(
        quote.combined_profit, Q16_ONE,
        std::max<int64_t>(1, quote.base), saturation_count);
    quote.relief = relief_route;
    return quote;
}

int64_t NativeEconomyRuntime::merchant_inventory_target(
        int32_t market, int32_t good, int32_t signal_index,
        int64_t realized_withdrawal,
        int64_t export_ema, int64_t cold_start_daily_supply, int64_t &sat) const {
    if (market < 0 || market >= market_store().market_count.get() || good < 0 ||
        good >= market_store().good_count.get() || _good_storage_modes[good] != 0) return 0;
    const int64_t index = market_store().index(market, good);
    int64_t feasible_daily = market_store().demand_ema[index];
    if (signal_index >= 0) feasible_daily = saturating_add(
        feasible_daily, _market_signals.business_demand_ema[signal_index], sat);
    feasible_daily = saturating_add(
        feasible_daily,
        epoch_procurement_demand_daily_for_market(market, good), sat);
    int64_t protected_daily = std::max<int64_t>(
        std::max<int64_t>(0, realized_withdrawal), feasible_daily);
    // Preserve the configured inventory-day target and add a smoothed
    // producer-income floor. This avoids procurement collapsing solely
    // because a short demand EMA window dipped while producers stayed active.
    int64_t smoothed_supply = std::max<int64_t>(0, cold_start_daily_supply);
    if (signal_index >= 0 && signal_index < static_cast<int32_t>(
            _market_signals.offered_supply_ema.size())) {
        smoothed_supply = std::max<int64_t>(smoothed_supply,
            _market_signals.offered_supply_ema[signal_index]);
    }
    const bool survival_good = _survival_food_good_mask[good] != 0 ||
        _survival_clothing_good_mask[good] != 0;
    protected_daily = std::max<int64_t>(protected_daily,
        smoothed_supply / (survival_good ? 2 : 4));
    if (protected_daily == 0 && export_ema <= 0) {
        protected_daily = std::max<int64_t>(0, cold_start_daily_supply);
    }
    const int64_t relief_q16 = trade_relief_pressure_q16(market, good, sat);
    if (relief_q16 > 0) {
        const int64_t relief_base = std::max<int64_t>(
            std::max<int64_t>(protected_daily, feasible_daily),
            std::max<int64_t>(GOODS_SCALE, cold_start_daily_supply));
        protected_daily = saturating_add(protected_daily,
            mul_div_sat(relief_base, relief_q16, Q16_ONE, sat), sat);
    }
    int64_t target = mul_div_sat(saturating_add(
        protected_daily, std::max<int64_t>(0, export_ema), sat),
        _good_target_inventory_days_q16[good], Q16_ONE, sat);
    if (signal_index >= 0) {
        target = std::max(target, merchant_protected_reserve(signal_index));
    }
    return std::max<int64_t>(0, target);
}

int32_t NativeEconomyRuntime::cached_trade_route_cost(
        int32_t source, int32_t destination, int32_t country, int32_t &expansions) {
    expansions = 0;
    if (source == destination) return 0;
    const uint8_t cap = water_capability_for_country(country, true);
    const int32_t layer = water_layer_index(cap);
    if (source < 0 || destination < 0 || source >= _cell_count.get() || destination >= _cell_count.get() ||
        _trade_plan.route_cache_keys.empty())
        return -1;
    const int32_t source_component = trade_component_for(source, cap);
    if (source_component < 0 ||
        source_component != trade_component_for(destination, cap))
        return -1;
    const uint64_t key = trade_route_cache_key(source, destination, layer);
    const size_t mask = _trade_plan.route_cache_keys.size() - 1;
    size_t slot = static_cast<size_t>((key ^ (key >> 33) ^ (key >> 17)) & mask);
    for (size_t probe = 0; probe < 8; ++probe, slot = (slot + 1) & mask) {
        if (_trade_plan.route_cache_keys[slot] == key) {
            ++_trade_route_cache_hits;
            return _trade_plan.route_cache_costs[slot];
        }
        if (_trade_plan.route_cache_keys[slot] == std::numeric_limits<uint64_t>::max()) break;
    }
    ++_trade_route_cache_misses;
    if (++_trade_plan.search_stamp == 0) {
        std::fill(_trade_plan.distance_stamp.begin(), _trade_plan.distance_stamp.end(), 0);
        _trade_plan.search_stamp = 1;
    }
    const uint32_t stamp = _trade_plan.search_stamp;
    auto greater_node = [](const auto &a, const auto &b) {
        return a.first != b.first ? a.first > b.first : a.second > b.second;
    };
    _trade_plan.heap.clear();
    _trade_plan.distance[source] = 0;
    _trade_plan.distance_stamp[source] = stamp;
    _trade_plan.heap.push_back({0, source});
    std::push_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
    int32_t result = -1;
    while (!_trade_plan.heap.empty() && expansions < _trade_max_route_expansions.get()) {
        std::pop_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        const auto current = _trade_plan.heap.back();
        _trade_plan.heap.pop_back();
        const int32_t cell = current.second;
        if (_trade_plan.distance_stamp[cell] != stamp ||
            current.first != _trade_plan.distance[cell]) continue;
        ++expansions;
        if (cell == destination) {
            result = current.first > std::numeric_limits<int32_t>::max()
                ? -1 : static_cast<int32_t>(current.first);
            break;
        }
        collect_transport_successors(cell, cap, false);
        for (size_t i = 0; i < _transport_succ_cells.size(); ++i) {
            const int32_t neighbor = _transport_succ_cells[i];
            const int64_t next = current.first + std::max(1, _transport_succ_costs[i]);
            if (_trade_plan.distance_stamp[neighbor] == stamp &&
                _trade_plan.distance[neighbor] <= next) continue;
            _trade_plan.distance_stamp[neighbor] = stamp;
            _trade_plan.distance[neighbor] = next;
            _trade_plan.heap.push_back({next, neighbor});
            std::push_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        }
    }
    _trade_route_expansions += expansions;
    slot = static_cast<size_t>((key ^ (key >> 33) ^ (key >> 17)) & mask);
    for (size_t probe = 0; probe < 8; ++probe, slot = (slot + 1) & mask) {
        if (_trade_plan.route_cache_keys[slot] == std::numeric_limits<uint64_t>::max() ||
            _trade_plan.route_cache_keys[slot] == key) break;
    }
    _trade_plan.route_cache_keys[slot] = key;
    _trade_plan.route_cache_costs[slot] = result;
    return result;
}

bool NativeEconomyRuntime::route_trade_source(
        int32_t source_index, int32_t expansion_budget,
        int32_t &expansions_done, bool &source_done, std::string &error) {
    expansions_done = 0;
    source_done = false;
    if (source_index < 0 || source_index >= static_cast<int32_t>(_trade_plan.sources.size())) {
        error = "trade_source_cursor_invalid";
        return false;
    }
        if (_trade_plan.route_search_active &&
        _trade_plan.route_search_source != source_index) {
        error = "trade_route_search_source_mismatch";
        return false;
    }
    const TradeSignal &source = _trade_plan.sources[source_index];
    auto append_candidate = [&](const TradeSignal &destination, int32_t route_cost) {
        if (!trade_vision_allows_pair(source.cell, destination.cell)) {
            ++_trade_rejected_vision;
            record_trade_signal_attempt(
                destination.cell, source.good, TRADE_SIGNAL_DIAG_ROUTE);
            return false;
        }
        record_trade_signal_attempt(
            destination.cell, source.good, TRADE_SIGNAL_DIAG_NONE);
        int64_t sat = 0;
        // P2-A: the trade factor is a VOLUME factor, applied to what this source
        // offers. It used to be folded into the merchant capacity pool only, so
        // a country with idle capacity -- the normal state, since capacity is
        // sized from merchant population -- saw no effect at all from a card
        // that promises "this country trades 50% more".
        int32_t trade_factor_q16 = Q16_ONE;
        if (source.country >= 0 && source.country < static_cast<int32_t>(
                _epoch_country_trade_capacity_factor_q16.size())) {
            trade_factor_q16 = _epoch_country_trade_capacity_factor_q16[
                static_cast<size_t>(source.country)];
        }
        // A4: the per-good capacity factor multiplies the country one, so a card
        // that names a single good moves only that good's offered volume. Both
        // arrays default to Q16_ONE, so an absent stat stays exactly neutral and
        // this block cannot perturb a run without per-good modifiers.
        if (source.good >= 0 && source.country >= 0) {
            const size_t good_count = _good_ids.size();
            const size_t good_index = static_cast<size_t>(source.country) * good_count +
                static_cast<size_t>(source.good);
            if (good_count > 0 && static_cast<size_t>(source.good) < good_count &&
                good_index < _epoch_country_good_trade_capacity_factor_q16.size()) {
                const int32_t good_factor_q16 =
                    _epoch_country_good_trade_capacity_factor_q16[good_index];
                if (good_factor_q16 != Q16_ONE) {
                    const int64_t combined = mul_div_sat(
                        static_cast<int64_t>(trade_factor_q16),
                        static_cast<int64_t>(good_factor_q16), Q16_ONE, sat);
                    trade_factor_q16 = static_cast<int32_t>(
                        std::clamp<int64_t>(combined, 0, 0x7FFFFFFF));
                }
            }
        }
        const int64_t offered_quantity = trade_factor_q16 == Q16_ONE
            ? source.quantity
            : mul_div_sat(source.quantity, trade_factor_q16, Q16_ONE, sat);
        const int64_t requested_quantity = std::min(
            offered_quantity, destination.quantity);
        if (requested_quantity <= 0 || route_cost <= 0) return false;
        const int64_t relief_q16 = trade_relief_pressure_q16(
            destination.cell, source.good, sat);
        const bool relief_route = relief_q16 >= Q16_ONE / 8;
        int32_t source_price = 0;
        int32_t destination_price = 0;
        int64_t profit = 0;
        int64_t margin_q16 = 0;
        const int64_t quantity = profitable_trade_quantity(
            source.cell, destination.cell, source.good, requested_quantity,
            relief_route, source_price, destination_price, profit,
            margin_q16, sat);
        if (quantity <= 0) {
            int32_t unit_source = 0;
            int32_t unit_destination = 0;
            int64_t unit_profit = 0;
            int64_t unit_margin = 0;
            profitable_trade_quantity(source.cell, destination.cell, source.good,
                1, true, unit_source, unit_destination, unit_profit,
                unit_margin, sat);
            if (unit_destination <= unit_source) {
                ++_trade_rejected_no_spread;
                record_trade_signal_attempt(destination.cell, source.good,
                    TRADE_SIGNAL_DIAG_NO_SPREAD);
            } else {
                ++_trade_rejected_margin;
                record_trade_signal_attempt(destination.cell, source.good,
                    TRADE_SIGNAL_DIAG_MARGIN);
            }
            ++_trade_rejected_profit;
            return false;
        }
        if (quantity < requested_quantity) ++_trade_quantity_profit_clips;
        const int64_t load = mul_div_sat(quantity,
            _good_transport_load_per_unit_q16[source.good], GOODS_SCALE, sat);
        const int64_t capacity = saturating_mul(load, route_cost, sat);
        if (capacity <= 0) {
            ++_trade_rejected_profit;
            return false;
        }
        if (relief_route) ++_trade_relief_candidates;
        const TradeQuote line_quote = make_trade_quote(
            source.cell, destination.cell, source.good, quantity,
            source_price, destination_price, relief_route, sat);
        int64_t density_profit = line_quote.combined_profit;
        if (relief_route && density_profit <= 0) {
            density_profit = std::max<int64_t>(1, mul_div_sat(
                goods_cost(quantity, std::max<int64_t>(1, source_price), sat),
                std::max<int64_t>(1, relief_q16), Q16_ONE, sat));
        }
        TradeCandidate candidate;
        candidate.source = source.cell;
        candidate.destination = destination.cell;
        candidate.good = source.good;
        candidate.country = source.country;
        candidate.source_country = source.country;
        candidate.destination_country = destination.country;
        candidate.source_country_handle = source.country >= 0 &&
                source.country < static_cast<int32_t>(_epoch_country_handles.size())
            ? _epoch_country_handles[static_cast<size_t>(source.country)] : 0;
        candidate.destination_country_handle = destination.country >= 0 &&
                destination.country < static_cast<int32_t>(_epoch_country_handles.size())
            ? _epoch_country_handles[static_cast<size_t>(destination.country)] : 0;
        candidate.route_cost = route_cost;
        candidate.source_price = source_price;
        candidate.destination_price = destination_price;
        candidate.quantity = quantity;
        candidate.expected_profit = line_quote.combined_profit;
        candidate.base_value = line_quote.base;
        candidate.retail_value = line_quote.retail;
        candidate.import_transfer = line_quote.import_transfer;
        candidate.export_transfer = line_quote.export_transfer;
        candidate.capacity_work = capacity;
        candidate.density_q16 = mul_div_sat(
            density_profit, Q16_ONE, capacity, sat);
        candidate.signal_age_days = destination.age_days;
        candidate.response_priority = destination.response_priority;
        candidate.source_price_stock_generation =
            _cell_price_stock_gen[candidate.source];
        candidate.destination_price_stock_generation =
            _cell_price_stock_gen[candidate.destination];
        candidate.planned_day = _sample_day;
        candidate.topology_generation = _trade_topology.topology_generation;
        candidate.country_topology_hash = _epoch_country_topology_hash;
        if (line_quote.foreign) candidate.flags |= TRADE_LINE_FOREIGN;
        if (relief_route) candidate.flags |= TRADE_LINE_RELIEF;
        if (line_quote.import_transfer < 0)
            candidate.flags |= TRADE_LINE_IMPORT_SUBSIDY;
        else if (line_quote.import_transfer > 0)
            candidate.flags |= TRADE_LINE_IMPORT_TAX;
        if (line_quote.export_transfer < 0)
            candidate.flags |= TRADE_LINE_EXPORT_SUBSIDY;
        else if (line_quote.export_transfer > 0)
            candidate.flags |= TRADE_LINE_EXPORT_TAX;
        if (static_cast<int32_t>(_trade_plan.working_candidates.size()) <
            _trade_max_candidates.get()) {
            _trade_plan.working_candidates.push_back(candidate);
            ++_trade_candidates_generated;
            return true;
        }
        return false;
    };
    auto greater_node = [](const auto &a, const auto &b) {
        return a.first != b.first ? a.first > b.first : a.second > b.second;
    };

    auto destination_group_begin = [&]() {
        return std::lower_bound(
            _trade_plan.destinations.begin(), _trade_plan.destinations.end(), source,
            [](const TradeSignal &candidate, const TradeSignal &wanted) {
                return candidate.good < wanted.good;
            });
    };

    if (!_trade_plan.route_search_active) {
        const auto prepare_started = Clock::now();
        ++_trade_plan_route_sources_prepared_slice;
        _trade_plan.route_search_active = true;
        _trade_plan.route_search_source = source_index;
        _trade_plan.route_search_accepted = 0;
        _trade_plan.route_search_pending_targets = 0;
        _trade_plan.route_search_expansions = 0;
        const uint8_t cap = water_capability_for_country(source.country, true);
        const int32_t layer = water_layer_index(cap);
        const int32_t source_component = trade_component_for(source.cell, cap);
        if (_trade_plan.route_cache_keys.empty() || source_component < 0) {
            _trade_plan.route_search_active = false;
            _trade_plan.route_search_source = -1;
            source_done = true;
            _trade_plan_route_prepare_ms += elapsed_ms(prepare_started);
            return true;
        }
        if (++_trade_plan.search_stamp == 0) {
            std::fill(_trade_plan.distance_stamp.begin(), _trade_plan.distance_stamp.end(), 0);
            std::fill(_trade_plan.target_stamp.begin(), _trade_plan.target_stamp.end(), 0);
            _trade_plan.search_stamp = 1;
        }
        const uint32_t stamp = _trade_plan.search_stamp;
        const size_t mask = _trade_plan.route_cache_keys.size() - 1;
        const auto group_begin = destination_group_begin();
        for (auto it = group_begin; it != _trade_plan.destinations.end() &&
             it->good == source.good; ++it) {
            const TradeSignal &destination = *it;
            if (destination.cell == source.cell ||
                source_component != trade_component_for(destination.cell, cap)) continue;
            if (!trade_vision_allows_pair(source.cell, destination.cell)) {
                ++_trade_rejected_vision;
                record_trade_signal_attempt(
                    destination.cell, source.good, TRADE_SIGNAL_DIAG_ROUTE);
                continue;
            }
            const uint64_t key = trade_route_cache_key(
                source.cell, destination.cell, layer);
            size_t slot = static_cast<size_t>(
                (key ^ (key >> 33) ^ (key >> 17)) & mask);
            bool found = false;
            int32_t cached_cost = -1;
            for (size_t probe = 0; probe < 8; ++probe, slot = (slot + 1) & mask) {
                if (_trade_plan.route_cache_keys[slot] == key) {
                    found = true;
                    cached_cost = _trade_plan.route_cache_costs[slot];
                    break;
                }
                if (_trade_plan.route_cache_keys[slot] ==
                    std::numeric_limits<uint64_t>::max()) break;
            }
            if (found) {
                ++_trade_route_cache_hits;
                if (cached_cost > 0 &&
                    _trade_plan.route_search_accepted < _trade_target_count.get() &&
                    append_candidate(destination, cached_cost)) {
                    ++_trade_plan.route_search_accepted;
                } else if (cached_cost <= 0) {
                    record_trade_signal_attempt(
                        destination.cell, source.good, TRADE_SIGNAL_DIAG_ROUTE);
                }
                continue;
            }
            ++_trade_route_cache_misses;
            _trade_plan.target_stamp[destination.cell] = stamp;
            _trade_plan.target_signal[destination.cell] = static_cast<int32_t>(
                it - _trade_plan.destinations.begin());
            ++_trade_plan.route_search_pending_targets;
        }
        if (_trade_plan.route_search_accepted >= _trade_target_count.get() ||
            _trade_plan.route_search_pending_targets == 0) {
            _trade_plan.route_search_active = false;
            _trade_plan.route_search_source = -1;
            source_done = true;
            _trade_plan_route_prepare_ms += elapsed_ms(prepare_started);
            return true;
        }
        _trade_plan.heap.clear();
        _trade_plan.distance[source.cell] = 0;
        _trade_plan.distance_stamp[source.cell] = stamp;
        _trade_plan.heap.push_back({0, source.cell});
        std::push_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        _trade_plan_route_prepare_ms += elapsed_ms(prepare_started);
    }

    const uint32_t stamp = _trade_plan.search_stamp;
    const size_t mask = _trade_plan.route_cache_keys.size() - 1;
    const uint8_t cap = water_capability_for_country(source.country, true);
    const int32_t layer = water_layer_index(cap);
    const int32_t bounded_expansion_budget = std::max(0, expansion_budget);
    const auto expand_started = Clock::now();
    while (!_trade_plan.heap.empty() &&
           expansions_done < bounded_expansion_budget &&
           _trade_plan.route_search_expansions < _trade_max_route_expansions.get() &&
           _trade_plan.route_search_accepted < _trade_target_count.get() &&
           _trade_plan.route_search_pending_targets > 0) {
        std::pop_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        const auto current = _trade_plan.heap.back();
        _trade_plan.heap.pop_back();
        const int32_t cell = current.second;
        if (_trade_plan.distance_stamp[cell] != stamp ||
            _trade_plan.distance[cell] != current.first) continue;
        ++expansions_done;
        ++_trade_plan.route_search_expansions;
        if (_trade_plan.target_stamp[cell] == stamp) {
            _trade_plan.target_stamp[cell] = 0;
            --_trade_plan.route_search_pending_targets;
            const int32_t destination_index = _trade_plan.target_signal[cell];
            const int32_t route_cost = current.first > std::numeric_limits<int32_t>::max()
                ? -1 : static_cast<int32_t>(current.first);
            if (route_cost > 0) {
                const uint64_t key = trade_route_cache_key(source.cell, cell, layer);
                size_t slot = static_cast<size_t>(
                    (key ^ (key >> 33) ^ (key >> 17)) & mask);
                size_t insert_slot = slot;
                for (size_t probe = 0; probe < 8; ++probe, slot = (slot + 1) & mask) {
                    insert_slot = slot;
                    if (_trade_plan.route_cache_keys[slot] ==
                            std::numeric_limits<uint64_t>::max() ||
                        _trade_plan.route_cache_keys[slot] == key) break;
                }
                _trade_plan.route_cache_keys[insert_slot] = key;
                _trade_plan.route_cache_costs[insert_slot] = route_cost;
                if (destination_index >= 0 && destination_index <
                        static_cast<int32_t>(_trade_plan.destinations.size()) &&
                    append_candidate(_trade_plan.destinations[destination_index], route_cost))
                    ++_trade_plan.route_search_accepted;
            }
        }
        collect_transport_successors(cell, cap, false);
        for (size_t i = 0; i < _transport_succ_cells.size(); ++i) {
            const int32_t neighbor = _transport_succ_cells[i];
            const int64_t next = current.first + std::max(1, _transport_succ_costs[i]);
            if (_trade_plan.distance_stamp[neighbor] == stamp &&
                _trade_plan.distance[neighbor] <= next) continue;
            _trade_plan.distance_stamp[neighbor] = stamp;
            _trade_plan.distance[neighbor] = next;
            _trade_plan.heap.push_back({next, neighbor});
            std::push_heap(_trade_plan.heap.begin(), _trade_plan.heap.end(), greater_node);
        }
    }
    _trade_plan_route_expand_ms += elapsed_ms(expand_started);
    _trade_plan_route_expansions_slice += expansions_done;
    _trade_route_expansions += expansions_done;
    const auto finalize_started = Clock::now();
    const bool search_complete = _trade_plan.heap.empty() ||
        _trade_plan.route_search_expansions >= _trade_max_route_expansions.get() ||
        _trade_plan.route_search_accepted >= _trade_target_count.get() ||
        _trade_plan.route_search_pending_targets <= 0;
    if (!search_complete) {
        _trade_plan_route_finalize_ms += elapsed_ms(finalize_started);
        return true;
    }
    if (_trade_plan.route_search_accepted == 0 &&
        _trade_plan.route_search_expansions >= _trade_max_route_expansions.get()) {
        ++_trade_rejected_route;
        const auto group_begin = destination_group_begin();
        for (auto it = group_begin; it != _trade_plan.destinations.end() &&
             it->good == source.good; ++it) {
            record_trade_signal_attempt(
                it->cell, source.good, TRADE_SIGNAL_DIAG_ROUTE);
        }
    }
    _trade_plan.route_search_active = false;
    _trade_plan.route_search_source = -1;
    source_done = true;
    _trade_plan_route_finalize_ms += elapsed_ms(finalize_started);
    return true;
}

bool NativeEconomyRuntime::run_trade_planner_slice(
        int64_t &work_done, std::string &error) {
    const auto started = Clock::now();
    if (_trade_plan.phase == TradePlanStore::SCAN) {
        const auto scan_started = Clock::now();
        const int64_t scan_cursor_start = _trade_plan.scan_cursor;
        const int64_t end = std::min(_trade_plan.scan_total,
            _trade_plan.scan_cursor + _trade_signal_pairs_per_slice.get());
        for (; _trade_plan.scan_cursor < end; ++_trade_plan.scan_cursor) {
            const int32_t market = _trade_plan.scan_cells[_trade_plan.scan_cursor];
            const int32_t good = _trade_plan.scan_goods[_trade_plan.scan_cursor];
            ++work_done;
            if (_good_trade_enabled[good] == 0 || _good_storage_modes[good] != 0 ||
                market < 0 || market >= _cell_count.get() ||
                !good_market_available(market, good, true) ||
                _trade_topology.passable[market] == 0 ||
                _trade_topology.component[market] < 0) continue;
            const int32_t country = _epoch_cell_country[market];
            if (country < 0 || _merchant_offsets[market] >= _merchant_offsets[market + 1])
                continue;
            const int64_t index = market_store().index(market, good);
            int64_t sat = 0;
            const int64_t target = trade_local_stock_target(market, good, sat);
            const int64_t export_floor = trade_export_floor(market, good, sat);
            const int64_t stock = market_store().stock[index];
            if (stock > export_floor && static_cast<int32_t>(_trade_plan.sources.size()) <
                    _trade_max_signals.get()) {
                const int64_t cap = mul_div_sat(
                    stock, _trade_max_stock_share_q16.get(), Q16_ONE, sat);
                const int64_t quantity = std::min(stock - export_floor, cap);
                if (quantity > 0) _trade_plan.sources.push_back(
                    {market, good, country, market_store().price[index], quantity, 0});
            } else if (target > stock + _trade_plan.scan_inbound[_trade_plan.scan_cursor] &&
                       static_cast<int32_t>(_trade_plan.destinations.size()) <
                           _trade_max_signals.get()) {
                const int32_t signal_clock = ensure_trade_signal_clock_index(market, good);
                if (signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        _trade_signal_first_seen_day.size()) &&
                    _trade_signal_first_seen_day[signal_clock] < 0) {
                    _trade_signal_first_seen_day[signal_clock] = _sample_day;
                    ++_trade_deficit_episodes_started;
                    _trade_signal_first_dispatch_day[signal_clock] = -1;
                    _trade_signal_last_attempt_day[signal_clock] = -1;
                    _trade_signal_last_rejection_reason[signal_clock] =
                        TRADE_SIGNAL_DIAG_NONE;
                    _trade_signal_deadline_reported[signal_clock] = 0;
                }
                const int64_t first_seen = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        _trade_signal_first_seen_day.size())
                    ? _trade_signal_first_seen_day[signal_clock] : -1;
                const int32_t age = first_seen >= 0 ? static_cast<int32_t>(
                    std::clamp<int64_t>(_sample_day - first_seen, 0,
                                        std::numeric_limits<int32_t>::max())) : 0;
                _trade_signal_max_age_days = std::max<int64_t>(
                    _trade_signal_max_age_days, age);
                int32_t response_priority = 0;
                if (signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        _trade_signal_last_attempt_day.size()) &&
                    _trade_signal_last_attempt_day[signal_clock] >= 0) {
                    response_priority = 1;
                }
                if (signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        _trade_signal_first_dispatch_day.size()) &&
                    _trade_signal_first_dispatch_day[signal_clock] >= 0) {
                    response_priority = 2;
                }
                _trade_plan.destinations.push_back(
                    {market, good, country, market_store().price[index],
                     target - stock - _trade_plan.scan_inbound[_trade_plan.scan_cursor], age,
                     response_priority});
            }
        }
        _trade_plan_scan_body_ms += elapsed_ms(scan_started);
        _trade_plan_scan_pairs_slice += _trade_plan.scan_cursor - scan_cursor_start;
        if (_trade_plan.scan_cursor >= _trade_plan.scan_total) {
            const auto finalize_started = Clock::now();
            std::stable_sort(_trade_plan.sources.begin(), _trade_plan.sources.end(),
                [](const TradeSignal &a, const TradeSignal &b) {
                    if (a.good != b.good) return a.good < b.good;
                    if (a.country != b.country) return a.country < b.country;
                    if (a.price != b.price) return a.price < b.price;
                    if (a.quantity != b.quantity) return a.quantity > b.quantity;
                    return a.cell < b.cell;
                });
            std::stable_sort(_trade_plan.destinations.begin(), _trade_plan.destinations.end(),
                [](const TradeSignal &a, const TradeSignal &b) {
                    if (a.good != b.good) return a.good < b.good;
                    if (a.country != b.country) return a.country < b.country;
                    if (a.response_priority != b.response_priority)
                        return a.response_priority < b.response_priority;
                    if (a.age_days != b.age_days) return a.age_days > b.age_days;
                    if (a.price != b.price) return a.price > b.price;
                    if (a.quantity != b.quantity) return a.quantity > b.quantity;
                    return a.cell < b.cell;
                });
            for (const TradeSignal &destination : _trade_plan.destinations) {
                const auto source = std::lower_bound(
                    _trade_plan.sources.begin(), _trade_plan.sources.end(), destination,
                    [](const TradeSignal &candidate, const TradeSignal &wanted) {
                        return candidate.good < wanted.good;
                    });
                if (source == _trade_plan.sources.end() ||
                    source->good != destination.good) {
                    record_trade_signal_attempt(destination.cell, destination.good,
                                                TRADE_SIGNAL_DIAG_STOCK);
                }
            }
            // A dense world can expose thousands of tiny surplus cells for one
            // good. Routing every source makes a five-day planner take years to
            // complete while adding little economic value. Keep the strongest
            // deterministic per-country/good pools, then let the existing
            // nearest-target Dijkstra and profit clipping choose actual routes.
            auto keep_group_limit = [](std::vector<TradeSignal> &signals,
                                       int32_t limit) {
                if (signals.empty() || limit <= 0) return;
                std::vector<TradeSignal> kept;
                kept.reserve(signals.size());
                int32_t last_country = std::numeric_limits<int32_t>::min();
                int32_t last_good = std::numeric_limits<int32_t>::min();
                int32_t count = 0;
                for (const TradeSignal &signal : signals) {
                    if (signal.country != last_country || signal.good != last_good) {
                        last_country = signal.country;
                        last_good = signal.good;
                        count = 0;
                    }
                    if (count++ < limit) kept.push_back(signal);
                }
                signals.swap(kept);
            };
            keep_group_limit(_trade_plan.sources, 4);
            keep_group_limit(_trade_plan.destinations, 8);
            _trade_plan.phase = TradePlanStore::ROUTE;
            _trade_plan.route_cursor = 0;
            _trade_plan.route_search_active = false;
            _trade_plan.route_search_source = -1;
            _trade_plan.route_search_accepted = 0;
            _trade_plan.route_search_pending_targets = 0;
            _trade_plan.route_search_expansions = 0;
            _trade_plan_scan_finalize_ms += elapsed_ms(finalize_started);
        }
    } else if (_trade_plan.phase == TradePlanStore::ROUTE) {
        int32_t completed_sources = 0;
        int32_t expansion_budget = TRADE_ROUTE_EXPANSIONS_PER_SLICE;
        while (_trade_plan.route_cursor <
                   static_cast<int32_t>(_trade_plan.sources.size()) &&
               completed_sources < _trade_route_searches_per_slice.get()) {
            int32_t expansions_done = 0;
            bool source_done = false;
            if (!route_trade_source(
                    _trade_plan.route_cursor, expansion_budget,
                    expansions_done, source_done, error)) return false;
            work_done += expansions_done;
            expansion_budget -= expansions_done;
            if (!source_done) break;
            if (expansions_done == 0) ++work_done;
            ++_trade_plan.route_cursor;
            ++completed_sources;
            if (expansion_budget <= 0) break;
        }
        if (_trade_plan.route_cursor >= static_cast<int32_t>(_trade_plan.sources.size())) {
            const auto finalize_started = Clock::now();
            _trade_plan_candidates_finalized_slice = static_cast<int64_t>(
                _trade_plan.working_candidates.size());
            std::stable_sort(_trade_plan.working_candidates.begin(),
                _trade_plan.working_candidates.end(), [&](const TradeCandidate &a,
                                                          const TradeCandidate &b) {
                    const int32_t a_deadline = std::max(
                        0, _trade_response_days.get() - a.signal_age_days);
                    const int32_t b_deadline = std::max(
                        0, _trade_response_days.get() - b.signal_age_days);
                    if (a_deadline != b_deadline) return a_deadline < b_deadline;
                    if (a.response_priority != b.response_priority)
                        return a.response_priority < b.response_priority;
                    if (a.signal_age_days != b.signal_age_days)
                        return a.signal_age_days > b.signal_age_days;
                    if (a.density_q16 != b.density_q16) return a.density_q16 > b.density_q16;
                    if (a.expected_profit != b.expected_profit)
                        return a.expected_profit > b.expected_profit;
                    if (a.route_cost != b.route_cost) return a.route_cost < b.route_cost;
                    if (a.source != b.source) return a.source < b.source;
                    if (a.destination != b.destination) return a.destination < b.destination;
                    return a.good < b.good;
                });
            _trade_plan.ready_candidates.swap(_trade_plan.working_candidates);
            _trade_plan.phase = TradePlanStore::IDLE;
            _trade_plan.route_search_active = false;
            _trade_plan.route_search_source = -1;
            ++_trade_plan.completed_scans;
            _trade_plan_route_finalize_ms += elapsed_ms(finalize_started);
        }
    }
    _trade_plan_ms += elapsed_ms(started);
    return true;
}

int32_t NativeEconomyRuntime::trade_signal_clock_index(
        int32_t cell, int32_t good) const {
    const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
        static_cast<uint32_t>(good);
    const auto it = std::lower_bound(
        _trade_signal_clock_keys.begin(), _trade_signal_clock_keys.end(), key);
    return it != _trade_signal_clock_keys.end() && *it == key
        ? static_cast<int32_t>(it - _trade_signal_clock_keys.begin()) : -1;
}

int32_t NativeEconomyRuntime::ensure_trade_signal_clock_index(
        int32_t cell, int32_t good) {
    const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
        static_cast<uint32_t>(good);
    const auto it = std::lower_bound(
        _trade_signal_clock_keys.begin(), _trade_signal_clock_keys.end(), key);
    if (it != _trade_signal_clock_keys.end() && *it == key)
        return static_cast<int32_t>(it - _trade_signal_clock_keys.begin());
    const int32_t index = static_cast<int32_t>(it - _trade_signal_clock_keys.begin());
    _trade_signal_clock_keys.insert(it, key);
    _trade_signal_first_seen_day.insert(
        _trade_signal_first_seen_day.begin() + index, -1);
    _trade_signal_first_dispatch_day.insert(
        _trade_signal_first_dispatch_day.begin() + index, -1);
    _trade_signal_last_attempt_day.insert(
        _trade_signal_last_attempt_day.begin() + index, -1);
    _trade_signal_last_rejection_reason.insert(
        _trade_signal_last_rejection_reason.begin() + index, TRADE_SIGNAL_DIAG_NONE);
    _trade_signal_deadline_reported.insert(
        _trade_signal_deadline_reported.begin() + index, 0);
    return index;
}

void NativeEconomyRuntime::ensure_trade_signal_clock_keys_bulk(
        const std::vector<uint64_t> &sorted_unique_keys) {
    if (sorted_unique_keys.empty()) return;
    bool has_missing = false;
    for (const uint64_t key : sorted_unique_keys) {
        if (!std::binary_search(
                _trade_signal_clock_keys.begin(),
                _trade_signal_clock_keys.end(), key)) {
            has_missing = true;
            break;
        }
    }
    if (!has_missing) return;

    const size_t old_size = _trade_signal_clock_keys.size();
    const bool aligned =
        _trade_signal_first_seen_day.size() == old_size &&
        _trade_signal_first_dispatch_day.size() == old_size &&
        _trade_signal_last_attempt_day.size() == old_size &&
        _trade_signal_last_rejection_reason.size() == old_size &&
        _trade_signal_deadline_reported.size() == old_size;
    if (!aligned) {
        _trade_signal_clock_keys.clear();
        _trade_signal_first_seen_day.clear();
        _trade_signal_first_dispatch_day.clear();
        _trade_signal_last_attempt_day.clear();
        _trade_signal_last_rejection_reason.clear();
        _trade_signal_deadline_reported.clear();
    }

    thread_local std::vector<uint64_t> next_keys;
    thread_local std::vector<int64_t> next_first_seen;
    thread_local std::vector<int64_t> next_first_dispatch;
    thread_local std::vector<int64_t> next_last_attempt;
    thread_local std::vector<int32_t> next_rejection;
    thread_local std::vector<uint8_t> next_deadline;
    const size_t reserve_size = _trade_signal_clock_keys.size() +
        sorted_unique_keys.size();
    next_keys.clear();
    next_first_seen.clear();
    next_first_dispatch.clear();
    next_last_attempt.clear();
    next_rejection.clear();
    next_deadline.clear();
    next_keys.reserve(reserve_size);
    next_first_seen.reserve(reserve_size);
    next_first_dispatch.reserve(reserve_size);
    next_last_attempt.reserve(reserve_size);
    next_rejection.reserve(reserve_size);
    next_deadline.reserve(reserve_size);

    auto append_new = [&](uint64_t key) {
        next_keys.push_back(key);
        next_first_seen.push_back(-1);
        next_first_dispatch.push_back(-1);
        next_last_attempt.push_back(-1);
        next_rejection.push_back(TRADE_SIGNAL_DIAG_NONE);
        next_deadline.push_back(0);
    };
    auto append_old = [&](size_t index) {
        next_keys.push_back(_trade_signal_clock_keys[index]);
        next_first_seen.push_back(_trade_signal_first_seen_day[index]);
        next_first_dispatch.push_back(_trade_signal_first_dispatch_day[index]);
        next_last_attempt.push_back(_trade_signal_last_attempt_day[index]);
        next_rejection.push_back(_trade_signal_last_rejection_reason[index]);
        next_deadline.push_back(_trade_signal_deadline_reported[index]);
    };

    size_t old_cursor = 0;
    size_t requested_cursor = 0;
    while (old_cursor < _trade_signal_clock_keys.size() &&
           requested_cursor < sorted_unique_keys.size()) {
        const uint64_t old_key = _trade_signal_clock_keys[old_cursor];
        const uint64_t requested_key = sorted_unique_keys[requested_cursor];
        if (old_key < requested_key) {
            append_old(old_cursor++);
        } else if (requested_key < old_key) {
            append_new(requested_key);
            ++requested_cursor;
        } else {
            append_old(old_cursor++);
            ++requested_cursor;
        }
    }
    while (old_cursor < _trade_signal_clock_keys.size())
        append_old(old_cursor++);
    while (requested_cursor < sorted_unique_keys.size())
        append_new(sorted_unique_keys[requested_cursor++]);

    _trade_signal_clock_keys.swap(next_keys);
    _trade_signal_first_seen_day.swap(next_first_seen);
    _trade_signal_first_dispatch_day.swap(next_first_dispatch);
    _trade_signal_last_attempt_day.swap(next_last_attempt);
    _trade_signal_last_rejection_reason.swap(next_rejection);
    _trade_signal_deadline_reported.swap(next_deadline);
}

void NativeEconomyRuntime::record_trade_signal_attempt(
        int32_t cell, int32_t good, int32_t reason) {
    const int32_t index = ensure_trade_signal_clock_index(cell, good);
    if (index < 0 || index >= static_cast<int32_t>(
            _trade_signal_last_attempt_day.size())) return;
    _trade_signal_last_attempt_day[index] = _sample_day;
    if (_trade_signal_last_attempt_day[index] == _sample_day &&
        _trade_signal_last_rejection_reason[index] == TRADE_SIGNAL_DIAG_DISPATCHED &&
        reason != TRADE_SIGNAL_DIAG_DISPATCHED) return;
    _trade_signal_last_rejection_reason[index] = reason;
}

void NativeEconomyRuntime::refresh_trade_response_diagnostics() {
    _trade_signal_max_age_days = 0;
    _trade_response_deadline_misses = 0;
    _trade_unresolved_no_attempt = 0;
    _trade_unresolved_no_spread = 0;
    _trade_unresolved_margin = 0;
    _trade_unresolved_route = 0;
    _trade_unresolved_stock = 0;
    _trade_unresolved_capacity = 0;
    _trade_unresolved_cash = 0;
    _trade_unresolved_order_cap = 0;
    const size_t count = std::min({
        _trade_signal_first_seen_day.size(),
        _trade_signal_first_dispatch_day.size(),
        _trade_signal_deadline_reported.size(),
    });
    for (size_t index = 0; index < count; ++index) {
        const int64_t first_seen = _trade_signal_first_seen_day[index];
        if (first_seen < 0) continue;
        const int64_t age = std::max<int64_t>(0, _sample_day - first_seen);
        _trade_signal_max_age_days = std::max(_trade_signal_max_age_days, age);
        if (_trade_signal_first_dispatch_day[index] >= 0 ||
            age <= _trade_response_days.get()) continue;
        ++_trade_response_deadline_misses;
        switch (_trade_signal_last_rejection_reason[index]) {
            case TRADE_SIGNAL_DIAG_NO_SPREAD: ++_trade_unresolved_no_spread; break;
            case TRADE_SIGNAL_DIAG_MARGIN: ++_trade_unresolved_margin; break;
            case TRADE_SIGNAL_DIAG_ROUTE: ++_trade_unresolved_route; break;
            case TRADE_SIGNAL_DIAG_STOCK: ++_trade_unresolved_stock; break;
            case TRADE_SIGNAL_DIAG_CAPACITY: ++_trade_unresolved_capacity; break;
            case TRADE_SIGNAL_DIAG_CASH: ++_trade_unresolved_cash; break;
            case TRADE_SIGNAL_DIAG_ORDER_CAP: ++_trade_unresolved_order_cap; break;
            default: ++_trade_unresolved_no_attempt; break;
        }
        if (_trade_signal_deadline_reported[index] == 0) {
            _trade_signal_deadline_reported[index] = 1;
            ++_trade_response_deadline_misses_cumulative;
        }
    }
}

int32_t NativeEconomyRuntime::trade_flow_index(
        int32_t cell, int32_t good, bool create) {
    size_t lo = 0;
    size_t hi = _trade_flows.cells.size();
    while (lo < hi) {
        const size_t mid = lo + (hi - lo) / 2;
        if (_trade_flows.cells[mid] < cell ||
            (_trade_flows.cells[mid] == cell && _trade_flows.goods[mid] < good))
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo < _trade_flows.cells.size() && _trade_flows.cells[lo] == cell &&
        _trade_flows.goods[lo] == good) return static_cast<int32_t>(lo);
    if (!create) return -1;
    if (static_cast<int32_t>(_trade_flows.cells.size()) >= _trade_max_signals.get())
        return -1;
    const auto pos = static_cast<std::ptrdiff_t>(lo);
    _trade_flows.cells.insert(_trade_flows.cells.begin() + pos, cell);
    _trade_flows.goods.insert(_trade_flows.goods.begin() + pos, good);
    _trade_flows.import_ema.insert(_trade_flows.import_ema.begin() + pos, 0);
    _trade_flows.export_ema.insert(_trade_flows.export_ema.begin() + pos, 0);
    _trade_flows.period_import.insert(_trade_flows.period_import.begin() + pos, 0);
    _trade_flows.period_export.insert(_trade_flows.period_export.begin() + pos, 0);
    return static_cast<int32_t>(lo);
}

void NativeEconomyRuntime::update_trade_flow_ema() {
    int64_t sat = 0;
    const int64_t alpha = std::min<int64_t>(Q16_ONE, saturating_mul(
        _trade_flow_ema_alpha_q16.get(), std::max(1, _epoch_days.get()), sat));
    for (size_t i = 0; i < _trade_flows.cells.size(); ++i) {
        const int64_t observed_import = _trade_flows.period_import[i] /
            std::max(1, _epoch_days.get());
        const int64_t observed_export = _trade_flows.period_export[i] /
            std::max(1, _epoch_days.get());
        _trade_flows.import_ema.write_scalar(i, saturating_add(
            _trade_flows.import_ema[i], mul_div_sat(
                observed_import - _trade_flows.import_ema[i], alpha, Q16_ONE, sat), sat), market_mutation_sink());
        _trade_flows.export_ema.write_scalar(i, saturating_add(
            _trade_flows.export_ema[i], mul_div_sat(
                observed_export - _trade_flows.export_ema[i], alpha, Q16_ONE, sat), sat), market_mutation_sink());
        _trade_flows.period_import.write_scalar(i, 0, market_mutation_sink());
        _trade_flows.period_export.write_scalar(i, 0, market_mutation_sink());
    }
    _saturation_count = saturating_add(_saturation_count, sat, _saturation_count);
}

int64_t NativeEconomyRuntime::trade_transit_goods() const {
    int64_t total = 0;
    int64_t sat = 0;
    for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
        if (trade_orders_store().cargo_delivered[order] != 0) continue;
        for (int32_t line = trade_orders_store().line_offsets[order];
             line < trade_orders_store().line_offsets[order + 1]; ++line)
            total = saturating_add(total, trade_orders_store().line_quantities[line], sat);
    }
    return total;
}

int64_t NativeEconomyRuntime::trade_escrow_cash() const {
    int64_t total = 0;
    int64_t sat = 0;
    for (int64_t cash : trade_orders_store().cash_escrow)
        total = saturating_add(total, cash, sat);
    return total;
}

} // namespace pk
