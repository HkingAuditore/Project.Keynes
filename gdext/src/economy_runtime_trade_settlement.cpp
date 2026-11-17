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

int64_t NativeEconomyRuntime::credit_trade_sellers(
        int32_t order_index, int64_t amount, int32_t cashflow_source) {
    if (order_index < 0 || order_index >= trade_orders_store().size() || amount <= 0) return 0;
    const int32_t begin = trade_orders_store().seller_offsets[order_index];
    const int32_t end = trade_orders_store().seller_offsets[order_index + 1];
    int64_t total_weight = 0;
    std::vector<std::pair<int32_t, int64_t>> valid;
    valid.reserve(static_cast<size_t>(std::max(0, end - begin)));
    for (int32_t i = begin; i < end; ++i) {
        int32_t slot = -1;
        if (!population_store().valid_handle(trade_orders_store().seller_handles[i], slot) ||
            !is_merchant_slot(slot) ||
            population_store().page_cell[slot / COHORT_PAGE_SIZE] != trade_orders_store().sources[order_index])
            continue;
        const int64_t weight = std::max<int64_t>(1, trade_orders_store().seller_weights[i]);
        valid.push_back({slot, weight});
        total_weight = saturating_add(total_weight, weight, _saturation_count);
    }
    if (valid.empty() || total_weight <= 0) {
        const int64_t credited = credit_local_merchants(
            trade_orders_store().sources[order_index], amount,
            cashflow_source);
        if (credited > 0) {
            _merchant_trade_sale_cash = saturating_add(
                _merchant_trade_sale_cash, credited, _saturation_count);
            const int32_t cell = trade_orders_store().sources[order_index];
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
        population_store().funds.write_scalar(slot, saturating_add(
            population_store().funds[slot], share, _saturation_count), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, saturating_add(
            population_store().epoch_income[slot], share, _saturation_count), market_mutation_sink());
        trace_record_cashflow(trade_orders_store().sources[order_index],
            population_store().handle_for_slot(slot), cashflow_source, share, 0);
    }
    if (distributed > 0) {
        _merchant_trade_sale_cash = saturating_add(
            _merchant_trade_sale_cash, distributed, _saturation_count);
        const int32_t cell = trade_orders_store().sources[order_index];
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
    if (order_index < 0 || order_index >= trade_orders_store().size() || amount <= 0)
        return 0;
    const int32_t begin = trade_orders_store().seller_offsets[order_index];
    const int32_t end = trade_orders_store().seller_offsets[order_index + 1];
    std::vector<std::pair<int32_t, int64_t>> valid;
    valid.reserve(static_cast<size_t>(std::max(0, end - begin)));
    int64_t total_funds = 0;
    for (int32_t i = begin; i < end; ++i) {
        int32_t slot = -1;
        if (!population_store().valid_handle(trade_orders_store().seller_handles[i], slot) ||
            !is_merchant_slot(slot) ||
            population_store().page_cell[slot / COHORT_PAGE_SIZE] !=
                trade_orders_store().sources[order_index]) continue;
        const int64_t funds = std::max<int64_t>(0, population_store().funds[slot]);
        if (funds <= 0) continue;
        valid.push_back({slot, funds});
        total_funds = saturating_add(total_funds, funds, _saturation_count);
    }
    if (valid.empty() || total_funds <= 0)
        return debit_local_merchants(trade_orders_store().sources[order_index], amount,
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
            std::max<int64_t>(0, population_store().funds[slot]));
        distributed = saturating_add(distributed, share, _saturation_count);
        population_store().funds.write_scalar(slot, population_store().funds[slot] - (share), market_mutation_sink());
        population_store().epoch_expense.write_scalar(slot, saturating_add(
            population_store().epoch_expense[slot], share, _saturation_count), market_mutation_sink());
        trace_record_cashflow(trade_orders_store().sources[order_index],
            population_store().handle_for_slot(slot), cashflow_source, 0, share);
    }
    if (distributed > 0 && cashflow_source == CASHFLOW_EXPORT_TAX) {
        _merchant_trade_sale_cash = saturating_sub(
            _merchant_trade_sale_cash, distributed, _saturation_count);
        const int32_t cell = trade_orders_store().sources[order_index];
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
    trade_orders_store().arrival_bucket_days.clear();
    trade_orders_store().arrival_bucket_offsets.assign(1, 0);
    trade_orders_store().arrival_bucket_orders.clear();
    std::vector<int32_t> order_indices(static_cast<size_t>(trade_orders_store().size()));
    std::iota(order_indices.begin(), order_indices.end(), 0);
    std::stable_sort(order_indices.begin(), order_indices.end(), [&](int32_t a, int32_t b) {
        if (trade_orders_store().arrival_days[a] != trade_orders_store().arrival_days[b])
            return trade_orders_store().arrival_days[a] < trade_orders_store().arrival_days[b];
        return trade_orders_store().ids[a] < trade_orders_store().ids[b];
    });
    int64_t current_day = std::numeric_limits<int64_t>::min();
    for (const int32_t order : order_indices) {
        const int64_t day = trade_orders_store().arrival_days[order];
        if (trade_orders_store().arrival_bucket_days.empty() || day != current_day) {
            if (!trade_orders_store().arrival_bucket_days.empty())
                trade_orders_store().arrival_bucket_offsets.push_back(
                    static_cast<int32_t>(trade_orders_store().arrival_bucket_orders.size()));
            trade_orders_store().arrival_bucket_days.push_back(day);
            current_day = day;
        }
        trade_orders_store().arrival_bucket_orders.push_back(order);
    }
    if (!trade_orders_store().arrival_bucket_days.empty())
        trade_orders_store().arrival_bucket_offsets.push_back(
            static_cast<int32_t>(trade_orders_store().arrival_bucket_orders.size()));
    trade_orders_store().arrival_buckets_dirty = false;
}

void NativeEconomyRuntime::compact_trade_orders(const std::vector<uint8_t> &remove) {
    if (remove.size() != trade_orders_store().ids.size()) return;
    TradeOrderStore next;
    next.clear();
    next.next_id = trade_orders_store().next_id;
    for (int32_t i = 0; i < trade_orders_store().size(); ++i) {
        if (remove[i] != 0) continue;
        next.ids.push_back(trade_orders_store().ids[i]);
        next.sources.push_back(trade_orders_store().sources[i]);
        next.destinations.push_back(trade_orders_store().destinations[i]);
        next.countries.push_back(trade_orders_store().countries[i]);
        next.source_country_handles.push_back(
            trade_orders_store().source_country_handles[i]);
        next.destination_country_handles.push_back(
            trade_orders_store().destination_country_handles[i]);
        next.source_country_slots.push_back(
            trade_orders_store().source_country_slots[i]);
        next.destination_country_slots.push_back(
            trade_orders_store().destination_country_slots[i]);
        next.departure_days.push_back(trade_orders_store().departure_days[i]);
        next.arrival_days.push_back(trade_orders_store().arrival_days[i]);
        next.cash_escrow.push_back(trade_orders_store().cash_escrow[i]);
        next.capacity_work.push_back(trade_orders_store().capacity_work[i]);
        next.states.push_back(trade_orders_store().states[i]);
        next.cargo_delivered.push_back(trade_orders_store().cargo_delivered[i]);
        for (int32_t line = trade_orders_store().line_offsets[i];
             line < trade_orders_store().line_offsets[i + 1]; ++line) {
            next.line_goods.push_back(trade_orders_store().line_goods[line]);
            next.line_quantities.push_back(trade_orders_store().line_quantities[line]);
            next.line_unit_prices.push_back(trade_orders_store().line_unit_prices[line]);
            next.line_destination_prices.push_back(
                trade_orders_store().line_destination_prices[line]);
            next.line_base_values.push_back(
                trade_orders_store().line_base_values[line]);
            next.line_retail_values.push_back(
                trade_orders_store().line_retail_values[line]);
            next.line_import_transfers.push_back(
                trade_orders_store().line_import_transfers[line]);
            next.line_export_transfers.push_back(
                trade_orders_store().line_export_transfers[line]);
            next.line_transaction_transfers.push_back(
                trade_orders_store().line_transaction_transfers[line]);
            next.line_flags.push_back(trade_orders_store().line_flags[line]);
        }
        next.line_offsets.push_back(static_cast<int32_t>(next.line_goods.size()));
        for (int32_t seller = trade_orders_store().seller_offsets[i];
             seller < trade_orders_store().seller_offsets[i + 1]; ++seller) {
            next.seller_handles.push_back(trade_orders_store().seller_handles[seller]);
            next.seller_weights.push_back(trade_orders_store().seller_weights[seller]);
        }
        next.seller_offsets.push_back(static_cast<int32_t>(next.seller_handles.size()));
    }
    trade_orders_store() = std::move(next);
    rebuild_trade_arrival_buckets();
}

bool NativeEconomyRuntime::settle_due_trade_orders(std::string &error) {
    const auto started = Clock::now();
    if (trade_orders_store().ids.empty()) {
        _trade_settle_ms += elapsed_ms(started);
        return true;
    }
    if (trade_orders_store().arrival_buckets_dirty) rebuild_trade_arrival_buckets();
    std::vector<uint8_t> remove(static_cast<size_t>(trade_orders_store().size()), 0);
    for (int32_t bucket = 0;
         bucket < static_cast<int32_t>(trade_orders_store().arrival_bucket_days.size()) &&
         trade_orders_store().arrival_bucket_days[bucket] <= _sample_day; ++bucket) {
      for (int32_t position = trade_orders_store().arrival_bucket_offsets[bucket];
           position < trade_orders_store().arrival_bucket_offsets[bucket + 1]; ++position) {
        const int32_t order = trade_orders_store().arrival_bucket_orders[position];
        if (order < 0 || order >= trade_orders_store().size()) {
            error = "trade_arrival_bucket_invalid";
            return false;
        }
        if (trade_orders_store().cargo_delivered[order] == 0) {
            const int32_t destination = trade_orders_store().destinations[order];
            if (destination < 0 || destination >= market_store().market_count.get()) {
                error = "trade_order_destination_invalid";
                return false;
            }
            int64_t delivered = 0;
            int32_t trade_event_flags = 0;
            std::vector<EventLeg> trade_legs;
            trade_legs.reserve(static_cast<size_t>(std::max(0,
                trade_orders_store().line_offsets[order + 1] -
                trade_orders_store().line_offsets[order])) * 6U);
            for (int32_t line = trade_orders_store().line_offsets[order];
                 line < trade_orders_store().line_offsets[order + 1]; ++line) {
                const int32_t good = trade_orders_store().line_goods[line];
                const int64_t quantity = trade_orders_store().line_quantities[line];
                if (good < 0 || good >= market_store().good_count.get() || quantity <= 0) {
                    error = "trade_order_line_invalid";
                    return false;
                }
                const int64_t index = market_store().index(destination, good);
                audit_touch_market_lane(static_cast<size_t>(index));
                market_store().stock.write_scalar(index, saturating_add(
                    market_store().stock[index], quantity, _saturation_count), market_mutation_sink());
                delivered = saturating_add(delivered, quantity, _saturation_count);
                const int32_t flow = trade_flow_index(destination, good, true);
                if (flow >= 0) _trade_flows.period_import.write_scalar(flow, saturating_add(
                    _trade_flows.period_import[flow], quantity, _saturation_count), market_mutation_sink());
                CommittedGameplayFact fact;
                fact.kind = GAMEPLAY_FACT_TRADE_ARRIVED;
                fact.cell = destination;
                fact.entity_handle = static_cast<uint64_t>(
                    trade_orders_store().ids[order]);
                fact.entity_id = static_cast<int32_t>(std::clamp<int64_t>(
                    trade_orders_store().ids[order], 0,
                    std::numeric_limits<int32_t>::max()));
                fact.value = quantity;
                const int32_t source = trade_orders_store().sources[order];
                const int32_t source_country =
                    trade_orders_store().source_country_slots[order];
                const int32_t destination_country =
                    trade_orders_store().destination_country_slots[order];
                fact.payload = {source, source_country,
                                destination_country, good};
                const uint8_t line_flags = line < static_cast<int32_t>(
                        trade_orders_store().line_flags.size())
                    ? trade_orders_store().line_flags[line] : 0;
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
                // bast_fiber 走规则 10（见下方分支）；这里只处理 flax_fiber。
                // 修复前两者共用 5，导致下面的 bast_fiber = 10 成为死代码。
                else if (good_id == "flax_fiber")
                    contact_rule = 5;
                else if (good_id == "spices") contact_rule = 6;
                else if (good_id == "latex") contact_rule = 7;
                else if (good_id == "tin_ore" || good_id == "tin") contact_rule = 8;
                else if (good_id == "oceanic_vessels") contact_rule = 9;
                else if (good_id == "bast_fiber") contact_rule = 10;
                else if (good_id == "medicinal_herbs") contact_rule = 11;
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
                const int64_t order_id = trade_orders_store().ids[order];
                trade_legs.push_back({FIELD_TRADE_QUANTITY,
                    SUBJECT_TRADE_ORDER, order_id, good, 0, quantity});
                trade_legs.push_back({FIELD_TRADE_BASE_VALUE,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    trade_orders_store().line_base_values[line]});
                trade_legs.push_back({FIELD_TRADE_RETAIL_VALUE,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    trade_orders_store().line_retail_values[line]});
                trade_legs.push_back({FIELD_TRADE_IMPORT_TRANSFER,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    trade_orders_store().line_import_transfers[line]});
                trade_legs.push_back({FIELD_TRADE_EXPORT_TRANSFER,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    trade_orders_store().line_export_transfers[line]});
                trade_legs.push_back({FIELD_TRADE_TRANSACTION_TRANSFER,
                    SUBJECT_TRADE_ORDER, order_id, good, 0,
                    trade_orders_store().line_transaction_transfers[line]});
            }
            trade_orders_store().cargo_delivered.write_scalar(order, 1, market_mutation_sink());
            const int32_t source_cell = trade_orders_store().sources[order];
            // 货物按日历到达，不看目的地的分级节奏。休眠格必须在到货当日被拉回
            // T0，否则库存会挂在一个下次结算在 30 天后的市场上。
            request_cell_wake(destination);
            request_cell_wake(source_cell);
            if (source_cell != destination) {
                auto increment_trade_fact = [&](int32_t cell) {
                    if (cell < 0 || cell >= static_cast<int32_t>(
                            _cell_trade_gen.size()))
                        return;
                    if (_cell_trade_gen[static_cast<size_t>(cell)] !=
                        std::numeric_limits<uint32_t>::max())
                        _cell_trade_gen.write_scalar(static_cast<size_t>(cell), _cell_trade_gen[static_cast<size_t>(cell)] + 1, market_mutation_sink());
                };
                increment_trade_fact(source_cell);
                increment_trade_fact(destination);
            }
            _trade_settlement_lag_days = std::max<int64_t>(_trade_settlement_lag_days,
                _sample_day - trade_orders_store().arrival_days[order]);
            const bool trace_trade_detail = trace_detail_for_cell(destination) ||
                trace_detail_for_cell(trade_orders_store().sources[order]);
            trace_append(EVENT_TRADE_ARRIVED, static_cast<int32_t>(Stage::TRADE_SETTLE),
                destination, SUBJECT_TRADE_ORDER, trade_orders_store().ids[order],
                trade_orders_store().sources[order], destination, delivered,
                trade_orders_store().cash_escrow[order], trade_orders_store().departure_days[order],
                trade_orders_store().arrival_days[order],
                trace_trade_detail ? &trade_legs : nullptr,
                trade_event_flags);
            ++_trade_orders_arrived;
        }
        const int64_t escrow = trade_orders_store().cash_escrow[order];
        int64_t base_receipt = 0;
        int64_t export_tax = 0;
        int64_t export_subsidy = 0;
        for (int32_t line = trade_orders_store().line_offsets[order];
             line < trade_orders_store().line_offsets[order + 1]; ++line) {
            base_receipt = saturating_add(base_receipt,
                std::max<int64_t>(0, trade_orders_store().line_base_values[line]),
                _saturation_count);
            const int64_t transfer = trade_orders_store().line_export_transfers[line];
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
            trade_orders_store().cash_escrow.write_scalar(order, 0, market_mutation_sink());
            remove[order] = 1;
        } else {
            trade_orders_store().states.write_scalar(order, TradeOrderStore::WAITING_RECEIVER, market_mutation_sink());
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
            _trade_max_candidates.get() - static_cast<int32_t>(
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
                    0, _trade_response_days.get() - a.signal_age_days);
                const int32_t b_deadline = std::max(
                    0, _trade_response_days.get() - b.signal_age_days);
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
            merchant_population, _trade_capacity_per_merchant_q16.get(),
            _saturation_count);
        // The factor deliberately does NOT scale the pool any more. Applying it
        // in both places would multiply twice: a 2x card would mean 2x per
        // order AND 2x the capacity to carry them.
        country_capacity[static_cast<size_t>(country)] = saturating_add(
            country_capacity[static_cast<size_t>(country)], base_capacity,
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
            _country_good_trade.batch_epoch[index] == _epoch_id.get()) return;
        _country_good_trade.batch_epoch.write_scalar(index, _epoch_id.get(), market_mutation_sink());
        _country_good_trade.batch_import_quantity.write_scalar(index, 0, market_mutation_sink());
        _country_good_trade.batch_export_quantity.write_scalar(index, 0, market_mutation_sink());
        _country_good_trade.batch_import_base.write_scalar(index, 0, market_mutation_sink());
        _country_good_trade.batch_export_base.write_scalar(index, 0, market_mutation_sink());
        _country_good_trade.batch_import_tariff.write_scalar(index, 0, market_mutation_sink());
        _country_good_trade.batch_export_tariff.write_scalar(index, 0, market_mutation_sink());
    };
    const auto begin_country_partner_batch = [&](int32_t index) {
        if (index < 0 || index >= static_cast<int32_t>(
                _country_partner_trade.batch_epoch.size()) ||
            _country_partner_trade.batch_epoch[index] == _epoch_id.get()) return;
        _country_partner_trade.batch_epoch.write_scalar(index, _epoch_id.get(), market_mutation_sink());
        _country_partner_trade.batch_import_quantity.write_scalar(index, 0, market_mutation_sink());
        _country_partner_trade.batch_export_quantity.write_scalar(index, 0, market_mutation_sink());
        _country_partner_trade.batch_import_base.write_scalar(index, 0, market_mutation_sink());
        _country_partner_trade.batch_export_base.write_scalar(index, 0, market_mutation_sink());
        _country_partner_trade.batch_order_count.write_scalar(index, 0, market_mutation_sink());
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
        std::max(0, _trade_max_orders.get() - trade_orders_store().size())));
    merchant_funds_touched.reserve(accepted.capacity());
    for (const TradeCandidate &candidate : _trade_plan.ready_candidates) {
        const int32_t source_country = candidate.source_country >= 0
            ? candidate.source_country : candidate.country;
        const int32_t destination_country = candidate.destination_country >= 0
            ? candidate.destination_country : candidate.country;
        if (candidate.source < 0 || candidate.destination < 0 ||
            candidate.good < 0 || candidate.good >= market_store().good_count.get() ||
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
        const int64_t market_index = market_store().index(candidate.source, candidate.good);
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
                0, market_store().stock[market_index] - local_stock_target)).first;
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
            for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
                if (trade_orders_store().destinations[order] != candidate.destination) continue;
                for (int32_t line = trade_orders_store().line_offsets[order];
                     line < trade_orders_store().line_offsets[order + 1]; ++line) {
                    if (trade_orders_store().line_goods[line] == candidate.good)
                        inbound = saturating_add(inbound,
                            trade_orders_store().line_quantities[line], destination_sat);
                }
            }
            const int64_t destination_stock = market_store().stock[market_store().index(
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
        const int64_t destination_index = market_store().index(
            candidate.destination, candidate.good);
        clipped.source_price = estimate_trade_price(candidate.source, candidate.good,
            market_store().stock[market_index] - clipped.quantity, sat);
        clipped.destination_price = estimate_trade_price(
            candidate.destination, candidate.good,
            market_store().stock[destination_index] + clipped.quantity, sat);
        auto destination_cash_it = destination_trade_cash_remaining.find(
            candidate.destination);
        if (destination_cash_it == destination_trade_cash_remaining.end()) {
            int64_t merchant_cash = 0;
            for (int32_t k = _merchant_offsets[candidate.destination];
                 k < _merchant_offsets[candidate.destination + 1]; ++k) {
                merchant_cash = saturating_add(merchant_cash,
                    std::max<int64_t>(0,
                        population_store().funds[_merchant_slots[k]]), sat);
            }
            int64_t existing_order_reserved_cash = 0;
            for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
                if (trade_orders_store().destinations[order] ==
                        candidate.destination) {
                    existing_order_reserved_cash = saturating_add(
                        existing_order_reserved_cash,
                        std::max<int64_t>(0,
                            trade_orders_store().cash_escrow[order]), sat);
                }
            }
            const int64_t operating_floor = mul_div_sat(
                merchant_cash, _merchant_procurement_cash_reserve_q16.get(),
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
                    quote.margin_q16 >= _trade_min_margin_q16.get();
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
                market_store().stock[market_index] - quantity, sat);
            const int32_t quoted_destination = estimate_trade_price(
                candidate.destination, candidate.good,
                market_store().stock[destination_index] + quantity, sat);
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
            if (subsidy_blocked && _trade_runtime_mode.get() == 2) {
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
                        destination_country, CountryApi::TAX_IMPORT);
                    _tariff_history.requests.write_scalar(row, saturating_add(
                        _tariff_history.requests[row], import_request, sat), market_mutation_sink());
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
                        source_country, CountryApi::TAX_EXPORT);
                    _tariff_history.requests.write_scalar(row, saturating_add(
                        _tariff_history.requests[row], export_request, sat), market_mutation_sink());
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
                            _trade_max_candidates.get()) {
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
        clipped.transaction_transfer = best_quote.transaction_transfer;
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
        if (market_store().stock[market_index] - local_stock_target - reserved_stock <
                clipped.quantity) {
            ++_trade_rejected_stock;
            ++_trade_true_source_stock_failures;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_STOCK);
            continue;
        }
        if (_trade_runtime_mode.get() == 2 &&
            trade_orders_store().size() + static_cast<int32_t>(accepted.size()) >=
                _trade_max_orders.get()) {
            ++_trade_rejected_order_cap;
            record_trade_signal_attempt(candidate.destination, candidate.good,
                TRADE_SIGNAL_DIAG_ORDER_CAP);
            break;
        }
        const int64_t import_subsidy = -std::min<int64_t>(
            0, clipped.import_transfer);
        const int64_t export_subsidy = -std::min<int64_t>(
            0, clipped.export_transfer);
        if (_trade_runtime_mode.get() == 2 && (import_subsidy > 0 || export_subsidy > 0)) {
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
        if (_trade_runtime_mode.get() == 1) {
            accepted.push_back(clipped);
            continue;
        }
        const int64_t import_tax = std::max<int64_t>(
            0, clipped.import_transfer);
        const int32_t tx_rate = frozen_tax_rate(candidate.destination,
            CountryApi::TAX_TRANSACTION, candidate.good);
        const int32_t tx_mode = frozen_tax_mode(candidate.destination,
            CountryApi::TAX_TRANSACTION, candidate.good);
        const int64_t tx_base =
            tx_mode == CountryApi::TAX_MODE_ABSOLUTE
                ? std::max<int64_t>(0, clipped.quantity)
                : clipped.base_value;
        const int64_t transaction_tax = apply_fiscal_tax(
            candidate.destination, CountryApi::TAX_TRANSACTION,
            tx_base, std::max<int32_t>(0, tx_rate), tx_mode,
            _saturation_count);
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
        const int64_t debited_transaction = transaction_tax > 0
            ? debit_local_merchants(candidate.destination, transaction_tax,
                CASHFLOW_CONSUMPTION_TAX) : 0;
        const int64_t debited = saturating_add(
            saturating_add(debited_base, debited_tax, _saturation_count),
            debited_transaction, _saturation_count);
        const int64_t expected_debit = saturating_add(
            saturating_add(clipped.base_value, import_tax,
                           _saturation_count),
            std::max<int64_t>(0, clipped.transaction_transfer),
            _saturation_count);
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
        market_store().stock.write_scalar(market_index, market_store().stock[market_index] - (clipped.quantity), market_mutation_sink());
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
            _country_good_trade.import_quantity.write_scalar(import_good, saturating_add(
                _country_good_trade.import_quantity[import_good], clipped.quantity,
                _saturation_count), market_mutation_sink());
            _country_good_trade.batch_import_quantity.write_scalar(import_good, saturating_add(
                _country_good_trade.batch_import_quantity[import_good],
                clipped.quantity, _saturation_count), market_mutation_sink());
            _country_good_trade.import_base.write_scalar(import_good, saturating_add(
                _country_good_trade.import_base[import_good], clipped.base_value,
                _saturation_count), market_mutation_sink());
            _country_good_trade.batch_import_base.write_scalar(import_good, saturating_add(
                _country_good_trade.batch_import_base[import_good],
                clipped.base_value, _saturation_count), market_mutation_sink());
            _country_good_trade.import_tariff.write_scalar(import_good, saturating_add(
                _country_good_trade.import_tariff[import_good],
                clipped.import_transfer, _saturation_count), market_mutation_sink());
            _country_good_trade.batch_import_tariff.write_scalar(import_good, saturating_add(
                _country_good_trade.batch_import_tariff[import_good],
                clipped.import_transfer, _saturation_count), market_mutation_sink());
            _country_good_trade.export_quantity.write_scalar(export_good, saturating_add(
                _country_good_trade.export_quantity[export_good], clipped.quantity,
                _saturation_count), market_mutation_sink());
            _country_good_trade.batch_export_quantity.write_scalar(export_good, saturating_add(
                _country_good_trade.batch_export_quantity[export_good],
                clipped.quantity, _saturation_count), market_mutation_sink());
            _country_good_trade.export_base.write_scalar(export_good, saturating_add(
                _country_good_trade.export_base[export_good], clipped.base_value,
                _saturation_count), market_mutation_sink());
            _country_good_trade.batch_export_base.write_scalar(export_good, saturating_add(
                _country_good_trade.batch_export_base[export_good],
                clipped.base_value, _saturation_count), market_mutation_sink());
            _country_good_trade.export_tariff.write_scalar(export_good, saturating_add(
                _country_good_trade.export_tariff[export_good],
                clipped.export_transfer, _saturation_count), market_mutation_sink());
            _country_good_trade.batch_export_tariff.write_scalar(export_good, saturating_add(
                _country_good_trade.batch_export_tariff[export_good],
                clipped.export_transfer, _saturation_count), market_mutation_sink());
            const int32_t importer_partner = ensure_country_partner(
                destination_country, source_country);
            const int32_t exporter_partner = ensure_country_partner(
                source_country, destination_country);
            begin_country_partner_batch(importer_partner);
            begin_country_partner_batch(exporter_partner);
            _country_partner_trade.import_quantity.write_scalar(importer_partner, saturating_add(
                _country_partner_trade.import_quantity[importer_partner],
                clipped.quantity, _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_import_quantity.write_scalar(importer_partner, saturating_add(_country_partner_trade.batch_import_quantity[
                    importer_partner], clipped.quantity, _saturation_count), market_mutation_sink());
            _country_partner_trade.import_base.write_scalar(importer_partner, saturating_add(
                _country_partner_trade.import_base[importer_partner],
                clipped.base_value, _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_import_base.write_scalar(importer_partner, saturating_add(_country_partner_trade.batch_import_base[
                    importer_partner], clipped.base_value, _saturation_count), market_mutation_sink());
            _country_partner_trade.order_count.write_scalar(importer_partner, saturating_add(
                _country_partner_trade.order_count[importer_partner], 1,
                _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_order_count.write_scalar(importer_partner, saturating_add(_country_partner_trade.batch_order_count[
                    importer_partner], 1, _saturation_count), market_mutation_sink());
            _country_partner_trade.export_quantity.write_scalar(exporter_partner, saturating_add(
                _country_partner_trade.export_quantity[exporter_partner],
                clipped.quantity, _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_export_quantity.write_scalar(exporter_partner, saturating_add(_country_partner_trade.batch_export_quantity[
                    exporter_partner], clipped.quantity, _saturation_count), market_mutation_sink());
            _country_partner_trade.export_base.write_scalar(exporter_partner, saturating_add(
                _country_partner_trade.export_base[exporter_partner],
                clipped.base_value, _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_export_base.write_scalar(exporter_partner, saturating_add(_country_partner_trade.batch_export_base[
                    exporter_partner], clipped.base_value, _saturation_count), market_mutation_sink());
            _country_partner_trade.order_count.write_scalar(exporter_partner, saturating_add(
                _country_partner_trade.order_count[exporter_partner], 1,
                _saturation_count), market_mutation_sink());
            _country_partner_trade.batch_order_count.write_scalar(exporter_partner, saturating_add(_country_partner_trade.batch_order_count[
                    exporter_partner], 1, _saturation_count), market_mutation_sink());
            const auto update_tariff_history = [&](int32_t country, int32_t kind,
                                                    int64_t transfer) {
                const int32_t row = ensure_tariff_history(country, kind);
                _tariff_history.bases.write_scalar(row, saturating_add(
                    _tariff_history.bases[row], clipped.base_value,
                    _saturation_count), market_mutation_sink());
                if (transfer > 0) {
                    _tariff_history.assessed.write_scalar(row, saturating_add(
                        _tariff_history.assessed[row], transfer, _saturation_count), market_mutation_sink());
                    _tariff_history.collected.write_scalar(row, saturating_add(
                        _tariff_history.collected[row], transfer, _saturation_count), market_mutation_sink());
                } else if (transfer < 0) {
                    const int64_t subsidy = -transfer;
                    _tariff_history.requests.write_scalar(row, saturating_add(
                        _tariff_history.requests[row], subsidy, _saturation_count), market_mutation_sink());
                    _tariff_history.reserved.write_scalar(row, saturating_add(
                        _tariff_history.reserved[row], subsidy, _saturation_count), market_mutation_sink());
                    _tariff_history.paid.write_scalar(row, saturating_add(
                        _tariff_history.paid[row], subsidy, _saturation_count), market_mutation_sink());
                }
            };
            update_tariff_history(destination_country,
                CountryApi::TAX_IMPORT, clipped.import_transfer);
            update_tariff_history(source_country,
                CountryApi::TAX_EXPORT, clipped.export_transfer);
        }
        merchant_funds_touched.push_back(candidate.destination);
        accepted.push_back(clipped);
        record_trade_signal_attempt(candidate.destination, candidate.good,
            TRADE_SIGNAL_DIAG_DISPATCHED);
        const int32_t destination_signal = trade_signal_clock_index(
            candidate.destination, candidate.good);
        if (_trade_runtime_mode.get() == 2 && destination_signal >= 0 &&
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
        if (flow >= 0) _trade_flows.period_export.write_scalar(flow, saturating_add(
            _trade_flows.period_export[flow], clipped.quantity, _saturation_count), market_mutation_sink());
    }
    sort_dirty_country_trade_display_indices();
    _trade_plan.ready_candidates.clear();
    std::sort(merchant_funds_touched.begin(), merchant_funds_touched.end());
    merchant_funds_touched.erase(std::unique(merchant_funds_touched.begin(),
        merchant_funds_touched.end()), merchant_funds_touched.end());
    for (const int32_t cell : merchant_funds_touched) {
        if (cell >= 0 && cell < _cell_count.get())
            stage_cell_summary(cell, build_cell_summary(cell));
    }
    if (_trade_runtime_mode.get() != 2 || accepted.empty()) {
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
            1, mul_div_sat(_trade_speed_cost_per_day.get(), speed_factor,
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
        trade_orders_store().ids.push_back(trade_orders_store().next_id++);
        trade_orders_store().sources.push_back(first.source);
        trade_orders_store().destinations.push_back(first.destination);
        trade_orders_store().countries.push_back(first.country);
        trade_orders_store().source_country_handles.push_back(
            first.source_country_handle);
        trade_orders_store().destination_country_handles.push_back(
            first.destination_country_handle);
        trade_orders_store().source_country_slots.push_back(first.source_country);
        trade_orders_store().destination_country_slots.push_back(
            first.destination_country);
        trade_orders_store().departure_days.push_back(_sample_day);
        trade_orders_store().arrival_days.push_back(arrival);
        trade_orders_store().states.push_back(TradeOrderStore::IN_TRANSIT);
        trade_orders_store().cargo_delivered.push_back(0);
        int64_t cash = 0;
        int64_t capacity = 0;
        int32_t trade_event_flags = 0;
        std::vector<EventLeg> trade_legs;
        trade_legs.reserve((cursor - begin) * 6U);
        for (size_t i = begin; i < cursor; ++i) {
            const TradeCandidate &candidate = accepted[i];
            int64_t sat = 0;
            const int64_t line_cash = saturating_sub(
                candidate.base_value, candidate.export_transfer, sat);
            cash = saturating_add(cash, line_cash, _saturation_count);
            capacity = saturating_add(capacity, candidate.capacity_work, _saturation_count);
            trade_orders_store().line_goods.push_back(candidate.good);
            trade_orders_store().line_quantities.push_back(candidate.quantity);
            trade_orders_store().line_unit_prices.push_back(candidate.source_price);
            trade_orders_store().line_destination_prices.push_back(
                candidate.destination_price);
            trade_orders_store().line_base_values.push_back(candidate.base_value);
            trade_orders_store().line_retail_values.push_back(candidate.retail_value);
            trade_orders_store().line_import_transfers.push_back(
                candidate.import_transfer);
            trade_orders_store().line_export_transfers.push_back(
                candidate.export_transfer);
            trade_orders_store().line_transaction_transfers.push_back(
                candidate.transaction_transfer);
            trade_orders_store().line_flags.push_back(candidate.flags);
            trade_event_flags |= static_cast<int32_t>(candidate.flags) << 8;
            const int64_t order_id = trade_orders_store().ids.back();
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
            trade_legs.push_back({FIELD_TRADE_TRANSACTION_TRANSFER,
                SUBJECT_TRADE_ORDER, order_id, candidate.good, 0,
                candidate.transaction_transfer});
        }
        trade_orders_store().cash_escrow.push_back(cash);
        trade_orders_store().capacity_work.push_back(capacity);
        trade_orders_store().line_offsets.push_back(
            static_cast<int32_t>(trade_orders_store().line_goods.size()));
        for (int32_t k = _merchant_offsets[first.source];
             k < _merchant_offsets[first.source + 1]; ++k) {
            const int32_t slot = _merchant_slots[k];
            trade_orders_store().seller_handles.push_back(population_store().handle_for_slot(slot));
            trade_orders_store().seller_weights.push_back(
                std::max<int64_t>(1, population_store().population[slot]));
        }
        trade_orders_store().seller_offsets.push_back(
            static_cast<int32_t>(trade_orders_store().seller_handles.size()));
        const bool trace_trade_detail = trace_detail_for_cell(first.source) ||
            trace_detail_for_cell(first.destination);
        trace_append(EVENT_TRADE_DISPATCHED,
            static_cast<int32_t>(Stage::TRADE_DISPATCH), first.destination,
            SUBJECT_TRADE_ORDER, trade_orders_store().ids.back(), first.source,
            first.destination, static_cast<int64_t>(cursor - begin), cash,
            capacity, arrival, trace_trade_detail ? &trade_legs : nullptr,
            trade_event_flags);
        ++_trade_orders_dispatched;
        // Transient per-country counter for era advancement (country as
        // source or destination; one count per dispatched order).
        note_trade_order_countries(first.source, first.destination);
        trade_orders_store().arrival_buckets_dirty = true;
    }
    if (trade_orders_store().arrival_buckets_dirty) rebuild_trade_arrival_buckets();
    _trade_dispatch_ms += elapsed_ms(started);
    return true;
}


} // namespace pk
