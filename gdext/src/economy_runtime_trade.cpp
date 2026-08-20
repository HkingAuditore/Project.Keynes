#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <numeric>
#include <unordered_map>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;
constexpr int32_t PRICE_NUMERIC_GUARD_MIN = 1;
constexpr int32_t PRICE_NUMERIC_GUARD_MAX = std::numeric_limits<int32_t>::max();
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
        int32_t count, uint64_t generation, std::string &error) {
    if (!_configured || count != _cell_count || neighbor_indices == nullptr ||
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
    for (int32_t cell = 0; cell < count; ++cell) {
        const uint8_t terrain_id = terrain[cell];
        passable[cell] = trade_passable_lut[terrain_id] != 0 ? 1 : 0;
        enter_cost[cell] = passable[cell] != 0 ? trade_move_cost_lut[terrain_id] : 0;
        if (passable[cell] != 0 && enter_cost[cell] <= 0) {
            error = "trade_passable_cell_has_nonpositive_cost";
            return false;
        }
        mix_u32(passable[cell]);
        mix_u32(static_cast<uint32_t>(enter_cost[cell]));
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
    if (_trade_topology.ready) {
        ++_trade_topology_content_change_count;
        ++_trade_plan_reset_count;
        _trade_last_plan_reset_reason = "normalized_topology_changed";
    } else {
        _trade_last_plan_reset_reason = "initial_topology_capture";
    }
    const uint64_t resolved_generation = std::max<uint64_t>(
        _trade_topology.topology_generation + 1, generation != 0 ? generation : 1);
    _trade_topology.neighbors.swap(neighbors);
    _trade_topology.passable.swap(passable);
    _trade_topology.enter_cost.swap(enter_cost);
    _trade_topology.edge_cost.swap(edge_cost);
    _trade_topology.canal_edge_mask.swap(canal_mask);
    _trade_topology.canal_water.swap(canal_water_snapshot);
    _trade_topology.component.assign(static_cast<size_t>(count), -1);
    _trade_topology.topology_hash = normalized_hash;
    _trade_topology.topology_generation = resolved_generation;
    _trade_topology.component_country_hash = 0;
    _trade_topology.ready = true;
    _trade_plan.clear_transient();
    return true;
}

bool NativeEconomyRuntime::capture_trade_visibility(
        const uint8_t *visible, int32_t count, bool fog_solved, bool from_map,
        std::string &error) {
    _trade_visibility_manual = !from_map;
    _epoch_player_country_slot = _country_runtime != nullptr
        ? _country_runtime->starting_country_slot() : -1;
    if (!fog_solved) {
        _epoch_trade_vision_gated = false;
        _epoch_cell_visible.clear();
        return true;
    }
    if (!_configured || visible == nullptr || count != _cell_count) {
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
    if (source < 0 || destination < 0 || source >= _cell_count ||
        destination >= _cell_count) return false;
    if (_epoch_cell_visible.size() != static_cast<size_t>(_cell_count)) return true;
    const int32_t player = _epoch_player_country_slot;
    if (player < 0) return true;
    if (_epoch_cell_country.size() != static_cast<size_t>(_cell_count)) return true;
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
    if (!_trade_topology.ready || count != _cell_count ||
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
    _trade_topology.component_country_hash = 0;
    _trade_topology.component.assign(static_cast<size_t>(count), -1);
    ++_trade_topology_content_change_count;
    ++_trade_plan_reset_count;
    _trade_last_plan_reset_reason = "canal_topology_changed";
    _trade_plan.clear_transient();
    return true;
}

int32_t NativeEconomyRuntime::trade_edge_cost(
        int32_t from_cell, int32_t to_cell) const {
    if (from_cell < 0 || from_cell >= _cell_count || to_cell < 0 ||
        to_cell >= _cell_count) return 0;
    for (int direction = 0; direction < 6; ++direction) {
        if (_trade_topology.neighbors[from_cell * 6 + direction] == to_cell) {
            if (_trade_topology.edge_cost.size() ==
                    static_cast<size_t>(_cell_count) * 6)
                return std::max(1, _trade_topology.edge_cost[
                    from_cell * 6 + direction]);
            return std::max(1, _trade_topology.enter_cost[to_cell]);
        }
    }
    return 0;
}


int32_t NativeEconomyRuntime::estimate_trade_price(
        int32_t market, int32_t good, int64_t stock_after, int64_t &sat) const {
    const int64_t index = _market.index(market, good);
    const int32_t signal = market_signal_index(market, good);
    const PricePressure pressure = price_pressure(
        market, good, _market.demand_ema[index], std::max<int64_t>(0, stock_after),
        _market.last_shortage_q16[index], signal, sat);
    bool rate_clamped = false;
    const int64_t next = next_price_v4(good, _market.price[index], pressure,
        std::max(1, _epoch_days), sat, rate_clamped);
    return static_cast<int32_t>(std::clamp<int64_t>(
        next, PRICE_NUMERIC_GUARD_MIN, PRICE_NUMERIC_GUARD_MAX));
}

int64_t NativeEconomyRuntime::trade_relief_pressure_q16(
        int32_t market, int32_t good, int64_t &sat) const {
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count) return 0;
    const int64_t index = _market.index(market, good);
    int64_t pressure = 0;
    const bool survival_good =
        (good < static_cast<int32_t>(_survival_food_good_mask.size()) &&
         _survival_food_good_mask[good] != 0) ||
        (good < static_cast<int32_t>(_survival_clothing_good_mask.size()) &&
         _survival_clothing_good_mask[good] != 0);
    if (survival_good) {
        pressure = std::max<int64_t>(pressure,
            std::clamp<int64_t>(_market.last_shortage_q16[index], 0, Q16_ONE));
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
    if (signal >= 0 && signal < static_cast<int32_t>(
            _production_input_reserve.size())) {
        const int64_t reserve = std::max<int64_t>(0, _production_input_reserve[signal]);
        const int64_t stock = std::max<int64_t>(0, _market.stock[index]);
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
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count) return 0;
    const int64_t index = _market.index(market, good);
    int64_t demand = _market.demand_ema[index];
    const int32_t signal = market_signal_index(market, good);
    if (signal >= 0) demand = saturating_add(
        demand, _market_signals.business_demand_ema[signal], sat);
    const int64_t relief_q16 = trade_relief_pressure_q16(market, good, sat);
    if (relief_q16 > 0) {
        const int64_t relief_base = std::max<int64_t>(demand, GOODS_SCALE);
        demand = saturating_add(demand,
            mul_div_sat(relief_base, relief_q16, Q16_ONE, sat), sat);
    }
    int64_t target = mul_div_sat(
        demand, _good_target_inventory_days_q16[good], Q16_ONE, sat);
    target = mul_div_sat(target, _trade_import_fill_fraction_q16, Q16_ONE, sat);
    if (signal >= 0 && signal < static_cast<int32_t>(
            _production_input_reserve.size())) {
        target = std::max(target, _production_input_reserve[signal]);
    }
    return std::max<int64_t>(0, target);
}

int64_t NativeEconomyRuntime::trade_export_floor(
        int32_t market, int32_t good, int64_t &sat) const {
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count) return 0;
    const int32_t signal = market_signal_index(market, good);
    const int32_t flow = const_cast<NativeEconomyRuntime *>(this)->trade_flow_index(
        market, good, false);
    const int64_t realized = signal >= 0
        ? _market_signals.realized_withdrawal_ema[signal] : 0;
    const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
    const int64_t stock = _market.stock[_market.index(market, good)];
    const int64_t merchant_target = merchant_inventory_target(
        market, good, signal, realized, exports, 0, sat);
    int64_t floor = mul_div_sat(
        merchant_target, _trade_export_inventory_fraction_q16, Q16_ONE, sat);
    floor = std::max(floor, saturating_mul(
        realized, _trade_export_floor_days, sat));
    if (signal >= 0 && signal < static_cast<int32_t>(_production_input_reserve.size())) {
        floor = std::max(floor, _production_input_reserve[signal]);
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
    const int64_t source_stock = _market.stock[_market.index(source, good)];
    const int64_t destination_stock = _market.stock[_market.index(destination, good)];
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
               trade_quote.margin_q16 >= _trade_min_margin_q16));
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
    quote.base = mul_div_sat(std::max<int64_t>(0, quantity),
        quote.source_price, GOODS_SCALE, saturation_count);
    quote.retail = mul_div_sat(std::max<int64_t>(0, quantity),
        quote.destination_price, GOODS_SCALE, saturation_count);
    const int32_t source_country = source >= 0 &&
            source < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[static_cast<size_t>(source)] : -1;
    const int32_t destination_country = destination >= 0 &&
            destination < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[static_cast<size_t>(destination)] : -1;
    quote.foreign = source_country >= 0 && destination_country >= 0 &&
        source_country != destination_country;
    if (quote.foreign) {
        const int8_t import_rate = frozen_tax_rate(
            destination, NativeCountryRuntime::TAX_IMPORT, good);
        const int8_t export_rate = frozen_tax_rate(
            source, NativeCountryRuntime::TAX_EXPORT, good);
        const int64_t import_amount = mul_div_sat(
            quote.base, std::abs(static_cast<int32_t>(import_rate)), 100,
            saturation_count);
        const int64_t export_amount = mul_div_sat(
            quote.base, std::abs(static_cast<int32_t>(export_rate)), 100,
            saturation_count);
        quote.import_transfer = import_rate < 0 ? -import_amount : import_amount;
        quote.export_transfer = export_rate < 0 ? -export_amount : export_amount;
    }
    quote.importer_outlay = saturating_add(
        quote.base, quote.import_transfer, saturation_count);
    quote.exporter_receipt = saturating_sub(
        quote.base, quote.export_transfer, saturation_count);
    quote.importer_profit = saturating_sub(
        quote.retail, quote.importer_outlay, saturation_count);
    quote.combined_profit = saturating_sub(
        saturating_sub(saturating_sub(quote.retail, quote.base, saturation_count),
                       quote.import_transfer, saturation_count),
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
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count || _good_storage_modes[good] != 0) return 0;
    const int64_t index = _market.index(market, good);
    int64_t feasible_daily = _market.demand_ema[index];
    if (signal_index >= 0) feasible_daily = saturating_add(
        feasible_daily, _market_signals.business_demand_ema[signal_index], sat);
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
    if (signal_index >= 0 && signal_index < static_cast<int32_t>(
            _production_input_reserve.size())) {
        target = std::max(target, _production_input_reserve[signal_index]);
    }
    return std::max<int64_t>(0, target);
}

int32_t NativeEconomyRuntime::cached_trade_route_cost(
        int32_t source, int32_t destination, int32_t country, int32_t &expansions) {
    (void)country;
    expansions = 0;
    if (source == destination) return 0;
    if (source < 0 || destination < 0 || source >= _cell_count || destination >= _cell_count ||
        _trade_plan.route_cache_keys.empty() || _trade_topology.component[source] < 0 ||
        _trade_topology.component[source] != _trade_topology.component[destination])
        return -1;
    const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(source)) << 32) |
                         static_cast<uint32_t>(destination);
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
    while (!_trade_plan.heap.empty() && expansions < _trade_max_route_expansions) {
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
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(cell) * 6 + direction];
            if (neighbor < 0 || _trade_topology.passable[neighbor] == 0) continue;
            const int64_t next = current.first + std::max(1,
                _trade_topology.edge_cost[static_cast<size_t>(cell) * 6 + direction]);
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
        const int64_t requested_quantity = std::min(
            source.quantity, destination.quantity);
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
                mul_div_sat(quantity, std::max<int64_t>(1, source_price),
                            GOODS_SCALE, sat),
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
            _trade_max_candidates) {
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
        if (_trade_plan.route_cache_keys.empty() ||
            _trade_topology.component[source.cell] < 0) {
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
                _trade_topology.component[source.cell] !=
                    _trade_topology.component[destination.cell]) continue;
            if (!trade_vision_allows_pair(source.cell, destination.cell)) {
                ++_trade_rejected_vision;
                record_trade_signal_attempt(
                    destination.cell, source.good, TRADE_SIGNAL_DIAG_ROUTE);
                continue;
            }
            const uint64_t key =
                (static_cast<uint64_t>(static_cast<uint32_t>(source.cell)) << 32) |
                static_cast<uint32_t>(destination.cell);
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
                    _trade_plan.route_search_accepted < _trade_target_count &&
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
        if (_trade_plan.route_search_accepted >= _trade_target_count ||
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
    const int32_t bounded_expansion_budget = std::max(0, expansion_budget);
    const auto expand_started = Clock::now();
    while (!_trade_plan.heap.empty() &&
           expansions_done < bounded_expansion_budget &&
           _trade_plan.route_search_expansions < _trade_max_route_expansions &&
           _trade_plan.route_search_accepted < _trade_target_count &&
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
                const uint64_t key =
                    (static_cast<uint64_t>(static_cast<uint32_t>(source.cell)) << 32) |
                    static_cast<uint32_t>(cell);
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
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(cell) * 6 + direction];
            if (neighbor < 0 || _trade_topology.passable[neighbor] == 0) continue;
            const int64_t next = current.first + std::max(1,
                _trade_topology.edge_cost[static_cast<size_t>(cell) * 6 + direction]);
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
        _trade_plan.route_search_expansions >= _trade_max_route_expansions ||
        _trade_plan.route_search_accepted >= _trade_target_count ||
        _trade_plan.route_search_pending_targets <= 0;
    if (!search_complete) {
        _trade_plan_route_finalize_ms += elapsed_ms(finalize_started);
        return true;
    }
    if (_trade_plan.route_search_accepted == 0 &&
        _trade_plan.route_search_expansions >= _trade_max_route_expansions) {
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
            _trade_plan.scan_cursor + _trade_signal_pairs_per_slice);
        for (; _trade_plan.scan_cursor < end; ++_trade_plan.scan_cursor) {
            const int32_t market = _trade_plan.scan_cells[_trade_plan.scan_cursor];
            const int32_t good = _trade_plan.scan_goods[_trade_plan.scan_cursor];
            ++work_done;
            if (_good_trade_enabled[good] == 0 || _good_storage_modes[good] != 0 ||
                market < 0 || market >= _cell_count ||
                !good_market_available(market, good, true) ||
                _trade_topology.passable[market] == 0 ||
                _trade_topology.component[market] < 0) continue;
            const int32_t country = _epoch_cell_country[market];
            if (country < 0 || _merchant_offsets[market] >= _merchant_offsets[market + 1])
                continue;
            const int64_t index = _market.index(market, good);
            int64_t sat = 0;
            const int64_t target = trade_local_stock_target(market, good, sat);
            const int64_t export_floor = trade_export_floor(market, good, sat);
            const int64_t stock = _market.stock[index];
            if (stock > export_floor && static_cast<int32_t>(_trade_plan.sources.size()) <
                    _trade_max_signals) {
                const int64_t cap = mul_div_sat(
                    stock, _trade_max_stock_share_q16, Q16_ONE, sat);
                const int64_t quantity = std::min(stock - export_floor, cap);
                if (quantity > 0) _trade_plan.sources.push_back(
                    {market, good, country, _market.price[index], quantity, 0});
            } else if (target > stock + _trade_plan.scan_inbound[_trade_plan.scan_cursor] &&
                       static_cast<int32_t>(_trade_plan.destinations.size()) <
                           _trade_max_signals) {
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
                    {market, good, country, _market.price[index],
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
               completed_sources < _trade_route_searches_per_slice) {
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
                        0, _trade_response_days - a.signal_age_days);
                    const int32_t b_deadline = std::max(
                        0, _trade_response_days - b.signal_age_days);
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
            age <= _trade_response_days) continue;
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
    if (static_cast<int32_t>(_trade_flows.cells.size()) >= _trade_max_signals)
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
        _trade_flow_ema_alpha_q16, std::max(1, _epoch_days), sat));
    for (size_t i = 0; i < _trade_flows.cells.size(); ++i) {
        const int64_t observed_import = _trade_flows.period_import[i] /
            std::max(1, _epoch_days);
        const int64_t observed_export = _trade_flows.period_export[i] /
            std::max(1, _epoch_days);
        _trade_flows.import_ema[i] = saturating_add(
            _trade_flows.import_ema[i], mul_div_sat(
                observed_import - _trade_flows.import_ema[i], alpha, Q16_ONE, sat), sat);
        _trade_flows.export_ema[i] = saturating_add(
            _trade_flows.export_ema[i], mul_div_sat(
                observed_export - _trade_flows.export_ema[i], alpha, Q16_ONE, sat), sat);
        _trade_flows.period_import[i] = 0;
        _trade_flows.period_export[i] = 0;
    }
    _saturation_count = saturating_add(_saturation_count, sat, _saturation_count);
}

