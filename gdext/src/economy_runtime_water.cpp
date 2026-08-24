#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <limits>
#include <queue>
#include <utility>

namespace pk {

namespace {

constexpr uint8_t kLandformDeepOcean = 0;
constexpr uint8_t kLandformOcean = 1;
constexpr uint8_t kLandformCoast = 2;
constexpr uint8_t kLandformLake = 3;
constexpr uint8_t kTerrainSeaIce = 20;

uint8_t classify_water_class(uint8_t terrain, uint8_t landform) {
    if (terrain == kTerrainSeaIce) return NativeEconomyRuntime::WATER_CLASS_NONE;
    switch (landform) {
        case kLandformDeepOcean: return NativeEconomyRuntime::WATER_CLASS_DEEP;
        case kLandformOcean: return NativeEconomyRuntime::WATER_CLASS_FAR;
        case kLandformCoast: return NativeEconomyRuntime::WATER_CLASS_SHALLOW;
        case kLandformLake: return NativeEconomyRuntime::WATER_CLASS_LAKE;
        default: return NativeEconomyRuntime::WATER_CLASS_NONE;
    }
}

bool graph_water_ok(uint8_t water_class, int32_t graph_index) {
    switch (graph_index) {
        case 0: return water_class == NativeEconomyRuntime::WATER_CLASS_LAKE;
        case 1: return water_class == NativeEconomyRuntime::WATER_CLASS_LAKE ||
            water_class == NativeEconomyRuntime::WATER_CLASS_SHALLOW;
        case 2: return water_class == NativeEconomyRuntime::WATER_CLASS_LAKE ||
            water_class == NativeEconomyRuntime::WATER_CLASS_SHALLOW ||
            water_class == NativeEconomyRuntime::WATER_CLASS_FAR;
        case 3: return water_class != NativeEconomyRuntime::WATER_CLASS_NONE;
        default: return false;
    }
}

} // namespace

uint64_t NativeEconomyRuntime::trade_route_cache_key(
        int32_t source, int32_t destination, int32_t layer) {
    return (static_cast<uint64_t>(static_cast<uint8_t>(std::clamp(layer, 0, 7))) << 60) |
        (static_cast<uint64_t>(static_cast<uint32_t>(source) & 0x3fffffffu) << 30) |
        (static_cast<uint32_t>(destination) & 0x3fffffffu);
}

bool NativeEconomyRuntime::cells_are_hex_neighbors(int32_t a, int32_t b) const {
    if (a < 0 || b < 0 || a >= _cell_count || b >= _cell_count) return false;
    if (_trade_topology.neighbors.size() != static_cast<size_t>(_cell_count) * 6)
        return false;
    for (int32_t direction = 0; direction < 6; ++direction) {
        if (_trade_topology.neighbors[static_cast<size_t>(a) * 6 + direction] == b)
            return true;
    }
    return false;
}

bool NativeEconomyRuntime::water_class_navigable(uint8_t water_class,
                                                 uint8_t cap) const {
    switch (water_class) {
        case WATER_CLASS_LAKE:
            return (cap & WATER_CAP_RIVER) != 0 || water_maritime_level(cap) >= 1;
        case WATER_CLASS_SHALLOW:
            return water_maritime_level(cap) >= 1;
        case WATER_CLASS_FAR:
            return water_maritime_level(cap) >= 2;
        case WATER_CLASS_DEEP:
            return water_maritime_level(cap) >= 3;
        default:
            return false;
    }
}

uint8_t NativeEconomyRuntime::water_capability_for_country(
        int32_t country_slot, bool frozen) const {
    if (country_slot < 0) return 0;
    if (frozen && _epoch_active &&
        country_slot < static_cast<int32_t>(_epoch_country_water_capability.size())) {
        return _epoch_country_water_capability[static_cast<size_t>(country_slot)];
    }
    if (_country_runtime == nullptr) return 0;
    uint8_t cap = 0;
    if (_water_tech_river >= 0 &&
        _country_runtime->has_technology(country_slot, _water_tech_river))
        cap |= WATER_CAP_RIVER;
    if (_water_tech_shallow >= 0 &&
        _country_runtime->has_technology(country_slot, _water_tech_shallow))
        cap |= WATER_CAP_SHALLOW_SEA;
    if (_water_tech_far >= 0 &&
        _country_runtime->has_technology(country_slot, _water_tech_far))
        cap |= WATER_CAP_FAR_SEA;
    if (_water_tech_deep >= 0 &&
        _country_runtime->has_technology(country_slot, _water_tech_deep))
        cap |= WATER_CAP_DEEP_SEA;
    return cap;
}

uint8_t NativeEconomyRuntime::water_capability_for_handle(
        uint64_t country_handle, bool frozen) const {
    if (country_handle == 0 || _country_runtime == nullptr ||
        !_country_runtime->valid_handle(static_cast<int64_t>(country_handle)))
        return 0;
    const int32_t slot = static_cast<int32_t>(country_handle & 0xffffffffULL);
    return water_capability_for_country(slot, frozen);
}

int32_t NativeEconomyRuntime::trade_component_for(int32_t cell, uint8_t cap) const {
    if (cell < 0 || cell >= _cell_count) return -1;
    const int32_t layer = water_layer_index(cap);
    const size_t index = static_cast<size_t>(layer) * static_cast<size_t>(_cell_count) +
        static_cast<size_t>(cell);
    if (index < _trade_topology.component_layers.size())
        return _trade_topology.component_layers[index];
    if (cell < static_cast<int32_t>(_trade_topology.component.size()))
        return _trade_topology.component[static_cast<size_t>(cell)];
    return -1;
}

int32_t NativeEconomyRuntime::trade_land_step_cost(
        int32_t from_cell, int32_t to_cell, uint8_t cap) const {
    const int32_t cost = trade_edge_cost(from_cell, to_cell);
    if (cost <= 0) return 0;
    if ((cap & WATER_CAP_RIVER) == 0) return cost;
    if (_trade_topology.has_river.size() != static_cast<size_t>(_cell_count))
        return cost;
    if (_trade_topology.has_river[static_cast<size_t>(from_cell)] == 0 ||
        _trade_topology.has_river[static_cast<size_t>(to_cell)] == 0)
        return cost;
    return std::max(1, cost / 2);
}

void NativeEconomyRuntime::collect_transport_successors(
        int32_t cell, uint8_t cap, bool reverse) {
    _transport_succ_cells.clear();
    _transport_succ_costs.clear();
    if (cell < 0 || cell >= _cell_count ||
        _trade_topology.neighbors.size() != static_cast<size_t>(_cell_count) * 6)
        return;
    for (int32_t direction = 0; direction < 6; ++direction) {
        const int32_t neighbor = _trade_topology.neighbors[
            static_cast<size_t>(cell) * 6 + direction];
        if (neighbor < 0 ||
            _trade_topology.passable[static_cast<size_t>(neighbor)] == 0) continue;
        const int32_t step = reverse
            ? trade_land_step_cost(neighbor, cell, cap)
            : trade_land_step_cost(cell, neighbor, cap);
        if (step <= 0) continue;
        _transport_succ_cells.push_back(neighbor);
        _transport_succ_costs.push_back(step);
    }
    const int32_t graph_index = water_portal_graph_index(cap);
    if (graph_index < 0 || graph_index >= WATER_PORTAL_GRAPH_COUNT) return;
    const WaterPortalGraph &graph = _trade_topology.water_portals[graph_index];
    if (graph.cell_portal.size() != static_cast<size_t>(_cell_count)) return;
    const int32_t portal = graph.cell_portal[static_cast<size_t>(cell)];
    if (portal < 0) return;
    const std::vector<int32_t> &offsets = reverse ? graph.reverse_offsets : graph.offsets;
    const std::vector<int32_t> &targets = reverse ? graph.reverse_targets : graph.targets;
    const std::vector<int32_t> &costs = reverse ? graph.reverse_costs : graph.costs;
    if (offsets.size() < static_cast<size_t>(portal) + 2) return;
    const int32_t begin = offsets[static_cast<size_t>(portal)];
    const int32_t end = offsets[static_cast<size_t>(portal) + 1];
    for (int32_t edge = begin; edge < end; ++edge) {
        if (edge < 0 || edge >= static_cast<int32_t>(targets.size())) continue;
        const int32_t next = targets[static_cast<size_t>(edge)];
        const int32_t cost = costs[static_cast<size_t>(edge)];
        if (next < 0 || next >= _cell_count || cost <= 0) continue;
        _transport_succ_cells.push_back(next);
        _transport_succ_costs.push_back(cost);
    }
}

void NativeEconomyRuntime::build_water_portal_graph(int32_t graph_index) {
    WaterPortalGraph &graph = _trade_topology.water_portals[graph_index];
    graph.clear();
    const int32_t count = _cell_count;
    if (count <= 0 ||
        _trade_topology.water_class.size() != static_cast<size_t>(count) ||
        _trade_topology.neighbors.size() != static_cast<size_t>(count) * 6) {
        return;
    }
    graph.cell_portal.assign(static_cast<size_t>(count), -1);
    auto water_ok = [&](int32_t cell) {
        return graph_water_ok(_trade_topology.water_class[static_cast<size_t>(cell)],
                              graph_index);
    };
    for (int32_t cell = 0; cell < count; ++cell) {
        if (_trade_topology.passable[static_cast<size_t>(cell)] == 0) continue;
        bool portal = false;
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(cell) * 6 + direction];
            if (neighbor >= 0 && water_ok(neighbor)) {
                portal = true;
                break;
            }
        }
        if (!portal) continue;
        graph.cell_portal[static_cast<size_t>(cell)] =
            static_cast<int32_t>(graph.portal_cells.size());
        graph.portal_cells.push_back(cell);
    }
    const int32_t portal_count = static_cast<int32_t>(graph.portal_cells.size());
    graph.offsets.assign(static_cast<size_t>(portal_count) + 1, 0);
    graph.reverse_offsets.assign(static_cast<size_t>(portal_count) + 1, 0);
    if (portal_count <= 0) return;

    std::vector<int32_t> dist(static_cast<size_t>(count), 0);
    std::vector<uint32_t> stamp(static_cast<size_t>(count), 0);
    uint32_t generation = 1;
    std::vector<std::vector<std::pair<int32_t, int32_t>>> forward(
        static_cast<size_t>(portal_count));
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(std::min(count, 256)));

    for (int32_t portal = 0; portal < portal_count; ++portal) {
        if (++generation == 0) {
            std::fill(stamp.begin(), stamp.end(), 0);
            generation = 1;
        }
        queue.clear();
        const int32_t origin = graph.portal_cells[static_cast<size_t>(portal)];
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(origin) * 6 + direction];
            if (neighbor < 0 || !water_ok(neighbor)) continue;
            stamp[static_cast<size_t>(neighbor)] = generation;
            dist[static_cast<size_t>(neighbor)] = WATER_ENTER_COST;
            queue.push_back(neighbor);
        }
        size_t cursor = 0;
        while (cursor < queue.size()) {
            const int32_t water = queue[cursor++];
            const int32_t here = dist[static_cast<size_t>(water)];
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _trade_topology.neighbors[
                    static_cast<size_t>(water) * 6 + direction];
                if (neighbor < 0 || !water_ok(neighbor)) continue;
                if (stamp[static_cast<size_t>(neighbor)] == generation) continue;
                stamp[static_cast<size_t>(neighbor)] = generation;
                dist[static_cast<size_t>(neighbor)] = here + WATER_ENTER_COST;
                queue.push_back(neighbor);
            }
        }
        for (int32_t other = 0; other < portal_count; ++other) {
            if (other == portal) continue;
            const int32_t dest = graph.portal_cells[static_cast<size_t>(other)];
            int32_t best = std::numeric_limits<int32_t>::max();
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = _trade_topology.neighbors[
                    static_cast<size_t>(dest) * 6 + direction];
                if (neighbor < 0 || !water_ok(neighbor)) continue;
                if (stamp[static_cast<size_t>(neighbor)] != generation) continue;
                best = std::min(best, dist[static_cast<size_t>(neighbor)]);
            }
            if (best == std::numeric_limits<int32_t>::max()) continue;
            const int32_t jump = best + WATER_TRANSFER_PENALTY;
            if (jump <= 0) continue;
            forward[static_cast<size_t>(portal)].push_back({dest, jump});
        }
    }

    std::vector<std::vector<std::pair<int32_t, int32_t>>> reverse(
        static_cast<size_t>(portal_count));
    int32_t forward_edges = 0;
    for (int32_t portal = 0; portal < portal_count; ++portal) {
        std::sort(forward[static_cast<size_t>(portal)].begin(),
                  forward[static_cast<size_t>(portal)].end());
        forward_edges += static_cast<int32_t>(forward[static_cast<size_t>(portal)].size());
        for (const auto &edge : forward[static_cast<size_t>(portal)]) {
            const int32_t dest_portal = graph.cell_portal[static_cast<size_t>(edge.first)];
            if (dest_portal < 0) continue;
            reverse[static_cast<size_t>(dest_portal)].push_back(
                {graph.portal_cells[static_cast<size_t>(portal)], edge.second});
        }
    }
    graph.targets.reserve(static_cast<size_t>(forward_edges));
    graph.costs.reserve(static_cast<size_t>(forward_edges));
    graph.reverse_targets.reserve(static_cast<size_t>(forward_edges));
    graph.reverse_costs.reserve(static_cast<size_t>(forward_edges));
    for (int32_t portal = 0; portal < portal_count; ++portal) {
        graph.offsets[static_cast<size_t>(portal)] = static_cast<int32_t>(graph.targets.size());
        for (const auto &edge : forward[static_cast<size_t>(portal)]) {
            graph.targets.push_back(edge.first);
            graph.costs.push_back(edge.second);
        }
        graph.reverse_offsets[static_cast<size_t>(portal)] =
            static_cast<int32_t>(graph.reverse_targets.size());
        std::sort(reverse[static_cast<size_t>(portal)].begin(),
                  reverse[static_cast<size_t>(portal)].end());
        for (const auto &edge : reverse[static_cast<size_t>(portal)]) {
            graph.reverse_targets.push_back(edge.first);
            graph.reverse_costs.push_back(edge.second);
        }
    }
    graph.offsets[static_cast<size_t>(portal_count)] =
        static_cast<int32_t>(graph.targets.size());
    graph.reverse_offsets[static_cast<size_t>(portal_count)] =
        static_cast<int32_t>(graph.reverse_targets.size());
}

