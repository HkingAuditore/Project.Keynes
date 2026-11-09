#include "economy_runtime.h"

#include <algorithm>
#include <tuple>

namespace pk {
namespace {
uint64_t demand_key(int32_t place, int32_t good) {
    return (uint64_t(static_cast<uint32_t>(place)) << 32) | static_cast<uint32_t>(good);
}
int64_t demand_quantity(const std::vector<std::pair<uint64_t, int64_t>> &rows,
                       int32_t place, int32_t good) {
    if (place < 0 || good < 0) return 0;
    const uint64_t key = demand_key(place, good);
    const auto row = std::lower_bound(rows.begin(), rows.end(), key,
        [](const auto &entry, uint64_t value) { return entry.first < value; });
    return row != rows.end() && row->first == key ? row->second : 0;
}
}

bool NativeEconomyRuntime::military_procurement_demand_valid(const Command &cmd) const {
    if (cmd.effective_day < 0 || cmd.sequence < 0 || cmd.i64_0 < 0) return false;
    if (cmd.i32_0 == -1)
        return cmd.target_handle == 0 && cmd.i64_0 == 0;
    return cmd.i32_0 >= 0 && cmd.i32_0 < _cell_count.get() &&
        cmd.i32_1 >= 0 && cmd.i32_1 < market_store().good_count.get() &&
        cmd.i64_1 > 0 && cmd.i64_1 <= 365 && _country_runtime != nullptr &&
        country_reads().valid_handle(static_cast<int64_t>(cmd.target_handle));
}

bool NativeEconomyRuntime::retain_military_procurement_demand(
        const Command &cmd, std::string &error) {
    if (!military_procurement_demand_valid(cmd)) {
        error = "military_procurement_demand_invalid";
        return false;
    }
    // POD plan and epoch replay may visit the same command. Retaining its
    // original identity makes replacement idempotent and archive-compatible.
    for (const Command &pending : _pending_commands)
        if (pending.opcode == COMMAND_MILITARY_PROCUREMENT_DEMAND &&
            pending.sequence == cmd.sequence && pending.effective_day == cmd.effective_day)
            return true;
    _pending_commands.push_back(cmd);
    return true;
}

int64_t NativeEconomyRuntime::epoch_military_demand_daily(int32_t cell, int32_t good) const {
    return demand_quantity(_epoch_military_demand_by_cell, cell, good);
}
int64_t NativeEconomyRuntime::epoch_military_demand_daily_for_market(
        int32_t market, int32_t good) const {
    return demand_quantity(_epoch_military_demand_by_market, market, good);
}

void NativeEconomyRuntime::refresh_epoch_military_demand(int64_t day) {
    _epoch_military_demand_by_cell.clear();
    _epoch_military_demand_by_market.clear();
    if (_country_runtime == nullptr || !country_reads().economy_available()) return;
    // A reset followed by rows is one complete daily replacement. Keep the
    // newest due snapshot and all future requests in the existing saved queue.
    int64_t snapshot_day = -1, snapshot_sequence = -1;
    for (const Command &cmd : _pending_commands) {
        if (cmd.opcode != COMMAND_MILITARY_PROCUREMENT_DEMAND || cmd.i32_0 != -1 ||
            cmd.effective_day > day) continue;
        if (std::tie(cmd.effective_day, cmd.sequence) >
            std::tie(snapshot_day, snapshot_sequence)) {
            snapshot_day = cmd.effective_day;
            snapshot_sequence = cmd.sequence;
        }
    }
    if (snapshot_day < 0) return;
    _pending_commands.erase_if([&](const Command &cmd) {
        return cmd.opcode == COMMAND_MILITARY_PROCUREMENT_DEMAND &&
            std::tie(cmd.effective_day, cmd.sequence) <
            std::tie(snapshot_day, snapshot_sequence);
    });
    std::vector<Command> lines;
    for (const Command &cmd : _pending_commands)
        if (cmd.opcode == COMMAND_MILITARY_PROCUREMENT_DEMAND && cmd.i32_0 >= 0 &&
            cmd.effective_day == snapshot_day && cmd.sequence > snapshot_sequence &&
            military_procurement_demand_valid(cmd)) lines.push_back(cmd);
    std::sort(lines.begin(), lines.end(), [](const Command &a, const Command &b) {
        return a.sequence < b.sequence;
    });
    lines.erase(std::unique(lines.begin(), lines.end(), [](const Command &a, const Command &b) {
        return a.sequence == b.sequence;
    }), lines.end());
    std::vector<int64_t> cash_left(static_cast<size_t>(_epoch_country_count), 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        int64_t cash = std::max<int64_t>(0, country_reads().cash_for_slot(country));
        bool enabled = false;
        int64_t daily = 0, remaining = 0;
        research_procurement_policy_for(country, enabled, daily, remaining);
        if (enabled && remaining > 0)
            cash = std::max<int64_t>(0, cash - saturating_mul(std::max<int64_t>(0, daily),
                std::max(1, _epoch_days.get()), _saturation_count));
        cash_left[static_cast<size_t>(country)] = cash;
    }
    // Other frozen public buyers cannot promise the same treasury twice.
    for (const auto *rows : {&_epoch_colonization_demand_by_cell, &_epoch_era_demand_by_cell}) {
        for (const auto &row : *rows) {
            const int32_t cell = static_cast<int32_t>(row.first >> 32);
            const int32_t good = static_cast<int32_t>(row.first & 0xffffffffULL);
            const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
            if (country < 0 || country >= _epoch_country_count) continue;
            const int32_t market = market_store().cell_to_market[cell];
            if (market < 0 || market >= market_store().market_count.get()) continue;
            const int64_t price = std::max<int64_t>(1,
                market_store().price[market_store().index(market, good)]);
            int64_t &cash = cash_left[static_cast<size_t>(country)];
            cash = std::max<int64_t>(0, cash - goods_cost(row.second, price, _saturation_count));
        }
    }
    for (const Command &cmd : lines) {
        const int32_t cell = cmd.i32_0, good = cmd.i32_1;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count ||
            _epoch_country_handles[static_cast<size_t>(country)] != cmd.target_handle) continue;
        const int32_t market = market_store().cell_to_market[cell];
        if (market < 0 || market >= market_store().market_count.get()) continue;
        const int64_t price = std::max<int64_t>(1,
            market_store().price[market_store().index(market, good)]);
        int64_t &cash = cash_left[static_cast<size_t>(country)];
        const int64_t quantity = std::min(cmd.i64_0,
            mul_div_sat(cash, GOODS_SCALE, price, _saturation_count));
        if (quantity <= 0) continue;
        cash -= goods_cost(quantity, price, _saturation_count);
        const int64_t days = std::max<int64_t>(std::max(1, _epoch_days.get()), cmd.i64_1);
        const int64_t daily = quantity / days + (quantity % days != 0);
        _epoch_military_demand_by_cell.push_back({demand_key(cell, good), daily});
        _epoch_military_demand_by_market.push_back({demand_key(market, good), daily});
        ensure_market_signal_index(cell, good);
    }
    auto merge = [&](auto &rows) {
        std::sort(rows.begin(), rows.end());
        size_t write = 0;
        for (const auto &row : rows) {
            if (write > 0 && rows[write - 1].first == row.first)
                rows[write - 1].second = saturating_add(rows[write - 1].second,
                    row.second, _saturation_count);
            else rows[write++] = row;
        }
        rows.resize(write);
    };
    merge(_epoch_military_demand_by_cell);
    merge(_epoch_military_demand_by_market);
}
} // namespace pk
