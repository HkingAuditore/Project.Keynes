#include "economy_runtime.h"

#include "country_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include "effect_runtime.h"

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

using namespace godot;
using namespace variant_helpers;

namespace {

constexpr int32_t COLONIZATION_EXPANSION_BUDGET = 8192;
constexpr int32_t COLONIZATION_SPEED = 1;
constexpr size_t COLONIZATION_QUOTE_CACHE_LIMIT = 4096;
constexpr size_t COLONIZATION_RECEIPT_LIMIT = 2048;
constexpr int32_t COLONIZATION_EFFECT_SOURCE = 0x434f4c4f; // COLO

uint64_t mul_mod_u64(uint64_t a, uint64_t b, uint64_t modulus) {
    if (modulus == 0) return 0;
    a %= modulus;
    uint64_t result = 0;
    while (b != 0) {
        if ((b & 1U) != 0)
            result = result >= modulus - a ? result - (modulus - a) : result + a;
        b >>= 1U;
        if (b != 0)
            a = a >= modulus - a ? a - (modulus - a) : a + a;
    }
    return result;
}

bool due_heap_less(const std::pair<int64_t, int32_t> &a,
                   const std::pair<int64_t, int32_t> &b) {
    return a.first > b.first || (a.first == b.first && a.second > b.second);
}

bool route_heap_less(const std::pair<int64_t, int32_t> &a,
                     const std::pair<int64_t, int32_t> &b) {
    return a.first > b.first || (a.first == b.first && a.second > b.second);
}

} // namespace

void NativeEconomyRuntime::FamilyExpeditionStore::clear() {
    active.clear(); generation.clear(); stable_id.clear();
    country_handle.clear(); family_handle.clear(); source_cell.clear();
    target_cell.clear(); departure_day.clear(); due_day.clear();
    route_cost.clear(); speed.clear(); state.clear(); population.clear();
    route_begin.clear(); route_count.clear(); payload_begin.clear();
    payload_count.clear(); cargo_begin.clear(); cargo_count.clear();
    kit_building_begin.clear(); kit_building_count.clear();
    effect_transaction_id.clear();
    idempotency_key.clear(); free_indices.clear(); active_count = 0;
}

int32_t NativeEconomyRuntime::FamilyExpeditionStore::allocate() {
    int32_t index = -1;
    if (!free_indices.empty()) {
        index = free_indices.back();
        free_indices.pop_back();
        generation[index] = std::max<uint32_t>(1, generation[index] + 1);
        cargo_begin[index] = 0; cargo_count[index] = 0;
        kit_building_begin[index] = 0; kit_building_count[index] = 0;
    } else {
        index = static_cast<int32_t>(active.size());
        active.push_back(0); generation.push_back(1); stable_id.push_back(0);
        country_handle.push_back(0); family_handle.push_back(0);
        source_cell.push_back(-1); target_cell.push_back(-1);
        departure_day.push_back(-1); due_day.push_back(-1);
        route_cost.push_back(0); speed.push_back(COLONIZATION_SPEED);
        state.push_back(EXPEDITION_OUTBOUND); population.push_back(0);
        route_begin.push_back(0); route_count.push_back(0);
        payload_begin.push_back(0); payload_count.push_back(0);
        cargo_begin.push_back(0); cargo_count.push_back(0);
        kit_building_begin.push_back(0); kit_building_count.push_back(0);
        effect_transaction_id.push_back(0); idempotency_key.push_back(0);
    }
    active[index] = 1;
    ++active_count;
    return index;
}

void NativeEconomyRuntime::FamilyExpeditionStore::release(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0) return;
    active[index] = 0;
    country_handle[index] = 0; family_handle[index] = 0;
    population[index] = 0; effect_transaction_id[index] = 0;
    free_indices.push_back(index);
    --active_count;
}

uint64_t NativeEconomyRuntime::FamilyExpeditionStore::handle_for_index(
        int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0) return 0;
    return (static_cast<uint64_t>(generation[index]) << 32U) |
        static_cast<uint32_t>(index);
}

bool NativeEconomyRuntime::FamilyExpeditionStore::valid_handle(
        uint64_t handle, int32_t &index_out) const {
    const int32_t index = static_cast<int32_t>(handle & 0xffffffffULL);
    const uint32_t expected = static_cast<uint32_t>(handle >> 32U);
    if (index < 0 || index >= static_cast<int32_t>(active.size()) ||
        active[index] == 0 || generation[index] != expected) return false;
    index_out = index;
    return true;
}

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
    if (!_families.valid_handle(family_handle, family) || cell < 0 ||
        cell >= _cell_count) return 0;
    int64_t total = 0;
    const bool csr = _family_member_offsets.size() == _families.active.size() + 1;
    const int32_t begin = csr ? _family_member_offsets[family] : 0;
    const int32_t end = csr ? _family_member_offsets[family + 1]
        : static_cast<int32_t>(_family_memberships.size());
    for (int32_t p = begin; p < end; ++p) {
        const FamilyMembershipEdge &edge = _family_memberships[
            csr ? _family_member_edge_indices[p] : p];
        if (edge.family_handle != family_handle) continue;
        int32_t slot = -1;
        if (_population.valid_handle(edge.cohort_handle, slot) &&
            _population.page_cell[slot / COHORT_PAGE_SIZE] == cell)
            total += std::max<int64_t>(0, edge.people);
    }
    return total;
}

bool NativeEconomyRuntime::colonization_target_owner_allowed(
        uint64_t country_handle, int32_t cell) const {
    if (_country_runtime == nullptr || country_handle == 0 || cell < 0 ||
        cell >= _cell_count) return false;
    const int64_t owner = _country_runtime->country_handle_for_cell(cell);
    return owner == 0 || owner == static_cast<int64_t>(country_handle);
}

bool NativeEconomyRuntime::colonization_destination_family_allowed(
        uint64_t family_handle, int32_t cell) const {
    if (family_handle == 0 || cell < 0 || cell >= _cell_count) return false;
    if (family_population_in_cell(family_handle, cell) > 0) return true;
    if (_family_cell_offsets.size() != static_cast<size_t>(_cell_count + 1))
        return true;
    const int32_t count = _family_cell_offsets[static_cast<size_t>(cell) + 1] -
        _family_cell_offsets[static_cast<size_t>(cell)];
    return count < _family_max_per_cell;
}

bool NativeEconomyRuntime::plan_family_colonization_route(
        uint64_t country_handle, int32_t source_cell, int32_t target_cell,
        const uint8_t *visible, int32_t visible_count,
        std::vector<int32_t> &route, std::vector<int32_t> &cumulative,
        int32_t &cost, std::string &error) {
    route.clear(); cumulative.clear(); cost = 0;
    if (!_trade_topology.ready ||
        _trade_topology.neighbors.size() != static_cast<size_t>(_cell_count) * 6 ||
        _trade_topology.passable.size() != static_cast<size_t>(_cell_count) ||
        _trade_topology.enter_cost.size() != static_cast<size_t>(_cell_count)) {
        error = "colonization_topology_unavailable";
        return false;
    }
    if (country_handle == 0 || source_cell < 0 || source_cell >= _cell_count ||
        target_cell < 0 || target_cell >= _cell_count || source_cell == target_cell ||
        visible == nullptr || visible_count != _cell_count) {
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
        _country_runtime->country_handle_for_cell(source_cell) !=
            static_cast<int64_t>(country_handle) ||
        !colonization_target_owner_allowed(country_handle, target_cell)) {
        error = "colonization_route_territory_invalid";
        return false;
    }
    const size_t cells = static_cast<size_t>(_cell_count);
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
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(cell) * 6 + direction];
            if (neighbor < 0 || visible[neighbor] == 0 ||
                _trade_topology.passable[neighbor] == 0) continue;
            const int64_t owner = _country_runtime->country_handle_for_cell(neighbor);
            if (owner != 0 && owner != static_cast<int64_t>(country_handle)) continue;
            // Reverse Dijkstra: source->cell enters `cell`, so the reverse edge
            // carries cell.enter_cost rather than neighbor.enter_cost.
            const int64_t next = distance + std::max(1,
                trade_edge_cost(neighbor, cell));
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
        cursor = _colonization_parent[cursor];
        if (cursor < 0 || route.size() > static_cast<size_t>(_cell_count)) {
            error = "colonization_route_parent_cycle";
            return false;
        }
        running += std::max(1, trade_edge_cost(route.back(), cursor));
        route.push_back(cursor);
        cumulative.push_back(static_cast<int32_t>(std::min<int64_t>(
            running, std::numeric_limits<int32_t>::max())));
    }
    cost = cumulative.back();
    return true;
}

void NativeEconomyRuntime::fill_colonization_query_flags(Dictionary &out) const {
    const bool boundary_busy = _epoch_active || _save.active || _restore.active;
    out["busy"] = boundary_busy;
    out["fatal"] = _fatal;
    out["committed"] = !_epoch_active && !_fatal && !_save.active && !_restore.active;
    out["nonbinding"] = _epoch_active;
    out["snapshot_day"] = _current_day;
}