void NativeEconomyRuntime::build_water_transport_graphs() {
    for (int32_t graph = 0; graph < WATER_PORTAL_GRAPH_COUNT; ++graph)
        build_water_portal_graph(graph);
    build_water_component_layers();
}

void NativeEconomyRuntime::build_water_component_layers() {
    const int32_t count = _cell_count;
    _trade_topology.component_layers.assign(
        static_cast<size_t>(WATER_LAYER_COUNT) * static_cast<size_t>(std::max(0, count)),
        -1);
    if (count <= 0) {
        _trade_topology.component.assign(0, -1);
        _trade_topology.component_country_hash = _trade_topology.topology_hash;
        return;
    }
    std::vector<int32_t> queue;
    queue.reserve(static_cast<size_t>(std::min(count, 256)));
    for (int32_t layer = 0; layer < WATER_LAYER_COUNT; ++layer) {
        const uint8_t cap = water_capability_from_layer(layer);
        int32_t *components = _trade_topology.component_layers.data() +
            static_cast<size_t>(layer) * static_cast<size_t>(count);
        int32_t next_component = 0;
        for (int32_t seed = 0; seed < count; ++seed) {
            if (_trade_topology.passable[static_cast<size_t>(seed)] == 0 ||
                components[seed] >= 0) continue;
            const int32_t component = next_component++;
            components[seed] = component;
            queue.clear();
            queue.push_back(seed);
            size_t cursor = 0;
            while (cursor < queue.size()) {
                const int32_t cell = queue[cursor++];
                collect_transport_successors(cell, cap, false);
                for (size_t i = 0; i < _transport_succ_cells.size(); ++i) {
                    const int32_t neighbor = _transport_succ_cells[i];
                    if (neighbor < 0 || neighbor >= count) continue;
                    if (_trade_topology.passable[static_cast<size_t>(neighbor)] == 0)
                        continue;
                    if (components[neighbor] >= 0) continue;
                    components[neighbor] = component;
                    queue.push_back(neighbor);
                }
            }
        }
    }
    _trade_topology.component.assign(
        _trade_topology.component_layers.begin(),
        _trade_topology.component_layers.begin() + count);
    _trade_topology.component_country_hash = _trade_topology.topology_hash;
}

