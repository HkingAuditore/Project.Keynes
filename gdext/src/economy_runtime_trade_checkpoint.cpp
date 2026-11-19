#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "runtime_checkpoint_wire.h"

namespace pk {
namespace {

template<class IO, class... Value>
bool fields(IO &io, Value &...value) {
    return (io.field(value) && ...);
}

template<class IO, class... Column>
bool columns(IO &io, Column &...column) {
    return (io.rows(column, checkpoint_scalar) && ...);
}

constexpr auto trade_signal = [](auto &io, auto &signal) {
    return fields(io, signal.cell, signal.good, signal.country, signal.price,
        signal.quantity, signal.age_days, signal.response_priority);
};

constexpr auto trade_candidate = [](auto &io, auto &candidate) {
    return fields(io, candidate.source, candidate.destination, candidate.good,
        candidate.country, candidate.source_country, candidate.destination_country,
        candidate.source_country_handle, candidate.destination_country_handle,
        candidate.route_cost, candidate.source_price, candidate.destination_price,
        candidate.quantity, candidate.expected_profit, candidate.base_value,
        candidate.retail_value, candidate.import_transfer, candidate.export_transfer,
        candidate.transaction_transfer, candidate.capacity_work, candidate.density_q16,
        candidate.signal_age_days, candidate.response_priority,
        candidate.source_price_stock_generation, candidate.destination_price_stock_generation,
        candidate.planned_day, candidate.topology_generation,
        candidate.country_topology_hash, candidate.flags);
};

constexpr auto pair_fields = [](auto &io, auto &row) {
    return fields(io, row.first, row.second);
};

template<class IO, class Plan>
bool plan_fields(IO &io, Plan &plan) {
    if (!fields(io, plan.phase, plan.scan_cursor, plan.route_cursor,
                plan.country_topology_hash, plan.topology_generation,
                plan.route_cache_country_topology_hash, plan.route_cache_topology_generation,
                plan.route_search_active, plan.route_search_source, plan.route_search_accepted,
                plan.route_search_pending_targets, plan.route_search_expansions,
                plan.completed_scans) ||
        !columns(io, plan.scan_cells, plan.scan_goods, plan.scan_inbound,
                 plan.route_cache_keys, plan.route_cache_costs) ||
        !io.rows(plan.sources, trade_signal) || !io.rows(plan.destinations, trade_signal) ||
        !io.rows(plan.working_candidates, trade_candidate) ||
        !io.rows(plan.ready_candidates, trade_candidate) ||
        !io.rows(plan.deferred_subsidy_candidates, trade_candidate)) return false;
    // Finished searches need only an empty workspace for the next source.
    return !plan.route_search_active ||
        (columns(io, plan.distance, plan.distance_stamp, plan.target_signal, plan.target_stamp) &&
         io.field(plan.search_stamp) && io.rows(plan.heap, pair_fields));
}

struct SignalHistory {
    uint64_t key;
    int64_t seen;
    int64_t dispatched;
    int64_t attempted;
    int32_t rejection;
    uint8_t deadline_reported;
};

constexpr auto signal_history = [](auto &io, auto &row) {
    return fields(io, row.key, row.seen, row.dispatched, row.attempted,
                  row.rejection, row.deadline_reported);
};

} // namespace

std::vector<uint8_t> EconomyAuthorityTransfer::capture_trade_continuation(
        const NativeEconomyRuntime &runtime) {
    if (!runtime._trade_topology.ready) return {};
    CheckpointWriter out;
    fields(out, runtime._trade_topology.topology_hash, runtime._trade_topology.topology_generation);
    plan_fields(out, runtime._trade_plan);
    out.field(static_cast<uint32_t>(runtime._trade_active_keys.size()));
    for (const uint64_t key : runtime._trade_active_keys) {
        const auto idle = runtime._trade_active_key_idle_cycles.find(key);
        out.field(key);
        out.field(idle == runtime._trade_active_key_idle_cycles.end() ? uint8_t{0} : idle->second);
    }
    const auto &keys = runtime._trade_signal_clock_keys;
    out.field(static_cast<uint32_t>(keys.size()));
    for (size_t i = 0; i < keys.size(); ++i) {
        const SignalHistory row{keys[i], runtime._trade_signal_first_seen_day[i],
            runtime._trade_signal_first_dispatch_day[i], runtime._trade_signal_last_attempt_day[i],
            runtime._trade_signal_last_rejection_reason[i], runtime._trade_signal_deadline_reported[i]};
        signal_history(out, row);
    }
    return std::move(out.bytes);
}

void EconomyAuthorityTransfer::restore_trade_continuation(
        NativeEconomyRuntime &runtime, const std::vector<uint8_t> &wire) {
    if (wire.empty()) return;
    using Plan = NativeEconomyRuntime::TradePlanStore;
    CheckpointReader in{wire.data(), wire.size()};
    uint64_t topology_hash = 0, topology_generation = 0;
    Plan plan;
    std::vector<std::pair<uint64_t, uint8_t>> keys;
    std::vector<SignalHistory> history;
    if (!fields(in, topology_hash, topology_generation) || !plan_fields(in, plan) ||
        !in.rows(keys, pair_fields) || !in.rows(history, signal_history) || in.cursor != in.size)
        return;
    const auto &market = runtime.market_store();
    const size_t cells = static_cast<size_t>(runtime._cell_count.get());
    const auto valid_pair = [&](int32_t cell, int32_t good) {
        return cell >= 0 && cell < market.market_count.get() &&
            good >= 0 && good < market.good_count.get();
    };
    plan.scan_total = static_cast<int64_t>(plan.scan_cells.size());
    if (plan.phase < Plan::IDLE || plan.phase > Plan::ROUTE ||
        plan.scan_goods.size() != plan.scan_cells.size() ||
        plan.scan_inbound.size() != plan.scan_cells.size() ||
        plan.scan_cursor < 0 || plan.scan_cursor > plan.scan_total ||
        plan.route_cursor < 0 || static_cast<size_t>(plan.route_cursor) > plan.sources.size() ||
        plan.route_cache_keys.size() != plan.route_cache_costs.size() ||
        (plan.route_cache_keys.size() & (plan.route_cache_keys.size() - 1)) != 0) return;
    for (size_t i = 0; i < plan.scan_cells.size(); ++i) {
        if (!valid_pair(plan.scan_cells[i], plan.scan_goods[i])) return;
    }
    for (const auto *signals : {&plan.sources, &plan.destinations}) {
        for (const auto &signal : *signals) {
            if (!valid_pair(signal.cell, signal.good)) return;
        }
    }
    if (plan.route_search_active) {
        if (plan.route_search_source != plan.route_cursor || plan.route_cache_keys.empty() ||
            plan.distance.size() != cells || plan.distance_stamp.size() != cells ||
            plan.target_signal.size() != cells || plan.target_stamp.size() != cells) return;
        for (const auto &entry : plan.heap) {
            if (entry.second < 0 || static_cast<size_t>(entry.second) >= cells) return;
        }
        for (size_t cell = 0; cell < cells; ++cell) {
            if (plan.target_stamp[cell] == plan.search_stamp &&
                (plan.target_signal[cell] < 0 ||
                 static_cast<size_t>(plan.target_signal[cell]) >= plan.destinations.size())) return;
        }
    } else if (plan.phase != Plan::IDLE) {
        plan.distance.assign(cells, 0);
        plan.distance_stamp.assign(cells, 0);
        plan.target_signal.assign(cells, -1);
        plan.target_stamp.assign(cells, 0);
    }
    runtime._trade_plan = std::move(plan);
    // Geography rebuilds the graph on the first topology capture.
    runtime._trade_topology.topology_hash = topology_hash;
    runtime._trade_topology.topology_generation = topology_generation;
    runtime._trade_active_keys.clear();
    runtime._trade_active_key_present.assign(market.stock.size(), 0);
    for (const auto &[key, idle] : keys) {
        const int32_t cell = static_cast<int32_t>(key >> 32);
        const int32_t good = static_cast<int32_t>(key);
        if (!valid_pair(cell, good)) continue;
        runtime._trade_active_keys.push_back(key);
        runtime._trade_active_key_present[market.index(cell, good)] = 1;
        if (idle != 0) runtime._trade_active_key_idle_cycles.emplace(key, idle);
    }
    for (const auto &row : history) {
        runtime._trade_signal_clock_keys.push_back(row.key);
        runtime._trade_signal_first_seen_day.push_back(row.seen);
        runtime._trade_signal_first_dispatch_day.push_back(row.dispatched);
        runtime._trade_signal_last_attempt_day.push_back(row.attempted);
        runtime._trade_signal_last_rejection_reason.push_back(row.rejection);
        runtime._trade_signal_deadline_reported.push_back(row.deadline_reported);
    }
}
} // namespace pk