Dictionary NativeEconomyRuntime::family_colonization_quotes(
        int64_t country_handle_value, int32_t target_cell,
        int64_t family_filter_value, int32_t source_filter, int32_t offset,
        int32_t limit, const uint8_t *visible, int32_t visible_count,
        uint64_t vision_revision) {
    const auto started = std::chrono::steady_clock::now();
    Dictionary out;
    const uint64_t country_handle = static_cast<uint64_t>(country_handle_value);
    const uint64_t family_filter = static_cast<uint64_t>(family_filter_value);
    // Quotes are a nonbinding UI preview. Frozen cycles still expose the current
    // live/frozen membership so the planner is never blank; start/cancel queue
    // into pending when the epoch is open.
    if (!_bootstrapped || _fatal || _restore.active || _country_runtime == nullptr ||
        !_country_runtime->valid_handle(country_handle_value)) {
        out["ok"] = false;
        out["code"] = _restore.active ? "economy_busy_retry" :
            _fatal ? "economy_paused" :
            !_bootstrapped ? "economy_not_available" :
            "colonization_country_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    std::vector<int32_t> ignored_route, ignored_costs;
    int32_t ignored_total = 0;
    std::string route_error;
    // This validates target/topology before the one reverse search below.
    if (target_cell < 0 || target_cell >= _cell_count) {
        out["ok"] = false;
        out["code"] = "colonization_target_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    if (visible == nullptr || visible_count != _cell_count) {
        out["ok"] = false;
        out["code"] = "colonization_visibility_unavailable";
        fill_colonization_query_flags(out);
        return out;
    }
    if (visible[target_cell] == 0) {
        out["ok"] = false;
        out["code"] = "colonization_target_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    if (_trade_topology.passable.size() != static_cast<size_t>(_cell_count) ||
        !_trade_topology.ready) {
        out["ok"] = false;
        out["code"] = "colonization_topology_not_ready";
        fill_colonization_query_flags(out);
        return out;
    }
    if (!colonization_target_owner_allowed(country_handle, target_cell)) {
        out["ok"] = false;
        out["code"] = "colonization_target_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    // Frozen cycles may leave the live passable LUT mid-rebuild while quotes
    // are only a nonbinding preview. Keep the list readable; start still
    // revalidates the committed route.
    if (_trade_topology.passable[target_cell] == 0 && !_epoch_active) {
        out["ok"] = false;
        out["code"] = "colonization_target_invalid";
        fill_colonization_query_flags(out);
        return out;
    }
    NativeCountryRuntime::EconomySnapshot country_snapshot;
    if (!_country_runtime->copy_economy_snapshot(country_snapshot)) {
        out["ok"] = false; out["code"] = "colonization_country_snapshot_unavailable";
        fill_colonization_query_flags(out);
        return out;
    }
    const int32_t country_slot = _country_runtime->country_slot_for_cell(
        source_filter >= 0 ? source_filter : target_cell);
    (void)country_slot;
    const uint64_t vision_hash = trace_hash_mix(
        colonization_visibility_hash(visible, visible_count), vision_revision);

    // Run one bounded reverse Dijkstra and retain all reached local source
    // cells. This is the same scratch as single-route validation and never
    // clears a map-sized array.
    if (_colonization_distance.size() != static_cast<size_t>(_cell_count)) {
        _colonization_distance.resize(_cell_count);
        _colonization_distance_stamp.assign(_cell_count, 0);
        _colonization_parent.resize(_cell_count);
        _colonization_parent_stamp.assign(_cell_count, 0);
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
    std::vector<int32_t> reached_sources;
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
        const int64_t owner = _country_runtime->country_handle_for_cell(cell);
        if (owner == country_handle_value && visible[cell] != 0 &&
            (source_filter < 0 || source_filter == cell))
            reached_sources.push_back(cell);
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(cell) * 6 + direction];
            if (neighbor < 0 || visible[neighbor] == 0 ||
                _trade_topology.passable[neighbor] == 0) continue;
            const int64_t neighbor_owner =
                _country_runtime->country_handle_for_cell(neighbor);
            if (neighbor_owner != 0 && neighbor_owner != country_handle_value)
                continue;
            const int64_t next = distance + std::max(1,
                trade_edge_cost(neighbor, cell));
            const bool unseen = _colonization_distance_stamp[neighbor] != stamp;
            const bool shorter = !unseen && next < _colonization_distance[neighbor];
            const bool tie = !unseen && next == _colonization_distance[neighbor] &&
                cell < _colonization_parent[neighbor];
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
    std::sort(reached_sources.begin(), reached_sources.end());
    reached_sources.erase(std::unique(reached_sources.begin(),
                                      reached_sources.end()), reached_sources.end());
    uint64_t dest_kit_identity = 1;
    if (!reached_sources.empty()) {
        ColonizationKitPlan dest_preview;
        plan_colonization_kit(reached_sources.front(), target_cell,
            COLONIZATION_KIT_MIN_OWNER_SLOTS, 1, false, dest_preview);
        dest_kit_identity = dest_preview.dest_identity;
    }
    struct Candidate { uint64_t family; int32_t source; int64_t maximum;
        int32_t cost; int32_t days; uint64_t token; };
    std::vector<Candidate> candidates;
    for (const int32_t source : reached_sources) {
        if (_family_cell_offsets.size() != static_cast<size_t>(_cell_count + 1))
            continue;
        for (int32_t p = _family_cell_offsets[source];
             p < _family_cell_offsets[source + 1]; ++p) {
            const int32_t family = _family_cell_indices[p];
            const uint64_t family_handle = _families.handle_for_index(family);
            if (family_handle == 0 || source == target_cell ||
                (family_filter != 0 && family_handle != family_filter) ||
                !colonization_destination_family_allowed(family_handle,
                    target_cell)) continue;
            const int64_t branch_population = family_population_in_cell(
                family_handle, source);
            if (branch_population <= 1) continue;
            std::vector<int32_t> route;
            std::vector<int32_t> cumulative;
            int32_t cursor = source;
            int64_t running = 0;
            route.push_back(cursor); cumulative.push_back(0);
            uint64_t route_hash = 1469598103934665603ULL;
            route_hash = trace_hash_mix(route_hash, static_cast<uint32_t>(cursor));
            route_hash = trace_hash_mix(route_hash, 0);
            while (cursor != target_cell) {
                if (_colonization_parent_stamp[cursor] != stamp) {
                    route.clear(); break;
                }
                cursor = _colonization_parent[cursor];
                running += std::max(1, trade_edge_cost(route.back(), cursor));
                route.push_back(cursor);
                cumulative.push_back(static_cast<int32_t>(running));
                route_hash = trace_hash_mix(route_hash,
                    static_cast<uint32_t>(cursor));
                route_hash = trace_hash_mix(route_hash,
                    static_cast<uint32_t>(running));
            }
            if (route.empty()) continue;
            uint64_t token = 1469598103934665603ULL;
            for (const uint64_t value : {country_handle, family_handle,
                    static_cast<uint64_t>(static_cast<uint32_t>(source)),
                    static_cast<uint64_t>(static_cast<uint32_t>(target_cell)),
                    _trade_topology.topology_generation, country_snapshot.generation,
                    vision_hash, route_hash, dest_kit_identity})
                token = trace_hash_mix(token, value);
            token &= 0x7fffffffffffffffULL;
            if (token == 0) token = 1;
            if (_colonization_quote_cache.size() >= COLONIZATION_QUOTE_CACHE_LIMIT &&
                !has_pending_family_expedition_player_command()) {
                _colonization_quote_cache.clear();
                _colonization_quote_index.clear();
                _colonization_quote_route_cells.clear();
                _colonization_quote_route_costs.clear();
            }
            ColonizationQuoteCacheEntry entry;
            entry.token = token; entry.country_handle = country_handle;
            entry.family_handle = family_handle; entry.source_cell = source;
            entry.target_cell = target_cell;
            entry.maximum_population = branch_population - 1;
            entry.route_cost = static_cast<int32_t>(running);
            entry.travel_days = std::max(1, (entry.route_cost +
                COLONIZATION_SPEED - 1) / COLONIZATION_SPEED);
            entry.topology_generation = _trade_topology.topology_generation;
            entry.country_generation = country_snapshot.generation;
            entry.vision_hash = vision_hash; entry.route_hash = route_hash;
            entry.dest_kit_identity = dest_kit_identity;
            entry.route_begin = static_cast<uint32_t>(
                _colonization_quote_route_cells.size());
            entry.route_count = static_cast<uint32_t>(route.size());
            _colonization_quote_route_cells.insert(
                _colonization_quote_route_cells.end(), route.begin(), route.end());
            _colonization_quote_route_costs.insert(
                _colonization_quote_route_costs.end(), cumulative.begin(), cumulative.end());
            const auto existing = _colonization_quote_index.find(token);
            if (existing == _colonization_quote_index.end()) {
                _colonization_quote_index[token] = static_cast<int32_t>(
                    _colonization_quote_cache.size());
                _colonization_quote_cache.push_back(entry);
            } else {
                _colonization_quote_cache[existing->second] = entry;
            }
            candidates.push_back({family_handle, source,
                branch_population - 1, entry.route_cost, entry.travel_days, token});
        }
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a,
            const Candidate &b) {
        return std::tie(a.cost, a.source, a.family) <
               std::tie(b.cost, b.source, b.family);
    });
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min<int32_t>(candidates.size(), offset + limit);
    PackedInt64Array families, maximums, tokens;
    PackedInt32Array sources, costs, days, surname_disambiguators;
    PackedStringArray surnames;
    for (int32_t i = offset; i < end; ++i) {
        families.push_back(static_cast<int64_t>(candidates[i].family));
        int32_t family_index = -1;
        if (_families.valid_handle(candidates[i].family, family_index)) {
            const int32_t surname_id = _families.surname_id[family_index];
            surnames.push_back(surname_id >= 0 && surname_id <
                    static_cast<int32_t>(_family_surname_text.size())
                ? from_utf8(_family_surname_text[surname_id]) : String());
            surname_disambiguators.push_back(
                _families.surname_disambiguator[family_index]);
        } else {
            surnames.push_back(String()); surname_disambiguators.push_back(0);
        }
        sources.push_back(candidates[i].source);
        maximums.push_back(candidates[i].maximum);
        costs.push_back(candidates[i].cost); days.push_back(candidates[i].days);
        tokens.push_back(static_cast<int64_t>(candidates[i].token));
    }
    out["ok"] = true; out["target_cell"] = target_cell;
    fill_colonization_query_flags(out);
    out["kind"] = _country_runtime->country_handle_for_cell(target_cell) == 0
        ? String("colonize") : String("relocate");
    out["family_handles"] = families; out["source_cells"] = sources;
    out["surnames"] = surnames;
    out["surname_disambiguators"] = surname_disambiguators;
    out["maximum_populations"] = maximums; out["route_costs"] = costs;
    out["travel_days"] = days; out["quote_tokens"] = tokens;
    out["offset"] = offset; out["limit"] = limit;
    out["total"] = static_cast<int32_t>(candidates.size());
    out["has_more"] = end < static_cast<int32_t>(candidates.size());
    out["expansion_budget"] = COLONIZATION_EXPANSION_BUDGET;
    out["expansions"] = expansions;
    _colonization_route_query_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out["elapsed_ms"] = _colonization_route_query_ms;
    return out;
}

Dictionary NativeEconomyRuntime::family_colonization_quote_detail(
        int64_t quote_token_value, int64_t population) const {
    Dictionary out;
    fill_colonization_query_flags(out);
    if (!_bootstrapped || _fatal || _restore.active) {
        out["ok"] = false;
        out["code"] = _restore.active ? "economy_busy_retry" :
            _fatal ? "economy_paused" : "economy_not_available";
        return out;
    }
    const uint64_t token = static_cast<uint64_t>(quote_token_value);
    const auto found = _colonization_quote_index.find(token);
    if (found == _colonization_quote_index.end()) {
        out["ok"] = false; out["code"] = "colonization_quote_expired";
        return out;
    }
    const ColonizationQuoteCacheEntry &quote =
        _colonization_quote_cache[found->second];
    if (static_cast<size_t>(quote.route_begin) + quote.route_count >
            _colonization_quote_route_cells.size()) {
        out["ok"] = false; out["code"] = "colonization_quote_corrupt";
        return out;
    }
    PackedInt32Array route, cumulative;
    for (uint32_t i = 0; i < quote.route_count; ++i) {
        route.push_back(_colonization_quote_route_cells[quote.route_begin + i]);
        cumulative.push_back(_colonization_quote_route_costs[quote.route_begin + i]);
    }
    out["ok"] = true; out["quote_token"] = quote_token_value;
    out["country_handle"] = static_cast<int64_t>(quote.country_handle);
    out["family_handle"] = static_cast<int64_t>(quote.family_handle);
    out["source_cell"] = quote.source_cell; out["target_cell"] = quote.target_cell;
    out["kind"] = _country_runtime != nullptr &&
        _country_runtime->country_handle_for_cell(quote.target_cell) == 0
        ? String("colonize") : String("relocate");
    out["maximum_population"] = quote.maximum_population;
    out["route_cost"] = quote.route_cost; out["travel_days"] = quote.travel_days;
    out["route_cells"] = route; out["cumulative_costs"] = cumulative;
    std::vector<int64_t> profession_totals(_profession_ids.size(), 0);
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        if (edge.family_handle != quote.family_handle) continue;
        int32_t cohort = -1;
        if (!_population.valid_handle(edge.cohort_handle, cohort) ||
            _population.page_cell[cohort / COHORT_PAGE_SIZE] !=
                quote.source_cell) continue;
        const int32_t signature = _population.signature_id[cohort];
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size()))
            continue;
        profession_totals[_signatures[signature].profession_id] += edge.people;
    }
    PackedInt32Array profession_ids;
    PackedInt64Array profession_populations;
    for (int32_t profession = 0; profession < static_cast<int32_t>(
            profession_totals.size()); ++profession) {
        if (profession_totals[profession] <= 0) continue;
        profession_ids.push_back(profession);
        profession_populations.push_back(profession_totals[profession]);
    }
    out["profession_ids"] = profession_ids;
    out["profession_populations"] = profession_populations;
    ColonizationKitPlan kit;
    const int64_t kit_population = population > 0
        ? std::min(population, quote.maximum_population)
        : quote.maximum_population;
    plan_colonization_kit(quote.source_cell, quote.target_cell, kit_population,
        quote.travel_days, false, kit);
    PackedInt32Array kit_building_ids;
    PackedInt64Array kit_building_counts;
    for (const FamilyExpeditionKitBuilding &row : kit.buildings) {
        kit_building_ids.push_back(row.type_id);
        kit_building_counts.push_back(row.count);
    }
    PackedInt32Array kit_missing_goods;
    for (const int32_t good : kit.missing_good_ids)
        kit_missing_goods.push_back(good);
    out["kit_building_ids"] = kit_building_ids;
    out["kit_building_counts"] = kit_building_counts;
    out["kit_supported_population"] = kit.supported_population;
    out["kit_food_coverage_q16"] = kit.food_coverage_q16;
    out["kit_missing_goods"] = kit_missing_goods;
    out["kit_partial"] = kit.kit_partial != 0;
    out["kit_place_buildings"] = kit.place_buildings != 0;
    return out;
}

