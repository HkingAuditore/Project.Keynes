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
#include "economy_runtime_trade_settlement_section_candidate_feasibility.inc"
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
#include "economy_runtime_trade_settlement_section_accepted_order_book.inc"
    if (trade_orders_store().arrival_buckets_dirty) rebuild_trade_arrival_buckets();
    _trade_dispatch_ms += elapsed_ms(started);
    return true;
}


} // namespace pk
