#include "economy_runtime.h"

#include "economy_runtime_variant_helpers.h"
#include "effect_runtime.h"
#include "economy_host_port.h"

#include <algorithm>
#include <chrono>
#include <functional>
#include <numeric>
#include <tuple>

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/variant.hpp>

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
        const uint8_t *visible, int32_t visible_count, uint64_t vision_revision,
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
    CountryReadView::Snapshot snapshot;
    if (_country_runtime == nullptr ||
        !country_reads().copy_economy_snapshot(snapshot)) {
        out["ok"] = false; out["code"] = "colonization_country_snapshot_unavailable";
        return out;
    }
    const uint64_t visibility_hash = trace_hash_mix(
        colonization_visibility_hash(visible, visible_count), vision_revision);
    const bool revisions_match =
        quote.topology_generation == _trade_topology.topology_generation &&
        quote.country_generation == snapshot.generation &&
        quote.vision_hash == visibility_hash;
    if (!revisions_match && !_epoch_active) {
        std::vector<int32_t> route, cumulative;
        int32_t route_cost = 0;
        std::string error;
        if (!plan_family_colonization_route(
                static_cast<uint64_t>(country_handle_value), source_cell,
                target_cell, visible, visible_count, route, cumulative,
                route_cost, error)) {
            out["ok"] = false; out["code"] = "colonization_requote_required";
            out["message"] = String(error.c_str()); return out;
        }
        uint64_t route_hash = 1469598103934665603ULL;
        for (size_t i = 0; i < route.size(); ++i) {
            route_hash = trace_hash_mix(route_hash,
                static_cast<uint32_t>(route[i]));
            route_hash = trace_hash_mix(route_hash,
                static_cast<uint32_t>(cumulative[i]));
        }
        if (route_hash != quote.route_hash) {
            out["ok"] = false; out["code"] = "colonization_requote_required";
            return out;
        }
        quote.topology_generation = _trade_topology.topology_generation;
        quote.country_generation = snapshot.generation;
        quote.vision_hash = visibility_hash;
    }
    const uint64_t target_key = family_expedition_target_key(
        static_cast<uint64_t>(country_handle_value), target_cell);
    if (_family_expedition_target_index.find(target_key) !=
            _family_expedition_target_index.end() ||
        pending_family_expedition_target_taken(
            static_cast<uint64_t>(country_handle_value), target_cell)) {
        out["ok"] = false; out["code"] = "colonization_duplicate_target";
        return out;
    }
    // 无家族移民队直接搬当地无家族人口，因此校验口径是匿名可派上限；
    // 家族队仍然按可派族人校验，并至少给源地留一人。
    if (static_cast<uint64_t>(family_handle_value) == 0) {
        if (population > anonymous_dispatchable_in_cell(source_cell)) {
            out["ok"] = false; out["code"] = "colonization_population_insufficient";
            return out;
        }
    } else if (family_population_in_cell(
                   static_cast<uint64_t>(family_handle_value),
                   source_cell) <= population) {
        out["ok"] = false; out["code"] = "colonization_population_insufficient";
        return out;
    }
    Command command;
    command.opcode = COMMAND_START_FAMILY_EXPEDITION;
    command.effective_day = effective_day; command.sequence = sequence;
    command.target_handle = static_cast<uint64_t>(family_handle_value);
    command.i32_0 = source_cell; command.i32_1 = target_cell;
    command.i64_0 = population; command.i64_1 = quote_token_value;
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
    if (!apply_start_family_expedition(command, error)) {
        out["ok"] = false; out["code"] = String(error.c_str()); return out;
    }
    const int32_t expedition = _family_expedition_target_index[target_key];
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
    int32_t expedition = -1;
    if (!family_expeditions_store().valid_handle(
            static_cast<uint64_t>(expedition_handle_value), expedition) ||
        family_expeditions_store().country_handle[expedition] !=
            static_cast<uint64_t>(country_handle_value)) {
        out["ok"] = false; out["code"] = "colonization_expedition_invalid";
        return out;
    }
    if (pending_family_expedition_cancel_taken(
            static_cast<uint64_t>(expedition_handle_value))) {
        out["ok"] = false; out["code"] = "colonization_expedition_invalid";
        return out;
    }
    const bool preparing =
        family_expeditions_store().state[expedition] == EXPEDITION_PREPARING;
    Command command;
    command.opcode = COMMAND_CANCEL_FAMILY_EXPEDITION;
    command.effective_day = effective_day; command.sequence = sequence;
    command.target_handle = static_cast<uint64_t>(expedition_handle_value);
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
    auto matches = [&](const Command &cmd) {
        if (cmd.opcode != COMMAND_START_FAMILY_EXPEDITION ||
            cmd.i32_1 != target_cell) return false;
        const auto found = _colonization_quote_index.find(
            static_cast<uint64_t>(cmd.i64_1));
        if (found == _colonization_quote_index.end()) return true;
        return _colonization_quote_cache[found->second].country_handle ==
            country_handle;
    };
    for (const Command &cmd : _pending_commands)
        if (matches(cmd)) return true;
    for (const Command &cmd : _epoch_commands)
        if (matches(cmd)) return true;
    std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
    for (const Command &cmd : _worker_command_inbox->commands)
        if (matches(cmd)) return true;
    return false;
}

bool NativeEconomyRuntime::pending_family_expedition_cancel_taken(
        uint64_t expedition_handle) const {
    auto matches = [&](const Command &cmd) {
        return cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION &&
            cmd.target_handle == expedition_handle;
    };
    for (const Command &cmd : _pending_commands)
        if (matches(cmd)) return true;
    for (const Command &cmd : _epoch_commands)
        if (matches(cmd)) return true;
    std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
    for (const Command &cmd : _worker_command_inbox->commands)
        if (matches(cmd)) return true;
    return false;
}

