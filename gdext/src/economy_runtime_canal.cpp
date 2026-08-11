#include "economy_runtime.h"

#include "country_runtime.h"
#include "effect_runtime.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <cmath>
#include <queue>

namespace pk {

using namespace godot;

namespace {

constexpr int32_t CANAL_MAX_EDGES = 32;
constexpr int32_t CANAL_BASE_GOODS_PER_EDGE = 6750;
constexpr int32_t CANAL_BASE_DAYS_PER_EDGE = 5;
constexpr int32_t CANAL_MAX_EDGE_RISE_Q16 = 1311; // round(0.02 * 65536)
constexpr uint8_t TERRAIN_OCEAN = 0;
constexpr uint8_t TERRAIN_COAST = 1;
constexpr uint8_t TERRAIN_MOUNTAIN = 6;
constexpr uint8_t TERRAIN_GLACIER = 17;
constexpr uint8_t TERRAIN_LAKE = 18;
constexpr uint8_t TERRAIN_REEF = 19;
constexpr uint8_t TERRAIN_SEA_ICE = 20;
constexpr uint8_t TERRAIN_KELP = 21;
constexpr uint8_t LANDFORM_HILL = 6;
constexpr uint8_t LANDFORM_MOUNTAIN = 7;
constexpr uint8_t LANDFORM_PEAK = 8;
constexpr uint8_t LANDFORM_BADLANDS = 10;
constexpr uint8_t LANDFORM_VOLCANO = 12;
constexpr uint8_t LANDFORM_PLATEAU = 13;
constexpr uint8_t LANDFORM_CANYON = 15;

uint64_t canal_mix(uint64_t hash, uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        hash ^= static_cast<uint8_t>((value >> (i * 8)) & 0xffU);
        hash *= 1099511628211ULL;
    }
    return hash;
}

godot::Dictionary canal_failure(const char *code, const char *message = nullptr) {
    godot::Dictionary out;
    out["ok"] = false;
    out["code"] = code;
    out["message"] = message == nullptr ? code : message;
    return out;
}

} // namespace

