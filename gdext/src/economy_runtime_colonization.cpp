#include "economy_runtime_colonization_includes.inc"

namespace pk {
#include "economy_runtime_colonization_internal.h"
uint64_t NativeEconomyRuntime::family_expedition_target_key(
        uint64_t country_handle, int32_t target_cell) const {
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, country_handle);
    hash = trace_hash_mix(hash, static_cast<uint32_t>(target_cell));
    return hash;
}

uint64_t NativeEconomyRuntime::colonization_visibility_hash(
        const uint8_t *visible, int32_t count) const {
    uint64_t hash = 1469598103934665603ULL;
    if (visible == nullptr || count <= 0) return hash;
    for (int32_t cell = 0; cell < count; ++cell) {
        if (visible[cell] == 0) continue;
        hash = trace_hash_mix(hash, static_cast<uint32_t>(cell));
    }
    return hash;
}

int64_t NativeEconomyRuntime::family_population_in_cell(
        uint64_t family_handle, int32_t cell) const {
    int32_t family = -1;
    if (!families_store().valid_handle(family_handle, family) || cell < 0 ||
        cell >= _cell_count.get()) return 0;
    int64_t total = 0;
    const bool csr = _family_member_offsets.size() == families_store().active.size() + 1;
    const int32_t begin = csr ? _family_member_offsets[family] : 0;
    const int32_t end = csr ? _family_member_offsets[family + 1]
        : static_cast<int32_t>(family_memberships().size());
    for (int32_t p = begin; p < end; ++p) {
        const FamilyMembershipEdge &edge = family_memberships()[
            csr ? _family_member_edge_indices[p] : p];
        if (edge.family_handle != family_handle) continue;
        int32_t slot = -1;
        if (population_store().valid_handle(edge.cohort_handle, slot) &&
            population_store().page_cell[slot / COHORT_PAGE_SIZE] == cell)
            total += std::max<int64_t>(0, edge.people);
    }
    return total;
}

int64_t NativeEconomyRuntime::family_dispatchable_population_in_cell(
        uint64_t family_handle, int32_t cell) const {
    int32_t family = -1;
    if (!families_store().valid_handle(family_handle, family) || cell < 0 ||
        cell >= _cell_count.get()) return 0;
    int64_t total = 0, civilians = 0, merchants = 0;
    const bool csr = _family_member_offsets.size() == families_store().active.size() + 1;
    const int32_t begin = csr ? _family_member_offsets[family] : 0;
    const int32_t end = csr ? _family_member_offsets[family + 1]
        : static_cast<int32_t>(family_memberships().size());
    for (int32_t p = begin; p < end; ++p) {
        const auto &edge = family_memberships()[
            csr ? _family_member_edge_indices[p] : p];
        int32_t slot = -1;
        if (edge.family_handle != family_handle || edge.people <= 0 ||
            !population_store().valid_handle(edge.cohort_handle, slot) ||
            population_store().page_cell[slot / COHORT_PAGE_SIZE] != cell) continue;
        total += edge.people;
        const int32_t signature = population_store().signature_id[slot];
        if (profession_is_state_service_only(_signatures[signature].profession_id)) continue;
        civilians += edge.people;
        if (is_merchant_slot(slot)) merchants += edge.people;
    }
    // 留下当地最后一名族人及最后一名商人，军人不参与派遣。
    const int64_t merchant_capacity = std::max<int64_t>(0,
        living_merchant_population(cell) - 1);
    return std::max<int64_t>(0, std::min(total - 1,
        civilians - std::max<int64_t>(0, merchants - merchant_capacity)));
}

int64_t NativeEconomyRuntime::anonymous_population_in_cell(int32_t cell) const {
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    int64_t total = 0, sat = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        total = saturating_add(total, std::max<int64_t>(0,
            population_store().population[slot] - family_people_on_slot(slot)),
            sat);
    });
    return total;
}