bool NativeEconomyRuntime::reconstruct_water_corridor(
        int32_t from_portal, int32_t to_portal, uint8_t cap,
        std::vector<int32_t> &water_cells) const {
    water_cells.clear();
    if (from_portal < 0 || to_portal < 0 || from_portal >= _cell_count ||
        to_portal >= _cell_count || from_portal == to_portal) return false;
    if (_trade_topology.water_class.size() != static_cast<size_t>(_cell_count) ||
        _trade_topology.neighbors.size() != static_cast<size_t>(_cell_count) * 6)
        return false;
    auto water_ok = [&](int32_t cell) {
        return water_class_navigable(
            _trade_topology.water_class[static_cast<size_t>(cell)], cap);
    };
    std::vector<int32_t> parent(static_cast<size_t>(_cell_count), -2);
    std::vector<int32_t> queue;
    queue.reserve(64);
    int32_t reached = -1;
    for (int32_t direction = 0; direction < 6; ++direction) {
        const int32_t neighbor = _trade_topology.neighbors[
            static_cast<size_t>(from_portal) * 6 + direction];
        if (neighbor < 0 || !water_ok(neighbor) || parent[static_cast<size_t>(neighbor)] != -2)
            continue;
        parent[static_cast<size_t>(neighbor)] = -1;
        queue.push_back(neighbor);
    }
    size_t cursor = 0;
    while (cursor < queue.size() && reached < 0) {
        const int32_t water = queue[cursor++];
        bool adjacent_dest = false;
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(water) * 6 + direction];
            if (neighbor == to_portal) {
                adjacent_dest = true;
                break;
            }
        }
        if (adjacent_dest) {
            reached = water;
            break;
        }
        for (int32_t direction = 0; direction < 6; ++direction) {
            const int32_t neighbor = _trade_topology.neighbors[
                static_cast<size_t>(water) * 6 + direction];
            if (neighbor < 0 || !water_ok(neighbor) ||
                parent[static_cast<size_t>(neighbor)] != -2) continue;
            parent[static_cast<size_t>(neighbor)] = water;
            queue.push_back(neighbor);
        }
    }
    if (reached < 0) return false;
    std::vector<int32_t> reversed;
    for (int32_t cursor_cell = reached; cursor_cell >= 0;
         cursor_cell = parent[static_cast<size_t>(cursor_cell)]) {
        reversed.push_back(cursor_cell);
        if (parent[static_cast<size_t>(cursor_cell)] == -1) break;
    }
    std::reverse(reversed.begin(), reversed.end());
    water_cells.swap(reversed);
    return !water_cells.empty();
}