int64_t NativeEconomyRuntime::credit_trade_sellers(
        int32_t order_index, int64_t amount, int32_t cashflow_source) {
    if (order_index < 0 || order_index >= _trade_orders.size() || amount <= 0) return 0;
    const int32_t begin = _trade_orders.seller_offsets[order_index];
    const int32_t end = _trade_orders.seller_offsets[order_index + 1];
    int64_t total_weight = 0;
    std::vector<std::pair<int32_t, int64_t>> valid;
    valid.reserve(static_cast<size_t>(std::max(0, end - begin)));
    for (int32_t i = begin; i < end; ++i) {
        int32_t slot = -1;
        if (!_population.valid_handle(_trade_orders.seller_handles[i], slot) ||
            !is_merchant_slot(slot) ||
            _population.page_cell[slot / COHORT_PAGE_SIZE] != _trade_orders.sources[order_index])
            continue;
        const int64_t weight = std::max<int64_t>(1, _trade_orders.seller_weights[i]);
        valid.push_back({slot, weight});
        total_weight = saturating_add(total_weight, weight, _saturation_count);
    }
    if (valid.empty() || total_weight <= 0) {
        const int64_t credited = credit_local_merchants(
            _trade_orders.sources[order_index], amount,
            cashflow_source);
        if (credited > 0) {
            _merchant_trade_sale_cash = saturating_add(
                _merchant_trade_sale_cash, credited, _saturation_count);
            const int32_t cell = _trade_orders.sources[order_index];
            if (cell >= 0 && cell < static_cast<int32_t>(
                    _merchant_trade_sale_by_cell.size())) {
                _merchant_trade_sale_by_cell[cell] = saturating_add(
                    _merchant_trade_sale_by_cell[cell], credited,
                    _saturation_count);
            }
        }
        return credited;
    }
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (const auto &entry : valid) {
        const int32_t slot = entry.first;
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, entry.second, _saturation_count);
        const int64_t next = mul_div_sat(amount, prefix, total_weight, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        _population.funds[slot] = saturating_add(
            _population.funds[slot], share, _saturation_count);
        _population.epoch_income[slot] = saturating_add(
            _population.epoch_income[slot], share, _saturation_count);
        trace_record_cashflow(_trade_orders.sources[order_index],
            _population.handle_for_slot(slot), cashflow_source, share, 0);
    }
    if (distributed > 0) {
        _merchant_trade_sale_cash = saturating_add(
            _merchant_trade_sale_cash, distributed, _saturation_count);
        const int32_t cell = _trade_orders.sources[order_index];
        if (cell >= 0 && cell < static_cast<int32_t>(
                _merchant_trade_sale_by_cell.size())) {
            _merchant_trade_sale_by_cell[cell] = saturating_add(
                _merchant_trade_sale_by_cell[cell], distributed,
                _saturation_count);
        }
    }
    return distributed;
}

int64_t NativeEconomyRuntime::debit_trade_sellers(
        int32_t order_index, int64_t amount, int32_t cashflow_source) {
    if (order_index < 0 || order_index >= _trade_orders.size() || amount <= 0)
        return 0;
    const int32_t begin = _trade_orders.seller_offsets[order_index];
    const int32_t end = _trade_orders.seller_offsets[order_index + 1];
    std::vector<std::pair<int32_t, int64_t>> valid;
    valid.reserve(static_cast<size_t>(std::max(0, end - begin)));
    int64_t total_funds = 0;
    for (int32_t i = begin; i < end; ++i) {
        int32_t slot = -1;
        if (!_population.valid_handle(_trade_orders.seller_handles[i], slot) ||
            !is_merchant_slot(slot) ||
            _population.page_cell[slot / COHORT_PAGE_SIZE] !=
                _trade_orders.sources[order_index]) continue;
        const int64_t funds = std::max<int64_t>(0, _population.funds[slot]);
        if (funds <= 0) continue;
        valid.push_back({slot, funds});
        total_funds = saturating_add(total_funds, funds, _saturation_count);
    }
    if (valid.empty() || total_funds <= 0)
        return debit_local_merchants(_trade_orders.sources[order_index], amount,
            cashflow_source);
    const int64_t target = std::min(amount, total_funds);
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (const auto &entry : valid) {
        const int32_t slot = entry.first;
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, entry.second, _saturation_count);
        const int64_t next = mul_div_sat(target, prefix, total_funds,
            _saturation_count);
        const int64_t share = std::min(
            std::max<int64_t>(0, next - distributed),
            std::max<int64_t>(0, _population.funds[slot]));
        distributed = saturating_add(distributed, share, _saturation_count);
        _population.funds[slot] -= share;
        _population.epoch_expense[slot] = saturating_add(
            _population.epoch_expense[slot], share, _saturation_count);
        trace_record_cashflow(_trade_orders.sources[order_index],
            _population.handle_for_slot(slot), cashflow_source, 0, share);
    }
    if (distributed > 0 && cashflow_source == CASHFLOW_EXPORT_TAX) {
        _merchant_trade_sale_cash = saturating_sub(
            _merchant_trade_sale_cash, distributed, _saturation_count);
        const int32_t cell = _trade_orders.sources[order_index];
        if (cell >= 0 && cell < static_cast<int32_t>(
                _merchant_trade_sale_by_cell.size())) {
            _merchant_trade_sale_by_cell[cell] = saturating_sub(
                _merchant_trade_sale_by_cell[cell], distributed,
                _saturation_count);
        }
    }
    return distributed;
}