Dictionary NativeEconomyRuntime::submit_family_colonization_start(
        int64_t country_handle_value, int64_t family_handle_value,
        int32_t source_cell, int32_t target_cell, int64_t population,
        int64_t quote_token_value, int64_t effective_day, int64_t sequence,
        const uint8_t *visible, int32_t visible_count, uint64_t vision_revision) {
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
    NativeCountryRuntime::EconomySnapshot snapshot;
    if (_country_runtime == nullptr ||
        !_country_runtime->copy_economy_snapshot(snapshot)) {
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
    if (family_population_in_cell(static_cast<uint64_t>(family_handle_value),
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
    command.submit_order = _next_submit_order++;
    if (_epoch_active) {
        _pending_commands.push_back(command);
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
    out["ok"] = true; out["code"] = "colonization_started";
    out["message"] = "Family expedition started";
    out["effective_day"] = effective_day; out["sequence"] = sequence;
    out["expedition_handle"] = static_cast<int64_t>(
        _family_expeditions.handle_for_index(expedition));
    out["arrival_day"] = _family_expeditions.due_day[expedition];
    return out;
}

Dictionary NativeEconomyRuntime::submit_family_colonization_cancel(
        int64_t country_handle_value, int64_t expedition_handle_value,
        int64_t effective_day, int64_t sequence) {
    Dictionary out;
    if (_fatal || _save.active || _restore.active) {
        out["ok"] = false;
        out["code"] = _fatal ? "economy_paused" : "economy_not_available";
        return out;
    }
    int32_t expedition = -1;
    if (!_family_expeditions.valid_handle(
            static_cast<uint64_t>(expedition_handle_value), expedition) ||
        _family_expeditions.country_handle[expedition] !=
            static_cast<uint64_t>(country_handle_value)) {
        out["ok"] = false; out["code"] = "colonization_expedition_invalid";
        return out;
    }
    if (pending_family_expedition_cancel_taken(
            static_cast<uint64_t>(expedition_handle_value))) {
        out["ok"] = false; out["code"] = "colonization_expedition_invalid";
        return out;
    }
    Command command;
    command.opcode = COMMAND_CANCEL_FAMILY_EXPEDITION;
    command.effective_day = effective_day; command.sequence = sequence;
    command.target_handle = static_cast<uint64_t>(expedition_handle_value);
    command.submit_order = _next_submit_order++;
    if (_epoch_active) {
        _pending_commands.push_back(command);
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
    out["ok"] = true; out["code"] = "colonization_cancelled_returning";
    out["message"] = "Family expedition is returning";
    out["effective_day"] = effective_day; out["sequence"] = sequence;
    return out;
}

void NativeEconomyRuntime::push_family_expedition_due(int32_t expedition) {
    _family_expedition_due_heap.emplace_back(
        _family_expeditions.due_day[expedition], expedition);
    std::push_heap(_family_expedition_due_heap.begin(),
                   _family_expedition_due_heap.end(), due_heap_less);
}

void NativeEconomyRuntime::append_colonization_receipt(
        int32_t expedition, int64_t sequence, int64_t effective_day,
        int64_t settled_day, uint8_t kind, const char *code) {
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            _family_expeditions.active.size())) return;
    append_colonization_command_receipt(
        _family_expeditions.country_handle[expedition],
        _family_expeditions.handle_for_index(expedition),
        _family_expeditions.target_cell[expedition],
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
    return false;
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
            if (_families.valid_handle(cmd.target_handle, family))
                country = _country_runtime == nullptr ? 0 :
                    static_cast<uint64_t>(_country_runtime->country_handle_for_cell(
                        _families.home_cell[family]));
        }
    } else {
        int32_t expedition = -1;
        if (_family_expeditions.valid_handle(cmd.target_handle, expedition)) {
            country = _family_expeditions.country_handle[expedition];
            target_cell = _family_expeditions.target_cell[expedition];
        }
    }
    append_colonization_command_receipt(country, cmd.target_handle, target_cell,
        cmd.sequence, cmd.effective_day, _current_day, 7, error.c_str());
    ++_rejected_commands;
    error.clear();
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
    if (!colonization_destination_family_allowed(quote.family_handle,
            quote.target_cell)) {
        error = "colonization_family_cell_capacity"; return false;
    }
    ColonizationKitPlan kit;
    plan_colonization_kit(quote.source_cell, quote.target_cell, cmd.i64_0,
        quote.travel_days, _epoch_active, kit);
    if (!_epoch_active && kit.dest_identity != quote.dest_kit_identity) {
        error = "colonization_kit_requote_required"; return false;
    }
    const int32_t expedition = _family_expeditions.allocate();
    _family_expeditions.stable_id[expedition] =
        _next_family_expedition_stable_id++;
    _family_expeditions.country_handle[expedition] = quote.country_handle;
    _family_expeditions.family_handle[expedition] = quote.family_handle;
    _family_expeditions.source_cell[expedition] = quote.source_cell;
    _family_expeditions.target_cell[expedition] = quote.target_cell;
    _family_expeditions.departure_day[expedition] = cmd.effective_day;
    _family_expeditions.route_cost[expedition] = quote.route_cost;
    _family_expeditions.speed[expedition] = COLONIZATION_SPEED;
    _family_expeditions.due_day[expedition] = cmd.effective_day +
        std::max(1, quote.travel_days);
    _family_expeditions.state[expedition] = EXPEDITION_OUTBOUND;
    _family_expeditions.population[expedition] = cmd.i64_0;
    _family_expeditions.route_begin[expedition] = static_cast<uint32_t>(
        _family_expedition_route_cells.size());
    _family_expeditions.route_count[expedition] = quote.route_count;
    for (uint32_t i = 0; i < quote.route_count; ++i) {
        _family_expedition_route_cells.push_back(
            _colonization_quote_route_cells[quote.route_begin + i]);
        _family_expedition_route_costs.push_back(
            _colonization_quote_route_costs[quote.route_begin + i]);
    }
    uint64_t idempotency_key = 1469598103934665603ULL;
    idempotency_key = trace_hash_mix(idempotency_key,
        static_cast<uint64_t>(_family_expeditions.stable_id[expedition]));
    idempotency_key = trace_hash_mix(idempotency_key,
        static_cast<uint64_t>(cmd.sequence));
    _family_expeditions.idempotency_key[expedition] =
        idempotency_key == 0 ? 1 : idempotency_key;
    if (!extract_family_expedition_cargo(expedition, kit, error)) {
        _family_expeditions.release(expedition);
        if (error.empty()) error = "colonization_kit_materials_short";
        return false;
    }
    if (!extract_family_expedition_payload(expedition, cmd.i64_0, error)) {
        std::string ignored;
        restore_family_expedition_cargo(expedition, quote.source_cell, false,
            ignored);
        _family_expeditions.release(expedition);
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

void NativeEconomyRuntime::unwind_family_expedition_payload_extract(
        int32_t expedition) {
    if (expedition < 0 ||
        expedition >= static_cast<int32_t>(_family_expeditions.active.size()) ||
        _family_expeditions.active[expedition] == 0) return;
    const uint64_t family_handle = _family_expeditions.family_handle[expedition];
    const uint64_t owner = _family_expeditions.handle_for_index(expedition);
    const uint32_t begin = _family_expeditions.payload_begin[expedition];
    uint32_t count = _family_expeditions.payload_count[expedition];
    if (begin > _family_expedition_payloads.size()) return;
    if (count == 0 && _family_expedition_payloads.size() > begin)
        count = static_cast<uint32_t>(_family_expedition_payloads.size() - begin);
    const uint32_t end = std::min<uint32_t>(
        begin + count, static_cast<uint32_t>(_family_expedition_payloads.size()));
    uint32_t person_begin = static_cast<uint32_t>(
        _family_expedition_person_handles.size());
    for (uint32_t p = begin; p < end; ++p) {
        FamilyExpeditionPayload &payload = _family_expedition_payloads[p];
        _population.release_reserved_slot(payload.reserved_slot, owner);
        payload.reserved_slot = -1;
        person_begin = std::min(person_begin, payload.person_begin);
        int32_t slot = -1;
        if (_population.valid_handle(payload.source_cohort_handle, slot)) {
            audit_touch_population_lane(slot);
            touch_accounting_slot(slot);
            _population.population[slot] += payload.people;
            _population.funds[slot] += payload.funds;
            _population.epoch_income[slot] += payload.epoch_income;
            _population.epoch_expense[slot] += payload.epoch_expense;
            _population.epoch_in_kind_income[slot] += payload.epoch_in_kind_income;
            _population.income_ema[slot] += payload.income_ema;
            _population.epoch_tax_paid[slot] += payload.epoch_tax_paid;
            _population.epoch_subsidy_received[slot] +=
                payload.epoch_subsidy_received;
            _population.income_baseline_ema[slot] += payload.income_baseline_ema;
            _population.demography_residual[slot] += payload.demography_residual;
        }
        auto membership = std::find_if(_family_memberships.begin(),
            _family_memberships.end(), [&](const FamilyMembershipEdge &edge) {
                return edge.family_handle == family_handle &&
                    edge.cohort_handle == payload.source_cohort_handle;
            });
        if (membership == _family_memberships.end()) {
            _family_memberships.push_back({family_handle,
                payload.source_cohort_handle, payload.people, payload.cash_claim,
                payload.people, payload.funds, payload.owner_employed,
                payload.employee_employed});
        } else {
            membership->people += payload.people;
            membership->cash_claim += payload.cash_claim;
            membership->owner_employed += payload.owner_employed;
            membership->employee_employed += payload.employee_employed;
            membership->population_basis += payload.people;
            membership->funds_basis += payload.cash_claim;
        }
        const uint32_t person_end = std::min<uint32_t>(
            payload.person_begin + payload.person_count,
            static_cast<uint32_t>(_family_expedition_person_handles.size()));
        for (uint32_t i = payload.person_begin; i < person_end; ++i) {
            int32_t person = -1;
            if (_persons.valid_handle(_family_expedition_person_handles[i],
                    person))
                _persons.cohort_handle[person] = payload.source_cohort_handle;
        }
    }
    if (end > begin)
        _family_expedition_payloads.resize(begin);
    if (person_begin < _family_expedition_person_handles.size())
        _family_expedition_person_handles.resize(person_begin);
    _family_expeditions.payload_count[expedition] = 0;
    _family_expeditions.population[expedition] = 0;
    _family_indices_dirty = true;
    _person_indices_dirty = true;
}

bool NativeEconomyRuntime::extract_family_expedition_payload(
        int32_t expedition, int64_t requested, std::string &error) {
    const auto started = std::chrono::steady_clock::now();
    const uint64_t family_handle = _family_expeditions.family_handle[expedition];
    const int32_t source_cell = _family_expeditions.source_cell[expedition];
    struct Candidate { int32_t edge; int32_t slot; int64_t people;
        bool unemployed; uint64_t stable; int64_t selected = 0; };
    std::vector<Candidate> candidates;
    int32_t family = -1;
    if (!_families.valid_handle(family_handle, family)) {
        error = "colonization_family_invalid"; return false;
    }
    const bool csr = _family_member_offsets.size() == _families.active.size() + 1;
    const int32_t begin = csr ? _family_member_offsets[family] : 0;
    const int32_t end = csr ? _family_member_offsets[family + 1]
        : static_cast<int32_t>(_family_memberships.size());
    for (int32_t p = begin; p < end; ++p) {
        const int32_t edge_index = csr ? _family_member_edge_indices[p] : p;
        const FamilyMembershipEdge &edge = _family_memberships[edge_index];
        int32_t slot = -1;
        if (edge.family_handle != family_handle || edge.people <= 0 ||
            !_population.valid_handle(edge.cohort_handle, slot) ||
            _population.page_cell[slot / COHORT_PAGE_SIZE] != source_cell) continue;
        const int32_t signature = static_cast<int32_t>(
            _population.signature_id[slot]);
        candidates.push_back({edge_index, slot, edge.people,
            _signatures[signature].profession_id == _unemployed_profession_id,
            edge.cohort_handle, 0});
    }
    std::sort(candidates.begin(), candidates.end(), [](const Candidate &a,
            const Candidate &b) {
        return std::tuple<bool, uint64_t, int32_t>(
                   !a.unemployed, a.stable, a.edge) <
               std::tuple<bool, uint64_t, int32_t>(
                   !b.unemployed, b.stable, b.edge);
    });
    int64_t remaining = requested;
    for (Candidate &candidate : candidates) {
        if (!candidate.unemployed || remaining <= 0) continue;
        candidate.selected = std::min(candidate.people, remaining);
        remaining -= candidate.selected;
    }
    if (remaining > 0) {
        int64_t pool = 0;
        for (const Candidate &candidate : candidates)
            if (!candidate.unemployed) pool += candidate.people;
        if (pool < remaining) { error = "colonization_population_insufficient"; return false; }
        struct Remainder { int32_t candidate; int64_t remainder; int32_t profession;
            int32_t ethnicity; uint64_t stable; };
        std::vector<Remainder> remainders;
        int64_t allocated = 0;
        for (int32_t i = 0; i < static_cast<int32_t>(candidates.size()); ++i) {
            Candidate &candidate = candidates[i];
            if (candidate.unemployed) continue;
            candidate.selected = mul_div_sat(remaining, candidate.people,
                pool, _saturation_count);
            allocated += candidate.selected;
            const int32_t signature = static_cast<int32_t>(
                _population.signature_id[candidate.slot]);
            remainders.push_back({i, static_cast<int64_t>(mul_mod_u64(
                    static_cast<uint64_t>(remaining),
                    static_cast<uint64_t>(candidate.people),
                    static_cast<uint64_t>(pool))),
                _signatures[signature].profession_id,
                _signatures[signature].ethnicity_id, candidate.stable});
        }
        std::sort(remainders.begin(), remainders.end(), [](const Remainder &a,
                const Remainder &b) {
            if (a.remainder != b.remainder) return a.remainder > b.remainder;
            return std::tie(a.profession, a.ethnicity, a.stable) <
                   std::tie(b.profession, b.ethnicity, b.stable);
        });
        for (int64_t i = allocated; i < remaining; ++i)
            ++candidates[remainders[static_cast<size_t>(i - allocated)].candidate].selected;
    }
    int64_t merchant_population = living_merchant_population(source_cell);
    int64_t merchant_selected = 0;
    for (const Candidate &candidate : candidates) {
        if (candidate.selected > 0 && is_merchant_slot(candidate.slot))
            merchant_selected += candidate.selected;
    }
    int64_t overflow = merchant_selected -
        std::max<int64_t>(0, merchant_population - 1);
    for (int32_t i = static_cast<int32_t>(candidates.size()) - 1;
         i >= 0 && overflow > 0; --i) {
        Candidate &candidate = candidates[i];
        if (candidate.selected <= 0 || !is_merchant_slot(candidate.slot))
            continue;
        const int64_t reduce = std::min(overflow, candidate.selected);
        candidate.selected -= reduce;
        overflow -= reduce;
    }
    // Leaving the last living merchant can drop selected below the quoted
    // request. Refill from remaining non-merchant family capacity so the
    // transit count still matches the command; otherwise reject before
    // mutating ledgers. A stale scalar of requested people against a smaller
    // payload is what tripped population_conservation_failed after in-epoch
    // starts.
    int64_t selected_total = 0;
    for (const Candidate &candidate : candidates)
        selected_total += candidate.selected;
    int64_t shortfall = requested - selected_total;
    for (Candidate &candidate : candidates) {
        if (shortfall <= 0) break;
        if (is_merchant_slot(candidate.slot) ||
            candidate.selected >= candidate.people) continue;
        const int64_t take = std::min(shortfall,
            candidate.people - candidate.selected);
        candidate.selected += take;
        shortfall -= take;
    }
    selected_total = 0;
    for (const Candidate &candidate : candidates)
        selected_total += candidate.selected;
    if (selected_total != requested) {
        error = "colonization_population_insufficient";
        return false;
    }
    _family_expeditions.payload_begin[expedition] = static_cast<uint32_t>(
        _family_expedition_payloads.size());
    _family_expeditions.payload_count[expedition] = 0;
    for (Candidate &candidate : candidates) {
        if (candidate.selected <= 0) continue;
        FamilyMembershipEdge &edge = _family_memberships[candidate.edge];
        const int32_t slot = candidate.slot;
        const int64_t source_population = _population.population[slot];
        if (candidate.selected > edge.people || candidate.selected >=
                family_population_in_cell(family_handle, source_cell)) {
            error = "colonization_population_guard_failed";
            unwind_family_expedition_payload_extract(expedition);
            return false;
        }
        FamilyExpeditionPayload payload;
        payload.source_cohort_handle = edge.cohort_handle;
        payload.signature = static_cast<int32_t>(_population.signature_id[slot]);
        payload.people = candidate.selected;
        payload.funds = mul_div_sat(_population.funds[slot], candidate.selected,
            source_population, _saturation_count);
        payload.epoch_income = mul_div_sat(_population.epoch_income[slot],
            candidate.selected, source_population, _saturation_count);
        payload.epoch_expense = mul_div_sat(_population.epoch_expense[slot],
            candidate.selected, source_population, _saturation_count);
        payload.epoch_in_kind_income = mul_div_sat(
            _population.epoch_in_kind_income[slot], candidate.selected,
            source_population, _saturation_count);
        payload.income_ema = mul_div_sat(_population.income_ema[slot],
            candidate.selected, source_population, _saturation_count);
        payload.epoch_tax_paid = mul_div_sat(_population.epoch_tax_paid[slot],
            candidate.selected, source_population, _saturation_count);
        payload.epoch_subsidy_received = mul_div_sat(
            _population.epoch_subsidy_received[slot], candidate.selected,
            source_population, _saturation_count);
        payload.income_baseline_ema = mul_div_sat(
            _population.income_baseline_ema[slot], candidate.selected,
            source_population, _saturation_count);
        payload.demography_residual = mul_div_sat(
            _population.demography_residual[slot], candidate.selected,
            source_population, _saturation_count);
        payload.cash_claim = mul_div_sat(edge.cash_claim, candidate.selected,
            edge.people, _saturation_count);
        payload.owner_employed = mul_div_sat(edge.owner_employed,
            candidate.selected, edge.people, _saturation_count);
        payload.employee_employed = mul_div_sat(edge.employee_employed,
            candidate.selected, edge.people, _saturation_count);
        payload.needs_satisfaction = _population.needs_satisfaction[slot];
        payload.worst_need_id = _population.worst_need_id[slot];
        payload.composite_satisfaction =
            _population.composite_satisfaction[slot];
        payload.worst_dimension_id = _population.worst_dimension_id[slot];
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            payload.satisfaction_dims[dim] = _population.satisfaction_dims[
                static_cast<size_t>(slot) * SAT_DIM_COUNT + dim];
        payload.person_begin = static_cast<uint32_t>(
            _family_expedition_person_handles.size());
        std::vector<int32_t> people;
        for (int32_t person = 0; person < static_cast<int32_t>(
                _persons.active.size()); ++person) {
            if (_persons.active[person] != 0 &&
                _persons.family_handle[person] == family_handle &&
                _persons.cohort_handle[person] == edge.cohort_handle)
                people.push_back(person);
        }
        std::sort(people.begin(), people.end(), [&](int32_t a, int32_t b) {
            return std::tie(_persons.stable_id[a], a) <
                   std::tie(_persons.stable_id[b], b);
        });
        int64_t remaining_people = edge.people;
        int64_t remaining_selected = candidate.selected;
        for (const int32_t person : people) {
            uint64_t hash = 1469598103934665603ULL;
            hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed));
            hash = trace_hash_mix(hash, static_cast<uint64_t>(
                _family_expeditions.stable_id[expedition]));
            hash = trace_hash_mix(hash, static_cast<uint64_t>(
                _persons.stable_id[person]));
            if (remaining_people > 0 && remaining_selected > 0 &&
                static_cast<int64_t>(hash % static_cast<uint64_t>(
                    remaining_people)) < remaining_selected) {
                _family_expedition_person_handles.push_back(
                    _persons.handle_for_index(person));
                _persons.cohort_handle[person] = 0;
                _persons.building_handle[person] = 0;
                _persons.job_kind[person] = 0;
                _persons.employee_role_index[person] = -1;
                --remaining_selected;
            }
            --remaining_people;
        }
        payload.person_count = static_cast<uint32_t>(
            _family_expedition_person_handles.size()) - payload.person_begin;
        audit_touch_population_lane(slot);
        _population.population[slot] -= payload.people;
        _population.funds[slot] -= payload.funds;
        _population.epoch_income[slot] -= payload.epoch_income;
        _population.epoch_expense[slot] -= payload.epoch_expense;
        _population.epoch_in_kind_income[slot] -= payload.epoch_in_kind_income;
        _population.income_ema[slot] -= payload.income_ema;
        _population.epoch_tax_paid[slot] -= payload.epoch_tax_paid;
        _population.epoch_subsidy_received[slot] -= payload.epoch_subsidy_received;
        _population.income_baseline_ema[slot] -= payload.income_baseline_ema;
        _population.demography_residual[slot] -= payload.demography_residual;
        edge.people -= payload.people; edge.cash_claim -= payload.cash_claim;
        edge.owner_employed -= payload.owner_employed;
        edge.employee_employed -= payload.employee_employed;
        edge.population_basis = std::max<int64_t>(0,
            edge.population_basis - payload.people);
        edge.funds_basis = std::max<int64_t>(0,
            edge.funds_basis - payload.cash_claim);
        _family_expedition_payloads.push_back(payload);
        _family_expeditions.payload_count[expedition] =
            static_cast<uint32_t>(_family_expedition_payloads.size()) -
            _family_expeditions.payload_begin[expedition];
    }
    _family_expeditions.payload_count[expedition] = static_cast<uint32_t>(
        _family_expedition_payloads.size()) -
        _family_expeditions.payload_begin[expedition];
    if (_family_expeditions.payload_count[expedition] == 0) {
        error = "colonization_payload_empty";
        unwind_family_expedition_payload_extract(expedition);
        return false;
    }
    const uint64_t reservation_owner =
        _family_expeditions.handle_for_index(expedition);
    const uint32_t payload_begin = _family_expeditions.payload_begin[expedition];
    const uint32_t payload_end = payload_begin +
        _family_expeditions.payload_count[expedition];
    for (uint32_t p = payload_begin; p < payload_end; ++p) {
        FamilyExpeditionPayload &payload = _family_expedition_payloads[p];
        payload.reserved_slot = _population.reserve_slot(
            _family_expeditions.target_cell[expedition],
            static_cast<uint32_t>(payload.signature), reservation_owner);
        if (payload.reserved_slot < 0) {
            error = "colonization_target_slot_reservation_failed";
            unwind_family_expedition_payload_extract(expedition);
            return false;
        }
    }
    _family_expeditions.population[expedition] =
        family_expedition_payload_people(expedition);
    _family_indices_dirty = true; _person_indices_dirty = true;
    _structural_touched_cells.push_back(source_cell);
    if (!repair_cell_merchant_and_rebuild(source_cell, error)) {
        unwind_family_expedition_payload_extract(expedition);
        return false;
    }
    _colonization_payload_split_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return true;
}

bool NativeEconomyRuntime::restore_family_expedition_payload(
        int32_t expedition, int32_t destination_cell, std::string &error) {
    if (destination_cell < 0 || destination_cell >= _cell_count) {
        error = "colonization_destination_invalid"; return false;
    }
    const uint64_t family_handle = _family_expeditions.family_handle[expedition];
    const uint32_t begin = _family_expeditions.payload_begin[expedition];
    const uint32_t end = begin + _family_expeditions.payload_count[expedition];
    if (end > _family_expedition_payloads.size()) {
        error = "colonization_payload_range_invalid"; return false;
    }
    for (uint32_t p = begin; p < end; ++p) {
        FamilyExpeditionPayload &payload = _family_expedition_payloads[p];
        const uint64_t reservation_owner =
            _family_expeditions.handle_for_index(expedition);
        int32_t slot = -1;
        if (destination_cell == _family_expeditions.target_cell[expedition]) {
            slot = _population.claim_reserved_slot(payload.reserved_slot,
                destination_cell, static_cast<uint32_t>(payload.signature),
                reservation_owner);
        } else {
            _population.release_reserved_slot(payload.reserved_slot,
                                               reservation_owner);
            slot = _population.allocate_slot(destination_cell,
                static_cast<uint32_t>(payload.signature));
        }
        if (slot < 0) { error = "colonization_reserved_slot_unavailable"; return false; }
        payload.reserved_slot = -1;
        const int64_t old_population = _population.population[slot];
        const int64_t merged_population = old_population + payload.people;
        auto blend = [&](uint16_t old_value, uint16_t incoming) {
            if (merged_population <= 0) return incoming;
            return static_cast<uint16_t>((static_cast<int64_t>(old_value) *
                old_population + static_cast<int64_t>(incoming) * payload.people) /
                merged_population);
        };
        audit_touch_population_lane(slot); touch_accounting_slot(slot);
        _population.population[slot] = merged_population;
        _population.funds[slot] += payload.funds;
        _population.epoch_income[slot] += payload.epoch_income;
        _population.epoch_expense[slot] += payload.epoch_expense;
        _population.epoch_in_kind_income[slot] += payload.epoch_in_kind_income;
        _population.income_ema[slot] += payload.income_ema;
        _population.epoch_tax_paid[slot] += payload.epoch_tax_paid;
        _population.epoch_subsidy_received[slot] += payload.epoch_subsidy_received;
        _population.income_baseline_ema[slot] += payload.income_baseline_ema;
        _population.demography_residual[slot] += payload.demography_residual;
        _population.needs_satisfaction[slot] = blend(
            _population.needs_satisfaction[slot], payload.needs_satisfaction);
        _population.composite_satisfaction[slot] = blend(
            _population.composite_satisfaction[slot],
            payload.composite_satisfaction);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            const size_t lane = static_cast<size_t>(slot) * SAT_DIM_COUNT + dim;
            _population.satisfaction_dims[lane] = blend(
                _population.satisfaction_dims[lane],
                payload.satisfaction_dims[dim]);
        }
        if (old_population == 0) {
            _population.worst_need_id[slot] = payload.worst_need_id;
            _population.worst_dimension_id[slot] = payload.worst_dimension_id;
        }
        const uint64_t cohort_handle = _population.handle_for_slot(slot);
        _family_memberships.push_back({family_handle, cohort_handle,
            payload.people, payload.cash_claim, merged_population,
            _population.funds[slot], 0, 0});
        if (static_cast<size_t>(payload.person_begin) + payload.person_count >
                _family_expedition_person_handles.size()) {
            error = "colonization_person_payload_range_invalid"; return false;
        }
        for (uint32_t i = 0; i < payload.person_count; ++i) {
            int32_t person = -1;
            if (_persons.valid_handle(
                    _family_expedition_person_handles[payload.person_begin + i],
                    person))
                _persons.cohort_handle[person] = cohort_handle;
        }
    }
    _family_indices_dirty = true; _person_indices_dirty = true;
    _structural_touched_cells.push_back(destination_cell);
    return true;
}

bool NativeEconomyRuntime::finalize_immediate_family_expedition_settlement(
        int32_t destination_cell, std::string &error) {
    if (!repair_cell_merchant_and_rebuild(destination_cell, error)) return false;

    normalize_family_memberships(false);
    update_family_employment_attribution();
    if (_family_indices_dirty) rebuild_family_indices(false);
    rebuild_family_industry_metrics();
    rebuild_family_influences(false);
    rebuild_family_behavior_cache();
    rebuild_family_owned_output_csr();
    if (_person_indices_dirty) rebuild_person_indices();

    if (destination_cell >= 0 && destination_cell < _cell_count) {
        const CellSummary summary = build_cell_summary(destination_cell);
        if (destination_cell < static_cast<int32_t>(_committed_cells.size()))
            _committed_cells[destination_cell] = summary;
        if (destination_cell < static_cast<int32_t>(_staging_cells.size()))
            _staging_cells[destination_cell] = summary;
        if (destination_cell < static_cast<int32_t>(
                _cell_population_gen.size()))
            ++_cell_population_gen[destination_cell];
    }
    // Restore already audit-touches the destination lane. Rebuilding the
    // incremental shadow after that would snapshot post-merge population and
    // drop the +people / -transit delta for this epoch.
    if (!_epoch_active) rebuild_incremental_audit_shadow();
    note_family_expedition_audit_invalidation();
    return true;
}

void NativeEconomyRuntime::release_family_expedition_reservations(
        int32_t expedition) {
    if (expedition < 0 || expedition >= static_cast<int32_t>(
            _family_expeditions.active.size()) ||
        _family_expeditions.active[expedition] == 0) return;
    const uint64_t owner = _family_expeditions.handle_for_index(expedition);
    const uint32_t begin = _family_expeditions.payload_begin[expedition];
    const uint32_t end = std::min<uint32_t>(
        begin + _family_expeditions.payload_count[expedition],
        static_cast<uint32_t>(_family_expedition_payloads.size()));
    for (uint32_t p = begin; p < end; ++p) {
        FamilyExpeditionPayload &payload = _family_expedition_payloads[p];
        _population.release_reserved_slot(payload.reserved_slot, owner);
        payload.reserved_slot = -1;
    }
    _population.reclaim_empty_pages(_family_expeditions.target_cell[expedition]);
}

bool NativeEconomyRuntime::apply_cancel_family_expedition(
        const Command &cmd, std::string &error) {
    int32_t expedition = -1;
    if (!_family_expeditions.valid_handle(cmd.target_handle, expedition)) {
        error = "colonization_expedition_invalid"; return false;
    }
    if (_family_expeditions.state[expedition] == EXPEDITION_RETURNING) return true;
    if (_family_expeditions.state[expedition] == EXPEDITION_SETTLING &&
        _family_expeditions.effect_transaction_id[expedition] != 0) {
        error = "colonization_settlement_already_committed"; return false;
    }
    const int64_t elapsed = std::max<int64_t>(0,
        cmd.effective_day - _family_expeditions.departure_day[expedition]);
    const int64_t progressed = std::min<int64_t>(
        _family_expeditions.route_cost[expedition], elapsed *
        std::max(1, _family_expeditions.speed[expedition]));
    const int64_t return_days = (progressed +
        std::max(1, _family_expeditions.speed[expedition]) - 1) /
        std::max(1, _family_expeditions.speed[expedition]);
    _family_expeditions.state[expedition] = EXPEDITION_RETURNING;
    release_family_expedition_reservations(expedition);
    note_family_expedition_audit_invalidation();
    _family_expeditions.due_day[expedition] = cmd.effective_day + return_days;
    push_family_expedition_due(expedition);
    append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
        cmd.effective_day, 2, "CANCELLED_RETURNING");
    return true;
}