godot::Dictionary NativeEconomyRuntime::canal_quote_dictionary(
        const CanalQuote &quote) const {
    godot::Dictionary out;
    godot::PackedInt32Array cells;
    godot::PackedInt32Array dirs;
    godot::PackedInt32Array goods;
    godot::PackedInt64Array quantities;
    cells.resize(static_cast<int64_t>(quote.route_cells.size()));
    dirs.resize(static_cast<int64_t>(quote.route_edge_dirs.size()));
    goods.resize(2);
    quantities.resize(2);
    for (int i = 0; i < cells.size(); ++i) cells.set(i, quote.route_cells[static_cast<size_t>(i)]);
    for (int i = 0; i < dirs.size(); ++i) dirs.set(i, quote.route_edge_dirs[static_cast<size_t>(i)]);
    for (int i = 0; i < 2; ++i) {
        goods.set(i, quote.material_good_ids[static_cast<size_t>(i)]);
        quantities.set(i, quote.material_quantities[static_cast<size_t>(i)]);
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["message"] = "ok";
    out["quote_token"] = static_cast<int64_t>(quote.token);
    out["country_handle"] = static_cast<int64_t>(quote.country_handle);
    out["snapshot_day"] = quote.snapshot_day;
    out["route_cells"] = cells;
    out["route_edge_dirs"] = dirs;
    out["new_edge_count"] = quote.new_edge_count;
    out["reused_edge_count"] = quote.reused_edge_count;
    out["source_kind"] = quote.source_kind == CANAL_SOURCE_FRESHWATER
        ? "freshwater" : "saline";
    out["cash_required"] = quote.cash_required;
    out["construction_days"] = quote.construction_days;
    out["material_good_ids"] = goods;
    out["material_quantities"] = quantities;
    out["topology_hash"] = static_cast<int64_t>(quote.topology_hash);
    out["country_generation"] = static_cast<int64_t>(quote.country_generation);
    return out;
}

bool NativeEconomyRuntime::plan_canal_route(
        uint64_t country_handle, int32_t start_cell, int32_t end_cell,
        const godot::PackedInt32Array &waypoints, CanalQuote &quote,
        std::string &error) const {
    if (!_bootstrapped || _country_runtime == nullptr ||
        !_country_runtime->valid_handle(static_cast<int64_t>(country_handle))) {
        error = "canal_country_invalid";
        return false;
    }
    if (!_trade_topology.ready ||
        _trade_topology.neighbors.size() != static_cast<size_t>(_cell_count) * 6 ||
        _trade_topology.canal_edge_mask.size() != static_cast<size_t>(_cell_count) ||
        _building_elevation_q16.size() != static_cast<size_t>(_cell_count) ||
        _building_terrain.size() != static_cast<size_t>(_cell_count) ||
        _building_landform.size() != static_cast<size_t>(_cell_count) ||
        _building_is_water.size() != static_cast<size_t>(_cell_count) ||
        _building_has_river.size() != static_cast<size_t>(_cell_count)) {
        error = "canal_topology_unavailable";
        return false;
    }
    if (start_cell < 0 || start_cell >= _cell_count || end_cell < 0 ||
        end_cell >= _cell_count || start_cell == end_cell || waypoints.size() > 30) {
        error = "canal_endpoints_invalid";
        return false;
    }
    const int32_t country_slot = _country_runtime->country_slot_for_cell(start_cell);
    if (country_slot < 0 || _country_runtime->country_handle_for_cell(start_cell) !=
            static_cast<int64_t>(country_handle)) {
        error = "canal_cell_not_owned";
        return false;
    }
    const auto tech = std::find(_technology_ids.begin(), _technology_ids.end(),
                                "tech.canal_engineering");
    if (tech == _technology_ids.end() || !_country_runtime->has_technology(
            country_slot, static_cast<int32_t>(tech - _technology_ids.begin()))) {
        error = "canal_technology_locked";
        return false;
    }

    auto legal_cell = [&](int32_t cell) {
        if (cell < 0 || cell >= _cell_count || _building_is_water[cell] != 0 ||
            _country_runtime->country_handle_for_cell(cell) !=
                static_cast<int64_t>(country_handle)) return false;
        const uint8_t terrain = _building_terrain[cell];
        const uint8_t landform = _building_landform[cell];
        return terrain != TERRAIN_MOUNTAIN && terrain != TERRAIN_GLACIER &&
            landform != LANDFORM_MOUNTAIN && landform != LANDFORM_PEAK &&
            landform != LANDFORM_VOLCANO;
    };
    auto source_at = [&](int32_t cell) {
        uint8_t source = CANAL_SOURCE_NONE;
        if (_building_has_river[cell] != 0) source = CANAL_SOURCE_FRESHWATER;
        if (_trade_topology.canal_water.size() == static_cast<size_t>(_cell_count) &&
            _trade_topology.canal_edge_mask[cell] != 0 &&
            _trade_topology.canal_water[cell] > 0.0001f)
            source = CANAL_SOURCE_FRESHWATER;
        for (int direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[cell * 6 + direction];
            if (neighbor < 0) continue;
            const uint8_t terrain = _building_terrain[neighbor];
            if (terrain == TERRAIN_LAKE || _building_has_river[neighbor] != 0)
                source = CANAL_SOURCE_FRESHWATER;
            else if (source == CANAL_SOURCE_NONE &&
                     (terrain == TERRAIN_OCEAN || terrain == TERRAIN_COAST ||
                      terrain == TERRAIN_REEF || terrain == TERRAIN_SEA_ICE ||
                      terrain == TERRAIN_KELP))
                source = CANAL_SOURCE_SALINE;
        }
        return source;
    };
    if (!legal_cell(start_cell) || !legal_cell(end_cell)) {
        error = "canal_route_forbidden_terrain";
        return false;
    }
    const uint8_t start_source = source_at(start_cell);
    const uint8_t end_source = source_at(end_cell);
    quote.source_kind = std::max(start_source, end_source);
    if (quote.source_kind == CANAL_SOURCE_NONE) {
        error = "canal_water_source_required";
        return false;
    }

    std::vector<int32_t> stops;
    stops.reserve(static_cast<size_t>(waypoints.size()) + 2);
    stops.push_back(start_cell);
    for (int i = 0; i < waypoints.size(); ++i) stops.push_back(waypoints[i]);
    stops.push_back(end_cell);
    std::unordered_set<int32_t> used_cells;
    used_cells.insert(start_cell);
    quote.route_cells = {start_cell};
    quote.route_edge_dirs.clear();
    int32_t total_uphill = 0;

    for (size_t segment = 1; segment < stops.size(); ++segment) {
        const int32_t source = stops[segment - 1];
        const int32_t target = stops[segment];
        if (!legal_cell(source) || !legal_cell(target)) {
            error = "canal_waypoint_invalid";
            return false;
        }
        constexpr int64_t INF = std::numeric_limits<int64_t>::max() / 4;
        std::vector<int64_t> distance(static_cast<size_t>(_cell_count), INF);
        std::vector<int32_t> parent(static_cast<size_t>(_cell_count), -1);
        std::vector<int8_t> parent_dir(static_cast<size_t>(_cell_count), -1);
        using QueueRow = std::pair<int64_t, int32_t>;
        std::priority_queue<QueueRow, std::vector<QueueRow>, std::greater<QueueRow>> open;
        distance[source] = 0;
        open.push({0, source});
        while (!open.empty()) {
            const auto [cost, cell] = open.top();
            open.pop();
            if (cost != distance[cell]) continue;
            if (cell == target) break;
            for (int direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _trade_topology.neighbors[cell * 6 + direction];
                if (!legal_cell(neighbor) || (neighbor != target && used_cells.count(neighbor) != 0))
                    continue;
                const int32_t delta = _building_elevation_q16[neighbor] -
                                      _building_elevation_q16[cell];
                if (std::abs(delta) > CANAL_MAX_EDGE_RISE_Q16) continue;
                const bool reused = (_trade_topology.canal_edge_mask[cell] &
                                     (1U << direction)) != 0;
                const int64_t edge_cost = reused ? 1 :
                    1024 + std::abs(delta) +
                    (_building_terrain[neighbor] == TERRAIN_COAST ? 256 : 0);
                const int64_t next = cost + edge_cost;
                if (next < distance[neighbor] ||
                    (next == distance[neighbor] && cell < parent[neighbor])) {
                    distance[neighbor] = next;
                    parent[neighbor] = cell;
                    parent_dir[neighbor] = static_cast<int8_t>(direction);
                    open.push({next, neighbor});
                }
            }
        }
        if (parent[target] < 0) {
            error = "canal_route_not_found";
            return false;
        }
        std::vector<int32_t> segment_cells;
        std::vector<int32_t> segment_dirs;
        for (int32_t cursor = target; cursor != source; cursor = parent[cursor]) {
            segment_cells.push_back(cursor);
            segment_dirs.push_back(parent_dir[cursor]);
        }
        std::reverse(segment_cells.begin(), segment_cells.end());
        std::reverse(segment_dirs.begin(), segment_dirs.end());
        int32_t cursor = source;
        for (size_t i = 0; i < segment_cells.size(); ++i) {
            const int32_t neighbor = segment_cells[i];
            const int32_t direction = segment_dirs[i];
            const int32_t rise = std::max(0, _building_elevation_q16[neighbor] -
                                             _building_elevation_q16[cursor]);
            total_uphill += rise;
            if (total_uphill > CANAL_MAX_EDGE_RISE_Q16 ||
                quote.route_edge_dirs.size() >= CANAL_MAX_EDGES ||
                !used_cells.insert(neighbor).second) {
                error = total_uphill > CANAL_MAX_EDGE_RISE_Q16
                    ? "canal_total_uphill_exceeded" :
                    (quote.route_edge_dirs.size() >= CANAL_MAX_EDGES
                        ? "canal_route_too_long" : "canal_route_repeats_cell");
                return false;
            }
            quote.route_edge_dirs.push_back(direction);
            quote.route_cells.push_back(neighbor);
            cursor = neighbor;
        }
    }

    const auto lumber = std::find(_good_ids.begin(), _good_ids.end(), "lumber");
    const auto bricks = std::find(_good_ids.begin(), _good_ids.end(), "bricks");
    if (lumber == _good_ids.end() || bricks == _good_ids.end()) {
        error = "canal_material_catalog_missing";
        return false;
    }
    quote.material_good_ids = {{static_cast<int32_t>(lumber - _good_ids.begin()),
                                static_cast<int32_t>(bricks - _good_ids.begin())}};
    int64_t material_total = 0;
    quote.new_edge_count = 0;
    quote.reused_edge_count = 0;
    quote.construction_days = 0;
    for (size_t i = 0; i < quote.route_edge_dirs.size(); ++i) {
        const int32_t cell = quote.route_cells[i];
        const int32_t neighbor = quote.route_cells[i + 1];
        const int32_t direction = quote.route_edge_dirs[i];
        if ((_trade_topology.canal_edge_mask[cell] & (1U << direction)) != 0) {
            ++quote.reused_edge_count;
            continue;
        }
        ++quote.new_edge_count;
        const int32_t delta = std::abs(_building_elevation_q16[neighbor] -
                                       _building_elevation_q16[cell]);
        const uint8_t difficult_landform = std::max(
            _building_landform[cell], _building_landform[neighbor]);
        int32_t difficulty_q16 = 0;
        if (difficult_landform == LANDFORM_HILL)
            difficulty_q16 = Q16_ONE / 4;
        else if (difficult_landform == LANDFORM_BADLANDS ||
                 difficult_landform == LANDFORM_CANYON)
            difficulty_q16 = Q16_ONE / 2;
        else if (difficult_landform == LANDFORM_PLATEAU)
            difficulty_q16 = (Q16_ONE * 2) / 5;
        const int32_t factor_q16 = std::min<int32_t>(Q16_ONE * 2,
            Q16_ONE + static_cast<int32_t>((static_cast<int64_t>(delta) * Q16_ONE) /
                                           CANAL_MAX_EDGE_RISE_Q16) + difficulty_q16 +
            (_building_terrain[cell] == TERRAIN_COAST ? Q16_ONE / 4 : 0));
        const int64_t edge_goods = std::max<int64_t>(1,
            (static_cast<int64_t>(CANAL_BASE_GOODS_PER_EDGE) * factor_q16 +
             Q16_ONE - 1) / Q16_ONE);
        material_total += edge_goods;
        quote.construction_days += std::max<int32_t>(1,
            static_cast<int32_t>((static_cast<int64_t>(CANAL_BASE_DAYS_PER_EDGE) *
                                  factor_q16 + Q16_ONE - 1) / Q16_ONE));
    }
    if (quote.new_edge_count == 0) {
        error = "canal_route_already_complete";
        return false;
    }
    quote.material_quantities = {{material_total, material_total}};
    const int32_t market = _market.cell_to_market[start_cell];
    if (market < 0 || market >= _market.market_count) {
        error = "canal_market_unavailable";
        return false;
    }
    quote.cash_required = 0;
    quote.price_hash = 1469598103934665603ULL;
    for (int i = 0; i < 2; ++i) {
        const int32_t good = quote.material_good_ids[static_cast<size_t>(i)];
        const int64_t required = quote.material_quantities[static_cast<size_t>(i)];
        const int64_t treasury = std::max<int64_t>(0, _country_runtime->good_for_handle(
            static_cast<int64_t>(country_handle), good));
        const int64_t market_needed = required - std::min(required, treasury);
        const int64_t lane = _market.index(market, good);
        if (_market.stock[lane] < market_needed) {
            error = "canal_materials_insufficient";
            return false;
        }
        quote.cash_required += (market_needed * _market.price[lane]) / GOODS_SCALE;
        quote.price_hash = canal_mix(quote.price_hash, static_cast<uint64_t>(_market.price[lane]));
        quote.price_hash = canal_mix(quote.price_hash, static_cast<uint64_t>(_market.stock[lane]));
        quote.price_hash = canal_mix(quote.price_hash, static_cast<uint64_t>(treasury));
    }
    if (_country_runtime->cash_for_handle(static_cast<int64_t>(country_handle)) <
            quote.cash_required) {
        error = "canal_treasury_cash_insufficient";
        return false;
    }
    quote.country_handle = country_handle;
    quote.snapshot_day = _current_day;
    quote.topology_hash = _trade_topology.topology_hash;
    quote.country_generation = country_handle >> 32U;
    return true;
}

godot::Dictionary NativeEconomyRuntime::canal_route_quote(
        int64_t country_handle, int32_t start_cell, int32_t end_cell,
        const godot::PackedInt32Array &waypoints) {
    if (_epoch_active || _save.active || _restore.active)
        return canal_failure("canal_quote_busy");
    CanalQuote quote;
    std::string error;
    if (!plan_canal_route(static_cast<uint64_t>(country_handle), start_cell,
                          end_cell, waypoints, quote, error))
        return canal_failure(error.c_str());
    uint64_t token = canal_mix(_next_canal_quote_token++,
        static_cast<uint64_t>(country_handle));
    token = canal_mix(token, quote.topology_hash);
    token = canal_mix(token, static_cast<uint64_t>(quote.snapshot_day));
    token &= 0x7fffffffffffffffULL;
    if (token == 0) token = _next_canal_quote_token++;
    quote.token = token;
    _canal_quote_index[token] = static_cast<int32_t>(_canal_quotes.size());
    _canal_quotes.push_back(std::move(quote));
    return canal_quote_dictionary(_canal_quotes.back());
}

godot::Dictionary NativeEconomyRuntime::canal_route_quote_detail(
        int64_t country_handle, int64_t quote_token) const {
    const auto found = _canal_quote_index.find(static_cast<uint64_t>(quote_token));
    if (found == _canal_quote_index.end()) return canal_failure("canal_quote_stale");
    const CanalQuote &quote = _canal_quotes[static_cast<size_t>(found->second)];
    if (quote.country_handle != static_cast<uint64_t>(country_handle))
        return canal_failure("canal_quote_forbidden");
    std::string error;
    if (!validate_canal_quote_snapshot(quote, error))
        return canal_failure("canal_quote_stale", error.c_str());
    return canal_quote_dictionary(quote);
}

bool NativeEconomyRuntime::validate_canal_quote_snapshot(
        const CanalQuote &quote, std::string &error) const {
    if (_country_runtime == nullptr || !_country_runtime->valid_handle(
            static_cast<int64_t>(quote.country_handle)) ||
        quote.country_generation != (quote.country_handle >> 32U) ||
        !_trade_topology.ready || quote.topology_hash != _trade_topology.topology_hash ||
        _current_day < quote.snapshot_day || _current_day > quote.snapshot_day + 2) {
        error = "canal_quote_snapshot_changed";
        return false;
    }
    if (quote.route_cells.empty() || quote.route_edge_dirs.size() + 1 !=
            quote.route_cells.size()) {
        error = "canal_quote_route_invalid";
        return false;
    }
    uint64_t price_hash = 1469598103934665603ULL;
    const int32_t market = _market.cell_to_market[quote.route_cells.front()];
    for (int i = 0; i < 2; ++i) {
        const int32_t good = quote.material_good_ids[static_cast<size_t>(i)];
        const int64_t lane = _market.index(market, good);
        price_hash = canal_mix(price_hash, static_cast<uint64_t>(_market.price[lane]));
        price_hash = canal_mix(price_hash, static_cast<uint64_t>(_market.stock[lane]));
        price_hash = canal_mix(price_hash, static_cast<uint64_t>(
            _country_runtime->good_for_handle(static_cast<int64_t>(quote.country_handle), good)));
    }
    if (price_hash != quote.price_hash) {
        error = "canal_quote_price_snapshot_changed";
        return false;
    }
    for (const int32_t cell : quote.route_cells) {
        if (_country_runtime->country_handle_for_cell(cell) !=
                static_cast<int64_t>(quote.country_handle)) {
            error = "canal_quote_territory_changed";
            return false;
        }
    }
    return true;
}

godot::Dictionary NativeEconomyRuntime::queue_canal_construction(
        int64_t country_handle, int64_t quote_token, int64_t effective_day,
        int64_t sequence) {
    godot::Dictionary out;
    out["effective_day"] = effective_day;
    out["sequence"] = sequence;
    if (!_bootstrapped || _fatal || _save.active || _restore.active ||
        effective_day < 0 || sequence < 0) {
        out["ok"] = false; out["code"] = "canal_command_invalid";
        out["message"] = "canal_command_invalid";
        return out;
    }
    const auto found = _canal_quote_index.find(static_cast<uint64_t>(quote_token));
    if (found == _canal_quote_index.end()) {
        out["ok"] = false; out["code"] = "canal_quote_stale";
        out["message"] = "canal_quote_stale"; return out;
    }
    const CanalQuote &quote = _canal_quotes[static_cast<size_t>(found->second)];
    if (quote.country_handle != static_cast<uint64_t>(country_handle)) {
        out["ok"] = false; out["code"] = "canal_quote_forbidden";
        out["message"] = "canal_quote_forbidden"; return out;
    }
    std::string error;
    if (!validate_canal_quote_snapshot(quote, error)) {
        out["ok"] = false; out["code"] = "canal_quote_stale";
        out["message"] = error.c_str(); return out;
    }
    _pending_commands.push_back({COMMAND_BUILD_CANAL, effective_day, sequence,
        static_cast<uint64_t>(country_handle), quote.route_cells.front(), -1,
        quote_token, 0, _next_submit_order++});
    out["ok"] = true; out["code"] = "ok"; out["message"] = "ok";
    return out;
}

void NativeEconomyRuntime::stage_canal_receipt(
        const Command &cmd, bool ok, const char *code, uint64_t project_handle,
        int64_t cash_paid, int64_t treasury_goods_used,
        int64_t market_goods_used) {
    _canal_receipts.push_back({_next_canal_receipt_id++, cmd.effective_day,
        _current_day, cmd.sequence, cmd.target_handle, project_handle, ok,
        code == nullptr ? "canal_command_rejected" : code, cash_paid,
        treasury_goods_used, market_goods_used});
}

bool NativeEconomyRuntime::apply_canal_build_command(
        const Command &cmd, std::string &error) {
    const auto found = _canal_quote_index.find(static_cast<uint64_t>(cmd.i64_0));
    if (found == _canal_quote_index.end()) {
        stage_canal_receipt(cmd, false, "canal_quote_stale");
        return true;
    }
    const CanalQuote quote = _canal_quotes[static_cast<size_t>(found->second)];
    if (quote.country_handle != cmd.target_handle) {
        stage_canal_receipt(cmd, false, "canal_quote_forbidden");
        return true;
    }
    std::string stale;
    if (!validate_canal_quote_snapshot(quote, stale)) {
        stage_canal_receipt(cmd, false, "canal_quote_stale");
        return true;
    }
    const int32_t market = _market.cell_to_market[quote.route_cells.front()];
    std::array<int64_t, 2> treasury_used{{0, 0}};
    std::array<int64_t, 2> market_used{{0, 0}};
    int64_t cash = 0;
    int64_t treasury_total = 0;
    int64_t market_total = 0;
    for (int i = 0; i < 2; ++i) {
        const int32_t good = quote.material_good_ids[static_cast<size_t>(i)];
        const int64_t required = quote.material_quantities[static_cast<size_t>(i)];
        treasury_used[i] = std::min(required, std::max<int64_t>(0,
            _country_runtime->good_for_handle(static_cast<int64_t>(cmd.target_handle), good)));
        market_used[i] = required - treasury_used[i];
        const int64_t lane = _market.index(market, good);
        if (_market.stock[lane] < market_used[i]) {
            stage_canal_receipt(cmd, false, "canal_materials_insufficient");
            return true;
        }
        cash += (market_used[i] * _market.price[lane]) / GOODS_SCALE;
        treasury_total += treasury_used[i];
        market_total += market_used[i];
    }
    if (_country_runtime->cash_for_handle(static_cast<int64_t>(cmd.target_handle)) < cash) {
        stage_canal_receipt(cmd, false, "canal_treasury_cash_insufficient");
        return true;
    }
    if (cash > 0 && (_merchant_offsets.size() != static_cast<size_t>(_cell_count + 1) ||
                     _merchant_offsets[quote.route_cells.front()] >=
                     _merchant_offsets[quote.route_cells.front() + 1])) {
        stage_canal_receipt(cmd, false, "canal_market_unavailable");
        return true;
    }
    if (!_country_runtime->spend_treasury_assets(
            static_cast<int64_t>(cmd.target_handle), quote.material_good_ids.data(),
            treasury_used.data(), 2, cash)) {
        stage_canal_receipt(cmd, false, "canal_treasury_preflight_drift");
        return true;
    }
    for (int i = 0; i < 2; ++i) {
        const int64_t lane = _market.index(market, quote.material_good_ids[i]);
        audit_touch_market_lane(static_cast<size_t>(lane));
        _market.stock[lane] -= market_used[i];
        _construction_goods_consumed = saturating_add(_construction_goods_consumed,
            quote.material_quantities[i], _saturation_count);
    }
    if (cash > 0 && credit_local_merchants(quote.route_cells.front(), cash,
            CASHFLOW_MERCHANT_BUSINESS) != cash) {
        error = "canal_merchant_credit_invariant_failed";
        return false;
    }
    const uint32_t stable_id = static_cast<uint32_t>(_next_canal_project_id++);
    const uint64_t handle = (uint64_t{1} << 32U) | stable_id;
    CanalProject project;
    project.handle = handle;
    project.country_handle = quote.country_handle;
    project.effective_day = cmd.effective_day;
    project.sequence = cmd.sequence;
    project.ready_day = _current_day + quote.construction_days;
    project.topology_hash = quote.topology_hash;
    project.cash_paid = cash;
    project.treasury_goods_used = treasury_total;
    project.market_goods_used = market_total;
    project.source_kind = quote.source_kind;
    project.route_cells = quote.route_cells;
    project.route_edge_dirs = quote.route_edge_dirs;
    _canal_project_index[handle] = static_cast<int32_t>(_canal_projects.size());
    _canal_projects.push_back(std::move(project));
    stage_canal_receipt(cmd, true, "ok", handle, cash, treasury_total, market_total);
    _canal_quote_index.erase(static_cast<uint64_t>(cmd.i64_0));
    return true;
}

bool NativeEconomyRuntime::process_due_canal_projects(
        int64_t day, std::string &error) {
    for (CanalProject &project : _canal_projects) {
        if (project.state == CANAL_PROJECT_AWAITING_EFFECT) {
            if (_effect_runtime == nullptr || project.effect_transaction_id <= 0) continue;
            const int32_t status = _effect_runtime->transaction_status_pod(
                project.effect_transaction_id);
            if (status == EffectRuntime::ACKED) {
                project.state = CANAL_PROJECT_COMPLETED;
                project.route_cells.clear();
                project.route_edge_dirs.clear();
            } else if (status == EffectRuntime::REJECTED ||
                       status == EffectRuntime::RESYNC_REQUIRED) {
                project.state = CANAL_PROJECT_FAILED;
                _effect_runtime->consume_rejected_transaction_pod(
                    project.effect_transaction_id, static_cast<int64_t>(project.handle));
            }
            continue;
        }
        if (project.state != CANAL_PROJECT_BUILDING || project.ready_day > day)
            continue;
        if (_effect_runtime == nullptr) {
            error = "canal_effect_runtime_unavailable";
            return false;
        }
        int64_t transaction_id = 0;
        if (!_effect_runtime->enqueue_canal_commit_pod(
                static_cast<int64_t>(project.handle & 0x7fffffffffffffffULL), day,
                static_cast<int64_t>(project.handle), project.handle,
                project.generation, static_cast<uint64_t>(project.sequence),
                error, &transaction_id)) return false;
        project.effect_transaction_id = transaction_id;
        project.state = CANAL_PROJECT_AWAITING_EFFECT;
        // The fact is the bounded cross-domain notification: consumers receive
        // only the project identity, while the Effect adapter resolves the
        // authoritative route from this store.  Publish it once, after the
        // transaction has been durably accepted and before Effect execution.
        CommittedGameplayFact fact;
        fact.kind = GAMEPLAY_FACT_INFRASTRUCTURE_COMPLETED;
        fact.cell = project.route_cells.empty() ? -1 : project.route_cells.front();
        fact.entity_handle = project.handle;
        _committed_gameplay_facts.push_back(fact);
    }
    return true;
}

bool NativeEconomyRuntime::canal_project_commit_payload(
        uint64_t project_handle, uint32_t project_generation,
        std::vector<int32_t> &route_cells, std::vector<int32_t> &route_edge_dirs,
        uint64_t &topology_hash, std::string &error) const {
    const auto found = _canal_project_index.find(project_handle);
    if (found == _canal_project_index.end()) {
        error = "canal_project_unknown";
        return false;
    }
    const CanalProject &project = _canal_projects[static_cast<size_t>(found->second)];
    if (project.generation != project_generation ||
        project.state != CANAL_PROJECT_AWAITING_EFFECT ||
        project.route_cells.size() < 2 || project.route_cells.size() > 33 ||
        project.route_edge_dirs.size() + 1 != project.route_cells.size()) {
        error = "canal_project_payload_invalid";
        return false;
    }
    route_cells = project.route_cells;
    route_edge_dirs = project.route_edge_dirs;
    topology_hash = project.topology_hash;
    return true;
}

godot::Dictionary NativeEconomyRuntime::canal_construction_receipts(
        int64_t country_handle, int64_t after_receipt_id, int32_t limit) const {
    godot::Array rows;
    const int32_t bounded = std::clamp(limit, 0, 1024);
    for (const CanalConstructionReceipt &receipt : _canal_receipts) {
        if (receipt.receipt_id <= after_receipt_id ||
            receipt.country_handle != static_cast<uint64_t>(country_handle)) continue;
        godot::Dictionary row;
        row["ok"] = receipt.ok;
        row["code"] = receipt.code.c_str();
        row["message"] = receipt.code.c_str();
        row["effective_day"] = receipt.effective_day;
        row["settled_day"] = receipt.settled_day;
        row["sequence"] = receipt.sequence;
        row["project_handle"] = static_cast<int64_t>(receipt.project_handle);
        row["cash_paid"] = receipt.cash_paid;
        row["treasury_goods_used"] = receipt.treasury_goods_used;
        row["market_goods_used"] = receipt.market_goods_used;
        row["receipt_id"] = receipt.receipt_id;
        rows.push_back(row);
        if (rows.size() >= bounded) break;
    }
    godot::Dictionary out;
    out["ok"] = true;
    out["receipts"] = rows;
    out["count"] = rows.size();
    return out;
}

} // namespace pk