bool NativeEconomyRuntime::has_pending_family_expedition_player_command() const {
    auto matches = [](const Command &cmd) {
        return cmd.opcode == COMMAND_START_FAMILY_EXPEDITION ||
            cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION;
    };
    for (const Command &cmd : _pending_commands)
        if (matches(cmd)) return true;
    for (const Command &cmd : _epoch_commands)
        if (matches(cmd)) return true;
    std::lock_guard<std::mutex> lock(_worker_command_inbox->mutex);
    return !_worker_command_inbox->commands.empty();
}

bool NativeEconomyRuntime::apply_family_expedition_player_command(
        const Command &cmd, std::string &error) {
    const bool ok = cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION
        ? apply_cancel_family_expedition(cmd, error)
        : apply_start_family_expedition(cmd, error);
    if (ok) return true;
    uint64_t country = 0;
    int32_t target_cell = cmd.i32_1;
    if (cmd.opcode == COMMAND_START_FAMILY_EXPEDITION) {
        const auto found = _colonization_quote_index.find(
            static_cast<uint64_t>(cmd.i64_1));
        if (found != _colonization_quote_index.end()) {
            country = _colonization_quote_cache[found->second].country_handle;
            target_cell = _colonization_quote_cache[found->second].target_cell;
        } else {
            int32_t family = -1;
            if (families_store().valid_handle(cmd.target_handle, family))
                country = _country_runtime == nullptr ? 0 :
                    static_cast<uint64_t>(country_reads().country_handle_for_cell(
                        families_store().home_cell[family]));
        }
    } else {
        int32_t expedition = -1;
        if (family_expeditions_store().valid_handle(cmd.target_handle, expedition)) {
            country = family_expeditions_store().country_handle[expedition];
            target_cell = family_expeditions_store().target_cell[expedition];
        }
    }
    append_colonization_command_receipt(country, cmd.target_handle, target_cell,
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

uint64_t NativeEconomyRuntime::hash_preparing_missing_stock(
        int32_t source_cell, const int32_t *good_ids, uint32_t count) const {
    if (good_ids == nullptr || count == 0) return 0;
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, COLONIZATION_PREPARING_STOCK_HASH_REVISION);
    for (uint32_t i = 0; i < count; ++i) {
        hash = trace_hash_mix(hash, static_cast<uint32_t>(good_ids[i]));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(
            market_stock(source_cell, good_ids[i])));
    }
    return hash;
}

void NativeEconomyRuntime::store_preparing_missing_goods(
        int32_t expedition, const ColonizationKitPlan &kit) {
    family_expeditions_store().missing_good_begin.write_scalar(expedition, static_cast<uint32_t>(family_expedition_missing_good_ids().size()), market_mutation_sink());
    const int32_t source = family_expeditions_store().source_cell[expedition];
    for (const int32_t good : kit.missing_good_ids) {
        family_expedition_missing_good_ids().push_back(good);
        family_expedition_missing_good_quantities().push_back(
            market_stock(source, good));
    }
    family_expeditions_store().missing_good_count.write_scalar(expedition, static_cast<uint32_t>(kit.missing_good_ids.size()), market_mutation_sink());
    uint64_t identity = hash_preparing_missing_stock(source,
        kit.missing_good_ids.empty() ? nullptr : kit.missing_good_ids.data(),
        static_cast<uint32_t>(kit.missing_good_ids.size()));
    // Stocking progress must move the identity too, otherwise a party whose
    // shortfall list is unchanged looks frozen to the UI while its escrow grows.
    identity = trace_hash_mix(identity,
        static_cast<uint64_t>(std::max<int64_t>(0, kit.bridge_required_units)));
    identity = trace_hash_mix(identity,
        static_cast<uint64_t>(std::max<int64_t>(0, kit.bridge_missing_units)));
    for (const FamilyExpeditionCargoLine &line : kit.cargo) {
        identity = trace_hash_mix(identity,
            static_cast<uint32_t>(line.good_id));
        identity = trace_hash_mix(identity,
            static_cast<uint64_t>(line.quantity));
    }
    family_expeditions_store().kit_missing_stock_identity.write_scalar(expedition, identity == 0 ? 1 : identity, market_mutation_sink());
}

void NativeEconomyRuntime::refresh_preparing_family_expedition_missing(
        int32_t expedition) {
    const uint32_t count = family_expeditions_store().missing_good_count[expedition];
    const uint32_t begin = family_expeditions_store().missing_good_begin[expedition];
    const int32_t source = family_expeditions_store().source_cell[expedition];
    if (count == 0 ||
        begin + count > family_expedition_missing_good_ids().size()) {
        family_expeditions_store().kit_missing_stock_identity.write_scalar(expedition, 0, market_mutation_sink());
        return;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const int32_t good = family_expedition_missing_good_ids()[begin + i];
        if (begin + i < family_expedition_missing_good_quantities().size())
            family_expedition_missing_good_quantities().write_scalar(begin + i, market_stock(source, good), market_mutation_sink());
    }
}

void NativeEconomyRuntime::abort_preparing_family_expedition(
        int32_t expedition, int64_t day, uint8_t kind, const char *code) {
    if (_family_expedition_procurement_continuation.active &&
        _family_expedition_procurement_continuation.expedition == expedition) {
        FamilyExpeditionProcurementContinuation &c =
            _family_expedition_procurement_continuation;
        if (c.pending_request_id != 0 && (c.phase == 1 || c.phase == 5)) {
            c.expedition = -1;
            _family_expedition_procurement_orphans.push_back(std::move(c));
        } else if (_simulation_host != nullptr) {
            _simulation_host->release_country_economy_asset_settlement(
                c.pending_request_id);
        }
        _family_expedition_procurement_continuation =
            FamilyExpeditionProcurementContinuation{};
    }
    _family_expedition_procurement_rejections.erase(expedition);
    // Stocked goods were drawn from the source market and must go back there,
    // or cancelling a preparation would destroy them.
    if (family_expeditions_store().cargo_count[expedition] > 0) {
        std::string ignored;
        restore_family_expedition_cargo(expedition,
            family_expeditions_store().source_cell[expedition], false, ignored);
    }
    const uint64_t key = family_expedition_target_key(
        family_expeditions_store().country_handle[expedition],
        family_expeditions_store().target_cell[expedition]);
    append_colonization_receipt(expedition, 0,
        family_expeditions_store().departure_day[expedition], day, kind, code);
    _family_expedition_target_index.erase(key);
    family_expeditions_store().release(expedition);
    note_family_expedition_audit_invalidation();
}