int64_t NativeEconomyRuntime::anonymous_dispatchable_in_cell(int32_t cell) const {
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    int64_t pool = 0, cell_people = 0, merchant_pool = 0, merchant_people = 0,
        sat = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int64_t people = std::max<int64_t>(0,
            population_store().population[slot]);
        const int64_t anonymous = std::max<int64_t>(0,
            people - family_people_on_slot(slot));
        cell_people = saturating_add(cell_people, people, sat);
        if (is_merchant_slot(slot)) {
            merchant_people = saturating_add(merchant_people, people, sat);
            merchant_pool = saturating_add(merchant_pool, anonymous, sat);
        }
        if (anonymous <= 0) return;
        const int32_t signature = static_cast<int32_t>(
            population_store().signature_id[slot]);
        if (signature < 0 ||
            signature >= static_cast<int32_t>(_signatures.size())) return;
        // 军人不随行，与家族派遣同一规则。
        if (profession_is_state_service_only(_signatures[signature].profession_id))
            return;
        pool = saturating_add(pool, anonymous, sat);
    });
    // 无家族人口可以整批迁走；只在"还有人留下"时才给商人队列留最后一人
    // （空格不需要商人，见 rebuild_merchant_ranges 的 population > 0 判断）。
    if (pool < cell_people && merchant_people > 0 && merchant_pool >= merchant_people)
        pool = std::max<int64_t>(0, pool - 1);
    return pool;
}

bool NativeEconomyRuntime::colonization_target_owner_allowed(
        uint64_t country_handle, int32_t cell) const {
    if (_country_runtime == nullptr || country_handle == 0 || cell < 0 ||
        cell >= _cell_count.get()) return false;
    const int64_t owner = country_reads().country_handle_for_cell(cell);
    return owner == 0 || owner == static_cast<int64_t>(country_handle);
}

bool NativeEconomyRuntime::colonization_destination_family_allowed(
        uint64_t family_handle, int32_t cell) const {
    if (family_handle == 0 || cell < 0 || cell >= _cell_count.get()) return false;
    if (family_population_in_cell(family_handle, cell) > 0) return true;
    if (_family_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1))
        return true;
    const int32_t count = _family_cell_offsets[static_cast<size_t>(cell) + 1] -
        _family_cell_offsets[static_cast<size_t>(cell)];
    return count < _family_max_per_cell.get();
}