void NativeEconomyRuntime::rebuild_trade_arrival_buckets() {
    _trade_orders.arrival_bucket_days.clear();
    _trade_orders.arrival_bucket_offsets.assign(1, 0);
    _trade_orders.arrival_bucket_orders.clear();
    std::vector<int32_t> order_indices(static_cast<size_t>(_trade_orders.size()));
    std::iota(order_indices.begin(), order_indices.end(), 0);
    std::stable_sort(order_indices.begin(), order_indices.end(), [&](int32_t a, int32_t b) {
        if (_trade_orders.arrival_days[a] != _trade_orders.arrival_days[b])
            return _trade_orders.arrival_days[a] < _trade_orders.arrival_days[b];
        return _trade_orders.ids[a] < _trade_orders.ids[b];
    });
    int64_t current_day = std::numeric_limits<int64_t>::min();
    for (const int32_t order : order_indices) {
        const int64_t day = _trade_orders.arrival_days[order];
        if (_trade_orders.arrival_bucket_days.empty() || day != current_day) {
            if (!_trade_orders.arrival_bucket_days.empty())
                _trade_orders.arrival_bucket_offsets.push_back(
                    static_cast<int32_t>(_trade_orders.arrival_bucket_orders.size()));
            _trade_orders.arrival_bucket_days.push_back(day);
            current_day = day;
        }
        _trade_orders.arrival_bucket_orders.push_back(order);
    }
    if (!_trade_orders.arrival_bucket_days.empty())
        _trade_orders.arrival_bucket_offsets.push_back(
            static_cast<int32_t>(_trade_orders.arrival_bucket_orders.size()));
    _trade_orders.arrival_buckets_dirty = false;
}

void NativeEconomyRuntime::compact_trade_orders(const std::vector<uint8_t> &remove) {
    if (remove.size() != _trade_orders.ids.size()) return;
    TradeOrderStore next;
    next.clear();
    next.next_id = _trade_orders.next_id;
    for (int32_t i = 0; i < _trade_orders.size(); ++i) {
        if (remove[i] != 0) continue;
        next.ids.push_back(_trade_orders.ids[i]);
        next.sources.push_back(_trade_orders.sources[i]);
        next.destinations.push_back(_trade_orders.destinations[i]);
        next.countries.push_back(_trade_orders.countries[i]);
        next.source_country_handles.push_back(
            _trade_orders.source_country_handles[i]);
        next.destination_country_handles.push_back(
            _trade_orders.destination_country_handles[i]);
        next.source_country_slots.push_back(
            _trade_orders.source_country_slots[i]);
        next.destination_country_slots.push_back(
            _trade_orders.destination_country_slots[i]);
        next.departure_days.push_back(_trade_orders.departure_days[i]);
        next.arrival_days.push_back(_trade_orders.arrival_days[i]);
        next.cash_escrow.push_back(_trade_orders.cash_escrow[i]);
        next.capacity_work.push_back(_trade_orders.capacity_work[i]);
        next.states.push_back(_trade_orders.states[i]);
        next.cargo_delivered.push_back(_trade_orders.cargo_delivered[i]);
        for (int32_t line = _trade_orders.line_offsets[i];
             line < _trade_orders.line_offsets[i + 1]; ++line) {
            next.line_goods.push_back(_trade_orders.line_goods[line]);
            next.line_quantities.push_back(_trade_orders.line_quantities[line]);
            next.line_unit_prices.push_back(_trade_orders.line_unit_prices[line]);
            next.line_destination_prices.push_back(
                _trade_orders.line_destination_prices[line]);
            next.line_base_values.push_back(
                _trade_orders.line_base_values[line]);
            next.line_retail_values.push_back(
                _trade_orders.line_retail_values[line]);
            next.line_import_transfers.push_back(
                _trade_orders.line_import_transfers[line]);
            next.line_export_transfers.push_back(
                _trade_orders.line_export_transfers[line]);
            next.line_flags.push_back(_trade_orders.line_flags[line]);
        }
        next.line_offsets.push_back(static_cast<int32_t>(next.line_goods.size()));
        for (int32_t seller = _trade_orders.seller_offsets[i];
             seller < _trade_orders.seller_offsets[i + 1]; ++seller) {
            next.seller_handles.push_back(_trade_orders.seller_handles[seller]);
            next.seller_weights.push_back(_trade_orders.seller_weights[seller]);
        }
        next.seller_offsets.push_back(static_cast<int32_t>(next.seller_handles.size()));
    }
    _trade_orders = std::move(next);
    rebuild_trade_arrival_buckets();
}

bool NativeEconomyRuntime::settle_due_trade_orders(std::string &error) {
    const auto started = Clock::now();
    if (_trade_orders.ids.empty()) {
        _trade_settle_ms += elapsed_ms(started);
        return true;
    }
    if (_trade_orders.arrival_buckets_dirty) rebuild_trade_arrival_buckets();
    std::vector<uint8_t> remove(static_cast<size_t>(_trade_orders.size()), 0);
    for (int32_t bucket = 0;
         bucket < static_cast<int32_t>(_trade_orders.arrival_bucket_days.size()) &&
         _trade_orders.arrival_bucket_days[bucket] <= _sample_day; ++bucket) {
      for (int32_t position = _trade_orders.arrival_bucket_offsets[bucket];
           position < _trade_orders.arrival_bucket_offsets[bucket + 1]; ++position) {
        const int32_t order = _trade_orders.arrival_bucket_orders[position];
        if (order < 0 || order >= _trade_orders.size()) {
            error = "trade_arrival_bucket_invalid";
            return false;
        }
        if (_trade_orders.cargo_delivered[order] == 0) {
            const int32_t destination = _trade_orders.destinations[order];
            if (destination < 0 || destination >= _market.market_count) {
                error = "trade_order_destination_invalid";
                return false;
            }
            int64_t delivered = 0;
            int32_t trade_event_flags = 0;
            std::vector<EventLeg> trade_legs;
            trade_legs.reserve(static_cast<size_t>(std::max(0,
                _trade_orders.line_offsets[order + 1] -
                _trade_orders.line_offsets[order])) * 5U);
            for (int32_t line = _trade_orders.line_offsets[order];
                 line < _trade_orders.line_offsets[order + 1]; ++line) {
                const int32_t good = _trade_orders.line_goods[line];
                const int64_t quantity = _trade_orders.line_quantities[line];
                if (good < 0 || good >= _market.good_count || quantity <= 0) {
                    error = "trade_order_line_invalid";
                    return false;
                }
                const int64_t index = _market.index(destination, good);
                audit_touch_market_lane(static_cast<size_t>(index));
                _market.stock[index] = saturating_add(
                    _market.stock[index], quantity, _saturation_count);
                delivered = saturating_add(delivered, quantity, _saturation_count);
                const int32_t flow = trade_flow_index(destination, good, true);
                if (flow >= 0) _trade_flows.period_import[flow] = saturating_add(
                    _trade_flows.period_import[flow], quantity, _saturation_count);
                CommittedGameplayFact fact;
                fact.kind = GAMEPLAY_FACT_TRADE_ARRIVED;
                fact.cell = destination;
                fact.entity_handle = static_cast<uint64_t>(
                    _trade_orders.ids[order]);
                fact.entity_id = static_cast<int32_t>(std::clamp<int64_t>(
                    _trade_orders.ids[order], 0,
                    std::numeric_limits<int32_t>::max()));
                fact.value = quantity;
                const int32_t source = _trade_orders.sources[order];
                const int32_t source_country =
                    _trade_orders.source_country_slots[order];
                const int32_t destination_country =
                    _trade_orders.destination_country_slots[order];
                fact.payload = {source, source_country,
                                destination_country, good};
                const uint8_t line_flags = line < static_cast<int32_t>(
                        _trade_orders.line_flags.size())
                    ? _trade_orders.line_flags[line] : 0;
                fact.flags = line_flags;
                _staging_gameplay_facts.push_back(fact);
                int32_t contact_rule = -1;
                const std::string &good_id = _good_ids[static_cast<size_t>(good)];
                if (good_id == "corn_grain") contact_rule = 0;
                else if (good_id == "wheat_grain") contact_rule = 1;
                else if (good_id == "rice_grain") contact_rule = 2;
                else if (good_id == "potatoes") contact_rule = 3;
                else if (good_id == "seed_cotton" || good_id == "cotton_fiber")
                    contact_rule = 4;
                else if (good_id == "bast_fiber" || good_id == "flax_fiber")
                    contact_rule = 5;
                else if (good_id == "spices") contact_rule = 6;
                else if (good_id == "latex") contact_rule = 7;
                else if (good_id == "tin_ore" || good_id == "tin") contact_rule = 8;
                else if (good_id == "oceanic_vessels") contact_rule = 9;
                if (contact_rule >= 0 && source_country >= 0 &&
                    destination_country >= 0 && source_country != destination_country &&
                    destination_country < static_cast<int32_t>(_epoch_country_handles.size())) {
                    const uint64_t destination_handle = _epoch_country_handles[
                        static_cast<size_t>(destination_country)];
                    if (destination_handle != 0) {
                        CommittedGameplayFact contact;
                        contact.kind = GAMEPLAY_FACT_TECHNOLOGY_CONTACT;
                        contact.cell = destination;
                        contact.entity_handle = destination_handle;
                        contact.entity_id = destination_country;
                        contact.value = 1;
                        contact.payload = {contact_rule, source_country,
                                           destination_country, good};
                        _staging_gameplay_facts.push_back(contact);
                    }
                }
                trade_event_flags |= static_cast<int32_t>(line_flags) << 8;
                const int64_t order_id = _trade_orders.ids[order];
                trade_legs.push_back({FIELD_TRADE_QUANTITY,
                    SUBJECT_TRADE_ORDER, order_id, good, 0, quantity});
                trade_legs.push_back({FIELD_TRADE_BASE_VALUE,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    _trade_orders.line_base_values[line]});
                trade_legs.push_back({FIELD_TRADE_RETAIL_VALUE,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    _trade_orders.line_retail_values[line]});
                trade_legs.push_back({FIELD_TRADE_IMPORT_TRANSFER,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    _trade_orders.line_import_transfers[line]});
                trade_legs.push_back({FIELD_TRADE_EXPORT_TRANSFER,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    _trade_orders.line_export_transfers[line]});
            }
            _trade_orders.cargo_delivered[order] = 1;
            const int32_t source_cell = _trade_orders.sources[order];
            if (source_cell != destination) {
                auto increment_trade_fact = [&](int32_t cell) {
                    if (cell < 0 || cell >= static_cast<int32_t>(
                            _cell_trade_gen.size()))
                        return;
                    if (_cell_trade_gen[static_cast<size_t>(cell)] !=
                        std::numeric_limits<uint32_t>::max())
                        ++_cell_trade_gen[static_cast<size_t>(cell)];
                };
                increment_trade_fact(source_cell);
                increment_trade_fact(destination);
            }
            _trade_settlement_lag_days = std::max<int64_t>(_trade_settlement_lag_days,
                _sample_day - _trade_orders.arrival_days[order]);
            const bool trace_trade_detail = trace_detail_for_cell(destination) ||
                trace_detail_for_cell(_trade_orders.sources[order]);
            trace_append(EVENT_TRADE_ARRIVED, static_cast<int32_t>(Stage::TRADE_SETTLE),
                destination, SUBJECT_TRADE_ORDER, _trade_orders.ids[order],
                _trade_orders.sources[order], destination, delivered,
                _trade_orders.cash_escrow[order], _trade_orders.departure_days[order],
                _trade_orders.arrival_days[order],
                trace_trade_detail ? &trade_legs : nullptr,
                trade_event_flags);
            ++_trade_orders_arrived;
        }
        const int64_t escrow = _trade_orders.cash_escrow[order];
        int64_t base_receipt = 0;
        int64_t export_tax = 0;
        int64_t export_subsidy = 0;
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line) {
            base_receipt = saturating_add(base_receipt,
                std::max<int64_t>(0, _trade_orders.line_base_values[line]),
                _saturation_count);
            const int64_t transfer = _trade_orders.line_export_transfers[line];
            if (transfer > 0)
                export_tax = saturating_add(export_tax, transfer,
                    _saturation_count);
            else if (transfer < 0)
                export_subsidy = saturating_add(export_subsidy, -transfer,
                    _saturation_count);
        }
        int64_t credited = 0;
        if (base_receipt > 0)
            credited = saturating_add(credited,
                credit_trade_sellers(order, base_receipt), _saturation_count);
        if (export_tax > 0)
            credited = saturating_sub(credited,
                debit_trade_sellers(order, export_tax, CASHFLOW_EXPORT_TAX),
                _saturation_count);
        if (export_subsidy > 0)
            credited = saturating_add(credited,
                credit_trade_sellers(order, export_subsidy,
                    CASHFLOW_EXPORT_SUBSIDY), _saturation_count);
        if (credited == escrow) {
            _trade_orders.cash_escrow[order] = 0;
            remove[order] = 1;
        } else {
            _trade_orders.states[order] = TradeOrderStore::WAITING_RECEIVER;
            ++_trade_unclaimed_orders;
        }
      }
    }
    if (std::any_of(remove.begin(), remove.end(), [](uint8_t value) { return value != 0; }))
        compact_trade_orders(remove);
    _trade_settle_ms += elapsed_ms(started);
    return true;
}