bool NativeEconomyRuntime::launch_preparing_family_expedition(
        int32_t expedition, int64_t day, const ColonizationKitPlan &kit,
        std::string &error) {
    // The escrow already holds every kit line, so only the people still have
    // to leave. A blocked payload extract keeps the stocked goods and retries
    // tomorrow instead of dumping them back on the market.
    family_expeditions_store().kit_building_begin.write_scalar(expedition, static_cast<uint32_t>(
        family_expedition_kit_buildings().size()), market_mutation_sink());
    if (kit.place_buildings != 0) {
        family_expedition_kit_buildings().insert(
            family_expedition_kit_buildings().end(),
            kit.buildings.begin(), kit.buildings.end());
        family_expeditions_store().kit_building_count.write_scalar(expedition, static_cast<uint32_t>(kit.buildings.size()), market_mutation_sink());
    } else {
        family_expeditions_store().kit_building_count.write_scalar(expedition, 0, market_mutation_sink());
    }
    if (!extract_family_expedition_payload(expedition,
            family_expeditions_store().population[expedition], error)) {
        // These failures cannot be fixed by waiting another day.  Keeping the
        // party in PREPARING while discarding the reason made the UI look like
        // a completed kit was simply waiting forever.
        if (error == "colonization_population_insufficient" ||
            error == "colonization_population_guard_failed" ||
            error == "colonization_payload_empty") {
            const std::string reason = error;
            abort_preparing_family_expedition(expedition, day, 7,
                reason == "colonization_population_insufficient"
                    ? "PREPARING_POPULATION_INSUFFICIENT"
                    : "PREPARING_PAYLOAD_INVALID");
            error.clear();
            return true;
        }
        // Slot allocation and peer synchronization are transient. Keep the
        // escrow and retry, but retain a receipt so the blocked cause is
        // inspectable instead of silently becoming "waiting for departure".
        const std::string retry_reason = error.empty()
            ? "colonization_payload_retry" : error;
        append_colonization_receipt(expedition, 0, day, day, 2,
            retry_reason.c_str());
        error.clear();
        family_expeditions_store().kit_building_count.write_scalar(expedition, 0, market_mutation_sink());
        store_preparing_missing_goods(expedition, kit);
        family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
        push_family_expedition_due(expedition);
        return true;
    }
    const int32_t travel = std::max(1,
        (family_expeditions_store().route_cost[expedition] +
         std::max(1, family_expeditions_store().speed[expedition]) - 1) /
        std::max(1, family_expeditions_store().speed[expedition]));
    family_expeditions_store().state.write_scalar(expedition, EXPEDITION_OUTBOUND, market_mutation_sink());
    family_expeditions_store().departure_day.write_scalar(expedition, day, market_mutation_sink());
    family_expeditions_store().due_day.write_scalar(expedition, day + travel, market_mutation_sink());
    family_expeditions_store().missing_good_count.write_scalar(expedition, 0, market_mutation_sink());
    family_expeditions_store().kit_missing_stock_identity.write_scalar(expedition, 0, market_mutation_sink());
    _family_expedition_procurement_rejections.erase(expedition);
    push_family_expedition_due(expedition);
    note_family_expedition_audit_invalidation();
    append_colonization_receipt(expedition, 0, day, day, 1, "STARTED");
    return true;
}

bool NativeEconomyRuntime::preparing_kit_launchable(
        const ColonizationKitPlan &kit, int64_t people) const {
    // Only a party that plants the opening build plan waits for a complete
    // kit; this is the rule apply_start_family_expedition uses. A target that
    // gained buildings while the party stocked up gets no kit, and holding the
    // party for one would leave it "ready" forever.
    const bool needs_complete_kit = kit.place_buildings != 0 &&
        people >= COLONIZATION_KIT_MIN_OWNER_SLOTS;
    return !needs_complete_kit ||
        (kit.kit_partial == 0 && !kit.buildings.empty());
}

