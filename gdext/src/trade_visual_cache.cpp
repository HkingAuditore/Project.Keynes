#include "trade_visual_cache.h"
#include "economy_runtime.h"

#include <algorithm>
#include <chrono>
#include <limits>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
namespace {
uint64_t now_us() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
bool heap_greater(const std::pair<int64_t, int32_t> &a,
                  const std::pair<int64_t, int32_t> &b) { return a > b; }
}

void TradeVisualCache::request(const godot::PackedInt32Array &cells,
        const godot::PackedByteArray &visible, int64_t revision,
        int32_t selected, bool enabled) {
    std::lock_guard<std::mutex> lock(_request_mutex);
    _request.touched_us = now_us();
    _request.enabled = enabled;
    if (!enabled) return;
    _request.selected = selected;
    _request.revision = revision;
    if (cells.is_empty()) _request.cells.clear();
    else _request.cells.assign(cells.ptr(), cells.ptr() + std::min<int64_t>(INTEREST_CAP, cells.size()));
    std::sort(_request.cells.begin(), _request.cells.end());
    _request.cells.erase(std::unique(_request.cells.begin(), _request.cells.end()), _request.cells.end());
    // Empty means omniscient. Copy only when vision changes; caller supplies a
    // revision that also changes on world/fog rebind.
    if (_request.visible.size() != static_cast<size_t>(visible.size()) ||
        _mask_revision != revision) {
        if (visible.is_empty()) _request.visible.clear();
        else _request.visible.assign(visible.ptr(), visible.ptr() + visible.size());
        _mask_revision = revision;
    }
}

void TradeVisualCache::reset() {
    { std::lock_guard<std::mutex> lock(_request_mutex); _request = Request{}; }
    _routes.clear();
    _search = Search{};
    _topology = _country_topology = 0;
    _scan_cursor = 0;
    _cycle = 1;
    _mask_revision = -1;
    std::atomic_store_explicit(&_view, std::shared_ptr<const View>(), std::memory_order_release);
}