bool NativeEconomyRuntime::append_colonization_route_step(
        int32_t from_cell, int32_t to_cell, uint8_t cap, int64_t reverse_from,
        int64_t reverse_to, std::vector<int32_t> &route,
        std::vector<int32_t> &cumulative, int64_t &running) const {
    const int64_t jump = std::max<int64_t>(1, reverse_from - reverse_to);
    if (cells_are_hex_neighbors(from_cell, to_cell)) {
        running += std::max<int64_t>(1, trade_land_step_cost(from_cell, to_cell, cap));
        route.push_back(to_cell);
        cumulative.push_back(static_cast<int32_t>(
            std::min<int64_t>(running, std::numeric_limits<int32_t>::max())));
        return true;
    }
    std::vector<int32_t> water;
    if (!reconstruct_water_corridor(from_cell, to_cell, cap, water))
        return false;
    const int64_t origin = running;
    const int32_t water_n = static_cast<int32_t>(water.size());
    for (int32_t i = 0; i < water_n; ++i) {
        const int64_t part = water_n <= 0 ? jump
            : std::max<int64_t>(0, (jump * (i + 1)) / (water_n + 1));
        running = origin + part;
        route.push_back(water[static_cast<size_t>(i)]);
        cumulative.push_back(static_cast<int32_t>(
            std::min<int64_t>(running, std::numeric_limits<int32_t>::max())));
    }
    running = origin + jump;
    route.push_back(to_cell);
    cumulative.push_back(static_cast<int32_t>(
        std::min<int64_t>(running, std::numeric_limits<int32_t>::max())));
    return true;
}

void NativeEconomyRuntime::fill_trade_water_columns(
        const uint8_t *terrain, const uint8_t *landform, const uint8_t *has_river,
        int32_t count, std::vector<uint8_t> &water_class,
        std::vector<uint8_t> &river) const {
    water_class.assign(static_cast<size_t>(std::max(0, count)), WATER_CLASS_NONE);
    river.assign(static_cast<size_t>(std::max(0, count)), 0);
    if (count <= 0) return;
    if (landform != nullptr) {
        for (int32_t cell = 0; cell < count; ++cell) {
            water_class[static_cast<size_t>(cell)] = classify_water_class(
                terrain != nullptr ? terrain[cell] : 0, landform[cell]);
        }
    }
    if (has_river != nullptr) {
        for (int32_t cell = 0; cell < count; ++cell)
            river[static_cast<size_t>(cell)] = has_river[cell] != 0 ? 1 : 0;
    }
}

} // namespace pk