bool NativeEconomyRuntime::advance_preparing_family_expedition(
        int32_t expedition, int64_t day, std::string &error) {
    const int32_t source = family_expeditions_store().source_cell[expedition];
    const int32_t target = family_expeditions_store().target_cell[expedition];
    const uint64_t country = family_expeditions_store().country_handle[expedition];
    const uint64_t family = family_expeditions_store().family_handle[expedition];
    const bool caravan = family == 0;
    // 家族队按可派族人缩编；移民队按可派无家族人口缩编。
    const int64_t people = caravan ? 0 : std::min(
        family_expeditions_store().population[expedition],
        family_dispatchable_population_in_cell(family, source));
    const int64_t anonymous_people = caravan ? std::min(
        family_expeditions_store().anonymous[expedition],
        anonymous_dispatchable_in_cell(source)) : 0;
    if (!colonization_target_owner_allowed(country, target)) {
        abort_preparing_family_expedition(expedition, day, 3,
            "TARGET_LOST_RETURNING");
        return true;
    }
    if (people <= 0 && anonymous_people <= 0) {
        abort_preparing_family_expedition(expedition, day, 7, "PREPARING_ABORTED");
        return true;
    }
    FamilyExpeditionProcurementContinuation &continuation =
        _family_expedition_procurement_continuation;
    if (continuation.active) {
        if (continuation.expedition != expedition) {
            error = "colonization_treasury_peer_busy";
            family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
            push_family_expedition_due(expedition);
            return true;
        }
        const int32_t good = continuation.good;
        const uint8_t cargo_flags = continuation.cargo_flags;
        const int64_t quantity = continuation.quantity;
        const bool purchased = advance_family_expedition_procurement(
            continuation, error);
        if (!purchased && continuation.active) {
            error.clear();
            family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
            push_family_expedition_due(expedition);
            return true;
        }
        if (!purchased)
            note_family_expedition_procurement_rejection(expedition, good,
                cargo_flags, day, error.empty() ? continuation.last_error : error);
        if (purchased && good >= 0 && quantity > 0) {
            const uint32_t begin =
                family_expeditions_store().cargo_begin[expedition];
            const uint32_t count =
                family_expeditions_store().cargo_count[expedition];
            const uint32_t end = begin + count;
            if (end > family_expedition_cargo().size()) {
                error = "colonization_cargo_range_invalid";
                return false;
            }
            std::vector<FamilyExpeditionCargoLine> cargo;
            cargo.reserve(count + 1);
            for (uint32_t i = begin; i < end; ++i)
                cargo.push_back(family_expedition_cargo()[i]);
            auto held = std::find_if(cargo.begin(), cargo.end(),
                [&](const FamilyExpeditionCargoLine &line) {
                    return line.good_id == good && line.flags == cargo_flags;
                });
            if (held == cargo.end()) {
                cargo.push_back({good, quantity, cargo_flags});
            } else {
                held->quantity = saturating_add(held->quantity, quantity,
                    _saturation_count);
            }
            std::sort(cargo.begin(), cargo.end(),
                [](const FamilyExpeditionCargoLine &a,
                   const FamilyExpeditionCargoLine &b) {
                    return std::tie(a.flags, a.good_id) <
                        std::tie(b.flags, b.good_id);
                });
            family_expeditions_store().cargo_begin.write_scalar(expedition, static_cast<uint32_t>(family_expedition_cargo().size()), market_mutation_sink());
            family_expedition_cargo().insert(family_expedition_cargo().end(),
                cargo.begin(), cargo.end());
            family_expeditions_store().cargo_count.write_scalar(expedition, static_cast<uint32_t>(cargo.size()), market_mutation_sink());
            // The line that was rejected earlier finally landed: drop the note so
            // the panel stops reporting a refusal that no longer blocks anything.
            const auto rejection =
                _family_expedition_procurement_rejections.find(expedition);
            if (rejection != _family_expedition_procurement_rejections.end() &&
                rejection->second.good == good &&
                rejection->second.cargo_flags == cargo_flags)
                _family_expedition_procurement_rejections.erase(rejection);
            note_family_expedition_audit_invalidation();
        }
        error.clear();
    }
    const bool family_reduced = people != family_expeditions_store().population[expedition];
    const bool anonymous_changed =
        anonymous_people != family_expeditions_store().anonymous[expedition];
    const bool population_reduced = family_reduced || anonymous_changed;
    if (population_reduced) {
        if (family_reduced)
            family_expeditions_store().population.write_scalar(expedition, people, market_mutation_sink());
        if (anonymous_changed)
            family_expeditions_store().anonymous.write_scalar(expedition, anonymous_people, market_mutation_sink());
        note_family_expedition_audit_invalidation();
    }
    // Stock up day by day. A cell that never holds a whole kit at once can
    // still fund one over time, so the party escrows the spare stock it can
    // afford today and the planner treats that escrow as available tomorrow.
    // Replanning every day is the point: there is no shortcut that skips the
    // top-up, because spare stock can appear in goods that were not short.
    ColonizationReserveContext reserve;
    std::vector<int64_t> reserved_stock;
    collect_family_expedition_reserved_stock(expedition, reserved_stock);
    reserve.reserved = &reserved_stock;
    reserve.prefer_reserved_candidates = true;
    ColonizationKitPlan kit;
    const int32_t travel = std::max(1,
        (family_expeditions_store().route_cost[expedition] +
         std::max(1, family_expeditions_store().speed[expedition]) - 1) /
        std::max(1, family_expeditions_store().speed[expedition]));
    if (!plan_colonization_kit(source, target, people + anonymous_people, travel,
            false, kit, false, &reserve)) {
        abort_preparing_family_expedition(expedition, day, 7, "PREPARING_ABORTED");
        return true;
    }
    // 缩编后按实际人数采购；已成交货物保留，后续只补实际缺口。
    if (population_reduced) {
        family_expeditions_store().kit_bridge_required_units.write_scalar(expedition,
            std::max<int64_t>(0, kit.bridge_required_units), market_mutation_sink());
        family_expeditions_store().kit_material_required_units.write_scalar(expedition,
            std::max<int64_t>(0, kit.material_required_units), market_mutation_sink());
    }
    // Stockpiling only ever clears once the whole opening kit is affordable.
    // When a construction group has no candidate the source market can ever
    // supply, that day never comes, so end the preparation instead of holding
    // the escrow and the target claim forever.
    if (kit.kit_unbuildable != 0) {
        abort_preparing_family_expedition(expedition, day, 7,
            "PREPARING_UNBUILDABLE");
        return true;
    }
    if (!reserve_preparing_family_expedition_cargo(expedition, kit, error, day)) {
        // Escrow accounting must never fatal the economy: keep what is already
        // held, report the shortfall, and try again tomorrow.
        error.clear();
        store_preparing_missing_goods(expedition, kit);
        family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
        push_family_expedition_due(expedition);
        return true;
    }
    if (preparing_kit_launchable(kit, people + anonymous_people))
        return launch_preparing_family_expedition(expedition, day, kit, error);
    store_preparing_missing_goods(expedition, kit);
    family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
    push_family_expedition_due(expedition);
    return true;
}