bool NativeEconomyRuntime::plan_family_colonization_route(
        uint64_t country_handle, int32_t source_cell, int32_t target_cell,
        const uint8_t *visible, int32_t visible_count,
        std::vector<int32_t> &route, std::vector<int32_t> &cumulative,
        int32_t &cost, std::string &error) {
    route.clear(); cumulative.clear(); cost = 0;
    if (!_trade_topology.ready ||
        _trade_topology.neighbors.size() != static_cast<size_t>(_cell_count.get()) * 6 ||
        _trade_topology.passable.size() != static_cast<size_t>(_cell_count.get()) ||
        _trade_topology.enter_cost.size() != static_cast<size_t>(_cell_count.get())) {
        error = "colonization_topology_unavailable";
        return false;
    }
    if (country_handle == 0 || source_cell < 0 || source_cell >= _cell_count.get() ||
        target_cell < 0 || target_cell >= _cell_count.get() || source_cell == target_cell ||
        visible == nullptr || visible_count != _cell_count.get()) {
        error = "colonization_route_request_invalid";
        return false;
    }
    if (visible[source_cell] == 0 || visible[target_cell] == 0) {
        error = "colonization_route_not_visible";
        return false;
    }
    if (_trade_topology.passable[source_cell] == 0 ||
        _trade_topology.passable[target_cell] == 0) {
        error = "colonization_route_not_passable";
        return false;
    }
    if (_country_runtime == nullptr ||
        country_reads().country_handle_for_cell(source_cell) !=
            static_cast<int64_t>(country_handle) ||
        !colonization_target_owner_allowed(country_handle, target_cell)) {
        error = "colonization_route_territory_invalid";
        return false;
    }
    const uint8_t cap = water_capability_for_handle(country_handle, false);
    const size_t cells = static_cast<size_t>(_cell_count.get());
    if (_colonization_distance.size() != cells) {
        _colonization_distance.resize(cells);
        _colonization_distance_stamp.assign(cells, 0);
        _colonization_parent.resize(cells);
        _colonization_parent_stamp.assign(cells, 0);
        _colonization_search_stamp = 0;
    }
    if (++_colonization_search_stamp == 0) {
        std::fill(_colonization_distance_stamp.begin(),
                  _colonization_distance_stamp.end(), 0);
        std::fill(_colonization_parent_stamp.begin(),
                  _colonization_parent_stamp.end(), 0);
        _colonization_search_stamp = 1;
    }
    const uint32_t stamp = _colonization_search_stamp;
    _colonization_route_heap.clear();
    _colonization_distance[target_cell] = 0;
    _colonization_distance_stamp[target_cell] = stamp;
    _colonization_parent[target_cell] = -1;
    _colonization_parent_stamp[target_cell] = stamp;
    _colonization_route_heap.emplace_back(0, target_cell);
    std::push_heap(_colonization_route_heap.begin(),
                   _colonization_route_heap.end(), route_heap_less);
    int32_t expansions = 0;
    while (!_colonization_route_heap.empty() &&
           expansions < COLONIZATION_EXPANSION_BUDGET) {
        std::pop_heap(_colonization_route_heap.begin(),
                      _colonization_route_heap.end(), route_heap_less);
        const auto [distance, cell] = _colonization_route_heap.back();
        _colonization_route_heap.pop_back();
        if (_colonization_distance_stamp[cell] != stamp ||
            _colonization_distance[cell] != distance) continue;
        ++expansions;
        if (cell == source_cell) break;
        collect_transport_successors(cell, cap, true);
        for (size_t i = 0; i < _transport_succ_cells.size(); ++i) {
            const int32_t neighbor = _transport_succ_cells[i];
            if (neighbor < 0 || visible[neighbor] == 0 ||
                _trade_topology.passable[static_cast<size_t>(neighbor)] == 0) continue;
            const int64_t owner = country_reads().country_handle_for_cell(neighbor);
            if (owner != 0 && owner != static_cast<int64_t>(country_handle)) continue;
            const int64_t next = distance + std::max(1, _transport_succ_costs[i]);
            const bool unseen = _colonization_distance_stamp[neighbor] != stamp;
            const bool shorter = !unseen && next < _colonization_distance[neighbor];
            const bool tie = !unseen && next == _colonization_distance[neighbor] &&
                (_colonization_parent_stamp[neighbor] != stamp ||
                 cell < _colonization_parent[neighbor]);
            if (!unseen && !shorter && !tie) continue;
            _colonization_distance[neighbor] = next;
            _colonization_distance_stamp[neighbor] = stamp;
            _colonization_parent[neighbor] = cell;
            _colonization_parent_stamp[neighbor] = stamp;
            _colonization_route_heap.emplace_back(next, neighbor);
            std::push_heap(_colonization_route_heap.begin(),
                           _colonization_route_heap.end(), route_heap_less);
        }
    }
    if (_colonization_distance_stamp[source_cell] != stamp) {
        error = expansions >= COLONIZATION_EXPANSION_BUDGET
            ? "colonization_route_expansion_limit" : "colonization_route_unreachable";
        return false;
    }
    route.push_back(source_cell);
    cumulative.push_back(0);
    int32_t cursor = source_cell;
    int64_t running = 0;
    while (cursor != target_cell) {
        if (_colonization_parent_stamp[cursor] != stamp) {
            error = "colonization_route_parent_missing";
            return false;
        }
        const int32_t from = cursor;
        cursor = _colonization_parent[cursor];
        if (cursor < 0 || route.size() > static_cast<size_t>(_cell_count.get()) * 2) {
            error = "colonization_route_parent_cycle";
            return false;
        }
        if (!append_colonization_route_step(
                from, cursor, cap, _colonization_distance[from],
                _colonization_distance[cursor], route, cumulative, running)) {
            error = "colonization_route_water_invalid";
            return false;
        }
    }
    cost = cumulative.back();
    return true;
}