void TradeVisualCache::step(NativeEconomyRuntime &runtime) {
    const uint64_t started = now_us();
    Request interest;
    {
        std::lock_guard<std::mutex> lock(_request_mutex);
        if (!_request.enabled || started - _request.touched_us > 2'000'000) return;
        interest = _request;
    }
    if (!runtime._bootstrapped || runtime._epoch_active || runtime._fatal ||
        runtime._save.active || runtime._restore.active) return;
    const auto &topology = runtime._trade_topology;
    const int32_t count = runtime._cell_count.get();
    if (!topology.ready || count <= 0 ||
        topology.neighbors.size() != static_cast<size_t>(count) * 6) return;
    if (_topology != topology.topology_hash ||
        _country_topology != runtime._epoch_country_topology_hash ||
        (!_search.parent.empty() && _search.parent.size() != static_cast<size_t>(count))) {
        _routes.clear();
        _search = Search{};
        _topology = topology.topology_hash;
        _country_topology = runtime._epoch_country_topology_hash;
        _scan_cursor = 0;
    }
    auto visible = [&](int32_t cell) {
        return cell >= 0 && cell < count && (interest.visible.empty() ||
            (static_cast<size_t>(cell) < interest.visible.size() && interest.visible[cell] != 0));
    };
    auto relevant = [&](const Route &r) {
        return visible(r.source) && visible(r.destination) &&
            (r.source == interest.selected || r.destination == interest.selected ||
             std::binary_search(interest.cells.begin(), interest.cells.end(), r.source) ||
             std::binary_search(interest.cells.begin(), interest.cells.end(), r.destination));
    };
    const auto &orders = runtime.trade_orders_store();
    uint32_t scanned = 0, expansions = 0, hits = 0;
    if (orders.size() == 0) {
        _routes.clear();
        _search.route = -1;
        _search.heap.clear();
        _scan_cursor = 0;
    }
    const int32_t scans = std::min<int32_t>(SCAN_CAP, orders.size());
    for (int32_t n = 0; n < scans; ++n) {
        if (_scan_cursor >= orders.size()) { _scan_cursor = 0; ++_cycle; }
        const int32_t i = _scan_cursor++;
        ++scanned;
        if (orders.cargo_delivered[i] != 0) continue;
        Route candidate;
        candidate.source = orders.sources[i];
        candidate.destination = orders.destinations[i];
        candidate.country = orders.source_country_slots[i];
        if (candidate.source == candidate.destination || !relevant(candidate)) continue;
        const int32_t country = candidate.country;
        candidate.capability = country >= 0 && static_cast<size_t>(country) <
                runtime._epoch_country_water_capability.size()
            ? runtime._epoch_country_water_capability[country] : 0;
        auto found = std::find_if(_routes.begin(), _routes.end(), [&](const Route &r) {
            return r.source == candidate.source && r.destination == candidate.destination &&
                r.capability == candidate.capability && r.country == country;
        });
        if (found == _routes.end()) {
            if (_routes.size() >= ROUTE_CAP) {
                // Reuse a cold entry, never shift indices beneath a search.
                found = std::find_if(_routes.begin(), _routes.end(), [&](const Route &r) {
                    return (&r - _routes.data()) != _search.route &&
                        (!relevant(r) || r.seen_cycle + 1 < _cycle);
                });
                if (found == _routes.end()) continue;
                *found = std::move(candidate);
            } else {
                _routes.push_back(std::move(candidate));
                found = _routes.end() - 1;
            }
        } else if (!found->cells.empty()) { ++hits; }
        if (found->seen_cycle != _cycle) found->intensity = 0;
        found->seen_cycle = _cycle;
        found->intensity = std::min(3, found->intensity + 1);
        found->representative_order_id = std::max(found->representative_order_id, orders.ids[i]);
    }
    // IDs stay ascending across dispatch/compaction/restore. Validate at most
    // 128 representatives in O(log orders), so arrival immediately stops a
    // sampled route even when a full 512-order sweep would take many seconds.
    auto active = [&](const Route &r) {
        if (!relevant(r)) return false;
        const uint8_t cap = r.country >= 0 && static_cast<size_t>(r.country) <
            runtime._epoch_country_water_capability.size()
            ? runtime._epoch_country_water_capability[r.country] : 0;
        if (r.capability != cap) return false;
        const auto it = std::lower_bound(orders.ids.begin(), orders.ids.end(), r.representative_order_id);
        return it != orders.ids.end() && *it == r.representative_order_id &&
            orders.cargo_delivered[static_cast<size_t>(it - orders.ids.begin())] == 0;
    };
    // Native path scratch is completely separate from the economic planner.
    // Expand the six-neighbour graph directly: this is the continuous version
    // of the same coast portals, including their transfer penalty.
    auto water = [&](int32_t cell) {
        return topology.water_class.size() == static_cast<size_t>(count) &&
            topology.water_class[cell] != NativeEconomyRuntime::WATER_CLASS_NONE;
    };
    if (_search.route >= 0 && !active(_routes[_search.route])) {
        _search.route = -1;
        _search.heap.clear();
    }
    if (_search.route < 0) {
        int32_t best = -1;
        for (int32_t i = 0; i < static_cast<int32_t>(_routes.size()); ++i) {
            const auto &r = _routes[i];
            if (!active(r) || r.failed || !r.cells.empty()) continue;
            if (best < 0 || r.source == interest.selected || r.destination == interest.selected) best = i;
        }
        if (best >= 0) {
            if (_search.parent.size() != static_cast<size_t>(count)) {
                _search.distance.resize(count);
                _search.parent.resize(count);
                _search.visited.assign(count, 0);
            }
            _search.route = best;
            if (++_search.stamp == 0) {
                std::fill(_search.visited.begin(), _search.visited.end(), 0);
                _search.stamp = 1;
            }
            _search.heap.clear();
            _search.pops = 0;
            const auto &r = _routes[best];
            _search.distance[r.source] = 0;
            _search.parent[r.source] = -1;
            _search.visited[r.source] = _search.stamp;
            _search.heap.push_back({0, r.source});
        }
    }
    if (_search.route >= 0) {
        auto &r = _routes[_search.route];
        while (!_search.heap.empty() && expansions < EXPANSION_CAP) {
            std::pop_heap(_search.heap.begin(), _search.heap.end(), heap_greater);
            const auto node = _search.heap.back(); _search.heap.pop_back();
            // Count stale heap pops as work too; never hide an unbounded loop.
            ++expansions; ++_search.pops;
            const int32_t cell = node.second;
            if (_search.visited[cell] != _search.stamp || _search.distance[cell] != node.first) continue;
            if (cell == r.destination) {
                std::vector<int32_t> path;
                int32_t cursor = cell;
                while (cursor >= 0 && path.size() <= POINT_CAP) {
                    path.push_back(cursor); cursor = _search.parent[cursor];
                }
                if (cursor < 0 && path.size() >= 2 && path.size() <= POINT_CAP) {
                    r.cells.assign(path.rbegin(), path.rend());
                    r.modes.clear();
                    for (size_t j = 1; j < r.cells.size(); ++j) {
                        const auto a = r.cells[j - 1], b = r.cells[j];
                        bool river = (r.capability & NativeEconomyRuntime::WATER_CAP_RIVER) != 0 &&
                            topology.has_river.size() == static_cast<size_t>(count) &&
                            topology.has_river[a] && topology.has_river[b];
                        r.modes.push_back(water(a) || water(b) || river ? 1 : 0);
                    }
                } else r.failed = true;
                _search.route = -1; _search.heap.clear();
                break;
            }
            for (int d = 0; d < 6; ++d) {
                const int32_t next = topology.neighbors[static_cast<size_t>(cell) * 6 + d];
                if (next < 0 || next >= count) continue;
                const bool from_water = water(cell), to_water = water(next);
                if (to_water) {
                    if (!runtime.water_class_navigable(topology.water_class[next], r.capability)) continue;
                } else if (topology.passable[next] == 0) continue;
                int32_t cost;
                if (!from_water && !to_water) cost = runtime.trade_land_step_cost(cell, next, r.capability);
                else cost = to_water ? NativeEconomyRuntime::WATER_ENTER_COST
                    : NativeEconomyRuntime::WATER_TRANSFER_PENALTY;
                if (cost <= 0) continue;
                const int64_t distance = node.first + cost;
                if (_search.visited[next] == _search.stamp && _search.distance[next] <= distance) continue;
                _search.distance[next] = distance;
                _search.parent[next] = cell;
                _search.visited[next] = _search.stamp;
                _search.heap.push_back({distance, next});
                std::push_heap(_search.heap.begin(), _search.heap.end(), heap_greater);
            }
            if (_search.pops >= 65536) { r.failed = true; _search.heap.clear(); break; }
        }
        if (_search.route >= 0 && _search.heap.empty()) { r.failed = true; _search.route = -1; }
    }
    auto view = std::make_shared<View>();
    view->serial = ++_serial; view->topology = _topology;
    view->country_topology = _country_topology;
    view->day = runtime.last_committed_day(); view->request_revision = interest.revision;
    view->scanned = scanned; view->expansions = expansions; view->hits = hits;
    for (const auto &r : _routes) {
        if (!active(r)) continue;
        if (!r.cells.empty()) view->routes.push_back(r);
        else if (!r.failed) ++view->pending;
    }
    std::stable_sort(view->routes.begin(), view->routes.end(), [&](const Route &a, const Route &b) {
        const bool ap = a.source == interest.selected || a.destination == interest.selected;
        const bool bp = b.source == interest.selected || b.destination == interest.selected;
        if (ap != bp) return ap;
        return std::make_pair(a.source, a.destination) < std::make_pair(b.source, b.destination);
    });
    uint64_t bytes = _search.distance.capacity() * 8 + _search.parent.capacity() * 4 +
        _search.visited.capacity() * 4 + _search.heap.capacity() * sizeof(std::pair<int64_t, int32_t>);
    for (const auto &r : _routes) bytes += sizeof(Route) + r.cells.capacity() * 4 + r.modes.capacity();
    for (const auto &r : view->routes) bytes += sizeof(Route) + r.cells.capacity() * 4 + r.modes.capacity();
    view->bytes = bytes + interest.visible.capacity() * 2 + interest.cells.capacity() * 8;
    view->elapsed_us = now_us() - started;
    std::atomic_store_explicit(&_view, std::shared_ptr<const View>(std::move(view)), std::memory_order_release);
}