bool NativeEconomyRuntime::apply_start_family_expedition(
        const Command &cmd, std::string &error) {
    const auto found = _colonization_quote_index.find(
        static_cast<uint64_t>(cmd.i64_1));
    if (found == _colonization_quote_index.end()) {
        error = "colonization_requote_required"; return false;
    }
    const ColonizationQuoteCacheEntry &quote =
        _colonization_quote_cache[found->second];
    const bool caravan = quote.family_handle == 0;
    // 目标格按家族分支数限容；纯移民队不占家族坑位。
    if (!caravan && !colonization_destination_family_allowed(quote.family_handle,
            quote.target_cell)) {
        error = "colonization_family_cell_capacity"; return false;
    }
    // 家族队只搬族人；无家族移民队只搬当地无家族人口。人数口径都记在
    // `population`（家族）与 `anonymous`（平民）两条账上，队伍人数是两者之和。
    const int64_t requested_people = std::max<int64_t>(1, cmd.i64_0);
    const int64_t family_people = caravan ? 0 : requested_people;
    const int64_t anonymous_people = caravan ? std::min<int64_t>(
        requested_people, anonymous_dispatchable_in_cell(quote.source_cell)) : 0;
    if (anonymous_people <= 0 && family_people <= 0) {
        error = "colonization_population_insufficient"; return false;
    }
    const int64_t party_people = family_people + anonymous_people;
    ColonizationKitPlan kit;
    plan_colonization_kit(quote.source_cell, quote.target_cell, party_people,
        quote.travel_days, _epoch_active, kit);
    if (!_epoch_active && kit.dest_identity != quote.dest_kit_identity) {
        error = "colonization_kit_requote_required"; return false;
    }
    const int32_t expedition = family_expeditions_store().allocate();
    family_expeditions_store().stable_id.write_scalar(expedition, _next_family_expedition_stable_id++, market_mutation_sink());
    family_expeditions_store().country_handle.write_scalar(expedition, quote.country_handle, market_mutation_sink());
    family_expeditions_store().family_handle.write_scalar(expedition, quote.family_handle, market_mutation_sink());
    family_expeditions_store().source_cell.write_scalar(expedition, quote.source_cell, market_mutation_sink());
    family_expeditions_store().target_cell.write_scalar(expedition, quote.target_cell, market_mutation_sink());
    family_expeditions_store().departure_day.write_scalar(expedition, cmd.effective_day, market_mutation_sink());
    family_expeditions_store().route_cost.write_scalar(expedition, quote.route_cost, market_mutation_sink());
    family_expeditions_store().speed.write_scalar(expedition, COLONIZATION_SPEED, market_mutation_sink());
    family_expeditions_store().due_day.write_scalar(expedition, cmd.effective_day +
        std::max(1, quote.travel_days), market_mutation_sink());
    family_expeditions_store().state.write_scalar(expedition, EXPEDITION_OUTBOUND, market_mutation_sink());
    family_expeditions_store().population.write_scalar(expedition, family_people, market_mutation_sink());
    family_expeditions_store().anonymous.write_scalar(expedition, anonymous_people, market_mutation_sink());
    // Freeze the stocking denominator at expedition creation.  The live
    // market may re-plan substitutes later, but that must never make an
    // already funded party appear to lose progress.
    family_expeditions_store().kit_bridge_required_units.write_scalar(expedition, std::max<int64_t>(0, kit.bridge_required_units), market_mutation_sink());
    family_expeditions_store().kit_material_required_units.write_scalar(expedition, std::max<int64_t>(0, kit.material_required_units), market_mutation_sink());
    family_expeditions_store().route_begin.write_scalar(expedition, static_cast<uint32_t>(
        family_expedition_route_cells().size()), market_mutation_sink());
    family_expeditions_store().route_count.write_scalar(expedition, quote.route_count, market_mutation_sink());
    for (uint32_t i = 0; i < quote.route_count; ++i) {
        family_expedition_route_cells().push_back(
            _colonization_quote_route_cells[quote.route_begin + i]);
        family_expedition_route_costs().push_back(
            _colonization_quote_route_costs[quote.route_begin + i]);
    }
    uint64_t idempotency_key = 1469598103934665603ULL;
    idempotency_key = trace_hash_mix(idempotency_key,
        static_cast<uint64_t>(family_expeditions_store().stable_id[expedition]));
    idempotency_key = trace_hash_mix(idempotency_key,
        static_cast<uint64_t>(cmd.sequence));
    family_expeditions_store().idempotency_key.write_scalar(expedition, idempotency_key == 0 ? 1 : idempotency_key, market_mutation_sink());
    const bool needs_complete_kit = kit.place_buildings != 0 &&
        party_people >= COLONIZATION_KIT_MIN_OWNER_SLOTS;
    const bool kit_incomplete = kit.kit_partial != 0 || kit.buildings.empty();
    // The party exists from this point, so this epoch needs the colonization
    // channel even though its budget freeze already ran. Restoring it here also
    // keeps the fiscal page honest before the first purchase attempt.
    ensure_epoch_colonization_budget(quote.country_handle);
    auto occupy_preparing = [&]() {
        family_expeditions_store().payload_count.write_scalar(expedition, 0, market_mutation_sink());
        family_expeditions_store().kit_building_count.write_scalar(expedition, 0, market_mutation_sink());
        store_preparing_missing_goods(expedition, kit);
        family_expeditions_store().state.write_scalar(expedition, EXPEDITION_PREPARING, market_mutation_sink());
        family_expeditions_store().due_day.write_scalar(expedition, cmd.effective_day, market_mutation_sink());
        _family_expedition_target_index[family_expedition_target_key(
            quote.country_handle, quote.target_cell)] = expedition;
        push_family_expedition_due(expedition);
        note_family_expedition_audit_invalidation();
        append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
            cmd.effective_day, 1, "PREPARING");
        return true;
    };
    if (needs_complete_kit && kit_incomplete)
        return occupy_preparing();
    const bool cargo_reserved = reserve_preparing_family_expedition_cargo(
        expedition, kit, error, cmd.effective_day);
    const FamilyExpeditionProcurementContinuation &continuation =
        _family_expedition_procurement_continuation;
    const bool procurement_pending = continuation.active &&
        continuation.expedition == expedition;
    if (!cargo_reserved && (needs_complete_kit || procurement_pending)) {
        error.clear();
        return occupy_preparing();
    }
    if (!cargo_reserved)
        error.clear();
    if (!extract_family_expedition_cargo(expedition, kit, error)) {
        if (needs_complete_kit) {
            error.clear();
            return occupy_preparing();
        }
        family_expeditions_store().release(expedition);
        if (error.empty()) error = "colonization_kit_materials_short";
        return false;
    }
    if (!extract_family_expedition_payload(expedition, family_people, error)) {
        std::string ignored;
        restore_family_expedition_cargo(expedition, quote.source_cell, false,
            ignored);
        if (needs_complete_kit) {
            error.clear();
            return occupy_preparing();
        }
        family_expeditions_store().release(expedition);
        return false;
    }
    _family_expedition_target_index[family_expedition_target_key(
        quote.country_handle, quote.target_cell)] = expedition;
    push_family_expedition_due(expedition);
    note_family_expedition_audit_invalidation();
    append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
        cmd.effective_day, 1, "STARTED");
    return true;
}