Dictionary NativeEconomyRuntime::submit_family_colonization_start(
        int64_t country_handle_value, int64_t family_handle_value,
        int32_t source_cell, int32_t target_cell, int64_t population,
        int64_t quote_token_value, int64_t effective_day, int64_t sequence,
        const uint8_t *visible, int32_t visible_count, uint64_t,
        bool queue_for_worker) {
    Dictionary out;
    if (!_bootstrapped || _fatal || _save.active || _restore.active) {
        out["ok"] = false;
        out["code"] = _fatal ? "economy_paused" : "economy_not_available";
        return out;
    }
    const uint64_t token = static_cast<uint64_t>(quote_token_value);
    const auto found = _colonization_quote_index.find(token);
    if (found == _colonization_quote_index.end()) {
        out["ok"] = false; out["code"] = "colonization_requote_required";
        return out;
    }
    ColonizationQuoteCacheEntry &quote = _colonization_quote_cache[found->second];
    if (quote.country_handle != static_cast<uint64_t>(country_handle_value) ||
        quote.family_handle != static_cast<uint64_t>(family_handle_value) ||
        quote.source_cell != source_cell || quote.target_cell != target_cell ||
        population < 1 || population > quote.maximum_population ||
        effective_day < 0 || sequence < 0) {
        out["ok"] = false; out["code"] = "colonization_command_invalid";
        return out;
    }
    Command command;
    command.opcode = COMMAND_START_FAMILY_EXPEDITION;
    command.effective_day = effective_day; command.sequence = sequence;
    command.target_handle = static_cast<uint64_t>(family_handle_value);
    command.i32_0 = source_cell; command.i32_1 = target_cell;
    command.i64_0 = population; command.i64_1 = country_handle_value;
    // Copy the route identity so the command can outlive the display quote.
    command.expedition_route_hash = quote.route_hash;
    // Under worker execution the caller is the main thread while the worker
    // may be mid-day: applying here races the expedition heap and stores.
    if (queue_for_worker) {
        enqueue_worker_command(command);
    } else {
        command.submit_order = _next_submit_order++;
        if (_epoch_active) _pending_commands.push_back(command);
    }
    if (queue_for_worker || _epoch_active) {
        out["ok"] = true; out["code"] = "colonization_queued";
        out["message"] = "Family expedition queued until settlement";
        out["queued"] = true;
        out["effective_day"] = effective_day; out["sequence"] = sequence;
        return out;
    }
    std::string error;
    if (!apply_start_family_expedition(command, error, visible, visible_count, quote.dest_kit_identity)) {
        out["ok"] = false; out["code"] = String(error.c_str()); return out;
    }
    const int32_t expedition = _family_expedition_target_index.at(
        family_expedition_target_key(quote.country_handle, target_cell));
    const bool preparing =
        family_expeditions_store().state[expedition] == EXPEDITION_PREPARING;
    out["ok"] = true;
    out["code"] = preparing ? "colonization_preparing" : "colonization_started";
    out["message"] = preparing ? "Family expedition is preparing"
                               : "Family expedition started";
    out["effective_day"] = effective_day; out["sequence"] = sequence;
    out["expedition_handle"] = static_cast<int64_t>(
        family_expeditions_store().handle_for_index(expedition));
    out["arrival_day"] = family_expeditions_store().due_day[expedition];
    return out;
}

Dictionary NativeEconomyRuntime::submit_family_colonization_cancel(
        int64_t country_handle_value, int64_t expedition_handle_value,
        int64_t effective_day, int64_t sequence, bool queue_for_worker) {
    Dictionary out;
    if (_fatal || _save.active || _restore.active) {
        out["ok"] = false;
        out["code"] = _fatal ? "economy_paused" : "economy_not_available";
        return out;
    }
    Command command;
    command.opcode = COMMAND_CANCEL_FAMILY_EXPEDITION;
    command.effective_day = effective_day; command.sequence = sequence;
    command.target_handle = static_cast<uint64_t>(expedition_handle_value);
    command.i64_1 = country_handle_value;
    if (queue_for_worker) {
        enqueue_worker_command(command);
    } else {
        command.submit_order = _next_submit_order++;
        if (_epoch_active) _pending_commands.push_back(command);
    }
    if (queue_for_worker || _epoch_active) {
        out["ok"] = true; out["code"] = "colonization_cancel_queued";
        out["message"] = "Family expedition cancel queued until settlement";
        out["queued"] = true;
        out["effective_day"] = effective_day; out["sequence"] = sequence;
        return out;
    }
    int32_t expedition = -1;
    const bool preparing = family_expeditions_store().valid_handle(command.target_handle, expedition) &&
        family_expeditions_store().state[expedition] == EXPEDITION_PREPARING;
    std::string error;
    if (!apply_cancel_family_expedition(command, error)) {
        out["ok"] = false; out["code"] = String(error.c_str()); return out;
    }
    out["ok"] = true;
    out["code"] = preparing ? "colonization_cancelled"
                           : "colonization_cancelled_returning";
    out["message"] = preparing ? "Family expedition preparation cancelled"
                               : "Family expedition is returning";
    out["effective_day"] = effective_day; out["sequence"] = sequence;
    return out;
}

void NativeEconomyRuntime::enqueue_worker_command(const Command &command) {
    std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
    _worker_command_inbox->commands.push_back(command);
}

void NativeEconomyRuntime::drain_worker_command_inbox() {
    std::vector<Command> commands;
    {
        std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
        commands.swap(_worker_command_inbox->commands);
    }
    for (Command &command : commands) {
        command.submit_order = _next_submit_order++;
        _pending_commands.push_back(command);
    }
}

