#include "economy_runtime_trade_includes.inc"

namespace pk {


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



} // namespace pk