bool NativeEconomyRuntime::apply_cancel_family_expedition(
        const Command &cmd, std::string &error) {
    int32_t expedition = -1;
    if (!family_expeditions_store().valid_handle(cmd.target_handle, expedition)) {
        error = "colonization_expedition_invalid"; return false;
    }
    if (family_expeditions_store().state[expedition] == EXPEDITION_RETURNING) return true;
    if (family_expeditions_store().state[expedition] == EXPEDITION_PREPARING) {
        abort_preparing_family_expedition(expedition, cmd.effective_day, 2,
            "CANCELLED");
        return true;
    }
    if (family_expeditions_store().state[expedition] == EXPEDITION_SETTLING &&
        family_expeditions_store().effect_transaction_id[expedition] != 0) {
        error = "colonization_settlement_already_committed"; return false;
    }
    const int64_t elapsed = std::max<int64_t>(0,
        cmd.effective_day - family_expeditions_store().departure_day[expedition]);
    const int64_t progressed = std::min<int64_t>(
        family_expeditions_store().route_cost[expedition], elapsed *
        std::max(1, family_expeditions_store().speed[expedition]));
    const int64_t return_days = (progressed +
        std::max(1, family_expeditions_store().speed[expedition]) - 1) /
        std::max(1, family_expeditions_store().speed[expedition]);
    family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
    release_family_expedition_reservations(expedition);
    note_family_expedition_audit_invalidation();
    family_expeditions_store().due_day.write_scalar(expedition, cmd.effective_day + return_days, market_mutation_sink());
    push_family_expedition_due(expedition);
    append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
        cmd.effective_day, 2, "CANCELLED_RETURNING");
    return true;
}

bool NativeEconomyRuntime::apply_settle_family_expedition(
        const Command &cmd, std::string &error) {
    int32_t expedition = -1;
    if (!family_expeditions_store().valid_handle(cmd.target_handle, expedition))
        return true; // idempotent replay after a successful release.
    if (family_expeditions_store().state[expedition] != EXPEDITION_SETTLING)
        return true;
    const int64_t owner = _country_runtime == nullptr ? 0 :
        country_reads().country_handle_for_cell(
            family_expeditions_store().target_cell[expedition]);
    bool claimed = cmd.i64_0 != 0;
    if (!claimed && _effect_runtime != nullptr)
        claimed = _effect_runtime->family_colonization_includes_claim(
            family_expeditions_store().effect_transaction_id[expedition]);
    if (owner != static_cast<int64_t>(
            family_expeditions_store().country_handle[expedition])) {
        // Under Country worker authority the paired CLAIM commits on the
        // worker's own boundary, so an unowned target here means the claim is
        // not visible yet — not that someone else took the cell. Yield the
        // slice with backpressure instead of condemning the expedition; the
        // command replays intact once the committed snapshot carries the claim.
        // Treating this window as TARGET_LOST left the cell claimed by the
        // player while the settlers were sent home, so the cell kept 0 people.
        if (owner == 0) {
            error = "country_economy_asset_territory_claim_pending";
            return false;
        }
        family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
        release_family_expedition_reservations(expedition);
        note_family_expedition_audit_invalidation();
        family_expeditions_store().due_day.write_scalar(expedition, _current_day.get() +
            std::max<int64_t>(1, (family_expeditions_store().route_cost[expedition] +
                family_expeditions_store().speed[expedition] - 1) /
                family_expeditions_store().speed[expedition]), market_mutation_sink());
        push_family_expedition_due(expedition);
        append_colonization_receipt(expedition, cmd.sequence,
            cmd.effective_day, _current_day.get(), 3, "TARGET_LOST_RETURNING");
        return true;
    }
    const int32_t destination = family_expeditions_store().target_cell[expedition];
    const uint64_t country_handle = family_expeditions_store().country_handle[expedition];
    if (!restore_family_expedition_payload(expedition, destination, error))
        return false;
    if (!settle_family_expedition_kit(expedition, destination, error))
        return false;
    if (cmd.i32_1 > 0)
        apply_family_colonization_population_reward(destination,
            family_expeditions_store().family_handle[expedition], cmd.i32_1);
    append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
        _current_day.get(), claimed ? 4 : 6, claimed ? "CLAIMED" : "RELOCATED");
    _family_expedition_target_index.erase(family_expedition_target_key(
        country_handle, destination));
    family_expeditions_store().release(expedition);
    return finalize_immediate_family_expedition_settlement(destination, error);
}

bool NativeEconomyRuntime::family_expedition_settle_inflight(
        uint64_t expedition_handle) const {
    auto is_settle = [&](const Command &cmd) {
        return cmd.opcode == COMMAND_SETTLE_FAMILY_EXPEDITION &&
               cmd.target_handle == expedition_handle;
    };
    for (const Command &cmd : _pending_commands)
        if (is_settle(cmd)) return true;
    for (const Command &cmd : _epoch_commands)
        if (is_settle(cmd)) return true;
    return false;
}