void NativeEconomyRuntime::push_family_expedition_due(int32_t expedition) {
    _family_expedition_due_heap.emplace_back(
        family_expeditions_store().due_day[expedition], expedition);
    std::push_heap(_family_expedition_due_heap.begin(),
                   _family_expedition_due_heap.end(), due_heap_less);
}

void NativeEconomyRuntime::append_colonization_receipt(
        int32_t expedition, int64_t sequence, int64_t effective_day,
        int64_t settled_day, uint8_t kind, const char *code) {
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            family_expeditions_store().active.size())) return;
    append_colonization_command_receipt(
        family_expeditions_store().country_handle[expedition],
        family_expeditions_store().handle_for_index(expedition),
        family_expeditions_store().target_cell[expedition],
        sequence, effective_day, settled_day, kind, code);
}

void NativeEconomyRuntime::append_colonization_command_receipt(
        uint64_t country_handle, uint64_t expedition_handle,
        int32_t target_cell, int64_t sequence, int64_t effective_day,
        int64_t settled_day, uint8_t kind, const char *code) {
    ColonizationReceipt receipt;
    receipt.receipt_id = _next_colonization_receipt_id++;
    receipt.sequence = sequence; receipt.effective_day = effective_day;
    receipt.settled_day = settled_day;
    receipt.country_handle = country_handle;
    receipt.expedition_handle = expedition_handle;
    receipt.target_cell = target_cell;
    receipt.kind = kind; receipt.code = code == nullptr ? "" : code;
    _colonization_receipts.push_back(std::move(receipt));
    if (_colonization_receipts.size() > COLONIZATION_RECEIPT_LIMIT)
        _colonization_receipts.erase(_colonization_receipts.begin(),
            _colonization_receipts.begin() +
            (_colonization_receipts.size() - COLONIZATION_RECEIPT_LIMIT));
}

bool NativeEconomyRuntime::pending_family_expedition_target_taken(
        uint64_t country_handle, int32_t target_cell) const {
    const auto matches = [&](const Command &cmd) {
        return cmd.opcode == COMMAND_START_FAMILY_EXPEDITION &&
            cmd.i32_1 == target_cell && static_cast<uint64_t>(cmd.i64_1) == country_handle;
    };
    if (std::any_of(_pending_commands.begin(), _pending_commands.end(), matches) ||
        std::any_of(_epoch_commands.begin(), _epoch_commands.end(), matches))
        return true;
    std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
    const auto &inbox = _worker_command_inbox->commands;
    return std::any_of(inbox.begin(), inbox.end(), matches);
}

bool NativeEconomyRuntime::apply_family_expedition_player_command(
        const Command &cmd, std::string &error) {
    const bool ok = cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION
        ? apply_cancel_family_expedition(cmd, error)
        : apply_queued_family_expedition_start(cmd, error);
    if (ok) return true;
    append_colonization_command_receipt(static_cast<uint64_t>(cmd.i64_1),
        cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION ? cmd.target_handle : 0,
        cmd.opcode == COMMAND_START_FAMILY_EXPEDITION ? cmd.i32_1 : -1,
        cmd.sequence, cmd.effective_day, _current_day.get(), 7, error.c_str());
    ++_rejected_commands;
    error.clear();
    return true;
}

int64_t NativeEconomyRuntime::family_expedition_displayed_population(
        int32_t expedition) const {
    if (expedition < 0 ||
        expedition >= static_cast<int32_t>(family_expeditions_store().active.size()) ||
        family_expeditions_store().active[expedition] == 0)
        return 0;
    if (family_expeditions_store().state[expedition] == EXPEDITION_PREPARING)
        return std::max<int64_t>(0,
            family_expeditions_store().population[expedition] +
            family_expeditions_store().anonymous[expedition]);
    return family_expedition_payload_people(expedition);
}

int64_t NativeEconomyRuntime::market_stock(int32_t cell, int32_t good_id) const {
    if (cell < 0 || cell >= _cell_count.get() || good_id < 0 ||
        good_id >= market_store().good_count.get())
        return 0;
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0 || market >= market_store().market_count.get()) return 0;
    return std::max<int64_t>(0, market_store().stock[market_store().index(market, good_id)]);
}

bool NativeEconomyRuntime::colonization_good_is_tools(int32_t good_id) const {
    if (good_id < 0 ||
        good_id >= static_cast<int32_t>(_good_category_ids.size()))
        return false;
    return _good_category_ids[static_cast<size_t>(good_id)] == "tools";
}

} // namespace pk