bool NativeEconomyRuntime::apply_settle_family_expedition(
        const Command &cmd, std::string &error) {
    int32_t expedition = -1;
    if (!_family_expeditions.valid_handle(cmd.target_handle, expedition))
        return true; // idempotent replay after a successful release.
    if (_family_expeditions.state[expedition] != EXPEDITION_SETTLING)
        return true;
    const int64_t owner = _country_runtime == nullptr ? 0 :
        _country_runtime->country_handle_for_cell(
            _family_expeditions.target_cell[expedition]);
    if (owner != static_cast<int64_t>(
            _family_expeditions.country_handle[expedition])) {
        _family_expeditions.state[expedition] = EXPEDITION_RETURNING;
        release_family_expedition_reservations(expedition);
        note_family_expedition_audit_invalidation();
        _family_expeditions.due_day[expedition] = _current_day +
            std::max<int64_t>(1, (_family_expeditions.route_cost[expedition] +
                _family_expeditions.speed[expedition] - 1) /
                _family_expeditions.speed[expedition]);
        push_family_expedition_due(expedition);
        append_colonization_receipt(expedition, cmd.sequence,
            cmd.effective_day, _current_day, 3, "TARGET_LOST_RETURNING");
        return true;
    }
    const int32_t destination = _family_expeditions.target_cell[expedition];
    const uint64_t country_handle = _family_expeditions.country_handle[expedition];
    if (!restore_family_expedition_payload(expedition, destination, error))
        return false;
    if (!settle_family_expedition_kit(expedition, destination, error))
        return false;
    if (cmd.i32_1 > 0)
        apply_family_colonization_population_reward(destination,
            _family_expeditions.family_handle[expedition], cmd.i32_1);
    bool claimed = cmd.i64_0 != 0;
    if (!claimed && _effect_runtime != nullptr)
        claimed = _effect_runtime->family_colonization_includes_claim(
            _family_expeditions.effect_transaction_id[expedition]);
    append_colonization_receipt(expedition, cmd.sequence, cmd.effective_day,
        _current_day, claimed ? 4 : 6, claimed ? "CLAIMED" : "RELOCATED");
    _family_expedition_target_index.erase(family_expedition_target_key(
        country_handle, destination));
    _family_expeditions.release(expedition);
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
            _family_expeditions.active.size()); ++expedition) {
        if (_family_expeditions.active[expedition] == 0 ||
            _family_expeditions.state[expedition] != EXPEDITION_SETTLING)
            continue;
        const uint64_t handle = _family_expeditions.handle_for_index(expedition);
        if (handle == 0 || family_expedition_settle_inflight(handle)) continue;
        const uint64_t settle_key =
            _effect_runtime->family_colonization_settle_idempotency_key(
                _family_expeditions.stable_id[expedition],
                _family_expeditions.generation[expedition],
                _family_expeditions.idempotency_key[expedition]);
        const auto found = _effect_idempotency_requests.find(settle_key);
        if (found == _effect_idempotency_requests.end()) continue;
        const auto result = _effect_command_results.find(found->second);
        if (result == _effect_command_results.end() ||
            result->second.complete != 0) continue;
        Command command;
        command.opcode = COMMAND_SETTLE_FAMILY_EXPEDITION;
        command.effective_day = _current_day;
        command.sequence = static_cast<int64_t>(settle_key & 0x7fffffffffffffffULL);
        command.target_handle = handle;
        command.i32_0 = _family_expeditions.target_cell[expedition];
        command.i32_1 = _effect_runtime->family_colonization_population_reward(
            _family_expeditions.effect_transaction_id[expedition]);
        command.i64_0 = _effect_runtime->family_colonization_includes_claim(
            _family_expeditions.effect_transaction_id[expedition]) ? 1 : 0;
        command.i64_1 = static_cast<int64_t>(
            _family_expeditions.country_handle[expedition]);
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
    while (!_family_expedition_due_heap.empty()) {
        const auto top = _family_expedition_due_heap.front();
        if (top.first > day) break;
        std::pop_heap(_family_expedition_due_heap.begin(),
                      _family_expedition_due_heap.end(), due_heap_less);
        _family_expedition_due_heap.pop_back();
        const int32_t expedition = top.second;
        if (expedition < 0 || expedition >= static_cast<int32_t>(
                _family_expeditions.active.size()) ||
            _family_expeditions.active[expedition] == 0 ||
            _family_expeditions.due_day[expedition] != top.first) continue;
        if (_family_expeditions.state[expedition] == EXPEDITION_SETTLING) {
            const int64_t transaction_id =
                _family_expeditions.effect_transaction_id[expedition];
            const int32_t status = _effect_runtime == nullptr ? 0 :
                _effect_runtime->transaction_status_pod(transaction_id);
            if (status == EffectRuntime::REJECTED ||
                status == EffectRuntime::RESYNC_REQUIRED || status == 0) {
                if (_effect_runtime != nullptr && transaction_id != 0)
                    _effect_runtime->consume_rejected_transaction_pod(
                        transaction_id,
                        _family_expeditions.stable_id[expedition]);
                _family_expeditions.effect_transaction_id[expedition] = 0;
                _family_expeditions.state[expedition] = EXPEDITION_RETURNING;
                release_family_expedition_reservations(expedition);
                _family_expeditions.due_day[expedition] = day +
                    std::max<int64_t>(1,
                        (_family_expeditions.route_cost[expedition] +
                         _family_expeditions.speed[expedition] - 1) /
                        _family_expeditions.speed[expedition]);
                push_family_expedition_due(expedition);
                append_colonization_receipt(expedition, 0,
                    _family_expeditions.departure_day[expedition], day, 3,
                    "TARGET_LOST_RETURNING");
            } else {
                // ACKs normally complete within the same scheduler boundary.
                // Keeping one sparse heap entry makes stalled transactions
                // observable without scanning every active expedition daily.
                _family_expeditions.due_day[expedition] = day + 1;
                push_family_expedition_due(expedition);
            }
            continue;
        }
        if (_family_expeditions.state[expedition] == EXPEDITION_RETURNING) {
            const int32_t source_cell =
                _family_expeditions.source_cell[expedition];
            if (!restore_family_expedition_payload(expedition,
                    source_cell, error)) return false;
            if (!restore_family_expedition_cargo(expedition,
                    source_cell, false, error))
                return false;
            if (!repair_cell_merchant_and_rebuild(source_cell, error))
                return false;
            note_family_expedition_audit_invalidation();
            append_colonization_receipt(expedition, 0,
                _family_expeditions.departure_day[expedition], day, 5, "RETURNED");
            _family_expedition_target_index.erase(family_expedition_target_key(
                _family_expeditions.country_handle[expedition],
                _family_expeditions.target_cell[expedition]));
            _family_expeditions.release(expedition);
            continue;
        }
        if (_family_expeditions.state[expedition] == EXPEDITION_OUTBOUND) {
            const int64_t owner = _country_runtime == nullptr ? 0 :
                _country_runtime->country_handle_for_cell(
                    _family_expeditions.target_cell[expedition]);
            if (_country_runtime == nullptr ||
                (owner != 0 && owner != static_cast<int64_t>(
                    _family_expeditions.country_handle[expedition]))) {
                _family_expeditions.state[expedition] = EXPEDITION_RETURNING;
                release_family_expedition_reservations(expedition);
                _family_expeditions.due_day[expedition] = day +
                    std::max<int64_t>(1, (_family_expeditions.route_cost[expedition] +
                        _family_expeditions.speed[expedition] - 1) /
                        _family_expeditions.speed[expedition]);
                push_family_expedition_due(expedition);
                append_colonization_receipt(expedition, 0,
                    _family_expeditions.departure_day[expedition], day, 3,
                    "TARGET_LOST_RETURNING");
                continue;
            }
            if (_effect_runtime == nullptr) {
                error = "colonization_effect_runtime_unavailable"; return false;
            }
            const uint64_t handle =
                _family_expeditions.handle_for_index(expedition);
            int64_t transaction_id = 0;
            const bool claim_unowned = owner == 0;
            const int32_t population_reward =
                family_colonization_population_reward_amount(
                    _family_expeditions.family_handle[expedition]);
            if (!_effect_runtime->enqueue_family_colonization_pod(
                    _family_expeditions.stable_id[expedition], day,
                    _family_expeditions.stable_id[expedition],
                    _family_expeditions.country_handle[expedition],
                    static_cast<uint32_t>(
                        _family_expeditions.country_handle[expedition] >> 32U),
                    handle, _family_expeditions.generation[expedition],
                    _family_expeditions.target_cell[expedition],
                    _family_expeditions.idempotency_key[expedition], error,
                    &transaction_id, claim_unowned, population_reward)) return false;
            _family_expeditions.effect_transaction_id[expedition] = transaction_id;
            _family_expeditions.state[expedition] = EXPEDITION_SETTLING;
            _family_expeditions.due_day[expedition] = day + 1;
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
    for (int32_t i = 0; i < static_cast<int32_t>(
            _family_expeditions.active.size()); ++i) {
        if (_family_expeditions.active[i] == 0) continue;
        _family_expedition_target_index[family_expedition_target_key(
            _family_expeditions.country_handle[i],
            _family_expeditions.target_cell[i])] = i;
        if (_family_expeditions.state[i] != EXPEDITION_RETURNING) {
            const uint64_t owner = _family_expeditions.handle_for_index(i);
            const uint32_t begin = _family_expeditions.payload_begin[i];
            const uint32_t end = std::min<uint32_t>(begin +
                _family_expeditions.payload_count[i], static_cast<uint32_t>(
                    _family_expedition_payloads.size()));
            for (uint32_t p = begin; p < end; ++p) {
                FamilyExpeditionPayload &payload =
                    _family_expedition_payloads[p];
                payload.reserved_slot = _population.reserve_slot(
                    _family_expeditions.target_cell[i],
                    static_cast<uint32_t>(payload.signature), owner);
            }
        }
        if (_family_expeditions.due_day[i] !=
                std::numeric_limits<int64_t>::max())
            push_family_expedition_due(i);
    }
}

Dictionary NativeEconomyRuntime::family_expeditions(
        int64_t country_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    fill_colonization_query_flags(out);
    std::vector<int32_t> rows;
    for (int32_t i = 0; i < static_cast<int32_t>(
            _family_expeditions.active.size()); ++i)
        if (_family_expeditions.active[i] != 0 &&
            _family_expeditions.country_handle[i] ==
                static_cast<uint64_t>(country_handle_value)) rows.push_back(i);
    std::sort(rows.begin(), rows.end(), [&](int32_t a, int32_t b) {
        return std::tie(_family_expeditions.due_day[a],
                        _family_expeditions.stable_id[a]) <
               std::tie(_family_expeditions.due_day[b],
                        _family_expeditions.stable_id[b]);
    });
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min<int32_t>(rows.size(), offset + limit);
    PackedInt64Array handles, families, populations, departures, dues;
    PackedInt32Array sources, targets, costs, states;
    for (int32_t p = offset; p < end; ++p) {
        const int32_t i = rows[p];
        handles.push_back(static_cast<int64_t>(
            _family_expeditions.handle_for_index(i)));
        families.push_back(static_cast<int64_t>(
            _family_expeditions.family_handle[i]));
        sources.push_back(_family_expeditions.source_cell[i]);
        targets.push_back(_family_expeditions.target_cell[i]);
        populations.push_back(family_expedition_payload_people(i));
        departures.push_back(_family_expeditions.departure_day[i]);
        dues.push_back(_family_expeditions.due_day[i]);
        costs.push_back(_family_expeditions.route_cost[i]);
        states.push_back(_family_expeditions.state[i]);
    }
    out["ok"] = true; out["expedition_handles"] = handles;
    out["family_handles"] = families; out["source_cells"] = sources;
    out["target_cells"] = targets; out["populations"] = populations;
    out["departure_days"] = departures; out["due_days"] = dues;
    out["route_costs"] = costs; out["states"] = states;
    out["offset"] = offset; out["limit"] = limit;
    out["total"] = static_cast<int32_t>(rows.size());
    out["has_more"] = end < static_cast<int32_t>(rows.size());
    return out;
}

Dictionary NativeEconomyRuntime::family_expedition_snapshot(
        int64_t country_handle_value, int64_t expedition_handle_value) const {
    Dictionary out;
    int32_t expedition = -1;
    if (!_family_expeditions.valid_handle(
            static_cast<uint64_t>(expedition_handle_value), expedition) ||
        _family_expeditions.country_handle[expedition] !=
            static_cast<uint64_t>(country_handle_value)) {
        out["ok"] = false; out["code"] = "colonization_expedition_invalid";
        return out;
    }
    PackedInt32Array route, cumulative;
    const uint32_t begin = _family_expeditions.route_begin[expedition];
    const uint32_t count = _family_expeditions.route_count[expedition];
    for (uint32_t i = 0; i < count; ++i) {
        route.push_back(_family_expedition_route_cells[begin + i]);
        cumulative.push_back(_family_expedition_route_costs[begin + i]);
    }
    out["ok"] = true; out["expedition_handle"] = expedition_handle_value;
    out["family_handle"] = static_cast<int64_t>(
        _family_expeditions.family_handle[expedition]);
    out["source_cell"] = _family_expeditions.source_cell[expedition];
    out["target_cell"] = _family_expeditions.target_cell[expedition];
    out["population"] = family_expedition_payload_people(expedition);
    out["departure_day"] = _family_expeditions.departure_day[expedition];
    out["due_day"] = _family_expeditions.due_day[expedition];
    out["route_cost"] = _family_expeditions.route_cost[expedition];
    out["speed"] = _family_expeditions.speed[expedition];
    out["state"] = _family_expeditions.state[expedition];
    out["effect_transaction_id"] =
        _family_expeditions.effect_transaction_id[expedition];
    out["route_cells"] = route; out["cumulative_costs"] = cumulative;
    return out;
}

Dictionary NativeEconomyRuntime::family_colonization_receipts(
        int64_t country_handle_value, int64_t after_receipt_id,
        int32_t limit) const {
    Dictionary out;
    limit = std::clamp(limit, 1, 256);
    Array receipts;
    int64_t last = after_receipt_id;
    for (const ColonizationReceipt &receipt : _colonization_receipts) {
        if (receipt.receipt_id <= after_receipt_id ||
            receipt.country_handle != static_cast<uint64_t>(country_handle_value))
            continue;
        Dictionary row;
        row["receipt_id"] = receipt.receipt_id;
        row["sequence"] = receipt.sequence;
        row["effective_day"] = receipt.effective_day;
        row["settled_day"] = receipt.settled_day;
        row["expedition_handle"] = static_cast<int64_t>(receipt.expedition_handle);
        row["target_cell"] = receipt.target_cell;
        row["kind"] = receipt.kind;
        row["code"] = String(receipt.code.c_str());
        receipts.push_back(row); last = receipt.receipt_id;
        if (receipts.size() >= limit) break;
    }
    out["ok"] = true; out["receipts"] = receipts;
    out["count"] = receipts.size(); out["last_receipt_id"] = last;
    return out;
}

} // namespace pk