void NativeEconomyRuntime::recover_lost_family_settlement_commands() {
    if (_effect_runtime == nullptr) return;
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++expedition) {
        if (family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().state[expedition] != EXPEDITION_SETTLING)
            continue;
        const uint64_t handle = family_expeditions_store().handle_for_index(expedition);
        if (handle == 0 || family_expedition_settle_inflight(handle)) continue;
        const uint64_t settle_key =
            _effect_runtime->family_colonization_settle_idempotency_key(
                family_expeditions_store().stable_id[expedition],
                family_expeditions_store().generation[expedition],
                family_expeditions_store().idempotency_key[expedition]);
        const auto found = _effect_idempotency_requests.find(settle_key);
        if (found == _effect_idempotency_requests.end()) continue;
        const auto result = _effect_command_results.find(found->second);
        if (result == _effect_command_results.end() ||
            result->second.complete != 0) continue;
        Command command;
        command.opcode = COMMAND_SETTLE_FAMILY_EXPEDITION;
        command.effective_day = _current_day.get();
        command.sequence = static_cast<int64_t>(settle_key & 0x7fffffffffffffffULL);
        command.target_handle = handle;
        command.i32_0 = family_expeditions_store().target_cell[expedition];
        command.i32_1 = _effect_runtime->family_colonization_population_reward(
            family_expeditions_store().effect_transaction_id[expedition]);
        command.i64_0 = _effect_runtime->family_colonization_includes_claim(
            family_expeditions_store().effect_transaction_id[expedition]) ? 1 : 0;
        command.i64_1 = static_cast<int64_t>(
            family_expeditions_store().country_handle[expedition]);
        command.submit_order = _next_submit_order++;
        command.effect_request_id = found->second;
        command.effect_idempotency_key = settle_key;
        queue_family_settlement_command(command);
    }
}

bool NativeEconomyRuntime::stage_allows_in_epoch_family_settlement() const {
    if (!_epoch_active || _fatal) return false;
    switch (_stage) {
        case Stage::EPOCH_BEGIN:
        case Stage::TRADE_PLANNING:
        case Stage::BUILDING_PLAN:
        case Stage::TRADE_SETTLE:
        case Stage::LEDGER_APPLY:
            return true;
        default:
            return false;
    }
}

void NativeEconomyRuntime::queue_family_settlement_command(
        const Command &command) {
    if (_epoch_active && stage_allows_in_epoch_family_settlement())
        _epoch_commands.push_back(command);
    else
        _pending_commands.push_back(command);
}

