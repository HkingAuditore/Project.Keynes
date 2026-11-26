#include "economy_runtime_trade_includes.inc"

namespace pk {

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