bool NativeEconomyRuntime::dispatch_trade_candidates(std::string &error) {
    const auto started = Clock::now();
    // A full global route scan may span hundreds of fixed five-day cycles on
    // a populated map. Publish the deterministic chunk accumulated since the
    // prior settlement instead of withholding every profitable route until
    // the final source is visited. Dispatch revalidates price, stock, cash,
    // capacity and topology below, so partial publication remains conservative
    // while the stable route cursor provides eventual fairness.
    bool candidates_changed = false;
    if (_trade_plan.ready_candidates.empty() &&
        !_trade_plan.working_candidates.empty()) {
        _trade_plan.ready_candidates.swap(_trade_plan.working_candidates);
        candidates_changed = true;
    }
    if (!_trade_plan.deferred_subsidy_candidates.empty()) {
        const size_t available = static_cast<size_t>(std::max(0,
            _trade_max_candidates - static_cast<int32_t>(
                _trade_plan.ready_candidates.size())));
        const size_t append_count = std::min(
            available, _trade_plan.deferred_subsidy_candidates.size());
        _trade_plan.ready_candidates.insert(
            _trade_plan.ready_candidates.end(),
            _trade_plan.deferred_subsidy_candidates.begin(),
            _trade_plan.deferred_subsidy_candidates.begin() + append_count);
        _trade_plan.deferred_subsidy_candidates.clear();
        candidates_changed = candidates_changed || append_count > 0;
    }
    if (candidates_changed) {
        std::stable_sort(_trade_plan.ready_candidates.begin(),
            _trade_plan.ready_candidates.end(), [&](const TradeCandidate &a,
                                                     const TradeCandidate &b) {
                const int32_t a_deadline = std::max(
                    0, _trade_response_days - a.signal_age_days);
                const int32_t b_deadline = std::max(
                    0, _trade_response_days - b.signal_age_days);
                if (a_deadline != b_deadline) return a_deadline < b_deadline;
                if (a.response_priority != b.response_priority)
                    return a.response_priority < b.response_priority;
                if (a.signal_age_days != b.signal_age_days)
                    return a.signal_age_days > b.signal_age_days;
                if (a.density_q16 != b.density_q16)
                    return a.density_q16 > b.density_q16;
                if (a.expected_profit != b.expected_profit)
                    return a.expected_profit > b.expected_profit;
                if (a.route_cost != b.route_cost) return a.route_cost < b.route_cost;
                if (a.source != b.source) return a.source < b.source;
                if (a.destination != b.destination)
                    return a.destination < b.destination;
                return a.good < b.good;
            });
    }
    std::vector<int64_t> country_capacity(static_cast<size_t>(
        std::max(0, _epoch_country_count)), 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        const int64_t merchant_population = country < static_cast<int32_t>(
                _epoch_country_merchant_population.size())
            ? _epoch_country_merchant_population[static_cast<size_t>(country)] : 0;
        const int64_t base_capacity = saturating_mul(
            merchant_population, _trade_capacity_per_merchant_q16,
            _saturation_count);
        const int32_t capacity_factor = country <
                static_cast<int32_t>(_epoch_country_trade_capacity_factor_q16.size())
            ? _epoch_country_trade_capacity_factor_q16[country] : Q16_ONE;
        country_capacity[static_cast<size_t>(country)] = saturating_add(
            country_capacity[static_cast<size_t>(country)],
            mul_div_sat(base_capacity, capacity_factor, Q16_ONE,
                        _saturation_count),
            _saturation_count);
    }
    _trade_capacity_available = std::accumulate(
        country_capacity.begin(), country_capacity.end(), int64_t{0});
    std::vector<int64_t> intent_country_capacity = country_capacity;
    std::vector<TradeCandidate> accepted;
    std::vector<int32_t> merchant_funds_touched;
    std::unordered_map<uint64_t, int64_t> source_remaining;
    std::unordered_map<uint64_t, int64_t> destination_remaining;
    std::unordered_map<int32_t, int64_t> destination_trade_cash_remaining;
    // Subsidy intents use a private shadow of the same bounded resources. They
    // never move authoritative stock/cash/capacity, but multiple intents in one
    // batch still arbitrate deterministically against one another.
    std::unordered_map<uint64_t, int64_t> intent_source_remaining;
    std::unordered_map<uint64_t, int64_t> intent_destination_remaining;
    std::unordered_map<int32_t, int64_t> intent_destination_cash_remaining;
    if (_country_good_trade_index.size() !=
            _country_good_trade.countries.size() ||
        _country_partner_trade_index.size() !=
            _country_partner_trade.countries.size() ||
        _tariff_history_index.size() != _tariff_history.countries.size() ||
        _country_good_display_rows.size() !=
            static_cast<size_t>(std::max(0, _epoch_country_count)) ||
        _country_partner_display_rows.size() !=
            static_cast<size_t>(std::max(0, _epoch_country_count))) {
        rebuild_country_trade_indices();
    }
    const auto ensure_country_good = [&](int32_t country, int32_t good) {
        const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 32) |
            static_cast<uint32_t>(good);
        const auto found = _country_good_trade_index.find(key);
        if (found != _country_good_trade_index.end()) return found->second;
        const int32_t index = static_cast<int32_t>(_country_good_trade.countries.size());
        _country_good_trade_index.emplace(key, index);
        _country_good_trade.countries.push_back(country);
        _country_good_trade.goods.push_back(good);
        _country_good_trade.import_quantity.push_back(0);
        _country_good_trade.export_quantity.push_back(0);
        _country_good_trade.import_base.push_back(0);
        _country_good_trade.export_base.push_back(0);
        _country_good_trade.import_tariff.push_back(0);
        _country_good_trade.export_tariff.push_back(0);
        _country_good_trade.batch_epoch.push_back(-1);
        _country_good_trade.batch_import_quantity.push_back(0);
        _country_good_trade.batch_export_quantity.push_back(0);
        _country_good_trade.batch_import_base.push_back(0);
        _country_good_trade.batch_export_base.push_back(0);
        _country_good_trade.batch_import_tariff.push_back(0);
        _country_good_trade.batch_export_tariff.push_back(0);
        if (country >= 0 && country < static_cast<int32_t>(
                _country_good_display_rows.size())) {
            _country_good_display_rows[static_cast<size_t>(country)].push_back(index);
            _country_good_display_dirty[static_cast<size_t>(country)] = 1;
        }
        return index;
    };
    const auto ensure_country_partner = [&](int32_t country, int32_t partner) {
        const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 32) |
            static_cast<uint32_t>(partner);
        const auto found = _country_partner_trade_index.find(key);
        if (found != _country_partner_trade_index.end()) return found->second;
        const int32_t index = static_cast<int32_t>(
            _country_partner_trade.countries.size());
        _country_partner_trade_index.emplace(key, index);
        _country_partner_trade.countries.push_back(country);
        _country_partner_trade.partners.push_back(partner);
        _country_partner_trade.import_quantity.push_back(0);
        _country_partner_trade.export_quantity.push_back(0);
        _country_partner_trade.import_base.push_back(0);
        _country_partner_trade.export_base.push_back(0);
        _country_partner_trade.order_count.push_back(0);
        _country_partner_trade.batch_epoch.push_back(-1);
        _country_partner_trade.batch_import_quantity.push_back(0);
        _country_partner_trade.batch_export_quantity.push_back(0);
        _country_partner_trade.batch_import_base.push_back(0);
        _country_partner_trade.batch_export_base.push_back(0);
        _country_partner_trade.batch_order_count.push_back(0);
        if (country >= 0 && country < static_cast<int32_t>(
                _country_partner_display_rows.size())) {
            _country_partner_display_rows[static_cast<size_t>(country)].push_back(index);
            _country_partner_display_dirty[static_cast<size_t>(country)] = 1;
        }
        return index;
    };
    const auto begin_country_good_batch = [&](int32_t index) {
        if (index < 0 || index >= static_cast<int32_t>(
                _country_good_trade.batch_epoch.size()) ||
            _country_good_trade.batch_epoch[index] == _epoch_id) return;
        _country_good_trade.batch_epoch[index] = _epoch_id;
        _country_good_trade.batch_import_quantity[index] = 0;
        _country_good_trade.batch_export_quantity[index] = 0;
        _country_good_trade.batch_import_base[index] = 0;
        _country_good_trade.batch_export_base[index] = 0;
        _country_good_trade.batch_import_tariff[index] = 0;
        _country_good_trade.batch_export_tariff[index] = 0;
    };
    const auto begin_country_partner_batch = [&](int32_t index) {
        if (index < 0 || index >= static_cast<int32_t>(
                _country_partner_trade.batch_epoch.size()) ||
            _country_partner_trade.batch_epoch[index] == _epoch_id) return;
        _country_partner_trade.batch_epoch[index] = _epoch_id;
        _country_partner_trade.batch_import_quantity[index] = 0;
        _country_partner_trade.batch_export_quantity[index] = 0;
        _country_partner_trade.batch_import_base[index] = 0;
        _country_partner_trade.batch_export_base[index] = 0;
        _country_partner_trade.batch_order_count[index] = 0;
    };
    const auto ensure_tariff_history = [&](int32_t country, int32_t kind) {
        const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 32) |
            static_cast<uint32_t>(kind);
        const auto found = _tariff_history_index.find(key);
        if (found != _tariff_history_index.end()) return found->second;
        const int32_t index = static_cast<int32_t>(_tariff_history.countries.size());
        _tariff_history_index.emplace(key, index);
        _tariff_history.countries.push_back(country);
        _tariff_history.kinds.push_back(kind);
        _tariff_history.bases.push_back(0);
        _tariff_history.assessed.push_back(0);
        _tariff_history.collected.push_back(0);
        _tariff_history.requests.push_back(0);
        _tariff_history.reserved.push_back(0);
        _tariff_history.paid.push_back(0);
        _tariff_history.cumulative_bases.push_back(0);
        _tariff_history.cumulative_collected.push_back(0);
        _tariff_history.cumulative_requests.push_back(0);
        _tariff_history.cumulative_paid.push_back(0);
        return index;
    };
    const auto tariff_remaining = [&](int32_t country, int32_t tariff_kind) {
        if (country < 0 || country >= _epoch_country_count ||
            tariff_kind < 0 || tariff_kind >= 2) return int64_t{0};
        const size_t index = static_cast<size_t>(country) * 2U +
            static_cast<size_t>(tariff_kind);
        return index < _tariff_country_remaining.size()
            ? std::max<int64_t>(0, _tariff_country_remaining[index])
            : int64_t{0};
    };
    accepted.reserve(std::min<int32_t>(static_cast<int32_t>(
        _trade_plan.ready_candidates.size()),
        std::max(0, _trade_max_orders - _trade_orders.size())));
    merchant_funds_touched.reserve(accepted.capacity());
    for (const TradeCandidate &candidate : _trade_plan.ready_candidates) {
        const int32_t source_country = candidate.source_country >= 0
            ? candidate.source_country : candidate.country;
        const int32_t destination_country = candidate.destination_country >= 0
            ? candidate.destination_country : candidate.country;
        if (candidate.source < 0 || candidate.destination < 0 ||
            candidate.good < 0 || candidate.good >= _market.good_count ||
            source_country < 0 || source_country >= _epoch_country_count ||
            destination_country < 0 || destination_country >= _epoch_country_count ||
            candidate.topology_generation != _trade_topology.topology_generation ||
            candidate.source >= static_cast<int32_t>(_epoch_cell_country.size()) ||
            candidate.destination >= static_cast<int32_t>(_epoch_cell_country.size()) ||
            _epoch_cell_country[candidate.source] != source_country ||
            _epoch_cell_country[candidate.destination] != destination_country ||
            (candidate.source_country_handle != 0 &&
             _epoch_country_handles[static_cast<size_t>(source_country)] !=
                candidate.source_country_handle) ||
            (candidate.destination_country_handle != 0 &&
             _epoch_country_handles[static_cast<size_t>(destination_country)] !=
                candidate.destination_country_handle)) {
            ++_trade_rejected_route;
            if (candidate.destination >= 0 && candidate.good >= 0)
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_ROUTE);
            continue;
        }
        if (!trade_vision_allows_pair(candidate.source, candidate.destination)) {
            ++_trade_rejected_vision;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_ROUTE);
            continue;
        }
        if (candidate.source_price_stock_generation !=
                _cell_price_stock_gen[candidate.source] ||
            candidate.destination_price_stock_generation !=
                _cell_price_stock_gen[candidate.destination]) {
            ++_trade_candidates_stale_generation;
        }
        if ((candidate.expected_profit <= 0 &&
             (candidate.flags & TRADE_LINE_RELIEF) == 0) ||
            candidate.quantity <= 0) {
            ++_trade_rejected_profit;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_MARGIN);
            continue;
        }
        TradeCandidate clipped = candidate;
        const int64_t market_index = _market.index(candidate.source, candidate.good);
        int64_t target_sat = 0;
        const int64_t local_stock_target = trade_export_floor(
            candidate.source, candidate.good, target_sat);
        _saturation_count = saturating_add(
            _saturation_count, target_sat, _saturation_count);
        const uint64_t source_key = (static_cast<uint64_t>(
            static_cast<uint32_t>(candidate.source)) << 32) |
            static_cast<uint32_t>(candidate.good);
        auto source_it = source_remaining.find(source_key);
        if (source_it == source_remaining.end()) {
            source_it = source_remaining.emplace(source_key, std::max<int64_t>(
                0, _market.stock[market_index] - local_stock_target)).first;
        }
        int64_t reserved_stock = 0;
        clipped.quantity = std::min(clipped.quantity,
            std::max<int64_t>(0, source_it->second));
        const uint64_t destination_key = (static_cast<uint64_t>(
            static_cast<uint32_t>(candidate.destination)) << 32) |
            static_cast<uint32_t>(candidate.good);
        auto destination_it = destination_remaining.find(destination_key);
        if (destination_it == destination_remaining.end()) {
            int64_t destination_sat = 0;
            const int64_t target = trade_local_stock_target(
                candidate.destination, candidate.good, destination_sat);
            int64_t inbound = 0;
            for (int32_t order = 0; order < _trade_orders.size(); ++order) {
                if (_trade_orders.destinations[order] != candidate.destination) continue;
                for (int32_t line = _trade_orders.line_offsets[order];
                     line < _trade_orders.line_offsets[order + 1]; ++line) {
                    if (_trade_orders.line_goods[line] == candidate.good)
                        inbound = saturating_add(inbound,
                            _trade_orders.line_quantities[line], destination_sat);
                }
            }
            const int64_t destination_stock = _market.stock[_market.index(
                candidate.destination, candidate.good)];
            destination_it = destination_remaining.emplace(destination_key,
                std::max<int64_t>(0, target - destination_stock - inbound)).first;
            _saturation_count = saturating_add(
                _saturation_count, destination_sat, _saturation_count);
        }
        clipped.quantity = std::min(clipped.quantity,
                                    std::max<int64_t>(0, destination_it->second));
        int64_t sat = 0;
        const int64_t unit_work = saturating_mul(
            _good_transport_load_per_unit_q16[candidate.good],
            candidate.route_cost, sat);
        if (clipped.quantity <= 0) {
            if (source_it->second <= 0 || destination_it->second <= 0) {
                ++_trade_candidates_arbitrated_out;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_ARBITRATED_OUT);
            } else {
                ++_trade_rejected_capacity;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_CAPACITY);
            }
            continue;
        }
        const int64_t destination_index = _market.index(
            candidate.destination, candidate.good);
        clipped.source_price = estimate_trade_price(candidate.source, candidate.good,
            _market.stock[market_index] - clipped.quantity, sat);
        clipped.destination_price = estimate_trade_price(
            candidate.destination, candidate.good,
            _market.stock[destination_index] + clipped.quantity, sat);
        auto destination_cash_it = destination_trade_cash_remaining.find(
            candidate.destination);
        if (destination_cash_it == destination_trade_cash_remaining.end()) {
            int64_t merchant_cash = 0;
            for (int32_t k = _merchant_offsets[candidate.destination];
                 k < _merchant_offsets[candidate.destination + 1]; ++k) {
                merchant_cash = saturating_add(merchant_cash,
                    std::max<int64_t>(0,
                        _population.funds[_merchant_slots[k]]), sat);
            }
            int64_t existing_order_reserved_cash = 0;
            for (int32_t order = 0; order < _trade_orders.size(); ++order) {
                if (_trade_orders.destinations[order] ==
                        candidate.destination) {
                    existing_order_reserved_cash = saturating_add(
                        existing_order_reserved_cash,
                        std::max<int64_t>(0,
                            _trade_orders.cash_escrow[order]), sat);
                }
            }
            const int64_t operating_floor = mul_div_sat(
                merchant_cash, _merchant_procurement_cash_reserve_q16,
                Q16_ONE, sat);
            destination_cash_it = destination_trade_cash_remaining.emplace(
                candidate.destination, std::max<int64_t>(0,
                    merchant_cash -
                    std::min(merchant_cash, existing_order_reserved_cash) -
                    std::min(merchant_cash, operating_floor))).first;
        }
        const int64_t available_cash = std::max<int64_t>(
            0, destination_cash_it->second);
        const int64_t relief_q16 = trade_relief_pressure_q16(
            candidate.destination, candidate.good, sat);
        const bool relief_route = relief_q16 >= Q16_ONE / 8;
        const auto quote_is_viable = [&](const TradeQuote &quote) {
            const bool merchant_cash_safe = quote.importer_outlay >= 0 &&
                quote.importer_profit >= 0 && quote.exporter_receipt > 0;
            const bool route_profit_safe = relief_route
                ? quote.combined_profit >= 0
                : quote.combined_profit > 0 &&
                    quote.margin_q16 >= _trade_min_margin_q16;
            return merchant_cash_safe && route_profit_safe;
        };
        const int64_t before_profit_clip = clipped.quantity;
        int64_t margin_q16 = 0;
        clipped.quantity = profitable_trade_quantity(
            candidate.source, candidate.destination, candidate.good,
            clipped.quantity, relief_route, clipped.source_price,
            clipped.destination_price, clipped.expected_profit,
            margin_q16, sat);
        if (clipped.quantity <= 0) {
            ++_trade_rejected_profit;
            ++_trade_rejected_margin;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_MARGIN);
            continue;
        }
        if (clipped.quantity < before_profit_clip) ++_trade_quantity_profit_clips;
        auto quote_for_quantity = [&](int64_t quantity, TradeQuote &quote,
                                      int64_t &total_work,
                                      int64_t &source_work,
                                      int64_t &destination_work) {
            const int32_t quoted_source = estimate_trade_price(
                candidate.source, candidate.good,
                _market.stock[market_index] - quantity, sat);
            const int32_t quoted_destination = estimate_trade_price(
                candidate.destination, candidate.good,
                _market.stock[destination_index] + quantity, sat);
            quote = make_trade_quote(candidate.source, candidate.destination,
                candidate.good, quantity, quoted_source, quoted_destination,
                relief_route, sat);
            total_work = mul_div_sat(quantity, unit_work, GOODS_SCALE, sat);
            if (quote.foreign) {
                source_work = total_work / 2;
                destination_work = total_work - source_work;
            } else {
                source_work = total_work;
                destination_work = 0;
            }
        };
        int64_t low = 1;
        int64_t high = clipped.quantity;
        int64_t best_quantity = 0;
        TradeQuote best_quote;
        int64_t best_total_work = 0;
        int64_t best_source_work = 0;
        int64_t best_destination_work = 0;
        while (low <= high) {
            const int64_t mid = low + (high - low) / 2;
            TradeQuote quote;
            int64_t total_work = 0;
            int64_t source_work = 0;
            int64_t destination_work = 0;
            quote_for_quantity(mid, quote, total_work, source_work,
                               destination_work);
            const bool capacity_ok = total_work > 0 &&
                source_work <= country_capacity[static_cast<size_t>(source_country)] &&
                destination_work <= country_capacity[
                    static_cast<size_t>(destination_country)];
            const bool cash_ok = quote.importer_outlay >= 0 &&
                quote.importer_outlay <= available_cash;
            const bool subsidy_ok =
                -std::min<int64_t>(0, quote.export_transfer) <=
                    tariff_remaining(source_country, 1) &&
                -std::min<int64_t>(0, quote.import_transfer) <=
                    tariff_remaining(destination_country, 0);
            if (capacity_ok && cash_ok && subsidy_ok) {
                best_quantity = mid;
                best_quote = quote;
                best_total_work = total_work;
                best_source_work = source_work;
                best_destination_work = destination_work;
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }
        if (best_quantity > 0 && !quote_is_viable(best_quote)) {
            best_quantity = 0;
            best_total_work = 0;
            best_source_work = 0;
            best_destination_work = 0;
        }
        if (best_quantity <= 0) {
            TradeQuote unit_quote;
            int64_t unit_total_work = 0;
            int64_t unit_source_work = 0;
            int64_t unit_destination_work = 0;
            quote_for_quantity(1, unit_quote, unit_total_work,
                               unit_source_work, unit_destination_work);
            TradeQuote nominal_quote;
            int64_t nominal_total_work = 0;
            int64_t nominal_source_work = 0;
            int64_t nominal_destination_work = 0;
            quote_for_quantity(clipped.quantity, nominal_quote,
                               nominal_total_work, nominal_source_work,
                               nominal_destination_work);
            const bool subsidy_blocked =
                -std::min<int64_t>(0, nominal_quote.export_transfer) >
                    tariff_remaining(source_country, 1) ||
                -std::min<int64_t>(0, nominal_quote.import_transfer) >
                    tariff_remaining(destination_country, 0);
            if (subsidy_blocked && _trade_runtime_mode == 2) {
                // An intent is a bounded next-batch request only. It must not
                // change stock, merchant cash, actual tariff events, or the
                // current fiscal base. Its resource arbitration is shadow-only
                // and follows the same stable candidate order as real dispatch.
                const uint64_t source_key = (static_cast<uint64_t>(
                    static_cast<uint32_t>(candidate.source)) << 32) |
                    static_cast<uint32_t>(candidate.good);
                const uint64_t destination_key = (static_cast<uint64_t>(
                    static_cast<uint32_t>(candidate.destination)) << 32) |
                    static_cast<uint32_t>(candidate.good);
                auto intent_source_it = intent_source_remaining.find(source_key);
                if (intent_source_it == intent_source_remaining.end())
                    intent_source_it = intent_source_remaining.emplace(
                        source_key, source_it->second).first;
                auto intent_destination_it = intent_destination_remaining.find(
                    destination_key);
                if (intent_destination_it == intent_destination_remaining.end())
                    intent_destination_it = intent_destination_remaining.emplace(
                        destination_key, destination_it->second).first;
                auto intent_cash_it = intent_destination_cash_remaining.find(
                    candidate.destination);
                if (intent_cash_it == intent_destination_cash_remaining.end())
                    intent_cash_it = intent_destination_cash_remaining.emplace(
                        candidate.destination, available_cash).first;
                int64_t intent_quantity = 0;
                TradeQuote intent_quote;
                int64_t intent_source_work = 0;
                int64_t intent_destination_work = 0;
                int64_t intent_low = 1;
                int64_t intent_high = std::min(clipped.quantity,
                    std::min(intent_source_it->second,
                        intent_destination_it->second));
                while (intent_low <= intent_high) {
                    const int64_t mid = intent_low +
                        (intent_high - intent_low) / 2;
                    TradeQuote quote;
                    int64_t total_work = 0;
                    int64_t source_work = 0;
                    int64_t destination_work = 0;
                    quote_for_quantity(mid, quote, total_work, source_work,
                        destination_work);
                    const bool capacity_ok = total_work > 0 &&
                        source_work <= intent_country_capacity[
                            static_cast<size_t>(source_country)] &&
                        destination_work <= intent_country_capacity[
                            static_cast<size_t>(destination_country)];
                    const bool cash_ok = quote.importer_outlay >= 0 &&
                        quote.importer_outlay <= intent_cash_it->second;
                    if (capacity_ok && cash_ok) {
                        intent_quantity = mid;
                        intent_quote = quote;
                        intent_source_work = source_work;
                        intent_destination_work = destination_work;
                        intent_low = mid + 1;
                    } else {
                        intent_high = mid - 1;
                    }
                }
                if (intent_quantity > 0 && !quote_is_viable(intent_quote))
                    intent_quantity = 0;
                const int64_t import_request = intent_quantity > 0
                    ? -std::min<int64_t>(0, intent_quote.import_transfer) : 0;
                const int64_t export_request = intent_quantity > 0
                    ? -std::min<int64_t>(0, intent_quote.export_transfer) : 0;
                if (import_request > 0) {
                    const int32_t lane = tariff_epoch_lane_index(
                        candidate.destination, 0, true);
                    if (lane < 0) {
                        error = "tariff_intent_lane_allocate_failed";
                        return false;
                    }
                    _tariff_epoch_requests[lane] = saturating_add(
                        _tariff_epoch_requests[lane], import_request, sat);
                    const int32_t row = ensure_tariff_history(
                        destination_country, NativeCountryRuntime::TAX_IMPORT);
                    _tariff_history.requests[row] = saturating_add(
                        _tariff_history.requests[row], import_request, sat);
                }
                if (export_request > 0) {
                    const int32_t lane = tariff_epoch_lane_index(
                        candidate.source, 1, true);
                    if (lane < 0) {
                        error = "tariff_intent_lane_allocate_failed";
                        return false;
                    }
                    _tariff_epoch_requests[lane] = saturating_add(
                        _tariff_epoch_requests[lane], export_request, sat);
                    const int32_t row = ensure_tariff_history(
                        source_country, NativeCountryRuntime::TAX_EXPORT);
                    _tariff_history.requests[row] = saturating_add(
                        _tariff_history.requests[row], export_request, sat);
                }
                if (intent_quantity > 0 && (import_request > 0 || export_request > 0)) {
                    intent_source_it->second = std::max<int64_t>(0,
                        intent_source_it->second - intent_quantity);
                    intent_destination_it->second = std::max<int64_t>(0,
                        intent_destination_it->second - intent_quantity);
                    intent_country_capacity[static_cast<size_t>(source_country)] =
                        std::max<int64_t>(0,
                            intent_country_capacity[static_cast<size_t>(source_country)] -
                            intent_source_work);
                    intent_country_capacity[static_cast<size_t>(destination_country)] =
                        std::max<int64_t>(0,
                            intent_country_capacity[static_cast<size_t>(destination_country)] -
                            intent_destination_work);
                    intent_cash_it->second = std::max<int64_t>(0,
                        intent_cash_it->second - intent_quote.importer_outlay);
                    CommittedGameplayFact fact;
                    fact.kind = GAMEPLAY_FACT_TARIFF_SUBSIDY_INTENT;
                    fact.cell = candidate.destination;
                    fact.entity_id = -1;
                    fact.value = saturating_add(import_request, export_request, sat);
                    fact.payload = {candidate.source, source_country,
                                    destination_country, candidate.good};
                    fact.flags = TRADE_LINE_FOREIGN |
                        (intent_quote.import_transfer < 0
                            ? TRADE_LINE_IMPORT_SUBSIDY : 0) |
                        (intent_quote.export_transfer < 0
                            ? TRADE_LINE_EXPORT_SUBSIDY : 0);
                    _staging_gameplay_facts.push_back(fact);
                    if (static_cast<int32_t>(
                            _trade_plan.deferred_subsidy_candidates.size()) <
                            _trade_max_candidates) {
                        _trade_plan.deferred_subsidy_candidates.push_back(candidate);
                    }
                    std::vector<EventLeg> intent_legs;
                    if (trace_detail_for_cell(candidate.source) ||
                        trace_detail_for_cell(candidate.destination)) {
                        intent_legs.push_back({FIELD_TRADE_BASE_VALUE,
                            SUBJECT_MARKET, candidate.destination, candidate.good,
                            0, intent_quote.base});
                        intent_legs.push_back({FIELD_TRADE_IMPORT_TRANSFER,
                            SUBJECT_MARKET, candidate.destination, candidate.good,
                            0, intent_quote.import_transfer});
                        intent_legs.push_back({FIELD_TRADE_EXPORT_TRANSFER,
                            SUBJECT_MARKET, candidate.source, candidate.good,
                            0, intent_quote.export_transfer});
                    }
                    trace_append(EVENT_TARIFF_SUBSIDY_INTENT,
                        static_cast<int32_t>(Stage::TRADE_DISPATCH),
                        candidate.destination, SUBJECT_MARKET,
                        candidate.destination, candidate.source,
                        candidate.destination, intent_quantity, intent_quote.base,
                        fact.value, 0,
                        intent_legs.empty() ? nullptr : &intent_legs,
                        static_cast<int32_t>(fact.flags) << 8);
                }
            }
            if (available_cash < unit_quote.importer_outlay) {
                ++_trade_rejected_cash;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_CASH);
            } else {
                ++_trade_rejected_capacity;
                record_trade_signal_attempt(candidate.destination, candidate.good,
                    TRADE_SIGNAL_DIAG_CAPACITY);
            }
            continue;
        }
        clipped.quantity = best_quantity;
        clipped.source_price = best_quote.source_price;
        clipped.destination_price = best_quote.destination_price;
        clipped.expected_profit = best_quote.combined_profit;
        clipped.base_value = best_quote.base;
        clipped.retail_value = best_quote.retail;
        clipped.import_transfer = best_quote.import_transfer;
        clipped.export_transfer = best_quote.export_transfer;
        clipped.capacity_work = best_total_work;
        clipped.flags = best_quote.foreign ? TRADE_LINE_FOREIGN : 0;
        if (relief_route) clipped.flags |= TRADE_LINE_RELIEF;
        if (best_quote.import_transfer < 0)
            clipped.flags |= TRADE_LINE_IMPORT_SUBSIDY;
        else if (best_quote.import_transfer > 0)
            clipped.flags |= TRADE_LINE_IMPORT_TAX;
        if (best_quote.export_transfer < 0)
            clipped.flags |= TRADE_LINE_EXPORT_SUBSIDY;
        else if (best_quote.export_transfer > 0)
            clipped.flags |= TRADE_LINE_EXPORT_TAX;
        int64_t density_profit = best_quote.combined_profit;
        if (relief_route && density_profit <= 0) {
            density_profit = std::max<int64_t>(1, mul_div_sat(
                best_quote.base, std::max<int64_t>(1, relief_q16),
                Q16_ONE, sat));
        }
        clipped.density_q16 = mul_div_sat(
            density_profit, Q16_ONE, clipped.capacity_work, sat);
        const int64_t purchase_cash = best_quote.importer_outlay;
        if (_market.stock[market_index] - local_stock_target - reserved_stock <
                clipped.quantity) {
            ++_trade_rejected_stock;
            ++_trade_true_source_stock_failures;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_STOCK);
            continue;
        }
        if (_trade_runtime_mode == 2 &&
            _trade_orders.size() + static_cast<int32_t>(accepted.size()) >=
                _trade_max_orders) {
            ++_trade_rejected_order_cap;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_ORDER_CAP);
            break;
        }
        const int64_t import_subsidy = -std::min<int64_t>(
            0, clipped.import_transfer);
        const int64_t export_subsidy = -std::min<int64_t>(
            0, clipped.export_transfer);
        if (_trade_runtime_mode == 2 && (import_subsidy > 0 || export_subsidy > 0)) {
            // prepare_fiscal_budgets already reserved the combined country
            // escrow. Dispatch only consumes its frozen epoch remainder.
            const size_t import_budget = static_cast<size_t>(destination_country) * 2U;
            const size_t export_budget = static_cast<size_t>(source_country) * 2U + 1U;
            if (import_subsidy > 0 && import_budget < _tariff_country_remaining.size()) {
                _tariff_country_remaining[import_budget] = std::max<int64_t>(0,
                    _tariff_country_remaining[import_budget] - import_subsidy);
            }
            if (export_subsidy > 0 && export_budget < _tariff_country_remaining.size()) {
                _tariff_country_remaining[export_budget] = std::max<int64_t>(0,
                    _tariff_country_remaining[export_budget] - export_subsidy);
            }
        }
        country_capacity[static_cast<size_t>(source_country)] -=
            best_source_work;
        country_capacity[static_cast<size_t>(destination_country)] -=
            best_destination_work;
        intent_country_capacity[static_cast<size_t>(source_country)] =
            std::max<int64_t>(0,
                intent_country_capacity[static_cast<size_t>(source_country)] -
                best_source_work);
        intent_country_capacity[static_cast<size_t>(destination_country)] =
            std::max<int64_t>(0,
                intent_country_capacity[static_cast<size_t>(destination_country)] -
                best_destination_work);
        source_it->second = std::max<int64_t>(0,
            source_it->second - clipped.quantity);
        destination_it->second = std::max<int64_t>(0,
            destination_it->second - clipped.quantity);
        if (auto intent_it = intent_source_remaining.find(source_key);
            intent_it != intent_source_remaining.end()) {
            intent_it->second = std::max<int64_t>(0,
                intent_it->second - clipped.quantity);
        }
        if (auto intent_it = intent_destination_remaining.find(destination_key);
            intent_it != intent_destination_remaining.end()) {
            intent_it->second = std::max<int64_t>(0,
                intent_it->second - clipped.quantity);
        }
        _trade_capacity_used = saturating_add(_trade_capacity_used,
            clipped.capacity_work, _saturation_count);
        ++_trade_candidates_accepted;
        destination_cash_it->second = std::max<int64_t>(
            0, destination_cash_it->second - purchase_cash);
        if (auto intent_it = intent_destination_cash_remaining.find(
                candidate.destination);
            intent_it != intent_destination_cash_remaining.end()) {
            intent_it->second = std::max<int64_t>(0,
                intent_it->second - purchase_cash);
        }
        if (_trade_runtime_mode == 1) {
            accepted.push_back(clipped);
            continue;
        }
        const int64_t import_tax = std::max<int64_t>(
            0, clipped.import_transfer);
        // The merchant pays the base purchase. A positive import transfer is
        // an additional tax expense; a negative transfer is credited from the
        // escrow before the base debit so a subsidy can unlock a cash-poor
        // importer without creating money outside the country treasury.
        if (import_subsidy > 0) {
            credit_local_merchants(candidate.destination, import_subsidy,
                CASHFLOW_IMPORT_SUBSIDY);
        }
        const int64_t debited_base = debit_local_merchants(
            candidate.destination, clipped.base_value,
            CASHFLOW_MERCHANT_PROCUREMENT);
        const int64_t debited_tax = import_tax > 0
            ? debit_local_merchants(candidate.destination, import_tax,
                CASHFLOW_IMPORT_TAX) : 0;
        const int64_t debited = saturating_add(debited_base, debited_tax,
            _saturation_count);
        const int64_t expected_debit = saturating_add(
            clipped.base_value, import_tax, _saturation_count);
        if (debited != expected_debit) {
            if (import_subsidy > 0) {
                const size_t budget = static_cast<size_t>(destination_country) * 2U;
                if (budget < _tariff_country_remaining.size())
                    _tariff_country_remaining[budget] = saturating_add(
                        _tariff_country_remaining[budget], import_subsidy,
                        _saturation_count);
            }
            if (export_subsidy > 0) {
                const size_t budget = static_cast<size_t>(source_country) * 2U + 1U;
                if (budget < _tariff_country_remaining.size())
                    _tariff_country_remaining[budget] = saturating_add(
                        _tariff_country_remaining[budget], export_subsidy,
                        _saturation_count);
            }
            error = "trade_cash_reservation_failed";
            return false;
        }
        _merchant_trade_purchase_cash = saturating_add(
            _merchant_trade_purchase_cash, purchase_cash,
            _saturation_count);
        if (candidate.destination >= 0 &&
            candidate.destination < static_cast<int32_t>(
                _merchant_trade_purchase_by_cell.size())) {
            _merchant_trade_purchase_by_cell[candidate.destination] =
                saturating_add(
                    _merchant_trade_purchase_by_cell[candidate.destination],
                    purchase_cash, _saturation_count);
        }
        audit_touch_market_lane(static_cast<size_t>(market_index));
        _market.stock[market_index] -= clipped.quantity;
        // Household settlement already contributed its closing totals. Move the
        // dispatched value from those local totals into trade escrow/transit so
        // the later conservation audit counts it exactly once.
        _publish_accum.goods_stock = saturating_sub(
            _publish_accum.goods_stock, clipped.quantity, _saturation_count);
        _publish_accum.cohort_funds = saturating_sub(
            _publish_accum.cohort_funds, purchase_cash, _saturation_count);
        if ((clipped.flags & TRADE_LINE_FOREIGN) != 0) {
            const int32_t import_lane = tariff_epoch_lane_index(
                candidate.destination, 0, true);
            const int32_t export_lane = tariff_epoch_lane_index(
                candidate.source, 1, true);
            if (import_lane < 0 || export_lane < 0) {
                error = "tariff_epoch_lane_allocate_failed";
                return false;
            }
            for (const int32_t lane : {import_lane, export_lane}) {
                _tariff_epoch_bases[lane] = saturating_add(
                    _tariff_epoch_bases[lane], clipped.base_value,
                    _saturation_count);
                _tariff_epoch_events[lane] = saturating_add(
                    _tariff_epoch_events[lane], 1, _saturation_count);
            }
            const auto record_transfer = [&](int32_t lane, int64_t transfer) {
                if (transfer > 0) {
                    _tariff_epoch_assessed[lane] = saturating_add(
                        _tariff_epoch_assessed[lane], transfer,
                        _saturation_count);
                    _tariff_epoch_collected[lane] = saturating_add(
                        _tariff_epoch_collected[lane], transfer,
                        _saturation_count);
                } else if (transfer < 0) {
                    const int64_t subsidy = -transfer;
                    _tariff_epoch_requests[lane] = saturating_add(
                        _tariff_epoch_requests[lane], subsidy,
                        _saturation_count);
                    _tariff_epoch_reserved[lane] = saturating_add(
                        _tariff_epoch_reserved[lane], subsidy,
                        _saturation_count);
                    _tariff_epoch_paid[lane] = saturating_add(
                        _tariff_epoch_paid[lane], subsidy,
                        _saturation_count);
                }
            };
            record_transfer(import_lane, clipped.import_transfer);
            record_transfer(export_lane, clipped.export_transfer);
            const int32_t import_good = ensure_country_good(
                destination_country, candidate.good);
            const int32_t export_good = ensure_country_good(
                source_country, candidate.good);
            begin_country_good_batch(import_good);
            begin_country_good_batch(export_good);
            _country_good_trade.import_quantity[import_good] = saturating_add(
                _country_good_trade.import_quantity[import_good], clipped.quantity,
                _saturation_count);
            _country_good_trade.batch_import_quantity[import_good] = saturating_add(
                _country_good_trade.batch_import_quantity[import_good],
                clipped.quantity, _saturation_count);
            _country_good_trade.import_base[import_good] = saturating_add(
                _country_good_trade.import_base[import_good], clipped.base_value,
                _saturation_count);
            _country_good_trade.batch_import_base[import_good] = saturating_add(
                _country_good_trade.batch_import_base[import_good],
                clipped.base_value, _saturation_count);
            _country_good_trade.import_tariff[import_good] = saturating_add(
                _country_good_trade.import_tariff[import_good],
                clipped.import_transfer, _saturation_count);
            _country_good_trade.batch_import_tariff[import_good] = saturating_add(
                _country_good_trade.batch_import_tariff[import_good],
                clipped.import_transfer, _saturation_count);
            _country_good_trade.export_quantity[export_good] = saturating_add(
                _country_good_trade.export_quantity[export_good], clipped.quantity,
                _saturation_count);
            _country_good_trade.batch_export_quantity[export_good] = saturating_add(
                _country_good_trade.batch_export_quantity[export_good],
                clipped.quantity, _saturation_count);
            _country_good_trade.export_base[export_good] = saturating_add(
                _country_good_trade.export_base[export_good], clipped.base_value,
                _saturation_count);
            _country_good_trade.batch_export_base[export_good] = saturating_add(
                _country_good_trade.batch_export_base[export_good],
                clipped.base_value, _saturation_count);
            _country_good_trade.export_tariff[export_good] = saturating_add(
                _country_good_trade.export_tariff[export_good],
                clipped.export_transfer, _saturation_count);
            _country_good_trade.batch_export_tariff[export_good] = saturating_add(
                _country_good_trade.batch_export_tariff[export_good],
                clipped.export_transfer, _saturation_count);
            const int32_t importer_partner = ensure_country_partner(
                destination_country, source_country);
            const int32_t exporter_partner = ensure_country_partner(
                source_country, destination_country);
            begin_country_partner_batch(importer_partner);
            begin_country_partner_batch(exporter_partner);
            _country_partner_trade.import_quantity[importer_partner] = saturating_add(
                _country_partner_trade.import_quantity[importer_partner],
                clipped.quantity, _saturation_count);
            _country_partner_trade.batch_import_quantity[importer_partner] =
                saturating_add(_country_partner_trade.batch_import_quantity[
                    importer_partner], clipped.quantity, _saturation_count);
            _country_partner_trade.import_base[importer_partner] = saturating_add(
                _country_partner_trade.import_base[importer_partner],
                clipped.base_value, _saturation_count);
            _country_partner_trade.batch_import_base[importer_partner] =
                saturating_add(_country_partner_trade.batch_import_base[
                    importer_partner], clipped.base_value, _saturation_count);
            _country_partner_trade.order_count[importer_partner] = saturating_add(
                _country_partner_trade.order_count[importer_partner], 1,
                _saturation_count);
            _country_partner_trade.batch_order_count[importer_partner] =
                saturating_add(_country_partner_trade.batch_order_count[
                    importer_partner], 1, _saturation_count);
            _country_partner_trade.export_quantity[exporter_partner] = saturating_add(
                _country_partner_trade.export_quantity[exporter_partner],
                clipped.quantity, _saturation_count);
            _country_partner_trade.batch_export_quantity[exporter_partner] =
                saturating_add(_country_partner_trade.batch_export_quantity[
                    exporter_partner], clipped.quantity, _saturation_count);
            _country_partner_trade.export_base[exporter_partner] = saturating_add(
                _country_partner_trade.export_base[exporter_partner],
                clipped.base_value, _saturation_count);
            _country_partner_trade.batch_export_base[exporter_partner] =
                saturating_add(_country_partner_trade.batch_export_base[
                    exporter_partner], clipped.base_value, _saturation_count);
            _country_partner_trade.order_count[exporter_partner] = saturating_add(
                _country_partner_trade.order_count[exporter_partner], 1,
                _saturation_count);
            _country_partner_trade.batch_order_count[exporter_partner] =
                saturating_add(_country_partner_trade.batch_order_count[
                    exporter_partner], 1, _saturation_count);
            const auto update_tariff_history = [&](int32_t country, int32_t kind,
                                                    int64_t transfer) {
                const int32_t row = ensure_tariff_history(country, kind);
                _tariff_history.bases[row] = saturating_add(
                    _tariff_history.bases[row], clipped.base_value,
                    _saturation_count);
                if (transfer > 0) {
                    _tariff_history.assessed[row] = saturating_add(
                        _tariff_history.assessed[row], transfer, _saturation_count);
                    _tariff_history.collected[row] = saturating_add(
                        _tariff_history.collected[row], transfer, _saturation_count);
                } else if (transfer < 0) {
                    const int64_t subsidy = -transfer;
                    _tariff_history.requests[row] = saturating_add(
                        _tariff_history.requests[row], subsidy, _saturation_count);
                    _tariff_history.reserved[row] = saturating_add(
                        _tariff_history.reserved[row], subsidy, _saturation_count);
                    _tariff_history.paid[row] = saturating_add(
                        _tariff_history.paid[row], subsidy, _saturation_count);
                }
            };
            update_tariff_history(destination_country,
                NativeCountryRuntime::TAX_IMPORT, clipped.import_transfer);
            update_tariff_history(source_country,
                NativeCountryRuntime::TAX_EXPORT, clipped.export_transfer);
        }
        merchant_funds_touched.push_back(candidate.destination);
        accepted.push_back(clipped);
        record_trade_signal_attempt(candidate.destination, candidate.good,
            TRADE_SIGNAL_DIAG_DISPATCHED);
        const int32_t destination_signal = trade_signal_clock_index(
            candidate.destination, candidate.good);
        if (_trade_runtime_mode == 2 && destination_signal >= 0 &&
            destination_signal < static_cast<int32_t>(_trade_signal_first_seen_day.size()) &&
            destination_signal < static_cast<int32_t>(_trade_signal_first_dispatch_day.size()) &&
            _trade_signal_first_seen_day[destination_signal] >= 0 &&
            _trade_signal_first_dispatch_day[destination_signal] < 0) {
            _trade_signal_first_dispatch_day[destination_signal] = _sample_day;
            _trade_first_dispatch_delay_max_days = std::max<int64_t>(
                _trade_first_dispatch_delay_max_days,
                std::max<int64_t>(0, _sample_day -
                    _trade_signal_first_seen_day[destination_signal]));
            ++_trade_deficit_episodes_resolved;
            _trade_signal_first_seen_day[destination_signal] = -1;
            _trade_signal_first_dispatch_day[destination_signal] = -1;
            _trade_signal_deadline_reported[destination_signal] = 0;
        }
        const int32_t flow = trade_flow_index(candidate.source, candidate.good, true);
        if (flow >= 0) _trade_flows.period_export[flow] = saturating_add(
            _trade_flows.period_export[flow], clipped.quantity, _saturation_count);
    }
    sort_dirty_country_trade_display_indices();
    _trade_plan.ready_candidates.clear();
    std::sort(merchant_funds_touched.begin(), merchant_funds_touched.end());
    merchant_funds_touched.erase(std::unique(merchant_funds_touched.begin(),
        merchant_funds_touched.end()), merchant_funds_touched.end());
    for (const int32_t cell : merchant_funds_touched) {
        if (cell >= 0 && cell < _cell_count)
            stage_cell_summary(cell, build_cell_summary(cell));
    }
    if (_trade_runtime_mode != 2 || accepted.empty()) {
        _trade_dispatch_ms += elapsed_ms(started);
        return true;
    }
    auto arrival_for = [&](const TradeCandidate &candidate) {
        const int32_t source_country = candidate.source_country >= 0
            ? candidate.source_country : candidate.country;
        const int32_t destination_country = candidate.destination_country >= 0
            ? candidate.destination_country : candidate.country;
        int64_t speed_factor = Q16_ONE;
        if (source_country >= 0 && destination_country >= 0 &&
            source_country < static_cast<int32_t>(
                _epoch_country_trade_speed_factor_q16.size()) &&
            destination_country < static_cast<int32_t>(
                _epoch_country_trade_speed_factor_q16.size())) {
            speed_factor = (static_cast<int64_t>(
                _epoch_country_trade_speed_factor_q16[source_country]) +
                _epoch_country_trade_speed_factor_q16[destination_country]) / 2;
        }
        const int64_t effective_speed = std::max<int64_t>(
            1, mul_div_sat(_trade_speed_cost_per_day, speed_factor,
                           Q16_ONE, _saturation_count));
        const int64_t raw_days = std::max<int64_t>(1,
            (candidate.route_cost + effective_speed - 1) / effective_speed);
        // Transport is a daily authority transaction. Local markets consume
        // the delivered stock on their next rolling settlement, but cargo must
        // not wait for or align to that five-day cadence.
        return _sample_day + raw_days;
    };
    std::stable_sort(accepted.begin(), accepted.end(), [&](const TradeCandidate &a,
                                                           const TradeCandidate &b) {
        if (a.source != b.source) return a.source < b.source;
        if (a.destination != b.destination) return a.destination < b.destination;
        const int64_t arrival_a = arrival_for(a);
        const int64_t arrival_b = arrival_for(b);
        if (arrival_a != arrival_b) return arrival_a < arrival_b;
        return a.good < b.good;
    });
    size_t cursor = 0;
    while (cursor < accepted.size()) {
        const TradeCandidate &first = accepted[cursor];
        const int64_t arrival = arrival_for(first);
        const size_t begin = cursor;
        while (cursor < accepted.size() && cursor - begin < 16 &&
               accepted[cursor].source == first.source &&
               accepted[cursor].destination == first.destination &&
               arrival_for(accepted[cursor]) == arrival) ++cursor;
        _trade_orders.ids.push_back(_trade_orders.next_id++);
        _trade_orders.sources.push_back(first.source);
        _trade_orders.destinations.push_back(first.destination);
        _trade_orders.countries.push_back(first.country);
        _trade_orders.source_country_handles.push_back(
            first.source_country_handle);
        _trade_orders.destination_country_handles.push_back(
            first.destination_country_handle);
        _trade_orders.source_country_slots.push_back(first.source_country);
        _trade_orders.destination_country_slots.push_back(
            first.destination_country);
        _trade_orders.departure_days.push_back(_sample_day);
        _trade_orders.arrival_days.push_back(arrival);
        _trade_orders.states.push_back(TradeOrderStore::IN_TRANSIT);
        _trade_orders.cargo_delivered.push_back(0);
        int64_t cash = 0;
        int64_t capacity = 0;
        int32_t trade_event_flags = 0;
        std::vector<EventLeg> trade_legs;
        trade_legs.reserve((cursor - begin) * 5U);
        for (size_t i = begin; i < cursor; ++i) {
            const TradeCandidate &candidate = accepted[i];
            int64_t sat = 0;
            const int64_t line_cash = saturating_sub(
                candidate.base_value, candidate.export_transfer, sat);
            cash = saturating_add(cash, line_cash, _saturation_count);
            capacity = saturating_add(capacity, candidate.capacity_work, _saturation_count);
            _trade_orders.line_goods.push_back(candidate.good);
            _trade_orders.line_quantities.push_back(candidate.quantity);
            _trade_orders.line_unit_prices.push_back(candidate.source_price);
            _trade_orders.line_destination_prices.push_back(
                candidate.destination_price);
            _trade_orders.line_base_values.push_back(candidate.base_value);
            _trade_orders.line_retail_values.push_back(candidate.retail_value);
            _trade_orders.line_import_transfers.push_back(
                candidate.import_transfer);
            _trade_orders.line_export_transfers.push_back(
                candidate.export_transfer);
            _trade_orders.line_flags.push_back(candidate.flags);
            trade_event_flags |= static_cast<int32_t>(candidate.flags) << 8;
            const int64_t order_id = _trade_orders.ids.back();
            trade_legs.push_back({FIELD_TRADE_QUANTITY,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.quantity});
            trade_legs.push_back({FIELD_TRADE_BASE_VALUE,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.base_value});
            trade_legs.push_back({FIELD_TRADE_RETAIL_VALUE,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.retail_value});
            trade_legs.push_back({FIELD_TRADE_IMPORT_TRANSFER,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.import_transfer});
            trade_legs.push_back({FIELD_TRADE_EXPORT_TRANSFER,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.export_transfer});
        }
        _trade_orders.cash_escrow.push_back(cash);
        _trade_orders.capacity_work.push_back(capacity);
        _trade_orders.line_offsets.push_back(
            static_cast<int32_t>(_trade_orders.line_goods.size()));
        for (int32_t k = _merchant_offsets[first.source];
             k < _merchant_offsets[first.source + 1]; ++k) {
            const int32_t slot = _merchant_slots[k];
            _trade_orders.seller_handles.push_back(_population.handle_for_slot(slot));
            _trade_orders.seller_weights.push_back(
                std::max<int64_t>(1, _population.population[slot]));
        }
        _trade_orders.seller_offsets.push_back(
            static_cast<int32_t>(_trade_orders.seller_handles.size()));
        const bool trace_trade_detail = trace_detail_for_cell(first.source) ||
            trace_detail_for_cell(first.destination);
        trace_append(EVENT_TRADE_DISPATCHED,
            static_cast<int32_t>(Stage::TRADE_DISPATCH), first.destination,
            SUBJECT_TRADE_ORDER, _trade_orders.ids.back(), first.source,
            first.destination, static_cast<int64_t>(cursor - begin), cash,
            capacity, arrival, trace_trade_detail ? &trade_legs : nullptr,
            trade_event_flags);
        ++_trade_orders_dispatched;
        _trade_orders.arrival_buckets_dirty = true;
    }
    if (_trade_orders.arrival_buckets_dirty) rebuild_trade_arrival_buckets();
    _trade_dispatch_ms += elapsed_ms(started);
    return true;
}

int64_t NativeEconomyRuntime::trade_transit_goods() const {
    int64_t total = 0;
    int64_t sat = 0;
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        if (_trade_orders.cargo_delivered[order] != 0) continue;
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line)
            total = saturating_add(total, _trade_orders.line_quantities[line], sat);
    }
    return total;
}

int64_t NativeEconomyRuntime::trade_escrow_cash() const {
    int64_t total = 0;
    int64_t sat = 0;
    for (int64_t cash : _trade_orders.cash_escrow)
        total = saturating_add(total, cash, sat);
    return total;
}

} // namespace pk