bool NativeEconomyRuntime::process_due_family_expeditions(
        int64_t day, std::string &error) {
    const auto started = std::chrono::steady_clock::now();
    if (!settle_family_expedition_procurement_orphans(error)) return false;
    while (!_family_expedition_due_heap.empty()) {
        const auto top = _family_expedition_due_heap.front();
        if (top.first > day) break;
        std::pop_heap(_family_expedition_due_heap.begin(),
                      _family_expedition_due_heap.end(), due_heap_less);
        _family_expedition_due_heap.pop_back();
        const int32_t expedition = top.second;
        if (expedition < 0 || expedition >= static_cast<int32_t>(
                family_expeditions_store().active.size()) ||
            family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().due_day[expedition] != top.first) continue;
        if (family_expeditions_store().state[expedition] == EXPEDITION_PREPARING) {
            if (!advance_preparing_family_expedition(expedition, day, error))
                return false;
            continue;
        }
        if (family_expeditions_store().state[expedition] == EXPEDITION_SETTLING) {
            const int64_t transaction_id =
                family_expeditions_store().effect_transaction_id[expedition];
            int64_t resolved_transaction_id = 0;
            const int32_t status = _effect_runtime == nullptr ? 0 :
                _effect_runtime->family_colonization_transaction_status_pod(
                    transaction_id,
                    family_expeditions_store().stable_id[expedition],
                    family_expeditions_store().generation[expedition],
                    family_expeditions_store().idempotency_key[expedition],
                    &resolved_transaction_id);
            if (resolved_transaction_id != 0 &&
                resolved_transaction_id != transaction_id) {
                family_expeditions_store().effect_transaction_id.write_scalar(
                    expedition, resolved_transaction_id, market_mutation_sink());
            }
            if (status == EffectRuntime::REJECTED ||
                status == EffectRuntime::RESYNC_REQUIRED) {
                const int64_t consume_id = resolved_transaction_id != 0
                    ? resolved_transaction_id : transaction_id;
                if (_effect_runtime != nullptr && consume_id != 0)
                    _effect_runtime->consume_rejected_transaction_pod(
                        consume_id,
                        family_expeditions_store().stable_id[expedition]);
                family_expeditions_store().effect_transaction_id.write_scalar(expedition, 0, market_mutation_sink());
                family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
                release_family_expedition_reservations(expedition);
                family_expeditions_store().due_day.write_scalar(expedition, day +
                    std::max<int64_t>(1,
                        (family_expeditions_store().route_cost[expedition] +
                         family_expeditions_store().speed[expedition] - 1) /
                        family_expeditions_store().speed[expedition]), market_mutation_sink());
                push_family_expedition_due(expedition);
                append_colonization_receipt(expedition, 0,
                    family_expeditions_store().departure_day[expedition], day, 3,
                    "TARGET_LOST_RETURNING");
            } else if (status == 0 && _effect_runtime != nullptr) {
                // Builtin transaction is absent from EffectRuntime (for example
                // in an older save whose colonization tx ID collided with a
                // worker POD snapshot). Re-check ownership and re-enqueue
                // idempotently so the expedition cannot park in SETTLING forever.
                const int64_t owner = _country_runtime == nullptr ? 0 :
                    country_reads().country_handle_for_cell(
                        family_expeditions_store().target_cell[expedition]);
                if (_country_runtime == nullptr ||
                    (owner != 0 && owner != static_cast<int64_t>(
                        family_expeditions_store().country_handle[expedition]))) {
                    family_expeditions_store().effect_transaction_id.write_scalar(expedition, 0, market_mutation_sink());
                    family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
                    release_family_expedition_reservations(expedition);
                    family_expeditions_store().due_day.write_scalar(expedition, day +
                        std::max<int64_t>(1,
                            (family_expeditions_store().route_cost[expedition] +
                             family_expeditions_store().speed[expedition] - 1) /
                            family_expeditions_store().speed[expedition]), market_mutation_sink());
                    push_family_expedition_due(expedition);
                    append_colonization_receipt(expedition, 0,
                        family_expeditions_store().departure_day[expedition], day, 3,
                        "TARGET_LOST_RETURNING");
                } else {
                    const uint64_t handle =
                        family_expeditions_store().handle_for_index(expedition);
                    int64_t re_transaction_id = 0;
                    const bool claim_unowned = owner == 0;
                    const int32_t population_reward =
                        family_colonization_population_reward_amount(
                            family_expeditions_store().family_handle[expedition]);
                    if (!_effect_runtime->enqueue_family_colonization_pod(
                            family_expeditions_store().stable_id[expedition], day,
                            family_expeditions_store().stable_id[expedition],
                            family_expeditions_store().country_handle[expedition],
                            static_cast<uint32_t>(
                                family_expeditions_store().country_handle[expedition] >> 32U),
                            handle, family_expeditions_store().generation[expedition],
                            family_expeditions_store().target_cell[expedition],
                            family_expeditions_store().idempotency_key[expedition], error,
                            &re_transaction_id, claim_unowned, population_reward))
                        return false;
                    family_expeditions_store().effect_transaction_id.write_scalar(
                        expedition, re_transaction_id, market_mutation_sink());
                    family_expeditions_store().due_day.write_scalar(
                        expedition, day + 1, market_mutation_sink());
                    push_family_expedition_due(expedition);
                }
            } else {
                family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
                push_family_expedition_due(expedition);
            }
            continue;
        }
        if (family_expeditions_store().state[expedition] == EXPEDITION_RETURNING) {
            const int32_t source_cell =
                family_expeditions_store().source_cell[expedition];
            if (!restore_family_expedition_payload(expedition,
                    source_cell, error)) return false;
            if (!restore_family_expedition_cargo(expedition,
                    source_cell, false, error))
                return false;
            if (!repair_cell_merchant_and_rebuild(source_cell, error))
                return false;
            note_family_expedition_audit_invalidation();
            append_colonization_receipt(expedition, 0,
                family_expeditions_store().departure_day[expedition], day, 5, "RETURNED");
            _family_expedition_target_index.erase(family_expedition_target_key(
                family_expeditions_store().country_handle[expedition],
                family_expeditions_store().target_cell[expedition]));
            family_expeditions_store().release(expedition);
            continue;
        }
        if (family_expeditions_store().state[expedition] == EXPEDITION_OUTBOUND) {
            const int64_t owner = _country_runtime == nullptr ? 0 :
                country_reads().country_handle_for_cell(
                    family_expeditions_store().target_cell[expedition]);
            if (_country_runtime == nullptr ||
                (owner != 0 && owner != static_cast<int64_t>(
                    family_expeditions_store().country_handle[expedition]))) {
                family_expeditions_store().state.write_scalar(expedition, EXPEDITION_RETURNING, market_mutation_sink());
                release_family_expedition_reservations(expedition);
                family_expeditions_store().due_day.write_scalar(expedition, day +
                    std::max<int64_t>(1, (family_expeditions_store().route_cost[expedition] +
                        family_expeditions_store().speed[expedition] - 1) /
                        family_expeditions_store().speed[expedition]), market_mutation_sink());
                push_family_expedition_due(expedition);
                append_colonization_receipt(expedition, 0,
                    family_expeditions_store().departure_day[expedition], day, 3,
                    "TARGET_LOST_RETURNING");
                continue;
            }
            if (_effect_runtime == nullptr) {
                error = "colonization_effect_runtime_unavailable"; return false;
            }
            const uint64_t handle =
                family_expeditions_store().handle_for_index(expedition);
            int64_t transaction_id = 0;
            const bool claim_unowned = owner == 0;
            const int32_t population_reward =
                family_colonization_population_reward_amount(
                    family_expeditions_store().family_handle[expedition]);
            if (!_effect_runtime->enqueue_family_colonization_pod(
                    family_expeditions_store().stable_id[expedition], day,
                    family_expeditions_store().stable_id[expedition],
                    family_expeditions_store().country_handle[expedition],
                    static_cast<uint32_t>(
                        family_expeditions_store().country_handle[expedition] >> 32U),
                    handle, family_expeditions_store().generation[expedition],
                    family_expeditions_store().target_cell[expedition],
                    family_expeditions_store().idempotency_key[expedition], error,
                    &transaction_id, claim_unowned, population_reward)) return false;
            family_expeditions_store().effect_transaction_id.write_scalar(expedition, transaction_id, market_mutation_sink());
            family_expeditions_store().state.write_scalar(expedition, EXPEDITION_SETTLING, market_mutation_sink());
            family_expeditions_store().due_day.write_scalar(expedition, day + 1, market_mutation_sink());
            push_family_expedition_due(expedition);
        }
    }
    _colonization_cross_domain_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return true;
}

void NativeEconomyRuntime::rebuild_family_expedition_indices() {
    _family_expedition_target_index.clear();
    _family_expedition_due_heap.clear();
    _family_expedition_procurement_rejections.clear();
    _family_expedition_procurement_orphans.clear();
    for (int32_t i = 0; i < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++i) {
        if (family_expeditions_store().active[i] == 0) continue;
        _family_expedition_target_index[family_expedition_target_key(
            family_expeditions_store().country_handle[i],
            family_expeditions_store().target_cell[i])] = i;
        if (family_expeditions_store().state[i] != EXPEDITION_RETURNING) {
            const uint32_t begin = family_expeditions_store().payload_begin[i];
            const uint32_t end = std::min<uint32_t>(begin +
                family_expeditions_store().payload_count[i], static_cast<uint32_t>(
                    family_expedition_payloads().size()));
            reserve_family_expedition_payload_slots(i, begin, end, false);
        }
        if (family_expeditions_store().due_day[i] !=
                std::numeric_limits<int64_t>::max())
            push_family_expedition_due(i);
    }
}

} // namespace pk