godot::Dictionary TradeVisualCache::snapshot() const {
    using namespace godot;
    Dictionary out;
    const auto view = std::atomic_load_explicit(&_view, std::memory_order_acquire);
    out["ok"] = view != nullptr;
    if (!view) { out["reason"] = "trade_visual_pending"; return out; }
    PackedInt32Array sources, destinations, countries, intensity, offsets, cells;
    PackedByteArray modes, capabilities;
    offsets.push_back(0);
    std::lock_guard<std::mutex> lock(_request_mutex);
    auto visible = [&](int32_t cell) {
        return cell >= 0 && (_request.visible.empty() ||
            (static_cast<size_t>(cell) < _request.visible.size() && _request.visible[cell] != 0));
    };
    for (const auto &r : view->routes) {
        if (!_request.enabled || !visible(r.source) || !visible(r.destination)) continue;
        if (sources.size() >= 32) break;
        sources.push_back(r.source); destinations.push_back(r.destination);
        countries.push_back(r.country); intensity.push_back(r.intensity);
        capabilities.push_back(r.capability);
        for (size_t i = 0; i < r.cells.size(); ++i) {
            cells.push_back(r.cells[i]); modes.push_back(i < r.modes.size() ? r.modes[i] : 0);
        }
        offsets.push_back(cells.size());
    }
    out["source_cells"] = sources; out["destination_cells"] = destinations;
    out["country_slots"] = countries; out["intensity"] = intensity;
    out["capabilities"] = capabilities;
    out["route_offsets"] = offsets; out["route_cells"] = cells; out["edge_modes"] = modes;
    out["serial"] = static_cast<int64_t>(view->serial);
    out["topology_hash"] = static_cast<int64_t>(view->topology);
    out["country_topology_hash"] = static_cast<int64_t>(view->country_topology);
    out["snapshot_day"] = view->day; out["vision_revision"] = view->request_revision;
    out["scanned_orders"] = view->scanned; out["expanded_nodes"] = view->expansions;
    out["cache_hits"] = view->hits; out["pending_routes"] = view->pending;
    out["native_usec"] = static_cast<int64_t>(view->elapsed_us);
    out["memory_bytes"] = static_cast<int64_t>(view->bytes);
    out["snapshot_source"] = "committed_trade_visual";
    return out;
}
} // namespace pk
