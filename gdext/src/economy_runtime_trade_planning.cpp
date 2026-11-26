#include "economy_runtime_trade_includes.inc"

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

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

} // namespace pk
